# frozen_string_literal: true

require_relative "test_helper"

class StepsCommandTest < BlinkTestCase
  def test_steps_command_returns_catalog_in_json_mode
    with_fixture_workspace do |workspace|
      result = run_cli("steps", "--json", chdir: workspace)
      assert result[:status].success?, result[:stderr]

      payload = parse_json_output(result)
      steps = payload.dig("details", "steps")

      assert_equal true, payload["success"]
      assert_includes steps.map { |step| step["name"] }, "fetch_artifact"
      verify = steps.find { |step| step["name"] == "verify" }
      assert_equal "verify", verify["config_section"]
      assert_includes verify["supported_target_types"], "local"
    end
  end

  def test_steps_command_filters_to_specific_step
    with_fixture_workspace do |workspace|
      result = run_cli("steps", "stop", "--json", chdir: workspace)
      assert result[:status].success?, result[:stderr]

      payload = parse_json_output(result)
      steps = payload.dig("details", "steps")

      assert_equal 1, steps.size
      assert_equal "stop", steps.first["name"]
      assert_equal ["command"], steps.first["required_keys"]
    end
  end
end
