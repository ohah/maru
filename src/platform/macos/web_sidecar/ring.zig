//! 픽셀 링의 macOS 쪽 입구(W2) — 판정자가 지금 maru 역할로, W3 에서 maru 가 쓴다. CEF 를 모른다.

pub const mach = @import("mach.zig");
pub const iosurface = @import("iosurface.zig");
pub const ring_message = @import("ring_message.zig");
pub const ring_receiver = @import("ring_receiver.zig");
/// 판정자가 제3자 역할로 가짜 링을 보낼 때 쓴다.
pub const ring_producer = @import("ring_producer.zig");
