# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class Logs
      def initialize(argv)
        @argv    = argv.dup
        @follow  = !!@argv.delete("-f") || !!@argv.delete("--follow")
        @json    = !!@argv.delete("--json")
        @lines   = extract_flag_value("--lines") || "100"
        @service = @argv.reject { _1.start_with?("-") }.first

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        if @service.nil?
          show_help
          return
        end

        manifest = Manifest.load
        operation = Operations::Logs.new(
          manifest: manifest,
          service_name: @service,
          lines: @lines,
          target_name: @target_name
        )
        if @json
          if @follow
            puts Response.dump(
              success: false,
              summary: "`blink logs --json` does not support follow mode",
              details: { service: @service, target: operation.target.description },
              next_steps: ["Drop `--follow` or rerun without `--json` for streaming output."]
            )
            exit 1
          end
          details = operation.call
          puts Response.dump(
            success: true,
            summary: "Last #{@lines} lines of #{@service} logs",
            details: details,
            next_steps: ["Inspect the log output for errors or warnings."]
          )
        else
          operation.target.run(operation.stream_command(follow: @follow))
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the manifest or target selection and rerun `blink logs`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue TargetError => e
        if @json
          puts Response.dump(
            success: false,
            summary: "SSH error: #{e.message}",
            details: { service: @service, error: e.message },
            next_steps: ["Check connectivity with `blink doctor` and retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end

      private
      def extract_flag_value(flag)
        idx = @argv.index(flag)
        return nil unless idx
        @argv.delete_at(idx)
        @argv.delete_at(idx)
      end

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink logs <service> [-f] [--lines N] [--target NAME] [--json]"
      end
    end
  end
end
