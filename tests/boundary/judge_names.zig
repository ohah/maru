//! 판정자 파일 이름의 **원장** — 작업 슬라이스 ID 로 이름 붙은 것은 줄어들기만 한다.
//!
//! **왜 있나.** [파일·폴더 네이밍 컨벤션](../docs/project-structure.md)은 「폴더가 domain,
//! 파일명이 그 안의 한 책임을 표현한다」고 정한다. 제품은 그 규칙을 거의 다 지키는데
//! (`src/platform/macos/session_host/` 393 개 중 슬라이스 ID 이름은 12 개, 3%) 판정자는
//! 처음 셀 때 **108 개**가 `session_host_2d1_boundary.zig` 처럼 **그걸 만든 작업 회차**로 이름이
//! 붙어 있었다. 슬라이스 ID 는 책임이 아니라 이력이라, 구현이 끝나면 파일명이 아무것도 안 알려준다.
//!
//! **지금 남은 수는 아래 `expected_entries` 가 단일 출처다** — 여기 산문에 수를 또 적으면 갈린다.
//!
//! **규칙만 적어 두면 안 지켜진다.** 그래서 지금 있는 것을 목록으로 못 박고, 그 목록에 **없는**
//! 파일이 슬라이스 ID 이름이면 여기서 빨개진다. 목록은 도메인을 만질 때 한 줄씩 빠지고
//! (컨벤션이 정한 「점진적으로」), 늘지는 않는다.
//!
//! **고칠 때**: 파일을 주제 이름으로 옮겼으면 아래 목록에서 그 줄을 지우고 `expected_entries`
//! 를 하나 줄인다. 두 자리를 같이 고쳐야 하는 것이 의도다 — 줄어드는 것은 의식적인 행위다.

const std = @import("std");

/// 「숫자와 글자가 섞인 짧은 토큰」이지만 **주제어**인 것들.
///
/// 데이터에서 뽑아 손으로 골랐다 — 판정자 파일명에 실제로 나오는 그런 토큰 80 가지를 전부
/// 훑어 이 넷만 주제였다. **안 나오는 말을 미리 넣지 않는다**(`utf8`·`osc52` 같은 것도
/// 주제어지만 지금 파일명에 없다). 새 파일이 걸리면 그때 한 줄 더한다 — 그 되먹임이
/// 규칙을 좁게 유지한다.
const subject_words = [_][]const u8{ "a11y", "e2e", "stage3", "i18n" };

/// 슬라이스 ID 로 이름 붙은 판정자 — **줄어들기만 한다.**
const slice_named = [_][]const u8{
    "tests/fixtures/session_host_pre_p5b3_v2.zig",
    "tests/fixtures/session_host_pre_p5b3_v2_provenance.zig",
    "tests/session_host_2b2e_integration_sentinel.zig",
    "tests/session_host_2b3_sentinel.zig",
    "tests/session_host_2c4_boundary.zig",
    "tests/session_host_2d1_boundary.zig",
    "tests/session_host_2d2_boundary.zig",
    "tests/session_host_2d3_boundary.zig",
    "tests/session_host_2e_boundary.zig",
    "tests/session_host_3a1_boundary.zig",
    "tests/session_host_3a1_sentinel.zig",
    "tests/session_host_3a2_boundary.zig",
    "tests/session_host_3a2_sentinel.zig",
    "tests/session_host_3b_boundary.zig",
    "tests/session_host_3b_sentinel.zig",
    "tests/session_host_3d_boundary.zig",
    "tests/session_host_3d_e2e.zig",
    "tests/session_host_3d_product_e2e.zig",
    "tests/session_host_cr0b_boundary.zig",
    "tests/session_host_cr2_boundary.zig",
    "tests/session_host_cr2e_generation_slot.zig",
    "tests/session_host_cr2e_mutation.zig",
    "tests/session_host_cr2e_reducer.zig",
    "tests/session_host_cr3c_c1_boundary.zig",
    "tests/session_host_cr3c_c2_boundary.zig",
    "tests/session_host_cr4a_boundary.zig",
    "tests/session_host_cr4b_boundary.zig",
    "tests/session_host_cr4c_c1_boundary.zig",
    "tests/session_host_cr4c_c2_boundary.zig",
    "tests/session_host_cr5a_boundary.zig",
    "tests/session_host_cr5b1_boundary.zig",
    "tests/session_host_cr5b2a_boundary.zig",
    "tests/session_host_cr5b2b_boundary.zig",
    "tests/session_host_cr5b2c_boundary.zig",
    "tests/session_host_cr5c_boundary.zig",
    "tests/session_host_cr5d1_boundary.zig",
    "tests/session_host_cr5d2_boundary.zig",
    "tests/session_host_cr6a1_boundary.zig",
    "tests/session_host_cr6a2_boundary.zig",
    "tests/session_host_cr6b_boundary.zig",
    "tests/session_host_cr6d_boundary.zig",
    "tests/session_host_cr6d_pixel.zig",
    "tests/session_host_cr6f_boundary.zig",
    "tests/session_host_cr6f_idle_soak_boundary.zig",
    "tests/session_host_p4_r3_screen_inbox_boundary.zig",
    "tests/session_host_s11_6_narrowed_boundary.zig",
    "tests/support/session_host_cr6d_pixel.zig",
};

/// 목록 길이. 줄을 지우면 이 수도 함께 줄여야 한다.
const expected_entries: usize = 47;

/// 파일명 한 토막이 슬라이스 ID 인가 — **숫자와 글자가 섞였고 주제어가 아니면** 그렇다.
/// `v1`·`v2` 는 픽스처의 버전 표시라 뺀다.
fn isSliceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (subject_words) |w| if (std.mem.eql(u8, w, token)) return false;
    if (token[0] == 'v' and token.len >= 2) {
        var all_digits = true;
        for (token[1..]) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
        };
        if (all_digits) return false;
    }
    var has_digit = false;
    var has_alpha = false;
    for (token) |c| {
        if (std.ascii.isDigit(c)) has_digit = true;
        if (std.ascii.isAlphabetic(c)) has_alpha = true;
    }
    return has_digit and has_alpha;
}

fn sliceNamed(stem: []const u8) bool {
    var it = std.mem.splitScalar(u8, stem, '_');
    while (it.next()) |token| if (isSliceToken(token)) return true;
    return false;
}

fn inLedger(path: []const u8) bool {
    for (slice_named) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

test "원장은 줄어들기만 한다 — 개수를 못 박는다" {
    try std.testing.expectEqual(expected_entries, slice_named.len);
}

test "원장의 모든 줄은 실재하는 파일이다 — 이름을 옮기면 그 줄도 빠진다" {
    const io = std.testing.io;
    var missing: usize = 0;
    for (slice_named) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.debug.print("원장에 있으나 없는 파일: {s}\n", .{path});
            missing += 1;
            continue;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "원장에 없는 판정자는 슬라이스 ID 로 이름 붙이지 않는다" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var offenders: std.ArrayList([]const u8) = .empty;
    defer {
        for (offenders.items) |o| allocator.free(o);
        offenders.deinit(allocator);
    }

    // `tests/` 를 통째로 걷는다 — 하위 폴더(`boundary`·`support`·`fixtures`)도 같은 규칙이다.
    var seen: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        seen += 1;
        const stem = entry.basename[0 .. entry.basename.len - 4];
        if (!sliceNamed(stem)) continue;
        const full = try std.fmt.allocPrint(allocator, "tests/{s}", .{entry.path});
        if (inLedger(full)) {
            allocator.free(full);
            continue;
        }
        try offenders.append(allocator, full);
    }

    // **0 개를 세고도 초록이 되지 않게** — 걷기가 깨지면 위반도 0 이 된다.
    try std.testing.expect(seen >= 400);

    for (offenders.items) |o| {
        std.debug.print(
            "슬라이스 ID 이름의 새 판정자: {s}\n" ++
                "  파일명은 «그 안의 한 책임»을 표현한다(docs/project-structure.md).\n" ++
                "  작업 회차 ID 대신 무엇을 지키는지로 이름 짓는다.\n",
            .{o},
        );
    }
    try std.testing.expectEqual(@as(usize, 0), offenders.items.len);
}
