#!/bin/sh
# 컨트롤 플레인 1g(control-plane-security §8.4) 실측 — 서버가 붙은 프로세스의 출처(조상 사슬에서 자기 터미널의 foreground
# 그룹에 속한 첫 조상 → 그 세션 → pane)를 스스로 찾는지, 그 pane 으로만 browser grant 를 주는지 본다. 스모크 모드는 셸을 고정
# 시험 셸로 바꾸므로 **일반 모드**로 띄운다(셸 = 이 대본이 쓴 pane 대본). 확인 모달은 없다(사용자 결정 2026-11-16 「AI 가 모든 접근」 —
# 신원 판정을 지난 pane 은 전권을 묻지 않고 받는다). 두 모드를 본다: 세션 유지(기본 — pane 에 `MARU_PANE_ID` 가 없다)와 세션 유지 끔(in-process — 있다).
#
#   pane 셸에서 직접                      → 허용(그 pane 으로 전권 grant 를 넣고 실행)
#   pane 안 setsid 자식                   → 허용(Claude Code 의 Bash 도구 — 제어 터미널 없음, 조상 사슬로 pane 을 찾는다)
#   pane 안 새 process group 자식          → 허용(Codex — 터미널은 있지만 foreground 아님, foreground 인 부모로 찾는다)
#   셸이 쉬는 동안의 `&`                   → 허용(foreground 인 셸에서 나왔다)
#   다른 작업이 foreground 일 때의 `&`      → 거절(그 pane 의 foreground 작업에서 나오지 않았다 — grant 가 기억돼 있어도)
#   pane 밖에서 pane 번호를 댐             → 거절(1g 전에는 in-process pane 의 기억된 grant 를 모달 없이 탔다)
#
# 앱이 화면에 창을 띄운다. 끝나면 이 대본이 띄운 것(그 자손), 이 실행의 session host(와 그 셸), argv[0] 이 이 실행의 폴더 안인
# 프로세스만 끈다.
set -eu
# 시험 앱이 격리 HOME 밖에 쓰지 않게 — 이 변수들은 HOME 보다 먼저 읽힌다(에이전트 훅 설치 자리 `CLAUDE_CONFIG_DIR`·`CODEX_HOME`, 컨트롤
# 소켓·캐시 `XDG_CACHE_HOME`, 설정 `MARU_CONFIG`). 필요한 단계는 제 값을 따로 준다.
unset CLAUDE_CONFIG_DIR CODEX_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME MARU_CONFIG MARU_PANE_ID

app=${MARU_APP:-./zig-out/bin/maru-macos-app}
cli=${MARU_CLI:-$PWD/zig-out/bin/maru}
test -x "$app" || { echo "self-origin smoke: build the app first (zig build macos-app-build)" >&2; exit 2; }
test -x "$cli" || { echo "self-origin smoke: build the cli first (zig build)" >&2; exit 2; }

# 이 셸이 무엇이든 띄우기 전부터 있던 자식 — 부른 쪽이 `&` 로 띄운 작업(zsh 가 `-c` 의 마지막 명령을 exec 하면 그 작업이 이
# 대본의 자식이 된다 — 실측)은 이 실행의 것이 아니니 정리에서 뺀다.
inherited=" $(ps -ax -o pid=,ppid= | awk -v p=$$ '$2==p {printf "%s ", $1}')"
root=$(mktemp -d "/tmp/maru-self-origin.XXXXXX")
app_pid=""
server_pid=""
app_kids="" # run_mode 가 앱을 끄기 전에 모은 앱의 자손 — 그 사이에 신호가 와도 정리가 끈다
# 어떤 프로세스의 자손 pid 들(정리가 쓴다 — 이름으로 찾지 않는다; 같은 기계의 다른 실행·다른 maru 를 건드리지 않게).
descendants() { for k in $(ps -ax -o pid=,ppid= | awk -v p="$1" '$2==p {print $1}'); do echo "$k"; descendants "$k"; done; }
# 이 대본이 띄운 것과 그 자손(물려받은 자식과 그 아래는 뺀다).
own_descendants() { for k in $(ps -ax -o pid=,ppid= | awk -v p=$$ '$2==p {print $1}'); do case "$inherited" in *" $k "*) continue ;; esac; echo "$k"; descendants "$k"; done; }
# 이 실행의 session host(인자로 준 owner.lock 을 쥔 pid — 앱에서 떨어져 launchd 아래로 간다)와 그 자손(pane 셸).
# 인자가 없으면 아무것도 내지 않는다(`lsof -t` 는 이름 없이 부르면 기계의 모든 pid 를 낸다).
session_hosts() { [ $# -gt 0 ] || return 0; for h in $(lsof -t "$@" 2>/dev/null); do echo "$h"; descendants "$h"; done; }
# argv[0](`ps comm` — 마지막 열이어야 잘리지 않는다)이 $1 폴더 안 경로인 프로세스(launchd 아래로 넘어간 것도 — 이름이 아니라 위치).
# `/tmp` 는 `/private/tmp` 로도 뜬다. $2 가 있으면 argv[0] 이 그것으로 끝나는 것만.
procs_under() {
    [ -n "$1" ] || return 0
    ps -ax -o pid=,comm= | awk -v a="$1/" -v b="/private$1/" -v s="${2:-}" '{p = $1; sub(/^ *[0-9]+ /, "");
        if ((index($0, a) == 1 || index($0, b) == 1) && (s == "" || substr($0, length($0) - length(s) + 1) == s)) print p}'
}
cleanup() {
    trap '' INT HUP TERM # 정리 도중 또 온 시그널이 정리를 끊지 않게(EXIT trap 안의 exit 는 정리를 다시 돌리지 않는다)
    [ -n "${root:-}" ] || return 0
    kids="$(own_descendants) $(session_hosts "$root"/session-host-*/session-host/hosts/*/owner.lock)"
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    sleep 2
    kids="$kids $(own_descendants) $(session_hosts "$root"/session-host-*/session-host/hosts/*/owner.lock)"
    for k in $kids $app_kids; do kill -KILL "$k" 2>/dev/null || true; done
    for k in $(procs_under "$root"); do kill -KILL "$k" 2>/dev/null || true; done # 그 KILL 뒤에 남은 것을 본다
    rm -rf "$root" || true
    app_pid="" server_pid="" app_kids=""
}
# 시그널이면 곧 끝낸다(EXIT 가 한 번 정리한다) — trap 이 돌아온 뒤 지운 폴더로 단계를 이어 가지 않게.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
fail() { echo "self-origin smoke failed: $1" >&2; exit 1; }

port=$((21000 + $$ % 20000))
mkdir -p "$root/www"
printf '<!doctype html><title>self-origin</title>ok' > "$root/www/a.html"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$root/www" > "$root/http.log" 2>&1 &
server_pid=$!
url="http://127.0.0.1:$port/a.html"

# pane 셸 자리에 들어갈 대본 — 각 경우의 결과(출력과 종료 코드)를 파일에 남기고 pane 을 살려 둔다.
# pane 의 셸은 login(1)이 띄워 HOME 을 실제 사용자 홈으로 되돌린다 — 그대로 두면 CLI 가 이 기계에서 도는 **사용자의
# maru** 에 붙는다(실측). 그래서 대본이 시험 홈을 직접 세우고, 그 값이 없으면 아무것도 하지 않는다.
cat > "$root/pane.sh" <<PANE
#!/bin/sh
[ -n "\${MARU_SMOKE_HOME:-}" ] && [ -n "\${MARU_SMOKE_OUT:-}" ] || exec sleep 600
export HOME="\$MARU_SMOKE_HOME" XDG_CACHE_HOME="\$MARU_SMOKE_HOME/.cache"
out="\$MARU_SMOKE_OUT"
cli="$cli"
i=0
sid=
while [ -z "\$sid" ] && [ \$i -lt 40 ]; do
    sleep 0.5
    "\$cli" browser list > "\$out/list" 2>&1 || true
    sid=\$(awk '/^surface /{print \$2; exit}' "\$out/list")
    i=\$((i + 1))
done
echo "\$sid" > "\$out/web-id"
echo "\${MARU_PANE_ID:-}" > "\$out/pane-env"
"\$cli" browser navigate --surface "\$sid" "$url" > "\$out/fg" 2>&1; echo "rc=\$?" >> "\$out/fg"
python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' "\$cli" browser navigate --surface "\$sid" "$url" > "\$out/setsid" 2>&1; echo "rc=\$?" >> "\$out/setsid"
python3 -c 'import os, sys; os.setpgid(0, 0); os.execv(sys.argv[1], sys.argv[1:])' "\$cli" browser navigate --surface "\$sid" "$url" > "\$out/pgroup" 2>&1; echo "rc=\$?" >> "\$out/pgroup"
# 대화형 셸의 \`&\` 처럼 자기 process group 을 받게 job control 을 켠다(비대화형 sh 의 \`&\` 는 foreground 대본과 같은
# 그룹에 남아 foreground 로 보인다 — 실측).
set -m
# 셸이 쉬는 동안(wait — 셸이 foreground)의 \`&\`.
( "\$cli" browser navigate --surface "\$sid" "$url" > "\$out/bg-idle" 2>&1; echo "rc=\$?" >> "\$out/bg-idle" ) &
wait
# 다른 작업(sleep — 자기 group 으로 foreground)이 도는 동안의 \`&\`.
( sleep 1; "\$cli" browser navigate --surface "\$sid" "$url" > "\$out/bg" 2>&1; echo "rc=\$?" >> "\$out/bg" ) &
sleep 4
wait
set +m
touch "\$out/done"
exec sleep 600
PANE
chmod +x "$root/pane.sh"

run_mode() { # $1=이름 $2=session.keep-alive-after-quit
    mode=$1
    out="$root/out-$mode"
    mkdir -p "$out" "$root/home-$mode"
    printf 'ui.language = ko\nshell.command = %s\nshell.args =\nsession.keep-alive-after-quit = %s\n' "$root/pane.sh" "$2" > "$root/$mode.conf"
    # 앱의 control 디렉터리도 시험 홈으로(`XDG_CACHE_HOME` 이 먼저다 — 개발자 셸에 있으면 사용자의 control 디렉터리에 소켓을 연다).
    env HOME="$root/home-$mode" CFFIXED_USER_HOME="$root/home-$mode" XDG_CACHE_HOME="$root/home-$mode/.cache" MARU_SESSION_HOST_ROOT="$root/session-host-$mode" \
        MARU_CONFIG="$root/$mode.conf" MARU_WEB_PANEL=1 MARU_SMOKE_OUT="$out" MARU_SMOKE_HOME="$root/home-$mode" \
        "$app" > "$root/app-$mode.log" 2>&1 &
    app_pid=$!
    i=0
    while [ ! -f "$out/done" ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
    [ -f "$out/done" ] || { sed -n '1,40p' "$root/app-$mode.log" >&2; fail "$mode: the pane script did not finish"; }
    web_id=$(cat "$out/web-id")
    [ -n "$web_id" ] || fail "$mode: no web surface ($(cat "$out/list"))"
    # pane 밖(이 대본 — 다른 터미널)에서 그 pane 의 번호를 댄다. 번호는 pane 이 받은 env 또는 목록에서.
    pane_id=$(cat "$out/pane-env")
    if [ -z "$pane_id" ]; then
        HOME="$root/home-$mode" XDG_CACHE_HOME="$root/home-$mode/.cache" "$cli" sessions list > "$out/sessions" 2>&1 || true
        pane_id=$(sed -n 's/^.*\[\([0-9][0-9]*\)\].*terminal.*$/\1/p' "$out/sessions" | head -1)
    fi
    [ -n "$pane_id" ] || fail "$mode: could not find the terminal pane id ($(cat "$out/sessions" 2>/dev/null))"
    HOME="$root/home-$mode" XDG_CACHE_HOME="$root/home-$mode/.cache" MARU_PANE_ID="$pane_id" "$cli" browser navigate --surface "$web_id" "$url" > "$out/outside" 2>&1 \
        && echo "rc=0" >> "$out/outside" || echo "rc=$?" >> "$out/outside"
    # 앱의 자손(in-process 모드의 pane 셸 — login → sleep)은 앱을 끄기 전에 모은다 — 앱이 죽으면 launchd 아래로 넘어가 찾을 수 없다.
    app_kids=$(descendants "$app_pid")
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
    # 세션 유지 모드의 host 는 앱이 끝나도 pane 셸을 쥐고 남는다 — 그 host 와 셸을 끈다.
    for k in $app_kids $(session_hosts "$root/session-host-$mode"/session-host/hosts/*/owner.lock); do kill -KILL "$k" 2>/dev/null || true; done
    app_kids=""
    # 허용 = 종료 코드 0 이고 오류 응답이 없다(CLI 는 unauthorized 응답에도 0 으로 끝난다 — 출력으로 가른다).
    pass() { grep -q '^rc=0$' "$out/$1" && ! grep -q 'error:' "$out/$1"; }
    # 거절 = 서버의 unauthorized 응답(연결 실패·시간 초과 같은 다른 실패를 거절로 세지 않는다).
    refused() { grep -q 'Unauthorized' "$out/$1"; }
    pass fg || fail "$mode: the pane's own shell was refused ($(tr '\n' ' ' < "$out/fg"))"
    echo "PASS $mode: the pane's own shell got the grant and navigated"
    pass setsid || fail "$mode: a setsid child (agent tool shape) was refused ($(tr '\n' ' ' < "$out/setsid"))"
    echo "PASS $mode: a setsid child without a terminal was traced to its pane"
    pass pgroup || fail "$mode: a child in a new process group (Codex shape) was refused ($(tr '\n' ' ' < "$out/pgroup"))"
    echo "PASS $mode: a child in a new process group was traced to its foreground parent"
    pass bg-idle || fail "$mode: a background job while the shell was idle was refused ($(tr '\n' ' ' < "$out/bg-idle"))"
    echo "PASS $mode: a background job while the shell was idle was allowed"
    refused bg || fail "$mode: a background job while another job was in the foreground was not refused by the server ($(tr '\n' ' ' < "$out/bg"))"
    echo "PASS $mode: a background job while another job was in the foreground was refused"
    refused outside || fail "$mode: a process outside the pane that named pane $pane_id was not refused by the server ($(tr '\n' ' ' < "$out/outside"))"
    echo "PASS $mode: naming pane $pane_id from outside was refused"
}

run_mode persistent true
run_mode in-process false
echo "self-origin smoke passed"
