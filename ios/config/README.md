# ios-toolkit — generic iOS build toolkit

Part of the shared `toolkit/` monorepo (`ios/`, `server/`, plus future `android/`, `web/`).
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
Personal values that must stay out of git (a test account's login) go in
`<project>/build.properties.local`, loaded after it when present; keep that file
gitignored. Any `SCRIPT_ENV_<NAME>` from either file, or from the shell, reaches
debug scripts on the simulator as the environment variable `<NAME>`.

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

- `do_state_check` — no `@StateObject`/`@ObservedObject`/`@EnvironmentObject`/`@Published`/`ObservableObject`; `@State` allowed only with `// non-actionable: <reason>` on the same line; functions live in state-class extension files, not the base file
- `do_concurrency_check` — no `nonisolated(unsafe)`, `@unchecked Sendable`, `DispatchQueue.global`, `.sync {}`, locks, semaphores, or synchronous file I/O without `// concurrent-safe: <reason>` on the same line; `AVCaptureSession` must be inside an actor
- `do_section_marker_check` — `Queries → Handlers → Actions → Helpers` order, no `// MARK: -` dashes, no `private func` in Handlers
- `do_handler_suffix_check` — `on<Subject><Event>` with an approved suffix list
- `do_mark_spacing_check` — blank-line padding around `// MARK:`
- `do_try_check` — no unjustified `try?` (requires `// non-actionable:`)
- `do_handler_visibility_check` — handlers (`on<Subject><Event>`) must not be `private`; private imperative work is an action
- `do_observable_class_check` — `@Observable` must annotate a `@MainActor final class`
- `do_root_immutability_check` — the composition-root file declares no `var` (only `let` instances/resources)
- `do_reset_presence_check` — every `@Observable` domain state class defines `reset()`
- `do_mark_allowlist_check` — state extension files use only `Queries`/`Handlers`/`Actions`/`Helpers` markers; class bodies use blank-line grouping
- `do_transport_purity_check` — the transport file never reads `UserDefaults`/`ProcessInfo`/`Bundle` (config arrives via `init`)
- `do_transport_construction_check` — the transport is never zero-arg constructed

Point them at your state class via `TOOLKIT_STATE_CLASS` and `TOOLKIT_STATE_FILE`. The transport checks are opt-in: set `TOOLKIT_TRANSPORT_FILE` (e.g. `service/APIClient.swift`) to enable the purity and construction gates; leave it empty to skip them.

## Customizing per project

The toolkit is meant to stay untouched. A project's `build.sh` can override any function
or add commands after sourcing — last definition wins. Example:

```bash
export TOOLKIT_PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/toolkit/ios/build.sh"
do_mything() { echo "custom"; }
_dispatch "$@"
```

## Screenshots & vision

Capture and inspect the app's UI on the simulator:

- `screenshot [name]` — capture the booted simulator's screen to `build/screenshots/`
  (no build/launch); prints the absolute path last.
- `screenshots collect` — copy in-app debug captures (`DebugScreenshot.save`) out of
  the app container into `build/screenshots/`, preserving names.
- `see [--focus "<q>"]` — capture the simulator screen and describe it with a vision
  model; `--focus` optional (defaults to a broad description plus a footer nudging
  toward focused follow-ups).

`see` composes the shared `vision` command (see the monorepo `README.md`), which reads
`TOOLKIT_MODEL_API_KEY` / `TOOLKIT_MODEL_BASE_URL` / `TOOLKIT_VISION_MODEL` from the
environment. Images are sent at full resolution by default.

## Build configurations

Every building command (`build`, `install`, `launch`, `watch`, `debug`, `test`,
`tsan-test`, `e2e`, `profile`, `clean`) uses the configuration picked with
`--config <name>` / `-c <name>`, or `IOS_CONFIG=<name>` as a default. The name is
case-insensitive and must be a configuration the project defines. Debug is the default.

- `debug`: unoptimised; the development app (`BUNDLE_ID` + `DEV_BUNDLE_SUFFIX`).
- Any other non-Release configuration, such as a `Profile` the project defines as
  `release`-type in `project.yml`, also installs as the development app. Use it to
  judge performance: Debug builds are much slower (no optimisation, extra checks).
- `release`: the App Store configuration, which uses the plain `BUNDLE_ID`. It is
  usually distribution-signed, so it can't be installed on a phone directly.

Tests built with a non-Debug configuration get `ENABLE_TESTABILITY=YES` so that
`@testable import` works.

```bash
./build.sh ios --config profile install device
./build.sh ios --config profile profile device --script deck_swipe_perf --render
```

## Profiling

`profile [target] [--script <names>] [--seconds N] [--render] [--template <name>] [--name <label>]`
records an Instruments trace (`xctrace`, Time Profiler by default) of the installed
app on the connected phone or the booted simulator. It then prints a summary:

- the frame lines a debug script's frame monitor marked (Points of Interest signposts
  named `perf start`, `fps` and `perf summary`);
- with `--render`: frames shown per second, render-server and GPU time per frame,
  offscreen passes per frame, and a table per 5 seconds;
- sampled CPU per thread, the heaviest functions, and the app's own hot code.

`--script` launches the app with those debug scripts running immediately, skipping
the start-up marker wait (`TURN_DEBUG_SCRIPT_NO_MARKER=1`), so a scripted
interaction is measured end to end. Traces are kept in `build/traces/` so you can
open them in Instruments.

Notes:
- Install the configuration you want to measure first; a Profile build gives
  realistic numbers.
- `--render` adds the Hitches and GPU instruments, which drop the Points of
  Interest rows. Run once with and once without to get both.
- Don't take phone screenshots during a recording; they can disturb it.

## Commands

`setup [--force] [--renew-profiles]` · `update-toolkit` · `configure` · `build` · `clean` · `install [target] [--quiet|-q]` · `uninstall [target]` · `watch [target] [mode]` ·
`test [filter] [timeout] [--no-build]` · `tsan-test [filter] [timeout]` · `lint` · `format` · `unused` · `analyze` · `audit` · `doctor` ·
`logs [--cat] [--level] [N|tail]` · `debug [target] [--cat] [--level] [--script <names>] [--no-build]` · `signin` · `signout` · `e2e` · `e2e-run` ·
`screenshot [target] [name]` · `screenshots collect` · `see [target] [--focus <q>]` · `ui <cmd>` ·
`profile [target] [--script] [--seconds] [--render] [--template] [--name]` ·
`upload [--force] <text>` · `sentry <cmd>` · `[--server]` · `[--config <name>]`

`[target]` = `device` | `simulator` | `<name|udid>`; no target prefers a connected physical phone and falls back to the simulator.

`device` prefix or `--device <name|udid>` targets a specific physical device.
`install`, `uninstall`, `watch` and `debug` take `device` or `simulator` as an explicit target;
with no target they prefer a connected phone and fall back to the simulator.

- `setup --renew-profiles` renews the App Store provisioning profile (fastlane match
  `--force`), needed after adding a capability such as Associated Domains.
- `debug --no-build` relaunches the installed simulator app instead of rebuilding. On the
  simulator, `debug` reads the simulator's own log stream at debug level and writes the
  script marker only once that stream is listening, so a script that ends at once is
  still heard and the session stops on `DEBUG_SESSION_ENDED`.
- `signin` / `signout` run the project's `sign_in` / `sign_out` debug scripts on the
  simulator without rebuilding (`debug simulator --no-build --script sign_in`).
`IOS_DEVICE=<name|udid>` selects which connected iPhone to use when several are present
(a preference, not a force). Breaching commands auto-forward to the user-launched relay when `SCODE_SANDBOXED` is set; pass `--server` explicitly outside sandboxes. See `./build.sh` (no args) for full usage.
