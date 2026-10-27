# frozen_string_literal: true

# Loads the OSPF packet base class and every packet type, which
# OspfPacket.factory needs. Require this rather than ospf_packet.rb.
require_relative 'ospf_packet'
require_relative 'hello'
require_relative 'database_description'
require_relative 'link_state_request'
require_relative 'link_state_update'
require_relative 'link_state_ack'
