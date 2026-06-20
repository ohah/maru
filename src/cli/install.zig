//! `maru install-cli`의 순수 헬퍼 — 경로 조립과 PATH 멤버십 판정. 실제 I/O(자기 경로 resolve·mkdir·
//! symlink)는 main.zig가 한다. 이 모듈은 std만 의존해 단위 테스트로 동작을 못박는다.
//!
//! 무엇을 하나: `maru install-cli`는 현재 maru 바이너리를 사용자 PATH 디렉터리(`~/.local/bin/maru`)에
//! symlink해, 셸에서 `maru ssh` 같은 명령을 쓸 수 있게 한다(VS Code `code` 명령 설치와 같은 결).
//! sudo가 필요 없는 user-level 경로를 기본으로 둔다. 나중에 macOS .app 메뉴 'Install command'는 같은
//! 로직을 호출하는 얇은 버튼이 된다(docs/macos-app-host-boundary.md).

const std = @import("std");

/// CLI symlink를 둘 사용자 bin 디렉터리(홈 기준 상대). sudo 없이 쓰는 user-level 경로다.
pub const bin_subpath = ".local/bin";

/// bin 디렉터리 절대 경로(`<home>/.local/bin`). caller가 free한다.
pub fn binDir(allocator: std.mem.Allocator, home: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ home, bin_subpath }, 0);
}

/// symlink 경로(`<home>/.local/bin/maru`). caller가 free한다.
pub fn linkPath(allocator: std.mem.Allocator, home: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}/maru", .{ home, bin_subpath }, 0);
}

/// `$PATH`(":"로 구분)에 dir가 **정확히** 포함되는지. 설치 후 "PATH에 추가하라" 안내를 낼지
/// 정하는 데 쓴다 — 이미 있으면 안내를 안 낸다. 빈 entry(연속 ":")는 dir와 안 맞으므로 자연히 무시된다.
pub fn pathContainsDir(path_env: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

test "linkPath / binDir: 홈 기준 user-level 경로" {
    const a = std.testing.allocator;
    const bd = try binDir(a, "/Users/me");
    defer a.free(bd);
    try std.testing.expectEqualStrings("/Users/me/.local/bin", bd);
    const lp = try linkPath(a, "/Users/me");
    defer a.free(lp);
    try std.testing.expectEqualStrings("/Users/me/.local/bin/maru", lp);
}

test "pathContainsDir: 정확 일치만 true" {
    const dir = "/Users/me/.local/bin";
    try std.testing.expect(pathContainsDir("/usr/bin:/Users/me/.local/bin:/bin", dir));
    try std.testing.expect(pathContainsDir(dir, dir)); // 단독
    try std.testing.expect(pathContainsDir("::/Users/me/.local/bin", dir)); // 빈 entry 섞임
    try std.testing.expect(!pathContainsDir("/usr/bin:/bin", dir)); // 없음
    try std.testing.expect(!pathContainsDir("/Users/me/.local/bin2", dir)); // 부분 일치는 false
    try std.testing.expect(!pathContainsDir("", dir));
}
