#!/bin/sh
# W3b 로컬 스모크(CI 밖 — CEF SDK 가 필요하다): 앱이 Chromium sidecar 를 띄워 browser 탭을 만들고 이동시키며, 끝나면 남기지
# 않는다. 제품에 결과를 읽는 훅을 두지 않고 바깥에서 본다 — 앱의 자식 프로세스, 시험 HTTP 서버가 받은 요청, 프로필 권한,
# 종료 뒤 남은 sidecar.
set -eu

sidecar_dir="$PWD/zig-out/web-sidecar"
app=./zig-out/bin/maru-macos-app
test -x "$sidecar_dir/maru-web-host" || { echo "web-osr smoke: build the sidecar first (mise run web-sidecar)" >&2; exit 2; }
test -x "$app" || { echo "web-osr smoke: build the app first (zig build macos-app-build)" >&2; exit 2; }

root=$(mktemp -d "/tmp/maru-web-osr-smoke.XXXXXX")
server_pid=""
app_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    pkill -KILL -f "$root" 2>/dev/null || true
    rm -rf "$root"
}
trap cleanup EXIT HUP INT TERM

port=$((20000 + $$ % 20000))
cat > "$root/server.py" <<'PY'
import http.server, sys, base64
log = open(sys.argv[2], 'a', buffering=1)
# W4b: 페이지가 받은 DOM 이벤트를 `/ev?e=...` 요청으로 알린다(제품에 읽는 훅을 두지 않고 바깥에서 본다).
TEXT = " ".join(["maru selects this paragraph text by dragging across it"] * 40)
INPUT = ("<!doctype html><title>input</title><style>html,body{margin:0;height:3000px;font:28px sans-serif}p{margin:0;line-height:40px}</style>"
    "<body><p>" + TEXT + "</p><script>"
    "function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}"
    "addEventListener('click',function(e){ping('e=click&x='+e.clientX+'&y='+e.clientY+'&b='+e.button+'&d='+e.detail+'&w='+innerWidth)});"
    "addEventListener('dblclick',function(e){ping('e=dblclick&d='+e.detail)});"
    "addEventListener('contextmenu',function(e){ping('e=contextmenu&x='+e.clientX)});"
    "addEventListener('auxclick',function(e){if(e.button==1)ping('e=aux&b=1')});"
    "var out=false,hov=false;addEventListener('mousemove',function(e){if((e.buttons&1)&&e.clientX<0&&!out){out=true;ping('e=dragout&x='+e.clientX)}if(!e.buttons&&!hov){hov=true;ping('e=hover&x='+e.clientX)}});"
    "addEventListener('mouseup',function(e){if(e.button==0)ping('e=up&sel='+getSelection().toString().length+'&x='+e.clientX+'&y='+e.clientY)});"
    "document.documentElement.addEventListener('mouseleave',function(){ping('e=leave')});"
    "addEventListener('scroll',function(){clearTimeout(window.sc);window.sc=setTimeout(function(){ping('e=scroll&y='+scrollY)},300)});"
    "requestAnimationFrame(function(){requestAnimationFrame(function(){ping('e=ready')})});"
    "</script>").encode()
# W4c: 키보드 — textarea 가 받은 keydown·값·조합·포커스를 `/ev` 로 알린다.
KEYS = ("<!doctype html><title>keys</title><style>html,body{margin:0;height:100%}textarea{display:block;width:100%;height:100%;box-sizing:border-box;font:24px sans-serif}</style>"
    "<body><textarea id=t></textarea><script>"
    "var t=document.getElementById('t');function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}"
    "t.addEventListener('keydown',function(e){ping('e=kd&k='+encodeURIComponent(e.key)+'&c='+(e.ctrlKey?1:0)+'&m='+(e.metaKey?1:0))});"
    "t.addEventListener('keypress',function(e){ping('e=kp&k='+encodeURIComponent(e.key))});"
    "t.addEventListener('input',function(e){ping('e=val&v='+encodeURIComponent(t.value)+'&comp='+(e.isComposing?1:0))});"
    "t.addEventListener('compositionend',function(e){ping('e=cend&d='+encodeURIComponent(e.data))});"
    "t.addEventListener('focus',function(){ping('e=focus')});t.addEventListener('blur',function(){ping('e=blur')});"
    "requestAnimationFrame(function(){requestAnimationFrame(function(){ping('e=ready')})});"
    "</script>").encode()
# W6a②: 팝업 위젯 — 빨간 select(왼쪽 위 절반) 하나와 초록 바탕. 초점을 `/ev` 로 알린다.
SEL = ("<!doctype html><title>sel</title><style>html,body{margin:0;height:100%;background:#20a060}"
    "select{position:fixed;left:0;top:0;width:50%;height:40%;border:0;background:#ff0000;font:20px sans-serif}</style><body>"
    "<select id=a><option>apple<option>banana<option>cherry<option>date<option>elder</select><script>"
    "var a=document.getElementById('a');a.addEventListener('focus',function(){new Image().src='/ev?e=focus&id=a&t='+Date.now()});"
    "a.addEventListener('change',function(){new Image().src='/ev?e=change&v='+a.value+'&t='+Date.now()});"
    "</script>").encode()
# W6b: 툴팁 — 왼쪽 위(본문 폭 50%·높이 60%)에 두 줄 title, 나머지는 title 없음.
TIP = ("<!doctype html><title>tip</title><style>html,body{margin:0;height:100%;background:#20a060}"
    "#a{position:fixed;left:0;top:0;width:50%;height:60%;background:#ff0000}</style><body>"
    "<div id=a title='A tip&#10;line2'>a</div>").encode()
# W6c②: 우클릭 메뉴 — 왼쪽 위 링크 칸(본문 폭 50%·높이 30% — 글이 없는 자리를 누르면 낱말이 골라지지 않는다), 그 아래 입력 칸
# (글 「abc」 — 오른쪽 빈 자리를 우클릭하면 낱말이 골라지지 않는다), 오른쪽 위 빈 곳, 그 아래 큰 글 「hello world」(두 번 눌러
# 고른다), 오른쪽 아래는 우클릭하면 0.5 초 뒤 이동하는 칸(메뉴가 떠 있는 채 닫히는지). 불러옴·입력·
# 오른쪽 뗌을 `/ev` 로 알린다.
MENU = ("<!doctype html><title>menu</title><style>html,body{margin:0;height:100%;background:#20a060;font:28px sans-serif}"
    "#l{position:fixed;left:0;top:0;width:50%;height:30%;display:block;background:#ff0000}"
    "#i{position:fixed;left:0;top:45%;width:50%;height:15%;font:28px sans-serif}"
    "#p{position:fixed;left:50%;top:35%;font:60px sans-serif;margin:0}"
    "#n{position:fixed;left:50%;top:60%;width:50%;height:40%;background:#0000ff}</style><body>"
    "<a id=l href='/cm-target'>link</a><input id=i value='abc'><p id=p>hello world</p><div id=n></div><script>"
    "function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}ping('e=load&nt='+performance.getEntriesByType('navigation')[0].type);"
    "document.getElementById('i').addEventListener('input',function(e){ping('e=input&v='+encodeURIComponent(e.target.value))});"
    "addEventListener('mouseup',function(e){if(e.button==2)ping('e=up&b=2')});"
    "document.getElementById('n').addEventListener('contextmenu',function(){setTimeout(function(){location='/cm-app?2'},500)});"
    "</script>").encode()
# W6d①: 끌어 놓기 — 왼쪽 위(폭 50%·높이 60%) 받는 칸(파일 — 처음 dragover 에 본 파일 수, 놓으면 이름:크기와 첫 파일 내용),
# 오른쪽 위(폭 50%·높이 40%) 글 칸(값), 오른쪽 아래 이동 칸(동작 이동 — 놓인 글과 사용자 정의 형식), 왼쪽 아래 거절 칸(동작
# 없음), 들어왔다 나가면 leave. W6d②: 받는 칸 아래 끌 요소(글 `smoke-drag`·사용자 정의 형식 `application/x-maru` — 끝나면 동작),
# 페이지가 받은 mouseup. `/ev` 로 알린다.
DND = ("<!doctype html><title>dnd</title><style>html,body{margin:0;height:100%;background:#20a060}"
    "#z{position:fixed;left:0;top:0;width:50%;height:60%;background:#ff0000}"
    "#t{position:fixed;left:50%;top:0;width:50%;height:40%;font:28px sans-serif}"
    "#m{position:fixed;left:50%;top:60%;width:50%;height:40%;background:#0000ff}"
    "#n{position:fixed;left:0;top:70%;width:50%;height:30%;background:#ffff00}"
    "#d{position:fixed;left:0;top:60%;width:50%;height:10%;background:#ff00ff}"
    "#im{position:fixed;left:50%;top:42%;width:50%;height:16%}</style><body>"
    "<div id=z></div><textarea id=t></textarea><div id=m></div><div id=n></div><div id=d draggable=true></div>"
    "<img id=im src='/img/cat.png'><script>"
    "function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}ping('e=load');var over=0;"
    "var z=document.getElementById('z');"
    "z.addEventListener('dragenter',function(e){e.preventDefault();over=0});"
    "z.addEventListener('dragover',function(e){e.preventDefault();e.dataTransfer.dropEffect='copy';if(!over++)ping('e=over&f='+e.dataTransfer.files.length)});"
    "z.addEventListener('dragleave',function(e){if(e.target===z)ping('e=leave')});"
    "z.addEventListener('drop',function(e){e.preventDefault();var f=e.dataTransfer.files,n=[];for(var i=0;i<f.length;i++)n.push(f[i].name+':'+f[i].size);"
    "ping('e=drop&names='+encodeURIComponent(n.join(',')));if(f.length){var r=new FileReader();r.onload=function(){ping('e=content&v='+encodeURIComponent(r.result))};r.readAsText(f[0])}});"
    "document.getElementById('t').addEventListener('input',function(e){ping('e=input&v='+encodeURIComponent(e.target.value))});"
    "var m=document.getElementById('m');m.addEventListener('dragenter',function(e){e.preventDefault()});"
    "m.addEventListener('dragover',function(e){e.preventDefault();e.dataTransfer.dropEffect='move'});"
    "m.addEventListener('drop',function(e){e.preventDefault();ping('e=mdrop&v='+encodeURIComponent(e.dataTransfer.getData('text/plain'))+'&x='+encodeURIComponent(e.dataTransfer.getData('application/x-maru')))});"
    "var d=document.getElementById('d');d.addEventListener('dragstart',function(e){e.dataTransfer.setData('text/plain','smoke-drag');e.dataTransfer.setData('application/x-maru','smoke-secret');e.dataTransfer.effectAllowed='copyMove';ping('e=dstart')});"
    "d.addEventListener('dragend',function(e){ping('e=dend&v='+e.dataTransfer.dropEffect)});"
    "addEventListener('mouseup',function(){ping('e=up')});"
    "var n=document.getElementById('n');n.addEventListener('dragenter',function(e){e.preventDefault()});"
    "n.addEventListener('dragover',function(e){e.preventDefault();e.dataTransfer.dropEffect='none'});"
    "n.addEventListener('drop',function(e){e.preventDefault();ping('e=ndrop')});"
    "</script>").encode()
CAT_PNG = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAQUlEQVR4nO3OQQ0AMBAEofNvupWx8yBBAPfuUvYDISEhoZj9QEhISChmPxASEhKK2Q+EhISEYvYDISEhoZj9oB763xP3eV+LAIgAAAAASUVORK5CYII="
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        log.write(self.path + "\n")
        if self.path == "/solid":
            body = b"<!doctype html><title>solid</title><style>html,body{margin:0;height:100%;background:#20a060}</style><body>"
        elif self.path == "/anim":
            body = b"<!doctype html><title>anim</title><style>html,body{margin:0;height:100%}</style><body><script>let n=0;function f(){n++;document.body.style.background='rgb('+(n&255)+',80,160)';requestAnimationFrame(f)}f()</script>"
        elif self.path.startswith("/ev"):
            body = b""
        elif self.path == "/input":
            body = INPUT
        elif self.path == "/keys-app":
            body = KEYS
        elif self.path == "/sel":
            body = SEL
        elif self.path.startswith("/cm-app"):
            body = MENU
        elif self.path == "/tip-app":
            body = TIP
        elif self.path == "/dnd-app":
            body = DND
        elif self.path == "/img/cat.png":
            # W6d③: 끌어내 파일로 만들 이미지(48×48 빨간 PNG).
            body = base64.b64decode(CAT_PNG)
            self.send_response(200); self.send_header('Content-Type', 'image/png'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        elif self.path == "/nt-app":
            # W6e: 위는 보통 링크(가운데 클릭 → 뒤 탭 — 5000 자 주소: 새 탭의 첫 이동이 4 KiB 에서 버려지지 않는지. 다시 켤 때의 저장은 여전히 4 KiB 까지),
            # 아래는 `target=_blank`(앞 탭).
            body = (b"<!doctype html><title>nt</title><style>html,body{margin:0;height:100%}a{position:absolute;left:0;width:100%;display:block}</style><body>"
                    b"<a href='/nt-b?q=" + b"x" * 5000 + b"' style='top:5%;height:40%;background:#ccf'>b</a><a href='/nt-a' target=_blank style='top:55%;height:40%;background:#cfc'>a</a>")
        elif self.path in ("/pop-app", "/pop-stay"):
            # W6f②: 누르면 팝업을 연다 — 팝업이 opener 로 알리면 1.5 초 뒤 닫는다(팝업이 앞 탭이 되어 다시 누를 수 없다). `/pop-stay` 는 닫지
            # 않는다(그 팝업 탭의 스크린샷).
            close = b"" if self.path == "/pop-stay" else b"setTimeout(function(){window.w.close();setTimeout(function(){ping('closed-'+window.w.closed)},500)},1500)"
            # 위 절반은 보통 링크(가운데 클릭 — 오른쪽에 뒤 탭을 먼저 만든다: 팝업이 닫힌 뒤 오른쪽 이웃이 아니라 연 탭으로 돌아가는지).
            body = (b"<!doctype html><title>pop</title><style>html,body{margin:0;height:100%}a{position:absolute;left:0;width:100%;display:block}</style><body>"
                    b"<a href='/pop-nb' style='top:0;height:45%;background:#fcc'>nb</a>"
                    b"<a href='#' style='top:55%;height:45%;background:#ccf' onclick=\"window.w=window.open('/pop-child','pc');return false\">open</a>"
                    b"<script>function ping(e){new Image().src='/ev?e='+e+'&t='+Date.now()}"
                    b"addEventListener('message',function(m){ping('msg-'+m.data);" + close + b"})</script>")
        elif self.path == "/pop-nb":
            body = b"<!doctype html><title>nb</title><body>nb"
        elif self.path == "/pop-child":
            body = b"<!doctype html><title>child</title><style>html,body{margin:0;height:100%;background:#20a060}</style><body><script>if(window.opener)window.opener.postMessage('hi','*')</script>"
        elif self.path == "/nt-a" or self.path.startswith("/nt-b?"):
            body = b"<!doctype html><title>nt target</title><body>target"
        elif self.path == "/nav-a":
            body = b"<!doctype html><title>a</title><style>html,body{margin:0;height:100%}a{display:block;height:100%}</style><body><a href='/nav-b'>b</a><script>addEventListener('pageshow',function(){new Image().src='/ev?e=shown-a&t='+Date.now()})</script>"
        elif self.path == "/nav-b":
            body = b"<!doctype html><title>b</title><body style='margin:0;height:100%'>b"
        else:
            body = b"<!doctype html><title>osr-smoke</title><body>osr smoke"
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$root/server.py" "$port" "$root/requests.log" &
server_pid=$!
sleep 1

mkdir -p "$root/home"
HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/osr-smoke" \
MARU_MACOS_APP_SMOKE_MS=20000 "$app" > "$root/app.log" 2>&1 &
app_pid=$!

fail() { echo "web-osr smoke failed: $1" >&2; exit 1; }

# 1) 앱의 자식으로 sidecar 가 뜬다.
# sidecar 만 고른다 — 앱은 띄우기 전에 `codesign --verify --strict <…/maru-web-host>` 를 자식으로 돌려(W7a2) `-f maru-web-host`
# 가 그 잠깐 사는 프로세스를 잡으면 곧 사라져 명령줄이 비었다(W6a② 때 연달아 실측).
host_pid=""
for _ in $(seq 1 100); do
    host_pid=$(pgrep -P "$app_pid" -f 'maru-web-host --profile-dir' || true)
    [ -n "$host_pid" ] && break
    sleep 0.1
done
[ -n "$host_pid" ] || fail "no maru-web-host child of the app"
echo "sidecar pid $host_pid (parent $app_pid)"
# W7a2: sidecar 는 설치(여기선 개발 디렉터리)가 아니라 그 실행 사본에서 돈다.
run_root="$root/home/Library/Caches/maru/web-osr-run"
case "$(ps -o command= -p "$host_pid")" in
    "$run_root"/run-*/maru-web-host*) echo "the sidecar runs from its run copy" ;;
    *) fail "the sidecar does not run from a run copy under $run_root ($(ps -o command= -p "$host_pid"))" ;;
esac

# 2) sidecar 가 시험 주소를 요청한다(띄우기·handshake·생성·이동이 모두 됐다).
for _ in $(seq 1 150); do
    grep -qx "/osr-smoke" "$root/requests.log" 2>/dev/null && break
    sleep 0.1
done
grep -qx "/osr-smoke" "$root/requests.log" || fail "the sidecar never requested the test page"
echo "test page requested by the sidecar"

# 2b) sidecar 가 죽으면 다시 띄워 열린 탭을 같은 주소로 되살린다. 60 초 안에 세 번 죽으면 더 띄우지 않는다.
wait_new_child() { # $1 = 이전 pid — 새 자식 pid 를 찍는다(없으면 빈 줄)
    for _ in $(seq 1 100); do
        pid=$(pgrep -P "$app_pid" -f 'maru-web-host --profile-dir' || true)
        if [ -n "$pid" ] && [ "$pid" != "$1" ]; then echo "$pid"; return; fi
        sleep 0.1
    done
    echo ""
}
kill -KILL "$host_pid"
second=$(wait_new_child "$host_pid")
[ -n "$second" ] || fail "no restart after the first crash"
for _ in $(seq 1 150); do
    [ "$(grep -cx "/osr-smoke" "$root/requests.log")" -ge 2 ] && break
    sleep 0.1
done
[ "$(grep -cx "/osr-smoke" "$root/requests.log")" -ge 2 ] || fail "the restarted sidecar did not reopen the page"
echo "restarted as $second and reopened the page"
kill -KILL "$second"
third=$(wait_new_child "$second")
[ -n "$third" ] || fail "no restart after the second crash"
kill -KILL "$third"
sleep 3
latched=$(pgrep -P "$app_pid" -f 'maru-web-host --profile-dir' || true)
[ -z "$latched" ] || fail "restarted again after three crashes in a minute ($latched)"
echo "third crash within a minute: no restart (budget)"
# 죽은 sidecar 의 사본은 거둘 때 지운다 — 멈춘 뒤 남은 사본이 없다.
left=$(find "$run_root" -mindepth 1 -maxdepth 1 -name 'run-*' 2>/dev/null)
[ -z "$left" ] || fail "run copies left after the crashed sidecars were reaped: $left"
host_pid=$third

# 3) 프로필은 번들 ID 별 경로에 0700 으로.
profile=$(find "$root/home/Library/Application Support/maru/web" -maxdepth 2 -type d -name profile | head -1)
[ -n "$profile" ] || fail "no profile directory"
mode=$(stat -f "%Lp" "$profile")
[ "$mode" = "700" ] || fail "profile mode $mode"
echo "profile $profile mode $mode"

# 4) 앱이 끝나면 sidecar 도 남지 않는다.
wait "$app_pid" || true
app_pid=""
for _ in $(seq 1 100); do
    kill -0 "$host_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$host_pid" 2>/dev/null && fail "sidecar $host_pid still alive after the app exited"
leftover=$(pgrep -f "$profile" || true)
[ -z "$leftover" ] || fail "processes still using the profile: $leftover"

# ── W3c: 본문을 실제로 그린다 ───────────────────────────────────────────────────────────────────────────
# 앱을 새로 띄워(재시작 예산이 걸리지 않게) 세 가지를 잰다: 정적 페이지가 본문을 빈틈없이 채우는가(스크린샷), 애니메이션
# 페이지를 CEF 빈도에 가깝게 다시 그리는가, 정적 페이지에서는 다시 그리지 않는가(요약의 metal_frames_drawn).
run_app() { # $1=경로 $2=실행 ms $3=요약 파일, 나머지는 추가 환경. 우클릭 메뉴는 띄우지 않고 곧바로 취소한다(W6c② — 셸에서
            # 띄운 앱은 맨 앞이 아니라 메뉴를 쓸 수 없고, 진짜 메뉴는 아무도 닫지 못해 앱이 끝나지 않았다). W6c② 단계는 `=1` 로 덮는다.
    path=$1; ms=$2; summary=$3; shift 3
    rm -rf "$root/home" && mkdir -p "$root/home"
    env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
        MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port$path" \
        MARU_MACOS_APP_SMOKE_MS="$ms" MARU_APP_SUMMARY_PATH="$summary" MARU_WEB_OSR_TEST_CONTEXT_MENU=cancel "$@" "$app" > "$root/app-${path#/}.log" 2>&1
}

run_app /solid 20000 "$root/solid.summary" MARU_SCREENSHOT="$root/shot.ppm" MARU_SCREENSHOT_DELAY_MS=7000
[ -f "$root/shot.ppm" ] || fail "no screenshot"
python3 - "$root/shot.ppm" <<'PY' || fail "the page did not fill the pane body"
import sys
d = open(sys.argv[1], 'rb').read()
_, dims, _, px = d.split(b'\n', 3)
w, h = map(int, dims.split())
green = bytes.fromhex('20a060')
xs, ys = [], []
for y in range(h):
    for x in range(w):
        i = (y * w + x) * 3
        if px[i:i + 3] == green:
            xs.append(x); ys.append(y)
if not xs: print('no page pixels'); sys.exit(1)
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
area = (x1 - x0 + 1) * (y1 - y0 + 1)
holes = area - len(xs)
print(f'page rect {x1-x0+1}x{y1-y0+1} of {w}x{h} · non-page pixels inside {holes}')
sys.exit(0 if holes == 0 and area > w * h // 3 else 1)
PY

run_app /anim 9000 "$root/anim.summary"
run_app /solid 9000 "$root/static.summary"
anim=$(sed -n 's/^metal_frames_drawn=//p' "$root/anim.summary")
still=$(sed -n 's/^metal_frames_drawn=//p' "$root/static.summary")
echo "frames drawn in 9 s: animated page $anim · static page $still"
# 9 초 중 앞 ~2 초는 sidecar·첫 장 준비다 — 남은 7 초를 CEF 약 60fps 로 따라가면 300 을 넘는다.
[ "${anim:-0}" -ge 300 ] || fail "the animated page redrew only ${anim:-0} times in 9 s"
[ "${still:-0}" -le 60 ] || fail "the static page kept redrawing (${still} times in 9 s)"
# ── W4b: 포인터 ─────────────────────────────────────────────────────────────────────────────────────────────
# 셸에서 띄운 앱은 활성이 되지 못해 밖에서 합성한 클릭이 창 활성화에 먹힌다(실측). 밖에서 앱을 활성으로 만들면 사용자
# 작업의 포커스를 빼앗으므로, 앱이 대본(`MARU_WEB_OSR_TEST_INPUT`)을 읽어 Swift 가 부르는 같은 ABI 로 입력을 넣는다.
# 페이지가 받은 DOM 이벤트를 `/ev` 요청으로 알리고 여기서 본다. 좌표는 창 내용 view 의 비율 + pt.
cat > "$root/pointer.txt" <<'SCRIPT'
sleep 7000
hover 0.5 0.5 0 0
sleep 300
hover 0.5 0.5 10 0
sleep 300
hover 0.02 0.5 0 0
sleep 300
mouse 1 0.5 0.5 0 0 0
mouse 3 0.5 0.5 0 0 0
sleep 300
mouse 1 0.5 0.5 100 0 0
mouse 3 0.5 0.5 100 0 0
sleep 300
mouse 1 1.0 0.5 -50 0 0
mouse 3 1.0 0.5 -50 0 0
sleep 300
mouse 1 0.5 0.5 0 60 0
mouse 3 0.5 0.5 0 60 0
mouse 4 0.5 0.5 0 60 0
mouse 3 0.5 0.5 0 60 0
sleep 300
mouse 1 0.5 0.5 0 0 2
mouse 3 0.5 0.5 0 0 2
sleep 300
mouse 1 0.5 0.5 0 0 1
mouse 3 0.5 0.5 0 0 1
sleep 300
mouse 1 0.5 0.35 0 0 0
mouse 2 0.3 0.35 0 0 0
mouse 2 0.1 0.35 0 0 0
mouse 2 0.02 0.35 0 0 0
mouse 3 0.02 0.35 0 0 0
sleep 300
mouse 1 0.6 0.25 0 0 0
mouse 2 0.5 0.25 0 0 0
mouse 1 0.5 0.25 0 0 2
mouse 3 0.5 0.25 0 0 2
mouse 2 0.4 0.25 0 0 0
mouse 3 0.4 0.25 0 0 0
sleep 300
wheel 0.5 0.5 0 0 -5
sleep 500
hover 0.5 0.5 0 0
sleep 300
action toggle_command_palette
sleep 300
mouse 1 0.5 0.5 0 120 0
mouse 3 0.5 0.5 0 120 0
sleep 300
key 53 U+1B
sleep 300
mouse 1 0.5 0.5 0 -120 0
mouse 3 0.5 0.5 0 -120 0
sleep 1000
SCRIPT
: > "$root/requests.log"
run_app /input 30000 "$root/input.summary" MARU_WEB_OSR_TEST_INPUT="$root/pointer.txt"
python3 - "$root/requests.log" <<'PY' || fail "pointer input did not reach the page as expected"
import sys, urllib.parse
evs = []
for line in open(sys.argv[1]):
    if not line.startswith('/ev?'): continue
    evs.append(dict(urllib.parse.parse_qsl(line.strip()[4:])))
def of(name): return [e for e in evs if e.get('e') == name]
clicks = [e for e in of('click') if e['b'] == '0']
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check(bool(of('ready')), 'page ready')
names = [e.get('e') for e in evs]
# hover 는 클릭·끌기보다 먼저 한다 — 끌기를 뗄 때 Blink 가 내는 mouseleave 로 leave 판정이 거짓 통과하지 않게(적대 검증).
first_click = names.index('click') if 'click' in names else len(names)
check('hover' in names[:first_click], 'a buttonless move over the body reaches the page')
check('leave' in names[:first_click], 'moving off the body sends leave (before any click)')
check(len(clicks) >= 2, f'left clicks reached the page ({len(clicks)})')
if len(clicks) >= 2:
    x0, y0 = int(clicks[0]['x']), int(clicks[0]['y'])
    check(abs(int(clicks[1]['x']) - x0 - 100) <= 1 and clicks[1]['y'] == clicks[0]['y'], f'100 pt to the right is clientX +100 ({clicks[0]["x"]} -> {clicks[1]["x"]})')
    # 본문은 view 오른쪽 끝(창 여백 몇 pt 안쪽)까지다 — view 오른쪽 끝에서 50 pt 안은 clientX ≈ innerWidth − 50. 본문 시작
    # 오프셋을 빼먹으면 사이드바 폭만큼 어긋난다(상대 차이 판정은 그것을 못 잡는다).
    edge = [c for c in clicks if abs(int(c['x']) - (int(c['w']) - 50)) <= 12]
    check(bool(edge), 'a click 50 pt inside the right edge lands at clientX ≈ innerWidth − 50 (absolute coordinates)')
    gated = [c for c in clicks if abs(int(c['y']) - (y0 + 120)) <= 1]
    after = [c for c in clicks if abs(int(c['y']) - (y0 - 120)) <= 1]
    check(not gated, f'a click while the command palette is open does not reach the page ({len(gated)})')
    check(bool(after), 'a click after closing the palette reaches the page')
check(any(e.get('d') == '2' for e in of('dblclick')), 'double click reached as dblclick detail 2')
check(bool(of('contextmenu')), 'right click reached as contextmenu')
check(bool(of('aux')), 'middle click reached as auxclick')
out = of('dragout')
check(bool(out) and int(out[0]['x']) < 0, 'a drag that leaves the body keeps going to the page (clientX < 0 — gesture owner)')
check(any(int(e.get('sel', '0')) > 0 and int(e['x']) < 0 for e in of('up')), 'the drag selected text and was released outside the body')
if len(clicks) >= 2:
    # 본문 안에서 끄는 중 오른쪽을 눌렀다 떼도 왼쪽 뗌은 왼쪽 뗌으로 간다 — 두 번째 버튼이 주인을 덮으면 왼쪽 뗌이 오른쪽 뗌으로
    # 나가 이 뗌(본문 위쪽, clientX > 0)이 오지 않는다(적대 검증). 우클릭은 Chromium 이 capture 를 끝내므로(실측) 본문 안에서 잰다.
    check(any(int(e.get('sel', '0')) > 0 and int(e['x']) > 0 and int(e['y']) < y0 - 100 for e in of('up')), 'a right press mid-drag does not steal the left release')
# 본문 위에 멈춘 채 키보드로 오버레이를 열면(포인터 이동 없음) tick 이 leave 를 보낸다 — 페이지의 :hover 가 오버레이 뒤에
# 열린 채 남지 않게(적대 검증).
scroll_at = max((i for i, n in enumerate(names) if n == 'scroll'), default=None)
check(scroll_at is not None and 'leave' in names[scroll_at:], 'opening an overlay while hovering the body sends leave without a pointer move')
sc = of('scroll')
# 마우스 휠 다섯 줄 = 한 줄 40 px(Chromium 과 같은 값) × 5 = 200 px. 줄을 픽셀로 안 바꾸면 5 px 에 그친다.
check(bool(sc) and int(sc[-1]['y']) >= 100, f'five wheel lines scrolled the page by line height ({sc[-1]["y"] if sc else "none"} px)')
sys.exit(0 if ok else 1)
PY

# 뒤로 버튼: /nav-a 의 링크를 눌러 /nav-b 로 간 뒤, 본문 위의 뒤로 버튼(buttonNumber 3)이 /nav-a 로 돌려보낸다. 링크를
# **눌러서** 간다 — 페이지가 스스로(사용자 동작 없이) 만든 기록은 Chromium 이 뒤로 가기에서 건너뛴다(실측).
cat > "$root/back.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.5 0.5 0 0 0
mouse 3 0.5 0.5 0 0 0
sleep 2500
aux 0.5 0.5 0 0 3
sleep 2500
SCRIPT
: > "$root/requests.log"
run_app /nav-a 16000 "$root/back.summary" MARU_WEB_OSR_TEST_INPUT="$root/back.txt"
shown_a=$(grep -c 'e=shown-a' "$root/requests.log" || true)
went_b=$(grep -c '^/nav-b' "$root/requests.log" || true)
echo "back button: /nav-b loaded $went_b · /nav-a shown $shown_a times"
[ "$went_b" -ge 1 ] && [ "$shown_a" -ge 2 ] || fail "the back mouse button did not take the tab back"
# ── W4c: 키보드 ─────────────────────────────────────────────────────────────────────────────────────────────
# 대본의 `type`·`compose` 는 입력기 콜백(insertText·setMarkedText)을 같은 트랜잭션 안에서 직접 부른다 — 사용자의 입력
# 소스(한글·영문)에 따라 합성 키의 결과가 갈리지 않게. `key` 는 NSEvent 를 view 의 performKeyEquivalent·메뉴·keyDown 에
# AppKit 순서대로 넣는다. 복사·붙여넣기는 시스템 클립보드를 덮으므로 재지 않는다.
cat > "$root/keys.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.5 0.5 0 0 0
mouse 3 0.5 0.5 0 0 0
sleep 500
ime 0 i:U+61
ime 11 i:U+62
key 36 U+D
ime 8 i:U+63
sleep 300
key 51 U+7F
sleep 300
ime 2 m:U+3147
ime 0 m:U+C544
ime 45 m:U+C548
ime 49 k:U+20 i:U+C548
sleep 300
key 14 U+5 U+65 16
sleep 300
key 0 U+61 U+61 32
key 51 U+7F
sleep 300
key 6 U+7A U+7A 32
sleep 500
key 119 U+F72B
sleep 300
ime 4 m:U+314E
ime 0 m:U+D558
ime 49 k:U+20 i:U+D558 i:U+20
ime 2 m:U+3137
ime 36 k:U+D i:U+3137 c:insertNewline:
ime 38 m:U+6F22
ime 36 k:U+D i:U+6F22
ime 45 m:U+3134
ime 51 k:U+7F i:U+3134 d
ime 40 m:U+314B
ime 53 k:U+1B m:- c:cancelOperation:
ime 0 k:U+61 i:U+61 m:U+3131
ime 49 k:U+20 i:U+3131 i:U+20
sleep 300
ime 4 m:U+D55C
sleep 300
imeout u i:U+97D3
sleep 500
ime 4 m:U+314E
sleep 300
action toggle_command_palette
sleep 500
key 53 U+1B
sleep 800
key 15 U+72 U+72 32
sleep 2500
SCRIPT
: > "$root/requests.log"
run_app /keys-app 30000 "$root/keys.summary" MARU_WEB_OSR_TEST_INPUT="$root/keys.txt"
python3 - "$root/requests.log" <<'PY' || fail "keyboard input did not reach the page as expected"
import sys, urllib.parse
evs, loads = [], 0
for line in open(sys.argv[1]):
    line = line.strip()
    if line == '/keys-app': loads += 1
    if not line.startswith('/ev?'): continue
    evs.append(dict(urllib.parse.parse_qsl(line[4:], keep_blank_values=True)))
names = [e.get('e') for e in evs]
vals = [e['v'] for e in evs if e.get('e') == 'val']
kd = [e['k'] for e in evs if e.get('e') == 'kd']
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check('ready' in names and 'focus' in names, 'clicking the page gives the textarea focus (the tab got key focus before the click)')
check(kd[:2] == ['a', 'b'] and 'ab' in vals, f'typed letters arrive as keydown then text ({kd[:2]}, values {vals[:3]})')
check('Enter' in kd and 'ab\n' in vals, 'Enter is a keydown and inserts a newline (keypress)')
check('ab\nc' in vals and vals.index('ab\nc') < len(vals) - 1 and 'ab\n' in vals[vals.index('ab\nc') + 1:], 'Backspace deletes with a keydown only')
comp = [e for e in evs if e.get('e') == 'val' and e.get('comp') == '1']
check(any(v['v'] == 'ab\n안' for v in comp), 'Hangul composition shows as composing text (ㅇ → 아 → 안)')
check(any(e.get('e') == 'cend' and e.get('d') == '안' for e in evs), 'committing ends the composition with 안')
# keydown 순서 전체: 입력기가 가져간 키(조합 자모·조합을 취소한 Backspace·Esc)는 keydown 이 없다(적대 검증 — 처음 판정은
# 비ASCII 한 글자만 걸러 Unidentified 로 새어 나간 keydown 을 놓쳤다). ⌘ 편집·탐색·앱 단축키는 키가 아니라 명령이다.
expected_kd = ['a', 'b', 'Enter', 'c', 'Backspace', 'e', 'Backspace', 'End', ' ', 'Enter', ' ']
check(kd == expected_kd, f'the page sees exactly the keydowns of keys that acted ({kd})')
check(any(e.get('e') == 'kd' and e.get('k') == 'e' and e.get('c') == '1' for e in evs), 'Ctrl+E reaches the page as key e with ctrlKey')
i_empty = vals.index('') if '' in vals else -1
check(i_empty >= 0, '⌘A then Backspace empties the textarea (select all is the page edit command)')
check(i_empty >= 0 and any('안' in v for v in vals[i_empty + 1:]), '⌘Z undoes it (undo is the page edit command)')
check(any(e.get('e') == 'cend' and e.get('d') == 'ㅎ' for e in evs), 'opening an overlay mid-composition finishes the composition (ㅎ)')
# 후보창에서 마우스로 고르기: 조합(한) 중 트랜잭션 밖에서 unmarkText 뒤 insertText(韓) — 고른 글이 조합을 대신한다(한韓 이 아니다 —
# main 기준 리베이스 적대 검증: main 의 unmarkText 「keyDown 밖이면 즉시 확정」이 Chromium 탭에서 확정을 두 번 보냈다).
check(any(v.endswith('韓') for v in vals) and not any('한韓' in v for v in vals), f'picking a candidate after unmarkText replaces the composition ({[v[-3:] for v in vals if "韓" in v][:3]})')
blur_at = max((i for i, n in enumerate(names) if n == 'blur'), default=-1)
check(blur_at >= 0 and 'focus' in names[blur_at + 1:], 'the page loses focus under the overlay and gets it back when it closes')
check(loads >= 2, f'⌘R reloads the tab (page loads {loads})')
done = [e['v'] for e in evs if e.get('e') == 'val' and e.get('comp') == '0']
# 조합을 끝낸 키도 그 동작을 한다(적대 검증 — 처음엔 조합만 확정되고 키가 사라졌다).
check(any(v.endswith('안하 ') for v in done), 'Korean Space commits 하 and types the space')
check('ab\n안하 ㄷ\n' in done, 'Korean Enter commits ㄷ and inserts the newline')
# 조합이 끝날 때 Chrome 은 마지막 input 을 isComposing=true 로 낸다 — 확정·취소는 compositionend 와 그 뒤 값으로 본다.
allv = [e['v'] for e in evs if e.get('e') == 'val']
def after(v):  # v 다음에 온 값
    return allv[allv.index(v) + 1] if v in allv and allv.index(v) + 1 < len(allv) else None
check(any(e.get('e') == 'cend' and e.get('d') == '漢' for e in evs) and not any(v.endswith('漢\n') for v in allv), 'a commit-only Enter (the input method swallowed the key) commits 漢 and adds no newline')
base = 'ab\n안하 ㄷ\n漢'
check(after(base + 'ㄴ') == base and not any('ㄴ' in v for v in done), 'Backspace on the last jamo cancels the composition instead of committing it')
check(after(base + 'ㅋ') == base and not any('ㅋ' in v for v in done), 'Esc cancels the composition')
# 조합 없는 트랜잭션에서 확정(a) 뒤 새 조합(ㄱ)이 서도 a 는 남는다(적대 검증 — 쌓인 글이 조합에 덮여 사라졌다).
check(any(v.endswith('漢aㄱ ') for v in allv), 'text typed right before a new composition in the same key survives (a then ㄱ)')
sys.exit(0 if ok else 1)
PY

# ── W6a②: 팝업 위젯(`<select>` 목록)을 그린다 ───────────────────────────────────────────────────────────────
# 빨간 select 를 눌러 목록을 연 뒤 찍는다 — 목록은 select 바로 아래에 열린다(view DIP — 앱 안 실측). 그 띠가 초록 바탕이 아니라
# 항목 글자(어두운 픽셀)가 있으면 그려진 것이다(W6a① 까지는 목록이 보이지 않는 채 열려 띠가 초록이었다). Esc 로 닫으면 다시
# 초록이다. 목록 바탕은 select 배경색이라 select 자리는 닫힌 장에서 잰다.
# 스크린샷 하니스는 찍은 뒤 앱을 끝내므로 두 번 띄운다.
cat > "$root/popup.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
SCRIPT
cat > "$root/popup-esc.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1000
key 53 U+1B
SCRIPT
: > "$root/requests.log"
run_app /sel 30000 "$root/popup.summary" MARU_WEB_OSR_TEST_INPUT="$root/popup.txt" MARU_SCREENSHOT="$root/popup.ppm" MARU_SCREENSHOT_DELAY_MS=9000
grep -q 'e=focus&id=a' "$root/requests.log" || fail "the click did not reach the select"
: > "$root/requests.log"
run_app /sel 30000 "$root/popup-esc.summary" MARU_WEB_OSR_TEST_INPUT="$root/popup-esc.txt" MARU_SCREENSHOT="$root/popup-esc.ppm" MARU_SCREENSHOT_DELAY_MS=10000
grep -q 'e=focus&id=a' "$root/requests.log" || fail "the click did not reach the select (Esc run)"
python3 - "$root/popup.ppm" "$root/popup-esc.ppm" <<'PY' || fail "the opened <select> list was not drawn (or stayed after Esc)"
import sys
def load(path):
    d = open(path, 'rb').read()
    _, dims, _, px = d.split(b'\n', 3)
    w, h = map(int, dims.split())
    return w, h, px
def red_box(img):
    w, h, px = img
    red = bytes.fromhex('ff0000')
    xs, ys = [], []
    for y in range(0, h, 2):
        row = px[y * w * 3:(y + 1) * w * 3]
        i = row.find(red)
        while i != -1:
            if i % 3 == 0: xs.append(i // 3); ys.append(y)
            i = row.find(red, i + 3)
    return (min(xs) + 4, max(xs) - 4, max(ys), min(ys)) if xs else None
def band(img, box):
    w, h, px = img
    x0, x1, y1, top = box
    green = dark = total = 0
    # 띠 높이는 select 높이의 1/4 — 목록(항목 다섯)보다 짧아야 목록 아래 초록이 섞이지 않는다(배율·창 크기에 따라).
    for y in range(y1 + 6, min(h, y1 + 6 + max(4, (y1 - top) // 4))):
        for x in range(x0, x1):
            r, g, b = px[(y * w + x) * 3:(y * w + x) * 3 + 3]
            total += 1
            if (r, g, b) == (0x20, 0xa0, 0x60): green += 1
            # 글자만 센다 — 목록 바탕은 select 배경색(빨강)이라 밝기 식으로는 바탕도 「어둡다」로 셌다(W6a② 적대 검증 3 차).
            if max(r, g, b) < 0x60: dark += 1
    return green / total, dark
opened, closed = load(sys.argv[1]), load(sys.argv[2])
# select 자리는 닫힌 장의 빨간 영역이다 — 목록은 select 배경색(빨강)으로 칠해져 열린 장에서는 빨간 영역이 목록까지 늘어난다.
box = red_box(closed)
if box is None: print('FAIL no red select in the closed screenshot'); sys.exit(1)
(og, od), (cg, cd) = band(opened, box), band(closed, box)
print(f'below the select — opened: green {og:.2f} dark px {od} · after Esc: green {cg:.2f} dark px {cd}')
ok = og < 0.2 and od > 20 and cg > 0.95
print(('PASS ' if ok else 'FAIL ') + 'the opened <select> list is drawn under the select and gone after Esc')
sys.exit(0 if ok else 1)
PY
# 열린 목록의 키(W6a②): 「c」 → Enter 로 cherry 가 골라진다 — 키 대상 탭에 팝업이 열려 있으면 Swift 는 입력기를 거치지 않고
# 누름·글자를 보낸다(osr_key phase 3). 대본은 글자 「c」를 직접 실은 NSEvent 를 넣는다 — 그래서 이 판정은 phase 3 이 목록의
# 글자 찾기까지 닿는지를 본다. 입력기 우회 자체는 가르지 못한다 — 셸에서 띄운 앱은 맨 앞이 아니라 한글 입력 소스여도 macOS
# 입력기가 조합하지 않는다(W4d② 실측 — 2벌식에서 우회를 끈 변이도 통과했다). 진짜 입력기에서의 우회·키 이벤트 글자가 자모로
# 오는지는 자리 비움 모드(`web-osr-tester-live`) 몫이다.
cat > "$root/popup-type.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1000
key 8 U+63
sleep 500
key 36 U+D
sleep 1500
SCRIPT
: > "$root/requests.log"
run_app /sel 14000 "$root/popup-type.summary" MARU_WEB_OSR_TEST_INPUT="$root/popup-type.txt"
grep -q 'e=change&v=cherry' "$root/requests.log" || fail "typing c then Enter in the open <select> list did not pick cherry ($(grep '^/ev' "$root/requests.log" | tr '\n' ' '))"
echo "PASS typing in the open <select> list picks the item (c → cherry)"

# ── W6b: 페이지 툴팁 ─────────────────────────────────────────────────────────────────────────────────────────
# 셸에서 띄운 앱은 맨 앞이 아니라 macOS 가 툴팁을 실제로 띄우지 않는다(비활성 앱 — W6b 착수 전 실측). 그래서 maru 가 view 에
# macOS 툴팁을 **맞는 글로 달았는지**를 본다(대본 `tooltip` — 앱 로그의 `osr-test tooltip` 줄). title 있는 곳에 올리면 달리고(여러
# 줄), 빈 곳으로 가면 떼고, 다시 올리면 다시 달리고, 누르면(view 마우스 메서드 — macOS 가 숨긴다) 떼었다가 다음 움직임에 다시 달고
# (Chrome 은 누른 뒤 같은 요소에서 움직이면 다시 띄운다 — 실측), 포인터를 멈춘 채 분할하면 영역이 줄어든 본문으로 옮겨 가고,
# 팔레트가 열리면(탭을 떠난 것으로 — leave) 뗀다. 영역은 view 전체가 아니라 포인터가 있는 탭 본문이다(적대 검증 3 차 — view 전체면
# 멈춘 채 배치가 바뀔 때 옛 글이 터미널 위에 떴다).
cat > "$root/tip.txt" <<'SCRIPT'
sleep 7000
hover 0.40 0.33 0 0
sleep 300
hover 0.41 0.33 0 0
sleep 300
hover 0.42 0.34 0 0
sleep 1000
tooltip
hover 0.85 0.85 0 0
sleep 1000
tooltip
hover 0.40 0.33 0 0
sleep 300
hover 0.41 0.34 0 0
sleep 1000
tooltip
view down 0.41 0.34 0 0
view up 0.41 0.34 0 0
sleep 300
tooltip
view move 0.42 0.35 0 0
sleep 300
tooltip
action split_vertical
sleep 1000
tooltip
action toggle_command_palette
sleep 1000
tooltip
key 53 U+1B
sleep 500
SCRIPT
: > "$root/requests.log"
run_app /tip-app 17000 "$root/tip.summary" MARU_WEB_OSR_TEST_INPUT="$root/tip.txt"
grep -a '^osr-test tooltip' "$root/app-tip-app.log" > "$root/tip.report" || true
cat "$root/tip.report"
python3 - "$root/tip.report" <<'PY' || fail "the page tooltip was not attached to the view as expected"
import sys
lines = [l.strip() for l in open(sys.argv[1])]
on, off = 'osr-test tooltip active=true text=A tip\\nline2 area=', 'osr-test tooltip active=false text= area=-'
want = [on, off, on, off, on, on, off]
shape = len(lines) == len(want) and all(l.startswith(w) if w == on else l == w for l, w in zip(lines, want))
areas = [tuple(float(v) for v in l[len(on):].split(',')) for l in lines if l.startswith(on)] if shape else []
def holds(a, x, y): return a[0] <= x <= a[0] + a[2] and a[1] <= y <= a[1] + a[3]
# 처음 셋은 같은 본문(title 자리 0.42·0.34 와 같은 본문의 빈 자리 0.85·0.85 를 품고 view 전체가 아니다 — 위아래를 뒤집어
# 풀면 빈 자리가 빠진다), 분할 뒤는 포인터(0.42·0.35)를 품은 더 작은 본문으로 옮겼다.
body = shape and areas[0] == areas[1] == areas[2] and holds(areas[0], 0.42, 0.34) and holds(areas[0], 0.85, 0.85) and areas[0] != (0.0, 0.0, 1.0, 1.0)
moved = body and areas[3] != areas[0] and areas[3][2] * areas[3][3] < areas[0][2] * areas[0][3] and holds(areas[3], 0.42, 0.35)
ok = shape and body and moved
print(('PASS ' if ok else 'FAIL ') + f'tooltip attached to the hovered web body (not the whole view) over the titled element (multi-line), detached outside, reattached, detached by a click and reattached on the next move (Chrome re-shows), moved to the smaller body after a split with the pointer still, detached when the palette opens (shape {shape} body {body} moved {moved} {lines})')
sys.exit(0 if ok else 1)
PY

# ── W6c②: 우클릭 메뉴 ──────────────────────────────────────────────────────────────────────────────────────
# 셸에서 띄운 앱은 맨 앞이 아니라 macOS 메뉴를 띄울 수 없다 — 판정 모드(`MARU_WEB_OSR_TEST_CONTEXT_MENU`)는 띄우는 대신 항목을
# 보고하고(`osr-test menu shown items=…`) 대본의 `menupick 문구`·`menuclose` 로 끝맺는다. 그 뒤(답·hover 다시 맞추기·누른 채
# 뜬 메뉴의 오른쪽 떼기)는 진짜 경로다. 문구는 한국어(`ui.language = ko` — Chrome 154 메뉴 문구)로 본다. 클립보드를 쓰는 항목은
# 고르지 않는다(사용자 클립보드). 끝 무렵 창을 하나 더 띄워(`newwindow`) 다른 창의 tick 이 메뉴를 거두지 않는지 본다.
printf 'ui.language = ko\n' > "$root/menu.conf"
cat > "$root/menu.txt" <<'SCRIPT'
sleep 7000
view down 0.79 0.30 0 0 1
view up 0.79 0.30 0 0 1
sleep 900
menupick 새로고침
sleep 1500
mark reloaded
view down 0.395 0.30 0 0 1
view up 0.395 0.30 0 0 1
sleep 900
menuclose
sleep 300
view down 0.55 0.588 0 0
view up 0.55 0.588 0 0
sleep 300
view down 0.55 0.588 0 0 1
view up 0.55 0.588 0 0 1
sleep 900
menupick 모두 선택
sleep 300
key 6 U+7A
sleep 600
mark typed
view down 0.655 0.49 0 0
view up 0.655 0.49 0 0
view down 0.655 0.49 0 0 0 2
view up 0.655 0.49 0 0 0 2
sleep 300
view down 0.655 0.49 0 0 1
view up 0.655 0.49 0 0 1
sleep 900
menuclose
sleep 300
mark held
view down 0.79 0.30 0 0 1
sleep 900
menuclose
sleep 400
view move 0.39 0.29 0 0
sleep 300
view move 0.40 0.30 0 0
sleep 600
cursor
mark hovered
view up 0.79 0.30 0 0 1
sleep 300
newwindow
sleep 1500
firstwindow
mark secondwindow
view down 0.79 0.30 0 0 1
view up 0.79 0.30 0 0 1
sleep 900
ctxmenu
menupick 새로고침
sleep 1500
mark twowindows
view down 0.79 0.797 0 0 1
view up 0.79 0.797 0 0 1
sleep 2000
ctxmenu
SCRIPT
: > "$root/requests.log"
run_app /cm-app 31000 "$root/menu.summary" MARU_WEB_OSR_TEST_INPUT="$root/menu.txt" MARU_WEB_OSR_TEST_CONTEXT_MENU=1 MARU_CONFIG="$root/menu.conf"
grep -a '^osr-test menu\|^osr-test cursor\|^osr-test mark' "$root/app-cm-app.log" > "$root/menu.report" || true
cat "$root/menu.report"
python3 - "$root/menu.report" "$root/requests.log" <<'PY' || fail "the Chromium tab context menu did not behave as expected"
import sys, re
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
shown = [l[len('osr-test menu shown items='):] for l in report if l.startswith('osr-test menu shown items=')]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check(len(shown) == 7, f'seven menus were shown (blank, link, input, selection, held, blank with two windows, moving cell) — {len(shown)}')
check(len(shown) > 0 and shown[0] == '뒤로(off)|앞으로(off)|새로고침', f'the blank-page menu is back(off) · forward(off) · reload in Chrome words ({shown[0] if shown else None})')
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
def t_of(line):
    m = re.search(r'[?&]t=(\d+)', line)
    return int(m.group(1)) if m else 0
loads = [l for l in requests if l.startswith('/ev?e=load') and t_of(l) < marks.get('reloaded', 0)]
check(len(loads) == 2, f'picking reload loaded the page again (loads before the mark: {len(loads)})')
check(len(shown) > 1 and shown[1] == '새 탭에서 링크 열기|—|링크 주소 복사', f'the link menu (no text under the pointer) is open link in new tab — copy link address ({shown[1] if len(shown) > 1 else None})')
edit = re.compile(r'^그림 이모티콘 & 기호\|—\|실행 취소\(off\)\|다시 실행\(off\)\|—\|잘라내기\(off\)\|복사\(off\)\|붙여넣기(\(off\))?\|붙여넣고 스타일 일치시킴(\(off\))?\|모두 선택$')
check(len(shown) > 2 and bool(edit.match(shown[2])), f'the input menu is emoji — undo · redo — cut · copy · paste · paste and match style · select all ({shown[2] if len(shown) > 2 else None})')
selection = "'\u2068hello\u2069' 찾기|—|복사|—|음성▸[말하기 시작|말하기 중지(off)]|—|서비스▸[]"
check(len(shown) > 3 and shown[3] == selection, f"a selected word is look up — copy — speech ▸ — services ▸ ({shown[3] if len(shown) > 3 else None})")
check(any(l.startswith('/ev?e=input&v=z') for l in requests), f'select all from the menu, then z, replaced the field ({[l for l in requests if l.startswith("/ev?e=input")]})')
cursor = [l for l in report if l.startswith('osr-test cursor')]
check(len(cursor) == 1 and cursor[0] == 'osr-test cursor hand', f'after a menu that ate the right-button release, hover works again — the link shows the hand cursor ({cursor})')
held_ups = [l for l in requests if l.startswith('/ev?e=up&b=2') and marks.get('held', 0) < t_of(l) < marks.get('hovered', 0)]
check(len(held_ups) == 1, f'the release the held menu ate reached the page once, before the real release (sent by maru) — {len(held_ups)}')
# 다시 불러오기만 센다(새 창이 같은 시험 페이지를 처음 불러오는 것은 navigate — 시각으로 가르면 그것이 늦게 오면 흔들렸다).
two = [l for l in requests if l.startswith('/ev?e=load&nt=reload') and marks.get('secondwindow', 0) < t_of(l) < marks.get('twowindows', 0)]
check('osr-test menu items=뒤로(off)|앞으로(off)|새로고침' in report and len(two) == 1,
      f'with a second window open, the menu stays open for its own window and its pick runs (another window tick must not close it) — reloads {len(two)}')
check(report.count('osr-test menu closed-by-page') == 1 and report[-1] == 'osr-test menu none', f'only the menu open while the page navigates is closed, and nothing stays open ({report[-2:]})')
sys.exit(0 if ok else 1)
PY

# ── W6d①: 밖에서 끌어 놓기 ─────────────────────────────────────────────────────────────────────────────────
# (첫 끌기는 앱·sidecar 가 뜬 뒤 9 초 — 화면이 잠긴 때 7 초로는 페이지가 첫 끌기에 답하지 않은 적이 있다.)
# 진짜 끌기 세션은 사용자 포인터가 필요하다 — 대본 `drag` 이 터미널 view 의 끌기 메서드(draggingEntered·Updated·
# performDragOperation·Ended·Exited)를 가짜 끌기 정보(판정자 전용 이름의 pasteboard)로 부른다. 그 뒤(Swift → ABI → Zig →
# sidecar → 페이지)는 진짜 경로다. 돌려준 동작(`osr-test drag … op=`)과 페이지가 받은 것을 본다.
mkdir -p "$root/drop"
printf 'HELLO' > "$root/drop/a.txt"
cat > "$root/dnd.txt" <<SCRIPT
sleep 9000
drag enter 0.25 0.3 0 0 file $root/drop/a.txt
sleep 300
drag move 0.25 0.3 0 0
sleep 300
drag move 0.25 0.31 0 0
sleep 300
drag drop 0.25 0.31 0 0
sleep 800
mark filed
drag enter 0.75 0.2 0 0 text dropped words
sleep 300
drag move 0.75 0.2 0 0
sleep 300
drag move 0.75 0.21 0 0
sleep 300
drag drop 0.75 0.21 0 0
sleep 800
mark texted
drag enter 0.75 0.8 0 0 text moved words
sleep 300
drag move 0.75 0.8 0 0
sleep 300
drag move 0.75 0.81 0 0
sleep 300
drag drop 0.75 0.81 0 0
sleep 800
drag enter 0.25 0.85 0 0 text refused words
sleep 300
drag move 0.25 0.85 0 0
sleep 300
drag move 0.25 0.86 0 0
sleep 300
drag drop 0.25 0.86 0 0
sleep 800
mark effects
action toggle_command_palette
sleep 300
drag enter 0.25 0.3 0 0 file $root/drop/a.txt
sleep 300
drag move 0.25 0.3 0 0
sleep 300
drag drop 0.25 0.3 0 0
sleep 600
key 53 U+1B
sleep 300
mark gated
drag enter 0.25 0.3 0 0 url file://$root/drop/a.txt
sleep 300
drag move 0.25 0.3 0 0
sleep 300
drag move 0.25 0.31 0 0
sleep 300
drag drop 0.25 0.31 0 0
sleep 800
mark urlfile
drag enter 0.25 0.3 0 0 file $root/drop/a.txt
sleep 300
drag move 0.25 0.3 0 0
sleep 300
drag exit 0 0 0 0
sleep 600
mark exited
SCRIPT
: > "$root/requests.log"
run_app /dnd-app 32000 "$root/dnd.summary" MARU_WEB_OSR_TEST_INPUT="$root/dnd.txt"
grep -a '^osr-test drag\|^osr-test mark' "$root/app-dnd-app.log" > "$root/dnd.report" || true
cat "$root/dnd.report"
python3 - "$root/dnd.report" "$root/requests.log" <<'PY' || fail "dropping onto the Chromium tab did not behave as expected"
import sys, re, urllib.parse
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
def t_of(line):
    m = re.search(r'[?&]t=(\d+)', line)
    return int(m.group(1)) if m else 0
drags = [l for l in report if l.startswith('osr-test drag ')]
first = drags[:4]
check(first == ['osr-test drag enter op=0', 'osr-test drag move op=1', 'osr-test drag move op=1', 'osr-test drag drop op=1 ok=true'],
      f'over the drop zone the view answers the page operation (none until the page answers, then copy) and the drop is taken ({first})')
overs = [l.split('&t=')[0] for l in requests if l.startswith('/ev?e=over') and t_of(l) < marks.get('filed', 0)]
check(overs == ['/ev?e=over&f=0'], f'while dragging the page sees no files ({overs})')
dropped = [urllib.parse.unquote(l) for l in requests if l.startswith('/ev?e=drop') and t_of(l) < marks.get('filed', 0)]
content = [urllib.parse.unquote(l) for l in requests if l.startswith('/ev?e=content') and t_of(l) < marks.get('filed', 0)]
check(len(dropped) == 1 and 'names=a.txt:5' in dropped[0] and len(content) == 1 and 'v=HELLO' in content[0],
      f'after the drop the page reads the file name, size and content ({dropped} {content})')
typed = [urllib.parse.unquote(l) for l in requests if l.startswith('/ev?e=input') and marks.get('filed', 0) < t_of(l) < marks.get('texted', 0)]
check(drags[7:8] == ['osr-test drag drop op=1 ok=true'] and len(typed) == 1 and 'v=dropped words' in typed[0],
      f'text dropped on the text field goes in ({drags[4:8]} {typed})')
# 양성 대조 — 터미널 경로의 copy(1)와 다른 값을 페이지가 정한다: 이동 칸은 이동(16), 거절 칸은 0(놓기를 부르지 않는다).
# 두 칸 모두 dragenter 는 기본값(복사)으로 받고 dragover 에서 바꾸므로 첫 움직임의 답은 복사(1)다 — 페이지가 답한 그대로.
moved = [urllib.parse.unquote(l) for l in requests if l.startswith('/ev?e=mdrop') and marks.get('texted', 0) < t_of(l) < marks.get('effects', 0)]
check(drags[8:12] == ['osr-test drag enter op=0', 'osr-test drag move op=1', 'osr-test drag move op=16', 'osr-test drag drop op=16 ok=true'] and len(moved) == 1 and 'v=moved words' in moved[0],
      f'the page picks move on the move cell and the view answers it ({drags[8:12]} {moved})')
refused = [l for l in requests if l.startswith('/ev?e=ndrop')]
check(drags[12:16] == ['osr-test drag enter op=0', 'osr-test drag move op=1', 'osr-test drag move op=0', 'osr-test drag drop skipped op=0'] and not refused,
      f'the page refuses on the refusing cell — the view answers none and nothing is dropped ({drags[12:16]} {refused})')
gated_page = [l for l in requests if (l.startswith('/ev?e=drop') or l.startswith('/ev?e=over')) and marks.get('effects', 0) < t_of(l) < marks.get('gated', 0)]
check(drags[16:19] == ['osr-test drag enter op=1', 'osr-test drag move op=1', 'osr-test drag drop op=1 ok=false'] and not gated_page,
      f'with the command palette open the web body is not a drop target — the terminal drop path refuses it ({drags[16:19]} page {gated_page})')
# 주소 형식으로만 온 `file://`(다른 앱의 웹 페이지가 끌기에 넣을 수 있다)는 파일이 아니다 — 사용자가 고른 파일이 아니다.
url_drops = [urllib.parse.unquote(l) for l in requests if l.startswith('/ev?e=drop') and marks.get('gated', 0) < t_of(l) < marks.get('urlfile', 0)]
url_overs = [l for l in requests if l.startswith('/ev?e=over') and marks.get('gated', 0) < t_of(l) < marks.get('urlfile', 0)]
check(len(url_overs) == 1 and not any('a.txt' in d for d in url_drops), f'a file:// address dragged as a URL is not handed to the page as a file (the drag reached the page {url_overs}, drops {url_drops})')
left = [l for l in requests if l.startswith('/ev?e=leave') and marks.get('urlfile', 0) < t_of(l) < marks.get('exited', 0)]
after = [l for l in requests if l.startswith('/ev?e=drop') and t_of(l) > marks.get('urlfile', 0)]
check(len(left) == 1 and not after and drags[-1] == 'osr-test drag exit', f'a drag that leaves the view leaves the page and drops nothing ({left} {after} {drags[-1:]})')
sys.exit(0 if ok else 1)
PY

# ── W6d②: 페이지에서 끌어내기 ─────────────────────────────────────────────────────────────────────────────
# 셸에서 띄운 앱은 맨 앞이 아니라 macOS 끌기 세션을 쓸 수 없다 — 판정 모드(`MARU_WEB_OSR_TEST_DRAG_OUT`)는 세션 대신 끌기
# pasteboard·그림을 보고하고(`osr-test dragout start …`), 대본 `dragout move|drop|cancel` 이 그 pasteboard 를 가짜 끌기 정보로
# view 의 끌기 메서드에 넘긴 뒤(소스는 그 view) 소스의 끝을 부른다. 그 앞(페이지 → sidecar → 창이 가져감 → 제스처를 조용히 끝냄)과
# 뒤(maru 안 놓기의 source → sidecar → 페이지, 끝 → dragend)는 진짜 경로다.
cat > "$root/dragout.txt" <<SCRIPT
sleep 9000
view down 0.25 0.65 0 0
sleep 80
view drag 0.25 0.66 0 0
sleep 40
view drag 0.25 0.67 0 0
sleep 40
view drag 0.25 0.68 0 0
sleep 40
view drag 0.25 0.69 0 0
sleep 900
mark started
view up 0.25 0.69 0 0
sleep 300
dragout move 0.75 0.8 0 0
sleep 300
dragout move 0.75 0.81 0 0
sleep 300
dragout move 0.75 0.82 0 0
sleep 300
dragout drop 0.75 0.82 0 0
sleep 900
mark moved
view down 0.25 0.65 0 0
sleep 80
view drag 0.25 0.66 0 0
sleep 40
view drag 0.25 0.67 0 0
sleep 40
view drag 0.25 0.68 0 0
sleep 40
view drag 0.25 0.69 0 0
sleep 900
dragout cancel
sleep 900
mark cancelled
SCRIPT
: > "$root/requests.log"
run_app /dnd-app 24000 "$root/dragout.summary" MARU_WEB_OSR_TEST_INPUT="$root/dragout.txt" MARU_WEB_OSR_TEST_DRAG_OUT=1
grep -a '^osr-test dragout\|^osr-test mark' "$root/app-dnd-app.log" > "$root/dragout.report" || true
cat "$root/dragout.report"
python3 - "$root/dragout.report" "$root/requests.log" <<'PY' || fail "dragging out of the Chromium tab did not behave as expected"
import sys, re, urllib.parse
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
def t_of(line):
    m = re.search(r'[?&]t=(\d+)', line)
    return int(m.group(1)) if m else 0
def ev(prefix, a, b):
    return [urllib.parse.unquote(l.split('&t=')[0]) for l in requests if l.startswith(prefix) and marks.get(a, 0) < t_of(l) < marks.get(b, 1 << 62)]
starts = [l for l in report if l.startswith('osr-test dragout start')]
first = starts[0] if starts else ''
m = re.search(r'image=(\d+)x(\d+) png=(\d+)x(\d+)', first)
check(len(starts) == 2 and 'allowed=17' in first and 'org.maru.osr-drag' in first and 'public.utf8-plain-text' in first and 'text=smoke-drag' in first
      and m is not None and int(m.group(1)) > 0 and int(m.group(3)) > 0,
      f'pressing and dragging the draggable element starts a drag the window takes — the page text, its drag image and the maru mark ({starts})')
drags = [l for l in report if l.startswith('osr-test dragout ') and not l.startswith('osr-test dragout start')]
# 첫 움직임은 페이지가 아직 답하지 않아 0, 그 뒤는 페이지의 답(이동) — 끌기 허용이 복사·이동이라 dragenter 의 기본값도 이동이다.
check(len(drags) >= 4 and drags[0] == 'osr-test dragout move op=0' and drags[2] == 'osr-test dragout move op=16' and drags[3] == 'osr-test dragout drop op=16 done=16',
      f'over the move cell inside maru the page answers move and the drop is taken ({drags[:4]})')
moved = ev('/ev?e=mdrop', 'started', 'moved')
check(moved == ['/ev?e=mdrop&v=smoke-drag&x=smoke-secret'], f'the cell got the page text and its custom type — maru used the source drag data, not the pasteboard ({moved})')
ends = ev('/ev?e=dend', 'started', 'moved')
check(ends == ['/ev?e=dend&v=move'], f'the source element saw dragend with move ({ends})')
# 세션이 열리면 제스처가 끝나 그 뒤 떼기는 페이지로 가지 않는다(대본이 세션 뒤 떼기를 보낸다 — macOS 세션은 떼기를 먹는다).
check(ev('/ev?e=up', '', 'moved') == [], f'after the drag session starts, a release does not reach the page as mouseup ({ev("/ev?e=up", "", "moved")})')
cancelled = ev('/ev?e=dend', 'moved', 'cancelled')
check(drags[4:5] == ['osr-test dragout cancel'] and cancelled == ['/ev?e=dend&v=none'], f'a cancelled drag ends with none ({drags[4:5]} {cancelled})')
sys.exit(0 if ok else 1)
PY

# ── W6d③: 이미지를 끌어내 파일로 ─────────────────────────────────────────────────────────────────────────────
# 판정 모드는 Finder 대신 대본 `dragout promise <폴더>` 로 파일 약속을 받는다 — 끌기를 끝낸 뒤(Finder 는 놓은 뒤 청한다) 대리자가 그
# 대기열에서 sidecar 에 내용을 청해(끌기 때는 이름·크기만 왔다) 그 폴더의 안전한 이름으로 쓴다. 같은 폴더에 두 번 받아 덮어쓰지 않는지,
# 쓴 파일이 서버가 준 바이트 그대로인지, 내려받은 파일 표지(quarantine)가 붙었는지 본다. 같은 이름이 있으면 Chrome 처럼 「cat 2.png」.
mkdir -p "$root/promise"
cat > "$root/dragimg.txt" <<SCRIPT
sleep 9000
view down 0.75 0.58 0 0
sleep 80
view drag 0.75 0.59 0 0
sleep 40
view drag 0.75 0.6 0 0
sleep 40
view drag 0.75 0.61 0 0
sleep 40
view drag 0.75 0.62 0 0
sleep 900
dragout finder
sleep 300
dragout promise $root/promise
sleep 1500
dragout promise $root/promise
sleep 1500
SCRIPT
: > "$root/requests.log"
run_app /dnd-app 18000 "$root/dragimg.summary" MARU_WEB_OSR_TEST_INPUT="$root/dragimg.txt" MARU_WEB_OSR_TEST_DRAG_OUT=1
grep -a '^osr-test dragout' "$root/app-dnd-app.log" > "$root/dragimg.report" || true
cat "$root/dragimg.report"
python3 - "$root/dragimg.report" "$root/promise" <<'PY' || fail "dragging an image out as a file did not behave as expected"
import sys, os, base64, subprocess
report = [l.strip() for l in open(sys.argv[1])]
folder = sys.argv[2]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
start = [l for l in report if l.startswith('osr-test dragout start')]
check(len(start) == 1 and 'file=cat.png bytes=122' in start[0], f'an image drag carries the file to make — its safe name and the served bytes ({start})')
wrote = [l for l in report if l.startswith('osr-test dragout promise')]
check(wrote == ['osr-test dragout promise wrote cat.png', 'osr-test dragout promise wrote cat 2.png'],
      f'the promise writes the file, and a second one with the same name becomes "cat 2.png" — nothing is overwritten ({wrote})')
path = os.path.join(folder, 'cat.png')
want = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAQUlEQVR4nO3OQQ0AMBAEofNvupWx8yBBAPfuUvYDISEhoZj9QEhISChmPxASEhKK2Q+EhISEYvYDISEhoZj9oB763xP3eV+LAIgAAAAASUVORK5CYII=")
got = open(path, 'rb').read() if os.path.exists(path) else b''
second = open(os.path.join(folder, 'cat 2.png'), 'rb').read() if os.path.exists(os.path.join(folder, 'cat 2.png')) else b''
check(got == want and second == want and sorted(os.listdir(folder)) == ['cat 2.png', 'cat.png'], f'the written files are the served image, byte for byte, and nothing else is in the folder ({len(got)} {len(second)} bytes, {os.listdir(folder)})')
q = subprocess.run(['xattr', '-p', 'com.apple.quarantine', path], capture_output=True, text=True)
# 표지 값은 「플래그;시각;앱;UUID」 — 셸에서 띄운(번들 아닌) 시험 앱은 앱 이름 칸을 macOS 가 비운다. 표지가 있는지만 본다.
check(q.returncode == 0 and len(q.stdout.strip().split(';')) >= 3, f'the file carries the download quarantine mark — its origin is recorded ({q.stdout.strip()!r})')
sys.exit(0 if ok else 1)
PY

# ── W6e: 페이지가 연 새 탭 ─────────────────────────────────────────────────────────────────────────────
# 가운데 클릭 두 번(뒤 탭 — 지금 탭 오른쪽에 차례대로, 포커스 그대로), 그다음 `target=_blank` 클릭(앞 탭 — 이어 연 탭들 뒤, 그 탭으로
# 옮긴다). 앱은 판정 모드에서 새 탭의 자리를 적고(`osr-test newtab`), 새 탭이 그 주소를 불렀는지는 시험 서버가 받은 요청으로 본다.
cat > "$root/newtab.txt" <<SCRIPT
sleep 9000
view down 0.6 0.3 0 0 2
sleep 60
view up 0.6 0.3 0 0 2
sleep 1500
view down 0.6 0.3 0 0 2
sleep 60
view up 0.6 0.3 0 0 2
sleep 1500
view down 0.6 0.8 0 0
sleep 60
view up 0.6 0.8 0 0
sleep 3000
SCRIPT
: > "$root/requests.log"
run_app /nt-app 20000 "$root/newtab.summary" MARU_WEB_OSR_TEST_INPUT="$root/newtab.txt"
grep -a '^osr-test newtab' "$root/app-nt-app.log" > "$root/newtab.report" || true
cat "$root/newtab.report"
python3 - "$root/newtab.report" "$root/requests.log" <<'PY' || fail "tabs a page opened did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
# 연 탭의 자리(o)·처음 탭 수(n)는 pane 에 무엇이 먼저 있었는지에 달렸다(터미널 탭 하나) — 그것에 맞춰 본다.
fields = [dict(kv.split('=') for kv in l.split()[2:]) for l in report]
o = int(fields[0]['opener']) if fields else -1
n = int(fields[0]['tabs']) - 1 if fields else -1
# 가운데 클릭은 주소로 연 탭, `target=_blank` 는 팝업 브라우저를 이어 받은 탭이다(W6f② — maru 가 번호를 맡겨 둔다).
want = [f'osr-test newtab at={o + 1} tabs={n + 1} opener={o} active={o} placement=background adopted=false',
        f'osr-test newtab at={o + 2} tabs={n + 2} opener={o} active={o} placement=background adopted=false',
        f'osr-test newtab at={o + 3} tabs={n + 3} opener={o} active={o + 3} placement=foreground adopted=true']
check(len(report) == 3 and report == want, f'two middle clicks open background tabs right of the page in order, then a target=_blank link opens a foreground tab after them ({report})')
long_b = '/nt-b?q=' + 'x' * 5000
check(requests.count(long_b) == 2 and requests.count('/nt-a') == 1, f'each new tab loads its address — the 5000-character one too ({[r[:20] + "…" + str(len(r)) for r in requests if r.startswith("/nt-")]})')
sys.exit(0 if ok else 1)
PY

# ── W6f②: 원래 페이지와 이어진 팝업 ─────────────────────────────────────────────────────────────────────────
# 누르면 `window.open` — sidecar 가 maru 가 맡긴 번호로 팝업 브라우저를 만들고 maru 가 그 번호의 탭을 원래 탭 오른쪽에 붙인다(앞 탭).
# 팝업은 `window.opener.postMessage` 로 알리고, 원래 페이지는 그것을 받은 뒤 `w.close()` — 그 탭이 닫힌다. 팝업 주소는 팝업 브라우저가
# 한 번만 부른다(maru 가 다시 옮기지 않는다).
cat > "$root/adopt.txt" <<SCRIPT
sleep 9000
view down 0.6 0.25 0 0 2
sleep 60
view up 0.6 0.25 0 0 2
sleep 1500
view down 0.6 0.8 0 0
sleep 60
view up 0.6 0.8 0 0
sleep 5000
SCRIPT
# 먼저 닫지 않는 판 — 붙인 팝업 탭을 찍는다(찍고 나면 앱이 끝난다).
rm -f "$root/adopt.ppm"
run_app /pop-stay 25000 "$root/adopt-stay.summary" MARU_WEB_OSR_TEST_INPUT="$root/adopt.txt" MARU_SCREENSHOT="$root/adopt.ppm" MARU_SCREENSHOT_DELAY_MS=15500
grep -a '^osr-test newtab' "$root/app-pop-stay.log" > "$root/adopt-stay.report" || true

: > "$root/requests.log"
run_app /pop-app 20000 "$root/adopt.summary" MARU_WEB_OSR_TEST_INPUT="$root/adopt.txt"
grep -a '^osr-test newtab' "$root/app-pop-app.log" > "$root/adopt.report" || true
cat "$root/adopt.report"
python3 - "$root/adopt.report" "$root/requests.log" "$root/adopt.ppm" "$root/adopt-stay.report" <<'PY' || fail "a popup the page opened did not stay connected to it"
import sys
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
opened = [l for l in report if l.startswith('osr-test newtab at=')]
adopted = [l for l in opened if l.endswith('adopted=true')]
check(len(opened) == 2 and opened[0].endswith('placement=background adopted=false') and len(adopted) == 1 and 'placement=foreground' in adopted[0],
      f'a middle click opens a background tab, then window.open becomes one foreground tab after it — the sidecar\'s own popup browser adopted ({opened})')
check(requests.count('/pop-child') == 1, f'the popup page loads once — in the popup browser, not again by maru ({requests.count("/pop-child")})')
ev = [l for l in requests if l.startswith('/ev?e=')]
check(any(l.startswith('/ev?e=msg-hi') for l in ev), f'the popup reached the page through window.opener.postMessage ({ev})')
check(any(l.startswith('/ev?e=closed-true') for l in ev) and any(l.startswith('osr-test newtab page-closed') for l in report), f'the page closed the popup — it sees closed and its tab is closed ({ev}, {report})')
check('osr-test newtab page-closed active-opener=true' in report, f'after the popup closed, the page that opened it is the active tab again — not the tab to its right ({report})')
stay = [l.strip() for l in open(sys.argv[4])]
check(any(l.endswith('placement=foreground adopted=true') for l in stay), f'the screenshot run opened the popup through adoption too ({stay})')
# 스스로 닫는 보통 탭은 여기서 보지 않는다 — maru 탭은 about:blank 로 만든 뒤 옮겨, 그것이 먼저 커밋되면 기록이 둘이라 Blink 가 닫기를
# 막고 늦으면 닫힌다(실측: 둘 다 나왔다). 닫히면 그 탭을 닫는 것은 단위 시험(`web_osr` W6f②)이 본다.
# 붙인 팝업 탭이 그려진다 — 맡긴 번호의 링이 `popup_created` 보다 먼저 와도 잃지 않는다(초록 바탕이 본문을 채운다).
green = 0
try:
    d = open(sys.argv[3], 'rb').read()
    _, dims, _, px = d.split(b'\n', 3)
    w, h = map(int, dims.split())
    want = bytes.fromhex('20a060')
    green = sum(1 for i in range(0, w * h * 3, 3) if px[i:i + 3] == want)
    area = w * h
except Exception as e:
    area = 0
check(area > 0 and green > area // 4, f'the adopted popup tab draws its page (green {green} of {area} px)')
sys.exit(0 if ok else 1)
PY

# ── W6g: 창이 뒤에 있을 때의 첫 누름 ─────────────────────────────────────────────────────────────────────────
# Chromium 탭 본문 위의 첫 누름은 창을 올리면서 페이지에도 간다(Chrome 처럼 — 사용자 결정 2026-10-05), 탭 막대 쪽은 macOS 기본(창만).
# 셸에서 띄운 앱은 맨 앞이 될 수 없어 대본 `firstmouse` 가 AppKit 이 묻는 `acceptsFirstMouse` 를 같은 사건으로 부른다.
cat > "$root/firstmouse.txt" <<SCRIPT
sleep 9000
firstmouse 0.6 0.5
firstmouse 0.6 0.005
sleep 500
SCRIPT
run_app /solid 14000 "$root/firstmouse.summary" MARU_WEB_OSR_TEST_INPUT="$root/firstmouse.txt"
grep -a '^osr-test firstmouse' "$root/app-solid.log" > "$root/firstmouse.report" || true
cat "$root/firstmouse.report"
python3 - "$root/firstmouse.report" <<'PY' || fail "the first click on a window in the background did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check('osr-test firstmouse 0.6 0.5 true' in report, f'a first click on the Chromium page body also reaches the page (acceptsFirstMouse) ({report})')
check('osr-test firstmouse 0.6 0.005 false' in report, f'a first click on the window top (not the page) only brings the window forward ({report})')
sys.exit(0 if ok else 1)
PY

# ── W4d①: 설정 `browser.engine` ─────────────────────────────────────────────────────────────────────────────
# 개발용 환경변수 없이 설정으로 켠다. 설치 위치는 `$HOMEBREW_PREFIX/opt/maru-chromium/libexec` 를 먼저 본다 — 가짜 prefix 에
# brew 와 같은 모양(`Cellar/maru-chromium/<버전>/libexec` 실제 파일 + `opt/maru-chromium` 링크)으로 설치물을 두어 「설치됨」을,
# 빈 prefix 로 「설치 없음」을 만든다(실제 /opt/homebrew 에 없을 때만 믿을 수 있다). W7a2 부터 maru 는 그 keg 의 모양·소유·
# 서명·manifest 를 보고 띄우므로 개발 디렉터리를 링크하면 거절한다.
printf 'browser.engine = chromium\n' > "$root/engine.conf"
host_under() { # $1 = 띄운 pid — 그것이나 그 자식(앱)의 자식 maru-web-host(다른 앱 프로세스를 잡지 않게)
    for p in "$1" $(pgrep -P "$1" 2>/dev/null); do pgrep -P "$p" -f 'maru-web-host --profile-dir' 2>/dev/null; done
}
engine_app() { # $1=HOMEBREW_PREFIX $2=로그 이름
    rm -rf "$root/home" && mkdir -p "$root/home"
    env -u MARU_WEB_OSR_DIR HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
        MARU_WEB_PANEL=1 MARU_CONFIG="$root/engine.conf" HOMEBREW_PREFIX="$1" \
        MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/osr-smoke" MARU_MACOS_APP_SMOKE_MS=12000 "$app" > "$root/$2.log" 2>&1
}
if [ -x /opt/homebrew/opt/maru-chromium/libexec/maru-web-host ] || [ -x /usr/local/opt/maru-chromium/libexec/maru-web-host ]; then
    echo "browser.engine: maru-chromium is really installed — skipping the not-installed case"
    real_install=1
else
    real_install=0
fi
dist_dir="$PWD/zig-out/maru-chromium"
test -x "$dist_dir/maru-web-host" || fail "build the install tree first (mise run web-sidecar builds zig-out/maru-chromium)"
mkdir -p "$root/prefix/Cellar/maru-chromium/0.0.0" "$root/prefix/opt"
cp -Rc "$dist_dir" "$root/prefix/Cellar/maru-chromium/0.0.0/libexec" # `-c` 는 복제가 안 되면 스스로 보통 복사로 대신한다(man cp)
chmod -R go-w "$root/prefix/Cellar/maru-chromium"
ln -s ../Cellar/maru-chromium/0.0.0 "$root/prefix/opt/maru-chromium"
: > "$root/requests.log"
engine_app "$root/prefix" engine-on &
on_pid=$!
sleep 8
# 양성 대조 — 아래 「설치 없음」 판정이 쓰는 같은 방법으로 자식 sidecar 가 보여야 한다.
on_child=$(host_under "$on_pid" || true)
on_command=$(ps -o command= -p "${on_child:-0}" 2>/dev/null || true)
wait "$on_pid" || true
[ -n "$on_child" ] || fail "the child-sidecar probe did not see the Chromium sidecar of an installed engine"
case "$on_command" in
    "$run_root"/run-*/maru-web-host*) ;;
    *) fail "the brew install was not started from a run copy ($on_command)" ;;
esac
left=$(find "$run_root" -mindepth 1 -maxdepth 1 -name 'run-*' 2>/dev/null)
[ -z "$left" ] || fail "the run copy was left after the app quit: $left"
grep -q '^/osr-smoke' "$root/requests.log" || fail "browser.engine = chromium with maru-chromium installed did not open the tab in Chromium"
grep -q 'browser engine: chromium' "$root/engine-on.log" || fail "the chromium engine decision was not logged"
grep -q '^web_panel_count=0$' "$root/engine-on.log" || fail "the Chromium engine still made a WKWebView for the browser tab"
if [ "$real_install" = 0 ]; then
    mkdir -p "$root/empty-prefix"
    : > "$root/requests.log"
    # 설치가 없으면 sidecar 를 띄우지 않는다 — 돌리는 동안 이 앱의 자식에 maru-web-host 가 없어야 한다(요청이 없다는 것만으로는
    # 탭이 아예 안 열려도 통과한다 — 적대 검증).
    engine_app "$root/empty-prefix" engine-missing &
    missing_pid=$!
    sleep 8
    missing_child=$(host_under "$missing_pid" || true)
    wait "$missing_pid" || true
    [ -z "$missing_child" ] || fail "browser.engine = chromium without maru-chromium still started the Chromium sidecar"
    ! grep -q '^/osr-smoke' "$root/requests.log" || fail "browser.engine = chromium without maru-chromium still used Chromium"
    grep -q 'maru-chromium is not installed' "$root/engine-missing.log" || fail "no not-installed notice when maru-chromium is missing"
    # 실제로 WebKit 으로 열었는가 — 「Chromium 으로 정했는데 설치가 망가져 탭이 빈」 경우와 가른다(변이가 살아남았다).
    grep -Eq '^web_panel_count=[1-9]' "$root/engine-missing.log" || fail "without maru-chromium the browser tab did not open in WebKit"
fi
echo "browser.engine: installed → Chromium, missing → WebKit with a notice"

# W7a2: 설치 안이 믿을 수 없으면(그룹이 쓸 수 있는 파일) 띄우지 않고 이유를 남긴다.
chmod g+w "$root/prefix/Cellar/maru-chromium/0.0.0/libexec/maru-web-helper"
: > "$root/requests.log"
engine_app "$root/prefix" engine-tampered &
tampered_pid=$!
sleep 8
tampered_child=$(host_under "$tampered_pid" || true)
wait "$tampered_pid" || true
[ -z "$tampered_child" ] || fail "a group-writable maru-chromium install was still started"
! grep -q '^/osr-smoke' "$root/requests.log" || fail "a group-writable maru-chromium install still opened the page"
grep -q 'rejected before start: writable_by_others' "$root/engine-tampered.log" || fail "no rejection reason for a group-writable install"
echo "a group-writable install is refused before start (writable_by_others)"
chmod g-w "$root/prefix/Cellar/maru-chromium/0.0.0/libexec/maru-web-helper"

# W7a2: 실행 사본을 둘 캐시 뿌리가 남이 들어올 수 있으면(0755) 복제하지 않고, brew 설치는 설치에서 바로 띄우지도 않는다.
rm -rf "$root/home" && mkdir -p "$root/home/Library/Caches/maru/web-osr-run" && chmod 755 "$root/home/Library/Caches/maru/web-osr-run"
: > "$root/requests.log"
env -u MARU_WEB_OSR_DIR HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
    MARU_WEB_PANEL=1 MARU_CONFIG="$root/engine.conf" HOMEBREW_PREFIX="$root/prefix" \
    MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/osr-smoke" MARU_MACOS_APP_SMOKE_MS=12000 "$app" > "$root/engine-opencache.log" 2>&1 &
opencache_pid=$!
sleep 8
opencache_child=$(host_under "$opencache_pid" || true)
wait "$opencache_pid" || true
[ -z "$opencache_child" ] || fail "the brew install was started without a run copy ($opencache_child)"
! grep -q '^/osr-smoke' "$root/requests.log" || fail "the brew install opened the page without a run copy"
grep -q 'could not make the maru-chromium run copy: writable_by_others' "$root/engine-opencache.log" || fail "no reason logged when the run cache is open to others"
echo "no run copy (open cache root) → the brew install is not started"

# W7a2: 사본을 만든 뒤 띄우기가 실패하면(여기선 프로필 자리에 파일) 그 사본도 지운다.
rm -rf "$root/home" && mkdir -p "$root/home/Library/Application Support/maru" && : > "$root/home/Library/Application Support/maru/web"
env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" MARU_WEB_PANEL=1 \
    MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/osr-smoke" MARU_MACOS_APP_SMOKE_MS=8000 \
    "$app" > "$root/profile-blocked.log" 2>&1 &
blocked_pid=$!
sleep 5
[ -d "$run_root" ] || fail "no run cache when the profile could not be made — the start did not get as far as the copy"
left=$(find "$run_root" -mindepth 1 -maxdepth 1 -name 'run-*' 2>/dev/null)
wait "$blocked_pid" || true
[ -z "$left" ] || fail "a run copy was left after the start failed on the profile: $left"
echo "a start that fails after the copy removes the copy"

# W7a2: 릴리스 판(hardened runtime)은 개발용 환경변수로 실행 파일을 고르지 않는다 — 같은 앱을 ad-hoc 으로 hardened runtime
# 서명해 본다(판정은 빌드 플래그가 아니라 실행 중 서명 상태 `csops`).
# 릴리스 판은 `HOME` 대신 계정 홈을 쓴다 — 엔진을 정할 때 그 홈의 캐시를 청소하므로 실제 홈을 건드리지 않았는지 전후로 본다.
real_run_root="$(eval echo "~$(id -un)")/Library/Caches/maru/web-osr-run"
real_before=$(ls -1a "$real_run_root" 2>&1 || true)
cp "$app" "$root/maru-hardened"
codesign --force --sign - --options runtime "$root/maru-hardened" 2> "$root/hardened-sign.log" || fail "could not sign the hardened copy ($(cat "$root/hardened-sign.log"))"
hardened_app() { # $1=로그 이름, 나머지는 추가 환경
    name=$1; shift
    rm -rf "$root/home" && mkdir -p "$root/home"
    : > "$root/requests.log"
    env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" MARU_WEB_PANEL=1 \
        MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/osr-smoke" MARU_MACOS_APP_SMOKE_MS=10000 "$@" "$root/maru-hardened" > "$root/$name.log" 2>&1 &
    hardened_pid=$!
    sleep 7
    hardened_child=$(pgrep -P "$hardened_pid" -f 'maru-web-host --profile-dir' 2>/dev/null || true)
    wait "$hardened_pid" || true
    [ -z "$hardened_child" ] || fail "the hardened build started a sidecar chosen by the environment ($name)"
    ! grep -q '^/osr-smoke' "$root/requests.log" || fail "the hardened build opened the page in Chromium ($name)"
    grep -Eq '^web_panel_count=[1-9]' "$root/$name.log" || fail "the hardened build did not fall back to WebKit ($name)"
}
hardened_app hardened-envdir MARU_WEB_OSR_DIR="$sidecar_dir"
if [ "$real_install" = 0 ]; then
    hardened_app hardened-prefix MARU_CONFIG="$root/engine.conf" HOMEBREW_PREFIX="$root/prefix"
    grep -q 'maru-chromium is not installed' "$root/hardened-prefix.log" || fail "the hardened build did not ignore HOMEBREW_PREFIX"
else
    echo "hardened runtime: maru-chromium is really installed — skipping the HOMEBREW_PREFIX case"
fi
real_after=$(ls -1a "$real_run_root" 2>&1 || true)
[ "$real_before" = "$real_after" ] || fail "the hardened run changed the real $real_run_root"
if [ "$real_install" = 0 ]; then
    echo "hardened runtime: MARU_WEB_OSR_DIR and HOMEBREW_PREFIX are ignored"
else
    echo "hardened runtime: MARU_WEB_OSR_DIR is ignored"
fi
echo "web-osr smoke passed"
