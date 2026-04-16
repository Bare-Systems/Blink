# frozen_string_literal: true

require_relative "test_helper"

# Sprint D guardrail: verify `Blink::HTTP::Adapter` builds commands with TLS
# verification ON by default, and only emits `-k` when explicitly opted in.
class HTTPAdapterTest < BlinkTestCase
  def test_health_probe_command_verifies_tls_by_default
    cmd = Blink::HTTP::Adapter.health_probe_command("https://example.test/health")
    refute_includes cmd, "-k", "default health probe should verify TLS — got: #{cmd}"
    assert_includes cmd, "-f"
    assert_includes cmd, "--max-time 5"
    assert_includes cmd, "https://example.test/health"
  end

  def test_health_probe_command_opts_into_insecure
    cmd = Blink::HTTP::Adapter.health_probe_command("https://example.test/health", tls_insecure: true)
    assert_includes cmd, "-k"
  end

  def test_request_command_verifies_tls_by_default
    cmd = Blink::HTTP::Adapter.request_command("GET", "https://example.test/")
    refute_includes cmd, " -k ", "default request should verify TLS"
    assert_includes cmd, "-X"
    assert_includes cmd, "GET"
  end

  def test_request_command_threads_through_tls_insecure
    cmd = Blink::HTTP::Adapter.request_command("POST", "https://example.test/", tls_insecure: true)
    assert_includes cmd, "-k"
  end

  def test_http_version_flag_mapping
    assert_equal "--http1.1", Blink::HTTP::Adapter.http_version_flag("1.1")
    assert_equal "--http2",   Blink::HTTP::Adapter.http_version_flag("2")
    assert_equal "",          Blink::HTTP::Adapter.http_version_flag(nil)
  end
end
