//! Deterministic Chrome Lab Metal readback smoke.
//!
//! The executable never opens a user-facing Lab tab. It lowers one synthetic scenario through the
//! same Metal renderer the app host uses, then leaves PPM/PNG/JSON artifacts for visual review.

const std = @import("std");
const maru = @import("maru");
const lab = @import("chrome/lab.zig");
const bridge = @import("chrome/lab_smoke_bridge.zig");
const chrome_draw_lowering = @import("chrome/chrome_draw_lowering.zig");
const system_text = @import("chrome/system_text.zig");
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const coretext_frame_builder = @import("coretext_frame_builder.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const metal_smoke = @import("metal_smoke.zig");

const chrome = maru.chrome;
const artifact_io = maru.app.artifact_io;
const config = maru.config;
const renderer = maru.renderer;

const artifact_dir = "zig-out/maru-macos-chrome-lab";
const viewport = chrome.ui.layout.UiSize{ .width = 480, .height = 720 };
const cell_width_px: u32 = 8;
const cell_height_px: u32 = 16;
const terminal_background = [3]u8{ 20, 20, 20 };

test "measured Chrome text adapter stays in the macOS platform boundary" {
    _ = system_text.Artifact;
}

const FontVariant = enum {
    jetbrains_mono,
    jetendard,
    fira_code,
    cascadia_code,
    hack,

    fn family(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "JetBrains Mono",
            .jetendard => "Jetendard",
            .fira_code => "Fira Code",
            .cascadia_code => "Cascadia Code",
            .hack => "Hack",
        };
    }

    fn assetPath(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "assets/fonts/JetBrainsMono/JetBrainsMono-Regular.ttf",
            .jetendard => "assets/fonts/Jetendard/Jetendard-Regular.ttf",
            .fira_code => "assets/fonts/FiraCode/FiraCode-Regular.ttf",
            .cascadia_code => "assets/fonts/CascadiaCode/CascadiaCode-Regular.ttf",
            .hack => "assets/fonts/Hack/Hack-Regular.ttf",
        };
    }

    fn slug(self: FontVariant) []const u8 {
        return switch (self) {
            .jetbrains_mono => "jetbrains-mono",
            .jetendard => "jetendard",
            .fira_code => "fira-code",
            .cascadia_code => "cascadia-code",
            .hack => "hack",
        };
    }
};

const PpmProbe = struct {
    width: u32,
    height: u32,
    non_background_pixels: u32,
};

/// The Lab has one short, reviewable font specimen in addition to product-state fixtures. These
/// counts come from CoreText's actual shaped runs, not from a source-string coverage guess, so a
/// reviewer can tell whether a Korean sample used the registered face or a fallback face.
const FontUsage = struct {
    primary_glyphs: usize,
    fallback_glyphs: usize,
    distinct_font_faces: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const scenario_id = try readScenario();
    const font_variant = try readFontVariant();
    var font_postscript_name_buf: [128]u8 = undefined;
    const font_postscript_name = try registerLabFont(font_variant, &font_postscript_name_buf);
    var scenario_name_buf: [96]u8 = undefined;
    const scenario_name = if (font_variant == .jetbrains_mono)
        artifactName(scenario_id)
    else
        try std.fmt.bufPrint(&scenario_name_buf, "{s}-{s}", .{ artifactName(scenario_id), font_variant.slug() });
    const ppm_path = try allocPathZ(allocator, "{s}/{s}.ppm", .{ artifact_dir, scenario_name });
    defer allocator.free(ppm_path);
    const png_path = try allocPathZ(allocator, "{s}/{s}.png", .{ artifact_dir, scenario_name });
    defer allocator.free(png_path);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ artifact_dir, scenario_name });
    defer allocator.free(json_path);

    try resetArtifacts(io, ppm_path, png_path, json_path);

    const tokens = labTokens();
    // sticky 시나리오는 그룹 둘 + 카드 넷이라 항목이 가장 많다(6). 여기 상한은 `bufferSizes`가
    // 보고하는 값 이상이어야 하고, 모자라면 캡처가 조용히 비는 대신 fail-close 한다.
    var entries: [24]chrome.ui.tree.RectEntry = undefined;
    var items: [24]chrome.ui.layout.Item = undefined;
    var flex_scratch: [24]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [24]chrome.ui.layout.UiRect = undefined;
    var ops: [lab.frame_op_capacity]chrome.draw.Op = undefined;
    var dock_nodes: [24]chrome.ui.tree.UiNode = undefined;
    var dock_actions: [20]chrome.components.session_dock.ids.Entry = undefined;
    // Button이 label을 자식으로 들면서 action마다 node가 둘이다(Button + label).
    var detail_nodes: [20]chrome.ui.tree.UiNode = undefined;
    var detail_actions: [3]chrome.components.archive_detail.ids.Entry = undefined;
    var text_runs: [lab.frame_run_capacity]chrome.draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    // SB1 §5.2: 사이드바 배경 strip이 상태바 위에서 끊기는지 **픽셀로** 보는 시나리오에서만 값을 싣는다.
    // 나머지 시나리오는 0이라 기존 캡처와 바이트 동일하다.
    const sidebar_width_px: u32 = if (scenario_id == .sidebar_status_strip) 180 else 0;
    const status_bar_height_px: u32 = if (scenario_id == .sidebar_status_strip) 26 else 0;

    const frame = try lab.buildFrame(.{
        .id = scenario_id,
        .viewport_px = viewport,
        .now_ns = 0,
    }, &tokens, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .ops = &ops,
        .dock_nodes = &dock_nodes,
        .dock_actions = &dock_actions,
        .detail_nodes = &detail_nodes,
        .detail_actions = &detail_actions,
        .text_runs = &text_runs,
        .text_bytes = &text_bytes,
    });
    // This is deliberately the same semantic-to-CoreText-to-Metal path that the macOS host uses
    // for SessionDock. The older Lab-only lowerer drew cards without glyph atlas data, which made
    // a gray rounded rectangle look like a completed UI capture.
    var gpu_quads: std.ArrayList(renderer.metal_frame.GpuQuad) = .empty;
    defer gpu_quads.deinit(allocator);
    chrome_draw_lowering.appendBackgroundQuads(allocator, &.{frame.draws}, &tokens, 0, 0, &gpu_quads);
    const cols: u16 = @intFromFloat(viewport.width / @as(f32, @floatFromInt(cell_width_px)));
    const rows: u16 = @intFromFloat(viewport.height / @as(f32, @floatFromInt(cell_height_px)));
    var lab_config: config.Config = .{};
    lab_config.font.family = font_variant.family();
    const appearance = try config.resolveAppearance(lab_config);
    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const builder = coretext_frame_builder.CoreTextFrameBuilder{
        .appearance = appearance,
        .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
        .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
        .cell_width_px = cell_width_px,
        .glyph_cell_width_px = cell_width_px,
        .cell_height_px = cell_height_px,
    };
    // 제품 Session Dock과 **같은** artifact를 쓴다. 예전에는 `RichTextArtifact`(셀 격자 + 오프셋, clip
    // 파라미터 없음)를 썼는데, 그러면 Lab 캡처의 텍스트가 제품과 다른 위치에 놓이고 스크롤 뷰포트로
    // 잘리지도 않아, 시각 골든이 정렬·클리핑을 검증할 수 없었다(docs/agent-session-list.md의 Lab 계약).
    var measured = try system_text.shapeOps(
        allocator,
        &renderer_state.font_registry,
        frame.draws.ops,
        &tokens,
        cell_width_px,
        // Lab fixture는 1× 논리 스케일로 고정한다(viewport·cell 크기가 그 전제로 잡혀 있다).
        1000,
    );
    defer measured.deinit(allocator);
    // 제품은 Chrome 텍스트를 **두 패스**로 그린다(app_session): 등록 SVG/PUA 아이콘은 셀 draw
    // list(`buildIconTextDrawList`)로, 나머지 라벨은 measured artifact로. `shapesTextOp`가
    // wide_icons op를 셰이핑에서 빼기 때문에, 아이콘 패스를 같이 돌리지 않으면 액션 버튼이
    // **빈 상자**가 된다(골든 `expanded-actions`가 지키는 계약이 바로 그것이다).
    const icon_draw_list = try chrome_draw_lowering.buildIconTextDrawList(
        allocator,
        frame.draws.ops,
        &tokens,
        cell_width_px,
        cell_height_px,
        cols,
        rows,
    );
    // 두 패스를 **한 atlas 세대로** 함께 배치한다. 페인마다 따로 `placeMultiPane`을 부르면, 뒤 페인이
    // 좌표를 소진해 invalidate/grow를 일으켰을 때 앞 페인의 slot이 repack된 atlas를 가리킨다 —
    // `glyph_frame.prepareMultiPaneGlyphFrame` 문서가 "페인별 독립 빌드"를 cross-pane 깨짐의 원인으로
    // 지목하는 그 baseline이다. 지금 fixture로는 소진이 안 나지만 잠복시키지 않는다.
    var text_pane = try builder.shapeFromRecords(
        allocator,
        // artifact가 이미 가진 shaped record로 만든다 — CoreText를 다시 부르지 않고, glyph run의
        // row/col이 artifact placement 인덱스(`row * 256 + col`)와 같은 도메인에 놓인다. 셀
        // DrawList로 만들면 run 좌표가 셀 격자라 placement를 못 찾는다(MeasuredGlyphPlacementMissing).
        try system_text.emptyDrawList(allocator, measured.records.len),
        measured.records,
    );
    var text_pane_owned = true;
    errdefer if (text_pane_owned) text_pane.deinit(allocator);
    var icon_pane = try builder.shapeOnly(allocator, icon_draw_list, &renderer_state.font_registry);
    var icon_pane_owned = true;
    errdefer if (icon_pane_owned) icon_pane.deinit(allocator);

    const pane_frames = try renderer_state.placeMultiPane(
        allocator,
        &.{ text_pane.shaped.runs, icon_pane.shaped.runs },
    );
    defer allocator.free(pane_frames);
    // `placeMultiPane`은 프레임 소유권을 넘긴다. `finishPane`은 성공하면 프레임을 소비하고 실패하면
    // **자기 프레임만** 정리하므로, 앞 페인이 실패하면 뒤 페인 프레임이 아무에게도 회수되지 않는다.
    var frames_consumed: usize = 0;
    errdefer for (pane_frames[frames_consumed..]) |*unconsumed| unconsumed.deinit(allocator);

    frames_consumed = 1;
    var render_frame = try builder.finishPane(allocator, &text_pane, pane_frames[0], &renderer_state);
    text_pane_owned = false;
    defer render_frame.deinit(allocator);
    frames_consumed = 2;
    var icon_frame = try builder.finishPane(allocator, &icon_pane, pane_frames[1], &renderer_state);
    icon_pane_owned = false;
    defer icon_frame.deinit(allocator);
    const font_usage = inspectFontUsage(render_frame, renderer_state.font_registry.count());

    // 아이콘은 제품과 같이 native **셀** 경로로 넘긴다(아래 bridge 호출의 cells 인자).
    var metal_fixture = try metal_smoke.buildSmokeFixtureFromRenderFrame(
        allocator,
        icon_frame,
        renderer_state.atlas.config,
        renderer_state.atlas.entryCount(),
        true,
        "chrome-session-dock",
        coretext_shaper.CoreTextDrawListShaper.name,
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
    defer metal_fixture.deinit(allocator);
    var text_fixture = try metal_smoke.buildSmokeFixtureFromRenderFrame(
        allocator,
        render_frame,
        renderer_state.atlas.config,
        renderer_state.atlas.entryCount(),
        true,
        "chrome-session-dock",
        coretext_shaper.CoreTextDrawListShaper.name,
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
    defer text_fixture.deinit(allocator);

    // 두 프레임의 atlas 업로드를 합친다. `glyph_raster_frame`은 **그 프레임에서 새로 래스터한
    // slot만** 담으므로 한쪽만 넘기면 다른 쪽 glyph가 빈 텍스처로 그려진다. 두 번째 묶음의
    // `bytes_offset`은 이어붙인 픽셀 버퍼 기준으로 다시 잡는다.
    var raster_uploads: std.ArrayList(renderer.metal_frame.NativeMetalRasterUpload) = .empty;
    defer raster_uploads.deinit(allocator);
    var raster_pixels: std.ArrayList(u8) = .empty;
    defer raster_pixels.deinit(allocator);
    try raster_pixels.appendSlice(allocator, metal_fixture.raster_pixels);
    try raster_uploads.appendSlice(allocator, metal_fixture.raster_uploads);
    const text_pixels_base = raster_pixels.items.len;
    try raster_pixels.appendSlice(allocator, text_fixture.raster_pixels);
    for (text_fixture.raster_uploads) |upload| {
        var rebased = upload;
        rebased.bytes_offset += text_pixels_base;
        try raster_uploads.append(allocator, rebased);
    }

    // B1 lowerer proof: the Lab intentionally consumes the same final-pixel artifact as the
    // product host rather than handing Chrome text back as terminal cells. Atlas uploads stay
    // shared; only the completed semantic placement changes.
    var rich_glyphs: std.ArrayList(renderer.metal_frame.GpuGlyph) = .empty;
    defer rich_glyphs.deinit(allocator);
    // 제품(app_session)과 같은 스크롤 뷰포트를 넘긴다: published tree의 `content` 사각형이다.
    // 이게 있어야 반쯤 걸친 카드의 글자가 **잘린 그대로** 캡처돼, 골든이 클리핑 계약까지 본다.
    // Lab은 dock을 프레임 원점에 그리므로 pane 오프셋 없이 그 사각형이 곧 backing 좌표다.
    const scroll_clip: ?renderer.metal_frame.ClipPx = blk: {
        const rect = chrome.components.session_dock.build.scrollTextViewport(frame.tree) orelse break :blk null;
        break :blk .{
            .x = @intFromFloat(@max(rect.x, 0)),
            .y = @intFromFloat(@max(rect.y, 0)),
            .w = @intFromFloat(@max(rect.width, 0)),
            .h = @intFromFloat(@max(rect.height, 0)),
        };
    };
    try measured.appendGpuGlyphs(
        allocator,
        render_frame,
        renderer_state.atlas.config,
        0,
        0,
        scroll_clip,
        // artifact를 이번 프레임의 스크롤 위치에서 바로 셰이핑했으므로 차이가 없다(제품은 캐시
        // 재사용 시에만 0이 아니다).
        0,
        &rich_glyphs,
    );
    // 대조는 **클리핑 전** 좌표로 한다. `appendGpuGlyphs`는 부분 가시 glyph의 x/y/크기를 잘라내고
    // 완전히 밖인 glyph는 버리므로, 캡처용 목록과 placement를 1:1로 맞출 수 없다. 여기서 지키려는
    // 계약은 "placement가 GPU 좌표로 그대로 옮겨졌는가"라 클립과 직교한다 — clip=null로 한 번 더
    // 만들어 그것만 본다(CoreText 재호출 없음).
    var unclipped_glyphs: std.ArrayList(renderer.metal_frame.GpuGlyph) = .empty;
    defer unclipped_glyphs.deinit(allocator);
    try measured.appendGpuGlyphs(allocator, render_frame, renderer_state.atlas.config, 0, 0, null, 0, &unclipped_glyphs);
    const rich_text_matches_artifact = richGlyphsMatchArtifact(measured, render_frame, unclipped_glyphs.items) and
        // 클리핑은 glyph를 늘릴 수 없다.
        rich_glyphs.items.len <= unclipped_glyphs.items.len;

    var native: bridge.NativeResult = .{
        .status = -1,
        .renderer_created = 0,
        .atlas_ready = 0,
        .draw_submitted = 0,
        .ppm_written = 0,
        .png_written = 0,
    };
    bridge.maru_macos_chrome_lab_smoke_render(
        viewport.width,
        viewport.height,
        ppm_path,
        png_path,
        // 격자는 아이콘 셀 목록의 격자다(뷰포트에서 파생). measured 프레임의 size는 placement
        // 인덱싱용 합성 격자(256열)라 캡처 기하와 무관해서 쓰지 않는다.
        cols,
        rows,
        cell_width_px,
        cell_height_px,
        if (metal_fixture.cells.len > 0) metal_fixture.cells.ptr else null,
        metal_fixture.cells.len,
        metal_fixture.atlas_width_px,
        metal_fixture.atlas_height_px,
        if (raster_uploads.items.len > 0) raster_uploads.items.ptr else null,
        raster_uploads.items.len,
        if (raster_pixels.items.len > 0) raster_pixels.items.ptr else null,
        raster_pixels.items.len,
        if (gpu_quads.items.len > 0) gpu_quads.items.ptr else null,
        gpu_quads.items.len,
        null,
        0,
        if (rich_glyphs.items.len > 0) rich_glyphs.items.ptr else null,
        rich_glyphs.items.len,
        sidebar_width_px,
        status_bar_height_px,
        &native,
    );

    // Native setup/readback can fail before either file exists. Preserve a machine-readable failure
    // summary rather than returning a generic FileNotFound before CI or a reviewer can see which
    // product-renderer boundary failed.
    const ppm_bytes = std.Io.Dir.cwd().readFileAlloc(io, ppm_path, allocator, .limited(4 * 1024 * 1024)) catch null;
    defer if (ppm_bytes) |bytes| allocator.free(bytes);
    const ppm = if (ppm_bytes) |bytes| probePpm(bytes) catch PpmProbe{ .width = 0, .height = 0, .non_background_pixels = 0 } else PpmProbe{ .width = 0, .height = 0, .non_background_pixels = 0 };
    const png_bytes = std.Io.Dir.cwd().readFileAlloc(io, png_path, allocator, .limited(4 * 1024 * 1024)) catch null;
    defer if (png_bytes) |bytes| allocator.free(bytes);
    const valid_png = if (png_bytes) |bytes| bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") else false;
    const native_ok = native.status == 0 and native.renderer_created != 0 and native.atlas_ready != 0 and
        native.draw_submitted != 0 and native.ppm_written != 0 and native.png_written != 0;
    const pixel_ok = ppm.width == viewport.width and ppm.height == viewport.height and ppm.non_background_pixels > 0;
    // "이 캡처에 텍스트가 있었나"는 **두 패스 합**이다. measured record가 라벨을, 아이콘 셀이 등록
    // SVG/PUA glyph를 대표한다 — 한쪽만 보면 아이콘만 있는 시나리오가 "텍스트 없음"으로 오인된다.
    const has_text = measured.records.len > 0 or metal_fixture.cells.len > 0;
    const text_rasterized = has_text and raster_uploads.items.len > 0;
    // The lab intentionally routes component glyphs through the product pixel-placement pass
    // (not its legacy cell list), so a green artifact proves that this ABI/Metal path received
    // text in addition to the existing atlas uploads.
    // A text-free scenario is valid (the empty fixture deliberately has no glyphs). Whenever
    // the lowered fixture has text, however, the rich pass must receive at least one glyph.
    const rich_text_rasterized = !has_text or rich_glyphs.items.len > 0;
    const success = native_ok and pixel_ok and valid_png and text_rasterized and rich_text_rasterized and rich_text_matches_artifact;
    const summary = try renderSummary(allocator, scenario_name, font_variant, font_postscript_name, ppm_path, png_path, native, ppm, valid_png, gpu_quads.items.len, metal_fixture.cells.len, text_rasterized, rich_glyphs.items.len, rich_text_rasterized, rich_text_matches_artifact, font_usage, success);
    defer allocator.free(summary);
    try artifact_io.writeText(io, json_path, summary);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(summary);
    try stdout.flush();

    if (!success) return error.MacosChromeLabSmokeFailed;
}

fn readScenario() !lab.ScenarioId {
    const raw = std.c.getenv("MARU_CHROME_LAB_SCENARIO") orelse return .retained_list;
    return scenarioFromEnvValue(std.mem.span(raw)) orelse error.InvalidChromeLabScenario;
}

fn readFontVariant() !FontVariant {
    const raw = std.c.getenv("MARU_CHROME_LAB_FONT") orelse return .jetbrains_mono;
    return fontVariantFromValue(std.mem.span(raw)) orelse error.InvalidChromeLabFont;
}

fn fontVariantFromValue(value: []const u8) ?FontVariant {
    if (std.mem.eql(u8, value, "jetbrains-mono")) return .jetbrains_mono;
    if (std.mem.eql(u8, value, "jetendard")) return .jetendard;
    if (std.mem.eql(u8, value, "fira-code")) return .fira_code;
    if (std.mem.eql(u8, value, "cascadia-code")) return .cascadia_code;
    if (std.mem.eql(u8, value, "hack")) return .hack;
    return null;
}

fn registerLabFont(variant: FontVariant, postscript_name_out: []u8) ![]const u8 {
    if (postscript_name_out.len < 2) return error.ChromeLabFontPostscriptNameBufferTooSmall;
    const status = coretext_bridge.maru_macos_coretext_lab_register_font(
        variant.assetPath().ptr,
        variant.assetPath().len,
        variant.family().ptr,
        variant.family().len,
        postscript_name_out.ptr,
        postscript_name_out.len,
    );
    if (status != 0) return error.ChromeLabFontRegistrationFailed;
    const len = std.mem.indexOfScalar(u8, postscript_name_out, 0) orelse return error.ChromeLabFontPostscriptNameMissing;
    if (len == 0) return error.ChromeLabFontPostscriptNameMissing;
    return postscript_name_out[0..len];
}

fn scenarioFromEnvValue(raw: []const u8) ?lab.ScenarioId {
    if (std.mem.eql(u8, raw, "sidebar-status-strip")) return .sidebar_status_strip;
    if (std.mem.eql(u8, raw, "empty")) return .empty;
    if (std.mem.eql(u8, raw, "loading")) return .loading;
    if (std.mem.eql(u8, raw, "retained-list")) return .retained_list;
    if (std.mem.eql(u8, raw, "font-specimen")) return .font_specimen;
    if (std.mem.eql(u8, raw, "partial-scroll")) return .partial_scroll;
    if (std.mem.eql(u8, raw, "partial-group-scroll")) return .partial_group_scroll;
    if (std.mem.eql(u8, raw, "scrollbar")) return .scrollbar;
    if (std.mem.eql(u8, raw, "sticky-at-rest")) return .sticky_at_rest;
    if (std.mem.eql(u8, raw, "sticky-pinned")) return .sticky_pinned;
    if (std.mem.eql(u8, raw, "sticky-pushed")) return .sticky_pushed;
    if (std.mem.eql(u8, raw, "detail-loading")) return .detail_loading;
    if (std.mem.eql(u8, raw, "detail-ready")) return .detail_ready;
    if (std.mem.eql(u8, raw, "detail-stale")) return .detail_stale;
    if (std.mem.eql(u8, raw, "detail-unavailable")) return .detail_unavailable;
    return null;
}

fn artifactName(id: lab.ScenarioId) []const u8 {
    return switch (id) {
        .empty => "empty",
        .loading => "loading",
        .retained_list => "retained-list",
        .font_specimen => "font-specimen",
        .partial_scroll => "partial-scroll",
        .partial_group_scroll => "partial-group-scroll",
        .scrollbar => "scrollbar",
        .sticky_at_rest => "sticky-at-rest",
        .sticky_pinned => "sticky-pinned",
        .sticky_pushed => "sticky-pushed",
        .detail_loading => "detail-loading",
        .detail_ready => "detail-ready",
        .detail_stale => "detail-stale",
        .detail_unavailable => "detail-unavailable",
        .sidebar_status_strip => "sidebar-status-strip",
    };
}

fn allocPathZ(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

fn labTokens() chrome.Tokens {
    // Lab token input is intentionally static: no config, system appearance, font fallback, or
    // user theme can turn a visual regression into an unreviewed golden update.
    return chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        // Canonical rich-dark fixture uses the resolved default brand amber. A near-black test
        // accent makes the capture claim a contrast regression in a utility icon that the real
        // default theme never asks users to interpret.
        .accent = .{ .r = 221, .g = 161, .b = 94 },
    });
}

fn resetArtifacts(io: std.Io, ppm_path: []const u8, png_path: []const u8, json_path: []const u8) !void {
    try artifact_io.ensureDir(io, artifact_dir);
    inline for (.{ ppm_path, png_path, json_path }) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn probePpm(bytes: []const u8) !PpmProbe {
    const marker = std.mem.indexOf(u8, bytes, "\n255\n") orelse return error.InvalidPpm;
    const header_end = marker + "\n255\n".len;
    var fields = std.mem.tokenizeAny(u8, bytes[0..header_end], " \n\r\t");
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPpm, "P6")) return error.InvalidPpm;
    const width = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPpm, 10) catch return error.InvalidPpm;
    const height = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPpm, 10) catch return error.InvalidPpm;
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidPpm, "255") or fields.next() != null) return error.InvalidPpm;
    const pixel_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidPpm;
    const pixel_bytes = std.math.mul(usize, pixel_count, 3) catch return error.InvalidPpm;
    if (bytes.len - header_end != pixel_bytes) return error.InvalidPpm;

    var non_background: u32 = 0;
    var offset: usize = header_end;
    while (offset < bytes.len) : (offset += 3) {
        if (!std.mem.eql(u8, bytes[offset .. offset + 3], &terminal_background)) {
            non_background +|= 1;
        }
    }
    return .{ .width = width, .height = height, .non_background_pixels = non_background };
}

fn renderSummary(
    allocator: std.mem.Allocator,
    scenario_name: []const u8,
    font_variant: FontVariant,
    font_postscript_name: []const u8,
    ppm_path: []const u8,
    png_path: []const u8,
    native: bridge.NativeResult,
    ppm: PpmProbe,
    valid_png: bool,
    quad_count: usize,
    glyph_cell_count: usize,
    text_rasterized: bool,
    rich_glyph_count: usize,
    rich_text_rasterized: bool,
    rich_text_matches_artifact: bool,
    font_usage: FontUsage,
    success: bool,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "maru.macos-chrome-lab.v1",
        \\  "scenario": "{s}",
        \\  "font": {{ "family": "{s}", "postscript_name": "{s}", "asset": "{s}", "coretext_requested_match": true }},
        \\  "viewport_backing_px": {{ "width": {d}, "height": {d} }},
        \\  "appearance": "rich-dark-fixed",
        \\  "artifacts": {{ "ppm": "{s}", "png": "{s}" }},
        \\  "product_renderer": {{ "status": {d}, "created": {}, "atlas_ready": {}, "draw_submitted": {} }},
        \\  "readback": {{ "ppm_written": {}, "png_written": {}, "valid_png": {}, "width": {d}, "height": {d}, "non_background_pixels": {d} }},
        \\  "lowered": {{ "gpu_quads": {d}, "glyph_cells": {d}, "text_rasterized": {}, "gpu_glyphs": {d}, "rich_text_rasterized": {}, "rich_text_matches_artifact": {} }},
        \\  "font_usage": {{ "primary_glyphs": {d}, "fallback_glyphs": {d}, "distinct_font_faces": {d} }},
        \\  "success": {}
        \\}}
    , .{
        scenario_name,
        font_variant.family(),
        font_postscript_name,
        font_variant.assetPath(),
        viewport.width,
        viewport.height,
        ppm_path,
        png_path,
        native.status,
        native.renderer_created != 0,
        native.atlas_ready != 0,
        native.draw_submitted != 0,
        native.ppm_written != 0,
        native.png_written != 0,
        valid_png,
        ppm.width,
        ppm.height,
        ppm.non_background_pixels,
        quad_count,
        glyph_cell_count,
        text_rasterized,
        rich_glyph_count,
        rich_text_rasterized,
        rich_text_matches_artifact,
        font_usage.primary_glyphs,
        font_usage.fallback_glyphs,
        font_usage.distinct_font_faces,
        success,
    });
}

fn inspectFontUsage(frame: renderer.RenderFrame, distinct_font_faces: usize) FontUsage {
    var primary_glyphs: usize = 0;
    var fallback_glyphs: usize = 0;
    for (frame.glyph_quad_frame.glyphs) |glyph| {
        if (glyph.run.fallback) {
            fallback_glyphs += 1;
        } else {
            primary_glyphs += 1;
        }
    }
    return .{ .primary_glyphs = primary_glyphs, .fallback_glyphs = fallback_glyphs, .distinct_font_faces = distinct_font_faces };
}

/// This guard deliberately recomputes only the documented artifact-to-GPU projection.  It does
/// not inspect the cell fixture: if a future Lab path substitutes `row * cell_height` or a
/// fixture nudge, at least one sub-cell semantic origin differs and the product smoke closes.
/// GPU에 넘긴 glyph 좌표가 artifact의 placement와 정확히 같은지 — 변환이 좌표를 왜곡하지 않았다는 증거다.
///
/// measured artifact로 옮기면서 기대식이 단순해졌다. 예전 `RichTextArtifact`는 `col * cell_width + offset`
/// 이라 셀 격자를 되짚어야 했지만, `system_text.Artifact`의 placement는 **이미 최종 픽셀**이다. 그래서
/// 이 대조는 "placement를 그대로 실었는가"만 본다.
fn richGlyphsMatchArtifact(
    artifact: system_text.Artifact,
    frame: renderer.RenderFrame,
    glyphs: []const renderer.metal_frame.GpuGlyph,
) bool {
    var found: usize = 0;
    for (frame.glyph_quad_frame.glyphs) |glyph| {
        const index = @as(usize, glyph.run.row) * 256 + glyph.run.col;
        if (index >= artifact.placements.len) return false;
        const placement = artifact.placements[index];
        if (found == glyphs.len) return false;
        if (@abs(glyphs[found].x - placement.x_px) > 0.001 or @abs(glyphs[found].y - placement.y_px) > 0.001) return false;
        found += 1;
    }
    return found == glyphs.len;
}

test "Chrome Lab scenario parser keeps one process bound to one deterministic artifact name" {
    try std.testing.expectEqual(lab.ScenarioId.empty, scenarioFromEnvValue("empty").?);
    try std.testing.expectEqual(lab.ScenarioId.loading, scenarioFromEnvValue("loading").?);
    try std.testing.expectEqual(lab.ScenarioId.retained_list, scenarioFromEnvValue("retained-list").?);
    try std.testing.expectEqual(lab.ScenarioId.font_specimen, scenarioFromEnvValue("font-specimen").?);
    try std.testing.expectEqual(lab.ScenarioId.partial_scroll, scenarioFromEnvValue("partial-scroll").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_loading, scenarioFromEnvValue("detail-loading").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_ready, scenarioFromEnvValue("detail-ready").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_stale, scenarioFromEnvValue("detail-stale").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_unavailable, scenarioFromEnvValue("detail-unavailable").?);
    try std.testing.expect(scenarioFromEnvValue("unknown") == null);
    try std.testing.expectEqualStrings("empty", artifactName(.empty));
    try std.testing.expectEqualStrings("loading", artifactName(.loading));
    try std.testing.expectEqualStrings("retained-list", artifactName(.retained_list));
    try std.testing.expectEqualStrings("font-specimen", artifactName(.font_specimen));
    try std.testing.expectEqualStrings("partial-scroll", artifactName(.partial_scroll));
    try std.testing.expectEqualStrings("detail-ready", artifactName(.detail_ready));
    try std.testing.expectEqual(FontVariant.jetendard, fontVariantFromValue("jetendard").?);
    try std.testing.expectEqual(FontVariant.cascadia_code, fontVariantFromValue("cascadia-code").?);
    try std.testing.expect(fontVariantFromValue("unknown") == null);
}

test "Chrome Lab PPM probe rejects background-only and malformed readbacks" {
    const background_only = "P6\n2 1\n255\n\x14\x14\x14\x14\x14\x14";
    const background = try probePpm(background_only);
    try std.testing.expectEqual(@as(u32, 0), background.non_background_pixels);
    const painted = "P6\n2 1\n255\n\x14\x14\x14\xff\x00\x00";
    try std.testing.expectEqual(@as(u32, 1), (try probePpm(painted)).non_background_pixels);
    try std.testing.expectError(error.InvalidPpm, probePpm("P6\n2 1\n255\n\x14"));
}

test "Chrome Lab summary records component text rasterization and artifact paths" {
    const summary = try renderSummary(std.testing.allocator, "retained-list", .jetbrains_mono, "JetBrainsMono-Regular", "artifact.ppm", "artifact.png", .{
        .status = 0,
        .renderer_created = 1,
        .atlas_ready = 1,
        .draw_submitted = 1,
        .ppm_written = 1,
        .png_written = 1,
    }, .{ .width = 320, .height = 240, .non_background_pixels = 1 }, true, 1, 2, true, 2, true, true, .{ .primary_glyphs = 1, .fallback_glyphs = 2, .distinct_font_faces = 3 }, true);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"glyph_cells\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"text_rasterized\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"gpu_glyphs\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"rich_text_rasterized\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"rich_text_matches_artifact\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"primary_glyphs\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"fallback_glyphs\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"distinct_font_faces\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"family\": \"JetBrains Mono\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"postscript_name\": \"JetBrainsMono-Regular\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"ppm\": \"artifact.ppm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"success\": true") != null);
}
