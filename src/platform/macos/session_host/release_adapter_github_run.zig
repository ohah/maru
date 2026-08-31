//! Strict semantic parser for the current GitHub Actions workflow-run REST response.
//!
//! It binds already-captured bytes to the closed Actions context. It does not authenticate the
//! transport and does not prove that the current job passed the protected release environment.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const github_json = @import("release_adapter_github_json");
const github_repository = @import("release_adapter_github_repository");

pub const max_response_bytes = github_json.max_response_bytes;

const ApiRun = struct {
    id: github_repository.StrictU64,
    run_attempt: github_repository.StrictU64,
    event: []const u8,
    head_sha: []const u8,
    path: []const u8,
    status: []const u8,
    conclusion: ?[]const u8,
    pull_requests: []const std.json.Value,
    repository: github_repository.WireRepository,
    head_repository: ?github_repository.WireRepository,
};

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
    RunMismatch,
} || std.mem.Allocator.Error;

pub const Observation = struct {
    run_id: u64,
    run_attempt: u64,
    source_commit: []const u8,
    workflow_path: []const u8,
};

pub const Parsed = struct {
    inner: std.json.Parsed(ApiRun),
    bound_observation: Observation,

    pub fn deinit(self: *Parsed) void {
        self.inner.deinit();
    }

    pub fn observation(self: *const Parsed) *const Observation {
        return &self.bound_observation;
    }
};

pub fn parseAndBind(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: context_mod.Context,
) Error!Parsed {
    github_json.validateCompleteResponse(bytes) catch |err| return err;

    var inner = std.json.parseFromSlice(ApiRun, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer inner.deinit();

    const value = inner.value;
    const head_repository = value.head_repository orelse return error.RunMismatch;
    const workflow_path = workflowPath(expected) orelse
        return error.RunMismatch;
    if (value.id.value == 0 or value.id.value != expected.build.run_id or
        value.run_attempt.value == 0 or value.run_attempt.value != expected.build.run_attempt or
        !std.mem.eql(u8, value.event, "push") or
        !std.mem.eql(u8, value.head_sha, expected.source_commit) or
        !std.mem.eql(u8, value.path, workflow_path) or
        !std.mem.eql(u8, value.status, "in_progress") or
        value.conclusion != null or value.pull_requests.len != 0 or
        !github_repository.matchesWire(value.repository, expected.repository) or
        !github_repository.matchesWire(head_repository, expected.repository))
        return error.RunMismatch;

    return .{
        .inner = inner,
        .bound_observation = .{
            .run_id = value.id.value,
            .run_attempt = value.run_attempt.value,
            .source_commit = value.head_sha,
            .workflow_path = value.path,
        },
    };
}

fn workflowPath(expected: context_mod.Context) ?[]const u8 {
    const path = ".github/workflows/release.yml";
    var expected_ref_buf: [context_mod.max_value_bytes]u8 = undefined;
    const expected_ref = std.fmt.bufPrint(
        &expected_ref_buf,
        "ohah/maru/{s}@refs/tags/{s}",
        .{ path, expected.tag },
    ) catch return null;
    if (!std.mem.eql(u8, expected.build.workflow_ref, expected_ref)) return null;
    return path;
}

pub fn parseAndBindForTest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: context_mod.Context,
) !void {
    var parsed = try parseAndBind(allocator, bytes, expected);
    parsed.deinit();
}
