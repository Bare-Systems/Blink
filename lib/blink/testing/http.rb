# frozen_string_literal: true

require "shellwords"

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
    class HTTP
      def initialize(target)
        @target = target
      end

      def get(url, headers: {}, host: nil)
        request("GET", url, headers: with_host(headers, host))
      end

      def post(url, body: nil, headers: {}, host: nil)
        request("POST", url, body: body, headers: with_host(headers, host))
      end

      def head(url, headers: {}, host: nil)
        request("HEAD", url, headers: with_host(headers, host), head_only: true)
      end

      private

      def with_host(headers, host)
        host ? headers.merge("Host" => host) : headers
      end

      def request(method, url, body: nil, headers: {}, head_only: false)
        parts = %w[curl -sk --max-time 10 -i] + ["-X", method]
        headers.each { |k, v| parts += ["-H", "#{k}: #{v}"] }
        if body
          parts += ["-H", "Content-Type: application/json"] unless headers.key?("Content-Type")
          parts += ["--data-raw", body]
        end
        parts << url

        cmd = parts.map { |p| Shellwords.escape(p) }.join(" ")
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
