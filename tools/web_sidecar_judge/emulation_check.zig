//! W9e① 판정 — 실제 CEF 154 에서 기기 흉내(docs/plans/web-osr-backend.md 「W9e① 결정·실측」). 판정자가 **maru 역할**로 `emulation`(탭마다 전체
//! 상태)·`resize`·`navigate`·`nav_action`·사람 입력(`mouse`)을 보내고 `emulation_state`·`permission_request`·`renderer_gone` 과 픽셀 링(W2 —
//! 사용자가 보는 것)을 모은다. 페이지가 본 것은 DevTools `Runtime.evaluate`(지킴이 막지 않는 읽기)로, 서버가 받은 머리는 따로 띄운 서버의 기록으로
//! 잰다. `127.0.0.1:<포트>` 와 `localhost:<포트>` 는 다른 사이트다. 시나리오마다 sidecar·프로필을 따로 띄운다(Chromium 이 위치 허용을 프로필에
//! 저장한다).
//!
//! 화면(`emv`): emu-viewport-fit(링의 줄에서 흉내 화면 전체가 pane 왼쪽 위에 줄어 — E2)·emu-viewport-exact(pane 보다 작은 흉내)·emu-resize-refit
//!   (pane 이 바뀌면 다시 셈한다)·emu-user-input-fit(사용자 마우스는 Chromium 이 옮긴다)·emu-w9b-click-scaled(CDP 입력은 × fit 이어야 맞는 요소 —
//!   곱하지 않으면 다른 곳: E3)·emu-screenshot-size(흉내 화면 전체 @흉내 배율)·emu-touch·emu-vision-visible(사용자 화면이 회색)·emu-media-clear
//!   (forced-colors 가 지워진다 — E17).
//! 정체(`emi`): emu-ua-headers·emu-ua-derived-hints·emu-ua-none-safari·emu-accept-language-only·emu-locale-tz·emu-persist(같은·다른 사이트·새로고침·
//!   뒤로)·emu-first-doc-reload·emu-not-covered(다른 사이트 iframe 은 진짜 값 — 정직 표시의 근거)·emu-guard(maru 경유 Emulation.*·
//!   Network.setUserAgentOverride·Browser.grantPermissions 거절)·emu-cost.
//! 죽은 탭(`emd`): emu-dead-tab-no-crash(렌더러를 죽이고 흉내 화면을 바꿔도 host 가 산다 — 쌓았다가 새 렌더러에서, E11).
//! 위치(`emg`): emu-geo-agent(묻지 않고 허용·에이전트 좌표·이동해도 남음·끝나면 대신 허용 출처가 상태에서 빠짐 — Q2; 저장된 설정의 되돌림은 페이지로
//!   보이지 않는다 — Chromium 154 는 그 허용을 페이지 권한에 쓰지 않았다: `permissions.query` 는 처음부터 `prompt`)·emu-geo-no-context-grant(같은 출처의
//!   다른 탭은 에이전트 좌표를 받지 않고 maru 에 묻는다)·emu-geo-hidden-held(obs)(숨은 탭의 위치 요청은 Chromium 이 보일 때까지 붙잡는다 — 프롬프트도
//!   나오지 않는다, 보이면 묻지 않고 에이전트 좌표).
//! 섞인 프롬프트(`emx`): emu-geo-mixed-prompt(에이전트 좌표가 걸린 탭의 페이지·같은/다른 출처 iframe 이 위치와 알림·MIDI·화면 정보·글꼴·
//!   idle·클립보드·카메라·마이크를 한꺼번에 청한다 — 위치 말고는 무엇도 묻지 않고 허용되지 않는다(maru 가 거절한다), maru 에 온 위치만의 프롬프트는
//!   없다, 위치가 섞인 프롬프트가 오면 그것도 maru 에 왔다; 받은 프롬프트의 종류를 적는다 — Chromium 154 가 위치를 다른 권한과 한 프롬프트로
//!   묶는지 실측)·emu-geo-maru-answer-keeps-agent(되돌릴 표에 적지 못하는 긴 출처의 위치 요청은 maru 에 오고, maru 가 제 좌표로 답해도
//!   에이전트 좌표가 남는다).
//! 사이트 묶기(`ems`): emu-site-bound(사이트 안에서만 — 떠나면 지우고 돌아오면 다시, 리다이렉트로 떠나는 홉 하나는 늦다: E12)·
//!   emu-site-bound-aborted-hop(문서 없이 끊긴 이동(204)은 옛 문서의 사이트로 되돌린다 — 밖의 문서에서 묶인 사이트로 가는 204 가 그 문서에 흉내를
//!   걸지 않고, 묶인 사이트의 문서에서 밖으로 가는 204 가 흉내를 풀어 두지 않는다).
//! 넘나듦(`emh`): emu-site-bound-bfcache(뒤로·앞으로 돌아간 밖의 문서가 첫 스크립트·pageshow 에서 흉내를 보지 않고 그 요청이 흉내 머리를 싣지
//!   않는다 — maru 의 Chromium 은 bfcache 를 끈다)·emu-site-bound-slow-hop(밖의 문서가 묶인 사이트의 느린 주소로 가는 이동을 기다리는 동안 흉내를
//!   보지 않고, 그동안 그 문서가 만든 iframe 셋·Worker 의 요청은 진짜 머리다 — 탭 전체의 흉내는 모두 커밋 뒤에 걸고, 그 홉의 문서 요청 하나에만
//!   흉내 머리를 넣는다: 커밋 뒤 요청과 같은 꼴, 새 문서의 첫 스크립트는 모든 흉내)·emu-site-bound-hop-headers(client hints 를 가진 흉내 — 밖 → 안
//!   302 → 밖: 안 홉은 흉내 UA·Accept-Language·client hints 셋, 밖으로 가는 다음 홉은 진짜; 느린 홉의 문서 요청 머리가 커밋 뒤 요청과 같다)·
//!   emu-site-bound-error-page(밖 → 묶인 사이트의 닫힌 포트: 오류 페이지가 기다림을 끝낸다 — 상태는 그 주소의 사이트 안·기다림 없음, 다음 밖 이동은
//!   진짜).
//! 팝업(`emp`): emu-popup-shared(같은 프로세스의 팝업은 시간대·locale 이 따라오고 제 흉내는 process_shared_conflict — E13).
//! 재시작(`emr`): emu-restart(about:blank → 흉내 → 이동이면 문서 요청부터, 옛 sidecar 가 대신 허용한 출처는 새 sidecar 가 되돌린다 — P2-6).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const ring = @import("web_sidecar_ring");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const chunk = msg.devtools_chunk_bytes;
const iosurface = ring.iosurface;
const Receiver = ring.ring_receiver.Receiver;
const Ring = ring.ring_receiver.Ring;
const mailbox = protocol.mailbox;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const wait_ms = 15_000;
const max_tabs = 8;

// ── 서버(받은 문서·자원 요청의 머리를 적는다) ─────────────────────────────────────────────────────────────

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SockaddrIn = extern struct {
    len: u8 = @sizeOf(SockaddrIn),
    family: u8 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};
extern "c" fn socket(domain: c_int, kind: c_int, protocol_: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
const Timeval = extern struct { sec: i64, usec: i32 };

pub var port: u16 = 0;

/// 서버가 받은 요청 하나(머리 몇 가지).
const Rec = struct {
    target: [160]u8 = undefined,
    target_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    ua: [400]u8 = undefined,
    ua_len: usize = 0,
    al: [64]u8 = undefined,
    al_len: usize = 0,
    chua: [200]u8 = undefined,
    chua_len: usize = 0,
    plat: [32]u8 = undefined,
    plat_len: usize = 0,
    mob: [8]u8 = undefined,
    mob_len: usize = 0,

    fn put(buf: []u8, len: *usize, v: []const u8) void {
        const n = @min(v.len, buf.len);
        @memcpy(buf[0..n], v[0..n]);
        len.* = n;
    }
    fn targetText(self: *const Rec) []const u8 {
        return self.target[0..self.target_len];
    }
    fn uaText(self: *const Rec) []const u8 {
        return self.ua[0..self.ua_len];
    }
    fn alText(self: *const Rec) []const u8 {
        return self.al[0..self.al_len];
    }
    fn chuaText(self: *const Rec) []const u8 {
        return self.chua[0..self.chua_len];
    }
    fn platText(self: *const Rec) []const u8 {
        return self.plat[0..self.plat_len];
    }
    fn mobText(self: *const Rec) []const u8 {
        return self.mob[0..self.mob_len];
    }
};

var srv_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var srv_recs: std.ArrayList(Rec) = .empty;

pub fn startServer() !void {
    if (port != 0) return;
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 512) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    port = std.mem.bigToNative(u16, addr.port);
    const t = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    t.detach();
}

fn acceptLoop(fd: c_int) void {
    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        const timeout: Timeval = .{ .sec = 2, .usec = 0 };
        _ = setsockopt(conn, 0xffff, 0x1006, &timeout, @sizeOf(Timeval));
        const t = std.Thread.spawn(.{}, serveOne, .{conn}) catch {
            _ = std.c.close(conn);
            continue;
        };
        t.detach();
    }
}

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [2048]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(conn, buf[len..].ptr, buf.len - len);
        if (n <= 0) return;
        len += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") != null) break;
    }
    serveParsed(conn, buf[0..len]);
}

fn headerOf(r: []const u8, comptime name: []const u8) []const u8 {
    var it = std.mem.splitSequence(u8, r, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return "";
}

const html = "text/html; charset=utf-8";
/// 첫 요청부터 client hints 를 다 받게(문서 요청이 그 사이트의 Accept-CH 를 기억한다).
const accept_ch = "Accept-CH: Sec-CH-UA-Platform-Version, Sec-CH-UA-Model, Sec-CH-UA-Full-Version-List, Sec-CH-UA-Arch\r\n";

/// 페이지·iframe·worker 가 함께 쓰는 「무엇이 보이나」.
const p_js =
    \\function P(){var o={};try{o.ua=navigator.userAgent;o.plat=navigator.platform;o.lang=navigator.language;var r=Intl.DateTimeFormat().resolvedOptions();o.il=r.locale;o.tz=r.timeZone;o.off=new Date().getTimezoneOffset();if(navigator.userAgentData){var d=navigator.userAgentData;o.uad=d.brands.map(function(x){return x.brand+'/'+x.version}).join(',')+'|m='+d.mobile+'|p='+d.platform}else o.uad='none';if(typeof matchMedia!=='undefined'){o.iw=innerWidth;o.dpr=devicePixelRatio}}catch(e){o.err=String(e)}return o}
;

const vp_html =
    \\<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>vp</title>
    \\<style>html,body{margin:0;height:100%;background:#ff0000}@media (prefers-color-scheme:dark){html,body{background:#000080}}
    \\#g{position:fixed;left:0;top:0;width:100px;height:100px;background:#00ff00}#b{position:fixed;right:0;bottom:0;width:100px;height:100px;background:#0000ff}
    \\#y{position:fixed;right:0;top:0;width:100px;height:100px;background:#ffff00}</style>
    \\<div id=g></div><div id=b></div><div id=y></div>
    \\<script>window.ev=[];['click'].forEach(function(t){addEventListener(t,function(e){ev.push(t+':'+Math.round(e.clientX)+','+Math.round(e.clientY)+':'+(e.target.id||e.target.nodeName))},{capture:true})});
    \\window.M=function(){return JSON.stringify({iw:innerWidth,ih:innerHeight,dpr:devicePixelRatio,mtp:navigator.maxTouchPoints,coarse:matchMedia('(pointer:coarse)').matches,fc:matchMedia('(forced-colors:active)').matches,light:matchMedia('(prefers-color-scheme:light)').matches,print:matchMedia('print').matches,orient:screen.orientation&&screen.orientation.type,tz:Intl.DateTimeFormat().resolvedOptions().timeZone})};
    \\window.E=function(){var r=ev.join(' ');ev=[];return r};
    \\window.B=function(){var r=document.getElementById('b').getBoundingClientRect();return JSON.stringify({x:(r.left+r.right)/2,y:(r.top+r.bottom)/2})};</script>
;

const pp_head = "<!doctype html><title>pp</title><body><iframe id=f onload='window.fready=1' src='";
const pp_tail =
    \\'></iframe><script>
++ p_js ++
    \\
    \\function ask(t,tag){return new Promise(function(res){var ch=new MessageChannel();ch.port1.onmessage=function(e){res(e.data)};t.postMessage(tag,'*',[ch.port2]);setTimeout(function(){res('timeout')},4000)})}
    \\async function ALL(tag){if(!window.fready)await new Promise(function(r){document.getElementById('f').onload=r;setTimeout(r,3000)});var f=await ask(document.getElementById('f').contentWindow,tag);return JSON.stringify({main:P(),oopif:f})}
    \\function G(){return new Promise(function(res){navigator.geolocation.getCurrentPosition(function(p){res('ok '+p.coords.latitude+','+p.coords.longitude+' acc='+p.coords.accuracy)},function(e){res('err '+e.code)},{timeout:6000,maximumAge:0})})}
    \\async function GP(){try{return (await navigator.permissions.query({name:'geolocation'})).state}catch(e){return 'qerr '+e.message}}
    \\</script>
;

const fr_html = "<!doctype html><title>fr</title><script>" ++ p_js ++
    \\
    \\addEventListener('message',function(e){e.ports[0].postMessage(P())})</script>
;

/// 섞인 프롬프트(W9e① J5): 위치와 다른 권한을 같은 차례에 한꺼번에 청한다 — 결과는 차례대로 [위치, 알림, MIDI sysex, 화면 정보, 글꼴, idle,
/// 클립보드, 카메라+마이크]. 허용되면 「granted」 로 시작한다(위치는 「ok 위,경」). 글꼴은 거절돼도 빈 목록으로 풀린다(실측) — 「empty」.
const mx_js =
    \\function T(p){return Promise.race([p,new Promise(function(r){setTimeout(function(){r('timeout')},6000)})])}
    \\function R(p,ok){return T(p.then(ok||function(){return 'granted'},function(e){return 'rej '+(e&&e.name)}))}
    \\function ALLP(){var a=[];
    \\a.push(T(new Promise(function(res){navigator.geolocation.getCurrentPosition(function(p){res('ok '+p.coords.latitude+','+p.coords.longitude)},function(e){res('err '+e.code)},{timeout:5500,maximumAge:0})})));
    \\try{a.push(window.Notification?R(Notification.requestPermission(),function(x){return x==='granted'?'granted':String(x)}):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(navigator.requestMIDIAccess?R(navigator.requestMIDIAccess({sysex:true})):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(window.getScreenDetails?R(getScreenDetails()):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(window.queryLocalFonts?R(queryLocalFonts(),function(f){return f.length?'granted '+f.length:'empty'}):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(window.IdleDetector?R(IdleDetector.requestPermission(),function(x){return x==='granted'?'granted':String(x)}):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(navigator.clipboard&&navigator.clipboard.readText?R(navigator.clipboard.readText()):'na')}catch(e){a.push('throw '+e.name)}
    \\try{a.push(navigator.mediaDevices?R(navigator.mediaDevices.getUserMedia({video:true,audio:true})):'na')}catch(e){a.push('throw '+e.name)}
    \\return Promise.all(a)}
;
const mx_allow = "geolocation; midi; window-management; local-fonts; idle-detection; clipboard-read; camera; microphone";
const mxf_html = "<!doctype html><title>mxf</title><script>" ++ mx_js ++
    \\
    \\addEventListener('message',function(e){ALLP().then(function(r){e.ports[0].postMessage(r)})})</script>
;
const mx_head = "<!doctype html><title>mx</title><iframe id=s allow='" ++ mx_allow ++ "' src='/mxf'></iframe><iframe id=x allow='" ++ mx_allow ++ "' src='";
const mx_tail = "'></iframe><script>" ++ mx_js ++
    \\
    \\function ask(id){var t=document.getElementById(id).contentWindow;return new Promise(function(res){var ch=new MessageChannel();ch.port1.onmessage=function(e){res(e.data)};t.postMessage('go','*',[ch.port2]);setTimeout(function(){res('timeout')},9000)})}
    \\async function MX(){var r=await Promise.all([ALLP(),ask('s'),ask('x')]);return JSON.stringify({main:r[0],same:r[1],cross:r[2]})}
    \\async function MAIN(){return JSON.stringify(await ALLP())}
    \\</script>
;

/// 사이트 밖 문서가 흉내를 보는가(사이트 묶기의 오감 — `bound_all` 의 값만 고른다): 보인 것의 이름을 쉼표로, 없으면 `-`.
const sg_js =
    \\function SG(){var l=[];try{var r=Intl.DateTimeFormat().resolvedOptions();if(r.timeZone==='Asia/Tokyo')l.push('tz');if(String(r.locale).indexOf('fr')===0)l.push('il');if(navigator.userAgent.indexOf('BoundUA')===0)l.push('ua');if(String(navigator.language).indexOf('fr')===0)l.push('lang');if(innerWidth===390)l.push('iw');if(devicePixelRatio===3)l.push('dpr');if(navigator.maxTouchPoints===5)l.push('mtp');if(matchMedia('print').matches)l.push('print');if(matchMedia('(forced-colors:active)').matches)l.push('fc')}catch(x){l.push('err')}return l.join('.')||'-'}
;
/// 느린 이동을 기다리는 옛 문서: 100 ms 마다 제가 보는 것을 서버로(요청 머리도 서버가 적는다). `KID()` 는 기다리는 동안 브라우저 쪽에서 요청을
/// 만드는 것 넷 — 같은 사이트 iframe·다른 사이트(b.localhost) iframe·iframe 을 대상으로 한 form 제출·dedicated Worker(집중 검증 1 회차: 홉에서 건
/// 탭 전체의 UA 가 이 요청들에 실렸다). `GO(u,k)` 는 그 주소로 옮기고 `k` 면 700 ms 뒤 `KID()`.
const ob_html = "<!doctype html><title>ob</title><body><script>" ++ sg_js ++
    \\
    \\window.T0=SG();var n=0;setInterval(function(){n++;fetch('/obs?n='+n+'&e='+SG()).catch(function(){})},100);
    \\function KID(){var a=document.createElement('iframe');a.src='/ifr?same';document.body.appendChild(a);
    \\var b=document.createElement('iframe');b.src='http://b.localhost:'+location.port+'/ifr?cross';document.body.appendChild(b);
    \\try{window.W=new Worker('/wk?w')}catch(e){}
    \\var q=document.createElement('iframe');q.name='ff';document.body.appendChild(q);
    \\var f=document.createElement('form');f.method='GET';f.action='/ifr';f.target='ff';var h=document.createElement('input');h.name='form';h.value='1';f.appendChild(h);document.body.appendChild(f);f.submit()}
    \\window.GO=function(u,k){setTimeout(function(){location.href=u},0);if(k)setTimeout(KID,700);return 'go'};
    \\</script>
;
/// 기다리는 동안 만든 iframe 의 문서 — 그 안의 fetch 도 서버가 적는다.
const ifr_html = "<!doctype html><title>ifr</title><script>" ++ sg_js ++
    \\
    \\fetch('/ifs?t='+location.search.slice(1)+'&h='+location.host+'&e='+SG()).catch(function(){});
    \\</script>
;
const wk_js = "fetch('/wks?e='+(navigator.userAgent.indexOf('BoundUA')===0?'ua':'-')+'&l='+navigator.language).catch(function(){})";
/// 느린 응답 뒤의 새 문서(묶인 사이트) — 첫 스크립트가 본 것(`T0`)과 `P()`, 첫 스크립트의 요청 하나(`/aft?<같은 꼬리>&nu=` — 그때 navigator 의
/// UA 가 흉내 `B`(BoundUA)·`A`(Android)·진짜 `R`; 관측: 탭 전체 흉내는 커밋에서 걸려 이 요청과 겨룬다).
const slow_html = "<!doctype html><title>slow</title><script>" ++ sg_js ++ "window.T0=SG();" ++ p_js ++
    "var nu=navigator.userAgent;fetch('/aft?'+location.search.slice(1)+'&nu='+(nu.indexOf('BoundUA')===0?'B':nu.indexOf('Android')>0?'A':'R')).catch(function(){});</script>";
/// 묶인 사이트의 렌더러가 이미 떠 있는 새 문서(`/slowr` — `/slow` 와 같은 느린 응답): 첫 스크립트가 본 것(`T0`)과 그 요청 하나(`/aft?…`), 모든 흉내가 보인
/// 때(`FULL` — 첫 스크립트로부터 ms, 처음부터면 0, 5 초 안에 못 보면 -1).
const slowr_html = "<!doctype html><title>slowr</title><script>" ++ sg_js ++
    "window.T0=SG();var t0=performance.now(),A='tz.il.ua.lang.iw.dpr.mtp.print.fc';window.FULL=T0===A?0:-1;" ++
    "var nu=navigator.userAgent;fetch('/aft?'+location.search.slice(1)+'&nu='+(nu.indexOf('BoundUA')===0?'B':'R')).catch(function(){});" ++
    "if(FULL<0)(function q(){if(SG()===A){FULL=Math.round(performance.now()-t0);return}if(performance.now()-t0<5000)setTimeout(q,2)})();</script>";
/// bfcache 에 들 수 있는 문서(no-store 없음 — `replyCacheable`): 첫 스크립트와 pageshow 가 본 것, pageshow 의 요청.
const bf_html = "<!doctype html><title>bf</title><script>" ++ sg_js ++
    \\
    \\window.T0=SG();window.PS=[];addEventListener('pageshow',function(e){var s=SG();PS.push((e.persisted?'P':'N')+':'+s);fetch('/sub?bf='+location.search.slice(1)+'&p='+(e.persisted?1:0)+'&e='+s).catch(function(){})});
    \\</script>
;

/// `reply` 와 같되 `Cache-Control: no-store` 없이(bfcache 에 들 수 있게).
fn replyCacheable(conn: c_int, body: []const u8) void {
    var hb: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: max-age=0\r\nConnection: close\r\n\r\n", .{ html, body.len }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}
/// W9e②: 에이전트 탭(rAF 수·보임·바쁜 반복·가져오기·긴 작업).
const tr_common_js =
    \\window.__frames=0;(function t(){window.__frames++;requestAnimationFrame(t)})();
    \\window.bench=function(n){n=n||3e7;var s=performance.now(),x=0;for(var i=0;i<n;i++){x=(x+i*7)%1000003}window.__x=x;return Math.round(performance.now()-s)};
    \\window.ft=async function(u){var s=performance.now();try{var r=await fetch(u,{cache:'no-store'});await r.text();return 'ok '+Math.round(performance.now()-s)}catch(e){return 'err '+Math.round(performance.now()-s)}};
    \\window.ST=function(){return JSON.stringify({vis:document.visibilityState,frames:__frames,online:navigator.onLine})};
    \\window.LONG=function(ms){var s=performance.now();while(performance.now()-s<ms){}return 'long'};
;
const tr_html = "<!doctype html><title>TR-AGENT</title><body style='background:#0c0'><div id=n>trace page</div><script>" ++ tr_common_js ++ "setInterval(function(){var d=document.createElement('div');d.textContent=Math.random();document.body.appendChild(d);if(document.body.childNodes.length>200)document.body.removeChild(document.body.childNodes[2])},100);</script>";
/// 사용자 탭 안의 같은 사이트 iframe — 늘 일한다(trace 에 그 프레임 이벤트가 든다 — F3).
const tif_html = "<!doctype html><title>TIF</title><body><script>" ++ tr_common_js ++ "setInterval(function(){var d=document.createElement('p');d.textContent='IFRAMEWORK'+Math.random();document.body.appendChild(d);if(document.body.childNodes.length>50)document.body.removeChild(document.body.firstChild)},30);addEventListener('message',function(e){e.ports[0].postMessage(ST()+' bench='+bench(1e7))});</script>";
const tu_tail = "<script>window.IF=function(){return new Promise(function(r){var ch=new MessageChannel();ch.port1.onmessage=function(e){r(e.data)};document.getElementById('f').contentWindow.postMessage('x','*',[ch.port2]);setTimeout(function(){r('timeout')},6000)})};</script>";

const po_html = "<!doctype html><title>po</title><button id=o onclick=\"window.pop=window.open('/pp?child','w1')\" style='position:fixed;left:0;top:0;width:300px;height:200px'>open</button><script>" ++ p_js ++ "</script>";

fn serveParsed(conn: c_int, r: []const u8) void {
    const line_end = std.mem.indexOfScalar(u8, r, '\r') orelse return;
    var parts = std.mem.splitScalar(u8, r[0..line_end], ' ');
    _ = parts.next() orelse return;
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const host_hdr = headerOf(r, "host");
    {
        var rec: Rec = .{};
        Rec.put(&rec.target, &rec.target_len, target);
        Rec.put(&rec.host, &rec.host_len, host_hdr);
        Rec.put(&rec.ua, &rec.ua_len, headerOf(r, "user-agent"));
        Rec.put(&rec.al, &rec.al_len, headerOf(r, "accept-language"));
        Rec.put(&rec.chua, &rec.chua_len, headerOf(r, "sec-ch-ua"));
        Rec.put(&rec.plat, &rec.plat_len, headerOf(r, "sec-ch-ua-platform"));
        Rec.put(&rec.mob, &rec.mob_len, headerOf(r, "sec-ch-ua-mobile"));
        _ = std.c.pthread_mutex_lock(&srv_lock);
        srv_recs.append(std.heap.c_allocator, rec) catch {};
        _ = std.c.pthread_mutex_unlock(&srv_lock);
    }
    if (@import("w9e2_probe_a.zig").serve(conn, path, target, host_hdr)) return; // v20a 탐침 페이지
    if (@import("w9e2_probe_b.zig").serve(conn, path, target, host_hdr)) return; // v20b 탐침 페이지
    if (@import("w9e2_probe_c.zig").serve(conn, path, target, host_hdr)) return; // v20c 탐침 페이지
    var bb: [16384]u8 = undefined;
    if (std.mem.eql(u8, path, "/vp")) return reply(conn, "200 OK", html, accept_ch, vp_html);
    if (std.mem.eql(u8, path, "/pp")) {
        const other = if (std.mem.startsWith(u8, host_hdr, "127.0.0.1")) "localhost" else "127.0.0.1";
        const body = std.fmt.bufPrint(&bb, "{s}http://{s}:{d}/fr{s}", .{ pp_head, other, port, pp_tail }) catch return;
        return reply(conn, "200 OK", html, accept_ch, body);
    }
    if (std.mem.eql(u8, path, "/fr")) return reply(conn, "200 OK", html, "", fr_html);
    if (std.mem.eql(u8, path, "/mxf")) return reply(conn, "200 OK", html, "", mxf_html);
    if (std.mem.eql(u8, path, "/mx")) {
        const body = std.fmt.bufPrint(&bb, "{s}http://localhost:{d}/mxf{s}", .{ mx_head, port, mx_tail }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/po")) return reply(conn, "200 OK", html, accept_ch, po_html);
    // W9e②(perf_check.zig): trace·CPU·네트워크 조건의 페이지.
    if (std.mem.eql(u8, path, "/tr")) return reply(conn, "200 OK", html, "", tr_html);
    if (std.mem.eql(u8, path, "/tif")) return reply(conn, "200 OK", html, "", tif_html);
    if (std.mem.eql(u8, path, "/tu")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>TU-USER</title><body style='background:#e00'><iframe id=f src='http://127.0.0.1:{d}/tif?acct=IFRAMEUSERSECRET' width=300 height=200></iframe>{s}", .{ port, tu_tail }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/r2")) {
        // 묶인 사이트(127.0.0.1)에서 다른 사이트로 나가는 리다이렉트(E12 — 그 홉 요청은 흉내를 싣는다).
        const loc = std.fmt.bufPrint(&bb, "Location: http://localhost:{d}/pp?via=r2\r\n", .{port}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "r2");
    }
    // 문서 없는 이동(204 — 주 프레임 이동이 ERR_ABORTED 로 끊기고 옛 문서가 남는다; main 으로 옮길 때 더함).
    if (std.mem.eql(u8, path, "/nc")) return reply(conn, "204 No Content", "text/plain", "", "");
    if (std.mem.eql(u8, path, "/ob")) return reply(conn, "200 OK", html, "", ob_html);
    if (std.mem.eql(u8, path, "/ifr")) return reply(conn, "200 OK", html, "", ifr_html);
    if (std.mem.eql(u8, path, "/wk")) return reply(conn, "200 OK", "text/javascript", "", wk_js);
    if (std.mem.eql(u8, path, "/r3")) {
        // 밖 → 묶인 사이트(이 302) → 밖: 묶인 사이트 홉에 넣은 흉내 머리가 밖으로 가는 다음 홉에 남으면 안 된다.
        const loc = std.fmt.bufPrint(&bb, "Location: http://localhost:{d}/pp?via=r3\r\n", .{port}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "r3");
    }
    if (std.mem.eql(u8, path, "/bf")) return replyCacheable(conn, bf_html);
    // 느린 응답(`?ms=N` 동안 잡았다가 문서 — 밖의 문서가 묶인 사이트로 가는 이동을 오래 기다리게).
    if (std.mem.eql(u8, path, "/obf")) {
        // 밖의 문서가 묶인 사이트(127.0.0.1)의 iframe 을 품는다 — 그 사이트의 렌더러가 이 탭(BrowsingInstance)에 떠 있다.
        const body = std.fmt.bufPrint(&bb, "{s}<iframe src='http://127.0.0.1:{d}/ifr?emb'></iframe>", .{ ob_html, port }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/slow") or std.mem.eql(u8, path, "/slowr")) {
        var ms: u32 = 3000;
        if (std.mem.indexOf(u8, target, "ms=")) |at| {
            var e = at + 3;
            while (e < target.len and std.ascii.isDigit(target[e])) e += 1;
            ms = @min(std.fmt.parseInt(u32, target[at + 3 .. e], 10) catch 3000, 8000);
        }
        os.sleepMs(ms);
        return reply(conn, "200 OK", html, "", if (path.len == 5) slow_html else slowr_html);
    }
    return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "ok");
}

/// 그 글로 시작하는 target 의 마지막 요청(없으면 null).
fn lastReq(prefix: []const u8) ?Rec {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    var i = srv_recs.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, srv_recs.items[i].targetText(), prefix)) return srv_recs.items[i];
    }
    return null;
}

/// 그 글로 시작하고 그 호스트 머리를 가진 첫 요청.
fn firstReqOn(prefix: []const u8, host_prefix: []const u8) ?Rec {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    for (srv_recs.items) |rec| if (std.mem.startsWith(u8, rec.targetText(), prefix) and std.mem.startsWith(u8, rec.host[0..rec.host_len], host_prefix)) return rec;
    return null;
}

// ── 링(사용자가 보는 것) ───────────────────────────────────────────────────────────────────────────────────

fn controlOf(r: *const Ring) *mailbox.Control {
    return @ptrFromInt(r.control_address);
}

const Seg = struct { color: u32, start: usize, len: usize };

const View = struct {
    shown: ?Ring = null,
    front: mailbox.Slot = mailbox.initial_front,
    pending: ?Ring = null,
    pending_front: mailbox.Slot = mailbox.initial_front,
    frames: u64 = 0,

    fn adopt(self: *View, fresh: Ring) void {
        if (self.shown == null) {
            self.shown = fresh;
            self.front = mailbox.initial_front;
            return;
        }
        if (self.pending) |old| old.release();
        self.pending = fresh;
        self.pending_front = mailbox.initial_front;
    }

    fn poll(self: *View) void {
        if (self.pending) |*pending| {
            switch (mailbox.take(controlOf(pending), pending.generation, self.pending_front)) {
                .frame => |slot| {
                    self.shown.?.release();
                    self.shown = pending.*;
                    self.front = slot;
                    self.pending = null;
                    self.frames += 1;
                    return;
                },
                else => {},
            }
        }
        const shown = if (self.shown) |*shown| shown else return;
        switch (mailbox.take(controlOf(shown), shown.generation, self.front)) {
            .frame => |slot| {
                self.front = slot;
                self.frames += 1;
            },
            else => {},
        }
    }

    fn release(self: *View) void {
        if (self.shown) |s| s.release();
        if (self.pending) |p| p.release();
        self.* = .{};
    }

    /// 앞 장의 한 줄(가로)을 색 구간으로. 링이 없으면 0 개.
    fn row(self: *View, y: usize, out: []Seg) struct { segs: []Seg, width: usize, height: usize } {
        const shown = self.shown orelse return .{ .segs = out[0..0], .width = 0, .height = 0 };
        const surface = shown.surfaces[self.front];
        iosurface.lockRead(surface);
        defer iosurface.unlockRead(surface);
        const w = iosurface.width(surface);
        const h = iosurface.height(surface);
        if (y >= h) return .{ .segs = out[0..0], .width = w, .height = h };
        var n: usize = 0;
        var x: usize = 0;
        while (x < w and n < out.len) {
            const c = iosurface.pixel(surface, x, y) & 0xffffff;
            var e = x + 1;
            while (e < w and (iosurface.pixel(surface, e, y) & 0xffffff) == c) e += 1;
            out[n] = .{ .color = c, .start = x, .len = e - x };
            n += 1;
            x = e;
        }
        return .{ .segs = out[0..n], .width = w, .height = h };
    }

    fn pixelAt(self: *View, x: usize, y: usize) ?u32 {
        const shown = self.shown orelse return null;
        const surface = shown.surfaces[self.front];
        iosurface.lockRead(surface);
        defer iosurface.unlockRead(surface);
        if (x >= iosurface.width(surface) or y >= iosurface.height(surface)) return null;
        return iosurface.pixel(surface, x, y) & 0xffffff;
    }
};

fn segText(buf: []u8, segs: []const Seg) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (segs[0..@min(segs.len, 8)]) |s| w.print("{x:0>6}@{d}+{d} ", .{ s.color, s.start, s.len }) catch break;
    return w.buffered();
}

fn findColor(segs: []const Seg, color: u32) ?Seg {
    for (segs) |s| if (s.color == color) return s;
    return null;
}

// ── 운전 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// v20b 탐침(`w9e2_probe_b.zig`): `Run.take` 가 받는 메시지를 함께 본다(없으면 null — 기존 판정의 동작은 그대로).
pub var extra_hook: ?*const fn (msg.Message) void = null;

pub const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    receiver: ?*Receiver = null,
    views: [max_tabs]View = @splat(.{}),
    next_call: u32 = 100,
    result: std.ArrayList(u8) = .empty,
    created: [max_tabs]bool = @splat(false),
    loads: [max_tabs]u32 = @splat(0),
    gone: [max_tabs]u32 = @splat(0),
    gen: [max_tabs]u32 = @splat(0),
    /// 마지막 `emulation_state`(출처 목록은 수와 첫 출처만).
    st: [max_tabs]?msg.EmulationState = @splat(null),
    auto_first: [max_tabs][256]u8 = undefined,
    auto_first_len: [max_tabs]usize = @splat(0),
    states: u32 = 0,
    /// 권한 요청의 답: 0 = 허용, 1 = 거절, 2 = 답하지 않음, 3 = 위치면 maru 의 좌표(1.5, 2.5)를 보낸 뒤 허용(W5b2 — 사용자가 sheet 에서 허용), 아니면 거절.
    perm_mode: u8 = 1,
    prompts: [max_tabs]u32 = @splat(0),
    /// 받은 권한 요청의 종류(차례대로 — 섞인 프롬프트 실측).
    seen_kinds: [48]u32 = @splat(0),
    seen_media: [48]u8 = @splat(0),
    seen_n: usize = 0,
    failures: u32 = 0,
    /// W9e②: trace(판정자가 maru 역할로 받는다 — `perf_check.zig`).
    tr_states: [32]msg.TraceState = undefined,
    tr_state_n: usize = 0,
    tr_gz: std.ArrayList(u8) = .empty,
    tr_gz_bad: bool = false,
    tr_frames: std.ArrayList([64]u8) = .empty,
    tr_frame_lens: std.ArrayList(u8) = .empty,

    fn take(self: *Run, m: msg.Message) void {
        if (extra_hook) |h| h(m); // v20b 탐침: 판정자가 따로 세는 메시지(net_begin 등)
        switch (m) {
            .browser_created => |id| if (id < max_tabs) {
                self.created[id] = true;
            },
            .popup_created => |v| if (v.browser < max_tabs) {
                self.created[v.browser] = true;
            },
            .load_finished => |v| if (v.browser < max_tabs) {
                self.loads[v.browser] += 1;
            },
            .renderer_gone => |v| if (v.browser < max_tabs) {
                self.gone[v.browser] += 1;
            },
            .failure => self.failures += 1,
            .trace_state => |v| if (self.tr_state_n < self.tr_states.len) {
                self.tr_states[self.tr_state_n] = v;
                self.tr_state_n += 1;
            },
            .trace_data => |v| {
                if (v.offset != self.tr_gz.items.len) self.tr_gz_bad = true;
                self.tr_gz.appendSlice(self.gpa, v.bytes) catch {};
            },
            .trace_frames => |v| for (v.ids[0..v.count]) |id| {
                var b: [64]u8 = undefined;
                @memcpy(b[0..id.len], id);
                self.tr_frames.append(self.gpa, b) catch {};
                self.tr_frame_lens.append(self.gpa, @intCast(id.len)) catch {};
            },
            .emulation_state => |v| if (v.browser < max_tabs) {
                var keep = v;
                if (v.auto_count > 0) {
                    const n = @min(v.auto_allowed[0].len, 256);
                    @memcpy(self.auto_first[v.browser][0..n], v.auto_allowed[0][0..n]);
                    self.auto_first_len[v.browser] = n;
                } else self.auto_first_len[v.browser] = 0;
                keep.auto_allowed = @splat("");
                self.st[v.browser] = keep;
                self.states += 1;
            },
            .permission_request => |v| {
                if (v.browser < max_tabs) self.prompts[v.browser] += 1;
                if (self.seen_n < self.seen_kinds.len) {
                    self.seen_kinds[self.seen_n] = v.kinds;
                    self.seen_media[self.seen_n] = v.media;
                    self.seen_n += 1;
                }
                switch (self.perm_mode) {
                    0 => self.host.send(.{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = .accept } }) catch {},
                    1 => self.host.send(.{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = .deny } }) catch {},
                    3 => if (v.kinds & msg.PermissionKind.geolocation.bit() != 0) {
                        self.host.send(.{ .geolocation = .{ .browser = v.browser, .request = v.request, .available = true, .latitude = 1.5, .longitude = 2.5, .accuracy = 30 } }) catch {};
                        self.host.send(.{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = .accept } }) catch {};
                    } else {
                        self.host.send(.{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = .deny } }) catch {};
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn pollFrames(self: *Run) void {
        const rcv = self.receiver orelse return;
        while (rcv.receive(0) catch null) |received| switch (received) {
            .ring => |fresh| {
                if (fresh.browser < max_tabs and !fresh.popup) self.views[fresh.browser].adopt(fresh) else fresh.release();
            },
            .rejected => {},
        };
        for (&self.views) |*v| v.poll();
    }

    pub fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            self.pollFrames();
            const m = (self.host.next(10) catch null) orelse continue;
            self.take(m);
        }
    }

    pub fn until(self: *Run, comptime cond: fn (*Run, u64, u32) bool, b: u64, want: u32, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self, b, want)) {
            self.pollFrames();
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
        return cond(self, b, want);
    }

    pub fn loadsAt(self: *Run, b: u64, want: u32) bool {
        return self.loads[b] >= want;
    }
    pub fn createdAt(self: *Run, b: u64, _: u32) bool {
        return self.created[b];
    }
    pub fn goneAt(self: *Run, b: u64, want: u32) bool {
        return self.gone[b] >= want;
    }
    /// 그 세대의 상태가 와서 기다리는 것이 없다.
    pub fn settledAt(self: *Run, b: u64, want: u32) bool {
        const s = self.st[b] orelse return false;
        return s.generation == want and !s.pending;
    }
    pub fn genAt(self: *Run, b: u64, want: u32) bool {
        const s = self.st[b] orelse return false;
        return s.generation == want;
    }

    pub fn create(self: *Run, b: u64, u: []const u8) !void {
        try self.host.send(.{ .create_browser = .{ .browser = b, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = u } });
        _ = self.until(createdAt, b, 0, wait_ms);
        _ = self.until(loadsAt, b, 1, wait_ms);
        self.pump(200);
    }

    pub fn nav(self: *Run, b: u64, u: []const u8) !void {
        const before = self.loads[b];
        try self.host.send(.{ .navigate = .{ .browser = b, .url = u } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(200);
    }

    pub fn action(self: *Run, b: u64, a: msg.NavActionKind) !void {
        const before = self.loads[b];
        try self.host.send(.{ .nav_action = .{ .browser = b, .action = a } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(200);
    }

    /// 흉내 하나(세대를 올려 보낸다) — 그 세대가 자리 잡을 때까지(답을 다 받을 때까지) 기다린다. 받은 상태(없으면 null).
    pub fn emulate(self: *Run, b: u64, v: msg.Emulation) !?msg.EmulationState {
        self.gen[b] += 1;
        var e = v;
        e.browser = b;
        e.generation = self.gen[b];
        try self.host.send(.{ .emulation = e });
        _ = self.until(settledAt, b, self.gen[b], 5000);
        self.pump(150);
        return self.st[b];
    }

    pub fn call(self: *Run, browser: u64, method: []const u8, params: []const u8, ms: u32) !?msg.DevtoolsStatus {
        self.next_call += 1;
        const id = self.next_call;
        try self.host.send(.{ .devtools_call = .{ .browser = browser, .call = id, .method = method, .params_size = @intCast(params.len) } });
        var off: usize = 0;
        while (off < params.len) {
            const k = @min(chunk, params.len - off);
            try self.host.send(.{ .devtools_call_data = .{ .browser = browser, .call = id, .bytes = params[off..][0..k] } });
            off += k;
        }
        self.result.clearRetainingCapacity();
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            self.pollFrames();
            const m = (self.host.next(20) catch null) orelse continue;
            switch (m) {
                .devtools_result_data => |v| if (v.call == id) {
                    try self.result.appendSlice(self.gpa, v.bytes);
                    continue;
                },
                .devtools_result => |v| if (v.call == id) return v.status,
                else => {},
            }
            self.take(m);
        }
        return null;
    }

    pub fn ev(self: *Run, browser: u64, expr: []const u8, out: []u8) []const u8 {
        return self.evWith(browser, expr, out, false);
    }

    /// `gesture` — 사용자 누름 안에서 돈 것처럼(`userGesture` — 활성화가 있어야 묻는 권한).
    pub fn evWith(self: *Run, browser: u64, expr: []const u8, out: []u8, gesture: bool) []const u8 {
        var pb: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        w.writeAll(if (gesture) "{\"returnByValue\":true,\"awaitPromise\":true,\"userGesture\":true,\"expression\":" else "{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return "<arg>";
        std.json.Stringify.value(expr, .{}, &w) catch return "<arg>";
        w.writeAll("}") catch return "<arg>";
        const st = self.call(browser, "Runtime.evaluate", w.buffered(), 20_000) catch null;
        if (st == null or st.? != .ok) return std.fmt.bufPrint(out, "<{s}>", .{if (st) |s| @tagName(s) else "timeout"}) catch "<>";
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.result.items, .{}) catch return "<unparsed>";
        defer parsed.deinit();
        const res = parsed.value.object.get("result") orelse return "<noresult>";
        const v = res.object.get("value") orelse return "<novalue>";
        return switch (v) {
            .string => |s| std.fmt.bufPrint(out, "{s}", .{s[0..@min(s.len, out.len)]}) catch "<long>",
            .bool => |bv| if (bv) "true" else "false",
            .integer => |k| std.fmt.bufPrint(out, "{d}", .{k}) catch "<n>",
            .float => |f| std.fmt.bufPrint(out, "{d}", .{f}) catch "<n>",
            else => "<other>",
        };
    }

    /// 사람의 누름(maru 의 `mouse` — DIP).
    pub fn userClick(self: *Run, b: u64, x: i32, y: i32) void {
        self.host.send(.{ .mouse = .{ .browser = b, .kind = .move, .point = .{ .x = x, .y = y } } }) catch {};
        self.host.send(.{ .mouse = .{ .browser = b, .kind = .down, .point = .{ .x = x, .y = y }, .click_count = 1 } }) catch {};
        self.host.send(.{ .mouse = .{ .browser = b, .kind = .up, .point = .{ .x = x, .y = y }, .click_count = 1 } }) catch {};
        self.pump(250);
    }

    /// 에이전트의 누름(DevTools `Input.dispatchMouseEvent` — W9b 의 길).
    pub fn cdpClick(self: *Run, b: u64, x: f64, y: f64) void {
        var p: [256]u8 = undefined;
        _ = self.call(b, "Input.dispatchMouseEvent", std.fmt.bufPrint(&p, "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x, y }) catch return, 5000) catch {};
        _ = self.call(b, "Input.dispatchMouseEvent", std.fmt.bufPrint(&p, "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x, y }) catch return, 5000) catch {};
        self.pump(150);
    }

    /// 화면을 새로 그리게 한 뒤(링이 그 크기의 새 장을 받을 때까지) 잠깐 기다린다.
    pub fn settleFrames(self: *Run, b: u64) void {
        const before = self.views[b].frames;
        const deadline = os.nowMs() + 3000;
        while (os.nowMs() < deadline and self.views[b].frames < before + 2) {
            self.pollFrames();
            const m = (self.host.next(10) catch null) orelse continue;
            self.take(m);
        }
        self.pump(300);
    }

    pub fn renderers(self: *Run) u32 {
        var kids_buf: [64]c_int = undefined;
        var n: u32 = 0;
        for (os.children(self.host.pid, &kids_buf)) |kid| {
            if (os.argsContain(kid, "--type=renderer")) n += 1;
        }
        return n;
    }

    pub fn killRenderers(self: *Run) u32 {
        var kids_buf: [64]c_int = undefined;
        var killed: u32 = 0;
        for (os.children(self.host.pid, &kids_buf)) |kid| {
            if (os.argsContain(kid, "--type=renderer")) {
                _ = std.c.kill(kid, std.c.SIG.KILL);
                killed += 1;
            }
        }
        return killed;
    }

    fn deinit(self: *Run) void {
        for (&self.views) |*v| v.release();
        self.result.deinit(self.gpa);
        self.tr_gz.deinit(self.gpa);
        self.tr_frames.deinit(self.gpa);
        self.tr_frame_lens.deinit(self.gpa);
    }
};

pub fn uLoop(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

pub fn uLocal(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://localhost:{d}{s}", .{ port, path }) catch unreachable;
}

pub fn contains(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
}

fn jsonNum(s: []const u8, comptime key: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, s, "\"" ++ key ++ "\":") orelse return null;
    const start = at + key.len + 3;
    var end = start;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.' or s[end] == '-')) end += 1;
    return std.fmt.parseFloat(f64, s[start..end]) catch null;
}

/// 판정자 훅: sidecar 가 흉내의 CDP·위치·사이트 갈림을 stderr 에 적는다(판정 실패를 읽을 때). W9e②: trace 의 차례도.
const env_log: [*:0]const u8 = "MARU_WEB_TEST_EMU_LOG=1";
const env_trace_log: [*:0]const u8 = "MARU_WEB_TEST_TRACE_LOG=1";

pub const Session = struct {
    host: Host,
    receiver: Receiver,
    run: Run,

    pub fn deinit(self: *Session) void {
        self.run.deinit();
        stop(&self.host);
        self.receiver.close();
    }
};

pub fn open(sess: *Session, host_path: [:0]const u8, root: []const u8, name: []const u8) !void {
    var prof_buf: [1024]u8 = undefined;
    const profile = try std.fmt.bufPrintSentinel(&prof_buf, "--profile-dir={s}/{s}", .{ root, name }, 0);
    sess.receiver = try Receiver.open();
    errdefer sess.receiver.close();
    var log_buf: [1100]u8 = undefined;
    const log = std.fmt.bufPrintSentinel(&log_buf, "{s}/{s}.host.log", .{ root, name }, 0) catch null;
    sess.host = try Host.spawnWith(host_path, profile, log, &.{ env_log, env_trace_log });
    sess.receiver.expected_pid = sess.host.pid;
    try browsers_check.handshake(&sess.host);
    try sess.host.send(.{ .frame_channel = .{ .service = sess.receiver.serviceName(), .token = sess.receiver.token } });
    sess.run = .{ .host = &sess.host, .gpa = std.heap.c_allocator, .receiver = &sess.receiver };
}

fn stop(host: *Host) void {
    host.send(.shutdown) catch {};
    while (host.next(2000) catch null) |_| {}
    if (host.wait(20_000) == null) {
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(10_000);
    }
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    viewport(report, host_path, root) catch |err| report(false, "emu-viewport", @errorName(err));
    identity(report, host_path, root) catch |err| report(false, "emu-identity", @errorName(err));
    deadTab(report, host_path, root) catch |err| report(false, "emu-dead-tab-no-crash", @errorName(err));
    geolocation(report, host_path, root) catch |err| report(false, "emu-geo", @errorName(err));
    mixedPrompt(report, host_path, root) catch |err| report(false, "emu-geo-mixed-prompt", @errorName(err));
    siteBound(report, host_path, root) catch |err| report(false, "emu-site-bound", @errorName(err));
    siteBoundHistory(report, host_path, root) catch |err| report(false, "emu-site-bound-history", @errorName(err));
    popup(report, host_path, root) catch |err| report(false, "emu-popup-shared", @errorName(err));
    restart(report, host_path, root) catch |err| report(false, "emu-restart", @errorName(err));
}

const phone: msg.Emulation = .{ .browser = 0, .flags = .{ .viewport = true, .mobile = true }, .width = 390, .height = 844, .dsf = 3 };

// ── 화면 ────────────────────────────────────────────────────────────────────────────────────────────────

fn viewport(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emv");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [2000]u8 = undefined;
    var d: [900]u8 = undefined;
    var sb: [400]u8 = undefined;
    var segs: [64]Seg = undefined;
    try r.create(1, uLoop(&u, "/vp"));
    r.host.send(.{ .set_focus = .{ .browser = 1, .value = true } }) catch {};
    // 맞춤 — pane 640×400 DIP(@2 → 링 1280×800)에 390×844@3: fit 0.4739, 흉내 화면 전체(≈370×800 px)가 왼쪽 위에.
    {
        const st = try r.emulate(1, phone);
        r.settleFrames(1);
        const m = r.ev(1, "M()", &o);
        const row = r.views[1].row(40, &segs);
        const g = if (row.segs.len > 0) row.segs[0] else Seg{ .color = 0, .start = 0, .len = 0 };
        const y = findColor(row.segs, 0xffff00);
        const fit = if (st) |s| s.fit_scale else 0;
        const ok = st != null and fit == 0.4739 and st.?.active_mask & 1 != 0 and contains(m, "\"iw\":390") and contains(m, "\"dpr\":3") and g.color == 0x00ff00 and g.len >= 90 and g.len <= 100 and y != null and y.?.start + y.?.len >= 360 and y.?.start + y.?.len <= 375 and row.width == 1280;
        report(ok, "emu-viewport-fit", std.fmt.bufPrint(&d, "fit {d} 상태 0x{x} 페이지 {s} 링 {d}×{d} row@40 [{s}]", .{ fit, if (st) |s| s.active_mask else 0, m, row.width, row.height, segText(&sb, row.segs) }) catch "");
    }
    // 사용자 마우스(DIP)는 Chromium 이 scale 로 옮긴다 — (20,20) → #g, (160,365) → #b.
    {
        _ = r.ev(1, "E()", &o);
        r.userClick(1, 20, 20);
        r.userClick(1, 160, 365);
        const e = r.ev(1, "E()", &o);
        report(contains(e, ":g") and contains(e, ":b"), "emu-user-input-fit", std.fmt.bufPrint(&d, "사용자 누름 → {s}", .{e}) catch "");
    }
    // W9b 의 누름: CSS 가운데 × fit 이어야 #b(maru 가 곱한다 — `web_cdp_ops.input_scale`), 곱하지 않으면 다른 곳(E3).
    {
        const bpos = r.ev(1, "B()", &o);
        const bx = jsonNum(bpos, "x") orelse 340;
        const by = jsonNum(bpos, "y") orelse 794;
        _ = r.ev(1, "E()", &o);
        r.cdpClick(1, bx * 0.4739, by * 0.4739);
        var e1b: [400]u8 = undefined;
        const scaled = r.ev(1, "E()", &e1b);
        r.cdpClick(1, bx, by);
        var e2b: [400]u8 = undefined;
        const raw = r.ev(1, "E()", &e2b);
        report(contains(scaled, ":b") and !contains(raw, ":b"), "emu-w9b-click-scaled", std.fmt.bufPrint(&d, "#b 가운데 CSS ({d},{d}) × fit → {s}; 곱하지 않으면 → {s}", .{ bx, by, scaled, raw }) catch "");
    }
    // 스크린샷은 흉내 화면 전체 @흉내 배율(사용자 화면과 다르다 — E1).
    {
        const st = r.call(1, "Page.captureScreenshot", "{\"format\":\"png\"}", 15_000) catch null;
        const items = r.result.items;
        const key = "\"data\":\"";
        var w: u32 = 0;
        var h: u32 = 0;
        if (std.mem.indexOf(u8, items, key)) |at| {
            var raw: [24]u8 = undefined;
            if (items.len >= at + key.len + 32) if (std.base64.standard.Decoder.decode(&raw, items[at + key.len ..][0..32])) |_| {
                w = std.mem.readInt(u32, raw[16..20], .big);
                h = std.mem.readInt(u32, raw[20..24], .big);
            } else |_| {};
        }
        report(st != null and st.? == .ok and w == 1170 and h == 2532, "emu-screenshot-size", std.fmt.bufPrint(&d, "png {d}×{d}", .{ w, h }) catch "");
    }
    // pane 이 바뀌면 다시 셈한다(800×500 → fit 0.5924, 노랑의 끝 ≈ 462 px).
    {
        try r.host.send(.{ .resize = .{ .browser = 1, .size = .{ .width = 800, .height = 500, .scale = 2 } } });
        _ = r.until(struct {
            fn f(rr: *Run, b: u64, _: u32) bool {
                return if (rr.st[b]) |s| s.fit_scale == 0.5924 and !s.pending else false;
            }
        }.f, 1, 0, 5000);
        r.settleFrames(1);
        const row = r.views[1].row(40, &segs);
        const y = findColor(row.segs, 0xffff00);
        const fit = if (r.st[1]) |s| s.fit_scale else 0;
        const m = r.ev(1, "M()", &o);
        report(fit == 0.5924 and contains(m, "\"iw\":390") and y != null and y.?.start + y.?.len >= 452 and y.?.start + y.?.len <= 470, "emu-resize-refit", std.fmt.bufPrint(&d, "fit {d} 링 {d}×{d} row@40 [{s}] {s}", .{ fit, row.width, row.height, segText(&sb, row.segs), m }) catch "");
    }
    // pane 보다 작은 흉내(300×200 @1 — fit 1): 초록 200 px, 노랑의 끝 600 px.
    {
        const st = try r.emulate(1, .{ .browser = 0, .flags = .{ .viewport = true }, .width = 300, .height = 200, .dsf = 1 });
        r.settleFrames(1);
        const row = r.views[1].row(40, &segs);
        const y = findColor(row.segs, 0xffff00);
        const m = r.ev(1, "M()", &o);
        const g = if (row.segs.len > 0) row.segs[0] else Seg{ .color = 0, .start = 0, .len = 0 };
        report(st != null and st.?.fit_scale == 1 and contains(m, "\"iw\":300") and g.color == 0x00ff00 and g.len >= 196 and g.len <= 204 and y != null and y.?.start + y.?.len >= 596 and y.?.start + y.?.len <= 604, "emu-viewport-exact", std.fmt.bufPrint(&d, "fit {d} row@40 [{s}] {s}", .{ if (st) |s| s.fit_scale else 0, segText(&sb, row.segs), m }) catch "");
    }
    // 터치 — maxTouchPoints 5·pointer:coarse(곧바로 — E6).
    {
        var v = phone;
        v.flags.touch = true;
        _ = try r.emulate(1, v);
        const m = r.ev(1, "M()", &o);
        report(contains(m, "\"mtp\":5") and contains(m, "\"coarse\":true"), "emu-touch", m);
    }
    // 미디어 — forced-colors 가 걸리고, 지우면 풀린다(네 이름을 빈 값으로 — `{}` 는 풀지 않았다: E17). light·print 도.
    {
        var v = phone;
        v.flags.media = true;
        v.media = .{ .type = .print, .color_scheme = .light, .forced_colors = .active };
        _ = try r.emulate(1, v);
        var on_b: [400]u8 = undefined;
        const on = r.ev(1, "M()", &on_b);
        _ = try r.emulate(1, phone);
        const off = r.ev(1, "M()", &o);
        report(contains(on, "\"fc\":true") and contains(on, "\"light\":true") and contains(on, "\"print\":true") and contains(off, "\"fc\":false") and contains(off, "\"print\":false"), "emu-media-clear", std.fmt.bufPrint(&d, "걸림 {s} / 지움 {s}", .{ on, off }) catch "");
    }
    // 색각 — 사용자 화면(링)의 초록 상자가 회색이 된다(achromatopsia).
    {
        var v = phone;
        v.flags.vision = true;
        v.vision = .achromatopsia;
        _ = try r.emulate(1, v);
        r.settleFrames(1);
        const px = r.views[1].pixelAt(20, 20) orelse 0;
        const rr = (px >> 16) & 0xff;
        const gg = (px >> 8) & 0xff;
        const bb = px & 0xff;
        const grey = rr == gg and gg == bb;
        _ = try r.emulate(1, phone);
        r.settleFrames(1);
        const back = r.views[1].pixelAt(20, 20) orelse 0;
        report(grey and back == 0x00ff00, "emu-vision-visible", std.fmt.bufPrint(&d, "초록 상자 픽셀 {x:0>6} → 지우면 {x:0>6}", .{ px, back }) catch "");
    }
}

// ── 정체 ────────────────────────────────────────────────────────────────────────────────────────────────

const android_ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36";
const safari_ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

fn derivedAndroid() msg.Emulation {
    var v: msg.Emulation = .{ .browser = 0, .flags = .{ .ua = true, .hints = true }, .ua = android_ua, .platform = "Linux armv8l" };
    v.hints.brand_count = 2;
    v.hints.brands[0] = .{ .brand = "Chromium", .version = "154" };
    v.hints.brands[1] = .{ .brand = "Not A(Brand", .version = "99" };
    v.hints.platform = "Android";
    v.hints.mobile = true;
    return v;
}

fn identity(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emi");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [3000]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, uLoop(&u, "/pp?i0"));
    // UA + 추정한 client hints(maru 가 만든 것 — Chromium N·Not A(Brand 99·Android·모바일): 서버 머리와 userAgentData 가 맞는다.
    {
        _ = try r.emulate(1, derivedAndroid());
        try r.nav(1, uLoop(&u, "/pp?i1"));
        const rec = lastReq("/pp?i1");
        const p = r.ev(1, "JSON.stringify(P())", &o);
        const ok = rec != null and std.mem.eql(u8, rec.?.uaText(), android_ua) and contains(rec.?.chuaText(), "\"Chromium\";v=\"154\"") and std.mem.eql(u8, rec.?.platText(), "\"Android\"") and std.mem.eql(u8, rec.?.mobText(), "?1");
        report(ok, "emu-ua-headers", std.fmt.bufPrint(&d, "서버 ua=[{s}] sec-ch-ua=[{s}] platform=[{s}] mobile=[{s}]", .{ if (rec) |x| x.uaText() else "-", if (rec) |x| x.chuaText() else "-", if (rec) |x| x.platText() else "-", if (rec) |x| x.mobText() else "-" }) catch "");
        report(contains(p, "Chromium/154") and contains(p, "|m=true|p=Android") and contains(p, "\"plat\":\"Linux armv8l\""), "emu-ua-derived-hints", p);
    }
    // 진짜 Safari 꼴 — client hints 없음(none): Sec-CH-UA 가 아예 없고 userAgentData 의 브랜드는 빈 목록(E7).
    {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .ua = true }, .ua = safari_ua });
        try r.nav(1, uLoop(&u, "/pp?i2"));
        const rec = lastReq("/pp?i2");
        const p = r.ev(1, "JSON.stringify(P())", &o);
        report(rec != null and std.mem.eql(u8, rec.?.uaText(), safari_ua) and rec.?.chua_len == 0 and (contains(p, "\"uad\":\"|m=") or contains(p, "\"uad\":\"none\"")), "emu-ua-none-safari", std.fmt.bufPrint(&d, "서버 sec-ch-ua=[{s}] 페이지 {s}", .{ if (rec) |x| x.chuaText() else "-", p[0..@min(p.len, 400)] }) catch "");
    }
    // 언어만 — UA·client hints 는 그대로(빈 userAgent + acceptLanguage, E7), Accept-Language 와 navigator.language·Intl 이 fr.
    {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .locale = true }, .accept_language = "fr-FR,fr", .icu_locale = "fr_FR" });
        try r.nav(1, uLoop(&u, "/pp?i3"));
        const rec = lastReq("/pp?i3");
        const p = r.ev(1, "JSON.stringify(P())", &o);
        const ok = rec != null and contains(rec.?.uaText(), "Macintosh") and std.mem.startsWith(u8, rec.?.alText(), "fr-FR,fr") and rec.?.chua_len > 0 and contains(p, "\"lang\":\"fr-FR\"") and contains(p, "\"il\":\"fr-FR\"");
        report(ok, "emu-accept-language-only", std.fmt.bufPrint(&d, "서버 ua=[{s}] al=[{s}] sec-ch-ua=[{s}] 페이지 {s}", .{ if (rec) |x| x.uaText()[0..@min(x.ua_len, 60)] else "-", if (rec) |x| x.alText() else "-", if (rec) |x| x.chuaText() else "-", p[0..@min(p.len, 300)] }) catch "");
    }
    // 언어 + 시간대(Intl·Date).
    {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .locale = true, .timezone = true }, .accept_language = "fr-FR,fr", .icu_locale = "fr_FR", .timezone = "Asia/Kolkata" });
        const p = r.ev(1, "JSON.stringify(P())", &o);
        report((contains(p, "\"tz\":\"Asia/Kolkata\"") or contains(p, "\"tz\":\"Asia/Calcutta\"")) and contains(p, "\"off\":-330") and contains(p, "\"il\":\"fr-FR\""), "emu-locale-tz", p[0..@min(p.len, 400)]);
    }
    // 지속 — 같은 사이트·다른 사이트(렌더러가 바뀜)·새로고침·뒤로 뒤에도(E4).
    {
        var v = derivedAndroid();
        v.flags.timezone = true;
        v.timezone = "Asia/Kolkata";
        v.flags.viewport = true;
        v.flags.mobile = true;
        v.width = 390;
        v.height = 844;
        v.dsf = 3;
        _ = try r.emulate(1, v);
        var seen: [5][300]u8 = undefined;
        var texts: [5][]const u8 = undefined;
        try r.nav(1, uLoop(&u, "/vp?p1"));
        texts[0] = r.ev(1, "M()", &seen[0]);
        try r.nav(1, uLocal(&u, "/vp?p2"));
        texts[1] = r.ev(1, "M()", &seen[1]);
        try r.action(1, .reload);
        texts[2] = r.ev(1, "M()", &seen[2]);
        try r.action(1, .back);
        texts[3] = r.ev(1, "M()", &seen[3]);
        const rec = lastReq("/vp?p2");
        var all = rec != null and std.mem.eql(u8, rec.?.uaText(), android_ua);
        for (texts[0..4]) |t| all = all and contains(t, "\"iw\":390") and (contains(t, "Kolkata") or contains(t, "Calcutta"));
        report(all, "emu-persist", std.fmt.bufPrint(&d, "같은 사이트 {s} | 다른 사이트 {s} | 새로고침 {s} | 뒤로 {s}", .{ texts[0], texts[1], texts[2], texts[3] }) catch "");
    }
    // 첫 문서 — 지금 문서의 머리는 이미 갔다. 새로고침이면 문서 요청부터 새 UA(maru 의 `reload:true`).
    {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .ua = true }, .ua = "ReloadUA/1" });
        try r.action(1, .reload);
        const rec = lastReq("/vp?p1"); // 뒤로 간 문서(/vp?p1)의 새로고침
        report(rec != null and std.mem.eql(u8, rec.?.uaText(), "ReloadUA/1"), "emu-first-doc-reload", std.fmt.bufPrint(&d, "새로고침 요청 ua=[{s}]", .{if (rec) |x| x.uaText() else "-"}) catch "");
    }
    // 덮지 않는 것 — 다른 사이트 iframe 은 진짜 UA·시간대(결과의 not_covered 의 근거, E8).
    {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .ua = true, .timezone = true }, .ua = "CoveredUA/1", .timezone = "Asia/Kolkata" });
        try r.nav(1, uLoop(&u, "/pp?nc"));
        const all = r.ev(1, "ALL('nc')", &o);
        const oopif_at = std.mem.indexOf(u8, all, "\"oopif\"") orelse all.len;
        const main_part = all[0..oopif_at];
        const oopif_part = all[oopif_at..];
        report(contains(main_part, "CoveredUA/1") and !contains(oopif_part, "CoveredUA/1") and !contains(oopif_part, "Kolkata") and !contains(oopif_part, "Calcutta"), "emu-not-covered", all[0..@min(all.len, 700)]);
    }
    // 지킴 — maru 를 거친 DevTools 의 흉내·권한 메서드는 보내지 않는다(한 주인 — 죽은 탭의 metrics 가 sidecar 를 죽였다, E11·E15).
    {
        var bad: u32 = 0;
        var w: std.Io.Writer = .fixed(&d);
        for ([_][2][]const u8{
            .{ "Emulation.setDeviceMetricsOverride", "{\"width\":1,\"height\":1,\"deviceScaleFactor\":1,\"mobile\":false}" },
            .{ "Emulation.setTimezoneOverride", "{\"timezoneId\":\"UTC\"}" },
            .{ "Network.setUserAgentOverride", "{\"userAgent\":\"x\"}" },
            .{ "Browser.grantPermissions", "{\"permissions\":[\"geolocation\"]}" },
        }) |c| {
            const st = r.call(1, c[0], c[1], 5000) catch null;
            const refused = st != null and st.? == .invalid_request;
            if (!refused) bad += 1;
            w.print("{s}={s} ", .{ c[0], if (st) |s| @tagName(s) else "timeout" }) catch {};
        }
        report(bad == 0, "emu-guard", w.buffered());
    }
    // 비용 — 시간대를 20 번 바꿔도 다 자리 잡는 데 2 초 안(E20 — 호출 하나 0.1–0.5 ms).
    {
        const t0 = os.nowMs();
        for (0..20) |i| _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true }, .timezone = if (i % 2 == 0) "Asia/Tokyo" else "Europe/Paris" });
        const took = os.nowMs() - t0;
        report(took < 2000 + 20 * 150, "emu-cost", std.fmt.bufPrint(&d, "20 번 바꿈 {d} ms(판정자의 150 ms 기다림 포함)", .{took}) catch "");
    }
}

// ── 죽은 탭 ─────────────────────────────────────────────────────────────────────────────────────────────

fn deadTab(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emd");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [1500]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, uLoop(&u, "/vp?d0"));
    try r.create(2, uLoop(&u, "/vp?d1"));
    _ = try r.emulate(1, phone);
    const killed = r.killRenderers();
    _ = r.until(goneAtBoth, 1, 0, 8000);
    r.pump(800);
    // 렌더러가 없는 탭에 흉내 화면을 바꾼다 — sidecar 는 쌓아 두어야 한다(보내면 maru-web-host 가 SIGSEGV — E11 세 번).
    var v = phone;
    v.width = 412;
    v.height = 915;
    v.dsf = 2.625;
    r.gen[1] += 1;
    v.browser = 1;
    v.generation = r.gen[1];
    try r.host.send(.{ .emulation = v });
    _ = r.until(Run.genAt, 1, r.gen[1], 3000);
    r.pump(2000);
    const st_dead = r.st[1];
    const alive_after = os.alive(r.host.pid);
    try r.host.send(.{ .resize = .{ .browser = 1, .size = .{ .width = 700, .height = 420, .scale = 2 } } });
    r.pump(1500);
    const alive_resize = os.alive(r.host.pid);
    try r.action(1, .reload);
    _ = r.until(Run.settledAt, 1, r.gen[1], 5000);
    const m = r.ev(1, "M()", &o);
    const ok = killed > 0 and alive_after and alive_resize and st_dead != null and !st_dead.?.alive and st_dead.?.pending and contains(m, "\"iw\":412") and os.alive(r.host.pid);
    report(ok, "emu-dead-tab-no-crash", std.fmt.bufPrint(&d, "렌더러 {d} 죽임, 죽은 동안 상태 alive={} pending={}, host 생존 {}·resize 뒤 {}, 새로고침 뒤 {s}", .{ killed, if (st_dead) |s| s.alive else true, if (st_dead) |s| s.pending else false, alive_after, alive_resize, m }) catch "");
}

fn goneAtBoth(r: *Run, _: u64, _: u32) bool {
    return r.gone[1] >= 1 and r.gone[2] >= 1;
}

// ── 위치 ────────────────────────────────────────────────────────────────────────────────────────────────

fn geolocation(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emg");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [1500]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, uLoop(&u, "/pp?g1"));
    try r.create(2, uLoop(&u, "/pp?g2"));
    r.perm_mode = 1; // maru 에 오면 거절(사용자가 거절한 것처럼) — 에이전트 탭은 오지 않아야 한다
    var before_b: [64]u8 = undefined;
    const before = r.ev(1, "GP()", &before_b);
    const st = try r.emulate(1, .{ .browser = 0, .flags = .{ .geo = true }, .latitude = 48.8584, .longitude = 2.2945, .accuracy = 10 });
    const g1 = r.ev(1, "G()", &o);
    var after_b: [64]u8 = undefined;
    const after = r.ev(1, "GP()", &after_b);
    r.pump(300);
    var origin_b: [256]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_b, "http://127.0.0.1:{d}", .{port}) catch "";
    const recorded = r.auto_first_len[1] > 0 and std.mem.eql(u8, r.auto_first[1][0..r.auto_first_len[1]], origin);
    // 이동해도 에이전트 좌표(W5b2 의 새 문서 「없음」 되돌림이 걸지 않는다 — E14).
    try r.nav(1, uLoop(&u, "/pp?g3"));
    var g2b: [200]u8 = undefined;
    const g2 = r.ev(1, "G()", &g2b);
    const ok1 = st != null and st.?.active_mask & (1 << 4) != 0 and std.mem.startsWith(u8, g1, "ok 48.8584,2.2945 acc=10") and std.mem.startsWith(u8, g2, "ok 48.8584,2.2945") and r.prompts[1] == 0 and recorded;
    // 숨은 탭(에이전트가 연 탭은 숨은 채 열린다) — Chromium 은 보이지 않는 페이지의 위치 요청을(프롬프트까지) 보일 때까지 붙잡는다(관측).
    {
        try r.nav(1, uLoop(&u, "/pp?g4"));
        r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } }) catch {};
        r.pump(300);
        var hb: [200]u8 = undefined;
        _ = r.ev(1, "window.HG='pending';G().then(function(x){window.HG=x});'started'", &hb);
        r.pump(2500);
        var h1b: [200]u8 = undefined;
        const held = r.ev(1, "window.HG", &h1b);
        const held_prompts = r.prompts[1];
        r.host.send(.{ .set_hidden = .{ .browser = 1, .value = false } }) catch {};
        r.pump(1500);
        var h2b: [200]u8 = undefined;
        const shown = r.ev(1, "window.HG", &h2b);
        report(std.mem.eql(u8, held, "pending") and std.mem.startsWith(u8, shown, "ok 48.8584,2.2945") and r.prompts[1] == 0, "emu-geo-hidden-held(obs)", std.fmt.bufPrint(&d, "숨긴 동안 2.5 초 {s}(프롬프트 {d}), 보이자 {s}(프롬프트 {d})", .{ held, held_prompts, shown, r.prompts[1] }) catch "");
    }
    // 같은 출처의 다른 탭 — 에이전트 좌표를 받지 않고 maru 에 묻는다(답하지 않는다 — 거절하면 Chromium 이 그 출처에 거절을 저장해 뒤의 되돌림
    // 확인이 흐려진다; 그 탭은 시한으로 끝난다).
    var ob: [64]u8 = undefined;
    const other_state = r.ev(2, "GP()", &ob);
    r.perm_mode = 2;
    var g3b: [200]u8 = undefined;
    const g3 = r.ev(2, "G()", &g3b);
    r.perm_mode = 1;
    report(r.prompts[2] >= 1 and !contains(g3, "48.8584"), "emu-geo-no-context-grant", std.fmt.bufPrint(&d, "다른 탭: permissions.query={s}(관측 — 저장된 허용), 위치 요청 → maru 프롬프트 {d} 번, 결과 {s}", .{ other_state, r.prompts[2], g3 }) catch "");
    // 끝 — 흉내를 지우면 대신 허용한 출처를 기본으로 되돌린다(다른 탭의 prompt 는 관측 — Chromium 154 는 대신 허용 동안에도 prompt 였다).
    _ = try r.emulate(1, .{ .browser = 0 });
    r.pump(400);
    var endb: [64]u8 = undefined;
    const end_state = r.ev(2, "GP()", &endb);
    const restored = std.mem.eql(u8, end_state, "prompt") and r.auto_first_len[1] == 0;
    report(ok1 and restored, "emu-geo-agent", std.fmt.bufPrint(&d, "전 {s} → 에이전트 좌표 {s}(프롬프트 {d}, 저장 {s}), 대신 허용 출처 적힘 {}, 이동 뒤 {s}, 지운 뒤 다른 탭 {s}", .{ before, g1, r.prompts[1], after, recorded, g2, end_state }) catch "");
}

// ── 섞인 프롬프트(J5) ───────────────────────────────────────────────────────────────────────────────────

/// 에이전트 좌표가 걸린 탭에서 위치와 다른 권한을 한꺼번에 청한다(맨 위 문서는 사용자 누름 안에서, iframe 은 같은·다른 출처). 판정자는 maru
/// 역할로 오는 프롬프트를 모두 거절한다 — 묻지 않고 허용하는 막(`geo_slot.promptAutoAllowable`)이 위치가 섞인 프롬프트까지 열면 섞인 권한이
/// 「granted」 가 된다. 받은 프롬프트의 종류를 그대로 적는다(Chromium 이 위치를 다른 권한과 묶는지).
fn mixedPrompt(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emx");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [3000]u8 = undefined;
    try r.create(1, uLoop(&u, "/mx"));
    r.pump(500);
    r.perm_mode = 1; // maru 에 오면 거절(사용자가 거절한 것처럼)
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .geo = true }, .latitude = 48.8584, .longitude = 2.2945, .accuracy = 10 });
    // 먼저 맨 위와 두 iframe 이 한꺼번에(아직 아무 권한도 저장되지 않았을 때 — 묶일 기회가 가장 크다), 그다음 맨 위 혼자 다시.
    var ab: [1800]u8 = undefined;
    const all = r.evWith(1, "MX()", &ab, true);
    r.pump(300);
    var mb: [1200]u8 = undefined;
    const main_only = r.evWith(1, "MAIN()", &mb, true);
    r.pump(500);
    const geo = msg.PermissionKind.geolocation.bit();
    var geo_only: u32 = 0;
    var mixed: u32 = 0;
    var kb: [600]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kb);
    for (r.seen_kinds[0..r.seen_n], r.seen_media[0..r.seen_n]) |k, m| {
        if (k == geo) geo_only += 1;
        if (k & geo != 0 and k != geo) mixed += 1;
        kw.print(" k=0x{x}/m=0x{x}", .{ k, m }) catch {};
    }
    const main_geo_ok = std.mem.startsWith(u8, main_only, "[\"ok 48.8584,2.2945");
    const none_granted = !contains(main_only, "granted") and !contains(all, "granted") and main_only.len > 2 and all.len > 2 and main_only[0] != '<' and all[0] != '<';
    const ok = none_granted and geo_only == 0 and (main_geo_ok or mixed > 0);
    report(ok, "emu-geo-mixed-prompt", std.fmt.bufPrint(&d, "maru 프롬프트 {d} 개(위치만 {d}·위치가 섞인 것 {d}):{s} | 맨 위·iframe 한꺼번에 {s} | 다시 맨 위 {s}", .{ r.seen_n, geo_only, mixed, kw.buffered(), all[0..@min(all.len, 900)], main_only[0..@min(main_only.len, 400)] }) catch "");
    // 적을 수 없는 출처(255 B 를 넘는 `*.localhost` 호스트 — 되돌릴 표에 적지 못해 묻지 않고 허용하지 않는다)의 위치만의 프롬프트는 maru 에
    // 온다 — 사용자가 허용해 maru 가 제 좌표를 보내도 에이전트 좌표를 덮지 않는다(실측 E14 의 막이 maru 의 답 길에도 — 판정자 변이 J2).
    {
        const label = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 60 글자 라벨 넷 + localhost = 호스트 253 B
        var hb: [400]u8 = undefined;
        const long_url = std.fmt.bufPrint(&hb, "http://{s}.{s}.{s}.{s}.localhost:{d}/pp?long", .{ label, label, label, label, port }) catch unreachable;
        try r.nav(1, long_url);
        r.perm_mode = 3;
        const before = r.prompts[1];
        var gb: [200]u8 = undefined;
        const g = r.ev(1, "G()", &gb);
        r.pump(200);
        r.perm_mode = 1;
        report(r.prompts[1] > before and std.mem.startsWith(u8, g, "ok 48.8584,2.2945"), "emu-geo-maru-answer-keeps-agent", std.fmt.bufPrint(&d, "긴 출처(주소 {d} B)의 위치 요청 → maru 프롬프트 {d} 번(maru 가 1.5,2.5 를 보내고 허용), 페이지 {s}", .{ long_url.len, r.prompts[1] - before, g }) catch "");
    }
}

// ── 사이트 묶기 ─────────────────────────────────────────────────────────────────────────────────────────

fn siteBound(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "ems");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1800]u8 = undefined;
    try r.create(1, uLoop(&u, "/pp?s0"));
    const st0 = try r.emulate(1, .{ .browser = 0, .flags = .{ .site_bound = true, .ua = true, .timezone = true }, .site = "127.0.0.1", .ua = "BoundUA/1", .timezone = "Asia/Tokyo" });
    try r.nav(1, uLoop(&u, "/pp?s1"));
    const in1 = lastReq("/pp?s1");
    var p1b: [600]u8 = undefined;
    const p1 = r.ev(1, "JSON.stringify(P())", &p1b);
    try r.nav(1, uLocal(&u, "/pp?s2"));
    const out2 = lastReq("/pp?s2");
    var p2b: [600]u8 = undefined;
    const p2 = r.ev(1, "JSON.stringify(P())", &p2b);
    const off_state = r.st[1];
    try r.nav(1, uLoop(&u, "/pp?s3"));
    const in3 = lastReq("/pp?s3");
    var p3b: [600]u8 = undefined;
    const p3 = r.ev(1, "JSON.stringify(P())", &p3b);
    const on_state = r.st[1];
    const ok = st0 != null and st0.?.on_site and in1 != null and std.mem.eql(u8, in1.?.uaText(), "BoundUA/1") and contains(p1, "Asia/Tokyo") and
        out2 != null and !contains(out2.?.uaText(), "BoundUA") and !contains(p2, "Asia/Tokyo") and off_state != null and !off_state.?.on_site and off_state.?.active_mask == 0 and
        in3 != null and std.mem.eql(u8, in3.?.uaText(), "BoundUA/1") and contains(p3, "Asia/Tokyo") and on_state != null and on_state.?.on_site;
    report(ok, "emu-site-bound", std.fmt.bufPrint(&d, "안 ua=[{s}] {s} | 밖 ua=[{s}] on_site={} active=0x{x} {s} | 돌아옴 ua=[{s}] on_site={}", .{ if (in1) |x| x.uaText() else "-", p1[0..@min(p1.len, 160)], if (out2) |x| x.uaText()[0..@min(x.ua_len, 40)] else "-", if (off_state) |s| s.on_site else true, if (off_state) |s| s.active_mask else 0, p2[0..@min(p2.len, 160)], if (in3) |x| x.uaText() else "-", if (on_state) |s| s.on_site else false }) catch "");
    // 리다이렉트로 떠나는 홉 — 그 홉 요청은 흉내를 싣고 간다(한 요청 늦음 — E12, 문서화). 이 꼴이 바뀌면 문서를 고친다.
    try r.nav(1, uLoop(&u, "/r2"));
    const hop = firstReqOn("/pp?via=r2", "localhost");
    var p4b: [600]u8 = undefined;
    const p4 = r.ev(1, "JSON.stringify(P())", &p4b);
    report(hop != null and !contains(p4, "Asia/Tokyo"), "emu-site-bound-redirect-lag(obs)", std.fmt.bufPrint(&d, "다른 사이트로 나간 302 의 다음 요청 ua=[{s}](E12 — 흉내면 한 요청 늦음), 도착한 문서 {s}", .{ if (hop) |x| x.uaText()[0..@min(x.ua_len, 60)] else "-", p4[0..@min(p4.len, 160)] }) catch "");
    // 끊긴 홉(204 — ERR_ABORTED, 옛 문서가 남는다). (가) 밖의 문서(localhost)에서 묶인 사이트로 가는 204: `on_before_browse` 가 사이트 안으로 보고 걸었던
    // 흉내를 끊김이 거둬야 한다 — 남으면 사용자가 허락하지 않은 사이트의 문서가 흉내를 본다. (나) 묶인 사이트의 문서에서 밖으로 가는 204: 풀었던 흉내를
    // 끊김이 되걸어야 한다.
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/nc?a") } });
    r.pump(1500);
    const nca = lastReq("/nc?a");
    var p5b: [600]u8 = undefined;
    const p5 = r.ev(1, "JSON.stringify([location.host, P()])", &p5b);
    const st5 = r.st[1];
    try r.nav(1, uLoop(&u, "/pp?s6"));
    var p6b: [600]u8 = undefined;
    const p6 = r.ev(1, "JSON.stringify(P())", &p6b);
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLocal(&u, "/nc?b") } });
    r.pump(1500);
    const ncb = lastReq("/nc?b");
    var p7b: [600]u8 = undefined;
    const p7 = r.ev(1, "JSON.stringify([location.host, P()])", &p7b);
    const st7 = r.st[1];
    const ok_a = nca != null and contains(p5, "localhost") and !contains(p5, "Asia/Tokyo") and st5 != null and !st5.?.on_site;
    const ok_b = contains(p6, "Asia/Tokyo") and ncb != null and contains(p7, "127.0.0.1") and contains(p7, "Asia/Tokyo") and st7 != null and st7.?.on_site;
    report(ok_a and ok_b, "emu-site-bound-aborted-hop", std.fmt.bufPrint(&d, "밖→안 204 서버={} {s} on_site={} | 안 {s} | 안→밖 204 서버={} {s} on_site={}", .{ nca != null, p5[0..@min(p5.len, 200)], if (st5) |x| x.on_site else true, p6[0..@min(p6.len, 120)], ncb != null, p7[0..@min(p7.len, 200)], if (st7) |x| x.on_site else false }) catch "");
}

/// 사이트 묶기의 넘나듦 판정에 거는 흉내 — 옛 문서에 닿으면 `SG()` 가 이름으로 알린다.
const bound_all: msg.Emulation = .{ .browser = 0, .flags = .{ .site_bound = true, .viewport = true, .touch = true, .ua = true, .locale = true, .timezone = true, .media = true }, .site = "127.0.0.1", .width = 390, .height = 844, .dsf = 3, .ua = "BoundUA/1", .accept_language = "fr-FR,fr", .icu_locale = "fr_FR", .timezone = "Asia/Tokyo", .media = .{ .type = .print, .forced_colors = .active } };

/// 서버가 받은 요청 중 그 글로 시작하고 그 호스트에서 온 것 — 수, 흉내를 본(`e=` 가 `-` 가 아닌)·흉내 머리(UA·Accept-Language)를 실은 수, 처음 몇 개.
const Leaks = struct { total: u32 = 0, seen: u32 = 0, header: u32 = 0, buf: [700]u8 = undefined, len: usize = 0 };

fn leaksOn(prefix: []const u8, host_prefix: []const u8, out: *Leaks) void {
    out.* = .{};
    var w: std.Io.Writer = .fixed(&out.buf);
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    for (srv_recs.items) |rec| {
        const t = rec.targetText();
        if (!std.mem.startsWith(u8, t, prefix) or !std.mem.startsWith(u8, rec.host[0..rec.host_len], host_prefix)) continue;
        out.total += 1;
        const seen = if (std.mem.indexOf(u8, t, "e=")) |at| !std.mem.startsWith(u8, t[at + 2 ..], "-") else false;
        const header = contains(rec.uaText(), "BoundUA") or std.mem.startsWith(u8, rec.alText(), "fr");
        if (seen) out.seen += 1;
        if (header) out.header += 1;
        if ((seen or header) and out.seen + out.header <= 6) w.print("{s} ua=[{s}] al=[{s}]; ", .{ t[0..@min(t.len, 60)], rec.uaText()[0..@min(rec.ua_len, 12)], rec.alText()[0..@min(rec.al_len, 12)] }) catch {};
    }
    out.len = w.buffered().len;
}

/// 이동을 보내고(사람의 뒤로·앞으로 또는 페이지 스크립트) 문서가 서거나(새로 불러옴) 잠깐 지나기를(bfcache 복원 — 불러옴이 없을 수 있다) 기다린다.
fn settleNav(r: *Run, b: u64) void {
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(700);
}

/// 사이트 묶기의 넘나듦(사용자 결정 Q1 의 빈틈 둘 — 옮긴 판 20 회 검증 2026-11-12).
/// emu-site-bound-bfcache: 뒤로·앞으로로 돌아간 사이트 밖 문서(127.0.0.1 묶음, localhost 문서)가 첫 스크립트·pageshow 에서 흉내를 보지 않고 그
/// 문서의 요청이 흉내 머리를 싣지 않는다 — bfcache 복원은 `on_before_browse` 를 지나지 않아 흉내가 남은 채 pageshow 가 돌았다(그래서 maru 의 Chromium
/// 은 bfcache 를 끈다 — 사용자 결정 2026-11-12; 복원되면 보고에 `P` 가 보인다).
/// emu-site-bound-slow-hop: 사이트 밖 문서가 묶인 사이트의 느린 주소로 가는 이동을 기다리는 동안(3.5 초) 옛 문서가 화면·배율·시간대·UA·언어·터치·
/// 미디어 흉내를 보지 않고 그 요청도 흉내 머리를 싣지 않으며 상태는 사이트 밖이다; 새 문서의 문서 요청부터 흉내 UA, 새 문서는 모두 흉내(첫 스크립트가 본
/// 것은 관측으로 적는다).
fn siteBoundHistory(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emh");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [4096]u8 = undefined;
    var js: [400]u8 = undefined;
    const ps_js = "JSON.stringify([location.host,T0,PS,SG()])";
    // (가) 뒤로: 밖 a → 안 b → (사람의) 뒤로 a.  (나) 앞으로: 안 b → 밖 c → 뒤로 b → (페이지의) 앞으로 c.
    try r.create(1, uLocal(&u, "/bf?a"));
    const st0 = try r.emulate(1, bound_all);
    try r.nav(1, uLoop(&u, "/bf?b"));
    var b1: [400]u8 = undefined;
    const on_b = r.ev(1, ps_js, &b1);
    try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .back } });
    settleNav(r, 1);
    var b2: [400]u8 = undefined;
    const back_a = r.ev(1, ps_js, &b2);
    try r.nav(1, uLoop(&u, "/bf?b2"));
    try r.nav(1, uLocal(&u, "/bf?c"));
    try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .back } });
    settleNav(r, 1);
    var b3: [400]u8 = undefined;
    const back_b = r.ev(1, ps_js, &b3);
    _ = r.ev(1, "setTimeout(function(){history.forward()},0);1", &js);
    settleNav(r, 1);
    var b4: [400]u8 = undefined;
    const fwd_c = r.ev(1, ps_js, &b4);
    const st4 = r.st[1];
    var la: Leaks = undefined;
    leaksOn("/sub?bf=a", "localhost", &la);
    var lc: Leaks = undefined;
    leaksOn("/sub?bf=c", "localhost", &lc);
    // 밖 문서(a·c)가 본 것: T0·pageshow·지금 모두 `-`.
    const clean_a = contains(back_a, "localhost") and !leakText(back_a);
    const clean_c = contains(fwd_c, "localhost") and !leakText(fwd_c);
    const req_ok = la.total >= 2 and lc.total >= 2 and la.seen == 0 and la.header == 0 and lc.seen == 0 and lc.header == 0;
    const in_ok = contains(on_b, "127.0.0.1") and contains(on_b, "tz.") and contains(back_b, "127.0.0.1");
    report(st0 != null and in_ok and clean_a and clean_c and req_ok and st4 != null and !st4.?.on_site, "emu-site-bound-bfcache", std.fmt.bufPrint(&d, "안 {s} | 뒤로(사람) 밖 {s} | 안 {s} | 앞으로(페이지) 밖 {s} on_site={} | pageshow 요청 a {d}개(흉내 {d}·머리 {d}) c {d}개(흉내 {d}·머리 {d}) {s}{s}", .{ on_b[0..@min(on_b.len, 120)], back_a, back_b[0..@min(back_b.len, 120)], fwd_c, if (st4) |x| x.on_site else true, la.total, la.seen, la.header, lc.total, lc.seen, lc.header, la.buf[0..la.len], lc.buf[0..lc.len] }) catch "");

    // 느린 이동: 밖 문서(localhost /ob)가 묶인 사이트의 /slow?ms=3500 으로(페이지 스크립트 — 밖의 페이지가 기다림을 늘릴 수 있다). 기다리는 동안
    // 옛 문서가 iframe 셋(같은 사이트·다른 사이트·form 대상)과 Worker 를 만든다 — 그 요청들은 진짜 UA·Accept-Language 여야 한다.
    try r.create(2, uLocal(&u, "/ob?w"));
    _ = try r.emulate(2, bound_all);
    r.pump(400);
    var g0: [64]u8 = undefined;
    const t0_old = r.ev(2, "T0", &g0);
    const go = std.fmt.bufPrint(&js, "GO('http://127.0.0.1:{d}/slow?ms=3500&w',1)", .{port}) catch unreachable;
    var g1: [64]u8 = undefined;
    _ = r.ev(2, go, &g1);
    r.pump(1500);
    const st_mid = r.st[2];
    r.pump(1000);
    const st_mid2 = r.st[2];
    _ = r.until(Run.loadsAt, 2, r.loads[2] + 1, 8000);
    r.pump(600);
    var lo: Leaks = undefined;
    leaksOn("/obs?", "localhost", &lo);
    var kid: Kids = undefined;
    kidsOf(&kid);
    const doc = firstReqOn("/slow?ms=3500&w", "127.0.0.1");
    const aft = firstReqOn("/aft?ms=3500&w", "127.0.0.1");
    const aft2 = laterReq(r, 2, "/aft2?w");
    var g2: [700]u8 = undefined;
    const new_doc = r.ev(2, "JSON.stringify([location.host,'T0='+T0,SG(),P().tz,innerWidth])", &g2);
    const st_end = r.st[2];
    // 기다리는 동안 상태는 밖이고 답을 기다리지 않는다(옮긴 판 검증 L1 — 전에는 홉에서 건 UA 의 답이 커밋 뒤에 와 내내 pending).
    const mid_off = st_mid != null and !st_mid.?.on_site and !st_mid.?.pending and st_mid.?.active_mask == 0 and st_mid2 != null and !st_mid2.?.on_site and !st_mid2.?.pending;
    const old_ok = std.mem.eql(u8, t0_old, "-") and lo.total >= 20 and lo.seen == 0 and lo.header == 0;
    const kids_ok = kid.docs == 4 and kid.dirty == 0 and kid.inner >= 3 and kid.inner_dirty == 0;
    // 그 홉의 문서 요청 하나는 흉내 UA(넣었다), 커밋 뒤 요청과 같은 꼴(UA·client hints 셋 — metadata 없는 UA 면 client hints 없음). Accept-Language 는
    // 넣어도 CEF 154 가 진짜로 되돌린다(실측 — 그 요청 하나 늦음, 적기만 한다).
    const doc_ok = doc != null and aft2 != null and std.mem.eql(u8, doc.?.uaText(), "BoundUA/1") and sameHeaders(&doc.?, &aft2.?, false);
    const t0_all = "T0=tz.il.ua.lang.iw.dpr.mtp.print.fc";
    const new_ok = contains(new_doc, "127.0.0.1") and contains(new_doc, t0_all) and contains(new_doc, "Asia/Tokyo") and contains(new_doc, ",390]") and st_end != null and st_end.?.on_site;
    var hb: [2][400]u8 = undefined;
    var hb3: [400]u8 = undefined;
    report(old_ok and mid_off and kids_ok and doc_ok and new_ok, "emu-site-bound-slow-hop", std.fmt.bufPrint(&d, "옛 문서 T0={s} · 기다리는 동안 관찰 {d}개(흉내 {d}·흉내 머리 {d}) {s}· 상태 1.5 초 on_site={} pending={} active=0x{x} 2.5 초 on_site={} | 옛 문서가 만든 요청 문서 {d}개(흉내 머리 {d}) 안의 fetch {d}개(흉내 {d}) {s}| 새 문서 요청 {s} · 커밋 뒤 {s} · 첫 스크립트의 요청 {s} {s} | 새 문서 {s} on_site={}", .{ t0_old, lo.total, lo.seen, lo.header, lo.buf[0..lo.len], if (st_mid) |x| x.on_site else true, if (st_mid) |x| x.pending else true, if (st_mid) |x| x.active_mask else 0, if (st_mid2) |x| x.on_site else true, kid.docs, kid.dirty, kid.inner, kid.inner_dirty, kid.buf[0..kid.len], headerText(&hb[0], doc), headerText(&hb[1], aft2), if (aft) |x| x.targetText() else "-", headerText(&hb3, aft), new_doc[0..@min(new_doc.len, 200)], if (st_end) |x| x.on_site else false }) catch "");
    // 다음 탭이 이 탭의 렌더러를 나누지 않게(같은 사이트 — locale·시간대는 프로세스에 하나다: E13).
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(500);

    // client hints 를 가진 흉내 — 밖 → 안(302) → 밖: 묶인 사이트 홉의 요청은 흉내 머리(client hints 셋까지), 밖으로 가는 다음 홉은 진짜(넣은 머리가
    // 리다이렉트를 넘어 남지 않는다). 그 뒤 같은 탭에서 밖 → 안(느림): 문서 요청의 머리가 커밋 뒤 요청과 같다.
    var hv = derivedAndroid();
    hv.flags.site_bound = true;
    hv.site = "127.0.0.1";
    hv.flags.locale = true;
    hv.accept_language = "de-DE,de,en";
    hv.icu_locale = "de_DE";
    try r.create(3, uLocal(&u, "/ob?h"));
    _ = try r.emulate(3, hv);
    r.pump(300);
    const base = lastReq("/obs?");
    _ = r.ev(3, std.fmt.bufPrint(&js, "GO('http://127.0.0.1:{d}/r3?h')", .{port}) catch unreachable, &g1);
    _ = r.until(Run.loadsAt, 3, r.loads[3] + 1, 6000);
    r.pump(400);
    const r3 = firstReqOn("/r3?h", "127.0.0.1");
    const via = firstReqOn("/pp?via=r3", "localhost");
    const st_via = r.st[3];
    try r.nav(3, uLocal(&u, "/ob?h2"));
    r.pump(300);
    _ = r.ev(3, std.fmt.bufPrint(&js, "GO('http://127.0.0.1:{d}/slow?ms=1500&h')", .{port}) catch unreachable, &g1);
    _ = r.until(Run.loadsAt, 3, r.loads[3] + 1, 6000);
    r.pump(600);
    const hdoc = firstReqOn("/slow?ms=1500&h", "127.0.0.1");
    const haft_first = firstReqOn("/aft?ms=1500&h", "127.0.0.1");
    const haft = laterReq(r, 3, "/aft2?h");
    const want_chua = "\"Chromium\";v=\"154\", \"Not A(Brand\";v=\"99\"";
    const r3_ok = r3 != null and std.mem.eql(u8, r3.?.uaText(), android_ua) and std.mem.eql(u8, r3.?.chuaText(), want_chua) and
        std.mem.eql(u8, r3.?.mobText(), "?1") and std.mem.eql(u8, r3.?.platText(), "\"Android\"");
    const via_ok = via != null and base != null and std.mem.eql(u8, via.?.uaText(), base.?.uaText()) and std.mem.eql(u8, via.?.alText(), base.?.alText()) and sameHeaders(&via.?, &base.?, true) and st_via != null and !st_via.?.on_site;
    const hdoc_ok = hdoc != null and haft != null and std.mem.eql(u8, hdoc.?.uaText(), android_ua) and std.mem.eql(u8, hdoc.?.chuaText(), want_chua) and sameHeaders(&hdoc.?, &haft.?, false);
    var hb2: [4][400]u8 = undefined;
    report(r3_ok and via_ok and hdoc_ok, "emu-site-bound-hop-headers", std.fmt.bufPrint(&d, "안 302 홉 {s} | 밖 다음 홉 {s} (진짜 {s}) on_site={} | 느린 홉 문서 {s} · 커밋 뒤 {s} · 첫 스크립트의 요청 {s} {s}", .{ headerText(&hb2[0], r3), headerText(&hb2[1], via), headerText(&hb2[2], base), if (st_via) |x| x.on_site else true, headerText(&hb2[3], hdoc), headerText(&hb[0], haft), if (haft_first) |x| x.targetText() else "-", headerText(&hb3, haft_first) }) catch "");

    // 밖 → 묶인 사이트의 닫힌 포트(연결 거부 — 오류 페이지, `on_load_start` 없음): 오류 페이지(실패한 주소 — 묶인 사이트)가 커밋된 문서로 기다림을
    // 끝낸다(옮긴 판 검증 L2 — 안 그러면 다음 이동까지 상태가 밖·hold 로 남았다; 실측: 이 오류에서 Chromium 이 2.5 초 안에 스스로 다시 불러 오지 않았다).
    // 그 뒤 밖으로 가는 이동의 문서 요청은 진짜.
    const closed = closedPort();
    try r.create(4, uLocal(&u, "/ob?e"));
    _ = try r.emulate(4, bound_all);
    r.pump(300);
    _ = r.ev(4, std.fmt.bufPrint(&js, "GO('http://127.0.0.1:{d}/err?e')", .{closed}) catch unreachable, &g1);
    r.pump(2500);
    const st_err = r.st[4];
    try r.nav(4, uLocal(&u, "/ob?e2"));
    r.pump(300);
    const e2 = firstReqOn("/ob?e2", "localhost");
    var g3: [200]u8 = undefined;
    const after_err = r.ev(4, "JSON.stringify([location.host,T0,SG()])", &g3);
    const err_ok = st_err != null and st_err.?.on_site and !st_err.?.pending and e2 != null and !contains(e2.?.uaText(), "BoundUA") and !std.mem.startsWith(u8, e2.?.alText(), "fr") and contains(after_err, "localhost") and !leakText(after_err);
    report(err_ok, "emu-site-bound-error-page", std.fmt.bufPrint(&d, "오류 페이지 2.5 초 on_site={} pending={} active=0x{x} | 밖 이동 문서 {s} 문서 {s}", .{ if (st_err) |x| x.on_site else false, if (st_err) |x| x.pending else true, if (st_err) |x| x.active_mask else 0, headerText(&hb[0], e2), after_err }) catch "");

    // 데워진 렌더러(사용자 결정 2026-11-12 「받아들이고 문서에 적기」): 밖의 문서가 묶인 사이트의 iframe 을 품으면(그 사이트의 렌더러가 이 탭에 떠 있다)
    // 밖→안 이동의 새 문서가 그 렌더러로 가고, 첫 스크립트가 커밋 뒤에야 닿는 흉내보다 먼저(~3 ms) 돈다 — Chromium 이 이동 동안 탭의 DevTools 세션을 붙잡아
    // 렌더러 쪽 명령이 커밋 뒤에 간다. 첫 스크립트가 본 것은 관측으로 적고(obs), 동의에 닿는 것만 단언한다: 기다리는 동안 옛 문서·그 문서가 만든 iframe·form·
    // Worker 의 요청은 진짜, 새 문서는 커밋 뒤 1 초 안에 모든 흉내, 그 뒤 새로고침(`reload:true` 의 길)은 첫 스크립트부터 모든 흉내.
    // 앞 탭들은 닫는다 — 같은 사이트 렌더러를 나누면 언어가 process_shared 로 실패했다(탭 3 의 de_DE).
    try r.host.send(.{ .destroy_browser = 3 });
    try r.host.send(.{ .destroy_browser = 4 });
    r.pump(800);
    try r.create(5, uLocal(&u, "/obf?f"));
    _ = try r.emulate(5, bound_all);
    r.pump(400);
    var kid0: Kids = undefined;
    kidsOf(&kid0);
    var lo0: Leaks = undefined;
    leaksOn("/obs?", "localhost", &lo0);
    var g4: [64]u8 = undefined;
    const t0_obf = r.ev(5, "T0", &g4);
    _ = r.ev(5, std.fmt.bufPrint(&js, "GO('http://127.0.0.1:{d}/slowr?ms=1500&f',1)", .{port}) catch unreachable, &g1);
    r.pump(1100);
    const st_wait = r.st[5];
    _ = r.until(Run.loadsAt, 5, r.loads[5] + 1, 8000);
    r.pump(800);
    var lo5: Leaks = undefined;
    leaksOn("/obs?", "localhost", &lo5);
    var kid5: Kids = undefined;
    kidsOf(&kid5);
    const fdoc = firstReqOn("/slowr?ms=1500&f", "127.0.0.1");
    const faft = firstReqOn("/aft?ms=1500&f", "127.0.0.1");
    var g5: [300]u8 = undefined;
    const fnew = r.ev(5, "JSON.stringify([location.host,'T0='+T0,'FULL='+FULL,SG()])", &g5);
    const st_f = r.st[5];
    const rend = r.renderers();
    try r.action(5, .reload);
    r.pump(300);
    var g6: [300]u8 = undefined;
    const freload = r.ev(5, "JSON.stringify([location.host,'T0='+T0,'FULL='+FULL])", &g6);
    const old_clean = std.mem.eql(u8, t0_obf, "-") and lo5.total >= lo0.total + 8 and lo5.seen == lo0.seen and lo5.header == lo0.header and
        st_wait != null and !st_wait.?.on_site and st_wait.?.active_mask == 0;
    const kids_clean = kid5.docs == kid0.docs + 4 and kid5.dirty == kid0.dirty and kid5.inner >= kid0.inner + 3 and kid5.inner_dirty == kid0.inner_dirty;
    const full_ms: i64 = if (std.mem.indexOf(u8, fnew, "FULL=")) |at| blk: {
        var e = at + 5;
        if (e < fnew.len and fnew[e] == '-') break :blk -1;
        while (e < fnew.len and std.ascii.isDigit(fnew[e])) e += 1;
        break :blk std.fmt.parseInt(i64, fnew[at + 5 .. e], 10) catch -1;
    } else -1;
    const fnew_ok = contains(fnew, "127.0.0.1") and full_ms >= 0 and full_ms <= 1000 and contains(fnew, "," ++ "\"tz.il.ua.lang.iw.dpr.mtp.print.fc\"]") and st_f != null and st_f.?.on_site and
        fdoc != null and std.mem.eql(u8, fdoc.?.uaText(), "BoundUA/1");
    const reload_ok = contains(freload, "127.0.0.1") and contains(freload, t0_all);
    report(old_clean and kids_clean and fnew_ok and reload_ok, "emu-site-bound-reused-renderer", std.fmt.bufPrint(&d, "옛 문서 T0={s} · 기다리는 동안 관찰 +{d}개(흉내 {d}·머리 {d}) {s}· 1.1 초 on_site={} active=0x{x} | 옛 문서가 만든 요청 문서 +{d}개(흉내 머리 {d}) 안의 fetch +{d}개(흉내 {d}) {s}| 새 문서 요청 ua=[{s}] · 새 문서 {s} on_site={} | 새로고침 {s}", .{ t0_obf, lo5.total - lo0.total, lo5.seen - lo0.seen, lo5.header - lo0.header, lo5.buf[0..lo5.len], if (st_wait) |x| x.on_site else true, if (st_wait) |x| x.active_mask else 0, kid5.docs - kid0.docs, kid5.dirty - kid0.dirty, kid5.inner - kid0.inner, kid5.inner_dirty - kid0.inner_dirty, kid5.buf[0..@min(kid5.len, 300)], if (fdoc) |x| x.uaText()[0..@min(x.ua_len, 20)] else "-", fnew, if (st_f) |x| x.on_site else false, freload }) catch "");
    report(true, "emu-site-bound-reused-renderer-first-script(obs)", std.fmt.bufPrint(&d, "첫 스크립트 {s}(모든 흉내까지 {d} ms — 0 이면 처음부터) · 첫 스크립트의 요청 {s} {s} · 렌더러 {d}", .{ if (std.mem.indexOf(u8, fnew, "T0=")) |at| fnew[at .. std.mem.indexOfScalarPos(u8, fnew, at, '"') orelse fnew.len] else "-", full_ms, if (faft) |x| x.targetText() else "-", headerText(&hb[1], faft), rend }) catch "");
}

/// 기다리는 동안 옛 문서가 만든 요청들(`ob_html` 의 `KID`): iframe 문서 셋·Worker 스크립트(`docs` — 흉내 UA·Accept-Language 를 실은 수 `dirty`)와 그
/// 안의 fetch(`inner` — 흉내를 본 수 `inner_dirty`).
const Kids = struct { docs: u32 = 0, dirty: u32 = 0, inner: u32 = 0, inner_dirty: u32 = 0, buf: [900]u8 = undefined, len: usize = 0 };

fn kidsOf(out: *Kids) void {
    out.* = .{};
    var w: std.Io.Writer = .fixed(&out.buf);
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    for (srv_recs.items) |rec| {
        const t = rec.targetText();
        const header = contains(rec.uaText(), "BoundUA") or std.mem.startsWith(u8, rec.alText(), "fr");
        if (std.mem.startsWith(u8, t, "/ifr?") or std.mem.startsWith(u8, t, "/wk?")) {
            out.docs += 1;
            if (header) out.dirty += 1;
            w.print("{s}@{s} ua=[{s}] al=[{s}]; ", .{ t[0..@min(t.len, 16)], rec.host[0..@min(rec.host_len, 12)], rec.uaText()[0..@min(rec.ua_len, 10)], rec.alText()[0..@min(rec.al_len, 8)] }) catch {};
        } else if (std.mem.startsWith(u8, t, "/ifs?") or std.mem.startsWith(u8, t, "/wks?")) {
            out.inner += 1;
            const seen = contains(t, "e=ua") or (if (std.mem.indexOf(u8, t, "e=")) |at| !std.mem.startsWith(u8, t[at + 2 ..], "-") else false);
            if (header or seen) out.inner_dirty += 1;
        }
    }
    out.len = w.buffered().len;
}

/// 두 요청의 흉내에 닿는 머리(UA·Sec-CH-UA·-Mobile·-Platform, `with_al` 이면 Accept-Language 도)가 모두 같은가.
fn sameHeaders(a: *const Rec, b: *const Rec, with_al: bool) bool {
    return std.mem.eql(u8, a.uaText(), b.uaText()) and (!with_al or std.mem.eql(u8, a.alText(), b.alText())) and std.mem.eql(u8, a.chuaText(), b.chuaText()) and
        std.mem.eql(u8, a.mobText(), b.mobText()) and std.mem.eql(u8, a.platText(), b.platText());
}

/// 커밋이 끝난 뒤 그 탭의 문서가 보내는 요청 하나(탭 전체 흉내가 확실히 걸린 뒤 — 첫 스크립트의 요청은 커밋의 걸기와 겨룬다).
fn laterReq(r: *Run, b: u64, target: []const u8) ?Rec {
    var js: [200]u8 = undefined;
    var out: [16]u8 = undefined;
    _ = r.ev(b, std.fmt.bufPrint(&js, "fetch('{s}').then(function(){{return 1}})", .{target}) catch return null, &out);
    r.pump(300);
    return lastReq(target);
}

fn headerText(buf: []u8, rec: ?Rec) []const u8 {
    const x = rec orelse return "-";
    return std.fmt.bufPrint(buf, "ua=[{s}] al=[{s}] ch=[{s}] m=[{s}] p=[{s}]", .{ x.uaText()[0..@min(x.ua_len, 40)], x.alText(), x.chuaText()[0..@min(x.chua_len, 80)], x.mobText(), x.platText() }) catch "?";
}

/// 듣지 않는 루프백 포트 하나(묶었다가 곧 닫는다 — 연결 거부의 오류 페이지).
fn closedPort() u16 {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 9;
    defer _ = std.c.close(fd);
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return 9;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return 9;
    return std.mem.bigToNative(u16, addr.port);
}

/// `ps_js` 의 답에 흉내를 본 표지가 있는가(`SG()` 의 이름 — `-` 가 아닌 것).
fn leakText(s: []const u8) bool {
    const names = [_][]const u8{ "tz", "il", "ua", "lang", "iw", "dpr", "mtp", "print", "fc", "err" };
    // 이름은 `"` 또는 `:`·`.` 뒤에 와서 `.`·`"` 로 끝난다 — 호스트 글자와 섞이지 않게 앞뒤를 본다.
    for (names) |n| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s, i, n)) |at| : (i = at + 1) {
            const before = if (at == 0) ' ' else s[at - 1];
            const after = if (at + n.len >= s.len) ' ' else s[at + n.len];
            if ((before == '"' or before == ':' or before == '.') and (after == '"' or after == '.')) return true;
        }
    }
    return false;
}

// ── 팝업(같은 렌더러 프로세스) ─────────────────────────────────────────────────────────────────────────────

fn popup(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emp");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, uLoop(&u, "/po"));
    r.host.send(.{ .set_focus = .{ .browser = 1, .value = true } }) catch {};
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true, .locale = true, .ua = true }, .timezone = "Asia/Kolkata", .accept_language = "fr-FR,fr", .icu_locale = "fr_FR", .ua = "OpenerUA/1" });
    try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
    r.pump(200);
    r.userClick(1, 100, 100);
    _ = r.until(Run.loadsAt, 4, 1, wait_ms);
    r.pump(800);
    var pb: [800]u8 = undefined;
    const p = r.ev(4, "JSON.stringify(P())", &pb);
    // 팝업이 제 시간대를 걸면 — 같은 프로세스의 opener 가 쥐었다(「already in effect」 → process_shared_conflict).
    const st = try r.emulate(4, .{ .browser = 0, .flags = .{ .timezone = true }, .timezone = "Europe/Paris" });
    const conflict = st != null and st.?.failed_mask & (1 << 3) != 0 and st.?.reason == .process_shared_conflict;
    report(r.created[4] and (contains(p, "Kolkata") or contains(p, "Calcutta")) and contains(p, "\"il\":\"fr-FR\"") and !contains(p, "OpenerUA") and conflict, "emu-popup-shared", std.fmt.bufPrint(&d, "팝업 {s} | 팝업의 제 시간대 → 실패 0x{x} {s}", .{ p[0..@min(p.len, 300)], if (st) |s| s.failed_mask else 0, if (st) |s| @tagName(s.reason) else "-" }) catch "");
}

// ── 재시작 ──────────────────────────────────────────────────────────────────────────────────────────────

fn restart(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    var o: [200]u8 = undefined;
    var origin_b: [256]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_b, "http://127.0.0.1:{d}", .{port}) catch "";
    // 옛 sidecar — 위치를 대신 허용하게 하고(출처에 저장된다) 되돌리기 전에 죽인다(SIGKILL — 닫기 길을 지나지 않는다).
    var stored = false;
    {
        var sess: Session = undefined;
        try open(&sess, host_path, root, "emr");
        defer {
            sess.run.deinit();
            _ = std.c.kill(sess.host.pid, .KILL);
            _ = sess.host.wait(10_000);
            sess.receiver.close();
        }
        const r = &sess.run;
        try r.create(1, uLoop(&u, "/pp?r0"));
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .geo = true }, .latitude = 1, .longitude = 2, .accuracy = 3 });
        _ = r.ev(1, "G()", &o);
        r.pump(300);
        stored = r.auto_first_len[1] > 0;
    }
    os.sleepMs(1500); // 죽인 host 의 helper 가 사라져 프로필 잠금이 풀리게
    // 새 sidecar — maru 의 재생 차례(about:blank → 흉내(되돌릴 출처 실음) → 이동): 문서 요청부터 흉내, 저장된 허용은 기본으로.
    var sess: Session = undefined;
    try open(&sess, host_path, root, "emr");
    defer sess.deinit();
    const r = &sess.run;
    try r.host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = "about:blank" } });
    _ = r.until(Run.createdAt, 1, 0, wait_ms);
    var v: msg.Emulation = .{ .browser = 1, .generation = 1, .flags = .{ .ua = true, .timezone = true }, .ua = "RestartUA/1", .timezone = "Asia/Kolkata", .restore_count = 1 };
    v.restore[0] = origin;
    r.gen[1] = 1;
    try r.host.send(.{ .emulation = v });
    try r.host.send(.{ .navigate = .{ .browser = 1, .url = uLoop(&u, "/pp?rs") } });
    _ = r.until(Run.loadsAt, 1, 1, wait_ms);
    r.pump(300);
    const rec = firstReqOn("/pp?rs", "127.0.0.1");
    var gp_b: [64]u8 = undefined;
    const gp = r.ev(1, "GP()", &gp_b);
    report(stored and rec != null and std.mem.eql(u8, rec.?.uaText(), "RestartUA/1") and std.mem.eql(u8, gp, "prompt"), "emu-restart", std.fmt.bufPrint(&d, "옛 sidecar 가 대신 허용 {}, 새 sidecar 의 첫 문서 요청 ua=[{s}], 되돌린 뒤 permissions.query={s}", .{ stored, if (rec) |x| x.uaText() else "-", gp }) catch "");
}
