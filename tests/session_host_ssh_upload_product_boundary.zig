//! P3-e4d-3의 제품 경계를 소스 수준에서 고정한다.
//!
//! localhost SSH primitive만 통과해도 제품의 freshness queue나 원래 surface routing이 끊길 수 있다.
//! 따라서 실제 AppSession test가 공개 drop/image 진입점에서 시작하고 private shortcut을 쓰지 않는지 본다.

const std = @import("std");

test "P3-e4d-3 host-backed SSH upload uses actual AppSession product boundaries" {
    const allocator = std.testing.allocator;
    const body = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/app_session.zig",
        allocator,
        .limited(16 * 1024 * 1024),
    );
    defer allocator.free(body);

    const marker = "test \"P3-e4d-3 actual host-backed file and image uploads reach original surface\"";
    const start = std.mem.indexOf(u8, body, marker) orelse return error.ProductTestMissing;
    const tail = body[start..];
    const end = std.mem.indexOfPos(u8, tail, marker.len, "\ntest \"") orelse tail.len;
    const test_body = tail[0..end];

    try std.testing.expect(std.mem.indexOf(u8, test_body, "handleDroppedFiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "handleDroppedImage") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "session.tick()") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "runtime.writeInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "MARU_P5D_UPLOAD_FAILURE_DEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "app_image_send_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "app_file_send_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "total_terminal_input_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "ssh_remote_dest_present =") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "ssh_remote_dest.appendSlice") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "applyUserAction(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "pumpUserActions(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "drainUploadResults(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "startUpload(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "startUploadBytes(") == null);
}
