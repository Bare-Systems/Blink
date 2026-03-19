# frozen_string_literal: true

module Blink
  module Commands
    class Test
      def initialize(argv)
        @argv    = argv.dup
        @list    = !!@argv.delete("--list")
        @json    = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end

        # Remaining args: optional service name and @tags
        @tags    = @argv.select { |a| a.start_with?("@") }.map { |a| a.delete_prefix("@").to_sym }
        non_tags = @argv.reject { |a| a.start_with?("@") }
        @service = non_tags.first
      end

      def run
        if @argv.include?("--help") || @argv.include?("-h")
          show_help
          return
        end

        manifest = Manifest.load
        suites   = resolve_suites(manifest)

        if suites.empty?
          Output.warn("No suites found for #{@service ? "'#{@service}'" : "any service"}")
          exit 0
        end

        target = resolve_target(manifest)
        runner = Testing::Runner.new(tags: @tags, target: target, json_mode: @json)
        suites.each { |klass| klass.register(runner) }

        @list ? runner.list : runner.run
      rescue Manifest::Error => e
        Output.fatal(e.message)
      end

      private

      # Load and return suite classes for the requested service(s).
      def resolve_suites(manifest)
        services = @service ? [manifest.service!(@service)] : manifest.service_names.map { manifest.service(_1) }

        suite_paths = services.filter_map { |svc|
          path = svc&.dig("verify", "suite")
          next unless path
          File.expand_path(path, manifest.dir)
        }.select { |p| File.exist?(p) }

        if suite_paths.empty? && @service
          Output.warn("No verify.suite configured for '#{@service}'")
          return []
        end

        Testing::Suite.with_clean_registry do
          suite_paths.each { |p| load p }
        end

        Testing::Suite.registered
      end

      def resolve_target(manifest)
        if @target_name
          manifest.target!(@target_name)
        elsif @service
          svc_config = manifest.service!(@service)
          t_name = svc_config.dig("deploy", "target") || manifest.default_target_name
          manifest.target!(t_name)
        else
          manifest.target!(manifest.default_target_name)
        end
      end

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink test [service] [@tag ...] [--list] [--target NAME] [--json]\n\n"
        puts "  service      Only run suites for this service (default: all)"
        puts "  @tag         Filter tests by tag (e.g. @smoke @health)"
        puts "  --list       Show available tests without running them"
        puts "  --target     Override the target to run tests against"
        puts "  --json       Emit machine-readable JSON results"
      end
    end
  end
end
