//! 업그레이드가 한도로 막힐 때 **무엇이 그 크기를 만들었는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 과 2026-09-12, 사용자 host 가 두 번 `state_too_large` 로 업그레이드에 막혔다. 세션은
//! 살아남았지만(`status=resumed`) 옛 빌드에 갇혔고, 그러면 그 뒤 고친 어떤 것도 살아있는 세션에
//! 닿지 못한다. 그런데 로그에 남은 것은 **그 이름 한 줄뿐**이었다.
//!
//! 재는 도구(`runtimeSizeBreakdown` — screens·images·stores·other)는 2026-09-11 에 이미 만들어
//! 두었다. **그런데 제품 코드에서 아무도 부르지 않았다** — 호출자가 테스트 둘뿐이었다. 자를 만들고
//! 실패 자리에 잇지 않으면 다음에도 같은 한 줄만 남는다. 그 사이 우리는 footprint(62.2 MB)를
//! 직렬화 크기로 오해해 「스크롤백이 93%」라고 진단했다가, 실측이 1.64 MB/세션으로 나와 뒤집혔다.
//!
//! 이 판정자가 지키는 것은 **그 연결**이다.

const std = @import("std");

const manager_path = "src/platform/macos/session_host/runtime_manager.zig";
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

test "한도 초과는 태그별 크기를 남긴다 — 코어가 잠긴 그 자리에서" {
    const a = std.testing.allocator;
    const raw = try read(a, manager_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① **제품 코드에 호출자가 있다.** 이것이 빠졌던 바로 그 고리다 — 도구는 있었고 아무도 안 불렀다.
    const measure_at = std.mem.indexOf(u8, src, "handoff_codec.runtimeSizeBreakdown(") orelse
        return error.BreakdownNeverMeasured;

    // ② **코어가 잠긴 동안 잰다.** `previewUpgradeHandoff` 가 끝나면 `defer` 가 전부 풀어, 호출자에게
    //    넘겨서 재는 설계는 원리적으로 늦다. 재는 자리가 그 함수 «앞» 에 정의된 헬퍼여도 좋지만,
    //    **그 함수 안에서 불려야** 한다.
    const preview_at = std.mem.indexOf(u8, src, "pub fn previewUpgradeHandoff(") orelse
        return error.PreviewMissing;
    const preview_end = std.mem.indexOfPos(u8, src, preview_at, "\n    /// 한 번 열거한 paused graph") orelse src.len;
    const preview_body = src[preview_at..preview_end];
    const call_at = std.mem.indexOf(u8, preview_body, "logHandoffSizeBreakdown(") orelse
        return error.BreakdownNotCalledWhileLocked;

    // ③ **한도 초과일 때만** 부른다. 매번 부르면 업그레이드마다 runtime 수만큼 재인코딩이 돈다.
    const guard_from = if (call_at > 300) call_at - 300 else 0;
    try std.testing.expect(
        std.mem.indexOf(u8, preview_body[guard_from..call_at], "error.LimitExceeded") != null,
    );

    // ④ **네 축이 따로 나온다.** 총량 하나로 접으면 줄이는 방법이 정반대인 것들이 다시 뭉친다 —
    //    스크롤백을 자르는 것과 이미지를 버리는 것과 store 를 비우는 것은 서로 다른 일이다.
    //    값이 아니라 **축이 갈린다는 것**을 고정한다.
    for ([_][]const u8{ "screens=", "images=", "stores=", "other=" }) |axis| {
        if (std.mem.indexOf(u8, src, axis) == null) {
            std.debug.print("축 «{s}» 이 로그에 없다 — 총량만으로는 범인이 안 갈린다\n", .{axis});
            return error.AxisCollapsed;
        }
    }

    // ⑤ 한도와 실측 총량을 **함께** 낸다. 한쪽만 있으면 「얼마나 넘었나」를 사람이 계산해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, src, "limit={d}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "measured_total={d}") != null);

    // ⑥ 재다가 하나 실패해도 **나머지는 낸다**. 진단이 전부-아니면-전무면 정작 알고 싶은 순간에
    //    또 빈손이 된다.
    const helper_at = std.mem.indexOf(u8, src, "fn logHandoffSizeBreakdown(") orelse
        return error.HelperMissing;
    const helper_end = std.mem.indexOfPos(u8, src, helper_at, "\n}\n") orelse src.len;
    const helper = src[helper_at..helper_end];
    try std.testing.expect(std.mem.indexOf(u8, helper, "catch continue") != null);
    _ = measure_at;
}
