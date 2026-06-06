const std = @import("std");
const maru = @import("maru");
const renderer = maru.renderer;

const artifact_dir = "zig-out/maru-macos-coretext-smoke";
const font_name_capacity = 128;
const glyph_record_capacity = 64;

const NativeCoreTextSmokeResult = extern struct {
    status: c_int,
    primary_font_found: u32,
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
};

extern fn maru_macos_coretext_smoke_run(
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

    var native: NativeCoreTextSmokeResult = emptyNativeResult();
    var glyph_records = [_]NativeGlyphRecord{emptyGlyphRecord()} ** glyph_record_capacity;
    maru_macos_coretext_smoke_run(&native, &glyph_records, glyph_records.len);

    const smoke_status = deriveSmokeStatus(native);
    const record_count = @min(@as(usize, @intCast(native.glyph_record_count)), glyph_records.len);
    const glyph_frame_probe = try buildGlyphFrameProbe(allocator, native, glyph_records[0..record_count]);
    const summary = try renderSummary(allocator, smoke_status, native, glyph_frame_probe);
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
    smoke_status: SmokeStatus,
    native: NativeCoreTextSmokeResult,
    glyph_frame_probe: GlyphFrameProbe,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-coretext-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("font_resolved={}\n", .{smoke_status.font_resolved});
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
    try writer.print("primary_font_name={s}\n", .{cStringField(&native.primary_font_name)});
    try writer.print("first_fallback_font_name={s}\n", .{cStringField(&native.first_fallback_font_name)});

    return output.toOwnedSlice();
}

const GlyphFrameProbe = struct {
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
};

fn buildGlyphFrameProbe(
    allocator: std.mem.Allocator,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
) !GlyphFrameProbe {
    // 이 단계는 아직 bitmap을 rasterize하지 않는다. 대신 CoreText가 준 실제
    // font_id/glyph_id 후보를 Maru의 제품 renderer 계약인 `GlyphRunList -> GlyphFrame`
    // 경로에 태운다. 그래야 다음 Metal text draw에서 "폰트는 됐는데 frame/atlas 준비가
    // 안 됐다" 같은 원인을 summary로 분리할 수 있다.
    var runs: std.ArrayList(renderer.GlyphRun) = .empty;
    errdefer runs.deinit(allocator);
    try runs.ensureTotalCapacity(allocator, records.len);

    var fallback_count: usize = 0;
    var color_glyph_count: usize = 0;

    for (records) |record| {
        if (!isDrawableAtlasRecord(record)) continue;

        const glyph = glyphRunForAtlas(record);
        if (glyph.fallback) fallback_count += 1;
        if (glyph.cache_key.color_glyph_kind == .color) color_glyph_count += 1;
        runs.appendAssumeCapacity(glyph);
    }

    const glyph_slice = try runs.toOwnedSlice(allocator);
    errdefer allocator.free(glyph_slice);
    const overlays = try allocator.alloc(renderer.DrawOverlay, 0);
    errdefer allocator.free(overlays);

    var glyph_runs: renderer.GlyphRunList = .{
        .size = .{ .cols = colsForGlyphRuns(glyph_slice), .rows = 1 },
        .cursor = .{},
        .dirty = if (glyph_slice.len > 0) .{ .start_row = 0, .end_row = 0 } else null,
        .glyphs = glyph_slice,
        .overlays = overlays,
        .fallback_count = fallback_count,
        .replacement_count = 0,
    };

    var atlas = renderer.GlyphAtlas.init(allocator, .{});
    defer atlas.deinit();

    var frame = try renderer.prepareGlyphFrame(allocator, glyph_runs, &atlas);
    defer frame.deinit(allocator);

    const shape_complete = hasNativeShapeFields(native);

    const probe: GlyphFrameProbe = .{
        .atlas_keys_ready = shape_complete and
            frame.stats.glyph_count > 0 and
            atlas.entryCount() > 0,
        .glyph_frame_ready = shape_complete and
            frame.glyphs.len == frame.stats.glyph_count and
            frame.stats.glyph_count > 0,
        .drawable_glyph_count = frame.stats.glyph_count,
        .entry_count = atlas.entryCount(),
        .upload_candidates = frame.stats.upload_count,
        .upload_bytes = frame.stats.upload_bytes,
        .color_glyph_count = color_glyph_count,
        .glyph_count = frame.stats.glyph_count,
        .upload_count = frame.stats.upload_count,
        .reused_count = frame.stats.reused_count,
        .evicted_count = frame.stats.evicted_count,
        .fallback_count = frame.stats.fallback_count,
        .replacement_count = frame.stats.replacement_count,
    };

    // glyph_runs는 이 함수가 소유하는 입력 fixture다. prepareGlyphFrame은 값으로 받아
    // overlays를 dupe하고 glyph를 복사하므로 입력 소유권을 가져가지 않는다. 성공 경로에서는
    // 여기서 glyph_slice/overlays를 한 번만 해제한다. 오류 경로는 위의 errdefer 두 개가
    // 정확히 한 번씩 해제한다. (defer glyph_runs.deinit를 함께 두면 오류 시 errdefer와
    // 겹쳐 이중 free가 되므로 두지 않는다.)
    glyph_runs.deinit(allocator);
    return probe;
}

fn colsForGlyphRuns(glyphs: []const renderer.GlyphRun) u16 {
    // CoreText smoke의 glyph records는 probe 한 줄의 UTF-16 index를 col처럼 사용한다.
    // 제품 layout metric은 아니지만, GlyphRunList가 비어 있지 않은 유효한 surface
    // metadata를 갖도록 최소 cols를 계산한다.
    var max_col: u16 = 0;
    for (glyphs) |glyph| {
        const end = std.math.add(u16, glyph.col, @as(u16, glyph.cell_width)) catch std.math.maxInt(u16);
        max_col = @max(max_col, end);
    }
    return @max(max_col, 1);
}

fn isDrawableAtlasRecord(record: NativeGlyphRecord) bool {
    if (record.glyph_id == 0) return false;
    return record.category != @intFromEnum(NativeGlyphCategory.space);
}

fn glyphRunForAtlas(record: NativeGlyphRecord) renderer.GlyphRun {
    const color_kind: renderer.ColorGlyphKind = if (record.category == @intFromEnum(NativeGlyphCategory.emoji))
        .color
    else
        .monochrome;
    return .{
        .row = 0,
        .col = @intCast(@min(record.string_index, std.math.maxInt(u16))),
        .cell_width = if (record.category == @intFromEnum(NativeGlyphCategory.cjk) or record.category == @intFromEnum(NativeGlyphCategory.emoji)) 2 else 1,
        .codepoint = codepointForProbeRecord(record),
        .font_id = record.font_id,
        .glyph_id = record.glyph_id,
        .fallback = record.fallback != 0,
        .cache_key = .{
            .font_id = record.font_id,
            .glyph_id = record.glyph_id,
            .font_size_px = 14,
            .device_scale = 1,
            .color_glyph_kind = color_kind,
        },
    };
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
        .{ .font_id = 1, .glyph_id = 10, .string_index = 0, .category = @intFromEnum(NativeGlyphCategory.ascii), .fallback = 0 },
        .{ .font_id = 2, .glyph_id = 20, .string_index = 5, .category = @intFromEnum(NativeGlyphCategory.cjk), .fallback = 1 },
        .{ .font_id = 3, .glyph_id = 30, .string_index = 7, .category = @intFromEnum(NativeGlyphCategory.emoji), .fallback = 1 },
    };
    const glyph_frame_probe = try buildGlyphFrameProbe(std.testing.allocator, native, &records);
    const summary = try renderSummary(std.testing.allocator, deriveSmokeStatus(native), native, glyph_frame_probe);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-coretext-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_resolved=true\n") != null);
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
    const probe = try buildGlyphFrameProbe(std.testing.allocator, native, &[_]NativeGlyphRecord{
        .{ .font_id = 1, .glyph_id = 10, .string_index = 0, .category = @intFromEnum(NativeGlyphCategory.ascii), .fallback = 0 },
    });
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
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
    const probe = try buildGlyphFrameProbe(std.testing.allocator, native, &[_]NativeGlyphRecord{
        .{ .font_id = 1, .glyph_id = 10, .string_index = 0, .category = @intFromEnum(NativeGlyphCategory.ascii), .fallback = 0 },
    });
    try std.testing.expect(!probe.atlas_keys_ready);
    try std.testing.expect(!probe.glyph_frame_ready);
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
    // 실제로 그릴 glyph다. space record를 제외해 frame/atlas 숫자가 과장되지 않게 한다.
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
        .{ .font_id = 1, .glyph_id = 10, .string_index = 0, .category = @intFromEnum(NativeGlyphCategory.ascii), .fallback = 0 },
        .{ .font_id = 1, .glyph_id = 5, .string_index = 4, .category = @intFromEnum(NativeGlyphCategory.space), .fallback = 0 },
    };

    const probe = try buildGlyphFrameProbe(std.testing.allocator, native, &records);
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.drawable_glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.entry_count);
    try std.testing.expectEqual(@as(usize, 1), probe.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.upload_count);

    native.glyph_record_overflow = 1;
    const overflow_probe = try buildGlyphFrameProbe(std.testing.allocator, native, &records);
    try std.testing.expect(!overflow_probe.atlas_keys_ready);
    try std.testing.expect(!overflow_probe.glyph_frame_ready);
}
