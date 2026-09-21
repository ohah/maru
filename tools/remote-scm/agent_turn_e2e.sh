#!/bin/sh
# 에이전트 턴 축 실기 e2e — 하네스(loopback sshd) 위에서 `agent_turn_e2e_inner.sh` 를 돌린다. 전제·결과는 그 파일 머리말.
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 <out.png>" >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
exec sh "$ROOT/tools/remote-scm/ssh_harness.sh" "$ROOT/tools/remote-scm/agent_turn_e2e_inner.sh" "$@"
