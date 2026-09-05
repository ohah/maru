const std = @import("std");

// 회전(M5 첫 슬라이스)의 결정 셋을 **구조로** 못 박는다.
//
// **왜 텍스트 판정자인가.** 이 축의 증상은 스왑체인 기하 — Vulkan 서페이스가 있어야 나온다.
// CI 에는 GPU 도 창도 없으니 헤드리스로는 한 줄도 못 돈다. 그래서 여기서 세는 것은 「그렇게
// 그려지는가」가 아니라 **「그 결정이 아직 코드에 있는가」**다. 실제 그림은 에뮬레이터에서
// 눈으로 봤고(2026-09-05), 그때 본 것을 지우는 손을 이 판정자가 막는다.
//
// 셋 다 **한 번씩 실기에서 깨진 모습을 봤다.**

test "회전 경계: preTransform 을 currentTransform 으로 되돌리지 않는다" {
    // `preTransform` 은 「내가 이 회전을 **이미** 적용해 그린다」는 선언이다. 우리는 안 돌리고
    // 그리므로 화면이 90° 돌았을 때 그대로 주면 **그림이 옆으로 눕는다**(실측: 세로 크기 그대로
    // 좌상단에 누운 채, 나머지는 검정).
    const allocator = std.testing.allocator;
    const host = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(host);

    try std.testing.expectEqual(@as(usize, 0), count(host, ".preTransform = caps.currentTransform"));
    try std.testing.expectEqual(@as(usize, 1), count(host, ".preTransform = want_transform"));
    // IDENTITY 를 «쓸 수 있을 때만» 쓴다 — 못 쓰는 드라이버에서는 예전 값으로 돌아가야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(host, "VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) != 0"));
    try std.testing.expect(count(host, "identity_ok") >= 2);
}

test "회전 경계: SUBOPTIMAL 은 재생성 사유가 아니다" {
    // IDENTITY 를 일부러 요청하므로 서페이스의 `currentTransform` 과 **영구히** 어긋난다.
    // 드라이버는 그것을 매 프레임 `SUBOPTIMAL` 로 말하는데, 그걸 재생성으로 받으면 스왑체인을
    // 쉬지 않고 다시 만든다(실측 2026-09-05: 5초에 95회).
    const allocator = std.testing.allocator;
    const host = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(host);

    try std.testing.expectEqual(@as(usize, 0), count(host, "VK_SUBOPTIMAL_KHR"));
    // 대신 **진짜** 리사이즈를 잡는 자리는 남아 있어야 한다 — 이게 없으면 회전해도 격자를
    // 다시 안 잡는다(그리고 `OUT_OF_DATE` 를 안 주는 드라이버에서는 화면이 통째로 언다).
    try std.testing.expectEqual(@as(usize, 1), count(host, "VK_ERROR_OUT_OF_DATE_KHR) {"));
    try std.testing.expect(count(host, "ANativeWindow_getWidth") >= 2);
}

test "회전 경계: 스왑체인 크기와 리사이즈 검사는 «같은 곳»에서 온다" {
    // 둘이 다른 값을 보면 매 프레임 「크기가 다르다 → 재생성」이 돌아 화면이 멈춘다. 그래서
    // 만들 때도 검사할 때도 `ANativeWindow` 를 본다 — `caps.currentExtent` 는 회전 시 어느
    // 공간으로 오는지 드라이버마다 갈려서(실측: 이 에뮬레이터는 스펙과 달리 안 뒤바꿔 줬다)
    // **최후의 폴백**으로만 남긴다.
    const allocator = std.testing.allocator;
    const host = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(host);

    const from_caps = std.mem.indexOf(u8, host, "g.extent = caps.currentExtent;") orelse
        return error.FallbackMissing;
    const from_window = std.mem.indexOf(u8, host, "g.extent = (VkExtent2D){.width = ww, .height = wh}") orelse
        return error.WindowExtentMissing;
    // 창에서 온 값이 **나중에** 덮어써야 그것이 이긴다.
    try std.testing.expect(from_window > from_caps);

    // iOS 에는 이 축의 결함이 **구조적으로 없다** — 캐시한 크기가 없고 매 tick `self.bounds` 를
    // 다시 읽는다. 그 성질이 사라지면(크기를 캐시하기 시작하면) 여기서 알린다.
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    try std.testing.expect(count(ios, "self.bounds.size.width") >= 2);
    try std.testing.expectEqual(@as(usize, 0), count(ios, "g_extent"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
