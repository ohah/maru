//! Process-thread guard for allocator-callback cleanup suffixes.
//!
//! Frozen cleanup descriptors are internal-public only because Zig modules need a cross-file
//! boundary. Their structs remain copyable, so an allocator callback could otherwise rebind a
//! copied descriptor to a different address and recursively free the same backing. One shared
//! guard closes every frozen cleanup kind while any sibling kind is invoking callbacks.

threadlocal var callback_cleanup_active = false;

pub fn enter() bool {
    if (callback_cleanup_active) return false;
    callback_cleanup_active = true;
    return true;
}

pub fn leave() void {
    callback_cleanup_active = false;
}

pub fn active() bool {
    return callback_cleanup_active;
}

test "frozen cleanup guard rejects same-kind and cross-kind nesting" {
    try @import("std").testing.expect(enter());
    defer leave();
    try @import("std").testing.expect(!enter());
}
