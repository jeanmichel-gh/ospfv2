#
# (RFC 2328)
#
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |E|     0       |                  metric                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      Forwarding address                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      External Route Tag                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#
#
# 
# (RFC 4915)
# 
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                         Network Mask                          |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |E|     0       |                  metric                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      Forwarding address                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      External Route Tag                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |E|    MT-ID    |              MT-ID  metric                    |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      Forwarding address                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                      External Route Tag                       |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#         |                              ...                              |
#         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#
require 'infra/ospf_common'
require 'ie/metric'
require 'ie/tos_metric'
require 'ie/id'


module OSPFv2
  
  class ExternalRoute_Base
    include Common

    ForwardingAddress = Class.new(OSPFv2::Id)
    
    attr_reader  :metric, :type, :forwarding_address, :tag, :mt_id
    attr_checked :metric do |x|
      (0..0xffffff).include?(x)
    end
    attr_checked :type do |x|
      [:e1,:e2].include?(x)
    end
    attr_checked :tag do |x|
      (0..0xffffffff).include?(x)
    end
    attr_checked :mt_id do |x|
      (0..0x7f).include?(x)
    end
    
    attr_writer_delegate :forwarding_address
    
    def initialize(arg={})
      arg = arg.dup
      self.metric=0
      self.type=:e1
      self.tag=0
      self.mt_id=0
      if arg.is_a?(Hash)
        set arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self.class)
        parse arg.encode
      else
        raise ArgumentError, "Invalid Argument: #{arg.inspect}"
      end
    end
    
    def encode
      external =[]
      external << encoded_e_id_metric
      external << forwarding_address.encode
      external << [tag].pack('N')
      external.join
    end
    
    def parse(s)
      long1, long2, @tag = s.unpack('NNN')
      @type, @mt_id, @metric = parse_e_id_metric(long1)
      @forwarding_address = ForwardingAddress.new(long2)
    end
    
    def to_s
      "#{type.to_s.upcase} (ID #{mt_id}) Metric: #{metric.to_i} Forwarding: #{forwarding_address.to_ip} Tag: #{tag}"
    end
   
    private
    
    def encoded_e_id_metric
      long = 0
      long = 0x80000000 if type== :e2
      long |= (mt_id << 24)
      long |= metric.to_i
      [long].pack('N')
    end
    
    def parse_e_id_metric(long)
      type = :e1
      type = :e2 if (long >> 31) > 0
      metric = long & 0xffffff
      _id = long >> 24 & 0x7f
      [type,_id,metric]
    end
    
    def metric_to_s
      "Metric: #{metric}"
    end
    
  end
  
  class ExternalRoute < ExternalRoute_Base
    def initialize(arg={})
      if arg.is_a?(Hash)
        @forwarding_address = ForwardingAddress.new
        raise ArgumentError, "ID should be 0" if arg[:id] and arg[:mt_id]>0
      end
      super
    end
    def to_hash
      h = super
      h.delete(:mt_id)
      h
    end
    
  end

  class MtExternalRoute < ExternalRoute_Base
    def initialize(arg={})
      if arg.is_a?(Hash)
        @forwarding_address = ForwardingAddress.new
        raise ArgumentError, "MT-ID not set!" unless arg[:mt_id]
        raise ArgumentError, "MT-ID should not be 0!" if arg[:mt_id]==0
      end
      super
    end
  end
  
  def ExternalRoute_Base.new_hash(h)
    if h[:mt_metrics]
      MtExternalRoute.new(h)
    else
      ExternalRoute.new(h)
    end
  end
  
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
