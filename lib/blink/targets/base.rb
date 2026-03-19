# frozen_string_literal: true

module Blink
  module Targets
    class Base
      attr_reader :name, :config

      def initialize(name, config)
        @name   = name
        @config = config
      end

      # Run a command on the target. Raises on non-zero exit when
      # abort_on_failure is true (default).
      def run(cmd, abort_on_failure: true, tty: false)
        raise NotImplementedError
      end

      # Run a command and return its stdout as a string. Raises on failure.
      def capture(cmd)
        raise NotImplementedError
      end

      # Upload a local file to the target.
      def upload(local_path, remote_path)
        raise NotImplementedError
      end

      # Pipe a bash script to the target and execute it.
      def script(bash, abort_on_failure: true)
        raise NotImplementedError
      end

      # Download a remote file to a local path.
      def download(remote_path, local_path)
        raise NotImplementedError
      end

      # Check whether the target is reachable.
      def reachable?
        raise NotImplementedError
      end

      def description
        "#{config["type"]}:#{name}"
      end

      # Base directory on the target where services are installed.
      def base
        config["base"] || "/tmp"
      end
    end
  end
end
