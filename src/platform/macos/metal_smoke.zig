const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const metal_frame = renderer.metal_frame; // §8: metal_frame이 renderer로 이주 — maru.renderer barrel 경유(중립 frame DTO)
// shape/raster native bridge 시그니처는 coretext_smoke_bridge.zig가 단일 출처로 소유한다.
// CoreText smoke와 같은 선언을 공유해, 한쪽만 파라미터를 바꿔 ABI가 어긋나는 것을 막는다.
const maru_macos_coretext_shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list;
const maru_macos_coretext_smoke_rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph;

const artifact_dir = "zig-out/maru-macos-metal-smoke";
const screenshot_path = artifact_dir ++ "/metal-frame.ppm";
const default_duration_ms: u32 = 1500;
const renderer_input_draw_list = "terminal_core_draw_list";
// Metal smoke도 사람이 볼 수 있는 짧은 UI 확인이 목적이다. 환경변수 오타로
// 로컬 작업이나 CI runner가 오래 붙잡히지 않도록 window smoke와 같은 상한을 둔다.
const max_duration_ms: u32 = 600_000;

pub const NativeMetalSmokeResult = extern struct {
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
    screenshot_written: u32,
    screenshot_width: u32,
    screenshot_height: u32,
    screenshot_bytes: u32,
    screenshot_failures: u32,
    terminal_close_status: c_int = -1,
    terminal_close_requested: u32 = 0,
    terminal_close_callback_called: u32 = 0,
    terminal_close_callback_status: c_int = -1,
    terminal_window_closed: u32 = 0,
};

pub const NativeWindowCloseCallback = ?*const fn (?*anyopaque) callconv(.c) i32;

pub const NativeKeyDownMode = enum(u32) {
    none = 0,
    synthetic = 1,
    manual = 2,
};

pub const NativeKeyDownSmokeResult = extern struct {
    status: c_int,
    window_visible: u32,
    key_down_received: u32,
    codepoint: u32,
    modifier_shift: u32,
    modifier_control: u32,
    modifier_option: u32,
    modifier_command: u32,
};

// Metal DTO와 투영 helper는 순수 모듈 metal_frame이 소유한다. visible smoke와 제품 app
// host ABI가 같은 표현을 쓰도록 여기서는 re-export만 한다.
pub const NativeMetalCell = metal_frame.NativeMetalCell;
pub const NativeMetalRasterUpload = metal_frame.NativeMetalRasterUpload;

pub extern fn maru_macos_metal_smoke_run(
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
    screenshot_path_ptr: [*]const u8,
    screenshot_path_len: usize,
    result: *NativeMetalSmokeResult,
    close_callback: NativeWindowCloseCallback,
    close_callback_context: ?*anyopaque,
    keydown_result: ?*NativeKeyDownSmokeResult,
    keydown_mode: u32,
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
        .screenshot_written = 0,
        .screenshot_width = 0,
        .screenshot_height = 0,
        .screenshot_bytes = 0,
        .screenshot_failures = 0,
        .terminal_close_status = -1,
        .terminal_close_requested = 0,
        .terminal_close_callback_called = 0,
        .terminal_close_callback_status = -1,
        .terminal_window_closed = 0,
    };
    const appearance = try config.resolveAppearance(.{});
    var fixture = try buildSmokeFixture(allocator, appearance);
    defer fixture.deinit(allocator);

    try resetArtifacts(io);
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
        screenshot_path.ptr,
        screenshot_path.len,
        &native,
        null,
        null,
        null,
        @intFromEnum(NativeKeyDownMode.none),
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
        !smoke_status.product_atlas_sampled or
        !smoke_status.screenshot_artifact) return error.MacosMetalSmokeFailed;
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

pub const SmokeStatus = struct {
    visible_ui: bool,
    metal_surface: bool,
    terminal_grid: bool,
    product_atlas_uploaded: bool,
    product_atlas_sampled: bool,
    screenshot_artifact: bool,
};

pub fn deriveSmokeStatus(native: NativeMetalSmokeResult) SmokeStatus {
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
    const screenshot_artifact = native.screenshot_written != 0 and
        native.screenshot_width > 0 and
        native.screenshot_height > 0 and
        native.screenshot_bytes > 0 and
        native.screenshot_failures == 0;

    return .{
        .visible_ui = visible_ui,
        .metal_surface = metal_surface,
        .terminal_grid = visible_ui and
            metal_surface and
            readback_sampled_atlas_texels,
        .product_atlas_uploaded = product_atlas_uploaded,
        .product_atlas_sampled = product_atlas_sampled,
        .screenshot_artifact = screenshot_artifact,
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
    try writer.print("screenshot_artifact={}\n", .{smoke_status.screenshot_artifact});
    if (smoke_status.screenshot_artifact) {
        try writer.print("screenshot_path={s}\n", .{screenshot_path});
        try writer.writeAll("screenshot_format=ppm_rgb_from_bgra8_drawable_readback\n");
    }
    // glyph_text는 "실제 CoreText glyph bytes를 화면에서 샘플링했다"는 주장이다. 라벨을
    // fixture 능력만으로 단정하지 않고, 실제 atlas 샘플링 증거(product_atlas_sampled)와
    // CoreText bytes 사용 여부를 AND로 도출한다. 그래야 rasterizer가 빈 bitmap으로 퇴화하거나
    // 샘플링이 실패하면 glyph_text도 false가 된다. ui_note는 어떤 경로(CoreText vs test
    // fixture)를 탔는지 설명하는 라벨이므로 능력 플래그를 그대로 쓴다.
    const glyph_text = fixture.uses_coretext_bytes and smoke_status.product_atlas_sampled;
    try writer.print("glyph_text={}\n", .{glyph_text});
    if (fixture.uses_coretext_bytes) {
        try writer.writeAll("ui_note=appkit_window_with_coretext_drawlist_glyph_atlas_sampling\n");
    } else {
        try writer.writeAll("ui_note=appkit_window_with_product_atlas_shader_sampling_non_coretext_test_fixture\n");
    }
    try writer.print("renderer_input={s}\n", .{fixture.input});
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
    try writer.print("screenshot_written={d}\n", .{native.screenshot_written});
    try writer.print("screenshot_width={d}\n", .{native.screenshot_width});
    try writer.print("screenshot_height={d}\n", .{native.screenshot_height});
    try writer.print("screenshot_bytes={d}\n", .{native.screenshot_bytes});
    try writer.print("screenshot_failures={d}\n", .{native.screenshot_failures});
    try writer.print("terminal_close_status={d}\n", .{native.terminal_close_status});
    try writer.print("terminal_close_requested={}\n", .{native.terminal_close_requested != 0});
    try writer.print("terminal_close_callback_called={}\n", .{native.terminal_close_callback_called != 0});
    try writer.print("terminal_close_callback_status={d}\n", .{native.terminal_close_callback_status});
    try writer.print("terminal_window_closed={}\n", .{native.terminal_window_closed != 0});

    return output.toOwnedSlice();
}

pub const SmokeFixture = struct {
    size: terminal.Size,
    cells: []NativeMetalCell,
    atlas_width_px: u32,
    atlas_height_px: u32,
    raster_uploads: []NativeMetalRasterUpload,
    raster_pixels: []u8,
    // 이 fixture의 raster bytes가 실제 CoreText rasterizer에서 왔는지(true) 아니면 native
    // 런타임 없는 test fixture에서 왔는지(false)를 나타내는 "능력" 플래그다. summary의
    // glyph_text는 이 능력만으로 결정하지 않고, 실제로 atlas texel을 샘플링했는지(증거)와
    // 함께 도출한다. 그래야 라벨이 "실제 CoreText glyph를 화면에서 샘플링했다"는 주장을
    // 스스로의 증거 없이 단정하지 않는다.
    uses_coretext_bytes: bool,
    // 제품 frame 통계는 renderer가 소유한 공유 타입으로 들고, native 입력(size, cells)과
    // 진단 통계를 한 struct에 모은다. shaper/rasterizer는 어떤 font stack으로 frame을
    // 준비했는지 summary에서 바로 분리하기 위한 라벨이다.
    stats: renderer.RenderFrameStats,
    input: []const u8 = renderer_input_draw_list,
    shaper: []const u8 = coretext_shaper.CoreTextDrawListShaper.name,
    rasterizer: []const u8 = coretext_raster.CoreTextGlyphRasterizer.name,

    pub fn deinit(self: *SmokeFixture, allocator: std.mem.Allocator) void {
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
    return buildSmokeFixtureFromDrawListShaper(
        allocator,
        appearance,
        maru_macos_coretext_shape_draw_list,
        maru_macos_coretext_smoke_rasterize_glyph,
        coretext_raster.CoreTextGlyphRasterizer.name,
        true,
    );
}

fn buildSmokeFixtureFromDrawListShaper(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    shape_draw_list: coretext_shaper.ShapeDrawListFn,
    rasterize_glyph: coretext_raster.RasterizeGlyphFn,
    rasterizer_name: []const u8,
    uses_coretext_bytes: bool,
) !SmokeFixture {
    // Metal smoke의 입력은 실제 TerminalCore snapshot에서 나온 DrawList다. 이 경로가
    // probe-derived surface를 쓰면 shell text layout, cursor, dirty row, underline overlay가
    // 제품 shaper와 Metal backend 사이에서 보존되는지 증명하지 못한다.
    const draw_list = try buildTerminalDrawListFixture(allocator);
    return buildSmokeFixtureFromOwnedDrawList(
        allocator,
        appearance,
        draw_list,
        shape_draw_list,
        rasterize_glyph,
        rasterizer_name,
        uses_coretext_bytes,
        renderer_input_draw_list,
    );
}

pub fn buildSmokeFixtureFromOwnedDrawList(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    draw_list: renderer.DrawList,
    shape_draw_list: coretext_shaper.ShapeDrawListFn,
    rasterize_glyph: coretext_raster.RasterizeGlyphFn,
    rasterizer_name: []const u8,
    uses_coretext_bytes: bool,
    input: []const u8,
) !SmokeFixture {
    // visible smoke들은 서로 다른 source(고정 fixture, live PTY)를 쓰더라도 이후 Metal
    // 입력은 같은 제품 경계를 지나야 한다. 이 helper가 DrawList ownership과
    // CoreTextDrawListShaper -> RendererState -> GlyphRasterFrame 변환을 한 곳에 묶어
    // 새 smoke가 atlas/native DTO 조립을 다시 구현하지 않게 한다.
    var owned_draw_list = draw_list;
    var draw_list_owned = true;
    errdefer if (draw_list_owned) owned_draw_list.deinit(allocator);

    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = shape_draw_list,
    };
    var shaped = try shaper.shape(
        allocator,
        owned_draw_list,
        &font_registry,
    );
    defer shaped.deinit(allocator);

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
        owned_draw_list,
        shaped.runs,
        rasterizer,
    );
    draw_list_owned = false;
    defer frame.deinit(allocator);

    return buildSmokeFixtureFromRenderFrame(
        allocator,
        frame,
        state.atlas.config,
        state.atlas.entryCount(),
        uses_coretext_bytes,
        input,
        coretext_shaper.CoreTextDrawListShaper.name,
        rasterizer_name,
    );
}

pub fn buildSmokeFixtureFromRenderFrame(
    allocator: std.mem.Allocator,
    frame: renderer.RenderFrame,
    atlas_config: renderer.GlyphAtlasConfig,
    atlas_entry_count: usize,
    uses_coretext_bytes: bool,
    input: []const u8,
    shaper_name: []const u8,
    rasterizer_name: []const u8,
) !SmokeFixture {
    // Metal backend가 소비해야 할 입력은 DrawList나 TerminalCore snapshot이 아니라
    // renderer가 이미 준비한 RenderFrame이다. 이 helper는 RenderFrame의 backend-neutral
    // 결과를 native smoke ABI용 DTO로만 투영한다. frame ownership은 caller에게 남겨,
    // 실제 app loop가 FrameLoopTick을 유지한 채 같은 투영 경계를 재사용할 수 있게 한다.
    // visible smoke는 흰색 glyph coverage 픽셀을 그대로 readback 검증하므로 전경색은 흰색으로 두고,
    // 커서 overlay는 투영하지 않는다(cursor=null) — 커서 블록이 glyph-atlas readback을 바꾸지 않게.
    const native_cells = try buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, .{
        .default_fg = .{ .r = 255, .g = 255, .b = 255 },
    });
    errdefer allocator.free(native_cells);
    const native_raster_uploads = try buildNativeRasterUploads(allocator, frame.glyph_raster_frame);
    errdefer allocator.free(native_raster_uploads);
    const native_raster_pixels = try allocator.dupe(u8, frame.glyph_raster_frame.pixels);
    errdefer allocator.free(native_raster_pixels);

    return .{
        .size = frame.glyph_frame.size,
        .cells = native_cells,
        .atlas_width_px = atlas_config.atlas_width_px,
        .atlas_height_px = atlas_config.atlas_height_px,
        .raster_uploads = native_raster_uploads,
        .raster_pixels = native_raster_pixels,
        .uses_coretext_bytes = uses_coretext_bytes,
        .stats = renderer.renderFrameStats(frame, atlas_entry_count),
        .input = input,
        .shaper = shaper_name,
        .rasterizer = rasterizer_name,
    };
}

fn buildTerminalDrawListFixture(allocator: std.mem.Allocator) !renderer.DrawList {
    // 실제 shell/PTY는 아직 없지만, TerminalCore가 만드는 snapshot과 dirty/cursor/overlay
    // 계약을 그대로 거치는 fixture다. 다음 실제 입력 PR 전까지 Metal smoke가 볼 수 있는
    // 가장 제품에 가까운 text source로 둔다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    core.clearDirty();
    try core.write("Maru 한");
    return renderer.buildDrawList(allocator, core.snapshot());
}

const test_coretext_rasterizer = "test_coretext_glyph_rasterizer";

fn buildTestSmokeFixture(allocator: std.mem.Allocator) !SmokeFixture {
    // 기본 테스트는 Objective-C/CoreText runtime을 링크하지 않는다. 대신 DrawList native
    // bridge와 같은 ABI shape 결과를 fake로 만들고, Metal smoke fixture가 probe surface가
    // 아니라 TerminalCore DrawList shaper entrypoint를 타는지 고정한다.
    const appearance = try config.resolveAppearance(.{});
    return buildSmokeFixtureFromDrawListShaper(
        allocator,
        appearance,
        testShapeDrawList,
        testRasterizeGlyph,
        test_coretext_rasterizer,
        false,
    );
}

fn writeTestFontName(record: *coretext_shaper.NativeDrawGlyphRecord, name: []const u8) void {
    const len = @min(name.len, record.font_name.len - 1);
    @memcpy(record.font_name[0..len], name[0..len]);
    record.font_name[len] = 0;
}

fn emptyTestDrawGlyphRecord() coretext_shaper.NativeDrawGlyphRecord {
    return .{
        .cell_index = 0,
        .row = 0,
        .col = 0,
        .cell_width = 0,
        .codepoint = 0,
        .glyph_id = 0,
        .drawable = 0,
        .fallback = 0,
        .color_glyph_kind = 0,
        .font_name = [_]u8{0} ** coretext_probe.font_name_capacity,
    };
}

fn testShapeDrawList(
    _: [*]const u8,
    _: usize,
    _: f64,
    _: [*]const u8, // fallback CSV ptr
    _: usize, // fallback CSV len
    _: [*]const u8, // bold family ptr (F2-3)
    _: usize, // bold family len
    _: [*]const u8, // italic family ptr (F2-3)
    _: usize, // italic family len
    _: u32, // ligatures_enabled(config font.ligatures) — fake shaper는 feature를 안 쓴다
    cells_ptr: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    _: [*]const u32, // grapheme_pool ptr (fake shaper는 풀 미사용)
    _: usize, // grapheme_pool_len
    result: *coretext_shaper.NativeDrawListShapeResult,
    records_ptr: [*]coretext_shaper.NativeDrawGlyphRecord,
    record_capacity: usize,
) callconv(.c) void {
    const cells = cells_ptr[0..cell_count];
    var record_count: usize = 0;
    result.* = .{
        .status = 0,
        .primary_font_found = 1,
        .requested_font_matched = 1,
        .shaped_cell_count = 0,
        .glyph_record_count = 0,
        .glyph_record_overflow = 0,
        .missing_glyph_count = 0,
        .fallback_run_count = 0,
    };

    for (cells, 0..) |cell, index| {
        if (cell.codepoint == 0 or cell.codepoint == ' ') continue;
        if (record_count >= record_capacity) {
            result.glyph_record_overflow = 1;
            result.status = 7;
            return;
        }

        const fallback = cell.codepoint > 0x7f;
        var record = emptyTestDrawGlyphRecord();
        record.cell_index = @intCast(index);
        record.row = cell.row;
        record.col = cell.col;
        record.cell_width = cell.width;
        record.codepoint = cell.codepoint;
        record.glyph_id = cell.codepoint + 10;
        record.drawable = 1;
        record.fallback = if (fallback) 1 else 0;
        writeTestFontName(
            &record,
            if (fallback) "AppleSDGothicNeo-Regular" else "Menlo-Regular",
        );
        records_ptr[record_count] = record;
        record_count += 1;
        result.shaped_cell_count += 1;
        if (fallback) result.fallback_run_count += 1;
    }
    result.glyph_record_count = @intCast(record_count);
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

pub const buildNativeCellsFromGlyphQuads = metal_frame.buildNativeCellsFromGlyphQuads;
pub const buildNativeRasterUploads = metal_frame.buildNativeRasterUploads;
pub const nativeCellsHaveAtlasPlacement = metal_frame.nativeCellsHaveAtlasPlacement;

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/metal.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

fn resetArtifacts(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    // smoke가 실패해 새 screenshot을 쓰지 못했는데 예전 파일이 남아 있으면, 사용자가
    // stale artifact를 이번 실행 결과로 오해한다. 실행 전에 지우고, native summary의
    // screenshot_written 값만 현재 run의 단일 출처로 둔다.
    std.Io.Dir.cwd().deleteFile(io, screenshot_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
        .uses_coretext_bytes = true,
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
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_artifact=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_path=zig-out/maru-macos-metal-smoke/metal-frame.ppm\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_format=ppm_rgb_from_bgra8_drawable_readback\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_with_coretext_drawlist_glyph_atlas_sampling\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=terminal_core_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_atlas_slot_placement=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_quad_count=48\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_upload_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_skipped_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_backend=metal\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=coretext_draw_list\n") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_written=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_width=1440\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_height=840\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_bytes=3628800\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_close_status=-1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_close_requested=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_close_callback_called=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_close_callback_status=-1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "terminal_window_closed=false\n") != null);
}

test "glyph_text stays false when CoreText fixture did not sample atlas texels" {
    // glyph_text는 fixture가 CoreText bytes를 쓴다는 "능력"만으로 참이 되면 안 된다. 실제
    // atlas 샘플링 증거(product_atlas_sampled)가 없으면 거짓이어야, rasterizer가 빈 bitmap으로
    // 퇴화하거나 샘플링이 실패한 경우를 라벨이 과장하지 않는다.
    var native = std.mem.zeroes(NativeMetalSmokeResult);
    native.status = 0; // upload/sample 신호가 전부 0이라 product_atlas_sampled=false다.

    var cells = [_]NativeMetalCell{};
    var raster_uploads = [_]NativeMetalRasterUpload{};
    var raster_pixels = [_]u8{};
    const fixture: SmokeFixture = .{
        .size = .{ .cols = 12, .rows = 2 },
        .cells = cells[0..],
        .atlas_width_px = 1024,
        .atlas_height_px = 1024,
        .raster_uploads = raster_uploads[0..],
        .raster_pixels = raster_pixels[0..],
        .uses_coretext_bytes = true,
        .stats = std.mem.zeroInit(renderer.RenderFrameStats, .{ .backend = renderer.Backend.metal }),
    };

    const smoke_status = deriveSmokeStatus(native);
    const summary = try renderSummary(std.testing.allocator, 1500, smoke_status, native, fixture);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(!smoke_status.product_atlas_sampled);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=false\n") != null);
    // ui_note는 어떤 경로(CoreText vs test fixture)를 탔는지 설명하는 라벨이라, 증거가 아니라
    // fixture 능력 그대로 CoreText 경로를 적는다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "ui_note=appkit_window_with_coretext_drawlist_glyph_atlas_sampling\n") != null);
}

test "NativeMetalCell ABI keeps atlas placement and uv fields tightly packed" {
    // NativeMetalCell은 appkit_metal_smoke.m의 MaruMetalSmokeCell과 같은 메모리 모양이어야
    // 한다. 필드를 추가할 때 이 크기가 예고 없이 바뀌면 ObjC bridge가 atlas 좌표를 다른
    // 값으로 읽어 Metal smoke가 거짓 신호를 낼 수 있다. foreground·background(u32)에 이어 panel
    // 픽셀 origin_x/origin_y(u32) 추가로 64바이트가 됐다. offset도 고정해, 새 필드를 끼워 넣어 기존
    // 필드가 밀리면 크기는 같아도 잡히게 한다.
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(NativeMetalCell));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeMetalCell));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(NativeMetalCell, "foreground"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(NativeMetalCell, "background"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(NativeMetalCell, "origin_x"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(NativeMetalCell, "origin_y"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(NativeMetalCell, "codepoint"));
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
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(NativeMetalSmokeResult));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeMetalSmokeResult));
}

test "NativeKeyDownSmokeResult ABI keeps Metal terminal key payload visible to Zig" {
    // 같은 Metal terminal window가 받은 keyDown payload를 app host resolver에 넣는다.
    // 이 구조체 크기가 흔들리면 modifier나 codepoint를 잘못 읽어 PTY 입력 검증이 오염된다.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(NativeKeyDownSmokeResult));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(NativeKeyDownSmokeResult));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(NativeKeyDownMode.none));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(NativeKeyDownMode.synthetic));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(NativeKeyDownMode.manual));
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3_628_800,
        .screenshot_failures = 0,
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
    var missing_screenshot = success;
    missing_screenshot.screenshot_written = 0;
    missing_screenshot.screenshot_width = 0;
    missing_screenshot.screenshot_height = 0;
    missing_screenshot.screenshot_bytes = 0;
    var screenshot_failed = success;
    screenshot_failed.screenshot_failures = 1;

    try std.testing.expect(deriveSmokeStatus(success).product_atlas_uploaded);
    try std.testing.expect(deriveSmokeStatus(success).product_atlas_sampled);
    try std.testing.expect(deriveSmokeStatus(success).screenshot_artifact);
    try std.testing.expect(!deriveSmokeStatus(no_texture).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_uploads).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(mismatch).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(readback_failed).product_atlas_uploaded);
    try std.testing.expect(!deriveSmokeStatus(no_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial_sampling).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(missing_sample_source).product_atlas_sampled);
    try std.testing.expect(!deriveSmokeStatus(missing_screenshot).screenshot_artifact);
    try std.testing.expect(!deriveSmokeStatus(screenshot_failed).screenshot_artifact);
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

test "Metal smoke fixture comes from TerminalCore DrawList shaper" {
    // 이 테스트는 native bridge 없이도 smoke 입력이 제품 renderer frame 계약에서 왔는지
    // 증명한다. Metal 경계에 넘기는 데이터는 TerminalCore snapshot에서 만든 DrawList를
    // CoreTextDrawListShaper로 shape한 뒤 atlas slot이 준비된 GlyphFrame이어야 한다.
    var fixture = try buildTestSmokeFixture(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 12), fixture.size.cols);
    try std.testing.expectEqual(@as(u16, 2), fixture.size.rows);
    try std.testing.expect(fixture.stats.prepared());
    try std.testing.expectEqual(renderer.Backend.metal, fixture.stats.backend);
    try std.testing.expectEqualStrings(renderer_input_draw_list, fixture.input);
    try std.testing.expectEqualStrings(coretext_shaper.CoreTextDrawListShaper.name, fixture.shaper);
    try std.testing.expectEqualStrings(test_coretext_rasterizer, fixture.rasterizer);
    try std.testing.expect(!fixture.uses_coretext_bytes);
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
    try std.testing.expectEqual(@as(usize, 5), fixture.cells.len);
    try std.testing.expectEqual(@as(u32, 'M'), fixture.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[0].col);
    // cell_width가 native bridge로 보존되는지 고정한다(ASCII placeholder는 1셀 폭).
    try std.testing.expectEqual(@as(u16, 1), fixture.cells[0].width);
    try std.testing.expectEqual(@as(u32, '한'), fixture.cells[4].codepoint);
    try std.testing.expectEqual(@as(u16, 0), fixture.cells[4].row);
    try std.testing.expectEqual(@as(u16, 5), fixture.cells[4].col);
    try std.testing.expectEqual(@as(u16, 2), fixture.cells[4].width);
    try std.testing.expect(fixture.cells[0].slot_id > 0);
    try std.testing.expect(fixture.cells[0].atlas_width_px > 0);
    try std.testing.expect(fixture.cells[0].atlas_height_px > 0);
    try std.testing.expect(fixture.cells[4].slot_id > 0);
    try std.testing.expect(fixture.cells[4].atlas_width_px > 0);
    try std.testing.expect(fixture.cells[4].atlas_height_px > 0);
    try std.testing.expect(nativeCellsHaveAtlasPlacement(fixture.cells));
}

test "Metal smoke fixture can be projected from an already prepared RenderFrame" {
    // 실제 app loop는 TerminalCore나 DrawList를 Metal bridge에 직접 넘기지 말아야 한다.
    // renderer가 만든 RenderFrame만 native DTO로 투영할 수 있어야, visible UI smoke와
    // 나중의 Swift/AppKit loop가 같은 backend 입력 경계를 재사용한다.
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();

    core.clearDirty();
    try core.write("Maru");

    var state = renderer.RendererState.init(std.testing.allocator, .{});
    defer state.deinit();

    var frame = try state.buildFrame(std.testing.allocator, core.snapshot(), renderer.FakeFontBackend{});
    defer frame.deinit(std.testing.allocator);

    const atlas_entries = state.atlas.entryCount();
    var fixture = try buildSmokeFixtureFromRenderFrame(
        std.testing.allocator,
        frame,
        state.atlas.config,
        atlas_entries,
        false,
        "test_prepared_render_frame",
        "fake_font_backend",
        "fake_glyph_rasterizer",
    );
    defer fixture.deinit(std.testing.allocator);

    try std.testing.expect(fixture.stats.prepared());
    try std.testing.expectEqual(renderer.Backend.metal, fixture.stats.backend);
    try std.testing.expectEqual(frame.glyph_frame.size, fixture.size);
    try std.testing.expectEqual(state.atlas.config.atlas_width_px, fixture.atlas_width_px);
    try std.testing.expectEqual(state.atlas.config.atlas_height_px, fixture.atlas_height_px);
    try std.testing.expectEqual(atlas_entries, fixture.stats.atlas_entries);
    try std.testing.expectEqualStrings("test_prepared_render_frame", fixture.input);
    try std.testing.expectEqualStrings("fake_font_backend", fixture.shaper);
    try std.testing.expectEqualStrings("fake_glyph_rasterizer", fixture.rasterizer);
    var visible_glyph_count: usize = 0;
    for (frame.glyph_quad_frame.glyphs) |glyph| {
        if (glyph.run.codepoint != ' ') visible_glyph_count += 1;
    }
    try std.testing.expectEqual(visible_glyph_count, fixture.cells.len);
    try std.testing.expectEqual(frame.glyph_raster_frame.uploads.len, fixture.raster_uploads.len);
    try std.testing.expectEqual(frame.glyph_raster_frame.pixels.len, fixture.raster_pixels.len);
    try std.testing.expectEqual(frame.glyph_raster_frame.stats.byte_count, fixture.raster_pixels.len);
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
