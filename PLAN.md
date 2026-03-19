# Blink — Project Plan

## Vision

Blink is an **AI-first, declarative CI/CD operations tool** built in Ruby. It is a general-purpose engine for deploying, testing, and monitoring services — designed to be driven by both humans and AI agents with minimal input.

Think of it as Terraform for operational actions: you declare _what_ should happen (services, targets, steps, verifiers), and Blink figures out how to make it happen — then reports back in a form both humans and agents can understand.

Blink exposes a **CLI for humans** and a **stdio/MCP interface for AI agents**, using the same declarative engine underneath.

---

## Problem It Solves

The existing homelab `blink` CLI is a working but hardcoded CD tool — service definitions, deployer logic, test suites, and configuration are all tightly coupled in Ruby source files. To add a new service or target environment, you edit Ruby.

The new Blink inverts that model:

- **Config-driven, not code-driven.** Services, targets, pipelines, and verifiers are declared in a manifest (TOML). No Ruby changes needed for new services.
- **General-purpose, not homelab-specific.** Any service, any target (SSH host, Docker, local), any environment.
- **AI-native from day one.** The MCP/stdio interface is a first-class citizen — not bolted on. Agents get structured, machine-readable responses and can drive the full pipeline.
- **Minimal input, maximum inference.** Given a service name and a target, Blink should be able to infer a reasonable pipeline and run it.

---

## Core Concepts

### 1. Manifest (`blink.toml`)

The declarative source of truth. Defines everything Blink needs to operate:

```toml
[blink]
version = "1"

[targets.homelab]
type = "ssh"
host = "blink"
user = "admin"

[targets.local]
type = "local"

[services.tardigrade]
description = "TLS-terminating reverse proxy"
source = { type = "github_release", repo = "Bare-Labs/Tardigrade" }

[services.tardigrade.deploy]
target = "homelab"
pipeline = ["fetch_artifact", "stop", "install", "start", "verify"]

[services.tardigrade.verify]
suite = "suites/tardigrade.rb"
tags = ["smoke", "health"]
```

Manifests are:
- **Composable** — a root manifest can include service manifests from subdirectories
- **Environment-aware** — values can be overridden per target
- **Secret-safe** — no secrets in manifests; secrets come from env vars or a referenced secrets backend

---

### 2. Targets

A **target** is a runtime environment where operations execute. Targets are declared in the manifest and referenced by services.

| Target Type | Description |
|-------------|-------------|
| `ssh` | Operations run over SSH on a remote host |
| `local` | Operations run on the local machine |
| `docker` | Operations target a Docker daemon (local or remote) |
| `mcp` | Operations are delegated to a BearClaw/MCP gateway |

Targets can define:
- Connection parameters (host, user, key path)
- Environment variables to inject during operations
- Working directory / base path

---

### 3. Pipelines

A **pipeline** is an ordered sequence of named steps. Each step is a built-in or user-defined action.

**Built-in step types:**

| Step | Description |
|------|-------------|
| `fetch_artifact` | Download release artifact from source (GitHub, local build, Docker pull) |
| `build` | Build artifact locally (e.g., Docker cross-compile) |
| `stop` | Stop the running service |
| `backup` | Snapshot current binary/state before deploy |
| `install` | Place artifact, update symlinks, set permissions |
| `migrate` | Run database migrations (configurable per service) |
| `start` | Start/restart the service (systemd, Docker, process) |
| `health_check` | Wait for service to respond on expected port/path |
| `verify` | Run the test suite (see Verifiers) |
| `rollback` | Restore from backup; restart previous version |
| `notify` | Emit a structured event (webhook, stdout, MCP response) |
| `shell` | Run an arbitrary command on the target |

Pipelines declare their rollback path. If any step fails, Blink executes the rollback pipeline automatically.

**Example pipeline declaration:**

```toml
[services.ekho-server.deploy]
target = "homelab"
pipeline = ["fetch_artifact", "stop", "backup", "install", "migrate", "start", "health_check", "verify"]
rollback_pipeline = ["stop", "restore_backup", "start", "health_check"]
```

---

### 4. Sources (Artifact Providers)

A **source** defines where the deployable artifact comes from.

| Source Type | Description |
|-------------|-------------|
| `github_release` | Fetch latest (or pinned) release from GitHub |
| `gitlab_release` | Fetch latest (or pinned) release from GitLab |
| `docker_image` | Pull image from Docker Hub or registry |
| `local_build` | Build locally (with optional Docker cross-compile) |
| `oci` | Pull from any OCI-compliant registry |
| `url` | Fetch from an arbitrary URL |

Sources support:
- **Version pinning** — `version = "latest"` or `version = "1.2.3"`
- **Platform targeting** — automatically select the right binary for the target arch
- **Token auth** — via env var reference (e.g., `token_env = "GITHUB_TOKEN"`)

---

### 5. Verifiers (Test Suites)

A **verifier** validates that a service is working correctly after deployment. Verifiers are tagged test suites written in a simple Ruby DSL (extracted and generalized from the current blink testing framework).

**Test suite DSL:**

```ruby
Blink::Suite.define("tardigrade") do
  tag :smoke
  http_get "https://{{host}}:{{port}}/" do
    status 200
    header "server", match: /tardigrade/i
  end

  tag :health
  http_get "https://{{host}}:{{port}}/_health" do
    status 200
    body_json { |j| j["status"] == "ok" }
  end

  tag :security
  http_get "https://{{host}}:{{port}}/" do
    header "strict-transport-security", present: true
    header "x-content-type-options", eq: "nosniff"
  end
end
```

Variables (`{{host}}`, `{{port}}`) are resolved from the target's config at runtime.

Verifiers support:
- **Tag-based selection** — run only `@smoke` or `@e2e` tags
- **Parallel execution** — tests in a suite can run concurrently
- **Structured output** — results are machine-readable (JSON) and human-readable (table)
- **MCP-native results** — when invoked via MCP, results include pass/fail counts, failed test names, and suggested next steps

---

### 6. Service Registry

Services are declared in the manifest, but Blink maintains a **runtime registry** that resolves:
- Which pipeline to run for a given operation
- Which source to pull artifacts from
- Which target to deploy to
- Which verifier suite to run

The registry is lazily loaded and hot-reloadable — changes to `blink.toml` take effect on next invocation.

---

## Interfaces

### CLI (Human Interface)

```
blink deploy <service> [--target <target>] [--version <ver>] [--dry-run] [--local]
blink test <service> [--tags <tag,...>] [--target <target>] [--list]
blink status [<service>] [--target <target>]
blink doctor [--target <target>]
blink logs <service> [--follow] [--lines N]
blink restart <service> [--target <target>]
blink rollback <service> [--target <target>]
blink plan <service>          # Show what deploy would do (like terraform plan)
blink ps [--target <target>]
blink top [--target <target>] [--watch [N]]
blink ssh [--target <target>]
```

CLI design principles:
- Short, predictable command names
- `--dry-run` everywhere that mutates state
- `--json` flag on any command for machine-readable output
- Exit codes are meaningful (0 = success, 1 = failure, 2 = partial)
- No interactive prompts by default (safe for agent invocation)

---

### MCP / stdio Interface (Agent Interface)

Blink exposes all operations as **MCP tools** via stdio transport. An AI agent (e.g., Claude via BearClaw) can:
- List available services and their current status
- Deploy a service and get a structured result
- Run test suites and get pass/fail details
- Tail logs
- Roll back a failed deploy
- Query the manifest for service definitions

**MCP tool definitions (examples):**

```json
{
  "name": "blink_deploy",
  "description": "Deploy a service using the declared pipeline. Returns structured result including steps executed, any failures, and verification output.",
  "inputSchema": {
    "service": "string",
    "target": "string (optional, uses service default)",
    "version": "string (optional, default: latest)",
    "dry_run": "boolean (optional)"
  }
}
```

```json
{
  "name": "blink_test",
  "description": "Run verification suite for a service. Returns structured pass/fail results per test.",
  "inputSchema": {
    "service": "string",
    "tags": "array of strings (optional)",
    "target": "string (optional)"
  }
}
```

```json
{
  "name": "blink_status",
  "description": "Get current operational status of one or all services on a target.",
  "inputSchema": {
    "service": "string (optional, omit for all)",
    "target": "string (optional)"
  }
}
```

MCP design principles:
- Every tool response includes a `success` boolean and a `summary` string (for agents that need a quick answer)
- Failures always include a `suggested_next_step` field
- All tool responses are valid JSON
- The MCP server starts via `blink --mcp` (stdio transport)

---

## Architecture

```
blink/
├── bin/
│   └── blink                    # Entry point: CLI or --mcp mode
├── lib/
│   └── blink/
│       ├── cli.rb               # CLI command routing
│       ├── mcp_server.rb        # stdio MCP server (tool dispatch)
│       ├── manifest.rb          # TOML manifest loader + validator
│       ├── registry.rb          # Runtime service registry
│       ├── runner.rb            # Pipeline executor
│       ├── planner.rb           # Plan generation (dry-run / terraform-plan analog)
│       ├── targets/
│       │   ├── base.rb
│       │   ├── ssh_target.rb
│       │   ├── local_target.rb
│       │   ├── docker_target.rb
│       │   └── mcp_target.rb
│       ├── sources/
│       │   ├── base.rb
│       │   ├── github_release.rb
│       │   ├── gitlab_release.rb
│       │   ├── docker_image.rb
│       │   └── local_build.rb
│       ├── steps/
│       │   ├── base.rb
│       │   ├── fetch_artifact.rb
│       │   ├── build.rb
│       │   ├── stop.rb
│       │   ├── install.rb
│       │   ├── start.rb
│       │   ├── health_check.rb
│       │   ├── migrate.rb
│       │   ├── backup.rb
│       │   ├── rollback.rb
│       │   ├── notify.rb
│       │   └── shell.rb
│       ├── testing/
│       │   ├── suite.rb         # Suite DSL
│       │   ├── runner.rb        # Test executor (parallel)
│       │   ├── http.rb          # HTTP assertion helpers
│       │   └── reporter.rb      # Human + JSON output
│       ├── output.rb            # Terminal formatting
│       ├── ssh.rb               # SSH client wrapper
│       └── version.rb
├── blink.toml                   # Default manifest (project root)
└── Gemfile
```

---

## Configuration Model

### Manifest hierarchy

Blink resolves configuration by merging:

1. **Project manifest** (`blink.toml` in working dir)
2. **User manifest** (`~/.config/blink/blink.toml`)
3. **Environment overrides** (`BLINK_*` env vars)

Later layers win. This allows Joe's local machine to have homelab connection details without committing them to any repo.

### Secrets

Secrets are **never in manifests**. They are referenced by env var name:

```toml
[targets.homelab]
type = "ssh"
host = "blink"
ssh_key_env = "BLINK_SSH_KEY"  # optional; falls back to ssh-agent

[sources.github]
token_env = "GITHUB_TOKEN"
```

### Example: homelab manifest (`blink.toml`)

```toml
[blink]
version = "1"

[targets.homelab]
type    = "ssh"
host    = "blink"
user    = "admin"
base    = "/home/admin/baresystems"

[targets.local]
type = "local"

# --- Tardigrade ---
[services.tardigrade]
description = "TLS-terminating reverse proxy"

[services.tardigrade.source]
type    = "github_release"
repo    = "Bare-Labs/Tardigrade"
asset   = "tardigrade-linux-amd64"

[services.tardigrade.deploy]
target   = "homelab"
pipeline = ["fetch_artifact", "stop", "backup", "install", "start", "health_check", "verify"]
rollback_pipeline = ["stop", "restore_backup", "start"]

[services.tardigrade.start]
command = "sudo systemctl start tardigrade"

[services.tardigrade.stop]
command = "sudo systemctl stop tardigrade"

[services.tardigrade.verify]
suite = "suites/tardigrade.rb"
tags  = ["smoke", "health"]

# --- BearClaw ---
[services.bearclaw]
description = "AI DevOps agent"

[services.bearclaw.source]
type   = "github_release"
repo   = "Bare-Labs/BearClaw"
asset  = "bearclaw-linux-amd64"

[services.bearclaw.deploy]
target   = "homelab"
pipeline = ["fetch_artifact", "stop", "backup", "install", "start", "health_check", "verify"]

[services.bearclaw.verify]
suite = "suites/bearclaw.rb"
tags  = ["smoke"]

# --- Ursa ---
[services.ursa]
description = "C2 framework"

[services.ursa.source]
type  = "docker_image"
image = "ghcr.io/bare-labs/ursa-major"

[services.ursa.deploy]
target   = "homelab"
pipeline = ["fetch_artifact", "stop", "install", "start", "health_check", "verify"]

[services.ursa.start]
command = "docker compose up -d ursa-major"

[services.ursa.stop]
command = "docker compose down ursa-major"

[services.ursa.verify]
suite = "suites/ursa.rb"
tags  = ["smoke"]
```

---

## Migration from Homelab Blink

The new Blink should be able to fully replace the existing homelab `blink` Ruby CLI. Migration path:

### Phase 1 — Core engine + manifest (MVP)

- [ ] TOML manifest loader (`manifest.rb`) with schema validation
- [ ] SSH target implementation (port existing `ssh.rb`)
- [ ] `fetch_artifact` step (port existing GitHub release fetcher)
- [ ] `install`, `start`, `stop`, `backup`, `rollback` steps
- [ ] `health_check` step (HTTP poll with timeout/retries)
- [ ] CLI: `deploy`, `status`, `doctor`, `logs`, `restart`, `ps`, `ssh`
- [ ] Test suite runner (port existing testing DSL)
- [ ] `verify` step (runs test suite)
- [ ] JSON output mode (`--json`)
- [ ] `--dry-run` / `plan` command

**Done when:** Can deploy tardigrade and bearclaw via `blink deploy tardigrade` using a `blink.toml` — replacing the equivalent hardcoded deployers.

### Phase 2 — MCP interface

- [ ] stdio MCP server (`mcp_server.rb`)
- [ ] MCP tool: `blink_deploy`
- [ ] MCP tool: `blink_test`
- [ ] MCP tool: `blink_status`
- [ ] MCP tool: `blink_logs`
- [ ] MCP tool: `blink_rollback`
- [ ] MCP tool: `blink_list_services`
- [ ] Structured JSON responses with `success`, `summary`, `suggested_next_step`
- [ ] `blink --mcp` startup mode

**Done when:** BearClaw (or Claude) can drive a full deploy + verify cycle via MCP tools without touching the CLI.

### Phase 3 — Additional sources + steps

- [ ] GitLab release source
- [ ] Docker image source (pull + docker compose orchestration)
- [ ] `local_build` source (Docker cross-compile for Zig/other)
- [ ] `migrate` step (configurable migration command)
- [ ] `notify` step (webhook / stdout event)
- [ ] `shell` step (arbitrary command on target)
- [ ] Parallel test execution in suites

### Phase 4 — Ekho + multi-service

- [ ] Ekho service definitions in manifest (server, web-app, postgres)
- [ ] Ekho test suite (`suites/ekho_server.rb`, etc.)
- [ ] PostgreSQL migration step support
- [ ] Multi-service dependency ordering (deploy postgres before server)

### Phase 5 — Extensibility + polish

- [ ] User-defined step plugins (Ruby files in `steps/` dir)
- [ ] User-defined source plugins
- [ ] Multiple concurrent target support
- [ ] `blink diff` — show config drift between declared and actual state
- [x] `blink init` — scaffold a `blink.toml` with local target + declarative API/UI verifier examples
- [ ] CI-mode output (GitHub Actions / GitLab CI annotations)
- [ ] MCP tool: `blink_plan` (returns plan as structured data)

---

## Design Constraints

- **Zero runtime gem dependencies** — stdlib only (open-uri, net/http, etc.). Dev deps (rspec, rubocop) are fine.
- **Ruby 3.x minimum**
- **No proprietary homelab details in this repo** — the `blink.toml` that defines Joe's homelab lives locally and is never committed here. This repo ships the engine only.
- **Manifest is the contract** — Blink never infers behavior from filesystem conventions or repo structure. Everything must be declared.
- **Idempotent by default** — running `blink deploy` twice should be safe.
- **Agent-safe CLI** — no interactive prompts, no TTY requirements, predictable exit codes. The CLI must be drivable by a script or agent without modification.
- **Rollback is always defined** — if a pipeline doesn't declare a rollback, Blink warns at plan time.

---

## Relationship to Homelab Blink

The existing `Homelab/blink/` CLI is the working reference implementation. It is:
- The concrete use case that drives requirements
- The source of the test suite DSL and SSH client code to port
- The deployer logic to extract into declarative step implementations

The new Blink should make the `Homelab/blink/` deployer code unnecessary — replacing it with a `blink.toml` manifest and reusable step implementations.

Homelab-specific suites (`suites/*.rb`) remain in `Homelab/` (private) and are referenced by the homelab-local `blink.toml`. They are not part of this repo.

---

## Success Criteria

- [ ] `blink deploy tardigrade` works end-to-end against the homelab using only `blink.toml` config
- [ ] `blink test tardigrade --tags smoke` produces structured pass/fail output
- [ ] An AI agent (Claude via BearClaw MCP) can invoke `blink_deploy` and `blink_test` over stdio and get actionable responses
- [ ] Adding a new service requires only editing `blink.toml` — no Ruby changes
- [ ] `--dry-run` / `plan` accurately describes what would happen without mutating state
- [ ] The tool works on a fresh machine with only `gem install` (dev deps) and a valid `blink.toml`
