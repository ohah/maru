//! W9e② 적대 검증 v20a(1–10 회차) 탐침 — 판정용이다(제품 코드 아님). `maru-web-judge --w9e2a <dist> <프로필>`, 환경 `W9E2A_ONLY=이름,…` 이면
//! 그 탐침만. 판정자가 maru 역할로 trace·흉내·사람 입력을 보내고, 받은 trace 는 maru 의 거르기(`maru-web-trace-filter`)로 걸러 원본·남긴 것을
//! 프로필 폴더에 남긴다(파이썬으로 따로 읽는다). PASS = 문서가 약속한 동작, FAIL = 반례 후보.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const emu = @import("emulation_check.zig");
const perf = @import("perf_check.zig");
const select = @import("probe_select.zig");
const self_origin = @import("control_self_origin");

const msg = protocol.message;
const Run = emu.Run;
const Session = emu.Session;
const Report = emu.Report;
const contains = emu.contains;

// ── 페이지(no-store 없이 — bfcache 가 되게) ──────────────────────────────────────────────────────────────────

const common_js =
    \\window.__frames=0;(function t(){window.__frames++;requestAnimationFrame(t)})();
    \\window.bench=function(n){n=n||3e7;var s=performance.now(),x=0;for(var i=0;i<n;i++){x=(x+i*7)%1000003}window.__x=x;return Math.round(performance.now()-s)};
    \\window.ft=async function(u){var s=performance.now();try{var r=await fetch(u,{cache:'no-store'});await r.text();return 'ok '+Math.round(performance.now()-s)}catch(e){return 'err '+Math.round(performance.now()-s)}};
    \\window.ST=function(){return JSON.stringify({vis:document.visibilityState,frames:__frames,online:navigator.onLine,focus:document.hasFocus()})};
    \\window.NI=function(){var c=navigator.connection||{};return JSON.stringify({on:navigator.onLine,rtt:c.rtt,dl:c.downlink,et:c.effectiveType})};
    \\addEventListener('pageshow',function(e){window.__ps=String(e.persisted)});
    \\window.ASK=function(f,m){return new Promise(function(r){var el=document.getElementById(f);if(!el)return r('nof');var ch=new MessageChannel();ch.port1.onmessage=function(e){r(e.data)};el.contentWindow.postMessage(m,'*',[ch.port2]);setTimeout(function(){r('timeout')},20000)})};
;

/// 어느 iframe 이든 — 메시지로 묻는 것(bench·connection·fetch).
const kid_js =
    \\addEventListener('message',function(e){var p=e.ports[0];if(!p)return;if(e.data==='ni'){var c=navigator.connection||{};p.postMessage(JSON.stringify({on:navigator.onLine,rtt:c.rtt,dl:c.downlink,et:c.effectiveType}));return}
    \\if(e.data==='ft'){var s=performance.now();fetch('/x?kid'+Math.random(),{cache:'no-store'}).then(function(r){return r.text()}).then(function(){p.postMessage('ok '+Math.round(performance.now()-s))},function(){p.postMessage('err '+Math.round(performance.now()-s))});return}
    \\var s=performance.now(),x=0;for(var i=0;i<3e7;i++){x=(x+i*7)%1000003}p.postMessage(JSON.stringify({ms:Math.round(performance.now()-s),u:location.href.slice(0,30)}))});
;

const static_html = "<!doctype html><title>PA-STATIC</title><body style='margin:0;background:#00c000'><input id=i autofocus style='width:300px;height:40px'><div style='height:3000px'>agent</div><script>" ++ common_js ++ "</script>";
const user_anim_html = "<!doctype html><title>USER-ANIM</title><body style='margin:0;background:#ff0000'><script>var c=0;setInterval(function(){c^=1;document.body.style.background=c?'#0000ff':'#ff0000'},100)</script>";
const ifq_html = "<!doctype html><title>IFQ</title><body style='margin:0;background:#ffffff;height:100%'><p>quiet</p>";
const pop_html = "<!doctype html><title>PA-POP</title><body style='margin:0;background:#00c000'><button id=o onclick='OP()' style='position:fixed;left:0;top:0;width:300px;height:200px'>open</button><script>" ++ common_js ++ "window.OP=function(){window.pp=window.open('/pa-static?pop','p1');return 'ok'};</script>";
const prer_html = "<!doctype html><title>PA-PRER</title><body style='margin:0;background:#00c000'><script>" ++ common_js ++
    \\window.PR=function(){var s=document.createElement('script');s.type='speculationrules';s.textContent=JSON.stringify({prerender:[{source:'list',urls:['/pa-busy?prer']}]});document.head.appendChild(s);return String(HTMLScriptElement.supports&&HTMLScriptElement.supports('speculationrules'))};
++ "</script>";
const busy_html = "<!doctype html><title>BUSY</title><body><script>setInterval(function(){var d=document.createElement('div');d.textContent='PRERENDERBUSY'+Math.random();document.body.appendChild(d);if(document.body.childNodes.length>100)document.body.removeChild(document.body.firstChild)},30)</script>";
const bf1_html = "<!doctype html><title>PA-BF1</title><body style='margin:0;background:#00c000'><iframe src='/pa-busy?inner' width=200 height=100></iframe><script>" ++ common_js ++ "</script>";
const plain_html = "<!doctype html><title>PLAIN</title><body>plain<script>addEventListener('pageshow',function(e){window.__ps=String(e.persisted)})</script>";
const kid_html = "<!doctype html><title>KID</title><body style='margin:0;background:#ffff00'>kid<script>" ++ kid_js ++ "</script>";
const flood_html = "<!doctype html><title>FLOOD</title><body style='margin:0;background:#00c000'><script>" ++ common_js ++
    \\var n=0,pad='x'.repeat(300);function f(){for(var i=0;i<300;i++){performance.mark('m'+(n++)+pad)}performance.clearMarks();var d=document.createElement('div');d.textContent=n;document.body.appendChild(d);if(document.body.childNodes.length>300)document.body.removeChild(document.body.firstChild);setTimeout(f,1)}f();
++ "</script>";

var prer_hits = std.atomic.Value(u32).init(0);

fn replyRaw(conn: c_int, body: []const u8) void {
    var hb: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `emulation_check.serveParsed` 가 먼저 부른다 — `/pa-*` 만 맡는다.
pub fn serve(conn: c_int, path: []const u8, target: []const u8, host: []const u8) bool {
    _ = host;
    if (!std.mem.startsWith(u8, path, "/pa-")) return false;
    const port = emu.port;
    var bb: [16384]u8 = undefined;
    if (eql(path, "/pa-static")) return reply(conn, static_html);
    if (eql(path, "/pa-user-anim")) return reply(conn, user_anim_html);
    if (eql(path, "/pa-ifq")) return reply(conn, ifq_html);
    if (eql(path, "/pa-pop")) return reply(conn, pop_html);
    if (eql(path, "/pa-prer")) return reply(conn, prer_html);
    if (eql(path, "/pa-busy")) {
        if (std.mem.indexOf(u8, target, "prer") != null) _ = prer_hits.fetchAdd(1, .monotonic);
        return reply(conn, busy_html);
    }
    if (eql(path, "/pa-bf1")) return reply(conn, bf1_html);
    if (eql(path, "/pa-plain")) return reply(conn, plain_html);
    if (eql(path, "/pa-kid")) return reply(conn, kid_html);
    if (eql(path, "/pa-flood")) return reply(conn, flood_html);
    if (eql(path, "/pa-user-quiet")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>USER-QUIET</title><body style='margin:0;background:#eeeeee'><iframe id=f src='http://127.0.0.1:{d}/pa-ifq' style='position:absolute;left:0;top:0;width:400px;height:300px;border:0'></iframe>", .{port}) catch return false);
    // 사용자 탭(localhost) — 127.0.0.1 kid iframe(같은 사이트 — 에이전트 렌더러에 든다).
    if (eql(path, "/pa-uk")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>USER-KID</title><body style='margin:0'><iframe id=f src='http://127.0.0.1:{d}/pa-kid' width=300 height=200></iframe><script>{s}</script>", .{ port, common_js }) catch return false);
    // 사용자 탭 — 127.0.0.1 iframe 이 blob 주소를 만들어 주면 그 blob 으로 iframe 을 만들고 원래 iframe 을 지운다.
    if (eql(path, "/pa-blobhost")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>BLOBHOST</title><body style='margin:0'><script>{s}" ++
        \\window.__state='init';addEventListener('message',function(e){{if(e.data&&e.data.blob){{var b=document.createElement('iframe');b.id='b';b.style='width:300px;height:200px';b.onload=function(){{var a=document.getElementById('a');if(a)a.remove();window.__state='ready '+document.querySelectorAll('iframe').length}};b.src=e.data.blob;document.body.appendChild(b)}}}});
        \\var a=document.createElement('iframe');a.id='a';a.src=(location.search.indexOf('other')>=0?'http://localhost:':'http://127.0.0.1:')+{d}+'/pa-blobsrc'+location.search;document.body.appendChild(a);
    ++ "</script>", .{ common_js, port }) catch return false);
    if (eql(path, "/pa-uw")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>USER-W</title><body style='margin:0'><iframe id=f src='http://127.0.0.1:{d}/pa-wk' width=300 height=200></iframe>", .{port}) catch return false);
    if (eql(path, "/pa-wk")) return reply(conn, "<!doctype html><title>WK</title><body>wk<script>var w=new Worker('/pa-wjs');</script>");
    if (eql(path, "/pa-wjs")) {
        const js = "var n=0;setInterval(function(){fetch('/x?wtoken=WORKERSECRET'+(n++),{cache:'no-store'}).then(function(r){return r.text()})},100);";
        var hb: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{js.len}) catch return false;
        _ = std.c.write(conn, head.ptr, head.len);
        _ = std.c.write(conn, js.ptr, js.len);
        return true;
    }
    if (eql(path, "/pa-user-scroll")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>USER-SCROLL</title><body style='margin:0;background:#eeeeee'><iframe id=f src='http://127.0.0.1:{d}/pa-ifs' style='position:absolute;left:0;top:0;width:400px;height:300px;border:0'></iframe>", .{port}) catch return false);
    if (eql(path, "/pa-ifs")) return reply(conn, "<!doctype html><title>IFS</title><body style='margin:0;background:linear-gradient(#fff,#00f);height:6000px'><p>scroll me</p>");
    if (eql(path, "/pa-user-anim2")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>USER-ANIM2</title><body style='margin:0'><iframe id=f src='http://127.0.0.1:{d}/pa-ifa' style='position:absolute;left:0;top:0;width:400px;height:300px;border:0'></iframe>", .{port}) catch return false);
    if (eql(path, "/pa-ifa")) return reply(conn, "<!doctype html><title>IFA</title><style>@keyframes s{from{transform:translateX(0)}to{transform:translateX(200px)}}#b{width:80px;height:80px;background:#f0f;animation:s 0.5s linear infinite alternate;will-change:transform}</style><body style='margin:0'><div id=b></div>");
    if (eql(path, "/pa-noise")) return reply(conn, "<!doctype html><title>NOISE</title><body style='margin:0'><canvas id=c width=1280 height=800 style='width:640px;height:400px'></canvas><script>var c=document.getElementById('c').getContext('2d');var im=c.createImageData(1280,800);function f(){var d=im.data;for(var i=0;i<d.length;i+=4){var v=(Math.random()*255)|0;d[i]=v;d[i+1]=(v*7)&255;d[i+2]=(v*13)&255;d[i+3]=255}c.putImageData(im,0,0);requestAnimationFrame(f)}f();</script>");
    if (eql(path, "/pa-churn")) return reply(conn, "<!doctype html><title>CHURN</title><body style='margin:0;background:#00c000'><script>var n=0;setInterval(function(){var f=document.createElement('iframe');f.src='/pa-ifq?c='+(n++);f.width=60;f.height=40;document.body.appendChild(f);var all=document.querySelectorAll('iframe');if(all.length>4)all[0].remove()},40);</script>");
    if (eql(path, "/pa-blobsrc")) {
        if (std.mem.indexOf(u8, target, "mode=data") != null) return reply(conn, "<!doctype html><title>DATASRC</title><script>var html=\"<!doctype html><title>DATAKID</title><body>datakid<script>" ++ kid_js_escaped ++ "<\\/script>\";location.href='data:text/html,'+encodeURIComponent(html);</script>");
        if (std.mem.indexOf(u8, target, "mode=blank") != null) return reply(conn, "<!doctype html><title>BLANKSRC</title><script>var w=window;var f=function(){};location.href='about:blank';</script>");
        return reply(conn, "<!doctype html><title>BLOBSRC</title><script>var html=\"<!doctype html><title>BLOBKID</title><body>blobkid<script>" ++ kid_js_escaped ++ "<\\/script>\";var u=URL.createObjectURL(new Blob([html],{type:'text/html'}));location.href=u;</script>");
    }
    return false;
}

/// blob 문서 안에 넣을 kid_js(JS 글자 안이라 `"` 를 쓰지 않는다 — kid_js 에는 `"` 가 없다).
const kid_js_escaped = kid_js_noline;
const kid_js_noline = blk: {
    var out: [kid_js.len]u8 = undefined;
    for (kid_js, 0..) |ch, i| out[i] = if (ch == '\n') ' ' else ch;
    const final = out;
    break :blk &final;
};

fn reply(conn: c_int, body: []const u8) bool {
    replyRaw(conn, body);
    return true;
}

// ── 공통 ─────────────────────────────────────────────────────────────────────────────────────────────────

var root_dir: []const u8 = "";
var dbuf: [3000]u8 = undefined;

fn only(name: []const u8) bool {
    return select.selected("W9E2A_ONLY", name);
}

fn sleep(ms: u32) void {
    os.sleepMs(ms);
}

/// 원본·프레임·남긴 것을 남긴다(`<root>/<name>.raw.gz` 등).
fn save(r: *const Run, name: []const u8, kept: []const u8) void {
    var pb: [1200]u8 = undefined;
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/{s}.raw.gz", .{ root_dir, name }, 0) catch return, r.tr_gz.items) catch {};
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kept.gz", .{ root_dir, name }, 0) catch return, kept) catch {};
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(std.heap.c_allocator);
    for (r.tr_frames.items, r.tr_frame_lens.items) |*b, n| {
        ids.appendSlice(std.heap.c_allocator, b[0..n]) catch {};
        ids.append(std.heap.c_allocator, '\n') catch {};
    }
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/{s}.frames.txt", .{ root_dir, name }, 0) catch return, ids.items) catch {};
}

fn stName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.state) else "-";
}
fn rsName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.reason) else "-";
}

const Done = struct { st: ?msg.TraceState, outcome: []const u8, kept: u64, shots: u64, foreign: []const u8, frames: u64 = 0 };

var outcome_buf: [64]u8 = undefined;
var foreign_buf: [128]u8 = undefined;

fn finishAndFilter(r: *Run, gen: u32, wait: u32, name: []const u8) !Done {
    const st = perf.waitFinished(r, gen, wait);
    if (st == null or st.?.state != .done) {
        save(r, name, "");
        return .{ .st = st, .outcome = "not-done", .kept = 0, .shots = 0, .foreign = "-" };
    }
    var res = try perf.filterNow(r, std.heap.c_allocator);
    defer res.deinit(std.heap.c_allocator);
    save(r, name, res.gz);
    const o = std.fmt.bufPrint(&outcome_buf, "{s}", .{res.outcome}) catch "?";
    const f = std.fmt.bufPrint(&foreign_buf, "{s}", .{res.foreign[0..@min(res.foreign.len, 100)]}) catch "?";
    return .{ .st = st, .outcome = o, .kept = res.kept, .shots = res.screenshots, .foreign = f, .frames = res.frames };
}

fn start(r: *Run, b: u64, ms: u32, shots: bool) !u32 {
    const gen = try perf.startTrace(r, b, ms, shots);
    _ = r.until(perf.recordingAt, gen, 0, 8000);
    return gen;
}

fn key(r: *Run, b: u64, native: u8, ch: u16) void {
    const k: msg.Key = .{ .browser = b, .kind = .raw_down, .native_key_code = native, .character = ch, .unmodified_character = ch };
    r.host.send(.{ .key = k }) catch {};
    var c = k;
    c.kind = .char;
    r.host.send(.{ .key = c }) catch {};
    var up = k;
    up.kind = .up;
    r.host.send(.{ .key = up }) catch {};
    r.pump(120);
}

// ── 1 회차: 거르기 — 다른 탭 화면(스크린샷), 같은 프로세스 사용자 iframe 의 프레임 칸 없는 이벤트 ───────────────────────────

fn r1Screens(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1s");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-user-anim"));
    r.pump(800);
    const g = try start(r, 1, 2500, true);
    const a = try finishAndFilter(r, g, 40_000, "a1s_with_user");
    var oa: [32]u8 = undefined;
    const oa_s = std.fmt.bufPrint(&oa, "{s}", .{a.outcome}) catch "?";
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(1200);
    const g2 = try start(r, 1, 2500, true);
    const b = try finishAndFilter(r, g2, 40_000, "a1s_alone");
    report(true, "a1-screens(obs)", std.fmt.bufPrint(&dbuf, "보이는 사용자 탭과 함께: {s}/{s} 거르기 {s} 남김 {d} 스크린샷 {d} | 사용자 탭 없이: {s} 남김 {d} 스크린샷 {d} (색은 a1_screens.py 가 판정)", .{ stName(a.st), rsName(a.st), oa_s, a.kept, a.shots, b.outcome, b.kept, b.shots }) catch "");
}

fn r1Frameless(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1f");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-user-quiet"));
    r.pump(1500);
    // 대조: 입력 없이.
    const g0 = try start(r, 1, 2500, false);
    const c = try finishAndFilter(r, g0, 40_000, "a1f_control");
    var oc: [32]u8 = undefined;
    const oc_s = std.fmt.bufPrint(&oc, "{s}", .{c.outcome}) catch "?";
    // 사람이 사용자 탭의 같은 사이트(에이전트 프로세스) iframe 을 누르고 친다·움직인다·굴린다.
    try r.host.send(.{ .set_focus = .{ .browser = 2, .value = true } });
    const g = try start(r, 1, 4000, false);
    r.pump(300);
    r.userClick(2, 100, 100);
    key(r, 2, 0, 'a');
    key(r, 2, 11, 'b');
    key(r, 2, 8, 'c');
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        r.host.send(.{ .mouse = .{ .browser = 2, .kind = .move, .point = .{ .x = 50 + i * 20, .y = 120 } } }) catch {};
        r.pump(30);
    }
    r.host.send(.{ .wheel = .{ .browser = 2, .point = .{ .x = 100, .y = 100 }, .delta_x = 0, .delta_y = -120 } }) catch {};
    const d = try finishAndFilter(r, g, 40_000, "a1f_input");
    report(true, "a1-frameless(obs)", std.fmt.bufPrint(&dbuf, "대조(입력 없음) {s} 남김 {d} | 사람 입력(사용자 탭의 같은 사이트 iframe) {s}/{s} 거르기 {s} 남김 {d} 남의 프레임 {s} (EventDispatch 는 a1_frameless.py 가 센다)", .{ oc_s, c.kept, stName(d.st), rsName(d.st), d.outcome, d.kept, d.foreign }) catch "");
}

/// 포인터가 trace 앞에 이미 사용자 iframe 안에 있다 — 기록 중에는 옮김·굴림만(Event Timing 이 재지 않는 종류 — 프레임 칸 있는 이벤트가 없을 수 있다).
fn r1MoveOnly(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1m");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-user-quiet"));
    r.pump(1500);
    r.host.send(.{ .mouse = .{ .browser = 2, .kind = .move, .point = .{ .x = 30, .y = 30 } } }) catch {};
    r.pump(800);
    const g = try start(r, 1, 3000, false);
    r.pump(300);
    var i: i32 = 0;
    while (i < 40) : (i += 1) {
        r.host.send(.{ .mouse = .{ .browser = 2, .kind = .move, .point = .{ .x = 30 + @mod(i * 9, 300), .y = 40 + @mod(i * 5, 200) } } }) catch {};
        r.pump(25);
    }
    var j: i32 = 0;
    while (j < 3) : (j += 1) {
        r.host.send(.{ .wheel = .{ .browser = 2, .point = .{ .x = 100, .y = 100 }, .delta_x = 0, .delta_y = -120 } }) catch {};
        r.pump(60);
    }
    const d = try finishAndFilter(r, g, 40_000, "a1m_move");
    report(!eql(d.outcome, "kept"), "a1-frameless-move-only", std.fmt.bufPrint(&dbuf, "포인터가 이미 사용자 탭의 같은 사이트 iframe 안 — 기록 중 옮김 40·굴림 3 → {s}/{s} 거르기 {s} 남김 {d} 남의 프레임 {s} (남긴 것의 EventDispatch 는 py 로)", .{ stName(d.st), rsName(d.st), d.outcome, d.kept, d.foreign }) catch "");
}

/// 사용자 탭의 같은 사이트 iframe 이 trace 앞에 띄운 dedicated worker 가 기록 중에 비밀 주소를 가져온다(iframe 자신은 조용하다).
fn r1Worker(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1w");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-uw"));
    r.pump(2000);
    const g = try start(r, 1, 3000, false);
    const d = try finishAndFilter(r, g, 40_000, "a1w_worker");
    var pb: [1200]u8 = undefined;
    const kept = perf.readAll(std.heap.c_allocator, std.fmt.bufPrintSentinel(&pb, "{s}/a1w_worker.kept.gz", .{root_dir}, 0) catch "") catch &.{};
    const leaked = kept.len > 0 and gunzipHas(kept, "WORKERSECRET");
    const raw_has = gunzipHas(r.tr_gz.items, "WORKERSECRET");
    report(!leaked, "a1-user-worker", std.fmt.bufPrint(&dbuf, "사용자 iframe 의 worker(trace 앞에 시작) → {s}/{s} 거르기 {s} 남김 {d} 남의 프레임 {s}, 비밀 주소: 원본 {} 남긴 것 {}", .{ stName(d.st), rsName(d.st), d.outcome, d.kept, d.foreign, raw_has, leaked }) catch "");
}

fn gunzipHas(gz: []const u8, needle: []const u8) bool {
    var in: std.Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dd: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer out.deinit();
    _ = dd.reader.streamRemaining(&out.writer) catch return false;
    return std.mem.indexOf(u8, out.written(), needle) != null;
}

/// 사람이 사용자 탭의 같은 사이트 iframe 을 굴린다(스크립트 없는 긴 문서 — 컴포지터가 굴린다), 따로 컴포지터 애니메이션만 도는 사용자 iframe.
fn r1Scroll(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [256]u8 = undefined;
    var oa: [32]u8 = undefined;
    var oa_s: []const u8 = "?";
    var ka: u64 = 0;
    {
        var sess: Session = undefined;
        try emu.open(&sess, host_path, root, "pa1c");
        defer sess.deinit();
        const r = &sess.run;
        try r.create(1, emu.uLoop(&u, "/pa-static"));
        try r.create(2, emu.uLocal(&u, "/pa-user-scroll"));
        r.pump(1500);
        r.host.send(.{ .mouse = .{ .browser = 2, .kind = .move, .point = .{ .x = 100, .y = 100 } } }) catch {};
        r.pump(800);
        const g = try start(r, 1, 3000, false);
        r.pump(300);
        var j: i32 = 0;
        while (j < 12) : (j += 1) {
            r.host.send(.{ .wheel = .{ .browser = 2, .point = .{ .x = 100, .y = 100 }, .delta_x = 0, .delta_y = -60 } }) catch {};
            r.pump(80);
        }
        const d = try finishAndFilter(r, g, 40_000, "a1c_scroll");
        oa_s = std.fmt.bufPrint(&oa, "{s}", .{d.outcome}) catch "?";
        ka = d.kept;
    }
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1n");
    defer sess.deinit();
    const r = &sess.run;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-user-anim2"));
    r.pump(1500);
    const g = try start(r, 1, 2500, true);
    const d = try finishAndFilter(r, g, 40_000, "a1n_anim");
    // A1-1: 컴포지터만 쓰는 사용자 iframe 의 layer tree 는 가족에 묶이지 않는다 — 통째로 버린다(남기면 그 iframe 의 박자가 결과에 남는다).
    report(!eql(oa_s, "kept") and eql(d.outcome, "mixed_content"), "a1-user-scroll", std.fmt.bufPrint(&dbuf, "사람이 사용자 탭의 같은 사이트 iframe 을 굴림 12 → 거르기 {s} 남김 {d} | 컴포지터 애니메이션만 도는 사용자 iframe → {s} 남김 {d} frames_presented {d} 남의 프레임 {s}", .{ oa_s, ka, d.outcome, d.kept, d.frames, d.foreign }) catch "");
}

/// 에이전트 탭 자신이 컴포지터 애니메이션만(스크립트 없음 — 주 스레드가 일하지 않아 `SetLayerTreeId` 가 나오지 않을 수 있다) — 제 프레임을 남의
/// 것으로 보고 버리면 안 된다(A1-1 고침의 헛폐기 대조).
fn r1SelfAnim(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa1a");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-ifa"));
    r.pump(1500);
    const g = try start(r, 1, 2500, true);
    const d = try finishAndFilter(r, g, 40_000, "a1a_selfanim");
    report(eql(d.outcome, "kept") and d.frames > 0, "a1-self-compositor-anim", std.fmt.bufPrint(&dbuf, "에이전트 탭 자신의 컴포지터 애니메이션만 → {s}/{s} 거르기 {s} 남김 {d} frames_presented {d} 스크린샷 {d} 남의 프레임 {s}", .{ stName(d.st), rsName(d.st), d.outcome, d.kept, d.frames, d.shots, d.foreign }) catch "");
}

// ── 2 회차: 헛폐기 — 기록 중 연 팝업·prerender·bfcache ─────────────────────────────────────────────────────

fn r2Popup(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa2p");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-pop"));
    r.pump(500);
    try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
    r.pump(200);
    const g = try start(r, 1, 3000, false);
    r.pump(300);
    _ = &o;
    const op = "cdp-click";
    try r.host.send(.{ .new_tab_credit = 1 }); // maru 가 에이전트 탭에 주는 새 탭 장
    r.cdpClick(1, 100, 100); // 에이전트의 누름(DevTools 입력 — 사람 입력이 아니다)
    _ = r.until(Run.loadsAt, 4, 1, 8000);
    const a = try finishAndFilter(r, g, 40_000, "a2p_during");
    var oa: [32]u8 = undefined;
    const oa_s = std.fmt.bufPrint(&oa, "{s}", .{a.outcome}) catch "?";
    // 대조: 팝업이 trace 앞에 있었다(가족).
    const g2 = try start(r, 1, 2500, false);
    const b = try finishAndFilter(r, g2, 40_000, "a2p_before");
    const ok = eql(oa_s, "kept");
    report(ok, "a2-popup-during-trace", std.fmt.bufPrint(&dbuf, "기록 중 같은 사이트 팝업(OP {s}, 만들어짐 {}) → {s}/{s} 거르기 {s} 남의 프레임 {s} | 대조(팝업이 먼저 — 가족) {s} 남김 {d}", .{ op, r.created[4], stName(a.st), rsName(a.st), oa_s, a.foreign, b.outcome, b.kept }) catch "");
}

fn r2Prerender(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa2r");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-prer"));
    r.pump(500);
    const g0 = try start(r, 1, 2000, false);
    const c = try finishAndFilter(r, g0, 40_000, "a2r_control");
    var oc: [32]u8 = undefined;
    const oc_s = std.fmt.bufPrint(&oc, "{s}", .{c.outcome}) catch "?";
    const g = try start(r, 1, 3500, false);
    r.pump(300);
    const sup = r.ev(1, "PR()", &o);
    const a = try finishAndFilter(r, g, 40_000, "a2r_during");
    var oa: [32]u8 = undefined;
    const oa_s = std.fmt.bufPrint(&oa, "{s}", .{a.outcome}) catch "?";
    // 이미 prerender 된 채로 다시(사람이 흔히 겪는 꼴 — 검색 결과 페이지가 첫 결과를 미리 그린다).
    const g2 = try start(r, 1, 2500, false);
    const b = try finishAndFilter(r, g2, 40_000, "a2r_after");
    const hits = prer_hits.load(.monotonic);
    report(eql(oc_s, "kept") and eql(oa_s, "kept") and eql(b.outcome, "kept"), "a2-prerender", std.fmt.bufPrint(&dbuf, "대조 {s} 남김 {d} | 기록 중 speculationrules prerender(지원 {s}, 서버 요청 {d}) → {s} 남의 프레임 {s} | prerender 가 남은 채 다음 trace → {s} 남의 프레임 {s}", .{ oc_s, c.kept, sup, hits, oa_s, a.foreign, b.outcome, b.foreign }) catch "");
}

fn r2Bfcache(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa2b");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-bf1"));
    r.pump(800);
    try r.nav(1, emu.uLoop(&u, "/pa-static?b2"));
    r.pump(500);
    const g = try start(r, 1, 3500, false);
    r.pump(300);
    const before = r.loads[1];
    _ = r.ev(1, "setTimeout(function(){history.back()},50),'ok'", &o);
    _ = r.until(Run.loadsAt, 1, before + 1, 6000);
    r.pump(400);
    const ps = r.ev(1, "String(window.__ps)+' '+location.pathname", &o);
    var psb: [64]u8 = undefined;
    const ps_s = std.fmt.bufPrint(&psb, "{s}", .{ps}) catch "?";
    const a = try finishAndFilter(r, g, 40_000, "a2b_back");
    // 기대는 bfcache 와 무관하게 남김이다: main 은 bfcache 를 꺼 뒤로가 새로 불러온 문서(persisted false — 그 탭 혼자라 남김; 앞 문서의 늦은 layer
    // tree 보고는 거르기가 기록 시작 앞 시각으로 뺀다 — W9e② 20 회 검증 v2), 켜져 있으면 되살림(A2-2 — 프레임 트리를 다시 받아 남김).
    report(eql(a.outcome, "kept"), "a2-bfcache-back", std.fmt.bufPrint(&dbuf, "기록 중 에이전트 탭의 뒤로(bfcache 꺼짐이면 새로 불러옴·켜짐이면 되살림 — persisted {s}) → {s}/{s} 거르기 {s} 남김 {d} 남의 프레임 {s}", .{ ps_s, stName(a.st), rsName(a.st), a.outcome, a.kept, a.foreign }) catch "");
}

/// 프레임 집합의 경주 — 에이전트 페이지가 40 ms 마다 같은 사이트 iframe 을 만들고 지운다(광고 돌리기 꼴). 멈춤 직전에 붙은 프레임의 `frameAttached` 가
/// 멈춘 뒤에 오면 집합에 들지 않는다.
fn r2Churn(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa2c");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-churn"));
    r.pump(800);
    var mixed: usize = 0;
    var kept: usize = 0;
    var other: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const g = try start(r, 1, 1500, false);
        var nb: [32]u8 = undefined;
        const d = try finishAndFilter(r, g, 40_000, std.fmt.bufPrint(&nb, "a2c_{d}", .{i}) catch "a2c");
        if (eql(d.outcome, "mixed_content")) mixed += 1 else if (eql(d.outcome, "kept")) kept += 1 else other += 1;
        r.pump(300);
    }
    report(mixed == 0, "a2-frame-churn", std.fmt.bufPrint(&dbuf, "40 ms 마다 제 iframe 을 만들고 지우는 에이전트 페이지 1.5 s trace 8 번 → kept {d}, mixed_content {d}, 그 밖 {d}", .{ kept, mixed, other }) catch "");
}

// ── 3 회차: 사람 입력의 종류 ───────────────────────────────────────────────────────────────────────────────

const InputKind = enum { click, wheel, move, ime_compose, ime_finish, select_all, drop, key_up_only };

fn sendInput(r: *Run, k: InputKind) void {
    switch (k) {
        .click => r.userClick(1, 100, 20),
        .wheel => r.host.send(.{ .wheel = .{ .browser = 1, .point = .{ .x = 100, .y = 200 }, .delta_x = 0, .delta_y = -240 } }) catch {},
        .move => {
            var i: i32 = 0;
            while (i < 10) : (i += 1) {
                r.host.send(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 20 + i * 30, .y = 200 } } }) catch {};
                r.pump(20);
            }
        },
        .ime_compose => r.host.send(.{ .ime_set_composition = .{ .browser = 1, .text = "한", .selection = .{ .start = 1, .end = 1 } } }) catch {},
        .ime_finish => {
            r.host.send(.{ .ime_set_composition = .{ .browser = 1, .text = "글", .selection = .{ .start = 1, .end = 1 } } }) catch {};
            r.pump(100);
            r.host.send(.{ .ime_finish_composing = .{ .browser = 1, .value = true } }) catch {};
        },
        .select_all => r.host.send(.{ .edit_command = .{ .browser = 1, .command = .select_all } }) catch {},
        .drop => {
            r.host.send(.{ .drag_data = .{ .browser = 1, .kind = .text, .bytes = "DROPPED" } }) catch {};
            r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .enter, .point = .{ .x = 100, .y = 20 }, .allowed = 1 } }) catch {};
            r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .over, .point = .{ .x = 100, .y = 20 }, .allowed = 1 } }) catch {};
            r.pump(100);
            r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .drop, .point = .{ .x = 100, .y = 20 } } }) catch {};
        },
        .key_up_only => {
            const k2: msg.Key = .{ .browser = 1, .kind = .up, .native_key_code = 0, .character = 'a', .unmodified_character = 'a' };
            r.host.send(.{ .key = k2 }) catch {};
        },
    }
}

fn r3Inputs(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa3");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.host.send(.{ .set_focus = .{ .browser = 1, .value = true } });
    r.pump(600);
    var line: std.Io.Writer = .fixed(&dbuf);
    var missed: usize = 0;
    for (std.enums.values(InputKind)) |k| {
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .cpu = true, .network = true }, .cpu_rate = 2, .latency_ms = 100 });
        const g = try start(r, 1, 2000, false);
        r.pump(300);
        sendInput(r, k);
        r.pump(500);
        const st = perf.waitFinished(r, g, 30_000);
        const em = r.st[1];
        const val = r.ev(1, "document.getElementById('i').value+'|'+(window.getSelection()+'').length", &o);
        const discarded = st != null and st.?.state == .discarded and st.?.reason == .human_input;
        const released = em != null and em.?.released_mask != 0;
        if (k != .move and k != .key_up_only and !discarded) missed += 1;
        line.print("{s}: trace {s}/{s} 조건 풀림 {} 0x{x} 칸 '{s}'; ", .{ @tagName(k), stName(st), rsName(st), released, if (em) |e| e.released_mask else 0, val[0..@min(val.len, 30)] }) catch {};
        _ = try r.emulate(1, .{ .browser = 0 });
        _ = r.ev(1, "document.getElementById('i').value='';document.getElementById('i').focus();'x'", &o);
        r.pump(200);
    }
    report(missed == 0, "a3-human-input-kinds", line.buffered());
}

// ── 6 회차: focus 흉내의 끝 ──────────────────────────────────────────────────────────────────────────────

fn vis(r: *Run, b: u64, out: []u8) []const u8 {
    const s = r.ev(b, "ST()", out);
    return if (contains(s, "\"vis\":\"visible\"")) "visible" else if (contains(s, "\"vis\":\"hidden\"")) "hidden" else s;
}

fn r6Focus(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa6");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o1: [200]u8 = undefined;
    var o2: [200]u8 = undefined;
    var o3: [200]u8 = undefined;
    var o4: [200]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-static?other"));
    try r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    try r.host.send(.{ .set_hidden = .{ .browser = 2, .value = true } });
    r.pump(800);
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    // (a) abort
    {
        const g = try start(r, 1, 8000, false);
        r.pump(400);
        const during = vis(r, 1, &o1);
        const other = vis(r, 2, &o2);
        try r.host.send(.{ .trace = .{ .browser = 1, .generation = g, .action = .abort } });
        r.pump(600);
        const after = vis(r, 1, &o3);
        if (!eql(during, "visible") or !eql(other, "hidden") or !eql(after, "hidden")) bad += 1;
        line.print("abort: 중 {s}(다른 숨은 탭 {s}) → 뒤 {s}; ", .{ during, other, after }) catch {};
        _ = perf.waitFinished(r, g, 3000);
        r.pump(1500);
    }
    // (b) 사람 입력 폐기
    {
        const g = try start(r, 1, 8000, false);
        r.pump(400);
        const during = vis(r, 1, &o1);
        r.userClick(1, 5, 300);
        const st = perf.waitFinished(r, g, 3000);
        r.pump(400);
        const after = vis(r, 1, &o3);
        if (!eql(after, "hidden")) bad += 1;
        line.print("사람 누름 {s}/{s}: 중 {s} → 뒤 {s}; ", .{ stName(st), rsName(st), during, after }) catch {};
        r.pump(1500);
    }
    // (c) 기록 중 다른 사이트 이동(새 렌더러) → 끝나면?
    {
        const g = try start(r, 1, 3000, false);
        r.pump(300);
        try r.nav(1, emu.uLocal(&u, "/pa-static?cross"));
        r.pump(300);
        const during = vis(r, 1, &o1);
        const st = perf.waitFinished(r, g, 40_000);
        r.pump(600);
        const after = vis(r, 1, &o3);
        if (!eql(after, "hidden")) bad += 1;
        line.print("다른 사이트 이동 {s}/{s}: 중 {s} → 뒤 {s}; ", .{ stName(st), rsName(st), during, after }) catch {};
        r.pump(1000);
    }
    // (d) 렌더러 죽음 → 멈춤 → 다시 불러오기
    {
        const g = try start(r, 1, 6000, false);
        r.pump(400);
        const killed = r.killRenderers();
        _ = r.until(Run.goneAt, 1, 1, 6000);
        r.pump(300);
        try r.host.send(.{ .trace = .{ .browser = 1, .generation = g, .action = .stop } });
        const st = perf.waitFinished(r, g, 40_000);
        try r.action(1, .reload);
        r.pump(1200);
        const after = vis(r, 1, &o3);
        try r.action(2, .reload);
        r.pump(600);
        const other = vis(r, 2, &o4);
        if (!eql(after, "hidden") or !eql(other, "hidden")) bad += 1;
        line.print("렌더러 {d} 죽임 → 멈춤 {s}/{s} → 다시 불러온 뒤 {s}(다른 숨은 탭 {s}); ", .{ killed, stName(st), rsName(st), after, other }) catch {};
    }
    // (e) 숨은 탭 trace 시작이 바쁨으로 실패(다른 탭이 기록 중) — 실패한 탭에 흉내가 남는가
    {
        const g = try start(r, 2, 4000, false);
        perf.trace_gen += 1;
        const g2 = perf.trace_gen;
        try r.host.send(.{ .trace = .{ .browser = 1, .generation = g2, .action = .start, .duration_ms = 2000 } });
        r.pump(500);
        const t1 = vis(r, 1, &o1);
        const t2 = vis(r, 2, &o2);
        _ = perf.waitFinished(r, g, 40_000);
        r.pump(600);
        const t2a = vis(r, 2, &o3);
        if (!eql(t1, "hidden") or !eql(t2a, "hidden")) bad += 1;
        line.print("바쁨으로 실패한 숨은 탭 {s}, 기록 중인 탭 {s} → 끝 {s}", .{ t1, t2, t2a }) catch {};
    }
    report(bad == 0, "a6-focus-lifecycle", line.buffered());
}

/// 보이는 탭에서 시작한 trace 중에 maru 가 그 탭을 숨긴다(사람이 다른 탭으로 감) — 흉내도 경고도 없이 숨은 탭을 잰다.
fn r6HideMid(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa6h");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o1: [200]u8 = undefined;
    var o2: [200]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    r.pump(600);
    const g = try start(r, 1, 3000, true);
    const rec = perf.lastState(r, g);
    r.pump(500);
    try r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    r.pump(400);
    const during = vis(r, 1, &o1);
    const d = try finishAndFilter(r, g, 40_000, "a6h_hide");
    const after = vis(r, 1, &o2);
    const warned = (d.st != null and d.st.?.focus_emulated) or (rec != null and rec.?.focus_emulated);
    report(warned or eql(during, "visible"), "a6-hidden-mid-trace", std.fmt.bufPrint(&dbuf, "보이는 탭에서 시작(기록 focus={}) → 500 ms 뒤 숨김 → 중 {s}, 끝 {s}/{s} focus={} 거르기 {s} 스크린샷 {d}, 뒤 {s} — 앱 결과의 hidden·warnings 는 시작 때 값(코드)", .{ if (rec) |x| x.focus_emulated else false, during, stName(d.st), rsName(d.st), if (d.st) |x| x.focus_emulated else false, d.outcome, d.shots, after }) catch "");
}

// ── 7 회차: CPU 나눔 — blob 주소 iframe, bfcache 되살림 ──────────────────────────────────────────────────────

fn msOf(s: []const u8) i64 {
    const at = std.mem.indexOf(u8, s, "\"ms\":") orelse return -1;
    var e = at + 5;
    while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
    return std.fmt.parseInt(i64, s[at + 5 .. e], 10) catch -1;
}

fn r7Blob(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try r7BlobMode(report, host_path, root, "", "a7-cpu-blob-iframe");
    try r7BlobMode(report, host_path, root, "?mode=data", "a7-cpu-data-iframe");
    try r7BlobOther(report, host_path, root);
}

/// 대조(A7-1 고침의 헛거절): 사용자 탭(localhost)의 같은 사이트 iframe(localhost)이 제 문서를 `blob:http://localhost…` 로 바꾼다 — 안쪽 주소의
/// 사이트는 에이전트 탭(127.0.0.1)과 다르니 CPU 는 걸려야 한다(겉 스킴만 보면 사이트 0 이라 헛거절).
fn r7BlobOther(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa7c");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-blobhost?other"));
    r.pump(2500);
    var stb: [96]u8 = undefined;
    const state = std.fmt.bufPrint(&stb, "{s}", .{r.ev(2, "ASK('a','x')", &o)}) catch "?"; // 그 iframe 이 제 주소를 답한다(blob 문서에도 kid_js 가 있다)
    const base_t = perf.benchOf(r, 1);
    const st = try r.emulate(1, perf.cpuOn(4));
    const slow_t = perf.benchOf(r, 1);
    const cpu_bit: u16 = 1 << 7;
    const active = st != null and st.?.active_mask & cpu_bit != 0;
    const ok = contains(state, "blob:http://localhost") and active and slow_t * 10 >= base_t * 25;
    report(ok, "a7-cpu-blob-other-site", std.fmt.bufPrint(&dbuf, "사용자 탭 {s}: 다른 사이트 blob iframe 이 있을 때 에이전트 탭 CPU 4 배 → 걸림 {}(실패 0x{x} {s}), 에이전트 {d} → {d} ms", .{ state, active, if (st) |x| x.failed_mask else 0, if (st) |x| @tagName(x.reason) else "-", base_t, slow_t }) catch "");
    _ = try r.emulate(1, .{ .browser = 0 });
}

fn r7BlobMode(report: Report, host_path: [:0]const u8, root: []const u8, mode: []const u8, name: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa7b");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [256]u8 = undefined;
    var o2: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    var ub: [128]u8 = undefined;
    try r.create(2, emu.uLocal(&u, std.fmt.bufPrint(&ub, "/pa-blobhost{s}", .{mode}) catch "/pa-blobhost"));
    r.pump(2500);
    var stb: [64]u8 = undefined;
    const state = std.fmt.bufPrint(&stb, "{s}", .{r.ev(2, "window.__state", &o)}) catch "?";
    const base_t = perf.benchOf(r, 1);
    const base_b = msOf(r.ev(2, "ASK('a','x')", &o));
    const st = try r.emulate(1, perf.cpuOn(4));
    const slow_t = perf.benchOf(r, 1);
    const kid = r.ev(2, "ASK('a','x')", &o2);
    const slow_b = msOf(kid);
    const cpu_bit: u16 = 1 << 7;
    const active = st != null and st.?.active_mask & cpu_bit != 0;
    const leaked = active and base_b > 0 and slow_b * 10 >= base_b * 25;
    report(!leaked, name, std.fmt.bufPrint(&dbuf, "사용자 탭 {s}: 에이전트 탭 CPU 4 배 → 걸림 {}(실패 0x{x} {s}), 에이전트 {d} → {d} ms, 사용자 blob iframe {d} → {d} ms ({s})", .{ state, active, if (st) |s| s.failed_mask else 0, if (st) |s| @tagName(s.reason) else "-", base_t, slow_t, base_b, slow_b, kid[0..@min(kid.len, 80)] }) catch "");
    _ = try r.emulate(1, .{ .browser = 0 });
}

fn r7Bfcache(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa7f");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [256]u8 = undefined;
    var o2: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-uk"));
    r.pump(1500);
    const base_if = msOf(r.ev(2, "ASK('f','x')", &o));
    try r.nav(2, emu.uLocal(&u, "/pa-plain"));
    r.pump(800);
    const st = try r.emulate(1, perf.cpuOn(4));
    const cpu_bit: u16 = 1 << 7;
    const active = st != null and st.?.active_mask & cpu_bit != 0;
    const before = r.loads[2];
    try r.host.send(.{ .nav_action = .{ .browser = 2, .action = .back, .user = true } });
    _ = r.until(Run.loadsAt, 2, before + 1, 6000);
    r.pump(1500);
    var psb: [64]u8 = undefined;
    const ps = std.fmt.bufPrint(&psb, "{s}", .{r.ev(2, "String(window.__ps)+' '+location.pathname", &o)}) catch "?";
    const rel = r.st[1];
    const kid = r.ev(2, "ASK('f','x')", &o2);
    const after_if = msOf(kid);
    const leaked = active and base_if > 0 and after_if * 10 >= base_if * 25;
    report(!leaked, "a7-cpu-bfcache-restore", std.fmt.bufPrint(&dbuf, "사용자 탭이 같은 사이트 iframe 페이지를 bfcache 에 두고 떠난 동안 CPU 4 배 → 걸림 {}; 사용자 뒤로 → 되살림 {s}, 풀림 0x{x} {s}, 사용자 iframe {d} → {d} ms", .{ active, ps, if (rel) |s| s.released_mask else 0, if (rel) |s| @tagName(s.cpu_release) else "-", base_if, after_if }) catch "");
    _ = try r.emulate(1, .{ .browser = 0 });
}

/// CPU 를 건 에이전트 탭이 다른 사이트로 떠난 뒤 옛 렌더러 프로세스(bfcache·제 팝업이 살려 둔다)에 사용자 iframe 이 들어온다.
fn r7OldProc(report: Report, host_path: [:0]const u8, root: []const u8, keep_popup: bool, name: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, if (keep_popup) "pa7p" else "pa7o");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [256]u8 = undefined;
    var o2: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-pop"));
    r.pump(500);
    var pop_ms: i64 = -1;
    if (keep_popup) {
        try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
        r.pump(200);
        try r.host.send(.{ .new_tab_credit = 1 });
        r.cdpClick(1, 100, 100);
        _ = r.until(Run.loadsAt, 4, 1, 8000);
        r.pump(500);
    }
    const base_t = perf.benchOf(r, 1);
    const st = try r.emulate(1, perf.cpuOn(4));
    const slow_t = perf.benchOf(r, 1);
    // 에이전트 탭이 다른 사이트로(새 렌더러). 옛 프로세스는 bfcache(와 팝업)가 살려 둔다.
    try r.nav(1, emu.uLocal(&u, "/pa-static?left"));
    r.pump(800);
    const t_after = perf.benchOf(r, 1);
    if (keep_popup) pop_ms = perf.benchOf(r, 4);
    // 사용자 탭(localhost) 이 127.0.0.1 iframe 을 연다 — 옛 프로세스에 들 수 있다.
    try r.create(2, emu.uLocal(&u, "/pa-uk"));
    r.pump(1500);
    const kid = r.ev(2, "ASK('f','x')", &o);
    const kid_ms = msOf(kid);
    const rel = r.st[1];
    // 에이전트가 지운다 — 그래도 남는가.
    _ = try r.emulate(1, .{ .browser = 0 });
    r.pump(300);
    const kid2 = msOf(r.ev(2, "ASK('f','x')", &o2));
    const cpu_bit: u16 = 1 << 7;
    const active = st != null and st.?.active_mask & cpu_bit != 0;
    const leaked = active and kid_ms * 10 >= base_t * 25;
    const stuck = kid2 * 10 >= base_t * 25;
    report(!leaked and !stuck, name, std.fmt.bufPrint(&dbuf, "에이전트 탭 CPU 4 배(걸림 {}) {d} → {d} ms → 다른 사이트로 떠남 → 탭 {d} ms, 제 팝업 {d} ms → 사용자 탭의 127.0.0.1 iframe {d} ms(풀림 0x{x} {s}) → 에이전트가 지운 뒤 사용자 iframe {d} ms", .{ active, base_t, slow_t, t_after, pop_ms, kid_ms, if (rel) |x| x.released_mask else 0, if (rel) |x| @tagName(x.cpu_release) else "-", kid2 }) catch "");
}

fn r7Old(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try r7OldProc(report, host_path, root, false, "a7-old-process-bfcache");
    try r7OldProc(report, host_path, root, true, "a7-old-process-popup");
}

// ── 8 회차: 네트워크 — connection 되돌림, 기록과 함께, 지연의 범위 ─────────────────────────────────────────────

fn r8NetInfo(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa8");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var b1: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    var c1: [200]u8 = undefined;
    var c2: [200]u8 = undefined;
    var d1: [200]u8 = undefined;
    var d2: [200]u8 = undefined;
    var e1: [200]u8 = undefined;
    var e2: [200]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static"));
    try r.create(2, emu.uLocal(&u, "/pa-uk"));
    r.pump(1500);
    const base_t = r.ev(1, "NI()", &b1);
    const base_i = r.ev(2, "ASK('f','ni')", &b2);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    const off_t = r.ev(1, "NI()", &c1);
    const off_i = r.ev(2, "ASK('f','ni')", &c2);
    _ = try r.emulate(1, .{ .browser = 0 });
    r.pump(300);
    const back_t = r.ev(1, "NI()", &d1);
    const back_i = r.ev(2, "ASK('f','ni')", &d2);
    // 본문 기록(W9d)이 켜진 채 — Network.disable 이 없다.
    try r.host.send(.{ .net_watch = .{ .browser = 1, .on = true, .full = true, .any_host = true } });
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 1 } });
    r.pump(500);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    _ = try r.emulate(1, .{ .browser = 0 });
    r.pump(300);
    const rec_t = r.ev(1, "NI()", &e1);
    const rec_i = r.ev(2, "ASK('f','ni')", &e2);
    const same1 = eql(base_t, back_t) and eql(base_i, back_i);
    const same2 = eql(base_t, rec_t) and eql(base_i, rec_i);
    report(same1 and same2, "a8-netinfo-restored", std.fmt.bufPrint(&dbuf, "처음 T {s} iframe {s} | offline T {s} iframe {s} | 풂 T {s} iframe {s} | 기록 켠 채 offline→풂 T {s} iframe {s}", .{ base_t, base_i, off_t, off_i, back_t, back_i, rec_t, rec_i }) catch "");
    // 지연의 범위 — 에이전트 탭·같은 프로세스 사용자 iframe·에이전트가 연 팝업.
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
    try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } });
    try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
    r.pump(200);
    var o: [128]u8 = undefined;
    try r.host.send(.{ .new_tab_credit = 1 });
    _ = r.evWith(1, "window.pp=window.open('/pa-static?np','np'),'ok'", &o, true);
    _ = r.until(Run.loadsAt, 4, 1, 8000);
    r.pump(500);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true }, .latency_ms = 800 });
    var f1: [64]u8 = undefined;
    var f2: [64]u8 = undefined;
    var f3: [64]u8 = undefined;
    const ft_t = r.ev(1, "ft('/x?lt')", &f1);
    const ft_i = r.ev(2, "ASK('f','ft')", &f2);
    const ft_p = r.ev(4, "ft('/x?lp')", &f3);
    report(true, "a8-latency-scope(obs)", std.fmt.bufPrint(&dbuf, "지연 800 ms: 에이전트 탭 {s}, 같은 프로세스 사용자 iframe {s}, 에이전트가 연 팝업 {s}", .{ ft_t, ft_i, ft_p }) catch "");
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    var g1: [64]u8 = undefined;
    var g2: [64]u8 = undefined;
    var g3: [64]u8 = undefined;
    var h1: [200]u8 = undefined;
    var h2: [200]u8 = undefined;
    const of_t = r.ev(1, "ft('/x?ot')", &g1);
    const of_i = r.ev(2, "ASK('f','ft')", &g2);
    const of_p = r.ev(4, "ft('/x?op')", &g3);
    const on_i = r.ev(2, "ASK('f','ni')", &h1);
    const on_p = r.ev(4, "NI()", &h2);
    report(true, "a8-offline-scope(obs)", std.fmt.bufPrint(&dbuf, "offline: 에이전트 탭 가져오기 {s} | 같은 프로세스 사용자 iframe 가져오기 {s} onLine {s} | 에이전트가 연 팝업 가져오기 {s} onLine {s}", .{ of_t, of_i, on_i, of_p, on_p }) catch "");
    _ = try r.emulate(1, .{ .browser = 0 });
}

/// 사용자 탭의 CPU·네트워크(사이트에 묶임) — 그 사이트가 맨 위일 때만, 떠나면 풀고 돌아오면 다시, 사람이 몰면 풂.
fn r10SiteBound(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa10");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var f1: [64]u8 = undefined;
    var f2: [64]u8 = undefined;
    var f3: [64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-static?ub"));
    r.pump(400);
    const base = perf.benchOf(r, 1);
    const st = try r.emulate(1, .{ .browser = 0, .flags = .{ .site_bound = true, .cpu = true, .network = true }, .site = "127.0.0.1", .cpu_rate = 4, .latency_ms = 600 });
    const on1 = perf.benchOf(r, 1);
    const ft1 = r.ev(1, "ft('/x?s1')", &f1);
    try r.nav(1, emu.uLocal(&u, "/pa-static?off"));
    r.pump(500);
    const off = perf.benchOf(r, 1);
    const ft2 = r.ev(1, "ft('/x?s2')", &f2);
    try r.nav(1, emu.uLoop(&u, "/pa-static?back"));
    r.pump(500);
    const on2 = perf.benchOf(r, 1);
    r.userClick(1, 300, 300);
    r.pump(600);
    const rel = r.st[1];
    const after = perf.benchOf(r, 1);
    const ft3 = r.ev(1, "ft('/x?s3')", &f3);
    const ok = on1 * 10 >= base * 25 and off * 10 <= base * 16 and !contains(ft2, "err") and ftMs(ft2) < 300 and on2 * 10 >= base * 25 and rel != null and rel.?.released_mask != 0 and after * 10 <= base * 16 and ftMs(ft3) < 300;
    report(ok, "a10-user-tab-site-bound", std.fmt.bufPrint(&dbuf, "사용자 탭(127.0.0.1 에 묶임) CPU 4·지연 600(걸림 0x{x}): {d} → {d} ms·{s} | 다른 사이트로 → {d} ms·{s} | 돌아옴 → {d} ms | 사람 누름 → 풀림 0x{x} {s}/{s} → {d} ms·{s}", .{ if (st) |x| x.active_mask else 0, base, on1, ft1, off, ft2, on2, if (rel) |x| x.released_mask else 0, if (rel) |x| @tagName(x.cpu_release) else "-", if (rel) |x| @tagName(x.network_release) else "-", after, ft3 }) catch "");
}

fn ftMs(s: []const u8) i64 {
    const sp = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return -1;
    return std.fmt.parseInt(i64, s[sp + 1 ..], 10) catch -1;
}

// ── 4 회차: 자원 — 적대 페이지 30 s, UI 스레드 멈춤 ──────────────────────────────────────────────────────

fn r4Flood(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa4");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-flood"));
    try r.create(2, emu.uLocal(&u, "/pa-static?probe"));
    r.pump(500);
    const gen = try start(r, 1, 30_000, true);
    const t0 = os.nowMs();
    var max_eval: i64 = 0;
    var max_eval_recv: i64 = 0;
    var n: usize = 0;
    var stop_ms: i64 = 0;
    while (os.nowMs() - t0 < 120_000) {
        const st = perf.lastState(r, gen);
        if (st) |x| if (x.state == .done or x.state == .discarded or x.state == .failed) break;
        if (st) |x| if (x.state == .receiving and stop_ms == 0) {
            stop_ms = os.nowMs();
        };
        const a = os.nowMs();
        _ = r.ev(2, "1", &o);
        const dt = os.nowMs() - a;
        if (st != null and st.?.state == .receiving) max_eval_recv = @max(max_eval_recv, dt) else max_eval = @max(max_eval, dt);
        n += 1;
        r.pump(100);
    }
    const end = perf.lastState(r, gen);
    const done_ms = os.nowMs();
    var pb: [1200]u8 = undefined;
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/a4_flood.raw.gz", .{root_dir}, 0) catch return, r.tr_gz.items) catch {};
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(std.heap.c_allocator);
    for (r.tr_frames.items, r.tr_frame_lens.items) |*b, k| {
        ids.appendSlice(std.heap.c_allocator, b[0..k]) catch {};
        ids.append(std.heap.c_allocator, '\n') catch {};
    }
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/a4_flood.frames.txt", .{root_dir}, 0) catch return, ids.items) catch {};
    report(true, "a4-flood(obs)", std.fmt.bufPrint(&dbuf, "30 s 적대 페이지 → {s}/{s} 덮음 {d} ms, gzip {d} B, data_loss {}, 받기 시작→끝 {d} ms, 다른 탭 eval 최대: 기록 중 {d} ms·받는 중 {d} ms({d} 번)", .{ stName(end), rsName(end), if (end) |x| x.covered_ms else 0, r.tr_gz.items.len, if (end) |x| x.data_loss else false, if (stop_ms > 0) done_ms - stop_ms else -1, max_eval, max_eval_recv, n }) catch "");
}

/// 화면이 늘 바뀌는 페이지(캔버스 잡음) — 스크린샷이 큰 30 s trace.
fn r4Noise(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pa4n");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pa-noise"));
    r.pump(800);
    const gen = try start(r, 1, 30_000, true);
    const d = try finishAndFilter(r, gen, 120_000, "a4n_noise");
    const st = d.st;
    // A4-1: 상한 앞에서 잘라 `done` + truncated 로 끝나고, 거른 결과가 남는다(덮은 시간은 maru 의 요약이 다시 잰다 — 판정은 gzip 이 상한 안인지만).
    const ok = st != null and st.?.state == .done and st.?.truncated and r.tr_gz.items.len <= msg.max_trace_gz_bytes and eql(d.outcome, "kept");
    report(ok, "a4-noise-screens", std.fmt.bufPrint(&dbuf, "캔버스 잡음 30 s + 스크린샷 → {s}/{s} 덮음 {d} ms, 잘림 {}, 받은 gzip {d} B, data_loss {}, 거르기 {s} 스크린샷 {d}", .{ stName(st), rsName(st), if (st) |x| x.covered_ms else 0, if (st) |x| x.truncated else false, r.tr_gz.items.len, if (st) |x| x.data_loss else false, d.outcome, d.shots }) catch "");
}

// ── 9 회차: 주인 — 진짜 pty 셸에서 에이전트 흉내(setsid 명령), SIGSTOP, `&` ─────────────────────────────────────

fn r9Owner(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    _ = host_path;
    var pb: [1200]u8 = undefined;
    // 에이전트 흉내: 대화형 셸에서 foreground 로 띄운 sh — 명령은 새 세션(Claude Code 의 Bash 도구처럼 setsid, tty 없음).
    const script_path = try std.fmt.bufPrintSentinel(&pb, "{s}/agent.sh", .{root}, 0);
    try perf.writeAll(script_path,
        \\echo AG=$$
        \\perl -MPOSIX -e 'POSIX::setsid(); exec "/bin/sh","-c","echo CLI=\$\$; exec sleep 60"' &
        \\exec sleep 60
        \\
    );
    const pty = perf.spawnShell() orelse return error.SpawnFailed;
    defer perf.reap(pty.shell);
    defer _ = std.c.close(pty.master);
    var lb: [1400]u8 = undefined;
    const line = try std.fmt.bufPrint(&lb, "/bin/sh {s}\n", .{script_path});
    _ = std.c.write(pty.master, line.ptr, line.len);
    const ag = perf.readTagged(pty.master, "AG=", 8000) orelse return error.NoAgentPid;
    const cli = perf.readTagged(pty.master, "CLI=", 8000) orelse return error.NoCliPid;
    sleep(300);
    var wall: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &wall);
    const now_us: u64 = @as(u64, @intCast(wall.sec)) * std.time.us_per_s + @as(u64, @intCast(@divTrunc(wall.nsec, 1000)));
    const found = self_origin.findOrigin(perf.fullProvider(), cli, std.c.getuid(), now_us);
    var line2: std.Io.Writer = .fixed(&dbuf);
    var ok = true;
    switch (found) {
        .reject => |why| {
            line2.print("setsid 명령의 1g 거절 {s}; ", .{@tagName(why)}) catch {};
            ok = false;
        },
        .origin => |org| {
            const owner = self_origin.ownerOf(org, false);
            line2.print("셸 {d} → 에이전트 {d} → setsid 명령 {d}: job {d} shell {d} 주인 {s} {d}; ", .{ pty.shell, ag, cli, org.job_pid, org.shell_pid, if (owner) |w| w.kind() else "-", if (owner) |w| w.job.pid else 0 }) catch {};
            if (owner) |w| {
                // SIGSTOP — 살아 있다(멈춘 주인 — 문서의 받아들임).
                _ = std.c.kill(ag, std.c.SIG.STOP);
                perf.drain(pty.master);
                sleep(200);
                const stopped_alive = self_origin.ownerAlive(perf.fullProvider(), w);
                _ = std.c.kill(ag, std.c.SIG.CONT);
                // 명령(setsid)만 끝남 — 주인은 산다.
                _ = std.c.kill(cli, std.c.SIG.KILL);
                sleep(200);
                const cli_gone_alive = self_origin.ownerAlive(perf.fullProvider(), w);
                // 에이전트가 끝남 — 얼마 만에 끝난 것으로 보이나.
                _ = std.c.kill(ag, std.c.SIG.KILL);
                const t0 = os.nowMs();
                var gone_ms: i64 = -1;
                while (os.nowMs() - t0 < 3000) {
                    perf.drain(pty.master);
                    if (!self_origin.ownerAlive(perf.fullProvider(), w)) {
                        gone_ms = os.nowMs() - t0;
                        break;
                    }
                    sleep(5);
                }
                line2.print("SIGSTOP 중 살아 있음 {}, 명령만 끝남 → 살아 있음 {}, 에이전트 끝남 → {d} ms 에 끝남으로 봄; ", .{ stopped_alive, cli_gone_alive, gone_ms }) catch {};
                if (!(w.job.pid == ag and !w.shell and cli_gone_alive and gone_ms >= 0 and gone_ms < 500)) ok = false;
            } else ok = false;
        },
    }
    // 사람이 셸에서 `&` 로 띄운 명령 — 주인은 셸(문서의 알려진 길)인가.
    const bg = "sleep 61 & echo BG=$!\n";
    _ = std.c.write(pty.master, bg.ptr, bg.len);
    if (perf.readTagged(pty.master, "BG=", 8000)) |bgp| {
        sleep(200);
        _ = std.c.clock_gettime(.REALTIME, &wall);
        const now2: u64 = @as(u64, @intCast(wall.sec)) * std.time.us_per_s + @as(u64, @intCast(@divTrunc(wall.nsec, 1000)));
        switch (self_origin.findOrigin(perf.fullProvider(), bgp, std.c.getuid(), now2)) {
            .reject => |why| line2.print("`&` 명령 → 1g 거절 {s}", .{@tagName(why)}) catch {},
            .origin => |org| {
                const owner = self_origin.ownerOf(org, false);
                line2.print("`&` 명령 {d} → job {d}(셸 {d}) 주인 {s} {d}", .{ bgp, org.job_pid, pty.shell, if (owner) |w| w.kind() else "-", if (owner) |w| w.job.pid else 0 }) catch {};
            },
        }
        _ = std.c.kill(bgp, std.c.SIG.KILL);
    }
    report(ok, "a9-owner-real-procs", line2.buffered());
}

// ── 실행 ─────────────────────────────────────────────────────────────────────────────────────────────────

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try emu.startServer();
    try perf.setup(host_path, root);
    root_dir = root;
    const probes = .{
        .{ "a1-screens", r1Screens },
        .{ "a1-frameless", r1Frameless },
        .{ "a1-move", r1MoveOnly },
        .{ "a1-worker", r1Worker },
        .{ "a1-scroll", r1Scroll },
        .{ "a1-selfanim", r1SelfAnim },
        .{ "a2-popup", r2Popup },
        .{ "a2-prerender", r2Prerender },
        .{ "a2-bfcache", r2Bfcache },
        .{ "a2-churn", r2Churn },
        .{ "a3-inputs", r3Inputs },
        .{ "a6-focus", r6Focus },
        .{ "a6-hide", r6HideMid },
        .{ "a7-blob", r7Blob },
        .{ "a7-bfcache", r7Bfcache },
        .{ "a7-old", r7Old },
        .{ "a8-netinfo", r8NetInfo },
        .{ "a9-owner", r9Owner },
        .{ "a10-site", r10SiteBound },
        .{ "a4-flood", r4Flood },
        .{ "a4-noise", r4Noise },
    };
    // V-J1: 고른 이름이 없거나 틀렸으면 실패(빈 판이 통과로 보이지 않게 — `probe_select.zig`).
    var names: [probes.len][]const u8 = undefined;
    var ran: usize = 0;
    inline for (probes, 0..) |p, i| {
        names[i] = p[0];
        if (only(p[0])) {
            ran += 1;
            p[1](report, host_path, root) catch |e| report(false, p[0], @errorName(e));
        }
    }
    select.verify(report, "W9E2A_ONLY", "w9e2a-selection", &names, ran);
    // V-15: DevTools 관찰자 재진입(「Check failed: !check_reentrancy」)이 이 판의 어느 host 로그에도 없어야 한다 — trace 의 명령을 관찰자 콜백
    // 안에서 곧 내면 난다(늦은 시작 답 안의 `Tracing.end` 는 sidecar 를 죽였다). 판 전체를 본다.
    if (ran > 0) select.noReentrancy(report, root, "w9e2a-no-observer-reentrancy");
}
