//! 원격 SCM 시각 골든 게이트.
//!
//! 무엇을 증명하는가: `tools/remote-scm/capture.sh` 가 **실물 sshd 위에서 제품 Metal 경로**로 남긴
//! 프레임의 도크 열이, 커밋된 골든과 픽셀 단위로 같은지.
//!
//! **왜 이 축만 따로 있나**: 이웃 게이트(`dock_visual.zig`)는 Chrome Lab 의 결정론적 시나리오를 본다 —
//! 거기에는 원격이 없다. 원격 히스토리는 실물 sshd·control socket·원격 저장소가 **동시에** 있어야
//! 화면이 서므로 Lab 으로는 세울 수 없고, 그래서 RS7 전체가 「사람이 눈으로 보는 것」으로 남아 있었다.
//!
//! ## 무엇을 고정해 골든이 가능해졌나
//!
//! 캡처에는 실행마다 달라지는 것이 셋 있었다. 스크립트가 그 셋을 박는다(`capture_inner.sh`):
//!
//!  1. **커밋 SHA** — 신원·시각을 고정하면 같은 트리가 같은 SHA 를 낸다. 하니스의 `seed` 커밋은 시각이
//!     안 박혀 있어 그 이력을 쓰지 않고 저장소를 처음부터 다시 세운다.
//!  2. **상대시각** — `방금`/`N분 전`은 찍는 순간에 달렸다. 제품이 **미래 시각을 `방금`으로 접으므로**
//!     커밋 시각을 미래로 박으면 언제 찍어도 `방금`이다.
//!  3. **기본 브랜치 이름** — `init.defaultBranch` 는 기계마다 다르다. `-b main` 으로 박는다.
//!
//! ## 왜 프레임 전체가 아니라 도크 열인가
//!
//! 나머지가 결정적이지 않기 때문이다. **실측(2026-09-14, 같은 트리에서 두 번 찍어 비교)**:
//!
//! | 영역 | 다른 픽셀 |
//! |---|---|
//! | 프레임 전체 960×600 | 959 |
//! | 도크 열 `x∈[778,960) y∈[60,560)` | **0** |
//!
//! 프레임의 차이는 터미널 pane(로그인 줄의 시각·tty, 원격 강제가 echo 한 임시 경로)과 상태바(메모리·
//! CPU)에서 나온다 — 그것들은 이 게이트가 보려는 계약이 아니다. 도크 열만 잘라 **0 픽셀**을 고정한다.
//!
//! 골든 갱신: `MARU_UPDATE_GOLDEN=1` (이웃 게이트와 같은 관례). 갱신 뒤에는 **반드시 눈으로 확인**하고
//! 커밋한다 — 자동 갱신은 회귀를 골든으로 굳힌다.
//!
//! 캡처가 없으면 건너뛴다(캡처는 macOS·실물 sshd 를 요구하므로 CI 에서 안 돈다). `MARU_REQUIRE_GOLDEN=1`
//! 이면 부재를 실패로 만든다 — `mise run macos-remote-scm-visual-golden` 이 그 값을 켠다.

const std = @import("std");
const ppm = @import("ppm");

const capture_root = "zig-out/remote-scm-capture";
const golden_root = "tests/fixtures/golden/remote-scm";

/// 이웃 게이트와 같은 값·같은 근거(같은 기기에서는 결정적이지만 러너가 바뀌면 rasterizer 미세 차이).
/// **잡음 예산은 두지 않는다** — 실측이 0 픽셀이므로 관용을 넓힐 근거가 없다.
const channel_tolerance: u8 = 2;

/// 도크 열. 프레임의 나머지는 결정적이지 않다(위 표).
const dock_column: ppm.Rect = .{ .x = 778, .y = 60, .w = 182, .h = 500 };

const Case = struct {
    name: []const u8,
    rect: ppm.Rect,
};

const cases = [_]Case{
    // 원격 히스토리 목록 + 맨 위 커밋을 펼친 화면. 이 한 장이 RS7 의 화면 계약을 전부 지난다:
    // 커밋 넷이 서고(RS7b), 브랜치 칩이 붙고, 펼친 커밋의 파일 줄이 그 기계에서 온다(RS7c).
    .{ .name = "history-expanded", .rect = dock_column },
};

test "원격 SCM 도크 열이 골든과 같다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const update = std.c.getenv("MARU_UPDATE_GOLDEN") != null;
    const require_captures = std.c.getenv("MARU_REQUIRE_GOLDEN") != null;

    var checked: usize = 0;
    for (cases) |case| {
        var capture_buf: [256]u8 = undefined;
        const capture_path = try std.fmt.bufPrint(&capture_buf, "{s}/{s}.ppm", .{ capture_root, case.name });
        const capture_bytes = std.Io.Dir.cwd().readFileAlloc(io, capture_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                if (require_captures) {
                    std.debug.print(
                        "원격 SCM 캡처가 없다: {s} — `sh tools/remote-scm/capture.sh` 가 실패했는가?\n",
                        .{capture_path},
                    );
                    return error.RemoteScmCaptureMissing;
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
                "crop 이 캡처 밖이다: {s} (캡처 {d}x{d}, 요청 {d},{d} {d}x{d}) — 창 크기가 바뀌었으면 rect 를 갱신하라\n",
                .{ case.name, frame.width, frame.height, case.rect.x, case.rect.y, case.rect.w, case.rect.h },
            );
            return err;
        };
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
                std.debug.print(
                    "golden 이 없다: {s} (MARU_UPDATE_GOLDEN=1 로 만들고 눈으로 확인한 뒤 커밋하라)\n",
                    .{golden_path},
                );
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
                "원격 SCM 골든이 어긋났다: {s} — 다른 픽셀 {d}개, 최대 채널 차이 {d} (첫 자리 {d},{d})\n",
                .{ case.name, diff.differing_pixels, diff.max_channel_delta, diff.first_x, diff.first_y },
            );
            std.debug.print(
                "  캡처를 **다시 찍었는지** 먼저 보라 — `zig-out` 의 그림은 코드를 고쳐도 저절로 안 바뀐다:\n" ++
                    "  zig build macos-app-bundle && sh tools/remote-scm/capture.sh {s}/{s}.png MARU_FORCE_SCM_COMMIT_EXPAND=0\n",
                .{ capture_root, case.name },
            );
            return error.RemoteScmGoldenMismatch;
        }
        checked += 1;
    }

    // **전부 없으면 이 게이트는 아무것도 안 지킨다.** 그 사실을 초록으로 숨기지 않는다.
    if (checked == 0) return error.SkipZigTest;
}
