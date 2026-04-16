# frozen_string_literal: true

require_relative "test_helper"

# Sprint F.2 coverage: `Sources::Base` still behaves as a single cohesive
# class from the outside, but internally its caching and verification
# concerns live in separate, independently includeable modules
# (`Sources::Cache` and `Sources::Verification`). These tests pin that
# split so later refactors don't silently collapse the modules back into
# Base without noticing.
class SourcesSplitTest < Minitest::Test
  def test_cache_and_verification_are_separate_modules
    assert_instance_of Module, Blink::Sources::Cache
    assert_instance_of Module, Blink::Sources::Verification
    # Make sure neither was accidentally left as a class.
    refute_operator Blink::Sources::Cache, :instance_of?, Class
    refute_operator Blink::Sources::Verification, :instance_of?, Class
  end

  def test_base_includes_both_concerns
    ancestors = Blink::Sources::Base.ancestors
    assert_includes ancestors, Blink::Sources::Cache
    assert_includes ancestors, Blink::Sources::Verification
  end

  def test_cache_methods_live_on_cache_module_not_base_directly
    # Picked a representative method from each concern. If either ends up
    # redefined on Base, Base.instance_method(name).owner changes.
    assert_equal Blink::Sources::Cache,
                 Blink::Sources::Base.instance_method(:fetch_with_cache).owner
    assert_equal Blink::Sources::Cache,
                 Blink::Sources::Base.instance_method(:cache_reusable?).owner
    assert_equal Blink::Sources::Verification,
                 Blink::Sources::Base.instance_method(:verify_sha256!).owner
    assert_equal Blink::Sources::Verification,
                 Blink::Sources::Base.instance_method(:sha256_from_document).owner
  end

  def test_concrete_sources_still_function_end_to_end_via_mixins
    # Register a tiny test-only source that exercises cache + verify helpers
    # to confirm the mixed-in methods are reachable from a subclass.
    klass = Class.new(Blink::Sources::Base) do
      def fetch(version: "latest", build_name: nil); end

      public :sanitize_filename, :cache_reusable?, :sha256_from_document
    end
    src = klass.new({})
    assert_equal "ok", src.sanitize_filename("ok")
    assert src.cache_reusable?("/x", true, nil)
    sha = "0" * 64
    assert_equal sha, src.sha256_from_document("#{sha}  a.tgz", filename: "a.tgz")
  end
end
