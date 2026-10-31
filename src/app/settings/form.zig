//! Schema rows and stable edit requests for a settings host. The host validates,
//! persists and applies requests; no native window or filesystem is used here.
const std = @import("std");
const maru = @import("../../maru.zig");
const config = maru.config;
const widget = maru.chrome.components.settings;
const model = @import("model.zig");
const editing = @import("edit.zig");

pub const Frame = struct {
    sections: []const []const u8,
    rows: []const widget.FieldRow,
    keys: []const []const u8,
    dropdown: []const []const u8,
    /// Keep storage tokens separate from self-language display names.
    dropdown_labels: ?[]const []const u8 = null,
    pub fn displayDropdown(self: Frame) []const []const u8 {
        return self.dropdown_labels orelse self.dropdown;
    }
    pub fn key(self: Frame, index: usize) ?[]const u8 {
        return if (index < self.keys.len) self.keys[index] else null;
    }
};
pub const Result = struct { request: ?editing.Request = null, finish: bool = false };
pub const Form = struct {
    state: widget.State = .{},
    edit: editing.Edit = .{},

    pub fn frame(self: *Form, a: std.mem.Allocator, cfg: config.Config) !Frame {
        var bools: std.ArrayList(config.schema.BoolField) = .empty;
        var nums: std.ArrayList(config.schema.NumberField) = .empty;
        var enums: std.ArrayList(config.schema.EnumField) = .empty;
        var texts: std.ArrayList(config.schema.TextField) = .empty;
        var colors: std.ArrayList(config.schema.ColorField) = .empty;
        try config.schema.appendBoolFields(a, cfg, &bools);
        try config.schema.appendNumberFields(a, cfg, &nums);
        try config.schema.appendEnumFields(a, cfg, &enums);
        try config.schema.appendTextFields(a, cfg, &texts);
        try config.schema.appendColorFields(a, cfg, &colors);
        var labels: std.ArrayList([]const u8) = .empty;
        var sections: std.ArrayList(?config.Section) = .empty;
        inline for (@import("type_info_fields").enumFields(config.Section)) |field| {
            const sec: config.Section = @fromBackingInt(@intCast(field.value));
            if (model.settingsSectionHasField(bools.items, nums.items, enums.items, texts.items, colors.items, sec)) {
                try sections.append(a, sec);
                try labels.append(a, model.settingsSectionLabel(sec));
            }
        }
        if (model.settingsSectionHasField(bools.items, nums.items, enums.items, texts.items, colors.items, null)) {
            try sections.append(a, null);
            try labels.append(a, model.settingsSectionLabel(null));
        }
        self.state.section = @min(self.state.section, sections.items.len -| 1);
        const selected_section = if (sections.items.len > 0) sections.items[self.state.section] else null;
        var rows: std.ArrayList(widget.FieldRow) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        const query = self.state.searchQuery();
        // A single append owns both sequences: pointer rendering and edit dispatch
        // must never independently rebuild the selected row's key.
        for (bools.items) |field| if (matches(field, selected_section, query)) {
            try append(a, &rows, &keys, field.key, try label(a, field, query), .{ .toggle = field.value });
        };
        for (nums.items) |field| if (matches(field, selected_section, query)) {
            try append(a, &rows, &keys, field.key, try label(a, field, query), .{ .number = .{ .value = field.value, .min = field.min, .max = field.max } });
        };
        for (enums.items) |field| if (matches(field, selected_section, query)) {
            try append(a, &rows, &keys, field.key, try label(a, field, query), .{ .dropdown = if (std.mem.eql(u8, field.key, "ui.language")) maru.i18n.preferenceLabel(cfg.ui_language) else field.current });
        };
        for (texts.items) |field| if (matches(field, selected_section, query)) {
            try append(a, &rows, &keys, field.key, try label(a, field, query), .{ .text = field.value });
        };
        for (colors.items) |field| if (matches(field, selected_section, query)) {
            const rgb = config.appearance.parseHexColor(field.value) catch (config.appearance.parseHexColor("#808080") catch unreachable);
            try append(a, &rows, &keys, field.key, try label(a, field, query), .{ .color = .{ .hex = field.value, .rgb = rgb } });
        };
        self.state.setFieldCount(rows.items.len);
        const variants = if (self.state.dropdown.open and self.state.selected < keys.items.len)
            (try config.schema.enumVariants(a, cfg, keys.items[self.state.selected])) orelse &.{}
        else
            &.{};
        const language_variants = if (self.state.dropdown.open and self.state.selected < keys.items.len and std.mem.eql(u8, keys.items[self.state.selected], "ui.language")) blk: {
            const shown = try a.alloc([]const u8, variants.len);
            for (variants, 0..) |value, index| {
                const preference = std.meta.stringToEnum(maru.i18n.Preference, value) orelse return error.InvalidEnum;
                shown[index] = maru.i18n.preferenceLabel(preference);
            }
            break :blk shown;
        } else null;
        return .{ .sections = labels.items, .rows = rows.items, .keys = keys.items, .dropdown = variants, .dropdown_labels = language_variants };
    }

    pub fn action(self: *Form, a: std.mem.Allocator, cfg: config.Config, f: Frame, intent: widget.Action) !Result {
        switch (intent) {
            .dropdown_cancel, .close => return .{ .request = self.edit.rollback(), .finish = true },
            .dropdown_preview, .dropdown_accept => {
                const key = f.key(self.state.selected) orelse return .{};
                if (self.state.dropdown.selected >= f.dropdown.len) return .{};
                const commit = intent == .dropdown_accept;
                return .{ .request = try self.edit.request(key, f.dropdown[self.state.dropdown.selected], commit), .finish = commit };
            },
            .text_commit => {
                const key = f.key(self.state.selected) orelse return .{};
                return .{ .request = try self.edit.request(key, self.state.editText(), true), .finish = true };
            },
            .toggle => {
                const key = f.key(self.state.selected) orelse return .{};
                const row = f.rows[self.state.selected];
                const value = switch (row.kind) {
                    .toggle => |v| if (v) "true" else "false",
                    .number => |v| try widget.formatNumberValue(a, v.value),
                    .dropdown => |v| if (std.mem.eql(u8, key, "ui.language")) @tagName(cfg.ui_language) else v,
                    .text, .font => |v| v,
                    .color => |v| v.hex,
                    else => return .{},
                };
                if (row.kind != .toggle and row.kind != .dropdown and !self.state.editFits(value)) return error.TextTooLong;
                if (self.edit.active) {
                    if (!std.mem.eql(u8, key, self.edit.key.slice())) return error.EditInProgress;
                } else try self.edit.begin(key, value);
                switch (row.kind) {
                    .toggle => |v| return .{ .request = try self.edit.request(key, if (v) "false" else "true", true), .finish = true },
                    .dropdown => {
                        const variants = (try config.schema.enumVariants(a, cfg, key)) orelse return error.InvalidEnum;
                        self.state.dropdown.show(variants.len, config.schema.enumIndex(cfg, key) orelse 0);
                    },
                    else => self.state.enterEdit(value),
                }
            },
            .selection_changed, .search_changed, .section_changed => {
                // Moving text ownership away retires the old transaction too;
                // otherwise the next field would inherit an EditInProgress lock.
                if (!self.state.editing and !self.state.dropdown.open and self.edit.active)
                    return .{ .request = self.edit.rollback(), .finish = true };
            },
            else => {},
        }
        return .{};
    }
    pub fn complete(self: *Form, request: editing.Request, finish: bool, succeeded: bool) void {
        if (request.generation != self.edit.generation) return;
        self.edit.finish(request.generation, finish and succeeded);
        if (finish and succeeded) {
            self.state.cancelEdit();
            self.state.dropdown.hide();
        }
    }
};
fn matches(field: anytype, section: ?config.Section, query: []const u8) bool {
    return (query.len > 0 or field.section == section) and model.settingsRowMatches(field.doc_key, field.doc, field.key, query);
}
fn label(a: std.mem.Allocator, field: anytype, query: []const u8) ![]const u8 {
    return model.settingsRowLabel(a, query.len > 0, field.section, if (field.doc.len > 0) field.doc else field.key);
}
fn append(a: std.mem.Allocator, rows: *std.ArrayList(widget.FieldRow), keys: *std.ArrayList([]const u8), key: []const u8, text: []const u8, kind: widget.FieldRow.Kind) !void {
    try rows.append(a, .{ .label = text, .kind = kind });
    try keys.append(a, key);
}

fn setTestQuery(form: *Form, value: []const u8) void {
    form.state.startSearch();
    for (value) |cp| form.state.appendSearchCp(cp);
}
test "Settings form filtered rows keep their config key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var form: Form = .{};
    setTestQuery(&form, "font.size");
    const f = try form.frame(arena.allocator(), .{});
    try std.testing.expectEqual(@as(usize, 1), f.rows.len);
    try std.testing.expectEqualStrings("font.size", f.key(0).?);
    try std.testing.expect(f.rows[0].kind == .number);
    try std.testing.expect(f.key(1) == null);
}
test "Settings form clamps stale navigation and empty filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var form: Form = .{};
    form.state.section = std.math.maxInt(usize);
    setTestQuery(&form, "missing-setting-xyzzy");
    const f = try form.frame(arena.allocator(), .{});
    try std.testing.expect(form.state.section < f.sections.len);
    try std.testing.expectEqual(@as(usize, 0), form.state.count);
    const result = try form.action(arena.allocator(), .{}, f, .toggle);
    try std.testing.expect(result.request == null);
}
test "Settings form commit cannot retarget after filter change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "font.size");
    const old = try form.frame(a, .{});
    _ = try form.action(a, .{}, old, .toggle);
    form.state.endSearch();
    setTestQuery(&form, "font.family");
    const changed = try form.frame(a, .{});
    try std.testing.expectEqualStrings("font.family", changed.key(0).?);
    const result = try form.action(a, .{}, changed, .text_commit);
    try std.testing.expect(result.request == null);
}
test "Settings form cancellation restores the original key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "font.size");
    const f = try form.frame(a, .{});
    _ = try form.action(a, .{}, f, .toggle);
    const result = try form.action(a, .{}, f, .close);
    try std.testing.expect(result.finish);
    try std.testing.expectEqualStrings("font.size", result.request.?.key.slice());
    try std.testing.expect(!result.request.?.persist);
}

test "Settings form search and section focus changes retire the old edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]widget.Action{ .search_changed, .section_changed }) |intent| {
        var form: Form = .{};
        setTestQuery(&form, "font.size");
        const f = try form.frame(a, .{});
        _ = try form.action(a, .{}, f, .toggle);
        if (intent == .search_changed) form.state.startSearch() else form.state.selectSection(0);
        const result = try form.action(a, .{}, f, intent);
        try std.testing.expect(result.finish);
        try std.testing.expectEqualStrings("font.size", result.request.?.key.slice());
        try std.testing.expect(!result.request.?.persist);
        form.complete(result.request.?, result.finish, true);
        try std.testing.expect(!form.edit.active);
    }
}
test "Settings form stale completion cannot close the new editor" {
    var form: Form = .{};
    try form.edit.begin("font.size", "14");
    const old = (try form.edit.request("font.size", "16", true)).?;
    form.edit.finish(old.generation, true);
    try form.edit.begin("font.family", "Cascadia Mono");
    form.state.enterEdit("Cascadia Mono");
    form.complete(old, true, true);
    try std.testing.expect(form.state.editing);
    try std.testing.expect(form.edit.active);
}

test "Settings form retries a failed boolean write without dropping its original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "input.paste-protection");
    const f = try form.frame(a, .{});
    const first = try form.action(a, .{}, f, .toggle);
    form.complete(first.request.?, true, false);
    const retry = try form.action(a, .{}, f, .toggle);
    try std.testing.expectEqual(first.request.?.generation, retry.request.?.generation);
    try std.testing.expectEqualStrings(first.request.?.value.slice(), retry.request.?.value.slice());
    try std.testing.expect(form.edit.active);
}

test "Settings form language selected label uses its own language without changing the config" {
    const old = maru.i18n.lang();
    defer maru.i18n.setLang(old);
    maru.i18n.setLang(.en);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var form: Form = .{};
    setTestQuery(&form, "ui.language");
    const cfg: config.Config = .{ .ui_language = .ko };
    const f = try form.frame(arena.allocator(), cfg);
    try std.testing.expectEqualStrings("ui.language", f.keys[0]);
    try std.testing.expectEqualStrings("한국어", f.rows[0].kind.dropdown);
    try std.testing.expectEqual(maru.i18n.Preference.ko, cfg.ui_language);
}
test "Settings form language popup separates canonical values from display names" {
    const old = maru.i18n.lang();
    defer maru.i18n.setLang(old);
    maru.i18n.setLang(.en);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "ui.language");
    const cfg: config.Config = .{ .ui_language = .en };
    _ = try form.action(a, cfg, try form.frame(a, cfg), .toggle);
    const f = try form.frame(a, cfg);
    try std.testing.expectEqualStrings("auto", f.dropdown[0]);
    try std.testing.expectEqualStrings("en", f.dropdown[1]);
    try std.testing.expectEqualStrings("ko", f.dropdown[2]);
    try std.testing.expectEqualStrings("English", f.displayDropdown()[1]);
    try std.testing.expectEqualStrings("한국어", f.displayDropdown()[2]);
}
test "Settings form language accept persists a token rather than its label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "ui.language");
    const cfg: config.Config = .{ .ui_language = .en };
    _ = try form.action(a, cfg, try form.frame(a, cfg), .toggle);
    form.state.dropdown.selected = 2;
    const result = try form.action(a, cfg, try form.frame(a, cfg), .dropdown_accept);
    try std.testing.expectEqualStrings("ko", result.request.?.value.slice());
    try std.testing.expect(result.request.?.persist and result.finish);
}
test "Settings form language cancel restores auto token after preview even with a translated label" {
    const old = maru.i18n.lang();
    defer maru.i18n.setLang(old);
    maru.i18n.setLang(.ko);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "ui.language");
    var cfg: config.Config = .{ .ui_language = .auto };
    _ = try form.action(a, cfg, try form.frame(a, cfg), .toggle);
    form.state.dropdown.selected = 1;
    const preview = try form.action(a, cfg, try form.frame(a, cfg), .dropdown_preview);
    try std.testing.expectEqualStrings("en", preview.request.?.value.slice());
    form.complete(preview.request.?, false, true);
    cfg.ui_language = .en;
    const cancel = try form.action(a, cfg, try form.frame(a, cfg), .dropdown_cancel);
    try std.testing.expectEqualStrings("auto", cancel.request.?.value.slice());
    try std.testing.expect(!cancel.request.?.persist and cancel.finish);
}
test "Settings form other enums keep their original values and display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var form: Form = .{};
    setTestQuery(&form, "cursor.shape");
    const cfg: config.Config = .{};
    _ = try form.action(a, cfg, try form.frame(a, cfg), .toggle);
    const f = try form.frame(a, cfg);
    try std.testing.expect(f.dropdown_labels == null);
    try std.testing.expectEqualStrings("bar", f.displayDropdown()[1]);
    form.state.dropdown.selected = 2;
    const result = try form.action(a, cfg, f, .dropdown_accept);
    try std.testing.expectEqualStrings("underline", result.request.?.value.slice());
}
