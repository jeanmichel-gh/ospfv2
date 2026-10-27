# frozen_string_literal: true

require 'ospfv2/core'

# Routers on in-memory segments, all driven by one fake-clock loop.
#
#   lab = CoreLab.new
#   lan = lab.segment
#   r1 = lab.router('1.1.1.1', [lan, '10.0.0.1/24'])
#   r2 = lab.router('2.2.2.2', [lan, '10.0.0.2/24', { priority: 0 }])
#   lab.start
#   lab.run_until(60) { lab.full?(r1, r2) }
class CoreLab
  include OSPFv2

  attr_reader :loop, :log, :routers

  def initialize(seed: 1)
    @seed = seed
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e }, random: Random.new(seed))
    @routers = []
    @log = []
  end

  def segment
    Transport::Hub.new
  end

  # Each link is [hub, 'address/len', options] or [:passive, 'address/len'].
  def router(rid, *links, start: false)
    r = Core::Instance.new(router_id: rid, loop: @loop, random: Random.new(@seed + @routers.size),
                           logger: ->(level, msg) { @log << "#{rid} #{msg}" unless level == :debug })
    links.each_with_index do |(hub, addr, opts), i|
      opts ||= {}
      ip = addr.split('/').first
      if hub == :passive
        r.add_interface(name: "lo#{i}", address: addr, passive: true, **opts)
      else
        r.add_interface(name: "eth#{i}", address: addr, transport: Transport::Loopback.new(hub, ip), **opts)
      end
    end
    @routers << r
    r.start if start
    r
  end

  def start
    @routers.each(&:start)
    self
  end

  def run_until(timeout, &block)
    @loop.run_until(timeout, step: 0.5, &block)
  rescue EventLoop::Stalled
    raise EventLoop::Stalled, "#{$!.message}\n#{@log.last(40).join("\n")}"
  end

  def advance(seconds)
    @loop.advance(seconds)
  end

  def neighbor(r, rid)
    r.neighbors.find { |n| n.router_id == Core::Addr.to_i(rid) }
  end

  # Every router adjacent to every other one it should be.
  def full?(*rs)
    rs.combination(2).all? do |a, b|
      [neighbor(a, b.router_id_s), neighbor(b, a.router_id_s)].all? { |n| n&.full? }
    end
  end

  def states(r)
    r.neighbors.to_h { |n| [Core::Addr.to_s(n.router_id), n.state] }
  end

  # [type, ls_id, advr, seq, checksum] for every LSA, sorted.
  def db_keys(r)
    r.database.map { |_, l| l.key + [l.seq, l.checksum] }.sort
  end

  def synced?(*rs)
    rs.map { |r| db_keys(r) }.uniq.size == 1
  end

  # Nothing left to retransmit or request anywhere.
  def quiet?(*rs)
    rs.all? { |r| r.neighbors.all? { |n| n.retransmit.empty? && n.ls_request.empty? } }
  end

  # Runs until +pairs+ are full and every router holds the same database.
  # Updates that land within MinLSArrival of the last one are dropped and
  # retransmitted RxmtInterval later (RFC 2328 13), so this can take a
  # few seconds past Full.
  def converge(rs, adjacent: [rs], timeout: 120)
    run_until(timeout) do
      adjacent.all? { |set| full?(*set) } && synced?(*rs) && quiet?(*rs)
    end
  end

  def lsa(r, type, ls_id, advr = ls_id)
    key = [type, Core::Addr.to_i(ls_id), Core::Addr.to_i(advr)]
    r.database.map(&:last).find { |l| l.key == key }
  end
end
