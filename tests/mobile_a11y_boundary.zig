const std = @import("std");

// 접근성 어댑터(M9 둘째 슬라이스)의 결정들을 **구조로** 못 박는다.
//
// **왜 텍스트 판정자인가.** 이 축의 증상은 `UIAccessibility` 안에서만 난다 — CI 에는 시뮬레이터도
// 스크린 리더도 없다. 그래서 여기서 세는 것은 「스크린 리더가 읽는가」가 아니라 **「그 결정이
// 아직 코드에 있는가」**다. 실제 트리는 시뮬레이터에서 `idb ui describe-all` 로 읽어 대조했고
// (2026-09-06: 터미널 15개 → 목록 0개 → 돌아오면 다시 15개), 그때 본 것을 이 판정자가 지킨다.

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

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// **주석 줄은 빼고** 센다. 「Zig 에 플랫폼 어휘가 없다」는 성질은 *코드*에 대한 것이지, 그 이름을
/// 입에 올리지 말라는 뜻이 아니다 — 어댑터가 무엇으로 투영하는지는 주석이 적어야 할 바로 그
/// 내용이다(처음에 통째로 세어 붉었고, 그것은 판정자가 틀린 것이었다).
fn countCode(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, haystack, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        n += std.mem.count(u8, line, needle);
    }
    return n;
}

test "a11y 경계: wire 번호의 단일 출처는 헤더다" {
    // 브리지는 계약 enum(`chrome/ui/semantics.zig` 의 `Role`)의 **순번을 그대로 내보내지 않는다**.
    // 그러면 그 enum 에 줄을 하나 끼워 넣는 순간 host 가 조용히 다른 역할을 읽는다 — 화면에는
    // 아무 표시가 없고 스크린 리더만 「버튼」을 「목록 줄」로 읽는다.
    const allocator = std.testing.allocator;
    const header = try readSource(allocator, "src/platform/mobile/mobile_host_abi.h");
    defer allocator.free(header);
    const bridge = try readSource(allocator, "src/platform/mobile/mobile_bridge.zig");
    defer allocator.free(bridge);

    const roles = [_]struct { c: []const u8, zig: []const u8 }{
        .{ .c = "MARU_MOBILE_A11Y_ROLE_BUTTON = 0", .zig = "    button = 0," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_TREE_ITEM = 1", .zig = "    tree_item = 1," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_LIST_ITEM = 2", .zig = "    list_item = 2," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_TAB = 3", .zig = "    tab = 3," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_SCROLL_VIEW = 4", .zig = "    scroll_view = 4," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_TEXT = 5", .zig = "    text = 5," },
        .{ .c = "MARU_MOBILE_A11Y_ROLE_GROUP = 6", .zig = "    group = 6," },
    };
    for (roles) |r| {
        try std.testing.expectEqual(@as(usize, 1), count(header, r.c));
        try std.testing.expectEqual(@as(usize, 1), count(bridge, r.zig));
    }
    // 상태 비트도 같은 규율이다 — host 가 `1 << 3` 을 직접 적으면 「펼침 개념」과 「펼침 값」이
    // 갈린 이유가 사라진다.
    try std.testing.expectEqual(@as(usize, 1), count(header, "MARU_MOBILE_A11Y_STATE_ENABLED = 1u << 0"));
    try std.testing.expectEqual(@as(usize, 1), count(header, "MARU_MOBILE_A11Y_STATE_EXPANDABLE = 1u << 3"));

    // 그리고 **순번을 그대로 내보내던 옛 코드가 돌아오면** 안 된다.
    try std.testing.expectEqual(@as(usize, 0), count(bridge, "@intFromEnum(a11y_nodes[index].sem.role)"));
}

test "a11y 경계: iOS 어댑터는 요소를 «들고 있는다»" {
    // 질의마다 새로 만들면 iOS 가 index 별로 물을 때 앞서 준 요소가 배열과 함께 사라진다 —
    // 실측(`idb ui describe-all`): 열다섯 중 **마지막 하나만** 이름과 자리가 있었고 나머지 열넷은
    // 이름 `null` 에 크기 0 인 빈 그룹이었다. 눈으로는 안 보이고 스크린 리더에게만 보이는 결함이다.
    const allocator = std.testing.allocator;
    const host = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(host);

    try std.testing.expect(count(host, "_a11yElements") >= 4);
    // 만드는 자리는 **둘뿐**이다: 처음 물었을 때와, 지문이 바뀌었을 때.
    try std.testing.expectEqual(@as(usize, 2), count(host, "[self buildAccessibilityElements]"));

    // **그런데 개수만 세면 못 잡는다.** 「질의마다 새로 만든다」로 되돌리는 변이를 넣었더니 호출
    // 자리는 여전히 둘이라 위 줄이 그대로 초록이었다(적대적 변이가 그 구멍을 드러냈다). 그래서
    // **묻는 자리가 무엇을 답하는지**를 본다 — 들고 있는 것을 답해야 하고, 만드는 것은 처음 한 번뿐이다.
    const getter = "- (NSArray *)accessibilityElements {";
    const at = std.mem.indexOf(u8, host, getter) orelse return error.MissingGetter;
    const body_end = std.mem.indexOf(u8, host[at..], "\n}") orelse return error.MissingGetterEnd;
    const body = host[at .. at + body_end];
    try std.testing.expectEqual(@as(usize, 1), count(body, "return _a11yElements;"));
    try std.testing.expectEqual(@as(usize, 1), count(body, "if (_a11yElements == nil)"));

    // **알리지 않으면 커서가 옛 버튼에 남는다.**
    try std.testing.expectEqual(@as(usize, 1), count(host, "UIAccessibilityLayoutChangedNotification"));

    // 그 견주기는 **M14 조기 return 앞**에 있어야 한다 — 뒤에 두면 화면이 멈춘 프레임에서
    // 알림이 안 나간다(그리고 화면이 멈추는 것은 흔한 일이다).
    const note = std.mem.indexOf(u8, host, "[self noteAccessibilityChange]") orelse return error.MissingCall;
    const idle = std.mem.indexOf(u8, host, "if (!maru_mobile_frame_changed()") orelse return error.MissingIdleGate;
    try std.testing.expect(note < idle);
}

test "a11y 경계: 어휘는 host 에만, 좌표는 누르는 쪽과 같은 식으로" {
    const allocator = std.testing.allocator;
    const bridge = try readSource(allocator, "src/platform/mobile/mobile_bridge.zig");
    defer allocator.free(bridge);
    const host = try readSource(allocator, "src/platform/ios/ios_app_host.m");
    defer allocator.free(host);

    // **Zig 에는 플랫폼 접근성 어휘가 0 건이다**(계약 §3 — 의미는 코어가, 어휘는 host 가).
    // 데스크톱 경계 판정자가 지키는 그 성질을 모바일에서도 지킨다.
    try std.testing.expectEqual(@as(usize, 0), countCode(bridge, "UIAccessibility"));
    try std.testing.expectEqual(@as(usize, 0), countCode(bridge, "AccessibilityNodeInfo"));

    // 번역은 **한 함수 안에서만** 한다 — 두 곳에서 하면 역할이 조용히 갈린다.
    try std.testing.expectEqual(@as(usize, 1), count(host, "static UIAccessibilityTraits maruA11yTraits"));
    try std.testing.expectEqual(@as(usize, 1), count(host, "e.accessibilityTraits = maruA11yTraits("));

    // 브리지 좌표는 safe area 를 뺀 자리다. 읽는 자리도 **누르는 자리와 같은 식으로** 되돌린다 —
    // 한쪽만 고치면 스크린 리더가 짚는 곳이 손가락이 닿는 곳에서 노치만큼 어긋난다.
    try std.testing.expectEqual(@as(usize, 1), count(host, "CGRectMake(x + safe.left, y + safe.top, w, h)"));
    try std.testing.expect(count(host, "p.x - safe.left") >= 1);
}
