# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < BlinkTestCase
  def test_valid_manifest_fixture_passes_validation
    result = Blink::Manifest.validate_file(VALID_FIXTURE_MANIFEST)

    assert result.valid?
    assert_empty result.errors
    assert_equal 1, result.service_count
    assert_equal 1, result.target_count
  end

  def test_invalid_manifest_fixture_reports_actionable_errors
    result = Blink::Manifest.validate_file(INVALID_FIXTURE_MANIFEST)

    refute result.valid?
    refute_empty result.errors
    assert_includes result.errors.map(&:path), "services.broken.deploy.target"
    assert_match(/unknown target/i, result.errors.map(&:message).join("\n"))
  end
end
