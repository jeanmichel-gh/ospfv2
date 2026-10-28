# frozen_string_literal: true

require_relative '../config/tree'

module OSPFv2
  module CommandLine
    class Error < StandardError; end

    # The commands ospf-cli understands, as a tree of words. Each word can
    # be abbreviated to a unique prefix, as on Junos and IOS ("sh ip os nei").
    # A command ends at a node with an action; the action is a Hash the
    # shell executes, such as { view: :neighbors, style: :ios }.
    #
    # Junos forms ("show ospf ...") print Junos style, IOS forms
    # ("show ip ospf ...") print IOS style.
    class Grammar
      Node = Struct.new(:word, :help, :children, :action, :arg, keyword_init: true) do
        def arg? = !arg.nil?

        # An argument placeholder such as <router-id>.
        def label = arg? ? arg[:name] : word
      end

      Match = Struct.new(:action, :args)

      DB_TYPES = {
        'router' => 1, 'network' => 2, 'netsummary' => 3, 'asbrsummary' => 4, 'external' => 5
      }.freeze
      IOS_DB_TYPES = {
        'router' => 1, 'network' => 2, 'summary' => 3, 'asbr-summary' => 4, 'external' => 5
      }.freeze

      # Kinds of events ospfd streams (Daemon::Events::KINDS).
      EVENT_KINDS = %w[neighbor interface dr drop spf spf_skipped routes lsa router virtual_link commit log].freeze

      ROUTER_ID = { name: '<router-id>', match: /\A\d{1,3}(\.\d{1,3}){3}\z/ }.freeze
      NUMBER = { name: '<number>', match: /\A\d+\z/ }.freeze
      TEXT = { name: '<text>', match: /./ }.freeze

      attr_reader :root

      def initialize(&block)
        @root = Node.new(word: '', children: [])
        build(@root, &block)
      end

      # Parses words into a Match, or raises CommandLine::Error with a message a
      # router would print.
      def parse(words)
        node = @root
        args = []
        words.each_with_index do |w, i|
          node = step(node, w, words.take(i))
          args << w if node.arg?
        end
        unless node.action
          raise Error, words.empty? ? 'missing command' : "incomplete command: #{words.join(' ')} (type ? for options)"
        end
        Match.new(node.action, args)
      end

      # Possible next words after +words+, as [[label, help]], those that
      # start with +partial+ first. "<cr>" marks a complete command.
      def options(words, partial = '')
        node = @root
        words.each_with_index { |w, i| node = step(node, w, words.take(i)) }
        opts = node.children.select { |c| c.arg? ? partial.empty? || c.arg[:match].match?(partial) : c.word.start_with?(partial) }
                            .map { |c| [c.label, c.help] }
        opts << ['<cr>', 'Execute the command'] if node.action && partial.empty?
        opts
      rescue Error
        []
      end

      # Words that complete +partial+ (Tab).
      def completions(words, partial)
        options(words, partial).map(&:first).reject { |w| w.start_with?('<') }
      end

      private

      def step(node, word, before)
        kw = node.children.reject(&:arg?)
        exact = kw.find { |c| c.word == word }
        return exact if exact
        m = kw.select { |c| c.word.start_with?(word) }
        return m.first if m.size == 1
        if m.size > 1
          raise Error, "ambiguous '#{word}'#{after(before)}: #{m.map(&:word).join(', ')}"
        end
        arg = node.children.find { |c| c.arg? && c.arg[:match].match?(word) }
        return arg if arg
        raise Error, "syntax error, unknown '#{word}'#{after(before)}"
      end

      def after(before) = before.empty? ? '' : " after '#{before.join(' ')}'"

      def build(node, &block)
        Builder.new(node).instance_eval(&block)
      end

      # The DSL inside Grammar.new { ... }.
      class Builder
        def initialize(node)
          @node = node
        end

        def cmd(word, help, action: nil, &block)
          n = Node.new(word: word, help: help, children: [], action: action)
          @node.children << n
          Builder.new(n).instance_eval(&block) if block
          n
        end

        def arg(spec, help, action: nil, &block)
          n = Node.new(word: nil, help: help, children: [], action: action, arg: spec)
          @node.children << n
          Builder.new(n).instance_eval(&block) if block
          n
        end
      end

      # ---- the two modes ----

      OPERATIONAL = new do
        cmd 'show', 'Show information' do
          cmd 'ospf', 'OSPF information (Junos style)' do
            cmd 'neighbor', 'Neighbors', action: { view: :neighbors, style: :junos } do
              cmd 'detail', 'With timers and counters', action: { view: :neighbors, style: :junos, detail: true }
            end
            cmd 'interface', 'Interfaces', action: { view: :interfaces, style: :junos } do
              cmd 'detail', 'With timers and authentication', action: { view: :interfaces, style: :junos, detail: true }
            end
            cmd 'database', 'Link state database', action: { view: :database, style: :junos } do
              cmd 'detail', 'With LSA contents', action: { view: :database, style: :junos, detail: true }
              DB_TYPES.each do |word, type|
                cmd word, "#{word.capitalize} LSAs", action: { view: :database, style: :junos, type: type } do
                  cmd 'detail', 'With LSA contents', action: { view: :database, style: :junos, type: type, detail: true }
                end
              end
            end
            cmd 'route', 'OSPF routing table', action: { view: :routes, style: :junos } do
              cmd 'detail', 'With area, origin and tag', action: { view: :routes, style: :junos, detail: true }
            end
            cmd 'overview', 'Router id, areas, counts', action: { view: :overview, style: :junos }
            cmd 'log', 'SPF runs: when, why, how long', action: { view: :spf, style: :junos }
            cmd 'events', 'Recent protocol events', action: { view: :log, style: :junos }
            cmd 'statistics', 'Packet counters per interface', action: { view: :statistics, style: :junos }
          end
          cmd 'ip', 'IP information (IOS style)' do
            cmd 'ospf', 'OSPF process', action: { view: :overview, style: :ios } do
              cmd 'neighbor', 'Neighbors', action: { view: :neighbors, style: :ios } do
                cmd 'detail', 'With timers and counters', action: { view: :neighbors, style: :ios, detail: true }
              end
              cmd 'interface', 'Interfaces', action: { view: :interfaces, style: :ios, detail: true } do
                cmd 'brief', 'One line per interface', action: { view: :interfaces, style: :ios }
              end
              cmd 'database', 'Link state database', action: { view: :database, style: :ios } do
                IOS_DB_TYPES.each do |word, type|
                  cmd word, "#{word.capitalize} LSAs", action: { view: :database, style: :ios, type: type, detail: true }
                end
              end
              cmd 'route', 'OSPF routing table', action: { view: :routes, style: :ios }
              cmd 'statistics', 'SPF runs', action: { view: :spf, style: :ios }
              cmd 'traffic', 'Packet counters per interface', action: { view: :statistics, style: :ios }
              cmd 'events', 'Recent protocol events', action: { view: :log, style: :ios }
            end
            cmd 'route', 'IP routing table' do
              cmd 'ospf', 'OSPF routes in the kernel', action: { view: :fib, style: :ios }
            end
          end
          cmd 'route', 'Routing table (Junos style)' do
            cmd 'protocol', 'Routes of one protocol' do
              cmd 'ospf', 'OSPF routes in the kernel', action: { view: :fib, style: :junos }
            end
          end
          cmd 'configuration', 'Running configuration', action: { view: :configuration }
        end
        cmd 'clear', 'Reset state' do
          cmd 'ospf', 'OSPF (Junos style)' do
            cmd 'neighbor', 'Bring adjacencies down and up again', action: { clear: :neighbors } do
              arg ROUTER_ID, 'Only this neighbor', action: { clear: :neighbors }
            end
          end
          cmd 'ip', 'IP (IOS style)' do
            cmd 'ospf', 'OSPF' do
              cmd 'process', 'Bring every adjacency down and up again', action: { clear: :neighbors }
            end
          end
        end
        cmd 'monitor', 'Watch events as they happen (Ctrl-C stops)' do
          cmd 'ospf', 'OSPF (Junos style)' do
            cmd 'events', 'Protocol events, all kinds or some', action: { monitor: :events } do
              EVENT_KINDS.each do |k|
                cmd k, "#{k.tr('_', ' ').capitalize} events", action: { monitor: :events, kinds: [k] }
              end
            end
          end
          cmd 'ip', 'IP (IOS style)' do
            cmd 'ospf', 'OSPF' do
              cmd 'events', 'Protocol events', action: { monitor: :events }
            end
          end
        end
        cmd 'configure', 'Enter configuration mode', action: { mode: :configure } do
          cmd 'terminal', 'Enter configuration mode (IOS style)', action: { mode: :configure }
        end
        cmd 'help', 'How to use this CLI', action: { help: true }
        cmd 'exit', 'Leave the CLI', action: { exit: true }
        cmd 'quit', 'Leave the CLI', action: { exit: true }
      end

      # Configuration mode. set and delete take statements checked against
      # Config::Schema; see ConfigCompleter.
      CONFIGURE = new do
        cmd 'set', 'Set a configuration statement', action: { config: :set }
        cmd 'delete', 'Delete a configuration statement', action: { config: :delete }
        cmd 'show', 'Candidate configuration', action: { config: :show }
        cmd 'compare', 'Changes not yet committed', action: { config: :compare }
        cmd 'commit', 'Make the candidate the running configuration', action: { config: :commit } do
          cmd 'check', 'Check the candidate, change nothing', action: { config: :commit, check: true }
          cmd 'comment', 'Commit with a comment' do
            arg TEXT, 'Comment text', action: { config: :commit }
          end
        end
        cmd 'rollback', 'Load the running configuration (or an older one) into the candidate',
            action: { config: :rollback } do
          arg NUMBER, 'How many commits back, 1..9', action: { config: :rollback }
        end
        cmd 'discard', 'Throw away uncommitted changes', action: { config: :discard }
        cmd 'history', 'Recent commits', action: { config: :history }
        cmd 'run', 'Run an operational command', action: { config: :run }
        cmd 'exit', 'Leave configuration mode', action: { mode: :operational }
        cmd 'end', 'Leave configuration mode (IOS style)', action: { mode: :operational }
        cmd 'quit', 'Leave configuration mode', action: { mode: :operational }
      end
    end

    # Completion and help for the statements after set and delete, from
    # the configuration schema.
    module ConfigCompleter
      module_function

      # [[label, help]] for the word after +words+ (the statement so far).
      # +siblings+: after a leaf or flag, offer the leaves and flags beside
      # it, as set allows ("stub default-metric 10 no-summaries"); delete
      # takes one statement.
      def options(words, partial = '', siblings: true)
        node = Config::Schema::ROOT
        i = 0
        after_leaf = false
        while i < words.size
          child = find(node, words[i]) or return []
          return [] if after_leaf && !%i[leaf flag].include?(child.kind)
          case child.kind
          when :container
            node = child
            i += 1
          when :list
            return [[hint(child.type), "#{child.help} name"]] if i + 1 == words.size && partial.empty?
            return [] if i + 1 == words.size
            node = child
            i += 2
          when :leaf
            return [[hint(child.type), child.help]] if i + 1 == words.size
            return [['<cr>', '']] unless siblings
            i += 2 # its siblings may follow on the same line
            after_leaf = true
          when :flag
            return [['<cr>', '']] unless siblings
            i += 1
            after_leaf = true
          when :keyed_leaf
            rest = words.size - i - 1
            return [[hint(child.type), 'Key id']] if rest.zero?
            return [[child.sub[0], 'Secret for this key']] if rest == 1
            return rest == 2 ? [[hint(child.sub[1]), 'Secret']] : [['<cr>', '']]
          end
        end
        kids = node.children.values
        kids = kids.select { |c| %i[leaf flag].include?(c.kind) } if after_leaf
        opts = kids.select { |c| c.name.start_with?(partial) }.map { |c| [c.name, c.help.to_s] }
        opts << ['<cr>', ''] if !words.empty? && partial.empty? && node.inner?
        opts
      end

      def completions(words, partial, siblings: true)
        options(words, partial, siblings: siblings).map(&:first).reject { |w| w.start_with?('<') }
                                                    .select { |w| w.start_with?(partial) }
      end

      def find(node, word)
        return nil unless node.inner?
        m = node.matches(word)
        m.size == 1 ? m.first : nil
      end

      def hint(type) = Config::Schema::HINTS.fetch(type, '<value>')
    end
  end
end
