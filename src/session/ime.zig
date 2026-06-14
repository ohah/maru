//! L2 session core — IME(입력기) 키 트랜잭션의 순수 판정. macOS keyDown이 interpretKeyEvents로 모은 확정
//! 텍스트·조합 변화·삭제 신호를 받아 "확정 텍스트 전송 / 무시 / 일반 키 인코딩"을 결정한다 — 부작용(PTY 전송)
//! 에서 분리해 라이브 PTY 없이 단위 테스트한다(Ghostty의 shouldSuppressComposingControlInput 순수 판정과 같은
//! 방식). platform/macos/app_dev_session에서 추출(docs/layering-and-portability.md §3 — 2차 추출, "입력 수학" 그룹).
//! OS·렌더 무관 — std만 의존.

const std = @import("std");

/// imeEnd의 순수 판정 결과. 부작용(PTY 전송)에서 분리해 라이브 PTY 없이 unit 테스트한다.
pub const Decision = union(enum) {
    commit_text: []const u8, // 확정 텍스트만 전송(키 자체는 입력기가 소비)
    ignore, // 조합 조작 키(자모 삭제) / 조합 중 단일 C0 — 아무것도 안 보냄
    encode_key, // 일반 키 — 기존 인코딩 경로
};

/// IME 키의 일괄 판정(순수). 규칙(위에서 첫 일치):
/// 1. 확정 텍스트가 쌓였으면 그것만 보낸다. 단 조합 중 단일 C0(조합 조작용 Ctrl+H류)은 버림.
///    insertText + deleteBackward가 한 keyDown에 왔으면(한글 마지막 자모 백스페이스) 입력기가 조합 글자를
///    커밋한 뒤 그 삭제를 보낸 것 — 삭제가 확정 텍스트의 마지막 코드포인트를 상쇄한다. 남으면 그만 커밋,
///    없으면 아무것도 안 보낸다(PTY에 글자가 박혔다가 다음 BS로 지워야 하는 문제를 없앤다 — 실측 기반).
/// 2. 텍스트는 없지만 조합이 변했으면(자모 삭제) 키를 보내지 않는다.
/// 3. 둘 다 아니면 일반 키.
pub fn decide(composing: bool, inserted: []const u8, marked_changed: bool, did_delete: bool) Decision {
    if (inserted.len > 0) {
        const lone_c0 = inserted.len == 1 and inserted[0] < 0x20;
        if (composing and lone_c0) return .ignore;
        if (did_delete) {
            const kept = dropLastCodepoint(inserted);
            if (kept.len == 0) return .ignore;
            return .{ .commit_text = kept };
        }
        return .{ .commit_text = inserted };
    }
    if (marked_changed) return .ignore;
    return .encode_key;
}

/// UTF-8 문자열에서 마지막 코드포인트를 뗀 슬라이스. continuation 바이트(0x80~0xBF)를 지나
/// lead 바이트까지 되돌린다. 잘못된 UTF-8이면 1바이트만 뗀다(안전).
fn dropLastCodepoint(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    var i: usize = s.len - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return s[0..i];
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 추출 전 app_dev_session.zig에 있던 단위 테스트를 코드와 함께 옮겼다(순수 판정이라 OS·PTY 무관).

test "decide routes IME keys: commit text once, ignore composition edits, encode plain keys" {
    // 1) 확정 텍스트가 있으면 그것만 보낸다(키는 입력기 소비 — 조합 확정 Enter는 개행 없음).
    try std.testing.expect(decide(true, "\xec\x95\x88", false, false) == .commit_text);
    try std.testing.expectEqualStrings("\xec\x95\x88", decide(true, "\xec\x95\x88", false, false).commit_text);
    // 2) 텍스트 없이 조합만 변하면(자모 삭제) 키 무전송.
    try std.testing.expect(decide(true, "", true, false) == .ignore);
    // 3) 조합 중 단일 C0(조합 조작용 Ctrl+H류)은 버린다.
    try std.testing.expect(decide(true, "\x08", false, false) == .ignore);
    // 4) 조합 아닐 때의 C0는 정상 텍스트로 본다(commit) — 조합 보호는 composing일 때만.
    try std.testing.expect(decide(false, "\x08", false, false) == .commit_text);
    // 5) 텍스트도 조합 변화도 없으면 일반 키(Enter/Backspace/기능키).
    try std.testing.expect(decide(false, "", false, false) == .encode_key);
    // 6) 여러 글자 확정도 통째로 commit(영문 일반 타이핑 포함).
    try std.testing.expectEqualStrings("ab", decide(false, "ab", false, false).commit_text);
    // 7) 마지막 자모 백스페이스: insertText("ㄴ") + deleteBackward 상쇄 -> 아무것도 안 보냄
    //    (실측: 가나->BS->가ㄴ->BS->가. ㄴ이 PTY에 박히지 않는다).
    try std.testing.expect(decide(true, "\xe3\x84\xb4", false, true) == .ignore); // "ㄴ"
    // 8) 다중 글자 insert + 삭제: 마지막 코드포인트만 상쇄, 나머지는 commit.
    try std.testing.expectEqualStrings("a", decide(false, "ab", false, true).commit_text);
}
