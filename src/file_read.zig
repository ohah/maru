//! 파일 전체를 읽되 **읽는 동안 파일이 자라거나 줄어도 죽지 않는다**.
//!
//! std `Dir.readFileAlloc`·`File.Reader.interface.allocRemaining` 은 파일 크기를 한 번 재서 캐시하고
//! (`File.Reader.getSize`), 남은 양을 「캐시한 크기 − 지금까지 읽은 양」으로 셈한다(`Io/Writer.zig` sendFile). 그 사이
//! 다른 프로세스·스레드가 더 쓰면 읽은 양이 캐시한 크기를 넘어 **뺄셈이 넘친다** — Debug·ReleaseSafe 에서는
//! `integer overflow` **패닉**(`catch` 로 못 잡는다), ReleaseFast 에서는 거대한 값으로 감겨 상한까지 할당한다.
//! 2026-10-12 실측: 쓰는 중인 파일을 해시하는 `file_tree_backend.hashFile` 이 판정자에서 5/5 패닉, 같은 원인의
//! `live_pty` 판정자가 단독 100 회 중 5 회 패닉.
//!
//! 여기서는 크기를 묻지 않고 **지금 위치부터 EOF 까지 위치 지정 읽기**를 반복한다. 읽는 순간까지 있던 바이트를
//! 돌려준다(그 뒤에 덧붙은 것은 다음 읽기의 몫이다). 상한을 넘으면 `error.StreamTooLong` — std 와 같은 이름이라
//! 호출자의 오류 처리를 바꾸지 않아도 된다.
//!
//! std 만 쓰는 최상위 잎이다(layering §3.4) — 플랫폼·제품 모듈을 import 하지 않는다.

const array_repeat = @import("array_repeat");

const std = @import("std");

pub const Error = std.Io.File.ReadPositionalError || std.mem.Allocator.Error || error{StreamTooLong};

/// 한 번에 읽는 양. 파일 크기를 미리 모르므로 이 단위로 늘려 가며 읽는다.
const chunk_bytes: usize = 64 * 1024;

/// 이미 연 파일을 처음부터 EOF 까지 읽는다. 내용이 `limit` 바이트를 넘으면 `error.StreamTooLong`.
pub fn readOpenedAlloc(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File, limit: usize) Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var offset: u64 = 0;
    while (true) {
        // 상한 + 1 바이트까지만 받는다 — 그 한 바이트가 「상한을 넘었다」의 증거다.
        const room = (limit +| 1) - list.items.len;
        try list.ensureUnusedCapacity(gpa, @min(chunk_bytes, room));
        const dest = list.unusedCapacitySlice();
        const want = @min(dest.len, room);
        const n = try file.readPositional(io, &.{dest[0..want]}, offset);
        if (n == 0) break;
        list.items.len += n;
        offset += n;
        if (list.items.len > limit) return error.StreamTooLong;
    }
    return list.toOwnedSlice(gpa);
}

/// `dir` 기준 경로의 파일을 열어 `readOpenedAlloc` 한다. 여는 실패는 그 오류 그대로다.
pub fn readFileAlloc(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, gpa: std.mem.Allocator, limit: usize) (Error || std.Io.File.OpenError)![]u8 {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    return readOpenedAlloc(io, gpa, file, limit);
}

const testing = std.testing;

test "file_read: 상한까지는 읽고, 한 바이트라도 넘으면 StreamTooLong 이다 — std 와 같은 이름" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "hello" });
    const got = try readFileAlloc(testing.io, tmp.dir, "a", testing.allocator, 5);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
    try testing.expectError(error.StreamTooLong, readFileAlloc(testing.io, tmp.dir, "a", testing.allocator, 4));
}

test "file_read: 빈 파일과 청크보다 큰 파일" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty", .data = "" });
    const empty = try readFileAlloc(testing.io, tmp.dir, "empty", testing.allocator, 16);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const big = try testing.allocator.alloc(u8, chunk_bytes * 3 + 17);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big", .data = big });
    const got = try readFileAlloc(testing.io, tmp.dir, "big", testing.allocator, big.len);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, big, got);
}

test "file_read: 다른 스레드가 덧붙이고 비우는 중에도 죽지 않는다 — std readFileAlloc 이 패닉하던 자리" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 아래 쓰는 쪽이 POSIX 호출이다
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "grow.log", .data = "start\n" });
    const file = try tmp.dir.openFile(testing.io, "grow.log", .{ .mode = .write_only });
    defer file.close(testing.io);

    const Writer = struct {
        stop: std.atomic.Value(bool) = .init(false),
        writes: std.atomic.Value(usize) = .init(0),
        fn run(self: *@This(), f: std.Io.File) void {
            const chunk = array_repeat.repeat("x", 4096);
            var end: u64 = 0;
            while (!self.stop.load(.acquire)) {
                _ = f.writePositional(testing.io, &.{chunk}, end) catch return;
                end += chunk.len;
                if (end >= 1 << 20) { // 끝없이 자라지 않게 가끔 비운다 — 줄어드는 순간(로그 회전)도 실제로 있다
                    f.setLength(testing.io, 0) catch return;
                    end = 0;
                }
                _ = self.writes.fetchAdd(1, .monotonic);
            }
        }
    };
    var writer: Writer = .{};
    const thread = try std.Thread.spawn(.{}, Writer.run, .{ &writer, file });
    defer {
        writer.stop.store(true, .release);
        thread.join();
    }
    var reads: usize = 0;
    for (0..3000) |_| {
        const got = readFileAlloc(testing.io, tmp.dir, "grow.log", testing.allocator, 8 << 20) catch continue;
        testing.allocator.free(got);
        reads += 1;
    }
    // 개수로 확인한다 — 쓰는 스레드가 실제로 돌았고 읽기도 실제로 됐다.
    try testing.expect(writer.writes.load(.monotonic) > 0);
    try testing.expect(reads > 0);
}
