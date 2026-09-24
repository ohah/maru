//! 픽셀 링의 mailbox 규칙(W2, docs/plans/web-osr-backend.md C3) — 버퍼 세 장을 생산자(sidecar)·소비자(maru)가 원자
//! 워드 하나로 주고받는다. OS 를 모른다: 워드는 두 프로세스가 공유한 페이지에 있고, 이 모듈은 그 워드의 규칙만 든다.
//!
//! 세 장은 늘 back(생산자가 씀) · mailbox(대기) · front(소비자가 읽음)로 나뉜다. 생산자는 back 을 다 쓰면 mailbox 와 맞바꾸며
//! dirty 를 켜고, 소비자는 dirty 일 때만 front 와 맞바꾼다 — 그래서 **생산자가 쓰는 장을 소비자가 읽는 순간이 없다**.
//! 워드에는 세대(링을 새로 만들 때마다 오른다)도 함께 담아, 세대가 다른 맞바꾸기를 거절한다 — PoC 는 두 값을 따로 둬서
//! 크기 변경 순간 겹침이 논리적으로 가능했다(§13.1 「남은 미해결」 7).

const std = @import("std");

pub const Slot = u2;

/// 워드 배치: [63:32] 세대 · [2] dirty · [1:0] mailbox 슬롯.
pub const Word = struct {
    generation: u32,
    dirty: bool,
    mailbox: Slot,

    pub fn pack(self: Word) u64 {
        return (@as(u64, self.generation) << 32) | (@as(u64, @intFromBool(self.dirty)) << 2) | self.mailbox;
    }

    pub fn unpack(raw: u64) Word {
        return .{ .generation = @truncate(raw >> 32), .dirty = (raw >> 2) & 1 == 1, .mailbox = @truncate(raw & 3) };
    }
};

/// 공유 페이지 맨 앞에 두는 제어 블록. 두 프로세스가 같은 배치를 보도록 extern 이다.
pub const Control = extern struct {
    word: std.atomic.Value(u64),

    /// 새 링: mailbox 는 1, 생산자 back 은 0, 소비자 front 는 2 에서 시작한다.
    pub fn reset(self: *Control, generation: u32) void {
        self.word.store((Word{ .generation = generation, .dirty = false, .mailbox = 1 }).pack(), .release);
    }
};

pub const initial_back: Slot = 0;
pub const initial_front: Slot = 2;

pub const PublishError = error{StaleGeneration};

/// 생산자: `back` 을 다 쓴 뒤 부른다. 돌려받은 슬롯이 다음 back 이다.
pub fn publish(control: *Control, generation: u32, back: Slot) PublishError!Slot {
    var current = control.word.load(.acquire);
    while (true) {
        const word = Word.unpack(current);
        if (word.generation != generation) return error.StaleGeneration;
        const next = (Word{ .generation = generation, .dirty = true, .mailbox = back }).pack();
        if (control.word.cmpxchgWeak(current, next, .acq_rel, .acquire)) |observed| {
            current = observed;
            continue;
        }
        return word.mailbox;
    }
}

pub const Take = union(enum) {
    /// 새 프레임 — 이 슬롯이 새 front 다.
    frame: Slot,
    /// 새 프레임이 없다 — 지금 front 를 계속 보인다.
    none,
    /// 워드의 세대가 다르다 — 새 링이 왔다(소비자는 옛 front 를 계속 보이며 새 링의 첫 프레임을 기다린다).
    stale: u32,
};

/// 소비자: 새 프레임이 있으면 front 와 맞바꾼다.
pub fn take(control: *Control, generation: u32, front: Slot) Take {
    var current = control.word.load(.acquire);
    while (true) {
        const word = Word.unpack(current);
        if (word.generation != generation) return .{ .stale = word.generation };
        if (!word.dirty) return .none;
        const next = (Word{ .generation = generation, .dirty = false, .mailbox = front }).pack();
        if (control.word.cmpxchgWeak(current, next, .acq_rel, .acquire)) |observed| {
            current = observed;
            continue;
        }
        return .{ .frame = word.mailbox };
    }
}

test "word packs generation, dirty and slot without overlap" {
    const word: Word = .{ .generation = 0xDEADBEEF, .dirty = true, .mailbox = 2 };
    try std.testing.expectEqual(word, Word.unpack(word.pack()));
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF_00000006), word.pack());
}

test "publish then take hands the written slot to the consumer and keeps three distinct slots" {
    var control: Control = undefined;
    control.reset(1);
    var back: Slot = initial_back;
    var front: Slot = initial_front;
    try std.testing.expectEqual(Take.none, take(&control, 1, front));

    const written = back;
    back = try publish(&control, 1, back);
    const got = take(&control, 1, front);
    try std.testing.expectEqual(Take{ .frame = written }, got);
    front = got.frame;
    const mailbox = Word.unpack(control.word.load(.acquire)).mailbox;
    try std.testing.expect(back != front and back != mailbox and front != mailbox);
    try std.testing.expectEqual(Take.none, take(&control, 1, front));
}

test "a newer publish replaces an untaken frame — the consumer sees only the latest" {
    var control: Control = undefined;
    control.reset(3);
    var back: Slot = initial_back;
    const first = back;
    back = try publish(&control, 3, back);
    const second = back;
    back = try publish(&control, 3, back);
    // 첫 장은 다시 생산자 몫이 됐다(덮어써도 소비자가 안 읽는다).
    try std.testing.expectEqual(first, back);
    try std.testing.expectEqual(Take{ .frame = second }, take(&control, 3, initial_front));
}

test "a different generation is refused on both sides" {
    var control: Control = undefined;
    control.reset(5);
    try std.testing.expectError(error.StaleGeneration, publish(&control, 4, initial_back));
    control.reset(6);
    try std.testing.expectEqual(Take{ .stale = 6 }, take(&control, 5, initial_front));
}

const Shared = struct {
    control: Control = undefined,
    /// 슬롯마다 「지금 쓰는 중」 표시와 쓴 프레임 번호.
    writing: [3]std.atomic.Value(bool) = .{ .init(false), .init(false), .init(false) },
    stamp: [3]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0) },
    done: std.atomic.Value(bool) = .init(false),
};

fn producer(shared: *Shared, frames: u64) void {
    var back: Slot = initial_back;
    var n: u64 = 1;
    while (n <= frames) : (n += 1) {
        shared.writing[back].store(true, .release);
        shared.stamp[back].store(n, .release);
        std.atomic.spinLoopHint();
        shared.writing[back].store(false, .release);
        back = publish(&shared.control, 1, back) catch unreachable;
    }
    shared.done.store(true, .release);
}

test "a real producer thread never writes the slot the consumer holds, and frames only move forward" {
    var shared: Shared = .{};
    shared.control.reset(1);
    const frames = 200_000;
    const thread = try std.Thread.spawn(.{}, producer, .{ &shared, frames });
    var front: Slot = initial_front;
    var last: u64 = 0;
    var taken: u64 = 0;
    var overlaps: u64 = 0;
    var backwards: u64 = 0;
    while (true) {
        const finished = shared.done.load(.acquire);
        switch (take(&shared.control, 1, front)) {
            .frame => |slot| {
                front = slot;
                taken += 1;
                if (shared.writing[front].load(.acquire)) overlaps += 1;
                const stamp = shared.stamp[front].load(.acquire);
                if (stamp <= last) backwards += 1;
                last = stamp;
                // 소비자가 front 를 쥐고 있는 동안 생산자가 이 장을 쓰기 시작하면 안 된다.
                if (shared.writing[front].load(.acquire)) overlaps += 1;
            },
            .none => if (finished) break,
            .stale => unreachable,
        }
    }
    thread.join();
    try std.testing.expectEqual(@as(u64, 0), overlaps);
    try std.testing.expectEqual(@as(u64, 0), backwards);
    // 마지막 프레임은 반드시 소비자에게 닿는다(끝난 뒤의 take 가 가져간다).
    try std.testing.expectEqual(@as(u64, frames), last);
    try std.testing.expect(taken > 0);
}
