//! 경로 **모양** 판정 — 절대인가, 루트인가, 어디가 구분자인가. OS-중립 최상위 유틸이다(`width.zig` 선례).
//!
//! **왜 별도 모듈인가**: 이 판정이 필요한 곳이 L1(`terminal/selection.zig` 링크 감지)과 L2(`session/*`
//! 경로 가드) 양쪽에 있는데 L1은 L2를 import할 수 없다. 그래서 둘 다 닿는 최상위에 둔다.
//!
//! **왜 `path[0] == '/'`로 충분하지 않은가**: 그 판정은 POSIX 절대경로만 안다. Windows에는 드라이브 절대
//! (`C:\x`·`C:/x`)와 UNC(`\\server\share`)가 있고, 이들은 `/`로 시작하지 않는다. 그래서 "절대경로를 거부한다"는
//! 가드가 Windows 경로를 **상대경로로 통과**시킨다(docs/windows-platform.md §5).
//!
//! **`std.fs.path.isAbsolute`를 쓰지 않는 이유**: 그것은 **호스트 native** 판정이라 macOS에서 `C:\x`를 상대로
//! 본다. 이 모듈이 답해야 하는 질문은 "이 호스트에서 절대인가"가 아니라 **"어떤 OS의 절대경로 모양이라도
//! 되는가"** 다 — 가드는 자기 호스트가 모르는 모양도 막아야 하고, 터미널은 원격이 보낸 경로도 본다.

const std = @import("std");

/// 경로 구분자인가. Windows는 둘 다 구분자로 받고, POSIX 경로에서 `\`는 파일명에 쓸 수 있지만 이 모듈의
/// 소비자(가드·링크 감지)는 **보수적인 쪽**이 맞다 — 구분자일 수 있는 문자를 아니라고 단정하면 뚫린다.
pub fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// `C:` 같은 드라이브 지정자로 시작하는가(길이 2 이상, 첫 글자가 ASCII letter, 둘째가 `:`).
fn hasDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

/// **어떤 OS의 절대경로 모양이라도** 되는가.
///
/// - POSIX: `/x`
/// - Windows 드라이브 절대: `C:\x`, `C:/x`
/// - Windows 드라이브 상대: `C:x` — **절대로 친다.** 진짜 절대는 아니지만 "루트 기준 상대경로"도 아니라서,
///   이걸 상대로 통과시키면 `<root>/C:x`처럼 뜻이 없는 경로가 만들어지고 Windows에서는 드라이브의 *현재*
///   디렉터리로 해석돼 예측 불가가 된다. 가드는 이 모양을 받지 않는 편이 안전하다.
/// - UNC/네트워크: `\\server\share`, `//server/share`
pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (isSep(path[0])) return true; // POSIX 절대 + UNC(`//`·`\\`)를 함께 덮는다
    return hasDrivePrefix(path);
}

/// 터미널 화면의 토큰을 **열 수 있는 절대경로 링크로 감지할 것인가**. `isAbsolute`와 **일부러 다르다.**
///
/// **가드와 감지는 질문이 다르다.** 가드(`isAbsolute`)는 "이 문자열이 **어떤 OS에서든** 위험한가"를 묻는다 —
/// 문자열을 공격자가 고르므로 모양이 조금이라도 절대 같으면 거부해야 한다. 감지는 "이 문자열이 **이 호스트에서**
/// 실제로 열리는 경로인가"를 묻는다 — 답을 호스트가 정하므로 넓게 잡으면 곧바로 오탐(밑줄)이 된다.
///
/// **왜 컴파일 타임 OS 분기인가**: 감지 결과(밑줄 span)는 **콘텐츠를 가진 쪽**에서 만들어진다. 로컬은 물론
/// 원격 세션도 host가 `selection.collectViewportLinks`로 span을 모아 client에 보낸다. 그래서 "이 바이너리가
/// 도는 OS"가 곧 "그 경로가 실재할 수 있는 OS"다. VS Code도 같은 규칙을 런타임 값으로 구현한다 —
/// `detectLinks(text, this._processManager.os || OS)`는 클라이언트가 아니라 **백엔드/PTY의 OS**를 쓴다.
///
/// **왜 `isAbsolute`보다 좁은가**(실측, docs/windows-platform.md §5): 감지한 토큰은 곧바로
/// `TerminalCore.resolveClickedPath`로 가고 거기서 `std.fs.path.isAbsolute`가 거짓이면 **cwd에 join**된다.
/// 감지가 그보다 넓으면 "밑줄은 뜨는데 엉뚱한 경로를 연다"가 된다. Windows에서 잰 불일치는 이렇다:
///
/// - `a:b`, `C:relative` — `hasDrivePrefix`는 참이지만 `std.fs.path.isAbsolute`는 **거짓**. 그래서
///   드라이브 뒤에 **구분자를 요구**한다(`C:\x`·`C:/x`). VS Code의 `winDrivePrefix`도 같은 모양이다.
/// - `\foo\bar` — `isAbsolute`는 참이지만 `resolve`가 드라이브 없는 `\foo\bar`를 낸다. 게다가 이스케이프된
///   출력(`\n` 등)과 구별이 안 돼 오탐이 크다. 감지하지 않는다.
/// - UNC(`\\server\share`) — 진짜 절대지만 위와 같은 이스케이프 오탐 위험이 있고 터미널 출력에서 드물다.
///   VS Code도 `\\?\C:` 확장형만 다룬다. **지금은 감지하지 않는다**(알려진 공백).
pub fn isDetectableAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true; // POSIX 절대 — 모든 호스트에서 오늘과 같은 동작
    if (@import("builtin").os.tag != .windows) return false;
    return path.len >= 3 and hasDrivePrefix(path) and isSep(path[2]);
}

/// 경로가 **루트 자체**인가 — 그 아래를 이어 붙일 때 구분자를 하나 더 넣으면 안 되는 모양.
/// `/`, `C:\`, `C:/`, `C:`가 해당한다.
pub fn isRoot(path: []const u8) bool {
    if (path.len == 1 and isSep(path[0])) return true; // "/"
    if (path.len == 2 and hasDrivePrefix(path)) return true; // "C:"
    if (path.len == 3 and hasDrivePrefix(path) and isSep(path[2])) return true; // "C:\" · "C:/"
    return false;
}

test "isSep: 두 구분자를 모두 본다" {
    try std.testing.expect(isSep('/'));
    try std.testing.expect(isSep('\\'));
    try std.testing.expect(!isSep('a'));
    try std.testing.expect(!isSep(':'));
}

test "isAbsolute: POSIX·드라이브·UNC를 모두 절대로 본다" {
    // POSIX
    try std.testing.expect(isAbsolute("/usr/bin"));
    try std.testing.expect(isAbsolute("/"));
    // Windows 드라이브 절대(두 구분자 모두)
    try std.testing.expect(isAbsolute("C:\\Users\\me"));
    try std.testing.expect(isAbsolute("C:/Users/me"));
    try std.testing.expect(isAbsolute("z:/lower"));
    // 드라이브 상대 — 상대로 통과시키면 안 되므로 절대로 친다
    try std.testing.expect(isAbsolute("C:x"));
    try std.testing.expect(isAbsolute("C:"));
    // UNC
    try std.testing.expect(isAbsolute("\\\\server\\share"));
    try std.testing.expect(isAbsolute("//server/share"));

    // 상대는 상대다
    try std.testing.expect(!isAbsolute(""));
    try std.testing.expect(!isAbsolute("src/main.zig"));
    try std.testing.expect(!isAbsolute("./x"));
    try std.testing.expect(!isAbsolute("../x"));
    try std.testing.expect(!isAbsolute("C"));
    try std.testing.expect(!isAbsolute("1:/not-a-drive")); // 드라이브 문자는 letter여야 한다
    try std.testing.expect(!isAbsolute("CC:/two-letters"));
}

// 감지 술어는 **호스트 native**다(가드와 반대). 그리고 `std.fs.path.isAbsolute`가 절대로 인정하는 범위
// 안쪽이어야 한다 — 넘어가면 resolveClickedPath가 cwd에 join해 엉뚱한 경로를 연다(위 doc 주석의 실측).
test "isDetectableAbsolute: 호스트 OS 기준이고 resolve가 인정하는 범위를 넘지 않는다" {
    const windows = @import("builtin").os.tag == .windows;

    // POSIX 절대는 어느 호스트에서나 오늘과 같이 감지한다(동작 불변).
    try std.testing.expect(isDetectableAbsolute("/usr/bin/zig"));
    try std.testing.expect(isDetectableAbsolute("/"));

    // 드라이브 절대 — Windows에서만 감지한다.
    try std.testing.expectEqual(windows, isDetectableAbsolute("C:\\Users\\me\\a.zig"));
    try std.testing.expectEqual(windows, isDetectableAbsolute("C:/Users/me/a.zig"));
    try std.testing.expectEqual(windows, isDetectableAbsolute("z:\\lower"));
    try std.testing.expectEqual(windows, isDetectableAbsolute("C:\\")); // 드라이브 루트(POSIX `/`와 대칭)

    // 어느 호스트에서도 감지하지 않는 모양들 — 각각 이유가 다르다.
    try std.testing.expect(!isDetectableAbsolute("")); // 빈 토큰
    try std.testing.expect(!isDetectableAbsolute("a:b")); // isAbsolute=false → cwd join 오작동
    try std.testing.expect(!isDetectableAbsolute("C:relative")); // 같은 이유(드라이브 상대)
    try std.testing.expect(!isDetectableAbsolute("C:")); // 구분자 없음
    try std.testing.expect(!isDetectableAbsolute("\\foo\\bar")); // resolve가 드라이브 없는 경로를 낸다
    try std.testing.expect(!isDetectableAbsolute("\\\\server\\share")); // UNC — 알려진 공백
    try std.testing.expect(!isDetectableAbsolute("1:\\not-a-drive")); // 드라이브 문자는 letter여야 한다
    try std.testing.expect(!isDetectableAbsolute("src/main.zig")); // 상대
    try std.testing.expect(!isDetectableAbsolute("./x"));

    // **가드(isAbsolute)와 갈리는 지점**을 못 박는다 — 가드는 더 넓게 거부해야 맞다.
    try std.testing.expect(isAbsolute("C:relative") and !isDetectableAbsolute("C:relative"));
    try std.testing.expect(isAbsolute("\\\\server\\share") and !isDetectableAbsolute("\\\\server\\share"));

    // **비-Windows 빌드에서는 옛 판정(`word[0] == '/'`)과 완전히 동일해야 한다** — 이 슬라이스가 macOS 동작을
    // 하나도 바꾸지 않는다는 것을 코드로 못 박는다(Windows 빌드에서는 위 케이스들이 그 역할을 한다).
    if (!windows) {
        for ([_][]const u8{ "/a", "/", "C:\\a", "C:/a", "C:", "a:b", "", "rel/a.zig", "\\x", "//s", "~/a" }) |t| {
            try std.testing.expectEqual(t.len > 0 and t[0] == '/', isDetectableAbsolute(t));
        }
    }
}

test "isRoot: 루트 모양만 참" {
    try std.testing.expect(isRoot("/"));
    try std.testing.expect(isRoot("C:"));
    try std.testing.expect(isRoot("C:\\"));
    try std.testing.expect(isRoot("C:/"));

    try std.testing.expect(!isRoot(""));
    try std.testing.expect(!isRoot("/usr"));
    try std.testing.expect(!isRoot("C:\\Users"));
    try std.testing.expect(!isRoot("//server")); // UNC 공유 루트는 별개 모양이라 여기서 다루지 않는다
}
