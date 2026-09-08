//! Builds the only scalar projection allowed to cross the authored-attestation process boundary.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const profile_mod = @import("release_adapter_profile_endorsement");
const selector = @import("release_adapter_profile_authored_attestation_selector");

pub const option_count: usize = 5;
pub const argument_count: usize = 1 + option_count * 2;
pub const max_output_bytes: usize = 5 * std.fs.max_path_bytes + 512;

pub const Execution = struct {
    owner: ?*@This() = null,
    paths: [option_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    path_lens: [option_count]usize = @splat(0),
    plan: selector.Plan = .{},
    encoded: [max_output_bytes]u8 = @splat(0),
    encoded_len: usize = 0,
    seal: [32]u8 = @splat(0),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and std.mem.allEqual(usize, &self.path_lens, 0) and
            self.plan.isPristineForComposition() and self.encoded_len == 0 and
            allZero(std.mem.asBytes(&self.paths)) and allZero(&self.encoded) and allZero(&self.seal);
    }

    pub fn output(self: *const @This()) ?[]const u8 {
        if (self.owner != self or self.encoded_len == 0 or self.encoded_len > self.encoded.len) return null;
        if (!std.mem.eql(u8, &self.seal, &executionSeal(self))) return null;
        return self.encoded[0..self.encoded_len];
    }

    pub fn deinit(self: *@This()) !void {
        if (self.output() == null) return error.InvalidOwner;
        var first_error: ?anyerror = null;
        if (self.plan.owner == &self.plan) self.plan.deinit() catch |err| {
            first_error = err;
        };
        self.* = .{};
        if (first_error) |err| return err;
    }
};

const options = [_][]const u8{ "--preparation", "--baseline-evidence", "--upgrade-evidence", "--manifest", "--timing" };

pub fn compose(
    allocator: std.mem.Allocator,
    context: context_mod.Context,
    environment: profile_mod.Environment,
    args: []const []const u8,
    result: *Execution,
) ![]const u8 {
    if (!result.isPristineForComposition()) return error.InvalidOwner;
    if (args.len != argument_count) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "select")) return error.InvalidCommand;
    var values: [option_count]?[]const u8 = @splat(null);
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const option = args[index];
        const value = args[index + 1];
        if (value.len == 0 or value.len >= std.fs.max_path_bytes or hasControl(option) or hasControl(value)) return error.InvalidArguments;
        var found: ?usize = null;
        for (options, 0..) |candidate, candidate_index| if (std.mem.eql(u8, option, candidate)) {
            found = candidate_index;
            break;
        };
        const option_index = found orelse return error.InvalidArguments;
        if (values[option_index] != null) return error.InvalidArguments;
        values[option_index] = value;
    }
    for (&values) |value| if (value == null) return error.InvalidArguments;
    for (&values) |value| {
        const bytes = value.?;
        if (overlaps(bytes, std.mem.asBytes(result))) return error.InvalidOwner;
    }
    errdefer closeWorking(result);
    for (&values, 0..) |value, value_index| {
        const bytes = value.?;
        @memcpy(result.paths[value_index][0..bytes.len], bytes);
        result.path_lens[value_index] = bytes.len;
    }
    const paths = pathView(result);
    try selector.select(allocator, context, environment, paths, &result.plan);
    const projection = try result.plan.fence(allocator, context, environment);
    result.encoded_len = try encode(&result.encoded, projection);
    result.owner = result;
    result.seal = executionSeal(result);
    return result.output() orelse error.InvalidOwner;
}

fn pathView(result: *const Execution) selector.Paths {
    return .{
        .preparation = result.paths[0][0..result.path_lens[0] :0],
        .baseline_evidence = result.paths[1][0..result.path_lens[1] :0],
        .upgrade_evidence = result.paths[2][0..result.path_lens[2] :0],
        .manifest = result.paths[3][0..result.path_lens[3] :0],
        .timing = result.paths[4][0..result.path_lens[4] :0],
    };
}

fn encode(storage: []u8, value: selector.Projection) !usize {
    inline for (.{ value.evidence_path, value.evidence_name, value.manifest_path, value.manifest_name, value.timing_path, value.timing_name }) |field|
        if (hasControl(field)) return error.InvalidProjection;
    const required = if (value.timing_required) "true" else "false";
    const written = std.fmt.bufPrint(
        storage,
        "evidence-path={s}\nevidence-name={s}\nmanifest-path={s}\nmanifest-name={s}\ntiming-required={s}\ntiming-path={s}\ntiming-name={s}\n",
        .{ value.evidence_path, value.evidence_name, value.manifest_path, value.manifest_name, required, value.timing_path, value.timing_name },
    ) catch return error.OutputTooLarge;
    return written.len;
}

fn executionSeal(value: *const Execution) [32]u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&value.path_lens));
    hash.update(std.mem.asBytes(&value.paths));
    hash.update(std.mem.asBytes(&value.encoded_len));
    hash.update(value.encoded[0..value.encoded_len]);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn hasControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    const a_end = std.math.add(usize, a, left.len) catch return true;
    const b_end = std.math.add(usize, b, right.len) catch return true;
    return a < b_end and b < a_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn closeWorking(result: *Execution) void {
    if (result.plan.owner == &result.plan) result.plan.deinit() catch {};
    result.* = .{};
}
