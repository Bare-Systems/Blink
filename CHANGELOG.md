# Changelog

All notable changes to Blink are documented here.

## [Unreleased]

### Added

- **`skip_build` flag on `blink_deploy`** — New optional boolean parameter for both the CLI and MCP tool. When `true`, the `fetch_artifact` step is skipped and the most recently cached artifact path is restored from state. This solves the MCP timeout problem for services with long Docker builds (e.g. Python images on Apple Silicon): run `blink build` once to cache the artifact, then call `blink deploy --skip-build` (or `blink_deploy` with `skip_build: true`) for fast, build-free deploys. The cached artifact path is read from `last_deploy.artifact.path` in `.blink/state/current.json`.

- **`provision.env_file.always_update`** — New optional key on `env_file` blocks. Takes an array of seed key names that are force-synced on every deploy, even when the env file already exists. Uses a strip-and-append strategy (`grep -v` + `printf` + atomic `mv`) that is safe for values with special characters (base64 tokens, `+`, `=`, `/`). Keys not listed in `always_update` continue to use the existing "seed once" behaviour. Schema validation added for the new field.

### Changed

- Standardized the repository documentation contract and moved active planning to the workspace root `ROADMAP.md`.
- Ignored the repository-root `BLINK.md` and stopped tracking it so homelab-specific Blink operator notes stay local-only.
