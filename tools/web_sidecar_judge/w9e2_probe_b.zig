//! W9e② 적대 검증 v20b(1–10 고침 재확인·11–20 회차) 탐침 — 판정용이다(제품 코드 아님). `maru-web-judge --w9e2b <dist> <프로필>`, 환경
//! `W9E2B_ONLY=이름,…` 이면 그 탐침만. v20a 탐침(`w9e2_probe_a.zig`)과 같은 틀(판정자가 maru 역할로 trace·흉내·사람 입력을 보낸다). PASS = 문서가
//! 약속한 동작, FAIL = 반례 후보. `(obs)` 는 관찰만(늘 PASS).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const emu = @import("emulation_check.zig");
const perf = @import("perf_check.zig");
const select = @import("probe_select.zig");

const msg = protocol.message;
const Run = emu.Run;
const Session = emu.Session;
const Report = emu.Report;
const contains = emu.contains;

const common_js =
    \\window.__frames=0;
    \\window.bench=function(n){n=n||3e7;var s=performance.now(),x=0;for(var i=0;i<n;i++){x=(x+i*7)%1000003}window.__x=x;return Math.round(performance.now()-s)};
    \\window.ft=async function(u){var s=performance.now();try{var r=await fetch(u,{cache:'no-store'});await r.text();return 'ok '+Math.round(performance.now()-s)}catch(e){return 'err '+Math.round(performance.now()-s)}};
    \\window.ST=function(){return JSON.stringify({vis:document.visibilityState,online:navigator.onLine})};
    \\window.JANK=function(ms){var e=performance.now()+ms;while(performance.now()<e){}return 'j'};
;

/// sandbox srcdoc 안의 잼(불투명 출처 — 부모가 postMessage 로 묻는다). srcdoc 속성 안이라 작은따옴표를 쓰지 않는다.
const sbx_kid = "<script>onmessage=function(e){var s=performance.now(),x=0;for(var i=0;i<3e7;i++){x=(x+i*7)%1000003}e.ports[0].postMessage(JSON.stringify({ms:Math.round(performance.now()-s),x:x}))}</script>";
const ask_js = "window.ASK=function(f,m){return new Promise(function(r){var el=document.getElementById(f);var ch=new MessageChannel();ch.port1.onmessage=function(e){r(e.data)};el.contentWindow.postMessage(m,'*',[ch.port2]);setTimeout(function(){r('timeout')},20000)})};";

const anim_css = "<style>@keyframes s{from{transform:translateX(0)}to{transform:translateX(200px)}}#b{width:80px;height:80px;background:#f0f;animation:s 0.5s linear infinite alternate;will-change:transform}</style>";

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn replyRaw(conn: c_int, status: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n", .{ status, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn reply(conn: c_int, body: []const u8) bool {
    replyRaw(conn, "200 OK", "", body);
    return true;
}

/// `emulation_check.serveParsed` 가 부른다 — `/pb-*` 만 맡는다.
pub fn serve(conn: c_int, path: []const u8, target: []const u8, host: []const u8) bool {
    _ = host;
    _ = target;
    if (!std.mem.startsWith(u8, path, "/pb-")) return false;
    const port = emu.port;
    var bb: [16384]u8 = undefined;
    // 에이전트 탭 꼴.
    if (eql(path, "/pb-t")) return reply(conn, "<!doctype html><title>PB-T</title><body style='margin:0;background:#00c000'><input id=i style='width:300px;height:40px'><div style='height:3000px'>agent</div><script>" ++ common_js ++ "</script>");
    if (eql(path, "/pb-t-blank")) return reply(conn, "<!doctype html><title>PB-T-BLANK</title><body style='margin:0;background:#00c000'><iframe src='about:blank' width=50 height=50></iframe><script>" ++ common_js ++ "</script>");
    // 사용자 탭 안 같은 사이트(127.0.0.1) iframe 이 공유 주 스레드를 거의 늘 막는다(400 ms 일·50 ms 쉼 — 그 일의 TimerFire 는 그 iframe 의 프레임을 싣는다).
    if (eql(path, "/pb-u-kid-jank")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-KIDJANK</title><body>user<iframe src='http://127.0.0.1:{d}/pb-kid-jank' width=300 height=100></iframe>", .{port}) catch return false);
    if (eql(path, "/pb-kid-jank")) return reply(conn, "<!doctype html><title>KID-JANK</title><body>kid<script>setInterval(function(){var e=performance.now()+400;while(performance.now()<e){}},450)</script>");
    if (eql(path, "/pb-jank")) return reply(conn, "<!doctype html><title>PB-JANK</title>" ++ anim_css ++ "<body style='margin:0'><div id=b></div><script>" ++ common_js ++ "</script>");
    // 페이지가 rAF 를 바꿔(가로채) 센다 — 격리된 world 의 rAF 가 페이지 world 에 보이는가.
    if (eql(path, "/pb-detect")) return reply(conn, "<!doctype html><title>PB-DETECT</title>" ++ anim_css ++ "<body style='margin:0'><div id=b></div><script>" ++ common_js ++
        \\window.__hooked=0;var orig=window.requestAnimationFrame;window.requestAnimationFrame=function(f){window.__hooked++;return orig.call(window,f)};
        \\Window.prototype.requestAnimationFrame=window.requestAnimationFrame;
        \\window.__loaf=0;try{new PerformanceObserver(function(l){window.__loaf+=l.getEntries().length}).observe({type:'long-animation-frame'})}catch(e){window.__loaf=-1}
        \\window.__ctx0=Object.getOwnPropertyNames(window).length;window.__mut=0;new MutationObserver(function(m){window.__mut+=m.length}).observe(document,{subtree:true,childList:true,attributes:true});
        \\window.DET=function(){return JSON.stringify({hooked:__hooked,loaf:__loaf,globals:Object.getOwnPropertyNames(window).length-__ctx0,mut:__mut})};
    ++ "</script>");
    if (eql(path, "/pb-pop2")) return reply(conn, "<!doctype html><title>PB-POP2</title><body style='margin:0;background:#00c000'><script>" ++ common_js ++ "</script>");
    if (eql(path, "/pb-redir")) {
        var lb: [256]u8 = undefined;
        const loc = std.fmt.bufPrint(&lb, "Location: http://localhost:{d}/pb-t?redirected\r\n", .{port}) catch return false;
        replyRaw(conn, "302 Found", loc, "");
        return true;
    }
    if (eql(path, "/pb-dl")) {
        replyRaw(conn, "200 OK", "Content-Disposition: attachment; filename=\"x.bin\"\r\n", "0123456789");
        return true;
    }
    // 사용자 탭 꼴(localhost — 에이전트 탭 127.0.0.1 과 다른 사이트) — 흔한 광고·임베드.
    if (eql(path, "/pb-u-none")) return reply(conn, "<!doctype html><title>U-NONE</title><body>user<script>" ++ common_js ++ "</script>");
    // Hotjar `_hjSafeContext`·여러 라이브러리가 깨끗한 내장 함수를 얻으려 만드는 숨은 빈 iframe(src 없음).
    if (eql(path, "/pb-u-hidden")) return reply(conn, "<!doctype html><title>U-HIDDEN</title><body>user<script>" ++ common_js ++ "var f=document.createElement('iframe');f.style.display='none';f.id='_hjSafeContext';document.body.appendChild(f);</script>");
    // GPT 의 「friendly iframe」 — about:blank 에 광고 글을 써 넣는다.
    if (eql(path, "/pb-u-gpt")) return reply(conn, "<!doctype html><title>U-GPT</title><body>user<iframe id=g src='about:blank' width=300 height=250 frameborder=0></iframe><script>" ++ common_js ++ "var d=document.getElementById('g').contentDocument;d.open();d.write('<body style=\"background:#ccc\">AD</body>');d.close();</script>");
    if (eql(path, "/pb-u-srcdoc")) return reply(conn, "<!doctype html><title>U-SRCDOC</title><body>user<iframe srcdoc='<p>embed</p>' width=300 height=100></iframe><script>" ++ common_js ++ "</script>");
    if (eql(path, "/pb-u-js")) return reply(conn, "<!doctype html><title>U-JS</title><body>user<iframe src=\"javascript:''\" width=300 height=100></iframe><script>" ++ common_js ++ "</script>");
    if (eql(path, "/pb-u-sandbox")) return reply(conn, "<!doctype html><title>U-SANDBOX</title><body>user<iframe sandbox srcdoc='<p>x</p>' width=300 height=100></iframe><script>" ++ common_js ++ "</script>");
    // about:blank 안의 about:blank(조상을 둘 따라간다).
    if (eql(path, "/pb-u-nested")) return reply(conn, "<!doctype html><title>U-NESTED</title><body>user<iframe id=g src='about:blank' width=300 height=200></iframe><script>" ++ common_js ++ "var d=document.getElementById('g').contentDocument;d.open();d.write('<iframe src=\"about:blank\" width=100 height=50></iframe>');d.close();</script>");
    // 스크립트를 돌리는 sandbox srcdoc — 그 안에서 잰다(불투명 출처라 부모가 들여다볼 수 없다 — postMessage 로 묻는다).
    if (eql(path, "/pb-u-sbx-js") or eql(path, "/pb-t-sbx-js")) return reply(conn, "<!doctype html><title>SBX-JS</title><body>sbx<iframe id=f sandbox='allow-scripts' srcdoc='" ++ sbx_kid ++ "' width=300 height=100></iframe><script>" ++ common_js ++ ask_js ++ "</script>");
    // data: iframe — 그대로 위험(제가 연 것은 부모와 다를 수 있다 — 7 회차).
    if (eql(path, "/pb-u-data")) return reply(conn, "<!doctype html><title>U-DATA</title><body>user<iframe src='data:text/html,<p>d</p>' width=300 height=100></iframe><script>" ++ common_js ++ "</script>");
    // 에이전트 탭과 같은 사이트(127.0.0.1) iframe 이 제 문서를 about:blank 로 바꾼다(A7-1 의 꼴 — 그 문서는 제 프로세스에 남는다).
    if (eql(path, "/pb-u-selfblank")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-SELFBLANK</title><body>user<iframe id=f src='http://127.0.0.1:{d}/pb-kid-selfblank' width=300 height=100></iframe><script>{s}</script>", .{ port, common_js }) catch return false);
    if (eql(path, "/pb-kid-selfblank")) return reply(conn, "<!doctype html><title>KID-SELFBLANK</title><body>kid<script>setTimeout(function(){location.href='about:blank'},50)</script>");
    // 사용자 정보가 붙은 같은 사이트 iframe(호스트 어림이 `@` 를 넘는가).
    if (eql(path, "/pb-u-userinfo")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-USERINFO</title><body>user<iframe id=f src='http://u:p@127.0.0.1:{d}/pa-kid' width=300 height=100></iframe><script>{s}window.ASK=function(f,m){{return new Promise(function(r){{var el=document.getElementById(f);var ch=new MessageChannel();ch.port1.onmessage=function(e){{r(e.data)}};el.contentWindow.postMessage(m,'*',[ch.port2]);setTimeout(function(){{r('timeout')}},20000)}})}};</script>", .{ port, common_js }) catch return false);
    // 대문자 스킴·호스트(`HTTP://127.0.0.1`) — Chromium 이 정규형으로 주는가.
    if (eql(path, "/pb-u-upper")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-UPPER</title><body>user<iframe id=f src='HTTP://127.0.0.1:{d}/pa-kid' width=300 height=100></iframe><script>{s}{s}</script>", .{ port, common_js, ask_js }) catch return false);
    // 사용자 탭이 같은 사이트(127.0.0.1) 팝업을 연다.
    if (eql(path, "/pb-uopen")) return reply(conn, "<!doctype html><title>U-OPEN</title><body>user<script>" ++ common_js ++ "</script>");
    if (eql(path, "/pb-noise")) return reply(conn, "<!doctype html><title>NOISE</title><body style='margin:0'><canvas id=c width=1280 height=800 style='width:640px;height:400px'></canvas><script>var c=document.getElementById('c').getContext('2d');var im=c.createImageData(1280,800);function f(){var d=im.data;for(var i=0;i<d.length;i+=4){var v=(Math.random()*255)|0;d[i]=v;d[i+1]=(v*7)&255;d[i+2]=(v*13)&255;d[i+3]=255}c.putImageData(im,0,0);requestAnimationFrame(f)}f();</script>");
    return false;
}

// ── 공통 ─────────────────────────────────────────────────────────────────────────────────────────────────

var root_dir: []const u8 = "";
var dbuf: [4000]u8 = undefined;

fn only(name: []const u8) bool {
    return select.selected("W9E2B_ONLY", name);
}

fn stName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.state) else "-";
}
fn rsName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.reason) else "-";
}

const Done = struct { st: ?msg.TraceState, outcome: []const u8, kept: u64, shots: u64, foreign: []const u8, frames: u64 = 0, comp_dropped: u64 = 0, profile: bool = false };
var outcome_bufs: [8][64]u8 = undefined;
var foreign_bufs: [8][128]u8 = undefined;
var ob_i: usize = 0;

fn finishAndFilter(r: *Run, gen: u32, wait: u32) !Done {
    const st = perf.waitFinished(r, gen, wait);
    if (st == null or st.?.state != .done) return .{ .st = st, .outcome = "not-done", .kept = 0, .shots = 0, .foreign = "-" };
    var res = try perf.filterNow(r, std.heap.c_allocator);
    defer res.deinit(std.heap.c_allocator);
    ob_i = (ob_i + 1) % outcome_bufs.len;
    const o = std.fmt.bufPrint(&outcome_bufs[ob_i], "{s}", .{res.outcome}) catch "?";
    const f = std.fmt.bufPrint(&foreign_bufs[ob_i], "{s}", .{res.foreign[0..@min(res.foreign.len, 100)]}) catch "?";
    // 결정 12: 남긴 trace 에 V8 프로파일(긴 작업의 표본 — 막힌 동안 주 스레드의 일은 이것으로 보인다)이 있는가.
    const profile = res.gz.len > 0 and perf.gunzipContains(std.heap.c_allocator, res.gz, "ProfileChunk");
    return .{ .st = st, .outcome = o, .kept = res.kept, .shots = res.screenshots, .foreign = f, .frames = res.frames, .comp_dropped = res.comp_dropped, .profile = profile };
}

fn start(r: *Run, b: u64, ms: u32, shots: bool) !u32 {
    const gen = try perf.startTrace(r, b, ms, shots);
    _ = r.until(perf.recordingAt, gen, 0, 8000);
    return gen;
}

fn sendTrace(r: *Run, b: u64, gen: u32, action: msg.TraceAction) void {
    r.host.send(.{ .trace = .{ .browser = b, .generation = gen, .action = action } }) catch {};
}

/// 탭 자리를 다시 쓴다(판정자의 표는 8 칸).
fn recycle(r: *Run, b: u64) void {
    r.host.send(.{ .destroy_browser = b }) catch {};
    r.pump(700);
    r.created[b] = false;
    r.loads[b] = 0;
    r.st[b] = null;
    r.gen[b] = 0;
}

fn vis(r: *Run, b: u64, out: []u8) []const u8 {
    const s = r.ev(b, "ST()", out);
    return if (contains(s, "\"vis\":\"visible\"")) "visible" else if (contains(s, "\"vis\":\"hidden\"")) "hidden" else s;
}

fn msOf(s: []const u8) i64 {
    const at = std.mem.indexOf(u8, s, "\"ms\":") orelse return -1;
    var e = at + 5;
    while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
    return std.fmt.parseInt(i64, s[at + 5 .. e], 10) catch -1;
}

fn ftMs(s: []const u8) i64 {
    const sp = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return -1;
    return std.fmt.parseInt(i64, s[sp + 1 ..], 10) catch -1;
}

const cpu_bit: u16 = 1 << 7;
const net_bit: u16 = 1 << 8;

// ── A7-1: 사이트를 모르는 가족 밖 프레임 — 흔한 광고·임베드 꼴의 헛거절, 우회 꼴 ──────────────────────────────────────

fn b7Embeds(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb7");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(500);
    const base = perf.benchOf(r, 1);
    // `ask` — 그 사용자 탭의 iframe 안에서 잰다(postMessage), 아니면 사용자 탭 주 프레임에서(같은 출처의 물려받는 iframe 은 그 프로세스다).
    // `ask_first` — 그 iframe 이 실제로 불러와질 때까지 먼저 묻는다(사용자 정보가 붙은 주소는 iframe 이 늦게 생겨 조건을 건 뒤에야 나타났다 —
    // 그때는 sidecar 가 곧 푼다(`released:process_shared`), 여기서는 걸 때의 판정을 본다).
    // `either` — 걸려도·거절돼도 맞다(사용자 쪽이 느려지지만 않으면): 다른 출처의 사용자 정보 주소 iframe 은 Chromium 이 막아 문서가 생기지 않는다
    // (실측 — 주소가 빈 첫 문서로 남고 iframe 은 답하지 않는다; 고치기 전에는 그 빈 주소가 사이트 0 이라 거절됐다). 호스트 어림이 `@` 를 넘는지는
    // 순수 시험(`net_policy.hostOfUrl16`)이 본다.
    const Case = struct { name: []const u8, path: []const u8, loop: bool = false, want_refuse: bool, ask: bool = false, ask_first: bool = false, either: bool = false };
    const cases = [_]Case{
        .{ .name = "none", .path = "/pb-u-none", .want_refuse = false },
        .{ .name = "xsite-iframe", .path = "/pb-u-xsite", .want_refuse = false },
        .{ .name = "hidden-blank(hotjar)", .path = "/pb-u-hidden", .want_refuse = false },
        .{ .name = "about:blank+write(gpt)", .path = "/pb-u-gpt", .want_refuse = false },
        .{ .name = "srcdoc", .path = "/pb-u-srcdoc", .want_refuse = false },
        .{ .name = "javascript:", .path = "/pb-u-js", .want_refuse = false },
        .{ .name = "sandbox-srcdoc", .path = "/pb-u-sandbox", .want_refuse = false },
        .{ .name = "nested-blank", .path = "/pb-u-nested", .want_refuse = false },
        .{ .name = "sandbox-scripts", .path = "/pb-u-sbx-js", .want_refuse = false, .ask = true },
        .{ .name = "data:(위험 그대로)", .path = "/pb-u-data", .want_refuse = true },
        .{ .name = "same-site-iframe-self-blank(A7-1)", .path = "/pb-u-selfblank", .want_refuse = true },
        .{ .name = "userinfo-same-site(막힌 iframe)", .path = "/pb-u-userinfo", .want_refuse = true, .either = true },
        .{ .name = "upper-scheme-same-site", .path = "/pb-u-upper", .want_refuse = true, .ask_first = true },
        .{ .name = "user-own-same-site-tab", .path = "/pa-static?usr", .loop = true, .want_refuse = false },
    };
    var line: std.Io.Writer = .fixed(&dbuf);
    var false_refuse: usize = 0;
    var leaks: usize = 0;
    var o: [256]u8 = undefined;
    for (cases) |c| {
        try r.create(2, if (c.loop) emu.uLoop(&u, c.path) else emu.uLocal(&u, c.path));
        r.pump(1200);
        var warm: []const u8 = "-";
        if (c.ask_first) warm = r.ev(2, "ASK('f','x')", &o);
        const warm_ms = msOf(warm);
        const st = try r.emulate(1, perf.cpuOn(4));
        const active = st != null and st.?.active_mask & cpu_bit != 0;
        if (c.ask_first and warm_ms < 0) leaks += 1; // iframe 이 불러와지지 않았다 — 판정할 수 없다
        // 걸렸으면 사용자 쪽이 함께 느려지지 않았는지 잰다(2.5 배면 샘 — 판정의 「실제로 맞는가」).
        var user_ms: i64 = -1;
        if (active) {
            if (c.ask or c.ask_first or c.either) {
                user_ms = msOf(r.ev(2, "ASK('f','x')", &o));
            } else if (!eql(c.name, "xsite-iframe")) {
                user_ms = perf.benchOf(r, 2);
            }
        }
        if (c.want_refuse and active and !c.either) leaks += 1;
        if (!c.want_refuse and !active and !c.either) false_refuse += 1;
        if (user_ms >= 0 and user_ms * 10 >= base * 25) leaks += 1;
        line.print("{s}: 걸림 {} ({s}) 사용자 쪽 {d} ms; ", .{ c.name, active, if (st) |x| @tagName(x.reason) else "-", user_ms }) catch {};
        _ = try r.emulate(1, .{ .browser = 0 });
        recycle(r, 2);
    }
    // 대조: 에이전트 탭 자신에 about:blank iframe(가족) — 걸려야 한다.
    try r.nav(1, emu.uLoop(&u, "/pb-t-blank"));
    r.pump(500);
    const st_self = try r.emulate(1, perf.cpuOn(4));
    const self_ok = st_self != null and st_self.?.active_mask & cpu_bit != 0;
    _ = try r.emulate(1, .{ .browser = 0 });
    // 관찰: 에이전트 탭 자신의 sandbox(allow-scripts) srcdoc 이 CPU 를 함께 받는가 — 받으면 같은 프로세스, 아니면 Chromium 이 sandbox 를 따로 둔다.
    try r.nav(1, emu.uLoop(&u, "/pb-t-sbx-js"));
    r.pump(800);
    const sbx_base = msOf(r.ev(1, "ASK('f','x')", &o));
    const st_sbx = try r.emulate(1, perf.cpuOn(4));
    const sbx_on = msOf(r.ev(1, "ASK('f','x')", &o));
    _ = try r.emulate(1, .{ .browser = 0 });
    line.print("대조(에이전트 탭 자신의 about:blank iframe): 걸림 {}; 기준 {d} ms", .{ self_ok, base }) catch {};
    report(leaks == 0 and self_ok, "b7-embeds-bypass", line.buffered());
    report(false_refuse == 0, "b7-embeds-false-refuse", std.fmt.bufPrint(&o, "걸려야 하는 꼴(다른 사이트 사용자 탭의 물려받는 iframe 등) 중 거절 {d}", .{false_refuse}) catch "");
    report(true, "b7-sandbox-process(obs)", std.fmt.bufPrint(&o, "에이전트 탭 자신의 sandbox(allow-scripts) srcdoc: CPU 전 {d} ms → 4 배 건 뒤 {d} ms (걸림 {}) — 같이 느려지면 같은 프로세스", .{ sbx_base, sbx_on, st_sbx != null and st_sbx.?.active_mask & cpu_bit != 0 }) catch "");
}

// ── A1-1: rAF 묶기 — 주 스레드가 바쁜 동안의 헛폐기, 페이지가 알아채는가 ───────────────────────────────────────

fn b1Jank(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb1j");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-jank"));
    r.pump(1200);
    // 대조: 주 스레드가 쉰다.
    const g0 = try start(r, 1, 2000, false);
    const c = try finishAndFilter(r, g0, 40_000);
    // 긴 작업(4.5 s)이 기록 전부를 덮는다 — 컴포지터 애니메이션만 돈다. 그 프로세스는 가족만 쓴다.
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g = try start(r, 1, 2000, false);
    const d = try finishAndFilter(r, g, 40_000);
    r.pump(3000);
    // 스크린샷과 함께(기본값).
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g2 = try start(r, 1, 2000, true);
    const e = try finishAndFilter(r, g2, 40_000);
    r.pump(3000);
    _ = r.ev(1, "setTimeout(function(){JANK(600)},30),'ok'", &o);
    r.pump(150);
    const g3 = try start(r, 1, 2000, false);
    const f3 = try finishAndFilter(r, g3, 40_000);
    // 관찰: 애니메이션 없는 탭이 기록 내내 막힘.
    r.pump(3000);
    try r.nav(1, emu.uLoop(&u, "/pb-t?still"));
    r.pump(800);
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g4 = try start(r, 1, 2000, false);
    const f4 = try finishAndFilter(r, g4, 40_000);
    report(true, "b1-jank-still(obs)", std.fmt.bufPrint(&dbuf, "애니메이션 없는 탭이 4.5 s 막힌 동안 2 s trace → {s}/{s} 거르기 {s} 남김 {d} 뺌 {d} 프로파일 {} 남의 {s}", .{ stName(f4.st), rsName(f4.st), f4.outcome, f4.kept, f4.comp_dropped, f4.profile, f4.foreign }) catch "");
    report(true, "b1-jank-short(obs)", std.fmt.bufPrint(&dbuf, "긴 작업 0.6 s 가 시작을 덮음 → {s}/{s} 거르기 {s} 남김 {d} 프레임 {d} 남의 {s}", .{ stName(f3.st), rsName(f3.st), f3.outcome, f3.kept, f3.frames, f3.foreign }) catch "");
    // V-A1·결정 12: 주 스레드가 기록 내내 막힌 탭의 trace 는 「다른 탭이 섞였다」 로 버리지 않고 남긴다 — 그 프로세스를 가족만 썼으니 컴포지터도 뺄
    // 것이 없고(뺌 0, 프레임이 있다), 긴 작업은 V8 프로파일 표본으로 보인다. 대조(쉼)는 늘 남긴다.
    const own_ok = eql(c.outcome, "kept") and eql(d.outcome, "kept") and eql(e.outcome, "kept") and d.comp_dropped == 0 and d.profile and e.profile and d.frames > 0;
    report(own_ok, "b1-jank-compositor", std.fmt.bufPrint(&dbuf, "대조(쉼) {s} 프레임 {d} | 긴 작업 4.5 s 동안 2 s trace → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 프레임 {d} 뺌 {d} 프로파일 {} 남의 {s} | 스크린샷 켜고 → {s} 남김 {d} 프레임 {d} 프로파일 {} 남의 {s}", .{ c.outcome, c.frames, stName(d.st), rsName(d.st), if (d.st) |x| x.shared_process else false, d.outcome, d.kept, d.frames, d.comp_dropped, d.profile, d.foreign, e.outcome, e.kept, e.frames, e.profile, e.foreign }) catch "");
    // 결정 12 대조 — 같은 렌더러 프로세스에 사용자 탭의 같은 사이트 iframe(컴포지터 애니메이션)이 있다: 누구 것인지 가를 수 없는 이벤트만 빼고 남긴다
    // (뺌 > 0, 남의 컴포지터 프레임도 프로파일도 결과에 없다).
    try r.nav(1, emu.uLoop(&u, "/pb-jank?shared"));
    try r.create(2, emu.uLocal(&u, "/pa-user-anim2"));
    r.pump(1500);
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g5 = try start(r, 1, 2000, false);
    const s5 = try finishAndFilter(r, g5, 40_000);
    const shared5 = if (s5.st) |x| x.shared_process else false;
    report(shared5 and eql(s5.outcome, "kept") and s5.comp_dropped > 0 and !s5.profile and s5.frames == 0, "b1-jank-shared", std.fmt.bufPrint(&dbuf, "같은 프로세스에 사용자 iframe 의 컴포지터 애니메이션 + 막힌 탭 → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 뺌 {d} 프레임 {d} 프로파일 {} 남의 {s}", .{ stName(s5.st), rsName(s5.st), shared5, s5.outcome, s5.kept, s5.comp_dropped, s5.frames, s5.profile, s5.foreign }) catch "");
    recycle(r, 2);
    r.pump(3000);
    // 결정 12 대조 — 사용자 탭의 같은 사이트 iframe 이 공유 주 스레드를 막는다(그 일의 이벤트가 남의 프레임을 싣는다): 여전히 통째로 버린다.
    try r.nav(1, emu.uLoop(&u, "/pb-t?victim"));
    try r.create(2, emu.uLocal(&u, "/pb-u-kid-jank"));
    r.pump(2000);
    const g6 = try start(r, 1, 2000, false);
    const s6 = try finishAndFilter(r, g6, 40_000);
    report(eql(s6.outcome, "mixed_content"), "b1-jank-foreign", std.fmt.bufPrint(&dbuf, "사용자 탭의 같은 사이트 iframe 이 공유 주 스레드를 막는다 → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 남의 {s}", .{ stName(s6.st), rsName(s6.st), if (s6.st) |x| x.shared_process else false, s6.outcome, s6.kept, s6.foreign }) catch "");
    recycle(r, 2);
}

fn b1Detect(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb1d");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o1: [200]u8 = undefined;
    var o2: [200]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-detect"));
    r.pump(1200);
    var before_b: [200]u8 = undefined;
    const before = std.fmt.bufPrint(&before_b, "{s}", .{r.ev(1, "DET()", &o1)}) catch "?";
    var outs: [3][]const u8 = .{ "-", "-", "-" };
    var ob: [3][32]u8 = undefined;
    for (0..3) |i| {
        const g = try start(r, 1, 1500, false);
        const d = try finishAndFilter(r, g, 40_000);
        outs[i] = std.fmt.bufPrint(&ob[i], "{s}/{d}", .{ d.outcome, d.frames }) catch "?";
    }
    const after = r.ev(1, "DET()", &o2);
    const hooked0 = contains(after, "\"hooked\":0") and contains(after, "\"loaf\":0") and contains(after, "\"mut\":0");
    const globals0 = eql(before, after); // 전역 수(탐침 페이지가 스스로 만든 3)·관찰 값이 trace 세 번 뒤에도 같다
    report(hooked0 and globals0 and eql(outs[0][0..@min(outs[0].len, 4)], "kept"), "b1-isolated-raf-invisible", std.fmt.bufPrint(&dbuf, "페이지가 rAF 를 가로채 센다·LoAF·전역 수·변이 관찰 — 전 {s} | trace 3 번(거르기/프레임) {s} {s} {s} | 뒤 {s}", .{ before, outs[0], outs[1], outs[2], after }) catch "");
}

// ── A2: 가족에 끼어들기 — noopener 팝업, 사용자가 연 같은 사이트 탭, 사용자 탭이 연 같은 사이트 팝업 ──────────────────────

fn b2Family(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb2");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-pop2"));
    r.pump(500);
    // (1) 기록 중 noopener 팝업(에이전트의 몸짓).
    try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
    r.pump(200);
    const g1 = try start(r, 1, 3000, false);
    r.pump(300);
    try r.host.send(.{ .new_tab_credit = 1 });
    const op1 = r.evWith(1, "window.open('/pa-busy?nop','_blank','noopener'),'ok'", &o, true);
    _ = r.until(Run.loadsAt, 4, 1, 8000);
    const d1 = try finishAndFilter(r, g1, 40_000);
    var b1: [64]u8 = undefined;
    const s1 = std.fmt.bufPrint(&b1, "{s} 만들어짐 {} → {s}/{s} 거르기 {s} 남의 {s}", .{ op1, r.created[4], stName(d1.st), rsName(d1.st), d1.outcome, d1.foreign }) catch "?";
    // 그 팝업에 사람의 누름(가족이면 버림, 아니면 그대로) — 다음 trace 중.
    const g1b = try start(r, 1, 2000, false);
    r.pump(300);
    r.userClick(4, 50, 50);
    const st1b = perf.waitFinished(r, g1b, 30_000);
    // (2) 기록 중 사용자가 같은 사이트 탭을 따로 연다(maru 의 새 탭 — 연 탭 없음).
    const g2 = try start(r, 1, 3000, false);
    r.pump(300);
    try r.create(2, emu.uLoop(&u, "/pa-busy?usertab"));
    const d2 = try finishAndFilter(r, g2, 40_000);
    // 그 사용자 탭에 사람 입력 — 가족이 아니면 버리지 않는다.
    const g2b = try start(r, 1, 2000, false);
    r.pump(300);
    r.userClick(2, 50, 50);
    const st2b = perf.waitFinished(r, g2b, 30_000);
    // (3) 사용자 탭(localhost)이 기록 중 같은 사이트(127.0.0.1) 팝업을 연다 — 연 탭은 사용자 탭.
    try r.create(3, emu.uLocal(&u, "/pb-uopen"));
    try r.host.send(.{ .popup_reserve = .{ .browser = 5 } });
    r.pump(300);
    var pb: [160]u8 = undefined;
    const g3 = try start(r, 1, 3000, false);
    r.pump(300);
    try r.host.send(.{ .new_tab_credit = 1 });
    const op3 = r.evWith(3, std.fmt.bufPrint(&pb, "window.p=window.open('http://127.0.0.1:{d}/pa-busy?upop','up'),'ok'", .{emu.port}) catch "0", &o, true);
    _ = r.until(Run.loadsAt, 5, 1, 8000);
    const d3 = try finishAndFilter(r, g3, 40_000);
    const ok = (st1b != null and st1b.?.state == .discarded) and (st2b != null and st2b.?.state == .done);
    report(ok, "b2-family-joins", std.fmt.bufPrint(&dbuf, "(1) 기록 중 noopener 팝업 {s} | 그 팝업에 사람 누름 → {s}/{s} | (2) 기록 중 사용자가 같은 사이트 탭을 따로 연다 → {s}/{s} 거르기 {s} 남의 {s} | 그 탭에 사람 누름 → {s}/{s} | (3) 사용자 탭이 기록 중 같은 사이트 팝업({s} 만들어짐 {}) → {s}/{s} 거르기 {s} 남의 {s}", .{ s1, stName(st1b), rsName(st1b), stName(d2.st), rsName(d2.st), d2.outcome, d2.foreign, stName(st2b), rsName(st2b), op3, r.created[5], stName(d3.st), rsName(d3.st), d3.outcome, d3.foreign }) catch "");
}

// ── A3-1: 사람 입력과 에이전트 입력이 섞일 때 ───────────────────────────────────────────────────────────────

fn b3Mixed(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb3");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    try r.host.send(.{ .set_focus = .{ .browser = 1, .value = true } });
    r.pump(600);
    _ = r.ev(1, "document.getElementById('i').focus(),'f'", &o);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .cpu = true, .network = true }, .cpu_rate = 2, .latency_ms = 100 });
    const g = try start(r, 1, 3000, false);
    r.pump(300);
    // 에이전트(DevTools): 굴림·글 넣기·키.
    _ = r.call(1, "Input.dispatchMouseEvent", "{\"type\":\"mouseWheel\",\"x\":100,\"y\":200,\"deltaX\":0,\"deltaY\":240}", 5000) catch null;
    _ = r.call(1, "Input.insertText", "{\"text\":\"agent한\"}", 5000) catch null;
    _ = r.call(1, "Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"a\",\"text\":\"a\"}", 5000) catch null;
    _ = r.call(1, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"a\"}", 5000) catch null;
    _ = r.call(1, "Input.imeSetComposition", "{\"text\":\"글\",\"selectionStart\":1,\"selectionEnd\":1}", 5000) catch null;
    _ = r.call(1, "Input.insertText", "{\"text\":\"글\"}", 5000) catch null;
    // 사람(maru): 옮김·끌기 들어옴/위/나감(놓지 않음)·조합 취소·키 뗌만.
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        r.host.send(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 20 + i * 30, .y = 200 } } }) catch {};
        r.pump(20);
    }
    r.host.send(.{ .drag_data = .{ .browser = 1, .kind = .text, .bytes = "NOTDROPPED" } }) catch {};
    r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .enter, .point = .{ .x = 100, .y = 20 }, .allowed = 1 } }) catch {};
    r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .over, .point = .{ .x = 100, .y = 20 }, .allowed = 1 } }) catch {};
    r.host.send(.{ .drag_target = .{ .browser = 1, .kind = .leave } }) catch {};
    r.host.send(.{ .ime_cancel_composition = 1 }) catch {};
    r.host.send(.{ .key = .{ .browser = 1, .kind = .up, .native_key_code = 0, .character = 'z', .unmodified_character = 'z' } }) catch {};
    r.host.send(.{ .capture_lost = 1 }) catch {};
    r.pump(400);
    const st = perf.waitFinished(r, g, 30_000);
    const em = r.st[1];
    const val = r.ev(1, "document.getElementById('i').value", &o);
    const ok = st != null and st.?.state == .done and em != null and em.?.released_mask == 0;
    report(ok, "b3-agent-input-not-human", std.fmt.bufPrint(&dbuf, "에이전트 굴림·글·키·조합 + 사람 옮김·끌기(놓지 않음)·조합 취소·키 뗌·capture_lost → trace {s}/{s}, 조건 풀림 0x{x}, 칸 '{s}'", .{ stName(st), rsName(st), if (em) |e| e.released_mask else 0, val }) catch "");
    _ = try r.emulate(1, .{ .browser = 0 });
}

// ── A6-1: 기록 중 숨어 켠 focus 흉내 — 끝 경로마다 꺼지는가 ─────────────────────────────────────────────────

const EndKind = enum { abort, human, stop, renderer_kill, tab_close_other };

fn b6HideEnds(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    for (std.enums.values(EndKind)) |k| {
        var sess: Session = undefined;
        try emu.open(&sess, host_path, root, "pb6");
        defer sess.deinit();
        const r = &sess.run;
        var u: [256]u8 = undefined;
        var o1: [200]u8 = undefined;
        var o2: [200]u8 = undefined;
        var o3: [200]u8 = undefined;
        try r.create(1, emu.uLoop(&u, "/pb-t"));
        try r.create(2, emu.uLocal(&u, "/pb-t?other"));
        try r.host.send(.{ .set_hidden = .{ .browser = 2, .value = true } });
        r.pump(500);
        const g = try start(r, 1, 6000, false);
        r.pump(300);
        try r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
        r.pump(500);
        const during = vis(r, 1, &o1);
        switch (k) {
            .abort => sendTrace(r, 1, g, .abort),
            .human => r.host.send(.{ .key = .{ .browser = 1, .kind = .raw_down, .native_key_code = 0, .character = 'a', .unmodified_character = 'a' } }) catch {},
            .stop => sendTrace(r, 1, g, .stop),
            .renderer_kill => _ = r.killRenderers(),
            .tab_close_other => {}, // 다른 탭 닫힘은 끝이 아니다 — 시간으로 끝난다
        }
        if (k == .tab_close_other) try r.host.send(.{ .destroy_browser = 2 });
        const st = perf.waitFinished(r, g, 30_000);
        r.pump(600);
        if (k == .renderer_kill) {
            try r.action(1, .reload);
            r.pump(800);
        }
        const after = vis(r, 1, &o2);
        const other = if (k == .tab_close_other) "-" else vis(r, 2, &o3);
        if (!eql(during, "visible") or !eql(after, "hidden")) bad += 1;
        line.print("{s}: 중 {s} → {s}/{s} → 뒤 {s} (다른 숨은 탭 {s}); ", .{ @tagName(k), during, stName(st), rsName(st), after, other }) catch {};
    }
    report(bad == 0, "b6-hidden-mid-ends", line.buffered());
}

// ── 15: 렌더러 죽음 중 trace·다음 trace, 판정자 쪽 sidecar 재시작 ─────────────────────────────────────────────

fn b15Death(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&dbuf);
    var ok = true;
    {
        var sess: Session = undefined;
        try emu.open(&sess, host_path, root, "pb15");
        defer sess.deinit();
        const r = &sess.run;
        try r.create(1, emu.uLoop(&u, "/pb-t"));
        try r.create(2, emu.uLocal(&u, "/pb-t?b"));
        r.pump(500);
        // 렌더러 죽음 — trace 는 계속(t5), 다음 trace 가 된다.
        const g = try start(r, 1, 2500, false);
        r.pump(500);
        const killed = r.killRenderers();
        const st = perf.waitFinished(r, g, 30_000);
        r.pump(500);
        try r.action(1, .reload);
        r.pump(500);
        const g2 = try start(r, 1, 1500, false);
        const st2 = perf.waitFinished(r, g2, 30_000);
        line.print("렌더러 {d} 죽임 → {s}/{s}; 다음 trace → {s}/{s}; ", .{ killed, stName(st), rsName(st), stName(st2), rsName(st2) }) catch {};
        if (st2 == null or st2.?.state != .done) ok = false;
        // 기록 중 탭 닫힘 → 다른 탭의 다음 trace(이미 판정자 tr-tab-closed — 여기서는 멈춤 요청 직후 닫힘).
        const g3 = try start(r, 1, 5000, false);
        r.pump(300);
        sendTrace(r, 1, g3, .stop);
        try r.host.send(.{ .destroy_browser = 1 });
        const st3 = perf.waitFinished(r, g3, 30_000);
        r.pump(800);
        const g4 = try start(r, 2, 1500, false);
        const st4 = perf.waitFinished(r, g4, 30_000);
        line.print("멈춤 요청 직후 탭 닫힘 → {s}/{s}; 다른 탭 다음 trace → {s}/{s}; ", .{ stName(st3), rsName(st3), stName(st4), rsName(st4) }) catch {};
        if (st4 == null or st4.?.state != .done) ok = false;
        // 기록 중 sidecar 를 죽인다(앱 종료·sidecar 재시작의 꼴) — deinit 이 정리한다.
        _ = try start(r, 2, 8000, false);
        r.pump(300);
        _ = std.c.kill(r.host.pid, std.c.SIG.KILL);
        r.pump(500);
    }
    // 새 sidecar(재시작) — 첫 trace 가 「already started」 없이 된다.
    var sess2: Session = undefined;
    try emu.open(&sess2, host_path, root, "pb15");
    defer sess2.deinit();
    const r2 = &sess2.run;
    try r2.create(1, emu.uLoop(&u, "/pb-t?again"));
    r2.pump(300);
    const g5 = try start(r2, 1, 1500, false);
    const st5 = perf.waitFinished(r2, g5, 30_000);
    line.print("sidecar 를 기록 중 SIGKILL → 같은 프로필로 새 sidecar 의 첫 trace → {s}/{s}", .{ stName(st5), rsName(st5) }) catch {};
    if (st5 == null or st5.?.state != .done) ok = false;
    report(ok, "b15-death-restart", line.buffered());
}

/// 15: 기록하는 탭의 렌더러가 멈췄다(60 s 무한 루프 꼴) — 전역 trace 가 묶이는가, 다른 탭의 다음 trace 가 되는가.
fn b15Hang(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb15h");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    try r.create(2, emu.uLocal(&u, "/pb-t?b"));
    r.pump(500);
    // 멈춤 길이 — 환경 `B15_JANK_MS`(기본 8000: sidecar 의 시작 시한 5 s 를 넘겨 늦은 시작 답이 오게 — 고치기 전에는 60 s·14 s·8 s 모두 죽었다).
    const jank_ms: u32 = if (std.c.getenv("B15_JANK_MS")) |v| std.fmt.parseInt(u32, std.mem.span(v), 10) catch 8000 else 8000;
    var jb: [96]u8 = undefined;
    _ = r.ev(1, std.fmt.bufPrint(&jb, "setTimeout(function(){{JANK({d})}},30),'ok'", .{jank_ms}) catch "0", &o);
    r.pump(200);
    const t0 = os.nowMs();
    const g = try start(r, 1, 2000, false);
    const d = try finishAndFilter(r, g, 60_000);
    const t1 = os.nowMs();
    // 다른 탭의 다음 trace — 될 때까지 2 s 마다(최대 150 s), 실패의 까닭을 센다.
    var tries: usize = 0;
    var busy_n: usize = 0;
    var other_n: usize = 0;
    var d2: Done = .{ .st = null, .outcome = "-", .kept = 0, .shots = 0, .foreign = "-" };
    var ok_at: i64 = -1;
    while (os.nowMs() - t1 < 150_000) : (tries += 1) {
        const g2 = try start(r, 2, 1000, false);
        d2 = try finishAndFilter(r, g2, 60_000);
        if (d2.st != null and d2.st.?.state == .done) {
            ok_at = os.nowMs() - t0;
            break;
        }
        if (d2.st != null and d2.st.?.reason == .busy) busy_n += 1 else other_n += 1;
        r.pump(2000);
    }
    // 크래시 갈래(V-15): 늦은 시작 답 뒤에도 sidecar 가 산다 — 3 s 뒤 다른 탭의 eval(kill(pid, 0) 은 거두지 않은 좀비에도 0 이라 쓰지 않는다).
    r.pump(3000);
    var eb: [64]u8 = undefined;
    const e2 = std.fmt.bufPrint(&eb, "{s}", .{r.ev(2, "1+1", &o)}) catch "?";
    const alive = eql(e2, "2");
    report(alive and ok_at >= 0 and ok_at < 40_000 and eql(d2.outcome, "kept"), "b15-renderer-hang", std.fmt.bufPrint(&dbuf, "기록하는 탭이 {d} ms 멈춤 → {s}/{s} 거르기 {s} 남의 {s} ({d} ms) | 다른 탭의 다음 trace: {d} 번 시도(busy {d}·그 밖 {d}) → 처음 된 때 멈춤 시작부터 {d} ms, {s}/{s} 거르기 {s} | 3 s 뒤 sidecar 살아 있음 {} (다른 탭 eval {s})", .{ jank_ms, stName(d.st), rsName(d.st), d.outcome, d.foreign, t1 - t0, tries + 1, busy_n, other_n, ok_at, stName(d2.st), rsName(d2.st), d2.outcome, alive, e2 }) catch "");
}

/// 15 대조·변형: (a) trace 없이 같은 멈춤 — sidecar 가 사는가, (b) **사용자 탭**(localhost)의 렌더러가 멈춘 동안 에이전트 탭(127.0.0.1)을 trace.
fn b15HangVariants(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [256]u8 = undefined;
    var o: [64]u8 = undefined;
    var line: std.Io.Writer = .fixed(&dbuf);
    var ok = true;
    {
        var sess: Session = undefined;
        try emu.open(&sess, host_path, root, "pb15c");
        defer sess.deinit();
        const r = &sess.run;
        try r.create(1, emu.uLoop(&u, "/pb-t"));
        try r.create(2, emu.uLocal(&u, "/pb-t?b"));
        r.pump(500);
        _ = r.ev(1, "setTimeout(function(){JANK(60000)},30),'ok'", &o);
        r.pump(12_000);
        const e2 = r.ev(2, "1+1", &o);
        const alive = eql(e2, "2"); // 좀비도 kill(pid, 0) 에 0 — eval 로 본다
        line.print("(a) trace 없이 탭 1 이 60 s 멈춤 → 12 s 뒤 sidecar 살아 있음 {}, 다른 탭 eval {s}; ", .{ alive, e2 }) catch {};
        if (!alive) ok = false;
    }
    {
        var sess: Session = undefined;
        try emu.open(&sess, host_path, root, "pb15u");
        defer sess.deinit();
        const r = &sess.run;
        try r.create(1, emu.uLoop(&u, "/pb-t"));
        try r.create(2, emu.uLocal(&u, "/pb-t?user"));
        r.pump(500);
        _ = r.ev(2, "setTimeout(function(){JANK(60000)},30),'ok'", &o);
        r.pump(200);
        const g = perf.startTrace(r, 1, 2000, false) catch 0;
        const st = perf.waitFinished(r, g, 20_000);
        r.pump(4000);
        var e1b: [64]u8 = undefined;
        const e1 = std.fmt.bufPrint(&e1b, "{s}", .{r.ev(1, "1+1", &o)}) catch "?";
        const alive = eql(e1, "2");
        line.print("(b) 사용자 탭(localhost) 렌더러가 멈춘 동안 에이전트 탭 trace → {s}/{s}, 4 s 뒤 sidecar 살아 있음 {}, 에이전트 탭 eval {s}", .{ stName(st), rsName(st), alive, e1 }) catch {};
        if (!alive) ok = false;
    }
    report(ok, "b15-hang-variants", line.buffered());
}

/// 15: 시작 답(`Tracing.start`)이 오기 전에 버림·abort — 늦게 온 시작 답 안에서 `Tracing.end` 를 낸다(draining). sidecar 가 사는가.
fn b15EarlyEnd(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var u: [256]u8 = undefined;
    var o: [64]u8 = undefined;
    var line: std.Io.Writer = .fixed(&dbuf);
    var dead: usize = 0;
    const Kind = enum { human_click, abort, none };
    for (std.enums.values(Kind)) |k| {
        var sess: Session = undefined;
        var nb: [32]u8 = undefined;
        try emu.open(&sess, host_path, root, std.fmt.bufPrint(&nb, "pb15e_{s}", .{@tagName(k)}) catch "pb15e");
        defer sess.deinit();
        const r = &sess.run;
        try r.create(1, emu.uLoop(&u, "/pb-t"));
        try r.create(2, emu.uLocal(&u, "/pb-t?b"));
        r.pump(500);
        const g = try perf.startTrace(r, 1, 3000, false);
        switch (k) {
            .human_click => {
                r.host.send(.{ .mouse = .{ .browser = 1, .kind = .down, .point = .{ .x = 50, .y = 50 }, .click_count = 1 } }) catch {};
                r.host.send(.{ .mouse = .{ .browser = 1, .kind = .up, .point = .{ .x = 50, .y = 50 }, .click_count = 1 } }) catch {};
            },
            .abort => sendTrace(r, 1, g, .abort),
            .none => {},
        }
        const st = perf.waitFinished(r, g, 20_000);
        r.pump(3000);
        var eb: [64]u8 = undefined;
        const e2 = std.fmt.bufPrint(&eb, "{s}", .{r.ev(2, "1+1", &o)}) catch "?";
        const alive = eql(e2, "2"); // kill(pid, 0) 은 거두지 않은 좀비에도 0 — 다른 탭의 eval 로 본다
        if (!alive) dead += 1;
        line.print("{s}: {s}/{s}, 3 s 뒤 sidecar 살아 있음 {} (다른 탭 eval {s}); ", .{ @tagName(k), stName(st), rsName(st), alive, e2 }) catch {};
    }
    report(dead == 0, "b15-end-before-start-answer", line.buffered());
}

/// 15: 시작 창의 길이 — `trace{start}` 를 보낸 때부터 `recording` 까지(그 사이의 버림·abort 가 위 탐침의 길이다). 보이는 탭·숨은 탭.
fn b15Window(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb15w");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    try r.create(2, emu.uLocal(&u, "/pb-jank"));
    try r.host.send(.{ .set_hidden = .{ .browser = 2, .value = true } });
    r.pump(500);
    var line: std.Io.Writer = .fixed(&dbuf);
    for ([_]u64{ 1, 2 }) |b| {
        var mn: i64 = std.math.maxInt(i64);
        var mx: i64 = 0;
        var sum: i64 = 0;
        for (0..6) |_| {
            const t0 = os.nowMs();
            const g = try perf.startTrace(r, b, 1000, false);
            _ = r.until(perf.recordingAt, g, 0, 8000);
            const dt = os.nowMs() - t0;
            mn = @min(mn, dt);
            mx = @max(mx, dt);
            sum += dt;
            _ = perf.waitFinished(r, g, 30_000);
            r.pump(300);
        }
        line.print("{s} 탭: start→recording 최소 {d}·평균 {d}·최대 {d} ms(6 번); ", .{ if (b == 1) "보이는" else "숨은", mn, @divTrunc(sum, 6), mx }) catch {};
    }
    report(true, "b15-start-window(obs)", line.buffered());
}

/// 11: maru 를 거친 DevTools 호출로 조건·trace 를 scope·나눔 검사 없이 거는 길이 막혔는가(대조: 막지 않는 메서드).
fn b11Guard(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb11");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(300);
    const base = perf.benchOf(r, 1);
    var line: std.Io.Writer = .fixed(&dbuf);
    var leaked: usize = 0;
    const Call = struct { m: []const u8, p: []const u8 };
    const calls = [_]Call{
        .{ .m = "Emulation.setCPUThrottlingRate", .p = "{\"rate\":6}" },
        .{ .m = "Emulation.setFocusEmulationEnabled", .p = "{\"enabled\":true}" },
        .{ .m = "Network.emulateNetworkConditionsByRule", .p = "{\"matchedNetworkConditions\":[{\"urlPattern\":\"\",\"latency\":900,\"downloadThroughput\":-1,\"uploadThroughput\":-1}]}" },
        .{ .m = "Network.emulateNetworkConditions", .p = "{\"offline\":false,\"latency\":900,\"downloadThroughput\":-1,\"uploadThroughput\":-1}" },
        .{ .m = "Network.overrideNetworkState", .p = "{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}" },
        .{ .m = "Network.enable", .p = "{}" },
        .{ .m = "Network.disable", .p = "{}" },
        .{ .m = "Tracing.start", .p = "{}" },
        .{ .m = "IO.read", .p = "{\"handle\":\"1\"}" },
    };
    for (calls) |c| {
        const st = r.call(1, c.m, c.p, 5000) catch null;
        const refused = st != null and st.? == .invalid_request;
        if (!refused) leaked += 1;
        line.print("{s} {s}; ", .{ c.m, if (st) |x| @tagName(x) else "timeout" }) catch {};
    }
    var o: [64]u8 = undefined;
    const after = perf.benchOf(r, 1);
    const ft = r.ev(1, "ft('/x?g')", &o);
    const on = r.ev(1, "String(navigator.onLine)", &o);
    _ = on;
    const ok = leaked == 0 and after * 10 < base * 16 and ftMs(ft) < 300;
    line.print("| 뒤 bench {d} → {d} ms, 가져오기 {s}", .{ base, after, ft }) catch {};
    const ctl = r.call(1, "Page.getFrameTree", "{}", 5000) catch null;
    line.print(", 대조 Page.getFrameTree {s}", .{if (ctl) |x| @tagName(x) else "timeout"}) catch {};
    report(ok and ctl != null and ctl.? == .ok, "b11-devtools-guard", line.buffered());
}

// ── 16: trace 중 이동 — 다른 사이트, 리다이렉트, 다운로드 ───────────────────────────────────────────────────

fn b16Nav(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb16");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(500);
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    const Step = struct { name: []const u8, url_local: bool, path: []const u8 };
    const steps = [_]Step{
        .{ .name = "다른 사이트", .url_local = true, .path = "/pb-t?x" },
        .{ .name = "되돌아옴", .url_local = false, .path = "/pb-t?y" },
        .{ .name = "리다이렉트(다른 사이트로)", .url_local = false, .path = "/pb-redir" },
        .{ .name = "다운로드", .url_local = true, .path = "/pb-dl" },
    };
    for (steps) |s| {
        const g = try start(r, 1, 2500, false);
        r.pump(400);
        r.host.send(.{ .navigate = .{ .browser = 1, .url = if (s.url_local) emu.uLocal(&u, s.path) else emu.uLoop(&u, s.path) } }) catch {};
        const d = try finishAndFilter(r, g, 40_000);
        if (!eql(d.outcome, "kept")) bad += 1;
        line.print("{s}: {s}/{s} 거르기 {s} 남김 {d} 남의 {s}; ", .{ s.name, stName(d.st), rsName(d.st), d.outcome, d.kept, d.foreign }) catch {};
        r.pump(500);
    }
    report(bad == 0, "b16-nav-during-trace", line.buffered());
}

/// 16: 사람의 이동(주소창 `navigate{user}`·뒤로 `nav_action{user}`)은 trace 를 버리고 조건을 푼다, 멈춤·에이전트의 이동은 아니다 — sidecar 와
/// maru 가 함께 쓰는 가름(`human_use.touchOf`)의 실제 CEF 판정.
fn b16HumanNav(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb16h");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(500);
    try r.nav(1, emu.uLoop(&u, "/pb-t?two"));
    r.pump(500);
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    const Step = struct { name: []const u8, m: msg.Message, want_discard: bool };
    const steps = [_]Step{
        .{ .name = "에이전트 이동(user 거짓)", .m = .{ .navigate = .{ .browser = 1, .url = "", .user = false } }, .want_discard = false },
        .{ .name = "사람의 멈춤", .m = .{ .nav_action = .{ .browser = 1, .action = .stop, .user = true } }, .want_discard = false },
        .{ .name = "사람의 주소창 이동", .m = .{ .navigate = .{ .browser = 1, .url = "", .user = true } }, .want_discard = true },
        .{ .name = "사람의 뒤로", .m = .{ .nav_action = .{ .browser = 1, .action = .back, .user = true } }, .want_discard = true },
    };
    for (steps) |s| {
        _ = try r.emulate(1, perf.cpuOn(2));
        const g = try start(r, 1, 2000, false);
        r.pump(300);
        var m = s.m;
        if (m == .navigate) m.navigate.url = emu.uLoop(&u, "/pb-t?nav");
        r.host.send(m) catch {};
        const st = perf.waitFinished(r, g, 30_000);
        r.pump(400);
        const em = r.st[1];
        const released = em != null and em.?.released_mask & cpu_bit != 0 and em.?.cpu_release == .human_input;
        const discarded = st != null and st.?.state == .discarded and st.?.reason == .human_input;
        if (discarded != s.want_discard or released != s.want_discard) bad += 1;
        line.print("{s}: trace {s}/{s}, CPU 풀림 {}; ", .{ s.name, stName(st), rsName(st), released }) catch {};
        _ = try r.emulate(1, .{ .browser = 0 });
        r.pump(300);
    }
    report(bad == 0, "b16-human-nav", line.buffered());
}

// ── 17: CPU·네트워크·W9e① 흉내를 함께 걸고 하나만 푼다 ───────────────────────────────────────────────────────

fn b17Combo(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb17");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var f: [6][64]u8 = undefined;
    var tz: [6][64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(400);
    const base = perf.benchOf(r, 1);
    const tz_expr = "Intl.DateTimeFormat().resolvedOptions().timeZone+' '+navigator.onLine";
    const all: msg.Emulation = .{ .browser = 0, .flags = .{ .timezone = true, .cpu = true, .network = true }, .timezone = "Asia/Kathmandu", .cpu_rate = 4, .latency_ms = 400 };
    _ = try r.emulate(1, all);
    const c1 = perf.benchOf(r, 1);
    const n1 = r.ev(1, "ft('/x?c1')", &f[0]);
    const t1 = r.ev(1, tz_expr, &tz[0]);
    // CPU 만 푼다.
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true, .network = true }, .timezone = "Asia/Kathmandu", .latency_ms = 400 });
    const c2 = perf.benchOf(r, 1);
    const n2 = r.ev(1, "ft('/x?c2')", &f[1]);
    const t2 = r.ev(1, tz_expr, &tz[1]);
    // 네트워크만 푼다(다시 CPU 를 걸고).
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true, .cpu = true }, .timezone = "Asia/Kathmandu", .cpu_rate = 4 });
    const c3 = perf.benchOf(r, 1);
    const n3 = r.ev(1, "ft('/x?c3')", &f[2]);
    // offline + cpu → offline 만 푼다.
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true, .cpu = true, .network = true, .offline = true }, .timezone = "Asia/Kathmandu", .cpu_rate = 4 });
    const n4 = r.ev(1, "ft('/x?c4')", &f[3]);
    const t4 = r.ev(1, tz_expr, &tz[3]);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true, .cpu = true }, .timezone = "Asia/Kathmandu", .cpu_rate = 4 });
    const n5 = r.ev(1, "ft('/x?c5')", &f[4]);
    const t5 = r.ev(1, tz_expr, &tz[4]);
    const c5 = perf.benchOf(r, 1);
    // 모두 지움(--clear).
    _ = try r.emulate(1, .{ .browser = 0 });
    const c6 = perf.benchOf(r, 1);
    const n6 = r.ev(1, "ft('/x?c6')", &f[5]);
    const t6 = r.ev(1, tz_expr, &tz[5]);
    const slow = struct {
        fn is(x: i64, b: i64) bool {
            return x * 10 >= b * 25;
        }
    }.is;
    const ok = slow(c1, base) and ftMs(n1) >= 390 and contains(t1, "Katmandu") and !slow(c2, base) and ftMs(n2) >= 390 and contains(t2, "Katmandu") and slow(c3, base) and ftMs(n3) < 300 and contains(n4, "err") and contains(t4, "false") and contains(n5, "ok") and contains(t5, "true") and slow(c5, base) and !slow(c6, base) and ftMs(n6) < 300 and !contains(t6, "Katmandu");
    report(ok, "b17-conditions-partial-clear", std.fmt.bufPrint(&dbuf, "기준 {d} ms | 셋 {d} ms·{s}·{s} | CPU 풂 {d} ms·{s}·{s} | 망 풂 {d} ms·{s} | offline+cpu {s}·{s} → offline 풂 {s}·{s}·{d} ms | 모두 지움 {d} ms·{s}·{s}", .{ base, c1, n1, t1, c2, n2, t2, c3, n3, n4, t4, n5, t5, c5, c6, n6, t6 }) catch "");
}

// ── 18: W9d① 기록·W9d③ 막기와 조건 — Network 도메인 공유 ─────────────────────────────────────────────────────

fn b18W9d(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb18");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var f: [8][64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-t"));
    r.pump(400);
    try r.host.send(.{ .net_watch = .{ .browser = 1, .on = true, .full = true, .any_host = true } });
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 1 } });
    r.pump(400);
    var pat_buf: [128]u8 = undefined;
    var nb: msg.NetBlock = .{ .browser = 1, .generation = 1, .count = 1 };
    nb.rules[0] = .{ .id = 1, .site = "127.0.0.1", .pattern = std.fmt.bufPrint(&pat_buf, "http://127.0.0.1:{d}/xb*", .{emu.port}) catch "" };
    try r.host.send(.{ .net_block = nb });
    r.pump(400);
    const b0 = r.ev(1, "ft('/xb0')", &f[0]);
    const a0 = netBegins(r, 1, "ft('/x?a0')", &f[1]);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true }, .latency_ms = 400 });
    const a1 = netBegins(r, 1, "ft('/x?a1')", &f[2]);
    _ = try r.emulate(1, .{ .browser = 0 });
    const a2 = netBegins(r, 1, "ft('/x?a2')", &f[3]);
    const b2 = r.ev(1, "ft('/xb2')", &f[4]);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    _ = try r.emulate(1, .{ .browser = 0 });
    const a3 = netBegins(r, 1, "ft('/x?a3')", &f[5]);
    const b3 = r.ev(1, "ft('/xb3')", &f[6]);
    // 기록을 끄는 동안 조건은 남는가.
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true }, .latency_ms = 400 });
    try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
    r.pump(300);
    const a4 = r.ev(1, "ft('/x?a4')", &f[7]);
    _ = try r.emulate(1, .{ .browser = 0 });
    const ok = contains(b0, "err") and a0.n > 0 and a1.n > 0 and ftMs(a1.res) >= 390 and a2.n > 0 and ftMs(a2.res) < 300 and contains(b2, "err") and a3.n > 0 and contains(a3.res, "ok") and contains(b3, "err") and ftMs(a4) >= 390;
    report(ok, "b18-w9d-shared-network", std.fmt.bufPrint(&dbuf, "막기 {s} | 기록 net_begin: 처음 {d}({s}) · 지연 {d}({s}) · 지연 풂 {d}({s}) 막기 {s} · offline→풂 {d}({s}) 막기 {s} | 기록 끈 뒤 지연 {s}", .{ b0, a0.n, a0.res, a1.n, a1.res, a2.n, a2.res, b2, a3.n, a3.res, b3, a4 }) catch "");
}

const Nb = struct { n: u32, res: []const u8 };

/// 식을 돌리는 동안 그 탭의 `net_begin` 수(W9d① 기록이 살아 있는가).
fn netBegins(r: *Run, b: u64, expr: []const u8, out: []u8) Nb {
    net_begin_count = 0;
    net_begin_browser = b;
    emu.extra_hook = countNetBegin;
    defer emu.extra_hook = null;
    const res = r.ev(b, expr, out);
    r.pump(300);
    return .{ .n = net_begin_count, .res = res };
}

var net_begin_count: u32 = 0;
var net_begin_browser: u64 = 0;
fn countNetBegin(m: msg.Message) void {
    switch (m) {
        .net_begin => |v| if (v.browser == net_begin_browser) {
            net_begin_count += 1;
        },
        else => {},
    }
}

// ── 19: 자원 — 연달아 trace, sidecar RSS ───────────────────────────────────────────────────────────────

fn rssKb(pid: c_int) i64 {
    var pb: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&pb, "/bin/ps -o rss= -p {d}", .{pid}, 0) catch return -1;
    const fp = popen(cmd.ptr, "r") orelse return -1;
    defer _ = pclose(fp);
    var buf: [64]u8 = undefined;
    const n = fread(&buf, 1, buf.len, fp);
    const t = std.mem.trim(u8, buf[0..n], " \n\t");
    return std.fmt.parseInt(i64, t, 10) catch -1;
}
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(fp: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, fp: *anyopaque) usize;

fn b19Repeat(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb19");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-jank"));
    try r.create(2, emu.uLocal(&u, "/pb-jank?b"));
    r.pump(800);
    const rss0 = rssKb(r.host.pid);
    var done: usize = 0;
    var kept: usize = 0;
    var busy: usize = 0;
    const t0 = os.nowMs();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const b: u64 = if (i % 2 == 0) 1 else 2;
        const g = try perf.startTrace(r, b, 1000, i % 3 == 0);
        // 다른 탭이 곧바로 start(바쁨이어야 한다 — sidecar 는 하나만).
        const g_busy = try perf.startTrace(r, if (b == 1) 2 else 1, 1000, false);
        const sb = perf.waitFinished(r, g_busy, 10_000);
        if (sb != null and sb.?.state == .failed and sb.?.reason == .busy) busy += 1;
        const d = try finishAndFilter(r, g, 40_000);
        if (d.st != null and d.st.?.state == .done) done += 1;
        if (eql(d.outcome, "kept")) kept += 1;
    }
    const dt = os.nowMs() - t0;
    r.pump(1500);
    const rss1 = rssKb(r.host.pid);
    report(done == 12 and kept == 12 and busy == 12, "b19-back-to-back", std.fmt.bufPrint(&dbuf, "12 번 연달아(탭 번갈아·셋에 하나 스크린샷) — done {d}·kept {d}·같은 순간 다른 탭 start 바쁨 {d}/12, {d} ms, sidecar RSS {d} → {d} KiB", .{ done, kept, busy, dt, rss0, rss1 }) catch "");
}

// ── A4-1: 잘린 trace 의 덮은 시간 ───────────────────────────────────────────────────────────────────────

fn b4Trunc(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb4");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-noise"));
    r.pump(800);
    const gen = try start(r, 1, 30_000, true);
    const st = perf.waitFinished(r, gen, 120_000);
    var pb: [1200]u8 = undefined;
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/b4_trunc.raw.gz", .{root_dir}, 0) catch return, r.tr_gz.items) catch {};
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(std.heap.c_allocator);
    for (r.tr_frames.items, r.tr_frame_lens.items) |*b, k| {
        ids.appendSlice(std.heap.c_allocator, b[0..k]) catch {};
        ids.append(std.heap.c_allocator, '\n') catch {};
    }
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/b4_trunc.frames.txt", .{root_dir}, 0) catch return, ids.items) catch {};
    report(true, "b4-truncated(obs)", std.fmt.bufPrint(&dbuf, "캔버스 잡음 30 s + 스크린샷 → {s}/{s} 덮음 {d} ms 잘림 {} gzip {d} B (덮은 시간은 py 로)", .{ stName(st), rsName(st), if (st) |x| x.covered_ms else 0, if (st) |x| x.truncated else false, r.tr_gz.items.len }) catch "");
}

fn b4TruncMixed(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pb4m");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pb-noise"));
    try r.create(2, emu.uLocal(&u, "/pa-user-anim2"));
    r.pump(1200);
    const gen = try start(r, 1, 30_000, true);
    const d = try finishAndFilter(r, gen, 120_000);
    report(d.st != null and d.st.?.truncated and eql(d.outcome, "mixed_content"), "b4-truncated-mixed", std.fmt.bufPrint(&dbuf, "잘린 trace + 같은 프로세스 사용자 iframe 의 컴포지터 애니메이션 → {s}/{s} 잘림 {} 거르기 {s} 남김 {d} 남의 {s}", .{ stName(d.st), rsName(d.st), if (d.st) |x| x.truncated else false, d.outcome, d.kept, d.foreign }) catch "");
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try emu.startServer();
    try perf.setup(host_path, root);
    root_dir = root;
    const probes = .{
        .{ "b7-embeds", b7Embeds },
        .{ "b11-guard", b11Guard },
        .{ "b1-jank", b1Jank },
        .{ "b1-detect", b1Detect },
        .{ "b2-family", b2Family },
        .{ "b3-mixed", b3Mixed },
        .{ "b6-ends", b6HideEnds },
        .{ "b15-death", b15Death },
        .{ "b15-hang", b15Hang },
        .{ "b15-hang-var", b15HangVariants },
        .{ "b15-early", b15EarlyEnd },
        .{ "b15-window", b15Window },
        .{ "b16-nav", b16Nav },
        .{ "b16-human-nav", b16HumanNav },
        .{ "b17-combo", b17Combo },
        .{ "b18-w9d", b18W9d },
        .{ "b19-repeat", b19Repeat },
        .{ "b4-trunc", b4Trunc },
        .{ "b4-trunc-mixed", b4TruncMixed },
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
    select.verify(report, "W9E2B_ONLY", "w9e2b-selection", &names, ran);
    // V-15: DevTools 관찰자 재진입(「Check failed: !check_reentrancy」)이 이 판의 어느 host 로그에도 없어야 한다 — trace 의 명령을 관찰자 콜백
    // 안에서 곧 내면 난다(늦은 시작 답 안의 `Tracing.end` 는 sidecar 를 죽였다). 판 전체를 본다.
    if (ran > 0) select.noReentrancy(report, root, "w9e2b-no-observer-reentrancy");
}
