require 'test/unit'
require 'ospfv2'

# Every packet type must survive encode -> factory -> encode unchanged.
class TestPacketRoundTrip < Test::Unit::TestCase
  include OSPFv2

  def setup
    LSDB::Link.reset
    @db = LSDB::LinkStateDatabase.create(columns: 2, rows: 2)
    @db << Summary.new(advertising_router: 1, network: '30.0.0.0/24', metric: 10)
    @db << AsExternal.new(advertising_router: 1, network: '50.0.0.0/24', metric: 20, type: :e2, tag: 9)
  end

  def round_trip(pkt)
    bytes = pkt.encode
    back = OspfPacket.factory(bytes)
    assert_instance_of pkt.class, back
    assert_equal bytes.unpack1('H*'), back.encode.unpack1('H*')
    back
  end

  def test_hello
    h = Hello.new(router_id: '1.1.1.1', area_id: 3, netmask: '255.255.255.0', hello_interval: 5,
                  router_dead_interval: 20, designated_router_id: '10.0.0.1')
    h.neighbors = '2.2.2.2'
    back = round_trip(h)
    assert back.has_neighbor?('2.2.2.2')
    assert_equal 5, back.hello_interval
    assert_equal 3, back.area_id.to_i
  end

  def test_database_description_with_headers
    dd = DatabaseDescription.new(router_id: 1, area_id: 0, ls_db: @db, dd_sequence_number: 77)
    back = round_trip(dd)
    headers = []
    back.each { |h| headers << h.key }
    assert_equal @db.keys.sort, headers.sort
  end

  def test_link_state_request
    lsr = LinkStateRequest.new(router_id: 1, area_id: 0, requests: @db.keys)
    round_trip(lsr)
  end

  def test_link_state_update_and_ack
    lsu = LinkStateUpdate.new_lsas(router_id: 1, area_id: 0, lsas: @db.all).first
    back = round_trip(lsu)
    assert_equal @db.size, back.lsas.size
    ack = LinkStateAck.ack_ls_update(back, router_id: 2, area_id: 0)
    assert_equal @db.size, round_trip(ack).lsa_headers.size
  end

  def test_ospf_checksum_is_valid
    bytes = Hello.new(router_id: 1, netmask: '255.255.255.0').encode
    words = (bytes[0, 16] + bytes[24..]).unpack('n*')
    sum = words.sum
    sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
    assert_equal 0xffff, sum
  end
end
