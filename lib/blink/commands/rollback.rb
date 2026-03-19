# frozen_string_literal: true

require "json"
require "stringio"

module Blink
  module Commands
    class Rollback
      ANSI_STRIP = /\e\[[0-9;]*[mGKHF]/.freeze

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
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Define a rollback pipeline in blink.toml and retry `blink rollback`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue SSHError => e
        if @json
          puts Response.dump(
            success: false,
            summary: "SSH error: #{e.message}",
            details: { service: @service, error: e.message },
            next_steps: ["Run `blink doctor` to confirm connectivity, then retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink rollback <service> [--target NAME] [--dry-run] [--json]\n\n"
        puts "Run the service's declared rollback pipeline."
      end

      def capture_output
        old_stdout = $stdout
        old_stderr = $stderr
        captured_out = StringIO.new
        captured_err = StringIO.new
        $stdout = captured_out
        $stderr = captured_err
        result = yield
        output = [captured_out.string, captured_err.string].reject(&:empty?).join.gsub(ANSI_STRIP, "")
        [output, result]
      ensure
        $stdout = old_stdout
        $stderr = old_stderr
      end

      def next_steps_for(result)
        return ["Run `blink status #{@service}` to confirm the service recovered."] if result.success?
        ["Inspect the failed rollback step `#{result.failed_at}` and verify the recorded history entry."]
      end
    end
  end
end
