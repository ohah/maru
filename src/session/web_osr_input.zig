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
