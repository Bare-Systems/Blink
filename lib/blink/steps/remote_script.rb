# frozen_string_literal: true

module Blink
  module Steps
    # Execute a shell script on the target over SSH.
    #
    # Supports two forms — use exactly one:
    #
    #   path:   relative path to a local .sh file
    #   inline: multi-line shell script written directly in the TOML
    #
    # Example (file reference — existing pattern):
    #   [services.bearclaw.remote_script]
    #   path = "deploy/blink/provision_remote.sh"
    #
    # Example (inline — no external file needed):
    #   [services.polar.remote_script]
    #   inline = """
    #   set -e
    #   mkdir -p {{runtime_dir}}/staging
    #   docker network create baresystems 2>/dev/null || true
    #   """
    class RemoteScript < Base
      def call(ctx)
        cfg    = ctx.section("remote_script").merge(@config)
        script = resolve_script(cfg, ctx)
        source = cfg["path"] ? File.basename(cfg["path"]) : "(inline)"

        if dry_run?(ctx)
          dry_log(ctx, "would run remote script #{source}")
          return
        end

        ctx.target.script(ctx.resolve(script))
        Output.info("Executed remote script: #{source}")
      end

      private

      def resolve_script(cfg, ctx)
        if cfg["path"]
          script_abs = File.expand_path(cfg["path"], ctx.manifest.dir)
          raise "Script file not found: #{script_abs}" unless File.exist?(script_abs)
          File.read(script_abs)
        elsif cfg["inline"]
          cfg["inline"]
        else
          raise Manifest::Error,
            "remote_script requires 'path' or 'inline' for '#{ctx.service_name}'"
        end
      end
    end

    Steps.register("remote_script", RemoteScript)
  end
end
