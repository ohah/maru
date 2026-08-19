//! Workspace restore 직렬화(R1, writer). 실행 중이던 창/탭/split/터미널 레이아웃과 각 터미널의 cwd·shell을
//! 다시 열기 위한 **선언적 상태**를 `maru.workspace.v1` 텍스트로 굳힌다 — live PTY/process/grid 내용은 담지
//! 않는다(docs/workspace-restore.md). snapshot/trace와 같은 규칙: 첫 줄 bare 토큰(`schema=` 접두어 없음),
//! 이후 `<kind> <fields>` 라인, 따옴표 문자열은 `\` `"`·개행 escape. 이 파일은 값 모델과 text reader/writer를
//! 함께 두고, platform live capture/apply는 이 모델만 소비·생산한다. P4 R2a manifest-wide binding validator는
//! 이 모듈의 semantic preflight이며, R2b host inventory reconciliation은 per-surface text parse와 별도 후속 경계다.
//!
//! 계층: workspace → windows → tabs → (pane split 트리 + panes) → panes → surfaces(Term). 멀티 창은 windows가
//! N개(각 창 = 한 AppSession). split 트리는 preorder TreeNode 리스트로 — full binary tree라 self-delimiting
//! (split은 뒤따르는 두 subtree를 소비, leaf는 종단). 베이스: docs/workspace-restore.md 저장 모델 + 현재
//! 탭→pane→Term 풀 모델·멀티 창에 맞춰 window-aware로 확장.

const std = @import("std");
const dock_panel = @import("dock_panel.zig");
const split_tree = @import("split_tree.zig");
// 기준 ref의 형태 판정은 **git 명령을 만드는 쪽이 소유한다**(§3.5). 여기서 규칙을 다시 쓰면 저장이 받는
// 값과 실행이 받는 값이 갈린다 — 같은 L2 계층이라 그대로 부른다.
const git_command = @import("git_command.zig");
const writeEscaped = @import("../text_escape.zig").writeEscaped; // 따옴표 값 escape 단일 출처(trace/snapshot과 공유)

pub const header = "maru.workspace.v1";

/// 한 탭의 pane 수 sanity 상한. 손상·변조된 복원 파일이 pane_count를 부풀려도 split 트리 노드 상한
/// (2·pane_count−1)이 거대해져 깊은 재귀로 스택 오버플로가 나지 않게, parseTab이 먼저 이 값으로 가둔다.
/// 실제 레이아웃은 한 자릿수~십수 pane이라 1024는 어떤 현실 레이아웃보다 크다(손상만 거른다). 베이스: 표준이
/// 없어 sane 상한을 우리가 정함 — Ghostty는 바이너리 아카이버라 이 텍스트-깊은중첩 벡터 자체가 없다.
pub const max_panes_per_tab = 1024;

/// 한 라인의 key=value 필드 수 sanity 상한 — key-addressed 리더(LineFields)는 라인을 통째 토큰화하므로, 손상/변조
/// 파일이 한 줄에 토큰을 무한정 채우면 토큰화 작업·메모리가 라인 길이만큼 부풀 수 있다. 512는 현재 최대 window line과
/// additive scalar 확장 여유를 함께 보존하면서 손상된 unknown-field 폭주를 고정된 작업량으로 가두는 일반 상한이다.
pub const max_line_fields: usize = 512;

/// 한 창에 영속할 파일 도크 entry sanity 상한. 라이브 WKWebView 상한(기본 8)과 달리 해제된 탭 metadata는 남으므로
/// 더 넉넉해야 하지만, window 한 줄의 반복 키가 손상 파일에서 무한히 늘어나는 것은 막아야 한다. 256은 실제 열린 파일
/// 수보다 충분히 크고 max_line_fields의 반복 키 예산 안에 있다.
pub const max_dock_entries = dock_panel.max_entries;
/// 하나의 checkpoint에 둘 수 있는 persistent runtime owner 상한. semantic preflight의 hash table 작업·메모리를
/// attacker-controlled workspace 크기와 분리한다. 일반 in-process surface는 이 cap에 포함하지 않는다.
pub const max_runtime_bindings = 4096;
pub const max_explorer_roots: usize = 256;
/// 기억하는 저장소 기준의 최대 개수. 목록이 아니라 **기억**이라 상한이 낮아도 된다 — 넘으면 오래된
/// 것부터 버리는 것이 아니라 저장을 거절한다(잘린 기억은 "안 고른 것"과 구별되지 않는다).
pub const max_scm_bases: usize = 64;
pub const max_explorer_root_payload_bytes: usize = 1_049_860;
pub const max_explorer_root_raw_bytes: usize = 2_099_720;

pub const SplitDirection = split_tree.SplitDirection;

/// split 트리 한 노드(preorder). leaf는 pane 섹션 인덱스를 가리키고, split은 방향 + a의 비율(천분율 0..1000)을
/// 들고 뒤따르는 두 subtree(a, b)를 소비한다. ratio는 split_tree의 f32(0.05..0.95)를 *1000 반올림한 정수.
pub const TreeNode = union(enum) {
    leaf: usize,
    split: Split,

    pub const Split = struct {
        direction: SplitDirection,
        ratio_milli: u16,
    };
};

/// 한 터미널(Term)의 복원 가능 선언 상태(session.surface.RestorableSurfaceMetadata의 직렬화 부분집합 — id/
/// process_state 같은 런타임 값은 복원에 불필요하므로 안 담는다). cwd=OSC 7, title=OSC 0/2, command=spawn argv[0].
/// v1 복원이 실제로 소비하는 건 cwd·cols·rows뿐이다. title·command는 **목표 포맷의 선행 구현**으로 캡처·저장만
/// 하고 복원 spawn엔 아직 안 쓴다(기본 셸·"Maru" 제목으로 살림). 헛방어/유령 필드가 아니라 docs/workspace-restore.md에
/// 설계된 필드다: command=`shell_entry`(pane 재시작 기본 shell argv, round-trip 테스트까지 계획됨), title=pane title.
/// command는 argv[0]=셸이라 `last_observed_command` 자동 재실행 금지 정책과는 별개다. 정확한 제목·argv 복원은 후속.
pub const RuntimeState = enum {
    live,
    ended,
};

pub const Surface = struct {
    // custom_name = 사용자 지정 이름(rename), title = 자동 제목(OSC 0/2). 둘은 별도 필드다 — 표시 우선순위는
    // custom_name(비면 안 씀) → title → 기본값(app.label.pick). ""=없음. 단일 출처: docs/workspace-restore.md
    // "사용자 지정 이름(custom_name)과 자동 제목".
    custom_name: []const u8 = "",
    title: []const u8 = "",
    cwd: []const u8 = "",
    command: []const u8 = "",
    cols: u16 = 0,
    rows: u16 = 0,
    // 영속 세션 identity(P3-e3-5). host-backed Term은 `runtime_host_id:runtime_id` 쌍을 채우고 in-process면 둘 다 ""다.
    // runtime_id만 있는 상태는 옛 `runtime-id` 파일을 읽은 migration sentinel이다. 새로 캡처한 세션은 반드시 둘을 함께
    // 저장하며, host namespace가 다른 runtime을 같은 세션으로 오인하지 않게 attach 전에 host_id를 대조한다.
    runtime_host_id: []const u8 = "",
    runtime_id: []const u8 = "",
    // 키 부재는 live다. ended는 마지막 host/runtime identity를 버리지 않는 durable tombstone이며 full handle 없이는
    // 유효하지 않다. 이 상태는 PTY를 직렬화하지 않고 restore side effect를 막는 manifest 지시다.
    runtime_state: RuntimeState = .live,
};

/// split leaf 한 칸(panel) — 가로 탭으로 여러 Term을 들 수 있다(탭→pane 모델). active-term = 보이는 Term.
/// FP16 파일 Term 레코드. `pane` 줄의 **반복 필드** `file-term`으로 저장한다 — 새 line kind를 만들면 옛
/// 리더가 창 블록 중간의 미지 줄에서 `BadLine`으로 파일 전체를 폴백시키지만(§5.1), 필드는 forgiving하게
/// 무시되기 때문이다(docs/file-panel.md §5.0).
///
/// `index`는 런타임 Term 인덱스가 아니라 **persisted 시퀀스**(터미널 + 파일 Term, 브라우저 제외) 안의
/// 위치다. 브라우저 Term은 계속 미영속이라, 런타임 인덱스를 쓰면 `[terminal, browser, file]` pane에서
/// 복원 Term이 2개뿐인데 index가 2라 그 창 전체가 fail-close된다.
pub const FileTerm = struct {
    index: usize,
    kind: dock_panel.EntryKind,
    mode: dock_panel.Mode,
    path: []const u8,
};

/// WP-P 브라우저 Term 레코드. `pane` 줄의 반복 필드 `browser-term`으로 **현재 URL 하나만** 저장한다
/// (히스토리는 복원하지 않는다 — docs/workspace-restore.md §WP-P).
///
/// `insert_after`는 `FileTerm.index`와 **다른 축**이다: persisted 시퀀스 안의 자리가 아니라 "이 브라우저 앞에
/// 있는 persisted(터미널+파일) Term 수"다. 브라우저를 시퀀스에 합류시켜 인덱스를 재번호하면, 그 파일을 읽는
/// **구버전 Maru가 창을 통째로 폴백한다** — 구버전은 `browser-term`을 모르는 필드로 건너뛰므로
/// `total = surfaces + file_terms`로 계산하는데 재번호된 file-term index가 그 total을 넘어 범위 검사에 걸린다.
/// 즉 브라우저를 얻는 대가로 downgrade 시 **파일 탭까지** 잃는다. insert_after는 기존 인덱스 값을 하나도
/// 바꾸지 않으므로 구버전은 브라우저만 잃는다.
pub const BrowserTerm = struct {
    insert_after: usize,
    url: []const u8,
};

pub const Pane = struct {
    active_term: usize = 0,
    // 사용자 지정 이름(rename). Pane은 자동 제목 출처가 없어 custom_name 하나뿐(""=없음). 탭바 좌측 라벨 세그먼트로 표시.
    custom_name: []const u8 = "",
    surfaces: []const Surface,
    /// 이 pane의 파일 Term들(persisted index 순서는 무관 — 리더가 index로 재배치한다).
    file_terms: []const FileTerm = &.{},
    /// 이 pane의 브라우저 Term들(등장 순서 = 같은 insert_after 안에서의 상대 순서). WP-P.
    browser_terms: []const BrowserTerm = &.{},
    /// 활성 탭이 브라우저면 그 record 인덱스(`browser_terms` 안 위치). null=활성이 브라우저 아님.
    /// 구버전 리더는 이 필드를 무시하고 `active_term`(비-브라우저 공간)을 쓰므로 포커스만 이웃으로 떨어진다.
    active_browser: ?usize = null,
};

/// 한 워크스페이스(사이드바 탭) — pane split 트리 + 그 leaf들이 가리키는 pane 섹션들. active-pane = 포커스 panel.
pub const Tab = struct {
    active_pane: usize = 0,
    // 사용자 지정 이름(rename). 워크스페이스는 자동 제목 출처가 없어 custom_name 하나뿐(""=없음). 없으면 사이드바
    // 라벨은 활성 Term 라벨로 폴백한다(표시 해석은 platform이 app.label.pick으로). 예전 placeholder `title`을 대체.
    custom_name: []const u8 = "",
    // 위치 고정(우클릭 메뉴) — true면 드래그 재정렬에서 안 움직이고 사이드바에 고정 표시가 뜬다. 기본 false.
    pinned: bool = false,
    // 사이드바 카드 배경 tint(0xRRGGBB, 0=없음/기본 테마색). 우클릭 메뉴 프리셋으로 설정. 기본 0.
    background_color: u32 = 0,
    // 사이드바 카드 좌측 accent 막대색(0xRRGGBB, 0=기본 — 활성=테마 앰버·비활성=막대 없음). 우클릭 메뉴
    // 프리셋으로 설정. 지정하면 활성·비활성 카드 모두 그 색으로 막대 표시. 배경 tint와 직교. 기본 0.
    accent_color: u32 = 0,
    // 사이드바 그룹 시작 마커(위치 파생 소속 — docs/sidebar-groups.md §2.1·§4). null=그룹 시작 아님. 순수
    // additive 스칼라(새 블록·count 키 없음)라 옛 파일은 null로, 다운그레이드해도 옛 리더가 미지 키로 skip해
    // flat 정상 복원(forward·backward 양쪽 호환). group_collapsed는 group_start!=null일 때만 의미. 기본 null/false.
    group_start: ?[]const u8 = null,
    group_collapsed: bool = false,
    // 중첩 그룹 깊이(SG5-3 — docs/plans/sidebar-groups.md §9, docs/sidebar-groups.md §4). group_start!=null일 때만 의미(1=최상위 그룹, 2=중첩, …).
    // 순수 additive 스칼라. 기본 1이면 writer가 키를 **생략**해(round-trip 고정점·옛 파일 flat 정상) 옛 리더가 미지
    // 키로 skip하는 forward-compat도 유지한다. reader는 없으면 1(최상위 그룹)로 폴백. 소속·정규화는 위치 파생이 정한다.
    group_depth: u8 = 1,
    // 사이드바 그룹 공통 색(0xRRGGBB, 0=색 없음 — docs/plans/sidebar-groups.md §9 SG5-2·§4). group_start!=null일 때만 의미.
    // 순수 additive 스칼라(그룹 시작 탭에만 저장 — 소속은 위치 파생). null=색 없음=키 생략(옛 리더가 미지 키로 skip해
    // flat 정상 복원, 양쪽 호환). 그룹 색은 헤더 밴드·소속 카드 막대 층이라 개별 카드 background-color와 안 겹친다. 기본 0.
    group_color: u32 = 0,
    // 그룹-로컬 pin(GL — docs/sidebar-groups-pinning.md §13). 그룹 안 leaf 멤버가 자기 subtree 안에서 위로 고정됐는가. 전역
    // 핀(pinned = [고정][비고정] 리전)과 직교하는 별개 축이라 전역 파티션이 안 읽는다. 순수 additive 스칼라 —
    // false(기본)면 writer가 키를 **생략**해(round-trip 고정점·옛 파일 flat 정상) 옛 리더가 미지 키로 skip하는
    // forward-compat도 유지한다. reader는 없으면 false. 마커·top-level 카드에선 무의미(멤버 카드에만 실린다). 기본 false.
    local_pinned: bool = false,
    // §2.1 재설계 서브파티션 마커(top_level — docs/sidebar-groups-top-level.md §14). 한 핀 리전 안에서 이 카드부터 최상위(depth 0)로
    // 복귀하는 리딩 break 신호(pin 플립과 동형). 순수 additive 스칼라 — false(기본)면 writer가 키를 **생략**해(round-trip
    // 고정점·옛 파일 flat 정상) 옛 리더가 미지 키로 skip하는 forward-compat도 유지한다. reader는 없으면 false. 비마커 leaf
    // 카드에만 의미(마커·최상위-run 뒷카드는 위치 파생). 전 탭 false면 byte-identical. 기본 false.
    top_level: bool = false,
    tree: []const TreeNode, // preorder; leaf의 pane 인덱스가 panes를 가리킨다
    panes: []const Pane,
};

/// 한 OS 창의 픽셀(점) frame — 전역 스크린 좌표(bottom-left 원점, macOS NSWindow.frame). 절대 frame이라 어느
/// 모니터인지 자동 인코딩된다(각 모니터가 전역 좌표 영역을 차지하므로 display ID가 불필요 — M3f, docs/
/// window-surface-mobility.md §8A.8). x/y는 음수 가능(main 왼쪽/아래 보조 모니터), w/h는 양수. 저장은 점 단위
/// 정수(픽셀 아님 — HiDPI backing scale 무관). 복원 시 Swift가 어떤 NSScreen.visibleFrame과도 충분히 교차 안
/// 하면 main 화면으로 clamp한다.
pub const Frame = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// null=inferred legacy mode, non-null=explicit snapshot(빈 slice도 유효한 explicit-empty).
/// 저장소별 **비교 기준**(docs/editor-surface-dock.md §3.5). `origin/HEAD`가 없는 저장소에서 사용자가
/// 고른 값이고, 그 선택은 앱을 다시 켜도 남아야 한다("고를 수 있는데 매번 다시 골라야 한다"는 반쪽이다).
///
/// **창 줄에 실린다.** 저장소 단위 사실이라 최상위가 더 맞아 보이지만, 저장은 창마다 따로 일어난다
/// (`serializeWindow` — 각 세션이 자기 블록을 내고 Swift가 헤더 아래로 모은다). 최상위 섹션은 **쓸 주인이
/// 없다.** 그래서 탐색기 root 목록과 같은 자리에 같은 방식으로 싣는다.
pub const ScmBase = struct {
    /// 저장소 루트(절대 경로).
    repo: []const u8,
    /// 기준 ref 이름(`origin/main` 형태). `git_command.isSafeBaseRef`를 통과한 값만 싣는다 —
    /// 이 값은 다음 실행에서 **argv에 실린다**(§6: 파일을 거쳐 온 문자열은 인자 자리에서 다시 본다).
    base: []const u8,
};

pub const ExplorerPersistedState = struct {
    roots: ?[]const []const u8 = null,
};

/// 한 OS 창 = 한 AppSession. 탭들 + 활성 탭.
pub const Window = struct {
    active_tab: usize = 0,
    // 재시작 시 다시 focus할 활성(key) 창 마커(M3e — docs/window-surface-mobility.md §8A.8). 순수 additive 스칼라라
    // false(기본)면 writer가 키를 **생략**해(round-trip 고정점·옛 파일 flat 정상) 옛 리더가 미지 키로 skip하는
    // forward-compat도 유지한다(group-collapsed 옵션-키 패턴 그대로). reader는 없으면 false. 여러 창 중 최대 하나만
    // true(저장 시점 key 창) — 복원 loop가 activeWindowIndex로 그 창을 makeKeyAndOrderFront한다. 없으면(옛 파일·무마커)
    // 현행 동작(마지막 생성 창이 key) 유지. 기본 false.
    active: bool = false,
    // 창 픽셀(점) frame(M3f — docs/window-surface-mobility.md §8A.8). null=미저장(옛 파일·부분 필드) → 복원이 현행
    // 기본(cascade) 위치. 순수 additive 스칼라 4개(win-x/y/w/h)라 active-window와 동일한 옵션-키 패턴: null이면 writer가
    // 넷 다 생략(round-trip 고정점·옛 파일 flat 정상), 옛 리더가 미지 키 skip(forward-compat). 넷 다 있어야 frame,
    // 하나라도 없으면 null(부분=손상 방어). 전역 좌표라 어느 모니터인지 자동 인코딩. 기본 null.
    frame: ?Frame = null,
    // 창 레벨 파일 도크. 단일 그룹은 FP1 flat `dock-entry`, 다중 그룹은 FP8 additive preorder 키를 같은 window
    // 라인에 둔다. 기본값은 키를 전부 생략해 옛 파일 고정점과 양방향 호환을 유지한다.
    dock: dock_panel.PersistedState = .{},
    explorer: ExplorerPersistedState = .{},
    /// 저장소별 비교 기준(§3.5). 빈 목록이면 전부 기본값(`origin/HEAD`)이다.
    scm_bases: []const ScmBase = &.{},
    tabs: []const Tab,
};

/// 저장 단위(최근 세션 1개). 창 N개.
pub const Workspace = struct {
    windows: []const Window,
};

pub const RuntimeBindingValidationError = error{
    DuplicateRuntimeBinding,
    TooManyRuntimeBindings,
} || std.mem.Allocator.Error;

/// manifest의 writable runtime owner가 전역에서 하나뿐인지 검증한다. host observer subscription 수와는 무관한
/// layout 소유권 검증이며, restore attach/spawn과 checkpoint write보다 먼저 호출된다.
pub fn validateRuntimeBindings(allocator: std.mem.Allocator, ws: Workspace) RuntimeBindingValidationError!void {
    var full_handles = std.AutoHashMap([64]u8, void).init(allocator);
    defer full_handles.deinit();
    var full_runtime_ids = std.AutoHashMap([32]u8, void).init(allocator);
    defer full_runtime_ids.deinit();
    var bare_runtime_ids = std.AutoHashMap([32]u8, void).init(allocator);
    defer bare_runtime_ids.deinit();
    var binding_count: usize = 0;

    for (ws.windows) |win| {
        for (win.tabs) |tab| {
            for (tab.panes) |pane| {
                for (pane.surfaces) |surface| {
                    if (surface.runtime_id.len == 0) continue;
                    binding_count += 1;
                    if (binding_count > max_runtime_bindings) return error.TooManyRuntimeBindings;
                    // 구조적 identity 검증은 writeSurface/parseSurface의 단일 출처에 맡긴다. 여기서는 유효한 key만
                    // 전역 비교하고, 손상 모델을 고정 길이 배열에 복사해 panic하지 않는다.
                    if (surface.runtime_id.len != 32 or
                        (surface.runtime_host_id.len != 0 and surface.runtime_host_id.len != 32)) continue;

                    var runtime_id: [32]u8 = undefined;
                    @memcpy(runtime_id[0..], surface.runtime_id);
                    if (surface.runtime_host_id.len == 0) {
                        // legacy bare ID는 current host namespace를 암묵적으로 쓰므로 같은 runtime ID의 full/bare owner와
                        // 공존시키지 않는다. exact host를 증명할 수 없는 writable 중복은 attach 전에 fail-close한다.
                        if (bare_runtime_ids.contains(runtime_id) or full_runtime_ids.contains(runtime_id))
                            return error.DuplicateRuntimeBinding;
                        try bare_runtime_ids.put(runtime_id, {});
                        continue;
                    }

                    var handle: [64]u8 = undefined;
                    @memcpy(handle[0..32], surface.runtime_host_id);
                    @memcpy(handle[32..64], surface.runtime_id);
                    if (full_handles.contains(handle) or bare_runtime_ids.contains(runtime_id))
                        return error.DuplicateRuntimeBinding;
                    try full_handles.put(handle, {});
                    // 다른 host가 우연히 같은 runtime_id를 쓰는 것은 distinct full handle이라 허용한다. 이 보조 set은
                    // 뒤에 bare ID가 나왔을 때만 모호한 중복을 잡는다.
                    try full_runtime_ids.put(runtime_id, {});
                }
            }
        }
    }
}

/// 헤더 + 전체 workspace를 새 문자열로 직렬화한다(호출자 소유). live 캡처(R3)가 모델을 채워 넘기고, reader(R2)가
/// 같은 규칙으로 되읽는다.
pub fn serialize(allocator: std.mem.Allocator, ws: Workspace) ![]u8 {
    try validateRuntimeBindings(allocator, ws);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}\n", .{header});
    for (ws.windows) |win| try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

/// 한 창(Window) 블록만 직렬화한다(헤더 없음). 멀티 창 저장(R5)에서 각 AppSession이 자기 창 블록을 내고,
/// Swift가 `maru.workspace.v1` 헤더 하나 아래로 모아 parse 가능한 전체 텍스트를 만든다.
pub fn serializeWindow(allocator: std.mem.Allocator, win: Window) ![]u8 {
    try validateRuntimeBindings(allocator, .{ .windows = &.{win} });
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

/// 저장된 workspace에서 활성(key) 창의 인덱스 — active=true인 **첫** window(없으면 null). 복원 loop가 이 인덱스의
/// 창을 다시 focus(makeKeyAndOrderFront)한다. 옛 파일·무마커면 null(현행 동작 유지 — 마지막 생성 창이 key). 최대
/// 하나만 active=true지만, 손상/변조로 여러 개면 관대하게 첫 번째를 쓴다. M3e — docs/window-surface-mobility.md §8A.8.
pub fn activeWindowIndex(ws: Workspace) ?usize {
    for (ws.windows, 0..) |win, i| if (win.active) return i;
    return null;
}

/// 저장된 workspace에서 window_index 창의 픽셀(점) frame(전역 스크린 좌표) — 있으면 그 값, 없으면 null. 복원 loop가
/// 창마다 이 값을 받아 clamp 후 setFrame한다(없으면 현행 기본 cascade 위치 유지). null이 되는 경우: 옛 파일(win-* 키
/// 없음)·부분 필드(넷 중 일부만)·index 범위 밖. M3f — docs/window-surface-mobility.md §8A.8.
pub fn windowFrame(ws: Workspace, index: usize) ?Frame {
    if (index >= ws.windows.len) return null;
    return ws.windows[index].frame;
}

fn writeWindow(w: *std.Io.Writer, win: Window) !void {
    try validateDockState(win.dock);
    try validateExplorerState(win.explorer);
    try validateScmBases(win.scm_bases);
    try w.print("window tabs={d} active-tab={d}", .{ win.tabs.len, win.active_tab });
    // 활성(key) 창 마커(M3e §8A.8). false면 키 생략(additive·key-addressed — 옛 파일/비활성 창의 라인 문자열을 안
    // 바꿔 round-trip 고정점·양쪽 호환, group-collapsed와 동일). true면 active-window=1 스칼라로 쓴다.
    if (win.active) try w.writeAll(" active-window=1");
    // 창 픽셀(점) frame(M3f §8A.8). null이면 넷 다 생략(additive·key-addressed — 옛 파일/무-frame 창의 라인 문자열을
    // 안 바꿔 round-trip 고정점·양쪽 호환, active-window와 동일 패턴). 있으면 win-x/y/w/h를 넷 다 방출(전역 좌표, x/y는
    // 음수 가능 → {d}가 부호 포함). reader는 넷 다 있어야 frame으로 읽고 하나라도 없으면 null(부분=손상 방어).
    if (win.frame) |fr| try w.print(" win-x={d} win-y={d} win-w={d} win-h={d}", .{ fr.x, fr.y, fr.w, fr.h });
    // 도크는 새 line kind가 아니라 window 라인의 옵션/반복 키다. 옛 reader는 모르는 key를 skip하므로 뒤 창을
    // 잃지 않고, 기본값은 생략돼 기존 파일 byte 고정점도 유지된다(file-panel.md §5).
    if (win.dock.side != .right) try w.print(" dock-side={s}", .{@tagName(win.dock.side)});
    if (win.dock.size != 0) try w.print(" dock-size={d}", .{win.dock.size});
    if (win.dock.collapsed) try w.writeAll(" dock-collapsed=1");
    // 기본값(explorer)은 쓰지 않는다 — 옛 리더가 모르는 키를 만나지 않게 하고 파일도 짧게 유지한다.
    if (win.dock.view != .explorer) try w.print(" dock-view={s}", .{@tagName(win.dock.view)});
    const explorer_has_roots = if (win.explorer.roots) |roots| roots.len != 0 else false;
    if (win.dock.presented and !dockStateHasEntries(win.dock) and !explorer_has_roots)
        try w.writeAll(" dock-presented=1");
    if (win.explorer.roots) |roots| {
        try w.print(" dock-tree-roots=\"{d}:", .{roots.len});
        for (roots) |root| {
            try w.print("{d}:", .{root.len});
            try writeEscaped(w, root);
        }
        try w.writeByte('"');
    }
    // 저장소별 비교 기준(§3.5) — 탐색기 root와 같은 인코딩(길이 접두 + escape)이라 커서를 공유한다.
    if (win.scm_bases.len != 0) {
        try w.print(" scm-bases=\"{d}:", .{win.scm_bases.len});
        for (win.scm_bases) |entry| {
            try w.print("{d}:", .{entry.repo.len});
            try writeEscaped(w, entry.repo);
            try w.print("{d}:", .{entry.base.len});
            try writeEscaped(w, entry.base);
        }
        try w.writeByte('"');
    }
    // FP16 §5.0: 파일 목록은 창 줄이 아니라 각 `pane` 줄의 `file-term` 필드로 나간다. 창 줄에 남는 도크 키는
    // **탐색기 것뿐**이다(dock-size·dock-collapsed·dock-presented·dock-tree-roots).
    // 옛 `dock-entry`/`dock-entry-v2`/`dock-node`/`dock-group-*`는 **읽기만** 유지한다(1회 마이그레이션).
    try w.writeByte('\n');
    for (win.tabs) |tab| try writeTab(w, tab);
}

fn dockStateHasEntries(dock: dock_panel.PersistedState) bool {
    if (dock.entries.len != 0) return true;
    return false;
}

/// 저장 전에 거른다(§3.5). **읽을 때도 같은 검사를 다시 한다** — 파일은 우리 밖의 것이고, 이 값의
/// 다음 정거장은 git argv다. 여기서만 걸러 두면 손으로 고친 파일이 그 검사를 통째로 건너뛴다.
fn validateScmBases(entries: []const ScmBase) !void {
    if (entries.len > max_scm_bases) return error.InvalidScmBases;
    for (entries, 0..) |entry, i| {
        if (entry.repo.len == 0 or entry.repo.len > std.fs.max_path_bytes or
            !std.fs.path.isAbsolute(entry.repo) or !std.unicode.utf8ValidateSlice(entry.repo))
            return error.InvalidScmBases;
        // 형태 판정의 출처는 git 명령을 만드는 쪽이다 — 저장이 받는 값과 실행이 받는 값이 갈리지 않게.
        if (!git_command.isSafeBaseRef(entry.base)) return error.InvalidScmBases;
        // 같은 저장소가 둘이면 **어느 쪽이 맞는지 알 수 없다**. 나중 것으로 덮는 규칙을 여기 두면
        // 그 규칙이 파일 형식의 일부가 되고, 읽는 쪽마다 다르게 해석될 자리를 남긴다.
        for (entries[0..i]) |prior| if (std.mem.eql(u8, prior.repo, entry.repo)) return error.InvalidScmBases;
    }
}

fn validateExplorerState(explorer: ExplorerPersistedState) !void {
    const roots = explorer.roots orelse return;
    if (roots.len > max_explorer_roots) return error.InvalidExplorerState;
    var payload_len: usize = std.fmt.count("{d}:", .{roots.len});
    for (roots, 0..) |root, i| {
        if (root.len == 0 or root.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(root) or
            !std.unicode.utf8ValidateSlice(root)) return error.InvalidExplorerState;
        for (roots[0..i]) |prior| if (std.mem.eql(u8, prior, root)) return error.InvalidExplorerState;
        payload_len = std.math.add(usize, payload_len, std.fmt.count("{d}:", .{root.len})) catch return error.InvalidExplorerState;
        payload_len = std.math.add(usize, payload_len, root.len) catch return error.InvalidExplorerState;
        if (payload_len > max_explorer_root_payload_bytes) return error.InvalidExplorerState;
    }
}

/// 창 줄에 실리는 도크 상태 검증. FP16 이후 이 목록은 **capture 쪽에서만** 존재한다(복원은 pane 줄의
/// `file-term`이 담당) — `dock-presented` 판정이 이 목록을 보므로 불변식(경로 유일 · 있으면 정확히 하나 active)은
/// 그대로 건다. 옛 그룹/트리 검증은 그 포맷을 읽던 1회 마이그레이션 경로와 함께 제거했다(2026-07-29).
fn validateDockState(dock: dock_panel.PersistedState) !void {
    if (dock.entries.len > max_dock_entries) return error.InvalidDockState;
    var active_entries: usize = 0;
    for (dock.entries, 0..) |entry, i| {
        if (entry.path.len == 0 or !entry.mode.allowedFor(entry.kind)) return error.InvalidDockState;
        active_entries += @intFromBool(entry.active);
        for (dock.entries[0..i]) |existing| {
            if (std.mem.eql(u8, existing.path, entry.path)) return error.InvalidDockState;
        }
    }
    if ((dock.entries.len == 0 and active_entries != 0) or
        (dock.entries.len > 0 and active_entries != 1)) return error.InvalidDockState;
}

fn writeTab(w: *std.Io.Writer, tab: Tab) !void {
    try w.print("tab panes={d} active-pane={d} custom-name=\"", .{ tab.panes.len, tab.active_pane });
    try writeEscaped(w, tab.custom_name);
    try w.print("\" pinned={d} background-color={d} accent-color={d}", .{ @intFromBool(tab.pinned), tab.background_color, tab.accent_color });
    // 그룹 시작 마커(docs/sidebar-groups.md §4). null이면 키 자체를 생략한다 — 빈 문자열("")은 "이름 없는 그룹
    // 시작"과 구분해야 하므로 null을 빈 값으로 인코딩하지 않고 키 부재로 표현한다. reader는 group-start 키가 없으면
    // null(그룹 아님)로 읽어 round-trip이 고정된다. group-collapsed는 그룹 시작 탭에만 의미라 함께 쓴다.
    if (tab.group_start) |name| {
        try w.writeAll(" group-start=\"");
        try writeEscaped(w, name);
        try w.print("\" group-collapsed={d}", .{@intFromBool(tab.group_collapsed)});
        // 중첩 그룹 깊이(SG5-3, §4). 기본 1(최상위 그룹)이면 키 생략 — 옛 파일/비중첩 그룹의 라인 문자열을 안 바꿔
        // round-trip 고정점을 유지하고(옛 리더 미지 키 skip으로 양쪽 호환), >1일 때만 group-depth 스칼라로 쓴다.
        if (tab.group_depth > 1) try w.print(" group-depth={d}", .{tab.group_depth});
        // 그룹 공통 색(SG5-2, §4). 0=색 없음이면 키 생략(additive·key-addressed — 옛 파일/무색 그룹의 라인 문자열을
        // 안 바꿔 round-trip 고정점). 비영이면 group-color 스칼라로 쓴다(reader는 없으면 getUint 기본 0으로 폴백).
        if (tab.group_color != 0) try w.print(" group-color={d}", .{tab.group_color});
    }
    // 그룹-로컬 pin(GL, §13). group_start와 **무관**하게(멤버 카드 = group_start==null) 밖에서 쓴다. false면 키
    // 생략(additive·key-addressed — 옛 파일/비-로컬-pin 카드의 라인 문자열을 안 바꿔 round-trip 고정점). true면 스칼라.
    if (tab.local_pinned) try w.writeAll(" local-pinned=1");
    // §2.1 재설계 서브파티션 마커(top-level, §14). group_start와 무관하게 밖에서 쓴다. false면 키 생략(additive·
    // key-addressed — 옛 파일/비-top-level 카드의 라인 문자열을 안 바꿔 round-trip 고정점·양쪽 호환). true면 스칼라.
    if (tab.top_level) try w.writeAll(" top-level=1");
    try w.writeByte('\n');
    for (tab.tree) |node| try writeTreeNode(w, node);
    for (tab.panes) |pane| try writePane(w, pane);
}

fn writeTreeNode(w: *std.Io.Writer, node: TreeNode) !void {
    switch (node) {
        .leaf => |idx| try w.print("tree-node leaf pane={d}\n", .{idx}),
        .split => |s| try w.print("tree-node split {s} ratio={d}\n", .{ @tagName(s.direction), s.ratio_milli }),
    }
}

fn writePane(w: *std.Io.Writer, pane: Pane) !void {
    try w.print("pane surfaces={d} active-term={d} custom-name=\"", .{ pane.surfaces.len, pane.active_term });
    try writeEscaped(w, pane.custom_name);
    try w.writeAll("\"");
    // 파일 Term은 `surface` 줄이 아니라 이 줄의 반복 필드다(§5.0). `surfaces` 개수 필드는 **PTY surface 수**로
    // 남는다 — 옛 리더가 그 수만큼 `surface` 줄을 읽는 계약이라 건드리면 하위호환이 깨진다.
    // diff Term은 저장하지 않는다(docs/editor-surface-dock.md §3.5 — 그 시점 git 상태의 비교 결과라 되살리면 다른 것을
    // 같은 것처럼 보여 준다). **제외는 capture 단계에서 한다** — 여기서만 빼면 이미 부여된 index가 줄어든 총계와
    // 어긋나 복원 시 그 창 전체가 fail-close된다. 여기 검사는 잘못된 입력을 그대로 흘리지 않기 위한 두 번째 방어다.
    for (pane.file_terms) |ft| if (ft.kind != .diff) try writeFileTerm(w, ft);
    for (pane.browser_terms) |bt| try writeBrowserTerm(w, bt);
    if (pane.active_browser) |ab| try w.print(" active-browser={d}", .{ab});
    try w.writeAll("\n");
    for (pane.surfaces) |s| try writeSurface(w, s);
}

/// `file-term="<persisted-index>:<kind>:<mode>:<path-byte-len>:<path>"`. dock-entry와 같은 self-delimiting
/// 규칙(길이를 앞에, path를 마지막에)이라 `:`·공백·따옴표가 든 macOS 파일명도 escape 없이 왕복한다.
fn writeFileTerm(w: *std.Io.Writer, ft: FileTerm) !void {
    try w.print(" file-term=\"{d}:{s}:{s}:{d}:", .{ ft.index, @tagName(ft.kind), ft.mode.workspaceName(), ft.path.len });
    try writeEscaped(w, ft.path);
    try w.writeByte('"');
}

/// `browser-term="<insert-after>:<url-byte-len>:<url>"`. file-term과 같은 self-delimiting 모양이라 URL 안의
/// 특수문자·따옴표가 필드 경계를 깨지 않는다(WP-P).
fn writeBrowserTerm(w: *std.Io.Writer, bt: BrowserTerm) !void {
    try w.print(" browser-term=\"{d}:{d}:", .{ bt.insert_after, bt.url.len });
    try writeEscaped(w, bt.url);
    try w.writeByte('"');
}

fn writeSurface(w: *std.Io.Writer, s: Surface) !void {
    // custom-name(사용자 지정 이름)을 auto title 앞에 둔다 — 둘을 인접 배치해 사람이 읽기 쉽게. 리더(parseSurface)는
    // key-addressed(순서 무관·이름 조회, LineFields)라 이 순서는 가독성용일 뿐이다.
    try w.writeAll("surface custom-name=\"");
    try writeEscaped(w, s.custom_name);
    try w.writeAll("\" title=\"");
    try writeEscaped(w, s.title);
    try w.writeAll("\" cwd=\"");
    try writeEscaped(w, s.cwd);
    try w.writeAll("\" command=\"");
    try writeEscaped(w, s.command);
    try w.writeAll("\"");
    // 새 persistent identity는 host namespace와 runtime namespace를 한 필드로 묶는다. host 없는 runtime_id는 옛 파일을
    // 아직 attach하지 못한 migration 상태라 bare key를 한 번 더 보존한다. 새 live capture는 이 상태를 만들지 않는다.
    if (s.runtime_host_id.len > 0 or s.runtime_id.len > 0) {
        if (!validPersistentId(s.runtime_id)) return error.InvalidRuntimeIdentity;
        if (s.runtime_host_id.len > 0) {
            if (!validPersistentId(s.runtime_host_id)) return error.InvalidRuntimeIdentity;
            try w.writeAll(" runtime-handle=\"");
            try w.writeAll(s.runtime_host_id);
            try w.writeByte(':');
            try w.writeAll(s.runtime_id);
            try w.writeAll("\"");
        } else {
            // legacy migration only: preserving an existing bare id is safer than dropping the user's reconnect target.
            try w.writeAll(" runtime-id=\"");
            try w.writeAll(s.runtime_id);
            try w.writeAll("\"");
        }
    }
    if (s.runtime_state == .ended) {
        // Tombstone이 handle 없이 기록되면 다음 reader가 어느 runtime의 종료 상태인지 증명할 수 없다. legacy bare ID도
        // host namespace가 없어 durable identity가 아니므로 writer에서 fail-close한다.
        if (!validPersistentId(s.runtime_host_id) or !validPersistentId(s.runtime_id))
            return error.InvalidRuntimeIdentity;
        try w.writeAll(" runtime-state=\"ended\"");
    }
    try w.print(" cols={d} rows={d}\n", .{ s.cols, s.rows });
}

// ── R1 wire reader/parser ──────────────────────────────────────────────────────
// maru.workspace.v1 텍스트를 같은 모델로 되읽는다(round-trip). 결과는 arena가 모든 슬라이스·문자열을 소유하므로
// ParsedWorkspace.deinit() 한 번으로 정리한다. split 트리는 writer와 같은 preorder를 재귀로 재구성한다(split는
// 뒤따르는 두 subtree를 소비). 알 수 없는 trailing 라인은 forgiving하게 멈춘다(window 루프가 안 맞으면 종료).

pub const ParseError = error{ BadHeader, BadLine, Truncated } || std.mem.Allocator.Error;

/// parse 결과 — arena가 workspace의 모든 할당(슬라이스·escape 해제 문자열)을 소유한다. deinit으로 한 번에 해제.
pub const ParsedWorkspace = struct {
    arena: std.heap.ArenaAllocator,
    workspace: Workspace,

    pub fn deinit(self: *ParsedWorkspace) void {
        self.arena.deinit();
    }
};

const ParseLimits = struct {
    runtime_bindings: usize = 0,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!ParsedWorkspace {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines = LineIter{ .text = text };
    const head = lines.next() orelse return error.Truncated;
    if (!std.mem.eql(u8, head, header)) return error.BadHeader;

    var limits: ParseLimits = .{};
    var windows: std.ArrayList(Window) = .empty;
    while (lines.peek()) |line| {
        if (!std.mem.startsWith(u8, line, "window ")) break; // 알 수 없는 trailing → forgiving 종료
        try windows.append(a, try parseWindow(a, &lines, &limits));
    }
    const workspace: Workspace = .{ .windows = try windows.toOwnedSlice(a) };
    // validator hash-map은 parse model arena의 일부가 아니다. caller allocator를 써서 이 함수 안에서 실제 free하고,
    // ParsedWorkspace가 오래 살아도 scratch capacity가 함께 잔류하지 않게 한다.
    validateRuntimeBindings(allocator, workspace) catch |err| switch (err) {
        error.DuplicateRuntimeBinding, error.TooManyRuntimeBindings => return error.BadLine,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .arena = arena, .workspace = workspace };
}

fn parseWindow(a: std.mem.Allocator, lines: *LineIter, limits: *ParseLimits) ParseError!Window {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "window")) return error.BadLine;
    const tab_count = try f.requireUint("tabs", usize); // 구조 키(탭 개수) — 없으면 BadLine
    const active_tab = try f.getUint("active-tab", usize, 0); // 스칼라(기본 0=첫 탭)
    // 활성(key) 창 마커(M3e §8A.8). additive 스칼라라 없으면 false(옛 파일 = 무마커 = 현행 동작). 여러 창 중 최대
    // 하나만 true(저장 시점 key 창). group-collapsed와 동일한 옵션-키 패턴(getUint 기본 0 → forward/backward 호환).
    const active = (try f.getUint("active-window", u8, 0)) != 0;
    // 창 픽셀(점) frame(M3f §8A.8). additive 스칼라 4개(win-x/y/w/h)라 **넷 다 있어야** frame이고, 하나라도 없으면 null:
    // 옛 파일(win-* 무)·부분 필드(손상/변조로 일부만) 모두 cascade 기본 위치로 graceful 폴백한다(writer는 넷 다 or 아무것도
    // 안 냄 → 정상 파일은 all-or-none, 부분은 손상뿐). 단 넷 다 **있는데** 값이 깨졌으면 getInt가 BadLine(존재하는 손상은
    // 숨기지 않음 — 스칼라 규칙). x/y는 음수 가능(전역 좌표 = 보조 모니터)이라 getInt(signed). group-collapsed 옵션-키와 동형.
    const frame: ?Frame = if (f.find("win-x") != null and f.find("win-y") != null and f.find("win-w") != null and f.find("win-h") != null) .{
        .x = try f.getInt("win-x", i32, 0),
        .y = try f.getInt("win-y", i32, 0),
        .w = try f.getInt("win-w", i32, 0),
        .h = try f.getInt("win-h", i32, 0),
    } else null;

    var dock_supported = true;
    const dock_side: dock_panel.Side = if (f.find("dock-side")) |field| blk: {
        if (field.is_quoted) return error.BadLine;
        if (std.mem.eql(u8, field.raw, "right")) break :blk .right;
        if (std.mem.eql(u8, field.raw, "bottom")) break :blk .bottom;
        // 미래 side는 이 버전이 도크를 해석할 수 없다는 뜻이다. terminal workspace 전체를 버리지 않고 도크만 기본값으로.
        dock_supported = false;
        break :blk .right;
    } else .right;
    const dock_size = try f.getUint("dock-size", u32, 0);
    const dock_collapsed = (try f.getUint("dock-collapsed", u8, 0)) != 0;
    // 모르는 뷰 이름은 `explorer`로 clamp한다(docs/file-explorer.md §3.5). side와 달리 도크 전체를 포기하지
    // 않는 이유는 뷰가 **표시 선택**일 뿐이라, 못 그리는 뷰를 만나도 탐색기로 열면 사용자가 잃는 게 없기 때문이다.
    const dock_view: dock_panel.View = if (f.find("dock-view")) |field| blk: {
        if (field.is_quoted) return error.BadLine;
        break :blk dock_panel.View.parse(field.raw) orelse .explorer;
    } else .explorer;
    const dock_presented_requested = (try f.getUint("dock-presented", u8, 0)) != 0;
    const explorer_roots_field = f.find("dock-tree-roots");
    const explorer_parse = parseExplorerRoots(a, explorer_roots_field);
    const explorer_roots = explorer_parse.roots;
    // FP16 이후 도크는 **탐색기 전용**이고 파일 목록은 pane 줄의 `file-term`이 든다(§5.0). 옛 창-레벨 파일 키
    // (`dock-entry`/`dock-entry-v2`/`dock-node`/`dock-group-*`/`dock-focused-group`)를 읽던 1회 마이그레이션
    // 경로는 제거했다(2026-07-29 사용자 결정) — 쓰기는 진작 멈췄고, 한 번 실행하면 새 포맷으로 다시 저장되므로
    // 그 경로를 무기한 유지할 이유가 없다. 그 키가 남은 아주 오래된 파일은 **아래 unknown-field 관용**으로
    // 조용히 무시된다(창·터미널은 복원되고 그때 열려 있던 파일 탭만 안 살아난다).
    const dock: dock_panel.PersistedState = .{
        .side = dock_side,
        .size = dock_size,
        .collapsed = dock_collapsed,
        .view = dock_view,
    };
    var dock_with_presented = dock;
    dock_with_presented.presented = dock_presented_requested or dockStateHasEntries(dock) or
        (explorer_roots != null and explorer_roots.?.len > 0) or
        (explorer_roots_field != null and !explorer_parse.valid);
    var tabs: std.ArrayList(Tab) = .empty;
    var i: usize = 0;
    while (i < tab_count) : (i += 1) try tabs.append(a, try parseTab(a, lines, limits));
    // 기준 목록은 **못 읽으면 없는 것으로 본다**(탐색기 root와 다르다 — 그쪽은 도크 표시 여부까지 걸린다).
    // 기억이 사라지면 사용자는 기본값 화면을 보고 다시 고르면 되지만, 깨진 값을 실으면 다음 실행이
    // 그 값을 argv에 넣는다. 잃는 쪽이 안전한 쪽이다.
    const scm_bases = parseScmBases(a, f.find("scm-bases"));
    return .{ .active_tab = active_tab, .active = active, .frame = frame, .dock = dock_with_presented, .explorer = .{ .roots = explorer_roots }, .scm_bases = scm_bases, .tabs = try tabs.toOwnedSlice(a) };
}

const ExplorerRootsParse = struct { roots: ?[]const []const u8, valid: bool };

/// 저장소별 기준을 읽는다(§3.5). 탐색기 root와 **같은 인코딩·같은 커서**를 쓴다: `<개수>:` 뒤로
/// `<길이>:<저장소><길이>:<기준>`이 이어진다.
///
/// **한 항목이라도 이상하면 목록 전체를 버린다.** 부분 복원은 "어떤 저장소는 기억됐고 어떤 것은 아니다"를
/// 만드는데, 사용자에게 그 둘은 구별되지 않는다(둘 다 그냥 기본값으로 보인다).
fn parseScmBases(a: std.mem.Allocator, maybe_field: ?LineFields.Field) []const ScmBase {
    const field = maybe_field orelse return &.{};
    // 원시 바이트 상한은 탐색기 root와 **같은 값을 일부러 공유한다**: 이 필드도 같은 커서로 읽히므로
    // 한쪽만 넉넉하면 그 차이가 곧 파서의 두 번째 규칙이 된다. 실제 상한은 아래 개수 검사가 좁힌다.
    if (!field.is_quoted or field.raw.len > max_explorer_root_raw_bytes) return &.{};
    var cursor = ExplorerQuotedCursor{ .raw = field.raw };
    const count = cursor.parseLength() catch return &.{};
    if (count > max_scm_bases) return &.{};
    const entries = a.alloc(ScmBase, count) catch return &.{};
    for (entries, 0..) |*entry, index| {
        const repo = readCursorString(a, &cursor, std.fs.max_path_bytes) orelse return &.{};
        const base = readCursorString(a, &cursor, git_command.max_base_ref_len) orelse return &.{};
        // 저장할 때 건 검사를 **읽을 때 다시 건다**. 파일은 우리 밖의 것이라 그 사이에 바뀔 수 있고,
        // 이 값의 다음 정거장은 git argv다(§6 심층 방어).
        if (!std.fs.path.isAbsolute(repo) or !std.unicode.utf8ValidateSlice(repo)) return &.{};
        if (!git_command.isSafeBaseRef(base)) return &.{};
        for (entries[0..index]) |prior| if (std.mem.eql(u8, prior.repo, repo)) return &.{}; // 같은 저장소가 둘이면 어느 쪽이 맞는지 알 수 없다
        entry.* = .{ .repo = repo, .base = base };
    }
    if ((cursor.next() catch return &.{}) != null) return &.{}; // 남은 바이트 = 우리가 쓴 것이 아니다
    return entries;
}

/// 커서에서 길이 접두 문자열 하나를 읽는다(빈 문자열·상한 초과는 실패).
fn readCursorString(a: std.mem.Allocator, cursor: *ExplorerQuotedCursor, max_len: usize) ?[]const u8 {
    const len = cursor.parseLength() catch return null;
    if (len == 0 or len > max_len) return null;
    const out = a.alloc(u8, len) catch return null;
    for (out) |*byte| byte.* = (cursor.next() catch return null) orelse return null;
    return out;
}

fn parseExplorerRoots(a: std.mem.Allocator, maybe_field: ?LineFields.Field) ExplorerRootsParse {
    const field = maybe_field orelse return .{ .roots = null, .valid = true };
    if (!field.is_quoted or field.raw.len > max_explorer_root_raw_bytes) return .{ .roots = &.{}, .valid = false };
    var cursor = ExplorerQuotedCursor{ .raw = field.raw };
    const count = cursor.parseLength() catch return .{ .roots = &.{}, .valid = false };
    if (count > max_explorer_roots) return .{ .roots = &.{}, .valid = false };
    const roots = a.alloc([]const u8, count) catch return .{ .roots = &.{}, .valid = false };
    for (roots, 0..) |*root, index| {
        const len = cursor.parseLength() catch return .{ .roots = &.{}, .valid = false };
        if (len == 0 or len > std.fs.max_path_bytes) return .{ .roots = &.{}, .valid = false };
        const path = a.alloc(u8, len) catch return .{ .roots = &.{}, .valid = false };
        for (path) |*byte| byte.* = (cursor.next() catch return .{ .roots = &.{}, .valid = false }) orelse
            return .{ .roots = &.{}, .valid = false };
        if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return .{ .roots = &.{}, .valid = false };
        for (roots[0..index]) |prior| if (std.mem.eql(u8, prior, path)) return .{ .roots = &.{}, .valid = false };
        root.* = path;
    }
    if ((cursor.next() catch return .{ .roots = &.{}, .valid = false }) != null)
        return .{ .roots = &.{}, .valid = false };
    return .{ .roots = roots, .valid = true };
}

const ExplorerQuotedCursor = struct {
    raw: []const u8,
    pos: usize = 0,
    decoded: usize = 0,

    fn next(self: *ExplorerQuotedCursor) error{ InvalidEscape, PayloadTooLarge }!?u8 {
        if (self.pos >= self.raw.len) return null;
        var value = self.raw[self.pos];
        self.pos += 1;
        if (value == '\\') {
            if (self.pos >= self.raw.len) return error.InvalidEscape;
            value = switch (self.raw[self.pos]) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidEscape,
            };
            self.pos += 1;
        }
        self.decoded = std.math.add(usize, self.decoded, 1) catch return error.PayloadTooLarge;
        if (self.decoded > max_explorer_root_payload_bytes) return error.PayloadTooLarge;
        return value;
    }

    fn parseLength(self: *ExplorerQuotedCursor) error{ InvalidLength, InvalidEscape, PayloadTooLarge }!usize {
        var value: usize = 0;
        var digits: usize = 0;
        while (true) {
            const byte = (try self.next()) orelse return error.InvalidLength;
            if (byte == ':') return if (digits == 0) error.InvalidLength else value;
            if (byte < '0' or byte > '9') return error.InvalidLength;
            value = std.math.mul(usize, value, 10) catch return error.InvalidLength;
            value = std.math.add(usize, value, byte - '0') catch return error.InvalidLength;
            digits += 1;
        }
    }
};

const DockEntryParseError = error{ BadLine, UnsupportedDockValue };

fn parseDockEntry(encoded: []const u8) DockEntryParseError!dock_panel.PersistedEntry {
    var pos: usize = 0;
    const kind_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const mode_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const active_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const path_len_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const path = encoded[pos..];

    const kind: dock_panel.EntryKind = if (std.mem.eql(u8, kind_raw, "markdown"))
        .markdown
    else if (std.mem.eql(u8, kind_raw, "html"))
        .html
    else if (std.mem.eql(u8, kind_raw, "text"))
        .text
    else if (std.mem.eql(u8, kind_raw, "svg"))
        .svg
    else if (std.mem.eql(u8, kind_raw, "image"))
        .image
    else if (std.mem.eql(u8, kind_raw, "media"))
        .media
    else if (std.mem.eql(u8, kind_raw, "pdf"))
        .pdf
    else
        return error.UnsupportedDockValue;
    // 폐기된 라이브 프리뷰로 저장된 옛 entry는 그 kind의 기본 모드로 마이그레이션한다(docs/file-panel.md §1·§5).
    // 여기서 흡수하지 않으면 아래 UnsupportedDockValue가 그 창의 도크 전체를 빈 상태로 강등해 파일 탭이 사라진다.
    const parsed_mode = if (std.mem.eql(u8, mode_raw, dock_panel.legacy_live_preview_mode_name))
        dock_panel.Mode.defaultFor(kind)
    else
        dock_panel.Mode.parseWorkspaceName(mode_raw) orelse return error.UnsupportedDockValue;
    // kind에서 더 이상 허용하지 않는 모드도 defaultFor로 clamp해 복원을 거부하지 않고 조용히 마이그레이션한다.
    const mode = if (parsed_mode.allowedFor(kind)) parsed_mode else dock_panel.Mode.defaultFor(kind);
    const active = if (std.mem.eql(u8, active_raw, "0"))
        false
    else if (std.mem.eql(u8, active_raw, "1"))
        true
    else
        return error.BadLine;
    const path_len = std.fmt.parseInt(usize, path_len_raw, 10) catch return error.BadLine;
    if (path.len == 0 or path.len != path_len) return error.BadLine;
    return .{ .path = path, .kind = kind, .mode = mode, .active = active };
}

fn dockEntryPart(encoded: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= encoded.len) return null;
    const end = std.mem.indexOfScalarPos(u8, encoded, pos.*, ':') orelse return null;
    if (end == pos.*) return null;
    const part = encoded[pos.*..end];
    pos.* = end + 1;
    return part;
}

fn parseTab(a: std.mem.Allocator, lines: *LineIter, limits: *ParseLimits) ParseError!Tab {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "tab")) return error.BadLine;
    const pane_count = try f.requireUint("panes", usize); // 구조 키(트리·pane 개수 결정) — 없으면 BadLine

    // 손상/변조 파일 방어(R6 graceful). 0개 탭은 빌드 단계에서 무효이고, 부풀린 pane_count는 아래 트리 노드
    // 상한을 거대화해 깊은 재귀를 부르므로 sane 상한으로 먼저 가둔다 — 위반 시 BadLine→그 창은 기본 창으로.
    if (pane_count == 0 or pane_count > max_panes_per_tab) return error.BadLine;

    // 스칼라 속성(순서 무관·없으면 기본값 = additive 하위호환). background-color·accent-color는 나중 추가돼도
    // 옛 파일이 안 깨지고 0(없음)으로 복원된다(docs/workspace-restore.md "직렬화 진화 계획").
    const active_pane = try f.getUint("active-pane", usize, 0);
    const custom_name = try f.getQuoted(a, "custom-name", "");
    const pinned = (try f.getUint("pinned", u8, 0)) != 0;
    const background_color = try f.getUint("background-color", u32, 0);
    const accent_color = try f.getUint("accent-color", u32, 0);
    // 그룹 시작 마커(additive — docs/sidebar-groups.md §4). group-start 키가 **있을 때만** 그룹 시작이다:
    // 없으면 null(그룹 아님), 있으면 그 이름(빈 문자열도 유효한 "이름 없는 그룹"). 그래서 getQuoted 기본값이
    // 아니라 find로 존재를 먼저 확인한다(키 부재 ↔ 빈 값을 구분 — writer가 null을 키 생략으로 인코딩한 것과 짝).
    const group_start: ?[]const u8 = if (f.find("group-start") != null) try f.getQuoted(a, "group-start", "") else null;
    const group_collapsed = (try f.getUint("group-collapsed", u8, 0)) != 0;
    // 중첩 그룹 깊이(SG5-3, §4·§9). additive 스칼라라 없으면 1(최상위 그룹). group_start=null인 탭에서 읽혀도 무의미
    // (렌더가 group_start로 게이트). 정규화(gap 클램프)는 projectRows가 위치 파생 스택으로 재계산한다.
    const group_depth = try f.getUint("group-depth", u8, 1);
    // 그룹 공통 색(SG5-2, §4·§9). additive 스칼라라 없으면 0(색 없음). 그룹 시작 탭에만 의미(writer가 group-start
    // 있을 때만 비영 group-color를 쓴다) — group_start=null인 탭에서 0으로 읽혀도 무해(렌더가 group_start로 게이트).
    const group_color = try f.getUint("group-color", u32, 0);
    // 그룹-로컬 pin(GL, §13). additive 스칼라라 없으면 false. 멤버 카드에만 의미(마커·top카드에선 무시) — 렌더/파티션이
    // 위치·group_start로 게이트하므로 그 밖 탭에서 true로 읽혀도 무해(전역 파티션은 이 필드를 안 읽는다).
    const local_pinned = (try f.getUint("local-pinned", u8, 0)) != 0;
    // §2.1 재설계 서브파티션 마커(top-level, §14). additive 스칼라라 없으면 false. 비마커 leaf 카드에만 의미 — 렌더/파생이
    // 위치·group_start로 게이트하므로 그 밖 탭에서 true로 읽혀도 무해(7 파생 경계 리셋/break만 반응, 전역 파티션 무관).
    const top_level = (try f.getUint("top-level", u8, 0)) != 0;

    var tree: std.ArrayList(TreeNode) = .empty;
    // 구조 불변식: pane P개 탭의 split 트리는 leaf P + split (P−1) = 정확히 2P−1 노드다. 그보다 많이 읽히면
    // (손상·순환) BadLine으로 멈춰 크래시 대신 graceful 폴백한다. pane_count가 가둬졌으니 재귀 깊이도 ≤2P−1.
    try parseTree(a, lines, &tree, 2 * pane_count - 1); // 탭의 트리 하나(self-delimiting preorder)

    var panes: std.ArrayList(Pane) = .empty;
    var i: usize = 0;
    while (i < pane_count) : (i += 1) try panes.append(a, try parsePane(a, lines, limits));
    return .{ .active_pane = active_pane, .custom_name = custom_name, .pinned = pinned, .background_color = background_color, .accent_color = accent_color, .group_start = group_start, .group_collapsed = group_collapsed, .group_depth = group_depth, .group_color = group_color, .local_pinned = local_pinned, .top_level = top_level, .tree = try tree.toOwnedSlice(a), .panes = try panes.toOwnedSlice(a) };
}

/// 한 subtree를 preorder로 읽어 out에 append(self-delimiting). split는 뒤따르는 두 subtree(a,b)를 재귀로 소비.
/// max_nodes = 2·pane_count−1(구조 불변식): 이미 그만큼 읽었으면 더 읽지 않고 BadLine — 노드 수·재귀 깊이를 함께 가둔다.
fn parseTree(a: std.mem.Allocator, lines: *LineIter, out: *std.ArrayList(TreeNode), max_nodes: usize) ParseError!void {
    if (out.items.len >= max_nodes) return error.BadLine; // 트리 노드 수 > 2·pane−1 — 손상/순환(스택 오버플로 방지)
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "tree-node")) return error.BadLine;
    const kind = try r.word();
    if (std.mem.eql(u8, kind, "leaf")) {
        try r.key("pane=");
        try out.append(a, .{ .leaf = try r.uint(usize) });
    } else if (std.mem.eql(u8, kind, "split")) {
        const dir_word = try r.word();
        const dir: SplitDirection = if (std.mem.eql(u8, dir_word, "horizontal"))
            .horizontal
        else if (std.mem.eql(u8, dir_word, "vertical"))
            .vertical
        else
            return error.BadLine;
        try r.key("ratio=");
        const ratio = try r.uint(u16);
        try out.append(a, .{ .split = .{ .direction = dir, .ratio_milli = ratio } });
        try parseTree(a, lines, out, max_nodes); // a
        try parseTree(a, lines, out, max_nodes); // b
    } else return error.BadLine;
}

fn parsePane(a: std.mem.Allocator, lines: *LineIter, limits: *ParseLimits) ParseError!Pane {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "pane")) return error.BadLine;
    const surface_count = try f.requireUint("surfaces", usize); // 구조 키(surface 개수) — 없으면 BadLine
    const active_term = try f.getUint("active-term", usize, 0); // 스칼라(기본 0)
    const custom_name = try f.getQuoted(a, "custom-name", "");

    // FP16 파일 Term(반복 필드). 인식 못 하는 kind/mode는 그 **entry만** 버린다 — 창 전체를 폴백시키지 않는다
    // (dock-entry의 UnsupportedDockValue와 같은 관용). 개수 상한은 창당 파일 상한과 같다.
    var file_terms: std.ArrayList(FileTerm) = .empty;
    for (f.fields) |field| {
        if (!std.mem.eql(u8, field.key, "file-term")) continue;
        if (!field.is_quoted or file_terms.items.len >= max_dock_entries) return error.BadLine;
        const encoded = try unescapeQuoted(a, field.raw);
        const parsed = parseFileTerm(encoded) catch |err| switch (err) {
            error.UnsupportedDockValue => continue,
            error.BadLine => return error.BadLine,
        };
        try file_terms.append(a, parsed);
    }

    // WP-P 브라우저 Term(반복 필드). URL만 담고 인덱스 공간을 안 건드리므로 검증도 file-term과 분리된다 —
    // `insert_after`는 "앞의 persisted Term 수"라 [0, persisted_total] **닫힌** 구간이 유효하다(끝에 붙는 경우 포함).
    var browser_terms: std.ArrayList(BrowserTerm) = .empty;
    for (f.fields) |field| {
        if (!std.mem.eql(u8, field.key, "browser-term")) continue;
        if (!field.is_quoted or browser_terms.items.len >= max_dock_entries) return error.BadLine;
        const encoded = try unescapeQuoted(a, field.raw);
        const parsed = parseBrowserTerm(encoded) catch |err| switch (err) {
            error.UnsupportedDockValue => continue, // 빈 URL 등 — 그 record만 버린다(창은 살린다)
            error.BadLine => return error.BadLine,
        };
        try browser_terms.append(a, parsed);
    }
    const active_browser: ?usize = if (f.find("active-browser") != null)
        try f.getUint("active-browser", usize, 0)
    else
        null;

    var surfaces: std.ArrayList(Surface) = .empty;
    var i: usize = 0;
    while (i < surface_count) : (i += 1) try surfaces.append(a, try parseSurface(a, lines, limits));
    const pane: Pane = .{
        .active_term = active_term,
        .custom_name = custom_name,
        .surfaces = try surfaces.toOwnedSlice(a),
        .file_terms = try file_terms.toOwnedSlice(a),
        .browser_terms = try browser_terms.toOwnedSlice(a),
        .active_browser = active_browser,
    };
    try validatePaneFileTerms(pane);
    try validatePaneBrowserTerms(pane);
    return pane;
}

/// WP-P 불변식: `insert_after <= persisted_total`(끝에 붙기 허용), `active-browser < browser_terms.len`.
/// 위반은 그 창을 fail-closed 강등한다(file-term과 같은 규율).
fn validatePaneBrowserTerms(pane: Pane) ParseError!void {
    if (pane.browser_terms.len == 0) {
        if (pane.active_browser != null) return error.BadLine; // 활성 브라우저를 가리키는데 record가 없다
        return;
    }
    const persisted_total = pane.surfaces.len + pane.file_terms.len;
    for (pane.browser_terms) |bt| {
        if (bt.insert_after > persisted_total) return error.BadLine;
        if (bt.url.len == 0) return error.BadLine;
    }
    if (pane.active_browser) |ab| if (ab >= pane.browser_terms.len) return error.BadLine;
}

/// `browser-term="<insert-after>:<url-byte-len>:<url>"`. file-term과 같은 self-delimiting 파싱.
fn parseBrowserTerm(encoded: []const u8) DockEntryParseError!BrowserTerm {
    var pos: usize = 0;
    const after_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const insert_after = std.fmt.parseInt(usize, after_raw, 10) catch return error.BadLine;
    const len_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const url_len = std.fmt.parseInt(usize, len_raw, 10) catch return error.BadLine;
    if (pos + url_len != encoded.len) return error.BadLine; // self-delimiting: 남는 바이트가 정확히 URL
    const url = encoded[pos..];
    if (url.len == 0) return error.UnsupportedDockValue;
    if (!std.unicode.utf8ValidateSlice(url)) return error.BadLine;
    return .{ .insert_after = insert_after, .url = url };
}

/// persisted 시퀀스 불변식: index 중복 없음 + 전체가 `[0, persisted_total)`을 빠짐없이 덮음 +
/// `active-term < persisted_total`. 위반은 그 창을 기존 규칙대로 fail-closed 강등한다(§5.0).
fn validatePaneFileTerms(pane: Pane) ParseError!void {
    if (pane.file_terms.len == 0) return;
    const total = pane.surfaces.len + pane.file_terms.len;
    if (total > max_dock_entries + max_line_fields) return error.BadLine;
    for (pane.file_terms, 0..) |ft, i| {
        if (ft.index >= total) return error.BadLine;
        for (pane.file_terms[0..i]) |prior| {
            if (prior.index == ft.index) return error.BadLine;
            if (std.mem.eql(u8, prior.path, ft.path)) return error.BadLine; // pane 안 경로 중복
        }
    }
    if (pane.active_term >= total) return error.BadLine;
}

fn parseFileTerm(encoded: []const u8) DockEntryParseError!FileTerm {
    var pos: usize = 0;
    const index_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const index = std.fmt.parseInt(usize, index_raw, 10) catch return error.BadLine;
    // kind:mode:len:path는 dock-entry와 같은 문법이라 그 파서를 그대로 쓴다(active 자리는 없다).
    const kind_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const mode_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const path_len_raw = dockEntryPart(encoded, &pos) orelse return error.BadLine;
    const path = encoded[pos..];
    const kind = parseEntryKindName(kind_raw) orelse return error.UnsupportedDockValue;
    const parsed_mode = dock_panel.Mode.parseWorkspaceName(mode_raw) orelse return error.UnsupportedDockValue;
    const mode = if (parsed_mode.allowedFor(kind)) parsed_mode else dock_panel.Mode.defaultFor(kind);
    const path_len = std.fmt.parseInt(usize, path_len_raw, 10) catch return error.BadLine;
    if (path_len != path.len or path.len == 0) return error.BadLine;
    return .{ .index = index, .kind = kind, .mode = mode, .path = path };
}

fn parseEntryKindName(raw: []const u8) ?dock_panel.EntryKind {
    // writer가 절대 쓰지 않는 값은 reader도 받지 않는다 — 손으로 쓴 파일이 복원 못 할 상태를 만들지 못하게.
    if (std.mem.eql(u8, raw, "diff")) return null;
    inline for (@typeInfo(dock_panel.EntryKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @field(dock_panel.EntryKind, field.name);
    }
    return null;
}

fn parseSurface(a: std.mem.Allocator, lines: *LineIter, limits: *ParseLimits) ParseError!Surface {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "surface")) return error.BadLine;
    // 스칼라 속성(순서 무관·없으면 기본값). cols/rows는 복원 시 실제 pane 크기로 resize되므로 누락 시 sane 터미널
    // 기본(80×24)으로 graceful — 실 파일엔 항상 있고, 이 기본은 손상/축약 파일에서만 쓰인다.
    const custom_name = try f.getQuoted(a, "custom-name", "");
    const title = try f.getQuoted(a, "title", "");
    const cwd = try f.getQuoted(a, "cwd", "");
    const command = try f.getQuoted(a, "command", "");
    const legacy_runtime = f.find("runtime-id");
    const runtime_handle = f.find("runtime-handle");
    // Identity/state는 first-wins가 허용되는 일반 additive scalar가 아니다. 중복 키 하나로 valid 앞값 뒤의 손상·모순을
    // 숨길 수 있으므로 이 세 키만 exact uniqueness를 요구한다(unknown future scalar의 반복 관용성과 분리).
    if (f.count("runtime-id") > 1 or f.count("runtime-handle") > 1 or f.count("runtime-state") > 1)
        return error.BadLine;
    if (legacy_runtime != null and runtime_handle != null) return error.BadLine;
    var runtime_host_id: []const u8 = "";
    var runtime_id: []const u8 = "";
    if (runtime_handle != null) {
        const handle = try f.getQuoted(a, "runtime-handle", "");
        if (handle.len != 65 or handle[32] != ':' or
            !validPersistentId(handle[0..32]) or !validPersistentId(handle[33..65])) return error.BadLine;
        runtime_host_id = handle[0..32];
        runtime_id = handle[33..65];
    } else if (legacy_runtime != null) {
        runtime_id = try f.getQuoted(a, "runtime-id", "");
        if (!validPersistentId(runtime_id)) return error.BadLine;
    }
    if (runtime_id.len > 0) {
        limits.runtime_bindings += 1;
        if (limits.runtime_bindings > max_runtime_bindings) return error.BadLine;
    }
    var runtime_state: RuntimeState = .live;
    if (f.find("runtime-state") != null) {
        const state = try f.getQuoted(a, "runtime-state", "");
        if (!std.mem.eql(u8, state, "ended")) return error.BadLine;
        if (runtime_host_id.len == 0 or runtime_id.len == 0) return error.BadLine;
        runtime_state = .ended;
    }
    const cols = try f.getUint("cols", u16, 80);
    const rows = try f.getUint("rows", u16, 24);
    return .{
        .custom_name = custom_name,
        .title = title,
        .cwd = cwd,
        .command = command,
        .runtime_host_id = runtime_host_id,
        .runtime_id = runtime_id,
        .runtime_state = runtime_state,
        .cols = cols,
        .rows = rows,
    };
}

fn validPersistentId(id: []const u8) bool {
    if (id.len != 32) return false;
    var nonzero = false;
    for (id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    for (id) |c| nonzero = nonzero or c != '0';
    return nonzero;
}

/// 텍스트를 개행 단위 라인으로 나눈다(마지막 개행 뒤 빈 줄은 내지 않는다). peek은 소비 없이 다음 라인을 본다.
const LineIter = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.i >= self.text.len) return null;
        const start = self.i;
        const nl = std.mem.indexOfScalarPos(u8, self.text, self.i, '\n') orelse self.text.len;
        self.i = if (nl < self.text.len) nl + 1 else self.text.len;
        return self.text[start..nl];
    }

    fn peek(self: *const LineIter) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

/// `tree-node` 구조 라인 전용 순차(positional) 파서 — leaf/split 판별 word + pane=/ratio= 정수. 스칼라 속성 라인
/// (window/tab/pane/surface)은 순서 무관 key-addressed(LineFields)로 읽는다(docs/workspace-restore.md "직렬화 진화
/// 계획"). tree-node는 구조(라인 타입·판별 word)라 key=value가 아니어서 positional 유지. word=공백까지 한 토큰, key=`name` 정확 매치, uint=숫자.
const FieldReader = struct {
    line: []const u8,
    i: usize = 0,

    fn skipSpaces(self: *FieldReader) void {
        while (self.i < self.line.len and self.line[self.i] == ' ') self.i += 1;
    }

    fn word(self: *FieldReader) ParseError![]const u8 {
        self.skipSpaces();
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] != ' ') self.i += 1;
        if (self.i == start) return error.BadLine;
        return self.line[start..self.i];
    }

    fn key(self: *FieldReader, name: []const u8) ParseError!void {
        self.skipSpaces();
        if (!std.mem.startsWith(u8, self.line[self.i..], name)) return error.BadLine;
        self.i += name.len;
    }

    fn uint(self: *FieldReader, comptime T: type) ParseError!T {
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] >= '0' and self.line[self.i] <= '9') self.i += 1;
        if (self.i == start) return error.BadLine;
        return std.fmt.parseInt(T, self.line[start..self.i], 10) catch error.BadLine;
    }
};

/// 따옴표 값의 escape(`\\` `\"` `\n` `\r` `\t`)를 해제해 arena에 dup한다(writer.writeEscaped의 역연산).
/// LineFields가 조회 시점에 호출한다(원바이트는 토큰화 때 span만 잡아두고, 실제 읽는 키만 여기서 해제).
fn unescapeQuoted(a: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\') {
            i += 1;
            if (i >= raw.len) return error.BadLine;
            try out.append(a, switch (raw[i]) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.BadLine,
            });
            i += 1;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// 스칼라 속성 라인(`<kind> key=val key="quoted" ...`)을 **순서 무관** key=value 필드로 토큰화한다(key-addressed —
/// docs/workspace-restore.md "직렬화 진화 계획"). 구조 키(개수: `tabs`/`panes`/`surfaces`)는 `requireUint`으로
/// 없으면 BadLine(손상 탐지 loud-fail 유지), 스칼라 속성은 `getUint`/`getQuoted`로 없으면 기본값(additive 하위호환 —
/// 옛 파일이 안 깨짐). 미지 키는 조회 안 되어 자연히 skip(forward-compat). 값은 조회 시점에 파싱한다(quoted는 그때
/// escape 해제 → arena).
const LineFields = struct {
    const Field = struct { key: []const u8, raw: []const u8, is_quoted: bool }; // raw: uint=숫자 슬라이스 / quoted=따옴표 안 원바이트(escape 미해제)

    kind: []const u8,
    fields: []const Field,

    /// 라인을 `kind` + (key,value) 필드로 훑는다. 따옴표 값은 escape(`\"`)를 존중해 닫는 따옴표를 찾으므로, 값 안의
    /// `key=` 흉내나 공백이 토큰 경계를 깨지 않는다. key에 `=`가 없으면 BadLine, 닫는 따옴표가 없으면 BadLine.
    fn parse(a: std.mem.Allocator, line: []const u8) ParseError!LineFields {
        var i: usize = 0;
        while (i < line.len and line[i] == ' ') i += 1;
        const ks = i;
        while (i < line.len and line[i] != ' ') i += 1;
        if (i == ks) return error.BadLine; // 라인 타입 토큰 없음
        const kind = line[ks..i];

        var list: std.ArrayList(Field) = .empty;
        while (true) {
            while (i < line.len and line[i] == ' ') i += 1;
            if (i >= line.len) break;
            if (list.items.len >= max_line_fields) return error.BadLine; // 손상/변조 방어: 한 줄 토큰 폭주 차단(작업·메모리 경계)
            const key_start = i;
            while (i < line.len and line[i] != '=' and line[i] != ' ') i += 1;
            if (i >= line.len or line[i] != '=' or i == key_start) return error.BadLine; // key= 형식 아님
            const key = line[key_start..i];
            i += 1; // '=' 소비
            if (i < line.len and line[i] == '"') {
                i += 1;
                const vs = i;
                while (i < line.len and line[i] != '"') {
                    i += if (line[i] == '\\') 2 else 1; // escape 다음 1바이트 건너뜀(닫는 따옴표가 \" 를 안 오인하게)
                }
                if (i >= line.len) return error.BadLine; // 닫는 따옴표 없음(escape가 끝을 넘어가도 여기서 걸림)
                try list.append(a, .{ .key = key, .raw = line[vs..i], .is_quoted = true });
                i += 1; // 닫는 따옴표 소비
            } else {
                const vs = i;
                while (i < line.len and line[i] != ' ') i += 1;
                try list.append(a, .{ .key = key, .raw = line[vs..i], .is_quoted = false });
            }
        }
        return .{ .kind = kind, .fields = try list.toOwnedSlice(a) };
    }

    fn find(self: LineFields, key: []const u8) ?Field {
        for (self.fields) |f| if (std.mem.eql(u8, f.key, key)) return f;
        return null;
    }

    fn count(self: LineFields, key: []const u8) usize {
        var result: usize = 0;
        for (self.fields) |f| if (std.mem.eql(u8, f.key, key)) {
            result += 1;
        };
        return result;
    }

    /// 스칼라 정수 속성: 있으면 파싱(quoted면 BadLine·garbage면 BadLine — 있는데 깨졌으면 조용히 기본값 금지), 없으면 default.
    fn getUint(self: LineFields, key: []const u8, comptime T: type, default: T) ParseError!T {
        const f = self.find(key) orelse return default;
        if (f.is_quoted) return error.BadLine;
        return std.fmt.parseInt(T, f.raw, 10) catch error.BadLine;
    }

    /// 스칼라 부호 정수 속성(음수 가능 — 전역 스크린 좌표 win-x/y 등): 있으면 파싱(quoted면 BadLine·garbage면 BadLine —
    /// 있는데 깨졌으면 조용히 기본값 금지), 없으면 default. getUint와 같은 실패 모델이되 signed T(std.fmt.parseInt가
    /// 선행 `-`를 해석)라 음수 좌표를 안전히 읽는다. M3f 창 frame(win-x/y/w/h)이 첫 signed 필드다.
    fn getInt(self: LineFields, key: []const u8, comptime T: type, default: T) ParseError!T {
        const f = self.find(key) orelse return default;
        if (f.is_quoted) return error.BadLine;
        return std.fmt.parseInt(T, f.raw, 10) catch error.BadLine;
    }

    /// 구조 정수 키(개수 등): 없으면 BadLine(loud-fail — 기본값으로 못 때움).
    fn requireUint(self: LineFields, key: []const u8, comptime T: type) ParseError!T {
        const f = self.find(key) orelse return error.BadLine;
        if (f.is_quoted) return error.BadLine;
        return std.fmt.parseInt(T, f.raw, 10) catch error.BadLine;
    }

    /// 스칼라 따옴표 속성: 있으면 escape 해제해 arena dup, 없으면 default(호출자 리터럴 — arena가 통째 소유하므로 정적 슬라이스도 안전).
    fn getQuoted(self: LineFields, a: std.mem.Allocator, key: []const u8, default: []const u8) ParseError![]const u8 {
        const f = self.find(key) orelse return default;
        if (!f.is_quoted) return error.BadLine;
        return unescapeQuoted(a, f.raw);
    }
};

test "workspace serialize: 단일 창/탭/pane/surface" {
    const surfaces = [_]Surface{
        .{ .title = "app shell", .cwd = "/home/user/proj", .command = "/bin/zsh", .cols = 80, .rows = 24 },
    };
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .custom_name = "work", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .active_tab = 0, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "maru.workspace.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=1 active-pane=0 custom-name=\"work\" pinned=0 background-color=0 accent-color=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pane surfaces=1 active-term=0 custom-name=\"\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface custom-name=\"\" title=\"app shell\" cwd=\"/home/user/proj\" command=\"/bin/zsh\" cols=80 rows=24\n") != null);
}

test "workspace: 저장소별 비교 기준이 왕복한다 (§3.5 P7b)" {
    const surfaces = [_]Surface{.{ .cwd = "/repo/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .tree = &tree, .panes = &panes }};
    const bases = [_]ScmBase{
        .{ .repo = "/repo/a", .base = "origin/main" },
        .{ .repo = "/repo/b", .base = "release-1.2.x" },
    };
    const windows = [_]Window{.{ .active_tab = 0, .scm_bases = &bases, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "scm-bases=\"2:7:/repo/a11:origin/main7:/repo/b13:release-1.2.x\"") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const got = parsed.workspace.windows[0].scm_bases;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/repo/a", got[0].repo);
    try std.testing.expectEqualStrings("origin/main", got[0].base);
    try std.testing.expectEqualStrings("/repo/b", got[1].repo);
    try std.testing.expectEqualStrings("release-1.2.x", got[1].base);
}

test "workspace: 따옴표·공백·한글이 든 저장소 경로도 왕복한다 (§3.5 P7b)" {
    // 길이 접두는 **디코딩된 바이트 수**를 세고, escape는 그보다 길게 쓰인다. 그 둘이 어긋나면
    // 이어지는 항목의 시작이 밀려 목록 전체가 조용히 깨진다(탐색기 root와 같은 커서를 쓰는 이유다).
    const surfaces = [_]Surface{.{ .cwd = "/repo", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .tree = &tree, .panes = &panes }};
    const tricky = "/Users/한글/my \"repo\" dir";
    const bases = [_]ScmBase{
        .{ .repo = tricky, .base = "origin/main" },
        .{ .repo = "/plain", .base = "main" },
    };
    const windows = [_]Window{.{ .active_tab = 0, .scm_bases = &bases, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const got = parsed.workspace.windows[0].scm_bases;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings(tricky, got[0].repo);
    try std.testing.expectEqualStrings("origin/main", got[0].base);
    // **뒤 항목까지 온전해야 한다** — 앞 항목의 길이가 밀렸다면 여기서 드러난다.
    try std.testing.expectEqualStrings("/plain", got[1].repo);
    try std.testing.expectEqualStrings("main", got[1].base);
}

test "workspace: 기준이 없으면 그 키를 아예 안 쓴다 (옛 리더가 모르는 키를 안 만난다)" {
    const surfaces = [_]Surface{.{ .cwd = "/repo/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .active_tab = 0, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "scm-bases") == null);
}

test "workspace: 이상한 기준은 **목록 전체**를 버린다(부분 복원을 안 만든다)" {
    // 부분 복원은 "어떤 저장소는 기억됐고 어떤 것은 아니다"를 만드는데, 사용자에게 그 둘은
    // 구별되지 않는다(둘 다 그냥 기본값으로 보인다). 그리고 이 값의 다음 정거장은 git argv다.
    const base_line = "maru.workspace.v1\nwindow tabs=1 active-tab=0";
    const tail = "\ntab panes=1 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node leaf pane=0\npane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/repo/a\" command=\"/bin/zsh\" cols=80 rows=24\n";

    const cases = [_][]const u8{
        " scm-bases=\"1:7:/repo/a15:--upload-pack=x\"", // 옵션 주입
        " scm-bases=\"1:7:/repo/a4:a..b\"", // 우리가 붙이는 `...HEAD`와 합쳐져 다른 범위가 된다
        " scm-bases=\"1:6:repo/a11:origin/main\"", // 상대 경로 — 어느 저장소인지 알 수 없다
        " scm-bases=\"2:7:/repo/a11:origin/main7:/repo/a4:main\"", // 같은 저장소가 둘
        " scm-bases=\"1:7:/repo/a0:\"", // 빈 기준
    };
    for (cases) |bad| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ base_line, bad, tail });
        defer std.testing.allocator.free(text);
        var parsed = try parse(std.testing.allocator, text);
        defer parsed.deinit();
        // 창은 살아 있고 기억만 사라진다 — 사용자는 기본값 화면을 보고 다시 고르면 된다.
        try std.testing.expectEqual(@as(usize, 1), parsed.workspace.windows.len);
        try std.testing.expectEqual(@as(usize, 0), parsed.workspace.windows[0].scm_bases.len);
    }
}

test "workspace: 저장 쪽도 같은 검사를 건다(못 실을 값이면 저장을 거절한다)" {
    const surfaces = [_]Surface{.{ .cwd = "/repo/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .tree = &tree, .panes = &panes }};
    const bad = [_]ScmBase{.{ .repo = "/repo/a", .base = "--upload-pack=x" }};
    const windows = [_]Window{.{ .active_tab = 0, .scm_bases = &bad, .tabs = &tabs }};
    try std.testing.expectError(error.InvalidScmBases, serialize(std.testing.allocator, .{ .windows = &windows }));
}

test "workspace serialize: split 트리(중첩) + 멀티 pane" {
    // split horizontal { split vertical { leaf0, leaf1 }, leaf2 } — preorder 5노드, 3 panes.
    const s0 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 24 }};
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes = [_]Pane{
        .{ .surfaces = &s0 },
        .{ .surfaces = &s1 },
        .{ .surfaces = &s2 },
    };
    const tree = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs = [_]Tab{.{ .active_pane = 2, .custom_name = "split", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=3 active-pane=2 custom-name=\"split\" pinned=0 background-color=0 accent-color=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split horizontal ratio=500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split vertical ratio=300\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=2\n") != null);
}

test "workspace serialize: 멀티 창 + cwd/title escape" {
    // 따옴표·공백·개행이 섞인 cwd/title이 한 줄·한 토큰으로 escape돼야 한다.
    const s = [_]Surface{.{ .title = "a \"b\"", .cwd = "/tmp/x y\n", .command = "/bin/zsh", .cols = 10, .rows = 5 }};
    const panes = [_]Pane{.{ .surfaces = &s }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tab = Tab{ .tree = &tree, .panes = &panes };
    const tabs0 = [_]Tab{tab};
    const tabs1 = [_]Tab{tab};
    const windows = [_]Window{ .{ .tabs = &tabs0 }, .{ .tabs = &tabs1 } };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    // window 라인이 두 번(멀티 창).
    var it = std.mem.splitScalar(u8, text, '\n');
    var window_lines: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "window ")) window_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), window_lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface custom-name=\"\" title=\"a \\\"b\\\"\" cwd=\"/tmp/x y\\n\" command=\"/bin/zsh\" cols=10 rows=5\n") != null);
}

test "workspace round-trip: serialize → parse → 다시 serialize 동일(중첩 split·멀티 창·escape)" {
    // 복잡한 모델(멀티 창, 중첩 split, escape 필요한 cwd/title)을 직렬화한 뒤 되읽고 다시 직렬화하면 동일해야 한다.
    const s0 = [_]Surface{ .{ .title = "a \"b\"", .cwd = "/tmp/x y", .command = "/bin/zsh", .cols = 40, .rows = 24 }, .{ .cwd = "/var\nlog", .command = "/bin/bash", .cols = 40, .rows = 24 } };
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes0 = [_]Pane{ .{ .active_term = 1, .surfaces = &s0 }, .{ .surfaces = &s1 }, .{ .surfaces = &s2 } };
    const tree0 = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs0 = [_]Tab{.{ .active_pane = 2, .custom_name = "split", .tree = &tree0, .panes = &panes0 }};

    const sA = [_]Surface{.{ .title = "w2", .cwd = "/home", .command = "/bin/zsh", .cols = 100, .rows = 30 }};
    const panes1 = [_]Pane{.{ .surfaces = &sA }};
    const tree1 = [_]TreeNode{.{ .leaf = 0 }};
    const tabs1 = [_]Tab{.{ .custom_name = "single", .tree = &tree1, .panes = &panes1 }};

    const windows = [_]Window{ .{ .active_tab = 0, .tabs = &tabs0 }, .{ .active_tab = 0, .tabs = &tabs1 } };

    const text1 = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text1);

    var parsed = try parse(std.testing.allocator, text1);
    defer parsed.deinit();

    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2); // writer↔reader 고정점
}

test "workspace round-trip: surface runtime-handle은 host와 runtime identity를 함께 보존한다" {
    // host-backed Term은 host_id + runtime_id를 한 handle로 저장한다. runtime_id 단독으로는 host 재시작 뒤 다른
    // namespace를 같은 세션으로 오인할 수 있으므로 새 writer는 절대 bare runtime-id를 만들지 않는다.
    const hid = "fedcba9876543210fedcba9876543210";
    const rid = "0123456789abcdef0123456789abcdef";
    const surfs = [_]Surface{
        .{ .command = "/bin/zsh", .runtime_host_id = hid, .runtime_id = rid, .cols = 40, .rows = 24 }, // host-backed
        .{ .command = "/bin/zsh", .cols = 40, .rows = 24 }, // in-process(runtime_id="")
    };
    const panes = [_]Pane{.{ .surfaces = &surfs }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .active_tab = 0, .tabs = &tabs }};

    const text1 = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text1);
    try std.testing.expect(std.mem.indexOf(u8, text1, "runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text1, " runtime-id=") == null);

    var parsed = try parse(std.testing.allocator, text1);
    defer parsed.deinit();
    const rs = parsed.workspace.windows[0].tabs[0].panes[0].surfaces;
    try std.testing.expectEqualStrings(hid, rs[0].runtime_host_id);
    try std.testing.expectEqualStrings(rid, rs[0].runtime_id);
    try std.testing.expectEqualStrings("", rs[1].runtime_host_id);
    try std.testing.expectEqualStrings("", rs[1].runtime_id); // in-process는 "" (키 생략 → 기본)

    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2); // 고정점
}

test "workspace round-trip: durable ended tombstone은 exact handle과 state를 보존한다" {
    const hid = "fedcba9876543210fedcba9876543210";
    const rid = "0123456789abcdef0123456789abcdef";
    const surfaces = [_]Surface{.{
        .title = "ended",
        .command = "/bin/zsh",
        .runtime_host_id = hid,
        .runtime_id = rid,
        .runtime_state = .ended,
        .cols = 80,
        .rows = 24,
    }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-state=\"ended\"",
    ) != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const round = parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0];
    try std.testing.expectEqual(RuntimeState.ended, round.runtime_state);
    try std.testing.expectEqualStrings(hid, round.runtime_host_id);
    try std.testing.expectEqualStrings(rid, round.runtime_id);
}

test "workspace binding validator: 같은 full handle의 live/ended owner를 창 전체에서 거부한다" {
    const hid = "fedcba9876543210fedcba9876543210";
    const rid = "0123456789abcdef0123456789abcdef";
    const surfaces0 = [_]Surface{.{
        .runtime_host_id = hid,
        .runtime_id = rid,
        .cols = 80,
        .rows = 24,
    }};
    const surfaces1 = [_]Surface{.{
        .runtime_host_id = hid,
        .runtime_id = rid,
        .runtime_state = .ended,
        .cols = 80,
        .rows = 24,
    }};
    const panes0 = [_]Pane{.{ .surfaces = &surfaces0 }};
    const panes1 = [_]Pane{.{ .surfaces = &surfaces1 }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs0 = [_]Tab{.{ .tree = &tree, .panes = &panes0 }};
    const tabs1 = [_]Tab{.{ .tree = &tree, .panes = &panes1 }};
    const windows = [_]Window{ .{ .tabs = &tabs0 }, .{ .tabs = &tabs1 } };

    try std.testing.expectError(
        error.DuplicateRuntimeBinding,
        serialize(std.testing.allocator, .{ .windows = &windows }),
    );
}

test "workspace binding validator: legacy bare ID의 full/bare 모호한 중복은 거부하고 distinct full host는 허용한다" {
    const rid = "0123456789abcdef0123456789abcdef";
    const tree = [_]TreeNode{.{ .leaf = 0 }};

    const distinct_surfaces = [_]Surface{
        .{ .runtime_host_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .runtime_id = rid, .cols = 80, .rows = 24 },
        .{ .runtime_host_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .runtime_id = rid, .cols = 80, .rows = 24 },
    };
    const distinct_pane = [_]Pane{.{ .surfaces = &distinct_surfaces }};
    const distinct_tabs = [_]Tab{.{ .tree = &tree, .panes = &distinct_pane }};
    const distinct_windows = [_]Window{.{ .tabs = &distinct_tabs }};
    const text = try serialize(std.testing.allocator, .{ .windows = &distinct_windows });
    defer std.testing.allocator.free(text);

    const ambiguous_surfaces = [_]Surface{
        .{ .runtime_host_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .runtime_id = rid, .cols = 80, .rows = 24 },
        .{ .runtime_id = rid, .cols = 80, .rows = 24 },
    };
    const ambiguous_pane = [_]Pane{.{ .surfaces = &ambiguous_surfaces }};
    const ambiguous_tabs = [_]Tab{.{ .tree = &tree, .panes = &ambiguous_pane }};
    const ambiguous_windows = [_]Window{.{ .tabs = &ambiguous_tabs }};
    try std.testing.expectError(
        error.DuplicateRuntimeBinding,
        serialize(std.testing.allocator, .{ .windows = &ambiguous_windows }),
    );

    const reverse_surfaces = [_]Surface{
        .{ .runtime_id = rid, .cols = 80, .rows = 24 },
        .{ .runtime_host_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .runtime_id = rid, .cols = 80, .rows = 24 },
    };
    const reverse_pane = [_]Pane{.{ .surfaces = &reverse_surfaces }};
    const reverse_tabs = [_]Tab{.{ .tree = &tree, .panes = &reverse_pane }};
    const reverse_windows = [_]Window{.{ .tabs = &reverse_tabs }};
    try std.testing.expectError(
        error.DuplicateRuntimeBinding,
        serialize(std.testing.allocator, .{ .windows = &reverse_windows }),
    );

    const bare_surfaces = [_]Surface{
        .{ .runtime_id = rid, .cols = 80, .rows = 24 },
        .{ .runtime_id = rid, .cols = 80, .rows = 24 },
    };
    const bare_pane = [_]Pane{.{ .surfaces = &bare_surfaces }};
    const bare_tabs = [_]Tab{.{ .tree = &tree, .panes = &bare_pane }};
    const bare_windows = [_]Window{.{ .tabs = &bare_tabs }};
    try std.testing.expectError(
        error.DuplicateRuntimeBinding,
        serialize(std.testing.allocator, .{ .windows = &bare_windows }),
    );
}

test "workspace binding validator: exact cap과 cap+1이 semantic preflight 작업량을 제한한다" {
    const allocator = std.testing.allocator;
    const count = max_runtime_bindings + 1;
    const ids = try allocator.alloc([32]u8, count);
    defer allocator.free(ids);
    const surfaces = try allocator.alloc(Surface, count);
    defer allocator.free(surfaces);
    for (ids, surfaces, 0..) |*id, *surface, i| {
        @memset(id, '0');
        _ = try std.fmt.bufPrint(id[24..32], "{x:0>8}", .{i + 1});
        surface.* = .{
            .runtime_host_id = "fedcba9876543210fedcba9876543210",
            .runtime_id = id,
            .cols = 80,
            .rows = 24,
        };
    }
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    var pane = [_]Pane{.{ .surfaces = surfaces[0..max_runtime_bindings] }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &pane }};
    const windows = [_]Window{.{ .tabs = &tabs }};
    try validateRuntimeBindings(allocator, .{ .windows = &windows });
    pane[0].surfaces = surfaces;
    try std.testing.expectError(
        error.TooManyRuntimeBindings,
        validateRuntimeBindings(allocator, .{ .windows = &windows }),
    );
}

test "workspace parse: persistent binding wire cap은 exact 4096을 허용하고 4097을 BadLine으로 거부한다" {
    const allocator = std.testing.allocator;
    for ([_]usize{ max_runtime_bindings, max_runtime_bindings + 1 }) |count| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print(
            "{s}\n" ++
                "window active-tab=0 tabs=1\n" ++
                "tab active-pane=0 tree-nodes=1 panes=1 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
                "tree-node leaf pane=0\n" ++
                "pane surfaces={d} active-term=0 custom-name=\"\"\n",
            .{ header, count },
        );
        for (0..count) |i| {
            try out.writer.print(
                "surface runtime-handle=\"fedcba9876543210fedcba9876543210:000000000000000000000000{x:0>8}\" cols=80 rows=24\n",
                .{i + 1},
            );
        }
        const text = out.writer.buffered();
        if (count == max_runtime_bindings) {
            var parsed = try parse(allocator, text);
            parsed.deinit();
        } else {
            try std.testing.expectError(error.BadLine, parse(allocator, text));
        }
    }
}

test "workspace binding validator: allocation failure와 invalid model은 leak이나 고정 길이 copy panic이 없다" {
    const hid = "fedcba9876543210fedcba9876543210";
    const rid = "0123456789abcdef0123456789abcdef";
    const surfaces = [_]Surface{
        .{ .runtime_id = "11111111111111111111111111111111" },
        .{ .runtime_host_id = hid, .runtime_id = rid },
        .{ .runtime_host_id = hid, .runtime_id = rid },
    };
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};
    var saw_duplicate = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        validateRuntimeBindings(failing.allocator(), .{ .windows = &windows }) catch |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expect(failing.has_induced_failure);
                continue;
            },
            error.DuplicateRuntimeBinding => {
                saw_duplicate = true;
                break;
            },
            error.TooManyRuntimeBindings => return error.TestUnexpectedResult,
        };
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(saw_duplicate);

    const invalid = [_]Surface{
        .{ .runtime_host_id = hid, .runtime_id = "short" },
        .{ .runtime_host_id = "too-short", .runtime_id = rid },
    };
    const invalid_panes = [_]Pane{.{ .surfaces = &invalid }};
    const invalid_tabs = [_]Tab{.{ .tree = &tree, .panes = &invalid_panes }};
    const invalid_windows = [_]Window{.{ .tabs = &invalid_tabs }};
    try validateRuntimeBindings(std.testing.allocator, .{ .windows = &invalid_windows });
    try std.testing.expectError(
        error.InvalidRuntimeIdentity,
        serialize(std.testing.allocator, .{ .windows = &invalid_windows }),
    );
}

test "workspace parse: 전역 duplicate runtime binding은 어떤 소비자 publish 전 BadLine이다" {
    const text =
        \\maru.workspace.v1
        \\window active-tab=0 tabs=1
        \\tab active-pane=0 tree-nodes=1 panes=1 custom-name="" pinned=0 background-color=0 accent-color=0
        \\tree-node leaf pane=0
        \\pane surfaces=1 active-term=0 custom-name=""
        \\surface custom-name="" title="" cwd="" command="" runtime-handle="fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef" cols=80 rows=24
        \\window active-tab=0 tabs=1
        \\tab active-pane=0 tree-nodes=1 panes=1 custom-name="" pinned=0 background-color=0 accent-color=0
        \\tree-node leaf pane=0
        \\pane surfaces=1 active-term=0 custom-name=""
        \\surface custom-name="" title="" cwd="" command="" runtime-handle="fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef" runtime-state="ended" cols=80 rows=24
        \\
    ;
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, text));
}

test "workspace parse: legacy bare runtime-id는 읽되 다음 저장에서 handle로 위조하지 않는다" {
    const text =
        \\maru.workspace.v1
        \\window active-tab=0 tabs=1 dock-side=right dock-tree-size=256
        \\tab active-pane=0 tree-nodes=1 panes=1 custom-name="" pinned=0 background-color=0 accent-color=0
        \\tree-node leaf pane=0
        \\pane surfaces=1 active-term=0 custom-name=""
        \\surface custom-name="" title="" cwd="" command="/bin/zsh" runtime-id="0123456789abcdef0123456789abcdef" cols=80 rows=24
        \\
    ;
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const surface = parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0];
    try std.testing.expectEqualStrings("", surface.runtime_host_id);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", surface.runtime_id);
}

test "workspace parse: ambiguous or malformed persistent runtime identity fails closed" {
    const prefix =
        \\maru.workspace.v1
        \\window active-tab=0 tabs=1 dock-side=right dock-tree-size=256
        \\tab active-pane=0 tree-nodes=1 panes=1 custom-name="" pinned=0 background-color=0 accent-color=0
        \\tree-node leaf pane=0
        \\pane surfaces=1 active-term=0 custom-name=""
    ;
    const suffix = "\n";
    const invalid = [_][]const u8{
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdeF\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210-0123456789abcdef0123456789abcdef\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-id=\"0123456789abcdef0123456789abcdef\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-state=\"ended\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-id=\"0123456789abcdef0123456789abcdef\" runtime-state=\"ended\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-state=\"live\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-state=ended cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-id=\"0123456789abcdef0123456789abcdef\" runtime-id=\"fedcba9876543210fedcba9876543210\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-handle=\"bad\" cols=80 rows=24",
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" runtime-handle=\"fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef\" runtime-state=\"ended\" runtime-state=\"live\" cols=80 rows=24",
    };
    for (invalid) |surface_line| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "\n", surface_line, suffix });
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.BadLine, parse(std.testing.allocator, text));
    }
}

test "workspace round-trip: tab pinned·background_color·accent_color 보존" {
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .custom_name = "work", .pinned = true, .background_color = 0xDDA15E, .accent_color = 0x4A7BC4, .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pinned=1 background-color=14524766 accent-color=4881348\n") != null); // 0xDDA15E=14524766, 0x4A7BC4=4881348

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const tab = parsed.workspace.windows[0].tabs[0];
    try std.testing.expectEqual(true, tab.pinned);
    try std.testing.expectEqual(@as(u32, 0xDDA15E), tab.background_color);
    try std.testing.expectEqual(@as(u32, 0x4A7BC4), tab.accent_color);
}

test "workspace round-trip: tab group_start·group_collapsed 보존(위치 파생 그룹 마커)" {
    // 위치 파생 그룹(docs/sidebar-groups.md §2.1): 탭0이 "frontend" 그룹을 시작(접힘)하고, 탭1은 마커가 없어
    // 소속을 순서에서 파생한다(frontend에 속함). writer는 **그룹 시작 탭만** group-start=/group-collapsed=를
    // 내고, 마커 없는 탭은 키를 생략한다(null=그룹 아님). round-trip이 이 인코딩(null↔키부재)을 고정하는지 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{
        .{ .custom_name = "web", .group_start = "frontend", .group_collapsed = true, .tree = &tree, .panes = &panes },
        .{ .custom_name = "docs", .tree = &tree, .panes = &panes }, // 마커 없음 → null(위치 파생 소속)
    };
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 그룹 시작 탭(web)만 group-start/group-collapsed를 낸다.
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"web\" pinned=0 background-color=0 accent-color=0 group-start=\"frontend\" group-collapsed=1\n") != null);
    // 마커 없는 탭(docs)은 accent-color=0 바로 뒤 개행 — group-start 키가 안 붙는다.
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"docs\" pinned=0 background-color=0 accent-color=0\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const t0 = parsed.workspace.windows[0].tabs[0];
    const t1 = parsed.workspace.windows[0].tabs[1];
    try std.testing.expect(t0.group_start != null);
    try std.testing.expectEqualStrings("frontend", t0.group_start.?);
    try std.testing.expectEqual(true, t0.group_collapsed);
    try std.testing.expectEqual(@as(?[]const u8, null), t1.group_start); // 마커 없는 탭 = null
    try std.testing.expectEqual(false, t1.group_collapsed);

    // round-trip 고정점: 다시 직렬화하면 동일(null↔키부재 인코딩이 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: tab group_color 보존(SG5-2 — 비영은 group-color 키, 0은 키 생략)" {
    // 그룹 공통 색(docs/plans/sidebar-groups.md §9 SG5-2): 그룹 시작 탭에만 group_color를 저장하고, 소속 카드는 위치
    // 파생으로 그 색을 따른다(별도 저장 없음). writer는 비영 group-color만 쓰고(0=키 생략, additive), 색 없는
    // 그룹/무색 탭 라인은 안 바꾼다. round-trip이 이 인코딩(0↔키부재·비영↔키존재)을 고정하는지 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{
        // 색 있는 그룹(파랑 0x4A7BC4=4881348) — group-color 키가 group-collapsed 뒤에 붙는다.
        .{ .custom_name = "web", .group_start = "frontend", .group_collapsed = false, .group_color = 0x4A7BC4, .tree = &tree, .panes = &panes },
        // 소속 카드(마커 없음) — group_color를 저장하지 않는다(위치 파생). 무색이라 group-color 키 없음.
        .{ .custom_name = "docs", .tree = &tree, .panes = &panes },
        // 색 없는 그룹(group_color=0) — group-color 키 생략(round-trip 고정점, 라인 안 바뀜).
        .{ .custom_name = "infra", .group_start = "backend", .group_collapsed = false, .tree = &tree, .panes = &panes },
    };
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 색 있는 그룹: group-collapsed 뒤에 group-color=4881348.
    try std.testing.expect(std.mem.indexOf(u8, text, "group-start=\"frontend\" group-collapsed=0 group-color=4881348\n") != null);
    // 색 없는 그룹: group-collapsed=0 바로 뒤 개행(group-color 키 없음).
    try std.testing.expect(std.mem.indexOf(u8, text, "group-start=\"backend\" group-collapsed=0\n") != null);
    // 소속 카드(docs)에는 group-color가 안 붙는다(그룹 시작 아님).
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"docs\" pinned=0 background-color=0 accent-color=0\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const t0 = parsed.workspace.windows[0].tabs[0];
    const t1 = parsed.workspace.windows[0].tabs[1];
    const t2 = parsed.workspace.windows[0].tabs[2];
    try std.testing.expectEqual(@as(u32, 0x4A7BC4), t0.group_color); // 색 복원
    try std.testing.expectEqual(@as(u32, 0), t1.group_color); // 소속 카드 = 0(위치 파생, 저장 안 함)
    try std.testing.expectEqual(@as(u32, 0), t2.group_color); // 색 없는 그룹 = 0(키 생략 → 기본)

    // round-trip 고정점: 다시 직렬화하면 동일(0↔키부재·비영↔키존재 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: tab group_depth 보존(SG5-3 중첩 — >1은 group-depth 키, 1은 키 생략)" {
    // 중첩 그룹 깊이(docs/plans/sidebar-groups.md §9 SG5-3): 마커 탭에만 group_depth를 저장하고(1=최상위 그룹, 2=중첩, …),
    // 소속은 위치 파생이 정한다. writer는 >1일 때만 group-depth 키를 쓰고(1=키 생략, additive), 옛 파일/비중첩 그룹의
    // 라인을 안 바꾼다. round-trip이 이 인코딩(1↔키부재·>1↔키존재)을 고정하는지 + 하위호환(없으면 1)을 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{
        // 부모 그룹 A(depth 1) — group-depth 키 생략(기본 1).
        .{ .custom_name = "A", .group_start = "parent", .group_collapsed = false, .tree = &tree, .panes = &panes },
        // 중첩 자식 그룹 B(depth 2) — group-depth=2 키가 group-collapsed 뒤에 붙는다.
        .{ .custom_name = "B", .group_start = "child", .group_collapsed = false, .group_depth = 2, .tree = &tree, .panes = &panes },
        // 소속 카드(마커 없음) — group_depth 미저장(위치 파생).
        .{ .custom_name = "c", .tree = &tree, .panes = &panes },
    };
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 부모(depth 1): group-collapsed=0 바로 뒤 개행(group-depth 키 없음).
    try std.testing.expect(std.mem.indexOf(u8, text, "group-start=\"parent\" group-collapsed=0\n") != null);
    // 자식(depth 2): group-collapsed 뒤에 group-depth=2.
    try std.testing.expect(std.mem.indexOf(u8, text, "group-start=\"child\" group-collapsed=0 group-depth=2\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const t0 = parsed.workspace.windows[0].tabs[0];
    const t1 = parsed.workspace.windows[0].tabs[1];
    const t2 = parsed.workspace.windows[0].tabs[2];
    try std.testing.expectEqual(@as(u8, 1), t0.group_depth); // 부모 = 1(키 생략 → 기본)
    try std.testing.expectEqual(@as(u8, 2), t1.group_depth); // 자식 중첩 = 2 복원
    try std.testing.expectEqual(@as(u8, 1), t2.group_depth); // 소속 카드 = 1(무의미·기본)

    // round-trip 고정점: 다시 직렬화하면 동일(1↔키부재·>1↔키존재 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: tab local_pinned 보존(GL §13 — true는 local-pinned 키, false는 키 생략)" {
    // 그룹-로컬 pin(docs/sidebar-groups-pinning.md §13): 그룹 안 leaf 멤버가 subtree 안에서 위로 고정됐는가. 전역 pinned와
    // 직교하는 별개 축이라 group_start와 무관하게(멤버 카드에) 실린다. writer는 true만 쓰고(false=키 생략, additive),
    // 옛 파일/비-로컬-pin 카드 라인은 안 바꾼다. round-trip이 이 인코딩(false↔키부재·true↔키존재)을 고정하는지 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{
        // 그룹 마커(frontend) — 마커 자신은 로컬 pin 무의미(멤버 전용). local_pinned=false라 키 없음.
        .{ .custom_name = "web", .group_start = "frontend", .group_collapsed = false, .tree = &tree, .panes = &panes },
        // 로컬 pin된 소속 멤버 카드 — local-pinned=1 키가 accent-color 뒤(그룹 블록 밖)에 붙는다.
        .{ .custom_name = "docs", .local_pinned = true, .tree = &tree, .panes = &panes },
        // 비-로컬-pin 멤버 카드 — local-pinned 키 생략(round-trip 고정점, 라인 안 바뀜).
        .{ .custom_name = "api", .tree = &tree, .panes = &panes },
    };
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 로컬 pin 멤버(docs): accent-color=0 바로 뒤에 local-pinned=1(그룹 마커가 아니라 group-* 키가 안 붙는다).
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"docs\" pinned=0 background-color=0 accent-color=0 local-pinned=1\n") != null);
    // 비-로컬-pin 멤버(api): accent-color=0 바로 뒤 개행(local-pinned 키 없음).
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"api\" pinned=0 background-color=0 accent-color=0\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const t0 = parsed.workspace.windows[0].tabs[0];
    const t1 = parsed.workspace.windows[0].tabs[1];
    const t2 = parsed.workspace.windows[0].tabs[2];
    try std.testing.expectEqual(false, t0.local_pinned); // 마커 = false(키 생략 → 기본)
    try std.testing.expectEqual(true, t1.local_pinned); // 로컬 pin 멤버 복원
    try std.testing.expectEqual(false, t2.local_pinned); // 비-pin 멤버 = false(키 생략 → 기본)

    // round-trip 고정점: 다시 직렬화하면 동일(false↔키부재·true↔키존재 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: tab top_level 보존(§2.1 재설계 §14 — true는 top-level 키, false는 키 생략)" {
    // §2.1 재설계 서브파티션 마커(docs/sidebar-groups-top-level.md §14): 한 핀 리전 안에서 이 카드부터 최상위(depth 0) 복귀.
    // 전역 pinned·group_start와 직교하는 리딩 break 스칼라라 group 블록 밖에 실린다. writer는 true만 쓰고(false=키 생략,
    // additive), 옛 파일/비-top 카드 라인은 안 바꾼다. round-trip이 이 인코딩(false↔키부재·true↔키존재)을 고정하는지 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{
        // 그룹 마커(frontend) — 마커는 top_level 무의미(비마커 leaf 전용). top_level=false라 키 없음.
        .{ .custom_name = "web", .group_start = "frontend", .group_collapsed = false, .tree = &tree, .panes = &panes },
        // 그룹 멤버(top_level 없음) — top-level 키 생략(round-trip 고정점).
        .{ .custom_name = "docs", .tree = &tree, .panes = &panes },
        // 그룹 뒤 최상위 복귀 카드 — top-level=1 키가 accent-color 뒤(그룹 블록 밖)에 붙는다.
        .{ .custom_name = "top", .top_level = true, .tree = &tree, .panes = &panes },
    };
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // top-level 카드(top): accent-color=0 바로 뒤에 top-level=1(그룹 마커가 아니라 group-* 키가 안 붙는다).
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"top\" pinned=0 background-color=0 accent-color=0 top-level=1\n") != null);
    // 비-top 멤버(docs): accent-color=0 바로 뒤 개행(top-level 키 없음).
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-name=\"docs\" pinned=0 background-color=0 accent-color=0\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const t0 = parsed.workspace.windows[0].tabs[0];
    const t1 = parsed.workspace.windows[0].tabs[1];
    const t2 = parsed.workspace.windows[0].tabs[2];
    try std.testing.expectEqual(false, t0.top_level); // 마커 = false(키 생략 → 기본)
    try std.testing.expectEqual(false, t1.top_level); // 비-top 멤버 = false(키 생략 → 기본)
    try std.testing.expectEqual(true, t2.top_level); // 최상위 복귀 카드 복원

    // round-trip 고정점: 다시 직렬화하면 동일(false↔키부재·true↔키존재 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: window active(활성 창) 마커 보존(M3e — true는 active-window 키, false는 키 생략)" {
    // 재시작 시 다시 focus할 활성(key) 창 마커(docs/window-surface-mobility.md §8A.8). group-collapsed 옵션-키 패턴
    // 그대로: writer는 active=true인 창만 active-window=1을 내고(false=키 생략, additive), 옛 파일/비활성 창 라인은
    // 안 바꾼다. round-trip이 이 인코딩(false↔키부재·true↔키존재)을 고정하는지 + activeWindowIndex를 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs0 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const tabs1 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    // 창0=비활성(마커 없음), 창1=활성(active-window=1).
    const windows = [_]Window{
        .{ .tabs = &tabs0 },
        .{ .active = true, .tabs = &tabs1 },
    };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 창0(비활성): active-tab=0 바로 뒤 개행(active-window 키 없음 — group-collapsed와 동일 생략).
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0\n") != null);
    // 창1(활성): active-tab 뒤에 active-window=1.
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0 active-window=1\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.workspace.windows[0].active);
    try std.testing.expectEqual(true, parsed.workspace.windows[1].active);
    try std.testing.expectEqual(@as(?usize, 1), activeWindowIndex(parsed.workspace)); // 활성 = 창1

    // round-trip 고정점: 다시 직렬화하면 동일(false↔키부재·true↔키존재 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace serialize: active=false 창은 active-window 키 생략(옛 파일 flat 고정점)" {
    // 모든 창이 비활성(기본)이면 active-window 키가 어디에도 안 붙어, 옛(M3e 이전) 저장 파일과 라인이 byte-identical하다
    // (additive 옵션-키 = false 생략). 이게 "필드 추가 전후 라인 문자열 불변" 계약 — activeWindowIndex는 null(활성 없음).
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{ .{ .tabs = &tabs }, .{ .tabs = &tabs } };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "active-window") == null); // 어디에도 없음
    try std.testing.expectEqual(@as(?usize, null), activeWindowIndex(.{ .windows = &windows })); // 활성 창 없음 = null
}

test "workspace parse: 옛 v1 파일(active-window 키 없음) 하위호환 — 크래시/BadHeader 없이 active 전부 false" {
    // ⭐ M3e 하위호환의 핵심(사용자가 확인한 "필드 없이 저장 후 버전업 로드 무문제"): active-window 키가 **없는** 옛
    // maru.workspace.v1 텍스트(멀티 창)를 parse해도 헤더 유지(BadHeader 없음)·정상 로드·active 전부 false·
    // activeWindowIndex==null(현행 동작 = 마지막 생성 창 key). 버림·모달·크래시 없음. 배치(창별 cwd)도 그대로 로드.
    const old =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++ // active-window 키 없음(옛 파일)
        "tab panes=1 custom-name=\"w0\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/a\" command=\"/bin/zsh\" cols=80 rows=24\n" ++
        "window tabs=1 active-tab=0\n" ++ // 두 번째 창도 마커 없음
        "tab panes=1 custom-name=\"w1\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/b\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, old); // BadHeader/크래시 없이 성공
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.workspace.windows.len);
    try std.testing.expectEqual(false, parsed.workspace.windows[0].active); // 없음 → 기본 false
    try std.testing.expectEqual(false, parsed.workspace.windows[1].active);
    try std.testing.expectEqual(@as(?usize, null), activeWindowIndex(parsed.workspace)); // 마커 없음 = null(현행 유지)
    try std.testing.expectEqualStrings("/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/b", parsed.workspace.windows[1].tabs[0].panes[0].surfaces[0].cwd);
}

test "workspace round-trip: 멀티 창 배치 + 활성 창 재시작 유지(M3e cross-window 이동 회귀)" {
    // cross-window 이동은 각 세션 라이브 트리를 창별 블록으로 저장하므로 배치(어느 창에 무엇)는 이미 v1으로 재시작 후
    // 유지된다(M3 핵심 목표 충족). M3e는 그 위에 활성 창만 얹는다. 두 창(구분되는 cwd) + 창1 활성을 round-trip해서
    // 배치와 활성 마커가 함께 살아남는지(회귀 없나) 검증.
    const s0 = [_]Surface{.{ .cwd = "/proj/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const s1 = [_]Surface{.{ .cwd = "/proj/b", .command = "/bin/zsh", .cols = 90, .rows = 30 }};
    const p0 = [_]Pane{.{ .surfaces = &s0 }};
    const p1 = [_]Pane{.{ .surfaces = &s1 }};
    const t0 = [_]TreeNode{.{ .leaf = 0 }};
    const t1 = [_]TreeNode{.{ .leaf = 0 }};
    const tabs0 = [_]Tab{.{ .tree = &t0, .panes = &p0 }};
    const tabs1 = [_]Tab{.{ .tree = &t1, .panes = &p1 }};
    const windows = [_]Window{
        .{ .tabs = &tabs0 }, // 창0 비활성
        .{ .active = true, .tabs = &tabs1 }, // 창1 활성
    };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();

    // 배치 유지: 창0=/proj/a, 창1=/proj/b (cross-window placement).
    try std.testing.expectEqual(@as(usize, 2), parsed.workspace.windows.len);
    try std.testing.expectEqualStrings("/proj/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/proj/b", parsed.workspace.windows[1].tabs[0].panes[0].surfaces[0].cwd);
    // 활성 창 유지: 창1.
    try std.testing.expectEqual(@as(?usize, 1), activeWindowIndex(parsed.workspace));

    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: window frame(win-x/y/w/h) 보존(M3f — 전역 좌표·음수 포함)" {
    // 창 픽셀(점) frame(docs/window-surface-mobility.md §8A.8). active-window와 동일한 옵션-키 패턴: frame이 있으면
    // win-x/y/w/h 넷을 방출하고, round-trip이 그 값(음수 x/y = 보조 모니터 포함)을 고정한다. windowFrame 헬퍼도 검증.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs0 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const tabs1 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    // 창0=main 모니터(양수), 창1=왼쪽/아래 보조 모니터(음수 origin) — 전역 좌표가 모니터를 인코딩.
    const windows = [_]Window{
        .{ .frame = .{ .x = 100, .y = 200, .w = 960, .h = 600 }, .tabs = &tabs0 },
        .{ .frame = .{ .x = -1440, .y = -300, .w = 800, .h = 500 }, .tabs = &tabs1 },
    };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 창0: active-tab 뒤에 win-x/y/w/h 넷(양수).
    try std.testing.expect(std.mem.indexOf(u8, text, "win-x=100 win-y=200 win-w=960 win-h=600\n") != null);
    // 창1: 음수 origin도 그대로(부호).
    try std.testing.expect(std.mem.indexOf(u8, text, "win-x=-1440 win-y=-300 win-w=800 win-h=500\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const f0 = parsed.workspace.windows[0].frame.?;
    try std.testing.expectEqual(@as(i32, 100), f0.x);
    try std.testing.expectEqual(@as(i32, 200), f0.y);
    try std.testing.expectEqual(@as(i32, 960), f0.w);
    try std.testing.expectEqual(@as(i32, 600), f0.h);
    const f1 = windowFrame(parsed.workspace, 1).?; // 헬퍼가 창1 frame 반환
    try std.testing.expectEqual(@as(i32, -1440), f1.x);
    try std.testing.expectEqual(@as(i32, -300), f1.y);
    try std.testing.expectEqual(@as(?Frame, null), windowFrame(parsed.workspace, 2)); // index 범위 밖 → null

    // round-trip 고정점: 다시 직렬화하면 동일(음수·부호 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace round-trip: 활성 창 + frame 동시(M3e+M3f — 실 key-창 인코딩·한 줄 둘 다)" {
    // 실제 저장 시 key 창은 active=true AND frame 둘 다 실린다(한 window 라인에 active-window=1과 win-x/y/w/h).
    // 기존 M3e·M3f 테스트는 각각 한 마커만 검증해 이 조합 라인을 안 덮었다([4] 테스트 갭). 둘 다 방출되고(writer 순서=
    // active-window 뒤 win-*), parse가 active·frame 둘 다 복원하고, 재직렬화가 고정점인지 검증한다.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs0 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const tabs1 = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{
        .{ .tabs = &tabs0 }, // 창0 = 비활성·frame 없음
        .{ .active = true, .frame = .{ .x = 100, .y = 200, .w = 960, .h = 600 }, .tabs = &tabs1 }, // 창1 = 활성 AND frame
    };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    // 한 줄에 active-window=1과 win-* 넷이 함께(둘 다 있는 실 key-창 라인).
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0 active-window=1 win-x=100 win-y=200 win-w=960 win-h=600\n") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    // 둘 다 복원: 창1이 활성이고 그 창 frame이 저장값.
    try std.testing.expectEqual(@as(?usize, 1), activeWindowIndex(parsed.workspace));
    try std.testing.expectEqual(true, parsed.workspace.windows[1].active);
    const f1 = parsed.workspace.windows[1].frame.?;
    try std.testing.expectEqual(@as(i32, 100), f1.x);
    try std.testing.expectEqual(@as(i32, 200), f1.y);
    try std.testing.expectEqual(@as(i32, 960), f1.w);
    try std.testing.expectEqual(@as(i32, 600), f1.h);
    // 창0은 둘 다 없음(비활성·frame null) — 옵션-키 생략 유지.
    try std.testing.expectEqual(false, parsed.workspace.windows[0].active);
    try std.testing.expectEqual(@as(?Frame, null), parsed.workspace.windows[0].frame);

    // 재직렬화 고정점(active·frame 동시 인코딩 안정).
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace serialize: frame=null 창은 win-* 키 생략(옛 파일 flat 고정점)" {
    // frame이 null(미저장)이면 win-x/y/w/h 어디에도 안 붙어, 옛(M3f 이전) 저장 파일과 라인이 byte-identical하다
    // (additive 옵션-키 = null 생략). windowFrame은 null. active-window 생략 패턴과 동일한 계약.
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{ .{ .tabs = &tabs }, .{ .tabs = &tabs } }; // frame 기본 null

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "win-x") == null); // 어디에도 없음
    try std.testing.expect(std.mem.indexOf(u8, text, "win-w") == null);
    try std.testing.expectEqual(@as(?Frame, null), windowFrame(.{ .windows = &windows }, 0));

    // round-trip 고정점(null↔키부재).
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?Frame, null), parsed.workspace.windows[0].frame);
    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "workspace parse: 옛 v1 파일(win-* 키 없음) 하위호환 — 크래시/BadHeader 없이 frame 전부 null" {
    // ⭐ M3f 하위호환의 핵심: win-x/y/w/h 키가 **없는** 옛 maru.workspace.v1 텍스트를 parse해도 헤더 유지(BadHeader
    // 없음)·정상 로드·frame 전부 null(복원=cascade 기본 위치). 버림·모달·크래시 없음. 배치(cwd)도 그대로 로드.
    // active-window 마커가 있는(M3e) 파일에도 win-* 없이 정상(M3e만 있고 M3f 없는 중간 버전 파일 하위호환).
    const old =
        header ++ "\n" ++
        "window tabs=1 active-tab=0 active-window=1\n" ++ // M3e 마커만, win-* 없음(M3f 이전 파일)
        "tab panes=1 custom-name=\"w0\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/a\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, old); // BadHeader/크래시 없이 성공
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.workspace.windows.len);
    try std.testing.expectEqual(@as(?Frame, null), parsed.workspace.windows[0].frame); // win-* 없음 → null
    try std.testing.expectEqual(@as(?Frame, null), windowFrame(parsed.workspace, 0));
    try std.testing.expectEqual(true, parsed.workspace.windows[0].active); // active-window는 여전히 정상 파싱
    try std.testing.expectEqualStrings("/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
}

test "workspace parse: 부분 win-* 필드(일부만)는 frame null(손상 방어)" {
    // writer는 넷 다 or 아무것도 안 내지만, 손상/변조 파일이 win-x만 담을 수 있다. 넷 중 하나라도 없으면 frame=null로
    // graceful(부분 좌표는 setFrame에 쓸 수 없어 cascade 폴백). 크래시·BadLine 아님(스칼라 부재는 기본값 규칙).
    const partial =
        header ++ "\n" ++
        "window tabs=1 active-tab=0 win-x=100 win-y=200\n" ++ // win-w/win-h 없음 → 부분
        "tab panes=1 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/a\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, partial); // 성공(부분 필드는 손상 아님·스칼라 부재)
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?Frame, null), parsed.workspace.windows[0].frame); // 부분 → null(넷 다 필요)
}

test "workspace parse: win-* 키가 있는데 값이 깨지면 BadLine(존재하는 손상은 안 숨김)" {
    // additive 스칼라 규칙(docs/workspace-restore.md): 키가 **있는데** 값이 비숫자면 조용히 기본값으로 때우지 않고
    // BadLine. win-w에 garbage → getInt가 BadLine(넷 다 존재하므로 frame을 만들려다 파싱 실패). 부재(위 테스트)와 구분.
    const broken =
        header ++ "\n" ++
        "window tabs=1 active-tab=0 win-x=10 win-y=20 win-w=abc win-h=40\n" ++ // win-w 비숫자
        "tab panes=1 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/a\" command=\"/bin/zsh\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, broken));
}

test "workspace parse: 구조·escape 해제·forgiving" {
    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=1 custom-name=\"my tab\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node split vertical ratio=250\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"left pane\"\n" ++
        "surface custom-name=\"editor\" title=\"top\" cwd=\"/a b\\\"c\" command=\"/bin/zsh\" cols=80 rows=24\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/bash\" cols=80 rows=10\n" ++
        "trailing-garbage that should be ignored\n";

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const ws = parsed.workspace;

    try std.testing.expectEqual(@as(usize, 1), ws.windows.len);
    const tab = ws.windows[0].tabs[0];
    try std.testing.expectEqual(@as(usize, 1), tab.active_pane);
    try std.testing.expectEqualStrings("my tab", tab.custom_name); // 워크스페이스 사용자 지정 이름
    try std.testing.expectEqual(@as(u32, 0), tab.accent_color); // accent-color=0 파싱
    // 트리: split(vertical, 250) { leaf0, leaf1 } — preorder 3노드.
    try std.testing.expectEqual(@as(usize, 3), tab.tree.len);
    try std.testing.expect(tab.tree[0].split.direction == .vertical);
    try std.testing.expectEqual(@as(u16, 250), tab.tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(usize, 1), tab.tree[2].leaf);
    // surface[0] cwd escape 해제: `/a b"c`. custom_name(사용자)과 title(자동)은 별도 필드로 round-trip.
    try std.testing.expectEqual(@as(usize, 2), tab.panes.len);
    try std.testing.expectEqualStrings("left pane", tab.panes[0].custom_name); // pane 사용자 지정 이름
    try std.testing.expectEqualStrings("editor", tab.panes[0].surfaces[0].custom_name); // Term 사용자 지정 이름
    try std.testing.expectEqualStrings("top", tab.panes[0].surfaces[0].title); // Term 자동 제목(별도)
    try std.testing.expectEqualStrings("/a b\"c", tab.panes[0].surfaces[0].cwd);
    try std.testing.expectEqual(@as(u16, 80), tab.panes[0].surfaces[0].cols);
    try std.testing.expectEqualStrings("", tab.panes[1].custom_name); // 빈 custom_name = 이름 없음
    try std.testing.expectEqualStrings("/bin/bash", tab.panes[1].surfaces[0].command);
}

test "workspace parse: key-addressed 하위호환·순서무관·미지키 skip·구조키 필수" {
    // ① 하위호환: background-color·accent-color가 없는 옛 tab 라인도 파싱되고 각각 0(기본)이 된다(폴백 없음).
    //    active-pane·pinned도 없이 panes=만 있어도 스칼라는 전부 기본값으로 복원 — additive 필드가 옛 파일을 안 깬다.
    const old =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 custom-name=\"legacy\"\n" ++ // background-color·accent-color·active-pane·pinned 없음(구버전)
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++ // active-term 없음
        "surface custom-name=\"\" title=\"\" cwd=\"/w\" command=\"/bin/zsh\" cols=100 rows=30\n";
    var op = try parse(std.testing.allocator, old);
    defer op.deinit();
    const ot = op.workspace.windows[0].tabs[0];
    try std.testing.expectEqualStrings("legacy", ot.custom_name);
    try std.testing.expectEqual(@as(u32, 0), ot.background_color); // 없음 → 기본 0
    try std.testing.expectEqual(@as(u32, 0), ot.accent_color); // 없음 → 기본 0
    try std.testing.expectEqual(false, ot.pinned); // 없음 → 기본 false
    try std.testing.expectEqual(@as(?[]const u8, null), ot.group_start); // group-start 없음 → null(그룹 아님)
    try std.testing.expectEqual(false, ot.group_collapsed); // 없음 → 기본 false
    try std.testing.expectEqual(@as(usize, 0), ot.active_pane); // 없음 → 기본 0
    try std.testing.expectEqual(@as(usize, 0), ot.panes[0].active_term); // 없음 → 기본 0

    // ② 순서 무관 + ③ 미지 키 skip: 스칼라 키 순서를 뒤섞고 모르는 future-key를 끼워도 정확히 파싱된다(forward-compat).
    const reordered =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab accent-color=100 panes=1 future-key=\"ignored\" pinned=1 custom-name=\"x\" background-color=200 active-pane=0\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var rp = try parse(std.testing.allocator, reordered);
    defer rp.deinit();
    const rt = rp.workspace.windows[0].tabs[0];
    try std.testing.expectEqual(@as(u32, 200), rt.background_color); // 순서 뒤섞여도 이름으로 정확히
    try std.testing.expectEqual(@as(u32, 100), rt.accent_color);
    try std.testing.expectEqual(true, rt.pinned);
    try std.testing.expectEqualStrings("x", rt.custom_name); // future-key는 조용히 skip, 값 흉내가 경계 안 깸

    // ④ 구조 키(panes=)가 없으면 loud-fail(BadLine) — 손상 탐지는 유지(스칼라만 기본값, 개수 키는 required).
    const no_panes =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab active-pane=0 custom-name=\"\"\n"; // panes= 없음 → 블록 파싱 불가
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, no_panes));
}

test "workspace parse: 잘못된 헤더는 에러" {
    try std.testing.expectError(error.BadHeader, parse(std.testing.allocator, "not.a.workspace\nwindow tabs=0 active-tab=0\n"));
}

test "workspace parse: 손상 트리는 구조 불변식으로 graceful 차단(크래시 대신 BadLine)" {
    // 탭은 panes=2(트리 노드 최대 2·2−1=3)인데 split가 과하게 중첩돼 4번째 노드를 요구 → BadLine으로 멈춘다
    // (깊은 재귀 스택 오버플로 방지). 복원 측은 이 에러로 그 창을 기본 창으로 떨군다.
    const deep =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, deep));

    // 부풀린 pane_count는 트리 노드 상한(2·pane−1)을 거대화하므로 sane 상한(max_panes_per_tab)에서 먼저 막는다.
    const huge =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=999999 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, huge));
}

test "workspace serializeWindow: 헤더 없는 블록을 모아 전체로 parse(R5 집계)" {
    // 두 창을 각각 serializeWindow(헤더 없음)로 내고 헤더 하나 아래로 모으면, parse가 전체 workspace로 읽는다.
    const s0 = [_]Surface{.{ .cwd = "/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p0 = [_]Pane{.{ .surfaces = &s0 }};
    const t0 = [_]TreeNode{.{ .leaf = 0 }};
    const win0 = Window{ .tabs = &[_]Tab{.{ .tree = &t0, .panes = &p0 }} };

    const s1 = [_]Surface{.{ .cwd = "/b", .command = "/bin/bash", .cols = 100, .rows = 30 }};
    const p1 = [_]Pane{.{ .surfaces = &s1 }};
    const t1 = [_]TreeNode{.{ .leaf = 0 }};
    const win1 = Window{ .tabs = &[_]Tab{.{ .tree = &t1, .panes = &p1 }} };

    const b0 = try serializeWindow(std.testing.allocator, win0);
    defer std.testing.allocator.free(b0);
    const b1 = try serializeWindow(std.testing.allocator, win1);
    defer std.testing.allocator.free(b1);
    try std.testing.expect(std.mem.startsWith(u8, b0, "window ")); // 헤더 없음

    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}{s}", .{ header, b0, b1 });
    defer std.testing.allocator.free(text);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.workspace.windows.len);
    try std.testing.expectEqualStrings("/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/b", parsed.workspace.windows[1].tabs[0].panes[0].surfaces[0].cwd);
}

test "workspace serialize: 선언적 — env/fd/pid/last-observed 필드 없음(민감 데이터 미저장 정책)" {
    // 모델이 PTY 핸들·env·last_observed_command 필드를 안 가져, 저장 텍스트에 그런 라인이 절대 안 샌다
    // (docs/workspace-restore.md: live process 저장 금지, env는 allowlist 전까지 비움, last command 자동실행 금지).
    // 이 가드는 누가 나중에 그런 필드를 추가하면 깨져서 정책 위반을 컴파일·테스트 단계에서 잡는다.
    const s = [_]Surface{.{ .title = "api", .cwd = "/home/user/.secret-proj", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p = [_]Pane{.{ .surfaces = &s }};
    const t = [_]TreeNode{.{ .leaf = 0 }};
    const w = [_]Window{.{ .tabs = &[_]Tab{.{ .tree = &t, .panes = &p }} }};
    const text = try serialize(std.testing.allocator, .{ .windows = &w });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "env=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fd=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pid=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last-observed") == null);
    // cwd는 경로라 정상 저장된다(redaction 대상은 env이지 path가 아님 — workspace-restore.md).
    try std.testing.expect(std.mem.indexOf(u8, text, "cwd=\"/home/user/.secret-proj\"") != null);
}

test "workspace Surface contains only declarative terminal fields" {
    const expected = [_][]const u8{ "custom_name", "title", "cwd", "command", "cols", "rows" };
    inline for (expected) |name| try std.testing.expect(@hasField(Surface, name));
    inline for (.{ "agent_kind", "agent_session", "agent_argv" }) |name| try std.testing.expect(!@hasField(Surface, name));
}

test "workspace line field cap accepts 512 neutral fields and rejects the 513th" {
    const a = std.testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    try line.appendSlice(a, "future");
    for (0..max_line_fields) |_| try line.appendSlice(a, " future-field=0");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fields = try LineFields.parse(arena.allocator(), line.items);
    try std.testing.expectEqual(@as(usize, 512), fields.fields.len);
    try line.appendSlice(a, " future-field-overflow=0");
    try std.testing.expectError(error.BadLine, LineFields.parse(arena.allocator(), line.items));
}

test "workspace dock FP1: 기본 상태는 키를 생략하고 옛 파일은 기본 도크로 읽힌다" {
    const windows = [_]Window{.{ .tabs = &.{} }};
    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(header ++ "\nwindow tabs=0 active-tab=0\n", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-") == null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const dock = parsed.workspace.windows[0].dock;
    try std.testing.expectEqual(dock_panel.Side.right, dock.side);
    try std.testing.expectEqual(@as(u32, 0), dock.size);
    try std.testing.expect(!dock.collapsed);
    try std.testing.expectEqual(dock_panel.View.explorer, dock.view);
    try std.testing.expectEqual(@as(usize, 0), dock.entries.len);
}

test "workspace: 도크 뷰는 왕복하고 모르는 뷰는 탐색기로 clamp된다" {
    // 뷰는 도크의 **표시 선택**이라, 못 읽는 값을 만나도 창을 버리지 않고 탐색기로 연다(docs/file-explorer.md §3.5).
    const windows = [_]Window{.{ .tabs = &.{}, .dock = .{ .view = .source_control, .presented = true } }};
    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-view=source_control") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(dock_panel.View.source_control, parsed.workspace.windows[0].dock.view);

    // 미래 뷰 이름 → 탐색기로 clamp(도크의 나머지 상태는 그대로).
    var future = try parse(std.testing.allocator, header ++ "\nwindow tabs=0 active-tab=0 dock-size=321 dock-view=timeline\n");
    defer future.deinit();
    try std.testing.expectEqual(dock_panel.View.explorer, future.workspace.windows[0].dock.view);
    try std.testing.expectEqual(@as(u32, 321), future.workspace.windows[0].dock.size);
}

test "workspace Explorer v137: packed explicit roots and empty presented dock round trip" {
    const roots = [_][]const u8{ "/Users/me/project one", "/tmp/quote\"root" };
    const windows = [_]Window{.{
        .dock = .{ .presented = true },
        .explorer = .{ .roots = &roots },
        .tabs = &.{},
    }};
    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "dock-tree-roots="));
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-presented") == null); // roots에서 presented 파생

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const win = parsed.workspace.windows[0];
    try std.testing.expect(win.dock.presented);
    try std.testing.expect(win.explorer.roots != null);
    try std.testing.expectEqual(@as(usize, 2), win.explorer.roots.?.len);
    try std.testing.expectEqualStrings(roots[0], win.explorer.roots.?[0]);
    try std.testing.expectEqualStrings(roots[1], win.explorer.roots.?[1]);

    const empty_windows = [_]Window{.{
        .dock = .{ .presented = true },
        .explorer = .{ .roots = &.{} },
        .tabs = &.{},
    }};
    const empty_text = try serialize(std.testing.allocator, .{ .windows = &empty_windows });
    defer std.testing.allocator.free(empty_text);
    try std.testing.expect(std.mem.indexOf(u8, empty_text, "dock-presented=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_text, "dock-tree-roots=\"0:\"") != null);
    var empty_parsed = try parse(std.testing.allocator, empty_text);
    defer empty_parsed.deinit();
    try std.testing.expect(empty_parsed.workspace.windows[0].dock.presented);
    try std.testing.expectEqual(@as(usize, 0), empty_parsed.workspace.windows[0].explorer.roots.?.len);

    const explicit_empty_without_presentation = header ++ "\n" ++
        "window tabs=0 active-tab=0 dock-tree-roots=\"0:\"\n";
    var hidden_empty = try parse(std.testing.allocator, explicit_empty_without_presentation);
    defer hidden_empty.deinit();
    try std.testing.expect(!hidden_empty.workspace.windows[0].dock.presented);
    try std.testing.expectEqual(@as(usize, 0), hidden_empty.workspace.windows[0].explorer.roots.?.len);
}

test "workspace Explorer v137: malformed packed roots degrade only explorer metadata" {
    const text = header ++ "\n" ++
        "window tabs=1 active-tab=0 dock-presented=1 dock-entry=\"markdown:read:1:12:/tmp/kept.md\" dock-tree-roots=\"2:4:/tmp999:/bad\"\n" ++
        "tab panes=1 active-pane=0 custom-name=\"kept tab\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"kept pane\"\n" ++
        "surface custom-name=\"kept surface\" title=\"shell\" cwd=\"/work\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.workspace.windows.len);
    const win = parsed.workspace.windows[0];
    try std.testing.expect(win.dock.presented);
    try std.testing.expect(win.explorer.roots != null);
    try std.testing.expectEqual(@as(usize, 0), win.explorer.roots.?.len);
    // 옛 `dock-entry`는 2026-07-29에 읽기 경로를 지워 **조용히 무시**된다(unknown field 관용) — 창·탐색기
    // 상태는 그대로 살아남는 것이 이 테스트의 관심사다.
    try std.testing.expectEqual(@as(usize, 0), win.dock.entries.len);
    try std.testing.expectEqual(@as(usize, 1), win.tabs.len);
    try std.testing.expectEqualStrings("kept tab", win.tabs[0].custom_name);
    try std.testing.expectEqual(@as(usize, 1), win.tabs[0].panes.len);
    try std.testing.expectEqualStrings("kept pane", win.tabs[0].panes[0].custom_name);
    try std.testing.expectEqual(@as(usize, 1), win.tabs[0].panes[0].surfaces.len);
    try std.testing.expectEqualStrings("/work", win.tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/bin/zsh", win.tabs[0].panes[0].surfaces[0].command);

    const inferred_presented = header ++ "\n" ++
        "window tabs=0 active-tab=0 dock-tree-roots=\"1:9:relative!\"\n";
    var parsed_without_flag = try parse(std.testing.allocator, inferred_presented);
    defer parsed_without_flag.deinit();
    try std.testing.expect(parsed_without_flag.workspace.windows[0].dock.presented);
    try std.testing.expectEqual(@as(usize, 0), parsed_without_flag.workspace.windows[0].explorer.roots.?.len);
}

test "workspace Explorer v137: root count path and raw caps fail closed" {
    var too_many: [max_explorer_roots + 1][]const u8 = .{"/same"} ** (max_explorer_roots + 1);
    const too_many_windows = [_]Window{.{ .explorer = .{ .roots = &too_many }, .tabs = &.{} }};
    try std.testing.expectError(error.InvalidExplorerState, serialize(std.testing.allocator, .{ .windows = &too_many_windows }));

    var long_path: [std.fs.max_path_bytes + 1]u8 = @splat('a');
    long_path[0] = '/';
    const long_roots = [_][]const u8{&long_path};
    const long_windows = [_]Window{.{ .explorer = .{ .roots = &long_roots }, .tabs = &.{} }};
    try std.testing.expectError(error.InvalidExplorerState, serialize(std.testing.allocator, .{ .windows = &long_windows }));

    const raw = try std.testing.allocator.alloc(u8, max_explorer_root_raw_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, '0');
    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\nwindow tabs=0 active-tab=0 dock-tree-roots=\"{s}\"\n", .{ header, raw });
    defer std.testing.allocator.free(text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expect(parsed.workspace.windows[0].dock.presented);
    try std.testing.expectEqual(@as(usize, 0), parsed.workspace.windows[0].explorer.roots.?.len);
}

test "workspace Explorer v137: streaming decoded cap and allocation failure degrade to explicit empty" {
    const decoded = try std.testing.allocator.alloc(u8, max_explorer_root_payload_bytes + 1);
    defer std.testing.allocator.free(decoded);
    @memset(decoded, 'a');
    var cursor = ExplorerQuotedCursor{ .raw = decoded };
    for (0..max_explorer_root_payload_bytes) |_| try std.testing.expect((try cursor.next()) != null);
    try std.testing.expectError(error.PayloadTooLarge, cursor.next());

    const field: LineFields.Field = .{ .key = "dock-tree-roots", .raw = "1:4:/tmp", .is_quoted = true };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const roots = parseExplorerRoots(failing.allocator(), field).roots.?;
    try std.testing.expectEqual(@as(usize, 0), roots.len);
    try std.testing.expect(failing.has_induced_failure);
}

test "workspace: 옛 창-레벨 dock 파일 키는 무시되고 capture 불변식은 그대로다" {
    // 옛 `dock-entry`/`dock-entry-v2`/`dock-node`/`dock-group-*` 읽기 경로는 제거했다(2026-07-29). 그 키가 남은
    // 아주 오래된 파일은 unknown-field 관용으로 **조용히 무시**되고 창·탭·터미널은 정상 복원된다 — 손상된
    // 길이/중복 active 같은 옛 거부 규칙도 함께 사라진다(파싱하지 않으므로 판단할 대상이 없다).
    const legacy = header ++ "\n" ++
        "window tabs=1 active-tab=0 dock-side=bottom dock-entry=\"markdown:read:1:99:/tmp/a.md\" dock-group-count=2 dock-node=\"leaf:0\"\n" ++
        "tab panes=1 custom-name=\"kept\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/work\" command=\"/bin/zsh\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, legacy);
    defer parsed.deinit();
    const win = parsed.workspace.windows[0];
    try std.testing.expectEqual(@as(usize, 0), win.dock.entries.len); // 옛 파일 목록은 안 살아난다
    try std.testing.expectEqual(dock_panel.Side.bottom, win.dock.side); // 배치 상태는 그대로 읽는다
    try std.testing.expectEqual(@as(usize, 1), win.tabs.len);
    try std.testing.expectEqualStrings("kept", win.tabs[0].custom_name);

    // capture 쪽 불변식(있으면 정확히 하나 active)은 유지된다 — `dock-presented` 판정이 이 목록을 본다.
    const invalid_entries = [_]dock_panel.PersistedEntry{
        .{ .path = "/tmp/a.md", .kind = .markdown, .active = false },
    };
    const invalid_windows = [_]Window{.{ .dock = .{ .entries = &invalid_entries }, .tabs = &.{} }};
    try std.testing.expectError(error.InvalidDockState, serialize(std.testing.allocator, .{ .windows = &invalid_windows }));
}

test "workspace FP16: file-term이 pane 줄에서 왕복하고 창 줄엔 파일 키가 없다" {
    const file_terms = [_]FileTerm{
        .{ .index = 1, .kind = .markdown, .mode = .source_edit, .path = "/Users/me/a:b \"한글\".md" },
        .{ .index = 2, .kind = .html, .mode = .read, .path = "/Users/me/line\nname.html" },
    };
    const surfaces = [_]Surface{.{ .custom_name = "", .title = "", .cwd = "", .command = "", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 1, .surfaces = &surfaces, .file_terms = &file_terms }};
    const tabs = [_]Tab{.{ .active_pane = 0, .panes = &panes, .tree = &.{.{ .leaf = 0 }} }};
    const windows = [_]Window{.{
        .dock = .{ .side = .bottom, .size = 420, .collapsed = true },
        .tabs = &tabs,
    }};
    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    // 탐색기 도크 키는 남고, 파일 목록 키는 창 줄에서 사라졌다.
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-size=420") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-entry=\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-entry-v2=\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dock-node=\"") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "file-term=\""));
    // dirty는 런타임 상태라 영속하지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, text, "dirty") == null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const pane = parsed.workspace.windows[0].tabs[0].panes[0];
    try std.testing.expectEqual(@as(usize, 2), pane.file_terms.len);
    try std.testing.expectEqual(@as(usize, 1), pane.file_terms[0].index);
    try std.testing.expectEqual(dock_panel.EntryKind.markdown, pane.file_terms[0].kind);
    try std.testing.expectEqual(dock_panel.Mode.source_edit, pane.file_terms[0].mode);
    try std.testing.expectEqualStrings("/Users/me/a:b \"한글\".md", pane.file_terms[0].path);
    try std.testing.expectEqualStrings("/Users/me/line\nname.html", pane.file_terms[1].path);
    try std.testing.expectEqual(@as(usize, 1), pane.active_term);
    // 창 줄의 탐색기 상태는 그대로 왕복한다.
    try std.testing.expectEqual(@as(u32, 420), parsed.workspace.windows[0].dock.size);
    try std.testing.expectEqual(@as(usize, 0), parsed.workspace.windows[0].dock.entries.len);
}

test "workspace FP16: persisted 인덱스가 중복·범위 밖이거나 active-term이 넘치면 그 창을 폴백한다" {
    const bad_dup =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" file-term=\"1:markdown:read:9:/tmp/a.md\" file-term=\"1:markdown:read:9:/tmp/b.md\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, bad_dup));

    const bad_range =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" file-term=\"5:markdown:read:9:/tmp/a.md\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, bad_range));

    const bad_active =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=9 custom-name=\"\" file-term=\"1:markdown:read:9:/tmp/a.md\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, bad_active));
}

test "workspace WP-P: browser-term URL이 왕복하고 인덱스 공간을 안 건드린다" {
    // WP-P 핵심 계약: 브라우저는 **URL만** 저장하고 `insert_after`(앞의 persisted Term 수)를 쓴다 — file-term
    // 인덱스를 재번호하지 않으므로 구버전 리더가 브라우저만 잃고 창은 살린다. 그 성질을 왕복으로 고정한다.
    const a = std.testing.allocator;
    const text =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" file-term=\"1:markdown:read:9:/tmp/a.md\" " ++
        "browser-term=\"1:20:https://example.com/\" active-browser=0\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    var parsed = try parse(a, text);
    defer parsed.deinit();
    const pane = parsed.workspace.windows[0].tabs[0].panes[0];
    try std.testing.expectEqual(@as(usize, 1), pane.file_terms.len); // 파일 인덱스는 그대로 1
    try std.testing.expectEqual(@as(usize, 1), pane.file_terms[0].index);
    try std.testing.expectEqual(@as(usize, 1), pane.browser_terms.len);
    try std.testing.expectEqual(@as(usize, 1), pane.browser_terms[0].insert_after);
    try std.testing.expectEqualStrings("https://example.com/", pane.browser_terms[0].url);
    try std.testing.expectEqual(@as(?usize, 0), pane.active_browser);

    // 다시 직렬화 → 같은 값이 나오고 재파싱도 통과한다(byte 고정점이 아니라 값 왕복을 본다).
    const out = try serialize(a, parsed.workspace);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "browser-term=\"1:20:https://example.com/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "active-browser=0") != null);
    var again = try parse(a, out);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.workspace.windows[0].tabs[0].panes[0].browser_terms.len);
}

test "workspace WP-P: 잘못된 browser-term은 record만 버리거나 창을 폴백한다" {
    const a = std.testing.allocator;
    // 빈 URL = 복원할 값 없음 → 그 record만 버린다(창은 살린다). file-term의 UnsupportedDockValue와 같은 관용.
    const empty_url =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" browser-term=\"0:0:\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    var kept = try parse(a, empty_url);
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 0), kept.workspace.windows[0].tabs[0].panes[0].browser_terms.len);
    try std.testing.expectEqual(@as(usize, 1), kept.workspace.windows[0].tabs[0].panes[0].surfaces.len); // 창 보존

    // insert_after가 persisted_total(1)을 넘으면 자리를 만들 수 없다 → 그 창 fail-close.
    const out_of_range =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" browser-term=\"5:20:https://example.com/\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(a, out_of_range));

    // active-browser가 record 수를 넘으면 폴백(가리킬 대상이 없다).
    const bad_active =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" active-browser=2 browser-term=\"0:20:https://example.com/\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    try std.testing.expectError(error.BadLine, parse(a, bad_active));
}

test "workspace FP15: media file-term이 read 모드로 왕복한다" {
    // media는 격리 loadFileURL(WebKit media document) read 뷰라 mode가 항상 read다. wire 이름은 EntryKind
    // 태그명(`media`)이고, 옛 Maru가 이 줄을 읽으면 모르는 kind로 **그 항목만** 버린다(창은 산다 — 아래 테스트).
    const file_terms = [_]FileTerm{.{ .index = 1, .kind = .media, .mode = .read, .path = "/Users/me/영상 clip.mp4" }};
    const surfaces = [_]Surface{.{ .custom_name = "", .title = "", .cwd = "", .command = "", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .active_term = 1, .surfaces = &surfaces, .file_terms = &file_terms }};
    const tabs = [_]Tab{.{ .active_pane = 0, .panes = &panes, .tree = &.{.{ .leaf = 0 }} }};
    const windows = [_]Window{.{ .tabs = &tabs }};
    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "media") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const pane = parsed.workspace.windows[0].tabs[0].panes[0];
    try std.testing.expectEqual(@as(usize, 1), pane.file_terms.len);
    try std.testing.expectEqual(dock_panel.EntryKind.media, pane.file_terms[0].kind);
    try std.testing.expectEqual(dock_panel.Mode.read, pane.file_terms[0].mode);
    try std.testing.expectEqualStrings("/Users/me/영상 clip.mp4", pane.file_terms[0].path);
}

test "workspace FP16: 모르는 kind의 file-term은 그 항목만 버리고 창은 살린다" {
    const text =
        "maru.workspace.v1\nwindow tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\" file-term=\"1:hologram:read:9:/tmp/a.md\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"\" cols=80 rows=24\n";
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const pane = parsed.workspace.windows[0].tabs[0].panes[0];
    try std.testing.expectEqual(@as(usize, 0), pane.file_terms.len); // 미지 kind는 그 항목만 버린다
    try std.testing.expectEqual(@as(usize, 1), pane.surfaces.len); // 창·pane은 살아남는다
}

test "diff 파일 Term은 저장되지 않고 파일에서 읽히지도 않는다" {
    // diff는 그 시점 git 상태의 비교 결과다. 되살리면 저장할 때 보던 것과 다른 화면을 같은 것처럼 보여 주므로
    // 저장 대상이 아니다(docs/editor-surface-dock.md §3.5). 대신 소스 컨트롤 목록에서 다시 연다.
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const panes = [_]Pane{.{
        .surfaces = &.{},
        .file_terms = &.{
            .{ .index = 0, .kind = .markdown, .mode = .read, .path = "/tmp/keep.md" },
            .{ .index = 1, .kind = .diff, .mode = .read, .path = "/tmp/drop.zig" },
        },
    }};
    try writePane(&buf.writer, panes[0]);
    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "keep.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "drop.zig") == null);
    // 손으로 diff를 적어 넣어도 읽지 않는다(복원 못 할 상태를 파일이 만들지 못하게).
    try std.testing.expect(parseEntryKindName("diff") == null);
    try std.testing.expect(parseEntryKindName("markdown") != null);
}
