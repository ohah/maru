//! SSH 층 전체를 한 번에 컴파일·테스트하는 진입점.
//!
//! **세 최적화 모드로 다 돌리려고 있다**(`zig build check-ssh-modes`). `std` 의 몇몇 검사가
//! `if (std.debug.runtime_safety)` 뒤에 있어 **배포가 쓰는 ReleaseFast 에서 사라지는데**,
//! `zig build test` 는 Debug 라 CI 가 영영 못 본다 — 실제로 개인키 공개키 대조가 그렇게 빠져
//! 있었다(계약 §4.4.4).

const std = @import("std");

pub const packet = @import("packet.zig");
pub const wire = @import("wire.zig");
pub const version = @import("version.zig");
pub const kexinit = @import("kexinit.zig");
pub const kex = @import("kex.zig");
pub const cipher = @import("cipher.zig");
pub const transport = @import("transport.zig");
pub const hostkey = @import("hostkey.zig");
pub const known_hosts = @import("known_hosts.zig");
pub const userauth = @import("userauth.zig");
pub const private_key = @import("private_key.zig");

test {
    std.testing.refAllDecls(@This());
}
