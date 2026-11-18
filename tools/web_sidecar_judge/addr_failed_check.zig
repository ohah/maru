//! 실패한 이동의 주소(사용자 결정 2026-11-18 「사람이 친 주소」) — 주 프레임 이동이 오류 페이지로 끝나면 sidecar 의 `error_page` 가 실패한 주소
//! (CEF `on_load_error` 의 `failed_url` — 마지막 리다이렉트 홉)를 싣는가, 그 앞뒤에 `url_changed`·`page_started` 가 어떻게 오는가(maru 의 주소창은
//! 이 셋으로 「보이는 주소」 를 정한다 — `web_osr.shownUrl`). 판정자가 **maru 역할**로 이동을 보내고 받은 사건을 차례대로 적는다.
//!
//!   af-refused     접속을 거절하는 주소(`127.0.0.1:1` — Chromium 은 ERR_UNSAFE_PORT 로 끝낸다)로 친 이동 → `error_page.url` 이 그 주소
//!   af-dns         풀리지 않는 호스트(`.invalid`) → `error_page.url` 이 그 주소(ERR_NAME_NOT_RESOLVED)
//!   af-redirect    302 로 실패하는 주소로 가는 이동 → `error_page.url` 이 마지막 홉(처음 주소가 아니라)
//!   af-blocked     막기 규칙(-20) → `error_page.url` 이 막힌 주소, 규칙 번호도
//!   af-reload      오류 페이지에서 새로 고침 → 같은 실패 주소로 다시 `error_page`
//!   af-no-address  오류 페이지마다 `url_changed`·`page_started` 가 따라오지 않는다(maru 가 실패 주소를 지우지 않게 — 관찰을 단언으로)
//!   af-back        뒤로 → `page_started`·`url_changed` 가 옛 문서의 주소로 온다(maru 는 여기서 실패 주소를 지운다)
//!   af-noncommit   오류 페이지를 세우지 않는 실패(안전하지 않은 리다이렉트·알 수 없는 스킴)에서 무엇이 오는가(관찰)
//!   af-aborted     문서 없이 끝난 이동(다운로드 — ERR_ABORTED)은 `error_page` 가 없다(주소창은 그대로 — Chrome 과 같다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const msg = protocol.message;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 41;
const wait_ms = 15_000;

const Kind = enum { url_changed, page_started, error_page };
const Event = struct { kind: Kind, url: [256]u8 = undefined, url_len: usize = 0, code: i32 = 0, rule: u32 = 0 };

const Run = struct {
    host: *Host,
    events: [512]Event = undefined,
    n: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    state_gen: u32 = 0,

    fn title(self: *const Run) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn push(self: *Run, kind: Kind, url: []const u8, code: i32, rule: u32) void {
        if (self.n == self.events.len) return;
        var e: Event = .{ .kind = kind, .code = code, .rule = rule };
        e.url_len = @min(url.len, e.url.len);
        @memcpy(e.url[0..e.url_len], url[0..e.url_len]);
        self.events[self.n] = e;
        self.n += 1;
    }

    fn step(self: *Run) void {
        const m = (self.host.next(20) catch null) orelse return;
        switch (m) {
            .url_changed => |v| if (v.browser == browser_id) self.push(.url_changed, v.url, 0, 0),
            .page_started => |id| if (id == browser_id) self.push(.page_started, "", 0, 0),
            .error_page => |v| if (v.browser == browser_id) self.push(.error_page, v.url, v.error_code, v.blocked_rule),
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .net_block_state => |v| if (v.browser == browser_id) {
                self.state_gen = v.generation;
            },
            else => {},
        }
    }

    fn pump(self: *Run, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    fn untilTitle(self: *Run, want: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.eql(u8, self.title(), want)) return true;
            self.step();
        }
        return std.mem.eql(u8, self.title(), want);
    }

    /// `from` 번째 사건부터 첫 `error_page` 를 기다린다.
    fn untilError(self: *Run, from: usize, ms: u32) ?Event {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            for (self.events[from..self.n]) |e| if (e.kind == .error_page) return e;
            self.step();
        }
        for (self.events[from..self.n]) |e| if (e.kind == .error_page) return e;
        return null;
    }

    fn countFrom(self: *const Run, from: usize, kind: Kind) usize {
        var c: usize = 0;
        for (self.events[from..self.n]) |e| {
            if (e.kind == kind) c += 1;
        }
        return c;
    }

    fn lastUrlChanged(self: *const Run, from: usize) ?[]const u8 {
        var i = self.n;
        while (i > from) {
            i -= 1;
            if (self.events[i].kind == .url_changed) return self.events[i].url[0..self.events[i].url_len];
        }
        return null;
    }

    /// 사람의 이동(주소창)으로 보내고 그 `error_page` 를 기다린 뒤 1 초 더 받는다(뒤따르는 사건을 본다).
    fn failNav(self: *Run, url: []const u8) !struct { from: usize, ep: ?Event } {
        const from = self.n;
        try self.host.send(.{ .navigate = .{ .browser = browser_id, .url = url, .user = true } });
        const ep = self.untilError(from, wait_ms);
        self.pump(1000);
        return .{ .from = from, .ep = ep };
    }
};

fn urlOf(e: *const ?Event) []const u8 {
    if (e.*) |*v| return v.url[0..v.url_len];
    return "(없음)";
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var d: [600]u8 = undefined;
    var u: [256]u8 = undefined;
    var ub2: [256]u8 = undefined;

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 800, .height = 600, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/title?t=af-start") } });
    var r: Run = .{ .host = &host };
    if (!r.untilTitle("af-start", wait_ms)) return error.StartPageNotReady;
    r.pump(300);
    var follow: usize = 0; // 오류 페이지 뒤에 따라온 url_changed·page_started 수(모든 경우의 합)

    // 접속 거절(안전하지 않은 포트).
    const refused = "http://127.0.0.1:1/af-refused";
    const a = try r.failNav(refused);
    follow += r.countFrom(a.from, .url_changed) + r.countFrom(a.from, .page_started);
    report(a.ep != null and std.mem.eql(u8, urlOf(&a.ep), refused), "af-refused", std.fmt.bufPrint(&d, "error_page {?d} · url {s}(가려던 {s} 이어야)", .{ if (a.ep) |e| e.code else null, urlOf(&a.ep), refused }) catch "");

    // 풀리지 않는 호스트.
    const dns = "http://maru-af-test.invalid/af-dns";
    const b = try r.failNav(dns);
    follow += r.countFrom(b.from, .url_changed) + r.countFrom(b.from, .page_started);
    report(b.ep != null and std.mem.eql(u8, urlOf(&b.ep), dns), "af-dns", std.fmt.bufPrint(&d, "error_page {?d} · url {s}", .{ if (b.ep) |e| e.code else null, urlOf(&b.ep) }) catch "");

    // 리다이렉트 — 마지막 홉.
    const c = try r.failNav(browsers_check.url(&u, port, "/af-redirect"));
    follow += r.countFrom(c.from, .url_changed) + r.countFrom(c.from, .page_started);
    report(c.ep != null and std.mem.eql(u8, urlOf(&c.ep), "http://127.0.0.1:1/af-hop"), "af-redirect", std.fmt.bufPrint(&d, "error_page {?d} · url {s}(마지막 홉 http://127.0.0.1:1/af-hop 이어야)", .{ if (c.ep) |e| e.code else null, urlOf(&c.ep) }) catch "");

    // 막기 규칙.
    try host.send(.{ .net_watch = .{ .browser = browser_id, .on = true, .full = true, .any_host = true } });
    var v: msg.NetBlock = .{ .browser = browser_id, .generation = 1, .count = 1 };
    var pb: [96]u8 = undefined;
    v.rules[0] = .{ .id = 7, .site = "127.0.0.1", .pattern = std.fmt.bufPrint(&pb, "http://127.0.0.1:{d}/title", .{port}) catch unreachable };
    try host.send(.{ .net_block = v });
    const until = os.nowMs() + wait_ms;
    while (r.state_gen != 1 and os.nowMs() < until) r.step();
    const blocked = browsers_check.url(&ub2, port, "/title?t=af-blocked");
    const e = try r.failNav(blocked);
    follow += r.countFrom(e.from, .url_changed) + r.countFrom(e.from, .page_started);
    report(e.ep != null and std.mem.eql(u8, urlOf(&e.ep), blocked) and e.ep.?.code == -20 and e.ep.?.rule == 7, "af-blocked", std.fmt.bufPrint(&d, "error_page {?d} · 규칙 {?d} · url {s}", .{ if (e.ep) |x| x.code else null, if (e.ep) |x| x.rule else null, urlOf(&e.ep) }) catch "");

    // 오류 페이지에서 새로 고침 — 같은 실패 주소로 다시.
    const rl_from = r.n;
    try host.send(.{ .nav_action = .{ .browser = browser_id, .action = .reload, .user = true } });
    const rl = r.untilError(rl_from, wait_ms);
    r.pump(1000);
    follow += r.countFrom(rl_from, .url_changed) + r.countFrom(rl_from, .page_started);
    report(rl != null and std.mem.eql(u8, urlOf(&rl), blocked), "af-reload", std.fmt.bufPrint(&d, "새로 고침 → error_page url {s}", .{urlOf(&rl)}) catch "");
    try host.send(.{ .net_block = .{ .browser = browser_id, .generation = 2 } });
    r.pump(300);

    report(follow == 0, "af-no-address", std.fmt.bufPrint(&d, "오류 페이지 다섯 뒤 1 초 안에 온 url_changed·page_started {d} 개(0 이어야 — 오면 maru 가 실패 주소를 곧 지운다)", .{follow}) catch "");

    // 뒤로 — 오류 페이지 항목들을 지나 처음 문서까지. 첫 뒤로가 다시 실패하는 항목이면 그것도 error_page.
    const bk_from = r.n;
    for (0..5) |_| {
        try host.send(.{ .nav_action = .{ .browser = browser_id, .action = .back, .user = true } });
        r.pump(1500);
    }
    const back_url = r.lastUrlChanged(bk_from) orelse "(없음)";
    report(r.countFrom(bk_from, .page_started) >= 1 and std.mem.endsWith(u8, back_url, "/title?t=af-start"), "af-back", std.fmt.bufPrint(&d, "뒤로 다섯 — page_started {d} · error_page {d} · 마지막 url_changed {s}", .{ r.countFrom(bk_from, .page_started), r.countFrom(bk_from, .error_page), back_url }) catch "");

    // 오류 페이지를 세우지 않는 실패 — 옛 문서가 남으면 실패 주소를 싣지 않는다(주소 위장 막기). 안전하지 않은 리다이렉트(http → file:)·
    // 알 수 없는 스킴. 오류 페이지가 섰으면(Chromium 이 그렇게 끝내면) 그 주소를 싣는다 — 어느 쪽이든 싣는 주소는 프레임의 지금 주소와 같다.
    for ([_][]const u8{ "/af-unsafe-redirect", "", "/af-js?scheme", "/af-js?refused" }) |path| {
        const target = if (path.len > 0) browsers_check.url(&u, port, path) else "maru-af-unknown-scheme:x";
        const nc_from = r.n;
        try host.send(.{ .navigate = .{ .browser = browser_id, .url = target, .user = true } });
        r.pump(3500);
        var ep_url: []const u8 = "(error_page 없음)";
        for (r.events[nc_from..r.n]) |ev| if (ev.kind == .error_page) {
            ep_url = ev.url[0..ev.url_len];
        };
        report(true, "af-noncommit(obs)", std.fmt.bufPrint(&d, "{s} → error_page url 「{s}」 · url_changed {d} · page_started {d} · 제목 {s}", .{ target, ep_url, r.countFrom(nc_from, .url_changed), r.countFrom(nc_from, .page_started), r.title() }) catch "");
    }

    // 문서 없이 끝난 이동(다운로드).
    const ab_from = r.n;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/dl/f/attach"), .user = true } });
    r.pump(2500);
    report(r.countFrom(ab_from, .error_page) == 0, "af-aborted", std.fmt.bufPrint(&d, "다운로드 이동 뒤 error_page {d} 개(0 이어야) · url_changed {d}", .{ r.countFrom(ab_from, .error_page), r.countFrom(ab_from, .url_changed) }) catch "");
}
