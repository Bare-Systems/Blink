# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class Rollback < Base
      def initialize(argv)
        @argv = argv.dup
        @service = @argv.shift
        @dry_run = !!@argv.delete("--dry-run")
        @json = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        if @service.nil? || @service.start_with?("-")
          show_help
          return
        end

        manifest = Manifest.load
        operation = Operations::Rollback.new(
          manifest: manifest,
          service_name: @service,
          target_name: @target_name,
          dry_run: @dry_run,
          json_mode: @json
        )

        if @json
          output, result = capture_output { operation.call }
          puts Response.dump(
            success: result.success?,
            summary: result.summary,
            details: result.to_h.merge(output: output),
            next_steps: next_steps_for(result)
          )
          exit 1 if result.failure?
          return
        end

        result = operation.call
        puts
        result.success? ? Output.success(result.summary) : Output.error(result.summary)
        exit 1 if result.failure?
      rescue Manifest::Error => e
        emit_exception_and_exit(e, service: @service, next_steps: ["Define a rollback pipeline in blink.toml and retry `blink rollback`."]) if @json
        Output.fatal(e.message)
      rescue TargetError => e
        emit_exception_and_exit(e, service: @service, prefix: "SSH error", next_steps: ["Run `blink doctor` to confirm connectivity, then retry."]) if @json
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink rollback <service> [--target NAME] [--dry-run] [--json]\n\n"
        puts "Run the service's declared rollback pipeline."
      end

      def next_steps_for(result)
        return ["Run `blink status #{@service}` to confirm the service recovered."] if result.success?
        ["Inspect the failed rollback step `#{result.failed_at}` and verify the recorded history entry."]
      end
    end
  end
end
