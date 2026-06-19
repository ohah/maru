#!/bin/sh
# Maru 자체 terminfo(`terminfo/maru.terminfo`)의 적합성 검증 — opt-in `term = "xterm-maru"`의 토대다.
#
# 왜 이 검증이 중요한가: terminfo는 "프로그램이 읽는 머신에 있어야 하는 데이터 파일"이고, 캡 문자열을
# 한 글자라도 틀리면 tmux/nvim 등이 깨진 시퀀스를 내보내 화면이 망가진다("추측 말고 캡처"). 그래서
# 소스를 직접 `tic`로 컴파일해 (1) 깨끗이 컴파일되는지, (2) 핵심인 동기화 출력(Sync, DECSET 2026)이
# begin/end에서 정확히 `ESC [ ? 2026 h` / `ESC [ ? 2026 l` 바이트를 내는지, (3) primary/alias 이름이
# 모두 해석되는지, (4) truecolor(Tc)를 선언하는지를 실측한다. Sync는 tmux+SSH 플리커를 직접 고치는
# 캡이라 이 round-trip을 회귀로 박아둔다.
#
# 의존성: macOS/CI 표준 `tic`/`infocmp`/`tput`(ncurses). 기본 `mise run check`와 분리한 opt-in 검증이다.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC="$ROOT/terminfo/maru.terminfo"

fail() {
	echo "[terminfo-check] FAIL: $1" >&2
	exit 1
}

[ -f "$SRC" ] || fail "terminfo 소스가 없다: $SRC"
command -v tic >/dev/null 2>&1 || fail "tic(ncurses)이 PATH에 없다"

TIDIR=$(mktemp -d)
trap 'rm -rf "$TIDIR"' EXIT

# (1) 깨끗한 컴파일. -x로 확장 캡(Sync/Tc)을 포함한다.
tic -x -o "$TIDIR" "$SRC" 2>"$TIDIR/tic.err" || { cat "$TIDIR/tic.err" >&2; fail "tic 컴파일 실패"; }
[ -s "$TIDIR/tic.err" ] && { cat "$TIDIR/tic.err" >&2; fail "tic가 경고/에러를 냈다(클린 컴파일 아님)"; }

export TERMINFO="$TIDIR"

# (3) primary(xterm-maru) + alias(maru)가 모두 해석된다.
infocmp -x xterm-maru >/dev/null 2>&1 || fail "primary 이름 xterm-maru가 해석되지 않는다"
infocmp -x maru >/dev/null 2>&1 || fail "alias 이름 maru가 해석되지 않는다"

# (2) Sync round-trip: begin(p1=1)=ESC[?2026h, end(p1=0)=ESC[?2026l 정확히.
begin=$(tput -T xterm-maru Sync 1 | xxd -p)
end=$(tput -T xterm-maru Sync 0 | xxd -p)
[ "$begin" = "1b5b3f3230323668" ] || fail "Sync begin 바이트가 ESC[?2026h가 아니다: $begin"
[ "$end" = "1b5b3f323032366c" ] || fail "Sync end 바이트가 ESC[?2026l가 아니다: $end"

# (4) truecolor(Tc) 선언.
infocmp -x xterm-maru | grep -q 'Tc,' || fail "truecolor 캡 Tc가 선언되지 않았다"

echo "[terminfo-check] OK: xterm-maru/maru 컴파일 클린, Sync 2026 round-trip 정확, Tc 선언"
