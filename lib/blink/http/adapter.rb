# frozen_string_literal: true

require "shellwords"

module Blink
  module HTTP
    # Centralized curl invocation. All of Blink's HTTP traffic (health checks,
    # inline tests, Doctor/Status probes) flows through this module so TLS and
    # HTTP-version policy live in exactly one place.
    #
    # TLS policy: **verify by default.** Callers that genuinely need to hit a
    # self-signed endpoint must pass `tls_insecure: true`. This is wired through
    # as an opt-in config key (`health_check.tls_insecure`, inline test
    # `tls_insecure`). The planner warns when the flag is set so the security
    # posture is always visible.
    module Adapter
      DEFAULT_MAX_TIME = 5

      module_function

      # Run a one-shot health probe against `url` on `target`. Returns the HTTP
      # status code as an integer (0 or "000" on failure).
      #
      # Uses `curl -sf` so non-2xx responses exit non-zero, falling through to
      # the `|| echo 000` sentinel — preserving prior semantics exactly.
      def health_probe(target, url, http_version: nil, tls_insecure: false, max_time: DEFAULT_MAX_TIME)
        cmd = health_probe_command(url, http_version: http_version, tls_insecure: tls_insecure, max_time: max_time)
        target.capture(cmd).to_i
      end

      def health_probe_command(url, http_version: nil, tls_insecure: false, max_time: DEFAULT_MAX_TIME)
        flags = [
          "-s",
          "-f",
          tls_insecure ? "-k" : nil,
          "--max-time", max_time.to_s,
          http_version_flag(http_version),
          "--output", "/dev/null",
          "--write-out", "'%{http_code}'"
        ].compact.reject(&:empty?)
        "curl #{flags.join(' ')} #{url} 2>/dev/null || echo 000"
      end

      # Build a full `curl -i` command suitable for the testing HTTP helper.
      # Returns a shell-escaped string.
      def request_command(method, url, body: nil, headers: {}, http_version: nil,
                          tls_insecure: false, max_time: 10, include_headers: true)
        parts = ["curl", "-s"]
        parts << "-k" if tls_insecure
        parts += ["--max-time", max_time.to_s]
        parts << "-i" if include_headers
        parts += ["-X", method]
        parts << "--http1.1" if http_version.to_s == "1.1"
        parts << "--http2"   if http_version.to_s == "2"
        headers.each { |k, v| parts += ["-H", "#{k}: #{v}"] }
        if body
          parts += ["-H", "Content-Type: application/json"] unless headers.key?("Content-Type")
          parts += ["--data-raw", body]
        end
        parts << url
        parts.map { |p| Shellwords.escape(p) }.join(" ")
      end

      def http_version_flag(http_version)
        case http_version.to_s
        when "1.1" then "--http1.1"
        when "2"   then "--http2"
        else ""
        end
      end
    end
  end
end
