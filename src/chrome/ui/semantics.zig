//! interactive node 가 **같은 불변 스냅숏에** 싣는 접근성 서술자.
//!
//! 계약의 단일 출처는 [chrome 상호작용 이관](../../../docs/chrome-interaction-migration.md) §3 이다:
//!
//! > `UiActionId`만으로 keyboard와 accessibility를 표현할 수는 없다. interactive node는 같은
//! > immutable snapshot에 role, localized label, enabled/selected/expanded/value 및 keyboard
//! > focusability를 담은 typed semantic descriptor를 낸다. Swift adapter만 이 descriptor를 native
//! > accessibility element로 투영하고, Zig tree는 `NSAccessibility` object나 delegate를 보유하지 않는다.
//!
//! **왜 published tree 에 싣는가.** 이 tree 는 이미 "무엇이 어디에 있고 무엇을 누를 수 있는가"의 단일
//! 출처다(`rect`·`action`·`cursor`·`visual`). 접근성만 다른 경로로 두면 host 가 도메인 state 에서 역할과
//! 이름을 **다시 추론**하게 되고, 그 추론은 화면과 조용히 갈린다 — `cursor` 필드가 그 이유로 여기 있다.
//!
//! **무엇을 담지 않는가.** 플랫폼 타입(`NSAccessibilityRole` 문자열, AX notification, focus 이동)은 담지
//! 않는다. 이 파일은 **뜻**만 적고, 플랫폼 어휘로의 번역은 어댑터가 소유한다. 그래야 같은 tree 가
//! Windows(UI Automation)·모바일에서도 쓰인다.
//!
//! **아직 아무 host 도 이것을 읽지 않는다**(2026-08-25 기준). 계약과 첫 생산자만 선 상태이므로, 제품의
//! 접근성 상태를 "이관 완료"로 적으면 안 된다 — 그 판정은 어댑터가 서고 VoiceOver 로 확인한 뒤다.

const std = @import("std");

/// node 의 **뜻**. 플랫폼 역할 문자열이 아니라 그 앞 단계다.
///
/// 작게 유지한다 — 저장소가 실제로 그리는 것만 둔다. 새 역할은 그것을 내는 컴포넌트와 **함께** 온다
/// (역할만 먼저 늘리면 어댑터가 번역할 대상 없는 가지를 갖게 된다).
pub const Role = enum {
    /// 누르면 무언가 일어나는 면.
    button,
    /// 트리의 한 줄. `level`·`position_in_set`·`set_size` 를 함께 읽는다(파일 탐색기 행).
    tree_item,
    /// 평평한 목록의 한 줄(SCM 파일 행·세션 카드).
    list_item,
    /// 탭 하나.
    tab,
    /// 스크롤되는 목록·트리 컨테이너. 자식 줄들의 집합을 이룬다.
    scroll_view,
    /// 읽기 전용 글자.
    text,
    /// 이름만 있고 동작이 없는 묶음.
    group,
};

/// 하나의 서술자. **값 타입이고 문자열은 빌려온다** — 생명은 이 서술자를 실은 published tree 와 같다
/// (프레임 arena 또는 `i18n` 정적 테이블). tree 가 교체되면 이 슬라이스도 함께 죽는다.
pub const Semantics = struct {
    role: Role,
    /// 지역화된 이름. 컴포넌트가 `i18n.t(...)` 로 만든 문구이거나 **사용자 데이터**(파일 이름)다.
    ///
    /// 사용자 데이터는 번역하지 않는다 — 파일 이름을 번역하면 그 줄이 가리키는 대상이 달라진다.
    label: []const u8,
    /// 이름 옆에 **값으로** 읽히는 것(배지 개수, 상태 문구). 없으면 빈 슬라이스다.
    ///
    /// 이름에 붙여 한 문자열로 만들지 않는 이유: 스크린 리더는 이름과 값을 다른 시점에 읽고, 값만
    /// 바뀌었을 때 이름을 다시 읽지 않는다.
    value: []const u8 = "",
    /// 지금 누를 수 있나. 꺼진 컨트롤도 **자리와 이름은 있다**(P1 계약 — "누를 수 없는 컨트롤은
    /// 비활성으로 표시한다"). 그래서 서술자를 안 내는 것과 `enabled = false` 는 다른 말이다.
    enabled: bool = true,
    /// 고른 상태인가.
    selected: bool = false,
    /// 펼침 상태. `null` 은 **펼침이라는 개념이 없다**는 뜻이고 `false` 는 "접혀 있다"이다. 스크린
    /// 리더가 그 둘을 다르게 읽으므로 bool 하나로 뭉개지 않는다.
    expanded: ?bool = null,
    /// 키보드 포커스를 받을 수 있나. pointer 로만 닿는 면과 구별한다.
    focusable: bool = false,
    /// 집합 안 위치(1-based). 0 은 "집합의 일원이 아니다".
    ///
    /// **가상화 때문에 필요하다.** 화면에 뜬 노드는 창(window) 안 몇 줄뿐이라 host 가 자식 수를 세면
    /// 늘 창 크기가 나온다 — 스크린 리더가 "3 / 8" 이라고 읽지만 실제 목록은 400줄일 수 있다.
    position_in_set: u32 = 0,
    /// 집합의 전체 크기. 0 은 "모른다/해당 없음".
    set_size: u32 = 0,
    /// 트리 깊이(1-based). 0 은 "트리가 아니다".
    level: u32 = 0,
};

test "기본값은 '해당 없음'이지 거짓이 아니다" {
    const s: Semantics = .{ .role = .button, .label = "새로고침" };
    // 펼침 개념이 없는 것과 접혀 있는 것은 다른 사실이다.
    try std.testing.expect(s.expanded == null);
    // 집합 정보 0 은 "안 읽는다"이지 "첫 번째"가 아니다.
    try std.testing.expectEqual(@as(u32, 0), s.position_in_set);
    try std.testing.expectEqual(@as(u32, 0), s.set_size);
    try std.testing.expectEqual(@as(u32, 0), s.level);
    // 꺼짐은 명시해야 한다 — 기본이 켜짐이라 서술자를 낸 것만으로 "누를 수 있다"가 되지 않게.
    try std.testing.expect(s.enabled);
    try std.testing.expect(!s.focusable);
}
