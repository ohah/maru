//! Focused test root for the typed Chrome UI namespace.
//!
//! The production `chrome.zig` facade deliberately imports every Chrome component. Keeping this
//! build entrypoint separate makes `zig build test-chrome-ui` prove only the build → layout →
//! interaction → paint seam while resolving child-module imports from the real `src/` boundary.

const layout = @import("chrome/ui/layout.zig");
const style = @import("chrome/ui/style.zig");
const tree = @import("chrome/ui/tree.zig");
const ui_button = @import("chrome/ui/button.zig");
const interaction = @import("chrome/ui/interaction.zig");
const intent_table = @import("chrome/ui/intent_table.zig");
const continuous_drag = @import("chrome/ui/continuous_drag.zig");
const paint_style = @import("chrome/ui/paint_style.zig");
const paint = @import("chrome/ui/paint.zig");
const divider = @import("chrome/components/divider.zig");
const file_tree_scrollbar = @import("chrome/components/file_tree_scrollbar.zig");
const session_dock = @import("chrome/components/session_dock.zig");
const archive_detail = @import("chrome/components/archive_detail.zig");

test {
    // `refAllDecls` is intentionally explicit: imports alone do not make this focused artifact's
    // scope obvious to a reader, and each namespace owns the tests for its one responsibility.
    const testing = @import("std").testing;
    testing.refAllDecls(layout);
    testing.refAllDecls(ui_button);
    testing.refAllDecls(style);
    testing.refAllDecls(tree);
    testing.refAllDecls(interaction);
    testing.refAllDecls(intent_table);
    testing.refAllDecls(continuous_drag);
    testing.refAllDecls(divider);
    testing.refAllDecls(file_tree_scrollbar);
    testing.refAllDecls(paint_style);
    testing.refAllDecls(paint);
    testing.refAllDecls(session_dock);
    testing.refAllDecls(archive_detail);
}
