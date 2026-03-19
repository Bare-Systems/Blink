# frozen_string_literal: true

module Blink
  module Sources
    class Base
      def initialize(config)
        @config = config
      end

      # Fetch the artifact and return the local filesystem path to it.
      # version:    "latest" or a specific tag/version string.
      # build_name: named build to select (only used by local_build multi-build sources).
      def fetch(version: "latest", build_name: nil)
        raise NotImplementedError
      end
    end

    # Build a source from a config hash (from the manifest).
    def self.build(config)
      case config["type"]
      when "github_release" then GithubRelease.new(config)
      when "local_build"    then LocalBuild.new(config)
      else raise Manifest::Error, "Unknown source type '#{config["type"]}'. Supported: github_release, local_build"
      end
    end
  end
end
