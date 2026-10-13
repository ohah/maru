#!/bin/sh
# 사이드바 헤더·접힌 ◧·도크 토글 hover 판을 **실제 앱**으로 1x·2x 찍는다 — tests/golden/header_hover_visual.zig 가 비교한다.
#
# 왜 Chrome Lab 이 아닌가: Lab 은 app_session 을 import 하지 않아 장면의 quad 를 하니스가 직접 심는다. hover 판의 자리·
# 높이는 app_session(sidebar.zig `headerIconHoverPlateVertical`, file_panel.zig `filePanelDockControlRect`)이 정하므로
# Lab 장면은 그 계산을 타지 않는다. 2026-10-13 하루에 이 판들의 결함 넷(PR 셋 — #4408 펼친 판 세로 2px·접힌 판 0.5px ·
# #4410 도크 Retina 2px · #4421 pill 위 4px 잘림)이 숫자 판정자를 지나 캡처로만 보였다 — 그래서 제품 앱 캡처를 고정한다.
#
# 결정성: 앱마다 HOME·세션 host 루트를 따로 두고(사용자 세션·이전 실행과 섞이지 않게), UI 언어·셸·keep-alive 를
# 설정으로 박는다. 배율은 MARU_SCREENSHOT_RENDER_SCALE_MILLI 로 주입한다(1x 화면에서도 2x — #4412).
set -eu

app_path=${1:?Maru app executable path is required}
workspace=$(pwd -P)
root="$workspace/zig-out/header-hover-capture"
if [ ! -x "$app_path" ]; then
    echo "앱 실행 파일이 없다: $app_path — 먼저 zig build macos-app-bundle" >&2
    exit 2
fi
# 상위 환경의 MARU_* (창 크기·강제 상태·디버그 훅)가 흘러들면 장면이 바뀐다 — 아래에서 장마다 필요한 것만 다시 준다.
for var in $(env | sed -n 's/^\(MARU_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$var"
done
session_root=$(mktemp -d "/tmp/maru-header-hover.XXXXXX")
trap 'rm -rf "$session_root"' EXIT
trap 'rm -rf "$session_root"; exit 130' HUP INT TERM

rm -rf "$root"
mkdir -p "$root"
# 터미널 pane 은 판정 영역 밖이지만, 프롬프트·셸 rc 가 실행마다 화면을 흔들지 않게 아무것도 안 그리는 셸을 쓴다.
printf '#!/bin/sh\nexec sleep 60\n' > "$root/pane.sh"
chmod 755 "$root/pane.sh"
printf 'ui.language = ko\nshell.command = %s\nshell.args =\nsession.keep-alive-after-quit = false\n' "$root/pane.sh" > "$root/config"

# shot <이름> [VAR=값 ...] — 한 장을 찍는다. 앱은 첫 내용 frame 뒤 지연만큼 기다렸다 PPM 을 쓰고 끝난다.
shot() {
    name=$1
    shift
    home="$root/home-$name"
    mkdir -p "$home" "$session_root/$name"
    env HOME="$home" \
        CFFIXED_USER_HOME="$home" \
        MARU_SESSION_HOST_ROOT="$session_root/$name" \
        MARU_CONFIG="$root/config" \
        MARU_SCREENSHOT="$root/$name.ppm" \
        MARU_SCREENSHOT_DELAY_MS=1500 \
        "$@" \
        "$app_path" > "$root/$name.log" 2>&1
    test -s "$root/$name.ppm"
}

for scale in 1000 2000; do
    x=$((scale / 1000))x
    shot "header-none-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale
    shot "header-toggle-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_FORCE_HEADER_HOVER=toggle
    shot "header-view-options-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_FORCE_HEADER_HOVER=view_options
    shot "header-new-workspace-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_FORCE_HEADER_HOVER=new_workspace
    shot "header-bell-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_FORCE_HEADER_HOVER=notifications
    shot "collapsed-toggle-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_COLLAPSE_SIDEBAR=1 MARU_FORCE_HEADER_HOVER=collapsed
    shot "dock-toggle-$x" MARU_SCREENSHOT_RENDER_SCALE_MILLI=$scale MARU_FORCE_DOCK_TOGGLE_HOVER=1
done
echo "header hover captures written to $root"
