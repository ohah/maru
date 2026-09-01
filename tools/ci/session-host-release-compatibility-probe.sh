#!/bin/sh
set -eu

product=$1
expected='{"mrsh_major":2,"screen_codec":2,"handoff_reader_min":1,"handoff_reader_max":1,"app_host_abi":180}'
actual=$(env -i "$product" __session-host --release-compatibility)
test "$actual" = "$expected"

stdout_file="/tmp/maru-compat-stdout.$$"
stderr_file="/tmp/maru-compat-stderr.$$"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT HUP INT TERM
if env -i "$product" __session-host --release-compatibility extra >"$stdout_file" 2>"$stderr_file"; then
  exit 1
fi
test ! -s "$stdout_file"
grep -q '^invalid maru session host invocation$' "$stderr_file"
