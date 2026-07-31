//! `diff.open`이 웹으로 넘길 **본문 페이로드 정책**(L2 순수, docs/editor-surface.md §6·§10.6).
//!
//! 무엇을 실을지가 아니라 **무엇을 싣지 않을지**를 정하는 곳이다. diff 본문은 사용자가 고른 파일 하나지만 그 파일이
//! 100 MB일 수도, 실행 파일일 수도 있다. 그대로 브리지에 태우면 신뢰 shell이 그만큼을 문자열로 들고 CM6가 그것을
//! 파싱한다 — 화면에 못 그릴 것을 옮기느라 앱이 멎는다.
//!
//! 그래서 판정을 **바이트를 보기 전에 크기로**, 그리고 **내용을 보고 binary로** 두 번 한다. 둘 다 typed 결과로
//! 돌려주고(§6), 호출자는 그 사실을 화면에 말한다 — 잘린 내용을 정상인 척 보여 주지 않는다.

const std = @import("std");

/// 한쪽 문서의 바이트 상한(§10.6 — 1 MiB에서 출발해 실측으로 조정한다). 양쪽 합이 아니라 **한쪽 기준**이다:
/// 원본만 큰 경우(대용량 파일 삭제)와 수정본만 큰 경우를 같은 규칙으로 거른다.
pub const max_side_bytes: usize = 1 << 20;

/// 한 페이지에 실을 최대 줄 수(§10.6). CM6는 더 큰 문서도 열지만, 한 번에 넘기는 양을 묶어 두면 브리지 payload와
/// 첫 렌더 비용이 파일 크기와 무관하게 상한을 갖는다. 페이지 넘김은 후속 슬라이스다.
pub const max_lines: usize = 500;

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
    /// 그대로 실어도 되는 본문. 줄 수 상한을 넘었으면 `truncated_lines`가 잘린 사실을 싣는다.
    ok: struct { original: []const u8, modified: []const u8, truncated_lines: bool },
    reject: Rejection,
};

/// 두 쪽 바이트를 받아 실을지 말지 정한다. **할당하지 않는다** — 자를 때도 입력 슬라이스를 잘라 돌려준다.
///
/// 판정 순서가 계약이다: 크기 → binary → 줄 수. 큰 파일을 binary 검사하려고 먼저 훑지 않고(비용), binary를
/// 줄 단위로 자르지도 않는다(의미 없음).
pub fn decide(original: []const u8, modified: []const u8) Decision {
    if (original.len > max_side_bytes or modified.len > max_side_bytes) return .{ .reject = .too_large };
    if (looksBinary(original) or looksBinary(modified)) return .{ .reject = .binary };
    const cut_original = firstLines(original);
    const cut_modified = firstLines(modified);
    return .{ .ok = .{
        .original = cut_original.text,
        .modified = cut_modified.text,
        .truncated_lines = cut_original.truncated or cut_modified.truncated,
    } };
}

/// 앞부분에 NUL이 있으면 binary로 본다(git과 같은 판정).
pub fn looksBinary(bytes: []const u8) bool {
    const probe = bytes[0..@min(bytes.len, binary_probe_bytes)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

const Cut = struct { text: []const u8, truncated: bool };

/// 앞에서 `max_lines`줄까지 잘라 돌려준다. 자른 경우 그 사실을 함께 준다 — 조용히 일부만 보여 주지 않는다.
fn firstLines(bytes: []const u8) Cut {
    var lines: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '\n') continue;
        lines += 1;
        if (lines == max_lines) return .{ .text = bytes[0 .. i + 1], .truncated = i + 1 < bytes.len };
    }
    return .{ .text = bytes, .truncated = false };
}

const testing = std.testing;

test "상한 안의 텍스트는 그대로 싣는다" {
    const decision = decide("a\nb\n", "a\nB\n");
    try testing.expectEqualStrings("a\nb\n", decision.ok.original);
    try testing.expectEqualStrings("a\nB\n", decision.ok.modified);
    try testing.expect(!decision.ok.truncated_lines);
}

test "한쪽만 커도 거른다(합이 아니라 한쪽 기준)" {
    const big = "x" ** (max_side_bytes + 1);
    try testing.expectEqual(Rejection.too_large, decide(big, "small").reject);
    try testing.expectEqual(Rejection.too_large, decide("small", big).reject);
}

test "NUL이 있으면 binary다 — 크기 판정보다 뒤에 온다" {
    try testing.expectEqual(Rejection.binary, decide("ok\n", "a\x00b").reject);
    // 큰 binary는 binary가 아니라 too_large로 걸린다(크기를 먼저 본다 — 훑는 비용을 아낀다).
    const big_binary = "\x00" ** (max_side_bytes + 1);
    try testing.expectEqual(Rejection.too_large, decide("ok\n", big_binary).reject);
}

test "탐침 범위 밖의 NUL은 binary로 보지 않는다(git과 같은 판정)" {
    var buf: [binary_probe_bytes + 10]u8 = undefined;
    @memset(&buf, 'a');
    buf[binary_probe_bytes + 5] = 0;
    try testing.expect(!looksBinary(&buf));
}

test "줄 수 상한을 넘으면 잘라 싣고 잘렸다고 말한다" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    for (0..max_lines + 10) |i| {
        try buf.writer.print("line {d}\n", .{i});
    }
    const decision = decide(buf.written(), "one\n");
    try testing.expect(decision.ok.truncated_lines);
    try testing.expectEqual(max_lines, std.mem.count(u8, decision.ok.original, "\n"));
    // 짧은 쪽은 손대지 않는다.
    try testing.expectEqualStrings("one\n", decision.ok.modified);
}

test "마지막 줄에 개행이 없어도 자르지 않은 것은 그대로다" {
    const decision = decide("a\nb", "a\nb");
    try testing.expectEqualStrings("a\nb", decision.ok.original);
    try testing.expect(!decision.ok.truncated_lines);
}
