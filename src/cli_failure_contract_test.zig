//! CLI response failures must reach shell exit status instead of looking successful.
//! Imports collect parser and rendering tests without requiring a live app.
test {
    _ = @import("cli/incidents.zig");
    _ = @import("cli/agent_events.zig");
    _ = @import("cli/agent_hooks.zig");
    _ = @import("cli/lsp_trust.zig");
    _ = @import("cli/terminfo.zig");
    _ = @import("cli/runtime.zig");
    _ = @import("cli/trace.zig");
    _ = @import("cli/sessions.zig");
    _ = @import("cli/browser.zig");
    _ = @import("cli/mcp.zig"); // W9f
    // 러너의 시험(원자 공개·JSON 검사·줄 읽기)도 여기서 돈다 — 전에는 check-targets 가 컴파일만 해 한 번도 돌지 않았다(W9f 변이로 찾음).
    _ = @import("cli/browser/run.zig");
}
