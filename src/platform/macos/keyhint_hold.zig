//! 단축키 힌트 홀드 감지 — **순수 상태머신**(헤드리스 테스트 가능). gesture 정책은 Zig(이 파일), OS 타이머 clock만
//! Swift(native 최소). Swift는 flagsChanged·timer fire·keyDown/blur를 이 머신에 그대로 흘리고, 돌아온 Action으로
//! 타이머 시작/취소·redraw만 한다.
//!
//! **루트커즈(간헐 미표시 — "Cmd 눌렀을 때 나올 때도 있고 안 나올 때도")**: 옛 Swift `handleModifierFlags`는 arm/cancel은
//! flagsChanged의 `event.modifierFlags`로 결정하면서, **타이머 만료 콜백에선 `NSEvent.modifierFlags`(전역 정적 상태)를
//! 다시 읽어** 트리거 단독을 재확인했다. 이 정적 읽기는 **두 번째 출처**라 이벤트 스트림과 어긋날 수 있다 — 타이머
//! 콜백 시점에 stale/빈 값을 주면 트리거를 쥐고 있어도 재확인이 false → set_key_hints(1)을 건너뛰어 미표시. (이벤트로
//! arm은 됐는데 fire에서 막히니 "가끔만 뜸".)
//!
//! **근본 수정**: 재확인의 두 번째 출처를 **없앤다**. 권위 출처는 flagsChanged 이벤트 스트림 하나다 — arm된 타이머가
//! 만료까지 **살아남았다는 것 자체가** "그 사이 취소(해제·다른 mod) flagsChanged가 없었다 = 트리거가 유지됐다"를 뜻한다.
//! 그래서 onTimerFire는 글로벌을 다시 안 읽고 `armed`만 보고 표시한다. 취소된 늦은 fire는 `armed=false`라 자연히 무시
//! (race 안전). 이 단일-출처 계약을 아래 테스트가 재현·고정한다.

const std = @import("std");
const maru = @import("maru");

pub const HintModifier = maru.config.theme.HintModifier;

/// 현재 눌린 modifier 집합(4개). Swift가 NSEvent.modifierFlags를 비트로 변환해 넘긴다.
pub const Mods = struct {
    command: bool = false,
    control: bool = false,
    option: bool = false,
    shift: bool = false,
};

/// 머신이 내는 동작. Swift가 매핑: arm_timer=OS 타이머 시작, cancel=타이머 무효화, show=visible 켜짐(redraw),
/// hide=visible 꺼짐(타이머 무효화+redraw), none=무동작. (visible 토글 자체는 호출자(app_session)가 chrome_host에 적용.)
pub const Action = enum(u32) { none = 0, arm_timer = 1, cancel = 2, show = 3, hide = 4 };

pub const KeyHintHold = struct {
    armed: bool = false, // delay 타이머 대기 중(아직 표시 전)
    shown: bool = false, // 배지 표시 중

    fn isSolo(mods: Mods, trigger: HintModifier) bool {
        return switch (trigger) {
            .command => mods.command and !mods.control and !mods.option and !mods.shift,
            .control => mods.control and !mods.command and !mods.option and !mods.shift,
            .option => mods.option and !mods.command and !mods.control and !mods.shift,
        };
    }

    /// 대기/표시를 끈다 — 표시 중이면 hide, 대기만이면 cancel(타이머 무효화), 아무것도 없으면 none.
    fn off(self: *KeyHintHold) Action {
        const was_armed = self.armed;
        self.armed = false;
        if (self.shown) {
            self.shown = false;
            return .hide;
        }
        return if (was_armed) .cancel else .none;
    }

    /// flagsChanged: 현재 modifier 집합 + config(enabled·trigger). 트리거가 **단독**으로 눌렸으면 arm, 아니면(다른 mod
    /// 동반·해제) 취소/숨김. **단독성·해제는 전적으로 이 이벤트 경로가 판정**한다(단일 출처).
    pub fn onFlags(self: *KeyHintHold, mods: Mods, enabled: bool, trigger: HintModifier) Action {
        if (!enabled) return self.off();
        if (isSolo(mods, trigger)) {
            if (self.shown or self.armed) return .none; // 이미 표시/대기 — 재-arm 안 함(중복 타이머 방지)
            self.armed = true;
            return .arm_timer;
        }
        return self.off();
    }

    /// delay 타이머 만료: **글로벌 modifier를 다시 안 읽는다**. armed면 표시한다 — 여기 도달했다는 건 그 사이 취소
    /// flagsChanged가 없었다는 뜻(있었으면 onFlags가 armed=false로 껐고 Swift가 타이머를 무효화했다). 취소된 늦은
    /// fire(armed=false)는 무시(race 안전). 이게 "두 번째 출처(NSEvent 재읽기)"를 없앤 루트커즈 수정이다.
    pub fn onTimerFire(self: *KeyHintHold) Action {
        if (!self.armed) return .none; // 취소됨 → 늦은 fire 무시
        self.armed = false;
        if (self.shown) return .none;
        self.shown = true;
        return .show;
    }

    /// 실제 키 입력(= 단축키 실행)·포커스 상실: 취소 + 표시 중이면 숨김.
    pub fn onKeyOrBlur(self: *KeyHintHold) Action {
        return self.off();
    }
};

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 루트커즈(타이머 만료 시 글로벌 재읽기라는 두 번째 출처) 재현·고정 + 정상 사이클·race·취소·비활성 계약.

const cmd = Mods{ .command = true };
const cmd_shift = Mods{ .command = true, .shift = true };
const none_mods = Mods{};

test "정상: 단독 트리거 → arm, 만료 → show, 해제 → hide" {
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.arm_timer, h.onFlags(cmd, true, .command));
    try std.testing.expectEqual(Action.show, h.onTimerFire());
    try std.testing.expect(h.shown);
    try std.testing.expectEqual(Action.hide, h.onFlags(none_mods, true, .command)); // 해제 → hide
    try std.testing.expect(!h.shown);
}

test "루트커즈 회귀: armed가 만료까지 살아남으면(취소 flagsChanged 없음) 글로벌 재읽기 없이 **무조건** show" {
    // 옛 Swift는 만료 콜백에서 NSEvent.modifierFlags(2번째 출처)를 다시 읽어 트리거 단독을 재확인했는데, 그 정적
    // 읽기가 stale/빈 값을 주면 트리거를 쥐고 있어도 재확인 false → 미표시("가끔만 뜸")였다. 권위 출처는 이벤트
    // 스트림 하나다: arm 후 어떤 flagsChanged도 없었다(취소 안 됨) → onTimerFire는 armed만 보고 반드시 show.
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.arm_timer, h.onFlags(cmd, true, .command));
    // arm과 fire 사이에 어떤 이벤트도 없다(트리거 유지). 옛 코드라면 여기서 글로벌 재읽기에 의존했다.
    try std.testing.expectEqual(Action.show, h.onTimerFire());
}

test "race 안전: 해제 flagsChanged로 취소된 뒤 늦게 도착한 타이머 fire는 표시 안 함" {
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.arm_timer, h.onFlags(cmd, true, .command));
    try std.testing.expectEqual(Action.cancel, h.onFlags(none_mods, true, .command)); // 해제 → cancel(대기만이라 hide 아님)
    try std.testing.expectEqual(Action.none, h.onTimerFire()); // 늦은 fire: armed=false라 무시
    try std.testing.expect(!h.shown);
}

test "다른 mod 추가(트리거 단독 아님) → 대기 취소" {
    var h = KeyHintHold{};
    _ = h.onFlags(cmd, true, .command); // arm
    try std.testing.expectEqual(Action.cancel, h.onFlags(cmd_shift, true, .command)); // +shift → 단독 아님 → cancel
    try std.testing.expectEqual(Action.none, h.onTimerFire());
}

test "keyDown/포커스 상실: 표시 중이면 hide, 대기만이면 cancel" {
    var shown_h = KeyHintHold{ .armed = false, .shown = true };
    try std.testing.expectEqual(Action.hide, shown_h.onKeyOrBlur());
    var armed_h = KeyHintHold{ .armed = true, .shown = false };
    try std.testing.expectEqual(Action.cancel, armed_h.onKeyOrBlur());
    var idle_h = KeyHintHold{};
    try std.testing.expectEqual(Action.none, idle_h.onKeyOrBlur());
}

test "비활성(enabled=false): arm 안 함, 표시 중이면 끔" {
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.none, h.onFlags(cmd, false, .command)); // 비활성 → arm 안 함
    try std.testing.expect(!h.armed);
    var shown = KeyHintHold{ .shown = true };
    try std.testing.expectEqual(Action.hide, shown.onFlags(cmd, false, .command)); // 비활성이면 표시 중이어도 끔
}

test "재-arm 가드: 이미 대기/표시 중이면 추가 arm 안 함(중복 타이머 방지)" {
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.arm_timer, h.onFlags(cmd, true, .command)); // 첫 arm
    try std.testing.expectEqual(Action.none, h.onFlags(cmd, true, .command)); // 또 단독이 와도 재-arm 안 함
    _ = h.onTimerFire(); // shown
    try std.testing.expectEqual(Action.none, h.onFlags(cmd, true, .command)); // 표시 중에도 none
}

test "트리거 = control: control 단독만 arm(command 단독은 무시)" {
    var h = KeyHintHold{};
    try std.testing.expectEqual(Action.none, h.onFlags(cmd, true, .control)); // command는 트리거 아님
    try std.testing.expectEqual(Action.arm_timer, h.onFlags(.{ .control = true }, true, .control));
}
