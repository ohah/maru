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
//!   dl-pick-stale       옛 목록 번호·범위 밖 번호의 고르기는 아무것도 바꾸지 않는다(지금 목록은 여섯 — 받아들여지면 다른 값이
//!                       보인다), 범위 밖을 거절한 대리 스크립트는 목록을 닫는다
//!   dl-blur             목록이 붙지 않은 칸을 누르면 닫고, 그때 페이지가 보낸 가짜 `input` 은 목록을 열지 않는다
//!   dl-types            `type=search` 칸도 연다, `type=date` 에 붙은 목록·readonly 칸은 열지 않는다
//!   dl-scroll           칸과 상관없는 상자의 스크롤은 목록을 두고, 문서 스크롤은 닫는다
//!   dl-navigation       목록이 떠 있는 채 페이지를 옮기면 닫힌다(옛 문서의 pagehide 와 sidecar 의 `on_load_start` 둘 다 닫는다)
//!   dl-cap              옵션 300 개는 앞 256 개까지
//!   dl-long             레이블 600 자 옵션 256 개도 뜬다 — 보이는 레이블은 512 에서 자르고 모은 글 한도에서 앞쪽만
//!   dl-iframe           같은 출처 http iframe 안의 칸은 아직 열지 않는다(W6m③), 같은 페이지 주 프레임 칸은 연다
//!   dl-renderer-gone    목록이 떠 있는 채 렌더러가 죽으면 sidecar 가 닫는다(죽은 문서는 닫기를 보내지 못한다)
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
                if (std.mem.startsWith(u8, t.text, input_title)) seen.input = true;
                if (std.mem.startsWith(u8, t.text, change_title)) seen.change = true;
            },
            .datalist_hide => |h| if (h.browser == id) {
                seen.hidden = true;
            },
            else => {},
        }
    }
    return seen;
}

fn waitTitlePrefix(host: *Host, prefix: []const u8, ms: u32) bool {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        if (message == .title_changed and message.title_changed.browser == id and std.mem.startsWith(u8, message.title_changed.text, prefix)) return true;
    }
    return false;
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
    // 지금 목록에 항목이 여럿이게(`a` — 여섯) 한 뒤 보낸다: 옛 번호가 받아들여지면 지금 목록의 0 번(apple)이, 범위 밖이 받아들여지면
    // 엉뚱한 값이 들어가 `change` 가 보인다(목록이 하나뿐이면 같은 값이 들어가 가려지지 않았다).
    try clear(&host, 6);
    try typeChar(&host, 0, 'a');
    const again = watch(&host, 3000, 300);
    var stale: PickSeen = .{};
    if (again.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = down.list, .index = 0 } }); // 옛 목록(sidecar 가 거른다)
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = again.list, .index = again.count } }); // 범위 밖(대리 스크립트가 거절하고 닫는다)
        stale = watchPick(&host, "change:a:", "change:a:", 1500);
    }
    report(again.kind == .show and again.count == 6 and !stale.change and stale.hidden, "dl-pick-stale", std.fmt.bufPrint(&detail_buf, "다시 열림 {s}({d}) · change {} · 닫힘 {}", .{ @tagName(again.kind), again.count, stale.change, stale.hidden }) catch "");
    try click(&host, 100, 20); // 다시 연다(값 a — 여섯)
    _ = watch(&host, 3000, 300);

    // ── 초점이 옮겨 가면 닫힘 ──
    try click(&host, 100, 120); // b — 페이지가 a 에 가짜 input 을 보낸다
    const blurred = watch(&host, 3000, 600);
    report(blurred.kind == .hide and blurred.messages == 1, "dl-blur", std.fmt.bufPrint(&detail_buf, "{s} · 알림 {d}(닫힘 하나 — 가짜 input 이 열면 둘)", .{ @tagName(blurred.kind), blurred.messages }) catch "");

    // ── 칸 종류 ──
    try click(&host, 100, 220); // type=search
    const search = watch(&host, 3000, 300);
    try click(&host, 100, 320); // type=date(목록이 붙었지만 이 길이 아니다) — search 의 목록은 닫힌다
    const date = watch(&host, 1500, 300);
    try click(&host, 420, 20); // readonly
    const readonly = watch(&host, 1500, 300);
    report(search.kind == .show and search.count == 7 and search.field.y == 200 and date.kind == .hide and readonly.kind == .none, "dl-types", std.fmt.bufPrint(&detail_buf, "search {s}({d}, y {d}) · date {s} · readonly {s}", .{ @tagName(search.kind), search.count, search.field.y, @tagName(date.kind), @tagName(readonly.kind) }) catch "");

    // ── 스크롤 ──
    try click(&host, 100, 20);
    const before_scroll = watch(&host, 3000, 300);
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 450, .y = 140 }, .delta_x = 0, .delta_y = -120 } }); // 상자 f 안
    const box_scroll = watch(&host, 1200, 300);
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 450, .y = 350 }, .delta_x = 0, .delta_y = -120 } }); // 문서
    const doc_scroll = watch(&host, 2000, 300);
    report(before_scroll.kind == .show and box_scroll.kind == .none and doc_scroll.kind == .hide, "dl-scroll", std.fmt.bufPrint(&detail_buf, "열림 {s} · 상자 스크롤 뒤 {s}(none 이어야) · 문서 스크롤 뒤 {s}", .{ @tagName(before_scroll.kind), @tagName(box_scroll.kind), @tagName(doc_scroll.kind) }) catch "");

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

    // ── 긴 레이블 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-long") } });
    _ = waitTitle(&host, "dl-long-ready", 10_000);
    os.sleepMs(800);
    try click(&host, 100, 20);
    const long = watch(&host, 4000, 300);
    var label_len: usize = 0;
    var first_value_ok = false;
    if (long.kind == .show) {
        var it: protocol.fields.DatalistItems = .{ .bytes = long.items() };
        if (it.next() catch null) |item| {
            label_len = item.label.len;
            first_value_ok = std.mem.eql(u8, item.value, "v0");
        }
    }
    report(long.kind == .show and long.count > 10 and long.count < 256 and label_len == 512 and first_value_ok, "dl-long", std.fmt.bufPrint(&detail_buf, "{s} · 개수 {d} · 첫 레이블 {d} 바이트 · 첫 값 v0 {}", .{ @tagName(long.kind), long.count, label_len, first_value_ok }) catch "");

    // ── iframe 은 아직 — 같은 페이지 주 프레임 칸은 연다 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-frame") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    os.sleepMs(800);
    try click(&host, 100, 20); // iframe 안 칸
    const framed = watch(&host, 2000, 300);
    try click(&host, 100, 220); // 주 프레임 칸
    const main_field = watch(&host, 3000, 300);
    report(framed.kind == .none and main_field.kind == .show and main_field.count == 2, "dl-iframe", std.fmt.bufPrint(&detail_buf, "iframe {s} · 주 프레임 {s}({d})", .{ @tagName(framed.kind), @tagName(main_field.kind), main_field.count }) catch "");

    // ── 렌더러가 죽으면 sidecar 가 닫는다(마지막 — 브라우저가 죽는다) ──
    var kids_buf: [64]c_int = undefined;
    var killed: u32 = 0;
    if (main_field.kind == .show) {
        for (os.children(host.pid, &kids_buf)) |kid| {
            if (os.argsContain(kid, "--type=renderer")) {
                _ = std.c.kill(kid, std.c.SIG.KILL);
                killed += 1;
            }
        }
    }
    const gone = watch(&host, 4000, 300);
    report(killed >= 1 and gone.kind == .hide, "dl-renderer-gone", std.fmt.bufPrint(&detail_buf, "죽인 렌더러 {d} · 닫힘 {s}", .{ killed, @tagName(gone.kind) }) catch "");
}
