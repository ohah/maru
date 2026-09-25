#!/bin/sh
# W4d② 앱 안 시험기(CI 밖 — CEF SDK 가 필요하다): Chromium 탭 입력을 AppKit 쪽에서 넣고 페이지가 받은 DOM 이벤트로
# 판정한다. W4b·W4c 스모크는 대본이 ABI 를 곧바로 불렀다 — 여기서는 그 위의 Swift 한 겹을 탄다:
#   - 키: 진짜 키 이벤트를 앱 자기 프로세스에만 보낸다(`post` — 창 서버 → NSApp.sendEvent → keyDown·interpretKeyEvents).
#     다른 앱으로 새지 않고 앱이 비활성이어도 닿는다. **비활성 앱에는 키 창이 없어 ⌘ 조합은 view 의 performKeyEquivalent 를
#     건너뛰고 메뉴로 간다**(실측) — ⌘A·⌘D·⌘⌥← 는 메뉴 key equivalent 로, view 가 먼저 받는 ⌘Z·⌘⇧P 는 AppKit 순서를 대본이
#     밟는 `key` 로 넣는다. 진짜 performKeyEquivalent 경로는 `--live` 가 본다.
#   - 마우스: 터미널 view 의 마우스 메서드를 NSEvent 로 부른다(view → Swift 좌표·버튼·클릭 수 변환 → ABI). 창 hitTest 한
#     겹만 건너뛴다 — 비활성 앱의 창에 클릭을 보내면 창 활성화가 먹거나 앱이 앞으로 올라와 포커스를 빼앗는다.
#   - 커서·후보창 자리·오버레이는 앱 안에서 잰다(`cursor`·`imerect`·`overlay`). 조합은 입력기 콜백을 직접 부른다(진짜
#     입력기는 비활성 앱에서 조합하지 않는다 — `--live`).
# 사용자 작업을 방해하지 않는다: 앱을 앞으로 올리지 않고, 시스템 입력 소스·클립보드·포인터를 건드리지 않는다.
# 좌표 배율 판정(두 클릭 100 pt → 100 CSS px)은 2배 화면에서만 판별력이 있다 — 1배 화면에서는 배율을 무시해도 같다.
#
# `--live`(자리 비움 모드): 진짜 macOS 한글 입력기는 maru 가 맨 앞 앱이고 키가 HID 로 들어올 때만 조합한다. 이 모드는
# maru 를 앞으로 올리고 시스템 입력 소스를 한글 2벌식으로 바꾸고 진짜 키·포인터·클립보드(⌘C·⌘V)를 쓴다 — **자리를 비웠을
# 때만** 돌린다. 끝나면(앱이 죽어도) 입력 소스·클립보드·앞 앱을 되돌린다 — 사용자가 그 사이 바꾼 것은 덮지 않는다.
set -eu

live=0
[ "${1:-}" = "--live" ] && live=1

sidecar_dir="$PWD/zig-out/web-sidecar"
app=./zig-out/bin/maru-macos-app
bundle="$PWD/zig-out/Maru.app"
test -x "$sidecar_dir/maru-web-host" || { echo "web-osr tester: build the sidecar first (mise run web-sidecar)" >&2; exit 2; }
test -x "$app" || { echo "web-osr tester: build the app first (zig build macos-app-build)" >&2; exit 2; }
if [ "$live" = 1 ]; then
    test -d "$bundle" || { echo "web-osr tester: build the app first (zig build macos-app-build)" >&2; exit 2; }
fi
keep=${MARU_WEB_OSR_TESTER_KEEP:-}
[ -z "$keep" ] || [ ! -e "$keep" ] || { echo "web-osr tester: MARU_WEB_OSR_TESTER_KEEP=$keep already exists" >&2; exit 2; }

root=$(mktemp -d "/tmp/maru-web-osr-tester.XXXXXX")
server_pid=""
app_pid=""
watchdog_pid=""
clip_saved=0
restore_exe="$root/input-source-restore"
cleanup() {
    [ -n "$watchdog_pid" ] && kill "$watchdog_pid" 2>/dev/null || true
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    pkill -KILL -f "$root" 2>/dev/null || true
    if [ "$live" = 1 ]; then
        # 앱이 되돌리지 못하고 죽었으면(SIGTERM·SIGKILL 은 applicationWillTerminate 를 안 부른다) 입력 소스(우리가 고른
        # 소스일 때만 — 복원 도구의 규칙)를 되돌린다. 클립보드 글은 앱이 ⌘C 를 보냈는데(`live clipboard-touched`) 되돌렸다는
        # 보고가 없고, 시작 전 클립보드가 글이었을 때만 — 글이 아닌 클립보드(그림·파일)는 pbcopy 로 되살릴 수 없어 비우지
        # 않는다.
        [ -f "$root/input-source-restore.json" ] && [ -x "$restore_exe" ] && "$restore_exe" "$root/input-source-restore.json" || true
        if [ "$clip_saved" = 1 ] && [ -s "$root/clip.txt" ] && grep -q '^live clipboard-touched' "$root/report" 2>/dev/null &&
            ! grep -q '^live restored' "$root/report"; then
            pbcopy < "$root/clip.txt" || true
        fi
    fi
    # 실패를 들여다볼 때: MARU_WEB_OSR_TESTER_KEEP=<없는 디렉터리> 면 로그를 거기 남긴다.
    [ -n "$keep" ] && cp -R "$root" "$keep" || true
    rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

port=$((20000 + $$ % 20000))
cat > "$root/server.py" <<'PY'
import http.server, sys
log = open(sys.argv[2], 'a', buffering=1)
# 위 절반은 textarea(키·조합·포커스), 아래 절반은 링크(손가락 커서·클릭하면 #b 로 — 뒤로 버튼 판정)이자 스크롤 칸이다.
# 페이지마다 인스턴스 id(p)를 실어 창이 둘일 때 어느 페이지가 받았는지 가르고, 순번(s)을 실어 요청이 병렬 연결로 뒤바뀌어
# 도착해도 페이지가 보낸 순서로 판정한다.
PAGE = ("<!doctype html><title>tester</title><style>html,body{margin:0;height:100%}"
    "textarea{display:block;width:100%;height:50%;box-sizing:border-box;margin:0;font:24px sans-serif}"
    "#l{display:block;height:50%;overflow:auto;background:#dde}#l div{height:3000px}</style>"
    "<body><textarea id=t></textarea><a id=l href='#b'><div></div></a><script>"
    "var P=Math.random().toString(36).slice(2,8),S=0,t=document.getElementById('t'),l=document.getElementById('l');"
    "function ping(q){new Image().src='/ev?p='+P+'&s='+(++S)+'&'+q+'&t='+Date.now()}"
    "t.addEventListener('keydown',function(e){ping('e=kd&k='+encodeURIComponent(e.key)+'&c='+(e.ctrlKey?1:0)+'&m='+(e.metaKey?1:0))});"
    "t.addEventListener('input',function(e){ping('e=val&v='+encodeURIComponent(t.value)+'&comp='+(e.isComposing?1:0))});"
    "t.addEventListener('compositionend',function(e){ping('e=cend&d='+encodeURIComponent(e.data))});"
    "t.addEventListener('focus',function(){ping('e=focus')});t.addEventListener('blur',function(){ping('e=blur')});"
    "addEventListener('mousedown',function(e){ping('e=down&x='+e.clientX+'&y='+e.clientY+'&b='+e.button)});"
    "addEventListener('click',function(e){ping('e=click&x='+e.clientX+'&y='+e.clientY+'&d='+e.detail)});"
    "addEventListener('dblclick',function(e){ping('e=dblclick&d='+e.detail)});"
    "addEventListener('contextmenu',function(e){e.preventDefault();ping('e=contextmenu')});"
    "addEventListener('auxclick',function(e){if(e.button==1)ping('e=aux')});"
    "var out=false,held=false,mv=0;addEventListener('mousemove',function(e){if(!(e.buttons&1)){held=false;if(Date.now()-mv>300){mv=Date.now();ping('e=mv')}return}"
    "if(!held){held=true;ping('e=bmove&x='+e.clientX+'&y='+e.clientY)}if(e.clientX<0&&!out){out=true;ping('e=dragout&x='+e.clientX)}});"
    "addEventListener('hashchange',function(){ping('e=hash&h='+encodeURIComponent(location.hash))});"
    "requestAnimationFrame(function(){requestAnimationFrame(function(){ping('e=ready')})});"
    "</script>").encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        log.write(self.path + "\n")
        body = PAGE if self.path == "/tester" else b""
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$root/server.py" "$port" "$root/requests.log" &
server_pid=$!
sleep 1

fail() { echo "web-osr tester failed: $1" >&2; exit 1; }

# 앱이 멈춰 스모크 시간에 끝나지 않으면(메인 스레드 정지 등) 죽인다 — 자리 비움 모드에서 maru 가 입력 소스를 쥔 채 맨 앞에
# 남지 않게.
watchdog() { # $1=실행 ms
    [ -n "$app_pid" ] || return 0
    (sleep $(($1 / 1000 + 30)); kill "$app_pid" 2>/dev/null) &
    watchdog_pid=$!
}

run_app() { # $1=대본 $2=실행 ms, 나머지는 추가 환경(NAME=값)
    script=$1; ms=$2; shift 2
    rm -rf "$root/home" && mkdir -p "$root/home"
    : > "$root/requests.log"
    : > "$root/report"
    printf 'browser.engine = chromium\n' > "$root/config"
    set -- HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" MARU_CONFIG="$root/config" \
        MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/tester" \
        MARU_MACOS_APP_SMOKE_MS="$ms" MARU_WEB_OSR_TEST_INPUT="$script" MARU_WEB_OSR_TEST_REPORT="$root/report" "$@"
    if [ "$live" = 1 ]; then
        # 셸에서 띄운 실행 파일은 맨 앞 앱이 되지 못한다 — LaunchServices 로 번들을 띄운다(CR6d 와 같은 길). 앱 pid 는 번들
        # 실행 파일 경로로 찾아 cleanup 이 죽인다(`open` 의 argv 에는 앱 pid 가 없다).
        count=$#
        for kv in "$@"; do set -- "$@" --env "$kv"; done
        shift "$count"
        before=$(pgrep -f "$bundle/Contents/MacOS/maru-macos-app" || true)
        /usr/bin/open -n -W --stdout "$root/app.out.log" --stderr "$root/app.log" "$@" "$bundle" &
        open_pid=$!
        for _ in $(seq 1 100); do
            for pid in $(pgrep -f "$bundle/Contents/MacOS/maru-macos-app" || true); do
                case " $before " in *" $pid "*) ;; *) app_pid=$pid ;; esac
            done
            [ -n "$app_pid" ] && break
            sleep 0.1
        done
        watchdog "$ms"
        wait "$open_pid" || true
        app_pid=""
    else
        env "$@" "$app" > "$root/app.log" 2>&1 &
        app_pid=$!
        watchdog "$ms"
        wait "$app_pid" || true
        app_pid=""
    fi
}

# 판정기: 페이지 이벤트를 `mark` 시각으로 단계에 나눈다(보고의 시각과 페이지의 Date.now() 는 같은 시계다).
cat > "$root/judge.py" <<'PY'
import sys, urllib.parse
req, report = sys.argv[1], sys.argv[2]
evs = []
for line in open(req):
    line = line.strip()
    if line.startswith('/ev?'):
        evs.append(dict(urllib.parse.parse_qsl(line[4:], keep_blank_values=True)))
# 도착 순서가 아니라 페이지가 보낸 순서(같은 ms 안은 순번).
evs.sort(key=lambda e: (int(e.get('t', 0)), int(e.get('s', 0))))
marks, lines = [], []
for line in open(report):
    parts = line.split()
    if parts and parts[0] == 'mark':
        marks.append((parts[1], int(parts[2])))
    lines.append(line.strip())
def phase(name):
    """그 mark 부터 다음 mark 까지의 페이지 이벤트."""
    names = [m[0] for m in marks]
    if name not in names:
        return []
    i = names.index(name)
    lo = marks[i][1]
    hi = marks[i + 1][1] if i + 1 < len(marks) else 1 << 62
    return [e for e in evs if lo <= int(e.get('t', 0)) < hi]
def after(name):
    """그 mark 에 이어진 보고 줄."""
    out, on = [], False
    for line in lines:
        if line.startswith('mark '):
            on = line.split()[1] == name
        elif on:
            out.append(line)
    return out
def kinds(es): return [e.get('e') for e in es]
def at(es, kind): return [e for e in es if e.get('e') == kind]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
PY

if [ "$live" = 0 ]; then
# ── 자동(방해 없음) ────────────────────────────────────────────────────────────────────────────────────────────
# 좌표는 창 내용 view 의 (fx×폭 + dx, fy×높이 + dy) pt. 본문은 오른쪽 아래에 있고 fy 0.3 은 textarea, 0.8 은 링크, 0.147 은
# 본문 위의 주소창이다(Zig 가 받는 크롬 — 맨 위 28 pt 는 창 끌기 영역이라 AppKit 이 누름을 가져가고, 탭 줄의 탭을 끌면 탭이
# 옮겨지거나 분할돼 뒤 단계가 흔들린다). 키 번호: a=0 b=11 c=8 e=14 x=7 y=16 z=6 d=2 p=35 Enter=36 Backspace=51 Esc=53 ←=123, 수식자 shift=4
# ctrl=16 cmd=32 alt=8.
cat > "$root/auto.txt" <<'SCRIPT'
sleep 7000
mark keys
view down 0.6 0.3 0 0 0 1
view up 0.6 0.3 0 0 0 1
sleep 400
post 0
post 11
post 36
post 8
post 51
sleep 300
post 14 16
sleep 200
post 0 32
post 51
sleep 300
key 6 U+7A U+7A 32
sleep 400
mark ime
post 7
post 16
post 6
sleep 300
ime 2 m:U+3147
sleep 300
imerect
ime 36 i:U+3147 c:insertNewline:
sleep 300
mark clicks
view down 0.6 0.8 -60 0 0 1
view up 0.6 0.8 -60 0 0 1
view down 0.6 0.8 -60 0 0 2
view up 0.6 0.8 -60 0 0 2
sleep 300
view down 0.6 0.8 40 0 0 1
view up 0.6 0.8 40 0 0 1
sleep 300
mark right
view down 0.6 0.3 0 0 1 1
view up 0.6 0.3 0 0 1 1
sleep 300
mark middle
view down 0.6 0.3 0 0 2 1
view up 0.6 0.3 0 0 2 1
sleep 300
mark back
view down 0.6 0.8 0 0 3 1
view up 0.6 0.8 0 0 3 1
sleep 600
mark drag
view down 0.6 0.3 0 0 0 1
view drag 0.4 0.3 0 0 0 1
view drag 0.05 0.3 0 0 0 1
view up 0.05 0.3 0 0 0 1
sleep 300
mark cursor-link
view move 0.6 0.8 0 0 0 0
sleep 400
view move 0.6 0.8 1 0 0 0
sleep 100
cursor
mark cursor-text
view move 0.6 0.3 0 0 0 0
sleep 400
view move 0.6 0.3 1 0 0 0
sleep 100
cursor
mark cursor-out
view move 0.05 0.5 0 0 0 0
sleep 100
cursor
mark palette
key 35 U+50 U+50 36
sleep 600
view down 0.6 0.3 0 0 0 1
view up 0.6 0.3 0 0 0 1
post 0
sleep 300
mark palette-closed
post 53
sleep 600
post 11
sleep 400
mark toast
config browser.engine = webkit
menu Reload Config
sleep 800
overlay
view down 0.6 0.3 -50 0 0 1
view up 0.6 0.3 -50 0 0 1
sleep 400
overlay
view down 0.6 0.3 50 0 0 1
view up 0.6 0.3 50 0 0 1
sleep 400
mark lostup
view down 0.6 0.3 -50 0 0 1
view down 0.6 0.147 0 0 0 1
view up 0.6 0.147 0 0 0 1
sleep 300
view down 0.6 0.3 50 0 0 1
view up 0.6 0.3 50 0 0 1
sleep 400
mark outdrag
view down 0.6 0.147 0 0 0 1
view drag 0.6 0.3 0 0 0 1
view drag 0.6 0.5 0 0 0 1
view up 0.6 0.5 0 0 0 1
sleep 400
mark refocus
view down 0.6 0.3 0 0 0 1
view up 0.6 0.3 0 0 0 1
sleep 400
mark split
post 2 32
sleep 1000
post 0
sleep 400
mark split-back
post 123 40
sleep 600
post 11
sleep 400
mark newwindow
newwindow
sleep 3000
view down 0.6 0.3 0 0 0 1
view up 0.6 0.3 0 0 0 1
sleep 300
key 0 U+61
sleep 600
mark end
SCRIPT
run_app "$root/auto.txt" 40000
cat "$root/report"
python3 - "$root/requests.log" "$root/report" "$root/judge.py" <<'PY' || fail "the Chromium tab did not get the AppKit input as expected"
import sys
exec(open(sys.argv[3]).read())
names = [m[0] for m in marks]
t_new = marks[names.index('newwindow')][1] if 'newwindow' in names else 1 << 62
first = {e['p'] for e in evs if int(e['t']) < t_new}
check(len(first) == 1, f'one page instance until the new window (no reload in between: {sorted(first)})')
readies = [e['p'] for e in evs if e.get('e') == 'ready']
check(len(readies) == 2 and len(set(readies)) == 2, f'exactly two page loads — the first window and the new window ({readies})')
P0 = next(iter(first)) if first else None
def mine(name): return [e for e in phase(name) if e.get('p') == P0]

k = mine('keys')
downs = at(k, 'down')
check(bool(downs) and 'focus' in kinds(k), 'a click through the view mouseDown focuses the textarea')
X0, Y0 = (int(downs[0]['x']), int(downs[0]['y'])) if downs else (0, 0)
press = [l.split() for l in after('keys') if l.startswith('view down')]
OX, OY = (int(press[0][2]) - X0, int(press[0][3]) - Y0) if press else (0, 0)
kd = [e['k'] for e in at(k, 'kd')]
vals = [e['v'] for e in at(k, 'val')]
check(kd[:5] == ['a', 'b', 'Enter', 'c', 'Backspace'], f'real key events reach the page in order (window server → keyDown → interpretKeyEvents: {kd[:5]})')
check('ab\nc' in vals and vals[vals.index('ab\nc') + 1:][:1] == ['ab\n'], 'typing, Enter (newline) and Backspace edit the textarea')
check(any(e['k'] == 'e' and e['c'] == '1' for e in at(k, 'kd')), '⌃E arrives as key e with ctrlKey')
empty = vals.index('') if '' in vals else -1
check(empty >= 0, '⌘A (menu key equivalent → select all) then Backspace empties the textarea')
check(empty >= 0 and 'ab\n' in vals[empty + 1:], '⌘Z (AppKit order: view performKeyEquivalent → page undo) restores the text')
check(not any(e['m'] == '1' for e in at(k, 'kd')), 'the ⌘ chords maru handles send no page keydown')

i = mine('ime')
rect = [l.split() for l in after('ime') if l.startswith('imerect')]
rx, ry, rw, rh = map(int, rect[0][1:5]) if rect else (-1, -1, 0, 0)
# 조합은 글자 몇 개 뒤다 — 사각형이 없을 때의 폴백(페이지 원점)과 갈리게 원점에서 오른쪽으로 떨어져 있어야 한다.
check(OX + 25 <= rx <= OX + 200 and OY <= ry <= OY + 120 and rh > 0,
      f'the input method places candidates at the composition, not at the page origin (rect {rx},{ry} {rw}x{rh}, page origin {OX},{OY})')
check(any(e['d'] == 'ㅇ' for e in at(i, 'cend')), 'the composition commits into the page')

c = mine('clicks')
check(any(e['d'] == '2' for e in at(c, 'dblclick')), 'a double click (NSEvent clickCount 2) reaches as dblclick detail 2')
xs = sorted({int(e['x']) for e in at(c, 'click')})
check(len(xs) == 2 and abs(xs[1] - xs[0] - 100) <= 1, f'two clicks 100 pt apart land 100 CSS px apart (view pt → backing px → DIP: {xs})')
r, m = mine('right'), mine('middle')
check('contextmenu' in kinds(r) and 'aux' not in kinds(r), f'a right click (rightMouseDown) reaches as contextmenu ({kinds(r)})')
check('aux' in kinds(m) and 'contextmenu' not in kinds(m), f'a middle click (otherMouseDown button 2) reaches as auxclick ({kinds(m)})')
check(any(e['h'] == '#b' for e in at(c, 'hash')), 'clicking the link navigates (#b)')
check(any(e['h'] == '' for e in at(mine('back'), 'hash')), 'the back mouse button (otherMouseDown button 3) takes the tab back')
check(any(int(e['x']) < 0 for e in at(mine('drag'), 'dragout')), 'a drag from the page past its left edge keeps going to the page (clientX < 0)')

# 앞 단계가 기억시킨 커서와 다른 것을 바라게 차례를 짰다(글 → 링크 → 글 → 밖).
for name, want in (('cursor-link', 'hand'), ('cursor-text', 'ibeam'), ('cursor-out', 'arrow')):
    got = [l.split()[1] for l in after(name) if l.startswith('cursor ')]
    check(got[-1:] == [want], f'hover cursor over {name[7:]} is {want} ({got})')

pal = mine('palette')
check('blur' in kinds(pal) and not any(x in kinds(pal) for x in ('down', 'click', 'kd')),
      f'⌘⇧P (AppKit order: view performKeyEquivalent → web key route → app action) opens the palette: the page blurs and gets no click or key ({kinds(pal)})')
closed = mine('palette-closed')
check('focus' in kinds(closed) and any(e['k'] == 'b' for e in at(closed, 'kd')), 'Esc closes it: the page gets focus and keys back')

ov = [l.split()[1] for l in after('toast') if l.startswith('overlay ')]
t = at(mine('toast'), 'down')
check(ov == ['true', 'false'], f'Reload Config with a changed engine shows the notice toast and the first click closes it ({ov})')
check(len(t) == 1 and abs(int(t[0]['x']) - (X0 + 50)) <= 1, f'that first click does not reach the page, the second does ({[e["x"] for e in t]})')
lu = mine('lostup')
check([int(e['x']) for e in at(lu, 'down')] == [X0 - 50, X0 + 50] and [int(e['x']) for e in at(lu, 'click')] == [X0 + 50],
      f'a press on the page whose release was lost: a press outside (address bar) starts a new gesture there, not a page drag ({[(e["e"], e.get("x"), e.get("y")) for e in lu]})')
td = mine('outdrag')
check(not any(x in kinds(td) for x in ('down', 'click', 'bmove', 'mv', 'dragout')), f'a drag that starts outside the page (address bar) and crosses it sends the page nothing ({kinds(td)})')
check('focus' in kinds(mine('refocus')), 'clicking the page again gives it focus back')
sp = mine('split')
check('blur' in kinds(sp) and 'kd' not in kinds(sp), f'⌘D (menu) splits to a terminal pane: the page blurs and typing does not reach it ({kinds(sp)})')
back = mine('split-back')
check('focus' in kinds(back) and any(e['k'] == 'b' for e in at(back, 'kd')), '⌘⌥← (menu) back to the web pane: focus and keys return')
nw = phase('newwindow')
old = [e for e in nw if e.get('p') == P0]
ready1 = [e for e in nw if e.get('e') == 'ready' and e.get('p') != P0]
P1 = ready1[0]['p'] if ready1 else None
new = [e for e in nw if e.get('p') == P1]
new_down = at(new, 'down')
check(set(kinds(old)) <= {'blur'}, f'a click and a key in a new window at the same place do not reach the first window page ({kinds(old)})')
check(P1 is not None and bool(new_down) and int(ready1[0]['t']) <= int(new_down[0]['t']) and any(e['k'] == 'a' for e in at(new, 'kd')),
      f'they reach the new window own Chromium tab, loaded before the click ({kinds(new)})')
check(not any(l.startswith(('menu-missing', 'post-refused')) for l in lines), 'every scripted step ran')
sys.exit(0 if ok else 1)
PY
fi

if [ "$live" = 1 ]; then
# ── 자리 비움 모드 ─────────────────────────────────────────────────────────────────────────────────────────────
# maru 가 맨 앞에서 진짜 입력기(한글 2벌식)·진짜 포인터·진짜 클립보드로 받는다. 2벌식 자판: d=ㅇ(2) k=ㅏ(40) s=ㄴ(1).
# 조합 앞에 줄바꿈과 공백을 넣어 후보창 사각형이 페이지 원점(사각형이 없을 때의 폴백)과 갈리게 한다.
echo "web-osr tester --live: maru comes to the front, switches the input source to Korean 2-Set and moves the pointer."
echo "  Do not touch the keyboard or mouse. Everything is restored at the end. Ctrl-C now to cancel."
sleep 5
# 입력 소스 복원 도구(CR6d 와 같은 두 소스 — `macos-app-build` 는 만들지 않는다)를 먼저 만든다. 없으면 입력 소스를 바꾸지 않는다.
xcrun swiftc -parse-as-library src/platform/macos/SessionHostInputSourcePolicy.swift src/platform/macos/SessionHostInputSourceRestore.swift \
    -o "$restore_exe" > "$root/restore-build.log" 2>&1 || fail "could not build the input-source restore tool ($root/restore-build.log)"
# LaunchServices 로 띄운 앱은 제 TCC 책임자다 — 문서 폴더 아래의 sidecar 를 읽다 권한 창이 뜨지 않게 임시 뿌리로 복제한다.
cp -cR "$sidecar_dir" "$root/web-sidecar" 2>/dev/null || cp -R "$sidecar_dir" "$root/web-sidecar"
sidecar_dir="$root/web-sidecar"
front=$(osascript -e 'id of application (path to frontmost application as text)' 2>/dev/null || true)
pbpaste > "$root/clip.txt" 2>/dev/null && clip_saved=1 || true
cat > "$root/live.txt" <<'SCRIPT'
sleep 7000
live begin
sleep 1500
live source
sleep 300
live check
mark live-click
live click 0.6 0.3 0 0
sleep 500
mark live-hangul
live key 36
live key 49
live key 49
live key 49
live key 49
live key 2
live key 40
live key 1
sleep 300
imerect
live key 49
sleep 400
mark live-backspace
live key 2
live key 40
live key 51
live key 51
sleep 400
mark live-enter
live key 2
live key 40
live key 36
sleep 400
mark live-copy
live key 0 32
live key 8 32
sleep 300
live key 124
sleep 200
live key 9 32
sleep 500
live settle
mark live-undo
live key 6 32
sleep 500
mark live-palette
live key 35 36
sleep 600
mark live-palette-closed
live key 53
sleep 600
mark live-cursor
live move 0.6 0.8 0 0
sleep 600
live move 0.6 0.8 1 0
sleep 400
cursor
mark live-end
live end
sleep 500
SCRIPT
run_app "$root/live.txt" 26000 MARU_WEB_OSR_TEST_LIVE="$root/input-source-restore.json" MARU_WEB_OSR_TEST_LIVE_FRONT="${front:-none}"
cat "$root/report"
python3 - "$root/requests.log" "$root/report" "$root/judge.py" <<'PY' || fail "the real input method, pointer or clipboard did not reach the Chromium tab as expected"
import sys
exec(open(sys.argv[3]).read())
def vals(name): return [e['v'] for e in at(phase(name), 'val')]
state = [l for l in lines if l.startswith('live owns=')]
check(bool(state) and 'owns=true' in state[0] and 'Korean.2SetKorean' in state[0], f'maru is frontmost with Korean 2-Set selected ({state})')
check(not any(l.startswith(('live-not-front', 'live-refused', 'live-source-failed', 'live-covered', 'live-no-window', 'live-no-post-access')) for l in lines),
      'every real key and pointer event was sent (maru stayed in front and uncovered)')
c = phase('live-click')
downs = at(c, 'down')
check(bool(downs) and 'focus' in kinds(c), 'a real click (window server → hitTest → view) focuses the textarea')
X0, Y0 = (int(downs[0]['x']), int(downs[0]['y'])) if downs else (0, 0)
press = [l.split() for l in lines if l.startswith('live click')]
OX, OY = (int(press[0][2]) - X0, int(press[0][3]) - Y0) if press else (0, 0)
pre = '\n    '
h = phase('live-hangul')
check(any(e['v'] == pre + '안' and e['comp'] == '1' for e in at(h, 'val')), f'the real input method composes ㅇ → 아 → 안 in the page ({vals("live-hangul")})')
check(any(e['d'] in ('안', '안 ') for e in at(h, 'cend')) and vals('live-hangul')[-1:] == [pre + '안 '], 'Space commits 안 and types the space')
rect = [l.split() for l in lines if l.startswith('imerect')]
rx, ry = (int(rect[0][1]), int(rect[0][2])) if rect else (-1, -1)
check(OX + 20 <= rx <= OX + 200 and OY + 20 <= ry <= OY + 120, f'the candidate window sits at the real composition (rect {rx},{ry}, page origin {OX},{OY})')
b = phase('live-backspace')
check(vals('live-backspace')[-1:] == [pre + '안 '] and not any(e['d'] for e in at(b, 'cend')),
      f'Backspace on the last jamo cancels the composition without committing it ({vals("live-backspace")})')
before = pre + '안 아\n'
check(vals('live-enter')[-1:] == [before], f'Enter commits 아 and inserts a newline ({vals("live-enter")})')
check(vals('live-copy')[-1:] == [before + before], f'⌘A ⌘C → ⌘V pastes the page selection through the real clipboard ({vals("live-copy")[-1:]})')
check(vals('live-undo')[-1:] == [before], f'⌘Z undoes the paste ({vals("live-undo")[-1:]})')
p = phase('live-palette')
check('blur' in kinds(p) and 'kd' not in kinds(p), f'⌘⇧P through the real key window opens the palette ({kinds(p)})')
check('focus' in kinds(phase('live-palette-closed')), 'Esc closes it and the page gets focus back')
cur = [l.split()[1] for l in lines if l.startswith('cursor ')]
check(cur[-1:] == ['hand'], f'hovering the link with the real pointer shows the hand cursor ({cur})')
check(any(l.startswith('live restored source=true clipboard=true') for l in lines), 'the input source and clipboard were restored')
sys.exit(0 if ok else 1)
PY
fi

echo "web-osr tester passed"
