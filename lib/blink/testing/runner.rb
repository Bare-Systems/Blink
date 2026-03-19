# frozen_string_literal: true

module Blink
  module Testing
    class AssertionError < StandardError; end

    # Metadata + result for a single test.
    TestRecord = Struct.new(:name, :tags, :suite, :desc, :status, :message, :elapsed, :block)
    # status: :pass | :fail | :error | :skip

    # Collects tests from suites and executes them.
    # All I/O runs on the declared target (SSH or local) via the HTTP helper.
    class Runner
      def initialize(tags: [], target: nil, json_mode: false)
        @filter_tags = Array(tags).map(&:to_sym)
        @target      = target
        @json_mode   = json_mode
        @tests       = []
        @http        = nil
      end

      def register_test(name, tags:, suite:, desc: nil, &block)
        @tests << TestRecord.new(
          name, Array(tags).map(&:to_sym), suite, desc,
          nil, nil, nil, block
        )
      end

      # ── List (no network I/O) ────────────────────────────────────────────

      def list
        filtered = filtered_tests
        Reporter.new(json_mode: @json_mode).list(filtered, @filter_tags)
      end

      # ── Run and print results (used by the `test` command directly) ──────

      def run
        result = run_collected
        Reporter.new(json_mode: @json_mode).report(result)
        exit(result.success? ? 0 : 1)
      end

      # ── Run and return a RunResult (used by the `verify` step) ───────────

      def run_collected
        filtered = filtered_tests
        http     = HTTP.new(@target)

        results = filtered.map { |t| execute(t, http) }
        RunResult.new(results)
      end

      private

      def filtered_tests
        return @tests if @filter_tags.empty?
        @tests.select { |t| (@filter_tags & t.tags).any? }
      end

      def execute(t, http)
        ctx   = TestContext.new(http, @target)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          ctx.instance_eval(&t.block)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          t.dup.tap { |r| r.status = :pass; r.elapsed = elapsed }
        rescue AssertionError => e
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          t.dup.tap { |r| r.status = :fail; r.message = e.message; r.elapsed = elapsed }
        rescue => e
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          t.dup.tap { |r| r.status = :error; r.message = "#{e.class}: #{e.message}"; r.elapsed = elapsed }
        end
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # RunResult — immutable collection of TestRecord results.
    # ─────────────────────────────────────────────────────────────────────────
    class RunResult
      attr_reader :records

      def initialize(records)
        @records = records
      end

      def passed  = @records.count { _1.status == :pass }
      def failed  = @records.count { _1.status == :fail }
      def errored = @records.count { _1.status == :error }
      def skipped = @records.count { _1.status == :skip }
      def total   = @records.size
      def success? = failed + errored == 0

      def to_h
        {
          success: success?,
          passed: passed, failed: failed, errored: errored, skipped: skipped, total: total,
          tests: @records.map do |r|
            { name: r.name, suite: r.suite, tags: r.tags, status: r.status,
              elapsed: r.elapsed&.round(3), message: r.message }
          end
        }
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TestContext — the `self` inside each test block.
    # ─────────────────────────────────────────────────────────────────────────
    class TestContext
      def initialize(http, target)
        @http   = http
        @target = target
      end

      attr_reader :http

      def ssh_run(cmd)  = @target.capture(cmd)
      def run_cmd(cmd)  = @target.capture(cmd)

      # ── Assertions ────────────────────────────────────────────────────────

      def assert(condition, message = "assertion failed")
        raise AssertionError, message unless condition
      end

      def refute(condition, message = "expected condition to be false")
        raise AssertionError, message if condition
      end

      def assert_equal(expected, actual, message = nil)
        return if expected == actual
        raise AssertionError, message || "expected #{expected.inspect}\n     got #{actual.inspect}"
      end

      # assert_status res, 200
      # assert_status res, 200..299
      def assert_status(res, expected)
        ok = expected.is_a?(Range) ? expected.cover?(res.status) : res.status == expected
        raise AssertionError, "expected HTTP #{expected}, got #{res.status}\n     body: #{res.body.slice(0, 120)}" unless ok
      end

      def assert_body(res, expected)
        case expected
        when Regexp
          raise AssertionError, "expected body to match #{expected}\n     body: #{res.body.inspect}" unless res.body.match?(expected)
        else
          raise AssertionError, "expected body to include #{expected.inspect}\n     body: #{res.body.inspect}" unless res.body.include?(expected.to_s)
        end
      end

      def assert_header(res, name, expected = nil)
        val = res.header(name)
        raise AssertionError, "expected header '#{name}' to be present" if val.nil?
        return unless expected
        ok = expected.is_a?(Regexp) ? val.match?(expected) : val.include?(expected.to_s)
        raise AssertionError, "header '#{name}': expected #{expected.inspect}, got #{val.inspect}" unless ok
      end

      def refute_header(res, name)
        val = res.header(name)
        raise AssertionError, "expected header '#{name}' to be absent, got #{val.inspect}" unless val.nil?
      end

      def assert_json(res, &block)
        parsed = JSON.parse(res.body)
        result = block.call(parsed)
        raise AssertionError, "JSON assertion failed\n     body: #{res.body.slice(0, 200)}" unless result
      rescue JSON::ParserError => e
        raise AssertionError, "Response body is not valid JSON: #{e.message}"
      end
    end
  end
end
