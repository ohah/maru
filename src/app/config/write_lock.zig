//! In-process config writers serialize the whole read/patch/replace transaction.
//! Atomic replacement alone cannot prevent one writer from losing another key.
const std = @import("std");
var mutex: std.Io.Mutex = .init;
pub fn lock(io: std.Io) void {
    mutex.lockUncancelable(io);
}
pub fn unlock(io: std.Io) void {
    mutex.unlock(io);
}
