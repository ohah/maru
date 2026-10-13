//! **`MetalFrame` 의 모든 필드는 누군가 읽는다** — 렌더러로 가는 frame 에 죽은 필드가 쌓이지 않게 한다.
//!
//! `MetalFrame`(src/renderer/metal_frame.zig)은 Zig 가 한 프레임의 그릴 것을 담아 macOS host 로 넘기는 extern DTO 다.
//! 그것을 읽는 쪽은 **Swift host 하나**다 — `MaruAppHost.swift` 가 `frame.<필드>` 를 렌더러(`maru_metal_renderer_draw`)
//! 인자로 넘긴다. 그래서 Swift 가 `frame.<필드>` 로 읽지 않는 필드는 아무도 안 쓰는 값이다.
//!
//! **왜 세우나.** 렌더러가 Zig 규칙을 다시 적던 자리를 Zig 로 옮기면(ABI 222~228), 렌더러가 쓰던 기하 값
//! (`sidebar_slot_height_px`·`sidebar_header_height_px`·`titlebar_strip_px`·`sidebar_scroll_offset_px`)이 하나씩
//! 할 일을 잃었다. 렌더러 인자는 ABI 227 에서 뺐지만 frame 필드는 남아 매 프레임 스탬프됐고, 주석은 여전히
//! 「렌더러가 이 값으로 py_top 을 민다」고 적고 있었다 — 다음 수정이 그 주석을 믿고 값을 고치면 화면은 안 바뀐다.
//! 이 판정자는 그런 필드가 **생기는 순간** 빨개진다(2026-10-13).
const std = @import("std");

const frame_source = "src/renderer/metal_frame.zig";
const swift_host = "src/platform/macos/MaruAppHost.swift";
const max_source_bytes = 16 * 1024 * 1024;

/// `pub const MetalFrame = extern struct { ... };` 안의 필드 이름(4칸 들여쓰기 `name: 타입`)을 모은다.
fn collectFrameFields(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList([]const u8) {
    const open = "pub const MetalFrame = extern struct {";
    const start = std.mem.indexOf(u8, source, open) orelse return error.MetalFrameNotFound;
    const end = std.mem.indexOfPos(u8, source, start, "\n};") orelse return error.MetalFrameNotFound;
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer fields.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source[start + open.len .. end], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "     ")) continue;
        const rest = line[4..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const name = rest[0..colon];
        if (name.len == 0) continue;
        var ident = true;
        for (name) |ch| {
            if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) ident = false;
        }
        if (ident) try fields.append(allocator, name);
    }
    return fields;
}

/// `frame.<name>` 이 단어 경계로 나타나는가(`frame.cells` 가 `frame.cells_count` 에 걸리지 않게).
fn swiftReads(swift: []const u8, name: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, swift, offset, "frame.")) |at| {
        const begin = at + "frame.".len;
        offset = begin;
        if (!std.mem.startsWith(u8, swift[begin..], name)) continue;
        const after = begin + name.len;
        if (after < swift.len and (std.ascii.isAlphanumeric(swift[after]) or swift[after] == '_')) continue;
        if (at > 0 and (std.ascii.isAlphanumeric(swift[at - 1]) or swift[at - 1] == '_')) continue;
        return true;
    }
    return false;
}

test "MetalFrame 의 모든 필드는 Swift host 가 frame.<필드> 로 읽는다 — 죽은 frame 필드 0 개" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, frame_source, allocator, .limited(max_source_bytes));
    defer allocator.free(source);
    const swift = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, swift_host, allocator, .limited(max_source_bytes));
    defer allocator.free(swift);

    var fields = try collectFrameFields(allocator, source);
    defer fields.deinit(allocator);
    // 파싱이 무너져 0 개를 세면 아래 검사가 아무것도 안 잰다 — 개수로 확인한다(2026-10-13 기준 44 개).
    try std.testing.expect(fields.items.len >= 30);

    var unread: usize = 0;
    for (fields.items) |name| {
        if (swiftReads(swift, name)) continue;
        std.debug.print("\nMetalFrame.{s} 를 Swift host({s})가 읽지 않습니다 — 렌더러로 안 가는 죽은 필드입니다.\n  쓰는 곳이 없으면 MetalFrame·app_host_abi.h 에서 빼고(스탬프에 남겨야 하면 ChromeGeometry.sidebar_placement 로 옮기고) ABI 를 올리세요.\n", .{ name, swift_host });
        unread += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), unread);
}

test "swiftReads: 단어 경계로만 맞춘다" {
    try std.testing.expect(swiftReads("let a = frame.cells,", "cells"));
    try std.testing.expect(!swiftReads("let a = frame.cell_count,", "cell"));
    try std.testing.expect(!swiftReads("let a = myframe.cells,", "cells"));
    try std.testing.expect(!swiftReads("let a = cells", "cells"));
}
