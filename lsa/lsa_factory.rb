require 'lsa/lsa'
require 'lsa/router'
require 'lsa/network'
require 'lsa/summary'
require 'lsa/external'

module OSPFv2
  class Lsa
    class << self
      def factory(arg)
        if arg.is_a?(String)
          return unless (arg.size>=20)
          case arg[3]
          when 1 ; OSPFv2::Router.new_ntop(arg)
          when 2 ; OSPFv2::Network.new_ntop(arg)
          when 3 ; OSPFv2::Summary.new_ntop(arg)
          when 4 ; OSPFv2::AsbrSummary.new_ntop(arg)
          when 5 ; OSPFv2::AsExternal.new_ntop(arg)
          when 7 ; OSPFv2::AsExternal7.new_ntop(arg)
          end
        elsif arg.is_a?(Hash)
          case arg[:ls_type]
          when :router_lsa        ; OSPFv2::Router.new_hash(arg)
          when :network_lsa       ; OSPFv2::Network.new_hash(arg)
          when :summary_lsa       ; OSPFv2::Summary.new_hash(arg)
          when :asbr_summary_lsa  ; OSPFv2::AsbrSummary.new_hash(arg)
          when :as_external_lsa   ; OSPFv2::AsExternal.new_hash(arg)
          when :as_external7_lsa  ; OSPFv2::AsExternal7.new_hash(arg)
          end
        elsif arg.is_a?(Lsa)
          factory(arg.encode)
        end
      end
    end
  end
  
end
