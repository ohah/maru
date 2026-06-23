const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const coretext_bridge = @import("coretext_smoke_bridge.zig");
// shape/raster native bridge 시그니처는 coretext_smoke_bridge.zig가 단일 출처로 소유한다.
// Metal smoke와 같은 선언을 공유해 ABI 드리프트를 한 곳에서만 관리한다.
const maru_macos_coretext_shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list;
const maru_macos_coretext_smoke_rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph;

const artifact_dir = "zig-out/maru-macos-coretext-smoke";
const renderer_probe_shaper = "coretext_shaped_records";
const NativeCoreTextSmokeResult = coretext_probe.NativeCoreTextSmokeResult;
const NativeGlyphCategory = coretext_probe.NativeGlyphCategory;
const NativeGlyphRecord = coretext_probe.NativeGlyphRecord;
const emptyNativeResult = coretext_probe.emptyNativeResult;
const emptyGlyphRecord = coretext_probe.emptyGlyphRecord;
const nativeGlyphRecordForTest = coretext_probe.nativeGlyphRecordForTest;

extern fn maru_macos_coretext_smoke_run(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    result: *NativeCoreTextSmokeResult,
    glyph_records: [*]NativeGlyphRecord,
    glyph_record_capacity: usize,
) void;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const appearance = try config.resolveAppearance(.{});
    var native: NativeCoreTextSmokeResult = emptyNativeResult();
    var glyph_records = [_]NativeGlyphRecord{emptyGlyphRecord()} ** coretext_probe.glyph_record_capacity;
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

    // 이 smoke의 가치는 실패 위치(font/shape/raster/frame)를 summary로 좁히는 것이다. probe
    // build가 throw로 빠져나가면 정작 실패한 경로의 진단 artifact가 안 남는다. 그래서 probe
    // 실패를 error로 흘리지 않고 summary에 기록한 뒤, artifact를 쓴 다음 종료 코드로 보고한다.
    var fixed_probe_error: ?anyerror = null;
    const glyph_frame_probe = buildGlyphFrameProbe(
        allocator,
        appearance,
        native,
        glyph_records[0..record_count],
    ) catch |err| blk: {
        fixed_probe_error = err;
        break :blk emptyGlyphFrameProbe(coretext_raster.CoreTextGlyphRasterizer.name);
    };

    var draw_list_probe_error: ?anyerror = null;
    const draw_list_probe = buildDrawListGlyphFrameProbe(allocator, appearance) catch |err| blk: {
        draw_list_probe_error = err;
        var empty = emptyGlyphFrameProbe(coretext_raster.CoreTextGlyphRasterizer.name);
        empty.renderer_shaper = coretext_shaper.CoreTextDrawListShaper.name;
        break :blk empty;
    };

    const summary = try renderSummary(
        allocator,
        appearance,
        smoke_status,
        native,
        glyph_frame_probe,
        draw_list_probe,
        fixed_probe_error,
        draw_list_probe_error,
    );
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    // 요약을 먼저 남긴 뒤 실패를 보고한다.
    if (fixed_probe_error) |err| return err;
    if (draw_list_probe_error) |err| return err;
    if (!smoke_status.shaped_text or !smoke_status.glyph_rasterized) return error.MacosCoreTextSmokeFailed;
    // 헤드라인인 실제 TerminalCore -> DrawList 경로도 exit gate에 포함한다. 요약에만 출력하고
    // 게이팅하지 않으면, DrawList 프레임이 조용히 unprepared여도 smoke가 통과한다.
    if (!draw_list_probe.renderer_frame_prepared or
        !draw_list_probe.renderer_glyph_raster_ready) return error.MacosCoreTextSmokeFailed;
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
    // shape 완료 판정은 CoreText smoke와 Metal smoke가 같은 probe result를 해석하므로
    // `coretext_probe.zig`를 단일 출처로 둔다. status 6(raster 실패)은 shape와 무관하므로
    // 그대로 통과시켜 shape/raster 신호 분리를 유지한다.
    return coretext_probe.hasCompleteShapeFields(native);
}

fn renderSummary(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    smoke_status: SmokeStatus,
    native: NativeCoreTextSmokeResult,
    glyph_frame_probe: GlyphFrameProbe,
    draw_list_probe: GlyphFrameProbe,
    fixed_probe_error: ?anyerror,
    draw_list_probe_error: ?anyerror,
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
    try writer.writeAll("drawlist_input=terminal_core_draw_list\n");
    try writer.print("drawlist_frame_prepared={}\n", .{draw_list_probe.renderer_frame_prepared});
    try writer.print("drawlist_frame_consistent={}\n", .{draw_list_probe.renderer_frame_consistent});
    try writer.print("drawlist_font_identity_count={d}\n", .{draw_list_probe.font_identity_count});
    try writer.print("drawlist_surface_cols={d}\n", .{draw_list_probe.renderer_surface_cols});
    try writer.print("drawlist_surface_rows={d}\n", .{draw_list_probe.renderer_surface_rows});
    try writer.print("drawlist_draw_cells={d}\n", .{draw_list_probe.renderer_draw_cells});
    try writer.print("drawlist_draw_overlays={d}\n", .{draw_list_probe.renderer_draw_overlays});
    try writer.print("drawlist_glyph_count={d}\n", .{draw_list_probe.glyph_count});
    try writer.print("drawlist_fallback_count={d}\n", .{draw_list_probe.fallback_count});
    try writer.print("drawlist_glyph_raster_ready={}\n", .{draw_list_probe.renderer_glyph_raster_ready});
    try writer.print("drawlist_glyph_raster_upload_count={d}\n", .{draw_list_probe.renderer_glyph_raster_upload_count});
    try writer.print("drawlist_glyph_raster_error_skip_count={d}\n", .{draw_list_probe.renderer_glyph_raster_error_skip_count});
    try writer.print("drawlist_renderer_shaper={s}\n", .{draw_list_probe.renderer_shaper});
    try writer.print("drawlist_renderer_rasterizer={s}\n", .{draw_list_probe.renderer_rasterizer});
    // probe build가 던진 Zig error를 summary로 남겨, native 신호가 정상이어도 제품 후보 경계
    // (shaper/raster/frame 조립)에서 실패한 경우를 artifact만 보고 분리할 수 있게 한다.
    try writer.print("fixed_probe_error={s}\n", .{if (fixed_probe_error) |err| @errorName(err) else "none"});
    try writer.print("drawlist_probe_error={s}\n", .{if (draw_list_probe_error) |err| @errorName(err) else "none"});
    try writer.print("primary_font_name={s}\n", .{coretext_probe.cStringField(&native.primary_font_name)});
    try writer.print("first_fallback_font_name={s}\n", .{coretext_probe.cStringField(&native.first_fallback_font_name)});

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
        coretext_raster.CoreTextGlyphRasterizer{
            .appearance = appearance,
            .font_registry = &font_registry,
            .rasterize_glyph = maru_macos_coretext_smoke_rasterize_glyph,
        },
        coretext_raster.CoreTextGlyphRasterizer.name,
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
        font_registry,
    );
    defer shaped.deinit(allocator);
    var probe_draw_list = try coretext_shaper.buildProbeDrawListFromCoreTextGlyphs(
        allocator,
        coretext_records.items,
        probe_surface,
    );
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

    return glyphFrameProbeFromRenderFrame(
        font_registry,
        frame,
        &renderer_state,
        shaped.color_glyph_count,
        rasterizer_name,
        renderer_probe_shaper,
    );
}

fn buildDrawListGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
) !GlyphFrameProbe {
    // 이 경로는 fixed CoreText probe 문자열이 아니라 실제 TerminalCore snapshot에서 나온
    // DrawList를 CoreText runtime shaper로 넘긴다. 아직 Metal smoke 입력으로 쓰지는 않지만,
    // 다음 PR에서 probe-derived surface를 제거하기 전에 제품 shaper 경계를 독립적으로
    // 검증하기 위한 세로 슬라이스다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    core.clearDirty();
    try core.write("Maru 한");

    var draw_list = try renderer.buildDrawList(allocator, core.snapshot());
    var draw_list_owned = true;
    errdefer if (draw_list_owned) draw_list.deinit(allocator);

    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    var shaped = try shaper.shape(allocator, draw_list, &font_registry);
    defer shaped.deinit(allocator);

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
        .appearance = appearance,
        .font_registry = &font_registry,
        .rasterize_glyph = maru_macos_coretext_smoke_rasterize_glyph,
    };
    var frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
        allocator,
        draw_list,
        shaped.runs,
        rasterizer,
    );
    draw_list_owned = false;
    defer frame.deinit(allocator);

    return glyphFrameProbeFromRenderFrame(
        &font_registry,
        frame,
        &renderer_state,
        shaped.color_glyph_count,
        coretext_raster.CoreTextGlyphRasterizer.name,
        coretext_shaper.CoreTextDrawListShaper.name,
    );
}

fn glyphFrameProbeFromRenderFrame(
    font_registry: *const renderer.FontIdentityRegistry,
    frame: renderer.RenderFrame,
    renderer_state: *const renderer.RendererState,
    color_glyph_count: usize,
    rasterizer_name: []const u8,
    shaper_name: []const u8,
) GlyphFrameProbe {
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
        .color_glyph_count = color_glyph_count,
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
        .renderer_shaper = shaper_name,
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

    const shaped = [_]coretext_probe.CoreTextGlyphRecord{coretext_probe.coreTextGlyphRecord(&record)};
    const surface = coretext_shaper.deriveProbeSurfaceFromCoreTextGlyphs(&shaped);
    return coretext_shaper.buildGlyphRunListFromCoreTextGlyphs(
        allocator,
        &shaped,
        renderer.textConfigFromFontSize(font_size, 1),
        surface,
        &font_registry,
    );
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/coretext.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test {
    // coretext_smoke는 bridge에서 extern fn만 개별 alias(maru_macos_coretext_*)해 bridge 컨테이너가
    // 분석되지 않는다 — 그러면 CellMetricsResult ABI 가드 등 bridge가 소유한 native 계약 test가 이
    // coretext 계약 묶음(test-macos-coretext-smoke)에서 조용히 누락된다(coretext_raster는 타입을 직접
    // 써서 이미 수집된다). 컨테이너를 명시 참조해 bridge의 test를 함께 끌어온다.
    _ = coretext_bridge;
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
    var draw_list_probe = glyph_frame_probe;
    draw_list_probe.renderer_shaper = coretext_shaper.CoreTextDrawListShaper.name;
    draw_list_probe.renderer_rasterizer = coretext_raster.CoreTextGlyphRasterizer.name;
    const summary = try renderSummary(
        std.testing.allocator,
        appearance,
        deriveSmokeStatus(native),
        native,
        glyph_frame_probe,
        draw_list_probe,
        null,
        null,
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-coretext-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "fixed_probe_error=none\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_probe_error=none\n") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_input=terminal_core_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_frame_consistent=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_font_identity_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_surface_cols=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_surface_rows=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_draw_cells=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_draw_overlays=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_fallback_count=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_error_skip_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_renderer_shaper=coretext_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_renderer_rasterizer=coretext_glyph_rasterizer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "primary_font_name=Menlo-Regular\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "first_fallback_font_name=AppleColorEmoji\n") != null);
}

test "CoreText draw-list shaper normalizes synthesized box glyph to codepoint cache key" {
    // 회귀 고정(#1·#2·#6): box-drawing(U+2500)은 폰트(JetBrains Mono)가 실제 글리프를 줘도(glyph!=0)
    // rasterizer가 코드포인트로 합성하므로, 네이티브 셰이퍼가 glyph_id=0으로 정규화해야 한다. 그래야
    // cache_key가 codepoint로 키잉돼 primary/fallback이 한 슬롯에 모이고(중복 슬롯 방지), 폰트 glyph_id로
    // 키잉돼 다른 글자와 겹치는 aliasing이 사라진다. 옛 `synth=(glyph==0)&&…` 조건은 폰트 보유 시 일반
    // 경로로 새서 cache_key.glyph_id가 폰트 glyph_id가 됐다 → 이 테스트가 그 회귀를 잡는다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("──"); // U+2500 BOX DRAWINGS LIGHT HORIZONTAL ×2

    var draw_list = try renderer.buildDrawList(allocator, core.snapshot());
    defer draw_list.deinit(allocator);

    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    var shaped = try shaper.shape(allocator, draw_list, &font_registry);
    defer shaped.deinit(allocator);

    var box_seen: usize = 0;
    for (shaped.runs.glyphs) |glyph| {
        if (glyph.codepoint != 0x2500) continue;
        box_seen += 1;
        // glyph_id는 폰트 보유와 무관하게 0으로 정규화(합성은 codepoint로 그림 → 폰트 glyph 무의미).
        try std.testing.expectEqual(@as(renderer.GlyphId, 0), glyph.glyph_id);
        // cache_key는 codepoint로 키잉(font_id=0 합성 전용 공간, 폰트 glyph_id와 안 겹침).
        try std.testing.expectEqual(@as(renderer.GlyphId, 0x2500), glyph.cache_key.glyph_id);
        try std.testing.expectEqual(@as(renderer.FontId, 0), glyph.cache_key.font_id);
    }
    // drawable한 box glyph가 run에 들어왔어야 한다(글리프가 필터에서 죽었다면 box_seen==0 → 보더 안 보임).
    try std.testing.expect(box_seen >= 1);
}

test "CoreText draw-list shaper composes an NFD Hangul cluster identically to its precomposed syllable (HG3a)" {
    // 회귀 고정(HG3a): macOS 파일명 NFD '한' = 초성 U+1112 + 중성 U+1161 + 종성 U+11AB가 한 셀
    // cluster로 저장된다. DrawList가 grapheme_pool에 [중성, 종성]을 싣고 셰이퍼가 base 뒤에 붙여
    // CoreText에 넘기면, CoreText가 셋을 합성해 완성형 '한'(U+D55C)과 **같은 음절 글리프**를 낸다.
    // 풀 경로가 종성을 못 넘기면 NFD는 '하'로 합성돼 glyph_id가 달라진다 — 그 회귀를 폰트 무관하게 잡는다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };

    // col 0의 drawable 글리프(font_id, glyph_id)를 뽑는 헬퍼 — NFD와 완성형을 같은 방식으로 비교.
    const Probe = struct {
        fn glyphAtCol0(a: std.mem.Allocator, sh: coretext_shaper.CoreTextDrawListShaper, bytes: []const u8) !struct { font_id: renderer.FontId, glyph_id: renderer.GlyphId } {
            var core = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 1 });
            defer core.deinit();
            core.clearDirty();
            try core.write(bytes);
            var dl = try renderer.buildDrawList(a, core.snapshot());
            defer dl.deinit(a);
            var fr = renderer.FontIdentityRegistry.init(a);
            defer fr.deinit();
            var shaped = try sh.shape(a, dl, &fr);
            defer shaped.deinit(a);
            for (shaped.runs.glyphs) |g| {
                if (g.col == 0) return .{ .font_id = g.font_id, .glyph_id = g.glyph_id };
            }
            return error.NoGlyphAtCol0;
        }
    };

    const nfd = try Probe.glyphAtCol0(allocator, shaper, "\u{1112}\u{1161}\u{11AB}"); // NFD 한
    const nfc = try Probe.glyphAtCol0(allocator, shaper, "\u{D55C}"); // 완성형 한

    // 같은 음절로 합성됐다 — 풀이 종성까지 온전히 CoreText에 전달됐다는 증거(아니면 '하'로 달라짐).
    try std.testing.expectEqual(nfc.font_id, nfd.font_id);
    try std.testing.expectEqual(nfc.glyph_id, nfd.glyph_id);
    try std.testing.expect(nfd.glyph_id != 0); // notdef가 아니라 실제 음절 글리프
}

test "CoreText draw-list shaper shapes a ZWJ emoji family into a color glyph (GB11)" {
    // 회귀 고정(GB11): mode 2027에서 👨‍👩‍👧(👨 ZWJ 👩 ZWJ 👧)가 한 셀 cluster로 저장되고, DrawList가
    // grapheme_pool로 전체 시퀀스를 CoreText에 넘기면 컬러(AppleColorEmoji) 글리프로 셰이핑된다.
    // producer가 ZWJ 가족을 안 묶었으면(셀 분리) 또는 풀이 시퀀스를 못 넘기면 col 0이 비거나 단색이 된다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("\x1b[?2027h"); // grapheme cluster mode — 가족이 한 셀로 묶인다
    try core.write("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"); // 👨‍👩‍👧

    var dl = try renderer.buildDrawList(allocator, core.snapshot());
    defer dl.deinit(allocator);
    var fr = renderer.FontIdentityRegistry.init(allocator);
    defer fr.deinit();
    var shaped = try shaper.shape(allocator, dl, &fr);
    defer shaped.deinit(allocator);

    // col 0이 컬러 글리프로 셰이핑됐다 — 풀로 전달된 ZWJ 시퀀스를 CoreText가 이모지(컬러)로 그린다.
    var saw_color_at_col0 = false;
    for (shaped.runs.glyphs) |g| {
        if (g.col == 0 and g.cache_key.color_glyph_kind == .color) saw_color_at_col0 = true;
    }
    try std.testing.expect(saw_color_at_col0);
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
