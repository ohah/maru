//! 스모크가 남긴 PPM 캡처를 골든 이미지와 비교하는 순수 유틸.
//!
//! 왜 필요한가: chrome/renderer의 시각 결과는 지금까지 사람이 캡처를 **눈으로** 확인했다. 그 방식은
//! 실제로 실패했다 — 부분적으로 보이는 행이 "잘린" 것과 "세로로 눌린" 것을 육안으로 구분하지 못해,
//! 클리핑이 동작하지 않는 상태를 동작한다고 보고한 적이 있다(#1882 리뷰가 잡았다). 사람 눈이 놓치는
//! 종류의 차이를 기계가 보게 하는 것이 이 모듈의 존재 이유다.
//!
//! 전체 프레임(1920×960 PPM = 약 5.5 MB)을 골든으로 커밋하면 저장소가 감당하지 못하고, 무관한 UI
//! 변경마다 갱신해야 해서 아무도 안 보게 된다. 그래서 **관심 영역만 잘라** 비교한다: 검증하려는 계약이
//! 걸린 좁은 사각형 하나가 전체 프레임보다 회귀를 더 정확히 지목한다.

const std = @import("std");

pub const Error = error{
    UnsupportedFormat,
    MalformedHeader,
    TruncatedPixels,
    CropOutOfBounds,
    SizeMismatch,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGB8, 행 우선. 길이는 정확히 `width * height * 3`이다.
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn pixelAt(self: Image, x: u32, y: u32) [3]u8 {
        const index = (@as(usize, y) * self.width + x) * 3;
        return .{ self.pixels[index], self.pixels[index + 1], self.pixels[index + 2] };
    }
};

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// 두 이미지가 얼마나 다른지. 정확 일치를 요구하지 않는 이유는 아래 `expectMatches` 주석에 있다.
pub const Diff = struct {
    /// 채널 하나라도 허용치를 넘은 픽셀 수.
    differing_pixels: usize,
    /// 그 중 가장 큰 채널 차이(0이면 완전 일치).
    max_channel_delta: u8,
    /// 처음 어긋난 픽셀 좌표(있으면). 실패 메시지가 "어디"를 말할 수 있게 한다.
    first_x: u32 = 0,
    first_y: u32 = 0,
};

/// P6(binary RGB) PPM만 읽는다. 스모크가 그 포맷으로만 쓰므로 P3(ASCII)까지 지원해 표면을 넓히지 않는다.
pub fn decodeP6(allocator: std.mem.Allocator, bytes: []const u8) (Error || error{OutOfMemory})!Image {
    if (bytes.len < 2 or bytes[0] != 'P' or bytes[1] != '6') return Error.UnsupportedFormat;
    var cursor: usize = 2;
    const width = try readHeaderValue(bytes, &cursor);
    const height = try readHeaderValue(bytes, &cursor);
    const max_value = try readHeaderValue(bytes, &cursor);
    if (max_value != 255) return Error.UnsupportedFormat;
    // maxval 뒤 **정확히 한 바이트**의 공백만 헤더에 속한다(PPM 규약). 그 다음부터 픽셀이다.
    if (cursor >= bytes.len or !isPpmSpace(bytes[cursor])) return Error.MalformedHeader;
    cursor += 1;
    const needed = @as(usize, width) * @as(usize, height) * 3;
    if (bytes.len - cursor < needed) return Error.TruncatedPixels;
    const pixels = try allocator.alloc(u8, needed);
    @memcpy(pixels, bytes[cursor..][0..needed]);
    return .{ .width = width, .height = height, .pixels = pixels };
}

/// 관심 영역만 잘라 새 이미지를 만든다. 골든은 이 결과를 저장한다.
pub fn crop(allocator: std.mem.Allocator, image: Image, rect: Rect) (Error || error{OutOfMemory})!Image {
    if (rect.w == 0 or rect.h == 0) return Error.CropOutOfBounds;
    if (rect.x + rect.w > image.width or rect.y + rect.h > image.height) return Error.CropOutOfBounds;
    const pixels = try allocator.alloc(u8, @as(usize, rect.w) * @as(usize, rect.h) * 3);
    errdefer allocator.free(pixels);
    var row: u32 = 0;
    while (row < rect.h) : (row += 1) {
        const src_start = ((@as(usize, rect.y + row) * image.width) + rect.x) * 3;
        const dst_start = @as(usize, row) * rect.w * 3;
        @memcpy(pixels[dst_start..][0 .. @as(usize, rect.w) * 3], image.pixels[src_start..][0 .. @as(usize, rect.w) * 3]);
    }
    return .{ .width = rect.w, .height = rect.h, .pixels = pixels };
}

pub fn encodeP6(allocator: std.mem.Allocator, image: Image) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "P6\n{d} {d}\n255\n", .{ image.width, image.height });
    try out.appendSlice(allocator, image.pixels);
    return out.toOwnedSlice(allocator);
}

/// 두 이미지의 차이를 센다. `tolerance`는 **채널당** 허용 오차다.
pub fn compare(expected: Image, actual: Image, tolerance: u8) Error!Diff {
    if (expected.width != actual.width or expected.height != actual.height) return Error.SizeMismatch;
    var diff = Diff{ .differing_pixels = 0, .max_channel_delta = 0 };
    var index: usize = 0;
    while (index < expected.pixels.len) : (index += 3) {
        var worst: u8 = 0;
        for (0..3) |channel| {
            const a = expected.pixels[index + channel];
            const b = actual.pixels[index + channel];
            const delta = if (a > b) a - b else b - a;
            if (delta > worst) worst = delta;
        }
        if (worst > diff.max_channel_delta) diff.max_channel_delta = worst;
        if (worst > tolerance) {
            if (diff.differing_pixels == 0) {
                const pixel = index / 3;
                diff.first_x = @intCast(pixel % expected.width);
                diff.first_y = @intCast(pixel / expected.width);
            }
            diff.differing_pixels += 1;
        }
    }
    return diff;
}

test "decodeP6 reads a minimal image and rejects malformed input" {
    const allocator = std.testing.allocator;
    // 2×1 이미지: 빨강, 초록. 헤더에 주석과 여러 공백을 섞어 실제 writer 변형에 견디는지 본다.
    const source = "P6\n# comment\n2 1\n255\n" ++ "\xff\x00\x00\x00\xff\x00";
    var image = try decodeP6(allocator, source);
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual([3]u8{ 0xff, 0, 0 }, image.pixelAt(0, 0));
    try std.testing.expectEqual([3]u8{ 0, 0xff, 0 }, image.pixelAt(1, 0));

    try std.testing.expectError(Error.UnsupportedFormat, decodeP6(allocator, "P3\n1 1\n255\n\x00\x00\x00"));
    try std.testing.expectError(Error.TruncatedPixels, decodeP6(allocator, "P6\n2 1\n255\n\xff\x00"));
    try std.testing.expectError(Error.UnsupportedFormat, decodeP6(allocator, "P6\n1 1\n65535\n\x00\x00\x00"));
}

test "crop keeps the requested window and refuses to read outside it" {
    const allocator = std.testing.allocator;
    // 3×2. 각 픽셀의 R 채널에 인덱스를 넣어 잘린 위치를 식별한다.
    var pixels = [_]u8{ 0, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0, 5, 0, 0 };
    const image = Image{ .width = 3, .height = 2, .pixels = &pixels };
    var window = try crop(allocator, image, .{ .x = 1, .y = 0, .w = 2, .h = 2 });
    defer window.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), window.width);
    try std.testing.expectEqual(@as(u8, 1), window.pixelAt(0, 0)[0]);
    try std.testing.expectEqual(@as(u8, 2), window.pixelAt(1, 0)[0]);
    try std.testing.expectEqual(@as(u8, 4), window.pixelAt(0, 1)[0]);
    try std.testing.expectError(Error.CropOutOfBounds, crop(allocator, image, .{ .x = 2, .y = 0, .w = 2, .h = 1 }));
}

test "compare tolerates small channel noise but still reports where it broke" {
    var base = [_]u8{ 10, 20, 30, 40, 50, 60 };
    var noisy = [_]u8{ 12, 20, 30, 40, 50, 60 };
    const a = Image{ .width = 2, .height = 1, .pixels = &base };
    const b = Image{ .width = 2, .height = 1, .pixels = &noisy };
    // 허용치 안이면 다른 픽셀로 세지 않지만, 관측한 최대 차이는 그대로 보고한다.
    const soft = try compare(a, b, 2);
    try std.testing.expectEqual(@as(usize, 0), soft.differing_pixels);
    try std.testing.expectEqual(@as(u8, 2), soft.max_channel_delta);
    // 허용치를 낮추면 잡히고, 어디가 처음 어긋났는지 말한다.
    const strict = try compare(a, b, 1);
    try std.testing.expectEqual(@as(usize, 1), strict.differing_pixels);
    try std.testing.expectEqual(@as(u32, 0), strict.first_x);
    // 크기가 다르면 비교 자체가 성립하지 않는다(골든이 오래됐다는 신호다).
    var short = [_]u8{ 10, 20, 30 };
    const c = Image{ .width = 1, .height = 1, .pixels = &short };
    try std.testing.expectError(Error.SizeMismatch, compare(a, c, 0));
}

test "encodeP6 round-trips through decodeP6" {
    const allocator = std.testing.allocator;
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const image = Image{ .width = 2, .height = 1, .pixels = &pixels };
    const encoded = try encodeP6(allocator, image);
    defer allocator.free(encoded);
    var decoded = try decodeP6(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(image.width, decoded.width);
    try std.testing.expectEqualSlices(u8, image.pixels, decoded.pixels);
}

fn isPpmSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// PPM 헤더의 다음 십진 정수를 읽는다. 공백과 `#` 주석 줄을 건너뛴다(netpbm 규약).
fn readHeaderValue(bytes: []const u8, cursor: *usize) Error!u32 {
    var index = cursor.*;
    while (index < bytes.len) {
        if (isPpmSpace(bytes[index])) {
            index += 1;
            continue;
        }
        if (bytes[index] == '#') {
            while (index < bytes.len and bytes[index] != '\n') index += 1;
            continue;
        }
        break;
    }
    if (index >= bytes.len or bytes[index] < '0' or bytes[index] > '9') return Error.MalformedHeader;
    var value: u32 = 0;
    while (index < bytes.len and bytes[index] >= '0' and bytes[index] <= '9') : (index += 1) {
        value = std.math.mul(u32, value, 10) catch return Error.MalformedHeader;
        value = std.math.add(u32, value, bytes[index] - '0') catch return Error.MalformedHeader;
    }
    cursor.* = index;
    return value;
}
