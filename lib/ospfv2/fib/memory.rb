# frozen_string_literal: true

module OSPFv2
  module Fib
    # A kernel table in a Hash, for tests and for running without touching
    # the host. Records every call. +fail+ makes chosen routes fail;
    # +foreign+ holds routes of other protocols, which add refuses to
    # overwrite as the kernel does:
    #
    #   m = Fib::Memory.new
    #   m.fail[[prefix, len]] = 'Network is unreachable'
    #   m.foreign << [prefix, len, metric]
    class Memory
      attr_reader :table, :calls, :fail, :foreign

      def initialize
        @table = {}
        @calls = []
        @fail = {}
        @foreign = []
      end

      def add(route)
        @calls << [:add, route.to_s]
        check(route)
        if @table.key?(route.kernel_key) || @foreign.include?(route.kernel_key)
          raise Error, "another route to #{route.dest_s} with metric #{route.metric} is in the kernel"
        end
        @table[route.kernel_key] = route
      end

      def replace(route)
        @calls << [:replace, route.to_s]
        check(route)
        raise Error, "another route to #{route.dest_s} with metric #{route.metric} is in the kernel" if @foreign.include?(route.kernel_key) && !@table.key?(route.kernel_key)
        @table[route.kernel_key] = route
      end

      def delete(route)
        @calls << [:delete, route.to_s]
        check(route)
        @table.delete(route.kernel_key)
      end

      def dump = @table.values

      def close; end

      private

      def check(route)
        why = @fail[route.key] or return
        raise Error, why
      end
    end
  end
end
