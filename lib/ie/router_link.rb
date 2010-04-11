require 'infra/ospf_common'
require 'ie/id'
require 'ie/metric'
require 'ie/mt_metric'
require 'ie/router_link_type'

module OSPFv2
  
  class RouterLink
    include Common
    
    LinkId = Class.new(Id)
    LinkData = Class.new(Id)
    
    attr_reader :link_id, :link_data, :router_link_type, :metric, :mt_metrics
    
    attr_writer_delegate :link_id, :link_data, :router_link_type
    
    def initialize(arg={})
      arg = arg.dup
      if arg.is_a?(Hash)
        @link_id, @link_data, @router_link_type, @metric = nil, nil, nil, nil
        @mt_metrics = []
        set arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self.class)
        parse arg.encode
      else
        raise ArgumentError, "Invalid Argument: #{arg.inspect}"
      end
    end
    
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                          Link ID                              |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                         Link Data                             |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |     Type      |     # TOS     |            metric             |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                              ...                              |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |      TOS      |        0      |          TOS  metric          |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    def encode
      @link_id    ||= LinkId.new
      @link_data  ||= LinkData.new
      @router_link_type  ||= RouterLinkType.new
      @metric   ||= Metric.new
      rlink =[]
      rlink << link_id.encode
      rlink << link_data.encode
      rlink << router_link_type.encode
      rlink << [mt_metrics.size].pack('C')
      rlink << metric.encode('n')
      rlink << mt_metrics.collect { |x| x.encode }
      rlink.join
    end
    
    # TODO: if self.class is not RouterLink do not display RouterLinkType info....
    def to_s(ident=2)
      encode unless @router_link_type
      self.class.to_s.split('::').last + ":" +
      ['',link_id, link_data, router_link_type, metric, *mt_metrics].compact.collect { |x| x.to_s }.join("\n"+" "*ident)
    end
    
    def to_s_junos_style
      s = "  id #{id}, data #{data}, Type #{RouterLink.type_to_s_junos_style[@type]} (#{@type})"
      s +="\n    Topology count: #{@mt_id.size}, Default metric: #{@metric}"
      s += @mt_id.collect { |mt| "\n    #{mt.to_s_junos_style}" }.join
      s      
    end
 
    def to_s_junos
      s = "  id #{link_id.to_ip}, data #{link_data.to_ip}, Type #{RouterLinkType.to_junos(router_link_type.to_i)} (#{router_link_type.to_i})"
      s +="\n    Topology count: #{@mt_metrics.size}, Default metric: #{metric.to_i}"
      s += @mt_metrics.collect { |mt| "\n    #{mt.to_s}" }.join

    end
    
    class << self
      class_eval {
        RouterLinkType.each { |x| 
          define_method "new_#{x}" do |*args|
            OSPFv2::RouterLink.const_get(x.to_klass).send :new, *args
          end
        }
      }
    end
    
    RouterLinkType.each { |x| 
      klassname = Class.new(self) do
        define_method(:initialize) do |arg|
          arg ||={}
          arg[:router_link_type] = x if arg.is_a?(Hash)
          super arg
        end
        define_method(:to_hash) do
          super.merge :router_link_type => x
        end
      end
      self.const_set(x.to_klass, klassname)
    }
    
    # FIXME: same as summary.rb ... mixin candidate
    def mt_metrics=(val)
      [val].flatten.each { |x| self << x }
    end
    
    def <<(metric)
      @mt_metrics ||=[]
      @mt_metrics << MtMetric.new(metric)
      self
    end
    
    def parse(s)
      @mt_metrics ||=[]
      link_id, link_data, router_link_type, ntos, metric, mt_metrics = s.unpack('NNCCna*')
      @link_id = LinkId.new link_id
      @link_data = LinkData.new link_data
      @router_link_type = RouterLinkType.new router_link_type
      @metric = Metric.new metric
      while mt_metrics.size>0
        self << MtMetric.new(mt_metrics.slice!(0,4))
      end
    end
    
  end
# 
# require 'pp'  
#   h = {:router_link_type=>1, :metric=>1,:mt_metrics=>[{:id=>20, :metric=>33}, {:id=>255, :metric=>34}], :link_data=>"10.254.233.233",:link_id=>"2.2.2.2"}
# 
# pp RouterLink.new(h)
# 
# puts RouterLink.new(h)
# puts RouterLink.new(h).to_shex



  
end



load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
