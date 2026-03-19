# frozen_string_literal: true

module Blink
  module Steps
    # Start (or restart) the service. Uses service_config["start"]["command"].
    class Start < Base
      def call(ctx)
        cfg = ctx.section("start").merge(@config)
        cmd = cfg["command"] || raise(Manifest::Error, "No start.command configured for '#{ctx.service_name}'")
        cmd = ctx.resolve(cmd)

        if dry_run?(ctx)
          dry_log(ctx, "would start: #{cmd}")
          return
        end

        ctx.target.run(cmd)
      end
    end

    Steps.register("start", Start)
  end
end
