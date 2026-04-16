# frozen_string_literal: true

require "json"

module Blink
  module Commands
    # Base class providing shared plumbing for CLI commands:
    #   - stdout/stderr capture (via Blink::Runtime.capture_output)
    #   - standardized JSON response envelope
    #   - consistent rescue behavior for Manifest::Error and SSHError
    #
    # Subclasses stay in control of their own option parsing and `run` flow;
    # they opt in to the helpers below where useful. This keeps the migration
    # low-risk and avoids reshaping command I/O semantics.
    class Base
      # Wrap a block, capturing its stdout/stderr. Delegates to
      # Blink::Runtime.capture_output so every command shares one implementation.
      def capture_output(strip_ansi: true, &block)
        Runtime.capture_output(strip_ansi: strip_ansi, &block)
      end

      # Emit a success envelope to stdout.
      def emit_success(summary:, details:, next_steps: [])
        puts Response.dump(
          success:    true,
          summary:    summary,
          details:    details,
          next_steps: next_steps
        )
      end

      # Emit a failure envelope to stdout.
      def emit_failure(summary:, details:, next_steps: [])
        puts Response.dump(
          success:    false,
          summary:    summary,
          details:    details,
          next_steps: next_steps
        )
      end

      # Emit a standard error envelope derived from an exception, then exit.
      # `next_steps` is required because the right remediation is per-command.
      def emit_exception_and_exit(exception, service:, next_steps:, prefix: nil, code: 1)
        summary = prefix ? "#{prefix}: #{exception.message}" : exception.message
        emit_failure(
          summary:    summary,
          details:    { service: service, error: exception.message },
          next_steps: Array(next_steps)
        )
        exit code
      end
    end
  end
end
