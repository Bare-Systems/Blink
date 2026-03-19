# 🚀 Blink MVP Worklist (Codex-Ready)

## 🧱 EPIC 1 — Manifest System (Schema + Validation) [P0]

Status: foundation complete. Remaining work is incremental schema expansion as new sources/steps are added.

### Tasks

* [x] Define `blink.toml` schema (v1)
* [x] Implement schema validation layer (`Blink::Schema`)
* [x] Add manifest versioning (`version = "1"`)
* [x] Add validation errors with actionable messages
* [x] Add fixture manifests (valid + invalid cases)
* [x] Add schema tests

### Acceptance Criteria

* Invalid manifests fail fast with clear errors
* All required fields are validated (service, pipeline, target, source, etc.)
* Schema supports:

  * targets
  * sources
  * pipeline steps
  * environment overrides
* `blink validate` command returns structured JSON

---

## ⚙️ EPIC 2 — Plan Engine (Terraform-style) [P0]

Status: complete for current command surface.

### Tasks

* [x] Implement `Blink::Plan` object
* [x] Resolve:

  * declared config → resolved config
  * target expansion
  * source resolution
* [x] Expand pipeline into ordered steps
* [x] Generate rollback plan
* [x] Add warnings + blockers system
* [x] Compute config hash

### Acceptance Criteria

* `blink plan` outputs:

  * ordered steps
  * resolved config
  * rollback steps
  * warnings (non-blocking)
  * blockers (prevent execution)
* `--json` output is stable + machine-readable
* Plan output is deterministic for same input

---

## ▶️ EPIC 3 — Runner + Step Contracts [P0]

Status: complete for built-in steps currently implemented.

### Tasks

* [x] Define `Step` interface:

  * `validate`
  * `plan`
  * `execute`
  * `rollback`
  * `supports_target?`
* [x] Normalize step execution pipeline
* [x] Capture per-step:

  * start/end time
  * duration
  * status
  * outputs
* [x] Add structured failure handling
* [x] Implement rollback execution flow

### Acceptance Criteria

* Every step produces structured output
* Runner returns:

  * success/failure
  * failed step (if any)
  * full step results
* Rollback is triggered automatically on failure
* Steps are target-aware (local vs ssh)

---

## 🧠 EPIC 4 — State + History System (.blink/) [P0]

Status: complete for deploy, test, rollback, query, and report generation flows.

### Tasks

* [x] Replace `blink.lock` with `.blink/` directory model
* [x] Implement:

  * `.blink/state/current.json`
  * `.blink/history/<run-id>.json`
* [x] Generate unique `run_id`
* [x] Store:

  * plan snapshot
  * resolved config
  * step results
  * artifacts
  * timestamps
* [x] Add history indexing (`recent_runs.json`)
* [x] Add retention config support

### Acceptance Criteria

* Every run creates immutable history record
* Current state reflects latest successful run
* State includes:

  * last deploy target/version
  * last test summary
* History is queryable (CLI + JSON)
* System survives restarts and partial failures

---

## 📊 EPIC 5 — Structured Output + CLI Contract [P0]

Status: complete for the current CLI surface.

### Tasks

* [x] Standardize CLI output format:

  * `success`
  * `summary`
  * `details`
  * `next_steps`
* [x] Add `--json` flag to all commands
* [x] Define exit codes:

  * 0 success
  * 1 failure
  * 2 validation error
* [x] Remove all interactive prompts

### Acceptance Criteria

* All commands support `--json`
* Output is stable and parseable
* No command blocks on input
* Errors are structured (not raw strings)

---

## 🧪 EPIC 6 — Verifier / Testing Framework [P0]

Status: mostly complete. Remaining work is richer artifact linking and broader example coverage.

### Tasks

* [x] Finalize test suite DSL
* [x] Implement structured test results:

  * total / passed / failed
  * duration
  * per-check results
* [x] Add tagging support (`smoke`, `integration`)
* [x] Store test results in history
* [ ] Link test artifacts (logs, reports)

### Acceptance Criteria

* `blink test` outputs structured JSON
* Results are persisted per run
* Can filter tests by tag
* Test results are usable for future dashboards

---

## 🖥️ EPIC 7 — Targets (Execution Environments) [P1]

Status: core implementation complete. Remaining hardening is around SSH behavior and failure ergonomics.

### Tasks

* [x] Complete `local` target
* [x] Complete `ssh` target
* [x] Define target interface contract
* [x] Add target validation
* [x] Add environment binding logic

### Acceptance Criteria

* Same pipeline runs on local + ssh
* Target-specific logic is isolated
* Connection errors are handled cleanly
* Targets are selectable via manifest

---

## 📦 EPIC 8 — Sources (Artifacts) [P1]

Status: complete for the current source set. Remaining future work is additional source types and deeper registry/auth features, not the core source contract.

### Tasks

* [x] Harden `github_release` source
* [x] Harden `local_build` source
* [x] Add generic `url` source
* [x] Define source interface contract
* [x] Add artifact metadata tracking

### Acceptance Criteria

* Sources resolve to consistent artifact format
* Artifacts are tracked in state/history
* Source failures are clearly reported
* Artifacts can be reused across runs

---

## 📈 EPIC 9 — Report Generation (Static HTML) [P1]

Status: in progress. Command and exports exist; content/detail polish remains.

### Tasks

* [x] Implement `blink report generate`
* [x] Generate static HTML from history
* [ ] Include:

  * recent runs
  * test summaries
  * deploy history
* [x] Add JSON export for reports

### Acceptance Criteria

* Reports are fully static (no server required)
* Can generate:

  * last run
  * last N runs
  * date range
* Reports readable by humans
* Data derived from history (no duplication)

---

## 🤖 EPIC 10 — MCP Server (Agent Interface) [P1]

Status: complete for current tool surface.

### Tasks

* [x] Implement MCP tool bindings:

  * `blink_deploy`
  * `blink_test`
  * `blink_status`
  * `blink_logs`
  * `blink_rollback`
* [x] Ensure MCP calls core engine (no duplication)
* [x] Add structured MCP responses
* [x] Add `blink --mcp` mode

### Acceptance Criteria

* MCP responses mirror CLI JSON output
* No logic duplication between CLI and MCP
* Agents can:

  * plan
  * deploy
  * test
  * inspect state
* MCP is stateless wrapper over engine

---

## 🧩 EPIC 11 — Step System Hardening [P0]

Status: mostly complete. Built-in steps are introspectable; prose docs are still thin.

### Tasks

* [x] Formalize step registry
* [x] Add step validation rules
* [x] Add step capability metadata
* [x] Define rollback support per step
* [ ] Document all built-in steps

### Acceptance Criteria

* Steps are discoverable and introspectable
* Invalid step configs fail validation
* Each step declares:

  * inputs
  * outputs
  * supported targets
* Rollback behavior is explicit

---

## 📚 EPIC 12 — Documentation + Examples [P1]

Status: largely still open. The CLI and tests are ahead of the docs.

### Tasks

* [ ] Add `/docs` directory
* [ ] Create:

  * getting started guide
  * manifest reference
  * step reference
  * target reference
  * source reference
* [ ] Add example projects:

  * local deploy
  * ssh deploy
  * test suite example

### Acceptance Criteria

* New user can deploy something in <10 minutes
* Docs match actual CLI behavior
* Examples are runnable

---

# 🧭 Suggested Execution Order

## Phase 1 (Foundation)

* EPIC 1 — Manifest
* EPIC 2 — Plan
* EPIC 3 — Runner
* EPIC 4 — State/History
* EPIC 5 — CLI contract

## Phase 2 (Usability)

* EPIC 6 — Testing
* EPIC 7 — Targets
* EPIC 8 — Sources
* EPIC 9 — Reports

## Phase 3 (Agent-native)

* EPIC 10 — MCP
* EPIC 11 — Step hardening
* EPIC 12 — Docs

---

# 🧠 Final Note

Build Blink as a **deterministic execution engine with a system of record**, not just a CLI.

Everything should flow through:

* Manifest → Plan → Runner → State → History → Reports

If that pipeline is solid, everything else (MCP, dashboards, plugins) becomes easy.
