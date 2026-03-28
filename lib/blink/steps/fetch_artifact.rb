# frozen_string_literal: true

module Blink
  module Steps
    class FetchArtifact < Base
      step_definition(
        description: "Fetch a deployable artifact from the configured source.",
        config_section: "source",
        supported_target_types: %w[local ssh],
        rollback_strategy: "none",
        mutates_context: %w[artifact_path]
      )

      def execute(ctx)
        source_cfg = ctx.service_config["source"] ||
          raise(Manifest::Error, "No [services.#{ctx.service_name}.source] defined in manifest")

        internal = {
          "_manifest_dir" => ctx.manifest.service_dir(ctx.service_name),
          "_cache_dir"    => File.join(ctx.manifest.dir, ".blink", "artifacts"),
          "_service_name" => ctx.service_name,
        }
        source_cfg = source_cfg.merge(internal)

        # Multi-source dispatch: no top-level type, each named build has its own type
        if source_cfg["type"].nil?
          builds = source_cfg["builds"] || {}
          name = ctx.build_name ||
                 source_cfg["default"] ||
                 (builds.size == 1 ? builds.keys.first : nil)

          unless name
            raise Manifest::Error,
              "Multi-source: multiple builds defined (#{builds.keys.join(", ")}) " \
              "but no source.default and no --build flag given."
          end

          build_cfg = builds[name] || raise(Manifest::Error,
            "Build '#{name}' not found. Available: #{builds.keys.join(", ")}")

          source_cfg = build_cfg.merge(internal)
        end

        if dry_run?(ctx)
          source_ref = source_cfg["repo"] || source_cfg["image"] || source_cfg["command"] || source_cfg["artifact"]
          dry_log(ctx, "would fetch artifact from #{source_cfg["type"]}:#{source_ref}#{ctx.build_name ? " (build: #{ctx.build_name})" : ""}")
          ctx.artifact_path = "/tmp/dry-run-artifact"
          return { artifact_path: ctx.artifact_path }
        end

        source = Sources.build(source_cfg)
        ctx.artifact_path = source.fetch(version: ctx.version || "latest", build_name: ctx.build_name)
        Output.success("Artifact: #{ctx.artifact_path}")
        { artifact_path: ctx.artifact_path }
      end
    end

    Steps.register("fetch_artifact", FetchArtifact)
  end
end
