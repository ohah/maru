//! IME 조합 확정 규칙의 **모달리티 목록**을 소스로 고정한다.
//!
//! 규칙은 하나다: "조합(marked text) 중에 텍스트 입력이 아닌 사용자 상호작용이 오면 먼저 조합을 확정한다."
//! 안 하면 AppKit 입력기 세션(`hasMarkedText`)과 Zig `Surface.preedit`가 살아남아 조합 글자가 화면에
//! 잔상으로 남고, 그 뒤 입력이 stale한 조합에 이어 붙는다.
//!
//! **왜 소스 스캔인가**: 이 규칙은 chokepoint 하나로 닫히지 않는다 — AppKit 입력기 세션 종료
//! (`inputContext.discardMarkedText`)는 NSView만 할 수 있어서 Zig 쪽 전환 지점이 아니라 **Swift 입력
//! 경계마다** 합류시켜야 하는 **열린 목록**이다. 그래서 모달리티를 하나 더할 때 빠뜨리면 그 경로에서만
//! 조합 잔상이 남는다. 실제로 그렇게 두 번 드러났다: 탭 전환(2026-07 사용자 보고)과 **드롭**(2026-08-17
//! 사용자 보고 — "이미지 드래그해서 업로드할 때 IME 상태면 잔상이 남는다").
//!
//! Swift 는 이 저장소에 단위 테스트 하니스가 없다(타입 체크와 제품 링크만 있다). 그래서 이 게이트가
//! "네 모달리티가 모두 그 함수를 부른다"는 사실을 **문자열로** 든다 — 새 입력 경계를 추가하면서 이
//! 목록을 갱신하지 않으면 여기서 걸린다.

const std = @import("std");
const max_source_bytes = 16 * 1024 * 1024;

test "IME 조합 확정은 키보드·포인터·메뉴·드롭 네 모달리티가 공유한다" {
    const allocator = std.testing.allocator;
    const swift = try readSource(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);

    // 선언 1 + 호출 4. 이 숫자가 이 게이트의 전부다 — 늘거나 줄면 목록이 바뀐 것이고, 그때 아래 네
    // 문맥 단언도 함께 갱신해야 한다.
    try std.testing.expectEqual(@as(usize, 1), count(swift, "func commitMarkedTextIfComposing()"));
    try std.testing.expectEqual(@as(usize, 4), count(swift, "commitMarkedTextIfComposing()") - 1);

    // 네 모달리티 각각이 **자기 함수 안에서** 부르는지 본다. 총 개수만 세면 한 경로에서 두 번 부르고
    // 다른 경로가 빠진 상태도 통과한다.
    //
    // ① 드롭(performDragOperation) — 2026-08-17에 합류. 삽입 **전**에 확정해야 조합 글자가 드롭 내용보다
    //    앞에 온다.
    try std.testing.expect(callsWithin(swift, "override func performDragOperation(", "controller?.handleDrop("));
    // ② 키보드(keyDown) — 단축키·특수키가 조합을 지나쳐 가는 경로.
    try std.testing.expect(callsWithin(swift, "override func keyDown(", "handleKeyDown("));
    // ③ 포인터(kind == 1) — 사이드바 카드·탭 바 클릭의 탭/Term 전환.
    try std.testing.expect(count(swift, "if kind == 1 { (view as? MaruMetalTerminalView)?.commitMarkedTextIfComposing() }") == 1);
    // ④ 메뉴(runCatalogAction) — 키 단축키로 와도 keyDown을 안 거친다.
    try std.testing.expect(count(swift, "activeSurface?.view?.commitMarkedTextIfComposing()") == 1);

    // 확정은 **커밋 + AppKit 세션 종료 + 로컬 상태 비우기** 셋이 함께여야 한다. 하나라도 빠지면 잔상의
    // 출처가 그쪽으로 옮겨 간다(Zig만 비우면 AppKit marked 세션이 살아 다음 입력이 조합에 이어 붙는다).
    const body = between(swift, "func commitMarkedTextIfComposing()", "\n    }") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(count(body, "controller?.imeCommit()") == 1);
    try std.testing.expect(count(body, "inputContext?.discardMarkedText()") == 1);
    try std.testing.expect(count(body, "markedTextBuffer = \"\"") == 1);
    try std.testing.expect(count(body, "guard hasMarkedText() else { return }") == 1);
}

/// `open` 으로 시작하는 함수 본문에서 `marker` 보다 **앞서** 확정 호출이 있는지. 드롭·키보드처럼 "삽입
/// 전에 확정" 순서가 계약인 경로를 위한 판정이다.
fn callsWithin(source: []const u8, open: []const u8, marker: []const u8) bool {
    const start = std.mem.indexOf(u8, source, open) orelse return false;
    const marker_at = std.mem.indexOfPos(u8, source, start, marker) orelse return false;
    const call_at = std.mem.indexOfPos(u8, source, start, "commitMarkedTextIfComposing()") orelse return false;
    return call_at < marker_at;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
