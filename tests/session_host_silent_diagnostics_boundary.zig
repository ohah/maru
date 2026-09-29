//! **로그 없이 끝나던 세 자리**가 다시 조용해지지 않는지 못 박는다.
//!
//! ## 무엇이 있었나 (2026-09-29, 하루에 셋)
//!
//! 1. **업그레이드 `handoff_failed`** — 세션 13 개를 쥔 host 의 업그레이드가 `status=resumed
//!    reason=handoff_failed` 로 세 번 접혔는데 host 로그에 단계 줄이 **한 줄도** 없었다. 원인(승계 루프가
//!    manifest 를 경로로 찍어 ctime 이 바뀌어 `begin_restoring` 의 identity 대조가 실패)은 코드와 파일 시각으로
//!    추론해야 했다. `handoff_failed` 산출 지점 열네 곳 중 일곱이 단계를 남기지 않았고, authority 쪽은 에러를
//!    `else => .unchanged_retryable` 로 삼켰다.
//! 2. **host 자연 종료** — 새 빌드 host 셋이 12 분 간격으로 종료 로그 없이 사라졌다. 소켓·manifest 까지 정상
//!    정리돼 사고처럼 보였지만 전부 설계된 자연 종료였다. 그 판정이 break 하는 자리에 로그가 없었다.
//! 3. **spawn 재시도의 거짓 폴백 줄** — 죽은 spawn host 에 쓰다 실패하면 `createTerm` 이 **재시도 전에**
//!    `runtime_death` 를 기록해 error 로 「in-process 로 폴백」을 찍었다. 재시작이 곧바로 성공해도 그 줄은
//!    남았다 — 폴백하지 않았는데 로그는 폴백했다고 말했다.
//!
//! 셋 다 **동작은 맞았고 로그가 틀렸다.** 그래서 진단하는 사람이 엉뚱한 곳을 팠다(구현 에이전트가 정상 종료를
//! 사고로 보고 작업을 멈췄다).
//!
//! ## 이 판정자가 고정하는 것
//!
//! 문자열 목록이 아니라 **문법 자리**를 본다 — 주석을 걷고, 테스트 블록을 빼고, 산출 지점·분기 블록에 닻을
//! 내린다. 나중에 조용한 산출 지점이 새로 늘거나 로그를 주석으로 가려도 빨개진다.

const std = @import("std");

const coordinator_path = "src/platform/macos/session_host/upgrade_product_coordinator.zig";
const daemon_path = "src/platform/macos/session_host/daemon.zig";
const term_path = "src/platform/macos/app_session/term.zig";
const max_source_bytes = 8 * 1024 * 1024;

/// 산출 지점과 그 앞 단계 기록 사이에 허용하는 줄 간격. 실측 최대는 3 줄이다(`finishBeforeFreeze(…, .{`
/// 여러 줄 구조체). 「같은 함수 어딘가」로 늘어나 판정이 무의미해지지 않게 좁게 둔다.
const max_lines_back: usize = 4;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 걷는다. 문자열 안의 `//` 는 주석이 아니므로 건드리지 않는다. 주석을 남기면 「설명하는 주석」이
/// 「쓰는 코드」로 세어지고, 로그 호출을 `//` 로 가려도 판정이 통과한다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        var in_string = false;
        var cut: usize = line.len;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            if (in_string) {
                if (ch == '\\') {
                    i += 1;
                } else if (ch == '"') in_string = false;
                continue;
            }
            if (ch == '"') {
                in_string = true;
            } else if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
                cut = i;
                break;
            }
        }
        try out.appendSlice(allocator, line[0..cut]);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// 최상위 `test "…" {` 블록을 뺀 제품 코드만 남긴다(줄 수는 보존 — 빈 줄로 채운다).
fn blankTopLevelTests(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_test = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (!in_test and std.mem.startsWith(u8, line, "test \"")) in_test = true;
        if (!in_test) try out.appendSlice(allocator, line);
        if (in_test and std.mem.eql(u8, line, "}")) in_test = false;
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn productSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try read(allocator, path);
    defer allocator.free(raw);
    const stripped = try stripComments(allocator, raw);
    defer allocator.free(stripped);
    return blankTopLevelTests(allocator, stripped);
}

/// `open` 이 `{` 를 가리킬 때 짝이 맞는 `}` 까지의 블록(양끝 포함)을 돌려준다. 문자열 안의 괄호는 센다
/// 대상이 아니다(`"{s}"` 같은 포맷 문자열).
fn braceBlock(src: []const u8, open: usize) ?[]const u8 {
    if (open >= src.len or src[open] != '{') return null;
    var depth: usize = 0;
    var in_string = false;
    var i = open;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[open .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// `anchor` 바로 뒤(공백만 건너뛰고)에 `{` 가 와야 한다 — 한 줄짜리 `)) break;` 같은 옛 모양이면 null.
fn blockRightAfter(src: []const u8, anchor_end: usize) ?[]const u8 {
    var i = anchor_end;
    while (i < src.len and (src[i] == ' ' or src[i] == '\n')) : (i += 1) {}
    return braceBlock(src, i);
}

/// `start` 가 `(` 를 가리킬 때 짝 괄호 바로 뒤 위치.
fn afterMatchingParen(src: []const u8, start: usize) ?usize {
    if (src[start] != '(') return null;
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| : (at = found + needle.len) n += 1;
    return n;
}

test "업그레이드의 모든 handoff_failed 산출 지점은 어느 단계였는지 남긴다" {
    const a = std.testing.allocator;
    const src = try productSource(a, coordinator_path);
    defer a.free(src);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| try lines.append(a, line);

    // ① 본체: 제품 코드에서 `handoff_failed` 를 내는 줄마다 직전 몇 줄 안에 단계 기록이 있다. 산출 지점을
    //    목록으로 적지 않고 **그 이름이 나오는 모든 줄**을 산출 지점으로 본다 — 새 모양(헬퍼 반환·switch arm)이
    //    늘어도 잡힌다. 테스트 헬퍼의 단언(`std.testing`)만 뺀다.
    var producers: usize = 0;
    for (lines.items, 0..) |line, i| {
        if (std.mem.indexOf(u8, line, "handoff_failed") == null) continue;
        if (std.mem.indexOf(u8, line, "std.testing") != null) continue;
        producers += 1;
        var back: usize = 0;
        const found = while (back < max_lines_back and back <= i) : (back += 1) {
            if (std.mem.indexOf(u8, lines.items[i - back], "noteUpgradeStage") != null) break true;
        } else false;
        if (!found) {
            std.debug.print(
                "침묵하는 handoff_failed 산출 지점 — {s}:{d}: {s}\n",
                .{ coordinator_path, i + 1, std.mem.trim(u8, line, " ") },
            );
            return error.SilentHandoffFailedSite;
        }
    }
    // ② 빈 진공 통과 방지 — 산출 지점이 사라지면 ①이 공회전한다(2026-09-29 기준 14 곳).
    try std.testing.expect(producers >= 14);

    // ③ 단계 이름이 **서로 다르다**. 같은 이름으로 뭉치면 로그가 있어도 갈리지 않는다. 따옴표째 세어
    //    `.exec_failed` 같은 wire reason 과 헷갈리지 않는다.
    for ([_][]const u8{
        "\"unexpected_inherited_fd\"",
        "\"fd_slot_reserve\"",
        "\"rollback_image_revalidate_pre_freeze\"",
        "\"attempt_record_build\"",
        "\"handoff_encode\"",
        "\"rollback_image_revalidate_post_freeze\"",
        "\"authority_begin_restoring\"",
        "\"replace_all\"",
        "\"non_cloexec_assert\"",
        "\"rollback_image_revalidate_pre_exec\"",
        "\"exec_prepare_out_of_memory\"",
        "\"handoff_store_commit\"",
        "\"budget_prepare\"",
        "\"exec_failed\"",
    }) |label| {
        const seen = count(src, label);
        if (seen != 1) {
            std.debug.print("단계 라벨 {s} 이 {d} 번 — 정확히 1 번이어야 한다\n", .{ label, seen });
            return error.StageLabelNotUnique;
        }
    }

    // ④ authority 전이 에러의 **이름**이 wire 결과로 접히기 전에 남는다. `host_authority.zig` 의 세 전이가
    //    모두 기록 경유 함수를 부르고, 옛 「그냥 접기」 호출은 남지 않는다.
    const authority = try productSource(a, "src/platform/macos/session_host/host_authority.zig");
    defer a.free(authority);
    try std.testing.expectEqual(@as(usize, 3), count(authority, "catch |err| return transitionForErrorNoted(\""));
    try std.testing.expectEqual(@as(usize, 0), count(authority, "catch |err| return transitionForError(err)"));
    try std.testing.expectEqual(@as(usize, 1), count(authority, "upgrade_product.noteAuthorityTransitionErr(transition, err);"));
    try std.testing.expect(count(src, "pub fn noteAuthorityTransitionErr(") == 1);
    try std.testing.expect(count(src, "host_log.line(\"session host upgrade authority transition failed: transition={s} err={s}\"") == 1);
}

test "host 가 스스로 내려갈 때 그 사실을 남긴다" {
    const a = std.testing.allocator;
    const src = try productSource(a, daemon_path);
    defer a.free(src);

    // ① 자연 종료 판정의 **then 블록**에 로그와 break 가 함께 있다. 판정 호출의 짝 괄호 바로 뒤가 `{` 여야
    //    한다 — 옛 한 줄 모양 `)) break;` 이면 블록이 없어 빨개진다.
    const call = "if (shouldExitNaturally(";
    try std.testing.expectEqual(@as(usize, 1), count(src, call));
    const call_at = std.mem.indexOf(u8, src, call).?;
    const after_if = afterMatchingParen(src, call_at + "if ".len) orelse return error.UnbalancedCall;
    const then_block = blockRightAfter(src, after_if) orelse {
        std.debug.print("shouldExitNaturally 의 then 이 블록이 아니다 — 종료가 로그 없이 break 한다\n", .{});
        return error.SilentNaturalExit;
    };
    // 호출 자리와 메시지 머리를 따로 본다 — zig fmt 가 인자를 다음 줄로 내리면 한 덩어리 글자로는 안 맞는다.
    try std.testing.expectEqual(@as(usize, 1), count(then_block, "host_log.line("));
    try std.testing.expectEqual(@as(usize, 1), count(then_block, "\"session host exiting naturally:"));
    try std.testing.expect(std.mem.indexOf(u8, then_block, "break;") != null);

    // ② listener 가 깨져 나가는 갈래도 같은 규칙이다.
    const arm = ".listener_broken =>";
    try std.testing.expectEqual(@as(usize, 1), count(src, arm));
    const arm_at = std.mem.indexOf(u8, src, arm).?;
    const arm_block = blockRightAfter(src, arm_at + arm.len) orelse {
        std.debug.print(".listener_broken 갈래가 블록이 아니다 — 종료가 로그 없이 break 한다\n", .{});
        return error.SilentListenerExit;
    };
    try std.testing.expect(std.mem.indexOf(u8, arm_block, "host_log.line(") != null);
    try std.testing.expect(std.mem.indexOf(u8, arm_block, "break;") != null);
}

test "죽은 spawn host 재시작이 성공하면 폴백 실패를 기록하지 않는다" {
    const a = std.testing.allocator;
    const src = try productSource(a, term_path);
    defer a.free(src);

    // ① 첫 실패와 재시도 블록 사이: 실패 기록 0, info 한 줄 1. 재시도 **전에** `runtime_death` 를 찍으면
    //    재시작이 성공해도 error 「in-process 로 폴백」이 남는다 — 그게 고친 병이다.
    const gate = "if (!remote_dead) return err;";
    const block_anchor = "relaunch: {";
    try std.testing.expectEqual(@as(usize, 1), count(src, gate));
    try std.testing.expectEqual(@as(usize, 1), count(src, block_anchor));
    const gate_at = std.mem.indexOf(u8, src, gate).?;
    const block_at = std.mem.indexOf(u8, src, block_anchor).?;
    try std.testing.expect(gate_at < block_at);
    const before_retry = src[gate_at..block_at];
    try std.testing.expectEqual(@as(usize, 0), count(before_retry, "markHostConnectFailedError("));
    try std.testing.expectEqual(@as(usize, 1), count(before_retry, "std.log.info("));

    const relaunch = braceBlock(src, block_at + "relaunch: ".len) orelse return error.UnbalancedBlock;

    // ② 재spawn 성공 갈래에는 실패 기록이 없다.
    const ok_anchor = "|respawned| {";
    try std.testing.expectEqual(@as(usize, 1), count(relaunch, ok_anchor));
    const ok_at = std.mem.indexOf(u8, relaunch, ok_anchor).?;
    const ok_arm = braceBlock(relaunch, ok_at + ok_anchor.len - 1) orelse return error.UnbalancedBlock;
    try std.testing.expectEqual(@as(usize, 0), count(ok_arm, "markHostConnectFailedError("));
    try std.testing.expectEqual(@as(usize, 1), count(ok_arm, "break :surface respawned;"));

    // ③ 재spawn 실패 갈래에는 그 **재시도의** 에러로 실패를 기록한다 — 이것이 없으면 진짜 폴백이 조용해진다.
    const fail_anchor = "|retry_err| {";
    try std.testing.expectEqual(@as(usize, 1), count(relaunch, fail_anchor));
    const fail_at = std.mem.indexOf(u8, relaunch, fail_anchor).?;
    const fail_arm = braceBlock(relaunch, fail_at + fail_anchor.len - 1) orelse return error.UnbalancedBlock;
    try std.testing.expectEqual(@as(usize, 1), count(fail_arm, "self.markHostConnectFailedError(.runtime_death, retry_err);"));

    // ④ 재시도조차 못 한 두 갈래(evict 실패·backend 없음)는 원래 에러로 기록한다. ensure 실패는 ensure 가
    //    자기 단계로 이미 기록했으므로 덮지 않는다(`host_connect_failed` 로 곧장 빠진다).
    try std.testing.expectEqual(@as(usize, 2), count(relaunch, "self.markHostConnectFailedError(.runtime_death, err);"));
    try std.testing.expectEqual(@as(usize, 1), count(relaunch, "if (app_session_mod.host_connect_failed) break :relaunch;"));
}
