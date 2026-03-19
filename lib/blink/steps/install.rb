# frozen_string_literal: true

module Blink
  module Steps
    # Upload and install the downloaded artifact onto the target.
    # Requires ctx.artifact_path (set by fetch_artifact).
    # Config: { "dest" => "relative/path/to/binary" }
    class Install < Base
      def call(ctx)
        raise "No artifact_path in context — did fetch_artifact run?" unless ctx.artifact_path

        install_cfg = ctx.section("install").merge(@config)
        dest_rel    = install_cfg["dest"] ||
          raise(Manifest::Error, "No install.dest configured for '#{ctx.service_name}'")

        dest = File.join(ctx.target.base, dest_rel)

        if dry_run?(ctx)
          dry_log(ctx, "would install #{ctx.artifact_path} → #{dest}")
          return
        end

        ctx.target.run("mkdir -p #{File.dirname(dest)}")
        ctx.target.upload(ctx.artifact_path, dest)
        ctx.target.run("chmod +x #{dest}")
        Output.info("Installed: #{dest}")
      end
    end

    Steps.register("install", Install)
  end
end
