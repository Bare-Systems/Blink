# frozen_string_literal: true

require "open3"
require "shellwords"
require "tempfile"

module Blink
  # Base class for any failure produced by a `Blink::Target` implementation.
  # Concrete targets raise a subclass (`LocalTargetError`, `SSHTargetError`) so
  # callers can either rescue the generic family (`TargetError`) or a specific
  # flavor. `SSHError` is preserved as an alias for `SSHTargetError` for
  # backward compatibility with pre-Sprint-E callers.
  class TargetError < StandardError; end
  class LocalTargetError < TargetError; end
  class SSHTargetError < TargetError; end

  SSHError = SSHTargetError
end
