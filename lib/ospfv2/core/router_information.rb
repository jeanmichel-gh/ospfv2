# frozen_string_literal: true

require_relative 'tlv'

module OSPFv2
  module Core
    # The Router Information opaque LSA (RFC 7770): opaque type 4, its body
    # a list of TLVs. ospfd sends one per area, opaque ID 0, type 10, as
    # RFC 8665 section 3.1 requires area scope for SR's TLVs.
    #
    #   RouterInformation.new(tlvs: [Capabilities.new(bits: 0), SrAlgorithm.new(algorithms: [0])])
    #   RouterInformation.new({ tlvs: [{ type: 1, bits: 0 }] })
    #   RouterInformation.new(body_octets)
    #   RouterInformation.new(other)
    module RouterInformation
      OPAQUE_TYPE = 4

      # The SID/Label sub-TLV (RFC 8665 section 2.1): a 3-octet label, or
      # a 4-octet SID.
      class SidLabel < Tlv
        TYPE = 1
        attr_reader :sid

        def fields = { sid: @sid, octets: @octets }
        def label? = @octets == 3
        def to_s = label? ? "label #{@sid}" : "sid #{@sid}"

        private

        def set(f)
          @sid = Integer(f.fetch(:sid))
          @octets = Integer(f.fetch(:octets, 3))
        end

        def value = @octets == 3 ? Tlv.three(@sid) : [@sid].pack('N')

        def decode(v)
          @octets = v.bytesize
          @sid = @octets == 3 ? Tlv.from_three(v) : v.ljust(4, "\0").unpack1('N')
        end
      end

      SUB_TLVS = { 1 => SidLabel }.freeze

      # Router Informational Capabilities (RFC 7770 section 2.4): 32 bits.
      class Capabilities < Tlv
        TYPE = 1
        attr_reader :bits

        def fields = { bits: @bits }
        def to_s = format('capabilities 0x%08x', @bits)

        private

        def set(f) = @bits = Integer(f.fetch(:bits, 0))
        def value = [@bits].pack('N')
        def decode(v) = @bits = v.ljust(4, "\0").unpack1('N')
      end

      # SR-Algorithm (RFC 8665 section 3.1): one octet per algorithm.
      class SrAlgorithm < Tlv
        TYPE = 8
        attr_reader :algorithms

        def fields = { algorithms: @algorithms }
        def to_s = "algorithms #{@algorithms.join(' ')}"

        private

        def set(f) = @algorithms = Array(f.fetch(:algorithms)).map { Integer(_1) }
        def value = @algorithms.pack('C*')
        def decode(v) = @algorithms = v.unpack('C*')
      end

      # SID/Label Range (RFC 8665 section 3.2, type 9) and SR Local Block
      # (3.3, type 14): a 3-octet size, a reserved octet, then sub-TLVs,
      # the first SID/Label among them.
      class Range < Tlv
        attr_reader :size, :subs

        def first = @subs.find { _1.is_a?(SidLabel) }&.sid
        def sid_labels = @subs.count { _1.is_a?(SidLabel) }
        def fields = { size: @size, subs: @subs.map(&:to_hash) }
        def to_s = "#{name} #{first}#{"-#{first + @size - 1}" if first && @size.positive?} (size #{@size})"

        private

        def set(f)
          @size = Integer(f.fetch(:size))
          @subs = if f.key?(:subs) then f[:subs].map { _1.is_a?(Tlv) ? _1 : Tlv.from_hash(_1, SUB_TLVS) }
                  else [SidLabel.new(sid: Integer(f.fetch(:first)))]
                  end
        end

        def value = Tlv.three(@size) + "\0".b + @subs.map(&:encode).join

        def decode(v)
          raise Error, "#{name} of #{v.bytesize} octets, less than 4" if v.bytesize < 4
          @size = Tlv.from_three(v.byteslice(0, 3))
          @subs = Tlv.list(v.byteslice(4..), SUB_TLVS)
        end
      end

      class SidLabelRange < Range
        TYPE = 9
        def name = 'srgb'
      end

      class Srlb < Range
        TYPE = 14
        def name = 'srlb'
      end

      # A registry, not a case, so new TLVs join (RFC 9350's FAD, type 16).
      TLVS = { 1 => Capabilities, 8 => SrAlgorithm, 9 => SidLabelRange, 14 => Srlb }.freeze

      # The LSA's body: its TLVs, unknown ones kept.
      class Body < Tlv::Body
        TLVS = RouterInformation::TLVS

        def capabilities = @tlvs.find { _1.is_a?(Capabilities) }&.bits

        # RFC 8665 section 3.1: the first SR-Algorithm TLV; nil without one,
        # and the router is then "not being Segment Routing capable".
        def algorithms = @tlvs.find { _1.is_a?(SrAlgorithm) }&.algorithms

        def ranges(klass) = @tlvs.grep(klass)
      end

      module_function

      # The body ospfd sends: no capability bits (it has none of graceful
      # restart, stub router or TE), then SR's TLVs when given.
      #   srgb, srlb: [[first label, size], ...]
      def build(algorithms: nil, srgb: [], srlb: [])
        tlvs = [Capabilities.new(bits: 0)]
        tlvs << SrAlgorithm.new(algorithms: algorithms) if algorithms
        tlvs += srgb.map { |first, size| SidLabelRange.new(first: first, size: size) }
        tlvs += srlb.map { |first, size| Srlb.new(first: first, size: size) }
        Body.new(tlvs: tlvs)
      end
    end
  end
end
