//! 환경변수를 **UTF-8로** 읽는다 — 경로가 걸린 자리의 단일 출처.
//!
//! **`std.c.getenv`를 경로에 쓰면 안 된다.** 그것은 CRT의 **ANSI 환경**을 보므로 Windows에서 값이 그
//! 기계의 ACP 바이트로 온다. 한국어 Windows(ACP 949)에서 실측한 것:
//!
//! ```text
//! MARU_PROBE = C:\Users\홍길동\AppData\Local
//!   std.c.getenv        len=29  valid_utf8=false  … 5C C8 AB B1 E6 B5 BF 5C …
//!   std.process.Environ len=32  valid_utf8=true   C:\Users\홍길동\AppData\Local
//! ```
//!
//! 그 바이트를 UTF-8로 취급하면 파일 열기가 실패하고(`error.BadPathName`), 로더는 그것을 "파일 없음"과
//! 구분하지 못해 **사용자 config를 통째로 잃는다**. 더 나쁜 것은 cp949 **trail 바이트가 `0x5C`(`\`)일 수
//! 있다**는 점이다 — 구분자 정규화(계약 §5)가 글자 한가운데를 바꿔 **다른 경로**를 만든다.
//!
//! Windows에서는 `std.process.Environ`이 wide(UTF-16) 환경 블록을 읽어 WTF-8로 준다. POSIX에서는 환경이
//! 이미 바이트 문자열이라 차이가 없다.
//!
//! **끝단에서 대조군으로 확인했다.** `%MARU_CONFIG%`를 한글이 든 실제 경로
//! (`…\Temp\한글테스트\설정\config`, `input.right-click = menu`)로 두고 `win32-terminal-smoke`를 돌린 결과:
//!
//! ```text
//! Windows 갈래를 getenv로 되돌린 대조군   right_click=paste  ← 기본값. config를 통째로 잃었다
//! 이 파일 그대로(Environ)                  right_click=menu   ← 사용자 값이 살아 있다
//! ```
//!
//! 잃는 쪽이 조용하다는 것이 이 버그의 성질이다 — 진단도 경고도 없이 기본값으로 도는 것처럼 보인다.
//!
//! ## 무엇을 여기로 옮기고 무엇을 안 옮기는가
//!
//! **경로가 될 수 있는 값만** 옮긴다 — `$HOME`·`%LOCALAPPDATA%`·`$MARU_CONFIG`처럼 파일시스템을 가리키는
//! 것들이다. `MARU_DEBUG`(존재 여부만 봄)나 `USER`(표시용)처럼 경로가 아니고 사실상 ASCII인 값은
//! 그대로 둔다 — 여기로 옮기면 할당과 해제가 늘 뿐이다.

const std = @import("std");
const builtin = @import("builtin");

/// 환경변수 값을 UTF-8로 돌려준다. 없거나 비어 있으면 `null`. **호출자가 해제한다.**
///
/// 소유권이 `getenv`와 다르다(그쪽은 빌린 포인터). 그래서 이름을 `getenv`처럼 짓지 않았다 — 이름이 같으면
/// 호출자가 해제를 잊는다.
///
/// **`key`가 `[:0]`인 이유는 POSIX 갈래다.** 그쪽은 `std.c.getenv`를 부르므로 NUL 종단이 필요한데,
/// `[]const u8`로 받고 `@ptrCast(key.ptr)`하면 그 요구가 **말없이** 생긴다 — 리터럴만 넘기는 동안은
/// 돌고, 슬라이스를 넘기는 호출자가 처음 생기는 순간 경계 밖을 읽는다. 타입으로 못 박으면 그 실수가
/// 컴파일에서 걸린다(리터럴은 그대로 통과하므로 호출부는 하나도 안 바뀐다).
///
/// 빈 값을 `null`로 접는 이유: 이 저장소의 소비자들이 전부 "빈 값 = 설정 안 함"으로 다룬다(`MARU_CONFIG`가
/// 빈 문자열이면 기본 경로를 쓴다). 그 판정을 자리마다 반복하지 않는다.
pub fn allocValue(gpa: std.mem.Allocator, key: [:0]const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const env: std.process.Environ = .{ .block = std.process.Environ.GlobalBlock.global };
        const value = env.getAlloc(gpa, key) catch return null;
        if (value.len == 0) {
            gpa.free(value);
            return null;
        }
        return value;
    }
    // POSIX: 환경이 이미 바이트 문자열이라 변환이 없다. 소유권만 Windows 갈래와 맞춘다.
    const raw = std.c.getenv(@ptrCast(key.ptr)) orelse return null;
    const span = std.mem.span(raw);
    if (span.len == 0) return null;
    return gpa.dupe(u8, span) catch null;
}

const testing = std.testing;

test "allocValue: 없는 변수는 null 이고 해제할 것이 없다" {
    // 이름을 길게 잡아 실제 환경과 충돌하지 않게 한다.
    try testing.expect(allocValue(testing.allocator, "MARU_OS_ENV_TEST_ABSENT_KEY_XYZ") == null);
}

test "allocValue: 있는 변수는 소유 슬라이스로 오고 UTF-8 이다" {
    // 어느 OS에나 있는 변수를 고른다 — Windows 는 `SystemRoot`, POSIX 는 `PATH`.
    const key = if (builtin.os.tag == .windows) "SystemRoot" else "PATH";
    const value = allocValue(testing.allocator, key) orelse return; // 없는 환경(빈 CI 샌드박스)이면 건너뛴다
    defer testing.allocator.free(value);
    try testing.expect(value.len > 0);
    // **이것이 이 모듈의 존재 이유다** — `getenv` 는 Windows 에서 ACP 바이트를 준다.
    try testing.expect(std.unicode.utf8ValidateSlice(value));
}
