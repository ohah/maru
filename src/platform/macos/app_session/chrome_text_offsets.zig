//! CoreText measurement shared by control-font fields; layout policy stays in the caller.
const chrome = @import("maru").chrome;
const AppSession = @import("../app_session.zig").AppSession;
extern "c" fn maru_macos_coretext_chrome_offsets(text: [*]const u8, len: usize, offsets: *const [3]usize, positions: *[3]f64, family: [*]const u8, family_len: usize, fallback: [*]const u8, fallback_len: usize, font_px: f64, weight: u32, width: f64) c_int;
pub fn measure(self: *AppSession, text: []const u8, offsets: [3]usize, width: u32, scale_milli: u32) ![3]f32 {
    if (width == 0) return .{ 0, 0, 0 };
    if (@import("builtin").os.tag != .macos) return .{ 0, 0, 0 };
    const token = chrome.ui.typography.token(.control);
    var values: [3]f64 = undefined;
    const family = self.appearance.font.family;
    const fallback = self.appearance.font.fallback;
    if (maru_macos_coretext_chrome_offsets(text.ptr, text.len, &offsets, &values, family.ptr, family.len, fallback.ptr, fallback.len, @as(f64, @floatFromInt(token.point_size)) * @as(f64, @floatFromInt(scale_milli)) / 1000.0, @backingInt(token.weight), @floatFromInt(width)) != 0) return error.MeasureFailed;
    return .{ @floatCast(values[0]), @floatCast(values[1]), @floatCast(values[2]) };
}
