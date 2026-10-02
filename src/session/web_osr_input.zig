//! OSR 포인터 입력의 순수 규칙(W4b, docs/plans/web-osr-backend.md C5) — L2. 창의 backing px 좌표를 브라우저 view 의 DIP
//! 로 바꾸고, 어느 OSR 본문 위인지(분할 divider 잡는 띠는 빼고), xterm 수식자 비트·버튼·클릭 수·휠 양을 codec 값으로 옮긴다.
//! 라우팅(누가 받는가 — 오버레이 게이트·제스처 주인)은 L4(`app_session/web.zig`)가 이 함수들로 정한다.

const std = @import("std");
const web_sidecar = @import("web_sidecar/root.zig");
const message = web_sidecar.message;

pub const Rect = @import("split_tree.zig").Rect;
pub const Point = message.Point;
pub const Modifiers = message.Modifiers;
pub const MouseButton = message.MouseButton;

/// 이 창이 이번 tick 에 그린 OSR 본문 하나(창 backing px·좌상단).
pub const Target = struct {
    surface_id: u64,
    rect: Rect,
    /// 분할 divider 에 맞닿은 가장자리(left=1·right=2·bottom=4 — `web_panel_layout.SurfaceLayout.seam_edges`).
    seam_edges: u8 = 0,
    /// 가장자리별 divider 잡는 띠 폭(backing px). 이 띠 안의 클릭·hover 는 웹이 아니라 divider 것이다 — WKWebView 가
    /// hitTest 에서 통과시키는 것과 같은 자리(`WebPanelHitTestGeometry`).
    left_band_px: f64 = 0,
    right_band_px: f64 = 0,
    bottom_band_px: f64 = 0,
};

/// divider 잡는 띠 안인가. 망가진 폭(비유한·음수·rect 보다 큼)은 0 으로 본다 — 본문 전체를 통과시키지 않는다.
fn inGrabBand(t: Target, x: f64, y: f64) bool {
    if (t.seam_edges == 0) return false;
    const w: f64 = @floatFromInt(t.rect.w);
    const h: f64 = @floatFromInt(t.rect.h);
    const left = sane(t.left_band_px, w);
    const right = sane(t.right_band_px, w);
    const bottom = sane(t.bottom_band_px, h);
    const x0: f64 = @floatFromInt(t.rect.x);
    const y0: f64 = @floatFromInt(t.rect.y);
    if (t.seam_edges & 1 != 0 and left > 0 and x < x0 + left) return true;
    if (t.seam_edges & 2 != 0 and right > 0 and x >= x0 + w - right) return true;
    if (t.seam_edges & 4 != 0 and bottom > 0 and y >= y0 + h - bottom) return true;
    return false;
}

fn sane(band: f64, limit: f64) f64 {
    return if (std.math.isFinite(band) and band > 0 and band <= limit) band else 0;
}

/// 이 점이 올라 있는 OSR 본문(divider 띠 제외). 겹치지 않으므로 처음 맞는 것.
pub fn hit(targets: []const Target, x_px: f64, y_px: f64) ?Target {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    for (targets) |t| {
        const x0: f64 = @floatFromInt(t.rect.x);
        const y0: f64 = @floatFromInt(t.rect.y);
        if (x_px < x0 or y_px < y0) continue;
        if (x_px >= x0 + @as(f64, @floatFromInt(t.rect.w)) or y_px >= y0 + @as(f64, @floatFromInt(t.rect.h))) continue;
        if (inGrabBand(t, x_px, y_px)) continue;
        return t;
    }
    return null;
}

/// 팝업 위젯 한 장을 본문 위에 붙일 자리(W6a② — D4). 창 backing px 좌상단.
pub const PopupQuad = struct { x: f32, y: f32, w: f32, h: f32, u0: f32, v0: f32, u1: f32, v1: f32 };

/// 팝업 장(`tex_w`×`tex_h` px)을 본문 `rect`(backing px)의 view DIP `bounds` 자리에 1:1 로 붙인다 — 본문 밖으로 나간 부분은
/// UV 로 잘라 그리지 않는다(팝업이 다른 pane·탭 막대를 덮지 않게). 다 잘리면 null. sidecar 의 `get_screen_info` 가 화면
/// 사각형을 비워 둔다(배율만) — 그러면 CEF 는 view 사각형을 화면으로 쓰는 것으로 보이고(CEF 소스로는 확인하지 않았다), 맨
/// 아래 select 의 목록은 위로 뒤집혀 view 안에 들어왔다(앱 실측). 그래도 자르는 것은 maru 가 지킨다.
pub fn popupQuad(rect: Rect, bounds: message.Rect, scale: f64, tex_w: u32, tex_h: u32) ?PopupQuad {
    if (tex_w == 0 or tex_h == 0 or !std.math.isFinite(scale) or scale <= 0) return null;
    const rx0: f64 = @floatFromInt(rect.x);
    const ry0: f64 = @floatFromInt(rect.y);
    const rx1 = rx0 + @as(f64, @floatFromInt(rect.w));
    const ry1 = ry0 + @as(f64, @floatFromInt(rect.h));
    const tw: f64 = @floatFromInt(tex_w);
    const th: f64 = @floatFromInt(tex_h);
    const x0 = rx0 + @round(@as(f64, @floatFromInt(bounds.x)) * scale);
    const y0 = ry0 + @round(@as(f64, @floatFromInt(bounds.y)) * scale);
    const cx0 = @max(x0, rx0);
    const cy0 = @max(y0, ry0);
    const cx1 = @min(x0 + tw, rx1);
    const cy1 = @min(y0 + th, ry1);
    if (cx1 <= cx0 or cy1 <= cy0) return null;
    return .{
        .x = @floatCast(cx0),
        .y = @floatCast(cy0),
        .w = @floatCast(cx1 - cx0),
        .h = @floatCast(cy1 - cy0),
        .u0 = @floatCast((cx0 - x0) / tw),
        .v0 = @floatCast((cy0 - y0) / th),
        .u1 = @floatCast((cx1 - x0) / tw),
        .v1 = @floatCast((cy1 - y0) / th),
    };
}

/// 팝업 장을 그리는가(W6a②) — 열려 있고, 실제 프레임이고, 그 팝업의 첫 세대 이상인 링의 장일 때만. 링은 보임 알림보다
/// 먼저 올 수 있고 닫힌 팝업의 링이 아직 보이는 링으로 남아 있을 수 있어(같은 select 를 다시 열면 크기도 같다) **그릴 때**
/// 세대로 거른다 — 이것이 없으면 새 목록의 첫 장이 오기 전 수십 ms 동안 옛 목록이 비친다(W6a② 적대 검증 4 차).
pub fn popupShows(open: bool, has_frame: bool, shown_generation: ?u32, first_generation: u32) bool {
    const generation = shown_generation orelse return false;
    return open and has_frame and generation >= first_generation;
}

/// 닫힌 팝업의 링을 놓는가(W6a②) — 닫힐 때 보이던 링(`release_generation`, 0 = 없음)이 아직 보이는 링이고, 기다리는 새
/// 링이 없고, 그 링을 마지막으로 그린 프레임을 GPU 가 끝냈을 때만. 닫힘을 처리하기 전에 다음 팝업의 링이 먼저 와 있으면
/// 그것은 기다리는 링이거나(놓지 않는다) 첫 장을 꺼내 보이는 링이 됐다(세대가 달라 놓지 않는다) — 다시 알리지 않는 그
/// 링을 잃지 않는다(1 차). 닫힌 목록의 장을 브라우저가 사라질 때까지 쥐지 않는다 — scale 2 목록 하나가 링당 약 3 MB 다
/// (4 차).
pub fn popupReleasable(open: bool, release_generation: u32, shown_generation: ?u32, pending: bool, drawn_generation: u64, completed_generation: u64) bool {
    if (open or release_generation == 0 or pending) return false;
    const generation = shown_generation orelse return false;
    if (generation != release_generation) return false;
    return drawn_generation == 0 or completed_generation >= drawn_generation;
}

/// 창이 Swift 에 알린 툴팁(W6b) — (hover 탭, 그 탭의 툴팁 세대)와 그것이 바뀔 때마다 오르는 일련번호. Swift 는 일련번호가 바뀌면
/// macOS 툴팁을 다시 단다(글이 비었으면 뗀다).
pub const TooltipSeen = struct {
    surface: u64 = 0,
    generation: u32 = 0,
    serial: u64 = 0,

    /// 지금 hover 탭(`surface`, 없으면 0)과 그 탭의 툴팁 세대를 본다 — 둘 중 하나라도 바뀌었으면 일련번호를 올린다. 다른 탭으로
    /// 가거나 탭을 떠나면(0) 세대가 같아도 오른다 — 옛 탭의 글이 새 자리에 남지 않게.
    pub fn observe(self: *TooltipSeen, surface: u64, generation: u32) u64 {
        if (surface != self.surface or generation != self.generation) {
            self.surface = surface;
            self.generation = generation;
            self.serial +%= 1;
        }
        return self.serial;
    }
};

pub fn find(targets: []const Target, surface_id: u64) ?Target {
    for (targets) |t| if (t.surface_id == surface_id) return t;
    return null;
}

/// 창 backing px → 그 브라우저 view 의 DIP(내림). 제스처 주인은 본문 밖까지 끌 수 있어 음수·view 너머도 낸다 — codec 상한
/// (`max_pointer_extent`)으로 자른다. 비유한 좌표는 원점.
pub fn toDip(rect: Rect, x_px: f64, y_px: f64, scale_milli: u32) Point {
    // 0(첫 resize 전)은 1 배로 본다.
    const scale: f64 = if (scale_milli == 0) 1.0 else @as(f64, @floatFromInt(scale_milli)) / 1000.0;
    return .{
        .x = clampExtent((x_px - @as(f64, @floatFromInt(rect.x))) / scale),
        .y = clampExtent((y_px - @as(f64, @floatFromInt(rect.y))) / scale),
    };
}

fn clampExtent(v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const limit: f64 = @floatFromInt(message.max_pointer_extent);
    return @intFromFloat(@floor(std.math.clamp(v, -limit, limit)));
}

/// 지금 눌려 있는 버튼들. 한 제스처 안에서 다른 버튼을 더 누를 수 있다(왼쪽으로 끄는 중 오른쪽) — 각 버튼의 down·up 을
/// 그대로 보내고, 끄는 move 에는 눌린 버튼을 모두 싣는다(적대 검증 — 처음엔 주인 버튼 하나만 들어 두 번째 누름이 주인을
/// 덮고 왼쪽 뗌이 오른쪽 뗌으로 나갔다).
pub const Held = packed struct(u3) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,

    pub fn with(self: Held, b: MouseButton, down: bool) Held {
        var out = self;
        switch (b) {
            .left => out.left = down,
            .middle => out.middle = down,
            .right => out.right = down,
        }
        return out;
    }

    pub fn has(self: Held, b: MouseButton) bool {
        return switch (b) {
            .left => self.left,
            .middle => self.middle,
            .right => self.right,
        };
    }

    pub fn empty(self: Held) bool {
        return !self.left and !self.middle and !self.right;
    }

    pub fn one(b: MouseButton) Held {
        return (Held{}).with(b, true);
    }
};

/// xterm 마우스 수식자(shift=4·alt=8·ctrl=16·cmd=32 — Swift `modsBits`)와 눌린 버튼들 → codec 수식자.
pub fn modifiers(xterm_mods: i32, held: Held) Modifiers {
    return .{
        .shift = xterm_mods & 4 != 0,
        .alt = xterm_mods & 8 != 0,
        .control = xterm_mods & 16 != 0,
        .command = xterm_mods & 32 != 0,
        .left_button = held.left,
        .middle_button = held.middle,
        .right_button = held.right,
    };
}

/// xterm 버튼 번호(0=왼쪽·1=가운데·2=오른쪽 — Swift 가 buttonNumber 에서 바꾼 값) → codec 버튼. 다른 값은 null.
pub fn button(xterm_button: i32) ?MouseButton {
    return switch (xterm_button) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => null,
    };
}

/// `AppSession.mouse` 의 down 종류(1=한 번·4=두 번·5=세 번 이상) → 클릭 수. down 이 아니면 null.
pub fn clickCount(kind: i32) ?u8 {
    return switch (kind) {
        1 => 1,
        4 => 2,
        5 => 3,
        else => null,
    };
}

/// 휠 양 → CEF 픽셀(DIP). 트랙패드(정밀)는 이미 점(= DIP) 단위, 마우스 휠은 줄 단위라 Chromium 과 같은 한 칸 40 을
/// 곱한다. 부호는 그대로(NSEvent `scrollingDeltaY` 음수 = 아래로 — W4a 판정의 `delta_y -300` 과 같은 쪽).
pub fn wheelDelta(delta: f64, precise: bool) i32 {
    const per_line: f64 = 40;
    return clampExtent(if (precise) @round(delta) else @round(delta * per_line));
}

/// 입력기 트랜잭션(ime_begin~ime_end) 하나에서 일어난 일(W4c). 확정은 트랜잭션 끝까지 쥐어 둔다 — 한글 마지막 자모
/// Backspace 는 입력기가 「확정 + deleteBackward」로 보내는데, 그때는 확정이 아니라 조합 취소여야 한다.
pub const ImeTxn = struct {
    key_code: u8,
    /// 트랜잭션 시작 때 조합이 열려 있었다.
    had_composition: bool = false,
    /// 시작 때 조합을 확정한 글(아직 안 보냄). 새 조합이 뒤따르면 그 전에 보내고 `commit_sent` 로 바뀐다.
    commit: ?[]const u8 = null,
    commit_sent: bool = false,
    /// 이 트랜잭션에서 비지 않은 조합 글이 섰다(조합 시작·갱신) — 키는 입력기 것이다.
    marked: bool = false,
    /// 조합 확정이 아닌 확정 글(평문·확정 뒤 공백·문장부호).
    typed: []const u8 = "",
    /// 입력기가 키 동작 명령(doCommand — insertNewline·moveLeft·deleteBackward…)을 냈다.
    command: bool = false,
    delete_backward: bool = false,
    /// 조합이 확정 없이 비워졌다(Esc 등).
    cleared: bool = false,
};

/// 트랜잭션 끝에서 보낼 것. 규칙(W4c 착수 전 실측 + 적대 검증):
///   - 시작 때 조합: 확정 글이 있으면 보낸다 — 단 빈 확정이거나, 뒤에 deleteBackward 만 있으면(한글 마지막 자모) 취소.
///     확정 없이 비워졌으면 취소.
///   - 이번 키: 새 조합이 섰거나 조합을 취소했으면 아무 키 이벤트도 없다(입력기가 가져갔다). 확정 글(평문)이 있으면 raw_down + 글자(한
///     글자·BMP) 또는 확정 글. 조합을 끝낸 키는 뒤따른 명령이 있을 때만 그 키의 동작으로 보낸다(한글 Space·Enter·
///     화살표) — 명령 없이 확정만 했으면 입력기가 키를 삼킨 것이다(일본어 변환 확정 Enter). 조합이 없던 키는 늘 raw_down
///     (Backspace·Tab·화살표·Esc 는 raw_down 만으로 동작하고, char 를 더하면 쓸데없는 keypress 가 생긴다 — 실측).
///   - Enter(Return 36·숫자패드 76)는 raw_down 에 char `\r` 을 더한다(textarea 줄바꿈·폼 제출은 keypress 가 한다).
pub const ImeOutcome = struct {
    commit: enum { none, send, cancel } = .none,
    raw_down: bool = false,
    /// raw_down 뒤에 보낼 글자(char 이벤트).
    char: ?u16 = null,
    /// raw_down 뒤에 확정 글로 보낼 `typed`(여러 글자·BMP 밖 글자).
    commit_typed: bool = false,
};

pub fn imeOutcome(t: ImeTxn) ImeOutcome {
    var out: ImeOutcome = .{};
    const only_delete = t.delete_backward and t.typed.len == 0 and !t.marked;
    if (t.commit) |c| {
        out.commit = if (c.len == 0 or only_delete) .cancel else .send;
    } else if (t.had_composition and t.cleared and !t.marked and !t.commit_sent) {
        out.commit = .cancel;
    }
    if (t.marked) return out;
    if (t.typed.len > 0) {
        out.raw_down = true;
        const len = std.unicode.utf8ByteSequenceLength(t.typed[0]) catch {
            out.commit_typed = true;
            return out;
        };
        const cp = if (len == t.typed.len) std.unicode.utf8Decode(t.typed) catch null else null;
        if (cp != null and cp.? <= 0xFFFF) out.char = @intCast(cp.?) else out.commit_typed = true;
        return out;
    }
    // 조합을 취소한 키(Esc·마지막 자모 Backspace)는 입력기 것이다 — 페이지에 Escape·Backspace 가 가면 페이지의 모달이
    // 닫히거나 태그 입력이 앞 태그를 지운다(Chrome 도 조합 중 키는 Process 로 준다 — 적대 검증).
    if (out.commit == .cancel) return out;
    const ended = t.commit != null or t.commit_sent;
    if (t.had_composition and (!ended or !t.command)) {
        // 조합을 끝낸 키는 뒤따른 명령이 있을 때만 그 키의 동작이다. 조합 중 아무 변화 없이 명령만 온 키도 그 동작이다.
        if (!(t.command and !ended)) return out;
    }
    out.raw_down = true;
    if (t.key_code == 36 or t.key_code == 76) out.char = '\r';
    return out;
}

const testing = std.testing;

test "hit finds the body under the point and skips divider grab bands" {
    const targets = [_]Target{
        .{ .surface_id = 7, .rect = .{ .x = 100, .y = 50, .w = 400, .h = 300 }, .seam_edges = 2 | 4, .right_band_px = 8, .bottom_band_px = 6 },
        .{ .surface_id = 9, .rect = .{ .x = 510, .y = 50, .w = 200, .h = 300 }, .seam_edges = 1, .left_band_px = 8 },
    };
    try testing.expectEqual(@as(u64, 7), hit(&targets, 100, 50).?.surface_id); // 왼쪽 위 끝은 안(half-open)
    try testing.expectEqual(@as(?Target, null), hit(&targets, 99.9, 60));
    try testing.expectEqual(@as(?Target, null), hit(&targets, 493, 60)); // 오른쪽 divider 띠(492 부터)
    try testing.expectEqual(@as(u64, 7), hit(&targets, 491.9, 60).?.surface_id);
    try testing.expectEqual(@as(?Target, null), hit(&targets, 200, 345)); // 아래 띠(344 부터)
    try testing.expectEqual(@as(?Target, null), hit(&targets, 515, 60)); // 둘째의 왼쪽 띠
    try testing.expectEqual(@as(u64, 9), hit(&targets, 520, 60).?.surface_id);
    try testing.expectEqual(@as(?Target, null), hit(&targets, std.math.nan(f64), 60));
}

test "broken band widths do not swallow the whole body" {
    const t: Target = .{ .surface_id = 1, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .seam_edges = 1 | 2 | 4, .left_band_px = std.math.inf(f64), .right_band_px = 1000, .bottom_band_px = -5 };
    try testing.expectEqual(@as(u64, 1), hit(&.{t}, 50, 50).?.surface_id);
}

test "toDip divides by the scale, floors, and keeps out-of-body drags within the codec bound" {
    const rect: Rect = .{ .x = 100, .y = 40, .w = 800, .h = 600 };
    try testing.expectEqual(Point{ .x = 10, .y = 5 }, toDip(rect, 121, 51, 2000));
    try testing.expectEqual(Point{ .x = -1, .y = -20 }, toDip(rect, 99, 0, 2000)); // 본문 왼쪽 밖·위 밖
    try testing.expectEqual(Point{ .x = 21, .y = 11 }, toDip(rect, 121, 51, 1000));
    try testing.expectEqual(Point{ .x = message.max_pointer_extent, .y = 0 }, toDip(rect, 1e12, 40, 2000));
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, toDip(rect, std.math.inf(f64), std.math.nan(f64), 2000));
    try testing.expectEqual(Point{ .x = 50, .y = 0 }, toDip(rect, 150, 40, 0)); // scale 0 은 1 로
}

test "modifiers map xterm bits and every held button" {
    try testing.expectEqual(Modifiers{}, modifiers(0, .{}));
    try testing.expectEqual(Modifiers{ .shift = true, .command = true, .left_button = true }, modifiers(4 | 32, Held.one(.left)));
    try testing.expectEqual(Modifiers{ .alt = true, .control = true, .right_button = true }, modifiers(8 | 16, Held.one(.right)));
    try testing.expectEqual(Modifiers{ .middle_button = true }, modifiers(1 | 2 | 64, Held.one(.middle))); // 모르는 비트는 버린다
    try testing.expectEqual(Modifiers{ .left_button = true, .right_button = true }, modifiers(0, Held.one(.left).with(.right, true)));
}

test "held buttons: a second button joins and leaves without disturbing the first" {
    var held = Held.one(.left);
    held = held.with(.right, true);
    try testing.expect(held.has(.left) and held.has(.right) and !held.has(.middle));
    held = held.with(.right, false);
    try testing.expect(held.has(.left) and !held.empty());
    held = held.with(.left, false);
    try testing.expect(held.empty());
}

test "buttons, click counts and wheel deltas" {
    try testing.expectEqual(MouseButton.middle, button(1).?);
    try testing.expectEqual(@as(?MouseButton, null), button(3));
    try testing.expectEqual(@as(?u8, 2), clickCount(4));
    try testing.expectEqual(@as(?u8, null), clickCount(2));
    try testing.expectEqual(@as(i32, -12), wheelDelta(-12.4, true));
    try testing.expectEqual(@as(i32, -120), wheelDelta(-3, false));
    try testing.expectEqual(message.max_pointer_extent, wheelDelta(1e9, false));
    try testing.expectEqual(@as(i32, 0), wheelDelta(std.math.nan(f64), true));
}

test "ime outcome without a composition: plain letters, Enter and other keys" {
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .char = 'a' }, imeOutcome(.{ .key_code = 0, .typed = "a" }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .char = 0xE9 }, imeOutcome(.{ .key_code = 14, .typed = "é" }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .char = '\r' }, imeOutcome(.{ .key_code = 36, .command = true }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .char = '\r' }, imeOutcome(.{ .key_code = 76 }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true }, imeOutcome(.{ .key_code = 51, .command = true, .delete_backward = true }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true }, imeOutcome(.{ .key_code = 48, .command = true }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .commit_typed = true }, imeOutcome(.{ .key_code = 0, .typed = "ab" }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .commit_typed = true }, imeOutcome(.{ .key_code = 0, .typed = "😀" }));
    try testing.expectEqual(ImeOutcome{ .raw_down = true, .commit_typed = true }, imeOutcome(.{ .key_code = 0, .typed = "\xff" }));
    // 조합 시작 — 키는 입력기 것.
    try testing.expectEqual(ImeOutcome{}, imeOutcome(.{ .key_code = 2, .marked = true }));
}

test "ime outcome with a composition: the key that ends it (Korean Space, Enter, arrows) still acts" {
    // 한글 Space: 「한」 확정 + 「 」 삽입 → 확정을 보내고 공백 키.
    try testing.expectEqual(ImeOutcome{ .commit = .send, .raw_down = true, .char = ' ' }, imeOutcome(.{ .key_code = 49, .had_composition = true, .commit = "한", .typed = " " }));
    // 한글 Enter: 확정 + insertNewline 명령 → 확정 뒤 Enter.
    try testing.expectEqual(ImeOutcome{ .commit = .send, .raw_down = true, .char = '\r' }, imeOutcome(.{ .key_code = 36, .had_composition = true, .commit = "한", .command = true }));
    // 한글 ←: 확정 + moveLeft.
    try testing.expectEqual(ImeOutcome{ .commit = .send, .raw_down = true }, imeOutcome(.{ .key_code = 123, .had_composition = true, .commit = "한", .command = true }));
    // 일본어 변환 확정 Enter: 확정만, 명령 없음 → 입력기가 키를 삼켰다.
    try testing.expectEqual(ImeOutcome{ .commit = .send }, imeOutcome(.{ .key_code = 36, .had_composition = true, .commit = "漢字" }));
    // 다음 음절: 「한」 확정 + 「ㄱ」 조합(확정은 조합 전에 이미 보냄).
    try testing.expectEqual(ImeOutcome{}, imeOutcome(.{ .key_code = 1, .had_composition = true, .commit_sent = true, .marked = true }));
    // 자모 갱신(하 → 한): 키 이벤트 없음.
    try testing.expectEqual(ImeOutcome{}, imeOutcome(.{ .key_code = 45, .had_composition = true, .marked = true }));
}

test "ime outcome with a composition: last jamo Backspace, empty commit and Esc cancel instead of committing" {
    // 마지막 자모 Backspace: 입력기가 「ㄴ」 확정 + deleteBackward → 확정이 아니라 조합 취소, 키도 안 보낸다.
    try testing.expectEqual(ImeOutcome{ .commit = .cancel }, imeOutcome(.{ .key_code = 51, .had_composition = true, .commit = "ㄴ", .command = true, .delete_backward = true }));
    // 빈 확정(insertText("")) → 취소.
    try testing.expectEqual(ImeOutcome{ .commit = .cancel }, imeOutcome(.{ .key_code = 51, .had_composition = true, .commit = "" }));
    // Esc 가 조합을 비움(확정 없음) → 취소, Escape 키는 안 보낸다(입력기 것).
    try testing.expectEqual(ImeOutcome{ .commit = .cancel }, imeOutcome(.{ .key_code = 53, .had_composition = true, .cleared = true, .command = true }));
    // 조합 중 아무 변화 없이 명령만(드묾) → 그 키.
    try testing.expectEqual(ImeOutcome{ .raw_down = true }, imeOutcome(.{ .key_code = 123, .had_composition = true, .command = true }));
    // 조합 중 아무 일도 없음 → 입력기가 삼킴.
    try testing.expectEqual(ImeOutcome{}, imeOutcome(.{ .key_code = 7, .had_composition = true }));
}

test "tooltip serial bumps when the hover surface or its tooltip generation changes, not otherwise" {
    var seen: TooltipSeen = .{};
    const s0 = seen.observe(0, 0);
    try testing.expectEqual(s0, seen.observe(0, 0));
    const s1 = seen.observe(7, 3); // 탭에 들어왔다
    try testing.expect(s1 != s0);
    try testing.expectEqual(s1, seen.observe(7, 3)); // 그대로
    const s2 = seen.observe(7, 4); // 글이 바뀌었다
    try testing.expect(s2 != s1);
    const s3 = seen.observe(9, 4); // 다른 탭(세대가 우연히 같다)
    try testing.expect(s3 != s2);
    const s4 = seen.observe(0, 0); // 떠났다
    try testing.expect(s4 != s3);
    try testing.expectEqual(s4, seen.observe(0, 0));
}

test "popup shows only when open, with a real frame, from a ring of this popup (generation >= first)" {
    try testing.expect(popupShows(true, true, 5, 5));
    try testing.expect(popupShows(true, true, 6, 5));
    // 닫힌 팝업의 링이 아직 보이는 링이다(같은 select 를 다시 열었다 — 크기도 같다) — 새 팝업의 첫 장 전에는 그리지 않는다.
    try testing.expect(!popupShows(true, true, 4, 5));
    try testing.expect(!popupShows(false, true, 5, 5));
    try testing.expect(!popupShows(true, false, 5, 5));
    try testing.expect(!popupShows(true, true, null, 0));
}

test "a closed popup's ring is released only when it is still the shown ring, nothing waits, and the GPU is done" {
    // 닫힐 때 보이던 링(7) 그대로, 기다리는 링 없음, GPU 가 그 장을 그린 프레임(30)을 끝냈다.
    try testing.expect(popupReleasable(false, 7, 7, false, 30, 30));
    try testing.expect(popupReleasable(false, 7, 7, false, 0, 0)); // 그린 적 없다
    // GPU 가 아직 읽는다.
    try testing.expect(!popupReleasable(false, 7, 7, false, 30, 29));
    // 다음 팝업의 링이 먼저 와 기다린다 / 이미 첫 장을 꺼내 보이는 링이 됐다 — 다시 알리지 않는 그 링을 잃지 않는다.
    try testing.expect(!popupReleasable(false, 7, 7, true, 30, 30));
    try testing.expect(!popupReleasable(false, 7, 8, false, 30, 30));
    // 열려 있다 / 닫힐 때 보이던 링이 없었다 / 보이는 링이 없다.
    try testing.expect(!popupReleasable(true, 7, 7, false, 30, 30));
    try testing.expect(!popupReleasable(false, 0, 7, false, 30, 30));
    try testing.expect(!popupReleasable(false, 7, null, false, 30, 30));
}

test "popup quad: 1:1 at the view DIP spot, clipped to the body with matching UV, null when fully outside" {
    const body: Rect = .{ .x = 100, .y = 40, .w = 800, .h = 600 };
    // 실측한 목록 크기(view DIP 382x157, scale 2 → 장 764x314)를 아래로 넘치게 둔다.
    const seen = popupQuad(body, .{ .x = 0, .y = 183, .width = 382, .height = 157 }, 2, 764, 314).?;
    try testing.expectEqual(@as(f32, 100), seen.x);
    try testing.expectEqual(@as(f32, 406), seen.y);
    try testing.expectEqual(@as(f32, 764), seen.w);
    try testing.expectEqual(@as(f32, 234), seen.h); // 본문 아래 끝(640)에서 잘린다
    try testing.expectEqual(@as(f32, 1), seen.u1);
    try testing.expectApproxEqAbs(@as(f32, 234.0 / 314.0), seen.v1, 1e-6);
    // 오른쪽·아래로 넘치면 넘친 만큼 UV 를 줄인다.
    const q = popupQuad(body, .{ .x = 300, .y = 250, .width = 200, .height = 134 }, 2, 400, 268).?;
    try testing.expectEqual(@as(f32, 700), q.x);
    try testing.expectEqual(@as(f32, 200), q.w);
    try testing.expectEqual(@as(f32, 0.5), q.u1);
    try testing.expectEqual(@as(f32, 100), q.h); // y 40 + 250×2 = 540 에서 본문 끝 640 까지
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 268.0), q.v1, 1e-6);
    // 왼쪽·위로 나가면(음수 DIP) 시작 UV 가 0 보다 크다.
    const left = popupQuad(body, .{ .x = -10, .y = -5, .width = 100, .height = 50 }, 1, 100, 50).?;
    try testing.expectEqual(@as(f32, 100), left.x);
    try testing.expectApproxEqAbs(@as(f32, 0.1), left.u0, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), left.v0, 1e-6);
    // 완전히 밖·빈 장·이상한 배율은 그리지 않는다.
    try testing.expect(popupQuad(body, .{ .x = 900, .y = 0, .width = 10, .height = 10 }, 1, 10, 10) == null);
    try testing.expect(popupQuad(body, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, 1, 0, 10) == null);
    try testing.expect(popupQuad(body, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, std.math.nan(f64), 10, 10) == null);
}
