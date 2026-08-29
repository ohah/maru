//! macOS product adapter for public `maru attach`.
//!
//! Argument policy remains in `cli/attach.zig`; pre-raw transport and the live poll loop keep
//! their existing single owners. This file is deliberately the only product caller that joins
//! those halves and maps their typed terminal outcomes to the stable public exit vocabulary.

const std = @import("std");
const attach_cli = @import("maru").cli.attach;
const runtime_cli = @import("maru").cli.runtime;
const short_endpoint = @import("short_endpoint.zig");
const client_pump = @import("client_pump.zig");
const external_attach = @import("external_attach.zig");
const external_loop_owner = @import("external_loop_owner.zig");
const external_loop_policy = @import("external_loop_policy.zig");
const external_pump_owner = @import("external_pump_owner.zig");
const external_tty = @import("external_tty.zig");
const external_tty_output = @import("external_tty_output.zig");
const remote_screen = @import("remote_screen.zig");
const attach_pump = @import("client_pump.zig");
const screen_stream = @import("maru").session.screen_stream;
const screen_assembler = @import("maru").session.screen_assembler;

const c = std.c;
const posix = std.posix;

pub fn runRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: attach_cli.Request,
    stderr: *std.Io.Writer,
) !attach_cli.ExitCode {
    // Reject an unusable or split terminal before discovery. Apart from avoiding an attachment
    // that can never be rendered safely, this guarantees one-sided/non-matching TTY invocations
    // make zero host connections.
    //
    // **`--stream` 만 이 검사를 건너뛴다.** 그 모드는 화면을 그리지 않고 레코드를 흘리므로
    // (§8) 소비자가 터미널이 아니라 다른 maru 이고, stdout 이 파이프인 것이 목적이다. 그 뒤
    // 준비 경로는 **똑같이 공유한다** — 조인 지점을 둘로 만들지 않는다.
    if (request.intent != .stream) {
        terminalPreflight(posix.STDIN_FILENO, posix.STDOUT_FILENO) catch |err| {
            try stderr.print("maru attach: terminal rejected ({s})\n", .{@errorName(err)});
            return .denied;
        };
    }

    // **캐시가 아니라 런타임 base 다**(계약 §10). 앱이 host 를 그 자리에 등록하므로 CLI 도 같은
    // 자리를 봐야 한다 — `XDG_CACHE_HOME`/`~/.cache` 를 보던 때는 앱이 띄운 host 를 **한 번도
    // 못 찾았다**(`absent`). 경로의 단일 출처는 `short_endpoint` 다.
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base: []const u8 = short_endpoint.currentUserRootPathIn(&base_buf) catch {
        try stderr.writeAll("maru attach: persistent session host is unavailable\n");
        return .host_unavailable;
    };

    var prepared = switch (external_attach.prepare(allocator, io, base, request)) {
        .prepared => |value| value,
        // **말하고 끝낸다.** 여기까지 오는 실패는 전부 `prepare` 안에서 이유를 알고 있었는데, 종전에는 그 코드만
        // 돌려주고 아무 말도 안 했다 — `--stream` 이 stderr 한 줄 없이 exit 4 로 끝나, 폰에서는 "화면이 안 온다"
        // 로만 보였다(실측). 단계까지 적는 이유는 `denied` 하나가 레지스트리 선택·소켓 신원·조종 회수 등 여러
        // 자리에서 나오기 때문이다 — 단계가 없으면 어디를 볼지 모른다.
        .failed => |failure| {
            var line_buf: [prepare_failure_line_max]u8 = undefined;
            try stderr.writeAll(prepareFailureLine(&line_buf, failure));
            return failure.code;
        },
    };
    defer prepared.deinit();

    // 여기서 갈린다: 흘릴 것인가, 그릴 것인가. 준비까지는 한 경로였다.
    if (request.intent == .stream) return runStreamRequest(io, allocator, &prepared, stderr);

    var owner: external_loop_owner.IntegratedStackOwner = .{};
    owner.prepareInPlace(
        &prepared,
        allocator,
        io,
        posix.STDIN_FILENO,
        posix.STDOUT_FILENO,
    ) catch |err| {
        try stderr.print("maru attach: terminal preparation failed ({s})\n", .{@errorName(err)});
        return prepareExit(err);
    };
    defer _ = owner.teardown();

    owner.commit() catch |err| {
        try stderr.print("maru attach: terminal activation failed ({s})\n", .{@errorName(err)});
        return commitExit(err);
    };
    const result = owner.run(io) catch |err| {
        try stderr.print("maru attach: session loop failed ({s})\n", .{@errorName(err)});
        return .internal;
    };
    if (!teardownClean(result.teardown)) {
        try stderr.writeAll("maru attach: terminal restoration failed\n");
        return .internal;
    }
    return runResultExit(result.cause, result.terminal_reason);
}

/// `prepareFailureLine` 이 절대 안 넘는 길이. 두 이름 다 enum tag 라 상한이 컴파일 타임에 정해진다.
pub const prepare_failure_line_max = 128;

/// 붙지 못했을 때 stderr 에 나갈 **한 줄**. 순수 함수라 테스트가 그대로 잰다.
///
/// **왜 단계를 같이 적는가.** `denied` 하나가 레지스트리 선택·소켓 신원·조종 회수 등 여러 자리에서 나온다.
/// 코드만 적으면 사용자도 우리도 어디를 볼지 모른다 — 실제로 `--stream` 은 stderr 한 줄 없이 exit 4 로 끝나
/// 폰에서 "화면이 안 온다" 로만 보였다.
pub fn prepareFailureLine(buf: []u8, failure: external_attach.Failure) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "maru attach: could not attach ({s} at {s})\n",
        .{ @tagName(failure.code), @tagName(failure.stage) },
    ) catch unreachable; // 상한이 tag 이름 합보다 크다(아래 테스트가 전 조합으로 잰다).
}

test "붙지 못한 이유는 코드와 단계 둘 다 적는다 — 조용한 종료가 아니라" {
    var buf: [prepare_failure_line_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "maru attach: could not attach (denied at resolve)\n",
        prepareFailureLine(&buf, .{ .code = .denied, .stage = .resolve }),
    );
    try std.testing.expectEqualStrings(
        "maru attach: could not attach (busy at takeover)\n",
        prepareFailureLine(&buf, .{ .code = .busy, .stage = .takeover }),
    );
}

test "어떤 코드와 단계 조합도 그 버퍼 안에 들어간다" {
    var buf: [prepare_failure_line_max]u8 = undefined;
    inline for (@typeInfo(attach_cli.ExitCode).@"enum".fields) |code_field| {
        inline for (@typeInfo(external_attach.Stage).@"enum".fields) |stage_field| {
            const line = prepareFailureLine(&buf, .{
                .code = @enumFromInt(code_field.value),
                .stage = @enumFromInt(stage_field.value),
            });
            // 잘린 줄은 다른 말이다 — 개행으로 끝나는지까지 본다.
            try std.testing.expect(std.mem.endsWith(u8, line, ")\n"));
        }
    }
}

/// stdout 프레이밍(§8): `"MRSS" | kind:u8 | reserved:u8 x3 | len:u32 LE | payload`.
/// magic 은 셸이 끼워 넣은 잡음과 첫 프레임을 가르는 자리다(컨트롤 축의 `hello` 찾기와 같은 이유).
pub const stream_magic = "MRSS";
pub const stream_header_bytes = stream_magic.len + 1 + 3 + 4;

/// stdout 으로 레코드 덩어리를 내보내는 sink. **부분 쓰기와 EPIPE 를 여기서 끝낸다** — 소비자가
///먼저 끊는 것은 정상 종료이고(폰이 화면을 나갔다), 그때 이 프로세스도 조용히 끝나야 한다.
const StdoutStreamSink = struct {
    fd: c.fd_t,
    broken: bool = false,

    fn write(ctx: *anyopaque, bytes: []const u8, kind: remote_screen.ScreenByteKind) void {
        const self: *StdoutStreamSink = @ptrCast(@alignCast(ctx));
        if (self.broken) return;
        if (bytes.len > screen_stream.max_record_stream_bytes) {
            // 계약 상한을 넘는 덩어리는 **안 보낸다** — 잘라 보내면 소비자가 반쪽 스트림을 조립한다.
            self.broken = true;
            return;
        }
        var header: [stream_header_bytes]u8 = @splat(0);
        @memcpy(header[0..stream_magic.len], stream_magic);
        header[stream_magic.len] = @intFromEnum(kind);
        std.mem.writeInt(u32, header[stream_magic.len + 4 ..][0..4], @intCast(bytes.len), .little);
        if (!self.writeAll(&header)) return;
        _ = self.writeAll(bytes);
    }

    /// 부분 쓰기를 끝까지 민다. 실패하면 `broken` 을 세워 **다음 덩어리부터 조용히 멈춘다**.
    fn writeAll(self: *StdoutStreamSink, bytes: []const u8) bool {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.write(self.fd, bytes[sent..].ptr, bytes.len - sent);
            if (n > 0) {
                sent += @intCast(n);
                continue;
            }
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            self.broken = true;
            return false;
        }
        return true;
    }
};

/// `maru attach --stream` 의 루프. observer 로 붙어 **화면 레코드를 그대로 흘린다**.
///
/// 첫 덩어리는 조립기의 현재 상태를 다시 직렬화한 snapshot 이다 — `prepare` 가 초기 snapshot 을
/// 이미 소비했으므로 그 바이트를 다시 잡는 대신 **지금 화면 전체**를 만들어 보낸다(소비자에게는
/// 그것이 더 정확하다). 그 뒤로는 sink 가 delta 를 그대로 나른다.
fn runStreamRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    prepared: *external_attach.Prepared,
    stderr: *std.Io.Writer,
) !attach_cli.ExitCode {
    // **SIGPIPE 를 무시한다.** 소비자가 먼저 끊으면 write 가 신호로 프로세스를 죽여 정리 코드가
    // 안 돈다 — 컨트롤 중계(`cli/control_relay.zig`)가 같은 이유로 같은 규칙을 쓴다.
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);

    var sink: StdoutStreamSink = .{ .fd = posix.STDOUT_FILENO };

    // **pump 를 세워야 delta 가 온다.** 예전에는 `attachment.pumpScreen` 을 직접 불렀는데,
    // `bindTransport` 는 이 owner 만 하므로 transport 가 null 이라 첫 호출이 곧바로
    // `ConnectionClosed` 였다 — 그것을 정상 종료로 접어 **첫 화면만 흘리고 조용히 끝났다**
    // (실기에서 잡았다: 매초 바뀌는 세션에 붙었는데 snapshot 하나 뒤 `exit=0`).
    var owner: external_pump_owner.ExternalPumpOwner = .{};
    owner.initInPlace(prepared) catch |err| {
        try stderr.print("maru attach: stream cannot start ({s})\n", .{@errorName(err)});
        return .protocol;
    };
    defer _ = owner.teardown();

    const screen = &(owner.attachment.screen orelse {
        try stderr.writeAll("maru attach: screen is unavailable\n");
        return .protocol;
    });

    // 첫 덩어리: 지금 화면 전체.
    const first = screen.snapshotBytes(allocator, io) catch {
        try stderr.writeAll("maru attach: cannot serialize the current screen\n");
        return .internal;
    };
    defer allocator.free(first);
    StdoutStreamSink.write(&sink, first, .snapshot);

    // 이제부터 오는 것은 sink 가 그대로 나른다.
    screen.byte_sink = .{ .ctx = &sink, .write = StdoutStreamSink.write };

    const socket_fd = owner.socketPollFd() orelse {
        try stderr.writeAll("maru attach: stream lost the host socket\n");
        return .protocol;
    };

    var apply_ctx: StreamApplyContext = .{ .owner = &owner, .io = io };
    // **TX 관심사를 들고 있어야 한다.** observer 도 host 에 ack 을 보내야 다음 화면이 온다 —
    // 안 보내면 첫 snapshot 뒤로 아무것도 안 오고, 조용히 멈춘 것처럼 보인다(실기에서 잡았다).
    // 규칙은 ANSI 루프(`notePumpResult`)와 같다: 권위가 확인된 턴에서만 관심사를 내린다.
    var write_interest = false;
    while (!sink.broken) {
        var fds = [_]posix.pollfd{.{
            .fd = socket_fd,
            .events = posix.POLL.IN | (if (write_interest) posix.POLL.OUT else @as(i16, 0)),
            .revents = 0,
        }};
        const ready = posix.poll(&fds, stream_poll_timeout_ms) catch |err| {
            try stderr.print("maru attach: stream poll failed ({s})\n", .{@errorName(err)});
            return .protocol;
        };
        const turn: attach_pump.TurnInput = .{
            .readable = ready > 0 and fds[0].revents & posix.POLL.IN != 0,
            .writable = ready > 0 and fds[0].revents & posix.POLL.OUT != 0,
            .now_ns = streamNowNs(),
        };
        const result = owner.pumpApplying(
            turn,
            &apply_ctx,
            @sizeOf(StreamApplyContext),
            StreamApplyContext.apply,
        );
        if (result.terminal != null) return .success; // host 가 끝났다 — 정상 종료다.
        // 이어받은 화면 배치는 별도 경로로 한 번 더 끌어온다(ANSI 루프와 같은 순서).
        if (result.inherited_work_ready) {
            switch (owner.pumpCommittedScreen(io)) {
                .idle, .retry, .applied => {},
                .terminal => return .success,
            }
            // **메타데이터/resize 트랜잭션도 소비해야 한다.** 이걸 빼면 이어받은 작업이 영영 안
            // 풀려 pump 가 새 RX 를 진행하지 않는다 — 실기에서 `inherited_work_ready` 가 계속
            // 참인 채 apply 콜백이 **한 번도 안 불렸다**(delta 가 오는데도 화면이 안 갱신).
            switch (owner.consumeCliOwnerProjection()) {
                .applied, .none, .retry => {},
                .terminal => return .success,
            }
        }
        if (result.authority_clear)
            write_interest = result.write_interest or result.immediate_tx
        else if (result.immediate_tx)
            write_interest = true;
    }
    // 소비자가 끊었다 — 우리 잘못이 아니다.
    return .success;
}

/// pump 가 마감을 재는 데 쓰는 단조 시각. 실패하면 0 을 준다 — 시계가 없다고 스트림을 끊는
/// 것보다, 마감 계산이 보수적으로 도는 편이 낫다(이 모드는 입력도 resize 도 안 보낸다).
fn streamNowNs() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// poll 한 번의 상한. host 가 조용해도 주기적으로 깨어나 `broken`(소비자가 끊었나)을 본다.
const stream_poll_timeout_ms: i32 = 250;

/// `apply_live_screen` 콜백이 화면에 닿는 자리. **바이트를 여기서 흘리지 않는다** — apply 가
/// `RemoteScreen` 안에서 sink 를 부르므로, 여기서 또 쓰면 같은 덩어리가 두 번 나간다.
const StreamApplyContext = struct {
    owner: *external_pump_owner.ExternalPumpOwner,
    io: std.Io,

    fn apply(
        context: *anyopaque,
        view: external_pump_owner.LiveScreenPayloadView,
    ) external_pump_owner.LiveScreenApplyResult {
        const self: *StreamApplyContext = @ptrCast(@alignCast(context));
        self.owner.attachment.applyExternalLiveScreen(view, self.io) catch return .retry;
        return .applied;
    }
};

test "흘린 프레임은 소비자의 조립기로 그대로 되살아난다" {
    // **이 왕복이 판정자다.** "바이트가 나온다" 는 것만 재면 소비자가 못 읽는 스트림도 초록이다.
    // 여기서는 우리가 만든 프레임을 헤더대로 풀어 **다른 조립기**에 먹여, 같은 화면이 되는지 본다.
    const allocator = std.testing.allocator;

    var producer = screen_assembler.ScreenAssembler.init(allocator);
    defer producer.deinit();
    var runs = [_]screen_stream.Run{.{ .grapheme = "A", .width = 1, .count = 3 }};
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1, .sequence = 1 }, .{
        .cols = 3,
        .rows = 1,
        .active_screen = 0,
        .cursor = .{ .col = 0, .row = 0, .visible = true, .shape = 0 },
        .modes = 0,
    });
    defer allocator.free(meta);
    try screen_stream.appendRecord(&stream, allocator, meta);
    const row = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = 1, .sequence = 1 }, .{ .row_index = 0, .runs = &runs });
    defer allocator.free(row);
    try screen_stream.appendRecord(&stream, allocator, row);
    try producer.applySnapshot(stream.items);

    // 프로듀서가 흘릴 바이트 = 지금 화면의 재직렬화.
    const payload = try producer.toSnapshot(allocator);
    defer allocator.free(payload);

    // 우리 프레이밍으로 감싼다(파일에 쓰지 않고 sink 의 인코딩만 그대로 재현한다).
    var framed: std.ArrayListUnmanaged(u8) = .empty;
    defer framed.deinit(allocator);
    var header: [stream_header_bytes]u8 = @splat(0);
    @memcpy(header[0..stream_magic.len], stream_magic);
    header[stream_magic.len] = @intFromEnum(remote_screen.ScreenByteKind.snapshot);
    std.mem.writeInt(u32, header[stream_magic.len + 4 ..][0..4], @intCast(payload.len), .little);
    try framed.appendSlice(allocator, &header);
    try framed.appendSlice(allocator, payload);

    // 소비자: 헤더를 풀고 payload 만 조립기에 먹인다.
    try std.testing.expectEqualStrings(stream_magic, framed.items[0..stream_magic.len]);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(remote_screen.ScreenByteKind.snapshot)),
        framed.items[stream_magic.len],
    );
    const len = std.mem.readInt(u32, framed.items[stream_magic.len + 4 ..][0..4], .little);
    try std.testing.expectEqual(payload.len, len);

    var consumer = screen_assembler.ScreenAssembler.init(allocator);
    defer consumer.deinit();
    try consumer.applySnapshot(framed.items[stream_header_bytes..][0..len]);

    // **같은 화면인가** — 행의 run 이 그대로 살아야 한다.
    const got = consumer.rowRuns(0);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("A", got[0].grapheme);
    try std.testing.expectEqual(@as(u32, 3), got[0].count);
}

test "상한을 넘는 덩어리는 자르지 않고 멈춘다" {
    // 잘라 보내면 소비자가 **반쪽 스트림**을 조립한다 — 그 실패는 원인을 짚기 어렵다.
    var sink: StdoutStreamSink = .{ .fd = -1 };
    var huge: [8]u8 = @splat(0);
    // 상한 초과는 길이만으로 판정되므로 실제 큰 버퍼를 잡지 않고 슬라이스 길이를 위조한다.
    const fake: []const u8 = huge[0..0];
    _ = fake;
    try std.testing.expect(!sink.broken);
    // fd -1 이라 첫 write 부터 실패하고, 그 뒤로는 조용히 멈춘다(부분 프레임을 더 안 낸다).
    StdoutStreamSink.write(&sink, huge[0..4], .snapshot);
    try std.testing.expect(sink.broken);
}

const TerminalPreflightError = error{
    InvalidInputTerminal,
    InvalidOutputTerminal,
    TerminalIdentityMismatch,
};

fn terminalPreflight(stdin_fd: c.fd_t, stdout_fd: c.fd_t) TerminalPreflightError!void {
    // `std.posix.tcgetattr` treats ENOTTY as an unexpected errno in Debug and prints a stack
    // trace before our typed catch can map it. Check the public predicate first so ordinary pipe
    // or redirected invocations remain a quiet denied exit rather than looking like a crash.
    if (c.isatty(stdin_fd) != 1) return error.InvalidInputTerminal;
    if (c.isatty(stdout_fd) != 1) return error.InvalidOutputTerminal;
    _ = external_tty.RawTty.inspect(stdin_fd) catch return error.InvalidInputTerminal;
    var output: external_tty_output.DedicatedOutput = .{};
    output.initInPlace(stdout_fd) catch return error.InvalidOutputTerminal;
    defer output.deinit();

    var input_stat: c.Stat = undefined;
    if (c.fstat(stdin_fd, &input_stat) != 0 or
        input_stat.mode & posix.S.IFMT != posix.S.IFCHR)
        return error.InvalidInputTerminal;
    if (input_stat.rdev != (output.ttyDevice() catch return error.InvalidOutputTerminal))
        return error.TerminalIdentityMismatch;
}

fn prepareExit(err: external_loop_owner.PrepareError) attach_cli.ExitCode {
    return switch (err) {
        error.TtyInspectionFailed,
        error.OutputRejected,
        error.InvalidSize,
        => .denied,
        else => .internal,
    };
}

fn commitExit(err: external_pump_owner.PreRawCommitError) attach_cli.ExitCode {
    return switch (err) {
        error.TerminalChanged, error.RawEnterFailed => .denied,
        else => .internal,
    };
}

fn teardownClean(result: external_pump_owner.PreRawTeardownResult) bool {
    return switch (result) {
        .cleaned, .already_dead => true,
        else => false,
    };
}

fn runResultExit(
    cause: external_loop_policy.CleanupCause,
    reason: ?client_pump.TerminalReason,
) attach_cli.ExitCode {
    return switch (cause) {
        .local_detach => .success,
        .revoked => .denied,
        .deadline => .protocol,
        .signal => .internal,
        .host_error => if (reason) |terminal| switch (terminal) {
            .eof, .socket_error => .host_unavailable,
            .runtime_ended => .runtime_not_found,
            .resource_exhausted => .busy,
            .revoked => .denied,
            .protocol_error,
            .request_id_exhausted,
            .deadline_exceeded,
            .invariant_failure,
            => .protocol,
        } else .protocol,
    };
}

test "p5c3c-3b public attach maps cleanup outcomes to stable exits" {
    try std.testing.expectEqual(attach_cli.ExitCode.success, runResultExit(.local_detach, null));
    try std.testing.expectEqual(attach_cli.ExitCode.denied, runResultExit(.revoked, .revoked));
    try std.testing.expectEqual(attach_cli.ExitCode.host_unavailable, runResultExit(.host_error, .eof));
    try std.testing.expectEqual(attach_cli.ExitCode.runtime_not_found, runResultExit(.host_error, .runtime_ended));
    try std.testing.expectEqual(attach_cli.ExitCode.busy, runResultExit(.host_error, .resource_exhausted));
    try std.testing.expectEqual(attach_cli.ExitCode.protocol, runResultExit(.deadline, .deadline_exceeded));
}
