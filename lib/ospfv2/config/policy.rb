# frozen_string_literal: true

module OSPFv2
  module Config
    # A Junos-style export policy: terms tried in order. A term matches when
    # all its "from" conditions do. Route filters match as on Junos: the
    # longest filter prefix containing the route is chosen, then its match
    # types decide; its "then" sets metric, type and tag,
    # and accept or reject ends the evaluation. A term with neither lets
    # evaluation go on to the next with what it set. A route no term
    # accepts is not exported.
    #
    #   p = Policy.new('EXPORT', terms)
    #   p.evaluate(protocol: :static, prefix: 0x0a000000, prefix_len: 8)
    #   # => { metric: 20, type: 2, tag: 0 } or nil
    class Policy
      DEFAULTS = { metric: 20, type: 2, tag: 0 }.freeze

      # One route-filter prefix and its match types (several may be set).
      Filter = Struct.new(:prefix, :prefix_len, :matches, :upto) do
        def contains?(prefix, len)
          return false if len < prefix_len
          mask = prefix_len.zero? ? 0 : (0xffff_ffff << (32 - prefix_len)) & 0xffff_ffff
          (prefix & mask) == self.prefix
        end

        def match?(len)
          matches.any? do |m|
            case m
            when :exact then len == prefix_len
            when :orlonger then true
            when :longer then len > prefix_len
            when :upto then len <= upto
            end
          end
        end
      end

      Term = Struct.new(:name, :protocol, :filters, :set, :action, keyword_init: true) do
        def match?(route)
          return false if protocol && protocol != route[:protocol]
          return true if filters.empty?
          f = filters.select { |x| x.contains?(route[:prefix], route[:prefix_len]) }.max_by(&:prefix_len)
          !f.nil? && f.match?(route[:prefix_len])
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
            matches = %w[exact orlonger longer upto].select { |m| f[m] }.map(&:to_sym)
            matches = [:exact] if matches.empty?
            Filter.new(n, len.to_i, matches, f['upto'])
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
