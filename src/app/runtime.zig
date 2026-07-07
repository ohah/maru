const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const surface_mod = @import("../session/surface.zig");
const core_command = @import("../session/core_command.zig");
const TraceRecorder = @import("trace_recorder.zig").TraceRecorder; // MARU_TRACE 라이브 레코더(opt-in — host가 주입)

// PTY 출력의 제어 시퀀스를 찍는 진단 logger(드래그 시 zsh redraw 분석용). 게이트는 host가
// SurfaceRuntime.debug_input으로 주입한다(플랫폼 무관 — runtime은 libc/env에 직접 의존하지 않음).
const input_diag = std.log.scoped(.input);

// bytes를 사람이 읽을 escape 형태로 buf에 쓴다(ESC→\e, 제어→\xNN). 최대 cap까지, 넘으면 끝에 "...".
fn escapeForLog(bytes: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (bytes) |b| {
        if (n + 5 >= buf.len) {
            // 말줄임을 남은 칸만큼만 쓴다. 직전 반복이 4바이트(\xNN)를 써서 n이 buf.len-2까지
            // 갈 수 있어, 무조건 3바이트를 쓰면 버퍼를 한 칸 넘는다(OOB write).
            const ell = "...";
            const tail = @min(ell.len, buf.len - n);
            @memcpy(buf[n..][0..tail], ell[0..tail]);
            n += tail;
            break;
        }
        switch (b) {
            0x1b => {
                @memcpy(buf[n..][0..2], "\\e");
                n += 2;
            },
            '\r' => {
                @memcpy(buf[n..][0..2], "\\r");
                n += 2;
            },
            '\n' => {
                @memcpy(buf[n..][0..2], "\\n");
                n += 2;
            },
            0x20...0x7e => {
                buf[n] = b;
                n += 1;
            },
            else => {
                _ = std.fmt.bufPrint(buf[n..][0..4], "\\x{x:0>2}", .{b}) catch break;
                n += 4;
            },
        }
    }
    return buf[0..n];
}

pub const SurfaceId = u64;
pub const PtyId = u64;

pub const RuntimeError = std.mem.Allocator.Error || error{
    UnknownSurface,
    UnknownPty,
    SurfaceAlreadyAttached,
    PtyAlreadyAttached,
    ProcessExited,
    WriteFailed,
    ResizeFailed,
    ReadFailed,
    InvalidOutput,
};

pub const RuntimeLink = struct {
    surface_id: SurfaceId,
    pty_id: PtyId,
};

pub const TerminalInput = struct {
    bytes: []const u8,
};

pub const RuntimePtyEvent = union(enum) {
    output: struct {
        pty_id: PtyId,
        bytes: []const u8,
    },
    exited: struct {
        pty_id: PtyId,
        status: pty.ExitStatus,
    },
    read_error: struct {
        pty_id: PtyId,
        message: []const u8,
    },
};

// SurfaceRuntime은 실제 macOS PTY를 직접 알아서는 안 된다. 이 adapter는
// runtime이 필요한 "input 쓰기"와 "resize 전달"만 노출해서, routing 테스트가
// OS process 없이 fake PTY로 같은 계약을 검증할 수 있게 한다.
pub const PtyIo = struct {
    ctx: *anyopaque,
    write_input: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    resize_fn: *const fn (ctx: *anyopaque, size: terminal.Size) anyerror!void,
    // non-blocking 변형(없으면 writeInputNonBlocking이 blocking으로 폴백). 실제 PTY만 채운다.
    write_input_nb: ?*const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize = null,
    // Phase 3 위임 채널(docs/io-render-threading.md §9 P3-2~): 메인발 코어 mutate를 reader로 보낸다. interactive
    // 백엔드(live_pty WriteQueueIo)만 채운다 — null이면 위임 경로 없음(runtime이 직접 적용으로 폴백). 순환 import를
    // 피해 명령 타입은 중립 `core_command`에 둔다(opaque ctx로 큐 타입은 백엔드가 숨김).
    enqueue_command: ?*const fn (ctx: *anyopaque, cmd: core_command.CoreCommand) anyerror!void = null,

    pub fn fromSession(session: *pty.PtySession) PtyIo {
        return .{
            .ctx = session,
            .write_input = writeSessionInput,
            .resize_fn = resizeSession,
            .write_input_nb = writeSessionInputNonBlocking,
        };
    }

    pub fn writeInput(self: PtyIo, bytes: []const u8) !void {
        try self.write_input(self.ctx, bytes);
    }

    /// non-blocking 쓰기(가능한 만큼, 0이면 지금은 못 씀). 백엔드가 지원하지 않으면(fake 등)
    /// blocking 전체 쓰기로 폴백한다 — 테스트 더블이 큐 의미론을 깨지 않게.
    pub fn writeInputNonBlocking(self: PtyIo, bytes: []const u8) !usize {
        if (self.write_input_nb) |write_nb| return write_nb(self.ctx, bytes);
        try self.write_input(self.ctx, bytes);
        return bytes.len;
    }

    pub fn resize(self: PtyIo, size: terminal.Size) !void {
        try self.resize_fn(self.ctx, size);
    }

    fn writeSessionInput(ctx: *anyopaque, bytes: []const u8) !void {
        const session: *pty.PtySession = @ptrCast(@alignCast(ctx));
        try session.writeInput(bytes);
    }

    fn writeSessionInputNonBlocking(ctx: *anyopaque, bytes: []const u8) !usize {
        const session: *pty.PtySession = @ptrCast(@alignCast(ctx));
        return session.writeInputNonBlocking(bytes);
    }

    fn resizeSession(ctx: *anyopaque, size: terminal.Size) !void {
        const session: *pty.PtySession = @ptrCast(@alignCast(ctx));
        try session.resize(size);
    }
};

/// PTY 종료 상태를 trace process-exit code로. exited→code, signaled→128+시그널(POSIX 셸 관례), unknown→none.
fn exitCode(status: pty.ExitStatus) ?i32 {
    return switch (status) {
        .exited => |c| c,
        .signaled => |s| 128 + @as(i32, s),
        .unknown => null,
    };
}

pub const SurfaceRuntime = struct {
    allocator: std.mem.Allocator,
    links: std.ArrayList(Link) = .empty,
    // host가 켜면 PTY 출력의 제어 시퀀스를 진단 로깅한다(MARU_DEBUG 드래그 분석용). 기본 off.
    debug_input: bool = false,
    // host가 MARU_TRACE로 주입하는 라이브 trace 레코더(base kind output/resize/process-exit를 누적). null이면 기록 안 함
    // (opt-in — 분기 한 번, 오버헤드 0). 소유·수명은 host(app_session)가 관리하고 runtime은 이벤트만 흘린다.
    trace_recorder: ?*TraceRecorder = null,

    pub fn init(allocator: std.mem.Allocator) SurfaceRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SurfaceRuntime) void {
        self.links.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn attach(
        self: *SurfaceRuntime,
        surface: *surface_mod.Surface,
        pty_id: PtyId,
        pty_io: PtyIo,
    ) RuntimeError!RuntimeLink {
        // live handle은 Surface에 저장하지 않고 runtime의 연결 표에만 둔다.
        // 그래야 workspace restore가 저장 가능한 metadata와 process handle을 섞지 않는다.
        // routing key는 surface가 이미 가진 id를 그대로 쓴다. 별도 surface_id 인자를
        // 받으면 surface.id와 어긋나 detachSurface가 link을 못 찾는 stale link가 생길 수 있다.
        const surface_id = surface.id;
        if (self.findBySurface(surface_id) != null) return error.SurfaceAlreadyAttached;
        if (self.findByPty(pty_id) != null) return error.PtyAlreadyAttached;

        try self.links.append(self.allocator, .{
            .surface_id = surface_id,
            .surface = surface,
            .pty_id = pty_id,
            .pty_io = pty_io,
        });

        surface.process_state = .running;
        // MARU_TRACE: surface가 붙는 순간 초기 grid 크기를 resize 이벤트로 기록해 trace를 self-contained하게 만든다.
        // recordResize는 변경 시에만 발화하므로, 이 baseline이 없으면 resize 없는 세션은 초기 크기를 trace에서 복원
        // 못 해 replay가 호출자 추정 크기에 의존한다(다른 열에서 wrap → 화면 불일치). 이제 replay가 이 첫 resize를
        // 먼저 적용해 코어를 원 크기로 맞춘 뒤 output을 먹인다.
        if (self.trace_recorder) |rec| rec.recordResize(surface_id, surface.core.size.cols, surface.core.size.rows);
        return .{ .surface_id = surface_id, .pty_id = pty_id };
    }

    pub fn detachSurface(self: *SurfaceRuntime, surface_id: SurfaceId) void {
        if (self.findBySurface(surface_id)) |index| {
            _ = self.links.orderedRemove(index);
        }
    }

    pub fn writeInput(self: *SurfaceRuntime, surface_id: SurfaceId, input: TerminalInput) RuntimeError!void {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;
        // 진단: Maru가 PTY로 보내는 키 바이트(키 인코딩 검증용 — 예: Option+Backspace가 \e\x7f인지).
        // pty->core(출력)와 대칭으로 core->pty(입력)를 찍는다. MARU_DEBUG에서만.
        if (self.debug_input) {
            var ebuf: [320]u8 = undefined;
            input_diag.info("core->pty {d}B: {s}", .{ input.bytes.len, escapeForLog(input.bytes, &ebuf) });
        }
        link.pty_io.writeInput(input.bytes) catch return error.WriteFailed;
    }

    /// non-blocking 쓰기: 지금 쓸 수 있는 만큼만 쓰고 길이를 돌려준다(0 = 다음에). paste 큐가
    /// 자식이 stdin을 안 읽는 동안에도 UI tick을 동결시키지 않으려고 쓴다.
    pub fn writeInputNonBlocking(self: *SurfaceRuntime, surface_id: SurfaceId, bytes: []const u8) RuntimeError!usize {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;
        // writeInput과 대칭으로 core->pty 비차단 입력(paste·IME 확정·OSC 52 read 응답)도 진단 로깅한다. MARU_DEBUG에서만.
        if (self.debug_input) {
            var ebuf: [320]u8 = undefined;
            input_diag.info("core->pty(nb) {d}B: {s}", .{ bytes.len, escapeForLog(bytes, &ebuf) });
        }
        return link.pty_io.writeInputNonBlocking(bytes) catch return error.WriteFailed;
    }

    /// Phase 3 단일책임(docs/io-render-threading.md §9 P3-2~): 메인발 코어 mutate를 위임한다. interactive
    /// (reader-processing)면 명령 큐로 enqueue + reader wake(`pty_io.enqueue_command`)해 reader가 락 아래 적용하고,
    /// 메인은 코어를 직접 mutate하지 않는다(§9.3 재진입 구조적 불가). non-interactive(직접 경로 — controlled
    /// smoke/단위 테스트, reader 없음)면 호출 스레드가 코어 락 아래 직접 적용한다(폴백 — 단일 스레드라 경합 없음).
    pub fn enqueueCoreCommand(self: *SurfaceRuntime, surface_id: SurfaceId, cmd: core_command.CoreCommand, io: std.Io) RuntimeError!void {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;
        if (link.pty_io.enqueue_command) |enqueue| {
            enqueue(link.pty_io.ctx, cmd) catch return error.WriteFailed;
        } else {
            // non-interactive(reader 없음 — 테스트/smoke): 호출 스레드가 직접 적용. 응답 생성 명령(리포팅)은
            // interactive면 reader가 PTY로 흘리므로 폴백에서도 같게 흘린다(pendingResponse → pty_io.writeInput).
            // dupe 후 락 밖 write(블로킹 PTY 쓰기를 락 안에 안 두려고 — PR1 패턴).
            var reply_buf: ?[]u8 = null;
            {
                link.surface.lockCore(io);
                defer link.surface.unlockCore(io);
                core_command.apply(&link.surface.core, cmd);
                const reply = link.surface.core.pendingResponse();
                if (reply.len > 0) {
                    reply_buf = self.allocator.dupe(u8, reply) catch null;
                    link.surface.core.clearResponse();
                }
            }
            if (reply_buf) |reply| {
                defer self.allocator.free(reply);
                link.pty_io.writeInput(reply) catch return error.WriteFailed;
            }
        }
    }

    pub fn resize(self: *SurfaceRuntime, surface_id: SurfaceId, size: terminal.Size, io: std.Io) RuntimeError!void {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;

        // grid와 PTY winsize가 같은 최소 크기를 쓰도록 한 곳에서 clamp한다. TerminalCore는 wide
        // glyph continuation 때문에 cols>=2를 요구하고 init/resize에서 자체 clamp하는데, PTY
        // winsize를 raw size로 보내면 grid(2칸)와 셸 winsize(1칸)가 어긋난다. 같은 clamp 값을 둘 다에.
        const grid = terminal.clampGridSize(size);
        {
            // 코어 resize도 코어 변경이라 락 아래(docs/io-render-threading.md). PTY ioctl은 락 밖.
            link.surface.lockCore(io);
            defer link.surface.unlockCore(io);
            try link.surface.core.resize(grid.cols, grid.rows);
        }
        // MARU_TRACE: 재생이 core.resize로 reflow를 재구성하도록 clamp된 grid 크기를 기록(코어에 적용된 값과 동일).
        if (self.trace_recorder) |rec| rec.recordResize(link.surface_id, grid.cols, grid.rows);
        link.pty_io.resize(grid) catch return error.ResizeFailed;
    }

    /// io는 코어 락(std.Io.Mutex)을 잡는 데 쓴다 — 호출자(pump는 queue.io, 테스트는 testing.io)가
    /// 자기 io를 넘긴다. docs/io-render-threading.md PR3에서 이 처리가 I/O 스레드로 이동하면
    /// 같은 io로 잠근다.
    pub fn applyPtyEvent(self: *SurfaceRuntime, event: RuntimePtyEvent, io: std.Io) RuntimeError!void {
        switch (event) {
            .output => |output| {
                // PTY bytes는 여기서 해석하지 않고 TerminalCore로만 전달한다.
                // escape parsing과 UTF-8 tail buffering은 terminal layer 책임이다.
                const link = self.linkByPty(output.pty_id) orelse return error.UnknownPty;
                if (link.surface.process_state == .exited) return error.ProcessExited;
                // 진단: ESC를 포함한 출력 청크의 제어 시퀀스를 찍는다(zsh가 SIGWINCH 때 보내는
                // 커서 이동/clear/CPR 질의를 보기 위함). MARU_DEBUG에서만.
                if (self.debug_input and std.mem.indexOfScalar(u8, output.bytes, 0x1b) != null) {
                    var ebuf: [320]u8 = undefined;
                    input_diag.info("pty->core {d}B: {s}", .{ output.bytes.len, escapeForLog(output.bytes, &ebuf) });
                }
                // 코어 변경은 락 아래에서 한다. 터미널이 만든 응답(CPR·OSC 10/11·DA 등 query 답)
                // 바이트는 **락 안에서 복사**해 꺼내고, PTY write는 **락 밖**에서 한다 — write는
                // 자식이 stdin을 안 읽으면 blocking(poll POLL.OUT)일 수 있어, 락을 들고 있으면
                // 렌더 스레드의 snapshot(같은 락)을 막는다. (이 블록이 docs/io-render-threading.md
                // PR3에서 I/O 스레드로 이동하면 이 분리가 응답 지연 결함의 핵심 해소다.)
                var reply_buf: ?[]u8 = null;
                {
                    link.surface.lockCore(io);
                    defer link.surface.unlockCore(io);
                    link.surface.core.write(output.bytes) catch return error.InvalidOutput;
                    const reply = link.surface.core.pendingResponse();
                    if (reply.len > 0) {
                        // OOM이면 best-effort 드롭(기존 writeInput catch{}와 같은 결) — 응답은 비운다.
                        reply_buf = self.allocator.dupe(u8, reply) catch null;
                        link.surface.core.clearResponse();
                    }
                }
                link.surface.process_state = .running;
                // MARU_TRACE: 원시 출력을 trace로 기록(락 밖 — 코어 변경과 무관한 순수 append). 재생의 권위 데이터.
                if (self.trace_recorder) |rec| rec.recordOutput(link.surface_id, output.bytes);
                // zsh는 SIGWINCH redraw 때 CSI 6n으로 커서를 묻고, 응답이 없으면 redraw가 어긋나
                // 프롬프트가 중복된다. best-effort(실패해도 출력 적용은 유지).
                if (reply_buf) |reply| {
                    defer self.allocator.free(reply);
                    if (self.debug_input) {
                        var rbuf: [64]u8 = undefined;
                        input_diag.info("core->pty reply: {s}", .{escapeForLog(reply, &rbuf)});
                    }
                    link.pty_io.writeInput(reply) catch {};
                }
            },
            .exited => |exited| {
                const link = self.linkByPty(exited.pty_id) orelse return error.UnknownPty;
                link.surface.process_state = .exited;
                // MARU_TRACE: child 종료 기록(exited→code, signaled→128+sig 셸 관례, unknown→none).
                if (self.trace_recorder) |rec| rec.recordProcessExit(link.surface_id, exitCode(exited.status));
            },
            .read_error => |read_error| {
                _ = read_error.message;
                // A read error means the PTY is no longer usable. Latch the
                // surface as exited (mirroring the .exited path) so later input
                // and resize are rejected with ProcessExited instead of being
                // routed to a dead PTY adapter.
                const link = self.linkByPty(read_error.pty_id) orelse return error.UnknownPty;
                link.surface.process_state = .exited;
                return error.ReadFailed;
            },
        }
    }

    fn linkBySurface(self: *SurfaceRuntime, surface_id: SurfaceId) ?*Link {
        if (self.findBySurface(surface_id)) |index| return &self.links.items[index];
        return null;
    }

    fn linkByPty(self: *SurfaceRuntime, pty_id: PtyId) ?*Link {
        if (self.findByPty(pty_id)) |index| return &self.links.items[index];
        return null;
    }

    fn findBySurface(self: *const SurfaceRuntime, surface_id: SurfaceId) ?usize {
        for (self.links.items, 0..) |link, index| {
            if (link.surface_id == surface_id) return index;
        }
        return null;
    }

    fn findByPty(self: *const SurfaceRuntime, pty_id: PtyId) ?usize {
        for (self.links.items, 0..) |link, index| {
            if (link.pty_id == pty_id) return index;
        }
        return null;
    }
};

const Link = struct {
    surface_id: SurfaceId,
    surface: *surface_mod.Surface,
    pty_id: PtyId,
    pty_io: PtyIo,
};

const FakePty = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8) = .empty,
    resize_calls: usize = 0,
    last_size: ?terminal.Size = null,
    fail_write: bool = false,
    fail_resize: bool = false,

    fn init(allocator: std.mem.Allocator) FakePty {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakePty) void {
        self.writes.deinit(self.allocator);
    }

    fn io(self: *FakePty) PtyIo {
        return .{
            .ctx = self,
            .write_input = fakeWriteInput,
            .resize_fn = fakeResize,
        };
    }

    fn fakeWriteInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        if (self.fail_write) return error.FakeWriteFailed;
        try self.writes.appendSlice(self.allocator, bytes);
    }

    fn fakeResize(ctx: *anyopaque, size: terminal.Size) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        if (self.fail_resize) return error.FakeResizeFailed;
        self.resize_calls += 1;
        self.last_size = size;
    }
};

test "runtime rejects input for an unattached surface" {
    var runtime = SurfaceRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expectError(
        error.UnknownSurface,
        runtime.writeInput(1, .{ .bytes = "hello" }),
    );
}

test "runtime rejects duplicate surface and pty attachments" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface_a = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface_a.deinit();
    var surface_b = try surface_mod.Surface.init(allocator, 2, terminal.Size.default);
    defer surface_b.deinit();

    var pty_a = FakePty.init(allocator);
    defer pty_a.deinit();
    var pty_b = FakePty.init(allocator);
    defer pty_b.deinit();

    _ = try runtime.attach(&surface_a, 10, pty_a.io());
    try std.testing.expectError(
        error.SurfaceAlreadyAttached,
        runtime.attach(&surface_a, 11, pty_b.io()),
    );
    try std.testing.expectError(
        error.PtyAlreadyAttached,
        runtime.attach(&surface_b, 10, pty_b.io()),
    );
}

test "runtime routes pty output to the matching surface core" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface_a = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface_a.deinit();
    var surface_b = try surface_mod.Surface.init(allocator, 2, .{ .cols = 20, .rows = 3 });
    defer surface_b.deinit();

    var pty_a = FakePty.init(allocator);
    defer pty_a.deinit();
    var pty_b = FakePty.init(allocator);
    defer pty_b.deinit();

    _ = try runtime.attach(&surface_a, 10, pty_a.io());
    _ = try runtime.attach(&surface_b, 20, pty_b.io());

    try runtime.applyPtyEvent(.{ .output = .{ .pty_id = 20, .bytes = "runtime" } }, std.testing.io);

    const screen_a = try surface_a.core.dumpUtf8(allocator);
    defer allocator.free(screen_a);
    const screen_b = try surface_b.core.dumpUtf8(allocator);
    defer allocator.free(screen_b);

    try std.testing.expect(std.mem.indexOf(u8, screen_a, "runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, screen_b, "runtime") != null);
    try std.testing.expectEqual(surface_mod.ProcessState.running, surface_b.process_state);
}

// MARU_TRACE 라이브 레코딩의 핵심 계약: runtime이 output/resize/process-exit를 recorder에 흘리고, 그 trace를
// replay하면 실제 surface 화면이 byte-for-byte 재구성된다(캡처→재생 end-to-end).
test "runtime records base kind to trace recorder and replay reconstructs the screen byte-for-byte" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator); // 테스트 sink(in-memory) — 프로덕션은 host가 file writer 주입
    defer out.deinit();
    var rec = TraceRecorder.init(&out.writer);
    runtime.trace_recorder = &rec; // host가 MARU_TRACE로 주입하는 것과 동일

    var surface = try surface_mod.Surface.init(allocator, 7, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    _ = try runtime.attach(&surface, 10, fake_pty.io());

    try runtime.applyPtyEvent(.{ .output = .{ .pty_id = 10, .bytes = "ab\r\nCD" } }, std.testing.io);
    try runtime.resize(7, .{ .cols = 10, .rows = 3 }, std.testing.io);
    try runtime.applyPtyEvent(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } }, std.testing.io);

    // recorder가 surface_id=7로 이벤트를 기록. attach가 초기 크기(8x2)를 event 0 resize로 먼저 남겨 trace가
    // self-contained(초기 grid 복원 가능)하다 — 그 뒤 output·resize(10x3)·process-exit.
    const t = out.written();
    try std.testing.expect(std.mem.indexOf(u8, t, "event 0 resize surface=7 cols=8 rows=2\n") != null); // 초기 크기 baseline
    try std.testing.expect(std.mem.indexOf(u8, t, "output surface=7 bytes=\"ab\\r\\nCD\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "resize surface=7 cols=10 rows=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "process-exit surface=7 code=0\n") != null);

    // 기록한 trace를 replay하면 원 surface 화면(resize 후 10x3)과 byte-for-byte 동일.
    const replay = @import("../observability.zig").replay;
    var replayed = try replay.replayTrace(allocator, t, .{ .cols = 8, .rows = 2 });
    defer replayed.deinit();
    const src_screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(src_screen);
    const rep_screen = try replayed.dumpUtf8(allocator);
    defer allocator.free(rep_screen);
    try std.testing.expectEqualStrings(src_screen, rep_screen);
}

// 멀티 surface(탭/split) trace는 한 파일에 여러 surface가 섞인다 — replay는 한 core에 한 surface만 재구성해야
// 화면이 안 뒤섞인다(code-review [0]). target(첫 output surface)만 적용되고, 다른 pane은 surface_id로 골라 재생된다.
test "runtime: 멀티 surface trace replay는 surface별로 분리 재구성한다(뒤섞임 없음)" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var rec = TraceRecorder.init(&out.writer);
    runtime.trace_recorder = &rec;

    var sa = try surface_mod.Surface.init(allocator, 7, .{ .cols = 6, .rows = 1 });
    defer sa.deinit();
    var sb = try surface_mod.Surface.init(allocator, 8, .{ .cols = 6, .rows = 1 });
    defer sb.deinit();
    var pa = FakePty.init(allocator);
    defer pa.deinit();
    var pb = FakePty.init(allocator);
    defer pb.deinit();
    _ = try runtime.attach(&sa, 10, pa.io());
    _ = try runtime.attach(&sb, 20, pb.io());

    // 두 surface에 서로 다른 출력을 교차로 흘린다.
    try runtime.applyPtyEvent(.{ .output = .{ .pty_id = 10, .bytes = "AAAA" } }, std.testing.io);
    try runtime.applyPtyEvent(.{ .output = .{ .pty_id = 20, .bytes = "BBBB" } }, std.testing.io);

    const t = out.written();
    const replay = @import("../observability.zig").replay;

    // 기본 replay(첫 output surface=7)는 surface 7만 재구성 → "AAAA"만, "BBBB" 섞이지 않음.
    var r7 = try replay.replayTrace(allocator, t, .{ .cols = 6, .rows = 1 });
    defer r7.deinit();
    const s7 = try r7.dumpUtf8(allocator);
    defer allocator.free(s7);
    try std.testing.expect(std.mem.indexOf(u8, s7, "AAAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, s7, "BBBB") == null); // 다른 pane이 안 섞임

    // surface 8을 명시하면 "BBBB"만.
    const trace = @import("../observability.zig").trace;
    const parsed = try trace.parseEvents(allocator, t);
    defer trace.freeParsedEvents(allocator, parsed);
    var r8 = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 1 });
    defer r8.deinit();
    try replay.replayEventsForSurface(&r8, parsed, 8);
    const s8 = try r8.dumpUtf8(allocator);
    defer allocator.free(s8);
    try std.testing.expect(std.mem.indexOf(u8, s8, "BBBB") != null);
    try std.testing.expect(std.mem.indexOf(u8, s8, "AAAA") == null);
}

test "runtime sends terminal input through the attached pty io" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());
    try runtime.writeInput(1, .{ .bytes = "abc" });

    try std.testing.expectEqualStrings("abc", fake_pty.writes.items);
}

test "runtime maps pty input failures to WriteFailed" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    fake_pty.fail_write = true;

    _ = try runtime.attach(&surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.WriteFailed,
        runtime.writeInput(1, .{ .bytes = "abc" }),
    );
}

test "runtime resize updates core and pty io together" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 5 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());
    try runtime.resize(1, .{ .cols = 42, .rows = 13 }, std.testing.io);

    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, surface.core.size);
    try std.testing.expectEqual(@as(usize, 1), fake_pty.resize_calls);
    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, fake_pty.last_size.?);
}

test "runtime resize clamps to at least 2 columns for both core and pty winsize" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 5 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());

    // cols<2 resize: TerminalCore grid와 PTY winsize 둘 다 cols>=2로 clamp돼 일치해야 한다.
    // 한쪽만 clamp하면 grid(2칸)와 셸 winsize(1칸)가 어긋난다.
    try runtime.resize(1, .{ .cols = 1, .rows = 5 }, std.testing.io);
    try std.testing.expectEqual(@as(u16, 2), surface.core.size.cols);
    try std.testing.expectEqual(@as(u16, 2), fake_pty.last_size.?.cols);
    try std.testing.expectEqual(@as(u16, 5), fake_pty.last_size.?.rows);
}

test "runtime maps pty resize failures to ResizeFailed after updating the surface size" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 5 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    fake_pty.fail_resize = true;

    _ = try runtime.attach(&surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.ResizeFailed,
        runtime.resize(1, .{ .cols = 42, .rows = 13 }, std.testing.io),
    );
    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, surface.core.size);
}

test "runtime detaches surface and rejects late pty output" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());
    runtime.detachSurface(1);

    try std.testing.expectError(
        error.UnknownPty,
        runtime.applyPtyEvent(.{ .output = .{ .pty_id = 10, .bytes = "late" } }, std.testing.io),
    );
    try std.testing.expectError(
        error.UnknownSurface,
        runtime.writeInput(1, .{ .bytes = "ignored" }),
    );
}

test "runtime marks a surface exited and blocks further input" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());
    try runtime.applyPtyEvent(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } }, std.testing.io);

    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
    try std.testing.expectError(
        error.ProcessExited,
        runtime.writeInput(1, .{ .bytes = "after-exit" }),
    );
}

test "runtime reports pty read errors without tracing them as output" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(&surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.ReadFailed,
        runtime.applyPtyEvent(.{ .read_error = .{ .pty_id = 10, .message = "read failed" } }, std.testing.io),
    );

    // A fatal read error must latch the surface as terminal, so later input is
    // rejected with ProcessExited rather than routed to the dead PTY.
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
    try std.testing.expectError(
        error.ProcessExited,
        runtime.writeInput(1, .{ .bytes = "after-read-error" }),
    );
}

test "escapeForLog escapes controls and never writes past the buffer (OOB regression)" {
    var buf: [16]u8 = undefined;
    // 기본 escape들.
    try std.testing.expectEqualStrings("\\e[A\\r\\n", escapeForLog("\x1b[A\r\n", &buf));
    try std.testing.expectEqualStrings("\\x80ok", escapeForLog("\x80ok", &buf));

    // OOB 회귀(#202): 가드(n+5>=len)를 통과한 4바이트 \xNN 쓰기가 n을 buf.len-2까지 밀 수 있다.
    // 옛 코드는 거기서 말줄임 3바이트를 무조건 써서 한 칸 넘었다. 모든 잘림 지점에서 안전해야 한다.
    var small: [8]u8 = undefined;
    var i: usize = 0;
    while (i <= 12) : (i += 1) {
        // printable i개 + 제어 바이트들: n이 모든 정렬로 끝에 닿게 만든다.
        var input: [16]u8 = undefined;
        for (0..i) |k| input[k] = 'a';
        for (i..16) |k| input[k] = 0x80; // 4바이트 \x80으로 확장됨
        const out = escapeForLog(input[0..16], &small);
        try std.testing.expect(out.len <= small.len); // 패닉 없이 버퍼 안에서 끝나야 한다
    }
}
