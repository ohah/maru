//! Closed GitHub REST request plans for the session-host release adapter.
//!
//! This module owns endpoint construction and the exact `gh api` argument vocabulary. It does not
//! trust PATH, read credentials, execute a child, or interpret endpoint-specific JSON semantics.

const std = @import("std");
const identity = @import("release_adapter_identity");
const github_json = @import("release_adapter_github_json");

pub const max_response_bytes = github_json.max_response_bytes;
pub const max_token_bytes = github_json.max_scalar_string_bytes;

pub const max_capture_bytes: usize = 2 * max_response_bytes;

pub const PageShape = enum { none, array, jobs };

pub const Attempt = struct {
    run_id: u64,
    attempt: u64,
};

pub const DeploymentQuery = struct {
    source_sha: []const u8,
};

pub const Request = union(enum) {
    repository,
    workflow_run: u64,
    draft_releases,
    published_release: []const u8,
    commit: []const u8,
    tag_ref: []const u8,
    annotated_tag: []const u8,
    environment,
    attempt_jobs: Attempt,
    deployments: DeploymentQuery,
    deployment_statuses: u64,
};

pub const endpoint_storage_bytes = github_json.max_scalar_string_bytes + 1;
pub const max_args: usize = 14;
pub const EndpointStorage = [endpoint_storage_bytes]u8;
pub const ArgsStorage = [max_args][]const u8;

pub const Plan = struct {
    endpoint: []const u8,
    paginated: bool,
    page_shape: PageShape,
};

pub const Error = error{
    InvalidId,
    InvalidTag,
    InvalidSha,
    EndpointTooLong,
    InvalidToken,
    InvalidCapture,
    ResponseTooLarge,
    InvalidResponse,
} || std.mem.Allocator.Error;

pub fn plan(storage: *EndpointStorage, request: Request) Error!Plan {
    const rendered = switch (request) {
        .repository => try render(storage, "repos/ohah/maru", .{}),
        .workflow_run => |run_id| blk: {
            try validId(run_id);
            break :blk try render(storage, "repos/ohah/maru/actions/runs/{d}", .{run_id});
        },
        .draft_releases => try render(storage, "repos/ohah/maru/releases?per_page=100", .{}),
        .published_release => |tag| blk: {
            try validTag(tag);
            break :blk try render(storage, "repos/ohah/maru/releases/tags/{s}", .{tag});
        },
        .commit => |sha| blk: {
            try validSha(sha);
            break :blk try render(storage, "repos/ohah/maru/git/commits/{s}", .{sha});
        },
        .tag_ref => |tag| blk: {
            try validTag(tag);
            break :blk try render(storage, "repos/ohah/maru/git/ref/tags/{s}", .{tag});
        },
        .annotated_tag => |sha| blk: {
            try validSha(sha);
            break :blk try render(storage, "repos/ohah/maru/git/tags/{s}", .{sha});
        },
        .environment => try render(storage, "repos/ohah/maru/environments/release", .{}),
        .attempt_jobs => |attempt| blk: {
            try validId(attempt.run_id);
            try validId(attempt.attempt);
            break :blk try render(
                storage,
                "repos/ohah/maru/actions/runs/{d}/attempts/{d}/jobs?per_page=100",
                .{ attempt.run_id, attempt.attempt },
            );
        },
        .deployments => |query| blk: {
            try validSha(query.source_sha);
            break :blk try render(
                storage,
                "repos/ohah/maru/deployments?sha={s}&environment=release&per_page=100",
                .{query.source_sha},
            );
        },
        .deployment_statuses => |deployment_id| blk: {
            try validId(deployment_id);
            break :blk try render(
                storage,
                "repos/ohah/maru/deployments/{d}/statuses?per_page=100",
                .{deployment_id},
            );
        },
    };
    const page_shape: PageShape = switch (request) {
        .attempt_jobs => .jobs,
        .draft_releases, .deployments, .deployment_statuses => .array,
        else => .none,
    };
    return .{ .endpoint = rendered, .paginated = page_shape != .none, .page_shape = page_shape };
}

/// Returns slices borrowed from `plan` and static literals; callers convert them to sentinel argv.
pub fn args(storage: *ArgsStorage, request_plan: Plan) []const []const u8 {
    const prefix = [_][]const u8{
        "api",
        "--method",
        "GET",
        "--hostname",
        "github.com",
        "--header",
        "Accept: application/vnd.github+json",
        "--header",
        "X-GitHub-Api-Version: 2022-11-28",
    };
    for (prefix, 0..) |value, index| storage[index] = value;
    var used: usize = prefix.len;
    if (request_plan.paginated) {
        storage[used] = "--paginate";
        storage[used + 1] = "--slurp";
        used += 2;
    }
    storage[used] = request_plan.endpoint;
    return storage[0 .. used + 1];
}

pub fn validateToken(token: []const u8) Error!void {
    if (token.len == 0 or token.len > max_token_bytes) return error.InvalidToken;
    for (token) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidToken;
}

pub fn validateOutput(output: []const u8) Error!void {
    github_json.validateCompleteResponse(output) catch |err| switch (err) {
        error.ResponseTooLarge => return error.ResponseTooLarge,
        error.InvalidJson => return error.InvalidResponse,
    };
}

pub fn normalizeOutput(
    allocator: std.mem.Allocator,
    request_plan: Plan,
    captured: []const u8,
    output: []u8,
) Error![]const u8 {
    if (!request_plan.paginated) {
        try validateOutput(captured);
        if (captured.len > output.len) return error.ResponseTooLarge;
        @memcpy(output[0..captured.len], captured);
        return output[0..captured.len];
    }
    if (captured.len > max_capture_bytes) return error.ResponseTooLarge;
    try validateSlurpedCapture(captured);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, captured, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0)
        return error.InvalidResponse;

    var writer = std.Io.Writer.fixed(output[0..@min(output.len, max_response_bytes)]);
    var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    switch (request_plan.page_shape) {
        .none => unreachable,
        .array => {
            json.beginArray() catch return error.ResponseTooLarge;
            for (parsed.value.array.items) |page| {
                if (page != .array) return error.InvalidResponse;
                for (page.array.items) |item| json.write(item) catch return error.ResponseTooLarge;
            }
            json.endArray() catch return error.ResponseTooLarge;
        },
        .jobs => {
            var total_count: ?i64 = null;
            var flattened_jobs: usize = 0;
            json.beginObject() catch return error.ResponseTooLarge;
            json.objectField("total_count") catch return error.ResponseTooLarge;
            for (parsed.value.array.items) |page| {
                if (page != .object) return error.InvalidResponse;
                const value = page.object.get("total_count") orelse return error.InvalidResponse;
                if (value != .integer or value.integer < 0) return error.InvalidResponse;
                if (total_count != null and total_count.? != value.integer) return error.InvalidResponse;
                total_count = value.integer;
            }
            json.write(total_count.?) catch return error.ResponseTooLarge;
            json.objectField("jobs") catch return error.ResponseTooLarge;
            json.beginArray() catch return error.ResponseTooLarge;
            for (parsed.value.array.items) |page| {
                const jobs = page.object.get("jobs") orelse return error.InvalidResponse;
                if (jobs != .array) return error.InvalidResponse;
                for (jobs.array.items) |job| {
                    json.write(job) catch return error.ResponseTooLarge;
                    flattened_jobs += 1;
                }
            }
            if (total_count.? != @as(i64, @intCast(flattened_jobs))) return error.InvalidResponse;
            json.endArray() catch return error.ResponseTooLarge;
            json.endObject() catch return error.ResponseTooLarge;
        },
    }
    const result = writer.buffered();
    try validateOutput(result);
    return result;
}

fn validateSlurpedCapture(captured: []const u8) Error!void {
    // Bounded scanner nesting storage; scalar contents are only counted, never allocated.
    var scratch: [max_capture_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), captured);
    defer scanner.deinit();
    var scalar_len: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.InvalidResponse;
        switch (token) {
            .partial_number, .partial_string => |slice| try addCaptureScalarBytes(&scalar_len, slice.len),
            .partial_string_escaped_1 => |value| try addCaptureScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_2 => |value| try addCaptureScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_3 => |value| try addCaptureScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_4 => |value| try addCaptureScalarBytes(&scalar_len, value.len),
            .number, .string => |slice| {
                try addCaptureScalarBytes(&scalar_len, slice.len);
                scalar_len = 0;
            },
            .end_of_document => {
                if (scanner.cursor != captured.len) return error.InvalidResponse;
                return;
            },
            else => {},
        }
    }
}

fn addCaptureScalarBytes(current: *usize, additional: usize) Error!void {
    if (additional > github_json.max_scalar_string_bytes - current.*) return error.InvalidResponse;
    current.* += additional;
}

fn validId(value: u64) Error!void {
    if (value == 0) return error.InvalidId;
}

fn validTag(value: []const u8) Error!void {
    if (!identity.canonicalTag(value)) return error.InvalidTag;
}

fn validSha(value: []const u8) Error!void {
    if (!identity.lowerHex(value, 40)) return error.InvalidSha;
}

fn render(storage: *EndpointStorage, comptime format: []const u8, values: anytype) Error![]const u8 {
    return std.fmt.bufPrint(storage, format, values) catch return error.EndpointTooLong;
}
