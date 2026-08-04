//! Continuous drag의 tick coalescing — CIM2.
//!
//! divider·사이드바 폭·dock 경계는 매 pointer move마다 geometry를 다시 계산하고 PTY resize를
//! 팬아웃한다. move 이벤트는 tick보다 훨씬 자주 오므로 그것을 그대로 흘리면 한 프레임 안에서
//! 같은 일을 여러 번 한다. 이관 계약 §4.3은 그 상한을 **move 이벤트 수가 아니라 tick 수와 실제
//! geometry 변화**로 못 박는다.
//!
//! 이 모듈이 그 둘을 각각 담당한다.
//!
//!   - `absorb`는 좌표를 덮어쓰기만 한다. tick 사이에 move가 몇 번 오든 남는 것은 마지막 하나다.
//!   - `commitIfChanged`는 clamp를 **통과한 뒤의 값**을 받아 이전과 같으면 false를 낸다. 경계에
//!     닿은 채 계속 미는 동안 effect가 반복되지 않는 이유가 이것이다.
//!
//! clamp 자체는 여기 없다. 한계값은 domain 상수(pane 최소 비율, 사이드바 min/max pt)라서 host가
//! 소유하고, 이 모듈은 그 결과가 **달라졌는지만** 본다.

const std = @import("std");

pub const Point = struct { x_px: f64, y_px: f64 };

/// `Applied`는 clamp를 통과한 최종 domain 값의 타입이다(pane divider는 비율 `f32`, 사이드바 폭은
/// `u32`). 그 값의 동등성만 쓰므로 `==`로 비교 가능한 타입이어야 한다.
pub fn Coalescer(comptime Applied: type) type {
    return struct {
        const Self = @This();

        /// 아직 tick이 가져가지 않은 마지막 좌표.
        pending: ?Point = null,
        /// 마지막으로 실제 effect를 낸 값. `null`은 이번 drag에서 아직 아무것도 적용하지 않았다는 뜻.
        applied: ?Applied = null,

        /// move 하나를 흡수한다. 비유한 좌표는 버린다 — 좌표가 깨진 채로 tick까지 살아남으면
        /// 그 프레임의 geometry가 통째로 무의미해진다.
        pub fn absorb(self: *Self, x_px: f64, y_px: f64) void {
            if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return;
            self.pending = .{ .x_px = x_px, .y_px = y_px };
        }

        /// tick이 부르는 소비 함수. 남아 있던 최종 좌표 하나를 내주고 비운다.
        pub fn take(self: *Self) ?Point {
            const value = self.pending;
            self.pending = null;
            return value;
        }

        /// clamp를 통과한 값이 직전에 적용한 것과 다를 때만 true. 같으면 host는 effect를 건너뛴다.
        pub fn commitIfChanged(self: *Self, value: Applied) bool {
            if (self.applied) |previous| {
                if (previous == value) return false;
            }
            self.applied = value;
            return true;
        }

        /// drag가 끝났거나(up) 취소됐을 때. 다음 drag는 자기 첫 좌표를 반드시 적용해야 하므로
        /// `applied`까지 함께 비운다 — 남겨두면 새 drag의 첫 move가 "안 바뀌었다"로 먹힌다.
        pub fn reset(self: *Self) void {
            self.pending = null;
            self.applied = null;
        }
    };
}

const RatioCoalescer = Coalescer(f32);

test "several moves inside one tick collapse to the last coordinate" {
    var coalescer = RatioCoalescer{};
    try std.testing.expect(coalescer.take() == null);

    coalescer.absorb(10, 20);
    coalescer.absorb(11, 21);
    coalescer.absorb(12, 22);

    // tick 하나가 가져가는 것은 마지막 하나다. 상한이 move 수가 아니라 tick 수인 이유.
    const taken = coalescer.take().?;
    try std.testing.expectEqual(@as(f64, 12), taken.x_px);
    try std.testing.expectEqual(@as(f64, 22), taken.y_px);

    // 소비하면 비어 있다 — 같은 좌표를 다음 tick이 다시 적용하지 않는다.
    try std.testing.expect(coalescer.take() == null);
}

test "a broken coordinate never survives to the tick" {
    var coalescer = RatioCoalescer{};
    coalescer.absorb(5, 5);
    coalescer.absorb(std.math.nan(f64), 6);
    coalescer.absorb(7, std.math.inf(f64));

    // 마지막 유효 좌표가 남는다. 깨진 값이 덮어썼다면 그 프레임 geometry가 통째로 무의미해진다.
    const taken = coalescer.take().?;
    try std.testing.expectEqual(@as(f64, 5), taken.x_px);
}

test "a clamped value that did not change produces no effect" {
    var coalescer = RatioCoalescer{};

    // 첫 값은 언제나 적용된다.
    try std.testing.expect(coalescer.commitIfChanged(0.5));
    // 경계에 닿은 채 계속 미는 동안 clamp 결과가 같으면 effect가 반복되지 않는다.
    try std.testing.expect(!coalescer.commitIfChanged(0.5));
    try std.testing.expect(!coalescer.commitIfChanged(0.5));
    try std.testing.expect(coalescer.commitIfChanged(0.6));
    try std.testing.expect(!coalescer.commitIfChanged(0.6));
}

test "a finished drag does not make the next one skip its first move" {
    var coalescer = RatioCoalescer{};
    try std.testing.expect(coalescer.commitIfChanged(0.5));
    coalescer.absorb(9, 9);

    coalescer.reset();

    // 남은 좌표가 다음 drag로 새지 않는다.
    try std.testing.expect(coalescer.take() == null);
    // 그리고 같은 값으로 다시 시작해도 첫 적용은 일어난다 — `applied`를 남겨두면 여기서 먹힌다.
    try std.testing.expect(coalescer.commitIfChanged(0.5));
}
