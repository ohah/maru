#!/bin/sh
set -eu

artifact_root="tests/artifacts/perf/session-host-cr6e-soak"
mkdir -p "$artifact_root"
find "$artifact_root" -maxdepth 1 -type f -delete

batch=0
while [ "$batch" -lt 20 ]; do
  zig build test-session-host-cr6e-baseline-macos
  cp tests/artifacts/perf/session-host-cr6e-baseline-macos.json "$artifact_root/transport-$batch.json"
  zig build macos-session-host-cr6e-recovery-baseline -Doptimize=ReleaseFast
  cp tests/artifacts/perf/session-host-cr6e-recovery-baseline-macos.json "$artifact_root/recovery-$batch.json"
  zig run tools/perf/session_host_cr6e_budget_validator.zig -- \
    "$artifact_root/transport-$batch.json" "$artifact_root/recovery-$batch.json"
  batch=$((batch + 1))
done

zig run tools/perf/session_host_cr6e_soak_validator.zig -- "$artifact_root"
