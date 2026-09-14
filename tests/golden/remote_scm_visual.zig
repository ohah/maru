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
//! | 도크 열 + 경계선 `x∈[778,960)` | 0 **또는 506**(아래) |
//! | 도크 열 `x∈[779,960) y∈[60,575)` | **0** |
//!
//! 프레임의 차이는 터미널 pane(로그인 줄의 시각·tty, 원격 강제가 echo 한 임시 경로)과 상태바(메모리·
//! CPU)에서 나온다 — 그것들은 이 게이트가 보려는 계약이 아니다. 도크 열만 잘라 **0 픽셀**을 고정한다.
//!
//! ⚠️ **왼쪽 끝 한 열(`x=778`)은 도크가 아니라 터미널↔도크 divider 다 — 빼야 한다**(적대적 검증
//! 18 회차). 처음에는 그 열을 포함해 두 번 찍어 0 픽셀을 봤는데, 그것은 **운이었다**: 나중에 같은
//! 명령이 `(90,90,90)`(밝은 선)과 `(16,16,16)`(꺼진 선)으로 갈렸고 **정확히 그 한 열만, 506 행 전부**
//! 달랐다. 한 줄짜리 세로선이라 눈으로는 「회귀」로 보이고, 실제로 한 번 그렇게 보고 재현으로 귀책해야
//! 했다. 그 열은 이 게이트가 보려는 계약(도크가 무엇을 그리나)에 속하지 않으므로 crop 에서 제외한다.
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
///
/// **아래 끝을 브랜치 줄까지 내렸다**(2026-09-14). 그 전에는 `h = 500` 이라 목록만 담았는데, 히스토리
/// 탭이 「어느 기계인가」를 그 줄에 적게 되면서 **골든이 반쪽만 보는** 상태가 됐다. 실측으로 그 줄은
/// `y≈548..573` 이고 상태바는 `y≈581` 부터라, 575 가 둘 사이다(그 구간도 두 번 찍어 0 픽셀로 확인).
const dock_column: ppm.Rect = .{ .x = 779, .y = 60, .w = 181, .h = 515 };

/// **이 그림을 만든 것들.** 캡처보다 나중에 바뀐 것이 하나라도 있으면 그 그림은 **지금 것이 아니다.**
///
/// ⚠️ **여기에 앱 실행 파일이 들어 있는 것이 핵심이다.** 이웃 게이트(`dock_visual.zig`)는 시나리오
/// 소스 둘만 보고 「그 밖의 변경으로 캡처가 낡는 경우는 못 잡는다」를 한계로 적어 뒀는데, 이 캡처는
/// **실행 파일이 직접 그린다** — 도크 렌더든 원격 읽기든 앱을 다시 빌드하면 그 파일의 mtime 이 움직인다.
/// 그래서 소스 목록보다 좁고 정확하다.
const capture_producers = [_][]const u8{
    "zig-out/Maru.app/Contents/MacOS/maru-macos-app",
    "tools/remote-scm/capture.sh",
    "tools/remote-scm/capture_inner.sh",
};

/// 캡처가 생산자보다 **먼저** 만들어졌나 — 순수 판정(시각만 받는다).
fn captureIsStale(capture_ns: i128, newest_producer_ns: i128) bool {
    return capture_ns < newest_producer_ns;
}

test "낡은 캡처는 낡았다고 판정한다" {
    // **실측으로 확인한 구멍**(적대적 검증 2026-09-14): 캡처 파일의 mtime 을 2020 년으로 돌려 놓아도
    // 이 게이트가 **초록**이었다. 골든과 같기만 하면 통과하므로, 6 년 묵은 그림으로 「지금 코드의
    // 화면을 확인했다」고 말하게 된다. 이웃 게이트가 사흘 묵은 캡처를 「회귀」로 오판한 것과 같은 축이다.
    try std.testing.expect(captureIsStale(100, 200)); // 캡처가 먼저 = 낡았다
    try std.testing.expect(!captureIsStale(200, 100)); // 캡처가 나중 = 신선하다
    try std.testing.expect(!captureIsStale(100, 100)); // 같은 시각은 낡은 것이 아니다
}

/// 캡처가 생산자보다 낡았으면 **가장 최근 생산자의 이름**을 돌려준다(아니면 `null`). stat 이 안 되는
/// 생산자는 건너뛴다 — 없는 파일 때문에 게이트를 못 돌게 하지 않는다.
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

const Case = struct {
    name: []const u8,
    rect: ppm.Rect,
};

const cases = [_]Case{
    // 원격 히스토리 목록 + 맨 위 커밋을 펼친 화면. 이 한 장이 RS7 의 화면 계약을 전부 지난다:
    // 커밋 넷이 서고(RS7b), 브랜치 칩이 붙고, 펼친 커밋의 파일 줄이 그 기계에서 온다(RS7c),
    // 그리고 맨 아래 줄이 **어느 기계에서 읽었나**를 적는다(§2.3).
    .{ .name = "history-expanded", .rect = dock_column },
    // 원격 에이전트 탭. **한 줄로 끝나는 것**이 계약이다 — 로컬 세션의 턴이 그 자리에 남으면
    // 「이 기계의 기록」으로 읽힌다(§18.6). 이 장은 「없다」가 아니라 **「아직 안 된다」**를 고정한다.
    .{ .name = "agent-remote-unsupported", .rect = dock_column },
};

// ⚠️ **여기 없는 장 하나 — 「연결이 끊긴 원격 pane」**(적대적 검증 2026-09-14).
//
// `ControlPersist` 만료·네트워크 끊김에서 사용자가 실제로 보는 화면이라 값어치가 큰데, **캡처가
// 결정적이지 않다.** 원격 강제는 OSC 를 셸에 타이핑해 보내고 2 초마다 다시 시도하므로, 화면이
// 「로컬 → (통지 도착) → 연결 끊김」으로 **넘어가는 도중**에 찍힐 수 있다. 실측(같은 명령 3 회):
// 두 장은 0 픽셀로 같았고 한 장이 63 픽셀 달랐다.
//
// 그래서 **넣지 않는다** — 가끔 빨개지는 장 하나가 게이트 전체의 신뢰를 깎는다. 그 화면의 계약은
// 대신 순수 판정자가 문다(`연결이 끊긴 원격 pane 은 …`, `app_session.zig`). 넣으려면 먼저 강제 통지가
// **언제 도착했는지**를 캡처가 알 수 있어야 한다(지금은 알 방법이 없다).

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

        // ⚠️ **낡은 그림으로 통과하지 않는다.** `zig-out` 의 캡처는 코드를 고쳐도 저절로 안 바뀐다 —
        // 그대로 두면 이 게이트는 **지금 코드와 무관한 그림**을 골든과 비교하고, 같으면 초록을 낸다.
        // 그 초록은 「지금 화면을 확인했다」는 **가장 그럴듯한 거짓말**이다. 이웃 게이트는 그 사실을
        // 알려만 주는데(경고), 여기서는 **실패로 만든다** — 다시 찍는 길이 한 줄이기 때문이다.
        if (stalerThan(io, capture_path)) |producer| {
            std.debug.print(
                "캡처가 낡았다: {s} 가 그림보다 나중이다 — 다시 찍어라:\n  mise run macos-remote-scm-visual-golden\n",
                .{producer},
            );
            return error.RemoteScmCaptureStale;
        }

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
