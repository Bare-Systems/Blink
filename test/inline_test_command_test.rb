# frozen_string_literal: true

require_relative "test_helper"

class InlineTestCommandTest < BlinkTestCase
  def test_blink_test_runs_inline_api_and_ui_suites
    with_http_server(
      "/health" => lambda { |_req|
        [200, { "Content-Type" => "application/json" }, JSON.generate("status" => "ok", "data" => { "services" => [{ "name" => "demo" }] })]
      },
      "/" => lambda { |_req|
        html = <<~HTML
          <html>
            <body>
              <div id="app-root">
                <span class="status">Ready</span>
                <a data-testid="docs-link" href="/docs">Docs</a>
              </div>
            </body>
          </html>
        HTML
        [200, { "Content-Type" => "text/html" }, html]
      }
    ) do |port|
      with_tmp_workspace do |workspace|
        File.write(File.join(workspace, "blink.toml"), inline_manifest(port))

        list_result = run_cli("test", "demo", "--list", "--json", chdir: workspace)
        run_result = run_cli("test", "demo", "--json", chdir: workspace)

        list_payload = parse_json_output(list_result)
        run_payload = parse_json_output(run_result)

        assert list_result[:status].success?, list_result[:stderr]
        assert_equal true, list_payload["success"]
        assert_equal 2, list_payload.dig("details", "tests").size
        assert_equal ["api-health", "ui-home"], list_payload.dig("details", "tests").map { |test| test["name"] }.sort

        assert run_result[:status].success?, run_result[:stderr]
        assert_equal true, run_payload["success"]
        assert_equal 2, run_payload.dig("details", "passed")
        assert_equal 2, run_payload.dig("details", "total")
        assert_equal %w[pass pass], run_payload.dig("details", "tests").map { |test| test["status"] }.sort
      end
    end
  end

  def test_schema_rejects_unknown_selector_engine
    with_tmp_workspace do |workspace|
      manifest_path = File.join(workspace, "blink.toml")
      File.write(manifest_path, invalid_inline_manifest)

      result = Blink::Manifest.validate_file(manifest_path)

      refute result.valid?
      assert_includes result.errors.map(&:path), "services.demo.verify.tests.home.checks.root.engine"
    end
  end

  private

  def inline_manifest(port)
    <<~TOML
      [blink]
      version = "1"

      [targets.local]
      type = "local"

      [services.demo]
      description = "Inline verification fixture"

      [services.demo.deploy]
      target = "local"
      pipeline = ["verify"]

      [services.demo.verify]
      tags = ["smoke"]

      [services.demo.verify.tests.api-health]
      type = "api"
      url = "http://127.0.0.1:#{port}/health"

      [services.demo.verify.tests.api-health.checks.status]
      type = "status"
      equals = 200

      [services.demo.verify.tests.api-health.checks.status_json]
      type = "json"
      path = "$.status"
      equals = "ok"

      [services.demo.verify.tests.api-health.checks.first_service]
      type = "json"
      path = "$.data.services[0].name"
      equals = "demo"

      [services.demo.verify.tests.ui-home]
      type = "ui"
      url = "http://127.0.0.1:#{port}/"

      [services.demo.verify.tests.ui-home.checks.root]
      type = "selector"
      engine = "css"
      selector = "#app-root"

      [services.demo.verify.tests.ui-home.checks.docs]
      type = "selector"
      engine = "xpath"
      selector = "//a[@data-testid='docs-link']"

      [services.demo.verify.tests.ui-home.checks.ready]
      type = "text"
      contains = "Ready"
    TOML
  end

  def invalid_inline_manifest
    <<~TOML
      [blink]
      version = "1"

      [targets.local]
      type = "local"

      [services.demo]

      [services.demo.deploy]
      target = "local"
      pipeline = ["verify"]

      [services.demo.verify.tests.home]
      type = "ui"
      url = "http://127.0.0.1:3000/"

      [services.demo.verify.tests.home.checks.root]
      type = "selector"
      engine = "invalid"
      selector = "#app-root"
    TOML
  end
end
