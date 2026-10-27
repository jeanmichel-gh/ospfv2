# frozen_string_literal: true

# The OSPFv2 router core: interfaces, neighbors, DR election, flooding
# and LSA origination, running on one event loop.
#
#   require 'ospfv2/core'
#
# See OSPFv2::Core::Instance.

require_relative 'infra/event_loop'
require_relative 'infra/transport'
require_relative 'core/instance'
