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
