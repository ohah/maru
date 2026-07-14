#!/bin/sh
set -eu

export MARU_WEB_PANEL=1
export MARU_TEST_BROWSER_CAP=1
export MARU_MACOS_APP_SMOKE_MS=5000

rm -f zig-out/maru-macos-app/app.summary.txt
./zig-out/bin/maru-macos-app >/tmp/maru-browser-bounded-smoke.log

summary=zig-out/maru-macos-app/app.summary.txt
for field in \
    browser_ctl_bounded_structured \
    browser_ctl_bounded_tamper \
    browser_ctl_bounded_byte_boundary \
    browser_ctl_bounded_too_large \
    browser_ctl_bounded_execution_error \
    browser_ctl_bounded_serialization_error \
    browser_ctl_bounded_depth
do
    grep -qx "$field=true" "$summary" || {
        echo "bounded browser smoke failed: $field" >&2
        exit 1
    }
done
