//! Certificate-bound GitHub artifact attestation verification for Release CI.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const identity = @import("release_adapter_identity");
const github_json = @import("release_adapter_github_json");
const process = @import("bounded_process");

pub const max_response_bytes = github_json.max_response_bytes;
pub const max_token_bytes = github_json.max_scalar_string_bytes;
pub const max_args: usize = 18;
const arg_bytes: usize = context_mod.max_value_bytes + 32;

pub const Expected = struct {
    context: context_mod.Context,
    subject_name: []const u8,
    subject_sha256: []const u8,
};

pub const ArgsStorage = struct {
    args: [max_args][]const u8,
    source_ref: [context_mod.max_value_bytes]u8,
};

pub const Plan = struct { args: []const []const u8 };

pub const Observed = struct {
    parsed: std.json.Parsed(std.json.Value),
    verified: bool,
    run_id: u64,
    run_attempt: u64,
    subject_name: []const u8,
    subject_sha256: []const u8,

    pub fn deinit(self: *Observed, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }
};

pub const Error = error{
    InvalidPath,
    InvalidExpected,
    InvalidToken,
    InvalidBudget,
    InvalidCapture,
    ResponseTooLarge,
    InvalidJson,
    AttestationMismatch,
} || std.mem.Allocator.Error || process.Error;

pub fn plan(storage: *ArgsStorage, artifact_path: []const u8, expected: Expected) Error!Plan {
    try validateExpected(expected);
    if (artifact_path.len < 2 or artifact_path[0] != '/' or !validScalar(artifact_path))
        return error.InvalidPath;
    return planValidated(storage, artifact_path, expected);
}

/// Builds the same closed verifier command for a child whose cwd is a held directory vnode.
pub fn planDirectory(storage: *ArgsStorage, artifact_path: []const u8, expected: Expected) Error!Plan {
    try validateExpected(expected);
    if (artifact_path.len < 3 or !std.mem.startsWith(u8, artifact_path, "./") or
        !std.mem.eql(u8, artifact_path[2..], std.fs.path.basename(artifact_path)) or
        std.mem.eql(u8, artifact_path[2..], ".") or std.mem.eql(u8, artifact_path[2..], "..") or
        !validScalar(artifact_path)) return error.InvalidPath;
    return planValidated(storage, artifact_path, expected);
}

fn planValidated(storage: *ArgsStorage, artifact_path: []const u8, expected: Expected) Error!Plan {
    const source_ref = std.fmt.bufPrint(&storage.source_ref, "refs/tags/{s}", .{expected.context.tag}) catch
        return error.InvalidExpected;
    const values = [_][]const u8{
        "attestation",                    "verify",                                  artifact_path,     "--repo",                       "ohah/maru",
        "--signer-workflow",              "ohah/maru/.github/workflows/release.yml", "--signer-digest", expected.context.source_commit, "--source-digest",
        expected.context.source_commit,   "--source-ref",                            source_ref,        "--deny-self-hosted-runners",   "--predicate-type",
        "https://slsa.dev/provenance/v1", "--format",                                "json",
    };
    comptime std.debug.assert(values.len == max_args);
    for (values, 0..) |value, index| storage.args[index] = value;
    return .{ .args = &storage.args };
}

pub fn parseAndBind(allocator: std.mem.Allocator, bytes: []const u8, expected: Expected) Error!Observed {
    try validateExpected(expected);
    github_json.validateCompleteResponse(bytes) catch |err| switch (err) {
        error.ResponseTooLarge => return error.ResponseTooLarge,
        error.InvalidJson => return error.InvalidJson,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len != 1) return error.AttestationMismatch;
    const root = try object(parsed.value.array.items[0]);
    const result = try objectField(root, "verificationResult");
    const signature = try objectField(result, "signature");
    const certificate = try objectField(signature, "certificate");

    var repository_uri: [context_mod.max_value_bytes]u8 = undefined;
    const repo_uri = std.fmt.bufPrint(&repository_uri, "https://github.com/{s}/{s}", .{ expected.context.repository.owner, expected.context.repository.name }) catch return error.InvalidExpected;
    var owner_uri_storage: [context_mod.max_value_bytes]u8 = undefined;
    const owner_uri = std.fmt.bufPrint(&owner_uri_storage, "https://github.com/{s}", .{expected.context.repository.owner}) catch return error.InvalidExpected;
    var source_ref_storage: [context_mod.max_value_bytes]u8 = undefined;
    const source_ref = std.fmt.bufPrint(&source_ref_storage, "refs/tags/{s}", .{expected.context.tag}) catch return error.InvalidExpected;
    var workflow_uri_storage: [context_mod.max_value_bytes]u8 = undefined;
    const workflow_uri = std.fmt.bufPrint(&workflow_uri_storage, "https://github.com/{s}", .{expected.context.build.workflow_ref}) catch return error.InvalidExpected;
    var run_uri_storage: [context_mod.max_value_bytes]u8 = undefined;
    const run_uri = std.fmt.bufPrint(&run_uri_storage, "{s}/actions/runs/{d}/attempts/{d}", .{ repo_uri, expected.context.build.run_id, expected.context.build.run_attempt }) catch return error.InvalidExpected;
    var repo_id_storage: [32]u8 = undefined;
    const repo_id = std.fmt.bufPrint(&repo_id_storage, "{d}", .{expected.context.repository.id}) catch return error.InvalidExpected;

    const exact_certificate = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "subjectAlternativeName", .value = workflow_uri },
        .{ .name = "issuer", .value = "https://token.actions.githubusercontent.com" },
        .{ .name = "githubWorkflowTrigger", .value = "push" },
        .{ .name = "githubWorkflowSHA", .value = expected.context.source_commit },
        .{ .name = "githubWorkflowRepository", .value = "ohah/maru" },
        .{ .name = "githubWorkflowRef", .value = source_ref },
        .{ .name = "buildSignerURI", .value = workflow_uri },
        .{ .name = "buildSignerDigest", .value = expected.context.source_commit },
        .{ .name = "runnerEnvironment", .value = "github-hosted" },
        .{ .name = "sourceRepositoryURI", .value = repo_uri },
        .{ .name = "sourceRepositoryDigest", .value = expected.context.source_commit },
        .{ .name = "sourceRepositoryRef", .value = source_ref },
        .{ .name = "sourceRepositoryIdentifier", .value = repo_id },
        .{ .name = "sourceRepositoryOwnerURI", .value = owner_uri },
        .{ .name = "buildConfigURI", .value = workflow_uri },
        .{ .name = "buildConfigDigest", .value = expected.context.source_commit },
        .{ .name = "buildTrigger", .value = "push" },
        .{ .name = "runInvocationURI", .value = run_uri },
        .{ .name = "sourceRepositoryVisibilityAtSigning", .value = "public" },
    };
    for (exact_certificate) |field| try requireString(certificate, field.name, field.value);

    const statement = try objectField(result, "statement");
    try requireString(statement, "_type", "https://in-toto.io/Statement/v1");
    try requireString(statement, "predicateType", "https://slsa.dev/provenance/v1");
    const subjects = try arrayField(statement, "subject");
    if (subjects.items.len != 1) return error.AttestationMismatch;
    const subject = try object(subjects.items[0]);
    const observed_name = try stringField(subject, "name");
    if (!std.mem.eql(u8, observed_name, expected.subject_name)) return error.AttestationMismatch;
    const digest = try objectField(subject, "digest");
    const observed_sha = try stringField(digest, "sha256");
    if (!std.mem.eql(u8, observed_sha, expected.subject_sha256)) return error.AttestationMismatch;

    const predicate = try objectField(statement, "predicate");
    const definition = try objectField(predicate, "buildDefinition");
    try requireString(definition, "buildType", "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1");
    const external = try objectField(definition, "externalParameters");
    const workflow = try objectField(external, "workflow");
    try requireString(workflow, "path", ".github/workflows/release.yml");
    try requireString(workflow, "ref", source_ref);
    try requireString(workflow, "repository", repo_uri);
    const internal = try objectField(definition, "internalParameters");
    const github = try objectField(internal, "github");
    try requireString(github, "event_name", "push");
    try requireString(github, "repository_id", repo_id);
    const dependencies = try arrayField(definition, "resolvedDependencies");
    if (dependencies.items.len != 1) return error.AttestationMismatch;
    const dependency = try object(dependencies.items[0]);
    var dependency_uri_storage: [context_mod.max_value_bytes]u8 = undefined;
    const dependency_uri = std.fmt.bufPrint(&dependency_uri_storage, "git+{s}@{s}", .{ repo_uri, source_ref }) catch return error.InvalidExpected;
    try requireString(dependency, "uri", dependency_uri);
    try requireString(try objectField(dependency, "digest"), "gitCommit", expected.context.source_commit);
    const run_details = try objectField(predicate, "runDetails");
    try requireString(try objectField(run_details, "builder"), "id", "https://github.com/actions/runner/github-hosted");
    try requireString(try objectField(run_details, "metadata"), "invocationId", run_uri);
    const timestamps = try arrayField(result, "verifiedTimestamps");
    if (timestamps.items.len == 0) return error.AttestationMismatch;
    for (timestamps.items) |timestamp_value| {
        const timestamp = try object(timestamp_value);
        for ([_][]const u8{ "type", "uri", "timestamp" }) |name| {
            const value = try stringField(timestamp, name);
            if (!validScalar(value)) return error.AttestationMismatch;
        }
    }
    return .{ .parsed = parsed, .verified = true, .run_id = expected.context.build.run_id, .run_attempt = expected.context.build.run_attempt, .subject_name = observed_name, .subject_sha256 = observed_sha };
}

pub fn verifyWith(executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, artifact_path: []const u8, expected: Expected, output: []u8, budget_ns: i128) !Observed {
    if (!validScalar(token)) return error.InvalidToken;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (output.len == 0 or output.len > max_response_bytes) return error.ResponseTooLarge;
    var storage: ArgsStorage = undefined;
    const request = try plan(&storage, artifact_path, expected);
    var token_storage: ["GH_TOKEN=".len + max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    const captured = try executor.capture(executable, request.args, &environment, output, budget_ns);
    if (!borrowedFrom(captured, output)) return error.InvalidCapture;
    return parseAndBind(allocator, captured, expected);
}

pub fn verifyDirectoryWith(executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, directory_fd: std.c.fd_t, artifact_path: []const u8, expected: Expected, output: []u8, budget_ns: i128) !Observed {
    if (!validScalar(token)) return error.InvalidToken;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (output.len == 0 or output.len > max_response_bytes) return error.ResponseTooLarge;
    var storage: ArgsStorage = undefined;
    const request = try planDirectory(&storage, artifact_path, expected);
    var token_storage: ["GH_TOKEN=".len + max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    const captured = try executor.captureDirectory(executable, request.args, &environment, directory_fd, output, budget_ns);
    if (!borrowedFrom(captured, output)) return error.InvalidCapture;
    return parseAndBind(allocator, captured, expected);
}

pub fn verify(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, artifact_path: []const u8, expected: Expected, output: []u8, budget_ns: i128) !Observed {
    var executor = BoundedExecutor{ .io = io };
    return verifyWith(&executor, allocator, executable, token, artifact_path, expected, output, budget_ns);
}

pub const BoundedExecutor = struct {
    io: std.Io,
    pub fn capture(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) Error![]const u8 {
        return self.captureOptionalDirectory(executable, child_args, environment, null, output, budget_ns);
    }

    pub fn captureDirectory(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, directory_fd: std.c.fd_t, output: []u8, budget_ns: i128) Error![]const u8 {
        return self.captureOptionalDirectory(executable, child_args, environment, directory_fd, output, budget_ns);
    }

    fn captureOptionalDirectory(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, directory_fd: ?std.c.fd_t, output: []u8, budget_ns: i128) Error![]const u8 {
        var executable_storage: [max_token_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidPath;
        var args_storage: [max_args][arg_bytes]u8 = undefined;
        var argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (child_args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&args_storage[index], "{s}", .{arg}) catch return error.InvalidExpected).ptr;
        var environment_bytes: [2]["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| envp[index] = (std.fmt.bufPrintZ(&environment_bytes[index], "{s}", .{entry}) catch return error.InvalidToken).ptr;
        return if (directory_fd) |fd|
            process.runCaptureEnvironmentStdoutDirectory(self.io, executable_z, &argv, &envp, fd, output, budget_ns)
        else
            process.runCaptureEnvironmentStdout(self.io, executable_z, &argv, &envp, output, budget_ns);
    }
};

fn validateExpected(expected: Expected) Error!void {
    if (expected.context.repository.id == 0 or !std.mem.eql(u8, expected.context.repository.owner, "ohah") or !std.mem.eql(u8, expected.context.repository.name, "maru") or !identity.canonicalTag(expected.context.tag) or !identity.lowerHex(expected.context.source_commit, 40) or !expected.context.protected_tag or expected.context.build.run_id == 0 or expected.context.build.run_attempt == 0 or !identity.lowerHex(expected.subject_sha256, 64) or expected.subject_name.len == 0 or std.mem.indexOfScalar(u8, expected.subject_name, '/') != null or !validScalar(expected.subject_name)) return error.InvalidExpected;
    var workflow_storage: [context_mod.max_value_bytes]u8 = undefined;
    const workflow = std.fmt.bufPrint(
        &workflow_storage,
        "ohah/maru/.github/workflows/release.yml@refs/tags/{s}",
        .{expected.context.tag},
    ) catch return error.InvalidExpected;
    if (!std.mem.eql(u8, expected.context.build.workflow_ref, workflow))
        return error.InvalidExpected;
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.AttestationMismatch;
}
fn objectField(map: std.json.ObjectMap, name: []const u8) Error!std.json.ObjectMap {
    return object(map.get(name) orelse return error.AttestationMismatch);
}
fn arrayField(map: std.json.ObjectMap, name: []const u8) Error!std.json.Array {
    const value = map.get(name) orelse return error.AttestationMismatch;
    return if (value == .array) value.array else error.AttestationMismatch;
}
fn stringField(map: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const value = map.get(name) orelse return error.AttestationMismatch;
    return if (value == .string) value.string else error.AttestationMismatch;
}
fn requireString(map: std.json.ObjectMap, name: []const u8, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, try stringField(map, name), expected)) return error.AttestationMismatch;
}
fn borrowedFrom(captured: []const u8, supplied: []const u8) bool {
    const start = @intFromPtr(supplied.ptr);
    const end = std.math.add(usize, start, supplied.len) catch return false;
    const captured_start = @intFromPtr(captured.ptr);
    const captured_end = std.math.add(usize, captured_start, captured.len) catch return false;
    return captured_start >= start and captured_end <= end;
}
