# Android toolkit

The Android commands mirror the iOS ones: same names, same arguments, same output, so a script or an agent that drives one platform drives the other by changing `ios` to `android`. Coordinates are dp, which on a 402x874 dp emulator are the same numbers as iOS points on the iPhone 17 Pro simulator.

The project mounts it with a thin `build.sh` that sets `TOOLKIT_PROJECT_ROOT` and calls `_dispatch`, and a `build.properties` next to it. That folder is the Gradle root: `gradlew`, `settings.gradle.kts` and the app module live there. Output goes to its `build/` (gitignored).

Turn runs it as `./build.sh <command>` inside the Android repository, or `android/build.sh <command>` from Turn's folder. The usage lines below write `./build.sh android <command>`.

## Files

| File | Holds |
|---|---|
| `build.sh` | Settings, `--device` and `--config`, dispatch, usage |
| `build-gradle.sh` | The JDK, the Gradle wrapper, `build`, `clean`, `test`, `lint`, `format` |
| `build-lifecycle.sh` | `install`, `launch`, `uninstall`, `adb reverse`, the fixture session |
| `build-debug.sh` | `logs`, `debug`, `signin`, `signout` |
| `build-device.sh` | Target selection, `screenshot`, `screenshots collect`, `see` |
| `build-record.sh` | `record` |
| `build-ui.sh` | `ui` |
| `build-emulator.sh` | `emulator start\|stop\|status` |
| `build-lock.sh` | `lock` |
| `build-overnight.sh` | `night init`, `blocker add`, the overnight folder |
| `build-worktree.sh` | `worktree new\|remove\|list` |
| `build-doctor.sh` | `doctor` |

`toolkit/shared` provides what iOS uses too: `record-frames.sh` (frames and contact sheets), `logfmt.sh` (`--level`), `scripts.sh` (script names), `vision.sh`.

## Settings

`build.properties`, then the gitignored `build.properties.local`, are read with every key exported, so Gradle sees them too (for example `TURN_ROOT`). Environment variables of the same name are overridden by the files.

| Key | Default | Meaning |
|---|---|---|
| `ANDROID_APP_NAME` | the folder's name | Name in the output, for example `Turn` |
| `ANDROID_MODULE` | `app` | The Gradle module that builds the app |
| `ANDROID_APPLICATION_ID` | none | Used only before any APK is built; otherwise the id is read from the APK |
| `DEV_APPLICATION_ID_SUFFIX` | none | Added to `ANDROID_APPLICATION_ID` for debug and profile |
| `ANDROID_MAIN_ACTIVITY` | the launcher activity | `.MainActivity` or `package/class`; normally left out |
| `ANDROID_LOG_TAG` | `ANDROID_APP_NAME` | The tag the app logs with, `Turn` |
| `ANDROID_JAVA_HOME` | see below | The JDK for Gradle |
| `ANDROID_EMULATOR_AVD` | none | The AVD that `emulator start` boots, `Turn_Parity` |
| `ANDROID_EMULATOR_IMAGE` | none | System image `doctor` checks, `system-images;android-36;google_apis;arm64-v8a` |
| `ANDROID_BUILD_TOOLS` | none | Build tools version `doctor` checks, `37.0.0` |
| `SERVER_PORT` | `8080` | The local server's port, reversed onto the device |
| `SERVER_HEALTH_URL` | `http://localhost:<port>/api/health` | What `test` and `doctor` ask |
| `TOOLKIT_SERVER_ENABLED` | `false` | `adb reverse` on every launch, server check before tests |
| `TOOLKIT_DEBUG_SCRIPTS` | `false` | `debug --script` and `record --script` |
| `TOOLKIT_LOGS_ENABLED` | `true` | `logs` and `debug` |
| `TOOLKIT_ARCH_CHECKS` | `true` | Runs `do_android_arch_checks` in lint when a lint file defines it |
| `TOOLKIT_DEBUG_TIMEOUT` | `600` | Seconds a scripted `debug` waits for `DEBUG_SESSION_ENDED` |
| `TOOLKIT_FIXTURE_SESSION_CMD` | `./build.sh fixture session` | Run with the slot before `--fixture` launches |
| `TOOLKIT_OVERNIGHT_DIR` | `<main checkout>/../output/overnight` | Locks, night folders |
| `TOOLKIT_NIGHT_DATE` | the newest night with a queue | Fixes which night folder `blocker add` and `doctor --watch` use |
| `TOOLKIT_LOCK_TIMEOUT` | `1200` | Seconds a command waits for a lock |
| `TOOLKIT_WORKTREE_DIR` | `<parent>-<checkout>-work` | Where package worktrees go |
| `TOOLKIT_WORKTREE_BRANCH_PREFIX` | `pkg/` | Branch name before the package name |
| `TOOLKIT_WORKTREE_COPY` | `local.properties build.properties.local` | Gitignored files copied into a new worktree |
| `TOOLKIT_PACKAGES_FILE` | `<main checkout>/doc/packages.md` | The package list `night init` reads |
| `TOOLKIT_IOS_COMMIT` | from `night/launch-prompt.md` | The iOS commit `night init` writes |

From the environment: `ANDROID_DEVICE` (like `--device`), `ANDROID_CONFIG` (like `--config`), `ANDROID_LAUNCH_ARGS` (am start extras for every launch, for example `--ez turnMuted true`), `ANDROID_GRADLE_OFFLINE=true`, `AGENT_SLOT` (the fixture slot), and any `SCRIPT_ENV_<NAME>`, which reaches debug scripts as the extra `<NAME>`.

The SDK is found through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `~/Library/Android/sdk`.

### JDK

Gradle runs with `JAVA_HOME` set by the toolkit, whatever the shell has: `ANDROID_JAVA_HOME`, else Android Studio's JDK, else Homebrew's `openjdk@21` (`/opt/homebrew/opt/openjdk@21/...`, which survives upgrades), else `java_home -v 21` or `-v 17`. Only JDK 17 and 21 count; `java_home -v 21` returns JDK 26 on this Mac when 21 isn't registered, so it is checked too.

### Build types

`--config debug` (default), `profile` or `release` picks the Gradle build type: `assembleDebug`, `testDebugUnitTest`, `lintDebug` and so on. The APK is the newest in `<module>/build/outputs/apk/<type>/`.

## Targets

Every command that talks to a device takes an optional target first: `emulator` (`simulator` means the same), `device` (a phone over USB), a serial from `adb devices`, or the name of a running AVD. Without one, the running emulator is used, else the one connected phone. With several of one kind connected, the command refuses and lists them; pick one with `--device <serial>` or `ANDROID_DEVICE`. `install`, `launch`, `debug` and `record` boot `ANDROID_EMULATOR_AVD` when nothing is connected.

A lone argument to `screenshot` or `record` is the target only when it is one of those words, a connected serial or a running AVD; otherwise it is the file name, as on iOS.

## Commands

### Build

| Command | Does |
|---|---|
| `build` | `ktlintFormat`, then `ktlintCheck` and `detekt` (each when the Gradle build applies the plugin) and the arch checks, then `:app:assemble<Type>`. Prints `✓ Format passed`, `✓ Lint passed`, `✓ Build complete`. |
| `clean` | `gradle clean` and removes `build/` (screenshots, recordings, logs). |
| `test [filter] [timeout] [--no-build]` | `:app:test<Type>UnitTest --rerun`. The filter is a class name (`FeedLoadTests`) or `Class/method`. Stops Gradle after the timeout (120 s). Prints the verdict from the JUnit reports: `✓ 12 tests passed` or `✗ 2 of 12 tests failed:` and one line per failure. `--no-build` is accepted; Gradle compiles only what changed anyway. Asks the server first when `TOOLKIT_SERVER_ENABLED=true`. |
| `lint` | The `build` checks, then Android Lint (`:app:lint<Type>`). |
| `format` | `ktlintFormat`. |

Gradle's output goes to `build/logs/gradle-<command>.log`. On failure the toolkit prints the compiler errors, the failing tasks and Gradle's "What went wrong", then the log's path. Every Gradle call takes the gradle lock. While the night's `down/network` flag is set, Gradle runs `--offline`.

### App

| Command | Does |
|---|---|
| `install [target] [--quiet] [--fixture [slot]]` | `build`, then `adb install -r -d`, `adb reverse tcp:8080 tcp:8080` (with the server on) and `am start -W -S`. `--quiet` is accepted for iOS parity; the emulator window is never brought forward. |
| `launch [target] [--fixture [slot]] -- [extras...]` | Installs the built APK and launches it, forwarding am start extras (`--es key value`, `--ez key true`). Builds first when there is no APK. |
| `uninstall [target]` | Stops the watcher and the app and uninstalls it. Unlike iOS, which shuts the simulator down, the emulator keeps running: other work shares it. |
| `logs [target] [--cat <cat>] [--level <level>] [N\|tail]` | The app's log lines (tag `ANDROID_LOG_TAG`) as `HH:MM:SS.mmm  LEVEL [cat] msg`. `--cat all` shows every line of the running app's process. `tail` streams new lines. |
| `debug [target] [--cat] [--level] [--script <names>] [--no-build] [--timeout N] [--fixture [slot]]` | Below. |
| `signin [email code]` / `signout` | `debug emulator --no-build --script sign_in` or `sign_out`. The login comes from `SCRIPT_ENV_TURN_LOGIN_EMAIL` and `_CODE`, or the two arguments. |

`--fixture [slot]` (slot from `AGENT_SLOT`, else 1) runs `./build.sh fixture session <slot>` first, because a refresh token works once, then passes `FIXTURE_SLOT_<slot>_REFRESH_TOKEN` and `FIXTURE_SLOT_<slot>_CLOCK` from `build.properties.local` as the extras `TURN_DEBUG_REFRESH_TOKEN` and `TURN_CLOCK`.

### debug

1. Builds unless `--no-build` (which still builds when no APK exists), takes the emulator lock, installs and reverses the server port.
2. With `--script`: clears `cache/scriptor-ready` with `run-as` and passes `TURN_DEBUG_SCRIPT_NAMES`, every `SCRIPT_ENV_<NAME>` and the `signin` login as extras. Builds that aren't debuggable (`--config profile`) get `TURN_DEBUG_SCRIPT_NO_MARKER=1` instead of the marker.
3. Notes the device's time, streams `logcat -T <that time>` so nothing logged during launch is lost, and launches with `am start -W -S`.
4. One second later, writes the marker with `run-as`.
5. Shows the app's lines, filtered by `--cat` and `--level`, until `DEBUG_SESSION_ENDED` (`✓ App backgrounded, session ended.`) or the app's process ends (`✓ App stopped, session ended.`).

A scripted run fails when no `[scriptor]` line arrives within 40 s (the build has no script runner), or after `--timeout` seconds (default 600) without `DEBUG_SESSION_ENDED`.

### Screen

| Command | Does |
|---|---|
| `emulator start [--window]` | Boots the configured AVD, headless unless `--window`, and waits until Android has finished booting. Its log is `build/emulator/emulator.log`. |
| `emulator stop` | Shuts the running emulator down. |
| `emulator status` | Lists the connected emulators (with their AVD) and phones (with their model). |
| `screenshot [target] [name]` | Saves the screen to `build/screenshots/<name>.png` (default `turn_<date>-<time>.png`), says which device it came from, and prints the absolute path last. |
| `screenshots collect [target]` | Copies the PNGs debug scripts saved in the app's `files/DebugScreenshots` (through `run-as`, or for builds that aren't debuggable from `/sdcard/Android/data/<app>/files/DebugScreenshots`) into `build/screenshots/`. Prints each path, then `✓ Collected N screenshot(s)`. Same names overwrite. |
| `see [target] [--focus "<question>"]` | Captures the screen and describes it with the vision model (`toolkit/shared/vision.sh`). For models that can't read images. |
| `record [target] [name] [--seconds N] [--script <names>] [--frames <fps>]` | Records with `screenrecord` to `build/recordings/<name>.mp4`, at most 180 s (screenrecord's limit). Encoders refuse the full 1206x2622 screen, so the video is scaled to 1920 pixels on the long side (884x1920), same aspect. `--script` relaunches the app with the scripts once recording runs, without the marker. `--frames` cuts frames and 8 x 6 contact sheets into `build/recordings/<name>/`, as on iOS. Ctrl-C stops early and keeps the video. |
| `ui tap <x> <y>` | Taps at dp. |
| `ui tap --id <id>` | Taps the element with that resource id. Compose test tags appear as resource ids when the app sets `testTagsAsResourceId = true` on its root. |
| `ui tap --label <text>` | Taps the first element whose text or content description matches, exactly first, then as a substring. |
| `ui swipe <x1> <y1> <x2> <y2>` | Drags between two points in dp over 300 ms. |
| `ui swipe up\|down\|left\|right` | A full-screen swipe, with the same start and end points as iOS. |
| `ui type <text>` | Types into the focused field. |
| `ui press home\|back\|lock` | Presses a button. `back` exists only on Android. |
| `ui describe [name]` | Prints the view tree, one line per node (`class \| 'label' \| id=... \| x y w h` in dp), and saves it to `build/screenshots/<name>-ui.txt`. |

Every `ui` action except `describe` takes a screenshot afterwards and prints its path last. `--no-shot` skips it; `--delay <ms>` changes the wait before it (700 by default).

`ui` reads the screen through `uiautomator dump`, which sees what the accessibility tree sees. Taps and swipes go through `adb shell input`, scaled from dp to pixels with the device's density.

### Overnight work

| Command | Does |
|---|---|
| `lock <gradle\|emulator> -- <command...>` | Runs the command holding a lock shared by every checkout and worktree. gradle has two holders, emulator one. Waits up to 20 minutes, then fails and suggests a `lock-timeout` blocker. |
| `lock status` | Who holds each lock, and stale ones. |
| `night init <date> [--ios-commit <sha>] [--exclude "<IDs>"] [--force]` | Creates `<overnight>/<date>/` with empty `blockers.jsonl`, `progress.jsonl`, `notifications.jsonl`, the `down/` folder, and `queue.json` with every package of waves 1 to 4 in `doc/packages.md`, all `waiting`. Rows named ", phase 2" or ", only if" are left out; dependencies outside the queue (wave 0) are dropped. Keeps an existing `queue.json` unless `--force`. |
| `blocker add --kind <kind> --summary "<text>" [...]` | Appends one JSON line to the night's `blockers.jsonl` (`blockers.md` 6.2) and prints its path. Fills in the time, agent, worktree, branch and package. `blocker --help` lists the kinds and options. |
| `worktree new <package> [--from <ref>]` | Below. |
| `worktree remove <package> [--force]` | Below. |
| `worktree list` | The package worktrees and their branches. |
| `doctor [--quick] [--json] [--watch [minutes]]` | Below. |

Commands take the locks themselves: Gradle calls the gradle lock; `install`, `launch`, `uninstall`, `debug`, `record`, `screenshot`, `screenshots collect`, `see`, `ui` and `emulator start|stop` the emulator lock (after building, so no one holds the emulator while waiting for Gradle). Commands run under `lock` reuse the lock they hold (`TOOLKIT_LOCKS_HELD`), so one lock covers a sequence:

```
./build.sh android lock emulator -- sh -c './build.sh android debug --script lens_check && ./build.sh android screenshots collect'
```

A lock is a directory per holder in `<overnight>/locks/` with the owner's PID and start time. A holder that exited, even with `kill -9`, is cleared on the next take.

### worktree

`worktree new <package>` adds `<TOOLKIT_WORKTREE_DIR>/<package>` on a new branch `pkg/<package>` from the main checkout's current branch, fills each submodule from the main checkout's own clone (`git -c protocol.file.allow=always submodule update --init`, no network), copies `local.properties` and `build.properties.local`, and prints the path last. The submodule is checked out at the commit the branch pins; when the main checkout's clone is ahead, it says so, because worktrees only get toolkit changes once the pointer is committed.

`worktree remove <package>` refuses while the worktree has uncommitted changes or its branch isn't merged into the main checkout's branch. Then it removes the worktree (git needs `--force` for a worktree with submodules) and deletes the branch with `git branch -d`. `--force` removes it anyway and keeps the branch.

### doctor

Read-only: it never installs anything, never prompts, never starts the server and never reads the keychain. Each check prints `✓`, `⚠` (works, but a risk) or `✗` (blocks), with the fix. Exit 1 when any check fails.

Checks: power and caffeinate, free disk (30 GB, 12 GB), memory and swap, heavy apps, the JDK and a stale `JAVA_HOME`, adb, emulator, sdkmanager, avdmanager, the Gradle wrapper, python3 3.11+, ffmpeg, jq, fswatch, the SDK and its packages (platform-tools, emulator, the module's `compileSdk`, `ANDROID_BUILD_TOOLS`, `ANDROID_EMULATOR_IMAGE`), licences, the AVD (no microphone, no webcam), the emulator booted, phones connected, `adb reverse`, the Gradle cache, wrapper and memory settings, the local server, Postgres, network (Google, Maven Central, Anthropic), `toolkit/` checked out, `build.properties.local`, the scode sandbox, `HOMEBREW_NO_AUTO_UPDATE`, App Store auto updates, and the overnight flags (`ACTIVE`, `RESTART_OK`, `STOP`, `down/`).

`--quick` runs power, disk, memory, emulator, server and network, in about a second. `--json` prints one object per check: `{"check","status","detail","fix"}`. `--watch [minutes]` runs `--quick` every N minutes (default 5) into the night's `watch.log` and sets or clears `down/disk` (below 12 GB; below 5 GB it also writes `STOP`), `down/memory` (below 15 % free or more than 8 GB swap), `down/server`, `down/emulator` and `down/network`. `gradle` and `xcode` flags are left to agents and the user.
