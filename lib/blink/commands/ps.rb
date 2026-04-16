# frozen_string_literal: true

require "json"

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
        details = Operations::Ps.new(manifest: manifest, target_name: @target_name).call

        Output.header("Containers  (#{details[:target]})") unless @json

        if @json
          puts Response.dump(
            success: true,
            summary: "#{details[:container_count]} container(s) listed on #{details[:target]}",
            details: details,
            next_steps: []
          )
          return
        end

        lines = details[:output]
        if lines.size <= 1
          Output.warn("No containers running")
          return
        end

        puts
        lines.each_with_index do |line, i|
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
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { target: @target_name, error: e.message },
            next_steps: ["Fix the manifest or target selection and rerun `blink ps`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue TargetError => e
        if @json
          puts Response.dump(
            success: false,
            summary: "SSH error: #{e.message}",
            details: { target: @target_name, error: e.message },
            next_steps: ["Check target connectivity with `blink doctor` and retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end
    end
  end
end
