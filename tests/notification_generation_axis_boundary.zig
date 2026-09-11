//! **라벨 하나가 바뀌었다고 나머지 runtime 전부에게 다시 보내면 안 된다.**
//!
//! ## 무엇이 있었나
//!
//! 프레임 루프의 **33%** 가 알림 바인딩 동기화였다(2026-09-10 가중 프로파일). 원인은 세대 축이
//! 하나뿐이라는 것이었다 — `configureNotificationBinding` 이 라벨 하나를 고치며 **전역**
//! `notification_config_generation` 을 올리면, 나머지 N-1 개 entry 가 stale 이 돼 다음 틱에
//! `configureNotifications` 가 **전원 재전송**했다.
//!
//! 제품 계측으로 실측했다(2026-09-11, 세션 22 개):
//!
//!     notification rpc: ticks=300 label_changed=41 generation_stale=646 failed=0
//!     notification rpc: ticks=300 label_changed=25 generation_stale=456 failed=0
//!
//! **실패는 0** 이었다 — 재시도 폭주가 아니라 순수한 증폭이다. 라벨 41 건에 불필요한 재전송이
//! 646 건, 약 **16 배**다.
//!
//! ## 왜 entry 별 세대로 충분한가
//!
//! host 는 `records.getPtr(runtime_id)` 로 꺼낸 **그 runtime 레코드하고만** 비교한다
//! (`notification_delivery`: `next.config_generation <= record.config_generation` → `stale_config`).
//! 즉 세대는 처음부터 **runtime 별 축**이었고, 클라이언트만 공유 카운터를 쓰고 있었다.
//! `configureNotificationBinding` 의 주석도 *"generation은 runtime metadata별 축"* 이라 적는다 —
//! **주석이 옳고 구현이 어긋나 있었다.**
//!
//! ## 왜 소스를 세는가
//!
//! 이 계약을 값으로 재려면 실제 daemon 을 fork 해야 한다(기존 `P4 N2b1` 테스트가 그렇게 한다).
//! 계약 자체는 「라벨 경로가 전역 카운터를 안 건드린다」는 한 줄이고, 그 한 줄이 사라지는 것이 곧
//! 회귀이므로 배선을 여기서 잠근다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/remote_term_backend.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말과 코드 주석이 옛 모습을 인용하므로, 벗기지 않으면 「설명하는 주석」이
/// 「쓰는 코드」로 세어진다.
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

fn sliceOfFn(src: []const u8, signature: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, src, signature) orelse return error.FunctionGone;
    const rest = src[start..];
    const end = std.mem.indexOf(u8, rest[1..], "\n    pub fn ") orelse rest.len - 1;
    return rest[0 .. end + 1];
}

test "라벨 변경은 전역 세대를 올리지 않는다 (전원 재전송 증폭 차단)" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 라벨 경로는 **전역 카운터에 대입하지 않는다.** 이 한 줄이 증폭의 전부였다.
    const bind = try sliceOfFn(src, "pub fn configureNotificationBinding(");
    try std.testing.expect(std.mem.indexOf(u8, bind, "self.notification_config_generation =") == null);

    // ② 라벨 경로가 보내는 세대는 **그 entry 의 다음 값**이어야 한다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        bind,
        "entry.notification_config_applied_generation, 1",
    ) != null);

    // ③ 토글 경로의 «건너뛰기» 판정은 **토글 축**으로 한다. 라벨 축으로 비교하면 ①을 지켜도
    //    라벨 전송이 그 값을 움직여 다시 전원이 stale 이 된다.
    const cfg = try sliceOfFn(src, "pub fn configureNotifications(");
    try std.testing.expect(std.mem.indexOf(
        u8,
        cfg,
        "if (entry.notification_osc_applied_generation == self.notification_config_generation) continue;",
    ) != null);

    // ④ 실패 보상은 **토글 축만** 되돌린다. 라벨 세대를 0 으로 낮추면 host 의 단조 검사
    //    (`next.config_generation <= record.config_generation`)에 걸려 다음 전송이 거절된다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        cfg,
        "retry_entry.notification_config_applied_generation = 0;",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        cfg,
        "retry_entry.notification_osc_applied_generation = 0;",
    ) != null);
}
