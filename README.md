# Blink

Blink is a declarative deploy/test/rollback runner driven by `blink.toml`.

## Quick Start

```toml
[blink]
version = "1"

[targets.local]
type = "local"
base = "/tmp/my-service"

[services.app]
description = "Example service"

[services.app.source]
type = "local_build"
command = "bin/build"
artifact = "dist/app.tar.gz"

[services.app.deploy]
target = "local"
pipeline = ["fetch_artifact", "verify"]

[services.app.verify]
suite = "suite.rb"
```

Useful commands:

- `bin/blink init`
- `bin/blink validate --json`
- `bin/blink plan app --json`
- `bin/blink deploy app --json`
- `bin/blink test app --json`
- `bin/blink state app --json`
- `bin/blink history app --json`
- `bin/blink report generate --format html --json`

`blink init` scaffolds a starter `blink.toml` with deploy, health-check, and declarative API/UI verification examples.

## Declarative Test Suites

Blink supports both Ruby verifier suites and declarative inline checks under `verify.tests`.

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

[services.app.verify.tests.ui-home.checks.heading]
type = "selector"
engine = "xpath"
selector = "//h1[contains(., 'Welcome')]"
```

Supported inline test types:

- `api` / `http`: HTTP request checks with status/body/header/JSON assertions
- `ui`: HTML response checks with CSS or XPath selector assertions plus text checks
- `shell`: remote command assertions
- `mcp`: MCP initialize smoke tests
- `script`: local executable checks

Supported inline check types:

- `status`: exact HTTP response code validation
- `body`: substring or regex match against the raw response body
- `header`: header presence or value validation
- `json`: JSON-path-style lookups such as `$.status` or `$.data.items[0].id`
- `selector`: CSS or XPath presence/absence checks for `ui` tests
- `text`: text presence or regex match in the response body or rendered page text

Load testing is intentionally deferred for now. The current test surface is aimed at deploy gating and smoke/integration verification.

Selector checks use Nokogiri for HTML parsing. If you want declarative `css` or `xpath` checks, make sure `nokogiri` is available in the Ruby environment Blink runs under.

## Source Types

### `local_build`

Build an artifact locally, then stage or cache it under `.blink/artifacts/<service>/`.

```toml
[services.app.source]
type = "local_build"
workdir = "."
command = "bin/build"
artifact = "dist/app.tar.gz"

[services.app.source.env]
RACK_ENV = "production"
```

### `github_release`

Resolve a GitHub release asset and cache it by release tag + asset name.

```toml
[services.app.source]
type = "github_release"
repo = "owner/name"
asset = "app-linux-amd64.tar.gz"
token_env = "GITHUB_TOKEN"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
checksum_asset = "checksums.txt"
```

### `url`

Fetch an artifact from `file://`, `http://`, or `https://`.

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

`url` source cache behavior:

- `file://` artifacts are reused when the source file fingerprint is unchanged.
- `http://` and `https://` artifacts skip the network entirely while `cache.ttl_seconds` is still fresh.
- After TTL expiry, or when no TTL is configured, Blink revalidates cached HTTP artifacts with `If-None-Match` and `If-Modified-Since` when prior `ETag` or `Last-Modified` headers are available.
- If the server returns `304 Not Modified`, Blink keeps the cached artifact and records that it was revalidated.
- If the server does not provide validators, Blink downloads the artifact again.
- Set `sha256` to require an exact artifact checksum before Blink accepts the download or cached artifact.
- Set `checksum_url` to fetch a published checksum document and verify the artifact against the digest listed for the artifact filename.
- Set `signature_url` plus `verify_command` to run detached-signature verification against the downloaded artifact.
- Blink blocks plain `http://` remote sources by default. Set `allow_insecure = true` only when you have an explicit reason to accept plaintext transport.
- Set `cache.enabled = false` to disable source caching entirely.
- `token_env` injects `Authorization: Bearer <token>` unless you already set an explicit `Authorization` header under `headers`.
- `timeout_seconds` applies to both connect and read timeouts. Default: `30`.
- `retry_count` and `retry_backoff_seconds` control retries for transient HTTP/network failures. Defaults: `2` retries with `1` second backoff.

`github_release` provenance options:

- `sha256` verifies against a literal digest in the manifest.
- `checksum_asset` fetches another release asset, such as `checksums.txt`, and verifies the selected release artifact against the digest published in that file.
- `signature_asset` fetches a detached signature asset and runs `verify_command` against the downloaded release artifact.
- If you override `api_base` to plain `http://`, set `allow_insecure = true` or the planner will block the deploy.
- If both are present, `sha256` takes precedence.

Detached signature verification:

- `verify_command` is executed locally after the artifact is fetched. Use placeholders `{{artifact}}`, `{{signature}}`, and `{{public_key}}`.
- `public_key_path` is optional and is only interpolated if your verifier needs it.
- Blink records verified signature metadata in `.blink` state/history and surfaces it in reports.

## Persisted State

Blink writes run state under `.blink/`:

- `.blink/state/current.json`
- `.blink/state/recent_runs.json`
- `.blink/history/<run_id>.json`
- `.blink/artifacts/<service>/...`

Deploy state and run history include artifact metadata such as:

- artifact path, size, and SHA-256
- source type and cache key
- cache summary
- integrity verification metadata (`algorithm`, `expected`, `actual`, `verified_at`, `source`, `reference`) when checksum enforcement is enabled
- HTTP validator data (`etag`, `last_modified`, `validated_at`, `revalidated`) when applicable

That same data is available through:

- `blink state`
- `blink history`
- `blink report generate`

`blink plan` also surfaces source-security posture before execution, including transport, checksum mode, provenance mode, and blockers for insecure remote transport.
