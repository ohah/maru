//! 제안 목록 판정(W6m① — datalist). CEF Alloy 에는 Chromium 의 datalist 팝업이 없어 sidecar 의 대리 스크립트가 칸의 자리와 거른
//! 항목을 `datalist_show` 로 보내고, maru 가 고른 번호(`datalist_pick`)를 칸에 넣는다. 규칙은 Chrome 154 실측(§7).
//!
//!   dl-click-all        초점 없던 칸을 누르면 `disabled` 를 뺀 전부가 원래 순서로 — 값과 레이블(label 속성, 없으면 옵션 글,
//!                       값과 같으면 빈 레이블), 칸 사각형은 view DIP
//!   dl-filter           글자를 치면 값·레이블에서 대소문자를 무시한 부분 일치로 다시 거른다(`pi` → Apple pie·pineapple,
//!                       `ow` → 레이블 yellow fruit 의 banana)
//!   dl-closes           지워서 빈 칸이 되거나 일치가 없으면 닫는다
//!   dl-arrowdown        빈 칸에서 ↓ 는 전부를 연다
//!   dl-pick             고른 번호의 값이 칸에 들어가고 페이지가 `input`·`change` 를 받고, 목록은 닫힌다
//!   dl-pick-stale       옛 목록 번호·범위 밖 번호의 고르기는 아무것도 바꾸지 않는다
//!   dl-blur             목록이 붙지 않은 칸으로 초점이 옮겨 가면 닫는다
//!   dl-types            `type=email` 칸도 연다, `type=date` 에 붙은 목록은 열지 않는다(Chrome 은 선택 창 쪽 — 이 길이 아니다)
//!   dl-navigation       목록이 떠 있는 채 페이지를 옮기면 닫힌다(옛 문서는 닫기를 보내지 못한다 — sidecar 가 닫는다)
//!   dl-cap              옵션 300 개는 앞 256 개까지
//!   dl-iframe           iframe 안의 칸은 아직 열지 않는다(W6m③)
const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const BrowserId = protocol.message.BrowserId;
const Key = protocol.message.Key;

pub const Report = browsers_check.Report;
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
const id: BrowserId = 61;

/// 받은 목록 하나(덩어리를 복사해 둔다 — decoder 가 준 slice 는 다음 메시지까지만 산다).
const Seen = struct {
    kind: enum { none, show, hide } = .none,
    list: u32 = 0,
    field: protocol.message.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    count: u16 = 0,
    buf: [protocol.message.max_datalist_bytes]u8 = undefined,
    len: usize = 0,
    messages: u32 = 0,

    fn items(self: *const Seen) []const u8 {
        return self.buf[0..self.len];
    }

    /// 「값|레이블,값|레이블…」 — 판정 글에 그대로 보인다.
    fn describe(self: *const Seen, out: []u8) []const u8 {
        if (self.kind != .show) return if (self.kind == .hide) "hide" else "none";
        var w: std.Io.Writer = .fixed(out);
        var it: protocol.fields.DatalistItems = .{ .bytes = self.items() };
        var first = true;
        while (it.next() catch null) |item| {
            w.print("{s}{s}{s}{s}", .{ if (first) "" else ",", item.value, if (item.label.len > 0) "|" else "", item.label }) catch break;
            first = false;
        }
        return w.buffered();
    }
};

/// 처음 온 목록 알림을 기다리고, 그 뒤 `settle_ms` 동안 더 오면 마지막 것을 둔다(글자마다 다시 온다).
fn watch(host: *Host, ms: u32, settle_ms: u32) Seen {
    var seen: Seen = .{};
    var deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return seen) orelse return seen;
        switch (message) {
            .datalist_show => |s| if (s.browser == id) {
                seen.kind = .show;
                seen.list = s.list;
                seen.field = s.field;
                seen.count = s.count;
                @memcpy(seen.buf[0..s.items.len], s.items);
                seen.len = s.items.len;
                seen.messages += 1;
                deadline = @min(deadline, os.nowMs() + settle_ms);
            },
            .datalist_hide => |h| if (h.browser == id) {
                seen.kind = .hide;
                seen.list = h.list;
                seen.messages += 1;
                deadline = @min(deadline, os.nowMs() + settle_ms);
            },
            else => {},
        }
    }
    return seen;
}

/// 제목이 `text` 가 될 때까지(다른 제목은 건너뛴다).
fn waitTitle(host: *Host, text: []const u8, ms: u32) bool {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        if (message == .title_changed and message.title_changed.browser == id and std.mem.eql(u8, message.title_changed.text, text)) return true;
    }
    return false;
}

/// 고른 뒤 — 제목(`input`·`change`)과 목록 닫힘을 함께 본다(닫힘이 제목보다 먼저 올 수 있다).
const PickSeen = struct { input: bool = false, change: bool = false, hidden: bool = false };

fn watchPick(host: *Host, input_title: []const u8, change_title: []const u8, ms: u32) PickSeen {
    var seen: PickSeen = .{};
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline and !(seen.input and seen.change and seen.hidden)) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return seen) orelse return seen;
        switch (message) {
            .title_changed => |t| if (t.browser == id) {
                if (std.mem.eql(u8, t.text, input_title)) seen.input = true;
                if (std.mem.eql(u8, t.text, change_title)) seen.change = true;
            },
            .datalist_hide => |h| if (h.browser == id) {
                seen.hidden = true;
            },
            else => {},
        }
    }
    return seen;
}

/// 그 자리로 옮긴 뒤 누른다(이동 없는 합성 클릭은 Chromium 이 다르게 다룬다 — §7 날짜 실측).
fn click(host: *Host, x: i32, y: i32) !void {
    const point: protocol.message.Point = .{ .x = x, .y = y };
    try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = point } });
    os.sleepMs(60);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .point = point, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .point = point, .click_count = 1 } });
}

fn typeChar(host: *Host, native: u8, ch: u16) !void {
    const k: Key = .{ .browser = id, .kind = .raw_down, .native_key_code = native, .character = ch, .unmodified_character = ch };
    try host.send(.{ .key = k });
    var c = k;
    c.kind = .char;
    try host.send(.{ .key = c });
    var up = k;
    up.kind = .up;
    try host.send(.{ .key = up });
    os.sleepMs(120);
}

fn rawKey(host: *Host, windows: u8, native: u8, ch: u16) !void {
    const k: Key = .{ .browser = id, .kind = .raw_down, .windows_key_code = windows, .native_key_code = native, .character = ch, .unmodified_character = ch };
    try host.send(.{ .key = k });
    var up = k;
    up.kind = .up;
    try host.send(.{ .key = up });
    os.sleepMs(120);
}

fn backspace(host: *Host, n: usize) !void {
    for (0..n) |_| try rawKey(host, 0x08, 51, 0x7f);
}

/// 지금 열린 칸을 비운다(목록이 닫히는 것은 여기서 보지 않는다).
fn clear(host: *Host, n: usize) !void {
    try backspace(host, n);
    _ = watch(host, 600, 200);
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail_buf: [640]u8 = undefined;
    var a_buf: [512]u8 = undefined;
    var b_buf: [512]u8 = undefined;
    var u: [256]u8 = undefined;
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        os.sleepMs(500);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(&u, port, "/datalist") } });
    if (!waitTitle(&host, "dl-ready", 15_000)) return error.PageNotReady;
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });
    os.sleepMs(800); // 첫 프레임 뒤 약 0.5 초의 입력은 렌더러가 버린다(W4a)

    // ── 누르면 전부 ──
    try click(&host, 100, 20);
    const all = watch(&host, 4000, 300);
    const want_all = "apple,Apple pie,pineapple,banana|yellow fruit,APRICOT,cherry|Cherry text,grape|purple";
    const all_text = all.describe(&a_buf);
    report(all.kind == .show and std.mem.eql(u8, all_text, want_all) and all.count == 7 and
        all.field.x == 0 and all.field.y == 0 and all.field.width == 300 and all.field.height == 40, "dl-click-all", std.fmt.bufPrint(&detail_buf, "{s} · 개수 {d} · 칸 {d},{d} {d}x{d}", .{ all_text, all.count, all.field.x, all.field.y, all.field.width, all.field.height }) catch "");

    // ── 거르기 ──
    try typeChar(&host, 35, 'p');
    try typeChar(&host, 34, 'i');
    const pi = watch(&host, 3000, 400);
    const pi_text = pi.describe(&a_buf);
    try clear(&host, 2);
    try typeChar(&host, 31, 'o');
    try typeChar(&host, 13, 'w');
    const ow = watch(&host, 3000, 400);
    const ow_text = ow.describe(&b_buf);
    report(pi.kind == .show and std.mem.eql(u8, pi_text, "Apple pie,pineapple") and ow.kind == .show and std.mem.eql(u8, ow_text, "banana|yellow fruit"), "dl-filter", std.fmt.bufPrint(&detail_buf, "pi → {s} · ow → {s}", .{ pi_text, ow_text }) catch "");

    // ── 일치 없음·빈 칸이면 닫힘 ──
    try typeChar(&host, 12, 'q');
    const none = watch(&host, 3000, 300);
    try clear(&host, 3);
    try typeChar(&host, 35, 'p');
    const reopened = watch(&host, 3000, 300);
    try backspace(&host, 1);
    const emptied = watch(&host, 3000, 300);
    report(none.kind == .hide and reopened.kind == .show and emptied.kind == .hide, "dl-closes", std.fmt.bufPrint(&detail_buf, "owq → {s} · p → {s} · 빈 칸 → {s}", .{ @tagName(none.kind), @tagName(reopened.kind), @tagName(emptied.kind) }) catch "");

    // ── ↓ 는 전부를 연다 ──
    try rawKey(&host, 0x28, 125, 0xF701);
    const down = watch(&host, 3000, 300);
    const down_text = down.describe(&a_buf);
    report(down.kind == .show and std.mem.eql(u8, down_text, want_all), "dl-arrowdown", down_text);

    // ── 고르기 ──
    // 빈 값 옵션(pineapple 과 banana 사이)은 스크립트와 sidecar 가 함께 건너뛴다 — 3 번이 banana 여야 한다.
    var after: PickSeen = .{};
    if (down.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = down.list, .index = 3 } });
        after = watchPick(&host, "input:a:banana", "change:a:banana", 4000);
    }
    report(after.input and after.change and after.hidden, "dl-pick", std.fmt.bufPrint(&detail_buf, "input {} · change {} · 닫힘 {}", .{ after.input, after.change, after.hidden }) catch "");

    // ── 옛 번호·범위 밖 ──
    try click(&host, 100, 20);
    const again = watch(&host, 3000, 300); // 값이 banana — 걸러진 하나
    var stale_changed = false;
    if (again.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = down.list, .index = 0 } }); // 옛 목록
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = again.list, .index = 5 } }); // 범위 밖
        stale_changed = waitTitle(&host, "change:a:apple", 1500) or waitTitle(&host, "change:a:cherry", 500);
    }
    report(again.kind == .show and again.count == 1 and !stale_changed, "dl-pick-stale", std.fmt.bufPrint(&detail_buf, "다시 열림 {s}({d}) · 바뀜 {}", .{ @tagName(again.kind), again.count, stale_changed }) catch "");

    // ── 초점이 옮겨 가면 닫힘 ──
    try click(&host, 100, 120);
    const blurred = watch(&host, 3000, 300);
    report(blurred.kind == .hide, "dl-blur", @tagName(blurred.kind));

    // ── 칸 종류 ──
    try click(&host, 100, 220); // type=email
    const email = watch(&host, 3000, 300);
    try click(&host, 100, 320); // type=date(목록이 붙었지만 이 길이 아니다)
    const date = watch(&host, 1500, 300);
    report(email.kind == .show and email.count == 7 and email.field.y == 200 and date.kind != .show, "dl-types", std.fmt.bufPrint(&detail_buf, "email {s}({d}, y {d}) · date {s}", .{ @tagName(email.kind), email.count, email.field.y, @tagName(date.kind) }) catch "");

    // ── 이동하면 닫힘 ──
    try click(&host, 100, 20);
    const before_nav = watch(&host, 3000, 300);
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-many") } });
    const after_nav = watch(&host, 5000, 200);
    report(before_nav.kind == .show and after_nav.kind == .hide, "dl-navigation", std.fmt.bufPrint(&detail_buf, "이동 전 {s} · 이동 뒤 {s}", .{ @tagName(before_nav.kind), @tagName(after_nav.kind) }) catch "");

    // ── 상한 ──
    _ = waitTitle(&host, "dl-many-ready", 10_000);
    os.sleepMs(800);
    try click(&host, 100, 20);
    const many = watch(&host, 4000, 300);
    report(many.kind == .show and many.count == protocol.message.max_datalist_items, "dl-cap", std.fmt.bufPrint(&detail_buf, "옵션 300 → {d}", .{many.count}) catch "");

    // ── iframe 은 아직 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-frame") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    os.sleepMs(800);
    try click(&host, 100, 20);
    const framed = watch(&host, 2000, 300);
    report(framed.kind == .none, "dl-iframe", @tagName(framed.kind));
}
