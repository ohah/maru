//! 제품 helper는 현재 앱의 Contents/Helpers/rg 하나뿐이다. PATH·저장소·환경 override를 보지 않는다.
const std = @import("std");
pub fn locate(a: std.mem.Allocator, io: std.Io) ![]u8 {
    const executable = try std.process.executablePathAlloc(io, a);
    defer a.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return error.NotAppBundle;
    if (!std.mem.endsWith(u8, directory, "/Contents/MacOS")) return error.NotAppBundle;
    return std.fs.path.join(a, &.{ directory, "..", "Helpers", "rg" });
}
