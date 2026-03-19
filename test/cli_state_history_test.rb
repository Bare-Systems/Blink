# frozen_string_literal: true

require_relative "test_helper"

class CliStateHistoryTest < BlinkTestCase
  def test_state_and_history_reflect_test_and_rollback_runs
    with_fixture_workspace do |workspace|
      test_result = run_cli("test", "fixture", "--json", chdir: workspace)
      assert test_result[:status].success?, test_result[:stderr]

      rollback_result = run_cli("rollback", "fixture", "--json", chdir: workspace)
      assert rollback_result[:status].success?, rollback_result[:stderr]

      state_result = run_cli("state", "fixture", "--json", chdir: workspace)
      history_result = run_cli("history", "fixture", "--json", chdir: workspace)

      state = parse_json_output(state_result)
      history = parse_json_output(history_result)

      assert_equal true, state["success"]
      assert_equal "rollback", state.dig("details", "state", "last_run", "operation")
      assert_equal true, state.dig("details", "state", "last_rollback", "success")
      assert_equal true, state.dig("details", "state", "last_test", "success")

      assert_equal true, history["success"]
      assert_operator history.dig("details", "runs").size, :>=, 2
      assert_equal "rollback", history.dig("details", "runs", 0, "operation")
    end
  end
end
