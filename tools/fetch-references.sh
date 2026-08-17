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

# IETF 인터넷 초안은 **리비전이 붙은 URL 로만** 받을 수 있다(`-04.txt`). 리비전을 박아 두면
# 초안이 올라갈 때마다 이 스크립트가 조용히 404 를 내므로, datatracker 에서 현재 리비전을 먼저 묻는다.
dl_draft() {
  name="$1"
  out="$2"
  rev="$(curl -fsSL --max-time 60 "https://datatracker.ietf.org/doc/$name/doc.json" 2>/dev/null |
    sed -n 's/.*"rev"[ ]*:[ ]*"\([0-9]*\)".*/\1/p' | head -1)"
  if [ -z "$rev" ]; then
    echo "FAIL $out (리비전을 못 물었다 — https://datatracker.ietf.org/doc/$name/ 에서 직접 받는다)" >&2
    return 0
  fi
  dl "https://www.ietf.org/archive/id/$name-$rev.txt" "$out"
}

echo "공개 터미널 명세를 references/specs/ 로 받는다..."
dl "https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf" "ECMA-48_5th_edition_june_1991.pdf"
dl "https://invisible-island.net/xterm/ctlseqs/ctlseqs.txt" "xterm-ctlseqs.txt"
dl "https://vt100.net/emu/dec_ansi_parser" "vt100net-dec-ansi-parser.html"
dl "https://www.vt100.net/docs/vt100-ug/contents.html" "vt100-user-guide-contents.html"

# SSH(docs/ssh-client.md 가 이 문서들에서 유도된다). **문서가 로컬 경로를 걸어 두고 스크립트가
# 안 받으면 그 인용은 확인할 수 없는 인용이 된다** — 실제로 chacha20 초안이 그랬고, 그래서
# K_1/K_2 명명을 두고 잘못된 지적이 나왔다(구형 OpenSSH PROTOCOL 은 이름이 반대다).
echo "SSH 명세를 받는다..."
dl "https://www.rfc-editor.org/rfc/rfc4251.txt" "rfc4251-ssh.txt"
dl "https://www.rfc-editor.org/rfc/rfc4252.txt" "rfc4252-ssh.txt"
dl "https://www.rfc-editor.org/rfc/rfc4253.txt" "rfc4253-ssh.txt"
dl "https://www.rfc-editor.org/rfc/rfc4254.txt" "rfc4254-ssh.txt"
dl "https://www.rfc-editor.org/rfc/rfc8731.txt" "rfc8731-curve25519-kex.txt"
dl "https://www.rfc-editor.org/rfc/rfc5656.txt" "rfc5656-ecc.txt"
dl "https://www.rfc-editor.org/rfc/rfc7748.txt" "rfc7748-curves.txt"
dl "https://www.rfc-editor.org/rfc/rfc8709.txt" "rfc8709-ed25519-ssh.txt"
dl "https://www.rfc-editor.org/rfc/rfc8032.txt" "rfc8032-eddsa.txt"
dl_draft "draft-ietf-sshm-chacha20-poly1305" "draft-sshm-chacha20-poly1305.txt"
dl_draft "draft-ietf-sshm-strict-kex" "draft-strict-kex.txt"
dl "https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL" "openssh-protocol.txt"
dl "https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL.key" "openssh-protocol-key.txt"

echo
echo "선택: 동작 비교 오라클 구현(베끼는 대상 아님)"
echo "  Ghostty (libghostty-vt): git clone --depth 1 https://github.com/ghostty-org/ghostty.git references/ghostty"
echo "  libvterm (system):       brew install libvterm   # 또는 배포판 패키지"
echo
echo "선택: 기능 동작 레퍼런스(터미널 코어 밖 — 코드 미복사, docs/references.md)"
echo "  agent-browser (WebDriver/CDP 백엔드 참고): git clone --depth 1 https://github.com/vercel-labs/agent-browser references/agent-browser"
echo
echo "완료. references/ 는 gitignore된다. 자세한 내용은 docs/references.md."
