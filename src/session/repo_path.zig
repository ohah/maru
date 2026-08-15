//! 저장소 루트 **안쪽**을 가리키는 상대경로인지 판정한다(L2 순수, docs/editor-surface-tooling.md §6).
//!
//! **왜 필요한가**: diff는 남의 코드를 보려고 만든 기능이라 **적대적일 수 있는 저장소를 여는 것이 정상 사용**이다.
//! 저장소에 `key.txt -> ~/.ssh/id_rsa` 같은 심링크나 `../..` 경로가 들어 있어도, 읽은 내용은 신뢰 origin 웹뷰로
//! 들어간다. 가장 강한 방어는 이미 구조에 있고(브리지가 경로 인자를 받지 않는다 — §6), 이 모듈은 **우리 자신의
//! 버그와 이상한 git 출력**에 대한 심층 방어다.
//!
//! 여기서는 문자열만 본다. 심링크는 문자열로 알 수 없으므로 여는 쪽이 component마다 no-follow로 막는다(L4).

const std = @import("std");
const path_shape = @import("../path_shape.zig");

/// 저장소 루트 기준 상대경로로 **안전한가**. 거부 사유는 다섯이다:
/// ⑴ 빈 경로 ⑵ **절대경로**(POSIX `/`·Windows 드라이브 `C:`·UNC — `path_shape.isAbsolute`) ⑶ **역슬래시**
/// ⑷ `..`/`.` 세그먼트(루트 밖·자기 참조) ⑸ NUL(C 문자열 절단으로 다른 파일 지정).
///
/// 빈 세그먼트(`a//b`)도 거부한다 — 정상 git 출력에 없고, 정규화 없이 그대로 이어 붙이는 우리 쪽 규약을 단순하게
/// 유지한다(경로를 "고쳐서" 통과시키지 않는다 — 고치면 무엇을 읽는지가 호출자 눈에 안 보인다).
///
/// **역슬래시를 왜 따로 막는가**: 세그먼트를 `/`로만 쪼개므로 `..\..\secret`은 **세그먼트가 하나**여서 `..`
/// 검사를 그대로 통과한다. POSIX에서는 그것이 `..\..\secret`이라는 이름의 파일이라 무해하지만, Windows에서는
/// 진짜 상위 이동이라 **루트 밖으로 나간다**. git은 출력 경로에 항상 `/`를 쓰므로 정상 입력을 잃지 않는다.
/// (docs/windows-platform.md §5 — 절대경로 판정을 `[0]=='/'`에서 떼어내는 작업의 일부.)
pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path_shape.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false; // 빈 세그먼트(`a//b`, 끝의 `/`)
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
    }
    return true;
}

const testing = std.testing;

test "정상 상대경로만 통과한다" {
    try testing.expect(isSafeRelative("src/main.zig"));
    try testing.expect(isSafeRelative("a.txt"));
    try testing.expect(isSafeRelative("깊은/경로/한글.md")); // 비ASCII도 정상 경로다
    try testing.expect(isSafeRelative("dot.files/.gitignore")); // 점으로 시작하는 이름은 `.` 세그먼트가 아니다
}

test "루트 밖을 가리키거나 모호한 경로는 거부한다" {
    try testing.expect(!isSafeRelative("")); // 빈 경로
    try testing.expect(!isSafeRelative("/etc/passwd")); // 절대경로
    try testing.expect(!isSafeRelative("../outside.txt")); // 부모로 탈출
    try testing.expect(!isSafeRelative("a/../../b")); // 중간에서 탈출
    try testing.expect(!isSafeRelative("./a.txt")); // 자기 참조 세그먼트
    try testing.expect(!isSafeRelative("a//b")); // 빈 세그먼트
    try testing.expect(!isSafeRelative("a/")); // 끝의 슬래시
    try testing.expect(!isSafeRelative("a\x00b")); // NUL — C 문자열이 여기서 잘려 다른 파일을 가리킨다
}

// 이 가드는 `/`로만 세그먼트를 쪼갠다. 그래서 예전에는 **역슬래시가 통째로 한 세그먼트 안에 숨어** `..` 검사를
// 그대로 지나갔다 — POSIX에서는 그런 이름의 파일일 뿐이라 무해했지만 Windows에서는 진짜 상위 이동이라
// **루트 밖으로 나간다.** 절대경로 판정도 `[0]=='/'`라 드라이브 절대·UNC를 상대로 통과시켰다.
// (docs/windows-platform.md §5)
test "Windows 경로 모양도 거부한다 — 역슬래시 탈출과 드라이브·UNC 절대" {
    // 역슬래시 탈출: `/`로 쪼개면 세그먼트가 하나라 옛 `..` 검사를 통과했다.
    try testing.expect(!isSafeRelative("..\\..\\secret"));
    try testing.expect(!isSafeRelative("a\\..\\..\\b"));
    try testing.expect(!isSafeRelative("a\\b")); // 정상 git 출력은 항상 `/`라 잃는 입력이 없다

    // 드라이브 절대(두 구분자 모두)와 드라이브 상대.
    try testing.expect(!isSafeRelative("C:\\Windows\\System32"));
    try testing.expect(!isSafeRelative("C:/Windows/System32"));
    try testing.expect(!isSafeRelative("C:relative"));

    // UNC.
    try testing.expect(!isSafeRelative("\\\\server\\share"));
    try testing.expect(!isSafeRelative("//server/share"));

    // 드라이브 문자처럼 **생겼을 뿐인** 이름은 계속 통과한다(정상 파일을 막지 않는다).
    try testing.expect(isSafeRelative("C/main.zig"));
    try testing.expect(isSafeRelative("src/c.zig"));
}

test "`..`를 포함하는 **이름**은 통과한다(세그먼트만 본다)" {
    // `..hidden`은 부모가 아니라 그냥 파일 이름이다 — 이름 안의 점을 이유로 막으면 정상 파일을 못 연다.
    try testing.expect(isSafeRelative("..hidden"));
    try testing.expect(isSafeRelative("a/..b/c"));
}
