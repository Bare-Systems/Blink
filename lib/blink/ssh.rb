# frozen_string_literal: true

require "open3"
require "shellwords"
require "tempfile"

module Blink
  class SSHError < StandardError; end
end
