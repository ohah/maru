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
const client_source_path = "src/platform/macos/session_host/client.zig";
const session_source_path = "src/platform/macos/app_session.zig";
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

    // ② **남은 침묵도 없앴다**(2026-09-08). 전에는 「예정된 사유이고 보낼 것도 없으면」 조용했는데,
    //    정확히 그 모양으로 끊겼다 — GUI 가 `connection_eof` 를 네 번 찍고 in-process 로 내려가는 동안
    //    host 로그는 40 분간 한 줄도 늘지 않았다. 사유를 잘게 갈라 놔도 줄 자체가 안 나가면 소용없다.
    //    닫기는 연결마다 한 번뿐이라 전부 남겨도 넘치지 않는다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (reason.isExpected() and self.producer_remaining[index] == 0) return;",
    ) == null);
    //    테스트에서만 빠진다. 이것 말고 다른 조기 반환이 생기면 침묵이 되살아난 것이다.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (builtin.is_test) return;") != null);

    // ③ 로그 줄 자체는 그대로 있어야 한다.
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
    // ⑧ **GUI 쪽에도 맞춰 볼 손잡이가 있어야 한다**(2026-09-08). host 가 무엇을 남기든, GUI 가 「무엇을
    //    주고받다 끊겼는지」를 안 남기면 두 로그를 이어붙일 수 없다. `peer_broken` 주석이 2026-09-04 에
    //    요구한 것이 이것이고, 2026-09-08 에 GUI 가 `connection_eof` 를 네 번 찍는 동안 host 로그가 40 분간
    //    한 줄도 안 늘었을 때 다시 필요해졌다.
    const client_raw = try read(a, client_source_path);
    defer a.free(client_raw);
    const client_src = try stripComments(a, client_raw);
    defer a.free(client_src);
    for ([_][]const u8{
        "client read eof:",
        "last_success={d}",
        "in_flight={d}",
        "buffered={d}",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, client_src, needle) != null);

    //    **`poison` 안에서 찍지 않는다.** 거기는 fence 를 잡기 전이라 Client 저장소를 읽으면 안 된다
    //    (exclusive cleanup 콜백에서는 지연 poison 조차 저장소를 못 건드린다 — `poison` 주석). 실제로
    //    거기에 넣었다가 `expectNoUnlistedSelfFieldBefore` 판정자가 잡았다. 이 자리는 `requireBlockingMode`
    //    를 지난 뒤이고 바로 아래 줄이 이미 `parser` 를 읽으므로 같은 종류의 접근이다.
    const poison_at = std.mem.indexOf(u8, client_src, "pub fn poison(self: *Client").?;
    const eof_at = std.mem.indexOf(u8, client_src, "client read eof:").?;
    try std.testing.expect(eof_at < poison_at);

    // ⑨ **죽는 자리와 발견하는 자리 양쪽에 시각이 있어야 한다.** maru 의 로그 줄에는 타임스탬프가 없다
    //    (2026-09-09 실측: 4414 줄 중 6 줄만, 그마저 macOS 가 찍은 것). 그래서 「16 시간 전부터 죽어
    //    있었다」와 「방금 죽었다」를 못 갈랐다 — 둘은 고칠 곳이 완전히 다르다. 두 줄의 차이가 곧
    //    **조용히 죽어 있던 시간**이다.
    //    `info`·`err` 두 갈래 **모두** 찍어야 한다. 하나만 세면 한쪽을 지워도 판정자가 안 문다
    //    (역검증에서 실제로 그랬다).
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, client_src, "client poison: reason={s} at_unix={d}"),
    );
    const session_raw = try read(a, session_source_path);
    defer a.free(session_raw);
    const session_src = try stripComments(a, session_raw);
    defer a.free(session_src);
    //    **갈래별로 못 박는다.** 「접두가 어딘가 있으면 통과」로 세면 한쪽(`client=absent`)만 남아도
    //    판정자가 안 문다 — 역검증에서 실제로 그랬다.
    //    **세 갈래를 모두 못 박는다.** `app_remote_client` 는 비풀(legacy) 전용이라(`term.zig` 가
    //    `if (!pooled) app_remote_client else null` 로 가른다) 풀 구성에서 그것을 읽어 `poisoned=no` 를
    //    찍으면 **엉뚱한 객체의 상태**를 죽은 연결의 것인 양 말하게 된다. 구성을 먼저 밝히고, 상태는
    //    그 구성에서 실제로 쓰이는 객체일 때만 싣는다.
    for ([_][]const u8{
        "host link state at failure: at_unix={d} pooled=yes pool_hosts={d} client_state=unread",
        "host link state at failure: at_unix={d} pooled=no poisoned={s} last_success={d} in_flight={d}",
        "host link state at failure: at_unix={d} pooled=no client=absent",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, session_src, needle) != null);
    // ⑩ **사용자 동작 실패도 어느 갈래인지 말한다.** 사용자에게는 「세션 정보를 동기화하지 못했습니다」
    //    한 문장이지만 여기 오는 길은 여덟이다. 2026-09-09 실측: GUI 가 host 와 끊긴 상태에서 `cmd+v` 가
    //    그 문구를 냈는데, 로그가 0 줄이라 여덟 중 무엇인지 가릴 수 없었다.
    for ([_][]const u8{
        "user action failed: at_unix={d} why={s} kind={s} host_link={s}",
        "active_expired",
        "queued_expired",
        "probe_request_failed",
        "probe_unsupported",
        "probe_stale",
        "target_term_gone",
        "identity_unavailable",
        "identity_changed",
        "observation_read_failed",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, session_src, needle) != null);
    //    사유 없이 부르던 옛 모양이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(u8, session_src, "self.failUserAction(id);") == null);

    //    풀 구성에서 legacy client 를 읽는 모양이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        session_src,
        "host link state at failure: at_unix={d} poisoned={s}",
    ) == null);

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
