const std = @import("std");

const artifact_dir = "zig-out/maru-macos-glyph-texture-smoke";

const NativeGlyphTextureSmokeResult = extern struct {
    status: c_int,
    metal_device_created: u32,
    command_queue_created: u32,
    source_rasterized: u32,
    texture_created: u32,
    texture_uploaded: u32,
    texture_readback: u32,
    source_width: u32,
    source_height: u32,
    source_non_clear_pixels: u32,
    texture_non_clear_pixels: u32,
    texture_mismatched_pixels: u32,
    upload_bytes: u32,
    readback_failures: u32,
};

extern fn maru_macos_glyph_texture_smoke_run(result: *NativeGlyphTextureSmokeResult) void;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var native: NativeGlyphTextureSmokeResult = emptyNativeResult();
    maru_macos_glyph_texture_smoke_run(&native);

    const smoke_status = deriveSmokeStatus(native);
    const summary = try renderSummary(allocator, smoke_status, native);
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    if (!smoke_status.glyph_texture_uploaded) return error.MacosGlyphTextureSmokeFailed;
}

fn emptyNativeResult() NativeGlyphTextureSmokeResult {
    return .{
        .status = -1,
        .metal_device_created = 0,
        .command_queue_created = 0,
        .source_rasterized = 0,
        .texture_created = 0,
        .texture_uploaded = 0,
        .texture_readback = 0,
        .source_width = 0,
        .source_height = 0,
        .source_non_clear_pixels = 0,
        .texture_non_clear_pixels = 0,
        .texture_mismatched_pixels = 0,
        .upload_bytes = 0,
        .readback_failures = 0,
    };
}

const SmokeStatus = struct {
    source_rasterized: bool,
    metal_texture: bool,
    glyph_texture_uploaded: bool,
};

fn deriveSmokeStatus(native: NativeGlyphTextureSmokeResult) SmokeStatus {
    // 이 smoke는 글자를 화면에 그리지 않는다. CoreText가 만든 CPU bitmap이 Metal
    // texture로 올라가고, 같은 texture를 다시 읽었을 때 픽셀이 보존되는지만 본다.
    // 이렇게 해야 다음 text draw 실패가 rasterizer 문제인지 texture upload 문제인지
    // 작은 summary만 보고 분리할 수 있다.
    const source_rasterized = native.source_rasterized != 0 and
        native.source_width > 0 and
        native.source_height > 0 and
        native.source_non_clear_pixels > 0;
    const metal_texture = native.metal_device_created != 0 and
        native.command_queue_created != 0 and
        native.texture_created != 0;
    const glyph_texture_uploaded = source_rasterized and
        metal_texture and
        native.status == 0 and
        native.texture_uploaded != 0 and
        native.texture_readback != 0 and
        native.texture_non_clear_pixels == native.source_non_clear_pixels and
        native.texture_mismatched_pixels == 0 and
        native.upload_bytes > 0 and
        native.readback_failures == 0;

    return .{
        .source_rasterized = source_rasterized,
        .metal_texture = metal_texture,
        .glyph_texture_uploaded = glyph_texture_uploaded,
    };
}

fn renderSummary(
    allocator: std.mem.Allocator,
    smoke_status: SmokeStatus,
    native: NativeGlyphTextureSmokeResult,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-glyph-texture-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.print("source_rasterized={}\n", .{smoke_status.source_rasterized});
    try writer.print("metal_texture={}\n", .{smoke_status.metal_texture});
    try writer.print("glyph_texture_uploaded={}\n", .{smoke_status.glyph_texture_uploaded});
    try writer.writeAll("glyph_text=false\n");
    try writer.writeAll("ui_note=coretext_cpu_bitmap_to_metal_texture_no_window_no_text_draw\n");
    try writer.print("native_status={d}\n", .{native.status});
    try writer.print("metal_device_created={d}\n", .{native.metal_device_created});
    try writer.print("command_queue_created={d}\n", .{native.command_queue_created});
    try writer.print("native_source_rasterized={d}\n", .{native.source_rasterized});
    try writer.print("texture_created={d}\n", .{native.texture_created});
    try writer.print("texture_uploaded={d}\n", .{native.texture_uploaded});
    try writer.print("texture_readback={d}\n", .{native.texture_readback});
    try writer.print("source_width={d}\n", .{native.source_width});
    try writer.print("source_height={d}\n", .{native.source_height});
    try writer.print("source_non_clear_pixels={d}\n", .{native.source_non_clear_pixels});
    try writer.print("texture_non_clear_pixels={d}\n", .{native.texture_non_clear_pixels});
    try writer.print("texture_mismatched_pixels={d}\n", .{native.texture_mismatched_pixels});
    try writer.print("upload_bytes={d}\n", .{native.upload_bytes});
    try writer.print("readback_failures={d}\n", .{native.readback_failures});

    return output.toOwnedSlice();
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/glyph-texture.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test "macOS glyph texture smoke summary reports upload boundary" {
    // native Metal을 호출하지 않는 계약 테스트에서도 summary 의미를 고정한다.
    // 그래야 texture upload 구현이 바뀌어도 artifact consumer가 무엇을 읽어야 하는지
    // 흔들리지 않는다.
    const native: NativeGlyphTextureSmokeResult = .{
        .status = 0,
        .metal_device_created = 1,
        .command_queue_created = 1,
        .source_rasterized = 1,
        .texture_created = 1,
        .texture_uploaded = 1,
        .texture_readback = 1,
        .source_width = 128,
        .source_height = 64,
        .source_non_clear_pixels = 77,
        .texture_non_clear_pixels = 77,
        .texture_mismatched_pixels = 0,
        .upload_bytes = 32768,
        .readback_failures = 0,
    };
    const summary = try renderSummary(std.testing.allocator, deriveSmokeStatus(native), native);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-glyph-texture-smoke.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "source_rasterized=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "metal_texture=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_texture_uploaded=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_text=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "source_non_clear_pixels=77\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "texture_non_clear_pixels=77\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "texture_mismatched_pixels=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "upload_bytes=32768\n") != null);
}

test "glyph texture upload requires readback to match the source bitmap" {
    // texture를 만들었다는 사실만으로는 glyph pixel이 제대로 올라갔다고 말할 수 없다.
    // readback 결과가 source bitmap의 non-clear 픽셀 수와 byte 내용까지 맞아야 한다.
    var partial = emptyNativeResult();
    partial.status = 0;
    partial.metal_device_created = 1;
    partial.command_queue_created = 1;
    partial.source_rasterized = 1;
    partial.texture_created = 1;
    partial.texture_uploaded = 1;
    partial.texture_readback = 1;
    partial.source_width = 128;
    partial.source_height = 64;
    partial.source_non_clear_pixels = 77;
    partial.texture_non_clear_pixels = 76;
    partial.texture_mismatched_pixels = 0;
    partial.upload_bytes = 32768;
    try std.testing.expect(!deriveSmokeStatus(partial).glyph_texture_uploaded);

    var mismatch = partial;
    mismatch.texture_non_clear_pixels = 77;
    mismatch.texture_mismatched_pixels = 1;
    try std.testing.expect(!deriveSmokeStatus(mismatch).glyph_texture_uploaded);

    var success = mismatch;
    success.texture_mismatched_pixels = 0;
    try std.testing.expect(deriveSmokeStatus(success).glyph_texture_uploaded);
}
