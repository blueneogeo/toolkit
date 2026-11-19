# Android toolkit

The Android commands mirror the iOS ones: same names, same arguments, same output, so a script or an agent that drives one platform drives the other by changing `ios` to `android`. Coordinates are dp, which on a 402x874 dp emulator are the same numbers as iOS points on the iPhone 17 Pro simulator.

The project mounts it with a thin `build.sh` that sets `TOOLKIT_PROJECT_ROOT` and calls `_dispatch`, and a `build.properties` next to it. That folder is the Gradle root: `gradlew`, `settings.gradle.kts` and the app module live there. Output goes to its `build/` (gitignored).

Turn runs it as `./build.sh <command>` inside the Android repository, or `android/build.sh <command>` from Turn's folder. The usage lines below write `./build.sh android <command>`.

## Files

| File | Holds |
|---|---|
| `build.sh` | Settings, `--device` and `--config`, dispatch, usage, `<command> --help` |
| `build-gradle.sh` | The JDK, the Gradle wrapper, `build`, `clean`, `test`, `lint`, `format` |
| `build-lint.sh` | The grep gates (`do_android_arch_checks`) and the project's `lint.sh` hook |
| `detekt-rules/` | Turn's detekt rules (rule set `turn`), and the fixture tests of every gate |
| `detekt.yml`, `detekt-test.yml`, `detekt-debug.yml` | detekt's settings for the app, the tests and the debug tools |
| `build-lifecycle.sh` | `install`, `launch`, `uninstall`, `watch`, `adb reverse`, the fixture session |
| `build-debug.sh` | `logs`, `debug`, `signin`, `signout` |
| `build-device.sh` | Target selection, `screenshot`, `screenshots collect`, `see` |
| `build-record.sh` | `record` |
| `build-ui.sh` | `ui` |
| `build-emulator.sh` | `emulator start\|stop\|status\|restart\|create\|front\|contact\|text-size\|push`, `push` |
| `build-lock.sh` | `lock` |
| `build-overnight.sh` | `night init`, `blocker add`, the overnight folder |
| `build-worktree.sh` | `worktree new\|remove\|list` |
| `build-doctor.sh` | `doctor` |
| `build-sync.sh` | `sync`, and the parity gate in `build` and `lint` |
| `build-setup.sh` | `setup` |
| `build-profile.sh` | `profile`, `benchmark` |
| `build-upload.sh` | `preflight`, `upload`, `promote` |
| `build-icons.sh` | `icons` |
| `build-transcription-bench.sh` | `transcription-bench` |
| `tests/args_test.sh` | Argument parsing of `debug`, `record`, `ui`, `see`, `screenshot` and `screenshots collect`, and the fixture's stale-app check, against a fake adb. Run it with `bash toolkit/android/tests/args_test.sh` |
| `tests/help_test.sh` | Every command's `--help`, and that its flags are the ones this file and the usage list name. Run it with `bash toolkit/android/tests/help_test.sh` |

`toolkit/shared` provides what iOS uses too: `record-frames.sh` (frames and contact sheets), `compare.sh` (`compare`), `logfmt.sh` (`--level`), `scripts.sh` (script names and the check summary of `debug`), `vision.sh`, and `parity/` (the extractors and `parity.py` behind `sync`).

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
| `ANDROID_PUSH_RECEIVER` | `.debug.DebugPushReceiver` | The debug-only receiver `push` broadcasts to; `package/class`, or a class where a leading `.` means the module's namespace |
| `TOOLKIT_SERVER_ENABLED` | `false` | `adb reverse` on every launch, server check before tests |
| `TOOLKIT_DEBUG_SCRIPTS` | `false` | `debug --script` and `record --script` |
| `TOOLKIT_LOGS_ENABLED` | `true` | `logs` and `debug` |
| `TOOLKIT_SENTRY_ENABLED` | `false` | `sentry` queries, with `SENTRY_ORG` and `ANDROID_SENTRY_PROJECT` |
| `ANDROID_SENTRY_PROJECT` | none | The Sentry project `sentry` reads |
| `TOOLKIT_UPLOAD_ENABLED` | `false` | `upload` and `promote` |
| `DEPLOY_TAG_PREFIX` | `android/v` | The upload tags; the number after it is the versionCode |
| `ANDROID_PLAY_TRACKS` | `internal` | The tracks an upload ends on, comma-separated. It always goes to `internal` first and is promoted to the others, as `TESTFLIGHT_GROUPS` hands an iOS build on |
| `ANDROID_PLAY_RELEASE_STATUS` | `completed` | The status of every release `upload` and `promote` make. `draft` while Play still calls the app a draft app |
| `ANDROID_KEY_ALIAS` | `upload` | The key's alias in the upload keystore |
| `ANDROID_KEYSTORE_PATH` | none | A keystore file to sign with in place of the keychain's `ANDROID_KEYSTORE`, as `IOS_KEY_PATH` names the App Store key |
| `ANDROID_DEBUG_TOOLS_PACKAGE` | `<package>.debug` | The package `preflight` and `upload` refuse to find in the release bundle |
| `ANDROID_EMULATOR_PROFILE` | `pixel_8` | The avdmanager device profile `emulator create` and `setup` use while `ANDROID_EMULATOR_AVD` doesn't exist |
| `ANDROID_EMULATOR_HARDWARE` | the iPhone 17 Pro's canvas | `config.ini` keys written into that first AVD: `hw.lcd.width=1206 hw.lcd.height=2622 hw.lcd.density=480 hw.ramSize=3072 hw.audioInput=no hw.camera.back=virtualscene hw.camera.front=emulated hw.keyboard=yes PlayStore.enabled=no` and a 1206x2622 skin without a frame |
| `TOOLKIT_ARCH_CHECKS` | `true` | Runs the grep gates of `build-lint.sh` and the project's `lint.sh` in `build` and `lint`, and the parity gate |
| `ANDROID_SOURCE_DIR` | the parent of the first `model/` under `app/src/main/kotlin` | The app's Kotlin root for the architecture gates |
| `ANDROID_TRANSPORT_FILE` | `service/APIClient.kt` | The transport the purity and construction gates check |
| `ANDROID_RIPPLE_FILE` | `view/component/TopBarIconButton.kt` | The one file that may draw a ripple |
| `ANDROID_CAMERA_OWNER` | `CameraController.kt` | The one file that may call `bindToLifecycle` |
| `TOOLKIT_LINT_HOOK` | `lint.sh` | The project's own checks, run after the gates |
| `TURN_ROOT` | the project's parent when it has `shared/` | The folder with `shared/` that the token and icon gates read. `sync` doesn't use it: it reads the repository the project sits in |
| `TOOLKIT_DEBUG_TIMEOUT` | `600` | Seconds a scripted `debug` waits for `DEBUG_SESSION_ENDED` |
| `TOOLKIT_FIXTURE_SESSION_CMD` | `./build.sh fixture session` | Run with the slot before `--fixture` launches |
| `ANDROID_TRACE_PROCESSOR` | the one in androidx.benchmark's benchmark-common in the Gradle cache | The `trace_processor_shell` that `profile` runs on the device |
| `COMPARE_IOS_REFERENCE` | none | The iOS frames `compare` reads when `--ios` is left out |
| `TOOLKIT_FIXTURE_GRANTS` | empty | Runtime permissions granted before every `--fixture` launch (space-separated), so no system dialog pauses an unwatched script run |
| `TOOLKIT_OVERNIGHT_DIR` | `<main checkout>/../output/overnight` | Locks, night folders |
| `TOOLKIT_NIGHT_DATE` | the newest night with a queue | Fixes which night folder `blocker add` and `doctor --watch` use |
| `TOOLKIT_LOCK_TIMEOUT` | `1200` | Seconds a command waits for a lock |
| `TOOLKIT_EMULATOR_LOCK` | none | A name for a separate emulator lock, `emulator-<name>`: commands take it in place of `emulator`. For an emulator nobody else uses, for example one kept open for a person to look at |
| `TOOLKIT_WORKTREE_DIR` | `<checkout>-<project folder>-work` (`turn-android-work`), or `<parent>-<checkout>-work` for a project at the repository's top | Where package worktrees go |
| `TOOLKIT_WORKTREE_BRANCH_PREFIX` | `pkg/` | Branch name before the package name |
| `TOOLKIT_WORKTREE_COPY` | `local.properties build.properties.local` | The project's gitignored files copied into a new worktree |
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

`./build.sh android <command> --help` prints a command's help: its own usage text where it has one (`doctor`, `record`, `ui`, `sync`, `lock`, `blocker`, `night`, `worktree`, `icons`, `transcription-bench`, `profile`, `benchmark`, `compare`, `emulator`), else its rows and section of this file.

### Build

| Command | Does |
|---|---|
| `setup [--force]` | First-time setup, safe to re-run: accepts the SDK licences (sdkmanager asks you) when none are, installs the missing SDK packages (platform-tools, emulator, the module's `compileSdk`, `ANDROID_BUILD_TOOLS`, `ANDROID_EMULATOR_IMAGE`), makes `ANDROID_EMULATOR_AVD` when it doesn't exist (`emulator create`), writes `sdk.dir` to `local.properties` when it is missing, runs `gradlew --version`, then assembles the app. A re-run finds everything in place and only builds. `--force` runs `clean` before the build. Needs the SDK's command-line tools (`cmdline-tools/latest`). |
| `bundle` | `:app:bundle<Type>`, and prints the `.aab`'s size and path. |
| `build` | `ktlintFormat`, then `ktlintCheck` and `detekt` (each when the Gradle build applies the plugin) and the arch checks, then `:app:assemble<Type>`. Prints `✓ Format passed`, `✓ Lint passed`, `✓ Build complete`. |
| `clean` | `gradle clean` and removes `build/` (screenshots, recordings, logs). |
| `test [filter] [timeout] [--no-build\|--build-only]` | `:app:test<Type>UnitTest --rerun`. The filter is a class name (`FeedLoadTests`) or `Class/method`. Stops Gradle after the timeout (120 s). Prints the verdict from the JUnit reports: `✓ 12 tests passed` or `✗ 2 of 12 tests failed:` and one line per failure. `--no-build` is accepted; Gradle compiles only what changed anyway. Asks the server first when `TOOLKIT_SERVER_ENABLED=true`. `--build-only` compiles the tests (`:app:compile<Type>UnitTestKotlin`) without running them and without asking the server, and prints `✓ Tests build`. |
| `test instrumented [filter] [timeout] [--build-only] [--keep-installed]` | `:app:connected<Type>AndroidTest` on one device: the `--device` selector, else the running emulator (booted when nothing is connected), else the one phone. A filter `Class` or `Class/method` is looked up under `src/androidTest` for its package and passed as the runner's `class` argument; a dotted name is passed as it is. Same timeout and verdict as `test`, from the reports in `build/outputs/androidTest-results/connected/`. `--build-only` assembles the test APK (`:app:assemble<Type>AndroidTest`). `--keep-installed` leaves the app and its data on the device after the run, for a test that checks what a second run in a new process finds. Takes the emulator lock. |
| `lint` | The `build` checks, then Android Lint (`:app:lint<Type>`). |
| `unused` | Assembles the profile build (R8) and lists the app's classes and members in `build/outputs/mapping/profile/usage.txt`; fails when there are any. iOS: Periphery. |
| `analyze` | Android Lint with compose-lints and `-Pturn.lint.strict=true`, which makes every warning an error. |
| `audit` | Lists the `// lint:allow` overrides, then runs `lint`, `unused` and `analyze`. |
| `format` | `ktlintFormat`. |

Gradle's output goes to `build/logs/gradle-<command>.log`. On failure the toolkit prints the compiler errors, the failing tasks and Gradle's "What went wrong", then the log's path. Every Gradle call takes the gradle lock. While the night's `down/network` flag is set, Gradle runs `--offline`.

### App

| Command | Does |
|---|---|
| `install [target] [--quiet] [--no-launch] [--fixture [slot]]` | `build`, then `adb install -r -d`, `adb reverse tcp:8080 tcp:8080` (with the server on) and `am start -W -S`. `--quiet` is accepted for iOS parity; the emulator window is never brought forward. `--no-launch` installs without opening the app and compiles it with `cmd package compile -m speed-profile -f`, the state a Play install leaves, so the next launch is the first after an install (for launch measurements); it prints `✓ Installed, not launched`. |
| `launch [target] [--fixture [slot]] -- [extras...]` | Installs the built APK and launches it, forwarding am start extras (`--es key value`, `--ez key true`). Builds first when there is no APK. |
| `uninstall [target]` | Stops the watcher and the app and uninstalls it. Unlike iOS, which shuts the simulator down, the emulator keeps running: other work shares it. |
| `watch [target] [kotlin\|build]` | `build` and launch, then redeploy on every change: `kotlin` (default) rebuilds when a `.kt` file under `<module>/src` changes; `build` reinstalls whenever `.watch/build.stamp` is touched. 2 s between rounds. Takes the emulator lock only while it installs. Needs `fswatch`. `uninstall` stops it. |
| `logs [target] [--cat <cat>] [--level <level>] [--process <name\|all>] [--minutes M] [N\|tail]` | The last N lines (default 10) of the last M minutes (default 15) of the app's log lines (tag `ANDROID_LOG_TAG`) as `HH:MM:SS.mmm  LEVEL [cat] msg`. `--cat all` shows every line of the running app's process. `--process <name>` shows every line of that running process (`pidof`), for example `system_server`, whose `ActivityManager` lines say why an app process died; `--process all` every line on the device. Other tags read `HH:MM:SS.mmm  P/Tag: msg`. `tail` streams new lines of the app and takes neither `--process` nor `--minutes`. |
| `debug [target] [--cat] [--level] [--script <names>] [--no-build] [--timeout N] [--fixture [slot]]` | Below. |
| `signin [target] [email code]` / `signout [target]` | `debug <target> --no-build --script sign_in` or `sign_out`; the target defaults to `emulator`. The login comes from `SCRIPT_ENV_TURN_LOGIN_EMAIL` and `_CODE`, or the two arguments. |

`--fixture [slot]` (slot from `AGENT_SLOT`, else 1) runs `./build.sh fixture session <slot>` first, because a refresh token works once, then passes `FIXTURE_SLOT_<slot>_REFRESH_TOKEN` and `FIXTURE_SLOT_<slot>_CLOCK` from `build.properties.local` as the extras `TURN_DEBUG_REFRESH_TOKEN` and `TURN_CLOCK`. The app keeps the slot and reset instant it was seeded with in `files/toolkit-fixture-seed`. When they differ from the slot's now (the slot was reset, or another slot seeded the app), or the app was never seeded, the toolkit runs `pm clear` first, so the app drops the old account's keys, and grants the runtime permissions it had again. Builds that aren't debuggable, and an app not installed yet, are left alone.

`TURN_CLOCK` (an ISO 8601 instant) starts the debug build's `AppClock` at that instant, so frames show the same relative times on any day. `--fixture` passes the slot's reset instant. For other launches, `ANDROID_LAUNCH_ARGS="--es TURN_CLOCK 2026-11-17T23:47:43Z"` does what `IOS_LAUNCH_ARGS="-TURN_CLOCK 2026-11-17T23:47:43Z"` does on iOS, for every launch of `debug`, `record`, `launch` and `install`; it comes after the other extras, so it wins over the fixture's clock.

### debug

1. Builds unless `--no-build` (which still builds when no APK exists), takes the emulator lock, installs and reverses the server port.
2. With `--script`: clears `cache/scriptor-ready` with `run-as` and passes `TURN_DEBUG_SCRIPT_NAMES`, every `SCRIPT_ENV_<NAME>` and the `signin` login as extras. Builds that aren't debuggable (`--config profile`) get `TURN_DEBUG_SCRIPT_NO_MARKER=1` instead of the marker.
3. Notes the device's time, streams `logcat -T <that time>` so nothing logged during launch is lost, and launches with `am start -W -S`.
4. One second later, writes the marker with `run-as`.
5. Shows the app's lines, filtered by `--cat` and `--level`, until `DEBUG_SESSION_ENDED` (`✓ App backgrounded, session ended.`) or the process it launched ends (`✓ App stopped, session ended.`).
6. After a script run, prints each script's `SCRIPT_RESULT` line (`lens_check: 4 passed, 0 failed`), then `✓ Every check passed.`, or `✗ <n> check(s) failed:` with each failed check, or `✗ The app stopped before its scripts ended.` The last two exit 1. The summary functions are `_note_script_line` and `_script_summary` in `toolkit/shared/scripts.sh`, the same as iOS.

The target and the flags come in any order. A second target or an unknown flag stops the run. A scripted run also fails when no `[scriptor]` line arrives within 40 s (the build has no script runner), or after `--timeout` seconds (default 600) without `DEBUG_SESSION_ENDED`; a timeout prints the results the scripts logged so far.

### Screen

| Command | Does |
|---|---|
| `emulator start [avd] [--window]` | Boots the AVD (default `ANDROID_EMULATOR_AVD`) unless that AVD is running already, whatever other emulators run; headless and silent unless `--window`, which has sound, and waits until Android has finished booting. Its log is `build/emulator/emulator.log`. |
| `emulator stop [avd]` | Shuts that AVD's emulator down (default `ANDROID_EMULATOR_AVD`), never another one. |
| `emulator status` | Lists the connected emulators (with their AVD) and phones (with their model). |
| `emulator restart [avd\|serial]` | Shuts the running emulator down (`adb emu kill`) and boots the same AVD headless with `-no-snapshot-load`, a cold start with fresh system services, as `ios simulator restart`. |
| `emulator create <name> [--image <package>] [--profile <device>]` | Makes an AVD with `avdmanager`, unless one of that name exists, and prints its name last. Without `--profile` it copies the hardware of `ANDROID_EMULATOR_AVD` (screen, density, memory, cameras, no microphone, no Play Store); the image is `ANDROID_EMULATOR_IMAGE` unless `--image`. For `Turn_Min` (`--image "system-images;android-31;google_apis;arm64-v8a"`) and `Turn_Journey`. |
| `emulator front [avd\|serial]` | Brings the app forward with the launcher's own intent (`MAIN`, `LAUNCHER`, `--activity-reorder-to-front`), as a tap on its icon: the running process keeps its state. Starts the app when it isn't running. |
| `emulator contact [avd\|serial] <file.vcf>` | Reads the vCard's cards (name from `FN` or `N`, every `EMAIL` and `TEL`), adds each as a contact through `content insert` on `raw_contacts` and `data`, copies the file to `/sdcard/Download/`, and grants the app `READ_CONTACTS`. Says so when the app isn't installed or doesn't ask for the permission. The Contacts app's import needs a tap, so it isn't used. |
| `emulator text-size [size]` | Sets `font_scale` from the iOS Dynamic Type names: extra-small 0.82, small 0.88, medium 0.94, large 1.0, extra-large 1.12, extra-extra-large 1.24, extra-extra-extra-large 1.35, accessibility-medium 1.64, accessibility-large 1.95, accessibility-extra-large 2.35, accessibility-extra-extra-large 2.76, accessibility-extra-extra-extra-large 3.12. No size prints the current one. Android caps nonlinear scaling at 2.0 on API 34+, so the top three look alike there. |
| `push <payload.json>`, `emulator push <payload.json>` | Hands the payload, compacted to one line, to the debug build's receiver with `am broadcast -n <app>/<receiver> --es payload <json>`. The receiver is `ANDROID_PUSH_RECEIVER`, default `.debug.DebugPushReceiver` (a leading `.` means the module's `namespace`, so Turn's is `com.sendaturn.app.debug.DebugPushReceiver`); it hands the payload to the code the messaging service calls. Refuses when the installed app has no such receiver. No FCM is involved. |
| `screenshot [target] [name]` | Saves the screen to `build/screenshots/<name>.png` (default `turn_<date>-<time>.png`), says which device it came from, and prints the absolute path last. |
| `screenshots collect [target]` | Copies the PNGs debug scripts saved in the app's `files/DebugScreenshots` (through `run-as`, or for builds that aren't debuggable from `/sdcard/Android/data/<app>/files/DebugScreenshots`) into `build/screenshots/`. Prints each path, then `✓ Collected N screenshot(s)`. Same names overwrite. |
| `see [target] [--focus "<question>"]` | Captures the screen and describes it with the vision model (`toolkit/shared/vision.sh`). For models that can't read images. |
| `record [target] [name] [--seconds N] [--script <names>] [--frames <fps>] [--fixture [slot]]` | Records with `screenrecord` to `build/recordings/<name>.mp4`, at most 180 s (screenrecord's limit). Encoders refuse the full 1206x2622 screen, so the video is scaled to 1920 pixels on the long side (884x1920), same aspect. `--script` relaunches the app with the scripts once recording runs, without the marker. `--fixture` (with `--script`) seeds that launch as `debug --fixture` does, fetching the session before the recording starts. `--frames` cuts frames and 8 x 6 contact sheets into `build/recordings/<name>/`, as on iOS. Ctrl-C stops early and keeps the video. Unlike `debug`, it neither builds nor installs. |
| `compare <scripts> [target] [--fixture [slot\|standard]] [--no-build] [--ios <dir>] [--android <dir>] [--out <dir>] [--timeout N]` | Runs each debug script, collects its frames and writes `build/compare/<run>/index.html`: the iOS and Android frame of each frame name side by side, a frame missing on either side marked, and both sides' `[scriptor]` and `[perf]` lines aligned with failed checks highlighted. The iOS side is read from frames already made (`--ios`, else `COMPARE_IOS_REFERENCE`), a reference run on slot 8; compare doesn't run the simulator. `--android` takes frames already collected, and nothing runs. `build/compare/latest` points at the newest run. |
| `ui tap <x> <y>` | Taps at dp. |
| `ui tap --id <id>` | Taps the element with that resource id. Compose test tags appear as resource ids when the app sets `testTagsAsResourceId = true` on its root. |
| `ui tap --label <text>` | Taps the first element whose text or content description matches, exactly first, then as a substring. |
| `ui swipe <x1> <y1> <x2> <y2>` | Drags between two points in dp over 300 ms. |
| `ui swipe up\|down\|left\|right` | A full-screen swipe, with the same start and end points as iOS. |
| `ui type <text>` | Types into the focused field. ASCII only: `adb shell input text` can't type other characters, so it refuses them. |
| `ui press home\|back\|lock` | Presses a button. `back` exists only on Android. |
| `ui describe [name]` | Prints the view tree, one line per node (`class \| 'label' \| id=... \| x y w h` in dp), and saves it to `build/screenshots/<name>-ui.txt`. A tappable node with no text or content description, in itself or below it, ends in `\| no label`: TalkBack has nothing to read for it. |

### ui

Every `ui` action except `describe` takes a screenshot afterwards and prints its path last. `--no-shot` skips it; `--delay <ms>` changes the wait before it (700 by default).

`ui` reads the screen through `uiautomator dump`, which sees what the accessibility tree sees. Taps and swipes go through `adb shell input`, scaled from dp to pixels with the device's density.

A dump fails while an endless animation keeps the screen from going idle. After a failed dump, `ui` broadcasts `<app id>.HOLD_MOTION` with `--ez hold true` to the app, tries again three times 500 ms apart, then sends `hold false`. The debug build's receiver pauses the app's own endless transitions while held; a build without one ignores the broadcast.

### Performance

| Command | Does |
|---|---|
| `profile [target] [--script <names>] [--seconds N] [--render] [--name <label>] [--gfxinfo] [--main] [--until <seconds>] [--callers <function>] [--trace <file>] [--fixture [slot]]` | Records a Perfetto trace of the installed app for N seconds (default 40) into `build/traces/` and prints the FrameMonitor lines, CPU time per thread, the heaviest functions and the app's own code, as `ios profile` does. `--script` launches with those debug scripts, `--fixture` seeds that launch. `--render` adds frame times and missed deadlines, `--gfxinfo` the frame counts of `dumpsys gfxinfo`. `--main` keeps only the main thread, with its busy time per quarter second. `--until` keeps the first seconds (a launch). `--callers` shows what was on the stack whenever a matching function ran. `--trace` summarises a recorded `.pftrace` again without recording. Callstacks need a profile or debug build. It installs only when the built APK differs from the installed one. For a first launch after an install: `--config profile install --no-launch`, then `--config profile profile --until 5`. |
| `benchmark [target] [Class[#method]] [--build-only] [--fixture [slot]]` | Builds the profile build and the `benchmark` module and runs the Macrobenchmarks: `StartupBenchmark` (cold launch) and `DeckSwipeBenchmark` (`deck_swipe_perf`'s frames), or the one named. `--fixture` hands them a fresh session of the fixture slot. `--build-only` builds without a device, and fills the Gradle cache with the `trace_processor_shell` that `profile` uses. Numbers from the emulator only show regressions; measure on a phone. |

### Play

| Command | Does |
|---|---|
| `preflight` | The upload's release bundle (`:app:bundleRelease`, unsigned) and its checks, without uploading: the merged manifest isn't debuggable, and R8's mapping holds no class of `ANDROID_DEBUG_TOOLS_PACKAGE`. As `ios preflight`. |
| `upload [--dry-run] [--force] "release notes"` | Below. |
| `promote <track> [--from <track>] ["release notes"]` | Hands the newest release on `internal` (or `--from`) to the track with Gradle Play Publisher's `promoteReleaseArtifact`, with the notes given or else those of the newest upload tag. As `ios testflight <build>`, except that Play promotes a track's release, so it takes no versionCode. |

### upload

1. Doctor, the clean tree, the branch and `origin`, as `ios upload`. The next tag is `DEPLOY_TAG_PREFIX` plus the number of upload tags plus one; that number is the bundle's versionCode (`ANDROID_VERSION_CODE` for Gradle).
2. Asks before it goes on, unless `--force`. Tags the commit, and pushes the tag when there is an `origin`.
3. Builds `:app:bundleRelease` signed with the upload key, without the Gradle daemon, then checks it as `preflight` does and verifies its signature with `jarsigner` against the key's SHA-256.
4. Uploads it to the `internal` track (`publishReleaseBundle`, the notes as `src/release/play/release-notes/en-US/default.txt`, removed after), then promotes it to each other track of `ANDROID_PLAY_TRACKS`.
5. Annotates the tag with the versionCode, commit, time, tracks and notes, and logs the upload in `.watch/deploy.log`.

`--dry-run` runs steps 1 and 3 and stops: no question, no tag, nothing sent to Play, and uncommitted changes only warn. Without an upload key it signs with a throwaway key it makes in `build/upload/THROWAWAY-dry-run-key-NOT-the-Play-upload-key.p12`, which Play would refuse. With the upload key it gives the signed bundle for the first upload, which Play takes only by hand in Play Console. After that upload, tag its commit `git tag -a android/v1 -m "build: 1 | first upload by hand"`, so the next upload's versionCode is 2.

The secrets come from the environment, else from `keychain()` refs in the project's gitignored `.env.local`, read with `varlock printenv` as the server reads its own:

- `ANDROID_KEYSTORE`: the upload keystore, base64. Written to `build/upload/upload-key.jks` for the build and removed after it. `ANDROID_KEYSTORE_PATH` names a file instead.
- `ANDROID_KEYSTORE_PASSWORD`: its password, also the key's.
- `ANDROID_PLAY_JSON_KEY`: the Play service account's JSON key, handed to Gradle Play Publisher as `ANDROID_PUBLISHER_CREDENTIALS` for the publish and promote steps only. The app module keeps the plugin off without it, so no other build reaches Play.

To store them, in the Android folder:

```
keytool -genkeypair -keystore upload.jks -alias upload -keyalg RSA -keysize 4096 -validity 10000
base64 -i upload.jks | tr -d '\n' | pbcopy
varlock keychain set ANDROID_KEYSTORE --project turn-android --write-to .env.local
varlock keychain set ANDROID_KEYSTORE_PASSWORD --project turn-android --write-to .env.local
varlock keychain set ANDROID_PLAY_JSON_KEY --project turn-android --write-to .env.local
```

Paste the copied keystore at the first `set`, the password at the second and the JSON key file's contents (`tr -d '\n' < key.json | pbcopy`) at the third. Keep `upload.jks` and its password somewhere safe outside the Mac, then delete the file here: Play can reset a lost upload key, but only through its support.

### icons

| Command | Does |
|---|---|
| `icons [generate\|check\|scan\|sheet]` | `generate` (the default) downloads the Material Symbols that `icons.toml` maps the iOS SF Symbols to, writes `res/drawable/ic_*.xml` and `view/generated/TurnIcons.kt`, and deletes drawables nothing maps. It fails when an SF name in the iOS sources isn't in `icons.toml`. `check` does the same checks offline, with every `TurnIcon("...")` call in the app; `lint` runs it. `scan [--commit <c>]` lists the SF names in the iOS sources with their sites, `!` marking the unmapped ones. `sheet [--out <dir>]` writes the review page, SF and Material side by side. |

### sentry

`sentry <events [N] | issues [status] [N] | event <id> | issue <short-id> [all] | resolve <short-id>...>` runs the queries of `toolkit/shared/sentry.sh`, the same as iOS, on `ANDROID_SENTRY_PROJECT`. It needs `TOOLKIT_SENTRY_ENABLED=true`, `SENTRY_ORG`, the project, and a token in `SENTRY_AUTH_TOKEN` or `~/.sentryclirc`; `events` also needs `sentry-cli`.

### Overnight work

| Command | Does |
|---|---|
| `lock <gradle\|emulator> -- <command...>` | Runs the command holding a lock shared by every checkout and worktree. gradle has two holders, emulator one. Waits up to 20 minutes, then fails and suggests a `lock-timeout` blocker. With `TOOLKIT_EMULATOR_LOCK=<name>` the emulator lock is `emulator-<name>`, shared only by commands run with the same setting. |
| `lock status` | Who holds each lock, and stale ones. |
| `night init <date> [--ios-commit <sha>] [--exclude "<IDs>"] [--force]` | Creates `<overnight>/<date>/` with empty `blockers.jsonl`, `progress.jsonl`, `notifications.jsonl`, the `down/` folder, and `queue.json` with every package of waves 1 to 4 in `doc/packages.md`, all `waiting`. Rows named ", phase 2" or ", only if" are left out; dependencies outside the queue (wave 0) are dropped. Keeps an existing `queue.json` unless `--force`. |
| `blocker add --kind <kind> --summary "<text>" [...]` | Appends one JSON line to the night's `blockers.jsonl` (`blockers.md` 6.2) and prints its path. Fills in the time, agent, worktree, branch and package. More fields: `--severity blocks-step\|blocks-package\|blocks-all\|degraded` (default `blocks-step`), `--needs` (what a person must do), `--evidence <path>`, `--tried` (once per attempt), `--switched-to`, `--package`, `--agent`, and `--status resolved` when it clears. `blocker --help` lists the kinds. |
| `worktree new <package> [--from <ref>]` | Below. |
| `worktree remove <package> [--force]` | Below. |
| `worktree list` | The package worktrees and their branches. |
| `doctor [--quick] [--json] [--watch [minutes]]` | Below. |

### lock

Commands take the locks themselves: Gradle calls the gradle lock; `install`, `launch`, `uninstall`, `debug`, `record`, `screenshot`, `screenshots collect`, `see`, `ui`, `push`, `test instrumented`, `watch` and every `emulator` command except `status` and `create` the emulator lock (after building, so no one holds the emulator while waiting for Gradle). Commands run under `lock` reuse the lock they hold (`TOOLKIT_LOCKS_HELD`), so one lock covers a sequence:

```
./build.sh android lock emulator -- sh -c './build.sh android debug --script lens_check && ./build.sh android screenshots collect'
```

A lock is a directory per holder in `<overnight>/locks/` with the owner's PID and start time. A holder that exited, even with `kill -9`, is cleared on the next take.

### sync

The parity map compares the leading platform's Swift with the project's Kotlin, symbol by symbol, and the ledger under `sync/` records which iOS blob each unit was ported from. iOS is read from commits of the repository the project sits in (read-only), never from the working tree. The target is a commit the current branch contains: main's head when the branch has no commit under the iOS roots or `shared/` that main lacks, else `HEAD`. `--to` picks another commit; `mark` takes only one the branch contains. When main has iOS commits the branch lacks, `status` and `plan` say so.

| Command | Does |
|---|---|
| `sync status [--to <commit>] [-v]` | Lists shared inputs and units whose iOS files changed, were renamed (with git's similarity), added or deleted since the ledger's blobs. Per unit: the Android files, the diff stat, the commits that touched the files, symbols added, removed, changed and moved between units, and interaction APIs in the diff. `-v` prints the diffs. Exit 1 while anything is pending. |
| `sync diff <unit> [--to <commit>]` | The iOS diff of one unit since its ledger commit; for a unit new on iOS, since the marker. |
| `sync mark <unit>... [--to] [--status <s>] [--no-change "<reason>"]` | Records the units at the iOS commit with their Android blobs. Refuses a unit whose iOS side changed while its Android files did not (unless `--no-change`), a unit whose mirrored Kotlin file is missing, and one that fails the parity check at that commit. A renamed unit replaces the old one; a unit deleted on iOS is removed once its Kotlin files are gone. The status defaults to `ios-only` or `deferred` for a unit `parity.toml` lists so (its reason becomes the note), else `ported` once no `TODO("port:` is left, else `stub` or `partial`. Refuses a commit the branch doesn't contain. |
| `sync mark --commit [--to]` | Moves the marker in `sync/_sync.toml` and records the shared inputs, refusing while any unit is pending. |
| `sync plan [--to <commit>] [--out <dir>] [--max-packages <n>]` | Groups the pending units into packages and writes one brief per package and `plan.json` to `build/sync/<date>/` (or `--out`). Units start grouped by folder (`view/screen`, `view/component`, `model`, ...) in runs of at most 25; a test joins the unit it is named after, a view joins the `model/` unit that declares a type it uses. A package that uses a symbol another package adds waits for it: `wave` and `after` in `plan.json`, and packages waiting on each other become one. The smallest packages of a wave merge until at most `--max-packages` (4) are left. A brief has the units, the steps, the commit messages, the symbol changes, interaction APIs, flagged wording, the scripts and frames from `sync/coverage.json`, and each unit's iOS diff. With nothing pending it says so and exits 0. |
| `sync behind` | One line against main's head: `Android is N units behind main`, `Android is behind main in N shared files` or `Android is in sync with main`. Reads only git and the ledger, in well under a second, and always exits 0. |
| `sync map [--gate] [--at <commit>] [--unit <u>]` | Writes `build/parity/map.json` and `map.md`. `--gate` fails on a strict-tier symbol with no Kotlin twin, a misnamed or moved twin, an Android-only symbol or file with no reason in `parity.toml`, and names missing from the guide's Coverage block. `build` and `lint` run it. |
| `sync init --at <commit> [--force]` | Writes one ledger file per unit: `stub` where Kotlin files exist, `todo` where none do, `ios-only` per `parity.toml`. |
| `sync coverage [<log>\|-]` | Reads `[coverage] script=<name> frame=<frame> views=<A,B>` log lines into `sync/coverage.json` and names view units no script shows. |
| `sync guide [--seed] [--at <commit>]` | Checks the fenced `toml` block under `## Coverage` in the porting guide (`source.guide` in `parity.toml`, default `doc/platform-mapping.md`), or prints a seeded block with every iOS import and framework type. A guide that doesn't exist yet is skipped. |

The extractors build on first use into `build/parity-tools/`: the Swift one with swift-syntax (SwiftPM, about two minutes, offline once the package is in SwiftPM's cache), the Kotlin one with the Kotlin compiler's PSI from the Gradle cache, under the gradle lock. Results are cached per git blob in `build/parity/cache/`, so a warm map takes under a second.

The map reads the JVM tests (`android_tests` in `parity.toml`) and the instrumented ones (`android_instrumented_tests`). An iOS test file maps to the instrumented file when only that one exists. An abstract test base, the counterpart of an iOS `XCTestCase` subclass the tests inherit from, counts as a test class with no methods.

`parity.toml` holds the rules: source roots, tiers, how file names and enum cases change, split and moved files, renames, the type map for framework types, and the iOS-only and Android-only lists with their reasons.

### transcription-bench

| Command | Does |
|---|---|
| `transcription-bench [target] [push\|run\|report\|clean] [--corpus <dir>] [--engines <list>] [--prompts <list>] [--clips <ids>] [--baseline <file>] [--results <file>] [--timeout <s>] [--json]` | Runs a corpus of clips through the app's transcription engines and prints the scores per engine and language. `--engines` is `whisper` (default), `google` or both; `--prompts` is `app`, `none` or both (default). `--results` names a result file for `report`, once per phone (default the newest). `--timeout` is how long `run` waits for the script (default 14400 s). `--json` prints the report as JSON. |

The transcription quality test's host side. `push` copies the clips that the corpus's `manifest.json` names (default `build/transcription-corpus`, with human reference lines per clip) into the debug app's `files/transcription-bench/` with `run-as`, and a list of ids and files without the references. `run` launches the debug script `TRANSCRIPTION_BENCH_SCRIPT` (`transcription_benchmark`) with `--prompts` and `--clips` as launch extras and pulls its `results.json` into `build/transcription-bench/<serial>-<time>.json`. `report` scores result files with `transcription_bench.py`: WER after normalising (lower case, no accents or punctuation, numbers spelled out), the switching clips' WER and words in the wrong language, caption start error, words on negative clips, real-time factor, first load, memory and thermal status, with the pass marks against `--baseline`. Without a step it does all three. `clean` removes the folder from the app, the benchmark's own model copy included. Its tests: `python3 -B toolkit/android/tests/transcription_bench_test.py`.

### worktree

`worktree new <package>` adds `<TOOLKIT_WORKTREE_DIR>/<package>`, a worktree of the whole repository the project sits in, on a new branch `pkg/<package>` from the main checkout's current branch. Each submodule is cloned from the main checkout's own folder (`git -c protocol.file.allow=always -c submodule.<name>.url=<main>/<path> submodule update --init`, no network), the project's `local.properties` and `build.properties.local` are copied, and the worktree's root is printed last. Run `./build.sh android ...` there. The submodule is checked out at the commit the branch pins; when the main checkout's submodule is ahead, it says so, because worktrees only get toolkit changes once the pointer is committed.

`worktree remove <package>` refuses while the worktree has uncommitted changes or its branch isn't merged into the main checkout's branch. Then it removes the worktree (git needs `--force` for a worktree with submodules) and deletes the branch with `git branch -d`. `--force` removes it anyway and keeps the branch.

### doctor

Read-only: it never installs anything, never prompts, never starts the server and never reads the keychain. Each check prints `✓`, `⚠` (works, but a risk) or `✗` (blocks), with the fix. Exit 1 when any check fails.

Checks: power and caffeinate, free disk (30 GB, 12 GB), memory and swap, heavy apps, the JDK and a stale `JAVA_HOME`, adb, emulator, sdkmanager, avdmanager, the Gradle wrapper, python3 3.11+, ffmpeg, jq, fswatch, the SDK and its packages (platform-tools, emulator, the module's `compileSdk`, `ANDROID_BUILD_TOOLS`, `ANDROID_EMULATOR_IMAGE`), licences, the AVD (no microphone, no webcam), the emulator booted, phones connected, `adb reverse`, the Gradle cache, wrapper and memory settings, the local server, Postgres, network (Google, Maven Central, Anthropic), `toolkit/` checked out, `build.properties.local`, the scode sandbox, `HOMEBREW_NO_AUTO_UPDATE`, App Store auto updates, and the overnight flags (`ACTIVE`, `RESTART_OK`, `STOP`, `down/`).

`--quick` runs power, disk, memory, emulator, server and network, in about a second. `--json` prints one object per check: `{"check","status","detail","fix"}`. `--watch [minutes]` runs `--quick` every N minutes (default 5) into the night's `watch.log` and sets or clears `down/disk` (below 12 GB; below 5 GB it also writes `STOP`), `down/memory` (below 15 % free or more than 8 GB swap), `down/server`, `down/emulator` and `down/network`. `gradle` and `xcode` flags are left to agents and the user.
