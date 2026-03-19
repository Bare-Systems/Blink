# frozen_string_literal: true

require "json"

module Blink
  module Testing
    # Formats and prints test results (human-readable or JSON).
    class Reporter
      def initialize(json_mode: false)
        @json_mode = json_mode
      end

      def list(tests, filter_tags)
        if @json_mode
          puts JSON.generate(
            tests: tests.map { |t|
              { name: t.name, suite: t.suite, tags: t.tags, desc: t.desc }
            }
          )
          return
        end

        tag_label = filter_tags.any? ? "  #{Output::GRAY}[#{filter_tags.map { "@#{_1}" }.join(", ")}]#{Output::RESET}" : ""
        puts "\n#{Output::BOLD}#{tests.size} test#{tests.size == 1 ? "" : "s"}#{Output::RESET}#{tag_label}\n"

        max_tag_w = tests.map { plain_tags(_1).length }.max.to_i
        max_tag_w = [max_tag_w, 8].max
        indent    = " " * (4 + max_tag_w + 2)

        last_suite = nil
        tests.each do |t|
          if t.suite != last_suite
            puts
            puts "  #{Output::BOLD}#{t.suite}#{Output::RESET}"
            last_suite = t.suite
          end

          puts "    #{colored_tags(t).ljust(max_tag_w + ansi_overhead(t))}  #{t.name}"

          if t.desc && !t.desc.strip.empty?
            wrap(t.desc, 72).each { |line| puts "#{indent}#{Output::GRAY}#{line}#{Output::RESET}" }
          end
        end
        puts
      end

      def report(result)
        if @json_mode
          puts JSON.generate(result.to_h)
          return
        end

        puts "\n#{Output::BOLD}Running #{result.total} test#{result.total == 1 ? "" : "s"}#{Output::RESET}\n\n"

        last_suite = nil
        result.records.each do |r|
          if r.suite != last_suite
            puts "  #{Output::BOLD}#{r.suite}#{Output::RESET}"
            last_suite = r.suite
          end

          time_str = "#{Output::GRAY}(#{format("%.2f", r.elapsed)}s)#{Output::RESET}"
          case r.status
          when :pass
            puts "    #{Output::GREEN}✓#{Output::RESET}  #{r.name}  #{time_str}"
          when :fail
            puts "    #{Output::RED}✗#{Output::RESET}  #{r.name}  #{time_str}"
            r.message.split("\n").each { |l| puts "       #{Output::RED}#{l}#{Output::RESET}" }
          when :error
            puts "    #{Output::YELLOW}!#{Output::RESET}  #{r.name}  #{time_str}"
            r.message.split("\n").each { |l| puts "       #{Output::YELLOW}#{l}#{Output::RESET}" }
          when :skip
            puts "    #{Output::GRAY}-  #{r.name}#{Output::RESET}"
          end
        end

        total_time = result.records.sum(&:elapsed)
        summary    = "#{result.passed} passed"
        summary   += ", #{result.failed} failed"  if result.failed  > 0
        summary   += ", #{result.errored} errored" if result.errored > 0
        summary   += ", #{result.skipped} skipped" if result.skipped > 0
        summary   += "  #{Output::GRAY}(#{format("%.2f", total_time)}s total)#{Output::RESET}"

        puts
        result.success? ? Output.success(summary) : Output.error(summary)
      end

      private

      def plain_tags(t)  = t.tags.map { "@#{_1}" }.join(" ")
      def colored_tags(t) = t.tags.map { "#{Output::CYAN}@#{_1}#{Output::RESET}" }.join(" ")

      def ansi_overhead(t)
        t.tags.size * (Output::CYAN.length + Output::RESET.length)
      end

      def wrap(text, max_w)
        words = text.split
        lines = []
        line  = +""
        words.each do |w|
          if line.empty?
            line << w
          elsif line.length + 1 + w.length <= max_w
            line << " " << w
          else
            lines << line
            line = +w
          end
        end
        lines << line unless line.empty?
        lines
      end
    end
  end
end
