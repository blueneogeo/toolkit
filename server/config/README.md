# server-toolkit — generic Go server build toolkit

Part of the shared `toolkit/` monorepo (`server/`, `ios/`, plus future `android/`, `web/`).
A drop-in build system for any Go backend: mount the toolkit in your project, add a thin
`build.sh` entry, run `./build.sh setup`, and it builds — with zero configuration for
everything that doesn't need it. Online features (Sentry, Fly.io deploy) are OFF by
default and enabled per-project via `./build.sh configure`.

## Install into a new project

The toolkit lives one level below the project root (as a git submodule at `toolkit/`,
or copied in place). Create a thin entry `build.sh` in the project's `server/` directory:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_PROJECT_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/../toolkit/server/build.sh"
_dispatch "$@"
```

Then:

```
./build.sh setup
```

`setup` is idempotent: it detects the project (from `go.mod`), generates
`build.properties` from the example only if missing, walks through the interactive
configuration wizard (database, JWT secret, APNs, email), and builds incrementally.
Re-runs are no-ops.

## Configuration

Everything lives in `<project>/build.properties` (see
`config/build.properties.example` for the full documented surface). Shared config
(Sentry org, Fly.io app name) lives in the root `build.properties` for multi-platform
projects; the server platform reads root config first, then its own for overrides.

### Auto-detected

Go module path from `go.mod`, `cmd/server` entry point. Overridable via
`SERVER_CMD_PATH` and `SERVER_BIN_PATH`.

### Feature flags (all offline-safe)

| Flag | Default | Enables |
|---|---|---|
| `TOOLKIT_SERVER_SENTRY_ENABLED` | `false` | `sentry` queries (needs `SENTRY_ORG` and `SERVER_SENTRY_PROJECT`) |

### Build pipeline

`_sync_locale` (configurable locale copy) → `sqlc generate` → `golangci-lint` → `go build` → firewall registration.

## Commands

`setup` · `build` · `clean` · `start` · `stop` · `status` · `logs [N\|tail]` · `debug` ·
`watch` · `test [N] [service\|emails\|local\|live]` · `lint` · `format` · `doctor` ·
`docs` · `migrate up\|down` · `sql <query>` · `apns-setup` · `email-setup` ·
`live status` · `live logs [N\|tail]` · `live deploy [--dry-run] [--strategy] [--force] <text>` ·
`live rollback [--dry-run] [--force]` · `live snapshots` · `live deployments` · `live releases` ·
`live machines` · `live setup` · `live ci-setup` · `live sentry`

See `./build.sh server` (no args) for full usage.
