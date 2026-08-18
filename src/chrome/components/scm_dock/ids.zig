//! 소스 컨트롤 도크의 frame-local action 표.
//!
//! 포인터 히트테스트는 `UiActionId`만 돌려주고, 이 표가 그 ID에 도메인 의미를 다시 붙인다 — 그래야
//! 일반 interaction 계층이 git이나 행 인덱스를 알 필요가 없다(Session Dock과 같은 구조).

const intent_table = @import("../../ui/intent_table.zig");
const types = @import("types.zig");

/// 저장소 안의 한 행. **인덱스만으로는 부족하다**(②d) — 모델은 저장소마다 따로 서므로 같은 번호가
/// 저장소마다 다른 파일을 가리킨다.
pub const RowRef = struct { repo_index: u32, model_index: u32 };
/// 저장소 안의 한 그룹.
pub const SectionRef = struct { repo_index: u32, section: types.Section };

pub const Intent = union(enum) {
    /// 그룹 헤더 클릭 = 접기/펴기.
    toggle_section: types.Section,
    /// 그 그룹의 일괄 동작(`모두 스테이지`/`모두 언스테이지`). **무엇을 할지는 host가 현재 상태로
    /// 다시 정한다** — intent가 방향까지 실으면 published tree와 host 상태가 어긋날 수 있다.
    section_action: SectionRef,
    /// "모두 보기" — 그 그룹만 전부 편다.
    expand_section: types.Section,
    /// 행 클릭 = 그 비교 열기. **인덱스는 화면 창(virtualized window) 기준이 아니라 모델 인덱스**다 —
    /// host가 같은 스냅샷 세대의 모델에서 그 행을 다시 찾는다.
    open_row: RowRef,
    /// 행 호버의 `+`/`−`. 어느 방향인지는 그 행이 선 그룹이 정하므로 여기서는 행만 가리킨다.
    row_action: RowRef,
    /// 저장소 머리 줄 클릭 = 접기/펴기. **인덱스는 목록 기준**이고 host가 같은 스냅샷에서 다시 찾는다
    /// (파일 행이 모델 인덱스를 싣는 것과 같은 이유 — 경로 문자열로 되찾으면 스크롤 뒤 어긋난다).
    toggle_repo: u32,
    /// 커밋 상자 클릭 = **편집 시작**. 상자가 저장소마다 있으므로 **어느 저장소인지 싣는다**(②b) —
    /// 안 실으면 아래 그룹의 상자를 눌렀는데 위 그룹이 편집된다.
    ///
    /// caret을 어디에 놓을지는 여기 없다 — 그건 tree hit이 아니라 **글자 hit**이라 좌표가 필요하고,
    /// host가 같은 published rect로 그 변환을 한다(스크롤바와 같은 이유).
    commit_focus: u32,
    /// 커밋 버튼. **어느 저장소로 커밋하는가**를 싣는다. 켜졌는지는 host가 실제 index 상태로 다시 본다
    /// (쓰기 문서 §7 — intent가 "가능함"까지 실으면 어긋난 프레임의 클릭이 통과한다).
    commit: u32,
    /// 히스토리 목록의 커밋 줄을 눌렀다(P4). **고르기까지**가 이 조각이고, 그 커밋의 diff를 여는 것은
    /// P4b다(비교 기준이 하나 더 늘어나는 일이라 따로 본다).
    select_commit: u32,
    /// 에이전트 탭의 턴 줄을 눌렀다(P5) — 고르기이자 펼치기다(커밋 줄과 같은 규율).
    select_turn: u32,
    /// 펼친 턴의 파일을 눌렀다(P5) — 그 턴의 두 tree 사이 비교를 연다.
    open_turn_file: u32,
    /// 펼친 커밋의 파일을 눌렀다(P4b) — `커밋^ ↔ 커밋` 비교를 연다.
    open_commit_file: u32,
    /// 히스토리를 **더 읽는다**(P4). 몇 개를 더 읽을지는 host가 정한다 — 그 수는 화면이 아니라 비용
    /// 규율에 속한다.
    load_more_commits,
    /// 탭 줄의 칸을 눌렀다(P4). **어느 탭인지**를 싣고, 실제로 뷰가 바뀌는지는 host가 정한다
    /// (히스토리·에이전트는 그 탭이 읽을 것을 아직 안 읽었을 수 있다).
    select_tab: types.Tab,
    /// 머리 줄의 **새로고침**(②c). 읽기라 언제나 실행한다 — 그 저장소가 활성이면 목록 읽기를,
    /// 아니면 머리 줄 읽기를 다시 건다.
    refresh_repo: u32,
    /// 머리 줄의 **전체 스테이지**(②c). `git add -A`라 경로를 싣지 않는다 — 화면에 안 보이는 파일까지
    /// 드는 것이 "모두"의 뜻이다.
    stage_all_repo: u32,
    /// 브랜치 줄의 **원격 갱신**(P6). 대상은 **브랜치 줄이 말하는 그 저장소**(활성 저장소)라 인덱스를
    /// 싣지 않는다 — 줄이 하나뿐이므로 실으면 두 곳이 같은 사실을 들게 된다.
    fetch_remote,
    /// 그 칩 오른쪽의 `∨` — **보조 메뉴**를 연다(P6b). 메뉴 항목(`push`/`pull`)은 우리가 실행하지 않고
    /// 활성 터미널에 명령을 넣어 주므로, 무엇을 넣을지는 host가 정한다.
    open_remote_menu,
    /// 스크롤바. 목표 offset은 포인터 좌표의 함수라 intent에 실을 수 없다 — host가 같은 published
    /// 기하로 좌표를 offset으로 바꾼다.
    scroll_thumb,
    scroll_track,
};

pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
