# frozen_string_literal: true

require_relative 'lsa'
require_relative '../ie/opaque_id'
require_relative '../ie/opaque_type'
require_relative '../core/router_information'
require_relative '../core/extended'

module OSPFv2
  # An opaque LSA in the simulator (RFC 5250): types 9, 10 or 11, any
  # opaque type but TE's (TrafficEngineering), its body kept as octets.
  # The Router Information, extended prefix and extended link bodies come
  # from the router core's codec (core/router_information.rb,
  # core/extended.rb), built four ways there; the simulator has one codec
  # for SR's TLVs, not two (docs/design/sr-ospf.md, step 5).
  #
  #   OpaqueLsa.new(ls_type: :area, opaque_type: 4, opaque_id: 0, advertising_router: '0.1.0.1',
  #                 body: Core::RouterInformation.build(algorithms: [0], srgb: [[16000, 8000]]).encode)
  #   OpaqueLsa.new_ntop(octets)
  class OpaqueLsa < Lsa
    BODIES = { 4 => Core::RouterInformation::Body, 7 => Core::ExtendedPrefix::Body,
               8 => Core::ExtendedLink::Body }.freeze

    attr_reader :body

    def self.new_hash(h) = new(h)

    def initialize(arg = {})
      @ls_type = LsType.new(arg.is_a?(Hash) ? (arg[:ls_type] || :area) : 10)
      @body = ''.b
      super(arg.is_a?(Hash) ? arg.reject { |k, _| %i[ls_type body opaque_type opaque_id].include?(k) } : arg)
      # new_ntop starts from an empty Hash, then parses.
      return unless arg.is_a?(Hash) && arg.key?(:opaque_type)
      @opaque_type = OpaqueType.new(arg.fetch(:opaque_type))
      @opaque_id = OpaqueId.new(arg.fetch(:opaque_id, 0))
      b = arg[:body]
      @body = (b.respond_to?(:encode) && !b.is_a?(String) ? b.encode : b.to_s).b
    end

    # The link state ID an opaque LSA's header carries: its opaque type
    # and ID (RFC 5250 section 3), so key and lookups work as for others.
    def ls_id = LsId.new((@opaque_type.to_i << 24) | @opaque_id.to_i)

    def key = [ls_type.to_i, ls_id.to_i, advertising_router.to_i]

    def encode = super(@body)

    def parse(s)
      @body = super(s).to_s.b
    end

    # The body decoded by the core's codec, or nil for a type it has none
    # for. Raises Core::Tlv::Error on a malformed one.
    def decoded
      klass = BODIES[@opaque_type.to_i] or return nil
      klass.new(@body)
    end

    def to_s_verbose
      d = begin
        decoded&.to_s
      rescue Core::Tlv::Error => e
        "malformed: #{e.message}"
      end
      [super, "Opaque type #{@opaque_type.to_i}, ID #{@opaque_id.to_i}", d || "#{@body.bytesize} octets"].join("\n   ")
    end
  end
end
