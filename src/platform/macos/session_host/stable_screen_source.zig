//! Reconnect 동안 `Surface.remote` 주소를 바꾸지 않는 stable `ScreenSource` proxy(CR2b).
//!
//! `ScreenSource`의 기존 lock/unlock API에는 borrow token을 돌려줄 자리가 없다. 따라서 proxy gate를
//! render 임계구역 전체에 보유하고 exact target을 `pinned_target`에 저장한다. writer는 먼저
//! `writer_pending`을 게시한 뒤 gate를 얻으므로, 먼저 들어온 reader만 끝나고 새 reader는 writer 뒤로 간다.

const std = @import("std");
const maru = @import("maru");

const terminal = maru.terminal;
const ScreenSource = maru.session.surface.ScreenSource;

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

pub const PublishError = error{
    Busy,
    Closed,
    InvalidOwner,
    InvalidGeneration,
    GenerationExhausted,
};

pub const LockError = error{ Closed, InvalidOwner, NestedLock };

pub const TargetKind = enum(u8) { unavailable = 1, live = 2 };

pub const Target = struct {
    source: ScreenSource,
    generation: u64,
    kind: TargetKind,
};

pub const RetiredTarget = struct {
    source: ScreenSource,
    generation: u64,
    kind: TargetKind,
};

pub const Metrics = struct {
    render_sections: u64,
    render_total_ns: u64,
    render_max_ns: u64,
    writer_waits: u64,
    writer_wait_total_ns: u64,
    writer_wait_max_ns: u64,
};

const Lifecycle = enum(u8) { ready = 1, closed = 2 };

/// 옛 generation backing을 빌리지 않는 bounded placeholder. viewport 크기의 cell만 소유하고
/// 첫 행에 고정 marker를 미리 기록한다. render 중 allocation과 old scrollback/image 참조는 없다.
pub const UnavailableCore = struct {
    allocator: std.mem.Allocator,
    size: terminal.Size,
    cells: []terminal.Cell,

    const marker = "[session unavailable]";
    const vtable = ScreenSource.VTable{
        .render_snapshot = renderSnapshot,
        .lock = lock,
        .unlock = unlock,
    };

    fn init(allocator: std.mem.Allocator, size: terminal.Size) !UnavailableCore {
        if (size.cols == 0 or size.rows == 0) return error.InvalidSize;
        const count = try std.math.mul(usize, size.cols, size.rows);
        const cells = try allocator.alloc(terminal.Cell, count);
        @memset(cells, .{});
        for (marker, 0..) |byte, index| {
            if (index >= size.cols) break;
            cells[index].codepoint = byte;
        }
        return .{ .allocator = allocator, .size = size, .cells = cells };
    }

    fn deinit(self: *UnavailableCore) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn screenSource(self: *UnavailableCore) ScreenSource {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn renderSnapshot(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *UnavailableCore = @ptrCast(@alignCast(ctx));
        return .{
            .size = self.size,
            .cursor = .{ .visible = false },
            .viewport_scrolled_known = false,
            .cells = self.cells,
        };
    }

    fn lock(_: *anyopaque, _: std.Io) void {}
    fn unlock(_: *anyopaque, _: std.Io) void {}
};

pub const StableScreenSource = struct {
    owner_addr: usize = 0,
    owner_thread_id: u64 = 0,
    io: std.Io,
    gate: std.Io.Mutex = .init,
    writer_pending: std.atomic.Value(bool) = .init(false),
    reader_thread: std.atomic.Value(usize) = .init(0),
    render_started_ns: u64 = 0,
    render_sections: std.atomic.Value(u64) = .init(0),
    render_total_ns: std.atomic.Value(u64) = .init(0),
    render_max_ns: std.atomic.Value(u64) = .init(0),
    writer_waits: std.atomic.Value(u64) = .init(0),
    writer_wait_total_ns: std.atomic.Value(u64) = .init(0),
    writer_wait_max_ns: std.atomic.Value(u64) = .init(0),
    lifecycle: Lifecycle = .ready,
    prepared_transaction_addr: usize = 0,
    prepared_transaction_generation: u64 = 0,
    prepared_expected_generation: u64 = 0,
    prepared_next_generation: u64 = 0,
    unavailable: UnavailableCore,
    current: Target,
    pinned_target: ?Target = null,

    const vtable = ScreenSource.VTable{
        .render_snapshot = renderSnapshot,
        .lock = lock,
        .unlock = unlock,
    };

    pub fn initUnavailableInPlace(
        self: *StableScreenSource,
        allocator: std.mem.Allocator,
        io: std.Io,
        size: terminal.Size,
    ) !void {
        self.* = .{
            .owner_addr = @intFromPtr(self),
            .owner_thread_id = @intCast(std.Thread.getCurrentId()),
            .io = io,
            .unavailable = try .init(allocator, size),
            .current = undefined,
        };
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = 1,
            .kind = .unavailable,
        };
    }

    pub fn initLiveInPlace(
        self: *StableScreenSource,
        allocator: std.mem.Allocator,
        io: std.Io,
        size: terminal.Size,
        live: ScreenSource,
    ) !void {
        if (sourceAliasesOwner(self, live)) return error.InvalidOwner;
        try self.initUnavailableInPlace(allocator, io, size);
        self.current = .{ .source = live, .generation = 1, .kind = .live };
    }

    pub fn deinit(self: *StableScreenSource) void {
        if (!self.validOwner() or self.lifecycle != .closed or
            self.owner_thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
            self.pinned_target != null or self.writer_pending.load(.acquire))
            @panic("stable screen proxy deinit lost closed final owner");
        self.unavailable.deinit();
        self.owner_addr = 0;
        self.* = undefined;
    }

    pub fn screenSource(self: *StableScreenSource) ScreenSource {
        if (!self.validOwner()) @panic("stable screen proxy moved or copied");
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn metrics(self: *const StableScreenSource) Metrics {
        if (!self.validOwner()) @panic("stable screen proxy moved or copied");
        return .{
            .render_sections = self.render_sections.load(.acquire),
            .render_total_ns = self.render_total_ns.load(.acquire),
            .render_max_ns = self.render_max_ns.load(.acquire),
            .writer_waits = self.writer_waits.load(.acquire),
            .writer_wait_total_ns = self.writer_wait_total_ns.load(.acquire),
            .writer_wait_max_ns = self.writer_wait_max_ns.load(.acquire),
        };
    }

    /// 새 live target을 checked-monotonic generation으로 게시하고, gate가 보장한 retired target을 돌려준다.
    /// 반환 전까지 기존 reader의 target lock/unlock이 모두 끝나므로 caller가 그 뒤 retire/reclaim할 수 있다.
    pub fn publishLive(
        self: *StableScreenSource,
        source: ScreenSource,
        generation: u64,
    ) PublishError!RetiredTarget {
        return self.publishLiveWithCommit(source, generation, {}, struct {
            fn commit(_: void) void {}
        }.commit);
    }

    /// target 교체와 generation owner의 current 교체를 같은 writer gate 안에서 게시한다.
    /// commit callback은 caller가 선행 검증을 끝낸 no-fail mutation만 수행해야 한다.
    pub fn publishLiveWithCommit(
        self: *StableScreenSource,
        source: ScreenSource,
        generation: u64,
        context: anytype,
        comptime commit: anytype,
    ) PublishError!RetiredTarget {
        if (sourceAliasesOwner(self, source)) return error.InvalidOwner;
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        try self.validateNextGeneration(generation);
        const retired = self.current;
        commit(context);
        self.current = .{ .source = source, .generation = generation, .kind = .live };
        return .{ .source = retired.source, .generation = retired.generation, .kind = retired.kind };
    }

    /// CR3c1 전용. R2a가 예약한 unavailable placeholder와 exact 같은 shell
    /// generation을 live target으로 승격한다. generation을 재발급하지 않는다.
    pub fn promoteUnavailableToLiveWithCommit(
        self: *StableScreenSource,
        source: ScreenSource,
        generation: u64,
        context: anytype,
        comptime commit: anytype,
    ) PublishError!void {
        if (sourceAliasesOwner(self, source)) return error.InvalidOwner;
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        if (self.current.kind != .unavailable or self.current.generation != generation or generation == 0)
            return error.InvalidGeneration;
        commit(context);
        self.current = .{ .source = source, .generation = generation, .kind = .live };
    }

    /// current target을 stable unavailable placeholder로 바꾼다. generation 증가가 불가능한 max 상태는
    /// authority를 재사용하지 않고 fail-close한다.
    pub fn publishUnavailable(
        self: *StableScreenSource,
        generation: u64,
    ) PublishError!RetiredTarget {
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        try self.validateNextGeneration(generation);
        const retired = self.current;
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = generation,
            .kind = .unavailable,
        };
        return .{ .source = retired.source, .generation = retired.generation, .kind = retired.kind };
    }

    /// CR3b R2a 전용 publication leaf. 기존 live target과 expected generation을 검증한 뒤
    /// caller의 선검증된 store-only suffix와 unavailable target을 같은 writer gate에서 게시한다.
    pub fn publishUnavailableFromLiveWithCommit(
        self: *StableScreenSource,
        expected_generation: u64,
        generation: u64,
        context: anytype,
        comptime commit: anytype,
    ) PublishError!RetiredTarget {
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        if (self.current.kind != .live or self.current.generation != expected_generation)
            return error.InvalidGeneration;
        try self.validateNextGeneration(generation);
        const retired = self.current;
        commit(context);
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = generation,
            .kind = .unavailable,
        };
        return .{ .source = retired.source, .generation = retired.generation, .kind = retired.kind };
    }

    /// CR5 host-wide preparation records a logical reservation while briefly holding the writer
    /// gate. It must release the gate before returning because CR5 advances one state per AppKit
    /// frame and ordinary readers must run before the later commit turn. Commit reacquires the gate
    /// and revalidates the exact live target before its no-fail publication suffix.
    pub fn prepareUnavailableFromLive(
        self: *StableScreenSource,
        expected_generation: u64,
        generation: u64,
        transaction_addr: usize,
        transaction_generation: u64,
    ) PublishError!void {
        if (transaction_addr == 0 or transaction_generation == 0 or
            self.prepared_transaction_addr != 0 or self.prepared_transaction_generation != 0 or
            self.prepared_expected_generation != 0 or self.prepared_next_generation != 0)
            return error.InvalidOwner;
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        if (self.current.kind != .live or self.current.generation != expected_generation)
            return error.InvalidGeneration;
        try self.validateNextGeneration(generation);
        self.prepared_transaction_addr = transaction_addr;
        self.prepared_transaction_generation = transaction_generation;
        self.prepared_expected_generation = expected_generation;
        self.prepared_next_generation = generation;
    }

    pub fn preparedUnavailableExact(
        self: *const StableScreenSource,
        expected_generation: u64,
        generation: u64,
        transaction_addr: usize,
        transaction_generation: u64,
    ) bool {
        return self.validOwner() and self.lifecycle == .ready and
            self.current.kind == .live and self.current.generation == expected_generation and
            self.prepared_transaction_addr == transaction_addr and
            self.prepared_transaction_generation == transaction_generation and
            self.prepared_expected_generation == expected_generation and
            self.prepared_next_generation == generation;
    }

    pub fn abortPreparedUnavailable(
        self: *StableScreenSource,
        transaction_addr: usize,
        transaction_generation: u64,
    ) PublishError!void {
        if (!self.preparedUnavailableExact(
            self.prepared_expected_generation,
            self.prepared_next_generation,
            transaction_addr,
            transaction_generation,
        )) return error.InvalidOwner;
        self.clearPreparedUnavailable();
    }

    pub fn commitPreparedUnavailableNoFail(
        self: *StableScreenSource,
        transaction_addr: usize,
        transaction_generation: u64,
    ) void {
        self.beginWriter() catch @panic("CR5b prepared screen lost writer authority before commit");
        defer self.endWriter();
        if (!self.preparedUnavailableExact(
            self.prepared_expected_generation,
            self.prepared_next_generation,
            transaction_addr,
            transaction_generation,
        )) @panic("CR5b prepared unavailable authority drifted after whole-set preflight");
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = self.prepared_next_generation,
            .kind = .unavailable,
        };
        self.clearPreparedUnavailable();
    }

    pub fn unavailableExact(self: *const StableScreenSource, generation: u64) bool {
        return self.validOwner() and self.lifecycle == .ready and
            !self.writer_pending.load(.acquire) and self.pinned_target == null and
            self.current.kind == .unavailable and self.current.generation == generation and
            self.prepared_transaction_addr == 0 and self.prepared_transaction_generation == 0 and
            self.prepared_expected_generation == 0 and self.prepared_next_generation == 0;
    }

    fn clearPreparedUnavailable(self: *StableScreenSource) void {
        self.prepared_transaction_addr = 0;
        self.prepared_transaction_generation = 0;
        self.prepared_expected_generation = 0;
        self.prepared_next_generation = 0;
    }

    /// CR3c integration leaf. The callback may report a pre-mutation Busy/authority failure while
    /// the writer gate still pins the old live target. Only a successful callback permits the
    /// unavailable target publication, so a terminal attachment is never exposed as live.
    pub fn publishUnavailableFromLiveWithFallibleCommit(
        self: *StableScreenSource,
        expected_generation: u64,
        generation: u64,
        context: anytype,
        comptime commit: anytype,
    ) PublishError!RetiredTarget {
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        if (self.current.kind != .live or self.current.generation != expected_generation)
            return error.InvalidGeneration;
        try self.validateNextGeneration(generation);
        const retired = self.current;
        const committed: PublishError!void = commit(context);
        try committed;
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = generation,
            .kind = .unavailable,
        };
        return .{ .source = retired.source, .generation = retired.generation, .kind = retired.kind };
    }

    /// shell destroy용. 새 reader를 먼저 막고 기존 borrow가 exact target unlock을 끝낸 뒤 closed를 게시한다.
    /// generation을 새로 발급하지 않으며 반환된 live target은 이 호출 뒤에만 파괴할 수 있다.
    pub fn close(self: *StableScreenSource) PublishError!?RetiredTarget {
        try self.beginWriter();
        defer self.endWriter();
        if (self.lifecycle != .ready) return error.Closed;
        const retired = self.current;
        self.current = .{
            .source = self.unavailable.screenSource(),
            .generation = retired.generation,
            .kind = .unavailable,
        };
        self.lifecycle = .closed;
        return if (retired.kind == .live)
            .{ .source = retired.source, .generation = retired.generation, .kind = retired.kind }
        else
            null;
    }

    pub fn tryLock(self: *StableScreenSource, io: std.Io) LockError!void {
        if (!self.validOwner()) return error.InvalidOwner;
        const thread_id: usize = @intCast(std.Thread.getCurrentId());
        if (self.reader_thread.load(.acquire) == thread_id) return error.NestedLock;
        while (true) {
            while (self.writer_pending.load(.acquire)) std.Thread.yield() catch {};
            self.gate.lockUncancelable(self.io);
            if (!self.writer_pending.load(.acquire)) break;
            self.gate.unlock(self.io);
            std.Thread.yield() catch {};
        }
        if (self.lifecycle != .ready) {
            self.gate.unlock(self.io);
            return error.Closed;
        }
        const target = self.current;
        self.pinned_target = target;
        target.source.vtable.lock(target.source.ctx, io);
        self.render_started_ns = nowNs(self.io);
        self.reader_thread.store(thread_id, .release);
    }

    pub fn unlockPinned(self: *StableScreenSource, io: std.Io) void {
        const thread_id: usize = @intCast(std.Thread.getCurrentId());
        if (!self.validOwner() or self.reader_thread.load(.acquire) != thread_id)
            @panic("stable screen proxy unlock without exact reader owner");
        const pinned = self.pinned_target orelse
            @panic("stable screen proxy lost pinned target");
        pinned.source.vtable.unlock(pinned.source.ctx, io);
        const elapsed = nowNs(self.io) -| self.render_started_ns;
        addSaturating(&self.render_sections, 1);
        addSaturating(&self.render_total_ns, elapsed);
        updateMax(&self.render_max_ns, elapsed);
        self.reader_thread.store(0, .release);
        self.pinned_target = null;
        self.gate.unlock(self.io);
    }

    fn beginWriter(self: *StableScreenSource) PublishError!void {
        if (!self.validOwner()) return error.InvalidOwner;
        if (self.owner_thread_id != @as(u64, @intCast(std.Thread.getCurrentId())))
            return error.InvalidOwner;
        if (self.reader_thread.load(.acquire) == @as(usize, @intCast(std.Thread.getCurrentId())))
            return error.Busy;
        if (self.writer_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return error.Busy;
        const started = nowNs(self.io);
        self.gate.lockUncancelable(self.io);
        const elapsed = nowNs(self.io) -| started;
        addSaturating(&self.writer_waits, 1);
        addSaturating(&self.writer_wait_total_ns, elapsed);
        updateMax(&self.writer_wait_max_ns, elapsed);
    }

    fn endWriter(self: *StableScreenSource) void {
        self.gate.unlock(self.io);
        self.writer_pending.store(false, .release);
    }

    fn validateNextGeneration(self: *const StableScreenSource, generation: u64) PublishError!void {
        if (self.current.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        if (generation == 0 or generation <= self.current.generation)
            return error.InvalidGeneration;
    }

    fn validOwner(self: *const StableScreenSource) bool {
        return self.owner_addr != 0 and self.owner_addr == @intFromPtr(self);
    }

    fn sourceAliasesOwner(self: *const StableScreenSource, source: ScreenSource) bool {
        const start = @intFromPtr(self);
        const end = std.math.add(usize, start, @sizeOf(StableScreenSource)) catch return true;
        const address = @intFromPtr(source.ctx);
        return address >= start and address < end;
    }

    fn renderSnapshot(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *StableScreenSource = @ptrCast(@alignCast(ctx));
        const target = self.pinned_target orelse
            @panic("stable screen snapshot requires lockCore borrow");
        return target.source.vtable.render_snapshot(target.source.ctx);
    }

    fn lock(ctx: *anyopaque, io: std.Io) void {
        const self: *StableScreenSource = @ptrCast(@alignCast(ctx));
        self.tryLock(io) catch |err| switch (err) {
            error.NestedLock => @panic("stable screen proxy nested lock"),
            error.Closed, error.InvalidOwner => @panic("stable screen proxy invalid lock owner"),
        };
    }

    fn unlock(ctx: *anyopaque, io: std.Io) void {
        const self: *StableScreenSource = @ptrCast(@alignCast(ctx));
        self.unlockPinned(io);
    }
};

fn nowNs(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    if (value <= 0) return 0;
    return @intCast(@min(value, std.math.maxInt(u64)));
}

fn updateMax(value: *std.atomic.Value(u64), candidate: u64) void {
    var observed = value.load(.acquire);
    while (candidate > observed) {
        if (value.cmpxchgWeak(observed, candidate, .acq_rel, .acquire)) |actual| {
            observed = actual;
            continue;
        }
        break;
    }
}

fn addSaturating(value: *std.atomic.Value(u64), amount: u64) void {
    var observed = value.load(.acquire);
    while (true) {
        const next = observed +| amount;
        if (value.cmpxchgWeak(observed, next, .acq_rel, .acquire)) |actual| {
            observed = actual;
            continue;
        }
        break;
    }
}

const FakeTarget = struct {
    cell: terminal.Cell,
    locks: std.atomic.Value(usize) = .init(0),
    unlocks: std.atomic.Value(usize) = .init(0),
    mutex: std.atomic.Mutex = .unlocked,

    const vtable = ScreenSource.VTable{ .render_snapshot = render, .lock = lock, .unlock = unlock };

    fn init(cp: u21) FakeTarget {
        return .{ .cell = .{ .codepoint = cp } };
    }
    fn source(self: *FakeTarget) ScreenSource {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn render(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        return .{ .size = .{ .cols = 1, .rows = 1 }, .cells = @as(*const [1]terminal.Cell, &self.cell) };
    }
    fn lock(ctx: *anyopaque, _: std.Io) void {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        lockAtomic(&self.mutex);
        _ = self.locks.fetchAdd(1, .acq_rel);
    }
    fn unlock(ctx: *anyopaque, _: std.Io) void {
        const self: *FakeTarget = @ptrCast(@alignCast(ctx));
        _ = self.unlocks.fetchAdd(1, .acq_rel);
        self.mutex.unlock();
    }
};

test "CR2b stable proxy는 bounded unavailable marker와 final source 주소를 고정한다" {
    var proxy: StableScreenSource = undefined;
    try proxy.initUnavailableInPlace(std.testing.allocator, std.testing.io, .{ .cols = 24, .rows = 2 });
    const source = proxy.screenSource();
    try proxy.tryLock(std.testing.io);
    const snapshot = source.vtable.render_snapshot(source.ctx);
    try std.testing.expectEqual(terminal.Size{ .cols = 24, .rows = 2 }, snapshot.size);
    try std.testing.expectEqualStrings(UnavailableCore.marker, blk: {
        var bytes: [UnavailableCore.marker.len]u8 = undefined;
        for (&bytes, snapshot.cells[0..UnavailableCore.marker.len]) |*out, cell| out.* = @intCast(cell.codepoint);
        break :blk &bytes;
    });
    proxy.unlockPinned(std.testing.io);
    _ = try proxy.close();
    proxy.deinit();
}

test "CR2b stable proxy는 exact pinned target을 unlock하고 publish 뒤 새 target을 읽는다" {
    var old = FakeTarget.init('A');
    var new = FakeTarget.init('B');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(std.testing.allocator, std.testing.io, .{ .cols = 2, .rows = 1 }, old.source());
    const stable = proxy.screenSource();
    try proxy.tryLock(std.testing.io);
    try std.testing.expectEqual(@as(u21, 'A'), stable.vtable.render_snapshot(stable.ctx).cells[0].codepoint);
    proxy.unlockPinned(std.testing.io);
    const retired = try proxy.publishLive(new.source(), 2);
    try std.testing.expectEqual(@as(u64, 1), retired.generation);
    try proxy.tryLock(std.testing.io);
    try std.testing.expectEqual(@as(u21, 'B'), stable.vtable.render_snapshot(stable.ctx).cells[0].codepoint);
    proxy.unlockPinned(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), old.unlocks.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), new.unlocks.load(.acquire));
    _ = try proxy.close();
    const measured = proxy.metrics();
    try std.testing.expectEqual(@as(u64, 2), measured.render_sections);
    try std.testing.expectEqual(@as(u64, 2), measured.writer_waits);
    try std.testing.expect(measured.render_total_ns >= measured.render_max_ns);
    try std.testing.expect(measured.writer_wait_total_ns >= measured.writer_wait_max_ns);
    proxy.deinit();
}

test "CR2b stable proxy는 nested reader를 lock 전에 거부한다" {
    var target = FakeTarget.init('N');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(std.testing.allocator, std.testing.io, .{ .cols = 2, .rows = 1 }, target.source());
    try proxy.tryLock(std.testing.io);
    try std.testing.expectError(error.NestedLock, proxy.tryLock(std.testing.io));
    proxy.unlockPinned(std.testing.io);
    _ = try proxy.close();
    proxy.deinit();
}

test "CR2b stable proxy는 burned generation skip을 허용하고 zero stale max ABA를 거부한다" {
    var first = FakeTarget.init('1');
    var second = FakeTarget.init('2');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(std.testing.allocator, std.testing.io, .{ .cols = 2, .rows = 1 }, first.source());
    try std.testing.expectError(error.InvalidGeneration, proxy.publishLive(second.source(), 0));
    try std.testing.expectError(error.InvalidGeneration, proxy.publishLive(second.source(), 1));
    _ = try proxy.publishLive(second.source(), 3);
    try std.testing.expectEqual(@as(u64, 3), proxy.current.generation);
    var copied = proxy;
    try std.testing.expectError(error.InvalidOwner, copied.publishLive(second.source(), 4));
    try std.testing.expectError(error.InvalidOwner, proxy.publishLive(proxy.screenSource(), 4));
    const Foreign = struct {
        proxy: *StableScreenSource,
        source: ScreenSource,
        rejected: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            if (self.proxy.publishLive(self.source, 4)) |_| {} else |err| self.rejected.store(err == error.InvalidOwner, .release);
        }
    };
    var foreign = Foreign{ .proxy = &proxy, .source = second.source() };
    const thread = try std.Thread.spawn(.{}, Foreign.run, .{&foreign});
    thread.join();
    try std.testing.expect(foreign.rejected.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), proxy.current.generation);
    proxy.current.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, proxy.publishLive(second.source(), 1));
    _ = try proxy.close();
    proxy.deinit();
}

test "CR2b stable proxy는 writer pending 뒤 새 reader를 막고 기존 borrow 다음에 publish한다" {
    var old = FakeTarget.init('A');
    var new = FakeTarget.init('B');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(std.testing.allocator, std.testing.io, .{ .cols = 2, .rows = 1 }, old.source());
    const HeldReader = struct {
        proxy: *StableScreenSource,
        acquired: std.atomic.Value(bool) = .init(false),
        proceed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.proxy.tryLock(std.testing.io) catch return;
            self.acquired.store(true, .release);
            while (!self.proceed.load(.acquire)) std.Thread.yield() catch {};
            self.proxy.unlockPinned(std.testing.io);
        }
    };
    const LateReader = struct {
        proxy: *StableScreenSource,
        start: std.atomic.Value(bool) = .init(false),
        acquired: std.atomic.Value(bool) = .init(false),
        saw: std.atomic.Value(u32) = .init(0),
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            self.proxy.tryLock(std.testing.io) catch return;
            self.acquired.store(true, .release);
            const snapshot = self.proxy.screenSource().vtable.render_snapshot(self.proxy);
            self.saw.store(snapshot.cells[0].codepoint, .release);
            self.proxy.unlockPinned(std.testing.io);
        }
    };
    const Release = struct {
        proxy: *StableScreenSource,
        held: *HeldReader,
        late: *LateReader,
        late_was_blocked: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            while (!self.proxy.writer_pending.load(.acquire)) std.Thread.yield() catch {};
            self.late.start.store(true, .release);
            var spins: usize = 0;
            while (spins < 1024) : (spins += 1) std.Thread.yield() catch {};
            self.late_was_blocked.store(!self.late.acquired.load(.acquire), .release);
            self.held.proceed.store(true, .release);
        }
    };

    var held = HeldReader{ .proxy = &proxy };
    const held_thread = try std.Thread.spawn(.{}, HeldReader.run, .{&held});
    while (!held.acquired.load(.acquire)) std.Thread.yield() catch {};
    var late = LateReader{ .proxy = &proxy };
    const late_thread = try std.Thread.spawn(.{}, LateReader.run, .{&late});
    var release = Release{ .proxy = &proxy, .held = &held, .late = &late };
    const release_thread = try std.Thread.spawn(.{}, Release.run, .{&release});

    const retired = try proxy.publishLive(new.source(), 2);
    held_thread.join();
    release_thread.join();
    late_thread.join();
    try std.testing.expectEqual(@as(u64, 1), retired.generation);
    try std.testing.expect(release.late_was_blocked.load(.acquire));
    try std.testing.expect(late.acquired.load(.acquire));
    try std.testing.expectEqual(@as(u32, 'B'), late.saw.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), old.unlocks.load(.acquire));
    _ = try proxy.close();
    proxy.deinit();
}

test "CR5b prepared unavailable 예약은 frame 사이 reader gate를 붙잡지 않는다" {
    var live = FakeTarget.init('L');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(
        std.testing.allocator,
        std.testing.io,
        .{ .cols = 2, .rows = 1 },
        live.source(),
    );
    defer {
        _ = proxy.close() catch @panic("CR5b reservation fixture cleanup lost owner");
        proxy.deinit();
    }

    try proxy.prepareUnavailableFromLive(1, 2, @intFromPtr(&proxy), 1);
    // CR5 progresses one closed-state transition per AppKit frame. Preparation must therefore
    // reserve authority without retaining the writer gate into the next frame; otherwise the
    // ordinary clipboard/render snapshot read self-deadlocks before the coordinator can commit.
    try std.testing.expect(!proxy.writer_pending.load(.acquire));
    try proxy.tryLock(std.testing.io);
    const snapshot = proxy.screenSource().vtable.render_snapshot(&proxy);
    try std.testing.expectEqual(@as(u32, 'L'), snapshot.cells[0].codepoint);
    proxy.unlockPinned(std.testing.io);
    try proxy.abortPreparedUnavailable(@intFromPtr(&proxy), 1);
}

test "CR3b R2a stable proxy reader는 tombstone callback 중간 상태를 관측하지 않는다" {
    var old = FakeTarget.init('R');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(
        std.testing.allocator,
        std.testing.io,
        .{ .cols = 24, .rows = 1 },
        old.source(),
    );
    var proxy_settled = false;
    defer if (!proxy_settled) {
        _ = proxy.close() catch @panic("R2a proxy hostile fixture cleanup lost owner");
        proxy.deinit();
    };
    const State = struct {
        proxy: *StableScreenSource,
        callback_started: std.atomic.Value(bool) = .init(false),
        tombstone_stored: std.atomic.Value(bool) = .init(false),
        reader_started: std.atomic.Value(bool) = .init(false),
        reader_acquired: std.atomic.Value(bool) = .init(false),
        reader_blocked_during_callback: std.atomic.Value(bool) = .init(false),
        observed: std.atomic.Value(u32) = .init(0),

        fn commit(self: *@This()) void {
            self.tombstone_stored.store(true, .release);
            self.callback_started.store(true, .release);
            while (!self.reader_started.load(.acquire)) std.Thread.yield() catch {};
            var spins: usize = 0;
            while (spins < 1024) : (spins += 1) std.Thread.yield() catch {};
            self.reader_blocked_during_callback.store(
                !self.reader_acquired.load(.acquire),
                .release,
            );
        }

        fn read(self: *@This()) void {
            while (!self.callback_started.load(.acquire)) std.Thread.yield() catch {};
            self.reader_started.store(true, .release);
            self.proxy.tryLock(std.testing.io) catch return;
            self.reader_acquired.store(true, .release);
            const snapshot = self.proxy.screenSource().vtable.render_snapshot(self.proxy);
            self.observed.store(snapshot.cells[0].codepoint, .release);
            self.proxy.unlockPinned(std.testing.io);
        }
    };
    var state = State{ .proxy = &proxy };
    const reader = try std.Thread.spawn(.{}, State.read, .{&state});
    var reader_joined = false;
    defer if (!reader_joined) {
        state.callback_started.store(true, .release);
        reader.join();
    };
    const retired = try proxy.publishUnavailableFromLiveWithCommit(1, 2, &state, State.commit);
    reader.join();
    reader_joined = true;
    try std.testing.expect(state.tombstone_stored.load(.acquire));
    try std.testing.expect(state.reader_blocked_during_callback.load(.acquire));
    try std.testing.expect(state.reader_acquired.load(.acquire));
    try std.testing.expectEqual(@as(u32, '['), state.observed.load(.acquire));
    try std.testing.expectEqual(TargetKind.live, retired.kind);
    try std.testing.expectEqual(@as(u64, 1), retired.generation);
    try std.testing.expect((try proxy.close()) == null);
    proxy.deinit();
    proxy_settled = true;
}

test "CR2b stable proxy는 destroy와 borrow를 직렬화하고 live target을 exact once retire한다" {
    var target = FakeTarget.init('D');
    var proxy: StableScreenSource = undefined;
    try proxy.initLiveInPlace(std.testing.allocator, std.testing.io, .{ .cols = 2, .rows = 1 }, target.source());
    const HeldReader = struct {
        proxy: *StableScreenSource,
        acquired: std.atomic.Value(bool) = .init(false),
        proceed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.proxy.tryLock(std.testing.io) catch return;
            self.acquired.store(true, .release);
            while (!self.proceed.load(.acquire)) std.Thread.yield() catch {};
            self.proxy.unlockPinned(std.testing.io);
        }
    };
    const Release = struct {
        proxy: *StableScreenSource,
        held: *HeldReader,
        fn run(self: *@This()) void {
            while (!self.proxy.writer_pending.load(.acquire)) std.Thread.yield() catch {};
            self.held.proceed.store(true, .release);
        }
    };
    var held = HeldReader{ .proxy = &proxy };
    const held_thread = try std.Thread.spawn(.{}, HeldReader.run, .{&held});
    while (!held.acquired.load(.acquire)) std.Thread.yield() catch {};
    var release = Release{ .proxy = &proxy, .held = &held };
    const release_thread = try std.Thread.spawn(.{}, Release.run, .{&release});
    const retired = (try proxy.close()) orelse return error.TestUnexpectedResult;
    held_thread.join();
    release_thread.join();
    try std.testing.expectEqual(@as(u64, 1), retired.generation);
    try std.testing.expectEqual(@as(usize, 1), target.unlocks.load(.acquire));
    try std.testing.expectError(error.Closed, proxy.tryLock(std.testing.io));
    proxy.deinit();
}
