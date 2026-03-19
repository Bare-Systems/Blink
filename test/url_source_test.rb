# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class UrlSourceTest < BlinkTestCase
  def test_url_source_fetches_local_file_via_file_scheme
    Dir.mktmpdir("blink-url-source") do |tmp|
      source_path = File.join(tmp, "artifact.bin")
      File.binwrite(source_path, "artifact-data")

      source = Blink::Sources.build(
        "type" => "url",
        "url" => "file://#{source_path}",
        "artifact" => "copied.bin"
      )

      fetched_path = source.fetch

      assert File.exist?(fetched_path)
      assert_equal "artifact-data", File.binread(fetched_path)
      assert_equal "copied.bin", File.basename(fetched_path).split("-", 4).last
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    end
  end

  def test_schema_accepts_url_source_type
    data = {
      "blink" => { "version" => "1" },
      "targets" => { "local" => { "type" => "local" } },
      "services" => {
        "demo" => {
          "source" => {
            "type" => "url",
            "url" => "https://example.test/artifact.tar.gz",
            "artifact" => "artifact.tar.gz"
          },
          "deploy" => {
            "target" => "local",
            "pipeline" => ["fetch_artifact"]
          }
        }
      }
    }

    result = Blink::Schema.validate(data)

    assert result.valid?, result.errors.map(&:message).join("\n")
  end

  def test_schema_rejects_invalid_url_retry_config
    data = {
      "blink" => { "version" => "1" },
      "targets" => { "local" => { "type" => "local" } },
      "services" => {
        "demo" => {
          "source" => {
            "type" => "url",
            "url" => "https://example.test/artifact.tar.gz",
            "timeout_seconds" => 0,
            "retry_count" => -1,
            "headers" => { "X-Trace" => 123 },
            "sha256" => "bad",
            "signature_url" => "https://example.test/artifact.tar.gz.sig"
          },
          "deploy" => {
            "target" => "local",
            "pipeline" => ["fetch_artifact"]
          }
        }
      }
    }

    result = Blink::Schema.validate(data)

    refute result.valid?
    messages = result.errors.map(&:message).join("\n")
    assert_includes messages, "services.demo.source.timeout_seconds must be a positive integer."
    assert_includes messages, "services.demo.source.retry_count must be a non-negative integer."
    assert_includes messages, "url source headers values must be strings."
    assert_includes messages, "services.demo.source.sha256 must be a 64-character hex SHA-256 string."
    assert_includes messages, "url signature verification requires verify_command."
  end

  def test_http_url_source_reuses_cache_when_ttl_is_set
    requests = 0
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        requests += 1
        {
          status: 200,
          content_type: "application/octet-stream",
          body: "cached-http",
          headers: { "ETag" => "\"artifact-v1\"" }
        }
      end
    end

    begin
      cache_root = Dir.mktmpdir("blink-url-cache")
      source = Blink::Sources.build(
        "type" => "url",
        "_manifest_dir" => cache_root,
        "_cache_dir" => File.join(cache_root, ".blink", "artifacts"),
        "_service_name" => "fixture",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "cache" => { "ttl_seconds" => 60 }
      )

      first = source.fetch
      second = source.fetch

      assert_equal first, second
      assert_equal 1, requests
    ensure
      FileUtils.rm_rf(cache_root) if defined?(cache_root) && cache_root
      server.close
      thread.join
    end
  end

  def test_http_url_source_applies_headers_and_token_env
    request_headers = []
    ENV["BLINK_URL_TEST_TOKEN"] = "secret-token"
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |request|
        request_headers << request[:headers]
        {
          status: 200,
          content_type: "application/octet-stream",
          body: "auth-http"
        }
      end
    end

    begin
      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "headers" => { "X-Trace" => "abc123" },
        "token_env" => "BLINK_URL_TEST_TOKEN"
      )

      fetched_path = source.fetch

      assert_equal "auth-http", File.binread(fetched_path)
      assert_equal "abc123", request_headers.last["x-trace"]
      assert_equal "Bearer secret-token", request_headers.last["authorization"]
    ensure
      ENV.delete("BLINK_URL_TEST_TOKEN")
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close
      thread.join
    end
  end

  def test_http_url_source_verifies_sha256
    body = "verified-http"
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        {
          status: 200,
          content_type: "application/octet-stream",
          body: body
        }
      end
    end

    begin
      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "sha256" => Digest::SHA256.hexdigest(body)
      )

      fetched_path = source.fetch

      assert_equal body, File.binread(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close
      thread.join
    end
  end

  def test_http_url_source_verifies_checksum_from_checksum_url
    body = "verified-http"
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        {
          status: 200,
          content_type: "application/octet-stream",
          body: body
        }
      end
      mount.call("/checksums.txt") do |_request|
        {
          status: 200,
          content_type: "text/plain",
          body: "#{Digest::SHA256.hexdigest(body)}  artifact.tar.gz\n"
        }
      end
    end

    begin
      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "checksum_url" => "#{base_url}/checksums.txt"
      )

      fetched_path = source.fetch

      assert_equal body, File.binread(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close
      thread.join
    end
  end

  def test_http_url_source_verifies_signature_from_signature_url
    body = "verified-http"
    Dir.mktmpdir("blink-url-signature") do |tmp|
      verifier = write_signature_verifier(tmp)
      server, thread, base_url = start_server do |mount|
        mount.call("/artifact.tar.gz") do |_request|
          {
            status: 200,
            content_type: "application/octet-stream",
            body: body
          }
        end
        mount.call("/artifact.tar.gz.sig") do |_request|
          {
            status: 200,
            content_type: "text/plain",
            body: Digest::SHA256.hexdigest(body)
          }
        end
      end

      begin
        source = Blink::Sources.build(
          "type" => "url",
          "url" => "#{base_url}/artifact.tar.gz",
          "artifact" => "artifact.tar.gz",
          "signature_url" => "#{base_url}/artifact.tar.gz.sig",
          "verify_command" => "#{verifier} {{signature}} {{artifact}}"
        )

        fetched_path = source.fetch

        assert_equal body, File.binread(fetched_path)
      ensure
        FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
        server.close
        thread.join
      end
    end
  end

  def test_http_url_source_rejects_sha256_mismatch
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        {
          status: 200,
          content_type: "application/octet-stream",
          body: "mismatch-http"
        }
      end
    end

    source = Blink::Sources.build(
      "type" => "url",
      "url" => "#{base_url}/artifact.tar.gz",
      "artifact" => "artifact.tar.gz",
      "sha256" => "0" * 64
    )

    error = assert_raises(RuntimeError) { source.fetch }
    assert_includes error.message, "Checksum mismatch"
  ensure
    server.close if server
    thread.join if thread
  end

  def test_http_url_source_rejects_checksum_document_without_matching_entry
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        {
          status: 200,
          content_type: "application/octet-stream",
          body: "mismatch-http"
        }
      end
      mount.call("/checksums.txt") do |_request|
        {
          status: 200,
          content_type: "text/plain",
          body: "#{Digest::SHA256.hexdigest("other-http")}  other.tar.gz\n"
        }
      end
    end

    source = Blink::Sources.build(
      "type" => "url",
      "url" => "#{base_url}/artifact.tar.gz",
      "artifact" => "artifact.tar.gz",
      "checksum_url" => "#{base_url}/checksums.txt"
    )

    error = assert_raises(RuntimeError) { source.fetch }
    assert_includes error.message, "No SHA-256 entry"
  ensure
    server.close if server
    thread.join if thread
  end

  def test_http_url_source_rejects_bad_signature
    body = "verified-http"
    Dir.mktmpdir("blink-url-signature") do |tmp|
      verifier = write_signature_verifier(tmp)
      server, thread, base_url = start_server do |mount|
        mount.call("/artifact.tar.gz") do |_request|
          {
            status: 200,
            content_type: "application/octet-stream",
            body: body
          }
        end
        mount.call("/artifact.tar.gz.sig") do |_request|
          {
            status: 200,
            content_type: "text/plain",
            body: "not-the-right-signature"
          }
        end
      end

      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "signature_url" => "#{base_url}/artifact.tar.gz.sig",
        "verify_command" => "#{verifier} {{signature}} {{artifact}}"
      )

      error = assert_raises(RuntimeError) { source.fetch }
      assert_includes error.message, "Signature verification failed"
    ensure
      server.close if server
      thread.join if thread
    end
  end

  def test_http_url_source_prefers_explicit_authorization_header_over_token_env
    request_headers = []
    ENV["BLINK_URL_TEST_TOKEN"] = "secret-token"
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |request|
        request_headers << request[:headers]
        {
          status: 200,
          content_type: "application/octet-stream",
          body: "auth-http"
        }
      end
    end

    begin
      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "headers" => { "Authorization" => "Token explicit-token" },
        "token_env" => "BLINK_URL_TEST_TOKEN"
      )

      fetched_path = source.fetch

      assert_equal "auth-http", File.binread(fetched_path)
      assert_equal "Token explicit-token", request_headers.last["authorization"]
    ensure
      ENV.delete("BLINK_URL_TEST_TOKEN")
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close
      thread.join
    end
  end

  def test_http_url_source_does_not_reuse_without_ttl
    requests = 0
    request_headers = []
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |request|
        requests += 1
        request_headers << request[:headers]

        if request[:headers]["if-none-match"] == "\"artifact-v1\""
          {
            status: 304,
            content_type: "application/octet-stream",
            body: "",
            headers: { "ETag" => "\"artifact-v1\"" }
          }
        else
          {
            status: 200,
            content_type: "application/octet-stream",
            body: "uncached-http",
            headers: { "ETag" => "\"artifact-v1\"" }
          }
        end
      end
    end

    begin
      cache_root = Dir.mktmpdir("blink-url-cache-no-ttl")
      source = Blink::Sources.build(
        "type" => "url",
        "_manifest_dir" => cache_root,
        "_cache_dir" => File.join(cache_root, ".blink", "artifacts"),
        "_service_name" => "fixture",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz"
      )

      first = source.fetch
      second = source.fetch

      assert_equal first, second
      assert_equal 2, requests
      assert_nil request_headers.first["if-none-match"]
      assert_equal "\"artifact-v1\"", request_headers.last["if-none-match"]
      assert_equal "uncached-http", File.binread(second)
    ensure
      FileUtils.rm_rf(cache_root) if defined?(cache_root) && cache_root
      server.close
      thread.join
    end
  end

  def test_http_url_source_revalidates_with_last_modified_when_etag_is_absent
    requests = 0
    request_headers = []
    last_modified = "Wed, 21 Oct 2015 07:28:00 GMT"
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |request|
        requests += 1
        request_headers << request[:headers]

        if request[:headers]["if-modified-since"] == last_modified
          {
            status: 304,
            content_type: "application/octet-stream",
            body: "",
            headers: { "Last-Modified" => last_modified }
          }
        else
          {
            status: 200,
            content_type: "application/octet-stream",
            body: "last-modified-http",
            headers: { "Last-Modified" => last_modified }
          }
        end
      end
    end

    begin
      cache_root = Dir.mktmpdir("blink-url-cache-last-modified")
      source = Blink::Sources.build(
        "type" => "url",
        "_manifest_dir" => cache_root,
        "_cache_dir" => File.join(cache_root, ".blink", "artifacts"),
        "_service_name" => "fixture",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz"
      )

      first = source.fetch
      second = source.fetch

      assert_equal first, second
      assert_equal 2, requests
      assert_nil request_headers.first["if-modified-since"]
      assert_equal last_modified, request_headers.last["if-modified-since"]
      assert_equal "last-modified-http", File.binread(second)
    ensure
      FileUtils.rm_rf(cache_root) if defined?(cache_root) && cache_root
      server.close
      thread.join
    end
  end

  def test_http_url_source_retries_transient_failures
    requests = 0
    server, thread, base_url = start_server do |mount|
      mount.call("/artifact.tar.gz") do |_request|
        requests += 1
        if requests == 1
          {
            status: 503,
            content_type: "text/plain",
            body: "temporarily unavailable"
          }
        else
          {
            status: 200,
            content_type: "application/octet-stream",
            body: "retried-http"
          }
        end
      end
    end

    begin
      source = Blink::Sources.build(
        "type" => "url",
        "url" => "#{base_url}/artifact.tar.gz",
        "artifact" => "artifact.tar.gz",
        "retry_count" => 1,
        "retry_backoff_seconds" => 0
      )

      fetched_path = source.fetch

      assert_equal 2, requests
      assert_equal "retried-http", File.binread(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close
      thread.join
    end
  end

  private

  def start_server
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    base_url = "http://127.0.0.1:#{port}"
    routes = {}
    server = TCPServer.new("127.0.0.1", port)

    mount = lambda do |path, content_type = nil, body = nil, status: 200, headers: {}, &block|
      routes[path] = if block
                       block
                     else
                       lambda do |_request|
                         { status: status, content_type: content_type, body: body, headers: headers }
                       end
                     end
    end

    yield mount
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        next unless request_line

        path = request_line.split[1]
        headers = {}
        while (line = client.gets)
          break if line == "\r\n"

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip if key && value
        end

        callback = routes[path]
        response = if callback
                     callback.call(path: path, headers: headers)
                   else
                     { status: 404, content_type: "text/plain", body: "not found", headers: {} }
                   end

        status = response.fetch(:status, 200)
        content_type = response.fetch(:content_type, "application/octet-stream")
        body = response.fetch(:body, "")
        response_headers = response.fetch(:headers, {})
        reason =
          case status
          when 200 then "OK"
          when 304 then "Not Modified"
          when 404 then "Not Found"
          else "Response"
          end
        client.write "HTTP/1.1 #{status} #{reason}\r\n"
        client.write "Content-Type: #{content_type}\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
        response_headers.each do |key, value|
          client.write "#{key}: #{value}\r\n"
        end
        client.write "Connection: close\r\n\r\n"
        client.write body
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    sleep 0.05
    [server, thread, base_url]
  end
end
