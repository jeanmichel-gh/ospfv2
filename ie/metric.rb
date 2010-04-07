require 'infra/ospf_common'

module OSPFv2

class Metric
  include Common
  
  attr_reader  :metric
  attr_checked :metric do |x|
    (0..0xffffff).include?(x)
  end
  
  def initialize(metric=0)
    self.metric=metric
  end
  
  def to_i
    metric
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def to_s_junos
    "Topology default (ID 0) -> Metric: #{to_i}"
  end
  
  def encode(fmt='N')
    [metric].pack(fmt)
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
