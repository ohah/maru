#!/bin/bash
set -euo pipefail

[[ $# -eq 5 ]]
[[ $1 = commit ]]
[[ $4 = authored_attestation ]]
[[ $5 = succeeded || $5 = failed ]]
[[ $3 = "$MARU_TEST_CHECKPOINT_SENTINEL" ]]
printf '%s\n' "$*" >> "$MARU_TEST_CHECKPOINT_LOG"
[[ ${MARU_TEST_CHECKPOINT_FAIL:-0} = 0 ]]
