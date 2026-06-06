const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;
const terminal = maru.terminal;

const artifact_dir = "zig-out/maru-macos-metal-smoke";
const default_duration_ms: u32 = 1500;
const renderer_probe_shaper = "fake_font_backend";
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
    slot_id: u32,
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
    const summary = try renderSummary(allocator, duration_ms, smoke_status, native, fixture);
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
    fixture: SmokeFixture,
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
    try writer.writeAll("ui_note=appkit_window_with_metal_glyph_frame_placeholder_readback_no_glyph_text\n");
    try writer.writeAll("renderer_input=renderer_state_glyph_frame\n");
    try writer.print("renderer_frame_prepared={}\n", .{fixture.frame_prepared});
    try writer.print("renderer_backend={s}\n", .{@tagName(fixture.backend)});
    try writer.print("renderer_shaper={s}\n", .{fixture.shaper});
    try writer.print("renderer_draw_cells={d}\n", .{fixture.draw_cells});
    try writer.print("renderer_glyph_count={d}\n", .{fixture.glyph_count});
    try writer.print("renderer_glyph_upload_count={d}\n", .{fixture.upload_count});
    try writer.print("renderer_glyph_reused_count={d}\n", .{fixture.reused_count});
    try writer.print("renderer_atlas_entries={d}\n", .{fixture.atlas_entries});
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
    frame_prepared: bool,
    backend: renderer.Backend,
    shaper: []const u8 = renderer_probe_shaper,
    draw_cells: usize,
    glyph_count: usize,
    upload_count: usize,
    reused_count: usize,
    atlas_entries: usize,

    fn deinit(self: *SmokeFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }
};

fn buildSmokeFixture(allocator: std.mem.Allocator) !SmokeFixture {
    // 아직 glyph rasterizer가 없으므로, native bridge는 셀 사각형 placeholder를 그린다.
    // 대신 입력 출처를 RendererState -> GlyphFrame까지 올린다. 이렇게 해야 Metal smoke가
    // DrawList 직행 demo로 굳지 않고, backend가 제품 renderer frame 경계에서 받은 slot
    // 단위 데이터를 소비한다는 사실을 artifact로 남길 수 있다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 24, .rows = 6 });
    defer core.deinit();

    core.clearDirty();
    try core.write("Maru\r\nMetal");

    var state = renderer.RendererState.init(allocator, .{});
    defer state.deinit();

    var frame = try state.buildFrame(allocator, core.snapshot(), renderer.FakeFontBackend{});
    defer frame.deinit(allocator);

    const native_cells = try buildNativeCellsFromGlyphFrame(allocator, frame.glyph_frame);
    errdefer allocator.free(native_cells);

    const glyph_frame = frame.glyph_frame;
    const atlas_entries = state.atlas.entryCount();
    // renderer_frame_prepared 의미를 glyph_text_smoke probe와 똑같이 맞춘다: frame 일관성에
    // 더해 실제로 glyph가 잡혔고 atlas가 채워졌는지(>0)까지 봐야 빈 frame을 prepared로
    // 보고하지 않고, 두 smoke의 같은 summary 키가 같은 뜻을 갖는다.
    const frame_prepared = frame.glyphFrameConsistent() and
        glyph_frame.stats.glyph_count > 0 and
        atlas_entries > 0;

    return .{
        .size = glyph_frame.size,
        .cells = native_cells,
        .frame_prepared = frame_prepared,
        .backend = frame.backend,
        .draw_cells = frame.draw_list.cells.len,
        .glyph_count = glyph_frame.stats.glyph_count,
        .upload_count = glyph_frame.stats.upload_count,
        .reused_count = glyph_frame.stats.reused_count,
        .atlas_entries = atlas_entries,
    };
}

fn buildNativeCellsFromGlyphFrame(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphFrame,
) ![]NativeMetalCell {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    try cells.ensureTotalCapacity(allocator, frame.glyphs.len);
    for (frame.glyphs) |glyph| {
        // GlyphFrame은 dirty row 전체의 glyph 준비 결과를 담기 때문에 blank cell도 많다.
        // Metal smoke의 목적은 terminal-cell placeholder가 눈에 보이는지 확인하는 것이므로,
        // 실제 글자가 있는 glyph만 native bridge로 넘겨 검증 신호를 선명하게 만든다.
        if (glyph.run.codepoint == ' ') continue;
        cells.appendAssumeCapacity(.{
            .row = glyph.run.row,
            .col = glyph.run.col,
            .width = glyph.run.cell_width,
            .codepoint = glyph.run.codepoint,
            .slot_id = glyph.slot.id,
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

test "macOS Metal smoke summary reports GlyphFrame placeholder boundary" {
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
    var empty_cells = [_]NativeMetalCell{};
    const fixture: SmokeFixture = .{
        .size = .{ .cols = 24, .rows = 6 },
        .cells = empty_cells[0..],
        .frame_prepared = true,
        .backend = .metal,
        .shaper = renderer_probe_shaper,
        .draw_cells = 48,
        .glyph_count = 48,
        .upload_count = 8,
        .reused_count = 40,
        .atlas_entries = 8,
    };
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, fixture);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-metal-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_surface=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_grid=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_with_metal_glyph_frame_placeholder_readback_no_glyph_text\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=renderer_state_glyph_frame\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=fake_font_backend\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_cells=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_count=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_upload_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_reused_count=40\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_entries=8\n") != null);
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

test "Metal smoke fixture comes from RendererState glyph frame" {
    // 이 테스트는 native bridge 없이도 smoke 입력이 제품 renderer frame 계약에서 왔는지
    // 증명한다. 아직 placeholder quad를 그려도, Metal 경계에 넘기는 데이터는 DrawList가
    // 아니라 atlas slot이 준비된 GlyphFrame이어야 다음 text renderer 단계와 이어진다.
    var fixture = try buildSmokeFixture(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 24), fixture.size.cols);
    try std.testing.expectEqual(@as(u16, 6), fixture.size.rows);
    try std.testing.expect(fixture.frame_prepared);
    try std.testing.expectEqual(renderer.Backend.metal, fixture.backend);
    try std.testing.expectEqualStrings("fake_font_backend", fixture.shaper);
    try std.testing.expect(fixture.draw_cells >= fixture.cells.len);
    try std.testing.expect(fixture.glyph_count >= fixture.cells.len);
    // frame 통계는 dirty row의 공백 glyph까지 포함하지만, visible placeholder smoke는
    // 사람이 보기 쉬운 신호를 위해 공백 cell을 native bridge로 넘기지 않는다.
    try std.testing.expect(fixture.upload_count > 0);
    try std.testing.expect(fixture.atlas_entries > 0);
    // 모든 glyph는 upload 아니면 reuse 둘 중 하나라, 이 합이 glyph_count와 맞아야 probe
    // 통계가 backend로 일관되게 흘러간다(slot 재사용 회귀를 통계 단계에서 잡는다).
    try std.testing.expectEqual(fixture.glyph_count, fixture.upload_count + fixture.reused_count);
    try std.testing.expectEqual(@as(usize, 9), fixture.cells.len);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].col);
    // cell_width가 native bridge로 보존되는지 고정한다(ASCII placeholder는 1셀 폭).
    try std.testing.expectEqual(@as(u16, 1), fixture.cells[0].width);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[4].codepoint);
    try std.testing.expectEqual(@as(u16, 1), fixture.cells[4].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[4].col);
    try std.testing.expect(fixture.cells[0].slot_id > 0);
    try std.testing.expectEqual(fixture.cells[0].slot_id, fixture.cells[4].slot_id);
}
