const std = @import("std");

const artifact_dir = "zig-out/maru-macos-window-smoke";
const default_duration_ms: u32 = 1500;
// 수동 확인용으로 늘려도 오타(예: 1500000)나 악의적 값이 빌드를 며칠씩 멈추지
// 않도록 상한을 둔다. smoke는 짧게 보이는 창을 확인하는 용도다.
const max_duration_ms: u32 = 600_000;

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
    return durationFromEnv(std.mem.span(raw_ptr));
}

fn durationFromEnv(raw: []const u8) u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch return default_duration_ms;
    // 0ms는 창을 보여달라는 요청이 될 수 없다. 그대로 두면 native event pump가
    // 한 번도 안 돌아 창이 뜨자마자 사라지는데도 visible_ui=true가 된다. 기본값으로
    // 되돌리고, 비정상적으로 큰 값은 상한으로 잘라 runaway를 막는다.
    if (parsed == 0) return default_duration_ms;
    return @min(parsed, max_duration_ms);
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

test "window smoke duration override clamps invalid, zero, and oversized values" {
    // 0ms와 비정상 값이 그대로 native pump로 넘어가면 창이 안 보이는데도
    // visible_ui=true가 되거나 빌드가 runaway로 멈출 수 있다. 그 경계를 고정한다.
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("abc"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv(""));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("0"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("99999999999")); // > u32 max
    try std.testing.expectEqual(@as(u32, 250), durationFromEnv("250"));
    try std.testing.expectEqual(max_duration_ms, durationFromEnv("99999999")); // > 상한
}
