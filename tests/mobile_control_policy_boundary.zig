const std = @import("std");

// 컨트롤 축의 **정책이 코어에 있다**는 것을 «구조로» 못 박는다.
//
// **왜 있나.** 순서·가드·분류·마감이 두 host 의 C/ObjC tick 안에 있었고, 그래서 iOS 가 열기를
// 닫기보다 먼저 해 「열고 그 자리에서 닫기」를 무한히 되풀이했다 — 컨트롤 채널이 opening↔closed
// 로 진동하고 아무 세션도 안 떴는데 **판정자는 내내 초록이었다**(실기 2026-09-04). 그 정책을
// `mobile_bridge.zig` 로 올렸으니, 다시 host 로 새는 것을 여기서 막는다.
//
// 값 판정(순서·마감이 실제로 그렇게 도는가)은 `mobile_bridge_contract.zig` 의 「정책:」 판정자가
// 한다. **여기가 세는 것은 «자리»** 다.

test "정책 경계: 두 host 는 행동을 «받아서 실행만» 한다 — 순서를 스스로 정하지 않는다" {
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);

    for ([_][]const u8{ ios, android }) |host| {
        // 행동을 묻는 자리는 **한 곳**이다. 둘이 되면 한 tick 에 두 행동이 나갈 수 있다.
        try std.testing.expectEqual(@as(usize, 1), count(host, "maru_mobile_control_tick("));
        // 열기 결과의 분류도 코어가 한다 — host 는 「포기했나」만 보고 찍는다.
        try std.testing.expectEqual(@as(usize, 1), count(host, "maru_mobile_control_note_open("));

        // **host 가 순서를 정하던 자리들이 없어야 한다.** 하나라도 살아 있으면 그 tick 이
        // 코어가 정한 행동 말고 제 판단으로 움직인다는 뜻이다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_take_control_open"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_take_control_close"));
        // 마감을 host 가 세던 자리(시계 전역 + 5초 상수)도 없어야 한다 — 그것이 있으면 헤드리스
        // 판정자가 시간을 못 넣어 그 갈래가 통째로 안 덮인다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "> 5000"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_control_open_retry"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "maru_mobile_control_timeout"));
        // `MARU_SSH_ERR_NOT_READY` 분류도 코어 것이다.
        try std.testing.expectEqual(@as(usize, 0), count(host, "MARU_SSH_ERR_NOT_READY"));
    }
}

test "정책 경계: 가용 논리 크기는 코어가 «한 번만» 계산한다" {
    // 「키보드가 하단 inset 을 덮으니 두 번 빼지 않는다」가 예전에는 **세 자리**에 있었다 —
    // iOS 의 ObjC, Android 의 Java `ImeInsets`, 그리고 각자의 뺄셈. 같은 사실이 흩어지면
    // 한쪽만 고쳐지고, 이 축의 증상(키보드 위 빈 띠)은 눈으로 잘 안 갈린다.
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);
    const java = try readSource(allocator, "src/platform/android/MaruActivity.java");
    defer allocator.free(java);

    for ([_][]const u8{ ios, android }) |host| {
        // 계산은 코어에 묻는다 — 두 host 에 각각 한 번.
        try std.testing.expectEqual(@as(usize, 1), count(host, "maru_mobile_available_logical("));
    }
    // **host 가 직접 빼던 자리가 없어야 한다.**
    try std.testing.expectEqual(@as(usize, 0), count(ios, "safe.bottom ?"));
    try std.testing.expectEqual(@as(usize, 0), count(android, "avail_px"));
    // Java 도 미리 접지 않는다 — `ime` 를 그대로 넘긴다.
    try std.testing.expectEqual(@as(usize, 0), count(java, "ime > nav"));
    try std.testing.expectEqual(@as(usize, 1), count(java, "Type.ime()).bottom)"));
}

test "정책 경계: 코어가 베낀 ABI 상수는 헤더와 같은 값이다" {
    // 브리지는 `MARU_SSH_CONTROL_*` 와 `MARU_SSH_ERR_NOT_READY` 를 **값으로** 안다(Zig 는 그
    // 헤더를 안 읽는다). 갈리면 정책이 조용히 틀린 상태를 보고, 증상은 「세션이 안 열린다」다 —
    // 이 축이 이미 그 모양으로 한 번 죽었다. 그래서 **헤더 원문과 대조한다.**
    const allocator = std.testing.allocator;
    const header = try readSource(allocator, "src/platform/mobile/mobile_host_abi.h");
    defer allocator.free(header);
    const bridge = try readSource(allocator, "src/platform/mobile/mobile_bridge.zig");
    defer allocator.free(bridge);

    try expectPair(header, bridge, "#define MARU_SSH_CONTROL_NONE ", "const ssh_control_none: u32 = ");
    try expectPair(header, bridge, "#define MARU_SSH_CONTROL_CLOSED ", "const ssh_control_closed: u32 = ");
    try expectPair(header, bridge, "#define MARU_SSH_ERR_NOT_READY ", "const ssh_err_not_ready: c_int = ");

    // 행동 상수도 두 자리에 산다(헤더의 `#define` 과 Zig 의 `enum`). 그 셋이 짝이어야 host 의
    // `switch` 가 코어의 뜻과 같은 것을 가리킨다.
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_NONE 0"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_CLOSE 1"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_MOBILE_CONTROL_ACTION_OPEN 2"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "none = 0,"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "close = 1,"));
    try std.testing.expectEqual(@as(usize, 1), count(bridge, "open = 2,"));
}

test "정책 경계: 굽는 셀은 코어가 정하고, 다시 굽기는 «build 앞» 이다" {
    // **셀 크기는 정책이다.** 상수로 구우면 그 그림을 늘려 써서 흐려진다(실측: 22px 를 62px
    // 자리에). 그 판단이 host 로 새면 두 플랫폼이 서로 다른 크기로 굽고, 픽셀 대조가 조용히
    // 무의미해진다 — 예전에 네 자리에 흩어져 있던 그 상수다.
    //
    // **그리고 순서가 정책의 일부다.** 다시 구우면 텍스처를 새로 만들어 자라난 글자(한글·이모지)
    // 그림이 사라지는데, 등록부를 비우는 것은 `maru_mobile_build` 안이다. build **뒤에** 구우면
    // 그 프레임은 「등록은 있는데 그림은 없는」 칸을 그린다 — 한글이 한 프레임 빈칸으로 뜬다.
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);
    const header = try readSource(allocator, "src/platform/mobile/mobile_host_abi.h");
    defer allocator.free(header);

    // **옛 상수는 «지웠다».** 남겨 두면 굽는 자리가 다시 그것을 집는다 — 그 실수를 판정자로
    // 막는 것보다 심볼 자체를 없애는 편이 세다(그러면 컴파일이 안 된다).
    try std.testing.expectEqual(@as(usize, 0), count(header, "#define MARU_ATLAS_CELL_W"));
    try std.testing.expectEqual(@as(usize, 0), count(header, "#define MARU_ATLAS_CELL_H "));
    try std.testing.expectEqual(@as(usize, 1), count(header, "#define MARU_ATLAS_CELL_MAX "));

    for ([_][]const u8{ ios, android }) |host| {
        // **크기는 코어에 묻는다.**
        try std.testing.expect(count(host, "maru_mobile_atlas_cell_h()") > 0);
        // **그리는 배율을 알린다.** 안 알리면 코어가 1배로 알고 작게 굽는다(그 결함으로 한 바퀴 돌았다).
        // 횟수는 안 고정한다 — Android 는 굽기 앞(한 번)과 프레임마다(배율이 바뀔 수 있다) 둘이다.
        try std.testing.expect(count(host, "maru_mobile_set_render_scale(") > 0);

        // **여백·베이스라인은 «옛 크기에서 옛 값» 을 재현해야 한다.** 상수로 두면 셀이 커졌을 때
        // 글자가 바닥에 붙어 위가 잘리고, 비율을 잘못 적으면 옛 크기에서 자리가 밀린다 —
        // `CW / 24 + 1` 로 적었다가 CW=24 에서 1 이 아니라 2 가 돼 1px 밀린 것을 잡았다.
        // (0 이 될까 걱정한 것인데, 셀 하한 32 가 CW 를 24 아래로 못 내리므로 필요 없다.)
        try std.testing.expectEqual(@as(usize, 0), count(host, "CW / 24 + 1"));
        try std.testing.expect(count(host, "CW / 24") >= 3);
        try std.testing.expectEqual(@as(usize, 0), count(host, "CH - 8"));
    }

    // iOS 는 첫 굽기가 프레임보다 앞서 **다시** 굽는다 — 그 자리가 `build` 앞이어야 한다.
    try expectPrecedesInSameBody(ios, "!= _bakedCellH", "maru_mobile_build(");

    // Android 는 배율을 먼저 알므로 **첫 굽기 앞에서** 알린다.
    try expectPrecedesInSameBody(android, "maru_mobile_set_render_scale(", "!g_glyph_px && !rasterizeAtlasOnDevice(");
    // 그리고 **다시 굽는 것도 `build` 앞이다**(M13b) — iOS 와 같은 규율이다.
    try expectPrecedesInSameBody(android, "rebakeAtlas(g_app)", "maru_mobile_build(");

    // **「다시 그려라」는 host 가 정하지 않는다.** 격자가 바뀐 프레임을 「바뀐 프레임」으로 세는
    // 것은 코어의 판단이다(`maru_mobile_atlas_geometry`) — host 가 각자 프레임 카운터를 되돌리면
    // 두 플랫폼이 갈리고, 그 되돌림이 페이싱 측정·첫 프레임 로그까지 건드린다.
    try expectAbsentFromBody(android, "static void rebakeAtlas(", "g.frames = 0");

    // **자라는 글자는 «서 있는 텍스처의 격자» 에 굽는다 — 코어가 원하는 크기가 아니라.**
    // 코어는 설정·배율이 바뀌면 곧바로 새 크기를 답하는데, 텍스처는 다시 굽기 전까지 옛 격자다.
    // 그 답으로 슬롯을 계산하면 Android 는 `vkCmdCopyBufferToImage` 가, iOS 는 `replaceRegion:`
    // 이 이미지 밖을 가리킨다 — Android 는 다시 굽는 길이 아예 없어 `font.size` 만 키워도 그렇게
    // 되고, iOS 는 다시 굽기가 실패한 프레임이 그 경우다. 적대적 검증에서 잡았다.
    try expectAbsentFromBody(ios, "- (void)growAtlas {", "maru_mobile_atlas_cell_");
    try expectAbsentFromBody(ios, "- (BOOL)bakeColorGlyph:", "maru_mobile_atlas_cell_");
    try expectAbsentFromBody(android, "static void growAtlas(", "maru_mobile_atlas_cell_");

    // **다시 굽는 자리는 옛 폰트를 놓아야 한다.** 이 메서드는 이제 한 번만 도는 게 아니다 —
    // 셀이 바뀌면 다시 돈다. 안 놓으면 다시 구울 때마다 CTFont 다섯이 샌다(적대적 검증에서 잡았다).
    try std.testing.expectEqual(@as(usize, 1), count(ios, "if (_atlasFont) CFRelease(_atlasFont);"));
    try std.testing.expectEqual(@as(usize, 1), count(ios, "if (_atlasFaces[s]) CFRelease(_atlasFaces[s]);"));
}

/// `signature` 로 시작하는 함수 몸통 안에 `needle` 이 **없어야** 한다.
/// 몸통은 그 자리부터 열 0 의 `}` 까지다(두 host 의 코드 스타일이 그렇다).
///
/// **정의만 본다 — 선언은 건너뛴다.** 처음에 첫 자리를 그냥 썼다가, Android 의 앞선 프로토타입
/// (`static void growAtlas(struct android_app *app);`)에 걸려 엉뚱한 몸통을 재고 변이가 초록으로
/// 빠져나갔다. 그 줄에 `{` 가 있어야 정의다.
fn expectAbsentFromBody(src: []const u8, signature: []const u8, needle: []const u8) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, signature)) |at| {
        from = at + signature.len;
        const line_end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
        if (std.mem.indexOfScalar(u8, src[at..line_end], '{') == null) continue; // 선언이다
        const rest = src[at..];
        const end = std.mem.indexOf(u8, rest, "\n}\n") orelse rest.len;
        if (std.mem.indexOf(u8, rest[0..end], needle) != null) return error.NeedleInBody;
        return;
    }
    return error.DefinitionMissing;
}

/// `later` 바로 앞에 `earlier` 가 **같은 함수 안에** 있는가.
///
/// **파일 위치만 견주면 아무것도 안 잰다.** 처음에 그렇게 썼다가, Android 에서 굽기 앞의
/// `set_render_scale` 을 통째로 지우는 변이가 **초록으로 빠져나갔다** — 같은 이름이 파일 앞쪽
/// 다른 함수(`drawFrame`)에도 있어서 첫 자리가 우연히 앞이었다. 그래서 `later` 에서 **거꾸로**
/// 가장 가까운 `earlier` 를 찾고, 그 사이에 함수가 끝나는 자리(열 0 의 `}`)가 없어야 한다.
fn expectPrecedesInSameBody(src: []const u8, earlier: []const u8, later: []const u8) !void {
    const later_at = std.mem.indexOf(u8, src, later) orelse return error.LaterMissing;
    const at = std.mem.lastIndexOf(u8, src[0..later_at], earlier) orelse return error.EarlierMissing;
    if (std.mem.indexOf(u8, src[at..later_at], "\n}\n") != null) return error.NotInSameBody;
}

/// 헤더의 `#define <name> <v>` 와 Zig 의 `const <name>: T = <v>` 가 같은 값인가.
/// **괄호는 벗긴다** — C 는 음수를 `(-7)` 로 적는다.
fn expectPair(header: []const u8, bridge: []const u8, c_prefix: []const u8, zig_prefix: []const u8) !void {
    const c_val = try valueAfter(header, c_prefix);
    const zig_val = try valueAfter(bridge, zig_prefix);
    try std.testing.expectEqualStrings(std.mem.trim(u8, c_val, "()"), std.mem.trim(u8, zig_val, "();"));
}

/// `prefix` 뒤 그 줄의 나머지(공백 제거). 없으면 **오류** — 조용히 통과하지 않는다.
fn valueAfter(haystack: []const u8, prefix: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, haystack, prefix) orelse return error.PrefixMissing;
    const rest = haystack[at + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t\r");
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
