//! CR6d-v2a actual-AppKit capture의 순수 판정자.
//!
//! 실제 앱이 캡처와 geometry를 만들고 이 모듈은 그 바이트만 판정한다. 화면·입력기·파일시스템을
//! 여기서 다시 조회하지 않아, 캡처 뒤 다른 surface나 frame으로 바뀐 상태를 현재값으로 덮지 않는다.

const std = @import("std");
const ppm = @import("ppm.zig");

pub const Rect = ppm.Rect;

pub const ScreenRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const Capture = struct {
    runtime_id: []const u8,
    surface_id: u64,
    frame_generation: u64,
    cursor: Rect,
    /// AppKit가 제품 view 변환으로 독립 계산한 cursor의 screen-space 사각형이다.
    cursor_screen: ScreenRect,
    /// NSTextInputClient.firstRect(forCharacterRange:)가 같은 frame에서 반환한 값이다.
    first_rect: ScreenRect,
    ppm: []const u8,
};

pub const Result = struct {
    runtime_id: [32]u8,
    surface_id: u64,
    before_generation: u64,
    marked_generation: u64,
    cursor: Rect,
    first_rect: ScreenRect,
    before_digest: [32]u8,
    marked_digest: [32]u8,
    changed_pixels: usize,
    changed_bounds: Rect,
};

pub const Error = error{
    OutOfMemory,
    InvalidIdentity,
    IdentityMismatch,
    GenerationMismatch,
    InvalidGeometry,
    AnchorMismatch,
    InvalidCapture,
    CaptureSizeMismatch,
    NoMarkedPixelChange,
    PixelOutsideInterest,
};

pub const max_capture_bytes: usize = 16 * 1024 * 1024;

/// 첫 marked glyph는 canonical cursor에서 시작하고 한글 한 음절의 최대 두 cell 안에 있어야 한다.
/// 이 좁은 관심 영역 밖 변화까지 허용하면 blink나 다른 frame을 preedit 증거로 오인할 수 있다.
pub fn validate(allocator: std.mem.Allocator, before: Capture, marked: Capture) Error!Result {
    if (before.ppm.len == 0 or before.ppm.len > max_capture_bytes or
        marked.ppm.len == 0 or marked.ppm.len > max_capture_bytes)
        return Error.InvalidCapture;
    if (!validRuntimeId(before.runtime_id) or !validRuntimeId(marked.runtime_id) or
        before.surface_id == 0 or marked.surface_id == 0)
        return Error.InvalidIdentity;
    if (!std.mem.eql(u8, before.runtime_id, marked.runtime_id) or before.surface_id != marked.surface_id)
        return Error.IdentityMismatch;
    if (marked.frame_generation <= before.frame_generation) return Error.GenerationMismatch;
    if (!validRect(before.cursor) or !std.meta.eql(before.cursor, marked.cursor) or
        !validScreenRect(before.cursor_screen) or !validScreenRect(marked.cursor_screen) or
        !validScreenRect(before.first_rect) or !validScreenRect(marked.first_rect))
        return Error.InvalidGeometry;
    if (!std.meta.eql(before.cursor_screen, marked.cursor_screen) or
        !std.meta.eql(before.first_rect, marked.first_rect) or
        !std.meta.eql(before.cursor_screen, before.first_rect) or
        !std.meta.eql(marked.cursor_screen, marked.first_rect))
        return Error.AnchorMismatch;

    var before_image = ppm.decodeP6Exact(allocator, before.ppm) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidCapture,
    };
    defer before_image.deinit(allocator);
    var marked_image = ppm.decodeP6Exact(allocator, marked.ppm) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidCapture,
    };
    defer marked_image.deinit(allocator);
    if (before_image.width != marked_image.width or before_image.height != marked_image.height)
        return Error.CaptureSizeMismatch;
    if (!rectFits(before.cursor, before_image.width, before_image.height)) return Error.InvalidGeometry;

    const interest_w = std.math.mul(u32, before.cursor.w, 2) catch return Error.InvalidGeometry;
    const interest = Rect{
        .x = before.cursor.x,
        .y = before.cursor.y,
        .w = @min(interest_w, before_image.width - before.cursor.x),
        .h = before.cursor.h,
    };

    var count: usize = 0;
    var min_x: u32 = marked_image.width;
    var min_y: u32 = marked_image.height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var y: u32 = 0;
    while (y < marked_image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < marked_image.width) : (x += 1) {
            if (std.meta.eql(before_image.pixelAt(x, y), marked_image.pixelAt(x, y))) continue;
            if (!contains(interest, x, y)) return Error.PixelOutsideInterest;
            count += 1;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
    }
    const minimum_changed = @max(@as(usize, 2), @as(usize, before.cursor.w) * before.cursor.h / 32);
    if (count < minimum_changed) return Error.NoMarkedPixelChange;
    // 변화의 첫 픽셀은 두 번째 cell이 아니라 canonical cursor cell 안에서 시작해야 한다.
    if (!contains(before.cursor, min_x, min_y)) return Error.PixelOutsideInterest;
    var runtime_id: [32]u8 = undefined;
    @memcpy(&runtime_id, before.runtime_id);
    var before_digest: [32]u8 = undefined;
    var marked_digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(before.ppm, &before_digest, .{});
    std.crypto.hash.Blake3.hash(marked.ppm, &marked_digest, .{});
    return .{
        .runtime_id = runtime_id,
        .surface_id = before.surface_id,
        .before_generation = before.frame_generation,
        .marked_generation = marked.frame_generation,
        .cursor = before.cursor,
        .first_rect = before.first_rect,
        .before_digest = before_digest,
        .marked_digest = marked_digest,
        .changed_pixels = count,
        .changed_bounds = .{ .x = min_x, .y = min_y, .w = max_x - min_x + 1, .h = max_y - min_y + 1 },
    };
}

fn validRuntimeId(id: []const u8) bool {
    if (id.len != 32) return false;
    var nonzero = false;
    for (id) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
        nonzero = nonzero or byte != '0';
    }
    return nonzero;
}

fn validRect(rect: Rect) bool {
    return rect.w > 0 and rect.h > 0;
}

fn validScreenRect(rect: ScreenRect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
        std.math.isFinite(rect.w) and std.math.isFinite(rect.h) and rect.w > 0 and rect.h > 0;
}

fn rectFits(rect: Rect, width: u32, height: u32) bool {
    if (!validRect(rect) or rect.x >= width or rect.y >= height) return false;
    return rect.w <= width - rect.x and rect.h <= height - rect.y;
}

fn contains(rect: Rect, x: u32, y: u32) bool {
    return x >= rect.x and y >= rect.y and x - rect.x < rect.w and y - rect.y < rect.h;
}
