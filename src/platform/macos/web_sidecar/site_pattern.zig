//! 사이트 권한 패턴(2026-11-18 — `site_settings.zig`)의 순수 절반 — CEF 를 모른다(`pure_tests.zig` 가 돈다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

/// `"<1차>,<2차>"` 에서 1차가 출처 꼴이고 2차가 `*` 일 때 그 출처. 순수(시험한다).
pub fn originOfPattern(key: []const u8) ?[]const u8 {
    const comma = std.mem.lastIndexOfScalar(u8, key, ',') orelse return null;
    if (!std.mem.eql(u8, key[comma + 1 ..], "*")) return null;
    const primary = key[0..comma];
    if (primary.len == 0 or primary.len > protocol.fields.max_origin_bytes) return null;
    if (std.mem.indexOf(u8, primary, "[*.]") != null or std.mem.indexOfScalar(u8, primary, '*') != null) return null;
    protocol.fields.checkOrigin(primary) catch return null;
    return primary;
}

test "originOfPattern: 출처 꼴의 1차와 * 2차만 — 와일드카드·임베드·경로·빈 것은 null" {
    try std.testing.expectEqualStrings("http://127.0.0.1:30237", originOfPattern("http://127.0.0.1:30237,*").?);
    try std.testing.expectEqualStrings("https://accounts.google.com:443", originOfPattern("https://accounts.google.com:443,*").?);
    try std.testing.expect(originOfPattern("[*.]example.com,*") == null);
    try std.testing.expect(originOfPattern("https://[*.]example.com:443,*") == null);
    try std.testing.expect(originOfPattern("*,*") == null);
    try std.testing.expect(originOfPattern("https://a.example:443,https://top.example:443") == null);
    try std.testing.expect(originOfPattern("https://a.example/path,*") == null);
    try std.testing.expect(originOfPattern(",*") == null);
    try std.testing.expect(originOfPattern("https://a.example") == null);
    try std.testing.expectEqualStrings("http://[::1]:8080", originOfPattern("http://[::1]:8080,*").?);
}
