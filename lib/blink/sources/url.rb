# frozen_string_literal: true

require "fileutils"
require "net/http"
require "securerandom"
require "tmpdir"
require "uri"

module Blink
  module Sources
    class Url < Base
      TRANSIENT_HTTP_STATUS_CODES = %w[408 425 429 500 502 503 504].freeze

      def fetch(version: "latest", build_name: nil)
        _ = build_name
        raw_url = @config["url"] || raise(Manifest::Error, "source.url is required for url sources")
        resolved_url = raw_url.gsub("{{version}}", version.to_s)
        uri = URI(resolved_url)
        filename = resolve_filename(uri)
        cache_key = cache_key_for(uri, resolved_url)

        Output.step("Fetching artifact from #{resolved_url}...")

        fetch_with_cache(
          cache_key: cache_key,
          filename: filename,
          metadata: {
            "source_type" => "url",
            "url" => resolved_url,
            "version" => version,
          },
          reuse: cache_reuse_policy(uri),
          validate: lambda do |path, _existing_metadata|
            checksum, provenance = expected_checksum_details(version: version, filename: filename)
            checksum_metadata = verify_sha256!(path, checksum, provenance: provenance)
            signature_metadata = verify_signature_details(version: version, filename: filename, artifact_path: path)
            metadata_payload(checksum_metadata, signature_metadata)
          end
        ) do |destination, existing_metadata|
          case uri.scheme
          when "file"
            fetch_file(uri, destination)
            destination
          when "http", "https"
            fetch_http(uri, destination, cache_metadata: existing_metadata)
          else
            raise Manifest::Error, "Unsupported url source scheme #{uri.scheme.inspect}. Expected file, http, or https."
          end
        end
      end

      private

      def cache_reuse_policy(uri)
        return true if uri.scheme == "file"

        lambda do |cached_path|
          ttl = cache_ttl_seconds
          return false if ttl.nil?

          Time.now - File.mtime(cached_path) <= ttl
        end
      end

      def cache_key_for(uri, resolved_url)
        payload = {
          type: "url",
          url: resolved_url,
          headers: headers,
        }

        if uri.scheme == "file" && File.exist?(uri.path)
          stat = File.stat(uri.path)
          payload[:file] = { size: stat.size, mtime: stat.mtime.to_f }
        end

        digest_for(payload)
      end

      def resolve_filename(uri)
        configured = @config["artifact"]
        return configured if configured.is_a?(String) && !configured.strip.empty?

        basename = File.basename(uri.path)
        return basename unless basename.nil? || basename.empty? || basename == "/"

        "artifact"
      end

      def fetch_file(uri, dest)
        source_path = uri.path
        raise "URL source file not found: #{source_path}" unless File.exist?(source_path)

        FileUtils.cp(source_path, dest)
      end

      def fetch_http(uri, dest, cache_metadata: nil, limit: 5)
        response = request_http(uri, cache_metadata: cache_metadata, limit: limit)

        if response.code == "304"
          Output.info("Remote artifact unchanged: #{uri}")
          return {
            path: dest,
            metadata: http_cache_metadata(uri, response, cache_metadata, revalidated: true)
          }
        end

        raise "Download failed: HTTP #{response.code} for #{uri}" unless response.code == "200"

        File.open(dest, "wb") { |file| file.write(response.body) }
        {
          path: dest,
          metadata: http_cache_metadata(uri, response, cache_metadata, revalidated: false)
        }
      end

      def fetch_text_source(location)
        uri = URI(location)
        basename = File.basename(uri.path.to_s)
        basename = "document" if basename.nil? || basename.empty? || basename == "/"

        fetch_blob_source(location, filename: basename).then do |fetched|
          begin
            File.read(fetched[:path], encoding: "utf-8")
          ensure
            FileUtils.rm_f(fetched[:path]) if fetched[:temporary]
          end
        end
      end

      def fetch_blob_source(location, filename:)
        uri = URI(location)

        case uri.scheme
        when "file"
          { path: uri.path, temporary: false }
        when "http", "https"
          response = request_http(uri)
          raise "Fetch failed: HTTP #{response.code} for #{location}" unless response.code == "200"

          { path: stage_content(response.body, filename: filename), temporary: true }
        else
          raise Manifest::Error, "Unsupported remote reference scheme #{uri.scheme.inspect}. Expected file, http, or https."
        end
      end

      def expected_checksum_details(version:, filename:)
        return [@config["sha256"], { "source" => "manifest.sha256" }] if @config["sha256"]

        checksum_url = @config["checksum_url"]
        return [nil, nil] unless checksum_url

        resolved = checksum_url.gsub("{{version}}", version.to_s)
        checksum = sha256_from_document(fetch_text_source(resolved), filename: filename)
        [checksum, { "source" => "checksum_url", "reference" => resolved, "subject" => filename }]
      end

      def verify_signature_details(version:, filename:, artifact_path:)
        signature_url = @config["signature_url"]
        verify_command = @config["verify_command"]
        return nil if signature_url.to_s.strip.empty? || verify_command.to_s.strip.empty?

        resolved = signature_url.gsub("{{version}}", version.to_s)
        fetched = fetch_blob_source(resolved, filename: "#{filename}.sig")
        begin
          verify_signature!(
            artifact_path,
            verify_command: verify_command,
            signature_path: fetched[:path],
            public_key_path: @config["public_key_path"],
            provenance: { "source" => "signature_url", "reference" => resolved, "subject" => filename }
          )
        ensure
          FileUtils.rm_f(fetched[:path]) if fetched[:temporary]
        end
      end

      def request_http(uri, cache_metadata: nil, limit: 5)
        raise "Too many redirects fetching #{uri}" if limit.zero?

        attempts = 0

        begin
          req = Net::HTTP::Get.new(uri)
          headers.each { |key, value| req[key] = value }
          req["Authorization"] = "Bearer #{token}" if token && !authorization_header?(req)
          req["User-Agent"] = "blink/#{Blink::VERSION}"
          apply_revalidation_headers(req, cache_metadata) if cache_metadata.is_a?(Hash)

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: http_timeout_seconds,
            read_timeout: http_timeout_seconds
          ) do |http|
            http.request(req)
          end

          if %w[301 302 307 308].include?(response.code)
            location = response["location"] || raise("Redirect missing location for #{uri}")
            return request_http(URI(location), cache_metadata: cache_metadata, limit: limit - 1)
          end

          raise retryable_http_error(uri, response) if response.code != "200" && response.code != "304" && retryable_status?(response.code)

          response
        rescue Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, IOError, SystemCallError => e
          raise unless retryable_exception?(e) && attempts < retry_count

          attempts += 1
          wait_before_retry(uri, attempts, e.message)
          retry
        rescue StandardError => e
          raise unless e.message.start_with?("Retryable download failure") && attempts < retry_count

          attempts += 1
          wait_before_retry(uri, attempts, e.message.sub("Retryable download failure: ", ""))
          retry
        end
      end

      def apply_revalidation_headers(req, cache_metadata)
        http = cache_metadata.is_a?(Hash) ? cache_metadata["http"] : nil
        return unless http.is_a?(Hash)

        req["If-None-Match"] = http["etag"] if http["etag"]
        req["If-Modified-Since"] = http["last_modified"] if http["last_modified"]
      end

      def http_cache_metadata(uri, response, previous_metadata, revalidated:)
        previous_http = previous_metadata.is_a?(Hash) ? previous_metadata["http"] : nil
        http_metadata = {}
        http_metadata["etag"] = response["etag"] || previous_http&.dig("etag")
        http_metadata["last_modified"] = response["last-modified"] || previous_http&.dig("last_modified")
        http_metadata["status"] = response.code.to_i
        http_metadata["revalidated"] = revalidated
        http_metadata["validated_at"] = Time.now.utc.iso8601
        http_metadata["url"] = uri.to_s

        { "http" => http_metadata.compact }
      end

      def headers
        value = @config["headers"]
        return {} unless value.is_a?(Hash)

        value.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def authorization_header?(req)
        req.key?("authorization")
      end

      def http_timeout_seconds
        value = @config["timeout_seconds"]
        value.is_a?(Integer) && value.positive? ? value : 30
      end

      def retry_count
        value = @config["retry_count"]
        value.is_a?(Integer) && value >= 0 ? value : 2
      end

      def retry_backoff_seconds
        value = @config["retry_backoff_seconds"]
        value.is_a?(Integer) && value >= 0 ? value : 1
      end

      def retryable_status?(code)
        TRANSIENT_HTTP_STATUS_CODES.include?(code.to_s)
      end

      def retryable_exception?(error)
        !error.is_a?(Errno::ENOENT)
      end

      def retryable_http_error(uri, response)
        "Retryable download failure: HTTP #{response.code} for #{uri}"
      end

      def wait_before_retry(uri, attempts, reason)
        Output.info("Retrying #{uri} (attempt #{attempts}/#{retry_count}) after #{reason}")
        delay = retry_backoff_seconds
        sleep(delay) if delay.positive?
      end

      def token
        @config["token_env"]&.then { |env| ENV[env] }
      end
    end
  end
end
