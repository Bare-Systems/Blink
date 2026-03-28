# frozen_string_literal: true

require "json"
require "stringio"

module Blink
  module Commands
    class Deploy
      ANSI_STRIP = /\e\[[0-9;]*[mGKHF]/.freeze

      def initialize(argv)
        @argv     = argv.dup
        @service  = @argv.shift
        @dry_run  = !!@argv.delete("--dry-run")
        @json     = !!@argv.delete("--json")

        version_idx = @argv.index("--version")
        @version = if version_idx
          @argv.delete_at(version_idx)
          @argv.delete_at(version_idx)
        else
          "latest"
        end

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
        if @service&.start_with?("-")
          show_help
          return
        end

        manifest = Manifest.load

        if @service.nil?
          run_all(manifest)
          return
        end

        run_one(manifest, @service)
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the manifest or service configuration and rerun the deploy."]
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
            next_steps: ["Check target connectivity with `blink doctor` and retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def run_all(manifest)
        services = manifest.service_names
        if services.empty?
          Output.error("No services defined in manifest.")
          exit 1
        end

        Output.info("Deploying all services: #{services.join(", ")}") unless @json

        # Group services by deploy.priority (default 0). Higher priority deploys first.
        # Services at the same priority level deploy in parallel.
        priority_groups = services.group_by do |name|
          svc = manifest.service(name)
          svc&.dig("deploy", "priority") || 0
        end
        ordered_groups = priority_groups.sort_by { |priority, _| -priority }.map { |_, names| names }

        results  = {}
        failed   = []
        mutex    = Mutex.new
        start    = Time.now

        ordered_groups.each do |group|
          threads = group.map do |name|
            Thread.new do
              if @json
                _output, result = capture_output { Runner.new(manifest).run(name, target_name: @target, dry_run: @dry_run, json_mode: true, version: @version, build_name: @build) }
              else
                result = Runner.new(manifest).run(name, target_name: @target, dry_run: @dry_run, json_mode: false, version: @version, build_name: @build)
              end
              mutex.synchronize do
                results[name] = result
                failed << name if result.failure?
              end
            end
          end
          threads.each(&:join)

          # Stop deploying subsequent priority groups if any service in this group failed
          break if failed.any?
        end

        elapsed = (Time.now - start).round(1)

        if @json
          all_success = failed.empty?
          puts Response.dump(
            success: all_success,
            summary: all_success ? "All #{services.size} services deployed (#{elapsed}s)" : "#{failed.size} service(s) failed: #{failed.join(", ")}",
            details: results.transform_values(&:to_h),
            next_steps: all_success ? ["Run `blink test` to verify deployments."] : failed.map { |n| "Inspect failed service '#{n}' and rerun `blink deploy #{n}`." }
          )
          exit 1 unless all_success
          return
        end

        puts
        if failed.empty?
          Output.success("All #{services.size} services deployed  (#{elapsed}s)")
        else
          Output.error("#{failed.size} service(s) failed: #{failed.join(", ")}")
          exit 1
        end
      end

      def run_one(manifest, service)
        runner = Runner.new(manifest)

        if @json
          output, result = capture_output do
            runner.run(service, target_name: @target, dry_run: @dry_run, json_mode: true, version: @version, build_name: @build)
          end

          puts Response.dump(
            success: result.success?,
            summary: result.summary,
            details: result.to_h.merge(output: output),
            next_steps: next_steps_for(result, service)
          )
          exit 1 if result.failure?
          return
        end

        start  = Time.now
        result = runner.run(service, target_name: @target, dry_run: @dry_run, json_mode: false, version: @version, build_name: @build)
        elapsed = (Time.now - start).round(1)

        puts
        if result.success?
          Output.success("#{result.summary}  (#{elapsed}s)")
        else
          Output.error(result.summary)
          exit 1
        end
      end

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink deploy [service] [options]\n\n"
        puts "  Omit <service> to deploy all services defined in blink.toml.\n\n"
        puts "  #{Output::BOLD}--target NAME#{Output::RESET}    Override the target declared in blink.toml"
        puts "  #{Output::BOLD}--version TAG#{Output::RESET}    Deploy a specific release version (default: latest)"
        puts "  #{Output::BOLD}--build NAME#{Output::RESET}     Select a named build (multi-build source only)"
        puts "  #{Output::BOLD}--dry-run#{Output::RESET}        Show what would happen without executing"
        puts "  #{Output::BOLD}--json#{Output::RESET}           Emit machine-readable JSON output"
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

      def next_steps_for(result, service = @service)
        if result.success?
          @dry_run ? ["Run the same command without `--dry-run` to execute the deployment."] :
                     ["Run `blink test #{service}` to verify the deployment."]
        elsif result.failed_at == "plan"
          ["Fix the plan blockers, then rerun `blink plan #{service}` or `blink deploy #{service}`."]
        else
          ["Inspect the failed step `#{result.failed_at}` and rerun the deploy when ready."]
        end
      end
    end
  end
end
