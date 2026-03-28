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

      protected

      def stage_file(source_path, filename: File.basename(source_path))
        dest = temp_artifact_path(filename)
        FileUtils.cp(source_path, dest)
        dest
      end

      def fetch_with_cache(cache_key:, filename:, metadata: {}, reuse: true, validate: nil)
        cached_path = cached_artifact_path(cache_key, filename)
        existing_metadata = cached_path && File.exist?(cached_path) ? read_cache_metadata(cached_path) : nil
        if cached_path && File.exist?(cached_path) && cache_reusable?(cached_path, reuse, existing_metadata)
          validation_metadata = normalize_metadata_result(validate&.call(cached_path, existing_metadata))
          Output.info("Reusing cached artifact: #{cached_path}")
          write_cache_metadata(
            cached_path,
            metadata_payload(existing_metadata, metadata, validation_metadata, "cache_key" => cache_key, "reused_at" => Time.now.utc.iso8601)
          )
          return cached_path
        end

        cached_exists = cached_path && File.exist?(cached_path)
        destination = cached_path || temp_artifact_path(filename)
        fetched_path, dynamic_metadata = normalize_fetch_result(yield(destination, existing_metadata))
        validation_metadata = normalize_metadata_result(validate&.call(fetched_path, existing_metadata))
        return fetched_path unless cached_path

        if File.expand_path(fetched_path) != File.expand_path(cached_path)
          FileUtils.mkdir_p(File.dirname(cached_path))
          FileUtils.cp(fetched_path, cached_path)
        end

        timestamp = Time.now.utc.iso8601
        payload = metadata_payload(existing_metadata, metadata, dynamic_metadata, validation_metadata, "cache_key" => cache_key)
        payload["created_at"] ||= timestamp
        payload["updated_at"] = timestamp if cached_exists
        write_cache_metadata(cached_path, payload)
        cached_path
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

        value.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def raise_source_error(message, error_class = RuntimeError)
        raise error_class, source_error_message(message)
      end

      def source_error_message(message)
        "service '#{@config["_service_name"] || "unknown"}' source '#{@config["type"] || "unknown"}': #{message}"
      end

      def cache_root
        return nil unless cache_enabled?

        base = @config["_cache_dir"] || (@config["_manifest_dir"] && File.join(@config["_manifest_dir"], ".blink", "artifacts"))
        return nil unless base

        service = sanitize_filename(@config["_service_name"] || "shared")
        File.join(base, service)
      end

      def cached_artifact_path(cache_key, filename)
        return nil unless cache_key && cache_root

        FileUtils.mkdir_p(cache_root)
        File.join(cache_root, "#{cache_key}-#{sanitize_filename(filename)}")
      end

      def cache_metadata_path(cached_path)
        "#{cached_path}.json"
      end

      def write_cache_metadata(cached_path, metadata)
        File.write(cache_metadata_path(cached_path), JSON.pretty_generate(metadata) + "\n")
      rescue
        nil
      end

      def read_cache_metadata(cached_path)
        JSON.parse(File.read(cache_metadata_path(cached_path), encoding: "utf-8"))
      rescue
        nil
      end

      def cache_config
        @config["cache"].is_a?(Hash) ? @config["cache"] : {}
      end

      def cache_enabled?
        cache_config.fetch("enabled", true) != false
      end

      def cache_ttl_seconds
        ttl = cache_config["ttl_seconds"]
        ttl.is_a?(Integer) && ttl >= 0 ? ttl : nil
      end

      def cache_reusable?(cached_path, reuse, metadata = nil)
        case reuse
        when Proc
          reuse.arity >= 2 ? reuse.call(cached_path, metadata) : reuse.call(cached_path)
        else
          !!reuse
        end
      end

      def normalize_fetch_result(result)
        case result
        when Hash
          [result.fetch(:path), result[:metadata]]
        else
          [result, nil]
        end
      end

      def metadata_payload(*parts)
        parts.compact.reduce({}) do |merged, part|
          next merged unless part.is_a?(Hash)

          merged.merge(part)
        end
      end

      def normalize_metadata_result(result)
        result.is_a?(Hash) ? result : nil
      end

      def verify_sha256!(path, expected_sha256, provenance: nil)
        return nil if expected_sha256.nil? || expected_sha256.strip.empty?

        expected = expected_sha256.strip.downcase
        actual = Digest::SHA256.file(path).hexdigest
        raise "Checksum mismatch for #{path}: expected #{expected}, got #{actual}" unless actual == expected

        {
          "integrity" => {
            "algorithm" => "sha256",
            "expected" => expected,
            "actual" => actual,
            "verified" => true,
            "verified_at" => Time.now.utc.iso8601
          }.merge(normalize_metadata_result(provenance) || {})
        }
      end

      def verify_signature!(path, verify_command:, signature_path:, public_key_path: nil, provenance: nil)
        return nil if verify_command.to_s.strip.empty? || signature_path.to_s.strip.empty?

        rendered = render_verify_command(
          verify_command,
          artifact: path,
          signature: signature_path,
          public_key: public_key_path
        )
        stdout, stderr, status = Open3.capture3(rendered)
        raise "Signature verification failed: #{[stdout, stderr].join.strip}" unless status.success?

        {
          "signature" => {
            "verified" => true,
            "verified_at" => Time.now.utc.iso8601,
            "tool" => signature_tool_name(verify_command),
            "public_key_path" => public_key_path,
          }.merge(normalize_metadata_result(provenance) || {})
        }
      end

      def sha256_from_document(document, filename:)
        body = document.to_s.strip
        return body.downcase if body.match?(/\A[0-9a-fA-F]{64}\z/)

        body.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          if (match = stripped.match(/\A([0-9a-fA-F]{64})\s+\*?(.+)\z/))
            digest = match[1].downcase
            candidate = match[2].strip
            return digest if candidate == filename || File.basename(candidate) == filename
          elsif (match = stripped.match(/\ASHA256\s*\((.+)\)\s*=\s*([0-9a-fA-F]{64})\z/i))
            candidate = match[1].strip
            digest = match[2].downcase
            return digest if candidate == filename || File.basename(candidate) == filename
          end
        end

        raise "No SHA-256 entry for #{filename.inspect} in checksum document"
      end

      def render_verify_command(template, artifact:, signature:, public_key:)
        {
          "{{artifact}}" => Shellwords.escape(artifact.to_s),
          "{{signature}}" => Shellwords.escape(signature.to_s),
          "{{public_key}}" => Shellwords.escape(public_key.to_s)
        }.reduce(template.to_s) { |command, (needle, value)| command.gsub(needle, value) }
      end

      def signature_tool_name(template)
        Shellwords.split(template.to_s).first
      rescue ArgumentError
        template.to_s.split.first
      end
    end

    # Build a source from a config hash (from the manifest).
    def self.build(config)
      case config["type"]
      when "github_release" then GithubRelease.new(config)
      when "containerized_local_build" then ContainerizedLocalBuild.new(config)
      when "local_build"    then LocalBuild.new(config)
      when "url"            then Url.new(config)
      else raise Manifest::Error, "Unknown source type '#{config["type"]}'. Supported: containerized_local_build, github_release, local_build, url"
      end
    end
  end
end
