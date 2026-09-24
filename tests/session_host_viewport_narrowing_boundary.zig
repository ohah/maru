const std = @import("std");

// S11-6 「남이 좁혔나」의 **판정 자리**를 구조로 못 박는다.
//
// 이 게이트가 있는 이유는 실제로 두 번 밟았기 때문이다.
//
// ① 처음에 `narrowed_cols` 를 legacy 이벤트 갈래에만 적었다. 그런데 크기를 게시하는 자리는
//    **둘**이다 — attachment 가 `.legacy` 면 `drainLegacyObservationEvents`, `.generation` 이면
//    prepared semantic commit 이 게시한다. 제품이 쓰는 것은 후자라, 관측 크기는 갱신되는데
//    이 값만 0 이어서 **맥 상태줄 표시가 통째로 안 떴다**. 화면만 봐서는 「폰이 안 붙었나 보다」
//    와 구별되지 않는다.
// ② `RemoteRuntime` 은 `var rr: RemoteRuntime = undefined` 에서 in-place 로 서므로 **필드
//    기본값(`= 0`)이 안 먹는다.** spawn/attach 가 이 둘을 안 쓰면 쓰레기가 남고, 폰이 붙은 적
//    없는 세션의 상태줄에 「폰 43690열」(0xAAAA) 이 뜬다.
//
// 그래서 값 판정은 판정자가 하고, **자리**는 여기가 센다.
test "S11-6 narrowed boundary: host 가 확정한 크기를 게시하는 두 자리가 좁힘을 다시 판정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);

    // 판정은 한 자리에만 산다 — 흩어지면 한쪽만 고쳐진다(①이 그렇게 났다).
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn noteHostAppliedCols("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "narrowedFrom(self.requested_cols"));

    // **두 «이벤트» 경로가 모두 부른다.** 새 경로가 생기면 이 수가 안 맞아 여기서 걸린다.
    //
    // **여기서 세는 것은 「host 가 방금 확정한 크기」를 게시하는 자리뿐이다.** 크기를 싣는 자리는
    // 그 밖에도 있지만 일부러 판정하지 않는다(적대적 검증 1회차에 전수로 확인했다) —
    //  · `applyMetadataDto` 의 관측 DTO(`.size = .{ .cols = dto.cols, ... }`): 주기적 관측이라
    //    「방금 확정한 순간」이 아니다. 여기서 판정하면 확정 전 관측으로 표시가 번쩍인다.
    //  · `candidate.observation.size`(재연결 승격 리사이즈): **내가** 요청한 크기라 남이 좁힌 것이
    //    아니다.
    // 즉 이 게이트의 계약은 「크기를 싣는 모든 곳」이 아니라 **「확정 이벤트를 적용하는 곳」**이다.
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.noteHostAppliedCols("));
    try std.testing.expectEqual(
        @as(usize, 2),
        count(runtime, "self.currentGeneration().observation.size = "),
    );

    // **개수만 세면 «자리» 를 못 지킨다**(적대적 검증 3회차에 내 게이트에서 찾은 구멍이다).
    // 판정을 `applyResizeFullState` 안으로 옮기면 호출 수는 그대로 2 인데 **리사이즈 응답
    // 경로까지** 판정하게 된다. 그 순간 `requested_cols` 는 아직 **이전** 요청이라
    // 「내가 창을 줄였다」가 「남이 좁혔다」로 뒤집힌다 — 계약이 금지한 거짓 표시다.
    // 그래서 두 호출이 각각 «어느 자리에» 있는지를 앵커와 함께 못 박는다.
    // 두 호출은 서로 다른 인자로 서 있다 — 각각 제 자리에 하나씩이다.
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.noteHostAppliedCols(decision.cols);"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.noteHostAppliedCols(size.cols);"));
    // **응답 경로가 지나는 공용 적용기 «안» 에는 없어야 한다.** 개수만 세면 이 이동을 놓친다 —
    // 그래서 그 함수의 본문 범위를 잘라 직접 본다(서식이 바뀌어도 견딘다).
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn applyResizeFullState("));
    try std.testing.expectEqual(
        @as(usize, 0),
        count(bodyOf(runtime, "fn applyResizeFullState("), "noteHostAppliedCols"),
    );

    // ②: in-place 초기화 두 자리(spawn·attachExisting)가 둘 다 이 상태를 0 으로 쓴다.
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.requested_cols = 0;"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.narrowed_cols = 0;"));

    // **조정은 폴 회차마다 돈다 — 「출력이 있을 때」가 아니다.** 처음에 그 호출이 출력 wake
    // 갈래 안에 있어, 출력이 없는 세션은 폰이 선언해도 영영 안 좁아졌다(적대적 검증 4회차).
    // 다시 어느 갈래 «안» 으로 들어가면 여기서 걸린다 — `pollOnce` 본문에서 그 호출이 조건문
    // 아래로 들어갔는지는 세지 못하므로, **조건 없는 머리 자리**의 모양을 그대로 못 박는다.
    const owner_loop = try readSource(allocator, "src/platform/macos/session_host/poll_owner.zig");
    defer allocator.free(owner_loop);
    try std.testing.expectEqual(@as(usize, 1), count(owner_loop, "reconcileViewports(self);"));
    try std.testing.expectEqual(@as(usize, 1), count(
        owner_loop,
        "if (self.armed_upgrade != null) return .upgrade_ready;",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        bodyOf(owner_loop, "if (poll_fds[1].revents & c.POLL.IN != 0) {"),
        "reconcileViewports",
    ));

    // **`--stream` 루프는 control 을 실으면 스스로 쓰기 관심을 세우고, 쓰기 턴에 RX 프리픽스를
    // 함께 돈다**(ANSI 루프 `external_loop_owner` 와 같은 계약). 둘 중 하나라도 빠지면 조용한
    // 세션에서 선언이 큐에 실린 채 영영 안 나간다 — 실기에서 그 상태로 잡혔다(2026-09-03).
    const stream_cli = try readSource(allocator, "src/platform/macos/session_host/external_attach_cli.zig");
    defer allocator.free(stream_cli);
    try std.testing.expectEqual(@as(usize, 1), count(
        stream_cli,
        "if (viewport.drain(&owner, stderr)) {\n                write_interest = true;",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        stream_cli,
        ".readable = (ready > 0 and fds[0].revents & posix.POLL.IN != 0) or socket_writable,",
    ));

    // **TX 자격은 「관측자가 낼 수 있는 control 인가」로 판정한다** — `detach` 를 이름으로 박지
    // 않는다. 그 술어의 단일 출처는 `ControlKind.requiresController()` 다.
    const pump = try readSource(allocator, "src/platform/macos/session_host/client_external_pump.zig");
    defer allocator.free(pump);
    try std.testing.expectEqual(@as(usize, 1), count(pump, "fn observerControlTxIsSoleFrame("));
    try std.testing.expectEqual(@as(usize, 0), count(pump, "observerDetachTxIsSoleFrame"));
    try std.testing.expectEqual(@as(usize, 1), count(pump, "control.kind.requiresController() or"));
    // 기대↔종류 대조는 admission 과 자격 판정이 **같은 함수**를 쓴다.
    const correlation = try readSource(allocator, "src/platform/macos/session_host/client_control_correlation.zig");
    defer allocator.free(correlation);
    try std.testing.expectEqual(@as(usize, 1), count(correlation, "pub fn expectationMatchesKind("));
    try std.testing.expectEqual(@as(usize, 1), count(correlation, "!expectationMatchesKind(expectation, kind)"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(pump, "client_control_correlation.expectationMatchesKind("),
    );

    // 이 상태를 읽는 제품 소비처는 상태줄 하나뿐이다 — 늘어나면 그 자리도 위 계약을 알아야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(app, ".narrowedCols()"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "fn activeTermNarrowedCols("));

    // 주입은 **테스트 전용**이고 `builtin.is_test` 뒤에만 있다. 제품 갈래로 새면 실서버에서
    // 조회가 통째로 죽어도 판정자가 초록이 된다(이 축의 판정자가 실제로 그래서 헛돌았다).
    try std.testing.expectEqual(
        @as(usize, 1),
        count(app, "if (builtin.is_test) if (test_narrowed_cols_override)"),
    );
    // 세는 것은 **읽는 자리**뿐이다. 판정자가 넣고 되돌리는 자리는 늘어도 되므로 총 개수는
    // 안 센다 — 그 수를 박으면 판정자를 하나 더 쓸 때마다 무관한 게이트가 깨진다.
}

/// `marker` 로 시작하는 함수의 본문 범위. 다음 함수 선언(`\n    fn ` / `\n    pub fn `) 앞까지다.
/// 없으면 빈 조각을 돌려주는 대신 **원문 전체**를 돌려준다 — 그래야 마커가 사라졌을 때 이 게이트가
/// 「0 개」로 조용히 통과하지 않는다.
fn bodyOf(haystack: []const u8, marker: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, haystack, marker) orelse return haystack;
    const rest = haystack[at + marker.len ..];
    const end_a = std.mem.indexOf(u8, rest, "\n    fn ");
    const end_b = std.mem.indexOf(u8, rest, "\n    pub fn ");
    const end = if (end_a) |a| (if (end_b) |b| @min(a, b) else a) else (end_b orelse rest.len);
    return rest[0..end];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
