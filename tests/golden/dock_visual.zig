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
//! **이 게이트가 신뢰할 수 있는 범위**: Lab은 제품 Session Dock과 **같은 두 텍스트 경로**를 탄다 —
//! 등록 SVG/PUA 아이콘은 셀 draw list(`buildIconTextDrawList`), 나머지 라벨은
//! `system_text.Artifact`(순수 픽셀 placement + 뷰포트 clip). 스크롤 뷰포트도 제품과 같은 출처
//! (published tree의 `content` 사각형)에서 가져와 넘긴다.
//!
//! 그래서 텍스트의 픽셀 정렬과 **텍스트 클리핑까지** 골든으로 고정할 수 있다. 예전에는 Lab이
//! `chrome_draw_lowering.RichTextArtifact`(셀 격자 + 오프셋, clip 파라미터 없음)를 써서 글자가 격자로
//! 스냅되고 잘리지도 않았고, 그 때문에 정렬·클리핑 case는 "고정하면 안 되는 것"으로 빼 뒀다
//! (`group-pill-clipped-edge`를 넣었다가 제거한 적이 있다). 이관 후 그 case가 돌아왔다.
//!
//! 남는 간극: Lab은 dock을 프레임 원점에 단독으로 그리므로 pane 합성(터미널과의 레이어 순서,
//! pane 오프셋)은 보지 않는다. 그건 실제 앱을 띄우는 archive 스모크의 몫이다.
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
        // GPU per-quad clip(#1885)의 핵심 계약: CPU가 rect를 미리 자르면 shader가 줄어든 rect를
        // 원본으로 착각해 **잘린 변에도 곡률과 border stroke**를 그린다. radius가 높이의 절반인
        // count pill이 스크롤 상단에 걸린 이 상태가 그 차이를 유일하게 드러낸다.
        .name = "group-pill-clipped-edge",
        .capture = "partial-group-scroll.ppm",
        .contract = "스크롤 상단에 걸린 그룹 count pill의 잘린 변이 직선이다(곡률·stroke가 생기지 않는다)",
        .rect = .{ .x = 396, .y = 220, .w = 84, .h = 32 },
    },
    .{
        .name = "expanded-actions",
        .capture = "detail-ready.ppm",
        .contract = "펼친 detail의 액션 버튼에 아이콘과 라벨이 있다(빈 상자가 아니다)",
        .rect = .{ .x = 0, .y = 660, .w = 480, .h = 60 },
    },
    .{
        // 이 case가 생기기 전까지 **어떤 골든도 스크롤바를 보지 않았다.** Lab이 스크롤 입력
        // (`scroll_content_height_px`·`scroll_offset_px`)을 채우지 않아 스크롤바가 아예 발행되지
        // 않았고, 그래서 스크롤바를 통째로 지워도 골든 네 장이 전부 통과했다. 게이트가 있다는 것과
        // 그 게이트가 이것을 본다는 것은 다르다.
        //
        // 이 case가 더하는 것은 geometry 계산이 아니라 **그 계산이 GPU 픽셀까지 도달한다**는 것이다.
        // `scrollbarGeometry`의 산술은 build.zig 단위 테스트가 이미 본다. 그 사이 구간 — entry 발행,
        // clip, layer 순서, Metal lowering — 은 픽셀로만 판정된다.
        //
        // crop은 도크 우측 gutter와 그 왼쪽 content 가장자리를 함께 잡는다. 세로로는 track 위쪽 빈
        // 구간·thumb·아래쪽 빈 구간이 모두 들어가므로, thumb의 위치와 높이, track의 범위, 그리고
        // 스크롤바가 content 위로 넘어오는 회귀까지 한 사각형이 판정한다.
        //
        // 시나리오는 스크롤 입력만 주입한다 — 이 두 필드는 `scrollbarFor`만 읽고 가상화에는 관여하지
        // 않으므로, 카드가 offset만큼 밀렸는지는 이 case의 계약이 아니다(그건 `project`의 몫이다).
        .name = "scrollbar-track-and-thumb",
        .capture = "scrollbar.ppm",
        .contract = "넘치는 목록에 track과 thumb이 gutter 안에 있다(발행되고, content를 침범하지 않는다)",
        .rect = .{ .x = 452, .y = 200, .w = 28, .h = 400 },
    },
    // sticky의 세 상태는 clamp **한 줄**에서 나온다. 하나만 캡처하면 나머지 둘이 무판정으로 남고,
    // 그 상태로는 `next_y - h` 항을 빼도(=두 헤더가 겹쳐도) 게이트가 통과한다.
    //
    // crop은 목록 상단 밴드를 잡는다. 여기가 헤더와 지나가는 카드가 만나는 유일한 자리이고,
    // quad·text가 서로 다른 레이어라 **글자가 헤더를 뚫고 나오는** 회귀가 픽셀로만 판정된다.
    .{
        .name = "sticky-head-at-rest",
        .capture = "sticky-at-rest.ppm",
        .contract = "첫 그룹에 닿은 상태의 헤더가 흐름 그대로 있다(고정 때문에 자리가 튀지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
    .{
        .name = "sticky-head-pinned",
        .capture = "sticky-pinned.ppm",
        .contract = "지나간 카드가 고정 헤더 **밑으로** 지나간다(헤더를 뚫고 글자가 보이지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
    .{
        .name = "sticky-head-pushed",
        .capture = "sticky-pushed.ppm",
        .contract = "다음 그룹 헤더가 앞 헤더를 밀어낸다(둘이 같은 자리에 겹치지 않는다)",
        .rect = .{ .x = 0, .y = 200, .w = 480, .h = 120 },
    },
};

test "session dock visual golden" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const update = std.c.getenv("MARU_UPDATE_GOLDEN") != null;
    // 갱신 중에는 캡처가 아직 없을 수 있으므로 요구하지 않는다.
    const require_captures = !update and std.c.getenv("MARU_REQUIRE_GOLDEN") != null;

    var checked: usize = 0;
    for (cases) |case| {
        var capture_path_buf: [256]u8 = undefined;
        const capture_path = try std.fmt.bufPrint(&capture_path_buf, "{s}/{s}", .{ capture_root, case.capture });
        const capture_bytes = std.Io.Dir.cwd().readFileAlloc(io, capture_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            // 스모크를 안 돌린 환경에서는 이 게이트가 의미 없으므로 건너뛴다. 그러나 스모크를 먼저
            // 배선한 곳(CI)에서는 **한 장만 없는 것도 결함**이다 — 나머지 case가 통과하면 `checked > 0`이라
            // 아래 전체-부재 가드에 걸리지 않고, 그 시나리오의 렌더가 죽었다는 사실이 초록에 묻힌다.
            error.FileNotFound => {
                if (require_captures) {
                    std.debug.print("골든 캡처가 없다: {s} (시나리오 렌더가 실패했는가?)\n", .{capture_path});
                    return error.VisualGoldenCaptureMissing;
                }
                continue;
            },
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
        if (require_captures) return error.VisualGoldenCapturesMissing;
    }
}
