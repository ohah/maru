#!/bin/sh
# 컨트롤 플레인 1g(control-plane-security §8.4) 실측 — 서버가 붙은 프로세스의 출처(조상 사슬에서 제어 터미널을 가진 첫
# 프로세스 → 그 세션 → pane)를 스스로 찾는지, 그 pane 으로만 browser 확인 grant 를 묻는지 본다. 스모크 모드는 셸을 고정
# 시험 셸로 바꾸므로 **일반 모드**로 띄우고(셸 = 이 대본이 쓴 pane 대본), 확인 모달은 `MARU_TEST_GRANT_DECISION=approve`
# 로 자동 승인한다. 두 모드를 본다: 세션 유지(기본 — pane 에 `MARU_PANE_ID` 가 없다)와 세션 유지 끔(in-process — 있다).
#
#   pane 셸에서 직접          → 허용(확인 grant 를 그 pane 으로 묻고 실행)
#   pane 안 setsid 자식       → 허용(Claude Code 의 Bash 도구처럼 제어 터미널 없음 — 조상 사슬로 pane 을 찾는다)
#   pane 안 백그라운드 작업    → 거절(foreground 가 아니다 — 같은 pane 에 grant 가 기억돼 있어도)
#   pane 밖에서 pane 번호를 댐 → 거절(1g 전에는 in-process pane 의 기억된 grant 를 모달 없이 탔다)
#
# 앱이 화면에 창을 띄운다. 끝나면 이 대본이 띄운 앱·session host·셸만 끈다.
set -eu

app=${MARU_APP:-./zig-out/bin/maru-macos-app}
cli=${MARU_CLI:-$PWD/zig-out/bin/maru}
test -x "$app" || { echo "self-origin smoke: build the app first (zig build macos-app-build)" >&2; exit 2; }
test -x "$cli" || { echo "self-origin smoke: build the cli first (zig build)" >&2; exit 2; }

root=$(mktemp -d "/tmp/maru-self-origin.XXXXXX")
app_pid=""
server_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    pkill -KILL -f "$root" 2>/dev/null || true
    rm -rf "$root"
}
trap cleanup EXIT HUP INT TERM
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
# 대화형 셸의 \`&\` 처럼 자기 process group 을 받게 job control 을 켠다(비대화형 sh 의 \`&\` 는 foreground 대본과 같은
# 그룹에 남아 foreground 로 보인다 — 실측).
set -m
( "\$cli" browser navigate --surface "\$sid" "$url" > "\$out/bg" 2>&1; echo "rc=\$?" >> "\$out/bg" ) &
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
    env HOME="$root/home-$mode" CFFIXED_USER_HOME="$root/home-$mode" MARU_SESSION_HOST_ROOT="$root/session-host-$mode" \
        MARU_CONFIG="$root/$mode.conf" MARU_WEB_PANEL=1 MARU_TEST_GRANT_DECISION=approve MARU_SMOKE_OUT="$out" MARU_SMOKE_HOME="$root/home-$mode" \
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
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
    pkill -KILL -f "$root/session-host-$mode" 2>/dev/null || true
    # 허용 = 종료 코드 0 이고 오류 응답이 없다(CLI 는 unauthorized 응답에도 0 으로 끝난다 — 출력으로 가른다).
    pass() { grep -q '^rc=0$' "$out/$1" && ! grep -q 'error:' "$out/$1"; }
    pass fg || fail "$mode: the pane's own shell was refused ($(tr '\n' ' ' < "$out/fg"))"
    echo "PASS $mode: the pane's own shell got the grant and navigated"
    pass setsid || fail "$mode: a setsid child (agent tool shape) was refused ($(tr '\n' ' ' < "$out/setsid"))"
    echo "PASS $mode: a setsid child without a terminal was traced to its pane"
    pass bg && fail "$mode: a background job in the pane was allowed ($(tr '\n' ' ' < "$out/bg"))"
    echo "PASS $mode: a background job in the pane was refused"
    pass outside && fail "$mode: a process outside the pane that named pane $pane_id was allowed ($(tr '\n' ' ' < "$out/outside"))"
    echo "PASS $mode: naming pane $pane_id from outside was refused"
}

run_mode persistent true
run_mode in-process false
echo "self-origin smoke passed"
