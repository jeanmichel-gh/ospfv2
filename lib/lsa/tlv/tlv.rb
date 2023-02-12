#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require_relative '../../infra/ospf_common'
require_relative '../../ie/id'

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
