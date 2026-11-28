# frozen_string_literal: true

require 'socket'

module OSPFv2
  class Daemon
    # The host's interfaces, their IPv4 addresses and MTUs, from
    # getifaddrs and /sys/class/net. Tests swap in a Hash-backed fake.
    class System
      Link = Struct.new(:name, :address, :up, :others, :mtu, keyword_init: true)

      SYS_NET = '/sys/class/net'

      # { "eth1" => Link(address: "10.0.12.1/24", up: true, others: [...], mtu: 1500) }
      # +address+ is the first IPv4 address outside 127/8 (127.0.0.1 only
      # when there is nothing else); +others+ holds the rest. +mtu+ is nil
      # where the kernel does not say.
      def links
        found = Hash.new { |h, k| h[k] = { addrs: [], up: false } }
        Socket.getifaddrs.each do |ifa|
          entry = found[ifa.name]
          entry[:up] ||= (ifa.flags & Socket::IFF_UP) != 0
          next unless ifa.addr&.ipv4? && ifa.netmask
          len = ifa.netmask.ip_address.split('.').sum { |o| o.to_i.to_s(2).count('1') }
          entry[:addrs] << "#{ifa.addr.ip_address}/#{len}"
        end
        found.to_h do |name, e|
          addrs = e[:addrs].partition { |a| !a.start_with?('127.') }.flatten
          [name, Link.new(name: name, address: addrs.first, up: e[:up], others: addrs.drop(1), mtu: mtu(name))]
        end
      end

      def mtu(name)
        return nil if name.include?('/')
        Integer(File.read(File.join(SYS_NET, name, 'mtu')).strip)
      rescue SystemCallError, ArgumentError
        nil
      end

      PROC_MPLS = '/proc/sys/net/mpls'

      # Makes the host take label routes for +interfaces+, as isisd's
      # Router::Host#mpls does: MPLS input on each (net.mpls.conf.IF.input),
      # and a check that net.mpls.platform_labels is past +highest+.
      # Returns nil when it can, else why not. The mpls_router module and
      # the size of the label table are the host's to set.
      def mpls(interfaces, highest:, proc_mpls: PROC_MPLS)
        table = File.join(proc_mpls, 'platform_labels')
        return "#{table} is missing: is the mpls_router module loaded?" unless File.exist?(table)
        size = Integer(File.read(table).strip)
        return "net.mpls.platform_labels is #{size}, and labels go up to #{highest}" if size <= highest
        interfaces.each do |name|
          path = File.join(proc_mpls, 'conf', name, 'input')
          File.write(path, "1\n") if File.exist?(path)
        end
        nil
      rescue SystemCallError, ArgumentError => e
        "the MPLS settings cannot be written: #{e.message}"
      end

      STATIC_PROTOCOLS = [3, 4].freeze # RTPROT_BOOT (ip route add), RTPROT_STATIC

      # Static routes in the main table, as [prefix, prefix_len] Integers;
      # nil when the kernel cannot be read.
      def static_routes
        require_relative '../fib/netlink'
        nl = Fib::Netlink.new
        begin
          nl.dump(protocols: STATIC_PROTOCOLS).map { |r| [r.prefix, r.prefix_len] }
        ensure
          nl.close
        end
      rescue StandardError
        nil
      end
    end

    # A fixed set of links, for tests and the offline demo.
    class FakeSystem
      attr_accessor :statics

      def initialize(links = {})
        @links = links
        @statics = []
      end

      def static_routes = @statics.dup

      # set('eth1', '10.0.0.1/24'), set('eth1', nil) to remove the address
      def set(name, address, up: true, mtu: nil)
        @links[name] = System::Link.new(name: name, address: address, up: up, others: [], mtu: mtu)
      end

      def remove(name) = @links.delete(name)

      # What mpls answers: nil (it can), or why not. +mpls_calls+ records
      # what was asked.
      attr_accessor :mpls_answer
      attr_reader :mpls_calls

      def mpls(interfaces, highest:)
        (@mpls_calls ||= []) << [interfaces, highest]
        @mpls_answer
      end
      def links = @links.dup
    end
  end
end
