//! Live diagnostic panel facade; pixel tree layout is shared by paint and input.
const panel = @import("inspector/panel.zig");
pub const Tab = panel.Tab;
pub const Hit = panel.Hit;
pub const collect = panel.collect;
pub const hit = panel.hit;
pub const cursor = panel.cursor;
pub const cursorForTab = panel.cursorForTab;
pub const caretRect = panel.caretRect;
pub const caretRectForTab = panel.caretRectForTab;
pub const controlRect = panel.controlRect;
pub const fieldAt = panel.fieldAt;
pub const dataControlRect = panel.dataControlRect;

// The facade must expose the panel's geometry regression to the maru test root.
test {
    @import("std").testing.refAllDecls(panel);
}
