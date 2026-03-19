# frozen_string_literal: true

require "shellwords"

module Blink
  module Steps
    # Provision the remote host for a service deployment.
    #
    # Replaces ad-hoc provision shell scripts for the three most common
    # setup needs — no external script file required:
    #
    #   [services.polar.provision]
    #   dirs   = ["{{runtime_dir}}/staging", "{{runtime_dir}}/data"]
    #   script = "touch {{runtime_dir}}/polar.db 2>/dev/null || true"
    #
    #   [services.polar.provision.env_file]
    #   path = "{{runtime_dir}}/polar.env"
    #
    #   [services.polar.provision.env_file.seed]
    #   POLAR_SERVICE_TOKEN = "replace-me"
    #   POLAR_STATION_ID    = "homelab"
    #
    # Behaviour:
    #   dirs      — created with `mkdir -p` on the remote
    #   env_file  — seeded with defaults only if the file does not already
    #               exist on the remote (safe to re-deploy, never overwrites)
    #   script    — inline shell fragment run after dirs and env_file
    class Provision < Base
      def call(ctx)
        cfg      = ctx.section("provision").merge(@config)
        dirs     = Array(cfg["dirs"] || []).map { |d| ctx.resolve(d) }
        env_file = cfg["env_file"]
        script   = cfg["script"]

        if dry_run?(ctx)
          dry_log(ctx, "would create dirs: #{dirs.join(", ")}") unless dirs.empty?
          if env_file
            dry_log(ctx, "would seed env_file (if new): #{ctx.resolve(env_file["path"] || "")}")
          end
          dry_log(ctx, "would run provision script (inline)") if script
          return
        end

        # 1. Create directories
        unless dirs.empty?
          escaped = dirs.map { |d| Shellwords.escape(d) }.join(" ")
          ctx.target.run("mkdir -p #{escaped}")
          Output.info("Provisioned dirs: #{dirs.join(", ")}")
        end

        # 2. Seed env file — only if it does not yet exist on the remote.
        #    Values are written as KEY=value lines. After the first deploy the
        #    operator fills in real secrets; subsequent deploys leave it alone.
        if env_file
          path = ctx.resolve(env_file["path"] || raise(Manifest::Error, "provision.env_file.path is required"))
          seed = env_file["seed"] || {}
          unless seed.empty?
            lines   = seed.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
            escaped_path    = Shellwords.escape(path)
            escaped_content = Shellwords.escape(lines)
            # Use `test -f` so we never clobber a file that already has real secrets.
            ctx.target.run("test -f #{escaped_path} || printf #{escaped_content} > #{escaped_path}")
            Output.info("Env file seeded (if new): #{path}")
          end
        end

        # 3. Run inline shell fragment
        if script
          ctx.target.script(ctx.resolve(script))
          Output.info("Provision script executed")
        end
      end
    end

    Steps.register("provision", Provision)
  end
end
