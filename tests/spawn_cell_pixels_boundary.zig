//! 새 터미널을 여는 길목이 **셀 픽셀을 spawn 요청에 싣는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-14 실측. 세션 호스트로 연 터미널 브라우저 pane 은 **2560×1410** 인데 브라우저 뷰포트가
//! **1083×630** 으로 굳어 있었다(브라우저에 직접 `window.innerWidth` 를 물어 확인). 그림을 2.4 배
//! 확대해 채우니 글자가 크고, 문서 폭이 뷰포트를 넘어 가로 스크롤이 생기고, 사이트는 좁은 화면용
//! 레이아웃을 골랐다.
//!
//! 연쇄는 이렇다.
//!
//! 1. spawn 이 `ws_xpixel`/`ws_ypixel` 을 0 으로 둔다 — **채우는 코드는 있는데 값이 안 온다.**
//! 2. 자식은 표준 경로(`ws_xpixel / ws_col`)를 못 쓰고 `CSI 14t` 로 넘어간다.
//! 3. host 코어의 셀 메트릭이 아직 0 이라 코어는 **의도적으로 침묵한다**(0 을 답하면 기하가 통째로
//!    깨지므로 무응답이 오답보다 낫다 — `parser.zig` `reportWindowOps`).
//! 4. 자식은 짧은 제한시간 뒤 기본값으로 굳는다.
//!
//! **뒤늦게 보내도 소용없다.** 자식은 시작할 때 한 번만 묻는다 — 렌더 tick 에서 `set_cell_metrics` 를
//! 보내는 경로가 이미 있었는데도 증상이 그대로였고, 창 크기를 바꿔도 풀리지 않았다.
//!
//! in-process 가 멀쩡했던 이유도 같은 그림이다: 거기선 로컬 코어가 매 렌더 tick 메트릭을 받아, 자식이
//! 물을 때 이미 답할 값이 있다.
//!
//! ## 무엇을 재는가
//!
//! `spawnRequest` 는 자유 함수라 세션의 셀 메트릭에 닿지 못하고 호출부가 다섯 곳이다. 거기서 채우면
//! **새 호출부가 조용히 0 을 보낸다.** 그래서 두 spawn(원격·in-process 폴백)이 모두 지나는 길목
//! 하나에서 채우고, 이 판정자가 **그 길목이 spawn 보다 앞선다**는 것을 잰다.
//!
//! 이름이 아니라 순서를 잰다 — 대입이 `be.spawn(` 보다 뒤에 오면 첫 spawn 은 0 을 싣는다.

const std = @import("std");

const max_source_bytes = 4 << 20;

fn readSource(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_source_bytes));
}

test "새 터미널 spawn 이 셀 픽셀을 실어 보낸다" {
    const a = std.testing.allocator;
    const term_src = try readSource(a, "src/platform/macos/app_session/term.zig");
    defer a.free(term_src);

    // 1) 길목이 세션의 셀 메트릭을 요청에 싣는다.
    const w_assign = std.mem.indexOf(u8, term_src, "req.cell_width_px = self.cell_width_px") orelse
        return error.CellWidthNotCarried;
    const h_assign = std.mem.indexOf(u8, term_src, "req.cell_height_px = self.cell_height_px") orelse
        return error.CellHeightNotCarried;

    // 2) **첫 spawn 보다 앞선다.** 뒤에 오면 그 spawn 은 0 을 싣고, 자식은 이미 굳은 뒤다.
    const first_spawn = std.mem.indexOf(u8, term_src, "be.spawn(") orelse
        return error.SpawnCallSiteMissing;
    try std.testing.expect(w_assign < first_spawn);
    try std.testing.expect(h_assign < first_spawn);

    // 3) 원격·in-process 폴백 **둘 다** 이 길목을 지난다 — 한쪽만 지나면 폴백이 0 을 보낸다.
    var spawn_count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, term_src, cursor, "be.spawn(")) |at| {
        spawn_count += 1;
        cursor = at + 1;
    }
    try std.testing.expect(spawn_count >= 2);
    // 모든 spawn 이 대입 뒤에 있어야 한다.
    try std.testing.expect(std.mem.lastIndexOf(u8, term_src, "be.spawn(").? > h_assign);
}
