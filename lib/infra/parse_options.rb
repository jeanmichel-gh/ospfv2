#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# OSPFv2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OSPFv2.  If not, see <http://www.gnu.org/licenses/>.
#++

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
    options.num_sum = 3
    options.num_ext = 3
    options.ls_refresh_time = 2000
    options.ls_refresh_interval = 180
    options.console = :irb
    options.network_type = :broadcast

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
    dead_int = lambda { options.dead_int || (options.hello_int * 4) }

    option_help = "blabla ...."
    hlp_address =             "IP Address of the OSPF Interface."
    hlp_base_link_addr=       "base p2p links address           Default: #{options.base_link_addr}"
    hlp_base_router_id =      "base router-id                   Default: #{to_ip.call(options.base_router_id)}"
    hlp_neighbor_id=          "Neighbor Id.                     Default: #{to_ip.call(options.neighbor_id)}"
    hlp_router_id =           "Router Id.                       Default: #{to_ip.call(options.router_id)}"
    hlp_area_id =             "Area Id.                         Default: #{to_ip.call(options.area_id)}"
    hlp_grid =                "Area Grid.                       Default: #{options.grid.join('x')}"
    hlp_hello_int =           "Hello Int.                       Default: #{options.hello_int}"
    hlp_dead_int =            "Dead Int.                        Default: #{dead_int.call}"
    hlp_sum =                 "Number of Summary LSA            Default: #{options.num_sum}"
    hlp_ext =                 "Number AsExternal                Default: #{options.num_ext}"
    hlp_ls_refresh_time =     "LS Refresh Time                  Default: #{options.ls_refresh_time}"
    hlp_ls_refresh_interval = "LS Refresh Interval              Default: #{options.ls_refresh_interval}"

    optparse = OptionParser.new do |opts|

      opts.banner = "Usage: #{$0} [options]"

      opts.separator ""
      opts.separator "Neighbor:"
      opts.on("-i", "--address [PREFIX]", hlp_address) { |x| 
        options.ipaddr = x
        options.ipaddr = x.split('/')[0]
        _addr = IPAddr.new x
        options.network = _addr.to_s
        options.netmask = _addr.netmask
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
      opts.on( "--hello-interval [INT]", hlp_hello_int) { |int| 
        options.hello_int = int.to_i
      }
      opts.on("--dead-interval [INT]", hlp_dead_int) { |int| 
        options.dead_int = int.to_i
      }
      opts.on( '-c', "--network [TYPE]", [:broadcast, :p2p], "Network type (broadcast, p2p)") { |t|
        options.network_type = t || :broadcast
        
      }
      
      opts.separator ""
      opts.separator ""
      opts.separator "Link State Dabatabse:"
      opts.on("-g", "--grid [colxrow]", hlp_grid) { |grid| 
        options.grid = grid.split('x').collect { |x| x.to_i }
      }
      opts.on("-g", "--grid [colxrow]", hlp_grid) { |grid| 
        options.grid = grid.split('x').collect { |x| x.to_i }
      }
      opts.on('-S', "--number-of-summary [INT]", hlp_sum) { |x| 
        options.num_sum = x.to_i
      }
      opts.on('-E',"--number-of-external [INT]", hlp_ext) { |x| 
        options.num_ext = x.to_i
      }
      opts.on("--base-router-id [ID]", hlp_base_router_id) { |id| 
        options.base_router_id = id.to_i
      }
      opts.on( "--base-p2p-addr [PREFIX]", hlp_base_link_addr) { |x| 
        options.base_link_addr = x
      }

      opts.separator "\n"
      opts.on("--refresh-time [SECOND]", OptionParser::DecimalInteger, hlp_ls_refresh_time) { |x| 
        options.ls_refresh_time = x
      }
      opts.on("--refresh-interval [SECOND]", OptionParser::DecimalInteger, hlp_ls_refresh_interval) { |x| 
        options.ls_refresh_interval = x
      }
      
      opts.separator "\n"
      opts.on( '-f', "--log-fname [FILENAME]", "To redirect logs to a file.") { |fname|
        options.log_fname = fname 
      }
      opts.on( '-c', "--console [TYPE]", [:irb, :pry, :none], "Console (irb, pry, none)") { |t|
        options.console = t || :irb
      }
      opts.on_tail("-h", "--help", "Show this message") { puts "\n  #{opts}\n" ; exit }
      opts.on_tail("-?", "--help") { puts "\n  #{opts}\n" ; exit }
      opts.on
    end

    optparse.parse!(args)
    options.dead_int ||= (options.hello_int * 4)

    options

  end

end

load "../../../test/ospfv2/infra/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
