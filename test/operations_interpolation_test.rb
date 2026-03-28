# frozen_string_literal: true

require_relative "test_helper"

class OperationsInterpolationTest < BlinkTestCase
  FakeTarget = Struct.new(:commands, keyword_init: true) do
    def reachable? = true
    def description = "fake://target"
    def name = "fake"

    def capture(cmd)
      commands << cmd
      "200"
    end
  end

  def test_status_resolves_health_check_template_values
    with_http_server(
      "/health" => ->(_request) { [200, { "Content-Type" => "text/plain" }, "ok"] }
    ) do |port|
      with_tmp_workspace do |workspace|
        manifest_path = File.join(workspace, "blink.toml")
        File.write(manifest_path, <<~TOML)
          [blink]
          version = "1"

          [targets.local]
          type = "local"
          runtime_dir = "#{workspace}"

          [services.demo]
          port = "#{port}"
          service_name = "demo"

          [services.demo.deploy]
          target = "local"
          pipeline = ["stop", "start"]

          [services.demo.stop]
          command = "true"

          [services.demo.start]
          command = "true"

          [services.demo.health_check]
          url = "http://127.0.0.1:{{port}}/health"
        TOML

        manifest = Blink::Manifest.load(manifest_path)
        result = Blink::Operations::Status.new(manifest: manifest, service_name: "demo").call

        assert_equal true, result[:services].first[:healthy]
        assert_equal "http://127.0.0.1:#{port}/health", result[:services].first[:url]
        refute_includes result[:services].first[:detail], "{{port}}"
      end
    end
  end

  def test_status_honors_health_check_http_version
    with_tmp_workspace do |workspace|
      manifest_path = File.join(workspace, "blink.toml")
      File.write(manifest_path, <<~TOML)
        [blink]
        version = "1"

        [targets.local]
        type = "local"

        [services.demo]
        service_name = "demo"

        [services.demo.deploy]
        target = "local"
        pipeline = ["stop", "start"]

        [services.demo.stop]
        command = "true"

        [services.demo.start]
        command = "true"

        [services.demo.health_check]
        url = "https://127.0.0.1:8443/health"
        http_version = "1.1"
      TOML

      manifest = Blink::Manifest.load(manifest_path)
      fake_target = FakeTarget.new(commands: [])
      manifest.define_singleton_method(:target!) { |_name| fake_target }

      result = Blink::Operations::Status.new(manifest: manifest, service_name: "demo").call

      assert_equal true, result[:services].first[:healthy]
      assert_includes fake_target.commands.first, "--http1.1"
    end
  end

  def test_restart_resolves_service_and_target_template_values
    with_tmp_workspace do |workspace|
      manifest_path = File.join(workspace, "blink.toml")
      restart_log = File.join(workspace, "restart.log")

      File.write(manifest_path, <<~TOML)
        [blink]
        version = "1"

        [targets.local]
        type = "local"
        runtime_dir = "#{workspace}"

        [services.demo]
        port = "4567"
        service_name = "demo"

        [services.demo.deploy]
        target = "local"
        pipeline = ["stop", "start"]

        [services.demo.stop]
        command = "echo stop {{service_name}} {{port}} >> {{runtime_dir}}/restart.log"

        [services.demo.start]
        command = "echo start {{service_name}} {{port}} >> {{runtime_dir}}/restart.log"
      TOML

      manifest = Blink::Manifest.load(manifest_path)
      result = Blink::Operations::Restart.new(manifest: manifest, service_name: "demo").call

      assert_equal %w[stop start], result[:steps].map { |step| step[:step] }
      assert_equal [
        "stop demo 4567",
        "start demo 4567"
      ], File.readlines(restart_log, chomp: true)
      refute result[:steps].any? { |step| step[:command].include?("{{") }
    end
  end
end
