# frozen_string_literal: true

module Blink
  module EnvRefs
    ENV_REF_PATTERN = /\$\{([^}]+)\}/.freeze

    module_function

    def expand(value, context: "blink.toml value")
      value.to_s.gsub(ENV_REF_PATTERN) do
        var = Regexp.last_match(1)
        ENV.fetch(var) do
          raise Manifest::Error, "#{context} references ${#{var}} but it is not set in the environment or .env file"
        end
      end
    end
  end
end
