# frozen_string_literal: true

module Blink
  module Steps
    # Stop the running service. Uses service_config["stop"]["command"].
    # Failures are non-fatal by default (service may already be stopped).
    class Stop < Base
      def call(ctx)
        cfg = ctx.section("stop").merge(@config)
        cmd = cfg["command"] || raise(Manifest::Error, "No stop.command configured for '#{ctx.service_name}'")
        cmd = ctx.resolve(cmd)

        if dry_run?(ctx)
          dry_log(ctx, "would stop: #{cmd}")
          return
        end

        ctx.target.run(cmd, abort_on_failure: false)
      end
    end

    Steps.register("stop", Stop)
  end
end
