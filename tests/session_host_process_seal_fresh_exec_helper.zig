//! Product-mode fresh-process proof for the process seal singleton.
//!
//! The build runs this executable twice and captures the fixed-size records. Each invocation owns
//! a clean address space, exercises only the public singleton API, and proves same-process typed
//! derivation is idempotent before exposing a non-secret derived tag to the oracle.

const std = @import("std");
const process_seal_service = @import("process_seal_service");

const record_magic = "MRPSv1\x00\x00";

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.MissingExecutableArgument;
    const run_label = args.next() orelse return error.MissingRunLabel;
    if (!std.mem.eql(u8, run_label, "run-a") and !std.mem.eql(u8, run_label, "run-b"))
        return error.InvalidRunLabel;
    if (args.next() != null) return error.UnexpectedArgument;

    const pid = process_seal_service.currentProcessId();
    const nonce = try process_seal_service.generateProcessNonce();
    const receipt = try process_seal_service.prepare(pid, nonce);
    process_seal_service.commitReady(receipt);
    try process_seal_service.validateReady(pid, nonce);

    const input: process_seal_service.CapabilityKeyInput = .{
        .counter = 1,
        .slot_index = 1,
        .slot_generation = 1,
    };
    const first = try process_seal_service.capabilityRegistryKey(pid, nonce, input);
    try process_seal_service.validateReady(pid, nonce);
    const replay = try process_seal_service.capabilityRegistryKey(pid, nonce, input);
    if (first == 0 or replay != first) return error.NonIdempotentDerivation;

    var record: [16]u8 = undefined;
    @memcpy(record[0..8], record_magic);
    std.mem.writeInt(u64, record[8..16], first, .little);
    try writeAllStdout(&record);
}

fn writeAllStdout(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = std.c.write(1, bytes.ptr + offset, bytes.len - offset);
        if (written < 0) {
            if (std.posix.errno(written) == .INTR) continue;
            return error.StdoutWriteFailed;
        }
        if (written == 0) return error.StdoutWriteFailed;
        offset += @intCast(written);
    }
}
