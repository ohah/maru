//! host 가 client 연결을 닫을 때 **보낼 것을 든 채 끊긴 경우가 로그에 남는지** 못 박는다.
//!
//! ## 왜 소스를 세는가
//!
//! `logClientClosed` 는 `builtin.is_test` 에서 **곧바로 반환한다** — host stderr 를 파일로 돌리는 제품
//! 경로가 테스트에 없기 때문이다. 그래서 이 계약은 동작 test 로 볼 수 없고, 배선을 여기서 잠근다.
//!
//! ## 무엇이 있었나 (두 번 같은 자리에서 막혔다)
//!
//! `peer_broken` 은 세 조건이 **동시에** 성립해야 붙는다 — 닫는 중이 아니고, poll 이 peer 깨짐을
//! 보고했고, **보낼 것이 남아 있지 않다**(`!client.wantsWrite()`). 즉 host 가 보낼 것을 **든 채** 연결이
//! 깨지면 `client_closing` 으로 분류되고, 예전 가드(`reason.isExpected()`)가 그것을 통째로 침묵시켰다.
//!
//! - 2026-09-04: GUI `last_success_request_id=136440` 뒤 끊김. 양쪽이 서로 「상대가 닫았다」로 기록.
//! - 2026-09-07: GUI `stage=runtime_death error=ConnectionClosed`, host 로그 **0 줄**, 그런데 host 는
//!   `lifecycle=ready` 로 살아 있고 listener 도 정상이었다(클라이언트 0). 같은 침묵이 재발했다.
//!
//! 두 번 다 진단이 **필요한 바로 그 경우에** 스스로 입을 다물었다. 위 함수의 주석이 대조 지점으로 지목한
//! `pending_out` 이 정작 그때 안 찍힌 것이다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/poll_owner.zig";
const turn_source_path = "src/platform/macos/session_host/connection_turn.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다. **부정 단언은 반드시 이것을 지나야 한다** — 위 머리말이 옛 가드를 그대로 인용하므로,
/// 벗기지 않으면 「설명하는 주석」이 「쓰는 코드」로 세어진다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "보낼 것을 든 채 끊긴 연결은 «정상» 으로 분류돼도 로그에 남는다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 옛 가드가 되살아나면 빨개진다. 이것 하나가 두 번의 추적을 막았다.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (builtin.is_test or reason.isExpected()) return;") == null);

    // ② 침묵 조건에 **보낼 것이 없다** 가 함께 걸려 있어야 한다. `isExpected()` 만으로 침묵하면 안 된다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (reason.isExpected() and self.producer_remaining[index] == 0) return;",
    ) != null);

    // ③ 진짜 정상 종료는 여전히 침묵해야 한다 — 연결마다 찍으면 그 소음이 이 로그를 다시 못 읽게 만든다.
    //    그 뜻은 ②의 `== 0` 이 담고 있으므로, 가드가 통째로 사라지지 않았는지만 확인한다.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn logClientClosed(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pending_out={d}") != null);

    // ④ **안쪽 사유까지 싣는다**(2026-09-08). 바깥 `ClientCloseReason` 의 `client_closing` 하나가
    //    `connection_turn.CloseReason` 열 가지(eof · socket_error · protocol_error · resource_exhausted ·
    //    admission_closed · peer_requested · reply_flushed · partial_timeout · upgrade_completed ·
    //    upgrade_failed)를 통째로 뭉갠다. 실측에서 「host 가 먼저 닫았다」까지는 갈렸는데 그 열 중
    //    무엇인지 몰라 멈췄다 — `protocol_error` 와 `resource_exhausted` 와 `partial_timeout` 은 고칠
    //    곳이 완전히 다르다.
    try std.testing.expect(std.mem.indexOf(u8, src, "why={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "closeReason()") != null);

    // ⑤ **사유만으로는 못 좁힌다.** `socket_error` 는 호출부가 29 곳, `resource_exhausted` 는 18 곳이라
    //    사유 하나로는 어느 지점인지 갈리지 않는다. 호출 지점 주소와 ASLR 슬라이드를 함께 남겨
    //    `atos -o <바이너리> -l <slide> <why_ra>` 로 사후 복원한다 — `client.zig` 의 poison 로그와 같은
    //    관례다. 슬라이드가 빠지면 앱이 다시 뜬 순간 주소는 뜻 없는 숫자가 된다.
    try std.testing.expect(std.mem.indexOf(u8, src, "why_ra=0x{x}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "slide=0x{x}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "_dyld_get_image_vmaddr_slide") != null);

    // ⑥ `beginClose` 는 **인라인되면 안 된다.** 인라인되면 `@returnAddress()` 가 닫기로 한 지점이 아니라
    //    그 위 프레임을 가리켜, 사유와 지점이 어긋난 채 로그에 남는다.
    const turn_raw = try read(a, turn_source_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);
    try std.testing.expect(std.mem.indexOf(u8, turn, "noinline fn beginClose(") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn, "self.close_ra = @returnAddress();") != null);

    // ⑦ `validateProcessIdentity` 가 거짓이 되는 길은 **둘**인데(봉인을 못 읽음 / 신원이 달라짐) 호출부가
    //    셋이라 `why_ra` 로도 안 갈린다. 두 길이 각자 말해야 한다 — 앞은 `process_seal_service` 를,
    //    뒤는 상대 프로세스를 보게 만든다.
    try std.testing.expect(std.mem.indexOf(u8, turn, "process identity unreadable") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn, "process identity changed") != null);
    //    말없이 거짓을 돌려주던 옛 모습이 되살아나면 빨개진다. 이 단언이 실제로 물어서, 처음에 놓친
    //    두 곳(`validatePreparedCatchup`·`commitCatchupArm`)을 찾아냈다 — 셋 다 같은 침묵이었다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        turn,
        "process_seal_service.currentReadyIdentity() catch return false;",
    ) == null);
    //    셋이 같은 문구를 쓰면 다시 합쳐지므로 `where=` 로 갈라 둔다.
    try std.testing.expect(std.mem.indexOf(u8, turn, "where={s}") != null);
    for ([_][]const u8{
        "\"validateProcessIdentity\"",
        "\"validatePreparedCatchup\"",
        "\"commitCatchupArm\"",
    }) |where| try std.testing.expect(std.mem.indexOf(u8, turn, where) != null);
}
