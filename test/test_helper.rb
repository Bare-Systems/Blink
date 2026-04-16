# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "socket"
require "tmpdir"
require "digest"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")
require "blink"

class BlinkTestCase < Minitest::Test
  BIN = File.join(ROOT, "bin", "blink")
  VALID_FIXTURE_DIR = File.join(ROOT, "test", "fixtures", "manifests", "valid", "basic")
  VALID_FIXTURE_MANIFEST = File.join(VALID_FIXTURE_DIR, "blink.toml")
  PLATFORM_FIXTURE_DIR = File.join(ROOT, "test", "fixtures", "manifests", "valid", "platform_stack")
  PLATFORM_FIXTURE_MANIFEST = File.join(PLATFORM_FIXTURE_DIR, "blink.toml")
  INVALID_FIXTURE_MANIFEST = File.join(ROOT, "test", "fixtures", "manifests", "invalid", "missing_target.toml")

  def with_fixture_workspace
    Dir.mktmpdir("blink-test") do |tmp|
      FileUtils.cp_r(VALID_FIXTURE_DIR, tmp)
      workspace = File.join(tmp, "basic")
      yield workspace
    ensure
      FileUtils.rm_rf(File.join(tmp, "basic", ".blink"))
    end
  end

  def with_platform_workspace(port: nil)
    Dir.mktmpdir("blink-platform") do |tmp|
      FileUtils.cp_r(PLATFORM_FIXTURE_DIR, tmp)
      workspace = File.join(tmp, "platform_stack")

      if port
        manifest_path = File.join(workspace, "blink.toml")
        File.write(manifest_path, File.read(manifest_path).gsub("__PORT__", port.to_s))
      end

      yield workspace
    ensure
      FileUtils.rm_rf(File.join(tmp, "platform_stack", ".blink"))
    end
  end

  def run_cli(*args, chdir:)
    stdout, stderr, status = Open3.capture3(BIN, *args, chdir: chdir)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def parse_json_output(result)
    JSON.parse(result.fetch(:stdout))
  end

  def write_signature_verifier(dir)
    path = File.join(dir, "verify-signature.sh")
    File.write(
      path,
      <<~SH
        #!/bin/sh
        signature_file="$1"
        artifact_file="$2"
        expected="$(tr -d '\\r\\n' < "$signature_file")"
        actual="$(shasum -a 256 "$artifact_file" | awk '{print $1}')"
        [ "$expected" = "$actual" ]
      SH
    )
    FileUtils.chmod(0o755, path)
    path
  end

  def with_tmp_workspace
    Dir.mktmpdir("blink-workspace") do |dir|
      yield dir
    end
  end

  def with_http_server(routes)
    server = TCPServer.new("127.0.0.1", 0)
    stop = false
    thread = Thread.new do
      until stop
        socket = server.accept_nonblock(exception: false)
        if socket == :wait_readable
          IO.select([server], nil, nil, 0.05)
          next
        end

        handle_http_client(socket, routes)
      end
    rescue IOError, Errno::EBADF
      nil
    end

    port = server.addr[1]
    yield port
  ensure
    stop = true
    server&.close
    thread&.join
  end

  private

  def handle_http_client(socket, routes)
    request_line = socket.gets
    path = request_line.to_s.split[1]
    loop do
      line = socket.gets
      break if line.nil? || line.strip.empty?
    end

    responder = routes[path]
    status, headers, body = if responder
      responder.call(nil)
    else
      [404, { "Content-Type" => "text/plain" }, "not found"]
    end

    body = body.to_s
    headers = headers.merge(
      "Content-Length" => body.bytesize.to_s,
      "Connection" => "close"
    )

    socket.write("HTTP/1.1 #{status} #{http_status_text(status)}\r\n")
    headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
    socket.write("\r\n")
    socket.write(body)
  ensure
    socket&.close
  end

  def http_status_text(status)
    {
      200 => "OK",
      404 => "Not Found",
    }.fetch(status, "OK")
  end
end
