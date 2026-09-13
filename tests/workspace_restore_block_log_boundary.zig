//! 워크스페이스 복원 실패가 **어느 창 블록이었는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13 실측 — 저장 파일에 창 둘(탭 11 + 탭 1)이 온전했고 host 에도 세션 23 개가 살아 있었는데,
//! 앱은 기본 `/bin/zsh` **한 창**으로 떴고 그 상태(341 B)가 원본(7421 B)을 덮었다.
//!
//! 로그에 남은 것은 이 한 줄뿐이었다.
//!
//! ```
//! maru: workspace restore failed to create window block=1 of 2
//! ```
//!
//! **주 창(블록 0)의 실패는 완전히 조용했다.** 추가 창(블록 1 이상)만 로그를 찍고, 블록 0 은
//! `workspaceRestoreIncomplete = true` 만 세운 뒤 기본 셸 창으로 갈아탄다 — 그 갈아탄 결과가 곧
//! 341 B 다. 그래서 「복원이 왜 안 되나」가 로그에서 통째로 사라졌다.
//!
//! `applyWorkspaceWindow` 도 실패를 `false` 하나로만 말했다. 실패 지점이 둘(세션 없음 · apply status)
//! 인데 구분이 없어, 설령 블록 0 을 찍었어도 **왜** 인지는 여전히 몰랐을 것이다.

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

test "복원 실패는 주 창도 어느 블록인지와 왜인지를 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, host_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① **주 창도 로그를 남긴다.** 추가 창만 찍던 비대칭이 이 결함의 본체였다 — 보이는 실패와
    //    안 보이는 실패가 같은 함수 안에 나란히 있었다.
    try std.testing.expect(
        std.mem.indexOf(u8, src, "restore failed to apply window block=0") != null,
    );
    // 추가 창 쪽도 그대로 남는다 — 한쪽을 켜려고 다른 쪽을 끄면 같은 구멍이 자리만 옮긴다.
    try std.testing.expect(
        std.mem.indexOf(u8, src, "restore failed to create window block=") != null,
    );

    // ② **`applyWorkspaceWindow` 의 두 실패 지점이 갈린다.** 세션이 없는 것과 apply 가 거절한 것은
    //    고칠 곳이 전혀 다르다 — 앞은 수명, 뒤는 저장 내용·attach 다.
    const fn_at = std.mem.indexOf(u8, src, "func applyWorkspaceWindow(") orelse
        return error.ApplyFnMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\n    private func applyRestoredWindowFrame(") orelse src.len;
    const body = src[fn_at..fn_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "at=no_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "at=apply") != null);

    // ③ **status 값을 싣는다.** 「apply 가 거절했다」까지는 자리일 뿐이고, 그 코드가 곧 이유다.
    try std.testing.expect(std.mem.indexOf(u8, body, "status=\\(status)") != null);

    // ④ **조용한 `return false` 가 남지 않는다.** 하나라도 남으면 그 경로가 다시 침묵한다 —
    //    그게 오늘 주 창에서 일어난 일이다.
    var at: usize = 0;
    var bare: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "return false")) |f| : (at = f + "return false".len) {
        const from = if (f > 200) f - 200 else 0;
        if (std.mem.indexOf(u8, body[from..f], "fputs(") == null) bare += 1;
    }
    if (bare != 0) {
        std.debug.print("이유를 안 남기는 return false 가 {d} 곳\n", .{bare});
        return error.SilentFailureRemains;
    }
}
