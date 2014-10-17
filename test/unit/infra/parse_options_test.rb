
require "test/unit"

require "infra/parse_options"

class TestOptParse < Test::Unit::TestCase

  def test_parse_grid
    assert_equal [2,2], parse.grid
    assert_equal [3,4], parse('--grid 3x4').grid
    assert_equal [3,4], parse('-g 3x4').grid
  end
  def test_parse_area_id
    assert_equal 0, parse.area_id
    assert_equal 1, parse('--area-id 1').area_id
    assert_equal 2, parse('--area-id 0.0.0.2').area_id
    assert_equal 2, parse('-a 0.0.0.2').area_id
  end
  def test_parse_router_id
    assert_equal 1, parse.router_id
    assert_equal 2, parse('--router-id 2').router_id
    assert_equal 2, parse('-r 0.0.0.2').router_id
  end
  def test_parse_ipaddr
    assert_equal '192.168.1.123' ,parse.ipaddr
    assert_equal '1.1.1.1' ,parse('--address 1.1.1.1/23').ipaddr
    assert_equal '255.255.254.0' ,parse('--address 1.1.1.1/23').netmask
  end
  def test_hello_int
    assert_equal 10, parse.hello_int
    assert_equal 60, parse('--hello-int 60').hello_int
    assert_equal 40, parse.dead_int
    assert_equal 20, parse('--hello-int 20').hello_int
    assert_equal 80, parse('--hello-int 20').dead_int
    assert_equal 200, parse('--hello-int 20 --dead-int 200').dead_int
    assert_equal 200, parse('--dead-int 200').dead_int
    assert_equal 10, parse('--dead-int 200').hello_int
  end
  def test_num_of
    assert_equal 10, parse.num_sum
    assert_equal 10, parse.num_ext
    assert_equal 20, parse('--number-of-summary 20').num_sum
    assert_equal 20, parse('--number-of-external 20').num_ext
  end

  private
  
  def set(a, v)
    a.clear
    v.each { |x| a << x }
  end
  
  def parse(s='')
    set ARGV, s.split
    OptParse.parse(ARGV)
  end

end
