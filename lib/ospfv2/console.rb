# frozen_string_literal: true

module OSPFv2
  # Interactive commands, available in the irb session started by
  # `ospfv2 run` (type `help`). Every command is a plain method, so the
  # same calls work from scripts:
  #
  #   c = OSPFv2::Console.new(sim)
  #   c.down 'r1c1--r1c2'
  class Console
    attr_reader :sim

    def initialize(sim, out: $stdout)
      @sim = sim
      @out = out
    end

    def help
      @out.puts <<~TXT
        state                      neighbor state and counters
        lsdb [:junos|:ios|:plain]  print the link state database (lsdb! for verbose)
        lsa :router, id, advr      one LSA, verbose
        links [filter]             links with their id and state
        down LINK / up LINK        take a link down or up (id or "a--b")
        toggle LINK                flip a link
        flap LINK, count: 3, interval: 5
        refresh                    re-originate every simulated LSA
        flush                      MaxAge every simulated LSA
        aging on|off               let LSA ages grow, or freeze them
        events [n]                 last n events
        sim, ls_db, neighbor, topology   the underlying objects
      TXT
      nil
    end

    def state
      n = sim.neighbor.to_hash
      @out.puts "#{n[:state].to_s.upcase.ljust(9)} #{n[:router_id]} #{n[:address]}/#{n[:netmask]} area #{n[:area_id]}"
      @out.puts "neighbor  #{n[:neighbor_router_id] || '-'} at #{n[:neighbor_ip] || '-'}, DR #{n[:designated_router]}"
      c = sim.snapshot[:counts]
      @out.puts "lsdb      #{c[:total]} LSAs (#{c.except(:total, :unacked).map { |k, v| "#{v} #{k}" }.join(', ')}), #{c[:unacked]} not acked"
      nil
    end

    def lsdb(format = :junos)
      @out.puts sim.lsdb_text(format)
      nil
    end

    def lsdb!(format = :junos)
      @out.puts sim.lsdb_text(format, verbose: true)
      nil
    end

    def lsa(type, ls_id, advr = ls_id)
      l = sim.lsa(type, ls_id, advr) or return @out.puts('not found')
      @out.puts l.to_s_junos_verbose
      nil
    end

    def links(filter = nil)
      sim.links.each do |l|
        next if filter && !l.name.include?(filter.to_s)
        @out.puts format('%4d  %-24s %-5s metric %-5d %s', l.id, l.name, l.up? ? 'up' : 'DOWN', l.spec.metric, l.lsdb_link.network_to_s)
      end
      nil
    end

    def down(link) = report(sim.link_down(link))
    def up(link) = report(sim.link_up(link))
    def toggle(link) = report(sim.toggle_link(link))

    def flap(link, count: 3, interval: 5)
      sim.flap(link, count: count, interval: interval)
      @out.puts "flapping #{sim.link(link).name} #{count} times"
      nil
    end

    def refresh
      @out.puts "re-originated #{sim.refresh_all.size} LSAs"
    end

    def flush
      sim.flush_all
      @out.puts 'flushed'
    end

    def aging(on = nil)
      sim.aging = (on.nil? ? !sim.aging? : on.to_s == 'on')
      @out.puts "aging #{sim.aging? ? 'on' : 'off'}"
    end

    def events(n = 20)
      sim.events.last(n).each { |e| @out.puts "#{e.time} #{e.kind.to_s.ljust(8)} #{e.text}" }
      nil
    end

    def ls_db = sim.ls_db
    def neighbor = sim.neighbor
    def topology = sim.topology

    # irb with this object as self, so `state`, `down 3`... just work.
    def start_irb
      require 'irb'
      @out.puts "ospfv2 console. Type `help` for commands, `exit` to quit."
      IRB.setup(nil, argv: [])
      IRB.conf[:PROMPT][:OSPF] = { PROMPT_I: 'ospf> ', PROMPT_S: 'ospf* ', PROMPT_C: 'ospf* ', RETURN: "=> %s\n" }
      IRB.conf[:PROMPT_MODE] = :OSPF
      workspace = IRB::WorkSpace.new(binding)
      irb = IRB::Irb.new(workspace)
      IRB.conf[:MAIN_CONTEXT] = irb.context
      irb.run(IRB.conf)
    end

    def inspect = "#<OSPFv2::Console #{sim.neighbor.state}>"

    private

    def report(link)
      @out.puts "#{link.id} #{link.name} #{link.up? ? 'up' : 'down'}"
    end
  end
end
