const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;

const artifact_dir = "zig-out/maru-macos-coretext-smoke";
const font_name_capacity = 128;
const glyph_record_capacity = 64;
const renderer_probe_shaper = "coretext_shaped_records";

const NativeCoreTextSmokeResult = extern struct {
    status: c_int,
    primary_font_found: u32,
    requested_font_matched: u32,
    line_created: u32,
    run_count: u32,
    glyph_count: u32,
    fallback_run_count: u32,
    ascii_glyph_present: u32,
    cjk_glyph_present: u32,
    emoji_glyph_present: u32,
    missing_glyph_count: u32,
    glyph_record_count: u32,
    glyph_record_overflow: u32,
    glyph_rasterized: u32,
    raster_width: u32,
    raster_height: u32,
    raster_non_clear_pixels: u32,
    raster_failures: u32,
    primary_font_name: [font_name_capacity]u8,
    first_fallback_font_name: [font_name_capacity]u8,
};

const NativeGlyphCategory = enum(u32) {
    ascii = 1,
    cjk = 2,
    emoji = 3,
    space = 4,
    other = 5,
};

const NativeGlyphRecord = extern struct {
    font_id: u32,
    glyph_id: u32,
    string_index: u32,
    category: u32,
    fallback: u32,
    font_name: [font_name_capacity]u8,
};

const NativeGlyphRasterResult = extern struct {
    status: c_int,
    non_clear_pixels: u32,
};

extern fn maru_macos_coretext_smoke_run(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    result: *NativeCoreTextSmokeResult,
    glyph_records: [*]NativeGlyphRecord,
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
    result: *NativeGlyphRasterResult,
) void;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const appearance = try config.resolveAppearance(.{});
    var native: NativeCoreTextSmokeResult = emptyNativeResult();
    var glyph_records = [_]NativeGlyphRecord{emptyGlyphRecord()} ** glyph_record_capacity;
    maru_macos_coretext_smoke_run(
        appearance.font.family.ptr,
        appearance.font.family.len,
        @floatCast(appearance.font.size),
        &native,
        &glyph_records,
        glyph_records.len,
    );

    const smoke_status = deriveSmokeStatus(native);
    const record_count = @min(@as(usize, @intCast(native.glyph_record_count)), glyph_records.len);
    const glyph_frame_probe = try buildGlyphFrameProbe(
        allocator,
        appearance,
        native,
        glyph_records[0..record_count],
    );
    const summary = try renderSummary(allocator, appearance, smoke_status, native, glyph_frame_probe);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!smoke_status.shaped_text or !smoke_status.glyph_rasterized) return error.MacosCoreTextSmokeFailed;
}

fn emptyNativeResult() NativeCoreTextSmokeResult {
    return .{
        .status = -1,
        .primary_font_found = 0,
        .requested_font_matched = 0,
        .line_created = 0,
        .run_count = 0,
        .glyph_count = 0,
        .fallback_run_count = 0,
        .ascii_glyph_present = 0,
        .cjk_glyph_present = 0,
        .emoji_glyph_present = 0,
        .missing_glyph_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 0,
        .glyph_rasterized = 0,
        .raster_width = 0,
        .raster_height = 0,
        .raster_non_clear_pixels = 0,
        .raster_failures = 0,
        .primary_font_name = [_]u8{0} ** font_name_capacity,
        .first_fallback_font_name = [_]u8{0} ** font_name_capacity,
    };
}

fn emptyGlyphRecord() NativeGlyphRecord {
    return .{
        .font_id = 0,
        .glyph_id = 0,
        .string_index = 0,
        .category = 0,
        .fallback = 0,
        .font_name = [_]u8{0} ** font_name_capacity,
    };
}

const SmokeStatus = struct {
    font_resolved: bool,
    shaped_text: bool,
    glyph_rasterized: bool,
    fallback_observed: bool,
};

fn deriveSmokeStatus(native: NativeCoreTextSmokeResult) SmokeStatus {
    // 이 smoke는 glyph atlas나 Metal을 검증하지 않는다. CoreText가 macOS 기본
    // monospace font를 찾고 probe 문자열을 glyph run으로 나누는지 검증한다.
    // glyph_count만 보면 .notdef도 glyph로 세기 때문에, probe의 ASCII/CJK/emoji가
    // 각각 실제 glyph id로 매핑됐는지까지 pass 조건에 넣는다.
    // 이렇게 쪼개야 나중에 화면이 비었을 때 원인이 font resolve인지 GPU draw인지
    // summary만 보고 분리할 수 있다.
    const font_resolved = native.primary_font_found != 0;
    const shaped_text = hasNativeShapeFields(native);
    const glyph_rasterized = shaped_text and
        native.status == 0 and
        native.glyph_rasterized != 0 and
        native.raster_width > 0 and
        native.raster_height > 0 and
        native.raster_non_clear_pixels > 0 and
        native.raster_failures == 0;

    return .{
        .font_resolved = font_resolved,
        .shaped_text = shaped_text,
        .glyph_rasterized = glyph_rasterized,
        .fallback_observed = native.fallback_run_count > 0,
    };
}

fn hasNativeShapeFields(native: NativeCoreTextSmokeResult) bool {
    // status 7은 한 run의 glyph 수가 native 고정 버퍼(64)를 넘어 그 run의 glyph를
    // 기록하지 못한 경우다. 이때는 아래 field만 봐서는 shape가 끝까지 됐는지 알 수
    // 없으므로(먼저 기록된 다른 run은 정상으로 보일 수 있다) overflow status를 명시적으로
    // 제외한다. status 6(raster 실패)은 shape와 무관하므로 그대로 통과시켜 shape/raster
    // 신호 분리를 유지한다.
    return native.status != 7 and
        native.primary_font_found != 0 and
        native.line_created != 0 and
        native.run_count > 0 and
        native.glyph_count > 0 and
        native.ascii_glyph_present != 0 and
        native.cjk_glyph_present != 0 and
        native.emoji_glyph_present != 0 and
        native.missing_glyph_count == 0 and
        native.glyph_record_count > 0 and
        native.glyph_record_overflow == 0;
}

fn renderSummary(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    smoke_status: SmokeStatus,
    native: NativeCoreTextSmokeResult,
    glyph_frame_probe: GlyphFrameProbe,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-coretext-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.writeAll("resolved_appearance=true\n");
    try writer.print("requested_font_family={s}\n", .{appearance.font.family});
    try writer.print("requested_font_size={d:.1}\n", .{@as(f64, @floatCast(appearance.font.size))});
    try writer.print("requested_font_size_px={d}\n", .{fontSizePxForAtlas(appearance.font.size)});
    try writer.print("font_resolved={}\n", .{smoke_status.font_resolved});
    try writer.print("requested_font_matched={d}\n", .{native.requested_font_matched});
    try writer.print("shaped_text={}\n", .{smoke_status.shaped_text});
    try writer.print("fallback_observed={}\n", .{smoke_status.fallback_observed});
    try writer.print("glyph_rasterized={}\n", .{smoke_status.glyph_rasterized});
    try writer.writeAll("ui_note=coretext_font_shape_and_cpu_raster_no_window_no_metal_no_texture\n");
    try writer.writeAll("probe=ascii_cjk_emoji\n");
    try writer.print("native_status={d}\n", .{native.status});
    try writer.print("primary_font_found={d}\n", .{native.primary_font_found});
    try writer.print("line_created={d}\n", .{native.line_created});
    try writer.print("run_count={d}\n", .{native.run_count});
    try writer.print("glyph_count={d}\n", .{native.glyph_count});
    try writer.print("fallback_run_count={d}\n", .{native.fallback_run_count});
    try writer.print("ascii_glyph_present={d}\n", .{native.ascii_glyph_present});
    try writer.print("cjk_glyph_present={d}\n", .{native.cjk_glyph_present});
    try writer.print("emoji_glyph_present={d}\n", .{native.emoji_glyph_present});
    try writer.print("missing_glyph_count={d}\n", .{native.missing_glyph_count});
    try writer.print("glyph_record_count={d}\n", .{native.glyph_record_count});
    try writer.print("glyph_record_overflow={d}\n", .{native.glyph_record_overflow});
    try writer.print("font_identity_ready={}\n", .{glyph_frame_probe.font_identity_ready});
    try writer.print("font_identity_count={d}\n", .{glyph_frame_probe.font_identity_count});
    try writer.print("raster_width={d}\n", .{native.raster_width});
    try writer.print("raster_height={d}\n", .{native.raster_height});
    try writer.print("raster_non_clear_pixels={d}\n", .{native.raster_non_clear_pixels});
    try writer.print("raster_failures={d}\n", .{native.raster_failures});
    try writer.print("atlas_keys_ready={}\n", .{glyph_frame_probe.atlas_keys_ready});
    try writer.print("atlas_drawable_glyph_count={d}\n", .{glyph_frame_probe.drawable_glyph_count});
    try writer.print("atlas_entry_count={d}\n", .{glyph_frame_probe.entry_count});
    try writer.print("atlas_upload_candidates={d}\n", .{glyph_frame_probe.upload_candidates});
    try writer.print("atlas_upload_bytes={d}\n", .{glyph_frame_probe.upload_bytes});
    try writer.print("atlas_color_glyph_count={d}\n", .{glyph_frame_probe.color_glyph_count});
    try writer.print("glyph_frame_ready={}\n", .{glyph_frame_probe.glyph_frame_ready});
    try writer.print("glyph_frame_glyph_count={d}\n", .{glyph_frame_probe.glyph_count});
    try writer.print("glyph_frame_upload_count={d}\n", .{glyph_frame_probe.upload_count});
    try writer.print("glyph_frame_reused_count={d}\n", .{glyph_frame_probe.reused_count});
    try writer.print("glyph_frame_evicted_count={d}\n", .{glyph_frame_probe.evicted_count});
    try writer.print("glyph_frame_fallback_count={d}\n", .{glyph_frame_probe.fallback_count});
    try writer.print("glyph_frame_replacement_count={d}\n", .{glyph_frame_probe.replacement_count});
    try writer.writeAll("renderer_input=coretext_shaped_glyph_run_list\n");
    try writer.print("renderer_frame_prepared={}\n", .{glyph_frame_probe.renderer_frame_prepared});
    try writer.print("renderer_frame_consistent={}\n", .{glyph_frame_probe.renderer_frame_consistent});
    try writer.print("renderer_surface_cols={d}\n", .{glyph_frame_probe.renderer_surface_cols});
    try writer.print("renderer_surface_rows={d}\n", .{glyph_frame_probe.renderer_surface_rows});
    try writer.print("renderer_glyph_uv_ready={}\n", .{glyph_frame_probe.renderer_glyph_uv_ready});
    try writer.print("renderer_glyph_raster_ready={}\n", .{glyph_frame_probe.renderer_glyph_raster_ready});
    try writer.print("renderer_rasterizer={s}\n", .{glyph_frame_probe.renderer_rasterizer});
    try writer.print("renderer_glyph_raster_upload_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_upload_count});
    try writer.print("renderer_glyph_raster_skipped_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_skipped_count});
    try writer.print("renderer_glyph_raster_error_skip_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_error_skip_count});
    try writer.print("renderer_glyph_raster_zero_ink_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_zero_ink_count});
    try writer.print("renderer_glyph_raster_non_clear_pixels={d}\n", .{glyph_frame_probe.renderer_glyph_raster_non_clear_pixels});
    try writer.print("renderer_glyph_raster_byte_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_byte_count});
    try writer.print("renderer_draw_cells={d}\n", .{glyph_frame_probe.renderer_draw_cells});
    try writer.print("renderer_draw_overlays={d}\n", .{glyph_frame_probe.renderer_draw_overlays});
    try writer.print("renderer_shaper={s}\n", .{glyph_frame_probe.renderer_shaper});
    try writer.print("primary_font_name={s}\n", .{cStringField(&native.primary_font_name)});
    try writer.print("first_fallback_font_name={s}\n", .{cStringField(&native.first_fallback_font_name)});

    return output.toOwnedSlice();
}

const GlyphFrameProbe = struct {
    font_identity_ready: bool,
    font_identity_count: usize,
    atlas_keys_ready: bool,
    glyph_frame_ready: bool,
    drawable_glyph_count: usize,
    entry_count: usize,
    upload_candidates: usize,
    upload_bytes: usize,
    color_glyph_count: usize,
    glyph_count: usize,
    upload_count: usize,
    reused_count: usize,
    evicted_count: usize,
    fallback_count: usize,
    replacement_count: usize,
    renderer_frame_prepared: bool,
    renderer_frame_consistent: bool,
    renderer_surface_cols: u16,
    renderer_surface_rows: u16,
    renderer_glyph_uv_ready: bool,
    renderer_glyph_raster_ready: bool,
    renderer_rasterizer: []const u8,
    renderer_glyph_raster_upload_count: usize,
    renderer_glyph_raster_skipped_count: usize,
    renderer_glyph_raster_error_skip_count: usize,
    renderer_glyph_raster_zero_ink_count: usize,
    renderer_glyph_raster_non_clear_pixels: usize,
    renderer_glyph_raster_byte_count: usize,
    renderer_draw_cells: usize,
    renderer_draw_overlays: usize,
    renderer_shaper: []const u8 = renderer_probe_shaper,
};

fn buildGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
) !GlyphFrameProbe {
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    return buildGlyphFrameProbeWithRasterizer(
        allocator,
        appearance,
        native,
        records,
        &font_registry,
        CoreTextSmokeGlyphRasterizer{
            .appearance = appearance,
            .font_registry = &font_registry,
        },
        "coretext_glyph_rasterizer",
    );
}

fn buildGlyphFrameProbeWithRasterizer(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
    font_registry: *renderer.FontIdentityRegistry,
    rasterizer: anytype,
    rasterizer_name: []const u8,
) !GlyphFrameProbe {
    const shape_complete = hasNativeShapeFields(native);
    if (!shape_complete) return emptyGlyphFrameProbe(rasterizer_name);

    // 이 단계는 아직 제품 CoreText bitmap을 Metal cell renderer에 연결하지 않는다. 대신
    // CoreText가 준 실제 font_id/glyph_id 후보를 Maru의 제품 renderer state 계약인
    // `ShapedGlyphRecord -> GlyphRunList -> RendererState -> RenderFrame` 경로에 태운다.
    // 그래야 다음 Metal text draw에서 "폰트는 됐는데 frame/atlas/UV/raster 준비가 안 됐다"
    // 같은 원인을 summary로 분리할 수 있다.
    var native_shaped_records: std.ArrayList(renderer.ShapedGlyphRecord) = .empty;
    defer native_shaped_records.deinit(allocator);
    try native_shaped_records.ensureTotalCapacity(allocator, records.len);
    for (records) |record| {
        native_shaped_records.appendAssumeCapacity(try shapedRecordForCoreTextProbe(record, font_registry));
    }

    const probe_surface = probeSurfaceFromShapedRecords(native_shaped_records.items);
    var shaped = try renderer.buildGlyphRunListFromShapedRecordsWithSurface(
        allocator,
        native_shaped_records.items,
        renderer.textConfigFromFontSize(appearance.font.size, 1),
        probe_surface,
    );
    defer shaped.deinit(allocator);

    var probe_draw_list = try drawListFromShapedRecords(allocator, native_shaped_records.items, shaped.runs);
    var probe_draw_list_owned = true;
    errdefer if (probe_draw_list_owned) probe_draw_list.deinit(allocator);

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    var frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
        allocator,
        probe_draw_list,
        shaped.runs,
        rasterizer,
    );
    probe_draw_list_owned = false;
    defer frame.deinit(allocator);

    // 제품 RenderFrame의 prepared/consistent/UV/raster/draw 신호는 renderer가 단일 출처로
    // 소유한다(frame_probe). 이 smoke가 같은 gate를 손으로 다시 조립하면 glyph text/metal
    // smoke와 schema가 갈라지고(예: prepared의 glyph_count>0 절 누락) GlyphFrameStats가 바뀔
    // 때 한 곳만 빠뜨린다. 그래서 같은 renderFrameStats 계약을 그대로 쓴다.
    const render_stats = renderer.renderFrameStats(frame, renderer_state.atlas.entryCount());

    const probe: GlyphFrameProbe = .{
        .font_identity_ready = font_registry.count() > 0,
        .font_identity_count = font_registry.count(),
        .atlas_keys_ready = frame.glyph_frame.stats.glyph_count > 0 and
            renderer_state.atlas.entryCount() > 0,
        .glyph_frame_ready = frame.glyph_frame.glyphs.len == frame.glyph_frame.stats.glyph_count and
            frame.glyph_frame.stats.glyph_count > 0,
        .drawable_glyph_count = frame.glyph_frame.stats.glyph_count,
        .entry_count = renderer_state.atlas.entryCount(),
        .upload_candidates = frame.glyph_frame.stats.upload_count,
        .upload_bytes = frame.glyph_frame.stats.upload_bytes,
        .color_glyph_count = shaped.color_glyph_count,
        .glyph_count = frame.glyph_frame.stats.glyph_count,
        .upload_count = frame.glyph_frame.stats.upload_count,
        .reused_count = frame.glyph_frame.stats.reused_count,
        .evicted_count = frame.glyph_frame.stats.evicted_count,
        .fallback_count = frame.glyph_frame.stats.fallback_count,
        .replacement_count = frame.glyph_frame.stats.replacement_count,
        .renderer_frame_prepared = render_stats.prepared(),
        .renderer_frame_consistent = render_stats.consistent,
        .renderer_surface_cols = render_stats.surface_cols,
        .renderer_surface_rows = render_stats.surface_rows,
        .renderer_glyph_uv_ready = render_stats.glyph_uv_ready,
        .renderer_glyph_raster_ready = render_stats.glyph_raster_ready,
        .renderer_rasterizer = rasterizer_name,
        .renderer_glyph_raster_upload_count = render_stats.glyph_raster_upload_count,
        .renderer_glyph_raster_skipped_count = render_stats.glyph_raster_skipped_count,
        .renderer_glyph_raster_error_skip_count = render_stats.glyph_raster_error_skip_count,
        .renderer_glyph_raster_zero_ink_count = render_stats.glyph_raster_zero_ink_count,
        .renderer_glyph_raster_non_clear_pixels = frame.glyph_raster_frame.stats.non_clear_pixels,
        .renderer_glyph_raster_byte_count = render_stats.glyph_raster_byte_count,
        .renderer_draw_cells = render_stats.draw_cells,
        .renderer_draw_overlays = render_stats.draw_overlays,
    };
    return probe;
}

fn buildTestGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
) !GlyphFrameProbe {
    // 단위 계약 테스트는 임의 glyph id를 쓰므로 CoreText native rasterizer에 묶이면
    // OS font implementation detail에 따라 흔들린다. 테스트에서는 fake rasterizer를
    // 명시 주입하고, 실제 native rasterizer는 `mise run macos-coretext-smoke`에서 검증한다.
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    return buildGlyphFrameProbeWithRasterizer(
        allocator,
        appearance,
        native,
        records,
        &font_registry,
        renderer.FakeGlyphRasterizer{},
        "fake_glyph_rasterizer",
    );
}

fn emptyGlyphFrameProbe(rasterizer_name: []const u8) GlyphFrameProbe {
    return .{
        .font_identity_ready = false,
        .font_identity_count = 0,
        .atlas_keys_ready = false,
        .glyph_frame_ready = false,
        .drawable_glyph_count = 0,
        .entry_count = 0,
        .upload_candidates = 0,
        .upload_bytes = 0,
        .color_glyph_count = 0,
        .glyph_count = 0,
        .upload_count = 0,
        .reused_count = 0,
        .evicted_count = 0,
        .fallback_count = 0,
        .replacement_count = 0,
        .renderer_frame_prepared = false,
        .renderer_frame_consistent = false,
        .renderer_surface_cols = 0,
        .renderer_surface_rows = 0,
        .renderer_glyph_uv_ready = false,
        .renderer_glyph_raster_ready = false,
        .renderer_rasterizer = rasterizer_name,
        .renderer_glyph_raster_upload_count = 0,
        .renderer_glyph_raster_skipped_count = 0,
        .renderer_glyph_raster_error_skip_count = 0,
        .renderer_glyph_raster_zero_ink_count = 0,
        .renderer_glyph_raster_non_clear_pixels = 0,
        .renderer_glyph_raster_byte_count = 0,
        .renderer_draw_cells = 0,
        .renderer_draw_overlays = 0,
    };
}

const CoreTextSmokeGlyphRasterizer = struct {
    appearance: config.ResolvedAppearance,
    font_registry: *const renderer.FontIdentityRegistry,

    pub fn rasterize(
        self: CoreTextSmokeGlyphRasterizer,
        request: renderer.GlyphRasterRequest,
    ) renderer.GlyphRasterError!renderer.GlyphRasterResult {
        // 이 rasterizer는 아직 제품 macOS font backend가 아니다. CoreText smoke 안에서
        // native glyph id/font id 후보가 fake byte fill 대신 실제 CoreText glyph bitmap으로
        // 바뀔 수 있는지 확인하는 얇은 bridge다. 실패는 renderer의 기존 per-glyph skip
        // 회계로 들어가게 generic RasterizerFailed로 닫는다.
        if (request.pixels.len == 0) return error.RasterizerFailed;
        const font_identity = self.font_registry.get(request.run.font_id) orelse
            return error.RasterizerFailed;

        var native: NativeGlyphRasterResult = .{
            .status = -1,
            .non_clear_pixels = 0,
        };
        maru_macos_coretext_smoke_rasterize_glyph(
            self.appearance.font.family.ptr,
            self.appearance.font.family.len,
            @floatCast(self.appearance.font.size),
            font_identity.postscript_name.ptr,
            font_identity.postscript_name.len,
            request.run.codepoint,
            request.run.glyph_id,
            request.slot.width_px,
            request.slot.height_px,
            request.bytes_per_row,
            request.pixels.ptr,
            request.pixels.len,
            &native,
        );
        // native rasterizer는 ink가 0인 drawable glyph를 status 7로 닫는다. 그래서 이 status
        // 검사가 zero-ink 실패까지 포함하므로 codepoint별(space 등) 분기를 따로 두지 않는다.
        // space 같은 non-drawable record는 glyph run 생성 단계에서 이미 걸러져 이 rasterizer에
        // 도달하지 않는다.
        if (native.status != 0) return error.RasterizerFailed;

        return .{ .non_clear_pixels = native.non_clear_pixels };
    }
};

fn probeSurfaceFromShapedRecords(records: []const renderer.ShapedGlyphRecord) renderer.ShapedGlyphSurface {
    // CoreText smoke는 아직 실제 TerminalCore DrawList가 없어서 surface를 직접 만든다.
    // 여기서는 drawable glyph만이 아니라 space 같은 non-drawable record도 포함해 bounds를
    // 계산한다. 그래야 probe DrawList에 space cell을 남기더라도 col이 surface 밖으로 새는
    // 거짓 artifact가 생기지 않는다. 제품 shaper는 이 helper가 아니라 실제 DrawList metadata를
    // `buildGlyphRunListFromShapedRecordsWithSurface`에 넘겨야 한다.
    var max_row: u16 = 0;
    var max_col: u16 = 0;
    var any_cell = false;

    for (records) |record| {
        if (record.cell_width == 0) continue;

        any_cell = true;
        const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
            std.math.maxInt(u16);
        max_row = @max(max_row, record.row);
        max_col = @max(max_col, end_col);
    }

    const rows: u16 = if (any_cell) std.math.add(u16, max_row, 1) catch
        std.math.maxInt(u16) else 1;

    return .{
        .size = .{
            .cols = @max(max_col, 1),
            .rows = rows,
        },
        .dirty = if (any_cell) .{ .start_row = 0, .end_row = rows - 1 } else null,
    };
}

fn drawListFromShapedRecords(
    allocator: std.mem.Allocator,
    records: []const renderer.ShapedGlyphRecord,
    glyphs: renderer.GlyphRunList,
) !renderer.DrawList {
    // CoreText smoke에는 실제 TerminalCore snapshot에서 온 DrawList가 없다. 하지만 제품
    // renderer state entrypoint는 성공하면 DrawList를 RenderFrame으로 이동시키는 계약이므로,
    // native shaped record와 같은 surface metadata를 가진 최소 DrawList를 만들어 그
    // ownership/consistency 경계를 검증한다. space record도 draw cell로 남겨 "shape된 입력"
    // 전체가 frame artifact에 들어왔는지 볼 수 있게 한다.
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, records.len);

    for (records) |record| {
        if (record.cell_width == 0) continue;
        try ensureRecordFitsGlyphSurface(record, glyphs.size);
        cells.appendAssumeCapacity(.{
            .row = record.row,
            .col = record.col,
            .codepoint = record.codepoint,
            .combining = record.combining,
            .width = record.cell_width,
            .style = record.style,
        });
    }

    const overlays = try allocator.dupe(renderer.DrawOverlay, glyphs.overlays);
    errdefer allocator.free(overlays);

    return .{
        .size = glyphs.size,
        .cursor = glyphs.cursor,
        .dirty = glyphs.dirty,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = overlays,
    };
}

fn ensureRecordFitsGlyphSurface(
    record: renderer.ShapedGlyphRecord,
    size: maru.terminal.Size,
) !void {
    if (size.cols == 0 or size.rows == 0) return error.CoreTextProbeRecordOutsideSurface;
    if (record.row >= size.rows or record.col >= size.cols) return error.CoreTextProbeRecordOutsideSurface;
    const end_col = std.math.add(u16, record.col, @as(u16, record.cell_width)) catch
        return error.CoreTextProbeRecordOutsideSurface;
    if (end_col > size.cols) return error.CoreTextProbeRecordOutsideSurface;
}

fn shapedRecordForCoreTextProbe(
    record: NativeGlyphRecord,
    font_registry: *renderer.FontIdentityRegistry,
) !renderer.ShapedGlyphRecord {
    const drawable = drawableCoreTextProbeRecord(record);
    const font_id: renderer.FontId = if (drawable)
        try font_registry.intern(.{ .postscript_name = cStringField(&record.font_name) })
    else
        0;

    return .{
        .row = 0,
        .col = @intCast(@min(record.string_index, std.math.maxInt(u16))),
        .cell_width = cellWidthForCoreTextProbe(record.category),
        .codepoint = codepointForProbeRecord(record),
        .font_id = font_id,
        .glyph_id = record.glyph_id,
        .fallback = record.fallback != 0,
        .color_glyph_kind = colorGlyphKindForCoreTextProbe(record.category),
        .drawable = drawable,
    };
}

fn drawableCoreTextProbeRecord(record: NativeGlyphRecord) bool {
    return record.glyph_id != 0 and record.category != @intFromEnum(NativeGlyphCategory.space);
}

fn cellWidthForCoreTextProbe(category: u32) u2 {
    if (category == @intFromEnum(NativeGlyphCategory.cjk) or
        category == @intFromEnum(NativeGlyphCategory.emoji))
    {
        return 2;
    }
    return 1;
}

fn colorGlyphKindForCoreTextProbe(category: u32) renderer.ColorGlyphKind {
    if (category == @intFromEnum(NativeGlyphCategory.emoji)) return .color;
    return .monochrome;
}

fn fontSizePxForAtlas(font_size: f32) u16 {
    return renderer.textConfigFromFontSize(font_size, 1).font_size_px;
}

fn shapedGlyphRunForTest(
    allocator: std.mem.Allocator,
    record: NativeGlyphRecord,
    font_size: f32,
) !renderer.ShapedGlyphRunList {
    // 테스트가 CoreText private helper의 세부 구현에 직접 매달리지 않도록, native probe
    // record도 제품 renderer의 neutral adapter를 거쳐 cache key까지 확인한다.
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaped = [_]renderer.ShapedGlyphRecord{try shapedRecordForCoreTextProbe(record, &font_registry)};
    return renderer.buildGlyphRunListFromShapedRecords(
        allocator,
        &shaped,
        renderer.textConfigFromFontSize(font_size, 1),
    );
}

fn codepointForProbeRecord(record: NativeGlyphRecord) u21 {
    return switch (record.category) {
        @intFromEnum(NativeGlyphCategory.ascii) => switch (record.string_index) {
            0 => 'M',
            1 => 'a',
            2 => 'r',
            3 => 'u',
            else => '?',
        },
        @intFromEnum(NativeGlyphCategory.cjk) => '한',
        @intFromEnum(NativeGlyphCategory.emoji) => 0x1f34e,
        @intFromEnum(NativeGlyphCategory.space) => ' ',
        else => '?',
    };
}

fn cStringField(bytes: *const [font_name_capacity]u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..len];
}

const NativeGlyphRecordFixture = struct {
    native_font_id: u32 = 1,
    glyph_id: u32,
    string_index: u32,
    category: NativeGlyphCategory,
    fallback: bool = false,
    font_name: []const u8 = "Menlo-Regular",
};

fn nativeGlyphRecordForTest(args: NativeGlyphRecordFixture) NativeGlyphRecord {
    var record = emptyGlyphRecord();
    record.font_id = args.native_font_id;
    record.glyph_id = args.glyph_id;
    record.string_index = args.string_index;
    record.category = @intFromEnum(args.category);
    record.fallback = if (args.fallback) 1 else 0;

    const len = @min(args.font_name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], args.font_name[0..len]);
    return record;
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/coretext.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS CoreText smoke summary reports shaping atlas and raster boundary" {
    // native CoreText를 호출하지 않는 테스트에서도 summary 계약은 고정한다.
    // 그래야 폰트 스택 실패와 artifact 포맷 변경을 서로 다른 문제로 다룰 수 있다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.requested_font_matched = 1;
    native.line_created = 1;
    native.run_count = 3;
    native.glyph_count = 8;
    native.fallback_run_count = 2;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;
    native.glyph_rasterized = 1;
    native.raster_width = 512;
    native.raster_height = 128;
    native.raster_non_clear_pixels = 42;
    native.raster_failures = 0;
    @memcpy(native.primary_font_name[0.."Menlo-Regular".len], "Menlo-Regular");
    @memcpy(native.first_fallback_font_name[0.."AppleColorEmoji".len], "AppleColorEmoji");

    const records = [_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
        nativeGlyphRecordForTest(.{
            .native_font_id = 2,
            .glyph_id = 20,
            .string_index = 5,
            .category = .cjk,
            .fallback = true,
            .font_name = "AppleSDGothicNeo-Regular",
        }),
        nativeGlyphRecordForTest(.{
            .native_font_id = 3,
            .glyph_id = 30,
            .string_index = 7,
            .category = .emoji,
            .fallback = true,
            .font_name = "AppleColorEmoji",
        }),
    };
    const appearance = try config.resolveAppearance(.{});
    const glyph_frame_probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    const summary = try renderSummary(std.testing.allocator, appearance, deriveSmokeStatus(native), native, glyph_frame_probe);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-coretext-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "resolved_appearance=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_family=JetBrains Mono\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_size=14.0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_size_px=14\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_resolved=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_matched=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "shaped_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "fallback_observed=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_rasterized=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "probe=ascii_cjk_emoji\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "run_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ascii_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "cjk_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "emoji_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "missing_glyph_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_record_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_record_overflow=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_identity_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_identity_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_width=512\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_height=128\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_non_clear_pixels=42\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_keys_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_drawable_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_entry_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_upload_candidates=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_color_glyph_count=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_reused_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_evicted_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_fallback_count=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_replacement_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=coretext_shaped_glyph_run_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_consistent=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_cols=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_rows=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_rasterizer=fake_glyph_rasterizer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_skipped_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_error_skip_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_zero_ink_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_non_clear_pixels=588\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_byte_count=2352\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_cells=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_overlays=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=coretext_shaped_records\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "primary_font_name=Menlo-Regular\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "first_fallback_font_name=AppleColorEmoji\n") != null);
}

test "CoreText smoke does not treat fallback as required for shaping" {
    // fallback 관측은 유용한 진단 신호지만, OS와 설치 폰트에 따라 run 분리가 달라질 수
    // 있다. smoke의 pass/fail은 "글자를 glyph run으로 만들 수 있는가"에 둔다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 1;
    native.glyph_count = 8;
    native.fallback_run_count = 0;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 1;
    native.glyph_record_overflow = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);
    try std.testing.expect(!status.fallback_observed);
}

test "CoreText smoke keeps shaping and rasterization failures separate" {
    // CoreText smoke는 font shaping과 glyph bitmap rasterization을 같은 native 호출에서
    // 실행하지만, 두 신호를 섞으면 디버깅이 어려워진다. 이 테스트는 "shape는 성공,
    // CPU bitmap은 실패"인 상태가 summary에서 분리되어 보이는지 고정한다.
    var native = emptyNativeResult();
    native.status = 6;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;
    native.glyph_rasterized = 0;
    native.raster_width = 512;
    native.raster_height = 128;
    native.raster_non_clear_pixels = 0;
    native.raster_failures = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);

    // raster가 실패해도(shape는 성공) GlyphFrame 준비는 raster와 독립이다.
    // 그래서 glyph_frame_ready와 atlas_keys_ready는 그대로 true여야 한다. 이렇게 분리해야
    // summary만 보고 "shape/frame 준비는 됐고 CPU raster에서 막혔다"를 집어낼 수 있다.
    const appearance = try config.resolveAppearance(.{});
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &[_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
    });
    try std.testing.expect(probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.font_identity_count);
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
    try std.testing.expect(probe.renderer_frame_prepared);
    try std.testing.expect(probe.renderer_frame_consistent);
    try std.testing.expect(probe.renderer_glyph_uv_ready);
    try std.testing.expect(probe.renderer_glyph_raster_ready);
}

test "CoreText smoke treats native glyph-buffer overflow as incomplete shaping" {
    // status 7은 한 run의 glyph 수가 native 고정 버퍼를 넘어 그 run을 기록하지 못한
    // 상태다. 먼저 기록된 다른 run만 보면 shape가 성공한 것처럼 보일 수 있으므로,
    // summary가 shape를 성공으로 잘못 보고하지 않는지 고정한다. 그래야 화면이 빈 원인을
    // "shape는 됐는데 다음 단계 실패"로 오인하지 않는다.
    var native = emptyNativeResult();
    native.status = 7;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(!status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);

    // GlyphFrame 준비도 overflow run을 정상 shape로 취급하면 안 된다.
    const appearance = try config.resolveAppearance(.{});
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &[_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
    });
    try std.testing.expect(!probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 0), probe.font_identity_count);
    try std.testing.expect(!probe.atlas_keys_ready);
    try std.testing.expect(!probe.glyph_frame_ready);
    try std.testing.expect(!probe.renderer_frame_prepared);
    try std.testing.expect(!probe.renderer_frame_consistent);
}

test "CoreText smoke rejects missing font or empty glyph output" {
    // 성공 조건이 너무 느슨하면 "CoreText를 호출했다"만으로 shaped_text=true가 된다.
    // 실제 텍스트 렌더링의 선행 조건은 font, line, run, glyph가 모두 존재하는 것이다.
    var no_font = emptyNativeResult();
    no_font.status = 1;
    try std.testing.expect(!deriveSmokeStatus(no_font).shaped_text);

    var no_glyph = emptyNativeResult();
    no_glyph.status = 0;
    no_glyph.primary_font_found = 1;
    no_glyph.line_created = 1;
    no_glyph.run_count = 1;
    no_glyph.glyph_count = 0;
    try std.testing.expect(!deriveSmokeStatus(no_glyph).shaped_text);
}

test "CoreText smoke rejects probe categories that map to missing glyphs" {
    // 리뷰에서 지적된 핵심 회귀다. glyph_count는 .notdef도 세므로 ASCII만 성공한
    // 상태를 "CJK/emoji도 shape됐다"고 부르면 안 된다.
    var missing_cjk = emptyNativeResult();
    missing_cjk.status = 0;
    missing_cjk.primary_font_found = 1;
    missing_cjk.line_created = 1;
    missing_cjk.run_count = 2;
    missing_cjk.glyph_count = 8;
    missing_cjk.ascii_glyph_present = 1;
    missing_cjk.cjk_glyph_present = 0;
    missing_cjk.emoji_glyph_present = 1;
    missing_cjk.missing_glyph_count = 1;
    missing_cjk.glyph_record_count = 2;
    try std.testing.expect(!deriveSmokeStatus(missing_cjk).shaped_text);

    var missing_emoji = missing_cjk;
    missing_emoji.cjk_glyph_present = 1;
    missing_emoji.emoji_glyph_present = 0;
    try std.testing.expect(!deriveSmokeStatus(missing_emoji).shaped_text);
}

test "CoreText smoke glyph frame probe filters spaces and requires records" {
    // CoreText는 space도 glyph run에 포함할 수 있지만, atlas가 bitmap으로 굽는 대상은
    // 실제로 그릴 glyph다. space record는 glyph upload에서 제외하되 probe DrawList에는
    // 남긴다. 그래서 renderer surface는 drawable glyph만이 아니라 space 위치까지 덮어야
    // 한다. 그렇지 않으면 col=4 space가 width=1 surface 밖에 놓이는 거짓 artifact가 된다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 1;
    native.glyph_count = 2;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.glyph_record_count = 2;

    const records = [_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
        nativeGlyphRecordForTest(.{ .glyph_id = 5, .string_index = 4, .category = .space }),
    };

    const appearance = try config.resolveAppearance(.{ .font = .{ .family = "Menlo", .size = 16.4 } });
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    try std.testing.expect(probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.font_identity_count);
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.drawable_glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.entry_count);
    try std.testing.expectEqual(@as(usize, 1), probe.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.upload_count);
    try std.testing.expect(probe.renderer_frame_prepared);
    try std.testing.expectEqual(@as(u16, 5), probe.renderer_surface_cols);
    try std.testing.expectEqual(@as(u16, 1), probe.renderer_surface_rows);
    try std.testing.expectEqualStrings("fake_glyph_rasterizer", probe.renderer_rasterizer);
    try std.testing.expectEqual(@as(usize, 1), probe.renderer_glyph_raster_upload_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_skipped_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_error_skip_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_zero_ink_count);
    try std.testing.expectEqual(@as(usize, 256), probe.renderer_glyph_raster_non_clear_pixels);
    try std.testing.expectEqual(@as(usize, 1024), probe.renderer_glyph_raster_byte_count);
    try std.testing.expectEqual(@as(usize, 2), probe.renderer_draw_cells);
    try std.testing.expectEqualStrings(renderer_probe_shaper, probe.renderer_shaper);

    native.glyph_record_overflow = 1;
    const overflow_probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    try std.testing.expect(!overflow_probe.atlas_keys_ready);
    try std.testing.expect(!overflow_probe.glyph_frame_ready);
    try std.testing.expect(!overflow_probe.renderer_frame_prepared);
}

test "CoreText smoke rounds resolved font size into atlas cache key" {
    // CoreText는 fractional size를 받을 수 있지만, 현재 Maru glyph cache key는 정수 px를
    // 쓴다. bridge smoke가 hardcoded 14로 되돌아가면 설정 변경 후 atlas miss/hit 진단이
    // 틀어지므로 resolved size가 cache key까지 들어가는지 고정한다.
    const appearance = try config.resolveAppearance(.{ .font = .{ .family = "Menlo", .size = 16.6 } });
    var shaped = try shapedGlyphRunForTest(
        std.testing.allocator,
        nativeGlyphRecordForTest(.{ .glyph_id = 42, .string_index = 0, .category = .ascii }),
        appearance.font.size,
    );
    defer shaped.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), shaped.runs.glyphs.len);
    try std.testing.expectEqual(@as(u16, 17), shaped.runs.glyphs[0].cache_key.font_size_px);
}

test "CoreText smoke uses font identity registry instead of native record ids" {
    // C bridge의 `font_id`는 smoke 내부 진단용 임시 번호일 수 있다. renderer cache key는
    // 그 숫자를 그대로 믿지 않고, native font face name을 registry에 intern한 FontId를
    // 써야 한다. 그래야 같은 glyph id가 서로 다른 fallback face에서 충돌하지 않는다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const primary = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .native_font_id = 99,
        .glyph_id = 42,
        .string_index = 0,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    }), &font_registry);
    const cjk = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .native_font_id = 99,
        .glyph_id = 42,
        .string_index = 5,
        .category = .cjk,
        .fallback = true,
        .font_name = "AppleSDGothicNeo-Regular",
    }), &font_registry);
    const primary_again = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .native_font_id = 123,
        .glyph_id = 43,
        .string_index = 1,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    }), &font_registry);

    try std.testing.expectEqual(@as(usize, 2), font_registry.count());
    try std.testing.expect(primary.font_id != cjk.font_id);
    try std.testing.expectEqual(primary.font_id, primary_again.font_id);
}

test "CoreText smoke only interns drawable font identities" {
    // font_identity_count는 rasterizer가 실제로 조회할 face 수를 뜻해야 한다. 공백처럼
    // glyph bitmap을 만들지 않는 record까지 registry에 넣으면 summary가 "그릴 font"보다
    // 큰 숫자를 보고해 wrong-glyph 디버깅 신호가 흐려진다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const primary = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .native_font_id = 99,
        .glyph_id = 42,
        .string_index = 0,
        .category = .ascii,
        .font_name = "Menlo-Regular",
    }), &font_registry);
    const space = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .native_font_id = 100,
        .glyph_id = 5,
        .string_index = 4,
        .category = .space,
        .font_name = "SpaceOnlyFallback-Regular",
    }), &font_registry);

    try std.testing.expect(primary.drawable);
    try std.testing.expect(!space.drawable);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);
    try std.testing.expectEqual(@as(usize, 1), font_registry.count());
}

test "CoreText smoke ignores empty font names on non-drawable records" {
    // native bridge가 공백 record의 font name을 못 적어도 rasterizer에는 도달하지 않는다.
    // 이 경우 Zig adapter가 EmptyPostScriptName으로 summary 생성을 중단하면 진짜 원인인
    // shape/raster 단계가 아니라 진단 경계에서 smoke가 죽는다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const space = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .glyph_id = 5,
        .string_index = 4,
        .category = .space,
        .font_name = "",
    }), &font_registry);

    try std.testing.expect(!space.drawable);
    try std.testing.expectEqual(@as(renderer.FontId, 0), space.font_id);
    try std.testing.expectEqual(@as(usize, 0), font_registry.count());
}

test "CoreText smoke rejects empty font names on drawable records" {
    // drawable glyph의 glyph_id는 font-relative 값이다. PostScript name 없이 임시 FontId를
    // 만들면 rasterizer가 어느 CTFont에 그 glyph_id를 적용해야 하는지 알 수 없으므로,
    // 이 입력은 fallback이 아니라 명시적인 계약 위반이다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    try std.testing.expectError(
        renderer.FontIdentityError.EmptyPostScriptName,
        shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
            .glyph_id = 42,
            .string_index = 0,
            .category = .ascii,
            .font_name = "",
        }), &font_registry),
    );
}

test "CoreText smoke shaped record font id resolves back to its PostScript name" {
    // 제품 smoke rasterizer는 GlyphRun.font_id로 registry를 조회해(get) PostScript name을
    // 얻은 뒤 그 이름으로 CTFont를 만들어 glyph를 그린다. 이 왕복 계약(intern이 만든 font_id가
    // 같은 registry에서 원래 face name으로 다시 나오는가)이 깨지면 glyph가 엉뚱한 face로
    // 그려진다. native CoreText 없이도 그 lookup 경계를 고정해, fake rasterizer만 도는
    // 단위 테스트에서도 registry 배선 회귀를 잡는다.
    var font_registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer font_registry.deinit();

    const record = try shapedRecordForCoreTextProbe(nativeGlyphRecordForTest(.{
        .glyph_id = 42,
        .string_index = 0,
        .category = .cjk,
        .fallback = true,
        .font_name = "AppleSDGothicNeo-Regular",
    }), &font_registry);

    const identity = font_registry.get(record.font_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("AppleSDGothicNeo-Regular", identity.postscript_name);
}

test "CoreText smoke treats requested font mismatch as a diagnostic fallback" {
    // JetBrains Mono는 기본 요청값이지만 사용자의 Mac에 없을 수 있다. 그 경우 앱을
    // 시작하지 못하게 하기보다 system monospace fallback으로 화면을 띄우고,
    // requested_font_matched=0을 남겨 설정/폰트 문제를 숨기지 않는다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.requested_font_matched = 0;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.font_resolved);
    try std.testing.expect(status.shaped_text);
}
