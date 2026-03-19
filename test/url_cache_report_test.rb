# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class UrlCacheReportTest < BlinkTestCase
  def test_state_and_report_surface_http_cache_metadata
    body = "http-artifact"
    requests = 0
    Dir.mktmpdir("blink-url-report") do |workspace|
      verifier = write_signature_verifier(workspace)
      server, thread, base_url = start_server do |mount|
        mount.call("/artifact.tar.gz") do |request|
          requests += 1

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
              body: body,
              headers: { "ETag" => "\"artifact-v1\"" }
            }
          end
        end
        mount.call("/checksums.txt") do |_request|
          {
            status: 200,
            content_type: "text/plain",
            body: "#{Digest::SHA256.hexdigest(body)}  artifact.tar.gz\n"
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

      write_manifest(workspace, base_url, verifier)

      first = run_cli("deploy", "fixture", "--json", chdir: workspace)
      second = run_cli("deploy", "fixture", "--json", chdir: workspace)
      state_result = run_cli("state", "fixture", "--json", chdir: workspace)
      report_result = run_cli("report", "generate", "--format", "html", "--json", chdir: workspace)

      assert first[:status].success?, first[:stderr]
      assert second[:status].success?, second[:stderr]
      assert state_result[:status].success?, state_result[:stderr]
      assert report_result[:status].success?, report_result[:stderr]
      assert_equal 2, requests

      state = parse_json_output(state_result)
      artifact = state.dig("details", "state", "last_deploy", "artifact")
      assert_equal "url", artifact["source_type"]
      assert_equal true, artifact["cached"]
      assert_equal "\"artifact-v1\"", artifact.dig("http", "etag")
      assert_equal true, artifact.dig("http", "revalidated")
      assert_equal true, artifact.dig("integrity", "verified")
      assert_equal "checksum_url", artifact.dig("integrity", "source")
      assert_equal true, artifact.dig("signature", "verified")
      assert_equal "signature_url", artifact.dig("signature", "source")
      assert_includes artifact["cache_summary"], "revalidated"
      assert_includes artifact["cache_summary"], "sha256-verified"
      assert_includes artifact["cache_summary"], "via=checksum_url"
      assert_includes artifact["cache_summary"], "signature-verified"
      assert_includes artifact["cache_summary"], "signed-via=signature_url"

      report = parse_json_output(report_result)
      html = File.read(report.dig("details", "output"))
      assert_includes html, "Artifact:"
      assert_includes html, "ETag"
      assert_includes html, "Integrity: verified"
      assert_includes html, "Integrity source:"
      assert_includes html, "Signature: verified"
      assert_includes html, "Signature source:"
      assert_includes html, "&quot;artifact-v1&quot;"
      assert_includes html, "revalidated"
    ensure
      server.close
      thread.join
      FileUtils.rm_rf(File.join(workspace, ".blink")) if defined?(workspace) && workspace
    end
  end

  private

  def write_manifest(workspace, base_url, verifier)
    File.write(
      File.join(workspace, "blink.toml"),
      <<~TOML
        [blink]
        version = "1"

        [targets.local]
        type = "local"
        base = "/tmp/blink-url-report"

        [services.fixture]
        description = "HTTP-backed url source fixture"

        [services.fixture.source]
        type = "url"
        url = "#{base_url}/artifact.tar.gz"
        artifact = "artifact.tar.gz"
        checksum_url = "#{base_url}/checksums.txt"
        signature_url = "#{base_url}/artifact.tar.gz.sig"
        verify_command = "#{verifier} {{signature}} {{artifact}}"
        allow_insecure = true

        [services.fixture.deploy]
        target = "local"
        pipeline = ["fetch_artifact"]
      TOML
    )
  end

  def start_server
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    base_url = "http://127.0.0.1:#{port}"
    routes = {}
    server = TCPServer.new("127.0.0.1", port)

    mount = lambda do |path, &block|
      routes[path] = block
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

        response = routes.fetch(path).call(path: path, headers: headers)
        status = response.fetch(:status, 200)
        body = response.fetch(:body, "")
        client.write "HTTP/1.1 #{status} #{status == 304 ? "Not Modified" : "OK"}\r\n"
        client.write "Content-Type: #{response.fetch(:content_type, "application/octet-stream")}\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
        response.fetch(:headers, {}).each do |key, value|
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
