//! **한 턴 전체를 지휘하는 자리는 «지휘만» 한다** — 소스의 마커로 잘라낸 그 구간에
//! 필요한 호출 셋이 각각 한 번씩 있고, 금지한 것(`std.time`·할당·`recv`/`send`·lease
//! 획득/해제)은 **하나도 없다**. 구간이 넓어지면 그 순간 실패한다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3d**.

const std = @import("std");

pub fn main() !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/session_host/client_external_pump.zig",
        std.heap.page_allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.heap.page_allocator.free(source);

    const begin = std.mem.indexOf(
        u8,
        source,
        "// MARU_F3D_PRODUCT_ORCHESTRATION_BEGIN",
    ) orelse return error.F3dProductBoundaryMissing;
    const end = std.mem.indexOfPos(
        u8,
        source,
        begin,
        "// MARU_F3D_PRODUCT_ORCHESTRATION_END",
    ) orelse return error.F3dProductBoundaryMissing;
    const body = source[begin..end];
    for ([_][]const u8{
        "orchestrateCompletedControlUnderHeldLease(",
        "scratch.drain_evidence.mode == .completed_control",
        "terminalInjectedRxTurn(",
    }) |required| if (count(body, required) != 1)
        return error.F3dProductBoundaryDrift;

    for ([_][]const u8{
        "std.time",
        ".alloc(",
        "c.recv",
        "c.send",
        "acquireWholeTurnLease(",
        "releaseWholeTurnLease(",
    }) |forbidden| if (std.mem.indexOf(u8, body, forbidden) != null)
        return error.F3dProductBoundaryExpanded;

    for ([_][]const u8{
        "f3d product pump consumes resize response in the source turn",
        "f3d product pump consumes malformed response into terminal cleanup",
        "f3d product pump consumes resync ACK into awaiting snapshot",
        "f3d response payload cleanup callback owner drift terminalizes and quarantines",
    }) |test_name| if (count(source, test_name) != 1)
        return error.F3dBehaviorGateMissing;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |found| {
        total += 1;
        cursor = found + needle.len;
    }
    return total;
}
