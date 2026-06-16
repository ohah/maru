pub const core = @import("terminal/core.zig");
pub const input = @import("terminal/input.zig");
pub const types = @import("terminal/types.zig");
// Unicode 셀 폭(EAW)은 순수·레이어 무관이라 top-level 중립 유틸(src/width.zig)로 옮겼다 — terminal·platform·
// chrome이 모두 쓴다(색=color.zig와 같은 선례). 여기선 호환 re-export만 한다(terminal.width/cellWidth 그대로).
pub const width = @import("width.zig");

pub const Cell = types.Cell;
pub const Color = types.Color;
pub const Cursor = types.Cursor;
pub const CursorShape = types.CursorShape;
pub const SelectionPoint = types.SelectionPoint;
pub const SelectionSpan = types.SelectionSpan;
pub const Match = types.Match;
pub const DirtyRegion = types.DirtyRegion;
pub const Key = input.Key;
pub const KeyEvent = input.KeyEvent;
pub const ModifierSet = input.ModifierSet;
pub const RenderSnapshot = types.RenderSnapshot;
pub const KittyPlacement = types.KittyPlacement;
pub const KittyImageView = types.KittyImageView;
pub const RowCodepoints = types.RowCodepoints;
pub const SemanticPrompt = types.SemanticPrompt;
pub const RowPrompt = types.RowPrompt;
pub const Rgb = types.Rgb;
pub const Size = types.Size;
pub const Style = types.Style;
pub const TerminalCore = core.TerminalCore;
pub const clampGridSize = core.clampGridSize;
pub const cellWidth = width.cellWidth;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in terminal/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
