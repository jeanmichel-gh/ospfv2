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

require_relative  '../infra/ospf_constants'

module OSPFv2
class LsAge

  # One aging clock shared by every LSA, whatever LsAge subclass it uses.
  # It only advances while aging is on, so freezing holds every age where
  # it is and resuming continues from there.
  module Clock
    @lock = Mutex.new
    @accumulated = 0.0
    @since = nil

    class << self
      def now
        @lock.synchronize { @accumulated + (@since ? monotonic - @since : 0) }
      end

      def running?
        @lock.synchronize { !@since.nil? }
      end

      def start
        @lock.synchronize { @since ||= monotonic }
      end

      def stop
        @lock.synchronize do
          @accumulated += monotonic - @since if @since
          @since = nil
        end
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  class << self
    def aging?
      Clock.running?
    end

    # :on, :off, or no argument to toggle.
    def aging(arg=nil)
      on = arg.nil? ? !aging? : arg == :on || arg == true
      on ? Clock.start : Clock.stop
      aging?
    end
  end

  include Comparable

  def initialize(age=0)
    raise ArgumentError, "Invalid Argument #{age}" unless age.is_a?(Integer)
    @age=age
    @start = Clock.now
  end

  # Current age. Aging stops at MaxAge. An age already at or above MaxAge,
  # such as a DoNotAge value (RFC 1793, high bit set), is left as is.
  def to_i
    return @age if @age >= OSPFv2::MaxAge
    [(@age + Clock.now - @start).to_i, OSPFv2::MaxAge].min
  end

  def reset(age=nil)
    @age = age if age
    @start = Clock.now
  end

  def aging?
    self.class.aging?
  end

  def maxage
    reset(OSPFv2::MaxAge)
    to_i
  end
  
  def maxaged?
    to_i >= OSPFv2::MaxAge
  end
  
  def <=>(obj)
    to_i <=> obj.to_i
  end
  
  def -(obj)
    to_i - obj.to_i
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def to_s_ios
    "LS age: #{to_i}"
  end
  
  # The age on the wire is the current age (it was always the initial one).
  def encode
    [to_i].pack('n')
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

