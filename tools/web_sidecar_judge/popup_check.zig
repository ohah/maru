//! W6a① 판정 — 페이지의 팝업 위젯(`<select>` 목록)이 maru 에 닿는가(docs/plans/web-osr-backend.md D4·W6). 판정자가 **maru
//! 역할**로 `popup_changed` 와 팝업 링(`ring_message.popup_message_id`)을 받는다.
//!
//!   popup-shown        목록을 열면 `popup_changed`(보임·view DIP 사각형)가 온다 — 사각형은 `<select>` 아래, view 안
//!   popup-frame        팝업 링이 사각형 × scale 크기(±1)로 오고, 그 첫 장이 비어 있지 않다(본 화면 링과 따로)
//!   popup-keys         ↓·Enter 로 둘째 항목이 골라지고(`change` → 제목) 팝업이 닫힌다(`popup_changed` 숨김)
//!   popup-reopen       같은 크기로 다시 열면 팝업 링이 새로 온다 — 닫힐 때 버리므로 옛 목록이 비치지 않는다
//!   popup-close        Esc·바깥 클릭·바깥 휠·초점 잃기가 각각 팝업을 닫는다(착수 전 실측과 같다)
//!   popup-click-option 열린 목록의 셋째 항목 자리를 누르면 그 값이 골라진다(팝업 위젯으로 가는 클릭 — 보이지 않던 목록이
//!                      입력을 받던 것을 이제 보이게 그린다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const ring = @import("web_sidecar_ring");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const Receiver = ring.ring_receiver.Receiver;
const Ring = ring.ring_receiver.Ring;
const mailbox = protocol.mailbox;
const iosurface = ring.iosurface;
const Rect = protocol.message.Rect;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 21;
const scale: f32 = 2;
const wait_ms = 15_000;
/// 페이지의 `<select>` 가운데(view DIP — `http.zig` `/sel`).
const select_point: protocol.message.Point = .{ .x = 100, .y = 25 };

/// maru 역할의 관찰 — sidecar 알림과 링을 함께 비운다.
const Watch = struct {
    host: *Host,
    receiver: *Receiver,
    popup_visible: bool = false,
    popup_bounds: ?Rect = null,
    shows: u32 = 0,
    hides: u32 = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    popup_rings: u32 = 0,
    /// 마지막 팝업 링 — 첫 장을 읽을 때까지 쥔다.
    last_popup: ?Ring = null,
    first_pixel: ?u32 = null,
    main_rings: u32 = 0,
    rejected: u32 = 0,

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn pump(self: *Watch, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    /// 조건이 설 때까지(최대 `ms`) 비운다.
    fn until(self: *Watch, ms: u32, cond: *const fn (*const Watch) bool) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (cond(self)) return true;
            self.step();
        }
        return cond(self);
    }

    fn step(self: *Watch) void {
        while (self.receiver.receive(0) catch null) |received| switch (received) {
            .rejected => self.rejected += 1,
            .ring => |r| {
                if (r.browser != browser_id or !r.popup) {
                    if (!r.popup) self.main_rings += 1;
                    r.release();
                    continue;
                }
                self.popup_rings += 1;
                if (self.last_popup) |old| old.release();
                self.last_popup = r;
                self.first_pixel = null;
            },
        };
        if (self.last_popup) |*r| if (self.first_pixel == null) {
            switch (mailbox.take(@ptrFromInt(r.control_address), r.generation, mailbox.initial_front)) {
                .frame => |slot| {
                    const s = r.surfaces[slot];
                    self.first_pixel = iosurface.pixel(s, iosurface.width(s) / 2, iosurface.height(s) / 2);
                },
                else => {},
            }
        };
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .popup_changed => |v| if (v.browser == browser_id) {
                self.popup_visible = v.visible;
                if (v.visible) {
                    self.popup_bounds = v.bounds;
                    self.shows += 1;
                } else {
                    self.hides += 1;
                    // 닫힌 팝업의 링은 sidecar 가 버렸다 — 다음에 열면 새 링의 첫 장을 기다린다(옛 장을 새 것으로 읽지 않게).
                    // 팝업은 열린 뒤 수십 ms 지나야 그려진다 — maru 도 새 장이 오기 전에는 그리지 않는다(W6a②).
                    if (self.last_popup) |old| old.release();
                    self.last_popup = null;
                    self.first_pixel = null;
                }
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            else => {},
        }
    }

    fn release(self: *Watch) void {
        if (self.last_popup) |r| r.release();
        self.last_popup = null;
    }
};

fn isVisible(w: *const Watch) bool {
    return w.popup_visible;
}

fn isHidden(w: *const Watch) bool {
    return !w.popup_visible;
}

fn hasFirstPixel(w: *const Watch) bool {
    return w.first_pixel != null;
}

fn click(host: *Host, point: protocol.message.Point) !void {
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .point = point, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .point = point, .click_count = 1 } });
}

fn key(host: *Host, native: u8, ch: u16, with_char: bool) !void {
    const k: protocol.message.Key = .{ .browser = browser_id, .kind = .raw_down, .native_key_code = native, .character = ch, .unmodified_character = ch };
    try host.send(.{ .key = k });
    if (with_char) {
        var c = k;
        c.kind = .char;
        try host.send(.{ .key = c });
    }
    var up = k;
    up.kind = .up;
    try host.send(.{ .key = up });
}

/// 목록을 연다 — 새로 뜬 브라우저는 첫 입력을 잃을 수 있어(W7b 7~9 차) 열릴 때까지 몇 번 누른다. 연 횟수를 돌려준다(0 = 못 엶).
fn open(w: *Watch) !u8 {
    var attempt: u8 = 1;
    while (attempt <= 4) : (attempt += 1) {
        try click(w.host, select_point);
        if (w.until(2_000, isVisible)) return attempt;
    }
    return 0;
}

fn titleIs(w: *const Watch, want: []const u8) bool {
    return std.mem.eql(u8, w.title(), want);
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [320]u8 = undefined;
    var u: [256]u8 = undefined;

    var receiver = try Receiver.open();
    defer receiver.close();
    var host = try Host.spawn(host_path, profile_arg);
    receiver.expected_pid = host.pid;
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .frame_channel = .{ .service = receiver.serviceName(), .token = receiver.token } });
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = scale }, .hidden = false, .url = browsers_check.url(&u, port, "/sel") } });
    var w: Watch = .{ .host = &host, .receiver = &receiver };
    defer w.release();
    const ready = struct {
        fn f(x: *const Watch) bool {
            return titleIs(x, "sel-ready");
        }
    }.f;
    if (!w.until(wait_ms, ready)) return error.SelectPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });

    // ── 열기 ──
    const opened = try open(&w);
    const b = w.popup_bounds orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const below = b.y >= 30 and b.x >= 0 and b.width > 0 and b.height > 0 and @as(i64, b.x) + b.width <= 640 and @as(i64, b.y) + b.height <= 400;
    report(opened != 0 and below, "popup-shown", std.fmt.bufPrint(&detail, "{d} 번째 클릭에 열림 · 사각형 {d},{d} {d}x{d}(view DIP, `<select>` 아래·view 안 {})", .{ opened, b.x, b.y, b.width, b.height, below }) catch "");

    _ = w.until(3_000, hasFirstPixel);
    const r = w.last_popup;
    const want_w: i64 = @intFromFloat(@as(f32, @floatFromInt(b.width)) * scale);
    const want_h: i64 = @intFromFloat(@as(f32, @floatFromInt(b.height)) * scale);
    const size_ok = if (r) |x| @abs(@as(i64, x.width) - want_w) <= 1 and @abs(@as(i64, x.height) - want_h) <= 1 else false;
    const pixel = w.first_pixel orelse 0;
    report(r != null and size_ok and pixel >> 24 != 0 and w.rejected == 0, "popup-frame", std.fmt.bufPrint(&detail, "팝업 링 {d} 개 · {d}x{d}(사각형 × {d} = {d}x{d}) · 첫 장 가운데 픽셀 0x{x:0>8} · 거절 {d}", .{ w.popup_rings, if (r) |x| x.width else 0, if (r) |x| x.height else 0, @as(u32, @intFromFloat(scale)), want_w, want_h, pixel, w.rejected }) catch "");

    // ── ↓·Enter ──
    try key(&host, 125, 0xF701, false);
    w.pump(300);
    try key(&host, 36, 13, true);
    const chose_b = struct {
        fn f(x: *const Watch) bool {
            return titleIs(x, "sel:b") and !x.popup_visible;
        }
    }.f;
    const keys_ok = w.until(3_000, chose_b);
    report(keys_ok, "popup-keys", std.fmt.bufPrint(&detail, "↓·Enter → 제목 {s} · 팝업 보임 {}", .{ w.title(), w.popup_visible }) catch "");

    // ── 같은 크기로 다시 열기 ──
    const rings_before = w.popup_rings;
    const reopened = try open(&w);
    _ = w.until(3_000, hasFirstPixel);
    report(reopened != 0 and w.popup_rings == rings_before + 1 and w.first_pixel != null, "popup-reopen", std.fmt.bufPrint(&detail, "다시 열림 {} · 팝업 링 {d} → {d}(새 링이어야) · 첫 장 {}", .{ reopened != 0, rings_before, w.popup_rings, w.first_pixel != null }) catch "");

    // ── 닫기: Esc·바깥 클릭·바깥 휠·초점 잃기 ──
    try key(&host, 53, 27, false);
    const by_esc = w.until(2_000, isHidden);
    var by_outside = false;
    if (try open(&w) != 0) {
        try click(&host, .{ .x = 500, .y = 350 });
        by_outside = w.until(2_000, isHidden);
    }
    var by_wheel = false;
    if (try open(&w) != 0) {
        try host.send(.{ .wheel = .{ .browser = browser_id, .point = .{ .x = 500, .y = 350 }, .delta_x = 0, .delta_y = -120 } });
        by_wheel = w.until(2_000, isHidden);
    }
    var by_blur = false;
    if (try open(&w) != 0) {
        try host.send(.{ .set_focus = .{ .browser = browser_id, .value = false } });
        by_blur = w.until(2_000, isHidden);
        try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    }
    report(by_esc and by_outside and by_wheel and by_blur, "popup-close", std.fmt.bufPrint(&detail, "Esc {} · 바깥 클릭 {} · 바깥 휠 {} · 초점 잃기 {}", .{ by_esc, by_outside, by_wheel, by_blur }) catch "");

    // ── 열린 목록의 셋째 항목 자리를 누르기 ──
    var picked = false;
    if (try open(&w) != 0) {
        const pb = w.popup_bounds.?;
        // 다섯 항목이 사각형 높이를 고르게 나눈다(테두리는 무시할 만하다) — 셋째의 가운데.
        const row: i32 = @intCast(pb.height / 5);
        const target: protocol.message.Point = .{ .x = pb.x + @as(i32, @intCast(pb.width / 2)), .y = pb.y + row * 2 + @divTrunc(row, 2) };
        try click(&host, target);
        const chose_c = struct {
            fn f(x: *const Watch) bool {
                return titleIs(x, "sel:c") and !x.popup_visible;
            }
        }.f;
        picked = w.until(3_000, chose_c);
    }
    report(picked, "popup-click-option", std.fmt.bufPrint(&detail, "셋째 항목 자리 클릭 → 제목 {s} · 팝업 보임 {}", .{ w.title(), w.popup_visible }) catch "");
}
