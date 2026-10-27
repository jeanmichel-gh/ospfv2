# frozen_string_literal: true

require 'json'
require_relative 'grammar'
require_relative 'format'
require_relative 'client'

module OSPFv2
  module CommandLine
    # The ospf-cli command interpreter: operational and configuration
    # modes, output pipes, ? help and Tab completion.
    #
    #   shell = Shell.new(Client.new)
    #   puts shell.execute('show ospf neighbor')
    #   shell.interactive        # prompt loop on a terminal
    #
    # #execute returns the text to print; it never prints itself, so tests
    # and one-shot mode (ospf-cli -c) share the same path.
    class Shell
      PIPES = {
        'match' => :match, 'include' => :match, 'except' => :except, 'exclude' => :except,
        'count' => :count, 'display' => :display, 'json' => :json, 'compare' => :compare,
        'no-more' => :none, 'last' => :last
      }.freeze

      HELP = <<~TXT
        Commands take Junos or IOS forms, and any unique prefix of a word:
          show ospf neighbor          show ip ospf neighbor       sh ip os nei
          show ospf interface         show ip ospf interface brief
          show ospf database          show ip ospf database router
          show ospf overview          show ip ospf
          show ospf log               show configuration
          clear ospf neighbor         clear ip ospf process
          configure                   (then set, delete, show, compare, commit, rollback, exit)
        Type ? at the end of a line for the options there, Tab to complete.
        Pipes: | match REGEX, | except REGEX, | count, | last N, | display json, | display set
      TXT

      attr_reader :mode

      def initialize(client, hostname: 'ospf')
        @client = client
        @hostname = hostname
        @mode = :operational
      end

      def prompt
        @mode == :configure ? "#{@hostname}# " : "#{@hostname}> "
      end

      # Runs one line and returns its output (possibly empty). Errors come
      # back as text, the way a router prints them.
      def execute(line)
        line = line.to_s.strip
        return '' if line.empty? || line.start_with?('#')
        return help(line.chomp('?').rstrip, line.end_with?(' ?') || line == '?') if line.end_with?('?')

        cmd, *pipes = split_pipes(line)
        words = Config::Tree.split(cmd)
        out = @mode == :configure ? configure_command(words, pipes) : operational(words, pipes)
        out.is_a?(String) ? out : out.to_s
      rescue Error, Config::Error => e
        "error: #{e.message}"
      end

      # Words that can complete +partial+ given the +before+ text (Tab).
      def completions(before, partial)
        words = Config::Tree.split(before)
        return [] if before.include?('|')
        if @mode == :configure && %w[set delete].any? { |w| words.first&.then { |f| w.start_with?(f) && f.size.positive? } && words.size >= 1 }
          ConfigCompleter.completions(words.drop(1), partial)
        else
          grammar.completions(words, partial)
        end
      rescue Config::Error
        []
      end

      def exit? = @exit

      # The prompt loop. Uses Reline when on a terminal.
      def interactive(input: $stdin, output: $stdout)
        if input.tty?
          require 'reline'
          Reline.completion_proc = lambda do |partial|
            before = Reline.line_buffer.to_s[0, Reline.point.to_i - partial.size]
            completions(before, partial)
          end
          Reline.completion_append_character = ' '
          Reline.completer_word_break_characters = " \t"
          prefill = nil
          until @exit
            Reline.pre_input_hook = prefill ? -> { Reline.insert_text(prefill) } : nil
            line = Reline.readline(prompt, true)
            break if line.nil?
            prefill = line.strip.end_with?('?') ? "#{line.strip.chomp('?').rstrip} ".lstrip : nil
            out = execute(line)
            output.puts(out) unless out.empty?
          end
        else
          input.each_line do |line|
            out = execute(line)
            output.puts(out) unless out.empty?
            break if @exit
          end
        end
      end

      private

      def grammar = @mode == :configure ? Grammar::CONFIGURE : Grammar::OPERATIONAL

      # ---- ? help ----

      def help(line, after_space)
        words = Config::Tree.split(line)
        partial = after_space || words.empty? ? '' : words.pop
        opts = if @mode == :configure && words.first && %w[set delete].include?(expand_config(words.first))
                 ConfigCompleter.options(words.drop(1), partial)
               else
                 grammar.options(words, partial)
               end
        return "error: no options after '#{line}'" if opts.empty?
        width = opts.map { |o| o[0].size }.max
        "Possible completions:\n" + opts.map { |w, h| "  #{w.ljust(width)}  #{h}".rstrip }.join("\n")
      end

      def expand_config(word)
        %w[set delete].find { |w| w.start_with?(word) }
      end

      # ---- operational mode ----

      def operational(words, pipes)
        m = Grammar::OPERATIONAL.parse(words)
        a = m.action
        return HELP if a[:help]
        if a[:exit]
          @exit = true
          return ''
        end
        if a[:mode] == :configure
          @mode = :configure
          return "Entering configuration mode#{changed_note}"
        end
        if a[:clear]
          n = @client.call('clear.neighbors', router_id: m.args.first)['cleared']
          return "#{n} neighbor#{n == 1 ? '' : 's'} cleared"
        end
        run_view(a, pipes)
      end

      def run_view(a, pipes)
        if a[:view] == :configuration
          set = pipes.any? { |p| p == %w[display set] }
          text = @client.call('show.configuration', format: set ? 'set' : 'curly')
          return pipe(text, pipes.reject { |p| p == %w[display set] }, nil)
        end
        method = "show.#{a[:view]}"
        params = a[:view] == :database ? { detail: a[:detail] || a[:style] == :ios } : {}
        data = @client.call(method, params)
        router_id = needs_router_id?(a) ? @client.call('show.overview')['router_id'] : nil
        text = Format.render(a[:view], a[:style], data, detail: a[:detail], type: a[:type], router_id: router_id)
        pipe(text, pipes, data)
      end

      def needs_router_id?(a)
        a[:style] == :ios && %i[interfaces database].include?(a[:view])
      end

      # ---- configuration mode ----

      def configure_command(words, pipes)
        verb = words.first
        if verb && (full = expand_config(verb)) && words.size > 1
          errors = @client.call('config.load', lines: ["#{full} #{words.drop(1).map { |w| Config::Tree.quote(w) }.join(' ')}"])['errors']
          return errors.map { |e| "error: #{e.sub(/\Aline 1: /, '').sub(/: (set|delete) .*\z/, '')}" }.join("\n")
        end

        m = Grammar::CONFIGURE.parse(words.empty? ? [] : [words.first])
        a = m.action
        rest = words.drop(1)
        if a[:mode] == :operational
          note = @client.call('config.changed') ? "\nThe configuration has been changed but not committed" : ''
          @mode = :operational
          return "Exiting configuration mode#{note}"
        end
        case a[:config]
        when :set, :delete then "error: missing statement after '#{verb}'"
        when :show
          if pipes.include?(['compare'])
            return compare_text
          end
          set = pipes.any? { |p| p == %w[display set] }
          text = @client.call('show.configuration', candidate: true, format: set ? 'set' : 'curly')
          pipe(text, pipes.reject { |p| p == %w[display set] }, nil)
        when :compare then compare_text
        when :commit then commit(rest)
        when :rollback
          n = rest.first || '0'
          raise Error, "rollback takes a number 0..9, got '#{n}'" unless n.match?(/\A\d\z/)
          @client.call('config.rollback', number: n.to_i)
          "load complete#{n == '0' ? '' : ", rollback #{n} loaded into the candidate; commit to apply"}"
        when :discard
          @client.call('config.discard')
          'Uncommitted changes discarded'
        when :history
          @client.call('config.history').each_with_index.map do |c, i|
            "#{i}  #{c['time'].sub('T', ' ').sub('Z', ' UTC')}  #{c['changes']} change(s)#{c['comment'] ? "  #{c['comment']}" : ''}"
          end.join("\n")
        when :run
          raise Error, 'run what? e.g. run show ospf neighbor' if rest.empty?
          operational(rest, pipes)
        end
      end

      def commit(rest)
        check = rest.first && 'check'.start_with?(rest.first)
        comment = rest.first && 'comment'.start_with?(rest.first) && !check ? rest.drop(1).join(' ') : nil
        r = @client.call('config.commit', check: check ? true : false, comment: comment)
        return (["error: commit failed"] + r['errors'].map { |e| "  #{e}" }).join("\n") unless r['ok']
        out = r['warnings'].map { |w| "warning: #{w}" }
        out << (check ? 'configuration check succeeds' : 'commit complete')
        out.join("\n")
      end

      def compare_text
        lines = @client.call('config.compare')
        lines.empty? ? '[no changes]' : lines.join("\n")
      end

      def changed_note
        @client.call('config.changed') ? "\nThe configuration has been changed but not committed" : ''
      rescue Error
        ''
      end

      # ---- pipes ----

      def split_pipes(line)
        parts = line.split(/\s+\|\s*/)
        [parts.first, *parts.drop(1).map { |p| Config::Tree.split(p) }]
      end

      def pipe(text, pipes, data)
        pipes.each do |p|
          word, *args = p
          kind = PIPES.select { |k, _| k.start_with?(word.to_s) }
          kind = { word => PIPES[word] } if PIPES.key?(word)
          raise Error, "unknown pipe '#{word}' (match, except, count, last, display json, display set)" unless kind.size == 1
          case kind.values.first
          when :match then text = grep(text, args, true)
          when :except then text = grep(text, args, false)
          when :count then text = "Count: #{text.lines.size} lines"
          when :last then text = text.lines.last((args.first || '10').to_i).join.chomp
          when :json then text = json(data)
          when :display
            raise Error, "display what? (json, set)" if args.empty?
            raise Error, "unknown display '#{args.first}'" unless 'json'.start_with?(args.first)
            text = json(data)
          when :compare then raise Error, '| compare works on show in configuration mode'
          when :none then nil
          end
        end
        text
      end

      def grep(text, args, keep)
        raise Error, "missing pattern after | #{keep ? 'match' : 'except'}" if args.empty?
        re = Regexp.new(args.join(' '), Regexp::IGNORECASE)
        text.lines.select { |l| re.match?(l) == keep }.join.chomp
      rescue RegexpError => e
        raise Error, "bad pattern: #{e.message}"
      end

      def json(data)
        raise Error, 'no JSON for this command' if data.nil?
        JSON.pretty_generate(data)
      end
    end
  end
end
