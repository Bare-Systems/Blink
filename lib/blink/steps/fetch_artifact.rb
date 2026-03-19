# frozen_string_literal: true

module Blink
  module Steps
    # Download the service artifact from its declared source.
    # Sets ctx.artifact_path for use by subsequent steps (install, etc.).
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
        source_cfg = source_cfg.merge(
          "_manifest_dir" => ctx.manifest.dir,
          "_cache_dir" => File.join(ctx.manifest.dir, ".blink", "artifacts"),
          "_service_name" => ctx.service_name
        )

        if dry_run?(ctx)
          source_ref = source_cfg["repo"] || source_cfg["command"] || source_cfg["artifact"]
          dry_log(ctx, "would fetch artifact from #{source_cfg["type"]}:#{source_ref}#{ctx.build_name ? " (build: #{ctx.build_name})" : ""}")
          ctx.artifact_path = "/tmp/dry-run-artifact"
          return
        end

        source = Sources.build(source_cfg)
        ctx.artifact_path = source.fetch(version: ctx.version || "latest", build_name: ctx.build_name)
        Output.success("Artifact: #{ctx.artifact_path}")
      end
    end

    Steps.register("fetch_artifact", FetchArtifact)
  end
end
