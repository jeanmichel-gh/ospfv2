# frozen_string_literal: true

require 'socket'
require 'ipaddr'
require_relative 'ospf_constants'

module OSPFv2
  # Raised when raw sockets cannot be opened (not root, no CAP_NET_RAW).
  class PermissionError < StandardError; end

  # How a Neighbor puts packets on the wire.
  #
  # A transport has an #address, takes a block in #start that is called
  # with (ospf_bytes, source_ip) for every OSPF packet received from
  # someone else, sends with #send_packet(bytes, destination_ip), and
  # releases its resources in #stop.
  module Transport
    MULTICAST = [OSPFv2::AllSPFRouters, OSPFv2::AllDRouters].freeze

    # IP protocol 89 raw socket. Needs root or CAP_NET_RAW.
    class RawSocket
      attr_reader :address

      # address:   IPv4 address of the local interface (no prefix length).
      # interface: optional device name to bind to (SO_BINDTODEVICE).
      def initialize(address, interface: nil)
        @address = address
        @interface = interface
        @thread = nil
      end

      def start(&on_packet)
        raise ArgumentError, 'block required' unless on_packet
        @sock = open_socket
        @thread = Thread.new do
          Thread.current.name = 'ospfv2-rx'
          receive_loop(on_packet)
        end
        self
      end

      def send_packet(bytes, dest)
        @sock&.send(bytes, 0, Socket.pack_sockaddr_in(0, dest))
      rescue SystemCallError => e
        warn "ospfv2: send to #{dest} failed: #{e.message}"
      end

      def stop
        @thread&.kill
        @thread = nil
        @sock&.close unless @sock&.closed?
        @sock = nil
      end

      private

      def open_socket
        sock = Socket.open(Socket::PF_INET, Socket::SOCK_RAW, IPPROTO_OSPF)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BINDTODEVICE, @interface) if @interface
        local = IPAddr.new(@address).hton
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_IF, local)
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, [1].pack('C'))
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_LOOP, [0].pack('C'))
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_TOS, [0xc0].pack('C')) # internetwork control
        MULTICAST.each do |group|
          sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, IPAddr.new(group).hton + local)
        end
        sock
      rescue Errno::EPERM, Errno::EACCES
        sock&.close
        raise PermissionError, 'raw sockets need root or CAP_NET_RAW (docker: --cap-add NET_RAW)'
      rescue Errno::EADDRNOTAVAIL, Errno::ENODEV => e
        sock&.close
        raise ArgumentError, "cannot use address #{@address}#{" on #{@interface}" if @interface}: #{e.message}"
      end

      def receive_loop(on_packet)
        loop do
          data, sender = @sock.recvfrom(65_535)
          _, from = Socket.unpack_sockaddr_in(sender)
          next if from == @address
          payload = strip_ip_header(data)
          on_packet.call(payload, from) if payload
        end
      rescue IOError, Errno::EBADF
        # socket closed by #stop
      end

      # Linux hands IPv4 raw sockets the IP header. Use IHL rather than
      # assuming 20 bytes, and only keep protocol 89.
      def strip_ip_header(data)
        return if data.bytesize < 20
        ihl = (data.getbyte(0) & 0x0f) * 4
        return unless data.getbyte(9) == IPPROTO_OSPF
        data.byteslice(ihl..)
      end
    end

    # An in-memory broadcast segment. Transports attached to the same hub
    # see each other's multicast and unicast packets. Used by the tests
    # and by the offline demo.
    class Hub
      def initialize
        @members = []
        @lock = Mutex.new
        @drop = nil
      end

      def attach(member)
        @lock.synchronize { @members << member unless @members.include?(member) }
      end

      def detach(member)
        @lock.synchronize { @members.delete(member) }
      end

      # Optional filter to simulate loss: ->(bytes, from, dest) { true to drop }
      def drop_if(&filter)
        @drop = filter
      end

      def deliver(bytes, from, dest)
        return if @drop&.call(bytes, from, dest)
        targets = @lock.synchronize { @members.dup }
        targets.each do |m|
          next if m.address == from
          next unless MULTICAST.include?(dest) || m.address == dest
          m.receive(bytes.dup, from)
        end
      end
    end

    class Loopback
      attr_reader :address, :hub

      def initialize(hub, address)
        @hub = hub
        @address = address
        @on_packet = nil
      end

      def start(&on_packet)
        @on_packet = on_packet
        @hub.attach(self)
        self
      end

      def send_packet(bytes, dest)
        @hub.deliver(bytes, @address, dest)
      end

      def receive(bytes, from)
        @on_packet&.call(bytes, from)
      end

      def stop
        @hub.detach(self)
        @on_packet = nil
      end
    end
  end
end
