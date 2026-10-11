//! 터미널 마우스의 수정자 규칙 — 중립 `mods` 비트의 뜻과, 그 비트로 정하는 셋(셀렉션 override · 블록 선택 · 리포트의 command 마스킹).
//!
//! 호스트는 OS 이벤트를 이 비트로 번역만 하고(macOS 는 ABI 가 넘기는 `mods`, Windows 는 `win32_mouse.modifiersFrom`), 뜻은 이 파일 하나가
//! 소유한다([layering-and-portability.md](../../docs/layering-and-portability.md) §3.5). 예전에는 macOS `app_session.zig` 의 인라인 판정과
//! Windows `win32_mouse.zig` 가 그것을 읽어 와 따로 적은 사본이 있었다 — 한쪽만 고치면 같은 코어가 호스트마다 다르게 반응한다.
//!
//! 비트 값은 `terminal.input_report.reportMouse` 의 `mods` 규약(xterm `cb` 의 수정자 자리)이다.

/// shift.
pub const shift: u8 = 4;
/// option(macOS) · alt(Windows) — xterm 의 meta 자리.
pub const meta: u8 = 8;
/// ctrl.
pub const ctrl: u8 = 16;
/// command(⌘). Windows 엔 그 키가 없다 — 키보드 바인딩은 `Ctrl` 을 `command` 로 번역하지만 마우스 리포트의 수정자는 xterm 규약대로다.
pub const command: u8 = 32;

/// **shift·option(alt)는 셀렉션 override 다** — 셸 리포트를 누르고 로컬 선택이 가져간다. TUI 가 마우스를 다 먹으면 사용자가 화면의
/// 글자를 복사할 방법이 없어진다 — 그 탈출구다(iTerm2 관례: shift+click 은 선형, option+click 은 블록).
pub fn selectionOverride(mods: anytype) bool {
    return (mods & shift) != 0 or (mods & meta) != 0;
}

/// 마우스를 셸이 가져가는가(트래킹 모드이고 셀렉션 override 가 아니다), 로컬 선택이 가져가는가.
pub fn reportsToShell(tracking_active: bool, mods: anytype) bool {
    return tracking_active and !selectionOverride(mods);
}

/// 블록(사각) 선택인가 — **셀렉션 override 의 option(alt)가 사각 선택을 켠다.**
pub fn blockSelection(mods: anytype) bool {
    return (mods & meta) != 0;
}

/// 리포트에 실을 `mods` — **command 비트를 뗀다.** `reportMouse` 의 `cb = button + mods + motion` 에서 32 가 SGR motion 비트와 겹쳐
/// press 가 motion 으로 오인되거나 `cb` 가 부풀어 리포트가 오염된다(macOS 에서는 command 가 사이드바 그룹 드래그 수정자이기도 하다).
pub fn reportModifiers(mods: anytype) @TypeOf(mods) {
    return mods & ~@as(@TypeOf(mods), command);
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "셀렉션 override 는 shift·option 이고, 셸 리포트를 누른다 — 두 호스트의 정수 꼴 모두" {
    for ([_]u8{ shift, meta, shift | meta, shift | ctrl }) |m| {
        try testing.expect(selectionOverride(m));
        try testing.expect(!reportsToShell(true, m));
    }
    try testing.expect(!selectionOverride(@as(u8, ctrl | command)));
    try testing.expect(reportsToShell(true, @as(u8, ctrl)));
    try testing.expect(!reportsToShell(false, @as(u8, 0)));
    // macOS ABI 의 `mods` 는 i32 다 — 같은 답이어야 한다.
    try testing.expect(selectionOverride(@as(i32, 8)));
    try testing.expect(reportsToShell(true, @as(i32, 16)));
}

test "블록 선택은 option(alt)이다" {
    try testing.expect(blockSelection(@as(u8, meta)));
    try testing.expect(blockSelection(@as(i32, meta | shift)));
    try testing.expect(!blockSelection(@as(u8, shift | ctrl | command)));
}

test "리포트의 수정자는 command 만 뗀다 — 다른 비트와 정수 꼴은 그대로" {
    try testing.expectEqual(@as(u8, shift | ctrl), reportModifiers(@as(u8, shift | ctrl | command)));
    try testing.expectEqual(@as(i32, meta), reportModifiers(@as(i32, meta | command)));
    try testing.expectEqual(@as(u8, 0), reportModifiers(@as(u8, command)));
}
