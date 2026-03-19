# frozen_string_literal: true

require_relative "test_helper"

class TargetsEnvTest < BlinkTestCase
  def test_local_target_capture_injects_environment_variables
    target = Blink::Targets::LocalTarget.new(
      "local",
      "type" => "local",
      "env" => { "BLINK_TARGET_ENV" => "from-target" }
    )

    output = target.capture('printf %s "$BLINK_TARGET_ENV"')

    assert_equal "from-target", output
  end

  def test_schema_accepts_target_environment_tables
    data = {
      "blink" => { "version" => "1" },
      "targets" => {
        "local" => {
          "type" => "local",
          "env" => { "FOO" => "bar" }
        }
      },
      "services" => {
        "demo" => {
          "deploy" => {
            "target" => "local",
            "pipeline" => ["shell"]
          },
          "shell" => {
            "command" => "true"
          }
        }
      }
    }

    result = Blink::Schema.validate(data)

    assert result.valid?, result.errors.map(&:message).join("\n")
  end
end
