__END__


#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

=begin rdoc

2.3.2.  TLV Header

   The LSA payload consists of one or more nested Type/Length/Value
   (TLV) triplets for extensibility.  The format of each TLV is:

       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |              Type             |             Length            |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |                            Value...                           |
      .                                                               .
      .                                                               .
      .                                                               .
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

   The Length field defines the length of the value portion in octets
   (thus a TLV with no value portion would have a length of zero).  The
   TLV is padded to four-octet alignment; padding is not included in the
   length field (so a three octet value would have a length of three,
   but the total size of the TLV would be eight octets).  Nested TLVs
   are also 32-bit aligned.  Unrecognized types are ignored.

   
=end

require 'ip'

module Ospf
  
=begin rdoc
2.4.1.  Router Address TLV

   The Router Address TLV specifies a stable IP address of the
   advertising router that is always reachable if there is any
   connectivity to it; this is typically implemented as a "loopback
   address".  The key attribute is that the address does not become
   unusable if an interface is down.  In other protocols, this is known
   as the "router ID," but for obvious reasons this nomenclature is
   avoided here.  If a router advertises BGP routes with the BGP next
   hop attribute set to the BGP router ID, then the Router Address
   SHOULD be the same as the BGP router ID.

   If IS-IS is also active in the domain, this address can also be used
   to compute the mapping between the OSPF and IS-IS topologies.  For
   example, suppose a router R is advertising both IS-IS and OSPF
   Traffic Engineering LSAs, and suppose further that some router S is
   building a single Traffic Engineering Database (TED) based on both
   IS-IS and OSPF TE information.  R may then appear as two separate
   nodes in S's TED.  However, if both the IS-IS and OSPF LSAs generated
   by R contain the same Router Address, then S can determine that the
   IS-IS TE LSA and the OSPF TE LSA from R are indeed from a single
   router.

   The router address TLV is type 1, has a length of 4, and a value that
   is the four octet IP address.  It must appear in exactly one Traffic
   Engineering LSA originated by a router.

=end  

class TLV
  def __stlv_len(n)
    (((n+3)/4)*4)+4
  end
  private :__stlv_len
  def tlv_length
    @length
  end
  def to_hash
    {:tlv_type=> tlv_type}
  end
end


class TLV_Factory
  def TLV_Factory.create(arg={})
    type=nil
    if arg.is_a?(Hash)
      type = arg[:tlv_type]
    elsif arg.is_a?(String)
      type = arg[0..1].unpack('n')[0]
    end
    return nil if type.nil?
    case type
    when 1 ; RouterID_TLV.new(arg)
    when 2 ; LinkTLV.new(arg)
    end
  end  
end


class RouterID_TLV  < TLV
  include Ospf
  include Ospf::Ip
  
  attr_reader :tlv_type, :length

  def initialize(arg={})
    @tlv_type, @length, @rid = 1,4,0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def rid=(arg)
    @rid=ip2long(arg[:rid]) unless arg[:rid].nil?
  end

  def type_to_s
    "RouterID"
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.rid=arg
  end

  def enc
    __enc([
      [@tlv_type, 'n'], 
      [@length, 'n'], 
      [@rid, 'N'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nnN')
    @tlv_type = arr[0]
    @length= arr[1]
    @rid = arr[2]
  end
  private :__parse

  def rid
    long2ip(@rid)
  end

  def to_hash
    h = super
    h[:rid] = long2ip(@rid)
    h
  end

  def to_s
    "RouterID TLV: #{rid}"
  end

  def to_s_junos_style(ident=0)
    "  "*ident + "RtrAddr (1), length #{@length}: #{rid}"
  end

end

=begin rdoc

2.4.2.  Link TLV

   The Link TLV describes a single link.  It is constructed of a set of
   sub-TLVs.  There are no ordering requirements for the sub-TLVs.

   Only one Link TLV shall be carried in each LSA, allowing for fine
   granularity changes in topology.

   The Link TLV is type 2, and the length is variable.

   The following sub-TLVs of the Link TLV are defined:

      1 - Link type (1 octet)
      2 - Link ID (4 octets)
      3 - Local interface IP address (4 octets)
      4 - Remote interface IP address (4 octets)
      5 - Traffic engineering metric (4 octets)
      6 - Maximum bandwidth (4 octets)
      7 - Maximum reservable bandwidth (4 octets)
      8 - Unreserved bandwidth (32 octets)
      9 - Administrative group (4 octets)

   This memo defines sub-Types 1 through 9.  See the IANA Considerations
   section for allocation of new sub-Types.

   The Link Type and Link ID sub-TLVs are mandatory, i.e., must appear
   exactly once.
   
   All other sub-TLVs defined here may occur at most
   once.  These restrictions need not apply to future sub-TLVs.
   Unrecognized sub-TLVs are ignored.

   Various values below use the (32 bit) IEEE Floating Point format.
   For quick reference, this format is as follows:

       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |S|    Exponent   |                  Fraction                   |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

   S is the sign, Exponent is the exponent base 2 in "excess 127"
   notation, and Fraction is the mantissa - 1, with an implied binary
   point in front of it.  Thus, the above represents the value:

      (-1)**(S) * 2**(Exponent-127) * (1 + Fraction)

   For more details, refer to [4].
   
=end

class LinkTLV < TLV
  include Ospf

  attr_reader :tlv_type, :length, :tlvs

  def initialize(arg={})
    @tlv_type, @length, @tlvs = 2, 0, []
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
    self
  end

  def add(tlv)
    if tlv.is_a?(Ospf::SubTLV)
      @tlvs << tlv
    end
    self
  end

  def <<(tlv)
    add(tlv)
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    unless arg[:tlvs].nil?
      arg[:tlvs].each { |tlv| 
        tlv.is_a?(SubTLV) ? @tlvs << tlv : @tlvs << SubTLV.new(tlv) 
      }
    end
    self
  end

  def enc
    _tlvs =  @tlvs.collect { |tlv| tlv.enc }.join
    @length = _tlvs.size
    s = __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      ])
    s += _tlvs
    s
  end
    
  def __parse(s)
    arr = s.unpack('nn')
    @tlv_type = arr[0]
    @length= arr[1]
    tlvs = s[4..-1]
    while tlvs.size>0
      len = tlvs[2..3].unpack('n')[0]
      @tlvs << SubTLV_Factory.create(tlvs.slice!(0,__stlv_len(len)))
    end
  end
  private :__parse

  def to_hash
    {
      :tlv_type => tlv_type,
      :tlvs => @tlvs.collect { |tlv| tlv.to_hash }
    }
  end

  def to_s
    @length =  @tlvs.collect { |tlv| tlv.enc }.join.size
    self.class.to_s + "(2): " + "\n" +
    @tlvs.collect { |tlv| tlv.to_s }.join("\n")
  end

  def to_s_junos_style(ident=0)
    s = "  "* ident + "Link (2), length #{@length}:\n"
    s += @tlvs.collect { |tlv| tlv.to_s_junos_style(ident+1) }.join("\n")
  end

  def self.create(args={})
    link_tlv = LinkTLV.new()   
    link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw = nil, nil, nil, nil, nil, nil, nil    
    link_type = LinkTypeSubTLV.new(args) if args.has_key?(:link_type)
    link_id = LinkID_SubTLV.new(args) if args.has_key?(:link_id)
    local_if_addr = LocalInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:local_interface_ip_address)
    rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:remote_interface_ip_address)
    te_metric = TE_MetricSubTLV.new(args) if args.has_key?(:te_metric)
    max_bw = MaximumBandwidth_SubTLV.new(args) if args.has_key?(:max_bw)
    max_resv_bw = MaximumReservableBandwidth_SubTLV.new(args) if args.has_key?(:max_resv_bw)
    unresv_bw = UnreservedBandwidth_SubTLV.new(args) if args.has_key?(:unreserved_bw)
    [link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw, unresv_bw].each do |sub_tlv|
      link_tlv << sub_tlv unless sub_tlv.nil?
    end
    link_tlv    
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

end

class SubTLV
  
  def tlv_length
    @length
  end
  
  def to_hash
    {:tlv_type=> tlv_type}
  end
  
end


class SubTLV_Factory

  def SubTLV_Factory.create(arg={})
    if arg.is_a?(Hash)
      return nil if arg[:tlv_type].nil?
      type = arg[:tlv_type]
    elsif arg.is_a?(String)
      # assume we got it from the wire, i.e. it's packed.
      type = arg[0..1].unpack('n')[0]
    else
      return 
    end

    case type
    when 1 ; LinkTypeSubTLV.new(arg)
    when 2 ; LinkID_SubTLV.new(arg)
    when 3 ; LocalInterfaceIP_Address_SubTLV.new(arg)
    when 4 ; RemoteInterfaceIP_Address_SubTLV.new(arg)
    when 5 ; TE_MetricSubTLV.new(arg)
    when 6 ; MaximumBandwidth_SubTLV.new(arg)
    when 7 ; MaximumReservableBandwidth_SubTLV.new(arg)
    when 8 ; UnreservedBandwidth_SubTLV.new(arg)
    when 9 ; Color_SubTLV.new(arg)
    end

  end
  
end


=begin rdoc  
  2.5.1.  Link Type

     The Link Type sub-TLV defines the type of the link:

        1 - Point-to-point
        2 - Multi-access

     The Link Type sub-TLV is TLV type 1, and is one octet in length.
=end

class LinkTypeSubTLV < SubTLV
  include Ospf
  include Ospf::Ip

  attr_reader :tlv_type, :length, :link_type
  attr_writer :link_type

  def initialize(arg={})
    @tlv_type, @length, @link_type = 1,1,0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def link_type=(arg)
    @link_type=ip2long(arg[:link_type]) unless arg[:link_type].nil?
  end

  def link_type_to_s
    if @link_type==1
      "point-to-point"
    elsif @link_type==2
      "multiaccess"
    else
      "bogus(#{@link_type})"
    end
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.link_type=arg
  end

  def enc
    __enc([
      [@tlv_type, 'n'], 
      [@length, 'n'], 
      [@link_type, 'C'], 
      [[0,0,0], 'C3'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nnC')
    @tlv_type = arr[0]
    @length= arr[1]
    @link_type = arr[2]
  end
  private :__parse
  

  def to_hash
    h = super
    h[:link_type] = @link_type
    h
  end

  def to_s
    self.class.to_s + ": " + link_type_to_s
  end
  
  def to_s_junos_style(ident=0)
    "  "*ident + "Linktype (1), length #{@length}:\n  #{"  "*ident}#{@link_type}"
  end

end


=begin rdoc  
    2.5.2.  Link ID

       The Link ID sub-TLV identifies the other end of the link.  For
       point-to-point links, this is the Router ID of the neighbor.  For
       multi-access links, this is the interface address of the designated
       router.  The Link ID is identical to the contents of the Link ID
       field in the Router LSA for these link types.

       The Link ID sub-TLV is TLV type 2, and is four octets in length.

=end

class LinkID_SubTLV < SubTLV
  include Ospf
  include Ospf::Ip

  attr_reader :tlv_type, :length

  def initialize(arg={})
    @tlv_type, @length, @link_id = 2,4,0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def link_id=(arg)
    @link_id=ip2long(arg[:link_id]) unless arg[:link_id].nil?
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.link_id=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@link_id, 'N'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nnN')
    @tlv_type = arr[0]
    @length= arr[1]
    @link_id = arr[2]
  end
  private :__parse
  

  def link_id
    long2ip(@link_id)
  end

  def to_hash
    h = super
    h[:link_id]=link_id
    h
  end

  def to_s
    self.class.to_s + ": " + link_id
  end
  
  def to_s_junos_style(ident=0)
    "  "*ident + "LinkID (2), length #{@length}:\n  #{"  "*ident}#{link_id}"
  end

end


=begin rdoc  

  2.5.3.  Local Interface IP Address

     The Local Interface IP Address sub-TLV specifies the IP address(es)
     of the interface corresponding to this link.  If there are multiple
     local addresses on the link, they are all listed in this sub-TLV.

     The Local Interface IP Address sub-TLV is TLV type 3, and is 4N
     octets in length, where N is the number of local addresses.

=end


class LocalInterfaceIP_Address_SubTLV <  SubTLV
  include Ospf
  include Ospf::Ip

  attr_reader :tlv_type

  def initialize(arg={})
    @tlv_type, @local_interface_ip_address = 3,[]
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def local_interface_ip_address=(arg)
    unless arg[:local_interface_ip_address].nil?
      [arg[:local_interface_ip_address]].flatten.each {|addr|
        @local_interface_ip_address << ip2long(addr)
      }
    end
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.local_interface_ip_address=arg
  end

  def enc
    s = __enc([
      [@tlv_type,  'n'], 
      [length, 'n'], 
    ])
    s += @local_interface_ip_address.pack('N*')        
  end

  def __parse(s)
    arr = s.unpack('nnN*')
    @tlv_type = arr[0]
    length= arr[1]
    @local_interface_ip_address = arr[2..-1]
  end
  private :__parse
  

  def local_interface_ip_address
    @local_interface_ip_address.collect {|addr| long2ip(addr) }
  end

  def to_hash
    h=super
    h[:local_interface_ip_address] = local_interface_ip_address
    h
  end

  def length
    @local_interface_ip_address.flatten.size*4
  end

  def to_s
    self.class.to_s + ": " + local_interface_ip_address.join(", ")
  end
  
  def to_s_junos_style(ident=0)
    s = "  "*ident + "LocIfAdr (3), length #{length}:"
    s += local_interface_ip_address.collect {|addr| "\n  #{"  "*ident}#{addr}"}.join
  end

end

  
=begin rdoc

2.5.4.  Remote Interface IP Address

   The Remote Interface IP Address sub-TLV specifies the IP address(es)
   of the neighbor's interface corresponding to this link.  This and the
   local address are used to discern multiple parallel links between
   systems.  If the Link Type of the link is Multi-access, the Remote
   Interface IP Address is set to 0.0.0.0; alternatively, an
   implementation MAY choose not to send this sub-TLV.

   The Remote Interface IP Address sub-TLV is TLV type 4, and is 4N
   octets in length, where N is the number of neighbor addresses.

=end

class RemoteInterfaceIP_Address_SubTLV <  SubTLV
  include Ospf
  include Ospf::Ip

  attr_reader :tlv_type

  def initialize(arg={})
    @tlv_type, @remote_interface_ip_address = 4,[]
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def remote_interface_ip_address=(arg)
    unless arg[:remote_interface_ip_address].nil?
      [arg[:remote_interface_ip_address]].flatten.each { |addr|
        @remote_interface_ip_address << ip2long(addr)
      }
    end
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.remote_interface_ip_address=arg
  end

  def enc
    s = __enc([
      [@tlv_type,  'n'], 
      [length, 'n'], 
      ])
    s += @remote_interface_ip_address.pack('N*')        
  end

  def __parse(s)
    arr = s.unpack('nnN*')
    @tlv_type = arr[0]
    length= arr[1]
    @remote_interface_ip_address = arr[2..-1]
  end
  private :__parse
  
  def remote_interface_ip_address
    @remote_interface_ip_address.collect {|addr| long2ip(addr) }
  end

  def to_hash
    h=super
    h[:remote_interface_ip_address] = remote_interface_ip_address
    h
  end
  
  def length
    @remote_interface_ip_address.flatten.size*4
  end

  def to_s
    self.class.to_s + ": " + remote_interface_ip_address.join(", ")
  end
  
  def to_s_junos_style(ident=0)
    s = "  "*ident + "RemIfAdr (4), length #{length}:"
    s += remote_interface_ip_address.collect {|addr| "\n  #{"  "*ident}#{addr}"}.join
  end

end


=begin rdoc

2.5.5.  Traffic Engineering Metric

   The Traffic Engineering Metric sub-TLV specifies the link metric for
   traffic engineering purposes.  This metric may be different than the
   standard OSPF link metric.  Typically, this metric is assigned by a
   network administrator.

   The Traffic Engineering Metric sub-TLV is TLV type 5, and is four
   octets in length.

=end


class TE_MetricSubTLV < SubTLV
  include Ospf
  
  attr_reader :tlv_type, :length, :te_metric
  attr_writer :te_metric

  def initialize(arg={})
    @tlv_type, @length, @te_metric = 5,4,0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def te_metric=(arg)
    @te_metric=arg[:te_metric] unless arg[:te_metric].nil?
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.te_metric=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@te_metric, 'N'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nnN')
    @tlv_type = arr[0]
    @length= arr[1]
    @te_metric = arr[2]
  end
  private :__parse
  

  def to_hash
    h=super
    h[:te_metric]=te_metric
    h
  end

  def to_s
    self.class.to_s + ": #{te_metric}"
  end
  
  def to_s_junos_style(ident=0)
     "  "*ident + "TEMetric (5), length #{@length}:\n  #{"  "*ident}#{te_metric}"
  end

end

=begin rdoc

2.5.6.  Maximum Bandwidth

   The Maximum Bandwidth sub-TLV specifies the maximum bandwidth that
   can be used on this link, in this direction (from the system
   originating the LSA to its neighbor), in IEEE floating point format.
   This is the true link capacity.  The units are bytes per second.

   The Maximum Bandwidth sub-TLV is TLV type 6, and is four octets in
   length.

=end


class MaximumBandwidth_SubTLV < SubTLV
  include Ospf

  attr_reader :tlv_type, :length, :max_bw
  attr_writer :max_bw

  def initialize(arg={})
    @tlv_type, @length, @max_bw = 6,4,0.0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def max_bw=(arg)
    @max_bw=arg[:max_bw] unless arg[:max_bw].nil?
  end
  
  def set(arg)
    return self unless arg.is_a?(Hash)
    self.max_bw=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@max_bw/8.0, 'g'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nng')
    @tlv_type = arr[0]
    @length= arr[1]
    @max_bw = arr[2] * 8.0
  end
  private :__parse

  def to_hash
    h=super
    h[:max_bw]=max_bw 
    h
  end

  def to_s
    self.class.to_s + ": #{max_bw}"
  end
  
  def to_s_junos_style(ident=0)
    "  "*ident + "MaxBW (6), length #{@length}:\n  #{"  "*ident}#{bw_to_s(max_bw)}"
  end
  
end


=begin rdoc
2.5.7.  Maximum Reservable Bandwidth

   The Maximum Reservable Bandwidth sub-TLV specifies the maximum
   bandwidth that may be reserved on this link, in this direction, in
   IEEE floating point format.  Note that this may be greater than the
   maximum bandwidth (in which case the link may be oversubscribed).
   This SHOULD be user-configurable; the default value should be the
   Maximum Bandwidth.  The units are bytes per second.

   The Maximum Reservable Bandwidth sub-TLV is TLV type 7, and is four
   octets in length.

=end


class MaximumReservableBandwidth_SubTLV < SubTLV
  include Ospf

  attr_reader :tlv_type, :length, :max_resv_bw
  attr_writer :max_resv_bw

  def initialize(arg={})
    @tlv_type, @length, @max_resv_bw = 7,4,0.0
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end

  def max_resv_bw=(arg)
    # should be an array of 8 bw.
    @max_resv_bw=arg[:max_resv_bw] unless arg[:max_resv_bw].nil?
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.max_resv_bw=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@max_resv_bw / 8, 'g'], 
      ])
  end

  def __parse(s)
    arr = s.unpack('nng')
    @tlv_type = arr[0]
    @length= arr[1]
    @max_resv_bw = arr[2] * 8
  end
  private :__parse

  def to_hash
    h=super
    h[:max_resv_bw]=max_resv_bw 
    h
  end

  def to_s
    self.class.to_s + ": #{max_resv_bw}"
  end

  def to_s_junos_style(ident=0)
    "  "*ident + "MaxRsvBW (7), length #{@length}:\n  #{"  "*ident}#{bw_to_s(max_resv_bw)}"
  end

end

=begin rdoc

2.5.8.  Unreserved Bandwidth

   The Unreserved Bandwidth sub-TLV specifies the amount of bandwidth
   not yet reserved at each of the eight priority levels in IEEE
   floating point format.  The values correspond to the bandwidth that
   can be reserved with a setup priority of 0 through 7, arranged in
   increasing order with priority 0 occurring at the start of the sub-
   TLV, and priority 7 at the end of the sub-TLV.  The initial values
   (before any bandwidth is reserved) are all set to the Maximum
   Reservable Bandwidth.  Each value will be less than or equal to the
   Maximum Reservable Bandwidth.  The units are bytes per second.

   The Unreserved Bandwidth sub-TLV is TLV type 8, and is 32 octets in
   length.

=end

class UnreservedBandwidth_SubTLV < SubTLV
  include Ospf

  attr_reader :tlv_type, :unreserved_bw
  attr_writer :unreserved_bw

  def initialize(arg={})
    @tlv_type, @length, @unreserved_bw = 8,4, []
    if arg.is_a?(Hash) then
      set(arg)
    elsif arg.is_a?(String)
      __parse(arg)
    else
      raise ArgumentError, "Invalid argument", caller
    end
  end
  
  def length
    @unreserved_bw.flatten.size*4
  end

  def unreserved_bw=(arg)
    if arg.is_a?(Hash)
      unless arg[:unreserved_bw].nil?
        arg[:unreserved_bw].each { |bw|
          @unreserved_bw << bw
        }
      end
    elsif arg.is_a?(Array) and arg.size==8
      @unreserved_bw = arg
    end
  end
  
  def set(arg)
    return self unless arg.is_a?(Hash)
    self.unreserved_bw=arg
  end

  def enc
    s = __enc([
      [@tlv_type,  'n'], 
      [length, 'n'], 
    ])
    s += @unreserved_bw.collect { |bw| bw / 8 }.pack('g*')        
  end

  def __parse(s)
    arr = s.unpack('nng*')
    @tlv_type = arr[0]
    length= arr[1]
    @unreserved_bw = arr[2..-1].collect {|bw| bw*8 }
  end
  private :__parse

  def to_hash
    h=super
    h[:unreserved_bw] = unreserved_bw
    h
  end
  
  def to_s
    self.class.to_s + ": " + unreserved_bw.collect { |bw| bw }.join(", ")
  end

  def to_s_junos_style(ident=0)
    s = "  "*ident + "UnRsvBW (8), length #{length}:"
    unreserved_bw.each_with_index { |bw,i| s +="\n  #{"  "*ident}Priority #{i}, #{bw_to_s(bw)}" }
    s
  end    

end

=begin rdoc

   The Traffic Engineering Color sub-TLV is TLV type 9, and is four
   octets in length.

=end


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
    @te_metric=arg[:color] unless arg[:color].nil?
  end

  def set(arg)
    return self unless arg.is_a?(Hash)
    self.color=arg
  end

  def enc
    __enc([
      [@tlv_type,  'n'], 
      [@length, 'n'], 
      [@te_metric, 'N'], 
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

