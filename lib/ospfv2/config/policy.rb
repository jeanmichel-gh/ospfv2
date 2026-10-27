# frozen_string_literal: true

module OSPFv2
  module Config
    # A Junos-style export policy: terms tried in order. A term matches when
    # all its "from" conditions do; its "then" sets metric, type and tag,
    # and accept or reject ends the evaluation. A term with neither lets
    # evaluation go on to the next with what it set. A route no term
    # accepts is not exported.
    #
    #   p = Policy.new('EXPORT', terms)
    #   p.evaluate(protocol: :static, prefix: 0x0a000000, prefix_len: 8)
    #   # => { metric: 20, type: 2, tag: 0 } or nil
    class Policy
      DEFAULTS = { metric: 20, type: 2, tag: 0 }.freeze

      Filter = Struct.new(:prefix, :prefix_len, :match, :upto) do
        def match?(prefix, len)
          return false if len < prefix_len
          mask = prefix_len.zero? ? 0 : (0xffff_ffff << (32 - prefix_len)) & 0xffff_ffff
          return false unless (prefix & mask) == self.prefix
          case match
          when :exact then len == prefix_len
          when :orlonger then true
          when :longer then len > prefix_len
          when :upto then len <= upto
          end
        end
      end

      Term = Struct.new(:name, :protocol, :filters, :set, :action, keyword_init: true) do
        def match?(route)
          return false if protocol && protocol != route[:protocol]
          filters.empty? || filters.any? { |f| f.match?(route[:prefix], route[:prefix_len]) }
        end
      end

      attr_reader :name, :terms

      def initialize(name, terms)
        @name = name
        @terms = terms.freeze
        freeze
      end

      # From the configuration tree's policy-statement entry.
      def self.from_config(name, data)
        terms = (data['term'] || {}).map do |tname, t|
          from = t['from'] || {}
          filters = (from['route-filter'] || {}).map do |pfx, f|
            ip, len = pfx.split('/')
            n = ip.split('.').map(&:to_i).inject(0) { |a, o| (a << 8) | o }
            match = if f['upto'] then :upto
                    elsif f['orlonger'] then :orlonger
                    elsif f['longer'] then :longer
                    else :exact
                    end
            Filter.new(n, len.to_i, match, f['upto'])
          end
          th = t['then'] || {}
          set = { metric: th['metric'], type: th.dig('external', 'type'), tag: th['tag'] }.compact
          action = if th['reject'] then :reject
                   elsif th['accept'] then :accept
                   end
          Term.new(name: tname, protocol: from['protocol']&.to_sym, filters: filters, set: set, action: action)
        end
        new(name, terms)
      end

      def evaluate(route)
        attrs = DEFAULTS.dup
        @terms.each do |t|
          next unless t.match?(route)
          attrs.merge!(t.set)
          return attrs if t.action == :accept
          return nil if t.action == :reject
        end
        nil
      end
    end
  end
end
