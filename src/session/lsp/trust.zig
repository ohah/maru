//! 워크스페이스 신뢰 기억(docs/editor-surface-tooling.md §8.2a 「신뢰」) — `~/.config/maru/lsp-trust` 의 줄마다 `allow\t‹root›` /
//! `deny\t‹root›`. 순수 계산(파일 읽기·쓰기는 호출자). 마지막 줄이 이긴다 — 같은 root 를 다시 답하면 뒤에 붙이기만 하면 된다.
//!
//! **root 는 정규화된 절대 경로**여야 한다(끝 `/` 없음). 그 정규화는 호출자(파일 트리 root)가 이미 한다 — 여기서는 문자열 비교뿐이다.

const std = @import("std");

pub const Decision = enum { allow, deny };

/// 파일 내용에서 root 의 결정을 찾는다. 없으면 `null`(물어야 한다). 탭이 아니라 공백으로 갈린 줄·모르는 동사는 무시.
pub fn lookup(contents: []const u8, root: []const u8) ?Decision {
    var found: ?Decision = null;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const entry = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        const verb = entry[0..tab];
        const path = entry[tab + 1 ..];
        if (!std.mem.eql(u8, path, root)) continue;
        if (std.mem.eql(u8, verb, "allow")) found = .allow else if (std.mem.eql(u8, verb, "deny")) found = .deny;
    }
    return found;
}

/// 붙일 한 줄(개행 포함). `out` 이 모자라면 `null`. root 에 탭·개행이 있으면 `null` — 그런 경로는 기억할 수 없다(줄 형식이 깨진다).
pub fn line(decision: Decision, root: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, root, "\t\n\r") != null) return null;
    return std.fmt.bufPrint(out, "{s}\t{s}\n", .{ @tagName(decision), root }) catch null;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LST1 마지막 줄이 이긴다 — allow 뒤 deny 는 deny; 다른 root·모르는 동사·탭 없는 줄은 무시; 없으면 null (§8.2a)" {
    const f = "allow\t/a\nweird\t/a\nallow /b\ndeny\t/a\r\nallow\t/c\n";
    try testing.expectEqual(@as(?Decision, .deny), lookup(f, "/a"));
    try testing.expectEqual(@as(?Decision, .allow), lookup(f, "/c"));
    try testing.expect(lookup(f, "/b") == null); // 탭이 아니다
    try testing.expect(lookup(f, "/a/sub") == null); // 접두가 아니라 같음
    try testing.expect(lookup("", "/a") == null);
}

test "LST2 줄 만들기 — 되읽으면 같은 결정; 탭·개행이 든 root 는 못 적는다" {
    var buf: [64]u8 = undefined;
    const l = line(.allow, "/x/y z", &buf).?;
    try testing.expectEqualStrings("allow\t/x/y z\n", l);
    try testing.expectEqual(@as(?Decision, .allow), lookup(l, "/x/y z"));
    try testing.expect(line(.deny, "/bad\tpath", &buf) == null);
    var tiny: [4]u8 = undefined;
    try testing.expect(line(.deny, "/x", &tiny) == null);
}
