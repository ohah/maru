//! 제안 목록 판정(W6m① — datalist). CEF Alloy 에는 Chromium 의 datalist 팝업이 없어 sidecar 의 대리 스크립트가 칸의 자리와 거른
//! 항목을 `datalist_show` 로 보내고, maru 가 고른 번호(`datalist_pick`)를 칸에 넣는다. 규칙은 Chrome 154 실측(§7).
//!
//!   dl-click-all        초점 없던 칸을 누르면 `disabled` 를 뺀 전부가 원래 순서로 — 값과 레이블(label 속성, 없으면 옵션 글,
//!                       값과 같으면 빈 레이블), 칸 사각형은 view DIP
//!   dl-filter           글자를 치면 빈칸으로 나눈 단어마다 값·레이블에서 대소문자를 무시한 부분 일치로 다시 거른다(`pi` →
//!                       Apple pie·pineapple, `ow` → 레이블 yellow fruit 의 banana, `ban yel` → 값과 레이블에 나뉜 banana, 빈칸만 → 전부)
//!   dl-closes           지워서 빈 칸이 되거나 일치가 없으면 닫는다
//!   dl-arrowdown        빈 칸에서 ↓ 는 전부를 연다
//!   dl-pick             고른 번호의 값이 칸에 들어가고 페이지가 `input`·`change` 를 받고, 목록은 닫힌다
//!   dl-pick-stale       옛 목록 번호·범위 밖 번호의 고르기는 아무것도 바꾸지 않는다(지금 목록은 여섯 — 받아들여지면 다른 값이
//!                       보인다), 범위 밖을 거절한 대리 스크립트는 목록을 닫는다
//!   dl-blur             목록이 붙지 않은 칸을 누르면 닫고, 그때 페이지가 보낸 가짜 `input` 은 목록을 열지 않는다; Tab 으로
//!                       초점이 옮겨 가도 닫는다(누르기 없이 — `focusout`)
//!   dl-types            `type=search` 칸도 연다, `type=date` 에 붙은 목록·readonly 칸은 열지 않는다(열린 목록을 닫기만 한다)
//!   dl-scroll           칸과 상관없는 상자의 스크롤은 목록을 두고(상자가 스크롤된 것은 페이지가 알린다), 문서 스크롤은 닫는다,
//!                       좁은 칸에 긴 값을 쳐 칸 자신이 가로로 스크롤돼도 목록은 남는다
//!   dl-navigation       목록이 떠 있는 채 페이지를 옮기면 닫힌다(옛 문서의 pagehide 와 sidecar 의 `on_load_start` 둘 다 닫는다)
//!   dl-cap              옵션 300 개는 앞 256 개까지
//!   dl-long             레이블 600 자 옵션 256 개도 뜬다 — 보이는 레이블은 512 에서 자르고 모은 글 한도에서 앞 45 개(자르지
//!                       않으면 39 개)
//!   dl-shadow-open      열린 shadow DOM 안의 칸을 누르면 연다(칸 사각형은 host 자리), 글자는 거른다(초점은 shadow 를 따라 본다)
//!   dl-shadow-pick      고르면 값이 들어가고 host 의 수신자가 `input`(composed)을, 안쪽 칸이 `change` 를 받고 닫힌다
//!   dl-shadow-blur      Tab 으로 shadow 밖으로 나가면 닫는다(`focusout` 은 window 에서 host 로 보인다 — 진짜 대상으로 본다)
//!   dl-shadow-scroll    shadow 안 스크롤 상자가 칸을 품고 스크롤하면 닫는다(스크롤은 composed 가 아니다 — root 에 단 수신자)
//!   dl-shadow-none      shadow 안 칸의 목록이 바깥(light DOM)에 있으면 열지 않는다(Chrome 과 같다), 선언형 닫힌 shadow 는 하지 않는다
//!   dl-iframe-keys      포인터가 한 번도 오지 않은 iframe 의 칸은 Tab·글자로 들어가도 열지 않는다(원점을 모른다), 그 위로 포인터가
//!                       지나간 뒤의 ↓ 는 연다 — 칸 사각형은 iframe 내용 상자 원점(60,160)만큼 옮겨진다
//!   dl-iframe           같은 출처 iframe 안의 칸을 누르면 연다(사각형 60,160 300x40), 고르면 그 프레임 칸에 들어간다; 주 프레임 칸도 연다
//!   dl-iframe-scroll    최상위 문서가 스크롤하면 iframe 목록은 닫히고, 그 뒤 포인터 없이 ↓ 는 열지 않으며(원점이 낡았다), 포인터가
//!                       지나간 뒤에는 새 자리(위로 옮겨짐)로 연다
//!   dl-xframe           다른 출처 iframe(localhost — OOPIF) 안의 칸도 같은 자리로 열고 고르면 그 칸에 들어간다
//!   dl-iframe-removed   목록이 떠 있는 iframe 을 페이지가 떼어 내면 닫힌다
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
    /// 페이지가 제목으로 알린 마지막 문서 스크롤(`sy:N` — W6m③ iframe 판정), 없으면 -1.
    sy: i32 = -1,

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
            .title_changed => |t| if (t.browser == id and std.mem.startsWith(u8, t.text, "sy:")) {
                seen.sy = std.fmt.parseInt(i32, t.text[3..], 10) catch -1;
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
    // 여러 단어 — 단어마다 값이나 레이블에(`ban yel` → 값 banana·레이블 yellow fruit), 빈칸만이면 전부.
    try clear(&host, 2);
    for ("ban yel") |ch| try typeChar(&host, if (ch == ' ') 49 else 0, ch);
    const by = watch(&host, 3000, 400);
    var by_buf: [512]u8 = undefined;
    const by_text = by.describe(&by_buf);
    try clear(&host, 7);
    try typeChar(&host, 49, ' ');
    const blank = watch(&host, 3000, 400);
    report(pi.kind == .show and std.mem.eql(u8, pi_text, "Apple pie,pineapple") and ow.kind == .show and std.mem.eql(u8, ow_text, "banana|yellow fruit") and
        by.kind == .show and std.mem.eql(u8, by_text, "banana|yellow fruit") and blank.kind == .show and blank.count == 7, "dl-filter", std.fmt.bufPrint(&detail_buf, "pi → {s} · ow → {s} · ban yel → {s} · 빈칸 → {s}({d})", .{ pi_text, ow_text, by_text, @tagName(blank.kind), blank.count }) catch "");
    try clear(&host, 1);

    // ── 일치 없음·빈 칸이면 닫힘 ──
    try typeChar(&host, 31, 'o'); // 연다(banana·APRICOT)
    _ = watch(&host, 3000, 300);
    try typeChar(&host, 12, 'q');
    const none = watch(&host, 3000, 300);
    try clear(&host, 3);
    try typeChar(&host, 35, 'p');
    const reopened = watch(&host, 3000, 300);
    try backspace(&host, 1);
    const emptied = watch(&host, 3000, 300);
    report(none.kind == .hide and reopened.kind == .show and emptied.kind == .hide, "dl-closes", std.fmt.bufPrint(&detail_buf, "oq → {s} · p → {s} · 빈 칸 → {s}", .{ @tagName(none.kind), @tagName(reopened.kind), @tagName(emptied.kind) }) catch "");

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
    // Tab — 누르기 없이 초점만 옮긴다(`focusout` 이 닫는다).
    try click(&host, 100, 20);
    const before_tab = watch(&host, 3000, 300);
    try rawKey(&host, 0x09, 48, 9);
    const tabbed = watch(&host, 2000, 300);
    report(blurred.kind == .hide and blurred.messages == 1 and before_tab.kind == .show and tabbed.kind == .hide, "dl-blur", std.fmt.bufPrint(&detail_buf, "누르기 {s} · 알림 {d}(닫힘 하나 — 가짜 input 이 열면 둘) · Tab 전 {s} · Tab 뒤 {s}", .{ @tagName(blurred.kind), blurred.messages, @tagName(before_tab.kind), @tagName(tabbed.kind) }) catch "");

    // ── 칸 종류 ──
    try click(&host, 100, 220); // type=search
    const search = watch(&host, 3000, 300);
    try click(&host, 100, 320); // type=date(목록이 붙었지만 이 길이 아니다) — search 의 목록은 닫힌다
    const date = watch(&host, 1500, 300);
    try click(&host, 100, 20); // a 를 열어 두고
    _ = watch(&host, 3000, 300);
    try click(&host, 420, 20); // readonly — 열린 목록을 닫기만 한다(열면 마지막이 show)
    const readonly = watch(&host, 1500, 300);
    report(search.kind == .show and search.count == 7 and search.field.y == 200 and date.kind == .hide and readonly.kind == .hide, "dl-types", std.fmt.bufPrint(&detail_buf, "search {s}({d}, y {d}) · date {s} · readonly {s}", .{ @tagName(search.kind), search.count, search.field.y, @tagName(date.kind), @tagName(readonly.kind) }) catch "");

    // ── 스크롤 ──
    try click(&host, 100, 20);
    const before_scroll = watch(&host, 3000, 300);
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 450, .y = 140 }, .delta_x = 0, .delta_y = -120 } }); // 상자 f 안
    const box_scrolled = waitTitle(&host, "f-scrolled", 1500);
    const box_scroll = watch(&host, 800, 300);
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 450, .y = 350 }, .delta_x = 0, .delta_y = -120 } }); // 문서
    const doc_scroll = watch(&host, 2000, 300);
    // 좁은 칸 g(60 px)에 긴 값을 친다 — 칸이 가로로 스크롤돼도 목록은 남는다.
    try click(&host, 350, 220);
    _ = watch(&host, 1500, 300);
    for (0..12) |_| try typeChar(&host, 0, 'a');
    const self_scrolled = waitTitle(&host, "g-scrolled", 1500);
    const long_typed = watch(&host, 1500, 400);
    report(before_scroll.kind == .show and box_scrolled and box_scroll.kind == .none and doc_scroll.kind == .hide and self_scrolled and long_typed.kind == .show, "dl-scroll", std.fmt.bufPrint(&detail_buf, "열림 {s} · 상자 스크롤됨 {} 뒤 {s}(none 이어야) · 문서 스크롤 뒤 {s} · 좁은 칸 스크롤됨 {} 뒤 {s}(show 여야)", .{ @tagName(before_scroll.kind), box_scrolled, @tagName(box_scroll.kind), @tagName(doc_scroll.kind), self_scrolled, @tagName(long_typed.kind) }) catch "");

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
    report(long.kind == .show and long.count == 45 and label_len == 512 and first_value_ok, "dl-long", std.fmt.bufPrint(&detail_buf, "{s} · 개수 {d} · 첫 레이블 {d} 바이트 · 첫 값 v0 {}", .{ @tagName(long.kind), long.count, label_len, first_value_ok }) catch "");

    // ── W6m③: 열린 shadow DOM ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-shadow") } });
    _ = waitTitle(&host, "dl-shadow-ready", 10_000);
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } }); // 이동 뒤 페이지가 초점을 잃는다(초점 없는 페이지는 focusout 을 내지 않는다)
    os.sleepMs(800);
    try click(&host, 100, 20);
    const sh_all = watch(&host, 4000, 300);
    try typeChar(&host, 15, 'r');
    const sh_r = watch(&host, 3000, 400);
    const sh_r_text = sh_r.describe(&a_buf);
    report(sh_all.kind == .show and sh_all.count == 2 and sh_all.field.x == 0 and sh_all.field.y == 0 and sh_all.field.width == 300 and sh_all.field.height == 40 and
        sh_r.kind == .show and std.mem.eql(u8, sh_r_text, "apricot"), "dl-shadow-open", std.fmt.bufPrint(&detail_buf, "누름 {s}({d}) 칸 {d},{d} {d}x{d} · r → {s}", .{ @tagName(sh_all.kind), sh_all.count, sh_all.field.x, sh_all.field.y, sh_all.field.width, sh_all.field.height, sh_r_text }) catch "");
    var sh_pick: PickSeen = .{};
    if (sh_r.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = sh_r.list, .index = 0 } });
        sh_pick = watchPick(&host, "host-input:apricot", "sh-change:apricot", 3000);
    }
    report(sh_pick.input and sh_pick.change and sh_pick.hidden, "dl-shadow-pick", std.fmt.bufPrint(&detail_buf, "host input {} · change {} · 닫힘 {}", .{ sh_pick.input, sh_pick.change, sh_pick.hidden }) catch "");
    try clear(&host, 8);
    try click(&host, 100, 20);
    const sh_again = watch(&host, 3000, 300);
    try rawKey(&host, 0x09, 48, 9);
    const sh_tab = watch(&host, 2000, 300);
    report(sh_again.kind == .show and sh_tab.kind == .hide, "dl-shadow-blur", std.fmt.bufPrint(&detail_buf, "다시 엶 {s} · Tab 뒤 {s}", .{ @tagName(sh_again.kind), @tagName(sh_tab.kind) }) catch "");
    try click(&host, 100, 80); // s2 의 스크롤 상자 속 칸
    const sh_box = watch(&host, 3000, 300);
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 100, .y = 100 }, .delta_x = 0, .delta_y = -120 } });
    const sh_box_scroll = watch(&host, 2000, 300);
    report(sh_box.kind == .show and sh_box.field.y == 60 and sh_box_scroll.kind == .hide, "dl-shadow-scroll", std.fmt.bufPrint(&detail_buf, "상자 속 칸 {s}(y {d}) · 상자 스크롤 뒤 {s}", .{ @tagName(sh_box.kind), sh_box.field.y, @tagName(sh_box_scroll.kind) }) catch "");
    try click(&host, 100, 160); // s3 — 목록이 바깥에
    const sh_light = watch(&host, 2000, 300);
    try click(&host, 100, 220); // 선언형 닫힌 shadow
    const sh_closed = watch(&host, 2000, 300);
    report(sh_light.kind != .show and sh_closed.kind != .show, "dl-shadow-none", std.fmt.bufPrint(&detail_buf, "바깥 목록 {s} · 닫힌 shadow {s}", .{ @tagName(sh_light.kind), @tagName(sh_closed.kind) }) catch "");

    // ── W6m③: 같은 출처 iframe — 먼저 포인터 없이(Tab 으로만) ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-frame") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } }); // 이동 뒤 페이지가 초점을 잃는다(초점 없는 페이지는 focusout 을 내지 않는다)
    os.sleepMs(800);
    try click(&host, 600, 380); // 빈 곳(주 프레임) — iframe 에는 포인터가 가지 않는다
    _ = watch(&host, 600, 200);
    try rawKey(&host, 0x09, 48, 9); // 주 프레임 칸 m
    try rawKey(&host, 0x09, 48, 9); // iframe 의 칸
    _ = watch(&host, 600, 200);
    try typeChar(&host, 0, 'a');
    const keys_only = watch(&host, 2000, 300);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = .{ .x = 200, .y = 300 } } }); // iframe 위를 지나간다
    os.sleepMs(200);
    try rawKey(&host, 0x28, 125, 0xf701);
    const after_hover = watch(&host, 3000, 300);
    report(keys_only.kind != .show and after_hover.kind == .show and after_hover.field.x == 60 and after_hover.field.y == 160 and after_hover.field.width == 300 and after_hover.field.height == 40, "dl-iframe-keys", std.fmt.bufPrint(&detail_buf, "Tab·글자 {s} · 포인터 뒤 ↓ {s} 칸 {d},{d} {d}x{d}", .{ @tagName(keys_only.kind), @tagName(after_hover.kind), after_hover.field.x, after_hover.field.y, after_hover.field.width, after_hover.field.height }) catch "");

    // ── 최상위 스크롤 — iframe 목록은 닫히고, 낡은 원점으로는 열지 않는다 ──
    try host.send(.{ .wheel = .{ .browser = id, .point = .{ .x = 550, .y = 300 }, .delta_x = 0, .delta_y = -120 } }); // iframe 밖(문서)
    const top_scroll = watch(&host, 2000, 300);
    os.sleepMs(300);
    try rawKey(&host, 0x28, 125, 0xf701);
    const stale_open = watch(&host, 2000, 300);
    // 스크롤한 만큼 위로 옮겨진 칸 위를 지나간다(페이지가 알린 scrollY — 칸은 iframe 내용 원점 160 에서 시작).
    const sy = @max(top_scroll.sy, stale_open.sy);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .move, .point = .{ .x = 200, .y = 180 - sy } } });
    os.sleepMs(200);
    try rawKey(&host, 0x28, 125, 0xf701);
    const moved = watch(&host, 3000, 300);
    report(after_hover.kind == .show and top_scroll.kind == .hide and (stale_open.kind != .show or (stale_open.field.x == 60 and stale_open.field.y < 160)) and moved.kind == .show and sy > 0 and moved.field.x == 60 and moved.field.y == 160 - sy, "dl-iframe-scroll", std.fmt.bufPrint(&detail_buf, "최상위 스크롤 {s}(scrollY {d}) · 포인터 없이 ↓ {s} · 포인터 뒤 {s} 칸 {d},{d}", .{ @tagName(top_scroll.kind), sy, @tagName(stale_open.kind), @tagName(moved.kind), moved.field.x, moved.field.y }) catch "");

    // ── 같은 출처 iframe — 누르기·고르기, 주 프레임 칸 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-frame") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } }); // 이동 뒤 페이지가 초점을 잃는다(초점 없는 페이지는 focusout 을 내지 않는다)
    os.sleepMs(800);
    try click(&host, 100, 180); // iframe 안 칸
    const framed = watch(&host, 3000, 300);
    var frame_pick: PickSeen = .{};
    if (framed.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = framed.list, .index = 1 } });
        frame_pick = watchPick(&host, "in-input:b", "in-change:b", 3000);
    }
    try click(&host, 550, 220); // 주 프레임 칸
    const main_field = watch(&host, 3000, 300);
    report(framed.kind == .show and framed.field.x == 60 and framed.field.y == 160 and framed.field.width == 300 and framed.field.height == 40 and framed.count == 3 and
        frame_pick.input and frame_pick.change and frame_pick.hidden and main_field.kind == .show and main_field.count == 2, "dl-iframe", std.fmt.bufPrint(&detail_buf, "iframe {s}({d}) 칸 {d},{d} {d}x{d} · 고름 input {} change {} 닫힘 {} · 주 프레임 {s}({d})", .{ @tagName(framed.kind), framed.count, framed.field.x, framed.field.y, framed.field.width, framed.field.height, frame_pick.input, frame_pick.change, frame_pick.hidden, @tagName(main_field.kind), main_field.count }) catch "");

    // ── 다른 출처 iframe(localhost — OOPIF) ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-xframe") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } }); // 이동 뒤 페이지가 초점을 잃는다(초점 없는 페이지는 focusout 을 내지 않는다)
    os.sleepMs(800);
    try click(&host, 100, 180);
    const xframed = watch(&host, 3000, 300);
    var xframe_pick: PickSeen = .{};
    if (xframed.kind == .show) {
        try host.send(.{ .datalist_pick = .{ .browser = id, .list = xframed.list, .index = 0 } });
        xframe_pick = watchPick(&host, "in-input:a", "in-change:a", 3000);
    }
    report(xframed.kind == .show and xframed.field.x == 60 and xframed.field.y == 160 and xframed.field.width == 300 and xframed.field.height == 40 and
        xframe_pick.input and xframe_pick.change and xframe_pick.hidden, "dl-xframe", std.fmt.bufPrint(&detail_buf, "{s}({d}) 칸 {d},{d} {d}x{d} · 고름 input {} change {} 닫힘 {}", .{ @tagName(xframed.kind), xframed.count, xframed.field.x, xframed.field.y, xframed.field.width, xframed.field.height, xframe_pick.input, xframe_pick.change, xframe_pick.hidden }) catch "");
    try clear(&host, 3);
    try typeChar(&host, 6, 'z'); // zebra — 0.4 초 뒤 바깥 페이지가 iframe 을 떼어 낸다
    const zebra = watch(&host, 1000, 100);
    const removed = watch(&host, 3000, 300);
    report(zebra.kind == .show and removed.kind == .hide, "dl-iframe-removed", std.fmt.bufPrint(&detail_buf, "z {s} · 떼어 낸 뒤 {s}", .{ @tagName(zebra.kind), @tagName(removed.kind) }) catch "");

    // 렌더러 죽음 판정이 쓸 주 프레임 목록
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/datalist-frame") } });
    _ = waitTitle(&host, "dl-frame-ready", 10_000);
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } }); // 이동 뒤 페이지가 초점을 잃는다(초점 없는 페이지는 focusout 을 내지 않는다)
    os.sleepMs(800);
    try click(&host, 550, 220);
    const main_again = watch(&host, 3000, 300);

    // ── 렌더러가 죽으면 sidecar 가 닫는다(마지막 — 브라우저가 죽는다) ──
    var kids_buf: [64]c_int = undefined;
    var killed: u32 = 0;
    if (main_again.kind == .show) {
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
