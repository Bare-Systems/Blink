# frozen_string_literal: true

module Blink
  module Steps
    # Run an arbitrary command on the target.
    # Config: { "command" => "..." }
    class Shell < Base
      def call(ctx)
        cmd = @config["command"] || raise(Manifest::Error, "shell step requires 'command'")
        cmd = ctx.resolve(cmd)

        if dry_run?(ctx)
          dry_log(ctx, "would run: #{cmd}")
          return
        end

        ctx.target.run(cmd)
      end
    end

    Steps.register("shell", Shell)
  end
end
