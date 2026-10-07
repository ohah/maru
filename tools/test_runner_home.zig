//! 공용 테스트 러너(`simple_test_runner.zig`)의 `HOME`·`XDG_*` 격리 판정 — **순수 함수만** 둔다.
//!
//! 러너 안의 판정은 판정자가 직접 부를 수 없어(러너는 테스트 모듈이 아니다) 「`HOME=/` 이면 무한 self-exec」 같은
//! 결함이 단위로 안 잡혔다(적대적 검증 2026-10-07) — 격리 경계 판정자(`tests/session_host_test_namespace_isolation_boundary.zig`)
//! 는 러너가 만든 **결과**만 본다. 그래서 판정을 여기 두고 러너가 import 하며, 아래 판정자가 그 함수를 직접 부른다.
//! 이 파일의 판정자는 공용 러너가 아닌 **기본 러너**로 돈다(`build.zig` `check-boundaries`) — 공용 러너가 이 파일을
//! import 하므로 같은 컴파일에 다시 넣으면 「file exists in modules」로 막힌다. 순수 함수라 격리가 필요 없다.

const std = @import("std");

/// 러너가 다루는 XDG 변수와, `HOME` 에서 유도될 때의 하위 경로(XDG Base Directory 명세의 기본값).
pub const Xdg = struct { name: [*:0]const u8, sub: []const u8 };
pub const xdg_vars = [_]Xdg{
    .{ .name = "XDG_CACHE_HOME", .sub = ".cache" },
    .{ .name = "XDG_CONFIG_HOME", .sub = ".config" },
    .{ .name = "XDG_DATA_HOME", .sub = ".local/share" },
    .{ .name = "XDG_STATE_HOME", .sub = ".local/state" },
};

/// `path` 가 `dir` 자신이거나 그 아래인가 — 끝 `/` 는 무시하고 **경로 칸 단위**로 본다(`/tmp/h` 는 `/tmp/home` 의 조상이
/// 아니다). `dir` 이 비면 기준이 없으므로 아니다.
///
/// ⚠️ **루트(`/`)는 모든 절대 경로의 조상이다.** 예전에는 끝 `/` 를 떼면 빈 문자열이 되어 「아무것도 안 담는다」로
/// 읽었고, `HOME=/` 에 XDG 가 하나라도 있으면 러너가 XDG 를 `//.cache` 로 고쳐 exec 한 뒤 **또 밖이라고 판정해 끝없이
/// 자기 자신을 exec 했다**(2026-10-07 재현 — 같은 pid 가 출력 없이 2 분 넘게 돌았다).
pub fn pathUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    const d = std.mem.trimEnd(u8, dir, "/");
    if (d.len == 0) return path.len > 0 and path[0] == '/';
    const p = std.mem.trimEnd(u8, path, "/");
    if (!std.mem.startsWith(u8, p, d)) return false;
    return p.len == d.len or p[d.len] == '/';
}

/// 이 `HOME` 은 격리 기준으로 **쓸 수 없는가** — 비었거나 루트(`/`·`//` …)면 그렇다. 러너는 이때 실제 홈일 때처럼 새 임시 홈을
/// 세운다. 루트는 모든 절대 경로의 조상이라(`pathUnder`) 실제 캐시를 가리키는 XDG 도 「홈 아래」로 읽혀 **그대로 샜다**
/// (적대적 검증 2026-10-07 재현 — 예전에는 무한 self-exec, 그 고침 뒤에는 조용한 누출). 빈 값도 기준이 없어 XDG 를 못 옮겼다.
/// `HOME` 이 **아예 없는** 것은 다르다 — 명시 환경으로 자기 자신을 다시 띄우는 fixture 자식들이 「HOME 없음」을 일부러 시험한다.
pub fn homeUnusable(home: []const u8) bool {
    return std.mem.trimEnd(u8, home, "/").len == 0;
}

/// 이 XDG 값을 `home` 아래로 **새로 써야 하는가** — 비어 있거나(설정 안 됨) 홈 밖이면 그렇다.
///
/// **비어 있어도 쓴다.** login(1) 래퍼는 `HOME` 을 실제 홈으로 다시 정하지만 `XDG_*` 는 지킨다 — 비어 있던 XDG 는 그 셸
/// 안에서 실제 홈에서 유도되므로, 러너가 미리 채워 두어야 XDG 를 따르는 쓰기(캐시·상태)가 격리 홈에 남는다.
pub fn xdgNeedsMove(value: ?[]const u8, home: []const u8) bool {
    const v = value orelse return true;
    if (v.len == 0) return true;
    return !pathUnder(v, home);
}

/// `home` 아래의 XDG 경로(`<home>/<sub>`)를 `buf` 에 쓴다 — 끝 `/` 를 떼고 잇는다(`HOME=/` 이면 `/.cache`).
pub fn xdgPath(buf: []u8, home: []const u8, sub: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), sub });
}

// 「`HOME=/` 이면 무한 self-exec」는 결과가 아니라 **판정 함수**에서 났다(2026-10-07 재현: 같은 pid 가 출력 없이 2 분 넘게 돌았다). 그 함수를 직접 부른다.
test "runner home judgement: path ancestry is per path segment, root contains every absolute path, and every rewrite converges" {
    try std.testing.expect(pathUnder("/tmp/home/.cache", "/tmp/home"));
    try std.testing.expect(pathUnder("/tmp/home", "/tmp/home/"));
    try std.testing.expect(pathUnder("/tmp/home/", "/tmp/home"));
    try std.testing.expect(!pathUnder("/tmp/homex/.cache", "/tmp/home")); // 칸 단위
    try std.testing.expect(!pathUnder("/tmp", "/tmp/home"));
    try std.testing.expect(pathUnder("/x/.cache", "/")); // 루트는 모든 절대 경로의 조상
    try std.testing.expect(pathUnder("//.cache", "//"));
    try std.testing.expect(!pathUnder("relative/.cache", "/"));
    try std.testing.expect(!pathUnder("/x", "")); // 기준 홈이 없다
    try std.testing.expect(xdgNeedsMove(null, "/tmp/home")); // 비어 있어도 채운다
    try std.testing.expect(xdgNeedsMove("", "/tmp/home"));
    try std.testing.expect(xdgNeedsMove("/Users/me/.cache", "/tmp/home"));
    try std.testing.expect(!xdgNeedsMove("/tmp/home/.cache", "/tmp/home"));
    // **고친 값은 다시 고칠 일이 없다** — 이것이 깨지면 러너는 끝없이 자기 자신을 exec 한다(러너는 exec 전에 같은 판정을
    // 다시 해 사유 있는 실패로 바꾸지만, 그 가드에 기대지 않고 여기서 먼저 막는다).
    for ([_][]const u8{ "/", "//", "/tmp/home", "/tmp/home/", "/tmp/maru-home-1-AbC123", "relative" }) |home| {
        for (xdg_vars) |x| {
            var buf: [256]u8 = undefined;
            const value = try xdgPath(&buf, home, x.sub);
            try std.testing.expect(!xdgNeedsMove(value, home));
        }
    }
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/.cache", try xdgPath(&buf, "/", ".cache"));
    // 쓸 수 없는 홈 — 비었거나 루트. 러너가 새 임시 홈을 세운다(루트는 실제 캐시 XDG 도 「아래」로 읽어 샜다).
    for ([_][]const u8{ "", "/", "//", "///" }) |home| try std.testing.expect(homeUnusable(home));
    for ([_][]const u8{ "/tmp/home", "/tmp/home/", "relative", "/a" }) |home| try std.testing.expect(!homeUnusable(home));
    try std.testing.expectEqualStrings("/tmp/h/.local/state", try xdgPath(&buf, "/tmp/h/", ".local/state"));
}
