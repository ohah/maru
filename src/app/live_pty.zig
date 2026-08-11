const builtin = @import("builtin");
const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("../session/surface.zig");
const pty_reader = @import("pty_reader.zig");
const core_command = @import("../session/core_command.zig");
const control_surface = @import("../session/control_surface.zig"); // SurfaceKind(terminal|web) — union 태그(web-panel.md §6 4e)

extern "c" fn usleep(usec: c_uint) c_int;

/// 입력 방향 write 큐 버퍼링 상한(바이트). 키 입력은 작아 paste 뒤에 막히지 않을 만큼 넉넉하게 두고, 큰
/// paste는 per-tick enqueueSome으로 흘려보낸다(상한 초과분은 다음 tick). 사전 할당 없이 필요 시 이만큼까지 grow.
const pty_write_queue_capacity: usize = 1 << 18; // 256 KiB

/// 위임 명령 큐 상한(대기 명령 수). 명령은 작고 드문 UI 이벤트(IME·스크롤·선택)라 넉넉. 포화 시 메인이
/// backpressure로 잠깐 대기(손실 금지) — write_queue와 같은 계약(docs/plans/io-render-threading.md §9.2).
const pty_command_queue_capacity: usize = 1024;

// reader의 응답(코어 query reply) outbound 버퍼 상한은 pty_reader.response_buffer_capacity에 있다(write_queue·
// command_queue와 함께 세 outbound가 모두 bound된다). 그 결정·근거의 단일 출처는 docs/plans/io-render-threading.md §8.8(3)다.

/// 단일 writer 라우팅(docs/plans/io-render-threading.md §8 P2-3b): 메인 입력을 직접 세션에 쓰지 않고 write 큐에
/// enqueue + I/O 스레드 wake. PtyIo.ctx가 이 구조를 가리킨다(LivePtySession이 핀 고정해 주소 안정). resize는
/// 바이트 스트림이 아니라 ioctl이라 큐를 안 거치고 세션에 바로 전달한다(write(2) 바이트와 독립이라 안전).
///
/// producer 불변식: `writeInput`/`enqueueCommand` 호출은 AppSession 메인 실행 흐름 또는 host connection
/// dispatcher 한 곳에서 직렬화된다. `enqueuedTotal()` 스냅샷과 command enqueue는 이 불변식 아래 하나의 논리
/// 연산이다. 향후 여러 producer가 같은 runtime을 직접 호출하게 되면 두 큐를 공유 sequence lock으로 묶거나
/// 하나의 tagged queue로 합치기 전에는 이 타입을 그대로 공유하면 안 된다.
const WriteQueueIo = struct {
    write_queue: *pty_reader.PtyWriteQueue,
    command_queue: *pty_reader.CoreCommandQueue,
    session: *pty.PtySession,

    fn writeInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        try self.write_queue.enqueueBlocking(bytes); // 키/스크롤: 전량 보장(포화 시 backpressure)
        self.session.signalWrite();
    }

    /// Phase 3 위임(docs/plans/io-render-threading.md §9 P3-2~): 메인발 코어 mutate를 명령 큐에 enqueue(복사+포화 시
    /// backpressure)하고 reader poll을 wake한다 — write_queue와 같은 self-pipe wake 재사용. reader가 같은 루프에서
    /// pop해 락 아래 적용한다. PtyIo.enqueue_command가 이 함수를 가리킨다(interactive 백엔드만).
    fn enqueueCommand(ctx: *anyopaque, cmd: core_command.CoreCommand) !void {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        // 같은 producer가 앞서 enqueue한 input의 누적 끝을 fence로 함께 기록한다. reader는 그 prefix를 실제 PTY에
        // 쓴 뒤에만 명령을 적용하므로 `input A → focus reply → input B`가 별도 두 큐에서도 뒤집히지 않는다.
        try self.command_queue.enqueueAfterInput(cmd, self.write_queue.enqueuedTotal());
        self.session.signalWrite();
    }

    fn writeInputNonBlocking(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        const n = try self.write_queue.enqueueSome(bytes); // paste: 들어가는 만큼만(잔량은 다음 tick)
        if (n > 0) self.session.signalWrite();
        return n;
    }

    fn resize(ctx: *anyopaque, size: terminal.Size) !void {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        try self.session.resize(size);
    }
};

pub const LivePtySession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *pty.PtySession,
    queue: *pty_reader.PtyEventQueue,
    write_queue: *pty_reader.PtyWriteQueue,
    command_queue: *pty_reader.CoreCommandQueue,
    // PtyIo.ctx로 넘길 안정 저장(interactive 라우팅). init에서 채운다. 핀 고정 불변식 덕에 주소가 안정적.
    write_io_ctx: WriteQueueIo = undefined,
    reader: pty_reader.PtyReader,
    pty_id: runtime_mod.PtyId,
    link: ?runtime_mod.RuntimeLink = null,
    reader_finished: bool = false,
    reader_failed: bool = false,

    pub fn init(
        self: *LivePtySession,
        io: std.Io,
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        request: pty.SpawnRequest,
        queue_capacity: usize,
    ) !void {
        const session = try pty.PtySession.spawn(allocator, request);
        return self.initWithSession(io, allocator, pty_id, session, queue_capacity);
    }

    /// Exec-restore용 초기화. `PreparedAdoption.materialize`가 만든 session은
    /// child lifecycle을 아직 소유하지 않으므로, 이후 queue allocation이나
    /// reader 준비가 실패해 normal `deinit`을 타도 child를 signal/reap하지 않는다.
    pub fn initPreparedAdoption(
        self: *LivePtySession,
        io: std.Io,
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        adoption: *pty.PtySession.PreparedAdoption,
        queue_capacity: usize,
    ) !void {
        const session = adoption.materialize();
        return self.initWithSession(io, allocator, pty_id, session, queue_capacity);
    }

    fn initWithSession(
        self: *LivePtySession,
        io: std.Io,
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        session_value: pty.PtySession,
        queue_capacity: usize,
    ) !void {
        var owned_session = session_value;
        var session_transferred = false;
        defer if (!session_transferred) owned_session.deinit();
        // 이 타입은 live process, fd, reader thread, queue를 한 단위로 소유한다.
        // 호출자가 각각의 deinit/close 순서를 기억하게 두면 실제 tab close와 smoke cleanup이
        // 서로 다른 수명 규칙을 갖게 되므로, app layer에는 이 owner만 노출한다.
        self.* = .{
            .allocator = allocator,
            .io = io,
            .session = undefined,
            .queue = undefined,
            .write_queue = undefined,
            .command_queue = undefined,
            .reader = undefined,
            .pty_id = pty_id,
        };

        // PtyReader는 session/queue 포인터를 들고 실행된다. 이 두 객체는 owner가 heap에
        // 고정하므로 reader thread가 읽는 session/queue는 안정적이다.
        //
        // 불변식: 단, reader thread는 `&self.reader`(이 구조체 안의 embedded reader 필드)도
        // 잡고 실행된다. heap 고정은 session/queue 객체만 보호하고 reader self 포인터는
        // 보호하지 않으므로, init()으로 reader.start()가 실행된 뒤에는 이 LivePtySession 값을
        // 절대 이동/복사하면 안 된다(by-value 반환, realloc되는 ArrayList/HashMap 저장 등).
        // 모든 호출부는 고정 지역변수(`var x: LivePtySession = undefined; x.init(&x, ...)`)로
        // 제자리에서 소유한다. 값 이동이 필요해지면 reader도 heap-pin하거나 LivePtySession
        // 자체를 heap에 둬야 한다.
        self.session = try allocator.create(pty.PtySession);
        var session_allocated = true;
        errdefer if (session_allocated) allocator.destroy(self.session);
        self.session.* = owned_session;
        session_transferred = true;
        var session_initialized = true;
        errdefer if (session_initialized) self.session.deinit();

        self.queue = try allocator.create(pty_reader.PtyEventQueue);
        var queue_allocated = true;
        errdefer if (queue_allocated) allocator.destroy(self.queue);
        self.queue.* = try pty_reader.PtyEventQueue.init(io, allocator, queue_capacity);
        var queue_initialized = true;
        errdefer if (queue_initialized) self.queue.deinit();

        // 입력 방향 단일-writer 큐(docs/plans/io-render-threading.md §8 P2-3b): interactive 세션에서 메인 입력이
        // 이리로 들어오면 reader가 같은 poll 루프에서 drain해 PTY로 write한다(유일한 writer). 사전 할당 없이
        // cap까지 grow하므로 non-interactive 세션에선 사실상 0바이트(idle). 라우팅은 attachSurface가 켠다.
        self.write_queue = try allocator.create(pty_reader.PtyWriteQueue);
        var write_queue_allocated = true;
        errdefer if (write_queue_allocated) allocator.destroy(self.write_queue);
        self.write_queue.* = try pty_reader.PtyWriteQueue.init(io, allocator, pty_write_queue_capacity);
        var write_queue_initialized = true;
        errdefer if (write_queue_initialized) self.write_queue.deinit();

        // 위임 명령 큐(Phase 3, P3-2~): interactive 세션에서 메인발 코어 mutate가 이리로 enqueue되고 reader가 pop해
        // 락 아래 적용한다. write_queue와 같은 결(미사용이면 idle).
        self.command_queue = try allocator.create(pty_reader.CoreCommandQueue);
        var command_queue_allocated = true;
        errdefer if (command_queue_allocated) allocator.destroy(self.command_queue);
        self.command_queue.* = try pty_reader.CoreCommandQueue.init(io, allocator, pty_command_queue_capacity);
        var command_queue_initialized = true;
        errdefer if (command_queue_initialized) self.command_queue.deinit();

        // PtyIo ctx 안정 저장(LivePtySession이 핀 고정되므로 &self.write_io_ctx도 안정). 단일 writer + 명령 라우팅용.
        self.write_io_ctx = .{ .write_queue = self.write_queue, .command_queue = self.command_queue, .session = self.session };

        self.reader = pty_reader.PtyReader.init(allocator, pty_id, self.session, self.queue);
        errdefer {
            queue_allocated = false;
            queue_initialized = false;
            write_queue_allocated = false;
            write_queue_initialized = false;
            command_queue_allocated = false;
            command_queue_initialized = false;
            session_allocated = false;
            session_initialized = false;
            self.command_queue.deinit();
            allocator.destroy(self.command_queue);
            self.write_queue.deinit();
            allocator.destroy(self.write_queue);
            self.queue.deinit();
            allocator.destroy(self.queue);
            self.session.deinit();
            allocator.destroy(self.session);
            self.* = undefined;
        }

        // reader.start()는 attachSurface로 옮겼다 — 거기서 (interactive면) setProcessing으로 코어/락/io를
        // 주입한 뒤 활성화 상태로 시작한다(docs/io-render-threading.md PR3). init-start 뒤 활성화하면
        // pre-attach 출력이 큐로 새 순서가 어긋날 수 있어, 처음부터 알맞은 모드로 시작한다.
        queue_allocated = false;
        queue_initialized = false;
        write_queue_allocated = false;
        write_queue_initialized = false;
        command_queue_allocated = false;
        command_queue_initialized = false;
        session_allocated = false;
        session_initialized = false;
    }

    pub fn deinit(self: *LivePtySession) void {
        self.close();
        self.reader.deinit();
        self.command_queue.deinit();
        self.allocator.destroy(self.command_queue);
        self.write_queue.deinit();
        self.allocator.destroy(self.write_queue);
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.* = undefined;
    }

    /// process_in_reader=true면 리더가 출력을 직접 코어에 적용·응답한다(docs/io-render-threading.md PR3 —
    /// 렌더 tick에 안 묶여 즉시 응답). interactive 세션만 켠다. controlled_smoke/테스트는 false로 둬 기존
    /// 큐-드레인 경로를 유지한다(테스트가 코어를 메인 스레드에서 직접 조작하므로, 리더 처리와 경합하지 않게).
    /// 어느 경우든 reader.start()는 여기서(attach 후) 한다 — 활성 모드로 시작해 pre-attach 순서 문제를 없앤다.
    pub fn attachSurface(
        self: *LivePtySession,
        runtime: *runtime_mod.SurfaceRuntime,
        surface: *surface_mod.Surface,
        process_in_reader: bool,
    ) (runtime_mod.RuntimeError || std.Thread.SpawnError)!runtime_mod.RuntimeLink {
        const link = try self.attachSurfaceConfigured(runtime, surface, process_in_reader);
        self.reader.start() catch |err| {
            runtime.detachSurface(link.surface_id);
            self.link = null;
            return err;
        };
        return link;
    }

    /// Restore graph가 reader thread 생성 가능성을 authority commit 전에
    /// 증명하는 경로. Thread는 start gate에서 대기하므로 release 전에는
    /// session/queue/core를 한 번도 역참조하지 않는다.
    pub fn attachSurfacePrepared(
        self: *LivePtySession,
        runtime: *runtime_mod.SurfaceRuntime,
        surface: *surface_mod.Surface,
    ) (runtime_mod.RuntimeError || std.Thread.SpawnError)!runtime_mod.RuntimeLink {
        const link = try self.attachSurfaceConfigured(runtime, surface, true);
        self.reader.startPrepared() catch |err| {
            runtime.detachSurface(link.surface_id);
            self.link = null;
            return err;
        };
        return link;
    }

    fn attachSurfaceConfigured(
        self: *LivePtySession,
        runtime: *runtime_mod.SurfaceRuntime,
        surface: *surface_mod.Surface,
        process_in_reader: bool,
    ) runtime_mod.RuntimeError!runtime_mod.RuntimeLink {
        // attach link도 live PTY owner가 기록한다. closeAndDetach가 이 link를 이용해
        // runtime routing을 먼저 끊으므로, 어느 PTY가 어느 surface와 연결됐는지는
        // 이 owner가 알아야 한다.
        const link = try runtime.attach(surface, self.pty_id, self.ptyIo(process_in_reader));
        self.link = link;
        if (process_in_reader) {
            // 단일 writer(P2-3b): write_queue 주입을 setProcessing의 release-store 전에 둬 함께 publish하고,
            // 메인 입력은 ptyIo(true)가 돌려준 write-queue-backed PtyIo로 enqueue된다(직접 세션 write 없음).
            self.reader.setWriteQueue(self.write_queue);
            // Phase 3 위임(P3-2~): 명령 큐도 같은 publish 창에 주입한다 — 메인발 코어 mutate(IME 등)를 reader가
            // pop해 락 아래 적용한다(메인 직접 mutate 없음, §9.3). 메인은 ptyIo(true)의 enqueue_command로 보낸다.
            self.reader.setCommandQueue(self.command_queue);
            self.reader.setProcessing(&surface.core, &surface.core_mutex, self.io);
        }
        return link;
    }

    pub fn preparedStartReached(self: *const LivePtySession) bool {
        return self.reader.preparedStartReached();
    }

    /// Host-global graph가 전량 호출한 뒤에만 ownership commit 가능하다.
    pub fn revalidatePreparedOwnership(self: *const LivePtySession) !void {
        if (!self.reader.preparedStartReached()) return error.ReaderNotPrepared;
        try self.session.revalidatePreparedOwnership();
    }

    /// 전량 revalidate 뒤의 실패 불가능한 child lifecycle owner 승격.
    pub fn commitPreparedOwnership(self: *LivePtySession) void {
        self.session.commitPreparedOwnership();
    }

    pub fn releasePreparedStart(self: *LivePtySession) void {
        self.reader.releasePreparedStart();
    }

    /// Authority commit 전 restore 실패 전용 teardown. Gate를 abort/join한
    /// 뒤 routing과 process-local storage만 해제한다. Session의
    /// `owns_child_lifecycle=false`가 child signal/waitpid를 차단한다.
    pub fn discardPreparedAdoption(
        self: *LivePtySession,
        runtime: *runtime_mod.SurfaceRuntime,
    ) void {
        self.reader.discardPreparedStart();
        self.detachSurface(runtime);
        self.deinit();
    }

    /// interactive(process_in_reader=true)면 메인 입력을 write_queue로 보내는 PtyIo(단일 writer, P2-3b).
    /// 그 외(controlled smoke/테스트)는 세션 직접 write — reader가 readEvent 경로라 write_queue를 drain하지
    /// 않으므로 큐로 보내면 안 나간다(직접 경로 유지).
    pub fn ptyIo(self: *LivePtySession, process_in_reader: bool) runtime_mod.PtyIo {
        if (process_in_reader) {
            return .{
                .ctx = &self.write_io_ctx,
                .write_input = WriteQueueIo.writeInput,
                .resize_fn = WriteQueueIo.resize,
                .write_input_nb = WriteQueueIo.writeInputNonBlocking,
                .enqueue_command = WriteQueueIo.enqueueCommand,
            };
        }
        return runtime_mod.PtyIo.fromSession(self.session);
    }

    pub fn eventQueue(self: *LivePtySession) *pty_reader.PtyEventQueue {
        return self.queue;
    }

    /// 실제 PTY reader가 받은 누적 raw bytes. processing 모드의 queue에는 빈 렌더 신호만
    /// 들어가므로 session-host RSS fixture는 이 reader-owned counter를 사용한다.
    pub fn outputBytesRead(self: *const LivePtySession) u64 {
        return self.reader.outputBytesRead();
    }

    pub fn setOutputByteCounter(
        self: *LivePtySession,
        counter: *std.atomic.Value(u64),
    ) void {
        self.reader.setOutputByteCounter(counter);
    }

    pub fn childPid(self: *const LivePtySession) std.c.pid_t {
        return self.session.childPid();
    }

    pub fn pump(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) runtime_pump.RuntimeEventPump {
        return runtime_pump.RuntimeEventPump.init(self.allocator, self.queue, runtime);
    }

    pub fn finishAfterTermination(self: *LivePtySession) void {
        // drain이 exit/read_error를 본 뒤에는 reader thread가 더 할 일이 없다.
        // 여기서 정상 join을 기록해 이후 artifact 작성 중 오류가 나도 close cleanup이
        // 이미 종료된 reader를 다시 stop하지 않게 한다.
        if (!self.reader_finished) {
            self.reader.join();
            self.reader_finished = true;
        }
        // 종료 관측 시점에 child를 직접 종료/reap한다. 정상 exit 경로는 reader가 EOF에서
        // 이미 reap했으므로 session.close()가 atomic 가드로 no-op이지만, read_error처럼
        // reader가 child를 reap하지 않고 끝난 경로에서는 여기서 reap해야 한다. 이 단계를
        // 빼면 reader_finished=true 이후의 close()/closeAndDetach 수명 경계가 else 분기로
        // 빠져 session.close()를 부르지 않으므로, child가 deinit() 전까지 좀비로 남는다.
        self.session.close();
        self.queue.close();
        self.write_queue.close(); // 단일 writer: 메인이 enqueueBlocking 대기 중이면 QueueClosed로 풀어준다
        self.command_queue.close(); // 위임 명령 큐도 닫아 메인 enqueue 대기를 QueueClosed로 푼다(미적용 명령 폐기)
    }

    /// reader I/O 오류는 child 종료 증거가 아니다. host owner drain은 thread handle만 회수하고 PTY/child를
    /// 살려 unusable runtime으로 남긴다. 사용자가 명시적으로 close할 때 아래 close의 reader_finished 분기가
    /// session.close를 호출해 그때 child를 정리한다.
    pub fn finishAfterReadError(self: *LivePtySession) void {
        if (!self.reader_finished) {
            self.reader.join();
            self.reader_finished = true;
            self.reader_failed = true;
        }
    }

    /// Host upgrade가 child/fd/queue를 건드리지 않고 reader safe-point를 요청한다.
    pub fn requestUpgradePause(self: *LivePtySession) !void {
        if (self.reader_finished) return error.ReaderFinished;
        try self.reader.requestPause();
    }

    pub fn upgradePauseReached(self: *const LivePtySession) bool {
        return !self.reader_finished and self.reader.pauseReached();
    }

    /// reader가 safe-point를 publish한 뒤 thread handle만 회수한다. PTY와 queue는 열린 채다.
    pub fn joinUpgradePause(self: *LivePtySession) bool {
        if (self.reader_finished or !self.reader.pauseReached()) return false;
        self.reader.join();
        return self.reader.pausedStateIsSafe();
    }

    /// U2 실패 rollback. 이미 join된 paused reader만 같은 owner graph 위에서 다시 시작한다.
    pub fn resumeAfterUpgradePause(self: *LivePtySession) !void {
        if (self.reader_finished) return error.ReaderFinished;
        try self.reader.resumeAfterPause();
    }

    pub fn prepareResumeAfterUpgradePause(self: *LivePtySession) !void {
        if (self.reader_finished) return error.ReaderFinished;
        try self.reader.prepareResumeAfterPause();
    }

    pub fn releasePreparedUpgradeResume(self: *LivePtySession) void {
        self.reader.releasePreparedResume();
    }

    pub fn discardPreparedUpgradeResume(self: *LivePtySession) void {
        self.reader.discardPreparedResume();
    }

    pub fn cancelUpgradePause(self: *LivePtySession) bool {
        if (self.reader_finished) return false;
        return self.reader.cancelPause();
    }

    pub fn upgradeEligible(self: *LivePtySession) bool {
        // Coalesced output signal은 pause 요청과 경합해 다시 생길 수 있으므로 phase-1 eligibility에서 empty를
        // 요구하지 않는다. 모든 reader join 뒤 owner drain이 queue empty를 final gate로 검증한다.
        return !self.reader_finished and self.session.upgradeEligible();
    }

    pub fn upgradePausedAndSafe(self: *LivePtySession) bool {
        return !self.reader_finished and self.reader.pausedStateIsSafe() and self.queue.emptyAndOpen();
    }

    pub fn detachSurface(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) void {
        // Pane close는 surface routing부터 끊어야 한다. 그래야 닫힌 pane으로 늦게 도착한
        // output이나 input이 살아 있는 surface에 섞이지 않고 UnknownPty/UnknownSurface로
        // 떨어진다. 실제 PTY 종료는 close()가 맡고, detach는 runtime 연결만 제거한다.
        if (self.link) |link| {
            runtime.detachSurface(link.surface_id);
            self.link = null;
        }
    }

    pub fn closeAndDetach(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) void {
        // 실제 tab/window close command가 호출할 app-layer 수명 경계다.
        // detach와 PTY close 순서를 호출자마다 다시 쓰게 두면 late event 처리와 reader
        // cleanup이 갈라질 수 있으므로, owner가 하나의 idempotent operation으로 제공한다.
        self.detachSurface(runtime);
        self.close();
    }

    pub fn close(self: *LivePtySession) void {
        // 조기 실패, tab close, app quit은 같은 종료 순서를 타야 한다.
        // PtyReader.stopAndJoin이 queue.close -> session.close -> reader.join 순서를 소유하고,
        // 이 owner는 그 순서가 최대 한 번만 실행되도록 상태를 보관한다.
        // write_queue도 닫아, 메인이 enqueueBlocking에서 backpressure 대기 중이면 QueueClosed로 풀어준다
        // (단일 writer, §8.6 close-with-pending-write). close()는 idempotent.
        self.write_queue.close();
        self.command_queue.close(); // 위임 명령 큐도 닫는다(메인 enqueue 대기 → QueueClosed, 미적용 명령 폐기)
        if (!self.reader_finished) {
            self.reader.stopAndJoin();
            self.reader_finished = true;
        } else {
            self.queue.close();
            // read_error로 thread만 먼저 join한 runtime도 최종 close에서는 child를 종료/reap해야 한다.
            if (self.reader_failed) self.session.close();
        }
    }
};

/// M3a: 한 surface의 라이브 소유 **번들**(docs/window-surface-mobility.md §8A.1 옵션 A). registry가 이 번들을
/// heap 슬롯으로 개별 소유(`allocator.create(LiveSurface)`)하므로, terminal arm의 `&slot.terminal.surface.core`/
/// `&slot.terminal.surface.core_mutex`(reader 바인딩)와 `&slot.terminal.live_pty.reader`가 **창 밖 registry 슬롯에
/// 고정**된다 — Term이 heap-pin이라 안정하던 것을 registry 슬롯 고정으로 옮긴 것(cross-window 이동 시 Term은 창을
/// 옮겨도 이 슬롯 주소는 불변, reader 계약 보존).
///
/// **4e-1: `union(SurfaceKind)`으로 승격**(web-panel.md §6 "web surface는 Term"). terminal arm은 M3a 번들 그대로
/// (surface + live PTY), web arm은 **sentinel surface만**(빈 core — 렌더/PTY 없음, WKWebView는 Swift가 surfaceDiff로
/// 별도 구동). 두 arm이 **모두** `surface: Surface`를 노출하므로 `Term.surface: *Surface`가 web에서도 유효해
/// surface_ptrs 재바인딩·activeSurface() 계약이 **불변**이다(sentinel의 `id`가 web surface_id를 든다). 기본 태그가
/// 없어 caller(createTerm/createWebTerm)가 `slot.* = .{ .terminal = … }` / `.{ .web = … }`로 arm을 확정한 뒤 arm
/// 필드를 in-place init한다. registry(live_surface_registry.zig)는 `Rt.deinit()`만 부르므로 union도 struct처럼
/// **중립**(registry·removeUninitialized 코드 무변경).
///
/// Term은 `surface: *Surface`(양 arm의 `surface`)·`rt.live_pty: *LivePtySession`(terminal arm만)로 슬롯 필드를 참조만
/// 한다(소유 아님). web Term은 live PTY가 없어 `rt.live_pty`를 세우지 않고 `rt.live_initialized=false`로 둔다.
pub const LiveSurface = union(control_surface.SurfaceKind) {
    /// terminal arm(M3a 번들 그대로): surface(그리드/스크롤백) + 그 surface에 붙은 live PTY 셸.
    terminal: Terminal,
    /// web arm: sentinel surface만(빈 core — 4e-1은 렌더 안 함). WKWebView 부착·콘텐츠는 후속(4e-3/Phase 5).
    web: Web,

    /// terminal Term의 라이브 소유(surface + live PTY + 번들 allocator). 필드·수명은 M3a와 동일.
    pub const Terminal = struct {
        surface: surface_mod.Surface = undefined,
        live_pty: LivePtySession = undefined,
        /// 번들 **내부**(core·session/queue·surface owned string)를 만든 창 allocator. teardown이 `custom_name`
        /// 해제에 쓴다 — `Surface.deinit`엔 allocator가 없어(§ surface.zig) owned string 해제를 번들이 흡수한다
        /// (§8A.1). live_pty 내부(session/queue)는 `LivePtySession`이 자기 allocator를 들고 자족한다.
        internal_allocator: std.mem.Allocator = undefined,
    };

    /// web Term의 라이브 소유(sentinel surface + 번들 allocator). PTY/reader 없음 — teardown이 경량(reader join
    /// 없이 custom_name 해제 + sentinel surface.deinit). panel_kind는 여기 두지 않고 `Term.web_panel_kind`가 단일
    /// 출처(중복 저장 없이) — web arm은 registry 안정 heap 슬롯이 필요한 sentinel `Surface`만 든다.
    ///
    /// **§7 종료 placeholder(묘비)도 이 arm을 쓴다.** 필요한 것이 정확히 같기 때문이다 — PTY 없는 안정 heap 슬롯 +
    /// 경량 teardown. 다만 그 Term의 `kind`는 **`.terminal`** 이다(렌더·라벨 경로를 그대로 타야 하므로). 즉 이
    /// union의 arm 태그와 `Term.kind`가 일치하지 않을 수 있으니, **arm 태그로 `Term.kind`를 파생하지 말 것**.
    /// 반대 방향(`Term.kind`/`rt.ended_placeholder`로 teardown을 가르는 것)은 `destroyTerm`·세션 `deinit`이 한다.
    pub const Web = struct {
        surface: surface_mod.Surface = undefined,
        internal_allocator: std.mem.Allocator = undefined,
    };

    /// registry.remove/deinit이 부르는 번들 teardown. **arm 분기**: terminal은 `live_pty.deinit`(reader thread join —
    /// reader가 `&surface.core`를 잡음) → `surface` owned string 해제 → `surface.deinit`; web은 reader가 없어 경량
    /// (custom_name 해제 → sentinel surface.deinit). detach(라우팅)는 coordinator가 remove **전에** terminal에 한해
    /// `closeAndDetach`로 선행한다(§8A.1·live_surface_registry.zig remove 계약). closeAndDetach가 이미 reader를
    /// join했으면 여기 live_pty.deinit의 close는 멱등 no-op join이라 순서가 안전하다.
    pub fn deinit(self: *LiveSurface) void {
        switch (self.*) {
            .terminal => |*t| {
                t.live_pty.deinit();
                if (t.surface.custom_name) |n| t.internal_allocator.free(n);
                t.surface.deinit();
            },
            .web => |*w| {
                if (w.surface.custom_name) |n| w.internal_allocator.free(n);
                w.surface.deinit();
            },
        }
        self.* = undefined;
    }
};

// 4e-1: web arm sentinel teardown이 reader join 없이 경량(custom_name 해제 + sentinel surface.deinit)이고 누수 0임을
// 헤드리스로 못박는다(web-panel.md §6). terminal arm(reader join)은 실제 PTY가 필요해 별도(macOS) 경로이고, 여기선
// web arm만 — PTY/reader가 전혀 없어 순수 Zig로 leak을 testing.allocator가 검증한다. non-vacuous: custom_name(owned)을
// 안 해제하거나 sentinel surface.core를 안 deinit하면 testing.allocator가 leak으로 실패한다.
test "live surface web arm: sentinel teardown frees core + owned custom_name (leak 0, headless)" {
    const allocator = std.testing.allocator;
    var slot: LiveSurface = .{ .web = .{ .internal_allocator = allocator } };
    slot.web.surface = try surface_mod.Surface.init(allocator, 4242, .{ .cols = 1, .rows = 1 });
    // web Term의 사용자 rename(owned) — teardown이 internal_allocator로 해제해야 한다(web arm은 reader join 없이 경량).
    slot.web.surface.custom_name = try allocator.dupe(u8, "docs");
    // deinit이 union arm 분기(web) — custom_name free + sentinel surface.deinit(빈 core 해제). leak이면 실패.
    slot.deinit();
}

test "live pty session owns controlled command until normal termination" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var live: LivePtySession = undefined;
    try live.init(std.testing.io, allocator, 10, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf 'live owner\\n'" },
        .size = .{ .cols = 20, .rows = 3 },
    }, 4);
    defer live.deinit();
    // start는 attachSurface로 옮겼으므로(PR3) 이 standalone 리더-큐 경로 테스트는 직접 시작한다.
    // setProcessing 없이 → processing=false → 기존처럼 바이트를 큐에 넣는다(이 경로 검증).
    try live.reader.start();

    var saw_output = false;
    while (true) {
        const event = live.eventQueue().popBlocking() orelse return error.LivePtyQueueClosedTooEarly;
        defer event.deinit(allocator);

        switch (event) {
            .output => |output| {
                if (std.mem.indexOf(u8, output.bytes, "live owner") != null) {
                    saw_output = true;
                }
            },
            .exited => break,
            .read_error => return error.LivePtyReadError,
        }
    }

    live.finishAfterTermination();
    try std.testing.expect(saw_output);
    try std.testing.expect(live.reader_finished);
}

test "processing reader replaces a full render signal with exit and closes outbound queues" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var live: LivePtySession = undefined;
    try live.init(std.testing.io, allocator, 11, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf x" },
        .size = .{ .cols = 20, .rows = 3 },
    }, 1); // 첫 output 신호 하나만으로 event queue를 포화시킨다.
    defer live.deinit();

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    var core_mutex: std.Io.Mutex = .init;
    live.reader.setWriteQueue(live.write_queue);
    live.reader.setCommandQueue(live.command_queue);
    live.reader.setProcessing(&core, &core_mutex, std.testing.io);
    try live.reader.start();

    // consumer가 렌더 신호를 비우지 않은 채 child가 EOF를 낸다. old blocking push는 여기서 join을 영구
    // 대기시켰다. processing 전용 terminal replacement는 빈 신호를 exit로 바꾸고 close defer까지 도달한다.
    live.reader.join();
    live.reader_finished = true;
    const event = live.eventQueue().popBlocking() orelse return error.LivePtyQueueClosedTooEarly;
    switch (event) {
        .exited => {},
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.QueueClosed, live.write_queue.enqueueBlocking("late"));
    try std.testing.expectError(error.QueueClosed, live.command_queue.enqueueBlocking(.scroll_to_bottom));
}

test "processing reader pauses without closing child or queues and resumes at the next unread PTY byte" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 77, .{ .cols = 30, .rows = 3 });
    defer surface.deinit();
    var live: LivePtySession = undefined;
    try live.init(std.testing.io, allocator, 77, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf before; IFS= read -r line; printf 'after:%s' \"$line\"; sleep 5" },
        .size = .{ .cols = 30, .rows = 3 },
    }, 8);
    defer live.deinit();
    _ = try live.attachSurface(&runtime, &surface, true);
    const child_pid = live.session.child_pid;

    var pump = live.pump(&runtime);
    var saw_before = false;
    for (0..5000) |_| {
        _ = try pump.drainAvailable();
        surface.lockCore(std.testing.io);
        const dump = try surface.core.dumpUtf8(allocator);
        surface.unlockCore(std.testing.io);
        defer allocator.free(dump);
        if (std.mem.indexOf(u8, dump, "before") != null) {
            saw_before = true;
            break;
        }
        _ = usleep(1000);
    }
    try std.testing.expect(saw_before);
    _ = try pump.drainAvailable(); // safe-point eligibility: coalesced render signal도 owner가 비운다.

    try live.reader.requestPause();
    for (0..5000) |_| {
        if (live.reader.pauseReached()) break;
        _ = usleep(1000);
    }
    try std.testing.expect(live.reader.pauseReached());
    live.reader.join();
    try std.testing.expect(live.reader.pausedStateIsSafe());
    try std.testing.expectEqual(child_pid, live.session.child_pid);
    try std.testing.expect(!live.write_queue.closed);
    try std.testing.expect(!live.command_queue.closed);

    // Paused reader가 없는 동안 child가 만든 output은 core가 아니라 kernel PTY buffer에 남아야 한다.
    try live.session.writeInput("go\n");
    _ = usleep(20_000);
    surface.lockCore(std.testing.io);
    const paused_dump = try surface.core.dumpUtf8(allocator);
    surface.unlockCore(std.testing.io);
    defer allocator.free(paused_dump);
    try std.testing.expect(std.mem.indexOf(u8, paused_dump, "after:go") == null);

    try live.reader.resumeAfterPause();
    var saw_after = false;
    for (0..5000) |_| {
        _ = try pump.drainAvailable();
        surface.lockCore(std.testing.io);
        const dump = try surface.core.dumpUtf8(allocator);
        surface.unlockCore(std.testing.io);
        const contains_after = std.mem.indexOf(u8, dump, "after:go") != null;
        allocator.free(dump);
        if (contains_after) {
            saw_after = true;
            break;
        }
        _ = usleep(1000);
    }
    try std.testing.expect(saw_after);
    try std.testing.expectEqual(child_pid, live.session.child_pid);
}

test "upgrade pause drains query response, input fence, and core command in exact byte order with a full render queue" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 78, .{ .cols = 40, .rows = 4 });
    defer surface.deinit();
    var live: LivePtySession = undefined;
    try live.init(std.testing.io, allocator, 78, .{
        .command = "/bin/sh",
        .args = &.{
            "-c",
            "stty raw -echo; printf '\\033[?1004h\\033[6n'; IFS= read -r line; printf '%s' \"$line\" | od -An -tx1 | tr -d ' \\n'; printf '\\r\\n'; sleep 5",
        },
        .size = .{ .cols = 40, .rows = 4 },
    }, 1);
    defer live.deinit();
    _ = try live.attachSurface(&runtime, &surface, true);
    const io = live.ptyIo(true);

    // CPR 응답이 먼저 나가고, producer가 넣은 prefix, 그 input fence 뒤 focus response, suffix가 이어져야 한다.
    // capacity=1 render queue는 첫 output signal로 포화되지만 coalescing 신호라 reader/pause를 막지 않는다.
    // attach 직후 producer와 reader를 경주시켜서는 "query가 먼저 admission됐다"는 전제가 없다. 초기 output
    // signal이 queue를 채울 때까지 기다리면 query parse+response flush iteration이 끝났고, 아래 세 producer
    // 항목은 그 뒤의 정확한 FIFO가 된다.
    var attempts: usize = 0;
    while (attempts < 5000 and live.queue.count() == 0) : (attempts += 1) _ = usleep(1000);
    try std.testing.expectEqual(@as(usize, 1), live.queue.count());
    try io.writeInput("ABC");
    try io.enqueue_command.?(io.ctx, .{ .report_focus = true });
    try io.writeInput("DEF\n");
    try live.requestUpgradePause();
    attempts = 0;
    while (attempts < 5000 and !live.upgradePauseReached()) : (attempts += 1) _ = usleep(1000);
    try std.testing.expect(live.upgradePauseReached());
    try std.testing.expect(live.joinUpgradePause());
    try std.testing.expectEqual(@as(usize, 1), live.queue.count());
    const signal = live.queue.tryPop() orelse return error.TestUnexpectedResult;
    switch (signal) {
        .output => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(live.upgradePausedAndSafe());

    try live.resumeAfterUpgradePause();
    var pump = live.pump(&runtime);
    var ordered = false;
    attempts = 0;
    while (attempts < 5000 and !ordered) : (attempts += 1) {
        _ = try pump.drainAvailable();
        surface.lockCore(std.testing.io);
        const dump = try surface.core.dumpUtf8(allocator);
        surface.unlockCore(std.testing.io);
        ordered = std.mem.indexOf(
            u8,
            dump,
            "1b5b313b31524142431b5b49444546",
        ) != null;
        allocator.free(dump);
        if (!ordered) _ = usleep(1000);
    }
    try std.testing.expect(ordered);
}

const FakePty = struct {
    fn io(self: *FakePty) runtime_mod.PtyIo {
        return .{
            .ctx = self,
            .write_input = fakeWriteInput,
            .resize_fn = fakeResize,
        };
    }

    fn fakeWriteInput(ctx: *anyopaque, bytes: []const u8) !void {
        _ = ctx;
        _ = bytes;
    }

    fn fakeResize(ctx: *anyopaque, size: terminal.Size) !void {
        _ = ctx;
        _ = size;
    }
};

test "live pty closeAndDetach removes runtime routing before closing the queue" {
    // 이 테스트는 실제 macOS PTY 없이 close lifecycle의 app-level 계약을 고정한다.
    // 핵심은 닫힌 pane이 runtime link에서 먼저 빠지고, reader가 이미 끝난 session이면
    // close가 queue만 닫아도 idempotent하게 동작한다는 점이다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    const link = try runtime.attach(&surface, 10, fake_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var write_queue = try pty_reader.PtyWriteQueue.init(std.testing.io, allocator, 4096);
    var command_queue = try pty_reader.CoreCommandQueue.init(std.testing.io, allocator, 1024);
    defer command_queue.deinit();
    defer write_queue.deinit();
    var live: LivePtySession = .{
        .allocator = allocator,
        .io = std.testing.io,
        .session = undefined,
        .queue = &queue,
        .write_queue = &write_queue,
        .command_queue = &command_queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };

    live.closeAndDetach(&runtime);
    try std.testing.expect(live.link == null);
    try std.testing.expectError(error.UnknownSurface, runtime.writeInput(1, .{ .bytes = "x" }));
    try std.testing.expectError(error.UnknownPty, runtime.applyPtyEvent(.{
        .output = .{ .pty_id = 10, .bytes = "late output" },
    }, std.testing.io));
    try std.testing.expectError(error.QueueClosed, queue.tryPush(.{
        .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } },
    }));

    live.closeAndDetach(&runtime);
    try std.testing.expect(live.link == null);
}
