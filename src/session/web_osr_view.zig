//! 브라우저 하나의 「보일 링 고르기」(W3c, docs/plans/web-osr-backend.md C3) — L2 순수. W2 판정자의 `View` 를 maru 에
//! 다시 지은 것이다. 링의 IOSurface·mach 는 모른다 — 링은 세대와 제어 블록(mailbox 워드)만 본다.
//!
//! 규칙:
//! - 새 링이 와도 **그 링의 첫 프레임이 올 때까지** 옛 링의 front 를 계속 보인다(빈 장 없이 넘어간다).
//! - **GPU 소비자 규칙**: `take` 는 옛 front 를 생산자에게 돌려준다 — 그 장을 쓴 command buffer 가 끝나기 전에 부르면
//!   GPU 가 읽는 장을 sidecar 가 덮는다. 그래서 이 View 의 front 를 마지막으로 그린 프레임 세대가 완료됐을 때만 본다.
//! - 워드가 망가졌으면(`corrupt`) 그 링에서 더 꺼내지 않는다 — 지금 front 는 계속 보여도 된다(maru 가 쥔 surface 다).
//! - **기대 크기의 링에서만 꺼낸다**: 크기를 바꾸면 CEF 가 옛 크기 장에 새 레이아웃을 검은 여백과 함께 그린 전환
//!   프레임을 한 장 보낸다(W2 실측). 그래서 요청한 픽셀 크기(±1)와 다른 링의 프레임은 꺼내지 않고 마지막 좋은 장을
//!   보인다. 처음엔 「크기 변경을 보냈으면 다음 새 링까지 멈춘다」였는데, CEF 가 첫 장을 그리기 전에 크기 변경이
//!   가면 첫 링이 이미 새 크기라 다음 링이 영영 안 와 본문이 비었다(W3c 실측) — 크기를 비교하는 규칙으로 바꿨다.
//!
//! 링을 놓는 것(IOSurface·페이지 해제)은 호출자가 한다 — 이 View 가 「이제 놓아도 된다」고 돌려준 링만 놓는다. GPU 가
//! 쓰는 장을 놓지 않도록, 놓으라는 링은 모두 GPU 가 끝난 뒤(`poll` 이 돈 때)에만 나온다.

const std = @import("std");
const mailbox = @import("web_sidecar/root.zig").mailbox;

pub fn View(comptime Ring: type) type {
    return struct {
        const Self = @This();

        shown: ?Ring = null,
        front: mailbox.Slot = mailbox.initial_front,
        /// 지금 front 가 실제 프레임인가(첫 프레임 전의 initial_front 는 빈 장이다 — 그리지 않는다).
        has_frame: bool = false,
        shown_dead: bool = false,
        pending: ?Ring = null,
        pending_front: mailbox.Slot = mailbox.initial_front,
        /// 요청한 픽셀 크기(0 = 아직 없음 — 어느 링이든 꺼낸다).
        expected_width: u32 = 0,
        expected_height: u32 = 0,
        /// 이 View 의 front 를 마지막으로 그린 프레임 세대(0 = 아직 안 그렸다).
        drawn_generation: u64 = 0,

        pub const Poll = struct {
            /// 새 프레임을 front 로 삼았다 — 그 창을 다시 그린다.
            new_frame: bool = false,
            /// 이제 놓아도 되는 링(옛 링·버린 링). 최대 둘.
            retired: [2]?Ring = .{ null, null },
            /// 워드가 망가진 링을 만났다.
            corrupt: bool = false,

            fn retire(self: *Poll, ring: Ring) void {
                if (self.retired[0] == null) self.retired[0] = ring else self.retired[1] = ring;
            }
        };

        /// 새 세대 링을 받았다. 이미 기다리던 새 링이 있으면 그것은 놓는다(한 번도 그리지 않았다 — GPU 가 안 쓴다).
        pub fn adopt(self: *Self, fresh: Ring) ?Ring {
            if (self.shown == null) {
                self.shown = fresh;
                self.front = mailbox.initial_front;
                self.has_frame = false;
                self.shown_dead = false;
                return null;
            }
            const old = self.pending;
            self.pending = fresh;
            self.pending_front = mailbox.initial_front;
            return old;
        }

        /// 이 픽셀 크기로 그리라고 보냈다(생성·크기 변경). 이 크기(±1)가 아닌 링에서는 꺼내지 않는다.
        pub fn expect(self: *Self, width_px: u32, height_px: u32) void {
            self.expected_width = width_px;
            self.expected_height = height_px;
        }

        fn fitsExpected(self: *const Self, ring: *const Ring) bool {
            if (self.expected_width == 0 or self.expected_height == 0) return true;
            return near(ring.width, self.expected_width) and near(ring.height, self.expected_height);
        }

        fn near(a: u32, b: u32) bool {
            return (if (a > b) a - b else b - a) <= 1;
        }

        /// 이 프레임(세대 `generation`)이 지금 front 를 그렸다.
        pub fn drew(self: *Self, generation: u64) void {
            self.drawn_generation = generation;
        }

        /// 새 프레임이 있으면 front 로 삼는다. `completed_generation` 은 그 창에서 GPU 가 끝낸 마지막 프레임 세대다.
        pub fn poll(self: *Self, completed_generation: u64) Poll {
            var out: Poll = .{};
            // GPU 가 지금 front 를 아직 읽을 수 있다 — 아무것도 돌려주지 않는다.
            if (self.drawn_generation != 0 and completed_generation < self.drawn_generation) return out;
            if (self.pending) |*pending| if (self.fitsExpected(pending)) {
                switch (mailbox.take(pending.control, pending.generation, self.pending_front)) {
                    .frame => |slot| {
                        // 새 링의 첫 프레임 — 넘어간다. 옛 링은 GPU 가 끝났으니 놓아도 된다.
                        if (self.shown) |old| out.retire(old);
                        self.shown = pending.*;
                        self.front = slot;
                        self.has_frame = true;
                        self.shown_dead = false;
                        self.pending = null;
                        out.new_frame = true;
                        return out;
                    },
                    .corrupt => {
                        out.corrupt = true;
                        out.retire(pending.*);
                        self.pending = null;
                    },
                    .none, .stale => {},
                }
            };
            if (self.shown_dead) return out;
            const shown = if (self.shown) |*shown| shown else return out;
            if (!self.fitsExpected(shown)) return out;
            switch (mailbox.take(shown.control, shown.generation, self.front)) {
                .frame => |slot| {
                    self.front = slot;
                    self.has_frame = true;
                    out.new_frame = true;
                },
                .corrupt => {
                    out.corrupt = true;
                    self.shown_dead = true;
                },
                .none, .stale => {},
            }
            return out;
        }

        /// 브라우저가 사라졌다 — 들고 있던 링을 모두 돌려준다(호출자가 GPU 가 끝난 뒤 놓는다).
        pub fn clear(self: *Self) [2]?Ring {
            const out: [2]?Ring = .{ self.shown, self.pending };
            self.* = .{};
            return out;
        }
    };
}

// ── 시험: 가짜 링(세대 + 제어 블록)과 생산자 흉내 ────────────────────────────────────────────────────

const testing = std.testing;

const FakeRing = struct {
    generation: u32,
    control: *mailbox.Control,
    width: u32 = 100,
    height: u32 = 50,
    back: mailbox.Slot = mailbox.initial_back,

    fn publish(self: *FakeRing) void {
        self.back = mailbox.publish(self.control, self.generation, self.back) catch unreachable;
    }
};

const TestView = View(FakeRing);

test "첫 프레임 전에는 그릴 것이 없고, 발행하면 새 프레임을 front 로 삼는다" {
    var control: mailbox.Control = undefined;
    control.reset(1);
    var ring: FakeRing = .{ .generation = 1, .control = &control };
    var view: TestView = .{};
    try testing.expect(view.adopt(ring) == null);
    try testing.expect(!view.poll(0).new_frame);
    try testing.expect(!view.has_frame);
    ring.publish();
    try testing.expect(view.poll(0).new_frame);
    try testing.expect(view.has_frame);
}

test "GPU 가 지금 front 를 그린 프레임을 끝내기 전에는 꺼내지 않는다(front 를 생산자에게 돌려주지 않는다)" {
    var control: mailbox.Control = undefined;
    control.reset(1);
    var ring: FakeRing = .{ .generation = 1, .control = &control };
    var view: TestView = .{};
    _ = view.adopt(ring);
    ring.publish();
    try testing.expect(view.poll(0).new_frame);
    const held = view.front;
    view.drew(7); // 프레임 7 이 이 front 를 그렸다
    ring.publish();
    try testing.expect(!view.poll(6).new_frame); // GPU 가 6 까지만 끝냈다
    try testing.expectEqual(held, view.front);
    try testing.expect(view.poll(7).new_frame);
    try testing.expect(view.front != held);
}

test "새 링은 첫 프레임이 올 때까지 옛 front 를 보이고, 넘어갈 때 옛 링을 놓으라고 돌려준다" {
    var c1: mailbox.Control = undefined;
    c1.reset(1);
    var r1: FakeRing = .{ .generation = 1, .control = &c1 };
    var view: TestView = .{};
    _ = view.adopt(r1);
    r1.publish();
    _ = view.poll(0);
    const old_front = view.front;

    var c2: mailbox.Control = undefined;
    c2.reset(2);
    var r2: FakeRing = .{ .generation = 2, .control = &c2 };
    try testing.expect(view.adopt(r2) == null);
    // 새 링은 아직 비었다 — 옛 링이 계속 보인다.
    const quiet = view.poll(0);
    try testing.expect(!quiet.new_frame and quiet.retired[0] == null);
    try testing.expectEqual(old_front, view.front);
    try testing.expectEqual(@as(u32, 1), view.shown.?.generation);

    r2.publish();
    const switched = view.poll(0);
    try testing.expect(switched.new_frame);
    try testing.expectEqual(@as(u32, 1), switched.retired[0].?.generation);
    try testing.expectEqual(@as(u32, 2), view.shown.?.generation);
}

test "크기 변경 뒤에는 옛 크기 링의 전환 프레임을 꺼내지 않는다 — 새 크기 링의 첫 프레임까지 마지막 좋은 장" {
    var c1: mailbox.Control = undefined;
    c1.reset(1);
    var r1: FakeRing = .{ .generation = 1, .control = &c1, .width = 100, .height = 50 };
    var view: TestView = .{};
    view.expect(100, 50);
    _ = view.adopt(r1);
    r1.publish();
    try testing.expect(view.poll(0).new_frame);
    const good = view.front;
    view.expect(200, 80);
    r1.publish(); // CEF 가 옛 크기 장에 그린 전환 프레임
    try testing.expect(!view.poll(0).new_frame);
    try testing.expectEqual(good, view.front);

    var c2: mailbox.Control = undefined;
    c2.reset(2);
    var r2: FakeRing = .{ .generation = 2, .control = &c2, .width = 201, .height = 80 }; // ±1 은 같은 크기
    _ = view.adopt(r2);
    r2.publish();
    try testing.expect(view.poll(0).new_frame);
    try testing.expectEqual(@as(u32, 2), view.shown.?.generation);
}

test "CEF 가 첫 장을 그리기 전에 크기 변경이 가 첫 링이 이미 새 크기면 곧바로 꺼낸다(다음 링을 기다리지 않는다)" {
    var c1: mailbox.Control = undefined;
    c1.reset(1);
    var r1: FakeRing = .{ .generation = 1, .control = &c1, .width = 300, .height = 200 };
    var view: TestView = .{};
    view.expect(1600, 1200); // 생성 때 기본 크기
    view.expect(300, 200); // 첫 배치에서 바로 크기 변경
    _ = view.adopt(r1);
    r1.publish();
    try testing.expect(view.poll(0).new_frame);
}

test "망가진 워드: 기다리던 새 링은 버리고, 보이던 링은 더 꺼내지 않되 지금 장은 유지한다" {
    var c1: mailbox.Control = undefined;
    c1.reset(1);
    var r1: FakeRing = .{ .generation = 1, .control = &c1 };
    var view: TestView = .{};
    _ = view.adopt(r1);
    r1.publish();
    _ = view.poll(0);
    const kept = view.front;
    c1.word.store((mailbox.Word{ .generation = 1, .dirty = true, .mailbox = 3 }).pack(), .release);
    const bad = view.poll(0);
    try testing.expect(bad.corrupt and !bad.new_frame);
    try testing.expect(view.shown_dead);
    try testing.expectEqual(kept, view.front);

    var c2: mailbox.Control = undefined;
    c2.reset(2);
    const r2: FakeRing = .{ .generation = 2, .control = &c2 };
    _ = view.adopt(r2);
    c2.word.store((mailbox.Word{ .generation = 2, .dirty = true, .mailbox = mailbox.initial_front }).pack(), .release);
    const worse = view.poll(0);
    try testing.expect(worse.corrupt);
    try testing.expectEqual(@as(u32, 2), worse.retired[0].?.generation);
    try testing.expect(view.pending == null);
}

test "기다리던 새 링이 또 오면 앞의 것은 한 번도 그리지 않았으니 바로 놓는다" {
    var c1: mailbox.Control = undefined;
    c1.reset(1);
    var view: TestView = .{};
    _ = view.adopt(.{ .generation = 1, .control = &c1 });
    var c2: mailbox.Control = undefined;
    c2.reset(2);
    try testing.expect(view.adopt(.{ .generation = 2, .control = &c2 }) == null);
    var c3: mailbox.Control = undefined;
    c3.reset(3);
    try testing.expectEqual(@as(u32, 2), view.adopt(.{ .generation = 3, .control = &c3 }).?.generation);
    const left = view.clear();
    try testing.expectEqual(@as(u32, 1), left[0].?.generation);
    try testing.expectEqual(@as(u32, 3), left[1].?.generation);
}
