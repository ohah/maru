#!/bin/sh
# `capture.sh` 가 `ssh_harness.sh` 를 통해 부른다 — 하니스가 세운 sshd·control socket·원격 저장소를
# env(`MARU_REMOTE_SCM_{DEST,CTL,REPO}`)로 물려받는다.
set -eu

OUT=$1
shift
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
APP=$ROOT/zig-out/Maru.app/Contents/MacOS/maru-macos-app
[ -x "$APP" ] || { echo "capture: 앱 번들이 없다 — 먼저 'zig build macos-app-bundle'" >&2; exit 1; }
# ⚠️ **소스보다 낡은 앱으로 찍지 않는다**(적대적 검증 2026-09-14). 이 스크립트는 빌드를 안 하므로,
# 코드를 고치고 곧바로 부르면 **옛 바이너리가 그린 그림**이 나온다 — 그리고 성공으로 끝난다. 실제로
# 그 그림을 보고 「고침이 제품에 안 보인다」로 한참 헤맸다. 골든 게이트가 같은 판정을 갖고 있지만
# 그것은 **비교할 때**의 이야기고, 사람이 캡처만 부르는 길에는 아무 말도 없었다.
if [ -n "$(find "$ROOT/src" "$ROOT/build.zig" -newer "$APP" -print -quit 2>/dev/null)" ]; then
	echo "capture: 앱이 소스보다 낡았다 — 먼저 'zig build macos-app-bundle'" >&2
	exit 1
fi
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

# ⚠️ **영속 세션 host 를 끈다.** 켜져 있으면 앱이 데몬에 붙는데, 그 데몬이 앱보다 낡았으면
# 「영속 세션 host 업데이트 결과: …」가 **모달 토스트로 도크를 덮는다**. 앱을 방금 빌드했을 때 정확히
# 그 상태가 되므로, 캡처 직전에 빌드하는 이 하니스에서는 **자주** 덮인다 — 골든이 그 자리에서 흔들렸다
# (적대적 검증 2026-09-14). 이 캡처가 보려는 것은 도크이고 원격 SCM 은 host 축과 무관하다.
{
	printf 'session.keep-alive-after-quit = false\n'
	# ⚠️ **조용한 셸을 박는다.** 원격 강제는 OSC 를 **셸에 타이핑해서** 보내는데, 사용자의 rc 가 말을 걸면
	# (oh-my-zsh 의 `Would you like to update? [Y/n]` 이 그랬다) 그 프롬프트가 **첫 글자를 먹는다** —
	# `printf` 가 `rintf` 가 되어 OSC 가 영영 안 가고, 캡처는 **로컬 화면**을 찍고도 성공으로 끝난다
	# (적대적 검증 2026-09-14 에서 실제로 그 그림이 나왔다). 격리 HOME 만으로는 안 막힌다.
	printf 'shell.command = /bin/sh\n'
} > "$CAP_HOME/.config/maru/config"

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
# **앱 로그를 남긴다.** 격리 HOME 은 지워지므로, 캡처가 이상할 때 뒤늦게 볼 것이 없어진다 —
# 「그림이 틀렸다」를 진단할 유일한 실마리다(적대적 검증에서 실제로 그 로그가 없어 헤맸다).
#
# ⚠️ **로그는 두 갈래다.** 여기 리다이렉트한 것은 stdout/stderr 이고 거기엔 종료 시 상태 덤프만 온다.
# `std.log` 는 앱이 자기 logFn 으로 `<HOME>/.cache/maru/app.log` 에 쓴다(`app_host_abi.zig`).
# 그 파일을 안 챙겨서 적대적 검증 8 회차에 「계측을 넣었는데 한 줄도 안 나온다」로 한참 헤맸다 —
# 실은 나오고 있었고 **지워지는 HOME 과 함께 사라지고 있었다.** 둘을 한 파일로 잇는다.
{
	cat "$CAP_HOME/app.log" 2>/dev/null || true
	echo "=== std.log (<HOME>/.cache/maru/app.log) ==="
	cat "$CAP_HOME/.cache/maru/app.log" 2>/dev/null || true
} > "${OUT%.png}.log" 2>/dev/null || true
[ -s "$SHOT" ] || { echo "capture: 스크린샷이 안 나왔다" >&2; tail -20 "$CAP_HOME/app.log" >&2; exit 1; }

# **PPM 도 남긴다.** 골든 게이트는 PPM 을 읽는다(`tests/support/ppm.zig` 가 P6 만 안다) — 사람은
# PNG 를 보고 기계는 PPM 을 본다.
OUT_PPM=${OUT%.png}.ppm
cp "$SHOT" "$OUT_PPM"
python3 "$ROOT/tools/remote-scm/ppm_to_png.py" "$SHOT" "$OUT"
echo "capture: $OUT (+ $OUT_PPM)"
