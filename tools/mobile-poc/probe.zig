//! PoC 1단계: maru 코어가 iOS/Android 타깃으로 컴파일·링크되는가.
//!
//! 렌더러도 플랫폼도 건드리지 않고 **터미널 코어만** 세운다. 여기서 막히면
//! 나머지(GPU 표면·입력·셸)를 볼 필요가 없다.
const std = @import("std");
const terminal = @import("terminal");

/// **iOS 시뮬레이터에서 ReleaseSafe 를 쓰려면 이게 필요하다.** 기본 panic 핸들러는
/// 스택 트레이스를 찍으려고 `_dyld_get_image_header_containing_address` 를 부르는데
/// 그 심볼이 시뮬레이터 SDK 에 없어 링크가 깨진다(실측). `simple_panic` 은 메시지만
/// 내고 그 경로를 통째로 안 들여온다 — 안전 검사(overflow·bounds)는 그대로 산다.
pub const panic = std.debug.simple_panic;

/// 컴파일만 되고 링크에서 깨지는 경우가 있어 실제로 파싱까지 돌린다.
export fn maru_poc_smoke() u32 {
    var buf: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    var core = terminal.core.TerminalCore.init(alloc, .{ .cols = 80, .rows = 24 }) catch return 1;
    defer core.deinit();

    core.write("hello \x1b[31mworld\x1b[0m\r\n") catch return 2;
    return 0;
}
