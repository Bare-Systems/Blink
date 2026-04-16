# frozen_string_literal: true

require "stringio"

module Blink
  # Shared runtime helpers used by CLI commands and the MCP server.
  #
  # Commands previously each defined their own `capture_output` and ANSI_STRIP
  # constant; they now share this implementation.
  module Runtime
    ANSI_STRIP = /\e\[[0-9;]*[mGKHF]/.freeze

    module_function

    # Capture stdout (and optionally stderr) produced while the block runs.
    # Returns `[output_string, block_return_value]`. ANSI escape sequences are
    # stripped from the captured text by default.
    #
    # `capture_stderr:` — include stderr in the captured string (default true).
    #   MCP server passes false so its stderr logging channel stays live.
    # `normalize_encoding:` — force UTF-8 on the captured bytes (default true).
    def capture_output(strip_ansi: true, capture_stderr: true, normalize_encoding: true)
      old_stdout = $stdout
      old_stderr = $stderr if capture_stderr
      captured_out = StringIO.new
      captured_err = StringIO.new if capture_stderr
      $stdout = captured_out
      $stderr = captured_err if capture_stderr
      result = yield
      parts = [captured_out.string]
      parts << captured_err.string if capture_stderr
      output = parts.reject(&:empty?).join
      output = output.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") if normalize_encoding
      output = output.gsub(ANSI_STRIP, "") if strip_ansi
      [output, result]
    ensure
      $stdout = old_stdout
      $stderr = old_stderr if capture_stderr
    end
  end
end
