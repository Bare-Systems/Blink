# frozen_string_literal: true

require "open3"

module Blink
  module Targets
    class SSHTarget < Base
      SSH_OPTS = %w[
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=20
        -o ConnectTimeout=10
      ].freeze

      def host = config["host"] || raise(Manifest::Error, "SSH target '#{name}' missing 'host'")
      def user = config["user"]

      def ssh_host
        user ? "#{user}@#{host}" : host
      end

      def base
        config["base"] || (user ? "/home/#{user}" : "/tmp")
      end

      # Run a command on the remote host, streaming output.
      # tty: true allocates a pseudo-terminal for sudo-interactive commands.
      def run(cmd, abort_on_failure: true, tty: false)
        opts    = tty ? [*SSH_OPTS, "-t"] : SSH_OPTS
        success = system("ssh", *opts, ssh_host, cmd)
        raise SSHError, "Remote command failed: #{cmd.lines.first.chomp}" if !success && abort_on_failure
        success
      end

      # Run a command and return stdout. Raises SSHError on non-zero exit.
      def capture(cmd)
        out, err, status = Open3.capture3("ssh", *SSH_OPTS, ssh_host, cmd)
        raise SSHError, "Remote capture failed: #{err.strip}" unless status.success?
        out.strip
      end

      # Pipe a bash script via stdin to the remote host.
      def script(bash, abort_on_failure: true)
        out, err, status = Open3.capture3("ssh", *SSH_OPTS, ssh_host, "bash", "-s", stdin_data: bash)
        print out unless out.empty?
        $stderr.print err unless err.empty?
        raise SSHError, "Remote script failed" if !status.success? && abort_on_failure
        status.success?
      end

      def upload(local_path, remote_path)
        success = system("scp", *SSH_OPTS, local_path.to_s, "#{ssh_host}:#{remote_path}")
        raise SSHError, "scp upload failed: #{local_path} → #{remote_path}" unless success
      end

      def download(remote_path, local_path)
        success = system("scp", *SSH_OPTS, "#{ssh_host}:#{remote_path}", local_path.to_s)
        raise SSHError, "scp download failed: #{remote_path} → #{local_path}" unless success
      end

      def reachable?
        system("ssh", *SSH_OPTS, "-o", "BatchMode=yes", ssh_host, "true",
               out: File::NULL, err: File::NULL)
      end

      def description
        "ssh://#{ssh_host}"
      end
    end
  end
end
