# frozen_string_literal: true

require_relative "test_helper"

class MCPToolsTest < BlinkTestCase
  def test_mcp_exposes_steps_and_state_tools
    with_fixture_workspace do |workspace|
      test_result = run_cli("test", "fixture", "--json", chdir: workspace)
      assert test_result[:status].success?, test_result[:stderr]

      responses = nil
      Dir.chdir(workspace) do
        Open3.popen3(BIN, "--mcp") do |stdin, stdout, stderr, wait_thr|
          requests = [
            { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "1.0" } } },
            { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "blink_steps", arguments: { step: "verify" } } },
            { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "blink_state", arguments: { service: "fixture" } } }
          ]

          requests.each { |request| stdin.puts(JSON.generate(request)) }
          stdin.close

          responses = 3.times.map { JSON.parse(stdout.gets) }
          stderr.read
          assert wait_thr.value.success?
        end
      end

      steps_payload = JSON.parse(responses[1].dig("result", "content", 0, "text"))
      state_payload = JSON.parse(responses[2].dig("result", "content", 0, "text"))

      assert_equal true, steps_payload["success"]
      assert_equal "verify", steps_payload.dig("data", "steps", 0, "name")
      assert_equal true, state_payload["success"]
      assert_equal "fixture", state_payload.dig("data", "service")
      assert_equal true, state_payload.dig("data", "state", "last_test", "success")
    end
  end
end
