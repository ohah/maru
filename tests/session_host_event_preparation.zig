//! C3-3b2b2 pure event-preparation recipe contract.
//!
//! These tests deliberately stop before pending-owner publication. They pin the allocation-free,
//! pointer-free projection and caller-owned fill seam that both the compatibility adapter and the
//! later generation-event preparation path must share.

const std = @import("std");
const prep = @import("runtime_event_preparation");
const event_types = @import("runtime_event_types");
const event_wire = @import("runtime_event_wire");

const identity: event_types.EventIdentity = .{ .runtime_id = 0xaa, .stream_id = 7 };
const controller: event_types.EventAuthorityView = .{
    .role = .controller,
    .generation = .{ .tracked = 3 },
};

const metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"\/repo\u002Fsrc","window_title":"work","ssh_remote_dest":"dev@example.test","semantic_state":1,"alt_active":false,"app_cursor_keys":true,"app_keypad":false,"kitty_flags":3,"alternate_scroll":true,"mouse_tracking":true,"mouse_tracking_mode":2,"bracketed_paste":true,"bell_count":11,"clipboard_write_seq":12,"clipboard_read_seq":13,"clipboard_read_target":"c","observer_generation":14,"title_generation":15,"cols":120,"rows":40,"foreground_available":true,"foreground_pgid":77,"processes":[{"pid":77,"name":"zsh"}]}}
;

fn classify(payload: []const u8) event_types.Classification {
    return event_types.classifyEventView(
        identity,
        controller,
        .{
            .expected_major = 1,
            .metadata_support = .supported,
            .verdict = event_wire.preflightEvent(payload, .{}),
        },
        .{
            .major = 1,
            .kind = .event,
            .stream_id = identity.stream_id,
            .request_id = 0,
            .flags = 0,
            .payload_len = @intCast(payload.len),
            .payload = payload,
        },
    );
}

fn metadataRecipe(recipe: *const prep.EventPreparationRecipe) *const prep.MetadataPreparationRecipe {
    return switch (recipe.*) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*metadata| metadata,
            else => unreachable,
        },
        .violation => unreachable,
    };
}

fn typeContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| typeContainsPointer(array.child),
        .optional => |optional| typeContainsPointer(optional.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "C3-3b2b2 recipe projects all five accepted event arms" {
    const cases = .{
        .{ "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}", .revoked },
        .{ "{\"event\":\"snapshot.invalidated\"}", .invalidated },
        .{ "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}", .resized },
        .{ metadata_payload, .metadata },
        .{ "{\"event\":\"runtime.ended\"}", .ended },
    };
    inline for (cases) |case| {
        const recipe = try prep.buildEventPreparationRecipe(classify(case[0]), case[0]);
        const accepted = switch (recipe) {
            .accepted => |value| value,
            .violation => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case[1], std.meta.activeTag(accepted));
    }
}

test "C3-3b2b2 recipe preserves every closed violation arm without parsing payload" {
    const violations = [_]event_types.Violation{
        .{ .frame = .major_mismatch },
        .{ .identity = .zero_runtime },
        .{ .authority = .revoked_observer },
        .{ .capability = .metadata_unsupported },
        .stale_preflight,
        .unknown_event,
        .{ .foreign = .stream },
        .malformed,
        .resource_exhausted,
    };
    for (violations) |violation| {
        const recipe = try prep.buildEventPreparationRecipe(
            .{ .violation = violation },
            "not parsed for a closed violation",
        );
        const actual = switch (recipe) {
            .violation => |value| value,
            .accepted => return error.TestUnexpectedResult,
        };
        try std.testing.expect(std.meta.eql(violation, actual));
    }
}

test "C3-3b2b2 metadata recipe is pointer free and records decoded destination layout" {
    try std.testing.expect(!typeContainsPointer(prep.EventPreparationRecipe));
    try std.testing.expect(!typeContainsPointer(prep.MetadataFillProjection));

    const recipe = try prep.buildEventPreparationRecipe(classify(metadata_payload), metadata_payload);
    const metadata = metadataRecipe(&recipe);
    try std.testing.expectEqual(@as(u32, 9), metadata.cwd.decoded_len);
    try std.testing.expectEqual(@as(u32, 0), metadata.cwd.destination_start);
    try std.testing.expectEqual(@as(u32, 9), metadata.window_title.destination_start);
    try std.testing.expectEqual(@as(u32, 13), metadata.ssh_remote_dest.destination_start);
    try std.testing.expectEqual(@as(u32, 29), metadata.clipboard_read_target.destination_start);
    try std.testing.expectEqual(@as(u32, 30), metadata.backing_bytes);
}

test "C3-3b2b2 metadata fill decodes strings and process values into caller storage" {
    const classification = classify(metadata_payload);
    const recipe = try prep.buildEventPreparationRecipe(classification, metadata_payload);
    const metadata = metadataRecipe(&recipe);
    var backing: [30]u8 = [_]u8{0xcc} ** 30;
    var processes = [_]prep.FilledProcess{.{}} ** prep.max_process_entries;
    const projection = try prep.fillMetadataRecipe(
        metadata,
        classification,
        metadata_payload,
        &backing,
        &processes,
    );
    try std.testing.expectEqualStrings("/repo/src", backing[projection.cwd.start..][0..projection.cwd.len]);
    try std.testing.expectEqualStrings("work", backing[projection.window_title.start..][0..projection.window_title.len]);
    try std.testing.expectEqualStrings("dev@example.test", backing[projection.ssh_remote_dest.start..][0..projection.ssh_remote_dest.len]);
    try std.testing.expectEqualStrings("c", backing[projection.clipboard_read_target.start..][0..projection.clipboard_read_target.len]);
    try std.testing.expectEqual(@as(u8, 1), projection.process_count);
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
    const absent_recipe = try prep.buildEventPreparationRecipe(classify(absent), absent);
    const empty_recipe = try prep.buildEventPreparationRecipe(classify(present_empty), present_empty);
    try std.testing.expectEqual(@as(u8, 0), metadataRecipe(&absent_recipe).ssh_remote_dest_present_raw);
    try std.testing.expectEqual(@as(u8, 1), metadataRecipe(&empty_recipe).ssh_remote_dest_present_raw);
    try std.testing.expect(!std.meta.eql(absent_recipe, empty_recipe));
}

test "C3-3b2b2 unavailable foreground canonicalizes pgid count and process tail" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"","window_title":"","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":false,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const recipe = try prep.buildEventPreparationRecipe(classify(payload), payload);
    const metadata = metadataRecipe(&recipe);
    try std.testing.expectEqual(@as(u8, 0), metadata.foreground_available_raw);
    try std.testing.expectEqual(@as(u8, 0), metadata.foreground_pgid_present_raw);
    try std.testing.expectEqual(@as(i32, 0), metadata.foreground_pgid);
    try std.testing.expectEqual(@as(u8, 0), metadata.process_count);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&metadata.processes), 0));
}

test "C3-3b2b2 process name 128 is accepted and 129 is a resource violation before recipe fill" {
    const prefix =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":1,\"metadata\":{\"cwd\":\"\",\"window_title\":\"\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":false,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"";
    const suffix = "\"}]}}";
    const accepted_payload = prefix ++ ("x" ** 128) ++ suffix;
    const rejected_payload = prefix ++ ("x" ** 129) ++ suffix;

    const accepted_recipe = try prep.buildEventPreparationRecipe(classify(accepted_payload), accepted_payload);
    try std.testing.expectEqual(@as(u8, 128), metadataRecipe(&accepted_recipe).processes[0].name_len);

    const rejected_recipe = try prep.buildEventPreparationRecipe(classify(rejected_payload), rejected_payload);
    const violation = switch (rejected_recipe) {
        .violation => |value| value,
        .accepted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(.resource_exhausted, std.meta.activeTag(violation));
}

test "C3-3b2b2 accepted metadata cannot be paired with different payload bytes" {
    const classification = classify(metadata_payload);
    var mutated = metadata_payload.*;
    mutated[std.mem.indexOf(u8, &mutated, "work").?] = 'W';
    try std.testing.expectError(
        error.Malformed,
        prep.buildEventPreparationRecipe(classification, &mutated),
    );
}

test "C3-3b2b2 fill rejects wrong destination size before changing either scratch" {
    const classification = classify(metadata_payload);
    const recipe = try prep.buildEventPreparationRecipe(classification, metadata_payload);
    const metadata = metadataRecipe(&recipe);
    var backing: [31]u8 = [_]u8{0xa5} ** 31;
    var processes = [_]prep.FilledProcess{.{ .pid = -1, .len = 1, .bytes = [_]u8{0x5a} ** prep.max_process_name_bytes }} ** prep.max_process_entries;
    const backing_before = backing;
    const processes_before = processes;
    try std.testing.expectError(
        error.DestinationMismatch,
        prep.fillMetadataRecipe(metadata, classification, metadata_payload, &backing, &processes),
    );
    try std.testing.expectEqualSlices(u8, &backing_before, &backing);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&processes_before), std.mem.asBytes(&processes));
}

test "C3-3b2b2 fill rejects noncanonical raw recipe state before changing scratch" {
    const classification = classify(metadata_payload);
    var recipe = try prep.buildEventPreparationRecipe(classification, metadata_payload);
    var metadata = switch (recipe) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*value| value,
            else => unreachable,
        },
        .violation => unreachable,
    };
    metadata.alt_active_raw = 2;
    var backing: [30]u8 = [_]u8{0xa5} ** 30;
    var processes = [_]prep.FilledProcess{.{}} ** prep.max_process_entries;
    const backing_before = backing;
    const processes_before = processes;
    try std.testing.expectError(
        error.Malformed,
        prep.fillMetadataRecipe(metadata, classification, metadata_payload, &backing, &processes),
    );
    try std.testing.expectEqualSlices(u8, &backing_before, &backing);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&processes_before), std.mem.asBytes(&processes));
}
