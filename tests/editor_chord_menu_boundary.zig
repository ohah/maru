//! `performKeyEquivalent` 가 편집기 컨텍스트 질의를 **실제로 부르는지** 잰다
//! ([키 입력과 단축키](../docs/key-input-and-shortcuts.md) 「메뉴 keyEquivalent 층」).
//!
//! **Zig 판정자만으로는 이 층을 못 잡는다.** `EMK1`~`EMK4` 는 resolver·질의·표시를 재지만, 그 답을
//! **Swift 가 묻지 않으면** 아무 일도 안 일어난다 — 그것이 `⌘D`·`⌥⌘↑`·`⌥⌘↓` 가 배선된 채로 제품에서
//! 죽어 있던 이유다(2026-09-06 사용자 확인).
//!
//! **심볼 존재만 보면 약하다.** 이 저장소의 선례(`session_host_signed_app_quit_evidence_boundary`)는
//! `indexOf(swift, "심볼") != null` 만 보는데, 그러면 **극성을 뒤집은 변이**(`!= true`)도, 엉뚱한 함수로
//! 옮긴 변이도 안 죽는다. 그래서 여기서는 **블록을 통째로** 단언한다. 대가는 들여쓰기·줄바꿈을 바꾸면
//! 깨지는 것이고, 그 대가로 **Swift 에 판정을 복제하지 않는다**.
const std = @import("std");

fn readSwift() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/MaruAppHost.swift",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
}

test "EMK5 performKeyEquivalent 가 편집기 질의를 오버레이 뒤에 부른다" {
    const swift = try readSwift();
    defer std.testing.allocator.free(swift);

    // **오버레이 갈래가 먼저다** — 모달 중 chord 녹음이 새면 안 된다(그 갈래의 근거가 이 규칙보다
    // 앞선다). 그리고 편집기 갈래가 그 **뒤에** 붙어 있어야 한다. 블록 전체를 보므로 극성을 뒤집거나
    // 순서를 바꾸면 죽는다.
    const block =
        \\        if controller?.anyOverlayOpen == true {
        \\            controller?.handleKeyDown(event)
        \\            return true
        \\        }
        \\        if controller?.editorOwnsChord(event) == true {
        \\            controller?.handleKeyDown(event)
        \\            return true
        \\        }
        \\        return super.performKeyEquivalent(with: event)
    ;
    try std.testing.expect(std.mem.indexOf(u8, swift, block) != null);

    // **판정을 Swift 로 복제하지 않았다.** 활성 Term 종류·resolver 순서를 Swift 가 다시 세면 출처가
    // 둘이 되고, 그 둘은 반드시 갈린다.
    try std.testing.expect(std.mem.indexOf(u8, swift, "editor_context_bindings") == null);
    try std.testing.expect(std.mem.indexOf(u8, swift, "add_next_occurrence") == null);
}

test "EMK6 Swift 헬퍼가 ABI 를 그대로 통과시킨다" {
    const swift = try readSwift();
    defer std.testing.allocator.free(swift);
    const helper =
        \\    func editorOwnsChord(_ event: NSEvent) -> Bool {
        \\        guard let session = appSession, var keyEvent = normalizedKeyEvent(from: event) else { return false }
        \\        return maru_macos_app_session_editor_owns_chord(session, &keyEvent) != 0
        \\    }
    ;
    try std.testing.expect(std.mem.indexOf(u8, swift, helper) != null);

    // **C 헤더에도 있어야 Swift 가 본다.**
    const header = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/app_host_abi.h",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "maru_macos_app_session_editor_owns_chord") != null);
}
