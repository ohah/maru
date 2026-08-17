//! maru 자체 terminfo 로컬 캐시의 단일 출처 — 경로·이름·버전·컴파일 셸 명령을 두 호출자가 공유한다:
//!  1) `pty/macos.zig`가 자식 셸 spawn 시 자동 컴파일(TERM=xterm-maru면 캐시에 tic, 안 되면 폴백),
//!  2) `cli/terminfo.zig`(`maru terminfo` 서브커맨드)가 상태 조회·강제 재컴파일·삭제.
//!
//! 왜 공유하나: 두 곳이 같은 캐시 디렉터리·같은 버전 마커를 써야, 서브커맨드로 재컴파일한 결과를
//! spawn이 그대로 재사용하고(마커 일치 → 재컴파일 skip) 어긋나지 않는다. terminfo/maru.terminfo가
//! 단일 출처이고, 그 내용이 바뀌면 version()이 바뀌어 **다음 spawn이 stale 캐시를 자동 재컴파일**한다
//! (예전엔 한 번 컴파일되면 infocmp가 해석되는 한 영영 안 바꿔, terminfo 캡을 늘려도 기존 사용자
//! 캐시에 반영되지 않는 footgun이 있었다).
//!
//! 이식성/clean-room: 순수 std + embed만. **경로 해석기는 하나다** — `cacheDirZ`가 정한 값을 셸 명령에
//! 리터럴로 넘긴다(`shSingleQuote`). 예전에는 셸이 `${XDG_CACHE_HOME:-$HOME/.cache}`로 **다시 확장**해서
//! 규칙이 둘이었고, 그러면 base 규칙을 OS별로 바꿀 때 조용히 갈린다(계약 §5.3의 Windows 레이아웃).
//! base 자체는 `user_paths.cacheBaseFor`가 정한다.

const std = @import("std");
const path_shape = @import("path_shape.zig"); // 후행 구분자 다듬기의 단일 출처(다섯 파일에 복제돼 있었다)

/// 자식 셸에 줄 TERM 이름(= XTVERSION 자기식별 이름과 일치). terminfo primary 이름이기도 하다.
pub const term_name = "xterm-maru";

// terminfo 소스를 바이너리에 embed(빌드 import `maru_terminfo`; terminfo/maru.terminfo가 단일 출처).
// 아래 셸 명령이 `printf '%s' '<소스>'`로 작은따옴표 안에 인라인하므로 소스에 작은따옴표가 없어야 한다 —
// comptime으로 못박는다(있으면 빌드 실패). cli/ssh.zig도 같은 인라인을 쓰며 같은 가드를 둔다.
pub const source = @embedFile("maru_terminfo");
comptime {
    @setEvalBranchQuota(source.len + 100);
    for (source) |c| if (c == '\'') @compileError("maru terminfo 소스에 작은따옴표(')가 있으면 셸 인라인이 깨진다");
}

/// embed된 terminfo 내용의 버전 지문(FNV-1a 64bit). 내용이 한 바이트라도 바뀌면 값이 바뀐다. 캐시
/// 디렉터리에 `.maru-version`으로 적어 두고, spawn 때 이 값과 일치하고 xterm-maru가 해석되면 재컴파일을
/// 건너뛴다 — 일치하지 않으면(업데이트로 캡이 바뀜·마커 없음) 자동 재컴파일한다. 두 호출자가 같은 함수를
/// 써야 마커가 어긋나지 않으므로 여기 단일 출처로 둔다.
pub fn version() u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (source) |b| {
        h ^= b;
        h *%= 0x100000001b3; // FNV prime
    }
    return h;
}

/// 캐시 디렉터리 절대 경로. 자식 셸에 `TERMINFO=<이 값>`으로 주거나 사용자에게 보여줄 때 쓴다.
/// `base`(= `xdg_cache_home` 자리)가 있으면 `<base>/maru/terminfo`, 없으면 `<home>/.cache/maru/terminfo`다.
///
/// **`base`에 무엇이 오는지는 `user_paths.cacheBaseFor`가 정한다** — `$XDG_CACHE_HOME`이 모든 OS에서
/// 최우선이고, Windows에서는 그 다음이 `%LOCALAPPDATA%`다(계약 §5.3). 이 함수는 그 판정을 모른다.
/// 셸 명령은 이 함수의 결과를 **리터럴로** 받으므로 두 경로가 갈릴 수 없다. caller가 free한다.
pub fn cacheDirZ(allocator: std.mem.Allocator, xdg_cache_home: ?[]const u8, home: []const u8) ![:0]u8 {
    if (xdg_cache_home) |x| {
        if (x.len > 0) return std.fmt.allocPrintSentinel(allocator, "{s}/maru/terminfo", .{path_shape.trimTrailingSep(x)}, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "{s}/.cache/maru/terminfo", .{path_shape.trimTrailingSep(home)}, 0);
}

/// 셸 토큰 하나를 **작은따옴표로 감싸** 문자 그대로 넘긴다(POSIX 규칙: 내부 `'`는 `'\''`로 끊는다).
/// caller가 free한다.
///
/// **왜 필요한가.** 예전에는 명령이 `${XDG_CACHE_HOME:-$HOME/.cache}/maru/terminfo`라는 **셸 파라미터
/// 확장**을 그대로 담았다. 그러면 경로를 정하는 규칙이 둘(Zig `cacheDirZ` · 셸 문자열)이 되고, 둘이
/// 어긋나면 조용히 갈린다 — `pty/macos.zig`가 `cacheDirZ`로 dir을 구해 놓고 셸에는 다시 확장시키는
/// 중복이 실제로 있었다. 이제 **Zig가 한 번 정한 경로를 리터럴로 넘긴다.** 그 대가로 값을 셸에서 안전하게
/// 인용해야 하는데(경로에 공백·`$`·`` ` ``가 있을 수 있다), 작은따옴표는 NUL 말고 모든 바이트에 안전하다.
/// `pty/macos.zig`가 `exec -l` 토큰에 쓰는 것과 같은 규칙이다.
pub fn shSingleQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

// 캐시에 embed 소스를 컴파일하는 셸 명령의 공통 꼬리: 디렉터리를 비우고 다시 만들고 tic로 컴파일한 뒤
// 성공하면 버전 마커를 쓴다. 마지막 infocmp의 exit code가 "xterm-maru가 해석되는가"를 돌려준다(호출자가
// 성공/폴백 판정). {{ }}는 Zig fmt에서 literal 중괄호. `printf '%s'`는 %를 해석하지 않아 소스의 %가 안전.
const compile_tail =
    "rm -rf \"$d\"; mkdir -p \"$d\"; printf '%s' '{s}' | tic -x -o \"$d\" -{s} && printf '%s' \"$v\" > \"$d/.maru-version\"; " ++
    "TERMINFO=\"$d\" infocmp " ++ term_name ++ " >/dev/null 2>&1";

/// spawn 자동 컴파일 명령: 마커가 현재 버전과 일치하고 xterm-maru가 이미 해석되면 즉시 성공(재컴파일
/// skip), 아니면 캐시를 재컴파일한다. tic 오류는 버린다(조용히 폴백). caller가 free한다.
pub fn autoCompileCommand(allocator: std.mem.Allocator, dir: []const u8, ver: u64) ![:0]u8 {
    const quoted = try shSingleQuote(allocator, dir);
    defer allocator.free(quoted);
    // 셸 `{ ...; }` 그룹의 중괄호만 format string에서 `{{ }}`로 이스케이프한다.
    return std.fmt.allocPrintSentinel(
        allocator,
        "d={s}; v=\"{x}\"; " ++
            "{{ [ \"$(cat \"$d/.maru-version\" 2>/dev/null)\" = \"$v\" ] && TERMINFO=\"$d\" infocmp " ++ term_name ++ " >/dev/null 2>&1; }} && exit 0; " ++
            compile_tail,
        .{ quoted, ver, source, " 2>/dev/null" },
        0,
    );
}

/// `maru terminfo --refresh` 강제 재컴파일 명령: skip 없이 항상 캐시를 비우고 다시 컴파일한다. tic의
/// 출력(경고/오류)은 사용자가 보도록 그대로 흘린다(`2>/dev/null` 없음). caller가 free한다.
pub fn refreshCommand(allocator: std.mem.Allocator, dir: []const u8, ver: u64) ![:0]u8 {
    const quoted = try shSingleQuote(allocator, dir);
    defer allocator.free(quoted);
    return std.fmt.allocPrintSentinel(
        allocator,
        "d={s}; v=\"{x}\"; " ++ compile_tail,
        .{ quoted, ver, source, "" },
        0,
    );
}

/// `maru terminfo --clear` 삭제 명령: 캐시 디렉터리를 통째로 지운다(다음 spawn이 다시 컴파일). caller가 free.
pub fn clearCommand(allocator: std.mem.Allocator, dir: []const u8) ![:0]u8 {
    const quoted = try shSingleQuote(allocator, dir);
    defer allocator.free(quoted);
    return std.fmt.allocPrintSentinel(allocator, "rm -rf {s}", .{quoted}, 0);
}

/// 상태 조회: 캐시에서 xterm-maru가 해석되는지 검사하는 명령(exit 0이면 컴파일됨). caller가 free.
pub fn statusCommand(allocator: std.mem.Allocator, dir: []const u8) ![:0]u8 {
    const quoted = try shSingleQuote(allocator, dir);
    defer allocator.free(quoted);
    return std.fmt.allocPrintSentinel(allocator, "TERMINFO={s} infocmp " ++ term_name ++ " >/dev/null 2>&1", .{quoted}, 0);
}

test "version is deterministic and nonzero" {
    try std.testing.expect(version() != 0);
    try std.testing.expectEqual(version(), version()); // 같은 입력 → 같은 지문
}

// 입구 정규화(W3) 뒤에도 base가 `/`로 끝날 수 있고, 그때 이 함수만 이중 슬래시를 냈다 —
// `cli/sessions.zig`의 컨트롤 디렉터리 조립은 다듬고 있었다. 두 조립기가 같은 답을 내야 한다.
test "cacheDirZ: 후행 슬래시가 이중이 되지 않는다(컨트롤 디렉터리 조립과 같은 규칙)" {
    const a = std.testing.allocator;
    const cases = [_]struct { home: []const u8, want: []const u8 }{
        .{ .home = "C:/Users/me/", .want = "C:/Users/me/.cache/maru/terminfo" },
        .{ .home = "/Users/me/", .want = "/Users/me/.cache/maru/terminfo" },
        // 드라이브 루트: 떼도 `C:` + `/`로 다시 이어져 **절대경로로 남는다**.
        .{ .home = "C:/", .want = "C:/.cache/maru/terminfo" },
        // 길이 1(`/`)은 떼지 않는다 — 떼면 빈 문자열이라 상대 경로가 된다.
        .{ .home = "/", .want = "//.cache/maru/terminfo" },
    };
    for (cases) |c| {
        const d = try cacheDirZ(a, null, c.home);
        defer a.free(d);
        try std.testing.expectEqualStrings(c.want, d);
    }
    // XDG 쪽도 같은 규칙이다.
    const x = try cacheDirZ(a, "D:/cache/", "C:/Users/me");
    defer a.free(x);
    try std.testing.expectEqualStrings("D:/cache/maru/terminfo", x);
}

test "cacheDirZ honors XDG_CACHE_HOME else $HOME/.cache (matches shell ${XDG_CACHE_HOME:-$HOME/.cache})" {
    const a = std.testing.allocator;
    {
        const d = try cacheDirZ(a, null, "/Users/me"); // XDG 미설정 → $HOME/.cache
        defer a.free(d);
        try std.testing.expectEqualStrings("/Users/me/.cache/maru/terminfo", d);
    }
    {
        const d = try cacheDirZ(a, "", "/Users/me"); // XDG 빈 문자열 → :-와 동일하게 fallback
        defer a.free(d);
        try std.testing.expectEqualStrings("/Users/me/.cache/maru/terminfo", d);
    }
    {
        const d = try cacheDirZ(a, "/tmp/xdg", "/Users/me"); // XDG 설정 → <xdg>/maru/terminfo
        defer a.free(d);
        try std.testing.expectEqualStrings("/tmp/xdg/maru/terminfo", d);
    }
}

// **해석기가 하나임을 고정한다.** 셸 명령은 경로를 다시 확장하지 않고 `cacheDirZ`가 준 값을 그대로 받는다 —
// 예전에는 셸이 `${XDG_CACHE_HOME:-$HOME/.cache}`로 재확장해서 규칙이 둘이었고, Windows base를 옮기는 순간
// 조용히 갈렸을 것이다.
test "셸 명령은 경로를 재확장하지 않고 준 값을 그대로 쓴다" {
    const a = std.testing.allocator;
    const dir = "C:/Users/me/AppData/Local/maru/terminfo";
    inline for (.{ "auto", "refresh", "clear", "status" }) |which| {
        const cmd = switch (@as(u8, which[0])) {
            'a' => try autoCompileCommand(a, dir, 0x1234),
            'r' => try refreshCommand(a, dir, 0x1234),
            'c' => try clearCommand(a, dir),
            else => try statusCommand(a, dir),
        };
        defer a.free(cmd);
        try std.testing.expect(std.mem.indexOf(u8, cmd, dir) != null);
        try std.testing.expect(std.mem.indexOf(u8, cmd, "XDG_CACHE_HOME") == null);
        try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME") == null);
    }
}

// 경로에 셸 메타문자가 있어도 문자 그대로 간다. Windows 사용자명에 공백은 흔하고, `$`도 파일명에 쓸 수 있다.
test "shSingleQuote: 공백·$·따옴표가 든 경로가 문자 그대로 간다" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "C:/Users/a b/x", .want = "'C:/Users/a b/x'" },
        .{ .in = "/tmp/$HOME/x", .want = "'/tmp/$HOME/x'" },
        .{ .in = "/tmp/it's/x", .want = "'/tmp/it'\\''s/x'" },
        .{ .in = "/tmp/`id`/x", .want = "'/tmp/`id`/x'" },
    };
    for (cases) |c| {
        const q = try shSingleQuote(a, c.in);
        defer a.free(q);
        try std.testing.expectEqualStrings(c.want, q);
    }
}

test "autoCompileCommand skips when marker matches; refreshCommand always recompiles" {
    const a = std.testing.allocator;
    const auto = try autoCompileCommand(a, "/tmp/c/maru/terminfo", 0x1234);
    defer a.free(auto);
    const refresh = try refreshCommand(a, "/tmp/c/maru/terminfo", 0x1234);
    defer a.free(refresh);
    // auto는 마커 일치+해석 시 즉시 성공(skip), refresh는 그 조기 종료가 없다.
    try std.testing.expect(std.mem.indexOf(u8, auto, "&& exit 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "&& exit 0;") == null);
    // 둘 다 같은 버전 마커(0x1234 hex)를 쓰고, tic로 캐시를 컴파일하고, xterm-maru 해석을 확인한다.
    try std.testing.expect(std.mem.indexOf(u8, auto, "v=\"1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "v=\"1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "tic -x -o") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, ".maru-version") != null);
    // auto는 tic 오류를 버리고(2>/dev/null), refresh는 사용자에게 보인다(없음).
    try std.testing.expect(std.mem.indexOf(u8, auto, "tic -x -o \"$d\" - 2>/dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "tic -x -o \"$d\" - &&") != null);
}
