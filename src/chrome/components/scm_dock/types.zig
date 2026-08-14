//! 소스 컨트롤 도크의 platform-neutral 입력 DTO다(docs/editor-surface-dock.md §3.5).
//!
//! 이 파일은 `AppSession`도 git 결과 버퍼도 보관하지 않는다. platform이 `session/scm_view.zig`의 행 모델을
//! **화면용 문자열로 이미 잘라** 이 구조로 투영하고, component는 그 immutable snapshot만 읽는다
//! (Session Dock과 같은 규율 — component가 domain을 다시 해석하지 않는다).

const std = @import("std");
const layout = @import("../../ui/layout.zig");
const scroll_area = @import("../../ui/scroll_area.zig");
const ui_icon = @import("../../ui/icon.zig");

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
