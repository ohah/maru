const std = @import("std");

const artifact_dir = "zig-out/maru-macos-window-smoke";
const default_duration_ms: u32 = 1500;

extern fn maru_macos_window_smoke_run(duration_ms: u32) c_int;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const duration_ms = readDurationMs();
    const status = maru_macos_window_smoke_run(duration_ms);
    const visible_ui = status == 0;

    const summary = try renderSummary(allocator, duration_ms, visible_ui, status);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!visible_ui) return error.MacosWindowSmokeFailed;
}

fn readDurationMs() u32 {
    // 실제 창이 너무 빨리 닫히면 사람이 확인하기 어렵다. 기본값은 짧게 두되,
    // 필요하면 환경변수로 늘려 같은 smoke를 수동 확인에도 쓸 수 있게 한다.
    const raw_ptr = std.c.getenv("MARU_WINDOW_SMOKE_MS") orelse return default_duration_ms;
    const raw = std.mem.span(raw_ptr);

    return std.fmt.parseInt(u32, raw, 10) catch default_duration_ms;
}

fn renderSummary(
    allocator: std.mem.Allocator,
    duration_ms: u32,
    visible_ui: bool,
    status: c_int,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-window-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("visible_ui={}\n", .{visible_ui});
    try writer.writeAll("ui_note=appkit_window_only_no_metal_or_terminal_grid\n");
    try writer.print("duration_ms={d}\n", .{duration_ms});
    try writer.print("native_status={d}\n", .{status});

    return output.toOwnedSlice();
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/window.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS window smoke summary reports visible UI boundary" {
    // 실제 Cocoa 창을 띄우지 않는 테스트에서도 artifact 계약은 고정한다.
    // 그래야 UI smoke가 실패했을 때 "창 생성 실패"와 "요약 포맷 변경"을 분리해서 볼 수 있다.
    const summary = try renderSummary(std.testing.allocator, 1500, true, 0);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-window-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_only_no_metal_or_terminal_grid\n") != null);
}
