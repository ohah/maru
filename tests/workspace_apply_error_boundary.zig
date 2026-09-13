//! 워크스페이스 창 적용이 실패했을 때 **원래 오류**를 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13 실측 — 저장 파일에 창 둘(탭 11 + 탭 1)이 온전했고 host 에 세션 23 개가 살아 있었는데
//! **두 창 모두** 거절돼 앱이 기본 `/bin/zsh` 한 창으로 떴고, 그 상태(341 B)가 원본(7421 B)을 덮었다.
//! 하루에 다섯 번 반복됐다.
//!
//! 자리 이름을 붙여 여기까지 왔다(#3644 가 주 창의 침묵을 없앴다).
//!
//! ```
//! maru: workspace apply failed block=0 at=apply status=4    ← create_failed
//! maru: workspace apply failed block=1 at=apply status=4
//! ```
//!
//! **그런데 그 다음이 또 하나로 뭉쳐 있다.** `applyWorkspaceWindow` 안에서 **열일곱** 갈래가 전부
//! `create_failed` 로 접힌다 — 도크 복원·파일트리 루트 검증·탭 생성·용량 확보 어느 것이 죽었는지 알
//! 수 없고, 고칠 곳은 전부 다르다.
//!
//! 오늘 이 저장소에서 같은 모양을 네 번 풀었다: attach 자리 여덟 → 오류 다섯 → 닫힘 자리 29·18 →
//! collectOutput 스물넷. **매번 이름을 붙이자 한 번의 재현으로 끝났다.**

const std = @import("std");

const abi_path = "src/platform/macos/app_host_abi.zig";
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

test "창 적용 실패는 create_failed 뒤에 원래 오류를 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, abi_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    const fn_at = std.mem.indexOf(u8, src, "maru_macos_app_session_apply_workspace_window(") orelse
        return error.AbiFnMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\npub export fn ") orelse src.len;
    const body = src[fn_at..fn_end];

    // ① **오류를 삼키지 않는다.** `catch return …` 한 줄로 접으면 열일곱이 다시 하나가 된다 —
    //    그게 오늘 다섯 번 반복된 데이터 손실의 원인을 못 찾게 만든 자리다.
    const swallow = "applyWorkspaceWindow(parsed.workspace.windows[window_index]) catch return";
    if (std.mem.indexOf(u8, body, swallow) != null) {
        std.debug.print("오류를 이름 없이 삼킨다 — 열일곱이 하나로 접힌다\n", .{});
        return error.ErrorSwallowed;
    }

    // ② **원래 오류 이름을 싣는다.** 「적용이 실패했다」까지는 자리일 뿐이고, 그 이름이 곧 이유다.
    const apply_at = std.mem.indexOf(u8, body, "applyWorkspaceWindow(") orelse
        return error.ApplyCallMissing;
    const tail = body[apply_at..];
    try std.testing.expect(std.mem.indexOf(u8, tail, "@errorName(err)") != null);

    // ③ **어느 창인지 함께 낸다.** 창이 여럿일 때 어느 블록이 죽었는지가 갈려야 Swift 쪽 블록 로그와
    //    짝이 맞는다(#3644).
    try std.testing.expect(std.mem.indexOf(u8, tail, "window_index=") != null);

    // ④ **로그가 «죽어 있지» 않다.** `if (false)` 로 감싸면 소스에는 그대로 보이지만 영영 안 찍힌다 —
    //    죽은 로그는 살아 있는 로그와 구별되지 않아, 다음 재현에서 「아무 줄도 없다」로 나타난다
    //    (적대적 검증에서 이 바꿔치기가 그대로 통과했다). 문장이 catch 블록 «직속» 인지 본다.
    const catch_at = std.mem.indexOf(u8, tail, "catch |err| {") orelse return error.CatchBlockMissing;
    const log_at = std.mem.indexOfPos(u8, tail, catch_at, "std.log.scoped(") orelse
        return error.LogCallMissing;
    const before = std.mem.trim(u8, tail[catch_at + "catch |err| {".len .. log_at], " \t\r\n");
    const ok_direct = before.len == 0 or before[before.len - 1] == ';' or before[before.len - 1] == '{';
    if (!ok_direct) {
        std.debug.print("로그가 문장 직속이 아니다 — 조건 뒤에 숨으면 죽은 로그가 된다\n", .{});
        return error.LogNotDirectStatement;
    }

    // ⑤ **`PersistentRuntimeUnavailable` 의 네 출처가 갈린다.** 그 이름 하나로는 못 고친다 —
    //    풀에 호스트가 없는 것·legacy 불일치·attach 거절 셋은 고칠 곳이 전혀 다르고, 뒤의 둘은
    //    `classifyAttachError` 의 `else =>` 가 **원래 오류를 통째로 버린다.**
    try std.testing.expect(std.mem.indexOf(u8, tail, "attach_site={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "attach_raw={s}") != null);
    {
        const term_raw = try read(a, "src/platform/macos/app_session/term.zig");
        defer a.free(term_raw);
        const term = try stripComments(a, term_raw);
        defer a.free(term);
        for ([_][]const u8{
            "\"pool_host_missing\"",
            "\"legacy_host_mismatch\"",
            "\"attach_on_host\"",
            "\"attach_legacy\"",
        }) |site| {
            if (std.mem.indexOf(u8, term, site) == null) {
                std.debug.print("attach 자리 «{s}» 가 이름 없이 남았다\n", .{site});
                return error.AttachSiteUnnamed;
            }
        }
        // **원래 오류를 버리지 않는다.** 이름만 남기고 오류를 버리면 attach 거절의 실제 사유가
        // 사라져, 「지금 못 붙는다」에서 한 걸음도 못 나간다.
        try std.testing.expect(std.mem.indexOf(u8, term, "noteAttachFail(\"attach_on_host\", err)") != null);
        try std.testing.expect(std.mem.indexOf(u8, term, "noteAttachFail(\"attach_legacy\", err)") != null);
    }

    // ⑥ **`Status` 를 늘리지 않는다.** ABI 계약을 바꾸면 Swift 전수가 흔들린다 — 지금 필요한 것은
    //    「무엇이 죽었는지」뿐이고 그것은 로그로 충분하다. 반환은 그대로 `create_failed` 다.
    try std.testing.expect(std.mem.indexOf(u8, tail, "Status.create_failed") != null);
}
