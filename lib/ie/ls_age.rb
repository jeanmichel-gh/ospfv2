require 'infra/ospf_constants'

module OSPFv2
class LsAge
  include Comparable
  
  class << self
    def aging(state=:off)
      case state
      when :on   ; @aging = true
      when :off  ; @aging = false
      else
        raise ArgumentError, "Invalid Argument"
      end
    end
    def aging?
      @aging
    end
  end
  
  def initialize(age=0)
    raise ArgumentError, "Invalid Argument #{age}" unless age.is_a?(Integer)
    @age=age
    @time = Time.now
  end
  
  def to_i
    aging? ? (Time.new - @time + @age).to_int : @age
  end
  
  def aging?
    self.class.aging?
  end
  
  def maxage
    @age = OSPFv2::MaxAge
  end
  
  def maxaged?
    to_i >= OSPFv2::MaxAge
  end
  
  def <=>(obj)
    to_i <=> obj.to_i
  end
  
  def -(obj)
    to_i - obj.to_i
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def encode
    [@age].pack('n')
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
