# Android toolkit

The Android commands mirror the iOS ones: same names, same arguments, same output, so a script or an agent that drives one platform drives the other by changing `ios` to `android`. Coordinates are dp, which on a 402x874 dp emulator are the same numbers as iOS points on the iPhone 17 Pro simulator.

The project mounts it with a thin `android/build.sh` that sets `TOOLKIT_PROJECT_ROOT` and calls `_dispatch`, and a `build.properties` next to it. Output goes to `<project>/android/build/` (gitignored).

## Settings

`android/build.properties` (and an optional, gitignored `build.properties.local`):

| Key | Meaning |
|---|---|
| `ANDROID_EMULATOR_AVD` | The AVD that `emulator start` boots, for example `Turn_Parity`. |

The SDK is found through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `~/Library/Android/sdk`.

## Targets

Every command that talks to a device takes an optional target first: `emulator`, `device` (a phone over USB), or a serial from `adb devices`. Without one, the running emulator is used, else the one connected phone. With several of one kind connected, the command refuses and lists them; pick one with `--device <serial>` or `ANDROID_DEVICE`.

A lone argument to `screenshot` is the target only when it is one of those words or a connected serial; otherwise it is the file name, as on iOS.

## Commands

| Command | Does |
|---|---|
| `emulator start [--window]` | Boots the configured AVD, headless unless `--window`, and waits until Android has finished booting. Its log is `build/emulator/emulator.log`. |
| `emulator stop` | Shuts the running emulator down. |
| `emulator status` | Lists the connected emulators (with their AVD) and phones (with their model). |
| `screenshot [target] [name]` | Saves the screen to `build/screenshots/<name>.png` (default `turn_<date>-<time>.png`), says which device it came from, and prints the absolute path last. |
| `see [target] [--focus "<question>"]` | Captures the screen and describes it with the vision model (`toolkit/shared/vision.sh`). For models that can't read images. |
| `ui tap <x> <y>` | Taps at dp. |
| `ui tap --id <id>` | Taps the element with that resource id. Compose test tags appear as resource ids when the app sets `testTagsAsResourceId = true` on its root. |
| `ui tap --label <text>` | Taps the first element whose text or content description matches, exactly first, then as a substring. |
| `ui swipe <x1> <y1> <x2> <y2>` | Drags between two points in dp over 300 ms. |
| `ui swipe up\|down\|left\|right` | A full-screen swipe, with the same start and end points as iOS. |
| `ui type <text>` | Types into the focused field. |
| `ui press home\|back\|lock` | Presses a button. `back` exists only on Android. |
| `ui describe [name]` | Prints the view tree, one line per node (`class \| 'label' \| id=… \| x y w h` in dp), and saves it to `build/screenshots/<name>-ui.txt`. |

Every `ui` action except `describe` takes a screenshot afterwards and prints its path last. `--no-shot` skips it; `--delay <ms>` changes the wait before it (700 by default).

`ui` reads the screen through `uiautomator dump`, which sees what the accessibility tree sees. Taps and swipes go through `adb shell input`, scaled from dp to pixels with the device's density.
