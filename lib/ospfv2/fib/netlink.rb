# frozen_string_literal: true

require 'socket'
require_relative '../fib'

module OSPFv2
  module Fib
    # The Linux kernel routing table over rtnetlink, in plain Ruby.
    #
    #   nl = Fib::Netlink.new(protocol: 89, table: 254)
    #   nl.add(Fib::Route.new(prefix, 24, [['eth1', gateway]], 20))
    #   nl.dump     # our routes: this protocol id, this table
    #   nl.delete(route)
    #
    # Our routes carry their own protocol id (rtm_protocol), 89 by default
    # (OSPF's IP protocol number, unused by other daemons: FRR's ospfd is
    # 188), so we only ever see and touch our own. A new route goes in with
    # NLM_F_EXCL, so it never overwrites someone else's route to the same
    # prefix at the same metric; only a route already ours is replaced.
    # Equal-cost next hops go in as one multipath route. IPv4 only. Needs
    # CAP_NET_ADMIN.
    class Netlink
      AF_NETLINK = 16
      NETLINK_ROUTE = 0

      RTM_NEWROUTE = 24
      RTM_DELROUTE = 25
      RTM_GETROUTE = 26
      NLMSG_ERROR = 2
      NLMSG_DONE = 3

      NLM_F_REQUEST = 0x1
      NLM_F_MULTI = 0x2
      NLM_F_ACK = 0x4
      NLM_F_REPLACE = 0x100
      NLM_F_EXCL = 0x200
      NLM_F_CREATE = 0x400
      NLM_F_DUMP = 0x300

      RTA_DST = 1
      RTA_OIF = 4
      RTA_GATEWAY = 5
      RTA_PRIORITY = 6
      RTA_MULTIPATH = 9
      RTA_TABLE = 15

      RTN_UNICAST = 1
      RT_SCOPE_UNIVERSE = 0

      RECV = 1 << 16
      LINKS_TTL = 30 # seconds the interface index map is trusted

      attr_reader :protocol, :table

      # protocol: our rtm_protocol id, 1..255 but not one the kernel uses
      # table:    routing table id, 254 is main
      # links:    ->() { { "eth1" => ifindex } }, getifaddrs by default
      def initialize(protocol: 89, table: 254, links: nil)
        raise ArgumentError, "protocol #{protocol} is the kernel's own (5..255 allowed)" unless protocol.between?(5, 255)
        raise ArgumentError, "table #{table} out of range" unless table.between?(1, 0xffff_ffff)
        @protocol = protocol
        @table = table
        @links_source = links || method(:host_links)
        @links_map = nil
        @links_at = nil
        @seq = 0
        @lock = Mutex.new
        @sock = Socket.new(AF_NETLINK, Socket::SOCK_RAW, NETLINK_ROUTE)
        begin
          @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1 << 21)
          @sock.bind([AF_NETLINK, 0, 0, 0].pack('SSLL'))
        rescue StandardError
          @sock.close
          raise
        end
      end

      # A route new to us. Refused (Fib::Error) if the kernel already has a
      # route to the prefix at this metric, whoever it belongs to.
      def add(route)
        request(RTM_NEWROUTE, NLM_F_CREATE | NLM_F_EXCL, encode(route, hops: true))
      rescue Error => e
        raise unless e.message.start_with?('File exists')
        raise Error, "another route to #{route.dest_s} with metric #{route.metric} is in the kernel"
      end

      # A route that is ours already. If it has gone, it is added again.
      def replace(route)
        request(RTM_NEWROUTE, NLM_F_REPLACE, encode(route, hops: true))
      rescue Error => e
        raise unless e.message.start_with?('No such file or directory')
        add(route)
      end

      def delete(route)
        request(RTM_DELROUTE, 0, encode(route, hops: false))
      rescue Error => e
        raise unless e.message.start_with?('No such process') # ESRCH: gone already
      end

      # Our routes in our table, as Fib::Routes.
      def dump
        names = links(fresh: true).invert
        msgs = @lock.synchronize do
          seq = send_msg(RTM_GETROUTE, NLM_F_DUMP, rtmsg(0, 0, 0))
          collect(seq)
        end
        msgs.filter_map { |type, body| decode(body, names) if type == RTM_NEWROUTE }
      end

      def close
        @sock.close unless @sock.closed?
      end

      private

      # ---- encoding ----

      def rtmsg(dst_len, table, protocol, type: 0, scope: 0)
        [Socket::AF_INET, dst_len, 0, 0, table < 256 ? table : 252, protocol, scope, type, 0].pack('CCCCCCCCL')
      end

      def attr(type, data)
        len = 4 + data.bytesize
        [len, type].pack('SS') + data + ("\0" * pad(len))
      end

      def pad(len) = (4 - (len % 4)) % 4

      def encode(route, hops:)
        body = rtmsg(route.prefix_len, @table, @protocol, type: RTN_UNICAST, scope: RT_SCOPE_UNIVERSE)
        body << attr(RTA_TABLE, [@table].pack('L'))
        body << attr(RTA_DST, [route.prefix].pack('N'))
        body << attr(RTA_PRIORITY, [route.metric].pack('L'))
        return body unless hops
        index = lambda do |name|
          links[name] || links(fresh: true)[name] || raise(Error, "no interface #{name}")
        end
        if route.next_hops.size == 1
          ifname, gw = route.next_hops.first
          body << attr(RTA_GATEWAY, [gw].pack('N')) if gw
          body << attr(RTA_OIF, [index.call(ifname)].pack('l'))
        else
          nh = route.next_hops.map do |ifname, gw|
            sub = gw ? attr(RTA_GATEWAY, [gw].pack('N')) : ''.b
            [8 + sub.bytesize, 0, 0, index.call(ifname)].pack('SCCl') + sub
          end.join
          body << attr(RTA_MULTIPATH, nh)
        end
        body
      end

      # ---- talking to the kernel ----

      def request(type, flags, body)
        @lock.synchronize do
          seq = send_msg(type, flags | NLM_F_ACK, body)
          collect(seq)
        end
        nil
      end

      def send_msg(type, flags, body)
        @seq = (@seq + 1) & 0xffff_ffff
        msg = [16 + body.bytesize, type, flags | NLM_F_REQUEST, @seq, 0].pack('LSSLL') + body
        @sock.send(msg, 0, [AF_NETLINK, 0, 0, 0].pack('SSLL'))
        @seq
      rescue SystemCallError => e
        raise Error, e.message
      end

      # Reads replies to +seq+ until the ack, an error or the end of a dump.
      def collect(seq)
        out = []
        loop do
          data = @sock.recv(RECV)
          off = 0
          while off + 16 <= data.bytesize
            len, type, flags, mseq, = data.byteslice(off, 16).unpack('LSSLL')
            break if len < 16
            body = data.byteslice(off + 16, len - 16)
            off += len + pad(len)
            next unless mseq == seq
            case type
            when NLMSG_ERROR
              err = body.unpack1('l')
              raise Error, SystemCallError.new(nil, -err).message.sub(/ - .*\z/, '') unless err.zero?
              return out
            when NLMSG_DONE
              return out
            else
              out << [type, body]
              return out if (flags & NLM_F_MULTI).zero?
            end
          end
        end
      rescue SystemCallError => e
        raise Error, e.message
      end

      # ---- decoding a route ----

      def decode(body, names)
        family, dst_len, _, _, table, protocol, _, type, = body.unpack('CCCCCCCCL')
        return nil unless family == Socket::AF_INET && protocol == @protocol && type == RTN_UNICAST
        attrs = attrs(body.byteslice(12..))
        table = attrs[RTA_TABLE].unpack1('L') if attrs[RTA_TABLE]
        return nil unless table == @table
        prefix = attrs[RTA_DST] ? attrs[RTA_DST].unpack1('N') : 0
        metric = attrs[RTA_PRIORITY] ? attrs[RTA_PRIORITY].unpack1('L') : 0
        hops = if attrs[RTA_MULTIPATH]
                 multipath(attrs[RTA_MULTIPATH], names)
               else
                 oif = attrs[RTA_OIF]&.unpack1('l')
                 [[names.fetch(oif, "if#{oif}"), attrs[RTA_GATEWAY]&.unpack1('N')]]
               end
        Route.new(prefix, dst_len, hops, metric)
      end

      def attrs(data)
        out = {}
        off = 0
        while off + 4 <= data.bytesize
          len, type = data.byteslice(off, 4).unpack('SS')
          break if len < 4
          out[type & 0x3fff] = data.byteslice(off + 4, len - 4)
          off += len + pad(len)
        end
        out
      end

      def multipath(data, names)
        hops = []
        off = 0
        while off + 8 <= data.bytesize
          len, _, _, ifindex = data.byteslice(off, 8).unpack('SCCl')
          break if len < 8
          sub = attrs(data.byteslice(off + 8, len - 8))
          hops << [names.fetch(ifindex, "if#{ifindex}"), sub[RTA_GATEWAY]&.unpack1('N')]
          off += len + pad(len)
        end
        hops
      end

      # Interface name => index, cached: one getifaddrs per route would be
      # two netlink dumps per route.
      def links(fresh: false)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if fresh || @links_map.nil? || now - @links_at > LINKS_TTL
          @links_map = @links_source.call
          @links_at = now
        end
        @links_map
      end

      # Device names only: an address label such as eth1:vip shares its
      # device's index and is not a device.
      def host_links
        Socket.getifaddrs.each_with_object({}) do |ifa, h|
          next if ifa.name.include?(':')
          h[ifa.name] = ifa.ifindex
        end
      end
    end
  end
end
