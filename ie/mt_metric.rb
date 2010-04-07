# +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
# |      0        |                  metric                       |
# +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
# |     TOS       |                TOS  metric                    |
# +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
# |                              ...                              |
# 
# Network Mask
#     For Type 3 summary-LSAs, this indicates the destination
#     network's IP address mask.  For example, when advertising the
#     location of a class A network the value 0xff000000 would be
#     used.  This field is not meaningful and must be zero for Type 4
#     summary-LSAs.
# 
# metric
#     The metric of this route.  Expressed in the same units as the
#     interface metrics in the router-LSAs.
# 
# Additional TOS-specific information may also be included, for
# backward compatibility with previous versions of the OSPF
# specification ([Ref9]). For each desired TOS, TOS-specific
# information is encoded as follows:
# 
# TOS IP Type of Service that this metric refers to.  The encoding of
#     TOS in OSPF LSAs is described in Section 12.3.
# 
# TOS metric
#     TOS-specific metric information.
# 

require 'infra/ospf_common'
module OSPFv2

class MtMetric
  
  def initialize(arg={})
    arg = arg.dup
    @_id,@_metric=0,0
    if arg.is_a?(Hash)
      set arg
    elsif arg.is_a?(String)
      parse arg
    elsif arg.is_a?(self.class)
      parse arg.encode
    elsif arg.is_a?(Array) and arg.size==2
      @_id, @_metric = arg
    else
      raise ArgumentError, "Invalid Argument: #{arg.inspect}"
    end
  end
  
  def set(arg)
    @_id = arg[:id] if arg[:id]
    @_metric = arg[:metric] if arg[:metric]
  end
  
  def to_hash
    {:id=>id, :metric=> metric}
  end
  
  def id
    @_id
  end
  def id=(val)
    @_id=val
  end
  def metric
    @_metric
  end
  def metric=(val)
    @_metric=val
  end
    
  def encode
    m = []
    m << [id].pack('C')
    m << [metric].pack('N').unpack('C4')[1..-1].pack('C3')
    m.join
  end
  
  def parse(s)
    @_id, *metric = s.unpack('C4')
    @_metric = [0,*metric].pack('C4').unpack('N')[0]
  end
  
  def to_s
    "Topology #{id}, Metric #{metric}"
  end
  
  def to_s_junos
    "Topology (ID #{id}) -> Metric: #{metric}"
  end
  
end
end

load "../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
