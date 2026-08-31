#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /absolute/path/to/maru-macos-app" >&2
    exit 64
fi

app_executable=$1
case "$app_executable" in
    /*) ;;
    *)
        echo "app executable must be an absolute path" >&2
        exit 64
        ;;
esac

test_root=$(mktemp -d "/tmp/maru-app-instance-lease.XXXXXX")
winner_pid=
cleanup() {
    if [ -n "$winner_pid" ] && kill -0 "$winner_pid" 2>/dev/null; then
        kill -KILL "$winner_pid" 2>/dev/null || true
        wait "$winner_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

test_home=$test_root/home
session_root=$test_root/session-host-root
run_dir=$test_root/run
workspace_dir="$test_home/Library/Application Support/maru"
mkdir -p "$workspace_dir" "$run_dir" "$test_root/config" "$test_root/cache" "$session_root"
lock_path="$test_home/Library/Application Support/maru/workspace.v1.lock"
printf 'maru.workspace.v1\nsentinel=true\n' >"$workspace_dir/workspace.v1"
printf '# sentinel-config\nsession.keep-alive-after-quit = false\n' >"$test_root/config/config.toml"
printf 'sentinel-cache\n' >"$test_root/cache/sentinel"

launch() {
    duration_ms=$1
    stdout_path=$2
    stderr_path=$3
    (
        cd "$run_dir"
        HOME="$test_home" \
        CFFIXED_USER_HOME="$test_home" \
        MARU_SESSION_HOST_ROOT="$session_root" \
        XDG_CONFIG_HOME="$test_root/config" \
        XDG_CACHE_HOME="$test_root/cache" \
        MARU_CONFIG="$test_root/config/config.toml" \
        MARU_SESSION_CONFIG_BOOTSTRAP_DUPLICATE_SMOKE=1 \
        MARU_APP_INSTANCE_LEASE_SMOKE_READY=1 \
        MARU_MACOS_APP_SMOKE_MS="$duration_ms" \
        "$app_executable"
    ) >"$stdout_path" 2>"$stderr_path"
}

(
    cd "$run_dir"
    # fresh lock creation must force 0600 even when the launching shell denies every
    # requested creation bit through umask.
    umask 0777
    exec env \
        HOME="$test_home" \
        CFFIXED_USER_HOME="$test_home" \
        MARU_SESSION_HOST_ROOT="$session_root" \
        XDG_CONFIG_HOME="$test_root/config" \
        XDG_CACHE_HOME="$test_root/cache" \
        MARU_CONFIG="$test_root/config/config.toml" \
        MARU_SESSION_CONFIG_BOOTSTRAP_DUPLICATE_SMOKE=1 \
        MARU_APP_INSTANCE_LEASE_SMOKE_READY=1 \
        MARU_APP_INSTANCE_LEASE_SMOKE_HOLD=1 \
        MARU_MACOS_APP_SMOKE_MS=60000 \
        "$app_executable"
) >"$test_root/winner.stdout" 2>"$test_root/winner.stderr" &
winner_pid=$!

attempt=0
while ! grep -Fq "maru: app instance writer lease acquired" "$test_root/winner.stderr"; do
    if ! kill -0 "$winner_pid" 2>/dev/null; then
        wait "$winner_pid" || true
        echo "winner exited before acquiring the app-instance lease" >&2
        sed -n '1,120p' "$test_root/winner.stderr" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
        echo "timed out waiting for the app-instance lease" >&2
        exit 1
    fi
    sleep 0.05
done
grep -Fq "maru: session config bootstrap ready" "$test_root/winner.stderr"
grep -Fq "maru: duplicate session config bootstrap rejected" "$test_root/winner.stderr"
test -f "$lock_path"
test "$(stat -f '%Lp' "$lock_path")" = "600"

snapshot_tree() {
    destination=$1
    (
        cd "$test_root"
        find home config cache \
            ! -path 'home/Library/Application Support/maru/workspace.v1.lock' \
            -print | LC_ALL=C sort
        find home config cache \
            ! -path 'home/Library/Application Support/maru/workspace.v1.lock' \
            -exec stat -f '%N %i %m %z %Lp' {} \; | LC_ALL=C sort
        find home config cache -type f \
            ! -path 'home/Library/Application Support/maru/workspace.v1.lock' \
            -exec shasum -a 256 {} \; | LC_ALL=C sort
    ) >"$destination"
}
snapshot_tree "$test_root/before-loser.snapshot"

set +e
launch 1000 "$test_root/loser.stdout" "$test_root/loser.stderr"
loser_status=$?
set -e
if [ "$loser_status" -ne 2 ]; then
    echo "second instance exited with $loser_status, expected 2" >&2
    sed -n '1,120p' "$test_root/loser.stderr" >&2
    exit 1
fi
grep -Fq "second instance unsupported: workspace writer lease held" "$test_root/loser.stderr"
if grep -Fq "session config bootstrap ready" "$test_root/loser.stderr"; then
    echo "second instance reached session config bootstrap" >&2
    exit 1
fi
if grep -Fq "duplicate session config bootstrap" "$test_root/loser.stderr"; then
    echo "second instance reached duplicate session config bootstrap probe" >&2
    exit 1
fi
kill -0 "$winner_pid"
snapshot_tree "$test_root/after-loser.snapshot"
cmp "$test_root/before-loser.snapshot" "$test_root/after-loser.snapshot"

kill -KILL "$winner_pid"
wait "$winner_pid" 2>/dev/null || true
winner_pid=

launch 500 "$test_root/successor.stdout" "$test_root/successor.stderr"
grep -Fq "maru: session config bootstrap ready" "$test_root/successor.stderr"
grep -Fq "maru: duplicate session config bootstrap rejected" "$test_root/successor.stderr"
summary="$run_dir/zig-out/maru-macos-app/app.summary.txt"
test -f "$summary"
grep -Eq '^app_instance_lease_status=0$' "$summary"
