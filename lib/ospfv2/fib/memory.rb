# frozen_string_literal: true

module OSPFv2
  module Fib
    # A kernel table in a Hash, for tests and for running without touching
    # the host. Records every call. +fail+ makes chosen routes fail:
    #
    #   m = Fib::Memory.new
    #   m.fail[[prefix, len]] = 'Network is unreachable'
    class Memory
      attr_reader :table, :calls, :fail

      def initialize
        @table = {}
        @calls = []
        @fail = {}
      end

      def replace(route)
        @calls << [:replace, route.to_s]
        check(route)
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
