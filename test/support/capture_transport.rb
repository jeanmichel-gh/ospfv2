# frozen_string_literal: true

# A transport that records what a Neighbor sends instead of putting it on
# the wire. Packets can be injected with #inject.
class CaptureTransport
  attr_reader :address, :sent

  def initialize(address = '10.0.0.1')
    @address = address
    @sent = []
  end

  def start(&on_packet)
    @on_packet = on_packet
    self
  end

  def send_packet(bytes, dest)
    @sent << [OSPFv2::OspfPacket.factory(bytes), dest]
  end

  def inject(packet, from)
    @on_packet.call(packet.encode, from)
  end

  def stop; end

  def packets(klass = nil)
    @sent.map(&:first).select { |p| klass.nil? || p.is_a?(klass) }
  end
end
