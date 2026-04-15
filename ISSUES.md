# Blink Issues

## Phase 2

### [2B] Blink MVP — MCP Server + Manifest Deploy
Implement the core of Blink as described in the existing PLAN.md. This is the ops layer the whole platform is built around.

**What to build:**
- `blink.toml` manifest parser with schema validation
- `blink --mcp` stdio server exposing `blink_status`, `blink_deploy`, `blink_test`
- All responses: valid JSON, `success` bool, `summary` string, `suggested_next_step` on failure — never raw output
- Demonstrate deploying Tardigrade + BearClaw from manifest targets

**Constraints:**
- Secrets never stored in manifest — `${VAR}` env refs only (reject at parse time)

**Acceptance criteria:**
- [ ] `blink_status` returns structured JSON with per-service states
- [ ] `blink_deploy <service>` is idempotent; returns structured result
- [ ] `blink_test` runs verifier suite; returns per-service pass/fail with structured details
- [ ] Manifest with hardcoded secret value → rejected at parse time with clear error
- [ ] MCP `initialize` + `tools/list` returns `inputSchema` for all three tools
- [ ] `blink_deploy` can deploy at least Tardigrade and BearClaw from a real manifest
- [ ] All tool responses are valid JSON (never raw stdout/stderr)

### Async Build Streaming (follow-on)
`blink_build` and `blink_deploy` are currently synchronous. For long builds, agents need to kick off a job and poll for completion.

- Return a job ID immediately on build start
- Stream progress events; agent polls or subscribes
- Tracked here to not block MVP; implement after MVP is stable
