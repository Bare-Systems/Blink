# Blink

Blink is a declarative deploy, test, rollback, and reporting CLI driven by `blink.toml`.

Today, the repo ships a working Ruby engine for:

- manifest validation and planning
- deploy and rollback pipelines
- local and SSH targets
- artifact fetching from `local_build`, `github_release`, and `url` sources
- Ruby and declarative inline verification suites
- persisted `.blink/` state, history, and artifact metadata
- static report generation
- a current agent/tool server via `--mcp`

This README documents the feature set that exists in the codebase now. Active unfinished work is tracked in the workspace root `ROADMAP.md`.

## Quick Start

Generate a starter manifest:

```sh
bin/blink init --service app
```

That scaffold produces a local-target manifest shaped like this:

```toml
[blink]
version = "1"

[targets.local]
type = "local"

[services.app]
description = "Replace this with a short service description"
port = "3000"

[services.app.source]
type = "local_build"
command = "make build"
artifact = "dist/app"

[services.app.deploy]
target = "local"
pipeline = ["fetch_artifact", "stop", "install", "start", "health_check", "verify"]
rollback_pipeline = ["stop", "rollback", "start"]

[services.app.install]
dest = "/opt/app/app"

[services.app.stop]
command = "systemctl stop app"

[services.app.start]
command = "systemctl start app"

[services.app.health_check]
url = "http://127.0.0.1:{{port}}/health"

[services.app.verify]
tags = ["smoke"]
```

Typical workflow:

```sh
bin/blink validate --json
bin/blink plan app --json
bin/blink deploy app --json
bin/blink test app --json
bin/blink state app --json
bin/blink history app --json
bin/blink report generate --format html --json
```

## Command Surface

Current top-level commands:

- `init`: scaffold a starter `blink.toml`
- `validate`: schema-check a manifest and report actionable errors
- `plan`: expand a service into a resolved deploy plan with warnings and blockers
- `deploy`: execute the declared pipeline and persist run history
- `test`: run Ruby suites and/or declarative inline checks
- `status`: inspect service health on a target
- `doctor`: run connectivity and basic host health checks
- `logs`: fetch or stream service logs
- `restart`: restart a service using stop/start or restart commands
- `rollback`: run the declared rollback pipeline
- `steps`: inspect built-in step definitions
- `ps`: show Docker containers on a target
- `state`: read persisted `.blink` state
- `history`: read recent or specific recorded runs
- `report generate`: write static HTML or JSON reports from `.blink` history
- `ssh`: open an interactive SSH session to an SSH target

Most commands support `--json`. `blink validate` exits with code `2` for manifest validation errors.

## Manifest Model

Blink manifests are TOML with three core sections:

- `[blink]`: manifest metadata
- `[targets.<name>]`: runtime environments
- `[services.<name>]`: service configuration, sources, steps, and verification

Parent manifests can also compose child manifests with `blink.includes`:

```toml
[blink]
version = "1"
includes = [
  "BearClaw/blink.toml",
  "BearClawWeb/blink.toml",
  "Polar/blink.toml",
]

[targets.homelab]
type = "ssh"
host = "blink"
user = "admin"

[services.stack]
description = "Workspace-wide verification"

[services.stack.deploy]
target = "homelab"
pipeline = ["verify"]

[services.stack.verify.tests.edge]
type = "shell"
command = "echo ok"
expect_output = "ok"
```

Included services keep resolving relative source paths, suite files, scripts, and build mounts against their child manifest directory. That lets a workspace root manifest import repo-local service manifests and still run `blink test`, `blink build`, `blink plan`, or `blink deploy` from the parent.

Minimal required shape:

```toml
[blink]
version = "1"

[targets.local]
type = "local"

[services.app.deploy]
target = "local"
pipeline = ["verify"]

[services.app.verify]
suite = "suite.rb"
```

Blink currently resolves manifests by:

1. explicit path argument when supported
2. `BLINK_MANIFEST`
3. `blink.toml` in the current directory or a parent directory
4. `~/.config/blink/blink.toml`

A `.env` file in the manifest directory is also loaded when the manifest is read.

## Targets

Supported target types today:

- `local`: runs commands on the local machine
- `ssh`: runs commands over `ssh` and transfers files with `scp`

Target features currently implemented:

- optional `base` directory
- optional `env` table injected into target commands
- target overrides with `--target`

Example:

```toml
[targets.prod]
type = "ssh"
host = "prod.example.com"
user = "deploy"
base = "/srv/app"

[targets.prod.env]
RACK_ENV = "production"
```

## Sources

Supported source types today:

### `containerized_local_build`

Runs a local `docker run` with bind-mounted workspace access, then stages or caches the host-side artifact.

```toml
[services.app.source]
type = "containerized_local_build"
image = "docker:cli"
mount = ".:/workspace"
workdir = "/workspace"
command = "docker buildx build --platform linux/amd64 --load -t app:local . && docker save app:local | gzip -c > dist/app-image.tar.gz"
artifact = "dist/app-image.tar.gz"
docker_socket = true
platform = "linux/amd64"

[services.app.source.env]
TARGET_PLATFORM = "linux/amd64"
```

Optional fields:

- `env`
- `env_file`
- `platform`
- `docker_socket`
- `pull`
- `entrypoint`
- `user`

`mount` accepts either a single `host:container[:mode]` string or an array of mount specs.

### `local_build`

Runs a local build command, then stages or caches the artifact.

```toml
[services.app.source]
type = "local_build"
workdir = "."
command = "bin/build"
artifact = "dist/app.tar.gz"

[services.app.source.env]
GOOS = "linux"
```

`local_build` also supports named builds under `source.builds` plus `source.default`.

### `github_release`

Fetches a release asset from GitHub and caches it by tag and asset name.

```toml
[services.app.source]
type = "github_release"
repo = "owner/name"
asset = "app-linux-amd64.tar.gz"
token_env = "GITHUB_TOKEN"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
checksum_asset = "checksums.txt"
signature_asset = "app-linux-amd64.tar.gz.minisig"
verify_command = "minisign -Vm {{artifact}} -x {{signature}} -P /path/to/minisign.pub"
```

Supported integrity and provenance options:

- literal `sha256`
- release `checksum_asset`
- release `signature_asset` plus `verify_command`

### `url`

Fetches an artifact from `file://`, `http://`, or `https://`.

```toml
[services.app.source]
type = "url"
url = "https://downloads.example.com/app-{{version}}.tar.gz"
artifact = "app.tar.gz"
token_env = "DOWNLOAD_TOKEN"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
checksum_url = "https://downloads.example.com/app-{{version}}.sha256"
signature_url = "https://downloads.example.com/app-{{version}}.minisig"
verify_command = "minisign -Vm {{artifact}} -x {{signature}} -P /path/to/minisign.pub"
timeout_seconds = 30
retry_count = 2
retry_backoff_seconds = 1

[services.app.source.headers]
X-Trace = "blink"

[services.app.source.cache]
ttl_seconds = 300
```

Current `url` behavior:

- caches artifacts under `.blink/artifacts/<service>/`
- supports TTL-based reuse for HTTP downloads
- revalidates cached HTTP artifacts with `ETag` and `Last-Modified` when available
- blocks insecure `http://` sources unless `allow_insecure = true`
- supports checksum and detached-signature verification

## Built-in Steps

Blink currently ships these built-in steps:

- `fetch_artifact`
- `stop`
- `backup`
- `install`
- `start`
- `health_check`
- `verify`
- `rollback`
- `shell`
- `remote_script`
- `docker`
- `provision`

Use `bin/blink steps` or `bin/blink steps <name>` to inspect their current descriptions, supported targets, rollback behavior, and config sections.

## Verification

Blink supports two verification styles:

- Ruby suite files via `verify.suite`
- declarative inline tests via `verify.tests.*`

Both can be used together. Inline tests run first, then the Ruby suite.

Example inline checks:

```toml
[services.app.verify]
tags = ["smoke"]

[services.app.verify.tests.api-health]
type = "api"
url = "http://127.0.0.1:{{port}}/health"

[services.app.verify.tests.api-health.checks.status]
type = "status"
equals = 200

[services.app.verify.tests.api-health.checks.status_json]
type = "json"
path = "$.status"
equals = "ok"

[services.app.verify.tests.ui-home]
type = "ui"
url = "http://127.0.0.1:{{port}}/"

[services.app.verify.tests.ui-home.checks.root]
type = "selector"
engine = "css"
selector = "#app"

[services.app.verify.tests.ui-home.checks.ready]
type = "text"
contains = "Ready"
```

Supported inline test types:

- `api` / `http`
- `ui`
- `shell`
- `mcp`
- `script`

Supported inline check types:

- `status`
- `body`
- `header`
- `json`
- `selector`
- `text`

Notes:

- UI selector checks use Nokogiri when available.
- `script` tests run locally.
- `shell` and HTTP-based checks run against the selected target.

## Planning, State, and Reports

`blink plan` resolves and reports:

- target selection
- ordered pipeline steps
- rollback pipeline
- source security posture
- warnings
- blockers
- deterministic config hash

Blink persists run data under `.blink/`:

- `.blink/state/current.json`
- `.blink/state/recent_runs.json`
- `.blink/history/<run_id>.json`
- `.blink/artifacts/<service>/...`
- `.blink/reports/latest.html`
- `.blink/reports/latest.json`

Persisted data includes:

- deploy, rollback, and test summaries
- per-step results
- target and runtime metadata
- artifact SHA-256, cache metadata, and verification metadata
- recent run indexing for `state`, `history`, and `report generate`

## Agent / MCP Mode

Blink includes a current tool server behind:

```sh
bin/blink --mcp
```

It exposes tool handlers for:

- `blink_list_services`
- `blink_plan`
- `blink_deploy`
- `blink_test`
- `blink_status`
- `blink_logs`
- `blink_restart`
- `blink_ps`
- `blink_steps`
- `blink_state`
- `blink_history`
- `blink_rollback`
- `blink_doctor`

Current note: the codebase exposes an MCP-style JSON-RPC tool surface over stdio for local agent integration. Transport hardening and interoperability polish are still being tracked in the project plan.

## Current Boundaries

The README should stay honest about what is not implemented yet in this repo.

Not shipped today:

- Docker or MCP target types
- GitLab, OCI, or Docker image source types
- user-defined step or source plugins
- load testing
- parallel verifier execution
- drift detection or diff commands

Operational notes for the current implementation:

- `status`, `doctor`, and `ps` are target-centric commands. In multi-target manifests, pass `--target` explicitly when you want to inspect a specific target.
- `blink init` scaffolds examples for deploy, health-check, and inline API/UI verification, but you still need to replace the build and runtime commands with real ones.
- If you want authenticated GitHub API requests, set `GITHUB_TOKEN` or `GH_TOKEN`.

## Development

Run the test suite directly with Ruby:

```sh
ruby -Itest -Ilib -e 'Dir["test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

If you use Bundler, make sure development gems are installed first.
