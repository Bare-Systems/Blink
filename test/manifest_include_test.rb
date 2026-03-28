# frozen_string_literal: true

require_relative "test_helper"

class ManifestIncludeTest < BlinkTestCase
  def test_validate_file_allows_parent_manifest_with_only_imports
    with_composed_workspace do |root, _child|
      result = Blink::Manifest.validate_file(File.join(root, "blink.toml"))

      assert result.valid?
      assert_equal 1, result.service_count
      assert_equal 0, result.target_count
    end
  end

  def test_build_from_parent_manifest_uses_child_manifest_directory_for_source
    with_composed_workspace do |root, _child|
      result = run_cli("build", "child", "--json", chdir: root)

      assert result[:status].success?, result[:stdout]

      payload = parse_json_output(result)
      artifact_path = payload.dig("details", "artifact_path")
      assert File.exist?(artifact_path), "expected built artifact at #{artifact_path}"
      assert_equal "from-child-source", File.read(artifact_path)
    end
  end

  def test_test_from_parent_manifest_uses_child_manifest_directory_for_suite
    with_composed_workspace do |root, _child|
      result = run_cli("test", "child", "--json", chdir: root)

      assert result[:status].success?, result[:stdout]

      payload = parse_json_output(result)
      assert_equal true, payload["success"]
      assert_equal "1/1 passed", payload["summary"]
    end
  end

  def test_discover_all_and_load_for_service_ignore_imported_child_manifest_duplicates
    with_composed_workspace do |root, child|
      manifests = Blink::Manifest.discover_all(start_dir: root)

      assert_equal [File.join(root, "blink.toml")], manifests.map(&:path)

      manifest = Blink::Manifest.load_for_service!("child", start_dir: root)
      assert_equal File.join(root, "blink.toml"), manifest.path
      assert_equal child, manifest.service_dir("child")
    end
  end

  private

  def with_composed_workspace
    with_tmp_workspace do |workspace|
      root = File.join(workspace, "root")
      child = File.join(root, "child")
      FileUtils.mkdir_p(child)

      File.write(
        File.join(root, "blink.toml"),
        <<~TOML
          [blink]
          version = "1"
          includes = ["child/blink.toml"]
        TOML
      )

      File.write(
        File.join(child, "blink.toml"),
        <<~TOML
          [blink]
          version = "1"

          [targets.local]
          type = "local"
          base = "#{child}"

          [services.child]
          description = "child service"

          [services.child.deploy]
          target = "local"
          pipeline = ["fetch_artifact"]

          [services.child.source]
          type = "local_build"
          workdir = "."
          command = "mkdir -p dist && printf from-child-source > dist/artifact.txt"
          artifact = "dist/artifact.txt"

          [services.child.verify]
          suite = "suite.rb"
          tags = ["smoke"]
        TOML
      )

      File.write(
        File.join(child, "suite.rb"),
        <<~RUBY
          # frozen_string_literal: true

          class IncludedChildSuite < Blink::Testing::Suite
            suite_name "Included Child"

            test "child suite wired", tags: [:smoke] do
              assert true
            end
          end
        RUBY
      )

      yield root, child
    end
  end
end
