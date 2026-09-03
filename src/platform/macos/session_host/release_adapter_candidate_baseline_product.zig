//! Final-address ownership around one baseline-A product transaction.
//!
//! Concrete candidate and child adapters bind through this owner. The wrapper records every child
//! attempt before delegation, so the phase can leave an exact retry set when cleanup fails.

const std = @import("std");
const phase = @import("release_adapter_candidate_baseline_phase");

pub const max_path_bytes: usize = std.fs.max_path_bytes;

pub const Paths = struct {
    app_bundle: [:0]const u8,
    app_executable: [:0]const u8,
    cli_executable: [:0]const u8,
    default_false_root: [:0]const u8,
    signed_app_quit_root: [:0]const u8,
};

pub const PathStorage = struct {
    app_bundle: [max_path_bytes:0]u8 = @splat(0),
    app_executable: [max_path_bytes:0]u8 = @splat(0),
    cli_executable: [max_path_bytes:0]u8 = @splat(0),
    default_false_root: [max_path_bytes:0]u8 = @splat(0),
    signed_app_quit_root: [max_path_bytes:0]u8 = @splat(0),
};

pub const Execution = struct {
    owner: ?*Execution = null,
    candidate_bound: bool = false,
    default_false_attempted: bool = false,
    signed_app_quit_attempted: bool = false,
    evidence_attempted: bool = false,
    successful: bool = false,

    pub fn ownsSuccessfulChildren(self: *const @This()) bool {
        return self.owner == self and self.candidate_bound and self.default_false_attempted and
            self.signed_app_quit_attempted and self.evidence_attempted and self.successful;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and
            (self.default_false_attempted or self.signed_app_quit_attempted or self.evidence_attempted);
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.candidate_bound and !self.default_false_attempted and
            !self.signed_app_quit_attempted and !self.evidence_attempted and !self.successful;
    }
};

pub fn executeWith(steps: anytype, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    execution.owner = execution;
    steps.bindCandidate() catch |err| {
        execution.* = .{};
        return err;
    };
    execution.candidate_bound = true;

    var adapter = Adapter(@TypeOf(steps)){ .steps = steps, .execution = execution };
    phase.runWith(&adapter) catch |err| {
        if (err == error.CleanupFailed or execution.needsCleanup()) return error.CleanupFailed;
        execution.* = .{};
        return err;
    };
    execution.successful = true;
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!execution.needsCleanup()) return error.InvalidOwner;
    var clean = true;
    if (execution.evidence_attempted) {
        var released = true;
        steps.cleanupEvidence() catch {
            clean = false;
            released = false;
        };
        if (released) execution.evidence_attempted = false;
    }
    if (execution.signed_app_quit_attempted) {
        var released = true;
        steps.cleanupSignedAppQuit() catch {
            clean = false;
            released = false;
        };
        if (released) execution.signed_app_quit_attempted = false;
    }
    if (execution.default_false_attempted) {
        var released = true;
        steps.cleanupDefaultFalse() catch {
            clean = false;
            released = false;
        };
        if (released) execution.default_false_attempted = false;
    }
    if (!clean or execution.default_false_attempted or execution.signed_app_quit_attempted or execution.evidence_attempted)
        return error.CleanupFailed;
    execution.* = .{};
}

fn Adapter(comptime Steps: type) type {
    return struct {
        const StepType = switch (@typeInfo(Steps)) {
            .pointer => |pointer| pointer.child,
            else => Steps,
        };
        const StartReturn = @typeInfo(@TypeOf(StepType.startDeadline)).@"fn".return_type.?;
        const Deadline = @typeInfo(StartReturn).error_union.payload;

        steps: Steps,
        execution: *Execution,

        pub fn startDeadline(self: *@This()) !Deadline {
            return try self.steps.startDeadline();
        }
        pub fn validateInitialCandidate(self: *@This(), deadline: anytype) !void {
            try self.steps.validateInitialCandidate(deadline);
        }
        pub fn runDefaultFalse(self: *@This(), deadline: anytype) !void {
            self.execution.default_false_attempted = true;
            try self.steps.runDefaultFalse(deadline);
        }
        pub fn validateCandidateAfterDefault(self: *@This(), deadline: anytype) !void {
            try self.steps.validateCandidateAfterDefault(deadline);
        }
        pub fn runSignedAppQuit(self: *@This(), deadline: anytype) !void {
            self.execution.signed_app_quit_attempted = true;
            try self.steps.runSignedAppQuit(deadline);
        }
        pub fn validateCandidateAfterQuit(self: *@This(), deadline: anytype) !void {
            try self.steps.validateCandidateAfterQuit(deadline);
        }
        pub fn publishEvidence(self: *@This(), deadline: anytype) !void {
            self.execution.evidence_attempted = true;
            try self.steps.publishEvidence(deadline);
        }
        pub fn validateFinalCandidate(self: *@This(), deadline: anytype) !void {
            try self.steps.validateFinalCandidate(deadline);
        }
        pub fn validateFinalDeadline(self: *@This(), deadline: anytype) !void {
            try self.steps.validateFinalDeadline(deadline);
        }
        pub fn cleanupEvidence(self: *@This()) !void {
            try self.steps.cleanupEvidence();
            self.execution.evidence_attempted = false;
        }
        pub fn cleanupSignedAppQuit(self: *@This()) !void {
            try self.steps.cleanupSignedAppQuit();
            self.execution.signed_app_quit_attempted = false;
        }
        pub fn cleanupDefaultFalse(self: *@This()) !void {
            try self.steps.cleanupDefaultFalse();
            self.execution.default_false_attempted = false;
        }
    };
}

pub fn derivePaths(candidate_root: []const u8, work_root: []const u8, storage: *PathStorage) !Paths {
    try validateRoot(candidate_root);
    try validateRoot(work_root);
    const storage_bytes = std.mem.asBytes(storage);
    if (overlaps(storage_bytes, candidate_root) or overlaps(storage_bytes, work_root)) return error.InvalidPath;
    if (sameOrDescendant(candidate_root, work_root) or sameOrDescendant(work_root, candidate_root)) return error.InvalidPath;
    return .{
        .app_bundle = try path(&storage.app_bundle, candidate_root, "Maru.app"),
        .app_executable = try path(&storage.app_executable, candidate_root, "Maru.app/Contents/MacOS/maru-macos-app"),
        .cli_executable = try path(&storage.cli_executable, candidate_root, "Maru.app/Contents/MacOS/maru"),
        .default_false_root = try path(&storage.default_false_root, work_root, "default-false"),
        .signed_app_quit_root = try path(&storage.signed_app_quit_root, work_root, "signed-app-quit"),
    };
}

fn path(storage: *[max_path_bytes:0]u8, root: []const u8, leaf: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root, leaf }) catch error.PathTooLong;
}

fn validateRoot(value: []const u8) !void {
    if (!std.fs.path.isAbsolute(value) or value.len < 2 or value.len >= max_path_bytes or
        std.mem.indexOfScalar(u8, value, 0) != null or std.mem.endsWith(u8, value, "/"))
        return error.InvalidPath;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.InvalidPath;
    }
}

fn sameOrDescendant(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
