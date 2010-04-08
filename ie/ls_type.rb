# 
# LS Type   Description
# ___________________________________
# 1         Router-LSAs
# 2         Network-LSAs
# 3         Summary-LSAs (IP network)
# 4         Summary-LSAs (ASBR)
# 5         AS-external-LSAs
# 
module OSPFv2
class LsType
  
  def self.all
    [:router, :network, :summary, :asbr_summary, :as_external]
  end
  
  def self.to_i(arg)
    return arg unless arg.is_a?(Symbol)
    case arg.to_s
    when /^router(_lsa|)$/       ; @ls_type=1
    when /^network(_lsa|)$/      ; @ls_type=2
    when /^summary(_lsa|)$/      ; @ls_type=3
    when /^asbr_summary(_lsa|)$/ ; @ls_type=4
    when /^as_external(_lsa|)$/  ; @ls_type=5
    #FIXME: finish and unit-test
    # when :as_external7_lsa ; @ls_type=7
    # when :opaque_link      ; @ls_type=9
    # when :opaque_area      ; @ls_type=10
    # when :opaque_as        ; @ls_type=11
    end    
  end
  
  def self.to_sym(arg)
    return arg unless arg.is_a?(Fixnum)
    case arg
    when 1  ; :router_lsa
    when 2  ; :network_lsa
    when 3  ; :summary_lsa
    when 4  ; :asbr_summary_lsa
    when 5  ; :as_external_lsa
    when 7  ; :as_external7_lsa
    when 9  ; :opaque_link
    when 10 ; :opaque_area
    when 11 ; :opaque_as
    end
  end

  def self.to_junos(arg)
    return arg.to_i unless arg.is_a?(Fixnum)
    case arg
    when 1  ; 'Router'
    when 2  ; 'Network'
    when 3  ; 'Summary'
    when 4  ; 'ASBRSum'
    when 5  ; 'Extern'
    else
      'TBD'
    end
  end
  
  def initialize(ls_type=1)
    case ls_type
    when  1,:router_lsa       ; @ls_type=1
    when  2,:network_lsa      ; @ls_type=2
    when  3,:summary_lsa      ; @ls_type=3
    when  4,:asbr_summary_lsa ; @ls_type=4
    when  5,:as_external_lsa  ; @ls_type=5
    when  7,:as_external7_lsa ; @ls_type=7
    when  9,:opaque_link      ; @ls_type=9
    when 10,:opaque_area      ; @ls_type=10
    when 11,:opaque_as        ; @ls_type=11
    else
      raise ArgumentError, "Invalid LsType #{ls_type}"
    end
  end
  def to_i
    @ls_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_s_short
    case to_i
    when  1; 'router'
    when  2; 'network'
    when  3; 'summary'
    when  4; 'asbrSum'
    when  5; 'external'
    when  7; 'nssa'
    when  9; 'opaqLnk'
    when 10; 'opaqArea'
    when 11; 'opaqAs'
    end
  end
  def to_sym
    LsType.to_sym @ls_type
  end

  def encode
    [@ls_type].pack('C')
  end
  alias :enc  :encode
  
  def to_hash
    to_sym
  end
  
end
end

load "../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__

LSA_Header.aging=false
LSA_Header.lstype_to_s = Hash.new("unknown")
LSA_Header.lstype_to_s.store(1,"Router")
LSA_Header.lstype_to_s.store(2,"Network")
LSA_Header.lstype_to_s.store(3,"Summary")
LSA_Header.lstype_to_s.store(4,"ASBR_Sum")
LSA_Header.lstype_to_s.store(5,"External")
LSA_Header.lstype_to_s.store(9,"OpaqLink")
LSA_Header.lstype_to_s.store(10,"OpaqArea")
LSA_Header.lstype_to_s.store(11,"OpaqAS")


