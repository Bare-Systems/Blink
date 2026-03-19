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

        command, artifact_rel = resolve_build(build_name)

        label = build_name ? "  build: #{build_name}" : ""
        Output.step("Building local artifact in #{workdir}...#{label}")
        Output.info("Version override '#{version}' ignored for local_build") unless version == "latest"

        out, err, status = Open3.capture3(command, chdir: workdir)
        print out unless out.empty?
        $stderr.print err unless err.empty?
        raise "Local build failed: #{command}" unless status.success?

        artifact = File.expand_path(artifact_rel, workdir)
        raise "Built artifact not found: #{artifact}" unless File.exist?(artifact)

        artifact
      end

      private

      def resolve_build(build_name)
        builds = @config["builds"]

        if builds.nil? || builds.empty?
          # Legacy single-build shape
          command      = @config["command"]  || raise(Manifest::Error, "source.command is required for local_build")
          artifact_rel = @config["artifact"] || raise(Manifest::Error, "source.artifact is required for local_build")
          return [command, artifact_rel]
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

        [command, artifact_rel]
      end
    end
  end
end
