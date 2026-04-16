# Blink Refactor Plan

Derived from `deep-research-report.md` (2026-04). Each sprint is independently shippable and preserves `blink.toml` v1 compatibility.

---

## Priority 0 — Correctness & Safety

### Sprint A — Unify CLI command plumbing
**Problem:** `deploy`, `build`, `rollback`, `status`, `logs`, etc. each reimplement OptionParser setup, `--json` envelopes, ANSI stripping, stdout capture, and rescue/exit handling.

**Tasks:**
- [ ] Add `lib/blink/runtime.rb` with `Runtime.capture_output(strip_ansi: true)`.
- [ ] Add `lib/blink/commands/base.rb` with:
  - OptionParser scaffolding and `--json` flag.
  - `render_success(details)` / `render_error(message, code:)` producing consistent `{success, summary, details, next_steps}`.
  - Shared rescue for `Manifest::Error`, `TargetError`, generic StandardError.
- [ ] Migrate `Commands::Deploy` → `Base`.
- [ ] Migrate `Commands::Build` → `Base`.
- [ ] Migrate `Commands::Rollback` → `Base`.
- [ ] Migrate remaining commands (status, logs, ps, state, history, doctor, test, report, validate, plan, restart).
- [ ] Update MCP server to call through `Runtime.capture_output` instead of its own implementation.

**Acceptance:** All existing `--json` output shapes unchanged. `rake test` green. No duplicated `ANSI_STRIP` constants in commands.

---

### Sprint B — Concurrency-safe `.blink/` persistence
**Problem:** `Lock.persist` writes shared JSON files without locks; parallel deploy threads can corrupt them.

**Tasks:**
- [ ] Add `Lock.write_json_atomic(path, payload)`: write `path.tmp` → fsync → rename.
- [ ] Add `Lock.with_lock(&block)` using `File.open(".blink/.lock").flock(File::LOCK_EX)`.
- [ ] Wrap every update sequence in `with_lock`.
- [ ] Replace direct `File.write` callsites in `lock.rb`.
- [ ] Add `test/lock_concurrency_test.rb`: N threads record runs concurrently; assert all target JSON files remain parseable and contain all N runs.

**Acceptance:** Concurrency test passes. No `File.write(...json...)` outside atomic helper.

---

### Sprint C — MCP structured results + annotations
**Problem:** Tool results double-serialize as JSON-in-text; no `outputSchema`; errors inconsistently routed.

**Tasks:**
- [ ] Add `outputSchema` to each tool definition in `mcp_server.rb`.
- [ ] Return `CallToolResult` with both `content` (short human text) and `structuredContent` (object); keep JSON-in-text for one deprecation window.
- [ ] Route operational failures through `isError: true` in the result; reserve JSON-RPC errors for protocol issues (unknown method, invalid params, unknown tool).
- [ ] Add `ToolAnnotations`:
  - `destructiveHint: true` — `blink_deploy`, `blink_rollback`, `blink_restart`.
  - `readOnlyHint: true` — `blink_plan`, `blink_steps`, `blink_state`, `blink_history`, `blink_list_services`, `blink_status`, `blink_logs`, `blink_ps`, `blink_doctor`.
  - `idempotentHint: true` — read-only tools above.
- [ ] Sanitize tool-arg logging (redact header/token-shaped values).
- [ ] Add `test/mcp_server_test.rb`: pipe-driven `initialize` → `tools/list` → `tools/call` for `blink_plan` and a failure case.

**Acceptance:** MCP client receiving `structuredContent` sees a parsed object matching `outputSchema`. Integration test green.

---

## Priority 1 — Security & Consistency

### Sprint D — HTTP adapter + TLS default flip ✅ (BREAKING)
**Problem:** `curl -k` / `-sk` scattered across `steps/health_check.rb`, `testing/http.rb`, `operations.rb`.

**Tasks:**
- [x] Add `lib/blink/http/adapter.rb` encapsulating curl invocation with `tls.verify = true` default.
- [x] Add Schema + config keys: `health_check.tls_insecure`, inline-test `tls_insecure`.
- [x] Replace direct curl callsites in health_check, testing/http, operations.
- [x] Planner warning when `tls_insecure = true` is set.
- [x] Flip default immediately (not warn-then-enforce) — homelab will need follow-up.
- [x] TLS-default regression test (`test/http_adapter_test.rb`).

**Acceptance:** No `-k` outside the adapter's opt-in path. ✅

### Sprint D.1 — Homelab TLS follow-up
**Problem:** Sprint D flipped TLS verification on by default. Homelab services sit behind Tardigrade with certs the client does not yet trust (self-signed or internal CA). Their health checks and inline tests will start failing until we act.

**Tasks:**
- [ ] Audit every `blink.toml` in the homelab stack (BearClaw, BearClawWeb, Tardigrade, Koala, Polar, Ursa, Kodiak) for `health_check` and `verify.tests` blocks.
- [ ] Short-term: add `tls_insecure = true` to each one to unblock deploys. Planner will surface these as warnings, making the debt visible.
- [ ] Medium-term: install an internal CA (or publish Tardigrade's leaf cert) on the host Blink runs from, then remove each `tls_insecure = true`.
- [ ] Run `bin/blink plan <service>` per service and confirm the tls_insecure warnings are the only delta.

---

### Sprint E — Registry-driven schema + TargetError hierarchy
**Problem:** `Schema::KNOWN_STEPS/SOURCES/TESTS` duplicate runtime registries. `LocalTarget` raises `SSHError`.

**Tasks:**
- [ ] Derive allowed step/source/inline-test names from `Blink::Steps`, `Blink::Sources`, `Blink::Testing::InlineRunner` registries.
- [ ] Remove `KNOWN_*` constants; keep Schema for structural shape validation.
- [ ] Per-step config shape validation delegated to `StepDefinition`.
- [ ] Introduce `Blink::TargetError` base + `LocalTargetError` / `SSHTargetError`.
- [ ] Update rescue sites in commands, runner, targets.

**Acceptance:** Adding a new step in a plugin automatically passes schema validation without Schema edits.

---

## Priority 2 — Architecture & Extensibility

### Sprint F — Semantic nucleus + sources + plugins + MCP tasks
**Tasks:**
- [x] Define structs: `OperationPlan`, `OperationResult`, `StepResult(changed, idempotent)`, `ArtifactRef`, `Diagnostics`. _(F.1 — shipped; `lib/blink/semantic.rb`.)_
- [ ] Refactor CLI + MCP to render from these structs (single source of truth). _(Incremental — new callsites emit them directly; legacy hashes coexist until each callsite migrates. Tracked separately as renderer migration work.)_
- [x] Split `Sources::Base` into `Sources::Cache`, `Sources::Verification` mixins. _(F.2 — shipped.)_
- [ ] Extract `Sources::Downloader` shared by `url` + `github_release`. _(Deferred to F.2b — requires aligning `url.rb` and `github_release.rb` HTTP logic first.)_
- [x] Plugin autoload from `blink/plugins/*.rb` + `$BLINK_PLUGIN_PATH`. _(F.3 — shipped; plugins register via existing registries and flow through Sprint E's registry-driven schema.)_
- [ ] MCP long-ops: `blink_build` / `blink_deploy` accept `task: true` → return task handle; emit progress notifications; add task retrieval/cancel. _(F.4 — deferred; substantial subsystem (task manager, progress, cancel) that deserves its own focused sprint.)_

---

## Priority 3 — Polish

### Sprint G — Test stack + CI
**Tasks:**
- [ ] Drop unused `rspec` from Gemfile (or migrate — pick one; default is drop).
- [ ] Add `.github/workflows/blink-ci.yml`: matrix Ruby 3.1/3.2/3.3, `rake test`, rubocop, `bin/blink validate --json` + `plan` smoke against fixture manifest.

---

## Execution order

A → B → C → D → E → F → G. Each sprint is independently mergeable and backward-compatible.
