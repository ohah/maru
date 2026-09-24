//! OSR 브라우저 조정(W3b, docs/plans/web-osr-backend.md) — L2 순수. 창 하나가 이번 tick 에 모은 OSR 웹 탭의 배치와
//! sidecar 에 이미 있는 브라우저 기록을 비교해 보낼 명령(create·resize·set_hidden)을 만든다. OS·프로세스를 모른다 —
//! 기록 저장과 전송은 L4(`platform/macos/web_osr.zig`)가 한다.
//!
//! 파괴는 여기서 정하지 않는다. 배치에서 빠진 탭은 닫혔을 수도, 다른 창으로 옮겨졌을 수도 있다 — WKWebView 경로가
//! `has_web_surface` 로 둘을 가르듯, OSR 은 Term 이 실제로 사라질 때(`destroyTerm`) 파괴한다.

const std = @import("std");
const web_sidecar = @import("web_sidecar/root.zig");
const message = web_sidecar.message;

pub const ViewSize = message.ViewSize;
pub const BrowserId = message.BrowserId;

/// 새 탭이 처음 보일 때까지 쓸 크기(DIP). 숨은 채 만들어지는 탭(비활성 워크스페이스)은 rect 가 0 이다.
pub const fallback_size: ViewSize = .{ .width = 800, .height = 600, .scale = 2 };

/// 이번 tick 의 OSR 웹 탭 하나(창 좌표, backing px).
pub const Layout = struct {
    surface_id: u64,
    width_px: u32,
    height_px: u32,
    visible: bool,
};

/// sidecar 에 보낸 마지막 상태.
pub const Record = struct {
    surface_id: u64,
    size: ViewSize,
    hidden: bool,
};

pub const Command = union(enum) {
    create: struct { browser: BrowserId, size: ViewSize, hidden: bool },
    resize: struct { browser: BrowserId, size: ViewSize },
    set_hidden: struct { browser: BrowserId, value: bool },
};

/// backing px 를 DIP 로. 0 이면 null(배치 없음 — 크기를 바꾸지 않는다). 나머지는 올림 — CEF 가 그린 장이 rect 보다
/// 작아 가장자리가 비지 않게(W3c 가 rect 에 맞춰 그린다). scale 은 0.5~8 로 가둔다(codec 이 그 밖을 거절한다).
pub fn sizeFor(width_px: u32, height_px: u32, scale_milli: u32) ?ViewSize {
    if (width_px == 0 or height_px == 0) return null;
    const milli = std.math.clamp(scale_milli, 500, 8000);
    const scale: f32 = @as(f32, @floatFromInt(milli)) / 1000.0;
    const w = std.math.divCeil(u64, @as(u64, width_px) * 1000, milli) catch unreachable;
    const h = std.math.divCeil(u64, @as(u64, height_px) * 1000, milli) catch unreachable;
    return .{
        .width = @intCast(std.math.clamp(w, 1, message_max_extent)),
        .height = @intCast(std.math.clamp(h, 1, message_max_extent)),
        .scale = scale,
    };
}

const message_max_extent: u64 = web_sidecar.fields.max_view_extent;

/// 배치 하나를 기록과 맞춘다. 보낼 명령을 `out` 에 더하고 기록을 고친다(없으면 만든다 — 호출자가 `records` 에 넣는다).
/// 반환: 새 기록이면 그것(호출자가 저장), 아니면 null.
pub fn reconcile(record: ?*Record, layout: Layout, scale_milli: u32, out: *std.ArrayList(Command), gpa: std.mem.Allocator) error{OutOfMemory}!?Record {
    const hidden = !layout.visible;
    const measured = sizeFor(layout.width_px, layout.height_px, scale_milli);
    const r = record orelse {
        const size = measured orelse fallback_size;
        try out.append(gpa, .{ .create = .{ .browser = layout.surface_id, .size = size, .hidden = hidden } });
        return .{ .surface_id = layout.surface_id, .size = size, .hidden = hidden };
    };
    if (measured) |size| {
        if (size.width != r.size.width or size.height != r.size.height or size.scale != r.size.scale) {
            try out.append(gpa, .{ .resize = .{ .browser = layout.surface_id, .size = size } });
            r.size = size;
        }
    }
    if (hidden != r.hidden) {
        try out.append(gpa, .{ .set_hidden = .{ .browser = layout.surface_id, .value = hidden } });
        r.hidden = hidden;
    }
    return null;
}

const testing = std.testing;

test "sizeFor: px 를 scale 로 나눠 올림하고, 0 rect 는 null, scale 은 0.5~8 로 가둔다" {
    try testing.expectEqual(ViewSize{ .width = 760, .height = 486, .scale = 2 }, sizeFor(1520, 972, 2000).?);
    try testing.expectEqual(ViewSize{ .width = 761, .height = 1, .scale = 2 }, sizeFor(1521, 1, 2000).?); // 올림
    try testing.expect(sizeFor(0, 100, 2000) == null);
    try testing.expect(sizeFor(100, 0, 2000) == null);
    try testing.expectEqual(@as(f32, 8), sizeFor(80, 80, 20000).?.scale);
    try testing.expectEqual(@as(f32, 0.5), sizeFor(80, 80, 0).?.scale);
    try testing.expectEqual(@as(u32, 16384), sizeFor(std.math.maxInt(u32), 10, 1000).?.width); // codec 상한
}

test "reconcile: 처음 보는 탭은 create, 같은 배치는 명령 없음, 크기·보임이 바뀌면 그것만" {
    var out: std.ArrayList(Command) = .empty;
    defer out.deinit(testing.allocator);
    var rec = (try reconcile(null, .{ .surface_id = 11, .width_px = 1520, .height_px = 972, .visible = true }, 2000, &out, testing.allocator)).?;
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(ViewSize{ .width = 760, .height = 486, .scale = 2 }, out.items[0].create.size);
    try testing.expect(!out.items[0].create.hidden);

    out.clearRetainingCapacity();
    try testing.expect((try reconcile(&rec, .{ .surface_id = 11, .width_px = 1520, .height_px = 972, .visible = true }, 2000, &out, testing.allocator)) == null);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    try testing.expect((try reconcile(&rec, .{ .surface_id = 11, .width_px = 1000, .height_px = 972, .visible = true }, 2000, &out, testing.allocator)) == null);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 500), out.items[0].resize.size.width);

    // 비활성 워크스페이스로 가면 rect 가 0 — 크기는 그대로 두고 숨기기만 한다.
    out.clearRetainingCapacity();
    _ = try reconcile(&rec, .{ .surface_id = 11, .width_px = 0, .height_px = 0, .visible = false }, 2000, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].set_hidden.value);
    try testing.expectEqual(@as(u32, 500), rec.size.width);

    // 창의 scale 만 바뀌어도 resize(DIP 가 같아도 scale 이 다르다).
    out.clearRetainingCapacity();
    _ = try reconcile(&rec, .{ .surface_id = 11, .width_px = 500, .height_px = 486, .visible = true }, 1000, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(f32, 1), out.items[0].resize.size.scale);
    try testing.expect(!out.items[1].set_hidden.value);
}

test "reconcile: 숨은 채 처음 보이는 탭은 기본 크기로 숨겨 만든다" {
    var out: std.ArrayList(Command) = .empty;
    defer out.deinit(testing.allocator);
    const rec = (try reconcile(null, .{ .surface_id = 12, .width_px = 0, .height_px = 0, .visible = false }, 2000, &out, testing.allocator)).?;
    try testing.expectEqual(fallback_size, out.items[0].create.size);
    try testing.expect(out.items[0].create.hidden);
    try testing.expect(rec.hidden);
}
