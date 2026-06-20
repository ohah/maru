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
//! 이식성/clean-room: 순수 std + embed만. 캐시 경로는 현재 `$HOME/.cache/maru/terminfo`로 둔다(다른 maru
//! 캐시 ssh-terminfo-hosts·shell-integration은 $XDG_CACHE_HOME을 따르는데 이 캐시만 아직 아니다 — 경로를
//! 옮기면 기존 캐시가 orphan 되므로 통일은 별도 후속으로 두고, 여기선 pty/cli가 같은 경로를 쓰게만 한다).

const std = @import("std");

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

/// 캐시 디렉터리 절대 경로(`<home>/.cache/maru/terminfo`). 자식 셸에 `TERMINFO=<이 값>`으로 주거나
/// 사용자에게 보여줄 때 쓴다. 아래 셸 명령의 `$HOME/.cache/maru/terminfo`와 **반드시 같은 경로**여야
/// 한다(셸은 $HOME을, 이 함수는 인자 home을 쓰되 둘 다 같은 결과). caller가 free한다.
pub fn cacheDirZ(allocator: std.mem.Allocator, home: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/.cache/maru/terminfo", .{home}, 0);
}

// 캐시에 embed 소스를 컴파일하는 셸 명령의 공통 꼬리: 디렉터리를 비우고 다시 만들고 tic로 컴파일한 뒤
// 성공하면 버전 마커를 쓴다. 마지막 infocmp의 exit code가 "xterm-maru가 해석되는가"를 돌려준다(호출자가
// 성공/폴백 판정). {{ }}는 Zig fmt에서 literal 중괄호. `printf '%s'`는 %를 해석하지 않아 소스의 %가 안전.
const compile_tail =
    "rm -rf \"$d\"; mkdir -p \"$d\"; printf '%s' '{s}' | tic -x -o \"$d\" -{s} && printf '%s' \"$v\" > \"$d/.maru-version\"; " ++
    "TERMINFO=\"$d\" infocmp " ++ term_name ++ " >/dev/null 2>&1";

/// spawn 자동 컴파일 명령: 마커가 현재 버전과 일치하고 xterm-maru가 이미 해석되면 즉시 성공(재컴파일
/// skip), 아니면 캐시를 재컴파일한다. tic 오류는 버린다(조용히 폴백). caller가 free한다.
pub fn autoCompileCommand(allocator: std.mem.Allocator, ver: u64) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "d=\"$HOME/.cache/maru/terminfo\"; v=\"{x}\"; " ++
            "{{ [ \"$(cat \"$d/.maru-version\" 2>/dev/null)\" = \"$v\" ] && TERMINFO=\"$d\" infocmp " ++ term_name ++ " >/dev/null 2>&1; }} && exit 0; " ++
            compile_tail,
        .{ ver, source, " 2>/dev/null" },
        0,
    );
}

/// `maru terminfo --refresh` 강제 재컴파일 명령: skip 없이 항상 캐시를 비우고 다시 컴파일한다. tic의
/// 출력(경고/오류)은 사용자가 보도록 그대로 흘린다(`2>/dev/null` 없음). caller가 free한다.
pub fn refreshCommand(allocator: std.mem.Allocator, ver: u64) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "d=\"$HOME/.cache/maru/terminfo\"; v=\"{x}\"; " ++ compile_tail,
        .{ ver, source, "" },
        0,
    );
}

/// `maru terminfo --clear` 삭제 명령: 캐시 디렉터리를 통째로 지운다(다음 spawn이 다시 컴파일). caller가 free.
pub fn clearCommand(allocator: std.mem.Allocator) ![:0]u8 {
    return allocator.dupeZ(u8, "rm -rf \"$HOME/.cache/maru/terminfo\"");
}

/// 상태 조회: 캐시에서 xterm-maru가 해석되는지 검사하는 명령(exit 0이면 컴파일됨). caller가 free.
pub fn statusCommand(allocator: std.mem.Allocator) ![:0]u8 {
    return allocator.dupeZ(u8, "TERMINFO=\"$HOME/.cache/maru/terminfo\" infocmp " ++ term_name ++ " >/dev/null 2>&1");
}

test "version is deterministic and nonzero" {
    try std.testing.expect(version() != 0);
    try std.testing.expectEqual(version(), version()); // 같은 입력 → 같은 지문
}

test "cacheDirZ joins home with the fixed maru cache subpath" {
    const a = std.testing.allocator;
    const d = try cacheDirZ(a, "/Users/me");
    defer a.free(d);
    try std.testing.expectEqualStrings("/Users/me/.cache/maru/terminfo", d);
}

test "autoCompileCommand skips when marker matches; refreshCommand always recompiles" {
    const a = std.testing.allocator;
    const auto = try autoCompileCommand(a, 0x1234);
    defer a.free(auto);
    const refresh = try refreshCommand(a, 0x1234);
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
