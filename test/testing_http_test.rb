# frozen_string_literal: true

require_relative "test_helper"

class TestingHttpTest < BlinkTestCase
  FakeTarget = Struct.new(:commands, keyword_init: true) do
    def capture(cmd)
      commands << cmd
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    end
  end

  def test_http_client_can_force_http_1_1
    target = FakeTarget.new(commands: [])
    client = Blink::Testing::HTTP.new(target)

    response = client.get("https://127.0.0.1:8443/health", http_version: "1.1")

    assert_equal 200, response.status
    assert_includes target.commands.first, "--http1.1"
  end
end
