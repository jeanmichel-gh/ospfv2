#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# OSPFv2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OSPFv2.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'observer'
require 'thread'

class Timer
  include Observable

  class << self
    def start interval, observer=nil, &block
      timer = if block
        new interval, observer, &block
      else
        new interval, observer
      end
      timer.start
    end
  end

  def initialize interval, observer=nil, &block
    @interval = interval
    @code = block if block
    add_observer observer if observer
    @_timer_thread_ = nil
  end

  def start _interval=@interval, &block
    stop if running?
    changed and notify_observers(:ev_timer_start, id, Time.now.strftime("%M:%S"))
    _code = block || @code
    @_timer_thread_ = Thread.new(_interval, _code) do |interval, code|
      sleep(interval)
      code.call if code
      changed and notify_observers(:ev_timer_fire, id, Time.now.strftime("%M:%S"))
    end
    self
  end

  def cancel
    return unless @_timer_thread_
    [:exit, :join].each { |x| @_timer_thread_.send x }
    changed and notify_observers(:ev_timer_cancel, id, Time.now.strftime("%M:%S"))
    yield if block_given?
  end
  alias :stop :cancel

  def running?
    @_timer_thread_ and @_timer_thread_.alive?
  end

  def reset &block
    cancel
    start(&block)
  end

  private

  def id
    self.class.to_s.to_sym
  end

end

class PeriodicTimer < Timer
  def start _interval=@interval, &block
    @continue = true
    changed and notify_observers(:ev_timer_start, id, Time.now.strftime("%M:%S"))
    _code = block || @code
    @_timer_thread_ = Thread.new(_interval, _code) do |interval, code|
      loop do
        sleep(interval)
        code.call if code
        changed and notify_observers(:ev_timer_fire, id, Time.now.strftime("%M:%S"))
        break unless @continue
      end
      changed and notify_observers(:ev_timer_stop, id, Time.now.strftime("%M:%S"))
    end
    self
  end
  def last_shot
    @continue = false
  end
end

load "../../../test/ospfv2/infra/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
