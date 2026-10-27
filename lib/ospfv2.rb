# frozen_string_literal: true

# OSPFv2 packet, LSA and neighbor implementation used to simulate
# OSPF topologies against a device under test.
#
#   require 'ospfv2'
#
# loads the full library: information elements, LSAs, packets,
# the link state database builders and the neighbor state machine.

require_relative 'ospfv2/version'
require_relative 'ospfv2/infra/ospf_common'
require_relative 'ospfv2/infra/ospf_constants'
require_relative 'ospfv2/infra/event_loop'
require_relative 'ospfv2/lsa/lsa_factory'
require_relative 'ospfv2/packet/packets'
require_relative 'ospfv2/ls_db/link_state_database'
require_relative 'ospfv2/ls_db/link_state_database_links'
require_relative 'ospfv2/neighbor/neighbor'
