# frozen_string_literal: true

module Blink
  module Commands
    class Plan
      def initialize(argv)
        @argv    = argv.dup
        @service = @argv.shift
        @json    = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end

        build_idx = @argv.index("--build")
        @build = if build_idx
          @argv.delete_at(build_idx)
          @argv.delete_at(build_idx)
        end
      end

      def run
        if @service.nil? || @service.start_with?("-")
          show_help
          return
        end

        manifest = Manifest.load
        Planner.new(manifest).plan(@service, target_name: @target, build_name: @build, json_mode: @json)
      rescue Manifest::Error => e
        Output.fatal(e.message)
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink plan <service> [--target NAME] [--build NAME] [--json]\n\n"
        puts "Show what 'blink deploy <service>' would do without executing anything."
        puts
        puts "  #{Output::BOLD}--build NAME#{Output::RESET}  Select a named build (multi-build source only)"
      end
    end
  end
end
