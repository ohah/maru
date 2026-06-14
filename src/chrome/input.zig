//! 추상 입력 이벤트(OS 무관). platform 어댑터가 OS 입력(NSEvent 등)을 이걸로 변환해 host에 넘기고,
//! 컴포넌트 `handle`이 소비한다. 키보드 + 모디파이어. 마우스(pointer)는 hit-test 컴포넌트(divider/tabbar, C2)
//! 이주 때 추가한다. 단일 출처: docs/chrome-strategy.md §5.4.

/// 의미적 키(레이아웃 독립). 평문 입력은 `.char` + codepoint.
pub const Key = enum { enter, escape, up, down, backspace, char, other };

/// 모디파이어 상태. find의 Shift+Enter(이전 매치)·⌘/⌃/⌥+글자(닫기) 같은 조합 판정에 쓴다. platform 어댑터가
/// OS 모디파이어를 이걸로 매핑한다(예: app_dev_session.chromeInputFromKeyEvent).
pub const Mods = struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
};

pub const InputEvent = union(enum) {
    key: KeyEvent,
    // pointer: PointerEvent — C2에서 추가(좌표 + 버튼/이동/업).

    pub const KeyEvent = struct { key: Key, codepoint: u21 = 0, mods: Mods = .{} };
};
