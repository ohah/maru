//! `TerminalRuntimeRegistry` — host 측 runtime 소유 표와 controller/observer capability state machine(§9, §4).
//!
//! 이 파일은 runtime **하나당** 누가 controller이고 누가 observer인지, 각 subscription이 어떤 capability를 갖는지,
//! resize를 언제 적용/무시하는지를 결정하는 **순수 state machine**이다. 실제 `TerminalCore`/`LivePtySession` 소유와
//! `TIOCSWINSZ`/core resize 적용은 이 결정을 받아 host server(P3-d)가 수행한다 — 그래야 state machine을 실 PTY 없이
//! non-macOS에서 TDD하고, 실 runtime 배선을 platform 경계에 가둘 수 있다(layering-and-portability.md). 그 연결점으로
//! `RuntimeEntry.runtime`(opaque `*anyopaque`) 슬롯을 두어 server가 실 runtime handle을 실어 두고 조회한다.
//!
//! 핵심 규칙(§9):
//!   - runtime당 controller 1명(`input`+`resize`) + observer N명(`observe`만). `terminate`는 attach로 암묵 부여하지
//!     않는다(별도 auth + `runtime end` 확인).
//!   - `--take-over`만 기존 controller를 revoke하고 원자적으로 이전한다. controller가 그냥 끊기면 자동 승격하지 않는다.
//!   - resize는 controller만, controller별 last `client_sequence` 이하는 재적용하지 않는다. 실제 크기가 바뀔 때만
//!     `resize_generation`을 올리고 `runtime.resized`를 broadcast한다. client가 0명이어도 마지막 검증 크기를 유지한다.

const std = @import("std");

/// runtime 하나를 가리키는 opaque 128-bit 상관키(§4). wire는 big-endian 16바이트지만 registry 내부는 비교·해시가
/// 쉬운 u128로 다룬다(server가 wire ↔ u128 변환). 의미를 비트에 인코딩하지 않고 재사용하지 않는다.
pub const RuntimeId = u128;

/// connection 안의 한 attach subscription. MRSH `stream_id`와 같은 값이다.
pub const StreamId = u64;

/// capability 비트(§9). `is_controller` boolean 하나로 굳히지 않고 비트로 표현해 향후 여러 writable stream 같은
/// 확장을 wire 변경 없이 수용한다. `terminate`는 attach가 부여하지 않는다(별도 경로).
pub const Capability = struct {
    pub const observe: u8 = 1 << 0;
    pub const input: u8 = 1 << 1;
    pub const resize: u8 = 1 << 2;
    pub const terminate: u8 = 1 << 3;

    pub fn has(caps: u8, cap: u8) bool {
        return caps & cap != 0;
    }
};

/// attach 요청 모드(§8 CLI·GUI). `controller`는 controller가 없으면 획득하고 있으면 observer로 강등된다(조용히
/// 빼앗지 않음). `takeover`만 기존 controller를 revoke하고 이전한다.
pub const AttachMode = enum { observer, controller, takeover };

/// attach 결과. `granted`는 이 subscription이 실제로 받은 capability다. `controller_busy`는 controller를 요청했으나
/// 이미 controller가 있어 observer로 강등됐음을 뜻한다(GUI가 read-only banner 표시). `revoked_controller`는 takeover가
/// 밀어낸 이전 controller stream으로, server가 그 stream에 revocation 이벤트를 보낸다.
pub const AttachOutcome = struct {
    granted: u8,
    controller_busy: bool = false,
    revoked_controller: ?StreamId = null,
};

pub const DetachOutcome = struct {
    was_controller: bool,
    was_observer: bool,
};

/// resize 요청 판정(§9). `.stale`은 controller별 last sequence 이하라 무시(다른 output/client에 관측되지 않음).
/// `.applied`는 server가 실제 `TerminalCore`+PTY에 적용해야 하며, `changed`가 true일 때만 크기가 실제로 바뀌어
/// `resize_generation`이 올라가고 `runtime.resized`를 broadcast한다.
pub const ResizeOutcome = union(enum) {
    stale,
    applied: struct {
        cols: u16,
        rows: u16,
        resize_generation: u64,
        changed: bool,
    },
};

pub const RegistryError = error{
    RuntimeNotFound,
    DuplicateRuntime,
    /// 같은 stream이 이미 이 runtime에 attach돼 있다(중복 subscription).
    AlreadyAttached,
    /// resize/input을 controller 아닌 stream이 요청했다.
    NotController,
    OutOfMemory,
};

/// grid 크기 하한(§9 `terminal.clampGridSize`와 같은 규칙). wide glyph continuation 때문에 cols>=2가 필요하고
/// rows>=1이어야 한다. 상한은 두지 않는다(u16 범위). state machine이 clamp를 소유해 controller/observer가 같은
/// canonical 크기를 본다.
pub const min_cols: u16 = 2;
pub const min_rows: u16 = 1;

fn clampCols(c: u16) u16 {
    return if (c < min_cols) min_cols else c;
}
fn clampRows(r: u16) u16 {
    return if (r < min_rows) min_rows else r;
}

/// runtime 하나의 소유·구독·크기 상태. `runtime`은 server가 실 `LivePtySession`/`TerminalCore` handle을 실어 두는
/// opaque 슬롯이다(state machine은 이 값을 해석하지 않는다).
pub const RuntimeEntry = struct {
    id: RuntimeId,
    /// 마지막으로 검증된 canonical PTY 크기. client가 0명이어도 유지된다(§9).
    cols: u16,
    rows: u16,
    resize_generation: u64 = 0,
    controller: ?StreamId = null,
    /// controller가 마지막으로 적용한 client_sequence. controller가 바뀌면(takeover/재attach) 0으로 리셋한다.
    controller_sequence: u64 = 0,
    /// 현재 controller가 resize sequence를 한 번이라도 적용했는가. `controller_sequence==0`을 "아직 없음"과 "마지막이
    /// 0"이라는 두 의미로 겹쳐 쓰지 않기 위한 명시 sentinel이다 — 그래야 seq 0을 유효한 첫 값으로 받되 seq 0 재전송은
    /// stale로 막는다. controller가 바뀌면(controller/takeover 획득) `controller_sequence`와 함께 false로 리셋한다.
    resize_seq_seen: bool = false,
    observers: std.ArrayListUnmanaged(StreamId) = .empty,
    /// server가 실 runtime handle을 실어 두는 opaque 슬롯. state machine은 미해석.
    runtime: ?*anyopaque = null,

    fn isAttached(self: *const RuntimeEntry, stream: StreamId) bool {
        if (self.controller == stream) return true;
        for (self.observers.items) |o| if (o == stream) return true;
        return false;
    }

    fn removeObserver(self: *RuntimeEntry, stream: StreamId) bool {
        for (self.observers.items, 0..) |o, i| {
            if (o == stream) {
                _ = self.observers.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

/// host의 모든 runtime을 소유하는 표. runtime_id 키드. 소유는 caller(register/unregister/deinit).
pub const TerminalRuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(RuntimeId, *RuntimeEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) TerminalRuntimeRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TerminalRuntimeRegistry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            entry_ptr.*.observers.deinit(self.allocator);
            self.allocator.destroy(entry_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// runtime을 등록한다(server가 실 spawn 후). 초기 크기는 clamp된다. 같은 id가 이미 있으면 DuplicateRuntime.
    /// 반환된 포인터는 안정 heap 슬롯이라 server가 `runtime`에 실 handle을 실을 수 있다.
    pub fn register(self: *TerminalRuntimeRegistry, id: RuntimeId, cols: u16, rows: u16) RegistryError!*RuntimeEntry {
        if (self.entries.contains(id)) return error.DuplicateRuntime;
        const entry = self.allocator.create(RuntimeEntry) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .id = id, .cols = clampCols(cols), .rows = clampRows(rows) };
        self.entries.put(self.allocator, id, entry) catch return error.OutOfMemory;
        return entry;
    }

    /// runtime을 제거한다(terminate 후). 모든 구독은 이미 detach됐다고 가정한다 — 남은 observer/controller는 버려진다.
    pub fn unregister(self: *TerminalRuntimeRegistry, id: RuntimeId) void {
        if (self.entries.fetchRemove(id)) |kv| {
            kv.value.observers.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }
    }

    pub fn get(self: *TerminalRuntimeRegistry, id: RuntimeId) ?*RuntimeEntry {
        return self.entries.get(id);
    }

    pub fn count(self: *const TerminalRuntimeRegistry) usize {
        return self.entries.count();
    }

    /// 한 subscription을 runtime에 붙인다(§8·§9). 모드별로 controller/observer capability를 결정한다.
    pub fn attach(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId, mode: AttachMode) RegistryError!AttachOutcome {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        // observer/controller는 새 subscription이라 이미 붙어 있으면 중복이다. takeover는 이미 observer로 붙어 있던
        // stream이 controller로 **승격**하는 정상 경로(GUI가 observer로 붙었다가 명시 takeover)라 이 체크를 건너뛴다.
        if (mode != .takeover and entry.isAttached(stream)) return error.AlreadyAttached;

        switch (mode) {
            .observer => {
                try appendObserver(self.allocator, entry, stream);
                return .{ .granted = Capability.observe };
            },
            .controller => {
                if (entry.controller == null) {
                    entry.controller = stream;
                    entry.controller_sequence = 0; // 새 controller — sequence 창을 새로 연다.
                    entry.resize_seq_seen = false;
                    return .{ .granted = Capability.observe | Capability.input | Capability.resize };
                }
                // 이미 controller가 있으면 조용히 빼앗지 않고 observer로 강등한다(§8).
                try appendObserver(self.allocator, entry, stream);
                return .{ .granted = Capability.observe, .controller_busy = true };
            },
            .takeover => {
                if (entry.controller == stream) {
                    // 이미 이 stream이 controller다 — takeover는 no-op(자기 자신을 revoke하지 않는다).
                    return .{ .granted = Capability.observe | Capability.input | Capability.resize };
                }
                const revoked = entry.controller;
                if (revoked) |old| {
                    // 이전 controller는 observer로 강등한다(계속 관찰). server가 old에 revocation 이벤트를 보낸다.
                    try appendObserver(self.allocator, entry, old);
                }
                _ = entry.removeObserver(stream); // 이 stream이 observer였다면 승격(observer 목록에서 제거).
                entry.controller = stream;
                entry.controller_sequence = 0;
                entry.resize_seq_seen = false;
                return .{
                    .granted = Capability.observe | Capability.input | Capability.resize,
                    .revoked_controller = revoked,
                };
            },
        }
    }

    /// subscription을 뗀다(detach/EOF/crash). controller가 끊겨도 자동 승격하지 않는다(§9). runtime은 유지된다.
    pub fn detach(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId) RegistryError!DetachOutcome {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.controller == stream) {
            entry.controller = null; // release. 자동 승격 없음.
            return .{ .was_controller = true, .was_observer = false };
        }
        const was_observer = entry.removeObserver(stream);
        return .{ .was_controller = false, .was_observer = was_observer };
    }

    /// 이 subscription의 현재 capability를 계산한다.
    pub fn capabilitiesOf(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId) u8 {
        const entry = self.entries.get(id) orelse return 0;
        if (entry.controller == stream) return Capability.observe | Capability.input | Capability.resize;
        for (entry.observers.items) |o| if (o == stream) return Capability.observe;
        return 0;
    }

    /// controller가 요청한 resize를 판정한다(§9). stale sequence는 무시하고, 새 sequence면 clamp 후 크기 변화를
    /// 계산한다. 실제 크기가 바뀌면 `resize_generation`을 올린다. **실 core/PTY 적용은 server가 이 결과로 수행**한다.
    pub fn resize(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        stream: StreamId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
    ) RegistryError!ResizeOutcome {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.controller != stream) return error.NotController;
        if (entry.resize_seq_seen and client_sequence <= entry.controller_sequence) {
            return .stale; // controller별 last sequence 이하 — 재적용하지 않는다(seq 0도 첫 적용 뒤엔 stale).
        }
        entry.resize_seq_seen = true;
        entry.controller_sequence = client_sequence;

        const new_cols = clampCols(cols);
        const new_rows = clampRows(rows);
        const changed = new_cols != entry.cols or new_rows != entry.rows;
        if (changed) {
            entry.cols = new_cols;
            entry.rows = new_rows;
            entry.resize_generation += 1;
        }
        return .{ .applied = .{ .cols = new_cols, .rows = new_rows, .resize_generation = entry.resize_generation, .changed = changed } };
    }

    fn appendObserver(allocator: std.mem.Allocator, entry: *RuntimeEntry, stream: StreamId) RegistryError!void {
        entry.observers.append(allocator, stream) catch return error.OutOfMemory;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 여러 client가 한 runtime을 관찰하되 입력·resize는 정확히
// 한 명(controller)만 해야 — 두 사람이 같은 셸에 동시에 타이핑하거나 서로 크기를 다투는 일이 없다. controller 획득/
// 강등/takeover/release, capability 부여, stale resize 무시, clamp, client 0에서 크기 유지를 순수 state machine으로
// 고정한다. 실 PTY 없이 non-macOS에서 controller 정책 회귀를 잡는다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "registry: register/get/duplicate and count" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(0xAABB, 80, 24);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.get(0xAABB) != null);
    try testing.expectError(error.DuplicateRuntime, reg.register(0xAABB, 80, 24));
    // 초기 크기 clamp: cols=0 → 2, rows=0 → 1.
    const e = try reg.register(0xCCDD, 0, 0);
    try testing.expectEqual(min_cols, e.cols);
    try testing.expectEqual(min_rows, e.rows);
}

test "registry: first controller gets input+resize, extra controller is demoted to observer" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);

    const a = try reg.attach(1, 100, .controller);
    try testing.expect(Capability.has(a.granted, Capability.input) and Capability.has(a.granted, Capability.resize));
    try testing.expect(!a.controller_busy);

    // 두 번째 controller 요청 → 조용히 빼앗지 않고 observer로 강등(controller_busy).
    const b = try reg.attach(1, 200, .controller);
    try testing.expect(b.controller_busy);
    try testing.expectEqual(@as(u8, Capability.observe), b.granted);
    try testing.expectEqual(@as(u8, Capability.observe), reg.capabilitiesOf(1, 200));
    try testing.expect(Capability.has(reg.capabilitiesOf(1, 100), Capability.input));
}

test "registry: observers only observe; terminate is never granted by attach" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const o = try reg.attach(1, 300, .observer);
    try testing.expectEqual(@as(u8, Capability.observe), o.granted);
    try testing.expect(!Capability.has(o.granted, Capability.input));
    try testing.expect(!Capability.has(o.granted, Capability.terminate));
    // 같은 stream 재attach는 거부(중복 subscription).
    try testing.expectError(error.AlreadyAttached, reg.attach(1, 300, .observer));
}

test "registry: takeover revokes old controller and transfers input+resize atomically" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    // observer였다가 takeover로 승격하는 경우도 포함해 검증.
    _ = try reg.attach(1, 200, .observer);

    const t = try reg.attach(1, 200, .takeover);
    try testing.expectEqual(@as(?StreamId, 100), t.revoked_controller);
    try testing.expect(Capability.has(t.granted, Capability.input));
    // 새 controller=200, 이전 controller 100은 observer로 강등(계속 observe).
    try testing.expect(Capability.has(reg.capabilitiesOf(1, 200), Capability.resize));
    try testing.expectEqual(@as(u8, Capability.observe), reg.capabilitiesOf(1, 100));
}

test "registry: takeover with no existing controller just acquires control" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const t = try reg.attach(1, 100, .takeover);
    try testing.expectEqual(@as(?StreamId, null), t.revoked_controller);
    try testing.expect(Capability.has(t.granted, Capability.input));
}

test "registry: controller detach releases without auto-promoting an observer" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.attach(1, 200, .observer);

    const d = try reg.detach(1, 100);
    try testing.expect(d.was_controller);
    // observer 200은 자동 승격되지 않는다 — 여전히 observe만.
    try testing.expectEqual(@as(u8, Capability.observe), reg.capabilitiesOf(1, 200));
    try testing.expectEqual(@as(u8, 0), reg.capabilitiesOf(1, 100)); // detach됨
    // observer detach.
    const d2 = try reg.detach(1, 200);
    try testing.expect(d2.was_observer and !d2.was_controller);
}

test "registry: resize applies only for controller, bumps generation only on real change" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.attach(1, 200, .observer);

    // observer는 resize 불가.
    try testing.expectError(error.NotController, reg.resize(1, 200, 100, 30, 1));

    // controller resize → applied, changed, generation 1.
    const r1 = try reg.resize(1, 100, 100, 30, 1);
    try testing.expectEqual(@as(u16, 100), r1.applied.cols);
    try testing.expect(r1.applied.changed);
    try testing.expectEqual(@as(u64, 1), r1.applied.resize_generation);

    // 같은 크기 재요청(새 sequence) → applied이지만 changed=false, generation 유지.
    const r2 = try reg.resize(1, 100, 100, 30, 2);
    try testing.expect(!r2.applied.changed);
    try testing.expectEqual(@as(u64, 1), r2.applied.resize_generation);

    // stale sequence(<= last) → 무시.
    try testing.expectEqual(ResizeOutcome.stale, try reg.resize(1, 100, 50, 10, 2));

    // clamp: cols=1 → 2, rows=0 → 1.
    const r3 = try reg.resize(1, 100, 1, 0, 3);
    try testing.expectEqual(min_cols, r3.applied.cols);
    try testing.expectEqual(min_rows, r3.applied.rows);
}

test "registry: sequence 0 is a valid first resize but a replayed 0 is stale" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);

    // client_sequence=0을 첫 resize로 쓰는 client도 정상 적용된다(0이 sentinel과 겹치지 않음).
    const r0 = try reg.resize(1, 100, 100, 30, 0);
    try testing.expect(r0.applied.changed);
    // 같은 seq=0 재전송(중복/재생)은 stale로 무시되고, 첫 적용 크기를 되돌리지 못한다.
    try testing.expectEqual(ResizeOutcome.stale, try reg.resize(1, 100, 120, 40, 0));
    const e = reg.get(1).?;
    try testing.expectEqual(@as(u16, 100), e.cols);
    try testing.expectEqual(@as(u16, 30), e.rows);
    // 다음 유효 sequence(1)는 적용된다.
    const r1 = try reg.resize(1, 100, 120, 40, 1);
    try testing.expect(r1.applied.changed);
    // takeover한 새 controller는 sequence 창이 리셋돼 다시 seq=0을 받아들인다.
    _ = try reg.attach(1, 200, .takeover);
    const r2 = try reg.resize(1, 200, 90, 20, 0);
    try testing.expect(r2.applied.changed);
}

test "registry: canonical size survives all clients detaching (client 0)" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.resize(1, 100, 132, 43, 1);
    _ = try reg.detach(1, 100); // client 0
    const e = reg.get(1).?;
    try testing.expectEqual(@as(u16, 132), e.cols);
    try testing.expectEqual(@as(u16, 43), e.rows);
    // 재attach한 새 controller는 sequence 창이 리셋돼 첫 resize가 stale로 막히지 않는다.
    _ = try reg.attach(1, 300, .controller);
    const r = try reg.resize(1, 300, 100, 30, 1);
    try testing.expect(r.applied.changed);
}

test "registry: server can stash an opaque runtime handle on the entry" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    var fake_runtime: u32 = 7;
    const e = try reg.register(1, 80, 24);
    e.runtime = &fake_runtime; // server가 실 LivePtySession/TerminalCore handle을 여기 싣는다(state machine 미해석).
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&fake_runtime)), reg.get(1).?.runtime.?);
}
