//! 픽셀 링의 mailbox 규칙(W2, docs/plans/web-osr-backend.md C3) — 버퍼 세 장을 생산자(sidecar)·소비자(maru)가 원자
//! 워드 하나로 주고받는다. OS 를 모른다: 워드는 두 프로세스가 공유한 페이지에 있고, 이 모듈은 그 워드의 규칙만 든다.
//!
//! 세 장은 늘 back(생산자가 씀) · mailbox(대기) · front(소비자가 읽음)로 나뉜다. 생산자는 back 을 다 쓰면 mailbox 와 맞바꾸며
//! dirty 를 켜고, 소비자는 dirty 일 때만 front 와 맞바꾼다 — 그래서 **생산자가 쓰는 장을 소비자가 읽는 순간이 없다**.
//! 워드에는 세대(링을 새로 만들 때마다 오른다)도 함께 담아, 세대가 다른 맞바꾸기를 거절한다 — PoC 는 두 값을 따로 둬서
//! 크기 변경 순간 겹침이 논리적으로 가능했다(§13.1 「남은 미해결」 7).
//!
//! **워드는 믿지 않는다**: 공유 페이지라 상대가 언제든 아무 값이나 쓸 수 있다. 슬롯이 3(범위 밖)이거나 내가 쥔 장과 같으면
//! `corrupt` 로 거절하고(적대 검증 — 슬롯 3 을 쓰면 소비자가 `surfaces[3]` 을 색인했다), 상대가 워드를 계속 바꿔도
//! 맞바꾸기는 `max_attempts` 번 뒤 포기한다(렌더 스레드가 묶이지 않게).
//!
//! **GPU 소비자 규칙**: `take` 가 옛 front 를 mailbox 로 돌려주는 순간 생산자는 그 장을 다음 back 으로 가져가 쓸 수 있다.
//! 그러니 소비자는 front 를 읽는 일이 **끝난 뒤에만** 다음 `take` 를 한다 — GPU 로 그리면 그 장을 쓴 command buffer 가
//! 완료된 뒤다(W3). CPU 로 동기 읽는 판정자는 읽기가 끝난 뒤 부르므로 저절로 지킨다.

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

/// 한 번의 맞바꾸기에서 워드 경합을 다시 시도하는 상한.
pub const max_attempts = 64;

/// 워드가 가리키는 mailbox 슬롯을 쓸 수 있는가 — 세 장 안이고 내가 쥔 장이 아니어야 한다.
fn validMailbox(word: Word, mine: Slot) bool {
    return word.mailbox <= 2 and word.mailbox != mine;
}

pub const PublishError = error{
    StaleGeneration,
    /// 워드의 슬롯이 범위 밖이거나 내 back 과 같다 — 상대가 워드를 망가뜨렸다. 이 링은 버린다.
    Corrupt,
    /// 상대가 워드를 계속 바꿔 `max_attempts` 안에 못 맞바꿨다 — 이 프레임은 버린다.
    Contended,
};

/// 생산자: `back` 을 다 쓴 뒤 부른다. 돌려받은 슬롯이 다음 back 이다.
pub fn publish(control: *Control, generation: u32, back: Slot) PublishError!Slot {
    var current = control.word.load(.acquire);
    for (0..max_attempts) |_| {
        const word = Word.unpack(current);
        if (word.generation != generation) return error.StaleGeneration;
        if (!validMailbox(word, back)) return error.Corrupt;
        const next = (Word{ .generation = generation, .dirty = true, .mailbox = back }).pack();
        if (control.word.cmpxchgWeak(current, next, .acq_rel, .acquire)) |observed| {
            current = observed;
            continue;
        }
        return word.mailbox;
    }
    return error.Contended;
}

pub const Take = union(enum) {
    /// 새 프레임 — 이 슬롯이 새 front 다.
    frame: Slot,
    /// 새 프레임이 없다 — 지금 front 를 계속 보인다.
    none,
    /// 워드의 세대가 다르다 — 새 링이 왔다(소비자는 옛 front 를 계속 보이며 새 링의 첫 프레임을 기다린다).
    stale: u32,
    /// 워드의 슬롯이 범위 밖이거나 내 front 와 같다 — 이 링을 버린다(지금 front 는 계속 보여도 된다: 내 참조다).
    corrupt,
};

/// 소비자: 새 프레임이 있으면 front 와 맞바꾼다. 상대가 워드를 계속 바꾸면 `max_attempts` 번 뒤 `.none` — 다음 기회에 본다.
pub fn take(control: *Control, generation: u32, front: Slot) Take {
    var current = control.word.load(.acquire);
    for (0..max_attempts) |_| {
        const word = Word.unpack(current);
        if (word.generation != generation) return .{ .stale = word.generation };
        if (!word.dirty) return .none;
        if (!validMailbox(word, front)) return .corrupt;
        const next = (Word{ .generation = generation, .dirty = false, .mailbox = front }).pack();
        if (control.word.cmpxchgWeak(current, next, .acq_rel, .acquire)) |observed| {
            current = observed;
            continue;
        }
        return .{ .frame = word.mailbox };
    }
    return .none;
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

test "a slot outside the ring or equal to the held slot is corrupt on both sides — it is never handed out" {
    var control: Control = undefined;
    control.reset(7);
    // 상대가 슬롯 3 을 쓴다.
    control.word.store((Word{ .generation = 7, .dirty = true, .mailbox = 3 }).pack(), .release);
    try std.testing.expectEqual(Take.corrupt, take(&control, 7, initial_front));
    try std.testing.expectError(error.Corrupt, publish(&control, 7, initial_back));
    // 상대가 내가 쥔 장을 mailbox 라고 쓴다 — 받으면 두 쪽이 한 장을 함께 쥔다.
    control.word.store((Word{ .generation = 7, .dirty = true, .mailbox = initial_front }).pack(), .release);
    try std.testing.expectEqual(Take.corrupt, take(&control, 7, initial_front));
    control.word.store((Word{ .generation = 7, .dirty = false, .mailbox = initial_back }).pack(), .release);
    try std.testing.expectError(error.Corrupt, publish(&control, 7, initial_back));
    // 깨끗하지 않은(dirty 아님) 워드는 슬롯을 안 읽는다 — 새 프레임이 없을 뿐이다.
    control.word.store((Word{ .generation = 7, .dirty = false, .mailbox = 3 }).pack(), .release);
    try std.testing.expectEqual(Take.none, take(&control, 7, initial_front));
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
            .stale, .corrupt => unreachable,
        }
    }
    thread.join();
    try std.testing.expectEqual(@as(u64, 0), overlaps);
    try std.testing.expectEqual(@as(u64, 0), backwards);
    // 마지막 프레임은 반드시 소비자에게 닿는다(끝난 뒤의 take 가 가져간다).
    try std.testing.expectEqual(@as(u64, frames), last);
    try std.testing.expect(taken > 0);
}
