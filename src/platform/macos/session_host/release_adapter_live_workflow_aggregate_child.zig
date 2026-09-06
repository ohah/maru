//! Product-owned stage-5/6 child execution and reducer application boundary.
//!
//! Command identity comes only from the closed contract argv. The child receives a freshly built
//! environment containing only the workflow context vocabulary; ambient credentials and process
//! state cannot cross this boundary.

const std = @import("std");
const bounded = @import("bounded_process");
const context = @import("release_adapter_context");
const contract = @import("release_adapter_contract");
const cli_authority = @import("release_adapter_github_cli_authority");
const mapping = @import("release_adapter_live_workflow_aggregate_event");
const phase = @import("release_adapter_live_workflow_phase");

const max_environment_name_bytes = blk: {
    var maximum: usize = 0;
    for (context.required_names) |name| maximum = @max(maximum, name.len);
    for (cli_authority.required_runner_names) |name| maximum = @max(maximum, name.len);
    break :blk maximum;
};
const max_environment_entry_bytes = max_environment_name_bytes + 1 + context.max_value_bytes;
pub const environment_entry_count = context.required_names.len + cli_authority.required_runner_names.len;

pub const RunResult = enum { observed, observation_failed };

pub const Error = contract.Error || context.Error || cli_authority.Error || mapping.Error || error{
    InvalidArgumentCount,
    InvalidExecutable,
    InvalidBudget,
    InvalidStorage,
    AliasedInput,
    ContextMismatch,
};

pub const Storage = struct {
    in_use: bool = false,
    argument_bytes: [contract.max_command_args][contract.max_cli_value_bytes + 1]u8 = undefined,
    argv: [contract.max_command_args + 2:null]?[*:0]const u8 = @splat(null),
    environment_bytes: [environment_entry_count][max_environment_entry_bytes + 1]u8 = undefined,
    environment: [environment_entry_count + 1:null]?[*:0]const u8 = @splat(null),
    stdout: [mapping.max_stdout_bytes]u8 = undefined,
    stderr: [mapping.max_stderr_bytes]u8 = undefined,
};

/// Executes one validated aggregate command and applies exactly one observation to `state`.
/// Process/capture failures are authority-conservative reducer events, not returned raw errors.
pub fn runAndApply(
    io: std.Io,
    state: *phase.State,
    executable: [:0]const u8,
    arguments: []const []const u8,
    environment_entries: []const context.Entry,
    budget_ns: i128,
    storage: *Storage,
) Error!RunResult {
    if (storage.in_use) return error.InvalidStorage;
    if (arguments.len == 0 or arguments.len > contract.max_command_args)
        return error.InvalidArgumentCount;
    if (environment_entries.len < environment_entry_count) return error.MissingKey;
    if (environment_entries.len > environment_entry_count) return error.UnknownKey;
    if (executable.len < 2 or executable[0] != '/' or std.mem.indexOfScalar(u8, executable, 0) != null)
        return error.InvalidExecutable;
    if (budget_ns <= 0) return error.InvalidBudget;
    try rejectStorageAliases(storage, state, executable, arguments, environment_entries);

    const parsed = try contract.parseArgs(arguments);
    const command: mapping.Command = std.meta.activeTag(parsed);
    try mapping.validateApplication(state, command);
    const workflow_context = try validateEnvironment(environment_entries);
    const command_tag = switch (parsed) {
        .prepare_candidate_aggregate => |value| value.tag,
        .finalize_candidate_aggregate => |value| value.tag,
        else => return error.InvalidCommand,
    };
    if (!std.mem.eql(u8, command_tag, workflow_context.tag))
        return error.ContextMismatch;

    storage.in_use = true;
    defer clear(storage);
    buildArgv(storage, executable, arguments);
    buildEnvironment(storage, environment_entries);

    const observation = bounded.runObserveEnvironment(
        io,
        executable,
        &storage.argv,
        &storage.environment,
        &storage.stdout,
        &storage.stderr,
        budget_ns,
    ) catch {
        try mapping.applyObservation(state, command, .{
            .termination = .{ .unknown = 0 },
            .stdout = .{ .bytes = "", .complete = false },
            .stderr = .{ .bytes = "", .complete = false },
        });
        return .observation_failed;
    };
    try mapping.applyObservation(state, command, .{
        .termination = switch (observation.termination) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = signal },
            .unknown => |status| .{ .unknown = status },
        },
        .stdout = .{ .bytes = observation.stdout, .complete = true },
        .stderr = .{ .bytes = observation.stderr, .complete = true },
    });
    return .observed;
}

fn buildArgv(storage: *Storage, executable: [:0]const u8, arguments: []const []const u8) void {
    @memset(&storage.argv, null);
    storage.argv[0] = executable.ptr;
    for (arguments, 0..) |argument, index| {
        @memcpy(storage.argument_bytes[index][0..argument.len], argument);
        storage.argument_bytes[index][argument.len] = 0;
        storage.argv[index + 1] = @ptrCast(&storage.argument_bytes[index]);
    }
}

fn buildEnvironment(storage: *Storage, entries: []const context.Entry) void {
    @memset(&storage.environment, null);
    inline for (context.required_names, 0..) |name, index| {
        const value = valueForName(entries, name).?;
        const bytes = &storage.environment_bytes[index];
        @memcpy(bytes[0..name.len], name);
        bytes[name.len] = '=';
        @memcpy(bytes[name.len + 1 ..][0..value.len], value);
        bytes[name.len + 1 + value.len] = 0;
        storage.environment[index] = @ptrCast(bytes);
    }
    inline for (cli_authority.required_runner_names, 0..) |name, runner_index| {
        const index = context.required_names.len + runner_index;
        const value = valueForName(entries, name).?;
        const bytes = &storage.environment_bytes[index];
        @memcpy(bytes[0..name.len], name);
        bytes[name.len] = '=';
        @memcpy(bytes[name.len + 1 ..][0..value.len], value);
        bytes[name.len + 1 + value.len] = 0;
        storage.environment[index] = @ptrCast(bytes);
    }
}

fn validateEnvironment(entries: []const context.Entry) Error!context.Context {
    for (entries) |entry| if (!knownEnvironmentName(entry.name)) return error.UnknownKey;
    inline for (context.required_names) |name| try requireExactEntry(entries, name);
    inline for (cli_authority.required_runner_names) |name| try requireExactEntry(entries, name);

    var context_entries: [context.required_names.len]context.Entry = undefined;
    inline for (context.required_names, 0..) |name, index|
        context_entries[index] = .{ .name = name, .value = valueForName(entries, name).? };
    const workflow_context = try context.parse(&context_entries);
    var lookup = EntryLookup{ .entries = entries };
    _ = try cli_authority.readRunner(&lookup, workflow_context.source_commit);
    return workflow_context;
}

fn knownEnvironmentName(name: []const u8) bool {
    inline for (context.required_names) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    inline for (cli_authority.required_runner_names) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn requireExactEntry(entries: []const context.Entry, name: []const u8) error{ MissingKey, DuplicateKey }!void {
    var count: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) count += 1;
    }
    if (count == 0) return error.MissingKey;
    if (count != 1) return error.DuplicateKey;
}

const EntryLookup = struct {
    entries: []const context.Entry,

    pub fn get(self: *@This(), name: [:0]const u8) ?[]const u8 {
        return valueForName(self.entries, name);
    }
};

fn valueForName(entries: []const context.Entry, name: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

fn rejectStorageAliases(
    storage: *Storage,
    state: *const phase.State,
    executable: []const u8,
    arguments: []const []const u8,
    entries: []const context.Entry,
) error{AliasedInput}!void {
    const owned = std.mem.asBytes(storage);
    if (overlap(std.mem.asBytes(state), owned) or
        overlap(std.mem.sliceAsBytes(arguments), owned) or
        overlap(std.mem.sliceAsBytes(entries), owned) or
        overlap(executable, owned)) return error.AliasedInput;
    for (arguments) |argument| if (overlap(argument, owned)) return error.AliasedInput;
    for (entries) |entry| {
        if (overlap(entry.name, owned) or overlap(entry.value, owned)) return error.AliasedInput;
    }
}

fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn clear(storage: *Storage) void {
    @memset(std.mem.asBytes(&storage.argument_bytes), 0);
    @memset(std.mem.asBytes(&storage.environment_bytes), 0);
    @memset(&storage.argv, null);
    @memset(&storage.environment, null);
    @memset(&storage.stdout, 0);
    @memset(&storage.stderr, 0);
    storage.in_use = false;
}
