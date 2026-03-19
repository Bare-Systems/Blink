# frozen_string_literal: true

require "json"

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
        planner = Planner.new(manifest)
        if @json
          plan = planner.build(@service, target_name: @target, build_name: @build)
          puts Response.dump(
            success: plan.executable?,
            summary: plan.executable? ? "Plan ready for #{@service}" : "Plan blocked for #{@service}",
            details: plan.to_h,
            next_steps: plan.executable? ?
              ["Run `blink deploy #{@service}` to execute this plan."] :
              ["Fix the plan blockers and rerun `blink plan #{@service}`."]
          )
        else
          planner.plan(@service, target_name: @target, build_name: @build, json_mode: false)
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the manifest or service configuration and rerun `blink plan`."]
          )
          exit 1
        end
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
