const std = @import("std");
const i18n = @import("../i18n.zig");

pub const Transition = struct {
    before: i18n.Lang,
    after: i18n.Lang,
    /// Only an explicitly owned, still-matching notice can be translated.
    /// Static table slices remain valid throughout a language transition.
    pub fn ownedMessage(self: Transition, owned: bool, message: []const u8, key: i18n.Key) ?[:0]const u8 {
        if (!owned or !std.mem.eql(u8, message, i18n.tIn(self.before, key))) return null;
        return i18n.tIn(self.after, key);
    }
};
/// Both hosts use the existing i18n resolver; a transition means cached UI
/// strings need repainting. An unchanged preference needs no invalidation.
pub fn apply(preference: i18n.Preference) ?Transition {
    const before = i18n.lang();
    i18n.applyPreference(preference);
    const after = i18n.lang();
    return if (before == after) null else .{ .before = before, .after = after };
}
const Saved = struct {
    language: i18n.Lang,
    locale: [64]u8 = @splat(0),
    len: usize = 0,
    fn init() Saved {
        var saved: Saved = .{ .language = i18n.lang() };
        if (i18n.osLocale()) |tag| {
            saved.len = tag.len;
            @memcpy(saved.locale[0..tag.len], tag);
        }
        return saved;
    }
    fn restore(self: *const Saved) void {
        i18n.setOsLocale(self.locale[0..self.len]);
        i18n.setLang(self.language);
    }
};
test "language config applies the explicit preference and reports both languages" {
    const saved = Saved.init();
    defer saved.restore();
    i18n.setLang(.en);
    const change = apply(.ko).?;
    try std.testing.expectEqual(i18n.Lang.en, change.before);
    try std.testing.expectEqual(i18n.Lang.ko, change.after);
    try std.testing.expectEqual(i18n.Lang.ko, i18n.lang());
}
test "language config auto uses the injected OS locale and falls back on absence" {
    const saved = Saved.init();
    defer saved.restore();
    i18n.setLang(.en);
    i18n.setOsLocale("ko-KR");
    _ = apply(.auto);
    try std.testing.expectEqual(i18n.Lang.ko, i18n.lang());
    i18n.setOsLocale("");
    _ = apply(.auto);
    try std.testing.expectEqual(i18n.Lang.en, i18n.lang());
}
test "language config unchanged preference does not invalidate caches" {
    const saved = Saved.init();
    defer saved.restore();
    i18n.setLang(.en);
    try std.testing.expect(apply(.en) == null);
}
test "language config translates only its still owned notice" {
    const change: Transition = .{ .before = .en, .after = .ko };
    const old = i18n.tIn(.en, .app_config_apply_pending);
    try std.testing.expectEqualStrings(i18n.tIn(.ko, .app_config_apply_pending), change.ownedMessage(true, old, .app_config_apply_pending).?);
    try std.testing.expect(change.ownedMessage(false, old, .app_config_apply_pending) == null);
    try std.testing.expect(change.ownedMessage(true, i18n.tIn(.en, .app_save_failed), .app_config_apply_pending) == null);
}
test "language config return transition keeps previous table slices and recovery identity" {
    const saved = Saved.init();
    defer saved.restore();
    i18n.setLang(.ko);
    const old = i18n.t(.app_font_apply_failed);
    const change = apply(.en).?;
    const new = change.ownedMessage(true, old, .app_font_apply_failed).?;
    try std.testing.expectEqualStrings(i18n.t(.app_font_apply_failed), new);
    try std.testing.expectEqualStrings(i18n.tIn(.ko, .app_font_apply_failed), old);
    try std.testing.expect(!std.mem.eql(u8, old, new));
}
