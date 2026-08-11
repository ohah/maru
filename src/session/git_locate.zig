//! git 실행 파일 **후보 열거**(L2 순수, docs/editor-surface-dock.md §3.5).
//!
//! 소스 컨트롤 뷰는 git CLI를 실행해 읽는다. git이 없으면 "읽는 중"에 고착시키지 말고 그 사실을 말해야 하므로,
//! 실행 전에 후보 경로를 훑어 실제로 있는 것을 고른다. 여기서는 **어떤 경로를 어떤 순서로 볼지**만 정하고,
//! 존재·실행권 판정은 파일 시스템을 아는 L4가 한다(이 모듈은 syscall을 부르지 않는다).
//!
//! 순서는 PATH 먼저다 — 사용자가 셸에서 쓰는 git과 같은 것을 쓰는 게 맞다. PATH에 없을 때만 통상 설치 위치를 본다.

const std = @import("std");

/// PATH에 없을 때 볼 통상 설치 위치. 앞이 우선이다(homebrew → 수동 설치 → 명령행 도구 → shim).
pub const fallback_dirs = [_][]const u8{
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/Library/Developer/CommandLineTools/usr/bin",
    "/usr/bin",
};

/// macOS의 `/usr/bin/git`은 진짜 git이 아니라 **개발자 도구 shim**이다. 도구가 없는 기기에서 이걸 실행하면
/// git이 도는 대신 "명령행 개발자 도구를 설치하시겠습니까" 모달이 뜬다 — 파일 목록 한 번 보려다 시스템 설치
/// 창을 띄우는 건 사용자가 시킨 적 없는 일이라, 도구가 실제로 깔려 있다는 증거(`toolchain_probes`) 없이는
/// 후보에서 뺀다. PATH에는 거의 항상 `/usr/bin`이 들어 있으므로 위치와 무관하게 경로로 판정한다.
pub const shim_path = "/usr/bin/git";

/// shim을 믿어도 된다는 증거. 둘 중 하나라도 있으면 개발자 도구가 깔린 것이다.
pub const toolchain_probes = [_][]const u8{
    "/Library/Developer/CommandLineTools/usr/bin/git",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
};

pub fn isShim(path: []const u8) bool {
    return std.mem.eql(u8, path, shim_path);
}

/// PATH 항목 → fallback 순으로 `<dir>/git` 후보를 낸다. 호출자 버퍼에 쓰고 그 슬라이스를 돌려주므로
/// **다음 next()가 이전 결과를 덮는다** — 쓸 후보는 그 자리에서 판정하거나 복사해야 한다.
pub fn candidates(path_env: []const u8) Iterator {
    return .{ .path_env = path_env };
}

pub const Iterator = struct {
    path_env: []const u8,
    path_pos: usize = 0,
    fallback_pos: usize = 0,

    pub fn next(self: *Iterator, buf: []u8) ?[]const u8 {
        while (self.path_pos < self.path_env.len) {
            const rest = self.path_env[self.path_pos..];
            const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const dir = rest[0..end];
            self.path_pos += end + @intFromBool(end < rest.len);
            if (join(dir, buf)) |candidate| return candidate;
        }
        while (self.fallback_pos < fallback_dirs.len) {
            const dir = fallback_dirs[self.fallback_pos];
            self.fallback_pos += 1;
            if (join(dir, buf)) |candidate| return candidate;
        }
        return null;
    }
};

/// 절대경로 디렉터리에만 "/git"을 붙인다. 빈 항목(PATH의 `::`은 POSIX상 현재 디렉터리)과 상대경로는 건너뛴다 —
/// 앱의 cwd에 있는 `git`이라는 파일을 실행할 이유가 없다. 버퍼가 모자라도 건너뛴다(자른 경로를 실행하면 위험).
fn join(dir: []const u8, buf: []u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(dir)) return null;
    const trimmed = if (dir.len > 1 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    return std.fmt.bufPrint(buf, "{s}/git", .{trimmed}) catch null;
}

const testing = std.testing;

test "PATH 항목을 순서대로 내고 뒤에 통상 위치가 붙는다" {
    var buf: [256]u8 = undefined;
    var it = candidates("/opt/bin:/usr/bin");
    try testing.expectEqualStrings("/opt/bin/git", it.next(&buf).?);
    try testing.expectEqualStrings("/usr/bin/git", it.next(&buf).?);
    try testing.expectEqualStrings(fallback_dirs[0] ++ "/git", it.next(&buf).?);
}

test "빈 항목·상대경로는 건너뛰고 끝 슬래시는 하나만 남긴다" {
    var buf: [256]u8 = undefined;
    var it = candidates("::rel/bin:/opt/bin/:");
    try testing.expectEqualStrings("/opt/bin/git", it.next(&buf).?); // 앞의 셋은 전부 배제
    try testing.expectEqualStrings(fallback_dirs[0] ++ "/git", it.next(&buf).?);
}

test "PATH가 비어도 통상 위치는 전부 낸다" {
    var buf: [256]u8 = undefined;
    var it = candidates("");
    for (fallback_dirs) |dir| {
        var expected: [256]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}/git", .{dir}), it.next(&buf).?);
    }
    try testing.expect(it.next(&buf) == null);
}

test "버퍼가 모자란 후보는 자르지 않고 건너뛴다" {
    var buf: [12]u8 = undefined; // "/usr/bin/git"(12)는 담기고 "/opt/homebrew/bin/git"은 못 담는다
    var it = candidates("/very/long/prefix/bin:/usr/bin");
    try testing.expectEqualStrings("/usr/bin/git", it.next(&buf).?);
    try testing.expectEqualStrings("/usr/bin/git", it.next(&buf).?); // fallback의 /usr/bin — 그 앞 둘은 길이 초과
    try testing.expect(it.next(&buf) == null);
}

test "shim은 PATH에서 나와도 shim으로 판정한다" {
    var buf: [256]u8 = undefined;
    var it = candidates("/usr/bin");
    try testing.expect(isShim(it.next(&buf).?));
    try testing.expect(!isShim("/opt/homebrew/bin/git"));
}
