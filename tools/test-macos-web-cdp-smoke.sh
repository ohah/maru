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
#   text·label      text·label 로케이터(W9b②-2 — 격리 world 의 JS): 숨은 자손이 낀 버튼 글·쪼개진 글 exact·sr-only 글(누를 수 있는 버튼으로 바꿔
#                   누른다)·라벨(aria-hidden 별표는 뺀 exact)로 진짜 입력, 숨긴 체크박스는 label 로 ok:false + hint → 보이는 글로 누르면 토글,
#                   같은 글이 여럿이면 후보 ref 로 다시. 적대 리뷰 1 회차: 카드 제목 글은 카드 가운데의 다른 버튼이 아니라 그 글을 누른다,
#                   화면 밖 「… about …」 글이 링크를 가리지 않는다, shadow host 의 그려지지 않는 light 자식 글로 host 를 고르지 않는다(hint).
#                   2 회차: pointer-events:none 글은 그 버튼이 받는다, aria-hidden 아이콘 글자를 뺀 exact, display:contents 글.
#                   3 회차: 버튼 밖 상자의 로딩 덮개는 covered 이고 아무것도 눌리지 않는다, 버튼 안 터치 영역(Material)은 그 버튼이 받는다(shadow 안
#                   버튼 + slot 도), 카드 안 다른 버튼이 글을 덮으면 covered, 화면 밖 같은 글 사본이 있어도 exact(빼낼 글의 길이 하한).
#                   4 회차: select 를 품은 label 의 글 exact, sr-only 토글 체크박스는 label 로케이터로 그 label 을 눌러 켠다.
#                   5 회차: 가운데에 링크를 품은 글은 그 링크를 누르지 않고 covered.
#                   변이로 찾은 빈 곳: 투명 radio 가 덮은 요금제 카드(label 과 control 은 같은 것)는 눌린다, iframe 이 덮은 카드는 covered,
#                   그려지지 않은 요소 안 aria-hidden 글의 exact 는 hint, nth 가 보이는 일치 수를 넘으면 숨은 사본이 있어도 hint 없이 not ok
#   wait-visible    wait 의 로케이터(W9b②-3): 2 초 뒤 생기는 버튼을 role 로 기다려 matched, 같은 글이 둘이면 ok 와 ambiguous 경고,
#                   오프캔버스(left:-9999)의 버튼은 보이지 않아 시한(-32004)
#   hidden-tab      탭을 숨긴 채(대본 `action new_tab` — pane 대본이 `hide-now` 를 만들면) role 로케이터 click 이 3 초 안에 진짜로 누르고(접근성
#                   질의 + 1×1 스크린샷 — 그 스크린샷이 없으면 숨은 탭에서 질의가 답하지 않는다), hover 가 3 초 안에 mouseover 를 주고(예전 5 초),
#                   rAF 로 나타나는 버튼을 text wait 이 본다(확인마다 스크린샷). 그 뒤 `previous_tab` 으로 돌아온다
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
#   mcp             (W9f) `maru mcp` 를 에이전트처럼 새 세션(제어 터미널 없음)·파이프로 띄워 — pane 신원이 통과해 탭을 열고, 진짜로 누르고,
#                   글 `--help` 를 글로 넣고(도움말이 아니라), `-1` 식을 엔진에 보내고, 스크린샷은 PNG 그림, 틀린 인자 이름은 거절, 닫는다.
#                   표준 출력은 JSON-RPC 줄뿐이고 입력 끝에 0 으로 끝난다
#   repl            (W9f) `maru browser repl` 에 open → click(--surface 없이) → close 를 파이프로 — open 이 고른 탭에 명령이 간다
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
<div id=osh style="position:absolute;left:620px;top:220px"></div>
<div style="position:absolute;left:20px;top:740px">
<button id=td onclick="hit('td-'+event.isTrusted)">Erase now<span style="display:none">Erase now</span></button>
<a id=sp href="#" onclick="hit('sp-'+event.isTrusted);return false">Join <b>the</b> club</a>
<button id=icon onclick="hit('icon-'+event.isTrusted)"><span style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)">Close dialog</span>X</button>
<label for=em2>Work email <span aria-hidden=true>*</span></label><input id=em2 oninput="hit('em2-'+event.isTrusted+'-'+encodeURIComponent(this.value))">
<label id=dm><input type=checkbox style="display:none" onchange="hit('dm-'+this.checked)">Dark mode</label>
<button id=wl onclick="setTimeout(function(){document.body.insertAdjacentHTML('beforeend','<button style=position:absolute;left:600px;top:120px>Ready now</button>')},2000)">Start later</button>
<nav style="position:absolute;left:-9999px"><button>Offcanvas go</button></nav>
<button onclick="hit('hb-'+event.isTrusted)">Hidden role btn</button>
<span onmouseover="hit('hh-'+event.isTrusted)">Hover hidden</span>
<script>document.addEventListener('visibilitychange',function(){hit('vis-'+document.visibilityState)})</script>
<button id=rs onclick="setTimeout(function(){requestAnimationFrame(function(){document.body.insertAdjacentHTML('beforeend','<button style=position:absolute;left:600px;top:160px>Raf ready</button>')})},300)">Start raf</button>
<button onclick="hit('ar1-'+event.isTrusted)">Archive item</button><button onclick="hit('ar2')">Archive item</button>
<div role=button tabindex=0 onclick="hit('card-'+event.isTrusted)" style="position:relative;width:300px;height:60px;border:1px solid"><span>Card title</span><button style="position:absolute;left:110px;top:15px;width:80px;height:30px" onclick="event.stopPropagation();hit('cdel')">Del</button></div>
<a href="#" onclick="hit('rm-'+event.isTrusted);return false">Read more<span style="position:absolute;left:-10000px">Read more about pricing</span></a>
<div id=xm></div>
<button onclick="hit('pen-'+event.isTrusted)"><span style="pointer-events:none">Pointer pass</span></button>
<button onclick="hit('mi-'+event.isTrusted)"><span aria-hidden=true>delete</span> Remove row</button>
<button onclick="hit('dcb-'+event.isTrusted)"><div style="display:contents">Contents label</div></button>
<div class=busy style="position:relative;display:inline-block"><span onclick="hit('busy-'+event.isTrusted)">Busy export</span></div><style>.busy::after{content:'';position:absolute;inset:0}</style>
<button onclick="hit('tt-'+event.isTrusted)" style="position:relative"><span style="position:relative">Touch save</span><span style="position:absolute;left:0;right:0;top:50%;height:48px;transform:translateY(-50%)"></span></button>
<div role=button tabindex=0 onclick="hit('cd2-'+event.isTrusted)" style="position:relative;display:inline-block;width:220px;height:40px"><span>Card two title</span><button style="position:absolute;left:0;top:0;width:220px;height:40px;opacity:0.5" onclick="event.stopPropagation();hit('cd2del')">Del2</button></div>
<x-tb id=xtb><span>Shadow touch</span></x-tb>
<a href="#" onclick="hit('gs-'+event.isTrusted);return false">Get started<span style="position:absolute;left:-10000px">Get started</span></a>
<label>Country <span aria-hidden=true>*</span> <select onchange="hit('ct')"><option>Korea</option><option>Japan</option></select></label>
<label style="display:inline-flex"><input type=checkbox style="position:absolute;width:1px;height:1px;margin:-1px;overflow:hidden;clip:rect(0,0,0,0)" onchange="hit('tg-'+this.checked)"><span>Toggle wifi</span></label>
<div style="display:inline-block">I agree <a href="#" onclick="hit('tos-link');return false">to the Terms of Service</a> now</div>
<label style="position:relative;display:inline-block"><input type=radio name=plan style="position:absolute;left:0;top:0;width:100%;height:100%;margin:0;opacity:0" onchange="hit('pro-'+this.checked)"><span>Pro plan</span></label>
<div role=button tabindex=0 onclick="hit('ifc')" style="position:relative;display:inline-block"><span>Frame card</span><iframe srcdoc="x" style="position:absolute;left:0;top:0;width:100%;height:100%;border:0"></iframe></div>
<div style="display:none"><p>Secret plan<i aria-hidden=true>*</i><span style="display:none">long hidden words here</span></p></div>
<span style="display:none">Archive item</span>
</div>
<script>(function(){var h=document.getElementById('xtb');h.attachShadow({mode:'open'}).innerHTML='<button style="position:relative"><slot></slot><span style="position:absolute;left:-4px;right:-4px;top:-4px;bottom:-4px"></span></button>';h.shadowRoot.querySelector('button').addEventListener('click',function(e){hit('stb-'+e.isTrusted)})})()</script>
<script>(function(){var h=document.getElementById('xm');h.innerHTML='<div>Settings panel</div>';h.attachShadow({mode:'open'}).innerHTML='<button onclick="hit(\'xm-\'+event.isTrusted)">Menu</button>'})()</script>
<script>(function(){var r=document.getElementById('osh').attachShadow({mode:'open'});var inner=document.createElement('div');r.appendChild(inner);inner.attachShadow({mode:'open'}).innerHTML='<button id=osb>Shadow Role Btn</button>';inner.shadowRoot.getElementById('osb').addEventListener('click',function(e){hit('osb-'+e.isTrusted)})})()</script>
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
# 3 회차: 0.6 초마다 스스로 새로고침하는 페이지(숨은 탭 경우).
# W9b③: 에이전트가 연 탭(뒤쪽 — 처음부터 숨김). 첫 클릭·새 창 열기(결정 ④ — 뒤쪽 에이전트 탭)·떠나기 확인(글이 있으면).
printf '<!doctype html><title>ag</title><button id=ab style="position:absolute;left:30px;top:30px;width:120px;height:40px" onclick="new Image().src=&#39;/hit?ab-&#39;+event.isTrusted">Agent go</button><button id=pop style="position:absolute;left:30px;top:100px;width:120px;height:40px" onclick="window.open(&#39;ag2.html&#39;,&#39;_blank&#39;)">Pop</button><input id=t aria-label=Note style="position:absolute;left:30px;top:170px"><button id=al2 style="position:absolute;left:30px;top:220px;width:120px;height:40px" onclick="setTimeout(function(){alert(&#39;later&#39;)},1500)">Later alert</button><script>new Image().src="/hit?agvis-"+document.visibilityState;addEventListener("beforeunload",function(e){if(document.getElementById("t").value){e.preventDefault();e.returnValue=""}})</script>' > "$root/www/ag.html"
printf '<!doctype html><title>ag2</title>ag2<script>new Image().src="/hit?ag2vis-"+document.visibilityState;document.addEventListener("visibilitychange",function(){new Image().src="/hit?ag2vis-"+document.visibilityState})</script>' > "$root/www/ag2.html"
# W9b③ 적대 리뷰 3 회차: 숨긴 탭의 키(제출 신호), 제출이 alert 를 띄우는 문서, 같은 출처 팝업의 alert.
printf '<!doctype html><title>frm</title><form onsubmit="new Image().src=&#39;/hit?submit-&#39;+location.search.slice(1);return false"><input id=q aria-label=Q style="position:absolute;left:30px;top:30px"></form>' > "$root/www/frm.html"
printf '<!doctype html><title>frma</title><form onsubmit="navigator.sendBeacon(&#39;/hit?dsubmit-&#39;+location.search.slice(1));alert(&#39;sent&#39;);return false"><input id=q aria-label=Q style="position:absolute;left:30px;top:30px"></form>' > "$root/www/frma.html"
printf '<!doctype html><title>shr</title><button id=pop style="position:absolute;left:30px;top:30px;width:120px;height:40px" onclick="window.open(&#39;shr2.html&#39;,&#39;_blank&#39;)">Pop</button><button id=ok style="position:absolute;left:30px;top:100px;width:120px;height:40px" onclick="new Image().src=&#39;/hit?okclick&#39;">OK</button>' > "$root/www/shr.html"
printf '<!doctype html><title>shr2</title>shr2<script>new Image().src="/hit?shr2-load";setTimeout(function(){alert("popup")},800)</script>' > "$root/www/shr2.html"
# W9f: `maru mcp`·`maru browser repl` 이 움직이는 페이지.
printf '<!doctype html><title>mcp</title><button id=mb style="position:absolute;left:30px;top:30px;width:120px;height:40px" onclick="new Image().src=&#39;/hit?mb-&#39;+event.isTrusted">Mcp go</button><input id=mt aria-label=Query style="position:absolute;left:30px;top:100px" oninput="new Image().src=&#39;/hit?mt-&#39;+event.isTrusted+&#39;-&#39;+encodeURIComponent(this.value)"><button id=rb style="position:absolute;left:30px;top:160px;width:120px;height:40px" onclick="new Image().src=&#39;/hit?rb2-&#39;+event.isTrusted">Repl go</button>' > "$root/www/mcp.html"
# W9f: 에이전트가 MCP 서버를 띄우는 모양 — 새 세션(제어 터미널 없음)·파이프 입출력. 표준 출력의 줄은 모두 JSON-RPC 여야 한다.
cat > "$root/mcp_drive.py" <<'PY'
import base64, json, os, signal, subprocess, sys
cli, base, out = sys.argv[1:4]
signal.alarm(150)
p = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
res = {"nosid": "yes" if os.getsid(p.pid) == p.pid else "no"}
log = open(out + "/mcp-log", "w")
def send(obj):
    p.stdin.write((json.dumps(obj) + "\n").encode()); p.stdin.flush()
def recv():
    line = p.stdout.readline()
    log.write(line.decode(errors="replace")[:400].rstrip() + "\n"); log.flush()
    return json.loads(line)
nid = [0]
def call(name, args):
    nid[0] += 1
    send({"jsonrpc": "2.0", "id": nid[0], "method": "tools/call", "params": {"name": name, "arguments": args}})
    r = recv()
    assert r.get("id") == nid[0], r
    return r
def text(r):
    c = r.get("result", {}).get("content", [{}])[0]
    return c.get("text", ""), r.get("result", {}).get("isError")
send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}})
res["proto"] = recv()["result"]["protocolVersion"]
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": "l", "method": "tools/list"})
res["tools"] = str(len(recv()["result"]["tools"]))
# 응답을 기다리지 않고 둘을 잇달아 — 하나씩 처리해 각자의 id 로 답한다.
send({"jsonrpc": "2.0", "id": "p1", "method": "tools/call", "params": {"name": "browser_list", "arguments": {}}})
send({"jsonrpc": "2.0", "id": "p2", "method": "tools/call", "params": {"name": "browser_get_url", "arguments": {"surface": 999999}}})
a, b = recv(), recv()
res["pipelined"] = "%s,%s,%s" % (a.get("id"), b.get("id"), "listed" if text(a)[0].startswith("surface ") else "nolist")
t, e = text(call("browser_open", {"url": base + "/mcp.html"}))
res["open"] = t.strip().replace("\n", " ")
sid = t.split()[1] if t.startswith("opened ") and not e else "0"
t, e = text(call("browser_click", {"surface": int(sid), "selector": "#mb"}))
res["click"] = "%s %s" % (t.strip(), e)
t, e = text(call("browser_type", {"surface": int(sid), "selector": "#mt", "text": "--help"}))
res["type"] = "%s %s" % (t.strip()[:60].replace("\n", " "), e)
t, e = text(call("browser_exec", {"surface": int(sid), "expression": "-1"}))
res["exec"] = "%s %s" % (t.strip(), e)
r = call("browser_screenshot", {"surface": int(sid), "scale": 0.25})
c = r.get("result", {}).get("content", [{}])[0]
res["shot"] = "png" if c.get("type") == "image" and base64.b64decode(c.get("data", ""))[:4] == b"\x89PNG" else "no " + json.dumps(r)[:200]
r = call("browser_click", {"surface": int(sid), "selectr": "#mb"})
res["badarg"] = "error" if "error" in r or r.get("result", {}).get("isError") else "no"
t, e = text(call("browser_close", {"surface": int(sid)}))
res["close"] = "%s %s" % (t.strip(), e)
p.stdin.close()
rest = p.stdout.read()
res["rest"] = "empty" if rest == b"" else "extra"
res["rc"] = str(p.wait(10))
with open(out + "/mcp", "w") as f:
    for k, v in res.items():
        f.write("%s=%s\n" % (k, v))
PY
# W9b③: 숨은 채 불러온 문서 — 그 뒤 첫 마우스 누르기가 페이지에 닿는가(숨긴 탭은 새 문서를 그리지 않아 누르기가 사라졌다, 계획 공격 2 회차).
printf '<!doctype html><title>fresh</title><button id=fb style="position:absolute;left:30px;top:30px;width:140px;height:40px" onclick="new Image().src=&#39;/hit?fb-&#39;+event.isTrusted">Fresh go</button><a id=tohop href="hop.html" style="position:absolute;left:30px;top:120px">hop</a>' > "$root/www/fresh.html"
printf '<!doctype html><title>hop</title><button id=hop>Hop go</button><script>new Image().src="/hit?hopvis-"+document.visibilityState;setTimeout(function(){location.reload()},600)</script>' > "$root/www/hop.html"
printf '<!doctype html><title>page-c</title>c<script>setTimeout(function(){document.body.insertAdjacentHTML("beforeend","<p id=cready>ready</p>")},1000)</script>' > "$root/www/c.html"
# 느린 문서는 요소가 3 만을 넘는다 — role 로케이터가 질의 전에 거절하는지(W9b②).
python3 -c "import sys; sys.stdout.write('<!doctype html><title>page-slow</title>slow<button>Big</button><a id=next href=c1.html>next</a>' + '<i></i>' * 31000)" > "$root/www/slow.html"
# 접근성 트리를 비싸게 만드는 구성마다 상한을 하나 넘는 문서(W9b②-1 적대 리뷰 3·4 회차) — role 로케이터가 질의 전에 거절하는지. 다음 문서로 가는 링크를 단다.
python3 - "$root/www" <<'PY'
import sys
d = sys.argv[1]
pages = [
    ('c1', ''.join('<a href="#z%d">x</a>' % i for i in range(3001))),
    ('c2', '<input type=radio>' * 3001),
    ('c3', '<div role=radiogroup>' + '<span role=radio>r</span>' * 801 + '</div>'),
    ('c4', '<label><input type=checkbox>l</label>' * 3001),
    ('c5', ''.join('<pre>' + 'line\n' * 8000 + '</pre>' for _ in range(2))),
    ('c6', '<div>' + 't<!---->' * 30000 + '</div>'),
]
for k, (name, body) in enumerate(pages):
    # 마지막 문서는 스스로 새로고침하는 hop 문서로 간다(숨은 탭 3 회차 사례 — 대본 맨 끝).
    nxt = '<a id=next href="%s.html">next</a>' % pages[k + 1][0] if k + 1 < len(pages) else '<a id=tofresh href="fresh.html">fresh</a>'
    open('%s/%s.html' % (d, name), 'w').write('<!doctype html><title>%s</title><button>B</button>%s%s' % (name, nxt, body))
PY
# 받은 요청을 센다(새로고침이 문서를 다시 불렀는지).
cat > "$root/server.py" <<'PY'
import http.server, sys, functools, time
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow.html"):
            time.sleep(2)  # wait-load: 응답이 늦는 문서
        super().do_GET()
    def do_POST(self):
        # 3 회차: alert 바로 앞의 신호는 sendBeacon(POST) — 이미지 요청은 alert 가 렌더러를 멈춰 나가지 못한다.
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        sys.stderr.write("POST %s\n" % self.path); sys.stderr.flush()
        self.send_response(204); self.end_headers()
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
# 대본의 `action new_tab`(숨은 탭 경우)이 연 새 탭의 셸도 이 대본이다 — 한 번만 돈다.
mkdir "\$MARU_SMOKE_OUT/pane-once" 2>/dev/null || exec sleep 600
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
run role-shadow click --role button --name 'Shadow Role Btn' --exact
hit_seen osb-true && echo yes > "\$out/osb-hit" || echo no > "\$out/osb-hit"
run tx-hidden click --by-text 'Erase now' --exact
hit_seen td-true && echo yes > "\$out/td-hit" || echo no > "\$out/td-hit"
run tx-split click --by-text 'Join the club' --exact
hit_seen sp-true && echo yes > "\$out/sp-hit" || echo no > "\$out/sp-hit"
run tx-sr click --by-text 'Close dialog'
hit_seen icon-true && echo yes > "\$out/icon-hit" || echo no > "\$out/icon-hit"
run lb-type type --by-label 'Work email' --exact --text 'w@x'
hit_seen 'em2-true-w%40x' && echo yes > "\$out/em2-hit" || echo no > "\$out/em2-hit"
run lb-hidden click --by-label 'Dark mode'
run tx-dm click --by-text 'Dark mode'
hit_seen dm-true && echo yes > "\$out/dm-hit" || echo no > "\$out/dm-hit"
run tx-amb click --by-text 'Archive item'
tx_ref=\$(grep -o 'n[0-9][0-9]* "Archive item"' "\$out/tx-amb" | head -1 | cut -d' ' -f1)
run tx-ref click --ref "\$tx_ref"
hit_seen ar1-true && echo yes > "\$out/ar1-hit" || echo no > "\$out/ar1-hit"
run tx-card click --by-text 'Card title' --exact
hit_seen card-true && echo yes > "\$out/card-hit" || echo no > "\$out/card-hit"
run tx-more click --by-text 'Read more'
hit_seen rm-true && echo yes > "\$out/rm-hit" || echo no > "\$out/rm-hit"
run tx-host click --by-text 'Settings panel'
sleep 0.5
grep -q 'GET /hit?xm-' "$root/http.log" && echo yes > "\$out/xm-hit" || echo no > "\$out/xm-hit"
run tx-pe click --by-text 'Pointer pass' --exact
hit_seen pen-true && echo yes > "\$out/pen-hit" || echo no > "\$out/pen-hit"
run tx-icon click --by-text 'Remove row' --exact
hit_seen mi-true && echo yes > "\$out/mi-hit" || echo no > "\$out/mi-hit"
run tx-dc click --by-text 'Contents label' --exact
hit_seen dcb-true && echo yes > "\$out/dcb-hit" || echo no > "\$out/dcb-hit"
run tx-busy click --by-text 'Busy export' --exact
run tx-touch click --by-text 'Touch save' --exact
hit_seen tt-true && echo yes > "\$out/tt-hit" || echo no > "\$out/tt-hit"
run tx-inner click --by-text 'Card two title' --exact
run tx-stouch click --by-text 'Shadow touch' --exact
hit_seen stb-true && echo yes > "\$out/stb-hit" || echo no > "\$out/stb-hit"
run tx-gone click --by-text 'Get started' --exact
hit_seen gs-true && echo yes > "\$out/gs-hit" || echo no > "\$out/gs-hit"
run tx-sel hover --by-text 'Country' --exact
run lb-tiny click --by-label 'Toggle wifi'
hit_seen tg-true && echo yes > "\$out/tg-hit" || echo no > "\$out/tg-hit"
run tx-link click --by-text 'I agree'
run tx-radio click --by-text 'Pro plan' --exact
hit_seen pro-true && echo yes > "\$out/pro-hit" || echo no > "\$out/pro-hit"
run tx-iframe click --by-text 'Frame card' --exact
run tx-unr click --by-text 'Secret plan' --exact
run tx-nth click --by-text 'Archive item' --nth 5
run wv-start click --selector '#wl'
run wv-role wait --role button --name 'Ready now' --exact --timeout 6000
run wv-amb wait --by-text 'Archive item' --exact --timeout 3000
run wv-off wait --role button --name 'Offcanvas go' --exact --timeout 1500
# 탭을 숨긴다(앱 대본이 hide-now 를 보면 새 탭을 연다) — 페이지가 정말 hidden 이 됐는지 본다(적대 리뷰 1 회차).
touch "\$out/hide-now"
sleep 2
hit_seen vis-hidden && echo yes > "\$out/hid-vis" || echo no > "\$out/hid-vis"
t0=\$(date +%s)
run hid-role click --role button --name 'Hidden role btn' --exact
t1=\$(date +%s)
hit_seen hb-true && echo yes > "\$out/hb-hit" || echo no > "\$out/hb-hit"
t2=\$(date +%s)
run hid-hover hover --by-text 'Hover hidden' --exact
t3=\$(date +%s)
hit_seen hh-true && echo yes > "\$out/hh-hit" || echo no > "\$out/hh-hit"
# rAF 를 일으키는 클릭은 숨긴 뒤, kick 없는 selector 클릭으로 — 그 rAF 는 wait 의 확인에 실린 kick 만 돌린다(1 회차 — 앞의 클릭이면
# role 질의·hover 의 kick 이 대신 돌려 wait 의 kick 을 증명하지 못했다).
run hid-rs click --selector '#rs'
run hid-wait wait --by-text 'Raf ready' --exact --timeout 8000
echo "\$((t1 - t0)) \$((t3 - t2))" > "\$out/hid-secs"
touch "\$out/show-now"
sleep 2
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
for c in c1 c2 c3 c4 c5 c6; do
    run go-\$c click --selector '#next'
    url_is \$c.html || true
    run costly-\$c click --role button
done
touch "\$out/hide2-now"
sleep 2
# 3 회차: 스스로 계속 이동하는 숨은 탭(맨 끝에서 다시 숨긴다 — 문서를 옮기므로 앞의 ref 를 쓰는 사례 뒤에) — 이동하는 순간 보낸 스크린샷(kick)은 답이 오지 않을 수 있어 그 탭의 자리를 쥔다. 옛 sidecar 는
# 35 초 쥐어 그동안 selector wait 이 확인을 못 보내 시한이었고(15/25), role 질의는 곧 「too many」 였다. 열 번 모두 곧 맞아야 한다.
# Chromium 탭은 아직 `navigate` 를 받지 않는다(-32008) — 링크를 눌러 간다.
run fr-nav click --selector '#tofresh'
sleep 2
run fr-click click --selector '#fb'
hit_seen fb-true && echo yes > "\$out/fb-hit" || echo no > "\$out/fb-hit"
run hop-nav click --selector '#tohop'
sleep 2
# 이 탭이 정말 다시 숨었는지(5 회차 — 첫 숨김의 hid-vis 같은 확인이 없었다): 새로 불린 hop 문서가 hidden 으로 알린다.
hit_seen hopvis-hidden && echo yes > "\$out/hop-vis" || echo no > "\$out/hop-vis"
hop_to=0; hop_max=0
for k in 1 2 3 4 5 6 7 8 9 10; do
    s0=\$(date +%s)
    run hop-wait-\$k wait --selector '#hop' --timeout 5000
    s1=\$(date +%s)
    grep -q '(-32004)' "\$out/hop-wait-\$k" && hop_to=\$((hop_to + 1))
    [ \$((s1 - s0)) -gt \$hop_max ] && hop_max=\$((s1 - s0))
    sleep 0.5 # 이동을 여러 번 넘기게(숨은 탭의 타이머는 1 초 단위)
done
hop_role_max=0
for k in 1 2 3; do
    r0=\$(date +%s)
    run hop-role-\$k click --role button --name 'Hop go' --exact
    r1=\$(date +%s)
    [ \$((r1 - r0)) -gt \$hop_role_max ] && hop_role_max=\$((r1 - r0))
done
echo "\$hop_to \$hop_max \$(cat "\$out"/hop-role-* | grep -c 'too many DevTools calls') \$hop_role_max" > "\$out/hop-summary"
touch "\$out/show2-now"
sleep 2
# W9b③: 에이전트가 탭을 연다 — 이 pane 의 탭 줄 끝에 뒤쪽 탭으로(화면 그대로), 첫 불러오기까지 기다려 id 를 준다.
"\$cli" browser open --url "http://127.0.0.1:$port/ag.html" > "\$out/ag-open" 2>&1; echo "rc=\$?" >> "\$out/ag-open"
ag=\$(sed -n 's/^opened \([0-9]*\) .*/\1/p' "\$out/ag-open")
echo "\$ag" > "\$out/ag-id"
hit_seen agvis-hidden && echo yes > "\$out/ag-hidden" || echo no > "\$out/ag-hidden"
# 처음부터 숨긴 탭의 첫 클릭이 페이지에 닿는다(누르기 전 프레임).
"\$cli" browser click --surface "\$ag" --selector '#ab' > "\$out/ag-click" 2>&1; echo "rc=\$?" >> "\$out/ag-click"
hit_seen ab-true && echo yes > "\$out/ab-hit" || echo no > "\$out/ab-hit"
# 그 탭의 페이지가 연 새 탭 — 뒤쪽(숨김), 에이전트 탭이라 곧 닫을 수 있다(결정 ④).
"\$cli" browser click --surface "\$ag" --selector '#pop' > "\$out/ag-pop" 2>&1; echo "rc=\$?" >> "\$out/ag-pop"
hit_seen ag2vis && echo yes > "\$out/ag2-loaded" || echo no > "\$out/ag2-loaded"
# 팝업 브라우저는 CEF 가 보이게 만들고 maru 가 뒤쪽 탭으로 놓으며 숨긴다 — 첫 알림은 visible 일 수 있다(곧 hidden 이면 된다).
hit_seen ag2vis-hidden && echo yes > "\$out/ag2-hidden" || echo no > "\$out/ag2-hidden"
"\$cli" browser list > "\$out/ag-list" 2>&1
ag2=\$(awk '/^surface .*ag2\.html/{print \$2; exit}' "\$out/ag-list")
# 사용자 탭(이 pane 이 열지 않았다 — 조작 허락은 받았다)은 닫지 못한다.
"\$cli" browser close --surface "\$sid" > "\$out/ag-close-user" 2>&1; echo "rc=\$?" >> "\$out/ag-close-user"
# 글을 넣은 탭 — 페이지가 떠나기 확인으로 묻는다: 닫지 않고 곧 답한다(사용자가 그 탭에서 정한다).
"\$cli" browser type --surface "\$ag" --selector '#t' --text 'draft' > "\$out/ag-type" 2>&1; echo "rc=\$?" >> "\$out/ag-type"
c0=\$(date +%s)
"\$cli" browser close --surface "\$ag" > "\$out/ag-close-ask" 2>&1; echo "rc=\$?" >> "\$out/ag-close-ask"
c1=\$(date +%s)
echo "\$((c1 - c0))" > "\$out/ag-close-ask-secs"
"\$cli" browser close --surface "\$ag2" > "\$out/ag-close" 2>&1; echo "rc=\$?" >> "\$out/ag-close"
"\$cli" browser list > "\$out/ag-list2" 2>&1
# W9f: MCP 서버(새 세션 — 신원은 이 pane 의 foreground 조상으로 찾는다)와 repl.
python3 "$root/mcp_drive.py" "\$cli" "http://127.0.0.1:$port" "\$out" > "\$out/mcp-py" 2>&1; echo "rc=\$?" >> "\$out/mcp-py"
hit_seen mb-true && echo yes > "\$out/mb-hit" || echo no > "\$out/mb-hit"
hit_seen mt-true---help && echo yes > "\$out/mt-hit" || echo no > "\$out/mt-hit"
printf 'use x\nopen --url http://127.0.0.1:$port/mcp.html?repl\nclick --selector "#rb"\nclose\n' | "\$cli" browser repl > "\$out/repl" 2>&1; echo "rc=\$?" >> "\$out/repl"
hit_seen rb2-true && echo yes > "\$out/rb2-hit" || echo no > "\$out/rb2-hit"
# 접속이 안 되는 주소 — 실패한 이동도 곧 끝이다(적대 리뷰 1 회차: 25 초를 다 기다렸다).
f0=\$(date +%s)
"\$cli" browser open --url "http://127.0.0.1:1/" > "\$out/ag-refused" 2>&1; echo "rc=\$?" >> "\$out/ag-refused"
f1=\$(date +%s)
echo "\$((f1 - f0))" > "\$out/ag-refused-secs"
af=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/ag-refused")
"\$cli" browser close --surface "\$af" > /dev/null 2>&1 || true
# 3 회차: 처음부터 숨긴 새 탭에 곧장 키 — 요소에 Enter, 글을 넣은 뒤 대상 없는 Enter 가 제출한다(전에는 ok 로 답하고 닿지 않았다).
"\$cli" browser open --url "http://127.0.0.1:$port/frm.html?p1" > "\$out/r3-p1-open" 2>&1
fp1=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/r3-p1-open")
"\$cli" browser press --surface "\$fp1" --selector '#q' --key Enter > "\$out/r3-p1" 2>&1; echo "rc=\$?" >> "\$out/r3-p1"
hit_seen submit-p1 && echo yes > "\$out/r3-p1-hit" || echo no > "\$out/r3-p1-hit"
"\$cli" browser open --url "http://127.0.0.1:$port/frm.html?p2" > "\$out/r3-p2-open" 2>&1
fp2=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/r3-p2-open")
"\$cli" browser type --surface "\$fp2" --selector '#q' --text 'x' > "\$out/r3-p2-type" 2>&1
"\$cli" browser press --surface "\$fp2" --key Enter > "\$out/r3-p2" 2>&1; echo "rc=\$?" >> "\$out/r3-p2"
hit_seen submit-p2 && echo yes > "\$out/r3-p2-hit" || echo no > "\$out/r3-p2-hit"
"\$cli" browser close --surface "\$fp1" > /dev/null 2>&1 || true
"\$cli" browser close --surface "\$fp2" > /dev/null 2>&1 || true
# 상한 — 이 pane 의 에이전트 탭 8 개(ag 가 하나 남았다 — 일곱 더, 아홉째는 거절).
"\$cli" browser open --url "http://127.0.0.1:$port/ag.html?cap" > "\$out/ag-cap-1" 2>&1; echo "rc=\$?" >> "\$out/ag-cap-1"
for k in 2 3 4 5 6 7 8; do
    "\$cli" browser open > "\$out/ag-cap-\$k" 2>&1; echo "rc=\$?" >> "\$out/ag-cap-\$k"
done
# 상한에 닿은 뒤 에이전트 탭의 팝업은 더 열리지 않는다(적대 리뷰 1 회차: 보통 탭으로 계속 생겼다). 떠나기 확인이 없는 탭에서 — 누름은 닿는다.
capt=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/ag-cap-1")
"\$cli" browser list > "\$out/ag-cap-list0" 2>&1
"\$cli" browser click --surface "\$capt" --selector '#ab' > "\$out/ag-cap-ab" 2>&1; echo "rc=\$?" >> "\$out/ag-cap-ab"
"\$cli" browser click --surface "\$capt" --selector '#pop' > "\$out/ag-cap-pop" 2>&1; echo "rc=\$?" >> "\$out/ag-cap-pop"
sleep 2
"\$cli" browser list > "\$out/ag-cap-list1" 2>&1
# op 도중 뜬 JS 대화상자 — 시한·30 초를 기다리지 않고 그 이유로 곧 끝난다(적대 리뷰 2 회차: 30 초 뒤 「maru 가 없다」).
"\$cli" browser click --surface "\$capt" --selector '#al2' > "\$out/ag-al" 2>&1; echo "rc=\$?" >> "\$out/ag-al"
d0=\$(date +%s)
"\$cli" browser wait --surface "\$capt" --selector '#never' --timeout 8000 > "\$out/ag-dlg-wait" 2>&1; echo "rc=\$?" >> "\$out/ag-dlg-wait"
d1=\$(date +%s)
echo "\$((d1 - d0))" > "\$out/ag-dlg-secs"
# 3 회차 — 빈 상한 탭 셋을 닫아 자리를 낸다.
for k in 2 3 4; do
    bid=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/ag-cap-\$k")
    "\$cli" browser close --surface "\$bid" > "\$out/r3-free-\$k" 2>&1
done
# 제출이 alert 를 띄운다 — 키는 갔다: ok 와 「다시 하지 말라」(전에는 실패로 답해 다시 하면 두 번 제출).
"\$cli" browser open --url "http://127.0.0.1:$port/frma.html?d" > "\$out/r3-da-open" 2>&1
da=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/r3-da-open")
"\$cli" browser press --surface "\$da" --selector '#q' --key Enter > "\$out/r3-da" 2>&1; echo "rc=\$?" >> "\$out/r3-da"
n=0; while [ \$n -lt 20 ] && ! grep -q 'POST /hit?dsubmit-d' "$root/http.log"; do sleep 0.25; n=\$((n + 1)); done
grep -q 'POST /hit?dsubmit-d' "$root/http.log" && echo yes > "\$out/r3-da-hit" || echo no > "\$out/r3-da-hit"
# 같은 출처 팝업이 alert 를 띄운다 — 연 탭의 op 은 30 초 매달리지 않고 곧 그 이유로 끝난다.
"\$cli" browser open --url "http://127.0.0.1:$port/shr.html?f" > "\$out/r3-sh-open" 2>&1
sh=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/r3-sh-open")
"\$cli" browser click --surface "\$sh" --selector '#pop' > "\$out/r3-sh-pop" 2>&1
hit_seen shr2-load || true
sleep 2
f0=\$(date +%s)
"\$cli" browser click --surface "\$sh" --selector '#ok' > "\$out/r3-fam" 2>&1; echo "rc=\$?" >> "\$out/r3-fam"
f1=\$(date +%s)
echo "\$((f1 - f0))" > "\$out/r3-fam-secs"
touch "\$out/done"
exec sleep 600
PANE
chmod +x "$root/pane.sh"

out="$root/out"
mkdir -p "$out" "$root/home"
# 숨은 탭 경우(W9b②-3) — pane 대본이 hide-now 를 만들면 새 탭으로 Chromium 탭을 숨기고, show-now 면 돌아온다.
printf 'waitfile %s\naction new_tab\nwaitfile %s\naction previous_tab\nwaitfile %s\naction new_tab\nwaitfile %s\naction previous_tab\n' "$out/hide-now" "$out/show-now" "$out/hide2-now" "$out/show2-now" > "$root/hide.txt"
printf 'ui.language = ko\nshell.command = %s\nshell.args =\nsession.keep-alive-after-quit = false\n' "$root/pane.sh" > "$root/maru.conf"
env HOME="$root/home" CFFIXED_USER_HOME="$root/home" XDG_CACHE_HOME="$root/home/.cache" MARU_SESSION_HOST_ROOT="$root/session-host" \
    MARU_CONFIG="$root/maru.conf" MARU_WEB_PANEL=1 MARU_WEB_OSR_DIR="$sidecar_dir" MARU_WEB_OSR_TEST_URL="$url" \
    MARU_TEST_GRANT_DECISION=approve MARU_SMOKE_OUT="$out" MARU_SMOKE_HOME="$root/home" MARU_WEB_OSR_TEST_INPUT="$root/hide.txt" \
    "$app" > "$root/app.log" 2>&1 &
app_pid=$!
i=0
while [ ! -f "$out/done" ] && [ $i -lt 320 ]; do sleep 1; i=$((i + 1)); done
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
ok tx-hidden && [ "$(cat "$out/td-hit")" = yes ] || fail "a button whose text has a hidden duplicate was not found by text and clicked ($(tr '\n' ' ' < "$out/tx-hidden"))"
ok tx-split && [ "$(cat "$out/sp-hit")" = yes ] || fail "text split across elements was not found exactly ($(tr '\n' ' ' < "$out/tx-split"))"
ok tx-sr && [ "$(cat "$out/icon-hit")" = yes ] || fail "screen-reader-only text did not lead to clicking its button ($(tr '\n' ' ' < "$out/tx-sr"))"
ok lb-type && [ "$(cat "$out/em2-hit")" = yes ] || fail "typing by label (an aria-hidden star excluded, exact) did not go in ($(tr '\n' ' ' < "$out/lb-type"))"
grep -q 'not ok' "$out/lb-hidden" && grep -q '^hint: 1 matching' "$out/lb-hidden" || fail "a hidden checkbox by label did not answer not ok with a hint ($(tr '\n' ' ' < "$out/lb-hidden"))"
ok tx-dm && [ "$(cat "$out/dm-hit")" = yes ] || fail "clicking the visible label text did not toggle the hidden checkbox ($(tr '\n' ' ' < "$out/tx-dm"))"
grep -q 'ambiguous: 2 elements match text~"Archive item"' "$out/tx-amb" && ok tx-ref && [ "$(cat "$out/ar1-hit")" = yes ] || fail "an ambiguous text did not give candidate refs that click for real ($(tr '\n' ' ' < "$out/tx-amb") · $(tr '\n' ' ' < "$out/tx-ref"))"
ok tx-card && [ "$(cat "$out/card-hit")" = yes ] || fail "clicking a card's title text pressed something else at the card's center ($(tr '\n' ' ' < "$out/tx-card") · $(grep -c 'GET /hit?cdel' "$root/http.log") cdel)"
ok tx-more && [ "$(cat "$out/rm-hit")" = yes ] || fail "an off-page \"Read more about ...\" span hid its visible link ($(tr '\n' ' ' < "$out/tx-more"))"
grep -q 'not ok' "$out/tx-host" && grep -q '^hint: 1 matching' "$out/tx-host" && [ "$(cat "$out/xm-hit")" = no ] || fail "an unrendered light child of a shadow host made the host match and its button get pressed ($(tr '\n' ' ' < "$out/tx-host") · xm $(cat "$out/xm-hit"))"
ok tx-pe && [ "$(cat "$out/pen-hit")" = yes ] || fail "pointer-events:none text inside a button was refused as covered or not clicked ($(tr '\n' ' ' < "$out/tx-pe"))"
ok tx-icon && [ "$(cat "$out/mi-hit")" = yes ] || fail "an aria-hidden icon ligature broke an exact text match ($(tr '\n' ' ' < "$out/tx-icon"))"
ok tx-dc && [ "$(cat "$out/dcb-hit")" = yes ] || fail "display:contents text was taken for hidden ($(tr '\n' ' ' < "$out/tx-dc"))"
grep -q 'covered' "$out/tx-busy" && ! grep -q 'GET /hit?busy-' "$root/http.log" || fail "a loading overlay on a box around the text was not refused as covered ($(tr '\n' ' ' < "$out/tx-busy"))"
ok tx-touch && [ "$(cat "$out/tt-hit")" = yes ] || fail "a touch target inside the button was refused or the button was not clicked ($(tr '\n' ' ' < "$out/tx-touch"))"
grep -q 'covered' "$out/tx-inner" && ! grep -q 'GET /hit?cd2' "$root/http.log" || fail "another button inside the card covering the text was not refused ($(tr '\n' ' ' < "$out/tx-inner"))"
ok tx-stouch && [ "$(cat "$out/stb-hit")" = yes ] || fail "a touch target inside a shadow button with a slot was refused or not clicked ($(tr '\n' ' ' < "$out/tx-stouch"))"
ok tx-gone && [ "$(cat "$out/gs-hit")" = yes ] || fail "an off-page copy of the same text broke an exact match ($(tr '\n' ' ' < "$out/tx-gone"))"
ok tx-sel || fail "a label holding a select was not found by its text exactly ($(tr '\n' ' ' < "$out/tx-sel"))"
ok lb-tiny && [ "$(cat "$out/tg-hit")" = yes ] || fail "an sr-only toggle checkbox found by label was not turned on through its label ($(tr '\n' ' ' < "$out/lb-tiny"))"
grep -q 'covered' "$out/tx-link" && ! grep -q 'GET /hit?tos-link' "$root/http.log" || fail "text whose center is a link inside it pressed the link or was not refused ($(tr '\n' ' ' < "$out/tx-link"))"
ok tx-radio && [ "$(cat "$out/pro-hit")" = yes ] || fail "a plan card whose transparent radio covers its text was refused or the radio was not chosen ($(tr '\n' ' ' < "$out/tx-radio"))"
grep -q 'covered' "$out/tx-iframe" && ! grep -q 'GET /hit?ifc' "$root/http.log" || fail "an iframe covering a card's text was not refused as covered ($(tr '\n' ' ' < "$out/tx-iframe"))"
grep -q 'not ok' "$out/tx-unr" && grep -q '^hint: 1 matching' "$out/tx-unr" || fail "an unrendered match with aria-hidden text did not give a hint ($(tr '\n' ' ' < "$out/tx-unr"))"
grep -q 'not ok' "$out/tx-nth" && ! grep -q '^hint:' "$out/tx-nth" || fail "nth past the visible matches gave a hidden-element hint ($(tr '\n' ' ' < "$out/tx-nth"))"
ok wv-role && grep -q 'matched n[0-9]* "Ready now"' "$out/wv-role" || fail "waiting by role for a button made 2 s later did not answer ok with matched ($(tr '\n' ' ' < "$out/wv-role"))"
ok wv-amb && grep -q '^warning: ambiguous' "$out/wv-amb" || fail "waiting for a text matching two buttons did not answer ok with an ambiguous warning ($(tr '\n' ' ' < "$out/wv-amb"))"
grep -q '(-32004)' "$out/wv-off" && grep -q '^hint: 1 matching' "$out/wv-off" || fail "an off-canvas button was taken for visible, or the timeout had no hidden hint ($(tr '\n' ' ' < "$out/wv-off"))"
echo "PASS wait-visible: a role wait sees a button made 2 s later (matched), two matches answer with an ambiguous warning, an off-canvas button times out with a hidden hint"
[ "$(cat "$out/hid-vis")" = yes ] || fail "the Chromium tab was not hidden by the new tab (no visibilitychange to hidden) — the hidden-tab cases would prove nothing"
set -- $(cat "$out/hid-secs")
ok hid-role && [ "$(cat "$out/hb-hit")" = yes ] && [ "$1" -le 3 ] || fail "a role click on a hidden tab did not press for real within 3 s (${1}s · $(tr '\n' ' ' < "$out/hid-role"))"
ok hid-hover && [ "$(cat "$out/hh-hit")" = yes ] && [ "$2" -le 3 ] || fail "a hover on a hidden tab did not reach the page within 3 s (${2}s · $(tr '\n' ' ' < "$out/hid-hover"))"
ok hid-wait || fail "a text wait on a hidden tab did not see a button made in an animation frame ($(tr '\n' ' ' < "$out/hid-wait"))"
ok fr-click && [ "$(cat "$out/fb-hit")" = yes ] || fail "a selector click on a document loaded while the tab was hidden did not reach the page ($(tr '\n' ' ' < "$out/fr-click") · fresh loads $(grep -c 'GET /fresh.html' "$root/http.log"))"
read hop_to hop_max hop_busy hop_role_max < "$out/hop-summary" || true
hop_loads=$(grep -c 'GET /hop.html' "$root/http.log" || true)
[ "$(cat "$out/hop-vis")" = yes ] || fail "the hopping page was not hidden by the second new tab (no hidden load) — the case proves nothing ($(grep -o 'hopvis-[a-z]*' "$root/http.log" | sort | uniq -c | tr '\n' ' '))"
[ "$hop_loads" -ge 5 ] || fail "the hopping page did not keep reloading on the hidden tab ($hop_loads loads) — the case proves nothing ($(tr '\n' ' ' < "$out/hop-nav"))"
echo "hidden hopping tab ($hop_loads loads): selector waits timed out $hop_to/10 (longest ${hop_max}s) · role clicks answered 'too many' $hop_busy/3 (longest ${hop_role_max}s)"
# role 클릭은 새로고침 사이에 「context 없음」으로 끝날 수 있다 — 다만 자리를 기다려도(최대 4.5 초) 곧 답해야 한다(4 회차).
[ "$hop_to" = 0 ] && [ "$hop_busy" = 0 ] && [ "${hop_role_max:-99}" -le 6 ] || fail "on a hidden tab that keeps navigating, a lost screenshot blocked later calls ($hop_to/10 selector waits timed out, longest ${hop_max}s · $hop_busy/3 role clicks 'too many', longest role click ${hop_role_max}s — over 6 s means a call waited for a lost screenshot)"
# W9b③
grep -q '^opened [0-9]* http://127.0.0.1:[0-9]*/ag.html$' "$out/ag-open" && grep -q '^rc=0$' "$out/ag-open" && ! grep -q '^warning' "$out/ag-open" || fail "browser open did not answer the new tab after its first load ($(tr '\n' ' ' < "$out/ag-open"))"
[ "$(cat "$out/ag-hidden")" = yes ] || fail "the agent's tab was not opened behind the current one (the page was not hidden — $(grep -o 'agvis-[a-z]*' "$root/http.log" | tr '\n' ' '))"
ok ag-click && [ "$(cat "$out/ab-hit")" = yes ] || fail "the first click on the agent's new (hidden) tab did not reach the page ($(tr '\n' ' ' < "$out/ag-click"))"
ag2_place=$(grep 'osr-test newtab .*adopted=true' "$root/app.log" | tail -1)
echo "$ag2_place" | grep -q 'placement=background' && [ "$(echo "$ag2_place" | sed -n 's/.* at=\([0-9]*\) .*/\1/p')" != "$(echo "$ag2_place" | sed -n 's/.* active=\([0-9]*\) .*/\1/p')" ] || fail "a tab the agent's page opened was put in front ($ag2_place)"
[ "$(cat "$out/ag2-loaded")" = yes ] && [ "$(cat "$out/ag2-hidden")" = yes ] || fail "a tab the agent's page opened did not open behind (loaded $(cat "$out/ag2-loaded"), hidden $(cat "$out/ag2-hidden"))"
grep -q 'not opened by this pane' "$out/ag-close-user" && ! grep -q '^rc=0$' "$out/ag-close-user" || fail "the agent closed (or tried to close) a tab it did not open ($(tr '\n' ' ' < "$out/ag-close-user"))"
ok ag-type && grep -q '^not closed: the page asks before leaving' "$out/ag-close-ask" && [ "$(cat "$out/ag-close-ask-secs")" -le 3 ] || fail "closing a tab whose page asks before leaving did not answer 'not closed' at once ($(tr '\n' ' ' < "$out/ag-close-ask") · $(cat "$out/ag-close-ask-secs")s)"
grep -q '^closed$' "$out/ag-close" && grep -q '^rc=0$' "$out/ag-close" && ! grep -q 'ag2\.html' "$out/ag-list2" || fail "the agent could not close the tab its page opened ($(tr '\n' ' ' < "$out/ag-close"))"
for k in 1 2 3 4 5 6 7; do grep -q '^opened [0-9]*' "$out/ag-cap-$k" && grep -q '^rc=0$' "$out/ag-cap-$k" || fail "agent tab $k of 8 did not open ($(tr '\n' ' ' < "$out/ag-cap-$k"))"; done
[ "$(cat "$out/ag-refused-secs")" -le 5 ] && grep -q '^opened [0-9]*' "$out/ag-refused" || fail "opening an address that refuses connections did not answer soon ($(cat "$out/ag-refused-secs")s · $(tr '\n' ' ' < "$out/ag-refused"))"
ok ag-cap-pop && [ "$(grep -c 'GET /hit?ab-true' "$root/http.log")" -ge 2 ] || fail "the click on a capped agent tab did not reach the page — the popup check proves nothing ($(tr '\n' ' ' < "$out/ag-cap-pop"))"
ok ag-al && grep -q 'showing a dialog' "$out/ag-dlg-wait" && [ "$(cat "$out/ag-dlg-secs")" -le 6 ] || fail "a wait on a tab whose page showed an alert mid-way did not end at once with the dialog reason ($(cat "$out/ag-dlg-secs")s · $(tr '\n' ' ' < "$out/ag-dlg-wait"))"
[ "$(grep -c '^surface ' "$out/ag-cap-list0")" = "$(grep -c '^surface ' "$out/ag-cap-list1")" ] || fail "a popup from the agent's tab opened past the cap of 8 ($(grep -c '^surface ' "$out/ag-cap-list0") → $(grep -c '^surface ' "$out/ag-cap-list1") tabs)"
grep -q 'already has 8 tabs' "$out/ag-cap-8" || fail "a ninth agent tab was not refused ($(tr '\n' ' ' < "$out/ag-cap-8"))"
# W9b③ 적대 리뷰 3 회차
[ "$(cat "$out/r3-p1-hit")" = yes ] && grep -q '^ok$' "$out/r3-p1" || fail "Enter on an element of a new hidden tab did not submit the form ($(tr '\n' ' ' < "$out/r3-p1") · $(tr '\n' ' ' < "$out/r3-p1-open"))"
[ "$(cat "$out/r3-p2-hit")" = yes ] && grep -q '^ok$' "$out/r3-p2" || fail "Enter where the focus is on a new hidden tab did not submit the form ($(tr '\n' ' ' < "$out/r3-p2") · $(tr '\n' ' ' < "$out/r3-p2-type"))"
grep -q '^ok$' "$out/r3-da" && grep -q '^warning: the page opened a dialog' "$out/r3-da" && grep -q '^rc=0$' "$out/r3-da" && [ "$(cat "$out/r3-da-hit")" = yes ] || fail "a key whose submit opened an alert was not answered as delivered with a do-not-repeat warning ($(tr '\n' ' ' < "$out/r3-da") · hit $(cat "$out/r3-da-hit"))"
grep -q 'showing a dialog' "$out/r3-fam" && [ "$(cat "$out/r3-fam-secs")" -le 5 ] || fail "an op on a tab whose same-origin popup showed an alert did not end at once with the dialog reason ($(cat "$out/r3-fam-secs")s · $(tr '\n' ' ' < "$out/r3-fam") · pop $(tr '\n' ' ' < "$out/r3-sh-pop"))"
echo "PASS agent-keys-dialogs: Enter on a new hidden tab submits (on the element and where the focus is), a key whose submit opens an alert is answered as delivered with a warning, a same-origin popup's alert ends the opener's op at once ($(cat "$out/r3-fam-secs")s)"
# W9f
grep -q '^rc=0$' "$out/mcp-py" || fail "the MCP driver failed ($(tr '\n' ' ' < "$out/mcp-py" | cut -c1-600) · $(tail -3 "$out/mcp-log" 2>/dev/null | tr '\n' ' ' | cut -c1-600))"
mcp_get() { sed -n "s/^$1=//p" "$out/mcp"; }
[ "$(mcp_get nosid)" = yes ] || fail "the MCP server was not started in a new session — the identity case proves nothing"
[ "$(mcp_get proto)" = 2025-06-18 ] && [ "$(mcp_get tools)" -ge 18 ] || fail "MCP initialize or tools/list did not answer ($(tr '\n' ' ' < "$out/mcp"))"
mcp_get open | grep -q '^opened [0-9]* http://127.0.0.1:[0-9]*/mcp.html$' || fail "browser_open from an MCP server in a new session did not open a tab ($(mcp_get open))"
[ "$(mcp_get click)" = "ok False" ] && [ "$(cat "$out/mb-hit")" = yes ] || fail "browser_click through MCP did not click for real ($(mcp_get click))"
[ "$(mcp_get type)" = "ok False" ] && [ "$(cat "$out/mt-hit")" = yes ] || fail "browser_type through MCP did not type the text --help as text ($(mcp_get type) · $(grep 'GET /hit?mt' "$root/http.log" | tr '\n' ' '))"
# exec 는 Chromium 탭에서 아직 -32008(W9a) — 식 `-1` 이 옵션으로 읽히지 않고 엔진까지 갔는지만 본다(W9a 뒤에는 결과 -1).
mcp_get exec | grep -q '^-1 False$\|(-32008)' || fail "browser_exec through MCP did not send an expression starting with - to the engine ($(mcp_get exec))"
# screenshot 도 Chromium 탭에서 아직 -32008(W9a) — W9a 에서 PNG 그림만 받게 조인다.
mcp_get shot | grep -q '^png$\|(-32008)' || fail "browser_screenshot through MCP did not return a PNG image ($(mcp_get shot))"
[ "$(mcp_get pipelined)" = "p1,p2,listed" ] || fail "two MCP calls sent back to back did not get their own answers in order ($(mcp_get pipelined))"
[ "$(mcp_get badarg)" = error ] || fail "a misspelled MCP tool argument was not refused"
[ "$(mcp_get close)" = "closed False" ] || fail "browser_close through MCP did not close the tab ($(mcp_get close))"
[ "$(mcp_get rest)" = empty ] && [ "$(mcp_get rc)" = 0 ] || fail "maru mcp wrote extra output or did not exit 0 at the end of input ($(tr '\n' ' ' < "$out/mcp"))"
echo "PASS mcp: an MCP server started in a new session (no terminal) opens, clicks, types --help as text, sends the expression -1 to the engine, gets an image or the engine's refusal for a screenshot, refuses a misspelled argument and closes, with only JSON-RPC on its output"
# 첫 줄은 틀린 `use`(표준 오류) — 같은 파일로 받아도 줄이 서로 덮이지 않고(W9f 적대 리뷰 1 회차), 실패가 있었으니 종료 상태 1.
grep -q '^error: use needs one tab id' "$out/repl" && grep -q '^opened [0-9]* http://127.0.0.1:[0-9]*/mcp.html?repl$' "$out/repl" && grep -q '^ok$' "$out/repl" && grep -q '^closed$' "$out/repl" && grep -q '^rc=1$' "$out/repl" && [ "$(cat "$out/rb2-hit")" = yes ] || fail "repl did not open a tab, click it without --surface and close it, or its output lines overwrote each other ($(tr '\n' ' ' < "$out/repl"))"
echo "PASS repl: open picked the new tab, click and close ran on it without --surface"
echo "PASS agent-tabs: open answers after the first load with the tab behind the current one, its first click lands, a tab its page opens goes behind and is the agent's, a user tab cannot be closed, a page asking before leaving answers 'not closed' at once, a closed tab leaves the list, the ninth tab is refused"
echo "PASS hidden-tab: on a hidden tab a role click presses for real (${1}s), hover reaches the page (${2}s), a wait sees a button made in an animation frame"
echo "PASS text-label: text (hidden duplicate, split exact, sr-only → its button) and label (aria-hidden star excluded) act for real, a hidden checkbox gives a hint and its visible text toggles it, an ambiguous text gives refs, a card title is pressed itself, an off-page span does not hide its link, a shadow host's unrendered light text gives a hint, pointer-events:none text goes to its button, an aria-hidden icon is left out of exact text, display:contents text is found, a loading overlay and another button over the text are covered, a touch target (also in a shadow button) goes to its button, an off-page copy and a select do not break exact text, an sr-only toggle is turned on by its label, text around a link is not pressed on the link, a transparent radio over a plan card is chosen, an iframe over a card is covered, an unrendered match gives a hint, nth past the visible matches gives no hint"
ok hover && [ "$(cat "$out/hv-hit")" = yes ] || fail "hover did not give the element a real pointer move ($(tr '\n' ' ' < "$out/hover"))"
grep -q 'not ok' "$out/hover-missing" || fail "hovering a missing element was not not ok ($(tr '\n' ' ' < "$out/hover-missing"))"
echo "PASS hover: the element got a real (isTrusted) mouseover, a missing element is not ok"
grep -q 'ambiguous: 2 elements match role=button name~"Role Save"' "$out/role-amb" && [ -n "$(cat "$out/amb-ref")" ] || fail "an ambiguous role locator did not fail with candidate refs ($(tr '\n' ' ' < "$out/role-amb"))"
ok role-ref && [ "$(cat "$out/rs1-hit")" = yes ] || fail "clicking the candidate ref $(cat "$out/amb-ref") did not click Role Save for real ($(tr '\n' ' ' < "$out/role-ref"))"
ok role-nth && grep -q 'matched n[0-9]* "Role Save draft"' "$out/role-nth" && [ "$(cat "$out/rs2-hit")" = yes ] || fail "--nth 1 did not click the second match for real ($(tr '\n' ' ' < "$out/role-nth"))"
ok role-exact && grep -q 'matched n[0-9]* "Role Save"$' "$out/role-exact" || fail "--exact did not pick only Role Save ($(tr '\n' ' ' < "$out/role-exact"))"
ok role-level && grep -q 'matched n[0-9]* "Role Heading"' "$out/role-level" || fail "--level 2 did not find the h2 ($(tr '\n' ' ' < "$out/role-level"))"
grep -q '(-32602)' "$out/role-unknown" && grep -q 'did you mean "button"' "$out/role-unknown" || fail "an unknown role was not invalid params with a suggestion ($(tr '\n' ' ' < "$out/role-unknown"))"
ok role-shadow && [ "$(cat "$out/osb-hit")" = yes ] || fail "a button inside nested open shadow roots was not found and clicked by role ($(tr '\n' ' ' < "$out/role-shadow"))"
grep -q 'too_large: page has [0-9]* elements' "$out/role-big" || fail "a page with over 30000 elements was not refused before the query ($(tr '\n' ' ' < "$out/role-big"))"
for pair in "c1:same-page #links without a target" "c2:radio inputs" "c3:role=radio elements" "c4:labeled form controls" "c5:line fragments per block" "c6:text nodes per block"; do
    c=${pair%%:*}
    what=${pair#*:}
    grep -q "too_large: the accessibility query would freeze this page (~*[0-9]* $what" "$out/costly-$c" || fail "a page with too many $what was not refused before the accessibility query ($(tr '\n' ' ' < "$out/costly-$c"))"
done
echo "PASS role-costly: pages with too many #links without a target, radios, role=radio, labeled controls, line fragments or text nodes per block are refused before the query"
echo "PASS role: an ambiguous name failed with candidate refs and the ref clicked for real, --nth/--exact/--level picked the right element (matched), an unknown role suggested button, a button in nested open shadow roots was clicked, a 31000-element page was refused"
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
