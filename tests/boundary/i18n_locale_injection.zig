// 이 테스트는 **"세션을 만들기 전에 로케일을 넘긴다"** 는 규칙을 강제한다(docs/i18n.md §5.1).
//
// **무엇을 증명하나.** `ui.language` 의 기본값은 `auto` 이고, 그 판정은 platform 이 넘긴 OS 로케일
// 문자열에 달려 있다. 세션은 `init` 에서 config 를 읽으며 언어를 정하므로, **그 전에** 로케일이 들어와야
// 한다. 안 들어오면 `auto` 는 조용히 영어로 떨어진다 — 크래시도 경고도 없이 **화면 언어만 틀린다.**
//
// **왜 게이트가 필요한가 — 실제로 한 번 틀렸다.** I4a 를 붙일 때 Swift 의 세션 생성 호출부가 하나뿐인 줄
// 알고 거기에만 `publishUiLocale()` 을 넣었는데, 적대적 검증에서 **두 번째 경로**(quick 패널)가 나왔다.
// 그 경로로 먼저 뜬 창은 로케일 없이 언어를 정한다. 이 종류의 실수는 컴파일러가 못 잡고 테스트도
// 못 잡는다(둘 다 영어로 잘 동작한다). 새 생성 경로가 생길 때마다 같은 실수가 가능하므로 소스 스캔으로
// 닫는다 — `cli_purity.zig`·`cwd_axis.zig` 와 같은 결이다.
//
// **규칙**: `MaruAppHost.swift` 안에서 `maru_macos_app_session_create(` 호출 수와 `publishUiLocale()`
// 호출 수(정의 제외)가 **같아야 한다.**
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - **순서는 못 본다.** 두 호출이 같은 수만큼 있어도 `publishUiLocale()` 이 생성 *뒤* 에 오면 그 창은
//     여전히 로케일 없이 언어를 정한다. 개수만 세는 것은 "새 경로를 만들며 잊었다"를 잡기 위한 것이고,
//     순서를 소스 스캔으로 보려면 Swift 파서가 필요해 비용이 규칙 값어치를 넘는다.
//   - 다른 파일에서 세션을 만들면 못 본다(2026-08-17 기준 이 트리에는 `MaruAppHost.swift` 뿐이다).
//   - 주석이나 문자열 안의 같은 토큰도 센다. 그 경우 개수가 어긋나 **실패하는 쪽**으로 틀리므로
//     조용히 통과하지 않는다.
const std = @import("std");

const host_swift_path = "src/platform/macos/MaruAppHost.swift";

/// 겹치지 않게 부분 문자열을 센다.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

test "로케일 주입은 세션 생성 경로마다 있다 — auto 가 조용히 영어로 떨어지지 않게" {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        host_swift_path,
        std.testing.allocator,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(source);

    const creates = countOccurrences(source, "maru_macos_app_session_create(");
    const definitions = countOccurrences(source, "private func publishUiLocale()");
    const publishes = countOccurrences(source, "publishUiLocale()") - definitions;

    // 정의가 사라졌다면 규칙 자체가 무너진 것이라 개수 비교가 무의미하다 — 먼저 못 박는다.
    try std.testing.expectEqual(@as(usize, 1), definitions);

    // 세션을 만드는 자리가 없어졌다면 이 게이트는 아무것도 안 지키는 상태다. 0 을 통과시키면
    // "규칙이 지켜진다"와 "규칙이 볼 것이 없다"를 구분할 수 없어진다.
    try std.testing.expect(creates > 0);

    if (creates != publishes) {
        std.debug.print(
            \\
            \\{s}: 세션 생성 {d}곳, 로케일 주입 {d}곳 — 개수가 다르다.
            \\
            \\세션은 init 에서 config 를 읽으며 UI 언어를 정한다(ui.language 기본 auto → OS 로케일).
            \\그 전에 publishUiLocale() 이 없으면 그 경로로 뜬 창은 auto 가 영어로 떨어진다 —
            \\크래시도 경고도 없이 화면 언어만 틀린다. 새 생성 경로 바로 앞에 넣어라.
            \\단일 출처: docs/i18n.md §5.1.
            \\
        , .{ host_swift_path, creates, publishes });
        return error.LocaleInjectionMissing;
    }
}
