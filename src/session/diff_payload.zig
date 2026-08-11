//! `diff.open`이 웹으로 넘길 **본문 페이로드 정책**(L2 순수, docs/editor-surface-tooling.md §6, docs/editor-surface.md §10.6).
//!
//! 무엇을 실을지가 아니라 **무엇을 싣지 않을지**를 정하는 곳이다. diff 본문은 사용자가 고른 파일 하나지만 그 파일이
//! 100 MB일 수도, 실행 파일일 수도 있다. 그대로 브리지에 태우면 신뢰 shell이 그만큼을 문자열로 들고 CM6가 그것을
//! 파싱한다 — 화면에 못 그릴 것을 옮기느라 앱이 멎는다.
//!
//! 그래서 판정을 **바이트를 보기 전에 크기로**, 그리고 **내용을 보고 binary로** 두 번 한다. 둘 다 typed 결과로
//! 돌려주고(§6), 호출자는 그 사실을 화면에 말한다 — 잘린 내용을 정상인 척 보여 주지 않는다.

const std = @import("std");

/// 한쪽 문서의 바이트 상한. 양쪽 합이 아니라 **한쪽 기준**이다: 원본만 큰 경우(대용량 파일 삭제)와 수정본만
/// 큰 경우를 같은 규칙으로 거른다.
///
/// **8 MiB인 근거(2026-08-01 실측, 제품 WKWebView)**: 마운트 비용은 3.7 MB 238 ms · 7.4 MB 369 ms · 11 MB 514 ms로
/// 크기에 완만하게 붙는다. 1 MiB로 두면 이 저장소의 `app_session.zig`(4.0 MB)조차 못 여는데, 그건 상한이 지키려던
/// "화면에 못 그릴 것을 옮기지 않는다"가 아니라 **평범한 소스 파일을 막는 것**이다. 8 MiB는 그런 파일을 덮으면서
/// 브리지가 한 번에 옮기는 양은 여전히 묶어 둔다(양쪽 합 16 MiB가 상한).
pub const max_side_bytes: usize = 8 << 20;

/// **줄 수로는 거르지 않는다.** 문서의 "diff 페이지 500행"은 페이지네이션 단위이지 표시 상한이 아닌데, 그걸 상한으로
/// 쓰면 500줄 넘는 파일(대부분)이 안 열린다. 실측(2026-08-01, 제품 WKWebView): 2만 줄 문서에서 10%가 다른 최악의
/// 경우도 마운트 **229 ms**, 1천·5천 줄은 ~100 ms다 — CM6가 화면 밖을 그리지 않기 때문이다. 양을 묶는 일은
/// **바이트 상한**(`max_side_bytes`)이 이미 한다(1 MiB면 보통 코드로 2만 줄 남짓이라 위 측정 범위 안이다).
/// binary 판정에 볼 앞부분 길이. git도 같은 방식(앞부분에 NUL이 있으면 binary)이라 판정이 목록의 `-` 표시와 어긋나지
/// 않는다. 전체를 훑지 않는 이유는 큰 파일에서 판정 비용이 파일 크기에 비례하지 않게 하기 위해서다.
pub const binary_probe_bytes: usize = 8000;

pub const Rejection = enum {
    /// 한쪽이 `max_side_bytes`를 넘었다 → 외부 앱으로 열기 안내(§6).
    too_large,
    /// NUL 바이트가 있다 → 텍스트 비교가 의미 없다.
    binary,
};

pub const Decision = union(enum) {
    /// 그대로 실어도 되는 본문(자르지 않은 전체다).
    ok: struct { original: []const u8, modified: []const u8 },
    reject: Rejection,
};

/// 두 쪽 바이트를 받아 실을지 말지 정한다. **할당하지 않는다** — 자를 때도 입력 슬라이스를 잘라 돌려준다.
///
/// 판정 순서가 계약이다: 크기 → binary → 줄 수. 큰 파일을 binary 검사하려고 먼저 훑지 않고(비용), binary를
/// 줄 단위로 자르지도 않는다(의미 없음).
pub fn decide(original: []const u8, modified: []const u8) Decision {
    if (original.len > max_side_bytes or modified.len > max_side_bytes) return .{ .reject = .too_large };
    if (looksBinary(original) or looksBinary(modified)) return .{ .reject = .binary };
    return .{ .ok = .{ .original = original, .modified = modified } };
}

/// 앞부분에 NUL이 있으면 binary로 본다(git과 같은 판정).
pub fn looksBinary(bytes: []const u8) bool {
    const probe = bytes[0..@min(bytes.len, binary_probe_bytes)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

const testing = std.testing;

test "상한 안의 텍스트는 그대로 싣는다" {
    const decision = decide("a\nb\n", "a\nB\n");
    try testing.expectEqualStrings("a\nb\n", decision.ok.original);
    try testing.expectEqualStrings("a\nB\n", decision.ok.modified);
}

test "한쪽만 커도 거른다(합이 아니라 한쪽 기준)" {
    const big = "x" ** (max_side_bytes + 1);
    try testing.expectEqual(Rejection.too_large, decide(big, "small").reject);
    try testing.expectEqual(Rejection.too_large, decide("small", big).reject);
}

test "NUL이 있으면 binary다 — 크기 판정보다 뒤에 온다" {
    try testing.expectEqual(Rejection.binary, decide("ok\n", "a\x00b").reject);
    const big_binary = "\x00" ** (max_side_bytes + 1);
    try testing.expectEqual(Rejection.too_large, decide("ok\n", big_binary).reject);
}

test "탐침 범위 밖의 NUL은 binary로 보지 않는다(git과 같은 판정)" {
    var buf: [binary_probe_bytes + 10]u8 = undefined;
    @memset(&buf, 'a');
    buf[binary_probe_bytes + 5] = 0;
    try testing.expect(!looksBinary(&buf));
}

test "긴 문서는 그대로 싣는다(줄 수로 거르지 않는다)" {
    // 500줄 상한은 페이지네이션 단위를 표시 상한으로 잘못 쓴 것이었다 — 실측상 2만 줄도 마운트 229ms다.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    for (0..5000) |i| try buf.writer.print("line {d}\n", .{i});
    const decision = decide(buf.written(), "one\n");
    try testing.expectEqualStrings(buf.written(), decision.ok.original); // 자르지도, 거절하지도 않는다
}

test "마지막 줄에 개행이 없어도 한 줄로 센다" {
    const decision = decide("a\nb", "a\nb");
    try testing.expectEqualStrings("a\nb", decision.ok.original);
}
