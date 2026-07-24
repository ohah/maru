//! Host discovery와 MRSH hello가 공유하는 작은 identity 계약.
//!
//! 이 파일은 OS syscall을 import하지 않는다. Manifest와 server가 lifecycle 문자열을 각자 소유하면 upgrade 중 disk
//! routing authority와 wire identity가 갈라질 수 있으므로 stable enum을 한 곳에서 공유한다.

pub const Lifecycle = enum {
    ready,
    restoring,
    draining,
};

test "host lifecycle names are stable wire values" {
    const std = @import("std");
    try std.testing.expectEqualStrings("ready", @tagName(Lifecycle.ready));
    try std.testing.expectEqualStrings("restoring", @tagName(Lifecycle.restoring));
    try std.testing.expectEqualStrings("draining", @tagName(Lifecycle.draining));
}
