#!/bin/sh
# N3 product NSTextInputClient range smoke. Native callbacks are deterministic; actual Korean
# input-source composition/candidate behavior still needs the separate live IME verification.
set -eu

app_path=${1:?Maru app executable path is required}
live=${2:-0}
smoke_ms=20000
wrapped=0
late_focus=0
fixture_window_size=960x600
if [ "$live" = 2 ]; then wrapped=1; live=1; fi
if [ "$live" = 3 ]; then late_focus=1; live=1; fi
fixture_root=$(mktemp -d /tmp/maru-editor-ime.XXXXXX)
# The editor's pinned parent writer rejects symlink path components; macOS /tmp is one.
fixture_root=$(cd "$fixture_root" && pwd -P)
mkdir -p "$fixture_root/home" "$fixture_root/session-host"
chmod 700 "$fixture_root/session-host"
mkdir -p "$fixture_root/home/.config/maru"
printf 'session.keep-alive-after-quit = false\n' > "$fixture_root/home/.config/maru/config"
printf '%s' 'ab😀한cd' > "$fixture_root/document.txt"
if [ "$late_focus" = 1 ]; then printf '%s' 'L R' > "$fixture_root/document.txt"; fi
printf '%s' 'cat cat' > "$fixture_root/expected.txt"
xcrun swiftc src/platform/macos/SessionHostInputSourcePolicy.swift \
    tests/macos_editor_ime_input_source_policy.swift -o "$fixture_root/test-input-source-policy"
"$fixture_root/test-input-source-policy"
if [ "$live" = 1 ]; then
    smoke_ms=30000
    if [ "$wrapped" = 1 ]; then
        smoke_ms=105000
        fixture_window_size=640x700
        # Option+Return must reach the IME rather than the configured Meta encoder.
        printf 'editor.wrap = true\ninput.option-as-meta = false\ninput.ime-enter = commit-only\n' >> "$fixture_root/home/.config/maru/config"
    fi
    printf '%s' 'left 가
right' > "$fixture_root/expected.txt"
    if [ "$wrapped" = 1 ]; then
        python3 -c 'import sys;sys.stdout.write("x"*320+" 韓")' > "$fixture_root/expected.txt"
    fi
    if [ "$late_focus" = 1 ]; then printf '%s' 'L가 R나' > "$fixture_root/expected.txt"; fi
    xcrun swiftc src/platform/macos/SessionHostInputSourcePolicy.swift \
        src/platform/macos/SessionHostInputSourceRestore.swift -o "$fixture_root/restore-input-source"
    restore_input_source() {
        # The view may see the user's new source before TIS does. The driver revokes its
        # record; retain this guard if that fixture-only removal could not be completed.
        if test -f "$fixture_root/summary.txt" && \
            rg -q '^live_input_source_restore=superseded$' "$fixture_root/summary.txt"; then
            echo 'editor_ime_input_source_restore=superseded'
            return
        fi
        "$fixture_root/restore-input-source" "$fixture_root/input-source.json"
    }
    trap restore_input_source EXIT HUP INT TERM
fi
echo "editor_ime_fixture=$fixture_root"

set -- "$app_path"
if [ "$wrapped" = 1 ]; then
    bundle=$(dirname "$(dirname "$(dirname "$app_path")")")
    test -d "$bundle/Contents/MacOS"
    set -- /usr/bin/open -n -W --stdout "$fixture_root/app.stdout.txt" --stderr "$fixture_root/app.stderr.txt" "$bundle"
fi

# Keep failures as artifacts, including isolated home/backup state, for inspection.
env CFFIXED_USER_HOME="$fixture_root/home" \
    XDG_CONFIG_HOME="$fixture_root/home/.config" XDG_CACHE_HOME="$fixture_root/cache" \
    XDG_STATE_HOME="$fixture_root/state" MARU_CONFIG="$fixture_root/home/.config/maru/config" \
    MARU_EDITOR_BACKUP_ROOT="$fixture_root/editor-backups" MARU_NO_WORKSPACE_RESTORE=1 \
    MARU_SESSION_HOST_ROOT="$fixture_root/session-host" \
    MARU_FT_WINDOW_SIZE="${MARU_FT_WINDOW_SIZE:-$fixture_window_size}" MARU_MACOS_APP_SMOKE_MS="$smoke_ms" MARU_EDITOR_IME_SMOKE=1 MARU_IME_DEBUG=1 \
    MARU_EDITOR_IME_SMOKE_LIVE="$live" MARU_EDITOR_IME_WRAPPED_CANDIDATE="$wrapped" \
    MARU_EDITOR_IME_LATE_FOCUS="$late_focus" \
    MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT="$fixture_root" \
    MARU_NATIVE_EDITOR="$fixture_root/document.txt" \
    MARU_EDITOR_IME_SMOKE_OUT="$fixture_root/summary.txt" \
    "$@" > "$fixture_root/app.stdout.txt" 2> "$fixture_root/app.stderr.txt"

test -f "$fixture_root/summary.txt"
cat "$fixture_root/summary.txt"
rg -q '^failure_count=0$' "$fixture_root/summary.txt"
cmp "$fixture_root/document.txt" "$fixture_root/expected.txt"

if [ "$wrapped" = 1 ]; then
    xcrun swift tools/verify-ime-candidate-captures.swift "$fixture_root/editor-wrapped-candidates.json"
fi
