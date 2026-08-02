//! Deterministic Chrome Lab Metal readback smoke.
//!
//! The executable never opens a user-facing Lab tab. It lowers one synthetic scenario through the
//! same Metal renderer the app host uses, then leaves PPM/PNG/JSON artifacts for visual review.

const std = @import("std");
const maru = @import("maru");
const lab = @import("chrome/lab.zig");
const bridge = @import("chrome/lab_smoke_bridge.zig");
const chrome_draw_lowering = @import("chrome/chrome_draw_lowering.zig");
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

const PpmProbe = struct {
    width: u32,
    height: u32,
    non_background_pixels: u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const scenario_id = try readScenario();
    const scenario_name = artifactName(scenario_id);
    const ppm_path = try allocPathZ(allocator, "{s}/{s}.ppm", .{ artifact_dir, scenario_name });
    defer allocator.free(ppm_path);
    const png_path = try allocPathZ(allocator, "{s}/{s}.png", .{ artifact_dir, scenario_name });
    defer allocator.free(png_path);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ artifact_dir, scenario_name });
    defer allocator.free(json_path);

    try resetArtifacts(io, ppm_path, png_path, json_path);

    const tokens = labTokens();
    var entries: [16]chrome.ui.tree.RectEntry = undefined;
    var items: [16]chrome.ui.layout.Item = undefined;
    var flex_scratch: [16]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [16]chrome.ui.layout.UiRect = undefined;
    var ops: [32]chrome.draw.Op = undefined;
    var dock_nodes: [16]chrome.ui.tree.UiNode = undefined;
    var dock_actions: [12]chrome.components.session_dock.ids.Entry = undefined;
    var detail_nodes: [16]chrome.ui.tree.UiNode = undefined;
    var detail_actions: [3]chrome.components.archive_detail.ids.Entry = undefined;
    var text_runs: [32]chrome.draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
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
    const text_draw_list = try chrome_draw_lowering.buildTextDrawList(
        allocator,
        frame.draws.ops,
        &tokens,
        cell_width_px,
        cell_height_px,
        cols,
        rows,
    );
    const appearance = try config.resolveAppearance(.{});
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
    var render_frame = try builder.buildFromDrawList(allocator, text_draw_list, &renderer_state);
    defer render_frame.deinit(allocator);
    var metal_fixture = try metal_smoke.buildSmokeFixtureFromRenderFrame(
        allocator,
        render_frame,
        renderer_state.atlas.config,
        renderer_state.atlas.entryCount(),
        true,
        "chrome-session-dock",
        coretext_shaper.CoreTextDrawListShaper.name,
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
    defer metal_fixture.deinit(allocator);

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
        metal_fixture.size.cols,
        metal_fixture.size.rows,
        cell_width_px,
        cell_height_px,
        if (metal_fixture.cells.len > 0) metal_fixture.cells.ptr else null,
        metal_fixture.cells.len,
        metal_fixture.atlas_width_px,
        metal_fixture.atlas_height_px,
        if (metal_fixture.raster_uploads.len > 0) metal_fixture.raster_uploads.ptr else null,
        metal_fixture.raster_uploads.len,
        if (metal_fixture.raster_pixels.len > 0) metal_fixture.raster_pixels.ptr else null,
        metal_fixture.raster_pixels.len,
        if (gpu_quads.items.len > 0) gpu_quads.items.ptr else null,
        gpu_quads.items.len,
        null,
        0,
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
    const text_rasterized = metal_fixture.cells.len > 0 and metal_fixture.raster_uploads.len > 0;
    const success = native_ok and pixel_ok and valid_png and text_rasterized;
    const summary = try renderSummary(allocator, scenario_name, ppm_path, png_path, native, ppm, valid_png, gpu_quads.items.len, metal_fixture.cells.len, text_rasterized, success);
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

fn scenarioFromEnvValue(raw: []const u8) ?lab.ScenarioId {
    if (std.mem.eql(u8, raw, "empty")) return .empty;
    if (std.mem.eql(u8, raw, "loading")) return .loading;
    if (std.mem.eql(u8, raw, "retained-list")) return .retained_list;
    if (std.mem.eql(u8, raw, "partial-scroll")) return .partial_scroll;
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
        .partial_scroll => "partial-scroll",
        .detail_loading => "detail-loading",
        .detail_ready => "detail-ready",
        .detail_stale => "detail-stale",
        .detail_unavailable => "detail-unavailable",
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
        .accent = .{ .r = 13, .g = 14, .b = 15 },
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
    ppm_path: []const u8,
    png_path: []const u8,
    native: bridge.NativeResult,
    ppm: PpmProbe,
    valid_png: bool,
    quad_count: usize,
    glyph_cell_count: usize,
    text_rasterized: bool,
    success: bool,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "maru.macos-chrome-lab.v1",
        \\  "scenario": "{s}",
        \\  "viewport_backing_px": {{ "width": {d}, "height": {d} }},
        \\  "appearance": "rich-dark-fixed",
        \\  "artifacts": {{ "ppm": "{s}", "png": "{s}" }},
        \\  "product_renderer": {{ "status": {d}, "created": {}, "atlas_ready": {}, "draw_submitted": {} }},
        \\  "readback": {{ "ppm_written": {}, "png_written": {}, "valid_png": {}, "width": {d}, "height": {d}, "non_background_pixels": {d} }},
        \\  "lowered": {{ "gpu_quads": {d}, "glyph_cells": {d}, "text_rasterized": {} }},
        \\  "success": {}
        \\}}
    , .{
        scenario_name,
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
        success,
    });
}

test "Chrome Lab scenario parser keeps one process bound to one deterministic artifact name" {
    try std.testing.expectEqual(lab.ScenarioId.empty, scenarioFromEnvValue("empty").?);
    try std.testing.expectEqual(lab.ScenarioId.loading, scenarioFromEnvValue("loading").?);
    try std.testing.expectEqual(lab.ScenarioId.retained_list, scenarioFromEnvValue("retained-list").?);
    try std.testing.expectEqual(lab.ScenarioId.partial_scroll, scenarioFromEnvValue("partial-scroll").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_loading, scenarioFromEnvValue("detail-loading").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_ready, scenarioFromEnvValue("detail-ready").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_stale, scenarioFromEnvValue("detail-stale").?);
    try std.testing.expectEqual(lab.ScenarioId.detail_unavailable, scenarioFromEnvValue("detail-unavailable").?);
    try std.testing.expect(scenarioFromEnvValue("unknown") == null);
    try std.testing.expectEqualStrings("empty", artifactName(.empty));
    try std.testing.expectEqualStrings("loading", artifactName(.loading));
    try std.testing.expectEqualStrings("retained-list", artifactName(.retained_list));
    try std.testing.expectEqualStrings("partial-scroll", artifactName(.partial_scroll));
    try std.testing.expectEqualStrings("detail-ready", artifactName(.detail_ready));
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
    const summary = try renderSummary(std.testing.allocator, "retained-list", "artifact.ppm", "artifact.png", .{
        .status = 0,
        .renderer_created = 1,
        .atlas_ready = 1,
        .draw_submitted = 1,
        .ppm_written = 1,
        .png_written = 1,
    }, .{ .width = 320, .height = 240, .non_background_pixels = 1 }, true, 1, 2, true, true);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"glyph_cells\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"text_rasterized\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"ppm\": \"artifact.ppm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"success\": true") != null);
}
