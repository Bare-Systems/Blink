# frozen_string_literal: true

require_relative "test_helper"

class ReportCommandTest < BlinkTestCase
  def test_report_generate_writes_html_and_json_exports
    with_fixture_workspace do |workspace|
      assert run_cli("test", "fixture", "--json", chdir: workspace)[:status].success?
      assert run_cli("rollback", "fixture", "--json", chdir: workspace)[:status].success?

      html_result = run_cli("report", "generate", "--format", "html", "--json", chdir: workspace)
      json_result = run_cli("report", "generate", "--format", "json", "--json", chdir: workspace)

      html_payload = parse_json_output(html_result)
      json_payload = parse_json_output(json_result)

      html_path = html_payload.dig("details", "output")
      json_path = json_payload.dig("details", "output")

      assert File.exist?(html_path)
      assert File.exist?(json_path)
      assert_includes File.read(html_path), "Blink Report"
      assert_includes File.read(html_path), "Rollback succeeded"
      assert_equal "fixture", JSON.parse(File.read(json_path)).dig("services").keys.first
    end
  end
end
