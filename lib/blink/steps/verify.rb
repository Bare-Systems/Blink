# frozen_string_literal: true

module Blink
  module Steps
    # Run the service's test suite as a pipeline gate.
    #
    # Supports two modes that can be used independently or together:
    #
    # 1. Ruby suite file (original behaviour — unchanged):
    #
    #   [services.bearclaw.verify]
    #   suite = "blink/suites/bearclaw_homelab.rb"
    #   tags  = ["smoke", "health"]
    #
    # 2. Inline TOML tests (no Ruby file needed for simple checks):
    #
    #   [services.polar.verify.tests.rest-health]
    #   type          = "http"
    #   url           = "http://127.0.0.1:{{port}}/healthz"
    #   expect_status = 200
    #   tags          = ["smoke"]
    #
    #   [services.polar.verify.tests.container-running]
    #   type          = "shell"
    #   command       = "docker inspect --format '{{.State.Status}}' polar"
    #   expect_output = "running"
    #   tags          = ["health"]
    #
    # When both suite and tests are declared, inline tests run first, then
    # the Ruby suite. A failure in either causes the step to raise.
    class Verify < Base
      step_definition(
        description: "Run inline and/or Ruby verification suites for the service.",
        config_section: "verify",
        supported_target_types: %w[local ssh],
        rollback_strategy: "same"
      )

      def execute(ctx)
        cfg  = ctx.section("verify").merge(@config)
        tags = Array(cfg["tags"] || []).map(&:to_sym)

        if dry_run?(ctx)
          dry_log(ctx, "would run verify suite: #{cfg["suite"]}  tags=#{tags.inspect}") if cfg["suite"]
          if (tests = cfg["tests"])
            dry_log(ctx, "would run #{tests.size} inline test(s)  tags=#{tags.inspect}")
          end
          return
        end

        total_failed = 0

        # ── 1. Inline TOML tests ────────────────────────────────────────────
        if (tests_cfg = cfg["tests"])
          inline = Testing::InlineRunner.new(tests_cfg, ctx)
          result = inline.run(tags: tags)
          Testing::Reporter.new(json_mode: ctx.json_mode).report(result)
          total_failed += result.failed + result.errored
        end

        # ── 2. Ruby suite file ──────────────────────────────────────────────
        if (suite_path = cfg["suite"])
          suite_abs = File.expand_path(suite_path, ctx.manifest.dir)
          raise "Suite file not found: #{suite_abs}" unless File.exist?(suite_abs)

          runner = Testing::Runner.new(tags: tags, target: ctx.target, json_mode: ctx.json_mode)
          Testing::Suite.with_clean_registry { load suite_abs }
          Testing::Suite.registered.each { |klass| klass.register(runner) }

          result = runner.run_collected
          total_failed += result.failed + result.errored
        end

        raise "Verification failed: #{total_failed} test(s) failed" if total_failed > 0
      end

      def self.validate_config(config, service_config:, service_name:, path:)
        issues = []
        has_suite = config["suite"]
        has_tests = config["tests"]

        unless has_suite || has_tests
          issues << {
            path: path,
            message: "verify requires either suite = \"path/to/suite.rb\" or verify.tests.* entries.",
            severity: "error"
          }
        end

        if config["tags"] && !(config["tags"].is_a?(Array) && config["tags"].all? { |tag| tag.is_a?(String) && !tag.strip.empty? })
          issues << { path: "#{path}.tags", message: "verify.tags must be an array of strings.", severity: "error" }
        end

        issues
      end
    end

    Steps.register("verify", Verify)
  end
end
