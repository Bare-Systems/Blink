# frozen_string_literal: true

require_relative "test_helper"

class LocalBuildSourceTest < BlinkTestCase
  def test_local_build_stages_artifact_and_applies_source_env
    Dir.mktmpdir("blink-local-build") do |tmp|
      File.write(File.join(tmp, "build.rb"), <<~RUBY)
        Dir.mkdir("out") unless Dir.exist?("out")
        File.write("out/artifact.txt", ENV.fetch("BLINK_BUILD_VALUE"))
      RUBY

      source = Blink::Sources.build(
        "type" => "local_build",
        "workdir" => tmp,
        "command" => "ruby build.rb",
        "artifact" => "out/artifact.txt",
        "env" => { "BLINK_BUILD_VALUE" => "from-source-env" }
      )

      fetched_path = source.fetch

      assert File.exist?(fetched_path)
      assert_equal "from-source-env", File.read(fetched_path)
      refute_equal File.join(tmp, "out", "artifact.txt"), fetched_path
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    end
  end

  def test_local_build_merges_build_specific_env
    Dir.mktmpdir("blink-local-build-multi") do |tmp|
      File.write(File.join(tmp, "build.rb"), <<~'RUBY')
        Dir.mkdir("out") unless Dir.exist?("out")
        File.write("out/artifact.txt", "#{ENV.fetch("GLOBAL_VALUE")}-#{ENV.fetch("BUILD_VALUE")}")
      RUBY

      source = Blink::Sources.build(
        "type" => "local_build",
        "workdir" => tmp,
        "default" => "special",
        "env" => { "GLOBAL_VALUE" => "global" },
        "builds" => {
          "special" => {
            "command" => "ruby build.rb",
            "artifact" => "out/artifact.txt",
            "env" => { "BUILD_VALUE" => "build" }
          }
        }
      )

      fetched_path = source.fetch

      assert_equal "global-build", File.read(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    end
  end

  def test_local_build_reuses_cached_artifact_when_inputs_are_unchanged
    Dir.mktmpdir("blink-local-build-cache") do |tmp|
      log_path = File.join(Dir.tmpdir, "blink-build-log-#{Process.pid}-#{rand(100_000)}.log")
      File.write(File.join(tmp, "build.rb"), <<~RUBY)
        Dir.mkdir("out") unless Dir.exist?("out")
        File.write("out/artifact.txt", "cached-build")
        File.open(ENV.fetch("BUILD_LOG"), "a") { |f| f.puts("built") }
      RUBY

      source = Blink::Sources.build(
        "type" => "local_build",
        "_manifest_dir" => tmp,
        "_cache_dir" => File.join(tmp, ".blink", "artifacts"),
        "_service_name" => "fixture",
        "workdir" => tmp,
        "command" => "ruby build.rb",
        "artifact" => "out/artifact.txt",
        "env" => { "BUILD_LOG" => log_path }
      )

      first = source.fetch
      second = source.fetch

      assert_equal first, second
      assert_equal 1, File.readlines(log_path).size
      assert_includes first, "/.blink/artifacts/fixture/"
    ensure
      FileUtils.rm_f(log_path) if defined?(log_path) && log_path
      FileUtils.rm_rf(File.join(tmp, ".blink"))
    end
  end
end
