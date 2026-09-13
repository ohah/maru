#!/bin/sh
# Runs only the app executable borrowed from the mounted release DMG. SIGKILL is failure cleanup;
# a passing run must exit through AppKit's ordinary final-checkpoint Quit transaction.
set -eu
umask 077

app=$1
dmg=$2
test_uuid=$3
root=$4
output=$5
exe="$app/Contents/MacOS/maru-macos-app"
fixture=tests/fixtures/session-host/ended-runtime-workspace.v1
handle=1234567890abcdef1234567890abcdef:fedcba0987654321fedcba0987654321

case "$app:$dmg:$root:$output" in /*:/*:/*:/*) ;; *) exit 1 ;; esac
case "$test_uuid" in ????????-????-4???-[89ab]???-????????????) ;; *) exit 1 ;; esac
test ! -L "$app"
test ! -L "$dmg"
test -x "$exe"
test -f "$dmg"
test -f "$fixture"
test ! -e "$root"
test ! -e "$output"
/bin/mkdir -m 0700 "$root"
support="$root/Library/Application Support/maru"
/bin/mkdir -p "$support"
/bin/chmod 0700 "$root/Library" "$root/Library/Application Support" "$support"
/bin/cp "$fixture" "$support/workspace.v1"
/bin/chmod 0600 "$support/workspace.v1"
checkpoint="$support/workspace.v1"
dmg_sha_before=$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')
exe_sha_before=$(/usr/bin/shasum -a 256 "$exe" | /usr/bin/awk '{print $1}')

cleanup_pid=
cleanup() {
    if test -n "$cleanup_pid" && /bin/kill -0 "$cleanup_pid" 2>/dev/null; then
        /bin/kill -KILL "$cleanup_pid" 2>/dev/null || true
        wait "$cleanup_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

iteration=0
run_once() {
    iteration=$((iteration + 1))
    summary="$root/app-summary-$iteration.txt"
    before=$(/usr/bin/stat -f '%i' "$checkpoint")
    HOME="$root" CFFIXED_USER_HOME="$root" MARU_SESSION_HOST_ROOT="$root/session-host" \
      MARU_CONFIG="$root/.config/maru/config" \
      MARU_APP_SUMMARY_PATH="$summary" "$exe" &
    cleanup_pid=$!
    attempt=0
    while /bin/kill -0 "$cleanup_pid" 2>/dev/null; do
        attempt=$((attempt + 1))
        test "$attempt" -lt 150
        /bin/sleep 0.1
    done
    wait "$cleanup_pid"
    cleanup_pid=
    test "$before" != "$(/usr/bin/stat -f '%i' "$checkpoint")"
    /usr/bin/grep -Eq '^process_state=2$' "$summary"
    /usr/bin/grep -Eq '^final_frame_ended=true$' "$summary"
    /usr/bin/grep -Eq '^output_events=0$' "$summary"
    /usr/bin/grep -Eq '^terminal_input_events=0$' "$summary"
    /usr/bin/grep -Eq '^session_host_recovery_smoke_discovered_candidates=0$' "$summary"
    /usr/bin/grep -Eq '^session_host_recovery_smoke_ready_adapters=0$' "$summary"
    /usr/bin/grep -Eq '^session_host_recovery_smoke_inventory_runtimes=0$' "$summary"
    /usr/bin/grep -Eq '^session_host_recovery_smoke_target_activation_dispatched=false$' "$summary"
    /usr/bin/grep -Fq "runtime-handle=\"$handle\" runtime-state=\"ended\"" "$checkpoint"
    test ! -e "$checkpoint.bak"
    test ! -e "$support/.workspace.v1.tmp"
}

run_once
first_sha=$(/usr/bin/shasum -a 256 "$checkpoint" | /usr/bin/awk '{print $1}')
run_once
second_sha=$(/usr/bin/shasum -a 256 "$checkpoint" | /usr/bin/awk '{print $1}')
test "$first_sha" = "$second_sha"
dmg_sha=$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')
exe_sha=$(/usr/bin/shasum -a 256 "$exe" | /usr/bin/awk '{print $1}')
test "$dmg_sha" = "$dmg_sha_before"
test "$exe_sha" = "$exe_sha_before"
requirement=$(/usr/bin/codesign -d -r- "$app" 2>&1 | /usr/bin/sed -n 's/^designated => //p')
test -n "$requirement"
requirement_sha=$(printf '%s' "$requirement" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')

set -C
/usr/bin/jq -cn \
  --arg schema 'maru.session-host-signed-tombstone-relaunch.v1' \
  --arg test_uuid "$test_uuid" --arg result passed \
  --arg candidate_dmg_sha256 "$dmg_sha" --arg candidate_executable_sha256 "$exe_sha" \
  --arg designated_requirement_sha256 "$requirement_sha" --arg runtime_handle "$handle" \
  --arg runtime_state ended --arg checkpoint_first_sha256 "$first_sha" \
  --arg checkpoint_second_sha256 "$second_sha" \
  '{$schema,$test_uuid,$result,$candidate_dmg_sha256,$candidate_executable_sha256,$designated_requirement_sha256,$runtime_handle,$runtime_state,relaunch_count:2,normal_quit_count:2,final_checkpoint_count:2,$checkpoint_first_sha256,$checkpoint_second_sha256,probe_count:0,attach_count:0,spawn_count:0,output_event_count:0,terminal_input_event_count:0,cleanup_complete:true}' > "$output"
/bin/chmod 0600 "$output"
test "$(( $(/usr/bin/stat -f '%Lp' "$output") ))" -eq 600
trap - EXIT HUP INT TERM
