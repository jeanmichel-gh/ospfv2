# frozen_string_literal: true

module OSPFv2
  module Config
    class Error < StandardError; end

    # The shape of the configuration: which words may follow which, and
    # what values they take. The parser, the CLI completion and the help
    # text all come from here.
    #
    #   container 'protocols' do
    #     container 'ospf' do
    #       list 'area', key: :area_id do ... end
    #     end
    #   end
    module Schema
      # A node in the schema. Kinds:
      #   :container  a word followed by more words           protocols { ... }
      #   :list       a word, a key, then more words          area 0.0.0.0 { ... }
      #   :leaf       a word and one value                    metric 10;
      #   :flag       a word alone                            passive;
      #   :keyed_leaf a word, a key and one sub-leaf value    md5 1 key "s";
      class Node
        attr_reader :name, :kind, :help, :type, :children, :secret, :sub

        def initialize(name, kind, help: nil, type: nil, secret: false, sub: nil)
          @name = name
          @kind = kind
          @help = help
          @type = type
          @secret = secret
          @sub = sub
          @children = {}
        end

        def container(name, help: nil, &block) = add(Node.new(name, :container, help: help), &block)
        def list(name, key:, help: nil, &block) = add(Node.new(name, :list, help: help, type: key), &block)
        def leaf(name, type, help: nil, secret: false) = add(Node.new(name, :leaf, help: help, type: type, secret: secret))
        def flag(name, help: nil) = add(Node.new(name, :flag, help: help))

        # md5 <id> key <secret>: a list whose entries hold one leaf.
        def keyed_leaf(name, key:, sub:, type:, help: nil, secret: false)
          add(Node.new(name, :keyed_leaf, help: help, type: key, sub: [sub, type], secret: secret))
        end

        def child(word) = @children[word]

        # Children whose name starts with +prefix+.
        def matches(prefix)
          return [@children[prefix]] if @children.key?(prefix)
          @children.values.select { |c| c.name.start_with?(prefix) }
        end

        def inner? = %i[container list].include?(@kind)

        private

        def add(node, &block)
          @children[node.name] = node
          node.instance_eval(&block) if block
          node
        end
      end

      # Value types: a parser returning the canonical value, or raising
      # Config::Error with a message for the user.
      module Types
        module_function

        def ipv4(v)
          raise Error, "invalid IPv4 address '#{v}'" unless v.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) && v.split('.').all? { |o| o.to_i <= 255 }
          v.split('.').map(&:to_i).join('.')
        end

        # Area: dotted quad or a plain number, shown dotted (Junos style).
        def area(v)
          return [v.to_i].pack('N').unpack('C4').join('.') if v.match?(/\A\d+\z/) && v.to_i <= 0xffff_ffff
          ipv4(v)
        rescue Error
          raise Error, "invalid area '#{v}': use a number or a dotted quad"
        end

        def range(lo, hi)
          lambda do |v|
            raise Error, "'#{v}' is not a number" unless v.match?(/\A\d+\z/)
            raise Error, "value #{v} is not within range (#{lo}..#{hi})" unless v.to_i.between?(lo, hi)
            v.to_i
          end
        end

        # "10.1.0.0/16", returned with the host bits cleared.
        def prefix(v)
          ip, len = v.split('/', 2)
          raise Error, "invalid prefix '#{v}': use a.b.c.d/len" unless len&.match?(/\A\d{1,2}\z/) && len.to_i <= 32
          n = ipv4(ip).split('.').map(&:to_i).inject(0) { |a, o| (a << 8) | o }
          mask = len.to_i.zero? ? 0 : (0xffff_ffff << (32 - len.to_i)) & 0xffff_ffff
          "#{[n & mask].pack('N').unpack('C4').join('.')}/#{len.to_i}"
        end

        # "/24" or "24", a prefix length.
        def prefix_length(v)
          raise Error, "invalid prefix length '#{v}'" unless v.match?(%r{\A/?\d{1,2}\z}) && v.delete('/').to_i <= 32
          v.delete('/').to_i
        end

        def name(v)
          raise Error, "invalid name '#{v}'" unless v.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z/)
          v
        end

        def interface_name(v)
          raise Error, "invalid interface name '#{v}'" unless v.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:@-]{0,14}\z/)
          v
        end

        def string(max)
          lambda do |v|
            raise Error, 'value cannot be empty' if v.empty?
            raise Error, "value is longer than #{max} characters" if v.bytesize > max
            v
          end
        end

        def one_of(*words)
          lambda do |v|
            m = words.select { |w| w.start_with?(v) }
            m = [v] if words.include?(v)
            raise Error, "'#{v}' is not one of: #{words.join(', ')}" unless m.size == 1
            m.first
          end
        end
      end

      # Placeholder shown in help, per type.
      HINTS = {}.compare_by_identity

      def self.hint(type, text)
        HINTS[type] = text
        type
      end

      T = Types
      IPV4 = hint(T.method(:ipv4), '<a.b.c.d>')
      AREA = hint(T.method(:area), '<area-id>')
      IFNAME = hint(T.method(:interface_name), '<interface>')
      PREFIX = hint(T.method(:prefix), '<a.b.c.d/len>')
      NAME = hint(T.method(:name), '<name>')

      AUTH_ALGORITHMS = {
        'md5' => :md5, 'hmac-sha-1' => :hmac_sha1, 'hmac-sha-256' => :hmac_sha256,
        'hmac-sha-384' => :hmac_sha384, 'hmac-sha-512' => :hmac_sha512
      }.freeze

      ROOT = Node.new('', :container).tap do |root|
        root.instance_eval do
          container 'routing-options', help: 'Protocol-independent routing options' do
            leaf 'router-id', IPV4, help: 'Router identifier'
            container 'kernel', help: 'Installing OSPF routes in the Linux routing table' do
              leaf 'metric', Schema.hint(T.range(1, 4_294_967_295), '<1..4294967295>'),
                   help: 'Kernel route metric (default 20; lower wins against other routes to the same prefix)'
              leaf 'protocol', Schema.hint(T.range(5, 255), '<5..255>'), help: 'Protocol id our routes carry (default 89)'
              leaf 'table', Schema.hint(T.range(1, 4_294_967_295), '<table-id>'), help: 'Kernel table (default 254, main)'
              flag 'no-install', help: 'Compute routes, do not install them'
            end
          end
          container 'policy-options', help: 'Routing policy' do
            list 'policy-statement', key: NAME, help: 'A named policy' do
              list 'term', key: NAME, help: 'A term, tried in order' do
                container 'from', help: 'Conditions; all must match' do
                  leaf 'protocol', Schema.hint(T.one_of('direct', 'static'), '<direct|static>'),
                       help: 'direct: the host\'s own networks; static: static routes in the kernel'
                  list 'route-filter', key: PREFIX, help: 'Prefix to match' do
                    flag 'exact', help: 'This prefix only (the default)'
                    flag 'orlonger', help: 'This prefix and any longer one inside it'
                    flag 'longer', help: 'Longer prefixes inside it, not this one'
                    leaf 'upto', Schema.hint(T.method(:prefix_length), '</len>'), help: 'Inside it, up to this length'
                  end
                end
                container 'then', help: 'Actions' do
                  leaf 'metric', Schema.hint(T.range(0, 16_777_214), '<0..16777214>'), help: 'External metric (default 20)'
                  container 'external', help: 'External route options' do
                    leaf 'type', Schema.hint(T.range(1, 2), '<1|2>'), help: 'External type (default 2)'
                  end
                  leaf 'tag', Schema.hint(T.range(0, 4_294_967_295), '<tag>'), help: 'Route tag'
                  flag 'accept', help: 'Export the route'
                  flag 'reject', help: 'Do not export it'
                end
              end
            end
          end
          container 'protocols', help: 'Routing protocols' do
            container 'ospf', help: 'OSPF version 2' do
              leaf 'export', NAME, help: 'Policy choosing routes to advertise as AS externals'
              list 'area', key: AREA, help: 'OSPF area' do
                list 'interface', key: IFNAME, help: 'Interface in this area' do
                  leaf 'interface-type', Schema.hint(T.one_of('broadcast', 'p2p'), '<broadcast|p2p>'), help: 'Network type'
                  leaf 'metric', Schema.hint(T.range(1, 65_535), '<1..65535>'), help: 'Interface cost'
                  leaf 'priority', Schema.hint(T.range(0, 255), '<0..255>'), help: 'Designated router priority'
                  leaf 'hello-interval', Schema.hint(T.range(1, 65_535), '<seconds>'), help: 'Hello interval'
                  leaf 'dead-interval', Schema.hint(T.range(1, 65_535), '<seconds>'), help: 'Dead interval'
                  leaf 'retransmit-interval', Schema.hint(T.range(1, 65_535), '<seconds>'), help: 'LSA retransmit interval'
                  leaf 'transit-delay', Schema.hint(T.range(1, 65_535), '<seconds>'), help: 'Transmit delay'
                  leaf 'mtu', Schema.hint(T.range(576, 65_535), '<576..65535>'), help: 'MTU used in database description packets'
                  flag 'mtu-ignore', help: 'Do not check the neighbor MTU'
                  flag 'passive', help: 'Advertise the subnet, form no adjacency'
                  flag 'disable', help: 'Keep the configuration, do not run OSPF here'
                  container 'authentication', help: 'Packet authentication' do
                    leaf 'simple-password', Schema.hint(T.string(8), '<password>'), help: 'Clear text password (RFC 2328)',
                                                                                     secret: true
                    AUTH_ALGORITHMS.each do |word, algo|
                      max = algo == :md5 ? 16 : 255
                      keyed_leaf word, key: Schema.hint(T.range(0, 255), '<key-id>'), sub: 'key',
                                       type: Schema.hint(T.string(max), '<secret>'), secret: true,
                                       help: algo == :md5 ? 'Keyed MD5 (RFC 2328)' : "HMAC-#{word.split('-', 2).last.upcase} (RFC 5709)"
                    end
                    leaf 'send-key', Schema.hint(T.range(0, 255), '<key-id>'), help: 'Key to sign with (default: highest id)'
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
