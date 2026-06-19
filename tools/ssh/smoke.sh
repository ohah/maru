#!/bin/sh
# `maru ssh` 원격 terminfo 전파의 opt-in 통합 smoke. `ssh localhost`를 원격으로 써서 전파 파이프라인
# (maru → /bin/sh -c → infocmp → ssh → 원격 tic/infocmp)이 끝까지 에러 없이 돌고, 원격이 결국
# `xterm-maru`를 동기화 출력(Sync) 캡과 함께 해석하는지 확인한다.
#
# 기본 `mise run check`에 넣지 않는다 — sshd(Remote Login)와 localhost 키 인증이 필요해 환경 의존적
# 이다(없으면 graceful SKIP). 그래서 정책 문서가 요구하는 "opt-in SSH smoke"다(terminal-compatibility-
# policy.md 선행조건 ②, terminal-strategy.md §13).
#
# 한계(정직하게): localhost는 로컬과 같은 홈(`~/.terminfo`)을 공유한다. 그래서 원격 스크립트의
# "이미 설치됐으면 skip"(infocmp && exit 0)이 곧장 참이 돼, 이 smoke는 원격 `tic` 컴파일 자체보다는
# **연결·파이프·exec 글루의 end-to-end 실행**을 검증한다. `tic` 컴파일 적합성은 `mise run terminfo-check`
# 가 별도로(실제 tic round-trip) 본다. 진짜 빈 원격에 대한 설치 검증은 container/VM smoke의 후속 몫이다.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MARU="$ROOT/zig-out/bin/maru"

# 1) sshd/키 인증이 없으면 건너뛴다(실패가 아니다).
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true >/dev/null 2>&1; then
	echo "[ssh-smoke] SKIP: ssh localhost(키 인증)가 안 됨 — Remote Login 켜짐 + ~/.ssh 키가 필요하다."
	exit 0
fi

# 2) maru 바이너리.
[ -x "$MARU" ] || { echo "[ssh-smoke] FAIL: $MARU 없음 — 'mise run build' 먼저." >&2; exit 1; }

# 3) 전파 소스가 로컬에 있어야 한다(maru ssh는 로컬 infocmp -x xterm-maru를 파이프한다).
sh "$ROOT/tools/terminfo/install.sh" >/dev/null

# 4) 전파만 실행(세션 exec 없음) — 끝까지 에러 없이 돌아야 한다.
"$MARU" ssh --terminfo-only localhost || { echo "[ssh-smoke] FAIL: maru ssh --terminfo-only 실패" >&2; exit 1; }

# 5) 원격(localhost)이 xterm-maru를 Sync 캡과 함께 해석하는가.
if ssh -o BatchMode=yes localhost 'infocmp -x xterm-maru 2>/dev/null | grep -q "Sync="'; then
	echo "[ssh-smoke] OK: 전파 파이프라인 실행 + 원격이 xterm-maru(Sync) 해석"
else
	echo "[ssh-smoke] FAIL: 원격이 xterm-maru/Sync를 해석하지 못함" >&2
	exit 1
fi
