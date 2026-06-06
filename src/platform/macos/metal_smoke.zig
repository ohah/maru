const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const terminal = maru.terminal;

const artifact_dir = "zig-out/maru-macos-metal-smoke";
const default_duration_ms: u32 = 1500;
// Metal smoke도 사람이 볼 수 있는 짧은 UI 확인이 목적이다. 환경변수 오타로
// 로컬 작업이나 CI runner가 오래 붙잡히지 않도록 window smoke와 같은 상한을 둔다.
const max_duration_ms: u32 = 600_000;

const NativeMetalSmokeResult = extern struct {
    status: c_int,
    window_visible: u32,
    presented_frames: u32,
    drawable_failures: u32,
    requested_cells: u32,
    rendered_cells: u32,
    readback_samples: u32,
    readback_non_clear_pixels: u32,
    readback_failures: u32,
};

const NativeMetalCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
    reserved: u16 = 0,
    codepoint: u32,
};

extern fn maru_macos_metal_smoke_run(
    duration_ms: u32,
    cols: u16,
    rows: u16,
    cells: [*]const NativeMetalCell,
    cell_count: usize,
    result: *NativeMetalSmokeResult,
) void;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const duration_ms = readDurationMs();
    var native: NativeMetalSmokeResult = .{
        .status = -1,
        .window_visible = 0,
        .presented_frames = 0,
        .drawable_failures = 0,
        .requested_cells = 0,
        .rendered_cells = 0,
        .readback_samples = 0,
        .readback_non_clear_pixels = 0,
        .readback_failures = 0,
    };
    var fixture = try buildSmokeFixture(allocator);
    defer fixture.deinit(allocator);
    maru_macos_metal_smoke_run(
        duration_ms,
        fixture.size.cols,
        fixture.size.rows,
        fixture.cells.ptr,
        fixture.cells.len,
        &native,
    );

    const smoke_status = deriveSmokeStatus(native);
    const summary = try renderSummary(allocator, duration_ms, smoke_status, native);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!smoke_status.terminal_grid) return error.MacosMetalSmokeFailed;
}

fn readDurationMs() u32 {
    // window smoke와 별도 환경변수를 쓰면, AppKit 창 확인과 Metal frame 확인 시간을
    // 독립적으로 조절할 수 있다. parsing 정책은 같은 smoke UX를 위해 동일하게 둔다.
    const raw_ptr = std.c.getenv("MARU_METAL_SMOKE_MS") orelse return default_duration_ms;
    return durationFromEnv(std.mem.span(raw_ptr));
}

fn durationFromEnv(raw: []const u8) u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch return default_duration_ms;
    if (parsed == 0) return default_duration_ms;
    return @min(parsed, max_duration_ms);
}

const SmokeStatus = struct {
    visible_ui: bool,
    metal_surface: bool,
    terminal_grid: bool,
};

fn deriveSmokeStatus(native: NativeMetalSmokeResult) SmokeStatus {
    // terminal_grid는 "cell_count를 되돌려받았다"가 아니라 "실제 GPU 결과에서 clear
    // 색이 아닌 픽셀을 readback했다"는 신호여야 한다. 샘플한 셀 중심이 하나라도가
    // 아니라 전부 비-clear여야 부분 렌더 회귀까지 잡는다. rendered_cells==requested는
    // 항상 참이라(제출 셀 수를 그대로 돌려줌) 게이트에 넣지 않는다.
    const visible_ui = native.window_visible != 0;
    const metal_surface = native.presented_frames > 0;
    const readback_found_cell_pixels = native.readback_samples > 0 and
        native.readback_non_clear_pixels == native.readback_samples and
        native.readback_failures == 0;

    return .{
        .visible_ui = visible_ui,
        .metal_surface = metal_surface,
        .terminal_grid = visible_ui and
            metal_surface and
            readback_found_cell_pixels,
    };
}

fn renderSummary(
    allocator: std.mem.Allocator,
    duration_ms: u32,
    smoke_status: SmokeStatus,
    native: NativeMetalSmokeResult,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-metal-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("visible_ui={}\n", .{smoke_status.visible_ui});
    try writer.print("metal_surface={}\n", .{smoke_status.metal_surface});
    try writer.print("terminal_grid={}\n", .{smoke_status.terminal_grid});
    try writer.writeAll("glyph_text=false\n");
    try writer.writeAll("ui_note=appkit_window_with_metal_drawlist_placeholder_readback_no_glyph_text\n");
    try writer.print("duration_ms={d}\n", .{duration_ms});
    try writer.print("native_status={d}\n", .{native.status});
    try writer.print("window_visible={d}\n", .{native.window_visible});
    try writer.print("presented_frames={d}\n", .{native.presented_frames});
    try writer.print("drawable_failures={d}\n", .{native.drawable_failures});
    try writer.print("requested_cells={d}\n", .{native.requested_cells});
    try writer.print("rendered_cells={d}\n", .{native.rendered_cells});
    try writer.print("readback_samples={d}\n", .{native.readback_samples});
    try writer.print("readback_non_clear_pixels={d}\n", .{native.readback_non_clear_pixels});
    try writer.print("readback_failures={d}\n", .{native.readback_failures});

    return output.toOwnedSlice();
}

const SmokeFixture = struct {
    size: terminal.Size,
    cells: []NativeMetalCell,

    fn deinit(self: *SmokeFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }
};

fn buildSmokeFixture(allocator: std.mem.Allocator) !SmokeFixture {
    // 아직 glyph rasterizer가 없으므로, terminal 문자열을 셀 사각형으로만 그린다.
    // 그래도 데이터 출처는 실제 TerminalCore -> DrawList 경로여야 한다. 이렇게 해야
    // smoke가 "Metal만 됨"이 아니라 "renderer 입력 계약을 Metal backend가 소비함"을 증명한다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 24, .rows = 6 });
    defer core.deinit();

    core.clearDirty();
    try core.write("Maru\r\nMetal");

    var list = try renderer.buildDrawList(allocator, core.snapshot());
    defer list.deinit(allocator);

    return .{
        .size = list.size,
        .cells = try buildNativeCells(allocator, list),
    };
}

fn buildNativeCells(allocator: std.mem.Allocator, list: renderer.DrawList) ![]NativeMetalCell {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    try cells.ensureTotalCapacity(allocator, list.cells.len);
    for (list.cells) |cell| {
        // DrawList는 dirty row 전체를 담기 때문에 blank cell도 많다. Metal smoke의
        // 목적은 terminal-cell placeholder가 눈에 보이는지 확인하는 것이므로, 실제
        // 글자가 있는 셀만 native bridge로 넘겨 검증 신호를 선명하게 만든다.
        if (cell.codepoint == ' ') continue;
        cells.appendAssumeCapacity(.{
            .row = cell.row,
            .col = cell.col,
            .width = cell.width,
            .codepoint = cell.codepoint,
        });
    }

    return cells.toOwnedSlice(allocator);
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/metal.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS Metal smoke summary reports DrawList placeholder boundary" {
    // 실제 Metal device를 만들지 않는 테스트에서도 artifact 계약은 고정한다.
    // GPU 실패와 summary schema 변경을 분리해야 triage가 쉬워진다.
    const native: NativeMetalSmokeResult = .{
        .status = 0,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 1,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 9,
        .readback_failures = 0,
    };
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-metal-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_surface=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_grid=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "window_visible=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "presented_frames=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawable_failures=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_cells=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "rendered_cells=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_samples=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_non_clear_pixels=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_failures=0\n") != null);
}

test "Metal smoke terminal grid requires every sampled readback pixel non-clear" {
    // 이 테스트가 없으면 native bridge가 입력 cell_count를 그대로 되돌려도
    // terminal_grid=true가 된다. 샘플한 셀 중심이 전부 clear 색이 아닐 때만
    // terminal_grid를 true로 올린다는 계약을 고정한다(부분 렌더/readback 실패는 false).
    const no_readback: NativeMetalSmokeResult = .{
        .status = 9,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 0,
        .readback_failures = 0,
    };
    const partial_readback: NativeMetalSmokeResult = .{
        .status = 9,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 8,
        .readback_failures = 0,
    };
    const readback_failed: NativeMetalSmokeResult = .{
        .status = 9,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 9,
        .readback_failures = 1,
    };
    const all_pixels: NativeMetalSmokeResult = .{
        .status = 0,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 9,
        .readback_failures = 0,
    };

    try std.testing.expect(!deriveSmokeStatus(no_readback).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(partial_readback).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).terminal_grid);
    try std.testing.expect(deriveSmokeStatus(all_pixels).terminal_grid);
}

test "Metal smoke duration override clamps invalid, zero, and oversized values" {
    // 0ms나 너무 큰 값이 native smoke로 들어가면 실제 화면 검증의 의미가 사라진다.
    // window smoke와 같은 guardrail을 유지해 수동 실행과 자동 테스트를 예측 가능하게 한다.
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("abc"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv(""));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("0"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("99999999999")); // > u32 max
    try std.testing.expectEqual(@as(u32, 250), durationFromEnv("250"));
    try std.testing.expectEqual(max_duration_ms, durationFromEnv("99999999")); // > 상한
}

test "Metal smoke fixture comes from DrawList cells" {
    // 이 테스트는 native bridge 없이도 smoke 입력이 실제 renderer 계약에서 왔는지
    // 증명한다. 나중에 CoreText/glyph atlas가 붙어도 이 fixture는 "터미널 셀을
    // backend 입력으로 넘긴다"는 가장 작은 세로 슬라이스로 남는다.
    var fixture = try buildSmokeFixture(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 24), fixture.size.cols);
    try std.testing.expectEqual(@as(u16, 6), fixture.size.rows);
    try std.testing.expectEqual(@as(usize, 9), fixture.cells.len);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].col);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[4].codepoint);
    try std.testing.expectEqual(@as(u16, 1), fixture.cells[4].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[4].col);
}
