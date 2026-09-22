//! **적대적 응답·revoke 전송 증거가 조용히 사라지지 않는다** — 순수 행렬 하나와 제품 쪽
//! 다섯(revoke 경계를 넘는 TX 억제·socketpair 순서·불완전 프레임 거절·할당 실패 복원·
//! 유계 스트레스)이 이름으로 실재하는지 센다.
//!
//! 터미널에는 이렇게 보인다: 순서 테스트가 하나 사라지면 **revoke 뒤 쓰기가 다시 열리거나**
//! RX/TX 소유가 새는데, 평범한 단위 스위트는 여전히 초록을 보고한다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3e**.
//!
//! The filtered Zig runner succeeds when a filter matches zero tests, so this executable keeps
//! the hostile response/revoke transport evidence from disappearing silently. That matters to a
//! terminal because a missing ordering test can re-open post-revoke writes or leak RX/TX owners
//! while the ordinary unit suite still reports green.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const planner = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/client_pump.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(planner);
    const product = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/client_external_pump.zig",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(product);

    const pure_name =
        "hostile revoke pure hostile matrix seals response revoke HUP control progress and deadline precedence";
    if (count(planner, pure_name) != 1) return error.F3ePureGateMissing;

    for ([_][]const u8{
        "hostile revoke injected turn suppresses TX across revoke boundaries and transport retries",
        "hostile revoke socketpair orders response revoke and FIN without writable TX",
        "hostile revoke socketpair rejects incomplete frames and bounds one byte drip",
        "hostile revoke allocation fail index restores the common owner graph",
        "hostile revoke bounded stress preserves common final zero",
    }) |test_name| {
        if (count(product, test_name) != 1) return error.F3eProductGateMissing;
    }
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
