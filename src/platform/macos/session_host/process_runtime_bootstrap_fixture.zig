//! Non-test product-mode proof for the explicit ClientSlot process bootstrap.
//!
//! Unit tests compile with `builtin.is_test`; this executable deliberately does not, so a future
//! implicit test seam cannot make the missing-bootstrap rejection look green.

const std = @import("std");
const client_mod = @import("client.zig");
const client_slot_mod = @import("client_slot.zig");
const framing = @import("framing.zig");

pub fn main(init: std.process.Init) !void {
    var source = client_mod.Client{
        .allocator = init.gpa,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(init.gpa),
    };
    defer source.deinit();
    var slot: client_slot_mod.ClientSlot = undefined;
    client_slot_mod.ClientSlot.initInPlace(
        &slot,
        init.gpa,
        &source,
        source.host_id,
    ) catch |err| {
        if (err != error.ProcessDomainMismatch) return err;
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        try client_slot_mod.ClientSlot.initInPlace(
            &slot,
            init.gpa,
            &source,
            source.host_id,
        );
        defer slot.deinit();
        if (!slot.valid()) return error.BootstrappedSlotWasInvalid;
        return;
    };
    return error.MissingBootstrapWasAccepted;
}
