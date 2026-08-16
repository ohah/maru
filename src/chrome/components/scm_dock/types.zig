//! 소스 컨트롤 도크의 platform-neutral 입력 DTO다(docs/editor-surface-dock.md §3.5).
//!
//! 이 파일은 `AppSession`도 git 결과 버퍼도 보관하지 않는다. platform이 `session/scm_view.zig`의 행 모델을
//! **화면용 문자열로 이미 잘라** 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다
//! (Session Dock과 같은 규율 — component가 domain을 다시 해석하지 않는다).

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const ui_icon = @import("../../ui/icon.zig");
const typography = @import("../../ui/typography.zig");

/// 목록 그룹. `scm_view.Section`과 **같은 값 집합**이지만 component는 그쪽을 import하지 않는다 —
/// platform이 값을 옮기고, 값이 갈리면 그 변환 함수가 exhaustive switch에서 컴파일로 걸린다.
pub const Section = enum { staged, changes };

/// 도크 탭(§3.5.1). **축이 다르면 화면을 나눈다** — 세 탭은 서로 다른 질문에 답하고 항목 단위도 다르다
/// (변경 사항=파일, 히스토리=커밋, 에이전트=턴). 그래서 한 목록으로 합칠 수 없다.
pub const Tab = enum { changes, history, agent };

/// 행에 붙는 주 동작. 호버할 때만 보이는 컨트롤이다(§3.5.2).
pub const RowAction = enum { stage, unstage, none };

/// 상태 문자의 **의미**. 색을 고르는 것은 view이고, 여기서는 어떤 종류인지만 말한다 —
/// 색 결정이 platform으로 새면 테마마다 두 곳을 고쳐야 한다.
pub const StatusKind = enum {
    modified,
    /// 새로 생긴 것(`A`)과 추적되지 않은 것(`U`)은 같은 계열로 본다(VS Code 관례).
    added,
    deleted,
    /// 병합 충돌. 색은 위험 계열이지만 **동작이 없다**는 점이 더 중요하다(§3.5.2).
    conflicted,
};

pub const SectionItem = struct {
    section: Section,
    /// 그 그룹의 **전체** 파일 수(접혀 있어도 전체를 말한다).
    count: u32,
    collapsed: bool,
    /// 헤더 호버에 뜰 일괄 동작. `.none`이면 그 자리에 아무것도 그리지 않는다.
    action: RowAction,
};

pub const FileItem = struct {
    /// 이 행의 **모델 인덱스**. 화면 창(virtualized window) 안의 자리가 아니다 — host가 같은 스냅샷의
    /// 모델에서 이 행을 다시 찾는 열쇠이고, 창은 스크롤에 따라 움직인다. **창 자리를 쓰면 스크롤한 뒤
    /// 누른 행과 열리는 행이 어긋난다**(P1b가 그렇게 나갔다).
    model_index: u32 = 0,
    /// 파일 이름(굵게). 폭이 모자라도 **끝까지 남는다**.
    name: []const u8,
    /// 흐린 상대 경로. 폭이 좁아지면 **가장 먼저** 줄어든다.
    dir: []const u8,
    status: StatusKind,
    /// 화면에 그대로 그릴 한 글자(`M`·`A`·`D`·`U`·`R`…). 색은 `status`가 정한다.
    letter: u8,
    added: u32 = 0,
    removed: u32 = 0,
    /// 증감을 그릴 수 있나. 추적되지 않은 파일·충돌·하위 모듈은 숫자가 **존재하지 않는다**.
    has_delta: bool = false,
    /// numstat이 `-`를 준 파일 — 숫자 대신 그 사실을 적는다.
    binary: bool = false,
    action: RowAction,
    /// 지금 열려 있는 비교인가(강조).
    selected: bool = false,
};

pub const MoreItem = struct { section: Section, hidden: u32 };

pub const Item = union(enum) {
    section: SectionItem,
    file: FileItem,
    more: MoreItem,
    /// 목록이 불완전하다는 진술(누를 수 없다).
    notice: []const u8,
};

/// 목록 위의 요약 줄. 아직 커밋·필터가 없으므로 **숫자만** 싣는다.
pub const Summary = struct {
    added: u32 = 0,
    removed: u32 = 0,
};

pub const Props = struct {
    /// 도크 content rect(도크-로컬 좌표, 원점 0,0).
    viewport_px: layout.UiRect,
    /// Dock UI zoom. Session Dock과 같은 축이라 두 뷰의 행 높이가 함께 움직인다.
    scale_milli: u32 = 1000,
    /// 등폭 셀 폭. **`build`와 `view`가 같은 값을 봐야 한다** — 개수 배지의 자리는 이 값에서 나오고,
    /// 그 배지를 피해 앉아야 하는 일괄 동작 버튼의 자리는 `build`가 정한다. 둘이 갈리면 버튼이 배지 위로
    /// 올라오고, 배지는 paint 전용이라 **숫자를 눌렀는데 그룹 전체가 스테이지된다**(실측으로 그랬다).
    cell_width_px: u32 = 8,
    /// 이 tree를 만든 스냅샷 세대. action 표가 이 값으로 stale 클릭을 거부한다.
    snapshot_generation: u64 = 1,
    /// **가상화된 창**이다 — 화면에 보이는 만큼만 platform이 잘라 준다.
    items: []const Item = &.{},
    /// 스크롤 상태(전체 높이·현재 offset·첫 항목의 local y).
    scroll_offset_px: u32 = 0,
    content_h_px: u32 = 0,
    content_first_item_origin_y_px: i32 = 0,
    /// 브랜치 줄. 없으면(저장소를 못 잡음) 빈 문자열이고 그 줄을 그리지 않는다.
    branch: []const u8 = "",
    ahead: u32 = 0,
    behind: u32 = 0,
    has_ab: bool = false,
    summary: Summary = .{},
    /// 목록 대신 그릴 한 줄 안내(`변경 사항 없음`·`읽는 중…`). 있으면 목록은 비어 있다.
    empty_notice: []const u8 = "",
    /// 지금 열려 있는 탭. 모르는 값은 platform이 `.changes`로 clamp한다(§3.5.1) — component는 받은 값을
    /// 그대로 그린다.
    active_tab: Tab = .changes,
    /// `변경 사항` 탭 이름 옆에 붙는 **전체** 파일 수. **`items`로 셀 수 없다** — 그쪽은 가상화된 창이라
    /// 보이는 만큼만 오고, 스크롤 위치에 따라 숫자가 흔들린다.
    changed_file_count: u32 = 0,
    /// 커밋 메시지 상자에 보일 글자. 비면 안내 문구를 대신 그린다.
    commit_message: []const u8 = "",
    /// 상자가 보여 줄 **시각 행** 수(랩 결과). host가 `text_area.visibleRows`로 정해 준다 — 컴포넌트는
    /// 랩을 다시 계산하지 않는다(같은 계산이 두 곳이면 상자 높이와 그려지는 줄 수가 갈린다).
    commit_rows: u32 = 1,
    /// 커밋 버튼을 켤 수 있나. **실제 index 상태로만 정한다**(쓰기 문서 §7 — 낙관하지 않는다).
    commit_enabled: bool = false,
    /// 커밋 상자의 **편집 상태 스냅샷**. component는 편집하지 않는다 — host가 `TextField`로 편집하고
    /// 그 결과만 여기 싣는다(props는 immutable이고, 편집 상태가 둘이면 caret이 갈린다).
    commit_edit: CommitEdit = .{},
};

/// 커밋 상자의 편집 상태(§12 — 세로 축만 갖는 얇은 층). 가로 축(caret 열·선택 span)은 여전히
/// `text_field.fieldLayout`이 소유하고, 여기 있는 것은 그 함수에 넘길 **오프셋**뿐이다.
pub const CommitEdit = struct {
    /// 키를 받고 있나. 꺼져 있으면 caret도 선택 밴드도 그리지 않는다 — 안 깜빡이는 caret은
    /// "여기 쓰면 된다"가 아니라 "여기 뭔가 잘못됐다"로 읽힌다.
    focused: bool = false,
    /// 삽입점(바이트 오프셋). 개행이 섞여도 그대로 성립한다(§12.1 — `TextField`를 고치지 않는 이유).
    caret: usize = 0,
    /// 선택 구간(바이트 오프셋, 정렬되지 않을 수 있어 `lo`/`hi`로 읽는다).
    selection: ?Selection = null,
    /// IME 조합 중인 글자. caret 자리에 **끼워서** 그린다.
    preedit: []const u8 = "",
    /// 세로 스크롤 — 상자가 보여 줄 **첫 시각 행**이다(제약 ⑥: 논리 줄이 아니다).
    first_row: u32 = 0,
    /// 지금 위상에서 caret을 그릴까(깜빡임). **host가 위상을 소유한다** — 이 층에는 시간이 없다.
    /// 기본이 `true`라 위상을 안 주는 소비자(테스트·Lab)는 늘 보이는 caret을 얻는다.
    caret_visible: bool = true,
};

/// 선택 구간. `text_field.TextField.Selection`과 같은 모양이지만 **이 DTO가 자기 것을 갖는다** —
/// props는 platform이 채우는 값 묶음이고, 여기서 편집기 타입을 재수출하면 component 소비자가
/// 편집 API 전체를 딸려 보게 된다.
pub const Selection = struct {
    anchor: usize,
    focus: usize,

    pub fn lo(self: Selection) usize {
        return @min(self.anchor, self.focus);
    }
    pub fn hi(self: Selection) usize {
        return @max(self.anchor, self.focus);
    }
    pub fn empty(self: Selection) bool {
        return self.anchor == self.focus;
    }
};

/// 도크 치수. Session Dock과 같은 방식으로 zoom을 곱해 만든다 — 두 뷰가 같은 축으로 커지고 줄어야
/// 같은 컬럼에서 뷰를 갈아 끼울 때 행 높이가 튀지 않는다.
pub const DockMetrics = struct {
    /// 탭 줄(`변경 사항 (N) │ 히스토리 │ 에이전트`).
    tab_h: u32,
    /// 요약 줄(`+N -N`).
    summary_h: u32,
    /// 그룹 헤더 높이.
    section_h: u32,
    /// 파일 행 높이.
    row_h: u32,
    /// 브랜치 줄 높이.
    branch_h: u32,
    /// 커밋 메시지 상자의 **한 시각 행** 높이. 상자 전체 높이는 이것 × 보이는 행 수다 —
    /// 내용을 따라 자라고 상한에서 멈춘다(§12.2).
    commit_row_h: u32,
    /// 커밋 버튼 줄 높이.
    commit_button_h: u32,
    /// 커밋 상자의 **위아래 여백**. 글자가 테두리와 버튼 줄에 붙지 않게 한다 — 입력란은 글자가 상자
    /// 안에서 숨 쉬어야 눌러서 쓰는 자리로 읽힌다(사용자 지적 2026-08-16).
    commit_pad_y: u32,
    /// 목록 좌우 여백.
    inset_x: u32,
    /// 행 안에서 아이콘·글자·동작 사이의 간격.
    gap: u32,
    /// 상태 문자 slot 폭(오른쪽 끝 고정).
    status_extent: u32,
    /// 호버 동작 버튼 하나의 폭·높이.
    action_extent: u32,
    /// 그룹 헤더의 접힘 표시가 차지하는 가로 자리.
    disclosure_extent: u32,
    /// **아이콘 한 변(logical px)**. 셀 크기가 아니라 디자인 토큰(`ui/icon.Size`)에서 온다 — 셀로 그리면
    /// 행 높이와 무관하게 구워져 화살표가 글자보다 크고 세로도 어긋난다(사용자 지적 2026-08-14).
    icon_extent: u32,
    scrollbar_width: u32,
    scrollbar_inset_x: u32,
    scrollbar_min_thumb: u32,

    pub fn resolve(scale_milli: u32) DockMetrics {
        const s = struct {
            fn px(base: u32, milli: u32) u32 {
                return @max(1, base * @max(milli, 1) / 1000);
            }
        };
        return .{
            .tab_h = s.px(28, scale_milli),
            .summary_h = s.px(24, scale_milli),
            .section_h = s.px(24, scale_milli),
            .row_h = s.px(24, scale_milli),
            .branch_h = s.px(26, scale_milli),
            // **글자 줄 높이 그대로다.** 여기서 따로 20px를 고르면 상자 높이는 20씩 세는데 `view`는
            // 17(=`.control` 줄 높이)씩 줄을 놓아, 줄이 늘수록 아래에 빈 띠가 남고 클릭 → 행 변환도
            // 그만큼 어긋난다(같은 값의 출처가 둘이면 늘 이렇게 갈린다).
            .commit_row_h = typography.lineHeightPx(.control, scale_milli),
            .commit_button_h = s.px(28, scale_milli),
            .commit_pad_y = s.px(8, scale_milli),
            .inset_x = s.px(8, scale_milli),
            .gap = s.px(6, scale_milli),
            .status_extent = s.px(14, scale_milli),
            .action_extent = s.px(20, scale_milli),
            .disclosure_extent = s.px(16, scale_milli),
            // 행 높이 24px에 18pt 아이콘은 꽉 차 보인다 — 목록 행은 밀집한 자리라 `compact`가 맞다.
            .icon_extent = s.px(ui_icon.Size.compact.extentPt(), scale_milli),
            .scrollbar_width = s.px(8, scale_milli),
            .scrollbar_inset_x = s.px(2, scale_milli),
            .scrollbar_min_thumb = s.px(24, scale_milli),
        };
    }

    /// 항목 하나의 높이. 스크롤 상한·가상화 계산이 이 함수를 단일 출처로 쓴다 — platform이 자기
    /// 산술로 다시 재면 그린 자리와 스크롤 범위가 갈린다.
    /// 커밋 상자 전체 높이. **세 곳이 이 함수를 쓴다** — build(노드 높이)·view(글자 자리)·platform(목록
    /// 높이). 각자 계산하면 상자가 차지한 만큼 목록이 줄지 않아 스크롤 범위가 어긋난다(탭 줄에서 겪었다).
    pub fn commitBoxHeight(self: DockMetrics, rows: u32) u32 {
        return self.commit_row_h * @max(rows, 1) + self.commit_pad_y * 2;
    }

    /// 커밋 상자가 한 줄에 담는 **열 수**. **랩 계산의 단일 출처다** — host는 이 값으로 랩해 상자 높이를
    /// 정하고(`commit_rows`), view는 같은 값으로 랩해 글자를 놓는다. 둘이 갈리면 상자 높이와 실제 줄
    /// 수가 어긋나 마지막 줄이 잘리거나 빈 줄이 남는다.
    ///
    /// **13pt 역할 기준이다**(text-field-editor.md §12.3 ①) — chrome 글자가 사용자 등폭 폰트라 셀 =
    /// 실제 advance인 덕분에 셀 단위 랩이 성립한다. 12pt 역할로 낮추면 그 순간 랩이 깨진다.
    pub fn commitViewCols(self: DockMetrics, box_width_px: f32, cell_width_px: u32) u16 {
        const cell: f32 = @floatFromInt(@max(cell_width_px, 1));
        const usable = box_width_px - @as(f32, @floatFromInt(self.inset_x * 2));
        if (usable < cell) return 1; // 한 열은 늘 있다 — 0열이면 랩이 무한 루프가 될 자리다
        const cols = @floor(usable / cell);
        return @intFromFloat(@min(cols, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    }

    pub fn itemHeight(self: DockMetrics, item: Item) u32 {
        return switch (item) {
            .section => self.section_h,
            .file => self.row_h,
            // "모두 보기"와 안내는 파일 행과 같은 높이를 쓴다(줄이 하나이므로).
            .more, .notice => self.row_h,
        };
    }

    pub fn scrollbarMetrics(self: DockMetrics) scroll_area.ScrollbarMetrics {
        return .{
            .width_px = self.scrollbar_width,
            .inset_x_px = self.scrollbar_inset_x,
            .min_thumb_px = self.scrollbar_min_thumb,
        };
    }
};

const testing = std.testing;

test "DockMetrics: zoom이 커지면 행도 함께 커지고 0으로 접히지 않는다" {
    const base = DockMetrics.resolve(1000);
    const big = DockMetrics.resolve(2000);
    try testing.expect(big.row_h > base.row_h);
    try testing.expect(big.section_h > base.section_h);
    // 극단적으로 작은 zoom에서도 1px 아래로 접히면 행이 사라져 클릭할 것이 없어진다.
    const tiny = DockMetrics.resolve(1);
    try testing.expect(tiny.row_h >= 1 and tiny.status_extent >= 1);
}

test "itemHeight: 종류마다 높이가 정의된다(스크롤 상한의 단일 출처)" {
    const m = DockMetrics.resolve(1000);
    try testing.expectEqual(m.section_h, m.itemHeight(.{ .section = .{ .section = .staged, .count = 1, .collapsed = false, .action = .unstage } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .file = .{ .name = "a", .dir = "", .status = .modified, .letter = 'M', .action = .stage } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .more = .{ .section = .changes, .hidden = 3 } }));
    try testing.expectEqual(m.row_h, m.itemHeight(.{ .notice = "잘렸습니다" }));
}
