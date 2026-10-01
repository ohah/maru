//! W6a① 판정 — 페이지의 팝업 위젯(`<select>` 목록)이 maru 에 닿는가(docs/plans/web-osr-backend.md D4·W6). 판정자가 **maru
//! 역할**로 `popup_changed` 와 팝업 링(`ring_message.popup_message_id`)을 받는다.
//!
//!   popup-shown        목록을 열면 `popup_changed`(보임·view DIP 사각형)가 온다 — 사각형은 `<select>` 아래(y ≥ 40), view 안
//!   popup-frame        팝업 링이 사각형 × scale 크기(±1)로 오고, 그 첫 장의 항목 다섯 줄 중 넷 이상에 글자가 있다 — 흰 장·
//!                      테두리만·어두운 바탕은 통과하지 않는다. 본 화면 링도 따로 와 있다
//!   popup-keys         ↓·Enter 로 둘째 항목이 골라지고(`change` → 제목) 팝업이 닫힌다(`popup_changed` 숨김)
//!   popup-reopen       같은 크기로 다시 열면 팝업 링이 새로 온다(세대가 앞 팝업보다 크다) — 닫힐 때 버리므로 옛 목록이 비치지
//!                      않고, maru 는 닫히기 직전의 링과 세대로 가른다
//!   popup-close        Esc·바깥 클릭·바깥 휠·초점 잃기가 각각 팝업을 닫는다(착수 전 실측과 같다)
//!   (첫 열기만 다시 누름을 받는다 — 새로 뜬 브라우저는 첫 입력을 잃을 수 있다, W7b 7~9 차. 그 뒤의 열기는 첫 클릭에 열려야 한다)
//!   popup-click-option 열린 목록의 셋째 항목 자리를 누르면 그 값이 골라진다(팝업 위젯으로 가는 클릭). maru 가 목록을 실제로
//!                      그리는 것은 W6a② — W6a① 만으로는 앱에서 여전히 보이지 않는 채 입력을 받는다
//!   popup-rescale      열린 채 화면 배율이 2 → 1 로 바뀌면 팝업이 닫히고(그 뒤 팝업 링 없음), 1 배율로 다시 열면 팝업 링이
//!                      scale 1·사각형 × 1 크기로 온다(W6a① 적대 검증 4 차 — 옛 배율이 실리지 않는다)
//!   popup-renderer-gone 열린 채 렌더러를 죽이면(SIGKILL) `renderer_gone` 과 함께 팝업 닫힘이 **한 번** 온다(그 뒤 팝업 링 없음). 판정
//!                      내내 host 메시지가 모두 해석됐는지도 여기서 본다(해석 못 한 메시지는 다른 판정에서 시간 초과로만 보인다)

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
    first_generation: u32 = 0,
    shows: u32 = 0,
    hides: u32 = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    popup_rings: u32 = 0,
    /// 마지막 팝업 링 — 첫 장을 읽을 때까지 쥔다.
    last_popup: ?Ring = null,
    first_pixel: ?u32 = null,
    /// 첫 장의 글자(줄 띠마다 — `ink`).
    first_ink: Ink = .{},
    last_generation: u32 = 0,
    /// 마지막 팝업 링의 scale·크기(픽셀).
    last_scale: f32 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,
    renderer_gone: u32 = 0,
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
                // 열린 팝업의 첫 세대보다 작은 링은 닫히기 직전 팝업의 것이다 — 앱(W6a②)처럼 버린다(W6a① 적대 검증 7 차: 첫 링
                // 알림과 닫힘이 한 `step` 안에 붙으면 닫힘을 먼저 처리한 뒤 그 옛 링을 새 팝업의 첫 장으로 읽었다).
                if (self.popup_visible and r.generation < self.first_generation) {
                    r.release();
                    continue;
                }
                self.popup_rings += 1;
                self.last_generation = r.generation;
                self.last_scale = r.scale;
                self.last_width = r.width;
                self.last_height = r.height;
                if (self.last_popup) |old| old.release();
                self.last_popup = r;
                self.first_pixel = null;
            },
        };
        if (self.last_popup) |*r| if (self.first_pixel == null) {
            switch (mailbox.take(@ptrFromInt(r.control_address), r.generation, mailbox.initial_front)) {
                .frame => |slot| {
                    const s = r.surfaces[slot];
                    iosurface.lockRead(s);
                    defer iosurface.unlockRead(s);
                    self.first_pixel = iosurface.pixel(s, iosurface.width(s) / 2, iosurface.height(s) / 2);
                    self.first_ink = ink(s);
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
                    self.first_generation = v.first_generation;
                    if (self.last_popup) |old| if (old.generation < v.first_generation) {
                        old.release();
                        self.last_popup = null;
                        self.first_pixel = null;
                    };
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
            .renderer_gone => |v| if (v.browser == browser_id) {
                self.renderer_gone += 1;
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

/// 목록의 글자 — 테두리를 뺀 안쪽(가장자리 3 DIP × scale)을 항목 다섯 줄 띠로 나눠, 밝기 0x60 아래 픽셀이 20 개 넘는 띠 수와
/// 안쪽의 어두운 비율(‰)을 센다. 흰 장·테두리만·한 낱말만·어두운 바탕은 통과하지 못한다(W6a① 적대 검증 3 차 — 테두리
/// `#767676` 과 선택 바탕은 어둡지 않다).
const Ink = struct { total: usize = 0, bands_with_text: u8 = 0, dark_permille: usize = 0 };

fn ink(surface: iosurface.Ref) Ink {
    const w = iosurface.width(surface);
    const h = iosurface.height(surface);
    const inset: usize = @intFromFloat(3 * scale);
    if (w <= 2 * inset or h <= 2 * inset) return .{};
    var bands: [5]usize = @splat(0);
    var result: Ink = .{};
    var y: usize = inset;
    while (y < h - inset) : (y += 1) {
        var x: usize = inset;
        while (x < w - inset) : (x += 1) {
            const p = iosurface.pixel(surface, x, y);
            const lum = ((p >> 16) & 0xff) * 3 + ((p >> 8) & 0xff) * 6 + (p & 0xff);
            if (lum < 0x60 * 10) {
                result.total += 1;
                bands[@min(4, y * 5 / h)] += 1;
            }
        }
    }
    for (bands) |n| {
        if (n > 20) result.bands_with_text += 1;
    }
    result.dark_permille = result.total * 1000 / ((w - 2 * inset) * (h - 2 * inset));
    return result;
}

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

/// 첫 열기 뒤의 열기 — 열렸으면 true, 첫 클릭이 아니었으면 `first_click` 을 거짓으로.
fn openAgain(w: *Watch, first_click: *bool) !bool {
    const attempt = try open(w);
    if (attempt != 1) first_click.* = false;
    return attempt != 0;
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
    const below = b.y >= 40 and b.x >= 0 and b.width > 0 and b.height > 0 and @as(i64, b.x) + b.width <= 640 and @as(i64, b.y) + b.height <= 400;
    report(opened != 0 and below, "popup-shown", std.fmt.bufPrint(&detail, "{d} 번째 클릭에 열림 · 사각형 {d},{d} {d}x{d}(view DIP, `<select>` 아래·view 안 {})", .{ opened, b.x, b.y, b.width, b.height, below }) catch "");

    _ = w.until(3_000, hasFirstPixel);
    const r = w.last_popup;
    const want_w: i64 = @intFromFloat(@as(f32, @floatFromInt(b.width)) * scale);
    const want_h: i64 = @intFromFloat(@as(f32, @floatFromInt(b.height)) * scale);
    const size_ok = if (r) |x| @abs(@as(i64, x.width) - want_w) <= 1 and @abs(@as(i64, x.height) - want_h) <= 1 else false;
    const pixel = w.first_pixel orelse 0;
    const gen_ok = if (r) |x| w.first_generation != 0 and x.generation >= w.first_generation else false;
    report(r != null and size_ok and pixel >> 24 != 0 and w.first_ink.bands_with_text >= 4 and w.first_ink.dark_permille < 300 and w.main_rings >= 1 and w.rejected == 0 and gen_ok, "popup-frame", std.fmt.bufPrint(&detail, "팝업 링 {d} 개 · {d}x{d}(사각형 × {d} = {d}x{d}) · 첫 장 가운데 픽셀 0x{x:0>8} · 글자 있는 줄 {d}/5(글자 픽셀 {d}, 어두운 비율 {d}‰) · 본 화면 링 {d} · 거절 {d} · 세대 {d} ≥ 알린 첫 세대 {d}", .{ w.popup_rings, if (r) |x| x.width else 0, if (r) |x| x.height else 0, @as(u32, @intFromFloat(scale)), want_w, want_h, pixel, w.first_ink.bands_with_text, w.first_ink.total, w.first_ink.dark_permille, w.main_rings, w.rejected, if (r) |x| x.generation else 0, w.first_generation }) catch "");

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
    const generation_before = w.last_generation;
    const reopened = try open(&w);
    _ = w.until(3_000, hasFirstPixel);
    report(reopened == 1 and w.popup_rings > rings_before and w.last_generation > generation_before and w.first_generation > generation_before and w.last_generation >= w.first_generation and w.first_pixel != null, "popup-reopen", std.fmt.bufPrint(&detail, "{d} 번째 클릭에 다시 열림 · 팝업 링 {d} → {d}(새 링이어야) · 세대 {d} → {d}(커야) · 알린 첫 세대 {d}(앞 세대보다 커야) · 첫 장 {}", .{ reopened, rings_before, w.popup_rings, generation_before, w.last_generation, w.first_generation, w.first_pixel != null }) catch "");

    // ── 닫기: Esc·바깥 클릭·바깥 휠·초점 잃기 ──
    try key(&host, 53, 27, false);
    const by_esc = w.until(2_000, isHidden);
    var later_opens_first_click = true;
    var by_outside = false;
    if (try openAgain(&w, &later_opens_first_click)) {
        try click(&host, .{ .x = 500, .y = 350 });
        by_outside = w.until(2_000, isHidden);
    }
    var by_wheel = false;
    if (try openAgain(&w, &later_opens_first_click)) {
        try host.send(.{ .wheel = .{ .browser = browser_id, .point = .{ .x = 500, .y = 350 }, .delta_x = 0, .delta_y = -120 } });
        by_wheel = w.until(2_000, isHidden);
    }
    var by_blur = false;
    if (try openAgain(&w, &later_opens_first_click)) {
        try host.send(.{ .set_focus = .{ .browser = browser_id, .value = false } });
        by_blur = w.until(2_000, isHidden);
        try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    }
    report(by_esc and by_outside and by_wheel and by_blur and later_opens_first_click, "popup-close", std.fmt.bufPrint(&detail, "Esc {} · 바깥 클릭 {} · 바깥 휠 {} · 초점 잃기 {} · 그 사이 열기가 모두 첫 클릭 {}", .{ by_esc, by_outside, by_wheel, by_blur, later_opens_first_click }) catch "");

    // ── 열린 목록의 셋째 항목 자리를 누르기 ──
    var picked = false;
    var pick_first_click = true;
    if (try openAgain(&w, &pick_first_click)) {
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
    report(picked and pick_first_click, "popup-click-option", std.fmt.bufPrint(&detail, "셋째 항목 자리 클릭 → 제목 {s} · 팝업 보임 {}", .{ w.title(), w.popup_visible }) catch "");

    // ── 열린 채 배율 2 → 1 ──
    var rescale_open_first_click = true;
    const rescale_opened = try openAgain(&w, &rescale_open_first_click);
    _ = w.until(3_000, hasFirstPixel);
    const rings_at_rescale = w.popup_rings;
    try host.send(.{ .resize = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 1 } } });
    const closed_by_rescale = w.until(2_000, isHidden);
    w.pump(500);
    const rings_after_rescale = w.popup_rings;
    const reopened_at_1 = try open(&w);
    _ = w.until(3_000, hasFirstPixel);
    const b1 = w.popup_bounds orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const size_at_1 = w.last_popup != null and w.last_scale == 1 and @abs(@as(i64, w.last_width) - b1.width) <= 1 and @abs(@as(i64, w.last_height) - b1.height) <= 1;
    report(rescale_opened and closed_by_rescale and rings_after_rescale == rings_at_rescale and reopened_at_1 != 0 and w.first_pixel != null and size_at_1, "popup-rescale", std.fmt.bufPrint(&detail, "열림 {} · 배율 1 로 바꾸자 닫힘 {} · 그 뒤 팝업 링 {d} → {d}(없어야) · 다시 열림 {d} 번째 클릭 · 링 scale {d} {d}x{d}(사각형 {d}x{d}) · 첫 장 {}", .{ rescale_opened, closed_by_rescale, rings_at_rescale, rings_after_rescale, reopened_at_1, w.last_scale, w.last_width, w.last_height, b1.width, b1.height, w.first_pixel != null }) catch "");

    // ── 열린 채 렌더러를 죽인다 ──
    const open_before_kill = w.popup_visible or (try open(&w)) != 0;
    var kids_buf: [64]c_int = undefined;
    var killed: u32 = 0;
    for (os.children(host.pid, &kids_buf)) |kid| {
        if (os.argsContain(kid, "--type=renderer")) {
            _ = std.c.kill(kid, std.c.SIG.KILL);
            killed += 1;
        }
    }
    const gone_and_hidden = struct {
        fn f(x: *const Watch) bool {
            return x.renderer_gone != 0 and !x.popup_visible;
        }
    }.f;
    const rings_at_kill = w.popup_rings;
    const hides_at_kill = w.hides;
    const gone_ok = w.until(5_000, gone_and_hidden);
    w.pump(500);
    report(open_before_kill and killed >= 1 and gone_ok and w.hides - hides_at_kill == 1 and w.popup_rings == rings_at_kill and host.clean, "popup-renderer-gone", std.fmt.bufPrint(&detail, "죽이기 전 열림 {} · 죽인 렌더러 {d} · renderer_gone {d} · 닫힘 알림 {d}(하나여야) · 팝업 보임 {} · 그 뒤 팝업 링 {d} → {d}(없어야) · host 메시지 모두 해석됨 {}", .{ open_before_kill, killed, w.renderer_gone, w.hides - hides_at_kill, w.popup_visible, rings_at_kill, w.popup_rings, host.clean }) catch "");
}
