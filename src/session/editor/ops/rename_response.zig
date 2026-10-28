//! A request number belongs to one server connection and one document lifetime.
//! Hosts capture identity; this leaf decides whether an incoming response can settle the wait.
const std = @import("std");

pub const Owner = struct { surface: u64, document: usize, target_epoch: u64 };
pub const Decision = enum { ignore, cancel, accept };

pub fn decide(waiting: bool, expected_seq: u32, seq: u32, expected: ?Owner, current: ?Owner, same_client: bool) Decision {
    if (!waiting or seq != expected_seq) return .ignore;
    const owner = expected orelse return .cancel;
    const live = current orelse return .cancel;
    if (!std.meta.eql(owner, live)) return .cancel;
    if (!same_client) return .ignore;
    return .accept;
}

test "rename response owner isolates server sequence collisions and document lifetimes" {
    const t = std.testing;
    const owner: Owner = .{ .surface = 2, .document = 100, .target_epoch = 7 };
    try t.expectEqual(Decision.accept, decide(true, 1, 1, owner, owner, true));
    try t.expectEqual(Decision.ignore, decide(false, 1, 1, owner, owner, true));
    try t.expectEqual(Decision.ignore, decide(true, 1, 2, owner, owner, true));
    try t.expectEqual(Decision.ignore, decide(true, 1, 1, owner, owner, false));
    try t.expectEqual(Decision.cancel, decide(true, 1, 1, null, owner, true));
    try t.expectEqual(Decision.cancel, decide(true, 1, 1, owner, null, true));
    inline for (.{ Owner{ .surface = 3, .document = 100, .target_epoch = 7 }, Owner{ .surface = 2, .document = 101, .target_epoch = 7 }, Owner{ .surface = 2, .document = 100, .target_epoch = 8 } }) |other| {
        try t.expectEqual(Decision.cancel, decide(true, 1, 1, owner, other, true));
    }
}
