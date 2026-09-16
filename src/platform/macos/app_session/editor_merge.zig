//! S3b-1 — **3-way 병합 «모드»의 배선**(docs/editor-merge-conflicts.md §5 S3b).
//!
//! **종류가 아니라 모드다**(계약 §7 ④). 이 Term 은 계속 `kind == .editor` 이고, 여기 붙은 상태가
//! 「이 편집기는 병합을 고치는 중이다」를 뜻한다 — 비교 뷰가 `rt.editor_diff` 로 같은 자리에 선
//! 것과 같은 모양이다. 그래서 입력·찾기·저장·teardown 이 **손대지 않고** 그대로 돈다
//! (`kind == .editor` 술어가 제품 코드에만 80 곳이다 — 실측 2026-09-14).
//!
//! **세 판은 S3a 가 읽어 온다**: `.merge_stages` 기준이 `:1:`·`:2:`·`:3:` 을 읽어 `DiffResult` 에
//! 싣는다. 이 파일은 그 결과를 **Term 수명에 맞춰 들고 있을 뿐**이고, 「열 수 있나 / 2-way 로
//! 저하하나」는 중립 모듈(`session/editor/conflict.zig` 의 `StageSet`)이 혼자 소유한다.
//!
//! S3b-1 에서 화면은 **아직 편집기 하나**다(Result = 작업트리 파일). pane 넷은 S3b-2 다.

const std = @import("std");
const maru = @import("maru");

const conflict = maru.session.editor.conflict;
const merge_map = maru.session.editor.merge_map;
const dock_panel = maru.session.dock_panel;
const git_command = maru.session.git_command;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const git_backend_mod = @import("../git_backend.zig");
const git_ops = @import("git.zig");
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");
const coretext_frame_builder = @import("../coretext_frame_builder.zig");
const chrome = maru.chrome;
const chrome_editor = maru.chrome.components.editor_view;
const editor_ops = @import("editor.zig");
const editor_motion = maru.session.editor.motion;
const testing = std.testing;

/// 병합 모드 Term 하나가 드는 것.
///
/// **출처가 둘이라 해제도 둘이다**: `repo`·`rel_path` 는 세션 allocator 가 dupe 한 것이고, 세 판
/// 바이트는 워커에게서 **넘겨받은** 것이라 `worker_allocator` 로 푼다. 한 구조체 안에서 섞으면
/// heap 이 깨진다 — diff entry 가 같은 이유로 같은 규율을 적어 두었다(`freeDiffContent`).
pub const State = struct {
    /// 어느 저장소의 어느 경로인가(세션 allocator 소유). **다시 읽을 때 쓴다** — 그 사이 활성 Term 이
    /// 바뀌어도 이 Term 이 자기 쌍을 들고 있어야 남의 저장소를 읽지 않는다.
    repo: []const u8 = &.{},
    rel_path: []const u8 = &.{},
    /// 요청 짝. **늦게 온 옛 결과가 새 내용을 덮지 않게** 한다(diff 배관과 같은 규율).
    /// 0 이면 도는 요청이 없다.
    request_id: u64 = 0,
    /// `:1:` 공통 조상(워커 소유를 넘겨받는다). **비어 있는 것과 «없는 것»이 다르다** — 그 판정은
    /// 길이가 아니라 `stages` 가 답한다.
    base: []u8 = &.{},
    /// `:2:` 현재 것(ours).
    ours: []u8 = &.{},
    /// `:3:` 들어온 것(theirs).
    theirs: []u8 = &.{},
    /// 무엇을 읽었나(S3a). 「열 수 있나」·「2-way 로 저하하나」는 이 값이 답한다.
    stages: conflict.StageSet = .{},
    /// 한 판이라도 상한에서 잘렸다. 화면이 「이게 전부」라고 말하지 않게 쓴다.
    truncated: bool = false,
    /// 세 판이 도착했다.
    ready: bool = false,
    /// 읽지 못했다(충돌이 아니거나 git 이 없거나 요청을 못 걸었다).
    failed: bool = false,
    /// 세 판을 **줄로 쪼갠 것**(화면이 그리는 축). 바이트를 빌리므로 그 바이트보다 오래 살 수
    /// 없다 — `freeStages` 가 둘을 **한 단위로** 놓는다. 배열 자체는 세션 allocator 것이다.
    ///
    /// **여기서 한 번만 쪼갠다.** 매 프레임 쪼개면 큰 파일에서 프레임이 죽고(비교 뷰가 같은 이유로
    /// 같은 자리에 든다), 무엇보다 그 결과를 빌리는 행들이 프레임마다 다른 메모리를 가리킨다.
    base_lines: []const []const u8 = &.{},
    ours_lines: []const []const u8 = &.{},
    theirs_lines: []const []const u8 = &.{},
    /// 위 세 배열을 잡은 allocator(= 세션 것). 바이트 쪽과 **주인이 다르다**.
    line_allocator: ?std.mem.Allocator = null,
    /// **대응표 셋**(S3b-M) — `판 ↔ Result`. Result 문서의 줄과 세 판의 줄에서 만든다.
    ///
    /// **Result 문서가 바뀌면 낡는다.** 편집·고르기마다 다시 만든다 — 낡은 표로 옮기면 세 판이
    /// 엉뚱한 줄에 선다. 언제 만들었는지는 `map_revision` 이 기억한다(문서의 `revision` 과 대조).
    map_ours: ?merge_map.Map = null,
    map_theirs: ?merge_map.Map = null,
    map_base: ?merge_map.Map = null,
    /// 표를 만들 때의 Result 문서 개정 번호. 다르면 표가 낡았다.
    map_revision: ?u64 = null,
    /// **판의 고르기 줄**(S3b-3c) — Current·Incoming 각각. 표와 충돌 구간에서 만들므로 표와 같은
    /// 개정에 매이고(`actions_revision`), `freeMaps` 가 함께 놓는다.
    ours_hit: PaneHit = .{},
    theirs_hit: PaneHit = .{},
    base_hit: PaneHit = .{},
    actions_revision: ?u64 = null,
    /// 판의 caret(S3b-3b). **초점은 이것만으로 정해지지 않는다** — `focusedSide` 를 보라.
    pane_caret: ?PaneCaret = null,
    /// 세 판의 **가장 긴 줄의 열 수**(S6 — 가로 상한·판의 조임). stage 는 한 번 읽으면 안 바뀌므로 한 번
    /// 센다; `null` 은 「아직 안 셌다」. 셈의 규칙(탭 폭·상한)은 Result 의 `ensureMaxCols` 와 같다.
    ours_max_cols: ?u32 = null,
    theirs_max_cols: ?u32 = null,
    base_max_cols: ?u32 = null,
    /// 세 판 바이트를 **누구의 것으로 놓을까**. 워커에게서 넘겨받으므로 제품에서는 늘 워커 것이다.
    ///
    /// **상태가 스스로 기억하는 이유**: 자리마다 손으로 적으면 한 곳만 틀려도 heap 이 깨지고, 더
    /// 나쁘게는 **누수를 아예 못 잰다** — 워커 allocator(`smp_allocator`)에는 검출이 없어서, 해제를
    /// 통째로 지운 변이 둘이 그 구멍으로 살아남았다(적대적 7회차 B1·B8 실측). 상태가 들고 있으면
    /// 판정자가 검출되는 allocator 를 꽂아 그 변이를 죽일 수 있다.
    stage_allocator: std.mem.Allocator = git_backend_mod.worker_allocator,

    /// 조상이 없어 2-way 로 저하하나. **판정을 여기서 다시 적지 않는다** — 중립이 소유한다.
    pub fn degradesToTwoWay(self: State) bool {
        return self.stages.degradesToTwoWay();
    }
};

/// 한 판(Current 또는 Incoming)의 **고르기 줄과 그 판의 히트 기반 시설**(S3b-3c).
///
/// 위젯 표·동작 구간은 **그 판의 줄 축**이다(판에는 접힘이 없어 보이는 줄 = 문서 줄). 행 표와 기하는
/// **그 프레임이 그린 것**이고 Result 의 `editor_hit_rows`·`editor_hit_geom` 과 같은 이유로 렌더가
/// 굳힌다 — 판은 gutter 폭이 각자 다르고 줄바꿈이 켜지면 행↔줄이 1:1 이 아니라, Result 의 것으로
/// 대신 재면 누르는 자리가 밀린다(#3728·#3741 과 같은 뿌리 — 계약 §5 S3b-3c 공격 ③).
pub const PaneHit = struct {
    /// 판의 줄마다 위젯(없으면 `null`). 길이 = 그 판의 줄 수. **Base 판은 늘 비어 있다**(고르기가 없다).
    widgets: []?chrome_editor.content.Widget = &.{},
    /// 이름 하나가 차지하는 열 구간과 그것이 가리키는 구간·선택. `visible_line` 은 **판의 줄** 이다.
    spans: []AppSession.ConflictActionSpan = &.{},
    /// 위젯 글자(두 이름을 이은 것) — 표의 모든 위젯이 이 하나를 빌린다.
    label: []u8 = &.{},
    /// 그 프레임이 이 판에 그린 행들. 배열은 한 번 잡으면 줄이지 않는다(`rows_len` 이 유효 구간).
    hit_rows: []chrome_editor.visual_map.VisualRow = &.{},
    /// 행 → 판의 줄(접힘이 없으니 `v.line + first_line`). `hit.bodyPoint` 가 행 배열과 같은 축으로 읽는다.
    hit_lines: []u32 = &.{},
    hit_rows_len: usize = 0,
    /// 그 프레임의 판 기하 — 본문 원점(창 절대 px)과 본문 왼쪽(gutter 폭)·폭, 그리고 판의 첫 줄.
    body_x: i32 = 0,
    body_y: i32 = 0,
    content_left_px: u32 = 0,
    content_width: u16 = 0,
    first_line: usize = 0,
    /// caret 행 표(S3b-3b) — 줄마다 그 줄의 caret byte 들. 초점 판만 채운다.
    caret_rows: [][]const u32 = &.{},
    caret_byte: [1]u32 = .{0},
};

/// 세 판 중 하나(S3b-3b). `conflict.PaneSide` 는 고르기가 있는 둘만 알고, caret 은 Base 에도 선다.
pub const MergeSide = enum { current, incoming, base };

/// 판의 caret(S3b-3b) — **자리는 `RowSelection.focus` 하나다**(비교 뷰와 같은 판단: caret 을 따로 들면
/// 선택과 두 출처가 된다). 선택은 이 조각에 없어 anchor 는 늘 focus 와 같다.
pub const PaneCaret = struct {
    side: MergeSide,
    sel: maru.session.editor.selection.RowSelection,
};

/// 이 Term 이 병합 모드인가. **`kind` 로는 못 가른다**(병합 Term 도 `.editor` 다) — 그것이 §7 ④ 의
/// 답이고, 그래서 「병합인가」를 묻는 자리는 전부 이 술어를 지난다.
pub fn isMerge(term: *const Term) bool {
    return term.rt.editor_merge != null;
}

/// 이 Term 을 **병합 모드로 세운다.** 이미 세워져 있으면 옛 판을 놓고 다시 세운다(같은 Term 에
/// 다른 충돌 파일이 오는 길은 아직 없지만, 놓지 않으면 그 길이 생기는 날 누수가 된다).
pub fn begin(self: *AppSession, term: *Term, repo: []const u8, rel_path: []const u8) void {
    clear(self, term);
    // **경로를 못 복사하면 모드를 세우지 않는다.** 반쪽으로 세우면 다시 읽을 대상이 없는 병합
    // Term 이 남아, 화면이 「여는 중」에서 영영 안 풀린다.
    const repo_owned = self.allocator.dupe(u8, repo) catch return;
    const rel_owned = self.allocator.dupe(u8, rel_path) catch {
        self.allocator.free(repo_owned);
        return;
    };
    term.rt.editor_merge = .{ .repo = repo_owned, .rel_path = rel_owned };
    request(self, term);
}

/// 세 판을 백엔드에 요청한다. **실패해도 조용히 두지 않는다**(`failed`) — 그 화면은 이유를 말한다.
pub fn request(self: *AppSession, term: *Term) void {
    const state = &(term.rt.editor_merge orelse return);
    // ⚠️ **`ready`·`failed` 를 여기서 지우는 것은 오늘 관측되지 않는다**(적대적 4·5회차 실측). 부르는
    // 곳이 둘인데 하나는 갓 만든 상태(`begin`)이고, 다른 하나(tick 의 되살리기)는 **준비됐거나 실패한
    // 판을 건너뛴다**. 그래도 지우는 이유는 이 함수의 이름이 「지금 다시 읽는다」이기 때문이다 —
    // 세 번째 호출자(예: 「다시 읽기」 버튼)가 생기는 날 안 지우면 옛 판정이 새 읽기에 남는다.
    state.ready = false;
    state.failed = false;
    state.truncated = false;
    state.request_id = 0;
    if (state.repo.len == 0 or state.rel_path.len == 0) {
        state.failed = true;
        return;
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse {
        state.failed = true;
        return;
    };
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch {
            state.failed = true;
            return;
        };
    }
    self.git_request_seq += 1;
    state.request_id = self.git_request_seq;
    if (!self.git_backend.?.submitDiff(
        git_exe,
        state.repo,
        state.rel_path,
        // **rename 의 옛 경로를 쓰지 않는다**(S3a 실측): 충돌 stage 는 «지금 경로»에 실린다.
        //
        // 정직하게: 이 자리에 무엇을 넣어도 **이 층의 판정자는 안 깨어난다**(적대적 3회차 Y7 —
        // 등가). `blobSide` 가 옛 경로를 보는 것은 `side == .head` 일 때뿐이라, stage 갈래는 이
        // 인자를 아예 안 읽는다. 그 규칙을 지키는 판정자는 S3a 쪽에 있다(「rename 의 옛 경로는
        // stage 에 안 쓴다」, `test-merge-stages-e2e`). 여기서는 **뜻이 맞는 값**을 넘긴다.
        "",
        // stage 번호는 지정자가 든 리터럴이라 rev 자리가 빈다.
        "",
        "",
        .merge_stages,
        state.request_id,
        // 원격 병합은 아직 없다 — 원격 저장소에서 충돌을 고치는 길 자체가 서 있지 않다.
        null,
        "",
    )) {
        // 이미 다른 본문을 읽는 중이다. 다음 tick 에서 다시 건다(그때 슬롯이 빈다).
        state.request_id = 0;
    }
}

/// 도착한 결과를 이 Term 에 싣는다. 짝이 맞으면 **바이트 소유를 가져가고** true 를 낸다.
///
/// **짝이 안 맞으면 아무것도 안 한다** — 늦게 온 옛 결과가 새 판을 덮으면 화면이 다른 시점의 세
/// 판을 나란히 놓는다(그 그림은 틀린 것을 그럴듯하게 보여 준다).
pub fn deliver(self: *AppSession, term: *Term, result: *git_backend_mod.DiffResult) bool {
    const state = &(term.rt.editor_merge orelse return false);
    if (state.request_id == 0 or state.request_id != result.request_id) return false;
    state.request_id = 0;
    if (!result.ok) {
        state.failed = true;
        return true;
    }
    freeMaps(self, state); // 새 판이 오면 옛 표는 옛 줄을 가리킨다
    freeStages(state);
    state.base = result.base;
    state.ours = result.original;
    state.theirs = result.modified;
    state.stages = result.stages;
    state.truncated = result.truncated;
    // **줄로 쪼개는 것도 도착의 일부다** — 화면이 그릴 축이 없으면 「왔다」가 아니다. 못 쪼개면
    // 실패로 남긴다(반쪽으로 준비됐다고 하면 빈 pane 셋이 뜬다).
    // 정직하게: 「이미 쪼개 뒀으면 건너뛴다」로 바꾼 변이는 **등가**다(적대적 10회차 V8 실측) —
    // 바로 위 `freeStages` 가 줄 배열을 먼저 비우므로 그 조건이 언제나 참이다. 조건을 두지 않는
    // 이유가 그것이다: 두면 **읽는 사람이 그 순서를 다시 따라가야** 한다.
    splitAll(self, state) catch {
        state.failed = true;
        return true;
    };
    state.ready = true;
    // **실패 표시를 지운다.** 안 지우면 한 번 실패한 Term 은 판이 와도 「못 읽었다」를 띄운 채 남는다.
    state.failed = false;
    result.base = &.{};
    result.original = &.{};
    result.modified = &.{};
    self.metal_dirty = true;
    return true;
}

/// 이 Term 의 병합 상태를 놓는다. **`releaseEditorTerm` 이 문서와 같은 단위로 부른다** — 병합 판은
/// 그 문서를 고치려고 읽은 것이라 문서보다 오래 살 이유가 없다.
pub fn clear(self: *AppSession, term: *Term) void {
    const state = &(term.rt.editor_merge orelse return);
    freeMaps(self, state); // 표는 줄을 빌린다 — 줄보다 먼저 놓는다
    freePaneHits(self, state);
    freeStages(state);
    if (state.repo.len > 0) self.allocator.free(state.repo);
    if (state.rel_path.len > 0) self.allocator.free(state.rel_path);
    term.rt.editor_merge = null;
}

/// 세 판을 **줄로** 쪼갠다(화면 축). 바이트를 빌리므로 바이트와 한 단위로 산다.
fn splitAll(self: *AppSession, state: *State) !void {
    freeLines(state);
    state.line_allocator = self.allocator;
    // **Result 와 같은 줄 규칙으로**(`merge_map.splitLikeEditor`) — `diff_state.splitLines` 는 줄바꿈을
    // 붙인 채 잘라 대응표가 거짓 항등이 된다(그 함수의 주석).
    state.base_lines = try merge_map.splitLikeEditor(self.allocator, state.base);
    state.ours_lines = try merge_map.splitLikeEditor(self.allocator, state.ours);
    state.theirs_lines = try merge_map.splitLikeEditor(self.allocator, state.theirs);
}

/// 대응표 셋을 **지금 Result 문서**에 맞춰 세운다. 이미 그 개정에 맞게 서 있으면 아무 일도 안 한다.
///
/// **실패는 «표 없음»이다** — 표가 없으면 소비자는 옮기지 않는다(따라 굴리기는 0 줄로 선다). 반쪽
/// 표로 옮기는 것보다 안 옮기는 편이 정직하다.
pub fn ensureMaps(self: *AppSession, term: *Term) void {
    const state = &(term.rt.editor_merge orelse return);
    if (!state.ready) return;
    const doc = term.rt.editor_doc orelse return;
    const rev = doc.file.revision;
    if (state.map_revision) |have| if (have == rev) return;
    freeMaps(self, state);
    const result_lines = term.rt.editor_lines;
    state.map_ours = merge_map.build(self.allocator, state.ours_lines, result_lines) catch null;
    state.map_theirs = merge_map.build(self.allocator, state.theirs_lines, result_lines) catch null;
    // **조상이 없으면 표도 없다** — 빈 줄 배열과 비교하면 「전부 삭제」라는 거짓 표가 나온다.
    state.map_base = if (state.stages.has_base) (merge_map.build(self.allocator, state.base_lines, result_lines) catch null) else null;
    state.map_revision = rev;
}

/// 세 판의 가장 긴 줄(열)을 한 번 센다(S6). **Result 와 같은 셈**(`content.lineColumnsUpTo` — 탭 폭·`editor.max-columns`
/// 상한)이라 상한이 「셈이 멈춘 자리」로 같은 뜻이다. stage 바이트는 한 번 읽으면 안 바뀌므로 다시 안 센다.
pub fn ensurePaneMaxCols(term: *Term) void {
    const state = &(term.rt.editor_merge orelse return);
    if (!state.ready) return;
    const tab_width = term.rt.editor_tab_width;
    const limit = term.rt.editor_max_columns;
    inline for (.{ .{ &state.ours_max_cols, state.ours_lines }, .{ &state.theirs_max_cols, state.theirs_lines }, .{ &state.base_max_cols, state.base_lines } }) |c| {
        const slot: *?u32 = c[0];
        if (slot.* == null) {
            var max: u32 = 0;
            for (c[1]) |line| {
                max = @max(max, chrome_editor.content.lineColumnsUpTo(line, tab_width, limit));
                if (max >= limit) break; // 더 세도 답이 같다(성능 — 그 변이는 사는 것이 정상, S6 적대적 6회차 F7)
            }
            slot.* = max;
        }
    }
}

/// 네 판 중 **가장 넓은** 줄의 열 수(S6 — 가로 상한). Result 의 값은 호출자가 넘긴다(그 캐시는 편집기 것이다).
/// 판의 캐시가 아직 없으면 여기서 센다. 조상이 없으면 그 판은 안 든다.
pub fn widestCols(term: *Term, result_max_cols: u32) u32 {
    const state = &(term.rt.editor_merge orelse return result_max_cols);
    if (!state.ready) return result_max_cols;
    // `paneFirstCol` 도 세운다 — 둘 중 하나를 지워도 다른 쪽이 세워 화면이 같다(S6 적대적 9회차 I7·I8, 일부러 겹친 방어).
    // 둘 다 부르는 이유: 어느 쪽이 먼저 불리든(첫 휠 대 첫 프레임) 「안 셌다」로 답하지 않기 위해서다.
    ensurePaneMaxCols(term);
    var w = result_max_cols;
    w = @max(w, state.ours_max_cols orelse 0);
    w = @max(w, state.theirs_max_cols orelse 0);
    if (state.stages.has_base) w = @max(w, state.base_max_cols orelse 0);
    return w;
}

/// 판 하나가 그릴 가로 위치(S6): Result 의 값을 **그 판의 폭으로 조인 것**(Monaco 의 `setScrollLeft` 가 `scrollWidth −
/// width` 로 조이는 규칙). 판의 폭은 지난 프레임의 `PaneHit.content_width`(0 이면 아직 안 그렸다 — 안 조인다).
/// 판의 가장 긴 줄이 Result 보다 짧으면 그 판은 자기 끝에서 멈춘다 — 빈 화면 대신 내용의 끝이 보인다.
pub fn paneFirstCol(term: *Term, side: MergeSide, result_first_col: u32, beyond: u32) u32 {
    const state = &(term.rt.editor_merge orelse return result_first_col);
    if (!state.ready) return result_first_col; // 아직 판이 없다 — 그릴 판도 없어 관측 불가(S6 적대적 8회차 H8)
    ensurePaneMaxCols(term);
    const max_cols: u32 = switch (side) {
        .current => state.ours_max_cols orelse 0,
        .incoming => state.theirs_max_cols orelse 0,
        .base => state.base_max_cols orelse 0,
    };
    const visible: u32 = paneHitOf(state, side).content_width;
    // 아직 한 프레임도 안 그렸으면 안 조인다. **관측 불가**(S6 적대적 1회차 A16): 그 프레임에는 배치도 없어 Result 의 clamp 가
    // pane 전체 폭으로 재고 Result 값 자체를 0 으로 되돌리므로 여기 무엇을 돌려줘도 화면이 같다. 그래도 Result 값을 돌려주는
    // 이유는 뜻이다 — 「모르면 따라간다」.
    if (visible == 0) return result_first_col;
    // 빈 판(0)에는 beyond 도 안 더한다 — `scrollWidthCols` 의 「안 셌다는 안 셌다」와 같은 뜻. 화면은 같다(beyond 가 판 폭보다
    // 작아 `max_first` 가 어차피 0 — S6 적대적 6회차 F8).
    const width = if (max_cols == 0) 0 else max_cols +| beyond;
    const max_first: u32 = width -| visible;
    return @min(result_first_col, max_first);
}

/// 판의 고르기 줄을 **지금 개정**에 맞춰 세운다(S3b-3c). 표(`ensureMaps`)와 충돌 구간(`ensureConflicts`)
/// 이 이미 이 개정에 맞아 있어야 한다 — 호출자(`buildMergePaneOps`)가 그 순서를 지킨다.
///
/// **자리는 대응표의 «짝»이다**(`anchorOnSide` — 계약 §5 S3b-3c 공격 ①·②): 구간의 그 쪽 본문 첫 줄의
/// 짝 위, 본문이 비었으면 구간 다음 줄의 짝 위, 그것도 없으면 그 구간은 판에 줄이 없다(Result 줄이
/// 남는다). 표가 없는 판(too_large)도 마찬가지다.
pub fn ensurePaneHit(self: *AppSession, term: *Term) void {
    const state = &(term.rt.editor_merge orelse return);
    if (!state.ready) return;
    const rev = state.map_revision orelse return; // 표가 아직 없다 — 줄도 없다
    // **등가 변이**(적대적 2회차 B10): 이 비교를 `!= null` 로 바꿔도 답이 같다 — 표가 새로 설 때
    // `freeMaps → freeActions` 가 먼저 `actions_revision` 을 비우므로, 여기 오는 개정은 늘 「같거나 없음」
    // 이다. 그래도 개정을 비교하는 이유는 그 순서를 이 함수가 혼자 믿지 않으려는 것이다.
    if (state.actions_revision) |have| if (have == rev) return;
    freeActions(self, state);
    state.actions_revision = rev;
    const regions = term.rt.editor_conflicts;
    if (regions.len == 0) return;
    buildPaneHit(self, &state.ours_hit, .current, state.map_ours, state.ours_lines.len, regions);
    buildPaneHit(self, &state.theirs_hit, .incoming, state.map_theirs, state.theirs_lines.len, regions);
}

fn buildPaneHit(
    self: *AppSession,
    pa: *PaneHit,
    side: conflict.PaneSide,
    map: ?merge_map.Map,
    line_count: usize,
    regions: []const conflict.Region,
) void {
    const m = map orelse return;
    if (line_count == 0) return;

    // 글자와 열 구간은 **같은 함수**에서(`writeActions`) — Result 의 줄과 같은 규율. 열은 렌더가 쓰는
    // 그 규칙(`content.columnsOf`)으로 센다.
    const names = conflict.paneActionNames(side);
    var total: usize = conflict.action_gap.len;
    for (names) |n| total += n.len;
    const buf = self.allocator.alloc(u8, total) catch return;
    var name_spans: [2]conflict.ActionSpan = undefined;
    const label = conflict.writeActions(&names, buf, chrome_editor.content.columnsOf, &name_spans) orelse {
        self.allocator.free(buf);
        return;
    };
    const choices: [2]AppSession.ConflictChoice = switch (side) {
        .current => .{ .current, .both },
        .incoming => .{ .incoming, .both_incoming_first },
    };

    const table = self.allocator.alloc(?chrome_editor.content.Widget, line_count) catch {
        self.allocator.free(buf);
        return;
    };
    @memset(table, null);
    var spans: std.ArrayList(AppSession.ConflictActionSpan) = .empty;
    defer spans.deinit(self.allocator);
    for (regions, 0..) |r, ri| {
        const from: u32, const to: u32 = switch (side) {
            .current => .{ r.ours().from, r.ours().to },
            .incoming => .{ r.theirs().from, r.theirs().to },
        };
        const anchor = m.anchorOnSide(from, to, r.end + 1) orelse continue;
        if (anchor >= table.len) continue;
        table[anchor] = .{ .text = label, .col = 0 };
        for (name_spans, choices) |sp, choice| {
            spans.append(self.allocator, .{
                .visible_line = anchor,
                .region = @intCast(ri),
                .choice = choice,
                .from_col = sp.from,
                .to_col = sp.to,
            }) catch {
                self.allocator.free(buf);
                self.allocator.free(table);
                return;
            };
        }
    }
    pa.label = buf[0..label.len];
    pa.widgets = table;
    pa.spans = spans.toOwnedSlice(self.allocator) catch &.{};
}

/// 그 프레임이 판에 그린 행들과 기하를 굳힌다(S3b-3c 공격 ③ — Result 의 `storeHitRows` 와 같은 이유·
/// 같은 순간). 배열은 한 번 잡으면 줄이지 않는다.
pub fn storePaneHits(self: *AppSession, term: *Term, side: MergeSide, rows: []const chrome_editor.visual_map.VisualRow, first_line: usize) void {
    const state = &(term.rt.editor_merge orelse return);
    const lay = term.rt.editor_merge_layout orelse return;
    const pa = paneHitOf(state, side);
    const rect = (switch (side) {
        .current => lay.current,
        .incoming => lay.incoming,
        .base => lay.base,
    }) orelse {
        // 접힌 판은 클릭을 받지 않는다. **등가 변이**(적대적 3회차 C6): 이 비움을 지워도 답이 같다 —
        // `paneActionAtPoint` 가 사각이 `null` 인 판을 아예 안 본다. 그래도 비우는 이유는 낡은 행 표를
        // 「지금 화면」이라 믿는 자리가 생기는 날을 위해서다.
        pa.hit_rows_len = 0;
        return;
    };
    if (rows.len > pa.hit_rows.len) {
        const grown = self.allocator.alloc(chrome_editor.visual_map.VisualRow, rows.len) catch {
            pa.hit_rows_len = 0;
            return;
        };
        const grown_lines = self.allocator.alloc(u32, rows.len) catch {
            self.allocator.free(grown);
            pa.hit_rows_len = 0;
            return;
        };
        if (pa.hit_rows.len > 0) self.allocator.free(pa.hit_rows);
        if (pa.hit_lines.len > 0) self.allocator.free(pa.hit_lines);
        pa.hit_rows = grown;
        pa.hit_lines = grown_lines;
    }
    @memcpy(pa.hit_rows[0..rows.len], rows);
    // 행 → 줄. 판에는 접힘이 없어 상대 행에 첫 줄을 더한 것이 곧 줄이다(Result 의 `storeHitRows` 와 같은 축).
    for (rows, 0..) |v, i| pa.hit_lines[i] = @intCast(@min(@as(usize, v.line) + first_line, std.math.maxInt(u32)));
    pa.hit_rows_len = rows.len;
    pa.first_line = first_line;
    // **기하는 그 판의 것으로** — gutter 폭은 그 판의 줄 수에서 나온다(Result 와 자릿수가 다를 수 있다).
    // 배치 사각은 이미 여백 안쪽(글자 자리)이다 — 판마다 여백을 또 두지 않는다(S3b-2 정정, 2026-09-15).
    const lines_len = sideLines(state, side).len;
    const m = chrome_editor.diff_frame.sideMetrics(rect.w, rect.h, @intCast(self.cell_width_px), @intCast(self.cell_height_px));
    const geom = chrome_editor.geometry.compute(m.total_cols, lines_len, .{});
    pa.body_x = rect.x;
    pa.body_y = rect.y;
    pa.content_left_px = @as(u32, geom.contentLeft()) * @as(u32, self.cell_width_px);
    pa.content_width = geom.content.width;
}

fn paneHitOf(state: *State, side: MergeSide) *PaneHit {
    return switch (side) {
        .current => &state.ours_hit,
        .incoming => &state.theirs_hit,
        .base => &state.base_hit,
    };
}

pub fn sideLines(state: *const State, side: MergeSide) []const []const u8 {
    return switch (side) {
        .current => state.ours_lines,
        .incoming => state.theirs_lines,
        .base => state.base_lines,
    };
}

fn sideMap(state: *const State, side: MergeSide) ?merge_map.Map {
    return switch (side) {
        .current => state.map_ours,
        .incoming => state.map_theirs,
        .base => state.map_base,
    };
}

/// **초점 판**(S3b-3b — 계약 §5 S3b-3b): 판 caret 이 있고 **Result 의 selection 이 없을 때만** 그 판이다.
/// Result 를 누르거나 검색·이동이 Result 에 selection 을 세우면 판 caret 은 저절로 잠든다 — 그래서
/// Result 의 편집 경로 33 곳에 술어를 끼우지 않아도 「caret 은 판에, 글자는 Result 에」가 생기지 않는다
/// (selection 이 없으면 그 경로들은 이미 아무 일도 안 한다).
pub fn focusedSide(term: *const Term) ?MergeSide {
    const state = term.rt.editor_merge orelse return null;
    const c = state.pane_caret orelse return null;
    if (term.rt.editor_selection != null) return null;
    // **여분 커서도 selection 이다** — primary 가 없어도 여분이 남아 있으면 `insertText` 가 그 자리로
    // Result 를 고친다(적대적 1회차 A3: 판 클릭이 여분을 안 지워도 초록이었다 — 픽스처에 여분이 없었다).
    if (term.rt.editor_extra_selections.len > 0) return null;
    return c.side;
}

/// 판 본문의 한 점(창 절대 px)이 가리키는 자리. 그 판의 행 표·기하로 중립의 `hit.bodyPoint` 를 지난다.
pub const PanePoint = struct { side: MergeSide, line: u32, byte: u32 };
pub fn hitTestPaneBody(term: *const Term, x_px: f64, y_px: f64) ?PanePoint {
    const state = term.rt.editor_merge orelse return null;
    const lay = term.rt.editor_merge_layout orelse return null;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    inline for (.{ .{ lay.current, state.ours_hit, MergeSide.current }, .{ lay.incoming, state.theirs_hit, MergeSide.incoming }, .{ lay.base, state.base_hit, MergeSide.base } }) |c| {
        const rect: ?chrome.draw.Rect = c[0];
        const pa: PaneHit = c[1];
        if (rect) |r| if (insideRect(r, x_px, y_px)) {
            const n = pa.hit_rows_len;
            if (n == 0) return null;
            const lines = sideLines(&state, c[2]);
            const p = chrome_editor.hit.bodyPoint(.{
                .body_x = pa.body_x,
                .body_y = pa.body_y,
                .content_left_px = pa.content_left_px,
                .content_width = pa.content_width,
                .cell_w_px = term.rt.editor_hit_geom.cell_w_px,
                .cell_h_px = term.rt.editor_hit_geom.cell_h_px,
                .tab_width = term.rt.editor_hit_geom.tab_width,
            }, pa.hit_rows[0..n], pa.hit_lines[0..n], lines, x_px, y_px) orelse return null;
            if (p.line >= lines.len) return null;
            return .{ .side = c[2], .line = @intCast(p.line), .byte = @intCast(@min(p.byte_in_line, lines[p.line].len)) };
        };
    }
    return null;
}

/// 판을 눌러 caret 을 놓는다(S3b-3b). **Result 의 selection 을 비운다** — 그것이 초점이다(`focusedSide`).
pub fn placePaneCaret(self: *AppSession, term: *Term, x_px: f64, y_px: f64) bool {
    const p = hitTestPaneBody(term, x_px, y_px) orelse return false;
    const state = &(term.rt.editor_merge orelse return false);
    state.pane_caret = .{ .side = p.side, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = p.line, .byte = p.byte }) };
    term.rt.editor_selection = null;
    if (term.rt.editor_extra_selections.len > 0) {
        self.allocator.free(term.rt.editor_extra_selections);
        term.rt.editor_extra_selections = &.{};
    }
    self.metal_dirty = true;
    return true;
}

/// 초점 판의 caret 을 옮긴다 — 비교 뷰의 `diffMove` 와 같은 `(행, byte)` 축의 이동 일습. 편집은 없다.
/// 화면 밖으로 나가면 **Result 를 굴린다**(`toResult`) — 판은 스스로 못 굴러간다(S3b-M).
pub fn paneMove(self: *AppSession, term: *Term, how: editor_ops.Motion, extend: bool) bool {
    const side = focusedSide(term) orelse return false;
    const state = &(term.rt.editor_merge orelse return false);
    const texts = sideLines(state, side);
    if (texts.len == 0) return false;
    const c = &state.pane_caret.?;
    const RowPos = maru.session.editor.selection.RowPos;
    var sel = c.sel;
    const cur_row = @min(sel.focus.row, texts.len - 1);
    const cur_byte = @min(sel.focus.byte, texts[cur_row].len);
    const pa = paneHitOf(state, side);
    const rows: usize = @max(pa.hit_rows_len, 1);

    var pcm = editor_ops.productColumnMap(term);
    const map = pcm.map();
    const keeps_goal = switch (how) {
        .line_up, .line_down, .page_up, .page_down => true,
        else => false,
    };
    if (keeps_goal and sel.goal == .none) {
        sel.goal = editor_motion.goalAt(texts[cur_row], editor_ops.rowLine(texts[cur_row]), cur_byte, map);
    }
    const next: RowPos = switch (how) {
        .char_left => if (cur_byte > 0)
            .{ .row = cur_row, .byte = editor_motion.prevCharBoundary(texts[cur_row], cur_byte) }
        else if (cur_row > 0)
            .{ .row = cur_row - 1, .byte = texts[cur_row - 1].len }
        else
            .{ .row = 0, .byte = 0 },
        .char_right => if (cur_byte < texts[cur_row].len)
            .{ .row = cur_row, .byte = editor_motion.nextCharBoundary(texts[cur_row], cur_byte) }
        else if (cur_row + 1 < texts.len)
            .{ .row = cur_row + 1, .byte = 0 }
        else
            .{ .row = cur_row, .byte = cur_byte },
        .word_left => if (cur_byte > 0)
            .{ .row = cur_row, .byte = editor_motion.wordLeft(texts[cur_row], cur_byte) }
        else if (cur_row > 0)
            .{ .row = cur_row - 1, .byte = texts[cur_row - 1].len }
        else
            .{ .row = 0, .byte = 0 },
        .word_right => if (cur_byte < texts[cur_row].len)
            .{ .row = cur_row, .byte = editor_motion.wordRight(texts[cur_row], cur_byte) }
        else if (cur_row + 1 < texts.len)
            .{ .row = cur_row + 1, .byte = 0 }
        else
            .{ .row = cur_row, .byte = cur_byte },
        .line_start => .{ .row = cur_row, .byte = editor_motion.lineStartSmart(texts[cur_row], editor_ops.rowLine(texts[cur_row]), cur_byte) },
        .line_end => .{ .row = cur_row, .byte = texts[cur_row].len },
        .line_up, .line_down, .page_up, .page_down => blk: {
            const step: usize = if (how == .line_up or how == .line_down) 1 else rows;
            const up = (how == .line_up or how == .page_up);
            const row = if (up) cur_row -| step else @min(cur_row + step, texts.len - 1);
            break :blk .{ .row = row, .byte = editor_motion.offsetForGoal(texts[row], editor_ops.rowLine(texts[row]), sel.goal, map) };
        },
        .doc_start => .{ .row = 0, .byte = 0 },
        .doc_end => .{ .row = texts.len - 1, .byte = texts[texts.len - 1].len },
        .bracket_match => return false,
    };
    if (!keeps_goal) sel.clearGoal();
    // **선택은 이 조각에 없다** — `extend` 는 받되 늘리지 않는다(계약: 드래그·Shift 선택은 뺐다).
    _ = extend;
    const goal = sel.goal;
    sel = maru.session.editor.selection.RowSelection.at(next);
    sel.goal = goal;
    c.sel = sel;
    scrollResultForPaneCaret(term, side, next.row);
    revealPaneCaretColumn(self, term, side, texts[@min(next.row, texts.len - 1)], next.byte);
    self.metal_dirty = true;
    return true;
}

/// 초점 판의 caret 이 판의 **폭** 밖으로 나가면 Result 의 `editor_first_col` 을 옮긴다(S6 — 가로는 Result 의 값이라
/// 세 판이 따라온다). 단일 편집기의 `revealCaretColumn` 과 같은 규칙: 왼쪽으로 나가면 그 열, 오른쪽으로 나가면 그
/// 열이 마지막 칸. 상한은 그리기 직전의 clamp(Result 열 기준)와 판의 조임(`paneFirstCol`)이 건다.
/// 랩이면 가로가 없고(넷 다 0), 아직 한 프레임도 안 그렸으면(폭 0) 아무 일도 안 한다.
fn revealPaneCaretColumn(self: *AppSession, term: *Term, side: MergeSide, line: []const u8, byte: usize) void {
    if (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) return;
    const state = &(term.rt.editor_merge orelse return);
    const visible: u32 = paneHitOf(state, side).content_width;
    if (visible == 0) return;
    const col = chrome_editor.content.lineColumnsUpTo(line[0..@min(byte, line.len)], term.rt.editor_tab_width, term.rt.editor_max_columns);
    const result_col = term.rt.editor_first_col;
    const first = paneFirstCol(term, side, result_col, self.loaded_config.config.editor.scroll_beyond_last_column);
    var want: u32 = result_col;
    if (col < first) {
        want = col;
    } else if (col >= first + visible) {
        want = col + 1 - visible;
    } else return;
    if (want == result_col) return;
    term.rt.editor_first_col = want;
    self.metal_dirty = true;
}

/// 초점 판 caret 의 **Result 짝 줄**(0-based) — 판에 초점이 있을 때 「caret 줄」이 무엇이냐의 답(S5 의
/// 다음/이전 충돌이 이것을 기준으로 잰다). 초점 판이 없으면 `null`. 짝이 없으면 맨 위(`toResult` 의 규칙 —
/// 다음/이전 판정에서 `0` 과 `null` 은 같은 답을 낸다: 둘 다 「첫 구간」·「마지막 구간」. 그 변이가 사는 것이
/// 정상이다, S5 적대적 2회차 B14).
pub fn paneCaretResultLine(term: *const Term) ?u32 {
    const side = focusedSide(term) orelse return null;
    const state = &(term.rt.editor_merge orelse return null);
    const m = sideMap(state, side) orelse return null;
    const row = state.pane_caret.?.sel.focus.row;
    return m.toResult(@intCast(@min(row, std.math.maxInt(u32)))) orelse 0;
}

/// caret 이 판의 화면 밖이면 Result 를 굴려 따라오게 한다. 판의 첫 줄·행 수는 **마지막 프레임**의 것이다
/// (다음 프레임의 따라 굴리기가 `toSide` 로 새 첫 줄을 낸다).
fn scrollResultForPaneCaret(term: *Term, side: MergeSide, row: usize) void {
    const state = &(term.rt.editor_merge orelse return);
    const pa = paneHitOf(state, side);
    const rows = pa.hit_rows_len;
    if (rows == 0) return;
    const m = sideMap(state, side) orelse return;
    const first = pa.first_line;
    // 짝이 없고 앞 짝도 없으면(판 맨 위의 판만의 줄) Result 의 맨 위다 — `null` 로 두면 ⌘↑ 가 안 올라간다.
    const result_line = m.toResult(@intCast(@min(row, std.math.maxInt(u32)))) orelse 0;
    // 위로 나가면 caret 이 **첫 행**, 아래로 나가면 **마지막 행**에 서게 한다 — ↓ 한 줄에 화면이 한 페이지
    // 튀지 않는다(적대적 1회차 A10: 「보인다」만 재면 맨 위 행으로 튀어도 초록이었다).
    const want: ?usize = if (row < first)
        result_line
    else if (row >= first + rows)
        @as(usize, result_line) -| (rows - 1)
    else
        null;
    const target = want orelse return;
    const clamped = @min(target, term.rt.editor_max_top_line);
    if (clamped != term.rt.editor_first_line) {
        term.rt.editor_first_line = clamped;
        term.rt.editor_first_piece = 0;
    }
}

/// 렌더가 읽는 caret 행 표(S3b-3b) — 초점 판만 채우고, 나머지는 `null`(caret 없음).
pub fn buildPaneCarets(self: *AppSession, term: *Term, side: MergeSide) ?[]const []const u32 {
    const focused = focusedSide(term) orelse return null;
    if (focused != side) return null;
    const state = &(term.rt.editor_merge orelse return null);
    const texts = sideLines(state, side);
    if (texts.len == 0) return null;
    const c = state.pane_caret.?;
    if (c.sel.focus.row >= texts.len) return null;
    const pa = paneHitOf(state, side);
    if (pa.caret_rows.len < texts.len) {
        const grown = self.allocator.alloc([]const u32, texts.len) catch return null;
        if (pa.caret_rows.len > 0) self.allocator.free(pa.caret_rows);
        pa.caret_rows = grown;
    }
    const rows = pa.caret_rows[0..texts.len];
    for (rows) |*r| r.* = &.{};
    pa.caret_byte[0] = @intCast(@min(c.sel.focus.byte, texts[c.sel.focus.row].len));
    rows[c.sel.focus.row] = pa.caret_byte[0..1];
    return rows;
}

/// 판의 고르기 줄에서 **한 이름**을 눌렀나(창 절대 px). Result 의 `conflictActionAtPoint` 와 같은 모양이되
/// 그 판의 행 표·기하·줄 축을 쓴다.
pub fn paneActionAtPoint(term: *Term, x_px: f64, y_px: f64) ?AppSession.ConflictActionSpan {
    const state = term.rt.editor_merge orelse return null;
    const lay = term.rt.editor_merge_layout orelse return null;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const cw: f64 = @floatFromInt(@max(term.rt.editor_hit_geom.cell_w_px, 1));
    const ch: f64 = @floatFromInt(@max(term.rt.editor_hit_geom.cell_h_px, 1));
    inline for (.{ .{ lay.current, state.ours_hit }, .{ lay.incoming, state.theirs_hit } }) |c| {
        const rect: ?chrome.draw.Rect = c[0];
        const pa: PaneHit = c[1];
        if (rect) |r| if (insideRect(r, x_px, y_px)) {
            if (pa.hit_rows_len == 0 or pa.spans.len == 0) return null;
            const rel_y = y_px - @as(f64, @floatFromInt(pa.body_y));
            if (rel_y < 0) return null;
            const row: usize = @intFromFloat(rel_y / ch);
            if (row >= pa.hit_rows_len) return null;
            const v = pa.hit_rows[row];
            if (v.kind != .widget) return null;
            const rel_x = x_px - @as(f64, @floatFromInt(pa.body_x)) - @as(f64, @floatFromInt(pa.content_left_px));
            if (rel_x < 0) return null;
            const col: u32 = @intFromFloat(rel_x / cw);
            const pane_line: usize = @as(usize, v.line) + pa.first_line;
            for (pa.spans) |sp| {
                if (sp.visible_line != pane_line) continue;
                if (col >= sp.from_col and col < sp.to_col) return sp;
            }
            return null;
        };
    }
    return null;
}

fn insideRect(rect: chrome.draw.Rect, x_px: f64, y_px: f64) bool {
    const x: i64 = @intFromFloat(@floor(x_px));
    const y: i64 = @intFromFloat(@floor(y_px));
    return x >= rect.x and x < rect.x + @as(i64, @intCast(rect.w)) and
        y >= rect.y and y < rect.y + @as(i64, @intCast(rect.h));
}

fn freePaneHit(self: *AppSession, pa: *PaneHit) void {
    if (pa.widgets.len > 0) self.allocator.free(pa.widgets);
    if (pa.spans.len > 0) self.allocator.free(pa.spans);
    if (pa.label.len > 0) self.allocator.free(pa.label);
    pa.widgets = &.{};
    pa.spans = &.{};
    pa.label = &.{};
}

/// 판의 고르기 줄을 놓는다. **행 표는 남긴다** — 그것은 개정이 아니라 프레임에 매이고, 다음 프레임이
/// 덮어 쓴다(`clear` 만 `freePaneHits` 로 함께 놓는다).
fn freeActions(self: *AppSession, state: *State) void {
    freePaneHit(self, &state.ours_hit);
    freePaneHit(self, &state.theirs_hit);
    state.actions_revision = null;
}

fn freePaneHits(self: *AppSession, state: *State) void {
    inline for (.{ &state.ours_hit, &state.theirs_hit, &state.base_hit }) |pa| {
        if (pa.hit_rows.len > 0) self.allocator.free(pa.hit_rows);
        if (pa.hit_lines.len > 0) self.allocator.free(pa.hit_lines);
        if (pa.caret_rows.len > 0) self.allocator.free(pa.caret_rows);
        pa.hit_rows = &.{};
        pa.hit_lines = &.{};
        pa.caret_rows = &.{};
        pa.hit_rows_len = 0;
    }
}

fn freeMaps(self: *AppSession, state: *State) void {
    freeActions(self, state); // 고르기 줄은 표에서 나왔다 — 표보다 먼저
    if (state.map_ours) |*m| m.deinit(self.allocator);
    if (state.map_theirs) |*m| m.deinit(self.allocator);
    if (state.map_base) |*m| m.deinit(self.allocator);
    state.map_ours = null;
    state.map_theirs = null;
    state.map_base = null;
    state.map_revision = null;
}

fn freeLines(state: *State) void {
    const a = state.line_allocator orelse return;
    if (state.base_lines.len > 0) a.free(state.base_lines);
    if (state.ours_lines.len > 0) a.free(state.ours_lines);
    if (state.theirs_lines.len > 0) a.free(state.theirs_lines);
    state.base_lines = &.{};
    state.ours_lines = &.{};
    state.theirs_lines = &.{};
    state.line_allocator = null;
}

fn freeStages(state: *State) void {
    // **줄이 바이트를 빌린다** — 바이트를 놓기 전에 줄부터 놓는다. 순서를 뒤집으면 놓은 바이트를
    // 가리키는 배열이 잠깐 남고, 그 사이에 그리는 프레임이 있으면 해제된 메모리를 읽는다.
    freeLines(state);
    if (state.base.len > 0) state.stage_allocator.free(state.base);
    if (state.ours.len > 0) state.stage_allocator.free(state.ours);
    if (state.theirs.len > 0) state.stage_allocator.free(state.theirs);
    // ⚠️ **오늘 이 네 줄은 관측되지 않는다**(적대적 3회차 Y9 실측 — 등가). 부르는 곳이 둘뿐이고
    // 둘 다 곧바로 덮거나(`deliver`) 상태를 통째로 버린다(`clear`). 그래도 남겨 두는 이유는
    // 「비운다」가 이 함수의 **이름이 약속한 일**이기 때문이다 — 세 번째 호출자가 생기는 날 이
    // 줄들이 비로소 일을 하고, 없으면 그날 이중 해제가 난다.
    state.base = &.{};
    state.ours = &.{};
    state.theirs = &.{};
    state.stages = .{};
}

/// 도착한 결과 하나를 **병합 Term 들에게** 흘린다(짝이 맞는 Term 이 있으면 true).
/// 열려 있는 Term 을 훑는 것은 diff 배관과 같은 모양이다 — 그쪽은 entry 로, 이쪽은 이 상태로 짝을 맞춘다.
pub fn route(self: *AppSession, result: *git_backend_mod.DiffResult) bool {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (deliver(self, term, result)) return true;
            }
        }
    }
    return false;
}

/// 이 Term 의 탭이 무엇이라 불릴까. 병합 모드가 아니면 `null` — 호출자가 평소 라벨을 쓴다.
///
/// **파일 이름만으로는 못 가른다**: 같은 파일의 비교·편집기·병합이 한 줄에 나란히 설 수 있다
/// (`dock_panel.DiffBase.label` 이 비교 기준마다 라벨을 가르는 것과 같은 규율).
pub fn labelKey(term: *const Term) ?maru.i18n.Key {
    if (!isMerge(term)) return null;
    return .dock_merge_stages;
}

test "MRG1 병합 모드는 «종류가 아니라 상태»다 — 없으면 평범한 편집기다" {
    // 이 판정자가 지키는 것: `isMerge` 가 `kind` 를 안 본다. 종류로 가르는 순간 `kind == .editor`
    // 술어 80 곳이 전부 갈림길이 된다(계약 §7 ④).
    var term: Term = .{ .kind = .editor };
    try std.testing.expect(!isMerge(&term));
    try std.testing.expectEqual(@as(?maru.i18n.Key, null), labelKey(&term));
    term.rt.editor_merge = .{};
    try std.testing.expect(isMerge(&term));
    try std.testing.expectEqual(@as(?maru.i18n.Key, .dock_merge_stages), labelKey(&term));
    // **종류는 그대로 `.editor` 다** — 그것이 이 조각의 값이다.
    try std.testing.expectEqual(maru.session.control_surface.SurfaceKind.editor, term.kind);
    term.rt.editor_merge = null;
}

/// 판정자 전용 세션 하나(`editor_diff.zig` 의 픽스처와 같은 모양).
fn smokeSession(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    return session;
}

/// 판정자 전용: 워커가 준 것처럼 생긴 결과 하나(바이트는 **워커 allocator** 에서 나온다 — 제품이
/// 그 allocator 로 푸는 것이 계약이라, 테스트가 다른 데서 만들면 그 규율을 안 재게 된다).
fn fakeResult(request_id: u64, base: []const u8, ours: []const u8, theirs: []const u8) !git_backend_mod.DiffResult {
    // 기본은 「셋 다 왔다」 — 조상이 **빈 파일**인 경우를 재려면 아래 `fakeResultStages` 를 쓴다.
    return fakeResultStages(request_id, base, ours, theirs, .{
        .has_base = true,
        .has_ours = true,
        .has_theirs = true,
    }, false);
}

/// **「무엇이 왔나」를 내용과 «따로» 받는다.** 길이로 파생하면 「빈 조상」과 「없는 조상」이 픽스처
/// 안에서 이미 합쳐져, 그 둘을 가르는 규칙을 아무 판정자도 못 잰다(S3a 가 실측으로 가른 축이다).
fn fakeResultStages(
    request_id: u64,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    stages: conflict.StageSet,
    truncated: bool,
) !git_backend_mod.DiffResult {
    const a = git_backend_mod.worker_allocator;
    return .{
        .base = try a.dupe(u8, base),
        .original = try a.dupe(u8, ours),
        .modified = try a.dupe(u8, theirs),
        .stages = stages,
        .truncated = truncated,
        .ok = true,
        .request_id = request_id,
    };
}

test "MRG2 세 판이 도착하면 소유가 «넘어온다» — 그리고 Term 을 놓으면 함께 죽는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 7 };

    var result = try fakeResult(7, "BASE", "OURS", "THEIRS");
    defer result.deinit(git_backend_mod.worker_allocator); // 남은 것만 푼다(넘어간 것은 아래가 푼다)
    session.metal_dirty = false; // **대조군** — 도착이 실제로 다시 그리게 만드는지 본다
    try testing.expect(deliver(session, term, &result));
    // 안 알리면 판은 왔는데 **화면이 그대로**다(다음 아무 입력까지 빈 채로 남는다).
    try testing.expect(session.metal_dirty);

    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(state.ready);
    try testing.expect(!state.failed); // 성공이 실패 표시를 지운다
    try testing.expectEqualStrings("BASE", state.base);
    try testing.expectEqualStrings("OURS", state.ours);
    try testing.expectEqualStrings("THEIRS", state.theirs);
    // **자리가 뜻이다** — S3a 가 `:1:`·`:2:`·`:3:` 을 그 순서로 싣는다.
    try testing.expect(!state.degradesToTwoWay());
    // **소유가 넘어왔다**: 결과 쪽이 비어야 아래 `deinit` 이 이중 해제를 안 한다.
    try testing.expectEqual(@as(usize, 0), result.base.len);
    try testing.expectEqual(@as(usize, 0), result.original.len);
    try testing.expectEqual(@as(usize, 0), result.modified.len);
    // 요청도 풀렸다 — 안 풀면 다음 결과를 이 Term 이 또 집어삼킨다.
    try testing.expectEqual(@as(u64, 0), state.request_id);

    // 문서를 놓으면 병합 판도 함께 죽는다(`releaseEditorTerm` 이 부른다 — 여기서는 직접).
    clear(session, term);
    try testing.expect(term.rt.editor_merge == null);
}

test "MRG3 늦게 온 옛 결과는 «안» 싣는다 — 짝이 다르면 건드리지 않는다" {
    // 이 갈래가 없으면 화면이 **다른 시점의 세 판**을 나란히 놓는다. 그 그림은 틀린 것을 그럴듯하게
    // 보여 주므로 「안 보이는 것」보다 나쁘다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-late.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 9 };

    var stale = try fakeResult(8, "OLD", "OLD", "OLD"); // 8 ≠ 9
    defer stale.deinit(git_backend_mod.worker_allocator);
    try testing.expect(!deliver(session, term, &stale));
    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(!state.ready);
    try testing.expectEqual(@as(u64, 9), state.request_id); // 요청은 그대로 돈다
    // **결과는 손대지 않았다** — 소유를 안 가져갔으므로 위 `deinit` 이 전부 푼다.
    try testing.expectEqualStrings("OLD", stale.base);

    // **대조군**: 짝이 맞으면 싣는다(이 판정자가 「아무것도 안 싣는다」로 갈려도 초록이 되지 않게).
    var fresh = try fakeResult(9, "B", "O", "T");
    defer fresh.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &fresh));
    try testing.expect(term.rt.editor_merge.?.ready);
    clear(session, term);
}

test "MRG4 결과는 «짝이 맞는 그 Term» 에게만 간다 — 여럿이 열려 있어도" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const a = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-a.txt", .text);
    a.term.rt.editor_merge = .{ .request_id = 11 };
    const b = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-b.txt", .text);
    b.term.rt.editor_merge = .{ .request_id = 12 };

    var result = try fakeResult(12, "B", "O", "T");
    defer result.deinit(git_backend_mod.worker_allocator);
    try testing.expect(route(session, &result));
    // **B 가 받았고 A 는 안 받았다.** 순회가 첫 병합 Term 에게 주면 여기가 빨개진다.
    try testing.expect(b.term.rt.editor_merge.?.ready);
    try testing.expect(!a.term.rt.editor_merge.?.ready);
    try testing.expectEqual(@as(u64, 11), a.term.rt.editor_merge.?.request_id);

    // 짝이 아무 데도 없으면 아무도 안 받는다(그 결과는 호출자가 버린다).
    var orphan = try fakeResult(99, "B", "O", "T");
    defer orphan.deinit(git_backend_mod.worker_allocator);
    try testing.expect(!route(session, &orphan));

    // **다른 «탭» 에 있어도 받는다.** 순회가 첫 탭만 보면 두 번째 워크스페이스에서 연 병합은
    // 영영 「여는 중」이다(적대적 4회차 X6 이 그 자리였다).
    _ = try tab_ops.createTab(
        session,
        .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "w",
        "sh",
    );
    const c = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-c.txt", .text);
    c.term.rt.editor_merge = .{ .request_id = 13 };
    try testing.expect(session.tabs.items.len >= 2); // 픽스처가 실제로 탭을 늘렸다
    var far = try fakeResult(13, "B", "O", "T");
    defer far.deinit(git_backend_mod.worker_allocator);
    try testing.expect(route(session, &far));
    try testing.expect(c.term.rt.editor_merge.?.ready);

    clear(session, a.term);
    clear(session, b.term);
    clear(session, c.term);
}

test "MRG5 실패는 «결과로» 실린다 — 화면이 여는 중에 안 갇힌다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-fail.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 3 };
    var failed: git_backend_mod.DiffResult = .{ .ok = false, .request_id = 3 };
    try testing.expect(deliver(session, term, &failed));
    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(state.failed);
    try testing.expect(!state.ready);
    try testing.expectEqual(@as(u64, 0), state.request_id); // in-flight 가 풀렸다
    clear(session, term);
}

test "MRG6 경로를 못 들면 병합 모드를 «안» 세운다 — 반쪽으로 서지 않는다" {
    // 반쪽으로 세우면 다시 읽을 대상이 없는 병합 Term 이 남아 화면이 영영 「여는 중」이다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-empty.txt", .text);
    const term = opened.term;
    // 저장소도 경로도 있으면 선다(대조군) — git 이 없으면 `failed` 로 서지만 **상태는 선다**.
    begin(session, term, "/tmp/maru-merge-repo", "f.txt");
    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expectEqualStrings("/tmp/maru-merge-repo", state.repo);
    try testing.expectEqualStrings("f.txt", state.rel_path);
    // **저장소가 비어도** 요청을 안 건다(경로만 보면 이 축이 통째로 빈다 — 적대적 7회차 B5).
    begin(session, term, "", "f.txt");
    try testing.expect(term.rt.editor_merge.?.failed);
    try testing.expectEqual(@as(u64, 0), term.rt.editor_merge.?.request_id);

    // 빈 경로로 다시 세우면 **요청을 안 걸고 실패로 남는다**(조용히 도는 요청이 없다).
    begin(session, term, "/tmp/maru-merge-repo", "");
    const empty = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(empty.failed);
    try testing.expectEqual(@as(u64, 0), empty.request_id);
    // **실패는 래치가 아니다.** 다시 세우면 풀려야 한다 — 안 풀면 한 번 실패한 Term 은 영영
    // 「못 읽었다」를 띄운 채 남는다(파일이 멀쩡해진 뒤에도).
    begin(session, term, "/tmp/maru-merge-repo", "f.txt");
    try testing.expect(!term.rt.editor_merge.?.failed);
    clear(session, term);
}

test "MRG7 충돌 행으로 연 편집기는 «병합 모드» 로 선다 (제품 경계)" {
    // **버튼 → 이 함수**는 `SCMC1` 이 이미 든다(발행된 rect 에 포인터 → intent → 제품 핸들러).
    // 여기서 재는 것은 그다음 한 칸이다: **그 함수가 연 Term 이 병합 모드인가.** 그 배선이 끊기면
    // S3b-2 가 그릴 것을 든 Term 이 없고, 화면은 지금과 똑같아 **아무도 눈치채지 못한다.**
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    // 실제 파일이 있어야 한다 — 여는 경로가 `stat` 으로 regular file 을 확인한다.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "conflict.txt",
        .data = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic\n",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.txt", .data = "plain\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    // 백엔드는 세우되 **요청은 못 나가게** 둔다 — 이 판정자가 재는 것은 배선이지 git 왕복이 아니다
    // (실제 세 판 읽기는 `test-merge-stages-e2e` 가 진짜 충돌 저장소 위에서 잰다).
    session.git_backend = try git_backend_mod.Backend.init(session.io);
    session.git_backend.?.state.?.shutting_down = true;

    git_ops.openEditorForScmRow(session, repo, .{
        .section = .changes,
        .path = "conflict.txt",
        .letter = 'U',
        .action = .resolve,
        .conflicted = true,
    });

    const term = pane_ops.activePane(session).activeTerm();
    // ⑴ **종류는 그대로 편집기다** — 모드지 종류가 아니다(계약 §7 ④).
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.editor, term.kind);
    // ⑵ **병합 모드로 섰고 자기 쌍을 들고 있다.** 저장소·경로를 안 들면 다시 읽을 대상이 없다.
    try testing.expect(isMerge(term));
    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expectEqualStrings(repo, state.repo);
    try testing.expectEqualStrings("conflict.txt", state.rel_path);
    // ⑶ **탭이 무엇을 보는지 말한다.** 이름만이면 같은 파일의 편집기·비교·병합을 탭 줄에서 못 가른다.
    const label = try session.diffAwareLabel(allocator, term);
    defer allocator.free(label);
    // **글자 그대로 못박는다** — 「둘 다 들어 있나」로만 재면 구분자를 지운 변이가 산다
    // (적대적 4회차 X7). 문구 자체는 i18n 표가 소유하므로 여기서 조립해 비교한다.
    const want = try std.fmt.allocPrint(allocator, "conflict.txt · {s}", .{maru.i18n.t(.dock_merge_stages)});
    defer allocator.free(want);
    try testing.expectEqualStrings(want, label);

    // ⑷ **저장 표식과 «같이» 붙는다.** 병합 Term 은 고치는 중인 문서라 dirty 가 흔한데, 한쪽만
    // 나오면 「고치는 중」이나 「무엇을 고치는 중」 하나가 사라진다.
    // dirty 는 **파생값**이다(`내용 해시 != 저장 해시`) — 플래그가 없으므로 저장 해시를 흔든다.
    const saved_hash = if (term.rt.editor_doc) |d| d.saved_hash else 0;
    if (term.rt.editor_doc) |*doc| doc.saved_hash = saved_hash ^ 1;
    const dirty_label = try session.diffAwareLabel(allocator, term);
    defer allocator.free(dirty_label);
    // **자리까지 못박는다** — 표식이 뒤로 가도 「둘 다 들어 있나」로는 안 갈린다(적대적 6회차 A8).
    const want_dirty = try std.fmt.allocPrint(allocator, "{s} conflict.txt · {s}", .{
        app_session_mod.editor_dirty_marker,
        maru.i18n.t(.dock_merge_stages),
    });
    defer allocator.free(want_dirty);
    try testing.expectEqualStrings(want_dirty, dirty_label);
    if (term.rt.editor_doc) |*doc| doc.saved_hash = saved_hash;

    // ⑸ **대조군: 충돌이 «아닌» 행으로 연 편집기는 병합 모드가 아니다.** 이것이 없으면 「모든 파일이
    // 병합 모드」로 갈려도 위 셋이 전부 초록이다.
    git_ops.openEditorForScmRow(session, repo, .{
        .section = .changes,
        .path = "plain.txt",
        .letter = 'M',
        .action = .stage,
    });
    const plain = pane_ops.activePane(session).activeTerm();
    try testing.expect(!isMerge(plain));
    const plain_label = try session.diffAwareLabel(allocator, plain);
    defer allocator.free(plain_label);
    try testing.expect(std.mem.indexOf(u8, plain_label, maru.i18n.t(.dock_merge_stages)) == null);
}

test "MRG8 tick 이 걷은 결과가 병합 Term 까지 «간다» (제품 경계 — 배선)" {
    // **위 판정자들은 `route`·`deliver` 를 직접 부른다.** 그러면 tick 쪽 호출자(`drainGitStatus` 안의
    // 한 줄)가 통째로 무판정이다 — 그 줄을 지운 변이가 살아남았다(적대적 1회차 Z13). 여기서는
    // 백엔드 슬롯에 결과를 놓고 **tick 이 부르는 그 함수**를 불러, 판이 Term 까지 가는지 잰다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-tick.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 42 };

    // 워커가 막 놓고 간 것처럼 슬롯에 싣는다(실제 왕복은 `test-merge-stages-e2e` 가 잰다).
    session.git_backend.?.state.?.diff_result = try fakeResult(42, "BASE", "OURS", "THEIRS");

    git_ops.drainGitStatus(session);

    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(state.ready);
    try testing.expectEqualStrings("THEIRS", state.theirs);
    // **슬롯도 비었다** — 안 걷으면 다음 요청이 영영 거절된다(`submitDiff` 가 결과가 남아 있으면 false).
    try testing.expect(session.git_backend.?.state.?.diff_result == null);
    clear(session, term);
}

test "MRG9 «빈 조상»은 조상이다 — 저하 판정을 길이로 다시 적지 않는다" {
    // S3a 가 실측으로 가른 축이 여기까지 와야 한다: 조상이 **빈 파일**인 충돌은 `:1:` 이 멀쩡히
    // 실린다(빈 blob). 이 층에서 「내용이 비었으니 조상이 없다」로 다시 적으면 3-way 가 근거 없이
    // 2-way 로 저하한다 — 규칙은 중립(`StageSet`)이 혼자 소유해야 한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-empty-base.txt", .text);
    const term = opened.term;

    // ⑴ **빈 조상**: 내용은 0 바이트인데 `has_base` 는 참이다 → 3-way 를 유지한다.
    term.rt.editor_merge = .{ .request_id = 21 };
    var empty_base = try fakeResultStages(21, "", "OURS", "THEIRS", .{
        .has_base = true,
        .has_ours = true,
        .has_theirs = true,
    }, false);
    defer empty_base.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &empty_base));
    try testing.expectEqual(@as(usize, 0), term.rt.editor_merge.?.base.len);
    try testing.expect(!term.rt.editor_merge.?.degradesToTwoWay());

    // ⑵ **없는 조상**(add/add): 같은 0 바이트인데 `has_base` 가 거짓이다 → 2-way 로 저하한다.
    term.rt.editor_merge.?.request_id = 22;
    var no_base = try fakeResultStages(22, "", "OURS", "THEIRS", .{
        .has_base = false,
        .has_ours = true,
        .has_theirs = true,
    }, false);
    defer no_base.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &no_base));
    try testing.expectEqual(@as(usize, 0), term.rt.editor_merge.?.base.len);
    try testing.expect(term.rt.editor_merge.?.degradesToTwoWay());
    // **조상이 없어도 «준비됨» 이다.** 셋 다 와야 준비됐다고 보면 add/add 충돌은 영영 「여는 중」이다
    // — 그 충돌을 아예 못 고친다(계약 §5 S3a: 조상이 없는 것은 «정상»이다).
    try testing.expect(term.rt.editor_merge.?.ready);
    clear(session, term);
}

test "MRG10 잘린 판은 «잘렸다» 를 달고 온다 — 이게 전부라고 말하지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-trunc.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 31 };
    var cut = try fakeResultStages(31, "B", "O", "T", .{
        .has_base = true,
        .has_ours = true,
        .has_theirs = true,
    }, true);
    defer cut.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &cut));
    try testing.expect(term.rt.editor_merge.?.truncated);

    // **대조군**: 안 잘린 결과는 그 표시를 지운다(래치로 남으면 다음 파일까지 「잘렸다」가 된다).
    term.rt.editor_merge.?.request_id = 32;
    var whole = try fakeResult(32, "B", "O", "T");
    defer whole.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &whole));
    try testing.expect(!term.rt.editor_merge.?.truncated);
    clear(session, term);
}

test "MRG11 요청마다 «다른 번호» 를 받는다 — 비교 요청과도 안 겹친다" {
    // 번호가 안 늘면 두 요청이 같은 짝을 갖는다: 먼저 온 결과가 **남의 Term** 에 실린다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);
    // 슬롯을 막아 요청이 실제로 안 나가게 둔다 — 여기서 재는 것은 **번호 발급**이다.
    session.git_backend.?.state.?.shutting_down = true;

    const a = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-id-a.txt", .text);
    const b = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-id-b.txt", .text);
    const before = session.git_request_seq;
    begin(session, a.term, "/tmp/repo", "a.txt");
    const after_a = session.git_request_seq;
    begin(session, b.term, "/tmp/repo", "b.txt");
    const after_b = session.git_request_seq;
    try testing.expect(after_a > before);
    try testing.expect(after_b > after_a);
    clear(session, a.term);
    clear(session, b.term);
}

test "MRG12 진짜 충돌 저장소에서 세 판이 «병합 Term 까지» 온다 (end-to-end)" {
    // **여기까지 와야 배선이 증명된다.** 앞 판정자들은 결과를 손으로 만들어 넣으므로, 「어느 기준으로
    // 요청했나」가 통째로 무판정이다 — 기준을 `.conflict`(2-way) 로 바꾼 변이가 살아남았다(적대적
    // 3회차 Y6). 여기서는 실제 `git merge` 충돌 저장소를 만들고 제품 경로로 열어, 세 판이 실제로
    // 도착하는지 잰다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = git_backend_mod.locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = git_backend_mod.testTmpRepoPath(&repo_buf, "tmp-merge-mode") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = git_backend_mod.testRunQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = git_backend_mod.testRunQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!git_backend_mod.testMakeStageRepo(exe, repo, .content)) return error.SkipZigTest;

    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    git_ops.openEditorForScmRow(session, repo, .{
        .section = .changes,
        .path = "f.txt",
        .letter = 'U',
        .action = .resolve,
        .conflicted = true,
    });
    const term = pane_ops.activePane(session).activeTerm();
    try testing.expect(isMerge(term));

    // 워커가 끝나기를 기다리며 tick 쪽 배수를 돈다(제품이 매 프레임 하는 그 일이다).
    var spins: usize = 0;
    while (spins < 600) : (spins += 1) {
        git_ops.drainGitStatus(session);
        const st = term.rt.editor_merge orelse break;
        if (st.ready or st.failed) break;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(state.ready);
    // **자리가 뜻이다**: `:1:` 조상 · `:2:` 현재 것 · `:3:` 들어온 것(하네스가 심은 값).
    try testing.expectEqualStrings("BASE\n", state.base);
    try testing.expectEqualStrings("OURS\n", state.ours);
    try testing.expectEqualStrings("THEIRS\n", state.theirs);
    try testing.expect(!state.degradesToTwoWay());
    // **작업트리 문서는 그대로 충돌 표시가 든 파일이다**(Result 는 그것을 고치는 자리다).
    const doc = term.rt.editor_doc orelse return error.MissingDocument;
    try testing.expect(std.mem.indexOf(u8, doc.file.content, "<<<<<<<") != null);
}

test "MRG13 슬롯이 차서 못 건 요청을 tick 이 «되살린다»" {
    // 이 자리가 없으면 병합 Term 이 **영영 빈 채로** 남는다 — 비교 쪽에는 있던 규율이 병합 쪽에만
    // 없었다(적대적 4회차). 실패도 아니고 준비도 아닌 채 화면이 「여는 중」에 갇힌다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-retry.txt", .text);
    const term = opened.term;

    // **슬롯을 채워 둔다** — 안 걷힌 결과가 있으면 `submitDiff` 가 거절한다(그 규율은 backend 것이다).
    session.git_backend.?.state.?.diff_result = try fakeResult(1000, "x", "y", "z");
    begin(session, term, "/tmp/maru-merge-repo", "f.txt");
    const blocked = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expectEqual(@as(u64, 0), blocked.request_id); // 못 걸었다
    try testing.expect(!blocked.failed); // 실패도 아니다 — 다음 tick 이 다시 건다

    // **되살리기는 걷기보다 «앞»에 있다**(그 함수의 순서). 그래서 첫 tick 은 슬롯을 비우기만 하고,
    // 실제로 다시 걸리는 것은 그다음 tick 이다 — 제품이 매 프레임 그렇게 돈다.
    git_ops.drainGitStatus(session); // ① 슬롯을 걷는다(이 시점엔 아직 못 건다)
    try testing.expectEqual(@as(u64, 0), term.rt.editor_merge.?.request_id);
    git_ops.drainGitStatus(session); // ② 이제 되살린다
    const revived = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(revived.request_id != 0 or revived.failed);
    // git 이 있으면 번호가 실제로 나갔다(없는 기계에서는 `failed` 로 정직하게 선다).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (git_backend_mod.locate(&exe_buf) != null) try testing.expect(revived.request_id != 0);
    clear(session, term);
}

test "MRG14 되살리기는 «못 건 것만» 건다 — 준비된 판을 매 프레임 다시 읽지 않는다" {
    // 되살리기가 조건을 잃으면 병합 Term 하나가 **매 프레임 git 을 부른다**. 화면은 멀쩡해 보이는데
    // (같은 내용이 다시 실린다) 프레임마다 프로세스가 뜬다 — 눈에 안 보이는 종류의 고장이다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-quiet.txt", .text);
    const term = opened.term;

    // **경로를 들려 둔다.** 안 들려 주면 되살리기가 돌아도 `request` 가 조기 반환해 번호가 안 늘고,
    // 이 판정자가 「안 건다」를 증언하지 못한다(적대적 5회차에서 그 픽스처로 변이가 살아남았다).
    term.rt.editor_merge = .{
        .repo = try allocator.dupe(u8, "/tmp/maru-merge-repo"),
        .rel_path = try allocator.dupe(u8, "f.txt"),
        .ready = true,
    };
    // ⑴ **이미 준비된 판**은 다시 안 건다.
    const before_ready = session.git_request_seq;
    git_ops.drainGitStatus(session);
    try testing.expectEqual(before_ready, session.git_request_seq);
    try testing.expectEqual(@as(u64, 0), term.rt.editor_merge.?.request_id);

    // ⑵ **실패로 접은 판**도 다시 안 건다(그 화면은 이유를 말하고 멈춘다).
    term.rt.editor_merge.?.ready = false;
    term.rt.editor_merge.?.failed = true;
    git_ops.drainGitStatus(session);
    try testing.expectEqual(before_ready, session.git_request_seq);

    // ⑶ **도는 요청**도 다시 안 건다 — 걸 때마다 번호가 바뀌면 먼저 온 답이 영영 짝을 못 찾는다.
    term.rt.editor_merge.?.failed = false;
    term.rt.editor_merge.?.request_id = 77;
    git_ops.drainGitStatus(session);
    try testing.expectEqual(before_ready, session.git_request_seq);
    try testing.expectEqual(@as(u64, 77), term.rt.editor_merge.?.request_id);

    // ⑷ **대조군**: 셋 다 아닌 판은 실제로 걸린다(위 셋이 「아무것도 안 건다」로 갈려도 초록이 되지 않게).
    term.rt.editor_merge.?.request_id = 0;
    git_ops.drainGitStatus(session);
    try testing.expect(session.git_request_seq > before_ready);
    clear(session, term);
}

test "MRG15 되살리기는 «다른 탭» 의 병합 Term 도 본다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);

    _ = try tab_ops.createTab(
        session,
        .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "w",
        "sh",
    );
    try testing.expect(session.tabs.items.len >= 2); // 픽스처가 실제로 탭을 늘렸다
    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-tab2.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{
        .repo = try allocator.dupe(u8, "/tmp/maru-merge-repo"),
        .rel_path = try allocator.dupe(u8, "f.txt"),
    };
    const before = session.git_request_seq;
    git_ops.drainGitStatus(session);
    // 첫 탭만 훑으면 두 번째 워크스페이스의 병합은 영영 안 걸린다.
    try testing.expect(session.git_request_seq > before);
    clear(session, term);
}

test "MRG16 세 판은 «상태가 든 allocator» 로 놓인다 — 도착에도 teardown 에도" {
    // **이 판정자가 없으면 해제를 통째로 지운 변이가 산다.** 제품의 세 판은 워커 allocator
    // (`smp_allocator`)에서 오는데 그쪽은 누수 검출이 없어서, 「안 놓는다」가 아무 데서도 안 보였다
    // (적대적 7회차 B1·B8 실측 — 둘 다 살아남았다). 상태가 allocator 를 들고 있으므로 여기서
    // **검출되는 것**을 꽂는다. 그리고 `freeStages` 를 직접 부르지 않고 **제품 함수 둘**
    // (`deliver`·`clear`)을 지나게 한다 — 함수만 재면 그 함수를 «부르지 않는» 변이가 산다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-own.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{
        .stage_allocator = allocator,
        .request_id = 5,
        .base = try allocator.dupe(u8, "B1"),
        .ours = try allocator.dupe(u8, "O1"),
        .theirs = try allocator.dupe(u8, "T1"),
        .stages = .{ .has_base = true, .has_ours = true, .has_theirs = true },
        .ready = true,
    };

    // ⑴ **새 판이 도착하면 옛 판을 놓는다.** 안 놓으면 파일을 다시 읽을 때마다 세 조각이 샌다.
    var next: git_backend_mod.DiffResult = .{
        .base = try allocator.dupe(u8, "B2"),
        .original = try allocator.dupe(u8, "O2"),
        .modified = try allocator.dupe(u8, "T2"),
        .stages = .{ .has_base = true, .has_ours = true, .has_theirs = true },
        .ok = true,
        .request_id = 5,
    };
    try testing.expect(deliver(session, term, &next));
    try testing.expectEqualStrings("B2", term.rt.editor_merge.?.base);
    // **줄도 새 것이어야 한다.** 바이트만 갈고 줄을 그대로 두면 화면이 **옛 판**을 그리고, 더 나쁘게는
    // 놓인 바이트를 가리킨다(줄은 바이트를 빌린다).
    try testing.expectEqual(@as(usize, 1), term.rt.editor_merge.?.base_lines.len);
    try testing.expectEqualStrings("B2", term.rt.editor_merge.?.base_lines[0]);
    // **세 판이 «각자» 바이트에서 쪼개진다.** 조상만 보면 `ours` 자리에 `theirs` 를 쪼개는 변이가
    // 산다(적대적 6회차 R5 실측) — 화면에는 「현재 것」 자리에 「들어온 것」이 뜨는 결함이다.
    try testing.expectEqualStrings("O2", term.rt.editor_merge.?.ours_lines[0]);
    try testing.expectEqualStrings("T2", term.rt.editor_merge.?.theirs_lines[0]);

    // ⑵ **문서를 놓으면 판도 놓는다.** 여기서 빠뜨린 `free` 가 있으면 `testing.allocator` 가 빨개진다.
    clear(session, term);
    try testing.expect(term.rt.editor_merge == null);
}

test "MRG17 읽기에 실패해도 «이미 든 판» 은 안 버린다" {
    // 실패했다고 화면을 비우면, 잠깐 끊긴 git 호출 하나에 **보고 있던 세 판이 사라진다**. 실패는
    // 표시로 말하고 내용은 그대로 둔다 — 그래야 「다시 읽는 중」이 「아무것도 없음」이 되지 않는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-keep.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 41 };
    var good = try fakeResult(41, "BASE", "OURS", "THEIRS");
    defer good.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &good));

    term.rt.editor_merge.?.request_id = 42;
    var bad: git_backend_mod.DiffResult = .{ .ok = false, .request_id = 42 };
    try testing.expect(deliver(session, term, &bad));
    const state = term.rt.editor_merge orelse return error.MissingMergeState;
    try testing.expect(state.failed);
    // **판은 그대로다.**
    try testing.expectEqualStrings("BASE", state.base);
    try testing.expectEqualStrings("OURS", state.ours);
    try testing.expectEqualStrings("THEIRS", state.theirs);
    try testing.expect(state.stages.has_base);

    // **그리고 성공이 오면 실패 표시가 «지워진다».** 안 지우면 판이 와도 「못 읽었다」가 남는다
    // (적대적 7회차 D10 — 이 축이 통째로 없었다).
    term.rt.editor_merge.?.request_id = 43;
    var again = try fakeResult(43, "B2", "O2", "T2");
    defer again.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &again));
    try testing.expect(!term.rt.editor_merge.?.failed);
    try testing.expect(term.rt.editor_merge.?.ready);
    clear(session, term);
}

test "MRG18 되살리기는 «다른 pane» 의 병합 Term 도 본다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);

    // 탭 하나 안에서 pane 을 **둘**로 가른다 — 첫 pane 만 훑는 순회는 여기서 걸린다.
    try pane_ops.splitActivePane(session, .vertical);
    const tab = tab_ops.activeTab(session);
    try testing.expect(tab.panes.items.len >= 2); // 픽스처가 실제로 갈랐다

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-pane2.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{
        .repo = try allocator.dupe(u8, "/tmp/maru-merge-repo"),
        .rel_path = try allocator.dupe(u8, "f.txt"),
    };
    const before = session.git_request_seq;
    git_ops.drainGitStatus(session);
    try testing.expect(session.git_request_seq > before);
    clear(session, term);
}

/// 판정자 전용: 탭 스트립의 **그려질 셀**을 한 줄 글자로 뜬다(빈 칸은 공백).
///
/// **왜 셀까지 가나.** 라벨 문자열만 비교하면 「그 글자가 탭 줄에 실제로 실리는가」는 무판정이다 —
/// 이 저장소는 그 구멍으로 한 번 데었다(저장 표식을 컨트롤 플레인에만 붙여 **화면에는 점이 안
/// 나왔던** 일, `diffAwareLabel` 주석). 탭 바는 Chrome Lab 이 그리는 컴포넌트가 아니라 PNG 캡처가
/// 없으므로, **그려질 셀을 글자로 뜨는 것**이 이 표면에서 얻을 수 있는 가장 화면에 가까운 증거다.
fn renderTabStrip(allocator: std.mem.Allocator, titles: []const []const u8, cols: u16, out: []u8) ![]const u8 {
    var dl = try coretext_frame_builder.buildPaneTabBarDrawList(
        allocator,
        titles,
        cols,
        .{ .rgb = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC } },
        true, // 닫기 ✕ 고정 표시(제품과 같은 값)
        0, // 활성 탭
        .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } },
        0, // 균등분할
        0, // 스크롤 없음
        null, // rename 중 아님
    );
    defer dl.deinit(allocator);
    @memset(out, ' ');
    var end: usize = 0;
    for (dl.cells) |cell| {
        if (cell.col >= cols) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
        // 한 칸에 한 글자만 뜬다(멀티바이트는 그 칸에 겹쳐 적지 않고 뒤로 민다) — 눈으로 읽을
        // 증거를 만드는 것이 목적이라 열 정렬보다 **글자가 실렸는가**가 중요하다.
        if (end + n > out.len) break;
        @memcpy(out[end..][0..n], buf[0..n]);
        end += n;
    }
    return out[0..end];
}

test "MRG19 탭 스트립의 «그려질 셀» 에 병합 기준이 실린다 (화면 증거)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "conflict.txt",
        .data = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic\n",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_backend = try git_backend_mod.Backend.init(session.io);
    session.git_backend.?.state.?.shutting_down = true;

    git_ops.openEditorForScmRow(session, repo, .{
        .section = .changes,
        .path = "conflict.txt",
        .letter = 'U',
        .action = .resolve,
        .conflicted = true,
    });
    const term = pane_ops.activePane(session).activeTerm();
    try testing.expect(isMerge(term));

    // 탭 바가 부르는 그 함수로 라벨을 만든다(`diffAwareLabel` — 사용자가 보는 제목의 단일 자리).
    const label = try session.diffAwareLabel(allocator, term);
    defer allocator.free(label);
    var strip_buf: [512]u8 = undefined;
    const strip = try renderTabStrip(allocator, &.{label}, 40, &strip_buf);

    // **셀에 실렸다.**
    try testing.expect(std.mem.indexOf(u8, strip, maru.i18n.t(.dock_merge_stages)) != null);
    try testing.expect(std.mem.indexOf(u8, strip, "conflict.txt") != null);

    // **대조군**: 병합이 아닌 Term 의 탭 줄에는 그 기준이 «없다» — 없으면 이 판정자는 「탭 줄에는
    // 늘 그 글자가 있다」로 갈려도 초록이다.
    const plain_label = try allocator.dupe(u8, "conflict.txt");
    defer allocator.free(plain_label);
    var plain_buf: [512]u8 = undefined;
    const plain_strip = try renderTabStrip(allocator, &.{plain_label}, 40, &plain_buf);
    try testing.expect(std.mem.indexOf(u8, plain_strip, maru.i18n.t(.dock_merge_stages)) == null);

    // **언어를 갈라서도 잰다.** 이 저장소는 「영어로만 돌아 열-대-바이트 변이가 살아남은」 일을
    // 겪었다 — 한글은 한 글자가 두 칸이라 탭 폭 계산이 갈린다.
    const prev_lang = maru.i18n.lang();
    defer maru.i18n.setLang(prev_lang);
    maru.i18n.setLang(.ko);
    const ko_label = try session.diffAwareLabel(allocator, term);
    defer allocator.free(ko_label);
    var ko_buf: [512]u8 = undefined;
    const ko_strip = try renderTabStrip(allocator, &.{ko_label}, 40, &ko_buf);
    try testing.expect(std.mem.indexOf(u8, ko_strip, maru.i18n.t(.dock_merge_stages)) != null);
    // **두 언어가 실제로 다르다** — 같으면 위 단언이 「언어와 무관한 글자」를 보고 있다는 뜻이다.
    try testing.expect(!std.mem.eql(u8, ko_strip, strip));

    // 사람이 읽을 증거를 남긴다(PR 에 붙인다) — `MARU_DUMP_TAB_STRIP=1` 일 때만.
    if (std.c.getenv("MARU_DUMP_TAB_STRIP") != null) {
        std.debug.print(
            "\n[탭 스트립 · 병합 ko] |{s}|\n[탭 스트립 · 병합 en] |{s}|\n[탭 스트립 · 평범   ] |{s}|\n",
            .{ ko_strip, strip, plain_strip },
        );
    }
}

test "MRG20 쪼갠 줄은 «바이트와 한 단위» 로 산다 — 비우면 둘 다 없다" {
    // 줄 배열은 바이트를 **빌린다**. 바이트를 먼저 놓으면 놓인 메모리를 가리키는 배열이 남고, 그
    // 사이에 그리는 프레임이 있으면 해제된 메모리를 읽는다(적대적 6회차 R2 가 그 순서를 뒤집었다).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    const opened = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-merge-lines.txt", .text);
    const term = opened.term;
    term.rt.editor_merge = .{ .request_id = 51 };
    var r = try fakeResult(51, "B\n", "O\n", "T\n");
    defer r.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &r));

    const st = term.rt.editor_merge orelse return error.MissingMergeState;
    // **줄이 실제로 바이트를 가리킨다**(복사가 아니다) — 그래야 「한 단위」라는 말이 참이다.
    try testing.expectEqual(@intFromPtr(st.base.ptr), @intFromPtr(st.base_lines[0].ptr));
    try testing.expectEqual(@intFromPtr(st.ours.ptr), @intFromPtr(st.ours_lines[0].ptr));
    try testing.expectEqual(@intFromPtr(st.theirs.ptr), @intFromPtr(st.theirs_lines[0].ptr));

    clear(session, term);
    try testing.expect(term.rt.editor_merge == null);
}

test "MRG21 대응표는 «제품의 쪼개기 경로» 를 지나 선다 — 준비 전·조상 없음·재전달에서는 없다" {
    // MPN12 는 줄 배열을 손으로 쪼개 넣는다 — 그래서 `deliver` → `splitAll` 이 비교 뷰의 `splitLines`
    // (줄바꿈을 붙인 채)로 돌아가도 초록이었다(적대적 2회차 B8). 여기서는 판이 **`deliver` 로** 들어온다.
    // 같은 회차의 이웃 다섯(준비 전 표·조상 없는 base 표·매 프레임 재생성·재전달 뒤 옛 표·`map_revision`
    // 잔존)도 전부 이 상태 층의 것이라 한 판정자로 묶는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();

    // Result 문서는 **실제 파일**이어야 한다 — `ensureMaps` 는 문서의 개정 번호를 보고, 줄은 편집기가 연 것을 쓴다.
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var doc_buf: [2048]u8 = undefined;
    var doc_len: usize = 0;
    for (0..40) |k| {
        const l = try std.fmt.bufPrint(doc_buf[doc_len..], "line {d:0>3}\n", .{k});
        doc_len += l.len;
    }
    const doc = doc_buf[0..doc_len];
    try dir.dir.writeFile(testing.io, .{ .sub_path = "r.txt", .data = doc });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try dir.dir.realPath(testing.io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "r.txt" });
    defer allocator.free(path);
    const opened = try pane_ops.openFileTermInActivePane(session, path, .text);
    const term = opened.term;
    try testing.expect(term.rt.editor_doc != null);
    term.rt.editor_merge = .{ .request_id = 61 };

    // ⑴ 준비 전에는 표가 없다 — 빈 줄 배열과 비교하면 「전부 추가」라는 거짓 표가 선다.
    ensureMaps(session, term);
    try testing.expect(term.rt.editor_merge.?.map_ours == null);
    try testing.expect(term.rt.editor_merge.?.map_revision == null);

    // ⑵ ours 는 맨 위에 `EXTRA` 한 줄이 더 있고 조상은 **없다**. 판이 `deliver` 로 들어온다.
    var ours_buf: [2048]u8 = undefined;
    const ours = try std.fmt.bufPrint(&ours_buf, "EXTRA\n{s}", .{doc});
    var r1 = try fakeResultStages(61, "", ours, doc, .{ .has_base = false, .has_ours = true, .has_theirs = true }, false);
    defer r1.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &r1));
    ensureMaps(session, term);
    const st1 = term.rt.editor_merge.?;
    const m_ours = st1.map_ours orelse return error.MapNotBuilt;
    // **줄 규칙이 편집기의 것이라야** Result 10 ↔ ours 11 이다. 줄바꿈을 붙인 채 쪼개면 같은 글자가 전부
    // «다른 줄» 이 되어 첨자대로 짝지어져 10 ↔ 10 — 항등처럼 보이는 거짓 표다.
    try testing.expectEqual(@as(?u32, 11), m_ours.toSide(10));
    try testing.expectEqual(@as(?u32, 10), st1.map_theirs.?.toSide(10));
    try testing.expect(st1.map_base == null); // 조상이 없으면 그 표도 없다
    const rev1 = st1.map_revision orelse return error.MapNotBuilt;

    // ⑶ 같은 개정이면 다시 안 세운다 — 같은 표(포인터)가 남는다.
    ensureMaps(session, term);
    try testing.expect(term.rt.editor_merge.?.map_ours.?.rows.left.ptr == m_ours.rows.left.ptr);
    try testing.expectEqual(rev1, term.rt.editor_merge.?.map_revision.?);

    // ⑷ **재전달**(「다시 읽기」가 생기는 날의 경로): 옛 표는 옛 줄을 가리키므로 `deliver` 가 먼저 놓아야
    //    하고, `map_revision` 도 함께 지워야 다음 `ensureMaps` 가 「같은 개정」이라 믿고 빈 표를 남기지 않는다.
    term.rt.editor_merge.?.request_id = 62;
    var r2 = try fakeResult(62, doc, doc, doc);
    defer r2.deinit(git_backend_mod.worker_allocator);
    try testing.expect(deliver(session, term, &r2));
    try testing.expect(term.rt.editor_merge.?.map_ours == null);
    try testing.expect(term.rt.editor_merge.?.map_revision == null);
    ensureMaps(session, term);
    const st2 = term.rt.editor_merge.?;
    try testing.expectEqual(@as(?u32, 10), st2.map_ours.?.toSide(10)); // 이제 ours 도 항등
    try testing.expect(st2.map_base != null); // 조상이 왔으니 표도 선다

    clear(session, term);
    try testing.expect(term.rt.editor_merge == null);
}

test "MRG22 목록 모델은 백엔드의 마커 판정을 «판정했을 때만» 믿는다 — 못 했으면 충돌 행은 전부 → 다 (S4)" {
    // 백엔드 결과에는 「마커가 남은 경로들」과 「판정을 했는가」가 따로 실린다. 빈 목록만 보고 `+` 를 내면
    // 판정 실패(명령 실패·잘림)가 「전부 해결됨」으로 보인다 — 그 자리가 이 플랫폼 층의 한 줄이다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    const wa = git_backend_mod.worker_allocator;
    const status = "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n";
    var rows: [16]maru.session.scm_view.Row = undefined;
    var scratch: [512]u8 = undefined;

    // ⑴ 판정 못 함 + 빈 목록 → `→`.
    session.git_result = .{ .status = try wa.dupe(u8, status), .ok = true, .conflict_scan_ok = false };
    const m1 = git_ops.buildScmModel(session, &rows, &scratch) orelse return error.NoModel;
    try testing.expectEqual(maru.session.scm_view.RowAction.resolve, m1.rows[1].file.action);
    if (session.git_result) |*r| r.deinit(wa);

    // ⑵ 판정함 + 빈 목록 → `+`(완료).
    session.git_result = .{ .status = try wa.dupe(u8, status), .ok = true, .conflict_scan_ok = true };
    const m2 = git_ops.buildScmModel(session, &rows, &scratch) orelse return error.NoModel;
    try testing.expectEqual(maru.session.scm_view.RowAction.stage, m2.rows[1].file.action);
    if (session.git_result) |*r| r.deinit(wa);

    // ⑶ 판정함 + f.txt 남음 → `→`.
    session.git_result = .{ .status = try wa.dupe(u8, status), .conflict_markers = try wa.dupe(u8, "f.txt\x00"), .ok = true, .conflict_scan_ok = true };
    const m3 = git_ops.buildScmModel(session, &rows, &scratch) orelse return error.NoModel;
    try testing.expectEqual(maru.session.scm_view.RowAction.resolve, m3.rows[1].file.action);
    if (session.git_result) |*r| r.deinit(wa);
    session.git_result = null;
}

test "MRG23 「모두 스테이지」는 마커가 남은 충돌 파일을 비켜 간다 — 진짜 저장소에서 g.txt 만 올라가고 f.txt 는 UU 다 (S4b end-to-end)" {
    // `add -A` 는 unmerged 를 pathspec 제외와 무관하게 스테이지한다(실측). 그래서 미해결 충돌이 있으면 경로로
    // 건다 — 계획은 중립(`planStageAll`)이 세우고, 여기서는 **제품의 두 입구**(저장소 머리 줄·「변경 사항」 머리
    // 줄)가 그 계획을 실제 git 에 실어 보내는지, 그리고 그 결과 index 가 어떻게 되는지를 잰다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = git_backend_mod.locate(&exe_buf) orelse return error.SkipZigTest;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = git_backend_mod.testTmpRepoPath(&repo_buf, "tmp-stage-all-skip") orelse return error.SkipZigTest;
    var rm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rm_path = std.fmt.bufPrintZ(&rm_buf, "{s}", .{repo}) catch return error.SkipZigTest;
    _ = git_backend_mod.testRunQuiet(&.{ "/bin/rm", "-rf", rm_path });
    defer _ = git_backend_mod.testRunQuiet(&.{ "/bin/rm", "-rf", rm_path });
    if (!git_backend_mod.testMakeStageRepo(exe, repo, .content)) return error.SkipZigTest;
    // 충돌 옆에 평범한 변경 하나(g.txt, 추적 안 됨) — 이것이 버튼을 켜고, 이것만 올라가야 한다.
    try git_backend_mod.testWriteFileAt(repo, "g.txt", "plain\n");

    const session = try smokeSession(allocator);
    defer allocator.destroy(session);
    defer session.deinit();
    session.git_repo = try allocator.dupe(u8, repo);
    // 목록 결과는 **판정함 + f.txt 에 마커 남음** — 백엔드가 실제로 내는 모양 그대로(S4 e2e 가 그 모양을 잰다).
    const wa = git_backend_mod.worker_allocator;
    session.git_result = .{
        .status = try wa.dupe(u8, "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n? g.txt\n"),
        .conflict_markers = try wa.dupe(u8, "f.txt\x00"),
        .conflict_scan_ok = true,
        .ok = true,
    };
    defer {
        if (session.git_result) |*r| r.deinit(wa);
        session.git_result = null;
    }

    // ⑴ 저장소 머리 줄의 「모두 스테이지」 → 계획은 «경로», 건 쓰기는 `.stage` 경로 하나, 알림은 「두었습니다」.
    app_session_mod.scm_dock_ops.submitStageAllForTest(session, repo);
    try testing.expectEqual(std.meta.Tag(maru.session.scm_view.StageAllPlan).paths, session.scm_last_stage_all_plan.?);
    try testing.expectEqual(maru.session.git_write_command.Kind.stage, session.scm_last_write_kind.?);
    try testing.expectEqual(@as(usize, 1), session.scm_last_write_path_count);
    try testing.expect(session.scm_write_error != null);
    try testing.expectEqualStrings(maru.i18n.t(.scm_stage_all_skipped_conflicts), session.scm_write_error.?);
    // 쓰기가 끝나기를 기다린다(제품이 tick 마다 하는 배수).
    var spins: usize = 0;
    while (spins < 600 and session.scm_write_inflight != 0) : (spins += 1) {
        app_session_mod.scm_dock_ops.drainScmWrite(session);
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expectEqual(@as(u64, 0), session.scm_write_inflight);
    // **index 의 사실**: g.txt 는 올라갔고(`A.`), f.txt 는 여전히 `UU` 다 — `git status` 원문으로 읽는다.
    var status_out: [std.fs.max_path_bytes]u8 = undefined;
    const st = git_backend_mod.testGitStatusLines(exe, repo, &status_out) orelse return error.StatusFailed;
    try testing.expect(std.mem.indexOf(u8, st, "u UU") != null); // f.txt 는 그대로 충돌
    try testing.expect(std.mem.indexOf(u8, st, "1 A. ") != null); // g.txt 는 올라갔다

    // ⑵ 「변경 사항」 머리 줄도 같은 길이다 — 이번엔 판정 못 함(모든 충돌이 미해결) + 올릴 것 없음 → «없음» 알림.
    if (session.git_result) |*r| r.deinit(wa);
    session.git_result = .{
        .status = try wa.dupe(u8, "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n"),
        .conflict_scan_ok = false,
        .ok = true,
    };
    const seq_before = session.scm_write_seq;
    app_session_mod.scm_dock_ops.submitSectionWriteForTest(session, .{ .repo_index = 0, .section = .changes });
    try testing.expectEqual(std.meta.Tag(maru.session.scm_view.StageAllPlan).nothing, session.scm_last_stage_all_plan.?);
    try testing.expectEqual(seq_before, session.scm_write_seq); // 아무것도 안 걸었다
    try testing.expectEqualStrings(maru.i18n.t(.scm_nothing_to_stage), session.scm_write_error.?);

    // ⑶ 미해결 충돌 + 평범한 변경인데 **목록이 잘렸다** → 거절하고 이유를 말한다(반쪽을 «모두» 라 하지 않는다).
    //    잘림은 읽기 결과의 플래그에서 온다 — 안 넘기면 잘린 목록의 앞쪽만 올라간다(적대적 1회차 A11).
    if (session.git_result) |*r| r.deinit(wa);
    session.git_result = .{
        .status = try wa.dupe(u8, "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n? g.txt\n"),
        .conflict_markers = try wa.dupe(u8, "f.txt\x00"), // 미해결이라야 경로 계획이 필요하고, 그래야 잘림이 문제다
        .conflict_scan_ok = true,
        .truncated = true,
        .ok = true,
    };
    const seq_before3 = session.scm_write_seq;
    app_session_mod.scm_dock_ops.submitStageAllForTest(session, repo);
    try testing.expectEqual(std.meta.Tag(maru.session.scm_view.StageAllPlan).blocked_truncated, session.scm_last_stage_all_plan.?);
    try testing.expectEqual(seq_before3, session.scm_write_seq);
    try testing.expectEqualStrings(maru.i18n.t(.scm_stage_all_blocked_truncated), session.scm_write_error.?);

    // ⑷ **비활성 저장소**는 마커 판정이 없다(S4 한계) → 그 충돌 행은 전부 미해결로 본다. 충돌만 있는 목록이면
    //    «없음» 이지 «전부 해결 → -A» 가 아니다(적대적 2회차 B7: 빈 목록을 넘겨 «전부 해결» 로 읽은 변이가 살았다).
    app_session_mod.scm_dock_ops.seedRepoStatusForTest(session, "/other/repo", "main", "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n");
    const seq_before4 = session.scm_write_seq;
    app_session_mod.scm_dock_ops.submitStageAllForTest(session, "/other/repo");
    try testing.expectEqual(std.meta.Tag(maru.session.scm_view.StageAllPlan).nothing, session.scm_last_stage_all_plan.?);
    try testing.expectEqual(seq_before4, session.scm_write_seq);
}
