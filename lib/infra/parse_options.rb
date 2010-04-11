require 'optparse'
require 'ostruct'

require 'ie/id'

class OptParse
  def self.parse(args)

    options = OpenStruct.new
    options.ipaddr = '192.168.1.123'
    options.network = '192.168.1.0'
    options.netmask = '255.255.255.0'
    options.base_link_addr = '1.3.0.0/30'
    options.base_router_id = 0
    options.hello_int = 10
    options.router_id = 1
    options.neighbor_id = 2
    options.area_id = 0
    options.log_fname = $stdout
    options.grid = [2,2]
    options.num_sum = 10
    options.num_ext = 10

    options.parse  = Proc.new do |filename|
      y_conf = YAML::load_file(filename)
      y_conf.keys.each do |k|
        case k.downcase
        when "key1"
        when "key2"
        end
      end
      options
    end

    to_ip = lambda { |id| [id].pack('N').unpack('C*').join('.') }
    to_id = lambda { |x| OSPFv2::Id.to_i(x) }
    dead_int = lambda { @dead_int || (options.hello_int * 4)}

    option_help = "blabla ...."
    hlp_address =    "IP Address of the OSPF Interface."
    hlp_base_link_addr = "base p2p links addres [#{options.base_link_addr}]"
    hlp_base_router_id   = "base router-id [#{to_ip.call(options.base_router_id)}]"
    hlp_neighbor_id= "Neighbor Id. [#{to_ip.call(options.neighbor_id)}]"
    hlp_router_id =  "Router Id.   [#{to_ip.call(options.router_id)}]"
    hlp_area_id =    "Area Id.     [#{to_ip.call(options.area_id)}]"
    hlp_grid =       "Area Grid.   [#{options.grid.join('x')}]"
    hlp_hello_int =  "Hello Int.   [#{options.hello_int}]"
    hlp_dead_int =   "Dead Int.    [#{dead_int.call}]"
    hlp_sum =        "\#Summary.   [#{options.num_sum}]"
    hlp_ext =        "\#External.  [#{options.num_ext}]"

    optparse = OptionParser.new do |opts|

      opts.banner = "Usage: #{$0} [options]"

      opts.on( "--base-p2p-addr [PREFIX]", hlp_base_link_addr) { |x| 
        options.base_link_addr = x
      }
      opts.on("-i", "--address [PREFIX]", hlp_address) { |x| 
        options.ipaddr = x
        options.ipaddr = x.split('/')[0]
        _addr = IPAddr.new x
        options.network = _addr.to_s
        options.netmask = _addr.netmask
      }
      opts.on("--base-router-id [ID]", hlp_base_router_id) { |id| 
        options.base_router_id = id.to_i
      }
      opts.on("-r", "--router-id [ID]", hlp_router_id) { |id| 
        options.router_id = OSPFv2::Id.to_i(id) 
      }
      opts.on("-n", "--neighbor-id [ID]", hlp_neighbor_id) { |id| 
        options.neighbor_id = OSPFv2::Id.to_i(id) 
      }
      opts.on("-a", "--area-id [ID]", hlp_area_id) { |id| 
        options.area_id = to_id.call(id) 
      }
      opts.on("-g", "--grid [colxrow]", hlp_grid) { |grid| 
        options.grid = grid.split('x').collect { |x| x.to_i }
      }
      opts.on( "--hello-interval [INT]", hlp_hello_int) { |int| 
        options.hello_int = int.to_i
      }
      opts.on("--dead-interval [INT]", hlp_dead_int) { |int| 
        @dead_int = int.to_i
      }
      opts.on("-g", "--grid [colxrow]", hlp_grid) { |grid| 
        options.grid = grid.split('x').collect { |x| x.to_i }
      }
      opts.on('-S', "--number-of-summary [INT]", "Number of Summary LSA.") { |x| 
        options.num_sum = x.to_i
      }
      opts.on('-E',"--number-of-external [INT]", "Number AsExternal") { |x| 
        options.num_ext = x.to_i
      }
      opts.on( '-f', "--log-fname [FILENAME]", "To redirect logs to a file.") { |fname|
        options.log_fname = fname 
      }
      opts.on_tail("-h", "--help", "Show this message") { puts "\n  #{opts}\n" ; exit }
      opts.on_tail("-?", "--help") { puts "\n  #{opts}\n" ; exit }
      opts.on
    end

    optparse.parse!(args)
    options.dead_int = @dead_int || (options.hello_int * 4)

    options

  end

end

load "../../../test/ospfv2/infra/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
