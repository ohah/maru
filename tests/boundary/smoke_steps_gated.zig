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

/// 이 줄이 **스핀 번호와 견주는가**. 이름이 나오는 것만으로는 부족하다 — 증가문·주석·판정
/// 출력에도 그 이름이 나온다.
fn hasSpinComparison(line: []const u8) bool {
    for ([_][]const u8{ "spins ==", "spins >=", "spins <=", "spins >", "spins <" }) |needle| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "합성 앱 루프의 스핀 단계는 전부 smoke 로 갈린다" {
    const source = @embedFile("main_source");
    // 루프가 끝나는 자리 — 그 뒤는 판정 출력이라 각본이 아니다.
    const end_marker = "try stdout.writeAll(\"maru.win32-terminal-smoke.v1";
    const loop_at = std.mem.indexOf(u8, source, loop_marker) orelse {
        // 루프 모양이 바뀌면 **조용히 통과하지 않는다** — 이 게이트가 무엇을 보는지 잃어버린다.
        std.debug.print("합성 앱 루프를 못 찾았다: 이 게이트의 표지(`{s}`)가 바뀌었다\n", .{loop_marker});
        return error.LoopMarkerMissing;
    };

    const end_at = std.mem.indexOf(u8, source, end_marker) orelse {
        std.debug.print("루프의 끝 표지를 못 찾았다: {s}\n", .{end_marker});
        return error.EndMarkerMissing;
    };
    var violations: usize = 0;
    var line_no: usize = 1;
    var i: usize = 0;
    var prev: []const u8 = "";

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| : (line_no += 1) {
        defer {
            i += line.len + 1;
            prev = line;
        }
        if (i < loop_at) continue;
        // **루프 안에서만 본다.** 파일 끝까지 훑었더니 뒤에 있는 다른 함수의 `while (spins < 32)`
        // 를 각본으로 잡았다(실측: `pumpForIntent`). 중괄호 깊이로 루프의 끝을 찾는다 — 형식
        // 문자열의 `{d}` 는 여닫이가 짝이라 셈에 영향이 없다.
        // **루프의 끝은 표지로 잡는다.** 처음에는 중괄호를 셌는데 **후반부를 통째로 놓쳤다**
        // (실측 2026-08-26: 4626 은 잡고 4889 는 안 잡혔다 — 깊이가 어딘가에서 일찍 0 이 됐다).
        // 문자열·문자 리터럴 안의 중괄호를 세지 않으려면 렉서가 필요한데, 이 게이트가 하려는 일에
        // 비해 과하다. 루프 **바로 뒤에 오는 줄**을 끝으로 삼으면 그 문제가 사라진다.
        if (i >= end_at) break;
        const trimmed = std.mem.trimStart(u8, line, " ");
        // 주석은 안 본다 — 이 게이트를 설명하는 줄에도 `spins` 가 나온다.
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        // 루프 머리와 증가문은 각본이 아니다.
        if (std.mem.indexOf(u8, trimmed, loop_marker) != null) continue;
        if (std.mem.startsWith(u8, trimmed, "spins +=")) continue;
        // **비교 자체를 본다 — 줄 앞을 보지 않는다.** 앞을 보면 `if (titlebar_px != 0 and spins == 490)`
        // 처럼 **조건 순서만 바꿔도 통째로 새어 나간다**(실측 2026-08-26: 그 모양이 이 게이트를
        // 그냥 지나갔다). 각본은 스핀 번호와 견주는 것이 본질이므로 그 비교를 표지로 삼는다.
        if (!hasSpinComparison(trimmed)) continue;
        // 같은 줄이나 **바로 앞 줄**에 `smoke` 가 있으면 갈린 것이다 — 조건이 길면 `zig fmt` 가
        // 두 줄로 접는다.
        if (std.mem.indexOf(u8, trimmed, "smoke") != null) continue;
        if (std.mem.indexOf(u8, prev, "smoke") != null) continue;
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
