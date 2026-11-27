# frozen_string_literal: true

module OSPFv2
  module Core
    # The TLVs of opaque LSAs (RFC 7770 section 2.3, RFC 7684 section 2):
    # a 2-octet type, a 2-octet length, the value padded to 4 octets, the
    # padding not in the length.
    #
    # Each TLV class is built four ways (routescope's
    # docs/design/protocol-conventions.md, part 1): from field values, a
    # Hash, its wire octets (header included), or another instance. All
    # four give the same object, and #encode is the measure. Building
    # never validates: OSPFv2::Validation says what is wrong.
    #
    # Types are found through a registry. An unknown one is kept as
    # Tlv::Unknown with its octets and encoded back unchanged.
    class Tlv
      class Error < StandardError; end

      # The TLVs in +octets+, each found in +registry+ (type => class).
      # Raises Error on a TLV past the end, which Validation reports first.
      def self.list(octets, registry)
        out = []
        at = 0
        octets = octets.b
        while at < octets.bytesize
          raise Error, "#{octets.bytesize - at} octets left, less than a TLV header" if octets.bytesize - at < 4
          type, len = octets.byteslice(at, 4).unpack('nn')
          raise Error, "TLV #{type} of length #{len} runs past its end" if at + 4 + len > octets.bytesize
          # With its padding, kept as it came (below).
          out << registry.fetch(type, Unknown).new(octets.byteslice(at, 4 + ((len + 3) & ~3)))
          at += 4 + ((len + 3) & ~3)
        end
        out
      end

      # One TLV from a Hash with :type, through +registry+.
      def self.from_hash(h, registry)
        h = h.transform_keys(&:to_sym)
        registry.fetch(h.fetch(:type), Unknown).new(h)
      end

      def self.pad(value) = value + ("\0" * (-value.bytesize % 4))

      def self.wrap(type, value) = [type, value.bytesize].pack('nn') + pad(value.b)

      def self.three(n) = [n].pack('N').byteslice(1, 3)

      def self.from_three(octets) = ("\0".b + octets).unpack1('N')

      # +arg+: nil (with +fields+), a Hash, octets, or an instance.
      def initialize(arg = nil, **fields)
        case arg
        when nil then set(fields)
        when Hash then set(arg.transform_keys(&:to_sym))
        when String then parse(arg.b)
        when self.class then parse(arg.encode)
        else raise ArgumentError, "a #{self.class.name.split('::').last} from #{arg.class}?"
        end
      end

      def type = self.class::TYPE

      # The padding is "composed of undefined bits" (RFC 7770 section 2.3):
      # FRR 10.5.1 pads its SR-Algorithm TLV with 0xff. A parsed TLV sends
      # back the padding it came with; a built one, zeros.
      def encode
        v = value.b
        pad = @pad&.bytesize == -v.bytesize % 4 ? @pad : "\0" * (-v.bytesize % 4)
        [type, v.bytesize].pack('nn') + v + pad
      end

      def to_hash = { type: type }.merge(fields)

      def to_shex = encode.unpack1('H*')

      def ==(other) = other.is_a?(Tlv) && encode == other.encode
      alias eql? ==

      def hash = encode.hash

      private

      # The value from +octets+, a whole TLV, header included.
      def parse(octets)
        raise Error, 'a TLV needs 4 octets' if octets.bytesize < 4
        _, len = octets.unpack('nn')
        raise Error, "TLV of length #{len} in #{octets.bytesize - 4} octets" if len > octets.bytesize - 4
        @pad = octets.byteslice(4 + len, -len % 4) if octets.bytesize >= 4 + len + (-len % 4)
        decode(octets.byteslice(4, len))
      end

      # An unknown type: its type and value kept as they came. Its Hash
      # has :type and :value, the value in hex.
      class Unknown < Tlv
        attr_reader :value

        def type = @type

        def fields = { value: @value.unpack1('H*') }

        def to_s = "type #{@type}, #{@value.bytesize} octets"

        private

        def set(f)
          @type = Integer(f.fetch(:type))
          @value = [f.fetch(:value, '')].pack('H*')
        end

        def parse(octets)
          @type = octets.unpack1('n') if octets.bytesize >= 2
          super
        end

        def decode(v) = @value = v
      end
    end
  end
end
