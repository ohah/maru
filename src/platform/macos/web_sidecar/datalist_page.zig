//! 제안 목록(datalist — W6m①)의 CEF 를 모르는 부분 — 대리 스크립트 조각과 렌더러가 보낸 목록 풀기(순수 — `pure_tests.zig`).
//! 규칙과 믿음의 경계는 `datalist.zig`.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const message = protocol.message;

/// 제안 목록 대리 스크립트 — 렌더러가 http(s) 출처 문서가 생길 때(주 프레임과 iframe — 다른 출처 iframe 도) `(function(send,main){…})`
/// 로 감싸 돌린다(`renderer.runDatalistScript` — 페이지 스크립트보다 먼저, `send` 와 「주 프레임인가」는 인자로). 큰따옴표·역슬래시
/// 없이 쓴다(아래 comptime 검사가 지킨다).
///
/// W6m③: 열린 shadow DOM 안의 칸 — window 수신자에서 사건 대상은 shadow host 로 바뀌므로(retarget) `composedPath()` 의 첫 것을
/// 쓴다. 초점은 칸의 root 를 따라 올라가며(각 shadow root 의 `activeElement` 가 그 아래 것) 문서의 `activeElement` 까지 맞아야 하고,
/// 스크롤은 composed 가 아니라 window 에 오지 않으므로 보인 칸의 shadow root 마다 capture 수신자를 단다. 닫힌 shadow 는 하지 않는다
/// (사용자 결정 2026-10-07 — `attachShadow` 바꿔치기의 흔적: toString·오류 stack). iframe 안의 칸 — 그 프레임의 viewport 기준
/// 사각형을 그 viewport 로 자르고, **신뢰된 포인터 사건의 `screenX − clientX`**(CEF OSR 에서 screen 좌표는 주 view 의 좌표다 —
/// 같은·다른 출처 iframe 에서 내용 상자 원점과 px 단위로 같았다, 실측)를 더해 주 view 기준으로 보낸다. 포인터가 그 프레임에 한 번도
/// 오지 않았으면(Tab 으로만 들어옴) 보이지 않는다. 포인터가 기준점에서 20 px 넘게 움직였을 때 screen 차이와 client 차이가 다르면
/// (부모가 iframe 을 확대·회전했거나 최상위가 pinch 확대됐다 — 원점이 포인터 자리마다 달라진다) 원점을 버린다 — 바로 앞 사건과의
/// 쌍으로 보면 천천히 움직여 피할 수 있었다(적대 리뷰 2 회차). 포인터가 그대로인데 client 만 바뀌면 프레임이 옮겨진 것이다(바깥
/// 스크롤 — 확대가 아니다). 그 값을 잰 뒤의 시간(`a`)을 함께 보내 sidecar 가 스크롤 뒤의 낡은 자리를 버린다. 휠은 원점을 재지
/// 않는다(휠이 바깥 상자를 굴리면 굴리기 전 값이 남는다 — 기준점만 놓는다). 바깥 프레임과 메시지를 주고받지 않는다(적대 검토 —
/// 페이지가 엿보거나 위조할 수 있다). iframe 에서 글자로 여는 목록은 그 문서가 1 초 안에 신뢰된 키 누름을 받았을 때만 — 사용자가 다른
/// 프레임에 치는 동안 iframe 이 스스로 초점을 가져가 칸에 글을 넣어도(`execCommand` 의 `input` 은 isTrusted 다, 초점도 그 프레임이
/// 된다) 키 누름은 만들지 못한다(적대 리뷰 2 회차 — 초점 확인만으로는 가리지 못했다). 입력기 조합(`composition*` — maru 는 조합 중인
/// 키를 keydown 으로 보내지 않는다)·붙여넣기·끌어 놓기의 신뢰된 사건도 센다(페이지는 이것들을 isTrusted 로 만들지 못한다 — 3 회차).
/// 문을 지나지 못한 글자는 그 칸에 떠 있던 목록을 닫는다(옛 항목이 남지 않게). 초점은 그 문서가 실제로 초점을 가졌을 때만 본다
/// (`hasFocus`).
///
/// 페이지가 바꿔 놓을 수 있는 것은 우리가 아는 길에서 부르지 않는다: 판정·읽기·넣기에 쓰는 getter/setter·함수(`type`·`list`·
/// `value`·`readOnly`·`disabled`, `options`·길이, 옵션의 `value`·`label`·`disabled`, 사각형·`visualViewport`, `activeElement`,
/// 사건의 `target`·`button`·`ctrlKey`·`key`·수식키, `contains`, 글 함수, `addEventListener`·`dispatchEvent`·`Event`·
/// `JSON.stringify`)는 먼저 쥐고, 보내는 객체·배열과 사건 초기값은 원형이 없게 만든다(`toJSON`·`Array.prototype` 의 번호 setter·
/// `Object.prototype` 에 둔 값이 끼어들지 않게 — 적대 검증). `isTrusted` 는 사건 자신의 바꿀 수 없는 속성이라 그대로 읽는다.
///
/// 거르기는 친 글을 빈칸으로 나눈 단어마다 값이나 레이블에 들어 있어야 한다(대소문자 무시, 낱말 중간도 — 단어가 없으면 전부).
/// 규칙(Chrome 154 실측 §7 — 재지 않은 것은 W6m 문단에): 사용자의 사건만(`isTrusted` — 폼 라이브러리가 보낸 가짜 `input` 은
/// 아니다), 초점이 있는 글 칸(`readOnly`·`disabled` 는 아니다)에서. 왼쪽 누름(⌃ 누름은 macOS 의 우클릭이다)·↓·글자로 지금 값을
/// 거른 목록을 보이고, 다른 곳을 누르거나 빈 칸·일치 없음·초점 잃음·그 칸을 품은 스크롤·창 크기 바뀜·`pagehide` 면 닫는다.
/// 보이는 글은 512 단위에서(대리 쌍을 가르지 않고) 자르고 JSON 으로 늘어난 길이(제어 문자 6·따옴표·역슬래시 2)를 모두 합쳐
/// 24000 단위에서 멈춘다 — 넣을 값은 원래 값을 쥔다.
pub const script_part = "(function(){" ++
    "var A=Reflect.apply,J=JSON.stringify,S=String,G=Object.getOwnPropertyDescriptor,SP=Object.setPrototypeOf,E=Event,W=window,D=document," ++
    "IP=HTMLInputElement.prototype,TG=G(IP,'type').get,LG=G(IP,'list').get,VD=G(IP,'value'),VG=VD.get,VS=VD.set,RO=G(IP,'readOnly').get,DI=G(IP,'disabled').get," ++
    "OG=G(HTMLDataListElement.prototype,'options').get,CL=G(HTMLCollection.prototype,'length').get," ++
    "OP=HTMLOptionElement.prototype,OV=G(OP,'value').get,OL=G(OP,'label').get,OD=G(OP,'disabled').get," ++
    "BR=Element.prototype.getBoundingClientRect,RP=DOMRectReadOnly.prototype,RX=G(RP,'x').get,RY=G(RP,'y').get,RW=G(RP,'width').get,RH=G(RP,'height').get," ++
    "VV=W.visualViewport,VP=VV?VisualViewport.prototype:null,VL=VP&&G(VP,'offsetLeft').get,VT=VP&&G(VP,'offsetTop').get,VC=VP&&G(VP,'scale').get," ++
    "AE=G(Document.prototype,'activeElement').get,ET=G(Event.prototype,'target').get,MP=MouseEvent.prototype,MB=G(MP,'button').get,MC=G(MP,'ctrlKey').get," ++
    "KP=KeyboardEvent.prototype,KK=G(KP,'key').get,KA=G(KP,'altKey').get,KC=G(KP,'ctrlKey').get,KM=G(KP,'metaKey').get," ++
    "AL=EventTarget.prototype.addEventListener,DE=EventTarget.prototype.dispatchEvent,SR=S.prototype,LC=SR.toLowerCase,IX=SR.indexOf,SL=SR.slice,CC=SR.charCodeAt," ++
    // W6m③ — 사건의 진짜 대상·shadow root·포인터 좌표·프레임 viewport·시계.
    "CP=Event.prototype.composedPath,RN=Node.prototype.getRootNode,PN=G(Node.prototype,'parentNode').get,SRP=ShadowRoot.prototype,SH=G(SRP,'host').get,SA=G(SRP,'activeElement').get," ++
    "SX=G(MP,'screenX').get,SY=G(MP,'screenY').get,CX=G(MP,'clientX').get,CY=G(MP,'clientY').get,IW=G(W,'innerWidth').get,IH=G(W,'innerHeight').get," ++
    "PF=performance,PW=Performance.prototype.now,MX=Math.max,MN=Math.min,MR=Math.round,MA=Math.abs,WS=WeakSet,WA=WS.prototype.add,WH=WS.prototype.has,roots=new WS(),ox=0,oy=0,ot=-1," ++
    "anchored=false,asx=0,asy=0,acx=0,acy=0,lt=-1e9,scaled=false,hits=0,kt=-1e9,HF=Document.prototype.hasFocus," ++
    "K={__proto__:null,text:1,search:1,url:1,tel:1,email:1,number:1},cur=null,ver=0,vals=null,busy=false;" ++
    "function arr(){return SP([],null)}" ++
    "function real(e){try{return e.isTrusted===true}catch(x){return false}}" ++
    // 보이는 글 — 512 단위에서 자르되 대리 쌍의 앞쪽에서 끝나지 않게.
    // 거르기 단어 — 빈칸(공백·탭·줄바꿈·NBSP)으로 나눈다. 단어가 없으면(빈칸만) 전부(Chrome 154 실측 2026-10-07).
    "function words(s){var w=arr(),k=0,st=-1;for(var i=0;i<=s.length;i++){var c=i<s.length?A(CC,s,[i]):32;if(c<=32||c===160){if(st>=0){w[k++]=A(SL,s,[st,i]);st=-1}}else if(st<0)st=i}return w}" ++
    "function cost(s){var n=s.length+2;for(var i=0;i<s.length;i++){var c=A(CC,s,[i]);if(c<32)n+=5;else if(c===34||c===92)n++}return n}" ++
    "function cut(s){if(s.length<=512)return s;s=A(SL,s,[0,512]);var c=A(CC,s,[511]);return c>=55296&&c<=56319?A(SL,s,[0,511]):s}" ++
    // 제안 목록이 붙은, 쓸 수 있는 글 칸이면 그 칸(아니면 null). getter 를 다른 객체에 부르면 던진다 — 그것으로 종류를 가린다.
    "function fieldOf(t){try{return K[A(TG,t,[])]===1&&!A(RO,t,[])&&!A(DI,t,[])&&A(LG,t,[])?t:null}catch(e){return null}}" ++
    // 사건의 진짜 대상 — 열린 shadow 안이면 그 안의 것(window 에서 `target` 은 host 다).
    "function tgt(e){var p=A(CP,e,[]);return p.length?p[0]:null}" ++
    // 초점 — 칸의 root 를 따라 올라가며 각 shadow root 의 `activeElement` 가 그 아래 것이고, 끝에 문서의 `activeElement` 가 바깥 host.
    "function focused(t){try{if(!A(HF,D,[]))return false;var n=t,r=A(RN,n,[]);while(r!==D){if(A(SA,r,[])!==n)return false;n=A(SH,r,[]);r=A(RN,n,[])}return A(AE,D,[])===n}catch(e){return false}}" ++
    // g 가 t 를 품는가 — shadow 경계를 넘어(부모가 없으면 host 로).
    "function holds(g,t){var n=t;while(n){if(n===g)return true;var p=A(PN,n,[]);if(!p){try{p=A(SH,n,[])}catch(x){p=null}}n=p}return false}" ++
    // 보인 칸의 shadow root 마다 스크롤 수신자를 한 번 단다(스크롤은 composed 가 아니다).
    "function watch(t){try{var r=A(RN,t,[]);while(r!==D){if(!A(WH,roots,[r])){A(WA,roots,[r]);A(AL,r,['scroll',onScroll,true])}r=A(RN,A(SH,r,[]),[])}}catch(e){}}" ++
    "function onScroll(e){try{var g=tgt(e);if(cur&&g!==cur&&holds(g,cur))hide()}catch(x){}}" ++
    // iframe 의 원점 — 신뢰된 포인터 사건의 screen − client(주 view 기준 이 프레임 viewport 의 왼쪽 위).
    // 기준점에서 20 px 넘게 움직였을 때만 확대를 판정한다(위 머리 주석). 한 번의 움직임 안에서만 — 사건 사이가 0.3 초 넘게 비면(그
    // 사이에 바깥이 스크롤했을 수 있다 — 위아래로 움직이며 바깥이 위아래로 스크롤하면 한 쌍으로는 확대와 가르지 못한다) 그 사건을 새
    // 기준점으로 둔다. 확대로 판정되면 다음 판정까지 원점을 쓰지 않는다.
    "function seen(e){if(main||!real(e))return;try{var sx=A(SX,e,[]),sy=A(SY,e,[]),cx=A(CX,e,[]),cy=A(CY,e,[]),now=A(PW,PF,[]);if(now-lt>300)anchored=false;lt=now;" ++
    "if(!anchored){anchored=true;asx=sx;asy=sy;acx=cx;acy=cy}else{var dsx=sx-asx,dsy=sy-asy,dcx=cx-acx,dcy=cy-acy;" ++
    // 포인터가 그대로(screen 차이 0 — 정수 DIP)인데 client 만 바뀌었다 — 프레임이 옮겨졌다. 기준점만 새로 놓고 확대 판정은 두다(축소한
    // iframe 에서 천천히 움직이면 screen 차이 1 에 client 차이 2 가 되어 확대를 지울 수 있었다 — 3 회차). 확대는 두 번 이어서 판정돼야
    // 남긴다(바깥 스크롤 애니메이션 중 한 번 움직인 것으로 남지 않게 — 3 회차), 맞는 판정 하나면 지운다.
    "if(dsx===0&&dsy===0){if(dcx!==0||dcy!==0){asx=sx;asy=sy;acx=cx;acy=cy}}" ++
    "else if(MA(dcx)>=20||MA(dcy)>=20){if(MA(dsx-dcx)>1||MA(dsy-dcy)>1){hits++;scaled=hits>=2}else{hits=0;scaled=false}asx=sx;asy=sy;acx=cx;acy=cy}}" ++
    "if(scaled){ot=-1;return}ox=sx-cx;oy=sy-cy;ot=now}catch(x){}}" ++
    "function hide(){if(!cur)return;cur=null;vals=null;try{send('dl',J({__proto__:null,t:0,v:ver}))}catch(e){}}" ++
    "function show(t){try{var l=A(LG,t,[]);if(!l)return hide();var q=words(A(LC,S(A(VG,t,[])),[])),os=A(OG,l,[]),n=A(CL,os,[]),it=arr(),vs=arr(),k=0,used=0;" ++
    "for(var i=0;i<n&&k<256;i++){var o=os[i];if(A(OD,o,[]))continue;var v=S(A(OV,o,[])),b=S(A(OL,o,[]));if(v==='')continue;" ++
    "var lv=A(LC,v,[]),lb=A(LC,b,[]),hit=true;for(var j=0;j<q.length;j++)if(A(IX,lv,[q[j]])<0&&A(IX,lb,[q[j]])<0){hit=false;break}if(!hit)continue;" ++
    "var p=arr();p[0]=cut(v);p[1]=cut(b);used+=cost(p[0])+cost(p[1])+4;if(used>24000)break;it[k]=p;vs[k]=v;k++}" ++
    "if(!k)return hide();" ++
    "var r=A(BR,t,[]),x=A(RX,r,[]),y=A(RY,r,[]),w=A(RW,r,[]),h=A(RH,r,[]),age=0,rr=arr();" ++
    "if(main){var vx=0,vy=0,s=1;if(VV){vx=A(VL,VV,[]);vy=A(VT,VV,[]);s=A(VC,VV,[])}rr[0]=(x-vx)*s;rr[1]=(y-vy)*s;rr[2]=w*s;rr[3]=h*s}" ++
    // iframe — 이 프레임 viewport 로 자르고 원점을 더한다. 원점을 모르면(포인터가 오지 않았다) 보이지 않는다.
    "else{if(ot<0)return hide();var x0=MX(x,0),y0=MX(y,0),x1=MN(x+w,A(IW,W,[])),y1=MN(y+h,A(IH,W,[]));if(x1<=x0||y1<=y0)return hide();" ++
    "rr[0]=x0+ox;rr[1]=y0+oy;rr[2]=x1-x0;rr[3]=y1-y0;age=MR(A(PW,PF,[])-ot)}" ++
    "cur=t;vals=vs;ver++;watch(t);" ++
    "send('dl',J({__proto__:null,t:1,v:ver,r:rr,i:it,a:age}))}catch(e){}}" ++
    "function on(type,f){A(AL,W,[type,f,true])}" ++
    "on('mousemove',seen);A(AL,W,['wheel',function(e){if(real(e))anchored=false},{__proto__:null,capture:true,passive:true}]);" ++
    "function typed(e){if(real(e))kt=A(PW,PF,[])}on('keydown',typed);on('compositionstart',typed);on('compositionupdate',typed);on('compositionend',typed);on('paste',typed);on('drop',typed);" ++
    "on('mousedown',function(e){try{seen(e);if(busy||!real(e))return;var t=fieldOf(tgt(e));if(t&&A(MB,e,[])===0&&!A(MC,e,[]))show(t);else hide()}catch(x){}});" ++
    "on('input',function(e){try{if(busy||!real(e))return;var t=fieldOf(tgt(e));if(!t||!focused(t))return;if(!main&&A(PW,PF,[])-kt>1000){if(cur===t)hide();return}if(S(A(VG,t,[]))==='')return hide();show(t)}catch(x){}});" ++
    "on('keydown',function(e){try{if(busy||!real(e)||A(KK,e,[])!=='ArrowDown'||A(KA,e,[])||A(KC,e,[])||A(KM,e,[]))return;var t=fieldOf(tgt(e));if(t&&focused(t))show(t)}catch(x){}});" ++
    "on('focusout',function(e){try{if(cur&&tgt(e)===cur)hide()}catch(x){}});" ++
    // 스크롤은 그 칸을 품은 것(문서·조상)일 때만 — 캡처라 페이지의 다른 상자(채팅 기록·캐러셀)의 스크롤도 오고, 칸 자신도
    // 긴 값을 칠 때 가로로 스크롤된다(`contains` 는 자기 자신에도 참이다 — 적대 검증 2 차).
    "on('scroll',onScroll);on('resize',function(){hide()});on('pagehide',function(){hide()});" ++
    // 고르기 — 같은 판이고 그 칸에 아직 초점이 있고 쓸 수 있을 때만 넣는다. 넣는 동안 우리 `input` 처리기는 다시 보이지 않는다.
    // 넣었든 거절했든 닫는다 — 단 판이 다르면 닫지 않는다: 그 사이 새 목록이 나갔으므로 닫기가 새 목록을 닫았다(글자를 치고 곧바로
    // Enter — 옛 목록의 고르기가 거절되며 새 목록까지 사라졌다, 적대 검증 3 차).
    "send('dl',function(v,i){var ok=false;try{ok=v===ver&&!!cur&&focused(cur)&&fieldOf(cur)===cur&&i>=0&&i<vals.length}catch(x){}" ++
    "if(ok){var t=cur;busy=true;try{A(VS,t,[vals[i]]);A(DE,t,[new E('input',{__proto__:null,bubbles:true,composed:true})]);A(DE,t,[new E('change',{__proto__:null,bubbles:true})])}catch(x){}busy=false}" ++
    "if(v===ver)hide()})" ++
    "})();";

comptime {
    @setEvalBranchQuota(100_000);
    std.debug.assert(std.mem.indexOfAny(u8, script_part, "\"\\\n") == null);
}

/// 렌더러가 보낸 목록 하나를 풀어 둔 것(순수 — 시험한다).
pub const Parsed = union(enum) {
    hide: i32,
    /// `age_ms` — iframe 이 원점(포인터 사건)을 잰 뒤 지난 시간(주 프레임은 0). sidecar 가 최상위 스크롤 뒤의 낡은 자리를 버린다.
    show: struct { version: i32, field: message.Rect, count: u16, items: []const u8, age_ms: u32 = 0 },
};

/// `{t:0,v}` 는 닫기, `{t:1,v,r:[x,y,w,h],i:[[값,레이블],…]}` 는 보이기. 항목 글이 UTF-8 이 아니면(대리 스크립트가 아닌 것이
/// 보냈다) 목록 전체를 버린다 — 하나만 건너뛰면 고른 번호가 스크립트가 쥔 항목과 어긋난다. `items_buf` 에 덩어리를 쌓는다.
/// view 와 겹치지 않는 칸은 보이지 않는다(null).
pub fn parse(payload: []const u8, view: message.ViewSize, items_buf: []u8) ?Parsed {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    return parseValue(parsed.value, view, items_buf);
}

fn parseValue(root: std.json.Value, view: message.ViewSize, items_buf: []u8) ?Parsed {
    if (root != .object) return null;
    const kind = root.object.get("t") orelse return null;
    const version_value = root.object.get("v") orelse return null;
    if (kind != .integer or version_value != .integer) return null;
    if (version_value.integer < 0 or version_value.integer > std.math.maxInt(i32)) return null;
    const version: i32 = @intCast(version_value.integer);
    if (kind.integer == 0) return .{ .hide = version };
    if (kind.integer != 1) return null;
    const rect = root.object.get("r") orelse return null;
    if (rect != .array or rect.array.items.len != 4) return null;
    var nums: [4]f64 = undefined;
    for (rect.array.items, 0..) |item, i| {
        nums[i] = switch (item) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => return null,
        };
        if (!std.math.isFinite(nums[i])) return null;
    }
    // view 와 겹치는 칸만(자리는 view DIP — 겹침은 원래 사각형으로 본다). 그다음 네 변을 view 둘레 한 겹 안으로 묶는다(코덱
    // 상한 안 — 넓은 칸이 왼쪽 밖에서 시작해도 보이는 쪽 끝은 그대로).
    const vw: f64 = @floatFromInt(view.width);
    const vh: f64 = @floatFromInt(view.height);
    if (nums[2] < 0 or nums[3] < 0) return null;
    if (nums[0] >= vw or nums[1] >= vh or nums[0] + nums[2] <= 0 or nums[1] + nums[3] <= 0) return null;
    const x = @max(nums[0], -vw);
    const y = @max(nums[1], -vh);
    const w = @min(nums[0] + nums[2], 2 * vw) - x;
    const h = @min(nums[1] + nums[3], 2 * vh) - y;
    const items = root.object.get("i") orelse return null;
    if (items != .array) return null;
    var builder: protocol.fields.DatalistBuilder = .{ .buf = items_buf };
    for (items.array.items) |item| {
        if (item != .array or item.array.items.len != 2) return null;
        const value = item.array.items[0];
        const label = item.array.items[1];
        if (value != .string or label != .string) return null;
        if (!std.unicode.utf8ValidateSlice(value.string) or !std.unicode.utf8ValidateSlice(label.string)) return null;
        if (!builder.add(value.string, label.string)) break;
    }
    if (builder.count == 0) return null;
    var age_ms: u32 = 0;
    if (root.object.get("a")) |age| {
        if (age != .integer or age.integer < 0) return null;
        age_ms = @intCast(@min(age.integer, std.math.maxInt(u32)));
    }
    return .{ .show = .{
        .age_ms = age_ms,
        .version = version,
        .field = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)), .width = @intFromFloat(@round(w)), .height = @intFromFloat(@round(h)) },
        .count = builder.count,
        .items = builder.items(),
    } };
}

// ── 순수 시험 ─────────────────────────────────────────────────────────────────────────────────────────────

const test_view: message.ViewSize = .{ .width = 800, .height = 600, .scale = 2 };

test "datalist payload: show keeps order, blanks a label equal to the value, and rounds the field into view DIP" {
    var buf: [message.max_datalist_bytes]u8 = undefined;
    const got = parse("{\"t\":1,\"v\":3,\"r\":[0.4,10.6,300,40],\"i\":[[\"apple\",\"apple\"],[\"banana\",\"yellow fruit\"]]}", test_view, &buf).?;
    try std.testing.expectEqual(@as(i32, 3), got.show.version);
    try std.testing.expectEqual(message.Rect{ .x = 0, .y = 11, .width = 300, .height = 40 }, got.show.field);
    try std.testing.expectEqual(@as(u16, 2), got.show.count);
    var it: protocol.fields.DatalistItems = .{ .bytes = got.show.items };
    try std.testing.expectEqualStrings("", (try it.next()).?.label);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("banana", second.value);
    try std.testing.expectEqualStrings("yellow fruit", second.label);
    try std.testing.expectEqual(Parsed{ .hide = 4 }, parse("{\"t\":0,\"v\":4}", test_view, &buf).?);
}

test "datalist payload: malformed, out of view, empty, or non-UTF-8 lists are not shown" {
    var buf: [message.max_datalist_bytes]u8 = undefined;
    const bad = [_][]const u8{
        "[]",
        "{\"t\":2,\"v\":1}",
        "{\"t\":1,\"v\":-1,\"r\":[0,0,1,1],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,1],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,1,\"1\"],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"\",\"only an empty value\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[800,0,10,10],\"i\":[[\"a\",\"\"]]}", // view 오른쪽 밖
        "{\"t\":1,\"v\":1,\"r\":[-20,0,10,10],\"i\":[[\"a\",\"\"]]}", // view 왼쪽 밖
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\\ud800\",\"\"]]}", // 짝 없는 대리 — 하나라도 있으면 목록 전체를 버린다
    };
    for (bad) |payload| try std.testing.expect(parse(payload, test_view, &buf) == null);
    // 걸친 칸은 보인다 — 자리는 view 둘레 한 겹 안으로.
    const edge = parse("{\"t\":1,\"v\":1,\"r\":[-5000,590,6000,40],\"i\":[[\"a\",\"\"]]}", test_view, &buf).?;
    try std.testing.expectEqual(@as(i32, -800), edge.show.field.x);
    try std.testing.expectEqual(@as(u32, 1800), edge.show.field.width); // 오른쪽 끝 1000 은 그대로
    try std.testing.expect(parse("{\"t\":1,\"v\":1,\"r\":[0,0,-1,10],\"i\":[[\"a\",\"\"]]}", test_view, &buf) == null); // 음수 크기
}

test "datalist payload: an iframe's origin age is kept, a missing age is 0, and a malformed age drops the list (W6m③)" {
    var buf: [message.max_datalist_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 250), parse("{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\",\"\"]],\"a\":250}", test_view, &buf).?.show.age_ms);
    try std.testing.expectEqual(@as(u32, 0), parse("{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\",\"\"]]}", test_view, &buf).?.show.age_ms);
    try std.testing.expect(parse("{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\",\"\"]],\"a\":-1}", test_view, &buf) == null);
    try std.testing.expect(parse("{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\",\"\"]],\"a\":1.5}", test_view, &buf) == null);
}
