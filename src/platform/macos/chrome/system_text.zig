//! macOS CoreText shaping adapter for shared chrome text artifacts.
//! CoreText/cache calls stay here; requests, placement and ownership live in app.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const common = maru.app.chrome_text;
const bridge = @import("../coretext_smoke_bridge.zig");
pub const Placement = common.Placement;
pub const Request = common.Request;
pub const UnresolvedGlyph = common.UnresolvedGlyph;
pub const UnresolvedArtifact = common.UnresolvedArtifact;
pub const Artifact = common.Artifact;
pub const Face = common.Face;
pub const prepareRequest = common.prepareRequest;
pub const shapesTextOp = common.shapesTextOp;
pub const shapesRun = common.shapesRun;
pub const opMaxWidthPx = common.opMaxWidthPx;
pub const resolveArtifact = common.resolveArtifact;
pub const emptyDrawList = common.emptyDrawList;

pub fn shapeOps(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    face: Face,
    scale_milli: u32,
) !Artifact {
    return common.shapeOpsWith(allocator, registry, ops, tk, cell_width_px, face, scale_milli, shapeUnresolvedRun);
}

pub fn shapeRequest(allocator: std.mem.Allocator, request: *const Request, scale_milli: u32) !UnresolvedArtifact {
    return common.shapeRequestWith(allocator, request, scale_milli, shapeUnresolvedRun);
}

pub fn shapeRun(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    text: []const u8,
    role: chrome.ui.typography.ChromeTextRole,
    origin: chrome.draw.Px,
    max_width_px: u32,
    foreground: u32,
    face: Face,
    scale_milli: u32,
) !Artifact {
    return common.shapeRunWith(allocator, registry, text, role, origin, max_width_px, foreground, face, scale_milli, shapeUnresolvedRun);
}

fn weight(role: chrome.ui.typography.ChromeTextRole) u32 {
    return switch (chrome.ui.typography.token(role).weight) {
        .regular => 0,
        .medium, .semibold => 1,
    };
}

fn shapeUnresolvedRun(allocator: std.mem.Allocator, run: Request.Run, face: Face, scale_milli: u32) ![]UnresolvedGlyph {
    if (comptime builtin.os.tag != .macos) return common.shapeUnresolvedRun(allocator, run, face, scale_milli);
    const metrics = common.runMetrics(run, scale_milli);
    const scaled_size = metrics.scaled_size;
    const point_size = metrics.point_size;
    var native: bridge.NativeChromeTextShapeResult = .{};
    const capacity = metrics.capacity;

    // **여기서 갈라진다.** 위에서 정한 크기·줄 높이·색은 그대로 쓰고 글리프를 만드는 일만 플랫폼이
    // 한다. 아래 CoreText 경로와 **같은 `UnresolvedGlyph`** 로 접히므로 두 플랫폼이 같은 화면을 낸다.

    var glyphs = try allocator.alloc(bridge.NativeChromeTextGlyphRecord, capacity);
    defer allocator.free(glyphs);
    bridge.maru_macos_coretext_shape_chrome_text(
        run.text.ptr,
        run.text.len,
        face.family.ptr,
        face.family.len,
        face.fallback.ptr,
        face.fallback.len,
        scaled_size,
        weight(run.role),
        @floatFromInt(run.max_width_px),
        @intFromBool(run.anchor == .tail),
        &native,
        glyphs.ptr,
        glyphs.len,
    );
    if (native.status != 0 or native.glyph_record_overflow != 0) return error.CoreTextChromeTextShapeFailed;
    const count = @min(@as(usize, native.glyph_record_count), glyphs.len);
    const out = try allocator.alloc(UnresolvedGlyph, count);
    for (glyphs[0..count], out) |native_glyph, *glyph| {
        glyph.* = .{
            .glyph_id = native_glyph.glyph_id,
            .codepoint = native_glyph.codepoint,
            .fallback = native_glyph.fallback != 0,
            .color_glyph_kind = if (native_glyph.color_glyph_kind != 0) .color else .monochrome,
            .x_px = native_glyph.x_px,
            .advance_px = native_glyph.advance_px,
            .left_overhang_px = native_glyph.left_overhang_px,
            .font_name = native_glyph.font_name,
            .point_size = point_size,
            // 편집기 줄 높이는 셀에서 오고(호출자가 device px로 준다), 아니면 토큰 line height다.
            // 이 값이 래스터 높이와 세로 정렬 기준이라 폰트와 함께 커져야 글자가 안 잘린다.
            .line_height_px = if (run.line_height_px) |lh|
                @floatFromInt(lh)
            else
                @floatFromInt(chrome.ui.typography.lineHeightPx(run.role, scale_milli)),
            .origin = run.origin,
            .foreground = run.foreground,
            .run_index = 0,
        };
    }
    return out;
}

test "chrome text shapes with the requested family and keeps the system face when none is given" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Session" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 40 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });

    var system_request = try prepareRequest(allocator, 1, &ops, &tk, 8, .{});
    defer system_request.deinit(allocator);
    var system_artifact = try shapeRequest(allocator, &system_request, 1000);
    defer system_artifact.deinit(allocator);

    var menlo_request = try prepareRequest(allocator, 2, &ops, &tk, 8, .{ .family = "Menlo" });
    defer menlo_request.deinit(allocator);
    var menlo_artifact = try shapeRequest(allocator, &menlo_request, 1000);
    defer menlo_artifact.deinit(allocator);

    try std.testing.expect(system_artifact.glyphs.len > 0);
    try std.testing.expect(menlo_artifact.glyphs.len > 0);
    const menlo_name = std.mem.sliceTo(&menlo_artifact.glyphs[0].font_name, 0);
    const system_name = std.mem.sliceTo(&system_artifact.glyphs[0].font_name, 0);
    try std.testing.expect(std.mem.startsWith(u8, menlo_name, "Menlo"));
    try std.testing.expect(!std.mem.startsWith(u8, system_name, "Menlo"));
}

test "tail anchor truncates the head so the caret end survives" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaZ";
    const runs = [_]chrome.draw.Run{.{ .text = long }};
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });

    const Shape = struct {
        fn run(alloc: std.mem.Allocator, tokens: *const chrome.Tokens, text_runs: []const chrome.draw.Run, anchor: chrome.text_layout.Anchor) !UnresolvedArtifact {
            const ops = [_]chrome.draw.Op{.{
                .text = .{
                    .origin = .{ .x = 0, .y = 0 },
                    .runs = text_runs,
                    .role = .surface_fg,
                    .text_role = .control,
                    .max_width_px = 60, // 원문보다 훨씬 좁다 → 반드시 잘린다
                    .anchor = anchor,
                },
            }};
            var request = try prepareRequest(alloc, 1, &ops, tokens, 8, .{});
            defer request.deinit(alloc);
            return shapeRequest(alloc, &request, 1000);
        }
    };

    var head = try Shape.run(allocator, &tk, &runs, .head);
    defer head.deinit(allocator);
    var tail = try Shape.run(allocator, &tk, &runs, .tail);
    defer tail.deinit(allocator);
    try std.testing.expect(head.glyphs.len > 0 and tail.glyphs.len > 0);

    // 판정은 **끝 글자가 살아남는가**로 한다. 브리지는 codepoint를 원본 문자열의 `string_index`에서 읽으므로
    // `…` 토큰 glyph가 원본 문자로 보고될 수 있다 — 즉 "앞에 …가 붙었나"는 이 ABI로 신뢰할 수 없다. 반면
    // 계약의 본질은 "caret이 있는 끝이 남는가"이고, 그건 마지막 glyph로 정확히 판정된다.
    try std.testing.expectEqual(@as(u32, 'Z'), tail.glyphs[tail.glyphs.len - 1].codepoint);
    // head 앵커는 반대로 끝을 버린다 — 두 앵커가 같은 결과를 내면 이 이관이 무의미하므로 함께 고정한다.
    try std.testing.expect(head.glyphs[head.glyphs.len - 1].codepoint != 'Z');
}

test "an unknown chrome family falls back to the system face instead of blanking the dock" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Session" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 40 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 3, &ops, &tk, 8, .{ .family = "MaruNoSuchFamily12345" });
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 1000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
    const name = std.mem.sliceTo(&artifact.glyphs[0].font_name, 0);
    try std.testing.expect(!std.mem.startsWith(u8, name, "MaruNoSuchFamily"));
}

test "owned request shapes proportional text before renderer registry resolution" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 12, .y = 8 },
        .runs = &runs,
        .role = .surface_fg,
        .text_role = .dock_heading,
        .max_cols = 40,
    } }};
    const tokens = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 10, .g = 10, .b = 10 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 50, .g = 50, .b = 50 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 60, .g = 80, .b = 120 },
        .cursor = .{ .r = 255, .g = 255, .b = 255 },
        .terminal_background = .{ .r = 255, .g = 255, .b = 255 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 20, .g = 120, .b = 255 },
    });
    var request = try prepareRequest(allocator, 44, &ops, &tokens, 16, .{});
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 2000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
}

test "chrome text shaping reuses one face across roles instead of rebuilding it per run" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const roles = [_]chrome.ui.typography.ChromeTextRole{
        .dock_heading, .supporting, .control, .group_heading, .card_heading, .body, .metadata, .overline, .button_label,
    };

    // 두 요청은 텍스트·길이·run 수가 완전히 같고 role만 다르다. 따라서 차이는 face 생성 비용뿐이다.
    const Shape = struct {
        const run_count = 55;
        const sample_count = 21;
        const Sample = struct {
            median_ns: u64,
            hits: u64,
            misses: u64,
        };

        fn sample(gpa: std.mem.Allocator, clock_io: std.Io, varied_roles: bool, role_table: []const chrome.ui.typography.ChromeTextRole, scale_milli: u32) !Sample {
            const runs = try gpa.alloc(Request.Run, run_count);
            for (runs, 0..) |*run, index| run.* = .{
                .text = try gpa.dupe(u8, "세션 기록 도크 스크롤 측정"),
                .role = if (varied_roles) role_table[index % role_table.len] else .card_heading,
                .origin = .{ .x = 0, .y = 0 },
                // truncation 경로는 이 테스트의 대상이 아니므로 타지 않게 한다.
                .max_width_px = 1_000_000,
                .foreground = 0xffffff,
            };
            var request = Request{ .fingerprint = 0, .runs = runs };
            defer request.deinit(gpa);

            // face 캐시를 채우는 첫 호출은 정상 상태 비용이 아니다.
            var warm = try shapeRequest(gpa, &request, scale_milli);
            warm.deinit(gpa);

            var hits_before: u64 = 0;
            var misses_before: u64 = 0;
            bridge.maru_macos_coretext_chrome_font_cache_stats_for_test(&hits_before, &misses_before);

            var samples: [sample_count]u64 = undefined;
            for (&samples) |*elapsed_ns| {
                const start = std.Io.Clock.awake.now(clock_io).nanoseconds;
                var artifact = try shapeRequest(gpa, &request, scale_milli);
                elapsed_ns.* = @intCast(std.Io.Clock.awake.now(clock_io).nanoseconds - start);
                artifact.deinit(gpa);
            }
            var hits_after: u64 = 0;
            var misses_after: u64 = 0;
            bridge.maru_macos_coretext_chrome_font_cache_stats_for_test(&hits_after, &misses_after);
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            return .{
                .median_ns = samples[samples.len / 2],
                .hits = hits_after - hits_before,
                .misses = misses_after - misses_before,
            };
        }
    };

    const expected_hits = Shape.run_count * Shape.sample_count;
    const same_role = try Shape.sample(allocator, io, false, &roles, 2000);
    try std.testing.expectEqual(@as(u64, expected_hits), same_role.hits);
    try std.testing.expectEqual(@as(u64, 0), same_role.misses);

    const varied_role = try Shape.sample(allocator, io, true, &roles, 2000);
    try std.testing.expectEqual(@as(u64, expected_hits), varied_role.hits);
    try std.testing.expectEqual(@as(u64, 0), varied_role.misses);

    // 상한만 두고 축출을 안 하면 캐시는 `Cmd`+`+`/`-` 몇 번에 가득 찬다(dock scale이 폰트 크기를 따라가므로
    // 크기마다 role 9개가 새 항목이다). 그 뒤로는 매 run이 폰트를 다시 만드는 옛 경로로 **조용히** 되돌아가고
    // 그 상태가 영구히 남는다. 위 ratio는 이걸 못 잡는다 — 캐시가 막히면 두 측정이 **함께** 느려져 비율이
    // 그대로이기 때문이다. 그래서 용량을 넘길 만큼 여러 scale을 흘려보낸 뒤 같은 측정을 다시 한다.
    // 축출이 있으면 첫 iteration이 그 scale의 face를 다시 채워 이후가 hit이므로 median이 유지된다.
    var overflow_scale: u32 = 1100;
    while (overflow_scale <= 1900) : (overflow_scale += 100) {
        const overflow_sample = try Shape.sample(allocator, io, true, &roles, overflow_scale);
        try std.testing.expectEqual(@as(u64, expected_hits), overflow_sample.hits);
        try std.testing.expectEqual(@as(u64, 0), overflow_sample.misses);
    }
    // 측정 scale은 **한 번도 캐시된 적 없는** 값이어야 한다. 이미 들어갔던 scale로 재면 축출이 없어도
    // 초기 항목이 살아남아 hit이 나므로 판별이 안 된다(실제로 그렇게 통과했다).
    const after_overflow = try Shape.sample(allocator, io, true, &roles, 2100);
    try std.testing.expectEqual(@as(u64, expected_hits), after_overflow.hits);
    try std.testing.expectEqual(@as(u64, 0), after_overflow.misses);

    // timing은 판정에 쓰지 않지만 0이 아니어야 실제 product shape 호출이 수행된 것이다.
    try std.testing.expect(same_role.median_ns > 0);
    try std.testing.expect(varied_role.median_ns > 0);
    try std.testing.expect(after_overflow.median_ns > 0);
}
