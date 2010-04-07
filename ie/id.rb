
require 'ipaddr'
require 'infra/ospf_common'

module OSPFv2
class Id

  def self.new_ntoh(s)
    return unless s.is_a?(String)
    new s.unpack('N')[0]
  end

  def self.to_i(id)
    return id unless id.is_a?(String)
    IPAddr.new(id).to_i
  end

  def initialize(arg=0)
    self.id = arg
  end
  
  def id=(val)
    if val.is_a?(Hash)
      @id = val[:id] if val[:id]
    elsif val.is_a?(IPAddr)
      @id = val.to_i
    elsif val.is_a?(Integer)
      raise ArgumentError, "Invalid Argument #{val}" unless (0..0xffffffff).include?(val)
      @id = val
    elsif val.is_a?(String)
      @id = IPAddr.new(val).to_i
    elsif val.is_a?(Id)
      @id = val.to_i
    else
      raise ArgumentError, "Invalid Argument #{val.inspect}"
    end
  end
  
  def encode
    [@id].pack('N')
  end
  alias :enc  :encode

  def to_i
    @id
  end
  
  def to_s(verbose=true)
    verbose ? to_s_verbose : to_s_short
  end
  
  def to_hash
    to_s_short
  end

  def to_ip
    to_s(false)
  end
  
  private
  
  def to_s_short
    IPAddr.new_ntoh([@id].pack('N')).to_s
  end
  
  def to_s_verbose
    self.class.to_s.split('::').last + ": " + to_s_short
  end
  
end

end

load "../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

