const std = @import("std");
const terminal = @import("../terminal.zig");

/// 메인발 비-PTY 코어 mutate를 I/O 스레드(reader)로 위임하는 명령(docs/io-render-threading.md §9 Phase 3,
/// (a) 단일책임). runtime·pty_reader·live_pty가 공유하므로 순환 import를 피해 **중립 위치**에 둔다(terminal만
/// 의존). 큐는 `pty_reader.CoreCommandQueue`, 적용은 `apply`(여기) — reader drain과 non-interactive 직접 폴백이
/// 같은 적용 로직을 공유한다. 명령 집합은 §9.2를 따라 단계 확장(P3-2 IME·P3-4 scroll·선택; 리포팅·config 후속).
pub const CoreCommand = union(enum) {
    set_preedit: []const u8, // owned(큐 소유) — IME 조합 텍스트. 적용/드롭/close 시 해제.
    clear_preedit, // IME 조합 해제(빈 preedit)
    scroll: isize, // scrollViewport(delta_up)
    scroll_to_bottom,
};

/// 명령을 코어에 적용한다. **호출자가 코어 락(core_mutex)을 잡은 상태여야 한다** — reader는 `owner_dbg.lock`,
/// non-interactive 직접 폴백은 `surface.lockCore`. 단일 mutator 계약상 적용은 한 스레드에서만 일어난다(§9.3).
/// 응답을 만드는 명령(리포팅 — P3-3)은 적용 후 호출자가 `core.pendingResponse`를 PTY로 흘린다.
pub fn apply(core: *terminal.TerminalCore, cmd: CoreCommand) void {
    switch (cmd) {
        .set_preedit => |bytes| core.setPreedit(bytes) catch {}, // OOM이면 조합 표시 스킵(best-effort)
        .clear_preedit => core.setPreedit("") catch {}, // 빈 bytes = 해제
        .scroll => |delta| core.scrollViewport(delta),
        .scroll_to_bottom => core.scrollToBottom(),
    }
}

test "core_command.apply: 각 명령이 코어를 올바르게 mutate (위임 적용 로직)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // set_preedit → 조합 텍스트 설정, clear_preedit → 해제(빈 preedit)
    apply(&core, .{ .set_preedit = "한" });
    try std.testing.expect(core.preedit != null);
    apply(&core, .clear_preedit);
    try std.testing.expect(core.preedit == null);

    // scroll → 과거로 스크롤(view_offset>0), scroll_to_bottom → 바닥 복귀(view_offset==0)
    var i: usize = 0;
    while (i < 20) : (i += 1) try core.write("line\r\n");
    apply(&core, .{ .scroll = 5 });
    try std.testing.expect(core.viewOffset() > 0);
    apply(&core, .scroll_to_bottom);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
}
