# frozen_string_literal: true

module Blink
  module Steps
    # Back up the currently-installed binary before overwriting it.
    # Sets ctx.backup_path; the rollback step restores from there.
    # Skips silently if no install.dest is configured.
    class Backup < Base
      def call(ctx)
        install_cfg = ctx.section("install").merge(@config)
        dest_rel    = install_cfg["dest"]

        unless dest_rel
          Output.info("No install.dest; skipping backup")
          return
        end

        dest   = File.join(ctx.target.base, dest_rel)
        backup = "#{dest}.bak"

        if dry_run?(ctx)
          dry_log(ctx, "would backup #{dest} → #{backup}")
          ctx.backup_path = backup
          return
        end

        exists = ctx.target.capture("test -f #{dest} && echo yes || echo no") == "yes"
        if exists
          ctx.target.run("cp #{dest} #{backup}")
          ctx.backup_path = backup
          Output.info("Backed up: #{backup}")
        else
          Output.info("No existing binary at #{dest}; skipping backup")
        end
      end
    end

    Steps.register("backup", Backup)
  end
end
