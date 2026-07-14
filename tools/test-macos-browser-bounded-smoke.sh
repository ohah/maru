#!/bin/sh
set -eu

export MARU_WEB_PANEL=1
export MARU_TEST_BROWSER_CAP=1
export MARU_MACOS_APP_SMOKE_MS=60000

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
    browser_ctl_bounded_stream
do
    grep -qx "$field=true" "$summary" || {
        echo "bounded browser smoke failed: $field" >&2
        exit 1
    }
done

pump_actions=$(sed -n 's/^browser_result_pump_actions=//p' "$summary")
pump_p95=$(sed -n 's/^browser_result_pump_p95_ms=//p' "$summary")
pump_max=$(sed -n 's/^browser_result_pump_max_ms=//p' "$summary")
[ "${pump_actions:-0}" -gt 0 ] || { echo "bounded browser smoke failed: no pump actions" >&2; exit 1; }
awk -v p95="$pump_p95" -v max="$pump_max" 'BEGIN { exit !(p95 <= 0.5 && max <= 1.0) }' || {
    echo "bounded browser smoke failed: pump p95=${pump_p95}ms max=${pump_max}ms" >&2
    exit 1
}
