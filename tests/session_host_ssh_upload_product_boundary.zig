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

test "RA5 원격 이벤트 채널은 홈을 원격 셸이 펴게 둔다 — 작은따옴표는 $HOME 을 리터럴로 굳힌다" {
    // **한 글자 차이가 축 전체를 죽인다.** `--dir='$HOME/...'` 로 적으면 작은따옴표 안에서 `$HOME` 이
    // 확장되지 않아, 원격 maru 가 리터럴 `$HOME/...` 이라는 이름의 디렉터리를 열려다 실패한다. 증상은
    // «hello 가 안 온다» 하나뿐이고 그것은 «원격에 훅이 안 깔렸다» 와 화면에서 구분되지 않는다 —
    // 그래서 소스 수준에서 못박는다(이 실수를 실제로 한 번 했다).
    //
    // 인용을 아예 빼는 것도 답이 아니다: 홈에 공백이 있는 계정에서 원격 셸이 인자를 쪼갠다.
    const allocator = std.testing.allocator;
    const body = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/ssh_upload.zig",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(body);

    const start = std.mem.indexOf(u8, body, "pub fn spawnAgentEvents") orelse return error.SpawnMissing;
    const tail = body[start..];
    const end = std.mem.indexOfPos(u8, tail, 1, "\npub fn ") orelse tail.len;
    const fn_body = tail[0..end];

    // 큰따옴표로 감싼 `$HOME/` 이어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "--dir=\\\"$HOME/{s}\\\"") != null);
    // 그리고 작은따옴표 형태는 남아 있으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "--dir='") == null);
    // 받는 값이 **상대 경로**임을 이름으로도 못박는다 — 절대 경로를 넘기면 `$HOME` 이 앞에 또 붙는다.
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "remote_dir_rel") != null);

    // ⚠️ **스트리머도 PATH 를 앞에 붙여야 한다.** 설치만 고치고 여기를 빠뜨리면 «설치는 되는데
    // 스트리머가 안 뜨는» 상태가 되고, 증상은 앞의 실패와 구분되지 않는다(둘 다 「배지가 안 선다」).
    // 값은 설치와 **같은 상수**여야 한다 — 두 곳에 따로 적으면 한쪽만 고쳐진다.
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "remote_path_prefix") != null);
    // **한 문자열로 순서까지 함께 문다.** 따로 찾으면 위 문서 주석에 있는 `agent-events --stdio` 가
    // 먼저 걸려 «PATH 가 뒤에 있다» 고 잘못 읽는다(실제로 그렇게 한 번 빨갰다).
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "PATH=\\\"{s}:$PATH\\\"; exec {s} agent-events --stdio") != null);
}
