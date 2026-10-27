# frozen_string_literal: true

require 'ipaddr'

module OSPFv2
  module Core
    # Dotted quads and 32-bit integers. The core keeps router ids, area
    # ids and addresses as Integers and turns them into strings only for
    # display.
    module Addr
      module_function

      def to_i(value)
        case value
        when Integer
          raise ArgumentError, "not a 32-bit value: #{value}" unless value.between?(0, 0xffff_ffff)
          value
        when IPAddr then value.to_i
        when String
          raise ArgumentError, "not a dotted quad: #{value.inspect}" unless value.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
          IPAddr.new(value).to_i
        else
          raise ArgumentError, "not an address: #{value.inspect}"
        end
      rescue IPAddr::InvalidAddressError
        raise ArgumentError, "not a dotted quad: #{value.inspect}"
      end

      def to_s(value)
        [value].pack('N').unpack('C4').join('.')
      end

      def mask(prefix_len)
        prefix_len.zero? ? 0 : (0xffff_ffff << (32 - prefix_len)) & 0xffff_ffff
      end

      def prefix_len(mask)
        raise ArgumentError, "not a contiguous mask: #{to_s(mask)}" unless mask == self.mask(32 - (~mask & 0xffff_ffff).bit_length)
        32 - (~mask & 0xffff_ffff).bit_length
      end

      # "10.0.0.1/24" => [address, prefix_len] as [Integer, Integer]
      def parse_prefix(value)
        ip, len = value.to_s.split('/', 2)
        raise ArgumentError, "missing prefix length in #{value.inspect}" unless len
        raise ArgumentError, "bad prefix length in #{value.inspect}" unless len.match?(/\A\d{1,2}\z/) && len.to_i <= 32
        [to_i(ip), len.to_i]
      end
    end
  end
end
