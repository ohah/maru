//! P5b2b2 독립 ReleaseFast host fixture.
//! 제품 daemon graph를 실행하고 private fd 3/4로만 owner telemetry를 노출한다.

const std = @import("std");
const session_host = @import("session_host");
const probe_wire = @import("slow_observer_probe");
const c = std.c;
const posix = std.posix;

const Probe = struct {
    command_fd: c.fd_t = probe_wire.command_fd,
    report_fd: c.fd_t = probe_wire.report_fd,
    pending_sequence: u64 = 0,
    pending_kind: probe_wire.ReportKind = .snapshot,
    pending_after_send: session_host.daemon.FixtureAction = .continue_serving,

    fn sendPending(
        self: *Probe,
        telemetry: session_host.poll_owner.TelemetrySnapshot,
        pty_output_bytes: u64,
        output_wake: session_host.runtime_manager.RuntimeManager.OutputWakeEvidence,
        child_exit: session_host.runtime_manager.RuntimeManager.ChildExitEvidence,
        observation: session_host.runtime_manager.RuntimeManager.ObservationPerformanceEvidence,
        metadata_sampler: session_host.runtime_manager.RuntimeManager.MetadataSamplerEvidence,
        screen: session_host.runtime_manager.RuntimeManager.ScreenPerformanceEvidence,
    ) ?session_host.daemon.FixtureAction {
        if (self.pending_sequence == 0) return null;
        const report = probe_wire.Report.from(
            self.pending_sequence,
            self.pending_kind,
            telemetry,
            pty_output_bytes,
            output_wake,
            child_exit,
            observation,
            metadata_sampler,
            screen,
        );
        const rc = c.send(
            self.report_fd,
            std.mem.asBytes(&report).ptr,
            @sizeOf(probe_wire.Report),
            posix.MSG.DONTWAIT,
        );
        if (rc == @sizeOf(probe_wire.Report)) {
            const action = self.pending_after_send;
            self.pending_sequence = 0;
            self.pending_after_send = .continue_serving;
            return action;
        }
        if (rc < 0 and posix.errno(rc) == .AGAIN) return .continue_serving;
        return .stop;
    }

    fn afterTurn(
        context: *anyopaque,
        telemetry: session_host.poll_owner.TelemetrySnapshot,
        pty_output_bytes: u64,
        output_wake: session_host.runtime_manager.RuntimeManager.OutputWakeEvidence,
        child_exit: session_host.runtime_manager.RuntimeManager.ChildExitEvidence,
        observation: session_host.runtime_manager.RuntimeManager.ObservationPerformanceEvidence,
        metadata_sampler: session_host.runtime_manager.RuntimeManager.MetadataSamplerEvidence,
        screen: session_host.runtime_manager.RuntimeManager.ScreenPerformanceEvidence,
    ) session_host.daemon.FixtureAction {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (self.sendPending(telemetry, pty_output_bytes, output_wake, child_exit, observation, metadata_sampler, screen)) |action| return action;

        var packet_bytes: [@sizeOf(probe_wire.CommandPacket) + 1]u8 = undefined;
        const rc = c.recv(
            self.command_fd,
            &packet_bytes,
            packet_bytes.len,
            posix.MSG.DONTWAIT | posix.MSG.TRUNC,
        );
        if (rc < 0 and posix.errno(rc) == .AGAIN) return .continue_serving;
        if (rc != @sizeOf(probe_wire.CommandPacket)) return .stop;
        const command = probe_wire.decodeCommandDatagram(
            packet_bytes[0..@intCast(rc)],
        ) orelse return .stop;
        const action = command.command() orelse return .stop;
        self.pending_sequence = command.sequence;
        switch (action) {
            .snapshot => self.pending_kind = .snapshot,
            .reset_stall => {
                self.pending_kind = .reset_ack;
                // reset은 daemon이 callback 반환 뒤 적용한다. ACK는 다음 owner turn의
                // post-reset snapshot을 보낸 뒤 continue한다.
                return .reset_stall;
            },
            .stop => {
                self.pending_kind = .stop_ack;
                self.pending_after_send = .stop;
            },
        }
        return self.sendPending(telemetry, pty_output_bytes, output_wake, child_exit, observation, metadata_sampler, screen) orelse
            .continue_serving;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const dir_raw = args.next() orelse return error.MissingSessionDirectory;
    const socket_raw = args.next() orelse return error.MissingSocketPath;
    if (args.next() != null) return error.UnexpectedArgument;
    const dir = try init.gpa.dupeZ(u8, dir_raw);
    defer init.gpa.free(dir);
    const socket = try init.gpa.dupeZ(u8, socket_raw);
    defer init.gpa.free(socket);

    var probe: Probe = .{};
    var socket_type: c_int = 0;
    var socket_type_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(
        probe.command_fd,
        posix.SOL.SOCKET,
        posix.SO.TYPE,
        &socket_type,
        &socket_type_len,
    ) != 0 or socket_type != posix.SOCK.DGRAM) return error.InvalidProbeFd;
    socket_type = 0;
    socket_type_len = @sizeOf(c_int);
    if (c.getsockopt(
        probe.report_fd,
        posix.SOL.SOCKET,
        posix.SO.TYPE,
        &socket_type,
        &socket_type_len,
    ) != 0 or socket_type != posix.SOCK.DGRAM) return error.InvalidProbeFd;
    // fd 3/4는 fixture host exec를 통과시키기 위해 parent에서 non-CLOEXEC였지만,
    // host가 다시 forkpty하는 controlled child에는 절대 상속되면 안 된다.
    // 여기서 즉시 CLOEXEC로 바꿔 owner-only trust boundary를 닫는다.
    try setCloseOnExec(probe.command_fd);
    try setCloseOnExec(probe.report_fd);
    const one: c_int = 1;
    if (c.setsockopt(
        probe.report_fd,
        posix.SOL.SOCKET,
        posix.SO.NOSIGPIPE,
        &one,
        @sizeOf(c_int),
    ) != 0) return error.InvalidProbeFd;
    defer {
        _ = c.close(probe.command_fd);
        _ = c.close(probe.report_fd);
    }
    try session_host.daemon.runSessionHostForFixture(
        init.gpa,
        init.io,
        dir,
        socket,
        .{ .ctx = &probe, .after_turn = Probe.afterTurn },
    );
}

fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0)
        return error.InvalidProbeFd;
}
