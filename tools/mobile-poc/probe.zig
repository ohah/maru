//! PoC 1단계: maru 코어가 iOS/Android 타깃으로 컴파일·링크되는가.
//!
//! 렌더러도 플랫폼도 건드리지 않고 **터미널 코어만** 세운다. 여기서 막히면
//! 나머지(GPU 표면·입력·셸)를 볼 필요가 없다.
const std = @import("std");
const terminal = @import("terminal");

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
