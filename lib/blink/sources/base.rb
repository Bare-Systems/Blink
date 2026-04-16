# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require "open3"
require "securerandom"
require "shellwords"
require "tmpdir"
require "time"

module Blink
  module Sources
    # Registry of source type name → class. Plugins and built-in sources alike
    # call `Blink::Sources.register("my_type", MySource)` to make their type
    # available to the manifest schema and `Sources.build`.
    REGISTRY = {}

    # Register a source class under the given manifest type name.
    def self.register(type, klass)
      REGISTRY[type.to_s] = klass
    end

    # List of registered source type names (used by Schema and diagnostics).
    def self.known_types
      REGISTRY.keys.sort
    end

    class Base
      # Concerns extracted in Sprint F. Kept as separate modules so each
      # surface (caching, integrity/signature verification) can be reasoned
      # about and tested on its own, and so future plugin source types can
      # opt out of either concern if they don't need it.
      include Cache
      include Verification

      def initialize(config)
        @config = config
      end

      # Fetch the artifact and return the local filesystem path to it.
      # version:    "latest" or a specific tag/version string.
      # build_name: named build to select (only used by local_build multi-build sources).
      def fetch(version: "latest", build_name: nil)
        raise NotImplementedError
      end

      protected

      def stage_file(source_path, filename: File.basename(source_path))
        dest = temp_artifact_path(filename)
        FileUtils.cp(source_path, dest)
        dest
      end

      def temp_artifact_path(filename)
        File.join(Dir.tmpdir, "blink-artifact-#{SecureRandom.hex(6)}-#{sanitize_filename(filename)}")
      end

      def stage_content(content, filename:)
        path = temp_artifact_path(filename)
        File.binwrite(path, content)
        path
      end

      def execute_command!(env, command, chdir:, failure_message:)
        out, err, status = capture_command(env, command, chdir: chdir)
        print out unless out.to_s.empty?
        $stderr.print err unless err.to_s.empty?
        raise failure_message unless status.success?

        [out, err, status]
      end

      def capture_command(env, command, chdir:)
        runner = @config["_command_runner"]
        normalized_env = stringify_env(env)
        return runner.call(normalized_env, command, chdir: chdir) if runner.respond_to?(:call)

        if command.is_a?(Array)
          Open3.capture3(normalized_env, *command, chdir: chdir)
        else
          Open3.capture3(normalized_env, command, chdir: chdir)
        end
      end

      def sanitize_filename(filename)
        name = filename.to_s.strip
        return "artifact" if name.empty?

        name.gsub(/[^A-Za-z0-9.\-_]+/, "-")
      end

      def digest_for(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end

      def fingerprint_paths(paths, excluded: [])
        excluded_paths = Array(excluded).compact.map { |path| File.expand_path(path) }.uniq

        entries = Array(paths).compact.map { |path| File.expand_path(path) }.uniq.sort.flat_map do |root|
          next [] unless File.exist?(root)

          if File.directory?(root)
            Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
              next if File.directory?(path)
              next if path.include?("/.git/")
              next if path.include?("/.blink/")
              next if excluded_paths.include?(path)

              stat = File.stat(path)
              {
                root: root,
                path: path.delete_prefix("#{root}/"),
                size: stat.size,
                mtime: stat.mtime.to_f
              }
            end
          else
            next [] if excluded_paths.include?(root)

            stat = File.stat(root)
            [{
              root: File.dirname(root),
              path: File.basename(root),
              size: stat.size,
              mtime: stat.mtime.to_f
            }]
          end
        end

        digest_for(entries)
      end

      def stringify_env(value)
        return {} unless value.is_a?(Hash)

        value.transform_keys(&:to_s).transform_values do |entry|
          Blink::EnvRefs.expand(entry.to_s, context: "service '#{@config["_service_name"] || "unknown"}' source env")
        end
      end

      def raise_source_error(message, error_class = RuntimeError)
        raise error_class, source_error_message(message)
      end

      def source_error_message(message)
        "service '#{@config["_service_name"] || "unknown"}' source '#{@config["type"] || "unknown"}': #{message}"
      end

    end

    # Build a source from a config hash (from the manifest). Looks up the
    # source class in the registry populated by `Sources.register`.
    def self.build(config)
      type = config["type"]
      klass = REGISTRY[type.to_s]
      unless klass
        supported = REGISTRY.keys.sort.join(", ")
        raise Manifest::Error, "Unknown source type '#{type}'. Supported: #{supported}"
      end
      klass.new(config)
    end
  end
end
