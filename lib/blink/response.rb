# frozen_string_literal: true

require "json"

module Blink
  module Response
    module_function

    def build(success:, summary:, details: {}, next_steps: [])
      {
        success: success,
        summary: summary,
        details: details,
        next_steps: Array(next_steps),
      }
    end

    def dump(**kwargs)
      JSON.generate(build(**kwargs))
    end
  end
end
