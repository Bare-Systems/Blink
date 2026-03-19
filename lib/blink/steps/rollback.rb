# frozen_string_literal: true

module Blink
  module Steps
    # Restore the service binary from the backup created by the backup step.
    # Requires ctx.backup_path to have been set.
    class Rollback < Base
      def call(ctx)
        unless ctx.backup_path
          Output.warn("No backup_path in context — cannot rollback")
          return
        end

        install_cfg = ctx.section("install").merge(@config)
        dest_rel    = install_cfg["dest"]

        unless dest_rel
          Output.warn("No install.dest — cannot rollback")
          return
        end

        dest = File.join(ctx.target.base, dest_rel)

        if dry_run?(ctx)
          dry_log(ctx, "would restore #{ctx.backup_path} → #{dest}")
          return
        end

        ctx.target.run("cp #{ctx.backup_path} #{dest}")
        ctx.target.run("chmod +x #{dest}")
        Output.info("Restored: #{dest}")
      end
    end

    Steps.register("rollback", Rollback)
  end
end
