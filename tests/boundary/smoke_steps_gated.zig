// 이 테스트는 **판정 스캐폴딩이 제품 경로에서 돌지 않게** 한다.
//
// **무엇을 증명하나.** `src/main.zig` 의 합성 앱 루프 안에서 스핀 번호로 갈리는 단계(`if (spins ...`)가
// **전부 `smoke` 로 먼저 갈린다.**
//
// **왜 게이트가 필요한가 — 실제로 제품에서 돌고 있었다.** 그 루프는 `win32-terminal`(제품)과
// `win32-terminal-smoke`(판정)가 **같이 쓴다.** 두 명령의 유일한 차이는 스핀 상한이고, 단계들이
// 스핀 번호로만 갈려 있어서 **제품 실행이 판정 각본을 그대로 따라 했다** — 창을 스스로 최대화하고,
// ＋ 를 눌러 세션을 열댓 개 만들고, 셸에 `MARK-ONE` 을 치고, 도크 뷰를 바꾸고, 에이전트 그룹을 접었다.
//
// **어떻게 드러났나.** 캡처에 `MARK-ONE` 이 찍혔다(2026-08-26). 그 글자는 스모크의 세션 전환 판정이
// 쓰는 표시라 제품 화면에 나올 수 없는 것이었다. 그 전까지 **어떤 판정도 이것을 못 봤다** — 스모크는
// 자기가 그 단계를 도는 것이 정상이고, 제품 경로를 보는 판정은 없기 때문이다.
//
// **규칙**: 루프 안의 `if (spins` 는 반드시 `if (smoke and spins` 여야 한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - `smoke` 로 갈리지 않는 **다른 모양**의 각본은 못 본다(예: `if (frame_count == 3)`). 이 게이트가
//     고정하는 것은 지금 쓰는 관용구 하나다.
//   - `smoke` 의 **정의가 틀리는 것**은 못 본다. 그 값이 `max_spins != null` 인지는 사람이 본다.

const std = @import("std");

const loop_marker = "while ((max_spins == null or spins < max_spins.?)";

test "합성 앱 루프의 스핀 단계는 전부 smoke 로 갈린다" {
    const source = @embedFile("main_source");
    const loop_at = std.mem.indexOf(u8, source, loop_marker) orelse {
        // 루프 모양이 바뀌면 **조용히 통과하지 않는다** — 이 게이트가 무엇을 보는지 잃어버린다.
        std.debug.print("합성 앱 루프를 못 찾았다: 이 게이트의 표지(`{s}`)가 바뀌었다\n", .{loop_marker});
        return error.LoopMarkerMissing;
    };

    var violations: usize = 0;
    var line_no: usize = 1;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| : (line_no += 1) {
        defer i += line.len + 1;
        if (i < loop_at) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "if (spins ")) continue;
        violations += 1;
        std.debug.print("src/main.zig:{d}: 스핀 단계가 `smoke` 로 안 갈렸다 — 제품 실행이 이 각본을 따라 한다\n", .{line_no});
    }
    if (violations != 0) {
        std.debug.print("판정 스캐폴딩 위반 {d}건\n", .{violations});
        return error.SmokeStepNotGated;
    }

    // **공허하지 않은지 본다.** 갈린 단계가 하나도 없으면 이 게이트는 아무것도 안 지킨다 —
    // 관용구가 통째로 바뀐 것이므로 그때도 시끄러워야 한다.
    var gated: usize = 0;
    var it2 = std.mem.splitScalar(u8, source[loop_at..], '\n');
    while (it2.next()) |line| {
        if (std.mem.indexOf(u8, line, "if (smoke and spins ") != null) gated += 1;
    }
    try std.testing.expect(gated >= 20);
}
