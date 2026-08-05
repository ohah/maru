//! Session Dock 시각 골든 게이트.
//!
//! 무엇을 증명하는가: `macos-agent-session-archive-smoke`가 **실제 AppKit + Metal 경로**로 남긴 캡처의
//! 관심 영역이, 커밋된 골든과 픽셀 단위로 같은지. chrome/renderer의 시각 계약(스크롤 클리핑, 액션 라벨,
//! 카드 밀도)은 지금까지 사람이 캡처를 눈으로 확인해 왔는데, 그 방식이 실제로 놓친 회귀가 있었다 —
//! 부분적으로 보이는 행이 "잘린" 것과 "세로로 눌린" 것을 구분하지 못해 클리핑이 죽은 상태를 정상으로
//! 보고했다(#1882 코드리뷰가 잡았다). 사람 눈이 놓치는 종류의 차이를 기계가 보게 하는 것이 목적이다.
//!
//! 왜 전체 프레임이 아니라 잘라서 보는가: 1920×960 PPM은 약 5.5 MB라 커밋할 수 없고, 무관한 UI 변경마다
//! 갱신해야 해서 결국 아무도 안 본다. 검증하려는 계약이 걸린 좁은 사각형 하나가 회귀를 더 정확히 지목한다.
//!
//! 골든 갱신: `MARU_UPDATE_GOLDEN=1 zig build test-dock-visual-golden` (기존 replay 골든과 같은 관례).
//! 갱신 후에는 **반드시 눈으로 확인**하고 커밋한다 — 자동 갱신은 회귀를 골든으로 굳힐 수 있다.
//!
//! 캡처가 없으면 skip한다. 이 게이트는 스모크를 먼저 돌린 환경에서만 의미가 있고, 캡처 부재를 실패로
//! 만들면 스모크와 무관한 변경까지 막는다.

const std = @import("std");
const ppm = @import("ppm");

const capture_root = "zig-out/maru-agent-session-archive-smoke/captures";
const golden_root = "tests/fixtures/golden/dock";

/// GPU 렌더는 같은 기기·드라이버에서 결정적이지만, 러너가 바뀌면 rasterizer 미세 차이가 날 수 있다.
/// 채널당 2까지는 잡지 않는다 — 이번에 잡으려는 결함(클리핑 실패, 라벨 소실, 밀도 변화)은 그보다
/// 훨씬 큰 차이라 감도를 잃지 않는다.
const channel_tolerance: u8 = 2;

const Case = struct {
    name: []const u8,
    capture: []const u8,
    /// 이 사각형이 무엇을 지키는지 — 실패했을 때 사람이 바로 알 수 있게 계약을 적는다.
    contract: []const u8,
    rect: ppm.Rect,
};

const cases = [_]Case{
    .{
        .name = "scroll-clip-boundary",
        .capture = "expanded-scroll-anchor-scroll-anchor-after.ppm",
        .contract = "부분적으로 보이는 카드가 스크롤 영역 상단에서 잘린다(눌리지 않는다) + 고정 chrome 미침범",
        .rect = .{ .x = 1300, .y = 275, .w = 600, .h = 90 },
    },
    .{
        .name = "expanded-actions",
        .capture = "expanded-scroll-anchor-scroll-anchor-after.ppm",
        .contract = "펼친 카드의 액션 버튼에 아이콘과 라벨이 있다(빈 상자가 아니다)",
        .rect = .{ .x = 1300, .y = 610, .w = 600, .h = 60 },
    },
    .{
        .name = "list-density",
        .capture = "resume-pointer-list.ppm",
        .contract = "그룹 헤더와 카드 3행의 높이·간격이 DockMetrics대로다(축소되지 않는다)",
        // 스코프 버튼 행을 반쯤 걸치지 않게 검색 필드 아래부터 잡는다 — 골든은 검증하려는 계약만 담아야
        // 무관한 변경으로 갱신되지 않는다.
        .rect = .{ .x = 1300, .y = 240, .w = 600, .h = 240 },
    },
};

test "session dock visual golden" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const update = std.c.getenv("MARU_UPDATE_GOLDEN") != null;

    var checked: usize = 0;
    for (cases) |case| {
        var capture_path_buf: [256]u8 = undefined;
        const capture_path = try std.fmt.bufPrint(&capture_path_buf, "{s}/{s}", .{ capture_root, case.capture });
        const capture_bytes = std.Io.Dir.cwd().readFileAlloc(io, capture_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue, // 스모크를 안 돌린 환경 — 이 게이트는 그때 의미가 없다.
            else => return err,
        };
        defer allocator.free(capture_bytes);

        var frame = try ppm.decodeP6(allocator, capture_bytes);
        defer frame.deinit(allocator);
        var window = ppm.crop(allocator, frame, case.rect) catch |err| {
            std.debug.print(
                "golden crop이 캡처 밖이다: {s} (캡처 {d}x{d}, 요청 {d},{d} {d}x{d}) — viewport가 바뀌었으면 rect를 갱신하라\n",
                .{ case.name, frame.width, frame.height, case.rect.x, case.rect.y, case.rect.w, case.rect.h },
            );
            return err;
        };
        defer window.deinit(allocator);

        var golden_path_buf: [256]u8 = undefined;
        const golden_path = try std.fmt.bufPrint(&golden_path_buf, "{s}/{s}.ppm", .{ golden_root, case.name });

        if (update) {
            const encoded = try ppm.encodeP6(allocator, window);
            defer allocator.free(encoded);
            try std.Io.Dir.cwd().createDirPath(io, golden_root);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = encoded });
            checked += 1;
            continue;
        }

        const golden_bytes = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("golden이 없다: {s} (MARU_UPDATE_GOLDEN=1로 만들고 눈으로 확인한 뒤 커밋하라)\n", .{golden_path});
                return err;
            },
            else => return err,
        };
        defer allocator.free(golden_bytes);
        var golden = try ppm.decodeP6(allocator, golden_bytes);
        defer golden.deinit(allocator);

        const diff = ppm.compare(golden, window, channel_tolerance) catch |err| {
            std.debug.print("golden 크기가 캡처와 다르다: {s} — {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        if (diff.differing_pixels != 0) {
            std.debug.print(
                "시각 회귀: {s}\n  계약: {s}\n  다른 픽셀 {d}개, 최대 채널 차이 {d}, 처음 어긋난 곳 ({d},{d})\n  갱신이 의도라면 MARU_UPDATE_GOLDEN=1로 다시 만들고 **눈으로 확인**하라\n",
                .{ case.name, case.contract, diff.differing_pixels, diff.max_channel_delta, diff.first_x, diff.first_y },
            );
            return error.VisualGoldenMismatch;
        }
        checked += 1;
    }

    if (checked == 0) {
        // 캡처가 하나도 없으면 조용히 통과하지 않는다 — "게이트가 돌았다"는 착각이 가장 위험하다.
        std.debug.print("dock 시각 골든: 캡처가 없어 건너뛴다(먼저 `zig build macos-agent-session-archive-smoke`)\n", .{});
    }
}
