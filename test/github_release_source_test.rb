# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class GithubReleaseSourceTest < BlinkTestCase
  def test_github_release_fetches_asset_from_configurable_api_base
    release_calls = 0
    download_calls = 0
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
        "tag_name" => "v1.2.3",
        "assets" => [
          {
            "name" => "demo-linux-amd64.tar.gz",
            "size" => 12,
            "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
          }
        ]
      )) { release_calls += 1 }
      mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", "release-bytes") { download_calls += 1 }
    end

    begin
      cache_root = Dir.mktmpdir("blink-gh-cache")
      source = Blink::Sources.build(
        "type" => "github_release",
        "_manifest_dir" => cache_root,
        "_cache_dir" => File.join(cache_root, ".blink", "artifacts"),
        "_service_name" => "fixture",
        "api_base" => base_url,
        "repo" => "acme/demo",
        "asset" => "demo-linux-amd64"
      )

      fetched_path = source.fetch
      fetched_path_again = source.fetch

      assert File.exist?(fetched_path)
      assert_equal "release-bytes", File.binread(fetched_path)
      assert_equal fetched_path, fetched_path_again
      assert_equal 2, release_calls
      assert_equal 1, download_calls
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      FileUtils.rm_rf(cache_root) if defined?(cache_root) && cache_root
      server.close
      thread.join
    end
  end

  def test_github_release_reports_api_message_on_failure
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate("message" => "rate limited"), status: 403)
    end

    source = Blink::Sources.build(
      "type" => "github_release",
      "api_base" => base_url,
      "repo" => "acme/demo",
      "asset" => "demo"
    )

    error = assert_raises(RuntimeError) { source.fetch }
    assert_includes error.message, "rate limited"
  ensure
    server.close if server
    thread.join if thread
  end

  def test_github_release_verifies_sha256
    asset_body = "release-bytes"
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
        "tag_name" => "v1.2.3",
        "assets" => [
          {
            "name" => "demo-linux-amd64.tar.gz",
            "size" => asset_body.bytesize,
            "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
          }
        ]
      ))
      mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", asset_body)
    end

    source = Blink::Sources.build(
      "type" => "github_release",
      "api_base" => base_url,
      "repo" => "acme/demo",
      "asset" => "demo",
      "sha256" => Digest::SHA256.hexdigest(asset_body)
    )

    fetched_path = source.fetch
    assert_equal asset_body, File.binread(fetched_path)
  ensure
    FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    server.close if server
    thread.join if thread
  end

  def test_github_release_verifies_checksum_asset
    asset_body = "release-bytes"
    checksum_body = "#{Digest::SHA256.hexdigest(asset_body)}  demo-linux-amd64.tar.gz\n"
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
        "tag_name" => "v1.2.3",
        "assets" => [
          {
            "name" => "demo-linux-amd64.tar.gz",
            "size" => asset_body.bytesize,
            "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
          },
          {
            "name" => "checksums.txt",
            "size" => checksum_body.bytesize,
            "browser_download_url" => "#{base_url_placeholder}/downloads/checksums.txt"
          }
        ]
      ))
      mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", asset_body)
      mount.call("/downloads/checksums.txt", "text/plain", checksum_body)
    end

    source = Blink::Sources.build(
      "type" => "github_release",
      "api_base" => base_url,
      "repo" => "acme/demo",
      "asset" => "demo",
      "checksum_asset" => "checksums.txt"
    )

    fetched_path = source.fetch
    assert_equal asset_body, File.binread(fetched_path)
  ensure
    FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
    server.close if server
    thread.join if thread
  end

  def test_github_release_verifies_signature_asset
    asset_body = "release-bytes"
    Dir.mktmpdir("blink-gh-signature") do |tmp|
      verifier = write_signature_verifier(tmp)
      signature_body = Digest::SHA256.hexdigest(asset_body)
      server, thread, base_url = start_server do |mount|
        mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
          "tag_name" => "v1.2.3",
          "assets" => [
            {
              "name" => "demo-linux-amd64.tar.gz",
              "size" => asset_body.bytesize,
              "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
            },
            {
              "name" => "demo-linux-amd64.tar.gz.minisig",
              "size" => signature_body.bytesize,
              "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz.minisig"
            }
          ]
        ))
        mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", asset_body)
        mount.call("/downloads/demo-linux-amd64.tar.gz.minisig", "text/plain", signature_body)
      end

      source = Blink::Sources.build(
        "type" => "github_release",
        "api_base" => base_url,
        "repo" => "acme/demo",
        "asset" => "demo",
        "signature_asset" => ".minisig",
        "verify_command" => "#{verifier} {{signature}} {{artifact}}"
      )

      fetched_path = source.fetch
      assert_equal asset_body, File.binread(fetched_path)
    ensure
      FileUtils.rm_f(fetched_path) if defined?(fetched_path) && fetched_path
      server.close if server
      thread.join if thread
    end
  end

  def test_github_release_rejects_sha256_mismatch
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
        "tag_name" => "v1.2.3",
        "assets" => [
          {
            "name" => "demo-linux-amd64.tar.gz",
            "size" => 12,
            "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
          }
        ]
      ))
      mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", "release-bytes")
    end

    source = Blink::Sources.build(
      "type" => "github_release",
      "api_base" => base_url,
      "repo" => "acme/demo",
      "asset" => "demo",
      "sha256" => "0" * 64
    )

    error = assert_raises(RuntimeError) { source.fetch }
    assert_includes error.message, "Checksum mismatch"
  ensure
    server.close if server
    thread.join if thread
  end

  def test_github_release_rejects_checksum_asset_without_matching_entry
    server, thread, base_url = start_server do |mount|
      mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
        "tag_name" => "v1.2.3",
        "assets" => [
          {
            "name" => "demo-linux-amd64.tar.gz",
            "size" => 12,
            "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
          },
          {
            "name" => "checksums.txt",
            "size" => 20,
            "browser_download_url" => "#{base_url_placeholder}/downloads/checksums.txt"
          }
        ]
      ))
      mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", "release-bytes")
      mount.call("/downloads/checksums.txt", "text/plain", "#{Digest::SHA256.hexdigest("other")}  other.tar.gz\n")
    end

    source = Blink::Sources.build(
      "type" => "github_release",
      "api_base" => base_url,
      "repo" => "acme/demo",
      "asset" => "demo",
      "checksum_asset" => "checksums.txt"
    )

    error = assert_raises(RuntimeError) { source.fetch }
    assert_includes error.message, "No SHA-256 entry"
  ensure
    server.close if server
    thread.join if thread
  end

  def test_github_release_rejects_bad_signature_asset
    asset_body = "release-bytes"
    Dir.mktmpdir("blink-gh-signature") do |tmp|
      verifier = write_signature_verifier(tmp)
      server, thread, base_url = start_server do |mount|
        mount.call("/repos/acme/demo/releases/latest", "application/json", JSON.generate(
          "tag_name" => "v1.2.3",
          "assets" => [
            {
              "name" => "demo-linux-amd64.tar.gz",
              "size" => asset_body.bytesize,
              "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz"
            },
            {
              "name" => "demo-linux-amd64.tar.gz.minisig",
              "size" => 10,
              "browser_download_url" => "#{base_url_placeholder}/downloads/demo-linux-amd64.tar.gz.minisig"
            }
          ]
        ))
        mount.call("/downloads/demo-linux-amd64.tar.gz", "application/octet-stream", asset_body)
        mount.call("/downloads/demo-linux-amd64.tar.gz.minisig", "text/plain", "bad-signature")
      end

      source = Blink::Sources.build(
        "type" => "github_release",
        "api_base" => base_url,
        "repo" => "acme/demo",
        "asset" => "demo",
        "signature_asset" => ".minisig",
        "verify_command" => "#{verifier} {{signature}} {{artifact}}"
      )

      error = assert_raises(RuntimeError) { source.fetch }
      assert_includes error.message, "Signature verification failed"
    ensure
      server.close if server
      thread.join if thread
    end
  end

  private

  def base_url_placeholder
    "__BASE_URL__"
  end

  def start_server
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    base_url = "http://127.0.0.1:#{port}"
    routes = {}
    server = TCPServer.new("127.0.0.1", port)

    mount = lambda do |path, content_type, body, status: 200, &block|
      routes[path] = [status, content_type, body.gsub(base_url_placeholder, base_url), block]
    end

    yield mount
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        next unless request_line

        path = request_line.split[1]
        while (line = client.gets)
          break if line == "\r\n"
        end

        status, content_type, body, callback = routes.fetch(path, [404, "text/plain", "not found", nil])
        callback&.call
        reason = status == 200 ? "OK" : "Forbidden"
        client.write "HTTP/1.1 #{status} #{reason}\r\n"
        client.write "Content-Type: #{content_type}\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
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
