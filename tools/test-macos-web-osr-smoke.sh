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
# W6m②: 제안 목록 — select 페이지와 같은 자리(본문 폭 50%·높이 40%)의 빨간 글 칸에 옵션 다섯(둘은 레이블 — 하나는 가장 넓은
# 행). 페이지는 change·keydown 을 알린다.
DL = ("<!doctype html><title>dl</title><style>html,body{margin:0;height:100%;background:#20a060}body{height:3000px}"
    "input{position:fixed;left:0;top:0;width:50%;height:40%;border:0;background:#ff0000;font:20px sans-serif}</style><body>"
    "<input id=a list=l autocomplete=off><datalist id=l><option value=apple><option value=banana><option value=cherry label='red fruit'><option value=date><option value='elderberry wine' label='a longer label'></datalist><script>"
    "var a=document.getElementById('a');function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}"
    "a.addEventListener('change',function(){ping('e=change&v='+a.value)});a.addEventListener('keydown',function(e){ping('e=kd&k='+e.key)});"
    "a.addEventListener('keyup',function(e){ping('e=ku&k='+e.key)});document.addEventListener('mousedown',function(e){ping('e=md&b='+e.button)});"
    "</script>").encode()
# W6m②: 사용자가 손대지 않았는데 페이지가 스스로 칸에 글을 넣는다(`execCommand` — Chrome 은 그 `input` 을 isTrusted 로 낸다) —
# maru 는 최근 사용자 입력이 없는 탭의 목록을 받지 않는다(적대 검증 4 차). 본문을 한 번 눌러(탭이 키 대상이 되게 — 안 누르면
# 목록이 있어도 띄울 탭이 없어 판정이 아무것도 보지 못한다) 2.5 초 뒤에 넣는다(누름은 1 초 창 밖).
DLAUTO = DL.replace(b"</script>", b"a.addEventListener('input',function(e){ping('e=in&tr='+e.isTrusted)});var armed=false;"
    b"document.addEventListener('mousedown',function(){if(armed)return;armed=true;setTimeout(function(){a.focus();document.execCommand('insertText',false,'a')},2500)});</script>")
# W6m③: 열린 shadow DOM 안의 빨간 칸(본문 왼쪽 위 폭 50%·높이 30%)과, 다른 출처 iframe(localhost — 본문 위 40%~80%) 안의 파란 칸
# (iframe 의 위쪽 절반). 둘 다 목록이 붙어 있다.
DLF = ("<!doctype html><title>dlf</title><style>html,body{margin:0;height:100%;background:#20a060}#h{position:fixed;left:0;top:0;width:50%;height:30%}"
    "iframe{position:fixed;left:0;top:40%;width:50%;height:40%;border:0}</style><body><div id=h></div><iframe id=x></iframe><script>"
    "var r=document.getElementById('h').attachShadow({mode:'open'});r.innerHTML='<input list=l style=width:100%;height:100%;border:0;padding:0;margin:0;display:block;background:#ff0000;font:20px/1 sans-serif><datalist id=l><option value=apple><option value=avocado></datalist>';"
    "document.getElementById('x').src='http://localhost:'+location.port+'/dlf-inner'</script>").encode()
DLF_INNER = (b"<!doctype html><title>in</title><style>html,body{margin:0;height:100%;background:#20a060}input{width:100%;height:50%;border:0;padding:0;margin:0;display:block;background:#0000ff;font:20px sans-serif}</style>"
    b"<input list=l><datalist id=l><option value=blueberry><option value=banana></datalist>")
# W10a: 다운로드 — 위에서부터 60pt 칸 넷: `download` 속성 링크(「hello world.txt」), 첨부(`report.txt`), 느린 3 MB 첨부(`big.zip`,
# 0.3 초마다 100 KB — 받는 중에 취소한다), 실행될 수 있는 파일의 `download` 링크(`tool.command` — 누른 것은 보류하지 않는다). DLW_AUTO 는 사용자 동작 없이 1.5 초 뒤 실행될 수 있는 파일(`run me.command`)을 받는다.
DLW = (b"<!doctype html><title>dlw</title><style>a{position:fixed;left:0;width:300px;height:60px;display:block;background:#f00}</style><body>"
    b"<a href='/dlw-file' download='hello world.txt' style='top:0'>A</a><a href='/dlw-att' style='top:80px;background:#00f'>B</a>"
    b"<a href='/dlw-big' style='top:160px;background:#0f0'>C</a><a href='/dlw-file' download='tool.command' style='top:240px;background:#ff0'>D</a>")
DLW_AUTO = (b"<!doctype html><title>dlw auto</title><body><script>setTimeout(function(){var a=document.createElement('a');a.href='/dlw-file';"
    b"a.download='run me.command';document.body.appendChild(a);a.click()},1500)</script>")
# W10b: 사용자 동작 없이 보통 파일(`plain.txt`)을 받는다 — 매번 묻기면 보류된다.
DLW_AUTO_PLAIN = DLW_AUTO.replace(b"run me.command", b"plain.txt")
# W10c: 첨부 링크 둘 — 위 절반은 `target=_blank`(팝업 브라우저를 이어 받은 새 탭), 아래 절반은 보통 링크(가운데 클릭 — 주소로 연
# 새 탭). 새 탭은 문서 없이 다운로드만 한다.
DLW_BLANK = (b"<!doctype html><title>dlw blank</title><style>html,body{margin:0;height:100%}a{position:fixed;left:0;width:100%;height:50%;display:block;background:#f00}</style><body>"
    b"<a href='/dlw-att' target=_blank style='top:0'>A</a><a href='/dlw-att' style='top:50%;background:#00f'>B</a>")
# 위 칸이 느린 3 MB(`big.zip`)인 판 — 닫힌 빈 탭의 받기가 주차로 이어지는지(적대 리뷰 5 회차: 작은 첨부는 탭이 닫히기 전에 끝났다).
DLW_BLANK_BIG = DLW_BLANK.replace(b"href='/dlw-att' target=_blank", b"href='/dlw-big' target=_blank")
# W10d: 위 절반 — 새 탭(이어 받은 팝업)이 문서를 연 뒤 느린 3 MB 를 받고 1.5 초 뒤 스스로 닫는다(`window.close`). 아래 절반 — 누르면
# 느린 3 MB 팝업을 열고(문서 없이 받기만 해 maru 가 그 탭을 닫아 주차한다) 4 초 뒤 연 페이지가 그 팝업을 닫는다(`w.close()`).
DLW_SELFCLOSE = (b"<!doctype html><title>dlw selfclose</title><style>html,body{margin:0;height:100%}a,div{position:fixed;left:0;width:100%;height:50%;display:block;background:#f00}</style><body>"
    b"<a href='/dlw-selfclose-pop' target=_blank style='top:0'>A</a><div id=b style='top:50%;background:#00f'>B</div><script>"
    b"document.getElementById('b').onclick=function(){var w=window.open('/dlw-big');setTimeout(function(){w.close()},4000)}</script>")
DLW_SELFCLOSE_POP = (b"<!doctype html><title>pop</title><body><script>var a=document.createElement('a');a.href='/dlw-big';document.body.appendChild(a);"
    b"a.click();setTimeout(function(){window.close()},1500)</script>")
# W6b: 툴팁 — 왼쪽 위(본문 폭 50%·높이 60%)에 두 줄 title, 나머지는 title 없음.
TIP = ("<!doctype html><title>tip</title><style>html,body{margin:0;height:100%;background:#20a060}"
    "#a{position:fixed;left:0;top:0;width:50%;height:60%;background:#ff0000}</style><body>"
    "<div id=a title='A tip&#10;line2'>a</div>").encode()
# W6c②: 우클릭 메뉴 — 왼쪽 위 링크 칸(본문 폭 50%·높이 30% — 글이 없는 자리를 누르면 낱말이 골라지지 않는다), 그 아래 입력 칸
# (글 「abc」 — 오른쪽 빈 자리를 우클릭하면 낱말이 골라지지 않는다), 오른쪽 위 빈 곳, 그 아래 큰 글 「hello world」(두 번 눌러
# 고른다), 오른쪽 아래는 우클릭하면 0.5 초 뒤 이동하는 칸(메뉴가 떠 있는 채 닫히는지). 불러옴·입력·
# 오른쪽 뗌을 `/ev` 로 알린다. 왼쪽 아래는 http 이미지(W6h① — 새 탭에서 이미지 열기).
MENU = ("<!doctype html><title>menu</title><style>html,body{margin:0;height:100%;background:#20a060;font:28px sans-serif}"
    "#l{position:fixed;left:0;top:0;width:50%;height:30%;display:block;background:#ff0000}"
    "#i{position:fixed;left:0;top:45%;width:50%;height:15%;font:28px sans-serif}"
    "#p{position:fixed;left:50%;top:35%;font:60px sans-serif;margin:0}"
    "#n{position:fixed;left:50%;top:60%;width:50%;height:40%;background:#0000ff}</style><body>"
    "<a id=l href='/cm-target'>link</a><input id=i value='abc'><p id=p>hello world</p><div id=n></div>"
    "<img id=g src='/img/cat.png' style='position:fixed;left:0;top:65%;width:50%;height:30%'><script>"
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
        elif self.path == "/dl-app":
            body = DL
        elif self.path == "/dl-auto":
            body = DLAUTO
        elif self.path == "/dlf-app":
            body = DLF
        elif self.path == "/dlf-inner":
            body = DLF_INNER
        elif self.path.startswith("/cm-app"):
            body = MENU
        elif self.path == "/dlw-app":
            body = DLW
        elif self.path == "/dlw-auto":
            body = DLW_AUTO
        elif self.path == "/dlw-auto-plain":
            body = DLW_AUTO_PLAIN
        elif self.path == "/dlw-blank":
            body = DLW_BLANK
        elif self.path == "/dlw-blank-big":
            body = DLW_BLANK_BIG
        elif self.path == "/dlw-selfclose":
            body = DLW_SELFCLOSE
        elif self.path == "/dlw-selfclose-pop":
            body = DLW_SELFCLOSE_POP
        elif self.path in ("/dlw-file", "/dlw-att"):
            att = self.path == "/dlw-att"
            body = b"attached\n" if att else b"hello\n"
            self.send_response(200); self.send_header('Content-Type', 'text/plain' if att else 'application/octet-stream'); self.send_header('Content-Length', str(len(body)))
            if att: self.send_header('Content-Disposition', 'attachment; filename="report.txt"')
            self.end_headers(); self.wfile.write(body)
            return
        elif self.path == "/dlw-big":
            # 한 스레드 서버 — 받는 쪽이 취소해 끊으면 쓰기가 실패해 이 요청만 끝난다(그동안 다른 요청은 기다린다).
            import time
            self.send_response(200); self.send_header('Content-Type', 'application/zip'); self.send_header('Content-Length', str(30 * 104858))
            self.send_header('Content-Disposition', 'attachment; filename="big.zip"'); self.end_headers()
            try:
                for _ in range(30):
                    self.wfile.write(b'x' * 104858); self.wfile.flush(); time.sleep(0.3)
            except OSError:
                pass
            return
        elif self.path == "/tip-app":
            body = TIP
        elif self.path == "/dnd-app":
            body = DND
        elif self.path.startswith("/tone.wav"):
            # W6h②: 0.2 초 무음 WAV(8 kHz 모노 16 비트) — 오디오 우클릭 메뉴.
            import struct
            pcm = b"\x00\x00" * 1600
            body = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm
            self.send_response(200); self.send_header('Content-Type', 'audio/wav'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        elif self.path == "/media-app":
            # W6h②: 같은 주소 오디오 둘(본문 위쪽 왼·오른 절반 — 주소로는 어느 것인지 모른다, 우클릭한 자리의 요소를 바꿔야 한다).
            # 연속 재생 상태가 바뀌면 `/ev` 로 알린다(왼·오른 두 자리 숫자).
            body = (b"<!doctype html><title>media</title><style>html,body{margin:0;height:100%;background:#20a060}"
                    b"audio{position:fixed;top:0;width:50%;height:30%}</style><body><audio id=a controls src='/tone.wav?d' style='left:0'></audio>"
                    b"<audio id=b controls src='/tone.wav?d' style='left:50%'></audio><script>"
                    b"var a=document.getElementById('a'),b=document.getElementById('b'),last='00';setInterval(function(){var v=''+(+a.loop)+(+b.loop);if(v!==last){last=v;new Image().src='/ev?e=loop&v='+v+'&t='+Date.now()}},100);"
                    b"</script>")
        elif self.path == "/tick-app":
            # W6i: 페이지마다 다른 번호로 0.3 초마다 `/ev` 를 보낸다(닫힌 창의 페이지가 아직 도는지 본다).
            body = (b"<!doctype html><title>tick</title><body>tick<script>var p=Math.random().toString(36).slice(2,8);"
                    b"setInterval(function(){new Image().src='/ev?e=tick&p='+p+'&t='+Date.now()},300)</script>")
        elif self.path.startswith("/alert-app"):
            # W6k: 뜬 뒤 1.5 초에 alert 를 띄운다(`?loop` 이면 끝없이).
            again = b"for(;;)" if "loop" in self.path else b""
            body = b"<!doctype html><title>alert</title><body>alert<script>setTimeout(function(){" + again + b"alert('hold')},1500)</script>"
        elif self.path == "/upload-app":
            # W6l②: 보통의 업로드 칸 — 끌기에 파일(`Files`)이 있을 때만 받는다(dragover 에서 types 를 본다). 받으면 이름·크기를 알린다.
            body = (b"<!doctype html><title>upload</title><style>html,body{margin:0;height:100%;background:#ddd}</style><body><script>"
                    b"function ping(q){new Image().src='/ev?'+q+'&t='+Date.now()}"
                    b"function files(e){return [].indexOf.call(e.dataTransfer.types,'Files')>=0}"
                    b"addEventListener('dragover',function(e){if(files(e)){e.preventDefault();e.dataTransfer.dropEffect='copy'}});"
                    b"addEventListener('drop',function(e){e.preventDefault();var f=e.dataTransfer.files,n=[];for(var i=0;i<f.length;i++)n.push(f[i].name+':'+f[i].size);"
                    b"ping('e=upload&names='+encodeURIComponent(n.join(',')))});ping('e=ready')</script>")
        elif self.path.startswith("/ld-"):
            # W6l①: 놓은 링크가 연 페이지 — 0.3 초마다 자기 경로로 `/ev` 를 보낸다(어느 탭이 남고 바뀌었는지 가른다).
            body = (b"<!doctype html><title>ld</title><body>ld<script>setInterval(function(){new Image().src='/ev?e=alive&u="
                    + self.path.encode() + b"&t='+Date.now()},300)</script>")
        elif self.path.startswith("/unload-app"):
            # W6j: 0.3 초마다 `/ev` 를 보내고, 클릭하면 떠나기 확인을 건다(`?hang` 이면 그 처리기가 6 초 멈춘다).
            hang = b"var t=Date.now();while(Date.now()-t<6000);" if "hang" in self.path else b""
            body = (b"<!doctype html><title>unload</title><body style='margin:0;height:100%'>unload<script>var p=Math.random().toString(36).slice(2,8);"
                    b"function ping(q){new Image().src='/ev?'+q+'&p='+p+'&t='+Date.now()}setInterval(function(){ping('e=tick')},300);"
                    b"addEventListener('click',function(){window.onbeforeunload=function(e){" + hang + b"e.preventDefault();e.returnValue='x';return 'x'};ping('e=armed')});</script>")
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
check(len(shown) > 1 and shown[1] == '새 탭에서 링크 열기|새 창에서 링크 열기|—|링크 주소 복사', f'the link menu (no text under the pointer) is open link in new tab · new window — copy link address ({shown[1] if len(shown) > 1 else None})')
edit = re.compile(r'^그림 이모티콘 & 기호\|—\|실행 취소\(off\)\|다시 실행\(off\)\|—\|잘라내기\(off\)\|복사\(off\)\|붙여넣기(\(off\))?\|붙여넣고 스타일 일치시킴(\(off\))?\|모두 선택$')
check(len(shown) > 2 and bool(edit.match(shown[2])), f'the input menu is emoji — undo · redo — cut · copy · paste · paste and match style · select all ({shown[2] if len(shown) > 2 else None})')
selection = "'\u2068hello\u2069' 찾기|—|복사|Google에서 '\u2068hello\u2069' 검색|—|음성▸[말하기 시작|말하기 중지(off)]|—|서비스▸[]"
check(len(shown) > 3 and shown[3] == selection, f"a selected word is look up — copy · search Google — speech ▸ — services ▸ ({shown[3] if len(shown) > 3 else None})")
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

# ── W6h①: 우클릭 메뉴 빈칸 — 새 창에서 링크 열기·새 탭에서 이미지 열기·선택한 글 검색 ─────────────────────────────
# 링크 메뉴의 「새 창에서 링크 열기」는 새 maru 창을 만들어 그 창에 웹 탭으로 연다(사용자 결정 2026-10-05). 이미지 메뉴의 「새 탭에서
# 이미지 열기」는 뒤 탭으로 그 이미지를, 선택한 글 메뉴의 「…에서 '…' 검색」은 설정 `browser.search-url`(여기서는 이 시험 서버)로
# 앞 탭을 연다. 문구에 방향 격리 문자(U+2068·U+2069)가 들어가 대본은 파이썬으로 만든다.
printf 'ui.language = ko\nbrowser.search-url = http://127.0.0.1:%s/search?q=%%s\n' "$port" > "$root/mh.conf"
python3 - "$root/mh.txt" <<'PY'
import sys
fsi, pdi = '⁨', '⁩'
open(sys.argv[1], 'w', encoding='utf-8').write(f"""sleep 7000
view down 0.395 0.30 0 0 1
view up 0.395 0.30 0 0 1
sleep 900
menupick 새 창에서 링크 열기
sleep 4000
firstwindow
mark image
view down 0.395 0.80 0 0 1
view up 0.395 0.80 0 0 1
sleep 900
menupick 새 탭에서 이미지 열기
sleep 1500
mark search
view down 0.655 0.49 0 0
view up 0.655 0.49 0 0
view down 0.655 0.49 0 0 0 2
view up 0.655 0.49 0 0 0 2
sleep 300
view down 0.655 0.49 0 0 1
view up 0.655 0.49 0 0 1
sleep 900
menupick 127.0.0.1에서 '{fsi}hello{pdi}' 검색
sleep 2500
""")
PY
: > "$root/requests.log"
run_app /cm-app 26000 "$root/mh.summary" MARU_WEB_OSR_TEST_INPUT="$root/mh.txt" MARU_WEB_OSR_TEST_CONTEXT_MENU=1 MARU_CONFIG="$root/mh.conf"
grep -a '^osr-test menu\|^osr-test newwindow\|^osr-test newtab\|^osr-test mark\|^osr-test opentab' "$root/app-cm-app.log" > "$root/mh.report" || true
cat "$root/mh.report"
python3 - "$root/mh.report" "$root/requests.log" <<'PY' || fail "the W6h① context menu items did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
shown = [l[len('osr-test menu shown items='):] for l in report if l.startswith('osr-test menu shown items=')]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check(len(shown) == 3 and 'osr-test menu pick-missing' not in ' '.join(report), f'three menus were shown and every pick was found ({shown})')
# 새 창의 세션(Swift 가 적는다)과 탭을 연 세션(Zig 가 적는다)이 같다 — 원래 창에 탭이 생기지 않았다.
opened = [l for l in report if l.startswith('osr-test newwindow opened ')]
new_session = opened[0].split('session=')[1] if len(opened) == 1 and 'session=' in opened[0] else None
check(len(opened) == 1 and opened[0].startswith('osr-test newwindow opened windows=2 tab=true') and f'osr-test opentab session={new_session} opened=true' in report and requests.count('/cm-target') == 1,
      f'open link in new window made a second maru window whose own web tab loaded the link ({opened} · {[l for l in report if "opentab" in l]} · /cm-target {requests.count("/cm-target")})')
image_tabs = [l for l in report if l.startswith('osr-test newtab') and 'placement=background' in l]
# 이미지 우클릭(그 뗌의 `/ev`) 뒤, 검색 전에 그 이미지가 다시 불렸다 — 새 탭이 그 이미지를 연다. (새 창도 시험 페이지를 하나 열어
# — `MARU_WEB_PANEL` — 이미지가 그 전에도 불린다. 수로 세지 않고 차례로 본다.)
import re
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
def t_of(line):
    m = re.search(r'[?&]t=(\d+)', line)
    return int(m.group(1)) if m else 0
press = next((i for i, l in enumerate(requests) if l.startswith('/ev?e=up&b=2') and t_of(l) >= marks.get('image', 1 << 62)), None)
search = next((i for i, l in enumerate(requests) if l.startswith('/search')), len(requests))
image_loaded = press is not None and '/img/cat.png' in requests[press:search]
check(len(shown) > 1 and shown[1] == '새 탭에서 이미지 열기|이미지 복사|이미지 주소 복사' and len(image_tabs) == 1 and image_loaded,
      f'the image menu opens the image in a background tab ({shown[1] if len(shown) > 1 else None} · {image_tabs} · image requested after the right click {image_loaded})')
label = "127.0.0.1에서 '⁨hello⁩' 검색"
search_tabs = [l for l in report if l.startswith('osr-test newtab') and 'placement=foreground' in l]
check(len(shown) > 2 and label in shown[2].split('|') and len(search_tabs) == 1 and '/search?q=hello' in requests,
      f'the selection menu searches the configured engine in a foreground tab ({shown[2] if len(shown) > 2 else None} · {search_tabs} · {[l for l in requests if l.startswith("/search")]})')
sys.exit(0 if ok else 1)
PY

# ── W6h②: 동영상·오디오 우클릭 메뉴 ────────────────────────────────────────────────────────────────────────
# 오디오를 우클릭하면 「연속 재생 · 모든 제어 기능 표시 — 새 탭에서 오디오 열기 · 오디오 주소 복사」(Chrome 154 — 오디오의 제어 기능은
# 켜져 있고 끌 수 없다: 체크 표시 ✓·(off)). 같은 주소 오디오 둘 중 오른쪽을 우클릭해 「연속 재생」을 고르면 그 오디오만 켜지고(sidecar 가
# DevTools 로 우클릭한 자리의 요소를 바꾼다 — 배율 2 앱의 좌표로), 다음 메뉴에는 체크 표시가 붙는다.
printf 'ui.language = ko\n' > "$root/media.conf"
cat > "$root/media.txt" <<'SCRIPT'
sleep 7000
view down 0.79 0.30 0 0 1
view up 0.79 0.30 0 0 1
sleep 900
menupick 연속 재생
sleep 1200
view down 0.79 0.30 0 0 1
view up 0.79 0.30 0 0 1
sleep 900
menuclose
sleep 500
SCRIPT
: > "$root/requests.log"
run_app /media-app 16000 "$root/media.summary" MARU_WEB_OSR_TEST_INPUT="$root/media.txt" MARU_WEB_OSR_TEST_CONTEXT_MENU=1 MARU_CONFIG="$root/media.conf"
grep -a '^osr-test menu' "$root/app-media-app.log" > "$root/media.report" || true
cat "$root/media.report"
python3 - "$root/media.report" "$root/requests.log" <<'PY' || fail "the media context menu did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
shown = [l[len('osr-test menu shown items='):] for l in report if l.startswith('osr-test menu shown items=')]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
first = '연속 재생|모든 제어 기능 표시✓(off)|—|새 탭에서 오디오 열기|오디오 주소 복사'
check(len(shown) == 2 and shown[0] == first, f'the audio menu is loop · show all controls (checked, off for audio) — open audio in new tab · copy audio address ({shown})')
loops = [l for l in requests if l.startswith('/ev?e=loop')]
check(len(loops) == 1 and loops[0].startswith('/ev?e=loop&v=01') and len(shown) == 2 and shown[1].startswith('연속 재생✓|'),
      f'picking loop turned only the right-clicked one of two same-address audios on and the next menu shows it checked ({loops} · {shown[1] if len(shown) > 1 else None})')
sys.exit(0 if ok else 1)
PY

# ── W6i: 닫은 창의 Chromium 탭 ──────────────────────────────────────────────────────────────────────────────
# 창 둘 중 하나를 닫으면 그 창의 페이지도 닫힌다. 창 닫기가 탭을 먼저 부수지 않는 길(영속 세션을 끔 — 창에 실행 중 터미널이
# 있어도 host 를 거치지 않는다)에서 닫은 창의 페이지가 앱이 끝날 때까지 보이지 않게 돌았다. 두 창이 같은 시험 페이지를 띄우고
# (`MARU_WEB_PANEL` — 새 창에도), 닫은 뒤에는 한 페이지만 요청을 보내야 한다.
printf 'ui.language = ko\nsession.keep-alive-after-quit = false\n' > "$root/wclose.conf"
cat > "$root/wclose.txt" <<'SCRIPT'
sleep 8000
mark second
newwindow
sleep 3500
mark close
closewindow
sleep 5000
mark end
SCRIPT
: > "$root/requests.log"
run_app /tick-app 18000 "$root/wclose.summary" MARU_WEB_OSR_TEST_INPUT="$root/wclose.txt" MARU_CONFIG="$root/wclose.conf"
# 보고 줄은 앱의 요약 출력(stdout)과 한 줄에 섞일 수 있다(실측 — `file_osr-test mark …`) — 줄 중간에서도 찾는다.
grep -ao 'osr-test mark [a-z]* [0-9]*\|osr-test closewindow .*' "$root/app-tick-app.log" > "$root/wclose.report" || true
cat "$root/wclose.report"
python3 - "$root/wclose.report" "$root/requests.log" <<'PY' || fail "closing a window did not close its Chromium tab"
import sys
report = [l.strip() for l in open(sys.argv[1])]
ticks = []
for l in open(sys.argv[2]):
    if l.startswith('/ev?e=tick&'):
        q = dict(kv.split('=', 1) for kv in l.strip().split('?', 1)[1].split('&'))
        ticks.append((q['p'], int(q['t'])))
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
closed = [l for l in report if l.startswith('osr-test closewindow')]
check(closed == ['osr-test closewindow before=2 after=1'], f'the second window closed ({closed})')
second, close, end = marks.get('second', 0), marks.get('close', 0), marks.get('end', 0)
# 첫 창의 페이지는 가장 먼저 요청한 페이지다(화면이 잠기면 둘째 창을 열 때까지 아직 안 떴을 수 있다 — 시각으로 가르지 않는다).
# 다른 페이지는 둘째 창을 연 뒤에 처음 요청해야 한다. 닫은 뒤 살아 있어야 하는 것은 첫 창의 페이지다(다른 창의 것을 닫지 않는다).
starts = {}
for p, t in ticks:
    starts[p] = min(starts.get(p, t), t)
order = sorted(starts, key=starts.get)
first = set(order[:1]) if len(order) == 2 and starts[order[1]] > second > 0 else set()
before = {p for p, t in ticks if t < close}
after = {p for p, t in ticks if close + 1500 < t <= end}
check(len(first) == 1 and len(before) == 2 and after == first,
      f'both pages ran while the windows were open and only the first window page runs after closing the second ({len(first)} first · {len(before)} before · {len(after)} after, kept the first {after == first} · {len(ticks)} requests)')
sys.exit(0 if ok else 1)
PY

# ── W6l②: 그림 데이터를 파일로 놓기 ──────────────────────────────────────────────────────────────────────────
# 그림만 있는 끌기(다른 앱이 그림 자체를 끌 때 — 파일·주소·글 없이 PNG)는 본문에 들어올 때 `image.png` 파일이 된다(사용자 결정 2026-10-06).
# 보통의 업로드 칸(끌기에 Files 가 있을 때만 받는다)이 그 파일을 받는다. 글이 함께 있으면 그림을 붙이지 않는다 — 업로드 칸은 받지 않는다.
mkdir -p "$root/drop2"
python3 - "$root/drop2/pic.png" <<'PY'
import sys, zlib, struct
w, h = 4, 3
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
cat > "$root/imgdrop.txt" <<SCRIPT
sleep 8000
drag enter 0.5 0.5 0 0 png $root/drop2/pic.png
sleep 300
drag move 0.5 0.5 0 0
sleep 300
drag move 0.5 0.51 0 0
sleep 300
drag drop 0.5 0.51 0 0
sleep 1000
mark mixed
drag enter 0.5 0.5 0 0 pngtext $root/drop2/pic.png
sleep 300
drag move 0.5 0.5 0 0
sleep 300
drag move 0.5 0.51 0 0
sleep 300
drag drop 0.5 0.51 0 0
sleep 1000
mark tiffed
drag enter 0.5 0.5 0 0 tiff $root/drop2/pic.png
sleep 300
drag move 0.5 0.5 0 0
sleep 300
drag move 0.5 0.51 0 0
sleep 300
drag drop 0.5 0.51 0 0
sleep 1000
mark end
SCRIPT
: > "$root/requests.log"
run_app /upload-app 22000 "$root/imgdrop.summary" MARU_WEB_OSR_TEST_INPUT="$root/imgdrop.txt"
grep -ao 'osr-test drag [a-z]* [^ ]*\|osr-test mark [a-z]* [0-9]*' "$root/app-upload-app.log" > "$root/imgdrop.report" || true
cat "$root/imgdrop.report"
python3 - "$root/imgdrop.report" "$root/requests.log" "$(wc -c < "$root/drop2/pic.png" | tr -d ' ')" <<'PY' || fail "dropping image data did not give an upload field the image file"
import sys, urllib.parse
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
png_size = sys.argv[3]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
uploads = [urllib.parse.unquote(r.split('names=', 1)[1].split('&', 1)[0]) for r in requests if r.startswith('/ev?e=upload&')]
drops = [l for l in report if l.startswith('osr-test drag drop')]
check(uploads[:1] == [f'image.png:{png_size}'] and drops[:1] and drops[0].startswith('osr-test drag drop op=1'),
      f'image data alone dropped on an upload field arrives as the file image.png ({uploads} · {drops[:1]})')
check(len(drops) == 3 and not drops[1].startswith('osr-test drag drop op=1') and len(uploads) == 2,
      f'image data that comes with text is not turned into a file — the upload field does not take it ({uploads} · {drops})')
check(len(uploads) == 2 and uploads[1].startswith('image.png:') and uploads[1] != 'image.png:0' and drops[2].startswith('osr-test drag drop op=1'),
      f'TIFF-only image data (a screenshot) arrives as image.png too ({uploads} · {drops})')
sys.exit(0 if ok else 1)
PY

# ── W6l①: 링크를 탭 막대·주소 띠에 놓기 ───────────────────────────────────────────────────────────────────────
# 링크를 주소 띠에 놓으면 그 탭이, 웹 pane 의 빈 탭 막대에 놓으면 새 웹 탭이, 웹 탭 머리에 놓으면 그 탭이 그 주소를 부른다(Chrome 처럼 —
# 사용자 결정 2026-10-06). 허용하지 않는 주소(`javascript:`)는 거절된다. 자리는 Zig 의 hit-test 로 찾는다(대본 `droplink`).
printf 'ui.language = ko\n' > "$root/linkdrop.conf"
cat > "$root/linkdrop.txt" <<SCRIPT
sleep 7000
droplink band http://127.0.0.1:$port/ld-band
sleep 2000
mark newtab
droplink emptybar http://127.0.0.1:$port/ld-new
sleep 4000
mark webtab
droplink webtab http://127.0.0.1:$port/ld-tab
sleep 4000
mark js
droplink band javascript:alert(1)
sleep 4000
mark end
SCRIPT
: > "$root/requests.log"
# 숨은 탭은 신호가 1 초에 한 번이라 구간마다 4 초를 둔다(대본 약 22 초).
run_app /osr-smoke 28000 "$root/linkdrop.summary" MARU_WEB_OSR_TEST_INPUT="$root/linkdrop.txt" MARU_CONFIG="$root/linkdrop.conf"
grep -ao 'osr-test droplink [a-z]* [^ ]* ok=[a-z]*\|osr-test droplink none [a-z]*\|osr-test mark [a-z]* [0-9]*' "$root/app-osr-smoke.log" > "$root/linkdrop.report" || true
cat "$root/linkdrop.report"
python3 - "$root/linkdrop.report" "$root/requests.log" <<'PY' || fail "dropping a link on the tab bar or address bar did not open it as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
requests = [l.strip() for l in open(sys.argv[2])]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
def dropped(zone): return [l for l in report if l.startswith(f'osr-test droplink {zone} ')]
marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
order = [r for r in requests if r in ('/ld-band', '/ld-new', '/ld-tab')]
# 살아 있는 페이지(0.3 초 신호) — 시점 사이에 어느 경로의 페이지가 돌고 있었나.
alive = []
for r in requests:
    if r.startswith('/ev?e=alive&'):
        q = dict(kv.split('=', 1) for kv in r.split('?', 1)[1].split('&'))
        alive.append((q['u'], int(q['t'])))
def running(lo, hi): return {u for u, t in alive if marks.get(lo, 0) + 1200 < t < marks.get(hi, 0)}
check(dropped('band')[:1] and dropped('band')[0].endswith('ok=true') and any(u == '/ld-band' and t < marks.get('newtab', 0) for u, t in alive),
      f'a link dropped on the address band loads in that tab ({dropped("band")[:1]} · {order})')
# 새 탭: 앞 페이지(/ld-band)는 남고 /ld-new 가 함께 돈다(기존 탭을 바꾸지 않았다).
check(dropped('emptybar')[:1] and dropped('emptybar')[0].endswith('ok=true') and running('newtab', 'webtab') == {'/ld-band', '/ld-new'},
      f'a link dropped on empty tab bar space of a web pane opens a new web tab — the first page keeps running ({dropped("emptybar")} · {sorted(running("newtab", "webtab"))})')
# 웹 탭 머리(첫 웹 탭 — 활성이 아니다): 그 탭이 /ld-tab 으로 바뀌고 새 탭(/ld-new)은 그대로.
check(dropped('webtab')[:1] and dropped('webtab')[0].endswith('ok=true') and running('webtab', 'js') == {'/ld-new', '/ld-tab'} and order == ['/ld-band', '/ld-new', '/ld-tab'],
      f'a link dropped on a web tab header loads in that tab, not the active one ({dropped("webtab")} · {sorted(running("webtab", "js"))})')
check(len(dropped('band')) == 2 and dropped('band')[1].endswith('ok=false') and running('js', 'end') == {'/ld-new', '/ld-tab'},
      f'a javascript: link is refused and nothing navigates ({dropped("band")} · {sorted(running("js", "end"))})')
sys.exit(0 if ok else 1)
PY

# ── W6n: 안내 토스트가 떠 있는 동안의 hover ────────────────────────────────────────────────────────────────────
# 안내 토스트(입력을 막지 않는 알림)가 떠 있는 동안에도 hover 가 페이지로 가 툴팁이 달린다(W4b 의 오버레이 문이 토스트도 세어 사라졌다 —
# WebKit 탭은 원래 받는다). 토스트는 그대로 떠 있다(누름이 먼저 닫는다 — tester 가 본다). 설정의 엔진을 바꿔 다시 불러오면 토스트가 뜬다.
printf 'browser.engine = chromium\n' > "$root/toasttip.conf"
cat > "$root/toasttip.txt" <<'SCRIPT'
sleep 7000
config browser.engine = webkit
menu Reload Config
sleep 800
overlay
hover 0.40 0.33 0 0
sleep 300
hover 0.41 0.33 0 0
sleep 300
hover 0.42 0.34 0 0
sleep 1000
tooltip
overlay
SCRIPT
: > "$root/requests.log"
run_app /tip-app 14000 "$root/toasttip.summary" MARU_WEB_OSR_TEST_INPUT="$root/toasttip.txt" MARU_CONFIG="$root/toasttip.conf"
grep -ao 'osr-test overlay [a-z]*\|osr-test tooltip active=[a-z]*' "$root/app-tip-app.log" > "$root/toasttip.report" || true
cat "$root/toasttip.report"
python3 - "$root/toasttip.report" <<'PY' || fail "hover did not reach the page while a notice toast was up"
import sys
report = [l.strip() for l in open(sys.argv[1])]
ov = [l.split()[2] for l in report if l.startswith('osr-test overlay ')]
tips = [l for l in report if l.startswith('osr-test tooltip ')]
ok = ov == ['true', 'true'] and tips == ['osr-test tooltip active=true']
print(('PASS ' if ok else 'FAIL ') + f'hover reaches the page and its tooltip shows while a notice toast is up, and the toast stays ({ov} · {tips})')
sys.exit(0 if ok else 1)
PY

# ── W6m②: 제안 목록(datalist) ────────────────────────────────────────────────────────────────────────────
# 칸을 누르면 sidecar 가 보낸 목록을 maru 가 칸 바로 아래·왼쪽을 맞춘 macOS 네이티브 창(키 초점을 갖지 않는 자식 창 안의 표)으로
# 띄운다. 처음에는 아무것도 강조하지 않고(Chrome 154 실측), ↓↓↑ 로 옮긴 강조를 Enter 가 고르면 그 값이 페이지에 들어간다(change).
# 행 위의 움직임은 강조, 같은 행에서 누르고 떼면 고른다(대본 `dlmouse` — 창의 진짜 사건 처리기에 합성 사건). Esc 는 목록만 닫고
# 페이지에 가지 않으며, 닫힌 뒤의 ↓ 는 페이지가 받아 다시 연다. 열린 목록의 ↓ 는 페이지에 가지 않는다. 강조 없는 Enter 는 페이지로
# 간다(폼 제출). 대본 `datalist` 가 Zig 의 상태와 띄운 창(보임·행 수·표가 실제로 강조한 행·칸 아래인가·왼쪽 맞춤·잘린 행 수·첫
# 값·창 왼쪽 위의 view backing px)을 적는다. 앱 스크린샷은 Metal 화면만 찍어 네이티브 창이 담기지 않는다 — 그래서 스크린샷의 빨간
# 칸 왼쪽 아래와 창 왼쪽 위를 맞춰 자리를 따로 확인하고(dl-shot), 창 내용은 `dlsnap` 으로 받아 강조 색을 본다.
cat > "$root/dl-keys.txt" <<SCRIPT
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
datalist
dlsnap $root/dl-popup.png
key 125 U+F701
sleep 200
datalist
dlsnap $root/dl-popup-selected.png
key 125 U+F701
key 126 U+F700
sleep 200
datalist
key 36 U+D
sleep 1000
datalist
SCRIPT
cat > "$root/dl-mouse.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
dlmouse 2 move
sleep 200
datalist
dlmouse 3 down
dlmouse 3 up
sleep 1000
datalist
dlmouse 1 down
SCRIPT
# 행 위에서 누르고 창 밖에서 떼면 고르지 않는다(목록은 남는다). 움직임으로 생긴 강조는 창을 벗어나면 지워지고, 그때 Enter 는
# 페이지로 간다(지나가며 남은 강조를 고르지 않는다). 페이지 쪽에서 닫히면(문서 스크롤 — 대리 스크립트가 닫는다; 글자는 입력 소스에
# 따라 조합이 돼 쓰지 않는다) 창도 거둔다 — 적대 검증.
cat > "$root/dl-press.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
dlmouse 1 down
dlmouse -1 up
sleep 300
datalist
dlmouse 2 move
sleep 200
datalist
dlmouse -1 exit
sleep 200
datalist
key 36 U+D
sleep 500
wheel 0.80 0.80 0 0 -3
sleep 1500
datalist
SCRIPT
# 팔레트가 열리면 키 대상이 바뀌어 창을 거두고, 페이지는 초점을 잃어 목록을 닫는다 — 팔레트를 닫아도 다시 뜨지 않는다(Chrome 도
# 창이 초점을 되찾았다고 목록을 다시 띄우지 않는다).
# 뜬 직후(0.5 초 안)의 누르기는 고르지 않는다(페이지가 누를 자리에 목록을 띄워 누름을 고르기로 바꾸지 못하게 — W6m③ 적대 리뷰 3 회차),
# 그 뒤의 누르기는 고른다.
cat > "$root/dl-early.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 250
datalist
dlmouse 1 down
dlmouse 1 up
sleep 50
datalist
sleep 900
dlmouse 1 down
dlmouse 1 up
sleep 1000
datalist
SCRIPT
cat > "$root/dl-palette.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
datalist
action toggle_command_palette
sleep 500
datalist
key 53 U+1B
sleep 1500
datalist
SCRIPT
cat > "$root/dl-auto.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.80 0.80 0 0 0
mouse 3 0.80 0.80 0 0 0
sleep 4000
datalist
SCRIPT
cat > "$root/dl-shot.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
datalist
SCRIPT
cat > "$root/dl-esc.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.33 0 0 0
mouse 3 0.40 0.33 0 0 0
sleep 1500
key 53 U+1B
sleep 300
datalist
key 125 U+F701
sleep 1500
datalist
key 36 U+D
sleep 500
datalist
key 125 U+F701
sleep 300
datalist
key 53 U+1B
sleep 1000
SCRIPT
: > "$root/requests.log"
rm -f "$root/dl-popup.png" "$root/dl-popup-selected.png"
for dl in keys mouse esc press palette early; do
  : > "$root/requests.log"
  run_app /dl-app 14000 "$root/dl-$dl.summary" MARU_WEB_OSR_TEST_INPUT="$root/dl-$dl.txt"
  grep -ao 'osr-test datalist [a-z0-9= -]*\|osr-test dl-miss\|osr-test dlsnap ok' "$root/app-dl-app.log" | sed 's/ *$//' > "$root/dl-$dl.report" || true
  cp "$root/requests.log" "$root/dl-$dl.requests"
done
: > "$root/requests.log"
run_app /dl-auto 14000 "$root/dl-auto.summary" MARU_WEB_OSR_TEST_INPUT="$root/dl-auto.txt"
grep -ao 'osr-test datalist [a-z0-9= -]*' "$root/app-dl-auto.log" | sed 's/ *$//' > "$root/dl-auto.report" || true
cp "$root/requests.log" "$root/dl-auto.requests"
: > "$root/requests.log"
run_app /dl-app 20000 "$root/dl-shot.summary" MARU_WEB_OSR_TEST_INPUT="$root/dl-shot.txt" MARU_SCREENSHOT="$root/dl-shot.ppm" MARU_SCREENSHOT_DELAY_MS=11000
grep -ao 'osr-test datalist [a-z0-9= -]*' "$root/app-dl-app.log" | sed 's/ *$//' > "$root/dl-shot.report" || true
python3 - "$root" <<'PY' || fail "the datalist window, keys, mouse or Esc did not behave like Chrome"
import sys, os, zlib, struct
root = sys.argv[1]
def lines(name): return [l.strip() for l in open(os.path.join(root, name)) if l.strip()]
def ev(name): return [l.split('&t=')[0] for l in lines(name) if l.startswith('/ev')]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
def parse(l): return dict(kv.split('=', 1) for kv in l.split()[2:] if '=' in kv) if l.startswith('osr-test datalist') else l
def shown(sel): return {'open': 'true', 'count': '5', 'selected': str(sel), 'win': 'shown', 'rows': '5', 'sel': str(sel), 'below': 'true', 'left': 'true', 'clip': '0', 'first': 'apple'}
closed = {'open': 'false', 'count': '0', 'selected': '-1', 'win': 'hidden'}
def same(got, want):
    if len(got) != len(want): return False
    for g, w in zip(got, want):
        g = parse(g)
        if isinstance(w, dict):
            if not isinstance(g, dict) or {k: g.get(k) for k in w} != w: return False
        elif g != w: return False
    return True
keys = lines('dl-keys.report'); kreq = ev('dl-keys.requests')
check(same(keys, [shown(-1), 'osr-test dlsnap ok', shown(0), 'osr-test dlsnap ok', shown(0), closed]),
      f'the list window opens right under the field with its left edge aligned, no row clipped and nothing highlighted, ↓↓↑ moves the table highlight and Enter picks it ({keys})')
check('/ev?e=change&v=apple' in kreq and not any('k=Arrow' in r for r in kreq) and not any('k=Enter' in r for r in kreq),
      f'the picked value reaches the page, and ↓·↑·Enter on the open list do not ({kreq})')
def png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    i, idat, w = 8, b'', 0
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8]); c = d[i + 8:i + 8 + n]; i += 12 + n
        if t == b'IHDR': w, h, depth, ctype = struct.unpack('>IIBB', c[:10]); assert depth == 8 and ctype in (2, 6)
        elif t == b'IDAT': idat += c
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp; rows = []; prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, bpp, rows
def changed(a, b, top, bottom):
    # 두 스냅숏의 한 행 띠(pt — 위 여백 4, 행 22)에서 색이 크게 달라진 화소의 비율. 강조색은 시스템 설정을 따르므로 색 대신 차이를 본다.
    wa, ha, pa, ra = a; wb, hb, pb, rb = b
    if (wa, ha) != (wb, hb): return 1.0
    sy = ha / 118.0
    hit = total = 0
    for y in range(int(top * sy), int(bottom * sy)):
        for x in range(int(wa * 0.15), int(wa * 0.85)):
            total += 1
            hit += sum(abs(ra[y][x * pa + i] - rb[y][x * pb + i]) for i in range(3)) > 60
    return hit / max(total, 1)
pngs = [os.path.join(root, n) for n in ('dl-popup.png', 'dl-popup-selected.png')]
if all(os.path.exists(p) for p in pngs):
    a, b = png(pngs[0]), png(pngs[1])
    first, third = changed(a, b, 8, 22), changed(a, b, 52, 66)
    check(first > 0.4 and third < 0.05, f'the window paints the first row as highlighted only once ↓ highlights it and leaves the other rows alone (snapshots differ: first row {first:.2f} · third row {third:.2f})')
else:
    check(False, 'the list window snapshots exist (dl-popup.png · dl-popup-selected.png)')
mouse = lines('dl-mouse.report'); mreq = ev('dl-mouse.requests')
check(same(mouse, [shown(2), closed, 'osr-test dl-miss']) and '/ev?e=change&v=date' in mreq,
      f'moving over a row highlights it, a click on a row picks it and the window goes away ({mouse} · {mreq})')
press = lines('dl-press.report'); preq = ev('dl-press.requests')
check(same(press, [shown(-1), shown(2), shown(-1), closed])
      and not any(r.startswith('/ev?e=change') for r in preq) and '/ev?e=kd&k=Enter' in preq,
      f'a press on a row released outside the window picks nothing, a hover highlight clears when the pointer leaves so Enter reaches the page, and a page-side close hides the window ({press} · {preq})')
esc = lines('dl-esc.report'); ereq = ev('dl-esc.requests')
kd = [r for r in ereq if r.startswith('/ev?e=kd')]
check(same(esc, [closed, shown(-1), shown(-1), shown(0)])
      and kd == ['/ev?e=kd&k=ArrowDown', '/ev?e=kd&k=Enter'] and not any(r.startswith('/ev?e=change') for r in ereq),
      f'Esc closes only the list, ↓ on the closed field reaches the page and reopens it, Enter on the open list with nothing highlighted reaches the page and picks nothing ({esc} · {kd})')
auto = lines('dl-auto.report'); areq = ev('dl-auto.requests')
check(same(auto, [closed]) and '/ev?e=in&tr=true' in areq and '/ev?e=md&b=0' in areq,
      f'a list the page opens by itself (execCommand — a trusted input event) without user input does not show ({auto} · {areq})')
early = lines('dl-early.report'); erq = ev('dl-early.requests')
check(same(early, [shown(-1), shown(-1), closed]) and erq.count('/ev?e=change&v=banana') == 1,
      f'a click right after the window appears does not pick, a later click does ({early} · {erq})')
pal = lines('dl-palette.report')
check(same(pal, [shown(-1), closed, closed]), f'opening the command palette hides the window and closing it does not bring the list back ({pal})')
# 자리 — 스크린샷의 빨간 칸(왼쪽 아래)과 창 왼쪽 위(view backing px)가 맞는가. 보고의 below·left 는 같은 변환끼리의 비교라 따로 본다.
shot = [parse(l) for l in lines('dl-shot.report')]
spath = os.path.join(root, 'dl-shot.ppm')
if shot and isinstance(shot[0], dict) and 'atx' in shot[0] and os.path.exists(spath):
    d = open(spath, 'rb').read()
    _, dims, _, px = d.split(b'\n', 3)
    w, h = map(int, dims.split())
    red = bytes.fromhex('ff0000'); xs, ys = [], []
    for y in range(h):
        row = px[y * w * 3:(y + 1) * w * 3]
        i = row.find(red)
        while i != -1:
            if i % 3 == 0: xs.append(i // 3); ys.append(y)
            i = row.find(red, i + 3)
    ax, ay = int(shot[0]['atx']), int(shot[0]['aty'])
    check(bool(xs) and abs(ax - min(xs)) <= 3 and abs(ay - (max(ys) + 1)) <= 3,
          f'the window sits at the bottom-left corner of the field in the screenshot (window {ax},{ay} · field {min(xs) if xs else None},{max(ys) + 1 if ys else None})')
else:
    check(False, f'the placement run reported the window and took a screenshot ({shot})')
sys.exit(0 if ok else 1)
PY

# ── W6m③: shadow DOM·다른 출처 iframe 안의 칸 ────────────────────────────────────────────────────────────────
# 열린 shadow DOM 안의 빨간 칸을 누르면 그 칸 바로 아래에 목록 창, 다른 출처 iframe(OOPIF) 안의 파란 칸을 누르면(그 프레임은 누름의
# screen − client 로 자기 원점을 안다) 그 칸 바로 아래에 목록 창 — 스크린샷의 빨강·파랑 칸 왼쪽 아래와 창 왼쪽 위(view backing px)를
# 맞춘다(앱 스크린샷에는 네이티브 창이 담기지 않는다). 파란 칸에 글자(maru 의 키 경로 — iframe 이 받은 신뢰된 키 누름)를 치면 다시
# 거른 목록이 그 자리에 뜬다.
cat > "$root/dlf.txt" <<'SCRIPT'
sleep 7000
mouse 1 0.40 0.20 0 0 0
mouse 3 0.40 0.20 0 0 0
sleep 1500
datalist
mouse 1 0.40 0.58 0 0 0
mouse 3 0.40 0.58 0 0 0
sleep 1500
datalist
key 11 U+62
sleep 1000
datalist
SCRIPT
: > "$root/requests.log"
run_app /dlf-app 24000 "$root/dlf.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlf.txt" MARU_SCREENSHOT="$root/dlf.ppm" MARU_SCREENSHOT_DELAY_MS=13500 # 스크린샷은 대본이 끝난 뒤(찍으면 앱이 끝난다)
grep -ao 'osr-test datalist [a-z0-9= -]*' "$root/app-dlf-app.log" | sed 's/ *$//' > "$root/dlf.report" || true
python3 - "$root" <<'PY' || fail "the datalist window did not open under a field inside shadow DOM or a cross-origin iframe"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
rep = [dict(kv.split('=', 1) for kv in l.split()[2:] if '=' in kv) for l in open(os.path.join(root, 'dlf.report')) if l.strip()]
d = open(os.path.join(root, 'dlf.ppm'), 'rb').read() if os.path.exists(os.path.join(root, 'dlf.ppm')) else b''
def bbox(rgb):
    if not d: return None
    _, dims, _, px = d.split(b'\n', 3)
    w, h = map(int, dims.split())
    xs, ys = [], []
    for y in range(h):
        row = px[y * w * 3:(y + 1) * w * 3]
        i = row.find(rgb)
        while i != -1:
            if i % 3 == 0: xs.append(i // 3); ys.append(y)
            i = row.find(rgb, i + 3)
    return (min(xs), max(ys) + 1) if xs else None
def placed(r, box):
    return box is not None and r.get('win') == 'shown' and abs(int(r.get('atx', -99)) - box[0]) <= 3 and abs(int(r.get('aty', -99)) - box[1]) <= 3
red, blue = bbox(bytes.fromhex('ff0000')), bbox(bytes.fromhex('0000ff'))
sh = rep[0] if rep else {}
fr = rep[1] if len(rep) > 1 else {}
check(sh.get('count') == '2' and sh.get('first') == 'apple' and placed(sh, red), f'a field inside an open shadow root opens the list right under it ({sh} · field {red})')
check(fr.get('count') == '2' and fr.get('first') == 'blueberry' and placed(fr, blue), f'a field inside a cross-origin iframe opens the list right under it ({fr} · field {blue})')
ty = rep[2] if len(rep) > 2 else {}
check(ty.get('count') == '2' and ty.get('first') == 'blueberry' and placed(ty, blue), f'typing in the cross-origin iframe field refilters the list at the same place ({ty})')
sys.exit(0 if ok else 1)
PY

# ── W10a: 다운로드 ───────────────────────────────────────────────────────────────────────────────────────────
# 누른 링크의 다운로드는 `~/Downloads` 에 받는다 — 같은 이름이면 「(1)」을 붙이고, 끝나면 Chromium 이 격리 표지를 붙이며 받는 동안의
# 임시 파일(`.maru-part`)은 남지 않는다. 사용자가 시작했으니 목록 창이 뜬다. 받는 중 취소(목록의 취소 단추와 같은 길)하면 그 파일은
# 지워진다. 실행될 수 있는 파일도 사용자가 눌러 받으면 보류하지 않는다. 페이지가 스스로 받으려는 실행될 수 있는 파일은 보류해
# (목록 창은 뜬다) 받기를 누르기 전에는 디스크에 없다.
cat > "$root/dlw.txt" <<'SCRIPT'
sleep 7000
mouse 1 0 0 338 142 0
mouse 3 0 0 338 142 0
sleep 1500
mouse 1 0 0 338 142 0
mouse 3 0 0 338 142 0
sleep 1500
mouse 1 0 0 338 222 0
mouse 3 0 0 338 222 0
sleep 1500
mouse 1 0 0 338 382 0
mouse 3 0 0 338 382 0
sleep 1500
mouse 1 0 0 338 302 0
mouse 3 0 0 338 302 0
sleep 1500
downloads
dlact 4 0
sleep 1500
downloads
SCRIPT
cat > "$root/dlw-auto.txt" <<'SCRIPT'
sleep 9000
downloads
dlact 0 2
sleep 3500
downloads
SCRIPT
dl_check() { # $1=이름 — 대본의 목록 보고와 `~/Downloads` 를 남긴다
    grep -ao 'osr-test downloads* [^|]*\(|[^|]*\)\{0,6\}' "$root/app-$1.log" | sed 's/^osr-test //' > "$root/$1.report" || true
    ls -A "$root/home/Downloads" > "$root/$1.files" 2>/dev/null || true
    for f in "$root/home/Downloads"/*; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$(xattr -p com.apple.quarantine "$f" 2>/dev/null | cut -c1-4)"
    done > "$root/$1.quarantine"
    cat "$root/$1.report"
}
: > "$root/requests.log"
run_app /dlw-app 22000 "$root/dlw.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlw.txt"
dl_check dlw-app
python3 - "$root" dlw-app <<'PY' || fail "link downloads did not land in ~/Downloads as expected"
import sys, os
root, name = sys.argv[1], sys.argv[2]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, name + '.report')) if l.strip()]
heads = [l for l in lines if l.startswith('downloads ')]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
first, last = rows[:len(rows) // 2], rows[len(rows) // 2:]
files = sorted(l.strip() for l in open(os.path.join(root, name + '.files')) if l.strip())
quarantine = dict(l.rstrip('\n').split('\t') for l in open(os.path.join(root, name + '.quarantine')) if '\t' in l)
by = {r[1]: r for r in last}  # 행 이름은 받은 파일 이름(같은 이름이면 번호가 붙은 것)
check(len(heads) == 2 and 'window=true' in heads[0], f'clicked downloads show the list window ({heads})')
check(all(by.get(n, [''] * 7)[2] == '4' and by.get(n, [''] * 7)[6] == n for n in ('hello world.txt', 'hello world (1).txt')),
      f'the same name twice is numbered, both done and listed under their file names ({last})')
check(by.get('report.txt', [''] * 7)[2] == '4', f'an attachment is done under its server name ({by.get("report.txt")})')
big0 = [r for r in first if r[1] == 'big.zip']
check(bool(big0) and big0[0][2] == '2' and by.get('big.zip', [''] * 7)[2] == '5', f'the slow download was active, then canceled ({big0} → {by.get("big.zip")})')
check(by.get('tool.command', [''] * 7)[2] == '4' and by.get('tool.command', [''] * 7)[5] == '1', f'a runnable file the user clicked is downloaded, not held ({by.get("tool.command")})')
check(files == ['hello world (1).txt', 'hello world.txt', 'report.txt', 'tool.command'], f'~/Downloads holds exactly the finished files — no part file, no canceled file ({files})')
check(all(quarantine.get(f) == '0281' for f in files), f'every finished file carries the quarantine mark ({quarantine})')
sys.exit(0 if ok else 1)
PY

: > "$root/requests.log"
run_app /dlw-auto 16000 "$root/dlw-auto.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlw-auto.txt"
dl_check dlw-auto
python3 - "$root" dlw-auto <<'PY' || fail "a page-started runnable download was not held until the user took it"
import sys, os
root, name = sys.argv[1], sys.argv[2]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, name + '.report')) if l.strip()]
heads = [l for l in lines if l.startswith('downloads ')]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
files = sorted(l.strip() for l in open(os.path.join(root, name + '.files')) if l.strip())
quarantine = dict(l.rstrip('\n').split('\t') for l in open(os.path.join(root, name + '.quarantine')) if '\t' in l)
check(len(rows) == 2 and rows[0][1] == 'run me.command' and rows[0][2] == '1' and rows[0][5] == '1' and rows[0][6] == '', f'held, risky, no file yet ({rows[:1]})')
check(len(heads) == 2 and 'window=true' in heads[0], f'a held download brings the list window forward ({heads})')
check(len(rows) == 2 and rows[1][2] == '4' and rows[1][6] == 'run me.command', f'taking it downloads it ({rows[1:]})')
check(files == ['run me.command'] and quarantine.get('run me.command') == '0281', f'saved with the quarantine mark ({files} · {quarantine})')
sys.exit(0 if ok else 1)
PY

# ── W10b: 다운로드 「매번 묻기」 ──────────────────────────────────────────────────────────────────────────────
# `browser.download-ask = true` — 누른 다운로드는 저장 창(대본 `dlanswer` 가 경로로 답한다 — 창은 띄우지 않는다)이 고른 폴더·이름에
# 받는다. 있던 이름을 고르면 덮어쓴다(그때 그 경로에 무언가 있었다 — 저장 창이 「바꿀까요?」를 물은 경우). 취소하면 받지 않는다.
# `~/Downloads` 에는 아무것도 생기지 않는다. 사용자 동작 없이 받으려는 보통 파일도 보류하고, 목록의 받기가 저장 창을 띄운다.
printf 'browser.download-ask = true\n' > "$root/ask.conf"
rm -rf "$root/picked" && mkdir -p "$root/picked" && printf 'old\n' > "$root/picked/chosen.txt"
cat > "$root/dlask.txt" <<SCRIPT
sleep 7000
dlanswer $root/picked/chosen.txt
mouse 1 0 0 338 142 0
mouse 3 0 0 338 142 0
sleep 2000
dlanswer -
mouse 1 0 0 338 222 0
mouse 3 0 0 338 222 0
sleep 2000
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-app 16000 "$root/dlask.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlask.txt" MARU_CONFIG="$root/ask.conf"
dl_check dlw-app
cp "$root/dlw-app.report" "$root/dlask.report"
python3 - "$root" <<'PY' || fail "ask-each-time downloads did not land where the save panel said"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlask.report')) if l.strip()]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
picked = sorted(os.listdir(os.path.join(root, 'picked')))
content = open(os.path.join(root, 'picked', 'chosen.txt'), 'rb').read() if os.path.exists(os.path.join(root, 'picked', 'chosen.txt')) else b''
downloads = os.path.join(root, 'home', 'Downloads')
in_downloads = sorted(os.listdir(downloads)) if os.path.isdir(downloads) else []
check(len(rows) == 2 and rows[0][1] == 'chosen.txt' and rows[0][2] == '4' and rows[0][6] == 'chosen.txt', f'the clicked download is saved under the chosen name ({rows[:1]})')
check(picked == ['chosen.txt'] and content == b'hello\n', f'choosing an existing name replaces it — no numbered copy, no part file ({picked} · {content!r})')
check(len(rows) == 2 and rows[1][1] == 'report.txt' and rows[1][2] == '5', f'canceling the save panel downloads nothing ({rows[1:]})')
check(in_downloads == [], f'nothing lands in ~/Downloads when asking ({in_downloads})')
q = os.popen(f"xattr -p com.apple.quarantine '{os.path.join(root, 'picked', 'chosen.txt')}' 2>/dev/null").read()[:4]
check(q == '0281', f'the chosen file carries the quarantine mark ({q!r})')
sys.exit(0 if ok else 1)
PY
cat > "$root/dlask-auto.txt" <<SCRIPT
sleep 9000
downloads
dlanswer $root/picked/plain.txt
dlact 0 2
sleep 3500
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-auto-plain 16000 "$root/dlask-auto.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlask-auto.txt" MARU_CONFIG="$root/ask.conf"
dl_check dlw-auto-plain
python3 - "$root" <<'PY' || fail "an ask-each-time download the page started was not held until the user chose a place"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlw-auto-plain.report')) if l.strip()]
heads = [l for l in lines if l.startswith('downloads ')]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
check(len(rows) == 2 and rows[0][1] == 'plain.txt' and rows[0][2] == '1' and rows[0][5] == '0', f'a plain file the page started is held when asking ({rows[:1]})')
check(len(heads) == 2 and 'window=true' in heads[0], f'the held download brings the list window forward ({heads})')
check(len(rows) == 2 and rows[1][2] == '4' and rows[1][6] == 'plain.txt' and os.path.exists(os.path.join(root, 'picked', 'plain.txt')), f'taking it from the list asks and saves to the chosen place ({rows[1:]})')
via = os.popen(f"grep -ao 'osr-test download-ask via=[a-z]*' '{os.path.join(root, 'app-dlw-auto-plain.log')}'").read().split()
check(via[-1:] == ['via=list'], f'the list window shows the save panel for its own take, not the tab window ({via})')
sys.exit(0 if ok else 1)
PY

# 진짜 저장 창(대본이 답하지 않는다)을 종료·창 닫힘과 같은 길(.abort)로 치우면 그 다운로드는 보류로 돌아온다(다시 받을 수 있게).
cat > "$root/dlask-abort.txt" <<SCRIPT
sleep 7000
mouse 1 0 0 338 142 0
mouse 3 0 0 338 142 0
sleep 2500
downloads
dlpanels abort
sleep 1500
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-app 16000 "$root/dlask-abort.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlask-abort.txt" MARU_CONFIG="$root/ask.conf"
dl_check dlw-app
grep -ao 'osr-test dlpanels [0-9]*' "$root/app-dlw-app.log" > "$root/dlask-abort.panels" || true
python3 - "$root" <<'PY' || fail "a dismissed save panel did not put the download back on hold"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlw-app.report')) if l.strip()]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
panels = open(os.path.join(root, 'dlask-abort.panels')).read().split()
check(len(rows) == 2 and rows[0][2] == '10' and panels[-1:] == ['1'], f'a clicked download shows a real save panel and waits (asking) ({rows[:1]} · panels {panels})')
check(len(rows) == 2 and rows[1][2] == '1', f'dismissing the panel the way quit and window close do puts it back on hold ({rows[1:]})')
sys.exit(0 if ok else 1)
PY

# ── W10c: 닫은 탭의 다운로드·빈 다운로드 탭 ──────────────────────────────────────────────────────────────────
# 받는 중인 웹 탭을 닫아도(⌘W·maru 확인) 다운로드는 끝까지 받아진다 — maru 가 그 브라우저를 숨겨 about:blank 에 남긴다(닫으면
# Chromium 이 서버 연결을 끊고 받던 파일을 지운다 — 판정 `dl-closed`). 다 받으면 그 브라우저를 닫는다(웹 탭이 없으면 sidecar 도 내린다).
# 페이지가 새 탭으로 연 첨부(`target=_blank`)는 문서 없이 다운로드만 한 그 탭을 닫고 파일은 받는다.
printf 'ui.language = ko\n' > "$root/park.conf"
cat > "$root/dlpark.txt" <<'SCRIPT'
sleep 7000
mouse 1 0 0 338 302 0
mouse 3 0 0 338 302 0
sleep 1500
downloads
key 13 U+77 U+77 32
sleep 700
key 36 U+D
sleep 2500
downloads
sleep 15000
downloads
SCRIPT
: > "$root/requests.log"
# 받기는 누른 뒤 약 9 초(0.3 초마다 100 KB) — 마지막 보고는 누른 뒤 약 19 초. 대본이 약 27 초라 34 초.
run_app /dlw-app 34000 "$root/dlpark.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlpark.txt" MARU_CONFIG="$root/park.conf"
dl_check dlw-app
cp "$root/dlw-app.report" "$root/dlpark.report"
grep -ao 'osr-test download-park[ a-z]*=[0-9]*\( tabs=[0-9]*\)\{0,1\}' "$root/app-dlw-app.log" | sed 's/^osr-test //' > "$root/dlpark.park" || true
cat "$root/dlpark.park"
python3 - "$root" <<'PY' || fail "a closed tab's download did not keep going to the end"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlpark.report')) if l.strip()]
groups, cur = [], None
for l in lines:
    if l.startswith('downloads '):
        cur = []; groups.append(cur)
    elif l.startswith('download ') and cur is not None:
        cur.append(l.split(' ', 1)[1].split('|'))
park = [l.strip() for l in open(os.path.join(root, 'dlpark.park')) if l.strip()]
big = lambda g: next((r for r in g if r[1] == 'big.zip'), [''] * 7)
path = os.path.join(root, 'home', 'Downloads', 'big.zip')
size = os.path.getsize(path) if os.path.exists(path) else -1
q = os.popen(f"xattr -p com.apple.quarantine '{path}' 2>/dev/null").read()[:4]
check(len(groups) == 3 and big(groups[0])[2] == '2', f'the slow download was going before the tab closed ({groups[:1]})')
check('download-park parked=1' in park, f'closing the tab hid its browser instead of closing it ({park})')
check(len(groups) == 3 and big(groups[1])[2] == '2', f'after the tab closed the download is still going, not stopped ({groups[1:2]})')
check(len(groups) == 3 and big(groups[2])[2] == '4' and size == 30 * 104858 and q == '0281', f'it finished in full with the quarantine mark ({groups[2:]} · {size} bytes · {q!r})')
check('download-park released parked=0 tabs=0' in park, f'once done the hidden browser was closed — no web tab is left, so the engine can go too ({park})')
sys.exit(0 if ok else 1)
PY
# 시험 서버는 한 스레드다 — 3 MB 를 보내는 약 9 초 동안 가운데 클릭의 첨부는 기다렸다가 받는다.
cat > "$root/dlblank.txt" <<'SCRIPT'
sleep 7000
view down 0.5 0.25 0 0
sleep 60
view up 0.5 0.25 0 0
sleep 3000
view down 0.5 0.75 0 0 2
sleep 60
view up 0.5 0.75 0 0 2
sleep 12000
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-blank-big 26000 "$root/dlblank.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlblank.txt"
dl_check dlw-blank-big
cp "$root/dlw-blank-big.report" "$root/dlw-blank.report"; cp "$root/dlw-blank-big.files" "$root/dlw-blank.files"
grep -ao 'osr-test download-park[ a-z]*=[0-9]*\( tabs=[0-9]*\)\{0,1\}' "$root/app-dlw-blank-big.log" | sed 's/^osr-test //' > "$root/dlblank.park" || true
grep -ao 'osr-test newtab \(download-blank closed tabs=[0-9]*\|at=[0-9]* tabs=[0-9]* opener=[0-9]* active=[0-9]* placement=[a-z_]* adopted=[a-z]*\)' "$root/app-dlw-blank-big.log" > "$root/dlblank.tabs" || true
cat "$root/dlblank.tabs"
python3 - "$root" <<'PY' || fail "a new tab that only downloaded was left open"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlw-blank.report')) if l.strip()]
rows = [l.split(' ', 1)[1].split('|') for l in lines if l.startswith('download ')]
tabs = [l.strip() for l in open(os.path.join(root, 'dlblank.tabs')) if l.strip()]
files = sorted(l.strip() for l in open(os.path.join(root, 'dlw-blank.files')) if l.strip())
opened = [t for t in tabs if ' at=' in t]
closed = [t for t in tabs if 'download-blank closed' in t]
check(len(opened) == 2 and 'adopted=true' in opened[0] and 'adopted=false' in opened[1], f'each link opened one new tab — the target=_blank popup, then the middle-clicked address ({tabs})')
# 보고 차례: 연 탭 · 닫음 · 연 탭 · 닫음 — 닫을 때마다 탭 수가 연 뒤보다 하나 적다.
pairs = list(zip(tabs[0::2], tabs[1::2]))
check(len(pairs) == 2 and all(' at=' in a and 'download-blank closed' in b and int(b.split('tabs=')[1]) == int(a.split('tabs=')[1].split()[0]) - 1 for a, b in pairs), f'both new tabs that only downloaded were closed ({tabs})')
park = [l.strip() for l in open(os.path.join(root, 'dlblank.park')) if l.strip()]
check(len(rows) == 2 and all(r[2] == '4' for r in rows) and files == ['big.zip', 'report.txt'], f'both files were still downloaded ({rows} · {files})')
check('download-park parked=1' in park and any(l.startswith('download-park released parked=0') for l in park), f'the closed popup tab kept downloading the 3 MB file hidden, then was closed ({park})')
sys.exit(0 if ok else 1)
PY
# 「매번 묻기」면 새 탭이 받는 다운로드의 저장 창이 그 새 탭에서 곧바로 뜬다 — 저장 창이 뜨기 전에 탭을 닫으면 목록 창으로 밀렸다
# (W10c 적대 리뷰 1 회차). 고른 곳에 받고, 그 빈 탭은 닫힌다.
rm -rf "$root/picked" && mkdir -p "$root/picked"
printf 'browser.download-ask = true\n' > "$root/ask.conf"
cat > "$root/dlblank-ask.txt" <<SCRIPT
sleep 7000
dlanswer $root/picked/blank.txt
view down 0.5 0.25 0 0
sleep 60
view up 0.5 0.25 0 0
sleep 3500
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-blank 16000 "$root/dlblank-ask.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlblank-ask.txt" MARU_CONFIG="$root/ask.conf"
dl_check dlw-blank
grep -ao 'osr-test \(newtab download-blank closed tabs=[0-9]*\|download-ask via=[a-z]*\)' "$root/app-dlw-blank.log" > "$root/dlblank-ask.report" || true
cat "$root/dlblank-ask.report"
python3 - "$root" <<'PY' || fail "an ask-each-time download in a new tab did not ask in that tab"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
seen = [l.strip() for l in open(os.path.join(root, 'dlblank-ask.report')) if l.strip()]
rows = [l.split(' ', 1)[1].split('|') for l in open(os.path.join(root, 'dlw-blank.report')) if l.startswith('download ')]
check('osr-test download-ask via=tab' in seen, f'the save panel came up from the new tab right away, not from the list window ({seen})')
check(any('download-blank closed' in l for l in seen), f'the blank tab was closed after the panel came up ({seen})')
check(len(rows) == 1 and rows[0][2] == '4' and os.path.exists(os.path.join(root, 'picked', 'blank.txt')), f'saved where the panel said ({rows})')
sys.exit(0 if ok else 1)
PY

# ── W10d: 스스로 닫는 다운로드 페이지 ─────────────────────────────────────────────────────────────────────────
# 받는 중인 페이지가 스스로 닫거나(`window.close`) 연 페이지가 닫아도(`w.close()`) 받기는 끝까지 간다 — sidecar 가 브라우저를 닫지 않고
# 알리고(`page_close_kept`), maru 는 그 탭을 닫고 브라우저를 주차한다(이미 주차한 것이면 그대로). 전에는 Chromium 이 받기를 끊었다.
# 시험 서버는 한 스레드라 두 3 MB 를 차례로 보낸다 — 두 번째 누름은 첫 받기가 끝난 뒤에.
cat > "$root/dlself.txt" <<'SCRIPT'
sleep 7000
view down 0.5 0.25 0 0
sleep 60
view up 0.5 0.25 0 0
sleep 13000
downloads
view down 0.5 0.75 0 0
sleep 60
view up 0.5 0.75 0 0
sleep 14000
downloads
SCRIPT
: > "$root/requests.log"
run_app /dlw-selfclose 40000 "$root/dlself.summary" MARU_WEB_OSR_TEST_INPUT="$root/dlself.txt"
dl_check dlw-selfclose
grep -ao 'osr-test \(download-park[ a-z]*=[0-9]*\( tabs=[0-9]*\)\{0,1\}\|newtab page-closed [a-z-]*=[a-z]*\|newtab download-blank closed tabs=[0-9]*\)' "$root/app-dlw-selfclose.log" | sed 's/^osr-test //' > "$root/dlself.events" || true
cat "$root/dlself.events"
python3 - "$root" <<'PY' || fail "a page that closed itself while downloading stopped the download"
import sys, os
root = sys.argv[1]
ok = True
def check(c, m):
    global ok
    ok = ok and c
    print(('PASS ' if c else 'FAIL ') + m)
lines = [l.strip() for l in open(os.path.join(root, 'dlw-selfclose.report')) if l.strip()]
groups, cur = [], None
for l in lines:
    if l.startswith('downloads '):
        cur = []; groups.append(cur)
    elif l.startswith('download ') and cur is not None:
        cur.append(l.split(' ', 1)[1].split('|'))
ev = [l.strip() for l in open(os.path.join(root, 'dlself.events')) if l.strip()]
files = sorted(l.strip() for l in open(os.path.join(root, 'dlw-selfclose.files')) if l.strip())
check(any(e.startswith('newtab page-closed') for e in ev), f'the popup that closed itself closed its tab ({ev})')
check(len(groups) == 2 and len(groups[0]) == 1 and groups[0][0][2] == '4' and groups[0][0][3] == str(30 * 104858), f'its download kept going to the end ({groups[:1]})')
check(any(e.startswith('newtab download-blank closed') for e in ev) and ev.count('download-park parked=1') >= 2, f'the second popup only downloaded — its tab was closed and parked ({ev})')
check(len(groups) == 2 and len(groups[1]) == 2 and groups[1][1][2] == '4' and groups[1][1][3] == str(30 * 104858), f'the opener closing that popup did not stop its download ({groups[1:]})')
check(files == ['big (1).zip', 'big.zip'], f'both files are in ~/Downloads ({files})')
sys.exit(0 if ok else 1)
PY
# 받는 중에 앱과 sidecar 가 함께 죽으면(여기서는 이 시험이 띄운 그 앱과 그 자식만 SIGKILL) 미리 만든 빈 `.maru-part` 와 Chromium 이
# 받던 ` (1)` 형제(데이터)가 남는다 — 다음 실행이 프로필을 잡을 때 그 기록(프로필의 `maru-download-parts`)에 있는 것과 그 형제만
# 지운다(사용자 결정 2026-10-09). 같은 HOME 으로 두 번 띄운다(`run_app` 은 HOME 을 비운다).
rm -rf "$root/home" && mkdir -p "$root/home"
printf 'sleep 7000\nmouse 1 0 0 338 302 0\nmouse 3 0 0 338 302 0\nsleep 30000\n' > "$root/dlcrash.txt"
: > "$root/requests.log"
env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
    MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/dlw-app" \
    MARU_MACOS_APP_SMOKE_MS=40000 MARU_WEB_OSR_TEST_INPUT="$root/dlcrash.txt" MARU_WEB_OSR_TEST_CONTEXT_MENU=cancel "$app" > "$root/app-dlcrash.log" 2>&1 &
crash_pid=$!
sleep 11
part_before=$(ls -A "$root/home/Downloads" 2>/dev/null | tr '\n' ' ')
pkill -KILL -P "$crash_pid" 2>/dev/null || true # 그 앱의 자식(sidecar 등) 먼저 — Chromium 이 정리할 틈 없이
kill -KILL "$crash_pid" 2>/dev/null; wait "$crash_pid" 2>/dev/null || true
sleep 3 # 남은 helper 가 끝나 프로필 잠금이 풀릴 때까지
journal=$(find "$root/home/Library/Application Support/maru/web" -maxdepth 3 -name maru-download-parts | head -1)
journal_lines=$( [ -n "$journal" ] && wc -l < "$journal" | tr -d ' ' || echo 0)
part_after_kill=$(ls -A "$root/home/Downloads" 2>/dev/null | tr '\n' ' ')
env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
    MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port/solid" \
    MARU_MACOS_APP_SMOKE_MS=12000 MARU_APP_SUMMARY_PATH="$root/dlcrash2.summary" MARU_WEB_OSR_TEST_CONTEXT_MENU=cancel "$app" > "$root/app-dlcrash2.log" 2>&1
part_after_restart=$(ls -A "$root/home/Downloads" 2>/dev/null | tr '\n' ' ')
journal_after=$( [ -n "$journal" ] && { [ -e "$journal" ] && wc -c < "$journal" | tr -d ' ' || echo 0; } || echo -)
[ -n "$journal" ] && [ -e "$journal.sweeping" ] && fail "the part journal sweep did not finish (a .sweeping file is left)"
echo "downloads while downloading: [$part_before] · after kill: [$part_after_kill] · journal lines $journal_lines · after restart: [$part_after_restart] · journal bytes $journal_after"
case "$part_after_kill" in *big.zip.maru-part*) ;; *) fail "killing the app mid-download did not leave the part file to clean (got [$part_after_kill])" ;; esac
case "$part_after_kill" in *"big.zip (1).maru-part"*) ;; *) echo "WARN the data sibling (big.zip (1).maru-part) was not left by the kill ([$part_after_kill]) — the sibling cleanup was not exercised" ;; esac
[ "${journal_lines:-0}" -ge 1 ] || fail "the part file was not recorded in the profile's part journal"
case "$part_after_restart" in *maru-part*) fail "the next launch did not remove the leftover part file ([$part_after_restart])" ;; esac
[ "$journal_after" = 0 ] || fail "the part journal was not emptied after cleaning ($journal_after bytes — 정리 뒤 기록은 없거나 비어 있어야 한다)"
echo "PASS part files left by a killed app and sidecar (the empty placeholder and Chromium's data sibling) are removed by the next launch and the journal is emptied"

# ── W6k: 대화상자가 떠 있을 때의 종료 ─────────────────────────────────────────────────────────────────────────
# 페이지 대화상자 sheet 가 떠 있으면 AppKit 이 종료를 진행하지 않았다(시험 모드의 끝도 — 앱이 끝나지 않았다). 종료를 고르면 maru 가 그
# sheet 를 취소로 닫는다(사용자 결정 2026-10-06). alert 를 띄운 채 시험 시간이 끝나도 앱이 제때 끝나야 한다 — 끝나지 않으면 감시가
# 끄고 실패로 본다(이 단계가 멈추지 않게).
alert_exit() { # $1=이름 $2=경로
    printf 'sleep 9000\nsheet\n' > "$root/alert-$1.txt"
    rm -rf "$root/home" && mkdir -p "$root/home"
    env HOME="$root/home" CFFIXED_USER_HOME="$root/home" MARU_SESSION_HOST_ROOT="$root/session-host" \
        MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="http://127.0.0.1:$port$2" \
        MARU_MACOS_APP_SMOKE_MS=12000 MARU_WEB_OSR_TEST_INPUT="$root/alert-$1.txt" "$app" > "$root/app-alert-$1.log" 2>&1 &
    alert_pid=$!
    waited=0
    while kill -0 "$alert_pid" 2>/dev/null && [ "$waited" -lt 45 ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$alert_pid" 2>/dev/null; then
        kill "$alert_pid" 2>/dev/null; sleep 2; kill -KILL "$alert_pid" 2>/dev/null || true
        echo "FAIL the app with a page alert open did not exit ($1 — still running ${waited} s after start, smoke 12 s)"
        return 1
    fi
    # 끝난 것이 죽은 것이 아니어야 한다(종료 코드 0 — 적대 검증).
    alert_rc=0; wait "$alert_pid" || alert_rc=$?
    shown=$(grep -ao 'osr-test sheet alert' "$root/app-alert-$1.log" | head -1)
    if [ -z "$shown" ]; then echo "FAIL no alert sheet was open when the smoke time ended ($1)"; return 1; fi
    if [ "$alert_rc" != 0 ]; then echo "FAIL the app with a page alert open ended with status $alert_rc ($1)"; return 1; fi
    echo "PASS the app with a page alert open exits cleanly when asked to quit ($1 — ${waited} s, the sheet was shown)"
}
alert_exit once /alert-app || fail "the app did not exit with a page alert open"
alert_exit loop /alert-app?loop || fail "the app did not exit with a page that keeps opening alerts"

# ── W6j: 탭 닫기의 떠나기 확인 ───────────────────────────────────────────────────────────────────────────────
# 웹 탭 하나를 닫으면 maru 확인(「닫을까요?」)이 먼저 뜨고, 받으면 페이지에 묻는다 — 떠나기 확인을 건 페이지면 「나가시겠습니까?」를 한 번
# 더(W5a sheet), 머무르기면 탭이 남는다(사용자 결정 2026-10-05 — 둘 다, 탭 하나만). 처리기가 없으면 묻지 않고 닫히고, 처리기가 멈추면
# maru 가 2 초 뒤 강제로 닫는다. ⌘W 는 터미널 view 로 넣고(대본 `key`), maru 확인은 Enter 로 받는다. 질문 sheet 는 뜬 뒤 0.5 초 단추를
# 막으므로(W5a 입력 보호) 본 뒤 0.7 초 기다렸다 답한다 — sheet 가 늦게 뜨면 답이 무시되고 다음 Enter 가 「떠나기」가 됐다.
printf 'ui.language = ko\n' > "$root/unload.conf"
unload_run() { # $1=이름 $2=경로 $3=대본
    printf '%s\n' "$3" > "$root/unload-$1.txt"
    : > "$root/requests.log"
    # 대본이 약 21 초 — 끝 표시(`mark end`) 전에 앱이 끝나지 않게 26 초.
    run_app "$2" 26000 "$root/unload-$1.summary" MARU_WEB_OSR_TEST_INPUT="$root/unload-$1.txt" MARU_CONFIG="$root/unload.conf"
    # 보고 줄은 요약 출력과 한 줄에 섞일 수 있다 — 줄 중간에서도 찾는다.
    grep -ao 'osr-test \(pageclose [a-z_]*\|overlay [a-z]*\|windowcount [0-9]*\|mark [a-z0-9]* [0-9]*\|sheet [^|]*|[^|]*\)' "$root/app-${2#/}.log" > "$root/unload-$1.report" || true
    cp "$root/requests.log" "$root/unload-$1.requests"
    cat "$root/unload-$1.report"
}
unload_run ask /unload-app "sleep 7000
view down 0.5 0.5 0 0
view up 0.5 0.5 0 0
sleep 1000
view down 0.5 0.5 0 0
view up 0.5 0.5 0 0
sleep 800
mark close1
key 13 U+77 U+77 32
sleep 700
overlay
key 36 U+D
sleep 1500
sheet
sleep 700
sheet-answer 1
sleep 2000
mark close2
key 13 U+77 U+77 32
sleep 700
key 36 U+D
sleep 1500
sheet
sleep 700
sheet-answer 0
sleep 3000
mark end"
unload_run plain /unload-app?plain "sleep 7000
mark close1
key 13 U+77 U+77 32
sleep 700
overlay
key 36 U+D
sleep 2500
sheet
mark end"
# 둘째 창에서 터미널 탭을 닫아 웹 탭만 남기고 ⌘W — 창의 마지막 탭이라 물은 뒤 창이 닫힌다(탭을 먼저 부수면 죽었다 — 적대 검증).
unload_run last /unload-app?last "sleep 6000
newwindow
sleep 3000
action previous_term
sleep 300
action close_term
sleep 1000
windowcount
mark close1
key 13 U+77 U+77 32
sleep 700
key 36 U+D
sleep 2500
windowcount
mark end"
unload_run hang /unload-app?hang "sleep 7000
view down 0.5 0.5 0 0
view up 0.5 0.5 0 0
sleep 1000
view down 0.5 0.5 0 0
view up 0.5 0.5 0 0
sleep 800
mark close1
key 13 U+77 U+77 32
sleep 700
key 36 U+D
sleep 1000
sheet
sleep 2500
mark end"
python3 - "$root" <<'PY' || fail "closing a web tab did not ask the page as expected"
import sys
root = sys.argv[1]
def load(name):
    report = [l.strip() for l in open(f'{root}/unload-{name}.report')]
    events = []
    for l in open(f'{root}/unload-{name}.requests'):
        if l.startswith('/ev?'):
            events.append(dict(kv.split('=', 1) for kv in l.strip().split('?', 1)[1].split('&') if '=' in kv))
    marks = {l.split()[2]: int(l.split()[3]) for l in report if l.startswith('osr-test mark ')}
    return report, events, marks
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
def closes(report): return [l.split()[2] for l in report if l.startswith('osr-test pageclose ')]
def sheets(report): return [l for l in report if l.startswith('osr-test sheet ')]
def leave_sheet(line): return line.startswith('osr-test sheet alert ') and ('나가시겠습니까' in line or 'Leave site?' in line)

report, events, marks = load('ask')
s = sheets(report)
ticks_between = [e for e in events if e.get('e') == 'tick' and marks.get('close1', 0) + 3000 < int(e['t']) < marks.get('close2', 0)]
check('osr-test overlay true' in report and closes(report)[:3] == ['asked', 'stayed', 'asked'] and len(s) >= 1 and leave_sheet(s[0])
      and any(e.get('e') == 'armed' for e in events) and len(ticks_between) >= 3,
      f'closing a web tab whose page set a leave confirmation shows the maru confirm, then the page question; Stay keeps the tab running ({closes(report)} · {s[:1]} · {len(ticks_between)} ticks after staying)')
# 닫힌 뒤에는 0.3 초 신호가 끊긴다(떠나기는 close2 + 약 2.9 초).
late = [e for e in events if e.get('e') == 'tick' and int(e['t']) > marks.get('close2', 0) + 4500]
check(closes(report) == ['asked', 'stayed', 'asked', 'closed'] and len(s) == 2 and leave_sheet(s[1]) and marks.get('end') and not late,
      f'closing again and choosing Leave closes the tab ({closes(report)} · {len(s)} sheets · {len(late)} ticks after it closed)')

report, events, marks = load('plain')
late = [e for e in events if e.get('e') == 'tick' and int(e['t']) > marks.get('close1', 0) + 2500]
check('osr-test overlay true' in report and closes(report) == ['asked', 'closed'] and sheets(report)[-1:] and sheets(report)[-1].startswith('osr-test sheet none')
      and marks.get('end') and not late,
      f'a page without a leave confirmation closes after the maru confirm without a second question ({closes(report)} · {sheets(report)} · {len(late)} ticks after it closed)')

report, events, marks = load('last')
counts = [l.split()[2] for l in report if l.startswith('osr-test windowcount ')]
check(counts == ['2', '1'] and closes(report) == ['asked', 'closed'],
      f'closing the only tab of a second window asks the page, then closes that window ({counts} · {closes(report)})')

report, events, marks = load('hang')
check(closes(report) == ['asked', 'timed_out'] and sheets(report)[-1:] and sheets(report)[-1].startswith('osr-test sheet none'),
      f'a page whose leave handler hangs is closed by maru after the wait, without a question ({closes(report)} · {sheets(report)})')
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
# 쓴 파일이 서버가 준 바이트 그대로인지, 내려받은 파일 표지(quarantine)가 붙었는지 본다. 같은 이름이 있으면 「cat 2.png」(Finder 는 그 놓기를 먼저 거절한다 — Chrome 도 같다).
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
# 창이 둘일 때 — 첫 누름은 그 창이 key 가 되기 전에 온다. 대상(명시 세션)은 첫 창으로 두고 그 탭을 터미널로 돌린 뒤(대조: 같은 자리가
# 0), 둘째 창(같은 시험 페이지)의 본문에 묻고 누르면 둘째 창의 세션으로 가야 한다(W6g 적대 검증 — key 창·첫 창의 배치로 판정하면
# 다른 창의 웹 본문 자리가 이 창의 터미널로 첫 누름을 새게 했다. 둘째 창을 고른 까닭: 비활성 앱에는 key 창이 없어 세션을 정하지
# 않으면 첫 창으로 떨어진다 — 첫 창 쪽을 보면 그 잘못도 통과한다, 2 차).
cat > "$root/firstmouse2.txt" <<SCRIPT
sleep 9000
newwindow
sleep 4000
firstwindow
action previous_term
sleep 600
firstmouse 0.6 0.5
firstmouse 0.6 0.5 last
lastview down 0.6 0.5 0 0
lastview up 0.6 0.5 0 0
sleep 800
SCRIPT
: > "$root/requests.log"
run_app /input 20000 "$root/firstmouse2.summary" MARU_WEB_OSR_TEST_INPUT="$root/firstmouse2.txt"
grep -a '^osr-test firstmouse' "$root/app-input.log" > "$root/firstmouse2.report" || true
cat "$root/firstmouse2.report"
python3 - "$root/firstmouse2.report" "$root/requests.log" <<'PY' || fail "the first click with two windows did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
clicks = [l.strip() for l in open(sys.argv[2]) if l.startswith('/ev?e=click')]
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what)
    ok = ok and cond
check(report == ['osr-test firstmouse 0.6 0.5 false', 'osr-test firstmouse 0.6 0.5 last true'] and len(clicks) == 1,
      f'with the first window on a terminal tab, a first click on the second window\'s page body is asked and delivered through the second window ({report} · clicks {clicks})')
sys.exit(0 if ok else 1)
PY
# 알림 토스트가 떠 있으면 넘기지 않는다(누름 경로가 토스트를 닫으며 누름을 삼킨다 — 그 첫 누름에 페이지는 못 받는다). 닫은 뒤에는
# 다시 넘긴다(대조 — 거짓이 다른 까닭이 아니다).
cat > "$root/firstmouse3.txt" <<SCRIPT
sleep 9000
config browser.engine = webkit
menu Reload Config
sleep 800
overlay
firstmouse 0.6 0.5
view down 0.6 0.3 -50 0 0 1
view up 0.6 0.3 -50 0 0 1
sleep 400
overlay
firstmouse 0.6 0.5
sleep 300
SCRIPT
printf 'browser.engine = chromium\n' > "$root/firstmouse.conf"
run_app /solid 14000 "$root/firstmouse3.summary" MARU_WEB_OSR_TEST_INPUT="$root/firstmouse3.txt" MARU_CONFIG="$root/firstmouse.conf"
grep -a '^osr-test firstmouse\|^osr-test overlay' "$root/app-solid.log" > "$root/firstmouse3.report" || true
cat "$root/firstmouse3.report"
python3 - "$root/firstmouse3.report" <<'PY' || fail "the first click while the notice toast is up did not behave as expected"
import sys
report = [l.strip() for l in open(sys.argv[1])]
want = ['osr-test overlay true', 'osr-test firstmouse 0.6 0.5 false', 'osr-test overlay false', 'osr-test firstmouse 0.6 0.5 true']
ok = report == want
print(('PASS ' if ok else 'FAIL ') + f'while the notice toast is up a first click only brings the window forward, and after it closes the page gets it again ({report})')
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
