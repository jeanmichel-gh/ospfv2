# frozen_string_literal: true

require_relative 'core/addr'
require_relative 'fib/memory'
require_relative 'fib/manager'

module OSPFv2
  # The forwarding table: getting the routes OSPF computed into the kernel.
  #
  # Fib::Manager decides what should be installed and keeps the kernel in
  # line with it. A backend does the installing: Fib::Netlink on Linux,
  # Fib::Memory in tests. A backend knows three things:
  #
  #   add(route)       a route new to us; refused if the kernel has a route
  #                    to that prefix at that metric already, anyone's
  #   replace(route)   change a route that is ours
  #   delete(route)    remove it (gone already is fine)
  #   dump             our routes as the kernel holds them now
  #
  # and raises Fib::Error when the kernel says no.
  module Fib
    class Error < StandardError; end

    # One kernel route. +next_hops+ are [interface, gateway] pairs, gateway
    # an Integer, sorted so equal routes compare equal.
    Route = Struct.new(:prefix, :prefix_len, :next_hops, :metric) do
      def initialize(prefix, prefix_len, next_hops, metric)
        super(prefix, prefix_len, next_hops.sort_by { |i, g| [i.to_s, g.to_i] }.freeze, metric)
      end

      def key = [prefix, prefix_len]

      # The kernel tells routes apart by destination and metric: the same
      # prefix at two metrics is two routes.
      def kernel_key = [prefix, prefix_len, metric]
      def dest_s = "#{Core::Addr.to_s(prefix)}/#{prefix_len}"
      def hops_s = next_hops.map { |i, g| g ? "via #{Core::Addr.to_s(g)} #{i}" : "dev #{i}" }.join(', ')
      def to_s = "#{dest_s} #{hops_s} metric #{metric}"
    end
  end
end
