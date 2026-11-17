#!/bin/bash
# android-toolkit/build-setup.sh: first-time setup of the SDK, the AVD and the build
# Sourced by build.sh. Re-runs do only what is missing, then build.
#
# Provides: do_setup, _sdk_required_packages
# Depends on: _resolve_java_home, _gradle_require, _gradle_run, _gradle_failure,
#             _gradle_log, _assemble, do_clean (build-gradle.sh)
# Depends on: _emulator_create (build-emulator.sh)

_sdkmanager_bin() {
    echo "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager"
}

_sdkmanager() {
    local java_home
    java_home=$(_resolve_java_home) || return 1
    JAVA_HOME="$java_home" "$(_sdkmanager_bin)" "$@"
}

# The SDK packages the project builds and runs with, one per line, in
# sdkmanager's names: platform-tools, emulator, the module's compileSdk,
# ANDROID_BUILD_TOOLS and ANDROID_EMULATOR_IMAGE.
_sdk_required_packages() {
    local compile
    compile=$(sed -n 's/.*compileSdk *= *\([0-9.]*\).*/\1/p' "$PROJECT_ROOT/$ANDROID_MODULE/build.gradle.kts" 2>/dev/null | head -1)
    echo "platform-tools"
    echo "emulator"
    [[ -n "$compile" ]] && echo "platforms;android-$compile"
    [[ -n "${ANDROID_BUILD_TOOLS:-}" ]] && echo "build-tools;$ANDROID_BUILD_TOOLS"
    [[ -n "${ANDROID_EMULATOR_IMAGE:-}" ]] && echo "$ANDROID_EMULATOR_IMAGE"
    return 0
}

_sdk_package_installed() {
    local dir="$ANDROID_SDK/${1//;//}" found
    found=$(ls -d "$dir" "$dir".* 2>/dev/null | head -1 || true)
    [[ -n "$found" && -f "$found/source.properties" ]]
}

do_setup() {
    local force=false arg
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) echo "✗ Unknown argument: $arg"; echo "Usage: ./build.sh android setup [--force]"; return 1 ;;
        esac
    done

    local java_home
    java_home=$(_resolve_java_home) || return 1
    echo "JDK: $java_home"

    if [[ ! -x "$(_sdkmanager_bin)" ]]; then
        echo "✗ No sdkmanager at $(_sdkmanager_bin)."
        echo "  Install the Android SDK Command-line Tools (Android Studio > SDK Manager > SDK Tools),"
        echo "  or set ANDROID_HOME to an SDK that has them, and run setup again."
        return 1
    fi

    if [[ ! -f "$ANDROID_SDK/licenses/android-sdk-license" ]]; then
        echo "→ The SDK licences need your answer:"
        _sdkmanager --licenses || return 1
    else
        echo "Licences accepted."
    fi

    local package missing=()
    while IFS= read -r package; do
        _sdk_package_installed "$package" || missing+=("$package")
    done < <(_sdk_required_packages)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "→ Installing ${missing[*]}"
        _sdkmanager --install "${missing[@]}" || { echo "✗ sdkmanager could not install them."; return 1; }
    else
        echo "SDK packages up to date."
    fi

    if [[ -n "$ANDROID_EMULATOR_AVD" ]]; then
        if [[ -d "$HOME/.android/avd/$ANDROID_EMULATOR_AVD.avd" ]]; then
            echo "AVD $ANDROID_EMULATOR_AVD up to date."
        else
            _emulator_create "$ANDROID_EMULATOR_AVD" >/dev/null || return 1
            echo "AVD $ANDROID_EMULATOR_AVD made."
        fi
    else
        echo "⚠ No ANDROID_EMULATOR_AVD in build.properties; no AVD made."
    fi

    local local_properties="$PROJECT_ROOT/local.properties"
    if [[ -f "$local_properties" ]] && grep -q '^sdk\.dir=' "$local_properties"; then
        echo "local.properties up to date."
    else
        echo "sdk.dir=$ANDROID_SDK" >> "$local_properties"
        echo "local.properties written."
    fi

    _gradle_require || return 1
    if ! _gradle_run setup --version; then
        echo "✗ The Gradle wrapper failed:"
        _gradle_failure "$(_gradle_log setup)"
        return 1
    fi
    local version
    version=$(sed -n 's/^Gradle \([0-9.]*\).*/\1/p' "$(_gradle_log setup)" 2>/dev/null | head -1 || true)
    echo "Gradle ${version:+$version }ready."

    if $force; then
        do_clean || return 1
    fi
    _assemble || return 1
    echo ""
    echo "Setup done."
    echo "Re-running ./build.sh android setup only builds; use --force to build from clean."
}
