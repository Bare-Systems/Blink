# frozen_string_literal: true

module Blink
  module Sources
    # Cache concern for source artifacts. Mixed into `Sources::Base`.
    #
    # Provides the `fetch_with_cache` wrapper and all supporting helpers that
    # read/write cached artifacts under `.blink/artifacts/<service>/` plus the
    # JSON-sidecar metadata files that track origin, integrity, and reuse
    # timestamps. Concrete sources (`url`, `github_release`, `local_build`)
    # call `fetch_with_cache(...) { |dest, metadata| ... }` and let this
    # module decide whether to serve from cache or invoke the block to fetch.
    #
    # Before Sprint F this logic lived on `Sources::Base`. It was extracted
    # into its own module so that (a) the caching concern is named and
    # testable in isolation, and (b) non-caching sources (future plugins, or
    # in-memory synthetic sources) can choose not to mix it in.
    module Cache
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
    end
  end
end
