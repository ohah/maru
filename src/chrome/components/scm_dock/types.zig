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
    /// 어느 저장소의 그룹인가(목록 기준 — 머리 줄과 같은 축). 목록에 저장소가 여럿이면 **같은 이름의
    /// 그룹이 여럿**이라, 이것이 없으면 일괄 스테이지가 남의 저장소로 간다(②d).
    repo_index: u32 = 0,
    section: Section,
    /// 그 그룹의 **전체** 파일 수(접혀 있어도 전체를 말한다).
    count: u32,
    collapsed: bool,
    /// 헤더 호버에 뜰 일괄 동작. `.none`이면 그 자리에 아무것도 그리지 않는다.
    action: RowAction,
};

pub const FileItem = struct {
    /// 어느 저장소의 행인가(목록 기준). 모델 인덱스는 **저장소마다 따로** 세므로, 이것 없이 인덱스만
    /// 실으면 아래 그룹의 파일을 눌렀는데 위 저장소의 같은 번호 파일이 열린다(②d).
    repo_index: u32 = 0,
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

pub const MoreItem = struct { repo_index: u32 = 0, section: Section, hidden: u32 };

/// 저장소 하나의 **커밋 입력 상자**. 목록 안에 산다(§3.5.1c) — 그룹마다 자기 상자를 갖는다.
///
/// **고정 chrome에서 목록으로 내려온 이유**: 상자가 하나면 "지금 어느 저장소로 커밋하는가"가 화면에
/// 없다. 사용자가 두 저장소를 열어 둔 채 아래 그룹의 파일을 보고 있어도, 위에 떠 있는 상자는 다른
/// 저장소의 것일 수 있다 — 그 어긋남은 **잘못된 저장소에 커밋**으로 끝난다.
pub const CommitBoxItem = struct {
    /// 어느 저장소의 상자인가(목록 기준 — 머리 줄과 같은 축).
    repo_index: u32,
    /// 보여 줄 **시각 행** 수(host가 랩해서 정한다).
    rows: u32 = 1,
    /// 상자에 그릴 글자(조합 중이면 그것이 끼워진 표시 텍스트).
    text: []const u8 = "",
    /// 편집 상태. **포커스는 상자마다 다르다** — 여럿이 동시에 caret을 갖지 않는다.
    edit: CommitEdit = .{},
};

/// 저장소 하나의 **커밋 버튼**. 상자 바로 아래 줄이다.
pub const CommitButtonItem = struct {
    repo_index: u32,
    /// 실제 index 상태로만 켠다(쓰기 문서 §7 — 낙관하지 않는다).
    enabled: bool = false,
    run: CommitRun = .idle,
};

/// 저장소·워크트리 하나의 **머리 줄**(§3.5.1c). 목록의 단위가 저장소가 아니라 워크트리이므로 이 행
/// 하나가 곧 한 워크트리다.
///
/// 화면에 세 가지가 함께 선다: 접힘 표시 · 이름 · 브랜치 칩. 동작 아이콘 줄(새로고침·스테이지·커밋…)은
/// 다음 조각이다 — **자리를 먼저 잡되 없는 버튼을 그리지 않는다**(P1 계약은 "누를 수 없는 컨트롤은
/// 비활성으로 표시한다"이지 "아직 없는 컨트롤을 그린다"가 아니다).
pub const RepoItem = struct {
    /// 목록 안에서 이 저장소의 자리. host가 같은 스냅샷에서 이 저장소를 다시 찾는 열쇠다 —
    /// **경로 문자열로 되찾지 않는다**(창이 스크롤되면 화면 자리와 어긋난다는 이유는 파일 행과 같다).
    index: u32,
    /// 화면에 그릴 이름. 보통 마지막 경로 조각이고, 같은 이름이 둘이면 host가 구별되는 데까지 늘린다.
    name: []const u8,
    /// 체크아웃된 브랜치. 분리 HEAD면 짧은 해시가 대신 온다(host가 정한다 — 컴포넌트는 문자열만 그린다).
    branch: []const u8 = "",
    /// 접혀 있나. 접히면 그 저장소의 커밋 상자·요약·파일 행이 목록에 아예 없다(host가 안 넣는다).
    collapsed: bool = false,
    /// 주 워크트리(저장소 루트 자신)인가. 아이콘이 갈린다 — 워크트리는 "딸린 것"이라는 사실이 보여야
    /// 사용자가 같은 이름의 두 줄을 구별한다.
    primary: bool = true,
    /// 그 저장소의 변경 파일 수. 접혀 있어도 보여야 "여기 뭔가 있다"를 안다(VS Code도 그렇다).
    count: u32 = 0,
    /// 아직 그 저장소를 **읽지 않았다**. 읽기는 하나씩 순차로 도므로(§3.5.1c) 목록에 있는데 아직
    /// 차례가 안 온 저장소가 생긴다.
    ///
    /// **0건과 구별해야 한다** — 배지가 없는 것을 사용자는 "변경 없음"으로 읽는다. 이 값이 참이면
    /// 배지 대신 `읽는 중…`을 적어 "아직 모른다"를 말한다.
    pending: bool = false,
    /// 그 저장소를 **읽지 못했다**(경로가 사라졌거나 git이 실패했다). `pending`과 다른 사실이라 문구도
    /// 다르다 — "읽는 중…"은 곧 온다는 약속이고, 이쪽은 오지 않는다는 말이다. 0건으로 그리면 **없는
    /// 사실을 단정한다**.
    failed: bool = false,
    /// **전체 스테이지**를 켤 수 있나(그 저장소를 읽었고 스테이지할 것이 있다). 새로고침은 읽기라 늘
    /// 켜져 있으므로 따로 두지 않는다.
    ///
    /// 꺼져 있어도 **감추지 않는다**(P1 계약) — 비활성으로 표시하고, 눌리면 host가 이유를 적는다.
    can_stage_all: bool = false,
};

/// 히스토리 탭의 커밋 한 줄(P4). 문자열은 전부 host가 든 원문을 빌린다(할당 없음).
pub const CommitItem = struct {
    /// 목록 안 자리. 클릭 intent가 이것을 싣고 host가 같은 스냅샷에서 다시 찾는다(파일 행과 같은 규율).
    index: u32 = 0,
    /// 제목 한 줄. 폭이 모자라면 **여기가 마지막으로** 줄어든다(무엇을 한 커밋인지가 가장 중요하다).
    subject: []const u8,
    author: []const u8 = "",
    /// 이미 사람이 읽을 꼴로 만든 상대 시각(`3시간 전`). **host가 만든다** — component에는 시간이 없다.
    when: []const u8 = "",
    /// 짧은 해시(7자).
    short_oid: []const u8 = "",
    /// 첫 ref 칩 하나만 그린다. 여럿이면 좁은 도크에서 제목을 다 밀어낸다.
    ref: []const u8 = "",
    /// 그 칩이 **지금 체크아웃된 브랜치**인가(색이 갈린다).
    ref_is_head: bool = false,
    /// 지금 고른 커밋인가(강조).
    selected: bool = false,
    /// 펼쳐져 있나(P4b). 펼치면 그 커밋이 바꾼 파일 줄이 **바로 아래**에 온다.
    expanded: bool = false,
};

/// 에이전트 탭의 **턴 한 줄**(P5 — §3.5.4). 1급 항목은 파일이 아니라 턴이다.
pub const TurnItem = struct {
    /// 목록 안 자리(0 = 진행 중). 클릭 intent가 이것을 싣고 host가 같은 스냅샷에서 다시 찾는다.
    index: u32 = 0,
    /// 사람이 읽을 이름(`진행 중`·`마지막 턴`·`3턴 전`). **host가 만든다** — 세는 규칙이 화면 문구다.
    title: []const u8,
    /// 그 턴을 돌린 에이전트(`claude`·`codex`). 모르면 빈 문자열이고 그 자리는 비운다.
    agent: []const u8 = "",
    /// 이미 사람이 읽을 꼴로 만든 상대 시각. **진행 중은 빈 문자열**이다(끝나지 않았다).
    when: []const u8 = "",
    selected: bool = false,
    expanded: bool = false,
    /// 진행 중인 턴인가. 오른쪽이 **작업트리**라 계속 변한다는 사실을 화면이 말한다.
    live: bool = false,
};

/// 펼친 커밋 아래의 파일 한 줄(P4b). 변경 사항 탭의 `FileItem`과 **다른 항목**이다 — 그쪽은 작업트리
/// 상태이고 이쪽은 그 커밋이 바꾼 것이라, 클릭이 여는 비교 기준도 동작(스테이지)도 다르다.
pub const CommitFileItem = struct {
    /// 그 커밋 안에서 몇 번째 파일인가. 클릭 intent가 이것을 싣고 host가 같은 목록에서 다시 찾는다.
    index: u32 = 0,
    name: []const u8,
    dir: []const u8 = "",
    status: StatusKind,
    /// 화면에 그대로 그릴 한 글자(`M`·`A`·`D`·`R`).
    letter: u8,
    /// 지금 열려 있는 비교인가(강조). 목록이 **무엇을 보고 있는지** 말해야 파일 여럿을 오갈 때 길을
    /// 잃지 않는다(변경 사항 탭의 파일 행과 같은 규율).
    selected: bool = false,
    /// **턴의 파일인가**(P5). 같은 줄 모양을 두 탭이 쓰지만 여는 비교가 다르다 — 커밋은 `커밋^ ↔ 커밋`,
    /// 턴은 `스냅샷 ↔ 스냅샷`이다. 이 값이 없으면 intent가 한쪽으로만 가서 다른 탭의 클릭이 죽는다.
    from_turn: bool = false,
};

pub const Item = union(enum) {
    /// 저장소·워크트리 머리 줄. **목록의 첫 층**이고, 그 아래에 그 저장소의 줄들이 온다.
    repo: RepoItem,
    /// 그 저장소의 커밋 입력 상자(머리 줄 바로 아래).
    commit_box: CommitBoxItem,
    /// 그 저장소의 커밋 버튼(상자 바로 아래).
    commit_button: CommitButtonItem,
    section: SectionItem,
    file: FileItem,
    more: MoreItem,
    /// 목록이 불완전하다는 진술(누를 수 없다).
    /// 히스토리 탭의 커밋 줄(P4).
    commit: CommitItem,
    /// 에이전트 탭의 턴 줄(P5).
    turn: TurnItem,
    /// 펼친 커밋 아래의 파일 줄(P4b).
    commit_file: CommitFileItem,
    /// 히스토리 목록 끝의 **더 보기**(P4). 상한만큼 읽었을 때만 선다 — 끝까지 읽었으면 없다(있으면
    /// 눌러도 아무 일이 없어 "고장"으로 읽힌다).
    load_more,
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
    /// 지금 열려 있는 탭. 모르는 값은 platform이 `.changes`로 clamp한다(§3.5.1) — component는 받은 값을
    /// 그대로 그린다.
    active_tab: Tab = .changes,
    /// 요약 줄(`+N -N`)을 그리나. **히스토리 탭에서는 끈다**(P4) — 그 숫자는 작업트리의 것이고 커밋
    /// 목록과 아무 관계가 없다. 0으로 두면 "바뀐 것이 없다"는 **틀린 진술**이 된다.
    show_summary: bool = true,
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
    /// 커밋이 도는 중인가. **버튼이 그 사실을 말한다** — 눌렀는데 아무 표시가 없으면 사용자는 다시
    /// 누르고, 두 번째 누름은 조용히 거부된다(쓰기는 하나씩이다).
    commit_run: CommitRun = .idle,
    /// 커밋 상자의 **편집 상태 스냅샷**. component는 편집하지 않는다 — host가 `TextField`로 편집하고
    /// 그 결과만 여기 싣는다(props는 immutable이고, 편집 상태가 둘이면 caret이 갈린다).
    commit_edit: CommitEdit = .{},
};

/// 커밋 실행 상태. `slow`는 **문구일 뿐**이다 — 상한을 넘겨도 프로세스를 죽이지 않는다(쓰기 문서 §3:
/// hook은 테스트 전체를 돌 수도 있고, 중간에 죽이면 index·`.git`이 어중간해진다).
pub const CommitRun = enum { idle, running, slow };

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
    /// 저장소·워크트리 머리 줄 높이.
    repo_h: u32,
    /// 커밋 메시지 상자의 **한 시각 행** 높이. 상자 전체 높이는 이것 × 보이는 행 수다 —
    /// 내용을 따라 자라고 상한에서 멈춘다(§12.2).
    commit_row_h: u32,
    /// 커밋 버튼 줄 높이.
    commit_button_h: u32,
    /// 커밋 상자의 **위아래 여백**. 글자가 테두리와 버튼 줄에 붙지 않게 한다 — 입력란은 글자가 상자
    /// 안에서 숨 쉬어야 눌러서 쓰는 자리로 읽힌다(사용자 지적 2026-08-16).
    commit_pad_y: u32,
    /// 히스토리 커밋 줄 높이(두 줄 + 위아래 여백 — §3.5.3).
    commit_row_two_line_h: u32,
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
            // 28px면 13pt 글자(줄 높이 17) 위아래로 5px씩밖에 안 남아 탭 이름이 줄에 낀 것처럼 보인다
            // (사용자 지적 2026-08-16). 34px는 위아래 8px 남겨 아래 커밋 줄의 여백(`commit_pad_y`)과
            // 같은 급이 된다 — 두 줄이 서로 다른 리듬으로 숨 쉬면 그 사이가 어긋나 보인다.
            .tab_h = s.px(34, scale_milli),
            .summary_h = s.px(24, scale_milli),
            .section_h = s.px(24, scale_milli),
            .row_h = s.px(24, scale_milli),
            .branch_h = s.px(26, scale_milli),
            // 그룹 헤더(24)보다 크고 탭 줄(34)보다 작다 — 목록 안에서 가장 굵은 층이되 고정 chrome보다는
            // 가볍다.
            .repo_h = s.px(30, scale_milli),
            // **글자 줄 높이 그대로다.** 여기서 따로 20px를 고르면 상자 높이는 20씩 세는데 `view`는
            // 17(=`.control` 줄 높이)씩 줄을 놓아, 줄이 늘수록 아래에 빈 띠가 남고 클릭 → 행 변환도
            // 그만큼 어긋난다(같은 값의 출처가 둘이면 늘 이렇게 갈린다).
            .commit_row_h = typography.lineHeightPx(.control, scale_milli),
            .commit_button_h = s.px(28, scale_milli),
            .commit_pad_y = s.px(8, scale_milli),
            // 제목(control 17px) + 보조 줄(supporting) + 위아래 여백. 파일 행보다 높지만 그만큼
            // 정보가 둘이다.
            .commit_row_two_line_h = typography.lineHeightPx(.control, scale_milli) +
                typography.lineHeightPx(.supporting, scale_milli) + s.px(8, scale_milli),
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
    /// 상자 안 **스크롤바 거터**. 목록과 같은 규율로 **늘 비워 둔다** — 글이 8행을 넘는 순간 막대가
    /// 나타나는데, 그때 폭이 줄면 글이 통째로 다시 접혀 커서가 튄다(목록이 같은 이유로 gutter를 상시
    /// 소유한다).
    pub fn commitGutterPx(self: DockMetrics) u32 {
        return self.scrollbar_width + self.scrollbar_inset_x * 2;
    }

    pub fn commitViewCols(self: DockMetrics, box_width_px: f32, cell_width_px: u32) u16 {
        const cell: f32 = @floatFromInt(@max(cell_width_px, 1));
        const usable = box_width_px - @as(f32, @floatFromInt(self.inset_x * 2 + self.commitGutterPx()));
        if (usable < cell) return 1; // 한 열은 늘 있다 — 0열이면 랩이 무한 루프가 될 자리다
        const cols = @floor(usable / cell);
        return @intFromFloat(@min(cols, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    }

    pub fn itemHeight(self: DockMetrics, item: Item) u32 {
        return switch (item) {
            // 머리 줄은 그룹 헤더보다 한 급 크다 — 이름·브랜치 칩이 함께 서고, 목록의 첫 층이라
            // 눈이 여기서 끊겨야 저장소 경계가 보인다.
            .repo => self.repo_h,
            // 커밋 줄은 파일 행과 같은 높이다 — 목록 두 탭이 같은 격자를 쓰면 탭을 오가도 눈이 안 튄다.
            // **두 줄이다**(§3.5.3): 제목 / 작성자·시각·해시. 한 줄에 몰면 좁은 도크에서 제목이 거의
            // 남지 않는다 — 목록에서 가장 중요한 것이 "무엇을 한 커밋인가"다.
            // 턴 줄도 두 줄이다(제목 / 에이전트 · 시각) — 커밋 줄과 같은 격자를 쓴다.
            .commit, .turn => self.commit_row_two_line_h,
            // 커밋 안의 파일 줄은 **파일 행과 같은 높이**다 — 두 탭이 같은 격자를 쓴다.
            .commit_file => self.row_h,
            .load_more => self.row_h,
            .commit_box => |box| self.commitBoxHeight(box.rows),
            // 버튼 아래 여백까지 이 행이 갖는다 — 다음 줄(요약·그룹 헤더)과 붙지 않게.
            .commit_button => self.commit_button_h + self.commit_pad_y,
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
