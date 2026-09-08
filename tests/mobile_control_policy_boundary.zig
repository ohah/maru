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

test "정책 경계: 시스템 글자 배율은 «실어 나르기만» 한다 (M13c)" {
    // **따라갈지도, 얼마까지 키울지도 코어가 든다.** host 가 그것을 알면 두 플랫폼이 갈리고,
    // 「iOS 는 따라가는데 Android 는 안 따라간다」 같은 결함이 화면으로만 드러난다.
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const java = try readSource(allocator, "src/platform/android/MaruActivity.java");
    defer allocator.free(java);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);
    const manifest = try readSource(allocator, "src/platform/android/AndroidManifest.xml");
    defer allocator.free(manifest);

    // 두 host 가 코어에 싣는다.
    try std.testing.expect(count(ios, "maru_mobile_set_system_font_scale(") > 0);
    try std.testing.expect(count(android, "maru_mobile_set_system_font_scale(") > 0);

    // **host 는 범위를 안 자른다.** 자르는 자리가 둘이 되면 두 플랫폼이 다른 상한을 갖는다.
    // 글자 세기로는 못 잡는다 — 「안 본다」고 적은 **주석**까지 세기 때문이다(그렇게 짰다가
    // 판정자가 자기 설명문에 걸렸다). 그러니 **어길 수 있는 자리**, 즉 그 함수 몸통을 본다.
    try expectAbsentFromBody(java, "private void applySystemFontScale() {", "Math.min");
    try expectAbsentFromBody(java, "private void applySystemFontScale() {", "Math.max");
    try expectAbsentFromBody(ios, "- (void)reportSystemFontScale {", "MIN(");
    try expectAbsentFromBody(ios, "- (void)reportSystemFontScale {", "MAX(");

    // **iOS 는 배율 표를 스스로 만들지 않는다.** 카테고리 이름에 붙은 실제 배율은 UIKit 이
    // 소유하고 iOS 판마다 바뀔 수 있다 — `UIFontMetrics` 에게 물어야 접근성 크기(AX1~AX5)까지
    // 한 자리에서 맞는다.
    try std.testing.expect(count(ios, "UIFontMetrics") > 0);
    try std.testing.expectEqual(@as(usize, 0), count(ios, "UIContentSizeCategoryAccessibility"));

    // **외관과 «따로» 본다.** 한 trait 변화에 둘 다 실려 오지 않는다 — 하나의 `if` 로 묶으면
    // 글자 크기만 바뀐 변화를 놓친다.
    // **콜백 몸통을 본다** — 글자 세기로는 못 잡는다. 이 이름은 위 `reportSystemFontScale` 의
    // 설명 주석에도 있어서, 콜백에서 통째로 지운 변이가 「어딘가 있다」로 초록이었다.
    try expectPresentInBody(ios, "- (void)traitCollectionDidChange:", "preferredContentSizeCategory");
    try expectPresentInBody(ios, "- (void)traitCollectionDidChange:", "reportSystemFontScale");
    try expectPresentInBody(ios, "- (void)didMoveToWindow {", "reportSystemFontScale");

    // **Android 는 재생성 말고 그 자리에서 받는다.** manifest 에 `fontScale` 이 없으면 액티비티가
    // 통째로 다시 서서 창·스왑체인·아틀라스가 전부 다시 만들어지고 화면이 한 번 끊긴다.
    try std.testing.expect(count(manifest, "uiMode|fontScale") > 0);

    // **두 자리 다 알려야 한다** — 뜬 채로 바뀌는 것(`onConfigurationChanged`)과 돌아오는 것
    // (`onResume`)은 다른 길이다. 「어딘가 한 번 부른다」로 재면 한쪽을 지워도 초록이다:
    // 실제로 `onConfigurationChanged` 쪽을 지운 변이가 순서 단언을 빠져나갔다(짝이 `onResume`
    // 에도 있어서 그쪽으로 맞아 버렸다).
    try expectPresentInBody(java, "public void onConfigurationChanged(", "applySystemFontScale();");
    try expectPresentInBody(java, "protected void onResume() {", "applySystemFontScale();");
    // **첫 굽기보다 먼저.** 네이티브 창은 `onCreate` 뒤에 서고 아틀라스도 거기서 처음 구워진다 —
    // 여기서 안 알리면 시작할 때 한 번 다시 굽게 되고, 큰 글씨를 쓰는 사람일수록 그 한 번이 보인다.
    try expectPresentInBody(java, "protected void onCreate(Bundle state) {", "applySystemFontScale();");
}

test "정책 경계: 새 출력 낭독은 host 가 «말하기만» 한다 (M9a)" {
    // **무엇을 언제 읽을지는 코어가 정한다.** host 가 그 판단을 나눠 가지면 두 플랫폼이 다른 때에
    // 다른 것을 읽고, 그 차이는 **소리로만 드러나** 화면으로는 영영 안 보인다.
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const java = try readSource(allocator, "src/platform/android/MaruActivity.java");
    defer allocator.free(java);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);

    // 두 host 가 코어에 묻고 그 답을 그대로 넘긴다.
    try std.testing.expectEqual(@as(usize, 1), count(ios, "maru_mobile_a11y_take_announcement("));
    try std.testing.expectEqual(@as(usize, 1), count(android, "maru_mobile_a11y_take_announcement("));
    try std.testing.expect(count(ios, "UIAccessibilityAnnouncementNotification") > 0);
    try std.testing.expect(count(java, "announceForAccessibility") > 0);

    // **정책이 host 로 새지 않았다.** 상한도 기다림도 「무엇을 읽을지」도 여기 있으면 안 된다.
    for ([_][]const u8{ ios, java, android }) |host| {
        try std.testing.expectEqual(@as(usize, 0), count(host, "too much"));
        try std.testing.expectEqual(@as(usize, 0), count(host, "출력이 많"));
    }
    try expectAbsentFromBody(android, "static void drainA11yAnnouncement(void) {", "for (");
    // **낭독기가 켜졌는지도 host 가 안 묻는다.** 두 OS 다 꺼져 있으면 no-op 이라 물을 필요가
    // 없는데, 한쪽만 물으면 「iOS 만 안 읽는다」 같은 결함이 **소리로만** 드러난다.
    try std.testing.expectEqual(@as(usize, 0), count(ios, "UIAccessibilityIsVoiceOverRunning"));
    try std.testing.expectEqual(@as(usize, 0), count(java, "isTouchExplorationEnabled"));

    // **버퍼 상한이 두 곳에서 같아야 한다.** host 가 작게 잡으면 긴 낭독이 통째로 버려진다 —
    // 코어는 자리를 안 넘겨 자르지 않는다(문장 가운데서 끊긴 말을 읽느니 안 읽는 편이 낫다).
    // 그리고 host 는 **그 이름으로** 잡아야 한다: 숫자를 손으로 적으면 다음에 상한이 바뀔 때 갈린다.
    const header = try readSource(allocator, "src/platform/mobile/mobile_host_abi.h");
    defer allocator.free(header);
    const bridge = try readSource(allocator, "src/platform/mobile/mobile_bridge.zig");
    defer allocator.free(bridge);
    const cap = try valueAfter(header, "#define MARU_A11Y_ANNOUNCE_MAX ");
    const rows = try valueAfter(bridge, "const announce_row_cap = ");
    const per_row = try valueAfter(bridge, "const term_row_read_cap = ");
    const want = (try std.fmt.parseInt(usize, std.mem.trim(u8, rows, ";"), 10)) *
        (try std.fmt.parseInt(usize, std.mem.trim(u8, per_row, ";"), 10));
    try std.testing.expectEqual(want, try std.fmt.parseInt(usize, cap, 10));
    try std.testing.expect(count(ios, "MARU_A11Y_ANNOUNCE_MAX") > 0);
    try std.testing.expect(count(android, "MARU_A11Y_ANNOUNCE_MAX") > 0);
    try expectAbsentFromBody(java, "public static void a11yAnnounce(", "length()");

    // **절전 게이트 «앞» 이다.** 뒤에 두면 화면이 안 바뀐 프레임에서 말이 안 나가는데, 잠잠해졌다는
    // 판정이 곧 「읽을 때가 됐다」라서 하필 그 프레임이 절전에 걸려 영영 안 읽힌다.
    try expectPrecedesInSameBody(android, "drainA11yAnnouncement();", "if (!frame_changed && g.pace_done)");
}

test "정책 경계: 스크롤백 훑기도 host 가 «나르기만» 한다 (M9b)" {
    // **얼마나 미는지·언제 미는지는 코어가 정한다.** host 가 그 판단을 나눠 가지면 두 플랫폼이
    // 다른 때에 다른 만큼 움직이고, 그 차이는 낭독기를 켠 사람에게만 드러난다.
    const allocator = std.testing.allocator;
    const ios = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(ios);
    const java = try readSource(allocator, "src/platform/android/MaruActivity.java");
    defer allocator.free(java);
    const android = try readSource(allocator, "src/platform/android/android_app_host.c");
    defer allocator.free(android);

    // 두 길이 두 host 에 다 있다 — 한쪽만 있으면 그 플랫폼에서는 스크롤백에 못 닿는다.
    try std.testing.expect(count(ios, "accessibilityElementDidBecomeFocused") > 0);
    try std.testing.expect(count(ios, "accessibilityScroll:") > 0);
    try std.testing.expect(count(java, "nativeA11yFocus(") > 0);
    // **몸통을 본다 — 글자 세기로는 못 잡는다.** 같은 이름이 `performAction` 의 `switch` 에도
    // 있어서, 노드에 동작을 다는 줄을 통째로 지운 변이가 「어딘가 있다」로 초록이었다.
    try expectPresentInBody(java, "public AccessibilityNodeInfo createAccessibilityNodeInfo(", "ACTION_SCROLL_BACKWARD");
    try expectPresentInBody(java, "public AccessibilityNodeInfo createAccessibilityNodeInfo(", "ACTION_SCROLL_FORWARD");
    // **위·아래 둘 다** 코어에 넘긴다 — 하나만 넘기면 한쪽으로만 훑을 수 있다.
    try expectCountInBody(java, "public boolean performAction(", "nativeA11yScroll(", 2);

    // **「움직였나」를 그대로 돌려준다.** 삼키고 참을 답하면 낭독기가 끝에서 계속 「됐다」고 말해
    // 사용자가 갇힌다.
    try expectPresentInBody(ios, "- (BOOL)accessibilityScroll:", "return maru_mobile_a11y_scroll(");

    // **얼마나 미는지를 host 가 안 센다.** 화면 줄 수·스크롤백 길이를 여기서 세면 코어와 갈린다.
    try expectAbsentFromBody(ios, "- (BOOL)accessibilityScroll:", "maru_mobile_term_rows");
    try expectAbsentFromBody(ios, "- (void)accessibilityElementDidBecomeFocused {", "a11y_set_pos");
    try std.testing.expectEqual(@as(usize, 0), count(java, "maru_mobile_term_rows"));
    try std.testing.expectEqual(@as(usize, 0), count(java, "nativeScrollbackLen"));

    // **「갈 수 있나」도 코어가 답한다** — host 가 따로 세면 동작은 붙는데 눌러도 안 움직인다.
    // 여기도 몸통을 본다: 선언 줄이 따로 있어 이름만 세면 조건을 `true` 로 바꾼 변이가 빠져나간다.
    // **위·아래를 각각 묻는다.** 「있다」로 재면 하나를 `true` 로 바꾼 변이가 나머지에 걸려 통과한다.
    try expectCountInBody(java, "public AccessibilityNodeInfo createAccessibilityNodeInfo(", "nativeA11yCanScroll(", 2);
    // **갈 곳이 있을 때만 「스크롤되는 것」이라고 말한다** — 늘 참으로 두면 스크롤백이 없는
    // 화면에서도 TalkBack 이 그렇게 읽어 주고, 사용자는 있지도 않은 곳을 찾는다.
    try std.testing.expectEqual(@as(usize, 0), count(java, "setScrollable(true)"));
    try std.testing.expect(count(android, "maru_mobile_a11y_can_scroll(") > 0);

    // **초점이 우리 요소를 벗어난 것도 알린다** — 안 알리면 나중에 그 가장자리로 돌아왔을 때
    // 「다시 닿았다」로 보여 한 번 만에 밀린다.
    try expectPresentInBody(java, "public boolean performAction(", "nativeA11yFocus(nativeA11yCount())");
}

/// `signature` 로 여는 함수의 **몸통**. 없으면 오류다.
///
/// **정의만 본다 — 선언은 건너뛴다.** 처음에 첫 자리를 그냥 썼다가, Android 의 앞선 프로토타입
/// (`static void growAtlas(struct android_app *app);`)에 걸려 엉뚱한 몸통을 재고 변이가 초록으로
/// 빠져나갔다. 그 줄에 `{` 가 있어야 정의다.
///
/// **닫는 자리는 «서명의 들여쓰기» 로 찾는다.** 열 0 의 `}` 로 고정하면 Java 처럼 클래스 안에
/// 4칸 들여쓴 메서드에서 몸통이 파일 끝까지 늘어나 옆 메서드의 내용까지 보게 된다 — 그러면
/// 「이 콜백이 부르는가」가 「어딘가 부르는가」로 바뀌어 변이가 빠져나간다(실제로 겪었다).
fn bodyOf(src: []const u8, signature: []const u8) ![]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, signature)) |at| {
        from = at + signature.len;
        const line_end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
        if (std.mem.indexOfScalar(u8, src[at..line_end], '{') == null) continue; // 선언이다
        const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        var closer_buf: [34]u8 = undefined;
        const indent = at - line_start;
        if (indent + 3 > closer_buf.len) return error.IndentTooDeep;
        closer_buf[0] = '\n';
        @memset(closer_buf[1 .. 1 + indent], ' ');
        closer_buf[1 + indent] = '}';
        closer_buf[2 + indent] = '\n';
        const closer = closer_buf[0 .. 3 + indent];
        const rest = src[at..];
        const end = std.mem.indexOf(u8, rest, closer) orelse rest.len;
        return rest[0..end];
    }
    return error.DefinitionMissing;
}

/// 그 몸통 안에 `needle` 이 **있어야** 한다.
fn expectPresentInBody(src: []const u8, signature: []const u8, needle: []const u8) !void {
    const body = try bodyOf(src, signature);
    if (std.mem.indexOf(u8, body, needle) == null) return error.NeedleMissingFromBody;
}

/// 그 몸통 안에 `needle` 이 **몇 개** 있는가를 고정한다.
///
/// **「있다」로는 모자란 자리가 있다.** 위/아래처럼 짝으로 있어야 하는 것은 하나를 지워도 나머지가
/// 「있다」를 만족시켜 변이가 초록으로 빠져나간다 — 실제로 두 번 겪었다(스크롤 동작을 다는 자리,
/// 그것을 코어에 넘기는 자리).
fn expectCountInBody(src: []const u8, signature: []const u8, needle: []const u8, want: usize) !void {
    const body = try bodyOf(src, signature);
    try std.testing.expectEqual(want, count(body, needle));
}

/// 그 몸통 안에 `needle` 이 **없어야** 한다.
fn expectAbsentFromBody(src: []const u8, signature: []const u8, needle: []const u8) !void {
    const body = try bodyOf(src, signature);
    if (std.mem.indexOf(u8, body, needle) != null) return error.NeedleInBody;
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
