#!/bin/sh
# 원격 SCM 화면을 **제품 Metal 경로**로 찍는다.
#
# ## 왜 필요한가
#
# 원격 히스토리(RS7)는 실물 sshd·control socket·원격 저장소가 **동시에** 있어야 화면이 선다. 그래서
# 그 축의 PR 들이 [PR 체크리스트](../../docs/pr-checklist.md)가 요구하는 PNG 캡처 없이 올라갔고,
# 「목록이 실제로 뜨는가」는 손 테스트로 남았다. 설비는 이미 있었는데(아래) 잇는 스크립트만 없었다.
#
# ## 무엇을 재사용하나
#
# sshd·키·원격 저장소는 `ssh_harness.sh` 가 전부 갖고 있다 — 두 벌로 만들지 않는다. 이 스크립트는
# 그 하니스에 **앱을 띄우는 내부 스크립트**를 넘긴다(하니스의 계약이 `<실행 파일> [인자…]` 다).
#
# ## 사용법
#
#   sh tools/remote-scm/capture.sh <출력.png> [내부 스크립트에 넘길 env 이름=값 …]
#
# 예) 히스토리 탭 + 맨 위 커밋을 펼친 화면:
#   zig build macos-app-bundle
#   sh tools/remote-scm/capture.sh /tmp/rs7.png MARU_FORCE_SCM_COMMIT_EXPAND=0
#
# macOS 전용이다(제품 Metal 경로를 띄운다).
set -eu

if [ "$#" -lt 1 ]; then
	echo "usage: $0 <out.png> [KEY=VALUE …]" >&2
	exit 2
fi
case "$(uname -s)" in
Darwin) ;;
*) echo "remote-scm capture: macOS 전용이다(제품 Metal 경로)" >&2; exit 1 ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
exec sh "$ROOT/tools/remote-scm/ssh_harness.sh" "$ROOT/tools/remote-scm/capture_inner.sh" "$@"
