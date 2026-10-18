//! Keeps allocation-failure prefixes stable when realloc could otherwise succeed in-place.
//! `checkAllAllocationFailures` injects failures into alloc calls, so every resize must fall
//! back to alloc+copy+free for its prefix count to describe the same operation sequence.

const std = @import("std");

pub const State = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *State) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = noResize,
    .remap = noRemap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    const self: *State = @ptrCast(@alignCast(ctx));
    return self.backing.rawAlloc(len, alignment, return_address);
}

fn noResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return false;
}

fn noRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    const self: *State = @ptrCast(@alignCast(ctx));
    self.backing.rawFree(memory, alignment, return_address);
}
