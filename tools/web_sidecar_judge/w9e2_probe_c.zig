//! W9e② 적대 검증 v20c(11–20 회차 고침 `f3ebb8fde` 재검증) 탐침 — 판정용이다(제품 코드 아님). `maru-web-judge --w9e2c <dist> <프로필>`, 환경
//! `W9E2C_ONLY=이름,…` 이면 그 탐침만. v20b 탐침(`w9e2_probe_b.zig`)과 같은 틀(판정자가 maru 역할로 trace·흉내·사람 입력을 보낸다). PASS = 문서가
//! 약속한 동작, FAIL = 반례 후보. `(obs)` 는 관찰만(늘 PASS). v20c 고침(N1–N4·L2) 뒤 기준으로 들였다 — `c2-*`(N1: 사용자 iframe 의 워커는 통째
//! 버림·남긴 V8 표본은 주 스레드 isolate 의 것만), `c7-*`(N2: 기록은 커밋한 문서만·주 문서마다), `c5-dialog-*`(N3: 사람의 sheet 답은 사람 입력,
//! 에이전트의 답은 아니다), `c5-family-popup-human`(N4: 사람이 가족 팝업을 몰면 연 탭의 CPU 가 풀리고 네트워크는 남는다). 환경 `W9E2C_HOST_ARG=--스위치` 면 host 명령줄에 그 스위치 하나를 더한다
//! (`host.zig` 의 `extra_arg` — 프로세스 상한 등, 판정용).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const emu = @import("emulation_check.zig");
const perf = @import("perf_check.zig");
const select = @import("probe_select.zig");
const host_mod = @import("host.zig");

const msg = protocol.message;
const Run = emu.Run;
const Session = emu.Session;
const Report = emu.Report;
const contains = emu.contains;

const common_js =
    \\window.bench=function(n){n=n||3e7;var s=performance.now(),x=0;for(var i=0;i<n;i++){x=(x+i*7)%1000003}window.__x=x;return Math.round(performance.now()-s)};
    \\window.JANK=function(ms){var e=performance.now()+ms;while(performance.now()<e){}return 'j'};
    \\window.ASK=function(f,m){return new Promise(function(r){var el=document.getElementById(f);var ch=new MessageChannel();ch.port1.onmessage=function(e){r(e.data)};el.contentWindow.postMessage(m,'*',[ch.port2]);setTimeout(function(){r('timeout')},20000)})};
;
/// iframe 안에서 잰다(부모가 ASK 로 묻는다).
const kid_bench = "<script>window.bench=function(n){n=n||3e7;var s=performance.now(),x=0;for(var i=0;i<n;i++){x=(x+i*7)%1000003}window.__x=x;return Math.round(performance.now()-s)};onmessage=function(e){e.ports[0].postMessage(JSON.stringify({ms:bench()}))}</script>";

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn replyType(conn: c_int, status: []const u8, ctype: []const u8, extra: []const u8, body: []const u8) void {
    var hb: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n{s}\r\n", .{ status, ctype, body.len, extra }) catch return;
    _ = std.c.write(conn, head.ptr, head.len);
    _ = std.c.write(conn, body.ptr, body.len);
}

fn reply(conn: c_int, body: []const u8) bool {
    replyType(conn, "200 OK", "text/html; charset=utf-8", "", body);
    return true;
}

fn queryInt(target: []const u8, key: []const u8) ?u32 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        const eqi = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (eql(kv[0..eqi], key)) return std.fmt.parseInt(u32, kv[eqi + 1 ..], 10) catch null;
    }
    return null;
}

/// `emulation_check.serveParsed` 가 부른다 — `/pc-*` 만 맡는다.
pub fn serve(conn: c_int, path: []const u8, target: []const u8, host: []const u8) bool {
    _ = host;
    if (!std.mem.startsWith(u8, path, "/pc-")) return false;
    const port = emu.port;
    var bb: [16384]u8 = undefined;
    if (eql(path, "/pc-t")) return reply(conn, "<!doctype html><title>PC-T</title><body style='margin:0;background:#00c000'><div style='height:2000px'>agent</div><script>" ++ common_js ++ "</script>");
    // ── 사용자 iframe 의 워커(같은 사이트 iframe 이 에이전트 탭의 프로세스에 든다 — 그 워커도) ──
    if (eql(path, "/pc-u-worker")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-WORKER</title><body>user<iframe id=f src='http://127.0.0.1:{d}/pc-kid-worker' width=300 height=100></iframe><script>{s}</script>", .{ port, common_js }) catch return false);
    if (eql(path, "/pc-kid-worker")) return reply(conn, "<!doctype html><title>KID-WORKER</title><body>kid<script>window.w=new Worker('/pc-secret-worker.js?tok=SECRETTOKEN1');</script>");
    if (eql(path, "/pc-secret-worker.js")) {
        replyType(conn, "200 OK", "application/javascript", "", "function USERSECRETFN(){var x=0;for(var i=0;i<3e6;i++){x=(x+i*7)%1000003}return x}setInterval(function(){USERSECRETFN()},2);");
        return true;
    }
    // 에이전트 탭 자신의 워커(그 isolate 의 표본은 빠진다 — F2) + 주 스레드의 일(그 isolate 의 표본은 남는다 — 거르기가 V8 프로파일을 통째로 버리지
    // 않는가의 대조).
    if (eql(path, "/pc-t-worker")) return reply(conn, "<!doctype html><title>PC-T-WORKER</title><body>agent<script>" ++ common_js ++ "window.w=new Worker('/pc-own-worker.js?tok=AGENTTOKEN');function AGENTMAINFN(){var x=0;for(var i=0;i<2e6;i++){x=(x+i*7)%1000003}return x}setInterval(function(){AGENTMAINFN()},5);</script>");
    if (eql(path, "/pc-own-worker.js")) {
        replyType(conn, "200 OK", "application/javascript", "", "function AGENTOWNFN(){var x=0;for(var i=0;i<3e6;i++){x=(x+i*7)%1000003}return x}setInterval(function(){AGENTOWNFN()},2);");
        return true;
    }
    // ── V-A7 기록 — 리다이렉트 사슬(쿠키 맞추기 꼴: h{n}.localhost → … → h0.localhost) + about:blank(GPT friendly iframe 꼴) ──
    if (eql(path, "/pc-hop")) {
        const n = queryInt(target, "n") orelse 0;
        if (n == 0) return reply(conn, "<!doctype html><title>HOP0</title><body>sync done");
        var lb: [256]u8 = undefined;
        const loc = std.fmt.bufPrint(&lb, "Location: http://h{d}.localhost:{d}/pc-hop?n={d}\r\n", .{ n - 1, port, n - 1 }) catch return false;
        replyType(conn, "302 Found", "text/html", loc, "");
        return true;
    }
    if (eql(path, "/pc-u-sync")) {
        const n = queryInt(target, "n") orelse 9;
        return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-SYNC</title><body>user<iframe src='http://h{d}.localhost:{d}/pc-hop?n={d}' width=10 height=10></iframe><iframe id=g src='about:blank' width=300 height=250></iframe><script>{s}var d=document.getElementById('g').contentDocument;d.open();d.write('AD');d.close();</script>", .{ n, port, n, common_js }) catch return false);
    }
    // 에이전트 탭의 사이트(127.0.0.1) iframe 이 한 번 있었던 사용자 탭 — 그 iframe 은 곧 지운다(남는 것은 about:blank 하나).
    if (eql(path, "/pc-u-tsite-gone")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-TSITE-GONE</title><body>user<iframe id=t src='http://127.0.0.1:{d}/pc-hop?n=0' width=10 height=10></iframe><iframe id=g src='about:blank' width=300 height=250></iframe><script>{s}window.GONE=function(){{var t=document.getElementById('t');t.parentNode.removeChild(t);return 'gone'}};</script>", .{ port, common_js }) catch return false);
    // ── 프로세스 상한 넘기기 — 서로 다른 사이트(s{i}.localhost) iframe n 개(사이트마다 렌더러 하나) ──
    if (eql(path, "/pc-many")) {
        const n = queryInt(target, "n") orelse 90;
        var w: std.Io.Writer = .fixed(&bb);
        w.writeAll("<!doctype html><title>U-MANY</title><body>user") catch return false;
        var i: u32 = 0;
        while (i < n) : (i += 1) w.print("<iframe src='http://s{d}.localhost:{d}/pc-hop?n=0' width=8 height=8></iframe>", .{ i, port }) catch return false;
        return reply(conn, w.buffered());
    }
    // ── v20c N2 대조: 에이전트 사이트를 홉으로만 지나는 리다이렉트(커밋은 h0.localhost) + about:blank — 홉을 적으면 헛거절 ──
    if (eql(path, "/pc-u-viaagent")) return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-VIAAGENT</title><body>user<iframe src='http://127.0.0.1:{d}/pc-hop?n=1' width=10 height=10></iframe><iframe id=g src='about:blank' width=300 height=250></iframe><script>{s}var d=document.getElementById('g').contentDocument;d.open();d.write('AD');d.close();</script>", .{ port, common_js }) catch return false);
    // 서로 다른 사이트 하위 프레임 n 개(한 문서의 기록 칸 16 을 넘긴다) + about:blank. `blank=1` 이면 먼저 에이전트 사이트 iframe 이 제 문서를
    // about:blank 로 바꾸고, 그 뒤에(0.4 s) 다른 사이트 iframe 들이 커밋한다 — 넘쳐 다시 셀 때 에이전트 사이트 기록이 남아야 한다.
    if (eql(path, "/pc-u-overflow")) {
        const n = queryInt(target, "n") orelse 17;
        const blank = queryInt(target, "blank") != null;
        var w: std.Io.Writer = .fixed(&bb);
        w.writeAll("<!doctype html><title>U-OVERFLOW</title><body>user<iframe id=g src='about:blank' width=30 height=25></iframe>") catch return false;
        if (blank) w.print("<iframe src='http://127.0.0.1:{d}/pb-kid-selfblank' width=30 height=20></iframe>", .{port}) catch return false;
        w.print("<script>{s}var d=document.getElementById('g').contentDocument;d.open();d.write('AD');d.close();setTimeout(function(){{for(var i=0;i<{d};i++){{var f=document.createElement('iframe');f.width=8;f.height=8;f.src='http://o'+i+'.localhost:{d}/pc-hop?n=0';document.body.appendChild(f)}}}},{d});</script>", .{ common_js, n, port, @as(u32, if (blank) 400 else 0) }) catch return false;
        return reply(conn, w.buffered());
    }
    // ── 3c — 다른 사이트(x.localhost) iframe 이 만든 about:blank 손자 ──
    if (eql(path, "/pc-u-grand")) {
        const h = if (queryInt(target, "t") != null) "127.0.0.1" else "x.localhost";
        return reply(conn, std.fmt.bufPrint(&bb, "<!doctype html><title>U-GRAND</title><body>user<iframe id=f src='http://{s}:{d}/pc-kid-grand' width=300 height=200></iframe><script>{s}</script>", .{ h, port, common_js }) catch return false);
    }
    if (eql(path, "/pc-kid-grand")) return reply(conn, "<!doctype html><title>KID-GRAND</title><body>kid<iframe id=g src='about:blank' width=100 height=50></iframe>" ++ kid_bench ++ "<script>var d=document.getElementById('g').contentDocument;d.open();d.write('<b>grand</b>');d.close();</script>");
    return false;
}

// ── 공통 ─────────────────────────────────────────────────────────────────────────────────────────────────

var dbuf: [6000]u8 = undefined;
var root_dir: []const u8 = "";
const cpu_bit: u16 = 1 << 7;

fn only(name: []const u8) bool {
    return select.selected("W9E2C_ONLY", name);
}

fn stName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.state) else "-";
}
fn rsName(st: ?msg.TraceState) []const u8 {
    return if (st) |x| @tagName(x.reason) else "-";
}

fn hostUrl(buf: []u8, host: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ host, emu.port, path }) catch unreachable;
}

fn recycle(r: *Run, b: u64) void {
    r.host.send(.{ .destroy_browser = b }) catch {};
    r.pump(700);
    r.created[b] = false;
    r.loads[b] = 0;
    r.st[b] = null;
    r.gen[b] = 0;
}

fn msOf(s: []const u8) i64 {
    const at = std.mem.indexOf(u8, s, "\"ms\":") orelse return -1;
    var e = at + 5;
    while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
    return std.fmt.parseInt(i64, s[at + 5 .. e], 10) catch -1;
}

fn cpuActive(st: ?msg.EmulationState) bool {
    return st != null and st.?.active_mask & cpu_bit != 0;
}

fn reasonOf(st: ?msg.EmulationState) []const u8 {
    return if (st) |x| @tagName(x.reason) else "-";
}

/// host 의 자식 프로세스 수(렌더러·GPU·utility — `Run.renderers` 는 64 에서 잘린다).
fn childCount(pid: c_int) i64 {
    var cb: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cb, "/usr/bin/pgrep -P {d} | /usr/bin/wc -l", .{pid}, 0) catch return -1;
    const fp = popen(cmd.ptr, "r") orelse return -1;
    defer _ = pclose(fp);
    var buf: [64]u8 = undefined;
    const n = fread(&buf, 1, buf.len, fp);
    return std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..n], " \n\t"), 10) catch -1;
}

fn crashReports() i64 {
    const fp = popen("/bin/ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | /usr/bin/grep -c '^maru-web-host'", "r") orelse return -1;
    defer _ = pclose(fp);
    var buf: [64]u8 = undefined;
    const n = fread(&buf, 1, buf.len, fp);
    return std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..n], " \n\t"), 10) catch -1;
}
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(fp: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, fp: *anyopaque) usize;

const Done = struct { st: ?msg.TraceState, outcome: []const u8 = "-", kept: u64 = 0, frames: u64 = 0, comp_dropped: u64 = 0, foreign: []const u8 = "-", raw_has: [4]bool = @splat(false), kept_has: [4]bool = @splat(false) };
var outcome_bufs: [8][64]u8 = undefined;
var foreign_bufs: [8][128]u8 = undefined;
var ob_i: usize = 0;

/// 끝을 기다려 거르고, 원본·남긴 것에서 바늘 셋을 찾는다.
fn finishFilter(r: *Run, gen: u32, wait: u32, needles: [4][]const u8) !Done {
    const st = perf.waitFinished(r, gen, wait);
    var d: Done = .{ .st = st };
    for (needles, 0..) |n, i| if (n.len > 0 and r.tr_gz.items.len > 0) {
        d.raw_has[i] = perf.gunzipContains(std.heap.c_allocator, r.tr_gz.items, n);
    };
    if (st == null or st.?.state != .done) {
        d.outcome = "not-done";
        return d;
    }
    var res = try perf.filterNow(r, std.heap.c_allocator);
    defer res.deinit(std.heap.c_allocator);
    ob_i = (ob_i + 1) % outcome_bufs.len;
    d.outcome = std.fmt.bufPrint(&outcome_bufs[ob_i], "{s}", .{res.outcome}) catch "?";
    d.foreign = std.fmt.bufPrint(&foreign_bufs[ob_i], "{s}", .{res.foreign[0..@min(res.foreign.len, 100)]}) catch "?";
    d.kept = res.kept;
    d.frames = res.frames;
    d.comp_dropped = res.comp_dropped;
    for (needles, 0..) |n, i| if (n.len > 0 and res.gz.len > 0) {
        d.kept_has[i] = perf.gunzipContains(std.heap.c_allocator, res.gz, n);
    };
    // 읽는 사람이 볼 수 있게 남긴 것·원본을 판 뿌리에 둔다(`c_<세대>.kept.gz`·`.raw.gz`).
    var pb: [1200]u8 = undefined;
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/c_{d}.kept.gz", .{ root_dir, gen }, 0) catch return d, res.gz) catch {};
    perf.writeAll(std.fmt.bufPrintSentinel(&pb, "{s}/c_{d}.raw.gz", .{ root_dir, gen }, 0) catch return d, r.tr_gz.items) catch {};
    return d;
}

fn start(r: *Run, b: u64, ms: u32, shots: bool) !u32 {
    const gen = try perf.startTrace(r, b, ms, shots);
    _ = r.until(perf.recordingAt, gen, 0, 8000);
    return gen;
}

// ── 결정 12·F2: 사용자 iframe(에이전트 탭과 같은 사이트 — 같은 렌더러 프로세스)의 전용 워커 ─────────────────────────────

fn c2UserWorker(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc2w");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    const needles = [4][]const u8{ "USERSECRETFN", "SECRETTOKEN1", "AGENTOWNFN", "AGENTMAINFN" };
    // 대조: 에이전트 탭 자신의 워커와 주 스레드의 일 — 남긴 것에 주 스레드 isolate 의 표본(AGENTMAINFN)만 남고 워커 isolate 의 표본(AGENTOWNFN)은
    // 빠지는가(N1 의 허용 목록 — 원본에는 둘 다 있다: 바늘 찾기가 된다).
    try r.create(1, emu.uLoop(&u, "/pc-t-worker"));
    r.pump(1500);
    const g0 = try start(r, 1, 2000, false);
    const d0 = try finishFilter(r, g0, 40_000, needles);
    // 사용자 탭(localhost) 안의 127.0.0.1 iframe 이 워커를 돌린다 — iframe 의 주 스레드는 쉰다.
    try r.nav(1, emu.uLoop(&u, "/pc-t"));
    try r.create(2, emu.uLocal(&u, "/pc-u-worker"));
    r.pump(2500);
    const procs = r.renderers();
    const g1 = try start(r, 1, 2000, false);
    const d1 = try finishFilter(r, g1, 40_000, needles);
    r.pump(1000);
    // 같은 꼴 + 에이전트 탭이 기록 내내 막힘(결정 12 의 막힌 탭 — 나눔 표시가 서면 주 스레드 밖을 뺀다).
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g2 = try start(r, 1, 2000, false);
    const d2 = try finishFilter(r, g2, 40_000, needles);
    const leak1 = eql(d1.outcome, "kept") and (d1.kept_has[0] or d1.kept_has[1]);
    const leak2 = eql(d2.outcome, "kept") and (d2.kept_has[0] or d2.kept_has[1]);
    report(!leak1 and !leak2, "c2-user-worker-leak", std.fmt.bufPrint(&dbuf, "사용자 iframe(127.0.0.1)의 워커, 렌더러 {d} 개 → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 남의 {s} 원본 USERSECRETFN {}·SECRETTOKEN1 {} → 남김 USERSECRETFN {}·SECRETTOKEN1 {} | 막힌 탭 + 같은 워커 → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 뺌 {d} 원본 {}·{} → 남김 {}·{}", .{
        procs,          stName(d1.st),   rsName(d1.st), if (d1.st) |x| x.shared_process else false, d1.outcome,
        d1.kept,        d1.foreign,      d1.raw_has[0], d1.raw_has[1],                              d1.kept_has[0],
        d1.kept_has[1], stName(d2.st),   rsName(d2.st), if (d2.st) |x| x.shared_process else false, d2.outcome,
        d2.kept,        d2.comp_dropped, d2.raw_has[0], d2.raw_has[1],                              d2.kept_has[0],
        d2.kept_has[1],
    }) catch "");
    // N1 의 둘째 판단: 남길 렌더러 프로세스의 워커가 가족 밖 프레임(사용자 iframe)의 것이면 통째로 버린다(`mixed_content`). 원본에 그 워커의 표본이
    // 없으면(워커가 기록 전에 끝났다) 가를 것이 없다 — 그때는 실패로 둔다(탐침이 꼴을 만들지 못했다).
    var vb: [600]u8 = undefined;
    report(eql(d1.outcome, "mixed_content") and eql(d2.outcome, "mixed_content") and d1.raw_has[0] and d2.raw_has[0], "c2-user-worker-discard", std.fmt.bufPrint(&vb, "거르기 {s}·{s}(막힌 탭), 원본에 사용자 워커 표본 {}·{}", .{ d1.outcome, d2.outcome, d1.raw_has[0], d2.raw_has[0] }) catch "");
    report(eql(d0.outcome, "kept") and d0.raw_has[2] and d0.raw_has[3] and d0.kept_has[3] and !d0.kept_has[2], "c2-worker-profile-main-only", std.fmt.bufPrint(&vb, "에이전트 탭 자신 {s}/{s} 거르기 {s}: 원본 AGENTOWNFN {}·AGENTMAINFN {} → 남김 AGENTOWNFN {}(빠져야)·AGENTMAINFN {}(남아야)", .{ stName(d0.st), rsName(d0.st), d0.outcome, d0.raw_has[2], d0.raw_has[3], d0.kept_has[2], d0.kept_has[3] }) catch "");
    recycle(r, 2);
}

// ── 결정 12·CPU: 프로세스 나눔 어림이 놓치는 꼴 — 렌더러 프로세스 상한(같은 사이트의 따로 연 사용자 탭) ──────────────────────

fn c12ProcLimit(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc12");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    const arg = if (host_mod.extra_arg) |a| std.mem.span(a) else "(없음)";
    const arg2 = if (host_mod.extra_arg2) |a| std.mem.span(a) else "";
    try r.create(1, emu.uLoop(&u, "/pc-t"));
    // 환경 `C12_IFRAMES=n` 이면 먼저 사용자 탭 하나에 서로 다른 사이트 iframe n 개를 띄워 Chromium 의 렌더러 프로세스 상한(이 기계 82)을 넘긴다.
    const many: u32 = if (std.c.getenv("C12_IFRAMES")) |v| std.fmt.parseInt(u32, std.mem.span(v), 10) catch 0 else 0;
    if (many > 0) {
        var mb: [64]u8 = undefined;
        try r.create(3, emu.uLocal(&u, std.fmt.bufPrint(&mb, "/pc-many?n={d}", .{many}) catch "/pc-many"));
        r.pump(15_000);
    }
    const procs_many = childCount(r.host.pid);
    // 사용자가 따로 연 같은 사이트 탭(연 탭 없음 — 어림은 「다른 프로세스」 로 본다, c1).
    try r.create(2, emu.uLoop(&u, "/pb-jank?user"));
    r.pump(1200);
    const procs = childCount(r.host.pid);
    var uab: [200]u8 = undefined;
    const ua = r.ev(1, "navigator.userAgent.slice(0,40)", &uab);
    const base2 = perf.benchOf(r, 2);
    const st = try r.emulate(1, perf.cpuOn(4));
    const on = cpuActive(st);
    const user_on = perf.benchOf(r, 2);
    const agent_on = perf.benchOf(r, 1);
    _ = try r.emulate(1, .{ .browser = 0 });
    const user_slow = on and user_on * 10 >= base2 * 25;
    // 막힌 에이전트 탭 trace(애니메이션 없음) — 같은 프로세스의 사용자 탭 컴포지터 애니메이션이 가족 것으로 남는가.
    try r.nav(1, emu.uLoop(&u, "/pc-t?still"));
    r.pump(800);
    _ = r.ev(1, "setTimeout(function(){JANK(4500)},30),'ok'", &o);
    r.pump(150);
    const g = try start(r, 1, 2000, false);
    const d = try finishFilter(r, g, 40_000, .{ "", "", "", "" });
    const foreign_frames = eql(d.outcome, "kept") and d.frames > 0 and d.comp_dropped == 0;
    report(!user_slow and !foreign_frames, "c12-process-limit", std.fmt.bufPrint(&dbuf, "host 스위치 {s} {s} (UA {s}), 다른 사이트 iframe {d} 개 뒤 host 자식 프로세스 {d} 개 → 같은 사이트 탭 뒤 {d} 개 | CPU 4 배 → 걸림 {} ({s}) 에이전트 {d} ms, 따로 연 같은 사이트 사용자 탭 {d} → {d} ms(느려짐 {}) | 막힌 에이전트 탭(애니메이션 없음) trace + 사용자 탭 애니메이션 → {s}/{s} 나눔 {} 거르기 {s} 남김 {d} 프레임 {d} 뺌 {d} 남의 {s}", .{ arg, arg2, ua, many, procs_many, procs, on, reasonOf(st), agent_on, base2, user_on, user_slow, stName(d.st), rsName(d.st), if (d.st) |x| x.shared_process else false, d.outcome, d.kept, d.frames, d.comp_dropped, d.foreign }) catch "");
}

// ── V-A7: 「하위 프레임이 가졌던 사이트」 기록 — 리다이렉트 사슬로 넘침, 지난 뒤에도 남는가, 닫아야 풀리는가 ────────────────────────

fn c7Sticky(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc7");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pc-t"));
    r.pump(400);
    const base = perf.benchOf(r, 1);
    var line: std.Io.Writer = .fixed(&dbuf);
    var false_refuse: usize = 0;
    var leaks: usize = 0;
    // `want_on` null — 어느 쪽이든 받아들인다(같은 주 문서 안에서 지운 iframe 과 제 문서를 about:blank 로 바꾼 iframe 은 가를 수 없다 — v20c N2 문서).
    const Step = struct { name: []const u8, nav: ?[]const u8 = null, fresh: bool = false, js: ?[]const u8 = null, back: bool = false, settle_ms: u32 = 1200, want_on: ?bool };
    const steps = [_]Step{
        .{ .name = "새 탭: about:blank 광고 칸만", .nav = "/pb-u-gpt", .fresh = true, .want_on = true },
        .{ .name = "같은 탭 → 리다이렉트 7 홉(8 사이트)+about:blank", .nav = "/pc-u-sync?n=7", .want_on = true },
        .{ .name = "같은 탭 → 리다이렉트 8 홉(9 사이트)+about:blank", .nav = "/pc-u-sync?n=8", .want_on = true },
        .{ .name = "같은 탭 → about:blank 광고 칸만(사슬은 지났다)", .nav = "/pb-u-gpt", .want_on = true },
        .{ .name = "같은 탭 → iframe 없음", .nav = "/pb-u-none", .want_on = true },
        .{ .name = "같은 탭 → about:blank 광고 칸만(다시)", .nav = "/pb-u-gpt", .want_on = true },
        .{ .name = "탭을 닫고 새 탭: about:blank 광고 칸만", .nav = "/pb-u-gpt", .fresh = true, .want_on = true },
        .{ .name = "새 탭: 에이전트 사이트 iframe(진짜 위험)+about:blank", .nav = "/pc-u-tsite-gone", .fresh = true, .want_on = false },
        .{ .name = "그 iframe 을 지운 뒤(about:blank 만 남음 — 같은 문서)", .js = "GONE()", .want_on = null },
        .{ .name = "같은 탭 → about:blank 광고 칸만", .nav = "/pb-u-gpt", .want_on = true },
        // A7-1 이 bfcache 로 새지 않는가(v20c N2 — 기록은 주 문서마다): 같은 사이트 iframe 이 제 문서를 about:blank 로 바꾼 사용자 탭 → 다른 문서 →
        // 뒤로(되살아난 그 iframe 은 에이전트 탭의 프로세스에 있다 — bfcache 가 아니면 다시 불러 그 iframe 이 다시 있다; 어느 쪽이든 위험).
        .{ .name = "새 탭: 같은 사이트 iframe 이 제 문서를 about:blank 로", .nav = "/pb-u-selfblank", .fresh = true, .want_on = false },
        .{ .name = "같은 탭 → 다른 문서(about:blank 광고 칸)", .nav = "/pb-u-gpt", .want_on = true },
        .{ .name = "같은 탭 → 뒤로(제 문서를 바꾼 iframe 의 문서)", .back = true, .want_on = false },
        // 홉은 문서가 아니다 — 에이전트 사이트를 리다이렉트 홉으로만 지난 iframe 은 그 사이트에 커밋하지 않았다.
        .{ .name = "새 탭: 에이전트 사이트를 홉으로만 지난 iframe + about:blank", .nav = "/pc-u-viaagent", .fresh = true, .want_on = true },
        // 한 문서의 칸(16)을 넘겨도 「모름」 으로 굳지 않는다.
        .{ .name = "새 탭: 다른 사이트 하위 프레임 17 + about:blank", .nav = "/pc-u-overflow?n=17", .fresh = true, .settle_ms = 5000, .want_on = true },
        // 넘쳐 다시 셀 때 열린 탭의 맨 위 사이트(에이전트 사이트) 기록을 먼저 남긴다 — 제 문서를 about:blank 로 바꾼 같은 사이트 iframe 이 뒤에 온 다른
        // 사이트 iframe 들에 밀려 사라지면 A7-1 이 샌다.
        .{ .name = "새 탭: 같은 사이트 iframe 이 about:blank 로 + 그 뒤 다른 사이트 17", .nav = "/pc-u-overflow?n=17&blank=1", .fresh = true, .settle_ms = 5000, .want_on = false },
    };
    for (steps) |s| {
        if (s.fresh) {
            if (r.created[2]) recycle(r, 2);
            try r.create(2, emu.uLocal(&u, s.nav.?));
        } else if (s.nav) |p| try r.nav(2, emu.uLocal(&u, p));
        if (s.js) |j| _ = r.ev(2, j, &o);
        if (s.back) try r.action(2, .back);
        r.pump(s.settle_ms);
        const st = try r.emulate(1, perf.cpuOn(4));
        const on = cpuActive(st);
        var user_ms: i64 = -1;
        if (on) user_ms = perf.benchOf(r, 2);
        _ = try r.emulate(1, .{ .browser = 0 });
        if (s.want_on) |w| {
            if (w and !on) false_refuse += 1;
            if (!w and on) leaks += 1;
        }
        if (user_ms >= 0 and user_ms * 10 >= base * 25) leaks += 1;
        line.print("{s}: 걸림 {} ({s}) 사용자 탭 {d} ms; ", .{ s.name, on, reasonOf(st), user_ms }) catch {};
    }
    line.print("기준 {d} ms", .{base}) catch {};
    report(leaks == 0, "c7-history-bypass", line.buffered());
    report(false_refuse == 0, "c7-history-false-refuse", std.fmt.bufPrint(&o, "걸려야 하는 꼴(남의 프로세스가 아닌) 중 거절 {d}", .{false_refuse}) catch "");
}

// ── 3c: 다른 사이트 iframe 의 about:blank 손자(에이전트 사이트 iframe 의 손자는 위험) ───────────────────────────────

fn c3Grandchild(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc3");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pc-t"));
    r.pump(400);
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    const Case = struct { name: []const u8, path: []const u8, want_on: bool };
    for ([_]Case{
        .{ .name = "x.localhost iframe 의 about:blank 손자", .path = "/pc-u-grand", .want_on = true },
        .{ .name = "127.0.0.1(에이전트 사이트) iframe 의 about:blank 손자", .path = "/pc-u-grand?t=1", .want_on = false },
    }) |c| {
        try r.create(2, emu.uLocal(&u, c.path));
        r.pump(1200);
        const base_kid = msOf(r.ev(2, "ASK('f','x')", &o));
        const st = try r.emulate(1, perf.cpuOn(4));
        const on = cpuActive(st);
        const kid_on = msOf(r.ev(2, "ASK('f','x')", &o));
        _ = try r.emulate(1, .{ .browser = 0 });
        const slowed = on and base_kid > 0 and kid_on * 10 >= base_kid * 25;
        if (on != c.want_on or slowed) bad += 1;
        line.print("{s}: 걸림 {} ({s}), 그 iframe {d} → {d} ms; ", .{ c.name, on, reasonOf(st), base_kid, kid_on }) catch {};
        recycle(r, 2);
    }
    report(bad == 0, "c3-grandchild", line.buffered());
}

// ── 5: 사람이 에이전트 탭의 팝업(가족 — CPU 를 함께 받는다)을 몬다 — trace 는 버리는데 조건은? ───────────────────────────────

fn c5FamilyPopupHuman(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc5");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pc-t"));
    r.pump(400);
    try r.host.send(.{ .popup_reserve = .{ .browser = 4 } });
    r.pump(200);
    try r.host.send(.{ .new_tab_credit = 1 });
    _ = r.evWith(1, "window.p=window.open('/pc-t?popup','pp'),'ok'", &o, true);
    _ = r.until(Run.loadsAt, 4, 1, 8000);
    r.pump(800);
    const base_pop = perf.benchOf(r, 4);
    // 에이전트 탭에 CPU 4 배와 네트워크 지연(그 탭의 요청만 — 팝업은 받지 않는다, A8-1).
    const st = try r.emulate(1, .{ .browser = 0, .flags = .{ .cpu = true, .network = true }, .cpu_rate = 4, .latency_ms = 300 });
    const on = cpuActive(st);
    const net_bit: u16 = 1 << 8;
    const net_on = st != null and st.?.active_mask & net_bit != 0;
    const pop_on = perf.benchOf(r, 4);
    // trace 중 사람이 팝업을 누른다.
    const g = try start(r, 1, 3000, false);
    r.pump(300);
    r.userClick(4, 50, 50);
    const tst = perf.waitFinished(r, g, 30_000);
    // 사람이 팝업에 친다.
    r.host.send(.{ .key = .{ .browser = 4, .kind = .raw_down, .native_key_code = 0, .character = 'a', .unmodified_character = 'a' } }) catch {};
    r.host.send(.{ .key = .{ .browser = 4, .kind = .up, .native_key_code = 0, .character = 'a', .unmodified_character = 'a' } }) catch {};
    r.pump(600);
    const pop_after = perf.benchOf(r, 4);
    const em = r.st[1];
    const released = em != null and em.?.released_mask & cpu_bit != 0;
    const net_kept = em != null and em.?.active_mask & net_bit != 0 and em.?.released_mask & net_bit == 0;
    _ = try r.emulate(1, .{ .browser = 0 });
    const still_slow = pop_after * 10 >= base_pop * 25;
    const slowed = pop_on * 10 >= base_pop * 25;
    report(on and net_on and slowed and released and !still_slow and net_kept and tst != null and tst.?.reason == .human_input, "c5-family-popup-human", std.fmt.bufPrint(&dbuf, "에이전트 탭에 CPU 4 배·지연 → 걸림 {}·{} | 그 탭이 연 팝업 {d} → {d} ms(함께 느려짐 {}) | trace 중 사람이 팝업 누름 → {s}/{s} | 사람이 팝업을 누르고 친 뒤: 에이전트 탭 CPU 풀림 {} (released 0x{x}), 네트워크 남음 {}, 팝업 {d} ms(아직 느림 {})", .{ on, net_on, base_pop, pop_on, slowed, stName(tst), rsName(tst), released, if (em) |e| e.released_mask else 0, net_kept, pop_after, still_slow }) catch "");
}

// ── 5: 사람이 에이전트 탭의 prompt() 에 답한다(maru 의 대화상자 — dialog_reply) ──────────────────────────────────────────

var dialog_req: ?msg.RequestId = null;
var dialog_browser: u64 = 0;
fn hookDialog(m: msg.Message) void {
    switch (m) {
        .js_dialog => |v| if (v.browser == dialog_browser) {
            dialog_req = v.request;
        },
        else => {},
    }
}

fn c5DialogHuman(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "pc5d");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var o: [128]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/pc-t"));
    r.pump(400);
    dialog_browser = 1;
    emu.extra_hook = hookDialog;
    defer emu.extra_hook = null;
    // 둘째 판은 에이전트의 답(`browser.handleDialog` — maru 는 `user` 거짓으로 보낸다)이라 trace·조건이 남아야 한다. 대화상자 셋(prompt·confirm·
    // 파일)이 모두 같은 가름이다 — 여기서는 prompt(사람이 친 글이 페이지로 간다)와 confirm.
    const Case = struct { user: bool, js: []const u8, text: []const u8 };
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    for ([_]Case{
        .{ .user = true, .js = "setTimeout(function(){window.__p=prompt('q','')},10),'ok'", .text = "HUMANTYPED" },
        .{ .user = false, .js = "setTimeout(function(){window.__p=prompt('q','')},10),'ok'", .text = "AGENTTYPED" },
        .{ .user = true, .js = "setTimeout(function(){window.__p=confirm('q')},10),'ok'", .text = "" },
    }) |c| {
        _ = try r.emulate(1, perf.cpuOn(2));
        dialog_req = null;
        const g = try start(r, 1, 3000, false);
        r.pump(200);
        _ = r.ev(1, c.js, &o);
        const t0 = os.nowMs();
        while (dialog_req == null and os.nowMs() - t0 < 5000) r.pump(20);
        if (dialog_req) |req| r.host.send(.{ .dialog_reply = .{ .browser = 1, .request = req, .accept = true, .text = c.text, .user = c.user } }) catch {};
        const st = perf.waitFinished(r, g, 30_000);
        r.pump(300);
        const val = r.ev(1, "String(window.__p)", &o);
        const em = r.st[1];
        const released = em != null and em.?.released_mask & cpu_bit != 0;
        _ = try r.emulate(1, .{ .browser = 0 });
        const discarded = st != null and st.?.state == .discarded and st.?.reason == .human_input;
        const done = st != null and st.?.state == .done;
        if (dialog_req == null) bad += 1;
        if (c.user and (!discarded or !released)) bad += 1;
        if (!c.user and (!done or released)) bad += 1;
        line.print("{s} 답(user {}, 대화상자 받음 {}) → trace {s}/{s}, CPU 풀림 {}, 페이지가 받은 글 {s}; ", .{ if (c.user) "사람" else "에이전트", c.user, dialog_req != null, stName(st), rsName(st), released, val }) catch {};
        r.pump(500);
    }
    report(bad == 0, "c5-dialog-reply-human", line.buffered());
}

// ── V-15: 늦은 시작 답(draining)과 탭 닫힘·렌더러 죽음·sidecar 종료의 경주 ─────────────────────────────────────────────

const RaceKind = enum { close, kill, shutdown, none };

fn c15Race(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var line: std.Io.Writer = .fixed(&dbuf);
    var bad: usize = 0;
    const jank_ms: i64 = 6500;
    const Case = struct { k: RaceKind, off: i64 };
    const cases = [_]Case{
        .{ .k = .none, .off = 0 },
        .{ .k = .close, .off = -60 },
        .{ .k = .close, .off = -15 },
        .{ .k = .close, .off = 0 },
        .{ .k = .close, .off = 10 },
        .{ .k = .close, .off = 40 },
        .{ .k = .kill, .off = -20 },
        .{ .k = .kill, .off = 0 },
        .{ .k = .kill, .off = 20 },
        .{ .k = .shutdown, .off = -20 },
        .{ .k = .shutdown, .off = 0 },
        .{ .k = .shutdown, .off = 20 },
    };
    const crash0 = crashReports();
    for (cases, 0..) |c, ci| {
        var sess: Session = undefined;
        var nb: [32]u8 = undefined;
        try emu.open(&sess, host_path, root, std.fmt.bufPrint(&nb, "pc15r_{d}", .{ci}) catch "pc15r");
        const r = &sess.run;
        var u: [256]u8 = undefined;
        var o: [64]u8 = undefined;
        try r.create(1, emu.uLoop(&u, "/pc-t"));
        try r.create(2, emu.uLocal(&u, "/pc-t?b"));
        r.pump(500);
        var jb: [96]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&jb, "setTimeout(function(){{JANK({d})}},30),'ok'", .{jank_ms}) catch "0", &o);
        const tj = os.nowMs() + 30;
        r.pump(150);
        const g = try perf.startTrace(r, 1, 2000, false);
        r.pump(50);
        r.host.send(.{ .trace = .{ .browser = 1, .generation = g, .action = .abort } }) catch {};
        const at = tj + jank_ms + c.off;
        while (os.nowMs() < at) r.pump(1);
        var exit_code: ?u8 = null;
        switch (c.k) {
            .close => r.host.send(.{ .destroy_browser = 1 }) catch {},
            .kill => _ = r.killRenderers(),
            .shutdown => {
                r.host.send(.shutdown) catch {};
                while (r.host.next(2000) catch null) |_| {}
                exit_code = r.host.wait(30_000);
            },
            .none => {},
        }
        if (c.k == .shutdown) {
            // `Session.deinit` 은 다시 shutdown·wait 를 한다 — 이미 거뒀으니 받는 쪽만 닫는다.
            sess.receiver.close();
            line.print("shutdown {d} ms: 종료 코드 {?d}; ", .{ c.off, exit_code }) catch {};
            if (exit_code == null or exit_code.? != 0) bad += 1;
            continue;
        }
        defer sess.deinit();
        r.pump(3000);
        if (c.k == .kill) {
            try r.action(2, .reload);
            r.pump(500);
        }
        const e2 = r.ev(2, "1+1", &o);
        const alive = eql(e2, "2");
        const g2 = perf.startTrace(r, 2, 1000, false) catch 0;
        const st2 = perf.waitFinished(r, g2, 30_000);
        const next_ok = st2 != null and st2.?.state == .done;
        if (!alive or !next_ok) bad += 1;
        line.print("{s} {d} ms: 살아 있음 {} 다른 탭 다음 trace {s}/{s}; ", .{ @tagName(c.k), c.off, alive, stName(st2), rsName(st2) }) catch {};
    }
    os.sleepMs(6000); // ReportCrash 가 보고를 쓸 때까지
    const crash1 = crashReports();
    line.print("크래시 보고 {d} → {d}", .{ crash0, crash1 }) catch {};
    if (crash1 != crash0) bad += 1;
    report(bad == 0, "c15-late-start-races", line.buffered());
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    if (std.c.getenv("W9E2C_HOST_ARG")) |a| host_mod.extra_arg = a;
    if (std.c.getenv("W9E2C_HOST_ARG2")) |a| host_mod.extra_arg2 = a;
    try emu.startServer();
    try perf.setup(host_path, root);
    root_dir = root;
    const probes = .{
        .{ "c2-worker", c2UserWorker },
        .{ "c12-limit", c12ProcLimit },
        .{ "c7-sticky", c7Sticky },
        .{ "c3-grand", c3Grandchild },
        .{ "c5-popup", c5FamilyPopupHuman },
        .{ "c5-dialog", c5DialogHuman },
        .{ "c15-race", c15Race },
    };
    var names: [probes.len][]const u8 = undefined;
    var ran: usize = 0;
    inline for (probes, 0..) |p, i| {
        names[i] = p[0];
        if (only(p[0])) {
            ran += 1;
            p[1](report, host_path, root) catch |e| report(false, p[0], @errorName(e));
        }
    }
    select.verify(report, "W9E2C_ONLY", "w9e2c-selection", &names, ran);
    if (ran > 0) select.noReentrancy(report, root, "w9e2c-no-observer-reentrancy");
}
