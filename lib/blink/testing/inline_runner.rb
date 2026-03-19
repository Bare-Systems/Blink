# frozen_string_literal: true

require "json"

module Blink
  module Testing
    # Runs inline test definitions declared in [services.X.verify.tests.*].
    #
    # This avoids needing a Ruby suite file for straightforward deploy
    # verification. Inline tests are keyed by name in the TOML and dispatched
    # by type.
    #
    # Supported test types
    # ────────────────────
    #
    # http — HTTP request + assertion
    #   [services.polar.verify.tests.rest-health]
    #   type          = "http"
    #   url           = "http://127.0.0.1:{{port}}/healthz"
    #   method        = "GET"          # default
    #   expect_status = 200
    #   expect_body   = "ok"           # substring match (optional)
    #   expect_json   = "stale == false"  # path == value expression (optional)
    #
    #   [services.polar.verify.tests.rest-health.headers]
    #   Authorization = "Bearer {{service_token}}"
    #
    # shell — Remote command + output assertion
    #   [services.polar.verify.tests.container-running]
    #   type          = "shell"
    #   command       = "docker inspect --format '{{.State.Status}}' polar"
    #   expect_output = "running"      # exact string or /regex/ (optional)
    #
    # mcp — JSON-RPC initialize handshake
    #   [services.polar.verify.tests.mcp-surface]
    #   type          = "mcp"
    #   url           = "http://127.0.0.1:{{mcp_port}}"
    #   expect_status = 200
    #
    # ui — Fetch HTML and check for element/text presence
    #   [services.koala-ui.verify.tests.homepage]
    #   type          = "ui"
    #   url           = "http://127.0.0.1:{{ui_port}}/"
    #   selector      = "div[data-testid='app-root']"
    #   expect_text   = "Koala"        # optional text anywhere in page
    #
    # script — Run a local shell script, pass = exit 0
    #   [services.polar.verify.tests.custom-check]
    #   type = "script"
    #   path = "blink/tests/polar_check.sh"
    #
    class InlineRunner
      def initialize(tests_cfg, ctx)
        @tests_cfg = tests_cfg  # Hash: { "test-name" => { "type" => "http", ... } }
        @ctx       = ctx
        @http      = HTTP.new(ctx.target)
      end

      # Run all inline tests, optionally filtered to tests whose tags overlap
      # with the given list. Returns a Testing::RunResult.
      def run(tags: [])
        filter = Array(tags).map(&:to_sym)

        records = @tests_cfg.filter_map do |name, spec|
          test_tags = Array(spec["tags"] || []).map(&:to_sym)
          next if filter.any? && (filter & test_tags).empty?

          execute_inline(name, spec)
        end

        RunResult.new(records)
      end

      private

      def execute_inline(name, spec)
        type  = spec["type"] || raise(Manifest::Error, "verify.tests.#{name}.type is required")
        tags  = Array(spec["tags"] || []).map(&:to_sym)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rec   = TestRecord.new(name, tags, "inline", spec["desc"], nil, nil, nil, nil)

        begin
          case type
          when "http"   then run_http(name, spec)
          when "shell"  then run_shell(name, spec)
          when "mcp"    then run_mcp(name, spec)
          when "ui"     then run_ui(name, spec)
          when "script" then run_script(name, spec)
          else
            raise Manifest::Error, "Unknown inline test type '#{type}' for '#{name}'"
          end

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          rec.dup.tap { |r| r.status = :pass; r.elapsed = elapsed }

        rescue AssertionError => e
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          rec.dup.tap { |r| r.status = :fail; r.message = e.message; r.elapsed = elapsed }

        rescue => e
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          rec.dup.tap { |r| r.status = :error; r.message = "#{e.class}: #{e.message}"; r.elapsed = elapsed }
        end
      end

      # ── Test type runners ──────────────────────────────────────────────────

      def run_http(name, spec)
        url     = resolve(spec["url"] || raise(Manifest::Error, "http test '#{name}' requires url"))
        method  = (spec["method"] || "GET").upcase
        headers = (spec["headers"] || {}).transform_values { |v| resolve(v.to_s) }

        res = case method
              when "GET"  then @http.get(url,  headers: headers)
              when "POST" then @http.post(url, body: spec["body"], headers: headers)
              when "HEAD" then @http.head(url, headers: headers)
              else             @http.get(url,  headers: headers)
              end

        if (expected = spec["expect_status"])
          raise AssertionError,
            "expected HTTP #{expected}, got #{res.status}\n  body: #{res.body.slice(0, 120)}" \
            unless res.status == expected
        end

        if (expected = spec["expect_body"])
          raise AssertionError,
            "expected body to include #{expected.inspect}\n  body: #{res.body.slice(0, 120)}" \
            unless res.body.include?(expected.to_s)
        end

        check_json_expr(res.body, spec["expect_json"], name) if spec["expect_json"]
      end

      def run_shell(name, spec)
        cmd    = resolve(spec["command"] || raise(Manifest::Error, "shell test '#{name}' requires command"))
        output = @ctx.target.capture(cmd).strip

        return unless (expected = spec["expect_output"])

        expected = resolve(expected.to_s)
        match = if expected.start_with?("/") && expected.end_with?("/")
                  output.match?(Regexp.new(expected[1..-2]))
                else
                  output == expected
                end
        raise AssertionError, "expected output #{expected.inspect}, got #{output.inspect}" unless match
      end

      def run_mcp(name, spec)
        url = resolve(spec["url"] || raise(Manifest::Error, "mcp test '#{name}' requires url"))

        body = JSON.generate(
          jsonrpc: "2.0",
          id:      1,
          method:  "initialize",
          params:  {
            protocolVersion: "2024-11-05",
            capabilities:    {},
            clientInfo:      { name: "blink-test", version: "1" },
          }
        )

        res             = @http.post("#{url}/mcp", body: body, headers: { "Content-Type" => "application/json" })
        expected_status = spec["expect_status"] || 200

        raise AssertionError,
          "MCP initialize expected HTTP #{expected_status}, got #{res.status}" \
          unless res.status == expected_status

        if spec["expect_tools"]
          parsed = begin
            JSON.parse(res.body)
          rescue JSON::ParserError => e
            raise AssertionError, "MCP response is not valid JSON: #{e.message}"
          end
          raise AssertionError, "MCP response missing 'result' key" unless parsed["result"]
        end
      end

      def run_ui(name, spec)
        url  = resolve(spec["url"] || raise(Manifest::Error, "ui test '#{name}' requires url"))
        res  = @http.get(url)
        expected_status = spec["expect_status"] || 200

        raise AssertionError,
          "UI page returned HTTP #{res.status} (expected #{expected_status})" \
          unless res.status == expected_status

        if (selector = spec["selector"])
          pat = selector_to_pattern(selector)
          raise AssertionError,
            "CSS selector #{selector.inspect} not found in page source" \
            unless res.body.match?(pat)
        end

        if (expected_text = spec["expect_text"])
          raise AssertionError,
            "Expected text #{expected_text.inspect} not found in page" \
            unless res.body.include?(expected_text)
        end
      end

      def run_script(name, spec)
        path = spec["path"] || raise(Manifest::Error, "script test '#{name}' requires path")
        abs  = File.expand_path(path, @ctx.manifest.dir)
        raise "Test script not found: #{abs}" unless File.exist?(abs)

        # Run locally (not via SSH) — the script tests the deployed service
        # over the network rather than running on the target host.
        out = `bash #{Shellwords.escape(abs)} 2>&1`
        raise AssertionError, "Script test '#{name}' failed (exit #{$?.exitstatus}):\n#{out}" unless $?.success?
      end

      # ── Helpers ────────────────────────────────────────────────────────────

      def resolve(str)
        @ctx.resolve(str.to_s)
      end

      # Convert a simple CSS selector to a Regexp for smoke-test presence
      # checking in raw HTML. Not a real CSS engine — covers the common cases:
      #   tag, #id, .class, [attr], [attr='value'], div.class[attr]
      def selector_to_pattern(selector)
        # If there's an attribute expression, look for the attr string in source
        if (m = selector.match(/\[([^\]]+)\]/))
          Regexp.new(Regexp.escape(m[1]), Regexp::IGNORECASE)
        else
          # Fall back to looking for the opening tag
          tag = selector.split(/[.#\[]/)[0].strip
          Regexp.new("<#{Regexp.escape(tag)}[\\s>/]", Regexp::IGNORECASE)
        end
      end

      # Evaluate a JSON path expression against a response body.
      # Supports two forms:
      #   "indoor.stale == false"   — equality check
      #   "indoor.stale"            — presence check (not nil)
      def check_json_expr(body, expr, name)
        parsed = begin
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise AssertionError, "Response is not valid JSON: #{e.message}"
        end

        if expr.include?("==")
          path_str, _, expected_str = expr.partition("==")
          path     = path_str.strip.split(".")
          expected = coerce_value(expected_str.strip)
          actual   = dig_path(parsed, path)
          raise AssertionError,
            "JSON: #{path_str.strip} expected #{expected.inspect}, got #{actual.inspect}" \
            unless actual == expected
        else
          path   = expr.strip.split(".")
          actual = dig_path(parsed, path)
          raise AssertionError,
            "JSON: #{expr.strip} expected to be present, got nil" if actual.nil?
        end
      end

      def dig_path(obj, path)
        path.reduce(obj) { |h, k| h.is_a?(Hash) ? h[k] : nil }
      end

      def coerce_value(str)
        case str
        when "true"           then true
        when "false"          then false
        when "null", "nil"    then nil
        when /\A-?\d+\z/      then str.to_i
        when /\A-?[\d.]+\z/   then str.to_f
        when /\A"(.*)"\z/     then $1
        when /\A'(.*)'\z/     then $1
        else str
        end
      end
    end
  end
end
