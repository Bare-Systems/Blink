# frozen_string_literal: true

require_relative "test_helper"

class ContainerizedLocalBuildSourceTest < BlinkTestCase
  CommandStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def test_schema_accepts_containerized_local_build_source_type
    data = {
      "blink" => { "version" => "1" },
      "targets" => { "local" => { "type" => "local" } },
      "services" => {
        "demo" => {
          "source" => {
            "type" => "containerized_local_build",
            "image" => "docker:cli",
            "mount" => ".:/workspace",
            "workdir" => "/workspace",
            "command" => "docker build .",
            "artifact" => "dist/image.tar.gz"
          },
          "deploy" => {
            "target" => "local",
            "pipeline" => ["fetch_artifact"]
          }
        }
      }
    }

    result = Blink::Schema.validate(data)

    assert result.valid?, result.errors.map(&:message).join("\n")
  end

  def test_schema_rejects_invalid_containerized_local_build_config
    data = {
      "blink" => { "version" => "1" },
      "targets" => { "local" => { "type" => "local" } },
      "services" => {
        "demo" => {
          "source" => {
            "type" => "containerized_local_build",
            "mount" => [],
            "workdir" => "/workspace",
            "command" => "docker build .",
            "docker_socket" => "yes"
          },
          "deploy" => {
            "target" => "local",
            "pipeline" => ["fetch_artifact"]
          }
        }
      }
    }

    result = Blink::Schema.validate(data)

    refute result.valid?
    messages = result.errors.map(&:message).join("\n")
    assert_includes messages, "containerized_local_build sources require image."
    assert_includes messages, "containerized_local_build sources require mount = \"host:container\" or an array of mount specs."
    assert_includes messages, "containerized_local_build sources require artifact."
    assert_includes messages, "services.demo.source.docker_socket must be a boolean."
  end

  def test_containerized_local_build_builds_expected_docker_run_command
    Dir.mktmpdir("blink-containerized-build") do |tmp|
      recorded = []
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace",
        "command" => "printf artifact > dist/artifact.txt",
        "artifact" => "dist/artifact.txt",
        "env" => { "TARGET_PLATFORM" => "linux/amd64" },
        "platform" => "linux/amd64",
        "docker_socket" => true,
        "_command_runner" => lambda do |env, command, chdir:|
          recorded << { env: env, command: command, chdir: chdir }
          FileUtils.mkdir_p(File.join(tmp, "dist"))
          File.write(File.join(tmp, "dist", "artifact.txt"), "artifact")
          ["", "", CommandStatus.new(true)]
        end
      )

      fetched_path = source.fetch

      assert_equal "artifact", File.read(fetched_path)
      assert_equal 1, recorded.size
      assert_equal({}, recorded.first[:env])
      assert_equal tmp, recorded.first[:chdir]
      command = recorded.first[:command]
      assert_equal ["docker", "run", "--rm"], command.first(3)
      assert_includes command, "--platform"
      assert_includes command, "linux/amd64"
      assert_includes command, "#{tmp}:/workspace"
      assert_includes command, "/var/run/docker.sock:/var/run/docker.sock"
      assert_includes command, "TARGET_PLATFORM=linux/amd64"
      assert_includes command, "BLINK_WORKSPACE_HOST=#{tmp}"
      assert_includes command, "BLINK_WORKSPACE_CONTAINER=/workspace"
      assert_includes command, "BLINK_HOST_WORKDIR=#{tmp}"
      assert_includes command, "BLINK_CONTAINER_WORKDIR=/workspace"
      assert_equal ["-w", "/workspace", "docker:cli", "sh", "-lc", "printf artifact > dist/artifact.txt"], command.last(6)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    end
  end

  def test_containerized_local_build_does_not_mount_docker_socket_unless_enabled
    Dir.mktmpdir("blink-containerized-build-no-socket") do |tmp|
      recorded = []
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace",
        "command" => "printf artifact > dist/artifact.txt",
        "artifact" => "dist/artifact.txt",
        "_command_runner" => lambda do |_env, command, chdir:|
          recorded << { command: command, chdir: chdir }
          FileUtils.mkdir_p(File.join(tmp, "dist"))
          File.write(File.join(tmp, "dist", "artifact.txt"), "artifact")
          ["", "", CommandStatus.new(true)]
        end
      )

      source.fetch

      refute_includes recorded.first[:command], "/var/run/docker.sock:/var/run/docker.sock"
    end
  end

  def test_containerized_local_build_resolves_artifact_relative_to_container_workdir
    Dir.mktmpdir("blink-containerized-build-workdir") do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "edge"))
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace/edge",
        "command" => "zig build",
        "artifact" => "zig-out/bin/bareclaw",
        "_command_runner" => lambda do |_env, _command, chdir:|
          assert_equal tmp, chdir
          FileUtils.mkdir_p(File.join(tmp, "edge", "zig-out", "bin"))
          File.write(File.join(tmp, "edge", "zig-out", "bin", "bareclaw"), "binary")
          ["", "", CommandStatus.new(true)]
        end
      )

      fetched_path = source.fetch

      assert_equal "binary", File.read(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    end
  end

  def test_containerized_local_build_fails_when_mount_path_is_missing
    Dir.mktmpdir("blink-containerized-build-missing-mount") do |tmp|
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => "./missing:/workspace",
        "workdir" => "/workspace",
        "command" => "docker build .",
        "artifact" => "dist/image.tar.gz"
      )

      error = assert_raises(Blink::Manifest::Error) { source.fetch }
      assert_includes error.message, "service 'fixture'"
      assert_includes error.message, "source 'containerized_local_build'"
      assert_includes error.message, "mount path does not exist"
    end
  end

  def test_containerized_local_build_fails_when_command_exits_non_zero
    Dir.mktmpdir("blink-containerized-build-fail") do |tmp|
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace",
        "command" => "exit 1",
        "artifact" => "dist/image.tar.gz",
        "_command_runner" => lambda do |_env, _command, chdir:|
          assert_equal tmp, chdir
          ["", "boom", CommandStatus.new(false)]
        end
      )

      error = assert_raises(RuntimeError) { source.fetch }
      assert_includes error.message, "service 'fixture'"
      assert_includes error.message, "source 'containerized_local_build'"
      assert_includes error.message, "container command exited non-zero"
    end
  end

  def test_containerized_local_build_fails_clearly_when_artifact_is_missing
    Dir.mktmpdir("blink-containerized-build-missing-artifact") do |tmp|
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace",
        "command" => "docker build .",
        "artifact" => "dist/image.tar.gz",
        "_command_runner" => lambda do |_env, _command, chdir:|
          assert_equal tmp, chdir
          ["", "", CommandStatus.new(true)]
        end
      )

      error = assert_raises(RuntimeError) { source.fetch }
      assert_includes error.message, "service 'fixture'"
      assert_includes error.message, "source 'containerized_local_build'"
      assert_includes error.message, File.join(tmp, "dist", "image.tar.gz")
    end
  end

  def test_containerized_local_build_can_pull_builder_image_before_running
    Dir.mktmpdir("blink-containerized-build-pull") do |tmp|
      recorded = []
      source = Blink::Sources.build(
        "type" => "containerized_local_build",
        "_manifest_dir" => tmp,
        "_service_name" => "fixture",
        "image" => "docker:cli",
        "mount" => ".:/workspace",
        "workdir" => "/workspace",
        "command" => "printf artifact > dist/artifact.txt",
        "artifact" => "dist/artifact.txt",
        "pull" => true,
        "platform" => "linux/amd64",
        "_command_runner" => lambda do |_env, command, chdir:|
          recorded << { command: command, chdir: chdir }
          if command[1] == "run"
            FileUtils.mkdir_p(File.join(tmp, "dist"))
            File.write(File.join(tmp, "dist", "artifact.txt"), "artifact")
          end
          ["", "", CommandStatus.new(true)]
        end
      )

      source.fetch

      assert_equal ["docker", "pull", "--platform", "linux/amd64", "docker:cli"], recorded[0][:command]
      assert_equal "docker", recorded[1][:command][0]
      assert_equal "run", recorded[1][:command][1]
    end
  end
end
