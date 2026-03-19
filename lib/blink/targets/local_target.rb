# frozen_string_literal: true

require "open3"
require "fileutils"

module Blink
  module Targets
    # Executes commands on the local machine.
    class LocalTarget < Base
      def run(cmd, abort_on_failure: true, tty: false)
        success = system(environment, cmd)
        raise SSHError, "Local command failed: #{cmd.lines.first.chomp}" if !success && abort_on_failure
        success
      end

      def capture(cmd)
        out, err, status = Open3.capture3(environment, cmd)
        raise SSHError, "Local capture failed: #{err.strip}" unless status.success?
        out.strip
      end

      def upload(local_path, remote_path)
        FileUtils.mkdir_p(File.dirname(remote_path))
        FileUtils.cp(local_path.to_s, remote_path)
      end

      def script(bash, abort_on_failure: true)
        out, err, status = Open3.capture3(environment, "bash", "-s", stdin_data: bash)
        print out unless out.empty?
        $stderr.print err unless err.empty?
        raise SSHError, "Local script failed" if !status.success? && abort_on_failure
        status.success?
      end

      def download(remote_path, local_path)
        FileUtils.cp(remote_path, local_path.to_s)
      end

      def reachable? = true

      def base
        config["base"] || Dir.home
      end

      def description = "local"
    end
  end
end
