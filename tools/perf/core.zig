const std = @import("std");
const maru = @import("maru");

const Budget = struct {
    name: []const u8,
    elapsed_ns: i96,
    budget_ns: i96,
    units: usize,

    fn passed(self: Budget) bool {
        return self.elapsed_ns <= self.budget_ns;
    }
};

const budgets = struct {
    const core_large_output_ns = 2 * std.time.ns_per_s;
    const core_resize_loop_ns = 1 * std.time.ns_per_s;
    const snapshot_serialize_ns = 1 * std.time.ns_per_s;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // 성능 측정은 실행 중인 머신 상태에 영향을 받기 때문에 기본 check에는 넣지 않는다.
    // 대신 큰 구조 변경 전후에 opt-in으로 실행해서 느린 구조가 조용히 들어오지 않게 한다.
    const results = [_]Budget{
        try measureLargeOutput(allocator, io),
        try measureResizeLoop(allocator, io),
        try measureSnapshotSerialization(allocator, io),
    };

    const report = try renderReport(allocator, &results);
    defer allocator.free(report);

    try writeText(io, "tests/artifacts/perf/core.txt", report);
    try stdout.writeAll(report);
    try stdout.flush();

    for (results) |result| {
        if (!result.passed()) return error.PerformanceBudgetExceeded;
    }
}

fn measureLargeOutput(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();

    // 터미널은 빌드 로그처럼 큰 stdout을 자주 받으므로, 많은 줄을 쓰는 경로를 먼저 지킨다.
    const line_count = 100_000;
    const start = now(io);
    for (0..line_count) |line_no| {
        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("perf-line-{d}\r\n", .{line_no});
        try core.write(writer.buffered());
    }
    const elapsed = now(io) - start;

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);
    if (std.mem.indexOf(u8, screen, "perf-line-99999") == null) {
        return error.PerfResultMissingExpectedLine;
    }

    return .{
        .name = "core_large_output",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_large_output_ns,
        .units = line_count,
    };
}

fn measureResizeLoop(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();

    // 창 크기 변경은 split, font size 변경, workspace 복구에서 자주 일어나므로 별도 예산으로 본다.
    const iterations = 5_000;
    const start = now(io);
    for (0..iterations) |iteration| {
        const cols: u16 = @intCast(20 + (iteration % 120));
        const rows: u16 = @intCast(4 + (iteration % 36));
        try core.resize(cols, rows);

        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("perf-resize-{d}", .{iteration});
        try core.write(writer.buffered());
    }
    const elapsed = now(io) - start;

    const snapshot = core.snapshot();
    const expected_cells = @as(usize, snapshot.size.cols) * @as(usize, snapshot.size.rows);
    if (snapshot.cells.len != expected_cells) {
        return error.PerfResultInvalidCellCount;
    }

    return .{
        .name = "core_resize_loop",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.core_resize_loop_ns,
        .units = iterations,
    };
}

fn measureSnapshotSerialization(allocator: std.mem.Allocator, io: std.Io) !Budget {
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 120, .rows = 40 });
    defer core.deinit();

    // snapshot은 로그, E2E, 미래 inspector가 공유할 관측 데이터라서 너무 무거워지면 안 된다.
    for (0..400) |line_no| {
        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("snapshot-source-{d}\r\n", .{line_no});
        try core.write(writer.buffered());
    }

    const iterations = 200;
    const start = now(io);
    for (0..iterations) |_| {
        const rendered = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
        allocator.free(rendered);
    }
    const elapsed = now(io) - start;

    return .{
        .name = "snapshot_serialize",
        .elapsed_ns = elapsed,
        .budget_ns = budgets.snapshot_serialize_ns,
        .units = iterations,
    };
}

fn renderReport(allocator: std.mem.Allocator, results: []const Budget) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.writeAll("maru.perf.v1\n");
    for (results) |result| {
        try output.writer.print(
            "name={s} elapsed_ms={d} budget_ms={d} units={d} status={s}\n",
            .{
                result.name,
                nsToMs(result.elapsed_ns),
                nsToMs(result.budget_ns),
                result.units,
                if (result.passed()) "pass" else "fail",
            },
        );
    }

    return output.toOwnedSlice();
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn nsToMs(ns: i96) i64 {
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try ensureParent(io, path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash == 0) return;
        try std.Io.Dir.cwd().createDirPath(io, path[0..slash]);
    }
}
