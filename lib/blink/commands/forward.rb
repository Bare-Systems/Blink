# frozen_string_literal: true

module Blink
  module Commands
    # Establish an SSH port-forward tunnel for a service.
    #
    # Reads [services.<name>.forward] from blink.toml:
    #   local_port  - port to bind on localhost (required)
    #   remote_port - port to forward to on the target (required)
    #
    # Usage:
    #   blink forward <service>
    #   blink forward <service> --local-port 4000   # override local port
    #   blink forward <service> --target staging
    #
    # If no [forward] block is configured the command exits cleanly with a notice.
    class Forward
      def initialize(argv)
        @argv = argv.dup

        target_idx = @argv.index("--target")
        @target_override = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end

        local_idx = @argv.index("--local-port")
        @local_port_override = if local_idx
          @argv.delete_at(local_idx)
          @argv.delete_at(local_idx)&.to_i
        end

        @service_name = @argv.shift
      end

      def run
        manifest     = Manifest.load
        service_name = @service_name || manifest.default_service_name

        unless service_name
          Output.fatal("Usage: blink forward <service>")
        end

        svc          = manifest.service!(service_name)
        forward_cfg  = svc["forward"]

        unless forward_cfg.is_a?(Hash) && forward_cfg["local_port"] && forward_cfg["remote_port"]
          Output.info("No [services.#{service_name}.forward] block configured — nothing to do.")
          return
        end

        local_port  = @local_port_override || forward_cfg["local_port"].to_i
        remote_port = forward_cfg["remote_port"].to_i

        target_name = @target_override || svc.dig("deploy", "target") || manifest.default_target_name
        target      = manifest.target!(target_name)

        unless target.is_a?(Targets::SSHTarget)
          Output.fatal("Target '#{target_name}' is not an SSH target — port forwarding requires SSH.")
        end

        Output.header("Port Forward — #{service_name}")
        Output.step("Tunnelling localhost:#{local_port} → #{target.ssh_host}:#{remote_port}")
        Output.info("Press Ctrl+C to stop the tunnel.")
        puts

        # Build the SSH command: -N = no remote command, -L = local forward
        ssh_args = [
          *Targets::SSHTarget::SSH_OPTS,
          "-N",
          "-L", "#{local_port}:127.0.0.1:#{remote_port}",
          target.ssh_host
        ]

        pid = spawn("ssh", *ssh_args)

        Signal.trap("INT")  { Process.kill("TERM", pid) rescue nil }
        Signal.trap("TERM") { Process.kill("TERM", pid) rescue nil }

        Output.success("Tunnel active: http://localhost:#{local_port}")

        _, status = Process.wait2(pid)

        puts
        if status.success? || status.termsig
          Output.info("Tunnel closed.")
        else
          Output.error("Tunnel exited with status #{status.exitstatus}")
          exit 1
        end
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue TargetError => e
        Output.fatal("SSH error: #{e.message}")
      end
    end
  end
end
