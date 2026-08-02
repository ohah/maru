//! Platform-neutral, redacted input DTO for an archive session detail panel.

const layout = @import("../../ui/layout.zig");

pub const State = enum { loading, ready, stale, unavailable };
pub const Provider = enum { codex, claude };
pub const Role = enum { user, assistant };

pub const Turn = struct {
    role: Role,
    /// The host has applied the repository redaction policy before constructing this DTO.
    text: []const u8,
};

pub const Props = struct {
    viewport_px: layout.UiSize,
    cell_width_px: u32,
    cell_height_px: u32,
    snapshot_generation: u64,
    state: State,
    provider: Provider,
    title: []const u8,
    metadata: []const u8,
    turns: []const Turn = &.{},
    action_record_count: u32 = 0,
    spinner_phase: u3 = 0,
    /// These booleans describe host-authorized capabilities, not UI preference. A non-ready
    /// state must still disable every source-affecting action even if a stale DTO says true.
    resume_enabled: bool = false,
    reveal_enabled: bool = false,
    focus_live_enabled: bool = false,
};

pub const Metrics = struct {
    header_h: u32,
    metadata_h: u32,
    section_h: u32,
    turn_h: u32,
    actions_h: u32,
    gap: u32,
    pad: u32,

    pub fn fromCellHeight(cell_height_px: u32) Metrics {
        const ch = @max(cell_height_px, 1);
        return .{
            .header_h = ch * 3,
            // Text baselines are one cell below a card's top edge. Two metadata lines therefore
            // need three cells: 1ch for the first baseline, 1ch between baselines, and a final
            // descender/clip cell. Keeping this in the shared metric prevents a painted count
            // from existing semantically but being clipped by the same rect tree.
            .metadata_h = ch * 3,
            .section_h = ch * 2,
            .turn_h = ch * 4,
            .actions_h = ch * 2,
            .gap = @max(ch / 2, 4),
            .pad = @max(ch, 8),
        };
    }
};

pub fn isActionable(props: Props) bool {
    return props.state == .ready;
}
