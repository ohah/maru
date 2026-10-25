//! Shared settings search and section vocabulary. Native hosts own persistence
//! and live application; the model never reaches into a platform session.
const std = @import("std");
const maru = @import("../../maru.zig");
const config_mod = maru.config;

pub fn settingsRowMatches(doc_key: ?maru.i18n.Key, label: []const u8, key: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (std.ascii.findIgnoreCase(key, query) != null) return true;
    // 키가 있으면 **모든 언어**를 본다. 없으면(환경변수 이름·chord 표기처럼 번역 대상이 아닌 라벨) 그 라벨
    // 하나만 보는데, 그런 라벨은 애초에 언어를 안 타므로 판정도 언어 독립이다.
    if (doc_key) |dk| {
        inline for (@import("type_info_fields").enumFields(maru.i18n.Lang)) |lf| {
            const sentence = maru.i18n.tIn(@field(maru.i18n.Lang, lf.name), dk);
            if (std.ascii.findIgnoreCase(sentence, query) != null) return true;
        }
        return false;
    }
    return std.ascii.findIgnoreCase(label, query) != null;
}

pub fn settingsSectionLabel(sec: ?config_mod.Section) []const u8 {
    const s = sec orelse return maru.i18n.t(.set_section_other);
    return maru.i18n.t(switch (s) {
        .app => .set_section_app,
        .font => .set_section_font,
        .theme => .set_section_theme,
        .cursor => .set_section_cursor,
        .window => .set_section_window,
        .input => .set_section_input,
        .terminal => .set_section_terminal,
        .workspace => .set_section_workspace,
        .quick_terminal => .set_section_quick_terminal,
        .sidebar => .set_section_sidebar,
        .global_hotkey => .set_section_global_hotkey,
        .editor => .set_section_editor,
    });
}

pub fn settingsSectionHasField(bools: []const config_mod.schema.BoolField, nums: []const config_mod.schema.NumberField, enums: []const config_mod.schema.EnumField, texts: []const config_mod.schema.TextField, colors: []const config_mod.schema.ColorField, sec: ?config_mod.Section) bool {
    // `.global_hotkey`는 schema 필드가 없는 특수 섹션이라 강제로 목록에 넣는다(전역 단축키 녹음 행만 — theme의
    // palette·input의 keybind 특수 행 패턴처럼 currentSectionFields가 행을 합성한다). 좌측 네비에 항상 보여야 한다.
    if (sec == .global_hotkey) return true;
    for (bools) |b| if (b.section == sec) return true;
    for (nums) |n| if (n.section == sec) return true;
    for (enums) |e| if (e.section == sec) return true;
    for (texts) |t| if (t.section == sec) return true;
    for (colors) |c| if (c.section == sec) return true;
    return false;
}

pub fn settingsRowLabel(arena: std.mem.Allocator, cross: bool, section: ?config_mod.Section, label: []const u8) ![]const u8 {
    if (!cross) return label;
    return std.fmt.allocPrint(arena, "{s} › {s}", .{ settingsSectionLabel(section), label });
}

test "Settings model empty search includes every row" {
    try std.testing.expect(settingsRowMatches(null, "", "", ""));
}
test "Settings model config key search ignores ASCII case" {
    try std.testing.expect(settingsRowMatches(null, "unrelated", "font.family", "FONT.FAM"));
    try std.testing.expect(!settingsRowMatches(null, "unrelated", "font.family", "missing"));
}
test "Settings model searches translated descriptions across languages" {
    const key: maru.i18n.Key = .set_section_font;
    inline for (@import("type_info_fields").enumFields(maru.i18n.Lang)) |field| {
        const label = maru.i18n.tIn(@field(maru.i18n.Lang, field.name), key);
        try std.testing.expect(settingsRowMatches(key, "", "unknown", label));
    }
}
test "Settings model sections include colors and special global bindings" {
    const colors = [_]config_mod.schema.ColorField{.{ .key = "test", .doc = "", .value = "#ffffff", .section = .theme }};
    try std.testing.expect(settingsSectionHasField(&.{}, &.{}, &.{}, &.{}, &colors, .theme));
    try std.testing.expect(settingsSectionHasField(&.{}, &.{}, &.{}, &.{}, &.{}, .global_hotkey));
    try std.testing.expect(!settingsSectionHasField(&.{}, &.{}, &.{}, &.{}, &.{}, .font));
}
test "Settings model cross section labels preserve the row identity" {
    const a = std.testing.allocator;
    const plain = try settingsRowLabel(a, false, .font, "family");
    try std.testing.expectEqualStrings("family", plain);
    const cross = try settingsRowLabel(a, true, .font, "family");
    defer a.free(cross);
    const expected = try std.fmt.allocPrint(a, "{s} › family", .{settingsSectionLabel(.font)});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, cross);
}
