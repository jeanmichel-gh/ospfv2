# frozen_string_literal: true

module OSPFv2
  # Reads the classic pcap format (as tcpdump -w writes it) from an IO, one
  # record at a time, so it works on a live pipe.
  #
  #   r = Pcap::Reader.new($stdin)
  #   r.link                          # => 1 (Ethernet)
  #   r.each { |rec| rec.time; rec.data; rec.length }
  module Pcap
    class Error < StandardError; end

    Record = Struct.new(:time, :data, :length, keyword_init: true)

    class Reader
      MAGIC = { 0xa1b2c3d4 => 1_000_000, 0xa1b23c4d => 1_000_000_000 }.freeze
      MAX_RECORD = 262_144

      attr_reader :link, :snaplen

      def initialize(io)
        @io = io
        head = read(24) or raise Error, 'no pcap header: the capture produced nothing'
        magic = head.unpack1('V')
        @order = MAGIC.key?(magic) ? 'V' : 'N'
        magic = head.unpack1(@order)
        @frac = MAGIC[magic] or raise Error, format('not a pcap stream (magic 0x%08x)', magic)
        _maj, _min, _zone, _sig, @snaplen, @link = head.byteslice(4..).unpack(@order == 'V' ? 'vvVVVV' : 'nnNNNN')
      end

      def each
        return enum_for(:each) unless block_given?
        while (rec = self.next)
          yield rec
        end
      end

      # The next record, or nil at the end of the stream.
      def next
        h = read(16) or return nil
        sec, frac, incl, orig = h.unpack(@order * 4)
        raise Error, "record of #{incl} bytes: the stream is damaged" if incl > MAX_RECORD
        data = read(incl) or return nil
        Record.new(time: Time.at(sec, frac * (1_000_000_000 / @frac), :nsec), data: data, length: orig)
      end

      private

      def read(n)
        return ''.b if n.zero?
        buf = @io.read(n)
        buf && buf.bytesize == n ? buf.b : nil
      end
    end
  end
end
