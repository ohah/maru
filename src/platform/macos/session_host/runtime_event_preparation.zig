//! Allocation-free preparation recipe for an already classified runtime event.
//!
//! This leaf owns no source or destination storage. It canonicalizes the classifier result into
//! a fixed value and can later fill caller-owned metadata scratch after rebinding the payload.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const resize_wire = @import("resize_wire.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_types = @import("runtime_metadata_types.zig");

pub const Digest = runtime_event_wire.Digest;
pub const max_process_entries = runtime_metadata_types.max_process_entries;
pub const max_process_name_bytes = runtime_metadata_types.max_process_name_bytes;
pub const FilledProcess = runtime_metadata_types.ProcessValue;

pub const StringRecipe = struct {
    destination_start: u32 = 0,
    decoded_len: u32 = 0,
    digest: Digest = [_]u8{0} ** 32,
};

pub const ProcessRecipe = struct {
    pid: i32 = 0,
    name_len: u8 = 0,
    name_digest: Digest = [_]u8{0} ** 32,
};

pub const MetadataPreparationRecipe = struct {
    payload_digest: Digest = [_]u8{0} ** 32,
    semantic_digest: Digest = [_]u8{0} ** 32,
    backing_bytes: u32 = 0,
    revision: u64 = 0,
    observer_generation: u64 = 0,
    title_generation: u32 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    semantic_state_raw: u8 = 0,
    alt_active_raw: u8 = 0,
    app_cursor_keys_raw: u8 = 0,
    app_keypad_raw: u8 = 0,
    kitty_flags_raw: u8 = 0,
    alternate_scroll_raw: u8 = 0,
    mouse_tracking_raw: u8 = 0,
    mouse_tracking_mode: u8 = 0,
    bracketed_paste_raw: u8 = 0,
    bell_count: u64 = 0,
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,
    foreground_available_raw: u8 = 0,
    foreground_pgid_present_raw: u8 = 0,
    foreground_pgid: i32 = 0,
    /// PTY 자식 뿌리와 host 프로세스 pid. **선택 필드라 present 플래그가 없다** — 구 host면 0이고,
    /// 0은 "모른다"와 "없다"를 가를 필요가 없는 값이다(pid 0은 유효한 대상이 아니다).
    child_pid: i32 = 0,
    host_pid: i32 = 0,
    cwd: StringRecipe = .{},
    window_title: StringRecipe = .{},
    ssh_remote_dest_present_raw: u8 = 0,
    ssh_remote_dest: StringRecipe = .{},
    clipboard_read_target: StringRecipe = .{},
    processes: [max_process_entries]ProcessRecipe = [_]ProcessRecipe{.{}} ** max_process_entries,
    process_count: u8 = 0,
};

pub const AcceptedPreparationTag = enum(u8) {
    revoked = 1,
    invalidated = 2,
    resized = 3,
    metadata = 4,
    ended = 5,
};

pub const AcceptedPreparationRecipe = union(AcceptedPreparationTag) {
    revoked: u64,
    invalidated: void,
    resized: resize_wire.Event,
    metadata: MetadataPreparationRecipe,
    ended: void,
};

pub const EventPreparationTag = enum(u8) {
    accepted = 1,
    violation = 2,
};

pub const EventPreparationRecipe = union(EventPreparationTag) {
    accepted: AcceptedPreparationRecipe,
    violation: runtime_event_types.Violation,
};

pub const FilledRange = struct {
    start: u32,
    len: u32,
};

pub const MetadataFillProjection = struct {
    cwd: FilledRange,
    window_title: FilledRange,
    ssh_remote_dest_present_raw: u8,
    ssh_remote_dest: FilledRange,
    clipboard_read_target: FilledRange,
    process_count: u8,
};

pub const RecipeError = error{
    Malformed,
    ResourceExhausted,
};

pub const FillError = RecipeError || error{
    DestinationMismatch,
    DestinationOverlap,
};

const FillPostCopyTestHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
};

const fill_post_copy_testing = if (builtin.is_test) struct {
    threadlocal var hook: ?FillPostCopyTestHook = null;
} else struct {};

fn runFillPostCopyTestHook() void {
    if (builtin.is_test) {
        if (fill_post_copy_testing.hook) |hook| hook.run(hook.context);
    }
}

pub fn buildEventPreparationRecipe(
    classification: runtime_event_types.Classification,
    payload: []const u8,
) RecipeError!EventPreparationRecipe {
    return switch (classification) {
        .violation => |value| .{ .violation = value },
        .accepted => |accepted| .{ .accepted = switch (accepted) {
            .revoked => |generation| .{ .revoked = try validateRevoked(payload, generation) },
            .invalidated => blk: {
                try validateEmptyAccepted(payload, .invalidated);
                break :blk .invalidated;
            },
            .resized => |event| .{ .resized = try validateResized(payload, event) },
            .metadata => |validated| .{
                .metadata = try buildMetadataRecipe(payload, validated),
            },
            .ended => blk: {
                try validateEmptyAccepted(payload, .ended);
                break :blk .ended;
            },
        } },
    };
}

pub fn fillMetadataRecipe(
    recipe: *const MetadataPreparationRecipe,
    classification: runtime_event_types.Classification,
    payload: []const u8,
    backing: []u8,
    processes: *[max_process_entries]FilledProcess,
) FillError!MetadataFillProjection {
    const rebuilt_event = try buildEventPreparationRecipe(classification, payload);
    const rebuilt = switch (rebuilt_event) {
        .accepted => |accepted| switch (accepted) {
            .metadata => |metadata| metadata,
            else => return error.Malformed,
        },
        .violation => return error.Malformed,
    };
    if (!std.meta.eql(recipe.*, rebuilt)) return error.Malformed;
    if (backing.len != recipe.backing_bytes) return error.DestinationMismatch;
    try validateDestinationExtents(recipe, payload, backing, processes);

    const preflight = canonicalAccepted(payload) orelse return error.Malformed;
    const metadata = switch (preflight.event) {
        .metadata => |value| value,
        else => return error.Malformed,
    };
    try validateFillPlan(recipe, payload, &metadata);

    processes.* = [_]FilledProcess{.{}} ** max_process_entries;
    try decodeInto(payload, metadata.cwd, recipe.cwd, backing);
    try decodeInto(payload, metadata.window_title, recipe.window_title, backing);
    if (metadata.ssh_remote_dest) |span|
        try decodeInto(payload, span, recipe.ssh_remote_dest, backing);
    try decodeInto(
        payload,
        metadata.clipboard_read_target,
        recipe.clipboard_read_target,
        backing,
    );
    for (metadata.foregroundProcesses(), 0..) |process, index| {
        processes[index].pid = process.pid;
        processes[index].len = @intCast(process.name.decoded_len);
        runtime_event_wire.decodeStringExact(
            payload,
            process.name,
            processes[index].bytes[0..process.name.decoded_len],
        ) catch return error.Malformed;
    }

    runFillPostCopyTestHook();
    if (!std.mem.eql(
        u8,
        &runtime_event_wire.payloadDigest(payload),
        &recipe.payload_digest,
    )) return error.Malformed;
    return .{
        .cwd = filledRange(recipe.cwd),
        .window_title = filledRange(recipe.window_title),
        .ssh_remote_dest_present_raw = recipe.ssh_remote_dest_present_raw,
        .ssh_remote_dest = filledRange(recipe.ssh_remote_dest),
        .clipboard_read_target = filledRange(recipe.clipboard_read_target),
        .process_count = recipe.process_count,
    };
}

fn validateRevoked(payload: []const u8, generation: u64) RecipeError!u64 {
    const preflight = canonicalAccepted(payload) orelse return error.Malformed;
    const revoked = switch (preflight.event) {
        .revoked => |value| value,
        else => return error.Malformed,
    };
    if (revoked.controller_generation != generation) return error.Malformed;
    return generation;
}

fn validateEmptyAccepted(
    payload: []const u8,
    comptime expected: std.meta.Tag(runtime_event_wire.Event),
) RecipeError!void {
    const preflight = canonicalAccepted(payload) orelse return error.Malformed;
    if (std.meta.activeTag(preflight.event) != expected) return error.Malformed;
}

fn validateResized(
    payload: []const u8,
    expected: resize_wire.Event,
) RecipeError!resize_wire.Event {
    const preflight = canonicalAccepted(payload) orelse return error.Malformed;
    const actual = switch (preflight.event) {
        .resized => |value| value,
        else => return error.Malformed,
    };
    if (!std.meta.eql(actual, expected)) return error.Malformed;
    return expected;
}

fn buildMetadataRecipe(
    payload: []const u8,
    validated: runtime_event_types.ValidatedMetadataView,
) RecipeError!MetadataPreparationRecipe {
    const preflight = canonicalAccepted(payload) orelse return error.Malformed;
    if (!runtime_event_wire.eventPreflightEql(preflight, validated.preflight()))
        return error.Malformed;
    const metadata = switch (preflight.event) {
        .metadata => |value| value,
        else => return error.Malformed,
    };
    if (metadata.process_count > max_process_entries) return error.ResourceExhausted;

    var result: MetadataPreparationRecipe = .{
        .payload_digest = preflight.raw_digest,
        .semantic_digest = metadata.semantic_digest,
        .revision = metadata.revision,
        .observer_generation = metadata.observer_generation,
        .title_generation = metadata.title_generation,
        .cols = metadata.cols,
        .rows = metadata.rows,
        .semantic_state_raw = @intFromEnum(metadata.semantic_state),
        .alt_active_raw = @intFromBool(metadata.alt_active),
        .app_cursor_keys_raw = @intFromBool(metadata.app_cursor_keys),
        .app_keypad_raw = @intFromBool(metadata.app_keypad),
        .kitty_flags_raw = metadata.kitty_flags,
        .alternate_scroll_raw = @intFromBool(metadata.alternate_scroll),
        .mouse_tracking_raw = @intFromBool(metadata.mouse_tracking),
        .mouse_tracking_mode = metadata.mouse_tracking_mode,
        .bracketed_paste_raw = @intFromBool(metadata.bracketed_paste),
        .bell_count = metadata.bell_count,
        .clipboard_write_seq = metadata.clipboard_write_seq,
        .clipboard_read_seq = metadata.clipboard_read_seq,
        .foreground_available_raw = @intFromBool(metadata.foreground_available),
        .foreground_pgid_present_raw = @intFromBool(metadata.foreground_pgid != null),
        .foreground_pgid = metadata.foreground_pgid orelse 0,
        .child_pid = metadata.child_pid,
        .host_pid = metadata.host_pid,
        .ssh_remote_dest_present_raw = @intFromBool(metadata.ssh_remote_dest != null),
        .process_count = metadata.process_count,
    };
    var destination: usize = 0;
    result.cwd = try stringRecipe(payload, metadata.cwd, &destination);
    result.window_title = try stringRecipe(payload, metadata.window_title, &destination);
    if (metadata.ssh_remote_dest) |span|
        result.ssh_remote_dest = try stringRecipe(payload, span, &destination);
    result.clipboard_read_target = try stringRecipe(
        payload,
        metadata.clipboard_read_target,
        &destination,
    );
    if (destination > protocol.max_control_json or destination > std.math.maxInt(u32))
        return error.ResourceExhausted;
    result.backing_bytes = @intCast(destination);

    for (metadata.foregroundProcesses(), 0..) |process, index| {
        if (process.name.decoded_len > max_process_name_bytes or
            process.name.decoded_len > std.math.maxInt(u8) or
            !runtime_event_wire.validateStringSpan(payload, process.name))
            return error.ResourceExhausted;
        result.processes[index] = .{
            .pid = process.pid,
            .name_len = @intCast(process.name.decoded_len),
            .name_digest = process.name.digest,
        };
    }
    if (!metadata.foreground_available and
        (result.foreground_pgid_present_raw != 0 or result.foreground_pgid != 0 or
            result.process_count != 0))
        return error.Malformed;
    return result;
}

fn stringRecipe(
    payload: []const u8,
    span: runtime_event_wire.StringSpan,
    destination: *usize,
) RecipeError!StringRecipe {
    if (!runtime_event_wire.validateStringSpan(payload, span)) return error.Malformed;
    if (destination.* > std.math.maxInt(u32) or span.decoded_len > std.math.maxInt(u32))
        return error.ResourceExhausted;
    const result: StringRecipe = .{
        .destination_start = @intCast(destination.*),
        .decoded_len = @intCast(span.decoded_len),
        .digest = span.digest,
    };
    destination.* = std.math.add(usize, destination.*, span.decoded_len) catch
        return error.ResourceExhausted;
    return result;
}

fn canonicalAccepted(payload: []const u8) ?runtime_event_wire.EventPreflight {
    return switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |value| value,
        else => null,
    };
}

fn validateFillPlan(
    recipe: *const MetadataPreparationRecipe,
    payload: []const u8,
    metadata: *const runtime_event_wire.MetadataView,
) FillError!void {
    if (recipe.semantic_state_raw > @intFromEnum(runtime_metadata_types.SemanticPrompt.command) or
        recipe.alt_active_raw > 1 or recipe.app_cursor_keys_raw > 1 or
        recipe.app_keypad_raw > 1 or recipe.kitty_flags_raw > std.math.maxInt(u5) or
        recipe.alternate_scroll_raw > 1 or recipe.mouse_tracking_raw > 1 or
        recipe.mouse_tracking_mode > 4 or recipe.bracketed_paste_raw > 1 or
        recipe.foreground_available_raw > 1 or recipe.foreground_pgid_present_raw > 1 or
        recipe.ssh_remote_dest_present_raw > 1)
        return error.Malformed;
    if (recipe.process_count > max_process_entries or
        recipe.process_count != metadata.process_count)
        return error.Malformed;
    // pid 둘은 범위 제약이 없으므로 **원본과 같은가**로만 본다 — recipe가 관측과 갈리면 seal이 무의미해진다.
    if (recipe.child_pid != metadata.child_pid or recipe.host_pid != metadata.host_pid)
        return error.Malformed;
    if (recipe.foreground_available_raw == 0 and
        (recipe.foreground_pgid_present_raw != 0 or recipe.foreground_pgid != 0 or
            recipe.process_count != 0))
        return error.Malformed;

    var destination: u32 = 0;
    try validateStringPlan(payload, metadata.cwd, recipe.cwd, &destination);
    try validateStringPlan(payload, metadata.window_title, recipe.window_title, &destination);
    if ((metadata.ssh_remote_dest != null) != (recipe.ssh_remote_dest_present_raw == 1))
        return error.Malformed;
    if (metadata.ssh_remote_dest) |span|
        try validateStringPlan(payload, span, recipe.ssh_remote_dest, &destination)
    else if (!std.meta.eql(recipe.ssh_remote_dest, StringRecipe{}))
        return error.Malformed;
    try validateStringPlan(
        payload,
        metadata.clipboard_read_target,
        recipe.clipboard_read_target,
        &destination,
    );
    if (destination != recipe.backing_bytes) return error.Malformed;

    for (metadata.foregroundProcesses(), 0..) |process, index| {
        const planned = recipe.processes[index];
        if (planned.pid != process.pid or planned.name_len != process.name.decoded_len or
            !std.mem.eql(u8, &planned.name_digest, &process.name.digest) or
            !runtime_event_wire.validateStringSpan(payload, process.name))
            return error.Malformed;
    }
    for (recipe.processes[recipe.process_count..]) |unused|
        if (!std.meta.eql(unused, ProcessRecipe{})) return error.Malformed;
}

fn validateStringPlan(
    payload: []const u8,
    span: runtime_event_wire.StringSpan,
    planned: StringRecipe,
    destination: *u32,
) FillError!void {
    if (!runtime_event_wire.validateStringSpan(payload, span) or
        planned.destination_start != destination.* or
        planned.decoded_len != span.decoded_len or
        !std.mem.eql(u8, &planned.digest, &span.digest))
        return error.Malformed;
    destination.* = std.math.add(u32, destination.*, planned.decoded_len) catch
        return error.Malformed;
}

fn decodeInto(
    payload: []const u8,
    span: runtime_event_wire.StringSpan,
    planned: StringRecipe,
    backing: []u8,
) FillError!void {
    const start: usize = planned.destination_start;
    const len: usize = planned.decoded_len;
    const end = std.math.add(usize, start, len) catch return error.Malformed;
    if (end > backing.len) return error.Malformed;
    runtime_event_wire.decodeStringExact(payload, span, backing[start..end]) catch
        return error.Malformed;
}

fn filledRange(recipe: StringRecipe) FilledRange {
    return .{ .start = recipe.destination_start, .len = recipe.decoded_len };
}

const ByteRange = struct {
    start: usize,
    end: usize,

    fn from(start: usize, len: usize) FillError!ByteRange {
        return .{
            .start = start,
            .end = std.math.add(usize, start, len) catch return error.DestinationOverlap,
        };
    }

    fn overlaps(a: ByteRange, b: ByteRange) bool {
        if (a.start == a.end or b.start == b.end) return false;
        return a.start < b.end and b.start < a.end;
    }
};

fn validateDestinationExtents(
    recipe: *const MetadataPreparationRecipe,
    payload: []const u8,
    backing: []u8,
    processes: *[max_process_entries]FilledProcess,
) FillError!void {
    const ranges = [_]ByteRange{
        try ByteRange.from(@intFromPtr(payload.ptr), payload.len),
        try ByteRange.from(@intFromPtr(recipe), @sizeOf(MetadataPreparationRecipe)),
        try ByteRange.from(@intFromPtr(backing.ptr), backing.len),
        try ByteRange.from(@intFromPtr(processes), @sizeOf(@TypeOf(processes.*))),
    };
    for (ranges, 0..) |range, index|
        for (ranges[index + 1 ..]) |other|
            if (range.overlaps(other)) return error.DestinationOverlap;
}

const test_identity: runtime_event_types.EventIdentity = .{ .runtime_id = 0xaa, .stream_id = 7 };
const test_authority: runtime_event_types.EventAuthorityView = .{
    .role = .controller,
    .generation = .{ .tracked = 3 },
};
const test_metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"\/repo\u002Fsrc","window_title":"work","ssh_remote_dest":"dev@example.test","semantic_state":1,"alt_active":false,"app_cursor_keys":true,"app_keypad":false,"kitty_flags":3,"alternate_scroll":true,"mouse_tracking":true,"mouse_tracking_mode":2,"bracketed_paste":true,"bell_count":11,"clipboard_write_seq":12,"clipboard_read_seq":13,"clipboard_read_target":"c","observer_generation":14,"title_generation":15,"cols":120,"rows":40,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"zsh"}]}}
;

fn testClassification(payload: []const u8) runtime_event_types.Classification {
    return runtime_event_types.classifyEventView(
        test_identity,
        test_authority,
        .{
            .expected_major = protocol.version_major,
            .metadata_support = .supported,
            .verdict = runtime_event_wire.preflightEvent(payload, .{}),
        },
        .{
            .major = protocol.version_major,
            .kind = .event,
            .stream_id = test_identity.stream_id,
            .request_id = 0,
            .flags = 0,
            .payload_len = @intCast(payload.len),
            .payload = payload,
        },
    );
}

fn testMetadataRecipe(recipe: *const EventPreparationRecipe) *const MetadataPreparationRecipe {
    return switch (recipe.*) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*metadata| metadata,
            else => unreachable,
        },
        .violation => unreachable,
    };
}

fn typeContainsForbidden(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .@"fn" => true,
        .array => |array| typeContainsForbidden(array.child),
        .optional => |optional| typeContainsForbidden(optional.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsForbidden(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsForbidden(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn expectExactFields(comptime fields: []const std.builtin.Type.StructField, comptime expected: anytype) !void {
    try std.testing.expectEqual(expected.len, fields.len);
    inline for (fields, expected) |field, wanted| {
        try std.testing.expectEqualStrings(wanted[0], field.name);
        try std.testing.expect(field.type == wanted[1]);
    }
}

fn expectExactUnionFields(comptime fields: []const std.builtin.Type.UnionField, comptime expected: anytype) !void {
    try std.testing.expectEqual(expected.len, fields.len);
    inline for (fields, expected) |field, wanted| {
        try std.testing.expectEqualStrings(wanted[0], field.name);
        try std.testing.expect(field.type == wanted[1]);
    }
}

test "C3-3b2b2 recipe projects all five accepted event arms" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(AcceptedPreparationTag.revoked));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(AcceptedPreparationTag.invalidated));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(AcceptedPreparationTag.resized));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(AcceptedPreparationTag.metadata));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(AcceptedPreparationTag.ended));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EventPreparationTag.accepted));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EventPreparationTag.violation));

    const cases = .{
        .{ "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}", .revoked },
        .{ "{\"event\":\"snapshot.invalidated\"}", .invalidated },
        .{ "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}", .resized },
        .{ test_metadata_payload, .metadata },
        .{ "{\"event\":\"runtime.ended\"}", .ended },
    };
    inline for (cases) |case| {
        const recipe = try buildEventPreparationRecipe(testClassification(case[0]), case[0]);
        const accepted = switch (recipe) {
            .accepted => |value| value,
            .violation => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case[1], std.meta.activeTag(accepted));
    }
}

test "C3-3b2b2 recipe preserves every closed violation arm without parsing payload" {
    const expectViolationRecipe = struct {
        fn run(violation: runtime_event_types.Violation) !void {
            const recipe = try buildEventPreparationRecipe(
                .{ .violation = violation },
                "not parsed for a closed violation",
            );
            try std.testing.expect(std.meta.eql(violation, recipe.violation));
        }
    }.run;
    inline for (std.meta.fields(runtime_event_types.FrameViolation)) |field|
        try expectViolationRecipe(.{ .frame = @enumFromInt(field.value) });
    inline for (std.meta.fields(runtime_event_types.IdentityViolation)) |field|
        try expectViolationRecipe(.{ .identity = @enumFromInt(field.value) });
    inline for (std.meta.fields(runtime_event_types.AuthorityViolation)) |field|
        try expectViolationRecipe(.{ .authority = @enumFromInt(field.value) });
    inline for (std.meta.fields(runtime_event_types.CapabilityViolation)) |field|
        try expectViolationRecipe(.{ .capability = @enumFromInt(field.value) });
    inline for (std.meta.fields(runtime_event_wire.ForeignKind)) |field|
        try expectViolationRecipe(.{ .foreign = @enumFromInt(field.value) });
    inline for (.{
        runtime_event_types.Violation.stale_preflight,
        runtime_event_types.Violation.unknown_event,
        runtime_event_types.Violation.malformed,
        runtime_event_types.Violation.resource_exhausted,
    }) |violation| try expectViolationRecipe(violation);
}

test "C3-3b2b2 metadata recipe is pointer free and records decoded destination layout" {
    try std.testing.expect(!typeContainsForbidden(EventPreparationRecipe));
    try std.testing.expect(!typeContainsForbidden(MetadataFillProjection));

    try expectExactFields(std.meta.fields(StringRecipe), .{
        .{ "destination_start", u32 }, .{ "decoded_len", u32 }, .{ "digest", Digest },
    });
    try expectExactFields(std.meta.fields(ProcessRecipe), .{
        .{ "pid", i32 }, .{ "name_len", u8 }, .{ "name_digest", Digest },
    });
    try expectExactFields(std.meta.fields(MetadataPreparationRecipe), .{
        .{ "payload_digest", Digest },                        .{ "semantic_digest", Digest },       .{ "backing_bytes", u32 },
        .{ "revision", u64 },                                 .{ "observer_generation", u64 },      .{ "title_generation", u32 },
        .{ "cols", u16 },                                     .{ "rows", u16 },                     .{ "semantic_state_raw", u8 },
        .{ "alt_active_raw", u8 },                            .{ "app_cursor_keys_raw", u8 },       .{ "app_keypad_raw", u8 },
        .{ "kitty_flags_raw", u8 },                           .{ "alternate_scroll_raw", u8 },      .{ "mouse_tracking_raw", u8 },
        .{ "mouse_tracking_mode", u8 },                       .{ "bracketed_paste_raw", u8 },       .{ "bell_count", u64 },
        .{ "clipboard_write_seq", u64 },                      .{ "clipboard_read_seq", u64 },       .{ "foreground_available_raw", u8 },
        .{ "foreground_pgid_present_raw", u8 },               .{ "foreground_pgid", i32 },          .{ "child_pid", i32 },
        .{ "host_pid", i32 },                                 .{ "cwd", StringRecipe },             .{ "window_title", StringRecipe },
        .{ "ssh_remote_dest_present_raw", u8 },               .{ "ssh_remote_dest", StringRecipe }, .{ "clipboard_read_target", StringRecipe },
        .{ "processes", [max_process_entries]ProcessRecipe }, .{ "process_count", u8 },
    });
    try expectExactUnionFields(std.meta.fields(AcceptedPreparationRecipe), .{
        .{ "revoked", u64 },                        .{ "invalidated", void }, .{ "resized", resize_wire.Event },
        .{ "metadata", MetadataPreparationRecipe }, .{ "ended", void },
    });
    try expectExactUnionFields(std.meta.fields(EventPreparationRecipe), .{
        .{ "accepted", AcceptedPreparationRecipe }, .{ "violation", runtime_event_types.Violation },
    });
    try expectExactFields(std.meta.fields(FilledRange), .{
        .{ "start", u32 }, .{ "len", u32 },
    });
    try expectExactFields(std.meta.fields(MetadataFillProjection), .{
        .{ "cwd", FilledRange },                   .{ "window_title", FilledRange },
        .{ "ssh_remote_dest_present_raw", u8 },    .{ "ssh_remote_dest", FilledRange },
        .{ "clipboard_read_target", FilledRange }, .{ "process_count", u8 },
    });
    const recipe = try buildEventPreparationRecipe(
        testClassification(test_metadata_payload),
        test_metadata_payload,
    );
    const metadata = testMetadataRecipe(&recipe);
    try std.testing.expectEqual(@as(u32, 9), metadata.cwd.decoded_len);
    try std.testing.expectEqual(@as(u32, 0), metadata.cwd.destination_start);
    try std.testing.expectEqual(@as(u32, 9), metadata.window_title.destination_start);
    try std.testing.expectEqual(@as(u32, 13), metadata.ssh_remote_dest.destination_start);
    try std.testing.expectEqual(@as(u32, 29), metadata.clipboard_read_target.destination_start);
    try std.testing.expectEqual(@as(u32, 30), metadata.backing_bytes);
}

test "C3-3b2b2 metadata fill decodes strings and process values into caller storage" {
    const classification = testClassification(test_metadata_payload);
    const recipe = try buildEventPreparationRecipe(classification, test_metadata_payload);
    var backing: [30]u8 = [_]u8{0xcc} ** 30;
    var processes = [_]FilledProcess{.{}} ** max_process_entries;
    const projection = try fillMetadataRecipe(
        testMetadataRecipe(&recipe),
        classification,
        test_metadata_payload,
        &backing,
        &processes,
    );
    try std.testing.expectEqualStrings("/repo/src", backing[projection.cwd.start..][0..projection.cwd.len]);
    try std.testing.expectEqualStrings("work", backing[projection.window_title.start..][0..projection.window_title.len]);
    try std.testing.expectEqualStrings("dev@example.test", backing[projection.ssh_remote_dest.start..][0..projection.ssh_remote_dest.len]);
    try std.testing.expectEqualStrings("c", backing[projection.clipboard_read_target.start..][0..projection.clipboard_read_target.len]);
    try std.testing.expectEqual(@as(i32, 77), processes[0].pid);
    try std.testing.expectEqualStrings("zsh", processes[0].slice());
}

test "C3-3b2b2 SSH absent and present-empty remain distinct canonical recipes" {
    const absent =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"","window_title":"","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":false,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const present_empty =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"","window_title":"","ssh_remote_dest":"","semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":false,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const absent_recipe = try buildEventPreparationRecipe(testClassification(absent), absent);
    const empty_recipe = try buildEventPreparationRecipe(testClassification(present_empty), present_empty);
    try std.testing.expectEqual(@as(u8, 0), testMetadataRecipe(&absent_recipe).ssh_remote_dest_present_raw);
    try std.testing.expectEqual(@as(u8, 1), testMetadataRecipe(&empty_recipe).ssh_remote_dest_present_raw);
    try std.testing.expect(!std.meta.eql(absent_recipe, empty_recipe));
}

test "C3-3b2b2 unavailable foreground canonicalizes pgid count and process tail" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"","window_title":"","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":false,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const recipe = try buildEventPreparationRecipe(testClassification(payload), payload);
    const metadata = testMetadataRecipe(&recipe);
    try std.testing.expectEqual(@as(u8, 0), metadata.foreground_available_raw);
    try std.testing.expectEqual(@as(i32, 0), metadata.foreground_pgid);
    try std.testing.expectEqual(@as(u8, 0), metadata.process_count);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&metadata.processes), 0));
}

test "C3-3b2b2 process name 128 is accepted and 129 is a resource violation before recipe fill" {
    const prefix = "{\"event\":\"runtime.metadata\",\"metadata_revision\":1,\"metadata\":{\"cwd\":\"\",\"window_title\":\"\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"";
    const suffix = "\"}]}}";
    const accepted_payload = prefix ++ ("x" ** 128) ++ suffix;
    const rejected_payload = prefix ++ ("x" ** 129) ++ suffix;
    const accepted = try buildEventPreparationRecipe(
        testClassification(accepted_payload),
        accepted_payload,
    );
    try std.testing.expectEqual(@as(u8, 128), testMetadataRecipe(&accepted).processes[0].name_len);
    var accepted_backing: [0]u8 = .{};
    var accepted_processes = [_]FilledProcess{.{}} ** max_process_entries;
    _ = try fillMetadataRecipe(
        testMetadataRecipe(&accepted),
        testClassification(accepted_payload),
        accepted_payload,
        &accepted_backing,
        &accepted_processes,
    );
    try std.testing.expectEqual(@as(u8, 128), accepted_processes[0].len);
    try std.testing.expectEqualStrings("x" ** 128, accepted_processes[0].slice());
    const rejected = try buildEventPreparationRecipe(
        testClassification(rejected_payload),
        rejected_payload,
    );
    try std.testing.expectEqual(.resource_exhausted, std.meta.activeTag(rejected.violation));

    const escaped_payload = prefix ++ ("\\u0078" ** 128) ++ suffix;
    const escaped = try buildEventPreparationRecipe(
        testClassification(escaped_payload),
        escaped_payload,
    );
    try std.testing.expectEqual(@as(u8, 128), testMetadataRecipe(&escaped).processes[0].name_len);
    const utf8_128_payload = prefix ++ ("é" ** 64) ++ suffix;
    const utf8_129_payload = prefix ++ ("é" ** 63) ++ "€" ++ suffix;
    const utf8_128 = try buildEventPreparationRecipe(
        testClassification(utf8_128_payload),
        utf8_128_payload,
    );
    try std.testing.expectEqual(@as(u8, 128), testMetadataRecipe(&utf8_128).processes[0].name_len);
    const utf8_129 = try buildEventPreparationRecipe(
        testClassification(utf8_129_payload),
        utf8_129_payload,
    );
    try std.testing.expectEqual(.resource_exhausted, std.meta.activeTag(utf8_129.violation));

    const process = "{\"pid\":7,\"name\":\"x\"}";
    const comma_process = process ++ ",";
    const count_prefix = "{\"event\":\"runtime.metadata\",\"metadata_revision\":1,\"metadata\":{\"cwd\":\"\",\"window_title\":\"\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[";
    const count_suffix = "]}}";
    const count_64_payload = count_prefix ++ (comma_process ** 63) ++ process ++ count_suffix;
    const count_65_payload = count_prefix ++ (comma_process ** 64) ++ process ++ count_suffix;
    const count_64 = try buildEventPreparationRecipe(
        testClassification(count_64_payload),
        count_64_payload,
    );
    try std.testing.expectEqual(@as(u8, 64), testMetadataRecipe(&count_64).process_count);
    const count_65 = try buildEventPreparationRecipe(
        testClassification(count_65_payload),
        count_65_payload,
    );
    try std.testing.expectEqual(.resource_exhausted, std.meta.activeTag(count_65.violation));
}

test "C3-3b2b2 accepted metadata cannot be paired with different payload bytes" {
    const classification = testClassification(test_metadata_payload);
    var mutated = test_metadata_payload.*;
    mutated[std.mem.indexOf(u8, &mutated, "work").?] = 'W';
    try std.testing.expectError(
        error.Malformed,
        buildEventPreparationRecipe(classification, &mutated),
    );

    // The final digest check is the only guard exercised after both scratch targets were filled.
    const PostCopyMutation = struct {
        payload: []u8,
        index: usize,

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.payload[self.index] ^= 1;
        }
    };
    var post_copy_payload = test_metadata_payload.*;
    const post_copy_classification = testClassification(&post_copy_payload);
    const post_copy_recipe = try buildEventPreparationRecipe(
        post_copy_classification,
        &post_copy_payload,
    );
    var post_copy_backing: [30]u8 = [_]u8{0xa5} ** 30;
    var post_copy_processes = [_]FilledProcess{.{}} ** max_process_entries;
    var mutation: PostCopyMutation = .{
        .payload = &post_copy_payload,
        .index = std.mem.indexOf(u8, &post_copy_payload, "metadata_revision\":9").? +
            "metadata_revision\":".len,
    };
    fill_post_copy_testing.hook = .{ .context = &mutation, .run = PostCopyMutation.run };
    defer fill_post_copy_testing.hook = null;
    try std.testing.expectError(
        error.Malformed,
        fillMetadataRecipe(
            testMetadataRecipe(&post_copy_recipe),
            post_copy_classification,
            &post_copy_payload,
            &post_copy_backing,
            &post_copy_processes,
        ),
    );
    try std.testing.expectEqualStrings("/repo/src", post_copy_backing[0..9]);
    try std.testing.expectEqualStrings("work", post_copy_backing[9..13]);
    try std.testing.expectEqualStrings("dev@example.test", post_copy_backing[13..29]);
    try std.testing.expectEqualStrings("c", post_copy_backing[29..30]);
    try std.testing.expectEqual(@as(i32, 77), post_copy_processes[0].pid);
    try std.testing.expectEqualStrings("zsh", post_copy_processes[0].slice());
}

test "C3-3b2b2 fill rejects wrong destination size before changing either scratch" {
    const classification = testClassification(test_metadata_payload);
    const recipe = try buildEventPreparationRecipe(classification, test_metadata_payload);
    var backing: [31]u8 = [_]u8{0xa5} ** 31;
    var processes = [_]FilledProcess{.{}} ** max_process_entries;
    const backing_before = backing;
    const processes_before = processes;
    try std.testing.expectError(
        error.DestinationMismatch,
        fillMetadataRecipe(
            testMetadataRecipe(&recipe),
            classification,
            test_metadata_payload,
            &backing,
            &processes,
        ),
    );
    try std.testing.expectEqualSlices(u8, &backing_before, &backing);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&processes_before), std.mem.asBytes(&processes));

    var mutable_payload align(@alignOf(FilledProcess)) = test_metadata_payload.*;
    const mutable_classification = testClassification(&mutable_payload);
    var mutable_recipe = try buildEventPreparationRecipe(mutable_classification, &mutable_payload);
    const metadata = switch (mutable_recipe) {
        .accepted => |*accepted| &accepted.metadata,
        .violation => unreachable,
    };
    var ordinary_backing: [30]u8 = [_]u8{0xa5} ** 30;
    var ordinary_processes = [_]FilledProcess{.{}} ** max_process_entries;

    const payload_backing = mutable_payload[0..30];
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, payload_backing, &ordinary_processes),
    );
    const recipe_backing = std.mem.asBytes(metadata)[0..30];
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, recipe_backing, &ordinary_processes),
    );
    const payload_processes: *[max_process_entries]FilledProcess = @ptrCast(@alignCast(&mutable_payload));
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, &ordinary_backing, payload_processes),
    );
    const recipe_processes: *[max_process_entries]FilledProcess = @ptrCast(@alignCast(metadata));
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, &ordinary_backing, recipe_processes),
    );
    const process_backing = std.mem.asBytes(&ordinary_processes)[0..30];
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, process_backing, &ordinary_processes),
    );

    const empty_payload =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"","window_title":"","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":false,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var mutable_empty align(@alignOf(FilledProcess)) = empty_payload.*;
    const empty_classification = testClassification(&mutable_empty);
    var empty_recipe = try buildEventPreparationRecipe(empty_classification, &mutable_empty);
    var no_backing: [0]u8 = .{};
    const empty_payload_processes: *[max_process_entries]FilledProcess = @ptrCast(@alignCast(&mutable_empty));
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(testMetadataRecipe(&empty_recipe), empty_classification, &mutable_empty, &no_backing, empty_payload_processes),
    );

    const fake_start = std.math.maxInt(usize) - 10;
    const overflowing: []u8 = @as([*]u8, @ptrFromInt(fake_start))[0..30];
    try std.testing.expectError(
        error.DestinationOverlap,
        fillMetadataRecipe(metadata, mutable_classification, &mutable_payload, overflowing, &ordinary_processes),
    );

    var adjacent: [test_metadata_payload.len + 30]u8 = undefined;
    @memcpy(adjacent[0..test_metadata_payload.len], test_metadata_payload);
    const adjacent_payload = adjacent[0..test_metadata_payload.len];
    const adjacent_backing = adjacent[test_metadata_payload.len..];
    const adjacent_classification = testClassification(adjacent_payload);
    var adjacent_recipe = try buildEventPreparationRecipe(adjacent_classification, adjacent_payload);
    _ = try fillMetadataRecipe(
        testMetadataRecipe(&adjacent_recipe),
        adjacent_classification,
        adjacent_payload,
        adjacent_backing,
        &ordinary_processes,
    );
}

test "C3-3b2b2 fill rejects noncanonical raw recipe state before changing scratch" {
    const classification = testClassification(test_metadata_payload);
    var recipe = try buildEventPreparationRecipe(classification, test_metadata_payload);
    const metadata = switch (recipe) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*value| value,
            else => unreachable,
        },
        .violation => unreachable,
    };
    metadata.alt_active_raw = 2;
    var backing: [30]u8 = [_]u8{0xa5} ** 30;
    var processes = [_]FilledProcess{.{}} ** max_process_entries;
    const backing_before = backing;
    const processes_before = processes;
    try std.testing.expectError(
        error.Malformed,
        fillMetadataRecipe(metadata, classification, test_metadata_payload, &backing, &processes),
    );
    try std.testing.expectEqualSlices(u8, &backing_before, &backing);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&processes_before), std.mem.asBytes(&processes));

    const Mutation = enum {
        semantic_state,
        bool_raw,
        kitty_flags,
        mouse_mode,
        presence,
        destination,
        process_tail,
        digest,
    };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var candidate = try buildEventPreparationRecipe(classification, test_metadata_payload);
        const candidate_metadata = switch (candidate) {
            .accepted => |*accepted| &accepted.metadata,
            .violation => unreachable,
        };
        switch (mutation) {
            .semantic_state => candidate_metadata.semantic_state_raw = 0xff,
            .bool_raw => candidate_metadata.app_cursor_keys_raw = 2,
            .kitty_flags => candidate_metadata.kitty_flags_raw = 32,
            .mouse_mode => candidate_metadata.mouse_tracking_mode = 5,
            .presence => candidate_metadata.ssh_remote_dest_present_raw = 2,
            .destination => candidate_metadata.cwd.destination_start = 1,
            .process_tail => candidate_metadata.processes[1].pid = 1,
            .digest => candidate_metadata.semantic_digest[0] ^= 1,
        }
        var candidate_backing: [30]u8 = [_]u8{0xa5} ** 30;
        var candidate_processes = [_]FilledProcess{.{}} ** max_process_entries;
        const candidate_backing_before = candidate_backing;
        const candidate_processes_before = candidate_processes;
        try std.testing.expectError(
            error.Malformed,
            fillMetadataRecipe(
                candidate_metadata,
                classification,
                test_metadata_payload,
                &candidate_backing,
                &candidate_processes,
            ),
        );
        try std.testing.expectEqualSlices(u8, &candidate_backing_before, &candidate_backing);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&candidate_processes_before),
            std.mem.asBytes(&candidate_processes),
        );
    }
}
