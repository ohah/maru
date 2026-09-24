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
import http.server, sys
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
host_pid=""
for _ in $(seq 1 100); do
    host_pid=$(pgrep -P "$app_pid" -f maru-web-host || true)
    [ -n "$host_pid" ] && break
    sleep 0.1
done
[ -n "$host_pid" ] || fail "no maru-web-host child of the app"
echo "sidecar pid $host_pid (parent $app_pid)"

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
        pid=$(pgrep -P "$app_pid" -f maru-web-host || true)
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
latched=$(pgrep -P "$app_pid" -f maru-web-host || true)
[ -z "$latched" ] || fail "restarted again after three crashes in a minute ($latched)"
echo "third crash within a minute: no restart (budget)"
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
run_app() { # $1=경로 $2=실행 ms $3=요약 파일, 나머지는 추가 환경
    path=$1; ms=$2; summary=$3; shift 3
    rm -rf "$root/home" && mkdir -p "$root/home"
    env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
        MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port$path" \
        MARU_MACOS_APP_SMOKE_MS="$ms" MARU_APP_SUMMARY_PATH="$summary" "$@" "$app" > "$root/app-${path#/}.log" 2>&1
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
echo "web-osr smoke passed"
