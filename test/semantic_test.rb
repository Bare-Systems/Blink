# frozen_string_literal: true

require_relative "test_helper"

# Sprint F.1 coverage: the semantic nucleus structs render to stable,
# round-trip-safe hash shapes. These are the types the CLI and MCP server
# will serialize from as each callsite is migrated — so their `to_h` shape
# is effectively a public contract and worth pinning.
class SemanticTest < Minitest::Test
  S = Blink::Semantic

  def test_diagnostic_severity_predicates
    err = S::Diagnostic.new(severity: :error, path: "a", message: "bad")
    warn_ = S::Diagnostic.new(severity: :warning, path: "b", message: "meh")
    note = S::Diagnostic.new(severity: :note, path: "c", message: "fyi")
    assert err.error?
    assert warn_.warning?
    assert note.note?
    refute err.warning?
  end

  def test_diagnostics_bag_groups_by_severity
    bag = S::Diagnostics.empty
    bag.add(severity: :error,   path: "x", message: "e")
    bag.add(severity: :warning, path: "y", message: "w")
    bag.add(severity: :note,    path: "z", message: "n")

    assert_equal 1, bag.errors.size
    assert_equal 1, bag.warnings.size
    assert_equal 1, bag.notes.size
    refute bag.empty?
  end

  def test_step_result_to_h_stable_shape
    s = S::StepResult.new(
      name: "fetch_artifact", status: :ok, changed: true, idempotent: true,
      elapsed: 1.23, message: "fetched", data: { "path" => "/tmp/a.tgz" }
    )
    h = s.to_h
    assert_equal "ok", h[:status]
    assert_equal true, h[:changed]
    assert_equal true, h[:idempotent]
    assert_equal({ "path" => "/tmp/a.tgz" }, h[:data])
    assert s.ok?
  end

  def test_artifact_ref_to_h
    a = S::ArtifactRef.new(path: "/tmp/x.tgz", filename: "x.tgz", sha256: "abc",
                           size_bytes: 42, provenance: "url", metadata: { "k" => "v" })
    h = a.to_h
    assert_equal "/tmp/x.tgz", h[:path]
    assert_equal "abc", h[:sha256]
    assert_equal({ "k" => "v" }, h[:metadata])
  end

  def test_operation_result_changed_and_to_h
    steps = [
      S::StepResult.new(name: "a", status: :ok, changed: false, idempotent: true),
      S::StepResult.new(name: "b", status: :ok, changed: true,  idempotent: true),
    ]
    r = S::OperationResult.new(
      operation: :deploy, service: "svc", status: :ok, steps: steps,
      elapsed: 3.14, summary: "done", next_step: "run tests",
    )
    assert r.changed?
    refute r.no_op?
    h = r.to_h
    assert_equal "deploy", h[:operation]
    assert_equal "ok", h[:status]
    assert_equal 2, h[:steps].size
    assert_equal true, h[:changed]
  end

  def test_operation_plan_to_h_roundtrips_diagnostics
    diag = S::Diagnostics.empty.add(severity: :warning, path: "p", message: "m")
    plan = S::OperationPlan.new(
      operation: :deploy, service: "svc", target: "local", pipeline: %w[install start],
      rollback_pipeline: %w[stop], config_hash: "abc", diagnostics: diag, source: {},
    )
    h = plan.to_h
    assert_equal "deploy", h[:operation]
    assert_equal %w[install start], h[:pipeline]
    assert_equal 1, h[:diagnostics][:warnings].size
  end
end
