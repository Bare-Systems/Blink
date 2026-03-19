# frozen_string_literal: true

module Blink
  module Commands
    class Ps
      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        manifest    = Manifest.load
        target_name = @target_name || manifest.default_target_name
        target      = manifest.target!(target_name)

        Output.header("Containers  (#{target.description})")

        raw = target.capture('docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>&1')

        if @json
          lines = raw.lines.map(&:chomp)
          puts JSON.generate(target: target.description, output: lines)
          return
        end

        lines = raw.lines
        if lines.size <= 1
          Output.warn("No containers running")
          return
        end

        puts
        lines.each_with_index do |line, i|
          line = line.chomp
          if i == 0
            puts "  #{Output::BOLD}#{line}#{Output::RESET}"
          elsif line.include?("Up")
            puts "  #{Output::GREEN}#{line}#{Output::RESET}"
          else
            puts "  #{Output::YELLOW}#{line}#{Output::RESET}"
          end
        end
        puts
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue SSHError => e
        Output.fatal("SSH error: #{e.message}")
      end
    end
  end
end
