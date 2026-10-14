#!/bin/sh
# W9b① 실측 — pane 안의 에이전트(이 대본이 띄운 pane 셸)가 Chromium(OSR) 탭을 DevTools 로 움직이는가(docs/plans/web-osr-backend.md
# W9). 앱을 **일반 모드**로 띄운다(스모크 모드는 셸을 고정 시험 셸로 바꾼다). 확인 모달은 `MARU_TEST_GRANT_DECISION=approve` 로
# 자동 승인한다. 시험 페이지는 `MARU_WEB_OSR_TEST_URL`(시작 브라우저 탭 — `MARU_WEB_PANEL=1`).
#
#   click-trusted   `maru browser click --selector '#b'` → ok, 페이지는 사람 클릭(`isTrusted`)으로 받는다(페이지가 서버로 보내는 신호
#                   요청 `/hit?b-true` — `browser list` 의 제목은 페이지 제목이 아니라 탭 이름이다(WebKit 과 같다 — W9a 작성자 선택), 이동은 주소 칸으로 본다)
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
#   w9c-dialog      (W9c②) 에이전트가 JS 대화상자를 보고 답한다: 누름 뒤 alert — 다음 op 은 handle-dialog 를 가리키며 곧 실패, `dialog` 가
#                   종류·원인(agent)·답해도 되나·줄바꿈을 보이고, 답하면 페이지가 이어 간다 · prompt 글이 페이지에 닿는다 · confirm 닫기는 false ·
#                   confirm 뒤 alert(사슬)도 에이전트 것 · 누름 뒤 setTimeout 의 alert 도 에이전트 것 · 모르는 번호는 실패 · 같은 출처 팝업의
#                   alert 는 연 탭에서 번호로 답한다(번호 없이는 「no dialog」) · 에이전트가 물은 닫기의 떠나기 확인에 떠나기로 답하면 탭이
#                   닫힌다 · navigate 가 떠나기 확인으로 실패한 탭에 떠나기로 답하면 이동이 이어진다 · 사람 탭(이 pane 이 열지 않았다)의 누가
#                   띄웠는지 모르는 alert(스크립트 6.5 초 뒤)는 거절한다(C13). 「사용자가 손댄 문서」 의 떠나기 거절은 사람 입력이 필요해 단위
#                   시험(web_osr)이 본다
#   w9c-console     (W9c①) Chromium 탭의 콘솔: 수준(log·info → log·warn·error·debug), 누름의 동기 줄은 곧 이은 console 에 있다, 처음 읽은 뒤에는
#                   이동을 넘어 남는다, --clear 는 비운다, 쏟아지면 maru 표지(버린 수)를 남기고 다 싣지 않는다(남은 줄 + 버린 수 = 3000 — 끝의 버린 수만 실은 frame), alert 가 떠 있어도 읽는다,
#                   잡히지 않은 예외는 (source:line) 을 단다. 사용자의 탭(확인 모달로 허락)을 다른 사이트 A → B(다른 출처 iframe 셋 — 적대
#                   리뷰 2 회차 F2) 뒤 처음 읽으면 A 의 줄이 보이지 않고, 곧 C 로 옮긴 뒤(빠른 사슬 — 2 회차 F1) 다시 읽어도 C 에 늦게 온 A 의
#                   unload 줄은 보이지 않는다 — 대조: 앞 사이트에서 먼저 읽은 탭은 그 unload 줄을 이동 뒤에도 본다(줄은 와 있었다). 에이전트가
#                   연 탭은 태어날 때 묶인다(3 회차 F1): 오류를 남기고 곧 다른 사이트로 옮기는 페이지의 그 오류가 첫 읽기에 있다. 떠날 때 300 줄을
#                   남기는 페이지를 떠나면 앞 문서 양동이를 넘은 줄은 「from pages or origins this tab had just left」 표지로 남는다(4 회차 A).
#                   그 탭을 읽은 적 없는 쪽(둘째 pane — 처음 연 새 탭의 셸, 5 회차 변이 K02–K04): 다른 사이트의 문서에서 접속이 안 되는 주소로
#                   옮겨 오류 페이지가 되면 처음 읽어도 앞 사이트의 줄이 없다(대조: 연 pane 은 그 줄을 봤다), 쏟고 곧 옮긴 문서의 버린 수가 옮겨
#                   간 문서의 표지로 보이지 않는다(대조: 연 pane 은 표지를 봤다), A → B(처음 읽어 묶임) → C 의 빠른 사슬에서 C 가 A·B 출처로
#                   300 줄씩 남겨 둘 다 버려지면 B 에 묶인 쪽에게 B 의 표지가 있다(A 의 줄은 두 문서 앞으로 숨는다 — 사슬이 1 초 창 안이었다는 증거)
#   w9c-upload      (W9c③) 에이전트가 연 탭의 파일 입력칸에 파일을 넣는다(확인 모달은 시험 빌드의 자동 결정 — 앱을
#                   `-Dweb-upload-test-decision=true` 로 만든다, `MARU_TEST_UPLOAD_DECISION` 이 가리키는 파일을 호출마다 바꾼다): 한 파일 —
#                   페이지가 진짜 change(isTrusted)로 받아 내용을 읽어 보낸다 · 상대 경로 둘을 multiple 칸에(CLI 의 현재 폴더로 붙인다) ·
#                   받은 뒤 change 에서 칸을 비우는 칸·칸을 새 것으로 바꿔 끼우는 칸은 성공에 kept:false(다시 올리지 말라는 안내 — 적대 리뷰 1 회차) ·
#                   꺼진 칸·한 파일 칸에 둘은 모달 전에 거절 · 거부는 -32002 · 사본은 프로필의 upload-staging/<탭>/ 아래 0400 ·
#                   모달 동안 페이지가 옮겨 가면 「page changed」 이고 새 문서는 아무것도 받지 않는다 · change 처리기가 곧 같은 출처로 옮기는 칸은
#                   성공에 navigated:true(「try again」 없음 — 적대 리뷰 2 회차) · 탭을 닫으면 그 탭의 사본 폴더가 사라진다
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
iframe_pids=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    for p in $iframe_pids; do kill "$p" 2>/dev/null || true; done
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
# W9c②: 에이전트가 답할 대화상자들 — 답한 뒤 페이지가 이어 가면 신호를 보낸다.
cat > "$root/www/dlg.html" <<'HTML'
<!doctype html><title>dlg</title><script>function hit(w){new Image().src='/hit?'+w}</script>
<button id=al style="position:absolute;left:30px;top:30px;width:120px;height:40px" onclick="alert('hello\nworld');hit('dal-done')">Alert</button>
<button id=pr style="position:absolute;left:30px;top:80px;width:120px;height:40px" onclick="hit('dpr-'+encodeURIComponent(prompt('Name?','def')))">Prompt</button>
<button id=cf style="position:absolute;left:30px;top:130px;width:120px;height:40px" onclick="hit('dcf-'+confirm('Sure?'))">Confirm</button>
<button id=ch style="position:absolute;left:30px;top:180px;width:120px;height:40px" onclick="hit('dch1-'+confirm('one'));alert('two');hit('dch-done')">Chain</button>
<button id=st style="position:absolute;left:30px;top:230px;width:120px;height:40px" onclick="setTimeout(function(){alert('timer');hit('dst-done')},1500)">Timer</button>
HTML
# W9c①: 콘솔 — 수준·누름의 동기 줄·쏟아짐·alert·잡히지 않은 예외. secret 은 다른 사이트(localhost)의 문서 — 불러올 때와 떠날 때 줄을 남긴다.
cat > "$root/www/con.html" <<'HTML'
<!doctype html><title>con</title>
<script>console.log('con-log-'+location.search.slice(1));console.info('con-info');console.warn('con-warn');console.error('con-error');console.debug('con-debug')</script>
<button id=cl style="position:absolute;left:30px;top:30px;width:120px;height:40px" onclick="console.log('con-click-sync')">Log</button>
<button id=fl style="position:absolute;left:30px;top:80px;width:120px;height:40px" onclick="for(var i=0;i<3000;i++)console.log('con-flood-'+i)">Flood</button>
<button id=al style="position:absolute;left:30px;top:130px;width:120px;height:40px" onclick="console.log('con-before-alert');alert('wait')">Alert</button>
<button id=ue style="position:absolute;left:30px;top:180px;width:120px;height:40px" onclick="setTimeout(function(){throw new Error('con-uncaught')},0)">Throw</button>
HTML
printf '<!doctype html><title>secret</title><script>console.log("con-secret-token");addEventListener("pagehide",function(){console.log("con-secret-unload")});addEventListener("unload",function(){console.log("con-secret-unload2")})</script>secret' > "$root/www/secret.html"
# W9c① 적대 리뷰 3 회차 F1: 오류를 남기고 곧 다른 사이트(127.0.0.1)로 옮기는 문서 — 에이전트가 연 탭이면 첫 읽기에 그 오류가 있어야 한다.
printf '<!doctype html><title>redir</title><script>console.error("con-redir-error");location.replace("http://127.0.0.1:%s/con.html?a")</script>redir' "$port" > "$root/www/redir.html"
# W9c① 적대 리뷰 2 회차: 떠날 때(unload) 400 ms 동안 100 ms 마다 줄을 남기는 다른 사이트의 문서, 다른 출처 iframe 셋을 담는 문서(그 출처는
# 아래에서 같은 서버를 포트 셋에 더 띄워 만든다 — 셋이면 전에는 앞 주 프레임 출처를 밀어냈다).
printf '<!doctype html><title>late</title><script>console.log("con-late-token");addEventListener("pagehide",function(){console.log("con-late-pagehide")});addEventListener("unload",function(){var t=Date.now(),k=0;while(Date.now()-t<400){if(Date.now()-t>=k*100){console.log("con-late-unload-"+(k*100));k++}}console.log("con-late-unload-end")})</script>late' > "$root/www/late.html"
printf '<!doctype html><title>f</title>f' > "$root/www/f.html"
# W9c① 적대 리뷰 4 회차 A: 떠날 때(pagehide) 300 줄을 남기는 문서 — 앞 문서 양동이(버스트 80)를 넘는 줄은 버려지고 그 수가 표지로 남는다.
printf '<!doctype html><title>unflood</title><script>console.log("con-unflood-head");addEventListener("pagehide",function(){for(var i=0;i<300;i++)console.log("con-unflood-"+i)})</script>unflood' > "$root/www/unflood.html"
# W9c① 5 회차 변이 K03: 400 줄을 쏟고(탭의 그 밖 양동이 버스트 200 을 넘는다) 곧 옮기는 문서 — 버린 수는 옮기기 전 문서의 것이다. 옮겨 간
# 문서는 경고 한 줄만(오류·경고 양동이는 쏟아짐이 쓰지 않았다 — 그 문서 자신은 버리지 않는다).
printf '<!doctype html><title>k3a</title><script>for(var i=0;i<400;i++)console.log("k3-flood-"+i);location.replace("/k3b.html")</script>k3a' > "$root/www/k3a.html"
printf '<!doctype html><title>k3b</title><script>console.warn("k3-quiet")</script>k3b' > "$root/www/k3b.html"
# K02: A(localhost) → B(127.0.0.1) → C(포트 +1) 의 문서. C 는 A 의 출처와 B 의 출처에서 스크립트를 불러, 두 출처가 300 줄씩 남긴다 — 줄의 출처는
# 그 스크립트 주소라 sidecar 는 A 의 것을 두 문서 앞, B 의 것을 한 문서 앞의 줄로 본다(떠난 지 1 초 창 안).
printf '<!doctype html><title>k2a</title><script>console.log("k2-a-head")</script>k2a' > "$root/www/k2a.html"
printf '<!doctype html><title>k2b</title><script>console.log("k2-b-head")</script>k2b' > "$root/www/k2b.html"
printf '<!doctype html><title>k2c</title><script>console.log("k2-c-head")</script><script src="http://localhost:%s/k2fa.js"></script><script src="http://127.0.0.1:%s/k2fb.js"></script>k2c' "$port" "$port" > "$root/www/k2c.html"
printf 'for(var i=0;i<300;i++)console.log("k2-old-a-"+i)' > "$root/www/k2fa.js"
printf 'for(var i=0;i<300;i++)console.log("k2-old-b-"+i)' > "$root/www/k2fb.js"
printf '<!doctype html><title>con3</title><script>console.log("con3-head")</script><iframe src="http://127.0.0.1:%s/f.html"></iframe><iframe src="http://127.0.0.1:%s/f.html"></iframe><iframe src="http://127.0.0.1:%s/f.html"></iframe>' "$((port + 1))" "$((port + 2))" "$((port + 3))" > "$root/www/con3.html"
# W9c③: 파일 입력칸 — 넣은 파일을 읽어(FileReader) 이름·크기·내용을 신호로 보낸다. up2 는 같은 칸을 가진 다음 문서(모달 동안 옮겨 간다).
for pg in up up2; do
cat > "$root/www/$pg.html" <<HTML
<!doctype html><title>$pg</title><script>
function rep(el,ev){var fs=Array.prototype.slice.call(el.files),n=fs.length,left=n,parts=[],tag='$pg-'+el.id+'-'+n+'-'+ev.isTrusted;if(!n){new Image().src='/hit?'+tag;return}
for(var i=0;i<n;i++)(function(f){var r=new FileReader();r.onload=function(){parts.push(f.name+':'+f.size+':'+String(r.result).trim());if(--left===0){parts.sort();new Image().src='/hit?'+tag+'-'+encodeURIComponent(parts.join('|'))}};r.onerror=function(){new Image().src='/hit?'+tag+'-err-'+r.error.name};r.readAsText(f)})(fs[i])}
</script>
<input type=file id=one onchange="rep(this,event)">
<input type=file id=multi multiple onchange="rep(this,event)">
<input type=file id=dis disabled onchange="rep(this,event)">
<input type=file id=clr onchange="rep(this,event);this.value=''">
<input type=file id=rr onchange="rep(this,event);this.replaceWith(this.cloneNode())">
<input type=file id=nav onchange="var f=this.files[0];location.href='/up3.html?nav-'+this.files.length+'-'+event.isTrusted+'-'+encodeURIComponent(f.name+':'+f.size)">
<button id=later style="position:absolute;left:30px;top:200px;width:120px;height:40px" onclick="setTimeout(function(){location='up2.html'},1200)">Later</button>
HTML
done
# 적대 리뷰 2 회차: change 처리기가 곧 옮겨 가는 칸(nav)의 도착지 — 주소에 받은 파일의 이름·크기를 싣는다(옮겨 가면 이미지 신호는 끊긴다).
printf '<!doctype html><title>up3</title>up3' > "$root/www/up3.html"
mkdir -p "$root/files"
printf 'alpha\n' > "$root/files/a.txt"
printf 'bravo\n' > "$root/files/b.txt"
echo approve > "$root/updecision"
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
# W9a①: navigate·get-url·screenshot — 아래로 긴 문서, 화면에 고정된 빨간 네모(스크롤해도 보기 좌표 20,20), 글이 있으면 떠나기 확인.
printf '<!doctype html><title>w9a</title><style>body{height:5000px;margin:0}#fx{position:fixed;left:20px;top:20px;width:50px;height:50px;background:#f00}</style><div id=fx></div><a id=low href="#" style="position:absolute;left:10px;top:3000px">low</a><input id=t aria-label=Note style="position:absolute;left:100px;top:3020px"><script>addEventListener("beforeunload",function(e){if(document.getElementById("t").value){e.preventDefault();e.returnValue=""}})</script>' > "$root/www/w9a.html"
# W9a 적대 리뷰 5 회차: 불러온 뒤 늦게 붙는 iframe(6 초 늦는 문서) — 그것이 불러오는 동안에도 exec 은 돈다(주 프레임 이동이 아니다).
printf '<!doctype html><title>ifr</title>ifr<script>addEventListener("load",function(){setTimeout(function(){var f=document.createElement("iframe");f.src="/hang?ifr";document.body.appendChild(f)},300)})</script>' > "$root/www/ifr.html"
# 받은 요청을 센다(새로고침이 문서를 다시 불렀는지).
cat > "$root/server.py" <<'PY'
import http.server, sys, functools, time
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow.html"):
            time.sleep(2)  # wait-load: 응답이 늦는 문서
        if self.path.startswith("/hang"):
            # W9a 적대 리뷰 4 회차: 6 초 뒤에 답하는 문서 — 그동안(확정되지 않은 이동) 보낸 exec 은 곧 거절돼야 한다.
            time.sleep(6)
            self.path = "/a.html"
        if self.path.startswith("/csp.html"):
            # W9a②: 엄격 CSP(script-src 'self') — exec 자체는 돌고 그 안의 new Function 은 EvalError(WebKit 과 같다).
            body = b"<!doctype html><title>csp</title><p id=p>csp</p>"
            sys.stderr.write("GET %s\n" % self.path); sys.stderr.flush()
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Security-Policy", "script-src 'self'"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/nocontent"):
            # W9a①: 문서가 없는 응답 — navigate 는 곧 loaded:false 로 끝나야 한다.
            sys.stderr.write("GET %s\n" % self.path); sys.stderr.flush()
            self.send_response(204); self.end_headers(); return
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
for k in 1 2 3; do
    python3 "$root/server.py" "$((port + k))" "$root/www" 2> "$root/http-f$k.log" &
    iframe_pids="$iframe_pids $!"
done
url="http://127.0.0.1:$port/a.html"

# pane 셸 자리에 들어갈 대본 — login(1)이 HOME 을 실제 홈으로 되돌리므로 시험 홈을 직접 세운다(없으면 아무것도 하지 않는다).
cat > "$root/pane.sh" <<PANE
#!/bin/sh
[ -n "\${MARU_SMOKE_HOME:-}" ] && [ -n "\${MARU_SMOKE_OUT:-}" ] || exec sleep 600
export HOME="\$MARU_SMOKE_HOME" XDG_CACHE_HOME="\$MARU_SMOKE_HOME/.cache"
out="\$MARU_SMOKE_OUT"
cli="$cli"
# 대본의 「action new_tab」(숨은 탭 경우)이 연 새 탭의 셸도 이 대본이다 — 한 번만 돈다. 처음 연 새 탭의 pane 은 둘째 읽는 쪽이다(W9c① 5 회차
# 변이 K02·K03·K04 — 그 탭을 읽은 적 없는 pane 의 grant): 첫 pane 이 p2-go 를 만들면 그 탭들을 읽고(K02 는 이동 사슬도 이 pane 이 몬다)
# p2-done 을 만든다. 둘째 새 탭의 pane 은 아무것도 하지 않는다.
if ! mkdir "\$out/pane-once" 2>/dev/null; then
    mkdir "\$out/pane-two" 2>/dev/null || exec sleep 600
    n=0
    while [ ! -f "\$out/p2-go" ] && [ \$n -lt 2400 ]; do sleep 0.25; n=\$((n + 1)); done
    [ -f "\$out/p2-go" ] || exec sleep 600
    ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
    ep=\$(cat "\$out/p2-ep"); k3=\$(cat "\$out/p2-k3"); k2=\$(cat "\$out/p2-k2")
    # K04: 오류 페이지로 바뀐 탭을 처음 읽는다 — 앞 사이트(secret)의 줄이 없어야 한다.
    "\$cli" browser console --surface "\$ep" > "\$out/cn-ep-fresh" 2>&1; echo "rc=\$?" >> "\$out/cn-ep-fresh"
    # K03: 쏟아진 뒤 곧 옮긴 탭을 처음 읽는다 — 앞 문서의 버린 수가 지금 문서의 표지로 오지 않아야 한다.
    "\$cli" browser console --surface "\$k3" > "\$out/cn-k3-fresh" 2>&1; echo "rc=\$?" >> "\$out/cn-k3-fresh"
    # K02: A(localhost) 에 있는 탭을 B(127.0.0.1) 로 옮겨 처음 읽어 B 에 묶이고, 곧 C(포트 +1) 로 — C 는 A 와 B 의 출처 스크립트를 불러
    # 두 출처가 300 줄씩 남긴다(1 초 창 안이라 A 의 것은 두 문서 앞, B 의 것은 한 문서 앞 — 앞 문서 양동이를 넘어 둘 다 버려진다).
    t0=\$(ms)
    "\$cli" browser navigate --surface "\$k2" "http://127.0.0.1:$port/k2b.html" > "\$out/cn-k2-navb" 2>&1
    "\$cli" browser console --surface "\$k2" > "\$out/cn-k2-b" 2>&1; echo "rc=\$?" >> "\$out/cn-k2-b"
    "\$cli" browser navigate --surface "\$k2" "http://127.0.0.1:$((port + 1))/k2c.html" > "\$out/cn-k2-navc" 2>&1
    t1=\$(ms)
    echo "\$((t1 - t0))" > "\$out/cn-k2-ms"
    sleep 1.5
    "\$cli" browser console --surface "\$k2" > "\$out/cn-k2-c" 2>&1; echo "rc=\$?" >> "\$out/cn-k2-c"
    touch "\$out/p2-done"
    exec sleep 600
fi
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
# 링크를 눌러 간다(누르기 사례이기도 하다 — navigate 는 W9a① 사례가 본다).
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
# 글을 넣은 탭 — 페이지가 떠나기 확인으로 묻는다: 닫지 않고 곧 답한다(질문은 탭에 남는다 — 에이전트의 닫기라 W9c② 의 handle-dialog 로 답할 수 있다).
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
printf 'use x\nopen --url http://127.0.0.1:$port/mcp.html?repl\nclick --selector "#rb"\nclose\nclick --selector "#rb"\n' | "\$cli" browser repl > "\$out/repl" 2>&1; echo "rc=\$?" >> "\$out/repl"
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
# W9a①: navigate·get-url·screenshot(뒤쪽 에이전트 탭 — 숨김). 상한 탭 넷을 닫아 자리를 낸다.
for k in 5 6 7 8; do
    bid=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/ag-cap-\$k")
    "\$cli" browser close --surface "\$bid" > /dev/null 2>&1 || true
done
"\$cli" browser open --url "http://127.0.0.1:$port/w9a.html" > "\$out/nv-open" 2>&1
nv=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/nv-open")
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/a.html?nv" > "\$out/nv-a" 2>&1; echo "rc=\$?" >> "\$out/nv-a"
"\$cli" browser get-url --surface "\$nv" > "\$out/nv-url" 2>&1; echo "rc=\$?" >> "\$out/nv-url"
n0=\$(date +%s)
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/nocontent" > "\$out/nv-204" 2>&1; echo "rc=\$?" >> "\$out/nv-204"
n1=\$(date +%s)
echo "\$((n1 - n0))" > "\$out/nv-204-secs"
"\$cli" browser navigate --surface "\$nv" "javascript:alert(1)" > "\$out/nv-js" 2>&1; echo "rc=\$?" >> "\$out/nv-js"
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/w9a.html?back" > "\$out/nv-back" 2>&1; echo "rc=\$?" >> "\$out/nv-back"
"\$cli" browser scroll --surface "\$nv" --selector '#low' > "\$out/nv-scroll" 2>&1
"\$cli" browser screenshot --surface "\$nv" --rect 20,20,50,50 --out "\$out/nv-fx.png" > "\$out/nv-shot" 2>&1; echo "rc=\$?" >> "\$out/nv-shot"
"\$cli" browser screenshot --surface "\$nv" --rect 20,20,50,50 --scale 2 --out "\$out/nv-fx2.png" > "\$out/nv-shot2" 2>&1; echo "rc=\$?" >> "\$out/nv-shot2"
"\$cli" browser screenshot --surface "\$nv" --out "\$out/nv-full.png" > "\$out/nv-shot-full" 2>&1; echo "rc=\$?" >> "\$out/nv-shot-full"
# W9a②: executeScript — 값·await·args(__proto__ 는 자기 속성)·던진 값·문법 오류·너무 큰 결과·식이 - 로 시작·엄격 CSP.
"\$cli" browser exec --surface "\$nv" '1 + 1' > "\$out/ex-sum" 2>&1; echo "rc=\$?" >> "\$out/ex-sum"
"\$cli" browser exec --surface "\$nv" 'Promise.resolve({a:[1,"한"],u:undefined,n:NaN,t:document.title})' > "\$out/ex-obj" 2>&1; echo "rc=\$?" >> "\$out/ex-obj"
"\$cli" browser exec --surface "\$nv" --args '[{"__proto__":{"x":1},"k":2},"s"]' 'Object.prototype.hasOwnProperty.call(args[0],"__proto__") && args[0].x === undefined && args[0].k + args[1]' > "\$out/ex-args" 2>&1; echo "rc=\$?" >> "\$out/ex-args"
"\$cli" browser exec --surface "\$nv" 'Promise.reject(new TypeError("boom"))' > "\$out/ex-throw" 2>&1; echo "rc=\$?" >> "\$out/ex-throw"
"\$cli" browser exec --surface "\$nv" '1 +' > "\$out/ex-syntax" 2>&1; echo "rc=\$?" >> "\$out/ex-syntax"
"\$cli" browser exec --surface "\$nv" --max-result-bytes 100 '"x".repeat(1000)' > "\$out/ex-big" 2>&1; echo "rc=\$?" >> "\$out/ex-big"
"\$cli" browser exec --surface "\$nv" -- '-1' > "\$out/ex-neg" 2>&1; echo "rc=\$?" >> "\$out/ex-neg"
"\$cli" browser exec --surface "\$nv" 'undefined' > "\$out/ex-undef" 2>&1; echo "rc=\$?" >> "\$out/ex-undef"
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/csp.html" > "\$out/nv-csp" 2>&1
"\$cli" browser exec --surface "\$nv" 'document.getElementById("p").textContent' > "\$out/ex-csp-ok" 2>&1; echo "rc=\$?" >> "\$out/ex-csp-ok"
"\$cli" browser exec --surface "\$nv" 'new Function("return 1")()' > "\$out/ex-csp-eval" 2>&1; echo "rc=\$?" >> "\$out/ex-csp-eval"
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/w9a.html?back2" > "\$out/nv-back2" 2>&1
# W9a③: localStorage(격리 world — 페이지가 getItem 을 거짓말하게 바꿔도 참값)·쿠키(그 호스트만)·clearStorage.
"\$cli" browser set-local-storage --surface "\$nv" --key k1 --value 'v1 "한"' > "\$out/ls-set" 2>&1; echo "rc=\$?" >> "\$out/ls-set"
"\$cli" browser exec --surface "\$nv" 'Storage.prototype.getItem=function(){return "LIE"}, 1' > "\$out/ls-lie" 2>&1
"\$cli" browser get-local-storage --surface "\$nv" --key k1 > "\$out/ls-get" 2>&1; echo "rc=\$?" >> "\$out/ls-get"
"\$cli" browser remove-local-storage --surface "\$nv" --key k1 > "\$out/ls-rm" 2>&1; echo "rc=\$?" >> "\$out/ls-rm"
"\$cli" browser get-local-storage --surface "\$nv" --key k1 > "\$out/ls-get2" 2>&1; echo "rc=\$?" >> "\$out/ls-get2"
"\$cli" browser set-cookie --surface "\$nv" --name ck1 --value cv1 > "\$out/ck-set" 2>&1; echo "rc=\$?" >> "\$out/ck-set"
"\$cli" browser set-cookie --surface "\$nv" --name ck2 --value cv2 --domain example.com > "\$out/ck-set-other" 2>&1; echo "rc=\$?" >> "\$out/ck-set-other"
"\$cli" browser get-cookies --surface "\$nv" > "\$out/ck-get" 2>&1; echo "rc=\$?" >> "\$out/ck-get"
"\$cli" browser delete-cookie --surface "\$nv" --name ck1 > "\$out/ck-del" 2>&1; echo "rc=\$?" >> "\$out/ck-del"
"\$cli" browser get-cookies --surface "\$nv" > "\$out/ck-get2" 2>&1; echo "rc=\$?" >> "\$out/ck-get2"
# 적대 리뷰 1 회차: sameSite 는 WebKit 처럼 소문자, 긴 값은 상한 글로. 2 회차: IP 호스트엔 도메인 쿠키가 없다 — 「--domain .127.0.0.1」 은 호스트 전용
# 쿠키를 같은 글로 지운다(도메인 호스트에서 「.a.test」 가 호스트 전용을 남기는 WebKit 규칙은 단위 시험 R1-C).
"\$cli" browser exec --surface "\$nv" 'document.cookie="ss=1; SameSite=Lax; path=/", 1' > "\$out/r1s-js" 2>&1
"\$cli" browser get-cookies --surface "\$nv" > "\$out/r1s-get" 2>&1; echo "rc=\$?" >> "\$out/r1s-get"
"\$cli" browser delete-cookie --surface "\$nv" --name ss --domain .127.0.0.1 > "\$out/r1s-del-dot" 2>&1; echo "rc=\$?" >> "\$out/r1s-del-dot"
"\$cli" browser get-cookies --surface "\$nv" > "\$out/r1s-get2" 2>&1
"\$cli" browser delete-cookie --surface "\$nv" --name ss > "\$out/r1s-del" 2>&1
"\$cli" browser set-local-storage --surface "\$nv" --key big --value "\$(head -c 70000 /dev/zero | tr '\0' x)" > "\$out/r1s-big" 2>&1; echo "rc=\$?" >> "\$out/r1s-big"
"\$cli" browser set-cookie --surface "\$nv" --name ck3 --value cv3 > "\$out/cl-ck" 2>&1
"\$cli" browser set-local-storage --surface "\$nv" --key k3 --value v3 > "\$out/cl-ls" 2>&1
"\$cli" browser clear-storage --surface "\$nv" > "\$out/cl" 2>&1; echo "rc=\$?" >> "\$out/cl"
"\$cli" browser get-cookies --surface "\$nv" > "\$out/cl-ck2" 2>&1
"\$cli" browser get-local-storage --surface "\$nv" --key k3 > "\$out/cl-ls2" 2>&1
# 적대 리뷰 2 회차: 주소에 userinfo 가 있어도 그 호스트로 — 전에는 지우기·clearStorage 가 아무것도 하지 않고 ok.
"\$cli" browser navigate --surface "\$nv" "http://u:p@127.0.0.1:$port/w9a.html?ui" > "\$out/ui-nav" 2>&1
"\$cli" browser exec --surface "\$nv" 'document.cookie="ui=1; path=/", 1' > "\$out/ui-js" 2>&1
"\$cli" browser get-cookies --surface "\$nv" > "\$out/ui-get" 2>&1; echo "rc=\$?" >> "\$out/ui-get"
"\$cli" browser clear-storage --surface "\$nv" > "\$out/ui-cl" 2>&1; echo "rc=\$?" >> "\$out/ui-cl"
"\$cli" browser exec --surface "\$nv" 'document.cookie' > "\$out/ui-after" 2>&1
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/w9a.html?back3" > "\$out/nv-back3" 2>&1
# 적대 리뷰 2 회차: 멈추지 않는 스크립트는 시한(-32004) 뒤 멈춘다 — 같은 탭의 다음 exec 이 답한다(전에는 렌더러가 100 % 로 계속 돌아 뒤 요청이 모두 시한).
# V8 이 값으로 옮기지 못하는 던진 값(자기를 가리키는 Error)도 이름·메시지, 여러 줄 긴 메시지도 그대로. 포트가 범위를 넘는 주소는 곧 거절.
"\$cli" browser exec --surface "\$nv" '(()=>{while(true){}})()' > "\$out/r2-loop" 2>&1; echo "rc=\$?" >> "\$out/r2-loop"
"\$cli" browser exec --surface "\$nv" '6 * 7' > "\$out/r2-after" 2>&1; echo "rc=\$?" >> "\$out/r2-after"
# 적대 리뷰 3 회차: 던진 값의 이름을 읽는 getter 가 멈추지 않는다 — 그것도 시한 뒤 멈추고 탭이 답한다.
"\$cli" browser exec --surface "\$nv" '(()=>{throw {get name(){while(true){}}}})()' > "\$out/r3-getter" 2>&1; echo "rc=\$?" >> "\$out/r3-getter"
"\$cli" browser exec --surface "\$nv" '6 * 7' > "\$out/r3-after" 2>&1; echo "rc=\$?" >> "\$out/r3-after"
"\$cli" browser exec --surface "\$nv" '(()=>{const e=new Error("selfref"); e.self=e; e.w=window; throw e})()' > "\$out/r2-selfref" 2>&1; echo "rc=\$?" >> "\$out/r2-selfref"
"\$cli" browser exec --surface "\$nv" '(()=>{throw new Error("line1\\n"+"x".repeat(20000))})()' > "\$out/r2-long" 2>&1; echo "rc=\$?" >> "\$out/r2-long"
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:99999/" > "\$out/r2-port" 2>&1; echo "rc=\$?" >> "\$out/r2-port"
# 적대 리뷰 4 회차: 확정되지 않은 이동 중(6 초 늦는 문서)의 exec 은 곧 거절 — 전에는 Chromium 이 붙잡아 두었다가 시한 뒤 새 문서에서 돌렸다.
# 이동은 페이지가 스스로(같은 탭의 op 대기열을 잡지 않게 — navigate op 뒤의 exec 은 그것이 끝난 뒤 새 문서에서 정상으로 돈다).
# 스크립트가 직접 이동해도 exec 은 곧 답한다(전에는 묶음 놓기가 확정까지 붙잡혀 6 초 — 느린 서버면 30 초).
g0=\$(date +%s)
"\$cli" browser exec --surface "\$nv" 'location.href="/hang?r4", 1' > "\$out/r4-go" 2>&1; echo "rc=\$?" >> "\$out/r4-go"
g1=\$(date +%s)
echo "\$((g1 - g0))" > "\$out/r4-go-secs"
sleep 1
x0=\$(date +%s)
"\$cli" browser exec --surface "\$nv" '(fetch("/hit?r4ran-"+location.pathname), 1)' > "\$out/r4-exec" 2>&1; echo "rc=\$?" >> "\$out/r4-exec"
x1=\$(date +%s)
echo "\$((x1 - x0))" > "\$out/r4-exec-secs"
sleep 7
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/ifr.html" > "\$out/r5-ifr-nav" 2>&1
sleep 1
i0=\$(date +%s)
"\$cli" browser exec --surface "\$nv" 'document.title' > "\$out/r5-ifr" 2>&1; echo "rc=\$?" >> "\$out/r5-ifr"
i1=\$(date +%s)
echo "\$((i1 - i0))" > "\$out/r5-ifr-secs"
sleep 6
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/w9a.html?back3" > "\$out/nv-back3" 2>&1
# 적대 리뷰 1 회차: 좁은 rect 에 큰 scale(1×400, 8000)이 엔진을 죽였다 — 접혀서 찍히고 엔진은 산다. wire 가 거절하는 주소(탭 문자)는 곧 invalid_params.
"\$cli" browser screenshot --surface "\$nv" --rect 0,0,1,400 --scale 8000 --out "\$out/r1-tall.png" > "\$out/r1-tall" 2>&1; echo "rc=\$?" >> "\$out/r1-tall"
"\$cli" browser get-url --surface "\$nv" > "\$out/r1-alive" 2>&1; echo "rc=\$?" >> "\$out/r1-alive"
u0=\$(date +%s)
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/a.html?t=a	b" > "\$out/r1-tab" 2>&1; echo "rc=\$?" >> "\$out/r1-tab"
u1=\$(date +%s)
echo "\$((u1 - u0))" > "\$out/r1-tab-secs"
# 글을 넣은 문서 — 떠나기 확인: navigate 는 곧 실패로 답한다(에이전트의 이동이라 W9c② 의 handle-dialog 로 떠나기를 고를 수 있다 — 아래).
"\$cli" browser type --surface "\$nv" --selector '#t' --text 'draft' > "\$out/nv-type" 2>&1
b0=\$(date +%s)
"\$cli" browser navigate --surface "\$nv" "http://127.0.0.1:$port/a.html?bu" > "\$out/nv-bu" 2>&1; echo "rc=\$?" >> "\$out/nv-bu"
b1=\$(date +%s)
echo "\$((b1 - b0))" > "\$out/nv-bu-secs"
# W9c②: 에이전트가 JS 대화상자를 보고 답한다. 대화상자가 남은 에이전트 탭(capt·da·sh 의 팝업·ag·nv)을 먼저 답해 자리를 낸다.
"\$cli" browser handle-dialog --surface "\$capt" --accept > "\$out/dg-capt" 2>&1; echo "rc=\$?" >> "\$out/dg-capt"
"\$cli" browser handle-dialog --surface "\$da" --accept > "\$out/dg-da" 2>&1; echo "rc=\$?" >> "\$out/dg-da"
# 같은 출처 팝업의 alert — 연 탭(sh)에는 대화상자가 없다(번호 없이는 실패), 목록이 팝업의 번호를 주고 그 번호로 답하면 연 탭이 다시 움직인다.
"\$cli" browser handle-dialog --surface "\$sh" --accept > "\$out/dg-fam-none" 2>&1; echo "rc=\$?" >> "\$out/dg-fam-none"
"\$cli" browser dialog --surface "\$sh" > "\$out/dg-fam-list" 2>&1; echo "rc=\$?" >> "\$out/dg-fam-list"
ftok=\$(sed -n 's/^alert tab=[0-9]* token=\([0-9]*\) .*/\1/p' "\$out/dg-fam-list")
"\$cli" browser handle-dialog --surface "\$sh" --accept --dialog "\$ftok" > "\$out/dg-fam" 2>&1; echo "rc=\$?" >> "\$out/dg-fam"
"\$cli" browser click --surface "\$sh" --selector '#ok' > "\$out/dg-fam-ok" 2>&1; echo "rc=\$?" >> "\$out/dg-fam-ok"
hit_seen okclick && echo yes > "\$out/dg-fam-hit" || echo no > "\$out/dg-fam-hit"
# 에이전트가 물은 닫기의 떠나기 확인(ag — 위에서 「not closed」) — 떠나기로 답하면 탭이 닫힌다.
"\$cli" browser dialog --surface "\$ag" > "\$out/dg-ag-list" 2>&1
"\$cli" browser handle-dialog --surface "\$ag" --accept > "\$out/dg-ag" 2>&1; echo "rc=\$?" >> "\$out/dg-ag"
n=0
while [ \$n -lt 20 ]; do
    "\$cli" browser list > "\$out/dg-ag-list2" 2>&1 || true
    grep -q "^surface \$ag " "\$out/dg-ag-list2" || break
    sleep 0.25; n=\$((n + 1))
done
# navigate 가 떠나기 확인으로 실패한 탭(nv) — 떠나기로 답하면 그 이동이 이어진다.
"\$cli" browser handle-dialog --surface "\$nv" --accept > "\$out/dg-nv" 2>&1; echo "rc=\$?" >> "\$out/dg-nv"
"\$cli" browser wait --surface "\$nv" --load > "\$out/dg-nv-wait" 2>&1
"\$cli" browser get-url --surface "\$nv" > "\$out/dg-nv-url" 2>&1; echo "rc=\$?" >> "\$out/dg-nv-url"
# 새 에이전트 탭의 alert·prompt·confirm·사슬·setTimeout.
"\$cli" browser open --url "http://127.0.0.1:$port/dlg.html" > "\$out/dg-open" 2>&1
dg=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/dg-open")
"\$cli" browser dialog --surface "\$dg" > "\$out/dg-none" 2>&1; echo "rc=\$?" >> "\$out/dg-none"
"\$cli" browser click --surface "\$dg" --selector '#al' > "\$out/dg-al-click" 2>&1; echo "rc=\$?" >> "\$out/dg-al-click"
"\$cli" browser click --surface "\$dg" --selector '#pr' > "\$out/dg-al-blocked" 2>&1; echo "rc=\$?" >> "\$out/dg-al-blocked"
"\$cli" browser dialog --surface "\$dg" > "\$out/dg-al-list" 2>&1; echo "rc=\$?" >> "\$out/dg-al-list"
"\$cli" browser handle-dialog --surface "\$dg" --accept --dialog 999999 > "\$out/dg-badtok" 2>&1; echo "rc=\$?" >> "\$out/dg-badtok"
"\$cli" browser handle-dialog --surface "\$dg" --accept > "\$out/dg-al" 2>&1; echo "rc=\$?" >> "\$out/dg-al"
hit_seen dal-done && echo yes > "\$out/dg-al-hit" || echo no > "\$out/dg-al-hit"
"\$cli" browser click --surface "\$dg" --selector '#pr' > "\$out/dg-pr-click" 2>&1
"\$cli" browser handle-dialog --surface "\$dg" --accept --text 'maru 한' > "\$out/dg-pr" 2>&1; echo "rc=\$?" >> "\$out/dg-pr"
hit_seen 'dpr-maru%20%ED%95%9C' && echo yes > "\$out/dg-pr-hit" || echo no > "\$out/dg-pr-hit"
"\$cli" browser click --surface "\$dg" --selector '#cf' > "\$out/dg-cf-click" 2>&1
"\$cli" browser handle-dialog --surface "\$dg" --dismiss > "\$out/dg-cf" 2>&1; echo "rc=\$?" >> "\$out/dg-cf"
hit_seen dcf-false && echo yes > "\$out/dg-cf-hit" || echo no > "\$out/dg-cf-hit"
"\$cli" browser click --surface "\$dg" --selector '#ch' > "\$out/dg-ch-click" 2>&1
"\$cli" browser handle-dialog --surface "\$dg" --accept > "\$out/dg-ch1" 2>&1; echo "rc=\$?" >> "\$out/dg-ch1"
n=0; while [ \$n -lt 20 ]; do "\$cli" browser dialog --surface "\$dg" > "\$out/dg-ch-list" 2>&1; grep -q '^alert ' "\$out/dg-ch-list" && break; sleep 0.25; n=\$((n + 1)); done
"\$cli" browser handle-dialog --surface "\$dg" --accept > "\$out/dg-ch2" 2>&1; echo "rc=\$?" >> "\$out/dg-ch2"
hit_seen dch-done && echo yes > "\$out/dg-ch-hit" || echo no > "\$out/dg-ch-hit"
"\$cli" browser click --surface "\$dg" --selector '#st' > "\$out/dg-st-click" 2>&1; echo "rc=\$?" >> "\$out/dg-st-click"
n=0; while [ \$n -lt 32 ]; do "\$cli" browser dialog --surface "\$dg" > "\$out/dg-st-list" 2>&1; grep -q '^alert ' "\$out/dg-st-list" && break; sleep 0.25; n=\$((n + 1)); done
"\$cli" browser handle-dialog --surface "\$dg" --accept > "\$out/dg-st" 2>&1; echo "rc=\$?" >> "\$out/dg-st"
hit_seen dst-done && echo yes > "\$out/dg-st-hit" || echo no > "\$out/dg-st-hit"
"\$cli" browser close --surface "\$dg" > /dev/null 2>&1 || true
# W9c①: 사용자의 탭(이 pane 이 열지 않았다 — 확인 모달로 허락해 태어날 때 묶이지 않는다)을 처음 읽는다. 다른 사이트 A(떠날 때 400 ms 동안 줄을
# 남긴다) → B(다른 출처 iframe 셋 — 적대 리뷰 2 회차 F2: B 의 출처들이 A 의 출처를 밀어내 A 의 늦은 줄이 지금 문서의 줄이 되었다) → 이동 직후 처음
# 읽어 묶는다 → 곧 C(빠른 사슬 — 2 회차 F1: C 가 시작한 뒤 온 A 의 unload 줄이 B 에서 묶인 쪽에게 보였다) → 늦은 줄이 다 온 뒤 다시 읽는다. 첫 읽기는
# 이 탭에 한 번뿐이라(같은 grant) 한 사슬에 담는다. 그 탭은 위에서 스스로 새로고침하는 hop 문서에 있다.
"\$cli" browser navigate --surface "\$sid" "http://localhost:$port/late.html?u" > "\$out/cn-u-nav" 2>&1
sleep 1.5
"\$cli" browser navigate --surface "\$sid" "http://127.0.0.1:$port/con3.html?ub" > "\$out/cn-u-nav2" 2>&1
"\$cli" browser console --surface "\$sid" > "\$out/cn-u-first" 2>&1; echo "rc=\$?" >> "\$out/cn-u-first"
"\$cli" browser navigate --surface "\$sid" "http://127.0.0.1:$port/con.html?uc" > "\$out/cn-u-nav3" 2>&1
sleep 1.5
"\$cli" browser console --surface "\$sid" > "\$out/cn-u-second" 2>&1; echo "rc=\$?" >> "\$out/cn-u-second"
# 사람의 탭(이 pane 이 열지 않았다 — 조작 허락만) — 누가 띄웠는지 모르는 alert(스크립트 뒤 6.5 초 — 창 5 초 밖)는 답하지 않는다(C13). 타이머가 돌 수
# 있게 가만히 있는 문서로 옮긴다.
"\$cli" browser navigate --surface "\$sid" "http://127.0.0.1:$port/ag2.html?user" > "\$out/dg-user-nav" 2>&1
"\$cli" browser exec --surface "\$sid" 'setTimeout(function(){alert("late user")},6500), 1' > "\$out/dg-user-exec" 2>&1
n=0; while [ \$n -lt 48 ]; do "\$cli" browser dialog --surface "\$sid" > "\$out/dg-user-list" 2>&1; grep -q '^alert ' "\$out/dg-user-list" && break; sleep 0.25; n=\$((n + 1)); done
"\$cli" browser handle-dialog --surface "\$sid" --accept > "\$out/dg-user" 2>&1; echo "rc=\$?" >> "\$out/dg-user"
# W9c①: 콘솔. 대조 탭 — 다른 사이트(localhost)에서 먼저 읽고 옮긴다(앞 문서의 떠날 때 줄이 와 있는지 — 묶인 쪽은 본다).
"\$cli" browser open --url "http://localhost:$port/secret.html?ctl" > "\$out/cn-ctl-open" 2>&1
ctl=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-ctl-open")
sleep 1
"\$cli" browser console --surface "\$ctl" > "\$out/cn-ctl-first" 2>&1; echo "rc=\$?" >> "\$out/cn-ctl-first"
"\$cli" browser navigate --surface "\$ctl" "http://127.0.0.1:$port/con.html?ctl" > "\$out/cn-ctl-nav" 2>&1
sleep 1
"\$cli" browser console --surface "\$ctl" > "\$out/cn-ctl-after" 2>&1; echo "rc=\$?" >> "\$out/cn-ctl-after"
"\$cli" browser close --surface "\$ctl" > /dev/null 2>&1 || true
# 적대 리뷰 4 회차 A: 에이전트가 연 탭(태어날 때 묶인다)에서 떠날 때 300 줄을 남기는 문서를 떠난다 — 넘친 앞 문서의 줄은 표지로 남는다(전에는 세지 않았다).
"\$cli" browser open --url "http://localhost:$port/unflood.html" > "\$out/cn-uf-open" 2>&1
uf=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-uf-open")
sleep 1
"\$cli" browser navigate --surface "\$uf" "http://127.0.0.1:$port/con.html?uf" > "\$out/cn-uf-nav" 2>&1
sleep 1.5
"\$cli" browser console --surface "\$uf" > "\$out/cn-uf" 2>&1; echo "rc=\$?" >> "\$out/cn-uf"
"\$cli" browser close --surface "\$uf" > /dev/null 2>&1 || true
# 적대 리뷰 3 회차 F1: 에이전트가 연 탭은 태어날 때 묶인다 — 오류를 남기고 곧 다른 사이트로 옮긴 페이지의 그 오류가 첫 읽기에 있다(전에는 첫 읽기가
# 지금 문서의 줄만 보이고 앞 줄을 지웠다).
"\$cli" browser open --url "http://localhost:$port/redir.html" > "\$out/cn-open" 2>&1
cn=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-open")
sleep 1
"\$cli" browser console --surface "\$cn" > "\$out/cn-first" 2>&1; echo "rc=\$?" >> "\$out/cn-first"
# 누름의 동기 줄 — 곧 이은 console 에 있다.
"\$cli" browser click --surface "\$cn" --selector '#cl' > "\$out/cn-click" 2>&1
"\$cli" browser console --surface "\$cn" > "\$out/cn-sync" 2>&1; echo "rc=\$?" >> "\$out/cn-sync"
# 처음 읽은 뒤에는 이동을 넘어 남고, --clear 는 비운다.
"\$cli" browser navigate --surface "\$cn" "http://127.0.0.1:$port/con.html?b" > "\$out/cn-nav2" 2>&1
"\$cli" browser console --surface "\$cn" --clear > "\$out/cn-kept" 2>&1; echo "rc=\$?" >> "\$out/cn-kept"
"\$cli" browser console --surface "\$cn" > "\$out/cn-empty" 2>&1; echo "rc=\$?" >> "\$out/cn-empty"
# 쏟아짐 — 3000 줄 중 다 싣지 않고 버린 수를 표지로(쏟아짐이 그친 뒤 250 ms 에 버린 수만 실은 frame 도 온다).
"\$cli" browser click --surface "\$cn" --selector '#fl' > "\$out/cn-fl-click" 2>&1
sleep 1
"\$cli" browser console --surface "\$cn" --clear > "\$out/cn-flood" 2>&1; echo "rc=\$?" >> "\$out/cn-flood"
# 잡히지 않은 예외.
sleep 2
"\$cli" browser click --surface "\$cn" --selector '#ue' > "\$out/cn-ue-click" 2>&1
sleep 1
"\$cli" browser console --surface "\$cn" > "\$out/cn-uncaught" 2>&1; echo "rc=\$?" >> "\$out/cn-uncaught"
# alert 가 떠 있어도 읽는다(op 줄에 서지 않는다).
"\$cli" browser click --surface "\$cn" --selector '#al' > "\$out/cn-al-click" 2>&1
"\$cli" browser console --surface "\$cn" > "\$out/cn-alert" 2>&1; echo "rc=\$?" >> "\$out/cn-alert"
"\$cli" browser dialog --surface "\$cn" > "\$out/cn-al-list" 2>&1
"\$cli" browser handle-dialog --surface "\$cn" --accept > /dev/null 2>&1 || true
"\$cli" browser close --surface "\$cn" > /dev/null 2>&1 || true
# W9c① 5 회차 변이 K02·K03·K04(CEF 처리기 접착 — 차이는 그 탭을 처음 읽는 쪽에게만 보인다): 이 pane 이 탭을 준비하고(이 pane 은 연 탭에
# 태어날 때 묶여 대조로 읽는다), 둘째 pane(처음 연 새 탭의 셸)이 처음 읽는다.
# K04: 다른 사이트(localhost)의 secret 문서 → 접속이 안 되는 주소(오류 페이지 — on_load_start 가 없다).
"\$cli" browser open --url "http://localhost:$port/secret.html?ep" > "\$out/cn-ep-open" 2>&1
ep=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-ep-open")
sleep 1
"\$cli" browser console --surface "\$ep" > "\$out/cn-ep-ctl" 2>&1; echo "rc=\$?" >> "\$out/cn-ep-ctl"
"\$cli" browser navigate --surface "\$ep" "http://127.0.0.1:1/" > "\$out/cn-ep-nav" 2>&1; echo "rc=\$?" >> "\$out/cn-ep-nav"
sleep 1.5
# K03: 조용한 문서에서 연 탭을 쏟고 곧 옮기는 문서로 — 대조(태어날 때 묶인 이 pane)는 버린 수의 표지를 본다.
"\$cli" browser open --url "http://127.0.0.1:$port/f.html?k3" > "\$out/cn-k3-open" 2>&1
k3=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-k3-open")
sleep 1
"\$cli" browser navigate --surface "\$k3" "http://127.0.0.1:$port/k3a.html" > "\$out/cn-k3-nav" 2>&1
sleep 1.5
"\$cli" browser console --surface "\$k3" > "\$out/cn-k3-ctl" 2>&1; echo "rc=\$?" >> "\$out/cn-k3-ctl"
# K02: A 에서 연 탭 — 사슬은 둘째 pane 이 몬다.
"\$cli" browser open --url "http://localhost:$port/k2a.html" > "\$out/cn-k2-open" 2>&1
k2=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/cn-k2-open")
sleep 1
echo "\$ep" > "\$out/p2-ep"; echo "\$k3" > "\$out/p2-k3"; echo "\$k2" > "\$out/p2-k2"
touch "\$out/p2-go"
n=0; while [ ! -f "\$out/p2-done" ] && [ \$n -lt 240 ]; do sleep 0.25; n=\$((n + 1)); done
for t in "\$ep" "\$k3" "\$k2"; do "\$cli" browser close --surface "\$t" > /dev/null 2>&1 || true; done
# W9c③: 업로드 — 에이전트가 연 탭(그 pane 의 grant). 결정은 파일로(호출마다 바꾼다).
"\$cli" browser open --url "http://127.0.0.1:$port/up.html" > "\$out/up-open" 2>&1
up=\$(sed -n 's/^opened \([0-9]*\).*/\1/p' "\$out/up-open")
echo approve > "$root/updecision"
"\$cli" browser upload --surface "\$up" --selector '#one' "$root/files/a.txt" > "\$out/up-one" 2>&1; echo "rc=\$?" >> "\$out/up-one"
hit_seen 'up-one-1-true-a.txt%3A6%3Aalpha' && echo yes > "\$out/up-one-hit" || echo no > "\$out/up-one-hit"
# 사본 — 프로필의 upload-staging 아래 그 탭의 폴더(파일 0400).
find "\$HOME/Library/Application Support/maru/web" -path "*upload-staging/\$up/*" -type f -exec ls -l {} \; > "\$out/up-stage" 2>&1
# 상대 경로 둘을 multiple 칸에 — CLI 가 자기 현재 폴더로 붙인다.
(cd "$root/files" && "\$cli" browser upload --surface "\$up" --selector '#multi' a.txt b.txt) > "\$out/up-multi" 2>&1; echo "rc=\$?" >> "\$out/up-multi"
hit_seen 'up-multi-2-true-a.txt%3A6%3Aalpha%7Cb.txt%3A6%3Abravo' && echo yes > "\$out/up-multi-hit" || echo no > "\$out/up-multi-hit"
# 받은 뒤 change 에서 칸을 비우는 위젯·칸을 새 것으로 바꿔 끼우는 위젯 — 페이지는 받았다: 성공에 kept:false(적대 리뷰 1 회차 — 전에는 「다른 목록」 실패라 다시 올렸다).
"\$cli" browser upload --surface "\$up" --selector '#clr' "$root/files/a.txt" > "\$out/up-clr" 2>&1; echo "rc=\$?" >> "\$out/up-clr"
hit_seen 'up-clr-1-true-a.txt%3A6%3Aalpha' && echo yes > "\$out/up-clr-hit" || echo no > "\$out/up-clr-hit"
"\$cli" browser upload --surface "\$up" --selector '#rr' "$root/files/b.txt" > "\$out/up-rr" 2>&1; echo "rc=\$?" >> "\$out/up-rr"
hit_seen 'up-rr-1-true-b.txt%3A6%3Abravo' && echo yes > "\$out/up-rr-hit" || echo no > "\$out/up-rr-hit"
# 모달 전 거절 — 꺼진 칸, 한 파일 칸에 둘.
"\$cli" browser upload --surface "\$up" --selector '#dis' "$root/files/a.txt" > "\$out/up-dis" 2>&1; echo "rc=\$?" >> "\$out/up-dis"
"\$cli" browser upload --surface "\$up" --selector '#one' "$root/files/a.txt" "$root/files/b.txt" > "\$out/up-single" 2>&1; echo "rc=\$?" >> "\$out/up-single"
# 거부.
echo deny > "$root/updecision"
"\$cli" browser upload --surface "\$up" --selector '#one' "$root/files/b.txt" > "\$out/up-deny" 2>&1; echo "rc=\$?" >> "\$out/up-deny"
# 모달 동안 페이지가 다음 문서로 옮겨 간다(1.2 초 뒤) — 승인(3 초 뒤) 뒤 다시 찾으면 다른 문서: 넣지 않는다.
echo approve-after-ms:3000 > "$root/updecision"
"\$cli" browser click --surface "\$up" --selector '#later' > "\$out/up-later" 2>&1
"\$cli" browser upload --surface "\$up" --selector '#one' "$root/files/b.txt" > "\$out/up-moved" 2>&1; echo "rc=\$?" >> "\$out/up-moved"
sleep 1
grep -c 'GET /hit?up2-' "$root/http.log" > "\$out/up2-hits" || true
# 적대 리뷰 2 회차: 넣자 change 처리기가 같은 출처로 옮겨 간다 — 넣은 뒤 읽기는 문서가 사라져 못 한다. 받았다는 성공(navigated:true)이어야 한다
# (실패·「then try again」 이면 에이전트가 다시 불러 모달이 또 뜨고 두 번 올라간다). 이 호출 하나뿐이다 — 옮겨 간 문서의 요청 수로 두 번 넣지 않았음을 본다.
"\$cli" browser upload --surface "\$up" --selector '#nav' "$root/files/a.txt" > "\$out/up-nav" 2>&1; echo "rc=\$?" >> "\$out/up-nav"
sleep 1
grep -c 'GET /up3.html?nav-1-true-a.txt%3A6' "$root/http.log" > "\$out/up-nav-loads" || true
echo approve > "$root/updecision"
"\$cli" browser close --surface "\$up" > "\$out/up-close" 2>&1
sleep 0.5
find "\$HOME/Library/Application Support/maru/web" -path "*upload-staging/\$up" > "\$out/up-after-close" 2>&1
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
    MARU_TEST_UPLOAD_DECISION="$root/updecision" \
    "$app" > "$root/app.log" 2>&1 &
app_pid=$!
i=0
while [ ! -f "$out/done" ] && [ $i -lt 510 ]; do sleep 1; i=$((i + 1)); done
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
# W9a①
pngred() { python3 - "$1" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n"
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
idat = b""; i = 8
while i < len(d):
    n = struct.unpack(">I", d[i:i + 4])[0]; t = d[i + 4:i + 8]
    if t == b"IDAT": idat += d[i + 8:i + 8 + n]
    i += 12 + n
bpp = {2: 3, 6: 4}[ctype]
raw = zlib.decompress(idat); stride = w * bpp; prev = bytearray(stride); red = 0; p = 0
for y in range(h):
    f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
    for x in range(stride):
        a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    for x in range(0, stride, bpp):
        if line[x] > 200 and line[x + 1] < 60 and line[x + 2] < 60: red += 1
    prev = line
print(w, h, round(100 * red / (w * h)))
PY
}
grep -q '^ok$' "$out/nv-a" && ! grep -q '^warning' "$out/nv-a" && grep -q '^rc=0$' "$out/nv-a" && grep -q 'GET /a.html?nv' "$root/http.log" || fail "navigate on a Chromium tab did not load the page ($(tr '\n' ' ' < "$out/nv-a"))"
grep -q '/a.html?nv$' "$out/nv-url" || fail "get-url did not print the address navigate loaded ($(tr '\n' ' ' < "$out/nv-url"))"
grep -q '^ok$' "$out/nv-204" && grep -q '^warning: no page finished loading' "$out/nv-204" && [ "$(cat "$out/nv-204-secs")" -le 5 ] || fail "navigate to an empty (204) response did not answer soon with loaded:false ($(cat "$out/nv-204-secs")s · $(tr '\n' ' ' < "$out/nv-204"))"
grep -q '^rc=1$' "$out/nv-js" && grep -q 'http, https or about:blank' "$out/nv-js" || fail "navigate to javascript: was not refused ($(tr '\n' ' ' < "$out/nv-js"))"
fx=$(pngred "$out/nv-fx.png" 2>&1) && fx2=$(pngred "$out/nv-fx2.png" 2>&1) && full=$(pngred "$out/nv-full.png" 2>&1) || fail "a Chromium screenshot was not a PNG ($fx · $fx2 · $full · $(tr '\n' ' ' < "$out/nv-shot"))"
# 고정된 빨간 네모(보기 좌표 20,20 50×50)를 스크롤한 뒤 찍었다 — 보기 좌표가 맞으면 거의 빨갛다. scale 2 는 두 배 폭.
set -- $fx; fxw=$1; [ "$3" -ge 90 ] || fail "the rect screenshot of a scrolled page missed the fixed red box ($fx — view coordinates were not mapped to the scrolled document)"
set -- $fx2; [ "$1" -eq $((fxw * 2)) ] && [ "$3" -ge 90 ] || fail "--scale 2 did not double the width of the rect screenshot ($fx2 vs $fx)"
grep -q '^rc=1$' "$out/nv-bu" && grep -q 'asks before leaving' "$out/nv-bu" && [ "$(cat "$out/nv-bu-secs")" -le 5 ] || fail "navigate on a page that asks before leaving did not fail at once with that reason ($(cat "$out/nv-bu-secs")s · $(tr '\n' ' ' < "$out/nv-bu"))"
# W9a②
grep -q '^2$' "$out/ex-sum" && grep -q '^rc=0$' "$out/ex-sum" || fail "exec on a Chromium tab did not answer 2 ($(tr '\n' ' ' < "$out/ex-sum"))"
grep -q '^{"a":\[1,"한"\],"n":null,"t":"w9a"}$' "$out/ex-obj" || fail "exec did not await the promise and return strict JSON (undefined key dropped, NaN null) ($(tr '\n' ' ' < "$out/ex-obj"))"
grep -q '^"2s"$' "$out/ex-args" || fail "exec args did not reach the script with __proto__ as an own key ($(tr '\n' ' ' < "$out/ex-args"))"
grep -q '(-32006)' "$out/ex-throw" && grep -q '^script error (execution): TypeError: boom$' "$out/ex-throw" && grep -q '^rc=1$' "$out/ex-throw" || fail "a rejected promise was not reported as a script error with its name and message ($(tr '\n' ' ' < "$out/ex-throw"))"
grep -q '^script error (execution): SyntaxError: ' "$out/ex-syntax" || fail "a syntax error was not reported as SyntaxError ($(tr '\n' ' ' < "$out/ex-syntax"))"
grep -q '(-32005)' "$out/ex-big" || fail "a result over --max-result-bytes was not refused as too large ($(tr '\n' ' ' < "$out/ex-big"))"
grep -q '^-1$' "$out/ex-neg" || fail "the expression -1 after -- was not run ($(tr '\n' ' ' < "$out/ex-neg"))"
grep -q '^null$' "$out/ex-undef" || fail "undefined did not come back as null like WebKit ($(tr '\n' ' ' < "$out/ex-undef"))"
grep -q '^"csp"$' "$out/ex-csp-ok" || fail "exec on a strict-CSP page did not run ($(tr '\n' ' ' < "$out/ex-csp-ok") · $(tr '\n' ' ' < "$out/nv-csp"))"
grep -q '^script error (execution): EvalError: ' "$out/ex-csp-eval" || fail "new Function inside exec on a strict-CSP page was not blocked like WebKit ($(tr '\n' ' ' < "$out/ex-csp-eval"))"
# 적대 리뷰 1 회차
grep -q '^rc=0$' "$out/r1-tall" && tall=$(pngred "$out/r1-tall.png" 2>&1) && grep -q '^rc=0$' "$out/r1-alive" && grep -q 'w9a.html' "$out/r1-alive" || fail "a 1x400 rect with scale 8000 did not come back folded with the engine alive ($(tr '\n' ' ' < "$out/r1-tall") · $(tr '\n' ' ' < "$out/r1-alive"))"
set -- $tall; [ "$2" -le 8000 ] && [ "$1" -le 8000 ] || fail "the tall screenshot was not folded to 8000 px ($tall)"
grep -q '^rc=1$' "$out/r1-tab" && grep -q 'http, https or about:blank' "$out/r1-tab" && [ "$(cat "$out/r1-tab-secs")" -le 3 ] || fail "a URL with a control character was not refused at once ($(cat "$out/r1-tab-secs")s · $(tr '\n' ' ' < "$out/r1-tab"))"
echo "PASS w9a-r1: a narrow rect with a huge scale is folded ($tall) and the engine stays alive, a URL with a control character is refused at once"
# 적대 리뷰 2 회차
grep -q '(-32004)' "$out/r2-loop" && grep -q '^42$' "$out/r2-after" || fail "a script that never ends was not stopped after its timeout — the next exec on that tab did not answer ($(tr '\n' ' ' < "$out/r2-loop") · $(tr '\n' ' ' < "$out/r2-after"))"
grep -q '^script error (execution): Error: selfref$' "$out/r2-selfref" || fail "an Error V8 cannot copy by value lost its name and message ($(tr '\n' ' ' < "$out/r2-selfref"))"
grep -q '^script error (execution): Error: line1' "$out/r2-long" || fail "a long multi-line error message fell back to the fixed diagnostic ($(tr '\n' ' ' < "$out/r2-long" | cut -c1-300))"
grep -q '^rc=1$' "$out/r2-port" && grep -q 'http, https or about:blank' "$out/r2-port" || fail "an address with an out-of-range port was not refused at once ($(tr '\n' ' ' < "$out/r2-port"))"
grep -q '(-32004)' "$out/r3-getter" && grep -q '^42$' "$out/r3-after" || fail "a thrown value whose name getter never ends was not stopped — the next exec on that tab did not answer ($(tr '\n' ' ' < "$out/r3-getter") · $(tr '\n' ' ' < "$out/r3-after"))"
grep -q '^1$' "$out/r4-go" && [ "$(cat "$out/r4-go-secs")" -le 3 ] || fail "an exec whose script navigates did not answer at once ($(cat "$out/r4-go-secs")s · $(tr '\n' ' ' < "$out/r4-go"))"
grep -q 'loading a new page' "$out/r4-exec" && grep -q '^rc=1$' "$out/r4-exec" && [ "$(cat "$out/r4-exec-secs")" -le 3 ] && ! grep -q 'GET /hit?r4ran' "$root/http.log" || fail "an exec sent while the tab was loading a new page was not refused at once, or ran later ($(cat "$out/r4-exec-secs")s · $(tr '\n' ' ' < "$out/r4-exec") · $(grep 'r4ran' "$root/http.log" | tr '\n' ' '))"
grep -q '^"ifr"$' "$out/r5-ifr" && [ "$(cat "$out/r5-ifr-secs")" -le 3 ] || fail "an exec while only a late iframe was loading was refused or slow ($(cat "$out/r5-ifr-secs")s · $(tr '\n' ' ' < "$out/r5-ifr"))"
echo "PASS w9a-r2: a script that never ends (and a thrown value whose getter never ends) is stopped after its timeout and the tab answers the next exec, an Error V8 cannot copy keeps its name and message, a long multi-line message survives, an out-of-range port is refused, an exec whose script navigates answers at once, an exec while that new page is still loading is refused at once and never runs later, an exec while only a late iframe loads runs"
# W9a③
grep -q '^ok$' "$out/ls-set" && grep -q '^v1 "한"$' "$out/ls-get" && grep -q '^ok$' "$out/ls-rm" && grep -q '^$' "$out/ls-get2" && grep -q '^rc=0$' "$out/ls-get2" || fail "localStorage on a Chromium tab did not set, read past a lying getItem and remove ($(tr '\n' ' ' < "$out/ls-set") · $(tr '\n' ' ' < "$out/ls-get") · $(tr '\n' ' ' < "$out/ls-rm") · $(tr '\n' ' ' < "$out/ls-get2"))"
grep -q '^ok$' "$out/ck-set" && grep -q '"name":"ck1"' "$out/ck-get" && grep -q '"value":"cv1"' "$out/ck-get" || fail "a cookie set on a Chromium tab was not read back ($(tr '\n' ' ' < "$out/ck-set") · $(tr '\n' ' ' < "$out/ck-get"))"
grep -q '^rc=1$' "$out/ck-set-other" && grep -q "page's own host" "$out/ck-set-other" || fail "a cookie for another host was not refused ($(tr '\n' ' ' < "$out/ck-set-other"))"
grep -q '^ok$' "$out/ck-del" && ! grep -q '"name":"ck1"' "$out/ck-get2" && grep -q '^rc=0$' "$out/ck-get2" || fail "delete-cookie did not remove the cookie ($(tr '\n' ' ' < "$out/ck-del") · $(tr '\n' ' ' < "$out/ck-get2"))"
grep -q '^ok$' "$out/cl" && ! grep -q '"name":"ck3"' "$out/cl-ck2" && grep -q '^$' "$out/cl-ls2" || fail "clear-storage did not clear the page's cookies and localStorage ($(tr '\n' ' ' < "$out/cl") · $(tr '\n' ' ' < "$out/cl-ck2") · $(tr '\n' ' ' < "$out/cl-ls2"))"
grep -q '"name":"ss"' "$out/r1s-get" && grep -q '"sameSite":"lax"' "$out/r1s-get" || fail "a SameSite=Lax cookie did not come back with sameSite \"lax\" like WebKit ($(tr '\n' ' ' < "$out/r1s-get"))"
grep -q '^ok$' "$out/r1s-del-dot" && ! grep -q '"name":"ss"' "$out/r1s-get2" || fail "delete-cookie --domain .127.0.0.1 did not remove the cookie on an IP host (Chromium keeps no domain cookies there) ($(tr '\n' ' ' < "$out/r1s-del-dot") · $(tr '\n' ' ' < "$out/r1s-get2"))"
grep -q '^rc=1$' "$out/r1s-big" && grep -q 'localStorage key and value are too large' "$out/r1s-big" || fail "a 70000-character localStorage value did not fail with the size limit message ($(tr '\n' ' ' < "$out/r1s-big" | cut -c1-300))"
grep -q '"name":"ui"' "$out/ui-get" && grep -q '^ok$' "$out/ui-cl" && ! grep -q 'ui=1' "$out/ui-after" || fail "on a page whose address has a username and password, get-cookies/clear-storage did not act on its host ($(tr '\n' ' ' < "$out/ui-nav") · $(tr '\n' ' ' < "$out/ui-get") · $(tr '\n' ' ' < "$out/ui-cl") · $(tr '\n' ' ' < "$out/ui-after"))"
echo "PASS w9a-storage: localStorage sets, reads past a page that lies in getItem, and removes; a cookie is set, read and deleted, a cookie for another host is refused; clear-storage clears the page's cookies and localStorage; sameSite comes back lowercase, --domain .<IP> deletes the IP host's cookie, a too-long value names the limit, an address with a username and password still acts on its host"
echo "PASS w9a-exec: exec on a Chromium tab returns strict JSON (await, undefined→null, NaN→null, args with __proto__ as an own key), reports thrown values and syntax errors with name and message, refuses results over the limit, runs -1 after --, and keeps strict CSP (eval blocked)"
echo "PASS w9a-page: navigate waits for the load (an empty response ends at once with a warning, javascript: is refused, a page asking before leaving fails at once), get-url follows it, a rect screenshot of a scrolled hidden tab hits the fixed box ($fx, scale 2: $fx2), a full one is a PNG ($full)"
# W9c②
grep -q '^rc=0$' "$out/dg-none" && grep -q '^(no dialog)$' "$out/dg-none" || fail "dialog on a tab without one did not say (no dialog) ($(tr '\n' ' ' < "$out/dg-none"))"
grep -q '^warning: the page opened a dialog .*maru browser handle-dialog' "$out/dg-al-click" || fail "a click whose handler opened an alert did not warn with the handle-dialog hint ($(tr '\n' ' ' < "$out/dg-al-click"))"
grep -q '^rc=1$' "$out/dg-al-blocked" && grep -q 'showing a dialog.*maru browser handle-dialog' "$out/dg-al-blocked" || fail "an op on a tab with an alert did not fail pointing at handle-dialog ($(tr '\n' ' ' < "$out/dg-al-blocked"))"
grep -q '^alert tab=[0-9]* token=[0-9]* cause=agent may_answer=yes origin=http://127.0.0.1:[0-9]*$' "$out/dg-al-list" || fail "dialog did not list the agent's alert with its token, cause and origin ($(tr '\n' ' ' < "$out/dg-al-list"))"
grep -q '^  message: "hello ⏎ world"$' "$out/dg-al-list" && grep -q '^answer with: maru browser handle-dialog' "$out/dg-al-list" || fail "dialog did not show the alert's line break as a visible mark, or the answer hint ($(tr '\n' ' ' < "$out/dg-al-list"))"
grep -q '^rc=1$' "$out/dg-badtok" && grep -q 'no such dialog' "$out/dg-badtok" || fail "an unknown dialog token was not refused ($(tr '\n' ' ' < "$out/dg-badtok"))"
grep -q '^answered alert$' "$out/dg-al" && grep -q '^rc=0$' "$out/dg-al" && [ "$(cat "$out/dg-al-hit")" = yes ] || fail "accepting the alert did not let the page go on ($(tr '\n' ' ' < "$out/dg-al") · hit $(cat "$out/dg-al-hit"))"
grep -q '^answered prompt$' "$out/dg-pr" && [ "$(cat "$out/dg-pr-hit")" = yes ] || fail "the prompt answer text did not reach the page ($(tr '\n' ' ' < "$out/dg-pr") · $(grep 'GET /hit?dpr' "$root/http.log" | tr '\n' ' '))"
grep -q '^answered confirm$' "$out/dg-cf" && [ "$(cat "$out/dg-cf-hit")" = yes ] || fail "dismissing the confirm did not give the page false ($(tr '\n' ' ' < "$out/dg-cf") · $(grep 'GET /hit?dcf' "$root/http.log" | tr '\n' ' '))"
grep -q '^answered confirm$' "$out/dg-ch1" && grep -q 'cause=agent may_answer=yes' "$out/dg-ch-list" && grep -q '^answered alert$' "$out/dg-ch2" && [ "$(cat "$out/dg-ch-hit")" = yes ] || fail "the alert that came right after the agent answered a confirm was not the agent's to answer ($(tr '\n' ' ' < "$out/dg-ch-list") · $(tr '\n' ' ' < "$out/dg-ch2"))"
grep -q 'cause=agent may_answer=yes' "$out/dg-st-list" && grep -q '^answered alert$' "$out/dg-st" && [ "$(cat "$out/dg-st-hit")" = yes ] || fail "an alert a click scheduled 1.5 s later was not the agent's to answer ($(tr '\n' ' ' < "$out/dg-st-list") · $(tr '\n' ' ' < "$out/dg-st"))"
grep -q '^answered alert$' "$out/dg-capt" && grep -q '^answered alert$' "$out/dg-da" || fail "the alerts left on agent tabs (a delayed alert after a click, an alert after a submit) could not be answered ($(tr '\n' ' ' < "$out/dg-capt") · $(tr '\n' ' ' < "$out/dg-da"))"
grep -q '^rc=1$' "$out/dg-fam-none" && grep -q 'no dialog is showing in this tab' "$out/dg-fam-none" || fail "answering without a token on the opener of a popup with an alert did not refuse ($(tr '\n' ' ' < "$out/dg-fam-none"))"
grep -q '^alert tab=[0-9]* token=[0-9]* cause=[a-z]* may_answer=yes' "$out/dg-fam-list" && grep -q '^answered alert$' "$out/dg-fam" && grep -q '^ok$' "$out/dg-fam-ok" && [ "$(cat "$out/dg-fam-hit")" = yes ] || fail "the popup's alert was not listed from its opener and answered with its token, or the opener stayed blocked ($(tr '\n' ' ' < "$out/dg-fam-list") · $(tr '\n' ' ' < "$out/dg-fam") · $(tr '\n' ' ' < "$out/dg-fam-ok"))"
grep -q 'maru browser handle-dialog --accept' "$out/ag-close-ask" && grep -q '^before_unload tab=[0-9]* token=[0-9]* cause=agent may_answer=yes' "$out/dg-ag-list" && grep -q '^answered before_unload$' "$out/dg-ag" && grep -q '^note: the page is leaving' "$out/dg-ag" && ! grep -q "^surface $(cat "$out/ag-id") " "$out/dg-ag-list2" || fail "the leave-page question of the agent's own close was not answerable, or leaving did not close the tab ($(tr '\n' ' ' < "$out/dg-ag-list") · $(tr '\n' ' ' < "$out/dg-ag") · $(grep -c '^surface ' "$out/dg-ag-list2") tabs)"
grep -q '^answered before_unload$' "$out/dg-nv" && grep -q '/a.html?bu$' "$out/dg-nv-url" || fail "leaving after the agent's navigate asked before leaving did not let the navigation go on ($(tr '\n' ' ' < "$out/dg-nv") · $(tr '\n' ' ' < "$out/dg-nv-wait") · $(tr '\n' ' ' < "$out/dg-nv-url"))"
grep -q '^alert tab=[0-9]* token=[0-9]* cause=unknown may_answer=no' "$out/dg-user-list" && grep -q '^rc=1$' "$out/dg-user" && grep -q 'the user is answering this dialog' "$out/dg-user" || fail "an alert nobody just caused on a user's tab was answerable ($(tr '\n' ' ' < "$out/dg-user-list") · $(tr '\n' ' ' < "$out/dg-user") · nav $(tr '\n' ' ' < "$out/dg-user-nav") · exec $(tr '\n' ' ' < "$out/dg-user-exec"))"
# W9c①
grep -q '^rc=0$' "$out/cn-ctl-first" && grep -q '^\[log\] con-secret-token$' "$out/cn-ctl-first" && grep -q 'con-secret-unload' "$out/cn-ctl-after" || fail "control: a tab read on the first site did not show its line, or after moving to another site did not show the old page's unload line — the leak check below would prove nothing ($(tr '\n' ' ' < "$out/cn-ctl-first") · $(tr '\n' ' ' < "$out/cn-ctl-after"))"
for k in 1 2 3; do grep -q 'GET /f.html' "$root/http-f$k.log" || fail "the page with three cross-origin iframes did not load the iframe on port +$k — the check below would prove nothing ($(tr '\n' ' ' < "$out/cn-u-nav2"))"; done
grep -q '^rc=0$' "$out/cn-u-first" && grep -qxF '[log] con3-head' "$out/cn-u-first" && grep -q '^rc=0$' "$out/cn-u-second" && grep -qxF '[log] con3-head' "$out/cn-u-second" && grep -qxF '[log] con-log-uc' "$out/cn-u-second" && ! grep -q 'con-late' "$out/cn-u-first" "$out/cn-u-second" || fail "on a user's tab, the first read after A, B with three cross-origin iframes, or the read after a fast move on to C, showed A's lines ($(tr '\n' ' ' < "$out/cn-u-first") / $(tr '\n' ' ' < "$out/cn-u-second") · nav $(tr '\n' ' ' < "$out/cn-u-nav") $(tr '\n' ' ' < "$out/cn-u-nav2") $(tr '\n' ' ' < "$out/cn-u-nav3"))"
uf_lines=$(grep -c '^\[log\] con-unflood-[0-9]' "$out/cn-uf" || true)
grep -q '^rc=0$' "$out/cn-uf" && grep -qxF '[log] con-unflood-head' "$out/cn-uf" && grep -qxF '[log] con-log-uf' "$out/cn-uf" && grep -q '^\[maru\] [0-9]* console messages from pages or origins this tab had just left were dropped' "$out/cn-uf" && [ "$uf_lines" -ge 3 ] && [ "$uf_lines" -lt 300 ] || fail "on a tab the agent opened, 300 lines a page logged while leaving were not cut with a previous-page dropped marker ($uf_lines lines · $(grep -v '^\[log\] con-unflood-[0-9]' "$out/cn-uf" | tr '\n' ' ' | cut -c1-400))"
grep -q '^rc=0$' "$out/cn-first" && grep -qxF '[error] con-redir-error' "$out/cn-first" || fail "on a tab the agent opened, the first read lost the error its first page logged before moving to another site ($(tr '\n' ' ' < "$out/cn-first"))"
for want in '[log] con-log-a' '[log] con-info' '[warn] con-warn' '[error] con-error' '[debug] con-debug'; do
    grep -qxF "$want" "$out/cn-first" || fail "console did not list \"$want\" ($(tr '\n' ' ' < "$out/cn-first"))"
done
grep -qxF '[log] con-click-sync' "$out/cn-sync" || fail "the line a click logged was not in the console read right after it ($(tr '\n' ' ' < "$out/cn-sync"))"
grep -qxF '[log] con-log-a' "$out/cn-kept" && grep -qxF '[log] con-log-b' "$out/cn-kept" && grep -q '^(empty console)$' "$out/cn-empty" || fail "lines were not kept across a navigation after the first read, or --clear did not empty the console ($(tr '\n' ' ' < "$out/cn-kept" | cut -c1-300) · $(tr '\n' ' ' < "$out/cn-empty"))"
flood_lines=$(grep -c '^\[log\] con-flood-' "$out/cn-flood" || true)
grep -q '^\[maru\] [0-9]* console messages were dropped' "$out/cn-flood" && [ "$flood_lines" -ge 100 ] && [ "$flood_lines" -lt 3000 ] || fail "a flood of 3000 lines was not cut with a maru dropped marker ($flood_lines flood lines · $(grep '^\[maru\]' "$out/cn-flood" | tr '\n' ' '))"
# 남은 줄과 버린 수를 합하면 3000 — 쏟아짐 끝의 버린 수는 250 ms 뒤 버린 수만 실은 frame 으로만 온다(W9c① 5 회차 변이: 그 task 를 빼도 표지는
# 남아 위 검사만으로는 몰랐다).
flood_dropped=$(sed -n 's/^\[maru\] \([0-9]*\) console messages were dropped.*/\1/p' "$out/cn-flood" | awk '{s += $1} END {print s + 0}')
[ $((flood_lines + flood_dropped)) -eq 3000 ] || fail "a flood of 3000 lines kept $flood_lines lines and counted $flood_dropped dropped — the rest went without a count (the drop-only frame after the flood did not come)"
grep -q '^\[error\] Uncaught Error: con-uncaught (http://127.0.0.1:[0-9]*/con.html?b:[0-9]*)$' "$out/cn-uncaught" || fail "an uncaught error did not come with its source and line ($(grep -i 'uncaught' "$out/cn-uncaught" | tr '\n' ' '))"
grep -q '^rc=0$' "$out/cn-alert" && grep -qxF '[log] con-before-alert' "$out/cn-alert" && grep -q '^alert ' "$out/cn-al-list" || fail "console did not answer while the page showed an alert ($(tr '\n' ' ' < "$out/cn-alert" | cut -c1-300) · $(tr '\n' ' ' < "$out/cn-al-list"))"
# W9c① 5 회차 변이 K02·K03·K04 — 둘째 pane(그 탭을 읽은 적 없는 쪽)이 읽은 것. 처리기 접착부를 빼도 묶인 쪽에게는 차이가 없어 위 검사는 몰랐다.
[ -f "$out/p2-done" ] || fail "the second pane (a reader that never read those tabs) did not finish — the first-read checks would prove nothing ($(ls "$out" | grep -E '^(p2-|pane-|cn-ep|cn-k)' | tr '\n' ' '))"
# K04: 오류 페이지로의 이동도 새 문서다(sidecar 의 error_page) — 없으면 처음 읽는 쪽에게 앞 사이트의 줄이 지금 문서의 줄로 보였다.
grep -q '^rc=0$' "$out/cn-ep-ctl" && grep -qxF '[log] con-secret-token' "$out/cn-ep-ctl" || fail "control: the pane that opened the secret page did not see its line — the error-page check would prove nothing ($(tr '\n' ' ' < "$out/cn-ep-ctl"))"
grep -q '^rc=0$' "$out/cn-ep-fresh" && ! grep -q 'con-secret' "$out/cn-ep-fresh" || fail "after a failed navigation put an error page in the tab, a pane that never read the tab saw the previous site's lines ($(tr '\n' ' ' < "$out/cn-ep-fresh" | cut -c1-300) · nav $(tr '\n' ' ' < "$out/cn-ep-nav"))"
# K03: 옮기기 전 문서의 버린 수는 page_started 앞에 보낸다 — 아니면 옮겨 간 문서의 표지가 되어 처음 읽는 쪽에게 앞 문서의 양이 보였다.
k3_lines=$(grep -c '^\[log\] k3-flood-' "$out/cn-k3-ctl" || true)
grep -q '^rc=0$' "$out/cn-k3-ctl" && grep -q '^\[maru\] [0-9]* console messages were dropped' "$out/cn-k3-ctl" && [ "$k3_lines" -ge 100 ] || fail "control: the pane that opened the flooding page did not see its lines and a dropped marker — the check would prove nothing ($k3_lines lines · $(grep -v '^\[log\] k3-flood-' "$out/cn-k3-ctl" | tr '\n' ' ' | cut -c1-300))"
grep -q '^rc=0$' "$out/cn-k3-fresh" && grep -qxF '[warn] k3-quiet' "$out/cn-k3-fresh" && ! grep -q '^\[maru\]' "$out/cn-k3-fresh" && ! grep -q 'k3-flood' "$out/cn-k3-fresh" || fail "a pane that never read the tab saw, on the page it moved to, the dropped count of the page that flooded just before ($(tr '\n' ' ' < "$out/cn-k3-fresh" | cut -c1-300))"
# K02: 두 문서의 앞 문서 줄을 버리면 표지도 문서마다(splitOld) — 합치면 B 의 것이 A 의 표지로 가 B 에 묶인 쪽에게 표지가 없었다.
grep -q 'GET /k2fa.js' "$root/http.log" && grep -q 'GET /k2fb.js' "$root/http.log" || fail "C did not load the scripts of A's and B's origins — the chain check would prove nothing"
grep -q '^rc=0$' "$out/cn-k2-b" && grep -qxF '[log] k2-b-head' "$out/cn-k2-b" && ! grep -q 'k2-a-head' "$out/cn-k2-b" || fail "the second pane's first read of the chain tab was not on B — the chain check would prove nothing ($(tr '\n' ' ' < "$out/cn-k2-b") · nav $(tr '\n' ' ' < "$out/cn-k2-navb"))"
grep -q '^rc=0$' "$out/cn-k2-c" && grep -qxF '[log] k2-c-head' "$out/cn-k2-c" && ! grep -q 'k2-old-a-' "$out/cn-k2-c" || fail "A's lines logged on C were not taken as lines of two documents back (the chain took $(cat "$out/cn-k2-ms") ms — past the 1 s window?) — the chain check would prove nothing ($(grep -v '^\[log\] k2-old-' "$out/cn-k2-c" | tr '\n' ' ' | cut -c1-300))"
grep -q '^\[maru\] [0-9]* console messages from pages or origins this tab had just left were dropped' "$out/cn-k2-c" || fail "a reader latched on B did not see the dropped marker of B's lines in a fast A → B → C chain — they went into A's marker ($(grep -v '^\[log\] k2-old-' "$out/cn-k2-c" | tr '\n' ' ' | cut -c1-300) · $(grep -c '^\[log\] k2-old-b-' "$out/cn-k2-c" || true) of B's lines kept · chain $(cat "$out/cn-k2-ms") ms)"
echo "PASS w9c-console-first-reader: after a failed navigation to an error page a pane that never read the tab sees none of the previous site's lines (control: the opener saw the line), the dropped count of a page that flooded and moved on is not a marker of the next page for it (control: the opener saw the marker), and a reader latched on B in a fast A → B → C chain sees B's own old-line dropped marker (chain $(cat "$out/cn-k2-ms") ms)"
echo "PASS w9c-console: levels (info as log), a click's line is in the next read, lines are kept across navigation after the first read, --clear empties, a 3000-line flood keeps $flood_lines lines and counts the other $flood_dropped in a dropped marker, an uncaught error carries source:line, console answers during an alert, on a user's tab the first read after A, B with three cross-origin iframes shows none of A's lines, nor does a read after a fast move on to C (control: the old page's unload line did arrive), on a tab the agent opened the first read keeps the error of a page that moved to another site, and 300 lines a page logged while leaving keep $uf_lines lines with a previous-page dropped marker"
# W9c③: 업로드.
up_hint="(the app must be built with -Dweb-upload-test-decision=true so the upload dialog is answered automatically)"
grep -q '^uploaded 1 file to http://127.0.0.1:' "$out/up-one" && grep -q '^rc=0$' "$out/up-one" && [ "$(cat "$out/up-one-hit")" = yes ] \
    || fail "upload of one file did not reach the page as a trusted change with its content ($(tr '\n' ' ' < "$out/up-one") · $(grep 'GET /hit?up' "$root/http.log" | tr '\n' ' ')) $up_hint"
grep -q '^-r--------[@+]* .*/a\.txt$' "$out/up-stage" || fail "the staged copy was not under the profile's upload-staging/<tab> with mode 0400 ($(tr '\n' ' ' < "$out/up-stage"))"
grep -q '^uploaded 2 files' "$out/up-multi" && [ "$(cat "$out/up-multi-hit")" = yes ] || fail "two relative paths into a multiple input did not reach the page ($(tr '\n' ' ' < "$out/up-multi"))"
for w in clr rr; do
    grep -q '^uploaded 1 file to http://127.0.0.1:' "$out/up-$w" && grep -q '^rc=0$' "$out/up-$w" && grep -q 'kept: false' "$out/up-$w" && [ "$(cat "$out/up-$w-hit")" = yes ] \
        || fail "an input the page cleared or replaced in its change handler was not reported as received with kept:false ($w: $(tr '\n' ' ' < "$out/up-$w") · hit $(cat "$out/up-$w-hit"))"
done
grep -q '^rc=1$' "$out/up-dis" && grep -q 'disabled' "$out/up-dis" || fail "a disabled file input was not refused ($(tr '\n' ' ' < "$out/up-dis"))"
grep -q '^rc=1$' "$out/up-single" && grep -q 'takes one file' "$out/up-single" || fail "two files into a single-file input were not refused ($(tr '\n' ' ' < "$out/up-single"))"
grep -q '^rc=1$' "$out/up-deny" && grep -q 'declined.*(-32002)' "$out/up-deny" || fail "a declined upload did not fail with -32002 ($(tr '\n' ' ' < "$out/up-deny"))"
! grep -q 'GET /hit?up-one-1-true-b.txt' "$root/http.log" || fail "a declined or moved upload still reached the page ($(grep 'GET /hit?up' "$root/http.log" | tr '\n' ' '))"
grep -q '^rc=1$' "$out/up-moved" && grep -q 'page changed' "$out/up-moved" || fail "an upload whose page moved during the dialog did not fail with page changed ($(tr '\n' ' ' < "$out/up-moved"))"
[ "$(cat "$out/up2-hits")" = 0 ] || fail "the page the tab moved to during the dialog received files ($(grep 'GET /hit?up2' "$root/http.log" | tr '\n' ' '))"
grep -q '^uploaded 1 file to http://127.0.0.1:' "$out/up-nav" && grep -q '^rc=0$' "$out/up-nav" && grep -q 'navigated: true' "$out/up-nav" && ! grep -q 'try again' "$out/up-nav" \
    && [ "$(cat "$out/up-nav-loads")" = 1 ] \
    || fail "an input whose change handler navigated right away was not reported as received with navigated:true, or the agent was told to try again ($(tr '\n' ' ' < "$out/up-nav") · loads $(cat "$out/up-nav-loads") · $(grep 'GET /up3' "$root/http.log" | tr '\n' ' '))"
[ ! -s "$out/up-after-close" ] || fail "closing the tab did not remove its upload-staging folder ($(tr '\n' ' ' < "$out/up-after-close"))"
echo "PASS w9c-upload: one file reaches the page as a trusted change with its content, the staged copy is 0400 under the profile's upload-staging/<tab>, two relative paths reach a multiple input, an input the page clears or replaces in its change handler is a success with kept:false, a disabled input and two files into a single-file input are refused before the dialog, a declined dialog is -32002, a page that moved during the dialog gets nothing (page changed), an input whose change handler navigates right away is a success with navigated:true (no try again, one navigation), closing the tab removes its copies"
echo "PASS w9c-dialog: a blocked op points at handle-dialog, dialog lists the agent's alert (cause, line break shown), alert/prompt text/confirm dismiss/chained alert/timer alert are answered and the page goes on, an unknown token is refused, a popup's alert is answered from its opener by token, leaving answers the agent's own close (the tab closes) and navigate (it goes on), an unattributed alert on a user's tab is refused"
echo "PASS agent-keys-dialogs: Enter on a new hidden tab submits (on the element and where the focus is), a key whose submit opens an alert is answered as delivered with a warning, a same-origin popup's alert ends the opener's op at once ($(cat "$out/r3-fam-secs")s)"
# W9f
grep -q '^rc=0$' "$out/mcp-py" || fail "the MCP driver failed ($(tr '\n' ' ' < "$out/mcp-py" | cut -c1-600) · $(tail -3 "$out/mcp-log" 2>/dev/null | tr '\n' ' ' | cut -c1-600))"
mcp_get() { sed -n "s/^$1=//p" "$out/mcp"; }
[ "$(mcp_get nosid)" = yes ] || fail "the MCP server was not started in a new session — the identity case proves nothing"
[ "$(mcp_get proto)" = 2025-06-18 ] && [ "$(mcp_get tools)" -ge 18 ] || fail "MCP initialize or tools/list did not answer ($(tr '\n' ' ' < "$out/mcp"))"
mcp_get open | grep -q '^opened [0-9]* http://127.0.0.1:[0-9]*/mcp.html$' || fail "browser_open from an MCP server in a new session did not open a tab ($(mcp_get open))"
[ "$(mcp_get click)" = "ok False" ] && [ "$(cat "$out/mb-hit")" = yes ] || fail "browser_click through MCP did not click for real ($(mcp_get click))"
[ "$(mcp_get type)" = "ok False" ] && [ "$(cat "$out/mt-hit")" = yes ] || fail "browser_type through MCP did not type the text --help as text ($(mcp_get type) · $(grep 'GET /hit?mt' "$root/http.log" | tr '\n' ' '))"
# W9a②: Chromium 탭의 exec 도 결과를 준다 — 식 `-1` 이 옵션으로 읽히지 않고 -1 로 답한다.
[ "$(mcp_get exec)" = "-1 False" ] || fail "browser_exec through MCP did not run the expression -1 ($(mcp_get exec))"
# W9a①: Chromium 탭의 screenshot 은 PNG 그림이다.
mcp_get shot | grep -q '^png$' || fail "browser_screenshot through MCP did not return a PNG image ($(mcp_get shot))"
[ "$(mcp_get pipelined)" = "p1,p2,listed" ] || fail "two MCP calls sent back to back did not get their own answers in order ($(mcp_get pipelined))"
[ "$(mcp_get badarg)" = error ] || fail "a misspelled MCP tool argument was not refused"
[ "$(mcp_get close)" = "closed False" ] || fail "browser_close through MCP did not close the tab ($(mcp_get close))"
[ "$(mcp_get rest)" = empty ] && [ "$(mcp_get rc)" = 0 ] || fail "maru mcp wrote extra output or did not exit 0 at the end of input ($(tr '\n' ' ' < "$out/mcp"))"
echo "PASS mcp: an MCP server started in a new session (no terminal) opens, clicks, types --help as text, runs the expression -1, gets a PNG image for a screenshot, refuses a misspelled argument and closes, with only JSON-RPC on its output"
# 첫 줄은 틀린 `use`(표준 오류) — 같은 파일로 받아도 줄이 서로 덮이지 않고(W9f 적대 리뷰 1 회차), 실패가 있었으니 종료 상태 1.
grep -q '^(the picked tab was closed' "$out/repl" && grep -q '^hint: pick a tab with `use <id>`' "$out/repl" && grep -q '^error: use needs one tab id' "$out/repl" && grep -q '^opened [0-9]* http://127.0.0.1:[0-9]*/mcp.html?repl$' "$out/repl" && grep -q '^ok$' "$out/repl" && grep -q '^closed$' "$out/repl" && grep -q '^rc=1$' "$out/repl" && [ "$(cat "$out/rb2-hit")" = yes ] || fail "repl did not open a tab, click it without --surface and close it, or its output lines overwrote each other ($(tr '\n' ' ' < "$out/repl"))"
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
