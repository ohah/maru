//! 복원이 실패한 실행이 **저장 파일을 덮지 않는지**, 그리고 그 규칙이 **종료를 막지 않는지** 못 박는다.
//!
//! ## 무엇이 있었나 (둘이다)
//!
//! **① 파일이 덮였다.** 2026-09-13 실측 — 저장 파일에 창 둘(탭 11 + 탭 1)이 온전하고 host 에 세션
//! 23 개가 살아 있는데도 attach 가 매번 실패해 앱이 기본 `/bin/zsh` 한 창으로 떴다. 그리고 종료
//! 저장이 **7421 B 를 341 B 로** 덮었다 — **하루에 다섯 번.**
//!
//! 평상시 저장은 래치가 이미 막고 있었다. 그 래치가 **종료 저장만 면제**한 근거는 「그 경로가
//! `preservePrevious` 로 마지막 완전본을 `.bak` 에 남긴다」였는데, `ensureBackup` 은 `O_EXCL` 이라
//! `.bak` 이 이미 있으면 아무것도 안 한다 — 실제 `.bak` 은 **7 월 25 일 4614 B** 에서 멈춰 있었다.
//! 쌍이 깨져 있었으므로 면제의 근거가 없다.
//!
//! 그리고 같은 논리가 **이미 바로 옆에 있었다**: 복원을 «끈» 사용자(`MARU_NO_WORKSPACE_RESTORE`)는
//! 저장도 막는다. 복원이 «실패한» 경우가 남기는 상태는 그것과 똑같다. 결과가 같으면 규칙도 같아야 한다.
//!
//! **② 그 수정이 앱을 못 닫게 만들었다.** 첫 수정은 `captureWorkspaceSnapshot` 안에서 `nil` 을
//! 돌려줬다. 그런데 그 자리에서 `nil` 은 **「캡처 실패」** 라는 뜻이다 — 상태 기계가 `CANCEL_QUIT` 을
//! 내고, `allowsFailure=false` 인 keep-alive 종료는 **취소된다.** 사용자는 앱이 영영 안 닫히는 것만
//! 본다(실측: 같은 네 줄이 무한 반복).
//!
//! > **「안 쓰기로 한 것」과 「쓰지 못한 것」은 다른 사건이다.** 다른 자리에서 말해야 한다.
//!
//! 그래서 판단은 **저장을 시작하기 전**(`beginFinalWorkspaceCheckpoint`)에 있어야 하고, 그 경로는
//! 종료를 **끝까지 진행**시켜야 한다.
//!
//! ## 왜 이 판정자가 ② 를 놓쳤나
//!
//! 옛 조항은 "final-quit finished — quit proceeds" 라는 문자열이 **파일 어딘가에 있는지**만 봤다.
//! 그 문자열은 당연히 있었다 — 다른 경로가 쓰니까. 건너뛰기 경로가 **거기에 닿는지**는 재지 않았다.
//! 존재를 재면 의도를 못 잰다.

const std = @import("std");

const host_path = "src/platform/macos/MaruAppHost.swift";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

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

fn funcBody(src: []const u8, decl: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, decl) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + decl.len, "\n    private func ") orelse src.len;
    return src[at..end];
}

/// `guard !workspaceRestoreIncomplete …` 의 **조건부만** 떼어 온다.
fn latchGuardCondition(body: []const u8) ?[]const u8 {
    const head = "guard !workspaceRestoreIncomplete";
    const at = std.mem.indexOf(u8, body, head) orelse return null;
    const end = std.mem.indexOfPos(u8, body, at, " else") orelse body.len;
    return body[at..end];
}

test "불완전 복원 래치는 저장을 막되 종료는 막지 않는다" {
    const a = std.testing.allocator;
    const raw = try read(a, host_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    const begin = try funcBody(src, "func beginFinalWorkspaceCheckpoint(");
    const drive = try funcBody(src, "func driveWorkspaceCheckpoint(");
    const capture = try funcBody(src, "func captureWorkspaceSnapshot(");

    // ── ① 종료 저장: 판단이 **상태 기계를 시작하기 전**에 있어야 한다 ───────────────────────────
    const begin_cond = latchGuardCondition(begin) orelse {
        std.debug.print("종료 저장에 불완전-복원 가드가 없다 — 실패한 복원이 저장 파일을 덮는다\n", .{});
        return error.NoFinalQuitGuard;
    };
    const guard_at = std.mem.indexOf(u8, begin, begin_cond).?;

    //    상태 기계는 `workspaceFinalQuitPending = true` 에서 시작한다. 가드가 그 **뒤**에 있으면
    //    이미 진입한 상태라 빠져나갈 길이 `CANCEL_QUIT` 뿐이다 — 그게 앱이 안 닫히던 모양이다.
    const machine_at = std.mem.indexOf(u8, begin, "workspaceFinalQuitPending = true") orelse
        return error.QuitMachineEntryMissing;
    if (guard_at > machine_at) {
        std.debug.print("가드가 상태 기계 «뒤» 에 있다 — 빠져나갈 길이 CANCEL_QUIT 뿐이라 종료가 취소된다\n", .{});
        return error.GuardAfterMachineEntry;
    }

    //    가드 본문은 **앱을 실제로 닫아야** 한다. 그냥 `return` 이면 종료 요청이 허공에 뜬다.
    const body_end = std.mem.indexOfPos(u8, begin, guard_at, "\n        }") orelse begin.len;
    const guard_body = begin[guard_at..body_end];
    const terminates = std.mem.indexOf(u8, guard_body, "NSApp.terminate") != null and
        std.mem.indexOf(u8, guard_body, "toApplicationShouldTerminate: true") != null;
    if (!terminates) {
        std.debug.print("건너뛰기 경로가 앱을 닫지 않는다 — 종료 요청이 허공에 뜬다: «{s}»\n", .{guard_body});
        return error.SkipPathDoesNotQuit;
    }

    //    그리고 **왜** 안 썼는지 남긴다. 조용히 건너뛰면 「저장이 왜 안 됐나」가 다시 안 보인다.
    try std.testing.expect(std.mem.indexOf(u8, guard_body, "final-quit save skipped") != null);

    // ── ② 평상시 저장: 면제 항이 없어야 한다 ─────────────────────────────────────────────────
    //    `|| workspaceFinalQuitPending` 이 원래 버그다. 접두만 보면 다시 붙여도 초록이다.
    const drive_cond = latchGuardCondition(drive) orelse return error.NoPeriodicGuard;
    if (std.mem.indexOf(u8, drive_cond, "FinalQuit") != null or
        std.mem.indexOf(u8, drive_cond, "||") != null)
    {
        std.debug.print("평상시 저장 가드가 예외를 달고 있다 — 원래 버그의 모양이다: «{s}»\n", .{drive_cond});
        return error.PeriodicGuardHasExemption;
    }

    // ── ③ 캡처 층에는 래치를 **두지 않는다** ────────────────────────────────────────────────
    //    그 자리의 `nil` 은 「캡처 실패」라는 뜻이고, 실패는 종료를 취소시킨다. 건너뜀을 실패로
    //    말하면 안 된다 — ② 사고가 정확히 이것이었다.
    if (latchGuardCondition(capture) != null) {
        std.debug.print("캡처 층이 래치를 본다 — nil 은 «실패» 로 읽혀 종료가 취소된다\n", .{});
        return error.LatchInCaptureLayer;
    }

    // ── ④ 옆에 있던 같은 규칙을 지운 게 아니다 ──────────────────────────────────────────────
    //    복원을 «끈» 경우의 가드는 그대로 남아야 한다. 한쪽을 켜려고 다른 쪽을 끄면 구멍이 자리만 옮긴다.
    try std.testing.expect(std.mem.indexOf(u8, capture, "MARU_NO_WORKSPACE_RESTORE") != null);
}
