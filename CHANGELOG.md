# Changelog

All notable changes to Blink are documented here.

## [Unreleased]

### Added

- **`skip_build` flag on `blink_deploy`** — New optional boolean parameter for both the CLI and MCP tool. When `true`, the `fetch_artifact` step is skipped and the most recently cached artifact path is restored from state. This solves the MCP timeout problem for services with long Docker builds (e.g. Python images on Apple Silicon): run `blink build` once to cache the artifact, then call `blink deploy --skip-build` (or `blink_deploy` with `skip_build: true`) for fast, build-free deploys. The cached artifact path is read from `last_deploy.artifact.path` in `.blink/state/current.json`.

- **`provision.env_file.always_update`** — New optional key on `env_file` blocks. Takes an array of seed key names that are force-synced on every deploy, even when the env file already exists. Uses a strip-and-append strategy (`grep -v` + `printf` + atomic `mv`) that is safe for values with special characters (base64 tokens, `+`, `=`, `/`). Keys not listed in `always_update` continue to use the existing "seed once" behaviour. Schema validation added for the new field.

### Changed

- Blink Stage 2B MVP is now in place:
  - Added `${VAR}` env-ref expansion helpers for target env, source env, inline test headers, URL source headers, and provision seed values so manifest-managed secrets resolve from the runtime environment instead of being stored inline.
  - Schema validation now rejects hardcoded secret-like values in target env, source env, and provision seed tables with clear parse-time errors.
  - `blink_test` now returns per-service pass/fail summaries in both CLI JSON and MCP responses via `service_results`.
  - Added a committed two-service Tardigrade + BearClaw fixture manifest plus coverage for real-manifest deploy idempotence, structured `blink_status`, structured `blink_test`, and MCP `tools/list` schema publication for the Stage 2B tool set.
- **HTTP adapter + TLS-verify-by-default (Sprint D). BREAKING.** All curl-based HTTP traffic (health checks, inline tests, `Status` and `Doctor` probes) now flows through `Blink::HTTP::Adapter`, which enforces TLS verification by default. The previous behavior (`curl -k` / `-sk` / `-sfk` scattered across callsites) is gone. To keep hitting self-signed endpoints, opt in explicitly per service or per test:

  ```toml
  [services.myapp.health_check]
  url = "https://tardigrade.local/myapp/health"
  tls_insecure = true

  [services.myapp.verify.tests.smoke]
  type = "http"
  url = "https://tardigrade.local/myapp"
  tls_insecure = true
  ```

  Both the schema validator and the planner warn when `tls_insecure = true` is set, so the insecure posture is always visible in `blink plan`. Homelab services behind Tardigrade will need `tls_insecure = true` added to their health checks and inline tests until a proper cert chain is in place. Adapter tests land in `test/http_adapter_test.rb`.
- **Semantic nucleus + sources split + plugin autoload (Sprint F.1–F.3).**
  - Introduced `Blink::Semantic` — a small module of plain data structs (`OperationPlan`, `OperationResult`, `StepResult`, `ArtifactRef`, `Diagnostic`, `Diagnostics`) that describe an operation end-to-end. These are the single source of truth the CLI renderer and MCP server will serialize from as callsites migrate; existing hash-shaped payloads continue to work unchanged during the transition. `StepResult` carries Ansible-style `changed` / `idempotent` flags; `OperationResult` aggregates them into `changed?` / `no_op?` predicates.
  - Split `Blink::Sources::Base` into two focused mixins: `Blink::Sources::Cache` (fetch_with_cache, cache sidecar metadata, TTL / reuse policy) and `Blink::Sources::Verification` (SHA-256 checksum + signature verification, SHA256SUMS-style document parsing, verify-command template rendering). `Sources::Base` now does nothing more than `include Cache; include Verification` plus hold the minimal shared plumbing (`temp_artifact_path`, `execute_command!`, `stringify_env`, `raise_source_error`). Concrete sources are unchanged — the split is purely structural and fully tested.
  - Added a plugin autoload path. `Blink::Plugins.autoload!` runs on require and loads every `.rb` under `lib/blink/plugins/` plus any directories on `$BLINK_PLUGIN_PATH` (colon-separated). Plugins register via the existing public registries (`Blink::Sources.register`, `Blink::Steps.register`, `InlineRunner.register`) and — thanks to Sprint E's registry-driven schema — participate in manifest validation automatically, with no Schema edits. Broken plugins are logged to stderr instead of crashing the CLI. Added `test/semantic_test.rb`, `test/sources_split_test.rb`, `test/plugin_autoload_test.rb`.
- **Registry-driven schema + TargetError hierarchy (Sprint E).** The manifest validator now derives its lists of known source types, inline test types, and step names from the runtime registries (`Blink::Sources::REGISTRY`, `Blink::Testing::InlineRunner::REGISTRY`, `Blink::Steps::REGISTRY`) instead of hand-maintained constants. Plugins that call `Blink::Sources.register(...)` / `InlineRunner.register(...)` / `Steps.register(...)` now flow through to the schema automatically — no Schema edits required. The obsolete `KNOWN_STEPS`, `KNOWN_SOURCE_TYPES`, and `KNOWN_INLINE_TEST_TYPES` constants are gone (`KNOWN_TARGET_TYPES` stays — targets are structural). On the target side, introduced `Blink::TargetError` as the shared base class for `LocalTargetError` (new) and `SSHTargetError` (renamed). `LocalTarget` no longer pretends its failures are SSH errors. `SSHError` is preserved as an alias for `SSHTargetError` for backward compatibility, but command-level rescue sites now catch the broader `TargetError` so local-target failures surface with the same ergonomics as SSH ones. Added `test/registry_and_target_error_test.rb`.
- **MCP structured tool results + annotations (Sprint C).** `tools/list` now advertises a shared `outputSchema` on every tool plus per-tool MCP `annotations` (`readOnlyHint`, `idempotentHint`, `destructiveHint`, `openWorldHint`) so LLM clients can reason about safety before calling — `blink_deploy` / `blink_rollback` are marked destructive, read-only tools (`blink_plan`, `blink_steps`, `blink_state`, `blink_history`, etc.) are marked idempotent. `tools/call` responses now include `structuredContent` (the parsed tool payload) and `isError` alongside the legacy JSON-in-text `content` block, so modern MCP clients can consume structured data without re-parsing a string. Operational failures (including `Manifest::Error`) are now returned via `isError: true` inside `CallToolResult` rather than as JSON-RPC protocol errors, per MCP spec guidance. Tool arguments are redacted (`token`, `api_key`, `authorization`, etc.) before being written to the stderr log channel. Added `test/mcp_server_test.rb`.
- **Concurrency-safe `.blink/` persistence (Sprint B).** `Blink::Lock.write_json` now writes atomically (tmp file + fsync + rename), so readers never observe a partially-written state file. The shared read-modify-write sequence that updates `state/current.json` and `state/recent_runs.json` is now wrapped in an OS-level `flock` on `.blink/.lock`, serializing parallel deploy threads and separate Blink processes so no update is lost. Added `test/lock_concurrency_test.rb` to prove both properties.
- **Shared CLI command plumbing (Sprint A).** Introduced `Blink::Runtime.capture_output` and `Blink::Commands::Base`. The `deploy`, `build`, and `rollback` commands now share a single stdout/stderr capture implementation, ANSI-strip regex, and JSON error envelope, replacing three independent copies. The MCP server delegates to the same helper (stdout-only mode, so its stderr log channel stays live). No user-visible output shape changes.
- Standardized the repository documentation contract and moved active planning to the workspace root `ROADMAP.md`.
- Ignored the repository-root `BLINK.md` and stopped tracking it so homelab-specific Blink operator notes stay local-only.
