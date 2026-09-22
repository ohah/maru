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
# 밖에서 쓴 내용의 **사본**. 판정을 `$(cat …)` 비교로 하면 셸이 끝의 개행을 지워 「내용은 같고 개행만
# 다르게 덮어쓴 저장」이 통과한다 — `cmp` 로 바이트까지 본다.
reference="$root/expected.txt"
ready="$root/ready"
summary="$workspace/zig-out/maru-macos-app/app.summary.txt"

original='original-from-open
'
external='changed-by-another-process
'
# `restore-backup` 이 레코드에 심는 내용 — 디스크에도, 우리가 타이핑한 것에도 없는 글자여야
# 「레코드에서 왔다」가 증명된다.
restored='restored-from-backup
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

backups="$home/Library/Application Support/maru/editor-backups"

run_scenario() {
    scenario=$1
    rm -f "$ready"
    printf '%s' "$original" > "$document"
    # **백업 자리를 비우고 시작한다** — 앞 시나리오가 남긴 파일을 이 시나리오의 결과로 읽지 않는다
    # (같은 문서라 이름이 같다). ⚠️ `restore-backup` 은 예외다: 그 시나리오는 **심어 둔 레코드**로
    # 시작하고, 그 이름은 앞 시나리오(`quit-backup`)가 만든 것을 재사용한다(이름이 Wyhash 라 셸이
    # 계산할 수 없다 — 그 의존을 아래에서 명시로 확인한다).
    if [ "$scenario" != restore-backup ]; then
        rm -rf "$backups"
    fi
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

    if [ "$scenario" = restore-backup ]; then
        # **레코드를 미리 심는다** — 크래시 없이 「지난 세션이 남긴 것」을 만드는 유일한 길이다.
        # 포맷은 `session/editor/backup.zig` 가 소유한다: 헤더 줄 → `key=value` 한 줄 → 빈 줄 → 원문.
        # `disk-hash` 는 **빼고 쓴다** — 셸은 Wyhash 를 못 내고, 없으면 복원이 지금 디스크 지문을
        # 그대로 둔다(그 갈래는 헤드리스 `U4b-2` 가 잰다).
        # ⚠️ **이름은 앱이 계산한다**(Wyhash) — 셸이 맞출 수 없다. 그래서 `quit-backup` 이 **같은
        # 문서로 방금 만든** 레코드 파일의 이름을 그대로 재사용해 내용만 덮어쓴다.
        printf '%s' "$restored" > "$root/restored.txt"
        bytes=$(wc -c < "$root/restored.txt" | tr -d ' ')
        existing=$(ls "$backups" 2>/dev/null | head -1)
        if [ -z "$existing" ]; then
            echo "restore-backup needs the record name produced by quit-backup (run order matters)" >&2
            exit 1
        fi
        {
            printf 'maru.editor-backup.v1\n'
            printf 'doc kind=path bytes=%s path="%s"\n' "$bytes" "$document"
            printf '\n'
            printf '%s' "$restored"
        } > "$backups/$existing"
    fi
    if [ "$scenario" != clean-save ] && [ "$scenario" != quit-backup ] && [ "$scenario" != restore-backup ]; then
        # **드라이버가 부를 때까지 기다린다.** 편집기가 파일을 읽고 글자를 넣은 뒤에야 "밖에서
        # 바뀌었다"가 성립한다. 고정 sleep 은 기계에 따라 순서가 뒤집혀 무엇을 쟀는지 알 수 없다.
        waited=0
        while [ ! -f "$ready" ]; do
            # **앱이 먼저 죽었으면 기다릴 상대가 없다.** 이 검사가 없으면 무장 실패(시나리오 오타로
            # 드라이버가 안 붙는 것)와 크래시가 전부 20초를 태운 뒤 「밖에서 바꿔 달라고 안 했다」로
            # 보고돼, 요약이 들고 있는 진짜 이유를 가린다.
            if ! kill -0 "$app_pid" 2>/dev/null; then
                wait "$app_pid" 2>/dev/null || true
                echo "editor save-conflict smoke app exited before asking for the external change" >&2
                grep -E '^editor_save_conflict_smoke_' "$summary" >&2 || true
                exit 1
            fi
            if [ "$waited" -ge 200 ]; then
                kill "$app_pid" 2>/dev/null || true
                wait "$app_pid" 2>/dev/null || true
                echo "editor save-conflict smoke never asked for the external change" >&2
                grep -E '^editor_save_conflict_smoke_' "$summary" >&2 || true
                exit 1
            fi
            sleep 0.1
            waited=$((waited + 1))
        done
        # **다른 프로세스가 쓴다** — 앱이 쓰면 그것은 "밖에서"가 아니다.
        printf '%s' "$external" > "$document"
        printf '%s' "$external" > "$reference"
        # ⚠️ **「다시 읽기」가 몰래 쓰는 것은 내용으로 안 보인다** — 다시 읽은 직후의 버퍼는 디스크와
        # 같은 바이트라, 그것을 되쓰면 파일은 글자 하나 안 바뀐다. 그래서 **쓴 시각**을 본다(소수점
        # 포함 mtime). 이 줄이 없으면 「읽기가 아니라 읽고 되쓰기」인 구현이 게이트를 통과한다
        # (적대적 4회차에서 실제로 통과했다).
        mtime_before=$(stat -f %Fm "$document")
    fi

    wait "$app_pid"
    test -f "$summary"
    cp "$summary" "$root/$scenario.summary.txt"
    if [ "$scenario" = conflict-reload ] || [ "$scenario" = conflict-compare ]; then
        # **다시 읽기·비교는 읽기다** — 앱이 그 파일에 한 글자도 쓰지 않았어야 한다.
        if [ "$(stat -f %Fm "$document")" != "$mtime_before" ]; then
            echo "this choice wrote to the file (mtime moved): $scenario" >&2
            exit 1
        fi
    fi
}

run_scenario external-conflict
grep -Eq '^editor_save_conflict_smoke_scenario=external-conflict$' "$root/external-conflict.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/external-conflict.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/external-conflict.summary.txt"
# 앱의 판정과 **별개로** 파일을 직접 센다. 앱 안의 probe 가 거짓말을 해도 이 줄은 안 속는다.
cmp -s "$document" "$reference"

run_scenario clean-save
grep -Eq '^editor_save_conflict_smoke_scenario=clean-save$' "$root/clean-save.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/clean-save.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/clean-save.summary.txt"
# 대조군이 없으면 "무조건 거절"도 위 판정을 통과한다. 여기서는 **우리가 넣은 글자가 디스크에** 있어야 한다.
grep -q 'xyz' "$document"
grep -q 'original-from-open' "$document"

# C1a — 충돌 상자에서 **덮어쓰기**를 고르면 내 편집이 디스크에 있다.
run_scenario conflict-overwrite
grep -Eq '^editor_save_conflict_smoke_scenario=conflict-overwrite$' "$root/conflict-overwrite.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/conflict-overwrite.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/conflict-overwrite.summary.txt"
# 앱 밖에서 한 번 더: **우리 글자가 있고 밖에서 쓴 줄은 사라졌다**(그것이 덮어쓰기다).
grep -q 'xyz' "$document"
! grep -q 'changed-by-another-process' "$document"

# C1a — **다시 읽기**를 고르면 디스크는 그대로다(읽기는 쓰지 않는다).
run_scenario conflict-reload
grep -Eq '^editor_save_conflict_smoke_scenario=conflict-reload$' "$root/conflict-reload.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/conflict-reload.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/conflict-reload.summary.txt"
cmp -s "$document" "$reference"

# U4a — **저장하지 않고 종료**하면 미저장 내용이 백업에 남는다(§3.10).
#
# 이 시나리오의 값은 **누가 썼는가**에 있다: 드라이버가 타이핑 직후 종료를 요청하므로 debounce(2초)가
# 만기되지 않았고, 따라서 파일이 있다면 그것은 tick 이 아니라 **종료 경로의 flush** 다. 헤드리스
# 판정자는 그 함수를 직접 부르므로 이 배선은 앱 프로세스 안에서만 관측된다.
run_scenario quit-backup
grep -Eq '^editor_save_conflict_smoke_scenario=quit-backup$' "$root/quit-backup.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/quit-backup.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/quit-backup.summary.txt"
# ⑴ **저장은 한 번도 안 했다** — 원본 파일이 열었을 때 그대로다(백업은 저장이 아니다).
printf '%s' "$original" > "$reference"
cmp -s "$document" "$reference"
# ⑵ **백업이 정확히 하나 있다**(문서당 하나 — §3.10).
if [ "$(ls -1 "$backups" 2>/dev/null | wc -l | tr -d ' ')" != 1 ]; then
    echo "expected exactly one backup record in $backups" >&2
    ls -la "$backups" >&2 || true
    exit 1
fi
# ⑶ **그 안에 미저장 내용이 있다** — 본문은 escape 없이 그대로 실리므로 밖에서 셀 수 있다.
grep -q 'xyz' "$backups"/*.bak
grep -q 'original-from-open' "$backups"/*.bak
# ⑷ **소유자만 읽는다**(§3.10 — 소스가 평문으로 남는다).
if [ "$(stat -f %Lp "$backups"/*.bak)" != 600 ]; then
    echo "backup record is not owner-only: $(stat -f %Lp "$backups"/*.bak)" >&2
    exit 1
fi

# U4b — 지난 세션의 백업이 있는 문서는 **묻지 않고 dirty 로** 열린다(§3.10).
#
# `quit-backup` 바로 뒤에 둔다: 레코드 **이름**이 Wyhash 라 셸이 계산할 수 없어, 그 시나리오가 방금
# 만든 파일 이름에 내용을 덮어써서 심는다(그 의존은 위 `run_scenario` 가 명시로 확인한다).
run_scenario restore-backup
grep -Eq '^editor_save_conflict_smoke_scenario=restore-backup$' "$root/restore-backup.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/restore-backup.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/restore-backup.summary.txt"
# ⑴ **디스크는 그대로다** — 복원은 읽기다(파일을 덮지 않는다).
printf '%s' "$original" > "$reference"
cmp -s "$document" "$reference"
# ⑵ **버퍼에 레코드의 내용이 있었다** — 종료 flush 가 그 버퍼를 다시 썼으므로, 남은 레코드에 그 글자가
#    있다는 것이 곧 「앱이 레코드를 읽어 문서에 넣었다」는 증거다(드라이버는 dirty 만 볼 수 있다).
grep -q 'restored-from-backup' "$backups"/*.bak
! grep -q 'original-from-open' "$backups"/*.bak

# C1b — **비교**를 고르면 아무것도 버리지 않는다: 디스크가 그대로다(비교가 섰다는 것은 앱 안의
# probe 가 말한다 — 그 선택은 일부러 파일을 건드리지 않으므로 밖에서는 「그대로」만 보인다).
run_scenario conflict-compare
grep -Eq '^editor_save_conflict_smoke_scenario=conflict-compare$' "$root/conflict-compare.summary.txt"
grep -Eq '^editor_save_conflict_smoke_failure=$' "$root/conflict-compare.summary.txt"
grep -Eq '^editor_save_conflict_smoke_stage=done$' "$root/conflict-compare.summary.txt"
cmp -s "$document" "$reference"
