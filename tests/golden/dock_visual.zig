//! Session Dock 시각 골든 게이트.
//!
//! 무엇을 증명하는가: Chrome Lab이 **제품 lowering + Metal 오프스크린 렌더**로 남긴 캡처의 관심 영역이,
//! 커밋된 골든과 픽셀 단위로 같은지. chrome/renderer의 시각 계약(스크롤 클리핑, 액션 라벨,
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
//! 왜 archive 스모크가 아니라 Lab인가: archive 스모크는 실제 앱을 띄우는 visible AppKit 픽스처라
//! `Maru.app` 번들(Swift host + web 번들 + 코드사인)을 통째로 요구한다. 시각 계약을 지키는 데 그 비용은
//! 불필요하다. Lab은 같은 제품 lowering과 Metal 렌더를 오프스크린으로 태우므로 번들 없이 결정적이고,
//! 창 생성 실패 같은 환경 변수도 없다. archive 스모크는 실제 사용자 플로우(포인터·키·provider 실행)
//! 검증에 그대로 남는다 — 두 게이트가 서로 다른 것을 본다.
//!
//! 캡처가 없으면 skip한다. 이 게이트는 Lab을 먼저 돌린 환경에서만 의미가 있고, 캡처 부재를 실패로
//! 만들면 Lab과 무관한 변경까지 막는다.
//!
//! 단 **CI처럼 스모크를 먼저 돌리도록 배선한 곳에서는 skip이 곧 무력화**다: 창 생성이나 캡처가 실패해도
//! 초록으로 지나가고, 로그를 아무도 안 보면 "게이트가 있다"는 착각만 남는다. `MARU_REQUIRE_GOLDEN=1`이면
//! 캡처 부재를 실패로 만든다 — `mise run macos-dock-visual-golden`이 그 값을 켠다.

const std = @import("std");
const ppm = @import("ppm");

const capture_root = "zig-out/maru-macos-chrome-lab";
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
        .name = "partial-scroll-cards",
        .capture = "partial-scroll.ppm",
        .contract = "부분 스크롤된 카드 3행의 높이·간격이 DockMetrics대로다(축소되지 않는다)",
        .rect = .{ .x = 0, .y = 205, .w = 480, .h = 290 },
    },
    .{
        .name = "group-header-pill",
        .capture = "retained-list.ppm",
        .contract = "그룹 헤더의 이름·chevron·count pill이 행 안 제자리에 있다(pill이 아래로 새지 않는다)",
        .rect = .{ .x = 0, .y = 225, .w = 480, .h = 60 },
    },
    .{
        .name = "expanded-actions",
        .capture = "detail-ready.ppm",
        .contract = "펼친 detail의 액션 버튼에 아이콘과 라벨이 있다(빈 상자가 아니다)",
        .rect = .{ .x = 0, .y = 660, .w = 480, .h = 60 },
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
        std.debug.print("dock 시각 골든: 캡처가 없어 건너뛴다(먼저 `zig build macos-chrome-lab-smoke`)\n", .{});
        // 스모크를 먼저 돌리도록 배선한 곳(CI)에서는 캡처 부재 자체가 결함이다. 창 생성이나 캡처가
        // 실패했는데 게이트가 초록이면 그 실패를 영원히 못 본다.
        if (std.c.getenv("MARU_REQUIRE_GOLDEN") != null) return error.VisualGoldenCapturesMissing;
    }
}
