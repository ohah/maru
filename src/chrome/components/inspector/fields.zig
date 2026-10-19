//! Presentation rows keep the diagnostic key available to filtering without making
//! serialization syntax the UI. The exported JSON remains unchanged.
const std = @import("std");
const i18n = @import("../../../i18n.zig");
const metadata = @import("../../../inspector_metadata.zig");
pub const Row = struct { key: []const u8, label: []const u8, value: []const u8 = "", heading: bool = false, missing: bool = false, field_path: []const u8 = "", meaning: []const u8 = "", raw_value: []const u8 = "", info: metadata.Info = .{ .source = .session_model } };

fn humanize(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    const text = try a.dupe(u8, key);
    for (text, 0..) |*c, i| {
        if (c.* == '_') c.* = ' ' else if (i == 0 and c.* < 128) c.* = std.ascii.toUpper(c.*);
    }
    return text;
}
fn heading(key: []const u8) ?i18n.Key {
    const entries = .{
        .{ "surface_id", .inspector_session_section },  .{ "observation", .inspector_observation_section },
        .{ "remote", .inspector_location_section },     .{ "osc7_cwd", .inspector_osc_section },
        .{ "hook_cwd", .inspector_hook_section },       .{ "ssh_destination", .inspector_routing_section },
        .{ "availability", .inspector_screen_section }, .{ "semantic_prompt", .inspector_input_section },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    return null;
}
pub fn flatten(a: std.mem.Allocator, value: std.json.Value, prefix: []const u8, out: *std.ArrayList(Row)) !void {
    if (out.items.len >= 512) return;
    switch (value) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (prefix.len == 0) if (heading(entry.key_ptr.*)) |key| try out.append(a, .{ .key = "", .label = i18n.t(key), .heading = true });
                try flatten(a, entry.value_ptr.*, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, if (prefix.len > 0) "." else "", entry.key_ptr.* }), out);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                if (std.mem.eql(u8, prefix, "items") and item == .object) {
                    const event = item.object;
                    const kind = event.get("kind") orelse continue;
                    const origin = event.get("origin") orelse continue;
                    const observed = event.get("observed_ms") orelse continue;
                    const sequence = event.get("sequence") orelse continue;
                    const revision = event.get("revision") orelse continue;
                    if (kind != .string or origin != .string or observed != .integer or sequence != .integer or revision != .integer) continue;
                    try out.append(a, .{ .key = try std.fmt.allocPrint(a, "items[{d}]", .{i}), .label = try std.fmt.allocPrint(a, "#{d} · {d} ms", .{ sequence.integer, observed.integer }), .value = try std.fmt.allocPrint(a, "{s} · {s} · r{d}", .{ kind.string, origin.string, revision.integer }) });
                } else try flatten(a, item, try std.fmt.allocPrint(a, "{s}[{d}]", .{ prefix, i }), out);
            }
        },
        else => {
            const text = if (value == .string) value.string else try std.json.Stringify.valueAlloc(a, value, .{});
            try out.append(a, .{ .key = prefix, .label = try humanize(a, prefix), .value = text, .missing = value == .null or (value == .string and value.string.len == 0) });
        },
    }
}

const Spec = struct { path: []const u8, name: i18n.Key, meaning: i18n.Key };
const specs = [_]Spec{
    .{ .path = "overview.surface_id", .name = .inspector_name_overview_surface_id, .meaning = .inspector_meaning_overview_surface_id },
    .{ .path = "overview.runtime_id", .name = .inspector_name_overview_runtime_id, .meaning = .inspector_meaning_overview_runtime_id },
    .{ .path = "overview.window", .name = .inspector_name_overview_window, .meaning = .inspector_meaning_overview_window },
    .{ .path = "overview.tab", .name = .inspector_name_overview_tab, .meaning = .inspector_meaning_overview_tab },
    .{ .path = "overview.pane", .name = .inspector_name_overview_pane, .meaning = .inspector_meaning_overview_pane },
    .{ .path = "overview.title", .name = .inspector_name_overview_title, .meaning = .inspector_meaning_overview_title },
    .{ .path = "overview.backend", .name = .inspector_name_overview_backend, .meaning = .inspector_meaning_overview_backend },
    .{ .path = "overview.observation", .name = .inspector_name_overview_observation, .meaning = .inspector_meaning_overview_observation },
    .{ .path = "overview.observation_revision", .name = .inspector_name_overview_observation_revision, .meaning = .inspector_meaning_overview_observation_revision },
    .{ .path = "overview.observer_generation", .name = .inspector_name_overview_observer_generation, .meaning = .inspector_meaning_overview_observer_generation },
    .{ .path = "overview.sampled_at_ms", .name = .inspector_name_overview_sampled_at_ms, .meaning = .inspector_meaning_overview_sampled_at_ms },
    .{ .path = "overview.terminated", .name = .inspector_name_overview_terminated, .meaning = .inspector_meaning_overview_terminated },
    .{ .path = "path.remote", .name = .inspector_name_path_remote, .meaning = .inspector_meaning_path_remote },
    .{ .path = "path.selected_cwd", .name = .inspector_name_path_selected_cwd, .meaning = .inspector_meaning_path_selected_cwd },
    .{ .path = "path.source", .name = .inspector_name_path_source, .meaning = .inspector_meaning_path_source },
    .{ .path = "path.reason", .name = .inspector_name_path_reason, .meaning = .inspector_meaning_path_reason },
    .{ .path = "path.osc7_cwd", .name = .inspector_name_path_osc7_cwd, .meaning = .inspector_meaning_path_osc7_cwd },
    .{ .path = "path.osc7_host", .name = .inspector_name_path_osc7_host, .meaning = .inspector_meaning_path_osc7_host },
    .{ .path = "path.hook_cwd", .name = .inspector_name_path_hook_cwd, .meaning = .inspector_meaning_path_hook_cwd },
    .{ .path = "path.hook_host", .name = .inspector_name_path_hook_host, .meaning = .inspector_meaning_path_hook_host },
    .{ .path = "path.hook_age_ms", .name = .inspector_name_path_hook_age_ms, .meaning = .inspector_meaning_path_hook_age_ms },
    .{ .path = "path.hook_fresh", .name = .inspector_name_path_hook_fresh, .meaning = .inspector_meaning_path_hook_fresh },
    .{ .path = "path.hook_host_matches", .name = .inspector_name_path_hook_host_matches, .meaning = .inspector_meaning_path_hook_host_matches },
    .{ .path = "path.hook_slot", .name = .inspector_name_path_hook_slot, .meaning = .inspector_meaning_path_hook_slot },
    .{ .path = "path.ssh_destination", .name = .inspector_name_path_ssh_destination, .meaning = .inspector_meaning_path_ssh_destination },
    .{ .path = "path.scm_target", .name = .inspector_name_path_scm_target, .meaning = .inspector_meaning_path_scm_target },
    .{ .path = "path.scm_reason", .name = .inspector_name_path_scm_reason, .meaning = .inspector_meaning_path_scm_reason },
    .{ .path = "path.explorer_mode", .name = .inspector_name_path_explorer_mode, .meaning = .inspector_meaning_path_explorer_mode },
    .{ .path = "path.explorer_root", .name = .inspector_name_path_explorer_root, .meaning = .inspector_meaning_path_explorer_root },
    .{ .path = "path.explorer_destination", .name = .inspector_name_path_explorer_destination, .meaning = .inspector_meaning_path_explorer_destination },
    .{ .path = "path.explorer_rows_remote", .name = .inspector_name_path_explorer_rows_remote, .meaning = .inspector_meaning_path_explorer_rows_remote },
    .{ .path = "terminal.availability", .name = .inspector_name_terminal_availability, .meaning = .inspector_meaning_terminal_availability },
    .{ .path = "terminal.cols", .name = .inspector_name_terminal_cols, .meaning = .inspector_meaning_terminal_cols },
    .{ .path = "terminal.rows", .name = .inspector_name_terminal_rows, .meaning = .inspector_meaning_terminal_rows },
    .{ .path = "terminal.semantic_prompt", .name = .inspector_name_terminal_semantic_prompt, .meaning = .inspector_meaning_terminal_semantic_prompt },
    .{ .path = "terminal.alternate_screen", .name = .inspector_name_terminal_alternate_screen, .meaning = .inspector_meaning_terminal_alternate_screen },
    .{ .path = "terminal.application_cursor_keys", .name = .inspector_name_terminal_application_cursor_keys, .meaning = .inspector_meaning_terminal_application_cursor_keys },
    .{ .path = "terminal.application_keypad", .name = .inspector_name_terminal_application_keypad, .meaning = .inspector_meaning_terminal_application_keypad },
    .{ .path = "terminal.kitty_flags", .name = .inspector_name_terminal_kitty_flags, .meaning = .inspector_meaning_terminal_kitty_flags },
    .{ .path = "terminal.alternate_scroll", .name = .inspector_name_terminal_alternate_scroll, .meaning = .inspector_meaning_terminal_alternate_scroll },
    .{ .path = "terminal.mouse_tracking", .name = .inspector_name_terminal_mouse_tracking, .meaning = .inspector_meaning_terminal_mouse_tracking },
    .{ .path = "terminal.mouse_tracking_mode", .name = .inspector_name_terminal_mouse_tracking_mode, .meaning = .inspector_meaning_terminal_mouse_tracking_mode },
    .{ .path = "terminal.bracketed_paste", .name = .inspector_name_terminal_bracketed_paste, .meaning = .inspector_meaning_terminal_bracketed_paste },
    .{ .path = "terminal.foreground_available", .name = .inspector_name_terminal_foreground_available, .meaning = .inspector_meaning_terminal_foreground_available },
    .{ .path = "terminal.foreground_pgid", .name = .inspector_name_terminal_foreground_pgid, .meaning = .inspector_meaning_terminal_foreground_pgid },
    .{ .path = "terminal.cursor", .name = .inspector_name_terminal_cursor, .meaning = .inspector_meaning_terminal_cursor },
    .{ .path = "terminal.cursor.row", .name = .inspector_name_terminal_cursor_row, .meaning = .inspector_meaning_terminal_cursor_row },
    .{ .path = "terminal.cursor.col", .name = .inspector_name_terminal_cursor_col, .meaning = .inspector_meaning_terminal_cursor_col },
    .{ .path = "terminal.scroll_region", .name = .inspector_name_terminal_scroll_region, .meaning = .inspector_meaning_terminal_scroll_region },
    .{ .path = "terminal.scroll_region.top", .name = .inspector_name_terminal_scroll_region_top, .meaning = .inspector_meaning_terminal_scroll_region_top },
    .{ .path = "terminal.scroll_region.bottom", .name = .inspector_name_terminal_scroll_region_bottom, .meaning = .inspector_meaning_terminal_scroll_region_bottom },
    .{ .path = "terminal.core_detail_support", .name = .inspector_name_terminal_core_detail_support, .meaning = .inspector_meaning_terminal_core_detail_support },
    .{ .path = "events.capture", .name = .inspector_name_events_capture, .meaning = .inspector_meaning_events_capture },
    .{ .path = "events.protocol_support", .name = .inspector_name_events_protocol_support, .meaning = .inspector_meaning_events_protocol_support },
    .{ .path = "events.capacity", .name = .inspector_name_events_capacity, .meaning = .inspector_meaning_events_capacity },
    .{ .path = "events.evicted", .name = .inspector_name_events_evicted, .meaning = .inspector_meaning_events_evicted },
    .{ .path = "events.items", .name = .inspector_name_events_items, .meaning = .inspector_meaning_events_items },
};
fn specFor(path: []const u8) ?Spec {
    const stable = if (std.mem.startsWith(u8, path, "events.items[")) "events.items" else path;
    for (specs) |spec| if (std.mem.eql(u8, stable, spec.path)) return spec;
    return null;
}
/// Add context from the canonical shared metadata without changing the raw JSON.
pub fn decorate(a: std.mem.Allocator, root: std.json.Value, section: []const u8, rows: []Row) !void {
    for (rows) |*row| {
        if (row.heading or row.key.len == 0) continue;
        row.field_path = try std.fmt.allocPrint(a, "{s}.{s}", .{ section, row.key });
        row.raw_value = row.value;
        row.info = metadata.forField(root, row.field_path);
        if (specFor(row.field_path)) |spec| {
            // Event labels carry sequence and observation time. Share their
            // explanation without replacing the identity of each history row.
            if (!std.mem.startsWith(u8, row.field_path, "events.items[")) row.label = i18n.t(spec.name);
            row.meaning = i18n.t(spec.meaning);
        } else if (std.mem.startsWith(u8, row.field_path, "elements.")) {
            const suffix = row.key[(if (std.mem.indexOfScalar(u8, row.key, '.')) |dot| dot + 1 else 0)..];
            const names = .{ .{ "source", .inspector_ui_source }, .{ "id", .inspector_ui_id }, .{ "parent_id", .inspector_ui_parent_id }, .{ "generation", .inspector_ui_generation }, .{ "kind", .inspector_ui_kind }, .{ "role", .inspector_ui_role }, .{ "rect", .inspector_ui_rect }, .{ "visible_rect", .inspector_ui_visible_rect }, .{ "action_id", .inspector_ui_action_id }, .{ "enabled", .inspector_ui_enabled }, .{ "cursor", .inspector_ui_cursor } };
            inline for (names) |entry| if (std.mem.eql(u8, suffix, entry[0])) {
                row.label = i18n.t(entry[1]);
            };
            row.meaning = i18n.t(.inspector_ui_detail);
        } else row.meaning = row.field_path;
        if (row.info.availability != .available) {
            row.value = availabilityLabel(row.info.availability);
            row.missing = true;
        }
    }
}

test "inspector event explanation preserves sequence timestamp origin and revision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"field_info":{"events.items":{"availability":"available","source":"inspector_history","reason":"none"}},"events":{"items":[{"sequence":7,"observed_ms":42,"kind":"cwd_changed","origin":"sampled_metadata","revision":9}]}}
    , .{});
    var rows: std.ArrayList(Row) = .empty;
    try flatten(a, parsed.value.object.get("events").?, "", &rows);
    try decorate(a, parsed.value, "events", rows.items);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("#7 · 42 ms", rows.items[0].label);
    try std.testing.expectEqualStrings("cwd_changed · sampled_metadata · r9", rows.items[0].value);
    try std.testing.expect(rows.items[0].meaning.len > 0);
    try std.testing.expectEqual(.inspector_history, rows.items[0].info.source);
}

test "inspector field details retain literal null false and zero alongside collection state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"overview":{"backend":"in_process","runtime_id":null,"terminated":false,"sampled_at_ms":0}}
    , .{});
    var rows: std.ArrayList(Row) = .empty;
    try flatten(a, parsed.value.object.get("overview").?, "", &rows);
    try decorate(a, parsed.value, "overview", rows.items);
    var checked: usize = 0;
    for (rows.items) |row| {
        if (std.mem.eql(u8, row.key, "runtime_id")) {
            try std.testing.expectEqualStrings("null", row.raw_value);
            try std.testing.expectEqual(.not_applicable, row.info.availability);
            checked += 1;
        } else if (std.mem.eql(u8, row.key, "terminated") or std.mem.eql(u8, row.key, "sampled_at_ms")) {
            try std.testing.expectEqual(.available, row.info.availability);
            try std.testing.expect(!row.missing);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), checked);
}
pub fn availabilityLabel(value: metadata.Availability) []const u8 {
    return switch (value) {
        .available => i18n.t(.inspector_state_available),
        .not_applicable => i18n.t(.inspector_state_not_applicable),
        .not_collected => i18n.t(.inspector_state_not_collected),
        .unsupported => i18n.t(.inspector_state_unsupported),
        .unavailable => i18n.t(.inspector_state_unavailable),
    };
}
pub fn sourceLabel(value: metadata.Source) []const u8 {
    return switch (value) {
        .published_ui_tree => i18n.t(.inspector_src_ui_tree),
        .session_model => i18n.t(.inspector_src_session_model),
        .window_membership => i18n.t(.inspector_src_window_membership),
        .runtime_observation => i18n.t(.inspector_src_runtime_observation),
        .terminal_screen => i18n.t(.inspector_src_terminal_screen),
        .local_core => i18n.t(.inspector_src_local_core),
        .osc7 => i18n.t(.inspector_src_osc7),
        .agent_hook => i18n.t(.inspector_src_agent_hook),
        .kernel => i18n.t(.inspector_src_kernel),
        .scm_decision => i18n.t(.inspector_src_scm_decision),
        .explorer_state => i18n.t(.inspector_src_explorer_state),
        .inspector_history => i18n.t(.inspector_src_inspector_history),
        .sampling_policy => i18n.t(.inspector_src_sampling_policy),
    };
}
pub fn reasonLabel(value: metadata.Reason) []const u8 {
    return switch (value) {
        .none => i18n.t(.inspector_why_none),
        .no_session_host => i18n.t(.inspector_why_no_session_host),
        .window_unbound => i18n.t(.inspector_why_window_unbound),
        .local_terminal => i18n.t(.inspector_why_local_terminal),
        .no_shell_hook => i18n.t(.inspector_why_no_shell_hook),
        .no_observed_cwd => i18n.t(.inspector_why_no_observed_cwd),
        .host_omitted => i18n.t(.inspector_why_host_omitted),
        .no_ssh_destination => i18n.t(.inspector_why_no_ssh_destination),
        .host_transport_missing => i18n.t(.inspector_why_host_transport_missing),
        .observation_unavailable => i18n.t(.inspector_why_observation_unavailable),
        .foreground_unavailable => i18n.t(.inspector_why_foreground_unavailable),
        .detail_not_ready => i18n.t(.inspector_why_detail_not_ready),
        .not_captured => i18n.t(.inspector_why_not_captured),
    };
}

test "inspector UI field labels explain published node values without JSON prefixes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"elements":{"selected":{"source":"file_tree","id":7,"visible_rect":{"x":1,"y":2,"width":3,"height":4}}}}
    , .{});
    var rows = [_]Row{
        .{ .key = "selected.source", .label = "selected.source", .value = "file_tree" },
        .{ .key = "selected.id", .label = "selected.id", .value = "7" },
        .{ .key = "selected.visible_rect", .label = "selected.visible_rect", .value = "3 x 4" },
    };
    try decorate(arena.allocator(), root.value, "elements", &rows);
    try std.testing.expectEqualStrings(i18n.t(.inspector_ui_source), rows[0].label);
    try std.testing.expectEqualStrings(i18n.t(.inspector_ui_id), rows[1].label);
    try std.testing.expectEqualStrings(i18n.t(.inspector_ui_visible_rect), rows[2].label);
    for (rows) |row| {
        try std.testing.expectEqual(metadata.Source.published_ui_tree, row.info.source);
        try std.testing.expectEqual(metadata.Availability.available, row.info.availability);
        try std.testing.expectEqualStrings(i18n.t(.inspector_ui_detail), row.meaning);
    }
}
