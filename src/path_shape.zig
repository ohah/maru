//! 경로 **모양** 판정 — 절대인가, 구분자로 끝나는가, 어디가 구분자인가. OS-중립 최상위 유틸이다(`width.zig` 선례).
//!
//! **왜 별도 모듈인가**: 이 판정이 필요한 곳이 L1(`terminal/selection.zig` 링크 감지)과 L2(`session/*`
//! 경로 가드) 양쪽에 있는데 L1은 L2를 import할 수 없다. 그래서 둘 다 닿는 최상위에 둔다.
//!
//! **왜 `path[0] == '/'`로 충분하지 않은가**: 그 판정은 POSIX 절대경로만 안다. Windows에는 드라이브 절대
//! (`C:\x`·`C:/x`)와 UNC(`\\server\share`)가 있고, 이들은 `/`로 시작하지 않는다. 그래서 "절대경로를 거부한다"는
//! 가드가 Windows 경로를 **상대경로로 통과**시킨다(docs/windows-platform.md §5).
//!
//! **`std.fs.path.isAbsolute`를 쓰지 않는 이유**: 그것은 **호스트 native** 판정이라 macOS에서 `C:\x`를 상대로
//! 본다. 가드가 답해야 하는 질문은 "이 호스트에서 절대인가"가 아니라 **"어떤 OS의 절대경로 모양이라도
//! 되는가"** 다 — 가드는 자기 호스트가 모르는 모양도 막아야 하고, 터미널은 원격이 보낸 경로도 본다.

const std = @import("std");

/// 경로 구분자인가. Windows는 둘 다 구분자로 받고, POSIX 경로에서 `\`는 파일명에 쓸 수 있지만 이 함수의
/// 소비자(**가드**)는 보수적인 쪽이 맞다 — 구분자일 수 있는 문자를 아니라고 단정하면 뚫린다.
///
/// **경계 판정에는 쓰지 말 것.** "이 경로가 저 루트 안인가"를 묻는 자리에서 `\`를 구분자로 세면 POSIX에서
/// `p\q`라는 **평범한 파일 이름**이 디렉터리 `p`의 자식으로 둔갑한다. L2의 경로 계약은 POSIX이므로
/// (docs/layering-and-portability.md §4.1) 그 자리는 `/`만 봐야 한다 — `endsWithSep`를 쓴다.
pub fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// 드라이브 지정자(`C:`)의 **바이트 길이**. 드라이브 모양이 아니면 null.
///
/// **드라이브 문자를 A–Z로 제한하지 않는다.** Win32는 그런 제한을 두지 않는다 —
/// `RtlDetermineDosPathNameType_U`를 모사하는 `std.fs.path.getWin32PathType`도 **아무 코드포인트나** 받아서
/// `1:/x`와 `λ:\x`가 절대경로다(std 자신의 테스트가 그렇게 고정한다; `SetVolumeMountPointW`로 비알파벳
/// 드라이브를 만들 수 있기 때문이다). **가드는 OS 파서보다 좁으면 안 된다** — 좁으면 그 차이가 그대로
/// 우회로가 된다(실측: 옛 `isAlphabetic` 판정에서 `1:/Windows/x`가 `repo_path`를 상대경로로 통과했다).
/// 그래서 문자 **종류**를 묻지 않고, 첫 코드포인트 바로 뒤가 `:`인지만 본다.
fn drivePrefixLen(path: []const u8) ?usize {
    if (path.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(path[0]) catch 1;
    if (path.len <= n or path[n] != ':') return null;
    return n + 1;
}

/// **어떤 OS의 절대경로 모양이라도** 되는가 — 가드용(넓게 거부).
///
/// - POSIX: `/x`
/// - Windows 드라이브 절대: `C:\x`, `C:/x`
/// - Windows 드라이브 상대: `C:x` — **절대로 친다.** 진짜 절대는 아니지만 "루트 기준 상대경로"도 아니라서,
///   이걸 상대로 통과시키면 `<root>/C:x`처럼 뜻이 없는 경로가 만들어지고 Windows에서는 드라이브의 *현재*
///   디렉터리로 해석돼 예측 불가가 된다. 가드는 이 모양을 받지 않는 편이 안전하다.
/// - UNC/네트워크: `\\server\share`, `//server/share`
///
/// **알고 받아들이는 대가**: POSIX에서 `Q:answers.md`·`a:b.txt`는 합법 파일명인데 여기서 절대로 판정된다.
/// Windows 파일명에는 `:`를 쓸 수 없으므로 이 대가는 POSIX 전용이고, 저장소에 그런 이름이 있으면 그 파일의
/// diff를 못 연다. 드라이브 상대(`C:x`)를 위험으로 보는 판단(위)과 같은 뿌리이며, 정상 파일을 잃는 쪽보다
/// 루트 밖을 읽는 쪽이 더 나쁘다고 보고 **의도적으로** 이 방향을 택했다.
pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (isSep(path[0])) return true; // POSIX 절대 + UNC(`//`·`\\`)를 함께 덮는다
    return drivePrefixLen(path) != null;
}

/// 터미널 화면의 토큰을 **열 수 있는 절대경로 링크로 감지할 것인가** — 이 바이너리가 도는 OS 기준.
/// 본체는 `isDetectableAbsoluteFor`이고, 여기는 호스트 OS를 채워 넣는 얇은 래퍼다.
pub fn isDetectableAbsolute(path: []const u8) bool {
    return isDetectableAbsoluteFor(@import("builtin").os.tag, path);
}

/// `isDetectableAbsolute`의 본체 — 판정 기준이 되는 OS를 **인자로** 받는다. `isAbsolute`와 **일부러 다르다.**
///
/// **가드와 감지는 질문이 다르다.** 가드(`isAbsolute`)는 "이 문자열이 **어떤 OS에서든** 위험한가"를 묻는다 —
/// 문자열을 공격자가 고르므로 모양이 조금이라도 절대 같으면 거부해야 한다. 감지는 "이 문자열이 **그 OS에서**
/// 실제로 열리는 경로인가"를 묻는다 — 답을 파일시스템이 정하므로 넓게 잡으면 곧바로 오탐(밑줄)이 된다.
///
/// **왜 OS가 인자인가**: 감지 결과(밑줄 span)는 **콘텐츠를 가진 쪽**에서 만들어진다. 로컬은 물론 원격 세션도
/// host가 `selection.collectViewportLinks`로 span을 모아 client에 보낸다. VS Code도 같은 규칙을 런타임 값으로
/// 구현한다 — `detectLinks(text, this._processManager.os || OS)`는 클라이언트가 아니라 **백엔드/PTY의 OS**를 쓴다.
/// 지금 호출자는 호스트 OS만 넘기지만, 그 값이 **파라미터라서** 테스트가 두 OS를 모두 돌 수 있고(비-Windows
/// CI에서도 Windows 갈래가 실제로 실행된다), 나중에 ssh 원격 OS(`TerminalCore.sshRemoteDest`)를 반영할 때
/// 소비자를 다시 배선하지 않아도 된다.
///
/// **왜 `isAbsolute`보다 좁은가**(실측, docs/windows-platform.md §5.1): 감지한 토큰은 곧바로
/// `TerminalCore.resolveClickedPath`로 가고 거기서 `std.fs.path.isAbsolute`가 거짓이면 **cwd에 join**된다.
/// 감지가 그보다 넓으면 "밑줄은 뜨는데 엉뚱한 경로를 연다"가 된다. Windows에서 잰 불일치는 이렇다:
///
/// - `a:b`, `C:relative` — 드라이브 모양이지만 `std.fs.path.isAbsolute`는 **거짓**. 그래서 드라이브 뒤에
///   **구분자를 요구**한다(`C:\x`·`C:/x`). VS Code의 `winDrivePrefix`도 같은 모양이다.
/// - `\foo\bar` — `isAbsolute`는 참이지만 `resolve`가 드라이브 없는 `\foo\bar`를 낸다. 게다가 이스케이프된
///   출력(`\n` 등)과 구별이 안 돼 오탐이 크다. 감지하지 않는다.
/// - UNC(`\\server\share`·`//server/share`) — 진짜 절대지만 위와 같은 오탐 위험이 있고 터미널 출력에서 드물다.
///   VS Code도 `\\?\C:` 확장형만 다룬다. **여기서 직접 배제한다** — 예전에는 호출자의 `!startsWith("//")`가
///   `//server/share`를 막고 있어서, 이 함수의 doc과 실제 반환값이 어긋나 있었다.
///
/// **마지막에 `std.fs.path.isAbsoluteWindows`로 확인한다.** 위 규칙들은 *정책*("무엇을 링크로 보고 싶은가")이고,
/// 부분집합 관계는 *사실*("resolve가 이것을 절대로 인정하는가")이다. 둘을 각각 손으로 맞추면 어긋난다 —
/// `drivePrefixLen`의 UTF-8 근사가 `\x80:/x`·`😀:/x` 등 72가지 바이트열에서 std와 갈렸다(적대적 검증).
/// 정책은 여기서 좁히고, 사실은 std에게 묻는다.
///
/// **남은 비대칭(알려진 것)**: Windows에서 `/foo/bar`는 계속 감지하는데, Win32에서 그것은 `\foo\bar`와 **같은
/// 종류**(`.rooted`)라 위에서 `\foo\bar`를 뺀 이유가 그대로 적용된다. 그럼에도 남긴 것은 Windows 터미널에
/// git-bash·MSYS·WSL 출력으로 POSIX 모양이 흔히 뜨기 때문이다. 대가는 그 링크의 `access`가 터미널의 cwd
/// 드라이브가 아니라 **프로세스의 현재 드라이브**에 묶인다는 것이다(docs/windows-platform.md §5.1).
pub fn isDetectableAbsoluteFor(os_tag: std.Target.Os.Tag, path: []const u8) bool {
    if (path.len == 0) return false;
    // UNC와 프로토콜 상대는 어느 OS에서도 감지하지 않는다 — doc과 반환값을 여기서 일치시킨다.
    // **`//`만 본다**: 옛 호출부 규칙(`!startsWith("//")`)과 정확히 같은 집합이라야 macOS 동작이 불변이다.
    // `isSep`으로 두 자리를 보면 `/\x`(POSIX에서 `\`라는 이름의 디렉터리 아래)까지 배제해 버린다 —
    // 적대적 검증에서 나온 차이다.
    if (std.mem.startsWith(u8, path, "//")) return false;
    if (path[0] == '/') return true; // POSIX 절대 — 모든 호스트에서 예전과 같은 동작
    if (os_tag != .windows) return false;
    if (std.mem.startsWith(u8, path, "\\\\")) return false; // UNC(역슬래시 철자)
    const n = drivePrefixLen(path) orelse return false;
    if (path.len <= n or !isSep(path[n])) return false; // 드라이브 뒤 구분자 필수
    // **부분집합을 정의상 보장한다.** 위 검사들은 "무엇을 링크로 보고 싶은가"(정책)이고, 이 마지막 줄은
    // "resolve가 이것을 절대로 인정하는가"(사실)다. 둘을 각각 손으로 맞추면 반드시 어긋난다 — 실제로
    // `drivePrefixLen`의 UTF-8 근사가 `\x80:/x`·`😀:/x` 같은 72가지 바이트열에서 std와 갈렸고, 그 토큰은
    // 밑줄이 뜬 채 클릭하면 cwd에 join돼 **엉뚱한 파일을 열었다**(적대적 검증). 사실은 std에게 묻는다.
    return std.fs.path.isAbsoluteWindows(path);
}

/// 플랫폼이 중립 레이어로 넘기는 경로의 구분자를 **POSIX(`/`)로 정규화**한다(입구 정규화).
///
/// **왜 입구인가**: L2는 경로를 이을 때 항상 `/`를 쓰는데(docs/layering-and-portability.md §4.1) 입력이
/// native면 결과가 섞인다 — 실측: `$HOME`이 `C:\Users\me`일 때 terminfo 캐시 경로가
/// `C:\Users\me/.cache/maru/terminfo`가 된다. 그 상태로 `file_tree`·`git_ops`에 들어가면 이미 한 번 고친
/// `/repo\docs` 문제를 그대로 다시 겪는다(docs/windows-platform.md §5).
///
/// **`os_tag`가 인자인 이유는 안전이다.** POSIX에서 `\`는 **파일 이름에 쓸 수 있는 평범한 글자**라, 거기서
/// 바꾸면 `p\q`라는 파일이 `p/q`라는 다른 경로가 된다 — W1.5에서 `pathWithin`에 `\`를 구분자로 넣었다가
/// 정확히 그 부류의 회귀를 냈다. 그래서 Windows 기준일 때만 바꾸고, 그 판정을 테스트가 두 갈래 다 돈다.
///
/// 반환은 항상 `allocator` 소유다(바꿀 것이 없어도 복사본) — "때로는 owned 때로는 borrowed"는 호출자가
/// 반드시 틀리는 계약이다(W2.5에서 그 형태로 누수를 하나 냈다).
pub fn normalizeSeparatorsFor(
    os_tag: std.Target.Os.Tag,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    if (os_tag != .windows) return copy;
    for (copy) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return copy;
}

/// `normalizeSeparatorsFor`를 호스트 OS로 부르는 얇은 래퍼. 플랫폼 진입점(`main.zig` 등)이 쓴다.
pub fn normalizeSeparators(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return normalizeSeparatorsFor(@import("builtin").os.tag, allocator, path);
}

/// 경로가 **이미 구분자로 끝나는가** — 그 아래에 자식을 이어 붙일 때 구분자를 하나 더 넣으면 안 되는 모양.
///
/// 포함 판정(`pathWithin`)이 묻는 것이 정확히 이 질문이다: 루트가 `/`나 `C:/`처럼 구분자로 끝나면 루트 바로
/// 뒤 바이트가 **곧 첫 자식의 첫 글자**라, 거기서 구분자를 한 번 더 요구하면 자식이 통째로 루트 밖으로 보인다.
///
/// **`/`만 본다.** L2의 경로 계약은 POSIX이고(docs/layering-and-portability.md §4.1 — *"L2에서 경로 구분자를
/// 만들어 내는 자리는 항상 POSIX 구분자를 쓴다"*), 드라이브 루트도 입구에서 `C:/`로 정규화돼 들어온다
/// (docs/windows-platform.md §5). 여기서 `\`까지 세면 POSIX에서 `p\q`라는 **평범한 파일 이름**이 디렉터리 `p`의
/// 자식으로 둔갑한다 — 실측으로 확인한 회귀다(§5.1).
///
/// 길이를 열거하지 않으므로 `/`·`C:/`뿐 아니라 후행 구분자가 붙은 **모든** 루트(`C:/repo/`)가 함께 맞는다.
pub fn endsWithSep(path: []const u8) bool {
    return path.len > 0 and path[path.len - 1] == '/';
}

const testing = std.testing;

test "isSep: 두 구분자를 모두 본다" {
    try testing.expect(isSep('/'));
    try testing.expect(isSep('\\'));
    try testing.expect(!isSep('a'));
    try testing.expect(!isSep(':'));
}

test "isAbsolute: POSIX·드라이브·UNC를 모두 절대로 본다" {
    // POSIX
    try testing.expect(isAbsolute("/usr/bin"));
    try testing.expect(isAbsolute("/"));
    // Windows 드라이브 절대(두 구분자 모두)
    try testing.expect(isAbsolute("C:\\Users\\me"));
    try testing.expect(isAbsolute("C:/Users/me"));
    try testing.expect(isAbsolute("z:/lower"));
    // 드라이브 상대 — 상대로 통과시키면 안 되므로 절대로 친다
    try testing.expect(isAbsolute("C:x"));
    try testing.expect(isAbsolute("C:"));
    // UNC
    try testing.expect(isAbsolute("\\\\server\\share"));
    try testing.expect(isAbsolute("//server/share"));

    // 상대는 상대다
    try testing.expect(!isAbsolute(""));
    try testing.expect(!isAbsolute("src/main.zig"));
    try testing.expect(!isAbsolute("./x"));
    try testing.expect(!isAbsolute("../x"));
    try testing.expect(!isAbsolute("C"));
    try testing.expect(!isAbsolute("CC:/two-letters")); // `:`가 첫 코드포인트 뒤가 아니다
}

// 가드가 **OS 파서보다 좁으면** 그 차이가 곧 우회로다. Win32는 드라이브 문자를 A–Z로 제한하지 않는데
// (`std.fs.path.isAbsoluteWindows("1:/x") == true`) 옛 판정은 `isAlphabetic`을 요구해서 `1:/Windows/x`가
// **상대경로로 통과**했다 — 이 모듈이 닫으려던 바로 그 구멍이다(docs/windows-platform.md §5.1).
test "isAbsolute: 드라이브 문자를 A–Z로 제한하지 않는다(Win32와 같은 폭)" {
    for ([_][]const u8{ "1:/x", "1:\\x", "_:/x", "λ:\\x", "가:/x" }) |t| {
        try testing.expect(isAbsolute(t));
        // std가 절대로 보는 것을 우리가 상대로 보면 안 된다 — 그 간극이 우회로가 된다.
        try testing.expect(std.fs.path.isAbsoluteWindows(t));
    }
}

// 감지 술어는 **OS를 인자로** 받는다. 그래서 이 테스트는 Windows 러너 없이도 두 갈래를 모두 실행한다
// (예전에는 comptime 분기라 비-Windows에서 Windows 단언이 통째로 공허참이었다).
test "isDetectableAbsoluteFor: 두 OS 갈래를 모두 실행한다" {
    const win = std.Target.Os.Tag.windows;
    const mac = std.Target.Os.Tag.macos;

    // POSIX 절대는 어느 OS 기준으로도 감지한다.
    for ([_]std.Target.Os.Tag{ win, mac }) |os| {
        try testing.expect(isDetectableAbsoluteFor(os, "/usr/bin/zig"));
        try testing.expect(isDetectableAbsoluteFor(os, "/"));
    }

    // 드라이브 절대 — Windows 기준일 때만.
    for ([_][]const u8{ "C:\\Users\\me\\a.zig", "C:/Users/me/a.zig", "z:\\lower", "C:\\", "1:/x" }) |t| {
        try testing.expect(isDetectableAbsoluteFor(win, t));
        try testing.expect(!isDetectableAbsoluteFor(mac, t));
    }

    // 어느 OS 기준으로도 감지하지 않는 모양들 — 각각 이유가 다르다.
    for ([_][]const u8{
        "", // 빈 토큰
        "a:b", // isAbsolute=false → cwd join 오작동
        "C:relative", // 같은 이유(드라이브 상대)
        "C:", // 구분자 없음
        "\\foo\\bar", // resolve가 드라이브 없는 경로를 낸다
        "\\\\server\\share", // UNC
        "//server/share", // UNC(슬래시) — 예전엔 호출자만 막고 있었다
        "src/main.zig",
        "./x",
    }) |t| {
        try testing.expect(!isDetectableAbsoluteFor(win, t));
        try testing.expect(!isDetectableAbsoluteFor(mac, t));
    }

    // **가드와 갈리는 지점**을 못 박는다 — 가드는 더 넓게 거부해야 맞다.
    try testing.expect(isAbsolute("C:relative") and !isDetectableAbsoluteFor(win, "C:relative"));
    try testing.expect(isAbsolute("//server/share") and !isDetectableAbsoluteFor(win, "//server/share"));

    // **비-Windows 기준에서는 옛 규칙과 완전히 동일**해야 한다 — macOS 동작 불변의 증거. 옛 규칙은
    // 술어(`word[0]=='/'`)와 호출부의 `!startsWith("//")`를 **합친 것**이라 여기서도 합쳐서 비교한다.
    // 한때 UNC 배제를 `isSep`으로 두 자리 봐서 `/\x`(POSIX에서 `\`라는 이름의 디렉터리 아래)까지 배제했고,
    // 그것이 이 주장을 깼다 — 적대적 검증에서 나온 차이다.
    for ([_][]const u8{
        "/a",   "/",         "//a",   "//",   "/\\x", "/\\",
        "\\/x", "\\\\x",     "C:\\a", "C:/a", "C:",   "a:b",
        "",     "rel/a.zig", "\\x",   "~/a",  ":/x",  "1:/x",
    }) |t| {
        const old = t.len > 0 and t[0] == '/' and !std.mem.startsWith(u8, t, "//");
        try testing.expectEqual(old, isDetectableAbsoluteFor(mac, t));
    }
}

// **부분집합 불변식**: 감지한 것은 반드시 resolve 단계(`std.fs.path.isAbsolute`)도 절대로 인정해야 한다.
// 아니면 `resolveClickedPath`가 그 토큰을 cwd에 join해 **엉뚱한 파일을 연다**. 지금까지 이 관계는 주석
// 다섯 군데에 산문으로만 있고 단언이 없었다 — 여기서 실행 가능하게 만든다.
test "감지 ⊆ std.fs.path.isAbsolute — 이 관계가 깨지면 클릭이 cwd에 join된다" {
    const win = std.Target.Os.Tag.windows;
    for ([_][]const u8{
        "/foo/bar",   "C:/x", "C:\\x", "C:\\",       "1:/x",
        "//server/x", "a:b",  "C:",    "\\foo",      "rel/x",
        "./x",        "~/x",  "",      "C:relative",
    }) |t| {
        if (isDetectableAbsoluteFor(win, t)) try testing.expect(std.fs.path.isAbsoluteWindows(t));
        if (isDetectableAbsoluteFor(.macos, t)) try testing.expect(std.fs.path.isAbsolutePosix(t));
    }
}

// 위 케이스 목록은 **손으로 고른 것**이라, 관계가 깨져 있는데도 통과했다. 드라이브 자리에 들어올 수 있는
// **모든 바이트**와 잘린/BMP 밖 UTF-8 선행 바이트까지 훑는다 — 적대적 검증이 여기서 72건을 찾았다:
// `utf8ByteSequenceLength` 실패를 길이 1로 근사한 탓에 `\x80:/x`·`\xFF:/x`가, 4바이트 이모지는 UTF-16
// surrogate pair라 `😀:/x`가 우리 쪽에서만 드라이브로 판정됐다. 그 토큰들은 밑줄이 뜬 채 클릭하면
// resolve가 상대로 보고 **cwd에 join**한다 — 이 술어가 막겠다고 만들어진 바로 그 실패다.
test "감지 ⊆ std: 드라이브 자리 전 바이트 + 잘린·BMP 밖 UTF-8 선행" {
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        for ([_]u8{ '/', '\\', 'x', ':' }) |sep| {
            const buf = [_]u8{ @intCast(b), ':', sep, 'y' };
            const t: []const u8 = &buf;
            if (isDetectableAbsoluteFor(.windows, t)) try testing.expect(std.fs.path.isAbsoluteWindows(t));
            if (isDetectableAbsoluteFor(.macos, t)) try testing.expect(std.fs.path.isAbsolutePosix(t));
        }
    }
    for ([_][]const u8{
        "\xF0:/x", "\xE0:/x", "\xC2:/x",
        "\x80:/x", "\xFF:/x", "\xF0\x9F:/x",
        "\xC3\xA9:/x",          "\xF0\x9F\x98\x80:/x", // 😀 — BMP 밖(surrogate pair)
        "\xF0\x9F\x98\x80:\\x",
    }) |t| {
        if (isDetectableAbsoluteFor(.windows, t)) try testing.expect(std.fs.path.isAbsoluteWindows(t));
    }
}

// 포함 판정이 실제로 묻는 질문이다. 예전 `isRoot`는 길이 1/2/3만 열거해서 `C:/repo/`처럼 후행 구분자가 붙은
// 더 긴 루트를 놓쳤고(자식이 하나도 안 보인다), `C:`(드라이브 상대)까지 루트로 쳐서 형제-접두 보호를 없앴다.
// 입구 정규화. **Windows 기준일 때만** 바꾼다 — POSIX에서 `\`는 파일 이름 글자라 바꾸면 다른 파일을 가리킨다.
// OS가 인자라 두 갈래를 여기서 모두 돈다(컴파일 타임 분기면 CI에서 한쪽이 공허참이 된다).
test "normalizeSeparatorsFor: Windows에서만 역슬래시를 바꾼다" {
    const a = std.testing.allocator;

    // Windows 기준: 섞인 경로가 전부 `/`가 된다(실제로 본 모양이다).
    {
        const got = try normalizeSeparatorsFor(.windows, a, "C:\\Users\\me/.cache/maru");
        defer a.free(got);
        try testing.expectEqualStrings("C:/Users/me/.cache/maru", got);
    }
    // POSIX 기준: **한 글자도 안 바꾼다.** `p\q`는 그런 이름의 파일이다.
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        const got = try normalizeSeparatorsFor(os, a, "/w/p\\q");
        defer a.free(got);
        try testing.expectEqualStrings("/w/p\\q", got);
    }
    // 바꿀 것이 없어도 **항상 owned**를 돌려준다(호출자가 분기하지 않게).
    {
        const got = try normalizeSeparatorsFor(.windows, a, "");
        defer a.free(got);
        try testing.expectEqualStrings("", got);
    }
    // 정규화 후에도 절대경로 판정이 유지된다(입구를 지나 가드로 가는 경로).
    {
        const got = try normalizeSeparatorsFor(.windows, a, "C:\\Windows");
        defer a.free(got);
        try testing.expect(isAbsolute(got));
        try testing.expect(std.mem.indexOfScalar(u8, got, '\\') == null);
    }
}

test "endsWithSep: 구분자로 끝나는 모든 루트를 맞힌다" {
    try testing.expect(endsWithSep("/"));
    try testing.expect(endsWithSep("C:/"));
    try testing.expect(endsWithSep("C:/repo/")); // 길이 열거로는 못 잡던 자리
    try testing.expect(endsWithSep("/usr/"));

    try testing.expect(!endsWithSep(""));
    try testing.expect(!endsWithSep("/usr"));
    try testing.expect(!endsWithSep("C:/repo"));
    try testing.expect(!endsWithSep("C:")); // 드라이브 상대는 루트가 아니다
    // L2 계약이 POSIX라 `\`로 끝나는 경로는 여기 오지 않는다. 와도 구분자로 세지 않는다 —
    // POSIX에서 `a\`는 그런 이름의 파일이다.
    try testing.expect(!endsWithSep("C:\\"));
}
