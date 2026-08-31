//! **비동기 wake 지연 예산이 세 자리에서 같은 값인가.**
//!
//! 무엇을 증명하는가: `session_host_recovery_smoke_async_wake_apply_latency_ns` 의 상한이
//! ⑴ 소유자(`cr6c_appkit_smoke.zig` 의 `wake_apply_latency_budget_ns`) ⑵ baseline validator
//! ⑶ `build.zig` 의 awk 검증 셋에서 **같은 숫자**인지 센다.
//!
//! **왜 필요한가**: 이 값은 원래 세 곳에 `60ms` 로 각자 적혀 있었고, 셋이 갈리면 *"어느 게이트는
//! 통과하고 어느 게이트는 죽는"* 상태가 된다. validator 는 독립 실행 파일이라 소유자를 import 하지
//! 못해 값을 옮겨 적을 수밖에 없고, `build.zig` 의 awk 는 셸 문자열이라 상수를 참조할 길이 없다 —
//! 그래서 **컴파일러가 못 잡는다.** 이 판정자가 그 자리를 대신한다.
//!
//! **문자열로 구조를 찾지 않는다**(프로젝트 규율). 세 자리 다 "이 이름 뒤의 숫자" 라는 구조가 있어
//! 그 숫자만 뽑아 비교하며, **못 찾으면 통과하지 않고 실패한다** — 스캐너가 빗나갔는데 초록이면
//! 판정이 사라진 것을 아무도 모른다.

const std = @import("std");

/// 경계 판정자들이 쓰는 그 읽기다(`imports.zig` 와 같은 형태) — 못 읽으면 조용히 넘어가지 않고
/// 무엇을 못 읽었는지 찍고 실패한다.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("wake 예산 스캔이 {s} 를 못 읽었다: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// `needle` 뒤에 오는 첫 십진수를 읽는다. 못 찾으면 `null` — 호출자가 실패로 다룬다.
fn numberAfter(haystack: []const u8, needle: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, haystack, needle) orelse return null;
    var i = at + needle.len;
    while (i < haystack.len and !std.ascii.isDigit(haystack[i])) : (i += 1) {
        // 숫자에 닿기 전에 줄이 끝나면 그 자리가 아니다.
        if (haystack[i] == '\n') return null;
    }
    const start = i;
    while (i < haystack.len and std.ascii.isDigit(haystack[i])) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, haystack[start..i], 10) catch null;
}

test "wake 지연 예산은 세 자리에서 같은 값이다" {
    const allocator = std.testing.allocator;

    const owner_src = try readFile(allocator, "src/platform/macos/session_host/cr6c_appkit_smoke.zig");
    defer allocator.free(owner_src);
    const validator_src = try readFile(allocator, "tools/perf/session_host_cr6e_recovery_validator.zig");
    defer allocator.free(validator_src);
    const build_src = try readFile(allocator, "build.zig");
    defer allocator.free(build_src);

    // ⑴·⑵ 는 `<이름>: u64 = <숫자> * std.time.ns_per_ms` 꼴이라 ms 단위로 읽힌다.
    const owner_ms = numberAfter(owner_src, "pub const wake_apply_latency_budget_ns: u64 =") orelse
        return error.OwnerBudgetNotFound;
    const validator_ms = numberAfter(validator_src, "const wake_apply_latency_budget_ns: u64 =") orelse
        return error.ValidatorBudgetNotFound;
    // ⑶ 은 awk 안의 ns 리터럴이다.
    const build_ns = numberAfter(build_src, "session_host_recovery_smoke_async_wake_apply_latency_ns\\\" && $2 + 0 > 0 && $2 + 0 <=") orelse
        return error.BuildBudgetNotFound;

    try std.testing.expectEqual(owner_ms, validator_ms);
    try std.testing.expectEqual(owner_ms * std.time.ns_per_ms, build_ns);

    // **0 을 세고도 초록이 되지 않게** — 위 스캔이 전부 빗나가면 셋 다 0 이 되어 서로 같아진다.
    try std.testing.expect(owner_ms > 0);
}
