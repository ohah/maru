//! 파일시스템이 저장한 철자만 읽는다. 링크의 물리 대상이나 inode로 논리 경로를 합치지 않는다.
//! Apple getattrlist(2)의 ATTR_CMN_NAME + FSOPT_NOFOLLOW 계약과 현재 SDK sys/attr.h ABI를 따른다.
const std = @import("std");
const builtin = @import("builtin");
const request = @import("maru").session.editor.search.request;

const Attributes = extern struct {
    bitmapcount: u16 = 5,
    reserved: u16 = 0,
    common: u32 = 1, // ATTR_CMN_NAME
    volume: u32 = 0,
    directory: u32 = 0,
    file: u32 = 0,
    fork: u32 = 0,
};
extern "c" fn getattrlist(path: [*:0]const u8, attributes: *Attributes, buffer: *anyopaque, size: usize, options: c_ulong) c_int;

/// root 상대 논리 경로를 유지한다. 마지막 구성요소를 따라가지 않으므로 Link/file의 Link도 남는다.
/// 아직 없는 이름은 이미 확인한 부모 아래에서 원래 철자를 보존한다. 다른 조회 실패는 묵살하지 않는다.
pub fn spelling(a: std.mem.Allocator, root: []const u8, input: []const u8, control: anytype) ![]u8 {
    const relative = try request.relativePath(input);
    if (control.cancelled.load(.acquire)) return error.Cancelled;
    if (builtin.os.tag != .macos) return a.dupe(u8, relative);
    var absolute: std.ArrayList(u8) = .empty;
    defer absolute.deinit(a);
    try absolute.appendSlice(a, root);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var absent = false;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        if (absolute.items.len == 0 or absolute.items[absolute.items.len - 1] != '/') try absolute.append(a, '/');
        const prefix = absolute.items.len;
        try absolute.appendSlice(a, part);
        try absolute.append(a, 0);
        var buffer: [std.fs.max_path_bytes + 16]u8 align(4) = undefined;
        var name = part;
        if (!absent) {
            var attributes: Attributes = .{};
            while (true) {
                // FSOPT_NOFOLLOW는 마지막 링크만 보존한다. 다음 구성요소 조회는 그 디렉터리 링크를 통과한다.
                const rc = getattrlist(absolute.items[0 .. absolute.items.len - 1 :0].ptr, &attributes, &buffer, buffer.len, 1);
                if (rc == 0) {
                    name = try attributeName(&buffer);
                    break;
                }
                switch (std.posix.errno(rc)) {
                    .INTR => if (control.cancelled.load(.acquire)) return error.Cancelled,
                    .NOENT, .NOTDIR => {
                        absent = true;
                        break;
                    },
                    else => return error.PathSpellingUnavailable,
                }
            }
        }
        absolute.shrinkRetainingCapacity(prefix);
        try absolute.appendSlice(a, name);
        if (result.items.len > 0) try result.append(a, '/');
        try result.appendSlice(a, name);
    }
    return result.toOwnedSlice(a);
}

// attrreference는 현재 SDK의 int32/u32다. 오래된 man page의 long/size_t를 64-bit ABI로 해석하지 않는다.
fn attributeName(buffer: []const u8) ![]const u8 {
    if (buffer.len < 12) return error.InvalidPathAttributes;
    const endian = builtin.cpu.arch.endian();
    const total = std.mem.readInt(u32, buffer[0..4], endian);
    const offset = std.mem.readInt(i32, buffer[4..8], endian);
    const length = std.mem.readInt(u32, buffer[8..12], endian);
    if (total > buffer.len or total < 12 or offset < 8 or length < 2) return error.InvalidPathAttributes;
    const start = try std.math.add(usize, 4, @intCast(offset));
    const end = try std.math.add(usize, start, length);
    if (end > total or buffer[end - 1] != 0) return error.InvalidPathAttributes;
    const name = buffer[start .. end - 1];
    if (!std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPathAttributes;
    return name;
}

/// 점유 키는 예산 제외·미지원 모델도 포함한다. 정규화 완료 전에 모델/디스크 검색을 시작하지 않는다.
pub fn prepare(a: std.mem.Allocator, root: []const u8, state: *request.State, models: anytype, control: anytype) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var keys = state.occupied.keyIterator();
    while (keys.next()) |key| {
        const name = try spelling(a, root, key.*, control);
        names.append(a, name) catch |err| {
            a.free(name);
            return err;
        };
    }
    // iterator 사용이 끝난 뒤 추가한다. 중간 OOM에도 기존 키를 잃지 않아 caller가 전체를 해제할 수 있다.
    for (names.items) |name| try state.occupy(a, name);
    for (models.items) |*captured| {
        const name = try spelling(a, root, captured.path, control);
        state.occupy(a, name) catch |err| {
            a.free(name);
            return err;
        };
        a.free(captured.path);
        captured.path = name;
    }
}

test "EDPSPATH1 metadata 참조의 잘림 오프셋과 잘못된 이름은 경로가 되지 않는다" {
    const endian = builtin.cpu.arch.endian();
    var valid: [16]u8 = @splat(0);
    std.mem.writeInt(u32, valid[0..4], 14, endian);
    std.mem.writeInt(i32, valid[4..8], 8, endian);
    std.mem.writeInt(u32, valid[8..12], 2, endian);
    valid[12] = 'x';
    try std.testing.expectEqualStrings("x", try attributeName(&valid));
    for (0..7) |corruption| {
        var invalid = valid;
        switch (corruption) {
            0 => std.mem.writeInt(u32, invalid[0..4], 17, endian),
            1 => std.mem.writeInt(i32, invalid[4..8], -1, endian),
            2 => std.mem.writeInt(u32, invalid[8..12], 5, endian),
            3 => invalid[13] = 'y',
            4 => invalid[12] = '/',
            5 => invalid[12] = 0,
            else => invalid[12] = 0x80,
        }
        try std.testing.expectError(error.InvalidPathAttributes, attributeName(&invalid));
    }
}
