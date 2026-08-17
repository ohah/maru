//! 한 제스처의 뜻을 드는 상태기계 — docs/mobile-platform.md §3.1 "한 제스처의 뜻은 상태 하나가 든다".
//!
//! **"이 손짓이 무슨 뜻인가" 를 조합으로 다시 만들지 않는다.** 전에는 표면마다
//! `active`·`moved`·`stop_tap`·`pressed` 를 따로 들고 "탭이다" 를 **`up` 인데 `moved < slop` 이고
//! `stop_tap` 이 아니고 `pressed` 가 있다** 로 자리마다 다시 만들었다. 한 자리에서 한 항을
//! 빠뜨려도 컴파일도 테스트도 통과한다 — 실제로 그 조합 하나가 톱니 판정으로 새어 설정이 안
//! 열렸고, 본문에서는 선택으로 들어갈 때 옆 변수(관성 속도)를 안 지워 떼는 순간 고른 글자가
//! 흘러갔다. 전이를 한 곳에 모으면 그런 뒷정리가 **전이의 일부**라 빠뜨릴 자리가 없다.
//!
//! **여기 없는 것**: 어느 행이 눌렸나(표면마다 뜻이 다르다), 관성(`scroll_area.Touch`),
//! 손가락 소유권(표면이 든다). 이 모듈은 **한 제스처의 단계**만 안다.

const std = @import("std");
const scroll_area = @import("scroll_area.zig");

pub const Press = struct {
    /// 슬롭·길게 누름 임계는 **스크롤 면과 같은 값을 쓴다** — 같은 손짓이 표면마다 다르게
    /// 판정되면 사용자는 이유를 모른다. 단일 출처는 `scroll_area.Touch` 다.
    pub const slop_px = scroll_area.Touch.slop_px;

    pub const State = enum {
        /// 닿은 손가락이 없다.
        idle,
        /// 짚었고 아직 슬롭 안이다 — **탭이 될 수 있다**.
        pressed,
        /// 슬롭을 넘었다 — 이 제스처는 끝까지 스크롤이다.
        scrolling,
        /// 짚은 채 시계가 지났다(본문의 선택). **`move` 로는 판정할 수 없다** — 손가락이
        /// 가만히 있으면 `move` 가 아예 안 온다(2초를 눌러도 아무 일도 안 났다, 실측).
        long_pressed,
    };

    /// 떼었을 때 이 제스처가 남긴 것.
    pub const Release = enum {
        /// 탭이다 — 누른 것을 활성화한다.
        tap,
        /// 아무 일도 없다(밀었거나·길게 눌렀거나·세우려던 짚음이었거나·취소).
        none,
    };

    state: State = .idle,
    /// **흐르는 면을 세우려고 짚었나.** 상태가 아니라 그 제스처에 붙는 표시다 — 세우고 그대로
    /// 미는 일이 있어서 `scrolling` 으로 이어질 수 있기 때문이다. 떼도 아무것도 활성화하지
    /// 않는다(세우려던 손짓이 키를 내보내거나 화면을 넘기면 안 된다).
    stop_tap: bool = false,
    down_x: f32 = 0,
    down_y: f32 = 0,
    down_ms: u64 = 0,

    /// 짚었다. `stopped_fling` 은 이 짚음이 흐르던 것을 세웠는지다(`Touch.begin` 의 반환값).
    pub fn begin(self: *Press, x: f32, y: f32, t_ms: u64, stopped_fling: bool) void {
        self.* = .{
            .state = .pressed,
            .stop_tap = stopped_fling,
            .down_x = x,
            .down_y = y,
            .down_ms = t_ms,
        };
    }

    /// 움직였다. **이번 호출에서 슬롭을 넘었으면 true** — 누름 표시를 거두는 자리가 그것이다.
    /// 이미 `scrolling`·`long_pressed` 면 다시 true 를 내지 않는다(같은 일을 두 번 하게 된다).
    pub fn move(self: *Press, x: f32, y: f32) bool {
        // **거리는 안 쌓는다.** 처음엔 최대 이동량을 필드로 들었는데, 슬롭을 넘는 순간 상태가
        // `scrolling` 으로 **래치**되므로 그 뒤의 값은 아무도 안 본다 — 갔다 돌아와도 이미
        // 스크롤인 것은 상태가 지킨다. 필드와 `@max` 를 지워도 아무 테스트가 안 깨지는 것을
        // 변이로 확인하고 걷었다(안 보는 값을 들면 다음 사람이 그것으로 판정하려 든다).
        if (self.state != .pressed) return false;
        if (@abs(x - self.down_x) + @abs(y - self.down_y) < slop_px) return false;
        self.state = .scrolling;
        return true;
    }

    /// 프레임마다 한 번. 짚은 채 `hold_ms` 가 지났으면 `long_pressed` 로 넘어가고 **true** 를
    /// 낸다(그 자리에서 선택을 잡는다). 한 제스처에 한 번만 true 다.
    ///
    /// **`move` 에서 판정하지 않는 이유**는 손가락이 가만히 있으면 `move` 가 안 오기 때문이다.
    pub fn holdPast(self: *Press, now_ms: u64, hold_ms: u64) bool {
        if (self.state != .pressed) return false;
        if (now_ms < self.down_ms or now_ms - self.down_ms < hold_ms) return false;
        self.state = .long_pressed;
        return true;
    }

    /// 뗐다. **탭은 `pressed` 에서만 나온다** — 밀었거나 길게 눌렀으면 그 손짓은 이미 뜻이 있다.
    pub fn end(self: *Press) Release {
        const tap = self.state == .pressed and !self.stop_tap;
        self.* = .{};
        return if (tap) .tap else .none;
    }

    /// 소유 손가락이 떼지고 남은 손가락이 **이어받았다.** 새 기준을 잡되 **이미 밀기로** 둔다 —
    /// 이어받은 손가락이 그 자리에서 떼는 것으로 키가 나가거나 화면이 넘어가면 안 된다
    /// (사용자는 그 손가락으로 아무것도 누른 적이 없다).
    pub fn adoptAsScroll(self: *Press, x: f32, y: f32) void {
        self.* = .{ .state = .scrolling, .down_x = x, .down_y = y };
    }

    /// 취소(제스처를 OS 가 뺏었다·화면이 바뀐다) — 아무것도 안 남긴다.
    pub fn cancel(self: *Press) void {
        self.* = .{};
    }

    /// 지금 이 표면이 제스처를 들고 있나.
    pub fn active(self: Press) bool {
        return self.state != .idle;
    }

    /// 이 제스처가 아직 탭이 될 수 있나. **누름 표시를 그릴지**가 이 값이다 — 밀기 시작한
    /// 순간 표시를 거둬야 사용자가 "눌린 채 스크롤되는" 화면을 안 본다.
    pub fn canTap(self: Press) bool {
        return self.state == .pressed and !self.stop_tap;
    }
};

test "짚었다 떼면 탭이다" {
    var p: Press = .{};
    try std.testing.expect(!p.active());
    p.begin(10, 10, 0, false);
    try std.testing.expectEqual(Press.State.pressed, p.state);
    try std.testing.expect(p.active());
    try std.testing.expect(p.canTap());
    try std.testing.expectEqual(Press.Release.tap, p.end());
    // 떼면 처음으로 돌아간다 — 다음 제스처가 앞의 값을 물려받지 않는다.
    try std.testing.expectEqual(Press.State.idle, p.state);
    try std.testing.expect(!p.active());
}

test "슬롭을 넘으면 스크롤이고 떼도 탭이 아니다" {
    var p: Press = .{};
    p.begin(10, 10, 0, false);
    // 임계 **직전**은 아직 탭이다 — 손 떨림이 탭을 죽이면 안 된다.
    try std.testing.expect(!p.move(10 + Press.slop_px - 1, 10));
    try std.testing.expect(p.canTap());
    try std.testing.expect(p.move(10 + Press.slop_px, 10));
    try std.testing.expectEqual(Press.State.scrolling, p.state);
    try std.testing.expect(!p.canTap());
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "슬롭을 넘은 것은 한 번만 알린다" {
    var p: Press = .{};
    p.begin(0, 0, 0, false);
    try std.testing.expect(p.move(100, 0));
    // **두 번째부터는 false** — 누름 표시를 거두는 일을 프레임마다 다시 하지 않는다.
    try std.testing.expect(!p.move(200, 0));
    try std.testing.expect(!p.move(300, 0));
}

test "갔다 돌아와도 스크롤이다" {
    var p: Press = .{};
    p.begin(0, 0, 0, false);
    try std.testing.expect(p.move(100, 0));
    // 제자리로 돌아온다 — `moved` 가 지금 거리라면 여기서 다시 탭이 된다.
    _ = p.move(0, 0);
    try std.testing.expectEqual(Press.State.scrolling, p.state);
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "세우려던 짚음은 떼도 아무것도 안 한다" {
    var p: Press = .{};
    p.begin(10, 10, 0, true); // 흐르던 것을 세웠다
    try std.testing.expectEqual(Press.State.pressed, p.state);
    try std.testing.expect(!p.canTap()); // 눌림 표시도 안 그린다
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "세우고 그대로 밀 수 있다" {
    var p: Press = .{};
    p.begin(10, 10, 0, true);
    // **`stop_tap` 은 상태가 아니다** — 세운 뒤 이어서 미는 것은 정상적인 손짓이다.
    try std.testing.expect(p.move(10 + Press.slop_px, 10));
    try std.testing.expectEqual(Press.State.scrolling, p.state);
}

test "짚은 채 시계가 지나면 길게 누름이고, 한 번만 알린다" {
    var p: Press = .{};
    p.begin(0, 0, 1000, false);
    try std.testing.expect(!p.holdPast(1400, 500)); // 아직 이르다
    try std.testing.expectEqual(Press.State.pressed, p.state);
    try std.testing.expect(p.holdPast(1500, 500));
    try std.testing.expectEqual(Press.State.long_pressed, p.state);
    try std.testing.expect(!p.holdPast(3000, 500)); // 두 번은 안 잡는다
    try std.testing.expectEqual(Press.Release.none, p.end()); // 길게 누른 것은 탭이 아니다
}

test "밀기 시작한 뒤에는 길게 누름이 안 잡힌다" {
    var p: Press = .{};
    p.begin(0, 0, 1000, false);
    try std.testing.expect(p.move(100, 0));
    // 스크롤 중에 손을 멈춰도 선택이 되면 안 된다 — 스크롤하다 멈추는 것은 흔한 일이다.
    try std.testing.expect(!p.holdPast(9000, 500));
    try std.testing.expectEqual(Press.State.scrolling, p.state);
}

test "시계가 거꾸로 가도 길게 누름으로 안 샌다" {
    var p: Press = .{};
    p.begin(0, 0, 1000, false);
    // host 가 주는 시각이 튈 수 있다(단조라고 계약에 적었지만 그것이 깨진 자리를 겪었다).
    try std.testing.expect(!p.holdPast(500, 500));
    try std.testing.expectEqual(Press.State.pressed, p.state);
}

test "취소는 아무것도 안 남긴다" {
    var p: Press = .{};
    p.begin(10, 10, 0, false);
    p.cancel();
    try std.testing.expectEqual(Press.State.idle, p.state);
    try std.testing.expect(!p.active());
    // 취소 뒤의 `end` 는 탭이 아니다(닿은 손가락이 없다).
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "idle 에서 온 move 는 상태를 안 만든다" {
    var p: Press = .{};
    // `down` 을 못 본 채 `move` 가 오는 일이 있다(취소 뒤 남은 손가락).
    try std.testing.expect(!p.move(100, 100));
    try std.testing.expectEqual(Press.State.idle, p.state);
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "슬롭은 스크롤 면과 같은 값이다" {
    // 같은 손짓이 표면마다 다르게 판정되면 사용자는 이유를 모른다.
    try std.testing.expectEqual(scroll_area.Touch.slop_px, Press.slop_px);
}

test "이어받은 손가락은 이미 밀기다" {
    var p: Press = .{};
    p.begin(0, 0, 0, false);
    _ = p.move(100, 0);
    // 소유자가 떠나고 다른 손가락이 그 자리를 잇는다.
    p.adoptAsScroll(300, 50);
    try std.testing.expectEqual(Press.State.scrolling, p.state);
    // 이어받은 자리에서 곧바로 떼도 아무 일이 없다.
    try std.testing.expectEqual(Press.Release.none, p.end());
}

test "이어받은 뒤의 기준은 새 손가락 자리다" {
    var p: Press = .{};
    p.begin(0, 0, 0, false);
    p.adoptAsScroll(300, 50);
    // 새 기준에서 재기 시작한다 — 옛 자리 기준이면 첫 move 가 300px 짜리 점프가 된다.
    try std.testing.expectEqual(@as(f32, 300), p.down_x);
    try std.testing.expectEqual(@as(f32, 50), p.down_y);
}
