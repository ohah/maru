//! backend-neutral 색 primitive.
//!
//! 색 값은 terminal cell, renderer theme, config resolve 등 여러 레이어가 공유한다.
//! 특정 도메인(예: terminal) 안에 두면 config나 renderer가 색 하나 때문에 그 도메인을
//! import해야 해서 레이어 경계가 흐려진다. 그래서 공용 top-level 모듈로 분리한다.

const std = @import("std");

/// 채널당 8-bit RGB. alpha나 palette index 같은 도메인 의미는 담지 않는다. 그런
/// 의미가 필요한 곳(예: terminal `Color` union의 default/indexed)은 이 타입을 감싸서 둔다.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

// 표준 xterm 16색 팔레트(0..15). 터미널 `Color.indexed`를 화면 RGB로 풀 때 쓴다.
const ansi16 = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 }, // 0 black
    .{ .r = 128, .g = 0, .b = 0 }, // 1 red
    .{ .r = 0, .g = 128, .b = 0 }, // 2 green
    .{ .r = 128, .g = 128, .b = 0 }, // 3 yellow
    .{ .r = 0, .g = 0, .b = 128 }, // 4 blue
    .{ .r = 128, .g = 0, .b = 128 }, // 5 magenta
    .{ .r = 0, .g = 128, .b = 128 }, // 6 cyan
    .{ .r = 192, .g = 192, .b = 192 }, // 7 white
    .{ .r = 128, .g = 128, .b = 128 }, // 8 bright black
    .{ .r = 255, .g = 0, .b = 0 }, // 9 bright red
    .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
    .{ .r = 0, .g = 0, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
    .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// xterm 256색 index를 RGB로 푼다: 0..15 ANSI, 16..231 6×6×6 cube, 232..255 grayscale ramp.
pub fn xterm256(index: u8) Rgb {
    if (index < 16) return ansi16[index];
    if (index < 232) {
        const n = index - 16;
        return .{
            .r = cube_levels[n / 36],
            .g = cube_levels[(n / 6) % 6],
            .b = cube_levels[n % 6],
        };
    }
    const level: u8 = 8 + (index - 232) * 10;
    return .{ .r = level, .g = level, .b = level };
}

/// xterm OSC "color specification"을 RGB로 푼다(OSC 4 팔레트·후속 OSC 10/11 set이 공유). 지원 형식:
///   - `rgb:<r>/<g>/<b>` — 각 채널 1..4 hex 자리를 8-bit로 스케일(rgb:ff/00/80, rgb:ffff/0000/8080 등).
///   - `#rgb` / `#rrggbb` / `#rrrgggbbb` / `#rrrrggggbbbb` — 채널당 1..4 hex 자리.
/// 형식 위반(자리수 0 또는 5+, 비-hex, 채널 수 != 3)이면 null. 베이스: xterm ctlseqs color specification.
pub fn parseSpec(spec: []const u8) ?Rgb {
    if (std.mem.startsWith(u8, spec, "rgb:")) return parseRgbForm(spec[4..]);
    if (spec.len >= 1 and spec[0] == '#') return parseHashForm(spec[1..]);
    return null;
}

fn parseRgbForm(s: []const u8) ?Rgb {
    var it = std.mem.splitScalar(u8, s, '/');
    const r = scaleChannel(it.next() orelse return null) orelse return null;
    const g = scaleChannel(it.next() orelse return null) orelse return null;
    const b = scaleChannel(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null; // 채널 4개+면 형식 위반
    return .{ .r = r, .g = g, .b = b };
}

fn parseHashForm(s: []const u8) ?Rgb {
    if (s.len == 0 or s.len % 3 != 0) return null;
    const w = s.len / 3; // 채널당 자리수
    if (w > 4) return null;
    return .{
        .r = scaleChannel(s[0..w]) orelse return null,
        .g = scaleChannel(s[w .. 2 * w]) orelse return null,
        .b = scaleChannel(s[2 * w .. 3 * w]) orelse return null,
    };
}

/// 1..4 hex 자리 채널을 8-bit로 스케일한다. k자리 값 v(최대 16^k-1)를 `v*255/(16^k-1)`로 0..255에 매핑
/// (xterm: 2-hex는 그대로, 4-hex는 상위 바이트 근사). ff/ffff→255, 80/8080→128, f/fff의 채널→255.
fn scaleChannel(h: []const u8) ?u8 {
    if (h.len == 0 or h.len > 4) return null;
    const v = std.fmt.parseInt(u16, h, 16) catch return null; // 4 hex = 최대 0xffff
    const max: u32 = (@as(u32, 1) << @intCast(4 * h.len)) - 1; // 16^k - 1
    return @intCast(@as(u32, v) * 255 / max);
}

test "rgb holds three independent 8-bit channels" {
    const c: Rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    try std.testing.expectEqual(@as(u8, 0x10), c.r);
    try std.testing.expectEqual(@as(u8, 0x20), c.g);
    try std.testing.expectEqual(@as(u8, 0x30), c.b);
}

test "xterm256 resolves ansi, color cube, and grayscale ranges" {
    // ANSI 16
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(0));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(9));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(15));
    // 6x6x6 cube: 16 = (0,0,0), 231 = (255,255,255)
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, xterm256(16));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, xterm256(231));
    // cube 196 = 16 + 180 -> n=180 -> r=180/36=5(255), g=(180/6)%6=0, b=0
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, xterm256(196));
    // grayscale ramp: 232 = 8, 255 = 238
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, xterm256(232));
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, xterm256(255));
}

test "parseSpec resolves xterm rgb: and # color specifications" {
    // rgb: 2-hex 채널(가장 흔함) — 그대로.
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0x00, .b = 0x80 }, parseSpec("rgb:ff/00/80").?);
    // rgb: 4-hex 채널 — 상위 바이트 근사(ffff→255, 8080→128, 0000→0).
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, parseSpec("rgb:ffff/8080/0000").?);
    // rgb: 1-hex 채널 — f→255, 0→0, 8→0x88(136).
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 136 }, parseSpec("rgb:f/0/8").?);
    // # 6-hex / 3-hex.
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, parseSpec("#aabbcc").?);
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, parseSpec("#abc").?);
    // 형식 위반 → null: 채널 수 부족·과다, 비-hex, 빈 채널, 미지원 prefix.
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:ff/00"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:ff/00/80/11"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb:gg/00/80"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("rgb://"));
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("#abcd")); // 4 hex = 채널당 균등 분할 불가(4%3!=0)
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("blue")); // 이름 색은 미지원
    try std.testing.expectEqual(@as(?Rgb, null), parseSpec("?")); // 질의는 파서가 아니라 호출자가 처리
}
