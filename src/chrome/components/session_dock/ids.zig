//! Frame-local action table for Session Dock.
//!
//! Pointer hit testing returns only `UiActionId`; this table is the deliberate second half that
//! restores domain meaning without teaching the generic UI interaction layer about archive records.

const tree = @import("../../ui/tree.zig");
const types = @import("types.zig");

pub const Intent = union(enum) {
    refresh,
    scope: types.Scope,
    focus_search,
    toggle_group: u64,
    select_card: u64,
    resume_session,
    reveal_log,
    focus_live,
};

pub const Entry = struct {
    action_id: tree.UiActionId,
    snapshot_generation: u64,
    intent: Intent,
};

pub const Table = struct {
    entries: []Entry,
    count: usize = 0,

    pub fn init(entries: []Entry) Table {
        return .{ .entries = entries };
    }

    pub fn append(self: *Table, snapshot_generation: u64, intent: Intent) error{InsufficientActionBuffer}!tree.UiAction {
        if (self.count == self.entries.len) return error.InsufficientActionBuffer;
        const action_id: tree.UiActionId = @intCast(self.count + 1);
        self.entries[self.count] = .{
            .action_id = action_id,
            .snapshot_generation = snapshot_generation,
            .intent = intent,
        };
        self.count += 1;
        return .{ .id = action_id };
    }

    pub fn slice(self: *const Table) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn resolve(self: *const Table, action_id: tree.UiActionId, generation: u64) ?Intent {
        for (self.slice()) |entry| {
            if (entry.action_id == action_id and entry.snapshot_generation == generation) return entry.intent;
        }
        return null;
    }
};
