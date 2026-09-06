const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const split_tree = @import("split_tree.zig");

/// 파일 패널 도크의 창-로컬 배치. 실제 rect 계산과 config 기본 크기는 FP3가 소유하며, `size == 0`은 그
/// 런타임 기본을 사용한다는 뜻이다. FP1이 아직 정해지지 않은 픽셀/point 정책을 선점하지 않게 하는 sentinel이다.
pub const Side = enum { right, bottom };

/// 도크가 담는 뷰. 도크는 하나이고 그 안에서 무엇을 그릴지만 고른다(docs/file-explorer.md §3.5) — 폭·접기·포커스·
/// 영속은 뷰와 무관하게 도크가 계속 소유한다. 새 뷰를 더할 때 workspace 리더는 **모르는 값을 `explorer`로 clamp**해
/// 옛 버전이 새 파일을 만나도 창을 통째로 버리지 않는다.
/// ⚠️ **뷰를 더하면 「활성 pane 을 어떻게 따라가는가」를 답해야 한다.**
///
/// 사용자가 이 축을 신고한 이유가 그것이다(2026-08-31): 이미지 갤러리에는 그 답이 **없어서**, pane 을
/// 옮겨도 격자가 옛 pane 의 것으로 남았다. 나머지 셋은 답을 갖고 있었는데 **함수 이름도 파일도 서로
/// 달라**, 더하는 사람이 「여기도 필요하다」를 알 길이 없었다.
///
/// | 뷰 | 추종 진입점 |
/// | --- | --- |
/// | `explorer` | `app_session/file_panel.zig` · `followActiveTerminalCwd` |
/// | `source_control` | `app_session/git.zig` · `followActiveTerminalRepo` |
/// | `agent_sessions` | `app_session/agent_dock.zig` · `refreshAgentSessionArchiveProjectScopeForFocus` |
/// | `image_gallery` | `app_session/image_gallery.zig` · `refreshForFocus` |
///
/// 이 표를 판정자가 **exhaustive switch 로** 물고 있다(`app_session.zig` — 「도크 뷰는 전부 활성 pane 을
/// 따라간다」). 값이 늘면 **거기서 컴파일이 깨진다** — 런타임 판정자는 그 사람이 안 돌리면 그만이라,
/// 강제력을 컴파일러에 둔다.
pub const View = enum {
    explorer,
    source_control,
    agent_sessions,
    /// IG1: 에이전트와 주고받은 이미지 격자(docs/agent-image-gallery.md). 범위는 **활성 pane**이다.
    image_gallery,

    /// 뷰 스위처 바의 **슬롯 순서**. 화면 왼쪽부터 이 차례다.
    ///
    /// **여기 두는 이유**: 슬롯 기하는 chrome(`dock_view_bar`)이 소유하지만 그 슬롯이 **무슨 뷰인가**
    /// 는 이 enum 의 성질이고, chrome 은 session 을 import 할 수 없다. 호출자마다 `0 => .explorer`
    /// 를 적으면 뷰를 하나 더할 때 한 곳만 고쳐져 **바의 두 번째 칸이 다른 화면을 연다.**
    pub fn forSlot(index: usize) ?View {
        return switch (index) {
            0 => .explorer,
            1 => .source_control,
            2 => .agent_sessions,
            3 => .image_gallery,
            else => null,
        };
    }

    /// `forSlot` 의 역. 지금 뷰의 칸을 강조할 때 쓴다.
    pub fn slot(self: View) usize {
        return switch (self) {
            .explorer => 0,
            .source_control => 1,
            .agent_sessions => 2,
            .image_gallery => 3,
        };
    }

    /// workspace 텍스트 → 뷰. 모르는 이름은 null이고 호출자가 기본값으로 clamp한다.
    pub fn parse(name: []const u8) ?View {
        inline for (@typeInfo(View).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) return @field(View, field.name);
        }
        return null;
    }
};

/// 창 하나가 보존하는 파일 entry 상한. workspace.v1이 window 한 줄에 반복 키를 두는 FP1 포맷이므로 reader의
/// 손상-input 작업량 bound와 live 모델의 저장 가능 상태를 같은 계약으로 맞춘다. 비활성 WKWebView 해제 상한(기본 8)과
/// 달리 이 값은 가벼운 탭 metadata 수 상한이다.
pub const max_entries: usize = 256;

/// 한 창 도크의 editor group 상한. 분할 UI는 보통 한 자릿수지만 workspace 입력이 빈 leaf를 무한히 만들지
/// 못하게 모델과 reader가 같은 bound를 쓴다. 64 groups면 preorder node도 최대 127개로 고정된다.
/// 콘텐츠 종류는 WebKit 구성 선택에 쓰이는 L2 정책 값이다. 브라우저 탭을 도크로 보내는 후속 확장은 이 닫힌 목록에
/// 새 값을 더하되, 트리·탭 소유 모델은 그대로 재사용한다(docs/file-panel.md §1, docs/file-panel-kinds.md §2.2). `text`는 markdown과 같은
/// 신뢰 shell·`maru.file.read/write` 브리지를 쓰지만 라이브 프리뷰·mode 선택기·링크가 없는 소스 전용 편집기다(FP12).
pub const EntryKind = enum {
    markdown,
    html,
    text,
    svg,
    image,
    media,
    pdf,
    /// E1: git diff 본문(docs/editor-surface-structure.md §3, docs/plans/editor-surface.md §9). 신뢰 shell에 CM6 MergeView를 마운트하지만 파일을 편집하지
    /// 않는다 — 내용은 `diff.open`이 주고 저장·dirty·epoch 흐름이 없다. **디스크 파일이 아니라 비교 결과**라
    /// entry가 경로와 함께 비교 기준(`DiffBase`)을 들고 다닌다.
    diff,

    /// 신뢰 shell에서 CM6를 마운트하고 `maru.file.read/write` 브리지로 편집하는 kind인지. read/write·dirty·저장·
    /// document epoch·외부변경·초기 hydration identity 보호 게이트가 이 술어를 공유한다(§2.2·§3). markdown 라이브
    /// 프리뷰·링크·readAsset·mermaid 전용 경로는 별도로 `== .markdown`을 유지한다. svg는 소스 편집(xml)이 이 브리지를
    /// 쓰고 읽기 모드는 격리 render origin의 sanitize 프리뷰다(§2.2·FP13).
    /// **kind만 보는 판정이다.** 실제 소비처는 `Entry.usesEditorBridge`를 쓴다 — 같은 kind 안에서도
    /// 네이티브 편집기로 연 문서는 브리지를 안 쓰기 때문이다. 이름을 나눠 둔 것은 그 둘을 헷갈려
    /// 호출하면 컴파일러가 잡지 못해서다.
    pub fn usesEditorBridgeByKind(self: EntryKind) bool {
        return switch (self) {
            .markdown, .text, .svg => true,
            // diff는 CM6를 쓰지만 **읽기 전용 비교 결과**라 file.read/write·dirty·저장·epoch 흐름이 없다.
            // 내용은 diff.open이 주고, 그 method는 별도 grant 축이다(§3.1).
            .diff => false,
            // image(FP14)는 신뢰 shell이지만 CM6 편집기가 없다(readSelfImage로 자기 바이너리만 읽어 panzoom read
            // 프리뷰). html·media·pdf는 격리 loadFileURL(media는 WebKit media document — FP15). 넷 다 CM6 편집기·
            // editor_epoch 문서 흐름을 쓰지 않는다(§2.2).
            .html, .image, .media, .pdf => false,
        };
    }
};

/// diff 본문의 **비교 기준**. 도크 소스 컨트롤 목록의 섹션이 그대로 기준이 된다(docs/editor-surface.md §10.10 —
/// 전역 기본 base도 선택기도 두지 않는다). 같은 경로가 스테이지·미스테이지 양쪽에 있을 수 있으므로 diff Term의
/// 유일성 키는 `(경로, kind, base)`다 — 한 파일의 두 diff를 나란히 보는 것은 정상 리뷰 흐름이다(§3.5).
pub const DiffBase = enum {
    /// `HEAD ↔ index`(스테이지된 변경).
    staged,
    /// `index ↔ worktree`(변경 사항).
    unstaged,
    /// 비교 대상이 없다 — 파일 내용을 그대로 보여 준다(추적되지 않은 파일).
    untracked,
    /// 히스토리에서 고른 **커밋 하나**: `커밋^ ↔ 커밋`(P4b). 루트 커밋은 `^`가 없어 왼쪽이 없다 —
    /// 그때는 `untracked`처럼 오른쪽만 보인다(새로 생긴 파일과 같은 모양이고, 실제로 그렇다).
    ///
    /// 병합 커밋은 **첫 부모 기준**이다(`commit_files`가 같은 기준으로 목록을 낸다) — 목록과 본문이
    /// 다른 기준을 쓰면 목록에 있는 파일이 본문에서 "변경 없음"으로 보인다.
    commit,
    /// 에이전트 타임라인의 **완료된 턴 하나**: `스냅샷[K+1] ↔ 스냅샷[K]`(P5). 양쪽 다 tree라
    /// 작업트리가 어떻게 바뀌든 그 비교는 고정된다 — `turn`(마지막 스냅샷 ↔ 작업트리)과 **다른 기준**이다.
    turn_range,
    /// 병합 충돌 중인 파일: `HEAD ↔ 작업트리`. index에 stage 0이 없어 `:<경로>`를 못 읽으므로(실측) 왼쪽을
    /// HEAD로 잡는다 — 그러면 작업트리의 충돌 표시를 그대로 볼 수 있다.
    conflict,

    /// 탭 라벨에 붙일 기준 이름. 파일 이름만으로는 **같은 파일의 다른 비교**(MM은 두 개, 편집기 탭까지 세 개)를
    /// 구분할 수 없다 — 무엇을 보고 있는지 탭에서 바로 알 수 있어야 한다.
    pub fn label(self: DiffBase) []const u8 {
        return switch (self) {
            .staged => i18n.t(.dock_staged),
            .unstaged => i18n.t(.dock_worktree),
            .untracked => i18n.t(.dock_new_file),
            .conflict => i18n.t(.dock_conflict),
            .commit => i18n.t(.dock_commit),
            .turn_range => i18n.t(.dock_turn),
        };
    }
};

/// 폐기된 라이브 프리뷰 모드가 workspace 파일에 남긴 wire 이름이다. **writer는 이 값을 다시 쓰지 않는다** —
/// 옛 파일을 여는 reader만 이 이름을 읽기 모드로 마이그레이션한다(`workspace.parseDockEntry`). 흡수하지 않으면
/// 알 수 없는 mode가 그 창의 도크 전체를 빈 상태로 강등해 사용자가 열어 둔 파일 탭을 잃는다.
pub const legacy_live_preview_mode_name = "live-preview";

/// 파일 도크 표시 모드. enum ordinal은 C ABI raw 값, workspaceName/parseWorkspaceName은 workspace 문자열 wire의
/// 정책 SSOT다. 헤더의 시각 순서·kind별 선택지는 `dock_layout.modesForKind`가 별도로 고정한다. HTML은 read만 허용하고
/// Markdown의 두 편집 모드는 같은 dirty/save 수명 계약을 소비한다.
pub const Mode = enum(u32) {
    read = 0,
    source_edit = 1,
    /// 툴바를 가진 문서모델 WYSIWYG 편집(§2.5). markdown 전용이며 소스를 대체하지 않는다.
    rich = 2,

    /// 새 entry의 시작 모드는 kind 정책에서 한 번만 정한다. 복원 entry는 workspace에 저장된 mode를 그대로
    /// 덮어쓰므로 이 기본값과 독립이고, HTML은 실행 가능한 문서라 계속 read-only로 시작한다.
    pub fn defaultFor(kind: EntryKind) Mode {
        return switch (kind) {
            .markdown => .read,
            // diff는 읽기 전용이라 mode가 하나뿐이다(선택기도 없다 — dock_layout.modesForKind).
            .diff => .read,
            // html·media·pdf=격리 loadFileURL, image=신뢰 뷰어+readSelfImage(FP14) — 넷 다 read 뷰 전용(편집·모드 없음).
            .html, .image, .media, .pdf => .read,
            .text => .source_edit,
            .svg => .read, // 이미지 미리보기가 먼저(VSCode SVG 프리뷰 관례).
        };
    }

    pub fn allowedFor(self: Mode, kind: EntryKind) bool {
        return switch (kind) {
            .markdown => self == .read or self == .rich or self == .source_edit,
            .html, .image, .media, .pdf => self == .read, // read 뷰 전용(편집·모드 없음).
            .text => self == .source_edit,
            .svg => self == .read or self == .source_edit, // 리치는 markdown 전용이다.
            .diff => self == .read, // 읽기 전용 비교 결과.
        };
    }

    pub fn isEditable(self: Mode) bool {
        return self == .source_edit or self == .rich;
    }

    pub fn workspaceName(self: Mode) []const u8 {
        return switch (self) {
            .read => "read",
            .source_edit => "source-edit",
            .rich => "rich",
        };
    }

    pub fn parseWorkspaceName(raw: []const u8) ?Mode {
        inline for (std.enums.values(Mode)) |mode| {
            if (std.mem.eql(u8, raw, mode.workspaceName())) return mode;
        }
        return null;
    }
};

/// 파일 entry의 앱-런타임 전역 identity. path는 rename으로, surface_id는 LRU eviction/recreate로 바뀔 수 있어
/// drag·비동기 ack가 위치를 다시 찾는 키로 쓸 수 없다. 0은 미할당 sentinel이며 발급한 값은 close 뒤에도 재사용하지 않는다.
pub const EntryId = u64;

/// AppRuntime이 인스턴스 하나를 소유하고 각 DockPanel에 주입하는 순수 L2 발급기. 메인 actor 전용이며, wrap 시
/// 0이나 과거 값을 재발급하는 대신 fail-closed한다.
pub const EntryIdAllocator = struct {
    next_id: EntryId = 1,

    pub fn next(self: *EntryIdAllocator) !EntryId {
        if (self.next_id == 0 or self.next_id == std.math.maxInt(EntryId)) return error.EntryIdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

pub const Entry = struct {
    id: EntryId,
    path: []u8,
    kind: EntryKind,
    /// 이 문서를 **네이티브 편집기 Term**이 들고 있나(N1 — `MARU_NATIVE_TEXT`). kind로 가를 수 없어
    /// entry에 둔다: `.text`는 CM6로도 네이티브로도 열리고, 그 둘은 저장·dirty·epoch 흐름이 있고
    /// 없고가 갈린다. `.diff`는 kind 자체가 브리지를 안 써서 이 필드가 필요 없었다.
    native_editor: bool = false,
    /// 런타임 entry 생성자는 신규 정책(`Mode.defaultFor`)인지 복원된 명시 mode인지 반드시 선택한다.
    /// wire 호환용 `.read` fallback은 `PersistedEntry`에만 남겨 둘을 조용히 섞지 않는다.
    mode: Mode,
    dirty: bool = false,
    /// FP6 two-phase dirty mirror. source editor가 비활성/읽기 모드로 넘어갈 때 true로 세우고 shell의 강제
    /// setDirty snapshot ack에서만 내린다. ack 전에는 non-dirty라도 live view eviction 대상이 아니다.
    dirty_sync_pending: bool = false,
    /// scope close(`.pane`/`.tab`)가 파괴 전 dirty 스냅샷을 **이미 한 번 요청했나**. 브릿지가 영영 답하지
    /// 않아도 두 번째 시도는 그냥 진행하게 하는 once-only 래치다 — 없으면 편집 가능 파일이 든 pane이
    /// 영원히 안 닫힌다(docs/file-panel-dock-ui.md §3.2).
    close_snapshot_requested: bool = false,
    /// shell이 보고한 CM6 문서 revision. close request의 request_id/revision ack와 함께 stale clean/save 완료를 거부한다.
    editor_revision: u64 = 0,
    /// 같은 surface에서 WebContent document가 교체돼 revision clock이 0으로 돌아가도 이전 document의 ACK가 새
    /// 편집 상태를 덮지 못하게 하는 런타임 generation. bridge beginDocument만 증가시키며 workspace에는 저장하지 않는다.
    editor_epoch: u64 = 0,
    /// document id는 신뢰 shell URL이 가진 surface-local 단조 navigation identity다. 같은 document의 begin 재시도는
    /// idempotent하게 같은 epoch를 받고, 이전 document의 늦은 begin/read는 거부한다. surface id 교체 시 새 수명으로 본다.
    editor_surface_id: u64 = 0,
    editor_document_id: u64 = 0,
    editor_document_active: bool = false,
    /// dirty/pending document를 잃은 WebContent reload는 disk hydration으로 clean을 추정할 수 없다. 명시적 복구 UX가
    /// 생길 때까지 save/clean ACK/eviction/mutation을 fail-close하는 catastrophic recovery latch다.
    editor_recovery_required: bool = false,
    /// diff entry 전용. 어느 기준으로 비교하는지 — 유일성 키의 일부이고(§3.5) 읽을 blob도 이 값이 정한다.
    /// diff가 아닌 kind에서는 의미가 없다(`.unstaged` 기본값을 읽지 않는다).
    diff_base: DiffBase = .unstaged,
    /// diff entry 전용. 저장소 루트 기준 상대경로 — `git show <rev>:<path>`가 그 형태를 요구한다. entry의 `path`는
    /// 절대경로라 그대로 못 쓴다. 소유는 entry에 있고 `path`와 같은 시점에 해제된다.
    diff_rel_path: []u8 = &.{},
    /// rename의 **옛 경로**(그 외 빈 값). 왼쪽(HEAD)은 이 경로로 읽어야 한다 — 새 경로는 HEAD에 없다.
    diff_orig_rel_path: []u8 = &.{},
    /// `.turn_range` 기준의 **오른쪽 tree**(P5). 왼쪽은 아래 `diff_commit_oid`가 든다 — 두 기준이
    /// "왼쪽 rev"라는 같은 자리를 공유하고, 오른쪽이 있는 기준만 이 값을 더 든다.
    diff_right_oid: []u8 = &.{},
    /// `.commit` 기준이 비교할 **커밋 OID**(P4b). 왼쪽은 `<oid>^:<경로>`, 오른쪽은 `<oid>:<경로>`다.
    /// 다른 기준에서는 비어 있다 — 그 값들은 목록 읽기가 준 merge-base·스냅샷 tree를 쓴다.
    diff_commit_oid: []u8 = &.{},
    /// 이 비교가 속한 저장소 루트. **열 때 정해 들고 다닌다** — 나중에 다시 구하면 그 사이 활성 Term이 바뀌어
    /// 다른 저장소(혹은 없음)로 해석된다.
    diff_repo: []u8 = &.{},
    /// 이 비교가 **어느 호스트의 것인가**(RS3 — docs/plans/remote-scm.md). 빈 값이면 로컬이다.
    /// `diff_remote_root`는 그 호스트에서의 저장소 루트다(작업트리 쪽을 읽을 때 절대경로를 만든다).
    ///
    /// **`diff_repo`와 같은 이유로 열 때 박는다.** 세션 상태(`git_repo_dest`)를 나중에 읽으면, diff를 열어
    /// 둔 채 다른 pane으로 옮겼을 때 **그 비교가 다른 호스트의 것으로 해석된다** — 경로만 보면 원격
    /// `/srv/app`과 로컬 `/srv/app`이 같은 값이라 그 오해는 조용히 일어난다.
    diff_remote_dest: []u8 = &.{},
    diff_remote_root: []u8 = &.{},
    /// **원격 미러의 출처**(RF6e). 이 문서가 원격 파일을 내려받은 미러라면, `remote_origin_dest` 는
    /// 그 호스트이고 `remote_origin_path` 는 **저쪽에서의 절대 경로**다. 빈 값이면 로컬 파일이다.
    ///
    /// 왜 필요한가: 미러는 `~/.cache/maru/remote-view/<해시>/<이름>` 에 있어서, 경로 밴드가 그것을
    /// 그대로 그리면 **화면이 거짓말을 한다** — 사용자가 연 것은 저쪽 파일인데 우리 캐시 경로가 뜬다.
    /// `diff_remote_dest` 와 같은 이유로 **열 때 박는다**: 나중에 세션 상태를 읽으면 그 사이 활성
    /// pane 이 바뀌어 다른 호스트의 것으로 해석된다(경로만 보면 원격 `/srv/app` 과 로컬 `/srv/app` 이
    /// 같은 값이라 그 오해는 조용히 일어난다).
    remote_origin_dest: []u8 = &.{},
    /// 밴드가 그릴 **표시 라벨**(`<호스트>:<저쪽 절대 경로>` — 상태바 cwd 라벨과 같은 모양).
    /// 경로가 아니라 **라벨**이다: 밴드는 문자열 하나를 받으므로 렌더에서 이어 붙이지 않고 **열 때
    /// 한 번** 굳힌다(프레임마다 할당하지 않는다). 저쪽 순수 경로가 필요해지는 소비처가 생기면 그때
    /// 필드를 더한다 — 지금은 없다.
    remote_origin_label: []u8 = &.{},
    /// 백엔드가 읽어 온 두 쪽. `diff_ready` 전에는 비어 있고, 브리지는 그 상태를 pending으로 답한다 —
    /// 빈 문서를 정상 결과로 주면 화면이 "변경 없음"을 보여 준다.
    diff_original: []u8 = &.{},
    diff_modified: []u8 = &.{},
    diff_ready: bool = false,
    /// 읽기가 실패했다(경로가 사라졌거나 conflict 등). 다시 열기 전까지 이 상태를 유지한다.
    diff_failed: bool = false,
    /// 한쪽이라도 상한에서 잘렸다 — 온전한 파일처럼 보여 주지 않고 그 사실을 화면에 말한다.
    diff_truncated: bool = false,
    /// 이 entry가 건 읽기 요청. 늦게 도착한 옛 결과가 새 내용을 덮지 않게 한다.
    diff_request_id: u64 = 0,
    /// 마지막 성공 Markdown read/save의 디스크 content token. 저장 직전 같은 inode의 in-place 외부 변경도 감지한다.
    disk_content_hash: u64 = 0,
    disk_content_hash_valid: bool = false,
    /// Materialized explorer row에서 새 Markdown entry를 만든 경우 최초 hydration이 같은 regular file을
    /// 읽는지 확인하는 transient identity. workspace에는 저장하지 않으며 첫 exact-fd read 뒤 해제한다.
    initial_file_identity_device: u64 = 0,
    initial_file_identity_inode: u64 = 0,
    initial_file_identity_kind: u8 = 0,
    initial_file_identity_pending: bool = false,
    /// FSEvents가 디스크 변경을 알렸는데 source editor가 dirty라 자동 reload하지 못한 상태. 사용자의 buffer를
    /// 덮지 않으며 트리/헤더에 conflict를 표시하고 저장도 명시적 해결 전까지 거부한다.
    external_change: bool = false,
    external_change_generation: u64 = 0,
    /// 사용자 승인 뒤 실제 web read/replace 성공 ack를 기다리는 2-phase reload. 완료 전에는 dirty/conflict 보호를
    /// 유지하며 workspace에는 저장하지 않는다.
    conflict_reload_pending: bool = false,
    conflict_reload_generation: u64 = 0,
    /// atomic write 직후 dirty ack/FSEvents 순서가 뒤집혀 자기 저장을 외부 충돌로 오인하지 않게 하는 bounded latch.
    /// 첫 exact-path event가 소비하거나 grace tick이 만료하며 workspace에는 저장하지 않는다.
    self_write_grace_ticks: u16 = 0,
    self_write_hash: u64 = 0,
    self_write_verifications: u8 = 0,
    /// File-tree rename/delete reservation. Nonzero blocks bridge reads/writes, dirty reports, reload and
    /// close until the exact background request commits or rolls back. It is transient and never persisted.
    mutation_pending_id: u64 = 0,
    /// FP3 runtime handle. workspace.v1에는 저장하지 않고 복원/재소환 때 앱 전역 allocator에서 새 id를 발급한다.
    surface_id: u64 = 0,
    /// 이 entry가 **지금** CM6 브리지를 쓰는가 — read/write·dirty·저장·document epoch·외부변경 게이트가
    /// 공유하는 술어. kind에서 entry로 올린 이유는 네이티브 편집기로 연 텍스트가 같은 kind를 쓰면서
    /// 브리지를 안 쓰기 때문이다. 그것을 kind로만 판정하면, 오지 않을 CM6 응답을 기다리다 **탭이 안
    /// 닫힌다**(닫기가 dirty 스냅샷을 요구한다 — `filePanelEntryNeedsDirtyProtection`).
    pub fn usesEditorBridge(self: *const Entry) bool {
        return self.kind.usesEditorBridgeByKind() and !self.native_editor;
    }
};

/// workspace.v1에 들어가는 entry 부분집합. dirty는 파일 내용이 아니라 휘발성 편집 상태라 의도적으로 빠진다.
pub const PersistedEntry = struct {
    path: []const u8,
    kind: EntryKind,
    mode: Mode = .read,
    active: bool = false,
};

pub const PersistedState = struct {
    side: Side = .right,
    size: u32 = 0,
    collapsed: bool = false,
    view: View = .explorer,
    /// Explorer launcher로 한 번 열린 도크인지. content와 분리해 explicit-empty 도크도 재시작 뒤 유지한다.
    presented: bool = false,
    entries: []const PersistedEntry = &.{},
};

/// FP16: 도크는 **탐색기 전용**이라 그룹 트리도 파일 소유도 없다. 남은 것은 도크 자신의 배치 상태와,
/// 워크스페이스 파일을 읽어 들일 때 잠깐 드는 **평탄한 복원 목록**뿐이다. 파일 entry의 런타임 소유는
/// `session_model.Term.file_entry`이고(§1), 이 구조체는 그 entry를 만들어 넘겨 주기만 한다.
///
/// 옛 `DockGroup`/`DockTree`/drop 기계(`commitEntryDrop`·`removeGroup`·`pruneEmptyGroups`)는 "도크 안에서
/// 여러 파일을 동시에 보여 준다"는 기능이 워크스페이스 pane split으로 흡수되면서 통째로 사라졌다.
pub const DockPanel = struct {
    allocator: std.mem.Allocator,
    entry_ids: *EntryIdAllocator,
    side: Side = .right,
    size: u32 = 0,
    collapsed: bool = false,
    presented: bool = false,
    /// 지금 그리는 뷰(docs/file-explorer.md §3.5). 도크 자체의 배치 상태와 같은 급이라 여기 산다.
    view: View = .explorer,
    /// `restore`가 채우는 복원 목록. 호출자가 Term으로 **이관하면 비운다**(path 소유도 함께 넘어간다).
    restored: std.ArrayList(Entry) = .empty,
    /// 복원 당시 활성이던 entry의 index(없으면 null).
    restored_active: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator) !DockPanel {
        return .{ .allocator = allocator, .entry_ids = entry_ids };
    }

    pub fn deinit(self: *DockPanel) void {
        for (self.restored.items) |entry| self.allocator.free(entry.path);
        self.restored.deinit(self.allocator);
        self.* = undefined;
    }

    /// 아직 Term으로 이관되지 않은 복원 entry 수.
    pub fn restoredCount(self: *const DockPanel) usize {
        return self.restored.items.len;
    }

    /// 와이어 상태에서 도크 배치와 **평탄한 복원 목록**을 만든다. 옛 다중 group 배치(`groups`/`tree`)를 읽던
    /// 경로는 그 포맷 파서와 함께 제거했다(2026-07-29) — 지금 `entries`는 capture 쪽에서만 채워지고, 복원되는
    /// 파일 목록은 pane 줄의 `file-term`이 든다(docs/file-panel.md §5.0).
    pub fn restore(allocator: std.mem.Allocator, entry_ids: *EntryIdAllocator, state: PersistedState) !DockPanel {
        if (state.entries.len > max_entries) return error.InvalidPersistedState;
        var panel = try DockPanel.init(allocator, entry_ids);
        errdefer panel.deinit();
        panel.side = state.side;
        panel.size = state.size;
        panel.collapsed = state.collapsed;
        panel.presented = state.presented;
        panel.view = state.view;

        try panel.appendRestored(state.entries);
        return panel;
    }

    /// 복원 목록에 entry를 잇는다. 경로 중복·허용되지 않는 mode·빈 경로는 와이어 오류다.
    fn appendRestored(self: *DockPanel, entries: []const PersistedEntry) !void {
        for (entries) |entry| {
            if (entry.path.len == 0 or !entry.mode.allowedFor(entry.kind)) return error.InvalidPersistedState;
            for (self.restored.items) |existing| {
                if (std.mem.eql(u8, existing.path, entry.path)) return error.InvalidPersistedState;
            }
            if (self.restored.items.len >= max_entries) return error.InvalidPersistedState;
            const owned = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(owned);
            try self.restored.append(self.allocator, .{
                .id = try self.entry_ids.next(),
                .path = owned,
                .kind = entry.kind,
                .mode = entry.mode,
            });
            if (entry.active) self.restored_active = self.restored.items.len - 1;
        }
    }
};

test "EntryKind/Mode policy: markdown, html, text (FP12 §2.2)" {
    // 신뢰 편집 브리지 kind: markdown+text만. html은 격리 read-only.
    try std.testing.expect(EntryKind.markdown.usesEditorBridgeByKind());
    try std.testing.expect(EntryKind.text.usesEditorBridgeByKind());
    try std.testing.expect(!EntryKind.html.usesEditorBridgeByKind());

    // 기본 모드: markdown=읽기(라이브 백로그), html=읽기, text=소스.
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.markdown));
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.html));
    try std.testing.expectEqual(Mode.source_edit, Mode.defaultFor(.text));
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.image)); // FP14: read 뷰 전용.
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.pdf)); // FP15: read 뷰 전용.
    try std.testing.expectEqual(Mode.read, Mode.defaultFor(.media)); // FP15 media: read 뷰 전용(모드 선택기 없음).
    // media는 격리 loadFileURL(WebKit media document)이라 CM6 편집 브리지를 쓰지 않는다.
    try std.testing.expect(!EntryKind.media.usesEditorBridgeByKind());

    // 허용 모드: markdown=읽기|소스, html=read만, text=source_edit만, image/pdf=read만(격리 loadFileURL).
    try std.testing.expect(Mode.read.allowedFor(.markdown) and Mode.rich.allowedFor(.markdown) and Mode.source_edit.allowedFor(.markdown));
    // 리치는 markdown 전용이다 — svg·text는 문서모델로 다룰 대상이 아니다.
    try std.testing.expect(!Mode.rich.allowedFor(.svg) and !Mode.rich.allowedFor(.text) and !Mode.rich.allowedFor(.html));
    try std.testing.expect(Mode.read.allowedFor(.html) and !Mode.source_edit.allowedFor(.html));
    try std.testing.expect(Mode.source_edit.allowedFor(.text) and !Mode.read.allowedFor(.text));
    inline for (.{ EntryKind.image, EntryKind.media, EntryKind.pdf }) |kind| {
        try std.testing.expect(Mode.read.allowedFor(kind) and !Mode.source_edit.allowedFor(kind));
    }

    // 새 entry의 기본 모드는 항상 자기 kind에서 허용된다(복원 검증 불변식과 일치). 모든 kind를 exhaustive하게 검증한다.
    inline for (std.enums.values(EntryKind)) |kind| {
        try std.testing.expect(Mode.defaultFor(kind).allowedFor(kind));
    }
}

test "entry id allocator: monotonic nonzero and exhaustion fails closed" {
    var ids: EntryIdAllocator = .{};
    try std.testing.expectEqual(@as(EntryId, 1), try ids.next());
    try std.testing.expectEqual(@as(EntryId, 2), try ids.next());
    ids.next_id = std.math.maxInt(EntryId);
    try std.testing.expectError(error.EntryIdExhausted, ids.next());
    try std.testing.expectEqual(std.math.maxInt(EntryId), ids.next_id);
}

test "dock mode policy keeps HTML read-only and the Markdown source editor dirty-capable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Mode.read));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Mode.source_edit));
    try std.testing.expect(Mode.read.allowedFor(.markdown));
    try std.testing.expect(Mode.source_edit.allowedFor(.markdown));
    try std.testing.expect(Mode.read.allowedFor(.html));
    try std.testing.expect(!Mode.source_edit.allowedFor(.html));
    try std.testing.expect(!Mode.read.isEditable());
    try std.testing.expect(Mode.source_edit.isEditable());
    try std.testing.expect(Mode.rich.isEditable()); // 리치도 dirty/save 수명을 소비한다.
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Mode.rich));
    inline for (std.enums.values(Mode)) |mode| {
        try std.testing.expectEqual(mode, Mode.parseWorkspaceName(mode.workspaceName()).?);
    }
    try std.testing.expect(Mode.parseWorkspaceName("future") == null);
    // 폐기된 라이브 프리뷰의 wire 이름은 더 이상 mode로 파싱되지 않는다 — 옛 workspace 파일의 마이그레이션은
    // `workspace.parseDockEntry`가 소유하며, 그 경로가 없으면 도크 전체가 강등된다.
    try std.testing.expect(Mode.parseWorkspaceName(legacy_live_preview_mode_name) == null);
}

test "dock panel: restore rejects a persisted HTML editor mode" {
    var entry_ids: EntryIdAllocator = .{};
    const entries = [_]PersistedEntry{.{ .path = "/tmp/a.html", .kind = .html, .mode = .source_edit, .active = true }};
    try std.testing.expectError(error.InvalidPersistedState, DockPanel.restore(std.testing.allocator, &entry_ids, .{ .entries = &entries }));
}

test "슬롯 순서: forSlot 과 slot 이 서로의 역이다" {
    // **모든 뷰가 칸을 갖고, 칸마다 뷰가 하나다.** 뷰를 더하면 여기서 걸린다 — 그때 바의 칸 수
    // (`chrome.components.dock_view_bar.slot_count`)도 함께 봐야 한다.
    for (std.enums.values(View)) |v| {
        try std.testing.expectEqual(v, View.forSlot(v.slot()).?);
    }
    var seen = [_]bool{false} ** @typeInfo(View).@"enum".fields.len;
    var i: usize = 0;
    while (i < seen.len) : (i += 1) {
        const v = View.forSlot(i) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!seen[@intFromEnum(v)]); // 두 칸이 같은 뷰를 가리키지 않는다
        seen[@intFromEnum(v)] = true;
    }
    // 칸 수를 넘으면 없다.
    try std.testing.expectEqual(@as(?View, null), View.forSlot(seen.len));
}
