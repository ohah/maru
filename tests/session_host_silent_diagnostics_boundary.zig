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
//! 글자가 **있는지**가 아니라 **그 자리에서 효과를 내는지**를 본다. 주석을 걷고 테스트 블록을 뺀 뒤,
//! 중괄호 블록과 문장(statement) 경계를 따라 읽는다.
//!
//! - 단계 기록은 `handoff_failed` 를 내는 문장의 **바로 앞 문장**이고, 같은 블록 안에 있으며, 문자열 첫 인자를
//!   받는 **호출문**이어야 한다. 「N 줄 안 어딘가」로 재던 첫 판은 이웃 switch arm 으로 옮긴 기록(X1b)이나
//!   `_ = .{ "noteUpgradeStage", … }` 같은 가짜(X6)를 통과시켰다.
//! - `createTerm` 재시도 앞 구간은 호출 **철자**가 아니라 `runtime_death` **토큰**을 센다 — 별칭으로 부른
//!   기록(X4)도 잡는다. 래치 검사는 `ensureRemoteBackendNow();` **바로 다음 문장**이어야 하고 다른 `if` 아래에
//!   들어가면 안 된다(X5).

const std = @import("std");

const coordinator_path = "src/platform/macos/session_host/upgrade_product_coordinator.zig";
const daemon_path = "src/platform/macos/session_host/daemon.zig";
const term_path = "src/platform/macos/app_session/term.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 코드 문자만 훑는 커서. 문자열·문자 리터럴 안의 괄호와 `//` 는 코드가 아니다.
const Cursor = struct {
    src: []const u8,
    i: usize,

    /// `i` 가 리터럴 시작이면 그 끝 다음으로 건너뛰고 true.
    fn skipLiteral(self: *Cursor) bool {
        const ch = self.src[self.i];
        if (ch != '"' and ch != '\'') return false;
        var j = self.i + 1;
        while (j < self.src.len) : (j += 1) {
            if (self.src[j] == '\\') {
                j += 1;
                continue;
            }
            if (self.src[j] == ch or self.src[j] == '\n') break;
        }
        self.i = @min(j + 1, self.src.len);
        return true;
    }
};

/// 줄 주석을 걷는다(문자열 안의 `//` 는 보존). 주석을 남기면 「설명하는 주석」이 「쓰는 코드」로 세어지고,
/// 로그 호출을 `//` 로 가려도 판정이 통과한다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        var cur: Cursor = .{ .src = line, .i = 0 };
        var cut: usize = line.len;
        while (cur.i < line.len) {
            if (cur.skipLiteral()) continue;
            if (line[cur.i] == '/' and cur.i + 1 < line.len and line[cur.i + 1] == '/') {
                cut = cur.i;
                break;
            }
            cur.i += 1;
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

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
}

/// `{` 가 구조체·배열 리터럴(`.{`)인가 — 블록이 아니다.
fn isLiteralBrace(src: []const u8, at: usize) bool {
    var j = at;
    while (j > 0) {
        j -= 1;
        if (isSpace(src[j])) continue;
        return src[j] == '.';
    }
    return false;
}

/// `pos` 를 감싸는 가장 안쪽 **블록** `{` 의 위치(리터럴 `.{` 는 건너뛴다).
fn enclosingBlockOpen(src: []const u8, pos: usize) ?usize {
    var stack: [256]struct { at: usize, literal: bool } = undefined;
    var depth: usize = 0;
    var cur: Cursor = .{ .src = src, .i = 0 };
    while (cur.i < pos) {
        if (cur.skipLiteral()) continue;
        switch (src[cur.i]) {
            '{' => {
                if (depth == stack.len) return null;
                stack[depth] = .{ .at = cur.i, .literal = isLiteralBrace(src, cur.i) };
                depth += 1;
            },
            '}' => depth -|= 1,
            else => {},
        }
        cur.i += 1;
    }
    while (depth > 0) {
        depth -= 1;
        if (!stack[depth].literal) return stack[depth].at;
    }
    return null;
}

/// `open` 이 `{` 를 가리킬 때 짝 `}` 의 위치.
fn matchingClose(src: []const u8, open: usize) ?usize {
    if (open >= src.len or src[open] != '{') return null;
    var depth: usize = 0;
    var cur: Cursor = .{ .src = src, .i = open };
    while (cur.i < src.len) {
        if (cur.skipLiteral()) continue;
        switch (src[cur.i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return cur.i;
            },
            else => {},
        }
        cur.i += 1;
    }
    return null;
}

/// `open` 블록의 **속**(양끝 괄호 제외).
fn blockInner(src: []const u8, open: usize) ?[]const u8 {
    const close = matchingClose(src, open) orelse return null;
    return src[open + 1 .. close];
}

/// 블록 속을 깊이 0 문장들로 나눈다. 경계는 깊이 0 의 `;`, 그리고 깊이 0 으로 돌아오는 `}` 중 뒤에 `;`·`else`
/// 가 오지 않는 것(`if (…) { … }` 처럼 세미콜론 없이 끝나는 문장). 빈 문장은 버린다.
fn statements(allocator: std.mem.Allocator, inner: []const u8) ![]Statement {
    var list: std.ArrayList(Statement) = .empty;
    errdefer list.deinit(allocator);
    var depth: usize = 0;
    var start: usize = 0;
    var cur: Cursor = .{ .src = inner, .i = 0 };
    while (cur.i < inner.len) {
        if (cur.skipLiteral()) continue;
        const ch = inner[cur.i];
        var boundary = false;
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']' => depth -|= 1,
            '}' => {
                depth -|= 1;
                if (depth == 0) {
                    var j = cur.i + 1;
                    while (j < inner.len and isSpace(inner[j])) : (j += 1) {}
                    const rest = inner[j..];
                    boundary = !(std.mem.startsWith(u8, rest, ";") or std.mem.startsWith(u8, rest, "else"));
                }
            },
            ';' => boundary = depth == 0,
            else => {},
        }
        cur.i += 1;
        if (boundary) {
            const text = std.mem.trim(u8, inner[start..cur.i], " \n\t\r");
            if (text.len > 0 and !std.mem.eql(u8, text, ";"))
                try list.append(allocator, .{ .text = text, .begin = start, .end = cur.i });
            start = cur.i;
        }
    }
    const tail = std.mem.trim(u8, inner[start..], " \n\t\r");
    if (tail.len > 0) try list.append(allocator, .{ .text = tail, .begin = start, .end = inner.len });
    return list.toOwnedSlice(allocator);
}

const Statement = struct { text: []const u8, begin: usize, end: usize };

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| : (at = found + needle.len) n += 1;
    return n;
}

/// 단계 기록 **호출문**인가 — 문자열 첫 인자를 받는 `noteUpgradeStage(`/`noteUpgradeStageErr(` 로 시작한다.
fn isStageNoteStatement(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "noteUpgradeStage(\"") or
        std.mem.startsWith(u8, text, "noteUpgradeStageErr(\"");
}

fn lineOf(src: []const u8, pos: usize) usize {
    return std.mem.count(u8, src[0..pos], "\n") + 1;
}

test "업그레이드의 모든 handoff_failed 산출 지점은 어느 단계였는지 남긴다" {
    const a = std.testing.allocator;
    const src = try productSource(a, coordinator_path);
    defer a.free(src);

    // ① 본체: 제품 코드에서 `handoff_failed` 가 나오는 **모든 자리**를 산출 지점으로 본다(목록을 적지 않는다 —
    //    새 모양이 늘어도 잡힌다). 그 자리를 품은 가장 안쪽 블록을 문장으로 나눠, 산출 문장의 **바로 앞 문장**이
    //    단계 기록 호출문인지 본다.
    var producers: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "handoff_failed")) |pos| : (at = pos + "handoff_failed".len) {
        const open = enclosingBlockOpen(src, pos) orelse return error.NoEnclosingBlock;
        const inner = blockInner(src, open) orelse return error.UnbalancedBlock;
        const rel = pos - (open + 1);
        const stmts = try statements(a, inner);
        defer a.free(stmts);
        const idx = for (stmts, 0..) |s, k| {
            if (rel >= s.begin and rel < s.end) break k;
        } else return error.ProducerOutsideStatement;
        // 테스트 헬퍼 함수(최상위 `test` 블록 밖)의 **단언** 문장은 산출이 아니라 관측이다. 줄이 아니라
        // 문장 단위로 가른다 — 같은 줄에 단언과 산출이 섞여도 산출 쪽이 빠지지 않는다.
        if (std.mem.startsWith(u8, stmts[idx].text, "try std.testing.")) continue;
        producers += 1;
        const ok = idx > 0 and isStageNoteStatement(stmts[idx - 1].text);
        if (!ok) {
            std.debug.print(
                "침묵하는 handoff_failed 산출 지점 — {s}:{d}: 바로 앞 문장이 단계 기록 호출이 아니다: «{s}»\n",
                .{ coordinator_path, lineOf(src, pos), if (idx > 0) stmts[idx - 1].text[0..@min(stmts[idx - 1].text.len, 80)] else "(블록 첫 문장)" },
            );
            return error.SilentHandoffFailedSite;
        }
    }
    // ② 빈 진공 통과 방지 — 산출 지점이 사라지면 ①이 공회전한다(2026-09-29 기준 14 곳).
    try std.testing.expect(producers >= 14);

    // ③ 단계 이름이 **서로 다르다**. 같은 이름으로 뭉치면 로그가 있어도 갈리지 않는다. 호출 첫 인자 모양으로
    //    센다 — 두 헬퍼 중 어느 쪽이든 합쳐 정확히 1 번.
    for ([_][]const u8{
        "unexpected_inherited_fd",
        "fd_slot_reserve",
        "rollback_image_revalidate_pre_freeze",
        "attempt_record_build",
        "handoff_encode",
        "rollback_image_revalidate_post_freeze",
        "authority_begin_restoring",
        "replace_all",
        "non_cloexec_assert",
        "rollback_image_revalidate_pre_exec",
        "exec_prepare_out_of_memory",
        "handoff_store_commit",
        "budget_prepare",
        "exec_failed",
    }) |label| {
        var buf_a: [96]u8 = undefined;
        var buf_b: [96]u8 = undefined;
        const as_note = try std.fmt.bufPrint(&buf_a, "noteUpgradeStage(\"{s}\"", .{label});
        const as_err = try std.fmt.bufPrint(&buf_b, "noteUpgradeStageErr(\"{s}\"", .{label});
        const seen = count(src, as_note) + count(src, as_err);
        if (seen != 1) {
            std.debug.print("단계 라벨 «{s}» 기록 호출이 {d} 번 — 정확히 1 번이어야 한다\n", .{ label, seen });
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

    // ① 자연 종료 판정 `if` 의 then 이 **블록**이고, 그 블록 문장 중 로그 호출문과 `break;` 가 있다. 옛 한 줄
    //    모양 `)) break;` 이면 블록이 없어 빨개진다.
    const call = "if (shouldExitNaturally(";
    try std.testing.expectEqual(@as(usize, 1), count(src, call));
    const call_at = std.mem.indexOf(u8, src, call).?;
    var paren_depth: usize = 0;
    var cur: Cursor = .{ .src = src, .i = call_at + "if ".len };
    const after_cond = while (cur.i < src.len) {
        if (cur.skipLiteral()) continue;
        switch (src[cur.i]) {
            '(' => paren_depth += 1,
            ')' => {
                paren_depth -= 1;
                if (paren_depth == 0) break cur.i + 1;
            },
            else => {},
        }
        cur.i += 1;
    } else return error.UnbalancedCall;
    var j = after_cond;
    while (j < src.len and isSpace(src[j])) : (j += 1) {}
    if (src[j] != '{') {
        std.debug.print("shouldExitNaturally 의 then 이 블록이 아니다 — 종료가 로그 없이 break 한다\n", .{});
        return error.SilentNaturalExit;
    }
    try expectLogThenBreak(a, src, j, "\"session host exiting naturally:");

    // ② listener 가 깨져 나가는 갈래도 같은 규칙이다.
    const arm = ".listener_broken =>";
    try std.testing.expectEqual(@as(usize, 1), count(src, arm));
    var k = std.mem.indexOf(u8, src, arm).? + arm.len;
    while (k < src.len and isSpace(src[k])) : (k += 1) {}
    if (src[k] != '{') {
        std.debug.print(".listener_broken 갈래가 블록이 아니다 — 종료가 로그 없이 break 한다\n", .{});
        return error.SilentListenerExit;
    }
    try expectLogThenBreak(a, src, k, "\"session host exiting");
}

/// 블록의 깊이 0 문장 중 `host_log.line(` 으로 **시작하는** 호출문(메시지 머리 포함)이 하나 있고, 마지막 문장이
/// `break;` 다. 로그를 `if (false)` 아래에 숨기거나 주석으로 가리면 문장 머리가 달라져 빨개진다.
fn expectLogThenBreak(a: std.mem.Allocator, src: []const u8, open: usize, head: []const u8) !void {
    const inner = blockInner(src, open) orelse return error.UnbalancedBlock;
    const stmts = try statements(a, inner);
    defer a.free(stmts);
    var logs: usize = 0;
    for (stmts) |s| {
        if (std.mem.startsWith(u8, s.text, "host_log.line(") and std.mem.indexOf(u8, s.text, head) != null) logs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), logs);
    try std.testing.expect(stmts.len >= 2);
    try std.testing.expectEqualStrings("break;", stmts[stmts.len - 1].text);
}

test "죽은 spawn host 재시작이 성공하면 폴백 실패를 기록하지 않는다" {
    const a = std.testing.allocator;
    const src = try productSource(a, term_path);
    defer a.free(src);

    // ① 첫 실패와 재시도 블록 사이: `runtime_death` **토큰** 0 — 호출 철자가 아니라 단계 값을 센다(별칭으로
    //    부른 `mark(self, .runtime_death, err)` 도 잡는다). 대신 벽시계를 실은 info 한 줄이 있다.
    const gate = "if (!remote_dead) return err;";
    const block_anchor = "relaunch: {";
    try std.testing.expectEqual(@as(usize, 1), count(src, gate));
    try std.testing.expectEqual(@as(usize, 1), count(src, block_anchor));
    const gate_at = std.mem.indexOf(u8, src, gate).?;
    const block_at = std.mem.indexOf(u8, src, block_anchor).?;
    try std.testing.expect(gate_at < block_at);
    const before_retry = src[gate_at..block_at];
    try std.testing.expectEqual(@as(usize, 0), count(before_retry, "runtime_death"));
    try std.testing.expectEqual(@as(usize, 0), count(before_retry, "markHostConnectFailed"));
    try std.testing.expectEqual(@as(usize, 1), count(before_retry, "std.log.info("));
    try std.testing.expectEqual(@as(usize, 1), count(before_retry, "at_unix={d}"));

    // ② 재시도 블록의 **문장 순서**를 고정한다. 순서가 곧 의미다 — evict → ensure → 래치 검사 → backend → spawn.
    const open = block_at + "relaunch: ".len;
    const inner = blockInner(src, open) orelse return error.UnbalancedBlock;
    const stmts = try statements(a, inner);
    defer a.free(stmts);
    // 블록 안 `runtime_death` 는 정확히 셋(evict 실패·backend 없음·재spawn 실패). 넷이면 누가 재시도 전에 또 찍었다.
    try std.testing.expectEqual(@as(usize, 3), count(inner, "runtime_death"));
    try std.testing.expectEqual(@as(usize, 6), stmts.len);

    // evict 실패 갈래: 원래 에러로 기록하고 빠진다.
    try std.testing.expect(std.mem.startsWith(u8, stmts[0].text, "if (!app_session_mod.AppSession.evictDeadSpawnHost()) {"));
    try std.testing.expectEqual(@as(usize, 1), count(stmts[0].text, "self.markHostConnectFailedError(.runtime_death, err);"));
    try std.testing.expectEqual(@as(usize, 1), count(stmts[0].text, "break :relaunch;"));

    // ensure 바로 다음 문장이 래치 검사이고, **다른 `if` 아래에 있지 않다**(문장 머리가 정확히 이것이어야 한다).
    try std.testing.expectEqualStrings("self.ensureRemoteBackendNow();", stmts[1].text);
    try std.testing.expectEqualStrings("if (app_session_mod.host_connect_failed) break :relaunch;", stmts[2].text);

    // backend 가 없으면 원래 에러로 기록한다.
    try std.testing.expect(std.mem.startsWith(u8, stmts[3].text, "const rb = if (app_session_mod.app_remote_backend)"));
    try std.testing.expectEqual(@as(usize, 1), count(stmts[3].text, "self.markHostConnectFailedError(.runtime_death, err);"));
    try std.testing.expectEqualStrings("be = rb.backend();", stmts[4].text);

    // ③ 재spawn: 성공 갈래에는 실패 기록이 없고, 실패 갈래는 **재시도의** 에러로 기록한다.
    const spawn = stmts[5].text;
    try std.testing.expect(std.mem.startsWith(u8, spawn, "if (be.spawn("));
    const ok_anchor = "|respawned| {";
    const fail_anchor = "|retry_err| {";
    try std.testing.expectEqual(@as(usize, 1), count(spawn, ok_anchor));
    try std.testing.expectEqual(@as(usize, 1), count(spawn, fail_anchor));
    const ok_open = std.mem.indexOf(u8, spawn, ok_anchor).? + ok_anchor.len - 1;
    const fail_open = std.mem.indexOf(u8, spawn, fail_anchor).? + fail_anchor.len - 1;
    const ok_arm = blockInner(spawn, ok_open) orelse return error.UnbalancedBlock;
    const fail_arm = blockInner(spawn, fail_open) orelse return error.UnbalancedBlock;
    try std.testing.expectEqual(@as(usize, 0), count(ok_arm, "runtime_death"));
    try std.testing.expectEqual(@as(usize, 0), count(ok_arm, "markHostConnectFailed"));
    const ok_stmts = try statements(a, ok_arm);
    defer a.free(ok_stmts);
    try std.testing.expectEqual(@as(usize, 1), ok_stmts.len);
    try std.testing.expectEqualStrings("break :surface respawned;", ok_stmts[0].text);
    const fail_stmts = try statements(a, fail_arm);
    defer a.free(fail_stmts);
    try std.testing.expectEqual(@as(usize, 1), fail_stmts.len);
    try std.testing.expectEqualStrings("self.markHostConnectFailedError(.runtime_death, retry_err);", fail_stmts[0].text);
}
