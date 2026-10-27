module OSPFv2
  # Mixin for Information Elements.
  # Any to_s_ios / to_s_junos call falls back to to_s when an IE
  # does not define a vendor specific rendering.
  module IE
    VENDOR_TO_S = /\Ato_s_(ios|junos)\z/

    def method_missing(name, *args, &block)
      return to_s(*args, &block) if name.to_s.match?(VENDOR_TO_S)
      super
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.match?(VENDOR_TO_S) || super
    end
  end
end
