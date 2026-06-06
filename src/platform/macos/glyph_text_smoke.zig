const std = @import("std");
const maru = @import("maru");
const config = maru.config;

const artifact_dir = "zig-out/maru-macos-glyph-text-smoke";
const screenshot_path = artifact_dir ++ "/glyph-text-frame.ppm";
const default_duration_ms: u32 = 1500;
// 이 smoke는 사람이 실제 창에서 글자를 볼 수 있게 잠깐 유지한다. 환경변수 오타나
// CI 설정 실수로 창이 오래 떠 있지 않도록 다른 visible smoke와 같은 상한을 둔다.
const max_duration_ms: u32 = 600_000;

const NativeGlyphTextSmokeResult = extern struct {
    status: c_int,
    window_visible: u32,
    metal_device_created: u32,
    command_queue_created: u32,
    source_rasterized: u32,
    texture_created: u32,
    texture_uploaded: u32,
    pipeline_created: u32,
    glyph_text_drawn: u32,
    presented_frames: u32,
    drawable_failures: u32,
    source_width: u32,
    source_height: u32,
    source_non_clear_pixels: u32,
    readback_samples: u32,
    readback_non_clear_pixels: u32,
    readback_visible_glyph_pixels: u32,
    readback_failures: u32,
    upload_bytes: u32,
    screenshot_written: u32,
    screenshot_width: u32,
    screenshot_height: u32,
    screenshot_bytes: u32,
    screenshot_failures: u32,
};

// config.ResolvedAppearance에서 온 검증된 색을 native bridge로 넘긴다. 필드 순서/타입은
// appkit_glyph_text_smoke.m의 MaruGlyphTextAppearance와 정확히 일치해야 한다.
const NativeGlyphTextAppearance = extern struct {
    background_r: u8,
    background_g: u8,
    background_b: u8,
    foreground_r: u8,
    foreground_g: u8,
    foreground_b: u8,
    cursor_r: u8,
    cursor_g: u8,
    cursor_b: u8,
};

extern fn maru_macos_glyph_text_smoke_run(
    duration_ms: u32,
    appearance: *const NativeGlyphTextAppearance,
    screenshot_path_ptr: [*]const u8,
    screenshot_path_len: usize,
    result: *NativeGlyphTextSmokeResult,
) void;

fn nativeAppearance(appearance: config.ResolvedAppearance) NativeGlyphTextAppearance {
    return .{
        .background_r = appearance.theme.background.r,
        .background_g = appearance.theme.background.g,
        .background_b = appearance.theme.background.b,
        .foreground_r = appearance.theme.foreground.r,
        .foreground_g = appearance.theme.foreground.g,
        .foreground_b = appearance.theme.foreground.b,
        .cursor_r = appearance.theme.cursor.r,
        .cursor_g = appearance.theme.cursor.g,
        .cursor_b = appearance.theme.cursor.b,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const duration_ms = readDurationMs();
    // raw config 색 문자열을 frame loop 안에서 해석하지 않고, 시작 시점에 한 번 검증된
    // ResolvedAppearance로 바꿔 native bridge로 넘긴다. 기본 config는 항상 resolve된다.
    const appearance = try config.resolveAppearance(.{});
    const native_appearance = nativeAppearance(appearance);
    var native = emptyNativeResult();
    try ensureArtifactDir(io);
    maru_macos_glyph_text_smoke_run(duration_ms, &native_appearance, screenshot_path.ptr, screenshot_path.len, &native);

    const smoke_status = deriveSmokeStatus(native);
    const summary = try renderSummary(allocator, duration_ms, smoke_status, native, native_appearance);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!smoke_status.glyph_text_drawn) return error.MacosGlyphTextSmokeFailed;
}

fn emptyNativeResult() NativeGlyphTextSmokeResult {
    return .{
        .status = -1,
        .window_visible = 0,
        .metal_device_created = 0,
        .command_queue_created = 0,
        .source_rasterized = 0,
        .texture_created = 0,
        .texture_uploaded = 0,
        .pipeline_created = 0,
        .glyph_text_drawn = 0,
        .presented_frames = 0,
        .drawable_failures = 0,
        .source_width = 0,
        .source_height = 0,
        .source_non_clear_pixels = 0,
        .readback_samples = 0,
        .readback_non_clear_pixels = 0,
        .readback_visible_glyph_pixels = 0,
        .readback_failures = 0,
        .upload_bytes = 0,
        .screenshot_written = 0,
        .screenshot_width = 0,
        .screenshot_height = 0,
        .screenshot_bytes = 0,
        .screenshot_failures = 0,
    };
}

fn readDurationMs() u32 {
    // glyph texture smoke는 창이 없지만 이 smoke는 창을 띄운다. 별도 env를 두면
    // 텍스처 업로드 검증과 화면 글자 확인 시간을 서로 다르게 조절할 수 있다.
    const raw_ptr = std.c.getenv("MARU_GLYPH_TEXT_SMOKE_MS") orelse return default_duration_ms;
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
    source_rasterized: bool,
    glyph_texture_sampled: bool,
    screenshot_artifact: bool,
    glyph_text_drawn: bool,
};

fn deriveSmokeStatus(native: NativeGlyphTextSmokeResult) SmokeStatus {
    // 이 smoke의 핵심은 "texture를 만들었다"가 아니라 "그 texture를 fragment shader가
    // 실제 CAMetalDrawable에 샘플링했고, glyph ink 위치를 readback했다"이다. 그래서
    // 입력 카운터가 아니라 non-clear readback sample을 최종 gate로 삼는다.
    const visible_ui = native.window_visible != 0;
    const metal_surface = native.metal_device_created != 0 and
        native.command_queue_created != 0 and
        native.presented_frames > 0;
    const source_rasterized = native.source_rasterized != 0 and
        native.source_width > 0 and
        native.source_height > 0 and
        native.source_non_clear_pixels > 0;
    const glyph_texture_sampled = source_rasterized and
        metal_surface and
        native.texture_created != 0 and
        native.texture_uploaded != 0 and
        native.pipeline_created != 0 and
        native.upload_bytes > 0 and
        native.readback_samples > 0 and
        native.readback_non_clear_pixels == native.readback_samples and
        native.readback_visible_glyph_pixels == native.readback_samples and
        native.readback_failures == 0;
    const screenshot_artifact = glyph_texture_sampled and
        native.screenshot_written != 0 and
        native.screenshot_width > 0 and
        native.screenshot_height > 0 and
        native.screenshot_bytes > 0 and
        native.screenshot_failures == 0;

    return .{
        .visible_ui = visible_ui,
        .metal_surface = metal_surface,
        .source_rasterized = source_rasterized,
        .glyph_texture_sampled = glyph_texture_sampled,
        .screenshot_artifact = screenshot_artifact,
        .glyph_text_drawn = visible_ui and
            glyph_texture_sampled and
            screenshot_artifact and
            native.status == 0 and
            native.glyph_text_drawn != 0,
    };
}

// applied_* 색을 #RRGGBB로 찍는다. 세 채널을 한 곳에서 같은 순서(r,g,b)로 포맷해,
// 호출부마다 {x:0>2} triple을 반복하다 채널 순서를 헷갈리는 실수를 막는다.
fn writeAppliedColor(writer: anytype, label: []const u8, r: u8, g: u8, b: u8) !void {
    try writer.print("{s}=#{x:0>2}{x:0>2}{x:0>2}\n", .{ label, r, g, b });
}

fn renderSummary(
    allocator: std.mem.Allocator,
    duration_ms: u32,
    smoke_status: SmokeStatus,
    native: NativeGlyphTextSmokeResult,
    appearance: NativeGlyphTextAppearance,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-glyph-text-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("visible_ui={}\n", .{smoke_status.visible_ui});
    try writer.print("metal_surface={}\n", .{smoke_status.metal_surface});
    try writer.print("source_rasterized={}\n", .{smoke_status.source_rasterized});
    try writer.print("glyph_texture_sampled={}\n", .{smoke_status.glyph_texture_sampled});
    try writer.print("screenshot_artifact={}\n", .{smoke_status.screenshot_artifact});
    try writer.print("screenshot_path={s}\n", .{screenshot_path});
    try writer.writeAll("screenshot_format=ppm_rgb_from_bgra8_drawable_readback\n");
    try writer.print("glyph_text={}\n", .{smoke_status.glyph_text_drawn});
    // resolved ResolvedAppearance 색이 실제 렌더에 쓰였음을 artifact로 남긴다. background는
    // Metal clear color로, foreground는 CoreText glyph fill로 적용된다. cursor 색은 resolve해
    // 기록만 하고 이 smoke에서는 아직 그리지 않는다(다음 단계).
    try writeAppliedColor(writer, "applied_background", appearance.background_r, appearance.background_g, appearance.background_b);
    try writeAppliedColor(writer, "applied_foreground", appearance.foreground_r, appearance.foreground_g, appearance.foreground_b);
    try writeAppliedColor(writer, "applied_cursor", appearance.cursor_r, appearance.cursor_g, appearance.cursor_b);
    try writer.writeAll("appearance_note=background_to_clear_color_foreground_to_glyph_color_cursor_resolved_but_not_drawn\n");
    try writer.writeAll("ui_note=appkit_window_with_metal_shader_sampling_coretext_glyph_texture_no_terminal_renderer\n");
    try writer.print("duration_ms={d}\n", .{duration_ms});
    try writer.print("native_status={d}\n", .{native.status});
    try writer.print("native_status_label={s}\n", .{nativeStatusLabel(native.status)});
    try writer.print("window_visible={d}\n", .{native.window_visible});
    try writer.print("metal_device_created={d}\n", .{native.metal_device_created});
    try writer.print("command_queue_created={d}\n", .{native.command_queue_created});
    try writer.print("native_source_rasterized={d}\n", .{native.source_rasterized});
    try writer.print("texture_created={d}\n", .{native.texture_created});
    try writer.print("texture_uploaded={d}\n", .{native.texture_uploaded});
    try writer.print("pipeline_created={d}\n", .{native.pipeline_created});
    try writer.print("native_glyph_text_drawn={d}\n", .{native.glyph_text_drawn});
    try writer.print("presented_frames={d}\n", .{native.presented_frames});
    try writer.print("drawable_failures={d}\n", .{native.drawable_failures});
    try writer.print("source_width={d}\n", .{native.source_width});
    try writer.print("source_height={d}\n", .{native.source_height});
    try writer.print("source_non_clear_pixels={d}\n", .{native.source_non_clear_pixels});
    try writer.print("readback_samples={d}\n", .{native.readback_samples});
    try writer.print("readback_non_clear_pixels={d}\n", .{native.readback_non_clear_pixels});
    try writer.print("readback_visible_glyph_pixels={d}\n", .{native.readback_visible_glyph_pixels});
    try writer.print("readback_failures={d}\n", .{native.readback_failures});
    try writer.print("upload_bytes={d}\n", .{native.upload_bytes});
    try writer.print("screenshot_written={d}\n", .{native.screenshot_written});
    try writer.print("screenshot_width={d}\n", .{native.screenshot_width});
    try writer.print("screenshot_height={d}\n", .{native.screenshot_height});
    try writer.print("screenshot_bytes={d}\n", .{native.screenshot_bytes});
    try writer.print("screenshot_failures={d}\n", .{native.screenshot_failures});

    return output.toOwnedSlice();
}

fn nativeStatusLabel(status: c_int) []const u8 {
    return switch (status) {
        -1 => "not_run",
        0 => "ok",
        1 => "window_create_failed",
        2 => "cpu_raster_failed",
        3 => "metal_device_failed",
        4 => "command_queue_failed",
        5 => "texture_create_or_upload_failed",
        6 => "pipeline_create_failed",
        7 => "drawable_or_frame_failed",
        8 => "readback_infra_failed",
        9 => "readback_pixels_clear_or_partial",
        10 => "screenshot_write_failed",
        else => "unknown",
    };
}

fn ensureArtifactDir(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try ensureArtifactDir(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/glyph-text.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS glyph text smoke summary reports shader sampling boundary" {
    // native Metal을 호출하지 않는 계약 테스트에서도 artifact 의미를 고정한다.
    // 제품 renderer가 아직 없어도 "texture upload"와 "shader sampling text draw"는
    // 서로 다른 실패 단계라는 점을 summary schema로 분리해야 한다.
    const native: NativeGlyphTextSmokeResult = .{
        .status = 0,
        .window_visible = 1,
        .metal_device_created = 1,
        .command_queue_created = 1,
        .source_rasterized = 1,
        .texture_created = 1,
        .texture_uploaded = 1,
        .pipeline_created = 1,
        .glyph_text_drawn = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .source_width = 128,
        .source_height = 64,
        .source_non_clear_pixels = 77,
        .readback_samples = 16,
        .readback_non_clear_pixels = 16,
        .readback_visible_glyph_pixels = 16,
        .readback_failures = 0,
        .upload_bytes = 32768,
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3628800,
        .screenshot_failures = 0,
    };
    const appearance: NativeGlyphTextAppearance = .{
        .background_r = 0x10,
        .background_g = 0x10,
        .background_b = 0x10,
        .foreground_r = 0xe8,
        .foreground_g = 0xe8,
        .foreground_b = 0xe8,
        .cursor_r = 0xff,
        .cursor_g = 0xff,
        .cursor_b = 0xff,
    };
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, appearance);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-glyph-text-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "visible_ui=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_surface=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "source_rasterized=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_texture_sampled=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_artifact=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_path=zig-out/maru-macos-glyph-text-smoke/glyph-text-frame.ppm\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_format=ppm_rgb_from_bgra8_drawable_readback\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "native_status_label=ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_samples=16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_non_clear_pixels=16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "readback_visible_glyph_pixels=16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "upload_bytes=32768\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_written=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_width=1440\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_height=840\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_bytes=3628800\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "screenshot_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_background=#101010\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_foreground=#e8e8e8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_cursor=#ffffff\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "appearance_note=background_to_clear_color_foreground_to_glyph_color_cursor_resolved_but_not_drawn\n") != null);
}

test "glyph text smoke maps resolved appearance colors into the native bridge" {
    // ResolvedAppearance의 theme 색이 native bridge struct로 정확히 매핑되는지 고정한다.
    // 이게 어긋나면 잘못된 색이 clear/glyph로 그려져도 summary가 진짜 적용된 색을 못 남긴다.
    const appearance = nativeAppearance(try config.resolveAppearance(.{}));
    // 기본 theme: background #101010, foreground #e8e8e8, cursor #ffffff
    try std.testing.expectEqual(@as(u8, 0x10), appearance.background_r);
    try std.testing.expectEqual(@as(u8, 0x10), appearance.background_g);
    try std.testing.expectEqual(@as(u8, 0x10), appearance.background_b);
    try std.testing.expectEqual(@as(u8, 0xe8), appearance.foreground_r);
    try std.testing.expectEqual(@as(u8, 0xff), appearance.cursor_r);

    const native = emptyNativeResult();
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, appearance);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_background=#101010\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_foreground=#e8e8e8\n") != null);
}

test "glyph text smoke preserves per-channel theme colors" {
    // 기본 theme는 회색(r==g==b)이라 채널 전치 버그(예: background_b = .r)를 못 잡는다.
    // r/g/b가 모두 다른 색을 넣어 nativeAppearance 매핑과 summary echo가 채널을 섞지
    // 않는지 고정한다.
    const appearance = nativeAppearance(try config.resolveAppearance(.{
        .theme = .{ .background = "#ab12cd", .foreground = "#0099ff" },
    }));
    try std.testing.expectEqual(@as(u8, 0xab), appearance.background_r);
    try std.testing.expectEqual(@as(u8, 0x12), appearance.background_g);
    try std.testing.expectEqual(@as(u8, 0xcd), appearance.background_b);
    try std.testing.expectEqual(@as(u8, 0x00), appearance.foreground_r);
    try std.testing.expectEqual(@as(u8, 0x99), appearance.foreground_g);
    try std.testing.expectEqual(@as(u8, 0xff), appearance.foreground_b);

    const native = emptyNativeResult();
    const summary = try renderSummary(std.testing.allocator, 1500, deriveSmokeStatus(native), native, appearance);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_background=#ab12cd\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "applied_foreground=#0099ff\n") != null);
}

test "glyph text smoke status labels explain native failure stages" {
    // 실패 artifact를 볼 때 status 숫자만 있으면 Objective-C bridge를 다시 열어봐야
    // 한다. label 계약을 고정해 CI artifact만으로 멈춘 단계를 읽게 한다.
    try std.testing.expectEqualStrings("not_run", nativeStatusLabel(-1));
    try std.testing.expectEqualStrings("ok", nativeStatusLabel(0));
    try std.testing.expectEqualStrings("window_create_failed", nativeStatusLabel(1));
    try std.testing.expectEqualStrings("cpu_raster_failed", nativeStatusLabel(2));
    try std.testing.expectEqualStrings("metal_device_failed", nativeStatusLabel(3));
    try std.testing.expectEqualStrings("command_queue_failed", nativeStatusLabel(4));
    try std.testing.expectEqualStrings("texture_create_or_upload_failed", nativeStatusLabel(5));
    try std.testing.expectEqualStrings("pipeline_create_failed", nativeStatusLabel(6));
    try std.testing.expectEqualStrings("drawable_or_frame_failed", nativeStatusLabel(7));
    try std.testing.expectEqualStrings("readback_infra_failed", nativeStatusLabel(8));
    try std.testing.expectEqualStrings("readback_pixels_clear_or_partial", nativeStatusLabel(9));
    try std.testing.expectEqualStrings("screenshot_write_failed", nativeStatusLabel(10));
    try std.testing.expectEqualStrings("unknown", nativeStatusLabel(99));
}

test "glyph text draw requires visible UI, shader sampling, and native success" {
    // glyph_text=true는 "창이 떴다"나 "texture가 있다"가 아니라, shader가 glyph
    // texture를 drawable에 샘플링했고 그 ink pixel을 readback했다는 최종 신호다.
    const ok: NativeGlyphTextSmokeResult = .{
        .status = 0,
        .window_visible = 1,
        .metal_device_created = 1,
        .command_queue_created = 1,
        .source_rasterized = 1,
        .texture_created = 1,
        .texture_uploaded = 1,
        .pipeline_created = 1,
        .glyph_text_drawn = 1,
        .presented_frames = 3,
        .drawable_failures = 0,
        .source_width = 128,
        .source_height = 64,
        .source_non_clear_pixels = 77,
        .readback_samples = 16,
        .readback_non_clear_pixels = 16,
        .readback_visible_glyph_pixels = 16,
        .readback_failures = 0,
        .upload_bytes = 32768,
        .screenshot_written = 1,
        .screenshot_width = 1440,
        .screenshot_height = 840,
        .screenshot_bytes = 3628800,
        .screenshot_failures = 0,
    };
    try std.testing.expect(deriveSmokeStatus(ok).glyph_text_drawn);

    var hidden = ok;
    hidden.window_visible = 0;
    hidden.status = 1;
    try std.testing.expect(!deriveSmokeStatus(hidden).visible_ui);
    try std.testing.expect(!deriveSmokeStatus(hidden).glyph_text_drawn);

    var no_pipeline = ok;
    no_pipeline.pipeline_created = 0;
    no_pipeline.status = 6;
    try std.testing.expect(!deriveSmokeStatus(no_pipeline).glyph_texture_sampled);
    try std.testing.expect(!deriveSmokeStatus(no_pipeline).glyph_text_drawn);

    var no_draw = ok;
    no_draw.glyph_text_drawn = 0;
    no_draw.status = 9;
    try std.testing.expect(deriveSmokeStatus(no_draw).glyph_texture_sampled);
    try std.testing.expect(!deriveSmokeStatus(no_draw).glyph_text_drawn);
}

test "glyph text smoke requires a screenshot artifact before reporting final success" {
    // readback 숫자만 있으면 실패한 프레임을 사람이 바로 볼 수 없다. 이 smoke는 첫
    // visible glyph draw 경계이므로, 최종 성공은 PPM screenshot artifact까지 남겼을
    // 때만 true가 된다.
    var no_screenshot = emptyNativeResult();
    no_screenshot.status = 0;
    no_screenshot.window_visible = 1;
    no_screenshot.metal_device_created = 1;
    no_screenshot.command_queue_created = 1;
    no_screenshot.source_rasterized = 1;
    no_screenshot.texture_created = 1;
    no_screenshot.texture_uploaded = 1;
    no_screenshot.pipeline_created = 1;
    no_screenshot.glyph_text_drawn = 1;
    no_screenshot.presented_frames = 1;
    no_screenshot.source_width = 128;
    no_screenshot.source_height = 64;
    no_screenshot.source_non_clear_pixels = 77;
    no_screenshot.readback_samples = 16;
    no_screenshot.readback_non_clear_pixels = 16;
    no_screenshot.readback_visible_glyph_pixels = 16;
    no_screenshot.upload_bytes = 32768;

    try std.testing.expect(deriveSmokeStatus(no_screenshot).glyph_texture_sampled);
    try std.testing.expect(!deriveSmokeStatus(no_screenshot).screenshot_artifact);
    try std.testing.expect(!deriveSmokeStatus(no_screenshot).glyph_text_drawn);

    var screenshot_failed = no_screenshot;
    screenshot_failed.screenshot_written = 1;
    screenshot_failed.screenshot_width = 1440;
    screenshot_failed.screenshot_height = 840;
    screenshot_failed.screenshot_bytes = 3628800;
    screenshot_failed.screenshot_failures = 1;
    try std.testing.expect(!deriveSmokeStatus(screenshot_failed).screenshot_artifact);

    var success = screenshot_failed;
    success.screenshot_failures = 0;
    try std.testing.expect(deriveSmokeStatus(success).screenshot_artifact);
    try std.testing.expect(deriveSmokeStatus(success).glyph_text_drawn);
}

test "glyph text smoke readback must sample every selected glyph ink pixel" {
    // 한두 픽셀만 읽으면 글자가 비어 있거나 텍스처 좌표가 틀린 회귀를 놓친다.
    // smoke는 source glyph의 ink 위치 여러 개를 고르고, 그 위치가 모두 non-clear로
    // 돌아올 때만 shader sampling 성공으로 인정한다.
    var partial = emptyNativeResult();
    partial.status = 0;
    partial.window_visible = 1;
    partial.metal_device_created = 1;
    partial.command_queue_created = 1;
    partial.source_rasterized = 1;
    partial.texture_created = 1;
    partial.texture_uploaded = 1;
    partial.pipeline_created = 1;
    partial.glyph_text_drawn = 1;
    partial.presented_frames = 1;
    partial.source_width = 128;
    partial.source_height = 64;
    partial.source_non_clear_pixels = 77;
    partial.readback_samples = 16;
    partial.readback_non_clear_pixels = 15;
    partial.readback_visible_glyph_pixels = 15;
    partial.upload_bytes = 32768;
    partial.screenshot_written = 1;
    partial.screenshot_width = 1440;
    partial.screenshot_height = 840;
    partial.screenshot_bytes = 3628800;
    try std.testing.expect(!deriveSmokeStatus(partial).glyph_texture_sampled);
    try std.testing.expect(!deriveSmokeStatus(partial).glyph_text_drawn);

    var failed = partial;
    failed.readback_non_clear_pixels = 16;
    failed.readback_visible_glyph_pixels = 16;
    failed.readback_failures = 1;
    try std.testing.expect(!deriveSmokeStatus(failed).glyph_texture_sampled);

    var success = failed;
    success.readback_failures = 0;
    try std.testing.expect(deriveSmokeStatus(success).glyph_texture_sampled);
    try std.testing.expect(deriveSmokeStatus(success).glyph_text_drawn);
}

test "glyph text smoke rejects non-clear but visually dark glyph samples" {
    // 검정 glyph는 clear 색과 다르므로 non-clear readback만 보면 성공처럼 보인다.
    // 하지만 사용자가 보는 터미널에서는 어두운 배경에 묻히므로, 밝은 glyph pixel도
    // 별도로 세어야 screenshot artifact와 summary가 실제 UX를 반영한다.
    var dark = emptyNativeResult();
    dark.status = 0;
    dark.window_visible = 1;
    dark.metal_device_created = 1;
    dark.command_queue_created = 1;
    dark.source_rasterized = 1;
    dark.texture_created = 1;
    dark.texture_uploaded = 1;
    dark.pipeline_created = 1;
    dark.glyph_text_drawn = 1;
    dark.presented_frames = 1;
    dark.source_width = 128;
    dark.source_height = 64;
    dark.source_non_clear_pixels = 77;
    dark.readback_samples = 16;
    dark.readback_non_clear_pixels = 16;
    dark.readback_visible_glyph_pixels = 0;
    dark.upload_bytes = 32768;
    dark.screenshot_written = 1;
    dark.screenshot_width = 1440;
    dark.screenshot_height = 840;
    dark.screenshot_bytes = 3628800;

    try std.testing.expect(!deriveSmokeStatus(dark).glyph_texture_sampled);
    try std.testing.expect(!deriveSmokeStatus(dark).glyph_text_drawn);
}

test "glyph text smoke duration override clamps invalid, zero, and oversized values" {
    // visible smoke는 local UI를 잠깐 띄우므로 duration 정책을 테스트로 고정한다.
    // 이렇게 해야 수동 확인은 늘릴 수 있고, 실수로 긴 run이 CI를 붙잡는 일은 막는다.
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("abc"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv(""));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("0"));
    try std.testing.expectEqual(default_duration_ms, durationFromEnv("99999999999")); // > u32 max
    try std.testing.expectEqual(@as(u32, 250), durationFromEnv("250"));
    try std.testing.expectEqual(max_duration_ms, durationFromEnv("99999999")); // > 상한
}
