//! CLI response failures must reach shell exit status instead of looking successful.
//! Imports collect parser and rendering tests without requiring a live app.
test {
    _ = @import("cli/terminfo.zig");
    _ = @import("cli/runtime.zig");
    _ = @import("cli/trace.zig");
    _ = @import("cli/sessions.zig");
    _ = @import("cli/browser.zig");
}
