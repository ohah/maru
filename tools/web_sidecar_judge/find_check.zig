//! P0-2 판정 — 페이지 찾기(⌘F)가 진짜 `maru-web-host` 에서 수와 차례를 maru 에 돌려주는가(docs/plans/web-osr-backend.md P0-2). 판정자가
//! **maru 역할**로 `find`·`find_stop` 을 보내고 `find_result` 를 받는다. 페이지(`/find`)에는 `apple` 이 일곱(소문자 여섯·대문자 하나),
//! `banana` 가 하나, `사과` 가 둘 있다.
//!
//!   find-identifier  첫 찾기의 답이 온다 — sidecar 는 CEF 의 identifier 가 host 의 `find` 부름 수와 같을 때만 보내므로(`protocol.find`),
//!                    CEF 가 그 규칙을 바꾸면 답이 하나도 안 온다(이 판정이 그것을 잡는다)
//!   find-first       새 찾기 `apple` → 마지막 답이 7 개·차례 1(대소문자 무시 — 대문자 하나도 센다)
//!   find-next        같은 글로 앞으로 두 번 → 차례 2·3, 뒤로 한 번 → 2
//!   find-wrap        차례 1 에서 뒤로 → 7(끝에서 처음으로 돈다 — WebKit 탭의 wraps 와 같은 규칙), 7 에서 앞으로 → 1
//!   find-korean      `사과` → 2 개
//!   find-none        없는 글 → 0 개·차례 0·마지막 답
//!   find-stale       새 찾기 둘을 잇달아(`apple` 뒤 곧 `banana`) — 뒤 번호의 답이 온 뒤에는 앞 번호의 답이 오지 않고, 마지막 답은 `banana` 1 개
//!   find-stop        마지막 답을 받은 뒤 멈추면 그 번호의 답은 더 오지 않는다(1.5 초) — 멈춘 뒤 같은 글은 **새로** 찾는다(차례 1)
//!   find-two-tabs    다른 브라우저의 찾기는 제 차례로 센다 — 둘째 탭의 첫 찾기(그 host 의 identifier 0)도 답한다, 첫 탭의 찾기는 그대로 이어진다
//!   find-keep        멈춤의 `keep_selection`(닫힌 오버레이의 ⌘G 뒤 — 그 탭이 키 포커스를 가진 때) — 지금 일치가 선택으로 남아 같은 글의 다음
//!                    찾기가 그 다음 차례에서 이어진다. 그냥 멈춤 뒤에는 처음부터(1/7)
//!   find-reload      찾은 채 같은 페이지로 이동하면 Chromium 이 같은 찾기를 새 문서에서 다시 하고 그 답이 같은 번호로 온다(수가 0 을 거쳐 7 로)
//!   find-unknown     모르는 브라우저의 찾기는 `failure unknown_browser`, 모르는 브라우저의 멈춤은 조용하다(탭이 닫힌 뒤 늦은 멈춤)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 31;
const wait_ms = 15_000;
const answer_ms = 5_000;

/// maru 역할의 관찰 — 받은 찾기 답과 제목, 실패.
const Finds = struct {
    host: *Host,
    /// 받은 답(차례대로, 넘치면 앞의 것을 버리지 않고 센 수만 올린다).
    got: [256]protocol.message.FindResult = undefined,
    got_len: usize = 0,
    total: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    unknown_failures: u32 = 0,

    fn title(self: *const Finds) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn step(self: *Finds) void {
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .find_result => |v| {
                self.total += 1;
                if (self.got_len < self.got.len) {
                    self.got[self.got_len] = v;
                    self.got_len += 1;
                }
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .failure => |v| if (v.code == .unknown_browser) {
                self.unknown_failures += 1;
            },
            else => {},
        }
    }

    fn pump(self: *Finds, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    fn untilTitle(self: *Finds, want: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.eql(u8, self.title(), want)) return true;
            self.step();
        }
        return std.mem.eql(u8, self.title(), want);
    }

    /// 그 번호의 마지막 답(`final`)을 기다린다 — 받은 답 가운데 그 번호의 마지막 것을 돌려준다.
    fn untilFinal(self: *Finds, request: u32, ms: u32) ?protocol.message.FindResult {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.lastOf(request)) |r| if (r.final) return r;
            self.step();
        }
        return self.lastOf(request);
    }

    fn lastOf(self: *const Finds, request: u32) ?protocol.message.FindResult {
        var i = self.got_len;
        while (i > 0) {
            i -= 1;
            if (self.got[i].request == request) return self.got[i];
        }
        return null;
    }

    fn countOf(self: *const Finds, request: u32) usize {
        var n: usize = 0;
        for (self.got[0..self.got_len]) |r| {
            if (r.request == request) n += 1;
        }
        return n;
    }

    fn find(self: *Finds, request: u32, text: []const u8, forward: bool) !void {
        try self.findIn(browser_id, request, text, forward);
    }

    fn findIn(self: *Finds, browser: u64, request: u32, text: []const u8, forward: bool) !void {
        try self.host.send(.{ .find = .{ .browser = browser, .request = request, .forward = forward, .text = text } });
    }

    /// 찾고 마지막 답을 기다린다.
    fn findFinal(self: *Finds, request: u32, text: []const u8, forward: bool) !?protocol.message.FindResult {
        try self.find(request, text, forward);
        return self.untilFinal(request, answer_ms);
    }
};

fn fmtResult(buf: []u8, r: ?protocol.message.FindResult) []const u8 {
    const v = r orelse return "답 없음";
    return std.fmt.bufPrint(buf, "{d}/{d}{s}", .{ v.active, v.count, if (v.final) " 끝" else "" }) catch "";
}

fn is(r: ?protocol.message.FindResult, active: u32, count: u32) bool {
    const v = r orelse return false;
    return v.final and v.active == active and v.count == count;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [320]u8 = undefined;
    var u: [256]u8 = undefined;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    var c: [32]u8 = undefined;

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 800, .height = 600, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/find") } });
    var f: Finds = .{ .host = &host };
    if (!f.untilTitle("find-ready", wait_ms)) return error.FindPageNotReady;
    // 키 포커스를 준다 — 제품에서 닫힌 오버레이의 ⌘G 는 그 탭이 키를 받는 동안이다(maru 가 `set_focus` 를 보낸다). 포커스가 없으면 멈춤의
    // 선택 남기기가 선택을 남기지 않았다(실측 — `find-keep`).
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    f.pump(500);

    const first = try f.findFinal(1, "apple", true);
    report(f.countOf(1) > 0, "find-identifier", std.fmt.bufPrint(&detail, "첫 찾기의 답 {d} 개(모두 번호 1 — 받은 답 전체 {d})", .{ f.countOf(1), f.total }) catch "");
    report(is(first, 1, 7), "find-first", std.fmt.bufPrint(&detail, "apple → {s}(1/7 끝이어야 — 대문자 APPLE 도 센다)", .{fmtResult(&a, first)}) catch "");

    const n2 = try f.findFinal(2, "apple", true);
    const n3 = try f.findFinal(3, "apple", true);
    const p2 = try f.findFinal(4, "apple", false);
    report(is(n2, 2, 7) and is(n3, 3, 7) and is(p2, 2, 7), "find-next", std.fmt.bufPrint(&detail, "다음 {s} · 다음 {s} · 이전 {s}(2·3·2 이어야)", .{ fmtResult(&a, n2), fmtResult(&b, n3), fmtResult(&c, p2) }) catch "");

    const p1 = try f.findFinal(5, "apple", false);
    const wrap_back = try f.findFinal(6, "apple", false);
    const wrap_fwd = try f.findFinal(7, "apple", true);
    report(is(p1, 1, 7) and is(wrap_back, 7, 7) and is(wrap_fwd, 1, 7), "find-wrap", std.fmt.bufPrint(&detail, "이전 {s} · 처음에서 이전 {s} · 끝에서 다음 {s}(1·7·1 이어야)", .{ fmtResult(&a, p1), fmtResult(&b, wrap_back), fmtResult(&c, wrap_fwd) }) catch "");

    const ko = try f.findFinal(8, "사과", true);
    report(is(ko, 1, 2), "find-korean", std.fmt.bufPrint(&detail, "사과 → {s}(1/2 끝이어야)", .{fmtResult(&a, ko)}) catch "");

    const none = try f.findFinal(9, "zzqqxx", true);
    report(is(none, 0, 0), "find-none", std.fmt.bufPrint(&detail, "없는 글 → {s}(0/0 끝이어야)", .{fmtResult(&a, none)}) catch "");

    // 새 찾기 둘을 잇달아 — 앞 번호의 답이 뒤 번호의 답 다음에 오면 오버레이가 옛 글의 수를 잠깐 말한다.
    const before_stale = f.got_len;
    try f.find(10, "apple", true);
    try f.find(11, "banana", true);
    const banana = f.untilFinal(11, answer_ms);
    f.pump(800);
    var seen_new = false;
    var old_after_new: u32 = 0;
    for (f.got[before_stale..f.got_len]) |r| {
        if (r.request == 11) seen_new = true;
        if (r.request == 10 and seen_new) old_after_new += 1;
    }
    report(is(banana, 1, 1) and old_after_new == 0, "find-stale", std.fmt.bufPrint(&detail, "apple(10) 곧 banana(11) → banana {s} · 11 의 답 뒤에 온 10 의 답 {d} 개(0 이어야) · 10 의 답 {d} 개", .{ fmtResult(&a, banana), old_after_new, f.countOf(10) }) catch "");

    // 멈춤: 마지막 답을 받은 뒤 멈추면 그 번호의 답은 더 오지 않는다. 멈춘 뒤 새 찾기는 다시 답한다.
    const before_stop = try f.findFinal(12, "apple", true);
    const count_before = f.countOf(12);
    try host.send(.{ .find_stop = .{ .browser = browser_id } });
    f.pump(1_500);
    const after_stop = f.countOf(12);
    const again = try f.findFinal(13, "apple", true);
    report(before_stop != null and after_stop == count_before and is(again, 1, 7), "find-stop", std.fmt.bufPrint(&detail, "멈추기 전 {s} · 멈춘 뒤 1.5 초 답 {d} → {d}(그대로여야) · 다시 찾기 {s}", .{ fmtResult(&a, before_stop), count_before, after_stop, fmtResult(&b, again) }) catch "");

    // 둘째 브라우저 — identifier 는 host 마다 센다(실측으로 정한 규칙). 전역으로 세면 둘째 탭의 첫 답이 버려진다.
    const second_id: u64 = browser_id + 1;
    try host.send(.{ .create_browser = .{ .browser = second_id, .size = .{ .width = 800, .height = 600, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/find") } });
    f.pump(3_000); // 둘째 페이지가 뜰 때까지(제목은 첫 탭의 것만 본다)
    try f.findIn(second_id, 15, "banana", true);
    const other = f.untilFinal(15, answer_ms);
    const first_again = try f.findFinal(16, "apple", true);
    const first_next = try f.findFinal(17, "apple", true);
    report(is(other, 1, 1) and is(first_again, 2, 7) and is(first_next, 3, 7), "find-two-tabs", std.fmt.bufPrint(&detail, "둘째 탭 banana {s}(1/1) · 첫 탭 이어서 {s} · {s}(2/7·3/7 — 첫 탭의 찾기는 그대로)", .{ fmtResult(&a, other), fmtResult(&b, first_again), fmtResult(&c, first_next) }) catch "");
    try host.send(.{ .destroy_browser = second_id });

    // 멈춤의 선택 남기기 — 남긴 선택에서 다음 찾기가 이어지는가로 잰다(같은 글을 다시 찾으면 남긴 일치 다음 차례, 지우면 처음부터). 둘째 탭을
    // 만들고 닫은 뒤라 포커스를 다시 준다.
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    f.pump(1_000);
    const k1 = try f.findFinal(19, "apple", true);
    try host.send(.{ .find_stop = .{ .browser = browser_id, .keep_selection = true } });
    f.pump(500);
    const k2 = try f.findFinal(20, "apple", true);
    try host.send(.{ .find_stop = .{ .browser = browser_id } });
    f.pump(500);
    const k3 = try f.findFinal(21, "apple", true);
    try host.send(.{ .find_stop = .{ .browser = browser_id } });
    f.pump(300);
    // 앞 판정의 찾기가 이어진 채라 k1 은 1 이 아닐 수 있다 — 남긴 선택의 **다음** 차례인가만 본다.
    const k_next: u32 = if (k1) |v| v.active % 7 + 1 else 0;
    report(k1 != null and is(k2, k_next, 7) and is(k3, 1, 7), "find-keep", std.fmt.bufPrint(&detail, "찾기 {s} → 선택 남김 멈춤 → 다시 {s}({d}/7 — 이어짐) → 그냥 멈춤 → 다시 {s}(1/7 — 처음부터)", .{ fmtResult(&a, k1), fmtResult(&b, k2), k_next, fmtResult(&c, k3) }) catch "");

    // 이동: 같은 번호의 답이 새 문서에서 다시 온다(sidecar 가 배운 identifier 를 그대로 받는다).
    const before_reload = try f.findFinal(18, "apple", true);
    const seen_before = f.countOf(18);
    f.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/find?again") } });
    const reloaded = f.untilTitle("find-ready", wait_ms);
    var zero_seen = false;
    const deadline = os.nowMs() + answer_ms;
    while (os.nowMs() < deadline) : (f.step()) {
        for (f.got[0..f.got_len]) |r| {
            if (r.request == 18 and r.count == 0) zero_seen = true;
        }
        if (zero_seen) if (f.lastOf(18)) |r| if (r.final and r.count == 7) break;
    }
    const after_reload = f.lastOf(18);
    report(before_reload != null and reloaded and zero_seen and f.countOf(18) > seen_before and is(after_reload, after_reload.?.active, 7), "find-reload", std.fmt.bufPrint(&detail, "이동 전 {s} · 새 문서 {} · 같은 번호의 0 답 {} · 다시 {s}(n/7 끝)", .{ fmtResult(&a, before_reload), reloaded, zero_seen, fmtResult(&b, after_reload) }) catch "");

    const failures_before = f.unknown_failures;
    try host.send(.{ .find = .{ .browser = 999, .request = 14, .text = "apple" } });
    f.pump(800);
    const find_unknown = f.unknown_failures == failures_before + 1;
    try host.send(.{ .find_stop = .{ .browser = 999 } });
    f.pump(800);
    const stop_quiet = f.unknown_failures == failures_before + 1;
    report(find_unknown and stop_quiet and f.countOf(14) == 0 and host.clean, "find-unknown", std.fmt.bufPrint(&detail, "모르는 브라우저 찾기 → unknown_browser {} · 멈춤은 조용 {} · host 메시지 모두 해석 {}", .{ find_unknown, stop_quiet, host.clean }) catch "");
}
