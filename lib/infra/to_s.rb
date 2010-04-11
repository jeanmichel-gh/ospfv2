module OSPFv2
  module TO_S
    
    def to_s(*args)
      return to_s_default(*args) unless defined?($style)
      case $style
      when :junos ; to_s_junos(*args)
      when :junos_verbose ; to_s_junos_verbose(*args)
      else
        to_s_default(*args)
      end
    end
    
  end

end