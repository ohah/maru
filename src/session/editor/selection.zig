//! caret과 선택 범위 — **항상 배열이다**([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.2).
//!
//! 멀티 커서가 1급 결정이라 단수 selection을 두었다가 나중에 배열로 넓히면 편집 연산을 전부
//! 재작성해야 한다. 그래서 커서가 하나뿐인 N1에서도 배열로 시작한다.
//!
//! **위치는 byte offset이다**(§3.1). 줄·열이 아니라서 랩·접힘·가상 텍스트에 영향받지 않는다.
//!
//! **anchor는 점이 아니라 범위다.** 더블클릭으로 단어를 잡고 드래그하면 그 단어가 통째로 유지돼야
//! 하는데, anchor가 점이면 뒤로 끌 때 단어가 잘린다. VSCode도 같은 이유로 `selectionStart`를
//! `Range`로 든다(`cursorCommon.ts`의 `SingleCursorState`) — 여기 규칙은 그 구조에서 유도했다.

const std = @import("std");

/// anchor를 무엇으로 잡았는가. **드래그가 이어질 때 확장 단위를 정한다** — 더블클릭 후 드래그는
/// 단어 단위로, 트리플클릭 후 드래그는 줄 단위로 늘어난다.
///
/// 이 값이 없으면 드래그 중에 "원래 무엇을 잡았는지"를 알 수 없어 항상 글자 단위가 된다.
/// VSCode의 `SelectionStartKind`에 대응한다.
/// 이 byte가 **낱말 글자**인가. 소스 코드 기준이다 — 식별자를 이루는 것(영숫자·`_`·`$`)과 ASCII
/// 밖(한글·CJK·이모지)이 낱말이고 나머지는 구분자다.
///
/// **주소창(`text_field.zig`)과 규칙이 다른 것이 맞다.** 그쪽은 URL이라 `/`·`.`·`?`가 의미 있는
/// 경계이지만, 코드에서 `foo.bar()`를 더블클릭하면 `foo`만 잡히기를 기대한다. VSCode도 에디터와
/// 입력 위젯의 단어 규칙을 따로 둔다(`wordCharacterClass` vs 위젯 기본값).
///
/// **ASCII 밖을 통째로 낱말로 치는 것은 근사다.** 한글 `안녕하세요`를 더블클릭하면 전체가 잡히는데,
/// 형태소 경계를 아는 것이 옳지만 그것은 ICU 급 사전이 필요하다. CJK를 구분자로 치면 한 글자씩만
/// 잡혀 훨씬 나쁘다 — 그래서 이쪽으로 근사한다(VSCode도 CJK를 한 덩어리로 잡는다).
fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_' or b == '$' or b >= 0x80;
}

/// `offset`이 놓인 **낱말의 범위**. 구분자 위면 그 구분자 하나만 잡는다(빈 범위를 주지 않는다 —
/// 더블클릭이 아무 일도 안 하면 사용자는 클릭이 씹힌 것으로 읽는다).
///
/// **UTF-8 경계로 스냅하지 않는다.** `isWordByte`가 이어 byte(`0x80` 이상)를 전부 낱말로 치므로
/// 다중 byte 글자는 통째로 한 덩어리에 들어간다 — 중간에서 끊길 수 없다.
pub fn wordRangeAt(bytes: []const u8, offset: usize) struct { lo: usize, hi: usize } {
    if (bytes.len == 0) return .{ .lo = 0, .hi = 0 };
    const at = @min(offset, bytes.len);
    // 줄 끝(또는 문서 끝)을 눌렀으면 **앞** 글자를 본다 — 그 자리에는 글자가 없다.
    const probe = if (at == bytes.len or at == 0) (if (at == 0) at else at - 1) else at;
    const word = isWordByte(bytes[probe]);

    // **줄을 넘지 않는다.** 개행은 구분자이므로 구분자 런이 그대로 다음 줄까지 흐른다 — 줄 끝
    // 공백을 더블클릭하면 개행이 딸려오고(실측: `"foo  \nbar"`의 4를 누르면 `{32,32,10}`), 빈 줄을
    // 누르면 개행 넷이 잡혀 네 줄이 선택됐다. 복사가 그 개행을 그대로 낸다.
    if (bytes[probe] == '\n') return .{ .lo = probe, .hi = probe }; // 개행 자체는 고를 것이 없다
    var lo = probe;
    while (lo > 0 and bytes[lo - 1] != '\n' and isWordByte(bytes[lo - 1]) == word) lo -= 1;
    var hi = probe + 1;
    while (hi < bytes.len and bytes[hi] != '\n' and isWordByte(bytes[hi]) == word) hi += 1;
    return .{ .lo = lo, .hi = hi };
}

pub const AnchorKind = enum {
    /// 단순 클릭·키보드 이동. anchor 범위가 비어 있다.
    simple,
    /// 더블클릭으로 단어를 잡았다.
    word,
    /// 트리플클릭으로 줄을 잡았다.
    line,
    /// **제스처가 아니라 일치로 잡았다**(§9.1 "다음 일치 추가"). 잡은 범위가 낱말일 수도 아닐 수도
    /// 있어서 `word`·`line` 어느 쪽도 사실이 아니다.
    ///
    /// **없던 값을 더한 이유**: 이 열거는 *"무엇을 잡았는가"*를 말하고 드래그 확장이 그 값을 읽는데,
    /// 낱말 조각을 `word`라 적으면 끌 때 없는 낱말 경계로 늘어난다. 오늘은 그 경로가 닿지 않지만
    /// (마우스를 누르면 새 selection이 서서 `kind`가 덮인다) **관측 안 된다는 이유로 거짓을 적으면
    /// 그것이 참이 되는 날 조용히 틀린다.** 확장 규칙은 `simple`과 같다 — 글자 단위로 는다.
    match,
};

/// 세로 이동 시 유지할 **목표 시각 열**.
///
/// **L2는 이 값을 해석하지 않는다**(§3.2) — 시각 열은 뷰 폭·랩·접힘에 의존하는 L3 개념이라,
/// 여기서는 selection과 생사를 같이하도록 들고만 있는다.
///
/// **`line_end`가 별도 값인 이유**: "줄 끝에 붙어서" 세로로 움직이면 길이가 다른 줄에서도 계속 끝에
/// 있어야 한다(VSCode `moveToEndOfLine`의 `sticky`). VSCode는 이것을 `leftoverVisibleColumns`에
/// `MAX_SAFE_SMALL_INTEGER - maxColumn`이라는 **거대한 수**를 넣어 표현하는데, 그러면 "아주 큰 목표 열"과
/// "줄 끝 고정"이 같은 표현이 되어 읽는 쪽이 의도를 알 수 없다. 여기서는 그 둘을 갈라 둔다.
pub const Goal = union(enum) {
    /// 목표 열 없음. 다음 세로 이동이 현재 열에서 시작한다.
    none,
    /// 이 시각 열을 향한다.
    col: u32,
    /// 줄 끝에 붙는다 — 어느 줄에서도 그 줄의 끝으로 간다.
    line_end,

    pub fn eql(a: Goal, b: Goal) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .none, .line_end => true,
            .col => |x| x == b.col,
        };
    }
};

/// 열/블록 선택의 **원본 사각형**([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.2a).
///
/// **단수인 이유는 마우스가 하나이기 때문이다** — 두 사각형을 동시에 끌 수 없다. "줄마다 selection
/// 하나"인 **파생 결과**만 배열이며, 두 번째 드래그는 앞의 원본을 **대체**한다(⌥클릭으로 커서를
/// 추가하는 것과 다르다 — 그쪽은 결과 배열에 쌓인다).
///
/// 드래그 중 매 프레임 selection 배열을 다시 파생해야 하는데, **결과만 봐서는 "지금 열 선택 중인가"도
/// "어디서 시작했는가"도 알 수 없다**(우연히 같은 모양이 나올 수 있다). 그래서 원본을 따로 든다.
///
/// **좌표가 시각 행·열이다** — 랩·접힘·뷰 폭에 의존하므로 §3.1의 byte offset 축이 아니다. `goal`과 같은
/// 규율으로 **L2는 들고만 있고 갱신·해석은 L3**가 한다.
///
/// VSCode는 이것을 selection과 별도로 두지만(`IColumnSelectData`), 그것은 공개 API `Selection`에 필드를
/// 추가할 수 없어서다. 우리 `Selection`은 내부 타입이라 그 제약이 없고, §2.4가 selection 자체를 **뷰
/// 상태**로 정했으므로 열 선택 원본과 생명주기가 같다 — 그래서 `Selections`가 직접 든다.
pub const ColumnAnchor = struct {
    /// 드래그를 시작한 시각 행·열.
    from_row: u32,
    from_col: u32,
    /// 지금 끌고 있는 시각 행·열.
    to_row: u32,
    to_col: u32,
};

/// 선택 하나.
///
/// 저장하는 것은 **anchor 범위 + focus 점**이고, 실제 선택 범위는 그 둘에서 **파생**한다(`start`/`end`).
/// VSCode가 `selection`을 `selectionStart`와 `position`에서 계산하는 것과 같다 — 파생으로 두면
/// 드래그 방향이 바뀔 때 상태를 고쳐 쓸 필요가 없다.
pub const Selection = struct {
    /// anchor 범위의 시작. 단순 클릭이면 `anchor_end`와 같다.
    ///
    /// **순서가 뒤집힌 값이 들어와도 조회는 안전하다** — `anchorLo`/`anchorHi`가 `@min`/`@max`로
    /// 읽으므로, 잘못된 리터럴이 있어도 선택 범위가 사용자가 본 것과 달라지지 않는다. assert는
    /// ReleaseFast에서 사라지므로 불변식을 그것에만 맡기지 않는다.
    anchor_start: usize,
    /// anchor 범위의 끝.
    anchor_end: usize,
    /// 움직이는 끝(caret이 있는 쪽).
    focus: usize,
    kind: AnchorKind = .simple,
    /// focus 쪽 목표 열.
    goal: Goal = .none,
    /// anchor 쪽 목표 열.
    ///
    /// **선택을 유지한 채 focus만 움직일 때는 쓰이지 않는다**(anchor가 제자리이므로). 필요한 것은
    /// **selection 전체를 세로로 평행이동**할 때다 — VSCode `translateUp`/`translateDown`이 anchor와
    /// focus를 함께 옮기며 `selectionStartLeftoverVisibleColumns`를 쓴다. 하나만 두면 평행이동에서
    /// anchor 쪽이 열을 잃는다.
    ///
    /// **chord 를 `⌃⌘↑/↓` 라 적었던 것은 틀렸다(2026-09-05 정정).** VSCode 기본 keybinding 에 그 조합은
    /// 없다 — `translateUp`/`translateDown` 은 사용자 커맨드가 아니라 `addCursorUp`/`addCursorDown` 의
    /// **부품**이고, 사용자가 닿는 자리는 `insertCursorAbove`/`Below`(`⌥⌘↑`/`⌥⌘↓`)다. 이 필드를 읽는
    /// 첫 소비자가 그 연산이다(§3.2b).
    anchor_goal: Goal = .none,

    /// caret 하나(선택 없음)를 만든다.
    pub fn at(offset: usize) Selection {
        return .{ .anchor_start = offset, .anchor_end = offset, .focus = offset };
    }

    /// 점 anchor에서 시작하는 선택(키보드 shift+이동 등).
    pub fn fromPoints(anchor: usize, focus: usize) Selection {
        return .{ .anchor_start = anchor, .anchor_end = anchor, .focus = focus };
    }

    /// 범위를 잡고 시작하는 선택(더블·트리플 클릭). `focus`는 보통 범위의 한쪽 끝이다.
    ///
    /// **`kind`와 anchor 범위는 함께 가야 한다.** 점 anchor에 `.word`를 붙이면 "단어로 잡았는데 그
    /// 단어가 없는" 상태가 되고, N2의 드래그 확장이 무엇을 기준으로 늘릴지 알 수 없다.
    pub fn fromAnchorRange(a_start: usize, a_end: usize, focus: usize, kind: AnchorKind) Selection {
        std.debug.assert(a_start <= a_end);
        std.debug.assert((kind == .simple) == (a_start == a_end));
        return .{ .anchor_start = a_start, .anchor_end = a_end, .focus = focus, .kind = kind };
    }

    /// anchor 범위의 작은 쪽. 필드 순서가 뒤집혀 있어도 옳게 답한다.
    pub fn anchorLo(self: Selection) usize {
        return @min(self.anchor_start, self.anchor_end);
    }

    /// anchor 범위의 큰 쪽.
    pub fn anchorHi(self: Selection) usize {
        return @max(self.anchor_start, self.anchor_end);
    }

    /// anchor 범위가 비었는가(점 anchor).
    pub fn anchorIsPoint(self: Selection) bool {
        return self.anchor_start == self.anchor_end;
    }

    /// **고정단** — 선택의 움직이지 않는 끝.
    ///
    /// 드래그 방향이 정한다: 오른쪽으로 끌면 anchor 범위의 **시작**이, 왼쪽으로 끌면 **끝**이 고정된다.
    /// 그래야 잡은 단어가 어느 방향으로 끌어도 통째로 남는다. VSCode `_computeSelection`과 같은 규칙이다.
    pub fn fixedEnd(self: Selection) usize {
        const lo = self.anchorLo();
        if (self.anchorIsPoint() or self.focus > lo) return lo;
        return self.anchorHi();
    }

    pub fn start(self: Selection) usize {
        return @min(self.fixedEnd(), self.focus);
    }

    pub fn end(self: Selection) usize {
        return @max(self.fixedEnd(), self.focus);
    }

    /// 선택된 byte 수. caret이면 0이다.
    pub fn len(self: Selection) usize {
        return self.end() - self.start();
    }

    /// 범위 없이 caret만 있는 상태인가.
    pub fn isEmpty(self: Selection) bool {
        return self.start() == self.end();
    }

    /// focus가 고정단보다 **문서 앞쪽**인가. 병합이 방향을 보존할 때 쓴다.
    ///
    /// **좌우와 위아래를 가르지 않는다** — 위치가 byte offset 하나뿐이라(§3.1) 두 방향이 같은 축이다.
    /// 같은 줄에서 왼쪽으로 끌든 윗줄로 끌든 focus가 작아지므로 둘 다 여기서 참이다. 화면상의 방향이
    /// 필요한 곳은 L3이고, 그쪽은 offset을 시각 행·열로 환산한 뒤 본다.
    pub fn isReversed(self: Selection) bool {
        return self.focus < self.fixedEnd();
    }

    /// 두 selection이 겹치거나 맞닿는가. **맞닿는 것도 겹침으로 본다** — `[0,5)`와 `[5,9)`를 그대로
    /// 두면 그 경계에 두 caret이 남아 같은 자리에 두 번 삽입된다.
    ///
    /// **판정은 파생된 선택 범위로 한다 — anchor 범위는 보지 않는다.** anchor의 일부가 선택 밖에
    /// 있을 수 있기 때문이다(단어를 잡고 그 안으로 focus를 옮기면 그렇다). 겹침은 **사용자가 보는
    /// 범위**의 문제이고, anchor는 다음 드래그를 위한 내부 상태다.
    pub fn touches(self: Selection, other: Selection) bool {
        return self.start() <= other.end() and other.start() <= self.end();
    }
};

/// 커서 개수 상한([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.2).
///
/// 정규식 검색의 "모두 선택"은 매치 수만큼 커서를 만들므로 한 번의 조작이 수만 개를 낳을 수 있고,
/// 그 상태에서는 **편집마다 모든 커서의 offset을 매핑**해야 해 입력이 멈춘다. 넘으면 앞에서부터
/// 남기고 **잘랐다는 사실을 알린다** — 조용히 자르면 사용자는 뒤쪽 매치가 왜 안 바뀌었는지 모른다.
///
/// **이 값은 잠정이다 — 우리 측정이 아니라 VSCode `multiCursorLimit`의 기본값을 빌려 왔다.**
/// §3.0(버퍼 표현)·§4.2(폰트 advance)가 "구현 전 실측"을 규율로 세웠는데 여기서는 수치를 그대로
/// 가져다 썼으므로, **N2에서 매핑 비용을 재고 다시 고른다**(§3.2). 계약인 것은 **상한이 존재한다는
/// 것과 잘림을 알린다는 것**이고, 숫자 자체는 아니다.
pub const max_cursors: usize = 10_000;

/// selection 배열. **항상 1개 이상**이고 `primary`는 그 안의 유효한 인덱스다.
///
/// 0개를 허용하면 모든 소비처가 "커서 없음" 분기를 져야 한다. 편집기는 빈 파일에도 커서를 보이므로
/// 그 상태가 존재하지 않는다.
pub const Selections = struct {
    items: []Selection,
    primary: usize,
    /// 열/블록 선택의 원본. **드래그 중에만 있다**(§3.2a).
    ///
    /// **`null`이 VSCode `isReal`을 대신한다** — 별도 bool을 들면 "없음"과 "있지만 가짜"라는 두 표현이
    /// 생겨 읽는 쪽이 어느 것이 진짜인지 판단해야 한다.
    column: ?ColumnAnchor = null,

    /// 불변식을 지키며 만든다. **여기를 거치지 않고 리터럴로 만들면 그 불변식이 없다** — 빈 배열이나
    /// 범위 밖 primary는 `primarySelection()`에서 밟는다.
    pub fn init(items: []Selection, primary: usize) Selections {
        std.debug.assert(items.len > 0);
        std.debug.assert(primary < items.len);
        const self = Selections{ .items = items, .primary = primary };
        // **정렬을 여기서 강제한다.** `isSorted`를 만들어 놓고 아무도 부르지 않으면 그것은 불변식이
        // 아니라 관례다 — 편집을 뒤에서부터 적용하는 전제(§3.3)가 조용히 깨진다. `mergeOverlapping`의
        // 결과는 항상 이 조건을 만족하므로 정상 경로에서는 걸리지 않는다.
        std.debug.assert(self.isSorted());
        return self;
    }

    /// primary selection. 스크롤 추종·상태바 위치 표시의 기준이다(§3.2).
    pub fn primarySelection(self: Selections) Selection {
        // 불변식이 깨진 채로 읽으면 조용히 엉뚱한 메모리를 읽는다. Debug에서 즉시 멈춘다.
        std.debug.assert(self.items.len > 0);
        std.debug.assert(self.primary < self.items.len);
        return self.items[self.primary];
    }

    /// 문서 순서로 정렬돼 있는가. **편집을 뒤에서부터 적용하려면 필요한 불변식이다**(§3.2) —
    /// 순서가 없으면 앞쪽 offset이 밀린 뒤에 뒤쪽을 적용하게 된다. `mergeOverlapping`의 결과는
    /// 항상 이 조건을 만족하므로, 그것을 거쳐 만든 배열은 따로 확인할 필요가 없다.
    pub fn isSorted(self: Selections) bool {
        if (self.items.len < 2) return true;
        var i: usize = 1;
        while (i < self.items.len) : (i += 1) {
            if (self.items[i].start() < self.items[i - 1].start()) return false;
        }
        return true;
    }

    /// **가로 이동 뒤에 부른다**(§3.2). 세로 이동만 goal을 유지한다 — 좌우로 움직인 뒤에도 옛 목표
    /// 열이 남으면 다음 위/아래 이동이 사용자가 방금 떠난 열로 튄다.
    ///
    /// `invalidateVisualState`와 **사건이 다르다**: 그쪽은 "좌표계가 바뀌어서"(뷰 폭 변경)라 열
    /// 선택 원본까지 지우고, 이쪽은 "사용자가 열을 새로 정해서"라 goal만 건드린다.
    pub fn resetGoalsAfterHorizontalMove(self: *Selections) void {
        for (self.items) |*s| {
            s.goal = .none;
            s.anchor_goal = .none;
        }
    }

    /// **undo/redo가 selection을 복원할 때 부른다**(§3.3).
    ///
    /// 텍스트와 selection 배열·primary는 되돌리지만 **`column`은 되돌리지 않는다** — 그것은 문서
    /// 상태가 아니라 **진행 중인 제스처**이고, undo로 드래그가 부활하면 마우스를 놓은 사용자가
    /// 여전히 열 선택 중인 화면을 본다. `goal`도 같은 이유다(다음 세로 이동이 옛 목표 열로 튄다).
    ///
    /// 지금은 `invalidateVisualState`와 같은 일을 하지만 **이름을 나눠 둔다** — 부르는 이유가 다르고
    /// (한쪽은 뷰가 바뀌어서, 한쪽은 시간을 되감아서), 나중에 한쪽만 규칙이 달라질 수 있다.
    pub fn clearGestureState(self: *Selections) void {
        self.invalidateVisualState();
    }

    /// **시각 좌표가 무의미해졌을 때 부른다** — 뷰 폭 변경·랩 토글·접힘 변경(§3.2a).
    ///
    /// 그 순간 옛 시각 행·열은 다른 위치를 가리키므로, 그대로 두면 다음 프레임의 파생이 사용자가 잡은
    /// 것과 다른 사각형을 만든다. `goal`이 같은 이유로 무효화되는 것과 한 규율이다.
    pub fn invalidateVisualState(self: *Selections) void {
        self.column = null;
        for (self.items) |*s| {
            s.goal = .none;
            s.anchor_goal = .none;
        }
    }

    /// 커서 개수. 상태바가 "여럿이면 커서 개수"를 표시할 때 쓴다(§2.2).
    pub fn count(self: Selections) usize {
        return self.items.len;
    }

    /// 선택된 총 byte 수(모든 selection 합).
    pub fn totalSelected(self: Selections) usize {
        var total: usize = 0;
        for (self.items) |s| total += s.len();
        return total;
    }
};

/// 겹치는 selection들을 합치고 primary를 승계시킨다.
///
/// **primary가 사라지면 그것을 흡수한 selection이 primary를 승계한다**(§3.2). 승계 규칙이 없으면
/// 병합 후 primary 인덱스가 엉뚱한 selection을 가리켜 스크롤이 튄다.
///
/// `items`를 **제자리에서** 정렬·병합하고 남은 개수를 돌려준다. 할당하지 않으므로 편집 hot path에서
/// 부담이 없다.
pub fn mergeOverlapping(items: []Selection, primary: usize) struct { len: usize, primary: usize } {
    // 호출자가 범위 밖 primary를 넘기면 아래 `items[primary]`가 남의 메모리를 읽는다.
    std.debug.assert(items.len == 0 or primary < items.len);
    if (items.len <= 1) return .{ .len = items.len, .primary = primary };

    // 어느 selection이 primary였는지를 정렬 전에 표시해 둔다. 정렬이 인덱스를 흩뜨리므로
    // 위치가 아니라 **값**으로 따라가야 한다.
    const p_anchor_start = items[primary].anchor_start;
    const p_anchor_end = items[primary].anchor_end;
    const p_focus = items[primary].focus;

    std.mem.sort(Selection, items, {}, lessByStart);

    var write: usize = 0;
    var new_primary: usize = 0;
    var primary_found = false;

    var read: usize = 0;
    while (read < items.len) : (read += 1) {
        const cur = items[read];
        const is_primary = cur.anchor_start == p_anchor_start and
            cur.anchor_end == p_anchor_end and cur.focus == p_focus;

        if (write > 0 and items[write - 1].touches(cur)) {
            const prev = items[write - 1];
            const lo = @min(prev.start(), cur.start());
            const hi = @max(prev.end(), cur.end());
            // 방향은 **살아남은 쪽**의 것을 쓴다 — 병합 결과의 caret이 어디 있어야 하는지는 정할 수
            // 없고, 임의로 뒤집으면 다음 shift+이동이 반대로 간다.
            const reversed = prev.isReversed();
            items[write - 1] = .{
                // 병합 결과의 anchor는 **점**이다. 원래 잡았던 단어/줄 경계는 이미 의미를 잃었다 —
                // 합쳐진 범위는 그 어느 단어와도 대응하지 않는다.
                .anchor_start = if (reversed) hi else lo,
                .anchor_end = if (reversed) hi else lo,
                .focus = if (reversed) lo else hi,
                .kind = .simple,
                // 목표 열도 버린다. 병합된 범위의 그것은 어느 쪽 것도 맞지 않는다.
                .goal = .none,
                .anchor_goal = .none,
            };
            if (is_primary) {
                new_primary = write - 1;
                primary_found = true;
            }
        } else {
            items[write] = cur;
            if (is_primary) {
                new_primary = write;
                primary_found = true;
            }
            write += 1;
        }
    }

    // 값으로 못 찾는 경우(같은 값이 여럿이라 앞엣것이 먼저 매칭됨)는 0으로 떨어뜨린다 —
    // 유효한 인덱스인 것이 중요하고, 같은 값이면 어느 쪽을 가리켜도 동작이 같다.
    return .{ .len = write, .primary = if (primary_found) new_primary else 0 };
}

fn lessByStart(_: void, a: Selection, b: Selection) bool {
    if (a.start() != b.start()) return a.start() < b.start();
    return a.end() < b.end();
}

const testing = std.testing;

test "caret은 빈 선택이다" {
    const c = Selection.at(5);
    try testing.expect(c.isEmpty());
    try testing.expect(c.anchorIsPoint());
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(usize, 5), c.start());
    try testing.expectEqual(@as(usize, 5), c.end());
    try testing.expectEqual(AnchorKind.simple, c.kind);
}

test "점 anchor: 역방향 선택도 그대로 유지된다 — 방향이 정보다" {
    const back = Selection.fromPoints(10, 3);

    try testing.expect(back.isReversed());
    try testing.expectEqual(@as(usize, 3), back.start());
    try testing.expectEqual(@as(usize, 10), back.end());
    try testing.expectEqual(@as(usize, 7), back.len());
}

test "범위 anchor: 오른쪽으로 끌면 잡은 단어가 통째로 남는다" {
    // "hello world"에서 "hello"(0..5)를 더블클릭하고 오른쪽 8까지 끈다.
    const s = Selection.fromAnchorRange(0, 5, 8, .word);

    // 고정단은 anchor 시작(0) — 단어 전체가 선택 안에 들어온다.
    try testing.expectEqual(@as(usize, 0), s.fixedEnd());
    try testing.expectEqual(@as(usize, 0), s.start());
    try testing.expectEqual(@as(usize, 8), s.end());
}

test "범위 anchor: 왼쪽으로 끌어도 잡은 단어가 통째로 남는다 — 점 anchor면 잘린다" {
    // 같은 "hello"(0..5)를 잡고 왼쪽으로 갈 수는 없으니, 뒤쪽 단어를 잡고 앞으로 끈다.
    // "one two"에서 "two"(4..7)를 잡고 offset 1까지 끈다.
    const s = Selection.fromAnchorRange(4, 7, 1, .word);

    // 고정단이 anchor **끝**(7)이 되어야 "two"가 통째로 남는다.
    try testing.expectEqual(@as(usize, 7), s.fixedEnd());
    try testing.expectEqual(@as(usize, 1), s.start());
    try testing.expectEqual(@as(usize, 7), s.end());
    try testing.expect(s.isReversed());
}

test "범위 anchor: focus가 anchor 시작과 같으면 범위 전체가 남는다" {
    // 왼쪽 끝까지 정확히 끈 경계. 여기서 고정단이 시작으로 바뀌면 선택이 빈다.
    const s = Selection.fromAnchorRange(4, 7, 4, .word);

    try testing.expectEqual(@as(usize, 7), s.fixedEnd());
    try testing.expectEqual(@as(usize, 4), s.start());
    try testing.expectEqual(@as(usize, 7), s.end());
    try testing.expect(!s.isEmpty());
}

test "범위 anchor: focus가 범위 안이면 시작부터 focus까지다" {
    // 단어를 잡고 그 안에서 움직이는 경우. 경계 스냅은 상위(마우스 처리)가 하고 여기서는 규칙만 본다.
    const s = Selection.fromAnchorRange(0, 5, 3, .word);

    try testing.expectEqual(@as(usize, 0), s.fixedEnd());
    try testing.expectEqual(@as(usize, 3), s.end());
}

test "줄 anchor도 같은 규칙을 쓴다" {
    const s = Selection.fromAnchorRange(10, 20, 5, .line);
    try testing.expectEqual(AnchorKind.line, s.kind);
    try testing.expectEqual(@as(usize, 20), s.fixedEnd());
    try testing.expectEqual(@as(usize, 5), s.start());
}

test "양끝이 각자 목표 열을 갖는다 — selection 평행이동에서 둘 다 필요하다" {
    const s = Selection{
        .anchor_start = 10,
        .anchor_end = 10,
        .focus = 40,
        .goal = .{ .col = 12 },
        .anchor_goal = .{ .col = 3 },
    };

    try testing.expect(s.goal.eql(.{ .col = 12 }));
    try testing.expect(s.anchor_goal.eql(.{ .col = 3 }));
}

test "줄 끝 고정은 큰 숫자가 아니라 별도 값이다 — 의도가 읽혀야 한다" {
    const sticky = Selection{ .anchor_start = 0, .anchor_end = 0, .focus = 5, .goal = .line_end };

    try testing.expect(sticky.goal.eql(.line_end));
    // 아주 큰 목표 열과 구별된다. 같은 표현이면 소비처가 둘을 갈라낼 수 없다.
    try testing.expect(!sticky.goal.eql(.{ .col = std.math.maxInt(u32) }));
}

test "Goal.eql: 세 변종이 서로 구별된다" {
    const none: Goal = .none;
    const line_end: Goal = .line_end;
    const col3: Goal = .{ .col = 3 };

    try testing.expect(none.eql(.none));
    try testing.expect(!none.eql(.line_end));
    try testing.expect(!none.eql(.{ .col = 0 }));
    try testing.expect(line_end.eql(.line_end));
    try testing.expect(!line_end.eql(.{ .col = 3 }));
    try testing.expect(col3.eql(.{ .col = 3 }));
    try testing.expect(!col3.eql(.{ .col = 4 }));
}

test "맞닿는 범위도 겹침으로 본다 — 경계에 caret 둘이 남으면 중복 삽입된다" {
    const a = Selection.fromPoints(0, 5);
    const b = Selection.fromPoints(5, 9);
    try testing.expect(a.touches(b));
    try testing.expect(b.touches(a));

    const far = Selection.fromPoints(6, 9);
    try testing.expect(!a.touches(far));
}

test "merge: 겹치지 않으면 그대로 둔다" {
    var items = [_]Selection{ Selection.at(0), Selection.at(10), Selection.at(20) };
    const r = mergeOverlapping(&items, 1);

    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(usize, 1), r.primary);
    try testing.expectEqual(@as(usize, 10), items[r.primary].focus);
}

test "merge: 정렬되지 않은 입력도 처리한다" {
    var items = [_]Selection{ Selection.at(20), Selection.at(0), Selection.at(10) };
    const r = mergeOverlapping(&items, 0); // primary는 offset 20

    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(usize, 20), items[r.primary].focus);
}

test "merge: 겹치는 둘을 합친다" {
    var items = [_]Selection{ Selection.fromPoints(0, 6), Selection.fromPoints(4, 10) };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 0), items[0].start());
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: 앞 것이 뒤 것을 통째로 품으면 앞 것의 끝이 살아남는다" {
    // **겹치는 둘을 합치는 판정자가 이미 있는데도 뮤턴트가 살아남았다**(적대적 검증 2026-08-26 —
    // 병합 끝을 `@max(prev.end, cur.end)`에서 `cur.end`로 바꿔도 아무도 못 잡았다).
    //
    // 그 판정자의 배치가 **계단식**이라(`[0,6)` + `[4,10)`) 뒤 것의 끝이 언제나 더 크고, 두 식이
    // 같은 답을 냈다. **앞이 뒤를 품는 배치**에서만 갈린다 — 긴 낱말을 잡아 두고 그 안쪽을
    // `⌘⌃D`로 잡으면 실제로 생긴다.
    var items = [_]Selection{ Selection.fromPoints(0, 10), Selection.fromPoints(2, 5) };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 0), items[0].start());
    // `cur.end`(=5)를 쓰면 **5~10이 사라진다**.
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: primary가 흡수되면 흡수한 쪽이 승계한다" {
    var items = [_]Selection{ Selection.fromPoints(0, 6), Selection.fromPoints(4, 10) };
    const r = mergeOverlapping(&items, 1);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expect(r.primary < r.len);
    try testing.expectEqual(@as(usize, 0), r.primary);
}

test "merge: 병합 결과가 방향을 뒤집지 않는다" {
    var items = [_]Selection{ Selection.fromPoints(6, 0), Selection.fromPoints(4, 10) };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expect(items[0].isReversed());
    try testing.expectEqual(@as(usize, 0), items[0].start());
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: 병합 결과의 anchor는 점이 되고 kind가 simple로 돌아간다" {
    // 단어를 잡은 selection이 합쳐지면 그 단어 경계는 의미를 잃는다 — 합쳐진 범위는 어느 단어와도
    // 대응하지 않으므로, 그대로 두면 이후 드래그가 사라진 단어를 기준으로 확장한다.
    var items = [_]Selection{
        Selection.fromAnchorRange(0, 5, 6, .word),
        Selection.fromPoints(4, 10),
    };
    _ = mergeOverlapping(&items, 0);

    try testing.expect(items[0].anchorIsPoint());
    try testing.expectEqual(AnchorKind.simple, items[0].kind);
    try testing.expectEqual(@as(usize, 0), items[0].start());
    try testing.expectEqual(@as(usize, 10), items[0].end());
}

test "merge: 셋이 사슬로 이어지면 하나가 된다" {
    var items = [_]Selection{
        Selection.fromPoints(0, 5),
        Selection.fromPoints(4, 9),
        Selection.fromPoints(8, 12),
    };
    const r = mergeOverlapping(&items, 0);

    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 12), items[0].end());
}

test "merge: 병합된 selection은 양쪽 목표 열을 버린다" {
    var items = [_]Selection{
        .{ .anchor_start = 0, .anchor_end = 0, .focus = 6, .goal = .{ .col = 3 }, .anchor_goal = .{ .col = 1 } },
        .{ .anchor_start = 4, .anchor_end = 4, .focus = 10, .goal = .line_end, .anchor_goal = .{ .col = 2 } },
    };
    _ = mergeOverlapping(&items, 0);

    try testing.expect(items[0].goal.eql(.none));
    try testing.expect(items[0].anchor_goal.eql(.none));
}

test "merge: 하나짜리는 그대로다" {
    var items = [_]Selection{Selection.at(3)};
    const r = mergeOverlapping(&items, 0);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 0), r.primary);
}

test "Selections: primary와 개수·선택 합" {
    var items = [_]Selection{ Selection.fromPoints(0, 3), Selection.fromPoints(10, 14) };
    const sels = Selections.init(&items, 1);

    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 7), sels.totalSelected());
    try testing.expectEqual(@as(usize, 10), sels.primarySelection().fixedEnd());
}

test "Selections.init: 불변식을 세운다" {
    var items = [_]Selection{Selection.at(0)};
    const sels = Selections.init(&items, 0);

    try testing.expectEqual(@as(usize, 1), sels.count());
    try testing.expectEqual(@as(usize, 0), sels.primarySelection().focus);
}

test "merge 결과를 그대로 Selections에 넣을 수 있다 — primary가 항상 유효하다" {
    // 병합이 개수를 줄여도 돌려준 primary는 줄어든 범위 안이어야 한다. 이 왕복이 깨지면
    // primarySelection()이 범위 밖을 읽는다.
    var items = [_]Selection{
        Selection.fromPoints(0, 6),
        Selection.fromPoints(4, 10),
        Selection.fromPoints(20, 24),
    };
    const r = mergeOverlapping(&items, 1);

    try testing.expect(r.primary < r.len);
    const sels = Selections.init(items[0..r.len], r.primary);
    try testing.expectEqual(@as(usize, 2), sels.count());
}

test "anchor 범위가 선택 밖으로 나갈 수 있고, 겹침 판정은 그것을 보지 않는다" {
    // "hello"(0..5)를 잡고 focus를 3으로 → 선택은 [0,3)이지만 anchor_end는 5다.
    const s = Selection.fromAnchorRange(0, 5, 3, .word);
    try testing.expectEqual(@as(usize, 3), s.end());
    try testing.expectEqual(@as(usize, 5), s.anchor_end);

    // 겹침은 선택 범위 기준이라 [4,6)과 닿지 않는다 — anchor_end(5)가 그 안에 있어도 그렇다.
    const other = Selection.fromPoints(4, 6);
    try testing.expect(!s.touches(other));
}

test "caret은 별도 구조가 아니라 길이 0인 selection이다" {
    // 커서 개수 = items.len. 둘을 나눠 두면 "커서 셋 + 선택 둘" 같은 불일치가 생긴다(§3.2).
    var items = [_]Selection{ Selection.at(10), Selection.fromPoints(20, 25), Selection.at(40) };
    const sels = Selections.init(&items, 0);

    try testing.expectEqual(@as(usize, 3), sels.count()); // 커서 셋
    try testing.expect(items[0].isEmpty()); // caret만
    try testing.expect(!items[1].isEmpty()); // 선택 있음
    try testing.expectEqual(@as(usize, 10), items[0].focus); // focus가 곧 caret 위치
    try testing.expectEqual(@as(usize, 5), sels.totalSelected()); // 선택된 byte는 가운데 것뿐
}

test "열 선택 원본은 Selections가 든다 — null이 isReal을 대신한다" {
    var items = [_]Selection{Selection.at(0)};
    var sels = Selections.init(&items, 0);

    // 드래그 전에는 열 선택이 아니다. 별도 bool 없이 optional 하나로 표현된다(§3.2a).
    try testing.expect(sels.column == null);

    sels.column = .{ .from_row = 2, .from_col = 4, .to_row = 5, .to_col = 9 };
    try testing.expect(sels.column != null);
    try testing.expectEqual(@as(u32, 2), sels.column.?.from_row);
    try testing.expectEqual(@as(u32, 9), sels.column.?.to_col);
}

test "시각 상태 무효화는 열 원본과 goal을 함께 지운다" {
    // **같은 구조체에 있으므로 한 번에 묶인다** — 이것이 L3에 따로 두는 대비 실질 이득이다(§3.2a).
    // 뷰 폭이 바뀌면 옛 시각 행·열은 다른 위치를 가리킨다.
    var items = [_]Selection{
        .{ .anchor_start = 0, .anchor_end = 0, .focus = 5, .goal = .{ .col = 12 }, .anchor_goal = .line_end },
        .{ .anchor_start = 20, .anchor_end = 20, .focus = 20, .goal = .line_end },
    };
    var sels = Selections.init(&items, 0);
    sels.column = .{ .from_row = 1, .from_col = 2, .to_row = 3, .to_col = 4 };

    sels.invalidateVisualState();

    try testing.expect(sels.column == null);
    for (sels.items) |s| {
        try testing.expect(s.goal.eql(.none));
        try testing.expect(s.anchor_goal.eql(.none));
    }
    // **byte offset은 건드리지 않는다** — 그 축은 뷰 폭과 무관하다(§3.1).
    try testing.expectEqual(@as(usize, 5), sels.items[0].focus);
    try testing.expectEqual(@as(usize, 20), sels.items[1].focus);
}

test "undo 복원은 열 선택 원본을 되살리지 않는다 (§3.3)" {
    // 열 선택 원본은 **진행 중인 제스처**이지 문서 상태가 아니다. undo로 드래그가 부활하면
    // 마우스를 놓은 사용자가 여전히 열 선택 중인 화면을 본다.
    var items = [_]Selection{
        .{ .anchor_start = 0, .anchor_end = 0, .focus = 7, .goal = .{ .col = 3 } },
        .{ .anchor_start = 30, .anchor_end = 30, .focus = 30, .goal = .line_end },
    };
    var sels = Selections.init(&items, 1);
    sels.column = .{ .from_row = 0, .from_col = 0, .to_row = 4, .to_col = 8 };

    sels.clearGestureState();

    try testing.expect(sels.column == null);
    for (sels.items) |s| try testing.expect(s.goal.eql(.none));
    // **복원된 selection 자체는 남는다** — undo가 되돌리는 것은 텍스트와 커서 배열이다.
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expectEqual(@as(usize, 1), sels.primary);
    try testing.expectEqual(@as(usize, 7), sels.items[0].focus);
}

test "열 선택 원본은 누적되지 않고 대체된다 (§3.2a)" {
    // 마우스가 하나라 두 사각형을 동시에 끌 수 없다. 두 번째 드래그는 앞의 원본을 덮어쓴다 —
    // ⌥클릭으로 커서를 **추가**하는 것(결과 배열에 쌓임)과 다르다.
    var items = [_]Selection{ Selection.at(0), Selection.at(10) };
    var sels = Selections.init(&items, 0);

    sels.column = .{ .from_row = 0, .from_col = 0, .to_row = 2, .to_col = 5 };
    sels.column = .{ .from_row = 8, .from_col = 1, .to_row = 9, .to_col = 3 };

    try testing.expectEqual(@as(u32, 8), sels.column.?.from_row); // 두 번째만 남는다
    try testing.expectEqual(@as(usize, 2), sels.count()); // 결과 배열은 그대로
}

test "정렬 불변식: mergeOverlapping의 결과는 항상 정렬돼 있다 (§3.2)" {
    // **편집을 뒤에서부터 적용하려면 필요하다** — 순서가 없으면 앞쪽 offset이 밀린 뒤에 뒤쪽을
    // 적용하게 되어 두 번째 삽입이 엉뚱한 자리에 간다.
    var items = [_]Selection{
        Selection.fromPoints(50, 55),
        Selection.at(10),
        Selection.fromPoints(30, 35),
    };
    const merged = mergeOverlapping(&items, 0);
    const sels = Selections.init(items[0..merged.len], merged.primary);
    try testing.expect(sels.isSorted());
    try testing.expectEqual(@as(usize, 10), sels.items[0].start());
}

test "정렬 판정: 뒤집힌 배열을 isSorted가 구분한다" {
    // `init`이 assert로 강제하므로 여기서는 판정 함수만 직접 확인한다 — 정렬되지 않은 배열로
    // `init`을 부르는 것 자체가 계약 위반이고 Debug에서 즉시 멈춘다.
    var bad = [_]Selection{ Selection.at(40), Selection.at(10) };
    const unchecked = Selections{ .items = &bad, .primary = 0 };
    try testing.expect(!unchecked.isSorted());

    var good = [_]Selection{ Selection.at(10), Selection.at(40) };
    try testing.expect(Selections.init(&good, 0).isSorted());
}

test "가로 이동은 goal을 재설정하되 열 선택 원본은 건드리지 않는다 (§3.2)" {
    // 무효화(뷰 폭 변경)와 **다른 사건**이다 — 그쪽은 좌표계가 바뀌어서, 이쪽은 사용자가 열을
    // 새로 정해서다. 열 선택 드래그 중 좌우 이동은 사각형을 유지해야 한다.
    var items = [_]Selection{
        .{ .anchor_start = 0, .anchor_end = 0, .focus = 5, .goal = .{ .col = 12 }, .anchor_goal = .line_end },
    };
    var sels = Selections.init(&items, 0);
    sels.column = .{ .from_row = 1, .from_col = 2, .to_row = 3, .to_col = 4 };

    sels.resetGoalsAfterHorizontalMove();

    try testing.expect(sels.items[0].goal.eql(.none));
    try testing.expect(sels.items[0].anchor_goal.eql(.none));
    try testing.expect(sels.column != null); // 원본은 살아 있다
}

test "커서 상한이 있다 — 검색 '모두 선택'이 입력을 멈추지 않게" {
    try testing.expect(max_cursors > 0);
    // 상한은 "얼마나 많으면 매핑이 입력을 멈추는가"에서 나온 값이다. 정확한 수치보다 **상한이
    // 존재한다는 것**이 계약이며, 넘었을 때 잘랐다는 사실을 알리는 것도 함께다(§3.2).
    try testing.expectEqual(@as(usize, 10_000), max_cursors);
}

test "wordRangeAt: 줄을 넘지 않고, 낱말/구분자 런을 각각 잡는다" {
    // **직접 테스트가 0개였다**(적대적 검증). 제품 두 곳이 부르는데 줄 경계·ASCII 밖·`$` 규칙이
    // 전부 무판정이라, 셋을 각각 되돌린 뮤턴트가 전 스위트를 통과했다.
    const t = std.testing;

    // ⑴ **줄을 안 넘는다.** 줄 끝 공백을 눌러도 개행이 안 딸려온다(그 전에는 `{32,32,10}`이었다).
    {
        const b = "foo  \nbar   baz\n";
        const r = wordRangeAt(b, 4);
        try t.expectEqual(@as(usize, 3), r.lo);
        try t.expectEqual(@as(usize, 5), r.hi); // 개행 앞에서 멈춘다
    }
    // ⑵ **빈 줄은 고를 것이 없다.** 그 전에는 개행 넷이 잡혀 네 줄이 선택됐다.
    {
        const b = "a\n\n\n\nb\n";
        const r = wordRangeAt(b, 2);
        try t.expectEqual(r.lo, r.hi);
    }
    // ⑶ 낱말 런.
    {
        const b = "alpha beta gamma";
        const r = wordRangeAt(b, 8);
        try t.expectEqual(@as(usize, 6), r.lo);
        try t.expectEqual(@as(usize, 10), r.hi);
    }
    // ⑷ **구분자 런도 잡는다** — 빈 범위를 주면 클릭이 씹힌 것으로 보인다.
    {
        const b = "foo(((bar";
        const r = wordRangeAt(b, 4);
        try t.expectEqual(@as(usize, 3), r.lo);
        try t.expectEqual(@as(usize, 6), r.hi);
    }
    // ⑸ **`$`와 `_`는 낱말이다**(식별자를 이룬다).
    {
        const b = "let $x_1 = 2";
        const r = wordRangeAt(b, 5);
        try t.expectEqual(@as(usize, 4), r.lo);
        try t.expectEqual(@as(usize, 8), r.hi); // "$x_1" 통째로
    }
    // ⑹ **ASCII 밖은 통째로 한 낱말**이고, UTF-8 경계를 깨지 않는다.
    {
        const b = "say 안녕하세요 ok";
        const r = wordRangeAt(b, 6); // 다중 byte 글자 **중간**
        try t.expect(std.unicode.utf8ValidateSlice(b[r.lo..r.hi]));
        try t.expectEqualStrings("안녕하세요", b[r.lo..r.hi]);
    }
    // ⑺ 줄 끝·문서 끝을 눌러도 앞 글자를 본다(그 자리에는 글자가 없다).
    {
        const b = "abc";
        const r = wordRangeAt(b, 3);
        try t.expectEqual(@as(usize, 0), r.lo);
        try t.expectEqual(@as(usize, 3), r.hi);
    }
    try t.expectEqual(@as(usize, 0), wordRangeAt("", 0).hi);
}

/// 정렬된 **행 배열** 위의 한 자리 — `(행, 행 안 byte)`.
///
/// 비교 뷰가 쓴다. 그쪽은 문서 offset 축이 없다(§4.1g "비교 뷰"): 화면에 서는 것이 원본 줄이 아니라
/// 짝을 맞춰 정렬한 배열이고, **원본에 없는 빈 행**이 그 안에 섞여 있으며, 줄 끝 문자는 떼어져 있다.
///
/// **offset과 달리 전순서 스칼라가 아니다** — 비교가 사전식 두 단계다. `Selection`의 `@min`/`@max`·
/// 뺄셈이 그대로 안 되는 이유이고, 그래서 이 타입이 따로 있다.
pub const RowPos = struct {
    row: usize,
    byte: usize,

    pub fn lessThan(a: RowPos, b: RowPos) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.byte < b.byte;
    }

    pub fn eql(a: RowPos, b: RowPos) bool {
        return a.row == b.row and a.byte == b.byte;
    }

    pub fn min(a: RowPos, b: RowPos) RowPos {
        return if (lessThan(a, b)) a else b;
    }

    pub fn max(a: RowPos, b: RowPos) RowPos {
        return if (lessThan(a, b)) b else a;
    }
};

/// 행 배열 축의 선택 — `Selection`의 **계약을 그대로** 옮긴 것이고 축만 다르다.
///
/// **anchor가 범위인 이유가 여기서도 같다.** 점으로 두면 더블클릭으로 잡은 단어를 **뒤로** 끌 때
/// 그 단어가 통째로 사라진다(실측: `"beta"`를 잡고 왼쪽으로 끌면 `"pha "`가 남았다). 단일 편집기는
/// `fixedEnd`가 그것을 막는데, 비교 뷰가 점 anchor로 따로 서 있어 같은 제스처가 다르게 답했다.
/// `kind`도 같은 이유다 — 없으면 더블클릭 뒤 드래그가 단어가 아니라 글자 단위로 는다.
///
/// **`side`는 여기 없다.** 그것은 "한 Term이 두 열을 든다"의 부산물이라 뷰가 일급이 되면 사라지고,
/// `DiffSide`가 platform 타입이라 `check-boundaries`가 session 층으로 들이는 것도 막는다.
/// 어느 열인가는 이 값을 **드는 쪽**이 든다.
pub const RowSelection = struct {
    anchor_start: RowPos,
    anchor_end: RowPos,
    focus: RowPos,
    kind: AnchorKind = .simple,

    pub fn at(pos: RowPos) RowSelection {
        return .{ .anchor_start = pos, .anchor_end = pos, .focus = pos };
    }

    pub fn fromAnchorRange(a_start: RowPos, a_end: RowPos, focus: RowPos, kind: AnchorKind) RowSelection {
        std.debug.assert(!RowPos.lessThan(a_end, a_start));
        std.debug.assert((kind == .simple) == RowPos.eql(a_start, a_end));
        return .{ .anchor_start = a_start, .anchor_end = a_end, .focus = focus, .kind = kind };
    }

    pub fn anchorLo(self: RowSelection) RowPos {
        return RowPos.min(self.anchor_start, self.anchor_end);
    }

    pub fn anchorHi(self: RowSelection) RowPos {
        return RowPos.max(self.anchor_start, self.anchor_end);
    }

    pub fn anchorIsPoint(self: RowSelection) bool {
        return RowPos.eql(self.anchor_start, self.anchor_end);
    }

    /// **고정단** — 드래그 방향이 정한다. 뒤로 끌면 anchor 범위의 **끝**이 고정돼 잡은 단위가 남는다.
    pub fn fixedEnd(self: RowSelection) RowPos {
        const lo = self.anchorLo();
        if (self.anchorIsPoint() or RowPos.lessThan(lo, self.focus)) return lo;
        return self.anchorHi();
    }

    pub fn start(self: RowSelection) RowPos {
        return RowPos.min(self.fixedEnd(), self.focus);
    }

    pub fn end(self: RowSelection) RowPos {
        return RowPos.max(self.fixedEnd(), self.focus);
    }

    pub fn isEmpty(self: RowSelection) bool {
        return RowPos.eql(self.start(), self.end());
    }
};

test "RowSelection: anchor가 범위라 뒤로 끌어도 잡은 단위가 남는다" {
    const t = std.testing;
    const p = struct {
        fn at(row: usize, byte: usize) RowPos {
            return .{ .row = row, .byte = byte };
        }
    };

    // "alpha beta gamma"에서 `beta`(6..10)를 더블클릭으로 잡았다.
    var sel = RowSelection.fromAnchorRange(p.at(0, 6), p.at(0, 10), p.at(0, 10), .word);
    try t.expect(RowPos.eql(sel.start(), p.at(0, 6)));
    try t.expect(RowPos.eql(sel.end(), p.at(0, 10)));

    // **뒤로** 끌어 `alpha` 안(byte 2)으로 갔다 — `beta`의 끝이 남아야 한다.
    sel.focus = p.at(0, 2);
    try t.expect(RowPos.eql(sel.start(), p.at(0, 2)));
    try t.expect(RowPos.eql(sel.end(), p.at(0, 10))); // 점 anchor였다면 6이 되어 단어가 잘린다

    // 앞으로 끌면 시작이 남는다.
    sel.focus = p.at(0, 13);
    try t.expect(RowPos.eql(sel.start(), p.at(0, 6)));
    try t.expect(RowPos.eql(sel.end(), p.at(0, 13)));

    // 행을 가로질러도 사전식으로 답한다.
    sel.focus = p.at(3, 0);
    try t.expect(RowPos.eql(sel.start(), p.at(0, 6)));
    try t.expect(RowPos.eql(sel.end(), p.at(3, 0)));
    sel.focus = p.at(0, 0);
    try t.expect(RowPos.eql(sel.end(), p.at(0, 10)));

    // caret 하나는 비어 있다.
    try t.expect(RowSelection.at(p.at(2, 5)).isEmpty());
    try t.expect(!sel.isEmpty());
}

test "RowPos: 사전식 순서 — 행이 먼저고 그 다음이 byte" {
    const t = std.testing;
    const a: RowPos = .{ .row = 1, .byte = 99 };
    const b: RowPos = .{ .row = 2, .byte = 0 };
    try t.expect(RowPos.lessThan(a, b)); // 행이 이긴다 — byte만 보면 뒤집힌다
    try t.expect(!RowPos.lessThan(b, a));
    try t.expect(RowPos.eql(RowPos.min(a, b), a));
    try t.expect(RowPos.eql(RowPos.max(a, b), b));
    try t.expect(!RowPos.lessThan(a, a));
}
