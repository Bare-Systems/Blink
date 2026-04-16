# frozen_string_literal: true

module Blink
  module Testing
    # Lightweight HTTP response value object.
    Response = Struct.new(:status, :headers, :body) do
      def ok?         = status == 200
      def redirect?   = (300..399).cover?(status)
      def client_err? = (400..499).cover?(status)
      def server_err? = (500..599).cover?(status)
      def header(name) = headers[name.to_s.downcase]
    end

    # Makes HTTP requests via curl run on the target (SSH or local).
    # Running curl on the target ensures tests work against the service's
    # loopback interface, regardless of whether the host is directly
    # reachable from the developer's machine.
    #
    # TLS verification defaults to ON. Inline tests targeting self-signed
    # endpoints must set `tls_insecure: true` in their TOML config.
    class HTTP
      def initialize(target, tls_insecure: false)
        @target = target
        @tls_insecure = tls_insecure
      end

      def get(url, headers: {}, host: nil, http_version: nil)
        request("GET", url, headers: with_host(headers, host), http_version: http_version)
      end

      def post(url, body: nil, headers: {}, host: nil, http_version: nil)
        request("POST", url, body: body, headers: with_host(headers, host), http_version: http_version)
      end

      def head(url, headers: {}, host: nil, http_version: nil)
        request("HEAD", url, headers: with_host(headers, host), head_only: true, http_version: http_version)
      end

      private

      def with_host(headers, host)
        host ? headers.merge("Host" => host) : headers
      end

      def request(method, url, body: nil, headers: {}, head_only: false, http_version: nil)
        cmd = Blink::HTTP::Adapter.request_command(
          method, url,
          body:         body,
          headers:      headers,
          http_version: http_version,
          tls_insecure: @tls_insecure,
          max_time:     10,
          include_headers: true
        )
        raw = @target.capture(cmd)
        parse(raw)
      rescue => e
        Response.new(0, {}, "curl/target error: #{e.message}")
      end

      # Parse `curl -i` output (HTTP/1.1 or HTTP/2, handles redirect blocks).
      def parse(raw)
        raw = raw.gsub("\r\n", "\n").gsub("\r", "\n")
        blocks = raw.split(/\n(?=HTTP\/)/)
        block  = blocks.last.to_s

        lines       = block.split("\n")
        status_line = lines.shift.to_s
        status      = status_line.split(" ")[1].to_i

        headers  = {}
        body_buf = []
        in_body  = false

        lines.each do |line|
          if !in_body && line.strip.empty?
            in_body = true
            next
          end
          if in_body
            body_buf << line
          else
            k, _, v = line.partition(":")
            headers[k.strip.downcase] = v.strip unless k.strip.empty?
          end
        end

        Response.new(status, headers, body_buf.join("\n").strip)
      end
    end
  end
end
