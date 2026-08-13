//! 테스트 전용 임시 디렉터리 — `/tmp/maru-<tag>-<pid>`를 **깨끗한 상태로** 열고 닫는다.
//!
//! ## 왜 있나
//!
//! 이 디렉터리들은 이름이 **PID로 정해진다**. 그 자체는 문제가 아니다(같은 시각에 같은 PID는 없다).
//! 문제는 정리가 `defer _ = c.rmdir(dir)` 하나에만 걸려 있던 것이다:
//!
//! 1. 테스트가 죽거나 중단되면 하위 파일이 남는다(manifest는 `<dir>/hosts/<id>/host.v1.json`을 만든다).
//! 2. 그러면 `rmdir`은 `ENOTEMPTY`로 **조용히** 실패한다 — 반환값을 버리므로 아무도 모른다.
//! 3. macOS는 PID를 금방 재사용한다. 같은 PID가 다시 걸리면 그 잔여물 위에서 테스트가 시작되고,
//!    `renameNoReplace`가 "이미 존재"로 죽는다(`error.RenameFailed`).
//! 4. **그 실패가 또 잔여물을 남긴다.** 자기 증식이다.
//!
//! 실측(2026-08-13): 이 개발 머신에 `/tmp/maru-host-manifest-txn-*`가 **1,969개** 쌓여 있었고
//! (가장 오래된 것이 이틀 전), `mise run test`가 3회 중 2회 `RenameFailed`로 red였다. 손으로 지우면
//! 통과했다. CI는 러너가 매번 깨끗해 한 번도 못 잡았다 — 같은 커밋에서 CI는 3회 모두 green이었다.
//!
//! ## 그래서 **열 때** 지운다
//!
//! 닫을 때만 지우면 죽은 실행의 찌꺼기를 그대로 상속한다. 시작 시 재귀 삭제하면 3·4번 고리가 끊긴다 —
//! 잔여물이 있어도 그 실행은 성공하고, 성공한 실행은 자기 뒤를 치운다.
//!
//! 닫을 때도 `rmdir`이 아니라 재귀 삭제다. `rmdir`은 "비어 있을 때만"이라 이 용도에 맞지 않는다 —
//! 테스트가 만든 하위 트리를 지우는 것이 목적이지, 비었는지 확인하는 것이 목적이 아니다.
//!
//! ## 쓰지 않는 곳
//!
//! `admin_client.zig`의 정리는 **`rmdir`이 0을 반환하는지 단언한다**(= 제품 경로가 자기 디렉터리를
//! 실제로 회수했다). 그건 위생이 아니라 **계약**이라 여기로 옮기지 않는다 — 재귀 삭제로 바꾸면 그
//! 단언이 항상 참이 되어 검증이 사라진다.

const std = @import("std");
const c = std.c;

/// `/tmp/maru-<tag>-<pid>`를 만들고 그 경로를 돌려준다. 이미 있으면 **통째로 지우고** 다시 만든다.
///
/// 실패하면 `null`이다 — 호출자는 `orelse return error.SkipZigTest`로 접는다(기존 관례). 이 헬퍼는
/// 테스트 격리를 위한 것이라, 여기서 못 만들면 그 테스트는 판정할 자격이 없지 실패가 아니다.
pub fn open(io: std.Io, buf: []u8, tag: []const u8) ?[:0]u8 {
    const path = std.fmt.bufPrintZ(buf, "/tmp/maru-{s}-{d}", .{ tag, c.getpid() }) catch return null;
    // 죽은 실행의 잔여물을 상속하지 않는다(파일 머리말 3·4번 고리). 없으면 no-op다.
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    if (c.mkdir(path.ptr, 0o700) != 0) return null;
    return path;
}

/// 테스트가 끝날 때 트리째 지운다. 실패는 무시한다 — 다음 `open`이 어차피 다시 지운다.
pub fn close(io: std.Io, path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "scratch: 이전 실행이 남긴 하위 트리를 상속하지 않는다" {
    const io = std.testing.io;
    var buf: [192]u8 = undefined;

    // 1회차 — 하위 트리를 만들어 둔 채로 **닫지 않는다**(테스트가 죽은 상황을 그대로 만든다).
    const first = open(io, &buf, "test-scratch-inherit") orelse return error.SkipZigTest;
    var nested_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrintZ(&nested_buf, "{s}/hosts", .{first});
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested.ptr, 0o700));
    var residue_buf: [320]u8 = undefined;
    const residue = try std.fmt.bufPrintZ(&residue_buf, "{s}/host.v1.json", .{nested});
    {
        const fd = c.open(residue.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        _ = c.close(fd);
    }
    // ⚠️ 이 상태가 결함의 정확한 모양이다: `rmdir`로는 못 지운다(ENOTEMPTY).
    try std.testing.expect(c.rmdir(first.ptr) != 0);

    // 2회차 — 같은 PID(같은 프로세스다)라 경로가 같다. 잔여물을 상속하면 이 단언이 깨진다.
    //
    // ⚠️ 여기서는 `orelse return error.SkipZigTest`를 **쓰지 않는다**. pre-clean이 없으면 `mkdir`이
    // `EEXIST`로 실패해 `open`이 `null`을 주는데, skip으로 접으면 그 결함이 **green으로 집계된다**
    // (첫 판 회귀 테스트가 실제로 그랬다 — pre-clean을 지우는 뮤테이션에서 red가 아니라 SKIP이었다).
    // 잔여물이 있어도 여는 것이 이 헬퍼의 계약이므로, 못 열면 그것이 곧 실패다.
    var buf2: [192]u8 = undefined;
    const second = open(io, &buf2, "test-scratch-inherit") orelse
        return error.ScratchOpenMustSurviveResidue;
    defer close(io, second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(c.access(residue.ptr, c.F_OK) != 0); // 잔여 파일이 없다
    try std.testing.expect(c.access(nested.ptr, c.F_OK) != 0); // 잔여 디렉터리도 없다
}

test "scratch: close는 하위 트리가 있어도 지운다" {
    const io = std.testing.io;
    var buf: [192]u8 = undefined;
    const dir = open(io, &buf, "test-scratch-close") orelse return error.SkipZigTest;
    var nested_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrintZ(&nested_buf, "{s}/hosts", .{dir});
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested.ptr, 0o700));

    close(io, dir);
    // 옛 `rmdir` 정리는 여기서 조용히 실패해 디렉터리를 남겼다 — 그것이 1,969개의 출처다.
    try std.testing.expect(c.access(dir.ptr, c.F_OK) != 0);
}
