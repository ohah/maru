//! W9d③ 3 차 20 회 적대 검증 1·2·6·8·10 회차(검증자 A3 — 8485a891e 를 친 판)의 실제 CEF 판정 — `maru-web-judge --review-block-v20a3`
//! (docs/plans/web-osr-backend.md 「W9d③ 20 회 적대 검증」 3 차). 시험 서버·Run 은 `network_block_v20a2_check.zig` 의 것을 옮겼다(A3 끝점을 더했다).
//! `A3_ONLY=r6,r8,r10,canon` 으로 고른다.
//!
//! 증명하는 것: R6 — 문서 없이 끝난 iframe 이동(204·다운로드·빈 응답·제 규칙에 막힘)이 그 탭을 그 출처를 「보이는」 탭으로 남기지 않는다(빈 T 는 막지
//! 않고 무관한 탭에 「적용 안 됨」 이 세어지지 않는다 — MED-A3-1), 다른 사이트에서 규칙의 사이트로 들어오는 서비스 워커 범위 이동이 막히고 그 규칙에
//! 귀속된다(MED-A3-2), 진행 중 이동 표 넘침의 문서화된 몫, 연 탭의 about:blank 팝업이 낸 요청은 연 탭의 요청이다(N-A3-5 — 문서화), 한 요청의 「적용
//! 안 됨」 은 한 번(N-A3-2); R8 — 엄격의 리다이렉트 셈이 그 이동의 문서에만; R10 — 대화상자 없이 오래 도는 beforeunload 뒤의 사용자 이동(LOW-A3-3),
//! iframe 의 같은 문서 항목만 꺼낸 사용자의 뒤로 뒤 페이지의 기록 이동(LOW-A3-4), 묶인 토큰의 끝(N-A3-1), 처리기를 기다리는 사용자
//! 이동을 멈춤이 거둔다(LOW-A3-3 — 3 차 고침의 변이 판에 더했다); R1·R2 — 패턴 앞부분·호스트 글자·친 호스트
//! `%XX` 를 Chromium 과 대조.
//! 브라우저 탭에서 중요한 이유: 에이전트의 막기 규칙은 사용자 탭에도 듣는다 — 새는 쪽(막아야 할 이동이 지나감)과 넘치는 쪽(사용자의 이동·무관한
//! 사이트의 서비스 워커 요청이 막힘) 모두 사용자가 겪는 일이다.
const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const msg = protocol.message;
const chunk = msg.devtools_chunk_bytes;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const wait_ms = 15_000;

// ── 서버(받은 요청을 모두 적는다) ─────────────────────────────────────────────────────────────────────────

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

var port: u16 = 0;
/// 4 차 검증(A4): 같은 사이트(127.0.0.1)의 다른 출처 — 같은 렌더러의 iframe(떨어져 나감의 놓기 `subframeGone` 이 닿는가).
var port2: u16 = 0;
var srv_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
/// 받은 요청(`메서드 대상 host=…`) — 쏟아짐 끝점(`/f`)은 수만.
var srv_log: std.ArrayList(u8) = .empty;
var flood_served = std.atomic.Value(u32).init(0);

fn startServer() !void {
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

fn startServer2() !void {
    if (port2 != 0) return;
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0) return error.BindFailed;
    if (listen(fd, 512) != 0) return error.ListenFailed;
    var len: u32 = @sizeOf(SockaddrIn);
    if (getsockname(fd, &addr, &len) != 0) return error.SocketFailed;
    port2 = std.mem.bigToNative(u16, addr.port);
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

/// 서버가 그 글을 담은 요청을 받은 수(대상·host 머리 포함).
fn seen(needle: []const u8) usize {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    return std.mem.count(u8, srv_log.items, needle);
}

/// 그 글을 담은 마지막 요청 줄(`buf` 에 — 서비스 워커 표지 `sw=` 를 본다).
fn lastSeen(needle: []const u8, buf: []u8) []const u8 {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    const at = std.mem.lastIndexOf(u8, srv_log.items, needle) orelse return "";
    const start = (std.mem.lastIndexOfScalar(u8, srv_log.items[0..at], '\n') orelse 0);
    const end = std.mem.indexOfScalarPos(u8, srv_log.items, at, '\n') orelse srv_log.items.len;
    const line = srv_log.items[start..end];
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    return buf[0..n];
}

fn reply(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [2048]u8 = undefined;
    const cache = if (std.mem.indexOf(u8, extra, "Cache-Control") != null) "" else "Cache-Control: no-store\r\n";
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}{s}Connection: close\r\n\r\n", .{ status, ctype, body.len, cache, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

const html = "text/html; charset=utf-8";
/// 서비스 워커 — `/s/`·`/blk/` 아래를 네트워크로 받아 오며 `sw=<인스턴스>` 를 단다(서버 줄로 서비스 워커를 지났는지·어느 인스턴스인지 안다).
/// 이동(`mode=navigate`)은 주소를 바꾸지 않고 받아 온다 — 서비스 워커가 주소를 바꿔 받아 오는 이동은 막혀도 오류 페이지에 규칙이 붙지 않고 D2
/// 예외도 받지 못한다(계획 §6.3 — 문서화된 틈, 실측 phase 0 sw3 가 그 꼴이었다).
/// `message` 를 받으면 1.5 초 뒤 `/s/swlate` 를 부른다(탭이 모두 떠난 뒤의 요청 — block-sw-empty-T).
const sw_js =
    \\const iid=Math.random().toString(36).slice(2,8);
    \\self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open('c1').then(c=>c.add('/s/cached')))});
    \\self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
    \\self.addEventListener('message',e=>{e.waitUntil(new Promise(r=>setTimeout(()=>fetch('/s/swlate?sw='+iid).then(r,r),1500)))});
    \\self.addEventListener('fetch',e=>{const u=new URL(e.request.url);
    \\ if(e.request.mode==='navigate'){e.respondWith(fetch(e.request));return}
    \\ if(u.pathname==='/s/cached'){e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));return}
    \\ if(u.pathname==='/s/sw.js')return;
    \\ if(u.pathname.startsWith('/s/')||u.pathname.startsWith('/blk/')){const sep=u.search?'&':'?';
    \\  e.respondWith(fetch(u.href+sep+'sw='+iid))}});
;
const sw_reg =
    \\<script>window.swready=navigator.serviceWorker.register('/s/sw.js',{scope:'/s/'}).then(()=>navigator.serviceWorker.ready).then(()=>{
    \\ if(!navigator.serviceWorker.controller){if(!sessionStorage.rl){sessionStorage.rl=1;location.reload()}return 'nocontroller'}return 'controlled'},e=>'regerr:'+e.name+':'+e.message);
    \\</script>
;

/// A4: 모든 요청을 그 요청 그대로(주소를 바꾸지 않고) 받아 오는 서비스 워커 — 다른 출처로 가는 하위 자원도 공유 context 길로 그 주소 그대로 온다.
const sw4_js =
    \\self.addEventListener('install',e=>self.skipWaiting());
    \\self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
    \\self.addEventListener('fetch',e=>{if(new URL(e.request.url).pathname==='/s4/sw.js')return;e.respondWith(fetch(e.request))});
;
const sw4_reg =
    \\<script>window.swready=navigator.serviceWorker.register('/s4/sw.js',{scope:'/s4/'}).then(()=>navigator.serviceWorker.ready).then(()=>{
    \\ if(!navigator.serviceWorker.controller){if(!sessionStorage.rl4){sessionStorage.rl4=1;location.reload()}return 'nocontroller'}return 'controlled'},e=>'regerr:'+e.name+':'+e.message);
    \\</script>
;

fn serveOne(conn: c_int) void {
    defer _ = std.c.close(conn);
    while (serveReq(conn)) {}
}

fn serveReq(conn: c_int) bool {
    var req: [8192]u8 = undefined;
    const n = std.c.read(conn, &req, req.len);
    if (n <= 0) return false;
    serveParsed(conn, req[0..@intCast(n)]) catch return true;
    return false;
}

fn serveParsed(conn: c_int, r: []const u8) error{Keep}!void {
    const line_end = std.mem.indexOfScalar(u8, r, '\r') orelse return;
    var parts = std.mem.splitScalar(u8, r[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var host_hdr: []const u8 = "";
    if (std.ascii.findIgnoreCase(r, "\r\nhost: ")) |i| {
        const rest = r[i + 8 ..];
        host_hdr = rest[0 .. std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len];
    }
    if (std.mem.eql(u8, path, "/f")) {
        _ = flood_served.fetchAdd(1, .monotonic);
        const resp = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n";
        _ = std.c.write(conn, resp.ptr, resp.len);
        return error.Keep;
    }
    {
        _ = std.c.pthread_mutex_lock(&srv_lock);
        defer _ = std.c.pthread_mutex_unlock(&srv_lock);
        var lb: [600]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s} {s} host={s}\n", .{ method, target, host_hdr }) catch "";
        srv_log.appendSlice(std.heap.c_allocator, line) catch {};
    }
    const p = port;
    var bb: [4096]u8 = undefined;
    var xb: [512]u8 = undefined;
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>";
    // ── A8 endpoints (eighth-pass verifier on f36d51e93) ──
    if (std.mem.startsWith(u8, path, "/a8/")) return a8serve(conn, path, target);
    // ── A7 endpoints (seventh-pass verifier on 2baa301cd) — `TAG` in the page is the query string, so each tab's requests are its own ──
    if (std.mem.eql(u8, path, "/a7/cv") or std.mem.eql(u8, path, "/a7/hid") or std.mem.eql(u8, path, "/a7/sub")) {
        const tag = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "none";
        const tmpl = if (std.mem.eql(u8, path, "/a7/cv")) a7_cv_page else if (std.mem.eql(u8, path, "/a7/sub")) a7_sub_page else a7_hid_page;
        const body = std.mem.replaceOwned(u8, std.heap.c_allocator, tmpl, "TAG", tag) catch return;
        defer std.heap.c_allocator.free(body);
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a7/gc")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a7gc</title><script>window.M=k=>fetch('/a7/mark?'+k+'-gc');" ++
        "window.fr=new FinalizationRegistry(h=>M('fr-'+h));window.mk=()=>{const o={a:new Array(1000).fill(1)};fr.register(o,'held');return o};" ++
        "(()=>{const o2={a:new Array(1000).fill(2)};fr.register(o2,'ctrl')})();" ++
        "setInterval(()=>{window.junk=[];for(let i=0;i<30;i++)window.junk.push(new Array(1e5).fill(i))},100);</script>gc");
    if (std.mem.eql(u8, path, "/a7/font")) return reply(conn, "404 Not Found", "text/plain", "", "nofont");
    if (std.mem.eql(u8, path, "/a7/res")) return reply(conn, "200 OK", "image/svg+xml", "", svg);
    if (std.mem.eql(u8, path, "/a7/obj")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a7obj</title>obj");
    // ── A6 endpoints (sixth-pass verifier on 56c752cdb) ──
    if (std.mem.eql(u8, path, "/a6/one")) {
        // localhost page with ONE iframe (127.0.0.1 /x/blank) and `cyc(n,k,bad)` — n times: iframe → bad URL (error page), then → good 127.0.0.1 URL.
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a6one</title><script>window.mk=1;window.cr='idle';" ++
            "window.cyc=async(n,k,bad)=>{{const f=document.getElementById('f');const ld=u=>new Promise(r=>{{const t=setTimeout(()=>r('to'),3000);f.onload=()=>{{clearTimeout(t);r('ld')}};f.src=u}});" ++
            "let to=0;for(let i=0;i<n;i++){{if(await ld(bad+'?a6'+k+'-'+i)==='to')to++;if(await ld('http://127.0.0.1:{d}/x/blank?a6g'+k+'-'+i)==='to')to++}}return 'done '+n+' timeouts '+to}};" ++
            "window.run=(n,k,bad)=>{{window.cr='run';cyc(n,k,bad).then(v=>window.cr=v,e=>window.cr='err '+e)}};</script>" ++
            "<iframe id=f src='http://127.0.0.1:{d}/x/blank?a6first' width=20 height=20></iframe>", .{ p, p }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a6/err")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a6err</title><div id=c>c</div><div id=d>d</div><script>" ++
        "Error.prepareStackTrace=(e,s)=>{fetch('/a6/mark?pst-'+e.message);return 'pst'};" ++
        "const c=document.getElementById('c');c.e1=new Error('e1');" ++
        "const e2=new Error('e2');Object.defineProperty(e2,'stack',{get(){fetch('/a6/mark?sget');return 's'},configurable:true});c.e2=e2;" ++
        "class MyErr extends Error{};c.e4=new MyErr('e4');" ++
        "c.e5={get x(){fetch('/a6/mark?plain');return 1}};" ++
        "const d=document.getElementById('d');d.e6=new Error('e6');d.e7=[new Error('e7')];" ++
        "window.e8=new Error('e8');" ++
        "</script>");
    // 9 차: 렌더러가 죽은 동안의 바꾸기 — 서비스 워커 없는 문서(규칙·기록 판).
    if (std.mem.eql(u8, path, "/a9/top")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a9top</title>a9top");
    if (std.mem.eql(u8, path, "/z/204")) return reply(conn, "204 No Content", "text/plain", "", "");
    // 6 차 고침: 읽기 목록 밖으로 뺀 getProperties 가 토큰을 거두는가 — `/a5/bu600` 의 600 ms beforeunload 에 아직 읽지 않은 Error 와 prepareStackTrace.
    if (std.mem.eql(u8, path, "/a6/errbu")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a6errbu</title><script>" ++
        "addEventListener('beforeunload',()=>{const t=performance.now();while(performance.now()-t<600){}});" ++
        "Error.prepareStackTrace=(e,s)=>{fetch('/a6/mark?pst-'+e.message);return 'pst'};window.e9=new Error('tok');</script>a6errbu");
    // 6 차 고침: 읽기 목록에 남은 메서드가 V8 의 늦은 접근자(stack 꼴 만들기·toStringTag·toJSON)나 custom element·접근성 이름 계산·감시자로
    // 페이지 스크립트를 돌리는가 — 무엇이든 돌면 `/a6/mark?<이름>` 이 서버에 온다.
    if (std.mem.eql(u8, path, "/a6/lazy")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a6lazy</title><script>" ++
        "window.M=k=>fetch('/a6/mark?'+k);Error.prepareStackTrace=(e,s)=>{M('pst-'+(e&&e.message||e&&e.id||'x'));return 'pst'};" ++
        "for(const [o,k] of [[Element.prototype,'ariaLabel'],[Element.prototype,'role'],[Node.prototype,'textContent'],[HTMLElement.prototype,'title'],[HTMLElement.prototype,'innerText'],[Element.prototype,'id'],[Element.prototype,'className']]){const d=Object.getOwnPropertyDescriptor(o,k);if(d&&d.get)Object.defineProperty(o,k,{get(){M('proto-'+k);return d.get.call(this)},set:d.set,configurable:true})}" ++
        "for(const k of ['getAttribute','querySelector','getBoundingClientRect','getClientRects','hasAttribute','closest','matches']){const f=Element.prototype[k];Element.prototype[k]=function(...a){M('fn-'+k);return f.apply(this,a)}}" ++
        "class XL extends HTMLElement{static formAssociated=true;static observedAttributes=['aria-label','data-maru-ref','class','style'];" ++
        "constructor(){super();this.i=this.attachInternals();this.i.role='button';this.i.ariaLabel='xl';}" ++
        "get [Symbol.toStringTag](){M('tag');return 'XL'}toJSON(){M('tojson');return {}}[Symbol.toPrimitive](){M('prim');return 1}" ++
        "connectedCallback(){if(window.ready)M('conn')}disconnectedCallback(){M('disc')}adoptedCallback(){M('adopt')}attributeChangedCallback(n){if(window.ready)M('attr-'+n)}" ++
        "formResetCallback(){M('freset')}formDisabledCallback(){if(window.ready)M('fdis')}formStateRestoreCallback(){M('fsr')}formAssociatedCallback(){if(window.ready)M('fassoc')}};customElements.define('x-lazy',XL);" ++
        "class XS extends HTMLElement{constructor(){super();const r=this.attachShadow({mode:'open',delegatesFocus:true,serializable:true});r.innerHTML='<button>in</button><slot></slot>';}};customElements.define('x-sh',XS);" ++
        "</script><form id=f><label for=c>lab</label><x-lazy id=c aria-labelledby=lb tabindex=0>ce</x-lazy><span id=lb>label-by</span>" ++
        "<input id=i aria-describedby=lb><select><option>o</option></select><x-sh id=s><span>slotted</span></x-sh></form>" ++
        "<div hidden=until-found id=huf>hidden text</div>" ++
        "<details id=dt><summary>sum</summary>body</details><svg><title>svgt</title></svg><canvas id=cv>fallback</canvas>" ++
        "<iframe id=fr srcdoc=\"<script>Error.prepareStackTrace=()=>{parent.M('ifr-pst');return 's'};document.documentElement.e=new Error('ifr')</script><p>in</p>\" width=30 height=30></iframe>" ++
        "<div style='height:4000px'></div><img loading=lazy id=lz src='/a6/img' onload=\"M('lazyload')\" width=4 height=4>" ++
        // 7 차 NIT(c): content-visibility 요소를 화면 밖에(LOW-1 의 갈래) — `cva`(auto) 와, 스타일·배치를 건너뛰는 `cvh`(hidden — 그 안의 글꼴·배경
        // 그림은 누가 그 하위 트리를 강제할 때만 요청되고 `cv-*` marks 를 낸다).
        "<style>@font-face{font-family:LZH;src:url(/a7/font?lzh)}</style>" ++
        "<div id=cva style='content-visibility:auto;contain-intrinsic-size:10px 10px'><p id=cvap>cv text</p></div>" ++
        "<div id=cvh style='content-visibility:hidden;contain-intrinsic-size:10px 10px'><p id=cvhp style='font-family:LZH'>cvh text</p><div style='width:8px;height:8px;background-image:url(/a6/img?cvbg)'></div></div>" ++
        "<script>" ++
        "const c=document.getElementById('c');c.e1=new Error('e1');Error.captureStackTrace(c);c.tj={get toJSON(){M('get-tojson');return ()=>1}};" ++
        "document.documentElement.e2=new Error('e2');document.e3=new Error('e3');window.e8=new Error('e8');Error.captureStackTrace(document.getElementById('f'));" ++
        "Object.defineProperty(c,Symbol.toStringTag,{get(){M('own-tag');return 'T'},configurable:true});" ++
        "document.getElementById('huf').addEventListener('beforematch',()=>M('beforematch'));document.getElementById('cva').addEventListener('contentvisibilityautostatechange',()=>{if(window.ready)M('cvas')});" ++
        "document.getElementById('dt').addEventListener('toggle',()=>M('toggle'));" ++
        "document.fonts.addEventListener('loading',()=>M('cv-fontloading'));document.fonts.addEventListener('loadingerror',()=>M('cv-fonterr'));" ++
        "new PerformanceObserver(l=>{for(const e of l.getEntries())if(e.name.includes('cvbg')||e.name.includes('lzh'))M('cv-perf')}).observe({type:'resource'});" ++
        "for(const e of ['focus','blur','focusin','focusout','mouseover','mousemove','pointermove','selectionchange','scroll','resize','visibilitychange','pagehide','freeze','resume','securitypolicyviolation','invalid','load'])addEventListener(e,()=>{if(window.ready)M('ev-'+e)},true);" ++
        "document.addEventListener('selectionchange',()=>{if(window.ready)M('selchange')});" ++
        "new MutationObserver(()=>{if(window.ready)M('mut')}).observe(document,{subtree:true,attributes:true,childList:true,characterData:true});" ++
        "new ResizeObserver(()=>{if(window.ready)M('ro')}).observe(c);new IntersectionObserver(()=>{if(window.ready)M('io')}).observe(document.getElementById('lz'));" ++
        "setTimeout(()=>window.ready=1,400);" ++
        "</script>");
    if (std.mem.eql(u8, path, "/a6/img")) return reply(conn, "200 OK", "image/svg+xml", "", svg);
    if (std.mem.eql(u8, path, "/a6/dl")) return reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=a6.bin\r\n", "bin");
    if (std.mem.eql(u8, path, "/a6/204")) return reply(conn, "204 No Content", "text/plain", "", "");
    // ── A5 endpoints (fifth-pass verifier A5 on 7f0333fa9) ──
    if (std.mem.eql(u8, path, "/a5/ifrs")) {
        // localhost page with n iframes on 127.0.0.1 /blkifr?a5<k>-<i>; records pageshow.persisted (bfcache).
        const q = target[path.len..];
        var n: usize = 1;
        if (std.mem.indexOf(u8, q, "n=")) |i| n = std.fmt.parseInt(usize, q[i + 2 .. i + 2 + (std.mem.indexOfAny(u8, q[i + 2 ..], "&") orelse q.len - i - 2)], 10) catch 1;
        var k: []const u8 = "x";
        if (std.mem.indexOf(u8, q, "k=")) |i| k = q[i + 2 .. i + 2 + (std.mem.indexOfAny(u8, q[i + 2 ..], "&") orelse q.len - i - 2)];
        var w: std.Io.Writer = .fixed(&bb);
        w.writeAll("<!doctype html><title>a5ifrs</title><script>window.ps=[];addEventListener('pageshow',e=>ps.push(e.persisted))</script>") catch return;
        const same = std.mem.indexOf(u8, q, "same=1") != null;
        for (0..n) |i| w.print("<iframe src='http://127.0.0.1:{d}/blkifr?a5{s}-{d}' width=20 height=20></iframe>", .{ p, k, if (same) 0 else i }) catch return;
        return reply(conn, "200 OK", html, "", w.buffered());
    }
    if (std.mem.eql(u8, path, "/a5/nc")) {
        // Navigation API: cancel the user's same-document traversal (c=1) and then go(-2); otherwise go(-1) after it commits.
        const cancel = std.mem.indexOf(u8, target, "c=1") != null;
        const delay: []const u8 = if (std.mem.indexOf(u8, target, "d=1500") != null) "1500" else "300";
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a5nc</title><body style='height:380px;margin:0'><script>window.log=[];const CANCEL={s};" ++
            "window.goSelf=()=>{{log.push('self-go-2 idx '+navigation.currentEntry.index);history.go(-2)}};" ++
            "navigation.addEventListener('navigate',e=>{{if(e.navigationType!=='traverse')return;log.push('trav c='+e.cancelable+' same='+!!e.destination.sameDocument+' to '+e.destination.index);" ++
            "if(CANCEL&&e.cancelable){{e.preventDefault();log.push('canceled');const REP=location.search.includes('rep=1');let k=0;const f=()=>{{log.push('go-2 idx '+navigation.currentEntry.index+' len '+history.length+' t '+Math.round(performance.now()));history.go(-2);if(REP&&++k<14)setTimeout(f,2000)}};setTimeout(f,{s})}}else{{setTimeout(()=>{{log.push('go-1');history.go(-1)}},{s})}}}});" ++
            "navigation.addEventListener('navigateerror',e=>log.push('navigateerror '+e.message));" ++
            "document.addEventListener('click',()=>{{history.pushState({{}},'',location.pathname+location.search+'&b');log.push('pushed')}})</script>nc</body>", .{ if (cancel) "true" else "false", delay, delay }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a5/same3")) return reply(conn, "200 OK", html, "", "<!doctype html><title>same3</title><script>for(let i=0;i<3;i++)history.pushState({},'',location.href)</script>same3");
    if (std.mem.eql(u8, path, "/a5/bu600")) return reply(conn, "200 OK", html, "", "<!doctype html><title>bu600</title><script>addEventListener('beforeunload',()=>{const t=performance.now();while(performance.now()-t<600){}})</script>bu600");
    if (std.mem.eql(u8, path, "/a5/ro")) {
        // Page script behind accessors / proxy traps / custom-element getters — marks the server when any runs.
        return reply(conn, "200 OK", html, "", "<!doctype html><title>a5ro</title><script>" ++
            "Object.defineProperty(document,'zz',{get(){fetch('/a5/mark?getter');return 1},enumerable:true,configurable:true});" ++
            "window.px=new Proxy({a:1},{ownKeys(t){fetch('/a5/mark?ownkeys');return Reflect.ownKeys(t)},getOwnPropertyDescriptor(t,k){fetch('/a5/mark?gopd');return Reflect.getOwnPropertyDescriptor(t,k)},get(t,k){fetch('/a5/mark?pget');return t[k]},has(t,k){fetch('/a5/mark?has');return k in t},getPrototypeOf(t){fetch('/a5/mark?proto');return Object.prototype}});" ++
            "class X extends HTMLElement{get zz(){fetch('/a5/mark?ce');return 2}connectedCallback(){}};customElements.define('x-a5',X);" ++
            "addEventListener('resize',()=>fetch('/a5/mark?resize'));addEventListener('scroll',()=>fetch('/a5/mark?scroll'));" ++
            "visualViewport.addEventListener('resize',()=>fetch('/a5/mark?vvresize'));visualViewport.addEventListener('scroll',()=>fetch('/a5/mark?vvscroll'));" ++
            "new IntersectionObserver(es=>{if(window.ioReady)fetch('/a5/mark?io')}).observe(document.documentElement);setTimeout(()=>window.ioReady=1,300);" ++
            "</script><x-a5 id=c>ce</x-a5><div style='height:3000px'></div><div id=far>far</div>");
    }
    if (std.mem.eql(u8, path, "/a5/swtop")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a5swtop</title><script>window.ictl='none';addEventListener('message',e=>{{if(typeof e.data==='string'&&e.data.startsWith('ctl:'))window.ictl=e.data}});" ++
            "window.go=(nav,fu)=>{{frames[0].postMessage({{fu}},'*');location.href=nav}}</script><iframe src='http://localhost:{d}/s4/a5ifr'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/s4/a5ifr")) return reply(conn, "200 OK", html, "", "<!doctype html><title>a5ifr</title>" ++ sw4_reg ++
        "<script>window.swready.then(s=>parent.postMessage('ctl:'+s,'*'));addEventListener('message',e=>{if(!e.data||!e.data.fu)return;setTimeout(()=>fetch(e.data.fu,{mode:'no-cors'}).then(()=>fetch('/s4/mark?a5i-ok'),()=>fetch('/s4/mark?a5i-rej')),1500)})</script>");
    // ── A4 endpoints (fourth-pass verifier A4 — rounds 6, 8, 10 on 1d8fe6522) ──
    if (std.mem.eql(u8, path, "/a4/ifr2")) {
        // 127.0.0.1 page with one iframe on 127.0.0.1:<port2> (same site, other origin) whose path is everything after `s=`.
        const at = std.mem.indexOf(u8, target, "s=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no s");
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a4ifr2</title><iframe id=f src='http://127.0.0.1:{d}{s}'></iframe>", .{ port2, target[at + 2 ..] }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/s4/sw.js")) return reply(conn, "200 OK", "application/javascript", "", sw4_js);
    if (std.mem.startsWith(u8, path, "/s4/page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>s4page</title>" ++ sw4_reg);
    if (std.mem.eql(u8, path, "/s4/hang")) {
        _ = usleep(8_000_000);
        return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", "<!doctype html><title>s4hang</title>hang");
    }
    if (std.mem.eql(u8, path, "/a4/same0")) return reply(conn, "200 OK", html, "", "<!doctype html><title>same0</title><script>history.pushState({},'',location.href)</script>same0");
    // 같은 꼴 + 대화상자 없이 600 ms 도는 beforeunload — 그 뒤로의 `on_before_browse` 가 `go_back` 안에서 곧 오지 않는다(이동 뒤에 읽은 대상이 판정한다).
    if (std.mem.eql(u8, path, "/a4/same0b")) return reply(conn, "200 OK", html, "", "<!doctype html><title>same0b</title><script>history.pushState({},'',location.href);addEventListener('beforeunload',()=>{const t=performance.now();while(performance.now()-t<600){}})</script>same0b");
    if (std.mem.eql(u8, path, "/a4/bustay")) return reply(conn, "200 OK", html, "", "<!doctype html><title>bustay</title><script>const h=e=>{e.preventDefault();e.returnValue='x';if(!window.armed){window.armed=1;setTimeout(()=>{removeEventListener('beforeunload',h);history.go(-2)},2500)}};addEventListener('beforeunload',h)</script>bustay");
    // ── A3 endpoints (third-pass verifier A3 — rounds 1, 2, 6, 8, 10 on 8485a891e) ──
    if (std.mem.eql(u8, path, "/a3/close")) return; // closes without a response (ERR_EMPTY_RESPONSE)
    if (std.mem.eql(u8, path, "/a3/ifr")) {
        // localhost page with one iframe on 127.0.0.1 whose path is everything after `s=`.
        const at = std.mem.indexOf(u8, target, "s=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no s");
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a3ifr</title><iframe id=f src='http://127.0.0.1:{d}{s}'></iframe>", .{ p, target[at + 2 ..] }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/s/hang10") or std.mem.eql(u8, path, "/a3/hang10")) {
        // ten iframes that hang 8 s on localhost (another connection group than 127.0.0.1) — ten in-progress subframe navigations.
        var w: std.Io.Writer = .fixed(&bb);
        w.writeAll("<!doctype html><title>hang10</title>") catch return;
        if (path[1] == 's') w.writeAll(sw_reg) catch return;
        for (0..10) |i| w.print("<iframe src='http://localhost:{d}/x/hang?h{d}'></iframe>", .{ p, i }) catch return;
        return reply(conn, "200 OK", html, "", w.buffered());
    }
    if (std.mem.startsWith(u8, path, "/s/swr1")) return reply(conn, "302 Found", "text/plain", "Location: /s/swr2\r\n", "");
    if (std.mem.eql(u8, path, "/a3/sdi")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sdi</title><style>body{margin:0}iframe{border:0;width:320px;height:200px;display:block}</style><iframe id=f src='/a3/sdichild'></iframe>");
    if (std.mem.eql(u8, path, "/a3/sdichild")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sdichild</title><style>body{margin:0;height:200px}</style><script>addEventListener('click',()=>{history.pushState({},'','?s2');parent.pushed=(parent.pushed||0)+1})</script>child");
    if (std.mem.eql(u8, path, "/a3/same")) return reply(conn, "200 OK", html, "", "<!doctype html><title>same</title><style>body{margin:0;height:400px}</style><script>addEventListener('click',()=>{history.pushState({},'',location.href);window.pushed=(window.pushed||0)+1})</script>same");
    if (std.mem.startsWith(u8, path, "/a3/busy") or std.mem.startsWith(u8, path, "/blk/busy")) {
        // beforeunload handler that runs `ms=` milliseconds; `dlg=1` asks for the leave dialog at the end.
        var ms: []const u8 = "0";
        if (std.mem.indexOf(u8, target, "ms=")) |i| {
            var j = i + 3;
            while (j < target.len and std.ascii.isDigit(target[j])) j += 1;
            if (j > i + 3) ms = target[i + 3 .. j];
        }
        const dlg = std.mem.indexOf(u8, target, "dlg=1") != null;
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>busy</title><script>addEventListener('beforeunload',e=>{{const t=Date.now();while(Date.now()-t<{s}){{}}{s}}})</script>busy", .{ ms, if (dlg) "e.preventDefault();e.returnValue='x'" else "" }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a3/bfslow")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", html, "Cache-Control: max-age=0\r\n", "<!doctype html><title>bfslow</title><script>addEventListener('pageshow',e=>{window.ps=(window.ps||'')+(e.persisted?'P':'N')})</script>bfslow");
    }
    if (std.mem.eql(u8, path, "/a3/bfpage")) return reply(conn, "200 OK", html, "Cache-Control: max-age=0\r\n", "<!doctype html><title>bfpage</title><script>addEventListener('pageshow',e=>{window.ps=(window.ps||'')+(e.persisted?'P':'N')})</script>bfpage");
    if (std.mem.startsWith(u8, path, "/a3/replace")) {
        return reply(conn, "200 OK", html, "", "<!doctype html><title>replace</title><script>if(!location.search.includes('done'))location.replace(location.pathname+'?done')</script>r");
    }
    if (std.mem.eql(u8, path, "/a3/r307")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://127.0.0.1:{d}/s/inner?k5\r\n", .{p}) catch return;
        return reply(conn, "307 Temporary Redirect", "text/plain", loc, "");
    }
    // ── A2 endpoints ──
    if (std.mem.eql(u8, path, "/r/go")) {
        // 302 to everything after the first `to=` (raw — nested chains carry their own `to=`).
        const at = std.mem.indexOf(u8, target, "to=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no to");
        const loc = std.fmt.bufPrint(&xb, "Location: {s}\r\nAccess-Control-Allow-Origin: *\r\n", .{target[at + 3 ..]}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/n204")) return reply(conn, "204 No Content", "text/plain", "", "");
    if (std.mem.eql(u8, path, "/r/slowgo")) {
        // 1.5 초 뒤 `to=` 뒤로 302(이동 중에 엄격을 켤 틈).
        _ = usleep(1_500_000);
        const at = std.mem.indexOf(u8, target, "to=") orelse return reply(conn, "400 Bad Request", "text/plain", "", "no to");
        const loc = std.fmt.bufPrint(&xb, "Location: {s}\r\n", .{target[at + 3 ..]}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.startsWith(u8, path, "/dl/")) return reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=a2.bin\r\n", "data");
    if (std.mem.eql(u8, path, "/x/slowpage")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>slowpage</title>slow");
    }
    if (std.mem.eql(u8, path, "/x/lazy")) return reply(conn, "200 OK", html, "", "<!doctype html><title>lazy</title><div style='height:30000px'></div><iframe loading=lazy src='/p/sub?lz'></iframe>");
    if (std.mem.eql(u8, path, "/p/ifrhist")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ifrhist</title><iframe id=f src='/p/sub?f1'></iframe>");
    if (std.mem.startsWith(u8, path, "/blk/h")) return reply(conn, "200 OK", html, "Cache-Control: no-store\r\n", "<!doctype html><title>blk-h</title><script>addEventListener('unload',()=>{});window.bc=new BroadcastChannel('a2')</script>h");
    if (std.mem.startsWith(u8, path, "/blk/bu") or std.mem.eql(u8, path, "/p/bu")) return reply(conn, "200 OK", html, "", "<!doctype html><title>bu</title><script>addEventListener('beforeunload',e=>{e.preventDefault();e.returnValue='x'})</script>bu");
    if (std.mem.eql(u8, path, "/i/sw.js")) return reply(conn, "200 OK", "application/javascript", "", "importScripts('/blk/imp1.js');self.addEventListener('fetch',()=>{})");
    if (std.mem.eql(u8, path, "/i/swm.js")) return reply(conn, "200 OK", "application/javascript", "", "import '/blk/impm.js';self.addEventListener('fetch',()=>{})");
    if (std.mem.startsWith(u8, path, "/blk/impm")) return reply(conn, "200 OK", "application/javascript", "", "export{}");
    if (std.mem.startsWith(u8, path, "/blk/imp")) return reply(conn, "200 OK", "application/javascript", "", "self.imp=1");
    if (std.mem.eql(u8, path, "/s/slowpage")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>sslow</title>sslow");
    }
    if (std.mem.eql(u8, path, "/i/page")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ipage</title>i");
    // ── 1 차 검증(A)의 끝점 — 같은 서버를 쓴다 ──
    if (std.mem.eql(u8, path, "/x/hang")) {
        _ = usleep(8_000_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>hang</title>hang");
    }
    if (std.mem.eql(u8, path, "/r/slow")) {
        _ = usleep(1_500_000);
        return reply(conn, "302 Found", "text/plain", "Location: /m/late\r\nAccess-Control-Allow-Origin: *\r\n", "");
    }
    if (std.mem.eql(u8, path, "/m2/direct")) {
        _ = usleep(1_500_000);
        return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "direct");
    }
    if (std.mem.startsWith(u8, path, "/blk/slow")) {
        _ = usleep(2_000_000);
        return reply(conn, "200 OK", html, "", "<!doctype html><title>slow</title>slow");
    }
    if (std.mem.startsWith(u8, path, "/m/") or std.mem.startsWith(u8, path, "/m2/")) return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "m");
    if (std.mem.startsWith(u8, path, "/ok/")) return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", "<!doctype html><title>ok</title>ok");
    if (std.mem.eql(u8, path, "/r/to127")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://127.0.0.1:{d}/s/page?rd\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/toLocal")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/s/page?L2\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/tolocalblk")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/blk/xsite\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/x/bcn")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>bcn</title><script>addEventListener('pagehide',()=>navigator.sendBeacon('http://127.0.0.1:{d}/blk/rev'))</script>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/x/ifr")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>ifr</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data))</script><iframe src='http://localhost:{d}/p/ifrfetch'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/ifrfetch")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ifrfetch</title><script>fetch('/blk/ifr1').then(r=>'ok '+r.status,e=>'reject '+e.name).then(t=>parent.postMessage('ifr:'+t,'*'))</script>");
    if (std.mem.eql(u8, path, "/p/worker.js")) return reply(conn, "200 OK", "application/javascript", "", "fetch(new URL(location).searchParams.get('u')).then(()=>postMessage('ok'),()=>postMessage('reject'))");
    if (std.mem.eql(u8, path, "/p/shw.js")) return reply(conn, "200 OK", "application/javascript", "", "fetch(new URL(location).searchParams.get('u')).catch(()=>0)");
    if (std.mem.eql(u8, path, "/p/csp")) {
        const q = if (std.mem.indexOf(u8, target, "r=")) |i| target[i + 2 ..] else "/ok/none";
        const hdr = std.fmt.bufPrint(&xb, "Content-Security-Policy: img-src 'none'; report-uri {s}\r\n", .{q}) catch return;
        return reply(conn, "200 OK", html, hdr, "<!doctype html><title>csp</title><img src='/p/cspimg.svg'>");
    }
    if (std.mem.eql(u8, path, "/p/sub")) return reply(conn, "200 OK", html, "", "<!doctype html><title>sub</title><body>sub</body>");
    if (std.mem.eql(u8, path, "/p/userpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>userpage</title><img src='/blk/userimg'>");
    if (std.mem.eql(u8, path, "/blk/userpage")) return reply(conn, "200 OK", html, "", "<!doctype html><title>blk-userpage</title><img id=i src='/blk/userimg'>");
    if (std.mem.eql(u8, path, "/blk/s.js")) return reply(conn, "200 OK", "application/javascript", "", "window.sran=1");
    if (std.mem.eql(u8, path, "/blk/c.css")) return reply(conn, "200 OK", "text/css", "", "body{}");
    if (std.mem.startsWith(u8, path, "/blk/i") or std.mem.eql(u8, path, "/blk/target") or std.mem.startsWith(u8, path, "/typed/") or std.mem.startsWith(u8, path, "/forms") or std.mem.startsWith(u8, path, "/FORMS")) return reply(conn, "200 OK", "image/svg+xml", "Access-Control-Allow-Origin: *\r\n", svg);
    if (std.mem.eql(u8, path, "/blk/dl")) return reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=x.bin\r\n", "data");
    if (std.mem.eql(u8, path, "/blk/cors")) {
        if (std.mem.eql(u8, method, "OPTIONS")) return reply(conn, "204 No Content", "text/plain", "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: PUT\r\nAccess-Control-Allow-Headers: x-a\r\n", "");
        return reply(conn, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "cors");
    }
    if (std.mem.startsWith(u8, path, "/blk/") or std.mem.startsWith(u8, path, "/fl/") or std.mem.startsWith(u8, path, "/ctx/")) return reply(conn, "200 OK", html, "Access-Control-Allow-Origin: *\r\n", "<!doctype html><title>blk-reached</title>reached");
    if (std.mem.eql(u8, path, "/r/a")) return reply(conn, "301 Moved Permanently", "text/plain", "Location: /r/b\r\n", "");
    if (std.mem.eql(u8, path, "/r/b")) {
        const loc = std.fmt.bufPrint(&xb, "Location: http://localhost:{d}/blk/target\r\nAccess-Control-Allow-Origin: *\r\n", .{p}) catch return;
        return reply(conn, "302 Found", "text/plain", loc, "");
    }
    if (std.mem.eql(u8, path, "/r/nav")) return reply(conn, "302 Found", "text/plain", "Location: /blk/navtarget\r\n", "");
    if (std.mem.eql(u8, path, "/r/user")) return reply(conn, "302 Found", "text/plain", "Location: /blk/usertarget\r\n", "");
    if (std.mem.eql(u8, path, "/c/i.png")) return reply(conn, "200 OK", "image/svg+xml", "Cache-Control: max-age=600\r\n", svg);
    if (std.mem.eql(u8, path, "/p/mc")) return reply(conn, "200 OK", html, "Cache-Control: max-age=600\r\n", "<!doctype html><title>mc</title><img id=i src='/c/i.png'><script>window.addEventListener('pageshow',e=>{window.ps=(window.ps||'')+(e.persisted?'P':'N')})</script>");
    if (std.mem.eql(u8, path, "/p/pf")) return reply(conn, "200 OK", html, "", "<!doctype html><title>pf</title><link rel=prefetch href='/blk/pf'><script type=speculationrules>{\"prerender\":[{\"source\":\"list\",\"urls\":[\"/p/pr\"]}],\"prefetch\":[{\"source\":\"list\",\"urls\":[\"/p/spf\"]}]}</script><a id=a href='/p/pr'>pr</a>");
    if (std.mem.eql(u8, path, "/p/pr") or std.mem.eql(u8, path, "/p/spf")) return reply(conn, "200 OK", html, "", "<!doctype html><title>speculated</title>");
    // 페이지 맥락(localhost 맨 위·127.0.0.1 iframe·떠날 때의 비콘).
    if (std.mem.eql(u8, path, "/x/ctxtop")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>ctxtop</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data));addEventListener('pagehide',()=>navigator.sendBeacon('http://127.0.0.1:{d}/ctx/beacon'))</script><iframe src='http://127.0.0.1:{d}/p/ctxframe'></iframe>", .{ p, p }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/p/ctxframe")) return reply(conn, "200 OK", html, "", "<!doctype html><title>ctxframe</title><script>fetch('/ctx/b').then(r=>'ok '+r.status,e=>'reject '+e.name).then(t=>parent.postMessage('ctx:'+t,'*'))</script>");
    // 서비스 워커 쪽(어느 호스트든 — 출처마다 제 서비스 워커).
    if (std.mem.eql(u8, path, "/s/sw.js")) return reply(conn, "200 OK", "application/javascript", "", sw_js);
    if (std.mem.eql(u8, path, "/s/cached")) return reply(conn, "200 OK", "text/plain", "", "server-cached");
    if (std.mem.startsWith(u8, path, "/s/page")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>swpage</title>{s}<iframe id=inner src='/s/inner'></iframe><div id=t>{s}</div>", .{ sw_reg, target }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    // v20i(9 차 적대 검증): 머리에서 곧 부르는 하위 자원 넷(css·script·img·막을 img)과 파싱 중 fetch — 되살린 렌더러에 다시 보낸 우회가 이들보다 먼저인가.
    if (std.mem.eql(u8, path, "/s/zhead")) {
        const tag = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "none";
        const body = std.fmt.bufPrint(&bb, "<!doctype html><head><title>zhead</title>{s}<link rel=stylesheet href='/s/{s}-css'><script src='/s/{s}-js'></script><script>fetch('/s/{s}-early')</script></head><body><img src='/s/{s}-img'><img src='/s/{s}-blkimg'><div id=t>{s}</div></body>", .{ sw_reg, tag, tag, tag, tag, tag, target }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    // 9 차: 문서가 서자마자(파싱 중) 하위 자원을 부르는 서비스 워커 페이지 — 되살린 렌더러에 다시 보낸 우회 값이 첫 하위 자원보다 먼저 닿는가.
    if (std.mem.eql(u8, path, "/s/epage")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>swepage</title>{s}<script>fetch('/s/'+location.search.slice(1)+'-early')</script><div id=t>{s}</div>", .{ sw_reg, target }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/s/inner")) return reply(conn, "200 OK", html, "", "<!doctype html><title>inner</title>inner");
    if (std.mem.eql(u8, path, "/s/framed")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>framed</title>{s}<script>window.swready.then(s=>{{if(s==='controlled')fetch('/s/fromframe?'+Date.now()).then(r=>r.text()).then(t=>parent.postMessage('framed:'+t,'*'),e=>parent.postMessage('framed-reject:'+e.name,'*'))}})</script>", .{sw_reg}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.startsWith(u8, path, "/s/")) return reply(conn, "200 OK", "text/plain", "", target);
    if (std.mem.eql(u8, path, "/x/top")) {
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>xtop</title><script>window.msgs=[];addEventListener('message',e=>window.msgs.push(e.data))</script><iframe src='http://127.0.0.1:{d}/s/framed'></iframe>", .{p}) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/x/blank")) return reply(conn, "200 OK", html, "", "<!doctype html><title>xblank</title>x");
    return reply(conn, "200 OK", "text/plain", "", "x");
}

// ── 판정자(maru 역할) ──────────────────────────────────────────────────────────────────────────────────────

const max_tabs = 40;

const End = struct { browser: u64 = 0, request: u64 = 0, url: [256]u8 = undefined, url_len: usize = 0, ended: bool = false, flags: msg.NetEndFlags = .{}, rule: u32 = 0, error_code: i32 = 0 };
const Hit = struct { browser: u64, rule: u32, hits: u64 = 0, sw_hits: u64 = 0, sw_not_applied: u64 = 0 };
const ErrPage = struct { browser: u64, code: i32, rule: u32 };

const Run = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    next_call: u32 = 100,
    result: std.ArrayList(u8) = .empty,
    created: [max_tabs]bool = @splat(false),
    loads: [max_tabs]u32 = @splat(0),
    urls: [max_tabs]u32 = @splat(0),
    state_gen: [max_tabs]u32 = @splat(0),
    state_ok: [max_tabs]bool = @splat(false),
    strict: [max_tabs]msg.NetStrictState = @splat(.off),
    /// v20j: 받은 `failed` 엄격 상태 수(되살리는 중의 거짓 실패를 본다).
    failed_frames: [max_tabs]u32 = @splat(0),
    /// 12 차: 받은 `renderer_gone` 수 — kill 뒤 고정 시간 대신 sidecar 가 죽음을 알릴 때까지 기다린다(`zjKill`).
    gone: [max_tabs]u32 = @splat(0),
    /// 12 차: 받은 `browser_closed` 수 — 닫기 뒤 고정 시간 대신 실제로 닫힐 때까지 기다린다(`zjClose`).
    closed: [max_tabs]u32 = @splat(0),
    unrecorded: [max_tabs]u64 = @splat(0),
    skipped: [max_tabs]u64 = @splat(0),
    shared: [max_tabs]bool = @splat(false),
    redir_missed: [max_tabs]u64 = @splat(0),
    redir_bypassed: [max_tabs]u64 = @splat(0),
    reqs: std.ArrayList(End) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    errors: std.ArrayList(ErrPage) = .empty,
    downloads: u32 = 0,
    record_state: [max_tabs]msg.NetRecordStatus = @splat(.off),
    gen: u32 = 0,
    dialogs: std.ArrayList(msg.JsDialog) = .empty,

    fn take(self: *Run, m: msg.Message) void {
        switch (m) {
            .browser_created => |id| if (id < max_tabs) {
                self.created[id] = true;
            },
            .load_finished => |v| if (v.browser < max_tabs) {
                self.loads[v.browser] += 1;
            },
            .url_changed => |v| if (v.browser < max_tabs) {
                self.urls[v.browser] += 1;
            },
            .error_page => |v| self.errors.append(self.gpa, .{ .browser = v.browser, .code = v.error_code, .rule = v.blocked_rule }) catch {},
            .net_block_state => |v| if (v.browser < max_tabs) {
                self.state_gen[v.browser] = v.generation;
                self.state_ok[v.browser] = v.ok;
                self.strict[v.browser] = v.strict;
                if (v.strict == .failed) self.failed_frames[v.browser] += 1;
            },
            .net_block_hits => |v| if (v.browser < max_tabs) {
                self.unrecorded[v.browser] += v.unrecorded;
                self.skipped[v.browser] += v.skipped_unknown_page;
                self.redir_missed[v.browser] += v.strict_redirect_missed;
                self.redir_bypassed[v.browser] += v.strict_redirect_bypassed;
                if (v.sw_shared_with_unruled_tab) self.shared[v.browser] = true;
                for (v.entries[0..v.count]) |e| {
                    const h = for (self.hits.items) |*h| {
                        if (h.browser == v.browser and h.rule == e.rule_id) break h;
                    } else blk: {
                        self.hits.append(self.gpa, .{ .browser = v.browser, .rule = e.rule_id }) catch return;
                        break :blk &self.hits.items[self.hits.items.len - 1];
                    };
                    h.hits += e.hits;
                    h.sw_hits += e.sw_hits;
                    h.sw_not_applied += e.sw_not_applied;
                }
            },
            .net_begin => |v| {
                var e: End = .{ .browser = v.browser, .request = v.request };
                const n = @min(v.url.len, e.url.len);
                @memcpy(e.url[0..n], v.url[0..n]);
                e.url_len = n;
                self.reqs.append(self.gpa, e) catch {};
            },
            .net_end => |v| {
                var i = self.reqs.items.len;
                while (i > 0) {
                    i -= 1;
                    const e = &self.reqs.items[i];
                    if (e.browser == v.browser and e.request == v.request and !e.ended) {
                        e.ended = true;
                        e.flags = v.flags;
                        e.rule = v.rule_id;
                        e.error_code = v.error_code;
                        break;
                    }
                }
            },
            .download_begin => self.downloads += 1,
            .js_dialog => |v| self.dialogs.append(self.gpa, .{ .browser = v.browser, .request = v.request, .kind = v.kind, .origin = "", .message = "" }) catch {},
            .popup_created => |v| if (v.browser < max_tabs) {
                self.created[v.browser] = true;
            },
            .net_record_state => |v| if (v.browser < max_tabs) {
                self.record_state[v.browser] = v.status;
            },
            .renderer_gone => |v| if (v.browser < max_tabs) {
                self.gone[v.browser] += 1;
            },
            .browser_closed => |id| if (id < max_tabs) {
                self.closed[id] += 1;
            },
            else => {},
        }
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            const m = (self.host.next(20) catch null) orelse continue;
            self.take(m);
        }
    }

    fn until(self: *Run, comptime cond: fn (*Run, u64, u32) bool, b: u64, want: u32, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline and !cond(self, b, want)) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        return cond(self, b, want);
    }

    fn loadsAt(self: *Run, b: u64, want: u32) bool {
        return self.loads[b] >= want;
    }
    fn stateAt(self: *Run, b: u64, want: u32) bool {
        return self.state_gen[b] == want;
    }
    fn strictSettled(self: *Run, b: u64, want: u32) bool {
        return self.state_gen[b] == want and self.strict[b] != .off;
    }

    fn create(self: *Run, b: u64, u: []const u8) !void {
        try self.host.send(.{ .create_browser = .{ .browser = b, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = u } });
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline and !self.created[b]) {
            const m = (self.host.next(50) catch null) orelse continue;
            self.take(m);
        }
        _ = self.until(loadsAt, b, 1, wait_ms);
    }

    fn nav(self: *Run, b: u64, u: []const u8, user: bool) !void {
        const before = self.loads[b];
        try self.host.send(.{ .navigate = .{ .browser = b, .url = u, .user = user } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(150);
    }

    fn action(self: *Run, b: u64, a: msg.NavActionKind, user: bool) !void {
        const before = self.loads[b];
        try self.host.send(.{ .nav_action = .{ .browser = b, .action = a, .user = user } });
        _ = self.until(loadsAt, b, before + 1, wait_ms);
        self.pump(150);
    }

    fn watch(self: *Run, b: u64) !void {
        try self.host.send(.{ .net_watch = .{ .browser = b, .on = true, .full = true, .any_host = true } });
        self.pump(50);
    }

    /// 규칙(`pattern`·`site`·종류)을 통째로 보낸다 — 답(그 세대)을 기다린다. 엄격이면 엄격 상태가 정해질 때까지.
    fn block(self: *Run, b: u64, rules: []const msg.NetBlockRule, strict_site: []const u8) !bool {
        self.gen += 1;
        var v: msg.NetBlock = .{ .browser = b, .generation = self.gen, .strict_site = strict_site, .count = @intCast(rules.len) };
        for (rules, 0..) |r, i| v.rules[i] = r;
        try self.host.send(.{ .net_block = v });
        const got = if (strict_site.len != 0) self.until(strictSettled, b, self.gen, wait_ms) else self.until(stateAt, b, self.gen, wait_ms);
        return got and self.state_ok[b];
    }

    fn hitOf(self: *Run, b: u64, rule: u32) Hit {
        self.pump(80);
        for (self.hits.items) |h| if (h.browser == b and h.rule == rule) return h;
        return .{ .browser = b, .rule = rule };
    }

    /// 그 탭에서 주소에 그 글을 담은 마지막 요청의 끝.
    fn endOf(self: *Run, b: u64, needle: []const u8) ?End {
        var i = self.reqs.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.reqs.items[i];
            if (e.browser == b and std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) return e;
        }
        return null;
    }

    fn lastError(self: *Run, b: u64) ?ErrPage {
        var i = self.errors.items.len;
        while (i > 0) {
            i -= 1;
            if (self.errors.items[i].browser == b) return self.errors.items[i];
        }
        return null;
    }

    fn call(self: *Run, browser: u64, method: []const u8, params: []const u8, ms: u32) !?msg.DevtoolsStatus {
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
            const m = (self.host.next(50) catch null) orelse continue;
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

    /// 주 프레임에서 식을 돌려 글로(문자열·수·참거짓). 실패면 `<…>`.
    fn ev(self: *Run, browser: u64, expr: []const u8, out: []u8) []const u8 {
        return self.evAs(browser, expr, out, false);
    }

    /// `gesture` — 사용자 몸짓으로 돌린다(`window.open` 이 팝업을 만들게).
    fn evAs(self: *Run, browser: u64, expr: []const u8, out: []u8, gesture: bool) []const u8 {
        var pb: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&pb);
        w.writeAll(if (gesture) "{\"userGesture\":true,\"returnByValue\":true,\"awaitPromise\":true,\"expression\":" else "{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return "<arg>";
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
            .bool => |b| if (b) "true" else "false",
            .integer => |k| std.fmt.bufPrint(out, "{d}", .{k}) catch "<n>",
            .float => |f| std.fmt.bufPrint(out, "{d}", .{f}) catch "<n>",
            else => "<other>",
        };
    }
};

fn uLoop(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

fn uLocal(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://localhost:{d}{s}", .{ port, path }) catch unreachable;
}

/// 규칙 패턴(정규형 — 포트를 담는다).
fn pat(buf: []u8, host: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ host, port, path }) catch unreachable;
}

const js_fetch_head = "(async()=>{const t=performance.now();try{const r=await fetch(";
const js_fetch_tail = ");return 'ok '+r.status+' '+(await r.text()).slice(0,120)}catch(e){return 'reject '+e.name}})()";

fn fetchExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}'{s}'{s}", .{ js_fetch_head, u, js_fetch_tail }) catch unreachable;
}

fn imgExpr(buf: []u8, u: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "new Promise(res=>{{const i=new Image();i.onload=()=>res('load');i.onerror=()=>res('error');i.src='{s}';setTimeout(()=>res('timeout'),5000)}})", .{u}) catch unreachable;
}

fn starts(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn spawn(host_path: [:0]const u8, root: []const u8, name: []const u8, env: []const [*:0]const u8) !Host {
    var prof_buf: [1024]u8 = undefined;
    const profile = try std.fmt.bufPrintSentinel(&prof_buf, "--profile-dir={s}/{s}", .{ root, name }, 0);
    var host = try Host.spawnWith(host_path, profile, null, env);
    try browsers_check.handshake(&host);
    return host;
}

fn stop(host: *Host) void {
    host.send(.shutdown) catch {};
    while (host.next(2000) catch null) |_| {}
    if (host.wait(20_000) == null) {
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(10_000);
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// 3 차 검증(A3) 1·2·6·8·10 회차의 시나리오 — 보고 줄은 `A3-R<n>` 으로 시작한다. `A3_ONLY=r6,r8,r10,canon` 으로 고른다.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

extern "c" fn usleep(us: c_uint) c_int;

const url_canon = protocol.url_canon;
const nbp = protocol.net_block;

fn only(name: []const u8) bool {
    const v = std.c.getenv("A3_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    if (only("r6")) r6(report, host_path, root) catch |err| report(false, "A3-R6", @errorName(err));
    if (only("r8")) r8(report, host_path, root) catch |err| report(false, "A3-R8", @errorName(err));
    if (only("r10")) r10(report, host_path, root) catch |err| report(false, "A3-R10", @errorName(err));
    if (only("canon")) canon(report, host_path, root) catch |err| report(false, "A3-canon", @errorName(err));
}

/// `--review-block-v20a4`(4 차 검증 A4 — 6·8·10 회차): `A4_ONLY=r6,r10` 으로 고른다.
pub fn runA4(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    try startServer2();
    const sel = std.c.getenv("A4_ONLY");
    const want = struct {
        fn f(v: ?[*:0]const u8, name: []const u8) bool {
            const x = v orelse return true;
            return std.mem.indexOf(u8, std.mem.span(x), name) != null;
        }
    }.f;
    if (want(sel, "r6") or want(sel, "swh") or want(sel, "det") or want(sel, "bss")) a4r6(report, host_path, root) catch |err| report(false, "A4-R6", @errorName(err));
    if (want(sel, "r10") or want(sel, "skip") or want(sel, "cdpd")) a4r10(report, host_path, root) catch |err| report(false, "A4-R10", @errorName(err));
}

fn ctlOf(r: *Run, b: u64) []const u8 {
    var o: [64]u8 = undefined;
    const c = r.ev(b, "String(!!(navigator.serviceWorker&&navigator.serviceWorker.controller))", &o);
    return if (std.mem.eql(u8, c, "true")) "controlled" else if (std.mem.eql(u8, c, "false")) "bypassed" else "unknown";
}

fn swReady(r: *Run, b: u64) []const u8 {
    var o: [128]u8 = undefined;
    _ = r.ev(b, "window.swready", &o);
    _ = r.until(Run.loadsAt, b, r.loads[b] + 1, 3000);
    r.pump(400);
    return ctlOf(r, b);
}

/// `%L` → localhost origin, `%I` → 127.0.0.1 origin.
fn expand(buf: []u8, tmpl: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (i + 1 < tmpl.len and tmpl[i] == '%' and (tmpl[i + 1] == 'L' or tmpl[i + 1] == 'I')) {
            w.print("http://{s}:{d}", .{ if (tmpl[i + 1] == 'L') "localhost" else "127.0.0.1", port }) catch return "";
            i += 2;
            continue;
        }
        w.writeByte(tmpl[i]) catch return "";
        i += 1;
    }
    return w.buffered();
}

fn waitDialog(r: *Run, b: u64, from: usize, ms: u32) ?msg.JsDialog {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        for (r.dialogs.items[from..]) |dl| if (dl.browser == b) return dl;
        const m = (r.host.next(50) catch null) orelse continue;
        r.take(m);
    }
    for (r.dialogs.items[from..]) |dl| if (dl.browser == b) return dl;
    return null;
}

/// The agent's `browser.back` (web_cdp_ops): Page.getNavigationHistory then Page.navigateToHistoryEntry(currentIndex - 1).
fn cdpBack(r: *Run, b: u64) []const u8 {
    const st = r.call(b, "Page.getNavigationHistory", "{}", 5000) catch null;
    if (st == null or st.? != .ok) return "history-failed";
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return "history-unparsed";
    defer parsed.deinit();
    const ci = parsed.value.object.get("currentIndex") orelse return "no-index";
    const entries = parsed.value.object.get("entries") orelse return "no-entries";
    if (ci.integer < 1) return "at-start";
    const id = entries.array.items[@intCast(ci.integer - 1)].object.get("id").?.integer;
    var pb: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"entryId\":{d}}}", .{id}) catch return "fmt";
    const st2 = r.call(b, "Page.navigateToHistoryEntry", params, 5000) catch null;
    return if (st2 != null and st2.? == .ok) "sent" else "nav-failed";
}

/// A click at view coordinates through CDP Input (gives the frame under the point a real user activation).
fn click(r: *Run, b: u64, xx: u32, yy: u32) void {
    var pb: [200]u8 = undefined;
    for ([_][]const u8{ "mousePressed", "mouseReleased" }) |t| {
        const params = std.fmt.bufPrint(&pb, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ t, xx, yy }) catch return;
        _ = r.call(b, "Input.dispatchMouseEvent", params, 5000) catch null;
    }
}

fn createNoWait(r: *Run, b: u64, u: []const u8, settle_ms: u32) !void {
    try r.host.send(.{ .create_browser = .{ .browser = b, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = u } });
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline and !r.created[b]) {
        const m = (r.host.next(50) catch null) orelse continue;
        r.take(m);
    }
    r.pump(settle_ms);
}

fn endsFor(r: *Run, needle: []const u8, dd: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(dd);
    for (r.reqs.items) |e| if (std.mem.indexOf(u8, e.url[0..e.url_len], needle) != null) {
        w.print("[b{d} {s} ended {} blocked {} rule {d} err {d}] ", .{ e.browser, e.url[0..@min(e.url_len, 70)], e.ended, e.flags.blocked, e.rule, e.error_code }) catch break;
    };
    return w.buffered();
}

fn errOf(r: *Run, b: u64, from: usize) ?ErrPage {
    var i = r.errors.items.len;
    while (i > from) {
        i -= 1;
        if (r.errors.items[i].browser == b) return r.errors.items[i];
    }
    return null;
}

// ── R6: sw_share.role after MED-A2-1 ───────────────────────────────────────────────────────────────────────

fn r6(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a3_sw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var o3: [600]u8 = undefined;
    var d: [2000]u8 = undefined;
    var p5: [128]u8 = undefined;
    const broad = [_]msg.NetBlockRule{ .{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }, .{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" } };

    // R6-1: a ruled tab A on localhost whose iframe navigation to 127.0.0.1 never committed (204, download, empty response). Does the
    // in-progress subframe record keep A "showing" 127.0.0.1 — covering it (empty T broken) and charging A for B's requests?
    // `reload` — 규칙을 넣은 뒤 A 를 다시 불러 iframe 이동이 그 규칙 아래에서 일어나게(검증자 판의 이 갈래는 규칙 앞에 iframe 이 이미 섰다 — 실측
    // probe: 그 iframe 은 200 으로 섰고 막히지 않았다, A 는 정말 그 출처를 보였다).
    // `remove` — 이동 중인 iframe 을 지운다(떨어져 나감 — 3 차 고침의 변이 판에 더했다: `on_frame_detached` 가 놓지 않으면 하위 프레임 받침 10 초 동안
    // 그 탭이 「보였다」).
    const Var = struct { label: []const u8, src: []const u8, positive: bool = false, reload: bool = false, remove: bool = false };
    const vars = [_]Var{
        .{ .label = "control: no iframe", .src = "" },
        .{ .label = "iframe 204", .src = "/n204?a3" },
        .{ .label = "iframe download", .src = "/dl/a3.bin" },
        .{ .label = "iframe empty response", .src = "/a3/close" },
        .{ .label = "iframe blocked by A's own rule 42 (-20)", .src = "/blkifr?a3", .reload = true },
        .{ .label = "iframe removed while its navigation hangs", .src = "/x/hang?a3rm", .remove = true },
        .{ .label = "positive: committed 127 iframe", .src = "/p/sub?a3ok", .positive = true },
    };
    var id: u64 = 10;
    for (vars) |v| {
        const b = id;
        const a = id + 1;
        id += 2;
        try r.create(b, uLoop(&u, "/s/page?B3"));
        const bctl = swReady(&r, b);
        var ab: [256]u8 = undefined;
        const a_url = if (v.src.len == 0) uLocal(&ab, "/x/blank?A3") else std.fmt.bufPrint(&ab, "http://localhost:{d}/a3/ifr?s={s}", .{ port, v.src }) catch unreachable;
        try r.create(a, a_url);
        r.pump(800);
        try r.watch(a);
        const ok = try r.block(a, &broad, "");
        if (v.reload) {
            _ = r.ev(a, "(location.reload(),'reloading')", &o);
            r.pump(1000);
        }
        if (v.remove) {
            _ = r.ev(a, "(document.getElementById('f').remove(),'removed')", &o);
            r.pump(300);
        }
        var fo: [200]u8 = undefined;
        const fr = r.ev(a, "String(window.frames.length)+' '+(window.frames[0]?(()=>{try{return window.frames[0].location.href}catch(e){return 'cross-origin'}})():'-')", &fo);
        const got = r.ev(b, fetchExpr(&x, "/s/swlate-a3"), &o);
        r.pump(500);
        const h1 = r.hitOf(a, 41);
        const shared1 = r.shared[a];
        const s0 = seen("/s/swlate?sw=");
        _ = r.ev(b, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o2);
        r.pump(100);
        try r.host.send(.{ .destroy_browser = b });
        r.pump(3000);
        const h2 = r.hitOf(a, 41);
        const reached = seen("/s/swlate?sw=") - s0;
        const pass = if (v.positive) (reached == 0 and h1.sw_not_applied == 1) else (reached == 1 and h1.sw_not_applied == 0 and !shared1 and h2.sw_hits == 0);
        report(pass, "A3-R6-stale-subframe", std.fmt.bufPrint(&d, "{s}: B {s} · A (ruled {}, localhost, frames {s}) · B fetch /s/swlate-a3 → {s} · A sw_not_applied {d} shared {} · B closed, SW late fetch → server +{d} · A sw_hits {d} (want {s})", .{ v.label, bctl, ok, fr, got[0..@min(got.len, 30)], h1.sw_not_applied, shared1, reached, h2.sw_hits, if (v.positive) "server +0, not_applied 1: A really shows 127.0.0.1" else "server +1, 0/false: A does not show 127.0.0.1 — empty T" }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        r.pump(800);
    }

    // R6-2: in-progress table overflow (ten hanging iframes — 8 s, on localhost).
    {
        const a: u64 = 21;
        try r.create(a, uLoop(&u, "/s/page?A21"));
        const actl = swReady(&r, a);
        try r.watch(a);
        _ = try r.block(a, &.{.{ .id = 51, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/s/swblk*") }}, "");
        const base = r.ev(a, fetchExpr(&x, "/s/swblk-ov0"), &o);
        // (a) the ruled tab itself (shows 127.0.0.1) overflows: navigate a sibling tab? — no: A's own frames. A2 navigates to /s/hang10.
        const a2: u64 = 22;
        try createNoWait(&r, a2, uLoop(&u, "/s/hang10?A22"), 1500);
        try r.watch(a2);
        _ = try r.block(a2, &.{.{ .id = 52, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/s/swblk*") }}, "");
        r.pump(300);
        const s_a = seen("/s/swblk-ov1");
        const with_self = r.ev(a, fetchExpr(&x, "/s/swblk-ov1"), &o2);
        r.pump(400);
        const h52 = r.hitOf(a2, 52);
        const h51 = r.hitOf(a, 51);
        report(starts(with_self, "reject") and seen("/s/swblk-ov1") == s_a, "A3-R6-overflow-ruled-showing", std.fmt.bufPrint(&d, "A {s} (rule 51) baseline {s} · A22 on 127.0.0.1/s/hang10 (ruled 52, ten hanging localhost iframes → in-progress table overflow) · A fetch /s/swblk-ov1 → {s} server +{d} · A sw_hits {d} not_applied {d} · A22 sw_hits {d} not_applied {d} (want blocked: a tab proven to show O that holds a rule covers — MED-2)", .{ actl, base[0..@min(base.len, 20)], with_self[0..@min(with_self.len, 20)], seen("/s/swblk-ov1") - s_a, h51.sw_hits, h51.sw_not_applied, h52.sw_hits, h52.sw_not_applied }) catch "");
        try r.host.send(.{ .destroy_browser = a2 });
        r.pump(800);
        // (b) unruled Z on localhost overflows (does not show 127.0.0.1) → veto, counted.
        const z: u64 = 23;
        try createNoWait(&r, z, uLocal(&u, "/a3/hang10?Z"), 1500);
        const h0 = r.hitOf(a, 51);
        const withz = r.ev(a, fetchExpr(&x, "/s/swblk-ov2"), &o3);
        r.pump(400);
        const hz = r.hitOf(a, 51);
        report(starts(withz, "ok") and hz.sw_not_applied == h0.sw_not_applied + 1, "A3-R6-overflow-unruled-veto", std.fmt.bufPrint(&d, "unruled Z (localhost, in-progress table overflow) · A fetch /s/swblk-ov2 → {s} · A sw_not_applied +{d} (want not blocked, +1: unknown unruled tab vetoes — documented)", .{ withz[0..@min(withz.len, 20)], hz.sw_not_applied - h0.sw_not_applied }) catch "");
        try r.host.send(.{ .destroy_browser = z });
        r.pump(800);
        // (c) ruled Z' on localhost overflows → documented: an overflowed ruled tab counts as unruled (veto), counted.
        const z2: u64 = 24;
        try createNoWait(&r, z2, uLocal(&u, "/a3/hang10?Z2"), 1500);
        try r.watch(z2);
        _ = try r.block(z2, &.{.{ .id = 53, .site = "localhost", .pattern = "*://*/s/swblk*" }}, "");
        r.pump(200);
        const h3 = r.hitOf(a, 51);
        const withz2 = r.ev(a, fetchExpr(&x, "/s/swblk-ov3"), &o3);
        r.pump(400);
        const hz2 = r.hitOf(a, 51);
        const h53 = r.hitOf(z2, 53);
        report(starts(withz2, "ok") and hz2.sw_not_applied == h3.sw_not_applied + 1 and h53.sw_not_applied == 0, "A3-R6-overflow-ruled-other-veto", std.fmt.bufPrint(&d, "ruled Z' (localhost, broad rule 53, overflow, does not show 127.0.0.1) · A fetch /s/swblk-ov3 → {s} · A sw_not_applied +{d} · Z' sw_hits {d} not_applied {d} (want not blocked, A +1, Z' 0: overflowed ruled tab = veto — documented)", .{ withz2[0..@min(withz2.len, 20)], hz2.sw_not_applied - h3.sw_not_applied, h53.sw_hits, h53.sw_not_applied }) catch "");
        try r.host.send(.{ .destroy_browser = z2 });
        r.pump(800);
        // R6-3: popups the ruled tab opens — about:blank and blob: (origin 127.0.0.1, URL not http). Are their requests SW-controlled, and if so blocked by A's rule?
        try r.host.send(.{ .popup_reserve = .{ .browser = 25 } });
        try r.host.send(.{ .new_tab_credit = a });
        r.pump(100);
        _ = r.evAs(a, "(window.w=window.open('','_blank','popup,width=300,height=300'),'opened')", &o, true);
        r.pump(1500);
        var pc_b: [200]u8 = undefined;
        const pc = r.ev(a, "String(!!(window.w&&w.navigator.serviceWorker&&w.navigator.serviceWorker.controller))+' '+String(window.w&&w.location.href)", &pc_b);
        const s_p = seen("/s/swblk-pop1");
        const hp0 = r.hitOf(a, 51);
        var pf_b: [200]u8 = undefined;
        const pf = r.ev(a, "(async()=>{try{const r=await w.fetch('/s/swblk-pop1');return 'ok '+r.status}catch(e){return 'reject '+e.name}})()", &pf_b);
        var pk_b: [200]u8 = undefined;
        const pk = r.ev(a, "(async()=>{try{const r=await w.fetch('/s/okpop');return 'ok '+r.status}catch(e){return 'reject '+e.name}})()", &pk_b);
        // N-A3-5: 팝업 제 문맥(그 창의 eval — 연 탭의 스크립트 함수가 아니다)에서 낸 요청도 같은가.
        const s_p2 = seen("/s/swblk-pop2");
        var pe_b: [200]u8 = undefined;
        const pe = r.ev(a, "(async()=>{try{const r=await w.eval(\"fetch('/s/swblk-pop2')\");return 'ok '+r.status}catch(e){return 'reject '+e.name}})()", &pe_b);
        r.pump(400);
        const hp1 = r.hitOf(a, 51);
        var lb: [600]u8 = undefined;
        const pline = lastSeen("/s/swblk-pop1", &lb);
        var eb: [600]u8 = undefined;
        // N-A3-5(문서화한 동작 — 실측): 연 탭의 about:blank 팝업(연 탭의 출처를 물려받은 첫 문서)이 낸 요청은 연 탭의 스크립트가 부른 것이든 팝업 제
        // 문맥의 것이든 CEF 가 연 탭의 요청으로 보내 연 탭의 규칙이 막는다 — `window.open('')` 으로 막기를 비켜 가지 못한다. 막히지 않는 주소는 지나간다.
        const popup_ok = r.created[25] and (starts(pf, "reject") and starts(pe, "reject") and seen("/s/swblk-pop1") == s_p and seen("/s/swblk-pop2") == s_p2 and starts(pk, "ok") and hp1.hits >= hp0.hits + 2);
        report(popup_ok, "A3-R6-popup-about-blank", std.fmt.bufPrint(&d, "A (ruled 51) opened about:blank popup: controlled/url {s} · popup fetch /s/swblk-pop1 → {s} · server +{d} line '{s}' · A rule 51 hits +{d} sw_hits +{d} · A-recorded ends {s} · control popup fetch /s/okpop → {s} (server {d}) · popup's own realm (w.eval) fetch /s/swblk-pop2 → {s} server +{d} · popup created {} (want both blocked by the opener's rule, control passes)", .{ pc, pf, seen("/s/swblk-pop1") - s_p, std.mem.trim(u8, pline, "\n"), hp1.hits - hp0.hits, hp1.sw_hits - hp0.sw_hits, endsFor(&r, "swblk-pop1", &eb), pk, seen("/s/okpop"), pe, seen("/s/swblk-pop2") - s_p2, r.created[25] }) catch "");
        try r.host.send(.{ .destroy_browser = 25 });
        r.pump(600);
        try r.host.send(.{ .popup_reserve = .{ .browser = 26 } });
        try r.host.send(.{ .new_tab_credit = a });
        r.pump(100);
        var bj: [1200]u8 = undefined;
        const blob_js = std.fmt.bufPrint(&bj, "(window.blobres='pending',window.w2=window.open(URL.createObjectURL(new Blob(['<!doctype html><script>const ctl=String(!!(navigator.serviceWorker&&navigator.serviceWorker.controller));fetch(\"http://127.0.0.1:{d}/s/swblk-blob\").then(r=>opener.blobres=ctl+\" ok \"+r.status,e=>opener.blobres=ctl+\" reject \"+e.name)</scr'+'ipt>'],{{type:'text/html'}})),'_blank','popup,width=300,height=300'),'opened')", .{port}) catch unreachable;
        const s_b = seen("/s/swblk-blob");
        _ = r.evAs(a, blob_js, &o, true);
        r.pump(2000);
        var br_b: [200]u8 = undefined;
        const br = r.ev(a, "String(window.blobres)", &br_b);
        var lb2: [600]u8 = undefined;
        const bline = lastSeen("/s/swblk-blob", &lb2);
        report(true, "A3-R6-popup-blob(obs)", std.fmt.bufPrint(&d, "A (ruled 51) opened a blob: popup: controlled+fetch /s/swblk-blob → {s} · server +{d} line '{s}' · popup created {}", .{ br, seen("/s/swblk-blob") - s_b, std.mem.trim(u8, bline, "\n"), r.created[26] }) catch "");
        try r.host.send(.{ .destroy_browser = 26 });
        r.pump(600);
        try r.host.send(.{ .destroy_browser = a });
        r.pump(800);
    }

    // R6-5: a navigation INTO the rule's site from another site, to a URL the site's service worker controls (the navigation request
    // goes through the SW path). The rule was added while the tab was on that site (site 127.0.0.1). Tab path equivalent: blocked (-20).
    {
        const n: u64 = 29;
        try r.create(n, uLoop(&u, "/s/page?N29"));
        const nctl = swReady(&r, n);
        try r.watch(n);
        var p6: [128]u8 = undefined;
        _ = try r.block(n, &.{ .{ .id = 81, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/s/swblk*") }, .{ .id = 82, .site = "127.0.0.1", .pattern = pat(&p6, "127.0.0.1", "/blkout*") } }, "");
        const Way = struct { label: []const u8, start: []const u8, agent: bool, target: []const u8 };
        for ([_]Way{
            .{ .label = "control: agent navigate from 127.0.0.1/x/blank", .start = "/x/blank?n0", .agent = true, .target = "/s/swblknav0" },
            .{ .label = "agent navigate from localhost/x/blank", .start = "L", .agent = true, .target = "/s/swblknav1" },
            .{ .label = "page location.href from localhost/x/blank", .start = "L", .agent = false, .target = "/s/swblknav2" },
            .{ .label = "tab-path equivalent: agent navigate from localhost to a URL outside the SW scope", .start = "L", .agent = true, .target = "/blkout/x" },
        }) |w| {
            if (std.mem.eql(u8, w.start, "L")) try r.nav(n, uLocal(&u, "/x/blank?nL"), false) else try r.nav(n, uLoop(&u, w.start), false);
            r.pump(300);
            const e0 = r.errors.items.len;
            const s0 = seen(w.target);
            const loads0 = r.loads[n];
            var tu: [256]u8 = undefined;
            const target_url = uLoop(&tu, w.target);
            if (w.agent) {
                try r.host.send(.{ .navigate = .{ .browser = n, .url = target_url } });
            } else {
                var jb: [400]u8 = undefined;
                _ = r.ev(n, std.fmt.bufPrint(&jb, "(location.href='{s}','sent')", .{target_url}) catch unreachable, &o);
            }
            _ = r.until(Run.loadsAt, n, loads0 + 1, 6000);
            r.pump(600);
            const e = errOf(&r, n, e0);
            var lb: [600]u8 = undefined;
            const line = lastSeen(w.target, &lb);
            const h = r.hitOf(n, 81);
            // 5 차 고침(LOW-1)이 귀속을 이동 자체로 판정한 요청으로 거르므로 귀속도 단언한다(서비스 워커 범위 이동은 -2·규칙 81, 범위 밖은 -20·규칙 82).
            const want_rule: u32 = if (std.mem.startsWith(u8, w.target, "/blkout")) 82 else 81;
            report(seen(w.target) == s0 and e != null and e.?.rule == want_rule, "A3-R6-sw-nav-entering-site", std.fmt.bufPrint(&d, "{s} (tab {s}, rule 81 site 127.0.0.1 /s/swblk* + /blkout via pattern? see target): server +{d} line '{s}' · error page {?d} rule {?d} · rule 81 hits {d} sw_hits {d} not_applied {d} (want blocked)", .{ w.label, nctl, seen(w.target) - s0, std.mem.trim(u8, line, "\n"), if (e) |q| q.code else null, if (e) |q| q.rule else null, h.hits, h.sw_hits, h.sw_not_applied }) catch "");
        }
        try r.host.send(.{ .destroy_browser = n });
        r.pump(800);
    }

    // R6-4: counts exact across a redirect hop on the SW path — one request, not_applied counted once?
    {
        const b: u64 = 27;
        const a: u64 = 28;
        try r.create(b, uLoop(&u, "/s/page?B27"));
        const bctl = swReady(&r, b);
        try r.create(a, uLoop(&u, "/s/page?A28"));
        const actl = swReady(&r, a);
        try r.watch(a);
        _ = try r.block(a, &.{.{ .id = 71, .site = "127.0.0.1", .pattern = pat(&p5, "127.0.0.1", "/s/swr*") }}, "");
        const h0 = r.hitOf(a, 71);
        const got = r.ev(b, fetchExpr(&x, "/s/swr1"), &o);
        r.pump(500);
        const h1 = r.hitOf(a, 71);
        const got2 = r.ev(b, fetchExpr(&x, "/s/swr2?direct"), &o2);
        r.pump(500);
        const h2 = r.hitOf(a, 71);
        report(h1.sw_not_applied - h0.sw_not_applied == 1, "A3-R6-not-applied-per-request", std.fmt.bufPrint(&d, "B {s} unruled, A {s} ruled 71 (/s/swr*) both on 127.0.0.1 · B fetch /s/swr1 (302 → /s/swr2, one request, both hops match) → {s} · A sw_not_applied +{d} · control B fetch /s/swr2?direct (no hop) → {s} · +{d} (want +1 per request)", .{ bctl, actl, got[0..@min(got.len, 24)], h1.sw_not_applied - h0.sw_not_applied, got2[0..@min(got2.len, 24)], h2.sw_not_applied - h1.sw_not_applied }) catch "");
        try r.host.send(.{ .destroy_browser = b });
        try r.host.send(.{ .destroy_browser = a });
        r.pump(800);
    }
}

// ── R8: strict redirect counting bound to the navigation's document ─────────────────────────────────────────

fn r8(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a3_strict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [1024]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [1600]u8 = undefined;
    var p1: [128]u8 = undefined;
    try r.create(1, uLocal(&u, "/s/page?Lreg"));
    const l_reg = swReady(&r, 1);
    _ = r.ev(1, "(sessionStorage.rl=1,'ok')", &o);
    try r.nav(1, uLoop(&u, "/s/page?Ireg"), false);
    const i_reg = swReady(&r, 1);
    _ = r.ev(1, "(sessionStorage.rl=1,'ok')", &o);
    try r.watch(1);
    const rules = [_]msg.NetBlockRule{.{ .id = 31, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/s/st*") }};
    const on = try r.block(1, &rules, "127.0.0.1");
    report(on, "A3-R8-setup", std.fmt.bufPrint(&d, "SW localhost {s} · 127.0.0.1 {s} · strict on {} state {s}", .{ l_reg, i_reg, on, @tagName(r.strict[1]) }) catch "");

    const Case = struct {
        name: []const u8,
        start: []const u8,
        dest: []const u8,
        page: bool = false,
        want_missed: u64 = 0,
        want_bypassed: u64 = 0,
        lands: bool = true,
    };
    const cases = [_]Case{
        .{ .name = "K1 fragment on the start URL (inherited by the redirect target)", .start = "%L/x/blank?k1", .dest = "%L/r/go?to=%I/s/inner?k1#frag", .want_missed = 1 },
        .{ .name = "K2 crossing whose target closes without a response (error page)", .start = "%L/x/blank?k2", .dest = "%L/r/go?to=%I/a3/close", .lands = false },
        .{ .name = "K3 crossing whose target is blocked by the tab's rule (-20)", .start = "%L/x/blank?k3", .dest = "%L/r/go?to=%I/s/stblk", .lands = false },
        .{ .name = "K4 crossing whose landed page location.replace()s itself (same site — one landed crossing)", .start = "%L/x/blank?k4", .dest = "%L/r/go?to=%I/a3/replace", .want_missed = 1 },
        .{ .name = "K5 POST 307 crossing (form)", .start = "%L/x/blank?k5", .dest = "", .page = true, .want_missed = 1 },
    };
    var wrong: usize = 0;
    for (cases) |c| {
        var sb: [256]u8 = undefined;
        try r.nav(1, expand(&sb, c.start), false);
        r.pump(300);
        const m0 = r.redir_missed[1];
        const b0 = r.redir_bypassed[1];
        const e0 = r.errors.items.len;
        const loads0 = r.loads[1];
        var db: [512]u8 = undefined;
        if (c.page) {
            // a form POST to /r/go307 → 307 to 127.0.0.1 (method kept)
            const js = std.fmt.bufPrint(&x, "(()=>{{const f=document.createElement('form');f.method='POST';f.action='http://localhost:{d}/a3/r307';const i=document.createElement('input');i.name='a';i.value='1';f.appendChild(i);document.body.appendChild(f);f.submit();return 'ok'}})()", .{port}) catch unreachable;
            _ = r.ev(1, js, &o);
        } else try r.host.send(.{ .navigate = .{ .browser = 1, .url = expand(&db, c.dest) } });
        _ = r.until(Run.loadsAt, 1, loads0 + 1, 6000);
        r.pump(900);
        var lb: [200]u8 = undefined;
        const at = r.ev(1, "location.host+location.pathname+location.search+location.hash", &lb);
        const dm = r.redir_missed[1] - m0;
        const dbp = r.redir_bypassed[1] - b0;
        const e = errOf(&r, 1, e0);
        const ok = dm == c.want_missed and dbp == c.want_bypassed;
        if (!ok) wrong += 1;
        report(ok, "A3-R8-count", std.fmt.bufPrint(&d, "{s}: at {s} · error page {?d} rule {?d} · missed +{d} (want {d}) · bypassed +{d} (want {d})", .{ c.name, at, if (e) |v| v.code else null, if (e) |v| v.rule else null, dm, c.want_missed, dbp, c.want_bypassed }) catch "");
    }

    // K6: two crossings in a row, each landing → exactly +2.
    {
        const m0 = r.redir_missed[1];
        var db: [512]u8 = undefined;
        for ([_][]const u8{ "%L/r/go?to=%I/s/inner?k6a", "%L/r/go?to=%I/s/inner?k6b" }) |dest| {
            var sb: [256]u8 = undefined;
            try r.nav(1, expand(&sb, "%L/x/blank?k6"), false);
            r.pump(200);
            const loads0 = r.loads[1];
            try r.host.send(.{ .navigate = .{ .browser = 1, .url = expand(&db, dest) } });
            _ = r.until(Run.loadsAt, 1, loads0 + 1, 6000);
            r.pump(700);
        }
        report(r.redir_missed[1] - m0 == 2, "A3-R8-two-crossings", std.fmt.bufPrint(&d, "two landed in-crossings → missed +{d} (want 2)", .{r.redir_missed[1] - m0}) catch "");
    }

    // K7: a crossing is in flight (target slow) when the user goes back to a document with the SAME URL as the crossing's target —
    // restored from the back/forward cache (no new network navigation). The restored document is not the crossing's document.
    {
        var sb: [256]u8 = undefined;
        var db: [512]u8 = undefined;
        const Way = enum { user_back, agent_back, none };
        for ([_]Way{ .none, .user_back, .agent_back }) |way| {
            var tb: [64]u8 = undefined;
            const tag = std.fmt.bufPrint(&tb, "?k7{s}", .{@tagName(way)}) catch unreachable;
            var t1: [128]u8 = undefined;
            try r.nav(1, expand(&sb, std.fmt.bufPrint(&t1, "%I/a3/bfslow{s}", .{tag}) catch unreachable), false);
            r.pump(300);
            try r.nav(1, expand(&sb, "%L/x/blank?k7"), false);
            r.pump(300);
            const m0 = r.redir_missed[1];
            const b0 = r.redir_bypassed[1];
            const loads0 = r.loads[1];
            var dt: [160]u8 = undefined;
            const dest = expand(&db, std.fmt.bufPrint(&dt, "%L/r/go?to=%I/a3/bfslow{s}", .{tag}) catch unreachable);
            var js_b: [600]u8 = undefined;
            _ = r.ev(1, std.fmt.bufPrint(&js_b, "(location.href='{s}','ok')", .{dest}) catch unreachable, &o);
            r.pump(500); // the redirect hop has happened; the target answers after 1.5 s
            var how: []const u8 = "none";
            switch (way) {
                .user_back => {
                    try r.host.send(.{ .nav_action = .{ .browser = 1, .action = .back, .user = true } });
                    how = "user back";
                },
                .agent_back => how = cdpBack(&r, 1),
                .none => {},
            }
            _ = r.until(Run.loadsAt, 1, loads0 + 1, 6000);
            r.pump(2500);
            var lb: [200]u8 = undefined;
            const at = r.ev(1, "location.host+location.pathname+location.search+' ps='+String(window.ps)", &lb);
            const dm = r.redir_missed[1] - m0;
            const dbp = r.redir_bypassed[1] - b0;
            const restored = std.mem.indexOf(u8, at, "P") != null;
            const want: u64 = if (way == .none) 1 else 0;
            const ok = dm == want and dbp == 0;
            report(ok, "A3-R8-bfcache-same-url", std.fmt.bufPrint(&d, "{s}: crossing localhost→302→127.0.0.1/a3/bfslow in flight, then {s} → at {s} (restored from bfcache {}) · missed +{d} (want {d}) · bypassed +{d}", .{ @tagName(way), how, at, restored, dm, want, dbp }) catch "");
        }
    }

    // K8 (observation): strict turned off and on again while a crossing navigation (started with strict on) is in its first hop.
    {
        var sb: [256]u8 = undefined;
        var db: [512]u8 = undefined;
        try r.nav(1, expand(&sb, "%L/x/blank?k8"), false);
        r.pump(300);
        const m0 = r.redir_missed[1];
        const loads0 = r.loads[1];
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = expand(&db, "%L/r/slowgo?to=%I/s/inner?k8") } });
        r.pump(400);
        const off = try r.block(1, &rules, "");
        const on2 = try r.block(1, &rules, "127.0.0.1");
        _ = r.until(Run.loadsAt, 1, loads0 + 1, 6000);
        r.pump(800);
        const ctl = ctlOf(&r, 1);
        report(true, "A3-R8-off-on-mid-navigation(obs)", std.fmt.bufPrint(&d, "strict on at the start, off ({}) and on ({}) during the slow first hop, then 302 → 127.0.0.1: {s} · missed +{d}", .{ off, on2, ctl, r.redir_missed[1] - m0 }) catch "");
    }
}

// ── R10: D2 tokens after LOW-A2-3/LOW-A2-4 ─────────────────────────────────────────────────────────────────

fn r10(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a3_d2", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var d: [1600]u8 = undefined;
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};

    // T1: a user back that pops only a SAME-DOCUMENT iframe entry (iframe pushState with activation) — no on_before_browse anywhere, no
    // main-frame address change. Does the 1 s history token stay for the page's own history.go(-1)?
    {
        const Arm = struct { label: []const u8, user_back: bool, go: []const u8, tab: u64, first: []const u8 };
        for ([_]Arm{
            .{ .label = "control: no user back, page history.go(-2)", .user_back = false, .go = "-2", .tab = 2, .first = "/blk/sd2" },
            .{ .label = "check: user back alone (no page navigation) only pops the iframe entry", .user_back = true, .go = "0", .tab = 14, .first = "/blk/sd14" },
            .{ .label = "attack: user back pops the iframe pushState entry, page history.go(-1) 400 ms later", .user_back = true, .go = "-1", .tab = 1, .first = "/blk/sd1" },
        }) |v| {
            try r.create(v.tab, uLoop(&u, v.first));
            try r.nav(v.tab, uLoop(&u, "/a3/sdi"), false);
            r.pump(300);
            var gb0: [64]u8 = undefined;
            _ = r.evAs(v.tab, "(document.getElementById('f').contentWindow.history.pushState({},'','?s2'),'ok')", &gb0, true);
            r.pump(400);
            var hb: [100]u8 = undefined;
            const before = r.ev(v.tab, "String(history.length)+' iframe='+document.getElementById('f').contentWindow.location.search", &hb);
            var bcopy: [100]u8 = undefined;
            const bc = bcopy[0..@min(bcopy.len, before.len)];
            @memcpy(bc, before[0..bc.len]);
            try r.watch(v.tab);
            _ = try r.block(v.tab, &rules, "");
            const c0 = seen(v.first);
            const e0 = r.errors.items.len;
            var js: [200]u8 = undefined;
            if (!std.mem.eql(u8, v.go, "0")) _ = r.ev(v.tab, std.fmt.bufPrint(&js, "(setTimeout(()=>history.go({s}),400),'armed')", .{v.go}) catch unreachable, &o);
            if (v.user_back) try r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .back, .user = true } });
            r.pump(2500);
            const e = errOf(&r, v.tab, e0);
            var lb: [200]u8 = undefined;
            const at = r.ev(v.tab, "location.pathname+' '+document.title+' iframe='+(document.getElementById('f')?document.getElementById('f').contentWindow.location.search:'none')", &lb);
            report(seen(v.first) == c0, "A3-R10-samedoc-iframe-back-steal", std.fmt.bufPrint(&d, "{s}: before {s} · server +{d} · error page {?d} rule {?d} · at {s} (want blocked: the page's history move is not the user's)", .{ v.label, bc, seen(v.first) - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
        }
        // T1b: main frame pushState of the SAME URL (user activation), user back = same-document traversal to the same URL.
        try r.create(3, uLoop(&u, "/blk/sm3"));
        try r.nav(3, uLoop(&u, "/a3/same"), false);
        r.pump(300);
        click(&r, 3, 60, 60);
        r.pump(300);
        var hb: [100]u8 = undefined;
        const before = r.ev(3, "String(history.length)+' pushed='+String(window.pushed)", &hb);
        var bcopy: [100]u8 = undefined;
        const bc = bcopy[0..@min(bcopy.len, before.len)];
        @memcpy(bc, before[0..bc.len]);
        try r.watch(3);
        _ = try r.block(3, &rules, "");
        const c0 = seen("/blk/sm3");
        const e0 = r.errors.items.len;
        const url0 = r.urls[3];
        _ = r.ev(3, "(setTimeout(()=>history.go(-1),400),'armed')", &o);
        try r.host.send(.{ .nav_action = .{ .browser = 3, .action = .back, .user = true } });
        r.pump(2500);
        const e = errOf(&r, 3, e0);
        report(seen("/blk/sm3") == c0, "A3-R10-samedoc-sameurl-back-steal", std.fmt.bufPrint(&d, "before {s} · user back (same document, same URL — url_changed +{d}) then page history.go(-1) → server +{d} · error page {?d} rule {?d} (want blocked)", .{ bc, r.urls[3] - url0, seen("/blk/sm3") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
    }

    // T2: a beforeunload handler that runs long WITHOUT a dialog — the user's own navigation starts after the token lifetime.
    {
        const Busy = struct { label: []const u8, tab: u64, start: []const u8, first: []const u8 = "", kind: enum { reload, back, typed }, target: []const u8 };
        const vs = [_]Busy{
            .{ .label = "reload, handler 0 ms (control)", .tab = 4, .start = "/blk/busyr0?ms=0", .kind = .reload, .target = "/blk/busyr0" },
            .{ .label = "reload, handler 2 s", .tab = 5, .start = "/blk/busyr2?ms=2000", .kind = .reload, .target = "/blk/busyr2" },
            .{ .label = "back, handler 2 s", .tab = 6, .first = "/blk/hbk6", .start = "/a3/busy?ms=2000", .kind = .back, .target = "/blk/hbk6" },
            .{ .label = "typed, handler 6 s", .tab = 7, .start = "/a3/busy?ms=6000", .kind = .typed, .target = "/blk/tbusy7" },
            .{ .label = "typed, handler 0 ms (control)", .tab = 8, .start = "/a3/busy?ms=0", .kind = .typed, .target = "/blk/tbusy8" },
        };
        for (vs) |v| {
            if (v.first.len != 0) {
                try r.create(v.tab, uLoop(&u, v.first));
                try r.nav(v.tab, uLoop(&u, v.start), false);
            } else try r.create(v.tab, uLoop(&u, v.start));
            try r.watch(v.tab);
            _ = try r.block(v.tab, &rules, "");
            const c0 = seen(v.target);
            const e0 = r.errors.items.len;
            const t0 = os.nowMs();
            switch (v.kind) {
                .reload => try r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .reload, .user = true } }),
                .back => try r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .back, .user = true } }),
                .typed => try r.host.send(.{ .navigate = .{ .browser = v.tab, .url = uLoop(&u, v.target), .user = true } }),
            }
            _ = r.until(Run.loadsAt, v.tab, r.loads[v.tab] + 1, 12_000);
            const dt = os.nowMs() - t0;
            r.pump(600);
            const e = errOf(&r, v.tab, e0);
            report(seen(v.target) > c0, "A3-R10-busy-beforeunload", std.fmt.bufPrint(&d, "{s}: dialogs {d} · loaded after {d} ms · server +{d} · error page {?d} rule {?d} (want exempt: the user's own navigation)", .{ v.label, r.dialogs.items.len, dt, seen(v.target) - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
        }
    }

    // T3: the leave dialog on back/forward, answered after 3 s (only typed and reload were run before); and a handler that runs 1.5 s
    // before asking (the dialog appears after the 1 s token).
    {
        // back
        try r.create(9, uLoop(&u, "/blk/hbb9"));
        try r.nav(9, uLoop(&u, "/p/bu?b9"), false);
        var gb: [32]u8 = undefined;
        _ = r.evAs(9, "1", &gb, true);
        try r.watch(9);
        _ = try r.block(9, &rules, "");
        {
            const from = r.dialogs.items.len;
            const c0 = seen("/blk/hbb9");
            const e0 = r.errors.items.len;
            try r.host.send(.{ .nav_action = .{ .browser = 9, .action = .back, .user = true } });
            const dl = waitDialog(&r, 9, from, 4000);
            if (dl) |q| {
                r.pump(3000);
                try r.host.send(.{ .dialog_reply = .{ .browser = 9, .request = q.request, .accept = true } });
            }
            _ = r.until(Run.loadsAt, 9, r.loads[9] + 1, 6000);
            r.pump(600);
            const e = errOf(&r, 9, e0);
            report(seen("/blk/hbb9") > c0, "A3-R10-beforeunload-back", std.fmt.bufPrint(&d, "user back from a leave-dialog page, answered Leave after 3 s: dialog {s} · server +{d} · error page {?d} rule {?d} (want exempt)", .{ if (dl) |q| @tagName(q.kind) else "none", seen("/blk/hbb9") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
        }
        // forward: [/p/bu?f10, /blk/hff10] — go back first (no rule, no activation), then forward with the dialog.
        try r.create(10, uLoop(&u, "/p/bu?f10"));
        try r.nav(10, uLoop(&u, "/blk/hff10"), false);
        try r.action(10, .back, true);
        r.pump(300);
        _ = r.evAs(10, "1", &gb, true);
        try r.watch(10);
        _ = try r.block(10, &rules, "");
        {
            const from = r.dialogs.items.len;
            const c0 = seen("/blk/hff10");
            const e0 = r.errors.items.len;
            try r.host.send(.{ .nav_action = .{ .browser = 10, .action = .forward, .user = true } });
            const dl = waitDialog(&r, 10, from, 4000);
            if (dl) |q| {
                r.pump(3000);
                try r.host.send(.{ .dialog_reply = .{ .browser = 10, .request = q.request, .accept = true } });
            }
            _ = r.until(Run.loadsAt, 10, r.loads[10] + 1, 6000);
            r.pump(600);
            const e = errOf(&r, 10, e0);
            var lb: [100]u8 = undefined;
            const at = r.ev(10, "location.pathname", &lb);
            report(seen("/blk/hff10") > c0, "A3-R10-beforeunload-forward", std.fmt.bufPrint(&d, "user forward from a leave-dialog page, answered Leave after 3 s: dialog {s} · server +{d} · error page {?d} rule {?d} · at {s} (want exempt)", .{ if (dl) |q| @tagName(q.kind) else "none", seen("/blk/hff10") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
        }
        // busy 1.5 s, then the dialog; answered after 200 ms.
        try r.create(11, uLoop(&u, "/blk/busyd11?ms=1500&dlg=1"));
        _ = r.evAs(11, "1", &gb, true);
        try r.watch(11);
        _ = try r.block(11, &rules, "");
        {
            const from = r.dialogs.items.len;
            const c0 = seen("/blk/busyd11");
            const e0 = r.errors.items.len;
            try r.host.send(.{ .nav_action = .{ .browser = 11, .action = .reload, .user = true } });
            const dl = waitDialog(&r, 11, from, 5000);
            if (dl) |q| {
                r.pump(200);
                try r.host.send(.{ .dialog_reply = .{ .browser = 11, .request = q.request, .accept = true } });
            }
            _ = r.until(Run.loadsAt, 11, r.loads[11] + 1, 6000);
            r.pump(600);
            const e = errOf(&r, 11, e0);
            report(seen("/blk/busyd11") > c0, "A3-R10-busy-then-dialog-reload", std.fmt.bufPrint(&d, "user reload, handler runs 1.5 s then asks; Leave after 200 ms: dialog {s} · server +{d} · error page {?d} rule {?d} (want exempt)", .{ if (dl) |q| @tagName(q.kind) else "none", seen("/blk/busyd11") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
        }
    }

    // T4: the bound token of a user navigation that the IO side never consumed (no rule at its first hop, 204 — ERR_ABORTED does not clear
    // it). A rule is added, then the PAGE navigates to the same URL within 5 s.
    {
        try r.create(12, uLoop(&u, "/p/sub?t12"));
        try r.watch(12);
        // armed BEFORE the gesture — an agent Runtime call after it would clear the tokens (by design).
        _ = r.ev(12, "(setTimeout(()=>location.href='/n204?t12x',1500),'armed')", &o);
        try r.host.send(.{ .navigate = .{ .browser = 12, .url = uLoop(&u, "/n204?t12x"), .user = true } });
        r.pump(500);
        const typed = seen("/n204?t12x");
        _ = try r.block(12, &.{.{ .id = 2, .site = "127.0.0.1", .pattern = pat(&p2, "127.0.0.1", "/n204*") }}, "");
        const c0 = seen("/n204?t12x");
        const e0 = r.errors.items.len;
        r.pump(1800);
        const e = errOf(&r, 12, e0);
        const steal = seen("/n204?t12x") - c0;
        // control: a URL the user never typed.
        const c1 = seen("/n204?t12y");
        const e1 = r.errors.items.len;
        try r.nav(12, uLoop(&u, "/p/sub?t12c"), true);
        _ = r.ev(12, "(location.href='/n204?t12y','sent')", &o2);
        r.pump(1200);
        const ec = errOf(&r, 12, e1);
        report(steal == 0, "A3-R10-bound-token-unconsumed", std.fmt.bufPrint(&d, "user typed /n204?t12x with no rule (server {d} — 204, stays) · rule /n204* added · page location.href to the same URL → server +{d} · error page {?d} rule {?d} · control (never typed) → server +{d} error page {?d} rule {?d} (want blocked: the page's navigation is not the user's)", .{ typed, steal, if (e) |q| q.code else null, if (e) |q| q.rule else null, seen("/n204?t12y") - c1, if (ec) |q| q.code else null, if (ec) |q| q.rule else null }) catch "");
    }

    // T5: typed with a fragment from another page (cross-document) is exempt; typing the identical URL+fragment again (same document) and
    // the page's location.reload() 600 ms later is not.
    {
        try r.create(13, uLoop(&u, "/p/sub?t13"));
        try r.watch(13);
        _ = try r.block(13, &rules, "");
        const c0 = seen("/blk/tfr13");
        try r.host.send(.{ .navigate = .{ .browser = 13, .url = uLoop(&u, "/blk/tfr13#frag"), .user = true } });
        _ = r.until(Run.loadsAt, 13, r.loads[13] + 1, 5000);
        r.pump(500);
        const typed = seen("/blk/tfr13") - c0;
        _ = r.ev(13, "(setTimeout(()=>location.reload(),600),'armed')", &o);
        const c1 = seen("/blk/tfr13");
        const e1 = r.errors.items.len;
        try r.host.send(.{ .navigate = .{ .browser = 13, .url = uLoop(&u, "/blk/tfr13#frag"), .user = true } });
        r.pump(2000);
        const e = errOf(&r, 13, e1);
        report(typed == 1 and seen("/blk/tfr13") == c1, "A3-R10-typed-fragment", std.fmt.bufPrint(&d, "typed /blk/tfr13#frag from another page → server +{d} (want 1) · typed the same URL+fragment again (same document), page location.reload() 600 ms later → server +{d} · error page {?d} rule {?d} (want 0)", .{ typed, seen("/blk/tfr13") - c1, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
    }

    // T6 (mutation pass of the 3rd fixes — LOW-A3-3's stop): the user's typed navigation waits for the old document's 2 s beforeunload
    // handler, and the user presses stop meanwhile — that navigation never starts, and the stop must drop the waiting token: when the page
    // later goes to the same URL by itself, it is blocked (a stop that left the token let the page's navigation take it — judge mutation).
    {
        try r.create(15, uLoop(&u, "/a3/busy?ms=2000"));
        try r.watch(15);
        _ = try r.block(15, &rules, "");
        // armed BEFORE the gesture — an agent Runtime call after it would clear the tokens (by design).
        _ = r.ev(15, "(setTimeout(()=>location.href='/blk/stop15',3500),'armed')", &o);
        const c0 = seen("/blk/stop15");
        const e0 = r.errors.items.len;
        try r.host.send(.{ .navigate = .{ .browser = 15, .url = uLoop(&u, "/blk/stop15"), .user = true } });
        r.pump(500);
        try r.host.send(.{ .nav_action = .{ .browser = 15, .action = .stop, .user = true } });
        r.pump(8000);
        const e = errOf(&r, 15, e0);
        report(seen("/blk/stop15") == c0 and (if (e) |q| q.code == -20 and q.rule == 1 else false), "A3-R10-stop-drops-waiting-token", std.fmt.bufPrint(&d, "user typed /blk/stop15 behind a 2 s beforeunload handler, user stop 500 ms later, page location.href to the same URL at 3.5 s → server +{d} · error page {?d} rule {?d} (want blocked: the stopped navigation's token is gone)", .{ seen("/blk/stop15") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
    }
}

// ── R1/R2: the pattern parser and url_canon vs Chromium ─────────────────────────────────────────────────────

fn evAlloc(r: *Run, b: u64, expr: []const u8) ?std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"returnByValue\":true,\"awaitPromise\":true,\"expression\":") catch return null;
    std.json.Stringify.value(expr, .{}, &aw.writer) catch return null;
    aw.writer.writeAll("}") catch return null;
    const st = r.call(b, "Runtime.evaluate", aw.written(), 30_000) catch null;
    if (st == null or st.? != .ok) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{}) catch return null;
    defer parsed.deinit();
    const res = parsed.value.object.get("result") orelse return null;
    const v = res.object.get("value") orelse return null;
    if (v != .string) return null;
    return std.json.parseFromSlice(std.json.Value, r.gpa, v.string, .{}) catch null;
}

fn chromiumHrefs(r: *Run, b: u64, inputs: []const []const u8) ?std.json.Parsed(std.json.Value) {
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    aw.writer.writeAll("JSON.stringify(") catch return null;
    std.json.Stringify.value(inputs, .{}, &aw.writer) catch return null;
    aw.writer.writeAll(".map(s=>{try{return new URL(s).href}catch(e){return '!'}}))") catch return null;
    return evAlloc(r, b, aw.written());
}

/// The sidecar's `net_block_table.canonHash` (u16 side: GURL text from CEF; u8 side: what maru sends).
fn canonHash(comptime T: type, url: []const T) u64 {
    if (url_canon.hash(T, 0x9d3, url)) |v| return v;
    var h = std.hash.Wyhash.init(0x9d3);
    for (url) |c| h.update(std.mem.asBytes(&@as(u16, c)));
    return h.final();
}

fn canon(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a3_canon", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [8000]u8 = undefined;
    try r.create(1, uLoop(&u, "/p/sub"));
    var prng = std.Random.DefaultPrng.init(0xa3a3);
    const rnd = prng.random();

    // (a) R1 prefix mode: pattern `http://a.test<P>` (no `*`). Useful ⇔ some URL Chromium can produce starts with P. Suffixes probe that.
    {
        const chars = "ab/./%?!$&'()+,;=:@~[]\\\"<>{}|^`-_";
        const suffixes = [_][]const u8{ "", "x", "/x", ".x", "?q", "x/y" };
        const n_total: usize = 12_000;
        const batch: usize = 100;
        var false_reject: usize = 0;
        var dead_accept: usize = 0;
        var other_reject: usize = 0;
        var compared: usize = 0;
        var accepted: usize = 0;
        var store: [100][40]u8 = undefined;
        var paths: [100][]const u8 = undefined;
        var inputs: [100 * suffixes.len][]const u8 = undefined;
        var ibuf: [100 * suffixes.len][64]u8 = undefined;
        var ex: [4000]u8 = undefined;
        var exw: std.Io.Writer = .fixed(&ex);
        var shown: usize = 0;
        var done: usize = 0;
        while (done < n_total) : (done += batch) {
            for (0..batch) |i| {
                var w: std.Io.Writer = .fixed(&store[i]);
                w.writeByte('/') catch {};
                const n = rnd.uintLessThan(usize, 10);
                for (0..n) |_| {
                    const roll = rnd.uintLessThan(u8, 14);
                    if (roll == 0) {
                        w.writeAll("%2E") catch {};
                    } else if (roll == 1) {
                        w.writeAll("%41") catch {};
                    } else if (roll == 2) {
                        w.writeAll("..") catch {};
                    } else if (roll == 3) {
                        w.writeAll("/.") catch {};
                    } else w.writeByte(chars[rnd.uintLessThan(usize, chars.len)]) catch {};
                }
                paths[i] = w.buffered();
                for (suffixes, 0..) |s, k| inputs[i * suffixes.len + k] = std.fmt.bufPrint(&ibuf[i * suffixes.len + k], "http://a.test{s}{s}", .{ paths[i], s }) catch unreachable;
            }
            const parsed = chromiumHrefs(&r, 1, inputs[0 .. batch * suffixes.len]) orelse {
                report(false, "A3-R1-prefix", "chromium eval failed");
                return;
            };
            defer parsed.deinit();
            for (0..batch) |i| {
                var pb: [80]u8 = undefined;
                const pattern_text = std.fmt.bufPrint(&pb, "http://a.test{s}", .{paths[i]}) catch unreachable;
                const res = nbp.parse(pattern_text);
                // the normal-form path to look for (escapes uppercased — the generator only writes uppercase escapes)
                var useful = false;
                var matched = false;
                for (0..suffixes.len) |k| {
                    const href = parsed.value.array.items[i * suffixes.len + k].string;
                    if (std.mem.eql(u8, href, "!")) continue;
                    const cpath = href["http://a.test".len..];
                    if (std.mem.startsWith(u8, cpath, paths[i])) useful = true;
                    if (res == .ok) if (nbp.splitUrl(u8, href)) |parts| {
                        if (nbp.matchParts(u8, &res.ok, parts)) matched = true;
                    };
                }
                switch (res) {
                    .ok => {
                        compared += 1;
                        accepted += 1;
                        if (!matched) {
                            dead_accept += 1;
                            if (shown < 12) {
                                exw.print("[accepted {s}, no probe URL matches] ", .{paths[i]}) catch {};
                                shown += 1;
                            }
                        }
                    },
                    .err => |why| {
                        if (why != .path) {
                            other_reject += 1;
                            continue;
                        }
                        compared += 1;
                        if (useful) {
                            false_reject += 1;
                            if (shown < 12) {
                                exw.print("[rejected {s} but Chromium keeps a URL starting with it] ", .{paths[i]}) catch {};
                                shown += 1;
                            }
                        }
                    },
                }
            }
        }
        report(false_reject == 0, "A3-R1-prefix", std.fmt.bufPrint(&u, "random prefix patterns {d}: compared {d} (accepted {d}), other rejection {d}, false `.path` rejection {d}, accepted with no probe URL matching {d} (observation — probes are 6 suffixes)", .{ n_total, compared, accepted, other_reject, false_reject, dead_accept }) catch "");
        report(true, "A3-R1-prefix-examples", exw.buffered());
    }

    // (b) R1 host characters: which hosts does Chromium actually send requests to (`.localhost` — no DNS), and does the parser accept them?
    {
        var w: std.Io.Writer = .fixed(&d);
        var false_reject: usize = 0;
        var accepted_unreachable: usize = 0;
        const cs = "!$&'()*+,;=~_-";
        for (cs, 0..) |c, idx| {
            var hb: [16]u8 = undefined;
            const h = std.fmt.bufPrint(&hb, "a{c}b", .{c}) catch unreachable;
            var tb: [160]u8 = undefined;
            const target = std.fmt.bufPrint(&tb, "http://{s}.localhost:{d}/hostform3/{d}", .{ h, port, idx }) catch unreachable;
            var xb: [800]u8 = undefined;
            const fe = std.fmt.bufPrint(&xb, "(async()=>{{try{{await fetch(\"{s}\",{{mode:'no-cors'}});return 'ok'}}catch(e){{return 'reject '+e.name}}}})()", .{target}) catch unreachable;
            var ob: [300]u8 = undefined;
            const got = r.ev(1, fe, &ob);
            var gcopy: [40]u8 = undefined;
            const gc = gcopy[0..@min(gcopy.len, got.len)];
            @memcpy(gc, got[0..gc.len]);
            var hrefs_in = [_][]const u8{target};
            const hp = chromiumHrefs(&r, 1, &hrefs_in);
            defer if (hp) |pp| pp.deinit();
            const href = if (hp) |pp| pp.value.array.items[0].string else "?";
            r.pump(200);
            var nb: [64]u8 = undefined;
            const n = seen(std.fmt.bufPrint(&nb, "/hostform3/{d} ", .{idx}) catch unreachable);
            var pb: [160]u8 = undefined;
            const pattern = std.fmt.bufPrint(&pb, "http://{s}.localhost:{d}/hostform3/", .{ h, port }) catch unreachable;
            const res = nbp.parse(pattern);
            const acc = res == .ok;
            if (n > 0 and !acc) false_reject += 1;
            if (n == 0 and acc) accepted_unreachable += 1;
            w.print("[{s}: Chromium {s} · fetch {s} · server {d} · pattern {s}] ", .{ h, href[0..@min(href.len, 48)], gc, n, if (acc) "ok" else @tagName(res.err) }) catch {};
        }
        report(false_reject == 0, "A3-R1-host-chars", std.fmt.bufPrint(&u, "{d} host characters: reached the server but the pattern is rejected {d} · accepted but no request {d}", .{ cs.len, false_reject, accepted_unreachable }) catch "");
        report(true, "A3-R1-host-chars-detail", w.buffered());
    }

    // (c) R2: typed hosts with %XX (N-A2-3 fix) — url_canon on maru's u8 text vs on CEF's u16 GURL text.
    {
        const pieces = [_][]const u8{ "a", "b", "x", "1", "0", "7", "127", ".", ".", "-", "_", "%2e", "%2E", "%41", "%61", "%31", "%30", "%37", "%66", "%78", "%2d", "%5f", "%7e", "%25", "%00", "%20", "%2f", "%3a", "%40", "%5b", "%c3%a9", "%ff", "%", "%z1", "%E2%80%8B", "%C2%AD", "%09" };
        const n_total: usize = 12_000;
        const batch: usize = 150;
        var mismatches: usize = 0;
        var invalid: usize = 0;
        var compared: usize = 0;
        var null_hash: usize = 0;
        var ascii_mismatch: usize = 0;
        var examples: std.Io.Writer = .fixed(&d);
        var shown: usize = 0;
        var store: [150][200]u8 = undefined;
        var done: usize = 0;
        while (done < n_total) : (done += batch) {
            var inputs: [150][]const u8 = undefined;
            for (0..batch) |i| {
                var w: std.Io.Writer = .fixed(&store[i]);
                w.writeAll(if (rnd.boolean()) "http://" else "https://") catch {};
                const np = 1 + rnd.uintLessThan(usize, 6);
                for (0..np) |_| w.writeAll(pieces[rnd.uintLessThan(usize, pieces.len)]) catch {};
                if (rnd.boolean()) w.print(":{d}", .{port}) catch {};
                w.writeAll("/blk/x") catch {};
                inputs[i] = w.buffered();
            }
            const parsed = chromiumHrefs(&r, 1, inputs[0..batch]) orelse {
                report(false, "A3-R2-typed-host", "chromium eval failed");
                return;
            };
            defer parsed.deinit();
            for (parsed.value.array.items, 0..) |v, i| {
                const href = v.string;
                if (std.mem.eql(u8, href, "!")) {
                    invalid += 1;
                    continue;
                }
                compared += 1;
                var wide: [600]u16 = undefined;
                const wn = std.unicode.utf8ToUtf16Le(&wide, href) catch continue;
                const a = canonHash(u8, inputs[i]);
                const g = canonHash(u16, wide[0..wn]);
                if (url_canon.hash(u8, 0x9d3, inputs[i]) == null) null_hash += 1;
                if (a != g) {
                    mismatches += 1;
                    // the documented gap: a host that decodes to non-ASCII (IDN — GURL hands over punycode)
                    const hs = inputs[i][std.mem.indexOf(u8, inputs[i], "://").? + 3 ..];
                    const he = std.mem.indexOfAny(u8, hs, ":/") orelse hs.len;
                    var non_ascii = false;
                    var k: usize = 0;
                    while (k < he) : (k += 1) {
                        if (hs[k] == '%' and k + 2 < he and std.ascii.isHex(hs[k + 1]) and std.ascii.isHex(hs[k + 2])) {
                            const byte = std.fmt.parseInt(u8, hs[k + 1 .. k + 3], 16) catch 0;
                            if (byte >= 0x80) non_ascii = true;
                            k += 2;
                        } else if (hs[k] >= 0x80) non_ascii = true;
                    }
                    if (!non_ascii) {
                        ascii_mismatch += 1;
                        if (shown < 25) {
                            examples.print("[{s} ⇒ {s}] ", .{ inputs[i], href }) catch {};
                            shown += 1;
                        }
                    }
                }
            }
        }
        report(ascii_mismatch == 0, "A3-R2-typed-host", std.fmt.bufPrint(&u, "random typed hosts with %XX {d}: Chromium-invalid {d}, compared {d}, canonHash(u8 typed) != canonHash(u16 Chromium href) in {d} — of which the host decodes to ASCII only {d} (the rest decode to non-ASCII: documented IDN gap) (url_canon null on the typed side {d})", .{ n_total, invalid, compared, mismatches, ascii_mismatch, null_hash }) catch "");
        report(true, "A3-R2-typed-host-examples(ascii-only mismatches)", examples.buffered());
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// 4 차 검증(A4 — 1d8fe6522) 6·10 회차. 보고 줄은 `A4-R<n>` 으로 시작한다.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

fn a4sub(name: []const u8) bool {
    const v = std.c.getenv("A4_ONLY") orelse return true;
    const t = std.mem.span(v);
    return std.mem.indexOf(u8, t, name) != null or std.mem.indexOf(u8, t, "r6") != null or std.mem.indexOf(u8, t, "r10") != null;
}

fn a4r6(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a4_sw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var x: [2048]u8 = undefined;
    var o: [600]u8 = undefined;
    var o2: [600]u8 = undefined;
    var d: [2000]u8 = undefined;
    var p9: [128]u8 = undefined;

    // A4-R6-1: 규칙 42 가 막은 iframe 주소의 표시(blocked_sub)가 남는다 — 규칙을 뺀 뒤 같은 주소로 정말 선 iframe 을 오류 페이지로 쳐, 그 탭이
    // 127.0.0.1 을 보이는데도 T(O) 에서 빠진다. 대조: 다른 주소로 선 iframe.
    if (a4sub("bss")) {
        const broad = [_]msg.NetBlockRule{ .{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }, .{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" } };
        const only41 = [_]msg.NetBlockRule{.{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }};
        const Var = struct { label: []const u8, again: []const u8 };
        var id: u64 = 30;
        for ([_]Var{
            .{ .label = "control: rule 42 removed, iframe loads ANOTHER /blkifr URL", .again = "/blkifr?a4c" },
            .{ .label = "stale: rule 42 removed, iframe loads the SAME URL rule 42 blocked", .again = "/blkifr?a4s" },
        }) |v| {
            const b = id;
            const a = id + 1;
            id += 2;
            try r.create(b, uLoop(&u, "/s/page?B4"));
            const bctl = swReady(&r, b);
            var ab: [256]u8 = undefined;
            try r.create(a, std.fmt.bufPrint(&ab, "http://localhost:{d}/a3/ifr?s=/blkifr?a4s", .{port}) catch unreachable);
            r.pump(800);
            try r.watch(a);
            const ok1 = try r.block(a, &broad, "");
            const blk0 = seen("/blkifr?a4s");
            const e0 = r.errors.items.len;
            _ = r.ev(a, "(location.reload(),'reloading')", &o);
            r.pump(1200);
            const blocked_hits = r.hitOf(a, 42).hits;
            const ok2 = try r.block(a, &only41, "");
            const s_again = seen(v.again);
            var sb: [256]u8 = undefined;
            _ = r.ev(a, std.fmt.bufPrint(&sb, "(document.getElementById('f').src='http://127.0.0.1:{d}{s}','set')", .{ port, v.again }) catch unreachable, &o);
            r.pump(1500);
            const loaded = seen(v.again) - s_again;
            const got = r.ev(b, fetchExpr(&x, "/s/swlate-a4"), &o2);
            r.pump(500);
            const h1 = r.hitOf(a, 41);
            const s0 = seen("/s/swlate?sw=");
            _ = r.ev(b, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o);
            r.pump(100);
            try r.host.send(.{ .destroy_browser = b });
            r.pump(3000);
            const h2 = r.hitOf(a, 41);
            const reached = seen("/s/swlate?sw=") - s0;
            _ = errOf(&r, a, e0);
            const pass = loaded == 1 and h1.sw_not_applied == 1 and reached == 0 and h2.sw_hits == 1;
            report(pass, "A4-R6-blocked-sub-stale", std.fmt.bufPrint(&d, "{s}: B {s} · A ruled {}/{} · reload: /blkifr?a4s server +{d} rule 42 hits {d} · iframe again {s} → server +{d} · B fetch /s/swlate-a4 → {s} · A sw_not_applied {d} · B closed, SW late fetch → server +{d} · A sw_hits {d} (want: A shows 127.0.0.1 — not_applied 1, late fetch blocked +0, sw_hits 1)", .{ v.label, bctl, ok1, ok2, seen("/blkifr?a4s") - blk0, blocked_hits, v.again, loaded, got[0..@min(got.len, 30)], h1.sw_not_applied, reached, h2.sw_hits }) catch "");
            try r.host.send(.{ .destroy_browser = a });
            r.pump(800);
        }
    }

    // A4-R6-2: MED-A3-2 의 `swHosts` 는 「그 탭의 진행 중 주 프레임 이동 주소와 같다」 만 본다 — 떠나는 옛 문서(127.0.0.1, 서비스 워커가
    // 다스림)가 그 이동 주소(localhost)로 낸 하위 자원도 그 이동 자체로 쳐 localhost 에 묶인 규칙이 127.0.0.1 문서의 요청을 막는가.
    if (a4sub("swh")) {
        // Runtime.evaluate 는 다른 프로세스로 가는 이동이 끝날 때까지 붙잡힌다(실측 1 판: 모든 평가가 8 초 뒤 새 문서에서 돌았다) — 그래서 옛 문서
        // 스스로 이동을 시작하고 1.5 초 뒤 두 fetch 를 내며, 결과를 서버의 `/s4/mark?<k>-ok|rej` 로 알린다. 판정자는 그 사이에 규칙만 넣는다.
        const n: u64 = 36;
        try r.create(n, uLoop(&u, "/s4/page?N4"));
        const nctl = swReady(&r, n);
        try r.watch(n);
        var nb: [200]u8 = undefined;
        const nav_u = uLocal(&nb, "/s4/hang?a4nav");
        var cb: [200]u8 = undefined;
        const ctl_u = uLocal(&cb, "/s4/hang?a4ctl");
        var eb: [900]u8 = undefined;
        _ = r.ev(n, std.fmt.bufPrint(&eb, "(setTimeout(()=>{{location.href='{s}';setTimeout(()=>{{for(const [u,k] of [['{s}','ctl'],['{s}','nav']])fetch(u,{{mode:'no-cors'}}).then(()=>fetch('/s4/mark?'+k+'-ok'),e=>fetch('/s4/mark?'+k+'-rej'))}},1500)}},0),'go')", .{ nav_u, ctl_u, nav_u }) catch unreachable, &o);
        r.pump(400);
        const nav_seen = seen("/s4/hang?a4nav");
        // 규칙은 이동이 시작된 뒤(그 이동은 이미 처리기를 골랐다 — 막히지 않고 8 초 매달린다).
        const ok = try r.block(n, &.{.{ .id = 91, .site = "localhost", .pattern = pat(&p9, "localhost", "/s4/hang*") }}, "");
        r.pump(3000);
        const h = r.hitOf(n, 91);
        const ctl_reached = seen("/s4/hang?a4ctl");
        const nav_reached = seen("/s4/hang?a4nav") - nav_seen;
        const marks = [_][]const u8{ "/s4/mark?ctl-ok", "/s4/mark?ctl-rej", "/s4/mark?nav-ok", "/s4/mark?nav-rej" };
        var mb: [200]u8 = undefined;
        var mw: std.Io.Writer = .fixed(&mb);
        for (marks) |m| if (seen(m) > 0) mw.print("{s} ", .{m[9..]}) catch {};
        report(ctl_reached == 1 and nav_reached == 1 and seen("/s4/mark?nav-rej") == 0, "A4-R6-sw-hosts-same-url-other-initiator", std.fmt.bufPrint(&d, "N on 127.0.0.1 ({s}, SW passes every request through unchanged) navigating to {s} (server {d} at the rule, hangs 8 s) · rule 91 site localhost /s4/hang* added after the start ({}) · 1.5 s later the old 127.0.0.1 document fetches ANOTHER /s4/hang URL → server {d} and the navigation's own URL → server +{d} · marks [{s}] · rule 91 hits {d} sw_hits {d} (want both pass: both are the 127.0.0.1 document's requests — the tab path would use page host 127.0.0.1)", .{ nctl, nav_u, nav_seen, ok, ctl_reached, nav_reached, mw.buffered(), h.hits, h.sw_hits }) catch "");
        r.pump(5500);
        try r.host.send(.{ .destroy_browser = n });
        r.pump(500);
    }

    // A4-R6-3: 같은 사이트의 다른 출처(127.0.0.1:<port2>) iframe — 같은 렌더러라 프레임 번호가 남을 수 있다. 매달린 이동 중에 지운 iframe 의 진행 중
    // 기록을 누가 놓는가(3 차 고침의 변이에서 산 `subframeGone`). 대조: 지우지 않음(그 기록으로 「보인다」).
    if (a4sub("det")) {
        const Var = struct { label: []const u8, remove: bool };
        var id: u64 = 24;
        for ([_]Var{ .{ .label = "control: iframe still hanging", .remove = false }, .{ .label = "iframe removed while its navigation hangs", .remove = true } }) |v| {
            const b = id;
            const a = id + 1;
            id += 2;
            var bb2: [200]u8 = undefined;
            try r.create(b, std.fmt.bufPrint(&bb2, "http://127.0.0.1:{d}/s/page?B4g", .{port2}) catch unreachable);
            const bctl = swReady(&r, b);
            var ab: [200]u8 = undefined;
            try createNoWait(&r, a, std.fmt.bufPrint(&ab, "http://127.0.0.1:{d}/a4/ifr2?s=/x/hang?a4g{d}", .{ port, a }) catch unreachable, 600);
            try r.watch(a);
            const ok = try r.block(a, &.{.{ .id = 41, .site = "127.0.0.1", .pattern = "*://*/s/swlate*" }}, "");
            if (v.remove) {
                _ = r.ev(a, "(document.getElementById('f').remove(),'removed')", &o);
                r.pump(300);
            }
            var fo: [100]u8 = undefined;
            const fr = r.ev(a, "String(window.frames.length)", &fo);
            const got = r.ev(b, fetchExpr(&x, "/s/swlate-a4g"), &o2);
            r.pump(500);
            const h1 = r.hitOf(a, 41);
            const s0 = seen("/s/swlate?sw=");
            _ = r.ev(b, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o);
            r.pump(100);
            try r.host.send(.{ .destroy_browser = b });
            r.pump(3000);
            const reached = seen("/s/swlate?sw=") - s0;
            const pass = if (v.remove) (h1.sw_not_applied == 0 and reached == 1) else (h1.sw_not_applied == 1 and reached == 0);
            report(pass, "A4-R6-same-site-iframe-detach", std.fmt.bufPrint(&d, "{s}: B 127.0.0.1:{d} {s} · A 127.0.0.1:{d} ruled {} frames {s} · B fetch → {s} · A sw_not_applied {d} · late SW fetch → server +{d} (want {s})", .{ v.label, port2, bctl, port, ok, fr, got[0..@min(got.len, 24)], h1.sw_not_applied, reached, if (v.remove) "0 / +1: the removed iframe's record is released" else "1 / +0: the hanging iframe's record shows the origin" }) catch "");
            try r.host.send(.{ .destroy_browser = a });
            r.pump(800);
        }
    }
}

fn a4r10(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a4_d2", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};

    // A4-R10-1: 기록 조작 개입(history manipulation intervention) — 몸짓 없이 같은 주소로 pushState 한 항목은 뒤로가 건너뛴다. 기록 항목 비교
    // (`historyMovesMainFrame` — 지금과 바로 앞 항목)는 같은 주소라 토큰을 걸지 않는데 실제 뒤로는 그 앞의 다른 문서로 간다.
    if (a4sub("skip")) for ([_]struct { b: u64, prev: []const u8, page: []const u8, label: []const u8 }{
        .{ .b = 5, .prev = "/blk/a4prev", .page = "/a4/same0", .label = "no beforeunload — the back's on_before_browse comes inside go_back" },
        .{ .b = 8, .prev = "/blk/a4prevb", .page = "/a4/same0b", .label = "600 ms beforeunload — the back starts after the target was read" },
    }) |sk| {
        const b = sk.b;
        try r.create(b, uLoop(&u, sk.prev));
        try r.nav(b, uLoop(&u, sk.page), false);
        r.pump(300);
        var hb: [400]u8 = undefined;
        const hist0 = r.ev(b, "String(history.length)", &hb);
        try r.watch(b);
        _ = try r.block(b, &rules, "");
        const c0 = seen(sk.prev);
        const e0 = r.errors.items.len;
        const url0 = r.urls[b];
        try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
        r.pump(2500);
        const e = errOf(&r, b, e0);
        var lb: [300]u8 = undefined;
        const at = r.ev(b, "location.pathname", &lb);
        report(seen(sk.prev) > c0, "A4-R10-skippable-back", std.fmt.bufPrint(&d, "{s}: [{s}, {s} (skippable — pushState of the same URL without activation), {s}] history.length {s} · user back → server +{d} · url_changed +{d} · error page {?d} rule {?d} · at {s} (want exempt: the user's back reached a different document)", .{ sk.label, sk.prev, sk.page, sk.page, hist0, seen(sk.prev) - c0, r.urls[b] - url0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
    };

    // A4-R10-2: 떠나기 확인을 에이전트가 CDP `Page.handleJavaScriptDialog{accept:false}` 로 머무르게 하면 sidecar 의 답 길(`dialogAnswered`)을
    // 지나지 않는다 — 몸짓의 토큰이 남아(시계는 다른 주 프레임 이동을 기다린다 — 30 초) 2.5 초 뒤 페이지 자신의 `history.go(-2)`(기록 이동 —
    // 같은 갈래)가 막힌 주소에 닿는가. 대조: 사용자가 maru 의 확인에서 머무르기.
    if (a4sub("cdpd")) {
        const Arm = struct { label: []const u8, cdp: bool, tab: u64, first: []const u8 };
        for ([_]Arm{
            .{ .label = "control: user answers Stay through maru", .cdp = false, .tab = 6, .first = "/blk/a4dlg6" },
            .{ .label = "agent answers Stay through CDP Page.handleJavaScriptDialog", .cdp = true, .tab = 7, .first = "/blk/a4dlg7" },
        }) |v| {
            const b = v.tab;
            try r.create(b, uLoop(&u, v.first));
            try r.nav(b, uLoop(&u, "/p/sub?a4mid"), false);
            try r.nav(b, uLoop(&u, "/a4/bustay"), false);
            var gb: [32]u8 = undefined;
            _ = r.evAs(b, "1", &gb, true);
            const pe = r.call(b, "Page.enable", "{}", 5000) catch null;
            try r.watch(b);
            _ = try r.block(b, &rules, "");
            const from = r.dialogs.items.len;
            const c0 = seen(v.first);
            const e0 = r.errors.items.len;
            try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
            const dl = waitDialog(&r, b, from, 4000);
            var how: []const u8 = "no dialog";
            if (dl) |q| {
                r.pump(300);
                if (v.cdp) {
                    const st = r.call(b, "Page.handleJavaScriptDialog", "{\"accept\":false}", 5000) catch null;
                    how = if (st) |s| @tagName(s) else "timeout";
                } else {
                    try r.host.send(.{ .dialog_reply = .{ .browser = b, .request = q.request, .accept = false } });
                    how = "maru stay";
                }
            }
            r.pump(5000);
            const e = errOf(&r, b, e0);
            var lb: [300]u8 = undefined;
            const at = r.ev(b, "location.pathname", &lb);
            report(seen(v.first) == c0, "A4-R10-cdp-dialog-stay-steal", std.fmt.bufPrint(&d, "{s}: Page.enable {s} · user back → dialog {s} · answer {s} · page history.go(-2) 2.5 s later → server +{d} · error page {?d} rule {?d} · at {s} (want blocked: the page's history move is not the user's)", .{ v.label, if (pe) |s| @tagName(s) else "timeout", if (dl) |q| @tagName(q.kind) else "none", how, seen(v.first) - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
        }
    }
}

// ── A5: fifth-pass verifier on 7f0333fa9 (`--review-block-v20e`, `A5_ONLY=eov,leak,bfc,swi,nc,ro,tok,hist,strict`) ───────────────────────────

fn a5want(name: []const u8) bool {
    const v = std.c.getenv("A5_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn runA5(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    try startServer2();
    if (a5want("eov") or a5want("bfc") or a5want("leak")) a5r6(report, host_path, root) catch |err| report(false, "A5-R6", @errorName(err));
    if (a5want("swi")) a5swi(report, host_path, root) catch |err| report(false, "A5-swi", @errorName(err));
    if (a5want("nc")) a5nc(report, host_path, root) catch |err| report(false, "A5-nc", @errorName(err));
    if (a5want("ro")) a5ro(report, host_path, root) catch |err| report(false, "A5-ro", @errorName(err));
    if (a5want("tok")) a5tok(report, host_path, root) catch |err| report(false, "A5-tok", @errorName(err));
    if (a5want("hist")) a5hist(report, host_path, root) catch |err| report(false, "A5-hist", @errorName(err));
    if (a5want("strict")) a5strict(report, host_path, root) catch |err| report(false, "A5-strict", @errorName(err));
}

/// B (127.0.0.1, SW) fetch through its SW, then B closed and the SW's late fetch — what A (ruled, localhost, rule 41 */s/swlate*) counts.
const SwProbe = struct { got: [40]u8 = undefined, got_len: usize = 0, not_applied: u64 = 0, reached: usize = 0, sw_hits: u64 = 0 };

fn swProbe(r: *Run, a: u64, b: u64, tag: []const u8) !SwProbe {
    var out: SwProbe = .{};
    var x: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var ub: [64]u8 = undefined;
    const got = r.ev(b, fetchExpr(&x, std.fmt.bufPrint(&ub, "/s/swlate-{s}", .{tag}) catch unreachable), &o);
    out.got_len = @min(got.len, out.got.len);
    @memcpy(out.got[0..out.got_len], got[0..out.got_len]);
    r.pump(500);
    out.not_applied = r.hitOf(a, 41).sw_not_applied;
    const s0 = seen("/s/swlate?sw=");
    _ = r.ev(b, "(navigator.serviceWorker.controller.postMessage(1),'sent')", &o);
    r.pump(100);
    try r.host.send(.{ .destroy_browser = b });
    r.pump(3000);
    out.reached = seen("/s/swlate?sw=") - s0;
    out.sw_hits = r.hitOf(a, 41).sw_hits;
    return out;
}

fn a5r6(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_sw", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [2000]u8 = undefined;
    const broad = [_]msg.NetBlockRule{ .{ .id = 41, .site = "localhost", .pattern = "*://*/s/swlate*" }, .{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" } };
    var id: u64 = 2;

    // A5-R6-1: err_frames 8 자리 — 막힌 iframe 아홉이면 첫 오류 프레임을 잊어 그 탭이 127.0.0.1 을 「보인다」 로 나열되는가(오류 페이지뿐인데).
    const same_url = std.c.getenv("A5_SAME") != null;
    if (a5want("eov")) for (if (same_url) [_]usize{ 2, 8, 9, 12 } else [_]usize{ 1, 8, 9, 12 }) |n| {
        const b = id;
        const a = id + 1;
        id += 2;
        try r.create(b, uLoop(&u, "/s/page?B5"));
        const bctl = swReady(&r, b);
        try r.create(a, uLocal(&u, "/x/blank?A5"));
        try r.watch(a);
        const ok = try r.block(a, &broad, "");
        var kb: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "o{d}", .{n}) catch unreachable;
        var nb_: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&nb_, "/blkifr?a5{s}-", .{k}) catch unreachable;
        const s_blk = seen(needle);
        var pb: [128]u8 = undefined;
        try r.nav(a, uLocal(&u, std.fmt.bufPrint(&pb, "/a5/ifrs?n={d}&k={s}{s}", .{ n, k, if (same_url) "&same=1" else "" }) catch unreachable), false);
        r.pump(2000);
        var fo: [64]u8 = undefined;
        const fr = r.ev(a, "String(window.frames.length)", &fo);
        const h42 = r.hitOf(a, 42).hits;
        const pr = try swProbe(&r, a, b, k);
        const pass = seen(needle) == s_blk and pr.not_applied == 0 and pr.reached == 1;
        report(pass, "A5-R6-err-frames-overflow", std.fmt.bufPrint(&d, "n={d}{s}: B {s} · A ruled {} · A has {s} iframes all blocked (server +{d}, rule 42 hits {d}) · B fetch → {s} · A sw_not_applied {d} · B closed, SW late fetch → server +{d} · A sw_hits {d} (want: A shows only error pages — not_applied 0, late fetch passes +1)", .{ n, if (same_url) " (all the SAME URL)" else "", bctl, ok, fr, seen(needle) - s_blk, h42, pr.got[0..pr.got_len], pr.not_applied, pr.reached, pr.sw_hits }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        r.pump(800);
    };

    // A5-R6-1b: 새는 쪽 — A 의 규칙은 iframe 주소(42)뿐, 127.0.0.1 을 정말 보이는 Y 는 제 규칙 51(*/s/swlate*)을 쥔다. A 가 「보인다」 로 잘못
    // 나열되면 A 의 거부권이 Y 의 규칙을 「적용 안 됨」 으로 만든다(Y 의 서비스 워커 요청이 지나간다).
    if (a5want("leak")) for ([_]usize{ 1, 9 }) |n| {
        const y = id;
        const a = id + 1;
        id += 2;
        try r.create(y, uLoop(&u, "/s/page?Y5"));
        const yctl = swReady(&r, y);
        try r.watch(y);
        const oky = try r.block(y, &.{.{ .id = 51, .site = "127.0.0.1", .pattern = "*://*/s/swlate*" }}, "");
        try r.create(a, uLocal(&u, "/x/blank?A5l"));
        try r.watch(a);
        const oka = try r.block(a, &.{.{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" }}, "");
        var pb: [128]u8 = undefined;
        try r.nav(a, uLocal(&u, std.fmt.bufPrint(&pb, "/a5/ifrs?n={d}&k=l{d}", .{ n, n }) catch unreachable), false);
        r.pump(2000);
        var x: [512]u8 = undefined;
        var ub: [64]u8 = undefined;
        const s0 = seen("/s/swlate-leak");
        const got = r.ev(y, fetchExpr(&x, std.fmt.bufPrint(&ub, "/s/swlate-leak{d}", .{n}) catch unreachable), &o);
        r.pump(500);
        const h = r.hitOf(y, 51);
        const reached = seen("/s/swlate-leak") - s0;
        report(reached == 0, "A5-R6-err-frames-overflow-leak", std.fmt.bufPrint(&d, "n={d}: Y 127.0.0.1 {s} ruled {} (51 */s/swlate*) · A localhost ruled {} (42 */blkifr* only) with {d} blocked 127.0.0.1 iframes · Y fetch /s/swlate-leak through its SW → {s} · server +{d} · Y rule 51 sw_hits {d} sw_not_applied {d} (want blocked: only Y shows 127.0.0.1)", .{ n, yctl, oky, oka, n, got[0..@min(got.len, 40)], reached, h.sw_hits, h.sw_not_applied }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        try r.host.send(.{ .destroy_browser = y });
        r.pump(800);
    };

    // A5-R6-2: bfcache — A 의 막힌 iframe 오류 표시는 새 문서가 지운다(frameSettled). 뒤로가 bfcache 로 그 문서를 되살리면 오류 iframe 이 실패
    // 주소(127.0.0.1)로 다시 나열되는가.
    if (a5want("bfc")) {
        const b = id;
        const a = id + 1;
        id += 2;
        try r.create(b, uLoop(&u, "/s/page?B5b"));
        const bctl = swReady(&r, b);
        try r.create(a, uLocal(&u, "/x/blank?A5b"));
        try r.watch(a);
        const ok = try r.block(a, &broad, "");
        try r.nav(a, uLocal(&u, "/a5/ifrs?n=1&k=bf"), false);
        r.pump(1200);
        const req1 = seen("/a5/ifrs?n=1&k=bf");
        try r.nav(a, uLocal(&u, "/x/blank?A5c"), false);
        r.pump(800);
        try r.host.send(.{ .nav_action = .{ .browser = a, .action = .back, .user = false } });
        r.pump(2000);
        var pb: [100]u8 = undefined;
        const ps = r.ev(a, "JSON.stringify(window.ps||null)+' '+location.pathname", &pb);
        const req2 = seen("/a5/ifrs?n=1&k=bf");
        const blk = seen("/blkifr?a5bf-");
        const pr = try swProbe(&r, a, b, "bf");
        const pass = pr.not_applied == 0 and pr.reached == 1;
        report(pass, "A5-R6-bfcache-err-iframe", std.fmt.bufPrint(&d, "B {s} · A ruled {} · A /a5/ifrs (1 blocked iframe) → /x/blank → back: pageshow {s} · page requests {d}→{d} (same = bfcache) · /blkifr server {d} · B fetch → {s} · A sw_not_applied {d} · late SW fetch → server +{d} · A sw_hits {d} (want: not_applied 0, +1 — the restored iframe is still an error page)", .{ bctl, ok, ps, req1, req2, blk, pr.got[0..pr.got_len], pr.not_applied, pr.reached, pr.sw_hits }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        r.pump(800);
    }
    _ = &o;
}

/// A5: 다른 출처 iframe 안의 서비스 워커 — 그 출처가 진행 중 주 프레임 이동의 목적지 출처와 같으면 그 iframe 의 하위 자원(같은 주소)도 「이동 자체」
/// 로 쳐 이동 사이트의 규칙에 막히는가(탭 길이면 페이지 호스트 127.0.0.1 — 지나간다).
fn a5swi(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_swi", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var d: [2000]u8 = undefined;
    var p9: [128]u8 = undefined;
    const Arm = struct { label: []const u8, same: bool, tab: u64, key: []const u8 };
    for ([_]Arm{
        .{ .label = "control: iframe fetches ANOTHER /s4/hang URL", .same = false, .tab = 20, .key = "c" },
        .{ .label = "iframe fetches the navigation's own URL", .same = true, .tab = 21, .key = "s" },
    }) |v| {
        const n = v.tab;
        try r.create(n, uLoop(&u, "/a5/swtop"));
        r.pump(2500);
        var cb: [64]u8 = undefined;
        const ictl = r.ev(n, "String(window.ictl)", &cb);
        try r.watch(n);
        var navb: [200]u8 = undefined;
        var kb: [32]u8 = undefined;
        const nav_u = uLocal(&navb, std.fmt.bufPrint(&kb, "/s4/hang?a5nav{s}", .{v.key}) catch unreachable);
        var fb: [200]u8 = undefined;
        var kb2: [32]u8 = undefined;
        const fu = if (v.same) nav_u else uLocal(&fb, std.fmt.bufPrint(&kb2, "/s4/hang?a5ifr{s}", .{v.key}) catch unreachable);
        const rej0 = seen("/s4/mark?a5i-rej");
        const ok0 = seen("/s4/mark?a5i-ok");
        var eb: [600]u8 = undefined;
        _ = r.ev(n, std.fmt.bufPrint(&eb, "(setTimeout(()=>go('{s}','{s}'),0),'go')", .{ nav_u, fu }) catch unreachable, &o);
        r.pump(400);
        const nav_seen = seen(nav_u[std.mem.indexOf(u8, nav_u, "/s4/").?..]);
        const ok = try r.block(n, &.{.{ .id = 93, .site = "localhost", .pattern = pat(&p9, "localhost", "/s4/hang*") }}, "");
        r.pump(3000);
        const h = r.hitOf(n, 93);
        const rej = seen("/s4/mark?a5i-rej") - rej0;
        const fu_path = fu[std.mem.indexOf(u8, fu, "/s4/").?..];
        report(rej == 0, "A5-R6-sw-iframe-dest-origin", std.fmt.bufPrint(&d, "{s}: top 127.0.0.1 with a localhost iframe under its own SW ({s}) · top navigates to {s} (server {d}, hangs 8 s) · rule 93 site localhost /s4/hang* after the start ({}) · 1.5 s later the iframe fetches {s} → server now {d} · marks rej +{d} ok +{d} · rule 93 hits {d} sw_hits {d} (want pass: the old 127.0.0.1 document's iframe request — page host 127.0.0.1 on the tab path)", .{ v.label, ictl, nav_u, nav_seen, ok, fu_path, seen(fu_path), rej, seen("/s4/mark?a5i-ok") - ok0, h.hits, h.sw_hits }) catch "");
        r.pump(5500);
        try r.host.send(.{ .destroy_browser = n });
        r.pump(500);
    }
}

/// A5: 사용자의 뒤로가 같은 문서의 다른 주소 항목이고 페이지가 navigate 사건으로 그 기록 이동을 취소하면 확정도 on_before_browse 도 없다 — 기록 토큰이
/// 남아(30 초) 페이지의 history.go(-2) 가 막힌 주소로 가는가. 대조: 취소하지 않음(같은 문서 확정이 토큰을 거둔다) — 페이지의 history.go(-1).
fn a5nc(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_nc", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [3000]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};
    const Arm = struct { label: []const u8, page: []const u8, tab: u64, first: []const u8, self_go: bool = false };
    for ([_]Arm{
        .{ .label = "control: traversal commits, page history.go(-1) 300 ms later", .page = "/a5/nc?c=0", .tab = 10, .first = "/blk/a5nc10" },
        .{ .label = "page cancels the user's same-document traversal (navigate event), history.go(-2) 300 ms later", .page = "/a5/nc?c=1", .tab = 11, .first = "/blk/a5nc11" },
        .{ .label = "same, history.go(-2) 1500 ms later", .page = "/a5/nc?c=1&d=1500", .tab = 13, .first = "/blk/a5nc13" },
        .{ .label = "same, history.go(-2) retried every 2 s for 28 s (token cap 30 s)", .page = "/a5/nc?c=1&rep=1", .tab = 15, .first = "/blk/a5nc15" },
        .{ .label = "sanity: no user back, the page's own history.go(-2)", .page = "/a5/nc?c=1", .tab = 14, .first = "/blk/a5nc14", .self_go = true },
    }) |v| {
        const b = v.tab;
        try r.create(b, uLoop(&u, v.first));
        try r.nav(b, uLoop(&u, v.page), false);
        r.pump(300);
        click(&r, b, 100, 100);
        r.pump(300);
        var hb: [300]u8 = undefined;
        const st0 = r.ev(b, "location.pathname+location.search+' len '+history.length", &hb);
        try r.watch(b);
        const ok = try r.block(b, &rules, "");
        const c0 = seen(v.first);
        const e0 = r.errors.items.len;
        if (v.self_go) {
            var gb: [64]u8 = undefined;
            _ = r.ev(b, "(setTimeout(goSelf,50),'ok')", &gb);
        } else try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
        r.pump(if (std.mem.indexOf(u8, v.page, "rep=1") != null) 31_000 else 4000);
        const e = errOf(&r, b, e0);
        var lb: [1400]u8 = undefined;
        const at = r.ev(b, "JSON.stringify(window.log||null)+' at '+location.pathname+location.search", &lb);
        report(if (v.self_go) (seen(v.first) == c0 and e != null) else seen(v.first) == c0, "A5-R10-traverse-cancel-steal", std.fmt.bufPrint(&d, "{s}: [{s}, {s}, {s}&b (pushState after a click)] state {s} · ruled {} · user back → page log/at {s} · {s} server +{d} · error page {?d} rule {?d} (want blocked: the page's history move is not the user's)", .{ v.label, v.first, v.page, v.page, st0, ok, at, v.first, seen(v.first) - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null }) catch "");
        try r.host.send(.{ .destroy_browser = b });
        r.pump(500);
    }
}

fn grabStr(hay: []const u8, key: []const u8, out: []u8) []const u8 {
    const i = std.mem.indexOf(u8, hay, key) orelse return "";
    const rest = hay[i + key.len ..];
    const e = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    const n = @min(e, out.len);
    @memcpy(out[0..n], rest[0..n]);
    return out[0..n];
}

fn grabInt(hay: []const u8, key: []const u8) i64 {
    const i = std.mem.indexOf(u8, hay, key) orelse return -1;
    const rest = hay[i + key.len ..];
    var e: usize = 0;
    while (e < rest.len and rest[e] >= '0' and rest[e] <= '9') e += 1;
    return std.fmt.parseInt(i64, rest[0..e], 10) catch -1;
}

/// A5: `read_only_methods` 의 메서드가 페이지 스크립트(접근자·Proxy 트랩·custom element 의 getter)를 돌리는가 — 돌리면 토큰을 남긴 채 페이지의
/// 이동을 일으킬 수 있다.
fn a5ro(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_ro", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [3600]u8 = undefined;
    const b: u64 = 12;
    try r.create(b, uLoop(&u, "/a5/ro"));
    r.pump(500);
    const marks = [_][]const u8{ "/a5/mark?getter", "/a5/mark?ownkeys", "/a5/mark?gopd", "/a5/mark?pget", "/a5/mark?has", "/a5/mark?proto", "/a5/mark?ce", "/a5/mark?resize", "/a5/mark?scroll", "/a5/mark?io", "/a5/mark?vvresize", "/a5/mark?vvscroll" };
    var m0: [marks.len]usize = undefined;
    for (marks, 0..) |m, i| m0[i] = seen(m);
    var w: std.Io.Writer = .fixed(&d);
    var pb: [400]u8 = undefined;
    var ob: [200]u8 = undefined;
    var ob2: [200]u8 = undefined;
    _ = r.call(b, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
    const root_id = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#c\"}}", .{root_id}) catch "", 5000) catch null;
    const c_id = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{c_id}) catch "", 5000) catch null;
    const ce_obj = grabStr(r.result.items, "\"objectId\":\"", &ob);
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{root_id}) catch "", 5000) catch null;
    const doc_obj = grabStr(r.result.items, "\"objectId\":\"", &ob2);
    w.print("root {d} c {d} ce_obj {} doc_obj {} · ", .{ root_id, c_id, ce_obj.len > 0, doc_obj.len > 0 }) catch {};
    // `read` — sidecar 가 토큰을 남기는 호출(`devtools_table.startsNavigationCall` 거짓)인가. 5 차 고침: 화면 밖까지 찍기는 읽기가 아니다.
    // 6 차 고침: getProperties 도 읽기가 아니다(Error 값의 설명이 `Error.prepareStackTrace` 를 부른다 — `A6-R10-read-only-error-stack`).
    // 8 차 NIT(K1): `ok` — 그 호출의 답이 ok 여야 하는가(거짓이면 오류가 정답 — `fromSurface:false` 는 CEF 154 가 오류로 답한다, 5 차 문서).
    // 대상을 못 찾아 호출이 모두 오류여도 marks 0 이라 PASS 이던 빈 판을 막는다(A6-lazy 의 답 확인 꼴).
    const Step = struct { m: []const u8, p: []const u8, read: bool = true, ok: bool = true };
    var steps_buf: [18]Step = undefined;
    var ns: usize = 0;
    var sb: [18][400]u8 = undefined;
    steps_buf[ns] = .{ .m = "Runtime.getProperties", .p = std.fmt.bufPrint(&sb[ns], "{{\"objectId\":\"{s}\",\"ownProperties\":false,\"generatePreview\":true}}", .{ce_obj}) catch "", .read = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "Runtime.getProperties", .p = std.fmt.bufPrint(&sb[ns], "{{\"objectId\":\"{s}\",\"ownProperties\":false,\"accessorPropertiesOnly\":true,\"generatePreview\":true}}", .{ce_obj}) catch "", .read = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "Runtime.getProperties", .p = std.fmt.bufPrint(&sb[ns], "{{\"objectId\":\"{s}\",\"ownProperties\":true,\"generatePreview\":true}}", .{doc_obj}) catch "", .read = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "DOM.getOuterHTML", .p = std.fmt.bufPrint(&sb[ns], "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{c_id}) catch "" };
    ns += 1;
    steps_buf[ns] = .{ .m = "DOM.describeNode", .p = std.fmt.bufPrint(&sb[ns], "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{c_id}) catch "" };
    ns += 1;
    // 7 차 고침: getBoxModel 도 읽기가 아니다(건너뛴 하위 트리의 스타일·배치를 강제한다 — `A7-R1-read-list-token`).
    steps_buf[ns] = .{ .m = "DOM.getBoxModel", .p = std.fmt.bufPrint(&sb[ns], "{{\"nodeId\":{d}}}", .{c_id}) catch "", .read = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "DOM.getNodeForLocation", .p = "{\"x\":5,\"y\":5,\"includeUserAgentShadowDOM\":true,\"ignorePointerEventsNone\":true}" };
    ns += 1;
    steps_buf[ns] = .{ .m = "Accessibility.getFullAXTree", .p = "{}" };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{}" };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = msg.devtools_kick_params };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{\"clip\":{\"x\":0,\"y\":2900,\"width\":800,\"height\":200,\"scale\":1}}" };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{\"clip\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100,\"scale\":2}}" };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{\"fromSurface\":false,\"optimizeForSpeed\":true}", .ok = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{\"captureBeyondViewport\":true}", .read = false };
    ns += 1;
    steps_buf[ns] = .{ .m = "Page.captureScreenshot", .p = "{\"captureBeyondViewport\":true,\"clip\":{\"x\":0,\"y\":2900,\"width\":800,\"height\":200,\"scale\":1}}", .read = false };
    ns += 1;
    var ro_marks: usize = 0;
    var nonread_marks: usize = 0;
    var shape_bad: usize = 0;
    for (steps_buf[0..ns]) |st_| {
        var before: usize = 0;
        for (marks, 0..) |m, i| before += seen(m) - m0[i];
        const st = r.call(b, st_.m, st_.p, 5000) catch null;
        r.pump(200);
        var after: usize = 0;
        for (marks, 0..) |m, i| after += seen(m) - m0[i];
        if (st_.read) ro_marks += after - before else nonread_marks += after - before;
        // 기대가 오류인 단계도 답(오류)은 와야 한다 — 시한·끊김은 빈 판이다.
        const shape = st != null and st.? == (if (st_.ok) msg.DevtoolsStatus.ok else msg.DevtoolsStatus.cdp_error);
        if (!shape) shape_bad += 1;
        w.print("{s}{s} {s}{s} marks +{d} · ", .{ st_.m, if (st_.read) "" else "(not read)", if (st) |x| @tagName(x) else "timeout", if (shape) "" else "(UNEXPECTED)", after - before }) catch {};
    }
    var steps_total: usize = 0;
    for (marks, 0..) |m, i| steps_total += seen(m) - m0[i];
    // Proxy: objectId through Runtime.evaluate. getProperties left the read list in the 6th fix — its Proxy-trap marks are recorded, not asserted.
    _ = r.call(b, "Runtime.evaluate", "{\"expression\":\"window.px\"}", 5000) catch null;
    var ob3: [200]u8 = undefined;
    const px_obj = grabStr(r.result.items, "\"objectId\":\"", &ob3);
    r.pump(200);
    var after_eval: usize = 0;
    for (marks, 0..) |m, i| after_eval += seen(m) - m0[i];
    w.print("evaluate(px) marks {d} · ", .{after_eval - steps_total}) catch {};
    var pp: [400]u8 = undefined;
    const st1 = r.call(b, "Runtime.getProperties", std.fmt.bufPrint(&pp, "{{\"objectId\":\"{s}\",\"ownProperties\":true,\"generatePreview\":true}}", .{px_obj}) catch "", 5000) catch null;
    r.pump(300);
    const st2 = r.call(b, "Runtime.getProperties", std.fmt.bufPrint(&pp, "{{\"objectId\":\"{s}\",\"ownProperties\":false,\"generatePreview\":true}}", .{px_obj}) catch "", 5000) catch null;
    r.pump(500);
    var total: usize = 0;
    for (marks, 0..) |m, i| {
        const dlt = seen(m) - m0[i];
        total += dlt;
        if (dlt > 0) w.print("{s}+{d} ", .{ m[8..], dlt }) catch {};
    }
    const targets_ok = root_id > 0 and c_id > 0 and ce_obj.len > 0 and doc_obj.len > 0;
    w.print("· getProperties(px) {s}/{s} · marks: read steps {d}, not-read steps {d}, evaluate {d}, getProperties(px) {d} · shape mismatches {d} (want read 0, targets found, every step answers as expected, not-read screenshots > 0 — the page's marks reach the server; evaluate, getProperties and the not-read screenshots are outside the list since the 6th fix, their count recorded only)", .{ if (st1) |x| @tagName(x) else "timeout", if (st2) |x| @tagName(x) else "timeout", ro_marks, nonread_marks, after_eval - steps_total, total - after_eval, shape_bad }) catch {};
    report(targets_ok and shape_bad == 0 and nonread_marks > 0 and ro_marks == 0, "A5-R10-read-only-runs-no-script", w.buffered());
}

/// 5 차 고침(LOW-2): 사용자의 새로 고침 토큰이 살아 있는 동안(600 ms beforeunload — 그 이동이 아직 시작되지 않았다) 에이전트의 DevTools 화면 찍기가
/// 토큰을 남기는가 — 읽기(`{}`·kick 꼴)는 남기고(새로 고침은 예외로 지나간다), 화면 밖까지 찍기(`captureBeyondViewport` — resize 처리기를 돌린다)는
/// 거둔다(그 새로 고침은 규칙대로 막힌다).
fn a5tok(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_tok", &.{});
    defer stop(&host);
    var tok_run: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    const r = &tok_run;
    var u: [512]u8 = undefined;
    var d: [1200]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/a5/bu600*") }};
    const Arm = struct { label: []const u8, params: ?[]const u8, exempt: bool, tab: u64 };
    for ([_]Arm{
        .{ .label = "control: user reload, no DevTools call", .params = null, .exempt = true, .tab = 30 },
        .{ .label = "Page.captureScreenshot {} during the reload's beforeunload", .params = "{}", .exempt = true, .tab = 31 },
        .{ .label = "Page.captureScreenshot (kick params)", .params = msg.devtools_kick_params, .exempt = true, .tab = 32 },
        .{ .label = "Page.captureScreenshot {captureBeyondViewport:true}", .params = "{\"captureBeyondViewport\":true}", .exempt = false, .tab = 33 },
    }) |v| {
        var qb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&qb, "/a5/bu600?tok{d}", .{v.tab}) catch unreachable;
        r.create(v.tab, uLoop(&u, path)) catch |e| {
            report(false, "A5-R10-screenshot-token", @errorName(e));
            continue;
        };
        r.pump(500);
        r.watch(v.tab) catch {};
        const ok = r.block(v.tab, &rules, "") catch false;
        const c0 = seen(path);
        const e0 = r.errors.items.len;
        r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .reload, .user = true } }) catch {};
        var st_name: []const u8 = "none";
        if (v.params) |pp| {
            const st = r.call(v.tab, "Page.captureScreenshot", pp, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
        }
        r.pump(2500);
        const e = errOf(r, v.tab, e0);
        const reached = seen(path) - c0;
        const pass = if (v.exempt) reached >= 1 and e == null else reached == 0 and e != null;
        report(pass, "A5-R10-screenshot-token", std.fmt.bufPrint(&d, "{s}: ruled {} (rule 1 /a5/bu600*) · user reload + call {s} → server +{d} · error page {?d} rule {?d} (want {s})", .{ v.label, ok, st_name, reached, if (e) |q| q.code else null, if (e) |q| q.rule else null, if (v.exempt) "exempt — the token stays" else "blocked — the call takes the token" }) catch "");
        r.host.send(.{ .destroy_browser = v.tab }) catch {};
        r.pump(300);
    }
}

/// A5: 기록 토큰 — 건너뛰는 항목 셋(몸짓 없는 같은 주소 pushState 셋) 너머로 가는 사용자의 뒤로, 600 ms beforeunload 동안 사용자가 뒤로를 두 번.
fn a5hist(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_hist", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/blk/*") }};
    {
        const b: u64 = 16;
        try r.create(b, uLoop(&u, "/blk/a5s3"));
        try r.nav(b, uLoop(&u, "/a5/same3"), false);
        r.pump(300);
        var hb: [100]u8 = undefined;
        const hl = r.ev(b, "String(history.length)", &hb);
        try r.watch(b);
        _ = try r.block(b, &rules, "");
        const c0 = seen("/blk/a5s3");
        const e0 = r.errors.items.len;
        try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
        r.pump(2500);
        const e = errOf(&r, b, e0);
        var lb: [200]u8 = undefined;
        const at = r.ev(b, "location.pathname", &lb);
        report(seen("/blk/a5s3") > c0, "A5-R10-skip-three", std.fmt.bufPrint(&d, "[/blk/a5s3, /a5/same3 ×4 (three pushState of the same URL without activation)] history.length {s} · user back → server +{d} · error page {?d} rule {?d} · at {s} (want exempt: the user's back skips to a different document)", .{ hl, seen("/blk/a5s3") - c0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
        try r.host.send(.{ .destroy_browser = b });
        r.pump(300);
    }
    {
        const b: u64 = 17;
        try r.create(b, uLoop(&u, "/blk/a5bb"));
        try r.nav(b, uLoop(&u, "/ok/a5mid"), false);
        try r.nav(b, uLoop(&u, "/a5/bu600"), false);
        r.pump(300);
        try r.watch(b);
        _ = try r.block(b, &rules, "");
        const c0 = seen("/blk/a5bb");
        const m0 = seen("/ok/a5mid");
        const e0 = r.errors.items.len;
        try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
        r.pump(100);
        try r.host.send(.{ .nav_action = .{ .browser = b, .action = .back, .user = true } });
        r.pump(3000);
        const e = errOf(&r, b, e0);
        var lb: [200]u8 = undefined;
        const at = r.ev(b, "location.pathname", &lb);
        report(seen("/blk/a5bb") > c0, "A5-R10-double-back", std.fmt.bufPrint(&d, "[/blk/a5bb, /ok/a5mid, /a5/bu600 (600 ms beforeunload)] user back, 100 ms later user back again → /blk/a5bb server +{d} · /ok/a5mid server +{d} · error page {?d} rule {?d} · at {s} (want exempt: both backs are the user's)", .{ seen("/blk/a5bb") - c0, seen("/ok/a5mid") - m0, if (e) |q| q.code else null, if (e) |q| q.rule else null, at }) catch "");
        try r.host.send(.{ .destroy_browser = b });
        r.pump(300);
    }
}

fn sendBlock(r: *Run, b: u64, strict_site: []const u8) !u32 {
    r.gen += 1;
    var v: msg.NetBlock = .{ .browser = b, .generation = r.gen, .strict_site = strict_site, .count = 1 };
    v.rules[0] = .{ .id = 5, .site = "127.0.0.1", .pattern = "*://*/nothing-a5*" };
    try r.host.send(.{ .net_block = v });
    return r.gen;
}

fn reloadCtl(r: *Run, b: u64) []const u8 {
    _ = r.action(b, .reload, false) catch {};
    r.pump(700);
    return ctlOf(r, b);
}

/// A5: 엄격 켬→끔→켬을 답을 기다리지 않고 빠르게, 끝 값이 브라우저의 우회에 맞는가; 렌더러를 죽인 뒤(Page.crash) 끔이 우회를 지우는가.
fn a5strict(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a5_strict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 18;
    try r.create(b, uLoop(&u, "/s/page?ST5"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    // 켬→끔→켬(답 기다리지 않음).
    _ = try sendBlock(&r, b, "127.0.0.1");
    _ = try sendBlock(&r, b, "");
    const g3 = try sendBlock(&r, b, "127.0.0.1");
    const st3 = r.until(Run.strictSettled, b, g3, wait_ms);
    const s3 = r.strict[b];
    const c3 = reloadCtl(&r, b);
    // 끔→켬→끔(답 기다리지 않음).
    _ = try sendBlock(&r, b, "");
    _ = try sendBlock(&r, b, "127.0.0.1");
    const g6 = try sendBlock(&r, b, "");
    const st6 = r.until(Run.stateAt, b, g6, wait_ms);
    r.pump(300);
    const s6 = r.strict[b];
    const c6 = reloadCtl(&r, b);
    // 켬 → 렌더러 죽임 → 다시 불러옴 → 끔.
    const g7 = try sendBlock(&r, b, "127.0.0.1");
    _ = r.until(Run.strictSettled, b, g7, wait_ms);
    const c7 = reloadCtl(&r, b);
    const crash = r.call(b, "Page.crash", "{}", 3000) catch null;
    r.pump(800);
    _ = r.nav(b, uLoop(&u, "/s/page?ST5b"), false) catch {};
    r.pump(800);
    const c8 = ctlOf(&r, b);
    const g9 = try sendBlock(&r, b, "");
    _ = r.until(Run.stateAt, b, g9, wait_ms);
    r.pump(300);
    const c9 = reloadCtl(&r, b);
    const pass = std.mem.eql(u8, c3, "bypassed") and s3 == .on and std.mem.eql(u8, c6, "controlled") and s6 == .off and std.mem.eql(u8, c9, "controlled");
    report(pass, "A5-B-strict-rapid-toggle", std.fmt.bufPrint(&d, "start {s} · on→off→on unanswered: settled {} state {s} reload {s} · off→on→off: settled {} state {s} reload {s} · on: reload {s} · Page.crash {s} → navigate {s} · off: reload {s} (want bypassed/on, controlled/off, final controlled)", .{ c0, st3, @tagName(s3), c3, st6, @tagName(s6), c6, c7, if (crash) |x| @tagName(x) else "timeout", c8, c9 }) catch "");
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// A6: sixth-pass verifier on 56c752cdb and its fix (`--review-block-v20f`, `A6_ONLY=stale,mainerr,ro,tok,lazy`).
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

fn a6want(name: []const u8) bool {
    const v = std.c.getenv("A6_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn runA6(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    try startServer2();
    if (a6want("stale")) a6stale(report, host_path, root) catch |err| report(false, "A6-stale", @errorName(err));
    if (a6want("ro")) a6ro(report, host_path, root) catch |err| report(false, "A6-ro", @errorName(err));
    if (a6want("tok")) a6tok(report, host_path, root) catch |err| report(false, "A6-tok", @errorName(err));
    if (a6want("lazy")) a6lazy(report, host_path, root) catch |err| report(false, "A6-lazy", @errorName(err));
    if (a6want("mainerr")) a6mainerr(report, host_path, root) catch |err| report(false, "A6-mainerr", @errorName(err));
}

/// Y (127.0.0.1, SW, rule 51 */s/swlate*) fetches through its SW — server reach and Y's rule 51 counts.
fn a6yFetch(r: *Run, y: u64, tag: []const u8) struct { got: [40]u8, got_len: usize, reached: usize, sw_hits: u64, na: u64 } {
    var x: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var ub: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&ub, "/s/swlate-a6{s}", .{tag}) catch unreachable;
    const s0 = seen(path);
    const h0 = r.hitOf(y, 51);
    const got = r.ev(y, fetchExpr(&x, path), &o);
    r.pump(600);
    const h = r.hitOf(y, 51);
    var out: [40]u8 = undefined;
    const n = @min(got.len, out.len);
    @memcpy(out[0..n], got[0..n]);
    return .{ .got = out, .got_len = n, .reached = seen(path) - s0, .sw_hits = h.sw_hits - h0.sw_hits, .na = h.sw_not_applied - h0.sw_not_applied };
}

/// A6-stale: err_frames 64 자리를 「떠난 프레임 열쇠」 로 채울 수 있는가 — iframe 하나를 오류 페이지 ↔ 다른 사이트 진짜 문서로 n 번 오가게 한다(살아 있는
/// 프레임은 늘 둘). 열쇠가 남으면 err_unsure 가 되어 A 의 진짜 127.0.0.1 iframe 이 「보일지도」 — 규칙 없는 A 가 빠져 Y 의 규칙이 막는다(넘침).
/// 바라는 것: A 가 127.0.0.1 을 정말 보이고 맞는 규칙이 없다 — 거부권(server +1, not_applied 1).
fn a6stale(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a6_stale", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [2000]u8 = undefined;
    var id: u64 = 2;
    const Arm = struct { n: usize, bad: []const u8, label: []const u8 };
    var badb: [96]u8 = undefined;
    const bad_blk = uLoop(&badb, "/blkifr");
    for ([_]Arm{
        .{ .n = 0, .bad = "B", .label = "control: no cycles" },
        .{ .n = 70, .bad = "B", .label = "70 cycles: blocked by A's rule 42 (-20) <-> real 127.0.0.1 doc" },
        .{ .n = 70, .bad = "http://127.0.0.1:1/refused", .label = "70 cycles: connection refused <-> real 127.0.0.1 doc" },
    }) |v| {
        const y = id;
        const a = id + 1;
        id += 2;
        try r.create(y, uLoop(&u, "/s/page?Y6"));
        const yctl = swReady(&r, y);
        try r.watch(y);
        const oky = try r.block(y, &.{.{ .id = 51, .site = "127.0.0.1", .pattern = "*://*/s/swlate*" }}, "");
        try r.create(a, uLocal(&u, "/a6/one?k=s"));
        try r.watch(a);
        const oka = try r.block(a, &.{.{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" }}, "");
        r.pump(500);
        var o: [200]u8 = undefined;
        var eb: [400]u8 = undefined;
        var kb: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "s{d}", .{y}) catch unreachable;
        _ = r.ev(a, std.fmt.bufPrint(&eb, "(run({d},'{s}','{s}'),'started')", .{ v.n, k, if (std.mem.eql(u8, v.bad, "B")) bad_blk else v.bad }) catch unreachable, &o);
        var cr: []const u8 = "";
        var cb: [120]u8 = undefined;
        const deadline = os.nowMs() + 240_000;
        while (os.nowMs() < deadline) {
            r.pump(1000);
            cr = r.ev(a, "window.cr", &cb);
            if (std.mem.startsWith(u8, cr, "done") or std.mem.startsWith(u8, cr, "err")) break;
        }
        r.pump(800);
        var fb: [80]u8 = undefined;
        const fr = r.ev(a, "String(window.frames.length)+' '+document.getElementById('f').src.replace(/^http:\\/\\/[^/]+/,'')", &fb);
        const h42 = r.hitOf(a, 42).hits;
        var tb: [16]u8 = undefined;
        const res = a6yFetch(&r, y, std.fmt.bufPrint(&tb, "st{d}", .{y}) catch unreachable);
        report(res.reached == 1, "A6-stale-err-keys", std.fmt.bufPrint(&d, "{s}: Y 127.0.0.1 {s} ruled {} (51) · A localhost ruled {} (42 only), cycles → {s}, rule 42 hits {d}, A frames {s} (one REAL 127.0.0.1 iframe) · Y fetch through its SW → {s} · server +{d} · Y rule 51 sw_hits +{d} sw_not_applied +{d} (want server +1, not_applied 1 — A really shows 127.0.0.1 and holds no matching rule: its veto)", .{ v.label, yctl, oky, oka, cr, h42, fr, res.got[0..res.got_len], res.reached, res.sw_hits, res.na }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        try r.host.send(.{ .destroy_browser = y });
        r.pump(800);
    }
}

/// A6-mainerr: 주 프레임의 `on_load_error`(끊김 아님)가 옛 문서를 남기면 frameSettled(main) 가 err_frames·err_unsure·blocked_sub 를 지운다 — 남은
/// 막힌 iframe 의 오류 페이지가 「보인다」 로 돌아와 A 의 거부권이 Y 의 규칙을 「적용 안 됨」 으로 만드는가(샘). 각 갈래: 그 뒤 A 의 문서가 남았는가·
/// 주 프레임 오류 보고(code)·Y 의 fetch(바라는 것: 막힘 server +0).
fn a6mainerr(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a6_mainerr", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [2000]u8 = undefined;
    var id: u64 = 20;
    const Arm = struct { label: []const u8, expr: []const u8 };
    var b204: [96]u8 = undefined;
    var bdl: [96]u8 = undefined;
    var e204: [200]u8 = undefined;
    var edl: [200]u8 = undefined;
    for ([_]Arm{
        .{ .label = "control: nothing", .expr = "" },
        .{ .label = "location -> unknown scheme", .expr = "(location.href='maruxq6://x/y','set')" },
        .{ .label = "location -> data: URL", .expr = "(location.href='data:text/html,a6','set')" },
        .{ .label = "location -> 204", .expr = std.fmt.bufPrint(&e204, "(location.href='{s}','set')", .{uLoop(&b204, "/a6/204")}) catch unreachable },
        .{ .label = "location -> download", .expr = std.fmt.bufPrint(&edl, "(location.href='{s}','set')", .{uLoop(&bdl, "/a6/dl")}) catch unreachable },
        .{ .label = "location -> about:srcdoc", .expr = "(location.href='about:srcdoc','set')" },
        .{ .label = "location -> chrome://version", .expr = "(location.href='chrome://version','set')" },
        .{ .label = "location -> file:///etc/hosts", .expr = "(location.href='file:///etc/hosts','set')" },
    }) |v| {
        const y = id;
        const a = id + 1;
        id += 2;
        try r.create(y, uLoop(&u, "/s/page?Y6m"));
        const yctl = swReady(&r, y);
        try r.watch(y);
        const oky = try r.block(y, &.{.{ .id = 51, .site = "127.0.0.1", .pattern = "*://*/s/swlate*" }}, "");
        try r.create(a, uLocal(&u, "/x/blank?A6m"));
        try r.watch(a);
        const oka = try r.block(a, &.{.{ .id = 42, .site = "localhost", .pattern = "*://*/blkifr*" }}, "");
        var pb: [64]u8 = undefined;
        try r.nav(a, uLocal(&u, std.fmt.bufPrint(&pb, "/a5/ifrs?n=1&k=m{d}", .{a}) catch unreachable), false);
        r.pump(1500);
        var o: [200]u8 = undefined;
        _ = r.ev(a, "(window.mk=1,'mk')", &o);
        var tb: [16]u8 = undefined;
        const before = a6yFetch(&r, y, std.fmt.bufPrint(&tb, "mb{d}", .{y}) catch unreachable);
        const e0 = r.errors.items.len;
        var ob: [80]u8 = undefined;
        const set = if (v.expr.len != 0) r.ev(a, v.expr, &ob) else "none";
        r.pump(2000);
        const e = errOf(&r, a, e0);
        var kb: [120]u8 = undefined;
        const kept = r.ev(a, "String(window.mk)+' '+location.href.slice(0,40)+' frames '+window.frames.length", &kb);
        var tb2: [16]u8 = undefined;
        const after = a6yFetch(&r, y, std.fmt.bufPrint(&tb2, "ma{d}", .{y}) catch unreachable);
        report(before.reached == 0 and after.reached == 0, "A6-mainerr-keeps-doc", std.fmt.bufPrint(&d, "{s}: Y {s} ruled {} · A ruled {} with 1 blocked 127.0.0.1 iframe · Y fetch before → {s} server +{d} · A: {s} → main error_page {?d} · A doc after: {s} · Y fetch after → {s} server +{d} sw_hits +{d} not_applied +{d} (want blocked both times — A only shows an error page)", .{ v.label, yctl, oky, oka, before.got[0..before.got_len], before.reached, set, if (e) |q| q.code else null, kept, after.got[0..after.got_len], after.reached, after.sw_hits, after.na }) catch "");
        try r.host.send(.{ .destroy_browser = a });
        try r.host.send(.{ .destroy_browser = y });
        r.pump(800);
    }
}

/// A6-ro: 6 차 검증 LOW — `Runtime.getProperties` 는 Error 값의 설명(`stack` 을 읽는다)을 만들며 페이지의 `Error.prepareStackTrace` 를 부른다(Error 마다
/// 한 번, own `stack` getter 는 아니다). 6 차 고침으로 getProperties 는 읽기 목록 밖이다(`devtools_table.read_only_methods` — 토큰을 거둔다, `A6-R10-getproperties-token`).
/// 여기서는 목록에 남은 읽기(getDocument·querySelector·resolveNode)가 그 페이지에서 marks 0 인지 단언하고, getProperties 의 marks 는 목록 밖이라 적기만 한다.
fn a6ro(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a6_ro", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [3200]u8 = undefined;
    const b: u64 = 12;
    try r.create(b, uLoop(&u, "/a6/err"));
    r.pump(800);
    var w: std.Io.Writer = .fixed(&d);
    var pb: [400]u8 = undefined;
    var o1: [200]u8 = undefined;
    var o2: [200]u8 = undefined;
    var o3: [200]u8 = undefined;
    const m_all = "/a6/mark?";
    const base = seen(m_all);
    // 목록에 남은 읽기 — 단언한다(marks 0).
    _ = r.call(b, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
    const root_id = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#c\"}}", .{root_id}) catch "", 5000) catch null;
    const c_id = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#d\"}}", .{root_id}) catch "", 5000) catch null;
    const d_id = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{c_id}) catch "", 5000) catch null;
    const c_obj = grabStr(r.result.items, "\"objectId\":\"", &o1);
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{d_id}) catch "", 5000) catch null;
    const d_obj = grabStr(r.result.items, "\"objectId\":\"", &o2);
    r.pump(500);
    const read_marks = seen(m_all) - base;
    w.print("root {d} c {d} d {d} objs {} {} · read steps (getDocument·querySelector×2·resolveNode×2) marks +{d} · ", .{ root_id, c_id, d_id, c_obj.len > 0, d_obj.len > 0, read_marks }) catch {};
    // 목록 밖(6 차 고침) — 적기만 한다.
    const Step = struct { m: []const u8, p: []const u8 };
    var sb: [3][400]u8 = undefined;
    const steps = [_]Step{
        .{ .m = "Runtime.getProperties", .p = std.fmt.bufPrint(&sb[0], "{{\"objectId\":\"{s}\",\"ownProperties\":true}}", .{c_obj}) catch "" },
        .{ .m = "Runtime.getProperties", .p = std.fmt.bufPrint(&sb[1], "{{\"objectId\":\"{s}\",\"ownProperties\":true,\"generatePreview\":true}}", .{d_obj}) catch "" },
    };
    for (steps) |st| {
        const m0 = seen(m_all);
        const res = r.call(b, st.m, st.p, 5000) catch null;
        r.pump(600);
        w.print("{s}(not read) {s} marks +{d} · ", .{ st.m, if (res) |x| @tagName(x) else "timeout", seen(m_all) - m0 }) catch {};
    }
    _ = r.call(b, "Runtime.evaluate", "{\"expression\":\"window\"}", 5000) catch null; // 목록 밖(objectId 를 얻으려고만)
    const win_obj = grabStr(r.result.items, "\"objectId\":\"", &o3);
    const m1 = seen(m_all);
    const res3 = r.call(b, "Runtime.getProperties", std.fmt.bufPrint(&sb[2], "{{\"objectId\":\"{s}\",\"ownProperties\":true}}", .{win_obj}) catch "", 8000) catch null;
    r.pump(600);
    w.print("getProperties(window)(not read) {s} marks +{d} · marks seen: ", .{ if (res3) |x| @tagName(x) else "timeout", seen(m_all) - m1 }) catch {};
    {
        _ = std.c.pthread_mutex_lock(&srv_lock);
        defer _ = std.c.pthread_mutex_unlock(&srv_lock);
        var it = std.mem.splitScalar(u8, srv_log.items, '\n');
        while (it.next()) |line| if (std.mem.indexOf(u8, line, m_all)) |i| {
            const rest = line[i + m_all.len ..];
            w.print("{s} ", .{rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len]}) catch {};
        };
    }
    w.print("(want read 0 — getProperties is outside the read list since the 6th fix, its marks are recorded only)", .{}) catch {};
    // 대상을 얻지 못하면(DOM 호출이 답하지 않았다) 빈 판이다 — 실패로 친다.
    report(read_marks == 0 and c_obj.len > 0 and d_obj.len > 0, "A6-R10-read-only-error-stack", w.buffered());
}

/// A6-tok(6 차 고침): 사용자의 새로 고침 토큰이 살아 있는 동안(600 ms beforeunload) 에이전트의 `Runtime.getProperties` 가 토큰을 거두는가 — 읽기 목록
/// 밖이라 거둔다(그 새로 고침은 규칙대로 막힌다). 대조: 호출 없음·읽기(`DOM.resolveNode`)는 남긴다(새로 고침은 예외로 지나간다).
fn a6tok(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a6_tok", &.{});
    defer stop(&host);
    var tok_run: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    const r = &tok_run;
    var u: [512]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/a6/errbu*") }};
    const Kind = enum { none, resolve_node, props_window_own, props_window_preview, props_node_accessors };
    const Arm = struct { label: []const u8, kind: Kind, exempt: bool, tab: u64 };
    for ([_]Arm{
        .{ .label = "control: user reload, no DevTools call", .kind = .none, .exempt = true, .tab = 34 },
        .{ .label = "DOM.resolveNode (read list) during the reload's beforeunload", .kind = .resolve_node, .exempt = true, .tab = 35 },
        .{ .label = "Runtime.getProperties(window){ownProperties:true}", .kind = .props_window_own, .exempt = false, .tab = 36 },
        .{ .label = "Runtime.getProperties(window){ownProperties:true,generatePreview:true}", .kind = .props_window_preview, .exempt = false, .tab = 37 },
        .{ .label = "Runtime.getProperties(body){accessorPropertiesOnly:true}", .kind = .props_node_accessors, .exempt = false, .tab = 38 },
    }) |v| {
        var qb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&qb, "/a6/errbu?tok{d}", .{v.tab}) catch unreachable;
        r.create(v.tab, uLoop(&u, path)) catch |e| {
            report(false, "A6-R10-getproperties-token", @errorName(e));
            continue;
        };
        r.pump(500);
        r.watch(v.tab) catch {};
        const ok = r.block(v.tab, &rules, "") catch false;
        // 대상(objectId·nodeId)은 새로 고침 전에 얻는다 — 그 호출들(evaluate 는 목록 밖)은 사용자의 새로 고침보다 앞이라 토큰과 무관하다.
        var pb: [400]u8 = undefined;
        var ob: [200]u8 = undefined;
        var method: []const u8 = "";
        var params: []const u8 = "";
        switch (v.kind) {
            .none => {},
            .resolve_node => {
                _ = r.call(v.tab, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
                const root_id = grabInt(r.result.items, "\"nodeId\":");
                method = "DOM.resolveNode";
                params = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{root_id}) catch "";
            },
            .props_window_own, .props_window_preview => {
                _ = r.call(v.tab, "Runtime.evaluate", "{\"expression\":\"window\"}", 5000) catch null;
                const obj = grabStr(r.result.items, "\"objectId\":\"", &ob);
                method = "Runtime.getProperties";
                params = std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\",\"ownProperties\":true{s}}}", .{ obj, if (v.kind == .props_window_preview) ",\"generatePreview\":true" else "" }) catch "";
            },
            .props_node_accessors => {
                _ = r.call(v.tab, "Runtime.evaluate", "{\"expression\":\"document.body\"}", 5000) catch null;
                const obj = grabStr(r.result.items, "\"objectId\":\"", &ob);
                method = "Runtime.getProperties";
                params = std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\",\"ownProperties\":false,\"accessorPropertiesOnly\":true,\"generatePreview\":true}}", .{obj}) catch "";
            },
        }
        r.pump(300);
        const c0 = seen(path);
        const e0 = r.errors.items.len;
        r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .reload, .user = true } }) catch {};
        var st_name: []const u8 = "none";
        var answered = method.len == 0;
        if (method.len != 0) {
            const st = r.call(v.tab, method, params, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
            answered = st != null and st.? == .ok;
        }
        r.pump(2500);
        const e = errOf(r, v.tab, e0);
        const reached = seen(path) - c0;
        // 남기는 대조(읽기)는 호출이 실제로 답해야 한다 — 답하지 않은 호출이 「남겼다」 로 지나가지 않게.
        const pass = if (v.exempt) reached >= 1 and e == null and answered else reached == 0 and e != null;
        report(pass, "A6-R10-getproperties-token", std.fmt.bufPrint(&d, "{s}: ruled {} (rule 1 /a6/errbu*) · user reload + call {s} → server +{d} · error page {?d} rule {?d} (want {s})", .{ v.label, ok, st_name, reached, if (e) |q| q.code else null, if (e) |q| q.rule else null, if (v.exempt) "exempt — the token stays" else "blocked — the call takes the token" }) catch "");
        r.host.send(.{ .destroy_browser = v.tab }) catch {};
        r.pump(300);
    }
}

/// A6-lazy(6 차 고침의 둘째 물음): 읽기 목록에 **남은** 메서드 모두가 getProperties 와 같은 갈래(V8 의 늦은 접근자 — 읽지 않은 Error 의 stack 꼴
/// 만들기·`Error.captureStackTrace` 로 요소에 단 stack·`Symbol.toStringTag`·`toJSON`·`Symbol.toPrimitive`)나 custom element 콜백·접근성 이름 계산
/// (ElementInternals·aria-labelledby·label·shadow·slot)·DOM 원형의 getter·감시자(Mutation·Resize·Intersection)·beforematch·content-visibility·
/// details toggle·늦은 그림 불러오기로 페이지 스크립트를 돌리는가. 단계마다 marks 를 재고 모두 0 을 단언한다.
/// 7 차 고침(NIT): ① 단계마다 답의 꼴(ok·오류)을 기대값과 맞춘다 — 성공해야 할 호출이 실패하면 빈 판이라 FAIL(전에는 ok 29/34 로도 PASS 였다).
/// ② `Network.getResponseBody` 를 실제 요청 번호로 잰다 — `Network.enable` 은 에이전트에게 막혀 있으나 maru 의 W9d② 기록(`net_record`)이 그 탭에
/// 켠다(같은 DevTools 세션). 요청 번호는 `Page.getFrameTree` 의 `loaderId`(문서 요청의 CDP 번호)다. ③ content-visibility 요소를 화면 밖·건너뛴
/// 하위 트리(`cva`·`cvh`)에 두고 그 안의 노드에 읽기를 부른다(7 차 LOW-1 의 갈래) — 끝의 대조(목록 밖 JS 배치)가 그 갈래가 살아 있음을 보인다.
/// 7 차 고침으로 `DOM.getBoxModel`·`CSS.getComputedStyleForNode` 는 읽기 목록 밖이다(건너뛴 하위 트리를 강제한다 — 토큰 판정 `A7-R1-read-list-token`) — 여기서 재지 않는다.
fn a6lazy(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a6_lazy", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [12000]u8 = undefined;
    const b: u64 = 14;
    try r.create(b, uLoop(&u, "/a6/lazy"));
    r.pump(1200);
    var w: std.Io.Writer = .fixed(&d);
    const m_all = "/a6/mark?";
    const m_cv = "/a6/mark?cv-";
    const base = seen(m_all);
    var rb: [64]u8 = undefined;
    const ready = r.ev(b, "String(window.ready)", &rb); // 목록 밖 — 단계 앞이라 단언과 무관
    r.pump(300);
    const setup = seen(m_all) - base;
    var pb: [600]u8 = undefined;
    var ob: [200]u8 = undefined;
    var axb: [64]u8 = undefined;
    _ = r.call(b, "DOM.getDocument", "{\"depth\":-1,\"pierce\":true}", 5000) catch null;
    const root_id = grabInt(r.result.items, "\"nodeId\":");
    var ids: [4]i64 = @splat(-1);
    for ([_][]const u8{ "#c", "#f", "#cvhp", "#cvap" }, 0..) |sel, si| {
        _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"{s}\"}}", .{ root_id, sel }) catch "", 5000) catch null;
        ids[si] = grabInt(r.result.items, "\"nodeId\":");
    }
    const c_id = ids[0];
    const f_id = ids[1];
    const cvh_id = ids[2];
    const cva_id = ids[3];
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{c_id}) catch "", 5000) catch null;
    const c_obj = grabStr(r.result.items, "\"objectId\":\"", &ob);
    // AX 노드 번호는 전체 트리의 첫 노드(뿌리)에서 — `getRootAXNode` 는 CEF 154 에서 `Accessibility.enable`(목록 밖) 없이는 오류다.
    _ = r.call(b, "Accessibility.getFullAXTree", "{\"depth\":2}", 5000) catch null;
    const ax_root = grabStr(r.result.items, "\"nodeId\":\"", &axb);
    r.pump(400);
    const pre = seen(m_all) - base - setup;
    const targets_ok = root_id > 0 and c_id > 0 and f_id > 0 and cvh_id > 0 and cva_id > 0 and c_obj.len > 0 and ax_root.len > 0;
    w.print("ready {s} · setup marks {d} · root {d} c {d} f {d} cvhp {d} cvap {d} c_obj {} ax_root '{s}' · lookup steps marks +{d} · ", .{ ready, setup, root_id, c_id, f_id, cvh_id, cva_id, c_obj.len > 0, ax_root, pre }) catch {};
    // `ok` — 그 호출이 답해야 하는가. 거짓인 셋은 이 판에서 오류가 정답이다(도메인을 켜야 답한다 — 켠 뒤 아래에서 다시 잰다; 없는 요청 번호).
    const Step = struct { m: []const u8, p: []const u8, ok: bool };
    var sb: [48][600]u8 = undefined;
    var steps: [48]Step = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(st: []Step, bufs: [][600]u8, k: *usize, m: []const u8, want_ok: bool, comptime fmt: []const u8, args: anytype) void {
            st[k.*] = .{ .m = m, .p = std.fmt.bufPrint(&bufs[k.*], fmt, args) catch "", .ok = want_ok };
            k.* += 1;
        }
    }.f;
    // `DOM.getDocument` 은 위 찾기에서 쟀다(다시 부르면 노드 번호가 모두 바뀐다).
    add(&steps, &sb, &n, "DOM.querySelector", true, "{{\"nodeId\":{d},\"selector\":\"x-lazy\"}}", .{root_id});
    add(&steps, &sb, &n, "DOM.querySelectorAll", true, "{{\"nodeId\":{d},\"selector\":\"*\"}}", .{root_id});
    add(&steps, &sb, &n, "DOM.describeNode", true, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{c_id});
    add(&steps, &sb, &n, "DOM.describeNode", true, "{{\"objectId\":\"{s}\"}}", .{c_obj});
    add(&steps, &sb, &n, "DOM.resolveNode", true, "{{\"nodeId\":{d}}}", .{c_id});
    add(&steps, &sb, &n, "DOM.resolveNode", true, "{{\"nodeId\":{d}}}", .{f_id});
    add(&steps, &sb, &n, "DOM.resolveNode", true, "{{\"nodeId\":{d}}}", .{root_id});
    add(&steps, &sb, &n, "DOM.getContentQuads", true, "{{\"nodeId\":{d}}}", .{c_id});
    add(&steps, &sb, &n, "DOM.getOuterHTML", true, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{root_id});
    add(&steps, &sb, &n, "DOM.getAttributes", true, "{{\"nodeId\":{d}}}", .{c_id});
    add(&steps, &sb, &n, "DOM.getNodeForLocation", true, "{{\"x\":10,\"y\":10,\"includeUserAgentShadowDOM\":true,\"ignorePointerEventsNone\":true}}", .{});
    // 화면 밖·건너뛴 하위 트리(7 차 LOW-1 의 갈래) — `cvh` 의 글꼴·배경 그림은 그 하위 트리를 강제할 때만 요청된다.
    for ([_]i64{ cvh_id, cva_id }) |id| {
        add(&steps, &sb, &n, "DOM.getContentQuads", true, "{{\"nodeId\":{d}}}", .{id});
        add(&steps, &sb, &n, "DOM.describeNode", true, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{id});
        add(&steps, &sb, &n, "DOM.resolveNode", true, "{{\"nodeId\":{d}}}", .{id});
        add(&steps, &sb, &n, "DOM.getOuterHTML", true, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{id});
        add(&steps, &sb, &n, "Accessibility.getPartialAXTree", true, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{id});
    }
    add(&steps, &sb, &n, "Accessibility.queryAXTree", true, "{{\"nodeId\":{d},\"accessibleName\":\"cvh text\"}}", .{root_id});
    add(&steps, &sb, &n, "Accessibility.getFullAXTree", true, "{{}}", .{});
    add(&steps, &sb, &n, "Accessibility.getPartialAXTree", true, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{c_id});
    add(&steps, &sb, &n, "Accessibility.queryAXTree", true, "{{\"nodeId\":{d},\"accessibleName\":\"label-by\"}}", .{root_id});
    add(&steps, &sb, &n, "Accessibility.queryAXTree", true, "{{\"objectId\":\"{s}\",\"role\":\"button\"}}", .{c_obj});
    add(&steps, &sb, &n, "Accessibility.getRootAXNode", false, "{{}}", .{});
    add(&steps, &sb, &n, "Accessibility.getChildAXNodes", false, "{{\"id\":\"{s}\"}}", .{ax_root});
    add(&steps, &sb, &n, "Page.captureScreenshot", true, "{{}}", .{});
    add(&steps, &sb, &n, "Page.captureScreenshot", true, "{s}", .{msg.devtools_kick_params});
    add(&steps, &sb, &n, "Page.getLayoutMetrics", true, "{{}}", .{});
    add(&steps, &sb, &n, "Page.getFrameTree", true, "{{}}", .{});
    add(&steps, &sb, &n, "Page.getNavigationHistory", true, "{{}}", .{});
    add(&steps, &sb, &n, "Page.getResourceTree", true, "{{}}", .{});
    add(&steps, &sb, &n, "Network.getCookies", true, "{{}}", .{});
    // 없는 요청 번호(이 탭은 기록하지 않는다) — 오류가 정답. 실제 번호는 아래 기록하는 탭에서.
    add(&steps, &sb, &n, "Network.getResponseBody", false, "{{\"requestId\":\"1.1\"}}", .{});
    add(&steps, &sb, &n, "Storage.getCookies", true, "{{}}", .{});
    add(&steps, &sb, &n, "Storage.getUsageAndQuota", true, "{{\"origin\":\"http://127.0.0.1:{d}\"}}", .{port});
    add(&steps, &sb, &n, "Target.getTargetInfo", true, "{{}}", .{});
    add(&steps, &sb, &n, "Browser.getVersion", true, "{{}}", .{});
    add(&steps, &sb, &n, "Runtime.releaseObject", true, "{{\"objectId\":\"{s}\"}}", .{c_obj});
    add(&steps, &sb, &n, "Runtime.releaseObjectGroup", true, "{{\"objectGroup\":\"a6\"}}", .{});
    var total: usize = 0;
    var ok_steps: usize = 0;
    var want_ok: usize = 0;
    var shape_bad: usize = 0;
    for (steps[0..n]) |st| {
        const m0 = seen(m_all);
        const res = r.call(b, st.m, st.p, 5000) catch null;
        r.pump(300);
        const dm = seen(m_all) - m0;
        total += dm;
        const got_ok = res != null and res.? == .ok;
        const got_err = res != null and res.? == .cdp_error;
        if (got_ok) ok_steps += 1;
        if (st.ok) want_ok += 1;
        // 기대가 오류인 단계도 답(오류)은 와야 한다 — 시한·끊김은 빈 판이다.
        const shape = if (st.ok) got_ok else got_err;
        if (!shape) shape_bad += 1;
        w.print("{s} {s}{s} +{d} · ", .{ st.m[0..@min(st.m.len, 40)], if (res) |x| @tagName(x) else "timeout", if (shape) "" else "(UNEXPECTED)", dm }) catch {};
        if (res != null and res.? == .cdp_error) w.print("({s}) · ", .{r.result.items[0..@min(r.result.items.len, 70)]}) catch {};
    }
    // 목록의 둘은 그 도메인을 켜야 답한다(`Accessibility.enable` — 목록 밖, 거둔다). 켠 뒤 다시 잰다(켬 자체의 marks 는 적기만 한다).
    const me = seen(m_all);
    const en_a = r.call(b, "Accessibility.enable", "{}", 5000) catch null;
    r.pump(400);
    w.print("enable(outside the list) Accessibility {s} +{d} · ", .{ if (en_a) |x| @tagName(x) else "timeout", seen(m_all) - me }) catch {};
    var axb2: [64]u8 = undefined;
    var ax2_len: usize = 0;
    var gated_ok: usize = 0;
    for (0..2) |gi| {
        const m0 = seen(m_all);
        const gm: []const u8 = if (gi == 0) "Accessibility.getRootAXNode" else "Accessibility.getChildAXNodes";
        const gp: []const u8 = if (gi == 0) "{}" else std.fmt.bufPrint(&pb, "{{\"id\":\"{s}\"}}", .{axb2[0..ax2_len]}) catch "{}";
        const res = r.call(b, gm, gp, 5000) catch null;
        if (gi == 0) ax2_len = grabStr(r.result.items, "\"nodeId\":\"", &axb2).len;
        r.pump(300);
        const dm = seen(m_all) - m0;
        total += dm;
        if (res != null and res.? == .ok) gated_ok += 1;
        w.print("{s}(enabled) {s} +{d} · ", .{ gm, if (res) |x| @tagName(x) else "timeout", dm }) catch {};
    }
    // 빈 판이 아님을 보인다(목록 밖): 같은 요소의 getProperties 는 페이지 함수를 돌린다 — 이 페이지의 늦은 접근자가 살아 있다.
    _ = r.call(b, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
    const root2 = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#c\"}}", .{root2}) catch "", 5000) catch null;
    const c2 = grabInt(r.result.items, "\"nodeId\":");
    _ = r.call(b, "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{c2}) catch "", 5000) catch null;
    var ob4: [200]u8 = undefined;
    const c_obj2 = grabStr(r.result.items, "\"objectId\":\"", &ob4);
    r.pump(300);
    const ms = seen(m_all);
    const sres = r.call(b, "Runtime.getProperties", std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\",\"ownProperties\":true,\"generatePreview\":true}}", .{c_obj2}) catch "", 5000) catch null;
    r.pump(600);
    const sanity = seen(m_all) - ms;
    w.print("sanity: Runtime.getProperties(c)(not read) {s} +{d} · ", .{ if (sres) |x| @tagName(x) else "timeout", sanity }) catch {};
    // 건너뛴 하위 트리 갈래가 살아 있음(목록 밖 JS 배치 — `cvh` 안의 글꼴·배경 그림을 요청한다). 위 단계의 `cv-*` marks 는 total 에 들었다.
    const mc = seen(m_cv);
    var xb: [64]u8 = undefined;
    const forced = r.ev(b, "String(document.getElementById('cvhp').offsetHeight)", &xb);
    r.pump(1200);
    const cv_sanity = seen(m_cv) - mc;
    w.print("sanity: offsetHeight(cvhp)(not read) {s} → cv marks +{d} · ", .{ forced, cv_sanity }) catch {};
    // 멈춤은 마지막에(멈춤 뒤 처음 도는 페이지 스크립트가 끊겨 marks 가 숨을 수 있다).
    const mt = seen(m_all);
    const rt = r.call(b, "Runtime.terminateExecution", "{}", 5000) catch null;
    r.pump(1500);
    const dt_marks = seen(m_all) - mt;
    total += dt_marks;
    const rt_ok = rt != null and rt.? == .ok;
    w.print("Runtime.terminateExecution {s} +{d} · ok {d}/{d} (want {d}/{d}, shape mismatches {d}) (+ enabled {d}/2) · ", .{ if (rt) |x| @tagName(x) else "timeout", dt_marks, ok_steps + @intFromBool(rt_ok), n + 1, want_ok + 1, n + 1, shape_bad, gated_ok }) catch {};
    r.host.send(.{ .destroy_browser = b }) catch {};
    r.pump(300);
    // 실제 요청 번호의 `Network.getResponseBody`(7 차 NIT(b)): maru 의 기록이 켠 탭에서 문서 요청의 번호(`loaderId`)로.
    const b2: u64 = 15;
    var body_ok = false;
    var body_has = false;
    var body_marks: usize = 0;
    var lb: [80]u8 = undefined;
    var loader: []const u8 = "";
    var rec_on = false;
    rec: {
        r.create(b2, uLoop(&u, "/a6/lazy?rb0")) catch break :rec;
        r.pump(400);
        r.watch(b2) catch break :rec;
        r.host.send(.{ .net_record = .{ .browser = b2, .on = true, .session = 7 } }) catch break :rec;
        const dl = os.nowMs() + 5000;
        while (os.nowMs() < dl and r.record_state[b2] != .on) r.pump(50);
        rec_on = r.record_state[b2] == .on;
        r.nav(b2, uLoop(&u, "/a6/lazy?rb1"), false) catch break :rec;
        r.pump(1500);
        _ = r.call(b2, "Page.getFrameTree", "{}", 5000) catch null;
        loader = grabStr(r.result.items, "\"loaderId\":\"", &lb);
        r.pump(300);
        const m0 = seen(m_all);
        const res = r.call(b2, "Network.getResponseBody", std.fmt.bufPrint(&pb, "{{\"requestId\":\"{s}\"}}", .{loader}) catch "", 5000) catch null;
        body_ok = res != null and res.? == .ok;
        body_has = std.mem.indexOf(u8, r.result.items, "a6lazy") != null;
        r.pump(600);
        body_marks = seen(m_all) - m0;
        total += body_marks;
        w.print("recording tab: record {s} · loaderId '{s}' · Network.getResponseBody(loaderId) {s} body has page {} +{d} · ", .{ @tagName(r.record_state[b2]), loader, if (res) |x| @tagName(x) else "timeout", body_has, body_marks }) catch {};
    }
    r.host.send(.{ .net_record = .{ .browser = b2, .on = false } }) catch {};
    r.host.send(.{ .destroy_browser = b2 }) catch {};
    r.pump(300);
    w.print("marks seen: ", .{}) catch {};
    {
        _ = std.c.pthread_mutex_lock(&srv_lock);
        defer _ = std.c.pthread_mutex_unlock(&srv_lock);
        var it = std.mem.splitScalar(u8, srv_log.items, '\n');
        while (it.next()) |line| if (std.mem.indexOf(u8, line, m_all)) |i| {
            const rest = line[i + m_all.len ..];
            w.print("{s} ", .{rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len]}) catch {};
        };
    }
    w.print("(want 0 marks in every read step — total {d}; every step answers as expected; recorded body read by its real id; sanities > 0)", .{total}) catch {};
    const pass = targets_ok and total == 0 and pre == 0 and shape_bad == 0 and rt_ok and gated_ok == 2 and sanity > 0 and cv_sanity > 0 and rec_on and loader.len > 0 and body_ok and body_has;
    report(pass, "A6-R10-read-list-lazy-accessors", w.buffered());
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// A7: seventh-pass verifier on 2baa301cd and its fix (`--review-block-v20g`, `A7_ONLY=forced,hidden,name,rel,sub,tok`). 6 차 고침 뒤 읽기 목록에
// 남은 메서드가 페이지 스크립트를 돌리거나 페이지 상태(요청)를 바꾸는가: 강제 배치·스타일(content-visibility 로 건너뛴 하위 트리의 글꼴·배경
// 그림·object·transition·컨테이너 쿼리), 숨은 탭의 화면 찍기(렌더 차례의 rAF·감시자), 메서드 이름 꼴. 7 차 고침 뒤 기준: getBoxModel·
// getComputedStyleForNode 는 목록 밖(토큰을 거둔다 — `tok`, 수는 적기만), 숨은 탭의 화면 찍기·releaseObject 뒤 FinalizationRegistry 는 남는 틈(적기만 —
// 빈 판은 FAIL), 나머지 읽기는 +0 을 단언한다.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

/// 화면 밖 `content-visibility:auto`(L) 와 `content-visibility:hidden`(H) — 두 하위 트리는 스타일·배치를 건너뛴다. 그 안의 글꼴(404 — loadingerror)·
/// 배경 그림·컨테이너 쿼리 그림·`<object>`·transition(건너뛰는 동안 class 를 바꿨다)·@starting-style 요소는 누가 그 하위 트리의 스타일·배치를
/// 강제할 때만 요청·이벤트를 낸다. 페이지 스크립트는 `/a7/mark?<이름>-TAG` 로, 요청은 `TAG` 로 서버에 남는다.
const a7_cv_page =
    "<!doctype html><title>a7cv</title><style>" ++
    "@font-face{font-family:A7F;src:url(/a7/font?a-TAG)}@font-face{font-family:A7H;src:url(/a7/font?h-TAG)}" ++
    ".lk{content-visibility:auto;contain-intrinsic-size:auto 40px}.hd{content-visibility:hidden;contain-intrinsic-size:40px 40px}" ++
    ".bg{background-image:url(/a7/res?bg-TAG);width:8px;height:8px}.bgh{background-image:url(/a7/res?bgh-TAG);width:8px;height:8px}" ++
    ".tr{transition:opacity .05s;opacity:1}.tr.x{opacity:.2}@starting-style{.ss{opacity:0}}.ss{transition:opacity .05s;opacity:1}" ++
    ".cq{container-type:inline-size}@container (min-width:1px){.cqi{background-image:url(/a7/res?cq-TAG)}}" ++
    "</style><script>window.M=k=>fetch('/a7/mark?'+k+'-TAG');" ++
    "document.fonts.addEventListener('loading',()=>M('fontloading'));document.fonts.addEventListener('loadingdone',()=>M('fontdone'));document.fonts.addEventListener('loadingerror',()=>M('fonterr'));" ++
    "new PerformanceObserver(l=>{for(const e of l.getEntries())if(e.name.includes('/a7/res')||e.name.includes('/a7/font')||e.name.includes('/a7/obj'))M('perf')}).observe({type:'resource'});" ++
    "for(const t of ['transitionrun','transitionstart','transitionend','animationstart'])addEventListener(t,e=>M(t+'-'+e.target.id),true);" ++
    "document.addEventListener('contentvisibilityautostatechange',e=>{if(window.ready)M('cvas-'+e.target.id+'-'+e.skipped)},true);" ++
    "</script><div style='height:3000px'>top</div>" ++
    "<div class=lk id=L><p id=lp style='font-family:A7F'>auto text</p><div id=lbg class=bg></div><div id=ltr class=tr>t</div>" ++
    "<div class=cq><div id=lcq class=cqi>cq</div></div><object id=lobj data='/a7/obj?l-TAG' type='text/html' width=20 height=20 onload=\"M('lobjload')\"></object></div>" ++
    "<div class=hd id=H><p id=hp style='font-family:A7H'>hidden text</p><div id=hbg class=bgh></div><div id=htr class=tr>h</div>" ++
    "<object id=hobj data='/a7/obj?h-TAG' type='text/html' width=20 height=20 onload=\"M('hobjload')\"></object></div>" ++
    "<script>new ResizeObserver(()=>{if(window.ready)M('ro')}).observe(document.getElementById('lp'));" ++
    "requestAnimationFrame(()=>requestAnimationFrame(()=>{document.getElementById('ltr').classList.add('x');document.getElementById('htr').classList.add('x');" ++
    "const s=document.createElement('div');s.id='lss';s.className='ss';s.textContent='s';document.getElementById('L').append(s);setTimeout(()=>window.ready=1,400)}));" ++
    "</script>";

/// 숨은 탭: `arm()` 이 rAF·ResizeObserver·IntersectionObserver 를 건다 — 숨은 탭은 렌더 차례가 돌지 않아 스스로는 부르지 않는다. 화면 아래 늦은 그림.
const a7_hid_page =
    "<!doctype html><title>a7hid</title><script>window.M=k=>fetch('/a7/mark?'+k+'-TAG');" ++
    "document.addEventListener('visibilitychange',()=>M('vis-'+document.visibilityState));" ++
    "window.arm=()=>{requestAnimationFrame(()=>M('raf'));new ResizeObserver(()=>M('ro')).observe(document.getElementById('z'));" ++
    "new IntersectionObserver(()=>M('io')).observe(document.getElementById('z'));document.getElementById('z').style.width='9px';return document.visibilityState};" ++
    "</script><p>hid</p><div id=z style='width:5px;height:5px;background:red'></div>";

fn a7want(name: []const u8) bool {
    const v = std.c.getenv("A7_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn runA7(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    try startServer2();
    if (a7want("forced")) a7forced(report, host_path, root) catch |err| report(false, "A7-forced", @errorName(err));
    if (a7want("hidden")) a7hidden(report, host_path, root) catch |err| report(false, "A7-hidden", @errorName(err));
    if (a7want("name")) a7name(report, host_path, root) catch |err| report(false, "A7-name", @errorName(err));
    if (a7want("rel")) a7rel(report, host_path, root) catch |err| report(false, "A7-rel", @errorName(err));
    if (a7want("sub")) a7sub(report, host_path, root) catch |err| report(false, "A7-sub", @errorName(err));
    if (a7want("tok")) a7tok(report, host_path, root) catch |err| report(false, "A7-tok", @errorName(err));
}

/// 서버 줄 가운데 `tag` 를 담은 것의 대상만 `from` 번째부터 적는다.
fn a7lines(w: *std.Io.Writer, tag: []const u8, from: usize) void {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    var it = std.mem.splitScalar(u8, srv_log.items, '\n');
    var k: usize = 0;
    while (it.next()) |line| if (std.mem.indexOf(u8, line, tag) != null) {
        defer k += 1;
        if (k < from) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next();
        w.print("{s} ", .{parts.next() orelse ""}) catch {};
    };
}

const A7Kind = enum { none, lookup, box_lp, quads_lp, box_hp, quads_hp, ax_partial_hp, outer_h_shadow, quads_ltr, ax_full, ax_partial_lp, ax_query, outer_l, describe_l, resolve_lp, shot_clip_below, shot_kick, layout_metrics, node_at, js_rect, js_scroll };

/// A7-forced: 탭마다 새 페이지(그 탭만의 TAG). 찾기(getDocument·querySelector — 읽기)로 노드 번호를 얻은 뒤 한 메서드를 부르고 1.5 초 동안 그 TAG 의
/// 요청·marks 를 센다. 읽기 목록의 메서드는 0 이어야 한다. 대조: 아무 호출 없음(0), 같은 일을 하는 페이지 JS(목록 밖 — 탐침이 살아 있음을 보인다).
fn a7forced(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_forced", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [4000]u8 = undefined;
    const kinds = std.enums.values(A7Kind);
    for (kinds, 0..) |kind, ki| {
        const b: u64 = 1 + ki;
        var tb: [32]u8 = undefined;
        const tag = std.fmt.bufPrint(&tb, "a7f{d}x", .{ki}) catch unreachable;
        var pathb: [64]u8 = undefined;
        r.create(b, uLoop(&u, std.fmt.bufPrint(&pathb, "/a7/cv?{s}", .{tag}) catch unreachable)) catch |e| {
            report(false, "A7-forced", @errorName(e));
            continue;
        };
        r.pump(1500);
        var w: std.Io.Writer = .fixed(&d);
        const at_load = seen(tag);
        w.print("{s}: after load {d} reqs [", .{ @tagName(kind), at_load }) catch {};
        a7lines(&w, tag, 0);
        w.print("] · ", .{}) catch {};
        var pb: [600]u8 = undefined;
        var lp: i64 = -1;
        var hp: i64 = -1;
        var ltr: i64 = -1;
        var l_id: i64 = -1;
        var root_id: i64 = -1;
        var lookup_delta: usize = 0;
        if (kind != .none and kind != .js_rect and kind != .js_scroll and kind != .shot_clip_below and kind != .shot_kick and kind != .layout_metrics and kind != .node_at and kind != .ax_full) {
            const l0 = seen(tag);
            _ = r.call(b, "DOM.getDocument", "{\"depth\":-1,\"pierce\":true}", 5000) catch null;
            root_id = grabInt(r.result.items, "\"nodeId\":");
            const sels = [_][]const u8{ "#lp", "#hp", "#ltr", "#L" };
            var ids: [4]i64 = @splat(-1);
            for (sels, 0..) |sel, si| {
                _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"{s}\"}}", .{ root_id, sel }) catch "", 5000) catch null;
                ids[si] = grabInt(r.result.items, "\"nodeId\":");
            }
            lp = ids[0];
            hp = ids[1];
            ltr = ids[2];
            l_id = ids[3];
            r.pump(1200);
            lookup_delta = seen(tag) - l0;
            w.print("lookup (getDocument·querySelector×4) root {d} lp {d} hp {d} ltr {d} L {d} → +{d} · ", .{ root_id, lp, hp, ltr, l_id, lookup_delta }) catch {};
        }
        const m: []const u8, const p: []const u8 = switch (kind) {
            .none, .lookup => .{ "", "" },
            .box_lp => .{ "DOM.getBoxModel", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{lp}) catch "" },
            .quads_lp => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{lp}) catch "" },
            .box_hp => .{ "DOM.getBoxModel", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{hp}) catch "" },
            .quads_hp => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{hp}) catch "" },
            .ax_partial_hp => .{ "Accessibility.getPartialAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{hp}) catch "" },
            .outer_h_shadow => .{ "DOM.getOuterHTML", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{hp}) catch "" },
            .quads_ltr => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{ltr}) catch "" },
            .ax_full => .{ "Accessibility.getFullAXTree", "{}" },
            .ax_partial_lp => .{ "Accessibility.getPartialAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{lp}) catch "" },
            .ax_query => .{ "Accessibility.queryAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"accessibleName\":\"auto text\"}}", .{root_id}) catch "" },
            .outer_l => .{ "DOM.getOuterHTML", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{l_id}) catch "" },
            .describe_l => .{ "DOM.describeNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{l_id}) catch "" },
            .resolve_lp => .{ "DOM.resolveNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"objectGroup\":\"a7\"}}", .{lp}) catch "" },
            .shot_clip_below => .{ "Page.captureScreenshot", "{\"format\":\"png\",\"clip\":{\"x\":0,\"y\":3000,\"width\":200,\"height\":100,\"scale\":1}}" },
            .shot_kick => .{ "Page.captureScreenshot", msg.devtools_kick_params },
            .layout_metrics => .{ "Page.getLayoutMetrics", "{}" },
            .node_at => .{ "DOM.getNodeForLocation", "{\"x\":5,\"y\":5,\"includeUserAgentShadowDOM\":true}" },
            .js_rect => .{ "Runtime.evaluate", "{\"expression\":\"document.getElementById('lp').getBoundingClientRect().height+document.getElementById('hp').getBoundingClientRect().height\",\"returnByValue\":true}" },
            .js_scroll => .{ "Runtime.evaluate", "{\"expression\":\"document.getElementById('L').scrollIntoView(),1\",\"returnByValue\":true}" },
        };
        const c0 = seen(tag);
        var st_name: []const u8 = "-";
        if (m.len != 0) {
            const st = r.call(b, m, p, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
            if (st != null and st.? == .cdp_error) w.print("({s}) ", .{r.result.items[0..@min(r.result.items.len, 80)]}) catch {};
        }
        r.pump(1500);
        const delta = seen(tag) - c0;
        w.print("call {s} {s} → +{d} [", .{ m, st_name, delta }) catch {};
        a7lines(&w, tag, c0);
        w.print("]", .{}) catch {};
        const sanity = kind == .js_rect or kind == .js_scroll;
        // 8 차 NIT(H 판): H(c-v:hidden) 안의 노드를 부르는 읽기 판은 그 탭에서 H 가 호출 전까지 건너뛴 채였는지(H 자원 0)와, 끝의 페이지 JS 강제
        // (목록 밖)로 > 0 인지(갈래가 살아 있다)를 본다 — 대조 js_rect 는 다른 탭이라, H 가 보이게 바뀌어도 이 판들은 +0 이라 PASS 이던 빈 판을 막는다.
        const h_arm = kind == .quads_hp or kind == .ax_partial_hp or kind == .outer_h_shadow;
        var h_live = true;
        if (h_arm) {
            var hb: [3][40]u8 = undefined;
            var hn: [3][]const u8 = undefined;
            for ([_][]const u8{ "bgh-", "?h-", "hobjload-" }, 0..) |pre, hi| hn[hi] = std.fmt.bufPrint(&hb[hi], "{s}{s}", .{ pre, tag }) catch "";
            var h_before: usize = 0;
            for (hn) |n| h_before += seenBefore(n, c0);
            var h0: usize = 0;
            for (hn) |n| h0 += seen(n);
            const f0 = seen(tag);
            const fst = r.call(b, "Runtime.evaluate", "{\"expression\":\"(e=>getComputedStyle(e).width+'/'+e.getBoundingClientRect().height)(document.getElementById('hp'))\",\"returnByValue\":true}", 5000) catch null;
            r.pump(1500);
            var h1: usize = 0;
            for (hn) |n| h1 += seen(n);
            h_live = h_before == 0 and fst != null and fst.? == .ok and h1 > h0;
            w.print(" · H resources before the call {d} · then page JS forces H(outside the list) {s} → +{d} (H +{d}) [", .{ h_before, if (fst) |x| @tagName(x) else "timeout", seen(tag) - f0, h1 - h0 }) catch {};
            a7lines(&w, tag, f0);
            w.print("] (want 0 before, > 0 forced)", .{}) catch {};
        }
        // 7 차 고침: `DOM.getBoxModel` 은 읽기 목록 밖이다(H 에서 +10 — 토큰을 거둔다, `A7-R1-read-list-token`). 수는 적기만 한다.
        const outside = kind == .box_lp or kind == .box_hp;
        const answered = m.len == 0 or std.mem.eql(u8, st_name, "ok");
        // 읽기 목록의 메서드(와 대조 none·lookup)는 0, 탐침 대조(목록 밖 JS)는 > 0 이어야 한다. 답하지 않은 호출은 빈 판이라 실패.
        const pass = if (sanity) delta > 0 else if (outside) (lookup_delta == 0 and answered) else (h_live and delta == 0 and lookup_delta == 0 and answered);
        if (outside) w.print(" (outside the read list since the 7th fix — recorded, not asserted)", .{}) catch {};
        report(pass, if (sanity) "A7-R1-forced-sanity" else if (outside) "A7-R1-outside-list" else "A7-R1-read-list-forced-style-layout", w.buffered());
        r.host.send(.{ .destroy_browser = b }) catch {};
        r.pump(200);
    }
}

const A7HidKind = enum { none, shot_kick, shot_plain, box_body, ax_full, layout_metrics, get_document };

/// A7-hidden: 숨은 탭에서 읽기 목록의 메서드가 렌더 차례(rAF·ResizeObserver·IntersectionObserver)를 돌리는가 — `arm()` 뒤 1.5 초 동안 0 인지(대조),
/// 그다음 메서드 하나를 부르고 1.5 초 동안 marks 를 센다. 8 차 NIT(K2): 같은 탭의 양의 대조 — 끝에 다시 보이게 해 미뤄 둔 콜백이 도는지(+0 인 읽기 판),
/// 화면 찍기 판은 그 호출이 렌더 차례를 돌렸는지(> 0)를 단언한다. 페이지의 기록 함수가 죽어도 +0 이라 PASS 이던 빈 판을 막는다.
fn a7hidden(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_hidden", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [2600]u8 = undefined;
    for (std.enums.values(A7HidKind), 0..) |kind, ki| {
        const b: u64 = 20 + ki;
        var tb: [32]u8 = undefined;
        const tag = std.fmt.bufPrint(&tb, "a7h{d}x", .{ki}) catch unreachable;
        var pathb: [64]u8 = undefined;
        r.create(b, uLoop(&u, std.fmt.bufPrint(&pathb, "/a7/hid?{s}", .{tag}) catch unreachable)) catch |e| {
            report(false, "A7-hidden", @errorName(e));
            continue;
        };
        r.pump(800);
        try r.host.send(.{ .set_hidden = .{ .browser = b, .value = true } });
        r.pump(1000);
        var w: std.Io.Writer = .fixed(&d);
        var vb: [32]u8 = undefined;
        const a0 = seen(tag);
        const vis = r.ev(b, "arm()", &vb); // 목록 밖 — 설정(토큰과 무관)
        r.pump(1500);
        const armed = seen(tag) - a0;
        w.print("{s}: hidden, arm() → {s} · 1.5 s idle → +{d} [", .{ @tagName(kind), vis, armed }) catch {};
        a7lines(&w, tag, a0);
        w.print("] · ", .{}) catch {};
        const m: []const u8, const p: []const u8 = switch (kind) {
            .none => .{ "", "" },
            .shot_kick => .{ "Page.captureScreenshot", msg.devtools_kick_params },
            .shot_plain => .{ "Page.captureScreenshot", "{}" },
            .box_body => .{ "DOM.getBoxModel", "" },
            .ax_full => .{ "Accessibility.getFullAXTree", "{}" },
            .layout_metrics => .{ "Page.getLayoutMetrics", "{}" },
            .get_document => .{ "DOM.getDocument", "{\"depth\":-1}" },
        };
        var pb: [200]u8 = undefined;
        var params = p;
        if (kind == .box_body) {
            _ = r.call(b, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
            const root_id = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#z\"}}", .{root_id}) catch "", 5000) catch null;
            const z = grabInt(r.result.items, "\"nodeId\":");
            params = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{z}) catch "";
        }
        const c0 = seen(tag);
        var st_name: []const u8 = "-";
        if (m.len != 0) {
            const st = r.call(b, m, params, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
        }
        r.pump(1500);
        const delta = seen(tag) - c0;
        w.print("call {s} {s} → +{d} [", .{ m, st_name, delta }) catch {};
        a7lines(&w, tag, c0);
        // 7 차 LOW-2: 화면 찍기(maru 의 kick 꼴 포함)는 숨은 탭에서 렌더 차례를 한 번 돈다 — kick 은 그 목적 자체가 숨은 탭의 rAF 를 돌리는 것이라
        // (W9b②-3) 목록에 남는다. 남는 틈(페이지 타이머와 같은 등급) — 수는 적기만 한다. getBoxModel 은 7 차 고침으로 목록 밖이다(적기만).
        // 빈 판(숨지 않음·감시자가 스스로 돎·답 없음)은 FAIL 이다.
        const gap = kind == .shot_kick or kind == .shot_plain;
        const outside = kind == .box_body;
        // 양의 대조(8 차 NIT K2): 다시 보이게 하면 미뤄 둔 rAF·감시자가 돈다(+0 인 읽기 판은 그 셋이 > 0 — 갈래와 기록 함수가 살아 있다).
        try r.host.send(.{ .set_hidden = .{ .browser = b, .value = false } });
        const v0 = seen(tag);
        var cb_b: [3][32]u8 = undefined;
        var cb0: [3]usize = undefined;
        for ([_][]const u8{ "raf", "ro", "io" }, 0..) |cb, ci| {
            cb0[ci] = seen(std.fmt.bufPrint(&cb_b[ci], "mark?{s}-{s}", .{ cb, tag }) catch "");
        }
        r.pump(1500);
        const shown = seen(tag) - v0;
        var deferred: usize = 0;
        for ([_][]const u8{ "raf", "ro", "io" }, 0..) |cb, ci| deferred += seen(std.fmt.bufPrint(&cb_b[ci], "mark?{s}-{s}", .{ cb, tag }) catch "") - cb0[ci];
        w.print("] · shown again → +{d} (deferred rAF·RO·IO +{d}) [", .{ shown, deferred }) catch {};
        a7lines(&w, tag, v0);
        w.print("] (want hidden, idle +0, {s})", .{if (gap) "call recorded > 0 — documented gap: a hidden tab's screenshot runs one rendering step (positive control)" else if (outside) "call recorded — outside the read list; shown again > 0" else "call +0; shown again, the deferred callbacks run > 0"}) catch {};
        const answered = m.len == 0 or std.mem.eql(u8, st_name, "ok");
        const live = std.mem.eql(u8, vis, "hidden") and armed == 0 and answered;
        const pass = if (gap) (live and delta > 0) else if (outside) (live and shown > 0) else (live and delta == 0 and deferred > 0);
        report(pass, if (gap) "A7-R1-hidden-tab-screenshot-gap" else if (outside) "A7-R1-outside-list" else "A7-R1-hidden-tab-read-runs-frame", w.buffered());
        r.host.send(.{ .destroy_browser = b }) catch {};
        r.pump(200);
    }
}

/// A7-name: 대소문자만 다른 getProperties 이름(sidecar 는 목록 밖이라 거둔다 — 순수 `A7-name`)을 Chromium 이 getProperties 로 처리하는가.
/// `/a6/err` 의 `window.e8`(읽지 않은 Error)로 — 처리되면 prepareStackTrace 가 돈다. 대조: 바른 이름은 +1.
fn a7name(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_name", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 30;
    try r.create(b, uLoop(&u, "/a6/err"));
    r.pump(800);
    var w: std.Io.Writer = .fixed(&d);
    var ob: [200]u8 = undefined;
    _ = r.call(b, "Runtime.evaluate", "{\"expression\":\"window\"}", 5000) catch null;
    const win = grabStr(r.result.items, "\"objectId\":\"", &ob);
    var pb: [400]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\",\"ownProperties\":true}}", .{win}) catch "";
    var all_err = true;
    var total: usize = 0;
    for ([_][]const u8{ "runtime.getProperties", "Runtime.GetProperties", "Runtime.getproperties", "RUNTIME.GETPROPERTIES", "Runtime..getProperties", "Runtime.getProperties" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) |name| {
        const m0 = seen("/a6/mark?");
        const st = r.call(b, name, params, 5000) catch null;
        r.pump(500);
        const dm = seen("/a6/mark?") - m0;
        total += dm;
        if (st == null or st.? != .cdp_error) all_err = false;
        w.print("{s} {s} +{d} · ", .{ name[0..@min(name.len, 24)], if (st) |x| @tagName(x) else "timeout", dm }) catch {};
    }
    const m1 = seen("/a6/mark?");
    const st = r.call(b, "Runtime.getProperties", params, 5000) catch null;
    r.pump(600);
    const sanity = seen("/a6/mark?") - m1;
    w.print("sanity Runtime.getProperties {s} +{d} (want variants cdp_error +0, sanity > 0)", .{ if (st) |x| @tagName(x) else "timeout", sanity }) catch {};
    report(win.len > 0 and all_err and total == 0 and sanity > 0, "A7-R2-method-name-forms", w.buffered());
}

/// A7-rel: `Runtime.releaseObject`(읽기 목록의 예외)가 페이지의 처리기를 부르는가 — 페이지가 놓은 객체를 DevTools 만 쥐고 있으면, 놓는 순간
/// 그 객체가 거둘 수 있게 되고 다음 GC 뒤 페이지의 `FinalizationRegistry` 콜백(페이지 스크립트)이 돈다. 대조: 놓지 않은 동안은 `fr-held` 가 없다
/// (페이지 스스로 놓은 `ctrl` 은 GC 가 돈다는 증거).
fn a7rel(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_rel", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1200]u8 = undefined;
    const b: u64 = 31;
    try r.create(b, uLoop(&u, "/a7/gc"));
    r.pump(500);
    var ob: [200]u8 = undefined;
    _ = r.call(b, "Runtime.evaluate", "{\"expression\":\"mk()\"}", 5000) catch null;
    const obj = grabStr(r.result.items, "\"objectId\":\"", &ob);
    r.pump(6000);
    const ctrl = seen("/a7/mark?fr-ctrl-gc");
    const held_before = seen("/a7/mark?fr-held-gc");
    var pb: [300]u8 = undefined;
    const st = r.call(b, "Runtime.releaseObject", std.fmt.bufPrint(&pb, "{{\"objectId\":\"{s}\"}}", .{obj}) catch "", 5000) catch null;
    r.pump(8000);
    const held_after = seen("/a7/mark?fr-held-gc");
    // 7 차 LOW-3: 놓기는 maru 의 정리라 목록에 남는다 — 그 뒤 GC 가 페이지의 FinalizationRegistry 콜백을 돌릴 수 있다(남는 틈 — 적기만).
    // 빈 판(대상 없음·GC 가 돌지 않음·DevTools 가 쥔 동안 이미 돎·답 없음)은 FAIL 이다.
    const text = std.fmt.bufPrint(&d, "obj {} · 6 s held by DevTools: fr-ctrl {d} fr-held {d} · releaseObject {s} → 8 s: fr-held {d} (recorded — documented gap: after a release the page's FinalizationRegistry callback may run on the next GC)", .{ obj.len > 0, ctrl, held_before, if (st) |x| @tagName(x) else "timeout", held_after }) catch "";
    report(obj.len > 0 and ctrl > 0 and held_before == 0 and st != null and st.? == .ok, "A7-R3-release-object-finalization-gap", text);
}

/// 7 차 고침(LOW-1 의 같은 갈래를 목록에 남은 메서드에): 스타일·배치를 건너뛰는 하위 트리 — `content-visibility:hidden`(화면 밖 cvh, 화면 안 cvhv —
/// 위치로 찾는 `getNodeForLocation` 은 화면 안에서만 노드를 찾는다), 화면 밖 `content-visibility:auto`(cva), `hidden=until-found`(huf), 닫힌
/// `<details>`(det) — 이 셋은 불러오기(load) 1 초 뒤에 내용을 넣는다 — 와 `display:none`(dn). 실측(CEF 154): cva·huf·det 는 넣은 뒤 곧 스타일·배치되어
/// 자원을 받는다(강제할 것이 남지 않는다 — 판정은 적는다), 건너뛰기가 남는 것은 c-v:hidden 이고 display:none 은 페이지 JS 의 강제(대조)로도 요청이 없다.
/// 각 하위 트리 안: 제 글꼴(404 — document.fonts 이벤트)·배경 그림·`<object>`(onload) — PerformanceObserver 가 받은 것을 `/a7/mark?` 로 남긴다.
/// 누가 그 하위 트리의 스타일·배치를 강제하면 요청·marks 가 그 탭의 `TAG` 로 서버에 온다.
const a7_sub_page =
    "<!doctype html><title>a7sub</title><style>" ++
    "@font-face{font-family:Fcvh;src:url(/a7/font?f-cvh-TAG)}@font-face{font-family:Fcva;src:url(/a7/font?f-cva-TAG)}@font-face{font-family:Fhuf;src:url(/a7/font?f-huf-TAG)}" ++
    "@font-face{font-family:Fdet;src:url(/a7/font?f-det-TAG)}@font-face{font-family:Fdn;src:url(/a7/font?f-dn-TAG)}@font-face{font-family:Fcvhv;src:url(/a7/font?f-cvhv-TAG)}" ++
    ".bx{position:absolute;left:0;width:200px;height:60px}.g{width:8px;height:8px}" ++
    ".gcvh{background-image:url(/a7/res?bg-cvh-TAG)}.gcva{background-image:url(/a7/res?bg-cva-TAG)}.ghuf{background-image:url(/a7/res?bg-huf-TAG)}" ++
    ".gdet{background-image:url(/a7/res?bg-det-TAG)}.gdn{background-image:url(/a7/res?bg-dn-TAG)}.gcvhv{background-image:url(/a7/res?bg-cvhv-TAG)}" ++
    "</style><script>window.M=k=>fetch('/a7/mark?'+k+'-TAG');" ++
    "document.fonts.addEventListener('loading',()=>M('fontloading'));document.fonts.addEventListener('loadingdone',()=>M('fontdone'));document.fonts.addEventListener('loadingerror',()=>M('fonterr'));" ++
    "new PerformanceObserver(l=>{for(const e of l.getEntries()){const m=/[?](f|bg|o)-([a-z]+)-/.exec(e.name);if(m)M('perf-'+m[1]+'-'+m[2])}}).observe({type:'resource'});" ++
    "document.addEventListener('contentvisibilityautostatechange',e=>{if(window.ready)M('cvas-'+e.target.id+'-'+e.skipped)},true);" ++
    "document.addEventListener('beforematch',e=>M('beforematch-'+e.target.id),true);document.addEventListener('toggle',e=>M('toggle-'+e.target.id),true);" ++
    "const I=s=>`<p id=p${s} style='font-family:F${s}'>${s} text</p><div class='g g${s}'></div><object data='/a7/obj?o-${s}-TAG' type='text/html' width=20 height=20 onload=\"M('obj-${s}')\"></object>`;" ++
    "</script><div style='height:6000px'>top</div>" ++
    "<div id=cvh class=bx style='top:3000px;content-visibility:hidden;contain-intrinsic-size:200px 60px'></div>" ++
    "<div id=cvhv class=bx style='top:100px;content-visibility:hidden;contain-intrinsic-size:200px 60px'></div>" ++
    "<div id=cva class=bx style='top:3200px;content-visibility:auto;contain-intrinsic-size:200px 60px'></div>" ++
    "<div id=huf class=bx style='top:3400px' hidden=until-found></div>" ++
    "<details id=det class=bx style='top:3600px'><summary>det sum</summary><div id=detb></div></details>" ++
    "<div id=dn style='display:none'></div>" ++
    "<script>for(const s of ['cvh','cvhv','dn'])document.getElementById(s).innerHTML=I(s);" ++
    "addEventListener('load',()=>setTimeout(()=>{for(const s of ['cva','huf'])document.getElementById(s).innerHTML=I(s);document.getElementById('detb').innerHTML=I('det');setTimeout(()=>window.ready=1,400)},1000));" ++
    "</script>";

const A7SubKind = enum { quads, describe, ax_partial, ax_query, css, node_at, box, js };
const A7DocKind = enum { none, ax_full, layout_metrics, ax_root, ax_child, state };
/// `skipped` — 이 판에서 그 하위 트리가 건너뛴 채 남아 있어야 하는가(불러온 뒤 그 자원이 없어야 하고, 페이지 JS 의 강제 대조가 > 0 이어야 한다).
const a7_subs = [_]struct { id: []const u8, top: u32, skipped: bool }{
    .{ .id = "cvh", .top = 3000, .skipped = true },  .{ .id = "cvhv", .top = 100, .skipped = true },  .{ .id = "cva", .top = 3200, .skipped = false },
    .{ .id = "huf", .top = 3400, .skipped = false }, .{ .id = "det", .top = 3600, .skipped = false }, .{ .id = "dn", .top = 0, .skipped = false },
};

/// 7 차 고침의 실측(`A7_ONLY=sub`, `A7_SUB_ARM=<이름 조각>`): 건너뛴 하위 트리 × 읽기 목록의 메서드(+ 목록 밖 getBoxModel·CSS·페이지 JS 대조),
/// 문서 전체를 보는 읽기. 읽기 목록의 메서드는 +0 이어야 한다. 목록 밖은 적기만 한다(토큰 판정은 `A7-R1-read-list-token`).
/// `needle` 을 담은 서버 줄 가운데 처음 `upto` 줄(그 탭의 TAG 기준 — `seen(tag)` 의 수) 안의 것.
fn seenBefore(needle: []const u8, upto: usize) usize {
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    const tag_at = std.mem.lastIndexOfScalar(u8, needle, '-') orelse return 0;
    const tag = needle[tag_at + 1 ..];
    var it = std.mem.splitScalar(u8, srv_log.items, '\n');
    var k: usize = 0;
    var hits: usize = 0;
    while (it.next()) |line| if (std.mem.indexOf(u8, line, tag) != null) {
        defer k += 1;
        if (k >= upto) break;
        if (std.mem.indexOf(u8, line, needle) != null) hits += 1;
    };
    return hits;
}

fn a7sub(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_sub", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [4000]u8 = undefined;
    const n_sub = std.enums.values(A7SubKind).len;
    const n_arms = a7_subs.len * n_sub + std.enums.values(A7DocKind).len;
    for (0..n_arms) |ai| {
        // 탭 번호는 판정자 표(`max_tabs`) 안에서 돌려 쓴다 — 앞 판의 탭은 닫았고, 그 번호의 기록을 지운다.
        const b: u64 = 1 + ai % (max_tabs - 1);
        r.created[b] = false;
        r.loads[b] = 0;
        const doc_arm = ai >= a7_subs.len * n_sub;
        const sub = if (doc_arm) null else a7_subs[ai / n_sub];
        const kind: ?A7SubKind = if (doc_arm) null else std.enums.values(A7SubKind)[ai % n_sub];
        const dkind: ?A7DocKind = if (doc_arm) std.enums.values(A7DocKind)[ai - a7_subs.len * n_sub] else null;
        // `A7_SUB_ARM=<글>` — 이름(`cvh/css`·`doc/state` 꼴)에 그 글을 담은 판만(다시 잴 때).
        var nb: [48]u8 = undefined;
        const arm_name = if (sub) |s| std.fmt.bufPrint(&nb, "{s}/{s}", .{ s.id, @tagName(kind.?) }) catch "" else std.fmt.bufPrint(&nb, "doc/{s}", .{@tagName(dkind.?)}) catch "";
        if (std.c.getenv("A7_SUB_ARM")) |want| if (std.mem.indexOf(u8, arm_name, std.mem.span(want)) == null) continue;
        // 위치로 찾기는 화면 안의 점만 찾는다(화면 밖 점은 「No node found」 — 실측) — 화면 밖 하위 트리는 건너뛴다.
        if (kind != null and kind.? == .node_at and sub.?.top >= 400) continue;
        var tb: [32]u8 = undefined;
        const tag = std.fmt.bufPrint(&tb, "a7s{d}x", .{ai}) catch unreachable;
        var pathb: [64]u8 = undefined;
        r.create(b, uLoop(&u, std.fmt.bufPrint(&pathb, "/a7/sub?{s}", .{tag}) catch unreachable)) catch |e| {
            report(false, "A7-sub", @errorName(e));
            continue;
        };
        r.pump(2800);
        var w: std.Io.Writer = .fixed(&d);
        w.print("{s}: ", .{arm_name}) catch {};
        w.print("after load {d} [", .{seen(tag)}) catch {};
        a7lines(&w, tag, 0);
        w.print("] · ", .{}) catch {};
        // 도메인을 켜야 답하는 것(목록 밖 켬 — 따로 센다).
        const needs_css = kind != null and kind.? == .css;
        const needs_ax = dkind != null and (dkind.? == .ax_root or dkind.? == .ax_child);
        if (needs_css or needs_ax) {
            const e0 = seen(tag);
            if (needs_css) {
                _ = r.call(b, "DOM.enable", "{}", 5000) catch null;
                _ = r.call(b, "CSS.enable", "{}", 5000) catch null;
            } else _ = r.call(b, "Accessibility.enable", "{}", 5000) catch null;
            r.pump(1200);
            w.print("enable(outside the list) +{d} [", .{seen(tag) - e0}) catch {};
            a7lines(&w, tag, e0);
            w.print("] · ", .{}) catch {};
        }
        var pb: [600]u8 = undefined;
        var p_id: i64 = -1;
        var c_id: i64 = -1;
        var lookup_delta: usize = 0;
        if (sub) |s| if (kind.? != .node_at and kind.? != .js) {
            const l0 = seen(tag);
            _ = r.call(b, "DOM.getDocument", "{\"depth\":-1,\"pierce\":true}", 5000) catch null;
            const root_id = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#p{s}\"}}", .{ root_id, s.id }) catch "", 5000) catch null;
            p_id = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#{s}\"}}", .{ root_id, s.id }) catch "", 5000) catch null;
            c_id = grabInt(r.result.items, "\"nodeId\":");
            r.pump(1200);
            lookup_delta = seen(tag) - l0;
            w.print("lookup p {d} container {d} → +{d} · ", .{ p_id, c_id, lookup_delta }) catch {};
        };
        var axb: [64]u8 = undefined;
        var ax_child_id: []const u8 = "";
        if (dkind != null and dkind.? == .ax_child) {
            const l0 = seen(tag);
            _ = r.call(b, "Accessibility.getRootAXNode", "{}", 5000) catch null;
            ax_child_id = grabStr(r.result.items, "\"nodeId\":\"", &axb);
            r.pump(1000);
            lookup_delta = seen(tag) - l0;
            w.print("lookup getRootAXNode '{s}' → +{d} · ", .{ ax_child_id, lookup_delta }) catch {};
        }
        var m: []const u8 = "";
        var p: []const u8 = "";
        var in_list = true;
        var sanity = false;
        if (kind) |k| {
            const s = sub.?;
            switch (k) {
                .quads => {
                    m = "DOM.getContentQuads";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{p_id}) catch "";
                },
                .describe => {
                    m = "DOM.describeNode";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{c_id}) catch "";
                },
                .ax_partial => {
                    m = "Accessibility.getPartialAXTree";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{p_id}) catch "";
                },
                .ax_query => {
                    m = "Accessibility.queryAXTree";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"accessibleName\":\"{s} text\"}}", .{ c_id, s.id }) catch "";
                },
                .css => {
                    // 7 차 고침: 목록 밖(c-v:hidden 하위 트리의 스타일을 강제해 +10 — 실측) — 적기만 한다.
                    m = "CSS.getComputedStyleForNode";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{p_id}) catch "";
                    in_list = false;
                },
                .node_at => {
                    m = "DOM.getNodeForLocation";
                    p = std.fmt.bufPrint(&pb, "{{\"x\":10,\"y\":{d},\"includeUserAgentShadowDOM\":true,\"ignorePointerEventsNone\":true}}", .{if (s.top == 0) 10 else s.top + 10}) catch "";
                },
                .box => {
                    m = "DOM.getBoxModel";
                    p = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{p_id}) catch "";
                    in_list = false;
                },
                .js => {
                    m = "Runtime.evaluate";
                    p = std.fmt.bufPrint(&pb, "{{\"expression\":\"(e=>getComputedStyle(e).width+'/'+e.getBoundingClientRect().height)(document.getElementById('p{s}'))\",\"returnByValue\":true}}", .{s.id}) catch "";
                    in_list = false;
                    sanity = true;
                },
            }
        } else switch (dkind.?) {
            .none => {},
            .ax_full => {
                m = "Accessibility.getFullAXTree";
                p = "{}";
            },
            .layout_metrics => {
                m = "Page.getLayoutMetrics";
                p = "{}";
            },
            .ax_root => {
                m = "Accessibility.getRootAXNode";
                p = "{}";
            },
            .ax_child => {
                m = "Accessibility.getChildAXNodes";
                p = std.fmt.bufPrint(&pb, "{{\"id\":\"{s}\"}}", .{ax_child_id}) catch "";
            },
            .state => {
                m = "Runtime.evaluate";
                p = "{\"expression\":\"JSON.stringify(['cvh','cvhv','cva','huf','det'].map(i=>[i,performance.getEntriesByType('resource').filter(e=>e.name.includes('-'+i+'-')).length,document.getElementById('p'+i).checkVisibility({contentVisibilityAuto:true})]))+innerHeight+'/'+scrollY\",\"returnByValue\":true}";
                in_list = false;
            },
        }
        const c0 = seen(tag);
        var st_name: []const u8 = "-";
        var st: ?msg.DevtoolsStatus = null;
        if (m.len != 0) {
            st = r.call(b, m, p, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
            if (st != null and st.? == .cdp_error) w.print("({s}) ", .{r.result.items[0..@min(r.result.items.len, 80)]}) catch {};
        }
        r.pump(1500);
        const delta = seen(tag) - c0;
        w.print("call {s} {s} → +{d} [", .{ m, st_name, delta }) catch {};
        a7lines(&w, tag, c0);
        w.print("]", .{}) catch {};
        const is_state = dkind != null and dkind.? == .state;
        if (is_state) w.print(" state [id, resources, checkVisibility] {s}", .{r.result.items[0..@min(r.result.items.len, 300)]}) catch {};
        const answered = m.len == 0 or (st != null and st.? == .ok);
        const targets = sub == null or kind.? == .node_at or kind.? == .js or (p_id > 0 and c_id > 0);
        // 건너뛰어야 하는 하위 트리는 불러온 뒤 그 자원이 없어야 한다(그래야 +0 이 뜻을 가진다).
        var needle_b: [48]u8 = undefined;
        const at_load_sub = if (sub) |s| seenBefore(std.fmt.bufPrint(&needle_b, "-{s}-{s}", .{ s.id, tag }) catch "", c0) else 0;
        const live = sub == null or !sub.?.skipped or at_load_sub == 0;
        if (sub) |s| w.print(" · subtree resources before the call {d} (skipped {})", .{ at_load_sub, s.skipped }) catch {};
        // 8 차 NIT(K3): 문서 단위 판(dkind — 하위 트리를 고르지 않는다)도 그 탭의 c-v:hidden 둘(cvh·cvhv)이 호출 전까지 건너뛴 채였는지(자원 0)와,
        // 끝의 페이지 JS 강제(목록 밖)로 둘 다 > 0 인지(갈래가 살아 있다)를 본다 — 둘 다 보이게 바뀌어도 +0 이라 PASS 이던 빈 판을 막는다.
        var doc_live = true;
        if (dkind != null and !is_state) {
            var cv_b: [2][48]u8 = undefined;
            var cv_n: [2][]const u8 = undefined;
            var cv_at: [2]usize = undefined;
            var cv_0: [2]usize = undefined;
            for ([_][]const u8{ "cvh", "cvhv" }, 0..) |cv, ci| {
                cv_n[ci] = std.fmt.bufPrint(&cv_b[ci], "-{s}-{s}", .{ cv, tag }) catch "";
                cv_at[ci] = seenBefore(cv_n[ci], c0);
                cv_0[ci] = seen(cv_n[ci]);
            }
            const f0 = seen(tag);
            const fst = r.call(b, "Runtime.evaluate", "{\"expression\":\"['pcvh','pcvhv'].map(i=>(e=>getComputedStyle(e).width+'/'+e.getBoundingClientRect().height)(document.getElementById(i))).join(' ')\",\"returnByValue\":true}", 5000) catch null;
            r.pump(1500);
            var cv_forced: [2]usize = undefined;
            for (0..2) |ci| cv_forced[ci] = seen(cv_n[ci]) - cv_0[ci];
            doc_live = cv_at[0] == 0 and cv_at[1] == 0 and fst != null and fst.? == .ok and cv_forced[0] > 0 and cv_forced[1] > 0;
            w.print(" · c-v:hidden resources before the call cvh {d} cvhv {d} · then page JS forces both(outside the list) {s} → +{d} (cvh +{d}, cvhv +{d}) [", .{ cv_at[0], cv_at[1], if (fst) |x| @tagName(x) else "timeout", seen(tag) - f0, cv_forced[0], cv_forced[1] }) catch {};
            a7lines(&w, tag, f0);
            w.print("] (want 0 before, each > 0 forced)", .{}) catch {};
        }
        const name = if (is_state) "A7-R1b-skip-state" else if (sanity) "A7-R1b-forced-sanity" else if (!in_list) "A7-R1b-outside-list" else "A7-R1b-read-list-skipped-subtree";
        // 대조(페이지 JS 배치)는 건너뛴 하위 트리에서 > 0(갈래가 살아 있다), 이미 그린 하위 트리·display:none 에서는 적기만.
        const pass = if (is_state) answered else if (sanity) (live and (if (sub.?.skipped) delta > 0 else true)) else if (!in_list) (targets and live) else (targets and live and doc_live and delta == 0 and lookup_delta == 0 and answered);
        report(pass, name, w.buffered());
        r.host.send(.{ .destroy_browser = b }) catch {};
        r.pump(200);
    }
}

/// A7-tok(7 차 고침): 사용자의 새로 고침 토큰이 살아 있는 동안(600 ms beforeunload) 에이전트의 `DOM.getBoxModel`·`CSS.getComputedStyleForNode`
/// (건너뛴 하위 트리를 강제한다 — 읽기 목록 밖)가 토큰을 거두는가 — 거둔다(그 새로 고침은 규칙대로 막힌다). 대조: 호출 없음·같은 노드의
/// `DOM.getContentQuads`(읽기 — maru 의 흐름)는 남긴다(새로 고침은 예외로 지나간다).
fn a7tok(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a7_tok", &.{});
    defer stop(&host);
    var tok_run: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    const r = &tok_run;
    var u: [512]u8 = undefined;
    var d: [1400]u8 = undefined;
    var p1: [128]u8 = undefined;
    const rules = [_]msg.NetBlockRule{.{ .id = 1, .site = "127.0.0.1", .pattern = pat(&p1, "127.0.0.1", "/a6/errbu*") }};
    const Arm = struct { label: []const u8, method: []const u8, enable: []const u8, exempt: bool, tab: u64 };
    for ([_]Arm{
        .{ .label = "control: user reload, no DevTools call", .method = "", .enable = "", .exempt = true, .tab = 1 },
        .{ .label = "DOM.getContentQuads(body) (read list)", .method = "DOM.getContentQuads", .enable = "", .exempt = true, .tab = 2 },
        .{ .label = "DOM.getBoxModel(body)", .method = "DOM.getBoxModel", .enable = "", .exempt = false, .tab = 3 },
        .{ .label = "CSS.getComputedStyleForNode(body)", .method = "CSS.getComputedStyleForNode", .enable = "CSS.enable", .exempt = false, .tab = 4 },
    }) |v| {
        var qb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&qb, "/a6/errbu?a7tok{d}", .{v.tab}) catch unreachable;
        r.create(v.tab, uLoop(&u, path)) catch |e| {
            report(false, "A7-R1-read-list-token", @errorName(e));
            continue;
        };
        r.pump(500);
        r.watch(v.tab) catch {};
        const ok = r.block(v.tab, &rules, "") catch false;
        // 대상(nodeId)·도메인 켬은 새로 고침 전에 — 그 호출들은 사용자의 새로 고침보다 앞이라 토큰과 무관하다.
        var pb: [200]u8 = undefined;
        var params: []const u8 = "";
        if (v.enable.len != 0) {
            _ = r.call(v.tab, "DOM.enable", "{}", 5000) catch null;
            _ = r.call(v.tab, v.enable, "{}", 5000) catch null;
        }
        if (v.method.len != 0) {
            _ = r.call(v.tab, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
            const root_id = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(v.tab, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"body\"}}", .{root_id}) catch "", 5000) catch null;
            const body_id = grabInt(r.result.items, "\"nodeId\":");
            params = std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{body_id}) catch "";
        }
        r.pump(300);
        const c0 = seen(path);
        const e0 = r.errors.items.len;
        r.host.send(.{ .nav_action = .{ .browser = v.tab, .action = .reload, .user = true } }) catch {};
        var st_name: []const u8 = "none";
        var answered = v.method.len == 0;
        if (v.method.len != 0) {
            const st = r.call(v.tab, v.method, params, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
            answered = st != null and st.? == .ok;
        }
        r.pump(2500);
        const e = errOf(r, v.tab, e0);
        const reached = seen(path) - c0;
        // 남기는 대조(읽기)는 호출이 실제로 답해야 한다 — 답하지 않은 호출이 「남겼다」 로 지나가지 않게.
        const pass = ok and if (v.exempt) reached >= 1 and e == null and answered else reached == 0 and e != null;
        report(pass, "A7-R1-read-list-token", std.fmt.bufPrint(&d, "{s}: ruled {} (rule 1 /a6/errbu*) · user reload + call {s} → server +{d} · error page {?d} rule {?d} (want {s})", .{ v.label, ok, st_name, reached, if (e) |q| q.code else null, if (e) |q| q.rule else null, if (v.exempt) "exempt — the token stays" else "blocked — the call takes the token" }) catch "");
        r.host.send(.{ .destroy_browser = v.tab }) catch {};
        r.pump(300);
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// A8: eighth-pass verifier on f36d51e93 (`--review-block-v20h`, `A8_ONLY=tgt,hid`). 7 차 고침 뒤 읽기 목록(28 개)에 남은 메서드를 고친 이가
// 쓰지 않은 강제 계산·로드 갈래로 잰다: 화면 밖 늦은 iframe·그림, c-v:hidden 안의 iframe(바로·늦게), shadow `:host` 스타일, `font-display`,
// `media=print` 스타일시트, `image-set`·`srcset`(x·w), 열린 `<dialog>`·`popover`(상위 레이어)를 c-v:hidden 안에, 닫힌 dialog·popover, `contain:size`,
// 닫힌 `<select>`(기본·base-select)·`<details>`, 숨긴(display:none)·안 보이는(visibility:hidden)·화면 밖 iframe. 그리고 숨은 탭에서 렌더 차례를 돌리는가.
// 자원 이름은 `?X<대상>-<무엇>-TAG` — 탭마다 TAG 가 달라 그 탭의 요청만 센다. 페이지 스크립트는 `/a8/mark?<이름>-TAG`.
// 회귀 판정으로 남긴다(기대값은 8 차 2 판 a8r2 — 199/0): 읽기는 모두 +0, 답의 꼴은 단계마다 맞춘다(오류가 정답인 것 — 늦은 iframe 안쪽 노드, `fromSurface:false`),
// 숨은 탭은 다시 보이면 > 0·kick > 0 을 단언한다. 숨은 탭의 `queryAXTree` 는 렌더 차례를 기다려 5 초 안에 답하지 않는다 — 보이게 하면 ok(문서화된 동작).
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

const a8_head =
    \\<script>window.M=k=>fetch('/a8/mark?'+k+'-TAG');
    \\document.fonts.addEventListener('loading',()=>M('fontloading'));document.fonts.addEventListener('loadingdone',()=>M('fontdone'));document.fonts.addEventListener('loadingerror',()=>M('fonterr'));
    \\new PerformanceObserver(l=>{for(const e of l.getEntries()){const m=/[?]X([a-z]+)-([a-z0-9]+)-/.exec(e.name);if(m)M('perf-'+m[1]+'-'+m[2])}}).observe({type:'resource'});
    \\for(const q of ['(min-resolution: 1.5dppx)','(min-resolution: 2.5dppx)','(max-width: 300px)','(min-width: 1000px)','print','(orientation: portrait)'])matchMedia(q).addEventListener('change',()=>M('mq-'+q.replace(/[^a-z0-9.]/g,'')));
    \\addEventListener('resize',()=>M('resize'));visualViewport.addEventListener('resize',()=>M('vvresize'));visualViewport.addEventListener('scroll',()=>M('vvscroll'));
    \\addEventListener('beforeprint',()=>M('beforeprint'));addEventListener('afterprint',()=>M('afterprint'));
    \\</script>
;

/// 페이지 t — 상위 레이어가 아닌 대상.
const a8_page_t = "<!doctype html><title>a8t</title><link rel=stylesheet media=print href='/a8/css?Xprt-css-TAG'><style>" ++
    \\@font-face{font-family:Fshd;src:url(/a8/font?Xshd-font-TAG)}
    \\@font-face{font-family:Ffdb;src:url(/a8/font?Xfdp-fblock-TAG);font-display:block}
    \\@font-face{font-family:Ffdo;src:url(/a8/font?Xfdp-foptional-TAG);font-display:optional}
    \\@font-face{font-family:Ffds;src:url(/a8/font?Xfdp-fswap-TAG);font-display:swap}
    \\@font-face{font-family:Fsel;src:url(/a8/font?Xsel-font-TAG)}@font-face{font-family:Fbsel;src:url(/a8/font?Xbsel-font-TAG)}@font-face{font-family:Fdet;src:url(/a8/font?Xdet-font-TAG)}
    \\@media print{#top{background-image:url(/a8/res?Xprt-inl-TAG)}}
    \\.bx{position:absolute;left:0;width:200px;height:40px}.cvh{content-visibility:hidden;contain-intrinsic-size:200px 40px}.g{display:inline-block;width:8px;height:8px}
    \\select.bs{appearance:base-select}select.bs::picker(select){appearance:base-select}
    \\</style>
++ a8_head ++
    \\<script>class XA8 extends HTMLElement{constructor(){super();const r=this.attachShadow({mode:'open'});r.innerHTML="<style>:host{display:block;width:8px;height:8px;background-image:url(/a8/res?Xshd-host-TAG)}p{font-family:Fshd}</style><p id=sp>shd shadow</p>"}};customElements.define('x-a8',XA8);</script>
    \\<div id=top style='height:8000px'>top</div>
    \\<iframe id=ifl class=bx style='top:5000px' loading=lazy src='/a8/doc?Xifl-doc-TAG'></iframe>
    \\<img id=iml class=bx style='top:5200px' loading=lazy src='/a8/res?Ximl-img-TAG' onload="M('load-iml')">
    \\<div id=cvw class='bx cvh' style='top:100px'><iframe id=cvif src='/a8/doc?Xcvi-doc-TAG' width=50 height=20></iframe><iframe id=cvlf loading=lazy src='/a8/doc?Xcvl-doc-TAG' width=50 height=20></iframe><p id=pcvi>cvi text</p></div>
    \\<div id=shd class='bx cvh' style='top:160px'><x-a8 id=shh></x-a8><p id=pshd>shd text</p></div>
    \\<div id=fdp class='bx cvh' style='top:220px'><p id=pfdp><span style='font-family:Ffdb'>b</span><span style='font-family:Ffdo'>o</span><span style='font-family:Ffds'>s</span> fdp text</p></div>
    \\<div id=ims class=bx style='top:280px;height:8px;background-image:image-set(url(/a8/res?Xims-x1-TAG) 1x,url(/a8/res?Xims-x2-TAG) 2x,url(/a8/res?Xims-x3-TAG) 3x)'></div>
    \\<img id=srs style='position:absolute;top:300px;left:0' width=8 height=8 srcset='/a8/res?Xsrs-x1-TAG 1x, /a8/res?Xsrs-x2-TAG 2x, /a8/res?Xsrs-x3-TAG 3x'>
    \\<img id=wsr style='position:absolute;top:310px;left:0' width=8 height=8 sizes='(max-width:300px) 10px, (min-width:1000px) 1000px, 100px' srcset='/a8/res?Xwsr-w10-TAG 10w, /a8/res?Xwsr-w100-TAG 100w, /a8/res?Xwsr-w1000-TAG 1000w'>
    \\<select id=sel style='position:absolute;top:330px;left:0'><option>s1</option><option id=so2 style='font-family:Fsel;background-image:url(/a8/res?Xsel-obg-TAG)'>sel text</option></select>
    \\<select id=bsel class=bs style='position:absolute;top:330px;left:300px'><button><selectedcontent></selectedcontent></button><option>b1</option><option id=bo2><span class=g style='background-image:url(/a8/res?Xbsel-bg-TAG)'></span><span style='font-family:Fbsel'>bsel text</span></option></select>
    \\<details id=det class=bx style='top:360px'><summary>det sum</summary><p id=pdet style='font-family:Fdet'>det text</p><span class=g style='background-image:url(/a8/res?Xdet-bg-TAG)'></span></details>
    \\<iframe id=hif style='display:none' src='/a8/doc?Xhif-doc-TAG'></iframe>
    \\<iframe id=vif class=bx style='top:250px;left:300px;visibility:hidden' src='/a8/doc?Xvif-doc-TAG'></iframe>
    \\<iframe id=oif class=bx style='top:6000px' src='/a8/doc?Xoif-doc-TAG'></iframe>
    \\<script>setTimeout(()=>window.ready=1,400)</script>
;

/// 페이지 u — 상위 레이어(c-v:hidden 안의 열린 popover·modal dialog)와 닫힌 dialog·popover, `contain:size`.
const a8_page_u = "<!doctype html><title>a8u</title><style>" ++
    \\@font-face{font-family:Fpop;src:url(/a8/font?Xpop-font-TAG)}@font-face{font-family:Fdlg;src:url(/a8/font?Xdlg-font-TAG)}
    \\@font-face{font-family:Fdlgc;src:url(/a8/font?Xdlgc-font-TAG)}@font-face{font-family:Fpopc;src:url(/a8/font?Xpopc-font-TAG)}@font-face{font-family:Fcsz;src:url(/a8/font?Xcsz-font-TAG)}
    \\.bx{position:absolute;left:0;width:200px;height:40px}.cvh{content-visibility:hidden;contain-intrinsic-size:200px 40px}.g{display:inline-block;width:8px;height:8px}
    \\</style>
++ a8_head ++
    \\<div id=top style='height:8000px'>top</div>
    \\<div id=popw class='bx cvh' style='top:100px'><div id=pop popover=manual><p id=ppop style='font-family:Fpop'>pop text</p><span class=g style='background-image:url(/a8/res?Xpop-bg-TAG)'></span></div></div>
    \\<div id=dlgw class='bx cvh' style='top:160px'><dialog id=dlg><p id=pdlg style='font-family:Fdlg'>dlg text</p><span class=g style='background-image:url(/a8/res?Xdlg-bg-TAG)'></span></dialog></div>
    \\<dialog id=dlgc><p id=pdlgc style='font-family:Fdlgc'>dlgc text</p><span class=g style='background-image:url(/a8/res?Xdlgc-bg-TAG)'></span></dialog>
    \\<div id=popc popover><p id=ppopc style='font-family:Fpopc'>popc text</p><span class=g style='background-image:url(/a8/res?Xpopc-bg-TAG)'></span></div>
    \\<div id=csz class=bx style='top:6000px;contain:size;height:0;overflow:hidden'><p id=pcsz style='font-family:Fcsz'>csz text</p><span class=g style='background-image:url(/a8/res?Xcsz-bg-TAG)'></span></div>
    \\<script>try{document.getElementById('pop').showPopover()}catch(e){M('poperr')}try{document.getElementById('dlg').showModal()}catch(e){M('dlgerr')}setTimeout(()=>window.ready=1,400)</script>
;

/// iframe 의 문서(`/a8/doc?X<대상>-doc-TAG`): 제 글꼴·배경 그림·rAF — 그 프레임의 스타일·배치·렌더 차례가 돌 때만 요청·marks 를 낸다.
fn a8serve(conn: c_int, path: []const u8, target: []const u8) void {
    const q = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "none";
    if (std.mem.eql(u8, path, "/a8/t") or std.mem.eql(u8, path, "/a8/u")) {
        const body = std.mem.replaceOwned(u8, std.heap.c_allocator, if (std.mem.eql(u8, path, "/a8/t")) a8_page_t else a8_page_u, "TAG", q) catch return;
        defer std.heap.c_allocator.free(body);
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a8/doc")) {
        // q = X<id>-doc-<tag>
        const dash = std.mem.indexOfScalar(u8, q, '-') orelse return;
        const id = if (q.len > 1 and dash > 1) q[1..dash] else "x";
        const tag = if (std.mem.indexOf(u8, q, "-doc-")) |i| q[i + 5 ..] else "none";
        var bb: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>a8doc</title><style>@font-face{{font-family:IF;src:url(/a8/font?X{s}-ifont-{s})}}.b{{width:8px;height:8px;background-image:url(/a8/res?X{s}-ibg-{s})}}</style>" ++
            "<script>const P=k=>{{try{{parent.M(k)}}catch(e){{fetch('/a8/mark?'+k+'-{s}')}}}};new PerformanceObserver(l=>{{for(const e of l.getEntries())P('iperf-{s}')}}).observe({{type:'resource'}});" ++
            "document.fonts.addEventListener('loadingerror',()=>P('ifonterr-{s}'));requestAnimationFrame(()=>P('iraf-{s}'));</script><p id=ip style='font-family:IF'>{s} in</p><div class=b></div>", .{ id, tag, id, tag, tag, id, id, id, id }) catch return;
        return reply(conn, "200 OK", html, "", body);
    }
    if (std.mem.eql(u8, path, "/a8/css")) {
        const tag = if (std.mem.indexOf(u8, q, "-css-")) |i| q[i + 5 ..] else "none";
        var bb: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&bb, "#top{{background-image:url(/a8/res?Xprt-bg-{s})}}@font-face{{font-family:Fprt;src:url(/a8/font?Xprt-font-{s})}}body{{font-family:Fprt}}", .{ tag, tag }) catch return;
        return reply(conn, "200 OK", "text/css", "", body);
    }
    if (std.mem.eql(u8, path, "/a8/res")) return reply(conn, "200 OK", "image/svg+xml", "", "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>");
    if (std.mem.eql(u8, path, "/a8/font")) return reply(conn, "404 Not Found", "text/plain", "", "nofont");
    return reply(conn, "204 No Content", "text/plain", "", "");
}

const A8Tgt = struct { id: []const u8, page: u8, p: []const u8, c: []const u8, fr: []const u8 = "", top: u32 = 0 };
const a8_tgts = [_]A8Tgt{
    .{ .id = "ifl", .page = 't', .p = "", .c = "#ifl", .fr = "ifl" },
    .{ .id = "iml", .page = 't', .p = "#iml", .c = "#iml" },
    .{ .id = "cvi", .page = 't', .p = "", .c = "#cvw", .fr = "cvif", .top = 100 },
    .{ .id = "cvl", .page = 't', .p = "", .c = "#cvw", .fr = "cvlf", .top = 100 },
    .{ .id = "shd", .page = 't', .p = "#pshd", .c = "#shd", .top = 160 },
    .{ .id = "fdp", .page = 't', .p = "#pfdp", .c = "#fdp", .top = 220 },
    .{ .id = "prt", .page = 't', .p = "#top", .c = "body" },
    .{ .id = "ims", .page = 't', .p = "#ims", .c = "#ims", .top = 280 },
    .{ .id = "srs", .page = 't', .p = "#srs", .c = "#srs", .top = 300 },
    .{ .id = "wsr", .page = 't', .p = "#wsr", .c = "#wsr", .top = 310 },
    .{ .id = "sel", .page = 't', .p = "#so2", .c = "#sel", .top = 330 },
    .{ .id = "bsel", .page = 't', .p = "#bo2", .c = "#bsel" },
    .{ .id = "det", .page = 't', .p = "#pdet", .c = "#det", .top = 360 },
    .{ .id = "hif", .page = 't', .p = "", .c = "#hif", .fr = "hif" },
    .{ .id = "vif", .page = 't', .p = "", .c = "#vif", .fr = "vif" },
    .{ .id = "oif", .page = 't', .p = "", .c = "#oif", .fr = "oif" },
    .{ .id = "pop", .page = 'u', .p = "#ppop", .c = "#popw", .top = 100 },
    .{ .id = "dlg", .page = 'u', .p = "#pdlg", .c = "#dlgw", .top = 160 },
    .{ .id = "dlgc", .page = 'u', .p = "#pdlgc", .c = "#dlgc" },
    .{ .id = "popc", .page = 'u', .p = "#ppopc", .c = "#popc" },
    .{ .id = "csz", .page = 'u', .p = "#pcsz", .c = "#csz" },
};

fn a8want(name: []const u8) bool {
    const v = std.c.getenv("A8_ONLY") orelse return true;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

/// 10 차 검증(v20i)의 오래 걸리거나 시간에 민감한 탐침은 `A8_ONLY` 에 이름이 있을 때만 돈다(`zrecrash` — 되살리는 중 보이는 대로 kill -9,
/// `zearly` — 5 판 × 둘, `zrace` — 10 판, `zcrashurl` — chrome://crash 가 죽이지 못하면 관찰만). 회귀에 쓰는 갈래는 `a8want` 로 기본 실행에 든다.
fn zwant(name: []const u8) bool {
    const v = std.c.getenv("A8_ONLY") orelse return false;
    return std.mem.indexOf(u8, std.mem.span(v), name) != null;
}

pub fn runA8(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try startServer();
    try startServer2();
    if (a8want("tgt")) a8tgt(report, host_path, root) catch |err| report(false, "A8-tgt", @errorName(err));
    if (a8want("hid")) a8hid(report, host_path, root) catch |err| report(false, "A8-hid", @errorName(err));
    // 9 차: 렌더러가 죽은 동안 보낸 바꾸기(엄격·규칙·기록).
    if (a8want("dstrict")) a9strict(report, host_path, root) catch |err| report(false, "A9-dstrict", @errorName(err));
    if (a8want("drule")) a9rule(report, host_path, root) catch |err| report(false, "A9-drule", @errorName(err));
    if (a8want("drec")) a9rec(report, host_path, root) catch |err| report(false, "A9-drec", @errorName(err));
    // 10 차(v20i 적대 검증의 탐침 — 고친 뒤 기준): 기본 실행에 드는 갈래(`a8want` — `A8_ONLY` 가 없거나 그 이름이 있을 때). 바쁜 렌더러 경주(MED-1·
    // 9 차의 살아남은 변이 둘), kill -9, 탭마다 짝 자리(LOW-1), 엄격과 나눈 기록, 다시 맞추기가 켠 기록을 두는가, 204 로 되살림, 렌더러를 나눈 팝업.
    if (a8want("zbrecoff")) zbRecOff(report, host_path, root) catch |err| report(false, "Z-brecoff", @errorName(err));
    if (a8want("zbstrict")) zbStrict(report, host_path, root) catch |err| report(false, "Z-bstrict", @errorName(err));
    if (a8want("zbrecon")) zbRecOn(report, host_path, root) catch |err| report(false, "Z-brecon", @errorName(err));
    if (a8want("zkill")) zKill(report, host_path, root) catch |err| report(false, "Z-kill", @errorName(err));
    if (a8want("zslots")) zSlots(report, host_path, root) catch |err| report(false, "Z-slots", @errorName(err));
    if (a8want("z204")) z204(report, host_path, root) catch |err| report(false, "Z-204", @errorName(err));
    if (a8want("zpopup")) zPopup(report, host_path, root) catch |err| report(false, "Z-popup", @errorName(err));
    if (a8want("zsrec")) zStrictRec(report, host_path, root) catch |err| report(false, "Z-srec", @errorName(err));
    if (a8want("zkeeprec")) zKeepRec(report, host_path, root) catch |err| report(false, "Z-keeprec", @errorName(err));
    // 이름이 있을 때만(`zwant` — 오래 걸리거나 시간에 민감하다).
    if (zwant("zcrashurl")) zCrashUrl(report, host_path, root) catch |err| report(false, "Z-crashurl", @errorName(err));
    if (zwant("zrecrash")) zRecrash(report, host_path, root) catch |err| report(false, "Z-recrash", @errorName(err));
    if (zwant("zearly")) zEarly(report, host_path, root) catch |err| report(false, "Z-early", @errorName(err));
    if (zwant("zrace")) zRace(report, host_path, root) catch |err| report(false, "Z-race", @errorName(err));
    // 11 차(v20j — 10 차 고침의 적대 검증의 탐침): 기본 실행에 드는 갈래. `zjnofail`·`zjsuper` 는 10 차가 「판정으로 가르지 못한다」 고 적은 변이
    // 셋(죽음에 표시하지 않음·죽음 답을 셈에 넣음·먼저 온 명령이 자리를 쥠)을 maru 가 받는 상태 프레임으로 가른다. 기록과 섞기·렌더러를 나눈 팝업·
    // 닫은 탭의 번호를 다시 씀·죽음 아닌 렌더러 바꾸기는 끈 기록의 본문과 엄격 상태를 단언한다.
    if (a8want("zjnofail")) zjNoFail(report, host_path, root) catch |err| report(false, "ZJ-nofail", @errorName(err));
    if (a8want("zjsuper")) zjSuper(report, host_path, root) catch |err| report(false, "ZJ-super", @errorName(err));
    if (a8want("zjrec")) zjRec(report, host_path, root) catch |err| report(false, "ZJ-rec", @errorName(err));
    if (a8want("zjpop")) zjPop(report, host_path, root) catch |err| report(false, "ZJ-pop", @errorName(err));
    if (a8want("zjclose")) zjClose(report, host_path, root) catch |err| report(false, "ZJ-close", @errorName(err));
    if (a8want("zjxnav")) zjXnav(report, host_path, root) catch |err| report(false, "ZJ-xnav", @errorName(err));
    // 관찰만(늘 PASS — 판정 밖에서 로그 줄을 센다)이라 이름이 있을 때만.
    if (zwant("zjnav")) zjNav(report, host_path, root) catch |err| report(false, "ZJ-nav", @errorName(err));
}

/// 그 탭(TAG)의 서버 줄 가운데 `X<id>-` 를 담은 것의 수.
fn a8hits(id: []const u8, tag: []const u8) usize {
    var nb: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "X{s}-", .{id}) catch return 0;
    _ = std.c.pthread_mutex_lock(&srv_lock);
    defer _ = std.c.pthread_mutex_unlock(&srv_lock);
    var it = std.mem.splitScalar(u8, srv_log.items, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, tag) != null and std.mem.indexOf(u8, line, needle) != null) n += 1;
    }
    return n;
}

const A8Frame = struct { node: i64 = -1, doc: i64 = -1, frame_buf: [64]u8 = undefined, frame_len: usize = 0 };

fn a8walk(v: std.json.Value, want: []const u8, out: *A8Frame) bool {
    if (v != .object) return false;
    const o = v.object;
    if (o.get("attributes")) |attrs| {
        if (attrs == .array) {
            const a = attrs.array.items;
            var i: usize = 0;
            while (i + 1 < a.len) : (i += 2) {
                if (a[i] == .string and a[i + 1] == .string and std.mem.eql(u8, a[i].string, "id") and std.mem.eql(u8, a[i + 1].string, want)) {
                    if (o.get("nodeId")) |n| {
                        if (n == .integer) out.node = n.integer;
                    }
                    if (o.get("frameId")) |f| {
                        if (f == .string) {
                            const k = @min(f.string.len, out.frame_buf.len);
                            @memcpy(out.frame_buf[0..k], f.string[0..k]);
                            out.frame_len = k;
                        }
                    }
                    if (o.get("contentDocument")) |cd| {
                        if (cd == .object) {
                            if (cd.object.get("nodeId")) |n| {
                                if (n == .integer) out.doc = n.integer;
                            }
                        }
                    }
                    return true;
                }
            }
        }
    }
    for ([_][]const u8{ "children", "shadowRoots" }) |k| {
        if (o.get(k)) |ch| {
            if (ch == .array) {
                for (ch.array.items) |c| if (a8walk(c, want, out)) return true;
            }
        }
    }
    if (o.get("contentDocument")) |cd| if (a8walk(cd, want, out)) return true;
    return false;
}

const A8M = enum { idle, quads, describe, outer, ax_partial, ax_query, node_at, ax_frame, quads_frame, ax_full, resource_tree, layout_metrics, frame_tree, nav_history, shot_kick, shot_scale3, shot_surface, cookies, js };

fn a8node(m: A8M) bool {
    return switch (m) {
        .quads, .describe, .outer, .ax_partial, .ax_query, .node_at, .ax_frame, .quads_frame => true,
        else => false,
    };
}

const A8Ids = struct { p: i64 = -1, c: i64 = -1, fr: A8Frame = .{} };

/// A8-tgt: 페이지(t·u)마다, 메서드마다 새 탭. 불러온 뒤 3 초 쉬고 1 초 더 쉬어 +0 인지(대조) 본 뒤, 찾기(getDocument{depth:-1,pierce}·querySelector)의
/// 수를 대상마다 적고, 메서드를 대상마다(노드 메서드) 또는 한 번(문서 메서드) 부르며 1 초 동안 그 TAG 의 새 줄을 대상마다 센다. 읽기 목록의 메서드는
/// +0 이어야 한다. `js` 는 목록 밖 대조(페이지 JS 의 getComputedStyle·getBoundingClientRect — 건너뛴 하위 트리를 강제한다).
fn a8tgt(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a8_tgt", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [6000]u8 = undefined;
    var tab_i: usize = 0;
    const only_m = std.c.getenv("A8_M");
    for ([_]u8{ 't', 'u' }) |page| {
        for (std.enums.values(A8M)) |m| {
            if (only_m) |om| if (std.mem.indexOf(u8, std.mem.span(om), @tagName(m)) == null) continue;
            if ((m == .ax_frame or m == .quads_frame) and page == 'u') continue;
            tab_i += 1;
            const b: u64 = 1 + tab_i % (max_tabs - 1);
            r.created[b] = false;
            r.loads[b] = 0;
            var tb: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tb, "a8{c}{d}z", .{ page, tab_i }) catch unreachable;
            var pathb: [64]u8 = undefined;
            r.create(b, uLoop(&u, std.fmt.bufPrint(&pathb, "/a8/{c}?{s}", .{ page, tag }) catch unreachable)) catch |e| {
                report(false, "A8-tgt", @errorName(e));
                continue;
            };
            r.pump(3000);
            var w: std.Io.Writer = .fixed(&d);
            w.print("page {c} method {s} tag {s} · at load: ", .{ page, @tagName(m), tag }) catch {};
            for (a8_tgts) |t| if (t.page == page) w.print("{s} {d} ", .{ t.id, a8hits(t.id, tag) }) catch {};
            w.print("[", .{}) catch {};
            a7lines(&w, tag, 0);
            const idle0 = seen(tag);
            r.pump(1000);
            const idle = seen(tag) - idle0;
            w.print("] · idle 1 s +{d} · ", .{idle}) catch {};
            // 찾기 — getDocument{depth:-1,pierce:true}(읽기 목록) 와 querySelector. 그 수를 대상마다 적는다.
            var ids: [a8_tgts.len]A8Ids = @splat(.{});
            const before = blk: {
                var arr: [a8_tgts.len]usize = @splat(0);
                for (a8_tgts, 0..) |t, ti| arr[ti] = a8hits(t.id, tag);
                break :blk arr;
            };
            const l0 = seen(tag);
            var root_id: i64 = -1;
            if (m != .idle and m != .js) {
                _ = r.call(b, "DOM.getDocument", "{\"depth\":-1,\"pierce\":true}", 5000) catch null;
                root_id = grabInt(r.result.items, "\"nodeId\":");
                if (std.json.parseFromSlice(std.json.Value, r.gpa, r.result.items, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) if (parsed.value.object.get("root")) |rv| {
                        for (a8_tgts, 0..) |t, ti| if (t.page == page and t.fr.len != 0) {
                            _ = a8walk(rv, t.fr, &ids[ti].fr);
                        };
                    };
                } else |_| {}
                var pb: [300]u8 = undefined;
                for (a8_tgts, 0..) |t, ti| if (t.page == page) {
                    if (t.p.len != 0) {
                        _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"{s}\"}}", .{ root_id, t.p }) catch "", 5000) catch null;
                        ids[ti].p = grabInt(r.result.items, "\"nodeId\":");
                    } else if (ids[ti].fr.doc > 0) {
                        _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#ip\"}}", .{ids[ti].fr.doc}) catch "", 5000) catch null;
                        ids[ti].p = grabInt(r.result.items, "\"nodeId\":");
                    }
                    _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"{s}\"}}", .{ root_id, t.c }) catch "", 5000) catch null;
                    ids[ti].c = grabInt(r.result.items, "\"nodeId\":");
                };
                r.pump(1000);
            }
            const lookup = seen(tag) - l0;
            w.print("lookup +{d} (", .{lookup}) catch {};
            for (a8_tgts, 0..) |t, ti| if (t.page == page) {
                const dl = a8hits(t.id, tag) - before[ti];
                w.print("{s} p{d} c{d} fr{d}/{d}/{s} +{d}; ", .{ t.id, ids[ti].p, ids[ti].c, ids[ti].fr.node, ids[ti].fr.doc, ids[ti].fr.frame_buf[0..ids[ti].fr.frame_len], dl }) catch {};
            };
            w.print(") [", .{}) catch {};
            a7lines(&w, tag, l0);
            w.print("] · ", .{}) catch {};
            report(idle == 0 and lookup == 0 and (m == .idle or m == .js or root_id > 0), "A8-lookup-getDocument-pierce", w.buffered());
            // 메서드
            var pb: [600]u8 = undefined;
            if (a8node(m)) {
                for (a8_tgts, 0..) |t, ti| {
                    if (t.page != page) continue;
                    const id = ids[ti];
                    const meth: []const u8, const params: []const u8 = switch (m) {
                        .quads => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{id.p}) catch "" },
                        .describe => .{ "DOM.describeNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{id.c}) catch "" },
                        .outer => .{ "DOM.getOuterHTML", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{id.c}) catch "" },
                        .ax_partial => .{ "Accessibility.getPartialAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{id.p}) catch "" },
                        .ax_query => .{ "Accessibility.queryAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"accessibleName\":\"{s} {s}\"}}", .{ if (t.fr.len != 0 and id.fr.doc > 0) id.fr.doc else id.c, t.id, if (t.fr.len != 0) "in" else "text" }) catch "" },
                        .node_at => .{ "DOM.getNodeForLocation", std.fmt.bufPrint(&pb, "{{\"x\":{d},\"y\":{d},\"includeUserAgentShadowDOM\":true,\"ignorePointerEventsNone\":true}}", .{ if (t.id.len == 4 and std.mem.eql(u8, t.id, "bsel")) @as(u32, 310) else 10, t.top + 5 }) catch "" },
                        .ax_frame => .{ "Accessibility.getFullAXTree", std.fmt.bufPrint(&pb, "{{\"frameId\":\"{s}\"}}", .{id.fr.frame_buf[0..id.fr.frame_len]}) catch "" },
                        .quads_frame => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{id.fr.node}) catch "" },
                        else => unreachable,
                    };
                    if (m == .node_at and t.top == 0) continue;
                    if ((m == .ax_frame or m == .quads_frame) and t.fr.len == 0) continue;
                    var dd: [2400]u8 = undefined;
                    var w2: std.Io.Writer = .fixed(&dd);
                    const h0 = a8hits(t.id, tag);
                    const c0 = seen(tag);
                    const st = r.call(b, meth, params, 5000) catch null;
                    r.pump(1000);
                    const delta = seen(tag) - c0;
                    const own = a8hits(t.id, tag) - h0;
                    w2.print("page {c} {s} on {s} ({s}) → {s}", .{ page, meth, t.id, params, if (st) |x| @tagName(x) else "timeout" }) catch {};
                    if (st != null and st.? == .cdp_error) w2.print(" ({s})", .{r.result.items[0..@min(r.result.items.len, 90)]}) catch {};
                    if (m == .ax_frame and st != null and st.? == .ok) w2.print(" has '{s} in' {}", .{ t.id, std.mem.indexOf(u8, r.result.items, " in\"") != null }) catch {};
                    w2.print(" · +{d} (own {d}) [", .{ delta, own }) catch {};
                    a7lines(&w2, tag, c0);
                    // 답의 꼴(8 차 2 판 기준): 늦은 iframe(ifl·cvl)의 문서는 getDocument{pierce} 가 불러오지 않아 안쪽 노드(`#ip`)가 없다 — 그 노드를 부르는
                    // 판(quads·ax_partial)은 오류가 정답이고, 나머지는 모두 ok 여야 한다(대상을 못 찾아 오류인데 +0 이라 PASS 하는 빈 판을 막는다).
                    const lazy_inner = (std.mem.eql(u8, t.id, "ifl") or std.mem.eql(u8, t.id, "cvl")) and (m == .quads or m == .ax_partial);
                    const as_expected = st != null and st.? == (if (lazy_inner) msg.DevtoolsStatus.cdp_error else msg.DevtoolsStatus.ok);
                    w2.print("] · at load {d} · idle {d} · answer as expected {} (want {s})", .{ before[ti], idle, as_expected, if (lazy_inner) "cdp_error — the lazy iframe's document is not loaded" else "ok" }) catch {};
                    report(idle == 0 and delta == 0 and as_expected, "A8-R1-read-list-forced-load", w2.buffered());
                }
            } else if (m != .idle) {
                const meth: []const u8, const params: []const u8 = switch (m) {
                    .ax_full => .{ "Accessibility.getFullAXTree", "{}" },
                    .resource_tree => .{ "Page.getResourceTree", "{}" },
                    .layout_metrics => .{ "Page.getLayoutMetrics", "{}" },
                    .frame_tree => .{ "Page.getFrameTree", "{}" },
                    .nav_history => .{ "Page.getNavigationHistory", "{}" },
                    .shot_kick => .{ "Page.captureScreenshot", msg.devtools_kick_params },
                    .shot_scale3 => .{ "Page.captureScreenshot", "{\"format\":\"png\",\"clip\":{\"x\":0,\"y\":250,\"width\":400,\"height\":100,\"scale\":3}}" },
                    .shot_surface => .{ "Page.captureScreenshot", "{\"format\":\"png\",\"fromSurface\":false}" },
                    .cookies => .{ "Network.getCookies", "{}" },
                    .js => .{ "Runtime.evaluate", "{\"expression\":\"(()=>{const o=[];for(const s of ['#pcvi','#pshd','#sp','#pfdp','#so2','#bo2','#pdet','#ppop','#pdlg','#pdlgc','#ppopc','#pcsz']){const e=document.querySelector(s)||(document.querySelector('#shh')&&document.querySelector('#shh').shadowRoot.querySelector(s));if(e)o.push(s+':'+getComputedStyle(e).fontFamily+'/'+e.getBoundingClientRect().height)}for(const f of ['cvif','cvlf','hif','vif','oif','ifl']){const x=document.getElementById(f);if(x&&x.contentDocument&&x.contentDocument.getElementById('ip'))o.push(f+':'+x.contentDocument.getElementById('ip').getBoundingClientRect().height)}return o.join(' ')+' dpr '+devicePixelRatio})()\",\"returnByValue\":true}" },
                    else => unreachable,
                };
                var per: [a8_tgts.len]usize = @splat(0);
                for (a8_tgts, 0..) |t, ti| per[ti] = a8hits(t.id, tag);
                const c0 = seen(tag);
                const st = r.call(b, meth, params, 8000) catch null;
                r.pump(1500);
                const delta = seen(tag) - c0;
                var w2: std.Io.Writer = .fixed(&d);
                w2.print("page {c} {s} {s} → {s}", .{ page, meth, params[0..@min(params.len, 90)], if (st) |x| @tagName(x) else "timeout" }) catch {};
                if (st != null and st.? == .cdp_error) w2.print(" ({s})", .{r.result.items[0..@min(r.result.items.len, 90)]}) catch {};
                if (m == .js and st != null) w2.print(" value {s}", .{r.result.items[0..@min(r.result.items.len, 700)]}) catch {};
                if (m == .ax_full and st != null and st.? == .ok) {
                    w2.print(" · AX texts present:", .{}) catch {};
                    for ([_][]const u8{ "cvi text", "shd text", "shd shadow", "fdp text", "sel text", "bsel text", "det text", "pop text", "dlg text", "dlgc text", "popc text", "csz text", "det sum" }) |s|
                        w2.print(" '{s}' {}", .{ s, std.mem.indexOf(u8, r.result.items, s) != null }) catch {};
                }
                w2.print(" · +{d} per target:", .{delta}) catch {};
                for (a8_tgts, 0..) |t, ti| if (t.page == page) {
                    const dl = a8hits(t.id, tag) - per[ti];
                    if (dl != 0) w2.print(" {s} +{d}", .{ t.id, dl }) catch {};
                };
                w2.print(" [", .{}) catch {};
                a7lines(&w2, tag, c0);
                w2.print("] · idle {d}", .{idle}) catch {};
                // 1 차 판(a8r1)의 실측: `fromSurface:false` 는 CEF 154 가 오류로 답한다(5 차 문서와 같다 — 오류가 정답), 페이지 u 에는 페이지 JS 로도
                // 강제할 것이 없다(c-v:hidden 안의 열린 popover·modal dialog 는 높이 0·요청 0 — 갈래가 없다; 적기만).
                const want_err = m == .shot_surface;
                const answered_as_expected = st != null and (if (want_err) st.? == .cdp_error else st.? == .ok);
                const name = if (m == .js) (if (page == 'u') "A8-R1-forced-sanity-u-recorded" else "A8-R1-forced-sanity") else "A8-R1-read-list-forced-load";
                report(idle == 0 and (if (m == .js) (page == 'u' or delta > 0) else delta == 0) and answered_as_expected, name, w2.buffered());
            }
            r.host.send(.{ .destroy_browser = b }) catch {};
            r.pump(200);
        }
    }
}

const A8HidKind = enum { none, shot_kick, resource_tree, layout_metrics, node_at, quads_z, describe_body, outer_html, ax_query, ax_partial_z, ax_full, frame_tree, nav_history, get_doc, cookies };

/// A8-hid: 숨은 탭에서 읽기 목록의 다른 메서드(7 차 판정이 재지 않은 것 — 자원 트리·위치로 찾기·내용 사각형·설명·outerHTML·AX 질의·부분 AX·
/// 프레임 트리·기록·쿠키)가 렌더 차례(rAF·ResizeObserver·IntersectionObserver)를 돌리는가. 대조: 부른 뒤 보이게 하면 미뤄 둔 콜백이 돌아야 한다
/// (갈래가 살아 있다 — 7 차 판정에는 이 대조가 없다), kick 은 +3(문서화된 틈 — 양의 대조).
fn a8hid(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a8_hid", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [2400]u8 = undefined;
    for (std.enums.values(A8HidKind), 0..) |kind, ki| {
        const b: u64 = 20 + ki;
        var tb: [32]u8 = undefined;
        const tag = std.fmt.bufPrint(&tb, "a8h{d}x", .{ki}) catch unreachable;
        var pathb: [64]u8 = undefined;
        r.create(b, uLoop(&u, std.fmt.bufPrint(&pathb, "/a7/hid?{s}", .{tag}) catch unreachable)) catch |e| {
            report(false, "A8-hid", @errorName(e));
            continue;
        };
        r.pump(800);
        try r.host.send(.{ .set_hidden = .{ .browser = b, .value = true } });
        r.pump(1000);
        var w: std.Io.Writer = .fixed(&d);
        var vb: [32]u8 = undefined;
        const a0 = seen(tag);
        const vis = r.ev(b, "arm()", &vb);
        r.pump(1500);
        const armed = seen(tag) - a0;
        w.print("{s}: hidden, arm() → {s} · 1.5 s idle → +{d} · ", .{ @tagName(kind), vis, armed }) catch {};
        var pb: [300]u8 = undefined;
        var z: i64 = -1;
        var body: i64 = -1;
        var root_id: i64 = -1;
        const l0 = seen(tag);
        if (kind == .quads_z or kind == .describe_body or kind == .outer_html or kind == .ax_query or kind == .ax_partial_z) {
            _ = r.call(b, "DOM.getDocument", "{\"depth\":1}", 5000) catch null;
            root_id = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"#z\"}}", .{root_id}) catch "", 5000) catch null;
            z = grabInt(r.result.items, "\"nodeId\":");
            _ = r.call(b, "DOM.querySelector", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"selector\":\"body\"}}", .{root_id}) catch "", 5000) catch null;
            body = grabInt(r.result.items, "\"nodeId\":");
            r.pump(800);
        }
        const lookup = seen(tag) - l0;
        const m: []const u8, const p: []const u8 = switch (kind) {
            .none => .{ "", "" },
            .shot_kick => .{ "Page.captureScreenshot", msg.devtools_kick_params },
            .resource_tree => .{ "Page.getResourceTree", "{}" },
            .layout_metrics => .{ "Page.getLayoutMetrics", "{}" },
            .node_at => .{ "DOM.getNodeForLocation", "{\"x\":2,\"y\":30,\"includeUserAgentShadowDOM\":true}" },
            .quads_z => .{ "DOM.getContentQuads", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d}}}", .{z}) catch "" },
            .describe_body => .{ "DOM.describeNode", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"depth\":-1,\"pierce\":true}}", .{body}) catch "" },
            .outer_html => .{ "DOM.getOuterHTML", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"includeShadowDOM\":true}}", .{root_id}) catch "" },
            .ax_query => .{ "Accessibility.queryAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"accessibleName\":\"hid\"}}", .{root_id}) catch "" },
            .ax_partial_z => .{ "Accessibility.getPartialAXTree", std.fmt.bufPrint(&pb, "{{\"nodeId\":{d},\"fetchRelatives\":true}}", .{z}) catch "" },
            .ax_full => .{ "Accessibility.getFullAXTree", "{}" },
            .frame_tree => .{ "Page.getFrameTree", "{}" },
            .nav_history => .{ "Page.getNavigationHistory", "{}" },
            .get_doc => .{ "DOM.getDocument", "{\"depth\":-1,\"pierce\":true}" },
            .cookies => .{ "Network.getCookies", "{}" },
        };
        const c0 = seen(tag);
        var st_name: []const u8 = "-";
        var late: []const u8 = "";
        if (m.len != 0) {
            const st = r.call(b, m, p, 5000) catch null;
            st_name = if (st) |x| @tagName(x) else "timeout";
            if (st != null and st.? == .cdp_error) w.print("({s}) ", .{r.result.items[0..@min(r.result.items.len, 80)]}) catch {};
            if (st == null) late = "pending";
        }
        r.pump(1500);
        const delta = seen(tag) - c0;
        w.print("lookup +{d} · call {s} {s} → +{d} [", .{ lookup, m, st_name, delta }) catch {};
        a7lines(&w, tag, c0);
        // 1 차 판(a8r1): 숨은 탭의 queryAXTree 는 5 초 안에 답하지 않았다 — 보이게 한 뒤 그 호출의 답이 오는가(멈춤인가, 렌더 차례를 기다리는가).
        if (late.len != 0) {
            const id = r.next_call;
            try r.host.send(.{ .set_hidden = .{ .browser = b, .value = false } });
            const dl = os.nowMs() + 5000;
            while (os.nowMs() < dl) {
                const mm = (r.host.next(50) catch null) orelse continue;
                switch (mm) {
                    .devtools_result => |v| if (v.call == id) {
                        late = @tagName(v.status);
                        break;
                    },
                    else => {},
                }
                r.take(mm);
            }
            w.print("] · after showing, the pending call answered: {s} [", .{late}) catch {};
            try r.host.send(.{ .set_hidden = .{ .browser = b, .value = true } });
            r.pump(300);
        }
        // 양의 대조: 보이게 하면 미뤄 둔 rAF·감시자가 돈다(갈래가 살아 있다).
        try r.host.send(.{ .set_hidden = .{ .browser = b, .value = false } });
        const v0 = seen(tag);
        r.pump(1500);
        const shown = seen(tag) - v0;
        w.print("] · shown again → +{d} [", .{shown}) catch {};
        a7lines(&w, tag, v0);
        w.print("]", .{}) catch {};
        const answered = m.len == 0 or std.mem.eql(u8, st_name, "ok") or (kind == .ax_query and std.mem.eql(u8, late, "ok"));
        const live = std.mem.eql(u8, vis, "hidden") and armed == 0 and answered and lookup == 0;
        const gap = kind == .shot_kick;
        if (gap) {
            report(live and delta > 0, "A8-hid-positive-control-kick", w.buffered());
        } else {
            // 보이게 한 뒤 +0 이면 갈래가 죽었거나(빈 판) 호출이 이미 콜백을 돌렸다 — 어느 쪽이든 FAIL 로 드러낸다.
            report(live and delta == 0 and shown > 0, "A8-hid-read-runs-frame", w.buffered());
        }
        r.host.send(.{ .destroy_browser = b }) catch {};
        r.pump(200);
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// 9 차(W9e② 계획 실측이 찾은 W9d③ 결함 — `--review-block-v20h`, `A8_ONLY=dstrict,drule,drec`): 렌더러가 죽은 동안 보낸 Network 도메인 바꾸기.
// 렌더러가 죽은 동안 보낸 CDP 는 새 렌더러에 닿지 않는다 — 새 렌더러는 죽기 전의 렌더러 쪽 상태(우회·도메인 켜짐)를 되받는다(W9e② 실측 a3_dead3).
// 그래서 엄격 끔이 사라지면 「끈 줄 알았는데 그 탭의 서비스 워커가 계속 우회된다」. 하위 자원 fetch 가 서비스 워커를 지나는가(서버 줄의 `sw=`)로
// 렌더러 쪽 우회를, `navigator.serviceWorker.controller` 로 이동(브라우저 쪽) 우회를 함께 본다.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

/// 하위 자원 fetch 가 서비스 워커를 지났는가 — `sw` 지남·`net` 네트워크로 바로(우회)·`fail …` 그 밖.
fn a9sub(r: *Run, b: u64, path: []const u8) []const u8 {
    var x: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    const got = r.ev(b, fetchExpr(&x, path), &o);
    if (!starts(got, "ok 200")) return "fail";
    var lb: [600]u8 = undefined;
    const line = lastSeen(path, &lb);
    return if (std.mem.indexOf(u8, line, "sw=") != null) "sw" else "net";
}

/// 렌더러를 죽인다(`Page.crash`) — 답은 `detached`(곧) 또는 없다.
fn a9crash(r: *Run, b: u64) []const u8 {
    const st = r.call(b, "Page.crash", "{}", 3000) catch null;
    r.pump(800);
    return if (st) |x| @tagName(x) else "timeout";
}

/// 죽은 렌더러를 이동으로 되살리고 그 문서의 이동·하위 자원 우회를 잰다. `tag` 는 주소를 가른다.
/// `early` — 되살린 문서가 파싱 중에 부른 하위 자원(`/s/epage`)이 서비스 워커를 지났는가(다시 보낸 값이 문서보다 먼저 닿았는가).
const A9Seen = struct { early: []const u8, ctl: []const u8, sub: []const u8, ctl2: []const u8, sub2: []const u8 };

fn a9revive(r: *Run, b: u64, tag: []const u8) A9Seen {
    var u: [512]u8 = undefined;
    var pb: [64]u8 = undefined;
    r.nav(b, uLoop(&u, std.fmt.bufPrint(&pb, "/s/epage?{s}", .{tag}) catch "/s/epage"), false) catch {};
    r.pump(800);
    var eb: [64]u8 = undefined;
    const early_path = std.fmt.bufPrint(&eb, "/s/{s}-early", .{tag}) catch "/s/x";
    var lb: [600]u8 = undefined;
    const early_line = lastSeen(early_path, &lb);
    const early: []const u8 = if (early_line.len == 0) "none" else if (std.mem.indexOf(u8, early_line, "sw=") != null) "sw" else "net";
    const ctl = ctlOf(r, b);
    var sb: [64]u8 = undefined;
    const sub = a9sub(r, b, std.fmt.bufPrint(&sb, "/s/{s}-a", .{tag}) catch "/s/x");
    // 한 번 더 불러와도(살아 있는 렌더러의 새 문서) 같은가.
    const ctl2 = reloadCtl(r, b);
    var sb2: [64]u8 = undefined;
    const sub2 = a9sub(r, b, std.fmt.bufPrint(&sb2, "/s/{s}-b", .{tag}) catch "/s/x");
    return .{ .early = early, .ctl = ctl, .sub = sub, .ctl2 = ctl2, .sub2 = sub2 };
}

/// 되살린 문서의 파싱 중 하위 자원(`early`)까지 본다 — 다시 보낸 값은 새 렌더러가 붙기를 기다렸다가 문서보다 먼저 닿는다(실측 — 9 차).
fn a9bypassed(s: A9Seen) bool {
    return std.mem.eql(u8, s.early, "net") and std.mem.eql(u8, s.ctl, "bypassed") and std.mem.eql(u8, s.sub, "net") and std.mem.eql(u8, s.ctl2, "bypassed") and std.mem.eql(u8, s.sub2, "net");
}

fn a9controlled(s: A9Seen) bool {
    return std.mem.eql(u8, s.early, "sw") and std.mem.eql(u8, s.ctl, "controlled") and std.mem.eql(u8, s.sub, "sw") and std.mem.eql(u8, s.ctl2, "controlled") and std.mem.eql(u8, s.sub2, "sw");
}

/// 9 차: 렌더러가 죽은 동안의 엄격 켬·끔 — 되살린 뒤 마지막 바람이 이동·하위 자원 모두에 듣는가, 켬의 답(상태)이 오는가.
fn a9strict(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a9_strict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 21;
    try r.create(b, uLoop(&u, "/s/page?D9"));
    const c0 = swReady(&r, b);
    const s0 = a9sub(&r, b, "/s/d9-base");
    try r.watch(b);
    // 대조: 살아 있을 때 켬은 둘 다 우회한다.
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    const c1 = reloadCtl(&r, b);
    const s1 = a9sub(&r, b, "/s/d9-on");
    const alive_on = std.mem.eql(u8, c0, "controlled") and std.mem.eql(u8, s0, "sw") and st1 and r.strict[b] == .on and std.mem.eql(u8, c1, "bypassed") and std.mem.eql(u8, s1, "net");
    // ① 켠 채 죽임 → 죽은 동안 끔 → 되살림: 서비스 워커가 다시 다스려야 한다.
    {
        const cr = a9crash(&r, b);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        const state = r.strict[b];
        const v = a9revive(&r, b, "d9off");
        const pass = alive_on and st and state == .off and a9controlled(v);
        report(pass, "A9-dead-strict-off", std.fmt.bufPrint(&d, "alive: start {s}/{s} · on {}/{s} reload {s} sub {s} · Page.crash {s} · off while dead: answered {} state {s} · revive: early {s} · nav {s} sub {s} · reload {s} sub {s} (want early sw, controlled/sw both)", .{ c0, s0, st1, @tagName(r.strict[b]), c1, s1, cr, st, @tagName(state), v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    // ② 끈 채 죽임 → 죽은 동안 켬 → 되살림: 우회해야 하고 켬의 상태 답이 와야 한다.
    {
        const cr = a9crash(&r, b);
        const g = try sendBlock(&r, b, "127.0.0.1");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        const state = r.strict[b];
        const v = a9revive(&r, b, "d9on");
        // 되살린 뒤에야 답할 수 있으면 그때라도 와야 한다.
        const st_late = r.until(Run.strictSettled, b, g, wait_ms);
        const pass = st_late and r.strict[b] == .on and a9bypassed(v);
        report(pass, "A9-dead-strict-on", std.fmt.bufPrint(&d, "Page.crash {s} · on while dead: settled {} state {s} · revive: early {s} · nav {s} sub {s} · reload {s} sub {s} · settled after revive {} state {s} (want early net, bypassed/net both, on)", .{ cr, st, @tagName(state), v.early, v.ctl, v.sub, v.ctl2, v.sub2, st_late, @tagName(r.strict[b]) }) catch "");
    }
    // ③ 켠 채 죽임 → 죽은 동안 끔→켬→끔 → 되살림: 마지막(끔)만 — 꺼진 것을 다시 켜지 않는다.
    {
        const cr = a9crash(&r, b);
        _ = try sendBlock(&r, b, "");
        _ = try sendBlock(&r, b, "127.0.0.1");
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        const v = a9revive(&r, b, "d9last");
        r.pump(300);
        const pass = st and r.strict[b] == .off and r.state_gen[b] == g and a9controlled(v);
        report(pass, "A9-dead-strict-last-off", std.fmt.bufPrint(&d, "Page.crash {s} · off→on→off while dead: answered {} state {s} gen {d}/{d} · revive: early {s} · nav {s} sub {s} · reload {s} sub {s} (want early sw, controlled/sw both, off, last gen)", .{ cr, st, @tagName(r.strict[b]), r.state_gen[b], g, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    // ④ 끈 채 죽임 → 죽은 동안 켬→끔→켬 → 되살림: 마지막(켬).
    {
        const cr = a9crash(&r, b);
        _ = try sendBlock(&r, b, "127.0.0.1");
        _ = try sendBlock(&r, b, "");
        const g = try sendBlock(&r, b, "127.0.0.1");
        const v = a9revive(&r, b, "d9laston");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        const pass = st and r.strict[b] == .on and a9bypassed(v);
        report(pass, "A9-dead-strict-last-on", std.fmt.bufPrint(&d, "Page.crash {s} · on→off→on while dead · revive: early {s} · nav {s} sub {s} · reload {s} sub {s} · settled {} state {s} (want early net, bypassed/net both, on)", .{ cr, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]) }) catch "");
    }
    // ⑤ 대조: 살아 있을 때 끔은 그대로 듣는다(되살림 경로가 살아 있는 탭의 끔을 바꾸지 않는다).
    {
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        const c = reloadCtl(&r, b);
        const s = a9sub(&r, b, "/s/d9-alive-off");
        report(st and r.strict[b] == .off and std.mem.eql(u8, c, "controlled") and std.mem.eql(u8, s, "sw"), "A9-alive-strict-off", std.fmt.bufPrint(&d, "off while alive: answered {} state {s} · reload {s} sub {s} (want controlled/sw)", .{ st, @tagName(r.strict[b]), c, s }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// 9 차 대조: 막기 규칙은 sidecar 의 표다(CDP 가 아니다) — 렌더러가 죽은 동안 지운 규칙은 되살린 뒤 막지 않는다.
fn a9rule(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a9_rule", &.{});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1200]u8 = undefined;
    var x: [512]u8 = undefined;
    var o: [600]u8 = undefined;
    var pb: [256]u8 = undefined;
    const b: u64 = 22;
    try r.create(b, uLoop(&u, "/a9/top"));
    try r.watch(b);
    const ok1 = try r.block(b, &.{.{ .id = 91, .site = "127.0.0.1", .pattern = pat(&pb, "127.0.0.1", "/a9/blk*") }}, "");
    const f1 = r.ev(b, fetchExpr(&x, "/a9/blk-1"), &o);
    const blocked1 = starts(f1, "reject");
    const cr = a9crash(&r, b);
    const ok2 = try r.block(b, &.{}, "");
    r.nav(b, uLoop(&u, "/a9/top?2"), false) catch {};
    r.pump(500);
    const s0 = seen("/a9/blk-2");
    var o2: [600]u8 = undefined;
    const f2 = r.ev(b, fetchExpr(&x, "/a9/blk-2"), &o2);
    const pass = ok1 and blocked1 and ok2 and starts(f2, "ok 200") and seen("/a9/blk-2") == s0 + 1;
    report(pass, "A9-dead-rule-clear", std.fmt.bufPrint(&d, "rule 91 on: fetch {s} · Page.crash {s} · clear while dead: answered {} · revive: fetch {s} server +{d} (want reject, then ok +1)", .{ f1[0..@min(f1.len, 20)], cr, ok2, f2[0..@min(f2.len, 20)], seen("/a9/blk-2") - s0 }) catch "");
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// 9 차: 렌더러가 죽은 동안의 기록 끔 — 되살린 뒤 그 탭의 Network 도메인이 꺼졌는가(켜진 채면 렌더러가 본문을 계속 받아 두고 에이전트가 DevTools
/// `Network.getResponseBody` 로 그것을 읽는다 — 끈 기록이 남는다). 대조: 살아 있을 때 끔은 읽지 못한다, 켠 동안은 읽는다.
fn a9rec(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "a9_rec", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 23;
    try r.create(b, uLoop(&u, "/a9/top?r0"));
    try r.watch(b);
    const Body = struct {
        fn read(rr: *Run, bb: u64, uu: []u8, tag: []const u8) []const u8 {
            var pb: [64]u8 = undefined;
            rr.nav(bb, uLoop(uu, std.fmt.bufPrint(&pb, "/a9/top?{s}", .{tag}) catch "/a9/top"), false) catch {};
            rr.pump(600);
            _ = rr.call(bb, "Page.getFrameTree", "{}", 5000) catch null;
            var lb: [80]u8 = undefined;
            const loader = grabStr(rr.result.items, "\"loaderId\":\"", &lb);
            if (loader.len == 0) return "no-loader";
            var qb: [160]u8 = undefined;
            const res = rr.call(bb, "Network.getResponseBody", std.fmt.bufPrint(&qb, "{{\"requestId\":\"{s}\"}}", .{loader}) catch "", 5000) catch null;
            if (res == null) return "timeout";
            if (res.? != .ok) return "error";
            return if (std.mem.indexOf(u8, rr.result.items, "a9top") != null) "body" else "other";
        }
    };
    const recOn = struct {
        fn f(rr: *Run, bb: u64, session: u32) bool {
            rr.host.send(.{ .net_record = .{ .browser = bb, .on = true, .session = session } }) catch return false;
            const dl = os.nowMs() + 5000;
            while (os.nowMs() < dl and rr.record_state[bb] != .on) rr.pump(50);
            return rr.record_state[bb] == .on;
        }
    }.f;
    // 대조 ①: 기록 중에는 읽는다, 살아 있을 때 끄면 읽지 못한다.
    const on1 = recOn(&r, b, 31);
    const b1 = Body.read(&r, b, &u, "r1");
    try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
    r.pump(500);
    const b2 = Body.read(&r, b, &u, "r2");
    const control = on1 and std.mem.eql(u8, b1, "body") and !std.mem.eql(u8, b2, "body");
    // ② 기록 중 죽임 → 죽은 동안 끔 → 되살림: 읽지 못해야 한다.
    const on3 = recOn(&r, b, 32);
    const cr = a9crash(&r, b);
    try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
    r.pump(500);
    const st = @tagName(r.record_state[b]);
    const b3 = Body.read(&r, b, &u, "r3");
    const b4 = Body.read(&r, b, &u, "r4");
    const pass = control and on3 and !std.mem.eql(u8, b3, "body") and !std.mem.eql(u8, b4, "body");
    report(pass, "A9-dead-record-off", std.fmt.bufPrint(&d, "alive: record {} → getResponseBody {s} · off → {s} · record {} · Page.crash {s} · off while dead: state {s} · revive → {s} · next page → {s} (want body, not body; not body twice)", .{ on1, b1, b2, on3, cr, st, b3, b4 }) catch "");
    // ③ 끈 채 죽임 → 죽은 동안 켬 → 되살림: 켬은 새 렌더러가 붙을 때 실패로 답한다 — maru 에 `failed` 가 보이고(말없이 사라지지 않는다), 반쯤
    // 켜진 도메인이 남지 않는다(본문을 읽지 못한다). 되살린 뒤 다시 켜면 켜진다(대조). 죽은 동안의 켬을 미뤄 두었다 다시 보내는 것은 W9d② 의 몫이라
    // 하지 않았다(계획 「W9d③ 9 차」 남는 틈).
    {
        const cr2 = a9crash(&r, b);
        try r.host.send(.{ .net_record = .{ .browser = b, .on = true, .session = 33 } });
        r.pump(800);
        const st_dead = @tagName(r.record_state[b]);
        const b5 = Body.read(&r, b, &u, "r5");
        r.pump(300);
        const st_after = r.record_state[b];
        const b6 = Body.read(&r, b, &u, "r6");
        const on7 = recOn(&r, b, 34);
        const b7 = Body.read(&r, b, &u, "r7");
        const pass2 = st_after == .failed and !std.mem.eql(u8, b5, "body") and !std.mem.eql(u8, b6, "body") and on7 and std.mem.eql(u8, b7, "body");
        report(pass2, "A9-dead-record-on", std.fmt.bufPrint(&d, "Page.crash {s} · on while dead: state {s} · revive → {s} · state {s} · next page → {s} · on again {} → {s} (want failed, not body twice, then on and body)", .{ cr2, st_dead, b5, @tagName(st_after), b6, on7, b7 }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(300);
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// v20i — W9d③ 9 차 고침의 적대 검증(10 차) 탐침을 고친 뒤 기준의 회귀로(`--review-block-v20h`). 9 차 고침은 「렌더러가 죽은 동안 보낸 명령」 과
// 「답을 기다리던 명령」 을 표시해 그 첫 답에 다시 맞춘다. 이 탐침들은 그 경계를 민다: 렌더러가 바빠 명령을 처리하지 못한 채 죽는 경주(9 차의 살아남은
// 변이 둘·10 차 MED-1), kill -9·chrome://crash, 되살리는 중 또 죽음, 한 탭이 짝 자리를 다 쓰는가(10 차 LOW-1), 되살린 문서의 머리 하위 자원(10 차
// LOW-2 — 남는 틈), 204 로 되살림, 같은 렌더러를 나눈 팝업. 기본 실행·`A8_ONLY` 만의 나눔은 `runA8`.
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

/// 이 host 의 렌더러를 모두 kill -9 한다(판정자가 띄운 host 의 자식만) — 죽인 수.
fn zKillRenderers(host: *Host) u32 {
    var kids: [64]c_int = undefined;
    var n: u32 = 0;
    for (os.children(host.pid, &kids)) |kid| if (os.argsContain(kid, "--type=renderer")) {
        _ = std.c.kill(kid, std.c.SIG.KILL);
        n += 1;
    };
    return n;
}

fn zRendererCount(host: *Host) u32 {
    var kids: [64]c_int = undefined;
    var n: u32 = 0;
    for (os.children(host.pid, &kids)) |kid| if (os.argsContain(kid, "--type=renderer")) {
        n += 1;
    };
    return n;
}

/// 주 프레임을 `ms` 동안 바쁘게 한다(setTimeout 안의 돌기 — 그동안 렌더러는 Network 명령을 처리하지 못한다: 답을 기다리는 채 죽일 수 있다).
fn zBusy(r: *Run, b: u64, ms: u32) []const u8 {
    var x: [200]u8 = undefined;
    var o: [64]u8 = undefined;
    const e = std.fmt.bufPrint(&x, "setTimeout(()=>{{const t=Date.now();while(Date.now()-t<{d}){{}}}},0);'busy'", .{ms}) catch unreachable;
    const got = r.ev(b, e, &o);
    r.pump(300);
    return if (std.mem.eql(u8, got, "busy")) "busy" else "notbusy";
}

/// `/a9/top?tag` 로 이동해 그 문서의 본문을 에이전트의 DevTools(`Network.getResponseBody`, 문서의 loaderId)로 읽는다 — `body` 면 렌더러가 본문을
/// 받아 두었다(Network 도메인이 기록의 버퍼로 켜져 있다).
fn zBody(r: *Run, b: u64, tag: []const u8) []const u8 {
    var u: [512]u8 = undefined;
    var pb: [64]u8 = undefined;
    r.nav(b, uLoop(&u, std.fmt.bufPrint(&pb, "/a9/top?{s}", .{tag}) catch "/a9/top"), false) catch {};
    r.pump(600);
    _ = r.call(b, "Page.getFrameTree", "{}", 5000) catch null;
    var lb: [80]u8 = undefined;
    const loader = grabStr(r.result.items, "\"loaderId\":\"", &lb);
    if (loader.len == 0) return "no-loader";
    var qb: [160]u8 = undefined;
    const res = r.call(b, "Network.getResponseBody", std.fmt.bufPrint(&qb, "{{\"requestId\":\"{s}\"}}", .{loader}) catch "", 5000) catch null;
    if (res == null) return "timeout";
    if (res.? != .ok) return "error";
    return if (std.mem.indexOf(u8, r.result.items, "a9top") != null) "body" else "other";
}

fn zIsBody(s: []const u8) bool {
    return std.mem.eql(u8, s, "body");
}

fn zRecOn(r: *Run, b: u64, session: u32) bool {
    r.host.send(.{ .net_record = .{ .browser = b, .on = true, .session = session } }) catch return false;
    const dl = os.nowMs() + 5000;
    while (os.nowMs() < dl and r.record_state[b] != .on) r.pump(50);
    return r.record_state[b] == .on;
}

/// Z1(10 차 MED-1): 기록을 켠 탭의 주 프레임이 바쁜 동안 기록을 끈다(엄격 없음 — `disable` 하나; 고치기 전에는 답을 짝짓지 않았다) → 렌더러가
/// 죽는다 → 되살림. 죽기 전에 보낸 `disable` 은 렌더러가 처리하지 못했고(바쁨) 새 렌더러는 죽기 전 상태(기록의 버퍼로 켠 도메인)를 되받는다(고치기
/// 전 4/4 body). 기대: 되살린 뒤 본문을 읽지 못한다 — 짝지은 `disable` 이 죽음에 표시되고 그 답에 다시 맞춘다.
/// 두 판 — kill -9(바쁜 채 확실히 죽인다)와 Page.crash(바쁜 렌더러에도 듣는가).
fn zbRecOff(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_brecoff", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 26;
    try r.create(b, uLoop(&u, "/a9/top?z1"));
    try r.watch(b);
    // 셋째 판은 대조 — 바쁘지 않은 채 끄고(답을 받음) Page.crash.
    for ([_]u8{ 0, 1, 2 }, 0..) |mode, i| {
        const use_kill = mode == 0;
        var tb: [3][16]u8 = undefined;
        _ = &tb;
        const ta = std.fmt.bufPrint(&tb[0], "z1a{d}", .{i}) catch "z1a";
        const tbb = std.fmt.bufPrint(&tb[1], "z1b{d}", .{i}) catch "z1b";
        const tc = std.fmt.bufPrint(&tb[2], "z1c{d}", .{i}) catch "z1c";
        const on = zRecOn(&r, b, 41 + @as(u32, @intCast(i)));
        const b0 = zBody(&r, b, ta);
        const busy = if (mode == 2) "idle" else zBusy(&r, b, 6000);
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(400);
        const st_off = @tagName(r.record_state[b]);
        const t0 = os.nowMs();
        var killed: u32 = 0;
        var cr: []const u8 = "-";
        if (use_kill) killed = zKillRenderers(&host) else cr = a9crash(&r, b);
        const dt = os.nowMs() - t0;
        r.pump(800);
        const b1 = zBody(&r, b, tbb);
        const b2 = zBody(&r, b, tc);
        const pass = on and zIsBody(b0) and !zIsBody(b1) and !zIsBody(b2);
        report(pass, if (mode == 0) "Z-busy-record-off-kill" else if (mode == 1) "Z-busy-record-off-pagecrash" else "Z-idle-record-off-pagecrash(control)", std.fmt.bufPrint(&d, "record {} → {s} · {s} · off while busy: state {s} · {s} killed {d} Page.crash {s} in {d} ms · revive → {s} · next page → {s} (want body, then not body twice)", .{ on, b0, busy, st_off, if (use_kill) "kill -9" else "Page.crash", killed, cr, dt, b1, b2 }) catch "");
        // 다음 판을 위해 깨끗이 — 살아 있는 끔.
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(300);
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z2: 엄격의 바쁜 렌더러 경주(살아남은 변이 ② 「답을 기다리던 명령을 죽음에 표시하지 않음」 을 만든다) — 엄격 켬 → 바쁨 → 끔(`bypass_off` 는 답을
/// 짝짓는다, 렌더러가 처리 못 함) → kill -9 → 되살림. 그리고 거꾸로(끈 채 바쁨 → 켬 → kill → 되살림).
fn zbStrict(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_bstrict", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 27;
    try r.create(b, uLoop(&u, "/s/page?Z2"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    const c1 = reloadCtl(&r, b);
    const s1 = a9sub(&r, b, "/s/z2-on");
    {
        const busy = zBusy(&r, b, 6000);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, 3000);
        r.pump(300);
        const killed = zKillRenderers(&host);
        r.pump(800);
        const v = a9revive(&r, b, "z2off");
        const pass = std.mem.eql(u8, c0, "controlled") and st1 and std.mem.eql(u8, c1, "bypassed") and std.mem.eql(u8, s1, "net") and killed >= 1 and st and a9controlled(v);
        report(pass, "Z-busy-strict-off-kill", std.fmt.bufPrint(&d, "start {s} · on {} reload {s} sub {s} · {s} → off answered {} · killed {d} · revive: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw everywhere)", .{ c0, st1, c1, s1, busy, st, killed, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    {
        const busy = zBusy(&r, b, 6000);
        const g = try sendBlock(&r, b, "127.0.0.1");
        r.pump(400);
        const killed = zKillRenderers(&host);
        r.pump(800);
        const v = a9revive(&r, b, "z2on");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        const pass = killed >= 1 and st and r.strict[b] == .on and a9bypassed(v);
        report(pass, "Z-busy-strict-on-kill", std.fmt.bufPrint(&d, "{s} → on · killed {d} · revive: early {s} nav {s} sub {s} reload {s} sub {s} · settled {} state {s} (want bypassed/net everywhere, on)", .{ busy, killed, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]) }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z3: 살아남은 변이 ① 「기록 켬 실패를 명령 없이 내림」 을 가르는 꼴 — 기록 켬(s1) → 바쁨 → 끔(`disable` — 짝 없음) → 켬(s2 — net_body 의
/// `Network.enable`) → kill -9 → 되살림. s2 의 켬은 실패로 답한다; 그때 명령 없이 내리면 새 렌더러는 s1 의 버퍼로 켠 도메인을 그대로 쥔다.
/// 기대: 되살린 뒤 본문을 읽지 못한다(s2 는 `failed`).
fn zbRecOn(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_brecon", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 28;
    try r.create(b, uLoop(&u, "/a9/top?z3"));
    try r.watch(b);
    const on = zRecOn(&r, b, 51);
    const b0 = zBody(&r, b, "z3a");
    const busy = zBusy(&r, b, 6000);
    try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
    r.pump(100);
    try r.host.send(.{ .net_record = .{ .browser = b, .on = true, .session = 52 } });
    r.pump(300);
    const killed = zKillRenderers(&host);
    r.pump(800);
    const b1 = zBody(&r, b, "z3b");
    const st = @tagName(r.record_state[b]);
    const b2 = zBody(&r, b, "z3c");
    const pass = on and zIsBody(b0) and killed >= 1 and !zIsBody(b1) and !zIsBody(b2);
    report(pass, "Z-busy-record-offon-kill", std.fmt.bufPrint(&d, "record {} → {s} · {s} → off, on(s2) · killed {d} · revive → {s} · state {s} · next page → {s} (want body, then not body twice)", .{ on, b0, busy, killed, b1, st, b2 }) catch "");
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z4: Page.crash 대신 kill -9(바쁘지 않음) — 엄격 끔·켬·기록 끔이 A9 와 같이 맞는가.
fn zKill(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_kill", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 29;
    try r.create(b, uLoop(&u, "/s/page?Z4"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    {
        const killed = zKillRenderers(&host);
        r.pump(800);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        const v = a9revive(&r, b, "z4off");
        report(std.mem.eql(u8, c0, "controlled") and st1 and killed >= 1 and st and a9controlled(v), "Z-kill-strict-off", std.fmt.bufPrint(&d, "start {s} on {} · killed {d} · off while dead answered {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw)", .{ c0, st1, killed, st, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    {
        const killed = zKillRenderers(&host);
        r.pump(800);
        const g = try sendBlock(&r, b, "127.0.0.1");
        const v = a9revive(&r, b, "z4on");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        report(killed >= 1 and st and r.strict[b] == .on and a9bypassed(v), "Z-kill-strict-on", std.fmt.bufPrint(&d, "killed {d} · on while dead · revive: early {s} nav {s} sub {s} reload {s} sub {s} · settled {} {s} (want bypassed/net, on)", .{ killed, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]) }) catch "");
    }
    {
        const g = try sendBlock(&r, b, "");
        _ = r.until(Run.stateAt, b, g, wait_ms);
        const on = zRecOn(&r, b, 71);
        const b0 = zBody(&r, b, "z4a");
        const killed = zKillRenderers(&host);
        r.pump(800);
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(500);
        const b1 = zBody(&r, b, "z4b");
        const b2 = zBody(&r, b, "z4c");
        report(on and zIsBody(b0) and killed >= 1 and !zIsBody(b1) and !zIsBody(b2), "Z-kill-record-off", std.fmt.bufPrint(&d, "record {} → {s} · killed {d} · off while dead · revive → {s} · next → {s} (want body, then not body twice)", .{ on, b0, killed, b1, b2 }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z5: chrome://crash 로 렌더러를 죽인다(이동) — 그 길이 열려 있으면 끔이 맞는가. 열려 있지 않으면 관찰로 적는다.
fn zCrashUrl(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_crashurl", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 30;
    try r.create(b, uLoop(&u, "/s/page?Z5"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    const n0 = zRendererCount(&host);
    try r.host.send(.{ .navigate = .{ .browser = b, .url = "chrome://crash", .user = true } });
    r.pump(2000);
    const n1 = zRendererCount(&host);
    const probe = r.call(b, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", 3000) catch null;
    const probe_s: []const u8 = if (probe) |x| @tagName(x) else "timeout";
    const died = probe == null or probe.? != .ok;
    const g = try sendBlock(&r, b, "");
    const st = r.until(Run.stateAt, b, g, wait_ms);
    const v = a9revive(&r, b, "z5off");
    if (died) {
        report(std.mem.eql(u8, c0, "controlled") and st1 and st and a9controlled(v), "Z-crashurl-strict-off", std.fmt.bufPrint(&d, "start {s} on {} · chrome://crash renderers {d}→{d} probe {s} · off answered {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw)", .{ c0, st1, n0, n1, probe_s, st, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    } else {
        report(true, "Z-crashurl(obs)", std.fmt.bufPrint(&d, "chrome://crash did not kill the renderer (renderers {d}→{d} probe {s}) · off answered {} · revive: nav {s} sub {s}", .{ n0, n1, probe_s, st, v.ctl, v.sub }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// 되살리는 이동을 보내고 `dur_ms` 동안 이 host 의 렌더러를 보이는 대로 kill -9 한다(예비 렌더러가 그 이동에 쓰일 수 있어 가리지 않는다 — 되살리는
/// 중 또 죽음, 여러 번일 수 있다) — 죽인 수, 마지막으로 죽인 때(ms).
fn zNavAndKill(r: *Run, host: *Host, b: u64, path: []const u8, dur_ms: i64, ms_out: *i64) u32 {
    var u: [512]u8 = undefined;
    const t0 = os.nowMs();
    r.host.send(.{ .navigate = .{ .browser = b, .url = uLoop(&u, path), .user = false } }) catch return 0;
    var killed: u32 = 0;
    while (os.nowMs() < t0 + dur_ms) {
        const m = (r.host.next(1) catch null);
        if (m) |mm| r.take(mm);
        const k = zKillRenderers(host);
        if (k > 0) {
            killed += k;
            ms_out.* = os.nowMs() - t0;
        }
    }
    r.pump(1200);
    return killed;
}

/// Z6: 연속 죽음 — 죽음 → 끔(죽은 동안) → 되살리는 이동 → 새 렌더러를 곧 죽임 → 다시 되살림. 켬도 같은 꼴.
fn zRecrash(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_recrash", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 31;
    try r.create(b, uLoop(&u, "/s/page?Z6"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    const durs = [_]i64{ 60, 200, 500 };
    var round: u32 = 0;
    while (round < 3) : (round += 1) {
        {
            const cr = a9crash(&r, b);
            const g = try sendBlock(&r, b, "");
            const st = r.until(Run.stateAt, b, g, wait_ms);
            var ms: i64 = 0;
            var pb: [32]u8 = undefined;
            const k = zNavAndKill(&r, &host, b, std.fmt.bufPrint(&pb, "/s/epage?z6x{d}", .{round}) catch "/s/epage", durs[round], &ms);
            var tb: [16]u8 = undefined;
            const v = a9revive(&r, b, std.fmt.bufPrint(&tb, "z6off{d}", .{round}) catch "z6off");
            var nb: [48]u8 = undefined;
            report(std.mem.eql(u8, c0, "controlled") and st1 and st and k >= 1 and a9controlled(v), std.fmt.bufPrint(&nb, "Z-recrash-strict-off-{d}", .{round}) catch "Z-recrash-strict-off", std.fmt.bufPrint(&d, "Page.crash {s} · off while dead answered {} · revive nav + kills {d} (last at {d} ms) · revive again: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw)", .{ cr, st, k, ms, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
        }
        {
            const cr = a9crash(&r, b);
            const g = try sendBlock(&r, b, "127.0.0.1");
            var ms: i64 = 0;
            var pb: [32]u8 = undefined;
            const k = zNavAndKill(&r, &host, b, std.fmt.bufPrint(&pb, "/s/epage?z6y{d}", .{round}) catch "/s/epage", durs[round], &ms);
            var tb: [16]u8 = undefined;
            const v = a9revive(&r, b, std.fmt.bufPrint(&tb, "z6on{d}", .{round}) catch "z6on");
            const st = r.until(Run.strictSettled, b, g, wait_ms);
            var nb: [48]u8 = undefined;
            report(k >= 1 and st and r.strict[b] == .on and a9bypassed(v), std.fmt.bufPrint(&nb, "Z-recrash-strict-on-{d}", .{round}) catch "Z-recrash-strict-on", std.fmt.bufPrint(&d, "Page.crash {s} · on while dead · revive nav + kills {d} (last at {d} ms) · revive again: early {s} nav {s} sub {s} reload {s} sub {s} · settled {} {s} (want bypassed/net, on)", .{ cr, k, ms, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]) }) catch "");
        }
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z7(10 차 LOW-1): 고치기 전 짝 자리 256 은 모든 탭이 나눠, 죽은 탭 하나가 다 썼다 — 죽은 채 엄격을 70 번 켜고 끈다(명령 280). 그 뒤 ① 다른 탭의
/// 기록을 죽은 동안 끄고 되살리면 본문을 읽는가(고치기 전: 그 탭의 `disable` 이 자리를 얻지 못해 다시 맞추기를 몰랐다), ② 살아 있는 셋째 탭의 엄격 켬이
/// `failed` 로 밀리는가(고치기 전 2/2), ③ 죽은 탭을 되살린 뒤. 이제 자리는 탭마다 종류마다 하나다(`net_domain.Tab`).
fn zSlots(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_slots", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const hog: u64 = 32;
    const vic: u64 = 33;
    const third: u64 = 34;
    try r.create(hog, uLoop(&u, "/a9/top?hog"));
    try r.watch(hog);
    try r.create(vic, uLoop(&u, "/a9/top?vic"));
    try r.watch(vic);
    try r.create(third, uLoop(&u, "/a9/top?third"));
    try r.watch(third);
    // 대조: 자리가 넉넉할 때 셋째 탭의 엄격 켬은 on.
    const gc = try sendBlock(&r, third, "127.0.0.1");
    const stc = r.until(Run.strictSettled, third, gc, wait_ms);
    const third_ctrl = r.strict[third];
    const gc2 = try sendBlock(&r, third, "");
    _ = r.until(Run.stateAt, third, gc2, wait_ms);
    const cr_hog = a9crash(&r, hog);
    var i: u32 = 0;
    while (i < 70) : (i += 1) {
        _ = try sendBlock(&r, hog, "127.0.0.1");
        _ = try sendBlock(&r, hog, "");
    }
    r.pump(1000);
    // ① 피해 탭: 기록 켬 → 죽음 → 끔 → 되살림.
    const on = zRecOn(&r, vic, 61);
    const b0 = zBody(&r, vic, "z7a");
    const cr_vic = a9crash(&r, vic);
    try r.host.send(.{ .net_record = .{ .browser = vic, .on = false } });
    r.pump(500);
    const b1 = zBody(&r, vic, "z7b");
    const b2 = zBody(&r, vic, "z7c");
    report(on and zIsBody(b0) and !zIsBody(b1) and !zIsBody(b2), "Z-slots-victim-record-off", std.fmt.bufPrint(&d, "hog Page.crash {s} + 70 on/off while dead · victim record {} → {s} · Page.crash {s} · off while dead · revive → {s} · next → {s} (want body, then not body twice)", .{ cr_hog, on, b0, cr_vic, b1, b2 }) catch "");
    // ② 셋째 탭의 엄격 켬(살아 있음).
    const g3 = try sendBlock(&r, third, "127.0.0.1");
    const st3 = r.until(Run.strictSettled, third, g3, wait_ms);
    const third_full = r.strict[third];
    report(stc and third_ctrl == .on and st3 and third_full == .on, "Z-slots-third-strict-on", std.fmt.bufPrint(&d, "third tab strict on: before hog {} {s} · with hog's dead commands holding slots {} {s} (want on both)", .{ stc, @tagName(third_ctrl), st3, @tagName(third_full) }) catch "");
    const g4 = try sendBlock(&r, third, "");
    _ = r.until(Run.stateAt, third, g4, wait_ms);
    // ③ 죽은 탭을 되살린다 — 자리가 돌아오는가.
    r.nav(hog, uLoop(&u, "/a9/top?hog2"), false) catch {};
    r.pump(1500);
    const g5 = try sendBlock(&r, third, "127.0.0.1");
    const st5 = r.until(Run.strictSettled, third, g5, wait_ms);
    report(st5 and r.strict[third] == .on, "Z-slots-after-hog-revive", std.fmt.bufPrint(&d, "after reviving hog: third strict on {} {s} (want on)", .{ st5, @tagName(r.strict[third]) }) catch "");
    try r.host.send(.{ .destroy_browser = hog });
    try r.host.send(.{ .destroy_browser = vic });
    try r.host.send(.{ .destroy_browser = third });
    r.pump(300);
}

fn zLine(path: []const u8) []const u8 {
    var lb: [600]u8 = undefined;
    const line = lastSeen(path, &lb);
    return if (line.len == 0) "none" else if (std.mem.indexOf(u8, line, "sw=") != null) "sw" else "net";
}

/// Z8(10 차 LOW-2 — 남는 틈): 되살린 문서의 머리 하위 자원(css·script·img·막을 img·파싱 중 fetch)이 다시 보낸 값보다 먼저 나가는가 — 죽은 동안 켬 →
/// 되살림(모두 `net`, 막을 img 는 서버에 닿지 않음 — 종류를 단 규칙은 서비스 워커 길에 듣지 않는다). 죽은 동안 끔 → 되살림은 문서가 다스려지고
/// 막는 스크립트 뒤의 fetch 와 다음 문서는 `sw` 여야 한다; 머리의 css·script·img 는 새 렌더러가 되받은 옛 우회로 먼저 나간다(`net` — 고치지 못한
/// 틈, 늘 「더 우회」 쪽이라 막을 요청은 새지 않는다 — 계획 문서 「W9d③ 10 차」). 그 셋은 보고 줄에 적기만 한다. 5 판.
fn zEarly(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_early", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var pb: [256]u8 = undefined;
    const b: u64 = 35;
    try r.create(b, uLoop(&u, "/s/page?Z8"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const rule: msg.NetBlockRule = .{ .id = 81, .types = protocol.net_block.typeBits("image").?, .site = "127.0.0.1", .pattern = pat(&pb, "127.0.0.1", "/s/*-blkimg*") };
    const Send = struct {
        fn f(rr: *Run, bb: u64, rl: msg.NetBlockRule, strict: []const u8) !u32 {
            rr.gen += 1;
            var v: msg.NetBlock = .{ .browser = bb, .generation = rr.gen, .strict_site = strict, .count = 1 };
            v.rules[0] = rl;
            try rr.host.send(.{ .net_block = v });
            return rr.gen;
        }
    }.f;
    // 대조: 살아 있는 엄격 켬.
    const g0 = try Send(&r, b, rule, "127.0.0.1");
    const st0 = r.until(Run.strictSettled, b, g0, wait_ms);
    r.nav(b, uLoop(&u, "/s/zhead?z8c"), false) catch {};
    r.pump(800);
    const ctl_ok = std.mem.eql(u8, zLine("/s/z8c-css"), "net") and std.mem.eql(u8, zLine("/s/z8c-js"), "net") and std.mem.eql(u8, zLine("/s/z8c-early"), "net") and std.mem.eql(u8, zLine("/s/z8c-img"), "net") and seen("/s/z8c-blkimg") == 0;
    report(std.mem.eql(u8, c0, "controlled") and st0 and ctl_ok, "Z-early-alive-control", std.fmt.bufPrint(&d, "start {s} · strict on {} · css {s} js {s} early {s} img {s} blkimg server {d} (want net ×4, 0)", .{ c0, st0, zLine("/s/z8c-css"), zLine("/s/z8c-js"), zLine("/s/z8c-early"), zLine("/s/z8c-img"), seen("/s/z8c-blkimg") }) catch "");
    // 대조 ③(`ZEARLY_CTL`): 엄격을 끈 채 죽이고 아무것도 보내지 않고 되살린다 — 머리 하위 자원이 서비스 워커를 지나면, 죽은 동안 끈 판의 `net` 은
    // 새 렌더러가 되받은 옛 우회 때문이다.
    if (std.c.getenv("ZEARLY_CTL") != null) {
        const g = try Send(&r, b, rule, "");
        _ = r.until(Run.stateAt, b, g, wait_ms);
        r.nav(b, uLoop(&u, "/s/page?z8pre"), false) catch {};
        r.pump(500);
        const cr = a9crash(&r, b);
        r.nav(b, uLoop(&u, "/s/zhead?z8q"), false) catch {};
        r.pump(800);
        const ok = std.mem.eql(u8, zLine("/s/z8q-css"), "sw") and std.mem.eql(u8, zLine("/s/z8q-js"), "sw") and std.mem.eql(u8, zLine("/s/z8q-early"), "sw") and std.mem.eql(u8, zLine("/s/z8q-img"), "sw");
        report(ok, "Z-early-crash-nochange-control", std.fmt.bufPrint(&d, "strict off · Page.crash {s} · nothing sent · revive: ctl {s} css {s} js {s} early {s} img {s} (want sw ×4)", .{ cr, ctlOf(&r, b), zLine("/s/z8q-css"), zLine("/s/z8q-js"), zLine("/s/z8q-early"), zLine("/s/z8q-img") }) catch "");
        const g2 = try Send(&r, b, rule, "127.0.0.1");
        _ = r.until(Run.strictSettled, b, g2, wait_ms);
    }
    // 대조 ②: 살아 있는 엄격 끔 — 다스리는 문서의 머리 하위 자원은 모두 서비스 워커를 지난다(이 페이지·서비스 워커의 기준).
    {
        const g = try Send(&r, b, rule, "");
        _ = r.until(Run.stateAt, b, g, wait_ms);
        r.nav(b, uLoop(&u, "/s/zhead?z8d"), false) catch {};
        r.pump(800);
        const ok = std.mem.eql(u8, zLine("/s/z8d-css"), "sw") and std.mem.eql(u8, zLine("/s/z8d-js"), "sw") and std.mem.eql(u8, zLine("/s/z8d-early"), "sw") and std.mem.eql(u8, zLine("/s/z8d-img"), "sw");
        report(ok, "Z-early-alive-off-control", std.fmt.bufPrint(&d, "strict off alive · ctl {s} css {s} js {s} early {s} img {s} (want sw ×4)", .{ ctlOf(&r, b), zLine("/s/z8d-css"), zLine("/s/z8d-js"), zLine("/s/z8d-early"), zLine("/s/z8d-img") }) catch "");
        // 그리고 같은 문서를 한 번 더(살아 있는 렌더러의 새 문서).
        r.nav(b, uLoop(&u, "/s/zhead?z8e"), false) catch {};
        r.pump(800);
        report(true, "Z-early-alive-off-control2(obs)", std.fmt.bufPrint(&d, "again · css {s} js {s} early {s} img {s}", .{ zLine("/s/z8e-css"), zLine("/s/z8e-js"), zLine("/s/z8e-early"), zLine("/s/z8e-img") }) catch "");
        const g2 = try Send(&r, b, rule, "127.0.0.1");
        _ = r.until(Run.strictSettled, b, g2, wait_ms);
    }
    var k: u32 = 0;
    while (k < 5) : (k += 1) {
        var tb: [8][48]u8 = undefined;
        {
            const cr = a9crash(&r, b);
            const g = try Send(&r, b, rule, "");
            _ = r.until(Run.stateAt, b, g, wait_ms);
            const tag = std.fmt.bufPrint(&tb[0], "z8o{d}", .{k}) catch "z8o";
            r.nav(b, uLoop(&u, std.fmt.bufPrint(&tb[1], "/s/zhead?{s}", .{tag}) catch "/s/zhead"), false) catch {};
            r.pump(800);
            const css = zLine(std.fmt.bufPrint(&tb[2], "/s/{s}-css", .{tag}) catch "x");
            const js = zLine(std.fmt.bufPrint(&tb[3], "/s/{s}-js", .{tag}) catch "x");
            const early = zLine(std.fmt.bufPrint(&tb[4], "/s/{s}-early", .{tag}) catch "x");
            const img = zLine(std.fmt.bufPrint(&tb[5], "/s/{s}-img", .{tag}) catch "x");
            const ctl = ctlOf(&r, b);
            // 머리 하위 자원(css·js·img)은 남는 틈(옛 우회 — `net` 일 수 있다)이라 단언하지 않는다; 문서·파싱 중 fetch 는 다시 맞춘 값이어야 한다.
            const ok = std.mem.eql(u8, early, "sw") and std.mem.eql(u8, ctl, "controlled");
            // 되살린 뒤 같은 렌더러의 새 문서 — 다시 맞춘 뒤에는 모두 서비스 워커를 지나야 한다.
            const tag2 = std.fmt.bufPrint(&tb[7], "z8p{d}", .{k}) catch "z8p";
            r.nav(b, uLoop(&u, std.fmt.bufPrint(&tb[1], "/s/zhead?{s}", .{tag2}) catch "/s/zhead"), false) catch {};
            r.pump(800);
            var t2: [4][48]u8 = undefined;
            const css2 = zLine(std.fmt.bufPrint(&t2[0], "/s/{s}-css", .{tag2}) catch "x");
            const js2 = zLine(std.fmt.bufPrint(&t2[1], "/s/{s}-js", .{tag2}) catch "x");
            const img2 = zLine(std.fmt.bufPrint(&t2[2], "/s/{s}-img", .{tag2}) catch "x");
            var nb2: [48]u8 = undefined;
            report(std.mem.eql(u8, css2, "sw") and std.mem.eql(u8, js2, "sw") and std.mem.eql(u8, img2, "sw"), std.fmt.bufPrint(&nb2, "Z-early-dead-off-next-{d}", .{k}) catch "Z-early-dead-off-next", std.fmt.bufPrint(&d, "next doc after revive · css {s} js {s} img {s} (want sw ×3)", .{ css2, js2, img2 }) catch "");
            var nb: [40]u8 = undefined;
            report(ok, std.fmt.bufPrint(&nb, "Z-early-dead-off-{d}", .{k}) catch "Z-early-dead-off", std.fmt.bufPrint(&d, "Page.crash {s} · off while dead · revive: ctl {s} early {s} (want controlled, sw) · head css {s} js {s} img {s} (residual gap: old bypass allowed)", .{ cr, ctl, early, css, js, img }) catch "");
        }
        {
            const cr = a9crash(&r, b);
            const g = try Send(&r, b, rule, "127.0.0.1");
            const tag = std.fmt.bufPrint(&tb[0], "z8n{d}", .{k}) catch "z8n";
            r.nav(b, uLoop(&u, std.fmt.bufPrint(&tb[1], "/s/zhead?{s}", .{tag}) catch "/s/zhead"), false) catch {};
            r.pump(800);
            const st = r.until(Run.strictSettled, b, g, wait_ms);
            const css = zLine(std.fmt.bufPrint(&tb[2], "/s/{s}-css", .{tag}) catch "x");
            const js = zLine(std.fmt.bufPrint(&tb[3], "/s/{s}-js", .{tag}) catch "x");
            const early = zLine(std.fmt.bufPrint(&tb[4], "/s/{s}-early", .{tag}) catch "x");
            const img = zLine(std.fmt.bufPrint(&tb[5], "/s/{s}-img", .{tag}) catch "x");
            const blk = seen(std.fmt.bufPrint(&tb[6], "/s/{s}-blkimg", .{tag}) catch "x");
            const ctl = ctlOf(&r, b);
            const ok = st and r.strict[b] == .on and std.mem.eql(u8, css, "net") and std.mem.eql(u8, js, "net") and std.mem.eql(u8, early, "net") and std.mem.eql(u8, img, "net") and blk == 0 and std.mem.eql(u8, ctl, "bypassed");
            var nb: [40]u8 = undefined;
            report(ok, std.fmt.bufPrint(&nb, "Z-early-dead-on-{d}", .{k}) catch "Z-early-dead-on", std.fmt.bufPrint(&d, "Page.crash {s} · on while dead · revive: ctl {s} css {s} js {s} early {s} img {s} blkimg server {d} · settled {} {s} (want bypassed, net ×4, 0, on)", .{ cr, ctl, css, js, early, img, blk, st, @tagName(r.strict[b]) }) catch "");
        }
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z9: 204 로 되살림(문서가 서지 않는 이동) — 그 뒤의 이동에서 끔이 맞는가, 기록 끔도.
fn z204(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_204", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 36;
    try r.create(b, uLoop(&u, "/s/page?Z9"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const g1 = try sendBlock(&r, b, "127.0.0.1");
    const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
    {
        const cr = a9crash(&r, b);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        try r.host.send(.{ .navigate = .{ .browser = b, .url = uLoop(&u, "/z/204"), .user = false } });
        r.pump(1500);
        const n = zRendererCount(&host);
        const v = a9revive(&r, b, "z9off");
        report(std.mem.eql(u8, c0, "controlled") and st1 and st and a9controlled(v), "Z-204-strict-off", std.fmt.bufPrint(&d, "start {s} on {} · Page.crash {s} · off while dead answered {} · nav 204 (renderers {d}) · revive: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw)", .{ c0, st1, cr, st, n, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    {
        const on = zRecOn(&r, b, 91);
        const b0 = zBody(&r, b, "z9a");
        const cr = a9crash(&r, b);
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(400);
        try r.host.send(.{ .navigate = .{ .browser = b, .url = uLoop(&u, "/z/204"), .user = false } });
        r.pump(1500);
        const b1 = zBody(&r, b, "z9b");
        const b2 = zBody(&r, b, "z9c");
        report(on and zIsBody(b0) and !zIsBody(b1) and !zIsBody(b2), "Z-204-record-off", std.fmt.bufPrint(&d, "record {} → {s} · Page.crash {s} · off while dead · nav 204 · next → {s} · next → {s} (want body, then not body twice)", .{ on, b0, cr, b1, b2 }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z10: 같은 렌더러를 나눈 팝업 — 여는 탭 A(엄격 켬)와 그 팝업 P(엄격 켬). A 를 죽이면 P 도 죽는다. 죽은 동안 A 만 끈다 → A·P 를 되살린다: A 는
/// 다스림, P 는 그대로 우회(A 의 다시 맞추기가 P 를 덮지 않는다).
fn zPopup(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_popup", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var o: [200]u8 = undefined;
    const a: u64 = 37;
    const p: u64 = 38;
    try r.create(a, uLoop(&u, "/s/page?Z10"));
    const c0 = swReady(&r, a);
    try r.watch(a);
    try r.host.send(.{ .popup_reserve = .{ .browser = p } });
    try r.host.send(.{ .new_tab_credit = a });
    r.pump(100);
    _ = r.evAs(a, "(window.w=window.open('/s/page?zpop','_blank','popup,width=300,height=300'),'opened')", &o, true);
    r.pump(2500);
    const made = r.created[p];
    try r.watch(p);
    const cp0 = ctlOf(&r, p);
    const ga = try sendBlock(&r, a, "127.0.0.1");
    const sta = r.until(Run.strictSettled, a, ga, wait_ms);
    const gp = try sendBlock(&r, p, "127.0.0.1");
    const stp = r.until(Run.strictSettled, p, gp, wait_ms);
    const n0 = zRendererCount(&host);
    const cr = a9crash(&r, a);
    const pp = r.call(p, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", 3000) catch null;
    const p_dead = pp == null or pp.? != .ok;
    const g = try sendBlock(&r, a, "");
    const st = r.until(Run.stateAt, a, g, wait_ms);
    const va = a9revive(&r, a, "zpa");
    const vp = a9revive(&r, p, "zpp");
    const pass = made and std.mem.eql(u8, c0, "controlled") and sta and stp and st and a9controlled(va) and a9bypassed(vp) and r.strict[p] == .on;
    report(pass, "Z-popup-shared-renderer", std.fmt.bufPrint(&d, "A start {s} · popup made {} ctl {s} · strict on A {} P {} · renderers {d} · A Page.crash {s} · P probe {s} (dead {}) · A off while dead {} · revive A: early {s} nav {s} sub {s} reload {s} sub {s} · revive P: early {s} nav {s} sub {s} reload {s} sub {s} · P state {s} (want A controlled/sw, P bypassed/net)", .{ c0, made, cp0, sta, stp, n0, cr, if (pp) |x| @tagName(x) else "timeout", p_dead, st, va.early, va.ctl, va.sub, va.ctl2, va.sub2, vp.early, vp.ctl, vp.sub, vp.ctl2, vp.sub2, @tagName(r.strict[p]) }) catch "");
    try r.host.send(.{ .destroy_browser = p });
    try r.host.send(.{ .destroy_browser = a });
    r.pump(300);
}

/// Z11: 엄격과 기록이 도메인을 나눈 탭 — 기록 끔은 `disable` 이 아니라 가벼운 `enable`(버퍼 0)이다. 살아 있을 때·죽은 동안·바쁜 채 죽음 세 판에서
/// 끈 뒤 본문을 읽는가. 엄격 사이트는 `/a9/top` 의 호스트를 덮는다.
fn zStrictRec(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_srec", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 39;
    try r.create(b, uLoop(&u, "/a9/top?z11"));
    try r.watch(b);
    const g = try sendBlock(&r, b, "127.0.0.1");
    const st = r.until(Run.strictSettled, b, g, wait_ms);
    for ([_]u8{ 0, 1, 2 }, 0..) |mode, i| {
        var tb: [3][16]u8 = undefined;
        _ = &tb;
        const on = zRecOn(&r, b, 101 + @as(u32, @intCast(i)));
        const b0 = zBody(&r, b, std.fmt.bufPrint(&tb[0], "z11a{d}", .{i}) catch "z11a");
        var how: []const u8 = "alive";
        if (mode == 1) {
            how = a9crash(&r, b);
        } else if (mode == 2) {
            _ = zBusy(&r, b, 6000);
            how = "busy";
        }
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(400);
        if (mode == 2) {
            _ = zKillRenderers(&host);
            r.pump(800);
        }
        const b1 = zBody(&r, b, std.fmt.bufPrint(&tb[1], "z11b{d}", .{i}) catch "z11b");
        const b2 = zBody(&r, b, std.fmt.bufPrint(&tb[2], "z11c{d}", .{i}) catch "z11c");
        const names = [_][]const u8{ "Z-strict-record-off-alive", "Z-strict-record-off-dead", "Z-strict-record-off-busy-kill" };
        report(st and on and zIsBody(b0) and !zIsBody(b1) and !zIsBody(b2), names[mode], std.fmt.bufPrint(&d, "strict on {} {s} · record {} → {s} · {s} → off · next → {s} · next → {s} · strict {s} (want body, then not body twice)", .{ st, @tagName(r.strict[b]), on, b0, how, b1, b2, @tagName(r.strict[b]) }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z12: 죽음과 답의 경주(살아남은 변이 ② 의 다른 꼴) — 엄격 켬(정착) → [끔·켬·Page.crash] 를 쉬지 않고 → 죽은 동안 끔 → 되살림. 죽기 직전에 보낸
/// 명령의 답이 렌더러 죽음 뒤에 오면(늦은 성공) 그 답이 「죽은 동안」 표시를 먼저 써 버려, 그 뒤 죽은 동안 보낸 끔이 표시 없이 사라질 수 있다.
/// `usleep` 으로 crash 를 0–4 ms 늦춰 10 판. 기대: 매 판 되살린 뒤 다스림(`controlled/sw`).
fn zRace(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_race", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 40 - 1;
    try r.create(b, uLoop(&u, "/s/page?Z12"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    var k: u32 = 0;
    while (k < 10) : (k += 1) {
        const g1 = try sendBlock(&r, b, "127.0.0.1");
        const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
        _ = try sendBlock(&r, b, "");
        _ = try sendBlock(&r, b, "127.0.0.1");
        _ = usleep(@intCast((k % 5) * 1000));
        r.next_call += 1;
        try r.host.send(.{ .devtools_call = .{ .browser = b, .call = r.next_call, .method = "Page.crash", .params_size = 2 } });
        try r.host.send(.{ .devtools_call_data = .{ .browser = b, .call = r.next_call, .bytes = "{}" } });
        r.pump(800);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, wait_ms);
        var tb: [16]u8 = undefined;
        const v = a9revive(&r, b, std.fmt.bufPrint(&tb, "z12r{d}", .{k}) catch "z12r");
        var nb: [40]u8 = undefined;
        report(std.mem.eql(u8, c0, "controlled") and st1 and st and a9controlled(v), std.fmt.bufPrint(&nb, "Z-race-off-on-crash-{d}", .{k}) catch "Z-race", std.fmt.bufPrint(&d, "start {s} · on {} · off,on,Page.crash (+{d} ms) · off while dead answered {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} (want controlled/sw)", .{ c0, st1, k % 5, st, v.early, v.ctl, v.sub, v.ctl2, v.sub2 }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// Z13: 다시 맞추기가 켜 둔 기록을 끄지 않는가(W9d② 와의 상호작용) — 기록 켬 + 엄격 켬 → 죽음 → 죽은 동안 엄격 끔 → 되살림: 기록은 그대로 `on`,
/// 본문을 읽을 수 있어야 한다(다시 맞추기는 기록이 쥔 도메인을 끄지 않는다). 바쁜 채 죽임도.
fn zKeepRec(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "z_keeprec", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 38;
    try r.create(b, uLoop(&u, "/a9/top?z13"));
    try r.watch(b);
    const on = zRecOn(&r, b, 121);
    for ([_]bool{ false, true }, 0..) |busy, i| {
        var tb: [3][16]u8 = undefined;
        _ = &tb;
        const g1 = try sendBlock(&r, b, "127.0.0.1");
        const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
        const b0 = zBody(&r, b, std.fmt.bufPrint(&tb[0], "z13a{d}", .{i}) catch "z13a");
        var how: []const u8 = undefined;
        if (busy) {
            _ = zBusy(&r, b, 6000);
            const g = try sendBlock(&r, b, "");
            _ = r.until(Run.stateAt, b, g, 3000);
            r.pump(300);
            how = if (zKillRenderers(&host) > 0) "busy+kill" else "busy+nokill";
            r.pump(800);
        } else {
            how = a9crash(&r, b);
            const g = try sendBlock(&r, b, "");
            _ = r.until(Run.stateAt, b, g, wait_ms);
        }
        const b1 = zBody(&r, b, std.fmt.bufPrint(&tb[1], "z13b{d}", .{i}) catch "z13b");
        const b2 = zBody(&r, b, std.fmt.bufPrint(&tb[2], "z13c{d}", .{i}) catch "z13c");
        report(on and st1 and zIsBody(b0) and zIsBody(b1) and zIsBody(b2) and r.record_state[b] == .on, if (busy) "Z-keep-record-strict-off-busy" else "Z-keep-record-strict-off-dead", std.fmt.bufPrint(&d, "record {} · strict on {} · body {s} · {s} → strict off · revive → {s} · next → {s} · record {s} (want body ×3, on)", .{ on, st1, b0, how, b1, b2, @tagName(r.record_state[b]) }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════════
// v20j(10 차 고침의 적대 검증 — 11 차) — 기본 실행(`a8want`): zjnofail·zjsuper·zjrec·zjpop·zjclose·zjxnav. 이름이 있을 때만(`zwant`): zjnav(관찰).
// ════════════════════════════════════════════════════════════════════════════════════════════════════════

fn zjEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── 12 차 LOW-1: ZJ 판정의 질 ──────────────────────────────────────────────────────────────────────────────────────────
// 11 차 판은 「본문 없음」 을 `!zIsBody(x)`(본문이 「아니다」)로 쟀다. 그러면 되살림이 실패하거나 늦어 `no-loader`·`timeout`·`other` 가 나와도
// PASS 한다 — 탭이 아예 서지 않은 빈 판이 초록이다. 바쁨도 `zBusy` 의 `busy` 로만 봤는데, 그것은 돌기를 건 평가의 답이라 돌기가 돌지 않아도
// 늘 `busy` 다. 그래서 ZJ 갈래는 넷을 효과로 잰다.
//   (1) 읽은 문서가 바란 문서인가 — 주 프레임 주소의 표지(`zjRead` — 끝내 서지 않으면 `wrong-doc`).
//   (2) 「본문 없음」 은 `error` 일치 — 문서는 섰고 `getResponseBody` 만 거절했다(`zjNoBody`).
//   (3) 바쁨이 실제로 렌더러를 막았는가 — 명령을 보낸 뒤, 죽이기 전에 평가 `1` 이 답하지 않는다(`zjBusyNow`).
//   (4) 죽음이 실제로 났는가 — sidecar 의 `renderer_gone` 을 기다리고 확인한다(`zjKill` — 고정 800 ms 대신).

/// 「문서는 섰고 본문만 거절됐다」 — `zjRead`·`zjBody` 의 `error`. `no-loader`·`timeout`·`other`·`wrong-doc` 은 「없음」 이 아니라 판이 비었다는 뜻이다.
fn zjNoBody(s: []const u8) bool {
    return zjEq(s, "error");
}

/// 바란 문서를 읽었고 답이 왔다(본문이든 거절이든) — 「상태가 on 이 아닌데 본문이 읽히는가」 를 재는 판이 빈 판으로 PASS 하지 않게.
fn zjAnswered(s: []const u8) bool {
    return zIsBody(s) or zjNoBody(s);
}

/// 주 프레임이 `tag` 를 주소에 담은 문서가 될 때까지(조건 — 많아야 5 초) 기다린 뒤 그 문서의 본문을 에이전트의 DevTools(`Network.getResponseBody`,
/// 문서의 loaderId)로 읽는다. `body`·`error`(거절)·`other`(본문이 그 문서 것이 아님)·`timeout`·`no-loader`·`wrong-doc`(끝내 그 문서가 서지 않음).
fn zjRead(r: *Run, b: u64, tag: []const u8) []const u8 {
    var lb: [80]u8 = undefined;
    var ub: [512]u8 = undefined;
    var loader: []const u8 = "";
    var here = false;
    const dl = os.nowMs() + 5000;
    while (true) {
        const st = r.call(b, "Page.getFrameTree", "{}", 5000) catch null;
        if (st != null and st.? == .ok) {
            // 주 프레임(`frameTree.frame`)이 먼저 온다 — 하위 프레임(`childFrames`)은 그 뒤다.
            loader = grabStr(r.result.items, "\"loaderId\":\"", &lb);
            here = std.mem.indexOf(u8, grabStr(r.result.items, "\"url\":\"", &ub), tag) != null;
        }
        if ((here and loader.len != 0) or os.nowMs() >= dl) break;
        r.pump(100);
    }
    if (loader.len == 0) return "no-loader";
    if (!here) return "wrong-doc";
    var qb: [160]u8 = undefined;
    const res = r.call(b, "Network.getResponseBody", std.fmt.bufPrint(&qb, "{{\"requestId\":\"{s}\"}}", .{loader}) catch "", 5000) catch null;
    if (res == null) return "timeout";
    if (res.? != .ok) return "error";
    return if (std.mem.indexOf(u8, r.result.items, "a9top") != null) "body" else "other";
}

/// `/a9/top?tag` 로 이동해(죽은 뒤면 이 이동이 되살린다) 그 문서의 본문을 읽는다 — `zBody` 의 ZJ 판(이동 뒤 고정 600 ms 대신 그 문서가 섰는가를 본다).
fn zjBody(r: *Run, b: u64, tag: []const u8) []const u8 {
    var u: [512]u8 = undefined;
    var pb: [64]u8 = undefined;
    r.nav(b, uLoop(&u, std.fmt.bufPrint(&pb, "/a9/top?{s}", .{tag}) catch "/a9/top"), false) catch {};
    return zjRead(r, b, tag);
}

/// 지금 그 탭의 주 프레임이 바쁜가 — 평가 `1` 이 500 ms 안에 답하지 않으면 바쁘다(`zBusy` 의 돌기가 실제로 렌더러를 막고 있다). 명령을 보낸
/// 뒤에 물으므로 참이면 그 명령들은 바쁜 렌더러에 닿았다(돌기는 `zBusy` 가 돌아오기 전에 시작한다). 늦은 답은 `Run.take` 가 버리고, 그 사이
/// 렌더러가 죽으면 sidecar 가 `detached` 로 닫는다.
fn zjBusyNow(r: *Run, b: u64) bool {
    const st = r.call(b, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", 500) catch return false;
    return st == null;
}

/// 바쁨이 끝날 때까지(조건 — 평가 `1` 이 답한다, 많아야 `ms`). 렌더러는 받은 차례로 처리하므로 그 답이 오면 앞서 미룬 Network 명령의 답도
/// 이미 나갔다 — sidecar 가 그것을 상태 프레임으로 내는 짧은 틈만 더 퍼 온다. 앞 판의 고정 4500 ms 대신.
fn zjUntilIdle(r: *Run, b: u64, ms: u32) bool {
    const st = r.call(b, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", ms) catch null;
    r.pump(300);
    return st != null and st.? == .ok;
}

/// 평가로 물을 수 없는 옛 렌더러(닫은 탭·다른 사이트로 옮겨 간 탭)의 바쁨이 끝나고 늦은 답이 올 때까지 — `zBusy` 가 돌아온 때(`t0`)부터
/// `busy_ms` 와 여유 500 ms. 시간 기다림이지만 돌기는 벽시계(`Date.now`)로 끝나고 `t0` 전에 시작하므로 기준을 그때에 둔다(앞 판의 「지금부터
/// 3000·6000 ms」 는 앞 단계가 느리면 모자라거나 남았다).
fn zjPumpPastBusy(r: *Run, t0: i64, busy_ms: u32) void {
    const end = t0 + busy_ms + 500;
    const now = os.nowMs();
    if (now < end) r.pump(@intCast(end - now));
}

const ZjDeath = struct { killed: u32, died: bool };

/// 이 host 의 렌더러를 kill -9 하고 `tabs` 모두에 sidecar 의 `renderer_gone` 이 올 때까지(조건 — 많아야 `wait_ms`) 기다린다. `died` 는 그 알림이
/// 모두 왔는가다 — 죽음이 실제로 났고 sidecar 가 그것을 처리했다(`blocking.rendererGone` 은 그 알림 앞에서 돈다).
fn zjKill(r: *Run, host: *Host, tabs: []const u64) ZjDeath {
    var before: [4]u32 = @splat(0);
    for (tabs, 0..) |t, i| before[i] = r.gone[t];
    const killed = zKillRenderers(host);
    return .{ .killed = killed, .died = zjUntilGone(r, tabs, before[0..tabs.len]) };
}

fn zjUntilGone(r: *Run, tabs: []const u64, before: []const u32) bool {
    const dl = os.nowMs() + wait_ms;
    while (true) {
        var all = true;
        for (tabs, before) |t, n| all = all and r.gone[t] > n;
        if (all) break;
        if (os.nowMs() >= dl) return false;
        r.pump(50);
    }
    r.pump(150); // 같은 차례에 뒤따르는 상태 프레임
    return true;
}

/// ZJ1: 바쁜 렌더러에 보낸 엄격 켬(셈에 드는 명령)이 죽음을 맞는다 — 되살리는 동안 거짓 `failed` 상태를 내지 않고 곧장 `on`(살아남은 변이
/// P2 「gone 이 자리를 표시하지 않음」 은 죽음을 맞은 켬의 실패 답을 셈에 넣어 `failed` 를 한 번 낸다 — 새 문서에서 다시 맞춰 끝은 같다).
fn zjNoFail(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_nofail", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 30;
    try r.create(b, uLoop(&u, "/s/page?J1"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    for ([_]bool{ true, false, true }, 0..) |use_kill, i| {
        const g0 = try sendBlock(&r, b, "");
        _ = r.until(Run.stateAt, b, g0, wait_ms);
        r.pump(300);
        const busy = zBusy(&r, b, 6000);
        const g = try sendBlock(&r, b, "127.0.0.1");
        r.pump(400);
        r.failed_frames[b] = 0;
        const busy_now = zjBusyNow(&r, b);
        var death: ZjDeath = .{ .killed = 0, .died = false };
        var cr: []const u8 = "-";
        if (use_kill) death = zjKill(&r, &host, &.{b}) else {
            const n = r.gone[b];
            cr = a9crash(&r, b);
            death.died = zjUntilGone(&r, &.{b}, &.{n});
        }
        var tb: [16]u8 = undefined;
        const v = a9revive(&r, b, std.fmt.bufPrint(&tb, "zj1r{d}", .{i}) catch "zj1r");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        r.pump(500); // 「뒤늦은 failed 가 없다」 를 재는 창 — 부정 단언이라 창 자체가 재는 것이다
        const pass = zjEq(c0, "controlled") and zjEq(busy, "busy") and busy_now and (death.killed >= 1 or !use_kill) and death.died and st and r.strict[b] == .on and r.failed_frames[b] == 0 and a9bypassed(v);
        var nb: [64]u8 = undefined;
        report(pass, std.fmt.bufPrint(&nb, "ZJ-busy-strict-on-{s}-no-false-failed-{d}", .{ if (use_kill) "kill" else "pagecrash", i }) catch "ZJ-nofail", std.fmt.bufPrint(&d, "start {s} · {s} (blocked {}) → on · killed {d} Page.crash {s} gone {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} · settled {} {s} · failed frames {d} (want blocked, gone, bypassed/net, on, 0 failed)", .{ c0, busy, busy_now, death.killed, cr, death.died, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]), r.failed_frames[b] }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// ZJ2: 덮기 — 바쁜 렌더러가 답을 미루는 동안 같은 종류 명령을 겹쳐 보낸다. 늦은 옛 답이 새 명령의 결과로 읽히지 않고, 끝 상태와 실제 우회가
/// 마지막 바람에 맞는가. (a) 같은 차례의 덮기(엄격 사이트 옮김 — `bypass_on` 을 `bypass_off` 가 덮는다; 살아남은 변이 P11 「먼저 온 명령이 자리를
/// 쥠」 은 덮은 명령을 짝짓지 않아 셈이 끝나지 않는다), (b) 켬→끔→켬, (c) 끔→켬→끔, (d)(e) 같은 꼴에 kill -9. 모든 판이 「명령을 보낸 뒤에도
/// 렌더러가 바빴다」(`zjBusyNow`)를 통과 조건에 넣는다 — 바쁨이 걸리지 않으면 덮기가 아니라 차례대로 답한 판이다.
fn zjSuper(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_super", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 31;
    try r.create(b, uLoop(&u, "/s/page?J2"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    {
        const busy = zBusy(&r, b, 4000);
        r.failed_frames[b] = 0;
        _ = try sendBlock(&r, b, "127.0.0.1");
        r.pump(30);
        const g = try sendBlock(&r, b, "other.test");
        const busy_now = zjBusyNow(&r, b);
        const st = r.until(Run.strictSettled, b, g, 12000);
        const sta = r.strict[b];
        const ctl = reloadCtl(&r, b);
        const sub = a9sub(&r, b, "/s/zj2a");
        report(zjEq(c0, "controlled") and zjEq(busy, "busy") and busy_now and st and sta == .on and r.failed_frames[b] == 0 and zjEq(ctl, "controlled") and zjEq(sub, "sw"), "ZJ-supersede-same-epoch-site-move", std.fmt.bufPrint(&d, "start {s} · {s} → strict 127.0.0.1 then other.test (+30 ms) · blocked {} · settled {} {s} failed {d} · reload {s} sub {s} (want blocked, on, controlled/sw)", .{ c0, busy, busy_now, st, @tagName(sta), r.failed_frames[b], ctl, sub }) catch "");
    }
    {
        const g0 = try sendBlock(&r, b, "");
        _ = r.until(Run.stateAt, b, g0, wait_ms);
        const busy = zBusy(&r, b, 4000);
        r.failed_frames[b] = 0;
        _ = try sendBlock(&r, b, "127.0.0.1");
        r.pump(30);
        _ = try sendBlock(&r, b, "");
        r.pump(30);
        const g = try sendBlock(&r, b, "127.0.0.1");
        const busy_now = zjBusyNow(&r, b);
        const st = r.until(Run.strictSettled, b, g, 12000);
        const sta = r.strict[b];
        const ctl = reloadCtl(&r, b);
        const sub = a9sub(&r, b, "/s/zj2b");
        report(zjEq(busy, "busy") and busy_now and st and sta == .on and r.failed_frames[b] == 0 and zjEq(ctl, "bypassed") and zjEq(sub, "net"), "ZJ-supersede-on-off-on-busy", std.fmt.bufPrint(&d, "{s} → on, off, on · blocked {} · settled {} {s} failed {d} · reload {s} sub {s} (want blocked, on, bypassed/net)", .{ busy, busy_now, st, @tagName(sta), r.failed_frames[b], ctl, sub }) catch "");
    }
    {
        const busy = zBusy(&r, b, 4000);
        _ = try sendBlock(&r, b, "");
        r.pump(30);
        _ = try sendBlock(&r, b, "127.0.0.1");
        r.pump(30);
        const g = try sendBlock(&r, b, "");
        const busy_now = zjBusyNow(&r, b);
        const st = r.until(Run.stateAt, b, g, 12000);
        const idle = zjUntilIdle(&r, b, 12000); // 바쁨이 끝나고 늦은 답이 모두 온 뒤
        const sta = r.strict[b];
        const ctl = reloadCtl(&r, b);
        const sub = a9sub(&r, b, "/s/zj2c");
        report(zjEq(busy, "busy") and busy_now and st and idle and sta == .off and zjEq(ctl, "controlled") and zjEq(sub, "sw"), "ZJ-supersede-off-on-off-busy", std.fmt.bufPrint(&d, "{s} (from on) → off, on, off · blocked {} · answered {} · idle {} {s} after late answers · reload {s} sub {s} (want blocked, off, controlled/sw)", .{ busy, busy_now, st, idle, @tagName(sta), ctl, sub }) catch "");
    }
    {
        const busy = zBusy(&r, b, 6000);
        r.failed_frames[b] = 0;
        _ = try sendBlock(&r, b, "127.0.0.1");
        r.pump(30);
        _ = try sendBlock(&r, b, "");
        r.pump(30);
        const g = try sendBlock(&r, b, "127.0.0.1");
        r.pump(300);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const v = a9revive(&r, b, "zj2d");
        const st = r.until(Run.strictSettled, b, g, wait_ms);
        r.pump(300);
        report(zjEq(busy, "busy") and busy_now and death.killed >= 1 and death.died and st and r.strict[b] == .on and r.failed_frames[b] == 0 and a9bypassed(v), "ZJ-supersede-on-off-on-busy-kill", std.fmt.bufPrint(&d, "{s} (from off) → on, off, on · blocked {} · killed {d} gone {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} · settled {} {s} failed {d} (want blocked, gone, bypassed/net, on, 0)", .{ busy, busy_now, death.killed, death.died, v.early, v.ctl, v.sub, v.ctl2, v.sub2, st, @tagName(r.strict[b]), r.failed_frames[b] }) catch "");
    }
    {
        const busy = zBusy(&r, b, 6000);
        _ = try sendBlock(&r, b, "");
        r.pump(30);
        _ = try sendBlock(&r, b, "127.0.0.1");
        r.pump(30);
        const g = try sendBlock(&r, b, "");
        const st = r.until(Run.stateAt, b, g, 3000);
        r.pump(300);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const v = a9revive(&r, b, "zj2e");
        report(zjEq(busy, "busy") and busy_now and death.killed >= 1 and death.died and st and r.strict[b] == .off and a9controlled(v), "ZJ-supersede-off-on-off-busy-kill", std.fmt.bufPrint(&d, "{s} (from on) → off, on, off · answered {} · blocked {} · killed {d} gone {} · revive: early {s} nav {s} sub {s} reload {s} sub {s} · state {s} (want blocked, gone, controlled/sw, off)", .{ busy, st, busy_now, death.killed, death.died, v.early, v.ctl, v.sub, v.ctl2, v.sub2, @tagName(r.strict[b]) }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

fn zjRecOff(r: *Run, b: u64) void {
    r.host.send(.{ .net_record = .{ .browser = b, .on = false } }) catch {};
    r.pump(300);
}

fn zjRecOnNoWait(r: *Run, b: u64, session: u32) void {
    r.host.send(.{ .net_record = .{ .browser = b, .on = true, .session = session } }) catch {};
    r.pump(60);
}

/// ZJ3: W9d② 본문 기록과 섞기 — 기록 끔·켬을 바쁜 렌더러와 죽음 사이에 섞는다. 기대: 끝 바람이 끔이면 되살린 문서가 서고 그 본문은 거절된다
/// (`error`); 끝 바람이 켬이면 상태가 `on` 이 아닌데 본문이 읽히는 일은 없다(꺼진·실패한 기록의 본문 노출 0). 모든 판이 「끔·켬을 보낸 뒤에도 렌더러가
/// 바빴다」(`zjBusyNow`)와 「죽음이 났다」(`renderer_gone`)를 통과 조건에 넣는다 — 둘 중 하나라도 빠지면 이 판이 재려는 경주가 열리지 않은 것이다.
fn zjRec(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_rec", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 32;
    try r.create(b, uLoop(&u, "/a9/top?zj3"));
    try r.watch(b);
    // e1: 켬 → 바쁨 → 끔·켬·끔 → kill.
    {
        const on = zRecOn(&r, b, 301);
        const b0 = zjBody(&r, b, "zj3e1a");
        const busy = zBusy(&r, b, 6000);
        zjRecOff(&r, b);
        zjRecOnNoWait(&r, b, 302);
        zjRecOff(&r, b);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const b1 = zjBody(&r, b, "zj3e1b");
        const b2 = zjBody(&r, b, "zj3e1c");
        report(on and zIsBody(b0) and busy_now and death.killed >= 1 and death.died and zjNoBody(b1) and zjNoBody(b2) and r.record_state[b] == .off, "ZJ-rec-busy-off-on-off-kill", std.fmt.bufPrint(&d, "record {} → {s} · {s} → off, on, off · blocked {} · killed {d} gone {} · revive → {s} · next → {s} · state {s} (want body, blocked, gone, then error ×2, off)", .{ on, b0, busy, busy_now, death.killed, death.died, b1, b2, @tagName(r.record_state[b]) }) catch "");
    }
    // e2: 켬 → 바쁨 → 다시 켬(새 세션) → 끔 → kill.
    {
        const on = zRecOn(&r, b, 303);
        const b0 = zjBody(&r, b, "zj3e2a");
        const busy = zBusy(&r, b, 6000);
        zjRecOnNoWait(&r, b, 304);
        zjRecOff(&r, b);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const b1 = zjBody(&r, b, "zj3e2b");
        const b2 = zjBody(&r, b, "zj3e2c");
        report(on and zIsBody(b0) and busy_now and death.killed >= 1 and death.died and zjNoBody(b1) and zjNoBody(b2), "ZJ-rec-busy-reon-off-kill", std.fmt.bufPrint(&d, "record {} → {s} · {s} → on(s2), off · blocked {} · killed {d} gone {} · revive → {s} · next → {s} (want body, blocked, gone, then error ×2)", .{ on, b0, busy, busy_now, death.killed, death.died, b1, b2 }) catch "");
    }
    // e3: 끈 채 바쁨 → 켬 → kill — 상태가 on 이 아닌데 본문이 읽히지 않는가. 단언이 모두 부정형이던 판이라 양성 대조를 셋 둔다: 끈 채 연 문서가
    // 섰고 거절됐다(`error` — 탭이 섰다), 켬을 보낸 뒤에도 바빴다, 죽음이 났다. 되살린 두 읽기도 답이 와야 한다(빈 판이 「노출 없음」 으로 PASS 하지 않게).
    {
        const b0 = zjBody(&r, b, "zj3e3a");
        const busy = zBusy(&r, b, 6000);
        zjRecOnNoWait(&r, b, 305);
        r.pump(300);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const b1 = zjBody(&r, b, "zj3e3b");
        const st1 = r.record_state[b];
        const b2 = zjBody(&r, b, "zj3e3c");
        const st2 = r.record_state[b];
        const leak = (zIsBody(b1) and st1 != .on) or (zIsBody(b2) and st2 != .on);
        report(zjNoBody(b0) and busy_now and death.killed >= 1 and death.died and zjAnswered(b1) and zjAnswered(b2) and !leak, "ZJ-rec-busy-on-kill-consistent", std.fmt.bufPrint(&d, "off → {s} · {s} → on(s) · blocked {} · killed {d} gone {} · revive → {s} (state {s}) · next → {s} (state {s}) (want error, blocked, gone, then answered and no body while state is not on)", .{ b0, busy, busy_now, death.killed, death.died, b1, @tagName(st1), b2, @tagName(st2) }) catch "");
        zjRecOff(&r, b);
    }
    // e4: 엄격 + 기록 → 바쁨 → 기록 끔(가벼운 enable) → 엄격 끔(bypass_off·disable) → kill.
    {
        const g1 = try sendBlock(&r, b, "127.0.0.1");
        const st1 = r.until(Run.strictSettled, b, g1, wait_ms);
        const on = zRecOn(&r, b, 306);
        const b0 = zjBody(&r, b, "zj3e4a");
        const busy = zBusy(&r, b, 6000);
        zjRecOff(&r, b);
        _ = try sendBlock(&r, b, "");
        r.pump(300);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        const b1 = zjBody(&r, b, "zj3e4b");
        const b2 = zjBody(&r, b, "zj3e4c");
        report(st1 and on and zIsBody(b0) and busy_now and death.killed >= 1 and death.died and zjNoBody(b1) and zjNoBody(b2) and r.strict[b] == .off, "ZJ-rec-strict-busy-recoff-strictoff-kill", std.fmt.bufPrint(&d, "strict on {} · record {} → {s} · {s} → record off, strict off · blocked {} · killed {d} gone {} · revive → {s} · next → {s} · strict {s} (want body, blocked, gone, then error ×2, off)", .{ st1, on, b0, busy, busy_now, death.killed, death.died, b1, b2, @tagName(r.strict[b]) }) catch "");
    }
    // e5: 켬 → 바쁨 → 끔 → kill → 죽은 동안 켬·끔 → 되살림.
    {
        const on = zRecOn(&r, b, 307);
        const b0 = zjBody(&r, b, "zj3e5a");
        const busy = zBusy(&r, b, 6000);
        zjRecOff(&r, b);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        zjRecOnNoWait(&r, b, 308);
        zjRecOff(&r, b);
        const b1 = zjBody(&r, b, "zj3e5b");
        const b2 = zjBody(&r, b, "zj3e5c");
        report(on and zIsBody(b0) and busy_now and death.killed >= 1 and death.died and zjNoBody(b1) and zjNoBody(b2), "ZJ-rec-busy-off-kill-dead-on-off", std.fmt.bufPrint(&d, "record {} → {s} · {s} → off · blocked {} · killed {d} gone {} · dead: on, off · revive → {s} · next → {s} (want body, blocked, gone, then error ×2)", .{ on, b0, busy, busy_now, death.killed, death.died, b1, b2 }) catch "");
    }
    // e6: 켬 → 바쁨 → 끔 → kill → 죽은 동안 켬 → 되살림 — 상태와 본문이 맞는가.
    {
        const on = zRecOn(&r, b, 309);
        const b0 = zjBody(&r, b, "zj3e6a");
        const busy = zBusy(&r, b, 6000);
        zjRecOff(&r, b);
        const busy_now = zjBusyNow(&r, b);
        const death = zjKill(&r, &host, &.{b});
        zjRecOnNoWait(&r, b, 310);
        r.pump(200);
        const b1 = zjBody(&r, b, "zj3e6b");
        const st1 = r.record_state[b];
        const b2 = zjBody(&r, b, "zj3e6c");
        const st2 = r.record_state[b];
        const leak = (zIsBody(b1) and st1 != .on) or (zIsBody(b2) and st2 != .on);
        report(on and zIsBody(b0) and busy_now and death.killed >= 1 and death.died and zjAnswered(b1) and zjAnswered(b2) and !leak, "ZJ-rec-busy-off-kill-dead-on-consistent", std.fmt.bufPrint(&d, "record {} → {s} · {s} → off · blocked {} · killed {d} gone {} · dead: on(s) · revive → {s} (state {s}) · next → {s} (state {s}) (want body, blocked, gone, then answered and no body while state is not on)", .{ on, b0, busy, busy_now, death.killed, death.died, b1, @tagName(st1), b2, @tagName(st2) }) catch "");
        zjRecOff(&r, b);
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// ZJ4: 새 문서의 다시 맞추기(`on_load_start` — `Renderer.committed`)가 사용자 이동마다 명령을 내는가·끝없이 도는가. 죽음(바쁜 채 기록 끔 + kill)과
/// 되살림 뒤 사용자 이동 12 번 — 표지 사이의 `block: cdp b=33` 줄을 판정 밖에서 센다(0 이어야 한다). 같은 이동의 시간을 죽음 없는 대조와 견준다.
fn zjNav(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_nav", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 33;
    try r.create(b, uLoop(&u, "/a9/top?zj4"));
    try r.watch(b);
    var times: [2]i64 = .{ 0, 0 };
    for ([_]bool{ false, true }, 0..) |crash, i| {
        if (crash) {
            _ = zRecOn(&r, b, 401);
            _ = zBusy(&r, b, 6000);
            zjRecOff(&r, b);
            _ = zKillRenderers(&host);
            r.pump(800);
            _ = zBody(&r, b, "zj4rev");
            r.pump(1500);
        }
        std.debug.print("ZJNAV-BEGIN {s} b={d}\n", .{ if (crash) "after-crash" else "control", b });
        const t0 = os.nowMs();
        var k: u32 = 0;
        while (k < 12) : (k += 1) {
            var pb: [64]u8 = undefined;
            const path = if (k % 2 == 0) std.fmt.bufPrint(&pb, "/a9/top?zj4n{d}x{d}", .{ i, k }) catch "/a9/top" else std.fmt.bufPrint(&pb, "/s/page?zj4n{d}x{d}", .{ i, k }) catch "/s/page";
            r.nav(b, uLoop(&u, path), true) catch {};
        }
        times[i] = os.nowMs() - t0;
        r.pump(500);
        std.debug.print("ZJNAV-END {s} b={d}\n", .{ if (crash) "after-crash" else "control", b });
    }
    report(true, "ZJ-nav-after-resync(obs)", std.fmt.bufPrint(&d, "12 user navigations: control {d} ms · after busy-kill-resync {d} ms (count `block: cdp b=33` lines between ZJNAV markers outside — want 0)", .{ times[0], times[1] }) catch "");
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// ZJ5: 같은 렌더러를 나누는 팝업(같은 사이트) — A 의 기록 끔(바쁜 채, 답 전에 죽음)과 P 의 켠 기록이 섞이지 않는가. 기대: A 는 본문 거절, P 는 본문·on,
/// P 를 끄면 본문 거절. A 가 끔을 보낸 뒤에도 바빴고 두 탭 모두에 죽음이 왔어야 한다.
fn zjPop(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_pop", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var o: [200]u8 = undefined;
    const a: u64 = 34;
    const p: u64 = 35;
    try r.create(a, uLoop(&u, "/a9/top?zj5"));
    try r.watch(a);
    try r.host.send(.{ .popup_reserve = .{ .browser = p } });
    try r.host.send(.{ .new_tab_credit = a });
    r.pump(100);
    _ = r.evAs(a, "(window.w=window.open('/a9/top?zj5pop','_blank','popup,width=300,height=300'),'opened')", &o, true);
    // 팝업이 서고 그 문서를 다 불러올 때까지(조건 — 앞 판의 고정 2500 ms 대신).
    const pdl = os.nowMs() + wait_ms;
    while (os.nowMs() < pdl and !(r.created[p] and r.loads[p] >= 1)) r.pump(50);
    const made = r.created[p];
    try r.watch(p);
    const n0 = zRendererCount(&host);
    const ona = zRecOn(&r, a, 501);
    const onp = zRecOn(&r, p, 502);
    const a0 = zjBody(&r, a, "zj5a0");
    const p0 = zjBody(&r, p, "zj5p0");
    // 팝업 문서가 A 와 같은 렌더러인가 — A 를 바쁘게 하면 P 의 평가도 미뤄진다.
    const busy = zBusy(&r, a, 6000);
    const pt0 = os.nowMs();
    const pp = r.call(p, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", 1500) catch null;
    const p_wait = os.nowMs() - pt0;
    zjRecOff(&r, a);
    const busy_now = zjBusyNow(&r, a);
    const death = zjKill(&r, &host, &.{ a, p });
    const a1 = zjBody(&r, a, "zj5a1");
    const p1 = zjBody(&r, p, "zj5p1");
    const pst = r.record_state[p];
    zjRecOff(&r, p);
    const p2 = zjBody(&r, p, "zj5p2");
    const a2 = zjBody(&r, a, "zj5a2");
    const pass = made and ona and onp and zIsBody(a0) and zIsBody(p0) and busy_now and death.killed >= 1 and death.died and zjNoBody(a1) and zjNoBody(a2) and zIsBody(p1) and pst == .on and zjNoBody(p2);
    report(pass, "ZJ-popup-shared-record", std.fmt.bufPrint(&d, "popup made {} · renderers {d} · record A {} P {} · A {s} P {s} · A {s} (P eval {s} in {d} ms) → A off · blocked {} · killed {d} gone {} · A → {s} · P → {s} (state {s}) · P off → {s} · A → {s} (want A error, P body+on, then P error; blocked, gone)", .{ made, n0, ona, onp, a0, p0, busy, if (pp) |x| @tagName(x) else "timeout", p_wait, busy_now, death.killed, death.died, a1, p1, @tagName(pst), p2, a2 }) catch "");
    try r.host.send(.{ .destroy_browser = p });
    try r.host.send(.{ .destroy_browser = a });
    r.pump(300);
}

/// ZJ6: 탭 닫기 뒤 늦은 답 — 바쁜 탭에 엄격 켬(답 미룸) → 그 탭을 닫고 같은 maru 번호로 새 탭 → 엄격 켬: 상태·우회가 맞는가(옛 탭의 짝이 붙지 않는다).
/// 켬을 보낸 뒤에도 바빴고(`zjBusyNow`) 옛 탭이 실제로 닫혔어야(`browser_closed`) 이 판이 재려는 「닫힌 탭의 늦은 답」 이 생긴다.
fn zjClose(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_close", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    const b: u64 = 36;
    try r.create(b, uLoop(&u, "/s/page?J6"));
    const c0 = swReady(&r, b);
    try r.watch(b);
    const busy = zBusy(&r, b, 4000);
    const t_busy = os.nowMs();
    _ = try sendBlock(&r, b, "127.0.0.1");
    r.pump(100);
    const busy_now = zjBusyNow(&r, b);
    const closed_before = r.closed[b];
    try r.host.send(.{ .destroy_browser = b });
    // 옛 탭이 닫힐 때까지(조건 — 앞 판의 고정 1500 ms 대신).
    const cdl = os.nowMs() + wait_ms;
    while (os.nowMs() < cdl and r.closed[b] == closed_before) r.pump(50);
    const closed = r.closed[b] > closed_before;
    r.created[b] = false;
    r.loads[b] = 0;
    try r.create(b, uLoop(&u, "/s/page?J6b"));
    const c1 = swReady(&r, b);
    try r.watch(b);
    r.failed_frames[b] = 0;
    const g = try sendBlock(&r, b, "127.0.0.1");
    const st = r.until(Run.strictSettled, b, g, wait_ms);
    const sta = r.strict[b];
    const ctl = reloadCtl(&r, b);
    const sub = a9sub(&r, b, "/s/zj6a");
    zjPumpPastBusy(&r, t_busy, 4000); // 옛 탭의 바쁨이 끝나고 늦은 답이 올 때까지(닫은 탭이라 평가로 물을 수 없다)
    const g2 = try sendBlock(&r, b, "");
    const st2 = r.until(Run.stateAt, b, g2, wait_ms);
    const ctl2 = reloadCtl(&r, b);
    const sub2 = a9sub(&r, b, "/s/zj6b");
    report(zjEq(c0, "controlled") and zjEq(busy, "busy") and busy_now and closed and zjEq(c1, "controlled") and st and sta == .on and r.failed_frames[b] == 0 and zjEq(ctl, "bypassed") and zjEq(sub, "net") and st2 and r.strict[b] == .off and zjEq(ctl2, "controlled") and zjEq(sub2, "sw"), "ZJ-close-reuse-id", std.fmt.bufPrint(&d, "start {s} · {s} → strict on (blocked {}) → close {} · same id again {s} · strict on {} {s} failed {d} · reload {s} sub {s} · off {} · reload {s} sub {s} (want blocked, closed, on bypassed/net, then controlled/sw)", .{ c0, busy, busy_now, closed, c1, st, @tagName(sta), r.failed_frames[b], ctl, sub, st2, ctl2, sub2 }) catch "");
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}

/// ZJ7: 죽음이 아닌 렌더러 바꾸기 — (x1) 바쁜 채 기록 끔(답 미룸) → 곧 다른 사이트로 사용자 이동(새 렌더러): 새 문서·돌아온 문서·다음 문서 모두 본문 거절.
/// 끔을 보낸 뒤에도 옛 렌더러가 바빴어야 한다(`zjBusyNow`). (x2) 기록 켬 → 다른 사이트로 이동(옛 문서는 bfcache 로) → 끔 → 뒤로(되살린 옛 문서): 본문
/// 거절. 11 차 실측: 뒤로가 bfcache 로 되살지 않았다(표지 `undefined` — 보고 줄에 적는다) — 단언은 「끈 뒤 돌아온 문서의 본문 거절」 이고 bfcache 갈래
/// 자체는 재지 못한다. 읽는 문서마다 주소의 표지로 그 문서가 섰는가를 본다(`zjRead`).
fn zjXnav(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var host = try spawn(host_path, root, "zj_xnav", &.{"MARU_WEB_TEST_BLOCK_LOG=1"});
    defer stop(&host);
    var r: Run = .{ .host = &host, .gpa = std.heap.c_allocator };
    var u: [512]u8 = undefined;
    var d: [1600]u8 = undefined;
    var o: [200]u8 = undefined;
    const b: u64 = 37;
    try r.create(b, uLoop(&u, "/a9/top?zj7"));
    try r.watch(b);
    {
        const on = zRecOn(&r, b, 701);
        const b0 = zjBody(&r, b, "zj7x1a");
        const busy = zBusy(&r, b, 6000);
        const t_busy = os.nowMs();
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        r.pump(50);
        const busy_now = zjBusyNow(&r, b);
        r.nav(b, uLocal(&u, "/a9/top?zj7x1b"), true) catch {};
        const b1 = zjRead(&r, b, "zj7x1b");
        zjPumpPastBusy(&r, t_busy, 6000); // 옛 렌더러(다른 사이트 — 평가로 물을 수 없다)의 바쁨이 끝나고 늦은 답이 온 뒤
        const b1b = zjRead(&r, b, "zj7x1b");
        r.action(b, .back, true) catch {};
        const back_mark = r.ev(b, "location.search", &o);
        var bm: [64]u8 = undefined;
        const bmark = bm[0..@min(bm.len, back_mark.len)];
        @memcpy(bmark, back_mark[0..bmark.len]);
        const b2 = zjRead(&r, b, "zj7x1a");
        const b3 = zjBody(&r, b, "zj7x1c");
        report(on and zIsBody(b0) and busy_now and zjNoBody(b1) and zjNoBody(b1b) and zjNoBody(b2) and zjNoBody(b3), "ZJ-xnav-busy-off-crosssite", std.fmt.bufPrint(&d, "record {} → {s} · {s} → off (blocked {}) → user nav localhost → {s} · after busy → {s} · back ({s}) → {s} · next → {s} (want body, blocked, then error ×4)", .{ on, b0, busy, busy_now, b1, b1b, bmark, b2, b3 }) catch "");
    }
    {
        const on = zRecOn(&r, b, 702);
        const b0 = zjBody(&r, b, "zj7x2a");
        _ = r.ev(b, "(window.zjmark='kept','m')", &o);
        r.nav(b, uLocal(&u, "/a9/top?zj7x2b"), true) catch {};
        const b1 = zjRead(&r, b, "zj7x2b");
        try r.host.send(.{ .net_record = .{ .browser = b, .on = false } });
        // 끈 상태가 올 때까지(조건 — 앞 판의 고정 500 ms 대신).
        const odl = os.nowMs() + wait_ms;
        while (os.nowMs() < odl and r.record_state[b] != .off) r.pump(50);
        const b1b = zjRead(&r, b, "zj7x2b");
        r.action(b, .back, true) catch {};
        const m = r.ev(b, "String(window.zjmark)", &o);
        var mb: [32]u8 = undefined;
        const mark = mb[0..@min(mb.len, m.len)];
        @memcpy(mark, m[0..mark.len]);
        const b2 = zjRead(&r, b, "zj7x2a");
        r.pump(500); // 「조금 뒤에 다시 읽어도」 — 늦게 닿는 다시 맞추기를 보는 창이라 시간 자체가 재는 것이다
        const b2b = zjRead(&r, b, "zj7x2a");
        report(on and zIsBody(b0) and zIsBody(b1) and zjNoBody(b1b) and zjNoBody(b2) and zjNoBody(b2b), "ZJ-xnav-bfcache-off-back", std.fmt.bufPrint(&d, "record {} → {s} · user nav localhost → {s} · off → {s} · back (bfcache mark {s}) → {s} · again → {s} (want body ×2, then error ×3)", .{ on, b0, b1, b1b, mark, b2, b2b }) catch "");
    }
    try r.host.send(.{ .destroy_browser = b });
    r.pump(300);
}
