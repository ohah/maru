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

// ── Windows 지원 (W10) ──────────────────────────────────────────────────────────────────────
//
// **`os_tag` 를 인자로 받는다.** 이 저장소의 다른 OS-인지 술어들과 같은 이유다 — CI 에 Windows 러너가
// 없으므로 컴파일 타임 분기였다면 Windows 단언이 **공허참**이 된다(`user_paths.homeDirFor` 의 doc 이
// 그 선례를 적어 뒀다).

/// PATH 항목 구분자. **Windows 는 `;` 다** — `:` 로 가르면 `C:\Users\me\...` 가 드라이브 문자에서
/// 두 동강 나서, 어떤 항목과도 안 맞고 "PATH 에 없다" 는 안내가 늘 뜬다.
pub fn pathSeparatorFor(os_tag: std.Target.Os.Tag) u8 {
    return if (os_tag == .windows) ';' else ':';
}

/// CLI shim 을 둘 디렉터리. **Windows 는 `%LOCALAPPDATA%\maru\bin`** 이다.
///
/// `%LOCALAPPDATA%\Programs` 가 아니다 — 그쪽은 **설치된 응용 프로그램**의 자리이고 여기서 두는 것은
/// 실행 파일이 아니라 **shim** 한 장이다. `user_paths` 모듈 doc 이 *"Windows 에서는
/// `%LOCALAPPDATA%\maru\` 아래로 모은다 — config·캐시·런타임 전부"* 로 이미 정했고, 그 단일 출처를
/// 따르면 사용자가 지울 자리도 한 곳이다(계획 행의 `Programs?` 는 물음표였다).
///
/// `%LOCALAPPDATA%` 가 없는 비정상 환경에서는 **홈 아래로 폴백한다** — 경로가 아예 없는 것보다 낫다
/// (`defaultConfigPathFor` 가 같은 폴백을 쓴다).
pub fn binDirFor(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    home: ?[]const u8,
    localappdata: ?[]const u8,
) std.mem.Allocator.Error!?[:0]u8 {
    if (os_tag == .windows) {
        if (nonEmpty(localappdata)) |l|
            return try std.fmt.allocPrintSentinel(allocator, "{s}/maru/bin", .{trimSep(l)}, 0);
    }
    const h = nonEmpty(home) orelse return null;
    return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ trimSep(h), bin_subpath }, 0);
}

/// shim 파일 경로. **Windows 는 `maru.cmd`** 다 — symlink 는 개발자 모드나 관리자 권한이 필요해서
/// (`CreateSymbolicLink` 의 규약) 아무 계정에서나 되지 않는다. `.cmd` 는 권한이 필요 없고 `PATHEXT`
/// 기본값에 들어 있어 셸에서 `maru` 로 부를 수 있다.
pub fn shimPathFor(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    home: ?[]const u8,
    localappdata: ?[]const u8,
) std.mem.Allocator.Error!?[:0]u8 {
    const dir = try binDirFor(allocator, os_tag, home, localappdata) orelse return null;
    defer allocator.free(dir);
    const name = if (os_tag == .windows) "maru.cmd" else "maru";
    return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
}

/// `.cmd` shim 의 내용. caller 가 free 한다.
///
/// **`%*` 로 인자를 그대로 넘긴다** — 따옴표와 공백이 든 인자가 살아야 `maru ssh "a b"` 가 된다.
/// **`@echo off`** 가 없으면 실행할 때마다 명령 줄이 화면에 찍힌다.
/// **`""` 를 exe 경로에 두른다** — `C:\Program Files\...` 처럼 공백이 든 자리에서도 한 토큰이다.
pub fn cmdShimContents(allocator: std.mem.Allocator, exe_path: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "@echo off\r\n\"{s}\" %*\r\n", .{exe_path});
}

/// `PATH` 에 dir 가 포함되는가 — **OS 규칙대로**.
///
/// Windows 는 ⑴ 구분자가 `;` 이고 ⑵ 경로 비교가 **대소문자 무시**이며 ⑶ `/` 와 `\` 가 같은 구분자다.
/// 셋 중 하나만 빼도 이미 PATH 에 있는데 "추가하라" 는 안내가 뜬다.
pub fn pathContainsDirFor(os_tag: std.Target.Os.Tag, path_env: []const u8, dir: []const u8) bool {
    const sep = pathSeparatorFor(os_tag);
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \"");
        if (os_tag == .windows) {
            if (eqlWindowsPath(entry, dir)) return true;
        } else if (std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

/// Windows 경로 두 개가 같은가 — 대소문자 무시 + `/`·`\` 동일시 + 끝 구분자 무시.
fn eqlWindowsPath(a: []const u8, b: []const u8) bool {
    const x = trimSep(a);
    const y = trimSep(b);
    if (x.len != y.len) return false;
    for (x, y) |ca, cb| {
        if (normSep(std.ascii.toLower(ca)) != normSep(std.ascii.toLower(cb))) return false;
    }
    return true;
}

fn normSep(c: u8) u8 {
    return if (c == '\\') '/' else c;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

/// 끝의 구분자를 뗀다(하나만 남는 루트는 그대로 둔다).
fn trimSep(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and (s[end - 1] == '/' or s[end - 1] == '\\')) end -= 1;
    return s[0..end];
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

test "W10 위치: Windows 는 LOCALAPPDATA/maru/bin, POSIX 는 ~/.local/bin" {
    const a = std.testing.allocator;
    const w = (try binDirFor(a, .windows, "C:/Users/me", "C:/Users/me/AppData/Local")).?;
    defer a.free(w);
    try std.testing.expectEqualStrings("C:/Users/me/AppData/Local/maru/bin", w);
    // **끝 구분자가 있어도 두 번 안 겹친다.**
    const w2 = (try binDirFor(a, .windows, "C:/Users/me", "C:/Users/me/AppData/Local/")).?;
    defer a.free(w2);
    try std.testing.expectEqualStrings("C:/Users/me/AppData/Local/maru/bin", w2);
    // `%LOCALAPPDATA%` 가 없으면 홈으로 폴백한다 — 경로가 아예 없는 것보다 낫다.
    const wf = (try binDirFor(a, .windows, "C:/Users/me", null)).?;
    defer a.free(wf);
    try std.testing.expectEqualStrings("C:/Users/me/.local/bin", wf);
    // POSIX 는 예전 그대로다 — **회귀 0**.
    const p = (try binDirFor(a, .macos, "/Users/me", null)).?;
    defer a.free(p);
    try std.testing.expectEqualStrings("/Users/me/.local/bin", p);
    // 홈도 `%LOCALAPPDATA%` 도 없으면 자리를 못 정한다.
    try std.testing.expect((try binDirFor(a, .windows, null, null)) == null);
}

test "W10 shim: Windows 는 maru.cmd" {
    const a = std.testing.allocator;
    const w = (try shimPathFor(a, .windows, "C:/Users/me", "C:/Users/me/AppData/Local")).?;
    defer a.free(w);
    try std.testing.expectEqualStrings("C:/Users/me/AppData/Local/maru/bin/maru.cmd", w);
    const p = (try shimPathFor(a, .linux, "/home/me", null)).?;
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/me/.local/bin/maru", p);
}

test "W10 shim 내용: 인자를 그대로 넘기고 공백 든 경로를 감싼다" {
    const a = std.testing.allocator;
    const s = try cmdShimContents(a, "C:/Program Files/maru/maru.exe");
    defer a.free(s);
    // 실행할 때마다 명령 줄이 찍히면 안 된다.
    try std.testing.expect(std.mem.startsWith(u8, s, "@echo off"));
    // **`%*`** — 따옴표·공백이 든 인자가 살아야 `maru ssh "a b"` 가 된다.
    try std.testing.expect(std.mem.indexOf(u8, s, "%*") != null);
    // exe 경로가 따옴표 안이다.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"C:/Program Files/maru/maru.exe\"") != null);
    // `.cmd` 는 CRLF 다.
    try std.testing.expect(std.mem.indexOf(u8, s, "\r\n") != null);
}

test "W10 PATH: Windows 는 세미콜론·대소문자 무시·구분자 동일시" {
    const dir = "C:/Users/me/AppData/Local/maru/bin";
    // **여기가 결함이었다** — `:` 로 가르면 `C:` 에서 두 동강 나 어떤 항목과도 안 맞는다.
    try std.testing.expect(pathContainsDirFor(.windows, "C:/Windows;C:/Users/me/AppData/Local/maru/bin;C:/Git", dir));
    // Windows 경로 비교는 대소문자를 안 본다.
    try std.testing.expect(pathContainsDirFor(.windows, "C:/USERS/ME/APPDATA/LOCAL/MARU/BIN", dir));
    // `/` 와 `\` 는 같은 구분자다.
    try std.testing.expect(pathContainsDirFor(.windows, "C:\\Users\\me\\AppData\\Local\\maru\\bin", dir));
    // 끝 구분자와 따옴표는 무시한다(레지스트리 PATH 에 흔하다).
    try std.testing.expect(pathContainsDirFor(.windows, "\"C:/Users/me/AppData/Local/maru/bin/\"", dir));
    // 부분 일치는 아니다.
    try std.testing.expect(!pathContainsDirFor(.windows, "C:/Users/me/AppData/Local/maru/bin2", dir));
    try std.testing.expect(!pathContainsDirFor(.windows, "C:/Windows;C:/Git", dir));
    // POSIX 는 예전 규칙 그대로 — 대소문자를 본다.
    const pd = "/Users/me/.local/bin";
    try std.testing.expect(pathContainsDirFor(.macos, "/usr/bin:/Users/me/.local/bin", pd));
    try std.testing.expect(!pathContainsDirFor(.macos, "/usr/bin:/USERS/ME/.LOCAL/BIN", pd));
    // POSIX 에서 `;` 는 구분자가 아니다.
    try std.testing.expect(!pathContainsDirFor(.macos, "/usr/bin;/Users/me/.local/bin", pd));
}
