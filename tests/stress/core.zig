const std = @import("std");
const maru = @import("maru");
const artifacts = @import("test_support");
const stress_options = @import("stress_options");

const Profile = struct {
    mode_name: []const u8,
    output_lines: usize,
    resize_iterations: usize,
};

test "stress: repeated output keeps final screen bounded and inspectable" {
    // This test is intentionally not a benchmark. It protects the root cause
    // of terminal failures where many process-output chunks leave the screen
    // state inconsistent, loop forever, or fail without useful artifacts.
    const allocator = std.testing.allocator;
    const p = profile();

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 8 });
    defer core.deinit();

    var input_bytes: usize = 0;
    for (0..p.output_lines) |line_no| {
        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("line-{d}\r\n", .{line_no});

        const bytes = writer.buffered();
        input_bytes += bytes.len;
        try core.write(bytes);
    }

    const expected_last_line = try std.fmt.allocPrint(allocator, "line-{d}", .{p.output_lines - 1});
    defer allocator.free(expected_last_line);

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);

    try std.testing.expect(std.mem.indexOf(u8, screen, expected_last_line) != null);
    try std.testing.expectEqual(@as(usize, 40 * 8), core.snapshot().cells.len);

    try writeScreenArtifact(allocator, p, "large-output.screen.txt", screen);
    try writeSnapshotArtifact(allocator, p, "large-output.snapshot.txt", core.snapshot());
    try writeSummaryArtifact(allocator, p, "large-output.summary.txt", .{
        .lines = p.output_lines,
        .input_bytes = input_bytes,
        .cols = core.snapshot().size.cols,
        .rows = core.snapshot().size.rows,
    });
}

test "stress: repeated resize and writes keep storage invariants valid" {
    // Resize stress matters because terminal surfaces resize often: app window
    // changes, split surfaces, font-size changes, and future workspace restore
    // all exercise the same storage boundary.
    const allocator = std.testing.allocator;
    const p = profile();

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();

    for (0..p.resize_iterations) |iteration| {
        const cols: u16 = @intCast(10 + (iteration % 90));
        const rows: u16 = @intCast(2 + (iteration % 20));
        try core.resize(cols, rows);

        var line_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        try writer.print("resize-{d}", .{iteration});
        try core.write(writer.buffered());

        const snapshot = core.snapshot();
        try std.testing.expectEqual(@as(usize, cols) * @as(usize, rows), snapshot.cells.len);
        try std.testing.expect(snapshot.cursor.row < rows);
        try std.testing.expect(snapshot.cursor.col < cols);
        const dirty = snapshot.dirty orelse return error.ExpectedDirtyRegion;
        try std.testing.expect(dirty.start_row <= dirty.end_row);
        try std.testing.expect(dirty.end_row < rows);
    }

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);

    try writeScreenArtifact(allocator, p, "resize-loop.screen.txt", screen);
    try writeSnapshotArtifact(allocator, p, "resize-loop.snapshot.txt", core.snapshot());
    try writeSummaryArtifact(allocator, p, "resize-loop.summary.txt", .{
        .lines = p.resize_iterations,
        .input_bytes = 0,
        .cols = core.snapshot().size.cols,
        .rows = core.snapshot().size.rows,
    });
}

fn profile() Profile {
    if (stress_options.soak) {
        return .{
            .mode_name = "soak",
            .output_lines = 20_000,
            .resize_iterations = 2_000,
        };
    }

    return .{
        .mode_name = "quick",
        .output_lines = 2_000,
        .resize_iterations = 200,
    };
}

fn writeScreenArtifact(
    allocator: std.mem.Allocator,
    p: Profile,
    name: []const u8,
    contents: []const u8,
) !void {
    const path = try artifactPath(allocator, p, name);
    defer allocator.free(path);

    try artifacts.writeTextWithFinalNewline(allocator, path, contents);
}

fn writeSnapshotArtifact(
    allocator: std.mem.Allocator,
    p: Profile,
    name: []const u8,
    snapshot: maru.terminal.RenderSnapshot,
) !void {
    const rendered = try maru.observability.snapshot.renderTerminalSnapshot(allocator, snapshot);
    defer allocator.free(rendered);

    const path = try artifactPath(allocator, p, name);
    defer allocator.free(path);

    try artifacts.writeText(path, rendered);
}

const Summary = struct {
    lines: usize,
    input_bytes: usize,
    cols: u16,
    rows: u16,
};

fn writeSummaryArtifact(
    allocator: std.mem.Allocator,
    p: Profile,
    name: []const u8,
    summary: Summary,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.print(
        "mode={s}\nlines={d}\ninput_bytes={d}\ncols={d}\nrows={d}\n",
        .{ p.mode_name, summary.lines, summary.input_bytes, summary.cols, summary.rows },
    );

    const rendered = try output.toOwnedSlice();
    defer allocator.free(rendered);

    const path = try artifactPath(allocator, p, name);
    defer allocator.free(path);

    try artifacts.writeText(path, rendered);
}

fn artifactPath(allocator: std.mem.Allocator, p: Profile, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "tests/artifacts/stress/{s}/{s}", .{ p.mode_name, name });
}
