# frozen_string_literal: true

require_relative "test_helper"
require "blink/mcp_server"

class PlatformStackTest < BlinkTestCase
  def test_schema_accepts_platform_fixture_manifest
    result = Blink::Manifest.validate_file(PLATFORM_FIXTURE_MANIFEST)

    assert result.valid?, result.errors.map(&:message).join("\n")
    assert_equal 2, result.service_count
    assert_equal 1, result.target_count
  end

  def test_schema_rejects_hardcoded_secret_values
    with_tmp_workspace do |workspace|
      manifest_path = File.join(workspace, "blink.toml")
      File.write(manifest_path, <<~TOML)
        [blink]
        version = "1"

        [targets.local]
        type = "local"

        [targets.local.env]
        BEARCLAW_TOKEN = "plain-token"

        [services.demo]
        description = "Secret validation fixture"

        [services.demo.deploy]
        target = "local"
        pipeline = ["verify"]

        [services.demo.verify.tests.binary]
        type = "shell"
        command = "echo ok"
        expect_output = "ok"
      TOML

      result = Blink::Manifest.validate_file(manifest_path)

      refute result.valid?
      assert_includes result.errors.map(&:path), "targets.local.env.BEARCLAW_TOKEN"
      assert_match(/\$\{BEARCLAW_TOKEN\}/, result.errors.map(&:message).join("\n"))
    end
  end

  def test_deploy_all_services_from_platform_manifest_is_idempotent
    ENV["BLINK_BEARCLAW_TOKEN"] = "fixture-token"

    with_platform_workspace do |workspace|
      tardigrade_first = run_cli("deploy", "tardigrade", "--json", chdir: workspace)
      tardigrade_second = run_cli("deploy", "tardigrade", "--json", chdir: workspace)
      bearclaw_first = run_cli("deploy", "bearclaw", "--json", chdir: workspace)
      bearclaw_second = run_cli("deploy", "bearclaw", "--json", chdir: workspace)

      [tardigrade_first, tardigrade_second, bearclaw_first, bearclaw_second].each do |result|
        assert result[:status].success?, result[:stderr]
      end

      assert_equal true, parse_json_output(tardigrade_first)["success"]
      assert_equal true, parse_json_output(tardigrade_second)["success"]
      assert_equal true, parse_json_output(bearclaw_first)["success"]
      assert_equal true, parse_json_output(bearclaw_second)["success"]

      state = JSON.parse(File.read(File.join(workspace, ".blink", "state", "current.json")))
      assert_equal true, state.dig("services", "tardigrade", "last_deploy", "artifact", "cached")
      assert_equal true, state.dig("services", "bearclaw", "last_deploy", "artifact", "cached")
    end
  ensure
    ENV.delete("BLINK_BEARCLAW_TOKEN")
  end

  def test_mcp_tools_surface_structured_platform_results
    ENV["BLINK_BEARCLAW_TOKEN"] = "fixture-token"

    with_http_server(
      "/tardigrade/health" => ->(_req) { [200, { "Content-Type" => "text/plain" }, "ok"] },
      "/bearclaw/health" => ->(_req) { [200, { "Content-Type" => "text/plain" }, "ok"] }
    ) do |port|
      with_platform_workspace(port: port) do |workspace|
        Dir.chdir(workspace) do
          server = Blink::MCPServer.new

          tools = dispatch(server, "tools/list").dig(:result, :tools)
          %w[blink_status blink_deploy blink_test].each do |tool_name|
            tool = tools.find { |entry| entry[:name] == tool_name }
            refute_nil tool
            assert_kind_of Hash, tool[:inputSchema]
          end

          status = dispatch(server, "tools/call", { "name" => "blink_status", "arguments" => {} }).dig(:result, :structuredContent)
          assert_equal true, status["success"]
          assert_equal %w[bearclaw tardigrade], status.dig("data", "services").map { |service| service["name"] }.sort

          deploy = dispatch(server, "tools/call", { "name" => "blink_deploy", "arguments" => { "service" => "tardigrade" } }).dig(:result, :structuredContent)
          assert_equal true, deploy["success"]
          assert_equal "tardigrade", deploy.dig("data", "service")

          second_deploy = dispatch(server, "tools/call", { "name" => "blink_deploy", "arguments" => { "service" => "bearclaw" } }).dig(:result, :structuredContent)
          assert_equal true, second_deploy["success"]
          assert_equal "bearclaw", second_deploy.dig("data", "service")

          test_result = dispatch(server, "tools/call", { "name" => "blink_test", "arguments" => {} }).dig(:result, :structuredContent)
          assert_equal true, test_result["success"]
          assert_equal %w[bearclaw tardigrade], test_result.dig("data", "service_results").keys.sort
          assert_equal true, test_result.dig("data", "service_results", "bearclaw", "success")
          assert_equal true, test_result.dig("data", "service_results", "tardigrade", "success")
        end
      end
    end
  ensure
    ENV.delete("BLINK_BEARCLAW_TOKEN")
  end

  private

  def dispatch(server, method, params = nil)
    request = { "jsonrpc" => "2.0", "id" => 1, "method" => method }
    request["params"] = params if params
    server.send(:dispatch, request)
  end
end
