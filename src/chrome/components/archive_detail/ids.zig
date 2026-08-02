//! Opaque action identities for ArchiveSessionDetailPanel.

const tree = @import("../../ui/tree.zig");

pub const Intent = enum { resume_session, reveal_log, focus_live };

pub const Entry = struct {
    action_id: tree.UiActionId,
    snapshot_generation: u64,
    intent: Intent,
    /// This is duplicated from the published tree intentionally: keyboard dispatch in the host
    /// resolves the same identity without inventing a second state gate. A stale action must not
    /// become executable merely because it was addressed by a shortcut rather than a pointer.
    enabled: bool,
};

pub const Table = struct {
    entries: []Entry,
    count: usize = 0,

    pub fn init(entries: []Entry) Table {
        return .{ .entries = entries };
    }

    pub fn append(self: *Table, snapshot_generation: u64, intent: Intent, enabled: bool) error{InsufficientActionBuffer}!tree.UiAction {
        if (self.count == self.entries.len) return error.InsufficientActionBuffer;
        const action_id: tree.UiActionId = @intCast(self.count + 1);
        self.entries[self.count] = .{ .action_id = action_id, .snapshot_generation = snapshot_generation, .intent = intent, .enabled = enabled };
        self.count += 1;
        return .{ .id = action_id };
    }

    pub fn slice(self: *const Table) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn resolve(self: *const Table, action_id: tree.UiActionId, generation: u64) ?Intent {
        for (self.slice()) |entry| {
            if (entry.action_id == action_id and entry.snapshot_generation == generation and entry.enabled) return entry.intent;
        }
        return null;
    }
};
