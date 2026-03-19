# frozen_string_literal: true

require "json"
require "shellwords"

begin
  require "nokogiri"
rescue LoadError
  nil
end

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
    # api/http — HTTP request + structured assertions
    #   [services.polar.verify.tests.rest-health]
    #   type          = "api"
    #   url           = "http://127.0.0.1:{{port}}/healthz"
    #   method        = "GET"          # default
    #
    #   [services.polar.verify.tests.rest-health.checks.status]
    #   type   = "status"
    #   equals = 200
    #
    #   [services.polar.verify.tests.rest-health.checks.health]
    #   type   = "json"
    #   path   = "$.stale"
    #   equals = false
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
    #
    #   [services.koala-ui.verify.tests.homepage.checks.root]
    #   type     = "selector"
    #   engine   = "css"
    #   selector = "div[data-testid='app-root']"
    #
    #   [services.koala-ui.verify.tests.homepage.checks.heading]
    #   type     = "selector"
    #   engine   = "xpath"
    #   selector = "//h1[contains(., 'Koala')]"
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

      def list(tags: [])
        filter = Array(tags).map(&:to_sym)

        @tests_cfg.filter_map do |name, spec|
          test_tags = Array(spec["tags"] || []).map(&:to_sym)
          next if filter.any? && (filter & test_tags).empty?

          TestRecord.new(name, test_tags, suite_name, spec["desc"], nil, nil, nil, nil)
        end
      end

      private

      def execute_inline(name, spec)
        type  = normalized_test_type(spec["type"] || raise(Manifest::Error, "verify.tests.#{name}.type is required"))
        tags  = Array(spec["tags"] || []).map(&:to_sym)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rec   = TestRecord.new(name, tags, suite_name, spec["desc"], nil, nil, nil, nil)

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
        headers = resolved_headers(spec)
        body    = spec["body"]
        body    = resolve(body) if body.is_a?(String)

        res = case method
              when "GET"  then @http.get(url,  headers: headers)
              when "POST" then @http.post(url, body: body, headers: headers)
              when "HEAD" then @http.head(url, headers: headers)
              else             @http.get(url,  headers: headers)
              end

        apply_response_checks(name, res, normalized_checks(spec, default_status: nil))
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
        url = resolve(spec["url"] || raise(Manifest::Error, "ui test '#{name}' requires url"))
        res = @http.get(url, headers: resolved_headers(spec))
        apply_response_checks(name, res, normalized_checks(spec, default_status: 200), html: true)
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

      def suite_name
        @ctx&.service_name ? "#{@ctx.service_name}:inline" : "inline"
      end

      def normalized_test_type(type)
        case type.to_s
        when "api" then "http"
        else type.to_s
        end
      end

      def resolved_headers(spec)
        (spec["headers"] || {}).transform_values { |v| resolve(v.to_s) }
      end

      def normalized_checks(spec, default_status:)
        checks = extract_checks(spec["checks"])

        if default_status && !checks.any? { |check| check["type"] == "status" }
          checks.unshift("type" => "status", "equals" => default_status)
        end

        checks << { "type" => "status", "equals" => spec["expect_status"] } if spec.key?("expect_status")
        checks << { "type" => "body", "contains" => spec["expect_body"] } if spec["expect_body"]
        checks << legacy_json_check(spec["expect_json"]) if spec["expect_json"]
        checks << { "type" => "selector", "selector" => spec["selector"], "engine" => spec["selector_type"] || "css" } if spec["selector"]
        checks << { "type" => "text", "contains" => spec["expect_text"] } if spec["expect_text"]
        checks.compact
      end

      def apply_response_checks(name, response, checks, html: false)
        parsed_json = nil
        document = nil

        checks.each do |check|
          type = check["type"] || raise(Manifest::Error, "test '#{name}' includes a check without type")

          case type
          when "status"
            expected = check["equals"]
            raise AssertionError,
              "expected HTTP #{expected}, got #{response.status}\n  body: #{response.body.slice(0, 120)}" \
              unless response.status == expected
          when "body"
            actual = response.body.to_s
            apply_value_check!("body", actual, check)
          when "header"
            header_name = check["name"] || raise(Manifest::Error, "header checks require name")
            actual = response.header(header_name)
            present = check.key?("present") ? check["present"] : true
            if !present
              raise AssertionError, "expected header '#{header_name}' to be absent, got #{actual.inspect}" unless actual.nil?
              next
            end

            raise AssertionError, "expected header '#{header_name}' to be present" if actual.nil?
            apply_value_check!("header '#{header_name}'", actual, check, allow_present_only: true)
          when "json"
            parsed_json ||= parse_json_body(response.body)
            path = check["path"] || raise(Manifest::Error, "json checks require path")
            actual = json_path_get(parsed_json, path)
            if check.key?("present")
              if check["present"]
                raise AssertionError, "JSON path #{path.inspect} expected to be present, got nil" if actual.nil?
              else
                raise AssertionError, "JSON path #{path.inspect} expected to be absent, got #{actual.inspect}" unless actual.nil?
                next
              end
            elsif actual.nil? && !check.key?("equals")
              raise AssertionError, "JSON path #{path.inspect} expected to be present, got nil"
            end

            apply_value_check!("JSON path #{path}", actual, check, allow_present_only: true)
          when "text"
            actual = if html
              document ||= parse_html(response.body)
              document.text
            else
              response.body.to_s
            end
            apply_value_check!("text", actual, check)
          when "selector"
            document ||= parse_html(response.body)
            selector = check["selector"] || raise(Manifest::Error, "selector checks require selector")
            engine = (check["engine"] || check["selector_type"] || "css").to_s
            matches = case engine
                      when "css" then document.css(selector)
                      when "xpath" then document.xpath(selector)
                      else raise Manifest::Error, "Unknown selector engine #{engine.inspect}"
                      end
            expected_count = check["count"]
            present = check.key?("present") ? check["present"] : true

            if expected_count
              raise AssertionError,
                "#{engine.upcase} selector #{selector.inspect} expected #{expected_count} match(es), got #{matches.size}" \
                unless matches.size == expected_count
            elsif present
              raise AssertionError,
                "#{engine.upcase} selector #{selector.inspect} not found in page source" \
                if matches.empty?
            else
              raise AssertionError,
                "#{engine.upcase} selector #{selector.inspect} was expected to be absent" \
                unless matches.empty?
            end
          else
            raise Manifest::Error, "Unknown check type #{type.inspect} for '#{name}'"
          end
        end
      end

      def apply_value_check!(label, actual, check, allow_present_only: false)
        return if allow_present_only && check.keys == ["type", "present"]

        if check.key?("equals")
          expected = check["equals"]
          raise AssertionError, "#{label} expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
        end

        if check.key?("contains")
          expected = check["contains"]
          ok = case actual
               when String then actual.include?(expected.to_s)
               when Array then actual.include?(expected)
               when Hash then actual.key?(expected.to_s) || actual.value?(expected)
               else false
               end
          raise AssertionError, "#{label} expected to include #{expected.inspect}, got #{actual.inspect}" unless ok
        end

        return unless check.key?("matches")

        pattern = regex_from(check["matches"])
        raise AssertionError, "#{label} expected to match #{check["matches"].inspect}, got #{actual.inspect}" unless actual.to_s.match?(pattern)
      end

      def legacy_json_check(expr)
        expr = expr.to_s.strip
        if expr.include?("==")
          path_str, _, expected_str = expr.partition("==")
          {
            "type" => "json",
            "path" => path_str.strip,
            "equals" => coerce_legacy_value(expected_str.strip)
          }
        else
          {
            "type" => "json",
            "path" => expr,
            "present" => true
          }
        end
      end

      def parse_json_body(body)
        JSON.parse(body)
      rescue JSON::ParserError => e
        raise AssertionError, "Response is not valid JSON: #{e.message}"
      end

      def parse_html(body)
        raise Manifest::Error, "UI selector checks require the `nokogiri` gem to be installed." unless defined?(Nokogiri)

        Nokogiri::HTML(body.to_s)
      end

      def json_path_get(obj, path)
        tokens = tokenize_json_path(path)
        tokens.reduce(obj) do |current, token|
          case current
          when Hash
            current[token]
          when Array
            token.is_a?(Integer) ? current[token] : nil
          else
            nil
          end
        end
      end

      def tokenize_json_path(path)
        remaining = path.to_s.strip
        remaining = remaining[1..] if remaining.start_with?("$")
        tokens = []

        until remaining.empty?
          remaining = remaining[1..] if remaining.start_with?(".")
          case remaining
          when /\A([A-Za-z0-9_-]+)(.*)\z/m
            tokens << Regexp.last_match(1)
            remaining = Regexp.last_match(2)
          when /\A\[(\d+)\](.*)\z/m
            tokens << Regexp.last_match(1).to_i
            remaining = Regexp.last_match(2)
          when /\A\[['"]([^'"]+)['"]\](.*)\z/m
            tokens << Regexp.last_match(1)
            remaining = Regexp.last_match(2)
          else
            raise AssertionError, "Unsupported JSON path syntax: #{path.inspect}"
          end
        end

        tokens
      end

      def regex_from(value)
        string = value.to_s
        match = string.match(/\A\/(.*)\/([imx]*)\z/m)
        return Regexp.new(string) unless match

        options = 0
        options |= Regexp::IGNORECASE if match[2].include?("i")
        options |= Regexp::MULTILINE if match[2].include?("m")
        options |= Regexp::EXTENDED if match[2].include?("x")
        Regexp.new(match[1], options)
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
      end

      def extract_checks(raw_checks)
        case raw_checks
        when nil
          []
        when Array
          raw_checks.map { |check| stringify_keys(check) }
        when Hash
          raw_checks.values.map { |check| stringify_keys(check) }
        else
          []
        end
      end

      def coerce_legacy_value(str)
        case str
        when "true"           then true
        when "false"          then false
        when "null", "nil"    then nil
        when /\A-?\d+\z/      then str.to_i
        when /\A-?[\d.]+\z/   then str.to_f
        when /\A"(.*)"\z/m    then Regexp.last_match(1)
        when /\A'(.*)'\z/m    then Regexp.last_match(1)
        else str
        end
      end
    end
  end
end
