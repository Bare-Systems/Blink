# frozen_string_literal: true

require_relative "test_helper"

# Sprint E coverage: registry-driven schema + TargetError hierarchy.
#
# These tests pin two invariants:
#
#   1. Schema's list of "known" sources / steps / inline test types is derived
#      at runtime from the corresponding registry. Registering a new plugin
#      type must flow through to the validator without Schema edits.
#
#   2. `LocalTarget` and `SSHTarget` raise subclasses of `Blink::TargetError`,
#      and `SSHError` remains an alias for `SSHTargetError` for back-compat.
class RegistryAndTargetErrorTest < Minitest::Test
  def test_sources_registry_covers_all_builtin_types
    assert_includes Blink::Sources.known_types, "url"
    assert_includes Blink::Sources.known_types, "github_release"
    assert_includes Blink::Sources.known_types, "local_build"
    assert_includes Blink::Sources.known_types, "containerized_local_build"
  end

  def test_inline_runner_registry_covers_all_builtin_types
    types = Blink::Testing::InlineRunner.known_types
    %w[http api shell mcp ui script].each { |t| assert_includes types, t }
  end

  def test_steps_registry_covers_core_steps
    %w[fetch_artifact install start stop health_check verify].each do |name|
      assert Blink::Steps::REGISTRY.key?(name), "expected step '#{name}' in registry"
    end
  end

  def test_schema_known_source_types_reads_from_registry
    schema = Blink::Schema::Validator.allocate
    assert_equal Blink::Sources::REGISTRY.keys.sort,
                 schema.send(:known_source_types)
  end

  def test_schema_known_inline_test_types_reads_from_registry
    schema = Blink::Schema::Validator.allocate
    assert_equal Blink::Testing::InlineRunner::REGISTRY.keys.sort,
                 schema.send(:known_inline_test_types)
  end

  def test_schema_known_steps_reads_from_registry
    schema = Blink::Schema::Validator.allocate
    assert_equal Blink::Steps::REGISTRY.keys.sort,
                 schema.send(:known_steps)
  end

  def test_plugin_registration_picks_up_in_schema_without_edits
    stub_klass = Class.new(Blink::Sources::Base)
    Blink::Sources.register("__test_plugin__", stub_klass)
    begin
      assert_includes Blink::Schema::Validator.allocate.send(:known_source_types), "__test_plugin__"
    ensure
      Blink::Sources::REGISTRY.delete("__test_plugin__")
    end
  end

  def test_target_error_hierarchy
    assert_operator Blink::TargetError, :<, StandardError
    assert_operator Blink::LocalTargetError, :<, Blink::TargetError
    assert_operator Blink::SSHTargetError, :<, Blink::TargetError
  end

  def test_ssh_error_alias_preserved_for_backward_compat
    assert_equal Blink::SSHTargetError, Blink::SSHError
  end

  def test_local_target_raises_local_target_error
    target = Blink::Targets::LocalTarget.new("local", { "type" => "local" })
    err = assert_raises(Blink::LocalTargetError) do
      target.capture("exit 1 && false")
    end
    assert_kind_of Blink::TargetError, err
  end
end
