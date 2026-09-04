const std = @import("std");
const pty = @import("../pty.zig");
const runtime_mod = @import("runtime.zig");
const terminal = @import("../terminal.zig");
const core_command = @import("../session/core_command.zig");
const sync_frame_split = @import("sync_frame_split.zig");
extern "c" fn usleep(usec: c_uint) c_int;

/// reader-로컬 응답 outbound 버퍼(runProcessing의 out_buf)의 상한. 자식이 stdin을 안 비우면서(POLLOUT 미발화) 응답
/// 유발 출력(CPR·DA·OSC 10/11 등)을 쏟으면 out_buf가 무한 증가하던 경로(버그헌트 감사서 확정)를 막는다 — pending(미전송
/// 응답)이 이 값을 넘으면 추가 응답을 드롭하고(자식이 안 읽어 어차피 전달 불가 — 기존 OOM best-effort `catch {}`와 같은
/// 의미), 소비된 prefix도 이 값마다 compact해 점유를 ~2×response_buffer_capacity 이내로 bound한다.
/// 결정·근거의 단일 출처는 docs/plans/io-render-threading.md §8.8(3)이다(옛 "응답 드롭은 OOM만, capping은 실측 근거 시 재검토"를
/// 이 확정 버그 + 사용자 승인으로 갱신 — 추가 전 상의 완료, [[no-defensive-code-without-consult]]). 값은 write_queue cap과 같다.
pub const response_buffer_capacity: usize = 1 << 18; // 256 KiB
const PauseState = enum(u8) { running, requested, reached, terminal };

/// 응답 reply를 out_buf에 적재하되, pending(미전송 = out_buf[out_head..])이 response_buffer_capacity를 넘으면 드롭한다.
/// runProcessing의 명령 단계·read 단계 두 곳이 공유하는 단일 출처 — 게이트 로직이 둘로 갈라져 표류하지 않게 한다(상한·
/// 근거는 response_buffer_capacity 주석). OOM도 best-effort 드롭(catch {}). out_head는 호출 시점 스냅샷이라 값으로 받는다.
fn appendResponseBounded(allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8), out_head: usize, reply: []const u8) void {
    if (out_buf.items.len - out_head < response_buffer_capacity)
        out_buf.appendSlice(allocator, reply) catch {};
}

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
    pub const WakeNotifier = struct {
        ctx: *anyopaque,
        notify: *const fn (*anyopaque) void,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    items: []QueuedPtyEvent,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,
    wake_notifier: ?WakeNotifier = null,

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

    /// Host exec-upgrade safe-point용. Coalesced output 신호까지 owner drain이 소비됐고 queue가 계속
    /// 살아 있는지를 한 critical section에서 확인한다.
    pub fn emptyAndOpen(self: *PtyEventQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.closed and self.len == 0;
    }

    pub fn close(self: *PtyEventQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.closed = true;
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
    }

    /// Install before the reader starts. The callback runs after queue publication and after the
    /// queue mutex is released, so a host wake adapter cannot re-enter queue state under this lock.
    pub fn setWakeNotifier(self: *PtyEventQueue, notifier: WakeNotifier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.len == 0 and !self.closed and self.wake_notifier == null);
        self.wake_notifier = notifier;
    }

    pub fn tryPush(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return error.QueueClosed;
        }
        if (self.len == self.items.len) {
            self.mutex.unlock(self.io);
            return error.QueueFull;
        }
        self.pushAssumeLocked(event);
        const notifier = self.wake_notifier;
        self.mutex.unlock(self.io);
        if (notifier) |wake| wake.notify(wake.ctx);
    }

    pub fn pushBlocking(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        // PTY output은 버리면 안 된다. queue가 가득 차면 reader thread가 여기서
        // 기다리고, 그 결과 child stdout도 자연스럽게 느려진다. 이것이 문서화된
        // backpressure 정책이다.
        while (!self.closed and self.len == self.items.len) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) {
            self.mutex.unlock(self.io);
            return error.QueueClosed;
        }
        self.pushAssumeLocked(event);
        const notifier = self.wake_notifier;
        self.mutex.unlock(self.io);
        if (notifier) |wake| wake.notify(wake.ctx);
    }

    /// processing reader의 종료 이벤트 전용 비차단 push. processing 경로의 `.output`은 데이터가 아니라
    /// "코어가 바뀌었음"을 알리는 빈 coalescing 신호이므로, 큐가 그 신호 하나로 가득 찼다면 가장 오래된
    /// 신호를 종료 이벤트로 교체한다. EOF에서 `pushBlocking`하면 이 큐를 비우는 메인 스레드가 멈춘 동안
    /// reader도 큐 close defer에 도달하지 못하므로, 세션 종료가 영구 대기할 수 있다.
    ///
    /// 실제 PTY bytes를 소유하는 non-processing 경로에는 사용하지 않는다. 빈 신호가 아닌 이벤트로 큐가
    /// 가득 찼다면 보존을 위해 `QueueFull`을 반환한다.
    pub fn pushTerminalReplacingOutputSignal(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        switch (event) {
            .exited, .read_error => {},
            .output => return error.QueueFull,
        }

        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return error.QueueClosed;
        }
        if (self.len == self.items.len) {
            switch (self.items[self.head]) {
                .output => |output| {
                    if (output.bytes.len != 0) {
                        self.mutex.unlock(self.io);
                        return error.QueueFull;
                    }
                    _ = self.popAssumeLocked();
                },
                .exited, .read_error => {
                    self.mutex.unlock(self.io);
                    return error.QueueFull;
                },
            }
        }
        self.pushAssumeLocked(event);
        const notifier = self.wake_notifier;
        self.mutex.unlock(self.io);
        if (notifier) |wake| wake.notify(wake.ctx);
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

/// PTY **입력 방향** 단일-writer 큐(docs/plans/io-render-threading.md §8 Phase 2 — P2-1). 메인 스레드가 PTY로 보낼
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
    // 명령 큐 fence의 단일 시간축. enqueue 성공 바이트와 reader가 실제 PTY write한 바이트를 각각 단조 누적한다.
    enqueued_total: u64 = 0,
    consumed_total: u64 = 0,

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
        self.enqueued_total += @intCast(data.len);
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
        self.enqueued_total += @intCast(n);
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
        return self.drainChunkLimit(out, out.len);
    }

    /// 다음 command fence를 넘지 않도록 최대 `limit`까지만 복사한다. reader가 prior input을 정확히 fence까지
    /// 쓴 뒤 command를 적용하고, 그 command 응답을 suffix input보다 먼저 PTY에 쓰게 한다.
    pub fn drainChunkLimit(self: *PtyWriteQueue, out: []u8, limit: usize) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(self.pendingAssumeLocked(), @min(out.len, limit));
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
        self.consumed_total += @intCast(n);
        if (self.head >= self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
        self.not_full.broadcast(self.io);
    }

    pub fn enqueuedTotal(self: *PtyWriteQueue) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.enqueued_total;
    }

    pub fn consumedTotal(self: *PtyWriteQueue) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.consumed_total;
    }

    /// Host exec-upgrade safe-point가 input byte frontier를 한 락 아래에서 검사한다. pending 0만 따로 본 뒤
    /// counter를 다시 읽으면 enqueue/consume 사이 상태를 섞을 수 있으므로 동일 critical section에서 확인한다.
    pub fn drainedAtFence(self: *PtyWriteQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.closed and self.pendingAssumeLocked() == 0 and self.enqueued_total == self.consumed_total;
    }
};

/// 메인발 비-PTY 코어 mutate(스크롤·선택·리포팅·config)를 I/O 스레드(reader)로 위임하는 명령
/// (docs/plans/io-render-threading.md §9 Phase 3, (a) 단일책임). reader가 `runProcessing` write 단계에서 drain해
/// 코어 락 아래 적용한다 — 출력 `core.write`와 같은 스레드·같은 락이라 메인이 코어를 직접 mutate하지 않게 된다.
/// 현재 명령은 전부 inline POD다. IME marked text는 client-local `Surface` 상태라 이 큐를 통과하지 않는다.
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
        input_fence: u64 = 0,
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
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn pendingAssumeLocked(self: *const CoreCommandQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn close(self: *CoreCommandQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dropped = self.pendingAssumeLocked();
        self.items.clearRetainingCapacity();
        self.head = 0;
        self.closed = true;
        if (self.debug and dropped > 0) coreq.info("close: {d} unapplied command(s) dropped", .{dropped});
        self.not_full.broadcast(self.io); // backpressure 대기 중인 enqueue를 QueueClosed로 풀어준다
    }

    /// 메인 스레드: inline POD 명령 값을 큐에 넣는다. 대기 명령이 cap에 차면 reader가 비울 때까지
    /// backpressure로 대기한다(UI mutate는 버리면 안 됨). 닫혔으면 QueueClosed. 호출
    /// 후 호출자가 wake로 reader poll을 깨운다(P3-2). 입력 손실 금지라 가득 차도 드롭하지 않고 대기한다(출력 backpressure 대칭).
    pub fn enqueueBlocking(self: *CoreCommandQueue, cmd: CoreCommand) QueueError!void {
        return self.enqueueAfterInput(cmd, 0);
    }

    /// `input_fence` 이전에 enqueue된 PTY input byte가 실제로 모두 write된 뒤에만 적용할 명령을 넣는다.
    pub fn enqueueAfterInput(self: *CoreCommandQueue, cmd: CoreCommand, input_fence: u64) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closed and self.pendingAssumeLocked() >= self.cap) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.QueueClosed;
        const ts: i96 = if (self.debug) std.Io.Clock.awake.now(self.io).nanoseconds else 0;
        try self.items.append(self.allocator, .{ .cmd = cmd, .input_fence = input_fence, .enqueued_ns = ts });
        if (self.debug) coreq.info("enqueue {s} (depth={d})", .{ @tagName(cmd), self.pendingAssumeLocked() });
    }

    /// I/O 스레드: 다음 inline 명령 값 1건을 꺼낸다(없으면 null). head는 I/O 스레드만 움직이는 단일 소비자라,
    /// pop↔적용 사이 메인 enqueue가 tail에
    /// append해도 안전하다. 다 비면 버퍼를 비워 head=0으로 되돌린다(재사용).
    pub fn pop(self: *CoreCommandQueue) ?Entry {
        return self.popReady(std.math.maxInt(u64));
    }

    /// reader가 실제로 PTY에 쓴 input 누적량이 다음 명령 fence에 도달했을 때만 pop한다.
    pub fn popReady(self: *CoreCommandQueue, consumed_input: u64) ?Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pendingAssumeLocked() == 0) return null;
        if (self.items.items[self.head].input_fence > consumed_input) return null;
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

    pub fn nextFence(self: *CoreCommandQueue) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pendingAssumeLocked() == 0) return null;
        return self.items.items[self.head].input_fence;
    }

    pub fn hasPending(self: *CoreCommandQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pendingAssumeLocked() > 0;
    }

    /// Host exec-upgrade safe-point용. command queue를 닫지 않고 현재 fence가 전부 적용됐는지 확인한다.
    pub fn emptyAndOpen(self: *CoreCommandQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.closed and self.pendingAssumeLocked() == 0;
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
    // 단일 writer(docs/plans/io-render-threading.md §8 P2-3b): processing 경로에서 메인 입력(키/paste/스크롤)이
    // 이 큐로 들어오면 runProcessing이 같은 poll 루프에서 drain해 PTY로 write한다 — 메인은 직접 안 쓴다.
    // 옵셔널(null이면 메인 입력 drain 없이 응답만 — controlled smoke/단위 테스트 경로). start() 전 주입.
    write_queue: ?*PtyWriteQueue = null,
    // Phase 3 단일책임(docs/plans/io-render-threading.md §9 P3-2~): 메인발 코어 mutate(IME·스크롤 등)가 이 명령 큐로
    // 들어오면 runProcessing이 같은 poll 루프에서 pop해 코어 락 아래 적용한다 — 메인은 코어를 직접 mutate 안 한다.
    // 옵셔널(null이면 위임 없음 — controlled smoke/단위 테스트는 직접 경로). setProcessing/start() 전 주입.
    command_queue: ?*CoreCommandQueue = null,
    // processing이 켜지면(setProcessing이 release-store) run()이 코어를 직접 처리한다. release-acquire로
    // core/core_mutex/io/write_queue/command_queue 주입이 reader 스레드에 보인다(설정→store, 읽기 전 load).
    processing: std.atomic.Value(bool) = .init(false),
    // Host exec-upgrade 비파괴 pause. request는 self-pipe wake로 poll을 깨우고, reader가 마지막 local chunk와
    // outbound fence를 모두 처리한 loop 상단에서 reached를 publish한 뒤 thread만 반환한다. queue/session/child는
    // 닫지 않으므로 owner가 encode 실패 시 같은 reader를 다시 start할 수 있다.
    // cancel과 reader ACK가 서로 엇갈려 "cancel 성공처럼 보였지만 reader는 종료"되는 TOCTOU를 막는다. 두 전이는
    // requested 한 상태에서 CAS로 경쟁하며 정확히 한쪽만 승리한다.
    pause_state: std.atomic.Value(PauseState) = .init(.running),
    // Query response buffer를 stack-local로 두면 coordinator가 safe-point empty를 증명할 수 없다. reader 소유
    // transfer state로 승격해 pause join 뒤 allocation-free로 검사하고 resume 시 capacity를 재사용한다.
    transfer_out: std.ArrayList(u8) = .empty,
    transfer_out_head: usize = 0,
    // Target restore pre-commit start gate(U3). Thread 생성 성공은 먼저 증명하되 release 전에는 PTY/session/queue/core를
    // 한 번도 역참조하지 않는다. abort는 rollback cleanup이 child lifecycle을 건드리지 않고 thread만 join하게 한다.
    start_released: std.atomic.Value(bool) = .init(true),
    start_aborted: std.atomic.Value(bool) = .init(false),
    start_gate_reached: std.atomic.Value(bool) = .init(false),
    // 실제 PTY read 경계의 누적 byte 수. processing 경로는 큐에 빈 coalescing 신호만 남기므로
    // queue event 길이로 세면 항상 0이 된다. owner-side perf probe가 입력 길이를 출력량으로
    // 오인하지 않도록 reader가 읽은 자리에서 단조 증가시킨다.
    /// 선택적 제품 관측 sink. 기본 제품 경로는 null이라 read hot path에서 atomic
    /// 연산을 하지 않는다. 별도 process gate가 reader 시작 전에만 주입한다.
    output_byte_counter: ?*std.atomic.Value(u64) = null,

    // ── sync(2026) 프레임 경계 보류 ─────────────────────────────────────────────
    // **아직 안 끝난 프레임의 바이트는 코어에 안 넣고 여기 들고 있는다**(`sync_frame_split`).
    // 그래야 메인이 30Hz 로 격자를 읽을 때 언제나 **완성 프레임**을 본다 — 이 보류가 없으면
    // 청크가 프레임 한가운데서 끝나 그리다 만 화면이 그대로 투영된다(실측 18/18 tick).
    //
    // **버퍼는 한 번만 잡고 다시는 안 잡는다.** read hot path 에서 실패할 수 있는 할당을 하면
    // 「바이트를 순서대로 다 넣는다」를 지키기 위한 예외 경로가 늘어난다 — 처음 한 번 실패하면
    // 그때는 **아무것도 안 들고 있는 상태**라 그냥 이 축을 끄면 된다(오늘 동작).
    /// 보류 버퍼(첫 프레임을 만날 때 한 번 잡는다). null 이면 아직 안 잡았거나 포기했다.
    sync_held_buf: ?[]u8 = null,
    /// 보류 중인 바이트 수.
    sync_held_len: usize = 0,
    /// 보류를 시작한 시각(ns, monotonic). 시한을 넘기면 접는다.
    sync_held_since_ns: i128 = 0,
    /// 이 축을 껐나(버퍼를 못 잡았다). 켜지지 않으므로 read 경로는 분기 하나만 낸다.
    sync_bypass: bool = false,

    /// 보류 상한 — 이만큼 쌓이면 프레임이 안 끝나는 것으로 보고 접는다. 전체 화면을 truecolor 로
    /// 다시 그리는 프레임이 수십 KiB 라 그 몇 배를 준다(값은 여기 하나가 소유한다).
    const sync_held_max: usize = 256 * 1024;
    /// 보류 시한(ns). **프레임 «안에서» 질의를 보내고 답을 기다리는 앱**이 있으면 보류가 곧 교착이
    /// 되므로, 교착 대신 지연으로 접는다. 투영 게이트의 sync timeout(1초)과 같은 눈금이다.
    const sync_held_timeout_ns: i128 = 1000 * std.time.ns_per_ms;

    /// 청크를 **프레임 경계에서 잘라** 코어에 적용한다. 안 끝난 프레임의 꼬리는 다음 청크를 기다린다.
    ///
    /// 순서 계약: **읽은 바이트는 읽은 순서대로 빠짐없이** 코어에 들어간다. 보류가 풀리는 자리
    /// (상한·시한·프레임 완성)에서도 「들고 있던 것 → 이번 청크」 순서가 뒤집히지 않는다.
    fn applySyncFramed(
        self: *PtyReader,
        core: *terminal.TerminalCore,
        mutex: *std.Io.Mutex,
        chunk: []const u8,
        out_buf: *std.ArrayList(u8),
        out_head: *usize,
    ) void {
        if (self.sync_bypass) return self.applyToCore(core, mutex, chunk, out_buf, out_head);

        // 들고 있는 것이 없으면 **복사 없이** 이 청크만 본다 — 2026 을 안 쓰는 스트림(대부분)은
        // 여기서 `applicableLen == chunk.len` 이라 예전과 같은 한 번의 write 로 끝난다.
        if (self.sync_held_len == 0) {
            const n = sync_frame_split.applicableLen(chunk);
            self.applyToCore(core, mutex, chunk[0..n], out_buf, out_head);
            if (n == chunk.len) return;
            self.holdTail(chunk[n..], core, mutex, out_buf, out_head);
            return;
        }

        // 들고 있던 것이 있다 — 이어 붙여 다시 판정한다. 안 들어가면 **순서대로** 흘려보낸다.
        const buf = self.sync_held_buf.?;
        if (self.sync_held_len + chunk.len > buf.len or self.heldExpired()) {
            self.flushHeld(core, mutex, out_buf, out_head);
            return self.applySyncFramed(core, mutex, chunk, out_buf, out_head);
        }
        @memcpy(buf[self.sync_held_len..][0..chunk.len], chunk);
        self.sync_held_len += chunk.len;
        const joined = buf[0..self.sync_held_len];
        const n = sync_frame_split.applicableLen(joined);
        if (n == 0) return; // 아직도 프레임 안 — 더 기다린다
        self.applyToCore(core, mutex, joined[0..n], out_buf, out_head);
        const rest = self.sync_held_len - n;
        if (rest > 0) std.mem.copyForwards(u8, buf[0..rest], joined[n..]);
        self.sync_held_len = rest;
        if (rest == 0) self.sync_held_since_ns = 0;
    }

    /// 안 끝난 프레임의 꼬리를 들고 있는다. 버퍼를 아직 안 잡았으면 여기서 한 번 잡고, 못 잡으면
    /// 이 축을 끈다(그 자리에서 꼬리를 그대로 적용하므로 바이트는 안 잃는다).
    fn holdTail(
        self: *PtyReader,
        tail: []const u8,
        core: *terminal.TerminalCore,
        mutex: *std.Io.Mutex,
        out_buf: *std.ArrayList(u8),
        out_head: *usize,
    ) void {
        if (self.sync_held_buf == null) {
            self.sync_held_buf = self.allocator.alloc(u8, sync_held_max) catch {
                self.sync_bypass = true;
                return self.applyToCore(core, mutex, tail, out_buf, out_head);
            };
        }
        const buf = self.sync_held_buf.?;
        if (tail.len > buf.len) return self.applyToCore(core, mutex, tail, out_buf, out_head);
        @memcpy(buf[0..tail.len], tail);
        self.sync_held_len = tail.len;
        self.sync_held_since_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// 보류가 시한을 넘겼나. 넘기면 교착 대신 **그리다 만 프레임**을 택한다(오늘 동작).
    fn heldExpired(self: *PtyReader) bool {
        if (self.sync_held_len == 0) return false;
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        return now -| self.sync_held_since_ns >= sync_held_timeout_ns;
    }

    /// 들고 있던 것을 통째로 코어에 넣는다(상한·시한 초과).
    fn flushHeld(
        self: *PtyReader,
        core: *terminal.TerminalCore,
        mutex: *std.Io.Mutex,
        out_buf: *std.ArrayList(u8),
        out_head: *usize,
    ) void {
        if (self.sync_held_len == 0) return;
        const buf = self.sync_held_buf.?;
        self.applyToCore(core, mutex, buf[0..self.sync_held_len], out_buf, out_head);
        self.sync_held_len = 0;
        self.sync_held_since_ns = 0;
    }

    /// 코어에 한 조각을 적용하고 그 조각이 만든 응답을 outbound 로 옮긴다(옛 read 단계 본문 그대로).
    fn applyToCore(
        self: *PtyReader,
        core: *terminal.TerminalCore,
        mutex: *std.Io.Mutex,
        bytes: []const u8,
        out_buf: *std.ArrayList(u8),
        out_head: *usize,
    ) void {
        if (bytes.len == 0) return;
        core.owner_dbg.lock(mutex, self.io);
        core.write(bytes) catch {}; // best-effort(파서 OOM 등은 그 청크 드롭)
        const reply = core.pendingResponse();
        if (reply.len > 0) {
            appendResponseBounded(self.allocator, out_buf, out_head.*, reply);
            core.clearResponse();
        }
        core.owner_dbg.unlock(mutex, self.io);
    }

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

    pub fn startPrepared(self: *PtyReader) !void {
        std.debug.assert(self.thread == null);
        self.start_gate_reached.store(false, .release);
        self.start_aborted.store(false, .release);
        self.start_released.store(false, .release);
        errdefer {
            self.start_released.store(true, .release);
            self.start_aborted.store(false, .release);
            self.start_gate_reached.store(false, .release);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn preparedStartReached(self: *const PtyReader) bool {
        return self.start_gate_reached.load(.acquire);
    }

    pub fn releasePreparedStart(self: *PtyReader) void {
        std.debug.assert(self.thread != null);
        self.start_released.store(true, .release);
    }

    pub fn discardPreparedStart(self: *PtyReader) void {
        if (self.thread == null) return;
        std.debug.assert(!self.start_released.load(.acquire));
        self.start_aborted.store(true, .release);
        self.join();
        self.start_released.store(true, .release);
        self.start_aborted.store(false, .release);
        self.start_gate_reached.store(false, .release);
    }

    fn discardPreparedStartIfPending(self: *PtyReader) void {
        if (self.thread != null and !self.start_released.load(.acquire))
            self.discardPreparedStart();
    }

    pub fn deinit(self: *PtyReader) void {
        std.debug.assert(self.thread == null);
        self.transfer_out.deinit(self.allocator);
        self.transfer_out_head = 0;
        if (self.sync_held_buf) |buf| self.allocator.free(buf);
        self.sync_held_buf = null;
        self.sync_held_len = 0;
    }

    pub fn join(self: *PtyReader) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn outputBytesRead(self: *const PtyReader) u64 {
        const counter = self.output_byte_counter orelse return 0;
        return counter.load(.acquire);
    }

    pub fn setOutputByteCounter(
        self: *PtyReader,
        counter: *std.atomic.Value(u64),
    ) void {
        std.debug.assert(self.thread == null);
        self.output_byte_counter = counter;
    }

    fn recordOutputBytes(self: *PtyReader, amount: usize) void {
        const counter = self.output_byte_counter orelse return;
        _ = counter.fetchAdd(@intCast(amount), .release);
    }

    pub fn stopAndJoin(self: *PtyReader) void {
        // Prepared restore/resume cleanup이 전용 discard API를 놓치더라도 gate
        // thread를 먼저 abort/join한다. 그렇지 않으면 아래 session.close는
        // release되지 않은 gate를 깨울 수 없어 join이 영구 대기한다.
        self.discardPreparedStartIfPending();
        // 앱이 탭/창을 닫을 때는 queue를 먼저 닫아 reader가 더 이상 event를
        // 쌓지 못하게 하고, session.close로 blocking read를 깨운 뒤 join한다.
        // session.deinit은 reader가 끝난 뒤 호출해야 session memory를 안전하게 파괴할 수 있다.
        self.queue.close();
        self.session.close();
        self.join();
    }

    pub const PauseError = error{NotProcessing};

    /// 비파괴 pause 요청. 완료 여부는 `pauseReached`로 관찰하고, true가 된 뒤에만 `join`한다. deadline 전에
    /// 도달하지 못하면 `cancelPause`로 reader를 계속 실행시킨다.
    pub fn requestPause(self: *PtyReader) PauseError!void {
        if (!self.processing.load(.acquire)) return error.NotProcessing;
        if (self.pause_state.cmpxchgStrong(.running, .requested, .acq_rel, .acquire) != null)
            return error.NotProcessing;
        self.session.signalWrite();
    }

    pub fn pauseReached(self: *const PtyReader) bool {
        return self.pause_state.load(.acquire) == .reached;
    }

    /// true면 cancel CAS가 이겨 reader가 계속 실행하고, false면 reader ACK가 이겼으므로 caller가 join/resume해야 한다.
    pub fn cancelPause(self: *PtyReader) bool {
        const cancelled = self.pause_state.cmpxchgStrong(.requested, .running, .acq_rel, .acquire) == null;
        self.session.signalWrite();
        return cancelled;
    }

    fn tryAcknowledgePause(self: *PtyReader) bool {
        return self.pause_state.cmpxchgStrong(.requested, .reached, .acq_rel, .acquire) == null;
    }

    fn markTerminal(self: *PtyReader) void {
        self.pause_state.store(.terminal, .release);
    }

    /// reached thread를 join한 뒤 같은 queue/session/core에 reader를 다시 붙인다. paused thread는 terminal defer를
    /// 타지 않아 queue가 open이고 child/fd도 그대로다.
    pub fn prepareResumeAfterPause(self: *PtyReader) !void {
        std.debug.assert(self.thread == null);
        std.debug.assert(self.pause_state.load(.acquire) == .reached);
        try self.startPrepared();
    }

    pub fn releasePreparedResume(self: *PtyReader) void {
        std.debug.assert(self.thread != null);
        std.debug.assert(self.pause_state.load(.acquire) == .reached);
        self.pause_state.store(.running, .release);
        self.releasePreparedStart();
    }

    pub fn discardPreparedResume(self: *PtyReader) void {
        self.discardPreparedStart();
    }

    pub fn resumeAfterPause(self: *PtyReader) !void {
        try self.prepareResumeAfterPause();
        self.releasePreparedResume();
    }

    /// join된 pause frontier의 외부 검증. reader-owned response, admitted input fence, command queue, core response가
    /// 모두 비어야 handoff encode가 가능하다.
    pub fn pausedStateIsSafe(self: *PtyReader) bool {
        if (self.thread != null or self.pause_state.load(.acquire) != .reached) return false;
        if (self.transfer_out_head != 0 or self.transfer_out.items.len != 0) return false;
        if (self.write_queue) |wq| if (!wq.drainedAtFence()) return false;
        if (self.command_queue) |cq| if (!cq.emptyAndOpen()) return false;
        const core = self.core orelse return false;
        const mutex = self.core_mutex orelse return false;
        core.owner_dbg.lock(mutex, self.io);
        defer core.owner_dbg.unlock(mutex, self.io);
        return core.pendingResponse().len == 0;
    }

    pub fn run(self: *PtyReader) void {
        if (!self.start_released.load(.acquire)) {
            self.start_gate_reached.store(true, .release);
            while (!self.start_released.load(.acquire)) {
                if (self.start_aborted.load(.acquire)) return;
                _ = usleep(1000);
            }
        }
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
                    self.pushTerminationForIoError(@errorName(err));
                }
                return;
            };
            switch (event) {
                .output => |bytes| {
                    self.recordOutputBytes(bytes.len);
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

    /// reader-processing 통합 I/O 루프(docs/plans/io-render-threading.md §8 Phase 2 — P2-3a/b). 한 poll로
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
        // EOF/read/write 오류로 reader가 스스로 끝나는 경로도 outbound 생산자를 반드시 깨운다. owner가 나중에
        // finishAfterTermination/close에서 다시 닫아도 close는 멱등이다. 단 safe pause return은 queue를 닫으면
        // resume가 불가능하므로 terminal 종료와 분리한다.
        var paused = false;
        defer if (!paused) {
            // request/cancel과 terminal exit도 같은 atomic state에서 직렬화한다. `.requested`가 남은 채 thread만
            // 종료되면 manager가 cancel 성공으로 오인할 수 있으므로 outbound close보다 먼저 terminal을 publish한다.
            self.markTerminal();
            if (self.write_queue) |wq| wq.close();
            if (self.command_queue) |cq| cq.close();
        };
        const out_buf = &self.transfer_out;
        const out_head = &self.transfer_out_head;
        var readbuf: [4096]u8 = undefined;
        var writebuf: [512]u8 = undefined; // write_queue drain 청크(writeInputNonBlocking이 ≤512B 쓰므로)
        while (true) {
            // 명령 단계(docs/plans/io-render-threading.md §9 P3-2): prior input fence에 도달한 명령만 적용한다.
            // 이 단계를 poll/write보다 먼저 두면 focus/config가 만든 응답은 같은 fence 뒤 suffix input보다 먼저 나간다.
            if (self.command_queue) |cq| {
                const consumed_input = if (self.write_queue) |wq| wq.consumedTotal() else std.math.maxInt(u64);
                var applied = false;
                while (cq.popReady(consumed_input)) |entry| {
                    core.owner_dbg.lock(mutex, self.io);
                    const effect = core_command.apply(core, entry.cmd);
                    if (effect.send_form_feed) appendResponseBounded(self.allocator, out_buf, out_head.*, "\x0c");
                    const reply = core.pendingResponse();
                    if (reply.len > 0) {
                        appendResponseBounded(self.allocator, out_buf, out_head.*, reply);
                        core.clearResponse(); // 드롭(상한 초과)해도 코어 측 응답 버퍼는 항상 비운다
                    }
                    core.owner_dbg.unlock(mutex, self.io);
                    cq.logApply(entry); // MARU_DEBUG면 enqueue→apply 지연 로깅
                    applied = true;
                }
                // 명령이 코어를 바꿨으면 렌더 트리거(출력과 같은 빈 신호). 비블로킹(tryPush) — full이면 드롭(coalescing,
                // 교차-큐 데드락 방지, read 단계와 동일 근거).
                if (applied) self.queue.tryPush(.{ .output = .{ .pty_id = self.pty_id, .bytes = &.{} } }) catch |err| switch (err) {
                    error.QueueFull => {},
                    else => return,
                };
            }
            // Pause 요청은 continuous-readable PTY보다 우선한다. 이미 읽은 chunk는 위 read 단계에서 즉시 core에
            // 적용되고, admitted outbound가 모두 실제 PTY에 써진 frontier에서만 ACK한다. 이후 output은 kernel
            // PTY buffer에 남아 target/resumed reader가 다음 byte부터 읽는다.
            // **보류 중인 sync 프레임을 먼저 흘려보낸다.** 안 그러면 pause/handoff 가 그 바이트를
            // 통째로 버려 원격이 보낸 프레임이 사라지고, 이어지는 diff 가 없는 셀을 전제해 **모델이
            // 영구히 어긋난다**. 여기서 접는 대가는 그리다 만 프레임 한 장인데, 어차피 멈추는 자리다
            // (handoff 인벤토리도 이 두 필드를 `must_be_empty` 로 못 박는다).
            if (self.pause_state.load(.acquire) == .requested and self.sync_held_len > 0) {
                self.flushHeld(core, mutex, out_buf, out_head);
            }
            if (self.pause_state.load(.acquire) == .requested and
                out_head.* == 0 and out_buf.items.len == 0 and
                (self.write_queue == null or self.write_queue.?.drainedAtFence()) and
                (self.command_queue == null or self.command_queue.?.emptyAndOpen()))
            {
                core.owner_dbg.lock(mutex, self.io);
                const response_empty = core.pendingResponse().len == 0;
                core.owner_dbg.unlock(mutex, self.io);
                if (response_empty) {
                    if (self.tryAcknowledgePause()) {
                        paused = true;
                        return;
                    }
                }
            }
            const reply_pending = out_head.* < out_buf.items.len;
            const main_pending = if (self.write_queue) |wq| wq.hasPending() else false;
            const ready = self.session.waitIo(reply_pending or main_pending) catch |err| {
                if (err != error.SessionClosed and err != error.NoMoreEvents) {
                    self.pushProcessingTerminationForIoError(@errorName(err));
                }
                return;
            };
            // write 단계(비차단, read 무정지): 응답을 먼저 비운다(query 응답 지연 최소화), 응답이 다 나가면
            // 메인 입력을 한 청크 drain한다. 한 iteration에 한 소스/한 청크 — 다음 poll에서 이어 비운다.
            if (ready.writable) {
                // EAGAIN(버퍼 참)은 writeInputNonBlocking이 0으로 돌려준다(에러 아님 — 다음 poll에 이어 씀).
                // catch로 잡히는 건 치명적 write 실패(EIO 등)/SessionClosed뿐 — `catch 0`로 삼키면 head가 안 늘어
                // POLLOUT 스핀(라이브락)·입력 조용한 손실이 되므로, 에러면 reader를 종료한다(read 에러 경로와 동일).
                if (out_head.* < out_buf.items.len) {
                    const written = self.session.writeInputNonBlocking(out_buf.items[out_head.*..]) catch |err| {
                        if (err != error.SessionClosed) self.pushProcessingTerminationForIoError(@errorName(err));
                        return;
                    };
                    out_head.* += written;
                    if (out_head.* >= out_buf.items.len) {
                        out_buf.clearRetainingCapacity();
                        out_head.* = 0;
                    } else if (out_head.* >= response_buffer_capacity) {
                        // 부분 drain이 오래 이어지면 out_head(소비된 prefix)만 커지며 items.len이 무한 증가할 수 있다 —
                        // prefix가 상한만큼 쌓이면 잔여(out_buf[out_head..])를 앞으로 당겨 점유를 bound한다(아래 append 게이트가
                        // pending을, 여기가 prefix를 막아 합쳐서 ~2×response_buffer_capacity 이내). dest<src라 copyForwards가 안전.
                        const remaining = out_buf.items.len - out_head.*;
                        std.mem.copyForwards(u8, out_buf.items[0..remaining], out_buf.items[out_head.*..]);
                        out_buf.items.len = remaining;
                        out_head.* = 0;
                    }
                } else if (self.write_queue) |wq| {
                    const consumed = wq.consumedTotal();
                    const fence_limit: usize = if (self.command_queue) |cq|
                        if (cq.nextFence()) |fence|
                            @intCast(@min(fence -| consumed, @as(u64, writebuf.len)))
                        else
                            writebuf.len
                    else
                        writebuf.len;
                    const n = wq.drainChunkLimit(&writebuf, fence_limit);
                    if (n > 0) {
                        const written = self.session.writeInputNonBlocking(writebuf[0..n]) catch |err| {
                            if (err != error.SessionClosed) self.pushProcessingTerminationForIoError(@errorName(err));
                            return;
                        };
                        wq.consume(written); // 실제 쓴 만큼만 head 전진(부분 write 잔량은 다음 poll)
                    }
                }
            }
            // read 단계: 출력을 코어에 적용하고 응답을 outbound 버퍼에 적재한다.
            if (ready.readable) {
                switch (self.session.readChunk(&readbuf) catch |err| {
                    if (err != error.SessionClosed) self.pushProcessingTerminationForIoError(@errorName(err));
                    return;
                }) {
                    .again => {}, // readable/read race — 다음 poll에서 재시도
                    .data => |n| {
                        self.recordOutputBytes(n);
                        // **프레임 경계에서 자른다**(sync 2026 — `sync_frame_split`). 아직 안 끝난 프레임의
                        // 꼬리는 코어에 안 넣고 들고 있다가 다음 청크와 이어 붙인다. 그래야 메인이 30Hz 로
                        // 읽는 격자가 **언제나 완성 프레임**이다 — 없으면 청크가 프레임 한가운데서 끝나
                        // 그리다 만 화면이 그대로 투영된다(실측 18/18 tick).
                        self.applySyncFramed(core, mutex, readbuf[0..n], out_buf, out_head);
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
                            if (err != error.SessionClosed) self.pushProcessingTerminationForIoError(@errorName(err));
                            return;
                        };
                        if (status) |s| {
                            self.queue.pushTerminalReplacingOutputSignal(.{ .exited = .{
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

    /// I/O 오류(waitIo/read/write/reapAfterEof 실패)를 만난 reader가 큐에 넣을 종료 이벤트를 정한다 — **루트커즈 수정**:
    /// read_error가 자식 생존 검증 없이 종료로 취급돼 산 셸을 죽이고(finishAfterTermination→session.close→shutdownChild)
    /// 좌측 워크스페이스 탭을 통째로 닫던 버그(셸에서 claude 실행 중 Ctrl+C가 유발한 일시적 write 오류가 트리거).
    /// 세션에 비차단 reap(reapIfExited)을 걸어 검증한다: 자식이 이미 죽었으면 `.exited`(EOF 경로와 동치인 검증된 종료
    /// → 정상 자동 닫힘), 아직 살아있으면 `.read_error`(surface만 unusable로 latch되고 워크스페이스는 유지된다).
    /// reapIfExited 실패(ECHILD 등 — 이미 다른 곳이 reap 중)는 미검증이라 `.read_error`로 둔다(보수적). 어느 쪽이든
    /// 이 reader는 종료한다(연결이 끊겼다) — 이 함수는 "무엇을 큐에 넣을지"만 정하고, 큐 push 실패는 무시(닫힘).
    fn pushTerminationForIoError(self: *PtyReader, message: []const u8) void {
        const reaped = self.session.reapIfExited() catch null;
        if (reaped) |status| {
            self.queue.pushBlocking(.{ .exited = .{
                .pty_id = self.pty_id,
                .status = status,
            } }) catch {};
        } else {
            self.pushReadError(message);
        }
    }

    /// processing reader는 큐에 실제 output bytes를 싣지 않고 빈 렌더 신호만 싣는다. 오류 종료도 blocking
    /// push를 쓰면 포화된 신호 큐에서 reader가 멈춰 outbound queue close defer에 도달하지 못하므로, 빈
    /// 신호를 검증된 terminal event로 교체하는 전용 경로를 사용한다.
    fn pushProcessingTerminationForIoError(self: *PtyReader, message: []const u8) void {
        const reaped = self.session.reapIfExited() catch null;
        if (reaped) |status| {
            self.queue.pushTerminalReplacingOutputSignal(.{ .exited = .{
                .pty_id = self.pty_id,
                .status = status,
            } }) catch {};
        } else {
            self.queue.pushTerminalReplacingOutputSignal(.{ .read_error = .{
                .pty_id = self.pty_id,
                .message = message,
            } }) catch {};
        }
    }
};

test "pty event queue rejects zero capacity" {
    try std.testing.expectError(
        error.ZeroCapacity,
        PtyEventQueue.init(std.testing.io, std.testing.allocator, 0),
    );
}

test "PTY pause cancel and reader acknowledgement have one CAS winner" {
    var reader: PtyReader = undefined;
    reader.pause_state = .init(.requested);
    _ = reader.pause_state.cmpxchgStrong(.requested, .running, .acq_rel, .acquire);
    try std.testing.expect(!reader.tryAcknowledgePause());
    try std.testing.expectEqual(PauseState.running, reader.pause_state.load(.acquire));

    reader.pause_state = .init(.requested);
    try std.testing.expect(reader.tryAcknowledgePause());
    _ = reader.pause_state.cmpxchgStrong(.requested, .running, .acq_rel, .acquire);
    try std.testing.expectEqual(PauseState.reached, reader.pause_state.load(.acquire));

    reader.pause_state = .init(.requested);
    reader.markTerminal();
    try std.testing.expect(reader.pause_state.cmpxchgStrong(.requested, .running, .acq_rel, .acquire) != null);
    try std.testing.expectEqual(PauseState.terminal, reader.pause_state.load(.acquire));
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

test "PTY reader raw byte counter is monotonic across coalesced output signals" {
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var session: pty.PtySession = undefined;
    var reader = PtyReader.init(allocator, 8, &session, &queue);
    var counter: std.atomic.Value(u64) = .init(0);
    reader.setOutputByteCounter(&counter);
    try std.testing.expectEqual(@as(u64, 0), reader.outputBytesRead());
    reader.recordOutputBytes(7);
    reader.recordOutputBytes(11);
    try std.testing.expectEqual(@as(u64, 18), reader.outputBytesRead());
}

test "prepared reader start can be created and discarded before touching PTY dependencies" {
    const allocator = std.testing.allocator;
    var session: pty.PtySession = undefined;
    var queue: PtyEventQueue = undefined;
    var reader = PtyReader.init(allocator, 77, &session, &queue);
    defer reader.deinit();
    try reader.startPrepared();
    var attempts: usize = 0;
    while (attempts < 1000 and !reader.preparedStartReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(reader.preparedStartReached());
    reader.discardPreparedStart();
    try std.testing.expect(reader.thread == null);
}

test "generic stopAndJoin aborts a pending prepared start before session cleanup" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var session = try pty.PtySession.spawn(allocator, .{
        .command = "/bin/cat",
        .size = .{ .cols = 20, .rows = 4 },
    });
    defer session.deinit();
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var reader = PtyReader.init(allocator, 78, &session, &queue);
    defer reader.deinit();
    try reader.startPrepared();
    var attempts: usize = 0;
    while (attempts < 1000 and !reader.preparedStartReached()) : (attempts += 1)
        _ = usleep(1000);
    try std.testing.expect(reader.preparedStartReached());
    reader.stopAndJoin();
    try std.testing.expect(reader.thread == null);
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

test "processing terminal event replaces a full coalesced output signal" {
    var queue = try PtyEventQueue.init(std.testing.io, std.testing.allocator, 1);
    defer queue.deinit();

    try queue.tryPush(.{ .output = .{ .pty_id = 7, .bytes = &.{} } });
    try queue.pushTerminalReplacingOutputSignal(.{
        .exited = .{ .pty_id = 7, .status = .{ .exited = 23 } },
    });

    const event = queue.popBlocking().?;
    switch (event) {
        .exited => |exited| {
            try std.testing.expectEqual(@as(runtime_mod.PtyId, 7), exited.pty_id);
            try std.testing.expectEqual(@as(u8, 23), exited.status.exited);
        },
        else => return error.TestUnexpectedResult,
    }
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

test "pty event queue wake notifier observes successful publication but not rejected pushes" {
    const Counter = struct {
        value: usize = 0,
        queue: *PtyEventQueue,
        observed_count: usize = 0,

        fn notify(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.value += 1;
            self.observed_count = self.queue.count();
        }
    };

    var queue = try PtyEventQueue.init(std.testing.io, std.testing.allocator, 1);
    defer queue.deinit();
    var counter: Counter = .{ .queue = &queue };
    queue.setWakeNotifier(.{ .ctx = &counter, .notify = Counter.notify });

    try queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), counter.value);
    try std.testing.expectEqual(@as(usize, 1), counter.observed_count);
    try std.testing.expectError(
        error.QueueFull,
        queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = &.{} } }),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.value);

    var event = queue.tryPop().?;
    event.deinit(std.testing.allocator);
    try queue.pushTerminalReplacingOutputSignal(.{ .exited = .{
        .pty_id = 1,
        .status = .{ .exited = 0 },
    } });
    try std.testing.expectEqual(@as(usize, 2), counter.value);
    event = queue.tryPop().?;
    event.deinit(std.testing.allocator);
    queue.close();
    try std.testing.expectError(
        error.QueueClosed,
        queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = &.{} } }),
    );
    try std.testing.expectEqual(@as(usize, 2), counter.value);
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
    // 단일 writer close-with-pending(docs/plans/io-render-threading.md §8 P2-4): 소비자(I/O 스레드)가 멈춰 큐가 가득
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

test "CoreCommandQueue: enqueue→pop preserves FIFO for inline commands" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 8);
    defer q.deinit();
    try std.testing.expect(!q.hasPending());

    try q.enqueueBlocking(.{ .scroll = 2 });
    try q.enqueueBlocking(.{ .scroll = 5 });
    try q.enqueueBlocking(.scroll_to_bottom);

    try std.testing.expect(q.hasPending());

    const e1 = q.pop().?;
    try std.testing.expectEqual(@as(isize, 2), e1.cmd.scroll);

    const e2 = q.pop().?;
    try std.testing.expectEqual(@as(isize, 5), e2.cmd.scroll);

    const e3 = q.pop().?;
    try std.testing.expect(e3.cmd == .scroll_to_bottom);

    try std.testing.expect(q.pop() == null);
    try std.testing.expect(!q.hasPending());
}

test "PTY input fence preserves prior input then core command then suffix input" {
    // host-backed focus report는 입력과 별도 큐를 쓰지만 PTY에서 관측되는 순서는 하나여야 한다. 누적 byte fence가
    // 512B 청크 경계와 무관하게 prefix까지만 drain하고, command 적용 뒤 suffix를 허용하는지 고정한다.
    var writes = try PtyWriteQueue.init(std.testing.io, std.testing.allocator, 32);
    defer writes.deinit();
    var commands = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 4);
    defer commands.deinit();

    try writes.enqueueBlocking("ABCD");
    const fence = writes.enqueuedTotal();
    try commands.enqueueAfterInput(.{ .report_focus = true }, fence);
    try writes.enqueueBlocking("EF");

    try std.testing.expect(commands.popReady(writes.consumedTotal()) == null);
    var buf: [16]u8 = undefined;
    const prefix_limit: usize = @intCast(commands.nextFence().? - writes.consumedTotal());
    const prefix_len = writes.drainChunkLimit(&buf, prefix_limit);
    try std.testing.expectEqualStrings("ABCD", buf[0..prefix_len]);
    writes.consume(prefix_len);

    const command = commands.popReady(writes.consumedTotal()).?;
    try std.testing.expect(command.cmd == .report_focus);
    try std.testing.expect(command.cmd.report_focus);
    const suffix_len = writes.drainChunk(&buf);
    try std.testing.expectEqualStrings("EF", buf[0..suffix_len]);
}

test "CoreCommandQueue: zero capacity 거부 / close 후 enqueue는 QueueClosed" {
    try std.testing.expectError(error.ZeroCapacity, CoreCommandQueue.init(std.testing.io, std.testing.allocator, 0));
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 4);
    defer q.deinit();
    q.close();
    try std.testing.expectError(error.QueueClosed, q.enqueueBlocking(.{ .scroll = 1 }));
}

test "CoreCommandQueue: close discards pending inline commands" {
    var q = try CoreCommandQueue.init(std.testing.io, std.testing.allocator, 8);
    defer q.deinit();
    try q.enqueueBlocking(.{ .scroll = 1 });
    try q.enqueueBlocking(.{ .scroll = 3 });
    try std.testing.expect(q.hasPending());
    q.close();
    try std.testing.expect(!q.hasPending());
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
        got += 1;
    }
    thread.join();
    try std.testing.expectEqual(@as(usize, total), got);
}

test "sync(2026): 청크가 프레임 한가운데서 끝나도 코어에는 «완성 프레임»만 들어간다" {
    // **실기에서 잡은 결함**(2026-09-04, 임시 sshd + 시뮬레이션 프레임 스트림). 리더가 `read(2)` 청크를
    // 통째로 적용하는데 SSH 스트림은 거의 언제나 프레임 한가운데서 끊긴다. 그러면 코어 격자에
    // 「완성 프레임 N + 그리다 만 N+1」 이 남고, 메인이 30Hz 로 그것을 읽어 GPU 에 올린다 —
    // `.sync` 로그로 18/18 tick 이 `active=1 gproj=1`(= 그리다 만 프레임 투영)이었고, 매 표본이
    // `bsu == esu + 1` 이었다(= 투영 순간 리더가 다음 프레임 안).
    //
    // 그래서 판정은 **매 청크 뒤 코어가 프레임 밖인가**로 한다. 이 판정은 투영 게이트를 안 본다 —
    // 게이트는 tick 폴링이라 「언제 봐도 완성」을 보장할 수 없고, 그 보장은 여기서 서야 한다.
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var session: pty.PtySession = undefined; // run()을 시작하지 않으므로 역참조 안 됨
    var reader = PtyReader.init(allocator, 11, &session, &queue);
    defer reader.deinit();

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 4 });
    defer core.deinit();
    var mutex: std.Io.Mutex = .init;
    reader.setProcessing(&core, &mutex, std.testing.io);
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var out_head: usize = 0;

    const B = sync_frame_split.bsu;
    const E = sync_frame_split.esu;
    // 프레임 세 장을 **일부러 어긋난 자리에서** 잘라 넣는다(SSH 청크 경계 모사).
    const stream = B ++ "\x1b[Hone" ++ E ++ B ++ "\x1b[Htwo" ++ E ++ B ++ "\x1b[Hthree" ++ E;
    var at: usize = 0;
    var step: usize = 7; // 프레임 길이와 서로소인 보폭 — 경계가 골고루 어긋난다
    while (at < stream.len) {
        const end = @min(at + step, stream.len);
        reader.applySyncFramed(&core, &mutex, stream[at..end], &out_buf, &out_head);
        at = end;
        step = if (step == 7) 3 else 7; // BSU 한가운데서 끊기는 경우도 만든다

        // **매 청크 뒤 코어는 프레임 밖이어야 한다.** 하나라도 안이면 그 순간 메인이 읽으면 그리다 만
        // 화면이다 — 이 저장소가 실기에서 본 바로 그 상태다.
        mutex.lockUncancelable(std.testing.io);
        const mid_frame = core.sync_output;
        const bsu_n = core.sync_bsu_count;
        const esu_n = core.sync_esu_count;
        mutex.unlock(std.testing.io);
        try std.testing.expect(!mid_frame);
        try std.testing.expectEqual(bsu_n, esu_n);
    }

    // 그리고 **바이트를 하나도 안 잃는다** — 마지막 프레임까지 다 들어갔다.
    mutex.lockUncancelable(std.testing.io);
    const total_frames = core.sync_esu_count;
    mutex.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u64, 3), total_frames);
    try std.testing.expectEqual(@as(usize, 0), reader.sync_held_len);
}

test "sync(2026): 2026 을 안 쓰는 스트림은 보류도 복사도 없이 그대로 흐른다" {
    // 이 축이 켜졌다고 평범한 셸 출력이 한 tick 늦으면 안 된다. 보류 버퍼는 **첫 프레임을 만날 때만**
    // 잡히므로, 2026 이 없는 스트림은 할당조차 안 일어난다.
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var session: pty.PtySession = undefined;
    var reader = PtyReader.init(allocator, 12, &session, &queue);
    defer reader.deinit();

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 4 });
    defer core.deinit();
    var mutex: std.Io.Mutex = .init;
    reader.setProcessing(&core, &mutex, std.testing.io);
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var out_head: usize = 0;

    reader.applySyncFramed(&core, &mutex, "hello ", &out_buf, &out_head);
    reader.applySyncFramed(&core, &mutex, "world", &out_buf, &out_head);
    try std.testing.expectEqual(@as(usize, 0), reader.sync_held_len);
    try std.testing.expectEqual(@as(?[]u8, null), reader.sync_held_buf); // 할당 자체가 없다
}

test "sync(2026): 끝나지 않는 프레임은 상한에서 접어 스트림을 안 막는다" {
    // 프레임 «안에서» 질의를 보내고 답을 기다리는 앱이 있으면 보류가 곧 교착이 된다. 그래서
    // 상한을 넘기면 들고 있던 것을 그대로 코어에 넣는다 — **교착 대신 그리다 만 프레임**(오늘 동작)이다.
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var session: pty.PtySession = undefined;
    var reader = PtyReader.init(allocator, 13, &session, &queue);
    defer reader.deinit();

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 4 });
    defer core.deinit();
    var mutex: std.Io.Mutex = .init;
    reader.setProcessing(&core, &mutex, std.testing.io);
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var out_head: usize = 0;

    // BSU 만 보내고 ESU 를 안 준다 — 상한을 넘길 때까지 본문만 흘린다.
    reader.applySyncFramed(&core, &mutex, sync_frame_split.bsu, &out_buf, &out_head);
    try std.testing.expect(reader.sync_held_len > 0); // 들고 있다
    const filler = "x" ** 4096;
    var sent: usize = 0;
    while (sent <= PtyReader.sync_held_max) : (sent += filler.len) {
        reader.applySyncFramed(&core, &mutex, filler, &out_buf, &out_head);
    }
    // 접혔다 — 코어가 BSU 를 봤고(프레임 안), 보류는 상한 아래로 돌아왔다.
    mutex.lockUncancelable(std.testing.io);
    const saw_bsu = core.sync_bsu_count;
    mutex.unlock(std.testing.io);
    try std.testing.expect(saw_bsu >= 1);
    try std.testing.expect(reader.sync_held_len <= PtyReader.sync_held_max);
}
