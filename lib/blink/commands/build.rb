# frozen_string_literal: true

require "json"
require "stringio"

module Blink
  module Commands
    class Build
      ANSI_STRIP = /\e\[[0-9;]*[mGKHF]/.freeze

      def initialize(argv)
        @argv    = argv.dup
        @service = @argv.shift
        @dry_run = !!@argv.delete("--dry-run")
        @json    = !!@argv.delete("--json")

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
        runner   = Runner.new(manifest)

        if @json
          output, result = capture_output do
            runner.run(
              @service,
              operation:  "build",
              dry_run:    @dry_run,
              json_mode:  true,
              build_name: @build
            )
          end

          puts Response.dump(
            success:    result.success?,
            summary:    result.summary,
            details:    result.to_h.merge(output: output, artifact_path: artifact_from(result)),
            next_steps: next_steps_for(result)
          )
          exit 1 if result.failure?
          return
        end

        start  = Time.now
        result = runner.run(
          @service,
          operation:  "build",
          dry_run:    @dry_run,
          json_mode:  false,
          build_name: @build
        )
        elapsed = (Time.now - start).round(1)

        puts
        if result.success?
          Output.success("#{result.summary}  (#{elapsed}s)")
          artifact = artifact_from(result)
          Output.info("Artifact ready: #{artifact}") if artifact
        else
          Output.error(result.summary)
          exit 1
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success:    false,
            summary:    e.message,
            details:    { service: @service, error: e.message },
            next_steps: ["Fix the manifest or service configuration and retry."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue SSHError => e
        if @json
          puts Response.dump(
            success:    false,
            summary:    "SSH error: #{e.message}",
            details:    { service: @service, error: e.message },
            next_steps: ["Check target connectivity with `blink doctor` and retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink build <service> [options]\n\n"
        puts "  #{Output::BOLD}--build NAME#{Output::RESET}     Select a named build strategy (default: source.default)"
        puts "  #{Output::BOLD}--dry-run#{Output::RESET}        Show what would happen without executing"
        puts "  #{Output::BOLD}--json#{Output::RESET}           Emit machine-readable JSON output"
      end

      def artifact_from(result)
        result.step_results
              .find { |s| s[:step] == "fetch_artifact" }
              &.dig(:output, "artifact_path")
      end

      def next_steps_for(result)
        if result.success?
          deploy_cmd = "blink deploy #{@service}#{@build ? " --build #{@build}" : ""}"
          @dry_run ? ["Run without --dry-run to execute the build."] :
                     ["Run `#{deploy_cmd}` to deploy this artifact."]
        else
          ["Inspect the failed step `#{result.failed_at}` and rerun the build when ready."]
        end
      end

      def capture_output
        old_stdout = $stdout
        old_stderr = $stderr
        captured   = StringIO.new
        $stdout    = captured
        result     = yield
        output     = captured.string.gsub(ANSI_STRIP, "")
        [output, result]
      ensure
        $stdout = old_stdout
        $stderr = old_stderr
      end
    end
  end
end
