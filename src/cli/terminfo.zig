//! `maru terminfo` 서브커맨드의 순수 인자 파싱. 실제 I/O(셸 명령 실행·출력)는 main.zig가, 캐시 경로·
//! 버전·컴파일 셸 명령은 top-level `terminfo_cache.zig`가 갖는다(pty 자동 컴파일과 공유). 이 모듈은 std만
//! 의존해 단위 테스트로 동작을 못박는다.
//!
//! 무엇을 하나: maru는 자체 terminfo(`xterm-maru`)를 자식 셸마다 `~/.cache/maru/terminfo`에 자동
//! 컴파일해 쓴다. 이 서브커맨드는 그 캐시를 관리한다 — 상태 조회, 강제 재컴파일(업데이트 후), 삭제, 경로
//! 출력. 보통은 자동(버전 마커로 stale 감지 후 재컴파일)이라 손댈 일이 없지만, 강제·진단용으로 둔다.

const std = @import("std");

/// `maru terminfo [<action>]`의 동작. 인자 없으면 status(가장 안전한 기본 — 아무것도 안 바꾼다).
pub const Action = enum { status, refresh, clear, path };

pub const ParseError = error{UnknownArg};

/// "terminfo" 뒤 인자들을 Action으로 판정한다. 인자 0개면 status. 하나의 플래그(`--status`/`--refresh`/
/// `--clear`/`--path`)만 받는다. 알 수 없거나 2개 이상이면 error.UnknownArg(main이 usage를 낸다).
pub fn parse(args: []const []const u8) ParseError!Action {
    if (args.len == 0) return .status;
    if (args.len > 1) return error.UnknownArg;
    const a = args[0];
    if (std.mem.eql(u8, a, "--status")) return .status;
    if (std.mem.eql(u8, a, "--refresh")) return .refresh;
    if (std.mem.eql(u8, a, "--clear")) return .clear;
    if (std.mem.eql(u8, a, "--path")) return .path;
    return error.UnknownArg;
}

test "parse: 인자 없으면 status(안전 기본)" {
    try std.testing.expectEqual(Action.status, try parse(&.{}));
}

test "parse: 각 플래그가 해당 Action으로" {
    try std.testing.expectEqual(Action.status, try parse(&.{"--status"}));
    try std.testing.expectEqual(Action.refresh, try parse(&.{"--refresh"}));
    try std.testing.expectEqual(Action.clear, try parse(&.{"--clear"}));
    try std.testing.expectEqual(Action.path, try parse(&.{"--path"}));
}

test "parse: 알 수 없는 인자·중복은 거부" {
    try std.testing.expectError(error.UnknownArg, parse(&.{"--bogus"}));
    try std.testing.expectError(error.UnknownArg, parse(&.{"refresh"})); // 대시 없는 형식은 미지원
    try std.testing.expectError(error.UnknownArg, parse(&.{ "--refresh", "--clear" }));
}
