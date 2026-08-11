//! 종료 실패 진단을 UI나 logger 수명과 분리해 먼저 회수 가능한 값으로 만든다.

const std = @import("std");
const contract = @import("shutdown_contract.zig");

pub const capacity = 64;
const reason_count = @typeInfo(contract.ShutdownDiagnosticReason).@"enum".fields.len;

pub const ShutdownDiagnosticOverflow = struct {
    dropped_count: u32 = 0,
    counter_saturated: bool = false,
};

pub const ShutdownDiagnosticBatch = struct {
    details: [capacity]contract.ShutdownDiagnostic = undefined,
    detail_count: u8 = 0,
    overflow: [reason_count]ShutdownDiagnosticOverflow = [_]ShutdownDiagnosticOverflow{.{}} ** reason_count,
};

pub const ShutdownDiagnosticSink = struct {
    batch: ShutdownDiagnosticBatch = .{},

    pub fn push(self: *ShutdownDiagnosticSink, diagnostic: contract.ShutdownDiagnostic) void {
        if (self.batch.detail_count < capacity) {
            self.batch.details[self.batch.detail_count] = diagnostic;
            self.batch.detail_count += 1;
            return;
        }
        const index = @intFromEnum(diagnostic.reason);
        const overflow = &self.batch.overflow[index];
        if (overflow.dropped_count == std.math.maxInt(u32)) {
            overflow.counter_saturated = true;
            return;
        }
        overflow.dropped_count += 1;
    }

    /// callback이 재진입해도 이전 batch를 다시 볼 수 없도록 consumer 호출 전에 source를 비운다.
    pub fn drainBatch(self: *ShutdownDiagnosticSink) ShutdownDiagnosticBatch {
        const batch = self.batch;
        self.batch = .{};
        return batch;
    }
};

pub const ShutdownDiagnosticAdmission = struct {
    emitted: bool = false,
};

pub fn emitOnce(
    admission: *ShutdownDiagnosticAdmission,
    sink: *ShutdownDiagnosticSink,
    diagnostic: contract.ShutdownDiagnostic,
) bool {
    if (admission.emitted) return false;
    admission.emitted = true;
    sink.push(diagnostic);
    return true;
}

pub const ShutdownDiagnosticConsumerPort = struct {
    context: *anyopaque,
    project_notice: *const fn (*anyopaque, contract.ShutdownDiagnostic) anyerror!void,
    log: *const fn (*anyopaque, contract.ShutdownDiagnostic) anyerror!void,
    report_overflow: *const fn (*anyopaque, contract.ShutdownDiagnosticReason, ShutdownDiagnosticOverflow) anyerror!void,
};

pub fn drainToConsumers(
    sink: *ShutdownDiagnosticSink,
    app_quit: bool,
    port: ShutdownDiagnosticConsumerPort,
) void {
    const batch = sink.drainBatch();
    for (batch.details[0..batch.detail_count]) |diagnostic| {
        if (!app_quit) port.project_notice(port.context, diagnostic) catch {};
        port.log(port.context, diagnostic) catch {};
    }
    for (batch.overflow, 0..) |overflow, index| {
        if (overflow.dropped_count == 0 and !overflow.counter_saturated) continue;
        port.report_overflow(port.context, @enumFromInt(index), overflow) catch {};
    }
}

fn testDiagnostic(reason: contract.ShutdownDiagnosticReason) contract.ShutdownDiagnostic {
    return .{
        .reason = reason,
        .target_ordinal = 1,
        .attempt_count = 3,
        .elapsed_bucket = .lt15s,
        .app_quit = true,
    };
}

test "C3-3b6 진단 sink는 detail 0개와 64개를 FIFO로 보존한다" {
    var sink: ShutdownDiagnosticSink = .{};
    try std.testing.expectEqual(@as(u8, 0), sink.drainBatch().detail_count);
    for (0..capacity) |index| {
        var row = testDiagnostic(.terminate_unconfirmed);
        row.target_ordinal = @intCast(index);
        sink.push(row);
    }
    const batch = sink.drainBatch();
    try std.testing.expectEqual(@as(u8, capacity), batch.detail_count);
    for (batch.details[0..batch.detail_count], 0..) |row, index|
        try std.testing.expectEqual(@as(u16, @intCast(index)), row.target_ordinal);
}

test "C3-3b6 진단 sink는 65번째부터 reason별 drop summary를 남긴다" {
    var sink: ShutdownDiagnosticSink = .{};
    for (0..capacity) |_| sink.push(testDiagnostic(.terminate_unconfirmed));
    sink.push(testDiagnostic(.profile_incompatible));
    const batch = sink.drainBatch();
    try std.testing.expectEqual(@as(u32, 1), batch.overflow[@intFromEnum(contract.ShutdownDiagnosticReason.profile_incompatible)].dropped_count);
    try std.testing.expectEqual(@as(u32, 0), batch.overflow[@intFromEnum(contract.ShutdownDiagnosticReason.terminate_unconfirmed)].dropped_count);
}

test "C3-3b6 진단 sink는 dropped counter 포화를 sticky bit로 보존한다" {
    var sink: ShutdownDiagnosticSink = .{};
    sink.batch.detail_count = capacity;
    const index = @intFromEnum(contract.ShutdownDiagnosticReason.deadline_exhausted);
    sink.batch.overflow[index].dropped_count = std.math.maxInt(u32);
    sink.push(testDiagnostic(.deadline_exhausted));
    try std.testing.expect(sink.batch.overflow[index].counter_saturated);
    try std.testing.expectEqual(std.math.maxInt(u32), sink.batch.overflow[index].dropped_count);
}

test "C3-3b6 진단은 close request마다 exact once 발행된다" {
    var sink: ShutdownDiagnosticSink = .{};
    var admission: ShutdownDiagnosticAdmission = .{};
    try std.testing.expect(emitOnce(&admission, &sink, testDiagnostic(.terminate_unconfirmed)));
    try std.testing.expect(!emitOnce(&admission, &sink, testDiagnostic(.deadline_exhausted)));
    try std.testing.expectEqual(@as(u8, 1), sink.batch.detail_count);
}

test "C3-3b6 진단 drain은 callback 전에 slot과 overflow를 reset한다" {
    var sink: ShutdownDiagnosticSink = .{};
    for (0..capacity + 1) |_| sink.push(testDiagnostic(.terminate_unconfirmed));
    const batch = sink.drainBatch();
    try std.testing.expectEqual(@as(u8, capacity), batch.detail_count);
    try std.testing.expectEqual(@as(u8, 0), sink.batch.detail_count);
    try std.testing.expectEqual(@as(u32, 0), sink.batch.overflow[0].dropped_count);
}

const ConsumerProbe = struct {
    notices: u8 = 0,
    logs: u8 = 0,
    overflows: u8 = 0,
    fail_notice: bool = false,
    fail_log: bool = false,

    fn notice(raw: *anyopaque, _: contract.ShutdownDiagnostic) !void {
        const self: *ConsumerProbe = @ptrCast(@alignCast(raw));
        self.notices += 1;
        if (self.fail_notice) return error.Injected;
    }

    fn log(raw: *anyopaque, _: contract.ShutdownDiagnostic) !void {
        const self: *ConsumerProbe = @ptrCast(@alignCast(raw));
        self.logs += 1;
        if (self.fail_log) return error.Injected;
    }

    fn overflow(raw: *anyopaque, _: contract.ShutdownDiagnosticReason, _: ShutdownDiagnosticOverflow) !void {
        const self: *ConsumerProbe = @ptrCast(@alignCast(raw));
        self.overflows += 1;
        if (self.fail_log) return error.Injected;
    }

    fn port(self: *ConsumerProbe) ShutdownDiagnosticConsumerPort {
        return .{ .context = self, .project_notice = notice, .log = log, .report_overflow = overflow };
    }
};

test "C3-3b6 진단 bridge는 live에서 notice와 logger에 value를 fan-out한다" {
    var sink: ShutdownDiagnosticSink = .{};
    sink.push(testDiagnostic(.terminate_unconfirmed));
    var probe: ConsumerProbe = .{};
    drainToConsumers(&sink, false, probe.port());
    try std.testing.expectEqual(@as(u8, 1), probe.notices);
    try std.testing.expectEqual(@as(u8, 1), probe.logs);
}

test "C3-3b6 진단 bridge는 reason별 overflow snapshot을 value로 전달한다" {
    var sink: ShutdownDiagnosticSink = .{};
    sink.batch.detail_count = capacity;
    sink.push(testDiagnostic(.profile_incompatible));
    var probe: ConsumerProbe = .{};
    drainToConsumers(&sink, false, probe.port());
    try std.testing.expectEqual(@as(u8, 1), probe.overflows);
    try std.testing.expectEqual(@as(u32, 0), sink.batch.overflow[@intFromEnum(contract.ShutdownDiagnosticReason.profile_incompatible)].dropped_count);
}

test "C3-3b6 진단 bridge는 quit과 consumer 실패 뒤 재삽입 없이 재사용된다" {
    var sink: ShutdownDiagnosticSink = .{};
    sink.push(testDiagnostic(.terminate_unconfirmed));
    var probe: ConsumerProbe = .{ .fail_notice = true, .fail_log = true };
    drainToConsumers(&sink, true, probe.port());
    try std.testing.expectEqual(@as(u8, 0), probe.notices);
    try std.testing.expectEqual(@as(u8, 1), probe.logs);
    try std.testing.expectEqual(@as(u8, 0), sink.batch.detail_count);
    sink.push(testDiagnostic(.deadline_exhausted));
    try std.testing.expectEqual(@as(u8, 1), sink.batch.detail_count);
}
