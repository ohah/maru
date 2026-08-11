//! Canonical pointer-free semantic/content projection for one RuntimeObservation.
//!
//! Descriptor construction belongs to the current physical owner. This leaf only couples an
//! already-canonical graph with every scalar and active backing byte so preparation, pending owner,
//! and later settlement cannot drift into separate hashing rules.

const maru = @import("maru");
const std = @import("std");
const cleanup = @import("event_cleanup_seal.zig");

const RuntimeObservation = maru.app.RuntimeObservation;
const zero_digest = [_]u8{0} ** 32;

pub const Error = error{InvalidObservation};

fn descriptor(list: anytype, allocator: std.mem.Allocator) Error!cleanup.CleanupDescriptor {
    const T = std.meta.Child(@TypeOf(list.items));
    if (list.items.len == 0) {
        if (list.capacity != 0) return error.InvalidObservation;
        return .{};
    }
    if (list.items.len != list.capacity) return error.InvalidObservation;
    const length = std.math.mul(u64, list.items.len, @sizeOf(T)) catch return error.InvalidObservation;
    return .{
        .present = 1,
        .address = @intFromPtr(list.items.ptr),
        .length_bytes = length,
        .capacity_bytes = length,
        .alignment_log2 = std.math.log2_int(usize, @alignOf(T)),
        .allocator_ptr = @intFromPtr(allocator.ptr),
        .allocator_vtable = @intFromPtr(allocator.vtable),
    };
}

pub fn cleanupGraph(
    observation: *const RuntimeObservation,
    allocator: std.mem.Allocator,
) Error!cleanup.ObservationCleanupGraph {
    return .{
        .cwd = try descriptor(observation.cwd, allocator),
        .cwd_host = try descriptor(observation.cwd_host, allocator),
        .window_title = try descriptor(observation.window_title, allocator),
        .ssh_remote_dest = try descriptor(observation.ssh_remote_dest, allocator),
        .clipboard_read_target = try descriptor(observation.clipboard_read_target, allocator),
        .foreground_processes = try descriptor(observation.foreground_processes, allocator),
        .agent_progress = try descriptor(observation.agent_progress, allocator),
    };
}

fn stringDigestOrZero(role: cleanup.ObservationStringRole, bytes: []const u8) cleanup.Digest {
    return if (bytes.len == 0) zero_digest else cleanup.observationStringDigest(role, bytes);
}

pub fn input(
    observation: *const RuntimeObservation,
    graph: cleanup.ObservationCleanupGraph,
) Error!cleanup.ObservationCleanupDigestInput {
    if (observation.foreground_processes.items.len > 64) return error.InvalidObservation;
    var processes: cleanup.ForegroundProcessesDigestInput = .{};
    processes.count = @intCast(observation.foreground_processes.items.len);
    for (observation.foreground_processes.items, 0..) |process, index| {
        if (process.len > process.bytes.len) return error.InvalidObservation;
        processes.entries[index].pid = process.pid;
        processes.entries[index].len = process.len;
        @memcpy(processes.entries[index].bytes[0..process.len], process.bytes[0..process.len]);
    }
    return .{
        .availability = @intFromEnum(observation.availability),
        .revision = observation.revision,
        .observer_generation = observation.observer_generation,
        .title_generation = observation.title_generation,
        .cols = observation.size.cols,
        .rows = observation.size.rows,
        .ssh_remote_dest_present = @intFromBool(observation.ssh_remote_dest_present),
        .semantic_state = @intFromEnum(observation.semantic_state),
        .alt_active = @intFromBool(observation.alt_active),
        .app_cursor_keys = @intFromBool(observation.app_cursor_keys),
        .app_keypad = @intFromBool(observation.app_keypad),
        .kitty_flags = observation.kitty_flags,
        .alternate_scroll = @intFromBool(observation.alternate_scroll),
        .mouse_tracking = @intFromBool(observation.mouse_tracking),
        .mouse_tracking_mode = observation.mouse_tracking_mode,
        .bracketed_paste = @intFromBool(observation.bracketed_paste),
        .bell_count = observation.bell_count,
        .clipboard_write_seq = observation.clipboard_write_seq,
        .clipboard_read_seq = observation.clipboard_read_seq,
        .foreground_available = @intFromBool(observation.foreground_available),
        .foreground_pgid_present = @intFromBool(observation.foreground_pgid != null),
        .foreground_pgid = observation.foreground_pgid orelse 0,
        .foreground_process_count = processes.count,
        .graph = graph,
        .cwd_digest = stringDigestOrZero(.cwd, observation.cwd.items),
        .cwd_host_digest = stringDigestOrZero(.cwd_host, observation.cwd_host.items),
        .window_title_digest = stringDigestOrZero(.window_title, observation.window_title.items),
        .ssh_remote_dest_digest = stringDigestOrZero(.ssh_remote_dest, observation.ssh_remote_dest.items),
        .clipboard_read_target_digest = stringDigestOrZero(.clipboard_read_target, observation.clipboard_read_target.items),
        .foreground_processes_digest = if (processes.count == 0) zero_digest else cleanup.foregroundProcessesDigest(processes),
        .agent_progress_digest = stringDigestOrZero(.agent_progress, observation.agent_progress.items),
    };
}

pub fn digest(
    observation: *const RuntimeObservation,
    graph: cleanup.ObservationCleanupGraph,
) Error!cleanup.Digest {
    return cleanup.observationCleanupDigest(try input(observation, graph));
}

pub const SemanticPostInput = struct {
    observation_digest: cleanup.Digest,
    resync_needed: bool,
    resize_generation: u64,
    resize_baseline_present: bool,
    attachment_role_raw: u8,
    controller_generation: u64,
    metadata_published: bool,
    ended_published: bool,
};

/// 의미 commit 직후 Runtime이 실제 소유한 POST만 canonical transcript로 만든다.
pub fn semanticPostDigest(value: SemanticPostInput) cleanup.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.runtime-semantic-post.v1");
    hasher.update(&value.observation_digest);
    hashInt(&hasher, u8, @intFromBool(value.resync_needed));
    hashInt(&hasher, u64, value.resize_generation);
    hashInt(&hasher, u8, @intFromBool(value.resize_baseline_present));
    hashInt(&hasher, u8, value.attachment_role_raw);
    hashInt(&hasher, u64, value.controller_generation);
    hashInt(&hasher, u8, @intFromBool(value.metadata_published));
    hashInt(&hasher, u8, @intFromBool(value.ended_published));
    var out: cleanup.Digest = undefined;
    hasher.final(&out);
    return out;
}

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}
