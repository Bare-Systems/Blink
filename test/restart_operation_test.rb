# frozen_string_literal: true

require_relative "test_helper"

class RestartOperationTest < BlinkTestCase
  FakeTarget = Struct.new(:commands, :config, keyword_init: true) do
    def run(cmd, abort_on_failure: true, tty: false)
      commands << { cmd: cmd, abort_on_failure: abort_on_failure, tty: tty }
      true
    end

    def script(_bash, abort_on_failure: true)
      commands << { cmd: "script", abort_on_failure: abort_on_failure }
      true
    end

    def description = "fake://target"
    def name = "fake"
  end

  def test_restart_supports_stop_plus_docker_services
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
        pipeline = ["stop", "docker"]

        [services.demo.stop]
        command = "echo stop"

        [services.demo.docker]
        name = "demo"
        image = "demo:local"
      TOML

      manifest = Blink::Manifest.load(manifest_path)
      fake_target = FakeTarget.new(commands: [], config: { "type" => "local" })
      manifest.define_singleton_method(:target!) { |_name| fake_target }

      result = Blink::Operations::Restart.new(manifest: manifest, service_name: "demo").call

      assert_equal ["stop", "docker"], result[:steps].map { |step| step[:step] }
      assert_equal "echo stop", fake_target.commands.first[:cmd]
      assert_match(/\Adocker run /, fake_target.commands.last[:cmd])
    end
  end
end
