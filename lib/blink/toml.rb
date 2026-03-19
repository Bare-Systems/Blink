# frozen_string_literal: true

# Minimal TOML subset parser — no gem dependencies.
#
# Supports:
#   [section] and [section.sub.key]  — table headers
#   key = "string"                   — quoted strings (double or single)
#   key = """multi-line string"""    — triple-quoted multi-line strings
#   key = 123                        — integers
#   key = true / false               — booleans
#   key = ["a", "b"]                 — single-line arrays of strings/ints/bools
#   key = [                          — multi-line arrays (collapsed to single line)
#     "a",
#     "b",
#   ]
#   # comment                        — line comments (stripped before parsing)
#   Blank lines                      — ignored
#
# Does NOT support: inline tables, dates, floats, dotted keys,
# array of tables ([[...]]), or TOML 1.0 edge cases.
# This is sufficient for blink.toml manifests.

module Blink
  module TOML
    ParseError = Class.new(StandardError)

    module_function

    def parse(text)
      # Pre-process: collapse multi-line constructs into single lines so the
      # line-by-line parser can handle them without multi-line awareness.
      text = collapse_multiline_strings(text)
      text = collapse_multiline_arrays(text)

      result  = {}
      current = result

      text.each_line.with_index(1) do |raw_line, lineno|
        line = raw_line.gsub(/#(?=([^"]*"[^"]*")*[^"]*$).*/, "").rstrip
        next if line.strip.empty?

        if (m = line.match(/^\s*\[\[([^\]]+)\]\]\s*$/))
          raise ParseError, "Line #{lineno}: array-of-tables ([[...]]) not supported"

        elsif (m = line.match(/^\s*\[([^\]]+)\]\s*$/))
          keys    = m[1].strip.split(".")
          current = keys.reduce(result) do |h, k|
            k = k.strip
            h[k] = {} unless h.key?(k)
            raise ParseError, "Line #{lineno}: '#{k}' is already a non-table value" unless h[k].is_a?(Hash)
            h[k]
          end

        elsif (m = line.match(/^\s*(\w+)\s*=\s*(.+?)\s*$/))
          current[m[1]] = parse_value(m[2].strip, lineno)

        else
          raise ParseError, "Line #{lineno}: cannot parse: #{raw_line.chomp.inspect}"
        end
      end

      result
    end

    # Collapse """...""" blocks into escaped single-line "..." strings so the
    # rest of the parser can handle them without multi-line awareness.
    # A newline immediately after the opening """ is trimmed (TOML spec).
    def collapse_multiline_strings(text)
      text.gsub(/"""(.*?)"""/m) do
        content = $1
        content = content.sub(/\A\n/, "")  # trim leading newline
        escaped = content
          .gsub("\\", "\\\\\\\\")
          .gsub('"',  '\\"')
          .gsub("\n", "\\n")
          .gsub("\r", "\\r")
          .gsub("\t", "\\t")
        '"' + escaped + '"'
      end
    end

    # Collapse multi-line array values into a single line so the existing
    # parse_array handles them. Only matches array values (after `key =`),
    # not table headers, so `[services.foo]` lines are unaffected.
    #
    # Input:
    #   dirs = [
    #     "a",
    #     "b",
    #   ]
    #
    # Output:
    #   dirs = ["a", "b"]
    def collapse_multiline_arrays(text)
      # Match: word_key = [ ... ] where the bracket content spans lines.
      # [^\[\]] forbids nested brackets — sufficient for blink.toml usage.
      text.gsub(/(\w[\w-]*\s*=\s*)\[([^\[\]]*)\]/m) do
        key_part = $1
        content  = $2
        # Flatten newlines and excess whitespace between items
        collapsed = content.gsub(/\s*\n\s*/, " ").strip
        "#{key_part}[#{collapsed}]"
      end
    end

    def parse_value(raw, lineno)
      case raw
      when /\A"(.*)"\z/m   then unescape($1)
      when /\A'(.*)'\z/m   then $1
      when /\Atrue\z/       then true
      when /\Afalse\z/      then false
      when /\A-?\d+\z/      then raw.to_i
      when /\A\[/           then parse_array(raw, lineno)
      else raise ParseError, "Line #{lineno}: unsupported value: #{raw.inspect}"
      end
    end

    def parse_array(raw, lineno)
      inner = raw.match(/\A\[(.*)\]\z/m)&.[](1).to_s.strip
      return [] if inner.empty?

      items = []
      buf   = +""
      depth = 0
      in_dq = false
      in_sq = false

      inner.each_char do |c|
        case c
        when '"'  then in_dq = !in_dq  unless in_sq
        when "'"  then in_sq = !in_sq  unless in_dq
        when "["  then depth += 1      unless in_dq || in_sq
        when "]"  then depth -= 1      unless in_dq || in_sq
        when ","
          unless in_dq || in_sq || depth > 0
            items << parse_value(buf.strip, lineno)
            buf = +""
            next
          end
        end
        buf << c
      end
      items << parse_value(buf.strip, lineno) unless buf.strip.empty?
      items
    end

    def unescape(str)
      str.gsub(/\\(["\\nrt])/) do
        { '"' => '"', "\\" => "\\", "n" => "\n", "r" => "\r", "t" => "\t" }[$1] || $1
      end
    end
  end
end
