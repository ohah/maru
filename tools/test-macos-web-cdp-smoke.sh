#!/bin/sh
# W9b① 실측 — pane 안의 에이전트(이 대본이 띄운 pane 셸)가 Chromium(OSR) 탭을 DevTools 로 움직이는가(docs/plans/web-osr-backend.md
# W9). 앱을 **일반 모드**로 띄운다(스모크 모드는 셸을 고정 시험 셸로 바꾼다). 확인 모달은 `MARU_TEST_GRANT_DECISION=approve` 로
# 자동 승인한다. 시험 페이지는 `MARU_WEB_OSR_TEST_URL`(시작 브라우저 탭 — `MARU_WEB_PANEL=1`).
#
#   click-trusted   `maru browser click --selector '#b'` → ok, 페이지는 사람 클릭(`isTrusted`)으로 받는다(페이지가 서버로 보내는 신호
#                   요청 `/hit?b-true` — Chromium 탭의 `browser list` 제목은 아직 페이지 제목이 아니다(W9a), 이동은 주소 칸으로 본다)
#   click-ref       모르는 ref(`n999999`)는 not ok(ref 로 실제 누르기는 snapshot 이 ref 를 주는 W9b①b 에서)
#   click-far       화면 밖(1500 px 아래) 요소는 화면 안으로 스크롤해 누른다(누를 때 페이지가 스크롤돼 있었다 — 신호에 싣는다)
#   click-covered   다른 요소가 덮은 버튼은 누르지 않고 「covered」 오류 — 덮은 요소도 눌리지 않는다
#   click-missing   없는 요소는 not ok(WebKit 과 같다)
#   click-clobber   DOM clobbering(덮개를 담은 form 의 `parentNode` 를 덮인 버튼 자신으로 가리킨 페이지)으로도 덮임 검사를 통과하지 못한다
#   snapshot-ref    snapshot(접근성 트리)이 준 ref(`n<backendNodeId>`)로 그 버튼을 진짜로 누른다(W9b①b) — 페이지에 짝 없는 서로게이트
#                   글(잘못 자른 이모지)이 있어도 snapshot 이 실패하지 않는다
#   type            입력칸에 한글을 넣으면 기존 값을 바꿔 쓰고 페이지는 진짜 입력 이벤트로 받는다
#   wait-scroll     늦게 생기는 요소를 기다리고(보일 때 ok), 화면 밖 요소로 스크롤한다
#   wait-real       부른 뒤 2 초 지나 생기는 요소를 실제로 기다린다 · 링크 이동을 넘어 다음 문서의 요소를 기다린다
#   type-guards     빈 글은 지운다(Delete 키) · readonly 칸은 「did not take」(원래 값의 해시가 2^31 아래·위인 둘 — 해시를 같은 부호로 견주는지) · 초점을 가로채는 칸은 「focus moved」 로 아무것도 넣지 않는다
#   type-shaped     값을 다듬는 칸(넣은 글을 대문자 세 글자로 줄여 원래 값과 길이가 같아지는 칸 — 해시까지 견주는지 본다·끝 공백을 지우는 email 칸 — 지운 값을 신호로 본다)은 들어간 것으로 ok · maxlength 로
#                   잘린 칸과 원래 값 뒤에 덧붙은 칸(입력 때 원래 값을 앞에 다시 붙인다)은 「did not take」 · **닫힌** shadow root 안의
#                   칸(snapshot 의 ref)에도 넣는다(초점 검사가 거짓 「focus moved」 를 내지 않는다)
#   scroll-real     scroll 이 페이지를 실제로 굴린다(scrollY — 신호)
#   hover           hover 가 그 요소에 진짜 포인터 이동(isTrusted mouseover)을 준다 · 없는 요소는 not ok(W9b①b-2)
#   role            role 로케이터(W9b②): 이름이 여럿 맞으면 실패하고 후보 ref 를 준다 — 그 ref 로 다시 누르면 진짜 클릭 · --exact·--nth 로 고른다 ·
#                   성공 답에 matched(ref·이름) · 제목은 --level 로 · 모르는 역할은 invalid params(가까운 역할을 권한다) · 요소가 3 만을 넘는 페이지는
#                   질의 전에 거절(too_large — 질의가 페이지를 멈춘다)
#   press           요소에 Shift+a → 「A」(isTrusted keydown — 입력 이벤트만으로는 insertText 와 가를 수 없다) · Meta+a(편집 명령 selectAll)
#                   뒤 대상 없이 x → 값이 「x」로 바뀐다 · Shift+/ → 「?」(US 배열의 위 글자) ·
#                   대상 없이 Tab → 초점이 다음 칸으로 · 틀린 키 이름은 invalid params. 붙여넣기(Meta+v)는 사용자 클립보드를 쓰므로 스모크에
#                   넣지 않는다
#   back·forward    링크로 다음 문서에 간 뒤 뒤로 → 첫 문서, 앞으로 → 다음 문서, 더 앞으로 → not ok
#   reload          새로고침 → ok, 문서가 다시 불린다(서버가 받은 요청 수)
#   wait-nav        기다리는 **도중** 페이지가 다른 문서로 옮겨 가도(0.8 초 뒤 이동, 그 문서가 1 초 뒤 요소를 만든다) 그 요소를 찾는다
#   wait-load       응답이 2 초 늦는 문서로 가는 링크를 누른 뒤 `wait --load` 가 그 문서에서 ok. 그 문서를 새로고침한 직후의 `wait --load` 는
#                   새 응답이 다 불린 뒤에야 ok(wait 만 ≥ 1 초). 이동이 진행 중이면 Chromium 의 DevTools 가 그 페이지로 가는 호출을 새 문서가
#                   올 때까지 붙잡는다(실측 — 이동을 일으킨 클릭도 2.3 초, `nav_state.loading` 을 지운 변이도 이 시험을 지난다) — 옛 문서의
#                   complete 를 읽을 틈이 없다. 그래서 이 경우는 loading 판정이 아니라 Chromium 이 지킨다
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
<button id=t2 name=parentNode form=f2 style="position:absolute;left:300px;top:220px;width:100px;height:40px" onclick="hit('t2')">T2</button>
<form id=f2><div style="position:absolute;left:290px;top:210px;width:140px;height:70px;z-index:5;background:rgba(0,0,0,.2)" onclick="hit('over2')"></div></form>
<button id=rb style="position:absolute;left:20px;top:300px" onclick="hit('rb-'+event.isTrusted)">RefTarget</button>
<input id=in value="old" style="position:absolute;left:20px;top:360px" oninput="hit('in-'+event.isTrusted+'-'+encodeURIComponent(this.value))">
<button id=mk style="position:absolute;left:20px;top:420px" onclick="setTimeout(function(){document.body.insertAdjacentHTML('beforeend','<p id=late2>late2</p>')},2000)">Make</button>
<input id=ro readonly value="ro" style="position:absolute;left:20px;top:460px">
<button id=hv style="position:absolute;left:420px;top:300px" onmouseover="hit('hv-'+event.isTrusted)">Hov</button>
<button id=rs1 style="position:absolute;left:620px;top:100px" onclick="hit('rs1-'+event.isTrusted)">Role Save</button>
<button id=rs2 style="position:absolute;left:620px;top:140px" onclick="hit('rs2-'+event.isTrusted)">Role Save draft</button>
<h2 id=rh style="position:absolute;left:620px;top:170px;margin:0">Role Heading</h2>
<input id=pk style="position:absolute;left:420px;top:340px" onkeydown="hit('pkd-'+event.key+'-'+event.isTrusted)" oninput="hit('pkv-'+encodeURIComponent(this.value)+'-'+event.isTrusted)">
<input id=pk2 style="position:absolute;left:420px;top:380px" onfocus="hit('pk2focus')">
<input id=ro2 readonly value="old" style="position:absolute;left:220px;top:460px">
<input id=fs style="position:absolute;left:20px;top:500px" onfocus="document.getElementById('in').focus()">
<input id=up value="xyz" style="position:absolute;left:20px;top:540px" oninput="this.value=this.value.toUpperCase().slice(0,3);hit('up-'+this.value)">
<input id=ml maxlength=2 style="position:absolute;left:20px;top:580px">
<input id=ap value="pre" style="position:absolute;left:220px;top:540px" oninput="if(this.value.indexOf('pre')!==0)this.value='pre'+this.value">
<input id=em type=email style="position:absolute;left:220px;top:580px" oninput="hit('em-'+encodeURIComponent(this.value))">
<div id=sh style="position:absolute;left:20px;top:620px"></div>
<p id=ls style="position:absolute;left:200px;top:700px"></p><script>document.getElementById('ls').textContent='Lone \ud83d end'</script>
<script>(function(){var r=document.getElementById('sh').attachShadow({mode:'closed'});r.innerHTML='<input aria-label=ShadowField oninput="new Image().src=\'/hit?sh-\'+event.isTrusted+\'-\'+this.value">'})()</script>
<button id=far2 style="position:absolute;top:4000px;left:20px">Far2</button><div style="position:absolute;top:4100px;height:4000px;width:1px"></div>
<script>addEventListener('scroll',function(){if(scrollY>2000&&!window.__sy){window.__sy=1;hit('sy-true')}})</script>
<div id=late-box></div><script>setTimeout(function(){document.getElementById('late-box').innerHTML='<button id=late style=\'position:absolute;left:200px;top:300px\'>Late</button>'},1500)</script>
<button id=far style="position:absolute;top:1500px;left:20px" onclick="hit('far-'+event.isTrusted+'-scrolled-'+(scrollY>0))">Far</button><div style="height:2000px"></div>
HTML
printf '<!doctype html><title>page-b</title>b<script>setTimeout(function(){document.body.insertAdjacentHTML("beforeend","<p id=bready>ready</p>")},1000)</script><button id=go onclick="setTimeout(function(){location=&#39;c.html&#39;},800)">Go</button> <a id=slow href="slow.html">slow</a>' > "$root/www/b.html"
printf '<!doctype html><title>page-c</title>c<script>setTimeout(function(){document.body.insertAdjacentHTML("beforeend","<p id=cready>ready</p>")},1000)</script>' > "$root/www/c.html"
# 느린 문서는 요소가 3 만을 넘는다 — role 로케이터가 질의 전에 거절하는지(W9b②).
python3 -c "import sys; sys.stdout.write('<!doctype html><title>page-slow</title>slow<button>Big</button>' + '<i></i>' * 31000)" > "$root/www/slow.html"
# 받은 요청을 센다(새로고침이 문서를 다시 불렀는지).
cat > "$root/server.py" <<'PY'
import http.server, sys, functools, time
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow.html"):
            time.sleep(2)  # wait-load: 응답이 늦는 문서
        super().do_GET()
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
run click-clobber click --selector '#t2'
run click-far click --selector '#far'
hit_seen far-true-scrolled-true && echo yes > "\$out/far-hit" || echo no > "\$out/far-hit"
"\$cli" browser snapshot --surface "\$sid" --interactive > "\$out/snapshot" 2>&1; echo "rc=\$?" >> "\$out/snapshot"
ref=\$(sed -n 's/.*button "RefTarget" \[ref=\(n[0-9]*\)\].*/\1/p' "\$out/snapshot" | head -1)
echo "\$ref" > "\$out/ref"
shref=\$(sed -n 's/.*textbox "ShadowField" \[ref=\(n[0-9]*\)\].*/\1/p' "\$out/snapshot" | head -1)
echo "\$shref" > "\$out/shref"
run click-ref-real click --ref "\$ref"
hit_seen rb-true && echo yes > "\$out/ref-hit" || echo no > "\$out/ref-hit"
run type type --selector '#in' --text '새 값'
hit_seen 'in-true-%EC%83%88%20%EA%B0%92' && echo yes > "\$out/type-hit" || echo no > "\$out/type-hit"
run wait wait --selector '#late' --timeout 5000
run wait-never wait --selector '#never-there' --timeout 300
run scroll scroll --selector '#far'
run click-mk click --selector '#mk'
run wait-late2 wait --selector '#late2' --timeout 6000
run type-empty type --selector '#in' --text ''
hit_seen 'in-true-\$' && echo yes > "\$out/empty-hit" || echo no > "\$out/empty-hit"
run type-ro type --selector '#ro' --text 'x'
run type-ro2 type --selector '#ro2' --text 'x'
run type-fs type --selector '#fs' --text 'steal'
run type-up type --selector '#up' --text 'abcd'
run role-amb click --role button --name 'Role Save'
amb_ref=\$(sed -n 's/.*\(n[0-9][0-9]*\) "Role Save" (exact).*/\1/p' "\$out/role-amb" | head -1)
echo "\$amb_ref" > "\$out/amb-ref"
run role-ref click --ref "\$amb_ref"
hit_seen rs1-true && echo yes > "\$out/rs1-hit" || echo no > "\$out/rs1-hit"
run role-nth click --role button --name 'Role Save' --nth 1
hit_seen rs2-true && echo yes > "\$out/rs2-hit" || echo no > "\$out/rs2-hit"
run role-exact scroll --role button --name 'Role Save' --exact
run role-level scroll --role heading --level 2 --name 'role heading'
run role-unknown click --role buton
run hover hover --selector '#hv'
hit_seen hv-true && echo yes > "\$out/hv-hit" || echo no > "\$out/hv-hit"
run hover-missing hover --selector '#none'
run press-a press --selector '#pk' --key 'Shift+a'
hit_seen 'pkd-A-true' && hit_seen 'pkv-A-true' && echo yes > "\$out/pk-a" || echo no > "\$out/pk-a"
run press-all press --selector '#pk' --key 'Meta+a'
run press-x press --key 'x'
hit_seen 'pkv-x-true' && echo yes > "\$out/pk-x" || echo no > "\$out/pk-x"
run press-q press --key 'Shift+/'
hit_seen 'pkd-?-true' && hit_seen 'pkv-x%3F-true' && echo yes > "\$out/pk-q" || echo no > "\$out/pk-q"
run press-tab press --key 'Tab'
hit_seen pk2focus && echo yes > "\$out/pk-tab" || echo no > "\$out/pk-tab"
run press-bad press --key 'Hyper+a'
hit_seen up-ABC && echo yes > "\$out/up-hit" || echo no > "\$out/up-hit"
run type-ml type --selector '#ml' --text 'abcd'
run type-ap type --selector '#ap' --text 'X'
run type-em type --selector '#em' --text 'a@b.c '
hit_seen 'em-a%40b.c$' && echo yes > "\$out/em-hit" || echo no > "\$out/em-hit"
run type-sh type --ref "\$shref" --text 'deep'
hit_seen sh-true-deep && echo yes > "\$out/sh-hit" || echo no > "\$out/sh-hit"
sleep 0.5
run scroll2 scroll --selector '#far2'
hit_seen sy-true && echo yes > "\$out/sy-hit" || echo no > "\$out/sy-hit"
run click-next click --selector '#next'
run wait-bready wait --selector '#bready' --timeout 6000
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
run click-go click --selector '#go'
run wait-cready wait --selector '#cready' --timeout 8000
url_is c.html && echo yes > "\$out/c-title" || cp "\$out/list" "\$out/c-title"
run back2 back
url_is b.html || true
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
t0=\$(ms)
run click-slow click --selector '#slow'
tc=\$(ms)
run wait-load wait --load --timeout 8000
t1=\$(ms)
echo \$((tc - t0)) > "\$out/load-click-ms"
url_is slow.html && echo yes > "\$out/slow-title" || cp "\$out/list" "\$out/slow-title"
run role-big click --role button --name Big
t2=\$(ms)
run reload-slow reload
t3=\$(ms)
run wait-load2 wait --load --timeout 8000
t4=\$(ms)
echo \$((t4 - t3)) > "\$out/load-ms"
echo \$((t3 - t2)) > "\$out/reload-ms"
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
grep -q 'covered' "$out/click-clobber" || fail "a covered button behind a DOM-clobbering form was not refused ($(tr '\n' ' ' < "$out/click-clobber"))"
! grep -q 'GET /hit?t2\|GET /hit?over2' "$root/http.log" || fail "the clobbering page's button or cover was clicked ($(grep 'GET /hit' "$root/http.log" | tr '\n' ' '))"
echo "PASS click-clobber: DOM clobbering does not get a covered button past the check"
ok click-far && [ "$(cat "$out/far-hit")" = yes ] || fail "an element below the fold was not scrolled into view and clicked ($(tr '\n' ' ' < "$out/click-far"))"
echo "PASS click-far: an element below the fold is scrolled into view and clicked for real"
grep -q '^rc=0$' "$out/snapshot" && [ -n "$(cat "$out/ref")" ] || fail "snapshot did not list the RefTarget button with a node ref ($(tr '\n' ' ' < "$out/snapshot" | cut -c1-400))"
ok click-ref-real && [ "$(cat "$out/ref-hit")" = yes ] || fail "clicking the snapshot ref $(cat "$out/ref") did not click the button for real ($(tr '\n' ' ' < "$out/click-ref-real"))"
echo "PASS snapshot-ref: the accessibility snapshot gave ref $(cat "$out/ref") and clicking it pressed the button for real"
ok type && [ "$(cat "$out/type-hit")" = yes ] || fail "type did not replace the field's value with a real input event ($(tr '\n' ' ' < "$out/type") · $(grep 'GET /hit?in' "$root/http.log" | tr '\n' ' '))"
echo "PASS type: the field's value was replaced with Korean text through a real (isTrusted) input event"
ok wait && grep -q '(-32004)' "$out/wait-never" && ok scroll || fail "wait or scroll did not behave ($(tr '\n' ' ' < "$out/wait") · $(tr '\n' ' ' < "$out/wait-never") · $(tr '\n' ' ' < "$out/scroll"))"
echo "PASS wait-scroll: waiting for a late element succeeds, a missing one times out (-32004), scroll is ok"
ok wait-late2 || fail "waiting for an element made 2 s after the call did not succeed ($(tr '\n' ' ' < "$out/wait-late2"))"
ok wait-bready || fail "waiting across a link navigation for the next page's element did not succeed ($(tr '\n' ' ' < "$out/wait-bready"))"
echo "PASS wait-real: waits for an element made 2 s later, and across a navigation for the next page's element"
ok type-empty && [ "$(cat "$out/empty-hit")" = yes ] || fail "typing empty text did not clear the field with a real input ($(tr '\n' ' ' < "$out/type-empty") · $(grep 'GET /hit?in' "$root/http.log" | tr '\n' ' '))"
grep -q 'did not take' "$out/type-ro" && grep -q 'did not take' "$out/type-ro2" || fail "typing into a read-only field was not refused ($(tr '\n' ' ' < "$out/type-ro") · $(tr '\n' ' ' < "$out/type-ro2"))"
grep -q 'focus moved' "$out/type-fs" && ! grep -q 'GET /hit?in-true-steal' "$root/http.log" || fail "a field that moves focus away was not refused, or the text went elsewhere ($(tr '\n' ' ' < "$out/type-fs"))"
echo "PASS type-guards: empty text clears for real, a read-only field and a focus-stealing field are refused and nothing lands elsewhere"
ok type-up && [ "$(cat "$out/up-hit")" = yes ] || fail "a field that reshapes its value (upper case) was not taken as typed ($(tr '\n' ' ' < "$out/type-up"))"
grep -q 'did not take' "$out/type-ml" || fail "a maxlength field that cut the text was not refused ($(tr '\n' ' ' < "$out/type-ml"))"
grep -q 'did not take' "$out/type-ap" || fail "a field that moved the caret to the end (the text was appended, not replaced) was not refused ($(tr '\n' ' ' < "$out/type-ap"))"
ok type-em && [ "$(cat "$out/em-hit")" = yes ] || fail "an email field that trims the trailing space was not taken as typed ($(tr '\n' ' ' < "$out/type-em") · $(grep 'GET /hit?em' "$root/http.log" | tr '\n' ' '))"
[ -n "$(cat "$out/shref")" ] || fail "snapshot did not list the field inside the closed shadow root ($(tr '\n' ' ' < "$out/snapshot" | cut -c1-400))"
ok type-sh && [ "$(cat "$out/sh-hit")" = yes ] || fail "typing into a field inside a closed shadow root did not go in for real ($(tr '\n' ' ' < "$out/type-sh"))"
echo "PASS type-shaped: a reshaping field and an email field's trim are ok, a maxlength cut and an append are refused, a field inside a closed shadow root takes the text"
ok hover && [ "$(cat "$out/hv-hit")" = yes ] || fail "hover did not give the element a real pointer move ($(tr '\n' ' ' < "$out/hover"))"
grep -q 'not ok' "$out/hover-missing" || fail "hovering a missing element was not not ok ($(tr '\n' ' ' < "$out/hover-missing"))"
echo "PASS hover: the element got a real (isTrusted) mouseover, a missing element is not ok"
grep -q 'ambiguous: 2 elements match role=button name~"Role Save"' "$out/role-amb" && [ -n "$(cat "$out/amb-ref")" ] || fail "an ambiguous role locator did not fail with candidate refs ($(tr '\n' ' ' < "$out/role-amb"))"
ok role-ref && [ "$(cat "$out/rs1-hit")" = yes ] || fail "clicking the candidate ref $(cat "$out/amb-ref") did not click Role Save for real ($(tr '\n' ' ' < "$out/role-ref"))"
ok role-nth && grep -q 'matched n[0-9]* "Role Save draft"' "$out/role-nth" && [ "$(cat "$out/rs2-hit")" = yes ] || fail "--nth 1 did not click the second match for real ($(tr '\n' ' ' < "$out/role-nth"))"
ok role-exact && grep -q 'matched n[0-9]* "Role Save"$' "$out/role-exact" || fail "--exact did not pick only Role Save ($(tr '\n' ' ' < "$out/role-exact"))"
ok role-level && grep -q 'matched n[0-9]* "Role Heading"' "$out/role-level" || fail "--level 2 did not find the h2 ($(tr '\n' ' ' < "$out/role-level"))"
grep -q '(-32602)' "$out/role-unknown" && grep -q 'did you mean "button"' "$out/role-unknown" || fail "an unknown role was not invalid params with a suggestion ($(tr '\n' ' ' < "$out/role-unknown"))"
grep -q 'too_large: page has [0-9]* elements' "$out/role-big" || fail "a page with over 30000 elements was not refused before the query ($(tr '\n' ' ' < "$out/role-big"))"
echo "PASS role: an ambiguous name failed with candidate refs and the ref clicked for real, --nth/--exact/--level picked the right element (matched), an unknown role suggested button, a 31000-element page was refused"
ok press-a && [ "$(cat "$out/pk-a")" = yes ] || fail "press Shift+a on the field did not type A with a real key ($(tr '\n' ' ' < "$out/press-a") · $(grep 'GET /hit?pk' "$root/http.log" | tr '\n' ' '))"
ok press-all && ok press-x && [ "$(cat "$out/pk-x")" = yes ] || fail "Meta+a then x (where the focus is) did not replace the value ($(tr '\n' ' ' < "$out/press-all") · $(tr '\n' ' ' < "$out/press-x") · $(grep 'GET /hit?pk' "$root/http.log" | tr '\n' ' '))"
ok press-q && [ "$(cat "$out/pk-q")" = yes ] || fail "Shift+/ did not press ? as a real key ($(tr '\n' ' ' < "$out/press-q") · $(grep 'GET /hit?pk' "$root/http.log" | tr '\n' ' '))"
ok press-tab && [ "$(cat "$out/pk-tab")" = yes ] || fail "Tab (where the focus is) did not move the focus to the next field ($(tr '\n' ' ' < "$out/press-tab"))"
grep -q '(-32602)' "$out/press-bad" && grep -q 'unknown key name' "$out/press-bad" || fail "an unknown key name was not invalid params ($(tr '\n' ' ' < "$out/press-bad"))"
echo "PASS press: Shift+a typed A (a real keydown), Meta+a selected all and x replaced it, Shift+/ typed ?, Tab moved the focus, an unknown key name is invalid params"
ok scroll2 && [ "$(cat "$out/sy-hit")" = yes ] || fail "scroll did not move the page ($(tr '\n' ' ' < "$out/scroll2"))"
echo "PASS scroll-real: scroll moved the page down to the element"
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
ok click-go && ok wait-cready && [ "$(cat "$out/c-title")" = yes ] \
    || fail "waiting while the page moved to another document did not find that document's element ($(tr '\n' ' ' < "$out/wait-cready") · $(tr '\n' ' ' < "$out/c-title"))"
echo "PASS wait-nav: the wait kept going while the page moved to another document and found its element"
load_ms=$(cat "$out/load-ms")
ok click-slow && ok wait-load && [ "$(cat "$out/slow-title")" = yes ] || fail "wait --load after clicking a slow link did not succeed on that page ($(tr '\n' ' ' < "$out/wait-load") · $(tr '\n' ' ' < "$out/slow-title"))"
ok reload-slow && ok wait-load2 || fail "reloading the slow page and waiting for it to load did not succeed ($(tr '\n' ' ' < "$out/reload-slow") · $(tr '\n' ' ' < "$out/wait-load2"))"
[ "$load_ms" -ge 1000 ] || fail "wait --load answered before the reloaded slow page (2 s late) loaded (the wait took ${load_ms} ms, the reload $(cat "$out/reload-ms") ms)"
echo "PASS wait-load: wait --load on the slow page is ok, and right after a reload it answers only once the new response loaded (the wait took ${load_ms} ms, the reload $(cat "$out/reload-ms") ms, the link click $(cat "$out/load-click-ms") ms)"
echo "web cdp smoke passed"
