# frozen_string_literal: true

require 'digest/md5'
require 'openssl'

module OSPFv2
  module Core
    # OSPFv2 packet authentication, one object per interface.
    #
    #   Auth.build(nil)                                     # null (AuType 0)
    #   Auth.build(type: :simple, password: 'secret')       # AuType 1
    #   Auth.build(type: :md5, keys: { 1 => 'secret' })     # AuType 2, RFC 2328 D.3
    #   Auth.build(type: :hmac_sha256, keys: { 1 => 'k' })  # AuType 2, RFC 5709
    #   Auth.build(type: :crypto, send_key: 2,              # mixed algorithms
    #              keys: [{ id: 1, algorithm: :md5, secret: 'old' },
    #                     { id: 2, algorithm: :hmac_sha256, secret: 'new' }])
    #
    # A sender signs with one key (the highest id unless send_key says
    # otherwise). A receiver accepts any configured key, which is how keys
    # roll over without dropping adjacencies (RFC 2328 D.3).
    #
    # #seal takes an encoded packet whose checksum and authentication
    # fields are zero and returns the bytes to send. #open checks a
    # received packet and returns an Auth::Result, or raises Auth::Error.
    module Auth
      class Error < StandardError; end

      # The packet is corrupt rather than unauthenticated.
      class ChecksumError < Error; end

      NULL = 0
      SIMPLE = 1
      CRYPTO = 2

      # Key ID, and the cryptographic sequence number, of an accepted
      # packet. Both nil for null and simple authentication.
      Result = Struct.new(:key_id, :seq)

      # Hash lengths. MD5 is keyed MD5 from RFC 2328 D.4.3, the others are
      # HMAC-SHA from RFC 5709.
      ALGORITHMS = {
        md5: { length: 16 },
        hmac_sha1: { length: 20, digest: 'SHA1' },
        hmac_sha256: { length: 32, digest: 'SHA256' },
        hmac_sha384: { length: 48, digest: 'SHA384' },
        hmac_sha512: { length: 64, digest: 'SHA512' }
      }.freeze

      # RFC 5709 3.3: 0x878FE1F3 repeated to the hash length.
      APAD_WORD = [0x878F_E1F3].pack('N').freeze

      module_function

      # Builds the authentication for an interface from a spec Hash, a
      # Symbol (:none) or nil. +clock+ returns wall-clock seconds and seeds
      # the cryptographic sequence number so it survives a restart.
      def build(spec = nil, clock: nil, **inline)
        # Auth.build(type: :md5, ...) arrives as keywords, not a Hash.
        spec = inline if spec.nil? && !inline.empty?
        clock ||= -> { Time.now.to_i }
        return spec if spec.respond_to?(:seal) && spec.respond_to?(:open)
        return Null.new if spec.nil? || spec == :none
        raise ArgumentError, "authentication must be a Hash, got #{spec.inspect}" unless spec.is_a?(Hash)

        spec = spec.transform_keys(&:to_sym)
        type = spec[:type]&.to_sym
        case type
        when nil, :none
          check_keys(spec, %i[type])
          Null.new
        when :simple
          check_keys(spec, %i[type password])
          Simple.new(spec[:password])
        when :crypto
          check_keys(spec, %i[type keys send_key])
          Crypto.new(keys: crypto_keys(spec[:keys], nil), send_key: spec[:send_key], clock: clock)
        when *ALGORITHMS.keys
          check_keys(spec, %i[type keys send_key])
          Crypto.new(keys: crypto_keys(spec[:keys], type), send_key: spec[:send_key], clock: clock)
        else
          raise ArgumentError, "unknown authentication type #{type.inspect} " \
                               "(none, simple, #{ALGORITHMS.keys.join(', ')}, crypto)"
        end
      end

      def check_keys(spec, allowed)
        unknown = spec.keys - allowed
        raise ArgumentError, "unknown authentication option(s): #{unknown.join(', ')}" unless unknown.empty?
      end

      # Accepts { id => secret } or [{ id:, secret:, algorithm: }].
      def crypto_keys(keys, algorithm)
        raise ArgumentError, 'cryptographic authentication needs at least one key' if keys.nil? || keys.empty?
        list = keys.is_a?(Hash) ? keys.map { |id, secret| { id: id, secret: secret } } : keys
        list.map do |k|
          k = k.transform_keys(&:to_sym)
          algo = (k[:algorithm] || algorithm)&.to_sym
          raise ArgumentError, "key #{k[:id]}: algorithm missing" unless algo
          if algorithm && algo != algorithm
            raise ArgumentError, "key #{k[:id]}: algorithm #{algo} under authentication type #{algorithm}"
          end
          Key.new(id: k[:id], algorithm: algo, secret: k[:secret])
        end
      end

      # Constant-time comparison, so a forger learns nothing from timing.
      def same?(a, b)
        a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
      end

      # RFC 1071 checksum over the packet, skipping the 8 authentication
      # bytes (RFC 2328 D.4.1, D.4.2).
      def inet_checksum(raw)
        data = raw.dup
        data[16, 8] = "\0" * 8
        data << "\0" if data.bytesize.odd?
        sum = data.unpack('n*').sum
        sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
        ~sum & 0xffff
      end

      def set_checksum(raw)
        raw[12, 2] = [inet_checksum(raw)].pack('n')
        raw
      end

      def autype_of(raw) = raw.byteslice(14, 2).unpack1('n')

      # ---- AuType 0 ----
      class Null
        def autype = NULL
        def trailer_size = 0
        def to_s = 'none'
        def summary = { type: :none }

        def seal(raw)
          raw[14, 2] = [NULL].pack('n')
          Auth.set_checksum(raw)
        end

        def open(bytes, len)
          raw = bytes.byteslice(0, len)
          raise ChecksumError, format('bad checksum 0x%04x', raw.byteslice(12, 2).unpack1('n')) unless Auth.inet_checksum(raw).zero?
          Result.new
        end
      end

      # ---- AuType 1, RFC 2328 D.4.2 ----
      # The password travels in clear. It only guards against a router
      # joining by mistake.
      class Simple
        def initialize(password)
          raise ArgumentError, 'simple authentication needs a password' if password.nil? || password.to_s.empty?
          raise ArgumentError, 'simple password is at most 8 characters' if password.to_s.bytesize > 8
          @password = [password.to_s].pack('a8').freeze
        end

        def autype = SIMPLE
        def trailer_size = 0
        def to_s = 'simple'
        def summary = { type: :simple }

        def seal(raw)
          raw[14, 2] = [SIMPLE].pack('n')
          Auth.set_checksum(raw)
          raw[16, 8] = @password
          raw
        end

        def open(bytes, len)
          raw = bytes.byteslice(0, len)
          raise ChecksumError, format('bad checksum 0x%04x', raw.byteslice(12, 2).unpack1('n')) unless Auth.inet_checksum(raw).zero?
          raise Error, 'wrong password' unless Auth.same?(raw.byteslice(16, 8), @password)
          Result.new
        end
      end

      # One cryptographic key.
      class Key
        attr_reader :id, :algorithm, :length

        def initialize(id:, algorithm:, secret:)
          raise ArgumentError, "key id must be 0..255, got #{id.inspect}" unless id.is_a?(Integer) && id.between?(0, 255)
          algo = ALGORITHMS[algorithm] or raise ArgumentError, "key #{id}: unknown algorithm #{algorithm.inspect}"
          raise ArgumentError, "key #{id}: secret missing" if secret.nil? || secret.to_s.empty?
          if algorithm == :md5 && secret.to_s.bytesize > 16
            raise ArgumentError, "key #{id}: an MD5 key is at most 16 characters"
          end

          @id = id
          @algorithm = algorithm
          @length = algo[:length]
          @digest = algo[:digest]
          @secret = secret.to_s.b
          if @digest
            # RFC 5709 3.3: a key longer than the hash is hashed first.
            # A shorter one is zero padded, which HMAC does anyway.
            @hmac_key = @secret.bytesize > @length ? OpenSSL::Digest.digest(@digest, @secret) : @secret
            @apad = (APAD_WORD * (@length / 4)).freeze
          else
            @md5_key = [@secret].pack('a16').freeze
          end
          freeze
        end

        # The authentication data for +packet+ (the OSPF packet as sent,
        # its length field excluding the trailer).
        def digest(packet)
          if @digest
            OpenSSL::HMAC.digest(@digest, @hmac_key, packet + @apad)
          else
            Digest::MD5.digest(packet + @md5_key)
          end
        end

        def inspect = "#<Key #{@id} #{@algorithm}>"
        alias to_s inspect
      end

      # ---- AuType 2, RFC 2328 D.4.3 and RFC 5709 ----
      class Crypto
        attr_reader :keys, :send_key

        def initialize(keys:, send_key: nil, clock: -> { Time.now.to_i })
          raise ArgumentError, 'cryptographic authentication needs at least one key' if keys.empty?
          ids = keys.map(&:id)
          raise ArgumentError, "duplicate key id(s): #{ids.tally.select { |_, n| n > 1 }.keys.join(', ')}" if ids.uniq.size != ids.size

          @keys = keys.to_h { |k| [k.id, k] }.freeze
          @send_key = send_key ? @keys[send_key] : @keys.values.max_by(&:id)
          raise ArgumentError, "send key #{send_key} is not configured" unless @send_key

          @clock = clock
          @seq = 0
        end

        def autype = CRYPTO
        def trailer_size = @send_key.length
        def to_s = "#{@send_key.algorithm} key #{@send_key.id}"

        def summary
          { type: :crypto, send_key: @send_key.id, keys: @keys.values.map { |k| { id: k.id, algorithm: k.algorithm } } }
        end

        # The sequence number never goes down, and starts from the wall
        # clock so it stays ahead of what neighbors saw before a restart.
        def next_seq
          now = @clock.call.to_i & 0xffff_ffff
          @seq = now > @seq ? now : (@seq + 1) & 0xffff_ffff
        end

        def seal(raw)
          key = @send_key
          raw[12, 2] = "\0\0" # no checksum with cryptographic authentication
          raw[14, 2] = [CRYPTO].pack('n')
          raw[16, 8] = [0, key.id, key.length, next_seq].pack('nCCN')
          raw + key.digest(raw)
        end

        def open(bytes, len)
          _, key_id, dlen, seq = bytes.byteslice(16, 8).unpack('nCCN')
          key = @keys[key_id] or raise Error, "unknown key id #{key_id}"
          raise Error, "key #{key_id}: authentication data length #{dlen}, expected #{key.length}" unless dlen == key.length
          raise Error, "missing authentication data (#{bytes.bytesize - len} of #{dlen} bytes)" if bytes.bytesize < len + dlen

          got = bytes.byteslice(len, dlen)
          raise Error, "key #{key_id}: digest mismatch" unless Auth.same?(got, key.digest(bytes.byteslice(0, len)))
          Result.new(key_id, seq)
        end
      end
    end
  end
end
