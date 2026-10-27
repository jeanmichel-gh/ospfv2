# frozen_string_literal: true

require_relative 'schema'

module OSPFv2
  module Config
    # A configuration as nested Hashes, edited with Junos-style statements.
    #
    #   t = Tree.new
    #   t.set('set protocols ospf area 0 interface eth1 metric 10')
    #   t.delete('delete protocols ospf area 0.0.0.0 interface eth1 metric')
    #   puts t.to_curly          # protocols { ospf { ... } }
    #   puts t.to_set            # set protocols ospf ...
    #
    # Words may be abbreviated to any unique prefix ("set prot ospf ar 0").
    # Secrets render as HIDDEN unless asked otherwise, and HIDDEN is
    # refused on input so a pasted display cannot overwrite a secret.
    class Tree
      HIDDEN = '<hidden>'

      attr_reader :data

      def initialize(data = {})
        @data = data
      end

      def self.parse(text)
        t = new
        errors = t.load(text)
        raise Error, errors.join("\n") unless errors.empty?
        t
      end

      def dup = Tree.new(Marshal.load(Marshal.dump(@data)))
      def ==(other) = other.is_a?(Tree) && to_set(hide: false) == other.to_set(hide: false)
      def empty? = @data.empty?

      # Applies "set ..." / "delete ..." lines; blank lines and # comments
      # are skipped. Returns the errors, each naming its line.
      def load(text)
        errors = []
        text.each_line.with_index(1) do |line, n|
          line = line.strip
          next if line.empty? || line.start_with?('#')
          begin
            apply(line)
          rescue Error => e
            errors << "line #{n}: #{e.message}: #{Tree.hide_secrets(line)}"
          end
        end
        errors
      end

      # One "set ..." or "delete ..." statement.
      def apply(line)
        words = Tree.split(line)
        case words.first
        when 'set' then set(words.drop(1))
        when 'delete' then delete(words.drop(1))
        else raise Error, "expected set or delete, got '#{words.first}'"
        end
      end

      # Adds one statement. All or nothing: a statement that fails part
      # way leaves the tree as it was.
      def set(words)
        before = Marshal.dump(@data)
        set!(words)
      rescue Error
        @data.replace(Marshal.load(before))
        raise
      end

      def set!(words)
        words = Tree.split(words) if words.is_a?(String)
        raise Error, 'missing statement' if words.empty?
        node = Schema::ROOT
        data = @data
        i = 0
        after_leaf = false
        loop do
          child = resolve(node, words[i], words.take(i))
          if after_leaf && !%i[leaf flag].include?(child.kind)
            raise Error, "'#{words[i]}' cannot follow a value on the same line; give it its own set"
          end
          path = words.take(i) + [child.name]
          case child.kind
          when :container
            data = (data[child.name] ||= {})
            node = child
            i += 1
            return self if i == words.size
          when :list
            key = value(child, child.type, words[i + 1], path)
            data = ((data[child.name] ||= {})[key] ||= {})
            node = child
            i += 2
            return self if i == words.size
          # A leaf or flag may be followed by its siblings, as on Junos:
          # "stub default-metric 10 no-summaries".
          when :leaf
            v = value(child, child.type, words[i + 1], path)
            data[child.name] = v
            i += 2
            return self if i == words.size
            after_leaf = true
          when :flag
            data[child.name] = true
            i += 1
            return self if i == words.size
            after_leaf = true
          when :keyed_leaf
            key = value(child, child.type, words[i + 1], path)
            sub, sub_type = child.sub
            word = words[i + 2] or raise Error, "missing '#{sub}' after #{(path + [key]).join(' ')}"
            raise Error, "expected '#{sub}', got '#{word}'" unless sub.start_with?(word)
            v = value(child, sub_type, words[i + 3], path + [key, sub])
            extra!(words, i + 4)
            (data[child.name] ||= {})[key] = v
            return self
          end
        end
      end

      def delete(words)
        words = Tree.split(words) if words.is_a?(String)
        raise Error, 'missing statement' if words.empty?
        node = Schema::ROOT
        data = @data
        trail = [] # containers left empty by the delete are removed too
        i = 0
        loop do
          child = resolve(node, words[i], words.take(i))
          raise Error, 'statement not found' unless data.key?(child.name)
          case child.kind
          when :container
            if i + 1 == words.size
              data.delete(child.name)
              break
            end
            trail << [data, child.name]
            data = data[child.name]
            node = child
            i += 1
          when :list
            entries = data[child.name]
            if i + 1 == words.size
              data.delete(child.name)
              break
            end
            key = child.type.call(words[i + 1])
            raise Error, 'statement not found' unless entries.key?(key)
            if i + 2 == words.size
              entries.delete(key)
              data.delete(child.name) if entries.empty?
              break
            end
            # A list entry stays even when empty: "interface eth1;" means
            # run OSPF there with defaults.
            trail.clear
            data = entries[key]
            node = child
            i += 2
          when :flag
            extra!(words, i + 1)
            data.delete(child.name)
            break
          when :leaf
            # "delete ... metric" removes it; "delete ... metric 6" only
            # when the metric is 6.
            if i + 1 < words.size
              extra!(words, i + 2)
              raise Error, 'statement not found' unless data[child.name] == child.type.call(words[i + 1])
            end
            data.delete(child.name)
            break
          when :keyed_leaf
            if i + 1 == words.size
              data.delete(child.name)
            else
              # "delete ... md5 1" or "delete ... md5 1 key <secret>".
              extra!(words, i + 4)
              key = child.type.call(words[i + 1])
              raise Error, 'statement not found' unless data[child.name].key?(key)
              data[child.name].delete(key)
              data.delete(child.name) if data[child.name].empty?
            end
            break
          end
        end
        trail.reverse_each { |h, k| h.delete(k) if h[k].is_a?(Hash) && h[k].empty? }
        self
      end

      # ---- display ----

      def to_set(hide: true)
        out = []
        walk_set(Schema::ROOT, @data, [], hide, out)
        out
      end

      def to_curly(hide: true)
        out = []
        walk_curly(Schema::ROOT, @data, 0, hide, out)
        out.join("\n")
      end

      # Statements added and removed going from +self+ to +other+, in set
      # form: ["+ set ...", "- set ..."].
      def compare(other, hide: true)
        mine = to_set(hide: false)
        theirs = other.to_set(hide: false)
        shown = ->(line) { hide ? Tree.hide_line(line) : line }
        # "set ... interface eth1" stands for an empty block. It is not a
        # change when the block only gained or lost children.
        parent = ->(line, lines) { lines.any? { |l| l.start_with?("#{line} ") } }
        removed = (mine - theirs).reject { |l| parent.(l, theirs) }
        added = (theirs - mine).reject { |l| parent.(l, mine) }
        removed.map { |l| "- #{shown.(l)}" } + added.map { |l| "+ #{shown.(l)}" }
      end

      # ---- words ----

      # Splits a statement into words. Double quotes group words and
      # allow \" and \\ inside.
      def self.split(line)
        return line if line.is_a?(Array)
        words = []
        s = line.strip
        until s.empty?
          if s.start_with?('"')
            m = s.match(/\A"((?:[^"\\]|\\.)*)"/) or raise Error, 'unterminated quote'
            words << m[1].gsub(/\\(.)/, '\1')
          else
            m = s.match(/\A[^\s"]+/)
            words << m[0]
          end
          s = m.post_match.lstrip
        end
        words
      end

      def self.quote(value)
        v = value.to_s
        return v if v.match?(/\A[A-Za-z0-9_.:\/@-]+\z/)
        "\"#{v.gsub(/["\\]/) { "\\#{_1}" }}\""
      end

      SECRET_WORDS = /\b(key|simple-password)(\s+)("(?:[^"\\]|\\.)*"?|\S+)/

      # Masks anything after "key" or "simple-password" in a line of
      # text, even one that does not parse. For error messages and logs.
      def self.hide_secrets(line)
        line.gsub(SECRET_WORDS) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{quote(HIDDEN)}" }
      end

      # Masks the secret in one set line.
      def self.hide_line(line)
        Tree.new.tap { |t| t.set(Tree.split(line).drop(1)) }.to_set(hide: true).first || line
      rescue Error
        line
      end

      private :set!

      private

      def resolve(node, word, before)
        raise Error, "missing statement after '#{before.join(' ')}'" if word.nil?
        raise Error, "'#{before.join(' ')}' takes no more words" unless node.inner?
        m = node.matches(word)
        where = before.empty? ? '' : " after '#{before.join(' ')}'"
        raise Error, "syntax error, unknown '#{word}'#{where}" if m.empty?
        raise Error, "'#{word}' is ambiguous#{where}: #{m.map(&:name).join(', ')}" if m.size > 1
        m.first
      end

      def value(node, type, word, path)
        raise Error, "missing #{Schema::HINTS.fetch(type, 'value')} after '#{path.join(' ')}'" if word.nil?
        raise Error, "#{path.join(' ')}: type the real secret, not #{HIDDEN}" if node.secret && word == HIDDEN
        type.call(word)
      rescue Error => e
        raise e if e.message.include?(path.join(' ')) || word.nil?
        raise Error, "#{path.join(' ')}: #{e.message}"
      end

      def extra!(words, from)
        raise Error, "unexpected '#{words[from]}' at the end" if words.size > from
      end

      def shown(node, v, hide)
        node.secret && hide ? Tree.quote(HIDDEN) : Tree.quote(v)
      end

      def ordered(node, data)
        node.children.values.select { |c| data.key?(c.name) }
      end

      def walk_set(node, data, path, hide, out)
        out << "set #{path.join(' ')}" if data.empty? && !path.empty?
        ordered(node, data).each do |c|
          v = data[c.name]
          case c.kind
          when :container then walk_set(c, v, path + [c.name], hide, out)
          when :list then v.each { |k, entry| walk_set(c, entry, path + [c.name, Tree.quote(k)], hide, out) }
          when :leaf then out << "set #{(path + [c.name, shown(c, v, hide)]).join(' ')}"
          when :flag then out << "set #{(path + [c.name]).join(' ')}"
          when :keyed_leaf
            v.each { |k, s| out << "set #{(path + [c.name, k, c.sub[0], shown(c, s, hide)]).join(' ')}" }
          end
        end
      end

      def walk_curly(node, data, depth, hide, out)
        pad = '    ' * depth
        ordered(node, data).each do |c|
          v = data[c.name]
          case c.kind
          when :container then block(out, pad, c.name, c, v, depth, hide)
          when :list then v.each { |k, entry| block(out, pad, "#{c.name} #{Tree.quote(k)}", c, entry, depth, hide) }
          when :leaf then out << "#{pad}#{c.name} #{shown(c, v, hide)};#{secret_note(c, hide)}"
          when :flag then out << "#{pad}#{c.name};"
          when :keyed_leaf
            v.each { |k, s| out << "#{pad}#{c.name} #{k} #{c.sub[0]} #{shown(c, s, hide)};#{secret_note(c, hide)}" }
          end
        end
      end

      def block(out, pad, head, node, data, depth, hide)
        if data.empty?
          out << "#{pad}#{head};"
        else
          out << "#{pad}#{head} {"
          walk_curly(node, data, depth + 1, hide, out)
          out << "#{pad}}"
        end
      end

      def secret_note(node, hide)
        node.secret && hide ? ' ## SECRET-DATA' : ''
      end
    end
  end
end
