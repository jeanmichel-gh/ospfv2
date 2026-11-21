# frozen_string_literal: true

require 'bfd/client' # BFD::Client::Event, the events a real client polls

# Stands in for bfd4r's BFD::Client: keeps what the router wants and
# answers poll with what the test queued. No socket, no bfdd4r.
#
#   bfd = FakeBfdClient.new
#   bfd.up('eth0', '10.0.0.2')      # queue: down -> up
#   bfd.failure('eth0', '10.0.0.2') # queue: up -> down, diag control_detection_time_expired
class FakeBfdClient
  attr_reader :wanted, :calls, :name

  def initialize(name = 'ospfd')
    @name = name
    @wanted = {}   # [interface, peer] => params
    @calls = []    # [:want, params] or [:drop, key]
    @queue = []
    @states = {}
    @polls = []
  end

  # When each poll ran, by the clock the router gave it.
  attr_reader :polls

  def want(interface:, peer:, local:, **timers)
    params = { interface: interface, peer: peer, local: local, **timers }
    @wanted[[interface, peer]] = params
    @calls << [:want, params]
    self
  end

  def drop(interface:, peer:)
    @wanted.delete([interface, peer])
    @states.delete([interface, peer])
    @calls << [:drop, [interface, peer]]
    self
  end

  def wanted?(interface:, peer:) = @wanted.key?([interface, peer])
  def connected? = true
  def ios = []
  def close(release: false)
    @closed = true
    nil
  end

  def closed? = @closed == true

  def poll(now)
    @polls << now
    out = @queue
    @queue = []
    out
  end

  # Queues a state change for a session, as the real client tells it.
  def state(interface, peer, to, diag: nil)
    key = [interface, peer]
    from = @states[key]
    @states[key] = to
    @queue << BFD::Client::Event.new(type: :state, interface: interface, peer: peer, state: to, from: from, diag: diag)
  end

  def up(interface, peer) = state(interface, peer, :up)
  def failure(interface, peer) = state(interface, peer, :down, diag: :control_detection_time_expired)

  # The peer said AdminDown: what the real client makes of the event
  # bfdd4r sends then (BFD::Client.state_of).
  def remote_admin_down(interface, peer)
    to = BFD::Client.state_of('to' => 'down', 'remote_state' => 'admin_down')
    state(interface, peer, to, diag: :neighbor_signaled_session_down)
  end

  def lost(message = 'bfdd4r closed the connection')
    @states.clear
    @queue << BFD::Client::Event.new(type: :lost, message: message)
  end

  def connected
    @queue << BFD::Client::Event.new(type: :connected, message: 'bfdd4r answers on @bfdd4r')
  end

  # Takes the queued events, for a test that hands them on itself.
  def take = poll(nil).tap { @polls.pop }
end
