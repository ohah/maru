//! 원격 SCM **캡처 하니스**가 control socket 을 놓을 자리를 계산한다.
//!
//! 앱은 그 경로를 `maru.cli.ssh.controlSocketPath` 로 **스스로 만든다** — 하니스가 env 로 알려 줄 길이
//! 없다. 그래서 캡처 스크립트가 그 규칙을 한 번 더 적어야 하고, 이 파일이 그 자리다.
//!
//! ⚠️ **이것은 규칙의 사본이다.** 사본은 낡는다 — 그래서 제품 쪽에 그 모양을 못박는 판정자를 두고
//! (`src/cli/ssh.zig` 의 「모양은 `<home>/.cache/maru/ctl-<wyhash hex>` 다」), 그 판정자가 이 파일을
//! 이름으로 가리킨다. 규칙이 바뀌면 그 판정자가 먼저 죽고, 고칠 자리가 어디인지 함께 말한다.
//!
//! **제품 함수를 직접 부르지 않는 이유**: `src/cli/ssh.zig` 는 `@embedFile("maru_terminfo")` 를 지고 있어
//! 모듈 그래프 없이는 컴파일되지 않는다. 캡처 스크립트 하나 때문에 빌드 스텝을 만드는 것보다, 두 줄을
//! 옮겨 적고 **판정자로 묶는** 편이 싸다.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next(); // argv[0]
    const home = args.next() orelse return error.Usage;
    const dest = args.next() orelse return error.Usage;
    const base = std.mem.trimEnd(u8, home, "/");
    const hash = std.hash.Wyhash.hash(0, dest);
    std.debug.print("{s}/.cache/maru/ctl-{x}\n", .{ base, hash });
}
