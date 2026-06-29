#!/usr/bin/env sh
# references/ (gitignored)를 채운다: Maru clean-room 구현의 ground truth인 공개 명세와,
# 동작 비교용 오라클(선택)이다. 명세는 VT 코어 구현의 1차 출처이고, reference 터미널은
# 베끼는 대상이 아니라 동작 비교 오라클일 뿐이다(docs/references.md, docs/project-rules.md).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
specs="$root/references/specs"
mkdir -p "$specs"

dl() {
  url="$1"
  out="$2"
  if curl -fsSL --max-time 120 "$url" -o "$specs/$out"; then
    echo "ok   $out"
  else
    echo "FAIL $out ($url)" >&2
  fi
}

echo "공개 터미널 명세를 references/specs/ 로 받는다..."
dl "https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf" "ECMA-48_5th_edition_june_1991.pdf"
dl "https://invisible-island.net/xterm/ctlseqs/ctlseqs.txt" "xterm-ctlseqs.txt"
dl "https://vt100.net/emu/dec_ansi_parser" "vt100net-dec-ansi-parser.html"
dl "https://www.vt100.net/docs/vt100-ug/contents.html" "vt100-user-guide-contents.html"

echo
echo "선택: 동작 비교 오라클 구현(베끼는 대상 아님)"
echo "  Ghostty (libghostty-vt): git clone --depth 1 https://github.com/ghostty-org/ghostty.git references/ghostty"
echo "  libvterm (system):       brew install libvterm   # 또는 배포판 패키지"
echo
echo "선택: 기능 동작 레퍼런스(터미널 코어 밖 — 코드 미복사, docs/references.md)"
echo "  agent-browser (WebDriver/CDP 백엔드 참고): git clone --depth 1 https://github.com/vercel-labs/agent-browser references/agent-browser"
echo
echo "완료. references/ 는 gitignore된다. 자세한 내용은 docs/references.md."
