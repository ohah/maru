const std = @import("std");
const pty = @import("../pty.zig");
const runtime_mod = @import("runtime.zig");
const terminal = @import("../terminal.zig");

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
    // processing이 켜지면(setProcessing이 release-store) run()이 코어를 직접 처리한다. release-acquire로
    // core/core_mutex/io 주입이 reader 스레드에 보인다(설정→store, 읽기 전 load).
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
        self.processing.store(true, .release); // 필드 설정 뒤 release — reader가 acquire-load로 본다
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

    /// reader-processing 통합 I/O 루프(docs/io-render-threading.md §8 Phase 2 — P2-3a). 한 poll로
    /// read+write(+wake)를 인터리브한다: 출력을 직접 코어에 적용(락 아래)하고 코어가 만든 query
    /// 응답(OSC 10/11·CPR·DA)을 reader-로컬 버퍼에 쌓아 **POLLOUT일 때 비차단으로** 흘려보낸다 —
    /// 응답 write가 막혀도 read가 멈추지 않는다(기존 blocking writeInput은 자식이 stdin을 안 읽으면
    /// read 루프를 정지시킬 수 있었다). 응답 버퍼는 ArrayList(append는 안 막힘)라 self-write
    /// 데드락이 없다. 메인 입력은 아직 직접 경로다(단일 writer는 P2-3b).
    fn runProcessing(self: *PtyReader) void {
        const core = self.core.?;
        const mutex = self.core_mutex.?;
        // 응답 outbound 버퍼: out_buf[out_head..]가 아직 못 쓴 응답. 다 비우면 compact.
        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(self.allocator);
        var out_head: usize = 0;
        var readbuf: [4096]u8 = undefined;
        while (true) {
            const want_write = out_head < out_buf.items.len;
            const ready = self.session.waitIo(want_write) catch |err| {
                if (err != error.SessionClosed and err != error.NoMoreEvents) {
                    self.pushReadError(@errorName(err));
                }
                return;
            };
            // write 단계: writable이고 응답이 남았으면 한 청크 비차단 전송(read를 막지 않음).
            if (ready.writable and out_head < out_buf.items.len) {
                const written = self.session.writeInputNonBlocking(out_buf.items[out_head..]) catch 0;
                out_head += written;
                if (out_head >= out_buf.items.len) {
                    out_buf.clearRetainingCapacity();
                    out_head = 0;
                }
            }
            // read 단계: 출력을 코어에 적용하고 응답을 outbound 버퍼에 적재한다.
            if (ready.readable) {
                switch (self.session.readChunk(&readbuf) catch |err| {
                    if (err != error.SessionClosed) self.pushReadError(@errorName(err));
                    return;
                }) {
                    .again => {}, // readable/read race — 다음 poll에서 재시도
                    .data => |n| {
                        mutex.lockUncancelable(self.io);
                        core.write(readbuf[0..n]) catch {}; // best-effort(파서 OOM 등은 그 청크 드롭)
                        const reply = core.pendingResponse();
                        if (reply.len > 0) {
                            out_buf.appendSlice(self.allocator, reply) catch {}; // OOM이면 그 응답 드롭
                            core.clearResponse();
                        }
                        mutex.unlock(self.io);
                        // 메인에 "출력 발생" 신호(빈 bytes): output_events를 올려 렌더 트리거.
                        self.queue.pushBlocking(.{ .output = .{
                            .pty_id = self.pty_id,
                            .bytes = &.{},
                        } }) catch return;
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
