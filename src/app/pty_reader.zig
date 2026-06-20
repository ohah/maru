const std = @import("std");
const pty = @import("../pty.zig");
const runtime_mod = @import("runtime.zig");
const terminal = @import("../terminal.zig");
const core_command = @import("core_command.zig");

pub const QueueError = std.mem.Allocator.Error || error{
    ZeroCapacity,
    QueueClosed,
    QueueFull,
};

pub const QueuedPtyEvent = union(enum) {
    output: struct {
        pty_id: runtime_mod.PtyId,
        bytes: []u8,
    },
    exited: struct {
        pty_id: runtime_mod.PtyId,
        status: pty.ExitStatus,
    },
    read_error: struct {
        pty_id: runtime_mod.PtyId,
        message: []const u8,
    },

    pub fn deinit(self: QueuedPtyEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .output => |output| allocator.free(output.bytes),
            .exited, .read_error => {},
        }
    }

    pub fn runtimeEvent(self: QueuedPtyEvent) runtime_mod.RuntimePtyEvent {
        return switch (self) {
            .output => |output| .{ .output = .{
                .pty_id = output.pty_id,
                .bytes = output.bytes,
            } },
            .exited => |exited| .{ .exited = .{
                .pty_id = exited.pty_id,
                .status = exited.status,
            } },
            .read_error => |read_error| .{ .read_error = .{
                .pty_id = read_error.pty_id,
                .message = read_error.message,
            } },
        };
    }
};

pub const PtyEventQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    items: []QueuedPtyEvent,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, max_events: usize) QueueError!PtyEventQueue {
        if (max_events == 0) return error.ZeroCapacity;
        return .{
            .io = io,
            .allocator = allocator,
            .items = try allocator.alloc(QueuedPtyEvent, max_events),
        };
    }

    pub fn deinit(self: *PtyEventQueue) void {
        self.close();

        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const slot = (self.head + index) % self.items.len;
            self.items[slot].deinit(self.allocator);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn capacity(self: *const PtyEventQueue) usize {
        return self.items.len;
    }

    pub fn count(self: *PtyEventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len;
    }

    pub fn closedAndEmpty(self: *PtyEventQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Deadline 기반 smoke drain은 `tryPop`만으로는 "아직 output이 없음"과
        // "reader가 이미 queue를 닫음"을 구분할 수 없다. 이 관찰 API를 통해
        // 조기 close는 timeout이 아니라 lifecycle 실패로 보고하게 한다.
        return self.closed and self.len == 0;
    }

    pub fn close(self: *PtyEventQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.closed = true;
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
    }

    pub fn tryPush(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.QueueClosed;
        if (self.len == self.items.len) return error.QueueFull;
        self.pushAssumeLocked(event);
    }

    pub fn pushBlocking(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // PTY output은 버리면 안 된다. queue가 가득 차면 reader thread가 여기서
        // 기다리고, 그 결과 child stdout도 자연스럽게 느려진다. 이것이 문서화된
        // backpressure 정책이다.
        while (!self.closed and self.len == self.items.len) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.QueueClosed;
        self.pushAssumeLocked(event);
    }

    pub fn tryPop(self: *PtyEventQueue) ?QueuedPtyEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.len == 0) return null;
        return self.popAssumeLocked();
    }

    pub fn popBlocking(self: *PtyEventQueue) ?QueuedPtyEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.closed and self.len == 0) {
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        }
        if (self.len == 0) return null;
        return self.popAssumeLocked();
    }

    fn pushAssumeLocked(self: *PtyEventQueue, event: QueuedPtyEvent) void {
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = event;
        self.len += 1;
        self.not_empty.signal(self.io);
    }

    fn popAssumeLocked(self: *PtyEventQueue) QueuedPtyEvent {
        const event = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        self.not_full.signal(self.io);
        return event;
    }
};

/// PTY **입력 방향** 단일-writer 큐(docs/io-render-threading.md §8 Phase 2 — P2-1). 메인 스레드가 PTY로 보낼
/// 입력(키/paste/스크롤/질의 응답)을 `enqueueBlocking`으로 넣고, I/O 스레드(PtyReader)가 `drainChunk`로 빼
/// master에 write한다 — **유일한 writer**라 동시 write 인터리브가 없다(PtyEventQueue=출력 방향과 대칭).
/// bounded 바이트 FIFO + mutex. 포화 시 enqueue가 backpressure(셸이 입력을 안 읽으면 생산자를 늦춘다).
/// **P2-1은 primitive만 추가(미배선)** — I/O 루프 통합·라우팅은 P2-2/P2-3.
pub const PtyWriteQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    not_full: std.Io.Condition = .init,
    // FIFO 바이트: `head`부터 소비, 다 비면 clearRetainingCapacity로 head=0 리셋(재할당 없이 재사용).
    bytes: std.ArrayList(u8) = .empty,
    head: usize = 0,
    cap: usize, // 버퍼링 상한(바이트) — backpressure 기준
    closed: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, capacity_bytes: usize) QueueError!PtyWriteQueue {
        if (capacity_bytes == 0) return error.ZeroCapacity;
        return .{ .io = io, .allocator = allocator, .cap = capacity_bytes };
    }

    pub fn deinit(self: *PtyWriteQueue) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn close(self: *PtyWriteQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.not_full.broadcast(self.io); // backpressure 대기 중인 enqueue를 깨워 QueueClosed로 풀어준다
    }

    fn pendingAssumeLocked(self: *const PtyWriteQueue) usize {
        return self.bytes.items.len - self.head;
    }

    /// 메인 스레드: `data`를 큐에 복사한다. 버퍼링이 상한을 넘으면 공간이 날 때까지 backpressure로 대기한다
    /// (그동안 I/O 스레드가 drain). 닫혔으면 `error.QueueClosed`. 빈 입력은 no-op. 호출 후 호출자가 wake로
    /// I/O 스레드 poll을 깨운다(P2-2). 입력은 버리면 안 되므로 가득 차도 드롭하지 않고 대기한다(출력 backpressure 대칭).
    pub fn enqueueBlocking(self: *PtyWriteQueue, data: []const u8) QueueError!void {
        if (data.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // data가 cap보다 크면 단독으로도 상한을 넘으므로, 버퍼가 빌 때까지 기다렸다 통째로 넣는다(분할은 호출자 몫이 아님).
        while (!self.closed and self.pendingAssumeLocked() + data.len > self.cap and self.pendingAssumeLocked() > 0) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.QueueClosed;
        try self.bytes.appendSlice(self.allocator, data);
    }

    /// 메인(non-blocking): 상한을 넘지 않는 선에서 `data`의 앞부분만 넣고 넣은 길이를 반환한다(0=지금은
    /// 공간 없음). 큰 paste를 UI tick에 걸쳐 흘려보내는 경로가 쓴다 — `enqueueBlocking`과 달리 안 막히고,
    /// 못 넣은 잔량은 호출자가 다음 tick에 재시도한다(기존 per-tick paste 모델 보존). 닫혔으면 QueueClosed.
    pub fn enqueueSome(self: *PtyWriteQueue, data: []const u8) QueueError!usize {
        if (data.len == 0) return 0;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.QueueClosed;
        const room = self.cap -| self.pendingAssumeLocked(); // pending이 cap을 넘긴 직후엔 0(saturating)
        const n = @min(room, data.len);
        if (n == 0) return 0;
        try self.bytes.appendSlice(self.allocator, data[0..n]);
        return n;
    }

    pub fn hasPending(self: *PtyWriteQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pendingAssumeLocked() > 0;
    }

    /// I/O 스레드: head부터 최대 `out.len` 바이트를 `out`에 복사하고 길이를 반환한다(0=빔). 락 밖에서 그만큼 master에
    /// write한 뒤 실제 쓴 길이로 `consume`을 부른다(부분 write면 잔량은 다음 루프). 슬라이스가 아니라 복사를 돌려줘
    /// 락 밖 write 중 enqueue가 버퍼를 realloc해도 안전하다.
    pub fn drainChunk(self: *PtyWriteQueue, out: []u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(self.pendingAssumeLocked(), out.len);
        @memcpy(out[0..n], self.bytes.items[self.head .. self.head + n]);
        return n;
    }

    /// I/O 스레드: 실제로 write한 `n` 바이트만큼 head를 진행한다. 다 비면 버퍼를 비워 head=0으로 되돌리고(재사용),
    /// 공간이 생겼으니 backpressure 대기를 깨운다. head는 I/O 스레드만 움직이므로(단일 소비자) drain↔consume 사이
    /// enqueue가 tail에 append해도 안전하다.
    pub fn consume(self: *PtyWriteQueue, n: usize) void {
        if (n == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.head += n;
        if (self.head >= self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
        self.not_full.broadcast(self.io);
    }
};

/// 메인발 비-PTY 코어 mutate(IME·스크롤·선택·리포팅·config)를 I/O 스레드(reader)로 위임하는 명령
/// (docs/io-render-threading.md §9 Phase 3, (a) 단일책임). reader가 `runProcessing` write 단계에서 drain해
/// 코어 락 아래 적용한다 — 출력 `core.write`와 같은 스레드·같은 락이라 메인이 코어를 직접 mutate하지 않게 된다.
/// 가변 payload(`set_preedit` 바이트)는 큐가 owned 복사를 들고 적용·드롭·close 시 해제한다. P3-1은 프리미티브만
/// (미배선) — 배선은 P3-2~P3-4. 명령 집합은 §9.2를 따라 단계적으로 확장한다(여기선 P3-2 IME·P3-4 scroll 대표).
/// 명령 타입·적용 로직은 중립 모듈(`core_command.zig`)에 둔다 — runtime·live_pty가 순환 import 없이 공유.
pub const CoreCommand = core_command.CoreCommand;

/// 위임 명령의 bounded FIFO. `PtyWriteQueue`(바이트 FIFO)의 명령 버전 — 같은 mutex·condition·head-리셋 구조.
/// cap은 **대기 명령 수**(count) 기준. 메인이 enqueue(+wake), reader가 pop해 적용한다(단일 소비자). MARU_DEBUG면
/// enqueue/pop/close와 enqueue 시각(적용 지연 산출용)을 `coreq` 스코프로 로깅한다(기본 off, hot path 비용 분기 하나).
pub const CoreCommandQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    not_full: std.Io.Condition = .init,
    // FIFO: `head`부터 소비, 다 비면 clearRetainingCapacity로 head=0 리셋(재할당 없이 재사용) — PtyWriteQueue와 동형.
    items: std.ArrayList(Entry) = .empty,
    head: usize = 0,
    cap: usize, // 최대 대기 명령 수 — backpressure 기준
    closed: bool = false,
    debug: bool, // MARU_DEBUG(init 1회 캐시) — coreq 로깅·enqueue 타임스탬프 게이트(미설정 시 분기 하나, no-alloc)

    const coreq = std.log.scoped(.coreq);

    /// 큐가 보관하는 명령 1건 + enqueue 시각(MARU_DEBUG일 때만, 아니면 0). reader가 pop 후 `enqueued_ns`로
    /// 적용 지연을 산출한다(P3-2~). `enqueued_ns`는 `std.Io.Clock.awake` 나노초.
    pub const Entry = struct {
        cmd: CoreCommand,
        enqueued_ns: i96 = 0,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, capacity_commands: usize) QueueError!CoreCommandQueue {
        if (capacity_commands == 0) return error.ZeroCapacity;
        return .{
            .io = io,
            .allocator = allocator,
            .cap = capacity_commands,
            .debug = std.c.getenv("MARU_DEBUG") != null,
        };
    }

    pub fn deinit(self: *CoreCommandQueue) void {
        for (self.items.items[self.head..]) |entry| freeCommand(self.allocator, entry.cmd);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// 명령의 owned payload를 해제한다(payload 없는 변형은 no-op). `pop`한 호출자가 적용 후 호출한다.
    pub fn freeCommand(allocator: std.mem.Allocator, cmd: CoreCommand) void {
        switch (cmd) {
            .set_preedit => |b| allocator.free(b),
            .clear_preedit, .scroll, .scroll_to_bottom => {},
        }
    }

    fn dupeCommand(allocator: std.mem.Allocator, cmd: CoreCommand) QueueError!CoreCommand {
        return switch (cmd) {
            .set_preedit => |b| .{ .set_preedit = try allocator.dupe(u8, b) },
            .clear_preedit, .scroll, .scroll_to_bottom => cmd,
        };
    }

    fn pendingAssumeLocked(self: *const CoreCommandQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn close(self: *CoreCommandQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dropped = self.pendingAssumeLocked();
        for (self.items.items[self.head..]) |entry| freeCommand(self.allocator, entry.cmd);
        self.items.clearRetainingCapacity();
        self.head = 0;
        self.closed = true;
        if (self.debug and dropped > 0) coreq.info("close: {d} unapplied command(s) dropped", .{dropped});
        self.not_full.broadcast(self.io); // backpressure 대기 중인 enqueue를 QueueClosed로 풀어준다
    }

    /// 메인 스레드: 명령을 큐에 **복사**해 넣는다(가변 payload는 dupe — 호출자는 슬라이스 소유권 유지). 대기 명령이
    /// cap에 차면 reader가 비울 때까지 backpressure로 대기한다(UI mutate는 버리면 안 됨). 닫혔으면 QueueClosed. 호출
    /// 후 호출자가 wake로 reader poll을 깨운다(P3-2). 입력 손실 금지라 가득 차도 드롭하지 않고 대기한다(출력 backpressure 대칭).
    pub fn enqueueBlocking(self: *CoreCommandQueue, cmd: CoreCommand) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closed and self.pendingAssumeLocked() >= self.cap) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.QueueClosed;
        const owned = try dupeCommand(self.allocator, cmd);
        errdefer freeCommand(self.allocator, owned);
        const ts: i96 = if (self.debug) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
        try self.items.append(self.allocator, .{ .cmd = owned, .enqueued_ns = ts });
        if (self.debug) coreq.info("enqueue {s} (depth={d})", .{ @tagName(owned), self.pendingAssumeLocked() });
    }

    /// I/O 스레드: 다음 명령 1건을 꺼내 **소유권을 호출자에 넘긴다**(없으면 null). 호출자가 코어 락 아래 적용 후
    /// `freeCommand`로 해제한다. head는 I/O 스레드만 움직이는 단일 소비자라, pop↔적용 사이 메인 enqueue가 tail에
    /// append해도 안전하다. 다 비면 버퍼를 비워 head=0으로 되돌린다(재사용).
    pub fn pop(self: *CoreCommandQueue) ?Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pendingAssumeLocked() == 0) return null;
        const entry = self.items.items[self.head];
        self.head += 1;
        if (self.head >= self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        self.not_full.broadcast(self.io);
        if (self.debug) coreq.info("pop {s} (depth={d})", .{ @tagName(entry.cmd), self.pendingAssumeLocked() });
        return entry;
    }

    pub fn hasPending(self: *CoreCommandQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pendingAssumeLocked() > 0;
    }

    /// reader가 명령 적용 직후 호출 — MARU_DEBUG일 때만 enqueue→apply 지연(µs)을 `coreq.apply`로 찍는다(§9.7
    /// 위임 latency 관측). `Entry.enqueued_ns`는 enqueue 시점(debug일 때만 기록). 비-debug면 분기 하나로 즉시 반환.
    pub fn logApply(self: *CoreCommandQueue, entry: Entry) void {
        if (!self.debug) return;
        const apply_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const delay_us = @divTrunc(apply_ns - entry.enqueued_ns, std.time.ns_per_us);
        coreq.info("apply {s} (+{d}us)", .{ @tagName(entry.cmd), delay_us });
    }
};

pub const PtyReader = struct {
    allocator: std.mem.Allocator,
    pty_id: runtime_mod.PtyId,
    session: *pty.PtySession,
    queue: *PtyEventQueue,
    thread: ?std.Thread = null,
    // I/O–렌더 스레딩 분리(docs/io-render-threading.md PR3): processing이 켜지면 리더가 읽은 출력을
    // 직접 코어에 적용하고(락 아래) 코어가 만든 응답을 PTY로 되쓴다 — 렌더 tick에 안 묶여 즉시.
    // start() 전에 setProcessing으로 주입한다(스레드가 읽기 전에 설정돼야 race 없음). off면 기존처럼
    // 바이트만 큐에 넣는다(3b-1: 주입만, 동작 불변). 코어 write는 self.session으로 응답을 되쓴다.
    core: ?*terminal.TerminalCore = null,
    core_mutex: ?*std.Io.Mutex = null,
    io: std.Io = undefined,
    // 단일 writer(docs/io-render-threading.md §8 P2-3b): processing 경로에서 메인 입력(키/paste/스크롤)이
    // 이 큐로 들어오면 runProcessing이 같은 poll 루프에서 drain해 PTY로 write한다 — 메인은 직접 안 쓴다.
    // 옵셔널(null이면 메인 입력 drain 없이 응답만 — controlled smoke/단위 테스트 경로). start() 전 주입.
    write_queue: ?*PtyWriteQueue = null,
    // Phase 3 단일책임(docs/io-render-threading.md §9 P3-2~): 메인발 코어 mutate(IME·스크롤 등)가 이 명령 큐로
    // 들어오면 runProcessing이 같은 poll 루프에서 pop해 코어 락 아래 적용한다 — 메인은 코어를 직접 mutate 안 한다.
    // 옵셔널(null이면 위임 없음 — controlled smoke/단위 테스트는 직접 경로). setProcessing/start() 전 주입.
    command_queue: ?*CoreCommandQueue = null,
    // processing이 켜지면(setProcessing이 release-store) run()이 코어를 직접 처리한다. release-acquire로
    // core/core_mutex/io/write_queue/command_queue 주입이 reader 스레드에 보인다(설정→store, 읽기 전 load).
    processing: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        session: *pty.PtySession,
        queue: *PtyEventQueue,
    ) PtyReader {
        return .{
            .allocator = allocator,
            .pty_id = pty_id,
            .session = session,
            .queue = queue,
        };
    }

    /// 리더가 출력을 직접 코어에 적용(락 아래)하고 응답을 PTY로 되쓰도록 코어/락/io를 주입한다.
    /// **start() 전에** 호출해야 한다(스레드가 읽기 전 설정 — race 방지). docs/io-render-threading.md PR3.
    pub fn setProcessing(self: *PtyReader, core: *terminal.TerminalCore, core_mutex: *std.Io.Mutex, io: std.Io) void {
        self.core = core;
        self.core_mutex = core_mutex;
        self.io = io;
        // 이 코어가 이제 reader 스레드에 노출된다 — 락 계약(assertOwnedBySelf)을 활성화한다(디버그 전용,
        // docs/io-render-threading.md §6-5). reader 미부착 단일 스레드 경로는 armed가 아니라 면제된다.
        core.owner_dbg.arm();
        self.processing.store(true, .release); // 필드 설정 뒤 release — reader가 acquire-load로 본다
    }

    /// 단일 writer(P2-3b): 메인 입력이 흐를 write 큐를 주입한다. **setProcessing/start() 전에** 호출해야
    /// 한다(setProcessing의 release-store가 이 주입도 reader에 publish — 스레드 시작 전 설정이라 race 없음).
    /// 없으면 runProcessing은 응답만 쓰고 메인 입력은 drain하지 않는다(controlled smoke/단위 테스트).
    pub fn setWriteQueue(self: *PtyReader, write_queue: *PtyWriteQueue) void {
        self.write_queue = write_queue;
    }

    /// Phase 3(P3-2~): 메인발 코어 mutate가 흐를 명령 큐를 주입한다. **setProcessing/start() 전에** 호출해야
    /// 한다(setProcessing의 release-store가 publish — 스레드 시작 전 설정이라 race 없음). 없으면 runProcessing은
    /// 명령을 drain하지 않는다(controlled smoke/단위 테스트는 메인이 코어를 직접 mutate).
    pub fn setCommandQueue(self: *PtyReader, command_queue: *CoreCommandQueue) void {
        self.command_queue = command_queue;
    }

    pub fn start(self: *PtyReader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn join(self: *PtyReader) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn stopAndJoin(self: *PtyReader) void {
        // 앱이 탭/창을 닫을 때는 queue를 먼저 닫아 reader가 더 이상 event를
        // 쌓지 못하게 하고, session.close로 blocking read를 깨운 뒤 join한다.
        // session.deinit은 reader가 끝난 뒤 호출해야 session memory를 안전하게 파괴할 수 있다.
        self.queue.close();
        self.session.close();
        self.join();
    }

    pub fn run(self: *PtyReader) void {
        // processing은 start() 전에 setProcessing이 release-store하므로(불변식: 스레드가 읽기 전 설정)
        // run 진입 시 한 번만 acquire-load하면 충분하다 — 시작 후 뒤집히지 않는다.
        if (self.processing.load(.acquire)) {
            self.runProcessing();
            return;
        }
        // 큐-기반 경로(controlled smoke / non-interactive): readEvent가 반환한 allocator-owned
        // bytes의 소유권을 큐 event로 넘긴다(consumer가 deinit). 동작 불변.
        while (true) {
            const event = self.session.readEvent(self.allocator) catch |err| {
                // SessionClosed/NoMoreEvents는 사용자가 닫은 정상 종료다. read 실패가 아니므로
                // read_error로 surface하지 않는다. 그 밖의 에러만 consumer에게 알린다.
                if (err != error.SessionClosed and err != error.NoMoreEvents) {
                    self.pushReadError(@errorName(err));
                }
                return;
            };
            switch (event) {
                .output => |bytes| {
                    self.queue.pushBlocking(.{ .output = .{
                        .pty_id = self.pty_id,
                        .bytes = bytes,
                    } }) catch {
                        self.allocator.free(bytes); // push 실패(큐 닫힘) — 즉시 해제해 누수 방지
                        return;
                    };
                },
                .exited => |status| {
                    self.queue.pushBlocking(.{ .exited = .{
                        .pty_id = self.pty_id,
                        .status = status,
                    } }) catch return;
                    return;
                },
            }
        }
    }

    /// reader-processing 통합 I/O 루프(docs/io-render-threading.md §8 Phase 2 — P2-3a/b). 한 poll로
    /// read+write(+wake)를 인터리브한다: 출력을 직접 코어에 적용(락 아래)하고, 두 outbound 소스를
    /// **POLLOUT일 때 비차단으로** 흘려보낸다 — (1) 코어가 만든 query 응답(OSC 10/11·CPR·DA)을
    /// reader-로컬 버퍼에, (2) 메인 입력(키/paste/스크롤)을 공유 write_queue에서. write가 막혀도 read가
    /// 멈추지 않는다(기존 blocking writeInput은 자식이 stdin을 안 읽으면 read 루프를 정지시킬 수 있었다).
    /// 응답 버퍼는 ArrayList(append는 안 막힘)라 reader가 자기 응답을 적재하며 동시에 drain해도 self-write
    /// 데드락이 없다. **리더가 유일한 PTY writer**다(P2-3b — 메인은 write_queue.enqueue + signalWrite만).
    /// write_queue가 null이면(controlled smoke/단위 테스트) 응답만 쓴다.
    fn runProcessing(self: *PtyReader) void {
        const core = self.core.?;
        const mutex = self.core_mutex.?;
        // 응답 outbound 버퍼: out_buf[out_head..]가 아직 못 쓴 응답. 다 비우면 compact.
        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(self.allocator);
        var out_head: usize = 0;
        var readbuf: [4096]u8 = undefined;
        var writebuf: [512]u8 = undefined; // write_queue drain 청크(writeInputNonBlocking이 ≤512B 쓰므로)
        while (true) {
            const reply_pending = out_head < out_buf.items.len;
            const main_pending = if (self.write_queue) |wq| wq.hasPending() else false;
            const ready = self.session.waitIo(reply_pending or main_pending) catch |err| {
                if (err != error.SessionClosed and err != error.NoMoreEvents) {
                    self.pushReadError(@errorName(err));
                }
                return;
            };
            // write 단계(비차단, read 무정지): 응답을 먼저 비운다(query 응답 지연 최소화), 응답이 다 나가면
            // 메인 입력을 한 청크 drain한다. 한 iteration에 한 소스/한 청크 — 다음 poll에서 이어 비운다.
            if (ready.writable) {
                // EAGAIN(버퍼 참)은 writeInputNonBlocking이 0으로 돌려준다(에러 아님 — 다음 poll에 이어 씀).
                // catch로 잡히는 건 치명적 write 실패(EIO 등)/SessionClosed뿐 — `catch 0`로 삼키면 head가 안 늘어
                // POLLOUT 스핀(라이브락)·입력 조용한 손실이 되므로, 에러면 reader를 종료한다(read 에러 경로와 동일).
                if (out_head < out_buf.items.len) {
                    const written = self.session.writeInputNonBlocking(out_buf.items[out_head..]) catch |err| {
                        if (err != error.SessionClosed) self.pushReadError(@errorName(err));
                        return;
                    };
                    out_head += written;
                    if (out_head >= out_buf.items.len) {
                        out_buf.clearRetainingCapacity();
                        out_head = 0;
                    }
                } else if (self.write_queue) |wq| {
                    const n = wq.drainChunk(&writebuf);
                    if (n > 0) {
                        const written = self.session.writeInputNonBlocking(writebuf[0..n]) catch |err| {
                            if (err != error.SessionClosed) self.pushReadError(@errorName(err));
                            return;
                        };
                        wq.consume(written); // 실제 쓴 만큼만 head 전진(부분 write 잔량은 다음 poll)
                    }
                }
            }
            // 명령 단계(docs/io-render-threading.md §9 P3-2): 메인이 위임한 코어 mutate(IME 등)를 락 아래 적용한다.
            // PTY I/O와 무관(POLLOUT 불요) — 메인 enqueue 시 signalWrite로 깨어 여기서 비운다. 출력 core.write와
            // 같은 락·같은 스레드라 단일 mutator가 보존된다(§9.3). 응답 생성 명령(리포팅 — P3-3)은 outbound로 적재한다.
            if (self.command_queue) |cq| {
                var applied = false;
                while (cq.pop()) |entry| {
                    core.owner_dbg.lock(mutex, self.io);
                    core_command.apply(core, entry.cmd);
                    const reply = core.pendingResponse();
                    if (reply.len > 0) {
                        out_buf.appendSlice(self.allocator, reply) catch {}; // OOM이면 그 응답 드롭(best-effort)
                        core.clearResponse();
                    }
                    core.owner_dbg.unlock(mutex, self.io);
                    cq.logApply(entry); // MARU_DEBUG면 enqueue→apply 지연 로깅
                    CoreCommandQueue.freeCommand(self.allocator, entry.cmd);
                    applied = true;
                }
                // 명령이 코어를 바꿨으면 렌더 트리거(출력과 같은 빈 신호). 비블로킹(tryPush) — full이면 드롭(coalescing,
                // 교차-큐 데드락 방지, read 단계와 동일 근거).
                if (applied) self.queue.tryPush(.{ .output = .{ .pty_id = self.pty_id, .bytes = &.{} } }) catch |err| switch (err) {
                    error.QueueFull => {},
                    else => return,
                };
            }
            // read 단계: 출력을 코어에 적용하고 응답을 outbound 버퍼에 적재한다.
            if (ready.readable) {
                switch (self.session.readChunk(&readbuf) catch |err| {
                    if (err != error.SessionClosed) self.pushReadError(@errorName(err));
                    return;
                }) {
                    .again => {}, // readable/read race — 다음 poll에서 재시도
                    .data => |n| {
                        core.owner_dbg.lock(mutex, self.io);
                        core.write(readbuf[0..n]) catch {}; // best-effort(파서 OOM 등은 그 청크 드롭)
                        const reply = core.pendingResponse();
                        if (reply.len > 0) {
                            out_buf.appendSlice(self.allocator, reply) catch {}; // OOM이면 그 응답 드롭
                            core.clearResponse();
                        }
                        core.owner_dbg.unlock(mutex, self.io);
                        // 메인에 "출력 발생" 신호(빈 bytes): output_events를 올려 렌더 트리거. **비블로킹**(tryPush)으로
                        // 보낸다 — 큐가 차면 드롭한다. 근거: (1) 빈 신호라 데이터 손실 없음 — 렌더는 코어 최신 상태를
                        // 읽고, 큐에 이미 신호가 있어 catch-up 렌더가 일어난다(드롭=렌더 coalescing). (2) pushBlocking이면
                        // reader가 출력 큐 backpressure에 막혀 write_queue를 못 비우고, 그 사이 메인이 write_queue
                        // enqueueBlocking에 막히면 교차-큐 데드락(서로 상대 큐의 유일한 drainer)이 된다 — 비블로킹이 차단.
                        self.queue.tryPush(.{ .output = .{
                            .pty_id = self.pty_id,
                            .bytes = &.{},
                        } }) catch |err| switch (err) {
                            error.QueueFull => {}, // 렌더 이미 대기 중 — 드롭 OK(coalescing)
                            else => return, // QueueClosed(닫힘) 등 — reader 종료
                        };
                    },
                    .eof => {
                        const status = self.session.reapAfterEof() catch |err| {
                            if (err != error.SessionClosed) self.pushReadError(@errorName(err));
                            return;
                        };
                        if (status) |s| {
                            self.queue.pushBlocking(.{ .exited = .{
                                .pty_id = self.pty_id,
                                .status = s,
                            } }) catch return;
                        }
                        return; // EOF(또는 close 중) — 리더 종료
                    },
                }
            }
        }
    }

    fn pushReadError(self: *PtyReader, message: []const u8) void {
        self.queue.pushBlocking(.{ .read_error = .{
            .pty_id = self.pty_id,
            .message = message,
        } }) catch {};
    }
};

test "pty event queue rejects zero capacity" {
    try std.testing.expectError(
        error.ZeroCapacity,
        PtyEventQueue.init(std.testing.io, std.testing.allocator, 0),
    );
}

test "setProcessing wires core/lock and enables reader core-processing (PR3)" {
    // I/O–렌더 스레딩 분리(docs/io-render-threading.md PR3): setProcessing이 코어/락/io를 주입하고
    // processing 플래그를 켠다. 켜지면 run()이 출력을 직접 코어에 적용·응답한다(렌더 tick과 무관).
    // attachSurface가 interactive 세션에만 이걸 부른다(controlled_smoke/테스트는 false → 큐-드레인).
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var session: pty.PtySession = undefined; // run()을 시작하지 않으므로 역참조 안 됨
    var reader = PtyReader.init(allocator, 7, &session, &queue);
    try std.testing.expect(!reader.processing.load(.acquire)); // 기본 off — 큐잉 경로

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    var mutex: std.Io.Mutex = .init;
    reader.setProcessing(&core, &mutex, std.testing.io);

    try std.testing.expect(reader.processing.load(.acquire)); // 켜짐 — run()이 직접 처리
    try std.testing.expectEqual(@as(?*terminal.TerminalCore, &core), reader.core);
    try std.testing.expectEqual(@as(?*std.Io.Mutex, &mutex), reader.core_mutex);
}

test "pty event queue preserves event order and output ownership" {
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();

    const bytes = try allocator.dupe(u8, "hello");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 7, .bytes = bytes } });
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 7, .status = .{ .exited = 0 } } });

    const first = queue.popBlocking().?;
    defer first.deinit(allocator);
    try std.testing.expectEqual(runtime_mod.RuntimePtyEvent{
        .output = .{ .pty_id = 7, .bytes = bytes },
    }, first.runtimeEvent());

    const second = queue.popBlocking().?;
    defer second.deinit(allocator);
    try std.testing.expectEqual(runtime_mod.RuntimePtyEvent{
        .exited = .{ .pty_id = 7, .status = .{ .exited = 0 } },
    }, second.runtimeEvent());
}

test "pty event queue is bounded and reports full without allocating more" {
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();

    const first = try allocator.dupe(u8, "first");
    try queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = first } });

    const second = try allocator.dupe(u8, "second");
    errdefer allocator.free(second);
    try std.testing.expectError(
        error.QueueFull,
        queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = second } }),
    );
    allocator.free(second);

    const popped = queue.popBlocking().?;
    defer popped.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "pty event queue close stops new pushes and wakes empty consumers" {
    var queue = try PtyEventQueue.init(std.testing.io, std.testing.allocator, 1);
    defer queue.deinit();

    queue.close();
    try std.testing.expectError(
        error.QueueClosed,
        queue.pushBlocking(.{ .exited = .{ .pty_id = 1, .status = .{ .exited = 0 } } }),
    );
    try std.testing.expect(queue.popBlocking() == null);
}

test "PtyWriteQueue: enqueue→drainChunk→consume preserves FIFO bytes" {
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 64);
    defer q.deinit();
    try std.testing.expect(!q.hasPending());
    try q.enqueueBlocking("abc");
    try q.enqueueBlocking("def");
    try std.testing.expect(q.hasPending());
    var buf: [16]u8 = undefined;
    const n = q.drainChunk(&buf);
    try std.testing.expectEqualStrings("abcdef", buf[0..n]);
    q.consume(n);
    try std.testing.expect(!q.hasPending());
}

test "PtyWriteQueue: 작은 out으로 청크 분할 drain + 부분 consume(잔량 보존)" {
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 64);
    defer q.deinit();
    try q.enqueueBlocking("abcdef");
    var small: [3]u8 = undefined;
    const n1 = q.drainChunk(&small);
    try std.testing.expectEqual(@as(usize, 3), n1);
    try std.testing.expectEqualStrings("abc", small[0..n1]);
    q.consume(2); // 3개 봤지만 2개만 실제로 write됐다고 가정 — head는 2만 전진
    const n2 = q.drainChunk(&small);
    try std.testing.expectEqualStrings("cde", small[0..n2]); // 'c'부터 다시
    q.consume(n2);
    var rest: [16]u8 = undefined;
    const n3 = q.drainChunk(&rest);
    try std.testing.expectEqualStrings("f", rest[0..n3]);
    q.consume(n3);
    try std.testing.expect(!q.hasPending());
}

test "PtyWriteQueue: zero capacity 거부 / close 후 enqueue는 QueueClosed" {
    try std.testing.expectError(error.ZeroCapacity, PtyWriteQueue.init(std.testing.io, std.testing.allocator, 0));
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 8);
    defer q.deinit();
    q.close();
    try std.testing.expectError(error.QueueClosed, q.enqueueBlocking("x"));
}

test "PtyWriteQueue: backpressure — 상한 초과 enqueue는 소비자가 drain할 때까지 대기, 순서·전량 보존" {
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 8); // 작은 상한
    defer q.deinit();

    const total = 2000; // 상한(8)의 250배 — 생산자가 여러 번 backpressure로 막혀야 한다
    const Producer = struct {
        fn run(qq: *PtyWriteQueue, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const b = [_]u8{@as(u8, @intCast('A' + (i % 26)))};
                qq.enqueueBlocking(&b) catch return;
            }
        }
    };
    var thread = try std.Thread.spawn(.{}, Producer.run, .{ &q, total });

    // 소비자(이 스레드): 전량을 순서대로 drain. 생산자가 backpressure로 막혀도 drain이 공간을 내 진행시킨다.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    var buf: [5]u8 = undefined; // 작게 — 여러 청크로 쪼개 drain
    while (got.items.len < total) {
        const n = q.drainChunk(&buf);
        if (n == 0) continue; // 아직 생산 전 — 다시 시도(스핀, 테스트라 OK)
        try got.appendSlice(std.testing.allocator, buf[0..n]);
        q.consume(n);
    }
    thread.join();

    try std.testing.expectEqual(@as(usize, total), got.items.len);
    // 순서 보존: i번째 바이트는 'A'+(i%26)
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @intCast('A' + (i % 26))), got.items[i]);
    }
}

test "PtyWriteQueue: enqueueSome — 상한까지만 넣고 넘침은 0(안 막힘), drain 후 재개, 빈/닫힘 처리" {
    // P2-3b paste 경로: 큰 paste를 per-tick으로 흘려보낸다 — enqueueBlocking과 달리 안 막히고, 들어간 만큼만
    // 반환해 호출자가 잔량을 다음 tick에 재시도한다.
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 4); // cap 4
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 4), try q.enqueueSome("ABCDE")); // 앞 4만
    try std.testing.expectEqual(@as(usize, 0), try q.enqueueSome("FG")); // 가득 참 → 0(안 막힘)

    var buf: [2]u8 = undefined;
    const n = q.drainChunk(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("AB", buf[0..n]);
    q.consume(n); // 공간 2 생김

    try std.testing.expectEqual(@as(usize, 2), try q.enqueueSome("FGH")); // 공간 2만큼만

    try std.testing.expectEqual(@as(usize, 0), try q.enqueueSome("")); // 빈 입력은 no-op
    q.close();
    try std.testing.expectError(error.QueueClosed, q.enqueueSome("x")); // 닫힘
}

test "PtyWriteQueue: enqueueBlocking 대기 중 close → QueueClosed로 깨어남(무한 대기 없음, P2-4)" {
    // 단일 writer close-with-pending(docs/io-render-threading.md §8 P2-4): 소비자(I/O 스레드)가 멈춰 큐가 가득
    // 찬 채 생산자(메인)가 enqueueBlocking backpressure로 대기 중일 때, close가 그 대기를 QueueClosed로 풀어야
    // 한다(앱 종료/탭 close 시 메인이 영영 안 막히게). 풀리지 않으면 thread.join()이 영원히 hang → 테스트 실패(teeth).
    var q = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 4); // cap 4
    defer q.deinit();
    try q.enqueueBlocking("ABCD"); // 가득 채움(소비자 없음 → drain 안 됨)

    const Blocker = struct {
        fn run(qq: *PtyWriteQueue, out: *(QueueError!void)) void {
            out.* = qq.enqueueBlocking("E"); // 가득 참 → not_full 대기 → close가 풀어줄 때까지 막힘
        }
    };
    var result: QueueError!void = {};
    var thread = try std.Thread.spawn(.{}, Blocker.run, .{ &q, &result });
    // 생산자가 대기 상태가 되게 둔다(close가 깨우는 경로 검증). Zig 0.16 sleep은 std.Io.
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    q.close();
    thread.join();
    try std.testing.expectError(error.QueueClosed, result);
}

test "CoreCommandQueue: enqueue→pop FIFO 보존 + owned payload는 복사본(원본 변경 불가시)" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 8);
    defer q.deinit();
    try std.testing.expect(!q.hasPending());

    var src = [_]u8{ 'a', 'b', 'c' };
    try q.enqueueBlocking(.{ .set_preedit = &src });
    try q.enqueueBlocking(.{ .scroll = 5 });
    try q.enqueueBlocking(.scroll_to_bottom);
    src[0] = 'Z'; // 큐가 복사본을 들어야 한다 — enqueue 후 원본을 바꿔도 안 보여야

    try std.testing.expect(q.hasPending());

    const e1 = q.pop().?;
    try std.testing.expect(e1.cmd == .set_preedit);
    try std.testing.expectEqualStrings("abc", e1.cmd.set_preedit); // 복사본 — 'Z' 안 보임
    CoreCommandQueue.freeCommand(std.testing.allocator, e1.cmd);

    const e2 = q.pop().?;
    try std.testing.expectEqual(@as(isize, 5), e2.cmd.scroll);
    CoreCommandQueue.freeCommand(std.testing.allocator, e2.cmd);

    const e3 = q.pop().?;
    try std.testing.expect(e3.cmd == .scroll_to_bottom);
    CoreCommandQueue.freeCommand(std.testing.allocator, e3.cmd);

    try std.testing.expect(q.pop() == null);
    try std.testing.expect(!q.hasPending());
}

test "CoreCommandQueue: zero capacity 거부 / close 후 enqueue는 QueueClosed" {
    try std.testing.expectError(error.ZeroCapacity, CoreCommandQueue.init(std.testing.io, std.testing.allocator, 0));
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 4);
    defer q.deinit();
    q.close();
    try std.testing.expectError(error.QueueClosed, q.enqueueBlocking(.{ .scroll = 1 }));
}

test "CoreCommandQueue: close가 미적용 명령 폐기 + owned payload 해제(누수 0)" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 8);
    defer q.deinit();
    try q.enqueueBlocking(.{ .set_preedit = "leak-check" }); // owned 복사 — close가 풀어야 누수 0
    try q.enqueueBlocking(.{ .scroll = 3 });
    try std.testing.expect(q.hasPending());
    q.close(); // 미적용 2건 폐기 + set_preedit 복사본 free
    try std.testing.expect(!q.hasPending());
    // testing.allocator가 누수를 잡는다(close가 payload를 안 풀면 실패 — teeth).
}

test "CoreCommandQueue: backpressure 대기 중 close → QueueClosed로 깨어남(무한 대기 없음)" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 2); // cap 2
    defer q.deinit();
    try q.enqueueBlocking(.{ .scroll = 1 });
    try q.enqueueBlocking(.{ .scroll = 2 }); // 가득(소비자 없음 → drain 안 됨)

    const Blocker = struct {
        fn run(qq: *CoreCommandQueue, out: *(QueueError!void)) void {
            out.* = qq.enqueueBlocking(.{ .scroll = 3 }); // 가득 → not_full 대기 → close가 풀어줄 때까지 막힘
        }
    };
    var result: QueueError!void = {};
    var thread = try std.Thread.spawn(.{}, Blocker.run, .{ &q, &result });
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);
    q.close();
    thread.join();
    try std.testing.expectError(error.QueueClosed, result);
}

test "CoreCommandQueue: backpressure — 생산자가 막혀도 소비자 pop이 진행, scroll 순서·전량 보존" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 8); // 작은 상한
    defer q.deinit();
    const total = 2000; // 상한(8)의 250배 — 생산자가 여러 번 backpressure로 막혀야 한다
    const Producer = struct {
        fn run(qq: *CoreCommandQueue, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) qq.enqueueBlocking(.{ .scroll = @intCast(i) }) catch return;
        }
    };
    var thread = try std.Thread.spawn(.{}, Producer.run, .{ &q, total });
    var got: usize = 0;
    while (got < total) {
        const e = q.pop() orelse continue; // 아직 생산 전 — 재시도(스핀, 테스트라 OK)
        try std.testing.expectEqual(@as(isize, @intCast(got)), e.cmd.scroll); // 순서 보존
        CoreCommandQueue.freeCommand(std.testing.allocator, e.cmd);
        got += 1;
    }
    thread.join();
    try std.testing.expectEqual(@as(usize, total), got);
}
