# frozen_string_literal: true

require "json"

module Blink
  module Commands
    # Run connectivity and health checks against all configured targets.
    class Doctor
      def initialize(argv)
        @argv    = argv.dup
        @json    = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        manifest = Manifest.load
        result = Operations::Doctor.new(manifest: manifest, target_name: @target_name).call

        if @json
          puts Response.dump(
            success: result[:failed].zero?,
            summary: "#{result[:passed]} passed, #{result[:failed]} failed, #{result[:warnings]} warnings",
            details: result,
            next_steps: next_steps_for(result[:checks])
          )
          exit 1 unless result[:failed].zero?
          return
        end

        result[:checks].group_by { _1[:target] }.each do |target_name, checks|
          target = manifest.target!(target_name)
          Output.header("Doctor  (#{target.description})")
          puts
          checks.each { |check| render_check(check) }
        end

        puts

        if result[:failed].zero?
          if result[:warnings].zero?
            Output.success("All #{result[:passed]} checks passed")
          else
            Output.warn("#{result[:passed]} passed, #{result[:warnings]} warning(s)")
          end
        else
          Output.warn("#{result[:passed]} passed, #{Output::RED}#{result[:failed]} failed#{Output::RESET}")
          exit 1
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { target: @target_name, error: e.message },
            next_steps: ["Fix the manifest or target selection and rerun `blink doctor`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private

      def render_check(check)
        label = "  #{check[:check]}"
        case check[:status]
        when "pass"
          Output.label_row("#{label}:", "#{Output::GREEN}#{check[:detail] || 'ok'}#{Output::RESET}")
        when "warn"
          Output.warn("#{label}: #{check[:detail]}")
        else
          Output.label_row("#{label}:", "#{Output::RED}#{check[:detail] || 'FAIL'}#{Output::RESET}")
        end
      end

      def next_steps_for(checks)
        failed = checks.select { _1[:status] == "fail" }
        return ["Fix the failing checks and rerun `blink doctor`."] if failed.any?

        warned = checks.select { _1[:status] == "warn" }
        return ["Monitor the warning conditions; capacity is getting tight."] if warned.any?

        []
      end
    end
  end
end
