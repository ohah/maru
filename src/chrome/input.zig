//! 추상 입력 이벤트(OS 무관). platform 어댑터가 OS 입력(NSEvent 등)을 이걸로 변환해 host에 넘기고,
//! 컴포넌트 `handle`이 소비한다. 키보드(`.key`) + 모디파이어 + 마우스 포인터(`.pointer`). 포인터는 모달
//! 위젯(슬라이더 드래그·토글/색 클릭, CS-4)에 쓴다 — divider 드래그(down→move…→up)와 같은 라이브 포인터
//! 패턴(docs/layering-and-portability.md §6)을 ChromeHost가 활성 모달에 라우팅한다(CS-4-0). 좌표/hit-test는
//! divider/tabbar의 `hitTest`와 같은 backing-px 좌표계를 쓴다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");

/// 의미적 키(레이아웃 독립). 평문 입력은 `.char` + codepoint. left/right는 가로 포커스 이동(confirm 버튼 선택 등).
pub const Key = enum { enter, escape, up, down, left, right, backspace, char, other };

/// 모디파이어 상태. find의 Shift+Enter(이전 매치)·⌘/⌃/⌥+글자(닫기) 같은 조합 판정에 쓴다. platform 어댑터가
/// OS 모디파이어를 이걸로 매핑한다(예: app_session.chromeInputFromKeyEvent).
pub const Mods = struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
};

/// 포인터(마우스/트랙패드) 버튼. left=주 클릭(토글·슬라이더·항목 선택), right=보조(컨텍스트 메뉴),
/// other=그 외(중간 버튼 등 — 현재 위젯은 안 쓰지만 platform 어댑터가 버려도/넘겨도 되게 둔다).
pub const PointerButton = enum { left, right, other };

/// 포인터 이벤트 단계. down=버튼 누름(드래그 시작·hit-test), move=이동(버튼 누른 채면 드래그), up=버튼 뗌
/// (드래그 종료). divider 드래그와 같은 라이브 포인터 시퀀스(down→move…→up)를 모달 위젯에도 쓴다.
pub const PointerPhase = enum { down, move, up };

/// 포인터 이벤트. 좌표는 backing 픽셀(좌상단 원점) — divider/tabbar `hitTest`가 쓰는 좌표계와 동일하게
/// 맞춰, 모달 위젯 hit-test가 같은 산술을 공유한다. platform 어댑터(Swift)는 raw 좌표/버튼/모디파이어만
/// 넘기고(네이티브 최소), 좌표 해석·hit-test·드래그 상태는 Zig(컴포넌트/host)가 소유한다.
pub const PointerEvent = struct {
    phase: PointerPhase,
    x_px: f64,
    y_px: f64,
    button: PointerButton = .left,
    mods: Mods = .{},
};

pub const InputEvent = union(enum) {
    key: KeyEvent,
    pointer: PointerEvent,

    pub const KeyEvent = struct { key: Key, codepoint: u21 = 0, mods: Mods = .{} };
};

test "InputEvent: pointer 변형 태그·필드·기본값" {
    // 기본값: button=left, mods 전부 false.
    const down = InputEvent{ .pointer = .{ .phase = .down, .x_px = 12.5, .y_px = 34.0 } };
    try std.testing.expect(down == .pointer);
    try std.testing.expectEqual(PointerPhase.down, down.pointer.phase);
    try std.testing.expectEqual(@as(f64, 12.5), down.pointer.x_px);
    try std.testing.expectEqual(@as(f64, 34.0), down.pointer.y_px);
    try std.testing.expectEqual(PointerButton.left, down.pointer.button);
    try std.testing.expectEqual(Mods{}, down.pointer.mods);

    // move/up + 보조 버튼 + 모디파이어를 실어 나른다(라이브 드래그 시퀀스·우클릭 메뉴).
    const drag = InputEvent{ .pointer = .{ .phase = .move, .x_px = 1, .y_px = 2, .button = .left, .mods = .{ .shift = true } } };
    try std.testing.expectEqual(PointerPhase.move, drag.pointer.phase);
    try std.testing.expect(drag.pointer.mods.shift);
    const ctx = InputEvent{ .pointer = .{ .phase = .up, .x_px = 0, .y_px = 0, .button = .right } };
    try std.testing.expectEqual(PointerButton.right, ctx.pointer.button);

    // key 변형은 그대로 공존한다(회귀 가드).
    const k = InputEvent{ .key = .{ .key = .enter } };
    try std.testing.expect(k == .key);
}
