pub const app = @import("app.zig");
pub const chrome = @import("chrome.zig");
pub const cli = @import("cli.zig");
pub const color = @import("color.zig");
pub const config = @import("config.zig");
pub const observability = @import("observability.zig");
pub const plugin = @import("plugin.zig");
pub const pty = @import("pty.zig");
pub const renderer = @import("renderer.zig");
pub const session = @import("session.zig");
pub const terminal = @import("terminal.zig");
pub const terminfo_cache = @import("terminfo_cache.zig"); // maru 자체 terminfo 로컬 캐시 단일 출처(pty 자동 컴파일 + cli 서브커맨드 공용)
pub const width = @import("width.zig"); // Unicode 셀 폭(EAW) — 레이어 무관 중립 유틸(terminal·chrome·platform 공용)

test {
    @import("std").testing.refAllDecls(@This());
}
