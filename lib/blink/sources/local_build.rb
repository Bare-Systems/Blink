# frozen_string_literal: true

require "open3"

module Blink
  module Sources
    class LocalBuild < Base
      # fetch(version:, build_name:)
      #
      # Supports two TOML shapes:
      #
      # Single build (legacy):
      #   [services.foo.source]
      #   type     = "local_build"
      #   command  = "go build ..."
      #   artifact = "bin/foo"
      #
      # Multiple named builds:
      #   [services.foo.source]
      #   type    = "local_build"
      #   default = "linux-amd64"
      #
      #   [services.foo.source.builds.linux-amd64]
      #   command  = "GOOS=linux GOARCH=amd64 go build ..."
      #   artifact = "bin/foo-linux-amd64"
      #
      #   [services.foo.source.builds.linux-arm64]
      #   command  = "GOOS=linux GOARCH=arm64 go build ..."
      #   artifact = "bin/foo-linux-arm64"
      #
      # When build_name is nil, the "default" key is used; if there is no default
      # and only one build is defined, that build is used automatically.
      def fetch(version: "latest", build_name: nil)
        manifest_dir = @config["_manifest_dir"] || Dir.pwd
        workdir      = File.expand_path(@config["workdir"] || ".", manifest_dir)
        raise "Local build workdir not found: #{workdir}" unless Dir.exist?(workdir)

        command, artifact_rel, env = resolve_build(build_name)
        label = build_name ? "  build: #{build_name}" : ""
        cache_key = digest_for(
          type: "local_build",
          build_name: build_name,
          command: command,
          artifact: artifact_rel,
          env: env,
          workdir_fingerprint: fingerprint_workdir(workdir, artifact_rel)
        )

        if cache_root
          fetch_with_cache(
            cache_key: cache_key,
            filename: File.basename(artifact_rel),
            metadata: {
              "source_type" => "local_build",
              "build_name" => build_name,
              "version" => version,
              "workdir" => workdir,
            }
          ) do |_destination|
            run_build(workdir, command, env, artifact_rel, version, label)
          end
        else
          artifact_path = run_build(workdir, command, env, artifact_rel, version, label)
          stage_file(artifact_path, filename: File.basename(artifact_rel))
        end
      end

      private

      def run_build(workdir, command, env, artifact_rel, version, label)
        Output.step("Building local artifact in #{workdir}...#{label}")
        Output.info("Version override '#{version}' ignored for local_build") unless version == "latest"

        out, err, status = Open3.capture3(env, command, chdir: workdir)
        print out unless out.empty?
        $stderr.print err unless err.empty?
        raise "Local build failed: #{command}" unless status.success?

        artifact_path = File.expand_path(artifact_rel, workdir)
        raise "Built artifact not found: #{artifact_path}" unless File.exist?(artifact_path)

        artifact_path
      end

      def resolve_build(build_name)
        source_env = stringify_env(@config["env"])
        builds = @config["builds"]

        if builds.nil? || builds.empty?
          # Legacy single-build shape
          command      = @config["command"]  || raise(Manifest::Error, "source.command is required for local_build")
          artifact_rel = @config["artifact"] || raise(Manifest::Error, "source.artifact is required for local_build")
          return [command, artifact_rel, source_env]
        end

        # Multi-build shape — resolve which build to use
        name = build_name ||
               @config["default"] ||
               (builds.size == 1 ? builds.keys.first : nil)

        unless name
          raise Manifest::Error,
            "Multiple builds defined (#{builds.keys.join(", ")}) but no default set and no --build flag given. " \
            "Set source.default or pass --build NAME."
        end

        cfg = builds[name] || raise(Manifest::Error,
          "Build '#{name}' not found. Available: #{builds.keys.join(", ")}")

        command      = cfg["command"]  || raise(Manifest::Error, "builds.#{name}.command is required")
        artifact_rel = cfg["artifact"] || raise(Manifest::Error, "builds.#{name}.artifact is required")

        [command, artifact_rel, source_env.merge(stringify_env(cfg["env"]))]
      end

      def stringify_env(value)
        return {} unless value.is_a?(Hash)

        value.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def fingerprint_workdir(workdir, artifact_rel)
        excluded = [File.expand_path(artifact_rel, workdir)]
        entries = Dir.glob(File.join(workdir, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
          next if File.directory?(path)
          next if path.include?("/.git/")
          next if path.include?("/.blink/")
          next if excluded.include?(path)

          stat = File.stat(path)
          {
            path: path.delete_prefix("#{workdir}/"),
            size: stat.size,
            mtime: stat.mtime.to_f
          }
        end

        digest_for(entries)
      end
    end
  end
end
