const builtin = @import("builtin");
const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("surface.zig");
const pty_reader = @import("pty_reader.zig");
const core_command = @import("core_command.zig");

/// 입력 방향 write 큐 버퍼링 상한(바이트). 키 입력은 작아 paste 뒤에 막히지 않을 만큼 넉넉하게 두고, 큰
/// paste는 per-tick enqueueSome으로 흘려보낸다(상한 초과분은 다음 tick). 사전 할당 없이 필요 시 이만큼까지 grow.
const pty_write_queue_capacity: usize = 1 << 18; // 256 KiB

/// 위임 명령 큐 상한(대기 명령 수). 명령은 작고 드문 UI 이벤트(IME·스크롤·선택)라 넉넉. 포화 시 메인이
/// backpressure로 잠깐 대기(손실 금지) — write_queue와 같은 계약(docs/io-render-threading.md §9.2).
const pty_command_queue_capacity: usize = 1024;

// 세 번째 outbound 경로(코어 query 응답)의 상한은 pty_reader.response_buffer_capacity에 있다 — 세 outbound
// (write_queue·command_queue·응답 버퍼)가 모두 bounded라는 §8 정책의 단일 출처를 한곳에서 보이게 교차 참조한다.

/// 단일 writer 라우팅(docs/io-render-threading.md §8 P2-3b): 메인 입력을 직접 세션에 쓰지 않고 write 큐에
/// enqueue + I/O 스레드 wake. PtyIo.ctx가 이 구조를 가리킨다(LivePtySession이 핀 고정해 주소 안정). resize는
/// 바이트 스트림이 아니라 ioctl이라 큐를 안 거치고 세션에 바로 전달한다(write(2) 바이트와 독립이라 안전).
const WriteQueueIo = struct {
    write_queue: *pty_reader.PtyWriteQueue,
    command_queue: *pty_reader.CoreCommandQueue,
    session: *pty.PtySession,

    fn writeInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        try self.write_queue.enqueueBlocking(bytes); // 키/스크롤: 전량 보장(포화 시 backpressure)
        self.session.signalWrite();
    }

    /// Phase 3 위임(docs/io-render-threading.md §9 P3-2~): 메인발 코어 mutate를 명령 큐에 enqueue(복사+포화 시
    /// backpressure)하고 reader poll을 wake한다 — write_queue와 같은 self-pipe wake 재사용. reader가 같은 루프에서
    /// pop해 락 아래 적용한다. PtyIo.enqueue_command가 이 함수를 가리킨다(interactive 백엔드만).
    fn enqueueCommand(ctx: *anyopaque, cmd: core_command.CoreCommand) !void {
        const self: *WriteQueueIo = @ptrCast(@alignCast(ctx));
        try self.command_queue.enqueueBlocking(cmd);
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

    pub fn init(
        self: *LivePtySession,
        io: std.Io,
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        request: pty.SpawnRequest,
        queue_capacity: usize,
    ) !void {
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
        self.session.* = try pty.PtySession.spawn(allocator, request);
        var session_initialized = true;
        errdefer if (session_initialized) self.session.deinit();

        self.queue = try allocator.create(pty_reader.PtyEventQueue);
        var queue_allocated = true;
        errdefer if (queue_allocated) allocator.destroy(self.queue);
        self.queue.* = try pty_reader.PtyEventQueue.init(io, allocator, queue_capacity);
        var queue_initialized = true;
        errdefer if (queue_initialized) self.queue.deinit();

        // 입력 방향 단일-writer 큐(docs/io-render-threading.md §8 P2-3b): interactive 세션에서 메인 입력이
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
        self.reader.start() catch |err| {
            runtime.detachSurface(link.surface_id);
            self.link = null;
            return err;
        };
        return link;
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
        }
    }
};

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
