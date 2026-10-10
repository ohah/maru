#!/bin/sh
# W9b① 실측 — pane 안의 에이전트(이 대본이 띄운 pane 셸)가 Chromium(OSR) 탭을 DevTools 로 움직이는가(docs/plans/web-osr-backend.md
# W9). 앱을 **일반 모드**로 띄운다(스모크 모드는 셸을 고정 시험 셸로 바꾼다). 확인 모달은 `MARU_TEST_GRANT_DECISION=approve` 로
# 자동 승인한다. 시험 페이지는 `MARU_WEB_OSR_TEST_URL`(시작 브라우저 탭 — `MARU_WEB_PANEL=1`).
#
#   click-trusted   `maru browser click --selector '#b'` → ok, 페이지는 사람 클릭(`isTrusted`)으로 받는다(페이지가 서버로 보내는 신호
#                   요청 `/hit?b-true` — Chromium 탭의 `browser list` 제목은 아직 페이지 제목이 아니다(W9a), 이동은 주소 칸으로 본다)
#   click-ref       같은 문서의 ref(`n<backendNodeId>` — DevTools 로 얻는다) 클릭도 된다
#   click-covered   다른 요소가 덮은 버튼은 누르지 않고 「covered」 오류 — 덮은 요소도 눌리지 않는다
#   click-missing   없는 요소는 not ok(WebKit 과 같다)
#   back·forward    링크로 다음 문서에 간 뒤 뒤로 → 첫 문서, 앞으로 → 다음 문서, 더 앞으로 → not ok
#   reload          새로고침 → ok, 문서가 다시 불린다(서버가 받은 요청 수)
#
# 앱이 화면에 창을 띄운다. 끝나면 이 대본이 띄운 앱·셸·서버만 끈다.
set -eu

app=${MARU_APP:-./zig-out/bin/maru-macos-app}
cli=${MARU_CLI:-$PWD/zig-out/bin/maru}
sidecar_dir=${MARU_WEB_OSR_DIR:-$PWD/zig-out/web-sidecar}
test -x "$app" || { echo "web cdp smoke: build the app first (zig build macos-app-build)" >&2; exit 2; }
test -x "$cli" || { echo "web cdp smoke: build the cli first (zig build)" >&2; exit 2; }
test -x "$sidecar_dir/maru-web-host" || { echo "web cdp smoke: build the sidecar first (mise run web-sidecar)" >&2; exit 2; }

root=$(mktemp -d "/tmp/maru-web-cdp.XXXXXX")
app_pid=""
server_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    pkill -KILL -f "$root" 2>/dev/null || true
    rm -rf "$root"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "web cdp smoke failed: $1" >&2; exit 1; }

port=$((22000 + $$ % 20000))
mkdir -p "$root/www"
cat > "$root/www/a.html" <<'HTML'
<!doctype html><title>cdp-ready</title><style>body{margin:0}#cover{position:absolute;left:300px;top:100px;width:100px;height:40px}#over{position:absolute;left:290px;top:90px;width:140px;height:70px;background:rgba(0,0,0,.2)}</style>
<script>function hit(w){new Image().src='/hit?'+w}</script>
<button id=b onclick="hit('b-'+event.isTrusted)">Save</button>
<a id=next href="b.html">next</a>
<button id=cover onclick="hit('cover')">Covered</button><div id=over onclick="hit('over')"></div>
HTML
printf '<!doctype html><title>page-b</title>b' > "$root/www/b.html"
# 받은 요청을 센다(새로고침이 문서를 다시 불렀는지).
cat > "$root/server.py" <<'PY'
import http.server, sys, functools
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("GET %s\n" % self.path); sys.stderr.flush()
    def end_headers(self):
        self.send_header("Cache-Control", "no-store"); super().end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()
PY
python3 "$root/server.py" "$port" "$root/www" 2> "$root/http.log" &
server_pid=$!
url="http://127.0.0.1:$port/a.html"

# pane 셸 자리에 들어갈 대본 — login(1)이 HOME 을 실제 홈으로 되돌리므로 시험 홈을 직접 세운다(없으면 아무것도 하지 않는다).
cat > "$root/pane.sh" <<PANE
#!/bin/sh
[ -n "\${MARU_SMOKE_HOME:-}" ] && [ -n "\${MARU_SMOKE_OUT:-}" ] || exec sleep 600
export HOME="\$MARU_SMOKE_HOME" XDG_CACHE_HOME="\$MARU_SMOKE_HOME/.cache"
out="\$MARU_SMOKE_OUT"
cli="$cli"
# 주소가 \$1 로 끝날 때까지(최대 10 초) — 목록 줄의 주소 칸으로 본다.
url_is() {
    n=0
    while [ \$n -lt 40 ]; do
        "\$cli" browser list > "\$out/list" 2>&1 || true
        grep -q "/\$1 " "\$out/list" && return 0
        sleep 0.25; n=\$((n + 1))
    done
    return 1
}
# 페이지가 신호 요청을 보낼 때까지(최대 5 초).
hit_seen() {
    n=0
    while [ \$n -lt 20 ]; do
        grep -q "GET /hit?\$1" "$root/http.log" && return 0
        sleep 0.25; n=\$((n + 1))
    done
    return 1
}
i=0
sid=
while [ -z "\$sid" ] && [ \$i -lt 60 ]; do
    sleep 0.5
    "\$cli" browser list > "\$out/list" 2>&1 || true
    sid=\$(awk '/^surface .*a\\.html.*engine=chromium/{print \$2; exit}' "\$out/list")
    i=\$((i + 1))
done
echo "\$sid" > "\$out/sid"
# run <결과 이름> <하위 명령> [인자…]
run() { name=\$1; sub=\$2; shift 2; "\$cli" browser "\$sub" --surface "\$sid" "\$@" > "\$out/\$name" 2>&1; echo "rc=\$?" >> "\$out/\$name"; }
run click click --selector '#b'
hit_seen b-true && echo yes > "\$out/click-title" || grep 'GET /hit' "$root/http.log" > "\$out/click-title" || true
# ref — 같은 문서의 노드 번호(DevTools 의 backendNodeId)를 페이지 밖에서 얻을 길이 아직 없어(snapshot 은 W9b①b) 잘못된 ref 만 본다.
"\$cli" browser click --surface "\$sid" --ref n999999 > "\$out/click-ref" 2>&1; echo "rc=\$?" >> "\$out/click-ref"
run click-covered click --selector '#cover'
sleep 1
run click-missing click --selector '#none'
run click-next click --selector '#next'
url_is b.html && echo yes > "\$out/next-title" || cp "\$out/list" "\$out/next-title"
run back back
url_is a.html && echo yes > "\$out/back-title" || cp "\$out/list" "\$out/back-title"
run forward forward
url_is b.html && echo yes > "\$out/forward-title" || cp "\$out/list" "\$out/forward-title"
run forward-end forward
grep -c 'GET /b.html' "$root/http.log" > "\$out/reload-before" || true
run reload reload
sleep 1
grep -c 'GET /b.html' "$root/http.log" > "\$out/reload-after" || true
touch "\$out/done"
exec sleep 600
PANE
chmod +x "$root/pane.sh"

out="$root/out"
mkdir -p "$out" "$root/home"
printf 'ui.language = ko\nshell.command = %s\nshell.args =\nsession.keep-alive-after-quit = false\n' "$root/pane.sh" > "$root/maru.conf"
env HOME="$root/home" CFFIXED_USER_HOME="$root/home" XDG_CACHE_HOME="$root/home/.cache" MARU_SESSION_HOST_ROOT="$root/session-host" \
    MARU_CONFIG="$root/maru.conf" MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="$url" \
    MARU_TEST_GRANT_DECISION=approve MARU_SMOKE_OUT="$out" MARU_SMOKE_HOME="$root/home" \
    "$app" > "$root/app.log" 2>&1 &
app_pid=$!
i=0
while [ ! -f "$out/done" ] && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
[ -f "$out/done" ] || { sed -n '1,40p' "$root/app.log" >&2; fail "the pane script did not finish ($(cat "$out/list" 2>/dev/null | tr '\n' ' '))"; }
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
app_pid=""

[ -n "$(cat "$out/sid")" ] || fail "no Chromium tab with the test page ($(tr '\n' ' ' < "$out/list"))"
ok() { grep -q '^ok$' "$out/$1" && grep -q '^rc=0$' "$out/$1"; }
ok click && [ "$(cat "$out/click-title")" = yes ] \
    || fail "click did not reach the page as a trusted click ($(tr '\n' ' ' < "$out/click") · $(tr '\n' ' ' < "$out/click-title"))"
echo "PASS click-trusted: the page got a real (isTrusted) click"
grep -q 'not ok' "$out/click-ref" || fail "an unknown ref was not answered not ok ($(tr '\n' ' ' < "$out/click-ref"))"
echo "PASS click-ref: an unknown node ref is not ok"
grep -q 'covered' "$out/click-covered" || fail "a covered button was not refused ($(tr '\n' ' ' < "$out/click-covered"))"
! grep -q 'GET /hit?cover\|GET /hit?over' "$root/http.log" || fail "the covered button or its cover was clicked ($(grep 'GET /hit' "$root/http.log" | tr '\n' ' '))"
echo "PASS click-covered: a covered element is refused and nothing is clicked"
grep -q 'not ok' "$out/click-missing" || fail "a missing element was not answered not ok ($(tr '\n' ' ' < "$out/click-missing"))"
echo "PASS click-missing: a missing element is not ok"
ok click-next && [ "$(cat "$out/next-title")" = yes ] || fail "clicking the link did not open the next page ($(tr '\n' ' ' < "$out/next-title"))"
ok back && [ "$(cat "$out/back-title")" = yes ] || fail "back did not return to the first page ($(tr '\n' ' ' < "$out/back") · $(tr '\n' ' ' < "$out/back-title"))"
ok forward && [ "$(cat "$out/forward-title")" = yes ] || fail "forward did not reopen the next page ($(tr '\n' ' ' < "$out/forward"))"
grep -q 'not ok' "$out/forward-end" || fail "forward at the end of history was not not ok ($(tr '\n' ' ' < "$out/forward-end"))"
echo "PASS back-forward: back and forward follow the history, and forward at the end is not ok"
before=$(cat "$out/reload-before")
after=$(cat "$out/reload-after")
ok reload || fail "reload did not answer ok ($(tr '\n' ' ' < "$out/reload"))"
[ "$after" -gt "$before" ] || fail "reload did not load the page again (b.html requests $before → $after)"
echo "PASS reload: the page was loaded again (b.html requests $before → $after)"
echo "web cdp smoke passed"
