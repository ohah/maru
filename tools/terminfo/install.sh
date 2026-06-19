#!/bin/sh
# Maru 자체 terminfo를 로컬에 설치한다(opt-in). 기본 대상은 사용자 홈 `~/.terminfo`라 sudo가 필요 없다.
# 설치 후 config에서 `term = "xterm-maru"`로 켜면 로컬 프로그램이 maru 캡(Sync/Tc 등)을 인식한다.
#
# 원격(SSH)에는 이게 설치하지 않는다 — 원격 전파는 별도 증분(`maru ssh`)이다. 그 전까지 원격에서는
# 이 항목이 없으므로 `term`을 기본 `xterm-256color`로 두거나, 원격에 직접 설치해야 한다(아래 한 줄):
#   infocmp -x xterm-maru | ssh <host> 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'
#
# 대상 디렉터리는 $TERMINFO로 덮을 수 있다(예: 시스템 전역 설치 시).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC="$ROOT/terminfo/maru.terminfo"
DEST="${TERMINFO:-$HOME/.terminfo}"

[ -f "$SRC" ] || { echo "terminfo 소스가 없다: $SRC" >&2; exit 1; }
command -v tic >/dev/null 2>&1 || { echo "tic(ncurses)이 PATH에 없다" >&2; exit 1; }

mkdir -p "$DEST"
tic -x -o "$DEST" "$SRC"
echo "[install-terminfo] 설치 완료: $DEST (xterm-maru, alias maru)"
echo "[install-terminfo] config에 \`term = \"xterm-maru\"\`를 넣으면 켜진다."
