class SkyArray < Array
  def find_by_role(role, options = {})
    options ||= {}
    find_all{|sky_instance| sky_instance.role == role && options.inject(true){|res,(key,value)|
        res &= sky_instance.respond_to?(key.to_s) && sky_instance.send(key.to_sym) == value
      }
    }
  end
  
  def find_by_hostname(hostname, options = {})
    find_all{|sky_instance| sky_instance.hostname == hostname }
  end
  
  def find_by_internal_ip(internal_ip, options = {})
    find_all{|sky_instance| sky_instance.internal_ip == internal_ip }
  end
end