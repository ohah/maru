//! **해싱 대역폭을 어느 자리가 쓰는지** 갈리는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 실측 — 드레인 **2,032 회/초**에 다이제스트 **944 회**·**6.51 MB/초**를 해싱하는데, 실제
//! 이벤트는 **20 회/초**뿐이었다. 비용이 이벤트가 아니라 **드레인 빈도**를 따라간다.
//!
//! 그런데 총량만으로는 고칠 수 없다. `sealInput` 이 한 번에 5,816 B 이고 씰이 드레인당 0.197 회이니
//! 1,146 B/드레인인데, 실측은 **3,359 B/드레인** 이다 — **나머지 2,200 B 의 출처를 몰랐다.**
//!
//! 자리마다 줄이는 방법이 정반대다:
//!   - 불변 구조체 재해싱 → 캐시 (다만 #3557 에서 그 전제가 틀렸음이 드러났다)
//!   - 검증용 재계산 → 건드리면 씰이 거짓이 된다
//!   - DTO 내용 → 내용이 실제로 바뀐다
//!
//! 총량 하나로는 이 셋이 뭉쳐 「무엇을 줄일 수 있는가」가 안 갈린다.

const std = @import("std");

const prep_path = "src/platform/macos/session_host/pending_event_preparation.zig";
const session_path = "src/platform/macos/app_session.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

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

fn countIn(src: []const u8, needle: []const u8) usize {
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, needle)) |found| : (at = found + needle.len) seen += 1;
    return seen;
}

test "해싱 자리: 모든 생산 지점이 서로 다른 이름으로 세어진다" {
    const a = std.testing.allocator;
    const prep_raw = try read(a, prep_path);
    defer a.free(prep_raw);
    const prep = try stripComments(a, prep_raw);
    defer a.free(prep);

    // ① `rawDigest` 는 **자리를 반드시 받는다.** 인자 없는 형태가 남으면 그 자리는 안 세어진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        prep,
        "fn rawDigest(site: DigestSite, domain: []const u8, bytes: []const u8)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prep, "rawDigest(\"maru.") == null);

    // ② 자리마다 **정확히 한 번씩** 쓰인다. 둘이 같은 이름을 쓰면 로그가 있어도 안 갈린다.
    for ([_][]const u8{
        ".seal_snapshot,",
        ".seal_recipe,",
        ".seal_scratch,",
        ".seal_ranges,",
        ".seal_alloc_ctx,",
        ".obs_transfer_verify,",
        ".obs_snapshot,",
        ".obs_transfer_store,",
    }) |site| {
        const seen = countIn(prep, site);
        if (seen != 1) {
            std.debug.print("자리 «{s}» 가 {d} 번 — 정확히 1 번이어야 갈린다\n", .{ site, seen });
            return error.DigestSiteNotUnique;
        }
    }

    // ③ 카운터는 원자적이다 — 이 경로는 여러 스레드에서 불린다.
    try std.testing.expect(std.mem.indexOf(u8, prep, "@atomicRmw(u64, &digest_site_calls[index], .Add") != null);
    try std.testing.expect(std.mem.indexOf(u8, prep, "@atomicRmw(u64, &digest_site_bytes[index], .Add") != null);

    const session_raw = try read(a, session_path);
    defer a.free(session_raw);
    const session = try stripComments(a, session_raw);
    defer a.free(session);

    // ④ 진단이 **이름과 바이트를 함께** 낸다. 호출 수만으로는 대역폭이 안 보이고, 바이트만으로는
    //    「한 번에 큰가 여러 번인가」가 안 갈린다.
    try std.testing.expect(std.mem.indexOf(u8, session, "digest site: name={s} calls={d} bytes={d}") != null);
    // ⑤ 조용하면 한 줄도 안 찍는다 — 유휴 상태에서 로그가 원인을 덮지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, session, "if (!any) return;") != null);
}
