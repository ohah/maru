//! 합성 글리프(block·box·Powerline)가 공유하는 RGBA8 슬롯 픽셀 프리미티브 — 슬롯 계약 검증·클리어·흰색
//! coverage 쓰기·코너 대각선을 **단일 출처**로 둔다. 셀 셰이더가 alpha를 coverage로 읽어 전경색으로 칠하므로
//! "채움"은 흰색 불투명(0xFFFFFFFF). 세 합성 모듈이 같은 슬롯 계약(bytes_per_row≥w*4, len≥h*bpr)·같은 픽셀
//! 쓰기를 쓰도록 통일해, 한쪽만 고쳐 셋이 갈라지는 drift를 막는다. 중립 모듈(platform 무관).

const std = @import("std");

/// 슬롯이 w×h×4를 담는지(bytes_per_row≥w*4, len≥h*bpr). 어긋나면 OOB 쓰기(메모리 손상)이므로 호출부는
/// false를 받으면 빈 글리프(0px)로 안전 degrade한다.
pub fn slotFits(width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []const u8) bool {
    if (width_px == 0 or height_px == 0) return false;
    if (bytes_per_row < @as(usize, width_px) * 4) return false;
    if (pixels.len < @as(usize, height_px) * bytes_per_row) return false;
    return true;
}

/// 슬롯 h*bpr 바이트를 0으로(투명). slotFits 통과 가정.
pub fn clear(pixels: []u8, height_px: u32, bytes_per_row: usize) void {
    @memset(pixels[0 .. @as(usize, height_px) * bytes_per_row], 0);
}

/// off 위치 픽셀을 흰색 불투명(0xFFFFFFFF). 경계는 호출부가 slotFits로 검증했으므로 per-pixel 가드 없이 쓴다.
pub fn setPixel(pixels: []u8, off: usize) void {
    pixels[off] = 0xFF;
    pixels[off + 1] = 0xFF;
    pixels[off + 2] = 0xFF;
    pixels[off + 3] = 0xFF;
}

/// off 위치 픽셀을 RGB=흰색·A=alpha로(부분 coverage = 셰이더가 fg를 alpha/255 비율로 blend). 음영 삼각형 등.
pub fn setPixelAlpha(pixels: []u8, off: usize, alpha: u8) void {
    pixels[off] = 0xFF;
    pixels[off + 1] = 0xFF;
    pixels[off + 2] = 0xFF;
    pixels[off + 3] = alpha;
}

/// 셀 전체를 균일 alpha(RGB=흰색·A=alpha)로 채운다 — 음영 ░▒▓처럼 부분 coverage. 셰이더가 alpha를 coverage로
/// 읽어 `mix(bg, fg, alpha/255)`라, alpha=0x40/0x80/0xC0이면 fg를 25%/50%/75% blend한다. **새로 칠한** 픽셀 수
/// 반환(이미 칠해진 건 안 셈 — 다른 프리미티브와 같은 dedup 회계; 빈 슬롯이면 =w*h). slotFits 통과 가정.
/// alpha=0이면 빈 셀(0px).
pub fn fillUniformAlpha(pixels: []u8, width_px: u32, height_px: u32, bytes_per_row: usize, alpha: u8) u32 {
    if (alpha == 0) return 0;
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < height_px) : (y += 1) {
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < width_px) : (x += 1) {
            const off = row_off + @as(usize, x) * 4;
            if (pixels[off + 3] == 0) count += 1; // 교차 dedup 회계(다른 프리미티브와 일관)
            pixels[off] = 0xFF;
            pixels[off + 1] = 0xFF;
            pixels[off + 2] = 0xFF;
            pixels[off + 3] = alpha;
        }
    }
    return count;
}

/// [x0,x1)×[y0,y1) 픽셀을 흰색 불투명으로. **새로 칠한** 픽셀 수 반환(이미 칠해진 건 안 셈 → 겹치는 띠가
/// 교차해도 non_clear_pixels 회계가 정확). 서로 안 겹치는 사각형(block)에도 동일 결과. RGBA8 + bytes_per_row.
/// slotFits 통과 가정.
pub fn fillRect(pixels: []u8, bytes_per_row: usize, x0: u32, y0: u32, x1: u32, y1: u32) u32 {
    if (x1 <= x0 or y1 <= y0) return 0;
    var count: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(usize, y) * bytes_per_row;
        var x = x0;
        while (x < x1) : (x += 1) {
            const off = row_off + @as(usize, x) * 4;
            if (pixels[off + 3] == 0) count += 1; // 교차에서 겹친 픽셀은 한 번만 센다
            setPixel(pixels, off);
        }
    }
    return count;
}

/// 코너↔코너 대각선을 두께 t로 그린다. do_back=╲(좌상→우하), do_fwd=╱(좌하→우상), 둘 다면 ╳. 점-직선 수직거리
/// |px·fh − py·fw|/norm ≤ max(0.5, t/2)로 칠한다(셀 전체를 가로지르는 대각이라 선분 클립과 동치 — box ╱╲╳와
/// Powerline 모서리 thin 대각선이 같은 식). 새로 칠한 픽셀 수 반환. slotFits 통과 가정.
pub fn fillDiagonal(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, t: u32, do_back: bool, do_fwd: bool) u32 {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const norm = @sqrt(fw * fw + fh * fh);
    if (norm == 0) return 0;
    const half = @max(0.5, @as(f32, @floatFromInt(t)) / 2.0);
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            // ╲: px·fh − py·fw = 0. ╱: px·fh + py·fw − fw·fh = 0. (정규화 분모 norm 공유)
            const hit = (do_back and @abs(px * fh - py * fw) / norm <= half) or
                (do_fwd and @abs(px * fh + py * fw - fw * fh) / norm <= half);
            if (hit) {
                const off = row_off + @as(usize, x) * 4;
                if (pixels[off + 3] == 0) count += 1;
                setPixel(pixels, off);
            }
        }
    }
    return count;
}

/// 점 (px,py)에서 선분 (ax,ay)-(bx,by)까지 최단거리(끝점 클램프).
pub fn distSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    var tparam = ((px - ax) * dx + (py - ay) * dy) / len2;
    tparam = std.math.clamp(tparam, 0.0, 1.0);
    const qx = ax + tparam * dx;
    const qy = ay + tparam * dy;
    return @sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
}

/// 선분 (x0,y0)-(x1,y1)을 두께 t로 stroke한다(선분까지 거리 ≤ max(0.5, t/2)). 끝점이 셀 모서리·모서리중점·
/// 중앙이면 격자에 스냅된다. 대각선 글리프(🮠~🮮·🯐~🯟)용. 새로 칠한 픽셀 수 반환. slotFits 통과 가정.
pub fn fillSegment(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, x0: f32, y0: f32, x1: f32, y1: f32, t: u32) u32 {
    const half = @max(0.5, @as(f32, @floatFromInt(t)) / 2.0);
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            if (distSeg(px, py, x0, y0, x1, y1) <= half) {
                const off = row_off + @as(usize, x) * 4;
                if (pixels[off + 3] == 0) count += 1;
                setPixel(pixels, off);
            }
        }
    }
    return count;
}

/// 점 (px,py)가 삼각형 (ax,ay)-(bx,by)-(cx,cy) 안인지 — 세 변 외적 부호가 모두 같은(또는 0인) 쪽. 경계 포함.
pub fn pointInTriangle(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) bool {
    const d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by);
    const d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy);
    const d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay);
    const has_neg = d1 < 0 or d2 < 0 or d3 < 0;
    const has_pos = d1 > 0 or d2 > 0 or d3 > 0;
    return !(has_neg and has_pos);
}

/// 삼각형 (a,b,c)를 흰색 불투명으로 채운다(픽셀 중심 +0.5 기준). invert면 셀 안에서 삼각형 **바깥**을 채운다
/// (반전 wedge). 정점이 셀 모서리/중앙이면 셀 격자에 칼같이 스냅된다. 새로 칠한 픽셀 수 반환. slotFits 통과 가정.
pub fn fillTriangle(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, invert: bool) u32 {
    return fillTriangleAlpha(pixels, bytes_per_row, w, h, ax, ay, bx, by, cx, cy, invert, 0xFF);
}

/// fillTriangle과 같되 채움 alpha를 지정한다 — 음영 corner 삼각형(◢◣◤◥ solid=0xFF·🮜🮝🮞🮟 50%=0x80) 등. 새로
/// 칠한 픽셀 수 반환(alpha>0 가정). slotFits 통과 가정.
pub fn fillTriangleAlpha(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, invert: bool, alpha: u8) u32 {
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            if (pointInTriangle(px, py, ax, ay, bx, by, cx, cy) != invert) {
                const off = row_off + @as(usize, x) * 4;
                if (pixels[off + 3] == 0) count += 1;
                setPixelAlpha(pixels, off, alpha);
            }
        }
    }
    return count;
}

/// 단순 다각형(정점을 둘레 순으로 받음)을 흰색 불투명으로 채운다 — scanline even-odd. 정점이 셀 모서리·
/// 모서리중점·중앙이면 셀 격자에 스냅된다. 정점 ≤ 16개 가정(스택 교차 버퍼). 새로 칠한 픽셀 수 반환.
/// slotFits 통과 가정.
pub fn fillPolygon(pixels: []u8, bytes_per_row: usize, w: u32, h: u32, verts: []const [2]f32) u32 {
    if (verts.len < 3) return 0;
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        // 이 scanline과 교차하는 변의 x들(half-open [min,max)로 꼭짓점 이중 카운트 방지).
        var xs: [16]f32 = undefined;
        var nx: usize = 0;
        var i: usize = 0;
        while (i < verts.len) : (i += 1) {
            const a = verts[i];
            const b = verts[(i + 1) % verts.len];
            const ay = a[1];
            const by = b[1];
            if ((ay <= py and py < by) or (by <= py and py < ay)) {
                if (nx < xs.len) {
                    const t = (py - ay) / (by - ay);
                    xs[nx] = a[0] + t * (b[0] - a[0]);
                    nx += 1;
                }
            }
        }
        if (nx < 2) continue;
        // 교차 x 오름차순 정렬(삽입정렬, nx 작음).
        var j: usize = 1;
        while (j < nx) : (j += 1) {
            const key = xs[j];
            var k: usize = j;
            while (k > 0 and xs[k - 1] > key) : (k -= 1) xs[k] = xs[k - 1];
            xs[k] = key;
        }
        const row_off = @as(usize, y) * bytes_per_row;
        var p: usize = 0;
        while (p + 1 < nx) : (p += 2) {
            const xl = xs[p];
            const xr = xs[p + 1];
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                if (px >= xl and px < xr) {
                    const off = row_off + @as(usize, x) * 4;
                    if (pixels[off + 3] == 0) count += 1;
                    setPixel(pixels, off);
                }
            }
        }
    }
    return count;
}

test "slotFits: 계약(bpr≥w*4·len≥h*bpr) 검증" {
    var buf: [16 * 8 * 4]u8 = undefined; // 512 = 정확히 w=8·h=16·bpr=32
    try std.testing.expect(slotFits(8, 16, 8 * 4, &buf)); // 딱 맞음
    try std.testing.expect(!slotFits(0, 16, 32, &buf)); // w=0
    try std.testing.expect(!slotFits(8, 0, 32, &buf)); // h=0
    try std.testing.expect(!slotFits(8, 16, 8 * 4 - 4, &buf)); // bpr 부족(28<32)
    try std.testing.expect(!slotFits(8, 17, 8 * 4, &buf)); // len 부족(h=17 → 544 > 512)
    // 패딩된 bpr(스트라이드 > w*4)도 len이 충분하면 통과.
    var padded: [16 * 40]u8 = undefined; // 640 = h=16·bpr=40
    try std.testing.expect(slotFits(8, 16, 40, &padded));
}

test "fillUniformAlpha: 전 픽셀 균일 alpha, alpha=0이면 0px" {
    const w: u32 = 4;
    const h: u32 = 4;
    const bpr: usize = w * 4;
    var pixels: [4 * 4 * 4]u8 = undefined;
    clear(&pixels, h, bpr);
    try std.testing.expectEqual(@as(u32, 16), fillUniformAlpha(&pixels, w, h, bpr, 0x80));
    try std.testing.expectEqual(@as(u8, 0xFF), pixels[0]); // RGB=흰색
    try std.testing.expectEqual(@as(u8, 0x80), pixels[3]); // alpha
    try std.testing.expectEqual(@as(u8, 0x80), pixels[(15 * 4) + 3]); // 마지막 픽셀
    clear(&pixels, h, bpr);
    try std.testing.expectEqual(@as(u32, 0), fillUniformAlpha(&pixels, w, h, bpr, 0)); // 빈 셀
}

test "fillRect: 겹친 픽셀은 한 번만 센다(교차 회계)" {
    const w: u32 = 8;
    const h: u32 = 8;
    const bpr: usize = w * 4;
    var pixels: [8 * 8 * 4]u8 = undefined;
    clear(&pixels, h, bpr);
    // 가로띠 [0,8)×[3,5) = 16px, 세로띠 [3,5)×[0,8) = 16px, 교차 [3,5)×[3,5) = 4px 중복.
    const c1 = fillRect(&pixels, bpr, 0, 3, w, 5);
    const c2 = fillRect(&pixels, bpr, 3, 0, 5, h);
    try std.testing.expectEqual(@as(u32, 16), c1);
    try std.testing.expectEqual(@as(u32, 12), c2); // 16 − 교차 4(이미 칠해짐)
}

test "fillDiagonal: ╲는 좌상·우하 코너, ╱는 좌하·우상 코너를 지난다" {
    const w: u32 = 16;
    const h: u32 = 16;
    const bpr: usize = w * 4;
    var pixels: [16 * 16 * 4]u8 = undefined;
    const a = struct {
        fn at(p: []const u8, bpr_: usize, x: u32, y: u32) u8 {
            return p[@as(usize, y) * bpr_ + @as(usize, x) * 4 + 3];
        }
    }.at;
    clear(&pixels, h, bpr);
    _ = fillDiagonal(&pixels, bpr, w, h, 2, true, false); // ╲
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, 0));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, h - 1));
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, w - 1, 0));
    clear(&pixels, h, bpr);
    _ = fillDiagonal(&pixels, bpr, w, h, 2, false, true); // ╱
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, 0, h - 1));
    try std.testing.expectEqual(@as(u8, 0xFF), a(&pixels, bpr, w - 1, 0));
    try std.testing.expectEqual(@as(u8, 0x00), a(&pixels, bpr, 0, 0));
}
