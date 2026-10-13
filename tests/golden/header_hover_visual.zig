//! 사이드바 헤더·접힌 ◧·도크 토글 **hover 판** 시각 골든 게이트.
//!
//! 무엇을 증명하는가: `tools/header-hover/capture.sh` 가 **실제 앱**(Swift host + app_session + 제품 Metal 렌더)으로 1x·2x
//! 에서 찍은 hover 판이, 커밋된 골든과 픽셀 단위로 같은지. 판의 자리·높이(아이콘과 동심 · 띠 안 · 잉크를 덮음)와 렌더러가
//! 그것을 실제로 그리는 모습을 함께 고정한다.
//!
//! **왜 이 축만 따로 있나**: 이웃 게이트(`dock_visual.zig`)는 Chrome Lab 장면을 보는데, Lab 은 app_session 을 import 하지 않아
//! hover 판을 하니스가 직접 심는다 — 판의 자리를 정하는 제품 코드(sidebar.zig `headerIconHoverPlateVertical`·file_panel.zig
//! `filePanelDockControlRect`)를 타지 않는다. 2026-10-13 하루에 이 판들의 결함 넷(PR 셋 — #4408 펼친 판 세로 2px·접힌 판 0.5px · #4410 도크
//! Retina 2px · #4421 pill 위 4px 잘림)이 숫자 판정자를 지나 **캡처로만** 보였다. 그 캡처를 사람이 손으로 찍지 않게 한다.
//!
//! ## 무엇을 자르나
//!
//! 띠(1x 28·접힘 30, 2x 56·60px)와 그 아래 몇 px 만 — 판이 띠 밖으로 새면 그 줄이 어긋난다. **글꼴을 타는 것은 뺀다**:
//! 검색 줄 글자·탭 제목·접힌 ◧ 옆 알림 숫자. 헤더 아이콘은 글꼴이 아니라 합성 PUA(`icon_glyph.fillCoverage`)라 러너의
//! 글꼴 구성에 흔들리지 않는다. 실측(2026-10-13, 같은 트리에서 두 번 찍어 비교): 화면 위 10% 는 14장 모두 **0 픽셀**,
//! 차이는 화면 가운데 글자 한 줄(y 75~89)에서만 났다.
//!
//! 골든 갱신: `MARU_UPDATE_GOLDEN=1` (이웃 게이트와 같은 관례). 갱신 뒤에는 **반드시 눈으로 확인**하고 커밋한다 — 자동
//! 갱신은 회귀를 골든으로 굳힌다. 캡처가 없으면 건너뛴다. `MARU_REQUIRE_GOLDEN=1` 이면 부재를 실패로 만든다
//! (`mise run macos-header-hover-visual-golden` 이 켠다).

const std = @import("std");
const ppm = @import("ppm");

const capture_root = "zig-out/header-hover-capture";
const golden_root = "tests/fixtures/golden/header-hover";

/// 이웃 게이트와 같은 값·같은 근거. **잡음 예산은 두지 않는다** — 실측이 0 픽셀이므로 관용을 넓힐 근거가 없다.
const channel_tolerance: u8 = 2;

/// **이 그림을 만든 것들.** 캡처보다 나중에 바뀐 것이 하나라도 있으면 그 그림은 지금 것이 아니다(원격 SCM 게이트와 같은
/// 규율 — 앱 실행 파일이 직접 그리므로 다시 빌드하면 mtime 이 움직인다).
const capture_producers = [_][]const u8{
    "zig-out/Maru.app/Contents/MacOS/maru-macos-app",
    "tools/header-hover/capture.sh",
};

fn captureIsStale(capture_ns: i128, newest_producer_ns: i128) bool {
    return capture_ns < newest_producer_ns;
}

test "낡은 캡처는 낡았다고 판정한다" {
    try std.testing.expect(captureIsStale(100, 200));
    try std.testing.expect(!captureIsStale(200, 100));
    try std.testing.expect(!captureIsStale(100, 100));
}

fn stalerThan(io: std.Io, capture_path: []const u8) ?[]const u8 {
    const cap = std.Io.Dir.cwd().statFile(io, capture_path, .{}) catch return null;
    var newest_ns: i128 = 0;
    var newest_name: ?[]const u8 = null;
    for (capture_producers) |src| {
        const st = std.Io.Dir.cwd().statFile(io, src, .{}) catch continue;
        if (st.mtime.nanoseconds > newest_ns) {
            newest_ns = st.mtime.nanoseconds;
            newest_name = src;
        }
    }
    if (newest_name == null) return null;
    return if (captureIsStale(cap.mtime.nanoseconds, newest_ns)) newest_name else null;
}

/// 펼친 헤더 아이콘 넷(종·◧·⚙·+)과 그 판. 신호등 자리(왼쪽)와 검색 줄 글자(아래)는 뺀다.
const header_1x: ppm.Rect = .{ .x = 72, .y = 0, .w = 108, .h = 34 };
/// 접힌 사이드바의 종과 ◧ 판. 그 왼쪽의 알림 숫자(글꼴)와 아래 탭 제목은 뺀다.
const collapsed_1x: ppm.Rect = .{ .x = 106, .y = 0, .w = 44, .h = 34 };
/// 타이틀바 띠 오른쪽 끝 파일 도크 토글과 그 판(= 클릭 사각형). 아래 탭 바의 ✕·+ 글자는 뺀다.
const dock_1x: ppm.Rect = .{ .x = 912, .y = 0, .w = 48, .h = 34 };

/// 캡처 창의 기본 크기(1x, `MaruAppHost.swift` 의 초기 창 상수). 사각형이 이 크기를 전제로 하므로(도크 토글은 오른쪽 끝)
/// 장마다 먼저 단언한다 — 창이 더 크게 뜨면 crop 은 성공하고 엉뚱한 자리를 비교해 계약 위반으로 오진한다.
const frame_1x_w: u32 = 960;
const frame_1x_h: u32 = 600;

fn x2(r: ppm.Rect) ppm.Rect {
    return .{ .x = r.x * 2, .y = r.y * 2, .w = r.w * 2, .h = r.h * 2 };
}

const Case = struct {
    name: []const u8,
    /// 실패했을 때 사람이 바로 알 수 있게 계약을 적는다.
    contract: []const u8,
    rect: ppm.Rect,
};

const header_contract = "헤더 hover pill 이 그 아이콘과 동심이고 띠 안에서 끝난다(위가 창 끝에서 안 잘린다 — #4408·#4421)";
const cases = [_]Case{
    .{ .name = "header-none-1x", .contract = "hover 가 없으면 헤더 아이콘 뒤에 판이 없다", .rect = header_1x },
    .{ .name = "header-toggle-1x", .contract = header_contract, .rect = header_1x },
    .{ .name = "header-view-options-1x", .contract = header_contract, .rect = header_1x },
    .{ .name = "header-new-workspace-1x", .contract = header_contract, .rect = header_1x },
    .{ .name = "header-bell-1x", .contract = header_contract ++ " — 종은 2칸이라 반 칸 오른쪽 중심", .rect = header_1x },
    .{ .name = "collapsed-toggle-1x", .contract = "접힌 ◧ pill 이 그 아이콘과 동심이고 접힘 띠(30pt) 안에서 끝난다", .rect = collapsed_1x },
    .{ .name = "dock-toggle-1x", .contract = "도크 토글 판(= 클릭 사각형)이 띠에서 멈추고 ◧ 와 동심이다(#4410)", .rect = dock_1x },
    .{ .name = "header-none-2x", .contract = "hover 가 없으면 헤더 아이콘 뒤에 판이 없다(2x)", .rect = x2(header_1x) },
    .{ .name = "header-toggle-2x", .contract = header_contract ++ " — 2x 에서 예전 63px pill 이 56px 띠를 넘었다", .rect = x2(header_1x) },
    .{ .name = "header-view-options-2x", .contract = header_contract, .rect = x2(header_1x) },
    .{ .name = "header-new-workspace-2x", .contract = header_contract, .rect = x2(header_1x) },
    .{ .name = "header-bell-2x", .contract = header_contract, .rect = x2(header_1x) },
    .{ .name = "collapsed-toggle-2x", .contract = "접힌 ◧ pill 이 접힘 띠(2x 60px) 안에서 끝난다", .rect = x2(collapsed_1x) },
    .{ .name = "dock-toggle-2x", .contract = "도크 토글 판이 2x 띠(56px)에서 멈춘다 — 예전에는 59px 로 3px 샜다(#4410)", .rect = x2(dock_1x) },
};

test "헤더·접힌 ◧·도크 토글 hover 판이 골든과 같다 (1x·2x)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const update = std.c.getenv("MARU_UPDATE_GOLDEN") != null;
    const require_captures = std.c.getenv("MARU_REQUIRE_GOLDEN") != null;

    var checked: usize = 0;
    var mismatches: usize = 0;
    for (cases) |case| {
        var capture_buf: [256]u8 = undefined;
        const capture_path = try std.fmt.bufPrint(&capture_buf, "{s}/{s}.ppm", .{ capture_root, case.name });
        const capture_bytes = std.Io.Dir.cwd().readFileAlloc(io, capture_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                if (require_captures) {
                    std.debug.print("hover 캡처가 없다: {s} — `sh tools/header-hover/capture.sh` 가 실패했는가?\n", .{capture_path});
                    return error.HeaderHoverCaptureMissing;
                }
                continue;
            },
            else => return err,
        };
        defer allocator.free(capture_bytes);

        // 낡은 그림으로 통과하지 않는다 — 원격 SCM 게이트와 같은 이유(그 초록은 「지금 화면을 확인했다」는 거짓말이다).
        if (stalerThan(io, capture_path)) |producer| {
            std.debug.print("캡처가 낡았다: {s} 가 그림보다 나중이다 — 다시 찍어라:\n  mise run macos-header-hover-visual-golden\n", .{producer});
            return error.HeaderHoverCaptureStale;
        }

        var frame = try ppm.decodeP6(allocator, capture_bytes);
        defer frame.deinit(allocator);
        const scale: u32 = if (std.mem.endsWith(u8, case.name, "-2x")) 2 else 1;
        if (frame.width != frame_1x_w * scale or frame.height != frame_1x_h * scale) {
            std.debug.print(
                "창 크기가 다르다: {s} — 캡처 {d}x{d}, 기대 {d}x{d}. 사각형이 엉뚱한 자리를 볼 것이라 비교하지 않는다\n" ++
                    "  (상위 환경의 창 크기 변수가 흘러들었거나 기본 창 크기가 바뀌었다 — 바뀌었으면 rect 와 이 값을 함께 갱신하라)\n",
                .{ case.name, frame.width, frame.height, frame_1x_w * scale, frame_1x_h * scale },
            );
            mismatches += 1;
            continue;
        }
        var window = try ppm.crop(allocator, frame, case.rect); // 크기를 위에서 봤으므로 사각형은 늘 안이다
        defer window.deinit(allocator);

        var golden_buf: [256]u8 = undefined;
        const golden_path = try std.fmt.bufPrint(&golden_buf, "{s}/{s}.ppm", .{ golden_root, case.name });
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
                std.debug.print("golden 이 없다: {s} (MARU_UPDATE_GOLDEN=1 로 만들고 눈으로 확인한 뒤 커밋하라)\n", .{golden_path});
                return err;
            },
            else => return err,
        };
        defer allocator.free(golden_bytes);
        var golden = try ppm.decodeP6(allocator, golden_bytes);
        defer golden.deinit(allocator);

        const diff = ppm.compare(golden, window, channel_tolerance) catch |err| {
            std.debug.print("golden 크기가 캡처와 다르다: {s} — {s}\n", .{ case.name, @errorName(err) });
            mismatches += 1;
            continue;
        };
        if (diff.differing_pixels != 0) {
            // 첫 실패에서 멈추지 않고 전부 본다 — 한 번에 어느 장들이 갈렸는지 알아야 원인을 가른다.
            std.debug.print(
                "hover 골든이 어긋났다: {s} — 다른 픽셀 {d}개, 최대 채널 차이 {d} (첫 자리 {d},{d})\n  계약: {s}\n",
                .{ case.name, diff.differing_pixels, diff.max_channel_delta, diff.first_x, diff.first_y, case.contract },
            );
            mismatches += 1;
        }
        checked += 1;
    }
    if (mismatches > 0) {
        std.debug.print("  캡처를 다시 찍었는지 먼저 보라: zig build macos-app-bundle && sh tools/header-hover/capture.sh ./zig-out/Maru.app/Contents/MacOS/maru-macos-app\n", .{});
        return error.HeaderHoverGoldenMismatch;
    }
    // 전부 없으면 이 게이트는 아무것도 안 지킨다 — 그 사실을 초록으로 숨기지 않는다.
    if (checked == 0) return error.SkipZigTest;
    // 캡처를 요구하는 곳(mise·CI)에서는 **모든 장**을 봤어야 한다 — 몇 장만 남은 디렉터리로 초록을 내지 않는다.
    if (require_captures) try std.testing.expectEqual(@as(usize, cases.len), checked);
}
