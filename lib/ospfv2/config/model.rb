# frozen_string_literal: true

require_relative 'tree'

module OSPFv2
  module Config
    # What a configuration means for the router: its id and its OSPF
    # interfaces, checked as a whole. Building a Model is the commit check.
    #
    #   m = Model.new(tree)        # raises Config::Error listing every problem
    #   m.router_id                # => "1.1.1.1"
    #   m.interfaces["eth1"]       # => { area: "0.0.0.0", type: :p2p, cost: 10, auth: {...}, ... }
    class Model
      # Config words to Core::Interface options.
      OPTIONS = {
        'interface-type' => :type, 'metric' => :cost, 'priority' => :priority,
        'hello-interval' => :hello_interval, 'dead-interval' => :dead_interval,
        'retransmit-interval' => :rxmt_interval, 'transit-delay' => :transmit_delay,
        'mtu' => :mtu
      }.freeze

      DEFAULT_HELLO = 10 # as Core::Interface; checked by a test

      # Kernel route install defaults (routing-options kernel).
      KERNEL = { install: true, metric: 20, protocol: 89, table: 254 }.freeze
      KERNEL_TABLES = { 253 => 'default', 255 => 'local' }.freeze
      # Protocol ids others use (Linux rtnetlink.h and FRR). Routes under
      # our id are ours to delete, so these are refused.
      TAKEN_PROTOCOLS = {
        8 => 'gated', 9 => 'router advertisements', 10 => 'mrt', 11 => 'zebra', 12 => 'bird',
        13 => 'dnrouted', 14 => 'xorp', 15 => 'ntk', 16 => 'dhcp', 17 => 'mrouted', 18 => 'keepalived',
        42 => 'babel', 99 => 'openr', 186 => 'bgp', 187 => 'isis', 188 => 'ospf (FRR)', 189 => 'rip',
        192 => 'eigrp', 193 => 'ldp (FRR)', 194 => 'sharp (FRR)', 195 => 'pbr (FRR)', 196 => 'static (FRR)',
        197 => 'openfabric (FRR)', 198 => 'srte (FRR)'
      }.freeze

      attr_reader :router_id, :interfaces, :warnings, :kernel

      def initialize(tree)
        @errors = []
        @warnings = []
        data = tree.data
        @router_id = data.dig('routing-options', 'router-id')
        @errors << 'routing-options router-id is required' unless @router_id
        @interfaces = {}
        areas = data.dig('protocols', 'ospf', 'area') || {}
        areas.each do |area, a|
          (a['interface'] || {}).each { |name, i| interface(area, name, i) }
        end
        @kernel = kernel_options(data.dig('routing-options', 'kernel') || {})
        @warnings << 'no OSPF interfaces configured' if @interfaces.empty? && @errors.empty?
        raise Error, @errors.join("\n") unless @errors.empty?
        freeze
      end

      private

      def interface(area, name, i)
        if (other = @interfaces[name])
          @errors << "interface #{name} is in area #{other[:area]} and area #{area}; an interface belongs to one area"
          return
        end
        if i['disable']
          @warnings << "interface #{name} is disabled"
          return
        end
        opts = { area: area }
        OPTIONS.each { |word, key| opts[key] = i[word] if i.key?(word) }
        opts[:type] = opts[:type]&.to_sym || :broadcast
        opts[:mtu_ignore] = true if i['mtu-ignore']
        opts[:passive] = true if i['passive']
        hello = opts[:hello_interval] || DEFAULT_HELLO
        if opts[:dead_interval] && opts[:dead_interval] <= hello
          @errors << "interface #{name}: dead-interval #{opts[:dead_interval]} must be above hello-interval #{hello}"
        end
        auth = authentication(name, i['authentication'])
        opts[:auth] = auth if auth
        @interfaces[name] = opts.freeze
      end

      def kernel_options(k)
        out = KERNEL.merge(k.slice('metric', 'protocol', 'table').transform_keys(&:to_sym))
        out[:install] = false if k['no-install']
        if (name = KERNEL_TABLES[out[:table]])
          @errors << "routing-options kernel table #{out[:table]} is the kernel's #{name} table; pick another"
        end
        if (who = TAKEN_PROTOCOLS[out[:protocol]])
          @errors << "routing-options kernel protocol #{out[:protocol]} is #{who}'s; pick an unused id"
        end
        out.freeze
      end

      def authentication(name, a)
        return nil if a.nil? || a.empty?
        keys = []
        Schema::AUTH_ALGORITHMS.each do |word, algo|
          (a[word] || {}).each { |id, secret| keys << { id: id, algorithm: algo, secret: secret } }
        end
        password = a['simple-password']
        if password && !keys.empty?
          @errors << "interface #{name}: use either simple-password or keys, not both"
          return nil
        end
        dup = keys.group_by { |k| k[:id] }.select { |_, v| v.size > 1 }.keys
        @errors << "interface #{name}: key id #{dup.join(', ')} used by two algorithms" unless dup.empty?
        send_key = a['send-key']
        if send_key && keys.none? { |k| k[:id] == send_key }
          @errors << "interface #{name}: send-key #{send_key} is not a configured key"
        end
        return { type: :simple, password: password } if password
        if keys.empty?
          @errors << "interface #{name}: send-key without keys" if send_key
          return nil
        end
        { type: :crypto, keys: keys, send_key: send_key }.compact
      end
    end
  end
end
