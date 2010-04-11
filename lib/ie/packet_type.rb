module OSPFv2
class PacketType
  def initialize(value=0)
    case value
    when 1, :hello      ; @packet_type = 1
    when 2, :dd         ; @packet_type = 2
    when 3, :ls_request ; @packet_type = 3
    when 4, :ls_update  ; @packet_type = 4
    when 5, :ls_ack     ; @packet_type = 5
    else
      @packet_type = 0
    end
  end
  def to_hash
    to_sym
  end
  def to_i
    @packet_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_sym
    case @packet_type
    when 1  ; :hello
    when 2  ; :dd
    when 3  ; :ls_request
    when 4  ; :ls_update
    when 5  ; :ls_ack
    else
      'unknown'
    end
  end

  def encode
    [@packet_type].pack('C')
  end
  alias :enc  :encode
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
