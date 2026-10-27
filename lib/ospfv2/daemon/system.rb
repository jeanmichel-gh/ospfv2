# frozen_string_literal: true

require 'socket'

module OSPFv2
  class Daemon
    # The host's interfaces and their IPv4 addresses, from getifaddrs.
    # Tests swap in a Hash-backed fake.
    class System
      Link = Struct.new(:name, :address, :up, :others, keyword_init: true)

      # { "eth1" => Link(address: "10.0.12.1/24", up: true, others: [...]) }
      # +address+ is the first IPv4 address outside 127/8 (127.0.0.1 only
      # when there is nothing else); +others+ holds the rest.
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
          [name, Link.new(name: name, address: addrs.first, up: e[:up], others: addrs.drop(1))]
        end
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
      def set(name, address, up: true)
        @links[name] = System::Link.new(name: name, address: address, up: up, others: [])
      end

      def remove(name) = @links.delete(name)
      def links = @links.dup
    end
  end
end
