# frozen_string_literal: true

module Blink
  module Commands
    # Open an interactive SSH session to the default (or specified) target.
    class SshCmd
      def initialize(argv)
        @argv = argv.dup

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        manifest    = Manifest.load
        target_name = @target_name || manifest.default_target_name
        target      = manifest.target!(target_name)

        unless target.is_a?(Targets::SSHTarget)
          Output.fatal("Target '#{target_name}' is not an SSH target")
        end

        exec("ssh", *Targets::SSHTarget::SSH_OPTS, target.ssh_host)
      rescue Manifest::Error => e
        Output.fatal(e.message)
      end
    end
  end
end
