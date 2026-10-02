//! W6b 판정 — 페이지 툴팁(HTML `title`) 글이 maru 에 닿는가(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로
//! `tooltip_changed` 를 받는다. 띄우는 것은 maru(macOS 툴팁)라 여기서는 sidecar 의 글 규칙만 본다.
//!
//!   tooltip-enter      요소에 포인터가 들어오면 그 `title` 이 온다
//!   tooltip-once       같은 요소 안에서 다섯 번 더 움직여도 다시 오지 않는다(CEF 는 움직일 때마다 같은 글을 다시 부른다 — 실측)
//!   tooltip-multiline  여러 줄 `title` 은 LF 로 온다 — 페이지의 CRLF 도 LF 하나로(sidecar 의 글 정리가 줄바꿈을 지운 적이 있다 — W6b
//!                      착수 전 실측)
//!   tooltip-out        `title` 없는 곳으로 나가면 빈 글이 온다
//!   tooltip-leave      포인터가 view 를 떠나면 빈 글이 정확히 한 번 온다(CEF 의 빈 글과 sidecar 의 초기화가 겹치지 않는다). 렌더러가
//!                      바빠(1.5 초) CEF 의 빈 글이 늦어도 0.3 초 안에 온다 — sidecar 가 떠남을 보내며 스스로 비운다
//!   tooltip-sanitize   제어 문자는 공백으로, 5 KB 글은 4 KiB 안으로 잘려 온다 — 거절되어 옛 글이 남지 않는다(host 메시지 모두 해석)
//!   tooltip-keep-url   포인터를 멈춘 채 주소만 바뀌어도(해시·pushState) 툴팁은 그대로다(빈 글도 다시 보냄도 없다 — 같은 문서다.
//!                      비우면 자주 replaceState 하는 페이지에서 툴팁이 영영 안 뜬다)
//!   tooltip-reset-error 포인터를 멈춘 채 닿을 수 없는 주소로 옮겨 오류 페이지가 되면 빈 글이 온다(`on_load_start` 가 없다 —
//!                      옛 링크의 툴팁이 오류 페이지 위에 남지 않게)
//!   tooltip-reset-load 포인터를 멈춘 채 새 문서로 옮기면 빈 글이 오고, 다시 움직이면 같은 글이 다시 온다(실측: CEF 는 다음
//!                      움직임까지 부르지 않고, 새 문서의 같은 글은 sidecar 가 초기화하지 않으면 중복으로 걸러졌을 것이다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 22;
const wait_ms = 15_000;
const Point = protocol.message.Point;

const a_point: Point = .{ .x = 100, .y = 100 };
const b_point: Point = .{ .x = 400, .y = 100 };
const control_point: Point = .{ .x = 100, .y = 250 };
const long_point: Point = .{ .x = 400, .y = 250 };
const blank_point: Point = .{ .x = 520, .y = 360 };

/// maru 역할의 관찰 — 툴팁 알림 수와 마지막 글, 제목.
const Tips = struct {
    host: *Host,
    count: u32 = 0,
    last: [protocol.wire.max_text_bytes]u8 = undefined,
    last_len: usize = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    fn text(self: *const Tips) []const u8 {
        return self.last[0..self.last_len];
    }

    fn title(self: *const Tips) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn step(self: *Tips) void {
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .tooltip_changed => |v| if (v.browser == browser_id) {
                self.count += 1;
                self.last_len = @min(v.text.len, self.last.len);
                @memcpy(self.last[0..self.last_len], v.text[0..self.last_len]);
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            else => {},
        }
    }

    fn pump(self: *Tips, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    /// 알림이 `n` 개가 될 때까지(최대 `ms`).
    fn untilCount(self: *Tips, n: u32, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.count >= n) return true;
            self.step();
        }
        return self.count >= n;
    }

    fn untilTitle(self: *Tips, want: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.eql(u8, self.title(), want)) return true;
            self.step();
        }
        return std.mem.eql(u8, self.title(), want);
    }

    fn move(self: *Tips, point: Point) !void {
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = point } });
    }

    /// 움직여서 이 글이 마지막 알림이 될 때까지(새 알림 하나 이상).
    fn moveUntil(self: *Tips, point: Point, want: []const u8, ms: u32) !bool {
        const before = self.count;
        try self.move(point);
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (self.count > before and std.mem.eql(u8, self.text(), want)) return true;
            self.step();
        }
        return self.count > before and std.mem.eql(u8, self.text(), want);
    }
};

fn noControl(text: []const u8) bool {
    for (text) |byte| {
        if (byte == '\n' or byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn allByte(text: []const u8, byte: u8) bool {
    for (text) |b| if (b != byte) return false;
    return true;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [320]u8 = undefined;
    var u: [256]u8 = undefined;

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 2 }, .hidden = false, .url = browsers_check.url(&u, port, "/tip") } });
    var t: Tips = .{ .host = &host };
    if (!t.untilTitle("tip-ready", wait_ms)) return error.TipPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    // 새로 뜬 브라우저는 첫 입력을 잃을 수 있다(W7b 7~9 차) — 첫 글이 올 때까지 몇 번 들어간다.
    var entered = false;
    var attempt: u8 = 0;
    while (!entered and attempt < 4) : (attempt += 1) {
        try t.move(blank_point);
        t.pump(200);
        entered = try t.moveUntil(a_point, "A tip", 2_000);
    }
    report(entered, "tooltip-enter", std.fmt.bufPrint(&detail, "{d} 번째 들어감에 「{s}」(알림 {d})", .{ attempt, t.text(), t.count }) catch "");

    const before_once = t.count;
    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        try t.move(.{ .x = a_point.x + 8 * (i + 1), .y = a_point.y + 3 * i });
        t.pump(60);
    }
    t.pump(600);
    report(entered and t.count == before_once, "tooltip-once", std.fmt.bufPrint(&detail, "같은 요소 안 다섯 번 더 움직임 — 알림 {d} → {d}(그대로여야)", .{ before_once, t.count }) catch "");

    const multi = try t.moveUntil(b_point, "B line1\nB line2", 2_000);
    report(multi, "tooltip-multiline", std.fmt.bufPrint(&detail, "글 {d} 바이트 · LF {d} 개 · 「{s}」", .{ t.text().len, std.mem.count(u8, t.text(), "\n"), t.text() }) catch "");

    const out = try t.moveUntil(blank_point, "", 2_000);
    report(out, "tooltip-out", std.fmt.bufPrint(&detail, "title 없는 곳 → 빈 글 {}(알림 {d})", .{ out, t.count }) catch "");

    const back_in = try t.moveUntil(a_point, "A tip", 2_000);
    // 렌더러를 1.5 초 붙잡는다(해시 이동 — 같은 문서라 툴팁은 그대로다). 그동안 CEF 는 떠남의 빈 글을 부르지 못한다.
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/tip#busy") } });
    const busy = t.untilTitle("busy", 2_000); // 반복문 바로 앞에서 바꾼 제목 — 렌더러가 이제 붙잡혔다
    const before_leave = t.count;
    const leave_at = os.nowMs();
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .leave, .point = a_point } });
    const prompt = t.untilCount(before_leave + 1, 300) and t.text().len == 0;
    const prompt_ms = os.nowMs() - leave_at;
    t.pump(2_000); // 바쁜 렌더러가 풀린 뒤 CEF 의 빈 글이 와도 다시 보내지 않는다
    const left = back_in and busy and prompt and t.count == before_leave + 1;
    report(left, "tooltip-leave", std.fmt.bufPrint(&detail, "다시 들어감 {} · 렌더러 붙잡힘 {} · 바쁜 채 떠남 → 빈 글 {}({d} ms 안) · 2 초 뒤까지 알림 {d} → {d}(하나여야)", .{ back_in, busy, prompt, prompt_ms, before_leave, t.count }) catch "");

    const control_ok = try t.moveUntil(control_point, "ctl char", 2_000);
    const control_clean = noControl(t.text());
    const before_long = t.count;
    try t.move(long_point);
    _ = t.untilCount(before_long + 1, 2_000);
    const long_len = t.text().len;
    const long_ok = t.count > before_long and long_len > 4000 and long_len <= protocol.wire.max_text_bytes and allByte(t.text(), 'L');
    report(control_ok and control_clean and long_ok and host.clean, "tooltip-sanitize", std.fmt.bufPrint(&detail, "제어 문자 → 「ctl char」 {} · 5000 자 → {d} 바이트(4096 이하·L 만 {}) · host 메시지 모두 해석 {}", .{ control_ok and control_clean, long_len, long_ok, host.clean }) catch "");

    // 주소만 바뀐다(해시 이동 — 페이지가 이어서 pushState 도 한다). 포인터는 A 위에 멈춰 있다.
    const keep_in = try t.moveUntil(a_point, "A tip", 2_000);
    const before_url = t.count;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/tip#push") } });
    t.pump(1_200);
    try t.move(.{ .x = a_point.x + 5, .y = a_point.y });
    t.pump(800);
    const kept = keep_in and t.count == before_url and std.mem.eql(u8, t.text(), "A tip");
    report(kept, "tooltip-keep-url", std.fmt.bufPrint(&detail, "주소만 바뀜(해시·pushState)·그 뒤 움직임 — 알림 {d} → {d}(그대로여야) · 마지막 글 「{s}」", .{ before_url, t.count, t.text() }) catch "");

    // 닿을 수 없는 주소(오류 페이지). 포인터는 A 위에 멈춰 있다.
    const err_in = try t.moveUntil(.{ .x = a_point.x + 1, .y = a_point.y }, "A tip", 2_000) or std.mem.eql(u8, t.text(), "A tip");
    const before_error = t.count;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = "http://127.0.0.1:1/" } });
    const error_cleared = t.untilCount(before_error + 1, 5_000) and t.text().len == 0;
    report(err_in and error_cleared, "tooltip-reset-error", std.fmt.bufPrint(&detail, "A 위 「A tip」 {} · 오류 페이지 → 빈 글 {}(알림 {d} → {d})", .{ err_in, error_cleared, before_error, t.count }) catch "");
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/tip") } });
    t.title_len = 0;
    _ = t.untilTitle("tip-ready", wait_ms);
    _ = try t.moveUntil(a_point, "A tip", 3_000);

    // 새 문서(같은 배치). 포인터는 A 위에 멈춰 있다.
    const before_load = t.count;
    t.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/tip2") } });
    const load_cleared = t.untilCount(before_load + 1, 3_000) and t.text().len == 0;
    _ = t.untilTitle("tip-ready", wait_ms);
    var load_again = false;
    attempt = 0;
    while (!load_again and attempt < 3) : (attempt += 1) {
        load_again = try t.moveUntil(.{ .x = a_point.x + 2 * @as(i32, attempt + 1), .y = a_point.y }, "A tip", 2_000);
    }
    report(load_cleared and load_again, "tooltip-reset-load", std.fmt.bufPrint(&detail, "새 문서 → 빈 글 {} · 다시 움직이면 「A tip」 {}", .{ load_cleared, load_again }) catch "");
}
