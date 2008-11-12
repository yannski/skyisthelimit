require "EC2"
require File.join(File.dirname(__FILE__), "capistrano", "hostcmd")
require File.join(File.dirname(__FILE__), "ext", "hash")
require File.join(File.dirname(__FILE__), "sky_instance")
require File.join(File.dirname(__FILE__), "sky_array")

def read_config file
  logger.info "merge config file #{file}"
  if configuration_data.nil?
    data = YAML.load_file(file)
  elsif YAML.load_file(file).nil?
    configuration_data
  else
    data = configuration_data.deep_merge YAML.load_file(file)
  end
  set :configuration_data, data
end

def transform file
  @path = "/"
  @read_cmd = @write_cmd = @post_cmd = @pre_cmd = nil
  result = ERB.new(File.read(file)).result(binding)
  run @pre_cmd unless @pre_cmd.nil?
  if @write_cmd
    temp_file_name = "/tmp/sky-temp"
    put result, temp_file_name
    run "cat #{temp_file_name} | #{@write_cmd}"
    run "rm #{temp_file_name} -f"
  else
    put result, @path
  end
  run @post_cmd unless @post_cmd.nil?
end
    
Capistrano::Configuration.instance.load do

  namespace :sky do
    
    desc "Refresh instance data by connecting to all instances and grab the instance.yml file"
    task :refresh_instance_data do
      logger.info "Updating cloud data"
      new_sky_instances = SkyArray.new
      ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
      response = ec2.describe_instances()
      response.reservationSet.item.each do |ritem|
        ritem.instancesSet.item.each do |item|
          if item.instanceState.name == "running"
            dns = item.dnsName
            instance_id = item.instanceId
            task :_get_instance_data, :hosts => dns do
              begin
                instance_data = capture  "cat /etc/instance.yml"
                sky_instance = SkyInstance.new(YAML.load(instance_data).merge(:hostname => dns, :instance_id => instance_id))
                new_sky_instances << sky_instance if sky_instance.application == sky_application_name && sky_instance.environment == rails_env
              rescue
              end
            end
            _get_instance_data
          end
        end
      end if response.reservationSet
    
      top.roles.clear
      new_sky_instances.each{|sky_instance|
        top.role sky_instance.role.to_sym, sky_instance.hostname, sky_instance.options if sky_roles.keys.include?(sky_instance.role.to_sym)
      }
      set :sky_instances, new_sky_instances
    end
  
    desc "Read additional config files"
    task :read_additional_config_files do
      # load additional deploy-* file
      Dir[File.join(sky_config_dir, 'deploy-*.rb')].each do |deploy_file|
        top.load deploy_file
      end
      set :configuration_data, nil
      read_config(File.join(sky_config_dir, "sky.yml"))
      Dir[File.join(sky_config_dir, "sky-*.yml")].sort.each { |file| read_config(file) }
    end
  
    def merge existing_hash, new_hash
      return existing_hash if new_hash.nil?
      return new_hash if existing_hash.nil?
      new_hash.each{|key, value|
        if existing_hash[key]
          if existing_hash[key].is_a? Hash
            existing_hash[key].merge!(new_hash[key]) 
          elsif existing_hash[key].is_a? Array
            existing_hash[key] = existing_hash[key] | new_hash[key]
          else
            existing_hash[key] = existing_hash[key]
          end
        else
          existing_hash[key] = value
        end
      }
      existing_hash
    end
  
    desc "Provision the environment"
    task :provision do
      # sed -i '/amazon/d' ~/.ssh/known_hosts
      #sky.instances.launch
      sky.set_timezone
      sky.update.ubuntu_packages
      sky.install.ubuntu_packages
      sky.install.rubygems
      sky.install.basic_gems
      sky.mount_volumes
      sky.write_remote_files
    end
  
    desc "Write remote config files"
    task :write_remote_files do
      base_files = File.join(sky_config_dir, 'common', '*')
      Dir[base_files].each do |file|
        transform file
      end
    
      base_dir = File.join(sky_config_dir, 'role', '*')
      Dir[base_dir].each do |dir|
        role_name = dir.split("/").last
        next if ENV['SKY_ROLES'] && !ENV['SKY_ROLES'].split(",").include?(role_name)
        task_name = "_put_files_on_#{role_name}"
        task task_name.to_sym, :roles => role_name do
          base_files = File.join(dir, '*')
          Dir[base_files].each do |file|
            transform file
          end
        end
        send task_name
      end
    end
    
    desc "Mount EBS volumes"
    task :mount_volumes, :roles => %w(app), :only => {:primary => true} do
      ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
      role = "app"
      sky_instance = sky_instances.find_by_role(role, :primary => true).first
      instance_config = get_instance_config role
      instance_config["volumes"].each{|volume_options|
        ebs_volume_options = {:instance_id => sky_instance.instance_id, :volume_id => volume_options["volume_id"], :device => volume_options["device"]}
        begin
          ec2.attach_volume ebs_volume_options
        rescue EC2::InvalidDeviceInUse
        #rescue EC2::IncorrectState
        end
        sleep 10 # Wait until the EBS volume is really attached to the instance
        mount_point = volume_options.delete("mount_point")
        device = volume_options.delete("device")
        file_system = volume_options.delete("file_system")
        #run "yes | mkfs.xfs #{device}"
        run "echo \"#{device} #{mount_point} #{file_system} noatime 0 0\" >> /etc/fstab"
        run "mkdir #{mount_point} -p"
        run "mount #{mount_point}"
      }
    end

    task :setup_nfs_server, :roles => :app, :only => {:primary => true} do
      run "apt-get install -q -y nfs-common nfs-kernel-server"
      app_instance = sky_instances.find_by_role("app", :primary => true).first
      ips = sky_instances.map{|sky_instance| sky_instance.internal_ip if sky_instance.internal_ip != app_instance.internal_ip }.compact
      exports = "/vol "
      exports += ips.map{|ip| ip+"(rw)"}.join(" ")
      run "echo \"#{exports}\" > /etc/exports"
      run "/etc/init.d/nfs-kernel-server restart"
    end

    task :setup_nfs_clients do
      app_instance = sky_instances.find_by_role("app", :primary => true).first
      other_instances = sky_instances.find_all{|sky_instance| sky_instance.internal_ip != app_instance.internal_ip }
      other_instances.reverse.each{|sky_instance|
        dns = sky_instance.hostname
        task_name = "_setup_nfs_client_#{dns.gsub(".", "_")}"
        task task_name.to_sym, :hosts => dns do
          run "apt-get install -q -y nfs-common"
          run "mkdir -p /vol"
          fstab = "#{app_instance.internal_ip}:/vol	/vol	nfs	user,noauto	0	0"
          run "echo \"#{fstab}\" >> /etc/fstab"
          #run "trap \"mount /vol\" 1 2 3"
          run "mount /vol"
        end
        send task_name
      }
    end
  
    desc <<-DESC
    Set the timezone using the value of the variable named timezone. \
    Valid options for timezone can be determined by the contents of \
    /usr/share/zoneinfo, which can be seen here: \
    http://packages.ubuntu.com/cgi-bin/search_contents.pl?searchmode=filelist&word=tzdata&version=gutsy&arch=all&page=1&number=all \
    Remove 'usr/share/zoneinfo/' from the filename, and use the last \
    directory and file as the value. For example 'Africa/Abidjan' or \
    'posix/GMT' or 'Canada/Eastern'.
    DESC
    task :set_timezone do
      opts = timezone
      run "ln -sf /usr/share/zoneinfo/#{opts} /etc/localtime"
    
      # restart syslog so that times match timezone
      run "/etc/init.d/sysklogd restart"
    end
  
    namespace :instances do
      desc "Launch all instances"
      task :launch do
        logger.info "For the moment we have :"
        new_sky_roles = sky_roles
        sky_instances.each{|sky_instance|
          logger.info "#{sky_instance.hostname} configured as role #{sky_instance.role}"        
          new_sky_roles[sky_instance.role.to_sym] = new_sky_roles[sky_instance.role.to_sym] - 1 if new_sky_roles[sky_instance.role.to_sym]
        }
        logger.info "Need to launch :"
        new_sky_roles.each{|role, number|
          logger.info "#{number} for role #{role}"
        }
      
        ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
      
        new_sky_roles.each{|role_name, total_number_of_hosts|
          next if total_number_of_hosts < 1
          total_number_of_hosts.times{|i|
            create_instance role_name
          }
        }      
      end
    
      desc "Describe current instances"
      task :describe do
        ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
      
        results = []
        format = "%-14s %-10s %-50s %-7s %-20s"
        results << format % %w[InstanceID State DNS Role Zone]
      
        response = ec2.describe_instances()
        response.reservationSet.item.each do |ritem|
          ritem.instancesSet.item.each do |item|
            dns = item.dnsName
            instance_id = item.instanceId
            state = item.instanceState.name
            zone = item.placement.availabilityZone
            ary = sky_instances.find_by_hostname(dns)
            if ary.any?
              sky_instance = ary.first
              if sky_instance.application == sky_application_name && sky_instance.environment == rails_env
                results << format % [instance_id, state, dns, sky_instance.role, zone]
              end
            end
          end
        end if response.reservationSet
        results.each {|r|
          logger.info r
        }
      end
    end
    
    namespace :security_groups do
      desc "Describes the network security groups"
      task :describe do
        ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
        
        # For each group that does already exist in ec2
        response = ec2.describe_security_groups()
        puts response.xml
      end
    end
    
    namespace :update do
      desc "Update the base packages"
      task :ubuntu_packages do
        run "export DEBIAN_FRONTEND=noninteractive; apt-get autoremove -q -y && apt-get update && apt-get -q -y dist-upgrade"
      end
      
      desc "Update gems"
      task :gems do
        run "gem update"
      end
    end
  
    namespace :install do
      desc "Install base ubuntu packages"
      task :ubuntu_packages do
        opts = get_host_options('packages') { |x| x.join(' ') }
        run "export DEBIAN_FRONTEND=noninteractive; apt-get -q -y install $CAPISTRANO:VAR$", opts
      end
    
      desc "Install rubygems"
      task :rubygems do        
        cmd  = "if [ ! -f /usr/bin/gem ]; "
        cmd += "then wget -qP /tmp http://rubyforge.org/frs/download.php/45905/rubygems-1.3.1.tgz;"
        cmd += "tar -C /tmp -xzf /tmp/rubygems-1.3.1.tgz;"
        cmd += "ruby -C /tmp/rubygems-1.3.1 setup.rb;"
        cmd += "ln -sf /usr/bin/gem1.8 /usr/bin/gem;"
        cmd += "rm -rf /tmp/rubygems*;"
        cmd += "fi"
        run cmd
      end
    
      desc "Install some ruby gems"
      task :basic_gems do
        opts = get_host_options('gems') { |x| x.join(' ') }
        run "gem install $CAPISTRANO:VAR$ --no-rdoc --no-ri", opts do |ch, str, data|
          ch[:data] ||= ""
          ch[:data] << data
          if data =~ />\s*$/
            logger.info data
            logger.info "The gem command is asking for a number:"
            choice = STDIN.gets
            ch.send_data(choice)
          else
            logger.info data
          end
        end
      end
    end
  
    def get_instance_config role
      if configuration_data["roles"] && configuration_data["roles"][role.to_s]
        configuration_data.deep_merge configuration_data["roles"][role.to_s]
      else
        configuration_data
      end
    end
  
    def create_instance(role)
      instance_config = get_instance_config(role)
    
      res = nil
      ec2 = EC2::Base.new(:access_key_id => aws_access_key, :secret_access_key => aws_secret_access_key)
    
      # We need to use security_groups during create, so create them up front
      # #setup_security_groups
      security_groups = ["default"]
      security_groups << "web" if role.to_s == "web"
    
      ami = instance_config["ec2_instance"]
      ami_type = instance_config["ec2_instance_type"]
      response = ec2.run_instances(:image_id => ami, :key_name => ec2_key_name, :instance_type => ami_type, :group_id => security_groups)
      item = response.instancesSet.item[0]
      instance_id = item.instanceId

      logger.info "Instance #{instance_id} created"

      print "Waiting for instance to start"
      while true do
        print "."
        sleep 2
        response = ec2.describe_instances(:instance_id => instance_id)
        item = response.reservationSet.item[0].instancesSet.item[0]
        if item.instanceState.name == "running"
          logger.info "\nInstance running"
        
          # Connect to newly created instance and grab its internal ip so that
          # we can update all aliases
          res = dns = item.dnsName
          task :_put_instance_file, :hosts => dns do
            hsh = {:application => sky_application_name, :environment => rails_env, :role => role.to_s}
            hsh[:hostname] = dns
            hsh[:internal_ip] = capture("curl -s http://169.254.169.254/latest/meta-data/local-ipv4").strip
            hsh[:primary] = true if sky_instances.find_by_role(role.to_s, :conditions => {:primary => true}).empty?
            put YAML.dump(hsh), "/etc/instance.yml"
            run "hostname #{dns}"
            sky_instance = SkyInstance.new(hsh)
            set :sky_instances, (sky_instances << sky_instance)
            top.role role.to_sym, sky_instance.hostname, sky_instance.options
          end

          # even though instance is running, sometimes ssh hasn't started yet,
          # so retry on connect failure
          begin
            _put_instance_file
          rescue Capistrano::ConnectionError # FIXME why that does not work ?
            sleep 2
            logger.info "Failed to connect to #{dns}, retrying"
            retry
          end

          break
        end
      end
      return res
    end
  
    # Returns a map of "hostvar_<hostname>" => value for the given config value
    # for each instance host This is used to run capistrano tasks scoped to the
    # correct role/host so that a config value specific to a role/host will only
    # be used for that role/host, e.g. the list of packages to be installed.
    def get_host_options(key, &block)
      opts = {}
      sky_instances.each{|sky_instance|
        merging = configuration_data.keep_merge configuration_data["roles"][sky_instance.role.to_s]
        if block
          value = block.call(merging[key])
        end
        opts["hostvar_#{sky_instance.hostname}"] = value
      }
      return opts
    end
  end
  
  on :start, "sky:refresh_instance_data"
end
