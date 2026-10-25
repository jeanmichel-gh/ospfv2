# Opaque LSA support (RFC 5250).
#
# The opaque header handling (Opaque Type + Opaque ID in place of the
# Link State ID) lives in Lsa itself. This file exists so that opaque
# LSA subclasses such as TrafficEngineering can load it explicitly.

require_relative 'lsa'
require_relative '../ie/opaque_id'
require_relative '../ie/opaque_type'
