#!/bin/sh
# Native stdio failures do not need a Metal device or screen-recording permission.
set -eu
root=$(mktemp -d /tmp/maru-ppm-diagnostics.XXXXXX)
trap 'rm -rf "$root"' EXIT
clang -Wall -Wextra -Werror -framework Foundation tests/macos_ppm_writer_smoke.m -o "$root/check"
"$root/check" "$root/control.ppm"
