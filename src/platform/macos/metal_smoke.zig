const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");

const artifact_dir = "zig-out/maru-macos-metal-smoke";
const default_duration_ms: u32 = 1500;
const renderer_probe_shaper = "coretext_shaped_records";
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
    atlas_sample_missing_cells: u32,
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

extern fn maru_macos_coretext_smoke_run(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    result: *coretext_probe.NativeCoreTextSmokeResult,
    glyph_records: [*]coretext_probe.NativeGlyphRecord,
    glyph_record_capacity: usize,
) void;

extern fn maru_macos_coretext_smoke_rasterize_glyph(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    font_postscript_name: [*]const u8,
    font_postscript_name_len: usize,
    codepoint: u32,
    glyph_id: u32,
    width_px: usize,
    height_px: usize,
    bytes_per_row: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *coretext_raster.NativeGlyphRasterResult,
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
        .atlas_sample_missing_cells = 0,
    };
    const appearance = try config.resolveAppearance(.{});
    var fixture = try buildSmokeFixture(allocator, appearance);
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
    // terminal_grid는 "cell_count를 되돌려받았다"가 아니라 "shader가 제품 atlas texel을
    // 실제 drawable에 샘플링했다"는 신호여야 한다. non-clear 픽셀 수는 여전히 유용한
    // 진단값이지만, 실제 glyph 색이 clear 색에 가까울 수 있으므로 pass/fail gate로 쓰지
    // 않는다. rendered_cells==requested도 항상 참이라(제출 셀 수) gate에 넣지 않는다.
    const visible_ui = native.window_visible != 0;
    const metal_surface = native.presented_frames > 0;
    const readback_sampled_atlas_texels = native.readback_samples > 0 and
        native.readback_failures == 0 and
        native.atlas_sample_missing_cells == 0 and
        native.atlas_sampled_cells == native.readback_samples;
    const product_atlas_uploaded = native.atlas_texture_created != 0 and
        native.atlas_uploads_requested > 0 and
        native.atlas_uploads_uploaded == native.atlas_uploads_requested and
        native.atlas_readback_uploads == native.atlas_uploads_uploaded and
        native.atlas_upload_bytes > 0 and
        native.atlas_readback_mismatched_bytes == 0 and
        native.atlas_readback_failures == 0;
    const product_atlas_sampled = product_atlas_uploaded and
        readback_sampled_atlas_texels;

    return .{
        .visible_ui = visible_ui,
        .metal_surface = metal_surface,
        .terminal_grid = visible_ui and
            metal_surface and
            readback_sampled_atlas_texels,
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
    try writer.print("glyph_text={}\n", .{fixture.glyph_text});
    if (fixture.glyph_text) {
        try writer.writeAll("ui_note=appkit_window_with_coretext_shaped_glyph_atlas_sampling_probe_surface\n");
    } else {
        try writer.writeAll("ui_note=appkit_window_with_product_atlas_shader_sampling_non_coretext_test_fixture\n");
    }
    try writer.writeAll("renderer_input=renderer_state_glyph_frame\n");
    try writer.print("renderer_atlas_slot_placement={}\n", .{nativeCellsHaveAtlasPlacement(fixture.cells)});
    // 제품 frame 통계는 renderer가 소유한 공유 직렬화기로 남긴다. glyph text smoke와 같은
    // "renderer_" schema를 쓰므로 두 artifact의 키가 어긋나지 않는다.
    try renderer.writeRenderFrameStats(writer, "renderer_", fixture.stats);
    try writer.print("renderer_shaper={s}\n", .{fixture.shaper});
    try writer.print("renderer_rasterizer={s}\n", .{fixture.rasterizer});
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
    try writer.print("atlas_sample_missing_cells={d}\n", .{native.atlas_sample_missing_cells});

    return output.toOwnedSlice();
}

const SmokeFixture = struct {
    size: terminal.Size,
    cells: []NativeMetalCell,
    atlas_width_px: u32,
    atlas_height_px: u32,
    raster_uploads: []NativeMetalRasterUpload,
    raster_pixels: []u8,
    glyph_text: bool,
    // 제품 frame 통계는 renderer가 소유한 공유 타입으로 들고, native 입력(size, cells)과
    // 진단 통계를 한 struct에 모은다. shaper/rasterizer는 어떤 font stack으로 frame을
    // 준비했는지 summary에서 바로 분리하기 위한 라벨이다.
    stats: renderer.RenderFrameStats,
    shaper: []const u8 = renderer_probe_shaper,
    rasterizer: []const u8 = coretext_raster.CoreTextGlyphRasterizer.name,

    fn deinit(self: *SmokeFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.raster_uploads);
        allocator.free(self.raster_pixels);
        self.* = undefined;
    }
};

fn buildSmokeFixture(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
) !SmokeFixture {
    var native = coretext_probe.emptyNativeResult();
    var glyph_records = [_]coretext_probe.NativeGlyphRecord{coretext_probe.emptyGlyphRecord()} ** coretext_probe.glyph_record_capacity;
    maru_macos_coretext_smoke_run(
        appearance.font.family.ptr,
        appearance.font.family.len,
        @floatCast(appearance.font.size),
        &native,
        &glyph_records,
        glyph_records.len,
    );

    if (!coretext_probe.hasCompleteShapeFields(native)) return error.MacosCoreTextShapeIncomplete;
    const record_count = @min(@as(usize, @intCast(native.glyph_record_count)), glyph_records.len);

    return buildSmokeFixtureFromCoreTextRecords(
        allocator,
        appearance,
        glyph_records[0..record_count],
        maru_macos_coretext_smoke_rasterize_glyph,
        coretext_raster.CoreTextGlyphRasterizer.name,
        true,
    );
}

fn buildSmokeFixtureFromCoreTextRecords(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    records: []const coretext_probe.NativeGlyphRecord,
    rasterize_glyph: coretext_raster.RasterizeGlyphFn,
    rasterizer_name: []const u8,
    glyph_text: bool,
) !SmokeFixture {
    // Metal smoke는 이제 fake font backend가 아니라 CoreText가 만든 glyph id/font face
    // 후보를 제품 renderer frame에 태운다. 아직 입력 surface는 실제 TerminalCore가 아닌
    // probe bounds지만, GPU가 소비하는 glyph bitmap bytes는 CoreText rasterizer 산출물이다.
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    var coretext_records: std.ArrayList(coretext_probe.CoreTextGlyphRecord) = .empty;
    defer coretext_records.deinit(allocator);
    try coretext_records.ensureTotalCapacity(allocator, records.len);
    for (records) |*record| {
        coretext_records.appendAssumeCapacity(coretext_probe.coreTextGlyphRecord(record));
    }

    const probe_surface = coretext_shaper.deriveProbeSurfaceFromCoreTextGlyphs(coretext_records.items);
    var shaped = try coretext_shaper.buildGlyphRunListFromCoreTextGlyphs(
        allocator,
        coretext_records.items,
        renderer.textConfigFromFontSize(appearance.font.size, 1),
        probe_surface,
        &font_registry,
    );
    defer shaped.deinit(allocator);

    var draw_list = try coretext_shaper.buildProbeDrawListFromCoreTextGlyphs(
        allocator,
        coretext_records.items,
        probe_surface,
    );
    var draw_list_owned = true;
    errdefer if (draw_list_owned) draw_list.deinit(allocator);

    var state = renderer.RendererState.init(allocator, .{});
    defer state.deinit();

    // rasterizer는 FontIdentityRegistry가 준비된 뒤에 만든다. undefined registry pointer를
    // 들고 있는 템플릿 객체를 만들지 않으면 native glyph_id와 font face 연결 버그를
    // 더 이른 단계에서 피할 수 있다.
    const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
        .appearance = appearance,
        .font_registry = &font_registry,
        .rasterize_glyph = rasterize_glyph,
    };
    var frame = try state.buildFrameFromGlyphRunListWithRasterizer(
        allocator,
        draw_list,
        shaped.runs,
        rasterizer,
    );
    draw_list_owned = false;
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
        .glyph_text = glyph_text,
        .stats = renderer.renderFrameStats(frame, state.atlas.entryCount()),
        .rasterizer = rasterizer_name,
    };
}

const test_coretext_rasterizer = "test_coretext_glyph_rasterizer";

fn buildTestSmokeFixture(allocator: std.mem.Allocator) !SmokeFixture {
    // 기본 테스트는 Objective-C/CoreText runtime을 링크하지 않는다. 대신 native probe와 같은
    // record shape를 만들고, rasterizer만 테스트 bridge로 바꿔 Metal smoke fixture가
    // fake font backend가 아니라 shaped-record entrypoint를 타는지 고정한다.
    const appearance = try config.resolveAppearance(.{});
    const records = [_]coretext_probe.NativeGlyphRecord{
        coretext_probe.nativeGlyphRecordForTest(.{
            .glyph_id = 10,
            .string_index = 0,
            .category = .ascii,
        }),
        coretext_probe.nativeGlyphRecordForTest(.{
            .glyph_id = 20,
            .string_index = 5,
            .category = .cjk,
            .fallback = true,
            .font_name = "AppleSDGothicNeo-Regular",
        }),
        coretext_probe.nativeGlyphRecordForTest(.{
            .glyph_id = 30,
            .string_index = 7,
            .category = .emoji,
            .fallback = true,
            .font_name = "AppleColorEmoji",
        }),
    };
    return buildSmokeFixtureFromCoreTextRecords(
        allocator,
        appearance,
        &records,
        testRasterizeGlyph,
        test_coretext_rasterizer,
        false,
    );
}

fn testRasterizeGlyph(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8,
    _: usize,
    _: u32,
    _: u32,
    width_px: usize,
    height_px: usize,
    bytes_per_row: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *coretext_raster.NativeGlyphRasterResult,
) callconv(.c) void {
    var non_clear: u32 = 0;
    for (0..height_px) |y| {
        for (0..width_px) |x| {
            const offset = y * bytes_per_row + x * 4;
            if (offset + 3 >= pixel_capacity) continue;
            pixels[offset + 0] = 0xff;
            pixels[offset + 1] = 0xff;
            pixels[offset + 2] = 0xff;
            pixels[offset + 3] = 0xff;
            if (non_clear < std.math.maxInt(u32)) non_clear += 1;
        }
    }
    result.* = .{
        .status = if (non_clear > 0) 0 else 7,
        .non_clear_pixels = non_clear,
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
        // GlyphQuadFrame은 probe surface 전체의 glyph와 UV 준비 결과를 담기 때문에 blank cell도
        // 들어올 수 있다. Metal smoke의 목적은 CoreText glyph ink가 atlas texture를 통해
        // 보이는지 확인하는 것이므로, 실제 잉크 후보가 있는 glyph만 native bridge로 넘긴다.
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
        .atlas_sample_missing_cells = 0,
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
        .glyph_text = true,
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
        .rasterizer = coretext_raster.CoreTextGlyphRasterizer.name,
    };
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, fixture);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-metal-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_surface=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_grid=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "product_atlas_uploaded=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "product_atlas_sampled=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_with_coretext_shaped_glyph_atlas_sampling_probe_surface\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=renderer_state_glyph_frame\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_slot_placement=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_quad_count=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_upload_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_skipped_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=coretext_shaped_records\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_rasterizer=coretext_glyph_rasterizer\n") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_sample_missing_cells=0\n") != null);
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
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(NativeMetalSmokeResult));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeMetalSmokeResult));
}

test "Metal smoke terminal grid requires matched atlas texel samples" {
    // 이 테스트가 없으면 native bridge가 입력 cell_count를 그대로 되돌리거나, clear 색과
    // 가까운 glyph를 non-clear heuristic으로 오판해도 terminal_grid=true/false가 흔들린다.
    // source atlas texel과 drawable readback 픽셀이 모두 일치할 때만 grid를 true로 본다.
    const no_readback: NativeMetalSmokeResult = .{
        .status = 9,
        .window_visible = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .requested_cells = 9,
        .rendered_cells = 9,
        .readback_samples = 0,
        .readback_non_clear_pixels = 0,
        .readback_failures = 0,
        .atlas_texture_created = 1,
        .atlas_uploads_requested = 8,
        .atlas_uploads_uploaded = 8,
        .atlas_upload_bytes = 6272,
        .atlas_readback_uploads = 8,
        .atlas_readback_mismatched_bytes = 0,
        .atlas_readback_failures = 0,
        .atlas_sampled_cells = 0,
        .atlas_sample_missing_cells = 0,
    };
    const partial_sampling: NativeMetalSmokeResult = .{
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
        .atlas_sampled_cells = 8,
        .atlas_sample_missing_cells = 0,
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
        .atlas_sample_missing_cells = 0,
    };
    const matched_pixels_near_clear: NativeMetalSmokeResult = .{
        .status = 0,
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
        .atlas_sample_missing_cells = 0,
    };
    var missing_sample_source = matched_pixels_near_clear;
    missing_sample_source.atlas_sample_missing_cells = 1;

    try std.testing.expect(!deriveSmokeStatus(no_readback).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(partial_sampling).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).terminal_grid);
    try std.testing.expect(!deriveSmokeStatus(missing_sample_source).terminal_grid);
    try std.testing.expect(deriveSmokeStatus(matched_pixels_near_clear).terminal_grid);
    try std.testing.expect(deriveSmokeStatus(matched_pixels_near_clear).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_readback).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(missing_sample_source).product_atlas_sampled);
    try std.testing.expect(deriveSmokeStatus(matched_pixels_near_clear).product_atlas_sampled);
}

test "Metal smoke product atlas gates require upload, byte-matching readback, and shader sampling" {
    // terminal_grid는 실제 drawable readback이고, product_atlas_uploaded는 제품
    // GlyphRasterFrame bytes가 Metal atlas texture에 들어갔는지의 검증이다. 여기에
    // product_atlas_sampled를 따로 두면 upload는 성공했지만 shader가 atlas texture를
    // 쓰지 않은 회귀를 구분할 수 있다. 이 값은 단순 draw 제출 수가 아니라 drawable
    // readback 픽셀이 source atlas texel과 일치한 샘플 수와 source sample 누락 수로 판정한다.
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
        .atlas_sample_missing_cells = 0,
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
    var missing_sample_source = success;
    missing_sample_source.atlas_sample_missing_cells = 1;
    var all_sample_sources_missing = success;
    all_sample_sources_missing.readback_samples = 0;
    all_sample_sources_missing.readback_non_clear_pixels = 0;
    all_sample_sources_missing.atlas_uploads_requested = 0;
    all_sample_sources_missing.atlas_uploads_uploaded = 0;
    all_sample_sources_missing.atlas_upload_bytes = 0;
    all_sample_sources_missing.atlas_readback_uploads = 0;
    all_sample_sources_missing.atlas_sampled_cells = 0;
    all_sample_sources_missing.atlas_sample_missing_cells = 9;

    try std.testing.expect(deriveSmokeStatus(success).product_atlas_uploaded);
    try std.testing.expect(deriveSmokeStatus(success).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(no_texture).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_uploads).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(mismatch).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(missing_sample_source).product_atlas_sampled);
    // 모든 glyph가 raster 단계에서 skip되면 upload/readback 인프라는 실패하지 않았어도
    // 제품 atlas 검증은 false여야 한다. 그래야 "GPU가 고장"이 아니라 "sample source가 없음"
    // 이라는 원인을 summary에서 분리해서 볼 수 있다.
    try std.testing.expect(!deriveSmokeStatus(all_sample_sources_missing).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(all_sample_sources_missing).product_atlas_sampled);
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
    var fixture = try buildTestSmokeFixture(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 9), fixture.size.cols);
    try std.testing.expectEqual(@as(u16, 1), fixture.size.rows);
    try std.testing.expect(fixture.stats.prepared());
    try std.testing.expectEqual(renderer.Backend.metal, fixture.stats.backend);
    try std.testing.expectEqualStrings(renderer_probe_shaper, fixture.shaper);
    try std.testing.expectEqualStrings(test_coretext_rasterizer, fixture.rasterizer);
    try std.testing.expect(!fixture.glyph_text);
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
    try std.testing.expectEqual(@as(usize, 3), fixture.cells.len);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].col);
    // cell_width가 native bridge로 보존되는지 고정한다(ASCII placeholder는 1셀 폭).
    try std.testing.expectEqual(@as(u16, 1), fixture.cells[0].width);
    try std.testing.expectEqual(@as(u32, '한'), fixture.cells[1].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[1].row);
    try std.testing.expectEqual(@as(u16, 5), fixture.cells[1].col);
    try std.testing.expectEqual(@as(u16, 2), fixture.cells[1].width);
    try std.testing.expect(fixture.cells[0].slot_id > 0);
    try std.testing.expect(fixture.cells[0].atlas_width_px > 0);
    try std.testing.expect(fixture.cells[0].atlas_height_px > 0);
    try std.testing.expect(fixture.cells[1].slot_id > 0);
    try std.testing.expect(fixture.cells[1].atlas_width_px > 0);
    try std.testing.expect(fixture.cells[1].atlas_height_px > 0);
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
