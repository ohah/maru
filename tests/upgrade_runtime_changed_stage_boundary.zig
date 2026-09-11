//! **업그레이드가 `runtime_changed` 로 접혔을 때 어느 갈래였는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 실측 — 세션 19 개를 쥔 host 가 `result=upgrade_failed … reason=runtime_changed` 로 접혔다.
//! 세션은 안전했다(`status=resumed`). 그런데 **왜** 접혔는지는 알 길이 없었다. 그 host 의 로그 11971 B 는
//! 시작 한 줄과 client 연결 줄이 전부였고, 업그레이드에 관한 줄은 **하나도** 없었다.
//!
//! 이유는 단순하다. `noteUpgradeStage` 라는 기구가 이미 있고 `host-<id>.log` 로 나가는데, **일곱 개의
//! `runtime_changed` 산출 지점이 하나도 그것을 부르지 않았다.** 그래서 성격이 전혀 다른 일곱 갈래가
//! 하나의 wire reason 으로 접혀 구분 불가능해졌다:
//!
//!   - freeze 전 authority 가 ready 가 아님 (환경 문제)
//!   - freeze 전후로 authority 가 바뀜 (경합)
//!   - 예약 예산과 실제 handoff 불일치 (크기 문제)
//!   - handoff 직후 capture 재검증 실패 (자식 graph 변화)
//!   - exec 직전 capture 재검증 실패 (같은 이유, 다른 시점)
//!   - freeze 에러의 `else` (삼킨 에러)
//!   - capture 에러의 `else` (삼킨 에러)
//!
//! 앞의 셋은 재시도하면 풀릴 수 있고, 뒤의 넷은 반복될 수 있다. 구분이 안 되면 **재시도할 가치가 있는
//! 실패인지조차** 판단할 수 없다. 그리고 이 실패는 그냥 넘어가지 않는다 — 실패하면 `host_connect` 가
//! 빈 host 를 폴백으로 띄우고, 그 빈 host 가 설치본과 같은 build_id 로 manifest 를 publish 해 다음
//! 실행부터 업그레이드 스캔 자체를 가린다. 한 번의 불투명한 실패가 영구화된다.
//!
//! ## 이 판정자가 고정하는 것
//!
//! 문자열이 있는지가 아니라 **구조**를 본다 — 모든 `runtime_changed` 산출 지점은 직전 몇 줄 안에서
//! 스테이지를 남겨야 한다. 나중에 새 산출 지점이 조용히 늘어도 여기서 빨개진다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/upgrade_product_coordinator.zig";
const max_source_bytes = 8 * 1024 * 1024;

/// 산출 지점과 그 앞 스테이지 사이에 허용하는 줄 간격. 실측 최대는 3 줄이다(예산 불일치·재검증).
/// 넉넉히 잡되, 「같은 함수 어딘가」로 늘어나 판정이 무의미해지지 않을 만큼은 좁게 둔다.
const max_lines_back: usize = 6;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말이 옛 모습을 인용하므로, 벗기지 않으면 「설명하는 주석」이
/// 「쓰는 코드」로 세어진다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

test "모든 runtime_changed 산출 지점은 어느 갈래였는지 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);
    const lines = try splitLines(a, src);
    defer a.free(lines);

    // ① 산출 지점마다 직전에 스테이지가 있어야 한다. **이것이 이 판정자의 본체다** — 문자열 목록과
    //    달리, 나중에 조용한 산출 지점이 새로 늘어도 잡힌다.
    var producers: usize = 0;
    for (lines, 0..) |line, i| {
        if (std.mem.indexOf(u8, line, "runtime_changed") == null) continue;
        producers += 1;
        var back: usize = 0;
        const found = while (back < max_lines_back and back <= i) : (back += 1) {
            if (std.mem.indexOf(u8, lines[i - back], "noteUpgradeStage") != null) break true;
        } else false;
        if (!found) {
            std.debug.print(
                "침묵하는 runtime_changed 산출 지점 — {s}:{d}: {s}\n",
                .{ source_path, i + 1, std.mem.trim(u8, line, " ") },
            );
            return error.SilentRuntimeChangedSite;
        }
    }

    // ② 산출 지점이 실제로 있었는지 — 0 개면 ①의 루프가 공회전해 통과한다(빈 진공 통과 방지).
    try std.testing.expect(producers >= 7);

    // ③ 일곱 갈래가 **서로 다른 이름**을 쓴다. 같은 이름으로 뭉치면 로그가 있어도 갈리지 않는다.
    for ([_][]const u8{
        "ready_authority_not_ready",
        "authority_changed_across_freeze",
        "budget_reservation_mismatch",
        "capture_revalidate_post_handoff",
        "capture_revalidate_pre_exec",
        "freeze_error",
        "capture_error",
    }) |label| {
        var seen: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, label)) |found| : (at = found + label.len) seen += 1;
        if (seen != 1) {
            std.debug.print("스테이지 라벨 «{s}» 이 {d} 번 — 정확히 1 번이어야 한다\n", .{ label, seen });
            return error.StageLabelNotUnique;
        }
    }

    // ④ `else =>` 가 삼킨 에러는 **이름까지** 남긴다. 스테이지만 남기면 「그 밖의 무엇」이 그대로 남는다.
    //    이 파일에는 무관한 `@errorName` 이 이미 있으므로(rollback 경로), 그것에 기대면 판정이 헐거워진다 —
    //    헬퍼의 포맷 문자열 자체를 고정한다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "session host upgrade stage failed: stage={s} err={s}",
    ) != null);

    // ⑤ 고쳐 두었던 조용한 옛 모습이 되살아나면 빨개진다.
    for ([_][]const u8{
        "        else => .{ .status = .resumed, .reason = .runtime_changed },",
        "    ctx.manager.revalidateQuiescedCapture(&capture) catch\n",
    }) |gone| try std.testing.expect(std.mem.indexOf(u8, src, gone) == null);
}
