# frozen_string_literal: true

require_relative "test_helper"

class ArtifactCacheTest < BlinkTestCase
  def test_deploy_reuses_cached_artifact_and_records_cache_metadata
    with_fixture_workspace do |workspace|
      FileUtils.mkdir_p(File.join(workspace, "bin"))
      File.write(File.join(workspace, "bin", "fixture"), "artifact-binary")

      first = run_cli("deploy", "fixture", "--json", chdir: workspace)
      second = run_cli("deploy", "fixture", "--json", chdir: workspace)

      assert first[:status].success?, first[:stderr]
      assert second[:status].success?, second[:stderr]

      second_payload = parse_json_output(second)
      assert_includes second_payload.dig("details", "output"), "Reusing cached artifact"

      state = JSON.parse(File.read(File.join(workspace, ".blink", "state", "current.json")))
      artifact = state.dig("services", "fixture", "last_deploy", "artifact")

      assert_equal true, artifact["cached"]
      assert_equal "local_build", artifact["source_type"]
      assert_includes artifact["cache_summary"], "local_build"
      assert_equal "local_build", artifact.dig("cache", "source_type")
      assert_includes artifact["path"], "/.blink/artifacts/fixture/"
    end
  end
end
