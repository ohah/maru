#!/bin/sh
# `capture.sh` 가 `ssh_harness.sh` 를 통해 부른다 — 하니스가 세운 sshd·control socket·원격 저장소를
# env(`MARU_REMOTE_SCM_{DEST,CTL,REPO}`)로 물려받는다.
set -eu

OUT=$1
shift
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
APP=$ROOT/zig-out/Maru.app/Contents/MacOS/maru-macos-app
[ -x "$APP" ] || { echo "capture: 앱 번들이 없다 — 먼저 'zig build macos-app-bundle'" >&2; exit 1; }
: "${MARU_REMOTE_SCM_DEST:?하니스를 거치지 않았다}"
: "${MARU_REMOTE_SCM_CTL:?}"
: "${MARU_REMOTE_SCM_REPO:?}"

# **격리 HOME 을 짧게 잡는다.** 앱이 control socket 경로를 `<HOME>/.cache/maru/ctl-<…>` 로 만드는데,
# 그 경로가 `sun_path`(104)를 넘으면 소켓을 조용히 못 연다. 그리고 사용자의 진짜 `~/.cache/maru` 에
# 링크를 남기면, 나중에 같은 목적지로 진짜 `maru ssh` 를 할 때 **죽은 소켓을 재사용**하게 된다.
CAP_HOME=/tmp/maru-cap.$$
rm -rf "$CAP_HOME"
mkdir -p "$CAP_HOME/.cache/maru" "$CAP_HOME/.config/maru"
trap 'rm -rf "$CAP_HOME"' EXIT INT TERM

CTL_WANT=$(zig run "$ROOT/tools/remote-scm/ctl_path.zig" -- "$CAP_HOME" "$MARU_REMOTE_SCM_DEST" 2>&1 | tail -1)
case "$CTL_WANT" in
"$CAP_HOME"/*) ;;
*) echo "capture: control socket 경로 계산이 실패했다: $CTL_WANT" >&2; exit 1 ;;
esac

# **하니스의 소켓을 그 자리로 잇는다.** 복사할 수 없는 물건이라 심볼릭 링크다 — `connect(2)` 는 링크를
# 따라가고, `sun_path` 한도는 **건네는 경로**에 걸리므로 양쪽 다 짧으면 된다.
ln -s "$MARU_REMOTE_SCM_CTL" "$CTL_WANT"

# **저장소를 결정론으로 다시 세운다.** 골든으로 굳히려면 화면의 글자가 실행마다 같아야 하는데,
# 커밋 SHA 와 상대시각이 그렇지 않다. 셋을 고정한다:
#
#  1. **신원과 시각을 박는다** → 같은 트리 + 같은 저자/시각 = **같은 SHA**. 하니스가 만든 `seed` 커밋은
#     시각이 안 박혀 있으므로 그 이력을 쓰지 않고 **처음부터 다시 만든다**(저장소는 이 캡처의 것이다).
#  2. **시각을 미래로 둔다.** 히스토리 탭의 상대시각은 `방금`/`N분 전`…인데, 과거로 박으면 실행 날짜가
#     지날수록 글자가 자란다. 제품은 **미래 시각을 `방금`으로 접으므로**(시계가 어긋난 커밋 규율)
#     미래로 박으면 언제 찍어도 `방금`이다.
#  3. **기본 브랜치를 박는다**(`-b main`) — `init.defaultBranch` 는 기계마다 다르다.
GIT=/usr/bin/git
FIXED_DATE="2099-01-01T00:00:00+00:00"
rm -rf "$MARU_REMOTE_SCM_REPO"
mkdir -p "$MARU_REMOTE_SCM_REPO"
"$GIT" -C "$MARU_REMOTE_SCM_REPO" init -q -b main .
n=1
while [ "$n" -le 4 ]; do
	echo "line $n" > "$MARU_REMOTE_SCM_REPO/capture$n.txt"
	"$GIT" -C "$MARU_REMOTE_SCM_REPO" add -A
	GIT_AUTHOR_NAME="Maru Capture" GIT_AUTHOR_EMAIL=capture@maru.test \
		GIT_COMMITTER_NAME="Maru Capture" GIT_COMMITTER_EMAIL=capture@maru.test \
		GIT_AUTHOR_DATE="$FIXED_DATE" GIT_COMMITTER_DATE="$FIXED_DATE" \
		"$GIT" -C "$MARU_REMOTE_SCM_REPO" -c commit.gpgsign=false commit -q -m "원격 커밋 $n — 저쪽 기계에서 읽은 것"
	n=$((n + 1))
done

# 앱이 쓰는 PPM 을 PNG 로 바꾸기 전 임시 자리. `MARU_SCREENSHOT` 은 확장자와 무관하게 P6 를 쓴다.
SHOT=$CAP_HOME/shot.ppm

# **원격 pane 을 강제한다.** 진짜 `maru ssh` 를 태우면 셸 타이밍에 매달리는데, 이 캡처가 보려는 것은
# 「원격일 때 도크가 무엇을 그리나」이지 진입 경로가 아니다. 강제는 OSC 통지를 다시 보내는 것이라
# 그 아래(저장소 판정·원격 읽기·렌더)는 전부 제품 경로다.
#
# 호출자가 준 `KEY=VALUE` 를 뒤에 둬서 **덮어쓸 수 있게** 한다(탭·펼침·지연 등).
env -u CLAUDE_CODE_CHILD_SESSION \
	HOME="$CAP_HOME" CFFIXED_USER_HOME="$CAP_HOME" \
	MARU_FORCE_REMOTE_SCM="$MARU_REMOTE_SCM_DEST" \
	MARU_FORCE_REMOTE_SCM_CWD="$MARU_REMOTE_SCM_REPO" \
	MARU_FORCE_SCM=1 \
	MARU_FORCE_SCM_TAB=history \
	MARU_SCREENSHOT="$SHOT" \
	MARU_SCREENSHOT_DELAY_MS=7000 \
	"$@" \
	"$APP" >"$CAP_HOME/app.log" 2>&1 || {
	echo "capture: 앱이 실패했다" >&2
	tail -20 "$CAP_HOME/app.log" >&2
	exit 1
}
[ -s "$SHOT" ] || { echo "capture: 스크린샷이 안 나왔다" >&2; tail -20 "$CAP_HOME/app.log" >&2; exit 1; }

# **PPM 도 남긴다.** 골든 게이트는 PPM 을 읽는다(`tests/support/ppm.zig` 가 P6 만 안다) — 사람은
# PNG 를 보고 기계는 PPM 을 본다.
OUT_PPM=${OUT%.png}.ppm
cp "$SHOT" "$OUT_PPM"
python3 "$ROOT/tools/remote-scm/ppm_to_png.py" "$SHOT" "$OUT"
echo "capture: $OUT (+ $OUT_PPM)"
