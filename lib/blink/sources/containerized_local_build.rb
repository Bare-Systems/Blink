# frozen_string_literal: true

module Blink
  module Sources
    class ContainerizedLocalBuild < Base
      def fetch(version: "latest", build_name: nil)
        _ = build_name
        manifest_dir = @config["_manifest_dir"] || Dir.pwd
        image = required_config_string!("image")
        container_workdir = required_config_string!("workdir")
        command = required_config_string!("command")
        artifact_decl = required_config_string!("artifact")
        env = stringify_env(@config["env"])
        mounts = resolve_mounts(manifest_dir)
        env_files = resolve_env_files(manifest_dir)
        host_workdir = resolve_host_workdir(container_workdir, mounts)
        artifact_path = resolve_artifact_path(artifact_decl, host_workdir)
        runtime_env = container_runtime_env(mounts: mounts, host_workdir: host_workdir, container_workdir: container_workdir)

        cache_key = digest_for(
          type: "containerized_local_build",
          image: image,
          workdir: container_workdir,
          command: command,
          artifact: artifact_decl,
          mounts: mounts.map { |mount| mount.slice(:container_path, :host_path, :mode) },
          env: env,
          env_files: env_files,
          platform: @config["platform"],
          docker_socket: @config["docker_socket"] == true,
          pull: @config["pull"] == true,
          entrypoint: @config["entrypoint"],
          user: @config["user"],
          host_fingerprint: fingerprint_paths(mounts.map { |mount| mount[:host_path] } + env_files, excluded: [artifact_path])
        )

        if cache_root
          fetch_with_cache(
            cache_key: cache_key,
            filename: File.basename(artifact_path),
            metadata: {
              "source_type" => "containerized_local_build",
              "version" => version,
              "image" => image,
              "workdir" => container_workdir,
            }
          ) do |_destination|
            run_build(
              manifest_dir: manifest_dir,
              image: image,
              mounts: mounts,
              env_files: env_files,
              container_workdir: container_workdir,
              command: command,
              env: env.merge(runtime_env),
              artifact_path: artifact_path,
              version: version
            )
          end
        else
          built_path = run_build(
            manifest_dir: manifest_dir,
            image: image,
            mounts: mounts,
            env_files: env_files,
            container_workdir: container_workdir,
            command: command,
            env: env.merge(runtime_env),
            artifact_path: artifact_path,
            version: version
          )
          stage_file(built_path, filename: File.basename(artifact_path))
        end
      end

      private

      def run_build(manifest_dir:, image:, mounts:, env_files:, container_workdir:, command:, env:, artifact_path:, version:)
        Output.step("Building local artifact in container #{image}...")
        Output.info("Version override '#{version}' ignored for containerized_local_build") unless version == "latest"

        pull_image!(image, manifest_dir) if @config["pull"] == true

        docker_command = build_docker_command(
          image: image,
          mounts: mounts,
          env_files: env_files,
          container_workdir: container_workdir,
          command: command,
          env: env
        )
        execute_command!(
          {},
          docker_command,
          chdir: manifest_dir,
          failure_message: source_error_message("container command exited non-zero: #{docker_command.join(' ')}")
        )

        raise_source_error("artifact not produced at #{artifact_path}") unless File.exist?(artifact_path)

        artifact_path
      end

      def pull_image!(image, manifest_dir)
        pull_command = ["docker", "pull"]
        pull_command += ["--platform", @config["platform"]] if @config["platform"].is_a?(String) && !@config["platform"].strip.empty?
        pull_command << image

        execute_command!(
          {},
          pull_command,
          chdir: manifest_dir,
          failure_message: source_error_message("container image pull failed: #{pull_command.join(' ')}")
        )
      end

      def build_docker_command(image:, mounts:, env_files:, container_workdir:, command:, env:)
        docker_command = ["docker", "run", "--rm"]
        docker_command += ["--platform", @config["platform"]] if @config["platform"].is_a?(String) && !@config["platform"].strip.empty?
        docker_command += ["--entrypoint", @config["entrypoint"]] if @config["entrypoint"].is_a?(String) && !@config["entrypoint"].strip.empty?
        docker_command += ["--user", @config["user"]] if @config["user"].is_a?(String) && !@config["user"].strip.empty?
        mounts.each { |mount| docker_command += ["-v", mount[:bind_spec]] }
        docker_command += ["-v", "/var/run/docker.sock:/var/run/docker.sock"] if @config["docker_socket"] == true
        env_files.each { |path| docker_command += ["--env-file", path] }
        env.each { |key, value| docker_command += ["-e", "#{key}=#{value}"] }
        docker_command += ["-w", container_workdir, image, "sh", "-lc", command]
        docker_command
      end

      def container_runtime_env(mounts:, host_workdir:, container_workdir:)
        env = {
          "BLINK_HOST_WORKDIR" => host_workdir,
          "BLINK_CONTAINER_WORKDIR" => container_workdir,
        }

        primary_mount = mounts.first
        if primary_mount
          env["BLINK_WORKSPACE_HOST"] = primary_mount[:host_path]
          env["BLINK_WORKSPACE_CONTAINER"] = primary_mount[:container_path]
        end

        mounts.each_with_index do |mount, index|
          env["BLINK_MOUNT_#{index}_HOST"] = mount[:host_path]
          env["BLINK_MOUNT_#{index}_CONTAINER"] = mount[:container_path]
        end

        env
      end

      def resolve_mounts(manifest_dir)
        raw_mounts = @config["mount"]
        raise_source_error("field mount is required", Manifest::Error) if raw_mounts.nil?

        mounts = raw_mounts.is_a?(Array) ? raw_mounts : [raw_mounts]
        if mounts.empty? || !mounts.all? { |spec| spec.is_a?(String) && !spec.strip.empty? }
          raise_source_error("field mount must be a string or array of strings", Manifest::Error)
        end

        mounts.map.with_index do |spec, index|
          host_ref, container_path, mode = spec.split(":", 3)
          if host_ref.to_s.strip.empty? || container_path.to_s.strip.empty?
            raise_source_error("field mount[#{index}] must be HOST_PATH:CONTAINER_PATH[:MODE]", Manifest::Error)
          end

          host_path = File.expand_path(host_ref, manifest_dir)
          raise_source_error("mount path does not exist: #{host_path}", Manifest::Error) unless File.exist?(host_path)

          bind_spec = [host_path, container_path]
          bind_spec << mode if mode && !mode.empty?
          {
            host_path: host_path,
            container_path: container_path,
            mode: mode,
            bind_spec: bind_spec.join(":")
          }
        end
      end

      def resolve_env_files(manifest_dir)
        raw = @config["env_file"]
        return [] if raw.nil?

        files = raw.is_a?(Array) ? raw : [raw]
        unless files.all? { |path| path.is_a?(String) && !path.strip.empty? }
          raise_source_error("field env_file must be a string or array of strings", Manifest::Error)
        end

        files.map do |path|
          absolute = File.expand_path(path, manifest_dir)
          raise_source_error("env_file not found: #{absolute}", Manifest::Error) unless File.exist?(absolute)

          absolute
        end
      end

      def resolve_host_workdir(container_workdir, mounts)
        matched_mount = mounts
          .select { |mount| container_workdir == mount[:container_path] || container_workdir.start_with?("#{mount[:container_path]}/") }
          .max_by { |mount| mount[:container_path].length }

        raise_source_error("workdir #{container_workdir.inspect} is not covered by any mount", Manifest::Error) unless matched_mount

        suffix = container_workdir.delete_prefix(matched_mount[:container_path]).sub(%r{\A/}, "")
        host_workdir = suffix.empty? ? matched_mount[:host_path] : File.expand_path(suffix, matched_mount[:host_path])
        raise_source_error("workdir resolves to missing host path #{host_workdir}", Manifest::Error) unless Dir.exist?(host_workdir)

        host_workdir
      end

      def resolve_artifact_path(artifact_decl, host_workdir)
        return artifact_decl if artifact_decl.start_with?("/")

        File.expand_path(artifact_decl, host_workdir)
      end

      def required_config_string!(key)
        value = @config[key]
        return value if value.is_a?(String) && !value.strip.empty?

        raise_source_error("field #{key} is required", Manifest::Error)
      end
    end

    register("containerized_local_build", ContainerizedLocalBuild)
  end
end
