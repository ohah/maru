//! OS-independent restart reducer for durable aggregate cleanup.

const std = @import("std");

pub const entry_count: usize = 5;
pub const Outcome = enum { success, audit_required, cleanup_required, descriptor_close_failed };
pub const Location = enum { original, tomb, removed, ambiguous };
pub const CompletionState = enum { absent, durable_with_intent, durable };
pub const Inventory = struct {
    present: [entry_count]bool,
    foreign: ?usize = null,
    unexpected: bool = false,
};

const State = enum { pristine, running };

pub const Recovery = struct {
    owner: ?*Recovery = null,
    state: State = .pristine,
    seal: [32]u8 = @splat(0),

    pub fn isPristine(self: *const @This()) bool {
        return self.owner == null and self.state == .pristine and std.mem.allEqual(u8, &self.seal, 0);
    }

    fn start(self: *@This()) !void {
        if (!self.isPristine()) return error.InvalidOwner;
        self.owner = self;
        self.state = .running;
        self.seal = ownerSeal(self);
    }

    fn valid(self: *const @This()) bool {
        return self.owner == self and self.state == .running and
            std.crypto.timing_safe.eql([32]u8, self.seal, ownerSeal(self));
    }

    fn finish(self: *@This()) void {
        self.* = .{};
    }
};

pub fn begin(driver: anytype, result: *Recovery) !Outcome {
    try result.start();
    defer result.finish();
    const outcome: Outcome = blk: {
        driver.validate() catch break :blk .audit_required;
        switch (driver.inspectCompletion() catch break :blk .audit_required) {
            .absent => {},
            .durable_with_intent => break :blk finishDurableCompletion(driver, true),
            .durable => break :blk finishDurableCompletion(driver, false),
        }
        driver.publishIntent() catch |err| break :blk if (err == error.CleanupFailed) .cleanup_required else .audit_required;
        driver.syncParentAfterIntent() catch break :blk .cleanup_required;
        break :blk try continueCleanup(driver, result);
    };
    return closeAs(driver, outcome);
}

pub fn recover(driver: anytype, result: *Recovery) !Outcome {
    try result.start();
    defer result.finish();
    const outcome: Outcome = blk: {
        switch (driver.inspectCompletion() catch break :blk .audit_required) {
            .absent => {},
            .durable_with_intent => break :blk finishDurableCompletion(driver, true),
            .durable => break :blk finishDurableCompletion(driver, false),
        }
        break :blk try continueCleanup(driver, result);
    };
    return closeAs(driver, outcome);
}

fn continueCleanup(driver: anytype, result: *Recovery) !Outcome {
    if (!result.valid()) return error.InvalidOwner;
    const location = driver.locate() catch return .audit_required;
    switch (location) {
        .ambiguous => return .audit_required,
        .original => {
            driver.rename() catch return .cleanup_required;
            driver.syncParentAfterRename() catch return .cleanup_required;
        },
        .tomb => {},
        .removed => return finishRemoved(driver),
    }

    while (true) {
        if (!result.valid()) return error.InvalidOwner;
        const inventory = driver.inspectInventory() catch return .audit_required;
        const next = validateInventory(inventory) catch return .audit_required;
        if (next == null) break;
        driver.unlink(next.?) catch return .cleanup_required;
        driver.syncTomb() catch return .cleanup_required;
    }
    driver.removeTomb() catch return .cleanup_required;
    driver.syncParentAfterTomb() catch return .cleanup_required;
    return finishRemoved(driver);
}

fn finishRemoved(driver: anytype) Outcome {
    driver.publishCompletion() catch return .cleanup_required;
    driver.syncParentAfterCompletion() catch return .cleanup_required;
    driver.removeIntent() catch return .cleanup_required;
    driver.syncParentFinal() catch return .cleanup_required;
    return .success;
}

fn finishDurableCompletion(driver: anytype, remove_intent: bool) Outcome {
    if (remove_intent) driver.removeIntent() catch return .cleanup_required;
    driver.syncParentFinal() catch return .cleanup_required;
    return .success;
}

fn closeAs(driver: anytype, outcome: Outcome) Outcome {
    driver.close() catch return .descriptor_close_failed;
    return outcome;
}

fn validateInventory(inventory: Inventory) !?usize {
    if (inventory.foreign != null or inventory.unexpected) return error.InvalidInventory;
    var saw_absent = false;
    var next: ?usize = null;
    for (inventory.present, 0..) |present, index| {
        if (!present) {
            saw_absent = true;
        } else {
            if (saw_absent) return error.InvalidInventory;
            next = index;
        }
    }
    return next;
}

fn ownerSeal(result: *const Recovery) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.aggregate-cleanup-recovery.owner.v1\x00");
    const address = @intFromPtr(result);
    hasher.update(std.mem.asBytes(&address));
    hasher.update(std.mem.asBytes(&result.state));
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}
