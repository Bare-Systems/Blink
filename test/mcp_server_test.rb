# frozen_string_literal: true

require_relative "test_helper"
require "blink/mcp_server"

# Sprint C guardrail: verify the MCP server emits MCP-spec-aligned
# CallToolResult shapes (structuredContent + isError + content) and attaches
# tool annotations/outputSchema from tools/list.
#
# Drives the server directly via its `dispatch` method rather than through
# stdio pipes — this keeps the test fast and deterministic.
class MCPServerTest < BlinkTestCase
  def setup
    @server = Blink::MCPServer.new
  end

  def test_tools_list_includes_output_schema_and_annotations
    resp = dispatch("tools/list")
    tools = resp[:result][:tools]
    deploy = tools.find { |t| t[:name] == "blink_deploy" }

    refute_nil deploy
    assert_equal Blink::MCPServer::OUTPUT_SCHEMA, deploy[:outputSchema]
    assert_equal true, deploy[:annotations][:destructiveHint]
    assert_equal false, deploy[:annotations][:readOnlyHint]

    plan = tools.find { |t| t[:name] == "blink_plan" }
    assert_equal true, plan[:annotations][:readOnlyHint]
    assert_equal true, plan[:annotations][:idempotentHint]
  end

  def test_tools_call_returns_structured_content_and_is_error
    # Invoke blink_plan on a non-existent service — should surface as
    # isError:true in the result, NOT as a JSON-RPC error.
    resp = dispatch("tools/call", { "name" => "blink_plan", "arguments" => { "service" => "definitely-not-a-real-service" } })

    assert_nil resp[:error], "operational failure leaked as JSON-RPC error: #{resp[:error].inspect}"
    result = resp[:result]
    assert_equal true, result[:isError]
    assert_kind_of Hash, result[:structuredContent]
    assert_equal false, result[:structuredContent]["success"]
    assert_kind_of Array, result[:content]
    assert_equal "text", result[:content].first[:type]
  end

  def test_tools_call_unknown_tool_still_returns_is_error
    resp = dispatch("tools/call", { "name" => "blink_not_a_tool", "arguments" => {} })
    assert_nil resp[:error]
    assert_equal true, resp[:result][:isError]
  end

  def test_initialize_advertises_protocol_version
    resp = dispatch("initialize")
    assert_equal Blink::MCPServer::PROTOCOL_VERSION, resp[:result][:protocolVersion]
  end

  # ── Sprint F.4 task tools ─────────────────────────────────────────────

  def test_tools_list_includes_task_tools
    resp = dispatch("tools/list")
    names = resp[:result][:tools].map { |t| t[:name] }
    assert_includes names, "blink_task_status"
    assert_includes names, "blink_task_cancel"
  end

  def test_task_status_with_no_tasks
    resp = dispatch("tools/call", { "name" => "blink_task_status", "arguments" => {} })
    result = resp[:result][:structuredContent]
    assert_equal true, result["success"]
    assert_equal [], result.dig("data", "tasks")
  end

  def test_task_status_unknown_id
    resp = dispatch("tools/call", { "name" => "blink_task_status", "arguments" => { "task_id" => "nonexistent" } })
    result = resp[:result][:structuredContent]
    assert_equal false, result["success"]
    assert_match(/not found/, result["summary"])
  end

  def test_task_cancel_unknown_id
    resp = dispatch("tools/call", { "name" => "blink_task_cancel", "arguments" => { "task_id" => "nonexistent" } })
    result = resp[:result][:structuredContent]
    assert_equal false, result["success"]
    assert_match(/not found/, result["summary"])
  end

  def test_build_tool_schema_includes_task_param
    resp = dispatch("tools/list")
    build = resp[:result][:tools].find { |t| t[:name] == "blink_build" }
    assert build[:inputSchema][:properties].key?(:task), "blink_build missing task parameter"
    deploy = resp[:result][:tools].find { |t| t[:name] == "blink_deploy" }
    assert deploy[:inputSchema][:properties].key?(:task), "blink_deploy missing task parameter"
  end

  def test_redact_args_scrubs_secret_shaped_keys
    out = @server.send(:redact_args, { "service" => "app", "api_key" => "sk-xyz", "token" => "t", "Authorization" => "Bearer x" })
    assert_equal "app", out["service"]
    assert_equal "[REDACTED]", out["api_key"]
    assert_equal "[REDACTED]", out["token"]
    assert_equal "[REDACTED]", out["Authorization"]
  end

  private

  def dispatch(method, params = nil)
    req = { "jsonrpc" => "2.0", "id" => 1, "method" => method }
    req["params"] = params if params
    @server.send(:dispatch, req)
  end
end
