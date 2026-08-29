//! P3-e4d-4의 제품 경계를 소스 수준에서 고정한다.
//!
//! attach 단위 테스트나 control-path 해시 비교만으로는 AppSession 재접속 뒤 실제 업로드와 runtime 격리를
//! 증명하지 못한다. 공개 recovery·drop/paste 진입점과 실제 비대칭 SSH 실패 오라클을 한 테스트가 소유해야 한다.

const std = @import("std");

test "P3-e4d-4 reconnect upload uses public recovery and asymmetric ControlMaster isolation" {
    const allocator = std.testing.allocator;
    const body = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/app_session.zig",
        allocator,
        .limited(16 * 1024 * 1024),
    );
    defer allocator.free(body);

    const marker = "test \"P3-e4d-4 reconnected destinations and ControlMasters stay isolated\"";
    const start = std.mem.indexOf(u8, body, marker) orelse return error.ProductTestMissing;
    const tail = body[start..];
    const end = std.mem.indexOfPos(u8, tail, marker.len, "\ntest \"") orelse tail.len;
    const test_body = tail[0..end];

    try std.testing.expect(std.mem.indexOf(u8, test_body, "activateNotificationRuntime") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, ".adopt_recovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "handleDroppedFiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "handleDroppedImage") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "MARU_P5D_UPLOAD_DEST_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "MARU_P5D_UPLOAD_DEST_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "MARU_P5D_UPLOAD_CLIENT_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "controlSocketPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "app_file_send_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "total_terminal_input_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "runtime.writeInput") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "ssh_remote_dest_present =") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "restore_runtime_host_id =") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "restore_runtime_id =") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "attachExistingRuntimeInNewTab") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "applyUserAction(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "pumpUserActions(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "drainUploadResults(") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_body, "startUploadBytes(") == null);
}
