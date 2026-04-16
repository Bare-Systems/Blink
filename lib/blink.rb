# frozen_string_literal: true

# ── Core ──────────────────────────────────────────────────────────────────────
require_relative "blink/version"
require_relative "blink/output"
require_relative "blink/response"
require_relative "blink/runtime"
require_relative "blink/env_refs"
require_relative "blink/toml"
require_relative "blink/ssh"
require_relative "blink/schema"
require_relative "blink/manifest"
require_relative "blink/http/adapter"

# ── Targets ───────────────────────────────────────────────────────────────────
require_relative "blink/targets/base"
require_relative "blink/targets/ssh_target"
require_relative "blink/targets/local_target"

# ── Sources ───────────────────────────────────────────────────────────────────
require_relative "blink/sources/base"
require_relative "blink/sources/containerized_local_build"
require_relative "blink/sources/github_release"
require_relative "blink/sources/local_build"
require_relative "blink/sources/url"

# ── Steps ─────────────────────────────────────────────────────────────────────
require_relative "blink/steps/base"
require_relative "blink/steps/fetch_artifact"
require_relative "blink/steps/shell"
require_relative "blink/steps/remote_script"
require_relative "blink/steps/provision"
require_relative "blink/steps/docker"
require_relative "blink/steps/stop"
require_relative "blink/steps/start"
require_relative "blink/steps/backup"
require_relative "blink/steps/install"
require_relative "blink/steps/health_check"
require_relative "blink/steps/rollback"
require_relative "blink/steps/verify"

# ── Testing framework ─────────────────────────────────────────────────────────
require_relative "blink/testing/suite"
require_relative "blink/testing/http"
require_relative "blink/testing/runner"
require_relative "blink/testing/reporter"
require_relative "blink/testing/inline_runner"

# ── Reusable operations ──────────────────────────────────────────────────────
require_relative "blink/operations"

# ── Runner + Planner ──────────────────────────────────────────────────────────
require_relative "blink/registry"
require_relative "blink/lock"
require_relative "blink/runner"
require_relative "blink/plan"
require_relative "blink/planner"

# ── Commands ──────────────────────────────────────────────────────────────────
require_relative "blink/commands/base"
require_relative "blink/commands/init"
require_relative "blink/commands/build"
require_relative "blink/commands/deploy"
require_relative "blink/commands/plan"
require_relative "blink/commands/test"
require_relative "blink/commands/validate"
require_relative "blink/commands/status"
require_relative "blink/commands/doctor"
require_relative "blink/commands/logs"
require_relative "blink/commands/restart"
require_relative "blink/commands/rollback"
require_relative "blink/commands/steps"
require_relative "blink/commands/report"
require_relative "blink/commands/ps"
require_relative "blink/commands/state"
require_relative "blink/commands/history"
require_relative "blink/commands/ssh_cmd"
require_relative "blink/commands/forward"

# ── MCP server (loaded lazily via --mcp flag in CLI) ──────────────────────────
# require_relative "blink/mcp_server"   # loaded on demand in cli.rb

# ── CLI (last — depends on everything above) ──────────────────────────────────
require_relative "blink/cli"
