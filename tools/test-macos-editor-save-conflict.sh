#!/bin/sh
# C0 — 네이티브 편집기의 저장 충돌을 **실제 AppKit 프로세스**에서 확인한다
# (docs/native-editor-document-model.md §3.9d).
#
# 헤드리스 판정자는 `dispatchAppAction(.editor_save)`를 직접 불러 이유·문구까지 잰다. 이 게이트가
# 더하는 것은 그 앞뒤 두 조각이다: 진짜 `⌘S` 키가 `keyDown`의 chord 우회를 지나 그 디스패치에
# 닿는가, 그리고 **디스크가 안 덮이는가**. 뒤쪽은 앱 밖에서(여기서) 한 번 더 센다 — 앱이 스스로
# "안 덮었다"고 말하는 것과 파일이 실제로 그대로인 것은 다른 사실이다.
set -eu

app_path=${1:?Maru app executable path is required}
workspace=$(pwd -P)
root="$workspace/zig-out/maru-editor-save-conflict-smoke"
# 컨트롤 소켓의 sockaddr_un 은 104 바이트다. 격리 HOME 을 워크스페이스 아래 두면 조용히 안 뜬다.
session_root=$(mktemp -d "/tmp/maru-editor-save-conflict.XXXXXX")
trap 'rm -rf "$session_root"' EXIT HUP INT TERM
home="$root/home"
document="$root/doc.txt"
ready="$root/ready"
summary="$workspace/zig-out/maru-macos-app/app.summary.txt"

original='original-from-open
'
external='changed-by-another-process
'

case "$root" in
    "$workspace"/zig-out/maru-editor-save-conflict-smoke) ;;
    *)
        echo "refusing an unexpected editor save-conflict fixture root: $root" >&2
        exit 2
        ;;
esac

test -x "$app_path"
rm -rf "$root"
mkdir -p "$home"

run_scenario() {
    scenario=$1
    rm -f "$ready"
    printf '%s' "$original" > "$document"
    HOME="$home" \
    CFFIXED_USER_HOME="$home" \
    MARU_SESSION_HOST_ROOT="$session_root" \
    MARU_MACOS_APP_SMOKE_MS=20000 \
    MARU_EDITOR_SAVE_CONFLICT_SMOKE=1 \
    MARU_EDITOR_SAVE_CONFLICT_SMOKE_SCENARIO="$scenario" \
    MARU_EDITOR_SAVE_CONFLICT_SMOKE_READY="$ready" \
    MARU_NATIVE_EDITOR="$document" \
    "$app_path" &
    app_pid=$!

    if [ "$scenario" = external-conflict ]; then
        # **드라이버가 부를 때까지 기다린다.** 편집기가 파일을 읽고 글자를 넣은 뒤에야 "밖에서
        # 바뀌었다"가 성립한다. 고정 sleep 은 기계에 따라 순서가 뒤집혀 무엇을 쟀는지 알 수 없다.
        waited=0
        while [ ! -f "$ready" ]; do
            if [ "$waited" -ge 200 ]; then
                kill "$app_pid" 2>/dev/null || true
                wait "$app_pid" 2>/dev/null || true
                echo "editor save-conflict smoke never asked for the external change" >&2
                exit 1
            fi
            sleep 0.1
            waited=$((waited + 1))
        done
        # **다른 프로세스가 쓴다** — 앱이 쓰면 그것은 "밖에서"가 아니다.
        printf '%s' "$external" > "$document"
    fi

    wait "$app_pid"
    test -f "$summary"
    cp "$summary" "$root/$scenario.summary.txt"
}

run_scenario external-conflict
grep -Eq '^editor_save_conflict_smoke_scenario=external-conflict$' "$root/external-conflict.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/external-conflict.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/external-conflict.summary.txt"
# 앱의 판정과 **별개로** 파일을 직접 센다. 앱 안의 probe 가 거짓말을 해도 이 줄은 안 속는다.
test "$(cat "$document")" = "$(printf '%s' "$external")"

run_scenario clean-save
grep -Eq '^editor_save_conflict_smoke_scenario=clean-save$' "$root/clean-save.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/clean-save.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/clean-save.summary.txt"
# 대조군이 없으면 "무조건 거절"도 위 판정을 통과한다. 여기서는 **우리가 넣은 글자가 디스크에** 있어야 한다.
grep -q 'xyz' "$document"
grep -q 'original-from-open' "$document"
