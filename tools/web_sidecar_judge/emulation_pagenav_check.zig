//! W9e① (g) 판정 — 페이지가 시작한 이동의 흉내 틈(사용자 결정 2026-11-17 「틈 막기」, docs/plans/web-osr-backend.md 「W9e 후속 — 흉내 전용
//! 세션」). 사이트에 묶인 흉내(판정자의 `bound_all` — 사이트 127.0.0.1)를 건 탭에서 **페이지가** 사이트 밖(localhost)으로 가면 밖 문서의 첫
//! 스크립트·pageshow·그때의 요청이 흉내를 보지 않는다 — 흉내는 sidecar 가 그 탭의 page 타깃에 붙인 자식 세션으로 걸고, 떠나는 문서의 응답에서 그
//! 세션을 뗀다(`emulation.zig`·`emu_inject.zig`). 고치기 전 같은 꼴(묶인 문서가 밖 사이트의 iframe 을 품어 그 렌더러가 이미 떠 있다 — 「데워진
//! 렌더러」)에서 보통 부하 39/100·무거운 부하 50/50 이 샜다(재실측 2026-11-17 — 계획 기록 `$S/emu_pagenav/PLAN2.md`).
//!
//! 세션 `emq` 하나(sidecar 의 host 로그 `emq.host.log` — `MARU_WEB_TEST_EMU_LOG`):
//! - emu-page-nav-<종류>: `location.href=`·`a.click()`·사람의 누름(maru `mouse`)·`<meta refresh>`·폼 POST·`location.replace`·`history.back()`·
//!   `history.go(-2)`·에이전트 CDP 의 뒤로(`Page.navigateToHistoryEntry` — U2)·maru 의 주소 이동(#4721 게이트와 겹침) — 판마다 묶인 문서가 모든 흉내를 본 뒤(`in_ok`) 밖으로 가서, 밖 문서의 첫 스크립트·
//!   pageshow·지금·첫 요청·pageshow 의 요청·문서 요청 머리가 모두 진짜(`EMQ_ITERS` 판, 기본 3).
//! - emu-page-nav-detach-order: 위 판들의 host 로그 — 떠날 때마다 응답으로 뗀 줄(`detach resp`)이 하나씩, 「떼기 전에 커밋」 0 줄, 늦은 떼기 0 줄
//!   (응답 시각 → 떼기 µs 와 떼기 → 커밋 µs 를 적는다 — U5: 차례는 실측이 근거다).
//! - emu-page-nav-set-reload: 처음 거는 흉내 곧 뒤의 새로고침 — 세션을 붙이는 동안 maru 의 이동은 기다린다(새 문서의 요청·첫 스크립트가 흉내).
//! - emu-page-nav-two-tabs: 같은 사이트에 묶인 다른 탭은 한 탭이 떠나도 흉내 그대로(무장·떼기는 탭마다).
//! - emu-page-nav-redirect: 사이트 안 주소가 302 로 밖에 보낸다 — 첫 스크립트·첫 요청은 진짜(단언), 그 홉의 문서 요청 머리는 E12(관측).
//! - emu-page-nav-slow-wait: 밖으로 가는 느린 응답(1.5 초)을 기다리는 동안 묶인 문서는 흉내를 그대로 본다(떼기는 응답에서 — 홉에서 떼면 진짜를
//!   본다), 도착한 밖 문서는 진짜.
//! - emu-page-nav-aborted·-download: 밖 주소의 204·다운로드(응답 뒤 문서 없음) — 응답에서 뗀 뒤 남은 묶인 문서에 새 세션으로 다시 건다.
//! - emu-page-nav-bounce: 밖 문서가 첫 스크립트에서 곧 돌아온다 — 밖 문서는 진짜, 돌아온 묶인 문서는 결국 모든 흉내, 세션을 잃지 않는다.
//! - emu-page-nav-watch·-mock: 지켜보기(`net_watch` — 기록 처리기)·가짜(밖 문서를 가짜로 — 가짜 처리기) 처리기가 그 요청을 가져가도 같은 단언.
//! - emu-page-nav-body-record: 본문 기록(W9d② — 그 관찰자가 남의 page 세션 붙음을 떼던 자리)이 켜진 탭에서도 흉내가 걸리고 세션을 잃지 않는다.
//! - emu-page-nav-dead: 렌더러가 죽은 묶인 탭 — host 가 살고, maru 의 밖 이동 문서는 진짜, 돌아오면 다시 흉내.
//! - emu-page-nav-route-switch: 사이트에 묶이지 않은 흉내(root)에서 곧 묶인 흉내로 바뀌면 root 에 건 것을 먼저 지운다.
//! - emu-page-nav-sw-late: 서비스 워커가 답한 밖 문서(응답 콜백 없음)는 커밋에서 뗀다(늦은 길).
//! - emu-page-nav-sw(obs)·-prefetch(obs)·-block(obs): 응답 콜백이 없을 수 있는 이동(서비스 워커가 답한 밖 문서·speculation prefetch 된 밖 문서·막힌
//!   밖 문서의 오류 페이지) — 어느 길(응답·늦은 떼기)로 갔는지와 샌 수를 적는다(U4 — 지금과 같은 경주로 떨어지는지).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const emu = @import("emulation_check.zig");

const msg = protocol.message;
const Run = emu.Run;
const Session = emu.Session;
const Report = emu.Report;
const contains = emu.contains;
const uLoop = emu.uLoop;
const uLocal = emu.uLocal;

/// `bound_all` 의 모든 흉내가 보일 때의 `SG()`.
const full_emu = "tz.il.ua.lang.iw.dpr.mtp.print.fc";

// ── 페이지 ────────────────────────────────────────────────────────────────────────────────────────────────

/// 밖 문서(localhost): 첫 스크립트(`T0`)·그 요청(`/qnf`)·pageshow(`PS`)·그 요청(`/qns`)·400 ms 뒤 요청(`/qnl`).
const qn_js = emu.sg_js ++
    \\
    \\window.T0=SG();var q=location.search.slice(1);fetch('/qnf?'+q+'&e='+T0).catch(function(){});window.PS=[];
    \\addEventListener('pageshow',function(e){var s=SG();PS.push((e.persisted?'P':'N')+':'+s);fetch('/qns?'+q+'&e='+s).catch(function(){})});
    \\setTimeout(function(){fetch('/qnl?'+q+'&e='+SG()).catch(function(){})},400);
;
const qn_html = "<!doctype html><title>qn</title><script>" ++ qn_js ++ "</script>";

/// 묶인 문서(127.0.0.1): 화면 가득 링크(사람의 누름), `NAV(종류, 주소)`, `sb=1` 이면 100 ms 마다 제가 보는 것을 서버로(`/qib`).
const qi_html = "<!doctype html><title>qi</title><body style='margin:0'><a id=a href='#' style='position:fixed;left:0;top:0;width:100%;height:100%;display:block;background:#eee'>link</a><script>" ++ emu.sg_js ++
    \\
    \\window.T0=SG();var q=location.search.slice(1);
    \\if(q.indexOf('sb=1')>=0){setInterval(function(){fetch('/qib?'+q+'&e='+SG()).catch(function(){})},100)}
    \\window.NAV=function(k,u){if(k==='ulink'){document.getElementById('a').href=u;return k}
    \\setTimeout(function(){
    \\if(k==='loc')location.href=u;
    \\else if(k==='rep')location.replace(u);
    \\else if(k==='link'){var a=document.getElementById('a');a.href=u;a.click()}
    \\else if(k==='fpost'){var f=document.createElement('form');f.method='POST';f.action=u;var h=document.createElement('input');h.name='x';h.value='1';f.appendChild(h);document.body.appendChild(f);f.submit()}
    \\else if(k==='meta'){var m=document.createElement('meta');m.httpEquiv='refresh';m.content='0;url='+u;document.head.appendChild(m)}
    \\else if(k==='back')history.back();
    \\else if(k==='go2')history.go(-2);
    \\},0);return k};
    \\window.PF=function(u){var s=document.createElement('script');s.type='speculationrules';s.textContent=JSON.stringify({prefetch:[{source:'list',urls:[u]}]});document.head.appendChild(s);return 'pf'};
    \\</script>
;

/// 서비스 워커가 문서를 답하는 밖 페이지(`/qsw…` — 그 워커가 `fetch(e.request)` 로 답한다).
const qsw_js =
    \\self.addEventListener('install',function(e){self.skipWaiting()});self.addEventListener('activate',function(e){e.waitUntil(clients.claim())});
    \\self.addEventListener('fetch',function(e){if(e.request.mode==='navigate')e.respondWith(fetch(e.request))});
;
const qsw_html = "<!doctype html><title>qsw</title><script>" ++ qn_js ++
    \\
    \\window.REG=function(){return navigator.serviceWorker.register('/qsw.js',{scope:'/qsw'}).then(function(){return navigator.serviceWorker.ready}).then(function(){return 'ready'},function(e){return 'err '+e})};
    \\</script>
;

/// 이 판정의 주소(`emulation_check.serveParsed` 가 먼저 부른다). 맡으면 참.
pub fn serve(conn: c_int, path: []const u8, target: []const u8, host_hdr: []const u8) bool {
    _ = host_hdr;
    var bb: [8192]u8 = undefined;
    if (std.mem.eql(u8, path, "/qn") or std.mem.eql(u8, path, "/qnb")) {
        emu.replyCacheable(conn, qn_html);
        return true;
    }
    if (std.mem.eql(u8, path, "/qi")) {
        if (std.mem.indexOf(u8, target, "w=1") != null) {
            const body = std.fmt.bufPrint(&bb, "{s}<iframe src='http://localhost:{d}/ifr?warm'></iframe>", .{ qi_html, emu.port }) catch return true;
            emu.replyCacheable(conn, body);
        } else emu.replyCacheable(conn, qi_html);
        return true;
    }
    if (std.mem.eql(u8, path, "/qr")) {
        // 묶인 사이트(127.0.0.1)의 주소가 밖에 보낸다 — 처리기는 첫 홉(안)에서 고른다.
        const q = target[(std.mem.indexOfScalar(u8, target, '?') orelse target.len)..];
        const loc = std.fmt.bufPrint(&bb, "Location: http://localhost:{d}/qn{s}\r\n", .{ emu.port, q }) catch return true;
        emu.reply(conn, "302 Found", "text/plain", loc, "qr");
        return true;
    }
    if (std.mem.eql(u8, path, "/qnc")) {
        emu.reply(conn, "204 No Content", "text/plain", "", "");
        return true;
    }
    if (std.mem.eql(u8, path, "/qdl")) {
        // 응답 뒤에야 문서가 아님이 드러나는 이동(다운로드) — 주 프레임 이동이 끊기고 옛 문서가 남는다.
        emu.reply(conn, "200 OK", "application/octet-stream", "Content-Disposition: attachment; filename=\"q.bin\"\r\n", "qdl");
        return true;
    }
    if (std.mem.eql(u8, path, "/qbk")) {
        // 밖 문서가 첫 스크립트에서 곧 묶인 사이트로 되돌아간다(떼고 다시 붙이는 사이에 돌아옴).
        const q = target[(std.mem.indexOfScalar(u8, target, '?') orelse target.len)..];
        const body = std.fmt.bufPrint(&bb, "<!doctype html><title>qbk</title><script>{s}\nwindow.T0=SG();fetch('/qbf'+location.search+'&e='+T0).catch(function(){{}});location.replace('http://127.0.0.1:{d}/qi{s}b&w=1')</script>", .{ emu.sg_js, emu.port, q }) catch return true;
        emu.reply(conn, "200 OK", emu.html, "", body);
        return true;
    }
    if (std.mem.eql(u8, path, "/qslow")) {
        os.sleepMs(1500);
        emu.reply(conn, "200 OK", emu.html, "", qn_html);
        return true;
    }
    if (std.mem.eql(u8, path, "/qsw.js")) {
        emu.reply(conn, "200 OK", "text/javascript", "", qsw_js);
        return true;
    }
    if (std.mem.eql(u8, path, "/qsw")) {
        emu.reply(conn, "200 OK", emu.html, "", qsw_html);
        return true;
    }
    return false;
}

// ── 판 하나 ──────────────────────────────────────────────────────────────────────────────────────────────

const Tally = struct {
    runs: u32 = 0,
    in_ok: u32 = 0,
    arrived: u32 = 0,
    js: u32 = 0,
    first: u32 = 0,
    ps: u32 = 0,
    doc: u32 = 0,
    late: u32 = 0,
    sample: [400]u8 = undefined,
    sample_len: usize = 0,

    fn clean(self: *const Tally) bool {
        return self.runs > 0 and self.in_ok == self.runs and self.arrived == self.runs and self.js == 0 and self.first == 0 and self.ps == 0 and self.doc == 0;
    }

    fn text(self: *const Tally, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "판 {d} · 안 모든 흉내 {d} · 도착 {d} · 밖 첫 스크립트·pageshow 샘 {d} · 첫 요청 샘 {d} · pageshow 요청 샘 {d} · 문서 요청 머리 샘 {d} · 400 ms 뒤 샘 {d} · 보기 {s}", .{ self.runs, self.in_ok, self.arrived, self.js, self.first, self.ps, self.doc, self.late, self.sample[0..self.sample_len] }) catch "-";
    }
};

fn leaked(prefix: []const u8) bool {
    var l: emu.Leaks = undefined;
    emu.leaksOn(prefix, "localhost", &l);
    return l.seen > 0 or l.header > 0;
}

/// 판 하나: 묶인 문서로(maru — 밖→안, 커밋에서 흉내가 걸린다) → 모든 흉내를 보는지 → 그 종류로 밖(`out_path` — 기본 `/qn`)으로 → 밖 문서가 본 것.
fn oneNav(r: *Run, kind: []const u8, tag: []const u8, out_base: []const u8, t: *Tally) !void {
    var u: [256]u8 = undefined;
    var uo: [256]u8 = undefined;
    var js: [600]u8 = undefined;
    var d: [600]u8 = undefined;
    var opb: [96]u8 = undefined;
    const out_path = std.fmt.bufPrint(&opb, "{s}?x={s}", .{ out_base, tag }) catch unreachable;
    var ipb: [96]u8 = undefined;
    const in_path = std.fmt.bufPrint(&ipb, "/qi?x={s}&w=1", .{tag}) catch unreachable;
    var ipb2: [96]u8 = undefined;
    const in_path2 = std.fmt.bufPrint(&ipb2, "/qi?x={s}b&w=1", .{tag}) catch unreachable;
    const out_url = if (std.mem.eql(u8, out_base, "/qr")) uLoop(&uo, out_path) else uLocal(&uo, out_path);
    if (std.mem.eql(u8, kind, "back") or std.mem.eql(u8, kind, "cdpback")) {
        try r.nav(1, uLocal(&u, out_path));
        try r.nav(1, uLoop(&u, in_path));
    } else if (std.mem.eql(u8, kind, "go2")) {
        try r.nav(1, uLocal(&u, out_path));
        try r.nav(1, uLoop(&u, in_path));
        try r.nav(1, uLoop(&u, in_path2));
    } else try r.nav(1, uLoop(&u, in_path));
    r.pump(300);
    var sgb: [80]u8 = undefined;
    const in_sg = r.ev(1, "SG()", &sgb);
    if (std.mem.eql(u8, in_sg, full_emu)) t.in_ok += 1;
    if (std.mem.eql(u8, kind, "mnav")) {
        try r.host.send(.{ .navigate = .{ .browser = 1, .url = out_url, .user = true } });
    } else if (std.mem.eql(u8, kind, "cdpback")) {
        // 에이전트 CDP 의 뒤로(`browser.back` 의 길 — `Page.navigateToHistoryEntry`, wire 를 지나지 않는다; U2).
        if (try r.call(1, "Page.getNavigationHistory", "{}", 5000)) |_| {
            var hb: [96]u8 = undefined;
            if (prevEntry(r.result.items)) |id| _ = try r.call(1, "Page.navigateToHistoryEntry", std.fmt.bufPrint(&hb, "{{\"entryId\":{d}}}", .{id}) catch unreachable, 5000);
        }
    } else if (std.mem.eql(u8, kind, "ulink")) {
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('ulink','{s}')", .{out_url}) catch unreachable, &d);
        r.userClick(1, 100, 100);
    } else {
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('{s}','{s}')", .{ kind, out_url }) catch unreachable, &d);
    }
    emu.settleNav(r, 1);
    var ob: [400]u8 = undefined;
    const o = r.ev(1, "JSON.stringify([location.host,T0,PS,SG()])", &ob);
    r.pump(500);
    t.runs += 1;
    const arrived = contains(o, "localhost");
    if (arrived) t.arrived += 1;
    const js_leak = arrived and emu.leakText(o);
    if (js_leak) t.js += 1;
    var pb: [4][96]u8 = undefined;
    if (leaked(std.fmt.bufPrint(&pb[0], "/qnf?x={s}&", .{tag}) catch unreachable)) t.first += 1;
    if (leaked(std.fmt.bufPrint(&pb[1], "/qns?x={s}&", .{tag}) catch unreachable)) t.ps += 1;
    if (leaked(std.fmt.bufPrint(&pb[2], "/qnl?x={s}&", .{tag}) catch unreachable)) t.late += 1;
    // 문서 요청 머리 — 302 판은 E12(그 홉의 요청은 늦다)라 따로 센다(부른 쪽이 관측으로).
    if (leaked(std.fmt.bufPrint(&pb[3], "/qn?x={s}", .{tag}) catch unreachable)) t.doc += 1;
    if (t.sample_len == 0 or js_leak) {
        const n = @min(o.len, t.sample.len);
        @memcpy(t.sample[0..n], o[0..n]);
        t.sample_len = n;
    }
}

/// `Page.getNavigationHistory` 의 답에서 지금 항목 바로 앞 항목의 id.
fn prevEntry(json: []const u8) ?i64 {
    const ci = std.mem.indexOf(u8, json, "\"currentIndex\":") orelse return null;
    var e = ci + 15;
    while (e < json.len and std.ascii.isDigit(json[e])) e += 1;
    const cur = std.fmt.parseInt(usize, json[ci + 15 .. e], 10) catch return null;
    if (cur == 0) return null;
    var at: usize = 0;
    var k: usize = 0;
    while (std.mem.indexOfPos(u8, json, at, "{\"id\":")) |i| : (at = i + 1) {
        if (k == cur - 1) {
            var j = i + 6;
            while (j < json.len and std.ascii.isDigit(json[j])) j += 1;
            return std.fmt.parseInt(i64, json[i + 6 .. j], 10) catch null;
        }
        k += 1;
    }
    return null;
}

fn iters() u32 {
    const v = std.c.getenv("EMQ_ITERS") orelse return 3;
    return @max(1, std.fmt.parseInt(u32, std.mem.span(v), 10) catch 3);
}

/// 그 host 로그 구간의 µs 값들(`key` 뒤 수 — `…dt=123us`)의 가장 작은·가운데·가장 큰.
fn spread(log: []const u8, key: []const u8, buf: []u8) []const u8 {
    var vals: [256]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        if (!contains(line, key)) continue;
        const w = emu.wordAfter(line, "dt=");
        const v = std.fmt.parseInt(u64, w[0 .. std.mem.indexOf(u8, w, "us") orelse w.len], 10) catch continue;
        if (n < vals.len) {
            vals[n] = v;
            n += 1;
        }
    }
    if (n == 0) return "-";
    std.mem.sort(u64, vals[0..n], {}, std.sort.asc(u64));
    return std.fmt.bufPrint(buf, "{d}개 {d}/{d}/{d} µs", .{ n, vals[0], vals[n / 2], vals[n - 1] }) catch "-";
}

pub fn run(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "emq");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [4096]u8 = undefined;
    var tb: [1200]u8 = undefined;
    const n = iters();
    try r.create(1, uLocal(&u, "/qn?x=init"));
    _ = try r.emulate(1, emu.bound_all);

    // (1) 종류마다 — 데워진 렌더러(묶인 문서가 밖 사이트의 iframe 을 품는다).
    const kinds = [_][]const u8{ "loc", "link", "ulink", "meta", "fpost", "rep", "back", "go2", "cdpback", "mnav" };
    const mark = emu.logLen(root, "emq");
    var leaves: u32 = 0;
    for (kinds) |k| {
        var t: Tally = .{};
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, k, std.fmt.bufPrint(&tg, "{s}{d}q", .{ k, i }) catch unreachable, "/qn", &t);
        }
        leaves += t.runs;
        var nb: [48]u8 = undefined;
        report(t.clean(), std.fmt.bufPrint(&nb, "emu-page-nav-{s}", .{k}) catch "emu-page-nav", t.text(&tb));
    }
    {
        const lg = emu.logFrom(root, "emq", mark);
        const resp = emu.countIn(lg, "emu: session b=1 detach resp dt=");
        const before = emu.countIn(lg, "before detach");
        const late = emu.countIn(lg, "emu: session b=1 detach late");
        var sb: [2][80]u8 = undefined;
        const s_resp = spread(lg, "detach resp dt=", &sb[0]);
        const s_commit = spread(lg, "commit after detach dt=", &sb[1]);
        report(resp == leaves and before == 0 and late == 0, "emu-page-nav-detach-order", std.fmt.bufPrint(&d, "떠남 {d} · 응답으로 뗌 {d} · 떼기 전에 커밋 {d} · 늦은 떼기 {d} · 응답→떼기 {s} · 떼기→커밋 {s}", .{ leaves, resp, before, late, s_resp, s_commit }) catch "");
    }

    // (1b) 같은 사이트에 묶인 탭 둘 — 한 탭이 떠나도 다른 탭의 세션은 그대로(무장·떼기는 탭마다).
    {
        try r.create(2, uLoop(&u, "/qi?x=two2&w=1"));
        _ = try r.emulate(2, emu.bound_all);
        r.pump(300);
        var t: Tally = .{};
        try oneNav(r, "loc", "twoq", "/qn", &t);
        var sgb: [80]u8 = undefined;
        const other = r.ev(2, "SG()", &sgb);
        report(t.clean() and std.mem.eql(u8, other, full_emu), "emu-page-nav-two-tabs", std.fmt.bufPrint(&d, "{s} · 다른 탭 {s}", .{ t.text(&tb), other }) catch "");
        try r.host.send(.{ .destroy_browser = 2 });
        r.pump(300);
    }

    // (1c) 처음 거는 흉내 곧 뒤의 새로고침(`browser.emulate … --reload` 의 꼴 — maru 는 흉내 frame 바로 뒤에 `nav_action reload` 를 낸다): 세션을 붙이는
    // 동안 새로고침은 기다린다 — 새 문서의 요청·첫 스크립트가 흉내(격리 앱에서 처음에 둘 다 진짜였다).
    {
        try r.create(3, uLoop(&u, "/qi?x=sr"));
        r.pump(300);
        r.gen[3] += 1;
        var e = emu.bound_all;
        e.browser = 3;
        e.generation = r.gen[3];
        const before = r.loads[3];
        try r.host.send(.{ .emulation = e });
        try r.host.send(.{ .nav_action = .{ .browser = 3, .action = .reload } });
        _ = r.until(Run.loadsAt, 3, before + 1, 5000);
        r.pump(500);
        var tb3: [80]u8 = undefined;
        const t0 = r.ev(3, "T0", &tb3);
        var ld: emu.Leaks = undefined;
        emu.leaksOn("/qi?x=sr", "127.0.0.1", &ld);
        // 처음 문서(흉내 전) 하나와 새로고침 문서 하나 — 새로고침 문서의 머리만 흉내여야 한다.
        report(std.mem.eql(u8, t0, full_emu) and ld.total == 2 and ld.header == 1, "emu-page-nav-set-reload", std.fmt.bufPrint(&d, "새로고침 문서 첫 스크립트 {s} · 문서 요청 {d}개(흉내 머리 {d})", .{ t0, ld.total, ld.header }) catch "");
        try r.host.send(.{ .destroy_browser = 3 });
        r.pump(300);
    }

    // (2) 사이트 안 주소의 302 로 떠남 — 첫 스크립트·그 요청은 진짜, 문서 요청 머리는 E12(관측).
    {
        const m2 = emu.logLen(root, "emq");
        var t: Tally = .{};
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, "loc", std.fmt.bufPrint(&tg, "redir{d}q", .{i}) catch unreachable, "/qr", &t);
        }
        const lg = emu.logFrom(root, "emq", m2);
        const resp = emu.countIn(lg, "emu: session b=1 detach resp dt=");
        const ok = t.runs == n and t.in_ok == n and t.arrived == n and t.js == 0 and t.first == 0 and t.ps == 0 and resp == n;
        report(ok, "emu-page-nav-redirect", std.fmt.bufPrint(&d, "{s} · 응답으로 뗌 {d} (문서 요청 머리 샘은 E12 — 관측)", .{ t.text(&tb), resp }) catch "");
    }

    // (3) 밖으로 가는 느린 응답을 기다리는 동안 — 묶인 문서는 흉내를 그대로 본다.
    {
        try r.nav(1, uLoop(&u, "/qi?x=slow&w=1&sb=1"));
        r.pump(400);
        var lb: emu.Leaks = undefined;
        emu.leaksOn("/qib?x=slow&", "127.0.0.1", &lb);
        const before_total = lb.total;
        const before_seen = lb.seen;
        var js: [300]u8 = undefined;
        var o1: [200]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('loc','{s}')", .{uLocal(&u, "/qslow?x=slowq")}) catch unreachable, &o1);
        _ = r.until(Run.loadsAt, 1, r.loads[1] + 1, 6000);
        r.pump(500);
        emu.leaksOn("/qib?x=slow&", "127.0.0.1", &lb);
        const wait_total = lb.total - before_total;
        const wait_seen = lb.seen - before_seen;
        var ob: [400]u8 = undefined;
        const o = r.ev(1, "JSON.stringify([location.host,T0,PS,SG()])", &ob);
        const clean = contains(o, "localhost") and !emu.leakText(o) and !leaked("/qnf?x=slowq&");
        report(wait_total >= 8 and wait_seen == wait_total and clean, "emu-page-nav-slow-wait", std.fmt.bufPrint(&d, "기다리는 동안 묶인 문서의 요청 {d}개 중 흉내를 본 것 {d}개(머리 흉내 {d} — 관측) · 도착한 밖 문서 {s}", .{ wait_total, wait_seen, lb.header, o }) catch "");
    }

    // (4) 밖 주소의 204 — 응답에서 뗀 뒤 남은 묶인 문서에 새 세션으로 다시 건다.
    {
        try r.nav(1, uLoop(&u, "/qi?x=nc&w=1"));
        r.pump(300);
        var sgb: [80]u8 = undefined;
        const before = r.ev(1, "SG()", &sgb);
        const m4 = emu.logLen(root, "emq");
        var js: [300]u8 = undefined;
        var o1: [200]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('loc','{s}')", .{uLocal(&u, "/qnc?x=ncq")}) catch unreachable, &o1);
        r.pump(800);
        var ab: [200]u8 = undefined;
        const after = r.ev(1, "JSON.stringify([location.host,SG()])", &ab);
        const st = r.st[1];
        const lg = emu.logFrom(root, "emq", m4);
        const resp = emu.countIn(lg, "emu: session b=1 detach resp dt=");
        const ready = emu.countIn(lg, "emu: session b=1 ready");
        const ok = std.mem.eql(u8, before, full_emu) and contains(after, "127.0.0.1") and contains(after, full_emu) and st != null and st.?.on_site and !st.?.pending and resp == 1 and ready >= 1;
        report(ok, "emu-page-nav-aborted", std.fmt.bufPrint(&d, "전 {s} · 204 뒤 {s} on_site={} pending={} · 응답으로 뗌 {d} · 새 세션 ready {d}", .{ before, after, if (st) |x| x.on_site else false, if (st) |x| x.pending else true, resp, ready }) catch "");
    }

    // (4b) 응답 뒤 다운로드 — 응답에서 뗀 뒤 끊긴 이동, 남은 묶인 문서에 새 세션으로 다시 건다(그 사이 몇 ms 는 흉내 없이 — 받아들임 U4).
    {
        try r.nav(1, uLoop(&u, "/qi?x=dl&w=1"));
        r.pump(300);
        const m4 = emu.logLen(root, "emq");
        var js: [300]u8 = undefined;
        var o1: [200]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('loc','{s}')", .{uLocal(&u, "/qdl?x=dlq")}) catch unreachable, &o1);
        r.pump(1200);
        var ab: [200]u8 = undefined;
        const after = r.ev(1, "JSON.stringify([location.host,SG()])", &ab);
        const lg = emu.logFrom(root, "emq", m4);
        const resp = emu.countIn(lg, "emu: session b=1 detach resp dt=");
        report(contains(after, "127.0.0.1") and contains(after, full_emu) and resp == 1, "emu-page-nav-download", std.fmt.bufPrint(&d, "다운로드 뒤 {s} · 응답으로 뗌 {d}", .{ after, resp }) catch "");
    }

    // (4c) 빠른 되돌아옴 — 밖 문서가 첫 스크립트에서 곧 묶인 사이트로(새 세션이 붙기 전일 수 있다): 밖 문서는 진짜, 돌아온 묶인 문서는 결국 모든 흉내.
    {
        try r.nav(1, uLoop(&u, "/qi?x=bk&w=1"));
        r.pump(300);
        const m4 = emu.logLen(root, "emq");
        var js: [300]u8 = undefined;
        var o1: [200]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('loc','{s}')", .{uLocal(&u, "/qbk?x=bkq")}) catch unreachable, &o1);
        _ = r.until(Run.loadsAt, 1, r.loads[1] + 2, 5000);
        r.pump(800);
        var ab: [200]u8 = undefined;
        const back = r.ev(1, "JSON.stringify([location.host,SG()])", &ab);
        var lb: emu.Leaks = undefined;
        emu.leaksOn("/qbf?x=bkq", "localhost", &lb);
        const lg = emu.logFrom(root, "emq", m4);
        const lost = emu.countIn(lg, "emu: session b=1 lost");
        report(lb.total >= 1 and lb.seen == 0 and lb.header == 0 and contains(back, "127.0.0.1") and contains(back, full_emu) and lost == 0, "emu-page-nav-bounce", std.fmt.bufPrint(&d, "밖 문서 첫 요청 {d}개(흉내 {d}·머리 {d}) · 돌아온 문서 {s} · 세션 잃음 {d}", .{ lb.total, lb.seen, lb.header, back, lost }) catch "");
    }

    // (5) 지켜보기(기록 처리기)·가짜(기록 안 함·함) — 다른 처리기가 그 요청을 가져가도 응답 콜백이 떼기를 부른다.
    {
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = true, .full = true, .any_host = true } });
        r.pump(100);
        var t: Tally = .{};
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, "loc", std.fmt.bufPrint(&tg, "watch{d}q", .{i}) catch unreachable, "/qn", &t);
        }
        report(t.clean(), "emu-page-nav-watch", t.text(&tb));
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } });
        r.pump(100);
    }
    // 가짜는 지켜보는 탭에서만 맺는다(`mocking.applyCommit`) — 가짜 처리기(`mocking.Slot`)가 문서 요청을 가져간다. 기록하지 않는 가짜 처리기(번호 0·문이 찬
    // 요청)는 판정이 만들 수 없다 — 같은 응답 콜백(`emu_inject.responseOnly`)을 단다.
    {
        const recorded = true;
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = true, .full = true, .any_host = true } });
        r.pump(100);
        // 주 프레임 문서의 가짜는 그 문서의 호스트가 규칙의 사이트일 때만 맞는다(`net_mock_table.decideTab` — 사이트는 localhost).
        var pat: [96]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pat, "http://localhost:{d}/qnm*", .{emu.port}) catch unreachable;
        const gen: u32 = 1;
        try r.host.send(.{ .net_mock_rule = .{ .browser = 1, .generation = gen, .index = 0, .id = gen, .types = 0, .methods = 0, .site = "localhost", .pattern = pattern, .status = 200, .body_id = gen, .body_len = @intCast(qn_html.len), .content_type = "text/html; charset=utf-8" } });
        try r.host.send(.{ .net_mock_commit = .{ .browser = 1, .generation = gen, .count = 1 } });
        try r.host.send(.{ .net_mock_body = .{ .browser = 1, .body_id = gen, .offset = 0, .total = @intCast(qn_html.len), .bytes = qn_html } });
        r.pump(300);
        const m5 = emu.logLen(root, "emq");
        var t: Tally = .{};
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, "loc", std.fmt.bufPrint(&tg, "mock{d}q", .{i}) catch unreachable, "/qnm", &t);
        }
        // 가짜 문서는 서버에 오지 않는다 — 문서 요청 머리 칸은 늘 0(서버가 받은 것이 없다). 서버에 왔으면 가짜가 아니었다.
        var lm: emu.Leaks = undefined;
        var mp: [40]u8 = undefined;
        emu.leaksOn(std.fmt.bufPrint(&mp, "/qnm?x=mock", .{}) catch unreachable, "localhost", &lm);
        const lg = emu.logFrom(root, "emq", m5);
        const resp = emu.countIn(lg, "emu: session b=1 detach resp dt=");
        report(t.clean() and lm.total == 0 and resp == n, "emu-page-nav-mock", std.fmt.bufPrint(&d, "{s} · 서버가 받은 가짜 주소 {d}(0 이어야 가짜) · 응답으로 뗌 {d}", .{ t.text(&tb), lm.total, resp }) catch "");
        try r.host.send(.{ .net_mock_commit = .{ .browser = 1, .generation = gen + 10, .count = 0 } });
        if (recorded) try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } }); // 지켜보기를 끄면 규칙도 버린다
        r.pump(200);
    }

    // (6) 본문 기록(W9d②)이 켜진 탭 — 그 관찰자가 우리 page 세션의 붙음을 떼지 않는다.
    {
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = true, .full = true, .any_host = true } });
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = true, .session = 7 } });
        r.pump(300);
        const m6 = emu.logLen(root, "emq");
        var t: Tally = .{};
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, "loc", std.fmt.bufPrint(&tg, "body{d}q", .{i}) catch unreachable, "/qn", &t);
        }
        const lg = emu.logFrom(root, "emq", m6);
        const lost = emu.countIn(lg, "emu: session b=1 lost");
        const ready = emu.countIn(lg, "emu: session b=1 ready");
        report(t.clean() and lost == 0 and ready <= n + 1, "emu-page-nav-body-record", std.fmt.bufPrint(&d, "{s} · 세션 잃음 {d} · ready {d}(떠남마다 하나 — 고리면 는다)", .{ t.text(&tb), lost, ready }) catch "");
        try r.host.send(.{ .net_record = .{ .browser = 1, .on = false } });
        try r.host.send(.{ .net_watch = .{ .browser = 1, .on = false } });
        r.pump(300);
    }

    // (7) 응답 콜백이 없을 수 있는 이동 — 서비스 워커가 답한 밖 문서, speculation prefetch, 막힌 밖 문서(관측).
    {
        try r.nav(1, uLocal(&u, "/qsw?x=reg"));
        var rb: [80]u8 = undefined;
        const reg = r.ev(1, "REG()", &rb);
        var t: Tally = .{};
        const m7 = emu.logLen(root, "emq");
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            try oneNav(r, "loc", std.fmt.bufPrint(&tg, "sw{d}q", .{i}) catch unreachable, "/qsw", &t);
        }
        const lg = emu.logFrom(root, "emq", m7);
        const late = emu.countIn(lg, "emu: session b=1 detach late commit");
        report(true, "emu-page-nav-sw(obs)", std.fmt.bufPrint(&d, "등록 {s} · {s} · 응답으로 뗌 {d} · 늦은 떼기 {d} · 떼기 전에 커밋 {d}", .{ reg, t.text(&tb), emu.countIn(lg, "detach resp dt="), late, emu.countIn(lg, "before detach") }) catch "");
        // 응답 콜백이 없는 이동은 늦은 길이 커밋에서 뗀다 — 그 세션이 밖 문서에 남지 않는다(샘 수는 지금과 같은 경주라 관측만).
        report(std.mem.eql(u8, reg, "ready") and late == n, "emu-page-nav-sw-late", std.fmt.bufPrint(&d, "서비스 워커가 답한 밖 문서 {d} 판 · 커밋에서 뗌 {d}", .{ n, late }) catch "");
    }
    {
        var t: Tally = .{};
        const m8 = emu.logLen(root, "emq");
        var i: u32 = 0;
        var pf_hits: usize = 0;
        while (i < n) : (i += 1) {
            var tg: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tg, "pf{d}q", .{i}) catch unreachable;
            try r.nav(1, uLoop(&u, "/qi?x=pfin&w=1"));
            r.pump(300);
            var js: [300]u8 = undefined;
            var o1: [200]u8 = undefined;
            var pu: [256]u8 = undefined;
            var pp: [64]u8 = undefined;
            _ = r.ev(1, std.fmt.bufPrint(&js, "PF('{s}')", .{uLocal(&pu, std.fmt.bufPrint(&pp, "/qn?x={s}", .{tag}) catch unreachable)}) catch unreachable, &o1);
            r.pump(800);
            var lp: emu.Leaks = undefined;
            var pq: [64]u8 = undefined;
            emu.leaksOn(std.fmt.bufPrint(&pq, "/qn?x={s}", .{tag}) catch unreachable, "localhost", &lp);
            pf_hits += lp.total;
            try oneNav(r, "link", tag, "/qn", &t);
        }
        const lg = emu.logFrom(root, "emq", m8);
        report(true, "emu-page-nav-prefetch(obs)", std.fmt.bufPrint(&d, "prefetch 로 서버가 미리 받은 문서 {d} · {s} · 응답으로 뗌 {d} · 늦은 떼기 {d} · 떼기 전에 커밋 {d}", .{ pf_hits, t.text(&tb), emu.countIn(lg, "detach resp dt="), emu.countIn(lg, "detach late"), emu.countIn(lg, "before detach") }) catch "");
    }
    {
        var pat: [96]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pat, "http://localhost:{d}/qnb*", .{emu.port}) catch unreachable;
        var v: msg.NetBlock = .{ .browser = 1, .generation = 1, .count = 1 };
        v.rules[0] = .{ .id = 1, .site = "127.0.0.1", .pattern = pattern };
        try r.host.send(.{ .net_block = v });
        r.pump(200);
        try r.nav(1, uLoop(&u, "/qi?x=blk&w=1"));
        r.pump(300);
        const m9 = emu.logLen(root, "emq");
        var js: [300]u8 = undefined;
        var o1: [200]u8 = undefined;
        _ = r.ev(1, std.fmt.bufPrint(&js, "NAV('loc','{s}')", .{uLocal(&u, "/qnb?x=blkq")}) catch unreachable, &o1);
        emu.settleNav(r, 1);
        var ob: [300]u8 = undefined;
        const o = r.ev(1, "location.href", &ob);
        const lg = emu.logFrom(root, "emq", m9);
        try r.host.send(.{ .net_block = .{ .browser = 1, .generation = 2, .count = 0 } });
        r.pump(200);
        report(true, "emu-page-nav-block(obs)", std.fmt.bufPrint(&d, "막힌 밖 문서 뒤 {s} · host 생존 {} · 응답으로 뗌 {d} · 늦은 떼기 {d}", .{ o, os.alive(r.host.pid), emu.countIn(lg, "detach resp dt="), emu.countIn(lg, "detach late") }) catch "");
    }

    // (7b) 길 바꿈 — 사이트에 묶이지 않은 흉내(root)에서 곧 묶인 흉내로(maru 는 마지막 상태만 보낸다): root 에 건 것을 먼저 지운다(그대로면 세션을 떼도
    // root 의 시간대가 밖 문서에 남는다).
    {
        try r.nav(1, uLoop(&u, "/qi?x=rs&w=1"));
        _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .timezone = true }, .timezone = "Asia/Tokyo" });
        var sgb0: [80]u8 = undefined;
        const root_only = r.ev(1, "SG()", &sgb0);
        _ = try r.emulate(1, emu.bound_all);
        var t: Tally = .{};
        try oneNav(r, "loc", "rsq", "/qn", &t);
        report(std.mem.eql(u8, root_only, "tz") and t.clean(), "emu-page-nav-route-switch", std.fmt.bufPrint(&d, "root 흉내 {s} → 묶인 흉내 · {s}", .{ root_only, t.text(&tb) }) catch "");
    }

    // (8) 렌더러가 죽은 묶인 탭 — host 가 살고, maru 의 밖 이동 문서는 진짜, 돌아오면 다시 흉내.
    {
        try r.nav(1, uLoop(&u, "/qi?x=dead&w=1"));
        r.pump(300);
        var sgb: [80]u8 = undefined;
        const before = r.ev(1, "SG()", &sgb);
        const killed = r.killRenderers();
        _ = r.until(goneAt1, 1, 0, 8000);
        r.pump(800);
        const alive_dead = os.alive(r.host.pid);
        try r.nav(1, uLocal(&u, "/qn?x=deadq"));
        var ob: [400]u8 = undefined;
        const o = r.ev(1, "JSON.stringify([location.host,T0,PS,SG()])", &ob);
        r.pump(500);
        const out_clean = contains(o, "localhost") and !emu.leakText(o) and !leaked("/qnf?x=deadq&");
        try r.nav(1, uLoop(&u, "/qi?x=dead2&w=1"));
        r.pump(500);
        var sgb2: [80]u8 = undefined;
        const back_in = r.ev(1, "SG()", &sgb2);
        const ok = std.mem.eql(u8, before, full_emu) and killed > 0 and alive_dead and out_clean and std.mem.eql(u8, back_in, full_emu) and os.alive(r.host.pid);
        report(ok, "emu-page-nav-dead", std.fmt.bufPrint(&d, "전 {s} · 렌더러 {d} 죽임 · host 생존 {} · 밖 문서 {s} · 돌아옴 {s}", .{ before, killed, alive_dead, o, back_in }) catch "");
    }
}

fn goneAt1(r: *Run, _: u64, _: u32) bool {
    return r.gone[1] >= 1;
}
