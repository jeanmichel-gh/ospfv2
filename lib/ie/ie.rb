module OSPFv2
  module IE
    def method_missing(name, *args, &block)
      if name.to_s =~ /^to_s_(ios|junos)$/
        __send__ :to_s, *args, &block
      else
        p "#{name} is missing...."
        raise
      end
    end
  end
end
