class SkyInstance
  attr_accessor :environment, :role, :hostname, :application, :primary, :internal_ip, :instance_id
  
  def initialize options = {}
    @environment = options[:environment]
    @role = options[:role]
    @hostname = options[:hostname]
    @application = options[:application]
    @primary = options[:primary]
    @internal_ip = options[:internal_ip]
    @instance_id = options[:instance_id]
  end
  
  def options
    {:primary => @primary}.delete_if{|key, value| value.nil? }
  end
end