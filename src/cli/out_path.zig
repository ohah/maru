//! `maru browser … --out <path>` 의 **순수 절반** — 그 경로에 써도 되는가를 정한다(사용자 결정 2026-11-15
//! 「CLI 에서 — 새 파일만, 그리고 자리 제한」). 파일을 열고 정규 경로를 얻는 일은 `browser/run.zig` 가 하고,
//! 여기는 그 결과(정규 경로 문자열)만 받는다 — 그래서 소켓·파일 없이 시험한다.
//!
//! 왜 있나: `maru-browser` 플러그인은 `Bash(maru browser *)` 를 묻지 않고 허용한다. 그 상태에서 `--out` 은
//! 에이전트가 **묻지 않고** 아무 파일이나 만들거나 덮는 길이었다(`--out "$HOME/.zshrc"` 가 통과 — 실측). `exec --out`
//! 의 내용은 페이지가 정하므로 악성 페이지가 셸 설정을 쓰게 몰 수도 있다. 사람이 쳐도 같은 규칙이다.
//!
//! 규칙(단일 출처는 docs/control-plane-browser.md §9.6 「`--out` 규칙」):
//! 1. 이름(끝 조각)이 파일 이름 꼴이어야 한다 — `/` 로 끝나거나 `.`·`..` 면 폴더를 뜻하고, NUL·255 바이트 초과는 못 쓴다.
//! 2. 부모 폴더의 정규 경로가 **뿌리**(현재 폴더·`$TMPDIR`·`/tmp`) 아래여야 한다. 현재 폴더는 `/` 나 `$HOME` 의 조상이면
//!    뿌리가 못 된다(사람이 우연히 서 있는 자리다). 임시 폴더는 `/` 만 아니면 된다(정해진 자리다).
//! 3. 정규 경로의 **어느 조각도** 점으로 시작하면 안 되고(끝 이름도), `$HOME/Library` 는 숨은 폴더로 친다.
//! 「새 파일만」 은 파일 시스템이 판정한다(`link(2)` 의 EEXIST) — 여기서는 그 오류의 글만 둔다.
//!
//! 3 이 뿌리 **안쪽**만이 아니라 전체 경로를 보는 까닭: Claude Code 는 작업 폴더 안의 `cd` 를 묻지 않는다(실측).
//! 뿌리 기준이면 `cd .claude && maru browser exec --out settings.local.json …` 이 점 없는 이름이 된다.

const std = @import("std");

/// 한 조각의 상한(APFS·ext4 의 NAME_MAX). 넘으면 쓰기 전에 `NameTooLong` — 파일 시스템까지 가지 않는다.
pub const max_name_bytes: usize = 255;

pub const SplitError = error{
    /// `/` 로 끝나거나 끝 조각이 `.`·`..` — 폴더를 뜻한다.
    DirectoryPath,
    /// NUL 이 든 경로(MCP 의 `out` 으로만 올 수 있다).
    BadPathName,
    /// 끝 조각이 `max_name_bytes` 를 넘는다.
    NameTooLong,
};

pub const JudgeError = error{
    /// 부모 폴더가 어느 뿌리 아래도 아니다.
    OutsideAllowed,
    /// 정규 경로나 끝 이름에 숨은 조각이 있다.
    HiddenPath,
};

/// `path` 를 부모 폴더 부분과 끝 이름으로 나눈다. `dir` 이 빈 글이면 현재 폴더, `/x` 면 `/`.
pub const Split = struct { dir: []const u8, leaf: []const u8 };

pub fn split(path: []const u8) SplitError!Split {
    // 폴더를 뜻하는 꼴이 먼저다 — `/`·`a/` 는 NUL 이 없어도, 끝 이름이 없어도 같은 까닭이다.
    if (path.len == 0 or path[path.len - 1] == '/') return error.DirectoryPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const leaf = if (slash) |at| path[at + 1 ..] else path;
    if (std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.DirectoryPath;
    if (leaf.len > max_name_bytes) return error.NameTooLong;
    const dir = if (slash) |at| (if (at == 0) "/" else path[0..at]) else "";
    return .{ .dir = dir, .leaf = leaf };
}

/// 정규 경로(끝 `/` 없음 — `/` 자체만 예외)가 `root` 와 같거나 그 밑인가. 바이트 그대로 견준다 — 대소문자가 달라
/// 어긋나면 **거절** 쪽이다(정규 경로는 `F_GETPATH` 가 저장된 철자로 준다 — 실측).
pub fn under(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return std.mem.endsWith(u8, root, "/") or path[root.len] == '/';
}

/// `under` 의 대소문자 무시 판(홈 판정에만 쓴다 — 철자 차이로 홈 규칙이 빠지지 않게).
fn underIgnoreCase(path: []const u8, root: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(path, root)) return false;
    if (path.len == root.len) return true;
    return std.mem.endsWith(u8, root, "/") or path[root.len] == '/';
}

/// 판정에 쓰는 정규 경로들 — 가장자리(`browser/run.zig`)가 이 프로세스의 cwd·`$TMPDIR`·`/tmp`·`$HOME` 을 열어 얻는다.
/// 못 연 것은 null·빠짐이다(그 뿌리 아래에는 못 쓴다 — 거절 쪽).
pub const Places = struct {
    cwd: ?[]const u8 = null,
    temps: []const []const u8 = &.{},
    /// 없으면 홈 규칙(Library·cwd 의 조상 판정)은 건너뛴다 — 점 규칙은 그대로.
    home: ?[]const u8 = null,
};

/// 현재 폴더가 뿌리가 될 수 있는가 — 절대 경로이고 `/` 가 아니며 `home` 의 조상이 아니다(대소문자 무시 — 조상 판정이 철자
/// 차이로 빠지면 뿌리가 넓어진다). cwd 가 `/`·`/Users` 면 그 아래 `/opt/homebrew`·다른 사용자 자리가 든다. 홈 **자체**는 된다 —
/// 점·Library 규칙이 dotfile·자동 시작 자리를 막는다.
pub fn usableCwd(cwd: []const u8, home: ?[]const u8) bool {
    if (!usableTemp(cwd)) return false;
    const h = home orelse return true;
    return !(underIgnoreCase(h, cwd) and !std.ascii.eqlIgnoreCase(h, cwd));
}

/// 임시 폴더가 뿌리가 될 수 있는가 — 절대 경로이고 `/` 가 아니다. 홈의 조상인지는 보지 않는다: `/tmp` 아래에 홈을 둔 격리 환경(CI 시험)에서
/// 임시 폴더까지 막히면 쓸 곳이 없다. 그때도 홈 안은 점·Library 규칙이 지킨다.
pub fn usableTemp(root: []const u8) bool {
    return root.len > 0 and root[0] == '/' and !std.mem.eql(u8, root, "/");
}

/// 정규 부모 경로 `parent` 의 `leaf` 에 써도 되는가.
pub fn judge(parent: []const u8, leaf: []const u8, places: Places) JudgeError!void {
    // 자리가 먼저다 — 뿌리 밖의 숨은 이름(`~/.zshrc`)은 「밖」 이 사람에게 더 쓸모 있는 까닭이다.
    const in_cwd = if (places.cwd) |c| usableCwd(c, places.home) and under(parent, c) else false;
    if (!in_cwd) for (places.temps) |t| {
        if (usableTemp(t) and under(parent, t)) break;
    } else return error.OutsideAllowed;
    if (hidden(leaf)) return error.HiddenPath;
    var parts = std.mem.tokenizeScalar(u8, parent, '/');
    while (parts.next()) |part| if (hidden(part)) return error.HiddenPath;
    // `~/Library` 는 Finder 가 숨기는 앱 자료 폴더다(LaunchAgents·Application Support·Preferences). 점이 없어 위에서 안 걸린다.
    if (places.home) |h| if (underIgnoreCase(parent, h) and parent.len > h.len) {
        const rest = std.mem.trimStart(u8, parent[h.len..], "/");
        const first = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        if (std.ascii.eqlIgnoreCase(first, "Library")) return error.HiddenPath;
    };
}

/// 점으로 시작하는 조각 — 셸·도구가 설정으로 읽는 자리(`.zshrc`·`.config`·`.claude`·`.git`·`.ssh`).
fn hidden(part: []const u8) bool {
    return part.len > 0 and part[0] == '.';
}

/// `--out` 을 쓰지 못한 까닭의 한 줄(영어). 흔한 것은 그 까닭을, 그 밖은 「atomically」 로.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.OutputExists => "cannot write the output file: something already exists there — maru never overwrites; pick a new name",
        error.OutsideAllowed => "cannot write the output file: it must be in the current folder or the temp folder ($TMPDIR or /tmp) — write it there",
        error.HiddenPath => "cannot write the output file: its path has a hidden part (a name starting with a dot, or ~/Library) — pick a visible folder, for example under $TMPDIR",
        error.FileNotFound => "cannot write the output file: its directory does not exist — create it first or write under $TMPDIR",
        error.IsDir => "cannot write the output file: the path is a directory",
        error.DirectoryPath => "cannot write the output file: the path names a directory (it ends with /, . or ..)",
        error.OutputIsSymLink => "cannot write the output file: the path is a symbolic link",
        error.NotDir => "cannot write the output file: a part of its directory path is not a directory",
        error.BadPathName => "cannot write the output file: the path is not a valid file name",
        error.NameTooLong => "cannot write the output file: a name in the path is too long",
        error.SymLinkLoop => "cannot write the output file: its path loops through symbolic links",
        error.AccessDenied, error.PermissionDenied => "cannot write the output file: permission denied",
        else => "cannot publish the output file atomically",
    };
}

// ── 시험 ──────────────────────────────────────────────────────────────────────────────────────────────
// 이 시험이 증명하는 것: 셸 설정·자동 시작 자리(`~/.zshrc`·`~/.config/…`·`~/Library/LaunchAgents/…`)와 뿌리 밖은
// 파일 시스템에 닿기 전에 거절되고, 보통의 `shot.png`·`$TMPDIR/x/y.png` 는 통과한다. 에이전트가 묻지 않고 부르는
// 명령이 사용자의 셸을 바꾸지 못하게 하는 마지막 관문이라 터미널에서 중요하다.

const testing = std.testing;
const array_repeat = @import("array_repeat");

test "split: 끝 이름과 부모 부분 — 상대·절대·가운데 `..`·겹친 `/`" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "shot.png", "", "shot.png" },
        .{ "a/b.png", "a", "b.png" },
        .{ "/x", "/", "x" },
        .{ "/tmp/a/b", "/tmp/a", "b" },
        .{ "../x.png", "..", "x.png" },
        .{ "a//b", "a/", "b" },
        .{ "-", "", "-" },
        .{ "a/./b", "a/.", "b" },
        .{ "가/나.png", "가", "나.png" },
    };
    for (cases) |c| {
        const s = try split(c[0]);
        errdefer std.debug.print("split {s}: dir '{s}' leaf '{s}'\n", .{ c[0], s.dir, s.leaf });
        try testing.expectEqualStrings(c[1], s.dir);
        try testing.expectEqualStrings(c[2], s.leaf);
    }
}

test "split: 폴더를 뜻하는 꼴·NUL·긴 이름은 거절, 255 바이트는 받는다" {
    for ([_][]const u8{ "", "/", "a/", ".", "..", "a/.", "a/..", "/tmp/" }) |p| {
        errdefer std.debug.print("split '{s}'\n", .{p});
        try testing.expectError(error.DirectoryPath, split(p));
    }
    try testing.expectError(error.BadPathName, split("a\x00b"));
    try testing.expectError(error.BadPathName, split("d\x00/b"));
    var long: [256]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(error.NameTooLong, split(&long));
    try testing.expectError(error.NameTooLong, split("/tmp/" ++ array_repeat.repeat("a", 256)));
    try testing.expectEqualStrings(long[0..255], (try split(long[0..255])).leaf);
    // 부모 부분이 길어도 여기서는 거절하지 않는다 — 여는 쪽(파일 시스템)이 그 까닭을 말한다.
    try testing.expectEqualStrings("x", (try split(array_repeat.repeat("b", 300) ++ "/x")).leaf);
}

test "under: 같거나 조각 경계에서 밑 — 이름 앞부분만 같은 형제는 아니다" {
    try testing.expect(under("/p", "/p"));
    try testing.expect(under("/p/a/b", "/p"));
    try testing.expect(!under("/pa", "/p"));
    try testing.expect(!under("/p", "/p/a"));
    try testing.expect(!under("/P/a", "/p")); // 철자가 다르면 거절 쪽
    try testing.expect(under("/x", "/"));
}

test "usableCwd·usableTemp: `/`·홈의 조상·상대 경로는 cwd 뿌리가 못 되고 홈 자체와 그 밑은 된다; 임시 폴더는 `/` 만 아니면" {
    const home = "/Users/me";
    try testing.expect(!usableCwd("/", home));
    try testing.expect(!usableCwd("/Users", home));
    try testing.expect(!usableCwd("/users", home)); // 대소문자 무시
    try testing.expect(!usableCwd("", home));
    try testing.expect(!usableCwd("rel/dir", home));
    try testing.expect(usableCwd("/Users/me", home));
    try testing.expect(usableCwd("/Users/me/proj", home));
    try testing.expect(usableCwd("/Users/meow", home)); // 앞부분만 같은 형제는 조상이 아니다
    try testing.expect(usableCwd("/private/tmp", home));
    try testing.expect(!usableCwd("/", null));
    try testing.expect(usableCwd("/private/tmp", null));
    try testing.expect(!usableTemp("/"));
    try testing.expect(!usableTemp(""));
    try testing.expect(!usableTemp("tmp"));
    try testing.expect(usableTemp("/private/tmp"));
}

test "judge: 뿌리 아래의 보이는 이름은 통과" {
    const places: Places = .{ .cwd = "/Users/me/proj", .temps = &.{ "/private/var/folders/x/T", "/private/tmp" }, .home = "/Users/me" };
    try judge("/Users/me/proj", "shot.png", places);
    try judge("/Users/me/proj/out/sub", "a.json", places);
    try judge("/private/var/folders/x/T/maru-shots", "home-1.png", places);
    try judge("/private/tmp", "t.json.gz", places);
    try judge("/Users/me/proj", "-", places);
    try judge("/Users/me/proj", "x.png.", places); // 점이 끝에 있는 것은 숨은 이름이 아니다
    try judge("/Users/me/proj", "\u{FF0E}zshrc", places); // 전각 점 — 셸이 읽는 이름이 아니다
}

test "judge: 뿌리 밖은 OutsideAllowed — 형제·조상·홈·다른 볼륨" {
    const places: Places = .{ .cwd = "/Users/me/proj", .temps = &.{"/private/tmp"}, .home = "/Users/me" };
    for ([_][]const u8{ "/Users/me", "/Users/me/projx", "/Users/me/Library/LaunchAgents", "/", "/usr/bin", "/dev", "/private", "/Volumes/usb", "/private/tmpx" }) |p| {
        errdefer std.debug.print("outside {s}\n", .{p});
        try testing.expectError(error.OutsideAllowed, judge(p, "x", places));
    }
    // 뿌리가 없으면 아무 데도 못 쓴다.
    try testing.expectError(error.OutsideAllowed, judge("/private/tmp", "x", .{ .home = "/Users/me" }));
}

test "judge: 쓸 수 없는 뿌리(cwd 가 `/`·홈의 조상, 임시 폴더 `/`)는 무시한다 — cwd 가 `/` 여도 `/opt/homebrew` 에 못 쓴다" {
    const home = "/Users/me";
    try testing.expectError(error.OutsideAllowed, judge("/opt/homebrew/etc", "x.conf", .{ .cwd = "/", .home = home }));
    try testing.expectError(error.OutsideAllowed, judge("/Users/other", "x", .{ .cwd = "/Users", .home = home }));
    try testing.expectError(error.OutsideAllowed, judge("/opt/homebrew/etc", "x.conf", .{ .temps = &.{"/"}, .home = home }));
    // 같은 자리라도 다른 쓸 수 있는 뿌리가 덮으면 통과.
    try judge("/private/tmp", "x", .{ .cwd = "/", .temps = &.{"/private/tmp"}, .home = home });
    // 홈이 임시 폴더 아래인 격리 환경(CI): cwd 는 홈의 조상이라 못 쓰지만 임시 폴더가 덮는다 — 홈 안은 여전히 숨은 규칙.
    const iso: Places = .{ .cwd = "/private/tmp/r", .temps = &.{"/private/tmp"}, .home = "/private/tmp/r/home" };
    try judge("/private/tmp/r/sub", "x.png", iso);
    try testing.expectError(error.HiddenPath, judge("/private/tmp/r/home/Library/LaunchAgents", "x.plist", iso));
    try testing.expectError(error.HiddenPath, judge("/private/tmp/r/home", ".zshrc", iso));
}

test "judge: 숨은 조각 — 끝 이름, 뿌리 안의 폴더, 뿌리 자체 위의 폴더(전체 경로)" {
    const home = "/Users/me";
    const proj: Places = .{ .cwd = "/Users/me/proj", .home = home };
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj", ".envrc", proj));
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj", ".ZSHRC", proj));
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj/.claude", "settings.local.json", proj));
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj/.git/hooks", "pre-commit", proj));
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj/a/.b/c", "x", proj));
    // `cd .claude` 뒤 — 뿌리 자체가 숨은 폴더 아래다(전체 경로를 본다).
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj/.claude", "settings.local.json", .{ .cwd = "/Users/me/proj/.claude", .home = home }));
    try testing.expectError(error.HiddenPath, judge("/Users/me/proj/.claude/worktrees/x", "shot.png", .{ .cwd = "/Users/me/proj/.claude/worktrees/x", .home = home }));
    // 임시 폴더 안도 같다.
    try testing.expectError(error.HiddenPath, judge("/private/tmp/.X11-unix", "x", .{ .temps = &.{"/private/tmp"}, .home = home }));
}

test "judge: cwd 가 홈이면 dotfile·~/Library 는 거절, 보이는 폴더는 통과" {
    const home = "/Users/me";
    const at_home: Places = .{ .cwd = home, .home = home };
    for ([_]struct { []const u8, []const u8 }{
        .{ home, ".zshrc" },
        .{ home, ".zshenv" },
        .{ "/Users/me/.config/fish/conf.d", "x.fish" },
        .{ "/Users/me/.ssh", "authorized_keys" },
        .{ "/Users/me/.claude/commands", "x.md" },
        .{ "/Users/me/Library/LaunchAgents", "x.plist" },
        .{ "/Users/me/Library", "x" },
        .{ "/Users/me/LIBRARY/LaunchAgents", "x.plist" }, // 대소문자 무시(APFS)
        .{ "/Users/me/library/Application Support/x", "y" },
        .{ "/users/ME/Library/LaunchAgents", "x.plist" }, // 홈 철자도 대소문자 무시
    }) |c| {
        errdefer std.debug.print("hidden {s}/{s}\n", .{ c[0], c[1] });
        // 뿌리는 철자 그대로 견주므로 철자가 다른 경우에는 뿌리도 그 철자로 준다(정규 경로라면 같은 철자다).
        try testing.expectError(error.HiddenPath, judge(c[0], c[1], .{ .cwd = c[0][0..home.len], .home = home }));
    }
    try judge(home, "shot.png", at_home);
    try judge("/Users/me/Desktop", "shot.png", at_home);
    try judge("/Users/me/Documents/LibraryNotes", "x", at_home); // `Library` 는 홈 바로 밑만
    try judge("/Users/me/proj/Library", "x", at_home);
    try judge("/Users/me/Libraryx", "x", at_home);
    // 홈을 모르면 Library 규칙은 건너뛰지만 점 규칙은 그대로다.
    try judge("/Users/me/Library/LaunchAgents", "x.plist", .{ .cwd = home });
    try testing.expectError(error.HiddenPath, judge(home, ".zshrc", .{ .cwd = home }));
}

test "judge: 뿌리 밖과 숨은 이름이 겹치면 「밖」 을 먼저 말한다" {
    try testing.expectError(error.OutsideAllowed, judge("/Users/me", ".zshrc", .{ .cwd = "/Users/me/proj", .home = "/Users/me" }));
}

test "errorText: 까닭마다 한 줄, 새 규칙은 $TMPDIR 또는 새 이름을 안내한다" {
    const lines = [_]struct { anyerror, []const u8 }{
        .{ error.OutputExists, "new name" },
        .{ error.OutsideAllowed, "$TMPDIR" },
        .{ error.HiddenPath, "$TMPDIR" },
        .{ error.FileNotFound, "$TMPDIR" },
        .{ error.IsDir, "is a directory" },
        .{ error.DirectoryPath, "names a directory" },
        .{ error.OutputIsSymLink, "symbolic link" },
        .{ error.NotDir, "not a directory" },
        .{ error.BadPathName, "valid file name" },
        .{ error.NameTooLong, "too long" },
        .{ error.SymLinkLoop, "loops" },
        .{ error.AccessDenied, "permission denied" },
        .{ error.PermissionDenied, "permission denied" },
        .{ error.NoSpaceLeft, "atomically" },
    };
    for (lines) |l| {
        const t = errorText(l[0]);
        errdefer std.debug.print("{s}: {s}\n", .{ @errorName(l[0]), t });
        try testing.expect(std.mem.startsWith(u8, t, "cannot "));
        try testing.expect(std.mem.indexOf(u8, t, l[1]) != null);
        try testing.expect(std.mem.indexOfScalar(u8, t, '\n') == null);
        for (t) |b| try testing.expect(b < 0xEA or b > 0xED); // 영어(한글의 첫 바이트 0xEA..0xED 가 없다)
    }
}
