#!/bin/sh
set -eu

export MARU_WEB_PANEL=1
export MARU_TEST_BROWSER_CAP=1
export MARU_MACOS_APP_SMOKE_MS=90000

test_root=$(mktemp -d "/tmp/maru-browser-bounded-smoke.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
export HOME="$test_root"
export CFFIXED_USER_HOME="$test_root"
export MARU_SESSION_HOST_ROOT="$test_root/session-host-root"
mkdir -p "$MARU_SESSION_HOST_ROOT"

rm -f zig-out/maru-macos-app/app.summary.txt
./zig-out/bin/maru-macos-app >/tmp/maru-browser-bounded-smoke.log

summary=zig-out/maru-macos-app/app.summary.txt
for field in \
    browser_ctl_bounded_structured \
    browser_ctl_bounded_await_args \
    browser_ctl_bounded_strict_csp \
    browser_ctl_bounded_navigation \
    browser_ctl_bounded_tamper \
    browser_ctl_bounded_byte_boundary \
    browser_ctl_bounded_too_large \
    browser_ctl_bounded_execution_error \
    browser_ctl_bounded_serialization_error \
    browser_ctl_bounded_depth \
    browser_ctl_bounded_stream \
    browser_ctl_console_capture \
    browser_ctl_console_clear
do
    grep -qx "$field=true" "$summary" || {
        echo "bounded browser smoke failed: $field" >&2
        exit 1
    }
done

# W3a(D6): browser 탭 저장소 — macOS 14+ 는 격리된 영속 저장소이고 디렉터리는 0700·백업 제외, 11~13 은 비영속이 계약.
grep -qx "browser_data_store_isolated=true" "$summary" || { echo "bounded browser smoke failed: browser_data_store_isolated" >&2; exit 1; }
os_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$os_major" -ge 14 ]; then
    for field in browser_data_store_persistent browser_data_store_backup_excluded; do
        grep -qx "$field=true" "$summary" || {
            echo "bounded browser smoke failed: $field ($(grep "^$field=" "$summary"))" >&2
            exit 1
        }
    done
else
    grep -qx "browser_data_store_persistent=false" "$summary" || { echo "bounded browser smoke failed: persistent store on macOS <14" >&2; exit 1; }
fi

pump_actions=$(sed -n 's/^browser_result_pump_actions=//p' "$summary")
pump_p95=$(sed -n 's/^browser_result_pump_p95_ms=//p' "$summary")
pump_max=$(sed -n 's/^browser_result_pump_max_ms=//p' "$summary")
[ "${pump_actions:-0}" -gt 0 ] || { echo "bounded browser smoke failed: no pump actions" >&2; exit 1; }
awk -v p95="$pump_p95" -v max="$pump_max" 'BEGIN { exit !(p95 <= 0.5 && max <= 1.0) }' || {
    echo "bounded browser smoke failed: pump p95=${pump_p95}ms max=${pump_max}ms" >&2
    exit 1
}
