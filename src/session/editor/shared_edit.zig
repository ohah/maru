//! 연결된 다른 뷰의 선택과 자동 닫기 표식을 편집 delta에 매핑한다.
//! OS·Term·renderer를 모르는 정책이며 실제 두 Term 판정자는 macOS 공유 게시 fixture가 실행한다.
const delta = @import("delta.zig");
const selection = @import("selection.zig");

pub fn mapSelection(d: delta.Delta, sel: selection.Selection) selection.Selection {
    var moved = sel;
    // 수동 뷰의 삽입은 caret 뒤, 범위 시작 앞·끝 뒤에 붙인다.
    // VS Code oneCursor의 AlwaysGrowsWhenTypingAtEdges 동작을 참고한 독립 정책이다.
    // 삭제·교체 내부 좌표는 Maru delta.mapOffset의 시작점 clamp를 유지한다.
    const upper = sel.end();
    moved.anchor_start = mapPoint(d, sel.anchor_start, sel.isEmpty() or sel.anchor_start == upper);
    moved.anchor_end = mapPoint(d, sel.anchor_end, sel.isEmpty() or sel.anchor_end == upper);
    moved.focus = mapPoint(d, sel.focus, sel.isEmpty() or sel.focus == upper);
    moved.goal = .none;
    moved.anchor_goal = .none;
    return moved;
}

fn mapPoint(d: delta.Delta, at: usize, after_insert: bool) usize {
    var mapped = delta.mapOffset(d, at);
    if (after_insert) {
        for (d.changes) |c| {
            if (c.start == at and c.start == c.end) mapped += c.text.len;
        }
    }
    return mapped;
}

/// 같은 위치 삽입 또는 쌍의 어느 쪽 교체/삭제는 자동 닫기의 소유 근거를 깨뜨린다.
/// 표식을 이동만 하면 Backspace가 사용자가 새로 넣은 글자와 닫는 문자를 함께 지울 수 있다.
pub fn mapAutoClose(d: delta.Delta, at: usize) ?usize {
    for (d.changes) |c| {
        if (c.end > c.start and c.start <= at and c.end >= at) return null;
        if (c.start == c.end and c.start == at and c.text.len > 0) return null;
    }
    return delta.mapOffset(d, at);
}
