# frozen_string_literal: true

require_relative "test_helper"

class InitCommandTest < BlinkTestCase
  def test_init_scaffolds_manifest_with_api_and_ui_examples
    with_tmp_workspace do |workspace|
      result = run_cli("init", "--json", chdir: workspace)
      payload = parse_json_output(result)
      manifest_path = File.join(workspace, "blink.toml")

      assert result[:status].success?, result[:stderr]
      assert_equal true, payload["success"]
      assert_equal File.realpath(manifest_path), File.realpath(payload.dig("details", "output"))
      assert File.exist?(manifest_path)

      content = File.read(manifest_path)
      assert_includes content, '[blink]'
      assert_includes content, 'type = "api"'
      assert_includes content, 'type = "ui"'
      assert_includes content, 'engine = "css"'
      assert_includes content, '.checks.status'
      assert_includes content, "Load testing is planned"
    end
  end

  def test_init_refuses_to_overwrite_without_force
    with_tmp_workspace do |workspace|
      manifest_path = File.join(workspace, "blink.toml")
      File.write(manifest_path, "original")

      result = run_cli("init", "--json", chdir: workspace)
      payload = parse_json_output(result)

      refute result[:status].success?
      assert_equal false, payload["success"]
      assert_equal "original", File.read(manifest_path)

      forced = run_cli("init", "--force", "--json", chdir: workspace)
      assert forced[:status].success?, forced[:stderr]
      refute_equal "original", File.read(manifest_path)
    end
  end
end
