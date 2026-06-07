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
    atlas_texture_created: u32,
    atlas_uploads_requested: u32,
    atlas_uploads_uploaded: u32,
    atlas_upload_bytes: u32,
    atlas_readback_uploads: u32,
    atlas_readback_mismatched_bytes: u32,
    atlas_readback_failures: u32,
    atlas_sampled_cells: u32,
};

const NativeMetalCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
    reserved: u16 = 0,
    codepoint: u32,
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

const NativeMetalRasterUpload = extern struct {
    slot_id: u32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
    bytes_offset: usize,
    byte_count: usize,
    bytes_per_row: usize,
    non_clear_pixels: usize,
};

extern fn maru_macos_metal_smoke_run(
    duration_ms: u32,
    cols: u16,
    rows: u16,
    cells: [*]const NativeMetalCell,
    cell_count: usize,
    atlas_width_px: u32,
    atlas_height_px: u32,
    raster_uploads: [*]const NativeMetalRasterUpload,
    raster_upload_count: usize,
    raster_pixels: [*]const u8,
    raster_pixel_count: usize,
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
        .atlas_texture_created = 0,
        .atlas_uploads_requested = 0,
        .atlas_uploads_uploaded = 0,
        .atlas_upload_bytes = 0,
        .atlas_readback_uploads = 0,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 0,
    };
    var fixture = try buildSmokeFixture(allocator);
    defer fixture.deinit(allocator);
    maru_macos_metal_smoke_run(
        duration_ms,
        fixture.size.cols,
        fixture.size.rows,
        fixture.cells.ptr,
        fixture.cells.len,
        fixture.atlas_width_px,
        fixture.atlas_height_px,
        fixture.raster_uploads.ptr,
        fixture.raster_uploads.len,
        fixture.raster_pixels.ptr,
        fixture.raster_pixels.len,
        &native,
    );

    const smoke_status = deriveSmokeStatus(native);
    const summary = try renderSummary(allocator, duration_ms, smoke_status, native, fixture);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!smoke_status.terminal_grid or
        !smoke_status.product_atlas_uploaded or
        !smoke_status.product_atlas_sampled) return error.MacosMetalSmokeFailed;
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
    product_atlas_uploaded: bool,
    product_atlas_sampled: bool,
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
    const product_atlas_uploaded = native.atlas_texture_created != 0 and
        native.atlas_uploads_requested > 0 and
        native.atlas_uploads_uploaded == native.atlas_uploads_requested and
        native.atlas_readback_uploads == native.atlas_uploads_uploaded and
        native.atlas_upload_bytes > 0 and
        native.atlas_readback_mismatched_bytes == 0 and
        native.atlas_readback_failures == 0;
    const product_atlas_sampled = product_atlas_uploaded and
        native.atlas_sampled_cells == native.readback_samples and
        readback_found_cell_pixels;

    return .{
        .visible_ui = visible_ui,
        .metal_surface = metal_surface,
        .terminal_grid = visible_ui and
            metal_surface and
            readback_found_cell_pixels,
        .product_atlas_uploaded = product_atlas_uploaded,
        .product_atlas_sampled = product_atlas_sampled,
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
    try writer.print("product_atlas_uploaded={}\n", .{smoke_status.product_atlas_uploaded});
    try writer.print("product_atlas_sampled={}\n", .{smoke_status.product_atlas_sampled});
    try writer.writeAll("glyph_text=false\n");
    try writer.writeAll("ui_note=appkit_window_with_product_atlas_shader_sampling_fake_raster_no_coretext_glyph_text\n");
    try writer.writeAll("renderer_input=renderer_state_glyph_frame\n");
    try writer.print("renderer_atlas_slot_placement={}\n", .{nativeCellsHaveAtlasPlacement(fixture.cells)});
    // 제품 frame 통계는 renderer가 소유한 공유 직렬화기로 남긴다. glyph text smoke와 같은
    // "renderer_" schema를 쓰므로 두 artifact의 키가 어긋나지 않는다.
    try renderer.writeRenderFrameStats(writer, "renderer_", fixture.stats);
    try writer.print("renderer_shaper={s}\n", .{fixture.shaper});
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
    try writer.print("atlas_texture_created={d}\n", .{native.atlas_texture_created});
    try writer.print("atlas_uploads_requested={d}\n", .{native.atlas_uploads_requested});
    try writer.print("atlas_uploads_uploaded={d}\n", .{native.atlas_uploads_uploaded});
    try writer.print("atlas_upload_bytes={d}\n", .{native.atlas_upload_bytes});
    try writer.print("atlas_readback_uploads={d}\n", .{native.atlas_readback_uploads});
    try writer.print("atlas_readback_mismatched_bytes={d}\n", .{native.atlas_readback_mismatched_bytes});
    try writer.print("atlas_readback_failures={d}\n", .{native.atlas_readback_failures});
    try writer.print("atlas_sampled_cells={d}\n", .{native.atlas_sampled_cells});

    return output.toOwnedSlice();
}

const SmokeFixture = struct {
    size: terminal.Size,
    cells: []NativeMetalCell,
    atlas_width_px: u32,
    atlas_height_px: u32,
    raster_uploads: []NativeMetalRasterUpload,
    raster_pixels: []u8,
    // 제품 frame 통계는 renderer가 소유한 공유 타입으로 들고, native 입력(size, cells)과
    // 진단 통계를 한 struct에 모은다. shaper는 어떤 shaper로 frame을 준비했는지의 라벨이다.
    stats: renderer.RenderFrameStats,
    shaper: []const u8 = renderer_probe_shaper,

    fn deinit(self: *SmokeFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.raster_uploads);
        allocator.free(self.raster_pixels);
        self.* = undefined;
    }
};

fn buildSmokeFixture(allocator: std.mem.Allocator) !SmokeFixture {
    // 아직 제품 glyph rasterizer가 Metal cell text를 그리지 않으므로, native bridge는 셀
    // 사각형 placeholder를 그린다. 대신 입력 출처를 RendererState -> RenderFrame까지
    // 올려서 backend가 제품 renderer frame 경계에서 받은 slot/UV/raster upload 준비
    // 데이터를 소비한다는 사실을 artifact로 남긴다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 24, .rows = 6 });
    defer core.deinit();

    core.clearDirty();
    try core.write("Maru\r\nMetal");

    var state = renderer.RendererState.init(allocator, .{});
    defer state.deinit();

    var frame = try state.buildFrame(allocator, core.snapshot(), renderer.FakeFontBackend{});
    defer frame.deinit(allocator);

    const native_cells = try buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame);
    errdefer allocator.free(native_cells);
    const native_raster_uploads = try buildNativeRasterUploads(allocator, frame.glyph_raster_frame);
    errdefer allocator.free(native_raster_uploads);
    const native_raster_pixels = try allocator.dupe(u8, frame.glyph_raster_frame.pixels);
    errdefer allocator.free(native_raster_pixels);

    return .{
        .size = frame.glyph_frame.size,
        .cells = native_cells,
        .atlas_width_px = state.atlas.config.atlas_width_px,
        .atlas_height_px = state.atlas.config.atlas_height_px,
        .raster_uploads = native_raster_uploads,
        .raster_pixels = native_raster_pixels,
        .stats = renderer.renderFrameStats(frame, state.atlas.entryCount()),
    };
}

fn buildNativeCellsFromGlyphQuads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphQuadFrame,
) ![]NativeMetalCell {
    var cells: std.ArrayList(NativeMetalCell) = .empty;
    errdefer cells.deinit(allocator);

    try cells.ensureTotalCapacity(allocator, frame.glyphs.len);
    for (frame.glyphs) |glyph| {
        // GlyphQuadFrame은 dirty row 전체의 glyph와 UV 준비 결과를 담기 때문에 blank cell도 많다.
        // Metal smoke의 목적은 terminal-cell placeholder가 눈에 보이는지 확인하는 것이므로,
        // 실제 글자가 있는 glyph만 native bridge로 넘겨 검증 신호를 선명하게 만든다.
        if (glyph.run.codepoint == ' ') continue;
        cells.appendAssumeCapacity(.{
            .row = glyph.run.row,
            .col = glyph.run.col,
            .width = glyph.run.cell_width,
            .codepoint = glyph.run.codepoint,
            .slot_id = glyph.slot.id,
            .atlas_x_px = glyph.slot.x_px,
            .atlas_y_px = glyph.slot.y_px,
            .atlas_width_px = glyph.slot.width_px,
            .atlas_height_px = glyph.slot.height_px,
            .u0 = glyph.uv.u0,
            .v0 = glyph.uv.v0,
            .u1 = glyph.uv.u1,
            .v1 = glyph.uv.v1,
        });
    }

    return cells.toOwnedSlice(allocator);
}

fn buildNativeRasterUploads(
    allocator: std.mem.Allocator,
    frame: renderer.GlyphRasterFrame,
) ![]NativeMetalRasterUpload {
    var uploads: std.ArrayList(NativeMetalRasterUpload) = .empty;
    errdefer uploads.deinit(allocator);

    try uploads.ensureTotalCapacity(allocator, frame.uploads.len);
    for (frame.uploads) |upload| {
        uploads.appendAssumeCapacity(.{
            .slot_id = upload.slot.id,
            .atlas_x_px = upload.slot.x_px,
            .atlas_y_px = upload.slot.y_px,
            .atlas_width_px = upload.slot.width_px,
            .atlas_height_px = upload.slot.height_px,
            .bytes_offset = upload.bytes_offset,
            .byte_count = upload.byte_count,
            .bytes_per_row = upload.bytes_per_row,
            .non_clear_pixels = upload.non_clear_pixels,
        });
    }

    return uploads.toOwnedSlice(allocator);
}

fn nativeCellsHaveAtlasPlacement(cells: []const NativeMetalCell) bool {
    // 이 값은 "Metal이 glyph bitmap을 그렸다"는 뜻이 아니다. 다음 제품 text renderer에서
    // UV를 만들 수 있는 atlas placement 데이터가 Zig -> ObjC ABI까지 건너갔는지 보는
    // 중간 계약이다. 빈 배열이면 검증할 데이터가 없으므로 false로 둔다.
    if (cells.len == 0) return false;
    for (cells) |cell| {
        if (cell.slot_id == 0) return false;
        if (cell.atlas_width_px == 0 or cell.atlas_height_px == 0) return false;
    }
    return true;
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/metal.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS Metal smoke summary reports product atlas shader sampling boundary" {
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
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
    };
    var cells = [_]NativeMetalCell{.{
        .row = 0,
        .col = 0,
        .width = 1,
        .codepoint = 'M',
        .slot_id = 1,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 14,
        .atlas_height_px = 14,
        .u0 = 0.0,
        .v0 = 0.0,
        .u1 = 0.013671875,
        .v1 = 0.013671875,
    }};
    var raster_uploads = [_]NativeMetalRasterUpload{};
    var raster_pixels = [_]u8{};
    const fixture: SmokeFixture = .{
        .size = .{ .cols = 24, .rows = 6 },
        .cells = cells[0..],
        .atlas_width_px = 1024,
        .atlas_height_px = 1024,
        .raster_uploads = raster_uploads[0..],
        .raster_pixels = raster_pixels[0..],
        .stats = .{
            .consistent = true,
            .backend = .metal,
            .surface_cols = 24,
            .surface_rows = 6,
            .draw_cells = 48,
            .draw_overlays = 1,
            .glyph_count = 48,
            .glyph_quad_count = 48,
            .glyph_uv_count = 48,
            .glyph_uv_ready = true,
            .glyph_raster_upload_count = 8,
            .glyph_raster_skipped_count = 0,
            .glyph_raster_out_of_bounds_skip_count = 0,
            .glyph_raster_error_skip_count = 0,
            .glyph_raster_byte_count = 6272,
            .glyph_raster_zero_ink_count = 1,
            .glyph_raster_ready = true,
            .upload_count = 8,
            .reused_count = 40,
            .fallback_count = 0,
            .replacement_count = 0,
            .atlas_entries = 8,
        },
    };
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, fixture);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-metal-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_surface=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_grid=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "product_atlas_uploaded=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "product_atlas_sampled=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_with_product_atlas_shader_sampling_fake_raster_no_coretext_glyph_text\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=renderer_state_glyph_frame\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_slot_placement=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_quad_count=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_upload_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_skipped_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=fake_font_backend\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_cells=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_count=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_upload_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_reused_count=40\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_entries=8\n") != null);
    // glyph text smoke와 같은 공유 schema라, metal summary도 surface/overlay/fallback/
    // replacement 줄을 함께 남긴다(예전엔 metal에서 빠져 있던 키들).
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_cols=24\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_rows=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_overlays=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_fallback_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_replacement_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "window_visible=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "presented_frames=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawable_failures=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_cells=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "rendered_cells=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_samples=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_non_clear_pixels=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_texture_created=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_uploads_requested=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_uploads_uploaded=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_upload_bytes=6272\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_readback_uploads=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_readback_mismatched_bytes=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_readback_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_sampled_cells=9\n") != null);
}

test "NativeMetalCell ABI keeps atlas placement and uv fields tightly packed" {
    // NativeMetalCell은 appkit_metal_smoke.m의 MaruMetalSmokeCell과 같은 메모리 모양이어야
    // 한다. 필드를 추가할 때 이 크기가 예고 없이 바뀌면 ObjC bridge가 atlas 좌표를 다른
    // 값으로 읽어 Metal smoke가 거짓 신호를 낼 수 있다.
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(NativeMetalCell));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeMetalCell));
}

test "NativeMetalRasterUpload ABI keeps raster byte ranges visible to ObjC" {
    // NativeMetalRasterUpload은 Zig 제품 GlyphRasterFrame의 upload metadata를 ObjC bridge에
    // 넘기는 계약이다. offset/length 필드는 64-bit macOS에서 size_t와 같은 크기여야
    // native가 pixels slice의 올바른 byte range를 atlas texture에 복사할 수 있다.
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(NativeMetalRasterUpload));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(NativeMetalRasterUpload));
}

test "NativeMetalSmokeResult ABI keeps atlas diagnostics visible to Zig" {
    // native result는 Objective-C가 채우고 Zig가 summary gate로 해석한다. 크기나 정렬이
    // 예고 없이 달라지면 product_atlas_uploaded 같은 진단값을 다른 필드로 읽을 수 있다.
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(NativeMetalSmokeResult));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeMetalSmokeResult));
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
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
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
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
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
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
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
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
    };

    try std.testing.expect(!deriveSmokeStatus(no_readback).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(partial_readback).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).terminal_grid);
    try std.testing.expect(deriveSmokeStatus(all_pixels).terminal_grid);
    try std.testing.expect(deriveSmokeStatus(all_pixels).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_readback).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial_readback).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).product_atlas_sampled);
    try std.testing.expect(deriveSmokeStatus(all_pixels).product_atlas_sampled);
}

test "Metal smoke product atlas gates require upload, byte-matching readback, and shader sampling" {
    // terminal_grid는 실제 drawable readback이고, product_atlas_uploaded는 제품
    // GlyphRasterFrame bytes가 Metal atlas texture에 들어갔는지의 검증이다. 여기에
    // product_atlas_sampled를 따로 두면 upload는 성공했지만 shader가 atlas texture를
    // 쓰지 않은 회귀를 구분할 수 있다. 이 값은 단순 draw 제출 수가 아니라 drawable
    // readback 픽셀이 source atlas texel과 일치한 샘플 수로 판정한다.
    const success: NativeMetalSmokeResult = .{
        .status = 0,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 9,
        .readback_non_clear_pixels = 9,
        .readback_failures = 0,
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 9,
    };
    var no_texture = success;
    no_texture.atlas_texture_created = 0;
    var no_uploads = success;
    no_uploads.atlas_uploads_uploaded = 7;
    var mismatch = success;
    mismatch.atlas_readback_mismatched_bytes = 1;
    var readback_failed = success;
    readback_failed.atlas_readback_failures = 1;
    var no_sampling = success;
    no_sampling.atlas_sampled_cells = 0;
    var partial_sampling = success;
    partial_sampling.atlas_sampled_cells = 8;

    try std.testing.expect(deriveSmokeStatus(success).product_atlas_uploaded);
    try std.testing.expect(deriveSmokeStatus(success).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(no_texture).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_uploads).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(mismatch).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial_sampling).product_atlas_sampled);
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
    try std.testing.expect(fixture.stats.prepared());
    try std.testing.expectEqual(renderer.Backend.metal, fixture.stats.backend);
    try std.testing.expectEqualStrings("fake_font_backend", fixture.shaper);
    try std.testing.expect(fixture.stats.draw_cells >= fixture.cells.len);
    try std.testing.expect(fixture.stats.glyph_count >= fixture.cells.len);
    // frame 통계는 dirty row의 공백 glyph까지 포함하지만, visible placeholder smoke는
    // 사람이 보기 쉬운 신호를 위해 공백 cell을 native bridge로 넘기지 않는다.
    try std.testing.expect(fixture.stats.upload_count > 0);
    try std.testing.expect(fixture.stats.atlas_entries > 0);
    try std.testing.expect(fixture.stats.glyph_uv_ready);
    try std.testing.expectEqual(fixture.stats.glyph_count, fixture.stats.glyph_quad_count);
    try std.testing.expectEqual(fixture.stats.glyph_count, fixture.stats.glyph_uv_count);
    try std.testing.expect(fixture.stats.glyph_raster_ready);
    try std.testing.expectEqual(fixture.stats.upload_count, fixture.stats.glyph_raster_upload_count);
    try std.testing.expect(fixture.stats.glyph_raster_byte_count > 0);
    try std.testing.expectEqual(fixture.stats.glyph_raster_upload_count, fixture.raster_uploads.len);
    try std.testing.expectEqual(fixture.stats.glyph_raster_byte_count, fixture.raster_pixels.len);
    try std.testing.expect(fixture.atlas_width_px > 0);
    try std.testing.expect(fixture.atlas_height_px > 0);
    try std.testing.expect(fixture.raster_uploads[0].slot_id > 0);
    try std.testing.expect(fixture.raster_uploads[0].atlas_width_px > 0);
    try std.testing.expect(fixture.raster_uploads[0].atlas_height_px > 0);
    try std.testing.expect(fixture.raster_uploads[0].byte_count > 0);
    try std.testing.expectEqual(@as(usize, 0), fixture.raster_uploads[0].bytes_offset);
    try std.testing.expect(fixture.raster_uploads[0].bytes_offset + fixture.raster_uploads[0].byte_count <= fixture.raster_pixels.len);
    // 모든 glyph는 upload 아니면 reuse 둘 중 하나라, 이 합이 glyph_count와 맞아야 probe
    // 통계가 backend로 일관되게 흘러간다(slot 재사용 회귀를 통계 단계에서 잡는다).
    try std.testing.expectEqual(fixture.stats.glyph_count, fixture.stats.upload_count + fixture.stats.reused_count);
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
    try std.testing.expect(fixture.cells[0].atlas_width_px > 0);
    try std.testing.expect(fixture.cells[0].atlas_height_px > 0);
    // 같은 glyph/cache key는 같은 atlas slot 좌표를 재사용해야 한다. native bridge가
    // slot_id만 넘기고 좌표를 잃어버리면 다음 Metal text shader가 UV를 만들 수 없다.
    try std.testing.expectEqual(fixture.cells[0].atlas_x_px, fixture.cells[4].atlas_x_px);
    try std.testing.expectEqual(fixture.cells[0].atlas_y_px, fixture.cells[4].atlas_y_px);
    try std.testing.expect(nativeCellsHaveAtlasPlacement(fixture.cells));
}

test "Metal smoke atlas placement gate rejects missing slot coordinates" {
    // summary의 renderer_atlas_slot_placement는 단순히 cell_count가 있다는 뜻이 아니다.
    // 모든 native cell이 slot id와 bitmap 크기 후보를 가져야 다음 text renderer가 UV를
    // 계산할 수 있으므로, 빈/손상 fixture를 false로 닫는다.
    try std.testing.expect(!nativeCellsHaveAtlasPlacement(&[_]NativeMetalCell{}));

    const missing_slot = [_]NativeMetalCell{.{
        .row = 0,
        .col = 0,
        .width = 1,
        .codepoint = 'A',
        .slot_id = 0,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 14,
        .atlas_height_px = 14,
        .u0 = 0.0,
        .v0 = 0.0,
        .u1 = 0.013671875,
        .v1 = 0.013671875,
    }};
    try std.testing.expect(!nativeCellsHaveAtlasPlacement(&missing_slot));

    const missing_dimensions = [_]NativeMetalCell{.{
        .row = 0,
        .col = 0,
        .width = 1,
        .codepoint = 'A',
        .slot_id = 1,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 0,
        .atlas_height_px = 14,
        .u0 = 0.0,
        .v0 = 0.0,
        .u1 = 0.0,
        .v1 = 0.013671875,
    }};
    try std.testing.expect(!nativeCellsHaveAtlasPlacement(&missing_dimensions));
}
