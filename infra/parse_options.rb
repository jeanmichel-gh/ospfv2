require 'optparse'
require 'ostruct'

require 'ie/id'

class OptParse
  
  def self.parse(args)
    
    options = OpenStruct.new
    options.ipaddr = '192.168.1.123'
    options.router_id = 1
    options.area_id = 0
    options.log_fname = $stdout
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
    
    option_help = "blabla ...."
    hlp_address = "IP Address of the OSPF Interface."
    hlp_router_id = "Router ID."
    hlp_area_id = "Area ID."
    
    optparse = OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options]"
      opts.on("-i", "--address [IPADDR]", hlp_address) { |addr| options.ipaddr = addr }
      opts.on("-r", "--router-id [ID]", hlp_router_id) { |id| options.router_id = OSPFv2::Id.to_i(id) }
      opts.on("-a", "--area-id [ID]", hlp_area_id) { |id| options.area_id = OSPFv2::Id.to_i(id) }
      opts.on( '-f', "--log-fname [FILENAME]", "To redirect logs to a file.") { |fname| options.log_fname = fname }
      opts.on_tail("-h", "--help", "Show this message") { puts "\n  #{opts}\n" ; exit }
      opts.on_tail("-?", "--help") { puts "\n  #{opts}\n" ; exit }
      opts.on
    end
    
    optparse.parse!(args)
    options
    
  end
  
end
