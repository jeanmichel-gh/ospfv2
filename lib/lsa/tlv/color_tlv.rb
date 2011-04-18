
=begin rdoc

The Traffic Engineering Color sub-TLV is TLV type 9, and is four
octets in length.

=end


require 'lsa/tlv/tlv'

module OSPFv2

  class Color_Tlv
    include SubTlv
    include Common

    attr_reader :tlv_type, :length, :color

    def initialize(arg={})
      @tlv_type, @length,  = 9,4
      @color = 0

      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, @length, @color].pack('nnN')
    end

    def __parse(s)
      @tlv_type, _, @color = s.unpack('nnN')
    end

    def to_s
      self.class.to_s + ": " + color.to_s
    end

  end
end

if __FILE__ == $0

  require "test/unit"

  class Color_Tlv_Test < Test::Unit::TestCase # :nodoc:
    include OSPFv2
    def test_init
      assert_equal("0009000400000000", Color_Tlv.new().to_shex)
      assert_equal("OSPFv2::Color_Tlv: 254", Color_Tlv.new({:color=>254}).to_s)
      assert_equal("00090004000000fe", Color_Tlv.new({:color=>254}).to_shex)
      assert_equal(255, Color_Tlv.new({:color=>255}).to_hash[:color])
      assert_equal("000900040000ffff", Color_Tlv.new(Color_Tlv.new({:color=>0xffff}).encode).to_shex)
    end
  end
end


__END__




class Color_SubTLV < SubTLV
  include Ospf

  attr_reader :tlv_type, :length, :color
  attr_writer :color

  def initialize(arg={})
    @tlv_type, @length, @color = 9,4,0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def color=(arg)
    @color=arg[:color] unless arg[:color].nil?
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.color=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@color, 'N'], 
      ])
    end

    def __parse(s)
      arr = s.unpack('nnN')
      @tlv_type = arr[0]
      @length= arr[1]
      @color = arr[2]
    end
    private :__parse

    def to_hash
      h=super
      h[:color]=color
      h
    end

    def to_s
      self.class.to_s + ": #{color}"
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "Color (9), length #{@length}:\n  #{"  "*ident}#{color}"
    end

  end
end

if __FILE__ == $0
  load '../test/opaque_tlvs_test.rb'
end

