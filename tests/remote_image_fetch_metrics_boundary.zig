//! 원격 그림 왕복 계측이 **배선돼 있는가**.
//!
//! 순수 판정자(`RemoteFetchTotals`)는 셈과 갈래를 재고, 시계 판정자는 `monotonicNs` 를 잰다. 그런데
//! 그 둘을 **제품이 실제로 쓰는가**는 아무도 안 봤다 — 워커가 값을 안 실어도, 수확이 `add` 에 0 을
//! 넘겨도 게이트가 초록이었다(적대적 검증 2회차 I1·I2).
//!
//! 실제 ssh 왕복은 원격 호스트가 있어야 만들어지므로 그 축은 여기서 글자로 고정한다. **존재가 아니라
//! 무엇을 넘기는지**를 겨눈다 — 「`add(` 가 있다」로는 `add(ns, 0)` 을 못 잡는다.

const std = @import("std");

test "원격 그림 계측: 워커가 값을 싣고 수확이 그 값 그대로 누적한다" {
    const allocator = std.testing.allocator;
    const decode = try read(allocator, "src/platform/macos/agent_image_decode_backend.zig", 512 * 1024);
    defer allocator.free(decode);
    const activity = try read(allocator, "src/platform/macos/app_session/agent_activity.zig", 4 * 1024 * 1024);
    defer allocator.free(activity);

    // 워커가 왕복을 **감싸서** 잰다 — 시계 둘 사이에 그 호출이 있어야 잰 것이 왕복이다.
    try std.testing.expectEqual(@as(usize, 1), count(decode, "const started = monotonicNs();"));
    try std.testing.expectEqual(@as(usize, 1), count(decode, "const ended = monotonicNs();"));
    // **차이를 싣는다.** `started` 를 그냥 싣거나 0 을 싣는 퇴행을 막는다.
    try std.testing.expectEqual(@as(usize, 1), count(decode, "result.remote_ns = if (ended > started) ended - started else 0;"));
    // **받은 길이 그대로.** `0` 이나 상수를 실으면 바이트 축이 통째로 죽는다.
    try std.testing.expectEqual(@as(usize, 1), count(decode, "result.remote_bytes = got.len;"));

    // 수확은 **그 두 값을 그대로** 넘긴다 — 한쪽을 0 으로 접으면 그 축만 조용히 사라진다.
    try std.testing.expectEqual(@as(usize, 1), count(activity, "RemoteFetchTotals.counts(r.remote_ns, r.remote_bytes)"));
    try std.testing.expectEqual(@as(usize, 1), count(activity, "remote_fetch.add(r.remote_ns, r.remote_bytes);"));

    // **로그가 찍는 값**도 고정한다. 포맷만 잠그면 `{d}` 자리에 상수를 넣어도 통과한다 — 그러면
    // 줄은 멀쩡히 찍히는데 숫자가 거짓이라, 이 계측을 보고 내리는 판단이 통째로 틀어진다.
    try std.testing.expectEqual(@as(usize, 1), count(activity, "r.remote_bytes,\n                r.remote_ns / std.time.ns_per_ms,"));
    try std.testing.expectEqual(@as(usize, 1), count(activity, "self.agent_activity.remote_fetch.count,"));
    try std.testing.expectEqual(@as(usize, 1), count(activity, "self.agent_activity.remote_fetch.bytes,"));
    // **`.ns` 도 같이 고정한다.** 셋 중 둘만 잠갔더니 총합 자리에 「이번 한 장」을 찍는 변이가
    // 초록으로 살아남았다(적대적 검증 R15) — 그러면 `total` 이 총합이 아니라 마지막 장이 된다.
    try std.testing.expectEqual(@as(usize, 1), count(activity, "self.agent_activity.remote_fetch.ns / std.time.ns_per_ms,"));

    // **기본값이 0 이어야 로컬이 안 세진다.** 0 이 아니게 되면 로컬 완료본도 `counts` 를 참으로
    // 만들어 총합을 오염시키는데, 순수 판정자는 `counts` 를 직접 불러서 그 자리를 안 지난다.
    try std.testing.expectEqual(@as(usize, 1), count(decode, "remote_ns: u64 = 0,"));
    try std.testing.expectEqual(@as(usize, 1), count(decode, "remote_bytes: u64 = 0,"));

    // **누적은 소스가 갈릴 때 지워진다.** 안 지우면 「앱 시작 이후 누적」이라 화면 비용을 못 읽는다.
    try std.testing.expectEqual(@as(usize, 1), count(activity, "self.remote_fetch = .{};"));

    // 셈은 순수 타입이 소유한다 — 인라인으로 되돌리면 실제 ssh 없이 못 재는 상태로 돌아간다.
    try std.testing.expectEqual(@as(usize, 1), count(activity, "pub fn counts(ns: u64, bytes: u64) bool"));
    try std.testing.expectEqual(@as(usize, 1), count(activity, "pub fn add(self: *RemoteFetchTotals, ns: u64, bytes: u64) void"));
}

fn read(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}
