# frozen_string_literal: true

require_relative "test_helper"

class PlannerTest < BlinkTestCase
  def test_plan_includes_step_definitions_and_deterministic_hash
    manifest = Blink::Manifest.load(VALID_FIXTURE_MANIFEST)
    planner = Blink::Planner.new(manifest)

    first = planner.build("fixture")
    second = planner.build("fixture")

    assert first.executable?
    assert_equal first.config_hash, second.config_hash
    assert_equal "fetch_artifact", first.steps.first[:step]
    assert_equal "Blink::Steps::FetchArtifact", first.steps.first[:definition][:class_name]
    assert_equal ["artifact_path"], first.steps.first[:definition][:mutates_context]
    assert_equal "verify", first.steps.last[:step]
    assert_equal "stop", first.rollback_steps.first[:step]
  end

  def test_rollback_plan_uses_declared_rollback_pipeline
    manifest = Blink::Manifest.load(VALID_FIXTURE_MANIFEST)
    plan = Blink::Planner.new(manifest).build("fixture", operation: "rollback")

    assert_equal %w[stop start], plan.pipeline
    assert_empty plan.rollback
    assert_empty plan.warnings
    assert_empty plan.blockers
  end

  def test_plan_blocks_insecure_http_url_source_without_explicit_opt_in
    with_manifest(<<~TOML) do |manifest|
      [blink]
      version = "1"

      [targets.local]
      type = "local"
      base = "/tmp/blink-security"

      [services.fixture]
      description = "fixture"

      [services.fixture.source]
      type = "url"
      url = "http://downloads.example.test/app.tar.gz"
      artifact = "app.tar.gz"

      [services.fixture.deploy]
      target = "local"
      pipeline = ["fetch_artifact"]
    TOML
      plan = Blink::Planner.new(manifest).build("fixture")

      refute plan.executable?
      assert_includes plan.blockers.join("\n"), "Source URL uses insecure HTTP transport"
      assert_includes plan.warnings.join("\n"), "Remote source has no artifact verification configured."
      assert_equal "http", plan.security["transport"]
      assert_equal false, plan.security["allow_insecure"]
    end
  end

  def test_plan_warns_for_explicitly_allowed_insecure_http_with_checksum_provenance
    with_manifest(<<~TOML) do |manifest|
      [blink]
      version = "1"

      [targets.local]
      type = "local"
      base = "/tmp/blink-security"

      [services.fixture]
      description = "fixture"

      [services.fixture.source]
      type = "url"
      url = "http://downloads.example.test/app.tar.gz"
      artifact = "app.tar.gz"
      checksum_url = "http://downloads.example.test/checksums.txt"
      signature_url = "http://downloads.example.test/app.tar.gz.sig"
      verify_command = "verify-tool {{signature}} {{artifact}}"
      allow_insecure = true

      [services.fixture.deploy]
      target = "local"
      pipeline = ["fetch_artifact"]
    TOML
      plan = Blink::Planner.new(manifest).build("fixture")

      assert plan.executable?
      assert_includes plan.warnings.join("\n"), "Source URL uses insecure HTTP transport."
      assert_includes plan.warnings.join("\n"), "Checksum source uses insecure HTTP transport."
      assert_includes plan.warnings.join("\n"), "Signature source uses insecure HTTP transport."
      assert_equal "checksum_url", plan.security.dig("integrity", "mode")
      assert_equal "checksum_url", plan.security.dig("provenance", "mode")
      assert_equal "signature_url", plan.security.dig("signature", "mode")
    end
  end

  private

  def with_manifest(contents)
    Dir.mktmpdir("blink-planner") do |tmp|
      path = File.join(tmp, "blink.toml")
      File.write(path, contents)
      yield Blink::Manifest.load(path)
    end
  end
end
