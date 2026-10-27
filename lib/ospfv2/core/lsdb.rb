# frozen_string_literal: true

require_relative 'lsa'

module OSPFv2
  module Core
    # One link state database: an area's, or the AS-wide one for
    # AS-external LSAs.
    #
    # Each LSA is stored with the clock time it was installed. Its age is
    # computed when asked: stored age plus seconds since install, capped at
    # MaxAge. Nothing walks the database once a second to bump ages.
    class Lsdb
      Entry = Struct.new(:lsa, :installed_at, :aged_out) do
        def key = lsa.key
      end

      include Enumerable

      # Called with (new, old) when an install changes the contents
      # (RFC 2328 13.2): what makes SPF run.
      attr_accessor :on_change

      def initialize(clock)
        @clock = clock
        @entries = {}
        @expired = {}      # keys known to be at MaxAge
        @next_expiry = nil # earliest time another LSA can reach MaxAge
      end

      def size
        @entries.size
      end

      def empty?
        @entries.empty?
      end

      def entry(key)
        @entries[key]
      end

      def include?(key)
        @entries.key?(key)
      end

      # The LSA with its current age, or nil.
      def [](key)
        e = @entries[key]
        e && current(e)
      end

      def age(entry)
        [entry.lsa.age + (@clock.now - entry.installed_at).floor, OSPFv2::MaxAge].min
      end

      def current(entry)
        entry.lsa.with_age(age(entry))
      end

      # Seconds since this key was last installed, or nil.
      def since_installed(key)
        e = @entries[key]
        e && @clock.now - e.installed_at
      end

      # Installs +lsa+ (RFC 2328 13.2). Returns the previous copy with its
      # current age, or nil.
      def install(lsa)
        old = self[lsa.key]
        @entries[lsa.key] = Entry.new(lsa, @clock.now, false)
        @on_change&.call(lsa, old) if Lsdb.contents_changed?(old, lsa)
        if lsa.max_age?
          @expired[lsa.key] = true
        else
          @expired.delete(lsa.key)
          expires = @clock.now + OSPFv2::MaxAge - lsa.age
          @next_expiry = expires if @next_expiry.nil? || expires < @next_expiry
        end
        old
      end

      def delete(key)
        @expired.delete(key)
        @entries.delete(key)
      end

      # Yields each LSA with its current age.
      def each
        return enum_for(:each) unless block_given?
        @entries.each_value { |e| yield current(e) }
      end

      def entries
        @entries.values
      end

      # The LSAs not yet at MaxAge, as stored (their ages are stale, but
      # under MaxAge). What SPF reads: no copies.
      def live
        @entries.each_value.filter_map { |e| e.lsa if age(e) < OSPFv2::MaxAge }
      end

      def keys
        @entries.keys
      end

      # Entries whose age has reached MaxAge. Scans the whole database only
      # when some LSA can have aged out since the last scan, so a big,
      # quiet database costs nothing per second.
      def max_age_entries
        now = @clock.now
        if @next_expiry && now >= @next_expiry
          @next_expiry = nil
          @entries.each_value do |e|
            if age(e) >= OSPFv2::MaxAge
              @expired[e.key] = true
            else
              t = e.installed_at + OSPFv2::MaxAge - e.lsa.age
              @next_expiry = t if @next_expiry.nil? || t < @next_expiry
            end
          end
        end
        @expired.keys.filter_map { |k| @entries[k] }
      end

      # Sum of checksums, as routers show it.
      def checksum_sum
        @entries.each_value.sum { |e| e.lsa.checksum }
      end

      # Did the contents change in a way that matters for routing
      # (RFC 2328 13.2)? Age and sequence number alone do not count.
      def self.contents_changed?(old, new)
        return true if old.nil?
        return true if old.options != new.options
        return true if old.max_age? != new.max_age?
        old.length != new.length || old.body != new.body
      end
    end
  end
end
