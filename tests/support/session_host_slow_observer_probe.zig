//! P5b2b2 ReleaseFast fixture의 private command/report protocol.
//! 제품 MRSH와 독립이며 fork+exec로 상속한 fd 3/4에서만 사용한다.

const std = @import("std");
const session_host = @import("session_host");

pub const command_fd = 3;
pub const report_fd = 4;
pub const max_packet_bytes = 4096;

pub const Command = enum(u8) {
    snapshot = 1,
    reset_stall = 2,
    stop = 3,
};

pub const ReportKind = enum(u8) {
    snapshot = 1,
    reset_ack = 2,
    stop_ack = 3,
};

pub const CommandPacket = extern struct {
    magic: u32 = 0x4d525343, // MRSC
    version: u16 = 4,
    length: u16 = @sizeOf(CommandPacket),
    sequence: u64,
    action: u8,
    reserved: [7]u8 = [_]u8{0} ** 7,

    pub fn init(sequence: u64, action: Command) CommandPacket {
        return .{ .sequence = sequence, .action = @intFromEnum(action) };
    }

    pub fn command(self: CommandPacket) ?Command {
        if (self.magic != 0x4d525343 or self.version != 4 or
            self.length != @sizeOf(CommandPacket) or self.sequence == 0 or
            !std.mem.allEqual(u8, &self.reserved, 0)) return null;
        return std.enums.fromInt(Command, self.action);
    }
};

pub const Report = extern struct {
    magic: u32 = 0x4d525350, // MRSP
    version: u16 = 4,
    length: u16 = @sizeOf(Report),
    sequence: u64,
    kind: u8,
    reserved: [7]u8 = [_]u8{0} ** 7,
    resident_bytes: u64,
    shared_bytes: u64,
    prepared_base_bytes: u64,
    prepared_reclaim_bytes: u64,
    peak_resident_bytes: u64,
    peak_shared_bytes: u64,
    peak_prepared_base_bytes: u64,
    peak_prepared_reclaim_bytes: u64,
    peak_slot_queue_bytes: u64,
    peak_slot_base_bytes: u64,
    peak_slot_control_bytes: u64,
    peak_slot_total_bytes: u64,
    pressure_reclaims: u64,
    stalled_clients: u64,
    active_clients: u64,
    total_admitted: u64,
    pollout_absent_count: u64,
    first_stall_connection_id: u64,
    first_stall_ns: u64,
    first_stall_send_buffer_bytes: u64,
    stale_client_observations: u64,
    pty_output_bytes: u64,
    output_wake_notify_attempts: u64,
    output_wake_published_writes: u64,
    output_wake_coalesced_writes: u64,
    output_wake_drain_turns: u64,
    live_child_pid: i32,
    reaped_children: u64,
    last_child_exit_status: i32,
    exit_reserved: u32 = 0,
    observation_materializations: u64,
    observation_core_lock_acquisitions: u64,
    observation_core_lock_hold_total_ns: u64,
    observation_core_lock_hold_max_ns: u64,
    metadata_sampler_visits: u64,
    metadata_sampler_changes: u64,
    metadata_sampler_failures: u64,
    metadata_producer_visits: u64,
    screen_snapshot_calls: u64,
    screen_delta_calls: u64,
    screen_owned_allocations: u64,
    screen_core_lock_acquisitions: u64,

    pub fn from(
        sequence: u64,
        kind: ReportKind,
        telemetry: session_host.poll_owner.TelemetrySnapshot,
        pty_output_bytes: u64,
        output_wake: session_host.runtime_manager.RuntimeManager.OutputWakeEvidence,
        child_exit: session_host.runtime_manager.RuntimeManager.ChildExitEvidence,
        observation: session_host.runtime_manager.RuntimeManager.ObservationPerformanceEvidence,
        metadata_sampler: session_host.runtime_manager.RuntimeManager.MetadataSamplerEvidence,
        screen: session_host.runtime_manager.RuntimeManager.ScreenPerformanceEvidence,
    ) Report {
        const a = telemetry.accounting;
        return .{
            .sequence = sequence,
            .kind = @intFromEnum(kind),
            .resident_bytes = a.resident_bytes,
            .shared_bytes = a.shared_bytes,
            .prepared_base_bytes = a.prepared_base_bytes,
            .prepared_reclaim_bytes = a.prepared_reclaim_bytes,
            .peak_resident_bytes = a.peak_resident_bytes,
            .peak_shared_bytes = a.peak_shared_bytes,
            .peak_prepared_base_bytes = a.peak_prepared_base_bytes,
            .peak_prepared_reclaim_bytes = a.peak_prepared_reclaim_bytes,
            .peak_slot_queue_bytes = a.peak_slot_queue_bytes,
            .peak_slot_base_bytes = a.peak_slot_base_bytes,
            .peak_slot_control_bytes = a.peak_slot_control_bytes,
            .peak_slot_total_bytes = a.peak_slot_total_bytes,
            .pressure_reclaims = telemetry.pressure_reclaims,
            .stalled_clients = telemetry.stalled_clients,
            .active_clients = telemetry.active_clients,
            .total_admitted = telemetry.total_admitted,
            .pollout_absent_count = telemetry.pollout_absent_count,
            .first_stall_connection_id = telemetry.first_stall_connection_id,
            .first_stall_ns = telemetry.first_stall_ns,
            .first_stall_send_buffer_bytes = telemetry.first_stall_send_buffer_bytes,
            .stale_client_observations = telemetry.stale_client_observations,
            .pty_output_bytes = pty_output_bytes,
            .output_wake_notify_attempts = output_wake.notify_attempts,
            .output_wake_published_writes = output_wake.published_writes,
            .output_wake_coalesced_writes = output_wake.coalesced_writes,
            .output_wake_drain_turns = output_wake.drain_turns,
            .live_child_pid = child_exit.live_child_pid,
            .reaped_children = child_exit.reaped_children,
            .last_child_exit_status = child_exit.last_exit_status,
            .observation_materializations = observation.materializations,
            .observation_core_lock_acquisitions = observation.core_lock_acquisitions,
            .observation_core_lock_hold_total_ns = observation.core_lock_hold_total_ns,
            .observation_core_lock_hold_max_ns = observation.core_lock_hold_max_ns,
            .metadata_sampler_visits = metadata_sampler.visits,
            .metadata_sampler_changes = metadata_sampler.changes,
            .metadata_sampler_failures = metadata_sampler.failures,
            .metadata_producer_visits = metadata_sampler.producer_visits,
            .screen_snapshot_calls = screen.snapshot_calls,
            .screen_delta_calls = screen.delta_calls,
            .screen_owned_allocations = screen.owned_allocations,
            .screen_core_lock_acquisitions = screen.core_lock_acquisitions,
        };
    }

    pub fn valid(self: Report) bool {
        const parsed_kind = std.enums.fromInt(ReportKind, self.kind) orelse return false;
        _ = parsed_kind;
        return self.magic == 0x4d525350 and self.version == 4 and
            self.length == @sizeOf(Report) and self.sequence != 0 and
            std.mem.allEqual(u8, &self.reserved, 0) and self.exit_reserved == 0;
    }
};

pub fn decodeCommandDatagram(bytes: []const u8) ?CommandPacket {
    if (bytes.len != @sizeOf(CommandPacket)) return null;
    var packet: CommandPacket = undefined;
    @memcpy(std.mem.asBytes(&packet), bytes);
    _ = packet.command() orelse return null;
    return packet;
}

pub fn decodeReportDatagram(bytes: []const u8) ?Report {
    if (bytes.len != @sizeOf(Report)) return null;
    var report: Report = undefined;
    @memcpy(std.mem.asBytes(&report), bytes);
    if (!report.valid()) return null;
    return report;
}

comptime {
    if (@sizeOf(CommandPacket) > max_packet_bytes)
        @compileError("slow-observer probe command exceeds private packet cap");
    if (@sizeOf(Report) > max_packet_bytes)
        @compileError("slow-observer probe report exceeds private packet cap");
}

test "command packet rejects every authority field corruption" {
    const valid = CommandPacket.init(7, .snapshot);
    try std.testing.expectEqual(Command.snapshot, valid.command().?);

    var bad = valid;
    bad.magic = 0;
    try std.testing.expect(bad.command() == null);
    bad = valid;
    bad.version += 1;
    try std.testing.expect(bad.command() == null);
    bad = valid;
    bad.length -= 1;
    try std.testing.expect(bad.command() == null);
    bad = valid;
    bad.sequence = 0;
    try std.testing.expect(bad.command() == null);
    bad = valid;
    bad.action = 0xff;
    try std.testing.expect(bad.command() == null);
    bad = valid;
    bad.reserved[0] = 1;
    try std.testing.expect(bad.command() == null);
}

test "report rejects every framing field corruption" {
    const telemetry: session_host.poll_owner.TelemetrySnapshot = .{
        .accounting = std.mem.zeroes(
            session_host.connection_slot.ReactorCore.AccountingSnapshot,
        ),
        .pressure_reclaims = 0,
        .stalled_clients = 0,
        .active_clients = 0,
        .total_admitted = 0,
        .pollout_absent_count = 0,
        .first_stall_connection_id = 0,
        .first_stall_ns = 0,
        .first_stall_send_buffer_bytes = 0,
        .stale_client_observations = 0,
    };
    const valid = Report.from(9, .snapshot, telemetry, 0, .{
        .notify_attempts = 0,
        .published_writes = 0,
        .coalesced_writes = 0,
        .drain_turns = 0,
    }, .{
        .live_child_pid = 0,
        .reaped_children = 0,
        .last_exit_status = -1,
    }, .{
        .materializations = 0,
        .core_lock_acquisitions = 0,
        .core_lock_hold_total_ns = 0,
        .core_lock_hold_max_ns = 0,
    }, .{
        .visits = 0,
        .changes = 0,
        .failures = 0,
        .producer_visits = 0,
    }, .{
        .snapshot_calls = 0,
        .delta_calls = 0,
        .owned_allocations = 0,
        .core_lock_acquisitions = 0,
    });
    try std.testing.expect(valid.valid());

    var bad = valid;
    bad.magic = 0;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.version += 1;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.length -= 1;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.sequence = 0;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.kind = 0xff;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.reserved[0] = 1;
    try std.testing.expect(!bad.valid());
    bad = valid;
    bad.exit_reserved = 1;
    try std.testing.expect(!bad.valid());
}

test "exact packet decodes and exact plus one datagram is rejected" {
    const command = CommandPacket.init(17, .stop);
    try std.testing.expectEqual(
        Command.stop,
        decodeCommandDatagram(std.mem.asBytes(&command)).?.command().?,
    );
    var oversized_command: [@sizeOf(CommandPacket) + 1]u8 = undefined;
    @memcpy(oversized_command[0..@sizeOf(CommandPacket)], std.mem.asBytes(&command));
    oversized_command[oversized_command.len - 1] = 0;
    try std.testing.expect(decodeCommandDatagram(&oversized_command) == null);

    const telemetry: session_host.poll_owner.TelemetrySnapshot = .{
        .accounting = std.mem.zeroes(
            session_host.connection_slot.ReactorCore.AccountingSnapshot,
        ),
        .pressure_reclaims = 0,
        .stalled_clients = 0,
        .active_clients = 0,
        .total_admitted = 0,
        .pollout_absent_count = 0,
        .first_stall_connection_id = 0,
        .first_stall_ns = 0,
        .first_stall_send_buffer_bytes = 0,
        .stale_client_observations = 0,
    };
    const report = Report.from(18, .stop_ack, telemetry, 0, .{
        .notify_attempts = 0,
        .published_writes = 0,
        .coalesced_writes = 0,
        .drain_turns = 0,
    }, .{
        .live_child_pid = 0,
        .reaped_children = 0,
        .last_exit_status = -1,
    }, .{
        .materializations = 0,
        .core_lock_acquisitions = 0,
        .core_lock_hold_total_ns = 0,
        .core_lock_hold_max_ns = 0,
    }, .{
        .visits = 0,
        .changes = 0,
        .failures = 0,
        .producer_visits = 0,
    }, .{
        .snapshot_calls = 0,
        .delta_calls = 0,
        .owned_allocations = 0,
        .core_lock_acquisitions = 0,
    });
    try std.testing.expectEqual(
        ReportKind.stop_ack,
        @as(ReportKind, @enumFromInt(decodeReportDatagram(
            std.mem.asBytes(&report),
        ).?.kind)),
    );
    var oversized_report: [@sizeOf(Report) + 1]u8 = undefined;
    @memcpy(oversized_report[0..@sizeOf(Report)], std.mem.asBytes(&report));
    oversized_report[oversized_report.len - 1] = 0;
    try std.testing.expect(decodeReportDatagram(&oversized_report) == null);
}
