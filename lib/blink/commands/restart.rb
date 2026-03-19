# frozen_string_literal: true

module Blink
  module Commands
    class Restart
      def initialize(argv)
        @argv    = argv.dup
        @service = @argv.reject { _1.start_with?("-") }.first

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        if @service.nil?
          Output.fatal("Usage: blink restart <service> [--target NAME]")
        end

        manifest = Manifest.load
        svc      = manifest.service!(@service)

        target_name = @target_name || svc.dig("deploy", "target") || manifest.default_target_name
        target      = manifest.target!(target_name)

        Output.header("Restart: #{@service}")

        # Try stop then start using configured commands
        stop_cmd  = svc.dig("stop", "command")
        start_cmd = svc.dig("start", "command")

        if stop_cmd && start_cmd
          Output.step("stop")
          target.run(stop_cmd, abort_on_failure: false)
          Output.step("start")
          target.run(start_cmd)
        elsif (restart_cmd = svc.dig("restart", "command"))
          Output.step("restart")
          target.run(restart_cmd)
        else
          Output.fatal("No stop/start or restart commands configured for '#{@service}'")
        end

        Output.success("#{@service} restarted")
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue SSHError => e
        Output.fatal("SSH error: #{e.message}")
      end
    end
  end
end
