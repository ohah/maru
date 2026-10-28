//! Editor entry point for the shared Windows directory notification owner.
const native = @import("../directory_watch.zig");
pub const Watcher = native.Watcher;
pub const Groups = native.Groups;
pub const Lease = native.Lease;
pub const GroupKey = native.GroupKey;
