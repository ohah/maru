//! Chromium net 오류 번호의 이름(2026-11-20 「더하기」 — `browser.list`·`getUrl` 의 오류 페이지 표시). 오류 페이지로 끝나는 흔한 번호만 싣는다 —
//! 표에 없는 번호는 이름 없이 번호만 보인다(에이전트는 번호로 찾아볼 수 있다). 번호는 CEF 헤더(`cef_net_error_list.h`)와 같아야 한다 — sidecar
//! (`platform/macos/web_sidecar/dialogs.zig`)의 comptime 이 표의 줄마다 `c.ERR_*` 와 같은지 단언한다(CEF 를 올려 바뀌면 빌드가 멈춘다). CEF 를
//! 모르는 순수 표라 L2 에 두고 Linux 에서도 시험한다.
//!
//! sidecar 는 0 이상 번호를 -2(`ERR_FAILED`)로 바꿔 보낸다(`console.errorPage`) — 오는 번호는 늘 음수다.

const std = @import("std");

pub const Entry = struct { code: i32, name: []const u8 };

/// 번호 → 이름. 이름은 Chromium 의 `net::ERR_*` 그대로(오류 페이지 아래에 보이는 글과 같다).
pub const table = [_]Entry{
    .{ .code = -2, .name = "ERR_FAILED" },
    .{ .code = -6, .name = "ERR_FILE_NOT_FOUND" },
    .{ .code = -7, .name = "ERR_TIMED_OUT" },
    .{ .code = -10, .name = "ERR_ACCESS_DENIED" },
    .{ .code = -12, .name = "ERR_INSUFFICIENT_RESOURCES" },
    .{ .code = -20, .name = "ERR_BLOCKED_BY_CLIENT" },
    .{ .code = -21, .name = "ERR_NETWORK_CHANGED" },
    .{ .code = -22, .name = "ERR_BLOCKED_BY_ADMINISTRATOR" },
    .{ .code = -27, .name = "ERR_BLOCKED_BY_RESPONSE" },
    .{ .code = -100, .name = "ERR_CONNECTION_CLOSED" },
    .{ .code = -101, .name = "ERR_CONNECTION_RESET" },
    .{ .code = -102, .name = "ERR_CONNECTION_REFUSED" },
    .{ .code = -103, .name = "ERR_CONNECTION_ABORTED" },
    .{ .code = -104, .name = "ERR_CONNECTION_FAILED" },
    .{ .code = -105, .name = "ERR_NAME_NOT_RESOLVED" },
    .{ .code = -106, .name = "ERR_INTERNET_DISCONNECTED" },
    .{ .code = -107, .name = "ERR_SSL_PROTOCOL_ERROR" },
    .{ .code = -108, .name = "ERR_ADDRESS_INVALID" },
    .{ .code = -109, .name = "ERR_ADDRESS_UNREACHABLE" },
    .{ .code = -113, .name = "ERR_SSL_VERSION_OR_CIPHER_MISMATCH" },
    .{ .code = -118, .name = "ERR_CONNECTION_TIMED_OUT" },
    .{ .code = -130, .name = "ERR_PROXY_CONNECTION_FAILED" },
    .{ .code = -137, .name = "ERR_NAME_RESOLUTION_FAILED" },
    .{ .code = -200, .name = "ERR_CERT_COMMON_NAME_INVALID" },
    .{ .code = -201, .name = "ERR_CERT_DATE_INVALID" },
    .{ .code = -202, .name = "ERR_CERT_AUTHORITY_INVALID" },
    .{ .code = -207, .name = "ERR_CERT_INVALID" },
    .{ .code = -300, .name = "ERR_INVALID_URL" },
    .{ .code = -301, .name = "ERR_DISALLOWED_URL_SCHEME" },
    .{ .code = -302, .name = "ERR_UNKNOWN_URL_SCHEME" },
    .{ .code = -303, .name = "ERR_INVALID_REDIRECT" },
    .{ .code = -310, .name = "ERR_TOO_MANY_REDIRECTS" },
    .{ .code = -311, .name = "ERR_UNSAFE_REDIRECT" },
    .{ .code = -312, .name = "ERR_UNSAFE_PORT" },
    .{ .code = -320, .name = "ERR_INVALID_RESPONSE" },
    .{ .code = -324, .name = "ERR_EMPTY_RESPONSE" },
    .{ .code = -330, .name = "ERR_CONTENT_DECODING_FAILED" },
    .{ .code = -379, .name = "ERR_HTTP_RESPONSE_CODE_FAILURE" },
    .{ .code = -501, .name = "ERR_INSECURE_RESPONSE" },
};

/// 그 번호의 이름(표에 없으면 null — 번호만 보인다).
pub fn name(code: i32) ?[]const u8 {
    for (table) |e| if (e.code == code) return e.name;
    return null;
}

test "net_error: 흔한 오류 페이지 번호의 이름, 모르는 번호·0·양수는 이름 없음" {
    try std.testing.expectEqualStrings("ERR_BLOCKED_BY_CLIENT", name(-20).?);
    try std.testing.expectEqualStrings("ERR_CONNECTION_REFUSED", name(-102).?);
    try std.testing.expectEqualStrings("ERR_NAME_NOT_RESOLVED", name(-105).?);
    try std.testing.expectEqualStrings("ERR_UNSAFE_PORT", name(-312).?);
    try std.testing.expectEqualStrings("ERR_FAILED", name(-2).?);
    try std.testing.expect(name(-3) == null); // ERR_ABORTED 는 오류 페이지가 아니다(sidecar 가 보내지 않는다)
    try std.testing.expect(name(-9999) == null);
    try std.testing.expect(name(0) == null);
    try std.testing.expect(name(20) == null);
}

test "net_error: 표의 번호는 음수이고 겹치지 않으며 이름은 ERR_ 대문자" {
    for (table, 0..) |e, i| {
        try std.testing.expect(e.code < 0);
        try std.testing.expect(std.mem.startsWith(u8, e.name, "ERR_"));
        for (e.name) |ch| try std.testing.expect(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_');
        for (table[i + 1 ..]) |o| {
            try std.testing.expect(o.code != e.code);
            try std.testing.expect(!std.mem.eql(u8, o.name, e.name));
        }
    }
}
