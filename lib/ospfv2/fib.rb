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
  # and, for SR-MPLS (docs/design/sr-ospf.md, step 4), label routes:
  #
  #   add_label(label), replace_label(label), delete_label(label)
  #   dump_labels      our label routes as the kernel holds them now
  #
  # and raises Fib::Error when the kernel says no.
  module Fib
    class Error < StandardError; end

    # RFC 3032 section 2.1: a label never sent; the stack is popped instead.
    IMPLICIT_NULL = 3

    # One kernel route. +next_hops+ are [interface, gateway, label]:
    # gateway an Integer, label the MPLS label pushed on the way out or
    # nil (an [interface, gateway] pair has none). Sorted so equal routes
    # compare equal.
    Route = Struct.new(:prefix, :prefix_len, :next_hops, :metric) do
      def initialize(prefix, prefix_len, next_hops, metric)
        hops = next_hops.map { |i, g, l| [i, g, l] }.sort_by { |i, g, _| [i.to_s, g.to_i] }
        super(prefix, prefix_len, hops.freeze, metric)
      end

      def key = [prefix, prefix_len]

      # The kernel tells routes apart by destination and metric: the same
      # prefix at two metrics is two routes.
      def kernel_key = [prefix, prefix_len, metric]
      def dest_s = "#{Core::Addr.to_s(prefix)}/#{prefix_len}"
      def hops_s = next_hops.map { |i, g, l| (g ? "via #{Core::Addr.to_s(g)} #{i}" : "dev #{i}") + (l ? " push #{l}" : '') }.join(', ')
      def to_s = "#{dest_s} #{hops_s} metric #{metric}"
    end

    # One MPLS label route. +next_hops+ are [interface, gateway, out-label]:
    # out-label nil pops; a next hop with no gateway pops and looks the
    # packet up again, through that interface (lo for our own prefix).
    Label = Struct.new(:label, :next_hops) do
      def initialize(label, next_hops)
        super(label, next_hops.map { |i, g, l| [i, g, l] }.sort_by { |i, g, _| [i.to_s, g.to_i] }.freeze)
      end

      def key = label
      def hops_s = next_hops.map { |i, g, l| "#{l ? "swap #{l}" : 'pop'} #{g ? "via #{Core::Addr.to_s(g)} " : ''}dev #{i}" }.join(', ')
      def to_s = "label #{label} #{hops_s}"
    end
  end
end
