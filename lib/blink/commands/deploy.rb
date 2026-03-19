# frozen_string_literal: true

module Blink
  module Commands
    class Deploy
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
        if @service.nil? || @service.start_with?("-")
          show_help
          return
        end

        manifest = Manifest.load
        runner   = Runner.new(manifest)

        start  = Time.now
        result = runner.run(
          @service,
          target_name: @target,
          dry_run:     @dry_run,
          json_mode:   @json,
          version:     @version,
          build_name:  @build
        )
        elapsed = (Time.now - start).round(1)

        puts
        if result.success?
          Output.success("#{result.summary}  (#{elapsed}s)")
        else
          Output.error(result.summary)
          puts JSON.generate(result.to_h) if @json
          exit 1
        end

        puts JSON.generate(result.to_h) if @json && result.success?
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue SSHError => e
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink deploy <service> [options]\n\n"
        puts "  #{Output::BOLD}--target NAME#{Output::RESET}    Override the target declared in blink.toml"
        puts "  #{Output::BOLD}--version TAG#{Output::RESET}    Deploy a specific release version (default: latest)"
        puts "  #{Output::BOLD}--build NAME#{Output::RESET}     Select a named build (multi-build source only)"
        puts "  #{Output::BOLD}--dry-run#{Output::RESET}        Show what would happen without executing"
        puts "  #{Output::BOLD}--json#{Output::RESET}           Emit machine-readable JSON output"
      end
    end
  end
end
