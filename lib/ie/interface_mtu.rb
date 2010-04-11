require 'infra/ospf_common'
require 'infra/ospf_constants'

module OSPFv2

class InterfaceMtu
  include Common
  
  attr_checked :interface_mtu do |x|
    (0..0xffff).include?(x)
  end
  
  def initialize(interface_mtu=1500)
    self.interface_mtu=interface_mtu
  end
  
  def to_i
    interface_mtu
  end
  
  def number_of_lsa
    @noh ||= ((to_i - OSPFv2::PACKET_HEADER_LEN) / OSPFv2::LSA_HEADER_LEN) - 1
  end
  alias :n0flsa :number_of_lsa
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def encode(fmt='n')
    [interface_mtu].pack(fmt)
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
