//! **이벤트당 비용을 줄일 수 있는지 판단할 두 숫자**가 계속 나오는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 실측 — 터미널 브라우저가 렌더링하는 동안 maru 주 스레드 작업의 **54 %** 가 관측
//! 이벤트당 정규 투영 + 해싱이었다(`memcpy` 23 %, BLAKE3 24 %, 제로화 7 %). 비용은 이렇게 잡혔는데,
//! **줄일 수 있는 비용인지는 알 수 없었다.**
//!
//! 가장 유력한 수단인 「한 틱에 도착한 이벤트를 합쳐 다이제스트를 1 회만」의 이득은 전적으로
//! `events / drain_calls` 에 비례한다 — 그 값이 1 이면 이득은 **0** 이고 복잡도만 남는다. 그리고
//! `digests / events` 는 생산 경로가 셋이라 2~3 이 예상되는데, 그보다 크면 같은 관측을 중복
//! 해싱한다는 뜻이라 그 자체가 줄일 거리가 된다.
//!
//! 두 비를 모른 채 최적화를 붙이면 그건 측정이 아니라 추측이다. 그래서 계측이 먼저다.
//!
//! ## 이 판정자가 고정하는 것
//!
//! ① 모든 관측 다이제스트가 통과하는 **단일 지점**에서 센다 — 다른 자리에서 세면 경로가 늘 때 샌다.
//! ② 진단이 **두 비를 모두** 낸다 — 하나만 내면 판단이 반쪽이 된다.
//! ③ 카운터는 원자적이다 — 이 함수들은 여러 스레드에서 불린다. 평범한 `+=` 는 자료 경합(UB)이다.

const std = @import("std");

const seal_path = "src/platform/macos/session_host/event_cleanup_seal.zig";
const runtime_path = "src/platform/macos/session_host/remote_runtime.zig";
const session_path = "src/platform/macos/app_session.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말이 계약을 그대로 인용하므로, 벗기지 않으면 「설명하는 주석」이
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

fn has(src: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, src, needle) != null;
}

test "관측 이벤트 비용 계측: 단일 지점에서 원자적으로 세고, 두 비를 모두 낸다" {
    const a = std.testing.allocator;

    const seal_raw = try read(a, seal_path);
    defer a.free(seal_raw);
    const seal = try stripComments(a, seal_raw);
    defer a.free(seal);

    // ① 모든 관측 다이제스트가 지나는 단일 지점에서 센다. 이 함수 안이 아니면 경로가 늘 때 샌다.
    const funnel_at = std.mem.indexOf(u8, seal, "pub fn observationCleanupDigest(") orelse
        return error.DigestFunnelMissing;
    const funnel_end = std.mem.indexOfPos(u8, seal, funnel_at, "\n}\n") orelse seal.len;
    const funnel = seal[funnel_at..funnel_end];
    if (!has(funnel, "observation_digest_calls") or !has(funnel, "observation_digest_input_bytes")) {
        std.debug.print("단일 지점이 세지 않는다 — 다른 자리에서 세면 경로가 늘 때 샌다\n", .{});
        return error.DigestNotCountedAtFunnel;
    }

    // ③ 원자적이어야 한다. 이 경로는 여러 스레드에서 불린다.
    try std.testing.expect(has(funnel, "@atomicRmw"));
    try std.testing.expect(!has(funnel, "observation_digest_calls +=") and
        !has(funnel, "observation_digest_calls +%="));

    const runtime_raw = try read(a, runtime_path);
    defer a.free(runtime_raw);
    const runtime = try stripComments(a, runtime_raw);
    defer a.free(runtime);

    // 드레인 횟수와 정산된 이벤트 수 — 이 둘의 비가 병합의 이득 그 자체다.
    for ([_][]const u8{
        "observation_drain_calls",
        "observation_events_settled",
        "pub fn observationEventCounters()",
    }) |needle| try std.testing.expect(has(runtime, needle));
    try std.testing.expect(has(runtime, "@atomicRmw(u64, &observation_drain_calls, .Add"));
    try std.testing.expect(has(runtime, "@atomicRmw(u64, &observation_events_settled, .Add"));

    // 씰 카운터는 **호출 수가 아니라 바이트**도 센다. 고정 크기 구조체를 통째로 넘기는 자리라,
    // 바이트를 안 세면 「내용 한 줄 바뀌었는데 5.8 KB 를 해싱한다」가 보이지 않는다.
    const prep_raw = try read(a, "src/platform/macos/session_host/pending_event_preparation.zig");
    defer a.free(prep_raw);
    const prep = try stripComments(a, prep_raw);
    defer a.free(prep);
    try std.testing.expect(has(prep, "@atomicRmw(u64, &seal_calls, .Add"));
    try std.testing.expect(has(prep, "@atomicRmw(u64, &seal_raw_digest_bytes, .Add, bytes.len"));
    // 세는 자리가 `rawDigest` 안이어야 한다 — 호출자마다 세면 자리가 늘 때 샌다.
    // **시그니처를 통째로 잠그지 않는다.** 2026-09-11: 자리별 귀속을 위해 `site` 인자를 더했더니 이
    // 판정자가 리터럴 불일치로 개선을 막았다(`RawDigestFunnelMissing`). 여기서 고정할 의도는
    // 「이름이 `rawDigest` 인 함수가 하나 있고, 그 안에서 바이트를 센다」이지 인자 목록이 아니다.
    const raw_at = std.mem.indexOf(u8, prep, "fn rawDigest(") orelse
        return error.RawDigestFunnelMissing;
    const raw_end = std.mem.indexOfPos(u8, prep, raw_at, "\n}\n") orelse prep.len;
    try std.testing.expect(has(prep[raw_at..raw_end], "seal_raw_digest_bytes"));

    const session_raw = try read(a, session_path);
    defer a.free(session_raw);
    const session = try stripComments(a, session_raw);
    defer a.free(session);

    // ② 진단이 **두 비를 모두** 낸다. 하나만 내면 판단이 반쪽이 된다.
    for ([_][]const u8{
        "events_per_drain_x100",
        "digests_per_event_x100",
        "digest_bytes",
        // **씰 기계의 구조체 통째 해싱까지 센다.** 최종 다이제스트만 세면 비용의 96 % 를 놓친다 —
        // 실측에서 `sealInput` 이 BLAKE3 의 39 %, `observationCleanupDigest` 는 4 % 였다.
        "seals_per_event_x100",
        "raw_digest_bytes",
    }) |needle| {
        if (!has(session, needle)) {
            std.debug.print("진단에 «{s}» 이 없다 — 두 비가 다 있어야 판단이 선다\n", .{needle});
            return error.DiagnosticRatioMissing;
        }
    }
    // 조용할 때는 한 줄도 안 찍어야 로그가 원인을 덮지 않는다.
    try std.testing.expect(has(session, "if (events == 0) return;"));
    try std.testing.expect(has(session, "if (!any) return;"));

    // ③ **진단 장부는 프로세스 전역이다.** 세는 카운터가 전역인데 장부를 세션마다 두면 창이 둘일 때
    //    같은 증분을 각자 소비해 **값까지 똑같은 줄이 두 번** 찍힌다.
    //
    //    2026-09-12 실측: 로그 최근 300 줄 중 **276 줄(92 %)이 이 진단**이었고 그중 절반이 중복이었다.
    //    진짜 신호는 5 줄(1.7 %). 그 탓에 시작 시점의 `session host upgrade result` 가 회전으로 밀려나
    //    「업그레이드가 왜 안 됐나」를 앱을 두 번 재시작하며 헛짚었다 — **진단이 진단을 지웠다.**
    for ([_][]const u8{
        "var diag_obs_tick: u32 = 0;",
        "var diag_site_tick: u32 = 0;",
        "var diag_last_drain_calls: u64 = 0;",
        "var diag_site_last_calls = ",
    }) |needle| {
        if (!has(session, needle)) {
            std.debug.print("진단 장부 «{s}» 가 전역이 아니다 — 창마다 같은 줄이 두 번 찍힌다\n", .{needle});
            return error.DiagnosticLedgerNotGlobal;
        }
    }
    // 세션 필드로 되돌아가면 빨개진다.
    try std.testing.expect(!has(session, "obs_diag_last_drain_calls: u64 = 0,"));
    try std.testing.expect(!has(session, "digest_site_last_calls: ["));

    // ④ **자리별 내역은 총량보다 드물게 찍는다.** 한 번에 네 줄이라 같은 주기면 로그의 대부분을 차지한다.
    //
    //    **값이 아니라 관계를 고정한다.** 처음엔 `= 3600;` 을 통째로 잠갔는데, 30 초로 «조정» 하는 것도
    //    빨개졌다(적대적 검증 Z1) — 의도는 「총량보다 드물다」이지 특정 숫자가 아니다. 오늘 이 실수를
    //    네 번 했다.
    const site_iv = parseConst(session, "const digest_site_interval_ticks: u32 = ") orelse
        return error.SiteIntervalMissing;
    const total_iv = parseConst(session, "const notify_diag_interval_ticks: u32 = ") orelse
        return error.TotalIntervalMissing;
    if (site_iv <= total_iv) {
        std.debug.print(
            "자리별 간격 {d} 이 총량 간격 {d} 이하 — 네 줄짜리가 같은 주기면 로그를 덮는다\n",
            .{ site_iv, total_iv },
        );
        return error.SiteIntervalNotRarer;
    }

    // ⑤ 게이트는 **표본을 읽기 전에** 있어야 한다. 뒤에 두면 매 틱 읽고 버려 비용만 남는다(Z5).
    const fn_at = std.mem.indexOf(u8, session, "fn logDigestSiteDiag() void {") orelse
        return error.SiteDiagMissing;
    // 게이트는 **자기 틱**을 세야 한다. 총량의 틱을 쓰면 같은 주기로 돌아 드물게 찍는 의미가 사라진다(Z2).
    const gate_at = std.mem.indexOfPos(u8, session, fn_at, "diag_site_tick % digest_site_interval_ticks != 0") orelse
        return error.SiteGateMissing;
    const sample_at = std.mem.indexOfPos(u8, session, fn_at, "digestSiteSamples(") orelse
        return error.SiteSampleMissing;
    try std.testing.expect(gate_at < sample_at);

    // ⑥ 장부를 **갱신한다.** 안 하면 매 창의 증분이 누적 전체가 되어 숫자가 조용히 거짓이 된다(Z3).
    for ([_][]const u8{
        "diag_site_last_calls[i] = sample.calls;",
        "diag_site_last_bytes[i] = sample.bytes;",
    }) |needle| {
        if (!has(session, needle)) {
            std.debug.print("장부 갱신 «{s}» 이 없다 — 증분이 누적 전체가 된다\n", .{needle});
            return error.LedgerNotAdvanced;
        }
    }
}

/// `const <이름> = <숫자>;` 에서 숫자만 읽는다. 값을 리터럴로 잠그지 않고 **관계**를 재기 위한 것이다.
fn parseConst(src: []const u8, decl: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, src, decl) orelse return null;
    const rest = src[at + decl.len ..];
    const end = std.mem.indexOfAny(u8, rest, ";\n") orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, rest[0..end], " "), 10) catch null;
}
