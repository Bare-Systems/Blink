# frozen_string_literal: true

require "json"

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
        operation = Operations::TestRun.new(
          manifest: manifest,
          service_name: @service,
          tags: @tags,
          target_name: @target_name
        )

        unless operation.available?
          Output.warn("No suites found for #{@service ? "'#{@service}'" : "any service"}")
          exit 0
        end

        if @list
          if @json
            details = operation.list
            puts Response.dump(
              success: true,
              summary: "#{details[:tests].size} test(s) available",
              details: details,
              next_steps: ["Run `blink test#{@service ? " #{@service}" : ""}` without `--list` to execute them."]
            )
            return
          end

          details = operation.list
          Testing::Reporter.new(json_mode: false).list(
            details[:tests].map { |t| Blink::Testing::TestRecord.new(t[:name], t[:tags], t[:suite], t[:desc], nil, nil, nil, nil) },
            @tags
          )
          return
        end

        run = operation.run
        result = run[:result]
        if @json
          puts Response.dump(
            success: result.success?,
            summary: summary_for(result),
            details: result.to_h.merge(service: @service, target: run[:target], service_results: run[:service_results]),
            next_steps: next_steps_for(result)
          )
        else
          Testing::Reporter.new(json_mode: false).report(result)
        end

        exit(result.success? ? 0 : 1)
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the manifest or suite configuration and rerun `blink test`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private
      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink test [service] [@tag ...] [--list] [--target NAME] [--json]\n\n"
        puts "  service      Only run suites for this service (default: all)"
        puts "  @tag         Filter tests by tag (e.g. @smoke @health)"
        puts "  --list       Show available tests without running them"
        puts "  --target     Override the target to run tests against"
        puts "  --json       Emit machine-readable JSON results"
        puts
        puts "Declarative inline tests live under [services.<name>.verify.tests.*] and support `api` and `ui` patterns alongside Ruby suites."
      end

      def summary_for(result)
        parts = ["#{result.passed}/#{result.total} passed"]
        parts << "#{result.failed} failed" if result.failed.positive?
        parts << "#{result.errored} errored" if result.errored.positive?
        parts.join(", ")
      end

      def next_steps_for(result)
        return ["Investigate the failing tests and rerun `blink test`."] unless result.success?

        ["Tests passed. If this followed a deploy, the service is ready."]
      end
    end
  end
end
