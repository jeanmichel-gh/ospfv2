#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require 'lsa/tlv/tlv'

module OSPFv2

  class Link_Tlv
    include Tlv
    include Tlv::Common
    include Common
    
    attr_reader :tlv_type, :_length, :tlvs
    
    def initialize(arg={})
      @tlv_type = 2
      @tlvs = []
      if arg.is_a?(Hash) then
        if arg.has_key?(:tlvs)
          @tlvs = arg[:tlvs].collect { |h| SubTlv.factory(h) }
        end
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def has?(klass=nil)
      if klass.nil?
        return tlvs.collect { |tlv| tlv.class }
      else
        return tlvs.find { |tlv| tlv.is_a?(klass) }.nil? ? false : true
      end
    end    

    def find(klass)
      tlvs.find { |a| a.is_a?(klass) }
    end

    def __index(klass)
      i=-1
      tlvs.find { |a| i +=1 ; a.is_a?(klass) }
      i
    end
    private :__index

    def replace(*objs)
      objs.each do |obj|  
        if has?(obj.class)
          index = __index(obj.class)
          tlvs[index]=obj
        else
          add(obj)
        end
      end
      self
    end

    def remove(klass) 
      tlvs.delete_if { |a| a.is_a?(klass) }
    end

    def [](klass)
      find(klass)
    end

    def add(obj)
      if obj.is_a?(OSPFv2::SubTlv)
        @tlvs << obj
      else
        raise
      end
      self
    end
    
    def <<(obj)
      add(obj)
    end

    def encode
      tlvs = encoded_tlvs
      [@tlv_type, tlvs.size, tlvs].pack('nna*')
    end

    def __parse(s)
      @tlv_type, @_length, tlvs = s.unpack('nna*')
      while tlvs.size>0
        _, len = tlvs.unpack('nn')
        @tlvs << SubTlv.factory(tlvs.slice!(0,stlv_len(len)))
      end
    end

    def encoded_tlvs
      tlvs.collect { |tlv| tlv.encode }.join
    end
    
    def _length
      encoded_tlvs.size
    end
    
    # 
    # Link connected to Point-to-Point network
    #   Link ID : 1.2.3.4
    #   Interface Address : 1.1.1.1
    #   Neighbor Address : 2.2.2.2
    #   Admin Metric : 255
    #   Maximum bandwidth : 1250
    #   Maximum reservable bandwidth : 875
    #   Number of Priority : 8
    #   Priority 0 : 12          Priority 1 : 12        
    #   Priority 2 : 12          Priority 3 : 12        
    #   Priority 4 : 12          Priority 5 : 12        
    #   Priority 6 : 12          Priority 7 : 12        
    # 
    # Number of Links : 1
    # 
    def to_s_ios
      #TODO
      tlvs.collect { |tlv| tlv.to_s }.join("\n  ")
    end

    def to_s
      self.class.to_s + "(2): " + "\n" + tlvs.collect { |tlv| tlv.to_s }.join("\n")
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


TODO: to_s_ios

                Type-10 Opaque Link Area Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum Opaque ID
1.0.0.0         0.0.0.3         23          0x80000001 0x000D12 0       
1.0.0.255       0.0.0.1         23          0x80000001 0x00ACB1 255     




R1#show ip ospf database opaque-area 

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Type-10 Opaque Link Area Link States (Area 0)

  LS age: 44
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.0
  Opaque Type: 1
  Opaque ID: 0
  Advertising Router: 0.0.0.3
  LS Seq Number: 80000001
  Checksum: 0xD12
  Length: 116
  Fragment number : 0

    Link connected to Point-to-Point network
      Link ID : 5.6.7.8
      Interface Address : 111.111.111.111
      Neighbor Address : 222.222.222.222
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

  LS age: 45
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.255
  Opaque Type: 1
  Opaque ID: 255
  Advertising Router: 0.0.0.1
  LS Seq Number: 80000001
  Checksum: 0xACB1
  Length: 116
  Fragment number : 255

    Link connected to Point-to-Point network
      Link ID : 1.2.3.4
      Interface Address : 1.1.1.1
      Neighbor Address : 2.2.2.2
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

  LS age: 45
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.255
  Opaque Type: 1
  Opaque ID: 255
  Advertising Router: 0.0.0.1
  LS Seq Number: 80000001
  Checksum: 0xACB1
  Length: 116
  Fragment number : 255

    Link connected to Point-to-Point network
      Link ID : 1.2.3.4
      Interface Address : 1.1.1.1
      Neighbor Address : 2.2.2.2
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

R1#
