//! 원격 이벤트 스트리머에서 **커서의 이름 축**을 고정한다.
//!
//! ## 왜 판정자가 필요한가
//!
//! 스트리머는 파일마다 이름을 **둘** 쥔다.
//!
//! - `nonce` — 파일 이름(`nonceFromFileName`). 이 프로세스가 **다음 회차에 그 파일을 다시 찾는 열쇠**다.
//! - `emit_nonce` — RA6 역조회로 치환된 이름. tmux 안에서 `LC_MARU_PANE` 이 오염돼도 **어느 Term 의
//!   이벤트인가**를 되찾기 위한 것이다.
//!
//! **이벤트는 `emit_nonce`, 커서는 `nonce` 다.** 이 둘이 어긋나면 두 기능이 **각자 초록인 채로** 사슬이
//! 끊긴다. 실제로 그렇게 깨져 있었다(2026-09-03).
//!
//! 커서를 `emit_nonce` 로 실으면 로컬이 그 이름으로 기억했다가 `--resume=` 으로 돌려주는데, 스트리머는
//! `cursors.getOrPut(…, nonce)` 로 찾으므로 **못 맞춘다**. 오프셋이 0 에 머물러 재접속마다 파일을
//! 처음부터 다시 읽고(이벤트 중복), `shouldTruncate` 의 `cur.offset == size` 가 영영 거짓이라 파일도
//! 안 비워진다. 실측 비대칭이 그것을 드러냈다 — 역조회가 도는 `t*` 는 400~950KB 로 자라 있는데 치환이
//! 없는 `host_*` 는 1.5KB 였다.
//!
//! **로컬은 커서 이름을 귀속에 쓰지 않는다**(`recordRemoteCursors` — 재개 문자열을 만들 때 그대로
//! 되돌려 보내는 왕복 토큰이다). 그래서 파일 이름을 실어도 사이드바 판정은 안 달라지고, 파일 이름은
//! 역조회 결과와 달리 **주인이 바뀌어도 안 변한다**.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}

/// 한 호출의 인자 목록을 자른다. **`max` 를 넘으면 실패한다** — 닫는 괄호를 못 찾으면 슬라이스가 파일
/// 끝까지 달아나고, 그러면 아래 needle 이 **아무 데서나** 걸려 판정자가 통째로 초록이 된다.
fn callArgs(src: []const u8, head: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.CallMissing;
    const from = at + head.len;
    const end = std.mem.indexOfScalarPos(u8, src, from, ')') orelse return error.CallUnterminated;
    if (end - from > max) return error.CallRunaway;
    return src[from..end];
}

test "스트리머: 이벤트는 치환된 이름으로, 커서는 파일 이름으로 나간다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "src/main.zig");
    defer allocator.free(src);

    // ── 커서는 **파일 이름**이다. 깨지면 `--resume` 이 아무것도 못 이어 붙인다.
    var it = std.mem.splitSequence(u8, src, "ae.formatCursor(");
    _ = it.next(); // 첫 조각은 호출 앞의 본문이다
    var cursor_calls: usize = 0;
    while (it.next()) |rest| {
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse return error.CallUnterminated;
        const args = rest[0..end];
        cursor_calls += 1;
        if (std.mem.indexOf(u8, args, "emit_nonce") != null) {
            std.debug.print("커서를 치환된 이름으로 보낸다 — 재접속이 못 이어 붙는다: {s}\n", .{args});
            return error.CursorUsesEmitNonce;
        }
        try std.testing.expect(std.mem.indexOf(u8, args, "nonce") != null);
    }
    // **개수를 센다.** 호출이 0 이면 위 while 이 통째로 안 돌고 판정자가 조용히 초록이 된다
    // (「부재」와 「통과」를 가르는 자리 — 이 저장소에서 반복해 물린 부류다).
    try std.testing.expect(cursor_calls >= 2);

    // ── 이벤트는 **치환된 이름**이다. 뒤집히면 RA6 귀속이 무너져 배지가 엉뚱한 Term 에 선다.
    const event_args = try callArgs(src, "ae.formatEvent(", 200);
    try std.testing.expect(std.mem.indexOf(u8, event_args, "emit_nonce") != null);

    // ── 커서 맵의 키도 **파일 이름**이다. 위와 이것이 같아야 사슬이 이어진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "cursors.getOrPut(allocator, nonce)") != null);
}
