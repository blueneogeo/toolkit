# ios-toolkit — generic iOS build toolkit

Part of the shared `toolkit/` monorepo (`ios/`, plus future `android/`, `go/`, `web/`).
A drop-in build system for any iOS app: mount the toolkit in your project, add a thin
`build.sh` entry, run `./build.sh setup`, and it builds — with zero configuration for
everything that doesn't need it. Online features (Sentry, TestFlight upload, E2E, server)
are OFF by default and enabled per-project via `./build.sh configure`.

## Install into a new project

The toolkit lives one level below the project root (as a git submodule at `toolkit/`,
or copied in place). Create a thin entry `build.sh` in the project root:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_PROJECT_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/toolkit/ios/build.sh"
_dispatch "$@"
```

Then:

```
./build.sh setup
```

`setup` is idempotent: it detects the project (from `project.yml` or `*.xcodeproj`),
generates `build.properties` from the example only if missing, generates the Xcode
project only when out of date, configures the LSP server once, and builds incrementally.
Re-runs are no-ops; `./build.sh setup --force` regenerates. Add a `project.yml`
(XcodeGen) first if you don't have one.

## Configuration

Everything lives in `<project>/build.properties` (see
`config/build.properties.example` for the full documented surface).

External services (Sentry, upload, e2e, server) are configured idempotently via
`./build.sh configure` — already-configured items are skipped, non-interactive runs
just report state.

Auto-detected from `project.yml` / the `.xcodeproj` unless overridden: project name,
scheme, app name, source dir, bundle id, test target. Lint/format configs
(`.swiftlint.yml`, `.periphery.yml`) are found by searching upward from the toolkit.

### Feature flags (all offline-safe)

| Flag | Default | Enables |
|---|---|---|
| `TOOLKIT_SERVER_ENABLED` | `false` | `API_BASE_URL` export + server health gate before tests |
| `TOOLKIT_E2E_ENABLED` | `false` | `e2e` / `e2e-run` |
| `TOOLKIT_UPLOAD_ENABLED` | `false` | `upload` (TestFlight) + fastlane setup |
| `TOOLKIT_SENTRY_ENABLED` | `false` | `sentry` queries |
| `TOOLKIT_LOGS_ENABLED` | `true` | `logs` / `debug` |
| `TOOLKIT_DEBUG_SCRIPTS` | `false` | `debug --script` injection |
| `TOOLKIT_ARCH_CHECKS` | `true` | AppState architecture lint gates |

### Architecture lint gates

When `TOOLKIT_ARCH_CHECKS=true`, `lint` and every build additionally enforce:

- `do_state_check` — no `@StateObject`/`@ObservedObject`/`@EnvironmentObject`/`@Published`/`ObservableObject`; `@State` only via the configured exclusion; functions live in state-class extension files, not the base file
- `do_section_marker_check` — `Queries → Handlers → Actions → Helpers` order, no `// MARK: -` dashes, no `private func` in Handlers
- `do_handler_suffix_check` — `on<Subject><Event>` with an approved suffix list
- `do_mark_spacing_check` — blank-line padding around `// MARK:`
- `do_try_check` — no unjustified `try?` (requires `// non-actionable:`)

Point them at your state class via `TOOLKIT_STATE_CLASS` and `TOOLKIT_STATE_FILE`.

## Customizing per project

The toolkit is meant to stay untouched. A project's `build.sh` can override any function
or add commands after sourcing — last definition wins. Example:

```bash
export TOOLKIT_PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/toolkit/ios/build.sh"
do_mything() { echo "custom"; }
_dispatch "$@"
```

## Commands

`setup [--force]` · `update-toolkit` · `configure` · `build` · `clean` · `install [iphone]` · `uninstall [iphone]` · `watch [iphone] [mode]` ·
`test [filter] [timeout]` · `lint` · `format` · `unused` · `analyze` · `audit` · `doctor` ·
`logs [--cat] [--level] [N|tail]` · `debug [--cat] [--level]` · `e2e` · `e2e-run` ·
`upload [--force] <text>` · `sentry <cmd>`

`device` prefix or `--device <name|udid>` targets a physical device; otherwise the
simulator is used. See `./build.sh` (no args) for full usage.
