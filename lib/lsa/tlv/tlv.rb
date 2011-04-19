#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2011. All rights reserved.
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

require 'infra/ospf_common'
require 'ie/id'

module OSPFv2
  module Tlv
    module Common
      def stlv_len(n)
        (((n+3)/4)*4)+4
      end
      def tlv_len
        @length
      end
      def to_hash
        {:tlv_type=> tlv_type}
      end
    end
  end
  module SubTlv
    include Tlv
  end
end

