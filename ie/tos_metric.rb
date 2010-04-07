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
#     The cost of this route.  Expressed in the same units as the
#     interface costs in the router-LSAs.
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

class TosMetric
  include Common
  
  attr_reader :tos, :cost
  
  def initialize(arg={})
    arg = arg.dup
    @tos,@cost=0,0
    if arg.is_a?(Hash)
      set arg
    elsif arg.is_a?(String)
      parse arg
    elsif arg.is_a?(self.class)
      parse arg.encode
    elsif arg.is_a?(Array) and arg.size==2
      @tos, @cost = arg
    else
      raise ArgumentError, "Invalid Argument: #{arg.inspect}"
    end
  end
  
  alias :id :tos
  
  def encode
    m = []
    m << [tos].pack('C')
    m << [cost].pack('N').unpack('C4')[1..-1].pack('C3')
    m.join
  end
  
  def parse(s)
    @tos, *cost = s.unpack('C4')
    @cost = [0,*cost].pack('C4').unpack('N')[0]
  end
  
  def to_s
    self.class.to_s.split('::').last + ": tos: #{tos} cost: #{cost}"
  end
  
  def to_s_junos_style
    "Topology (ID #{id}) -> Metric: #{cost}"
  end
  
end
end

load "../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
