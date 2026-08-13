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

pub const OpenError = error{
    /// 경로를 만들 수 없다 — 버퍼 부족, 디스크 가득 참, `/tmp` 권한 등.
    ScratchUnavailable,
    /// **잔여물이 남아 있는데 지우지 못했다.** 이 헬퍼가 막으려는 상태가 그대로 살아 있다는 뜻이라
    /// 별도 이름을 준다 — 위 것과 뭉뚱그리면 원인이 화면에서 사라진다.
    ScratchResidueUnremovable,
};

/// `/tmp/maru-<tag>-<pid>`를 만들고 그 경로를 돌려준다. 이미 있으면 **통째로 지우고** 다시 만든다.
///
/// **`null`이 아니라 error를 준다.** 첫 판은 `?[:0]u8`였고 호출부가 전부
/// `orelse return error.SkipZigTest`였는데, 그러면 **이 파일이 막으려는 바로 그 상황에서 테스트가
/// 조용히 사라진다** — 잔여물을 못 지우면 `mkdir`이 `EEXIST`로 실패해 `null`이 되고, skip은 green으로
/// 집계된다. 회귀 테스트에서 같은 함정을 잡고(아래 주석) 호출부에도 남아 있다는 것을 적대적 검증에서
/// 찾았다. 못 도는 테스트에 green을 주지 않는 것이 이 API의 계약이다.
///
/// `tag`는 **comptime 슬러그**다. 런타임 문자열을 받으면 `../..` 같은 값이 `deleteTree`를 엉뚱한 경로로
/// 끌고 갈 수 있다 — 호출부가 전부 리터럴이라 comptime 검사는 공짜다.
pub fn open(io: std.Io, buf: []u8, comptime tag: []const u8) OpenError![:0]u8 {
    comptime {
        if (tag.len == 0) @compileError("scratch tag가 비었다");
        for (tag) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-')
                @compileError("scratch tag는 [a-zA-Z0-9-]만 쓴다(경로 조작 방지): " ++ tag);
        }
    }
    const path = std.fmt.bufPrintZ(buf, "/tmp/maru-{s}-{d}", .{ tag, c.getpid() }) catch
        return error.ScratchUnavailable;
    // 죽은 실행의 잔여물을 상속하지 않는다(파일 머리말 3·4번 고리). 없으면 no-op다.
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const rc = c.mkdir(path.ptr, 0o700);
    if (rc != 0) {
        // `EEXIST`는 위 `deleteTree`가 잔여물을 못 걷었다는 뜻이다 — 다른 실패와 구분해서 보고한다.
        // errno 읽기는 저장소 관례(`posix.errno`)를 쓴다.
        return if (std.posix.errno(rc) == .EXIST)
            error.ScratchResidueUnremovable
        else
            error.ScratchUnavailable;
    }
    return path;
}

/// 테스트가 끝날 때 트리째 지운다. 실패는 무시한다 — 다음 `open`이 어차피 다시 지운다.
///
/// `path`는 **`open`이 준 경로이거나 그것에서 파생된 것**이어야 한다(예: `<open 경로>.pinned`처럼 테스트가
/// rename으로 만든 형제). `open`과 달리 런타임 경로를 받으므로 comptime 방어가 없다 — 파생 경로를 지우는
/// 것이 실제 용도라서 막을 수 없고, 대신 그 계약을 여기 적어 둔다.
pub fn close(io: std.Io, path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "scratch: 이전 실행이 남긴 하위 트리를 상속하지 않는다" {
    const io = std.testing.io;
    var buf: [192]u8 = undefined;

    // 1회차 — 하위 트리를 만들어 둔 채로 **닫지 않는다**(테스트가 죽은 상황을 그대로 만든다).
    const first = try open(io, &buf, "test-scratch-inherit");
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
    // ⚠️ 여기서 `error.ScratchResidueUnremovable`을 skip으로 접지 않는다. pre-clean이 없으면 `mkdir`이
    // `EEXIST`로 실패해 `open`이 `null`을 주는데, skip으로 접으면 그 결함이 **green으로 집계된다**
    // (첫 판 회귀 테스트가 실제로 그랬다 — pre-clean을 지우는 뮤테이션에서 red가 아니라 SKIP이었다).
    // 잔여물이 있어도 여는 것이 이 헬퍼의 계약이므로, 못 열면 그것이 곧 실패다.
    var buf2: [192]u8 = undefined;
    const second = try open(io, &buf2, "test-scratch-inherit");
    defer close(io, second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(c.access(residue.ptr, c.F_OK) != 0); // 잔여 파일이 없다
    try std.testing.expect(c.access(nested.ptr, c.F_OK) != 0); // 잔여 디렉터리도 없다
}

test "scratch: close는 하위 트리가 있어도 지운다" {
    const io = std.testing.io;
    var buf: [192]u8 = undefined;
    const dir = try open(io, &buf, "test-scratch-close");
    var nested_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrintZ(&nested_buf, "{s}/hosts", .{dir});
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(nested.ptr, 0o700));

    close(io, dir);
    // 옛 `rmdir` 정리는 여기서 조용히 실패해 디렉터리를 남겼다 — 그것이 1,969개의 출처다.
    try std.testing.expect(c.access(dir.ptr, c.F_OK) != 0);
}
