//! 네이티브 편집기의 **platform 쪽 절반** — 파일을 읽고 권한을 보는 일
//! ([native-editor-document-model.md](../../../../docs/native-editor-document-model.md) §3.5).
//!
//! **L2가 파일을 읽지 않는다.** `session/editor/`는 OS를 모르므로(§2 레이어) bytes만 다루고, 여기서
//! 읽어 넘긴다. 그래서 이 파일에 있는 것은 딱 둘이다 — 읽기와 쓰기 권한 판정.
//!
//! **기존 `readFileAlloc`을 쓰지 않는다.** 그쪽은 "작은 사용자 파일"(에이전트 기록·config) 용도라
//! **빈 파일을 `null`로 돌려주고 1 MiB에서 끊는다**. 편집기는 둘 다 어긋난다: 빈 파일도 열려야 하고
//! (§3.5 — 여는 것을 막는 이유는 UTF-8 아님 하나뿐이다), 로그·생성 파일을 못 여는 편집기는 쓸 수 없다.

const std = @import("std");
const maru = @import("maru");

const editor = maru.session.editor;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const file_panel_ops = @import("file_panel.zig");
const command_catalog = @import("../command_catalog.zig");
const Term = app_session_mod.Term;
const Pane = app_session_mod.Pane;
const pane_ops = @import("pane.zig");
const symbol_picker = @import("../symbol_picker.zig");
const tab_ops = @import("tab.zig");
const term_ops = @import("term.zig");
const find_ops = @import("find.zig");
const scroll_ops = @import("scroll.zig");
const editor_diff_ops = @import("editor_diff.zig");
const workspace_ops = @import("workspace.zig");
const chrome = maru.chrome;
const chrome_draw = maru.chrome.draw;
const editor_fold = maru.session.editor.fold;
const editor_selection = maru.session.editor.selection;
const editor_motion = maru.session.editor.motion;
const editor_column = maru.session.editor.column;
const editor_pairs = maru.session.editor.pairs;
const occurrence = maru.session.editor.occurrence;
const chrome_editor = maru.chrome.components.editor_view;
const settings_ops = @import("settings.zig");
const chrome_scroll_area = maru.chrome.ui.scroll_area;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const renderer = app_session_mod.renderer;
const diag_gate = app_session_mod.diag_gate;

/// 편집기 pane 렌더 진단 logger. MARU_DEBUG일 때 프레임 한 번의 입력(사각·문서 줄 수)과 산출(op 수·
/// 시각 행 수·lowering이 만든 셀 수)을 한 줄로 찍는다. "본문이 비었다"의 원인이 ⑴ 사각이 0이라 op이
/// 안 나온 것인지 ⑵ op은 나왔는데 셀이 0이 된 것인지 ⑶ 셀까지 갔는데 합성이 덮은 것인지를 가른다 —
/// 셋은 고치는 자리가 전부 다르다. 게이트는 diag.zig 단일 출처.
const editor_diag = std.log.scoped(.editor);

/// 읽기 상한. **§3.5는 "열지 않음이 아니라 축소"를 요구하지만**, 축소 단계(①미니맵 ②랩 ③파싱
/// ④읽기 전용)는 그것을 실제로 만드는 슬라이스에서 붙는다. 그때까지 이 값은 **메모리를 지키는
/// 임시 방벽**이고, 넘으면 읽지 않고 그 사실을 호출자에게 알린다.
///
/// **숫자는 잠정이다.** §10이 축소 임계값에는 "선행 측정 게이트는 없다"고 했으므로(버퍼 표현은 그
/// 예외다 — §3.0) 여기서도 근거 없는 값을 계약처럼
/// 굳히지 않는다 — 축소를 만드는 슬라이스에서 실측으로 정한다.
pub const read_limit_bytes: u64 = 64 << 20;

pub const OpenFileError = error{
    /// 파일을 열거나 읽지 못했다(없음·권한·I/O). **읽기 전용과 다르다** — 쓸 수 없는 파일은 열린다.
    Unreadable,
    /// 위 상한을 넘었다.
    TooLarge,
    /// UTF-8이 아니다. 다른 인코딩을 추측하지 않는다(§3.5).
    NotUtf8,
    OutOfMemory,
};

/// 문서 내용의 해시 — dirty 판정 전용.
///
/// **저장 identity가 아니다.** 저장 경로는 inode와 `stableOpenedFileHash`로 외부 변경을 잡고
/// (그쪽은 디스크를 읽는다), 이 함수는 **메모리 안 두 상태가 같은가**만 답한다.
fn contentHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// 구문 강조 색(§5.3 1층). **`syntax` 모듈이 여기서 처음 제품에 들어온다** — 그 전까지는
/// 모듈만 서 있고 부르는 코드가 없어 exe에 링크되지 않았다.
pub const syntax_color = @import("editor_syntax.zig");

pub const Opened = struct {
    /// 열린 문서. **읽어 온 bytes를 빌리지 않고 소유한다**(N2 — `edit_doc.EditableFile`).
    ///
    /// **`bytes` 필드가 없어졌다.** 읽기 전용이던 동안에는 문서가 읽기 버퍼를 빌려 썼고 그래서 그
    /// 버퍼가 문서보다 오래 살아야 했다. 이제 문서가 자기 내용을 들므로 읽기 버퍼는 `openPath`가
    /// 끝나면 놓는다 — 파일이 `stat`과 read 사이에 줄어들어 생기던 "안 쓰는 꼬리"도 함께 사라진다.
    file: editor.edit_doc.EditableFile,

    /// **마지막으로 디스크와 같았던 내용의 해시.** dirty 판정의 유일한 근거다.
    ///
    /// **개정 번호가 아니라 내용이다**([file-panel.md](../../../docs/file-panel.md) §1이 소유하는
    /// 계약): *"편집 뒤 undo로 snapshot과 같은 내용에 돌아오면 revision이 더 높아도 clean"*.
    /// 개정 번호로 재면 열 번 고치고 열 번 되돌린 문서가 dirty로 남아, 사용자가 **바꾼 것이 없는데
    /// 저장하라는 표시**를 본다.
    ///
    /// **해시인 이유**: 사본을 들면 문서 하나에 메모리가 두 배가 되고(§3.0이 잰 2.7배 위에 또
    /// 얹힌다), 큰 파일에서 매 키 입력마다 전체 비교가 돈다. 해시는 충돌 가능성이 있지만 그 대가는
    /// *"바뀌었는데 clean으로 보인다"*가 아니라 **저장 버튼을 한 번 더 누르는 것**이다 — 저장
    /// 자체는 내용을 그대로 쓴다.
    saved_hash: u64,

    /// 지금 내용이 마지막 저장과 다른가.
    pub fn isDirty(self: Opened) bool {
        return contentHash(self.file.content) != self.saved_hash;
    }

    pub fn deinit(self: *Opened, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.file.deinit();
    }
};

/// 경로를 읽어 편집기 문서로 연다.
///
/// **쓸 수 없는 파일도 연다** — 읽기 전용으로 표시할 뿐이다(§3.5: "보는 것은 되어야 한다").
pub fn openPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) OpenFileError!Opened {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.Unreadable;
    defer file.close(io);

    const size = (file.stat(io) catch return error.Unreadable).size;
    if (size > read_limit_bytes) return error.TooLarge;

    // **빈 파일도 연다.** `alloc(0)`은 빈 슬라이스를 주고, `document.open`이 그것을 한 줄짜리
    // 문서로 해석한다 — 새 파일을 만들자마자 여는 흐름이 그렇게 생긴다.
    const buf = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    // **읽기 버퍼는 이 함수 안에서만 산다**(문서가 내용을 소유하게 된 뒤로 — N2). 성공하든 실패하든
    // 여기서 놓으므로 `defer`다. 앞서 `errdefer`와 `defer`가 **둘 다** 걸려 있어 오류 경로에서
    // 두 번 놓았고 세그폴트가 났다(적대적 검증 2026-08-25) — 읽기 전용이던 시절 문서가 이 버퍼를
    // 빌려 쓰던 흔적이 `errdefer` 쪽이다.
    defer allocator.free(buf);
    // **짧게 읽히면 그만큼만 문서가 된다.** `readPositionalAll`은 EOF에서 조용히 멈추므로(`amt == 0`
    // 이면 break) 파일이 `stat`과 여기 사이에 줄어들면 `n < size`가 되고, 우리는 그 시점의 실제
    // 내용을 여는 셈이라 화면은 거짓을 보이지 않는다.
    //
    // **저장이 붙으면 달라진다(N2).** 잘린 버퍼를 원문으로 알고 되쓰면 파일이 그만큼 잘린다 —
    // 그때는 `n != size`를 에러로 올리거나 다시 읽어야 한다. 읽기 전용인 지금은 그 판정을 만들지
    // 않는다(없는 계약을 여기서 지어내지 않는다).
    const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;

    const opened = editor.edit_doc.EditableFile.init(allocator, buf[0..n], !isWritable(path)) catch |e| switch (e) {
        error.NotUtf8 => return error.NotUtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // 방금 읽어 온 그대로다 — **여는 순간은 clean**이다.
    return .{ .file = opened, .saved_hash = contentHash(opened.content) };
}

/// 이 경로에 쓸 수 있는가. **여는 것을 막는 판정이 아니라 표시할 값**이다.
fn isWritable(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0].ptr, std.posix.W_OK) == 0;
}

/// 편집기 프레임 한 번의 산출물.
pub const PaneFrame = struct {
    /// 배경·스크롤바 quad와 텍스트 op. 호출자가 lowering으로 내린다.
    ops: []const chrome_draw.Op,
    ops_len: usize,
    /// 그린 시각 행 수(스크롤 clamp용).
    visual_rows: usize,
    /// 비교 뷰에서 **각 열이 채운 행 수**(단일 편집기면 0). 좌우 행 배열을 따로 굳히는 데 쓴다 —
    /// `visual_rows`는 둘 중 큰 값이라 어느 쪽이 몇 줄인지 모른다(§4.1g "비교 뷰").
    left_visual_rows: usize = 0,
    right_visual_rows: usize = 0,
    /// **문서 전체**의 시각 행 수(랩 포함). 렌더만 접힘을 아므로, 스크롤 입력이 쓰도록 함께 낸다.
    total_visual_rows: u32,
    /// 스크롤 **상한** `(줄, 조각)` — 같은 이유로 함께 낸다(§4.1d).
    max_top_line: usize,
    max_top_piece: u32,
    /// 그린 막대의 기하(**pane 상대 좌표**). 드래그가 이것을 잡는다 — 호출자가 pane 원점을 더해
    /// 창 좌표로 옮긴 뒤 `rt`에 싣는다(포인터는 창 좌표로 온다).
    ///
    /// 스크롤이 필요 없으면 `null`이고 그때는 막대도 없다.
    scrollbar: ?chrome.ui.scroll_area.ScrollbarGeometry = null,
    horizontal_scrollbar: ?chrome_editor.scrollbar.HorizontalGeometry = null,
    /// 비교 뷰 오른쪽 열의 짝(단일 편집기는 `null`).
    right_scrollbar: ?chrome.ui.scroll_area.ScrollbarGeometry = null,
    right_horizontal_scrollbar: ?chrome_editor.scrollbar.HorizontalGeometry = null,
};

/// 편집기 프레임에 필요한 호출자 소유 저장소. 한 프레임 안에서만 유효하다.
///
/// **컴포넌트의 것을 그대로 쓴다**(별칭). 같은 모양을 여기서 다시 선언하면 Zig에서 다른 타입이 되어,
/// 제품과 컴포넌트 사이에 뜻 없는 변환이 하나 생긴다.
pub const FrameScratch = chrome_editor.frame.Scratch;

/// 한 열이 쓸 자리에서 나오는 값들은 **컴포넌트가 소유한다**(`diff_frame.sideMetrics`) — 제품과
/// Chrome Lab이 같은 값을 써야 캡처가 제품을 예고한다.
const diff_frame = chrome_editor.diff_frame;

/// pane 사각과 셀 크기로 편집기 op을 만든다. 반환값은 `scratch.ops[0..ops_len]`이 유효하다는 뜻이다.
/// 보이는 줄의 **구문 강조 색**(§5.3 1층). 없으면 무색이다.
///
/// **보이는 범위만 묻는다.** 실측으로 전 문서 질의가 154KB에서 11ms인데 창 질의는 34~148µs다 —
/// §5.3이 LSP 층에 정한 *"보이는 범위만 요청한다"*와 같은 논리이고, 화면 밖 결과는 소비되지 않는다.
///
/// **비교 뷰는 빈 것을 낸다** — 문서가 둘이라 provider도 둘이어야 하고, 그 축을 가르는 것은 좌우
/// 히트테스트가 선 뒤의 일이다(`search_marks`가 같은 이유로 같은 자리에 있다).
/// 이동 스택 한 항목(§5.2). **Term 포인터가 아니라 surface id 다** — 그 Term 이 닫힐 수 있다.
pub const NavMark = struct {
    surface_id: u64,
    offset: usize,
};

/// 이동 대상(§5.2). **출처는 여기 안 온다** — 정의로 이동이든 진단 클릭이든 심볼 피커든 같은 값을
/// 넘기고, 이 경로는 누가 불렀는지 모른다. 출처마다 분기가 생기면 「경로는 하나다」가 이름만 남는다.
pub const NavTarget = struct {
    /// `null` 이면 **지금 문서 안**의 이동이다(줄 번호로 이동·심볼 피커). 파일 열기가 없을 뿐 같은 경로다.
    path: ?[]const u8 = null,
    /// range 의 **시작** byte offset. 끝은 지금 쓰지 않는다 — §5.2 가 요구하는 것은 「caret 을 range
    /// 시작에 놓는다」 이고, 범위 선택은 그 위에 얹을 별도 결정이다.
    offset: usize,
};

pub const NavError = error{
    /// root 밖이라 열지 않았다(§5.2 — 표시와 접근을 가른다).
    OutsideRoot,
    /// 그 경로를 못 열었다.
    Unopenable,
    /// 편집기 Term 이 아니거나 문서가 없다.
    NoDocument,
};

/// **`(URI?, range)` 하나로 수렴하는 진입점**(§5.2). 정의로 이동·진단 클릭·검색 결과·심볼로 이동이
/// 전부 여기로 온다.
///
/// **순서가 계약이다 — 열기 → 펴기 → caret → 스크롤.** 뒤집으면 「화면에 없는 곳으로 caret 만
/// 옮기는」 상태가 되고, 사용자는 아무 일도 안 일어난 것으로 본다.
///
/// **이미 있는 것을 다시 짓지 않는다.** 열기·유일성은 `pane.openFileTermInActivePane` 이, 펴기와
/// 스크롤은 `revealFoldedLine`·`revealPrimaryCaretRows` 가 갖고 있고 **그 둘은 이미 적대적 검증을
/// 거쳤다**(각자의 머리말이 그 이력을 든다). 새 경로가 그것을 우회하면 그 결함들이 되돌아온다.
pub fn navigateTo(self: *AppSession, target: NavTarget) NavError!void {
    // ⑴ **떠나기 전 자리를 먼저 잡는다.** 아래에서 pane 활성이 바뀌면 「직전 위치」를 못 구한다.
    const from = currentNavMark(self);

    // ⑵ 열기. 경로가 없으면 지금 Term 안의 이동이다.
    const term = if (target.path) |path| blk: {
        if (!withinNavRoot(self, path)) return error.OutsideRoot;
        const opened = pane_ops.openFileTermInActivePane(self, path, .text) catch return error.Unopenable;
        break :blk opened.term;
    } else pane_ops.activePane(self).activeTerm();

    if (term.kind != .editor) return error.NoDocument;
    const doc = term.rt.editor_doc orelse return error.NoDocument;
    const offset = @min(target.offset, doc.file.content.len);

    // ⑶ **실제로 움직일 때만 쌓는다.** 같은 자리를 여러 번 부른 뒤 뒤로가 먹통처럼 보이지 않게.
    if (from) |mark| {
        const same_spot = mark.surface_id == term.surfaceId() and mark.offset == offset;
        if (!same_spot) {
            pushNavMark(self, mark);
            // **새로 이동하면 앞으로 스택을 버린다**(브라우저와 같은 규약).
            self.editor_nav_forward.clearRetainingCapacity();
        }
    }

    placeCaretAndReveal(self, term, offset);
}

/// caret 을 놓고 그 자리를 드러낸다 — 위 ⑷⑸에 해당한다. **`revealPrimaryCaretRows` 가 펴기까지
/// 한다**(그 함수가 `revealFoldedLine` 을 먼저 부른다) — 여기서 또 펴면 같은 일을 두 번 한다.
fn placeCaretAndReveal(self: *AppSession, term: *Term, offset: usize) void {
    clearExtraSelections(self, term);
    term.rt.editor_selection = editor_selection.Selection.at(offset);
    revealPrimaryCaret(self, term);
    self.metal_dirty = true;
}

/// 지금 커서 자리를 스택 항목으로. 편집기가 아니거나 커서가 없으면 `null`(쌓을 것이 없다).
fn currentNavMark(self: *AppSession) ?NavMark {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return null;
    _ = term.rt.editor_doc orelse return null;
    const sel = term.rt.editor_selection orelse return null;
    return .{ .surface_id = term.surfaceId(), .offset = sel.focus };
}

/// **상한을 둔다.** 무한히 쌓으면 오래 켜 둔 창에서 계속 자란다 — 오래된 쪽부터 버린다.
pub const nav_stack_max: usize = 64;

fn pushNavMark(self: *AppSession, mark: NavMark) void {
    self.editor_nav_back.append(self.allocator, mark) catch return;
    if (self.editor_nav_back.items.len > nav_stack_max) {
        _ = self.editor_nav_back.orderedRemove(0);
    }
}

/// **root 밖은 열지 않는다**(§5.2 — 표시와 접근을 가른다). 판정의 단일 출처는
/// `repo_path.underRoot` 이고, breadcrumb 표시가 쓰는 그 함수다.
///
/// **root 를 모르면 막지 않는다** — 저장소 밖에서 파일 하나만 열어 쓰는 경우가 그것이고, 그때
/// 「밖」이라는 개념 자체가 없다.
fn withinNavRoot(self: *AppSession, path: []const u8) bool {
    const root = self.git_repo orelse (self.file_tree.rootAt(0) orelse return true);
    if (root.len == 0) return true;
    return maru.session.repo_path.underRoot(path, root);
}

/// **뒤로 간다**(§5.2). 닫힌 Term 을 가리키는 항목은 **버리고 다음으로** 간다 — 닫힌 파일을
/// 되살리는 것은 「이동」이 아니라 「열기」다. 갈 곳이 없으면 `false`.
pub fn navigateBack(self: *AppSession) bool {
    return navigateStep(self, &self.editor_nav_back, &self.editor_nav_forward);
}

/// **앞으로 간다**(§5.2).
pub fn navigateForward(self: *AppSession) bool {
    return navigateStep(self, &self.editor_nav_forward, &self.editor_nav_back);
}

fn navigateStep(
    self: *AppSession,
    from_stack: *std.ArrayList(NavMark),
    to_stack: *std.ArrayList(NavMark),
) bool {
    while (from_stack.items.len > 0) {
        const mark = from_stack.pop().?;
        const term = term_ops.termBySurfaceId(self, mark.surface_id) orelse continue; // 닫혔다 — 버린다
        if (term.kind != .editor) continue;
        const doc = term.rt.editor_doc orelse continue;

        // **반대쪽에 지금 자리를 남긴다** — 그러지 않으면 한 번 뒤로 간 뒤 돌아올 수 없다.
        if (currentNavMark(self)) |here| to_stack.append(self.allocator, here) catch {};

        focusTermForNav(self, term);
        placeCaretAndReveal(self, term, @min(mark.offset, doc.file.content.len));
        return true;
    }
    return false;
}

/// 그 Term 이 있는 pane/탭으로 옮긴다 — 열기 경로가 쓰는 것과 같은 단일 출처다.
fn focusTermForNav(self: *AppSession, term: *Term) void {
    _ = self.activateExistingFileTerm(term);
}

/// 헤더 밴드에 그릴 `경로 › 바깥 › 안쪽` 한 줄(§7.5 「체인이 밴드에 선다」). 체인이 없으면 `path` 를
/// 그대로 돌려주므로 **호출자는 분기하지 않는다** — 그 경우 밴드는 지금까지와 글자 하나 다르지 않다.
///
/// **비교 뷰는 체인이 없다** — 문서가 둘이라 provider 도 둘이어야 하고, 그 축을 가르는 것은 좌우
/// 히트테스트가 선 뒤의 일이다(`syntaxColors` 가 같은 이유로 같은 자리에서 같은 판정을 한다).
///
/// **커서가 여럿이면 primary 만 본다.** 체인은 "지금 여기" 를 말하는 표시인데 커서마다 하나씩 그리면
/// 그 문장이 성립하지 않는다.
pub fn headerBreadcrumb(self: *AppSession, term: *Term, path: []const u8) []const u8 {
    if (term.rt.editor_diff != null) return path;
    const doc = term.rt.editor_doc orelse return path;
    const sel = term.rt.editor_selection orelse return path;
    const focus = @min(sel.focus, doc.file.content.len);
    return syntax_color.breadcrumb(&term.rt.editor_syntax, self.allocator, path, doc.file.content, focus);
}

fn syntaxColors(self: *AppSession, term: *Term) []const []const chrome_editor.content.ColorSpan {
    if (term.rt.editor_diff != null) return &.{};
    const doc = term.rt.editor_doc orelse return &.{};

    // **끊긴 파싱을 이 프레임 몫만큼 이어 판다**(§2.1a). 여는 파싱이 한 프레임에 안 끝나는 문서가
    // 있으므로(690KB `build.zig` 실측 ~50ms) 프레임마다 예산만큼만 판다. 아직 남았으면 **다음 프레임을
    // 부른다** — 그러지 않으면 idle skip이 도는 순간 파싱이 거기서 멈춰 색이 영영 안 온다.
    //
    // **여기 두는 이유**: 이 함수가 색을 만드는 유일한 자리이고 프레임마다 불린다. 별도 tick 훅을
    // 두면 "언제 이어 파는가"의 출처가 둘이 된다.
    // **파기 전에 pending 을 기억한다.** 아래 `resumeParse` 는 **아직 파는 중**일 때 참이라, 그
    // 반환값만 보면 **끝나는 프레임을 놓친다** — 그런데 목록이 채워지는 것이 바로 그 프레임이다
    // (`SP11` 이 그 자리를 잡았다: 훅을 참 갈래에만 두었더니 목록이 영영 비었다).
    const was_pending = term.rt.editor_syntax.pending;
    if (syntax_color.resumeParse(&term.rt.editor_syntax, doc.file.content)) {
        self.metal_dirty = true;
    }
    // **피커가 열려 있고 방금 전까지 파던 중이었으면 목록을 다시 만든다**(§7.5 저하 — 「아직 모른다」의
    // 기제). 파싱이 끝나는 순간 검색어는 그대로라 아무것도 재필터를 촉발하지 않는다. `pending` 이
    // 풀린 다음 프레임부터는 `was_pending` 이 거짓이라 안 돈다 — 상주 비용이 아니라 **여는 순간의
    // 짧은 창**이다.
    if (was_pending and self.chrome_host.symbol_picker.open) recomputeSymbolPicker(self);
    if (!term.rt.editor_syntax.pending) {
        // **파싱이 끝난 프레임에 접힘을 구문 층으로 덮는다**(§4). 여는 자리에서는 트리가 아직
        // 없을 수 있어(§2.1a) 들여쓰기로 세웠고, 여기가 그 두 번째 갱신 시점이다.
        promoteFoldRangesToSyntax(self, term);
    }

    const first = term.rt.editor_first_line;
    // **길이 판정도 렌더 축이다.** 접히면 보이는 줄이 문서 줄보다 적어, 문서 수로 재면 화면 끝
    // 근처에서 실제보다 많은 줄을 요구하게 된다.
    const axis_len = if (term.rt.editor_visible_numbers.len > 0)
        term.rt.editor_visible_numbers.len
    else
        term.rt.editor_lines.len;
    if (first >= axis_len) return &.{};
    // 화면 높이를 모르는 자리라 **넉넉히** 잡는다 — 랩이 켜지면 논리 줄 하나가 여러 행이 되므로
    // 보이는 논리 줄은 행 수보다 적다. 남는 줄의 색은 만들어도 안 그려질 뿐이고, 모자라면 화면
    // 아래가 무색이 된다.
    const budget: usize = 256;
    const count = @min(budget, axis_len - first);
    return syntax_color.lineColors(
        &term.rt.editor_syntax,
        self.allocator,
        doc.file.content,
        doc.file.lines,
        first,
        count,
        term.rt.editor_tab_width,
        // **접힘 표를 함께 넘긴다** — 렌더가 받는 `lines` 가 접히면 보이는 줄 축이 되므로 색도
        // 같은 축이어야 한다(그 함수의 doc). 안 넘기면 접는 순간 색만 밀린다.
        term.rt.editor_visible_numbers,
    );
}

/// 설정의 caret 모양을 chrome 컴포넌트의 enum으로 옮긴다. **chrome은 config를 안 들여온다**(L3) —
/// 이름이 같으므로 옮겨 담기만 한다. 새 값이 한쪽에만 생기면 여기서 컴파일이 깨져 드러난다.
fn caretShape(self: *AppSession) chrome_editor.frame.CaretShape {
    return switch (self.loaded_config.config.editor.cursor_shape) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
    };
}

pub fn buildPaneOps(
    lines: []const []const u8,
    numbers: ?[]const ?u32,
    /// 줄마다의 gutter 접힘 표식(§4.1f). `null`이면 접힘 칸이 빈다.
    folds: ?[]const chrome_editor.gutter.Fold,
    /// gutter 자릿수를 정하는 **문서** 줄 수. 접히면 `lines`는 보이는 줄만이지만 번호는 원래 값이라,
    /// 보이는 수로 폭을 잡으면 렌더가 그리는 번호와 갈린다(`min_line_number_cells`가 10만 줄까지
    /// 가리지만 가려진다고 같은 것은 아니다 — 같은 부류를 §4.1e에서 이미 잡았다).
    total_lines: usize,
    first_line: usize,
    first_piece: u32,
    first_col: u16,
    /// 문서에서 **가장 긴 줄**의 표시 폭(열). 가로 스크롤바가 이 값으로 막대를 그리고, 그 막대가
    /// 자리를 먹으므로 본문 높이도 여기서 갈린다(§4.1a). `null`이면 막대가 없다.
    content_max_cols: ?u32,
    /// 줄별 시각 행 수 캐시(§2.1). `null`이면 매 프레임 다시 센다 — 그래도 그림은 같다.
    row_cache: ?*chrome_editor.frame.RowCache,
    /// 논리 줄마다의 **선택 범위**(§4.1g). `null`이면 선택이 없거나 caret뿐이다.
    selection_marks: ?[]const []const chrome_editor.frame.Mark,
    /// 논리 줄마다의 **검색 결과**(§5.1)와 그 중 현재 매치. `null`이면 검색이 닫혀 있거나
    /// 이 Term이 검색 대상이 아니다(활성이 아닌 pane — 그쪽까지 칠하면 어디를 검색 중인지 흐려진다).
    search_marks: ?[]const []const chrome_editor.frame.Mark,
    search_current: ?chrome_editor.frame.CurrentMatch,
    /// 검색 결과가 있는 **보이는 줄** 전체와 그 중 현재 매치(§4.1a 막대 마커). 위 `search_marks` 는
    /// 화면 안만 담아 **화면 밖 매치를 말하지 못한다** — 그 답이 이 목록의 존재 이유다.
    search_marker_lines: []const u32,
    search_marker_current: ?usize,
    /// 줄별 **구문 강조 색**(§5.3 1층). `lines`와 같은 축이고, 비어 있으면 무색이다 —
    /// grammar가 없거나 아직 안 판 문서가 그렇다.
    line_colors: []const []const chrome_editor.content.ColorSpan,
    /// 논리 줄마다의 **커서 자리**(줄 안 byte offset, 오름차순). `null`이면 커서가 없다.
    carets: ?[]const []const u32,
    /// 지금 커서를 그릴 순간인가(blink). 세션의 `blink_visible`이 그대로 온다.
    caret_visible: bool,
    /// caret 모양(`editor.cursor-shape`). **호출자가 넘긴다** — `tab_width`와 같은 이유로
    /// 기본값을 여기서 다시 쓰면 두 번째 출처가 된다.
    caret_shape: chrome_editor.frame.CaretShape,
    wrap: bool,
    /// 탭 폭(열). **호출자가 넘긴다** — 기본값을 여기서 다시 쓰면 그것이 두 번째 출처가 되고,
    /// hit-test가 "렌더가 쓰는 값"이라 부르는 것과 조용히 갈린다. 인자로 뚫은 이유는 하나 더 있다:
    /// 상수로 두면 **탭 폭 단일 출처를 재는 테스트(ADV3-D)가 자기 제목을 원리상 못 잰다** — 렌더도
    /// hit-test도 같은 comptime `4`를 읽으므로 하드코딩과 단일 출처 참조를 구분할 수 없다
    /// (11차 적대적 검증). 4가 아닌 값을 줄 수 있어야 그 둘이 갈린다.
    tab_width: u8,
    rect: chrome_draw.Rect,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    scratch: FrameScratch,
) PaneFrame {
    // **내용은 뷰 사각에서 한 겹 들어간다**(`frame.content_inset_px`) — 배경은 그대로 전체를 덮는다.
    // 활성 pane 포커스 테두리가 셀 **위** 층에 그려져서, 여백이 없으면 첫 글자 행과 스크롤바를 덮는다
    // (2026-08-14 실측). 열 수·스크롤바 gutter를 **이 사각으로** 계산해야 막대가 뷰 밖으로 안 밀린다.
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const inner: chrome_draw.Rect = .{ .x = 0, .y = 0, .w = rect.w -| chrome_editor.frame.content_inset_px * 2, .h = rect.h -| chrome_editor.frame.content_inset_px * 2 };
    const w = diff_frame.buildSide(
        .{ .lines = lines, .first_col = first_col, .numbers = numbers, .total_lines = total_lines, .folds = folds, .content_max_cols = content_max_cols, .row_cache = row_cache, .selection_marks = selection_marks, .search_marks = search_marks, .search_current = search_current, .search_marker_lines = search_marker_lines, .search_marker_current = search_marker_current, .line_colors = line_colors },
        .{ .first_line = first_line, .first_piece = first_piece, .carets = carets, .caret_visible = caret_visible, .caret_shape = caret_shape, .wrap = wrap, .tab_width = tab_width, .cell_w_px = cell_w_px, .cell_h_px = cell_h_px, .font_px = font_px },
        inner,
        // **배경만 뒤로 물린다.** 내용 op이 (0,0)에서 시작해야 셀 격자 양자화(`buildTextDrawList`가
        // px→셀로 바꾼다)에 여백이 먹히지 않는다 — 여백은 호출자가 **pane 원점**에 걸고, 배경은
        // 그만큼 음수로 밀어 뷰 사각 전체를 덮는다(§4.1b).
        .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        scratch,
    );
    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows, .total_visual_rows = w.total_visual_rows, .max_top_line = w.max_top_line, .max_top_piece = w.max_top_piece, .scrollbar = w.scrollbar, .horizontal_scrollbar = w.horizontal_scrollbar };
}

/// 편집기 본문의 화면 좌표를 **문서 offset**으로 옮긴다 — §4.1g의 다섯 단계.
///
/// `null`이면 이 좌표가 이 함수의 것이 아니다: 편집기 Term이 아니거나, 아직 그린 프레임이 없거나
/// (`editor_hit_rows_len == 0`), 좌표가 본문 사각 **밖**이다. **gutter는 여기 오지 않는다** — 줄 번호·
/// 접힘 화살표가 있는 자리라 그 클릭은 §4.1f의 접기/펼치기가 먼저 가져간다.
///
/// **비교 뷰는 아직 다루지 않는다**(§4.1g 결정표). 좌우가 `split_x`로 갈리고 어느 쪽인지부터 정해야
/// 하는데, 가로 스크롤 입력이 같은 이유로 비교를 뺐다 — 같은 자리에서 함께 연다.
///
/// **`AppSession`을 아예 안 받는다** — 기하도 셀 크기도 렌더가 굳힌 스냅숏(`editor_hit_geom`)에서
/// 온다. live로 다시 구하면 행 배열과 다른 프레임의 값이 되고, 실측으로 폭이 바뀐 뒤 클릭의 **80%**,
/// 폰트가 바뀐 뒤 **93%**가 다른 답을 냈다(10·11차 적대적 검증).
///
/// **그 인자 제거가 막는 것은 절반이다.** `AppSession`에만 있는 축(셀 크기·pane 기하)은 이제 타입이
/// 막지만, **`term.rt`는 통째로 live**이고 여기서 읽을 수 있다 — 이 함수 자신이 `editor_diff`를
/// 그렇게 읽는다(비교 뷰 거절). 실제로 `tab_w`를 `geom.tab_width` 대신 `term.rt.editor_tab_width`로
/// 바꾼 뮤턴트가 **컴파일되고 판정자 15개를 전부 통과했다**(12차 적대적 검증). 앞선 회차들이
/// *"live를 하나도 안 읽는다"* → *"layout만 live로 다시 구한다"* → *"쓸 수가 없다"*로 세 번 연속
/// 거짓을 적었으므로, 여기서는 **막는 축과 안 막는 축을 나눠 적는다**:
///
/// | 축 | 무엇이 막는가 |
/// |---|---|
/// | 셀 크기·pane 기하·layout | **타입** — `AppSession`이 인자에 없다 |
/// | `term.rt`의 스냅숏 필드(`editor_hit_*`) | 규율뿐 — `storeHitRows`가 함께 세우고 함께 지운다 |
/// | `term.rt`의 live 필드 **전부** | **아무것도 안 막는다** — 판정자뿐이다 |
///
/// **열거하지 않는다.** 13차는 이 행이 축을 셋으로 줄여 적은 것을 잡았고, 그래서 열둘을 적었더니
/// 14차가 그 목록에서 `editor_first_line`이 빠진 것을 잡았다 — 같은 파일이 두 곳에서 그 필드가
/// 프레임 사이에 바뀐다고 적고 있는데도. 축을 손으로 세는 문장은 **셀 때마다 새로 틀린다.**
/// 규칙만 남긴다: **`rt`의 필드 중 렌더가 굳힌 스냅숏(`editor_hit_*`)이 아닌 것은 전부 live이고,
/// 그것을 읽는 것을 막는 장치는 없다.** 지금 판정자가 있는 축은 탭 폭 하나뿐이다(ADV3-H).
///
/// 문서 내용(`editor_lines`·`editor_doc`)은 일부러 live로 읽는다 — 편집이 곧 렌더라 배열과 함께
/// 갱신된다.
///
/// 세로 밖은 첫/마지막 **보이는 행**으로 clamp한다. 드래그는 pane을 벗어나는 것이 정상이고, 그때
/// `null`을 주면 호출자가 분기를 하나 더 져야 한다(§10이 *"항상 유효한 offset"*이라 정한 것과 같은 결).
pub fn hitTestBody(term: *Term, x_px: f64, y_px: f64) ?usize {
    if (term.kind != .editor) return null;
    if (term.rt.editor_diff != null) return null; // 비교 뷰는 범위 밖
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;

    // **다섯 단계는 중립이 소유한다**(`chrome_editor.hit.bodyPoint`). 여기 있던 계산을 Windows
    // 편집기 표면이 그대로 필요로 했고, 다시 쓰면 이 자리가 적대적 검증으로 쌓은 것을 다시 밟는다 —
    // 좌표 묶기(NaN·무한대), gutter 거르기, 세로 clamp, 행 → 원본 줄, 줄 안 걸음. 그 근거는 전부
    // 그 파일로 옮겼다.
    //
    // **이 함수가 남기는 것은 두 가지뿐이다**: ⒜ 굳힌 값을 모아 넘기고 ⒝ 줄 안 byte 를 **문서
    // offset** 으로 바꾼다. ⒝ 는 문서 모델(session)을 알아야 해서 chrome 이 못 한다.
    const geom = term.rt.editor_hit_geom;
    const p = chrome_editor.hit.bodyPoint(
        .{
            .body_x = geom.body_x,
            .body_y = geom.body_y,
            .content_left_px = geom.content_left_px,
            .content_width = geom.content_width,
            .cell_w_px = geom.cell_w_px,
            .cell_h_px = geom.cell_h_px,
            .tab_width = geom.tab_width,
        },
        term.rt.editor_hit_rows[0..rows_len],
        term.rt.editor_hit_lines[0..rows_len],
        term.rt.editor_lines,
        x_px,
        y_px,
    ) orelse return null;

    // ⑤ 줄 안 byte → 문서 offset. `Selection`이 문서 전체 offset을 요구한다.
    const doc = term.rt.editor_doc orelse return null;
    const line = doc.file.lines.line(p.line) orelse return null;
    // **묶지 않고 단언한다.** `editor_lines[i]`는 `lineText(i) = bytes[start..contentEnd()]`이므로
    // `text.len == contentEnd() - start`가 항등이고, `byteAtPoint`의 모든 반환 경로가 `≤ text.len`
    // 이다. 묶으면 그 항등이 깨져도 조용히 다른 답을 내므로, 깨지는 순간 죽는 편이 낫다.
    std.debug.assert(p.byte_in_line <= line.contentEnd() - line.start);
    return line.start + p.byte_in_line;
}

/// 상태바가 보여 줄 **커서 위치**(줄:열). 선택이 없으면 `null`.
///
/// **열은 그래핌 클러스터 기준 1-based다**(§2.2). byte offset은 내부 축이고 사람이 읽는 값이 아니다.
/// **탭은 탭스톱까지의 폭이 아니라 문자 하나로 센다** — 이 값은 *"몇 번째 글자인가"*를 답하지 화면
/// 위치를 답하지 않고, 화면 위치는 caret이 이미 보여 준다. 그래서 `stepColumn`(렌더의 열)이 아니라
/// `grapheme.clusterEnd`로 센다 — 두 축을 섞으면 탭이 있는 줄에서 상태바가 화면과 다른 수를 낸다.
///
/// **줄도 1-based다.** 내부 인덱스는 0-based이지만 gutter가 1부터 그리므로, 상태바가 0을 말하면
/// 같은 줄을 두 이름으로 부르게 된다.
pub fn cursorPosition(term: *const Term) ?struct { line: usize, column: usize, truncated: bool } {
    if (term.kind != .editor) return null;
    // 비교 뷰는 축이 다르다(행 배열이고 문서가 둘이다) — 그 자리는 §4.1g "비교 뷰"가 따로 정한다.
    if (term.rt.editor_diff != null) return null;
    const sel = term.rt.editor_selection orelse return null;
    const doc = term.rt.editor_doc orelse return null;
    const off = @min(sel.focus, doc.file.content.len);
    const line_idx = doc.file.lines.lineAt(off);
    const line = doc.file.lines.line(line_idx) orelse return null;

    // **줄 끝에서 묶는다.** `contentEnd()`는 줄 끝 문자 앞이다 — 안 묶으면 CRLF 줄에서 CR을 한
    // 글자로 세어 **줄에 있는 글자 수보다 큰 열**이 나온다(실측: 글자 셋인 줄에서 `1:5`).
    // `line_index.offsetInLine`이 같은 clamp를 같은 이유로 지킨다.
    const end = @min(off, line.contentEnd());
    std.debug.assert(end >= line.start); // lineAt이 off를 담는 줄을 주고 contentEnd >= start다
    const text = doc.file.content[line.start..end];

    // 줄 머리에서 caret까지 **클러스터를 센다** — 상한까지만.
    var col: usize = 1;
    var i: usize = 0;
    while (i < text.len and col <= max_status_column) {
        i = maru.grapheme.clusterEnd(text, i);
        col += 1;
    }
    // **덜 센 것과 딱 맞게 센 것을 가른다.** `col > 상한`으로 보면 정확히 상한만큼인 줄이 끝까지
    // 세고도 잘렸다고 말한다 — 남은 바이트가 있는지로 본다.
    return .{ .line = line_idx + 1, .column = col, .truncated = i < text.len };
}

/// 상태바 열을 **여기까지만 센다**.
///
/// **상한이 없으면 매 프레임 줄 전체를 훑는다.** 상태바는 프레임마다 다시 조립되는데, 긴 줄 끝에
/// caret이 있으면 그 길이에 비례하는 일이 렌더 루프에 들어온다 — 1MB 한 줄에서 ASCII 기준 프레임당
/// **6.5~9.5ms**(ReleaseFast/M4 Max, 부하가 있는 머신에서 잰 값이라 **상한**이다). 60fps 예산
/// 16.7ms의 절반쯤을 한 줄이 먹는다. 더블·트리플 클릭 한 번이면 focus가 줄 끝으로 가므로 도달도
/// 쉽다. 같은 파일군이 이 부류를 이미 두 번 잡아 상한을 박았다(`frame.max_first_col` — 60,000열
/// 한 줄에서 프레임당 498ms/Debug, `frame.max_cols_count_limit`).
///
/// **`max_first_col`이 아니라 `max_cols_count_limit`을 쓴다.** 앞은 **가장 왼쪽 열**의 상한이라
/// 최대 스크롤에서도 화면 오른쪽 끝은 `max_first_col + 보이는 열`이다 — 그 값으로 묶으면 **화면에
/// 실제로 보이고 클릭도 되는** 글자를 상태바가 못 세고 `+`가 "그 너머는 볼 수 없다"는 거짓을 말한다.
/// 뒤는 그 여유(4,096열)를 이미 품은 값이라 화면에 오를 수 있는 열을 전부 덮는다.
///
/// **단위는 같지 않다.** 렌더의 열은 탭을 탭스톱까지·전각을 두 칸으로 세고(`content.stepColumn`),
/// 이 값은 그래핌 클러스터를 센다. 클러스터 수 ≤ 열 수이므로 열 상한을 클러스터 상한으로 쓰면
/// **보수적인 방향으로만** 어긋난다 — 화면에 오를 수 있는 글자를 못 세는 일은 없다.
/// 14,096 클러스터를 세는 데 ASCII 88µs·한글 NFC 131µs쯤 든다.
pub const max_status_column: usize = chrome_editor.frame.max_cols_count_limit;

/// gutter **접기 칸**의 화면 좌표를 그 행의 **문서 줄**(0-based)로 옮긴다 — §4.1f의 포인터 경로.
///
/// **본문 좌표계(`hitTestBody`)의 짝이다.** 그쪽은 gutter를 `null`로 거절하고(*"접힘 화살표 자리를
/// 안 뺏는다"*), 이 함수가 그 자리를 가져간다. §4.1g 결정표가 *"화살표 클릭이 붙으면 그쪽이 먼저
/// 가져가고, 그때까지 이 좌표계는 그 사각을 비워 둔다"*고 적어 둔 그 자리다.
///
/// **읽는 것은 렌더가 굳힌 스냅숏뿐이다**(`editor_hit_geom`·`editor_hit_rows`·`editor_hit_lines`).
/// 띠의 위치는 layout에서 나오고 layout은 폰트·pane 폭을 따라 움직이므로, 클릭 시점에 다시 구하면
/// 보이는 화살표와 다른 프레임의 띠를 재게 된다 — 본문이 실측 80%·93% 불일치로 겪은 축이다.
///
/// `null`인 경우: 편집기 Term이 아니거나, 비교 뷰이거나, 아직 그린 프레임이 없거나, 좌표가 접기
/// 띠 **밖**이거나, 그 행이 **랩으로 이어진 조각**이다.
///
/// 초판은 여기에 *"접기 칸이 꺼져 있거나"*를 적었는데 **제품 경로에 없는 상태다** — layout을 늘
/// `.{}`로 만들므로 `features.folding`은 항상 켜져 있다. 그 문장을 지키던 가드도 함께 걷어냈다
/// (아래 "가드가 없다").
///
/// **세로를 clamp하지 않는다** — `hitTestBody`와 갈리는 유일한 축이고 이유가 있다. 그쪽은 드래그가
/// pane을 벗어나는 것이 정상이라 늘 유효한 offset을 줘야 하지만, 접기는 **한 번 누르는 동작**이라
/// 밖은 곧 *"이 자리가 아니다"*다. 여기서 clamp하면 pane 아래 빈 곳을 눌러도 마지막 줄이 접힌다.
///
/// **줄이 접을 수 있는 머리인지는 안 본다.** 그것은 좌표계가 아니라 접힘 상태의 물음이라
/// `toggleFoldAtPoint`가 `editor_fold_ranges`로 판정한다 — 여기서 함께 보면 좌표 변환을 재는
/// 테스트가 접힘 상태까지 세워야 돌아간다.
pub fn hitTestFoldMark(term: *Term, x_px: f64, y_px: f64) ?u32 {
    if (term.kind != .editor) return null;
    if (term.rt.editor_diff != null) return null; // 비교 뷰는 접힘 자체가 없다(`foldsUnavailable`)
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;

    const geom = term.rt.editor_hit_geom;
    // **가드가 없다.** 초판은 `fold_width_px == 0 or cell_h_px == 0`을 물었는데 **둘 다 도달할 수
    // 없다**: `storeHitRows`가 행 배열과 기하를 사이에 return 없이 함께 세우고 `releaseEditorTerm`이
    // 함께 지우므로 위 `rows_len == 0`이 이미 "안 그렸다/해제됐다"를 막고, 그린 프레임의 셀 크기는
    // 0일 수 없으며(`appendPaneFrame`이 맨 앞에서 0이면 `null`을 낸다) 접기 칸도 폭을 갖는다
    // (제품은 layout을 늘 `.{}`로 만든다 — `features.folding = false`는 지금 제품 경로에 없다).
    // `hitTestBody`가 같은 논증으로 셀 0 가드를 걷어낸 자리다.
    //
    // **폭 0인 layout이 뒷날 생겨도 답이 바뀌지 않는다** — `left == right`가 되어 아래 비교가 모든
    // x를 거절한다. 즉 이 가드는 없을 때와 있을 때의 동작이 같고, 그래서 죽은 코드다(적대적 검증
    // 2026-08-22: 지운 판을 판정자 아홉이 하나도 구분하지 못했다).

    // **캐스트 전에 묶는다** — `hitTestBody`와 같은 이유다(NaN·무한대는 `@intFromFloat`에서 죽는다).
    const px_limit: f64 = 1 << 30;
    const clamped_x: f64 = if (std.math.isNan(x_px)) 0 else @max(-px_limit, @min(px_limit, x_px));
    const clamped_y: f64 = if (std.math.isNan(y_px)) 0 else @max(-px_limit, @min(px_limit, y_px));
    const rel_x: i64 = @as(i64, @intFromFloat(clamped_x)) - @as(i64, geom.body_x);
    const rel_y: i64 = @as(i64, @intFromFloat(clamped_y)) - @as(i64, geom.body_y);

    const left: i64 = @intCast(geom.fold_left_px);
    const right: i64 = left + @as(i64, @intCast(geom.fold_width_px));
    if (rel_x < left or rel_x >= right) return null;
    if (rel_y < 0) return null; // 위 doc — 클릭은 밖을 끌어오지 않는다
    const row_i: usize = @intCast(@divFloor(rel_y, @as(i64, geom.cell_h_px)));
    if (row_i >= rows_len) return null;

    // **랩으로 이어진 조각에는 화살표가 없다**(`gutter.rowsForVisual` — 한 줄에 표식이 여러 개 서면
    // 접힌 줄 수를 오해한다). 그린 것과 눌리는 것이 같아야 하므로 여기서도 거절한다.
    if (!term.rt.editor_hit_rows[row_i].showsLineNumber()) return null;

    const source_line = term.rt.editor_hit_lines[row_i];
    if (source_line >= term.rt.editor_lines.len) return null;
    return source_line;
}

/// 비교 뷰 본문의 화면 좌표를 **(어느 열, 행, 행 안 byte)**로 옮긴다(§4.1g "비교 뷰").
///
/// **단일 편집기보다 두 단계 짧다.** 접힘 층(③)은 비교에서 거절되고(`foldsUnavailable`), 문서 offset
/// 변환(⑤)은 대상 문서가 없다 — 화면에 서는 것은 원본 줄이 아니라 짝을 맞춰 정렬한 행 배열이다.
///
/// `null`이면 이 좌표가 이 함수의 것이 아니다: 비교 상태가 아니거나, 아직 안 그렸거나, **gutter**다.
///
/// **열 사이 틈은 `null`이 아니다.** 그 자리는 왼쪽 열의 오른쪽 밖이라 `byteAtPoint`가 그 행의 끝으로
/// clamp한다(결정표의 *"행 끝 너머 → 그 행의 끝"*과 같은 규칙). 초판 doc이 그것을 `null`이라 적었는데
/// 실측으로 `.left`를 답했다 — 동작이 아니라 문장이 틀렸다.
///
/// **`side`를 강제할 수 있다.** 드래그가 반대 열로 넘어가도 잡은 열에 머물러야 하므로(계약: 좌우를
/// 걸치는 선택은 만들지 않는다), 호출자가 잡은 열을 넘기면 그 열로만 답한다.
pub const DiffHit = struct { side: DiffSide, row: usize, byte: usize };
/// 비교 뷰의 어느 열인가. **찾기 오버레이가 그리는 타입을 그대로 쓴다**(`chrome` 컴포넌트가
/// 소유) — 같은 모양을 두 군데 두면 한쪽만 늘었을 때 조용히 갈린다.
pub const DiffSide = chrome.components.find.DiffSide;

pub fn hitTestDiffBody(term: *Term, x_px: f64, y_px: f64, force: ?DiffSide) ?DiffHit {
    if (term.kind != .editor) return null;
    const st = term.rt.editor_diff orelse return null;
    if (st.view != .compare) return null;
    const g = term.rt.editor_diff_hit_geom;
    if (g.cell_w_px == 0 or g.cell_h_px == 0) return null;

    const px_limit: f64 = 1 << 30;
    const cx: f64 = if (std.math.isNan(x_px)) 0 else @max(-px_limit, @min(px_limit, x_px));
    const cy: f64 = if (std.math.isNan(y_px)) 0 else @max(-px_limit, @min(px_limit, y_px));
    const xi: i64 = @intFromFloat(cx);
    const yi: i64 = @intFromFloat(cy);

    // ① 어느 열인가. 잡은 열이 있으면 그것을 쓴다 — 드래그가 반대 열로 넘어가도 머문다.
    const side: DiffSide = force orelse blk: {
        // 두 열의 본문 시작 x를 비교한다. 오른쪽 열 원점보다 왼쪽이면 왼쪽 열이다(틈은 아래에서 걸린다).
        break :blk if (xi >= @as(i64, g.right_x)) .right else .left;
    };
    const col_x: i64 = if (side == .right) g.right_x else g.left_x;
    const rows_len = if (side == .right) term.rt.editor_diff_hit_len_right else term.rt.editor_diff_hit_len_left;
    if (rows_len == 0) return null;
    const rows = if (side == .right) term.rt.editor_diff_hit_rows_right else term.rt.editor_diff_hit_rows_left;

    const content_left: i64 = col_x + @as(i64, g.content_left_px);
    if (xi < content_left) return null; // gutter — 이 좌표계가 받지 않는다

    // ② 화면 행 → 그 열의 행. 세로는 clamp한다(드래그가 pane을 벗어나는 것은 정상이다).
    const rel_y: i64 = yi - @as(i64, g.body_y);
    const row_i: usize = if (rel_y < 0) 0 else blk: {
        const r: usize = @intCast(@divFloor(rel_y, @as(i64, g.cell_h_px)));
        break :blk @min(r, rows_len - 1);
    };
    const v = rows[row_i];
    const texts = if (side == .right) st.right_texts else st.left_texts;
    // **`VisualRow.line`은 뷰포트 상대다.** `first_line`을 더해야 그 열의 행 배열 인덱스가 된다 —
    // 같은 파일 위쪽이 *"`v.line`은 상대 인덱스이고 그 배열은 절대 인덱스다"*라고 적어 둔 그
    // 오류를 초판이 그대로 재현했고, 스크롤한 프레임에서 판정 7발이 **전부** 어긋났다(적대적 검증).
    // 접힘이 거절되므로 없어지는 것은 번호표 단계뿐이고, 이 덧셈은 남는다.
    const line_idx: usize = v.line + g.first_line;
    if (line_idx >= texts.len) return null;

    // ③ 열·칸 안 픽셀 → 행 안 byte. **단일 편집기와 같은 함수**다.
    const off = chrome_editor.content.byteAtPoint(
        texts[line_idx],
        g.tab_width,
        @min(v.start_byte, texts[line_idx].len),
        v.start_byte_col,
        v.start_col,
        g.content_width,
        @intCast(@min(xi - content_left, @as(i64, std.math.maxInt(i32)))),
        g.cell_w_px,
    );
    return .{ .side = side, .row = line_idx, .byte = off };
}

/// 한 열의 행 배열을 굳힌다. 저장소는 **필요한 만큼 한 번 잡고 재사용**한다(단일 편집기와 같은 관례).
/// 못 잡으면 길이를 0으로 세워 그 프레임의 그 열만 클릭을 안 받는다 — 화면은 이미 다 그렸다.
fn storeOneSide(
    self: *AppSession,
    src: []const chrome_editor.visual_map.VisualRow,
    rows: *[]chrome_editor.visual_map.VisualRow,
    len: *usize,
) void {
    if (src.len > rows.len) {
        const grown = self.allocator.alloc(chrome_editor.visual_map.VisualRow, src.len) catch {
            len.* = 0;
            return;
        };
        if (rows.len > 0) self.allocator.free(rows.*);
        rows.* = grown;
    }
    @memcpy(rows.*[0..src.len], src);
    len.* = src.len;
}

/// 비교 뷰의 **좌우 행 배열과 열 기하**를 굳힌다(§4.1g "비교 뷰"). 단일 편집기의 `storeHitRows`와
/// 같은 자리·같은 이유이고, 축만 다르다 — 이쪽 행 인덱스는 그 열의 정렬된 행 배열의 것이다.
///
/// **접힘 번호표만 없어진다.** 비교에서는 접힘이 거절되므로(`foldsUnavailable`) ③의 두 단계 중
/// 번호표 되짚기가 빠지지만, **`+ first_line`은 남는다** — `VisualRow.line`은 뷰포트 상대이고
/// 세로 스크롤은 접힘과 별개다. 초판이 *"화면 행이 곧 그 배열의 행"*이라 적어 그 덧셈을 통째로
/// 빠뜨렸고, 스크롤한 프레임에서 판정 7발이 전부 어긋났다(적대적 검증).
fn storeDiffHitRows(
    self: *AppSession,
    term: *Term,
    leaf_rect: maru.session.SplitRect,
    left: []const chrome_editor.visual_map.VisualRow,
    right: []const chrome_editor.visual_map.VisualRow,
) void {
    storeOneSide(self, left, &term.rt.editor_diff_hit_rows_left, &term.rt.editor_diff_hit_len_left);
    storeOneSide(self, right, &term.rt.editor_diff_hit_rows_right, &term.rt.editor_diff_hit_len_right);

    // 열 기하도 같은 순간에 굳힌다 — 단일 편집기와 같은 규율(§4.1g "스냅숏의 경계").
    const body_outer = editorBodyRect(self, leaf_rect, term);
    const inset = chrome_editor.frame.content_inset_px;
    const inner_w = body_outer.w -| inset * 2;
    const inner_h = body_outer.h -| inset * 2;
    const cols = chrome_editor.diff_frame.columns(
        .{ .x = 0, .y = 0, .w = inner_w, .h = inner_h },
        @intCast(self.cell_width_px),
    );
    const m = chrome_editor.diff_frame.sideMetrics(@intCast(cols.left.w), inner_h, @intCast(self.cell_width_px), @intCast(self.cell_height_px));
    const lay = chrome_editor.geometry.compute(m.total_cols, diffRowCount(term), .{});
    const origin_x: i32 = @intCast(body_outer.x + inset);
    term.rt.editor_diff_hit_geom = .{
        .left_x = origin_x + cols.left.x,
        .right_x = origin_x + cols.right.x,
        .body_y = @intCast(body_outer.y + inset),
        .content_left_px = @as(u32, lay.contentLeft()) * @as(u32, self.cell_width_px),
        .content_width = lay.content.width,
        .cell_w_px = @intCast(@min(self.cell_width_px, std.math.maxInt(u16))),
        .cell_h_px = @intCast(@min(self.cell_height_px, std.math.maxInt(u16))),
        .tab_width = term.rt.editor_tab_width,
        .first_line = term.rt.editor_first_line,
    };
}

/// 비교 뷰의 행 수(좌우가 같다 — 짝을 맞춰 정렬했으므로). gutter 자릿수가 이 값으로 정해진다.
fn diffRowCount(term: *const Term) usize {
    const st = term.rt.editor_diff orelse return 0;
    return st.left_texts.len;
}

/// 마지막 프레임의 행들을 Term에 복사하고, **그 자리에서 절대 원본 줄까지 푼다**.
///
/// 저장소는 **필요한 만큼만 한 번 잡고 재사용**한다 — 화면 행 수는 창 크기로 정해지므로 프레임마다
/// 흔들리지 않는다.
///
/// **푸는 것을 여기서 하는 이유**는 `editor_hit_lines` doc에 있다: `VisualRow.line`을 절대 줄로 바꾸려면
/// `editor_first_line`과 `editor_visible_numbers`가 필요한데 **둘 다 프레임 사이에 바뀐다**. 렌더 시점에
/// 풀어 두면 `hitTestBody`가 **행 해석에** live 상태를 안 읽는다. 기하와 셀 크기도 같은 이유로 이
/// 함수가 함께 굳힌다(아래 `editor_hit_geom` 대입) — 셋이 한 함수 안에서 사이에 return 없이 세워지므로
/// "행 배열과 다른 프레임의 기하"가 생길 자리가 없다.
fn storeHitRows(self: *AppSession, term: *Term, leaf_rect: maru.session.SplitRect, rows: []const chrome_editor.visual_map.VisualRow) void {
    if (rows.len > term.rt.editor_hit_rows.len) {
        const grown = self.allocator.alloc(chrome_editor.visual_map.VisualRow, rows.len) catch {
            term.rt.editor_hit_rows_len = 0; // 못 잡았다 — 이 프레임은 클릭을 못 받는다
            return;
        };
        const grown_lines = self.allocator.alloc(u32, rows.len) catch {
            self.allocator.free(grown);
            term.rt.editor_hit_rows_len = 0;
            return;
        };
        if (term.rt.editor_hit_rows.len > 0) self.allocator.free(term.rt.editor_hit_rows);
        if (term.rt.editor_hit_lines.len > 0) self.allocator.free(term.rt.editor_hit_lines);
        term.rt.editor_hit_rows = grown;
        term.rt.editor_hit_lines = grown_lines;
    }
    @memcpy(term.rt.editor_hit_rows[0..rows.len], rows);

    // **③ 보이는 줄 → 원본 논리 줄을 여기서 푼다.**
    //
    // `v.line`은 뷰포트 첫 줄로부터의 **상대 인덱스**라 `first_line`을 더해야 보이는 줄이 되고
    // (gutter가 같은 표를 그렇게 읽는다 — `gutter.zig`의 `first_line + v.line`), 접힘이 켜져 있으면
    // 그 보이는 줄을 번호 표로 한 번 더 옮겨야 원본 줄이 된다.
    const first_line = term.rt.editor_first_line;
    const numbers = term.rt.editor_visible_numbers;
    const doc_lines = term.rt.editor_lines.len;
    for (rows, 0..) |v, i| {
        const visible_idx: usize = @as(usize, v.line) + first_line;
        // **되풀기는 색 경로와 같은 함수를 쓴다**(`syntax_color.sourceLineFor`). 예전에는 같은
        // 규칙이 여기 인라인으로만 있었고, 색 쪽이 그 되풀기를 아예 안 해서 **클릭은 맞는데 색은
        // 틀린** 반쪽 상태가 났다(사용자 보고 2026-08-31). 한 곳에 두면 그 갈림이 생길 수 없다.
        const source: usize = syntax_color.sourceLineFor(numbers, visible_idx) orelse doc_lines;
        term.rt.editor_hit_lines[i] = @intCast(@min(source, std.math.maxInt(u32)));
    }
    term.rt.editor_hit_rows_len = rows.len;

    // **기하도 같은 순간에 굳힌다**(`editor_hit_geom` doc). ①(픽셀 → 행·열)과 ④(행 폭)가 클릭
    // 시점에 다시 계산하면 행 배열과 다른 프레임의 값이 된다.
    const body_outer = editorBodyRect(self, leaf_rect, term);
    const inset = chrome_editor.frame.content_inset_px;
    const inner_w = body_outer.w -| inset * 2;
    const inner_h = body_outer.h -| inset * 2;
    const m = chrome_editor.diff_frame.sideMetrics(inner_w, inner_h, @intCast(self.cell_width_px), @intCast(self.cell_height_px));
    const lay = chrome_editor.geometry.compute(m.total_cols, term.rt.editor_lines.len, .{});
    term.rt.editor_hit_geom = .{
        .body_x = @intCast(body_outer.x + inset),
        .body_y = @intCast(body_outer.y + inset),
        .content_left_px = @as(u32, lay.contentLeft()) * @as(u32, self.cell_width_px),
        .content_width = lay.content.width,
        // **묶지 않는다** — 위 `sideMetrics(..., @intCast(self.cell_width_px), ...)`가 이미
        // u16 인자에 맨 캐스트를 넣으므로, 셀이 u16을 넘으면 **여기 오기 전에** 걸린다(안전 빌드는
        // 트랩, 배포 `ReleaseFast`는 UB). 그래서 이 자리는 도달 불가다. 초판은 여기에 *"묶으면 그
        // 트랩이 죽는다"*고 적었는데 **거짓이다** — 위 캐스트는 독립 식이라 여기서 무엇을 하든 죽지
        // 않는다(13차 적대적 검증). 남는 이유는 하나뿐이다: 도달 불가한 자리에 clamp를 두면 그것이
        // 죽은 코드이고, 이 커밋이 죽은 코드를 걷어내는 커밋이다.
        .cell_w_px = @intCast(self.cell_width_px),
        .cell_h_px = @intCast(self.cell_height_px),
        .tab_width = term.rt.editor_tab_width,
        // **접기 띠도 같은 layout에서 뽑는다**(§4.1f 포인터 경로). 여기서 함께 굳히지 않으면
        // 클릭이 다른 프레임의 열을 보고, 그리는 자리와 누르는 자리가 갈린다 — 본문이 이미 같은
        // 사고를 겪은 축이다(위 doc).
        .fold_left_px = @as(u32, lay.folding.start) * @as(u32, self.cell_width_px),
        .fold_width_px = @as(u32, lay.folding.width) * @as(u32, self.cell_width_px),
        // **어느 자리를 그렸는지도 굳힌다.** 이것이 있어야 나중에 "이 목록이 지금 화면 것인가"를
        // 물을 수 있다 — 그 질문 없이 목록만 믿으면 프레임 사이의 스크롤을 못 본다(그 필드의 doc).
        .top_line = term.rt.editor_first_line,
        .top_piece = term.rt.editor_first_piece,
        .visible_len = editorLines(term).len,
        .wrap = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap,
        .drawn = true,
    };
}

/// **좌우 두 열**을 한 ops 배열에 그린다(N1.5 c). 조합은 컴포넌트가 소유하고(`diff_frame.build`),
/// 여기서는 pane 여백만 반영한다 — Chrome Lab이 같은 함수를 불러 캡처가 제품을 예고한다.
pub fn buildDiffPaneOps(
    left: chrome_editor.diff_frame.Side,
    right: chrome_editor.diff_frame.Side,
    first_line: usize,
    first_piece: u32,
    wrap: bool,
    /// 탭 폭(열). **호출자가 넘긴다** — 기본값을 여기서 다시 쓰면 그것이 두 번째 출처가 되고,
    /// hit-test가 "렌더가 쓰는 값"이라 부르는 것과 조용히 갈린다. 인자로 뚫은 이유는 하나 더 있다:
    /// 상수로 두면 **탭 폭 단일 출처를 재는 테스트(ADV3-D)가 자기 제목을 원리상 못 잰다** — 렌더도
    /// hit-test도 같은 comptime `4`를 읽으므로 하드코딩과 단일 출처 참조를 구분할 수 없다
    /// (11차 적대적 검증). 4가 아닌 값을 줄 수 있어야 그 둘이 갈린다.
    tab_width: u8,
    rect: chrome_draw.Rect,
    cell_w_px: u16,
    cell_h_px: u16,
    font_px: u16,
    scratch: FrameScratch,
) PaneFrame {
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const inner: chrome_draw.Rect = .{
        .x = 0,
        .y = 0,
        .w = rect.w -| chrome_editor.frame.content_inset_px * 2,
        .h = rect.h -| chrome_editor.frame.content_inset_px * 2,
    };
    const w = diff_frame.build(.{
        .left = left,
        .right = right,
        .first_line = first_line,
        .first_piece = first_piece,
        .wrap = wrap,
        .tab_width = tab_width,
        .rect = inner,
        .background_rect = .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .font_px = font_px,
    }, scratch);
    return .{
        .ops = scratch.ops[0..w.ops],
        .ops_len = w.ops,
        .visual_rows = w.visual_rows,
        .left_visual_rows = w.left_visual_rows,
        .right_visual_rows = w.right_visual_rows,
        .total_visual_rows = w.total_visual_rows,
        .max_top_line = w.max_top_line,
        .max_top_piece = w.max_top_piece,
        // **왼쪽 열이 단일 편집기와 같은 자리를 쓴다** — 오른쪽은 아래 두 필드가 든다.
        .scrollbar = w.left_scrollbar,
        .horizontal_scrollbar = w.left_horizontal_scrollbar,
        .right_scrollbar = w.right_scrollbar,
        .right_horizontal_scrollbar = w.right_horizontal_scrollbar,
    };
}

/// 편집기 배경·스크롤바 quad가 실리는 합성 층. **제품과 Chrome Lab이 함께 읽는 단일 출처다.**
///
/// 왜 상수인가: 예전엔 양쪽이 각자 리터럴을 들었고 제품만 `3`으로 흘러갔다. 렌더러가 이름 없는
/// 값을 전부 over로 몰아넣어 오타가 "동작"했고, 그동안 Lab 캡처는 옳은데 제품만 빈 화면이었다.
/// 값이 하나면 그 상태가 만들어지지 않는다 — 이것을 잘못 바꾸면 **세 곳이 동시에** 신호를 낸다:
/// 제품 단위 테스트(층 단언), Lab 스모크 게이트(`isBelowText`), 그리고 Lab 캡처가 통째로 빈다.
pub const background_layer: u32 = chrome_draw_lowering.layers.bottom;

/// 한 leaf에 편집기 프레임을 그린 결과. 배경·스크롤바 quad는 이미 `gpu_quads`에 실렸고, 글자는
/// 호출자가 셀로 내리도록 DrawList로 돌려준다.
pub const PaneDraw = struct {
    /// 그린 사각(pane body — 탭 바 아래, 창 padding은 적용하지 않는다). 호출자가 셀 origin으로 쓴다.
    rect: maru.session.SplitRect,
    /// 본문·gutter 글자. **호출자가 소유한다**(`collectShaped`가 가져가거나 직접 해제).
    dl: renderer.DrawList,
};

/// leaf 하나에 편집기 프레임을 그린다. 편집기 Term이 아니거나 그릴 것이 없으면 `null`.
///
/// **왜 tick에서 뽑아 왔나.** 이 함수가 정하는 셋(사각·quad layer·lowering 격자)은 전부 조용히
/// 틀릴 수 있는 판정이고, tick 안에 있으면 프레임 전체를 돌리지 않고는 검사할 수 없다. 실제로
/// 배경 layer 하나가 뒤집혀 본문이 통째로 안 보이는 동안 테스트는 전부 초록이었다 — 아래 테스트가
/// 그 두 뮤턴트(layer 3·leaf 사각)를 잡는다.
///
/// 조립 자체는 `editor_view.frame`이 한다 — Chrome Lab과 **같은 함수**라 캡처가 제품을 예고한다.
/// 편집기 본문이 설 사각. `paneGeometry(...).body`에서 **헤더 밴드 한 줄을 더 뺀다**.
///
/// **왜 여기서 빼는가.** 밴드는 파일 Term이 소유하고 chrome이 pane 탭 바 바로 아래에 그린다
/// (file-panel-dock-ui.md §3.1 — breadcrumb·모드 선택기). 웹 Term은 `collectWebSurfaces`의
/// `inset.top = bar_h + addr_h`로 본문이 그 아래로 내려가지만, 편집기는 이 사각에 **직접 그리므로**
/// 빼지 않으면 본문 첫 행이 밴드와 겹친다(적대적 검증에서 잡았다 — 네이티브 비교 Term은
/// `file_entry`가 있어 chrome이 그 자리에 밴드를 그린다).
///
/// `paneGeometry`에서 빼지 않는 이유: 그 함수는 pane을 모르고 **터미널 격자도 그것을 쓴다** —
/// 터미널에는 밴드가 없으므로 거기서 빼면 셸 화면이 한 줄 내려간다.
pub fn editorBodyRect(self: *AppSession, leaf_rect: maru.session.SplitRect, term: *const Term) maru.session.SplitRect {
    const geo = pane_ops.paneGeometry(self, leaf_rect);
    if (term.file_entry == null) return geo.body;
    const band_h = pane_ops.paneBarHeightPx(self); // 밴드는 바와 같은 높이다(`paneBandRect`)
    return .{ .x = geo.body.x, .y = geo.body.y + band_h, .w = geo.body.w, .h = geo.body.h -| band_h };
}

pub fn appendPaneFrame(self: *AppSession, leaf_rect: maru.session.SplitRect, term: *Term) ?PaneDraw {
    if (term.kind != .editor) return null;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return null;

    // **그리기 전에 지금 기하로 위치를 되돌린다.** 창·분할·사이드바가 바뀌면 상한이 줄어드는데,
    // 스크롤 입력이 올 때까지 옛 위치가 남으면 화면이 통째로 빈다(그 함수의 doc — 실측값 포함).
    clampScrollToGeometry(self, term, leaf_rect);

    // **비교 Term은 문서 대신 판정을 말한다**(N1.5 b·c). 비교가 서면 좌우 두 열이고(c), 아직이거나
    // 보여 줄 수 없으면 그 사실을 한 줄로 말한다 — 조용한 빈 화면을 남기지 않는 것이 §7의 요구다.
    const diff_state_opt: ?*const editor_diff_ops.State = if (term.rt.editor_diff) |*st| st else null;
    var status_line: [1][]const u8 = undefined;
    const lines: []const []const u8 = if (diff_state_opt) |st| blk: {
        if (st.view == .compare) break :blk st.left_texts; // 아래 두 열 경로가 쓴다
        status_line[0] = editor_diff_ops.statusText(st.view);
        break :blk status_line[0..1];
    } else if (term.rt.editor_visible_lines.len > 0)
        // **접혀 있으면 보이는 줄만 그린다**(§4.1f). 번호는 아래에서 원래 값을 넘긴다.
        term.rt.editor_visible_lines
    else
        term.rt.editor_lines;
    if (lines.len == 0) return null;

    // **본문 사각은 `body`다 — `grid`가 아니다**(`paneGeometry` 단일 출처).
    //
    // 셋의 차이: `leaf_rect`(탭 바 포함) ⊃ `body`(탭 바 제외) ⊃ `grid`(body에서 `window_padding_px`만큼 더 안쪽).
    //
    // 탭 바는 반드시 빼야 한다 — 안 그러면 편집기 배경이 탭을 덮는다. **창 padding은 빼지 않는다**:
    // 그 여백은 터미널 셀이 창 가장자리에 붙지 않게 하려는 것이고, 편집기는 자기 배경·gutter·
    // 스크롤바로 이미 경계를 만든다. padding까지 적용하면 pane 안에 쓰이지 않는 띠가 한 겹 더 생겨
    // 문서가 차지할 자리가 줄고, 배경이 그 띠에서 끊겨 pane 배경이 비친다(2026-08-13 사용자 결정).
    //
    // **hit-test가 이 사각을 소비한다**(2026-08-19 — `hitTestBody`, §4.1g). 같은 `body`를 읽어야
    // "보이는 자리"와 "누르는 자리"가 갈리지 않는다 — 터미널이 `grid`를 쓰는 것과 달라지는 지점이다.
    // **한 겹 안쪽(`content_inset_px`)까지 같이 읽어야 한다**: 렌더가 그 안에 셀을 깔므로, 역변환에서
    // 그것을 빼먹으면 4px가 8px 셀의 절반이라 1칸 글자의 앞/뒤 판정이 전부 뒤집힌다(적대적 검증 실측).
    const rect = editorBodyRect(self, leaf_rect, term);
    if (rect.w == 0 or rect.h == 0) return null;

    // **행마다 op 넷을 쓴다**(본문·gutter·밴드·좌측 띠) — 밴드가 붙기 전의 둘에서 늘었다. 두 열로
    // 갈리면 열당 절반이므로, 1024면 열당 512 = **128행**이 실질 상한이라 아래 행 저장소(열당 256행)를
    // 키운 의미가 사라진다(리뷰 지적). 2560이면 열당 1,280 = 256행 + 여유다.
    var ops: [2560]chrome_draw.Op = undefined;
    var text: [16384]u8 = undefined;
    var runs: [1280]chrome_draw.Run = undefined;
    // **두 열로 갈리면 열당 절반이다**(`diff_frame.splitScratch`). 256이면 열당 128행 = 2,048px라,
    // 큰 화면을 꽉 채운 pane에서 아래쪽 행이 조용히 잘리고 스크롤바까지 틀린 자리에 선다(막대는
    // "보이는 높이"를 그린 행 수로 잡는다). 512면 열당 256행 = 4,096px로 실사용 화면을 덮는다.
    // op·run 저장소도 같은 계산으로 함께 키웠다(위) — 한쪽만 키우면 그쪽이 새 병목이 된다.
    var content_rows: [512]chrome_editor.content.Row = undefined;
    var visual_rows: [512]chrome_editor.visual_map.VisualRow = undefined;
    var gutter_rows: [512]chrome_editor.gutter.Row = undefined;
    var counts: [4096]u32 = undefined;
    // **세는 쪽과 그리는 쪽이 같은 크기를 쓴다**(`content.count_scratch_bytes`) — 갈리면 같은 줄의
    // 행 수가 달라진다.
    var count_scratch: [chrome_editor.content.count_scratch_bytes]u8 = undefined;
    // **블록 caret 반전 자리**(`Scratch.caret_cols`). 화면에 보이는 줄 수보다 넉넉히 잡는다 —
    // 멀티 커서가 한 화면에 이보다 많이 서면 뒤쪽 커서는 사각만 그려지고 글자가 반전되지 않는다.
    var caret_cols: [256]u32 = undefined;

    // **원점은 0,0이다.** 컴포넌트가 내는 좌표는 pane **상대**여야 한다 — 창 절대 좌표를 주면
    // `buildTextDrawList`가 셀 인덱스로 바꿀 때 pane 폭을 넘어 글자가 잘린다. 화면상의 자리는
    // 호출자의 `PanePlacement.origin_*`(= `PaneDraw.rect`)이 정한다.
    // 여백은 **원점**에 건다(위 `buildPaneOps` 주석) — 셀 격자는 이 원점에서 시작한다.
    const inset = chrome_editor.frame.content_inset_px;
    const inner: maru.session.SplitRect = .{
        .x = rect.x + inset,
        .y = rect.y + inset,
        .w = rect.w -| inset * 2,
        .h = rect.h -| inset * 2,
    };
    if (inner.w == 0 or inner.h == 0) return null;

    const wrap = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap; // 뷰 override가 config를 이긴다
    const scratch: FrameScratch = .{
        .ops = &ops,
        .text_bytes = &text,
        .runs = &runs,
        .content_rows = &content_rows,
        .visual_rows = &visual_rows,
        .gutter_rows = &gutter_rows,
        .row_counts = &counts,
        .count_scratch = &count_scratch,
        .caret_cols = &caret_cols,
    };

    // **캐시 자리는 필요할 때 잡고, 못 잡으면 없이 그린다**(§2.1의 "저하 동작"과 같은 결) — 캐시는
    // 빠르게 하는 장치이지 정확성의 전제가 아니라, 여기서 실패해도 화면은 그대로 나온다.
    //
    // 한 번 잡으면 줄이지 않는다: 접힘은 보이는 줄을 줄일 뿐 늘리지 못하므로 문서를 다시 열기 전까지
    // 이 크기로 충분하고, 매 프레임 크기를 재는 자리가 되지 않는다.
    const row_cache: ?*chrome_editor.frame.RowCache = blk: {
        // **폭을 라이브로 끄는 동안에는 다시 세지 않는다**(§2.1 저하 동작). 창 리사이즈는 여기 없다 —
        // 그쪽은 `windowDidResize`가 드래그 중 세션 resize를 아예 보류하고 끝날 때 한 번만 한다.
        term.rt.editor_row_cache.hold = widthDragActive(self);
        if (term.rt.editor_row_cache.prefix.len <= lines.len) {
            const grown = self.allocator.alloc(u32, lines.len + 1) catch break :blk null;
            if (term.rt.editor_row_cache.prefix.len > 0) self.allocator.free(term.rt.editor_row_cache.prefix);
            term.rt.editor_row_cache = .{ .prefix = grown }; // 자리가 바뀌었으니 키도 처음으로 되돌린다
        }
        break :blk &term.rt.editor_row_cache;
    };

    const pane_rect: chrome_draw.Rect = .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };

    // **검색 결과는 검색 중인 그 문서에만 칠한다**(§5.1). 열려 있는 편집기가 여럿이면 나머지에도
    // 같은 색이 깔리는데, 그러면 Enter가 어디로 갈지 화면이 말해 주지 못한다 — 터미널 쪽이
    // 활성 surface의 매치만 클립하는 것과 같은 규칙이다.
    const find_marks: ?[]const []const chrome_editor.frame.Mark = blk: {
        if (!isFindTarget(self, term)) break :blk null;
        // **닫은 채 ⌘G로 오가는 중이면 현재 매치만 그린다** — 스크롤백이 같은 자리에서 같은
        // 판정을 한다(`collectFindViewSpans`의 `if (find.open)`). 닫아 둔 검색의 나머지 강조까지
        // 남으면 "닫았는데 화면이 그대로"가 된다.
        const all = self.editor_find_matches.items;
        if (self.chrome_host.find.open) break :blk buildFindMarks(self, term, all);
        const cur = self.chrome_host.find.current;
        if (cur >= all.len) break :blk null;
        break :blk buildFindMarks(self, term, all[cur .. cur + 1]);
    };
    const find_current: ?chrome_editor.frame.CurrentMatch = blk: {
        if (find_marks == null) break :blk null;
        const vm = currentVisibleMatch(self, term) orelse break :blk null;
        break :blk .{ .line = vm.row, .start = vm.start };
    };
    // **막대 마커는 「보이는 줄」 축으로 낸다**(§4.1a). 강조(`find_marks`)는 화면 안만 담아서
    // 화면 **밖** 매치가 어디 있는지 말하지 못한다 — 그 답이 이 목록의 존재 이유다.
    //
    // **찾기가 닫히면 빈 조각이다.** 목록이 없는데 표시가 남으면 그것은 거짓이다.
    var marker_line_buf: [chrome_editor.scrollbar.marker_budget]u32 = undefined;
    var marker_lines: []const u32 = &.{};
    var marker_current: ?usize = null;
    if (isFindTarget(self, term) and self.chrome_host.find.open) {
        const cur_idx = self.chrome_host.find.current;
        const filled = markerRows(term, self.editor_find_matches.items, cur_idx, &marker_line_buf, &marker_current);
        marker_lines = marker_line_buf[0..filled];
    }

    // **조합 중이면 그 글자를 끼운 사본을 그린다**(N3). 문서는 그대로다 — 조합은 확정이 아니다.
    const preedit_rows = preeditLines(self, term, lines);
    defer if (preedit_rows) |rows| freePreeditLines(self, term, rows);
    const draw_lines: []const []const u8 = if (preedit_rows) |rows| rows else lines;

    const pf = if (diff_state_opt) |st| blk: {
        // **상태 줄은 가로로 안 민다** — 한 줄짜리 문구라 밀면 화면에서 사라진다.
        // 한 줄짜리 상태 문구다 — 캐시가 아낄 것이 없다.
        if (st.view != .compare) break :blk buildPaneOps(lines, null, null, lines.len, term.rt.editor_first_line, 0, 0, null, null, buildSelectionMarks(self, term), null, null, @as([]const u32, &.{}), null, syntaxColors(self, term), buildCaretRows(self, term), self.blink_visible, caretShape(self), wrap, term.rt.editor_tab_width, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
        // **좌우가 세로를 공유한다**(§3.5) — 행 배열이 이미 같은 길이라 같은 인덱스가 같은 높이다.
        // 가로는 각자다(§3.5의 그 규칙은 CM6가 "양쪽 줄 길이가 달라 한쪽을 따라가면 다른 쪽이
        // 엉뚱한 곳을 본다"고 적어 둔 근거에서 왔다) — 입력이 붙을 때 열별 `first_col`이 여기 온다.
        break :blk buildDiffPaneOps(
            // **검색 강조는 검색 중인 열에만 간다**(§5.1 「비교 뷰 검색」 — 한 번에 한 열이다).
            // 양쪽에 칠하면 카운터가 세지 않은 자리에 색이 남아, Enter 가 어디로 갈지 화면이 거짓말한다.
            .{ .lines = st.left_texts, .numbers = st.left_numbers, .total_lines = st.left_lines.len, .bands = st.left_bands, .marks = st.left_marks, .first_col = effectiveFirstCol(wrap, term, false), .content_max_cols = maxColsForRender(term, false), .selection_marks = buildDiffSelectionMarks(self, term, .left), .search_marks = diffSearchMarksFor(self, term, .left, find_marks), .search_current = diffSearchMarksFor(self, term, .left, find_current), .search_marker_lines = diffMarkerLinesFor(self, term, .left, marker_lines), .search_marker_current = diffSearchMarksFor(self, term, .left, marker_current) },
            .{ .lines = st.right_texts, .numbers = st.right_numbers, .total_lines = st.right_lines.len, .bands = st.right_bands, .marks = st.right_marks, .first_col = effectiveFirstCol(wrap, term, true), .content_max_cols = maxColsForRender(term, true), .selection_marks = buildDiffSelectionMarks(self, term, .right), .search_marks = diffSearchMarksFor(self, term, .right, find_marks), .search_current = diffSearchMarksFor(self, term, .right, find_current), .search_marker_lines = diffMarkerLinesFor(self, term, .right, marker_lines), .search_marker_current = diffSearchMarksFor(self, term, .right, marker_current) },
            term.rt.editor_first_line,
            effectiveFirstPiece(wrap, term),
            wrap,
            term.rt.editor_tab_width,
            pane_rect,
            @intCast(self.cell_width_px),
            @intCast(self.cell_height_px),
            @intCast(self.cell_height_px),
            scratch,
        );
    } else buildPaneOps(draw_lines, foldNumbers(term), foldMarks(term), term.rt.editor_lines.len, term.rt.editor_first_line, effectiveFirstPiece(wrap, term), effectiveFirstCol(wrap, term, false), maxColsForRender(term, false), row_cache, buildSelectionMarks(self, term), find_marks, find_current, marker_lines, marker_current, syntaxColors(self, term), buildCaretRows(self, term), self.blink_visible, caretShape(self), wrap, term.rt.editor_tab_width, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
    if (pf.ops_len == 0) return null;
    // **그린 행들을 Term에 남긴다**(§4.1g ②). `visual_rows`는 이 함수의 스택이라 반환과 함께
    // 사라지는데, 클릭은 렌더 **다음에** 오므로 그때 읽을 것이 있어야 한다 — 바로 아래 스크롤 값들을
    // 싣는 것과 같은 자리·같은 이유다(*"접힘을 아는 것은 렌더뿐"*).
    //
    // **못 담으면 그냥 안 담는다.** 저장소를 못 잡아도 화면은 이미 다 그렸고, 클릭이 그 프레임 동안
    // 안 될 뿐이다(§2.1 캐시가 "못 잡으면 없이 그린다"와 같은 결).
    if (term.rt.editor_diff) |st| {
        // **비교 뷰도 담는다**(§4.1g "비교 뷰"). 7차가 *"좌우가 섞인 배열이라 담아 두면 지뢰"*라 한
        // 것은 **섞인 하나**를 담는 것에 대한 지적이었고, 렌더가 이미 저장소를 반으로 갈라 각 열이
        // 자기 몫만 채우므로 갈라 받으면 그 지적이 성립하지 않는다.
        if (st.view == .compare) {
            const half = visual_rows.len / 2;
            const l = visual_rows[0..@min(pf.left_visual_rows, half)];
            const r = visual_rows[half..][0..@min(pf.right_visual_rows, visual_rows.len - half)];
            storeDiffHitRows(self, term, leaf_rect, l, r);
        }
    } else {
        storeHitRows(self, term, leaf_rect, visual_rows[0..@min(pf.visual_rows, visual_rows.len)]);
    }
    // 스크롤 입력이 읽을 값을 여기서 싣는다 — 접힘을 아는 것은 렌더뿐이다.
    term.rt.editor_total_visual_rows = pf.total_visual_rows;
    // **스크롤 상한도 렌더만 안다**(§4.1d) — 입력이 이것을 읽어 clamp한다.
    term.rt.editor_max_top_line = pf.max_top_line;
    term.rt.editor_max_top_piece = pf.max_top_piece;

    // **낡은 스냅숏으로 놓았던 검색 자리를 여기서 다시 잡는다**(그 필드 doc). 이 시점이면
    // 스냅숏도 시각 행 수도 이 프레임의 것이다.
    //
    // **파생값 대입보다 뒤여야 한다.** 재조준이 접힘을 펴면 `invalidateFoldDerived`가
    // `total_visual_rows`·`max_top_*`를 0으로 버리는데, 앞에 두면 위 세 줄이 **더 이상 없는
    // 배치의 값으로 그것을 되살린다**(적대적 검증 2026-08-24 실측: `total_visual=0`인데
    // `max_top=87`). 그 뒤 막대 드래그는 `max_top_line`만 보고 clamp하므로 없는 자리로 간다.
    //
    // **이 순서를 재는 판정자는 없다.** 세 번 시도해 세 번 다 픽스처가 그 상태를 못 만들었고
    // (재조준을 앞으로 되돌린 뮤턴트가 매번 살아남았다), **판정 안 하는 판정자를 두느니 공백을
    // 적기로 했다.** 이 슬라이스가 반복한 잘못이 그 반대였다 — 재는 척하는 판정자를 두는 것.
    // 근거는 실측 하나(위 수치)와 구조뿐이다: 무효화가 대입보다 먼저 나야 살아남는다.
    //
    // **비교 Term에서는 안 돈다.** 그쪽 꼬리는 `storeDiffHitRows`가 `editor_diff_hit_*`만 세우고
    // `editor_hit_geom`을 안 건드리므로, 여기서 신선도를 물으면 **비교 이전 배치의 스냅숏**을
    // 근거로 삼는다. 오늘은 `isFindTarget`이 막아 무해하지만 그 가드 하나에 걸쳐 두지 않는다.
    if (term.rt.editor_find_reveal_pending and term.rt.editor_diff == null) {
        term.rt.editor_find_reveal_pending = false;
        revealCurrentFindMatch(self, term);
        // **`metal_dirty`만으로는 부족하다** — 같은 tick 뒤쪽의 소거가 그것을 삼킨다(그 자리 doc).
        // 이 축은 소거를 지나 살아남아 다음 tick이 새 자리를 그리게 한다. 이것이 없으면 자리는
        // 맞고 화면은 옛 자리에 멈춘다(적대적 검증 2026-08-24 실측: tick 12번을 더 돌려도).
        self.reproject_after_frame = true;
    }
    // **막대 기하를 창 좌표로 옮겨 싣는다.** 컴포넌트는 pane 상대(원점 0,0)로 그리고 포인터는 창
    // 좌표로 오므로, 같은 축에서 비교하지 않으면 보이는 자리와 잡히는 자리가 갈린다. 여백(`inset`)은
    // 위 `buildPaneOps`가 원점에 건 그 값이다 — 여기서 다시 더해야 실제로 그려진 자리가 된다.
    term.rt.editor_scrollbar = if (pf.scrollbar) |bar| shiftScrollbar(bar, @intCast(rect.x + inset), @intCast(rect.y + inset)) else null;
    term.rt.editor_horizontal_scrollbar = if (pf.horizontal_scrollbar) |bar| shiftHorizontalScrollbar(bar, @intCast(rect.x + inset), @intCast(rect.y + inset)) else null;
    // 비교 뷰 오른쪽 열(단일 편집기는 `null`이라 그대로 비워진다).
    term.rt.editor_scrollbar_right = if (pf.right_scrollbar) |bar| shiftScrollbar(bar, @intCast(rect.x + inset), @intCast(rect.y + inset)) else null;
    term.rt.editor_horizontal_scrollbar_right = if (pf.right_horizontal_scrollbar) |bar| shiftHorizontalScrollbar(bar, @intCast(rect.x + inset), @intCast(rect.y + inset)) else null;
    // **아직 다 세지 못했으면 다음 프레임을 부른다**(§2.1 점진 계수). 이 렌더 루프는 dirty가 없으면
    // 투영을 건너뛰므로(idle skip), 이것을 안 세우면 진행이 거기서 멈춰 막대가 근사값인 채로 남는다.
    // 다 세면 더 요청하지 않으므로 idle로 돌아간다.
    if (row_cache) |c| {
        if (c.filled_upto < lines.len) self.metal_dirty = true;
    }

    const tokens = self.buildChromeTokens();
    const draws: chrome.ChromeDraw = .{ .layer = .sidebar, .ops = pf.ops };
    // 층은 `background_layer` 하나가 정한다(위 doc — Lab과 공유하는 단일 출처). §4.1b의 "op 순서상
    // 맨 처음"은 op 배열 안에서만 참이다 — quad와 셀은 파이프라인이 갈리므로 층을 따로 맞춰야 한다.
    // **창 투명도를 함께 건다.** 터미널은 배경을 그리지 않고 clear color가 그 자리인데, 그 alpha에
    // `window.opacity`가 곱해진다(`maru_metal_renderer.m`). 편집기만 불투명 solid로 덮으면 투명 배경을
    // 쓰는 창에서 이 pane만 데스크톱이 안 비쳐 두 뷰가 갈린다. `terminal_bg` 역할 quad에만 걸리므로
    // 스크롤바는 그대로다(반투명해지면 안 보인다).
    chrome_draw_lowering.appendBackgroundQuadsWithTerminalOpacity(
        self.allocator,
        &.{draws},
        &tokens,
        inner.x,
        inner.y,
        &self.gpu_quads,
        background_layer,
        workspace_ops.windowOpacityByte(self),
    );

    const cols: u16 = @intCast(@min(inner.w / @max(self.cell_width_px, 1), @as(u32, std.math.maxInt(u16))));
    const rows: u16 = @intCast(@min(inner.h / @max(self.cell_height_px, 1), @as(u32, std.math.maxInt(u16))));
    const dl = chrome_draw_lowering.buildTextDrawList(
        self.allocator,
        pf.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
    ) catch |e| {
        if (diag_gate.maruDebugEnabled()) editor_diag.debug("pane lowering failed: {s}", .{@errorName(e)});
        return null;
    };
    if (diag_gate.maruDebugEnabled()) editor_diag.debug(
        "pane rect=({d},{d} {d}x{d}) lines={d} ops={d} visual_rows={d} cells_grid={d}x{d} cells={d}",
        .{ rect.x, rect.y, rect.w, rect.h, lines.len, pf.ops_len, pf.visual_rows, cols, rows, dl.cells.len },
    );
    return .{ .rect = inner, .dl = dl }; // 원점 = 여백 안쪽(배경은 op이 음수로 덮는다)
}

/// N1: **편집기 Term** 하나를 만든다 — `createWebTerm`과 대칭이다(web-panel.md §6의 그 구조).
/// registry가 `LiveSurface` **editor arm** 슬롯을 소유하고, 그 arm의 sentinel `Surface`(빈 core)를
/// 제자리 init한다. **PTY spawn·attachSurface·pump가 없다** — 편집기는 셸이 아니다.
///
/// **sentinel surface가 왜 필요한가.** `Term.surface.id`가 유효해야 `surface_ptrs`·`activeSurface`
/// 계약이 깨지지 않는다(web이 같은 이유로 sentinel을 든다). 화면에 그리는 것은 그 core가 아니라
/// 편집기 프레임이다(§4).
///
/// 문서를 붙이는 것은 호출자다 — 이 함수는 Term과 슬롯만 만든다. Pane에 거는 것도 호출자 몫이다.
pub fn createEditorTerm(self: *AppSession) !*Term {
    const term = try self.allocator.create(Term);
    errdefer self.allocator.destroy(term);
    term.* = .{ .kind = .editor };

    const id = self.surface_ids.next(); // 앱 전역 발급(비재사용) — terminal·web과 같은 네임스페이스
    const slot = try self.live_registry.create(id, 0);
    // editor arm 확정 후 sentinel surface를 제자리 init. init 실패 시 슬롯은 아직 uninit이라
    // removeUninitialized로 deinit 없이 슬롯만 해제한다(web과 같은 규칙).
    slot.* = .{ .editor = .{ .internal_allocator = self.allocator } };
    term.surface = &slot.editor.surface;
    errdefer self.live_registry.removeUninitialized(id) catch {};
    term.surface.* = try maru.session.Surface.init(self.allocator, id, .{ .cols = 1, .rows = 1 });
    return term;
}

/// 일반 텍스트 파일을 **네이티브 편집기로** 열까. **기본이 네이티브다**(2026-08-19 사용자 결정).
///
/// **무엇을 내주고 정한 것인지 적어 둔다.** 비교(`MARU_NATIVE_DIFF`)는 CM6에서도 **읽기 전용**이라
/// 바꿔도 잃는 것이 없었지만, 일반 텍스트는 CM6에서 편집·저장이 된다(`EntryKind.text`의 기본 mode가
/// `.source_edit`이다). 네이티브 편집기는 N1이라 **읽기 전용이므로, 이 기본은 탐색기에서 연 파일을
/// 고칠 수 없게 만든다** — 편집이 붙는 N2까지 그렇다. 계획은 원래 이 전환을 N2에 두었고, 사용자가
/// 그 대가를 알고 앞당겼다(../../../../docs/plans/native-editor.md N1).
///
/// **`MARU_NATIVE_TEXT=0`으로 되돌릴 수 있다.** 고쳐야 하는 파일을 만나면 그 길로 CM6를 부른다 —
/// 훅을 지우는 것은 편집이 붙어 그 경로를 실제로 안 쓰게 된 뒤의 일이다(비교 훅과 같은 규율).
///
/// **세션이 init에서 한 번 읽어 든다**(`AppSession.native_text`) — `native_diff`와 같은 이유다.
pub fn nativeTextFromEnv() bool {
    const raw = std.c.getenv("MARU_NATIVE_TEXT") orelse return true;
    return editor_diff_ops.valueEnables(std.mem.span(raw));
}

/// 문서를 Term에 붙이기 **직전까지** 만들어 둔 것 — 문서·줄 배열·경로 복사 셋.
///
/// **왜 중간 상태에 이름을 줬나.** 파일 Term을 여는 경로(`pane.openFileTermInActivePane`)는 Term을
/// 만드는 **분기 전에** 이 파일을 네이티브로 열 수 있는지 알아야 한다 — 못 읽으면 CM6로 열어야
/// 하는데, 읽기와 부착이 한 함수에 붙어 있으면 그 판정을 할 수 없다(Term이 이미 만들어진 뒤다).
pub const Prepared = struct {
    opened: Opened,
    lines: [][]const u8,
    path: []u8,

    /// 아직 Term에 넘기지 않은 것을 되돌린다. **부착 뒤에는 부르지 않는다** — 그때부터 소유는
    /// Term이고 `destroyTerm`이 같은 것을 푼다(이중 해제).
    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        self.opened.deinit(allocator);
        allocator.free(self.lines);
        allocator.free(self.path);
    }
};

/// 경로를 읽어 부착 직전까지 만든다. **실패할 수 있는 일은 전부 여기서 끝난다.**
pub fn preparePath(self: *AppSession, path: []const u8) OpenFileError!Prepared {
    var opened = try openPath(self.io, self.allocator, path);
    errdefer opened.deinit(self.allocator);

    // **줄 슬라이스를 미리 만든다.** `frame.build`는 문서 전체를 받아야 스크롤바 길이가 맞는데(§4.1a),
    // 매 프레임 다시 만들면 프레임마다 할당이 생긴다. 줄들은 문서 버퍼를 빌리므로 문서보다 오래 살면 안 된다.
    const n = opened.file.lineCount();
    const lines = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
    errdefer self.allocator.free(lines);
    for (0..n) |i| lines[i] = opened.file.lineText(i) orelse "";

    const path_copy = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
    return .{ .opened = opened, .lines = lines, .path = path_copy };
}

/// 준비한 문서를 Term에 넘긴다. **실패하지 않는다** — 호출자는 이 앞에서 실패할 수 있는 일을 모두
/// 끝내 두어야 한다.
///
/// 예전에는 `term.rt`에 먼저 넘긴 뒤 경로 복사와 pane 등록을 했다. 그 둘이 실패하면 `errdefer
/// term_ops.destroyTerm`이 doc·lines를 풀고, 호출자의 `errdefer`가 **같은 것을 또 푼다** — 이중
/// 해제다. 같은 모양을 `materialize`와 `computeMarks`에서 이미 두 번 잡았고, 이 자리가 세 번째다.
/// 넘긴 뒤에는 실패 지점이 없으므로 errdefer가 겹칠 여지 자체가 사라진다.
pub fn finishAttach(self: *AppSession, term: *Term, prepared: Prepared) void {
    term.rt.editor_doc = prepared.opened;
    term.rt.editor_lines = prepared.lines;
    term.rt.editor_path = prepared.path;

    // **구문 트리를 여기서 연다**(§5.3). 문서와 수명이 같으므로 `releaseEditorTerm`이 함께 놓는다.
    // grammar가 없는 언어면 `provider`가 `null`이고 그 문서는 끝까지 무색이다 — 실패가 아니라
    // 저하다(§5). 여는 값은 문서 크기에 비례하지만(154KB 5ms 실측) **파일당 한 번**이고, 편집은
    // 증분이라 65µs다.
    term.rt.editor_syntax = syntax_color.open(
        term.rt.editor_doc.?.file.content,
        maru.session.editor.language.grammarForPath(prepared.path),
    );

    // **탭 폭을 config에서 받는다**(§9). 아래 파생값(접힘 겹수·`max_cols`)이 이 값에 달렸으므로
    // **그것들을 세기 전에** 넣어야 한다 — 뒤에 넣으면 세터가 방금 센 것을 도로 버린다.
    //
    // **여기서는 세터를 안 쓴다.** `setEditorTabWidth`는 *이미 선 파생값을 버리는* 함수인데 지금은
    // 버릴 것이 없다(이 줄 아래에서 처음 센다). 세터를 부르면 아직 없는 접힘 층을 지우고 다시
    // 세우려 해 같은 일을 두 번 한다.
    term.rt.editor_tab_width = editorTabWidth(self);

    // **접을 범위를 여기서 센다** — §4.1f가 정한 갱신 시점이 "문서를 열 때"다. 첫 접기 명령까지
    // 미루면 **펼쳐진 화살표(▾)가 그때까지 안 보여** 접을 수 있는 자리를 알 수 없다.
    //
    // **실패해도 파일은 연다.** 접힘은 부가 기능이고, 여는 것을 막는 이유는 UTF-8 아님 하나다(§3.5).
    ensureFoldRanges(self, term) catch {};
    rebuildVisible(self, term) catch {};
    // **가장 긴 줄도 여기서 센다** — 가로 스크롤바가 첫 프레임부터 서야 사용자가 그 축이 있다는
    // 것을 안다(굴려 보기 전에는 알 길이 없다. 2026-08-18 사용자 지적). 접힘 화살표와 같은 이유·
    // 같은 시점이다. 할당하지 않으므로 실패 지점이 없다.
    ensureMaxCols(term, false);
}

/// config가 정한 탭 폭(§9 — `editor.tab-width`).
///
/// **한 곳에서만 읽는다.** 값이 필요한 자리가 셋이고(문서 열기·config 재적용·기본값), 각자
/// `loaded_config`를 파고들면 스키마가 바뀔 때 한 곳만 따라가는 일이 난다 — 이 파일이 이미
/// 겪은 부류다(탭 폭을 상수로 읽던 세 자리를 적대적 검증이 잡았다).
pub fn editorTabWidth(self: *AppSession) u8 {
    const raw = self.loaded_config.config.editor.tab_width;
    // **파서가 이미 막는다** — u32 + range 필드는 범위 밖 값을 거절하고 기본값을 유지한다
    // (`config/schema.zig`). 그래도 묶는 이유는 **여기가 이 값의 단일 출처**여서다: 스키마에서
    // range가 빠지거나 테스트가 필드에 직접 쓰는 판에서도 0이 새면 탭스톱이 0이라 열이 안 늘어
    // 훑기가 끝나지 않는다. 도달 불가한 방어인 것을 알고 두는 것과 모르고 두는 것은 다르다.
    return @intCast(std.math.clamp(raw, 1, 16));
}

/// config가 다시 로드됐을 때 **열려 있는 편집기 Term 전부**에 탭 폭을 다시 넣는다.
///
/// **세터를 쓴다** — 여기서는 파생값이 이미 서 있고, 그것이 옛 폭으로 계산돼 있다. 세터가
/// 접힘 층·`max_cols`·가로 위치·행 수 캐시를 한 단위로 버리고 다시 세우며 보던 줄을 지킨다.
///
/// **값이 같으면 건너뛴다.** 세터 자신은 같은 값이어도 무효화하는데(그 doc: 필드에 직접 대입한
/// 뒤 부르는 경우를 막는다), 여기서는 그럴 일이 없고 reload마다 모든 편집기의 접힘이 펼쳐지면
/// 사용자가 접어 둔 것을 잃는다 — config에서 그 키를 안 건드린 reload가 대부분이다.
pub fn applyConfigTabWidth(self: *AppSession) void {
    const want = editorTabWidth(self);
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.kind != .editor) continue;
                if (term.rt.editor_tab_width == want) continue;
                setEditorTabWidth(self, term, want);
                // **다시 세어 준다.** 세터는 `max_cols`를 **버리기만** 하고(그것이 그 함수의 일이다),
                // 제품에서 다시 세는 자리는 `finishAttach`와 첫 가로 휠뿐이다. 그대로 두면
                // `maxColsForRender`가 0을 `null`로 읽어 **가로 막대를 아예 안 그리는데**, 그 막대는
                // 본문 아래 여백에서 자리를 먹으므로 생겼다 사라지면 **본문 높이가 출렁인다**
                // (`ensureMaxCols` doc이 금지한 그 상태다. ADV3-I가 세터 직후 `max_cols == 0`을
                // 단언하고 곧바로 손으로 다시 세는 것이 이 사실의 증거다).
                //
                // 비교 뷰는 좌우를 함께 센다 — 세터가 `foldsUnavailable` 조기 반환으로 오른쪽 값도
                // 버리는데, 그쪽 재계산 자리는 diff 결과가 다시 올 때뿐이라 더 오래 비어 있다.
                if (term.rt.editor_diff != null) {
                    ensureMaxColsForDiff(term);
                } else {
                    ensureMaxCols(term, false);
                }
            }
        }
    }
}

/// 경로를 열어 **활성 pane에 편집기 Term으로 붙인다**. N1의 "화면에 파일이 뜬다"가 여기서 닫힌다.
///
/// 실패는 호출자가 사용자에게 알린다 — §3.5가 "여는 것을 막는 이유는 UTF-8 아님 하나"라고 정했으므로
/// 나머지 이유를 같은 메시지로 뭉개면 그 계약을 확인할 수 없다.
pub fn openPathInActivePane(self: *AppSession, path: []const u8) OpenFileError!*Term {
    var prepared = try preparePath(self, path);
    errdefer prepared.deinit(self.allocator);

    const term = createEditorTerm(self) catch return error.OutOfMemory;
    errdefer term_ops.destroyTerm(self, term);

    const pane = pane_ops.activePane(self);
    pane.terms.append(self.allocator, term) catch return error.OutOfMemory;

    // 여기부터 실패 지점이 없다 — 소유가 Term으로 넘어간다.
    finishAttach(self, term, prepared);
    self.focusTerm(pane.terms.items.len - 1);
    self.metal_dirty = true;
    return term;
}

/// 편집기 pane의 세로 스크롤. **휠은 이 pane이 통째로 소유한다** — 편집기는 셸이 아니라 문서라
/// 스크롤백도 mouse reporting도 없고, 안 소유하면 뒤 터미널이 굴러가는 위화감이 남는다.
/// 편집기가 아니면 `false`(호출자가 지금까지의 경로로 흘린다).
///
/// **논리 줄 단위로 움직인다.** `editor_first_line`이 시각 행이 아니라 논리 줄이라 랩이 바뀌어도
/// 화면 맨 위 줄이 그대로다(그 필드 주석). 대가는 랩이 켜졌을 때 긴 줄이 한 번에 지나간다는 것이고,
/// 조각 단위 스크롤(`first_piece`)이 붙으면 여기가 그것을 함께 움직인다.
pub fn scrollLines(self: *AppSession, term: *Term, leaf_rect: maru.session.SplitRect, lines: i32) bool {
    if (term.kind != .editor) return false;
    if (lines == 0) return true; // 0줄이어도 **소유는 한다**(잔여 델타는 호출자의 accumulator가 든다)

    // 비교 Term은 좌우 **행** 배열이 문서다(좌우 길이가 같다). 문서 편집기는 줄 배열이다.
    const total: usize = if (term.rt.editor_diff) |st|
        (if (st.view == .compare) st.left_texts.len else 0)
    else
        // **`first_line`은 보이는 배열의 첨자다**(렌더가 그 배열과 이 값을 함께 받는다). 문서 줄
        // 수로 상한을 잡으면 접혔을 때 배열 밖으로 나간다 — 12만 줄을 접고 튕기면 **50,000**까지
        // 갔다(보이는 줄은 40,000). 그리기 직전 clamp가 화면은 가려 주지만, 그 사이에 이 값을 읽는
        // 쪽이 생기면 범위 밖이다. `clampScrollToGeometry`와 **같은 출처**를 쓴다.
        editorLines(term).len;
    if (total == 0) return true;

    // **마지막 화면이 비지 않게 멈춘다.** 끝을 넘겨 스크롤하게 두면 배경만 남은 화면이 나오고,
    // 사용자는 문서가 끝났는지 뷰가 깨졌는지 알 수 없다.
    //
    // **`body`에서 센다 — 격자가 아니다.** 편집기는 창 padding을 적용하지 않으므로(2026-08-13 결정)
    // `paneTermRect`(격자)로 세면 보이는 행이 실제보다 적어 상한이 그만큼 커지고, 끝까지 굴렸을 때
    // 아래에 빈 줄이 남는다 — 위 문장이 막겠다고 한 바로 그 상태다(리뷰 지적).
    const body = editorBodyRect(self, leaf_rect, term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = @max(inner_h / @max(self.cell_height_px, 1), 1);

    // **`visible`은 시각 행, `total`은 논리 줄이다.** 랩이 켜져 줄이 접히면 두 단위가 갈리므로 그대로
    // 빼면 안 된다 — 접힌 만큼 문서 끝이 **영영 닿지 않는다**(줄마다 3행으로 접히는 200줄 문서에서
    // 마지막 26줄이 그렇다). 렌더가 실어 둔 **문서 전체 시각 행 수**로 판정을 가른다.
    // **랩이면 시각 행 단위로 움직인다**(§4.1d — 앵커 + 조각 오프셋). 논리 줄만 움직이면 한 줄짜리
    // 문서에서 아무 데도 못 간다.
    if (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) {
        scrollPieces(self, term, lines, total, visible, visibleCols(self, body, term, false));
        return true;
    }

    const max_first = maxFirstLine(total, visible, term);
    if (max_first == 0) {
        // 문서가 화면에 다 들어간다 — 접혀 있든 아니든 움직일 이유가 없다.
        if (term.rt.editor_first_line != 0) {
            term.rt.editor_first_line = 0;
            self.metal_dirty = true;
        }
        return true;
    }

    const current: i64 = @intCast(term.rt.editor_first_line);
    // `lines > 0` = 휠 위 = 문서의 **앞쪽**으로(터미널 스크롤백과 같은 방향 규약).
    const next = std.math.clamp(current - @as(i64, lines), 0, @as(i64, @intCast(max_first)));
    const clamped: usize = @intCast(next);
    if (clamped != term.rt.editor_first_line) {
        term.rt.editor_first_line = clamped;
        self.metal_dirty = true;
    }
    return true;
}

/// 렌더에 넘길 가로 위치. **랩이면 0이다.**
///
/// 컴포넌트는 `!wrap or first_col == 0`을 어서션으로 요구한다. 그 불변식을 "상태를 고쳐서" 지키면
/// 랩을 켜는 경로가 늘 때마다 하나씩 빠뜨린다 — 실제로 `toggleWrap`은 지켰지만 **config 재적재**는
/// 안 지켰다(적대적 검증 2026-08-16). 값을 **읽는 자리**가 여기 하나뿐이므로, 여기서 세우면 어떤
/// 경로로 랩이 켜지든 깨질 수 없다.
///
/// **저장된 위치는 안 버린다.** 랩을 껐을 때 보던 자리로 돌아온다 — 켤 때 0으로 지우면 그 자리를
/// 잃는다.
/// 테스트가 본문 열 수를 확인하려고 부른다(같은 함수 — 규칙이 갈리지 않게).
pub fn visibleColsForTest(self: *AppSession, body: maru.session.SplitRect, term: *Term, right: bool) u16 {
    return visibleCols(self, body, term, right);
}

/// 한 열의 가로 위치를 상한 안으로 되돌린다. **최대 열은 위치가 0이 아닌 이상 이미 세어져 있다**
/// (`scrollCols`가 세운다) — 방어적으로만 본다.
fn clampOneColumn(self: *AppSession, first: *u16, max_cols: u32, visible_cols: u16) void {
    if (first.* == 0) return;
    const max_col: u32 = @min(max_cols -| visible_cols, @as(u32, chrome_editor.frame.max_first_col));
    if (@as(u32, first.*) > max_col) {
        first.* = @intCast(@min(max_col, std.math.maxInt(u16)));
        self.metal_dirty = true;
    }
}

/// 렌더에 넘길 조각 오프셋. **랩이 꺼져 있으면 0이다** — 줄마다 조각이 하나뿐이라 의미가 없고,
/// 저장된 값은 랩을 다시 켰을 때 돌아갈 자리다(가로의 `effectiveFirstCol`과 같은 규율).
fn effectiveFirstPiece(wrap: bool, term: *Term) u32 {
    return if (wrap) term.rt.editor_first_piece else 0;
}

fn effectiveFirstCol(wrap: bool, term: *Term, right: bool) u16 {
    // **열이 둘이어도 규칙은 하나다.** 오른쪽에 `if (wrap) 0 else …`를 다시 쓰면, 이 함수를 고칠 때
    // 한쪽만 따라온다 — 이 세션에서 같은 냄새로 세 번 물렸다(적대적 검증 2026-08-16).
    if (wrap) return 0;
    return if (right) term.rt.editor_first_col_right else term.rt.editor_first_col;
}

/// 랩이 켜졌을 때의 세로 스크롤 — **시각 행 단위**로 `(줄, 조각)`을 움직인다(§4.1d).
///
/// **Vim `smoothscroll`이 버그를 쏟은 자리다**(9.1.0211·0258·0260·0407 — off-by-one, 새 topline,
/// half-page 하위호환). 그래서 위치 정규화를 흩지 않고 여기와 `clampScrollToGeometry` 둘로만 둔다.
///
/// **상한은 렌더가 실어 둔 `(줄, 조각)`을 쓴다** — 여기서 문서 끝부터 조각을 누적하면 매 틱마다
/// 수십~수백 줄을 다시 조각내게 된다.
fn scrollPieces(self: *AppSession, term: *Term, delta_rows: i32, total_lines: usize, visible_rows: usize, content_cols: u16) void {
    // `delta_rows > 0` = 휠 위 = 문서 앞쪽으로(세로 규약 그대로).
    var line: i64 = @intCast(term.rt.editor_first_line);
    var piece: i64 = term.rt.editor_first_piece;
    var remaining: i64 = -@as(i64, delta_rows); // 아래로 갈 때 양수

    // **한 줄이 몇 조각인지는 그 줄만 세면 된다.** 지나는 줄마다 한 번씩이라 틱당 몇 줄이다.
    while (remaining != 0) {
        const rows = piecesOfLine(term, @intCast(line), content_cols);
        if (remaining > 0) {
            const room = @as(i64, rows) - 1 - piece; // 이 줄 안에서 더 내려갈 수 있는 행
            if (remaining <= room) {
                piece += remaining;
                break;
            }
            if (line + 1 >= @as(i64, @intCast(total_lines))) {
                piece = @max(0, @as(i64, rows) - 1);
                break;
            }
            remaining -= room + 1;
            line += 1;
            piece = 0;
        } else {
            if (-remaining <= piece) {
                piece += remaining;
                break;
            }
            if (line == 0) {
                piece = 0;
                break;
            }
            remaining += piece + 1;
            line -= 1;
            piece = @as(i64, piecesOfLine(term, @intCast(line), content_cols)) - 1;
        }
    }

    const next_line: usize = @intCast(@max(0, line));
    const next_piece: u32 = @intCast(@max(0, piece));
    if (next_line != term.rt.editor_first_line or next_piece != term.rt.editor_first_piece) {
        term.rt.editor_first_line = next_line;
        term.rt.editor_first_piece = next_piece;
        self.metal_dirty = true;
    }
    clampTopToMax(self, term, total_lines, visible_rows);
}

/// 그 논리 줄이 지금 폭에서 몇 조각인가(최소 1). 렌더와 **같은 함수**를 부른다 — 여기서 따로 세면
/// 화면과 스크롤이 갈린다.
fn piecesOfLine(term: *Term, line: usize, content_cols: u16) u32 {
    const lines = editorLines(term);
    if (line >= lines.len or content_cols == 0) return 1;
    var scratch: [chrome_editor.content.count_scratch_bytes]u8 = undefined; // 렌더와 같은 크기
    const c = chrome_editor.content.rowCount(
        lines[line],
        term.rt.editor_tab_width, // 렌더와 같은 값(단일 출처) — 갈리면 화면과 스크롤이 어긋난다
        content_cols,
        true,
        &scratch,
    );
    return @max(c.rows, 1);
}

/// 위치를 렌더가 실어 둔 상한 `(줄, 조각)` 안으로 되돌린다.
fn clampTopToMax(self: *AppSession, term: *Term, total_lines: usize, visible_rows: usize) void {
    // **"아직 안 그렸다"와 "문서가 다 들어간다"를 구분해야 한다.** 상한 `(0,0)`은 둘 다를 뜻할 수
    // 있어 그것만으로 가르면 짧은 문서가 clamp를 못 받는다(실제로 테스트 넷이 그렇게 깨졌다).
    // 렌더가 그렸는지는 `editor_total_visual_rows`가 이미 말한다.
    //
    // **첫 프레임 전에도 상한이 있어야 한다.** 렌더가 아직 안 실어 줬다고 무한정 가게 두면, 문서를
    // 열자마자 굴렸을 때 화면이 통째로 빈다 — 옛 논리 줄 경로는 상한을 그 자리에서 계산해 이 구멍이
    // 없었다. 그때는 **접힘을 모르므로 줄마다 1행으로 근사**한다(다음 프레임이 정확한 값으로 고친다).
    if (term.rt.editor_total_visual_rows == 0) {
        const fallback = total_lines -| visible_rows;
        if (term.rt.editor_first_line > fallback or (term.rt.editor_first_line == fallback and term.rt.editor_first_piece > 0)) {
            term.rt.editor_first_line = fallback;
            term.rt.editor_first_piece = 0;
            self.metal_dirty = true;
        }
        return;
    }
    const max_line = term.rt.editor_max_top_line;
    const max_piece = term.rt.editor_max_top_piece;
    const over = term.rt.editor_first_line > max_line or
        (term.rt.editor_first_line == max_line and term.rt.editor_first_piece > max_piece);
    if (!over) return;
    term.rt.editor_first_line = max_line;
    term.rt.editor_first_piece = max_piece;
    self.metal_dirty = true;
}

/// `editor_first_line`이 가질 수 있는 최대값. 0이면 문서가 화면에 다 들어간다.
///
/// **`visible`은 시각 행, `total`은 논리 줄이다.** 랩이 켜져 줄이 접히면 두 단위가 갈리므로 그대로
/// 빼면 안 된다 — 접힌 만큼 문서 끝이 **영영 닿지 않는다**(줄마다 3행으로 접히는 200줄 문서에서
/// 마지막 26줄이 그렇다). 렌더가 실어 둔 **문서 전체 시각 행 수**로 판정을 가른다.
fn maxFirstLine(total: usize, visible: usize, term: *Term) usize {
    const total_visual: usize = if (term.rt.editor_total_visual_rows > 0) term.rt.editor_total_visual_rows else total;
    if (total_visual <= visible) return 0;
    if (total_visual == total) return total -| visible; // 접힌 줄이 없다 — 정확히 계산된다
    // 접혔다. 논리 줄 몇 개가 마지막 화면을 채우는지는 여기서 모르므로 **닿을 수 있음**을 택한다
    // (마지막 줄이 맨 위에 올 때까지). 그 화면이 덜 차는 것보다 못 보는 것이 나쁘다 —
    // 조각 단위 스크롤이 붙으면 두 단위가 같아져 이 분기가 사라진다.
    return total -| 1;
}

/// 지금 기하로 두 축의 위치를 상한 안으로 되돌린다. **렌더가 그리기 전에 부른다.**
///
/// **상한은 보이는 크기에서 나오는데 그 크기는 창·분할·사이드바로 바뀐다.** 스크롤 입력이 올 때까지
/// 옛 위치가 남아 있으면 화면이 통째로 빈다 — 200줄 문서를 끝까지 굴려 둔 뒤 창을 높이면 97행이
/// 보이는데 `first_line`은 191이라 **9줄만 그려졌다**(적대적 검증 2026-08-16이 실측). 가로도 같은
/// 모양이었다(상한 111인데 위치 261 — 오른쪽 150열이 빔).
///
/// 리사이즈 경로에 붙이지 않는 이유: 기하는 창 크기 말고도 바뀐다(분할·사이드바 토글·탭 전환).
/// **그리기 직전이 그 전부를 지나는 유일한 자리**다.
pub fn clampScrollToGeometry(self: *AppSession, term: *Term, leaf_rect: maru.session.SplitRect) void {
    if (term.kind != .editor) return;
    const lines = editorLines(term);
    if (lines.len == 0) return;
    const body = editorBodyRect(self, leaf_rect, term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible_rows: usize = @max(inner_h / @max(self.cell_height_px, 1), 1);

    const max_first = maxFirstLine(lines.len, visible_rows, term);
    if (term.rt.editor_first_line > max_first) {
        term.rt.editor_first_line = max_first;
        self.metal_dirty = true;
    }

    // **랩이면 가로는 손대지 않는다.** 렌더가 `effectiveFirstCol`로 0을 쓰므로 불변식은 이미
    // 지켜졌고, 저장된 위치는 랩을 껐을 때 돌아갈 자리다 — 여기서 지우면 그것을 잃는다.
    if (!(term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap)) {
        // **두 열이 같은 규칙을 쓴다.** 왼쪽만 되돌리면 창이 커졌을 때 오른쪽 열만 빈다 — 실제로
        // 비교 가로 스크롤을 붙이자마자 그 상태가 됐다(적대적 검증 2026-08-16).
        clampOneColumn(self, &term.rt.editor_first_col, term.rt.editor_max_cols, visibleCols(self, body, term, false));
        clampOneColumn(self, &term.rt.editor_first_col_right, term.rt.editor_max_cols_right, visibleCols(self, body, term, true));
    }
}

/// 편집기 pane의 **가로** 스크롤. `cols > 0` = 왼쪽으로(문서 앞쪽).
///
/// **세로와 달리 넘칠 때만 소유한다.** 가로 축은 지금 pane **탭 바**를 굴리고 있고, 그것은 편집기
/// pane 위에서도 살아 있어야 한다는 결정이 이미 있다(`scroll.zig`의 세로 소유 주석 — 처음엔 편집기가
/// 곧바로 반환해 편집기 위 가로 스와이프가 아무 일도 안 했다). 문서가 안 넘치면 편집기는 이 축으로
/// 할 일이 없으므로 **넘길 때만** 가져간다 — 랩이 켜져 있으면 늘 안 넘친다.
///
/// **랩이 켜져 있으면 가로가 없다.** `visual_map`이 폭에 맞춰 잘라 두므로 넘칠 것이 없다.
pub fn scrollCols(self: *AppSession, term: *Term, leaf_rect: maru.session.SplitRect, cols: i32, x_px: ?f64) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) return false;

    const body = editorBodyRect(self, leaf_rect, term);

    // **비교는 열마다 따로 민다**(editor-surface-dock §3.5 — *"각 편집기가 자기 안에서 스크롤한다"*).
    // 공유하면 양쪽 줄 길이가 달라 한쪽을 따라갈 때 다른 쪽이 엉뚱한 곳을 본다. 어느 열인지는
    // 포인터가 정한다 — `diff_frame.columns()`가 주는 경계와 비교하며, 그 함수를 다시 부르므로
    // 규칙이 한 곳에만 있다. 포인터가 없으면(pane 밖 폴백) 왼쪽으로 친다.
    const right = isRightColumn(self, body, term, x_px);
    const lines = if (right) rightTexts(term) else editorLines(term);
    if (lines.len == 0) return false;
    const first_col = if (right) &term.rt.editor_first_col_right else &term.rt.editor_first_col;
    const max_cols = if (right) &term.rt.editor_max_cols_right else &term.rt.editor_max_cols;

    // **문서 전체에서 가장 긴 줄이 상한을 정한다.** 보이는 줄만 보면 세로로 굴릴 때마다 상한이
    // 출렁여, 오른쪽 끝을 보다가 위로 굴리면 본문이 제멋대로 왼쪽으로 튄다.
    ensureMaxCols(term, right); // 위 doc — 여는 경로와 같은 셈을 쓴다

    const visible = visibleCols(self, body, term, right);
    if (visible == 0) return false;
    if (max_cols.* <= visible) {
        // 안 넘친다 — 이 축은 탭 바가 쓴다(위 doc). 남아 있던 위치만 되돌린다.
        if (first_col.* != 0) {
            first_col.* = 0;
            self.metal_dirty = true;
        }
        return false;
    }

    // **상한이 하나 더 있다**(§3.8 — `frame.max_first_col`). 렌더 비용이 밀린 거리에 비례해서다.
    const max_first: u32 = @min(max_cols.* - visible, @as(u32, chrome_editor.frame.max_first_col));
    const current: i64 = first_col.*;
    const next = std.math.clamp(current - @as(i64, cols), 0, @as(i64, max_first));
    const clamped: u16 = @intCast(@min(next, std.math.maxInt(u16)));
    if (clamped != first_col.*) {
        first_col.* = clamped;
        self.metal_dirty = true;
    }
    return true;
}

/// 포인터가 비교의 **오른쪽 열** 위인가. 비교가 아니거나 포인터가 없으면 `false`(왼쪽).
fn isRightColumn(self: *AppSession, body: maru.session.SplitRect, term: *Term, x_px: ?f64) bool {
    const st = term.rt.editor_diff orelse return false;
    if (st.view != .compare) return false;
    const x = x_px orelse return false;
    const inset = chrome_editor.frame.content_inset_px;
    const inner_w = body.w -| inset * 2;
    const inner_h = body.h -| inset * 2;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = inner_w, .h = inner_h }, @intCast(self.cell_width_px));
    const rel = x - @as(f64, @floatFromInt(@as(i32, @intCast(body.x)) + @as(i32, @intCast(inset))));
    return rel >= @as(f64, @floatFromInt(cols.right.x));
}

/// 비교 오른쪽 열이 그리는 행들.
/// 비교 뷰에서 **검색할 열**(§5.1 「비교 뷰 검색」). 선택이 있는 열, 없으면 왼쪽이다 —
/// 가로 스크롤이 *"포인터가 정하고, 없으면 왼쪽으로 친다"* 로 고른 폴백과 같은 규칙이다.
///
/// **매번 다시 묻는다 — 베껴 들지 않는다.** `editor_diff_selection` 은 비교 내용이 다시 계산될 때
/// 버려지므로(옛 행 인덱스로 훑으면 죽는다), 베껴 두면 선택이 사라진 뒤에도 그 열을 계속 검색해
/// **화면은 왼쪽인데 결과는 오른쪽 것**이 된다.
pub fn diffSearchSide(self: *const AppSession, term: *const Term) DiffSide {
    // **명시값은 여기서 이긴다 — 호출자에서 갈아 끼우지 않는다.** 이 함수 하나를 **셋이** 읽는다:
    // 검색할 줄 배열(`findLines`)·강조(`diffSearchMarksFor`)·막대 마커(`diffMarkerLinesFor`).
    // 한 곳에서만 반영하면 나머지 둘이 옛 답을 따라가 **화면은 왼쪽인데 결과는 오른쪽 것**이 된다 —
    // 아래 「베껴 들지 않는다」가 막는 증상이 **다른 원인으로** 재발하는 자리다(§5.1).
    if (self.chrome_host.find.diff_side) |side| return side;
    const sel = term.rt.editor_diff_selection orelse return .left;
    return sel.side;
}

/// 검색 강조를 **이 열에 그릴 것인가**(§5.1 「비교 뷰 검색」 — 한 번에 한 열이다).
///
/// **호출 인자 안에 묻어 두면 잴 수 없다.** 양쪽에 칠하든 반대 열에 칠하든 화면만 다르고
/// 판정자는 전부 초록이었다(변이 D7·D8·D9). 그래서 결정을 여기 하나로 꺼낸다.
pub fn diffSearchMarksFor(self: *const AppSession, term: *const Term, side: DiffSide, marks: anytype) @TypeOf(marks) {
    return if (diffSearchSide(self, term) == side) marks else null;
}

/// 매치 목록을 **막대 마커의 행 목록**으로 옮긴다(§4.1a). 채운 개수를 돌려주고 현재 매치의
/// 자리를 `current` 에 적는다.
///
/// **축이 둘이라 여기서 갈린다.** 단일 편집기의 매치는 **문서 줄**이라 「보이는 줄」로 옮겨야
/// 하지만(접힘), 비교 뷰의 매치는 **이미 그 열의 정렬된 행**이다 — 옮기려 들면 없는 축을 하나
/// 더 만들고, 접힘 목록이 없어 대개 `null` 이 되어 **마커가 통째로 사라진다**.
///
/// **함수로 떼어낸 이유**는 이 갈림이 프레임 조립 안에 묻혀 있으면 판정자가 못 지나서다
/// (변이 M5 가 그 자리를 뒤집어도 아무도 안 잡았다).
pub fn markerRows(
    term: *Term,
    matches: []const maru.session.editor.find.Match,
    current_index: usize,
    out: []u32,
    current: *?usize,
) usize {
    const is_diff = term.rt.editor_diff != null;
    var k: usize = 0;
    for (matches, 0..) |m, i| {
        if (k >= out.len) break;
        // 단일 편집기에서 접혀 숨은 매치는 **접힌 줄 자리**에 찍는다 — 카운터에는 들어 있는데
        // 마커만 빠지면 「셋이라는데 두 개만 보인다」가 된다. 가면 펴지므로 도착하는 자리가 맞다.
        const row = if (is_diff) m.line else (visibleRowOfDocLine(term, m.line) orelse continue);
        if (i == current_index) current.* = k;
        out[k] = row;
        k += 1;
    }
    return k;
}

/// 막대 마커를 **이 열에 찍을 것인가**(§4.1a 「비교 뷰에서는 검색 중인 열의 막대에만」).
/// 강조와 같은 판정을 쓰되, 조각은 `null` 이 없으므로 **빈 조각이 「안 찍는다」**다.
pub fn diffMarkerLinesFor(self: *const AppSession, term: *const Term, side: DiffSide, lines: []const u32) []const u32 {
    return if (diffSearchSide(self, term) == side) lines else &.{};
}

/// 검색이 훑을 줄 배열 — 비교면 위 판정이 고른 열, 아니면 문서 줄이다.
pub fn findLines(self: *const AppSession, term: *Term) []const []const u8 {
    if (term.rt.editor_diff) |st| {
        if (st.view != .compare) return &.{};
        return if (diffSearchSide(self, term) == .right) st.right_texts else st.left_texts;
    }
    return term.rt.editor_lines;
}

fn rightTexts(term: *Term) []const []const u8 {
    const st = term.rt.editor_diff orelse return &.{};
    if (st.view != .compare) return &.{};
    return st.right_texts;
}

/// 이 편집기가 그리는 줄들(비교면 왼쪽 행, 아니면 문서 줄).
/// **렌더가 그리는 줄들.** 스크롤 상한·열 수 계산이 전부 이것을 봐야 한다 — 렌더가 접힘을 적용한
/// 배열을 그리는데 상한을 전체 문서로 세면, 접은 뒤 끝까지 굴렸을 때 **화면이 통째로 빈다**
/// (실측: 300줄을 접어 100줄이 됐는데 `first_line`이 266까지 갔다. 적대적 검증 2026-08-17).
fn editorLines(term: *Term) []const []const u8 {
    if (term.rt.editor_diff) |st| {
        if (st.view != .compare) return &.{};
        return st.left_texts;
    }
    if (term.rt.editor_visible_lines.len > 0) return term.rt.editor_visible_lines;
    return term.rt.editor_lines;
}

/// **접힘 범위를 세는 원본.** 접힌 결과가 아니라 문서 전체다 — `editorLines`를 쓰면 접은 뒤 다시
/// 세면서 접힌 것을 못 보게 된다(순환).
///
/// **diff 상태에서는 비어 있다 — 그것이 곧 "접을 수 없다"의 단일 출처다**(`foldsUnavailable`).
fn foldSourceLines(term: *Term) []const []const u8 {
    if (term.rt.editor_diff != null) return &.{};
    return term.rt.editor_lines;
}

/// **본문**이 쓰는 열 수 — pane 폭이 아니다. gutter(줄 번호·접기 자리)를 빼야 한다.
///
/// 컴포넌트가 폭에서 뽑는 것과 **같은 계산**을 부른다(`sideMetrics` → `geometry.compute`). 여기서
/// 직접 세면 두 곳이 갈려, 가장 긴 줄의 끝에 못 닿거나(상한이 작다) 오른쪽에 빈 자리가 남는다.
fn visibleCols(self: *AppSession, body: maru.session.SplitRect, term: *Term, right: bool) u16 {
    const inset = chrome_editor.frame.content_inset_px;
    const inner_w = body.w -| inset * 2;
    const inner_h = body.h -| inset * 2;
    // **자릿수는 렌더와 같은 출처로 센다.** 렌더는 `total_lines`에 **문서 줄 수**를 넘기는데
    // (`st.left_lines.len`), 여기서 **행 수**(filler 포함)를 쓰면 둘이 갈린다. `min_line_number_cells`
    // (Monaco `lineNumbersMinChars` = 5)가 10만 줄까지 가려 주지만, 가려진다고 같은 것은 아니다.
    // **렌더와 같은 출처여야 한다.** 렌더는 gutter 폭을 `total_lines`(문서 줄 수)로 잡는데 여기서
    // 보이는 줄 수를 쓰면 갈린다 — 접으면 그 둘이 실제로 달라진다(12만 줄 문서를 접어 4만 줄이
    // 보이면 6자리 대 5자리. 실측 88 대 89열. 적대적 검증 2026-08-17).
    const line_count = if (term.rt.editor_diff) |st| blk: {
        if (st.view != .compare) break :blk editorLines(term).len;
        break :blk if (right) st.right_lines.len else st.left_lines.len;
    } else term.rt.editor_lines.len;

    // **비교 뷰는 두 열로 갈린다.** pane 폭을 통째로 쓰면 폭을 두 배로 잡아 조각 수가 절반이 되고
    // (세로 스크롤이 어긋난다) 가로 상한도 두 배로 커진다 — 실측: 오른쪽 열 본문이 46열인데 102열로
    // 잡아 끝까지 밀어도 198열에서 멈췄다(실제 상한 254).
    //
    // **나머지 픽셀은 오른쪽이 가져간다**(`columns()` — pane 오른쪽 끝에 안 칠한 띠가 남지 않게).
    // 그래서 열마다 자기 폭으로 센다.
    const side_w = if (term.rt.editor_diff) |st| blk: {
        if (st.view != .compare) break :blk inner_w;
        const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = inner_w, .h = inner_h }, @intCast(self.cell_width_px));
        break :blk if (right) cols.right.w else cols.left.w;
    } else inner_w;
    const m = chrome_editor.diff_frame.sideMetrics(side_w, inner_h, @intCast(self.cell_width_px), @intCast(self.cell_height_px));
    const layout = chrome_editor.geometry.compute(m.total_cols, line_count, .{});
    return layout.content.width;
}

/// 렌더에 넘길 **가장 긴 줄의 폭**. 0은 "아직 안 셌다"는 뜻이라 `null`로 바꾼다 — 렌더가 0을 길이로
/// 믿으면 막대가 문서 전체를 덮는 것처럼 그려진다.
/// 편집기 pane의 **폭이 지금 매 프레임 바뀌는 중인가**(§2.1 저하 동작의 조건).
///
/// **창 리사이즈는 여기 없다.** `MaruAppHost.windowDidResize`가 `inLiveResize` 동안 세션 resize를
/// 보류하고 `windowDidEndLiveResize`에서 한 번만 적용하므로(zsh가 SIGWINCH마다 redraw하며 프롬프트를
/// 중복시키던 문제로 도입된 정책), 창을 끄는 동안 이 pane의 폭은 그대로다.
///
/// 남는 **세 경로**가 라이브다. 셋을 각각 물어야 하는 것 자체가 이 코드베이스의 상태를 드러낸다 —
/// "지금 폭을 끄는 중인가"의 단일 출처가 없고 capture 권위가 셋으로 갈려 있다(pane divider는 CIM2로
/// `InteractionState`에 이관됐고, 나머지 둘은 `PointerGestureOwner`의 서로 다른 variant다).
///
/// | 경로 | drag마다 부르는 것 | capture 권위 |
/// |---|---|---|
/// | 사이드바 우측 경계 | `sidebar_ops.setSidebarWidthPx` | `PointerGestureOwner.sidebar_divider` |
/// | pane divider | tick coalescer가 최종 좌표 하나를 적용 | `InteractionState`(CIM2) |
/// | dock 바깥 경계 | `dock_ops.setDockSizeFromPointer` | `PointerGestureOwner.dock_outer_divider` |
///
/// **dock을 빠뜨렸다가 적대적 검증에서 잡았다**(2026-08-18) — `setDockSizeFromPointer`는 dock이
/// `.right`면 x축을 끌고 `resizeTabPanes`로 전 탭 pane을 다시 재운다. 그 경로에서만 저하가 안 걸려
/// 큰 문서가 여전히 프레임당 수십 ms였다.
///
/// dock이 `.bottom`이면 높이만 바뀌어 캐시 키(줄 배열·본문 폭·랩·탭 폭)가 그대로다. 그때는 `hold`가
/// 켜져도 캐시가 맞아 저하 분기를 타지 않으므로, side를 따로 보지 않는다 — 판정을 늘리면 그 자리가
/// 또 하나의 "빠뜨릴 수 있는 조건"이 된다.
fn widthDragActive(self: *const AppSession) bool {
    return self.pointerGestureIs(.sidebar_divider) or
        self.pointerGestureIs(.dock_outer_divider) or
        pane_ops.dividerCaptureActive(self);
}

/// 활성 편집기의 **본문 선택을 클립보드로** 복사한다(§4.1g). 복사할 것이 없으면 `false`.
///
/// **바이트를 지금 뜬다**(*"나중에 지금 선택을 복사해"*가 아니라). 주소창 ⌘X가 같은 규율을 쓰고,
/// 이유도 같다 — 비동기로 미루면 그 사이 선택이 바뀌어 사용자가 본 것과 다른 것이 복사된다.
/// Swift가 다음 tick `pendingClipboard` drain에서 NSPasteboard에 쓴다(OSC52 write와 같은 경로라
/// 새 ABI가 필요 없다).
///
/// **문서 원본에서 뜬다** — 화면에 그린 것(`editor_lines`)이 아니라 `editor_doc`의 byte다. 둘은
/// §3.8 표기(`<U+202E>`)와 초장문 줄 축소에서 갈리고, 사용자가 붙여넣기를 기대하는 것은 **원본**이다.
///
/// **계약과 다른 자리 하나 — caret만 있을 때**(적대적 검증 2026-08-25에 드러났다).
/// [문서 모델](../../../../docs/native-editor-document-model.md) §3.4는 *"선택 없이 복사하면 caret이
/// 있는 줄 전체를 담고, 그 사실을 함께 기억한다"*고 정하는데 여기서는 **거절한다**(`false`).
///
/// 지금 그렇게 두는 이유: 그 규칙의 나머지 절반이 *"그렇게 담긴 것을 붙여넣으면 caret 위치가
/// 아니라 **줄 단위로** 삽입한다"*이고, 그것을 지키려면 "빈 선택에서 온 것인가" 플래그를 함께
/// 들어야 한다. **그 플래그를 읽는 유일한 소비처가 붙여넣기이고, 붙여넣기는 편집 연산이라 아직
/// 없다.** 줄만 담고 플래그를 안 들면 나중 붙여넣기가 줄 중간에 끼워 넣어 §3.4가 경고한 그대로
/// 줄이 깨진다.
///
/// 그래서 이 자리는 **빈칸이지 결정이 아니다** — 붙여넣기 슬라이스가 둘을 함께 세운다.
pub fn copySelection(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const doc = term.rt.editor_doc orelse return false;
    const bytes = doc.file.content;

    // **커서가 여럿이면 조각도 여럿이다**(§3.4). 시스템 클립보드에는 **문서 순서로 줄바꿈 연결**해
    // 넣는다 — 다른 앱이 붙여넣을 때 자연스러우라고 그 절이 정한 규칙이다.
    //
    // **조각 경계를 함께 기억한다**(§3.4). 붙여넣기가 그 소비처다 — 그것이 없던 동안에는 기억할
    // 이유가 없어 미뤄 두었고, 이제 함께 선다.
    var iter = selections(term);
    if (iter.count() == 0) return false;

    var ranges: std.ArrayList(occurrence.Range) = .empty;
    defer ranges.deinit(self.allocator);
    while (iter.next()) |sel| {
        const lo = sel.start();
        const hi = @min(sel.end(), bytes.len);
        if (hi <= lo or lo >= bytes.len) continue; // caret뿐이거나 낡은 offset이다
        ranges.append(self.allocator, .{ .start = lo, .end = hi }) catch return false;
    }

    // **선택이 없으면 caret이 있는 줄 전체다**(§3.4). 그 사실을 표식으로 함께 기억해 두었다가
    // 붙여넣을 때 **줄 단위로** 넣는다 — caret 자리에 끼워 넣으면 줄이 깨진다.
    //
    // 이것이 없어서 선택 없이 `⌘C`를 누르면 **아무 일도 안 일어났다**(적대적 검증 2026-08-26 —
    // 판정자가 오히려 "선택이 없으면 복사도 없다"로 그 상태를 고정하고 있었다). 다른 편집기는
    // 전부 줄을 담는다.
    const from_empty = ranges.items.len == 0;
    if (from_empty) {
        const primary = term.rt.editor_selection orelse return false;
        const line_idx = doc.file.lines.lineAt(@min(primary.focus, bytes.len));
        const line = doc.file.lines.line(line_idx) orelse return false;
        // **줄 끝 문자를 포함한다** — 줄 단위 삽입이 그것으로 줄을 만든다.
        ranges.append(self.allocator, .{ .start = line.start, .end = line.end_with_ending }) catch return false;
    }
    if (ranges.items.len == 0) return false;

    std.mem.sort(occurrence.Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: occurrence.Range, b: occurrence.Range) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(self.allocator);
    for (ranges.items, 0..) |r, i| {
        if (i > 0) out.append(self.allocator, '\n') catch return false;
        out.appendSlice(self.allocator, bytes[r.start..r.end]) catch return false;
        ends.append(self.allocator, out.items.len) catch return false;
    }

    const captured = out.toOwnedSlice(self.allocator) catch return false; // OOM이면 복사 안 함(선택 보존)
    const ends_owned = ends.toOwnedSlice(self.allocator) catch {
        self.allocator.free(captured);
        return false;
    };
    // **기억은 클립보드 문자열과 한 단위로 선다.** 하나만 서면 붙여넣기가 남의 문자열을 우리
    // 경계로 자른다 — `describes`가 문자열을 대조해 막지만, 애초에 어긋난 상태를 만들지 않는다.
    const meta_text = self.allocator.dupe(u8, captured) catch {
        self.allocator.free(captured);
        self.allocator.free(ends_owned);
        return false;
    };
    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
    self.chrome_clipboard_write = captured;
    if (self.editor_clipboard_meta) |*m| m.deinit(self.allocator);
    self.editor_clipboard_meta = .{
        .text = meta_text,
        .ends = ends_owned,
        .from_empty_selection = from_empty,
    };
    return true;
}

/// 커서 자리를 **보이는 줄 축**으로 자른다 — `buildSelectionMarks`와 같은 축·같은 이유다.
///
/// **띠와 따로 만드는 이유**: 커서는 길이 0이라 `Mark`로 쓸 수 없고(폭 0 사각은 안 보인다),
/// 선택이 있는 커서도 caret은 **focus 쪽 한 점**에 선다 — 띠의 끝과 같은 자리가 아닐 수 있다
/// (뒤로 끌면 focus가 앞쪽이다).
///
/// 저장소는 `Term.rt`가 들고 재사용한다(프레임마다 잡지 않는다 — 마크가 그러듯).
fn buildCaretRows(self: *AppSession, term: *Term) ?[]const []const u32 {
    var iter = selections(term);
    const cursor_count = iter.count();
    if (cursor_count == 0) return null;
    const doc = term.rt.editor_doc orelse return null;

    const numbers = term.rt.editor_visible_numbers;
    const visible = term.rt.editor_visible_lines;
    const lines_len = if (visible.len > 0) visible.len else term.rt.editor_lines.len;
    if (lines_len == 0) return null;

    if (term.rt.editor_caret_rows.len < lines_len or term.rt.editor_caret_buf.len < cursor_count) {
        const grown_rows = self.allocator.alloc([]const u32, lines_len) catch return null;
        const grown_buf = self.allocator.alloc(u32, cursor_count) catch {
            self.allocator.free(grown_rows);
            return null;
        };
        if (term.rt.editor_caret_rows.len > 0) self.allocator.free(term.rt.editor_caret_rows);
        if (term.rt.editor_caret_buf.len > 0) self.allocator.free(term.rt.editor_caret_buf);
        term.rt.editor_caret_rows = grown_rows;
        term.rt.editor_caret_buf = grown_buf;
    }
    const rows = term.rt.editor_caret_rows[0..lines_len];
    const buf = term.rt.editor_caret_buf[0..cursor_count];
    @memset(rows, &.{});

    // **문서 순서로 모은다** — 렌더가 한 줄의 위치들이 오름차순이라고 보고(`columnsAtOffsets`가
    // 그것을 단언한다), 커서 추가 순서로 채우면 그 계약이 깨진다. 띠 쪽에서 겪은 그 결함이다.
    var focuses = buf;
    var n: usize = 0;
    while (iter.next()) |sel| {
        focuses[n] = @intCast(@min(sel.focus, doc.file.content.len));
        n += 1;
    }
    focuses = focuses[0..n];
    std.mem.sort(u32, focuses, {}, std.sort.asc(u32));

    // 줄과 커서가 둘 다 문서 순서이므로 함께 걷는다(띠와 같은 병합 훑기).
    var first: usize = 0;
    var at: usize = 0;
    var any = false;
    for (0..lines_len) |i| {
        const line = visibleDocLine(doc, numbers, visible, i) orelse continue;
        const line_end = line.contentEnd();
        while (first < focuses.len and focuses[first] < line.start) first += 1;
        const row_start = at;
        var k = first;
        while (k < focuses.len and focuses[k] <= line_end) : (k += 1) {
            buf[at] = focuses[k] - @as(u32, @intCast(line.start));
            at += 1;
        }
        if (at > row_start) {
            rows[i] = buf[row_start..at];
            any = true;
        }
    }
    if (!any) return null;
    return rows;
}

/// primary와 나머지 커서를 **합쳐 보는 유일한 통로**(§3.2 멀티 selection).
///
/// `editor_selection`만 읽으면 커서가 여럿일 때 **하나만 보인다** — 그 결함은 화면에서 조용하다
/// (띠가 하나만 서고, 복사가 한 조각만 담는다). 그래서 소비처가 직접 두 필드를 읽지 않고 여기를 쓴다.
///
/// **primary가 먼저 나온다.** 문서 순서가 필요한 소비처(복사 — §3.4)는 받아서 정렬한다.
pub const SelectionIter = struct {
    primary: ?editor_selection.Selection,
    extras: []const editor_selection.Selection,
    i: usize = 0,

    pub fn next(self: *SelectionIter) ?editor_selection.Selection {
        const p = self.primary orelse return null;
        if (self.i == 0) {
            self.i = 1;
            return p;
        }
        if (self.i - 1 >= self.extras.len) return null;
        const s = self.extras[self.i - 1];
        self.i += 1;
        return s;
    }

    pub fn count(self: SelectionIter) usize {
        if (self.primary == null) return 0;
        return 1 + self.extras.len;
    }
};

/// 이 Term의 커서 전부.
pub fn selections(term: *Term) SelectionIter {
    return .{ .primary = term.rt.editor_selection, .extras = term.rt.editor_extra_selections };
}

/// primary 말고 나머지를 버린다. **커서를 새로 놓는 모든 경로가 부른다** — 클릭 한 번이 멀티커서를
/// 정리하지 않으면 사용자는 커서를 없앨 방법이 없다(VSCode도 클릭으로 정리한다).
pub fn clearExtraSelections(self: *AppSession, term: *Term) void {
    if (term.rt.editor_extra_selections.len == 0) return;
    self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = &.{};
}

/// **다음 일치를 찾아 커서를 하나 더 놓는다**(§9.1 — VSCode `⌘D`. 지금 chord는 `⌘⌃D`다).
///
/// 새로 놓은 것이 **primary가 된다** — 다음에 또 누르면 그 다음 일치로 이어져야 하고, 화면이
/// 따라가는 기준도 방금 놓은 자리다. 그래서 옛 primary는 나머지 쪽으로 내려간다.
/// 커서를 옮기는 단위(§3.2). **키가 아니라 의미로 적는다** — 같은 이동을 여러 chord가 부르고
/// (Home과 ⌘←), 플랫폼마다 관례가 다르기 때문이다.
pub const Motion = enum {
    char_left,
    char_right,
    word_left,
    word_right,
    /// smart home — 첫 글자와 줄 머리를 오간다.
    line_start,
    line_end,
    line_up,
    line_down,
    doc_start,
    doc_end,
    page_up,
    page_down,
    /// 괄호 짝으로 점프(§3.9c). 가로 이동 부류다 — goal 열을 버린다.
    bracket_match,
};

/// 열↔offset 변환을 **화면과 같은 출처**로 만든다(§5.4 MUST).
///
/// `motion.zig`가 열을 직접 세지 않는 이유가 이것이다 — 세면 `columnsAtOffsets`와 갈리는 두 번째
/// 출처가 생기고, 그 어긋남은 "커서가 눈에 보이는 자리와 다른 곳에 선다"로 나타난다. 정방향은
/// `columnsAtOffsets`, 역방향은 §4.1g의 `byteAtPoint`를 **열을 픽셀로 바꿔** 그대로 쓴다.
/// **열의 왼쪽 끝을 정확히 겨냥하려고 크게 잡는 탐침 셀 폭.**
///
/// `byteAtPoint`는 열을 픽셀로 받으므로, "7열"을 x=7px로 주면 **6번 글자의 오른쪽 절반**으로 읽혀
/// 한 칸 밀린다(적대적 검증 2026-08-26 — `MOV3`이 21 대신 22를 봤다). 폭을 크게 잡으면
/// `col * cell`이 그 열의 **왼쪽 끝**에 정확히 떨어져 **글자 시작 열에서는** 반올림이 없다.
///
/// **글자 안쪽 열에서는 여전히 반올림한다 — 그리고 그것이 계약이다**(2라운드 적대적 검증이
/// "반올림이 일어나지 않는다"고 적은 앞 문장을 반증했다). 탭 하나가 열 [0,4)를 먹을 때 목표 열
/// 1은 탭 **앞**(byte 0), 2·3은 탭 **뒤**(byte 1)에 선다 — 즉 **가장 가까운 경계**다.
///
/// 왜 그 계약인가: 그러면 **열 하나를 경계로 옮기는 규칙이 저장소에 하나뿐**이다. 같은 열을
/// 클릭해서 가든 ↓로 내려와서 가든 **같은 자리**에 선다. 내림으로 따로 정하면 규칙이 둘이 되고,
/// 사용자는 "클릭과 화살표가 다른 곳에 선다"로 겪는다. `MOT8`이 이 계약을 판정한다.
///
/// 화면 셀 폭과 무관해도 된다 — 이 변환은 **비율만** 쓰기 때문이다(열 = x / cell).
const column_probe_cell_px: u16 = 64;

const ProductColumnMap = struct {
    tab_width: u16,
    /// **열의 왼쪽 끝을 정확히 겨냥하려고 크게 잡는다.**
    ///
    /// `byteAtPoint`는 **클릭** 매핑이라 글자 중간을 넘으면 다음 글자로 넘어간다 — 클릭에는 맞지만
    /// 열→offset에는 **내림**이 필요하다. 셀 폭을 1로 두면 "7열"이 곧 x=7px이라 그 반올림에 걸려
    /// 한 칸 밀렸다(적대적 검증 2026-08-26 — `MOV3`이 21 대신 22를 봤다). 폭을 크게 잡으면
    /// `col * cell`이 그 열의 **왼쪽 끝**에 정확히 떨어져 반올림이 일어나지 않는다.
    ///
    /// 화면 셀 폭과 무관해도 된다 — 이 변환은 **비율만** 쓰기 때문이다(열 = x / cell).
    fn columnOf(ctx: *const anyopaque, line: []const u8, byte_in_line: usize) u32 {
        const self: *const ProductColumnMap = @ptrCast(@alignCast(ctx));
        var offs = [_]u32{@intCast(@min(byte_in_line, line.len))};
        var out = [_]u32{0};
        chrome_editor.content.columnsAtOffsets(line, self.tab_width, &offs, &out, std.math.maxInt(u32));
        return out[0];
    }

    fn offsetOf(ctx: *const anyopaque, line: []const u8, column: u32) usize {
        const self: *const ProductColumnMap = @ptrCast(@alignCast(ctx));
        const x_px: i32 = @intCast(@as(u64, column) * column_probe_cell_px);
        return chrome_editor.content.byteAtPoint(
            line,
            self.tab_width,
            0, // 줄 시작부터 센다 — 랩된 행이 아니라 논리 줄이다
            0,
            0,
            std.math.maxInt(u32), // 행 폭 상한 없음: 논리 줄 전체가 대상이다
            x_px,
            column_probe_cell_px,
        );
    }

    fn map(self: *const ProductColumnMap) editor_motion.ColumnMap {
        return .{ .ctx = self, .columnOf = columnOf, .offsetOf = offsetOf };
    }
};

fn productColumnMap(term: *Term) ProductColumnMap {
    return .{ .tab_width = term.rt.editor_tab_width };
}

/// 한 페이지가 몇 줄인가. **렌더가 굳힌 기하에서 읽는다** — 클릭이 같은 값을 읽는 것과 같은 출처다.
fn pageRows(term: *Term) usize {
    // **렌더가 마지막에 굳힌 행 수**다 — 클릭이 읽는 것과 같은 스냅숏이라 화면과 어긋나지 않는다.
    // 편집 직후에는 이것이 0으로 비워지고(`refreshAfterEdit` ⑸) 다음 프레임이 다시 채운다.
    // 그 사이에 PageDown이 오면 1줄로 떨어진다 — **0으로 두면 죽은 키가 된다**.
    return @max(1, term.rt.editor_hit_rows_len);
}

/// 편집 **전** 화면 맨 위 줄이 어디였는지 — byte offset으로 든다.
///
/// **줄 번호로는 안 된다.** 뷰포트 **위**에서 줄이 늘거나 줄면 같은 번호가 다른 내용을 가리켜
/// 화면이 그만큼 흔들린다(멀티커서 편집·undo가 실제로 그렇게 한다). §4.1c가 *"N2에서 Zed형
/// 앵커로 승격한다"*고 적은 자리이고, 여기서 **스크롤 앵커만** 먼저 승격한다 — 이 슬라이스가
/// 요구하는 것이 그것이고, 나머지(선택·표식 앵커)는 각자 필요할 때 같은 방식으로 옮긴다.
const ScrollAnchor = struct { off: usize };

fn captureScrollAnchor(term: *Term) ?ScrollAnchor {
    const doc = term.rt.editor_doc orelse return null;
    const top: u32 = @intCast(term.rt.editor_first_line);
    if (top == 0) return null; // 맨 위다 — 밀릴 것이 없다
    const doc_line = docLineOfVisibleRow(term, top) orelse return null;
    const line = doc.file.lines.line(doc_line) orelse return null;
    return .{ .off = line.start };
}

/// 편집이 민 만큼 앵커를 옮겨 **화면이 제자리에 남게** 한다.
///
/// **`refreshAfterEdit` 뒤에 부른다** — 줄 인덱스가 새 문서의 것이어야 옮긴 offset이 어느 줄인지
/// 답할 수 있다.
fn restoreScrollAnchor(self: *AppSession, term: *Term, saved: ?ScrollAnchor, d: maru.session.editor.delta.Delta) void {
    const a = saved orelse return;
    const doc = term.rt.editor_doc orelse return;
    const moved = maru.session.editor.delta.mapOffset(d, a.off);
    const doc_line: u32 = @intCast(doc.file.lines.lineAt(@min(moved, doc.file.content.len)));
    const row = visibleRowOfDocLine(term, doc_line) orelse return;
    if (row != term.rt.editor_first_line) setEditorTop(self, term, row);
}

/// 랩이 켜졌을 때 **한 시각 행** 위/아래로 옮긴 offset. 랩이 꺼졌거나 조립할 수 없으면 `null`.
///
/// **왜 논리 줄로는 안 되는가**: 랩이 켜지면 한 논리 줄이 여러 행을 차지하므로, ↓ 한 번이 화면에서
/// 서너 행을 건너뛴다. 사용자는 "한 줄 아래"를 눌렀는데 화면이 그만큼 안 맞는다.
///
/// **경계를 세지 않고 읽는다.** 어디서 접히는지는 `visual_map.pieces`가 정하는데(cluster를 안
/// 쪼개므로 열 상한의 배수가 아니다), 그 결과가 **렌더가 굳힌 `VisualRow` 배열**에 이미 원본 byte와
/// 열로 실려 있다(§4.1g의 스냅숏). 여기서 다시 세면 그것이 곧 두 번째 규칙이고, 걸친 2칸 글자와
/// §3.8 표기에서 갈린다.
///
/// **그래서 화면에 그려진 범위 안에서만 답한다.** 스냅숏 밖으로 나가는 이동은 `null`을 내고
/// 호출자가 논리 줄로 떨어진다 — 그 경우 caret 노출이 스크롤을 따라오게 하므로 다음 눌림에는
/// 다시 시각 축으로 돈다. **모를 때 추측해 두 번째 규칙을 만드는 것보다 낫다.**
///
/// **이음매(`assoc`)를 여기서 정한다**(§4 — 그동안 "부수효과"로 남아 있던 자리): 목표 열이 행
/// 경계에 정확히 걸리면 **뒤 행의 머리**를 고른다. `paintCarets`의 열 거르기가 이미 그렇게 그리고
/// 있었고(그래서 화면과 일치한다), CM6의 `assoc = 1`과도 같다.
fn movedVisualRow(self: *AppSession, term: *Term, focus: usize, goal: editor_selection.Goal, down: bool) ?usize {
    // **랩이 꺼졌으면 논리 줄 경로로 보낸다.** 그때 조각은 줄과 1:1이라 두 경로가 **같은 답**을
    // 내므로(뮤턴트로 확인 — 이 분기를 지워도 아무 판정자가 안 깨진다) 정답 문제가 아니라
    // **의존성 문제**다: 시각 경로는 렌더 스냅숏을 읽으므로, 굳이 랩도 아닌데 그것에 기대면
    // 스냅숏이 낡았을 때 답이 없어진다(`null` → 폴백). 랩이 아니면 스냅숏 없이도 답할 수 있다.
    const wrap = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap;
    if (!wrap) return null;
    const rows = term.rt.editor_hit_rows_len;
    if (rows == 0) return null; // 아직 안 그렸다 — 논리 줄로 떨어진다
    const doc = term.rt.editor_doc orelse return null;

    const lines = doc.file.lines;
    const doc_line = lines.lineAt(focus);
    const line = lines.line(doc_line) orelse return null;
    const visible_row = visibleRowOfDocLine(term, @intCast(doc_line)) orelse return null;
    const first: u32 = @intCast(term.rt.editor_first_line);
    if (visible_row < first) return null;
    const screen_line: u32 = visible_row - first;

    // 이 논리 줄의 조각들을 스냅숏에서 찾는다.
    const snap = term.rt.editor_hit_rows[0..rows];
    var pcm = productColumnMap(term);
    const map = pcm.map();
    const text = doc.file.content[line.start..line.contentEnd()];
    const col = if (focus >= line.contentEnd())
        map.columnOf(map.ctx, text, text.len)
    else
        map.columnOf(map.ctx, text, focus - line.start);

    // 지금 caret이 든 조각과, 목표가 될 조각을 스냅숏에서 고른다.
    var here: ?usize = null;
    for (snap, 0..) |vr, i| {
        if (vr.line != screen_line) continue;
        if (vr.start_col <= col) here = i else break;
    }
    const cur = here orelse return null;
    const target = if (down) cur + 1 else (if (cur == 0) return null else cur - 1);
    if (target >= snap.len) return null; // 화면 밖 — 논리 줄로 떨어진다

    const dest = snap[target];
    // **행 안 열**을 유지한다. 목표가 `line_end`면 그 행의 끝이다.
    const within: u32 = switch (goal) {
        .line_end => std.math.maxInt(u32),
        .none => col -| snap[cur].start_col,
        .col => |c| c -| snap[cur].start_col,
    };
    const want_col = dest.start_col +| within;

    const dest_doc_line = docLineOfVisibleRow(term, first + dest.line) orelse return null;
    const dest_line = lines.line(dest_doc_line) orelse return null;
    const dest_text = doc.file.content[dest_line.start..dest_line.contentEnd()];
    return dest_line.start + map.offsetOf(map.ctx, dest_text, want_col);
}

/// **보이는 줄** 인덱스가 어느 문서 줄인가 — `visibleRowOfDocLine`의 역이다.
///
/// 접힘이 켜지면 둘이 1:1이 아니므로 `editor_visible_numbers`(줄 번호 = 문서 줄 + 1)를 읽는다.
/// 접힘이 없으면 그 배열이 비고 두 축이 같다.
fn docLineOfVisibleRow(term: *const Term, visible_row: u32) ?u32 {
    const numbers = term.rt.editor_visible_numbers;
    if (term.rt.editor_visible_lines.len == 0 or numbers.len == 0) {
        return if (visible_row < term.rt.editor_lines.len) visible_row else null;
    }
    if (visible_row >= numbers.len) return null;
    const n = numbers[visible_row] orelse return null;
    return n - 1;
}

/// 한 커서를 옮긴 결과 offset. **선택을 어떻게 다룰지는 호출자가 정한다**(Shift 여부).
fn movedOffset(
    self: *AppSession,
    term: *Term,
    doc: Opened,
    sel: editor_selection.Selection,
    how: Motion,
    goal: *editor_selection.Goal,
) usize {
    const content = doc.file.content;
    const lines = doc.file.lines;
    const focus = @min(sel.focus, content.len);
    const line_idx = lines.lineAt(focus);
    const line = lines.line(line_idx) orelse return focus;
    var pcm = productColumnMap(term);
    const map = pcm.map();

    return switch (how) {
        // **가로 이동은 목표 열을 버린다**(§3.2) — 남기면 다음 세로 이동이 편집 전 열로 튄다.
        .char_left => blk: {
            goal.* = .none;
            break :blk editor_motion.prevCharBoundary(content, focus);
        },
        .char_right => blk: {
            goal.* = .none;
            break :blk editor_motion.nextCharBoundary(content, focus);
        },
        .word_left => blk: {
            goal.* = .none;
            break :blk editor_motion.wordLeft(content, focus);
        },
        .word_right => blk: {
            goal.* = .none;
            break :blk editor_motion.wordRight(content, focus);
        },
        .line_start => blk: {
            goal.* = .none;
            break :blk editor_motion.lineStartSmart(content, line, focus);
        },
        // **짝이 없으면 제자리다**(§3.9c) — 「없다」와 「여기다」는 다른 답이고, 없는데 옮기면
        // 사용자가 자기 자리를 잃는다.
        .bracket_match => blk: {
            goal.* = .none;
            break :blk editor_motion.matchingBracket(content, focus) orelse focus;
        },
        .line_end => blk: {
            // **줄 끝은 목표를 `line_end`로 세운다** — End 뒤에 아래로 내려가면 계속 줄 끝을 따라간다.
            goal.* = .line_end;
            break :blk editor_motion.lineEnd(line);
        },
        .doc_start => blk: {
            goal.* = .none;
            break :blk 0;
        },
        .doc_end => blk: {
            goal.* = .none;
            break :blk content.len;
        },
        .line_up, .line_down, .page_up, .page_down => blk: {
            // **세로 이동은 목표 열을 유지한다.** 없으면 지금 자리에서 세운다.
            if (goal.* == .none) goal.* = editor_motion.goalAt(content, line, focus, map);
            // **랩이 켜졌으면 시각 행이 먼저다**(§4.1g). 논리 줄로만 움직이면 ↓ 한 번이 화면에서
            // 서너 행을 건너뛴다 — 사용자가 누른 것과 화면이 안 맞는다. 스냅숏 밖으로 나가는
            // 이동은 `null`이라 아래 논리 줄 경로로 떨어지고, caret 노출이 스크롤을 따라오게 하므로
            // 다음 눌림에는 다시 시각 축으로 돈다.
            if (how == .line_up or how == .line_down) {
                if (movedVisualRow(self, term, focus, goal.*, how == .line_down)) |v| break :blk v;
            }
            const step: usize = switch (how) {
                .line_up, .line_down => 1,
                // 페이지는 **보이는 행 수**만큼이다. 화면이 아직 안 굳었으면(첫 프레임) 1로 떨어진다 —
                // 0으로 두면 PageDown이 아무 일도 안 해 사용자가 키가 죽은 줄 안다.
                else => pageRows(term),
            };
            const down = (how == .line_down or how == .page_down);
            const target = if (down)
                @min(line_idx + step, lines.lineCount() -| 1)
            else
                line_idx -| step;
            const dest = lines.line(target) orelse break :blk focus;
            break :blk editor_motion.offsetForGoal(content, dest, goal.*, map);
        },
    };
}

/// **커서를 옮긴다**(§3.2). `extend`면 anchor를 남겨 선택이 늘어난다(Shift).
///
/// 커서가 여럿이면 **전부** 옮긴다 — 하나만 옮기면 나머지가 제자리에 남아 다음 타이핑이 두 축으로
/// 갈린다. 옮긴 뒤 겹치면 합친다(`mergeOverlapping`이 그 규칙을 소유한다).
///
/// **묶음을 끊는다.** 커서가 편집 아닌 이유로 움직였으므로 §3.3의 그룹핑 규칙 그대로다 — 안 끊으면
/// "옮겨서 친 글자"가 앞의 타이핑과 한 묶음이 되어 undo 한 번에 둘 다 사라진다.
/// 커서가 화면 밖이면 **최소한만** 굴려 보이게 한다(§5.2 reveal의 줄 축).
///
/// **가운데로 보내지 않는다** — ⌘F의 `revealCurrentFindMatch`는 다음 매치가 어디로 이어지는지
/// 보여야 해서 가운데지만, 화살표는 한 번에 한 줄이라 가운데로 튕기면 **누를 때마다 화면이 반쯤
/// 갈아엎어진다**. VSCode·Vim도 caret 이동은 가장자리에서만 한 줄씩 민다.
///
/// **판정은 렌더가 굳힌 스냅숏으로 한다**(§4.1g ②) — 여기서 pane 사각을 다시 구하면 마지막
/// 프레임과 다른 값이 나오고, 그러면 "보인다"가 화면과 갈린다. 스냅숏이 지금 화면을 설명하지
/// 못하면(그 사이 접힘·랩·탭 폭·폰트가 바뀌었으면) **묻지 않고 민다** — 모를 때는 움직이는 쪽이
/// 덜 나쁘다. 그 규율과 대조식은 `revealCurrentFindMatch`가 값비싸게 세운 것을 그대로 쓴다.
///
/// **줄 축만 본다.** 한 화면보다 긴 줄 안에서의 가로 이동은 이 함수가 못 잡는다 — §5.2가 소유할
/// 2차원 reveal이고 그때 함께 닫힌다.
fn revealPrimaryCaret(self: *AppSession, term: *Term) void {
    revealPrimaryCaretRows(self, term, 0);
}

/// `fallback_rows`: 스냅숏이 비어 있을 때 쓸 **편집 전 행 수**.
///
/// **편집 경로가 이것을 준다.** `refreshAfterEdit`가 렌더 스냅숏을 비우므로(§4.1g ⑸ — 클릭이 옛
/// 자리를 답하지 않게), 편집 직후의 노출은 늘 "아직 안 그렸다" 갈래로 떨어진다. 그 갈래는 커서
/// 줄을 **맨 위에 두므로**, 그대로 두면 **한 글자 칠 때마다 화면이 그 줄을 천장으로 끌어올린다**
/// (적대적 검증 2026-08-26이 잡았다). 편집 전 화면이 몇 줄이었는지는 그 순간에도 알 수 있다.
fn revealPrimaryCaretRows(self: *AppSession, term: *Term, fallback_rows: usize) void {
    const doc = term.rt.editor_doc orelse return;
    const sel = term.rt.editor_selection orelse return;
    const doc_line: u32 = @intCast(doc.file.lines.lineAt(@min(sel.focus, doc.file.content.len)));

    // **먼저 편다.** 접힌 채로는 보이는 줄에 없어 아무 데도 못 간다.
    const unfolded = revealFoldedLine(self, term, doc_line);
    const row = visibleRowOfDocLine(term, doc_line) orelse return;

    const rows = term.rt.editor_hit_rows_len;
    if (rows == 0) {
        // 스냅숏이 없다. **편집 전 행 수를 알면 그것으로 최소 스크롤**을 하고, 그것도 없으면
        // (정말 한 프레임도 안 그렸다) 맨 위에 둔다.
        if (fallback_rows == 0) {
            setEditorTop(self, term, row);
            return;
        }
        const top0: u32 = @intCast(term.rt.editor_first_line);
        if (row < top0) setEditorTop(self, term, row) else if (row >= top0 + fallback_rows) setEditorTop(self, term, row -| (@as(u32, @intCast(fallback_rows)) -| 1));
        return;
    }

    const geom = term.rt.editor_hit_geom;
    const snapshot_is_current = geom.top_line == term.rt.editor_first_line and
        geom.top_piece == term.rt.editor_first_piece and
        geom.visible_len == editorLines(term).len and
        geom.wrap == (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) and
        geom.tab_width == term.rt.editor_tab_width and
        geom.cell_w_px == self.cell_width_px and
        geom.cell_h_px == self.cell_height_px;

    if (!unfolded and snapshot_is_current) {
        for (term.rt.editor_hit_lines[0..rows]) |drawn| {
            if (drawn == doc_line) return; // 이미 보인다 — 굴리면 화면만 튄다
        }
    }

    // 밖이다. **어느 쪽으로 나갔는지**에 따라 가장자리에 붙인다.
    if (row < term.rt.editor_first_line) {
        setEditorTop(self, term, row);
    } else {
        // 아래로 나갔다 — 그 줄이 **마지막 줄**이 되도록 민다. 논리 줄 수로 센다(시각 행 수로
        // 세면 랩에서 과대 계수라 필요 이상으로 굴러간다 — 가운데 배치가 같은 이유로 논리 줄을 쓴다).
        setEditorTop(self, term, row -| (drawnDocLines(term) -| 1));
    }
}

pub fn moveCarets(self: *AppSession, term: *Term, how: Motion, extend: bool) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;
    const primary = term.rt.editor_selection orelse return false;

    var moved_any = false;
    var next_primary = primary;
    {
        var goal = primary.goal;
        const off = movedOffset(self, term, doc, primary, how, &goal);
        next_primary = if (extend)
            editor_selection.Selection.fromAnchorRange(primary.anchorLo(), primary.anchorHi(), off, primary.kind)
        else
            editor_selection.Selection.at(off);
        next_primary.goal = goal;
        if (off != primary.focus or (!extend and !primary.isEmpty())) moved_any = true;
    }

    // 나머지 커서도 같은 단위로 옮긴다.
    for (term.rt.editor_extra_selections) |*extra| {
        var goal = extra.goal;
        const off = movedOffset(self, term, doc, extra.*, how, &goal);
        const next = if (extend)
            editor_selection.Selection.fromAnchorRange(extra.anchorLo(), extra.anchorHi(), off, extra.kind)
        else
            editor_selection.Selection.at(off);
        if (off != extra.focus or (!extend and !extra.isEmpty())) moved_any = true;
        extra.* = next;
        extra.goal = goal;
    }

    if (!moved_any) return false;

    term.rt.editor_selection = next_primary;
    breakUndoGroup(term); // 커서가 편집 아닌 이유로 움직였다(§3.3)
    revealPrimaryCaret(self, term); // 화면 밖으로 나갔으면 따라간다
    self.metal_dirty = true;
    return true;
}

/// 위/아래로 커서 추가 — 각 커서마다 한 줄 위(아래)에 **사본**을 더한다
/// ([문서 모델](../../../../docs/native-editor-document-model.md) §3.2b).
///
/// **선택 모양이 유지된다.** anchor 와 focus 를 **각자의 목표 열로** 옮기므로 caret 하나면 caret 이,
/// 범위를 고른 상태면 같은 모양의 범위가 생긴다. `Selection.anchor_goal` 이 그것을 위해 서 있었고
/// (§3.2 *"goal column이 양끝에 각각 있다"*), **이 함수가 그 필드를 읽는 첫 소비자**다.
///
/// **못 가면 안 더한다.** 문서 끝(처음)에서 clamp 하면 원본과 같은 자리가 되고 병합이 곧바로 지운다 —
/// VSCode 는 만들었다가 지우지만 우리는 만들지 않는다(§3.2b: 결과가 같다면 상한을 안 축내는 쪽).
///
/// **읽기 전용에서도 선다** — 문서를 바꾸지 않고, 멀티 커서 복사는 읽기 전용에서 뜻이 있다(§3.4).
pub fn addCursorVertically(self: *AppSession, term: *Term, down: bool) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;
    const primary = term.rt.editor_selection orelse return false; // 씨앗이 없다(§3.2b)

    var buf: std.ArrayList(editor_selection.Selection) = .empty;
    defer buf.deinit(self.allocator);
    buf.append(self.allocator, primary) catch return false;
    buf.appendSlice(self.allocator, term.rt.editor_extra_selections) catch return false;

    // **사본은 원본 뒤에 모아 넣는다.** 원본을 먼저 다 훑고 나서 더해야 방금 만든 사본을 다시
    // 훑어 한 번에 여러 줄이 늘어나지 않는다(VSCode `addCursorUp` 도 원본 배열만 훑는다).
    const original_len = buf.items.len;
    var added: usize = 0;
    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        if (original_len + added >= editor_selection.max_cursors) break; // 상한(§3.2)
        const sel = buf.items[i];
        const how: Motion = if (down) .line_down else .line_up;
        // **anchor 와 focus 를 각자의 목표 열로 옮긴다** — 하나만 옮기면 선택이 찌그러진다.
        // `movedOffset` 을 그대로 쓴다: 랩이 켜졌으면 시각 행, 아니면 논리 줄로 떨어지고 문서 끝은
        // clamp 한다 — 세로 이동이 이미 정한 그 규칙을 두 번째로 적으면 둘이 갈린다.
        var focus_goal = sel.goal;
        const new_focus = movedOffset(self, term, doc, sel, how, &focus_goal);
        const anchor_lo = sel.anchorLo();
        var anchor_goal = sel.anchor_goal;
        const new_anchor = if (anchor_lo == sel.focus)
            new_focus // caret 하나 — 두 번 재지 않는다
        else blk: {
            // anchor 를 focus 자리에 놓은 사본으로 물어본다 — 그 함수는 `focus` 만 옮긴다.
            var probe = editor_selection.Selection.at(anchor_lo);
            probe.goal = sel.anchor_goal;
            const moved = movedOffset(self, term, doc, probe, how, &anchor_goal);
            break :blk moved;
        };
        // **제자리면 안 더한다** — 문서 끝에서 clamp 된 것이고, 더해도 병합이 지운다.
        if (new_focus == sel.focus and new_anchor == anchor_lo) continue;
        // `kind` 는 승계하지 않는다(§3.2b) — 한 줄 위에 같은 낱말이 있을 이유가 없다.
        var copy = editor_selection.Selection.fromPoints(new_anchor, new_focus);
        copy.goal = focus_goal; // 옮기며 세운 목표 열을 사본이 이어받는다(§3.2)
        copy.anchor_goal = anchor_goal;
        buf.append(self.allocator, copy) catch break;
        added += 1;
    }
    if (added == 0) return false;

    // **primary 는 새로 생긴 쪽으로 간다**(§3.2) — 위로 더하면 맨 위, 아래로 더하면 맨 아래.
    // 그래야 `revealPrimaryCaret` 이 방금 늘어난 곳을 따라간다.
    var primary_idx: usize = original_len;
    var k: usize = original_len + 1;
    while (k < buf.items.len) : (k += 1) {
        const better = if (down)
            buf.items[k].focus > buf.items[primary_idx].focus
        else
            buf.items[k].focus < buf.items[primary_idx].focus;
        if (better) primary_idx = k;
    }

    const merged = editor_selection.mergeOverlapping(buf.items, primary_idx);
    const items = buf.items[0..merged.len];
    const extras = self.allocator.alloc(editor_selection.Selection, items.len - 1) catch return false;
    var w: usize = 0;
    for (items, 0..) |sel, idx| {
        if (idx == merged.primary) continue;
        extras[w] = sel;
        w += 1;
    }
    if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = extras;
    term.rt.editor_selection = items[merged.primary];

    breakUndoGroup(term); // 커서가 늘었다 — 다음 타이핑은 새 묶음이다(§3.3)
    revealPrimaryCaret(self, term);
    self.metal_dirty = true;
    return true;
}

pub fn addNextOccurrence(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g) — 이 슬라이스 밖
    const doc = term.rt.editor_doc orelse return false;

    var buf: std.ArrayList(editor_selection.Selection) = .empty;
    defer buf.deinit(self.allocator);

    // **고른 것이 없으면 아무 일도 하지 않는다.** 앞선 판은 `Selection.at(0)`을 씨앗으로 삼아
    // 문서 **첫 낱말**을 조용히 골랐다 — 사용자가 있지도 않은 커서 자리를 짐작당하는 셈이다.
    // caret이 서면(N2 다음 조각) 그때 "커서 밑 낱말"이 정당한 씨앗이 되고, `occurrence`는 이미
    // 그 경우를 답한다(OCC1). 그때까지는 거절이 맞다.
    const seed = term.rt.editor_selection orelse return false;

    // **커서 수에 상한이 있다**(`selection.max_cursors`). 그 상수는 "검색 '모두 선택'이 입력을
    // 멈추지 않게" 하려고 이미 서 있었는데 이 경로가 그것을 안 봤다 — 흔한 글자에서 키를 누르고
    // 있으면 커서가 끝없이 늘고, 마크 저장소와 훑기 비용이 그 수에 비례한다.
    if (term.rt.editor_extra_selections.len + 1 >= editor_selection.max_cursors) return false;

    buf.append(self.allocator, seed) catch return false;
    buf.appendSlice(self.allocator, term.rt.editor_extra_selections) catch return false;

    // **`nextOccurrence`는 문서 순서를 요구한다**(이미 고른 자리를 이분 탐색으로 거른다).
    // 커서는 추가 순서로 들고 있으므로 여기서 한 번 맞춘다 — primary가 어디로 가든 상관없다.
    // 씨앗은 값으로 이미 떠 뒀다.
    std.mem.sort(editor_selection.Selection, buf.items, {}, struct {
        fn lessThan(_: void, a: editor_selection.Selection, b: editor_selection.Selection) bool {
            return a.start() < b.start();
        }
    }.lessThan);
    const seed_index = for (buf.items, 0..) |s, i| {
        if (s.start() == seed.start() and s.end() == seed.end()) break i;
    } else 0;

    const found = maru.session.editor.occurrence.nextOccurrence(
        doc.file.content,
        buf.items,
        seed_index,
    ) orelse return false;

    // **caret에서 시작하면 커서가 늘지 않는다 — 낱말이 그 caret을 대신한다.**
    // 옛 판은 caret을 나머지로 내려 커서가 둘이 됐는데, 그 중 하나는 길이 0이라 **화면에 안 보이는데
    // 타이핑은 거기로도 간다.** VSCode도 첫 `⌘D`는 커서를 늘리지 않고 낱말을 잡을 뿐이다.
    // (`occurrence`가 caret 씨앗에 낱말을 답하는 것이 그 첫 걸음이고 — OCC1 — 여기가 그 짝이다.)
    if (seed.len() > 0) {
        // 옛 primary를 나머지로 내리고 새 자리를 primary로 세운다.
        const grown = self.allocator.alloc(
            editor_selection.Selection,
            term.rt.editor_extra_selections.len + 1,
        ) catch return false;
        @memcpy(grown[0..term.rt.editor_extra_selections.len], term.rt.editor_extra_selections);
        grown[grown.len - 1] = seed;
        if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
        term.rt.editor_extra_selections = grown;
    }

    // **`kind`는 잡은 단위를 말한다 — 짐작으로 `.word`를 붙이지 않는다.** 그 값은 이어지는 드래그가
    // 무엇으로 늘어날지를 정하므로(§3.2 anchor가 점이 아니라 범위인 이유), 낱말이 아닌 조각을
    // `.word`라 적으면 드래그가 없는 단위로 늘어난다. `occurrence`가 낱말 경계를 봤는지 여부와
    // 같은 판정을 여기서도 쓴다.
    const found_is_word = blk: {
        const w = editor_selection.wordRangeAt(doc.file.content, found.start);
        break :blk w.lo == found.start and w.hi == found.end;
    };
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(
        found.start,
        found.end,
        found.end,
        if (found_is_word) .word else .match,
    );
    breakUndoGroup(term); // 커서가 늘었다 — 다음 타이핑은 새 묶음이다(§3.3)
    self.metal_dirty = true;
    return true;
}

/// 선택(문서 offset 범위)을 **줄별 byte 범위**로 자른다 — 렌더가 요구하는 축이다.
///
/// **자르는 것이 제품의 일인 이유**: 컴포넌트는 어느 줄이 문서 몇 번째 byte에서 시작하는지 모른다.
/// 그 표는 `line_index`가 들고 있고 제품만 그것에 닿는다(§4.1g ⑤가 같은 이유로 제품 쪽이다).
///
/// **보이는 줄만 채운다.** 저장소는 문서 줄 수만큼 한 번 잡고 재사용한다 — 화면 밖 줄은 빈 슬라이스라
/// 렌더가 건너뛴다. 못 잡으면 선택이 안 그려질 뿐 다른 것은 그대로다(그리는 것은 곁가지이고, 선택
/// 자체는 `editor_selection`이 들고 있다).
fn buildSelectionMarks(self: *AppSession, term: *Term) ?[]const []const chrome_editor.frame.Mark {
    var iter = selections(term);
    if (iter.count() == 0) return null;
    const doc = term.rt.editor_doc orelse return null;
    // **렌더가 보는 축으로 만든다.** 접혀 있으면 렌더가 받는 배열은 `editor_visible_lines`(보이는 줄)
    // 이고 `paintSelection`은 그 축의 인덱스로 읽는다 — 문서 줄 축으로 만들면 접힘이 켜지는 순간
    // **화면이 조용히 거짓말한다**: 실측으로 보이는 줄의 띠가 사라지고(1→0), 숨긴 줄을 고르면
    // 엉뚱한 보이는 줄에 띠가 섰다(0→1). §4.1f와 §4.1g가 처음 만나는 자리다.
    const numbers = term.rt.editor_visible_numbers;
    const visible = term.rt.editor_visible_lines;
    const lines_len = if (visible.len > 0) visible.len else term.rt.editor_lines.len;
    if (lines_len == 0) return null;

    // **문서 순서로 정렬한다.** 렌더는 한 줄의 마크가 오름차순이라고 단언하고
    // (`content.columnsAtOffsets`), 커서 순서로 채우면 primary가 맨 앞에 와서 같은 줄에서
    // `12, 0, 6` 같은 배열이 나간다 — MC2가 그 패닉으로 이 결함을 잡았다.
    // 정렬은 아래 **병합 훑기**의 전제이기도 하다.
    // **해제는 잡은 길이 그대로 해야 한다.** 처음엔 `ordered = ordered[0..n]`으로 줄여 놓고
    // `defer free(ordered)`가 그 줄어든 슬라이스를 놓게 적었는데, 그것은 원래 할당과 길이가 달라
    // **잘못된 해제**다. 잡은 것(`storage`)과 쓰는 것(`ordered`)을 이름으로 가른다.
    // **흔한 경우에는 할당하지 않는다.** 이 함수는 프레임마다 돌고 커서는 대개 몇 개다 —
    // 하나짜리 선택에 힙을 왕복시킬 이유가 없다. 넘치면 그때만 잡는다.
    var stack_storage: [8]editor_selection.Selection = undefined;
    const heap_storage: ?[]editor_selection.Selection = if (iter.count() <= stack_storage.len)
        null
    else
        self.allocator.alloc(editor_selection.Selection, iter.count()) catch return null;
    defer if (heap_storage) |h| self.allocator.free(h);
    const storage = heap_storage orelse stack_storage[0..iter.count()];
    const ordered = blk: {
        var n: usize = 0;
        while (iter.next()) |sel| {
            if (sel.len() == 0) continue; // caret뿐 — 그릴 띠가 없다
            storage[n] = sel;
            n += 1;
        }
        if (n == 0) return null;
        const used = storage[0..n];
        std.mem.sort(editor_selection.Selection, used, {}, struct {
            fn lessThan(_: void, a: editor_selection.Selection, b: editor_selection.Selection) bool {
                return a.start() < b.start();
            }
        }.lessThan);
        break :blk used;
    };

    // **줄마다 커서 전부를 훑지 않는다.** 앞선 판이 그렇게 해서 비용이 `줄 수 × 커서 수`였고,
    // 저장소도 같은 곱(1000커서·2만 줄이면 160 MB)을 잡았다.
    //
    // 줄과 selection이 **둘 다 문서 순서**이므로 함께 걸으면 된다. 각 줄에서 이미 지나간 selection은
    // 버리고(`first`), 겹치는 것만 본다 — 전체가 `O(줄 + 커서 + 마크)`다.
    //
    // **실측**(ReleaseFast, 2만 줄, 같은 하네스에서 두 방식을 나란히 — 둘의 답이 같은 것도 함께 확인):
    //
    // | 커서 | 옛 훑기 | 병합 훑기 |
    // |---|---|---|
    // | 1 | 7µs | **10µs** |
    // | 10 | 66µs | 26µs |
    // | 200 | 1309µs | 30µs |
    // | 1000 | 6559µs | 32µs |
    //
    // **커서 하나에서는 오히려 느리다**(+43%) — 줄마다 포인터를 건사하는 몫이 붙기 때문이고,
    // 그것이 가장 흔한 경우다. 그럼에도 바꾼 이유는 **최악이 사라지기 때문**이다: 옛 방식은 커서가
    // 늘수록 선형으로 나빠져 1000개에서 프레임 예산의 40%를 먹었고, 새 방식은 거기서도 평평하다.
    // 3µs는 60fps 예산의 0.02%라 그 대가로 낼 만하다 — **재고 나서 한 판단이다.**
    // **줄별 개수를 배열로 들지 않는다.** 처음엔 `counts`를 프레임마다 잡았는데(2만 줄이면 80 KB
    // 할당·해제가 매 프레임), 아래 채우기가 어차피 같은 걸음을 다시 걸으므로 **총합만 있으면 된다** —
    // 줄별 슬라이스는 채우면서 `row_start..at`으로 잘라내면 나온다.
    var total: usize = 0;
    {
        var first: usize = 0;
        for (0..lines_len) |i| {
            const line = visibleDocLine(doc, numbers, visible, i) orelse continue;
            while (first < ordered.len and ordered[first].end() <= line.start) first += 1;
            var k = first;
            while (k < ordered.len and ordered[k].start() < line.contentEnd()) : (k += 1) {
                if (markRangeInLine(ordered[k], line) == null) continue;
                total += 1;
            }
        }
    }
    if (total == 0) return null;

    if (term.rt.editor_selection_marks.len < lines_len or term.rt.editor_selection_mark_buf.len < total) {
        const grown_rows = self.allocator.alloc([]const chrome_editor.frame.Mark, lines_len) catch return null;
        const grown_buf = self.allocator.alloc(chrome_editor.frame.Mark, total) catch {
            self.allocator.free(grown_rows);
            return null;
        };
        if (term.rt.editor_selection_marks.len > 0) self.allocator.free(term.rt.editor_selection_marks);
        if (term.rt.editor_selection_mark_buf.len > 0) self.allocator.free(term.rt.editor_selection_mark_buf);
        term.rt.editor_selection_marks = grown_rows;
        term.rt.editor_selection_mark_buf = grown_buf;
    }
    const rows = term.rt.editor_selection_marks[0..lines_len];
    const buf = term.rt.editor_selection_mark_buf[0..total];
    @memset(rows, &.{});

    var at: usize = 0;
    var first: usize = 0;
    for (0..lines_len) |i| {
        const line = visibleDocLine(doc, numbers, visible, i) orelse continue;
        while (first < ordered.len and ordered[first].end() <= line.start) first += 1;
        const row_start = at;
        var k = first;
        while (k < ordered.len and ordered[k].start() < line.contentEnd()) : (k += 1) {
            const m = markRangeInLine(ordered[k], line) orelse continue;
            buf[at] = m;
            at += 1;
        }
        rows[i] = buf[row_start..at];
    }
    return rows;
}

/// 보이는 줄 인덱스 → 원본 문서 줄. 번호 표는 1-based이고, 표에 없는 자리는 그릴 수 없다.
fn visibleDocLine(
    doc: Opened,
    numbers: []const ?u32,
    visible: []const []const u8,
    i: usize,
) ?maru.session.editor.line_index.Line {
    const doc_line: usize = if (visible.len > 0 and numbers.len > 0) blk: {
        if (i >= numbers.len) return null;
        break :blk (numbers[i] orelse return null) - 1;
    } else i;
    return doc.file.lines.line(doc_line);
}

/// 선택이 이 줄에서 차지하는 **줄 안 범위**. 겹치지 않으면 null.
fn markRangeInLine(
    sel: editor_selection.Selection,
    line: maru.session.editor.line_index.Line,
) ?chrome_editor.frame.Mark {
    const lo = sel.start();
    const hi = sel.end();
    const line_end = line.contentEnd();
    if (line_end <= lo or line.start >= hi) return null;
    const from = if (lo > line.start) lo - line.start else 0;
    const to = @min(hi, line_end) - line.start;
    if (to <= from) return null;
    return .{ .start = @intCast(from), .len = @intCast(to - from) };
}

/// 현재 검색 매치가 **보이게** 한다 — 접혀 있으면 펴고, 화면 밖이면 굴린다(§5.1 네비게이션).
///
/// **이미 보이면 아무것도 하지 않는다.** 타이핑마다 재검색이 돌므로(증분 검색) 매번 화면을 옮기면
/// 글자 하나 지울 때마다 본문이 튄다. VSCode도 화면 안 매치로는 뷰를 움직이지 않는다.
/// **IME 후보창이 설 자리**(N3 — 조합 중인 글자 아래). backing px, 창 좌상단 원점.
///
/// 편집기 Term은 코어가 sentinel이라 `imeCursorRect`의 터미널 갈래가 못 쓴다 — 그대로 두면
/// 후보창이 **pane 좌상단**에 뜬다(조합 글자는 문서 한가운데 있는데). 한글은 후보창을 보며
/// 고르는 입력이라 그 어긋남이 곧바로 걸린다.
///
/// **열은 `columnsAtOffsets`로 센다**(§5.4 MUST — 픽셀 배치의 단일 출처). 여기서 따로 세면
/// 렌더와 갈리는 두 번째 출처가 생긴다.
pub fn editorImeCaretRect(self: *AppSession, term: *Term) ?chrome_draw.Rect {
    if (term.kind != .editor) return null;
    if (term.rt.editor_diff != null) return null;
    const doc = term.rt.editor_doc orelse return null;

    // 조합 중이면 **조합을 시작한 자리**, 아니면 primary caret.
    const at = if (term.rt.editor_preedit.len > 0)
        term.rt.editor_preedit_at
    else if (term.rt.editor_selection) |sel| sel.start() else return null;
    if (at > doc.file.content.len) return null;

    const doc_line = doc.file.lines.lineAt(at);
    const row = visibleRowOfDocLine(term, @intCast(doc_line)) orelse return null;
    if (row < term.rt.editor_first_line) return null; // 화면 위로 벗어났다
    const screen_row = row - term.rt.editor_first_line;

    const line = doc.file.lines.line(doc_line) orelse return null;
    const text = doc.file.content[line.start..line.contentEnd()];
    var map: ProductColumnMap = .{ .tab_width = term.rt.editor_tab_width };
    const col = ProductColumnMap.columnOf(&map, text, at - line.start);
    const first_col = effectiveFirstCol(term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap, term, false);
    if (col < first_col) return null; // 가로로 벗어났다
    const screen_col = col - first_col;

    const body = editorBodyRect(self, .{
        .x = self.active_pane_rect.x,
        .y = self.active_pane_rect.y,
        .w = self.active_pane_rect.w,
        .h = self.active_pane_rect.h,
    }, term);
    const cw: i32 = @intCast(self.cell_width_px);
    const ch: i32 = @intCast(self.cell_height_px);
    return .{
        .x = @as(i32, @intCast(body.x)) + @as(i32, @intCast(screen_col)) * cw,
        .y = @as(i32, @intCast(body.y)) + @as(i32, @intCast(screen_row)) * ch,
        .w = @intCast(self.cell_width_px),
        .h = @intCast(self.cell_height_px),
    };
}

/// 조합 중 글자를 **그리는 줄 배열에만** 끼운 사본을 만든다(N3). 조합이 없거나 끼울 자리가
/// 화면 밖(접힘에 숨음)이면 `null` — 그때는 원래 배열을 그대로 그린다.
///
/// **버퍼가 아니라 화면만 바꾸는 이유**는 `setEditorPreedit`가 적어 두었다. 여기서 사본을 뜨는
/// 것은 그 판단의 대가다 — 조합 중에만, 프레임마다 줄 **포인터** 배열 하나를 복사한다(2만 줄이면
/// 160KB). 조합이 없으면 이 함수는 즉시 `null`이라 **평소에는 비용이 0**이다.
///
/// 제자리에서 바꿔치기하고 되돌리는 방법도 있었지만, 그러면 그 배열을 읽는 다른 것들(검색·클릭
/// 좌표)이 **그리는 도중의 값**을 볼 수 있는 창이 생긴다. 조합 중에만 드는 사본이 그 창보다 싸다.
fn preeditLines(self: *AppSession, term: *Term, base: []const []const u8) ?[][]const u8 {
    if (term.rt.editor_preedit.len == 0) return null;
    const doc = term.rt.editor_doc orelse return null;
    const at = term.rt.editor_preedit_at;
    if (at > doc.file.content.len) return null;

    const doc_line = doc.file.lines.lineAt(at);
    const row = visibleRowOfDocLine(term, @intCast(doc_line)) orelse return null; // 접혀 숨었다
    if (row >= base.len) return null;

    const line = doc.file.lines.line(doc_line) orelse return null;
    const text = doc.file.content[line.start..line.contentEnd()];
    const off = at - line.start;
    if (off > text.len) return null;

    const spliced = self.allocator.alloc(u8, text.len + term.rt.editor_preedit.len) catch return null;
    @memcpy(spliced[0..off], text[0..off]);
    @memcpy(spliced[off..][0..term.rt.editor_preedit.len], term.rt.editor_preedit);
    @memcpy(spliced[off + term.rt.editor_preedit.len ..], text[off..]);

    const rows = self.allocator.alloc([]const u8, base.len) catch {
        self.allocator.free(spliced);
        return null;
    };
    @memcpy(rows, base);
    rows[row] = spliced;
    return rows;
}

/// `preeditLines`가 뜬 사본을 놓는다 — 끼운 줄과 배열 둘 다.
fn freePreeditLines(self: *AppSession, term: *Term, rows: [][]const u8) void {
    const at = term.rt.editor_preedit_at;
    const doc = term.rt.editor_doc orelse {
        self.allocator.free(rows);
        return;
    };
    const doc_line = doc.file.lines.lineAt(@min(at, doc.file.content.len));
    if (visibleRowOfDocLine(term, @intCast(doc_line))) |row| {
        if (row < rows.len) self.allocator.free(rows[row]);
    }
    self.allocator.free(rows);
}

/// **IME 조합 중 글자를 갈아 끼운다**(N3 — native-editor.md §11). 빈 문자열이면 조합을 끝낸다.
///
/// **문서에 넣지 않는다.** 조합은 아직 확정이 아니므로 버퍼에 들어가면 undo·저장·검색이 그것을
/// 진짜 내용으로 본다 — 그리고 확정될 때 그 자리를 되돌리는 편집을 한 번 더 해야 한다. 터미널이
/// `terminal/preedit.zig`로 하는 것과 같은 판단이다(*"canonical cell grid를 바꾸지 않는다"*).
///
/// 자리는 **조합을 시작한 곳**으로 고정한다 — 그 규칙은 확정 텍스트가 이미 따르고 있다(§3.3의
/// IME 고정). 조합 중에 커서가 움직일 일은 없지만(입력기가 키를 다 먹는다) 두 값이 갈리면
/// **조합 글자와 확정 글자가 다른 자리에 나타난다.**
pub fn setEditorPreedit(self: *AppSession, term: *Term, bytes: []const u8) void {
    if (bytes.len == 0) {
        if (term.rt.editor_preedit.len > 0) self.allocator.free(term.rt.editor_preedit);
        term.rt.editor_preedit = &.{};
        return;
    }
    // **새 값을 먼저 복사한다.** OOM이면 보이던 조합 상태가 그대로 남는다 — 터미널 오버레이의
    // `replace`가 같은 순서를 쓴다(사라지는 것보다 낡은 것이 낫다).
    const next = self.allocator.dupe(u8, bytes) catch return;
    if (term.rt.editor_preedit.len == 0) {
        // 조합의 **시작**이다 — 이 자리에 확정 텍스트가 온다.
        term.rt.editor_preedit_at = if (term.rt.editor_selection) |sel| sel.start() else 0;
    }
    if (term.rt.editor_preedit.len > 0) self.allocator.free(term.rt.editor_preedit);
    term.rt.editor_preedit = next;
}

/// 검색 매치들을 문서 offset 범위로 편다. 매치는 `(줄, 줄 안 offset)`이고 편집은 문서 offset을
/// 받는다(§3.1) — 그 환산을 **한 곳**에 둔다. 줄 번호가 범위 밖이면 그 매치를 버린다(목록이
/// 편집보다 낡은 순간).
/// 문서 offset 범위 — **익명 구조체로 두지 않는다.** 같은 모양이라도 선언 자리가 다르면 Zig 는
/// 다른 타입으로 보므로, 공개 겉껍질이 속을 그대로 못 돌려준다.
pub const DocRange = struct { start: usize, end: usize };

/// 매치의 **문서 offset 범위**. 「선택 영역 내에서만」이 거를 때도 같은 변환을 쓴다(§5.1) —
/// 두 번째 변환을 만들면 두 축이 갈린다.
pub fn matchRangePublic(doc: Opened, m: maru.session.editor.find.Match) ?DocRange {
    return matchRange(doc, m);
}

fn matchRange(doc: Opened, m: maru.session.editor.find.Match) ?DocRange {
    const line = doc.file.lines.line(m.line) orelse return null;
    const start = line.start + m.start;
    if (start > doc.file.content.len) return null;
    return .{ .start = start, .end = @min(start + m.len, doc.file.content.len) };
}

/// **현재 매치 하나를 바꾼다**(§5.1). 바꾸기는 편집 연산이므로 되돌리기 하나다(§3.3).
///
/// 바꾼 뒤 **다음 매치로 간다** — 그러지 않으면 같은 자리를 다시 가리키게 되고, 바꿀 문자열이
/// 검색어를 품으면(`a` → `aa`) Enter를 누를 때마다 **같은 자리가 자라난다.**
pub fn replaceCurrentMatch(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    if (!isFindTarget(self, term)) return false; // 남의 문서 좌표로 이 문서를 고치지 않는다

    const idx = self.chrome_host.find.current;
    if (idx >= self.editor_find_matches.items.len) return false;
    const r = matchRange(doc, self.editor_find_matches.items[idx]) orelse return false;

    const text = self.chrome_host.find.replace.query.items;
    var changes = [_]maru.session.editor.delta.Change{.{ .start = r.start, .end = r.end, .text = text }};

    if (!applyEditAsOne(self, term, &changes)) return false;

    // **바꾼 자리 뒤의 첫 매치로 간다.** 목록은 방금 낡았으므로 다시 찾고, 그 안에서 고른다.
    const after = r.start + text.len;
    find_ops.recomputeEditorFindPublic(self, term);
    selectNextMatchAtOrAfter(self, term, after);
    return true;
}

/// **전부 바꾼다**(§5.1). 멀티 selection 동시 편집과 **같은 경로**를 타므로 되돌리기 하나다(§3.3).
///
/// **한 번에 적용하는 것이 되풀이를 막는다.** 하나씩 바꾸고 다시 찾기를 반복하면 바꾼 문자열이
/// 검색어를 품을 때 끝나지 않는다(`a` → `aa`).
pub fn replaceAllMatches(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    if (!isFindTarget(self, term)) return false;
    if (self.editor_find_matches.items.len == 0) return false;

    const text = self.chrome_host.find.replace.query.items;
    var changes: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer changes.deinit(self.allocator);
    for (self.editor_find_matches.items) |m| {
        const r = matchRange(doc, m) orelse continue;
        changes.append(self.allocator, .{ .start = r.start, .end = r.end, .text = text }) catch return false;
    }
    if (changes.items.len == 0) return false;

    if (!applyEditAsOne(self, term, changes.items)) return false;

    // 다 바꿨으니 남은 매치는 **바꾼 문자열이 검색어를 품은 경우뿐**이다. 다시 찾아 카운터를 맞춘다.
    find_ops.recomputeEditorFindPublic(self, term);
    self.chrome_host.find.current = 0;
    return true;
}

/// 문서 offset `at` **이상**에서 시작하는 첫 매치를 현재로 삼는다. 없으면 첫 매치로 돌아간다(wrap).
fn selectNextMatchAtOrAfter(self: *AppSession, term: *Term, at: usize) void {
    const doc = term.rt.editor_doc orelse return;
    for (self.editor_find_matches.items, 0..) |m, i| {
        const r = matchRange(doc, m) orelse continue;
        if (r.start >= at) {
            self.chrome_host.find.current = i;
            revealCurrentFindMatch(self, term);
            return;
        }
    }
    self.chrome_host.find.current = 0;
    revealCurrentFindMatch(self, term);
}

/// 변경 목록 하나를 **한 번의 편집**으로 적용한다 — 되돌리기 하나(§3.3), 스크롤·caret 추종까지.
/// 주석 토글과 바꾸기가 같은 꼬리를 쓰므로 여기 모은다.
///
/// **읽기 전용을 강제하는 것은 이 층이 아니다.** `EditableFile.apply`가 `error.ReadOnly`를 내는
/// 것이 그 계약의 방어이고(§3.5), 그것은 `edit_doc.zig`의 판정자가 직접 잡는다. 부르는 쪽들이
/// 앞서 두는 `read_only` 검사는 **싼 조기 반환**이지 두 번째 방어가 아니다 — 지워도 동작이
/// 같음을 뮤턴트로 확인했다(적대적 검증 2026-08-27). 이 파일의 여덟 자리가 같은 관용구를 쓰므로
/// 그 형태는 유지하되, **무엇이 실제로 막는지**를 여기 한 번 적어 둔다.
fn applyEditAsOne(self: *AppSession, term: *Term, changes: []maru.session.editor.delta.Change) bool {
    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;

    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term);
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = changes }, &sels) catch {
        self.allocator.free(before);
        return false;
    };

    breakUndoGroup(term); // 타이핑과 다른 연산이다(§3.3 "연산 종류 변경")
    pushUndo(self, term, inverse, before, before_primary, .insert);
    writeBackSelections(self, term, sels);
    // **구문 트리 통지**(§5.3). 역연산이 편집 **후** 좌표라 그대로 범위가 된다.
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = changes });
    revealPrimaryCaretRows(self, term, rows_before);
    breakUndoGroup(term);
    self.metal_dirty = true;
    return true;
}

/// 검색 매치 하나를 primary selection으로 만든다(§5.1). **선택 범위**여야 한다 — caret만 옮기면
/// 무엇을 찾았는지 화면이 말하지 않고, 바꾸기가 "지금 것"을 집을 근거도 사라진다.
fn selectFindMatch(self: *AppSession, term: *Term, match: maru.session.editor.find.Match) void {
    if (term.rt.editor_diff != null) return; // 비교 뷰는 축이 둘이다(§4.1g) — 검색 대상도 아직 아니다
    const doc = term.rt.editor_doc orelse return;
    const line = doc.file.lines.line(match.line) orelse return;

    // 매치는 **줄 안 offset**이고 selection은 **문서 offset**이다(§3.1 단일 위치 축).
    const start = line.start + match.start;
    const end = @min(start + match.len, doc.file.content.len);
    if (start > doc.file.content.len) return; // 목록이 편집보다 낡았다 — 조용히 둔다

    // **커서를 새로 놓는 경로다.** 멀티커서를 남기면 사용자가 그것을 없앨 방법이 없고(클릭이
    // 정리하는 그 규칙), 바꾸기가 엉뚱한 자리까지 건드린다.
    clearExtraSelections(self, term);
    term.rt.editor_selection = editor_selection.Selection.fromPoints(start, end);
    // 편집이 아닌 이유로 커서가 움직였다 — 다음 타이핑이 앞의 것과 한 묶음이 되면 안 된다(§3.3).
    breakUndoGroup(term);
}

pub fn revealCurrentFindMatch(self: *AppSession, term: *Term) void {
    // **이 Term의 매치가 맞는지 먼저 묻는다.** 목록은 계산한 시점의 편집기 것이고, 그 뒤 pane이
    // 바뀌었을 수 있다. 안 물으면 **남의 문서 줄 번호로 이 문서를 굴리고 이 문서의 접힘을
    // 편다** — 읽기인 줄 알았던 자리가 남의 상태를 쓴다(적대적 검증 2026-08-23이 실제로 재현).
    //
    // `buildFindMarks` 쪽은 이미 같은 판정을 쓰고 있었는데 스크롤 쪽만 안 썼다. ⌘G 경로
    // (`findNavigate`)도 출처를 확인한다 — **오버레이를 연 채 Enter만** 그 문을 안 지났다.
    if (!isFindTarget(self, term)) return;

    const idx = self.chrome_host.find.current;
    if (idx >= self.editor_find_matches.items.len) return;
    const match = self.editor_find_matches.items[idx];
    const doc_line = match.line;

    // **현재 일치가 primary selection을 옮긴다**(§5.1). 별도 "검색 커서"를 만들지 않는 것이
    // 이 문장의 요점이다 — 그래서 오버레이를 닫으면 **찾은 자리에서 그대로 편집이 이어진다**
    // (바꾸기도 그 selection 위에서 일어난다). 색만 바꾸면 Enter로 옮겨 다닌 뒤 Esc를 눌렀을 때
    // caret이 검색 전 자리에 남아, 사용자는 **화면과 다른 곳을 고치게 된다.**
    //
    // **스크롤보다 앞에 둔다.** 아래는 "이미 보인다"면 굴리지 않고 돌아가는데, 보이든 말든
    // selection은 옮겨야 한다.
    selectFindMatch(self, term, match);

    // **먼저 편다.** 접힌 채로 보이는 줄을 찾으면 그 줄이 없어 아무 데도 못 간다.
    const unfolded = revealFoldedLine(self, term, doc_line);

    const row = visibleRowOfDocLine(term, doc_line) orelse return; // 폈는데도 없다 — 그릴 것이 없다

    // **렌더가 굳힌 스냅숏을 읽는다**(§4.1g ② — 스냅숏의 경계). pane 사각을 여기서 다시 구하면
    // 마지막 프레임과 다른 값이 나올 수 있고, 그러면 "보인다"는 판정이 화면과 갈린다.
    const rows = term.rt.editor_hit_rows_len;
    if (rows == 0) { // 아직 한 프레임도 안 그렸다 — 맨 위에 둔다
        setEditorTop(self, term, row);
        return;
    }

    // **"보인다"를 세지 않고 찾는다 — 단, 그 목록이 지금 화면 것일 때만.**
    //
    // 초판은 `row < top + rows`로 셌는데, `rows`는 **시각 행** 수이고 `row`/`top`은 **논리 줄**이라
    // 랩이 켜지면 축이 섞였다. 그 근사는 **과대 계수**라 뷰포트 **아래** 줄을 "보인다"고 답했고,
    // 그러면 Enter를 눌러도 안 굴러가 **카운터만 올라가고 화면은 그대로**였다.
    //
    // 그래서 `editor_hit_lines`(마지막 프레임이 **행마다 어느 문서 줄을 그렸는지**)를 본다.
    // **그런데 그 목록만 믿으면 다른 문이 열린다**: 세 재료가 전부 지난 프레임의 것이라
    // **방금 자기가 한 스크롤을 못 본다**. 한 프레임 안에 Enter가 두 번 오면(키 반복 15ms <
    // 프레임 16.7ms) 두 번째가 "보인다"고 답해 같은 증상이 다시 났다 — 2라운드 적대적 검증이
    // 회귀로 잡았고, 옛 코드는 `top`을 라이브로 읽어 그 경우를 맞히고 있었다.
    //
    // 그래서 **묻고 나서 믿는다**: 스냅숏이 기록한 세로 위치가 지금 위치와 같을 때만 그 목록이
    // 이 화면을 설명한다. 다르면 무엇이 보이는지 모르므로 **굴린다**(모를 때는 움직이는 쪽이
    // 덜 나쁘다 — 안 움직이면 사용자는 "Enter가 죽었다"고 읽는다).
    //
    // **그래도 조각·열 축은 근사로 남는다.** 이 판정은 **줄**만 본다 — 한 화면보다 긴 줄 하나에
    // 든 매치는 그 줄이 그려져 있다는 이유로 "보인다"고 답해 안 굴러간다(미니파이 JSON·긴 로그).
    // 가로도 같다. 둘 다 §5.2가 소유할 2차원 reveal이고 그때 함께 닫는다 — 여기서 "근사가
    // 아니라 사실이다"라고 적었던 것은 **줄 축에서만** 참이었다(2라운드 적대적 검증).
    // **스냅숏이 이 화면을 설명하는가.** 세로 위치만 묻던 초판은 위치를 안 바꾸면서 배치를
    // 바꾸는 것들(접힘·랩·탭 폭·폰트 크기)을 못 봤다 — 그 창에서 다시 "이미 보인다"고 답했다.
    // 아래 값들은 전부 **여기서 라이브로 다시 읽을 수 있는 것**이라 대조가 성립한다.
    // **`geom.drawn`은 안 본다.** 위 `rows == 0` 조기 반환이 이미 "한 번도 안 그렸다"를 걸러
    // 낸다(`storeHitRows`가 `drawn`과 `editor_hit_rows_len`을 한 단위로 세우고 실패 경로는
    // 행 수를 0으로 남긴다). 대조식에 넣어 두었더니 **뮤턴트가 살아남았고**, 그것은 판정자가
    // 없다는 뜻이 아니라 **그 항이 아무 일도 안 한다**는 뜻이었다(적대적 검증 2026-08-24).
    const geom = term.rt.editor_hit_geom;
    const snapshot_is_current = geom.top_line == term.rt.editor_first_line and
        geom.top_piece == term.rt.editor_first_piece and
        geom.visible_len == editorLines(term).len and
        geom.wrap == (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) and
        geom.tab_width == term.rt.editor_tab_width and
        geom.cell_w_px == self.cell_width_px and
        geom.cell_h_px == self.cell_height_px;
    // **방금 폈으면 그 목록은 낡았다** — 펴기 전 화면의 것이다. 그때도 묻지 않고 굴린다.
    if (!unfolded and snapshot_is_current) {
        for (term.rt.editor_hit_lines[0..rows]) |drawn| {
            if (drawn == doc_line) return; // 이미 보인다 — 증분 검색이라 매번 굴리면 본문이 튄다
        }
    }

    // 화면 **가운데쯤**에 둔다. 맨 위에 두면 다음 매치가 어디로 이어지는지 안 보이고, Find 오버레이가
    // 활성 pane 위쪽 한 줄을 덮으므로 위에 붙은 매치는 가려진다(스크롤백 쪽이 같은 이유로 가운데다).
    //
    // **논리 줄 수로 나눈다 — 시각 행 수가 아니다.** 랩에서 한 줄이 세 행을 먹으면 시각 행의
    // 절반은 논리 줄 여럿을 지나쳐, 매치를 가운데가 아니라 **화면 아래로 밀어낸다**.
    //
    setEditorTop(self, term, row -| drawnDocLines(term) / 2);

    // **낡은 채로 놓았으면 다음 프레임 뒤에 한 번 더 잡는다.**
    //
    // 낡았다고 판정한 목록에서 나온 줄 수(`drawnDocLines`)로 가운데를 잡는 것은 추측이고,
    // 게다가 `clampScrollToGeometry`가 쓰는 `editor_total_visual_rows`도 같은 이유로 낡아
    // **방금 놓은 자리를 되돌린다**(실측: 31 → 7). 그래서 랩을 켠 직후 첫 Enter가 매치를 화면에
    // 못 올려 **두 번 눌러야 보였다**(적대적 검증 2026-08-24).
    //
    // 다음 프레임이 **둘 다** 이 배치의 값으로 갱신하므로 그 끝에서 다시 잡으면 정확하다.
    // 원격 find가 `remote_find_scroll_pending`으로 쓰는 그 패턴이다.
    //
    // **최대 두 번 돈다.** 재조준이 접힘을 펴면 보이는 줄 수가 그 자리에서 또 바뀌어 신선도
    // 대조가 다시 어긋나고 한 번 더 예약된다 — 그때는 펼 것이 없어 거기서 멈춘다(적대적 검증
    // 2026-08-24가 실측했고, 랩·접힘·긴 줄 조합 다섯을 8프레임씩 돌려 **진동은 없음**을 확인했다).
    // 초판 주석은 "두 번 돌지 않는다"고 적었는데 그것이 틀렸다.
    //
    // **비용은 프레임 하나다** — 재조준이 도는 그 프레임은 이미 옛 자리로 그려졌고, 새 자리는
    // 그다음 프레임이 그린다. 그 프레임을 **예약하는 것까지가 이 장치의 일이다**(`reproject_after_frame`):
    // `metal_dirty`만 세우면 같은 tick의 소거가 삼켜 **자리는 맞고 화면은 안 바뀐다**.
    //
    // **여기서 추측을 더 잘하려 하지 않는다.** "낡았을 때는 맨 위 가까이" 같은 특례를 넣어 봤지만
    // 재조준이 어차피 바로잡으므로 **아무 판정자도 그 특례를 재지 못했다** — 장치가 둘이면
    // 하나는 반드시 검증 밖에 남는다.
    if (!snapshot_is_current) term.rt.editor_find_reveal_pending = true;
}

/// 마지막 프레임이 그린 **문서 줄 수**(시각 행 수가 아니다).
///
/// 랩이 켜지면 한 줄이 여러 행을 차지하므로 둘이 다르고, 그 차이를 무시하면 "가운데 뒀다"고
/// 하면서 화면 밖에 두게 된다. `editor_hit_lines`는 행마다의 문서 줄이고 화면 아래로 갈수록
/// 커지므로(같은 줄의 조각들이 이어 붙는다), **값이 바뀌는 횟수**가 곧 줄 수다.
fn drawnDocLines(term: *const Term) usize {
    const n = term.rt.editor_hit_rows_len;
    if (n == 0) return 0;
    // **길이를 배열로 좁힌다.** 스냅숏의 두 값(`len`과 배열)이 어긋난 상태가 존재한다 —
    // 판정자가 "렌더가 굳혀 둔 상태"를 흉내 낼 때 길이만 세우고(`EDIT6`), 제품에서도
    // `storeHitRows`가 실패하면 그 사이가 벌어질 수 있다. 좁히지 않으면 **읽다가 죽는다**
    // (적대적 검증 2026-08-26 — 편집 경로가 이 함수를 부르기 시작하자 바로 패닉했다).
    const lines = term.rt.editor_hit_lines[0..@min(n, term.rt.editor_hit_lines.len)];
    if (lines.len == 0) return 0;
    var count: usize = 1;
    for (lines[1..], lines[0 .. lines.len - 1]) |cur, prev| {
        if (cur != prev) count += 1;
    }
    return count;
}

/// 화면 맨 위 줄을 옮긴다 — **조각 offset을 함께 지운다.**
///
/// 세로 위치는 `(줄, 조각)` 쌍이고(§4.1d), 다른 이동 지점은 전부 둘을 함께 세운다
/// (`scrollPieces`·`clampTopToMax`·`setEditorVScrollFromBarPx`). 초판의 `revealCurrentFindMatch`만
/// `first_line`을 혼자 썼고, 그래서 랩에서 긴 줄 중간(`first_piece > 0`)에 있다가 점프하면
/// **옛 조각 offset이 남아 목적지 줄을 지나쳤다** — 그다음 Enter는 "이미 보인다"로 판정돼
/// 영영 안 굴러갔다(적대적 검증 2026-08-23).
///
/// **접힘 경로는 우연히 안전했다**(`rebuildVisible`이 부르는 `invalidateFoldDerived`가 0을 놓는다).
/// 우연에 기대지 않으려고 여기서 명시한다.
fn setEditorTop(self: *AppSession, term: *Term, line: usize) void {
    term.rt.editor_first_line = line;
    term.rt.editor_first_piece = 0;
    self.metal_dirty = true;
}

/// `doc_line`을 숨기고 있는 접힘을 전부 편다(중첩이면 여러 겹). 숨어 있지 않으면 무동작.
///
/// **폈으면 `true`.** 부르는 쪽이 그 사실을 알아야 하는 이유는 `editor_hit_lines`가 **펴기 전
/// 화면의 스냅숏**이어서다 — 폈는데도 그 낡은 목록으로 "이미 보인다"를 판정하면, 방금 드러낸
/// 줄을 안 보인다고(또는 그 반대로) 답한다.
///
/// **한 번만 다시 만든다.** 겹마다 `toggleFoldHead`를 부르면 그때마다 보이는 줄 배열을 다시 만들고
/// 보던 자리를 되돌리는데, 여기서는 곧바로 다른 자리로 갈 것이라 그 일이 통째로 버려진다.
fn revealFoldedLine(self: *AppSession, term: *Term, doc_line: u32) bool {
    if (term.rt.editor_folded_len == 0) return false;
    if (foldsUnavailable(term)) return false;
    const buf = term.rt.editor_folded_buf;
    const prev_len = term.rt.editor_folded_len;
    // **되돌릴 자리를 만들고 나서 고친다.** 아래 압축은 `buf`를 제자리에서 덮으므로, 먼저 베끼지
    // 않으면 되돌릴 것이 이미 사라진 뒤다(`toggleFoldHead`가 같은 순서인 이유다).
    @memcpy(term.rt.editor_folded_prev[0..prev_len], buf[0..prev_len]);

    var kept: usize = 0;
    for (term.rt.editor_folded_prev[0..prev_len]) |head| {
        const covers = for (term.rt.editor_fold_ranges) |r| {
            if (r.head == head) break doc_line >= r.first_hidden and doc_line <= r.last_hidden;
        } else false;
        if (covers) continue; // 이 접힘이 그 줄을 숨긴다 — 뺀다
        buf[kept] = head;
        kept += 1;
    }
    if (kept == prev_len) return false; // 숨긴 것이 없었다 — 압축이 제자리 복사라 `buf`도 그대로다

    term.rt.editor_folded_len = kept;
    rebuildVisible(self, term) catch {
        @memcpy(buf[0..prev_len], term.rt.editor_folded_prev[0..prev_len]);
        term.rt.editor_folded_len = prev_len;
        return false;
    };
    self.metal_dirty = true;
    return true;
}

/// 이 Term이 지금 ⌘F가 검색하고 있는 문서인가.
///
/// **id로 묻는다.** 매치 목록은 계산한 시점의 활성 편집기 것이고(`editor_find_source`), 그 뒤에
/// pane이 바뀌었을 수 있다 — "활성인가"로 물으면 아직 다시 계산하지 않은 프레임에서 **남의 문서
/// 좌표를 이 문서에 칠한다**. 목록과 함께 실려 온 출처와 대조하면 그 한 프레임이 없다.
pub fn isFindTarget(self: *AppSession, term: *const Term) bool {
    if (!(self.chrome_host.find.open or self.find_nav)) return false;
    if (self.editor_find_source == 0) return false;
    return self.editor_find_source == term.surfaceId();
}

/// 검색 결과 하나를 **보이는 줄 축**으로 옮긴 것 — 그 축에 없으면(접혀 숨었다) `null`.
///
/// **길이는 담지 않는다.** 부르는 쪽이 필요한 것은 *어느 자리가 현재인가*뿐이고(`frame.CurrentMatch`),
/// 길이는 이미 `search_marks` 쪽에 있다 — 두 곳에 두면 둘이 다를 수 있다.
pub const VisibleMatch = struct { row: u32, start: u32 };

/// 문서 줄 → 보이는 줄. 접힘이 없으면 그대로다.
///
/// **훑는다.** 보이는 줄 배열은 문서 순서라 이분 탐색도 되지만, 이분 탐색을 넣어도 프레임
/// 복잡도가 안 변한다 — **바로 옆 `buildFindMarks`가 이미 매 프레임 보이는 줄 전체를 훑기
/// 때문**이다(선택 마크가 같은 모양이고, 둘을 함께 뷰포트 창으로 좁히는 것이 진짜 개선이다).
/// 초판은 "프레임당 한 번뿐이라"를 근거로 댔는데, 그 근거는 결론을 지지하지 않았다
/// (적대적 검증 2026-08-23 — 결론은 맞고 이유가 틀렸다).
fn visibleRowOfDocLine(term: *const Term, doc_line: u32) ?u32 {
    const numbers = term.rt.editor_visible_numbers;
    if (term.rt.editor_visible_lines.len == 0 or numbers.len == 0) {
        // **문서 밖은 없는 것으로 답한다.** 매치 목록이 다른 문서의 것일 수 있다 — 편집기를 닫고
        // 다른 것을 열면 목록은 다음 재검색까지 남는다(`editor_find_source`가 그것을 막지만,
        // 그 표식을 안 보는 경로가 생겨도 여기서 문서 밖으로 굴러가지 않는다).
        return if (doc_line < term.rt.editor_lines.len) doc_line else null;
    }
    for (numbers, 0..) |n, i| {
        const num = n orelse continue;
        if (num - 1 == doc_line) return @intCast(i);
    }
    return null; // 접혀 숨었다
}

/// 현재 매치를 **보이는 줄 축**으로 옮긴다(렌더가 색을 가르는 데 쓴다).
pub fn currentVisibleMatch(self: *AppSession, term: *Term) ?VisibleMatch {
    const idx = self.chrome_host.find.current;
    if (idx >= self.editor_find_matches.items.len) return null;
    const m = self.editor_find_matches.items[idx];
    const row = visibleRowOfDocLine(term, m.line) orelse return null;
    return .{ .row = row, .start = m.start };
}

/// 검색 결과(§5.1)를 **보이는 줄별 byte 범위**로 자른다 — `buildSelectionMarks`와 같은 일이고
/// 저장소 규칙만 다르다.
///
/// **줄당 하나를 전제하지 않는다.** 선택 쪽은 `buf[i..i+1]`로 잘라 주는데, 그 구조가 성립하는
/// 이유는 선택이 이어진 하나여서다. 매치는 한 줄에 여럿이라 같은 저장소에 얹으면 **둘째부터
/// 조용히 사라진다** — 이 슬라이스가 존재하는 이유가 그 구분이다.
///
/// **매치는 문서 줄 순서로 정렬돼 있다**(`find.findMatches`가 훑는 순서). 그래서 보이는 줄을
/// 훑으며 매치 커서를 함께 밀면 한 번의 통과로 끝난다 — 줄마다 다시 찾으면 접힌 큰 문서에서
/// 곱으로 붙는다.
///
/// **목록을 인자로 받는다.** ⌘G로 오버레이를 닫은 채 오갈 때는 **현재 매치만** 그려야 하는데
/// (스크롤백 쪽이 `if (find.open)`으로 나머지를 빼는 그 규칙), 목록을 통째로 읽으면 그 구분을
/// 이 함수 안에서 또 해야 한다 — 부르는 쪽이 슬라이스를 좁히면 규칙이 한 곳에만 남는다.
fn buildFindMarks(self: *AppSession, term: *Term, matches: []const maru.session.editor.find.Match) ?[]const []const chrome_editor.frame.Mark {
    if (matches.len == 0) return null;
    const numbers = term.rt.editor_visible_numbers;
    const visible = term.rt.editor_visible_lines;
    const folded = visible.len > 0 and numbers.len > 0;
    const lines_len = if (visible.len > 0) visible.len else term.rt.editor_lines.len;
    if (lines_len == 0) return null;

    if (term.rt.editor_find_marks.len < lines_len) {
        const grown = self.allocator.alloc([]const chrome_editor.frame.Mark, lines_len) catch return null;
        if (term.rt.editor_find_marks.len > 0) self.allocator.free(term.rt.editor_find_marks);
        term.rt.editor_find_marks = grown;
    }
    if (term.rt.editor_find_mark_buf.len < matches.len) {
        const grown = self.allocator.alloc(chrome_editor.frame.Mark, matches.len) catch return null;
        if (term.rt.editor_find_mark_buf.len > 0) self.allocator.free(term.rt.editor_find_mark_buf);
        term.rt.editor_find_mark_buf = grown;
    }
    const rows = term.rt.editor_find_marks[0..lines_len];
    const buf = term.rt.editor_find_mark_buf;
    @memset(rows, &.{});

    // 보이는 줄을 문서 순서로 훑으며 매치 커서를 민다. 접힘이 켜져 있어도 보이는 줄의 문서 번호는
    // 오름차순이라(숨은 줄을 건너뛸 뿐) 커서를 되돌릴 일이 없다.
    var mi: usize = 0;
    var w: usize = 0;
    for (0..lines_len) |i| {
        const doc_line: u32 = if (folded) blk: {
            if (i >= numbers.len) continue;
            break :blk (numbers[i] orelse continue) - 1;
        } else @intCast(i);
        // 이 줄보다 앞선 매치는 숨은 줄의 것이다 — 건너뛴다.
        while (mi < matches.len and matches[mi].line < doc_line) mi += 1;
        const from = w;
        while (mi < matches.len and matches[mi].line == doc_line) : (mi += 1) {
            // **도달 불가한 방어다.** 위에서 `buf.len >= matches.len`을 보장했고 `w`는 매치당
            // 최대 1씩만 는다. 그래도 두는 이유는 `editorTabWidth`의 clamp와 같다 — 넘치면
            // 남의 메모리를 쓰는 것이라 조용한 실패가 최악이고, **도달 불가한 것을 알고 두는
            // 것과 모르고 두는 것은 다르다**(적대적 검증 2026-08-23이 죽은 가지로 확인).
            if (w >= buf.len) break;
            buf[w] = .{ .start = matches[mi].start, .len = matches[mi].len };
            w += 1;
        }
        if (w > from) rows[i] = buf[from..w];
    }
    return rows;
}

/// 편집기 **본문**을 눌렀는가(§4.1g 배선). 눌렀으면 선택을 시작하고 `true`를 준다.
///
/// **이 함수가 `hitTestBody`의 첫 제품 호출자다.** 그 전까지 좌표계는 판정자만 부르고 있었고,
/// §4.1g의 "아직 검증되지 않는 문장" 표가 그 사실 위에 서 있었다.
///
/// **순서는 스크롤바 뒤·pane 포커스 앞이다.**
///
/// | 자리 | 누가 가져가나 | 왜 |
/// |---|---|---|
/// | pane 경계(seam) | divider 캡처 | 더 바깥이다 |
/// | 막대 띠 | `beginScrollbarGesture` | pane 안쪽 거터이고, 눌렀는데 포커스만 옮겨지면 두 번 눌러야 한다 |
/// | **본문 텍스트 열** | **이 함수** | gutter는 `hitTestBody`가 `null`을 준다(접힘 화살표 자리) |
/// | 그 밖 | pane 포커스 이동 | |
///
/// 결정표가 *"막대 위 클릭은 상위가 먼저 가져간다"*고 적은 것을 이 순서가 지킨다 — 그 문장은 그동안
/// 순서를 보장하는 코드가 없어 **예고**였다.
///
/// **잡은 Term을 든다.** 드래그가 pane을 벗어나거나 포커스가 옮겨져도 그 문서가 선택된다(스크롤바
/// 드래그가 같은 규율을 쓴다). 좌표가 본문 밖으로 나가면 `hitTestBody`가 clamp한 offset을 주므로
/// 호출자가 분기를 더 지지 않는다(§10 *"항상 유효한 offset"*).
/// 화면 좌표 → **문서 기준 시각 행·열**(§3.2a의 `ColumnAnchor` 축).
///
/// `hitTestBody` 와 **같은 굳은 스냅숏**을 읽는다 — 다른 프레임의 값을 섞으면 사각형이 caret 과 다른
/// 자리를 잡는다(§4.1g). 행은 **문서 기준**이라야 자동 스크롤 중에도 안 미끄러진다: `editor_hit_rows`
/// 의 첨자는 뷰포트 상대이므로 **`editor_first_line` 을 더해** 문서 축으로 올린다.
fn visualRowColAt(term: *Term, x_px: f64, y_px: f64) ?struct { row: u32, col: u32 } {
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;
    const geom = term.rt.editor_hit_geom;
    const p = chrome_editor.hit.bodyPoint(
        .{
            .body_x = geom.body_x,
            .body_y = geom.body_y,
            .content_left_px = geom.content_left_px,
            .content_width = geom.content_width,
            .cell_w_px = geom.cell_w_px,
            .cell_h_px = geom.cell_h_px,
            .tab_width = geom.tab_width,
        },
        term.rt.editor_hit_rows[0..rows_len],
        term.rt.editor_hit_lines[0..rows_len],
        term.rt.editor_lines,
        x_px,
        y_px,
    ) orelse return null;

    // 줄 안 byte → 시각 열. **`columnsAtOffsets` 하나를 쓴다** — 열을 여기서 다시 세면 화면과 갈리는
    // 두 번째 출처가 생긴다(`ColumnMap.columnOf` 가 같은 함수를 부른다).
    const line_text = if (p.line < term.rt.editor_lines.len) term.rt.editor_lines[p.line] else "";
    var offs = [_]u32{@intCast(@min(p.byte_in_line, line_text.len))};
    var cols = [_]u32{0};
    chrome_editor.content.columnsAtOffsets(line_text, geom.tab_width, &offs, &cols, std.math.maxInt(u32));

    return .{ .row = @intCast(p.row + term.rt.editor_first_line), .col = cols[0] };
}

pub fn beginBodySelection(self: *AppSession, pane: *Pane, x_px: f64, y_px: f64, mods: i32) bool {
    const term = pane.activeTerm();
    if (term.kind != .editor) return false;
    const off = hitTestBody(term, x_px, y_px) orelse return false;
    logHitSnapshotDiag(self, term, y_px, off);
    // 클릭 한 번이 멀티커서를 정리한다 — 안 그러면 사용자가 커서를 없앨 방법이 없다(§9.1).
    clearExtraSelections(self, term);
    // **커서가 편집 아닌 이유로 움직였다 — undo 묶음을 끊는다**(§3.3). 안 끊으면 클릭 뒤 친
    // 글자를 되돌릴 때 클릭 **전** 타이핑까지 함께 사라진다.
    breakUndoGroup(term);
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(off);

    // **`⌥` 또는 `⇧⌥` 면 열 선택이다**(§3.2a·§9.1). 앞은 터미널 관례(iTerm2·Terminal.app), 뒤는
    // VSCode 관례이고 **둘이 같은 결과**라 설정으로 가를 것이 없다. `⌘`(32)는 링크 열기가 쓰므로
    // 여기 안 온다.
    term.rt.editor_column_anchor = if ((mods & 8) != 0) blk: {
        const rc = visualRowColAt(term, x_px, y_px) orelse break :blk null;
        break :blk .{ .from_row = rc.row, .from_col = rc.col, .to_row = rc.row, .to_col = rc.col };
    } else null;

    self.beginPointerGesture(.{ .editor_selection = .{ .term = term } });
    self.metal_dirty = true;
    return true;
}

/// **클릭이 푼 자리를 스냅숏 신선도와 함께 남긴다**(`MARU_DEBUG=1` 일 때만).
///
/// **왜 있는가**: 사용자 보고(2026-08-31) — 클릭하면 캐럿이 몇 줄 아래로 간다. **간헐적이라
/// 재현이 잡히지 않는다.** 코드를 읽어 찾은 유력 후보는 `hitTestBody` 가 스냅숏
/// (`editor_hit_rows`·`editor_hit_lines`·`editor_hit_geom`)만 보고 **그것이 지금 화면을 설명하는지
/// 묻지 않는다**는 것이다 — 같은 파일의 검색 reveal 경로에는 그 대조(`snapshot_is_current`)가 있고
/// 주석이 이유까지 적어 뒀는데(*"세 재료가 전부 지난 프레임의 것이라 방금 자기가 한 스크롤을 못
/// 본다"*), 클릭 경로만 그 방어가 없다.
///
/// **그런데 그 비대칭이 이 증상의 원인인지는 확정되지 않았다.** 스냅숏은 다음 렌더에 갱신되므로
/// 한 프레임짜리 어긋남만 만들 수 있는데, 보고된 증상이 그 폭인지 모른다. 그래서 **막지 않고
/// 찍기만 한다** — 추측으로 클릭을 버리면 멀쩡한 클릭이 씹히고, 그 편이 더 나쁘다.
///
/// 다음에 재현되면 이 한 줄이 답을 준다: `stale=true` 이면 스냅숏 낡음이 원인이고 그때 방어를
/// 넣으면 된다. `stale=false` 인데 `line` 이 사용자가 누른 줄과 다르면 **원인이 다른 데 있다**.
fn logHitSnapshotDiag(self: *AppSession, term: *Term, y_px: f64, off: usize) void {
    if (!diag_gate.maruDebugEnabled()) return;
    const geom = term.rt.editor_hit_geom;
    // 검색 reveal 경로가 쓰는 것과 **같은 대조**다(`snapshot_is_current`) — 판정을 새로 적으면
    // 두 벌이 되고, 진단이 제품과 다른 것을 재게 된다.
    const stale = geom.top_line != term.rt.editor_first_line or
        geom.top_piece != term.rt.editor_first_piece or
        geom.visible_len != editorLines(term).len or
        geom.wrap != (term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap) or
        geom.tab_width != term.rt.editor_tab_width or
        geom.cell_w_px != self.cell_width_px or
        geom.cell_h_px != self.cell_height_px;
    const doc = term.rt.editor_doc;
    const line = if (doc) |d| d.file.lines.lineAt(@min(off, d.file.content.len)) else 0;
    const row: i64 = if (geom.cell_h_px == 0) -1 else blk: {
        const rel = @as(i64, @intFromFloat(@max(-1e9, @min(1e9, y_px)))) - @as(i64, geom.body_y);
        break :blk @divFloor(rel, @as(i64, geom.cell_h_px));
    };
    editor_diag.debug(
        "hit y={d:.1} row={d} off={d} line={d} stale={} snap_top=({d},{d}) live_top=({d},{d}) " ++
            "snap_len={d} live_len={d} rows={d} folded={}",
        .{
            y_px,                                   row,
            off,                                    line,
            stale,                                  geom.top_line,
            geom.top_piece,                         term.rt.editor_first_line,
            term.rt.editor_first_piece,             geom.visible_len,
            editorLines(term).len,                  term.rt.editor_hit_rows_len,
            term.rt.editor_visible_numbers.len > 0,
        },
    );
}

/// 선택 드래그가 pane 밖에 머무는 동안 **한 줄씩 굴리고 선택을 늘린다**(frame-loop tick마다).
/// 화면보다 긴 범위를 드래그로 고르는 표준 동작이고, 없으면 보이는 만큼만 고를 수 있다.
///
/// **tick 수가 아니라 경과 ms로 게이트한다.** tick마다 한 줄이면 30→60Hz에서 두 배 빨라진다 —
/// 터미널이 그 사고를 겪고 고친 자리이고(`scroll.applyDragAutoscroll`), 같은 상수를 쓴다.
///
/// **굴린 뒤에 다시 hit-test한다.** 스크롤이 행 배열을 바꾸므로, 같은 화면 좌표가 새 줄을 가리킨다 —
/// 그것이 "선택이 따라 늘어난다"의 구현이다. 다만 그 배열은 **다음 렌더**가 갱신하므로 이 tick에서는
/// 아직 옛 배열이다. 한 프레임 늦게 따라오는 것이 맞다(렌더가 굳힌 것만 읽는다는 §4.1g 계약).
pub fn applyDragAutoscroll(self: *AppSession, leaf_rect: maru.session.SplitRect) void {
    if (self.editor_drag_autoscroll == 0) {
        self.editor_drag_autoscroll_accum_ms = 0;
        return;
    }
    // 비교 뷰도 같은 tick이 굴린다 — 소유자만 다르다.
    const owner_term: *Term = switch (self.pointer_gesture_owner) {
        .editor_selection => |g| g.term,
        .editor_diff_selection_drag => |g| g.term,
        else => {
            // 제스처가 끝났는데 방향이 남아 있으면 영원히 굴린다 — 터미널이 그 latch를 겪었다.
            self.editor_drag_autoscroll = 0;
            self.editor_drag_autoscroll_accum_ms = 0;
            return;
        },
    };
    const is_diff = self.pointerGestureIs(.editor_diff_selection_drag);
    const owner = .{ .term = owner_term };
    self.editor_drag_autoscroll_accum_ms += self.msPerTick();
    if (self.editor_drag_autoscroll_accum_ms < scroll_ops.drag_autoscroll_step_ms) return;
    self.editor_drag_autoscroll_accum_ms -= scroll_ops.drag_autoscroll_step_ms;

    if (!scrollLines(self, owner.term, leaf_rect, self.editor_drag_autoscroll)) return;

    // 굴린 방향의 **가장자리 행**으로 선택을 늘린다. 지금 배열은 굴리기 전 것이므로 그 끝 행을
    // 쓰면 한 줄씩 정확히 따라간다(다음 렌더가 배열을 갱신하면 그 자리가 새 줄이 된다).
    const cell_h: u16 = if (is_diff) owner.term.rt.editor_diff_hit_geom.cell_h_px else owner.term.rt.editor_hit_geom.cell_h_px;
    const body_y: i32 = if (is_diff) owner.term.rt.editor_diff_hit_geom.body_y else owner.term.rt.editor_hit_geom.body_y;
    const rows_len: usize = if (is_diff) blk: {
        const side = self.pointer_gesture_owner.editor_diff_selection_drag.side;
        break :blk if (side == .right) owner.term.rt.editor_diff_hit_len_right else owner.term.rt.editor_diff_hit_len_left;
    } else owner.term.rt.editor_hit_rows_len;
    if (cell_h == 0 or rows_len == 0) return;
    // 위로 굴리면(양수) 가장자리는 **첫 행**, 아래로 굴리면 마지막 행이다(터미널이 같은 식을 쓴다).
    const edge_row: usize = if (self.editor_drag_autoscroll > 0) 0 else rows_len - 1;
    const edge_y: f64 = @as(f64, @floatFromInt(body_y)) +
        @as(f64, @floatFromInt(edge_row * cell_h)) + 1;
    if (is_diff) {
        _ = dragDiffBodySelection(self, 2, self.editor_drag_x_px, edge_y);
    } else {
        _ = dragBodySelection(self, 2, self.editor_drag_x_px, edge_y);
    }
    // `dragBodySelection`이 가장자리 좌표를 "안"으로 읽어 방향을 지운다 — 다시 세운다.
    self.editor_drag_autoscroll = if (edge_row == 0) 1 else -1;
    self.metal_dirty = true;
}

/// 비교 뷰의 더블(단어)·트리플(줄) 클릭. 단일 편집기의 `selectWordOrLineAt`과 같은 규칙이고
/// 축만 다르다 — 대상이 문서가 아니라 그 열의 행이다.
fn selectWordOrLineInDiff(self: *AppSession, pane: *Pane, whole_line: bool, x_px: f64, y_px: f64) bool {
    const term = pane.activeTerm();
    if (pointOnEditorScrollbar(term, x_px, y_px)) return false;
    const hit = hitTestDiffBody(term, x_px, y_px, null) orelse return false;
    const st = term.rt.editor_diff orelse return false;
    const texts = if (hit.side == .right) st.right_texts else st.left_texts;
    if (hit.row >= texts.len) return false;
    const text = texts[hit.row];

    const range: struct { lo: usize, hi: usize } = if (whole_line)
        .{ .lo = 0, .hi = text.len } // 행 전체(줄 끝 문자는 이미 떼어져 있다)
    else blk: {
        const w = editor_selection.wordRangeAt(text, hit.byte);
        break :blk .{ .lo = w.lo, .hi = w.hi };
    };
    // **anchor는 범위다** — 점으로 두면 뒤로 끌 때 잡은 단어가 통째로 사라진다(§3.2가 단일
    // 편집기에서 anchor를 범위로 만든 이유 그대로다). `kind`는 드래그가 늘어나는 단위를 정한다.
    term.rt.editor_diff_selection = .{
        .side = hit.side,
        .sel = editor_selection.RowSelection.fromAnchorRange(
            .{ .row = hit.row, .byte = range.lo },
            .{ .row = hit.row, .byte = range.hi },
            .{ .row = hit.row, .byte = range.hi },
            if (whole_line) .line else .word,
        ),
    };
    self.beginPointerGesture(.{ .editor_diff_selection_drag = .{ .term = term, .side = hit.side } });
    self.metal_dirty = true;
    return true;
}

/// 비교 뷰 본문을 눌렀는가(§4.1g "비교 뷰"). 눌렀으면 선택을 시작하고 `true`.
///
/// 단일 편집기의 `beginBodySelection`과 같은 자리·같은 순서(막대 뒤·pane 포커스 앞)에 선다.
pub fn beginDiffBodySelection(self: *AppSession, pane: *Pane, x_px: f64, y_px: f64) bool {
    const term = pane.activeTerm();
    if (term.kind != .editor) return false;
    if (pointOnEditorScrollbar(term, x_px, y_px)) return false;
    const hit = hitTestDiffBody(term, x_px, y_px, null) orelse return false;
    term.rt.editor_diff_selection = .{
        .side = hit.side,
        .sel = editor_selection.RowSelection.at(.{ .row = hit.row, .byte = hit.byte }),
    };
    self.beginPointerGesture(.{ .editor_diff_selection_drag = .{ .term = term, .side = hit.side } });
    self.metal_dirty = true;
    return true;
}

/// 비교 뷰 선택의 드래그·뗌. `kind`는 호스트 관례(2=drag, 3=up).
///
/// **잡은 열로 강제한다** — 반대 열로 끌어도 그 열의 경계에 머문다(계약: 좌우를 걸치는 선택은
/// 만들지 않는다).
pub fn dragDiffBodySelection(self: *AppSession, kind: u32, x_px: f64, y_px: f64) bool {
    const owner = switch (self.pointer_gesture_owner) {
        .editor_diff_selection_drag => |g| g,
        else => return false,
    };
    switch (kind) {
        2 => {
            const hit = hitTestDiffBody(owner.term, x_px, y_px, owner.side) orelse return true;
            if (owner.term.rt.editor_diff_selection) |*ds| {
                // **잡은 단위로 늘어난다** — 단일 편집기의 `dragBodySelection`과 같은 규칙이다.
                // 글자 단위로 늘면 잡은 단어의 반쪽이 남아 사용자가 본 것과 어긋난다.
                const at: editor_selection.RowPos = .{ .row = hit.row, .byte = hit.byte };
                ds.sel.focus = switch (ds.sel.kind) {
                    .simple, .match => at,
                    .word, .line => blk: {
                        const st = owner.term.rt.editor_diff orelse break :blk at;
                        const texts = if (owner.side == .right) st.right_texts else st.left_texts;
                        if (hit.row >= texts.len) break :blk at;
                        const text = texts[hit.row];
                        // 앞으로 끌면 그 단위의 **끝**, 뒤로 끌면 **시작**까지 삼킨다.
                        const forward = !editor_selection.RowPos.lessThan(at, ds.sel.anchorHi());
                        const edge: usize = switch (ds.sel.kind) {
                            .line => if (forward) text.len else 0, // 줄 끝 문자는 이미 떼어져 있다
                            .word => w: {
                                const r = editor_selection.wordRangeAt(text, hit.byte);
                                break :w if (forward) r.hi else r.lo;
                            },
                            .simple, .match => unreachable, // 바깥 switch가 이미 갈랐다
                        };
                        break :blk .{ .row = hit.row, .byte = edge };
                    },
                };
                self.metal_dirty = true;
            }
            return true;
        },
        3 => {
            self.finishPointerGesture();
            return true;
        },
        else => return false,
    }
}

/// 비교 뷰 선택을 **줄별 byte 범위**로 자른다 — 그 열의 렌더가 요구하는 축이다.
///
/// 단일 편집기의 `buildSelectionMarks`와 같은 일인데 훨씬 짧다: 행 배열이 곧 화면이라 축 변환이 없다.
pub fn buildDiffSelectionMarksForTest(self: *AppSession, term: *Term, side: DiffSide) ?[]const []const chrome_editor.frame.Mark {
    return buildDiffSelectionMarks(self, term, side);
}

fn buildDiffSelectionMarks(self: *AppSession, term: *Term, side: DiffSide) ?[]const []const chrome_editor.frame.Mark {
    const sel = term.rt.editor_diff_selection orelse return null;
    if (sel.side != side) return null; // 다른 열은 선택이 없다
    const st = term.rt.editor_diff orelse return null;
    if (st.view != .compare) return null;
    const texts = if (side == .right) st.right_texts else st.left_texts;
    if (texts.len == 0) return null;

    // **정규화는 타입이 한다.** `fixedEnd`가 드래그 방향에 따라 anchor 범위의 어느 끝을 고정할지
    // 정하므로, 손으로 뒤집던 때와 달리 잡은 단어가 뒤로 끌어도 남는다.
    const lo = sel.sel.start();
    const hi = sel.sel.end();
    const lo_row = lo.row;
    const lo_byte = lo.byte;
    const hi_row = hi.row;
    const hi_byte = hi.byte;
    if (sel.sel.isEmpty()) return null; // caret뿐 — 그릴 띠가 없다

    const rows_field = if (side == .right) &term.rt.editor_diff_marks_right else &term.rt.editor_diff_marks_left;
    const buf_field = if (side == .right) &term.rt.editor_diff_mark_buf_right else &term.rt.editor_diff_mark_buf_left;
    if (rows_field.len < texts.len) {
        const grown_rows = self.allocator.alloc([]const chrome_editor.frame.Mark, texts.len) catch return null;
        const grown_buf = self.allocator.alloc(chrome_editor.frame.Mark, texts.len) catch {
            self.allocator.free(grown_rows);
            return null;
        };
        if (rows_field.len > 0) self.allocator.free(rows_field.*);
        if (buf_field.len > 0) self.allocator.free(buf_field.*);
        rows_field.* = grown_rows;
        buf_field.* = grown_buf;
    }
    const rows = rows_field.*[0..texts.len];
    const buf = buf_field.*[0..texts.len];
    @memset(rows, &.{});

    // **행이 배열 밖이면 그릴 것이 없다.** `lo_row > texts.len`이면 아래 for-range가 `integer
    // overflow`로 죽는다 — 선택을 든 채 문서가 짧아지는 경로가 실재한다(적대적 검증).
    if (lo_row >= texts.len) return null;
    for (lo_row..@min(hi_row + 1, texts.len)) |i| {
        const text = texts[i];
        const from: u32 = if (i == lo_row) @intCast(@min(lo_byte, text.len)) else 0;
        const to: u32 = if (i == hi_row) @intCast(@min(hi_byte, text.len)) else @intCast(text.len);
        if (to <= from) continue;
        buf[i] = .{ .start = from, .len = to - from };
        rows[i] = buf[i .. i + 1];
    }
    return rows;
}

/// 비교 뷰 선택을 클립보드로. 복사할 것이 없으면 `false`.
///
/// **빈 행은 건너뛴다.** 짝맞춤 행은 그 자리에 줄이 **없는** 것이므로, 개행을 내면 원본에 없던
/// 빈 줄이 붙는다(줄 끝이 `null`인 행이 그것이다 — `*_endings`). §4.1g "비교 뷰"가 정한 규칙이다.
///
/// **줄 끝은 원본에서 되돌린다** — `*_texts`는 화면용이라 떼어져 있어서, 그대로 이으면 CRLF 문서가
/// LF로 바뀐다. 다만 **끝 개행 하나는 아직 갈린다**(§4.1g "아직 없는 것") — `splitLines`는 마지막
/// 줄 끝 뒤에 줄을 만들지 않는데 단일 편집기의 `line_index`는 빈 줄을 하나 더 두므로, 본문 끝까지
/// 고르면 단일 쪽에만 그 개행이 들어온다.
pub fn copyDiffSelection(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const sel = term.rt.editor_diff_selection orelse return false;
    const st = term.rt.editor_diff orelse return false;
    if (st.view != .compare) return false;
    const texts = if (sel.side == .right) st.right_texts else st.left_texts;
    // **줄 끝은 뗄 때 함께 굳혀 둔 것을 쓴다.** `*_texts`는 §3.8 가시화 때문에 줄 끝을 뗀 것이라
    // 그것만 이어 붙이면 CRLF 문서가 LF로 바뀌어 나간다. 줄 번호로 원본 배열을 되짚지 않는 이유는
    // 그 인덱스 산술이 맞다는 보장이 **출하 빌드에 없기** 때문이다(ReleaseFast에는 단언도 경계
    // 검사도 없다).
    const endings = if (sel.side == .right) st.right_endings else st.left_endings;
    // **불변식을 확인하고 어긋나면 거절한다.** 길이가 같다는 것은 타입이 아니라 `materialize`가
    // 지키는 것이라(같은 문장에서 같은 `rows.*.len`으로 잡는다) 여기서 확인할 값어치가 있다.
    // 어긋난 채로 이어 붙이면 **틀린 바이트가 조용히 클립보드로 간다** — 안 하는 편이 낫다.
    if (endings.len != texts.len) return false;

    // 정규화는 타입이 한다(위 `buildDiffSelectionMarks`와 같다) — 같은 네 줄을 복제하던 자리다.
    const lo = sel.sel.start();
    const hi = sel.sel.end();
    const lo_row = lo.row;
    const lo_byte = lo.byte;
    const hi_row = hi.row;
    const hi_byte = hi.byte;
    if (sel.sel.isEmpty()) return false;

    if (lo_row >= texts.len) return false; // 문서가 짧아졌다 — 위 `buildDiffSelectionMarks`와 같은 가드
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    // **분리자는 "앞에 줄이 있었는가"로 붙인다.** `out.items.len > 0`으로 걸면 첫 줄이 **진짜 빈
    // 줄**일 때 그 개행이 사라진다(실측: `keep`/``/`tail`에서 행 1~2를 고르면 `"tail"`만 나왔고,
    // 빈 줄만 고르면 아무것도 안 갔다). 단일 편집기는 문서 byte를 그대로 뜨므로 `"\n"`이 나온다 —
    // 같은 명령이 뷰에 따라 다르게 동작하면 안 된다.
    // **직전 줄의 끝** — 다음 줄을 쓸 때 앞에 붙인다. `null`이면 아직 아무 줄도 안 썼다는 뜻이라
    // 초기값을 지어낼 필요가 없다(첫 줄 앞에는 분리자가 없다).
    var pending_ending: ?[]const u8 = null;
    for (lo_row..@min(hi_row + 1, texts.len)) |i| {
        // **짝맞춤 빈 행은 `endings`가 스스로 말한다**(`null` = 그 자리에 줄이 없다). 예전에는
        // `numbers`를 봤는데, 그러면 이 배열의 안전성이 **다른 배열**에 달린다 — 짝맞춤 처리를
        // 나중에 바꾸면 뜻 없는 값이 분리자로 새어 나간다.
        const ending = endings[i] orelse continue;
        const text = texts[i];
        const from = if (i == lo_row) @min(lo_byte, text.len) else 0;
        const to = if (i == hi_row) @min(hi_byte, text.len) else text.len;
        if (pending_ending) |e| out.appendSlice(self.allocator, e) catch return false;
        if (to > from) out.appendSlice(self.allocator, text[from..to]) catch return false;
        // **그 줄이 실제로 무엇으로 끝났는지**를 다음 분리자로 쓴다. `'\n'`을 하드코딩하면 CRLF
        // 문서가 LF로 바뀌어 나간다.
        pending_ending = ending;
    }
    if (pending_ending == null) return false; // 고른 것이 짝맞춤 빈 행뿐이다 — 그 자리에 줄이 없다

    const captured = self.allocator.dupe(u8, out.items) catch return false;
    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
    self.chrome_clipboard_write = captured;
    return true;
}

/// 편집기 본문에서 **더블클릭(단어)·트리플클릭(줄)**. 잡았으면 `true`.
///
/// **`AnchorKind`가 여기서 정해진다.** `anchor`가 점이 아니라 **범위**인 이유가 이것이다 — 단어를
/// 잡고 뒤로 끌어도 그 단어가 통째로 남아야 하는데, 점이면 잘린다(`selection.zig` 머리말).
/// 이어지는 드래그가 그 단위로 늘어나는 것은 `dragBodySelection`이 맡는다.
///
/// **`pxToCell`보다 먼저 불려야 한다** — 그 함수는 영역 밖 좌표를 터미널 grid로 clamp하므로,
/// 편집기 좌표가 거기까지 가면 터미널에 단어/줄 선택 블록이 생긴다(도크가 같은 부류로 제보됐다).
/// 이 좌표가 편집기 **막대 띠** 위인가. 순수 판정이다 — `beginScrollbarGesture`는 잡는 부작용이
/// 있어 "눌렀는가"만 묻는 자리에서는 못 쓴다.
///
/// **띠 전체를 본다**(막대 자체가 아니라). 트랙 위 클릭도 막대가 가져가므로(그 지점으로 점프한다)
/// 본문 선택이 그 자리를 뺏으면 안 된다.
fn pointOnEditorScrollbar(term: *Term, x_px: f64, y_px: f64) bool {
    inline for (.{ term.rt.editor_scrollbar, term.rt.editor_scrollbar_right }) |maybe| {
        if (maybe) |bar| {
            if (x_px >= bar.hit_x and x_px < bar.hit_x + bar.hit_w and
                y_px >= bar.track_y and y_px < bar.track_y + bar.track_h) return true;
        }
    }
    inline for (.{ term.rt.editor_horizontal_scrollbar, term.rt.editor_horizontal_scrollbar_right }) |maybe| {
        if (maybe) |bar| {
            if (y_px >= bar.track_y and y_px < bar.track_y + bar.track_h and
                x_px >= bar.track_x and x_px < bar.track_x + bar.track_w) return true;
        }
    }
    return false;
}

pub fn selectWordOrLineAt(self: *AppSession, pane: *Pane, whole_line: bool, x_px: f64, y_px: f64) bool {
    const term = pane.activeTerm();
    if (term.kind != .editor) return false;
    // **비교 뷰도 여기서 소비한다.** `hitTestBody`가 diff를 첫 줄에서 거절하므로 이 자리에서 갈리지
    // 않으면 `false`가 나가고, 그 좌표는 `pxToCell`로 흘러 **터미널에** 단어/줄 선택 블록을 만든다
    // (이 함수 doc이 도크 제보로 적어 둔 그 사고다 — 적대적 검증이 비교 뷰에서 재현했다).
    if (term.rt.editor_diff != null) return selectWordOrLineInDiff(self, pane, whole_line, x_px, y_px);
    // **막대 띠는 여기서도 거절한다.** 단일 클릭은 pane 라우팅이 `divider → 막대 → 본문` 순서로
    // 걸러 주는데 kind 4/5는 그 블록을 안 타므로, 이 자리에서 같은 순서를 져야 한다 — 안 그러면
    // 막대 위 더블클릭이 **진행 중인 막대 드래그를 취소하고** 본문 선택을 연다(실측). 결정표의
    // *"막대 위 클릭은 상위가 먼저 가져간다"*가 kind에 따라 갈리면 그것은 규칙이 아니다.
    if (pointOnEditorScrollbar(term, x_px, y_px)) return false;
    const off = hitTestBody(term, x_px, y_px) orelse return false;
    const doc = term.rt.editor_doc orelse return false;

    const range: struct { lo: usize, hi: usize, kind: editor_selection.AnchorKind } = if (whole_line) blk: {
        // **줄 전체.** 개행은 뺀다 — 붙여넣기가 줄바꿈을 하나 더 만들지 않게 한다(트리플클릭이
        // 문단 사이를 벌리는 것은 사용자가 기대하는 바가 아니다).
        const li = doc.file.lines.lineAt(@min(off, doc.file.lines.byteLen()));
        const line = doc.file.lines.line(li) orelse return false;
        break :blk .{ .lo = line.start, .hi = line.contentEnd(), .kind = .line };
    } else blk: {
        const w = editor_selection.wordRangeAt(doc.file.content, off);
        break :blk .{ .lo = w.lo, .hi = w.hi, .kind = .word };
    };

    // **빈 범위면 `.simple`이어야 한다.** `fromAnchorRange`가 `(kind == .simple) == (lo == hi)`를
    // 단언하는데, **빈 줄**을 트리플클릭하면 `line.start == contentEnd()`라 그 단언이 깨진다
    // (안전 빌드는 panic, ReleaseFast는 확장 단위를 모르는 `.line`이 남는다 — 그 assert가 막으려던
    // 바로 그 상태다). 빈 줄에 caret을 두는 것이 옳다: 고를 것이 없다.
    const kind = if (range.lo == range.hi) editor_selection.AnchorKind.simple else range.kind;
    clearExtraSelections(self, term);
    breakUndoGroup(term); // 위와 같은 이유(§3.3)
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(range.lo, range.hi, range.hi, kind);
    // **드래그를 이어서 arm한다** — 더블클릭 후 끌면 단어 단위로 늘어난다. 뗌이 소유권을 놓는다.
    self.beginPointerGesture(.{ .editor_selection = .{ .term = term } });
    self.metal_dirty = true;
    return true;
}

/// 드래그·뗌을 소비한다. `kind`는 호스트 관례(2=drag, 3=up).
///
/// **`focus`만 움직인다** — `anchor_*`는 down이 세운 자리에 남는다. 그것이 드래그 선택의 정의이고,
/// 뒤로 끌면 `anchorLo`/`anchorHi`가 `@min`/`@max`로 읽어 범위가 뒤집히지 않는다(`Selection` doc).
pub const ColumnStep = enum { up, down, left, right };

/// 키보드로 사각형을 넓힌다 — **`from` 은 고정이고 `to` 만 움직인다**(§3.2a).
///
/// 시작 모서리가 따라 움직이면 그것은 넓히는 것이 아니라 **옮기는** 것이다(VSCode `columnSelectUp` 등이
/// 전부 `from` 을 그대로 넘긴다).
///
/// **사각형이 없으면 지금 caret 에서 만든다** — 그래야 키만으로 열 선택을 시작할 수 있다.
pub fn columnSelectStep(self: *AppSession, term: *Term, step: ColumnStep) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;

    if (term.rt.editor_column_anchor == null) {
        const sel = term.rt.editor_selection orelse return false;
        const li = doc.file.lines.lineAt(@min(sel.focus, doc.file.content.len));
        const line = doc.file.lines.line(li) orelse return false;
        const pm = productColumnMap(term);
        const col = pm.map().columnOf(pm.map().ctx, doc.file.content[line.start..line.contentEnd()], sel.focus - line.start);
        const row: u32 = @intCast(li);
        term.rt.editor_column_anchor = .{ .from_row = row, .from_col = col, .to_row = row, .to_col = col };
    }
    var a = &term.rt.editor_column_anchor.?;

    switch (step) {
        .up => a.to_row -|= 1,
        .down => {
            const last: u32 = @intCast(doc.file.lines.lineCount() -| 1);
            if (a.to_row < last) a.to_row += 1;
        },
        .left => a.to_col -|= 1,
        // **오른쪽 상한은 「걸친 줄들 중 가장 긴 줄의 끝 열」이다**(VSCode `maxVisualViewColumn`).
        // 없으면 오른쪽 키가 영원히 먹히고, 되돌리려면 그 횟수만큼 왼쪽을 눌러야 한다.
        .right => {
            const lo = @min(a.from_row, a.to_row);
            const hi = @max(a.from_row, a.to_row);
            const pm = productColumnMap(term);
            var max_col: u32 = 0;
            var i = lo;
            while (i <= hi) : (i += 1) {
                const line = doc.file.lines.line(i) orelse continue;
                const text = doc.file.content[line.start..line.contentEnd()];
                const c = pm.map().columnOf(pm.map().ctx, text, text.len);
                if (c > max_col) max_col = c;
            }
            if (a.to_col < max_col) a.to_col += 1;
        },
    }
    applyColumnSelection(self, term);
    revealPrimaryCaret(self, term);
    return true;
}

/// 사각형을 줄마다 selection 으로 펴서 제품 두 필드에 쓴다(§3.2a).
///
/// **매 프레임 다시 판다** — 결과를 누적하지 않으므로 사각형을 줄이면 커서도 줄고, 상한에 걸렸다
/// 풀려도 복구된다("누적되지 않고 대체된다").
fn applyColumnSelection(self: *AppSession, term: *Term) void {
    const anchor = term.rt.editor_column_anchor orelse return;
    const doc = term.rt.editor_doc orelse return;
    // **랩이 꺼졌으면 스냅숏을 안 쓴다.** 그때 시각 행은 논리 줄과 1:1 이라 두 경로가 **같은 답**을
    // 내는데, 스냅숏에 기대면 **화면 밖 줄에 커서가 안 선다** — 키보드로 넓히거나 자동 스크롤이
    // 따라오기 전에는 그 행이 스냅숏에 없기 때문이다. `movedVisualRow` 가 같은 이유로 랩이 꺼지면
    // 논리 줄 경로로 떨어진다.
    const wrapped = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap;
    const rows_len = term.rt.editor_hit_rows_len;
    if (wrapped and rows_len == 0) return; // 랩인데 그린 것이 없다 — 조각을 알 길이 없다

    // **`to_row` 에서 시작해 `from_row` 쪽으로** 모은다 — 그 순서가 곧 상한에서 살아남는 쪽이다.
    var rows: std.ArrayList(editor_column.Row) = .empty;
    defer rows.deinit(self.allocator);
    const first = term.rt.editor_first_line;
    const step: i64 = if (anchor.from_row > anchor.to_row) 1 else -1;
    var r: i64 = @intCast(anchor.to_row);
    const end: i64 = @as(i64, @intCast(anchor.from_row)) + step;
    while (r != end) : (r += step) {
        if (r < 0) break;
        const abs: usize = @intCast(r);
        const line_idx: usize = if (wrapped) blk: {
            if (abs < first or abs - first >= rows_len) continue; // 랩: 스냅숏 밖은 조각을 모른다
            break :blk term.rt.editor_hit_lines[abs - first];
        } else abs;
        const line = doc.file.lines.line(line_idx) orelse continue;
        const text = doc.file.content[line.start..line.contentEnd()];
        rows.append(self.allocator, .{ .start = line.start, .text = text }) catch break;
    }
    if (rows.items.len == 0) return;

    const cap = @min(rows.items.len, editor_selection.max_cursors);
    const buf = self.allocator.alloc(editor_selection.Selection, cap) catch return;
    defer self.allocator.free(buf);
    const pm = productColumnMap(term);
    const n = editor_column.derive(rows.items, anchor, pm.map(), buf);
    if (n == 0) return;

    // primary 는 **끌고 있는 쪽** — 첫 항목이 `to_row` 다(§3.2a).
    const extras = self.allocator.alloc(editor_selection.Selection, n - 1) catch return;
    @memcpy(extras, buf[1..n]);
    if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = extras;
    term.rt.editor_selection = buf[0];
    self.metal_dirty = true;
}

pub fn dragBodySelection(self: *AppSession, kind: u32, x_px: f64, y_px: f64) bool {
    const owner = switch (self.pointer_gesture_owner) {
        .editor_selection => |g| g,
        else => return false,
    };
    switch (kind) {
        2 => {
            // **위아래로 벗어났는가.** 굳은 기하로 잰다(§4.1g "스냅숏의 경계") — live로 다시 구하면
            // 행 배열과 다른 프레임의 값이 된다. 벗어난 동안 tick이 한 줄씩 굴리고 선택을 늘린다.
            const g = owner.term.rt.editor_hit_geom;
            self.editor_drag_x_px = x_px;
            if (g.cell_h_px > 0 and owner.term.rt.editor_hit_rows_len > 0) {
                const top: f64 = @floatFromInt(g.body_y);
                const bottom = top + @as(f64, @floatFromInt(owner.term.rt.editor_hit_rows_len * g.cell_h_px));
                // **부호는 `scrollLines`의 규약을 따른다**: 양수가 문서의 **앞쪽**(위)이다(터미널
                // 스크롤백과 같은 방향 규약이고 `drag_autoscroll`도 그렇다). 반대로 넣었다가
                // SEL5가 잡았다 — 아래로 끌면 위로 굴리려 하고 맨 위라 clamp에 막혔다.
                self.editor_drag_autoscroll = if (y_px < top) 1 else if (y_px > bottom) -1 else 0;
                if (self.editor_drag_autoscroll == 0) self.editor_drag_autoscroll_accum_ms = 0;
            }
            // **열 선택이면 사각형을 늘리고 파생한다**(§3.2a) — 아래 「잡은 단위로 늘어난다」 갈래는
            // 단일 selection 의 focus 를 미는 것이라 사각형과 축이 다르다.
            if (owner.term.rt.editor_column_anchor != null) {
                if (visualRowColAt(owner.term, x_px, y_px)) |rc| {
                    owner.term.rt.editor_column_anchor.?.to_row = rc.row;
                    owner.term.rt.editor_column_anchor.?.to_col = rc.col;
                    applyColumnSelection(self, owner.term);
                }
                return true;
            }
            const off = hitTestBody(owner.term, x_px, y_px) orelse return true; // 잡은 채로 밖 — 소비만 한다
            if (owner.term.rt.editor_selection) |*sel| {
                // **잡은 단위로 늘어난다**(`AnchorKind` doc). 더블클릭 뒤 끌면 지나가는 단어가
                // 통째로, 트리플클릭 뒤 끌면 줄이 통째로 들어온다 — 글자 단위로 늘면 잡은 단어의
                // 반쪽이 남아 사용자가 본 것과 어긋난다.
                sel.focus = switch (sel.kind) {
                    // `.match`(일치로 잡은 범위)는 잡은 단위가 없으므로 글자 단위로 는다 — `.simple`과 같다.
                    .simple, .match => off,
                    .word => blk: {
                        const doc = owner.term.rt.editor_doc orelse break :blk off;
                        const w = editor_selection.wordRangeAt(doc.file.content, off);
                        // 앞으로 끌면 그 단어의 **끝**, 뒤로 끌면 **시작**까지 삼킨다.
                        break :blk if (off >= sel.anchorHi()) w.hi else w.lo;
                    },
                    .line => blk: {
                        const doc = owner.term.rt.editor_doc orelse break :blk off;
                        const li = doc.file.lines.lineAt(@min(off, doc.file.lines.byteLen()));
                        const line = doc.file.lines.line(li) orelse break :blk off;
                        break :blk if (off >= sel.anchorHi()) line.contentEnd() else line.start;
                    },
                };
                self.metal_dirty = true;
            }
            return true;
        },
        3 => {
            self.editor_drag_autoscroll = 0; // 손을 뗐다 — 안 끄면 tick이 영원히 굴린다
            self.editor_drag_autoscroll_accum_ms = 0;
            self.finishPointerGesture();
            return true;
        },
        else => return false,
    }
}

/// 편집기 스크롤바를 **잡았는가**. 잡았으면 드래그를 시작하고 `true`를 준다.
///
/// **세로·가로를 한 자리에서 판정한다** — 두 막대는 pane 안에서 겹치지 않으므로(세로는 오른쪽 거터,
/// 가로는 아래 거터) 순서만 정하면 된다. 세로를 먼저 본다: 오른쪽 아래 모서리에서 둘이 만나면 세로가
/// 이긴다(세로가 늘 있고 가로는 랩이면 없다).
///
/// 기하는 **렌더가 창 좌표로 실어 둔 값**을 쓴다(`rt.editor_scrollbar`) — 여기서 다시 계산하면
/// "보이는 자리"와 "잡히는 자리"가 갈린다.
pub fn beginScrollbarGesture(self: *AppSession, pane: *Pane, x_px: f64, y_px: f64) bool {
    // **좌표가 가리키는 pane의 Term을 본다** — 활성 pane을 가정하면 split에서 다른 열의 막대를 눌렀을 때
    // 엉뚱한 문서가 스크롤된다(`beginDividerCapture`가 좌표로 판정하는 것과 같은 규율이다).
    const term = pane.activeTerm();
    if (term.kind != .editor) return false;

    // **판정은 `Drag.begin` 한 곳이다.** 여기서 `trackContains`를 또 부르면 같은 질문에 답하는 자리가
    // 둘이 되고, 한쪽이 바뀌면 "눌렀는데 안 잡힌다"가 조용히 생긴다 — 이 저장소가 여러 번 겪은 부류다.
    // 그래서 **차례로 시도하고 선 것을 쓴다**(실패한 시도는 상태를 건드리지 않는다).
    //
    // **세로를 먼저 본다** — 오른쪽 아래 모서리에서 둘이 만나면 세로가 이긴다(세로는 늘 있고 가로는
    // 랩이면 없다). 비교 뷰는 열이 둘이라 각 축을 좌우 모두 본다.
    if (term.rt.editor_scrollbar) |bar| {
        if (beginVertical(self, term, bar, x_px, y_px)) return true;
    }
    if (term.rt.editor_scrollbar_right) |bar| {
        // **세로는 좌우 값이 같다**(§3.5 세로 공유) — 어느 자리를 눌렀든 같은 곳으로 간다.
        if (beginVertical(self, term, bar, x_px, y_px)) return true;
    }
    if (term.rt.editor_horizontal_scrollbar) |bar| {
        if (beginHorizontal(self, term, bar, x_px, y_px, false)) return true;
    }
    if (term.rt.editor_horizontal_scrollbar_right) |bar| {
        // **가로는 각자다**(§3.5) — 오른쪽 막대는 오른쪽 열만 민다.
        if (beginHorizontal(self, term, bar, x_px, y_px, true)) return true;
    }
    return false;
}

fn beginVertical(self: *AppSession, term: *Term, bar: chrome.ui.scroll_area.ScrollbarGeometry, x_px: f64, y_px: f64) bool {
    self.editor_scrollbar_term = term;
    if (self.dock_list_scroll_drag.begin(bar, x_px, y_px)) |jumped| setEditorScrollFromBarPx(self, jumped);
    // **여기가 유일한 성공 판정이다.** `begin`의 `null`은 두 가지를 뜻하므로(thumb을 잡아 점프하지 않은
    // 성공 · track 밖이라 시작 못 한 실패) 반환값으로는 못 가른다 — `active`가 그 답이다.
    // 실패면 잡은 것을 되돌리고 `false`를 준다: 호출자가 다음 막대를 시도한다.
    if (!self.dock_list_scroll_drag.active) {
        self.editor_scrollbar_term = null;
        return false;
    }
    self.scrollbar_drag_target = .editor_vertical;
    self.pointer_gesture_owner = .none;
    self.metal_dirty = true;
    return true;
}

fn beginHorizontal(self: *AppSession, term: *Term, bar: chrome_editor.scrollbar.HorizontalGeometry, x_px: f64, y_px: f64, right: bool) bool {
    self.editor_scrollbar_term = term;
    self.editor_hscroll_right = right;
    if (self.editor_hscroll_drag.begin(bar, x_px, y_px)) |jumped| setEditorHScrollFromBarPx(self, jumped);
    if (!self.editor_hscroll_drag.active) { // 위 세로와 같은 이유
        self.editor_scrollbar_term = null;
        self.editor_hscroll_right = false;
        return false;
    }
    self.scrollbar_drag_target = .editor_horizontal;
    self.pointer_gesture_owner = .none;
    self.metal_dirty = true;
    return true;
}

/// 진행 중인 편집기 막대 드래그의 move/up. 좌표를 흡수만 하고 **tick이 최종 하나를 적용한다**
/// (CIM2 §4.3 — move 수가 아니라 tick 수가 상한이다).
pub fn routeScrollbarCapture(self: *AppSession, kind: i32, x_px: f64, y_px: f64) bool {
    switch (self.scrollbar_drag_target) {
        .editor_vertical => {
            if (kind == 2) {
                self.dock_list_scroll_drag.absorb(x_px, y_px);
            } else {
                self.dock_list_scroll_drag.end();
                self.scrollbar_drag_target = .none;
                self.editor_scrollbar_term = null;
            }
            return true;
        },
        .editor_horizontal => {
            if (kind == 2) {
                self.editor_hscroll_drag.absorb(x_px, y_px);
            } else {
                self.editor_hscroll_drag.end();
                self.scrollbar_drag_target = .none;
                self.editor_scrollbar_term = null;
                self.editor_hscroll_right = false; // 다음 down이 자기 열을 새로 정한다
            }
            return true;
        },
        else => return false,
    }
}

/// 편집기 막대 드래그가 진행 중인가 — `mouse()`가 **다른 판정보다 먼저** 물어야 한다(이관 계약 §2:
/// "진행 중인 capture가 최우선"). 안 그러면 포인터가 본문 위로 지나는 순간 드래그가 끊긴다.
pub fn scrollbarCaptureActive(self: *const AppSession) bool {
    return self.scrollbar_drag_target == .editor_vertical or self.scrollbar_drag_target == .editor_horizontal;
}

/// 세로 막대 드래그가 준 **px offset**을 편집기 좌표 `(논리 줄, 조각)`으로 옮긴다.
///
/// **왜 변환이 필요한가.** 막대는 `시각 행 × 셀 높이`로 만들어지는데(스크롤바 컴포넌트) 편집기가 드는
/// 좌표는 논리 줄과 조각이다. 랩·접힘 때문에 둘은 **비선형**이라 비율로 근사하면 손가락과 화면이
/// 어긋난다 — 접두합(`RowCache.prefix`)을 되짚어야 정확하다.
///
/// **아직 다 세지 못한 구간은 "줄당 한 행"으로 친다**(§2.1 점진 계수와 같은 근사). 그 구간에서는 드래그가
/// 조금 어긋나지만, 계수가 끝나면 다음 드래그부터 정확하다 — 화면을 멈추는 것보다 낫다.
pub fn setEditorScrollFromBarPx(self: *AppSession, offset_px: u32) void {
    // **잡은 Term에 간다** — 드래그 도중 포커스가 옮겨져도 손가락이 잡은 그 문서가 움직여야 한다.
    const term = self.editor_scrollbar_term orelse return;
    if (term.kind != .editor) return;
    const cell_h: u32 = @intCast(self.cell_height_px);
    if (cell_h == 0) return;
    const target_row: u32 = offset_px / cell_h;

    // **비교 뷰는 캐시가 비어 있다** — `buildDiffPaneOps`에 `row_cache`를 안 넘긴다(좌우 두 캐시가
    // 필요한데 저장소가 하나다 — #2371이 한계로 적은 자리). 그래서 아래 `line = target_row` 선형
    // 경로로 떨어지는데, **랩이 꺼진 비교에서는 그것이 정확하다**(시각 행 = 행 배열 인덱스). 랩을 켠
    // 비교는 애초에 좌우가 어긋나 비교가 성립하지 않는다(§3.5 "알려진 구멍") — 그 구멍이 닫힐 때
    // 좌우 캐시와 함께 본다.
    const c = &term.rt.editor_row_cache;
    var line: usize = target_row;
    var piece: u32 = 0;
    if (c.filled and c.filled_upto > 0 and c.prefix.len > c.filled_upto) {
        // 접두합에서 `prefix[i] <= target < prefix[i+1]`인 i를 찾는다 — 그 i가 논리 줄이고 나머지가 조각.
        if (target_row < c.prefix[c.filled_upto]) {
            var lo: usize = 0;
            var hi: usize = c.filled_upto; // prefix[hi] > target 이 보장된다
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (c.prefix[mid] <= target_row) lo = mid else hi = mid;
            }
            line = lo;
            piece = target_row - c.prefix[lo];
        } else {
            // 안 센 구간 — 줄당 한 행으로 친다.
            line = c.filled_upto + (target_row - c.prefix[c.filled_upto]);
            piece = 0;
        }
    }

    // **상한을 넘지 않는다**(§4.1d) — 렌더가 실어 둔 값이 단일 출처다.
    if (line > term.rt.editor_max_top_line) {
        line = term.rt.editor_max_top_line;
        piece = term.rt.editor_max_top_piece;
    } else if (line == term.rt.editor_max_top_line and piece > term.rt.editor_max_top_piece) {
        piece = term.rt.editor_max_top_piece;
    }

    if (line == term.rt.editor_first_line and piece == term.rt.editor_first_piece) return;
    term.rt.editor_first_line = line;
    term.rt.editor_first_piece = piece;
    self.metal_dirty = true;
}

/// 가로 막대 드래그가 준 **px offset**을 **열**로 옮긴다. 세로와 달리 선형이다(열 × 셀 폭).
pub fn setEditorHScrollFromBarPx(self: *AppSession, offset_px: u32) void {
    const term = self.editor_scrollbar_term orelse return;
    if (term.kind != .editor) return;
    const cell_w: u32 = @intCast(self.cell_width_px);
    if (cell_w == 0) return;
    const col_u32 = @min(offset_px / cell_w, @as(u32, chrome_editor.frame.max_first_col));
    const col: u16 = @intCast(col_u32);
    // **잡은 막대의 열에 간다**(§3.5 — 가로는 각자다). 비교 뷰가 아니면 늘 왼쪽이다.
    const slot = if (self.editor_hscroll_right) &term.rt.editor_first_col_right else &term.rt.editor_first_col;
    if (col == slot.*) return;
    slot.* = col;
    self.metal_dirty = true;
}

/// pane 상대 막대 기하를 **창 좌표**로 옮긴다. 축마다 옮길 필드가 달라 둘로 나뉜다 —
/// 한 함수에 담으면 세로의 `hit_x`와 가로의 `hit_y` 중 무엇을 옮기는지가 인자 순서에 숨는다.
fn shiftScrollbar(bar: chrome.ui.scroll_area.ScrollbarGeometry, dx: i32, dy: i32) chrome.ui.scroll_area.ScrollbarGeometry {
    var out = bar;
    const fx: f32 = @floatFromInt(dx);
    const fy: f32 = @floatFromInt(dy);
    out.track_x += fx;
    out.track_y += fy;
    out.hit_x += fx;
    out.thumb_y += fy;
    return out;
}

fn shiftHorizontalScrollbar(bar: chrome_editor.scrollbar.HorizontalGeometry, dx: i32, dy: i32) chrome_editor.scrollbar.HorizontalGeometry {
    var out = bar;
    const fx: f32 = @floatFromInt(dx);
    const fy: f32 = @floatFromInt(dy);
    out.track_x += fx;
    out.track_y += fy;
    out.hit_y += fy;
    out.thumb_x += fx;
    return out;
}

/// 비교 뷰의 **좌우 가장 긴 줄**을 센다(§4.1a — 가로 막대가 첫 프레임부터 서야 그 축이 있다는 것을
/// 사용자가 안다). 문서 편집기가 여는 경로에서 `ensureMaxCols`를 부르는 것과 같은 시점·같은 셈이고,
/// 비교는 두 문서라 **두 번** 부른다.
///
/// **행 배열이 선 뒤에 불러야 한다** — 이 셈이 `left_texts`/`right_texts`를 읽으므로 그 전에 부르면
/// 빈 것을 센다. 호출자(`editor_diff.computeRows`)가 그 순서를 지킨다.
pub fn ensureMaxColsForDiff(term: *Term) void {
    ensureMaxCols(term, false);
    ensureMaxCols(term, true);
}

/// 렌더에 넘길 **가장 긴 줄의 열 수**(0 = 아직 안 셌다 → 막대 없음).
///
/// **비교 뷰는 열마다 각자다**(§3.5) — 왼쪽은 원본, 오른쪽은 수정본이라 가장 긴 줄이 다르고,
/// 막대 길이도 그래서 각자여야 한다.
fn maxColsForRender(term: *Term, right: bool) ?u32 {
    const v = if (right) term.rt.editor_max_cols_right else term.rt.editor_max_cols;
    return if (v == 0) null else v;
}

/// 문서에서 **가장 긴 줄**의 표시 폭을 세어 캐시한다(이미 있으면 그대로).
///
/// **여는 경로와 가로 스크롤 입력이 같이 쓴다.** 예전에는 첫 가로 휠에서만 셌는데, 그러면 굴리기
/// 전에는 값이 0이라 **가로 스크롤바가 뜨지 않아** 사용자가 그 축이 있는지도 모른다(2026-08-18
/// 사용자 지적으로 드러난 자리다 — 접힘 화살표가 같은 이유로 여는 경로에서 계산된다).
///
/// **셈에도 상한이 있다**(`max_cols_count_limit`) — 그 너머는 `max_first_col` 때문에 어차피 못 가므로
/// 세면 낭비다. 5MB짜리 한 줄에서 첫 가로 휠이 149ms였다(적대적 검증 2026-08-16).
///
/// **줄이 많을 때는 점진으로 나누지 않는다**(2026-08-18 결정). 세로 축은 같은 부류의 전 문서 훑기를
/// 점진 계수로 나눴는데(§2.1) 이 가로 축은 그대로 둔다 — 이유는 성능이 아니라 **화면**이다.
/// `content_max_cols`가 `null`이면 가로 막대를 **아예 안 그리고**, 그 막대는 본문 아래 여백에서
/// **자리를 먹으므로**(§4.1a) 생겼다 사라지면 본문 높이가 출렁인다. 세로 막대는 안 센 줄을 한 행으로
/// 쳐도 "짧게라도" 그려지지만 가로는 그렇지 않다.
///
/// **실측(ReleaseFast, 2026-08-18 — 단계마다 직접 잰다)**: 2만 줄(2.1MB)에서 읽기+파싱 3ms,
/// 줄 배열 ~0ms, 이 셈 **24ms**다. **"읽기에 묻힌다"는 근거는 성립하지 않는다** — 그렇게 짐작했다가
/// 재 보고 틀린 것을 확인했다(읽기의 8배다). 그대로 두는 근거는 **절대값이 작다**는 것뿐이다(한 번
/// 툭 끊기는 정도). 이 값이 커지면(더 큰 문서·느린 기기) 위의 "잠정 막대" 문제를 풀고 점진으로 간다.
///
/// **읽기 값은 하한이다** — 하니스가 방금 쓴 파일을 바로 읽어 OS 페이지 캐시가 따뜻하다. 콜드 읽기는
/// 권한 없이 잴 수 없다. 다만 그 값이 커져도 이 셈이 사라지지는 않는다.
fn ensureMaxCols(term: *Term, right: bool) void {
    const cache = if (right) &term.rt.editor_max_cols_right else &term.rt.editor_max_cols;
    if (cache.* != 0) return;
    const lines = if (right) rightTexts(term) else editorLines(term);
    if (lines.len == 0) return;

    // **렌더가 쓰는 그 값**(`editor_tab_width` — 단일 출처). 상수를 읽으면 필드가 기본값이 아닐 때
    // 가로 막대 상한이 화면과 갈린다: 실측으로 탭 폭 8인 문서에서 상한이 20열로 나왔고 실제 가장 긴
    // 줄은 28열이라 **8열(29%)이 모자랐다**(12차 적대적 검증).
    const tab_width = term.rt.editor_tab_width;
    const limit = chrome_editor.frame.max_cols_count_limit;
    var max: u32 = 0;
    for (lines) |line| {
        max = @max(max, chrome_editor.content.lineColumnsUpTo(line, tab_width, limit));
        if (max >= limit) break; // 더 세도 답이 같다
    }
    cache.* = max;
}

/// 접을 범위를 세어 Term에 둔다(이미 있으면 그대로). **명령과 여는 경로가 부른다** — 렌더는 할당하지
/// 않는다.
///
/// **"이미 있으면 그대로"는 문서가 안 바뀐다는 전제 위에 서 있다.** 지금은 참이다 — `editor_lines`를
/// 채우는 곳은 `openPathInActivePane` 하나이고 그것은 늘 **새 Term**을 만든다. N2에서 편집이 들어와
/// 줄 배열이 살아 있는 Term에서 바뀌면 이 캐시가 옛 문서의 범위를 가리키므로, **그 슬라이스가 여기서
/// 무효화 지점을 만들어야 한다**(§4.1f "범위 목록은 갱신 시점을 갖는다").
///
/// **넘긴 뒤에는 실패 지점이 없다.** 이 세션에서 같은 자리의 이중 해제를 세 번 잡았다
/// (native-editor-layering.md §2.0a) — 잡을 것을 **모두 잡은 뒤** 한꺼번에 넘긴다.
fn ensureFoldRanges(self: *AppSession, term: *Term) error{OutOfMemory}!void {
    if (term.rt.editor_fold_ranges.len > 0) return;
    const lines = foldSourceLines(term);
    if (lines.len == 0) return;

    const tab_width = term.rt.editor_tab_width; // 렌더와 같은 값(단일 출처)
    const n = editor_fold.countRanges(lines, tab_width);
    if (n == 0) return;

    const ranges = try self.allocator.alloc(editor_fold.Range, n);
    errdefer self.allocator.free(ranges);
    const folded = try self.allocator.alloc(u32, n); // 접기/펼치기가 다시 할당하지 않게 미리 잡는다
    errdefer self.allocator.free(folded);
    // 되돌리기용 백업도 지금 잡는다 — 되돌리는 자리에 실패 지점이 있으면 실패했을 때 갇힌다.
    const folded_prev = try self.allocator.alloc(u32, n);
    errdefer self.allocator.free(folded_prev);
    // 표식도 여기서 잡는다 — 보이는 줄은 문서 줄보다 많을 수 없으므로 이 크기로 늘 충분하다.
    const marks = try self.allocator.alloc(chrome_editor.gutter.Fold, lines.len);

    // 여기서부터 실패 지점이 없다 — 넘긴다.
    _ = editor_fold.compute(lines, tab_width, ranges);
    term.rt.editor_fold_ranges = ranges;
    term.rt.editor_folded_buf = folded;
    term.rt.editor_folded_prev = folded_prev;
    term.rt.editor_folded_len = 0;
    term.rt.editor_fold_marks = marks;
    term.rt.editor_fold_marks_len = 0;
}

/// **구문 층으로 승격한다**(§4 — *"grammar가 있으면 구문 기반 범위가 들여쓰기 추정을 덮는다"*).
///
/// **왜 여는 자리가 아닌가.** §4.1f 는 *"범위는 파일을 열 때 센다"* 고 정했는데, §2.1a 예산이 붙은
/// 뒤로는 **그 시점에 트리가 아직 없을 수 있다**(690KB 파일이 여섯 프레임에 나뉜다). 그래서 여는
/// 자리는 들여쓰기로 세우고, **파싱이 끝난 프레임에 이 함수가 덮는다** — 갱신 시점이 하나에서
/// 둘이 됐다.
///
/// **접어 둔 것은 푼다.** 승격하면 화살표가 서는 줄이 달라지므로 옛 머리 번호가 가리키는 곳이
/// 다른 범위가 된다. 파싱은 여는 직후에 끝나므로 그 사이에 접어 둔 것이 있을 확률은 낮고, 있어도
/// **틀린 곳이 접힌 채로 남는 것보다 펼쳐지는 편이 낫다**.
fn promoteFoldRangesToSyntax(self: *AppSession, term: *Term) void {
    const doc = term.rt.editor_doc orelse return;
    const st = &term.rt.editor_syntax;
    if (st.pending) return; // 아직 파는 중이다 — 다음 프레임에 다시 본다
    if (term.rt.editor_syntax_folds_applied) return;
    var prov = &(st.provider orelse return);
    if (prov.tree == null) return; // grammar 없음 — 들여쓰기 층이 그대로 산다(§5)

    const lines = foldSourceLines(term);
    if (lines.len == 0) return;

    // **범위는 화면에 그리는 줄과 같은 문서에서 나와야 한다.** 트리는 `doc.file.content` 를 판
    // 것이고 범위가 실리는 곳은 `foldSourceLines`(=`rt.editor_lines`)다. 제품에서 그 둘은 **같은
    // 배열**이지만, 갈린 상태에서 덮으면 엉뚱한 줄에 화살표가 서고 접으면 다른 줄이 사라진다.
    //
    // **줄 수만 보면 모자란다.** 우연히 같은 경우를 못 거른다(실측: 판정자 픽스처가 네 줄짜리
    // 배열을 주입하는데 문서도 네 줄이라 통과했고, 승격이 다른 문서의 범위를 덮었다).
    // 그래서 **첫 줄과 끝 줄의 내용**까지 본다 — O(1)이고 갈린 상태를 실제로 거른다.
    if (prov.lineCount() != lines.len) return;
    if (doc.file.lineCount() != lines.len) return;
    const first_doc = doc.file.lineText(0) orelse return;
    const last_doc = doc.file.lineText(lines.len - 1) orelse return;
    if (!std.mem.eql(u8, first_doc, lines[0])) return;
    if (!std.mem.eql(u8, last_doc, lines[lines.len - 1])) return;

    var spans: std.ArrayList(syntax_color.FoldSpan) = .empty;
    defer spans.deinit(self.allocator);
    prov.foldSpans(self.allocator, &spans);
    // **머리 한 줄짜리는 만들지 않는다**(§4.1f — 접어도 줄어드는 것이 없다). `foldSpans`가 두 줄
    // 이상만 내므로 여기서 다시 거를 것은 없지만, 그 계약이 갈리면 아래 변환이 빈 범위를 만든다.
    if (spans.items.len == 0) {
        term.rt.editor_syntax_folds_applied = true; // 접을 것이 없다 — 다시 세지 않는다
        return;
    }

    const n = spans.items.len;
    const ranges = self.allocator.alloc(editor_fold.Range, n) catch return;
    const folded = self.allocator.alloc(u32, n) catch {
        self.allocator.free(ranges);
        return;
    };
    const folded_prev = self.allocator.alloc(u32, n) catch {
        self.allocator.free(ranges);
        self.allocator.free(folded);
        return;
    };

    // **중첩 레벨은 담긴 순서로 센다.** 시작 줄 오름차순이므로, 아직 안 끝난 범위의 수가 곧 깊이다
    // (들여쓰기 층이 스택 깊이를 쓰는 것과 같은 정의 — §4의 `Range.level` 주석).
    var stack: [editor_fold.max_depth]u32 = undefined;
    var depth: usize = 0;
    for (spans.items, 0..) |sp, i| {
        while (depth > 0 and stack[depth - 1] < sp.start_row) depth -= 1;
        if (depth < stack.len) {
            stack[depth] = sp.end_row;
            depth += 1;
        }
        ranges[i] = .{
            .head = sp.start_row,
            .first_hidden = sp.start_row + 1,
            .last_hidden = sp.end_row,
            .level = @intCast(@min(depth, std.math.maxInt(u16))),
        };
    }

    // 여기서부터 실패 지점이 없다 — 옛 것을 놓고 새 것을 건다.
    if (term.rt.editor_fold_ranges.len > 0) self.allocator.free(term.rt.editor_fold_ranges);
    if (term.rt.editor_folded_buf.len > 0) self.allocator.free(term.rt.editor_folded_buf);
    if (term.rt.editor_folded_prev.len > 0) self.allocator.free(term.rt.editor_folded_prev);
    term.rt.editor_fold_ranges = ranges;
    term.rt.editor_folded_buf = folded;
    term.rt.editor_folded_prev = folded_prev;
    term.rt.editor_folded_len = 0; // 접어 둔 것은 푼다(위 주석)
    term.rt.editor_syntax_folds_applied = true;

    // **보이는 줄 표를 다시 만든다.** 위에서 접어 둔 것을 풀었으므로 `rebuildVisible` 의 불변식
    // (「접힌 것이 없으면 보이는 줄 배열은 비어 있다」 = 원본을 그대로 그리라는 표시)이 지금
    // 깨져 있다 — 그 배열은 **접힌 상태로 만든 부분집합**이다.
    //
    // **그것이 사용자 제보 결함이었다**(2026-08-30 — 「커서 위치와 실제 입력 위치가 다르다」).
    // 파싱이 끝나기 전에 접으면(큰 문서는 예산 파싱이 여러 프레임 걸린다 — §2.1a) 본문은 부분집합을
    // 그리는데 접힘 상태는 「없음」이라 화면의 행과 문서의 줄이 어긋난다. 입력은 문서 offset 을,
    // 커서는 시각 행을 쓰므로 그 어긋남이 곧 그 증상이다. `ES32` 가 그 순서를 그대로 잰다.
    rebuildVisible(self, term) catch {
        // 못 만들면 **부분집합을 그대로 두지 않는다** — 틀린 표보다 없는 편이 낫다(`rebuildVisible`
        // 자신이 실패 갈래에서 같은 판단을 한다).
        if (term.rt.editor_visible_lines.len > 0) self.allocator.free(term.rt.editor_visible_lines);
        if (term.rt.editor_visible_numbers.len > 0) self.allocator.free(term.rt.editor_visible_numbers);
        term.rt.editor_visible_lines = &.{};
        term.rt.editor_visible_numbers = &.{};
        invalidateFoldDerived(self, term);
    };
    self.metal_dirty = true;
}

/// 접을 수 있는 것을 **전부 접는다**(§4 — *"큰 파일에서 하나씩 접는 것은 쓸모가 없다"*).
/// 편집기가 아니거나 접을 것이 없으면 `false`.
pub fn foldAll(self: *AppSession) bool {
    return applyFold(self, null);
}

/// **그 중첩 레벨의 블록만 접는다**(VSCode `editor.foldLevelN`). 레벨 1이 문서 맨 바깥이다.
///
/// **집합을 합치지 않고 갈아 끼운다.** VSCode는 기존 접힘 위에 더하지만 Vim `foldlevel`은 그 레벨에
/// 맞춰 열고 닫는다 — 두 선례가 갈리는 자리다. 갈아 끼우는 쪽이 (a) 같은 명령을 두 번 눌러도
/// 결과가 같고 (b) 레벨 2를 본 뒤 레벨 1을 누르면 더 크게 접히는 예측 가능한 사다리가 된다.
/// 합치기를 택하면 되돌릴 방법이 전체 펼치기뿐이라 사다리를 내려올 수 없다.
///
/// **초판은 근거를 하나 더 적었다** — *"N1에는 개별 접기가 없어 접힘 상태가 늘 「전체 · 어느 레벨 ·
/// 없음」 중 하나"*. 화살표 클릭(`toggleFoldAtPoint`)이 붙으면서 그 전제는 사라졌고, 이제 집합은
/// 임의의 모양일 수 있다. 그래도 **결론은 그대로다**: 위 (a)·(b)가 개별 접기와 무관하게 서고,
/// 손으로 접은 것을 레벨 명령이 갈아 끼워도 화살표로 다시 접을 수 있다(잃는 것은 한 번의 클릭이지,
/// 되돌릴 길 자체가 아니다).
///
/// 그 레벨에 블록이 없으면 **아무 일도 안 한다**(`false`) — 갈아 끼우는 모델에서 빈 집합을 넣으면
/// "접기 명령을 눌렀는데 펼쳐지는" 화면이 된다.
pub fn foldLevel(self: *AppSession, level: u16) bool {
    return applyFold(self, level);
}

/// 접힘 집합을 바꾸는 **유일한 경로**. `level`이 `null`이면 전부, 아니면 그 레벨만 접는다.
///
/// **실패하면 있던 집합으로 되돌린다 — 비우는 것이 아니다.** 이미 접힌 채로 다시 접다 실패하면
/// 화면은 접힌 그대로인데 상태만 "안 접힘"이 된다. 그러면 `unfoldAll`이 `folded_len == 0`을 보고
/// 거절해 **숨은 줄을 영영 못 되찾는다**(할당 실패 주입으로 실측: 문서 4줄인데 화면 2줄, 펼치기
/// 불가. 적대적 검증 2026-08-17). 레벨 접기가 들어오면서 **길이만으로는 되돌릴 수 없어**
/// (같은 길이라도 다른 머리들이다) 백업 배열을 함께 든다.
fn applyFold(self: *AppSession, level: ?u16) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    if (foldsUnavailable(term)) return false; // 아래 doc — diff 상태에서는 접지 않는다
    ensureFoldRanges(self, term) catch return false; // 못 세면 아무 일도 안 한다
    const ranges = term.rt.editor_fold_ranges;
    if (ranges.len == 0) return false;

    const prev_len = term.rt.editor_folded_len;
    @memcpy(term.rt.editor_folded_prev[0..prev_len], term.rt.editor_folded_buf[0..prev_len]);

    // `hiddenSpans`가 **오름차순**을 계약으로 요구한다. `compute`가 문서 순서로 내므로 걸러도
    // 순서가 유지된다.
    var n: usize = 0;
    for (ranges) |r| {
        if (level) |want| if (r.level != want) continue;
        term.rt.editor_folded_buf[n] = r.head;
        n += 1;
    }
    if (n == 0) return false; // 그 레벨에 블록이 없다 — 위 doc

    term.rt.editor_folded_len = n;
    const anchor = topDocLine(term); // 화면을 다시 만들기 **전에** 맨 위가 문서 몇째 줄인지 잡는다
    rebuildVisible(self, term) catch {
        @memcpy(term.rt.editor_folded_buf[0..prev_len], term.rt.editor_folded_prev[0..prev_len]);
        term.rt.editor_folded_len = prev_len; // 화면이 그대로니 상태도 그대로 둔다
        return false;
    };
    restoreTop(term, anchor);
    self.metal_dirty = true;
    return true;
}

/// gutter **접기 화살표를 눌렀는가** — 눌렀으면 그 블록 하나를 뒤집고 `true`(§4.1f 포인터 경로).
///
/// **§4.1f는 이것을 "안 한다"고 적었고 그 근거는 *"N1은 편집기 pane에 포인터 경로가 없다"*였다.**
/// 그 전제가 §4.1g(본문 hit-test·텍스트 선택, 2026-08-19~20)에서 사라졌다 — 결정표가 그때
/// *"화살표 클릭이 붙으면 그쪽이 먼저 가져간다"*고 자리를 예약해 두었고, 이 함수가 그 자리다.
/// 계약을 바꾼 것이 아니라 **막고 있던 조건이 없어진 것**이다.
///
/// 명령(전체·레벨 접기)과 **같은 상태**를 건드린다. 화살표는 그 상태의 다른 입구일 뿐이고, 그래서
/// 화살표로 접은 뒤 `Unfold All`이 그것을 편다.
///
/// 대상 Term은 **눌린 pane**의 것이다(활성 pane이 아니다) — split에서 다른 열의 화살표를 눌러도 그
/// 문서가 접혀야 하고, 스크롤바 드래그가 같은 규율을 쓴다.
pub fn toggleFoldAtPoint(self: *AppSession, pane: *Pane, x_px: f64, y_px: f64) bool {
    const term = pane.activeTerm();
    if (term.kind != .editor) return false;
    if (foldsUnavailable(term)) return false; // 비교 뷰 등 — 접힘 자체가 성립하지 않는다
    const line = hitTestFoldMark(term, x_px, y_px) orelse return false;
    // 범위는 파일을 열 때 세지만(§4.1f), 그때 실패했을 수 있으므로 여기서도 한 번 확인한다.
    ensureFoldRanges(self, term) catch return false;
    // **화살표가 없는 줄의 접기 칸은 아무도 안 가져간다.** 여기서 `true`를 주면 빈 칸을 눌러도
    // 클릭이 소비되어 pane 포커스 이동이 안 일어난다 — 보이는 것이 없는데 반응만 사라진다.
    if (!containsSorted(term.rt.editor_fold_ranges, line)) return false;
    return toggleFoldHead(self, term, line);
}

/// 머리 줄 하나의 접힘을 뒤집는다. **집합은 오름차순을 유지한다** — `hiddenSpans`가 그것을 계약으로
/// 요구한다(전체·레벨 접기는 `compute` 순서를 그대로 걸러 담아 공짜로 만족하지만, 하나씩 넣고 빼는
/// 이 경로는 스스로 지켜야 한다).
///
/// **실패하면 있던 집합으로 되돌린다** — `applyFold`와 같은 이유이고 같은 백업 배열을 쓴다. 화면은
/// 그대로인데 상태만 달라지면 `unfoldAll`이 거절해 숨은 줄을 못 되찾는다.
fn toggleFoldHead(self: *AppSession, term: *Term, head: u32) bool {
    const prev_len = term.rt.editor_folded_len;
    const buf = term.rt.editor_folded_buf;
    @memcpy(term.rt.editor_folded_prev[0..prev_len], buf[0..prev_len]);

    if (std.sort.binarySearch(u32, buf[0..prev_len], head, orderU32)) |i| {
        // 접혀 있다 → 편다. 뒤를 당겨 순서를 지킨다.
        std.mem.copyForwards(u32, buf[i .. prev_len - 1], buf[i + 1 .. prev_len]);
        term.rt.editor_folded_len = prev_len - 1;
    } else {
        // **저장소는 범위 수만큼 잡혀 있다**(`ensureFoldRanges`)이고 머리는 범위마다 하나뿐이라
        // 넘칠 수 없다. 그래도 묶는다 — 넘치면 남의 메모리를 쓰는 것이라 조용한 실패가 최악이다.
        if (prev_len >= buf.len) return false;
        const at = std.sort.lowerBound(u32, buf[0..prev_len], head, orderU32);
        std.mem.copyBackwards(u32, buf[at + 1 .. prev_len + 1], buf[at..prev_len]);
        buf[at] = head;
        term.rt.editor_folded_len = prev_len + 1;
    }

    const anchor = topDocLine(term); // 화면을 다시 만들기 **전에** 맨 위가 문서 몇째 줄인지 잡는다
    rebuildVisible(self, term) catch {
        @memcpy(buf[0..prev_len], term.rt.editor_folded_prev[0..prev_len]);
        term.rt.editor_folded_len = prev_len;
        return false;
    };
    restoreTop(term, anchor);
    self.metal_dirty = true;
    return true;
}

/// 전부 펼친다.
pub fn unfoldAll(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    if (foldsUnavailable(term)) return false;
    if (term.rt.editor_folded_len == 0) return false;
    const anchor = topDocLine(term);
    term.rt.editor_folded_len = 0;
    rebuildVisible(self, term) catch {}; // 펼치기는 배열을 푸는 쪽이라 실패할 것이 없다
    restoreTop(term, anchor);
    self.metal_dirty = true;
    return true;
}

/// 접힘을 화면에 반영한다 — **보이는 줄만 모은 배열**과 그 원래 번호를 다시 만든다.
///
/// **렌더는 이 배열을 그냥 그린다.** diff가 filler 행에 쓰는 것과 같은 모양이라 프레임이 접힘을 몰라도
/// 된다(§4.1f). 접힘이 바뀔 때만 돌고 프레임마다는 안 돈다.
fn rebuildVisible(self: *AppSession, term: *Term) error{OutOfMemory}!void {
    const lines = foldSourceLines(term);
    const heads = foldedHeads(term);
    if (heads.len == 0) {
        // 접힌 것이 없다 — 줄 배열은 원본을 그대로 그린다(만들 이유가 없다). **표식은 만든다** —
        // 펼쳐진 머리에도 화살표가 서야 접을 수 있는 자리가 보인다(Vim `foldcolumn`이 여는 fold에
        // `-`를 그리는 것과 같다).
        const marks = term.rt.editor_fold_marks[0..@min(term.rt.editor_fold_marks.len, lines.len)];
        for (marks, 0..) |*m, i| m.* = markFor(term, @intCast(i));
        term.rt.editor_fold_marks_len = marks.len;

        if (term.rt.editor_visible_lines.len > 0) self.allocator.free(term.rt.editor_visible_lines);
        if (term.rt.editor_visible_numbers.len > 0) self.allocator.free(term.rt.editor_visible_numbers);
        term.rt.editor_visible_lines = &.{};
        term.rt.editor_visible_numbers = &.{};
        invalidateFoldDerived(self, term);
        return;
    }

    // **구간 저장소를 잡는다 — 고정 배열이면 큰 파일에서 조용히 덜 접힌다.** 초판은 스택에 4,096개를
    // 두었는데, 12만 줄(4만 블록) 문서에서 **앞 4,096블록만 접혔다**(전체의 3%. 실측 111,808줄이 남았고
    // 4만 줄이어야 했다 — 적대적 검증 2026-08-17). 구간 수는 범위 수를 넘지 않는다.
    const span_buf = try self.allocator.alloc(editor_fold.Span, term.rt.editor_fold_ranges.len);
    defer self.allocator.free(span_buf);
    const spans = editor_fold.hiddenSpans(term.rt.editor_fold_ranges, heads, span_buf);

    // **줄마다 구간을 훑지 않는다.** 둘 다 문서 순서이므로 커서 하나로 나란히 간다 — 초판은
    // `isHidden`을 줄마다 불러 O(줄 × 구간)이었고, 실측 1,000블록 5ms · 2,000 15ms · **4,000 57ms**
    // (두 배마다 4배)였다. 4만 줄이면 전체 접기에 1.4초다(적대적 검증 2026-08-17).
    var hidden_total: usize = 0;
    for (spans) |sp| hidden_total += sp.last - sp.first + 1;
    const visible = lines.len -| hidden_total;

    const out_lines = try self.allocator.alloc([]const u8, visible);
    errdefer self.allocator.free(out_lines);
    const out_numbers = try self.allocator.alloc(?u32, visible);
    const out_marks = term.rt.editor_fold_marks[0..@min(term.rt.editor_fold_marks.len, visible)];

    var k: usize = 0;
    var si: usize = 0;
    for (lines, 0..) |line, i| {
        while (si < spans.len and spans[si].last < i) si += 1;
        if (si < spans.len and i >= spans[si].first) continue; // 숨는 줄
        if (k >= out_lines.len) break; // 방어 — 구간 합과 어긋나도 넘치지 않는다(아래에서 꼬리를 채운다)
        out_lines[k] = line;
        out_numbers[k] = @intCast(i + 1); // gutter는 1-based다
        if (k < out_marks.len) out_marks[k] = markFor(term, @intCast(i));
        k += 1;
    }

    // 여기서부터 실패 지점이 없다 — 옛 것을 풀고 넘긴다(§2.0a commit-last).
    if (term.rt.editor_visible_lines.len > 0) self.allocator.free(term.rt.editor_visible_lines);
    if (term.rt.editor_visible_numbers.len > 0) self.allocator.free(term.rt.editor_visible_numbers);
    // **잘라서 넘기면 안 된다** — `free`는 잡을 때의 길이를 요구하므로 부분 슬라이스를 넘기면 해제가
    // 어긋난다. 구간 합과 실제가 어긋나는 경우(상태와 범위가 잠시 갈릴 때)에만 꼬리가 남는데,
    // 빈 줄·번호 없음으로 채워 배열을 온전히 유지한다.
    while (k < out_lines.len) : (k += 1) {
        out_lines[k] = "";
        out_numbers[k] = null;
        if (k < out_marks.len) out_marks[k] = .none;
    }
    term.rt.editor_fold_marks_len = out_marks.len;
    term.rt.editor_visible_lines = out_lines;
    term.rt.editor_visible_numbers = out_numbers;
    invalidateFoldDerived(self, term);
}

/// 탭 폭을 바꾸는 **단일 지점**. 필드에 직접 대입하지 말고 여기를 부른다.
///
/// **탭 폭은 파생값을 셋 낡게 만든다.** 12차가 `ensureMaxCols`·`piecesOfLine`·`ensureFoldRanges`가
/// 상수를 읽는 것을 잡아 필드 추종으로 바꿨는데, 그것만으로는 **절반이었다**(13차): 둘은 `if (캐시가
/// 있으면) return`이라 탭 폭이 바뀌어도 옛 값이 그대로 남는다. 실측으로 같은 8열(28.6%) 부족이
/// 재현됐다 — 상수 경로만 막고 낡음 경로를 안 막았다.
///
/// | 파생값 | 탭 폭에 따라 갈리는가 | 무엇이 지키는가 |
/// |---|---|---|
/// | `editor_max_cols`·`_right` | 그렇다(탭 8에서 20 → 28열) | **이 함수** — `if (cache.* != 0) return` |
/// | `editor_fold_ranges` | **섞인 들여쓰기에서만** 그렇다 | **이 함수** — `if (len > 0) return` |
/// | `RowCache` 접두합 | 그렇다 | `frame.RowCache.hits()`가 `tab_width`를 키에 넣는다(스스로 지킨다) |
///
/// 접힘이 갈리는 조건은 좁다. 겹수는 탭 폭에 대해 **단조 스케일**이라 순수 탭·순수 스페이스 문서는
/// 4↔8에서 층 순서가 안 바뀐다 — 갈리는 것은 **탭과 스페이스가 섞인** 줄뿐이다(14차 실측: 문서 6개
/// 중 1개. 초판이 "6개 중 4개"라 적었는데 근거가 없었다). 그래도 버려야 한다: 좁은 조건이 안 나는
/// 조건은 아니고, ADV3-I가 그 조건을 만들어 잰다.
///
/// `editor_hit_geom.tab_width`는 여기서 안 건드린다 — 그것은 **렌더가 굳히는 스냅숏**이고, 다음
/// 프레임이 통째로 덮는다(§4.1g "스냅숏의 경계").
/// **같은 값으로 불러도 무효화한다.** 초판은 `if (같으면) return`으로 건너뛰었는데, 그러면 누가
/// 필드에 **직접 대입한 뒤** 이 함수를 부를 때 무효화가 안 된다 — 그것이 정확히 이 함수가 막으려는
/// 상태다. ADV3-I가 그 조합에서 바로 걸렸다(옛 상한 27이 남아 19를 기대한 단언이 깨졌다). 탭 폭
/// 변경은 드문 이벤트라 그 최적화는 값이 없고, 값이 있어도 낡음과 바꿀 것이 아니다.
pub fn setEditorTabWidth(self: *AppSession, term: *Term, tab_width: u8) void {
    // **접힘을 푸는 세 번째 경로다** — `applyFold`·`unfoldAll`과 같은 계약을 져야 한다.
    //
    // ⑴ **앵커부터 잡는다.** `editor_first_line`은 접힌 배열의 첨자이고, 배열이 사라지면 그대로 문서
    //    줄 번호로 재해석된다. 실측으로 900줄 문서에서 뷰포트가 **300줄 튀었다**(15차 적대적 검증) —
    //    `restoreTop` doc이 *"3만 줄 문서의 9,001번 줄을 보다가 전체 접기를 하면 1번 줄로 튀었다"*고
    //    못 박은 그 사고와 같은 것이다.
    const anchor = topDocLine(term);
    term.rt.editor_tab_width = tab_width;

    // ⓪ **접을 수 없는 상태면 접힘 층을 건드리지 않는다** — `applyFold`·`unfoldAll`이 지키는 계약
    //    셋 중 첫째다(초판은 둘만 졌다). 비교 뷰에서는 `foldSourceLines`가 비어 **다시 셀 수 없으므로**,
    //    지우면 돌아올 길이 없다: 실측으로 `marks=true ranges=8`이 `marks=false ranges=0`이 되고
    //    **비교를 꺼도 그대로**였다(16차 적대적 검증). 파생 캐시만 버리고 나간다.
    if (foldsUnavailable(term)) {
        invalidateFoldDerived(self, term);
        return;
    }

    dropFoldState(self, term);
    invalidateFoldDerived(self, term); // `max_cols`·가로 위치·세로 상한·행 수 캐시가 여기서 죽는다

    // ⑵ **접힘 층을 다시 세운다.** 안 세우면 gutter 화살표가 통째로 사라지고 **스스로 안 돌아온다** —
    //    `ensureFoldRanges` doc이 *"렌더는 할당하지 않는다"*라 다음 프레임이 복구하지 않고, 다음 접기
    //    명령까지 접을 수 있는 자리가 화면에서 사라진다(`finishAttach`가 여는 시점에 이 쌍을 부르는
    //    이유와 같다). 실측: 세터 뒤 `marks = 0`이고 `foldMarks(term) == null`이었다(15차).
    //
    //    **접힌 상태는 되살리지 않는다.** 탭 폭이 바뀌면 범위 자체가 달라져 "어느 범위가 접혀 있었나"가
    //    대응되지 않는다. 그래서 `unfoldAll`과 같은 결과(전부 펼침)로 가고, 보던 줄만 지킨다.
    ensureFoldRanges(self, term) catch {}; // 못 잡으면 접힘 없이 간다 — 다음 접기 명령이 다시 시도한다
    // `rebuildVisible`은 여기서 **반드시** `heads.len == 0` 갈래를 탄다(`dropFoldState`가
    // `folded_len`을 0으로 세웠다). 그 갈래는 할당이 없어 실패하지 않고, 끝에서
    // `invalidateFoldDerived`를 **다시 부른다** — 그래서 위 호출은 이 경로에서 죽은 줄이 아니라
    // **비교 뷰 조기 반환을 위해** 남아 있다(16차가 그것을 죽은 줄로 지목했고, ⓪을 세우면서 몫이 생겼다).
    rebuildVisible(self, term) catch {};
    restoreTop(term, anchor);
}

/// 접힘 상태를 **통째로** 놓는다 — `ensureFoldRanges`가 한 단위로 잡는 **넷**(`fold_ranges`·
/// `folded_buf`·`folded_prev`·`fold_marks`)과 `rebuildVisible`이 잡는 **둘**(`visible_lines`·
/// `visible_numbers`), 합쳐 여섯이다.
///
/// **여섯이 늘 한 단위인 것은 아니다.** `rebuildVisible`은 뒤의 둘만 따로 놓고 다시 잡는다(접을
/// 때마다 그 배열이 바뀌므로) — 그것은 정상이다. 여기서 여섯을 함께 놓는 이유는 **접힘 층 자체를
/// 버리기 때문**이다: 앞의 넷이 사라지면 뒤의 둘은 가리킬 곳이 없다.
///
/// **하나만 놓으면 셋이 고아가 된다.** 초판은 `editor_fold_ranges`만 free했는데, `ensureFoldRanges`가
/// 다시 통과하면서 `editor_folded_buf`·`editor_folded_prev`·`editor_fold_marks`의 포인터를 덮어써
/// **호출마다 세 할당이 샜다**(14차 적대적 검증 실측: 세터 3회 호출에 6 leaked, 테스트 명령이 단언은
/// 전부 통과하는데도 exit 1). 그 함수의 doc이 *"잡을 것을 모두 잡은 뒤 한꺼번에 넘긴다"*고 넷을 한
/// 단위로 선언했으므로, 놓는 쪽도 한 단위여야 한다.
///
/// **접힌 상태도 함께 편다.** 안 펴면 `editor_folded_len`·`editor_visible_lines`가 옛 범위를 가리킨
/// 채 남고, 다음 `ensureFoldRanges`가 `folded_len`을 0으로 만들면 `unfoldAll`이 `folded_len == 0`을
/// 보고 **거절해 숨은 줄을 영영 못 되찾는다**(`applyFold` doc이 2026-08-17에 막은 그 상태다 —
/// 14차 실측: 8줄 문서에서 5줄이 숨은 채 `unfoldAll = false`).
/// undo 스택 한 항목. **역연산과 그때의 커서를 함께 든다**(§3.3).
///
/// `Inverse`가 할당을 소유하므로 이 항목을 버릴 때는 **반드시 `deinit`** 한다 — 스택을 자르는
/// 자리가 넷이라(새 편집이 redo를 버릴 때·상한을 넘을 때·Term이 죽을 때·문서를 다시 열 때)
/// 한 곳만 빠뜨려도 샌다.
pub const UndoEntry = struct {
    inverse: maru.session.editor.delta.Inverse,
    /// **편집 전** 커서들(문서 순서). §3.3: *"undo/redo는 텍스트뿐 아니라 그 시점의 selection
    /// 배열 전체와 primary 인덱스를 되돌린다."*
    sels_before: []editor_selection.Selection,
    primary_before: usize,
    /// 묶음 번호. **같은 번호는 한 번의 undo로 함께 돌아간다.**
    group: u32,

    pub fn deinit(self: *UndoEntry, allocator: std.mem.Allocator) void {
        self.inverse.deinit();
        allocator.free(self.sels_before);
        self.* = undefined;
    }
};

/// 마지막 편집의 종류. 종류가 바뀌면 묶음을 끊는다(§3.3).
pub const EditKind = enum { none, insert, delete };

/// 연속 타이핑으로 볼 시간 간격(ms). 이보다 벌어지면 묶음을 끊는다.
///
/// **재서 정한 값이 아니라 관례다** — VSCode·CM6가 비슷한 자리에 500ms 안팎을 쓴다. §10의
/// 임계값 규율대로 사용자가 불편을 말하면 그때 고친다.
const undo_group_gap_ms: u64 = 500;

/// undo 스택 상한(항목 수). 넘으면 **가장 오래된 것부터** 버린다.
///
/// 무제한으로 두면 긴 세션에서 메모리가 누적된다 — §3.3이 delta를 고른 이유가 그것인데, 스택
/// 자체에 상한이 없으면 같은 문제가 한 층 위에서 돌아온다.
const undo_stack_limit: usize = 2048;

/// **묶음을 끊는다** — 커서가 편집 아닌 이유로 움직였을 때 호출한다(클릭·다음 일치 추가).
///
/// 안 끊으면 "클릭해서 다른 곳에 커서를 두고 친 글자"가 앞의 타이핑과 한 묶음이 되어 undo 한 번에
/// 둘 다 사라진다 — 사용자가 예측할 수 없다.
pub fn breakUndoGroup(term: *Term) void {
    term.rt.editor_last_edit_kind = .none;
    // **자동 닫기 표시도 여기서 버린다**(§3.7 — "그 표시는 그 caret이 떠나면 버린다").
    //
    // 이 함수는 *"커서가 편집 아닌 이유로 움직였다"*의 단일 자리다(클릭·⌘⌃D·이동 일습·붙여넣기).
    // 표시를 따로 버리는 함수를 두면 **그 둘이 갈리는 경로가 반드시 생긴다** — 실제로 따로 두려다
    // 호출부를 하나씩 세다가 그만뒀다.
    term.rt.editor_auto_closed_at = null;
}

/// 이번 편집이 앞의 것과 같은 묶음인가.
fn sameUndoGroup(term: *Term, kind: EditKind, now_ms: u64) bool {
    if (term.rt.editor_last_edit_kind != kind) return false;
    if (kind == .none) return false;
    return now_ms -| term.rt.editor_last_edit_ms <= undo_group_gap_ms;
}

/// 편집 하나를 undo 스택에 쌓는다. **`inverse`의 소유가 여기로 넘어온다.**
fn pushUndo(
    self: *AppSession,
    term: *Term,
    inverse: maru.session.editor.delta.Inverse,
    sels_before: []editor_selection.Selection,
    primary_before: usize,
    kind: EditKind,
) void {
    var owned_inverse = inverse;
    const now_ms = self.awakeMs();
    if (!sameUndoGroup(term, kind, now_ms)) term.rt.editor_edit_group +%= 1;
    term.rt.editor_last_edit_kind = kind;
    term.rt.editor_last_edit_ms = now_ms;

    // **새 편집은 redo를 버린다**(§3.3).
    dropRedo(self, term);

    const entry: UndoEntry = .{
        .inverse = owned_inverse,
        .sels_before = sels_before,
        .primary_before = primary_before,
        .group = term.rt.editor_edit_group,
    };
    if (!pushEntry(self, &term.rt.editor_undo, &term.rt.editor_undo_len, entry)) {
        // 못 쌓으면 **되돌릴 수 없는 편집**이 된다. 그래도 편집 자체는 성사시킨다 —
        // 여기서 편집을 취소하면 할당 실패 하나가 타이핑을 먹는다.
        var e = entry;
        e.deinit(self.allocator);
        owned_inverse = undefined;
    }
}

fn pushEntry(self: *AppSession, stack: *[]UndoEntry, len: *usize, entry: UndoEntry) bool {
    if (len.* == stack.len) {
        const next_cap = if (stack.len == 0) 16 else stack.len * 2;
        const grown = self.allocator.realloc(stack.*, next_cap) catch return false;
        stack.* = grown;
    }
    stack.*[len.*] = entry;
    len.* += 1;

    // 상한을 넘으면 **가장 오래된 것부터** 버린다.
    if (len.* > undo_stack_limit) {
        const drop = len.* - undo_stack_limit;
        for (stack.*[0..drop]) |*e| e.deinit(self.allocator);
        std.mem.copyForwards(UndoEntry, stack.*[0 .. len.* - drop], stack.*[drop..len.*]);
        len.* -= drop;
    }
    return true;
}

fn dropRedo(self: *AppSession, term: *Term) void {
    for (term.rt.editor_redo[0..term.rt.editor_redo_len]) |*e| e.deinit(self.allocator);
    term.rt.editor_redo_len = 0;
}

/// undo·redo 스택을 통째로 놓는다(Term이 죽거나 문서를 다시 열 때).
pub fn dropUndoState(self: *AppSession, term: *Term) void {
    for (term.rt.editor_undo[0..term.rt.editor_undo_len]) |*e| e.deinit(self.allocator);
    for (term.rt.editor_redo[0..term.rt.editor_redo_len]) |*e| e.deinit(self.allocator);
    if (term.rt.editor_undo.len > 0) self.allocator.free(term.rt.editor_undo);
    if (term.rt.editor_redo.len > 0) self.allocator.free(term.rt.editor_redo);
    term.rt.editor_undo = &.{};
    term.rt.editor_redo = &.{};
    term.rt.editor_undo_len = 0;
    term.rt.editor_redo_len = 0;
    term.rt.editor_last_edit_kind = .none;
}

/// **되돌린다**(§3.3). 같은 묶음은 함께 돌아간다.
pub fn undoEdit(self: *AppSession, term: *Term) bool {
    return stepHistory(self, term, true);
}

/// **다시 한다**(§3.3).
pub fn redoEdit(self: *AppSession, term: *Term) bool {
    return stepHistory(self, term, false);
}

fn stepHistory(self: *AppSession, term: *Term, is_undo: bool) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false;
    if (term.rt.editor_doc == null) return false;

    const from_len = if (is_undo) &term.rt.editor_undo_len else &term.rt.editor_redo_len;
    if (from_len.* == 0) return false;
    const from = if (is_undo) &term.rt.editor_undo else &term.rt.editor_redo;
    const to = if (is_undo) &term.rt.editor_redo else &term.rt.editor_undo;
    const to_len = if (is_undo) &term.rt.editor_redo_len else &term.rt.editor_undo_len;

    const group = from.*[from_len.* - 1].group;
    var restored: ?struct { items: []editor_selection.Selection, primary: usize } = null;
    var did_any = false;

    // **같은 묶음을 연속으로 꺼낸다** — 그것이 "연속 타이핑은 undo 하나"의 구현이다.
    while (from_len.* > 0 and from.*[from_len.* - 1].group == group) {
        from_len.* -= 1;
        var entry = from.*[from_len.*];

        // 되돌릴 때도 selection을 함께 민다 — `apply`가 그 계약이다.
        var sels = selectionsForEdit(self, term) orelse {
            entry.deinit(self.allocator);
            continue;
        };
        const back = term.rt.editor_doc.?.file.apply(entry.inverse.delta(), &sels) catch {
            self.allocator.free(sels.items);
            entry.deinit(self.allocator);
            continue;
        };
        self.allocator.free(sels.items);
        did_any = true;

        // 반대편 스택에 **같은 묶음 번호로** 쌓는다 — redo도 한 번에 돌아간다.
        // 그때의 "편집 전 커서"는 지금 항목이 든 것이다.
        if (restored) |r| self.allocator.free(r.items);
        restored = .{ .items = entry.sels_before, .primary = entry.primary_before };

        const mirror: UndoEntry = .{
            .inverse = back,
            .sels_before = self.allocator.dupe(editor_selection.Selection, entry.sels_before) catch &.{},
            .primary_before = entry.primary_before,
            .group = group,
        };
        if (!pushEntry(self, to, to_len, mirror)) {
            var m = mirror;
            m.deinit(self.allocator);
        }
        entry.inverse.deinit(); // `sels_before`는 위에서 `restored`가 가져갔다
    }

    if (!did_any) {
        if (restored) |r| self.allocator.free(r.items);
        return false;
    }

    // **커서를 그때로 돌린다**(§3.3). 열 선택 원본은 되살리지 않는다 — 진행 중인 제스처이지
    // 문서 상태가 아니다.
    if (restored) |r| {
        defer self.allocator.free(r.items);
        if (r.items.len > 0) {
            term.rt.editor_selection = r.items[@min(r.primary, r.items.len - 1)];
            clearExtraSelections(self, term);
            if (r.items.len > 1) {
                // **`catch &.{}`로 적으면 안 된다** — 빈 슬라이스 리터럴이 `[]const`라 타입이
                // 그쪽으로 굳고 아래 채우기가 "상수에 대입"이 된다. 실패는 옵셔널로 받는다.
                if (self.allocator.alloc(editor_selection.Selection, r.items.len - 1)) |extras| {
                    var k: usize = 0;
                    for (r.items, 0..) |sel, i| {
                        if (i == r.primary) continue;
                        extras[k] = sel;
                        k += 1;
                    }
                    term.rt.editor_extra_selections = extras;
                } else |_| {
                    // 나머지 커서를 못 되살렸다 — primary 하나로 간다. 되돌리기 자체는 성사됐다.
                }
            }
        }
    }
    breakUndoGroup(term); // 되돌린 뒤 친 글자는 새 묶음이다
    // **undo·redo는 범위를 안 넘긴다 — 전체를 다시 판다.** 한 번에 항목 여럿을
    // 되돌리는데 각 적용이 그 뒤 offset을 밀어, 범위를 합치면 어긋난 통지가 된다.
    refreshAfterEdit(self, term, null) catch {};
    return true;
}

/// **편집기 문서를 디스크에 쓴다**(§3.5 — 원문을 바꾸지 않는다).
///
/// **쓰기 자체는 파일 패널 경로를 그대로 쓴다**(`writePinnedFilePanel`). 그쪽은 부모 디렉터리를
/// 핀하고 temp↔leaf를 `RENAME_SWAP` 한 뒤 **양쪽 inode가 예상한 것인지 검증**하며, 검사 뒤 leaf가
/// 교체됐으면 swap을 되돌려 경쟁 파일을 보존한다. 편집기가 그 경로를 다시 짜면 그 방어가 두 벌이
/// 되고, 둘 중 하나만 고쳐지는 날이 온다.
///
/// **쓸 bytes는 L2가 만든다**(`saveBytes`) — BOM·끝 개행을 연 그대로 되돌리는 규칙이 그쪽에 있다.
///
/// **저장 뒤 문서를 다시 읽지 않는다.** 방금 쓴 것이 곧 문서이고, 다시 읽으면 그 사이 외부 변경을
/// 조용히 삼킨다(§3.6의 외부 편집 감지는 별도 계약이다).
/// 저장하지 않은 편집이 있는가. **편집기 Term이 아니면 false** — 호출자가 kind를 따로 안 봐도 된다.
pub fn isDirty(term: *const Term) bool {
    if (term.kind != .editor) return false;
    // **비교 뷰는 읽기 전용 결과라 저장할 축이 없다**(§7). 같은 Term이 문서를 든 채 비교로
    // 전환되므로, 이 갈래가 없으면 **비교 탭에 저장 표식이 뜨고** 닫기 게이트도 열린다 —
    // 사용자는 "이 비교를 저장해야 하나?"로 읽는다(적대적 검증 2026-08-26).
    // `editorMeta`는 같은 갈래를 이미 갖고 있었는데 여기만 빠져 있었다.
    if (term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    return doc.isDirty();
}

pub fn saveDocument(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    const path = term.rt.editor_path orelse return false;

    const bytes = doc.file.saveBytes(self.allocator) catch return false;
    // **쓴 내용이 무엇이었는지** 기억해 둔다 — 아래에서 clean 판정에 쓴다.
    const saved_content = doc.file.content;
    defer self.allocator.free(bytes);

    var pinned = file_panel_ops.openPinnedFilePanelParent(self.io, path) catch return false;
    defer pinned.dir.close(self.io);

    var original = pinned.dir.openFile(self.io, pinned.basename, .{ .mode = .read_only }) catch return false;
    defer original.close(self.io);
    const stat = original.stat(self.io) catch return false;

    // **지금 디스크에 있는 것의 해시를 넘긴다.** 0을 넘겨 "검사를 건너뛴다"고 적었다가 실제
    // 구현을 보니 **무조건 비교**한다 — 0이면 정상 파일이 늘 `ExternalConflict`가 된다.
    // 그 검사가 막는 것은 *"temp를 쓰는 동안 남이 같은 inode를 in-place로 고쳤다"*이므로,
    // 쓰기 직전에 읽은 값을 기준으로 두는 것이 맞다.
    const expected = AppSession.stableOpenedFileHash(self.io, original, stat.inode) catch return false;

    file_panel_ops.writePinnedFilePanel(
        self.io,
        pinned.dir,
        pinned.basename,
        original,
        stat,
        expected,
        bytes,
    ) catch return false;

    // **여기서 clean이 된다.** 쓰기가 성공한 그 순간의 내용이 곧 디스크 내용이다.
    //
    // **`bytes`가 아니라 `content`의 해시다** — `bytes`에는 BOM이 붙어 있고(§3.5 원본 보존)
    // 편집기가 든 내용에는 없다. `bytes`로 재면 BOM 있는 파일이 저장 직후에도 dirty로 남는다.
    //
    // **쓰기 뒤에 읽는다.** 쓰는 동안 사용자가 더 칠 수 있으므로(§1의 "저장 중 재편집은 dirty를
    // 유지한다") 지금 내용이 방금 쓴 것과 다를 수 있고, 그러면 dirty로 남는 것이 **맞다**.
    // 그래서 저장 시작 시점이 아니라 **끝난 뒤**의 내용을 재면 안 된다 — `saved_bytes`가 그것을
    // 위해 남아 있다.
    term.rt.editor_doc.?.saved_hash = contentHash(saved_content);
    self.metal_dirty = true;
    return true;
}

/// **커서마다 텍스트를 넣는다** — 타이핑의 실제 진입점(§3.3).
///
/// **커서가 여럿이면 delta 하나에 range를 여럿 담는다.** §3.3이 *"한 번의 연산 = undo 하나"*를
/// 자료구조 수준에서 보장하라고 한 것이 이것이고, 커서마다 따로 적용하면 첫 삽입이 뒤 커서를 밀어
/// 두 번째가 엉뚱한 자리에 간다(그 매핑을 `delta.apply`가 같은 연산에서 한다).
///
/// **선택이 있으면 그것을 지우고 넣는다** — 타이핑이 선택을 대체하는 보편 동작이다.
///
/// 실패하면 **아무 일도 안 일어난다**: delta 층이 원자적이고(`OutOfRange`·`MalformedDelta`·OOM
/// 전부 되돌린다), 파생 재구축이 실패해도 문서가 편집 전이다.
///
/// **역연산을 아직 어디에도 안 쌓는다** — undo 스택은 다음 조각이다. 지금은 받아서 버린다.
pub fn insertText(self: *AppSession, term: *Term, text: []const u8) bool {
    if (term.kind != .editor or text.len == 0) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 원본이 없다
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;

    var iter = selections(term);
    if (iter.count() == 0) return false;

    // 커서를 문서 순서로 모은다 — delta가 정렬·비겹침을 요구한다.
    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    // 자동 닫기가 만든 문자열은 **우리가 소유한다**(호출자의 `text`와 달리 임시다).
    var pair_texts: std.ArrayList([]u8) = .empty;
    defer {
        for (pair_texts.items) |t| self.allocator.free(t);
        pair_texts.deinit(self.allocator);
    }
    // type-over로 지나간 커서 자리 — 변경 없이 caret만 옮긴다.
    var skip_overs: std.ArrayList(usize) = .empty;
    defer skip_overs.deinit(self.allocator);

    // **타이핑 보조는 한 글자 입력일 때만 본다**(§3.7). 붙여넣기·IME 확정은 여러 글자가 한 번에
    // 오는데 그때 괄호를 닫으면 **사용자가 넣지 않은 문자**가 문서에 들어간다.
    const aid: ?u8 = if (text.len == 1) text[0] else null;
    const content_now = doc.file.content;

    while (iter.next()) |sel| {
        const lo = @min(sel.start(), doc.file.content.len);
        const hi = @min(sel.end(), doc.file.content.len);

        if (aid) |typed| {
            const before: ?u8 = if (lo > 0) content_now[lo - 1] else null;
            const after: ?u8 = if (hi < content_now.len) content_now[hi] else null;
            switch (editor_pairs.decide(typed, hi > lo, before, after)) {
                .insert_plain => {},
                .insert_pair => |pr| {
                    const owned = self.allocator.dupe(u8, &[_]u8{ pr.open, pr.close }) catch return false;
                    pair_texts.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                        return false;
                    };
                    ranges.append(self.allocator, .{ .start = lo, .end = hi, .text = owned }) catch return false;
                    continue;
                },
                .skip_over => {
                    // **빈 변경을 넣어 자리를 지킨다.** 아래 caret 재배치가 `inverse.changes`와
                    // **인덱스로** 맞추는데, 건너뛴 커서가 delta에 안 실리면 그 뒤 커서들이 밀려
                    // **엉뚱한 자리로 튄다**(적대적 검증 2026-08-27이 실측으로 잡았다 — type-over
                    // 커서가 다른 커서 자리로 갔다). 길이 0에 빈 텍스트라 버퍼는 안 바뀐다.
                    skip_overs.append(self.allocator, ranges.items.len) catch return false;
                    ranges.append(self.allocator, .{ .start = lo, .end = lo, .text = "" }) catch return false;
                    continue;
                },
                .surround => |pr| {
                    // **감싼다** — 선택을 지우지 않는다. 앞뒤 두 변경으로 나눠 넣으면 그 사이 내용이
                    // 그대로 살아 사용자가 고른 것이 유지된다.
                    const o = self.allocator.dupe(u8, &[_]u8{pr.open}) catch return false;
                    pair_texts.append(self.allocator, o) catch {
                        self.allocator.free(o);
                        return false;
                    };
                    const c = self.allocator.dupe(u8, &[_]u8{pr.close}) catch return false;
                    pair_texts.append(self.allocator, c) catch {
                        self.allocator.free(c);
                        return false;
                    };
                    ranges.append(self.allocator, .{ .start = lo, .end = lo, .text = o }) catch return false;
                    ranges.append(self.allocator, .{ .start = hi, .end = hi, .text = c }) catch return false;
                    continue;
                },
            }
        }
        ranges.append(self.allocator, .{ .start = lo, .end = hi, .text = text }) catch return false;
    }
    // **type-over만 있었으면 문서는 안 바뀐다** — caret만 한 칸 넘기고 끝낸다(§3.7).
    //
    // 변경이 없으므로 delta도 undo도 만들지 않는다 — 빈 편집을 쌓으면 undo가 헛돈다.
    if (ranges.items.len == skip_overs.items.len) {
        if (skip_overs.items.len == 0) return false; // 애초에 아무 커서도 없었다
        if (term.rt.editor_selection) |sel| {
            term.rt.editor_selection = editor_selection.Selection.at(sel.focus + 1);
        }
        for (term.rt.editor_extra_selections) |*e| e.* = editor_selection.Selection.at(e.focus + 1);
        breakUndoGroup(term); // 커서가 편집 아닌 이유로 움직였다(§3.3)
        self.metal_dirty = true;
        return true;
    }

    std.mem.sort(maru.session.editor.delta.Change, ranges.items, {}, struct {
        fn lessThan(_: void, a: maru.session.editor.delta.Change, b: maru.session.editor.delta.Change) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // **겹치는 커서는 여기서 걸린다.** `mergeOverlapping`이 selection 단계에서 합치므로 정상
    // 경로에서는 안 나오지만, 걸러 두지 않으면 `delta.apply`가 `MalformedDelta`로 거절하고
    // 사용자에게는 "타이핑이 안 먹는다"로 보인다.
    for (ranges.items, 0..) |c, i| {
        if (i > 0 and c.start < ranges.items[i - 1].end) return false;
    }

    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);

    // **`term.rt`를 통해 부른다** — 위 `doc`은 값 복사라 그것에 대고 고치면 사본만 바뀐다.
    // **편집 전 커서를 떠 둔다** — undo가 그것을 되살린다(§3.3).
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;

    // **편집 전 화면 맨 위를 offset으로 떠 둔다** — 뷰포트 위에서 줄이 바뀌면 줄 번호가 밀린다.
    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term); // 스냅숏이 비워지기 전에 떠 둔다(노출이 쓴다)
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = ranges.items }, &sels) catch {
        self.allocator.free(before);
        return false;
    };

    // **친 커서는 넣은 글자 뒤로 간다 — 매핑에 맡기지 않는다.**
    // `mapOffset`의 경계 규칙은 *"삽입 지점에 정확히 있는 offset은 밀지 않는다"*인데, 그것은
    // **다른** 커서에는 맞지만 타이핑한 커서 자신에게는 틀리다(친 글자 앞에 남는다 — 실측으로
    // EDIT1·EDIT5가 그것을 잡았다). 어디로 갈지는 매핑이 아니라 **편집 연산이 정한다.**
    //
    // 역연산의 각 range가 편집 **후** 좌표로 "새로 들어간 구간"을 가리키므로, 그 끝이 곧 커서 자리다
    // (삭제는 길이가 0이라 시작 = 끝이고, 지운 자리에 커서가 선다).
    // **건너뛴 커서는 한 칸 넘어간다**(type-over) — 빈 변경이라 `ic.end`가 제자리다.
    //
    // **`skip_overs`가 오름차순이라는 것을 쓴다.** 커서마다 그 목록을 훑으면 **커서 수에
    // 곱해진다**(상한 10,000이면 1억 번 — `MC3`이 같은 축을 실측으로 고정한 전례가 있다).
    // 넣는 자리가 `ranges.items.len`이라 정렬이 보장되므로, 한 번만 앞으로 밀며 본다.
    // **밀기와 소비 중 하나면 된다.** 둘 다 두었더니 각각을 지운 뮤턴트가 **둘 다 살아남았다**
    // (적대적 검증 2026-08-27 — 동치였다): `i`가 0부터 하나씩 오르고 목록이 오름차순이라
    // 소비만 해도 커서가 늘 맞은 자리에 온다. 방어가 둘이면 하나는 반드시 검증 밖에 남는다.
    var skip_at: usize = 0;
    for (inverse.changes, 0..) |ic, i| {
        if (i >= sels.items.len) break;
        var at = ic.end;
        if (skip_at < skip_overs.items.len and skip_overs.items[skip_at] == i) {
            at += 1;
            skip_at += 1;
        }
        sels.items[i] = editor_selection.Selection.at(at);
    }

    // **자동으로 닫은 쌍은 caret이 가운데다**(§3.7). 위 규칙은 "넣은 것 뒤"라 `()`에서 닫는 괄호
    // **뒤**에 서게 되는데, 그러면 자동 닫기가 오히려 방해가 된다 — 사용자는 그 안에 이어 친다.
    //
    // **감싼 경우는 보정하지 않는다**: 여는 것과 닫는 것이 별개 변경이라 그 사이 선택이 그대로
    // 살아 있고, caret은 그 끝에 서는 것이 맞다.
    for (ranges.items, 0..) |r, i| {
        if (i >= sels.items.len) break;
        if (r.text.len == 2 and r.start == r.end) {
            const p = editor_pairs.pairFor(r.text[0]) orelse continue;
            if (p.close != r.text[1]) continue;
            sels.items[i] = editor_selection.Selection.at(sels.items[i].focus -| 1);
            // **자동으로 넣은 닫는 문자를 표시해 둔다**(§3.7) — Backspace가 그것만 함께 지운다.
            term.rt.editor_auto_closed_at = sels.items[i].focus;
        }
    }

    pushUndo(self, term, inverse, before, before_primary, .insert);

    writeBackSelections(self, term, sels);
    // **조합 중이면 조합 자리도 함께 옮긴다.** 자리는 조합을 시작할 때 한 번만 잡는데(IME4), 이어
    // 치는 한글에서는 그 "시작"이 **키 트랜잭션 한가운데**다 — `insertText`(확정)는 `ime_inserted`에
    // 쌓였다가 `imeEnd`에서야 문서에 들어가므로, 그 사이에 오는 `setMarkedText`는 **확정이 아직
    // 안 들어간** caret을 읽는다. 그러면 다음 음절이 방금 확정한 글자 **앞**에 그려진다
    // (실측: "가나다…카타파"를 치면 조합 "하"가 "…카타하파"로 섰다 — IME7).
    //
    // 자리를 여기서 다시 잡는다. **어디로 들어갔는지는 이 편집이 안다** — caret을 다시 읽는 것이
    // 아니라 편집이 정한 결과를 그대로 쓴다(위 "커서는 넣은 글자 뒤로 간다"와 같은 출처).
    if (term.rt.editor_preedit.len > 0) {
        if (term.rt.editor_selection) |sel| term.rt.editor_preedit_at = sel.start();
    }
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = ranges.items });
    // **편집한 자리를 보여 준다**(§5.2 줄 축). 앵커 보정 **뒤**여야 한다 — 보정은 "화면을 제자리에"
    // 두는 것이고 노출은 "커서를 화면 안에"이므로, 순서가 반대면 보정이 노출을 되돌린다.
    //
    // 이것이 없어서 화면 밖에서 편집하면 **자기가 어디를 고치는지 못 봤다**(적대적 검증 2026-08-26).
    revealPrimaryCaretRows(self, term, rows_before);
    return true;
}

/// 제품의 커서들을 `Selections`(L2가 요구하는 모양)로 옮긴다. **문서 순서로 정렬해서** 준다 —
/// `Selections.init`이 그것을 불변식으로 강제한다(편집을 뒤에서부터 적용하는 전제, §3.2).
fn selectionsForEdit(self: *AppSession, term: *Term) ?maru.session.editor.selection.Selections {
    var iter = selections(term);
    const n = iter.count();
    if (n == 0) return null;
    const items = self.allocator.alloc(editor_selection.Selection, n) catch return null;
    var i: usize = 0;
    while (iter.next()) |sel| {
        items[i] = sel;
        i += 1;
    }
    std.mem.sort(editor_selection.Selection, items, {}, struct {
        fn lessThan(_: void, a: editor_selection.Selection, b: editor_selection.Selection) bool {
            return a.start() < b.start();
        }
    }.lessThan);
    // primary는 **문서 순서에서 마지막**으로 둔다 — 타이핑 뒤 화면이 따라갈 기준이고, 그 자리가
    // 사용자가 마지막으로 친 곳이다.
    return editor_selection.Selections.init(items, n - 1);
}

/// 밀린 커서들을 제품 저장소로 되돌린다. **primary와 나머지를 다시 가른다.**
fn writeBackSelections(self: *AppSession, term: *Term, sels: maru.session.editor.selection.Selections) void {
    term.rt.editor_selection = sels.primarySelection();
    const extras_len = sels.items.len - 1;
    if (extras_len == 0) {
        clearExtraSelections(self, term);
        return;
    }
    const grown = self.allocator.alloc(editor_selection.Selection, extras_len) catch {
        clearExtraSelections(self, term);
        return;
    };
    var k: usize = 0;
    for (sels.items, 0..) |s, i| {
        if (i == sels.primary) continue;
        grown[k] = s;
        k += 1;
    }
    if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = grown;
}

/// **커서마다 지운다** — Backspace·Delete(§3.2 "문자 단위 삭제").
///
/// 선택이 있으면 **그 선택을 지운다**(방향과 무관하다 — 사용자가 고른 것이 지울 대상이다).
/// 선택이 없으면 caret 기준으로 앞(`backward`) 또는 뒤 한 **글자**를 지운다.
///
/// **byte가 아니라 글자다.** 한글·이모지는 여러 byte라 byte 하나만 지우면 **깨진 UTF-8이 남는다** —
/// 그 상태는 화면에 §3.8 표기로 뜨고 저장하면 파일이 깨진다. `stepBack`/`stepForward`가 cluster
/// 경계를 지킨다.
///
/// **지울 것이 없는 커서는 delta에서 뺀다**(문서 처음에서 Backspace). 빈 range를 넣으면
/// `delta.apply`가 겹침으로 볼 수 있고, 무엇보다 "아무것도 안 지웠는데 undo가 하나 쌓인다".
/// **잘라내기** — 복사한 뒤 지운다(§3.4).
///
/// **복사를 먼저 한다.** 지우고 나면 복사할 것이 없고, 복사가 실패했는데 지우면 사용자가
/// **클립보드에도 없고 문서에도 없는** 상태를 겪는다(undo가 있지만 "잘라냈는데 붙여넣을 것이
/// 없다"는 그 자체로 계약 위반이다). 주소창 `addrEditCut`이 같은 순서다.
///
/// **이 순서를 지금 판정할 수는 없다**(적대적 검증 2026-08-26). 커서가 멀쩡한데 복사만 실패하는
/// 경우는 **할당 실패**뿐인데, 그 실패는 아래 `deleteText`도 함께 깨뜨려 두 식이 같은 답을 낸다 —
/// 실패 지점을 미는 판정자로도 안 갈렸다(**동치 뮤턴트**). 그래서 이 `if`는 검증된 동작이 아니라
/// **의도의 표현**이고, 복사가 할당 아닌 이유로 실패할 수 있게 되는 날 비로소 판정된다.
///
/// **선택이 없으면 줄 전체를 잘라낸다** — 복사 쪽이 그렇게 담으므로(§3.4) 지우는 것도 같은 범위여야
/// "복사한 것이 사라졌다"가 성립한다. 다른 편집기도 `⌘X`가 줄을 자른다.
/// 문서 전체를 고른다(⌘A·컨텍스트 메뉴 "전체 선택").
///
/// **편집기에는 이 자리가 없었다**(2026-08-30 코드 확인). `select_all` 액션이 주소창·커밋 상자는
/// 분기하는데 편집기 Term 만 빠져, 코어 큐로 `.select_all` 을 보내고 있었다 — 편집기 Term 의
/// 코어는 sentinel 이라 그 명령이 닿을 곳이 없다. 같은 파일에서 `pasteText` 는 §3.4 대로 편집기를
/// 알아보는데 이것만 안 따라갔다.
///
/// **멀티 커서를 정리한다** — 전체를 고르는 것은 커서를 하나로 되돌리는 일이다. 남겨 두면 그 다음
/// 편집이 여러 자리에 들어간다.
pub fn selectAll(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 문서가 둘이라 "전체" 가 안 정해진다
    const doc = term.rt.editor_doc orelse return false;
    clearExtraSelections(self, term);
    term.rt.editor_selection = .{
        .anchor_start = 0,
        .anchor_end = 0,
        .focus = doc.file.content.len,
    };
    self.metal_dirty = true;
    return true;
}

/// 고른 부분을 그 대상 터미널에 붙여넣는다(NS5 — docs/send-selection-to-agent.md).
///
/// **안전 계약은 전부 아래 층이 든다**(§4): 페이로드 끝에 개행을 안 붙이는 것과 bracketed 가 꺼진
/// 대상에 여러 줄을 안 보내는 것은 `session/agent_selection.zig` 가, 붙여넣기 보호와 실제 인코딩은
/// `submitPaste` 가 소유한다. 이 함수가 하는 것은 **잇는 것**뿐이다 — 선택을 줄 범위로, 경로를
/// 루트 기준으로, 그리고 대상의 bracketed 를 **페이로드를 만들기 전에** 읽는 것.
///
/// **bracketed 를 먼저 읽는 이유**: 만든 뒤에 자르면 잘린 인용이 나간다. 그 판정이 페이로드의
/// 모양을 정하므로 순서가 뒤집히면 안 된다.
/// 보냈으면 true. **호출자가 그것으로 "마지막 대상" 을 기억한다** — 못 보낸 대상을 기억하면
/// 다음 메뉴가 되지 않는 줄에서 시작한다.
pub fn sendSelectionToAgent(self: *AppSession, source: *Term, target_id: u64) bool {
    // **bracketed 를 먼저 읽는다** — 그 값이 페이로드의 모양을 정한다(§4). 만든 뒤에 자르면 잘린
    // 인용이 나간다. `null` 이면 그 대상이 터미널이 아니다.
    const bracketed = term_ops.bracketedPasteFor(self, target_id) orelse return false;
    var payload_buf: [maru.session.agent_selection.max_quote_bytes + 1024]u8 = undefined;
    const payload = buildSelectionPayload(self, source, bracketed, &payload_buf) orelse return false;
    // 대상은 **id 로 고정**된다 — `submitPaste` 가 그 계약을 든다(뒤에 탭이 바뀌어도 원래 surface 로).
    term_ops.submitPaste(self, payload, false, target_id);
    return true;
}

/// 보낼 바이트를 만든다.
///
/// **주입에서 갈라 둔 이유는 그것만이 관측 가능하기 때문이다** — 주입은 큐에 넣고 곧바로
/// 흘려보내므로(`flushPendingPaste`) 판정자가 큐를 들여다볼 틈이 없다. 안전 계약(§4)이 걸린
/// 자리라 "보낸 바이트가 무엇인가" 를 반드시 잴 수 있어야 한다.
pub fn buildSelectionPayload(
    self: *AppSession,
    source: *Term,
    bracketed: bool,
    out: []u8,
) ?[]const u8 {
    if (source.kind != .editor) return null;
    if (source.rt.editor_diff != null) return null; // 비교 뷰는 "그 파일의 그 줄" 이 하나로 안 정해진다(§3)
    const doc = source.rt.editor_doc orelse return null;
    const path = source.rt.editor_path orelse return null; // 핀된 경로가 없으면 참조를 못 만든다
    const bytes = doc.file.content;

    // **주 선택 하나만 보낸다**(§3). 멀티 커서면 나머지는 안 간다 — 조용히 첫 조각만 보내면
    // 사용자는 나머지가 갔다고 믿는다.
    const sel = source.rt.editor_selection orelse return null;
    const lo = @min(sel.anchorLo(), bytes.len);
    const hi = @min(@max(sel.anchorHi(), sel.focus), bytes.len);
    const start = @min(lo, hi);
    // 선택이 없으면 caret 이 있는 줄 하나다(§3 — 복사가 §3.4 로 정한 규칙과 같다).
    const line_lo = doc.file.lines.lineAt(start);
    const line_hi = doc.file.lines.lineAt(if (hi > start) hi -| 1 else start);
    const text: []const u8 = if (hi > start) bytes[start..hi] else blk: {
        const line = doc.file.lines.line(line_lo) orelse break :blk "";
        break :blk bytes[line.start..line.contentEnd()];
    };

    // **트리 루트 기준으로 접는다**(§2). 루트가 여럿이면 첫 번째를 쓴다 — 그 안이 아니면
    // `relativePath` 가 절대 경로를 그대로 돌려주므로 잘못 접힐 일은 없다.
    const root: []const u8 = self.file_tree.rootAt(0) orelse "";
    return maru.session.agent_selection.build(.{
        .path = maru.session.agent_selection.relativePath(root, path),
        .start_line = @intCast(line_lo + 1), // 1-based 닫힌 구간
        .end_line = @intCast(line_hi + 1),
        .text = text,
    }, .{ .bracketed_paste = bracketed }, out);
}

pub fn cutSelection(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    if (!copySelection(self)) return false;

    const had_selection = blk: {
        var it = selections(term);
        while (it.next()) |sel| if (!sel.isEmpty()) break :blk true;
        break :blk false;
    };
    if (had_selection) return deleteText(self, term, false);

    // **선택이 없다 = 줄 전체다.** caret이 있는 줄을 통째로 지운다.
    const primary = term.rt.editor_selection orelse return false;
    const line_idx = doc.file.lines.lineAt(@min(primary.focus, doc.file.content.len));
    const line = doc.file.lines.line(line_idx) orelse return false;
    term.rt.editor_selection = editor_selection.Selection.fromPoints(line.start, line.end_with_ending);
    clearExtraSelections(self, term);
    return deleteText(self, term, false);
}

/// **주석 토글**(§3.7) — selection이 걸친 줄 전체를 한 번에 뒤집는다.
///
/// **"하나라도 주석이 아니면 전부 주석"**(VSCode 관례를 §3.7이 채택했다). 섞여 있을 때 "전부
/// 해제"로 가면 **주석이던 줄이 코드가 되어** 사용자가 의도하지 않은 실행이 생긴다 — 반대 방향은
/// 되돌리기 쉽고 이쪽은 아니다.
///
/// **언어를 모르면 아무 일도 안 한다**(그 절이 그렇게 정했다). 모르는 파일에 아무 문법이나 넣으면
/// 사용자가 **그 언어에 없는 문자**를 문서에 박는다.
///
/// **한 번의 토글은 undo 하나다** — 커서가 N개여도 `delta.apply` 한 번이다(§3.3).
/// 커서들이 **걸친 줄 번호**(중복 없이 오름차순). 줄 조작 넷과 주석 토글이 **같은 답**을 써야 한다
/// — 갈리면 `⌘/` 로 주석 처리한 범위와 `⇧⌘K` 로 지우는 범위가 달라진다(§3.9a).
///
/// **선택이 다음 줄 머리에서 끝나면 그 줄은 뺀다.** 줄 전체를 끌어 고르면 끝이 다음 줄 offset 0이
/// 되는데, 그대로 넣으면 **고르지 않은 줄이 딸려 온다**(2026-08-27 실측 — `[0,2)`로 첫 줄만 골랐는데
/// 둘째 줄까지 갔다). VSCode·Xcode 가 같은 자리에서 뺀다.
///
/// **중복은 정렬 뒤 인접 비교로 지운다.** 넣을 때마다 앞을 훑으면 O(n²)이고 커서는 `⌘⌃D` 로 수천
/// 개가 된다(4,000개에서 비교 800만 번을 실측했다). 한 줄에 커서가 여럿이어도 **한 번만** 세야 —
/// 두 번 세면 주석은 `////` 가 되고 줄 이동은 **두 칸** 움직인다.
fn selectedLineNumbers(self: *AppSession, term: *Term, out: *std.ArrayList(usize)) bool {
    const doc = term.rt.editor_doc orelse return false;
    const content = doc.file.content;
    const lines = doc.file.lines;
    var iter = selections(term);
    if (iter.count() == 0) return false;
    while (iter.next()) |sel| {
        const s_off = @min(sel.start(), content.len);
        var e_off = @min(sel.end(), content.len);
        if (e_off > s_off) {
            const e_line = lines.lineAt(e_off);
            if (lines.line(e_line)) |l| {
                if (l.start == e_off) e_off -= 1;
            }
        }
        const lo = lines.lineAt(s_off);
        const hi = lines.lineAt(e_off);
        var n = lo;
        while (n <= hi) : (n += 1) out.append(self.allocator, n) catch return false;
    }
    if (out.items.len == 0) return false;
    std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
    var w: usize = 0;
    for (out.items, 0..) |n, i| {
        if (i == 0 or n != out.items[w - 1]) {
            out.items[w] = n;
            w += 1;
        }
    }
    out.shrinkRetainingCapacity(w);
    return true;
}

pub fn toggleLineComment(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;

    const path = term.rt.editor_path orelse return false;
    const lang = maru.session.editor.language.forPath(path);
    const marker = lang.lineComment() orelse return false; // 모르는 언어 — no-op(§3.7)

    const content = doc.file.content;
    const lines = doc.file.lines;

    // 커서들이 걸친 **줄 번호**를 모은다. 같은 줄에 커서가 여럿이면 한 번만 — 두 번 주석 처리하면
    // `////`가 된다.
    // **줄 번호는 `selectedLineNumbers` 하나가 답한다**(§3.9a) — 줄 조작 넷과 같은 답이어야 한다.
    var line_nums: std.ArrayList(usize) = .empty;
    defer line_nums.deinit(self.allocator);
    if (!selectedLineNumbers(self, term, &line_nums)) return false;

    // **하나라도 주석이 아니면 전부 주석.** 빈 줄은 판단에서 뺀다 — 빈 줄 하나 때문에 전체가
    // "주석 아님"으로 뒤집히면 이미 다 주석인 블록을 해제할 수 없다.
    var all_commented = true;
    var any_content = false;
    for (line_nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const text = content[line.start..line.contentEnd()];
        const trimmed = std.mem.trimStart(u8, text, " \t");
        if (trimmed.len == 0) continue; // 빈 줄
        any_content = true;
        if (!std.mem.startsWith(u8, trimmed, marker)) all_commented = false;
    }
    if (!any_content) return false; // 빈 줄만 골랐다 — 넣을 자리가 없다

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| self.allocator.free(t);
        owned.deinit(self.allocator);
    }

    for (line_nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const text = content[line.start..line.contentEnd()];
        const indent = text.len - std.mem.trimStart(u8, text, " \t").len;
        if (indent == text.len) continue; // 빈 줄은 건드리지 않는다
        if (all_commented) {
            // **해제** — 표식과 그 뒤 공백 하나까지 지운다(넣을 때 붙인 그 공백이다).
            const at = line.start + indent;
            var end = at + marker.len;
            if (end < content.len and content[end] == ' ') end += 1;
            ranges.append(self.allocator, .{ .start = at, .end = end, .text = "" }) catch return false;
        } else {
            // **주석** — 들여쓰기 **뒤**에 넣는다. 줄 머리에 넣으면 들여쓰기가 무너져 보인다.
            const t = std.fmt.allocPrint(self.allocator, "{s} ", .{marker}) catch return false;
            owned.append(self.allocator, t) catch {
                self.allocator.free(t);
                return false;
            };
            const at = line.start + indent;
            ranges.append(self.allocator, .{ .start = at, .end = at, .text = t }) catch return false;
        }
    }
    if (ranges.items.len == 0) return false;

    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;

    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term);
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = ranges.items }, &sels) catch {
        self.allocator.free(before);
        return false;
    };

    breakUndoGroup(term); // 타이핑과 다른 연산이다(§3.3 "연산 종류 변경")
    pushUndo(self, term, inverse, before, before_primary, .insert);
    writeBackSelections(self, term, sels);
    // **구문 트리 통지**(§5.3). 역연산이 편집 **후** 좌표라 그대로 범위가 된다.
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = ranges.items });
    revealPrimaryCaretRows(self, term, rows_before);
    breakUndoGroup(term);
    self.metal_dirty = true;
    return true;
}

/// 줄 조작 넷이 공유하는 **편집 적용 꼬리**(§3.9a) — undo 하나, 스크롤 앵커, 구문 통지, reveal.
///
/// **꼬리를 복사해 두면 넷 중 하나가 반드시 어긋난다.** 실제로 `toggleLineComment`·`pasteText`가
/// 같은 아홉 줄을 각자 들고 있고, 그 중 하나만 `breakUndoGroup`을 빠뜨려도 **타이핑과 한 undo로
/// 뭉친다**(§3.3 "연산 종류 변경"). 그래서 넷은 이 자리 하나를 탄다.
fn applyLineEdit(self: *AppSession, term: *Term, ranges: []const maru.session.editor.delta.Change) bool {
    if (ranges.len == 0) return false;
    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;
    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term);
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = ranges }, &sels) catch {
        self.allocator.free(before);
        return false;
    };
    breakUndoGroup(term);
    pushUndo(self, term, inverse, before, before_primary, .insert);
    writeBackSelections(self, term, sels);
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = ranges });
    revealPrimaryCaretRows(self, term, rows_before);
    breakUndoGroup(term);
    self.metal_dirty = true;
    return true;
}

/// 줄 조작이 설 수 있는 문서인가 — 편집기이고, 비교가 아니고, 읽기 전용이 아니어야 한다.
fn lineOpDoc(term: *Term) ?Opened {
    if (term.kind != .editor) return null;
    if (term.rt.editor_diff != null) return null; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return null;
    // **읽기 전용은 심층 방어다**(§6). `edit_doc.apply` 가 같은 판정을 하므로 이 줄을 지워도 문서는
    // 안 바뀌고 `applyLineEdit` 이 거짓을 낸다 — 그래서 **판정자로 잡히지 않는다**(변이 L21 이
    // 살아남는 것이 정상이다). 그럼에도 두는 이유는 여기서 막으면 `selectedLineNumbers` 부터의
    // 헛일과 할당이 아예 안 일어나서다. `toggleLineComment`·`pasteText` 도 같은 자리에 같은 줄을 둔다.
    if (doc.file.read_only) return null;
    return doc;
}

/// `⇧⌘K` — 걸친 줄들을 지운다(§3.9a).
///
/// **마지막 줄이면 앞 개행을 지운다.** 뒤에 개행이 없는데 줄 내용만 지우면 **빈 줄이 남아** 사용자
/// 눈에는 "지웠는데 자리가 남는다"로 보인다.
pub fn deleteLines(self: *AppSession, term: *Term) bool {
    const doc = lineOpDoc(term) orelse return false;
    const content = doc.file.content;
    const lines = doc.file.lines;
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(self.allocator);
    if (!selectedLineNumbers(self, term, &nums)) return false;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    for (nums.items) |n| {
        const line = lines.line(n) orelse continue;
        var start = line.start;
        var end = line.end_with_ending; // 개행 포함
        if (end >= content.len and start > 0) {
            // 문서 마지막 줄 — 앞 개행까지 먹는다.
            start -= 1;
            end = content.len;
        }
        ranges.append(self.allocator, .{ .start = start, .end = end, .text = "" }) catch return false;
    }
    return applyLineEdit(self, term, ranges.items);
}

/// 걸친 줄들을 **아래에** 복사한다(§3.9a).
///
/// **선택은 복사본으로 옮긴다**(VSCode 관례). 원본에 두면 다시 눌렀을 때 **같은 줄이 또 복제되어**
/// 사용자가 만든 복사본이 아니라 원본만 늘어난다 — `delta.apply`가 삽입 지점 뒤의 selection을 미므로,
/// 복사본을 **선택 앞이 아니라 뒤**에 넣는 것이 그 동작을 만든다.
pub fn duplicateLines(self: *AppSession, term: *Term) bool {
    const doc = lineOpDoc(term) orelse return false;
    const content = doc.file.content;
    const lines = doc.file.lines;
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(self.allocator);
    if (!selectedLineNumbers(self, term, &nums)) return false;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| self.allocator.free(t);
        owned.deinit(self.allocator);
    }
    var shift: usize = 0;
    // **연속한 줄은 한 덩어리로 복사한다.** 줄마다 따로 넣으면 A B 가 A A B B 가 되어 블록이 깨진다.
    var i: usize = 0;
    while (i < nums.items.len) {
        var j = i;
        while (j + 1 < nums.items.len and nums.items[j + 1] == nums.items[j] + 1) j += 1;
        const first = lines.line(nums.items[i]) orelse {
            i = j + 1;
            continue;
        };
        const last = lines.line(nums.items[j]) orelse {
            i = j + 1;
            continue;
        };
        const block = content[first.start..@min(last.end_with_ending, content.len)];
        const t = if (block.len > 0 and block[block.len - 1] == '\n')
            self.allocator.dupe(u8, block) catch return false
        else
            std.fmt.allocPrint(self.allocator, "\n{s}", .{block}) catch return false;
        owned.append(self.allocator, t) catch {
            self.allocator.free(t);
            return false;
        };
        const at = @min(last.end_with_ending, content.len);
        ranges.append(self.allocator, .{ .start = at, .end = at, .text = t }) catch return false;
        shift += t.len;
        i = j + 1;
    }
    if (!applyLineEdit(self, term, ranges.items)) return false;

    // **선택을 사본으로 옮긴다**(§3.9a). `delta.apply` 는 삽입 지점 **뒤**만 밀므로, 블록 뒤에 넣은
    // 사본은 선택을 안 건드린다 — 그대로 두면 커서가 **위 원본**에 남아, 다시 눌렀을 때 사용자가
    // 방금 만든 사본이 아니라 원본이 또 복제된다.
    //
    // **앞에 넣어 미는 방법은 안 된다** — 선택이 삽입 지점에서 시작하면 anchor 는 제자리고 focus 만
    // 밀려 **두 사본을 통째로 덮는다**(실측: 두 번째 복제가 네 벌을 만들었다).
    if (shift > 0) {
        if (term.rt.editor_selection) |sel| term.rt.editor_selection = .{
            .anchor_start = sel.anchor_start + shift,
            .anchor_end = sel.anchor_end + shift,
            .focus = sel.focus + shift,
            .kind = sel.kind,
        };
        for (term.rt.editor_extra_selections) |*e| e.* = .{
            .anchor_start = e.anchor_start + shift,
            .anchor_end = e.anchor_end + shift,
            .focus = e.focus + shift,
            .kind = e.kind,
        };
    }
    return true;
}

/// 걸친 블록을 위/아래 줄과 **통째로 맞바꾼다**(§3.9a).
///
/// **문서 처음/끝에서는 무동작이다.** clamp 해서 절반만 움직이면 사용자는 무슨 일이 났는지 못 읽는다.
/// **연속하지 않은 줄 무리는 각자 옮긴다** — 한 덩어리로 치면 사이의 안 고른 줄까지 끌려간다.
pub fn moveLines(self: *AppSession, term: *Term, down: bool) bool {
    const doc = lineOpDoc(term) orelse return false;
    const content = doc.file.content;
    const lines = doc.file.lines;
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(self.allocator);
    if (!selectedLineNumbers(self, term, &nums)) return false;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| self.allocator.free(t);
        owned.deinit(self.allocator);
    }
    var i: usize = 0;
    while (i < nums.items.len) {
        var j = i;
        while (j + 1 < nums.items.len and nums.items[j + 1] == nums.items[j] + 1) j += 1;
        const lo = nums.items[i];
        const hi = nums.items[j];
        i = j + 1;
        // **경계에서는 그 무리만 건너뛴다** — 다른 무리는 여전히 움직여야 한다.
        if (!down and lo == 0) continue;
        if (down and hi + 1 >= lines.lineCount()) continue;
        // **문서 끝 개행이 만드는 빈 줄은 이동 대상이 아니다.** 그것과 맞바꾸면 내용이 `"c\n"` →
        // `"\nc"` 가 되어 **빈 줄이 생기고 끝 개행이 사라진다**(적대적 검증 LN4 가 실측했다).
        // 화면에는 아무 줄도 없는 자리라, 사용자는 "아래로 옮겼는데 줄이 하나 늘었다"만 본다.
        if (down and (lines.line(hi + 1) orelse continue).start >= content.len) continue;
        const swap_n = if (down) hi + 1 else lo - 1;
        const blk_first = lines.line(lo) orelse continue;
        const blk_last = lines.line(hi) orelse continue;
        const other = lines.line(swap_n) orelse continue;

        const blk = content[blk_first.start..@min(blk_last.end_with_ending, content.len)];
        const oth = content[other.start..@min(other.end_with_ending, content.len)];
        // **개행이 없는 마지막 줄이 섞이면 개행을 손으로 맞춘다** — 그대로 이으면 두 줄이 붙는다.
        const blk_nl = blk.len > 0 and blk[blk.len - 1] == '\n';
        const oth_nl = oth.len > 0 and oth[oth.len - 1] == '\n';
        const blk_body = if (blk_nl) blk[0 .. blk.len - 1] else blk;
        const oth_body = if (oth_nl) oth[0 .. oth.len - 1] else oth;
        const region_start = if (down) blk_first.start else other.start;
        const region_end = if (down) @min(other.end_with_ending, content.len) else @min(blk_last.end_with_ending, content.len);
        const trailing_nl = if (down) blk_nl and oth_nl else oth_nl and blk_nl;
        const t = if (down)
            (if (trailing_nl)
                std.fmt.allocPrint(self.allocator, "{s}\n{s}\n", .{ oth_body, blk_body }) catch return false
            else
                std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ oth_body, blk_body }) catch return false)
        else
            (if (trailing_nl)
                std.fmt.allocPrint(self.allocator, "{s}\n{s}\n", .{ blk_body, oth_body }) catch return false
            else
                std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ blk_body, oth_body }) catch return false);
        owned.append(self.allocator, t) catch {
            self.allocator.free(t);
            return false;
        };
        ranges.append(self.allocator, .{ .start = region_start, .end = region_end, .text = t }) catch return false;
    }
    return applyLineEdit(self, term, ranges.items);
}

/// 걸친 줄들의 머리를 한 단계 넣거나 뺀다(§3.9a).
///
/// **들여쓰기는 탭 문자 하나다** — `Tab` 키가 넣는 것과 **같아야** 한다. 갈라 두면 같은 키가 선택
/// 여부에 따라 다른 문자를 넣는다. **빈 줄은 건드리지 않는다**(§3.7이 주석에서 같은 결정을 했다 —
/// 공백만 있는 줄이 늘어난다). **내어쓰기는 있는 만큼만** 뺀다: 탭 하나, 없으면 공백을 최대
/// `editor.tab-width`개. 없는 줄이 섞여도 연산 전체가 실패하지 않는다.
pub fn indentLines(self: *AppSession, term: *Term, outdent: bool) bool {
    const doc = lineOpDoc(term) orelse return false;
    const content = doc.file.content;
    const lines = doc.file.lines;
    var nums: std.ArrayList(usize) = .empty;
    defer nums.deinit(self.allocator);
    if (!selectedLineNumbers(self, term, &nums)) return false;

    const width: usize = @max(1, term.rt.editor_tab_width);
    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    for (nums.items) |n| {
        const line = lines.line(n) orelse continue;
        const text = content[line.start..line.contentEnd()];
        if (outdent) {
            if (text.len == 0) continue;
            var take: usize = 0;
            if (text[0] == '\t') {
                take = 1;
            } else {
                while (take < text.len and take < width and text[take] == ' ') take += 1;
            }
            if (take == 0) continue; // 뺄 것이 없다 — 이 줄만 건너뛴다
            ranges.append(self.allocator, .{ .start = line.start, .end = line.start + take, .text = "" }) catch return false;
        } else {
            if (std.mem.trimStart(u8, text, " \t").len == 0) continue; // 빈 줄
            ranges.append(self.allocator, .{ .start = line.start, .end = line.start, .text = "\t" }) catch return false;
        }
    }
    return applyLineEdit(self, term, ranges.items);
}

/// 선택이 **여러 줄에 걸치는가** — `Tab` 이 글자를 넣을지 줄을 들여쓸지 가른다(§3.9a).
///
/// **줄 번호로 잰다.** offset 차이로 재면 긴 한 줄이 여러 줄로 오인된다. 커서가 여럿이면 하나라도
/// 여러 줄에 걸치면 참이다 — 섞였을 때 일부만 들여쓰면 나머지 커서는 탭 문자를 받아 한 연산이
/// 두 뜻이 된다.
pub fn selectionSpansLines(term: *Term) bool {
    const doc = term.rt.editor_doc orelse return false;
    const lines = doc.file.lines;
    const content = doc.file.content;
    var iter = selections(term);
    while (iter.next()) |sel| {
        const s_off = @min(sel.start(), content.len);
        const e_off = @min(sel.end(), content.len);
        if (e_off <= s_off) continue;
        if (lines.lineAt(s_off) != lines.lineAt(e_off)) return true;
    }
    return false;
}

/// Enter — 개행을 넣고 **이전 줄의 들여쓰기를 잇는다**(§3.9a).
///
/// **앞 공백을 글자 그대로 잇는다** — 탭이면 탭, 공백이면 공백(§3.5 *"원문을 바꾸지 않는다"*와 같은
/// 결이다. 변환하면 그 파일의 나머지와 어긋난다).
///
/// **caret 앞까지만 본다.** 줄 가운데서 Enter 를 치면 뒤 절반이 다음 줄로 가는데, 그 줄의 들여쓰기는
/// **원래 줄의 것**이지 잘린 조각의 것이 아니다.
///
/// **커서마다 다른 들여쓰기를 잇는다** — 커서가 여럿이면 각자 자기 줄을 본다. 하나로 정하면 다른
/// 커서 자리에 **그 줄에 없던 공백**이 들어간다.
///
/// **읽기 전용·비교에서는 종전 경로로 떨어진다**(그쪽이 거절한다 — 여기서 또 판정하면 출처가 둘이다).
pub fn insertNewlineKeepingIndent(self: *AppSession, term: *Term) bool {
    const doc = lineOpDoc(term) orelse return insertText(self, term, "\n");
    const content = doc.file.content;
    const lines = doc.file.lines;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| self.allocator.free(t);
        owned.deinit(self.allocator);
    }
    var iter = selections(term);
    if (iter.count() == 0) return insertText(self, term, "\n");
    while (iter.next()) |sel| {
        const s_off = @min(sel.start(), content.len);
        const e_off = @min(sel.end(), content.len);
        const line = lines.line(lines.lineAt(s_off)) orelse return insertText(self, term, "\n");
        // **caret 앞까지만** 본다.
        const head = content[line.start..s_off];
        const indent_len = head.len - std.mem.trimStart(u8, head, " \t").len;
        const indent = head[0..indent_len];
        const t = std.fmt.allocPrint(self.allocator, "\n{s}", .{indent}) catch return false;
        owned.append(self.allocator, t) catch {
            self.allocator.free(t);
            return false;
        };
        ranges.append(self.allocator, .{ .start = s_off, .end = e_off, .text = t }) catch return false;
    }
    // **들여쓸 것이 없으면 종전 경로다** — 같은 결과를 두 자리에서 만들지 않는다.
    var any_indent = false;
    for (ranges.items) |r| {
        if (r.text.len > 1) any_indent = true;
    }
    if (!any_indent) return insertText(self, term, "\n");
    return applyLineEdit(self, term, ranges.items);
}

/// 선택(없으면 caret 의 낱말)을 대문자/소문자로 바꾼다(§3.9b).
///
/// **낱말 규칙은 `selection.wordRangeAt` 이 소유한다** — 더블클릭이 잡는 그 범위이고
/// `add_next_occurrence` 가 씨앗을 고를 때 쓰는 것과 **같은 함수**다. 셋이 다른 낱말을 잡으면
/// 사용자는 그 차이를 설명할 수 없다.
///
/// **대소문자 축은 `maru.terminal.selection` 이 소유한다** — `foldCase` 와 그 짝 `upperCase`. 여기서
/// 따로 표를 만들면 찾기의 대소문자 무시 비교와 어긋난다.
///
/// **줄 조작(§3.9a)과 달리 범위를 합치지 않는다.** 겹치는 것은 줄이 아니라 범위이고, 대소문자는
/// 멱등이라 겹친 자리를 두 번 바꿔도 결과가 같다.
pub fn transformCase(self: *AppSession, term: *Term, upper: bool) bool {
    const doc = lineOpDoc(term) orelse return false;
    const content = doc.file.content;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| self.allocator.free(t);
        owned.deinit(self.allocator);
    }
    var iter = selections(term);
    if (iter.count() == 0) return false;
    while (iter.next()) |sel| {
        var lo = @min(sel.start(), content.len);
        var hi = @min(sel.end(), content.len);
        if (hi == lo) {
            // **선택이 없으면 caret 의 낱말**(§3.9b).
            const w = editor_selection.wordRangeAt(content, lo);
            lo = w.lo;
            hi = w.hi;
        }
        // **빈 범위를 따로 안 막는다**(낱말이 없는 자리 — 문서 끝·공백). 아래 「바뀐 것이 없으면
        // 건너뛴다」가 그 경우를 그대로 덮으므로, 앞에 또 두면 **판정자로 구별할 수 없는 가지**가
        // 하나 늘 뿐이다(변이 C7 이 그것을 보였다).
        // **`hi >= lo` 는 두 출처 모두가 보장한다** — `sel.end() >= sel.start()` 이고 `wordRangeAt` 은
        // `lo <= hi` 를 낸다. 그래서 여기 `@max` 같은 방어를 두면 **닿을 수 없는 가지**가 되어 판정자로
        // 구별할 수 없다(변이 C16 이 그것을 보였다). 불변식이 깨지면 이 슬라이스가 곧바로 죽는 편이
        // 낫다 — 조용히 빈 범위로 넘어가면 「아무 일도 안 일어난다」로만 보인다.
        const src = content[lo..hi];
        const buf = self.allocator.alloc(u8, src.len) catch return false;
        owned.append(self.allocator, buf) catch {
            self.allocator.free(buf);
            return false;
        };
        // **길이가 안 변한다**(§3.9b) — 덮는 네 블록의 오프셋이 같은 UTF-8 길이 안에서만 움직인다.
        // 그래서 자리마다 제자리 인코딩이 성립하고, 선택 범위와 다른 커서가 안 밀린다.
        //
        // **그 불변식을 런타임에서 다시 안 막는다.** `CASE3` 이 `upperCase`·`foldCase` 를 코드포인트
        // 전 구간에 대해 **byte 길이가 같다**로 고정하므로, 여기 방어를 두면 **닿을 수 없는 가지**가
        // 된다(변이 C5 가 그것을 보였다). 1:N 매핑을 들이는 날 `CASE3` 이 먼저 빨개지고, §3.9b 가
        // 그때 선택 보정 규칙을 함께 정하라고 적어 뒀다.
        var w_i: usize = 0;
        // **문서는 열릴 때 UTF-8 이 검증된다**(`session/editor/document.zig` — 아니면 `error.NotUtf8`
        // 로 아예 안 열리고 CM6 로 떨어진다). 그래서 여기서 디코드가 실패할 수 없다 — 방어를 두면
        // **닿을 수 없는 가지**가 되고 판정자로 구별할 수 없다(변이 C5 가 그것을 보였다).
        // `unreachable` 대신 원문을 두는 이유는 §3.8 이다: 문서를 바꾸는 연산이 ReleaseFast 에서
        // 죽는 것보다, 그 자리를 안 건드리는 편이 안전한 저하다.
        var view = std.unicode.Utf8View.init(src) catch {
            continue;
        };
        var cps = view.iterator();
        while (cps.nextCodepoint()) |cp| {
            const out = if (upper) maru.terminal.selection.upperCase(cp) else maru.terminal.selection.foldCase(cp);
            w_i += std.unicode.utf8Encode(out, buf[w_i..]) catch continue;
        }
        if (std.mem.eql(u8, buf, src)) continue; // 바뀐 것이 없다 — 빈 delta 를 만들지 않는다
        ranges.append(self.allocator, .{ .start = lo, .end = hi, .text = buf }) catch return false;
    }
    // **문서 순서로 정렬한다.** `delta` 는 *"변경들이 문서 순서로 정렬돼 있고 겹치지 않는다"* 를
    // **불변식으로 요구**하는데, `selections()` 는 **primary 를 먼저** 낸다 — 커서가 여럿이면
    // 뒤쪽 커서가 앞에 와 `apply` 가 통째로 거절한다(적대적 검증 CS7 이 실측했다: `⌘⌃D` 로 커서를
    // 늘린 뒤 변환하면 **아무 일도 안 일어났다**). 줄 조작은 `selectedLineNumbers` 가 정렬해 주므로
    // 이 자리가 없었고, 그래서 같은 함정을 두 번째로 밟았다.
    //
    // **겹침은 만들지 않는다** — 각 selection 은 서로 겹치지 않고(§3.2 불변식), 낱말로 넓힌 범위도
    // 같은 낱말이면 같은 범위라 정렬 뒤 인접 비교로 볼 필요가 없다.
    std.mem.sort(maru.session.editor.delta.Change, ranges.items, {}, struct {
        fn lessThan(_: void, a: maru.session.editor.delta.Change, b: maru.session.editor.delta.Change) bool {
            return a.start < b.start;
        }
    }.lessThan);
    return applyLineEdit(self, term, ranges.items);
}

/// **클립보드를 커서마다 넣는다**(§3.4)./// **클립보드를 커서마다 넣는다**(§3.4).
///
/// 분배 규칙은 `clipboard.distribute`가 소유한다 — 조각 수가 커서 수와 **같으면** 하나씩,
/// **다르면** 전부에 통짜다. 외부 앱이 복사한 문자열이면 기억한 경계를 버리고 통짜로 간다.
///
/// **선택 없이 복사한 것은 줄 단위로 넣는다**(§3.4 — `from_empty_selection`): caret 자리에
/// 끼워 넣으면 줄이 깨지므로 **그 줄 앞**에 통째로 넣는다.
///
/// **한 번의 붙여넣기는 undo 하나다**(§3.3) — 커서가 N개여도 `delta.apply` 한 번이라 그렇게 된다.
pub fn pasteText(self: *AppSession, term: *Term, clipboard: []const u8) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(§4.1g)
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    if (clipboard.len == 0) return false;

    var iter = selections(term);
    const n = iter.count();
    if (n == 0) return false;

    const clip = maru.session.editor.clipboard;
    const line_wise = clip.describes(self.editor_clipboard_meta, clipboard) and
        self.editor_clipboard_meta.?.from_empty_selection;

    const pieces_buf = self.allocator.alloc([]const u8, n) catch return false;
    defer self.allocator.free(pieces_buf);
    const dist = clip.distribute(self.editor_clipboard_meta, clipboard, n, pieces_buf);

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    const content = doc.file.content;
    var i: usize = 0;
    iter = selections(term);
    while (iter.next()) |sel| : (i += 1) {
        const text = switch (dist) {
            .per_cursor => |ps| ps[i],
            .whole => |w| w,
        };
        if (line_wise) {
            // **줄 단위**: caret이 있는 줄의 **머리**에 넣는다. 선택이 있어도 그 줄 머리다 —
            // 줄 단위로 담은 것을 줄 중간에 끼우면 두 줄이 한 줄이 된다.
            const line_idx = doc.file.lines.lineAt(@min(sel.focus, content.len));
            const line = doc.file.lines.line(line_idx) orelse continue;
            ranges.append(self.allocator, .{ .start = line.start, .end = line.start, .text = text }) catch return false;
        } else {
            const lo = @min(sel.start(), content.len);
            const hi = @min(sel.end(), content.len);
            ranges.append(self.allocator, .{ .start = lo, .end = hi, .text = text }) catch return false;
        }
    }
    if (ranges.items.len == 0) return false;

    std.mem.sort(maru.session.editor.delta.Change, ranges.items, {}, struct {
        fn lessThan(_: void, a: maru.session.editor.delta.Change, b: maru.session.editor.delta.Change) bool {
            return a.start < b.start;
        }
    }.lessThan);
    // 겹치면 `delta.apply`가 거절한다. **줄 단위에서 같은 줄에 커서가 여럿**이면 줄 머리가 같아
    // 실제로 겹치므로 뒤 것을 버린다 — 두 번 넣으면 사용자는 커서를 둘 뒀다는 이유로 **줄이 두 번**
    // 들어간 것을 본다(`PASTE7`이 판정한다).
    //
    // **범위 겹침(아래 첫 줄)은 닿지 않는다** — `selectionsForEdit`이 부르는 `mergeOverlapping`이
    // 이미 합쳐서 준다. 지운 뮤턴트가 살아남아 그것을 확인했다(적대적 검증 2026-08-26). 남겨 두는
    // 이유는 **`delta`의 계약이 정렬·비겹침을 요구**하기 때문이다 — 그 전제가 깨지면 `apply`가
    // `MalformedDelta`로 붙여넣기를 통째로 거절하므로, 여기서 한 번 더 좁히는 값이 있다.
    var dedup: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer dedup.deinit(self.allocator);
    for (ranges.items) |c| {
        if (dedup.items.len > 0 and c.start < dedup.items[dedup.items.len - 1].end) continue;
        if (dedup.items.len > 0 and line_wise and c.start == dedup.items[dedup.items.len - 1].start) continue;
        dedup.append(self.allocator, c) catch return false;
    }

    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;

    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term); // 스냅숏이 비워지기 전에 떠 둔다(노출이 쓴다)
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = dedup.items }, &sels) catch {
        self.allocator.free(before);
        return false;
    };

    for (dedup.items, 0..) |_, k| {
        if (k < sels.items.len) sels.items[k] = editor_selection.Selection.at(inverse.changes[k].end);
    }
    // **앞뒤로 끊는다**(§3.3 "연산 종류 변경"). 뒤에만 끊으면 **붙여넣기 자신이** 앞 타이핑과 한
    // 묶음이 되어, 붙여넣기를 되돌리려는 undo 한 번에 친 것까지 사라진다 — `pushUndo`가 묶음을
    // 정하므로 그 **전에** 끊어야 붙여넣기가 자기 묶음을 갖는다(적대적 검증 2026-08-26이 잡았다).
    breakUndoGroup(term);
    pushUndo(self, term, inverse, before, before_primary, .insert);
    writeBackSelections(self, term, sels);
    // **구문 트리 통지**(§5.3). 역연산이 편집 **후** 좌표라 그대로 범위가 된다.
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = dedup.items });
    revealPrimaryCaretRows(self, term, rows_before); // 붙여넣은 자리를 보여 준다(§5.2)
    breakUndoGroup(term); // 다음 타이핑도 새 묶음이다
    self.metal_dirty = true;
    return true;
}

/// 삭제가 지우는 **단위**(§3.2 "문자/단어/줄 단위 삭제").
///
/// **이동 일습의 거울이다** — `Motion`이 커서를 옮기는 자리를 이쪽은 지운다. 그래서 경계 계산을
/// `motion.zig`가 그대로 소유하고, 여기서 다시 세지 않는다. 세면 **"⌥←로 간 자리"와 "⌥⌫가 지운
/// 자리"가 갈리고**, 사용자는 그 차이를 설명할 수 없다.
pub const DeleteUnit = enum { char, word, line_edge };

pub fn deleteText(self: *AppSession, term: *Term, backward: bool) bool {
    return deleteBy(self, term, backward, .char);
}

/// **단위로 지운다**(§3.2). 선택이 있으면 단위와 무관하게 그 선택을 지운다 — 사용자가 이미 범위를
/// 골랐는데 단위로 다시 정하면 고른 것이 무시된다.
pub fn deleteBy(self: *AppSession, term: *Term, backward: bool, unit: DeleteUnit) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;

    var iter = selections(term);
    if (iter.count() == 0) return false;
    const content = doc.file.content;

    var ranges: std.ArrayList(maru.session.editor.delta.Change) = .empty;
    defer ranges.deinit(self.allocator);
    while (iter.next()) |sel| {
        var lo = @min(sel.start(), content.len);
        var hi = @min(sel.end(), content.len);
        if (lo == hi) {
            // caret뿐 — **단위만큼** 무른다. 경계는 `motion.zig`가 소유한다(이동과 같은 자리여야
            // "⌥←로 간 곳"과 "⌥⌫가 지운 곳"이 갈리지 않는다).
            if (backward) {
                if (lo == 0) continue; // 문서 처음: 지울 것이 없다
                // **자동으로 넣은 닫는 문자를 함께 지운다**(§3.7). `(|)`에서 Backspace를 누르면
                // 여는 것만 지우고 닫는 것이 남으면 사용자가 그것을 또 지워야 한다 — 자동 닫기가
                // 만든 일을 자동 닫기가 되무르는 것이 맞다.
                //
                // **표시가 지금 caret 바로 뒤일 때만** 그렇게 한다. 사용자가 직접 친 닫는 문자는
                // 표시가 없고, 그 자리를 떠났다가 돌아온 경우도 표시가 버려져 있다.
                if (unit == .char and term.rt.editor_auto_closed_at == hi and hi < content.len) {
                    hi = nextCharBoundary(content, hi);
                }
                lo = switch (unit) {
                    .char => prevCharBoundary(content, lo),
                    .word => editor_motion.wordLeft(content, lo),
                    .line_edge => blk: {
                        // **줄 시작까지** — smart home과 같은 자리다(들여쓰기 앞이 아니라 첫 글자).
                        // 이미 첫 글자면 줄 머리까지 간다(그 함수가 토글을 소유한다).
                        const li = doc.file.lines.lineAt(lo);
                        const line = doc.file.lines.line(li) orelse break :blk lo;
                        const start = editor_motion.lineStartSmart(content, line, lo);
                        // **줄 머리에 있으면 앞 줄과 합친다.** 토글이 첫 글자를 돌려주므로 그대로 두면
                        // `lo`가 커져 아무것도 안 지우는 **죽은 키**가 된다 — `⌘⌦`가 줄 끝에서 겪던
                        // 것과 같은 함정이고, macOS는 그 자리에서 앞 개행을 지운다
                        // (적대적 검증 2026-08-27이 실측으로 잡았다).
                        break :blk if (start < lo) start else prevCharBoundary(content, lo);
                    },
                };
            } else {
                if (hi >= content.len) continue; // 문서 끝
                hi = switch (unit) {
                    .char => nextCharBoundary(content, hi),
                    .word => editor_motion.wordRight(content, hi),
                    .line_edge => blk: {
                        const li = doc.file.lines.lineAt(hi);
                        const line = doc.file.lines.line(li) orelse break :blk hi;
                        const end = editor_motion.lineEnd(line);
                        // **이미 줄 끝이면 개행 하나를 먹는다** — 안 그러면 `⌘⌦`가 죽은 키가 된다.
                        break :blk if (end > hi) end else nextCharBoundary(content, hi);
                    },
                };
            }
        }
        // **지금은 닿지 않는 방어다**(적대적 검증 2026-08-27). caret 갈래가 단위마다 반드시
        // 전진하고(`lo == 0`·문서 끝은 그 앞에서 걸러진다), 선택이 있으면 `start() <= end()`가
        // 보장되므로 여기서 `lo >= hi`가 되는 입력을 만들지 못했다 — 지운 뮤턴트가 살아남아
        // 그것을 보였다.
        //
        // 그래도 남기는 이유: **`delta`의 계약이 빈 변경을 금지하지는 않는다.** 빈 범위가 흘러가면
        // 아무것도 안 바꾸는 undo 항목이 쌓여 **undo가 헛돈다** — `DEL3`이 그 증상(빈 문서에서
        // 무동작)을 재고, 이 줄은 그 성질을 **여기서** 지킨다. 위에 같은 검사를 하나 더 두었다가
        // 중복임을 확인하고 지웠다: 방어가 둘이면 하나는 반드시 검증 밖에 남는다.
        if (lo >= hi) continue;
        ranges.append(self.allocator, .{ .start = lo, .end = hi, .text = "" }) catch return false;
    }
    if (ranges.items.len == 0) return false;

    std.mem.sort(maru.session.editor.delta.Change, ranges.items, {}, struct {
        fn lessThan(_: void, a: maru.session.editor.delta.Change, b: maru.session.editor.delta.Change) bool {
            return a.start < b.start;
        }
    }.lessThan);
    for (ranges.items, 0..) |c, i| {
        if (i > 0 and c.start < ranges.items[i - 1].end) return false; // 겹침 — 호출자 결함
    }

    var sels = selectionsForEdit(self, term) orelse return false;
    defer self.allocator.free(sels.items);

    // **편집 전 커서를 떠 둔다** — undo가 그것을 되살린다(§3.3).
    const before = self.allocator.dupe(editor_selection.Selection, sels.items) catch return false;
    const before_primary = sels.primary;

    // **편집 전 화면 맨 위를 offset으로 떠 둔다** — 뷰포트 위에서 줄이 바뀌면 줄 번호가 밀린다.
    const scroll_anchor = captureScrollAnchor(term);
    const rows_before = drawnDocLines(term); // 스냅숏이 비워지기 전에 떠 둔다(노출이 쓴다)
    const inverse = term.rt.editor_doc.?.file.apply(.{ .changes = ranges.items }, &sels) catch {
        self.allocator.free(before);
        return false;
    };

    // **친 커서는 넣은 글자 뒤로 간다 — 매핑에 맡기지 않는다.**
    // `mapOffset`의 경계 규칙은 *"삽입 지점에 정확히 있는 offset은 밀지 않는다"*인데, 그것은
    // **다른** 커서에는 맞지만 타이핑한 커서 자신에게는 틀리다(친 글자 앞에 남는다 — 실측으로
    // EDIT1·EDIT5가 그것을 잡았다). 어디로 갈지는 매핑이 아니라 **편집 연산이 정한다.**
    //
    // 역연산의 각 range가 편집 **후** 좌표로 "새로 들어간 구간"을 가리키므로, 그 끝이 곧 커서 자리다
    // (삭제는 길이가 0이라 시작 = 끝이고, 지운 자리에 커서가 선다).
    for (inverse.changes, 0..) |ic, i| {
        if (i < sels.items.len) sels.items[i] = editor_selection.Selection.at(ic.end);
    }

    pushUndo(self, term, inverse, before, before_primary, .delete);

    writeBackSelections(self, term, sels);
    // **구문 트리 통지**(§5.3). 역연산이 편집 **후** 좌표라 그대로 범위가 된다.
    const edit_span = syntax_color.spanFromInverse(inverse.changes);
    refreshAfterEdit(self, term, edit_span) catch {};
    restoreScrollAnchor(self, term, scroll_anchor, .{ .changes = ranges.items });
    // **편집한 자리를 보여 준다**(§5.2 줄 축). 앵커 보정 **뒤**여야 한다 — 보정은 "화면을 제자리에"
    // 두는 것이고 노출은 "커서를 화면 안에"이므로, 순서가 반대면 보정이 노출을 되돌린다.
    //
    // 이것이 없어서 화면 밖에서 편집하면 **자기가 어디를 고치는지 못 봤다**(적대적 검증 2026-08-26).
    revealPrimaryCaretRows(self, term, rows_before);
    return true;
}

/// `at` **앞** 글자의 시작 byte. UTF-8 이어지는 byte(`0b10xxxxxx`)를 건너뛴다.
///
/// **cluster가 아니라 code point 경계다.** 결합 문자(한글 NFD·이모지 ZWJ)는 여러 code point가
/// 한 글자로 보이는데, 그것까지 한 번에 무르려면 §3.8의 cluster 규칙이 필요하다 — 그 규칙은
/// `grapheme` 층이 소유하고 이 슬라이스 밖이다. **지금은 code point 단위이고, 깨진 UTF-8은
/// 만들지 않는다**(그것이 이 함수가 막는 것이다).
fn prevCharBoundary(bytes: []const u8, at: usize) usize {
    var i = @min(at, bytes.len);
    if (i == 0) return 0;
    i -= 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// `at` **뒤** 글자의 끝 byte.
fn nextCharBoundary(bytes: []const u8, at: usize) usize {
    if (at >= bytes.len) return bytes.len;
    const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return at + 1;
    return @min(at + n, bytes.len);
}

/// **편집 뒤에 낡는 것을 전부 다시 세운다**(§3.3 — 편집은 문서를 바꾼다).
///
/// 편집은 접힘 토글·스크롤과 **버려야 할 것이 다르다**. 저 둘은 문서가 그대로라 줄 배열이 살아
/// 있지만, 편집은 **줄 배열 자체가 문서 내용을 빌리는 슬라이스**라 내용이 바뀌면 통째로 낡는다 —
/// 남겨 두면 렌더가 해제된 자리나 옛 경계를 읽는다.
///
/// 버리는 순서가 규칙이다:
/// ⑴ 줄 배열을 다시 만든다(문서가 진실이다)
/// ⑵ 접힘 층을 다시 센다 — 들여쓰기가 바뀌었을 수 있다
/// ⑶ 보이는 줄을 다시 만든다(⑵에 달렸다)
/// ⑷ 파생 수치를 버린다(`max_cols`·시각 행 수·행 캐시)
/// ⑸ 렌더 스냅숏을 버린다 — **이것이 제일 중요하다.** `editor_hit_rows`·`editor_hit_geom`은
///    "렌더가 굳힌 것"이고 클릭이 그것을 읽는데, 편집 뒤에도 남아 있으면 **클릭이 사라진 글자의
///    자리를 답한다.** ⌘F 슬라이스가 같은 축에서 결함을 여럿 냈다.
///
/// **selection은 여기서 안 건드린다** — `delta.apply`가 이미 같은 연산에서 밀어 놓았다(§3.3).
/// 여기서 또 손대면 그 매핑을 덮어쓴다.
fn refreshAfterEdit(self: *AppSession, term: *Term, edit: ?syntax_color.EditSpan) error{OutOfMemory}!void {
    const doc = term.rt.editor_doc orelse return;

    // **문서가 바뀌면 「선택 영역 내에서만」의 범위를 버린다**(§5.1). 굳혀 둔 offset 이 이제 다른
    // 글자를 가리킨다 — 따라가게 만들면 마커·매치·범위 셋이 각각 다른 시점을 말한다. 여기가
    // 맞는 자리인 이유는 위 주석 그대로다: **편집 경로 여섯이 전부 이 함수를 지난다.**
    find_ops.dropFindSelectionRange(self);

    // **구문 트리에 편집을 알린다 — 여기가 유일한 자리다**(§5.3 `onEdit`). 제품의 편집 경로
    // 여섯이 전부 이 함수를 지나므로 통지도 한 곳이면 된다. 알리지 않으면 §5.3이 적었듯
    // *"매번 전체 재파싱"*이 되고, 실측으로 그 차이가 81배다(154KB에서 5.3ms 대 65µs).
    //
    // **줄 인덱스보다 먼저 부른다.** 아래 ⑴이 줄 배열을 갈아 끼우는데, 통지에 실리는 행·열은
    // **편집 뒤 문서**의 것이라 `doc.file.lines`가 이미 새 것이어야 한다 — `file.apply`가 그것을
    // 이미 갱신해 두었다(줄 배열 `editor_lines`와는 다른 축이다).
    if (edit) |e|
        syntax_color.onEditSpan(&term.rt.editor_syntax, doc.file.content, e, doc.file.lines)
    else
        // **`null`은 "안 바뀌었다"가 아니라 "범위를 모른다"이다.** 이 함수는 편집 뒤에만 불리므로
        // 통지를 건너뛰면 트리가 낡은 채로 남아 **색이 옛 문서를 가리킨다**. 범위를 못 만드는
        // 경로(undo·redo — 한 번에 항목 여럿)는 전체를 다시 파는 쪽이 정확하다.
        syntax_color.reparse(&term.rt.editor_syntax, doc.file.content);

    // ⑷⑸⑹은 **실패할 수 없는 연산이고, ⑵⑶이 실패해도 반드시 돌아야 한다.**
    //
    // 적대적 검증(2026-08-25)이 연 자리다. 원래는 ⑵⑶ 뒤에 순서대로 적혀 있었는데, `ensureFoldRanges`나
    // `rebuildVisible`이 할당에 실패하면 `try`가 즉시 반환해 **⑷⑸⑹이 통째로 안 돌았다** — 행 캐시가
    // 편집 **전** 계수를 든 채 `filled`로 남고 렌더 스냅숏도 낡은 채 남는다. 그것이 바로 ⑸의 주석이
    // 막으려는 상태이고, 호출자(`insertText`·`deleteText`)가 이 실패를 `catch {}`로 삼키므로
    // **편집은 성사되고 파생 상태만 낡는다** — 사용자는 클릭이 어긋나는 것으로만 겪는다.
    //
    // 닿는 경로는 OOM 하나뿐이지만 이론적이지 않다: 이 함수의 할당은 전부 줄 수에 비례하고
    // (`ranges`·`folded`·`folded_prev`·`marks`·`out_lines`), 64 MiB 상한 문서면 편집 한 번마다
    // 수십 MB를 잡는다. 무엇보다 **부분 실패라 프로세스가 살아서 계속 그린다.**
    defer {
        // ⑷ 파생 수치.
        invalidateFoldDerived(self, term);

        // ⑸ **렌더 스냅숏.** 다음 프레임이 다시 굳힐 때까지 클릭이 답할 것이 없어야 한다 —
        // 옛 값을 남기는 것보다 "아직 없다"가 낫다(hit-test가 `len == 0`을 이미 그렇게 다룬다).
        term.rt.editor_hit_rows_len = 0;
        term.rt.editor_hit_geom = .{};

        // ⑹ 스크롤이 문서 끝을 넘었을 수 있다(줄이 지워졌다면).
        if (term.rt.editor_first_line >= term.rt.editor_lines.len) {
            setEditorTop(self, term, term.rt.editor_lines.len -| 1);
        }
        self.metal_dirty = true;
    }

    // ⑴ 줄 배열 — 줄 수가 바뀌었을 수 있으므로 다시 잡는다.
    //
    // **여기서 실패하면 옛 배열을 그냥 둘 수 없다.** 줄 슬라이스는 문서 content 버퍼를 **빌리는데**,
    // `edit_doc.apply`는 새 내용을 만든 뒤 **옛 버퍼를 푼다**. 그래서 이 시점의 `editor_lines`는
    // 이미 **해제된 메모리를 가리킨다** — 남겨 두면 다음 프레임의 `editorLines(term)`가 그것을 읽는다.
    // 낡은 값이 아니라 **use-after-free**다(적대적 검증 2026-08-25).
    //
    // 놓고 비운다. 그러면 화면이 빈 문서로 보이지만 **읽을 수 없는 것을 읽지는 않는다** —
    // ⑸가 "옛 값보다 아직 없다가 낫다"고 고른 것과 같은 판단이다.
    const n = doc.file.lineCount();
    const lines = self.allocator.alloc([]const u8, n) catch |err| {
        if (term.rt.editor_lines.len > 0) self.allocator.free(term.rt.editor_lines);
        term.rt.editor_lines = &.{};
        // 보이는 줄도 같은 버퍼를 빌린다 — 함께 놓는다.
        dropFoldState(self, term);
        return err;
    };
    for (0..n) |i| lines[i] = doc.file.lineText(i) orelse "";
    if (term.rt.editor_lines.len > 0) self.allocator.free(term.rt.editor_lines);
    term.rt.editor_lines = lines;

    // ⑵⑶ 접힘 층과 보이는 줄.
    dropFoldState(self, term);
    try ensureFoldRanges(self, term);
    try rebuildVisible(self, term);
}

fn dropSelectionState(self: *AppSession, term: *Term) void {
    // 비교 뷰 선택도 함께 놓는다 — 같은 부류이고 같은 수명이다.
    if (term.rt.editor_diff_hit_rows_left.len > 0) self.allocator.free(term.rt.editor_diff_hit_rows_left);
    if (term.rt.editor_diff_hit_rows_right.len > 0) self.allocator.free(term.rt.editor_diff_hit_rows_right);
    if (term.rt.editor_diff_marks_left.len > 0) self.allocator.free(term.rt.editor_diff_marks_left);
    if (term.rt.editor_diff_marks_right.len > 0) self.allocator.free(term.rt.editor_diff_marks_right);
    if (term.rt.editor_diff_mark_buf_left.len > 0) self.allocator.free(term.rt.editor_diff_mark_buf_left);
    if (term.rt.editor_diff_mark_buf_right.len > 0) self.allocator.free(term.rt.editor_diff_mark_buf_right);
    term.rt.editor_diff_hit_rows_left = &.{};
    term.rt.editor_diff_hit_rows_right = &.{};
    term.rt.editor_diff_marks_left = &.{};
    term.rt.editor_diff_marks_right = &.{};
    term.rt.editor_diff_mark_buf_left = &.{};
    term.rt.editor_diff_mark_buf_right = &.{};
    term.rt.editor_diff_hit_len_left = 0;
    term.rt.editor_diff_hit_len_right = 0;
    term.rt.editor_diff_selection = null;
    term.rt.editor_diff_hit_geom = .{};

    if (term.rt.editor_selection_marks.len > 0) self.allocator.free(term.rt.editor_selection_marks);
    if (term.rt.editor_selection_mark_buf.len > 0) self.allocator.free(term.rt.editor_selection_mark_buf);
    term.rt.editor_selection_marks = &.{};
    term.rt.editor_selection_mark_buf = &.{};
    term.rt.editor_selection = null;
    // **나머지 커서도 같은 단위다.** 여기 빼먹으면 문서가 바뀐 뒤에도 옛 offset을 든 커서가 남아
    // 렌더가 없는 줄을 집는다 — 비교 뷰 선택이 `invalidate` 목록에서 빠져 패닉했던 그 자리다.
    clearExtraSelections(self, term);
    dropUndoState(self, term);
    if (term.rt.editor_caret_rows.len > 0) self.allocator.free(term.rt.editor_caret_rows);
    if (term.rt.editor_caret_buf.len > 0) self.allocator.free(term.rt.editor_caret_buf);
    term.rt.editor_caret_rows = &.{};
    term.rt.editor_caret_buf = &.{};

    if (term.rt.editor_find_marks.len > 0) self.allocator.free(term.rt.editor_find_marks);
    if (term.rt.editor_find_mark_buf.len > 0) self.allocator.free(term.rt.editor_find_mark_buf);
    term.rt.editor_find_marks = &.{};
    term.rt.editor_find_mark_buf = &.{};
    // **예약도 Term과 함께 사라진다.** `drawn` 필드 doc이 적은 규율("한 단위로 세우고 한 단위로
    // 지운다")의 예외를 그 규율을 적은 커밋이 만들어 두었다(적대적 검증 2026-08-24).
    term.rt.editor_find_reveal_pending = false;
}

fn dropFoldState(self: *AppSession, term: *Term) void {
    if (term.rt.editor_fold_ranges.len > 0) self.allocator.free(term.rt.editor_fold_ranges);
    if (term.rt.editor_folded_buf.len > 0) self.allocator.free(term.rt.editor_folded_buf);
    if (term.rt.editor_folded_prev.len > 0) self.allocator.free(term.rt.editor_folded_prev);
    if (term.rt.editor_fold_marks.len > 0) self.allocator.free(term.rt.editor_fold_marks);
    term.rt.editor_fold_ranges = &.{};
    term.rt.editor_folded_buf = &.{};
    term.rt.editor_folded_prev = &.{};
    term.rt.editor_fold_marks = &.{};
    term.rt.editor_folded_len = 0;
    term.rt.editor_fold_marks_len = 0;
    // **구문 승격 표시도 함께 되돌린다.** 이 함수가 접힘 무효화의 유일한 자리이므로(편집·닫기·다시
    // 열기가 전부 여기를 지난다) 표시를 여기 두면 갈릴 수 없다. 안 되돌리면 다음 문서가 **들여쓰기
    // 범위를 든 채 승격을 건너뛴다** — 구문 접힘이 조용히 사라진다.
    term.rt.editor_syntax_folds_applied = false;
    // 보이는 줄 배열도 접힘에서 나온 것이라 함께 놓는다 — 남기면 접힌 화면이 그대로 보인다.
    if (term.rt.editor_visible_lines.len > 0) self.allocator.free(term.rt.editor_visible_lines);
    if (term.rt.editor_visible_numbers.len > 0) self.allocator.free(term.rt.editor_visible_numbers);
    term.rt.editor_visible_lines = &.{};
    term.rt.editor_visible_numbers = &.{};
}

/// 접힘이 바뀌면 **보이는 줄이 달라지므로** 그것으로부터 나온 값이 전부 옛 것이다.
///
/// 가장 긴 줄이 접혀 숨어도 가로 상한이 그대로면 빈 곳으로 밀린다 — 실측: 2,000열짜리 줄이 숨었는데
/// `max_cols`가 2000이라 `first_col`이 1911까지 갔다(화면엔 두 줄뿐. 적대적 검증 2026-08-17).
/// 렌더가 싣는 값들도 옛 배열의 것이라 함께 버린다.
fn invalidateFoldDerived(self: *AppSession, term: *Term) void {
    term.rt.editor_max_cols = 0;
    term.rt.editor_max_cols_right = 0;
    term.rt.editor_first_col = 0;
    term.rt.editor_first_col_right = 0;
    term.rt.editor_total_visual_rows = 0;
    term.rt.editor_max_top_line = 0;
    term.rt.editor_max_top_piece = 0;
    term.rt.editor_first_piece = 0;
    // **줄 배열의 주소·길이만으로는 이 변화를 못 잡는다.** 보이는 줄은 미리 잡아 둔 한 버퍼의 앞부분을
    // 쓰므로, 레벨 접기를 갈아 끼웠을 때 접힌 줄 수가 우연히 같으면 주소도 길이도 그대로다 — 내용만
    // 다른 그 상태를 캐시가 "맞다"고 읽는다. 접힘을 바꾸는 곳은 여기 하나이므로 여기서 버린다.
    term.rt.editor_row_cache.filled = false;
    // **시각 좌표를 든 것들도 여기서 죽는다**(§3.2a) — 뷰 폭·랩·접힘·탭 폭이 바뀌면 옛 시각 열은
    // 다른 글자를 가리킨다. `goal` 과 열 원본은 **같은 사건에 함께** 죽어야 한다: 하나만 비우면
    // 다음 세로 이동과 다음 사각형이 서로 다른 좌표계를 본다.
    //
    // **`setEditorTabWidth` 가 이것을 안 하고 있었다**(적대적 검증 2026-09-05 — 계약의 무효화 목록에도
    // 탭 폭이 빠져 있었다). 접힘 층만 버리고 나가면 탭 폭 4→8 뒤의 목표 열이 옛 값 그대로다.
    invalidateVisualCoords(term);
    self.metal_dirty = true;
}

/// 시각 열에 기댄 값을 전부 버린다 — 열 원본과 양끝 목표 열(§3.2a·§3.2).
fn invalidateVisualCoords(term: *Term) void {
    term.rt.editor_column_anchor = null;
    if (term.rt.editor_selection) |*s| {
        s.goal = .none;
        s.anchor_goal = .none;
    }
    for (term.rt.editor_extra_selections) |*s| {
        s.goal = .none;
        s.anchor_goal = .none;
    }
}

/// 지금 이 Term에서 접힘이 성립하지 않는가. **접기·펼치기가 여기서 거절한다.**
///
/// 이유가 랩과 같다(§4.1d 알려진 구멍): 비교는 **좌우 행이 짝을 이뤄 같은 높이에 서야** 성립하는데,
/// 한쪽 행만 접으면 그 아래가 통째로 어긋난다. 게다가 렌더는 diff일 때 `st.left_texts`를 그리므로
/// **접힘 상태를 만들어도 화면이 그대로다** — 성공을 돌려주고 아무 일도 안 일어나면 사용자는 이유를
/// 알 수 없다(적대적 검증 2026-08-17이 그 상태를 잡았다).
///
/// **판정은 원본 유무 하나로 한다.** 초판은 `view == .compare`로 물었는데, diff는 `.loading`·
/// `.unavailable`·`.unchanged`도 상태이고 그때도 렌더가 diff 경로를 탄다 — 그 셋이 거절을 그냥
/// 지나가 같은 거짓 성공이 남아 있었다(적대적 검증 2026-08-17). 접힘의 원본은 `foldSourceLines`
/// 하나이므로, 그것이 비었는지를 묻는 편이 뷰 종류를 나열하는 것보다 갈릴 여지가 없다.
///
/// VSCode의 diff가 "바뀌지 않은 구간 접기"를 제공하지만 그것은 **좌우를 함께 접는 다른 기능**이고,
/// 들여쓰기 접힘을 한쪽에 적용하는 것과 다르다.
fn foldsUnavailable(term: *Term) bool {
    return foldSourceLines(term).len == 0;
}

/// 지금 화면 맨 위가 **문서 몇째 줄**인가(0-based). 접힘이 바뀌면 첨자의 뜻이 달라지므로, 위치를
/// 옮길 때는 이 문서 좌표로 건너간다.
fn topDocLine(term: *Term) usize {
    const nums = term.rt.editor_visible_numbers;
    if (nums.len == 0) return term.rt.editor_first_line; // 접힌 것이 없다 — 첨자가 곧 문서 줄이다
    if (term.rt.editor_first_line >= nums.len) return term.rt.editor_first_line;
    const v = nums[term.rt.editor_first_line] orelse return term.rt.editor_first_line;
    return v - 1; // gutter는 1-based로 담는다
}

/// 접힘이 바뀐 뒤 **보던 자리로 되돌린다.** 그 줄이 숨었으면 그것을 품은 머리 줄로 간다(바로 앞의
/// 보이는 줄이 곧 머리다 — 숨는 구간은 머리 바로 뒤에 붙는다).
///
/// **0으로 되돌리면 안 된다.** 3만 줄 문서의 9,001번 줄을 보다가 전체 접기를 하면 **1번 줄로 튀었다**
/// (실측. 적대적 검증 2026-08-17). Vim `zM`도 VSCode "Fold All"도 보던 자리를 지킨다. 상한을 넘는
/// 경우는 `clampScrollToGeometry`가 그리기 직전에 처리하므로 여기서 방어할 것이 없다.
fn restoreTop(term: *Term, doc_line: usize) void {
    const nums = term.rt.editor_visible_numbers;
    if (nums.len == 0) { // 다 펼쳤다 — 문서 줄이 곧 첨자다
        term.rt.editor_first_line = doc_line;
        return;
    }
    const want: u32 = std.math.cast(u32, doc_line + 1) orelse std.math.maxInt(u32);
    // 번호는 오름차순이다(문서 순서로 담는다). `want` 이하인 **마지막** 자리를 찾는다.
    var lo: usize = 0;
    var hi: usize = nums.len;
    var best: usize = 0;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const v = nums[mid] orelse {
            hi = mid; // 꼬리 채움(번호 없음)은 없는 것으로 본다
            continue;
        };
        if (v <= want) {
            best = mid;
            lo = mid + 1;
        } else hi = mid;
    }
    term.rt.editor_first_line = best;
}

/// 그 **문서 줄**의 gutter 표식. 접을 수 있는 머리면 화살표가 서고, 지금 접혀 있으면 오른쪽을 본다.
///
/// **범위와 접힘 상태 둘 다 이진 탐색으로 본다** — 줄마다 목록을 훑으면 문서 × 범위가 되고, 12만 줄
/// 문서에서 그 모양이 이미 한 번 성능 결함으로 나왔다(`rebuildVisible`의 구간 커서 주석).
fn markFor(term: *Term, line: u32) chrome_editor.gutter.Fold {
    if (!containsSorted(term.rt.editor_fold_ranges, line)) return .none;
    return if (std.sort.binarySearch(u32, foldedHeads(term), line, orderU32) != null) .collapsed else .open;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// 범위 목록(머리 줄 오름차순)에 그 머리가 있는가.
fn containsSorted(ranges: []const maru.session.editor.fold.Range, line: u32) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid].head == line) return true;
        if (ranges[mid].head < line) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// 그리는 줄들과 **같은 축**의 접힘 표식. 비어 있으면 `null`(접힘 칸이 빈다).
fn foldMarks(term: *Term) ?[]const chrome_editor.gutter.Fold {
    const len = term.rt.editor_fold_marks_len;
    return if (len > 0) term.rt.editor_fold_marks[0..len] else null;
}

/// 접혀 있으면 **원래 줄 번호** 배열을, 아니면 `null`(프레임이 `first_line + n + 1`로 센다).
fn foldNumbers(term: *Term) ?[]const ?u32 {
    return if (term.rt.editor_visible_numbers.len > 0) term.rt.editor_visible_numbers else null;
}

/// 지금 접혀 있는 머리 줄들(오름차순).
pub fn foldedHeads(term: *const Term) []const u32 {
    return term.rt.editor_folded_buf[0..term.rt.editor_folded_len];
}

/// 활성 Term이 편집기면 그 뷰의 랩을 뒤집는다. 아니면 무동작(true를 안 돌려주므로 호출자가 안다).
///
/// **override를 세우는 방식이다** — 지금 보이는 값의 반대를 뷰에 박는다. config를 바꾸지 않는 이유는
/// 그것이 **기본값**이고(다음에 여는 뷰가 따른다) 토글은 이 뷰의 일이기 때문이다.
pub fn toggleWrap(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const now = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap;
    term.rt.editor_wrap = !now;
    // 랩이 갈리면 시각 행·열이 통째로 바뀐다(§3.2a) — 접힘 파생과 같은 사건이다.
    invalidateVisualCoords(term);
    // **접힘이 달라지면 시각 행 수도 달라진다.** 렌더가 센 값은 옛 랩의 것이고 스크롤 상한이 그것을
    // 읽으므로, 다시 그리기 전의 한 번을 위해 버린다(다음 프레임이 곧바로 채운다).
    term.rt.editor_total_visual_rows = 0;
    // **조각도 버리지 않는다** — 랩을 다시 켜면 돌아갈 자리다(`effectiveFirstPiece`가 렌더에 0을 넘긴다).
    // **가로 위치는 버리지 않는다.** 랩 중에는 렌더가 안 쓰고(`effectiveFirstCol`), 랩을 끄면 보던
    // 자리로 돌아온다. 상한을 넘어 있으면 `clampScrollToGeometry`가 그리기 직전에 되돌린다.
    self.metal_dirty = true;
    return true;
}

/// 편집기 Term이 소유한 것을 놓는다. `destroyTerm`이 kind로 분기해 부른다.
pub fn releaseEditorTerm(self: *AppSession, term: *Term) void {
    editor_diff_ops.release(self, term); // N1.5 diff 행·줄 배열(entry 버퍼를 빌린다)
    if (term.rt.editor_doc) |*d| d.deinit(self.allocator);
    term.rt.editor_doc = null;
    // **구문 트리도 문서와 함께 죽는다.** tree-sitter의 파서·트리는 자기 `malloc`에서 오므로
    // 여기서 안 놓으면 `std.testing.allocator`가 못 보는 누수가 된다(`SYN10`이 그 자리를 잰다).
    term.rt.editor_syntax.deinit(self.allocator);
    if (term.rt.editor_lines.len > 0) self.allocator.free(term.rt.editor_lines);
    term.rt.editor_lines = &.{};
    // 체인 마디의 열 범위도 문서와 함께 죽는다(§7.5) — 렌더가 채우는 파생값이라 문서가 없으면
    // 가리킬 것이 없다. `SP18` 이 이 자리를 잡았다(픽스처가 심은 값이 누수로 드러났다).
    term.rt.editor_crumb_spans.deinit(self.allocator);
    if (term.rt.editor_hit_rows.len > 0) self.allocator.free(term.rt.editor_hit_rows);
    term.rt.editor_hit_rows = &.{};
    if (term.rt.editor_hit_lines.len > 0) self.allocator.free(term.rt.editor_hit_lines);
    term.rt.editor_hit_lines = &.{};
    // **기하도 함께 지운다** — 셋은 한 단위다(`storeHitRows`가 함께 세운다). `rows_len = 0`이 이미
    // 클릭을 막지만, 세우는 쪽만 한 단위이고 놓는 쪽이 아니면 그 규율이 반쪽이 된다.
    term.rt.editor_hit_geom = .{};
    term.rt.editor_hit_rows_len = 0;
    if (term.rt.editor_path) |p| self.allocator.free(p);
    setEditorPreedit(self, term, ""); // 조합 중이던 글자(N3)
    dropFoldState(self, term); // 접힘 층을 통째로 놓는다(그 함수 doc)
    dropSelectionState(self, term);
    if (term.rt.editor_row_cache.prefix.len > 0) self.allocator.free(term.rt.editor_row_cache.prefix);
    term.rt.editor_row_cache = .{ .prefix = &.{} };
    term.rt.editor_path = null;
}

const testing = std.testing;
const builtin = @import("builtin");

// ── `appendPaneFrame` — 편집기 pane 한 프레임의 기하·합성 계약 ────────────────────────────────
//
// **이 테스트들이 증명하는 것**: 편집기가 그린 배경이 자기 본문을 덮지 않고, 본문이 pane의 body에
// 선다는 것. 왜 중요한가 — 둘 다 **조용히** 틀린다. 배경 layer가 뒤집혀도 op·셀은 정상으로 나오고
// 좌표도 맞아, 실패는 오직 화면에서만 보인다(실제로 그 상태로 커밋됐고 캡처 픽셀을 재고서야 잡혔다).
// 사각도 같다 — leaf 전체를 쓰면 탭 바를 덮고 hit-test와 갈리지만 어떤 단위 테스트도 안 깨진다.

/// 헤드리스 세션 + 실제 파일을 연 편집기 Term. 렌더 상태(셀 크기·padding)는 init이 안 세우므로 준다.
/// 그린 셀 중에 이 코드포인트가 있는가 — 조합 글자가 **화면에 닿았는지**를 재는 유일한 방법이다.
fn drawnHasCodepoint(dl: renderer.DrawList, cp: u21) bool {
    for (dl.cells) |c| if (c.codepoint == cp) return true;
    return false;
}

test "IME5 후보창은 조합 글자 아래에 선다 — pane 구석이 아니라 (N3)" {
    // 편집기 Term은 코어가 sentinel이라 `imeCursorRect`의 터미널 갈래를 못 쓴다. 그대로 두면
    // **pane 좌상단**으로 떨어지는데, 한글은 후보창을 보며 고르는 입력이라 그 어긋남이 곧바로 걸린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;
    if (appendPaneFrame(fx.session, fx.leaf_rect, term)) |*d| { // pane 사각을 세운다
        var drawn = d.*;
        drawn.dl.deinit(allocator);
    }

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);

    // ⑴ 줄 머리(offset 0)면 본문 왼쪽 끝이다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    const head = editorImeCaretRect(fx.session, term) orelse return error.NoCaretRect;

    // ⑵ 같은 줄 다섯 글자 뒤면 **다섯 칸 오른쪽**이다 — 구석 고정이면 둘이 같아진다.
    term.rt.editor_selection = editor_selection.Selection.at(5);
    const mid = editorImeCaretRect(fx.session, term) orelse return error.NoCaretRect;
    try testing.expectEqual(head.y, mid.y);
    try testing.expectEqual(head.x + 5 * @as(i32, @intCast(fx.session.cell_width_px)), mid.x);

    // ⑶ 둘째 줄이면 **한 행 아래**다.
    term.rt.editor_selection = editor_selection.Selection.at(13); // "const a = 1;\n" 다음
    const next_line = editorImeCaretRect(fx.session, term) orelse return error.NoCaretRect;
    try testing.expectEqual(head.y + @as(i32, @intCast(fx.session.cell_height_px)), next_line.y);

    // ⑷ **조합 중이면 caret이 아니라 조합을 시작한 자리**를 가리킨다 — 조합 중에 caret이 다른
    //    곳을 가리키게 되어도 후보창은 글자 아래에 남아야 한다.
    term.rt.editor_selection = editor_selection.Selection.at(5);
    setEditorPreedit(fx.session, term, "\xed\x95\x9c");
    term.rt.editor_selection = editor_selection.Selection.at(0);
    const while_composing = editorImeCaretRect(fx.session, term) orelse return error.NoCaretRect;
    try testing.expectEqual(mid.x, while_composing.x);

    // ⑸ pane 구석이 아니다(그 폴백과 실제로 다르다).
    try testing.expect(while_composing.x != @as(i32, @intCast(fx.session.active_pane_rect.x)) or
        while_composing.y != @as(i32, @intCast(fx.session.active_pane_rect.y)));
    _ = body;
}

test "IME1 조합 중 글자는 화면에 뜨고 문서에는 안 들어간다 (N3 §11)" {
    // **실측으로 연 자리다**(적대적 검증 2026-08-27): 편집기 Term의 코어는 1×1 sentinel이라
    // 조합 글자가 거기 얹히면 화면에 닿지 않았다 — 한글을 치면 조합 중에는 아무것도 안 보이고
    // 음절이 확정될 때만 툭 나타났다. 확정 텍스트는 이미 문서로 가고 있었고 **조합만 갈 곳이
    // 없었다.**
    //
    // 그리고 **문서에는 안 들어가야 한다.** 조합은 확정이 아니므로 버퍼에 넣으면 undo·저장·검색이
    // 그것을 진짜 내용으로 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;
    const before = try allocator.dupe(u8, term.rt.editor_doc.?.file.content);
    defer allocator.free(before);

    term.rt.editor_selection = editor_selection.Selection.at(0);
    setEditorPreedit(fx.session, term, "\xed\x95\x9c"); // 조합 "한"(U+D55C)

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(drawnHasCodepoint(drawn.dl, 0xD55C)); // 화면에 있다
    try testing.expectEqualStrings(before, term.rt.editor_doc.?.file.content); // 문서는 그대로다
}

test "IME2 조합은 조합을 시작한 자리에 그려진다 (N3 §11)" {
    // 줄 머리에 그리면 caret이 중간일 때 **글자가 딴 데 뜬다**. 확정 텍스트가 이미 "조합을 시작한
    // 곳"으로 가는 규칙을 지키므로(§3.3 IME 고정), 조합 글자도 같은 자리여야 둘이 안 갈린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;

    // 첫 줄이 "const a = 1;" — 5번째 byte(=`t` 뒤)에서 조합을 시작한다.
    term.rt.editor_selection = editor_selection.Selection.at(5);
    setEditorPreedit(fx.session, term, "\xed\x95\x9c");
    try testing.expectEqual(@as(usize, 5), term.rt.editor_preedit_at);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 조합 글자가 선 셀의 **열**을 찾는다. 줄 머리(gutter 다음 첫 글자)면 실패한다.
    var found_col: ?u16 = null;
    var const_t_col: ?u16 = null;
    for (drawn.dl.cells) |c| {
        if (c.codepoint == 0xD55C) found_col = c.col;
        if (c.row == 0 and c.codepoint == 't') const_t_col = c.col; // "const"의 t
    }
    const hangul_col = found_col orelse return error.PreeditNotDrawn;
    const t_col = const_t_col orelse return error.AnchorNotDrawn;
    try testing.expectEqual(t_col + 1, hangul_col); // `t` 바로 뒤다
}

test "IME3 조합이 끝나면 화면에서도 사라진다 (N3)" {
    // 남으면 확정 글자와 조합 글자가 **둘 다** 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;
    term.rt.editor_selection = editor_selection.Selection.at(0);

    setEditorPreedit(fx.session, term, "\xed\x95\x9c");
    setEditorPreedit(fx.session, term, ""); // 입력기가 조합을 거둔다
    try testing.expectEqual(@as(usize, 0), term.rt.editor_preedit.len);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(!drawnHasCodepoint(drawn.dl, 0xD55C));
}

test "IME4 조합 자리는 시작할 때 한 번만 잡는다 (N3)" {
    // 'ㅎ' → '하' → '한'은 **같은 자리에서** 갈아 끼우는 것이다. 갱신마다 caret을 다시 읽으면
    // 자리가 흔들리고, 그러면 확정 텍스트가 조합이 보이던 곳과 다른 데로 간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;

    term.rt.editor_selection = editor_selection.Selection.at(5);
    setEditorPreedit(fx.session, term, "\xe3\x85\x8e"); // "ㅎ"
    try testing.expectEqual(@as(usize, 5), term.rt.editor_preedit_at);

    // 조합 중에 커서가 어떤 이유로든 움직여도 자리는 그대로다.
    term.rt.editor_selection = editor_selection.Selection.at(9);
    setEditorPreedit(fx.session, term, "\xed\x95\x9c"); // "한"
    try testing.expectEqual(@as(usize, 5), term.rt.editor_preedit_at);
}

test "IME7 이어 치는 한글: 조합 글자는 방금 확정한 글자 뒤에 선다" {
    // **음절 경계**를 아무도 안 봤다. IME4는 한 음절 안(ㅎ→하→한)만 본다.
    // 실제 키 트랜잭션은 `insertText`(확정)를 **큐에 쌓고** `imeEnd`에서야 문서에 넣는데,
    // 그 사이에 `setMarkedText`(다음 조합)가 온다 — 그때 caret은 아직 확정 앞이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;

    term.rt.editor_selection = editor_selection.Selection.at(0);
    setEditorPreedit(fx.session, term, "\xea\xb0\x80"); // 조합 "가"

    // 다음 키: 입력기가 "가"를 확정하고 "나" 조합을 시작한다. 확정은 아직 큐에 있다.
    setEditorPreedit(fx.session, term, ""); // 조합 해제
    setEditorPreedit(fx.session, term, "\xeb\x82\x98"); // 새 조합 "나"
    _ = insertText(fx.session, term, "\xea\xb0\x80"); // imeEnd가 이제 확정을 넣는다

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    var col_ga: ?u16 = null;
    var col_na: ?u16 = null;
    for (drawn.dl.cells) |c| {
        if (c.row == 0 and c.codepoint == 0xAC00) col_ga = c.col; // 가
        if (c.row == 0 and c.codepoint == 0xB098) col_na = c.col; // 나
    }
    const ga = col_ga orelse return error.CommittedNotDrawn;
    const na = col_na orelse return error.PreeditNotDrawn;
    // 조합 글자는 확정 글자 **뒤**에 서야 한다. 한글은 EAW wide라 두 칸을 차지한다.
    try testing.expectEqual(ga + 2, na);
}

const PaneFixture = struct {
    session: *AppSession,
    term: *Term,
    dir: testing.TmpDir,
    /// `paneGeometry`가 실제로 줄여야 할 leaf 사각. 아래 테스트가 body·grid와 이것을 대조한다.
    leaf_rect: maru.session.SplitRect = .{ .x = 100, .y = 50, .w = 800, .h = 600 },

    fn init(allocator: std.mem.Allocator) !PaneFixture {
        const io = std.testing.io;
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(io, .{ .sub_path = "doc.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try dir.dir.realPath(io, &root_buf)];
        const path = try std.fs.path.join(allocator, &.{ root, "doc.zig" });
        defer allocator.free(path);

        const session = try allocator.create(AppSession);
        errdefer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = app_session_mod.abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
        });
        errdefer session.deinit();
        session.cell_width_px = 8;
        session.cell_height_px = 16;
        // **padding을 0이 아닌 값으로 둔다.** 0이면 `body`와 `grid`가 같아져 둘 중 무엇을 골라도
        // 테스트가 통과한다 — 판정이 성립하려면 셋이 실제로 달라야 한다.
        session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };

        const term = try openPathInActivePane(session, path);
        return .{ .session = session, .term = term, .dir = dir };
    }

    fn deinit(self: *PaneFixture, allocator: std.mem.Allocator) void {
        self.session.deinit();
        allocator.destroy(self.session);
        self.dir.cleanup();
    }
};

test "랩 토글은 뷰 override를 세우고 config를 안 건드린다" {
    // **뷰별 상태다**(VSCode `⌥Z`와 같은 축) — 전역으로 두면 파일 하나를 랩해 보려다 열린 편집기가
    // 전부 바뀐다. config는 **기본값**으로 남아 새로 여는 뷰가 그것을 따라야 하므로, 토글이 config를
    // 건드리지 않는 것까지 함께 본다(건드리면 다음에 여는 파일의 기본이 조용히 뒤집힌다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const config_default = fx.session.loaded_config.config.editor.wrap;
    try testing.expect(fx.term.rt.editor_wrap == null); // 시작은 config 추종

    try testing.expect(toggleWrap(fx.session));
    try testing.expectEqual(!config_default, fx.term.rt.editor_wrap.?);
    try testing.expectEqual(config_default, fx.session.loaded_config.config.editor.wrap); // config 불변

    try testing.expect(toggleWrap(fx.session)); // 다시 누르면 되돌아온다
    try testing.expectEqual(config_default, fx.term.rt.editor_wrap.?);
}

test "편집기가 아닌 Term에서는 랩 토글이 무동작이다" {
    // 커맨드 팝업은 어디서든 부를 수 있다. 터미널이 활성일 때 이 액션이 무언가를 바꾸면
    // "아무 일도 안 일어나야 하는데 상태가 움직인" 것이라 다음 편집기 뷰가 이상해진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const shell = pane_ops.activePane(fx.session).terms.items[0];
    try testing.expect(shell.kind != .editor);
    term_ops.focusTerm(fx.session, 0); // 터미널을 활성으로
    try testing.expect(!toggleWrap(fx.session));
    try testing.expect(fx.term.rt.editor_wrap == null); // 편집기 뷰 상태도 그대로
}

test "편집기 배경은 셀 패스 앞 층에 실린다 — 뒤 층이면 자기 본문을 덮는다" {
    // `maru_metal_renderer.m`은 quad를 네 패스로 그리고 그중 `layers.bottom`만 셀 패스 **앞**에 온다.
    // 나머지는 셀 뒤라 배경이 글자를 덮는다 — 그 파일 주석이 이미 그렇게 적어 두었는데도 `3`이
    // 실려 편집기 본문이 통째로 안 보였다. 이 테스트가 그 뮤턴트를 잡는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // ⑴ 배경이 실제로 나왔다. quad가 0이면 아래 for가 공허하게 통과한다.
    try testing.expect(fx.session.gpu_quads.items.len > 0);
    // **리터럴로 판정한다.** `layers.bottom`으로 비교하면 그 상수를 3으로 바꿔도 통과한다 —
    // 판정 대상과 기대값이 같은 출처면 테스트가 아니라 항등식이다.
    for (fx.session.gpu_quads.items) |q| try testing.expectEqual(@as(u32, 2), q.layer);

    // ⑵ **그리고 글자도 나왔다.** 이것이 없으면 배경만 칠하고 본문을 안 그리는 상태(=우리가 고친
    //    바로 그 화면)도 초록이 된다 — 두 축을 함께 봐야 판정이 된다.
    try testing.expect(drawn.dl.cells.len > 0);
}

test "편집기 본문 사각은 pane body에서 내용 여백만 들어간다" {
    // **세 사각 중 하나를 고르는 판정이다.** leaf 전체를 쓰면 배경이 탭 바를 덮고, `grid`를 쓰면
    // 창 padding만큼 안쪽으로 들어가 pane 안에 쓰이지 않는 띠가 생긴다(사용자 결정: 편집기는 그
    // 여백을 쓰지 않는다). 그래서 `body`가 아닌 **둘 다**와 다름을 함께 못박는다 — 하나만 보면
    // 나머지로 잘못 바꿔도 초록이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const g = pane_ops.paneGeometry(fx.session, fx.leaf_rect);
    const inset = chrome_editor.frame.content_inset_px;
    // **대조군 먼저.** `body`·`grid`·leaf가 서로 다른 픽스처라야 판정이 성립한다(픽스처는 바 높이와
    // 0이 아닌 창 padding을 둘 다 세운다).
    try testing.expect(g.body.y != fx.leaf_rect.y); // 탭 바만큼 내려갔다
    try testing.expect(g.body.x != g.grid.x or g.body.w != g.grid.w); // 창 padding만큼 다르다

    // **`grid`가 아니라 `body`에서 출발한다**(창 padding 미적용) — 다만 내용은 뷰 자기 여백만큼
    // 들어간다(포커스 테두리가 셀 위 층이라 첫 행을 덮는다). 그래서 셋 중 어느 것과도 같지 않다.
    try testing.expectEqual(g.body.x + inset, drawn.rect.x);
    try testing.expectEqual(g.body.y + inset, drawn.rect.y);
    try testing.expectEqual(g.body.w - inset * 2, drawn.rect.w);
    try testing.expectEqual(g.body.h - inset * 2, drawn.rect.h);
    try testing.expect(drawn.rect.x != g.grid.x or drawn.rect.w != g.grid.w);
}

test "편집기 배경만 창 투명도를 따른다 — 스크롤바 알파는 그대로다" {
    // 터미널은 배경을 그리지 않고 **clear color**가 그 자리인데, 그 alpha에 `window.opacity`가 곱해진다.
    // 편집기만 불투명 solid로 덮으면 투명 배경 창에서 이 pane만 데스크톱이 안 비쳐 두 뷰가 갈린다.
    //
    // **판정을 "같은 프레임을 두 투명도로 그려 비교"로 한다.** 알파 상수와 비교하면 그 상수를 바꿔도
    // 통과하고, "반투명인 quad가 하나라도 있나"로 보면 **스크롤바까지 흐려지는 뮤턴트를 놓친다**
    // (실제로 놓쳤다 — thumb의 원래 알파가 0x66이라 곱해도 배경 알파와 달라 대조군처럼 보였다).
    // 두 실행의 알파 배열을 원소별로 비교하면 "무엇이 바뀌었고 무엇이 안 바뀌었나"가 그대로 나온다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 스크롤바가 실제로 나와야 대조군이 산다. 픽스처 문서는 4줄이므로 보이는 행이 그보다 적도록
    // 높이를 잡는다 — 바 높이는 테마가 정하므로 재서 더한다.
    const bar_h = pane_ops.paneBarHeightPx(fx.session);
    const short: maru.session.SplitRect = .{ .x = 100, .y = 50, .w = 400, .h = bar_h + 2 * 16 };

    var alphas_full: [8]u8 = undefined;
    var n_full: usize = 0;
    fx.session.appearance.window_opacity = 1.0;
    fx.session.gpu_quads.clearRetainingCapacity();
    {
        var d = appendPaneFrame(fx.session, short, fx.term) orelse return error.EditorPaneDidNotDraw;
        defer d.dl.deinit(allocator);
        for (fx.session.gpu_quads.items) |q| {
            if (n_full == alphas_full.len) break;
            alphas_full[n_full] = @intCast(q.fill_color0 >> 24);
            n_full += 1;
        }
    }
    try testing.expect(n_full >= 2); // 전제: 배경 + 스크롤바가 둘 다 나왔다

    fx.session.appearance.window_opacity = 0.5;
    fx.session.gpu_quads.clearRetainingCapacity();
    var d2 = appendPaneFrame(fx.session, short, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer d2.dl.deinit(allocator);
    try testing.expectEqual(n_full, fx.session.gpu_quads.items.len); // 같은 프레임이어야 비교가 성립한다

    var changed: usize = 0;
    for (fx.session.gpu_quads.items, 0..) |q, i| {
        const a: u8 = @intCast(q.fill_color0 >> 24);
        if (a == alphas_full[i]) continue;
        changed += 1;
        // 바뀐 것은 배경 하나뿐이고, 정확히 창 투명도만큼이어야 한다.
        try testing.expectEqual(@as(u8, 255), alphas_full[i]);
        try testing.expectEqual(workspace_ops.windowOpacityByte(fx.session), a);
    }
    try testing.expectEqual(@as(usize, 1), changed); // 하나만 — 스크롤바는 그대로다
}

test "편집기 배경 quad와 글자 셀은 같은 자리에 선다 — origin이 갈리면 배경만 옮겨간다" {
    // 배경은 GpuQuad(절대 px), 글자는 셀(origin + col×cw)이라 **서로 다른 경로로** 화면에 간다.
    // 두 origin이 갈리면 배경이 엉뚱한 데 칠해지는데, 각자만 보는 테스트로는 안 잡힌다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // **배경은 내용 사각이 아니라 pane body 전체를 덮는다**(§4.1b "뷰포트 전체를 덮는다") — 내용은
    // 여백만큼 안쪽이므로 배경 quad는 그 여백만큼 **밖으로** 나가 있어야 한다. 둘이 같아지면
    // 가장자리에 pane 배경이 비치는 띠가 생긴다.
    const inset: f32 = @floatFromInt(chrome_editor.frame.content_inset_px);
    const bg = fx.session.gpu_quads.items[0];
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.x)) - inset, bg.x);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.y)) - inset, bg.y);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.w)) + inset * 2, bg.w);
    try testing.expectEqual(@as(f32, @floatFromInt(drawn.rect.h)) + inset * 2, bg.h);
}

test "편집기가 아닌 Term은 이 경로를 타지 않는다 — 터미널 pane을 덮어쓰지 않는다" {
    // `appendPaneFrame`은 모든 leaf에 대해 불린다. kind 가드가 없으면 터미널 pane 위에 편집기
    // 배경을 칠하게 되고, 그 pane의 셀은 그대로라 "터미널이 흐려졌다"로만 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const shell = pane_ops.activePane(fx.session).terms.items[0];
    try testing.expect(shell.kind != .editor); // 픽스처 전제: 첫 Term은 편집기가 아니다
    fx.session.gpu_quads.clearRetainingCapacity();
    try testing.expect(appendPaneFrame(fx.session, fx.leaf_rect, shell) == null);
    try testing.expectEqual(@as(usize, 0), fx.session.gpu_quads.items.len); // quad도 안 남긴다
}

test "split에서 편집기는 자기 leaf에만 그린다 — 옆 터미널 pane을 침범하지 않는다" {
    // `appendPaneFrame`은 leaf마다 불린다. 사각을 인자가 아니라 세션 상태(활성 pane 등)에서
    // 가져오는 순간 split에서 두 leaf가 같은 자리에 그려지는데, 단일 pane 테스트로는 그것이
    // 절대 드러나지 않는다 — 단일 pane에서는 "활성 leaf"와 "이 leaf"가 늘 같기 때문이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 좌/우로 나눈 두 leaf 사각. 실제 split 트리를 세우지 않고 사각만 주는 이유는, 이 함수의
    // 계약이 "받은 사각 안에만 그린다"이지 트리 순회가 아니기 때문이다.
    const left: maru.session.SplitRect = .{ .x = 100, .y = 50, .w = 400, .h = 600 };
    const right: maru.session.SplitRect = .{ .x = 500, .y = 50, .w = 400, .h = 600 };

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, left, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 왼쪽 leaf 안에 완전히 들어간다 — 오른쪽 leaf로 한 픽셀도 넘지 않는다.
    try testing.expect(drawn.rect.x >= left.x);
    try testing.expect(drawn.rect.x + drawn.rect.w <= left.x + left.w);
    try testing.expect(drawn.rect.x + drawn.rect.w <= right.x);
    for (fx.session.gpu_quads.items) |q| {
        try testing.expect(q.x >= @as(f32, @floatFromInt(left.x)));
        try testing.expect(q.x + q.w <= @as(f32, @floatFromInt(right.x)));
    }

    // 그리고 **같은 Term을 오른쪽 leaf로 그리면 오른쪽에 선다** — 사각이 인자에서 오지 세션
    // 상태에서 오지 않는다는 뜻이다. 이 대조가 없으면 좌표를 어디서 얻든 위 단언은 통과한다.
    var drawn_r = appendPaneFrame(fx.session, right, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn_r.dl.deinit(allocator);
    try testing.expectEqual(drawn.rect.x + 400, drawn_r.rect.x);
    try testing.expectEqual(drawn.rect.y, drawn_r.rect.y); // 세로는 그대로
}

test "사각이 0으로 접히면 그리지 않는다 — 빈 DrawList를 흘리지 않는다" {
    // padding이 pane보다 크거나 창이 접히는 순간이 실재한다. 그때 op을 내면 셀 격자가 0열/0행이라
    // lowering이 실패하거나 빈 프레임이 합성에 들어간다.
    //
    // **이 테스트는 위쪽 `rect.w == 0` 가드를 지키지 못한다**(적대적 검증 실측): 그 가드를 지워도
    // `buildTextDrawList`가 `cols == 0`에서 `NoSpace`를 내 결국 같은 `null`이 나오고 quad도 안 남는다.
    // 즉 여기서 고정하는 것은 **경계에서의 관측 가능한 동작**이지 특정 분기가 아니다. 가드는 그래도
    // 남긴다 — 없으면 퇴화한 사각으로 프레임 조립이 한 번 돌고, "0이면 안 그린다"가 하류 에러의
    // 부수효과가 되어 계약이 코드에 안 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.session.gpu_quads.clearRetainingCapacity();
    try testing.expect(appendPaneFrame(fx.session, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, fx.term) == null);
    try testing.expectEqual(@as(usize, 0), fx.session.gpu_quads.items.len);
}

test "스크롤바 gutter가 폭을 다 먹는 좁은 pane에서도 죽지 않는다" {
    // `rect.w`가 0은 아니지만 `metrics.gutterPx()`(12px)보다 좁으면 `total_cols`가 0으로 접힌다.
    // 그 뒤 `scrollbar_gutter_px = rect.w - 0*cw = rect.w`가 되고, lowering의 `cols`도 1 근처다.
    // 창을 극단적으로 좁히거나 split을 끝까지 밀면 실제로 나오는 상태다 — 크래시나 잘못된 큰
    // 사각이 아니라 "안 그리거나 자기 사각 안에만 그린다"여야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **`body`는 padding을 빼지 않으므로 leaf 폭이 곧 본문 폭이다.** gutter(12px)보다 좁은 값을 직접 준다
    // — 예전엔 padding이 빼주던 몫에 기대고 있었고, 그 전제가 바뀌자 이 테스트가 즉시 빨간불이 됐다.
    // 내용 여백(사방 4px)을 뺀 뒤에도 0이 아니면서 gutter(12px)보다 좁아야 한다 → 10 + 8 = 18.
    const narrow: maru.session.SplitRect = .{ .x = 100, .y = 50, .w = 18, .h = 300 };
    const body = pane_ops.paneGeometry(fx.session, narrow).body;
    const content_w = body.w - chrome_editor.frame.content_inset_px * 2;
    try testing.expect(content_w > 0 and content_w < 12); // 전제: 정말 gutter보다 좁다

    fx.session.gpu_quads.clearRetainingCapacity();
    // **`if (…) |d|`로 감싸지 않는다.** null이면 조용히 통과하는 테스트가 되고, 그 순간 이 경계는
    // 검사되지 않는다 — 지금은 `total_cols`가 0으로 접혀도 배경 op이 나오므로 실제로 그린다.
    // 정책이 "이 폭에서는 안 그린다"로 바뀌면 여기서 빨간불이 나야 사람이 그 결정을 마주한다.
    var drawn = appendPaneFrame(fx.session, narrow, fx.term) orelse return error.NarrowPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expectEqual(content_w, drawn.rect.w);
    for (fx.session.gpu_quads.items) |q| {
        try testing.expect(q.w <= @as(f32, @floatFromInt(body.w)));
        try testing.expect(q.x + q.w <= @as(f32, @floatFromInt(narrow.x + narrow.w)));
    }
}

test "문서 끝을 넘긴 스크롤에서도 그리고 사각을 안 넘는다" {
    // `editor_first_line`은 스크롤이 붙기 전이라 지금은 늘 0이지만, 붙는 순간 범위를 넘는 값이
    // 들어온다(리사이즈로 문서가 짧아 보이는 프레임·복원된 옛 offset). `frame.build`는 `first_line`
    // 이 `lines.len`을 넘으면 본문 행을 하나도 못 만드는데, 그때도 배경·gutter는 나와야 하고
    // 무엇보다 사각을 넘으면 안 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_first_line = fx.term.rt.editor_lines.len + 100; // 문서 끝 한참 뒤
    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 내용 사각은 body에서 여백만큼 안쪽이다(위 사각 테스트가 그 관계를 소유한다).
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;
    try testing.expectEqual(body.w - chrome_editor.frame.content_inset_px * 2, drawn.rect.w);
    for (fx.session.gpu_quads.items) |q| {
        try testing.expect(q.x >= @as(f32, @floatFromInt(body.x)));
        try testing.expect(q.x + q.w <= @as(f32, @floatFromInt(body.x + body.w)));
        try testing.expect(q.y + q.h <= @as(f32, @floatFromInt(body.y + body.h)));
    }
    // 셀도 격자 밖으로 안 나간다 — 음수 origin은 lowering이 버리지만 과대 row/col은 안 버린다.
    const cols: u16 = @intCast(body.w / fx.session.cell_width_px);
    const rows: u16 = @intCast(body.h / fx.session.cell_height_px);
    for (drawn.dl.cells) |c| {
        try testing.expect(c.col < cols);
        try testing.expect(c.row < rows);
    }
}

test "빈 파일도 열린다 — 기존 readFileAlloc은 null을 준다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "empty.txt" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opened.file.lineCount());
    try testing.expectEqualStrings("", opened.file.lineText(0).?);
}

test "UTF-8이 아니면 열지 않는다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = "\xff\xfe\x00binary" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "bad.bin" });
    defer testing.allocator.free(path);

    try testing.expectError(error.NotUtf8, openPath(io, testing.allocator, path));
}

test "없는 경로는 Unreadable — 읽기 전용과 구분된다" {
    try testing.expectError(
        error.Unreadable,
        openPath(std.testing.io, testing.allocator, "/nonexistent/maru-editor-test"),
    );
}

test "디렉터리를 가리켜도 죽지 않고 Unreadable이다" {
    // 파일 패널이 폴더 행을 잘못 넘기는 경로가 실재한다. `openFile`이 디렉터리에 성공하는 플랫폼이
    // 있으므로(그러면 read가 EISDIR로 실패한다) 어느 단계에서 걸리든 **같은 에러 하나로** 나와야 한다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "sub" });
    defer testing.allocator.free(path);

    try testing.expectError(error.Unreadable, openPath(io, testing.allocator, path));
}

test "쓸 수 없는 파일도 열리고 읽기 전용으로 표시된다" {
    // §3.5: "쓸 수 없는 파일은 읽기 전용으로 연다 — 보는 것은 되어야 한다." **두 가지를 함께 본다**:
    // ⑴ 열리는가(권한이 여는 것을 막지 않는다) ⑵ 그 사실이 문서에 실리는가. `isWritable`이 늘
    // true를 줘도 ⑴은 통과하므로, ⑵이 없으면 읽기 전용 표시가 통째로 사라져도 아무도 모른다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ro.txt", .data = "locked\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "ro.txt" });
    defer testing.allocator.free(path);

    const pathz = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(pathz);
    if (std.c.chmod(pathz.ptr, 0o444) != 0) return error.SkipZigTest;
    // **root는 W_OK를 통과한다.** 그 환경에서는 이 테스트가 증명할 것이 없으므로 비켜난다.
    //
    // **판정을 `isWritable`로 하지 않는다.** 그러면 검사 대상 함수가 자기 검사 여부를 정하게 되어,
    // 그 함수가 늘 `true`를 돌려주도록 망가진 순간 테스트가 실패 대신 skip이 된다 — 적대적 검증에서
    // 실제로 그 뮤턴트가 초록으로 빠져나갔다. 환경만 보는 축(euid)으로 가른다.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expect(opened.file.read_only); // ⑵ 표시된다
    try testing.expectEqualStrings("locked", opened.file.lineText(0).?); // ⑴ 그래도 열린다
}

test "쓸 수 있는 파일은 읽기 전용이 아니다 — 대조군" {
    // 위 테스트만 있으면 `read_only`를 **항상 true로** 두어도 통과한다.
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "rw.txt", .data = "open\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "rw.txt" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);
    try testing.expect(!opened.file.read_only);
}

test "여러 줄 파일의 줄 내용이 줄바꿈 없이 나온다" {
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.zig", .data = "const a = 1;\nconst 한글 = 2;\r\n\tconst c = 3;" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "src.zig" });
    defer testing.allocator.free(path);

    var opened = try openPath(io, testing.allocator, path);
    defer opened.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), opened.file.lineCount());
    try testing.expectEqualStrings("const a = 1;", opened.file.lineText(0).?);
    try testing.expectEqualStrings("const 한글 = 2;", opened.file.lineText(1).?);
    try testing.expectEqualStrings("\tconst c = 3;", opened.file.lineText(2).?); // 탭은 전개 전이다
    try testing.expect(opened.file.format.mixed_endings);
}

// ── N1.5 c: 좌우 두 열 ───────────────────────────────────────────────────────────────────────
//
// **이 테스트들이 증명하는 것**: 같은 행이 좌우에서 **같은 높이**에 서고(비교의 전부다), 두 열이
// 서로를 침범하지 않으며, 번호가 각자 문서의 것이라는 것. 셋 다 조용히 틀린다 — 한 픽셀 어긋난
// 세로는 스크롤해야 보이고, 겹친 저장소는 한쪽 글자가 다른 쪽으로 바뀌어도 op 수는 그대로다.

const DiffFixture = struct {
    ops: [1024]chrome_draw.Op = undefined,
    text: [16384]u8 = undefined,
    runs: [1024]chrome_draw.Run = undefined,
    content_rows: [256]chrome_editor.content.Row = undefined,
    visual_rows: [256]chrome_editor.visual_map.VisualRow = undefined,
    gutter_rows: [256]chrome_editor.gutter.Row = undefined,
    counts: [4096]u32 = undefined,
    count_scratch: [8192]u8 = undefined,
    caret_cols: [256]u32 = undefined,

    fn scratch(self: *DiffFixture) FrameScratch {
        return .{
            .ops = &self.ops,
            .text_bytes = &self.text,
            .runs = &self.runs,
            .content_rows = &self.content_rows,
            .visual_rows = &self.visual_rows,
            .gutter_rows = &self.gutter_rows,
            .row_counts = &self.counts,
            .count_scratch = &self.count_scratch,
            .caret_cols = &self.caret_cols,
        };
    }
};

test "같은 행이 좌우에서 같은 높이에 선다 — 비교가 성립하는 유일한 조건" {
    var fx = DiffFixture{};
    const left_texts = [_][]const u8{ "keep", "gone", "tail" };
    const right_texts = [_][]const u8{ "keep", "", "tail" }; // 가운데가 filler
    const left_numbers = [_]?u32{ 1, 2, 3 };
    const right_numbers = [_]?u32{ 1, null, 2 };

    const pf = buildDiffPaneOps(
        .{ .lines = &left_texts, .numbers = &left_numbers, .total_lines = 3 },
        .{ .lines = &right_texts, .numbers = &right_numbers, .total_lines = 2 },
        0,
        0,
        false,
        chrome_editor.frame.default_tab_width,
        .{ .x = 0, .y = 0, .w = 800, .h = 300 },
        8,
        16,
        16,
        fx.scratch(),
    );
    try testing.expect(pf.ops_len > 0);

    const split = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = 800 - chrome_editor.frame.content_inset_px * 2, .h = 300 - chrome_editor.frame.content_inset_px * 2 }, 8).right.x;
    // 각 열에서 **본문 글자**의 y를 모은다(gutter·배경 제외를 위해 x로 가른다).
    var left_ys: [8]i32 = undefined;
    var right_ys: [8]i32 = undefined;
    var ln: usize = 0;
    var rn: usize = 0;
    for (pf.ops) |op| {
        if (op != .text) continue;
        const t = op.text;
        if (t.role != chrome_editor.content.text_role) continue; // 줄 번호는 다른 역할이다
        if (t.origin.x < split) {
            if (ln < left_ys.len) {
                left_ys[ln] = t.origin.y;
                ln += 1;
            }
        } else if (rn < right_ys.len) {
            right_ys[rn] = t.origin.y;
            rn += 1;
        }
    }
    // 왼쪽 3행, 오른쪽 2행(filler는 빈 문자열이라 글자 op이 없다)이고 **y가 같은 자리에 선다**.
    try testing.expect(ln >= 3);
    try testing.expect(rn >= 2);
    try testing.expectEqual(left_ys[0], right_ys[0]); // 첫 행
    try testing.expectEqual(left_ys[2], right_ys[1]); // 마지막 행 — filler 한 칸을 건너뛴 그 높이
}

// ── 세로 스크롤 ──────────────────────────────────────────────────────────────────────────────

test "휠 위는 문서 앞쪽으로, 아래는 뒤쪽으로 — 터미널 스크롤백과 같은 방향" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // **제품과 같은 것을 넘긴다 — leaf 사각이다.** 여기에 `body`를 넘기면 창 padding 차이가 가려져,
    // 실제로는 끝에서 빈 줄이 남는데 테스트만 통과한다(리뷰가 그 상태를 잡았다).
    const leaf = fx.leaf_rect;

    // 문서를 화면보다 길게 만든다(픽스처는 3줄이라 스크롤이 성립하지 않는다).
    const long = try allocator.alloc([]const u8, 200);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    try testing.expect(scrollLines(fx.session, fx.term, leaf, -3)); // 아래로 세 줄
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_first_line);
    try testing.expect(scrollLines(fx.session, fx.term, leaf, 1)); // 위로 한 줄
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_first_line);
}

test "문서 앞뒤로 넘어가지 않는다 — 마지막 화면이 비지 않게 멈춘다" {
    // 끝을 넘겨 스크롤하게 두면 배경만 남은 화면이 나오고, 사용자는 문서가 끝났는지 뷰가 깨졌는지 모른다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf = fx.leaf_rect;

    const long = try allocator.alloc([]const u8, 200);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    _ = scrollLines(fx.session, fx.term, leaf, 10); // 위로 — 이미 맨 앞
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);

    _ = scrollLines(fx.session, fx.term, leaf, -10_000); // 아래로 한참
    const body = pane_ops.paneGeometry(fx.session, leaf).body;
    const visible = (body.h -| chrome_editor.frame.content_inset_px * 2) / fx.session.cell_height_px;
    try testing.expectEqual(long.len - visible, fx.term.rt.editor_first_line);
    // **마지막 화면이 꽉 찬다** — 남은 줄이 화면 행 수와 같다.
    try testing.expectEqual(@as(usize, visible), long.len - fx.term.rt.editor_first_line);
}

test "문서가 화면보다 짧으면 움직이지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -50); // 픽스처는 3줄
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "편집기가 아니면 휠을 소유하지 않는다 — 터미널 스크롤백으로 흘러야 한다" {
    // 여기서 true를 돌려주면 셸 pane 위 휠이 **아무것도 안 하는** 상태가 된다(호출자가 곧바로 반환한다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = pane_ops.activePane(fx.session).terms.items[0];
    const saved_kind = term.kind;
    term.kind = .terminal;
    defer term.kind = saved_kind;
    try testing.expect(!scrollLines(fx.session, term, fx.leaf_rect, -3));
}

test "0줄이어도 편집기가 소유한다 — 잔여 델타가 뒤 터미널을 굴리면 안 된다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try testing.expect(scrollLines(fx.session, fx.term, fx.leaf_rect, 0));
}

test "스크롤하면 화면이 실제로 바뀐다 — 상태만 움직이고 렌더가 안 따라오면 아무 일도 안 일어난다" {
    // **`editor_first_line`이 바뀌는 것만 보는 테스트는 통과하면서 화면은 멈춰 있을 수 있다**(렌더가
    // 그 값을 안 읽으면). 여기서는 같은 pane을 두 번 그려 **셀 내용이 달라지는지**를 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 줄마다 다른 글자를 둔다 — 같은 글자면 스크롤해도 셀이 같아 보인다.
    const alphabet = "abcdefghijklmnopqrstuvwxyz";
    const long = try allocator.alloc([]const u8, 200);
    defer allocator.free(long);
    for (long, 0..) |*l, i| l.* = alphabet[i % 26 ..][0..1];
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    var before = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer before.dl.deinit(allocator);
    const first_before: u32 = blk: {
        for (before.dl.cells) |c| if (c.row == 0 and c.codepoint >= 'a' and c.codepoint <= 'z') break :blk c.codepoint;
        break :blk 0;
    };

    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -5);
    fx.session.gpu_quads.clearRetainingCapacity();
    var after = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer after.dl.deinit(allocator);
    const first_after: u32 = blk: {
        for (after.dl.cells) |c| if (c.row == 0 and c.codepoint >= 'a' and c.codepoint <= 'z') break :blk c.codepoint;
        break :blk 0;
    };

    try testing.expect(first_before != 0);
    // 다섯 줄 내려갔으니 맨 윗줄 글자가 다섯 칸 뒤다.
    try testing.expectEqual(alphabet[5], @as(u8, @intCast(first_after)));
    try testing.expectEqual(alphabet[0], @as(u8, @intCast(first_before)));
}

test "편집기가 세로만 소유한다 — 가로(탭 바) 축은 그대로 흐른다" {
    // 처음엔 세로를 처리하고 **곧바로 반환**해서, 편집기 pane 위 트랙패드 가로 스와이프가 아무 일도
    // 안 했다(리뷰 지적). 탭 바 가로 스크롤은 Maru chrome의 직교 축이라 편집기 위에서도 살아 있어야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // `scrollLines`는 **세로만** 답한다 — 가로 처리 여부를 이 반환값이 결정하면 안 된다는 계약을
    // 호출자(`scroll.zig`)가 지키는지는 그 파일의 구조로만 볼 수 있으므로, 여기서는 그 계약의
    // 전제(세로 0줄이어도 소유)와 함께 **가로 델타가 세로 상태를 안 건드리는 것**을 고정한다.
    const before = fx.term.rt.editor_first_line;
    try testing.expect(scrollLines(fx.session, fx.term, fx.leaf_rect, 0));
    try testing.expectEqual(before, fx.term.rt.editor_first_line);
}

test "랩으로 접힌 문서는 마지막 줄까지 닿는다 — 접힌 만큼 못 보는 일이 없다" {
    // `visible`(시각 행)에서 `total`(논리 줄)을 그대로 빼면, 줄마다 접히는 문서에서 **마지막 줄들이
    // 영영 안 보인다**(리뷰 지적). 렌더가 실어 둔 문서 전체 시각 행 수로 그 경우를 가른다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const long = try allocator.alloc([]const u8, 100);
    defer allocator.free(long);
    for (long) |*l| l.* = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;
    fx.term.rt.editor_wrap = true;

    // 한 번 그려 시각 행 수를 싣는다(그 값이 없으면 논리 줄로 폴백한다).
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_total_visual_rows > long.len); // 실제로 접혔다

    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -10_000);

    // **옛 단언은 `first_line == long.len - 1`이었다** — "마지막 논리 줄이 맨 위"라는 거친 근사이고,
    // 그 화면은 마지막 줄의 조각 몇 개만 남아 거의 비어 있다. 조각 단위 스크롤(§4.1d)이 붙으면서
    // **끝에 닿으면서 화면도 꽉 차는** 위치에 선다(실측: 99 → 83). 그래서 기계(=어느 줄인가)가 아니라
    // **의도**를 단언한다.
    var at_end = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer at_end.dl.deinit(allocator);
    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = inner_h / fx.session.cell_height_px;

    // 그린 행 수는 셀의 최대 row로 센다(`PaneDraw`는 행 수를 따로 내지 않는다).
    var drawn_rows: usize = 0;
    for (at_end.dl.cells) |c| drawn_rows = @max(drawn_rows, @as(usize, c.row) + 1);

    try testing.expect(fx.term.rt.editor_first_line > 0); // 실제로 끝까지 갔다
    try testing.expectEqual(visible, drawn_rows); // **화면이 꽉 찬다** — 옛 규칙은 여기서 빈다

    // 더 굴려도 안 움직인다 = 끝이다.
    const line_at_end = fx.term.rt.editor_first_line;
    const piece_at_end = fx.term.rt.editor_first_piece;
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -10_000);
    try testing.expectEqual(line_at_end, fx.term.rt.editor_first_line);
    try testing.expectEqual(piece_at_end, fx.term.rt.editor_first_piece);
}

test "접혀도 화면에 다 들어가면 안 움직인다" {
    // 위 규칙을 "랩이면 무조건 total-1"로 두면 짧은 문서도 스크롤돼 화면이 비어 버린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.term.rt.editor_wrap = true;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -50);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "휠 라우팅: 편집기 pane 위 세로는 문서가 먹고, 가로는 탭 바로 흐른다" {
    // **여기가 리뷰가 잡은 결함이 살던 자리다**(세로를 처리하고 곧바로 반환해 가로가 죽었다). 그런데
    // 그때도 `scrollLines` 단위 테스트는 전부 통과했다 — 라우팅은 그 함수 **밖**이기 때문이다.
    // 그래서 제품 진입점(`scrollWheel`)으로 직접 들어간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    // **창 크기를 준다.** 픽스처는 렌더 상태만 세우므로 `termRect()`가 0×0이고, 그러면 `paneTargetAt`이
    // 아무 pane도 못 맞혀 라우팅이 활성 surface 폴백으로 빠진다(이 테스트가 보려는 경로가 아니다).
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    // 문서를 화면보다 길게 — 짧으면 스크롤이 no-op이라 라우팅이 통과해도 아무것도 증명 못 한다.
    const long = try allocator.alloc([]const u8, 400);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    // 커서를 이 pane 안에 둔다. `paneTargetAt`은 활성 탭의 leaf 사각들을 `termRect()`에서 나누므로,
    // 그 사각의 한가운데면 leaf 하나짜리 배치에서 반드시 이 pane이 맞는다.
    const win = fx.session.termRect();
    const x: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) / 2.0;
    const y: f64 = @as(f64, @floatFromInt(win.y)) + @as(f64, @floatFromInt(win.h)) / 2.0;

    // ① 세로: 문서가 움직인다.
    const tab_scroll_before = fx.session.tab_wheel_accum;
    scroll_ops.scrollWheel(fx.session, -3.0 * @as(f64, @floatFromInt(fx.session.cell_height_px)), 0, false, x, y);
    try testing.expect(fx.term.rt.editor_first_line > 0);
    try testing.expectEqual(tab_scroll_before, fx.session.tab_wheel_accum); // 가로 축은 안 건드렸다

    // ② 가로: 세로 델타가 0이어도 **가로 누적기가 움직인다** — 편집기가 이벤트를 통째로 삼키면
    //    이 값이 그대로 남는다(그것이 리뷰가 잡은 상태였다).
    const line_before = fx.term.rt.editor_first_line;
    scroll_ops.scrollWheel(fx.session, 0, 3.0, true, x, y);
    try testing.expect(fx.session.tab_wheel_accum != tab_scroll_before);
    try testing.expectEqual(line_before, fx.term.rt.editor_first_line); // 가로가 세로를 안 건드린다
}

test "커서가 편집기 밖이면 문서가 안 움직인다 — 휠은 커서 아래 pane의 것이다" {
    // 편집기 pane이 **활성**이어도, 커서가 사이드바 위면 그쪽이 휠을 통째로 소비한다. 이 계약이
    // 깨지면 사이드바를 굴릴 때 뒤 문서가 함께 움직인다(터미널에서 이미 정해 둔 규율이다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    const long = try allocator.alloc([]const u8, 400);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    // 사이드바 위(x가 사이드바 폭 안).
    try testing.expect(fx.session.sidebar_width_px > 0);
    const x: f64 = @as(f64, @floatFromInt(fx.session.sidebar_width_px)) / 2.0;
    const y: f64 = 200;
    scroll_ops.scrollWheel(fx.session, -5.0 * @as(f64, @floatFromInt(fx.session.cell_height_px)), 0, false, x, y);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "pane 밖(어느 leaf에도 안 맞음)에서도 활성 편집기가 문서를 스크롤한다" {
    // `paneTargetAt`이 null이면 라우팅은 **활성 surface**로 폴백한다. 활성 Term이 편집기면 그 surface는
    // 문서가 아니라 sentinel core라(§편집기 Term) 스크롤백 경로가 아무 의미가 없다 — 그 자리에서
    // 문서를 굴리는 것이 사용자가 기대하는 동작이고, 그래야 "활성 pane이 반응한다"는 규율이 유지된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    const long = try allocator.alloc([]const u8, 400);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    // 창 오른쪽 바깥(어느 leaf에도 안 맞는 좌표) — 사이드바도 상태바도 아니다.
    const x: f64 = @floatFromInt(fx.session.backing_width_px + 100);
    const y: f64 = 200;
    scroll_ops.scrollWheel(fx.session, -4.0 * @as(f64, @floatFromInt(fx.session.cell_height_px)), 0, false, x, y);
    try testing.expect(fx.term.rt.editor_first_line > 0);
}

test "폴백은 편집기일 때만 가져간다 — 활성이 셸이면 지금까지의 경로 그대로다" {
    // 위 폴백이 **모든** Term을 가져가면 pane 밖 휠이 터미널 스크롤백을 못 굴린다(그 경로가 원래
    // 폴백의 존재 이유다). 편집기가 아닐 때 `scrollLines`가 false를 돌려주는 것이 그 경계다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    const term = pane_ops.activePane(fx.session).terms.items[0];
    const saved_kind = term.kind;
    term.kind = .terminal; // 셸인 척한다
    defer term.kind = saved_kind;

    const leaf = pane_ops.activeLeafRect(fx.session) orelse return error.NoLeafRect;
    try testing.expect(!scrollLines(fx.session, term, leaf, -3));
    // 문서 상태도 안 건드린다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
}

test "활성 leaf 사각은 격자가 아니라 leaf다 — 편집기가 body를 구하는 출발점" {
    // `active_pane_rect`(격자)를 그대로 쓰면 창 padding만큼 작아 보이는 행 수가 줄고, 스크롤 상한이
    // 그만큼 커진다(리뷰가 잡은 그 실수와 같은 종류다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    const leaf = pane_ops.activeLeafRect(fx.session) orelse return error.NoLeafRect;
    const grid = pane_ops.paneGeometry(fx.session, leaf).grid;
    // padding이 0이 아니므로 셋이 실제로 다르다 — 같으면 이 테스트가 아무것도 증명하지 못한다.
    try testing.expect(fx.session.window_padding_px.top > 0);
    try testing.expect(leaf.h > grid.h);
}

test "분할된 pane: 휠은 커서 아래 편집기만 굴린다 — 옆 pane 문서는 그대로다" {
    // **지금까지 라우팅 테스트가 전부 leaf 하나짜리였다.** 두 pane이 나란할 때 "옆 pane 위 휠이 이쪽을
    // 안 건드린다"가 실제로 성립하는지는 아무도 안 봤다 — 그런데 split은 사용자가 늘 쓰는 배치다.
    // `splitActivePane`은 진짜 셸을 띄우므로, 여기서는 **트리만** 손으로 세운다(그 함수가 spawn과
    // 분리해 두었기 때문에 가능하다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    // 두 pane 모두 긴 문서를 든 편집기로 만든다.
    const long = try allocator.alloc([]const u8, 400);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    const tab = tab_ops.activeTab(fx.session);
    const left_pane = tab.panes.items[0];

    const right_pane = try allocator.create(app_session_mod.Pane);
    right_pane.* = .{};
    const right_term = try createEditorTerm(fx.session);
    right_term.rt.editor_lines = long;
    try right_pane.terms.append(allocator, right_term);
    try tab.panes.append(allocator, right_pane);

    const split = try allocator.create(app_session_mod.PaneTree.Split);
    split.* = .{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = left_pane }, .b = .{ .leaf = right_pane } };
    try testing.expect(app_session_mod.PaneTree.replaceLeaf(&tab.tree, left_pane, .{ .split = split }));
    // **세운 것은 여기서 되돌린다.** 세션 해체에 맡기면 트리·pane 소유가 픽스처의 가정과 어긋나
    // 죽는다(실제로 그랬다) — 이 테스트가 보려는 것은 라우팅이지 해체가 아니다.
    defer {
        tab.tree = .{ .leaf = left_pane };
        allocator.destroy(split);
        _ = tab.panes.pop();
        right_term.rt.editor_lines = &.{}; // 빌린 배열이라 Term이 해제하면 안 된다
        term_ops.destroyTerm(fx.session, right_term);
        right_pane.terms.deinit(allocator);
        allocator.destroy(right_pane);
    }

    // 오른쪽 절반 한가운데에서 굴린다.
    const win = fx.session.termRect();
    const x: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) * 0.75;
    const y: f64 = @as(f64, @floatFromInt(win.y)) + @as(f64, @floatFromInt(win.h)) / 2.0;
    scroll_ops.scrollWheel(fx.session, -4.0 * @as(f64, @floatFromInt(fx.session.cell_height_px)), 0, false, x, y);

    try testing.expect(right_term.rt.editor_first_line > 0); // 커서 아래가 움직였다
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line); // 옆 pane은 그대로다

    // 왼쪽 절반에서 굴리면 반대가 된다.
    const before_right = right_term.rt.editor_first_line;
    const lx: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) * 0.25;
    scroll_ops.scrollWheel(fx.session, -2.0 * @as(f64, @floatFromInt(fx.session.cell_height_px)), 0, false, lx, y);
    try testing.expect(fx.term.rt.editor_first_line > 0);
    try testing.expectEqual(before_right, right_term.rt.editor_first_line);
}

test "파일 열기가 어디서 할당에 실패해도 새지 않는다 — init 이후만 흔든다" {
    // **이 자리에 테스트가 없었다.** 같은 이중 해제를 `materialize`·`computeMarks`에서 주입으로 두 번
    // 잡고, 여기는 그 패턴을 알고 나서 **읽어서** 고쳤다 — 회귀를 자동으로 잡을 것이 없었다.
    //
    // `checkAllAllocationFailures`를 그대로 못 쓴다: 세션 allocator는 init에 고정이고, 다른 allocator로
    // 잡으면 나중에 `releaseEditorTerm`이 세션 allocator로 풀어 **진짜 버그**가 된다. 그래서 세션을
    // 실패 allocator로 만들되 **init이 끝난 뒤부터** 실패 지점을 옮긴다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;

    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    try dir.dir.writeFile(io, .{ .sub_path = "doc.zig", .data = "const a = 1;\nconst b = 2;\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(backing, &.{ root, "doc.zig" });
    defer backing.free(path);

    // 실패 지점을 하나씩 뒤로 밀며 연다. 열기 한 번이 쓰는 할당 수보다 넉넉히 돈다.
    var failed_steps: usize = 0;
    var ok_steps: usize = 0;
    var step: usize = 0;
    while (step < 24) : (step += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();

        const session = try backing.create(AppSession);
        defer backing.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), alloc, .{
            .abi_version = app_session_mod.abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
        });
        defer session.deinit(); // 누수·이중 해제는 backing(=testing.allocator)이 잡는다

        // **여기서부터** 실패시킨다 — init이 쓴 할당은 건드리지 않는다.
        failing.fail_index = failing.allocations + step;
        const term = openPathInActivePane(session, path) catch {
            failed_steps += 1;
            continue;
        };
        // 성공했으면 세션 해체가 그 Term을 정리한다(그 경로도 함께 확인된다).
        try testing.expect(term.rt.editor_path != null);
        ok_steps += 1;
    }
    // **공허해질 수 없게 세어서 단언한다.** 실패를 한 번도 안 겪으면 이 테스트는 아무것도 지키지
    // 않는다 — 열기가 쓰는 할당 수가 줄어 창을 벗어나도 여기서 걸린다.
    try testing.expect(failed_steps >= 5);
    try testing.expect(ok_steps >= 1);
}

/// 가로 스크롤 테스트가 함께 쓰는 준비: 랩을 끄고 화면보다 **긴 줄**을 하나 심는다.
///
/// **`editor_lines`는 Term 소유다.** 호출자가 옛 슬라이스를 붙잡아 두고 defer로 되돌려야 한다 —
/// 안 그러면 `releaseEditorTerm`이 테스트 할당을 풀고 테스트도 풀어 **이중 해제**다(처음에 그랬다).
fn hscrollFixtureLines(allocator: std.mem.Allocator, fx: *PaneFixture, long_len: usize) ![]const []const u8 {
    fx.term.rt.editor_wrap = false;
    const long = try allocator.alloc(u8, long_len);
    errdefer allocator.free(long);
    @memset(long, 'x');
    const lines = try allocator.alloc([]const u8, 3);
    lines[0] = "short";
    lines[1] = long;
    lines[2] = "short";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_max_cols = 0; // 새 내용이다 — 캐시를 버린다
    return lines;
}

test "가로 휠은 긴 줄이 있을 때만 문서를 민다 — 아니면 탭 바가 그 축을 쓴다" {
    // **탭 바 축을 뺏으면 안 된다.** 편집기 pane 위 가로 스와이프가 탭 바를 굴리는 것은 이미 정해진
    // 동작이고(리뷰 지적으로 살아난 경로다), 편집기는 **넘칠 때만** 그 축을 가져간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;
    const win = fx.session.termRect();
    const x: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) / 2.0;
    const y: f64 = @as(f64, @floatFromInt(win.y)) + @as(f64, @floatFromInt(win.h)) / 2.0;
    // **셀 폭보다 큰 델타를 준다.** 작으면 누적기에만 쌓이고 `cols`가 0이라, 라우팅이 옳아도
    // 아무 일이 안 일어나 판정이 성립하지 않는다(이 테스트가 처음에 그렇게 실패했다).
    // 셀 폭의 **정확한 배수는 피한다** — 나머지가 0으로 돌아와 누적기가 그대로라, "탭 바가 이 축을
    // 썼다"를 누적기로 볼 수 없다(이 테스트가 두 번째로 그렇게 실패했다).
    const dx: f64 = -3.5 * @as(f64, @floatFromInt(fx.session.cell_width_px));

    // ① 안 넘치는 문서: 탭 바가 그 축을 쓰고 문서는 그대로다.
    fx.term.rt.editor_wrap = false;
    const accum_before = fx.session.tab_wheel_accum;
    scroll_ops.scrollWheel(fx.session, 0, dx, true, x, y);
    try testing.expect(fx.session.tab_wheel_accum != accum_before);
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);

    // **`tab_wheel_accum`으로는 축 소유를 판정할 수 없다** — 그 값은 라우팅 **이전에**
    // `wheelDeltaToLines`가 건드리므로 편집기가 축을 삼켜도 움직인다. 실제 판정은
    // "안 넘치면 편집기가 가로 축을 가져가지 않는다"가 한다(탭 바의 `tab_scroll_cols`를 본다).
    // ② 넘치는 문서: 이제 편집기가 가져간다.
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved; // 소유를 되돌린다 — Term이 원래 것을 푼다
    const lines = try hscrollFixtureLines(allocator, &fx, 4000);
    const long_buf = lines[1]; // defer는 LIFO다 — `lines`가 풀린 뒤 `lines[1]`을 읽으면 UAF다
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    scroll_ops.scrollWheel(fx.session, 0, dx, true, x, y);
    try testing.expect(fx.term.rt.editor_first_col > 0);
}

test "가로 스크롤은 가장 긴 줄의 끝에서 멈춘다 — 빈 화면으로 넘어가지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long_len = 500;
    const lines = try hscrollFixtureLines(allocator, &fx, long_len);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    try testing.expect(scrollCols(fx.session, fx.term, leaf, -1_000_000, null)); // 끝까지 민다
    const visible = visibleCols(fx.session, editorBodyRect(fx.session, leaf, fx.term), fx.term, false);
    try testing.expect(visible > 0);
    try testing.expectEqual(@as(u32, long_len) - visible, @as(u32, fx.term.rt.editor_first_col));

    try testing.expect(scrollCols(fx.session, fx.term, leaf, 1_000_000, null)); // 되돌리면 0에서 멈춘다
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);
}

test "랩 중에는 가로 축이 없고 렌더에도 0이 간다 — 위치는 버리지 않는다" {
    // 랩은 폭에 맞춰 잘라 두므로 넘칠 것이 없다. 옛 가로 위치를 남기면 랩된 본문이 왼쪽으로 밀려
    // 그려진다 — 화면에 아무 글자도 없는 상태가 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, 500);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    try testing.expect(scrollCols(fx.session, fx.term, leaf, -20, null));
    try testing.expect(fx.term.rt.editor_first_col > 0);

    const before_wrap = fx.term.rt.editor_first_col;

    try testing.expect(toggleWrap(fx.session)); // 랩 켬
    try testing.expect(!scrollCols(fx.session, fx.term, leaf, -20, null)); // 랩 중에는 이 축을 안 가진다
    // **렌더에는 0이 간다** — 컴포넌트의 `!wrap or first_col == 0`을 여기서 세운다. 그리는 것과
    // 저장된 위치는 다른 것이고, 그리기가 죽지 않는 것까지 함께 본다.
    try testing.expectEqual(@as(u16, 0), effectiveFirstCol(true, fx.term, false));
    var drawn = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    // **보던 자리로 돌아온다** — 켤 때 지우면 그것을 잃는다.
    try testing.expect(toggleWrap(fx.session)); // 랩 끔
    try testing.expectEqual(before_wrap, fx.term.rt.editor_first_col);
}

test "가로 위치가 렌더까지 간다 — 상태만 움직이고 화면이 그대로면 아무 일도 안 일어난다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, 500);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    var before = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    var short_before: usize = 0;
    for (before.dl.cells) |c| {
        if (c.codepoint == 's') short_before += 1;
    }
    before.dl.deinit(allocator);
    try testing.expect(short_before > 0); // 밀기 전에는 "short"가 보인다 — 없으면 아래 판정이 공허하다

    try testing.expect(scrollCols(fx.session, fx.term, leaf, -30, null));
    var after = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer after.dl.deinit(allocator);
    // 30열을 밀면 "short"(5열)는 화면 밖이다 — 긴 줄만 남는다.
    var short_after: usize = 0;
    for (after.dl.cells) |c| {
        if (c.codepoint == 's') short_after += 1;
    }
    try testing.expectEqual(@as(usize, 0), short_after);
}

test "창이 넓어지면 다음 프레임이 가로 위치를 되돌린다 — 오른쪽에 빈 자리가 남지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, 300);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    // 좁은 pane에서 끝까지 민다.
    const narrow: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
    try testing.expect(scrollCols(fx.session, fx.term, narrow, -1_000_000, null));
    const at_end = fx.term.rt.editor_first_col;
    try testing.expect(at_end > 0);

    // **창이 넓어졌다.** 상한은 줄었는데 위치는 그대로다 — 그리면 오른쪽에 빈 자리가 남는다.
    // **창이 넓어졌다.** 상한이 줄었으니 다음 프레임이 위치를 되돌려야 한다 — 안 그러면 오른쪽에
    // 빈 자리가 남는다(고치기 전 실측: 상한 111인데 위치 261).
    const wide: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 1600, .h = 400 };
    var drawn = appendPaneFrame(fx.session, wide, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const wide_visible = visibleCols(fx.session, editorBodyRect(fx.session, wide, fx.term), fx.term, false);
    const wide_max: u32 = fx.term.rt.editor_max_cols -| wide_visible;
    try testing.expect(at_end > wide_max); // 좁을 때 위치가 넓은 창의 상한을 넘는다 — 아니면 판정이 공허하다
    try testing.expectEqual(wide_max, @as(u32, fx.term.rt.editor_first_col));
}

test "창이 높아지면 다음 프레임이 세로 위치를 되돌린다 — 아래가 통째로 비지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const many = try allocator.alloc([]const u8, 200);
    defer allocator.free(many);
    for (many) |*l| l.* = "line";
    fx.term.rt.editor_lines = many;
    fx.term.rt.editor_wrap = false;

    const short: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 200 };
    _ = scrollLines(fx.session, fx.term, short, -1_000_000);
    const at_end = fx.term.rt.editor_first_line;
    try testing.expect(at_end > 0);

    const tall: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 1600 };
    var drawn = appendPaneFrame(fx.session, tall, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    const body = editorBodyRect(fx.session, tall, fx.term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = inner_h / fx.session.cell_height_px;
    try testing.expect(at_end > many.len -| visible); // 판정이 공허하지 않다
    try testing.expect(fx.term.rt.editor_first_line <= many.len -| visible);
    try testing.expect(drawn.dl.cells.len > 0);
}

test "되돌리기는 한 번이면 끝난다 — 매 프레임 dirty를 세우면 화면이 영원히 다시 그려진다" {
    // `clampScrollToGeometry`가 그리기 직전에 돌면서 `metal_dirty`를 세운다. 값이 안정되지 않으면
    // 프레임마다 다시 세워져 **아무 입력이 없어도 GPU가 계속 돈다**(배터리).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    for ([_]bool{ false, true }) |wrap| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);

        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;
        const lines = try hscrollFixtureLines(allocator, &fx, 300);
        const long_buf = lines[1];
        defer allocator.free(long_buf);
        defer allocator.free(lines);

        const narrow: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 400, .h = 200 };
        _ = scrollCols(fx.session, fx.term, narrow, -1_000_000, null);
        _ = scrollLines(fx.session, fx.term, narrow, -1_000_000);
        fx.term.rt.editor_wrap = wrap;

        // 창이 커졌다 — 첫 프레임이 되돌린다.
        const wide: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 1600, .h = 1200 };
        var f1 = appendPaneFrame(fx.session, wide, fx.term) orelse return error.EditorPaneDidNotDraw;
        f1.dl.deinit(allocator);

        // 두 번째 프레임부터는 **아무것도 안 바꿔야** 한다.
        fx.session.metal_dirty = false;
        const line_after = fx.term.rt.editor_first_line;
        const col_after = fx.term.rt.editor_first_col;
        var f2 = appendPaneFrame(fx.session, wide, fx.term) orelse return error.EditorPaneDidNotDraw;
        f2.dl.deinit(allocator);
        try testing.expectEqual(line_after, fx.term.rt.editor_first_line);
        try testing.expectEqual(col_after, fx.term.rt.editor_first_col);
        try testing.expect(!fx.session.metal_dirty); // 안정 상태에서 다시 그릴 이유가 없다
    }
}

test "config 재적재로 랩이 켜져도 그리기가 죽지 않는다 — 토글만 지키면 부족하다" {
    // 컴포넌트는 `!wrap or first_col == 0`을 **어서션**으로 요구한다. `toggleWrap`은 그것을 지키지만
    // 뷰 override가 없는 편집기는 config를 따르므로, **config가 바뀌면 토글을 지나지 않고** 랩이
    // 켜진다. Debug는 그 자리에서 죽고 ReleaseFast는 조용히 틀린 그림을 그린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, 300);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    // **override를 지운다** — 이 뷰는 config를 따른다(새로 연 편집기의 기본 상태다).
    fx.term.rt.editor_wrap = null;
    fx.session.loaded_config.config.editor.wrap = false;
    try testing.expect(scrollCols(fx.session, fx.term, leaf, -20, null));
    try testing.expect(fx.term.rt.editor_first_col > 0);

    // config가 바뀐다(재적재). 토글은 부르지 않는다.
    const stored = fx.term.rt.editor_first_col;
    fx.session.loaded_config.config.editor.wrap = true;
    var drawn = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(drawn.dl.cells.len > 0); // 어서션에 안 걸리고 그려진다
    try testing.expectEqual(stored, fx.term.rt.editor_first_col); // 상태는 그대로 — 랩을 끄면 돌아갈 자리
}

test "[측정] 첫 가로 휠이 문서 전체를 훑는 비용" {
    // PR #2239의 한계 절에 **"재지 않았다"**고 적었던 값이다. 재 보니 5만 줄에서 **501ms**였다 —
    // 반 초짜리 멈춤이라 한계로 남길 값이 아니었다. 원인은 `stepColumn`이 cluster마다 §3.8 위험 문자
    // 검사로 codepoint를 디코드하던 것이고, 가장 흔한 걸음(출력 가능한 ASCII)을 먼저 끝내 **28ms**가
    // 됐다(Debug, macOS arm64, 66바이트짜리 탭 들여쓰기 줄).
    //
    // 아래 상한은 **재앙 감지선**이지 예산이 아니다. 값이 궁금하면 출력이 그대로 찍힌다.
    //
    // **선은 실측에 앵커링한다.** 처음 이 선은 1000 이었는데, 그것은 위에 적은 **수정 전 값
    // 501ms 보다도 높다** — 즉 그 회귀가 그대로 돌아와도 통과했다. 잡겠다고 이름까지 적어 둔
    // 것을 못 잡는 감지선이었다. 지금 값은 28ms(이 기계)·39ms(CI 러너)이므로 200 은 실측의
    // 약 5배이면서 501ms 아래다 — 기계 편차는 흡수하고 회귀는 잡는다.
    //
    // **판정은 카운터가 한다**(2026-08-22). 이 픽스처는 탭과 ASCII뿐이라 `stepColumn`이 느린 경로를
    // **한 걸음도** 타면 안 된다 — 빠른 경로가 사라지는 그 회귀가 501ms를 만들었다. 시간으로 재면
    // 러너 부하와 구분이 안 되고(이 선도 부하가 크면 229ms로 넘겼다), 카운터는 안 흔들린다.
    // 시간은 **출력만** 한다.
    //
    // (전환을 한 번 실패했다: 계측을 `stepColumn`이 아니라 같은 두 줄로 시작하는 다른 함수에 넣어
    // 뮤턴트에서 카운터가 0이었고, "카운터로는 못 잡는다"고 결론낼 뻔했다. `content.zig`의
    // `stepColumn 계측이 두 경로를 갈라 센다`가 그 계측 자신을 잰다.)
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    for ([_]usize{ 10_000, 50_000 }) |n| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        // 실제 소스 코드에 가까운 줄(들여쓰기 탭 + ASCII 80자).
        const line = "\t\tconst result = try computeSomething(argument_one, argument_two);";
        const many = try allocator.alloc([]const u8, n);
        defer allocator.free(many);
        for (many) |*l| l.* = line;
        fx.term.rt.editor_lines = many;
        fx.term.rt.editor_wrap = false;
        fx.term.rt.editor_max_cols = 0;

        chrome_editor.content.slow_path_steps = 0;
        chrome_editor.content.total_steps = 0;
        const t0 = monotonicMsForTest();
        _ = scrollCols(fx.session, fx.term, leaf, -1, null);
        const t1 = monotonicMsForTest();
        const slow_first = chrome_editor.content.slow_path_steps;
        const total_first = chrome_editor.content.total_steps;
        std.debug.print("\n[측정] {d}줄 × {d}B: 첫 가로 휠 {d}ms (max_cols={d}, 걸음 {d} 중 느린 걸음 {d})\n", .{ n, line.len, t1 - t0, fx.term.rt.editor_max_cols, total_first, slow_first });

        // **탭과 ASCII뿐이다 — 느린 경로는 한 걸음도 없어야 한다.** 이것이 501ms 회귀의 축이다.
        try testing.expectEqual(@as(usize, 0), slow_first);
        // 실제로 걸었는지도 본다 — 위가 "아무것도 안 했다"로도 통과하면 안 된다.
        try testing.expectEqual(n * line.len, total_first);

        // 두 번째부터는 캐시라 **한 걸음도 다시 안 걷는다**. 시간이 아니라 걸음으로 잰다.
        chrome_editor.content.total_steps = 0;
        const t2 = monotonicMsForTest();
        _ = scrollCols(fx.session, fx.term, leaf, -1, null);
        const t3 = monotonicMsForTest();
        std.debug.print("[측정] {d}줄: 두 번째 휠 {d}ms (걸음 {d})\n", .{ n, t3 - t2, chrome_editor.content.total_steps });
        try testing.expectEqual(@as(usize, 0), chrome_editor.content.total_steps);
    }
}

fn monotonicMsForTest() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "[측정] 가로로 멀리 밀수록 프레임이 느려지는가" {
    // `expandTabs`는 화면 시작 열(`first_col`)까지 **훑고 버린다**. 그러면 오른쪽으로 갈수록 매
    // 프레임 비용이 커진다 — 긴 줄에서 계속 밀면 점점 뻑뻑해지는 상태다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;

    // **ASCII만이면 `expandTabs`가 원본을 그대로 빌려줘 O(1)이다** — 그 길을 타면 이 측정이 아무것도
    // 말하지 않는다(처음에 그렇게 재고 "평평하다"고 오판할 뻔했다). 앞에 2칸 글자를 하나 둔다.
    const long = try allocator.alloc(u8, 200_000);
    defer allocator.free(long);
    @memset(long, 'x');
    @memcpy(long[0..3], "한");
    const many = try allocator.alloc([]const u8, 60);
    defer allocator.free(many);
    for (many) |*l| l.* = long;
    fx.term.rt.editor_lines = many;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0;

    // **최대 열을 세워 두지 않으면 clamp가 매번 0으로 되돌린다** — 그러면 네 측정이 전부 같은
    // 조건이 되어 "평평하다"는 오판이 나온다(실제로 한 번 그렇게 읽을 뻔했다).
    _ = scrollCols(fx.session, fx.term, leaf, -1, null);
    // 셈이 상한(`max_cols_count_limit`)에서 멈추므로 줄 길이(20만)가 아니라 그 값이 나온다 —
    // 갈 수 있는 거리는 그것으로 충분하다.
    try testing.expectEqual(chrome_editor.frame.max_cols_count_limit, fx.term.rt.editor_max_cols);

    for ([_]u16{ 0, 20_000, 60_000 }) |col| {
        fx.term.rt.editor_first_col = col;
        // 한 번 그려 캐시·경로를 덥힌 뒤 잰다.
        var warm = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
        warm.dl.deinit(allocator);

        const t0 = monotonicMsForTest();
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            var d = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
            d.dl.deinit(allocator);
        }
        const t1 = monotonicMsForTest();
        std.debug.print("\n[측정] first_col={d}(그린 값 {d}): 4프레임 {d}ms\n", .{ col, fx.term.rt.editor_first_col, t1 - t0 });
        // 고치기 전 60,000열은 4프레임에 **약 2초**였다. 재앙 감지선이지 예산이 아니다.
        try testing.expect(t1 - t0 < 500);
    }
}

test "가로 스크롤에 §3.8 상한이 있다 — 무한히 밀리지 않는다" {
    // 렌더 비용이 **밀린 거리**에 비례하므로(그 상수의 doc) 상한 없이는 초장문 줄에서 프레임이
    // 죽는다. 구조적 해결(열↔byte 인덱스)이 오면 이 상한은 없어진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // 상한보다 **훨씬** 긴 줄 — 아니면 상한이 걸리는지 알 수 없다.
    const lines = try hscrollFixtureLines(allocator, &fx, @as(usize, chrome_editor.frame.max_first_col) * 5);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    try testing.expect(scrollCols(fx.session, fx.term, leaf, -1_000_000, null));
    try testing.expectEqual(chrome_editor.frame.max_first_col, fx.term.rt.editor_first_col);

    // 그리기 직전 되돌림도 같은 상한을 쓴다 — 두 곳이 갈리면 프레임마다 값이 튄다.
    var drawn = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expectEqual(chrome_editor.frame.max_first_col, fx.term.rt.editor_first_col);
}

test "[측정] minified 한 줄(5MB)에서 첫 가로 휠" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const huge = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(huge);
    @memset(huge, 'x');
    const lines = try allocator.alloc([]const u8, 1);
    defer allocator.free(lines);
    lines[0] = huge;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0;

    chrome_editor.content.total_steps = 0;
    const t0 = monotonicMsForTest();
    _ = scrollCols(fx.session, fx.term, leaf, -1, null);
    const t1 = monotonicMsForTest();
    std.debug.print("\n[측정] 5MB 한 줄: 첫 가로 휠 {d}ms (max_cols={d}, 셈 상한={d}, 걸음 {d})\n", .{ t1 - t0, fx.term.rt.editor_max_cols, chrome_editor.frame.max_cols_count_limit, chrome_editor.content.total_steps });
    // 고치기 전 149ms. **줄 길이와 무관해야 한다** — 셈이 상한에서 멈추므로. 시간 대신 **훑은
    // 걸음 수**로 잰다: 5MB(5,242,880)가 아니라 상한 근처여야 한다. 시간으로 재면 러너 부하와
    // 구분이 안 되고, 걸음 수는 안 흔들린다.
    try testing.expect(chrome_editor.content.total_steps <= chrome_editor.frame.max_cols_count_limit + 1);
    try testing.expectEqual(chrome_editor.frame.max_cols_count_limit, fx.term.rt.editor_max_cols);

    // **상한에 걸려도 갈 수 있는 거리는 그대로다.** 셈을 줄인 것이 도달 범위를 줄이면 안 된다.
    try testing.expect(scrollCols(fx.session, fx.term, leaf, -1_000_000, null));
    try testing.expectEqual(chrome_editor.frame.max_first_col, fx.term.rt.editor_first_col);
}

test "적대적: 유효 UTF-8인 바이너리(NUL 1MB 한 줄)를 열어도 프레임이 죽지 않는다" {
    // `NotUtf8`은 막지만 **NUL은 유효한 UTF-8**이라 통과한다. §3.8이 NUL마다 `<U+0000>` 8칸 표기를
    // 그리므로 1MB 한 줄이면 8M 열이다 — 렌더·랩·가로 스크롤이 전부 그 위에서 돈다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // 8 MiB로도 재 봤다: 랩 프레임이 4ms → 5ms로 **선형이 아니다**(§3.8 축소가 잡는다).
    const nuls = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(nuls);
    @memset(nuls, 0);
    const lines = try allocator.alloc([]const u8, 1);
    defer allocator.free(lines);
    lines[0] = nuls;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_max_cols = 0;

    for ([_]bool{ false, true }) |wrap| {
        fx.term.rt.editor_wrap = wrap;
        const t0 = monotonicMsForTest();
        var d = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
        d.dl.deinit(allocator);
        const t1 = monotonicMsForTest();
        std.debug.print("\n[적대] NUL 1MB 한 줄 wrap={}: 프레임 {d}ms\n", .{ wrap, t1 - t0 });
        try testing.expect(t1 - t0 < 200); // 재앙 감지선(실측 1~4ms)
    }

    fx.term.rt.editor_wrap = false;
    const t2 = monotonicMsForTest();
    _ = scrollCols(fx.session, fx.term, leaf, -1_000_000, null);
    const t3 = monotonicMsForTest();
    std.debug.print("[적대] NUL 1MB: 끝까지 가로 밀기 {d}ms (first_col={d})\n", .{ t3 - t2, fx.term.rt.editor_first_col });
    const t4 = monotonicMsForTest();
    var d2 = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    d2.dl.deinit(allocator);
    const t5 = monotonicMsForTest();
    std.debug.print("[적대] NUL 1MB: 밀린 상태 프레임 {d}ms\n", .{t5 - t4});
    try testing.expect(t5 - t4 < 200); // 실측 1ms
}

test "한 줄짜리 문서도 조각으로 움직인다 — 예전엔 전혀 못 움직였다" {
    // `editor_first_line`은 **논리 줄**이라 문서가 한 줄이면 값이 0 하나뿐이다. 예전에는 그래서 랩으로
    // 시각 행이 2,248개가 되어도 첫 화면 밖을 볼 방법이 없었다 — §4.1d의 조각 오프셋이 그것을 닫았다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const huge = try allocator.alloc(u8, 200_000);
    defer allocator.free(huge);
    @memset(huge, 'x');
    const lines = try allocator.alloc([]const u8, 1);
    defer allocator.free(lines);
    lines[0] = huge;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    var d = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    d.dl.deinit(allocator);
    std.debug.print("\n[적대] 한 줄 랩: 시각 행={d}, 논리 줄={d}\n", .{ fx.term.rt.editor_total_visual_rows, lines.len });
    try testing.expect(fx.term.rt.editor_total_visual_rows > 1000); // 실제로 아주 많이 접혔다

    // **그 구멍은 닫혔다(§4.1d).** 이 테스트는 "지금 이렇다"를 고정하고 있었고, 조각 단위 스크롤이
    // 붙으면 뒤집혀야 한다고 적어 뒀다 — 그대로 뒤집는다. 논리 줄은 하나뿐이라 0에 머물지만
    // **조각이 움직여** 첫 화면 밖을 볼 수 있다.
    _ = scrollLines(fx.session, fx.term, leaf, -1_000_000);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
    try testing.expect(fx.term.rt.editor_first_piece > 0);
}

test "좁은 창에서 센 최대 열이 넓은 창의 도달 거리를 줄이지 않는다" {
    // 최대 열 셈은 `max_cols_count_limit`에서 멈춘다. 그 값이 `max_first_col`과 같으면(여유분이
    // 없으면) 좁은 창에서 센 뒤 창을 넓혔을 때 `max_cols - visible`이 상한보다 작아져 **갈 수 있는
    // 거리가 줄어든다**. 여유분 4,096이 그것을 막는다 — 그 이유를 지키는 테스트가 없었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, @as(usize, chrome_editor.frame.max_first_col) * 10);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    // 좁은 창에서 센다.
    const narrow: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
    _ = scrollCols(fx.session, fx.term, narrow, -1, null);
    const counted = fx.term.rt.editor_max_cols;
    try testing.expectEqual(chrome_editor.frame.max_cols_count_limit, counted);

    // **창이 아주 넓어졌다.** 셈은 다시 하지 않는다(캐시) — 그래도 상한까지 갈 수 있어야 한다.
    const wide: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 4000, .h = 400 };
    try testing.expect(scrollCols(fx.session, fx.term, wide, -1_000_000, null));
    try testing.expectEqual(chrome_editor.frame.max_first_col, fx.term.rt.editor_first_col);
    try testing.expectEqual(counted, fx.term.rt.editor_max_cols); // 다시 세지 않았다
}

test "가로로 밀어도 컨트롤 플레인은 같은 사실을 말한다 — 위치는 메타가 아니다" {
    // 비교 Term에는 세로에 같은 계약의 테스트가 있다(`editor_diff.zig`). **새 축에도 같은 것이
    // 필요하다** — 메타(경로·읽기 전용)가 가로 위치에 따라 흔들리면 밖에서 보는 쪽이 "다른 파일이
    // 열렸다"고 오해한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try hscrollFixtureLines(allocator, &fx, 500);
    const long_buf = lines[1];
    defer allocator.free(long_buf);
    defer allocator.free(lines);

    const before = editor_diff_ops.editorMeta(fx.term);
    try testing.expect(scrollCols(fx.session, fx.term, leaf, -50, null));
    try testing.expect(fx.term.rt.editor_first_col > 0); // 실제로 밀렸다 — 아니면 공허하다
    var drawn = appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const after = editor_diff_ops.editorMeta(fx.term);
    try testing.expectEqual(before.read_only, after.read_only);
    try testing.expectEqualStrings(before.path.?, after.path.?);
}

test "안 넘치면 편집기가 가로 축을 가져가지 않는다 — 탭 바가 실제로 굴러야 한다" {
    // **이 테스트가 없어서 뮤턴트가 전체 테스트를 통과했다**(2026-08-16). 기존 라우팅 테스트는
    // `tab_wheel_accum`으로 판정했는데, 그 값은 라우팅 **이전에** `wheelDeltaToLines`가 건드리므로
    // 편집기가 축을 통째로 삼켜도 움직인다 — 아무것도 증명하지 못했다.
    //
    // 그래서 두 가지로 본다: ⑴ `scrollCols`가 **false**를 돌려주는가, ⑵ 탭 바가 **실제로 굴렀는가**
    // (`tab_scroll_cols`). ⑵는 탭이 넘쳐야 관측되므로 탭을 여러 개 만든다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;
    fx.term.rt.editor_wrap = false;

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    // ⑴ 짧은 문서 — 이 축으로 할 일이 없다.
    try testing.expect(!scrollCols(fx.session, fx.term, leaf, -20, null));
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);

    // ⑵ 탭 바가 넘치게 탭을 늘린 뒤, 편집기 pane 위에서 가로로 굴린다.
    const pane = pane_ops.activePane(fx.session);
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const t = try createEditorTerm(fx.session);
        try pane.terms.append(allocator, t);
    }
    fx.session.focusTerm(0); // 편집기 Term을 다시 활성으로

    const win = fx.session.termRect();
    const x: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) / 2.0;
    const y: f64 = @as(f64, @floatFromInt(win.y)) + @as(f64, @floatFromInt(win.h)) / 2.0;
    const before = pane.tab_scroll_cols;
    scroll_ops.scrollWheel(fx.session, 0, -4.0 * @as(f64, @floatFromInt(fx.session.cell_width_px)), true, x, y);
    try testing.expect(pane.tab_scroll_cols != before); // 탭 바가 실제로 굴렀다
}

test "분할된 pane: 가로 휠도 커서 아래 편집기만 민다 — 옆 pane은 그대로다" {
    // **세로에는 같은 격리 테스트가 있는데 가로에는 없었다.** 라우팅 코드는 공유하지만, 가로는
    // "넘칠 때만 소유한다"는 판정이 하나 더 붙어 경로가 갈린다 — 옆 pane 위에서 굴렸는데 이쪽이
    // 밀리면 사용자는 이유를 알 수 없다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    // 두 pane 모두 **긴 줄**을 들어야 한다 — 안 넘치면 편집기가 축을 안 가져가 판정이 공허해진다.
    const long_line = try allocator.alloc(u8, 4000);
    defer allocator.free(long_line);
    @memset(long_line, 'x');
    const lines = try allocator.alloc([]const u8, 3);
    defer allocator.free(lines);
    lines[0] = "short";
    lines[1] = long_line;
    lines[2] = "short";

    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = lines;
    defer fx.term.rt.editor_lines = saved;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0;

    const tab = tab_ops.activeTab(fx.session);
    const left_pane = tab.panes.items[0];
    const right_pane = try allocator.create(app_session_mod.Pane);
    right_pane.* = .{};
    const right_term = try createEditorTerm(fx.session);
    right_term.rt.editor_lines = lines;
    right_term.rt.editor_wrap = false;
    try right_pane.terms.append(allocator, right_term);
    try tab.panes.append(allocator, right_pane);

    const split = try allocator.create(app_session_mod.PaneTree.Split);
    split.* = .{ .direction = .horizontal, .ratio = 0.5, .a = .{ .leaf = left_pane }, .b = .{ .leaf = right_pane } };
    try testing.expect(app_session_mod.PaneTree.replaceLeaf(&tab.tree, left_pane, .{ .split = split }));
    // 세운 것은 여기서 되돌린다(세로 격리 테스트와 같은 규율 — 세션 해체에 맡기면 소유가 어긋난다).
    defer {
        tab.tree = .{ .leaf = left_pane };
        allocator.destroy(split);
        _ = tab.panes.pop();
        right_term.rt.editor_lines = &.{}; // 빌린 배열이라 Term이 해제하면 안 된다
        term_ops.destroyTerm(fx.session, right_term);
        right_pane.terms.deinit(allocator);
        allocator.destroy(right_pane);
    }

    const win = fx.session.termRect();
    const y: f64 = @as(f64, @floatFromInt(win.y)) + @as(f64, @floatFromInt(win.h)) / 2.0;
    const dx: f64 = -3.5 * @as(f64, @floatFromInt(fx.session.cell_width_px));

    // 오른쪽 절반에서 가로로 굴린다.
    const rx: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) * 0.75;
    scroll_ops.scrollWheel(fx.session, 0, dx, true, rx, y);
    try testing.expect(right_term.rt.editor_first_col > 0); // 커서 아래가 밀렸다
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col); // 옆 pane은 그대로다

    // 왼쪽 절반이면 반대가 된다.
    const before_right = right_term.rt.editor_first_col;
    const lx: f64 = @as(f64, @floatFromInt(win.x)) + @as(f64, @floatFromInt(win.w)) * 0.25;
    scroll_ops.scrollWheel(fx.session, 0, dx, true, lx, y);
    try testing.expect(fx.term.rt.editor_first_col > 0);
    try testing.expectEqual(before_right, right_term.rt.editor_first_col);
}

test "랩을 켠 한 줄짜리 문서도 세로로 움직인다 — 조각 단위 스크롤(§4.1d)" {
    // **이 슬라이스가 닫은 구멍이다.** 예전에는 `editor_first_line`이 논리 줄이라 값이 0 하나뿐이었고,
    // 시각 행이 2,000개가 넘어도 첫 화면 밖을 볼 방법이 없었다(minified 파일을 랩으로 연 상태).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const huge = try allocator.alloc(u8, 200_000);
    defer allocator.free(huge);
    @memset(huge, 'x');
    const lines = try allocator.alloc([]const u8, 1);
    defer allocator.free(lines);
    lines[0] = huge;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    var first = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    first.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_total_visual_rows > 1000); // 실제로 아주 많이 접혔다

    // ① 내려간다 — 논리 줄은 하나뿐이므로 **조각만** 움직인다.
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -5);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
    try testing.expectEqual(@as(u32, 5), fx.term.rt.editor_first_piece);

    // ② 화면이 실제로 바뀐다 — 상태만 움직이고 렌더가 안 따라오면 아무 일도 안 일어난다.
    var moved = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer moved.dl.deinit(allocator);
    try testing.expect(moved.dl.cells.len > 0);

    // ③ 끝까지 가면 멈추고, 그 화면은 비지 않는다.
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1_000_000);
    const end_piece = fx.term.rt.editor_first_piece;
    try testing.expect(end_piece > 5);
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1_000_000);
    try testing.expectEqual(end_piece, fx.term.rt.editor_first_piece);

    // ④ 되돌아온다.
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, 1_000_000);
    try testing.expectEqual(@as(u32, 0), fx.term.rt.editor_first_piece);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "적대적: 조각 스크롤은 한 칸씩 N번과 N칸 한 번이 같다" {
    // **Vim `smoothscroll`이 off-by-one을 쏟은 자리다**(9.1.0211·0258·0260·0407). 걸음 계산이
    // 줄 경계에서 하나 어긋나면 이 두 경로가 갈린다 — 사람 눈으로는 "가끔 한 행씩 튄다"로 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    // 줄 길이를 섞는다 — 한 조각짜리와 여러 조각짜리가 번갈아야 경계가 실제로 걸린다.
    var prng = std.Random.DefaultPrng.init(0x9105);
    const rnd = prng.random();

    for ([_]i32{ 1, 2, 3, 7, 13 }) |step| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        var bufs: [40][]u8 = undefined;
        var n: usize = 0;
        defer for (bufs[0..n]) |b| allocator.free(b);
        const lines = try allocator.alloc([]const u8, 40);
        defer allocator.free(lines);
        while (n < 40) : (n += 1) {
            const len = rnd.uintLessThan(usize, 300) + 1;
            bufs[n] = try allocator.alloc(u8, len);
            @memset(bufs[n], 'x');
            lines[n] = bufs[n];
        }
        fx.term.rt.editor_lines = lines;
        fx.term.rt.editor_wrap = true;

        var warm = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        warm.dl.deinit(allocator);

        // ① 한 칸씩 step번
        fx.term.rt.editor_first_line = 0;
        fx.term.rt.editor_first_piece = 0;
        var k: i32 = 0;
        while (k < step) : (k += 1) _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1);
        const by_one_line = fx.term.rt.editor_first_line;
        const by_one_piece = fx.term.rt.editor_first_piece;

        // ② step칸 한 번
        fx.term.rt.editor_first_line = 0;
        fx.term.rt.editor_first_piece = 0;
        _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -step);
        try testing.expectEqual(by_one_line, fx.term.rt.editor_first_line);
        try testing.expectEqual(by_one_piece, fx.term.rt.editor_first_piece);

        // **정말 그만큼 갔는지 직접 센다** — 두 경로가 나란히 틀리면 ①②는 통과한다.
        const cols = visibleCols(fx.session, editorBodyRect(fx.session, fx.leaf_rect, fx.term), fx.term, false);
        var walked: u32 = 0;
        for (0..by_one_line) |i| walked += piecesOfLine(fx.term, i, cols);
        walked += by_one_piece;
        try testing.expectEqual(@as(u32, @intCast(step)), walked);
        try testing.expect(by_one_line > 0 or by_one_piece > 0); // 실제로 움직였다

        // ③ 내려갔다 올라오면 제자리다(상한에 안 닿는 거리에서).
        _ = scrollLines(fx.session, fx.term, fx.leaf_rect, step);
        try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
        try testing.expectEqual(@as(u32, 0), fx.term.rt.editor_first_piece);
    }
}

test "4096줄을 넘는 랩 문서의 시각 행 수가 근사가 아니다 — 스크롤바 길이가 여기서 나온다" {
    // **예전에는 앞에서부터 4,096줄만 세고 나머지를 "논리 줄 하나"로 쳤다**(계수 상한이 호출자가 준
    // 스택 `[4096]u32`였다). 그러면 20,000줄 랩 문서의 시각 행이 40,000이 아니라 24,096으로 나와
    // **막대가 실제보다 1.66배 길게** 뜬다 — 문서가 짧다고 판정되기 때문이다.
    //
    // 이 근사는 **조용하다**: op도 크래시도 정상이고 막대 길이만 어긋난다. §2.1 캐시(`RowCache`)가
    // 그 상한을 없앴고, 이 테스트가 되돌아오는 것을 막는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long_line = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const n = 5_000; // 상한(4,096)을 넘는다
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    for (lines) |*l| l.* = long_line;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    // **점진 계수라 한 프레임에 끝나지 않는다**(§2.1) — 다 셀 때까지 프레임을 돌린다. 제품에서는
    // 렌더가 `metal_dirty`로 그 프레임을 스스로 부른다.
    var first = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    first.dl.deinit(allocator);
    const after_one = fx.term.rt.editor_total_visual_rows;

    var frames: usize = 1;
    while (fx.term.rt.editor_row_cache.filled_upto < n) : (frames += 1) {
        if (frames > 64) return error.ProgressiveCountDidNotFinish; // 진행이 멈추면 여기서 드러난다
        var step = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        step.dl.deinit(allocator);
    }

    // 기대값은 손으로 적지 않는다 — 렌더가 쓰는 그 계수로 한 줄을 재고 줄 수를 곱한다(모든 줄이 같다).
    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const per_line = piecesOfLine(fx.term, 0, visibleColsForTest(fx.session, body, fx.term, false));
    try testing.expect(per_line > 1); // 실제로 접혔다 — 아니면 이 테스트가 아무것도 안 본다
    try testing.expectEqual(per_line * n, fx.term.rt.editor_total_visual_rows);

    // **진행 중에는 실제보다 짧게 보인다**(안 센 줄을 한 행으로 치므로). 그 성질을 여기서 못박는다 —
    // 근사가 반대로(실제보다 길게) 나오면 막대가 문서 밖을 가리킨다.
    try testing.expect(after_one < per_line * n);
    try testing.expect(frames > 1); // 정말 나눠 셌다
}

test "적대적: 4096줄을 넘는 랩 문서도 끝에 닿는다" {
    // 상한(`max_top`)은 렌더가 센 `row_counts`를 **뒤에서부터** 훑어 구하는데, 그 배열은 문서
    // **앞에서부터** 4096줄만 채워진다. 뒤쪽 줄은 "1행"으로 근사되므로, 실제로는 여러 조각인 줄들이
    // 한 행으로 계산돼 **끝이 손에 안 닿는다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long_line = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const lines = try allocator.alloc([]const u8, 5000);
    defer allocator.free(lines);
    for (lines) |*l| l.* = long_line;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    var warm = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    warm.dl.deinit(allocator);

    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1_000_000);
    var at_end = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer at_end.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = inner_h / fx.session.cell_height_px;
    const cols = visibleCols(fx.session, body, fx.term, false);
    const pieces_per_line = piecesOfLine(fx.term, 4999, cols);
    try testing.expect(pieces_per_line > 1); // 실제로 접힌다 — 아니면 판정이 공허하다

    // **"화면이 꽉 찬다"로는 이 결함을 못 잡는다** — 일찍 멈춰도 뒤에 줄이 많으면 꽉 찬다.
    // 진짜 판정은 **마지막 줄이 화면에 들어오는가**다.
    var drawn_rows: usize = 0;
    for (at_end.dl.cells) |c| drawn_rows = @max(drawn_rows, @as(usize, c.row) + 1);
    const lines_on_screen = visible / pieces_per_line;
    std.debug.print("\n[적대] 5000줄 랩: first_line={d}, 줄당 {d}조각, 화면에 {d}줄 → 마지막 줄 {d}\n", .{ fx.term.rt.editor_first_line, pieces_per_line, lines_on_screen, fx.term.rt.editor_first_line + lines_on_screen });
    try testing.expectEqual(visible, drawn_rows); // 화면은 꽉 찬다
    try testing.expect(fx.term.rt.editor_first_line + lines_on_screen >= lines.len); // **마지막 줄에 닿는다**
}

test "override 없이 연 편집기는 config 기본을 따른다 — 되돌림이 실제로 관측된다" {
    // **기본값을 바꿨는데 테스트가 하나도 안 깨졌다.** 대부분이 `editor_wrap` override를 명시하기
    // 때문인데, 그렇다면 "기본값이 진짜 읽히는가"를 확인한 테스트가 없다는 뜻이기도 하다.
    // override를 **세우지 않고** 열어 기본 동작을 직접 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    try testing.expect(fx.term.rt.editor_wrap == null); // 새로 연 뷰는 config를 따른다
    try testing.expectEqual(false, fx.session.loaded_config.config.editor.wrap); // 되돌린 기본값

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long = try allocator.alloc(u8, 2000);
    defer allocator.free(long);
    @memset(long, 'x');
    const lines = try allocator.alloc([]const u8, 3);
    defer allocator.free(lines);
    lines[0] = "short";
    lines[1] = long;
    lines[2] = "short";
    fx.term.rt.editor_lines = lines;
    // **새 내용이다 — 가장 긴 줄 캐시를 버린다.** 픽스처는 실제 파일을 열고, 여는 경로가 그 파일
    // 기준으로 폭을 세어 둔다(가로 막대가 첫 프레임부터 서야 하므로). 줄 배열만 갈아 끼우는 것은
    // 테스트의 방식이지 제품 경로가 아니다 — 제품에서 문서가 바뀌면 늘 새 Term이다.
    fx.term.rt.editor_max_cols = 0;

    // ① 랩이 아니므로 접히지 않는다 — 시각 행 수가 논리 줄 수와 같다.
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expectEqual(@as(u32, @intCast(lines.len)), fx.term.rt.editor_total_visual_rows);

    // ② 그래서 가로 축을 편집기가 가져간다(랩이면 안 가져간다).
    try testing.expect(scrollCols(fx.session, fx.term, fx.leaf_rect, -20, null));
    try testing.expect(fx.term.rt.editor_first_col > 0);

    // ③ config를 도로 켜면 반대가 된다 — 이 테스트가 기본값을 **읽는지**까지 본다.
    fx.session.loaded_config.config.editor.wrap = true;
    fx.term.rt.editor_total_visual_rows = 0;
    var wrapped = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer wrapped.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_total_visual_rows > lines.len); // 접혔다
    try testing.expect(!scrollCols(fx.session, fx.term, fx.leaf_rect, -20, null)); // 가로 축을 안 가져간다
}

test "전체 접기·펼치기 — 접힌 머리가 오름차순이고 다시 할당하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    lines[0] = "a:";
    lines[1] = "  1";
    lines[2] = "  2";
    lines[3] = "b:";
    lines[4] = "  3";
    lines[5] = "c";
    fx.term.rt.editor_lines = lines;

    try testing.expect(foldAll(fx.session));
    const heads = foldedHeads(fx.term);
    try testing.expectEqual(@as(usize, 2), heads.len);
    try testing.expectEqual(@as(u32, 0), heads[0]);
    try testing.expectEqual(@as(u32, 3), heads[1]);
    // **오름차순이어야 한다** — `hiddenSpans`가 그것을 계약으로 요구한다(어기면 조용히 빠뜨린다).
    for (heads[1..], 0..) |h, i| try testing.expect(h > heads[i]);

    // 숨는 구간이 실제로 나온다.
    var sbuf: [8]editor_fold.Span = undefined;
    const spans = editor_fold.hiddenSpans(fx.term.rt.editor_fold_ranges, heads, &sbuf);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expect(editor_fold.isHidden(spans, 1) and editor_fold.isHidden(spans, 4));
    try testing.expect(!editor_fold.isHidden(spans, 0) and !editor_fold.isHidden(spans, 5));

    // **다시 접어도 새로 할당하지 않는다** — 버퍼를 미리 잡아 뒀다.
    const buf_ptr = fx.term.rt.editor_folded_buf.ptr;
    try testing.expect(unfoldAll(fx.session));
    try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len);
    try testing.expect(foldAll(fx.session));
    try testing.expectEqual(buf_ptr, fx.term.rt.editor_folded_buf.ptr);

    // 펼칠 것이 없으면 `false`(호출자가 무동작을 안다).
    try testing.expect(unfoldAll(fx.session));
    try testing.expect(!unfoldAll(fx.session));
}

test "접을 것이 없는 문서에서는 전체 접기가 무동작이다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const flat = try allocator.alloc([]const u8, 3);
    defer allocator.free(flat);
    for (flat) |*l| l.* = "x";
    fx.term.rt.editor_lines = flat;
    try testing.expect(!foldAll(fx.session));
}

test "diff가 로딩·불가 상태여도 접기를 거절한다 — 화면이 그대로인데 성공을 돌려주면 안 된다" {
    // 비교 뷰의 거짓 성공은 이미 잡았는데(editor_diff.zig), **판정을 뷰 종류로 했다.** diff는
    // `.loading`·`.unavailable`도 상태이고 그때도 렌더는 diff 경로를 타므로, 이 둘은 거절을 그냥
    // 지나갔다. `foldSourceLines`가 그 상태에서 빈 배열을 내기 때문에 **접힘 상태만 서고 화면은
    // 그대로**다 — 비교에서 결함이라고 판정한 것과 같은 부류다(적대적 검증 2026-08-17).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 4);
    defer allocator.free(lines);
    lines[0] = "a:";
    lines[1] = "  1";
    lines[2] = "b:";
    lines[3] = "  2";
    fx.term.rt.editor_lines = lines;

    // 먼저 평범하게 접어 **범위를 만들어 둔다** — diff를 켜기 전에 파일을 열어 본 경로다.
    try testing.expect(foldAll(fx.session));
    try testing.expect(unfoldAll(fx.session));

    defer fx.term.rt.editor_diff = null;
    for ([_]maru.session.editor.diff.View{ .loading, .{ .unavailable = .binary }, .unchanged }) |view| {
        fx.term.rt.editor_diff = .{ .requested_ms = 0 };
        fx.term.rt.editor_diff.?.view = view;
        try testing.expect(!foldAll(fx.session));
        try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len); // 상태도 안 선다
        try testing.expect(!unfoldAll(fx.session));
    }
}

test "접힘 범위 계산이 어디서 할당에 실패해도 새거나 두 번 풀지 않는다" {
    // **같은 자리에서 이중 해제를 세 번 잡았다**(layering §2.0a). 세션 allocator는 init에 고정이라
    // `checkAllAllocationFailures`를 그대로 못 쓴다 — 세션을 실패 allocator로 만들고 **init이 끝난
    // 뒤부터** 실패 지점을 민다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;
    var failed_steps: usize = 0;
    var ok_steps: usize = 0;

    var step: usize = 0;
    while (step < 12) : (step += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        const alloc = fa.allocator();
        var fx = try PaneFixture.init(alloc);
        defer fx.deinit(alloc);

        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;
        const lines = try backing.alloc([]const u8, 4);
        defer backing.free(lines);
        lines[0] = "a:";
        lines[1] = "  1";
        lines[2] = "b:";
        lines[3] = "  2";
        fx.term.rt.editor_lines = lines;

        fa.fail_index = fa.allocations + step;
        if (foldAll(fx.session)) ok_steps += 1 else failed_steps += 1;
        _ = foldAll(fx.session); // 반쯤 지어진 상태에서 다시 불러도 안전해야 한다
        _ = unfoldAll(fx.session);
    }
    // **공허해질 수 없게 센다** — 실패를 한 번도 안 겪으면 아무것도 지키지 않는다.
    try testing.expect(failed_steps >= 1);
    try testing.expect(ok_steps >= 1);
}

test "접으면 화면에서 그 줄들이 사라지고 번호는 원래 값이다" {
    // **상태만 움직이고 렌더가 안 따라오면 아무 일도 안 일어난다.** 접힌 줄의 글자가 화면에서 빠지고,
    // gutter가 **원래 줄 번호**를 그리는지(접힌 만큼 번호가 건너뛰는지) 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 5);
    defer allocator.free(lines);
    lines[0] = "head:";
    lines[1] = "  zzz"; // 접히면 사라질 글자
    lines[2] = "  zzz";
    lines[3] = "tail";
    lines[4] = "more";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;

    var before = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    var z_before: usize = 0;
    for (before.dl.cells) |c| {
        if (c.codepoint == 'z') z_before += 1;
    }
    before.dl.deinit(allocator);
    try testing.expect(z_before > 0); // 접기 전에는 보인다 — 아니면 아래 판정이 공허하다

    try testing.expect(foldAll(fx.session));
    var after = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer after.dl.deinit(allocator);

    var z_after: usize = 0;
    for (after.dl.cells) |c| {
        if (c.codepoint == 'z') z_after += 1;
    }
    try testing.expectEqual(@as(usize, 0), z_after); // **접힌 줄의 글자가 사라졌다**

    // gutter가 원래 번호를 그린다 — 접힌 뒤 화면은 1·4·5줄이므로 '4'가 있어야 한다.
    var saw_four = false;
    for (after.dl.cells) |c| {
        if (c.codepoint == '4') saw_four = true;
    }
    try testing.expect(saw_four);

    // 펼치면 돌아온다.
    try testing.expect(unfoldAll(fx.session));
    var back = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer back.dl.deinit(allocator);
    var z_back: usize = 0;
    for (back.dl.cells) |c| {
        if (c.codepoint == 'z') z_back += 1;
    }
    try testing.expectEqual(z_before, z_back);
}

test "레벨 접기도 화면에 반영된다 — 바깥은 남고 안쪽만 사라지며 화살표 방향이 갈린다" {
    // **상태만 움직이고 렌더가 안 따라오면 아무 일도 안 일어난다.** 전체 접기는 위 테스트가 셀까지
    // 봤지만 레벨 접기는 "어느 겹이 남는가"가 다르다 — 레벨 2를 접으면 바깥(레벨 1) 머리와 그 직속
    // 자식 머리는 보이고, **자식의 몸통만** 사라져야 한다. 그리고 gutter 화살표는 같은 화면에서
    // 갈린다: 바깥은 펼침(▾), 접은 자식은 접힘(▸).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 4);
    defer allocator.free(lines);
    lines[0] = "outer:"; // 레벨 1 머리
    lines[1] = "  inner:"; // 레벨 2 머리
    lines[2] = "    zzz"; // 레벨 2의 몸통 — 이것만 사라져야 한다
    lines[3] = "    zzz";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;

    try testing.expect(foldLevel(fx.session, 2));
    var dl = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer dl.dl.deinit(allocator);

    var z: usize = 0;
    var saw_o = false; // outer의 'o'
    var open_mark = false; // ▾
    var collapsed_mark = false; // 접힘 표식
    // **코드포인트를 여기 적지 않는다** — 컴포넌트가 소유한 글자에서 유도한다(글리프를 바꾸면
    // 이 판정이 조용히 옛 문자를 찾게 된다).
    const open_cp = chrome_editor.gutter.Fold.open.codepoint().?;
    const collapsed_cp = chrome_editor.gutter.Fold.collapsed.codepoint().?;
    for (dl.dl.cells) |c| {
        if (c.codepoint == open_cp) open_mark = true;
        if (c.codepoint == collapsed_cp) collapsed_mark = true;
        switch (c.codepoint) {
            'z' => z += 1,
            'o' => saw_o = true,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), z); // 안쪽 몸통이 사라졌다
    try testing.expect(saw_o); // 바깥은 그대로 보인다
    try testing.expect(open_mark and collapsed_mark); // 두 방향이 같은 화면에 선다
}

test "가로 막대가 첫 프레임부터 선다 — 굴려 보기 전에 축이 있는지 알 수 있다" {
    // **이것이 이 슬라이스의 이유다.** 예전에는 가장 긴 줄을 *첫 가로 휠에서* 셌기 때문에, 굴려
    // 보기 전에는 막대가 없어 그 축이 있는지도 알 수 없었다(2026-08-18 사용자 지적).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long = try allocator.alloc(u8, 2000);
    defer allocator.free(long);
    @memset(long, 'x');
    const lines = try allocator.alloc([]const u8, 3);
    defer allocator.free(lines);
    lines[0] = "short";
    lines[1] = long;
    lines[2] = "short";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0;
    ensureMaxCols(fx.term, false); // 여는 경로가 부르는 그대로 — 휠은 아직 안 왔다

    try testing.expect(fx.term.rt.editor_max_cols > 1000);
    fx.session.gpu_quads.clearRetainingCapacity(); // 앞선 프레임의 quad가 섞이면 판정이 공허해진다
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 막대는 셀이 아니라 **quad**로 내려간다(격자 밖이라 `fill`은 조용히 버려진다).
    // **자리로 가른다**: 가로 막대는 본문 아래에 서고(y가 본문 바닥보다 크다), 세로 막대는 오른쪽
    // 이라 y가 본문 안이다. 두께·길이로 가르면 thumb이 최소 길이로 clamp될 때 판정이 뒤집힌다.
    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const inset: f32 = @floatFromInt(chrome_editor.frame.content_inset_px);
    const body_top: f32 = @floatFromInt(body.y);
    const body_h: f32 = @floatFromInt(body.h);
    var below: usize = 0;
    for (fx.session.gpu_quads.items) |q| {
        // 본문 아래 절반쯤에서 시작하고 **얇은** quad — 배경(본문 전체를 덮는다)과 갈린다.
        if (q.y > body_top + body_h / 2 and q.h <= inset * 4) below += 1;
    }
    try testing.expect(below > 0);

    // 랩을 켜면 넘칠 것이 없다 — 축 자체가 사라진다(§4).
    fx.term.rt.editor_wrap = true;
    fx.term.rt.editor_total_visual_rows = 0;
    var wrapped = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer wrapped.dl.deinit(allocator);
    try testing.expect(!chrome_editor.frame.showsHorizontalBar(true, fx.term.rt.editor_max_cols, 40));
}

test "폭 드래그 중에는 시각 행을 다시 세지 않고, 놓으면 정확해진다 (§2.1 저하 동작)" {
    // **제품 경로로 증명한다.** 컴포넌트의 `hold`가 켜지는 조건은 제품이 정하므로(`widthDragActive`),
    // 그 배선이 빠지면 컴포넌트 테스트는 그대로 초록인 채 화면만 뻑뻑해진다.
    //
    // 창 리사이즈는 여기 대상이 아니다 — `windowDidResize`가 드래그 중 세션 resize를 보류한다.
    // 라이브로 폭을 끄는 것은 사이드바 경계와 pane divider 둘이고, 여기서는 앞의 것으로 세운다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long_line = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const lines = try allocator.alloc([]const u8, 400);
    defer allocator.free(lines);
    for (lines) |*l| l.* = long_line;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    var first = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    first.dl.deinit(allocator);
    const before = fx.term.rt.editor_total_visual_rows;
    try testing.expect(before > lines.len); // 실제로 접혔다 — 아니면 이 테스트가 아무것도 안 본다

    // ① 드래그 중: 폭을 여러 셀 줄여도 시각 행 수는 직전 값 그대로다.
    //
    // **폭을 끄는 제스처가 셋이라 셋을 다 본다.** dock을 빠뜨린 채로 첫 구현이 나갔고 적대적 검증이
    // 그것을 잡았다 — 한 제스처만 검증하면 나머지가 조용히 빠진다(pane divider는 `InteractionState`가
    // 들어 여기서 세울 수 없으므로 `PointerGestureOwner` 둘을 본다).
    var held = fx.leaf_rect;
    held.w = @divTrunc(held.w, 2);

    fx.session.pointer_gesture_owner = .{ .sidebar_divider = .{ .start_pt = 0 } };
    var by_sidebar = appendPaneFrame(fx.session, held, fx.term) orelse return error.EditorPaneDidNotDraw;
    by_sidebar.dl.deinit(allocator);
    try testing.expectEqual(before, fx.term.rt.editor_total_visual_rows);

    // **dock도 같은 축이다** — `setDockSizeFromPointer`는 dock이 `.right`면 x를 끌고 `resizeTabPanes`로
    // 전 탭 pane을 다시 재운다. 첫 구현이 이 경로를 빠뜨렸고 적대적 검증이 잡았다.
    fx.session.pointer_gesture_owner = .{ .dock_outer_divider = .{ .offset_px = 0 } };
    var by_dock = appendPaneFrame(fx.session, held, fx.term) orelse return error.EditorPaneDidNotDraw;
    by_dock.dl.deinit(allocator);
    try testing.expectEqual(before, fx.term.rt.editor_total_visual_rows);

    fx.session.pointer_gesture_owner = .{ .sidebar_divider = .{ .start_pt = 0 } };
    var narrow = fx.leaf_rect;
    // **조각 수가 실제로 달라질 만큼 좁힌다.** 몇 셀만 줄이면 같은 조각 수가 나와(실측: 10셀 축소에
    // 800행 그대로) 저하가 걸렸는지 안 걸렸는지 이 테스트가 구분하지 못한다.
    narrow.w = @divTrunc(narrow.w, 2);
    var during = appendPaneFrame(fx.session, narrow, fx.term) orelse return error.EditorPaneDidNotDraw;
    during.dl.deinit(allocator);
    try testing.expectEqual(before, fx.term.rt.editor_total_visual_rows);

    // ② 놓으면: 같은 폭인데 이번에는 다시 세어 좁아진 만큼 늘어난다.
    fx.session.pointer_gesture_owner = .none;
    var after = appendPaneFrame(fx.session, narrow, fx.term) orelse return error.EditorPaneDidNotDraw;
    after.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_total_visual_rows > before);
}

test "첫 프레임이 드래그 중이어도 시각 행은 정확하다 — 저하할 직전 값이 없다" {
    // 사이드바를 끌기 시작한 뒤 그 pane에 문서가 처음 그려지는 순서다. 저하가 "값이 없을 때"까지
    // 적용되면 막대가 통째로 틀린 채 드래그 내내 남는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long_line = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const lines = try allocator.alloc([]const u8, 400);
    defer allocator.free(lines);
    for (lines) |*l| l.* = long_line;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    fx.session.pointer_gesture_owner = .{ .sidebar_divider = .{ .start_pt = 0 } };
    defer fx.session.pointer_gesture_owner = .none;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const per_line = piecesOfLine(fx.term, 0, visibleColsForTest(fx.session, body, fx.term, false));
    try testing.expect(per_line > 1);
    try testing.expectEqual(per_line * @as(u32, @intCast(lines.len)), fx.term.rt.editor_total_visual_rows);
}

test "[측정] 드래그를 놓는 순간 — 점진 계수가 그 값을 프레임에 나눈다 (§2.1)" {
    // 저하 동작이 드래그 **중**을 닫았고, 남은 것은 **놓는 순간**이었다. 점진 계수(§2.1) 전에는 그
    // 프레임에서 전 문서를 한 번 세어 2만 줄에 **62ms**가 튀었다(측정 근거, ReleaseFast). 지금은
    // `count_chunk_lines`씩 나눠 세므로 프레임당 그 몫만 든다 — 대신 정확해지기까지 여러 프레임이
    // 걸리고, 그동안 막대는 실제보다 짧다(안 센 줄을 한 행으로 친다).
    //
    // **워커로 가지 않은 이유는 §2.1에 적었다** — 랩 계수는 줄마다 독립이라 나눌 수 있고, 스레딩의
    // 유지보수 비용(스냅샷 수명·revision 폐기·비결정적 테스트)이 이득보다 크다.
    //
    // **비교 대상을 함께 찍는다.** 같은 문서를 여는 경로에도 문서 크기에 비례하는 값이 이미 있다
    // (`ensureMaxCols` — 가장 긴 줄 세기). 놓는 순간의 값이 그것과 같은 급이면 "이미 받아들이고 있는
    // 비용"이고, 훨씬 크면 다른 판단이 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    for ([_]usize{ 5_000, 20_000 }) |n| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        const lines = try allocator.alloc([]const u8, n);
        defer allocator.free(lines);
        for (lines) |*l| l.* = "const x = 1; // " ++ ("긴 줄이라 랩이 일어난다 " ** 6);
        fx.term.rt.editor_lines = lines;
        fx.term.rt.editor_wrap = true;
        fx.term.rt.editor_max_cols = 0;

        var warm = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        warm.dl.deinit(allocator);

        // ① 드래그: 저하가 걸린 채 폭을 여러 번 끈다(여기는 이미 싸다 — 앞 측정이 0.2ms).
        fx.session.pointer_gesture_owner = .{ .dock_outer_divider = .{ .offset_px = 0 } };
        const cell_w: u32 = @intCast(fx.session.cell_width_px);
        var final_rect = fx.leaf_rect;
        for (0..10) |i| {
            var rect = fx.leaf_rect;
            rect.w -= @intCast(cell_w * (i + 1));
            final_rect = rect;
            var drawn = appendPaneFrame(fx.session, rect, fx.term) orelse return error.EditorPaneDidNotDraw;
            drawn.dl.deinit(allocator);
        }

        // ② 놓는다: 같은 폭인데 이번에는 센다. 이 한 프레임이 재는 대상이다.
        fx.session.pointer_gesture_owner = .none;
        const t0 = monotonicMsForTest();
        var settle = appendPaneFrame(fx.session, final_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        const t1 = monotonicMsForTest();
        settle.dl.deinit(allocator);

        // ③ 그 다음 프레임: 캐시가 맞으므로 공짜여야 한다. 아니면 "한 번"이 아니라 지속 비용이다.
        const t2 = monotonicMsForTest();
        var after = appendPaneFrame(fx.session, final_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        const t3 = monotonicMsForTest();
        after.dl.deinit(allocator);

        // ④ 비교: 같은 문서를 여는 경로에 이미 있는 문서 크기 비례 값.
        fx.term.rt.editor_max_cols = 0;
        const t4 = monotonicMsForTest();
        ensureMaxCols(fx.term, false);
        const t5 = monotonicMsForTest();

        std.debug.print("\n[측정] {d}줄 — 놓는 프레임 {d}ms, 다음 프레임 {d}ms, (비교) 여는 경로 가장 긴 줄 세기 {d}ms\n", .{
            n,
            t1 - t0,
            t3 - t2,
            t5 - t4,
        });
    }
}

test "세로 막대를 끌면 문서가 그만큼 움직인다 — px를 (줄, 조각)으로 되짚는다" {
    // 막대는 **시각 행 × 셀 높이**로 만들어지는데 편집기 좌표는 `(논리 줄, 조각)`이다. 랩 때문에 둘은
    // 비선형이라 비율로 근사하면 손가락과 화면이 어긋난다 — 접두합을 되짚어야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // **줄 길이를 섞는다.** 모두 같은 길이면 시각 행 ↔ 논리 줄이 **선형**이라, 접두합을 안 쓰고 비율로
    // 근사해도 같은 답이 나온다 — 그러면 이 테스트가 역매핑을 검증하지 못한다(뮤턴트로 확인했다).
    const long_line = "이 줄은 좁은 pane에서 여러 조각으로 접힐 만큼 길다 — 그래야 시각 행이 논리 줄보다 많아진다";
    const lines = try allocator.alloc([]const u8, 600);
    defer allocator.free(lines);
    // 앞쪽 절반은 짧고 뒤쪽 절반은 길다 — **한쪽에 몰려야** 비선형이다. 균등하게 섞으면 논리 줄 절반이
    // 시각 행도 절반이라 비율 근사와 답이 같아진다(그 픽스처로는 뮤턴트가 안 죽는 것을 확인했다).
    for (lines, 0..) |*l, i| l.* = if (i < lines.len / 2) "짧다" else long_line;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    // 계수가 끝날 때까지 그린다(점진 계수 — §2.1). 그래야 접두합이 정확하다.
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        var f = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        f.dl.deinit(allocator);
        if (fx.term.rt.editor_row_cache.filled_upto >= lines.len) break;
    }
    const bar = fx.term.rt.editor_scrollbar orelse return error.NoScrollbar;

    // 막대 중간쯤을 잡아 끈다.
    try testing.expect(beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), @floatCast(bar.track_x), @floatCast(bar.thumb_y)));
    try testing.expect(scrollbarCaptureActive(fx.session));
    const mid_y: f64 = @as(f64, bar.track_y) + @as(f64, bar.track_h) / 2;
    _ = routeScrollbarCapture(fx.session, 2, @floatCast(bar.track_x), mid_y);
    scroll_ops.applyPendingScrollbarScroll(fx.session);

    // 실제로 움직였고, 상한을 넘지 않았다.
    try testing.expect(fx.term.rt.editor_first_line > 0);
    try testing.expect(fx.term.rt.editor_first_line <= fx.term.rt.editor_max_top_line);

    // **판정은 "끈 자리에 막대가 서는가"다** — 그것이 드래그가 옳다는 뜻이다(손가락과 막대가 어긋나지
    // 않는다). 다시 그려 새 thumb 위치를 본다.
    //
    // 비율 근사로 계산하면 앞쪽이 짧고 뒤쪽이 긴 이 문서에서 **다른 시각 행에 서므로** thumb이 손가락을
    // 벗어난다(그 뮤턴트가 여기서 죽는다). thumb 위를 잡았으므로 `grab_dy`가 0이라, 끈 y가 곧 새 thumb의
    // 위쪽이어야 한다.
    var after = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    after.dl.deinit(allocator);
    const bar2 = fx.term.rt.editor_scrollbar orelse return error.NoScrollbar;
    const drift = @abs(@as(f64, bar2.thumb_y) - mid_y);
    // 한 줄이 한 시각 행이므로 셀 높이 두 칸이면 "같은 자리"다(반올림·clamp 여유).
    try testing.expect(drift <= @as(f64, @floatFromInt(fx.session.cell_height_px * 2)));

    // up이 캡처를 끝낸다.
    _ = routeScrollbarCapture(fx.session, 3, @floatCast(bar.track_x), mid_y);
    try testing.expect(!scrollbarCaptureActive(fx.session));
}

test "막대 밖을 누르면 드래그가 서지 않는다 — 태그만 남으면 안 된다" {
    // `Drag.begin`의 `null`은 두 가지다: thumb을 잡아 점프하지 않은 것(성공)과 track 밖이라 시작하지
    // 못한 것(실패). 반환값으로 못 가르므로 `active`를 봐야 하는데, 안 보면 **드래그는 비활성인데
    // 태그만 세워져** move가 흡수되지 않는 채 up까지 그 태그가 남는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 400);
    defer allocator.free(lines);
    for (lines) |*l| l.* = "line";
    fx.term.rt.editor_lines = lines;

    var f = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    f.dl.deinit(allocator);
    const bar = fx.term.rt.editor_scrollbar orelse return error.NoScrollbar;

    // 막대의 **왼쪽 바깥**(본문 한가운데)을 누른다 — 거터 안이 아니다.
    const outside_x: f64 = @as(f64, bar.hit_x) - 40;
    try testing.expect(!beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), outside_x, @floatCast(bar.thumb_y)));
    try testing.expect(!scrollbarCaptureActive(fx.session)); // 태그가 안 남았다
    try testing.expect(fx.session.editor_scrollbar_term == null); // 잡은 Term도 안 남았다
}

test "가로 막대를 끌면 열이 움직인다 — 세로와 축이 다르다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // 랩을 끄고 아주 긴 줄을 준다 — 그래야 가로 막대가 선다(랩이면 축 자체가 없다).
    const wide = "const value = compute(index); // " ++ ("가로로 아주 긴 줄이다 " ** 20);
    const lines = try allocator.alloc([]const u8, 40);
    defer allocator.free(lines);
    for (lines) |*l| l.* = wide;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0;
    ensureMaxCols(fx.term, false); // 여는 경로가 부르는 그대로 — 줄을 직접 꽂았으니 여기서 센다

    var f = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    f.dl.deinit(allocator);
    const bar = fx.term.rt.editor_horizontal_scrollbar orelse return error.NoHorizontalScrollbar;

    try testing.expect(beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), @floatCast(bar.thumb_x), @floatCast(bar.track_y)));
    try testing.expectEqual(@as(@TypeOf(fx.session.scrollbar_drag_target), .editor_horizontal), fx.session.scrollbar_drag_target);

    const mid_x: f64 = @as(f64, bar.track_x) + @as(f64, bar.track_w) / 2;
    _ = routeScrollbarCapture(fx.session, 2, mid_x, @floatCast(bar.track_y));
    scroll_ops.applyPendingEditorHScroll(fx.session);
    try testing.expect(fx.term.rt.editor_first_col > 0);

    _ = routeScrollbarCapture(fx.session, 3, mid_x, @floatCast(bar.track_y));
    try testing.expect(!scrollbarCaptureActive(fx.session));
}

test "[측정] 폭을 라이브로 끄는 드래그 — 캐시가 매 프레임 무효다 (§2.1 남은 구간)" {
    // **어느 드래그인지가 중요하다.** §2.1은 이 작업을 분리 대상으로 적으며 근거를 *"창 리사이즈 중에는
    // 매 프레임 발생한다"*고 썼는데, **이 구현에서 창 경로는 이미 닫혀 있다** — `MaruAppHost`의
    // `windowDidResize`가 `inLiveResize`면 세션 resize를 보류하고 `windowDidEndLiveResize`에서 한 번만
    // 처리한다(zsh가 SIGWINCH마다 redraw하며 프롬프트를 중복시키던 문제로 도입된 정책). 그래서 창을
    // 끄는 동안 편집기 폭은 안 바뀌고 계수도 안 돈다.
    //
    // **라이브로 폭을 바꾸는 경로는 둘이다**: 사이드바 폭 드래그(`setSidebarWidthPx` — drag마다 갱신)와
    // pane divider 드래그(`routeDividerCapture` — 같은 패턴). 이 테스트가 재는 것이 그 둘이다.
    //
    // 폭이 바뀌면 모든 줄의 조각 수가 바뀌므로 캐시가 매번 무효가 되고, 캐시가 계수 상한(`[4096]u32`)을
    // 없앴으므로 그 비용은 이제 문서 크기에 **그대로 비례한다**(예전에는 4,096줄에서 잘려 캡됐다 — 대신
    // 값이 틀렸다). 창 리사이즈에서는 같은 비용이 **놓는 순간 1회** 든다.
    //
    // 폭은 **셀 하나만큼** 줄인다 — 1px씩 줄이면 열 수가 그대로라 캐시가 맞아 버려서 드래그를 재는 것이
    // 아니게 된다(이 테스트가 스스로를 무력화하는 자리다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const frames = 20;
    for ([_]usize{ 1_000, 5_000, 20_000 }) |n| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        const lines = try allocator.alloc([]const u8, n);
        defer allocator.free(lines);
        for (lines) |*l| l.* = "const x = 1; // " ++ ("긴 줄이라 랩이 일어난다 " ** 6);
        fx.term.rt.editor_lines = lines;
        fx.term.rt.editor_wrap = true;
        fx.term.rt.editor_max_cols = 0;

        var warm = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        warm.dl.deinit(allocator);

        const cell_w: u32 = @intCast(fx.session.cell_width_px);
        // 저하를 켠 쪽과 안 켠 쪽을 **같은 조건에서** 잰다 — 제스처 유무가 유일한 차이다.
        // 켠 쪽은 dock 경계 제스처로 세운다: 사이드바로만 재면 dock 경로가 빠져도 이 측정이 그대로
        // 좋아 보인다(첫 구현이 실제로 그 상태였고 적대적 검증이 잡았다).
        for ([_]bool{ false, true }) |degrade| {
            fx.session.pointer_gesture_owner = if (degrade) .{ .dock_outer_divider = .{ .offset_px = 0 } } else .none;
            defer fx.session.pointer_gesture_owner = .none;

            const t0 = monotonicMsForTest();
            for (0..frames) |i| {
                var rect = fx.leaf_rect;
                rect.w -= @intCast(cell_w * (i + 1)); // 드래그: 매 프레임 한 셀씩 좁아진다
                var drawn = appendPaneFrame(fx.session, rect, fx.term) orelse return error.EditorPaneDidNotDraw;
                drawn.dl.deinit(allocator);
            }
            const total = monotonicMsForTest() - t0;
            std.debug.print("\n[측정] 드래그 중 랩 {d}줄 (저하 {s}): {d}프레임 {d}ms (프레임당 {d}µs)\n", .{
                n,
                if (degrade) "켬" else "끔",
                frames,
                total,
                total * 1000 / frames,
            });
        }
    }
}

test "[측정] 랩 켠 문서의 프레임 비용 — 계수 캐시가 그것을 문서 크기에서 떼어 놓는다" {
    // §2.1이 *"문서 크기에 비례하는 작업은 메인에서 하지 않는다"*고 못박았고, 그 표의 한 줄이
    // **전 문서 랩 재계산**이다. 캐시(`frame.RowCache`)가 들어오기 전 이 자리의 실측은 이랬다
    // (ReleaseFast, 20프레임 평균, 2026-08-18):
    //
    // | 문서 | 프레임당 | 시각 행(센 값) |
    // |---|---|---|
    // | 1,000줄 | 3.3ms | 2,000 (정확) |
    // | 4,000줄 | 12.9ms | 8,000 (정확) |
    // | 20,000줄 | 12.7ms | **24,096** (실제 40,000) |
    //
    // 두 가지가 함께 드러났다. ⑴ 계수가 **매 프레임** 돌았다 — 계약이 적은 "리사이즈 중"만이 아니다.
    // ⑵ 20,000줄이 4,000줄보다 빨랐다 — 계수 루프의 상한이 호출자가 준 `row_counts` 배열 길이인데
    // 제품이 그것을 스택 `[4096]u32`로 줬기 때문이다. 넘는 줄은 "논리 줄 하나"로 근사되므로 **비용이
    // 캡되는 대신 시각 행 수가 틀렸다**(막대가 실제보다 1.66배 길었다). 성능과 정확성이 한 상한에
    // 묶여 있었고, 캐시가 둘을 함께 풀었다.
    //
    // 그래서 계속 세 크기를 잰다: 캐시가 도로 빠지거나 무효화가 매 프레임 걸리면 위 표로 돌아가는데,
    // **그 회귀는 조용하다**(그림은 같고 프레임만 느려진다). 시계가 ms 해상도라 여러 프레임을 합친다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const frames = 20;
    for ([_]usize{ 1_000, 4_000, 20_000 }) |n| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        const lines = try allocator.alloc([]const u8, n);
        defer allocator.free(lines);
        // 랩이 실제로 일어나게 본문보다 긴 줄을 준다(짧으면 조각이 하나라 셈이 싸다).
        for (lines) |*l| l.* = "const x = 1; // " ++ ("긴 줄이라 랩이 일어난다 " ** 6);
        fx.term.rt.editor_lines = lines;
        fx.term.rt.editor_wrap = true;
        fx.term.rt.editor_max_cols = 0;

        // 첫 프레임은 폰트·픽스처 워밍이 섞이므로 재는 구간에서 뺀다.
        var warm = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        warm.dl.deinit(allocator);

        const t0 = monotonicMsForTest();
        for (0..frames) |_| {
            var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
            drawn.dl.deinit(allocator);
        }
        const total = monotonicMsForTest() - t0;
        // 상한에 걸렸으면 초과분이 "줄당 1행"으로 들어간다 — 그 사실을 값으로 남긴다.
        const rows = fx.term.rt.editor_total_visual_rows;
        std.debug.print("\n[측정] 랩 {d}줄: {d}프레임 {d}ms (프레임당 {d}µs, 시각 행 {d} = 논리 {d} + {d})\n", .{
            n,
            frames,
            total,
            total * 1000 / frames,
            rows,
            n,
            rows -| @as(u32, @intCast(n)),
        });
    }
}

test "[측정] 여는 경로의 내역 — 단계마다 직접 잰다" {
    // `ensureMaxCols`(가로 막대 근거)를 세로처럼 점진으로 나눌지 판단하려면 그 값이 **여는 경로에서
    // 차지하는 몫**을 알아야 한다.
    //
    // **재실행으로 근사하지 않는다.** 처음엔 전체를 한 번 재고 `ensureMaxCols`만 다시 돌려 뺐는데,
    // 두 번째 호출은 줄 배열과 그 바이트가 이미 CPU 캐시에 올라와 있어 **첫 실행보다 빠르다**. 몫을
    // 알고 싶으면 같은 실행 안에서 단계마다 재야 한다 — 여기서는 `openPathInActivePane`이 하는 일을
    // 같은 순서로 직접 밟는다.
    //
    // **한계: OS 페이지 캐시는 따뜻하다.** 방금 쓴 파일을 바로 읽으므로 읽기 값은 "캐시 히트"에
    // 가깝다. 콜드 읽기(디스크에서 처음 가져오기)는 이 하니스로 잴 수 없다 — 캐시를 비우려면 권한이
    // 필요하다. 그래서 아래 읽기 값은 **하한**이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const line = "const value = compute(index); // 이 줄은 창보다 길어서 랩이 켜지면 여러 조각으로 접힌다\n";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..20_000) |_| try text.appendSlice(allocator, line);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "big.zig", .data = text.items });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "big.zig" });
    defer allocator.free(path);

    // ① 파일 읽기 + 줄 파싱(`openPath`) — 여는 경로의 첫 단계 그대로.
    const t0 = monotonicMsForTest();
    var opened = try openPath(fx.session.io, allocator, path);
    const t1 = monotonicMsForTest();
    defer opened.deinit(allocator);

    // ② 줄 슬라이스 배열 만들기 — 같은 경로가 하는 그대로.
    const n = opened.file.lineCount();
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    const t2 = monotonicMsForTest();
    for (0..n) |i| lines[i] = opened.file.lineText(i) orelse "";
    const t3 = monotonicMsForTest();

    // ③ 가장 긴 줄 세기 — **이 문서에서 처음 도는 실행**이다(재실행 근사가 아니다).
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_max_cols = 0;
    const t4 = monotonicMsForTest();
    ensureMaxCols(fx.term, false);
    const t5 = monotonicMsForTest();

    std.debug.print("\n[측정] 2만 줄({d}KB) 여는 경로: 읽기+파싱 {d}ms · 줄 배열 {d}ms · 가장 긴 줄 세기 {d}ms (max_cols={d})\n", .{
        text.items.len / 1024,
        t1 - t0,
        t3 - t2,
        t5 - t4,
        fx.term.rt.editor_max_cols,
    });
}

test "[측정] 큰 파일을 여는 값 — 가장 긴 줄 세기가 열기에 붙었다" {
    // 접힘 몫과 같은 자리다(§4.1f 표) — 여는 경로에 붙은 값은 접기를 안 쓰는 사용자도 문다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;

    const n = 120_000;
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    for (lines) |*l| l.* = "const x = 1; // 평범한 길이의 줄이다";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_max_cols = 0;

    const t0 = monotonicMsForTest();
    ensureMaxCols(fx.term, false);
    const t1 = monotonicMsForTest();
    std.debug.print("\n[측정] {d}줄 열기의 가장 긴 줄 세기: {d}ms (max_cols={d})\n", .{ n, t1 - t0, fx.term.rt.editor_max_cols });
    // **재앙 감지선이지 예산이 아니다** — 그래서 자릿수로 둔다. 옛 상한 500ms 는 CI 러너 실측(main 463ms)과
    // 여유가 7% 뿐이라, 코드와 무관한 PR 들이 러너 편차만으로 연달아 빨강이 됐다(511·560·604ms — 2026-08-18).
    // 그 상태의 게이트는 회귀를 알리는 대신 무작위로 울리는 알람이라, 사람이 결과를 안 보게 만든다.
    // 고치기 전 이 경로는 **초 단위**였고 이 선이 잡으려는 것도 그 자릿수다.
    //
    // 같은 파일의 다른 측정선(4프레임·접기)은 **건드리지 않는다** — 같은 러너 실측이 14~37ms 라 500ms
    // 상한과의 여유가 90% 넘는다. 문제는 "500 이라는 값"이 아니라 **여유가 없어진 이 한 자리**다.
    //
    // **제품이 느린 것이 아니다** — 배포가 쓰는 ReleaseFast 에서 같은 일이 42ms 다(실측). 이 테스트가
    // 도는 Debug 가 9배 느릴 뿐이라, 선은 "Debug 를 CI 러너에서 돌렸을 때" 를 기준으로 잡는다.
    try testing.expect(t1 - t0 < 2000);
}

test "[측정] 큰 문서 전체 접기 — 보이는 줄 다시 만들기" {
    // `rebuildVisible`은 줄마다 `isHidden(spans, i)`를 부른다. 구간이 많아지면 줄×구간이라
    // **방금 `hiddenSpans`에서 고친 것과 같은 부류**다. 재고 확인한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    for ([_]usize{ 1000, 2000, 4000 }) |blocks| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        const n = blocks * 2;
        const lines = try allocator.alloc([]const u8, n);
        defer allocator.free(lines);
        for (0..blocks) |b| {
            lines[b * 2] = "head:";
            lines[b * 2 + 1] = "  body";
        }
        fx.term.rt.editor_lines = lines;

        const t0 = monotonicMsForTest();
        try testing.expect(foldAll(fx.session));
        const t1 = monotonicMsForTest();
        std.debug.print("\n[측정] {d}블록 전체 접기(보이는 줄 만들기 포함): {d}ms\n", .{ blocks, t1 - t0 });
    }
}

test "[측정] 큰 파일을 여는 값 — 범위 세기와 표식 만들기가 열기에 붙었다" {
    // §4.1f가 갱신 시점을 *"문서를 열 때"*로 정하면서 `ensureFoldRanges`·`rebuildVisible`이 **모든
    // 파일 열기 경로**에 들어갔다(`openPathInActivePane`). 접기 명령은 사용자가 기다릴 각오를 하고
    // 누르지만 **여는 것은 아니다** — 그래서 여기에 값을 매겨 둔다.
    //
    // 접힘이 하나도 없는 상태에서도 표식은 줄마다 만들어지므로(`markFor` — 문서 줄 수만큼 이진 탐색
    // 두 번), 접을 것이 많은 문서와 **평평한 문서 둘 다** 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    for ([_]bool{ true, false }) |nested| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;

        const n = 120_000;
        const lines = try allocator.alloc([]const u8, n);
        defer allocator.free(lines);
        for (0..n) |i| lines[i] = if (nested and i % 2 == 1) "  body" else if (nested) "head:" else "x";
        fx.term.rt.editor_lines = lines;

        const t0 = monotonicMsForTest();
        try ensureFoldRanges(fx.session, fx.term); // 여는 경로가 부르는 그대로
        try rebuildVisible(fx.session, fx.term);
        const t1 = monotonicMsForTest();
        std.debug.print("\n[측정] {d}줄 열기의 접힘 몫({s}): {d}ms\n", .{ n, if (nested) "블록 6만" else "평평", t1 - t0 });

        // **여는 것만으로 무는 메모리도 함께 적는다.** 접기를 한 번도 안 누른 사용자까지 이 값을
        // 물기 때문이다 — 큰 파일을 여러 개 띄우면 누적된다. 접은 뒤의 값은 `editor_visible_*`가
        // 더해져 더 커지므로 접고 나서 잰다.
        _ = foldAll(fx.session);
        const rt = &fx.term.rt;
        const held = rt.editor_fold_ranges.len * @sizeOf(editor_fold.Range) +
            rt.editor_folded_buf.len * @sizeOf(u32) +
            rt.editor_fold_marks.len * @sizeOf(chrome_editor.gutter.Fold) +
            rt.editor_visible_lines.len * @sizeOf([]const u8) +
            rt.editor_visible_numbers.len * @sizeOf(?u32);
        std.debug.print("[측정] 같은 문서의 접힘 자료구조({s}): {d}KiB\n", .{ if (nested) "접은 뒤" else "평평", held / 1024 });

        // **재앙 감지선이지 예산이 아니다.** 여는 순간이 눈에 띄게 멈추면 여기서 걸린다.
        try testing.expect(t1 - t0 < 500);
    }
}

test "접은 뒤 끝까지 굴려도 마지막 화면이 안 빈다 — 스크롤과 렌더가 같은 배열을 본다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // 접으면 300줄이 머리 100줄로 줄어든다.
    const lines = try allocator.alloc([]const u8, 300);
    defer allocator.free(lines);
    for (0..100) |b| {
        lines[b * 3] = "head:";
        lines[b * 3 + 1] = "  x";
        lines[b * 3 + 2] = "  y";
    }
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;

    try testing.expect(foldAll(fx.session));
    try testing.expectEqual(@as(usize, 100), fx.term.rt.editor_visible_lines.len);

    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1_000_000);
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const inner_h = body.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = inner_h / fx.session.cell_height_px;
    var drawn_rows: usize = 0;
    for (drawn.dl.cells) |c| drawn_rows = @max(drawn_rows, @as(usize, c.row) + 1);
    // 고치기 전: 상한을 **전체 문서**(300줄)로 세어 `first_line`이 266까지 갔고 보이는 줄은 100개라
    // **화면이 통째로 비었다**(그린 행 0).
    try testing.expect(fx.term.rt.editor_first_line < fx.term.rt.editor_visible_lines.len);

    // **마지막 화면이 비면 안 된다** — 스크롤 상한이 접힘을 모르면 여기서 빈다.
    try testing.expectEqual(visible, drawn_rows);
}

test "가장 긴 줄이 접혀 숨으면 가로 상한도 다시 센다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // **들여쓴** 긴 줄이어야 접을 범위가 생긴다(처음엔 들여쓰기를 빼서 `foldAll`이 false였다).
    const long = try allocator.alloc(u8, 2000);
    defer allocator.free(long);
    @memset(long, 'x');
    long[0] = ' ';
    long[1] = ' ';
    const lines = try allocator.alloc([]const u8, 3);
    defer allocator.free(lines);
    lines[0] = "head:";
    lines[1] = long; // 아주 긴 줄 — 접히면 숨는다
    lines[2] = "tail";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_max_cols = 0; // 새 내용이다 — 여는 경로가 세어 둔 값을 버린다(위 테스트와 같은 이유)

    // 접기 전에 가로 상한을 세운다.
    try testing.expect(scrollCols(fx.session, fx.term, fx.leaf_rect, -1_000_000, null));
    const before = fx.term.rt.editor_max_cols;
    try testing.expect(before > 1000);

    // 접으면 그 긴 줄이 숨는다 — 남는 줄은 "head:"와 "tail"뿐이다.
    try testing.expect(foldAll(fx.session));
    _ = scrollCols(fx.session, fx.term, fx.leaf_rect, -1_000_000, null);
    // 고치기 전: `max_cols`가 2000 그대로라 `first_col`이 **1911**까지 갔다 — 화면엔 두 줄뿐인데
    // 1911열로 밀려 빈 화면이었다.
    try testing.expect(fx.term.rt.editor_max_cols < before);

    // **긴 줄이 숨었으니 가로로 밀 것이 없다.**
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);
}

test "접혀도 gutter 폭은 문서 줄 수로 잡는다 — 번호는 원래 값이다" {
    // 접히면 `lines`는 보이는 줄만이지만 gutter는 **원래 번호**를 그린다. 폭을 보이는 수로 잡으면
    // 그리는 번호와 갈린다. `min_line_number_cells`(= 5)가 10만 줄까지 가리므로 **작은 문서로 쓴
    // 테스트는 공허하다** — 이 세션에서 같은 함정을 이미 밟았다(§4.1e). 가림막을 넘겨 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    // 문서 120,000줄(6자리) → 접으면 40,000줄(5자리)만 보인다. 자릿수가 갈린다.
    const n = 120_000;
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    for (0..n / 3) |b| {
        lines[b * 3] = "h:";
        lines[b * 3 + 1] = "  a";
        lines[b * 3 + 2] = "  b";
    }
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;

    try testing.expect(foldAll(fx.session));
    const visible = fx.term.rt.editor_visible_lines.len;
    try testing.expectEqual(@as(usize, n / 3), visible);
    // 가림막 밖에서 자릿수가 실제로 갈린다 — 아니면 판정이 공허하다.
    try testing.expect(chrome_editor.geometry.digitCount(n) > chrome_editor.geometry.digitCount(visible));
    try testing.expect(chrome_editor.geometry.digitCount(visible) >= chrome_editor.geometry.min_line_number_cells);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 본문이 gutter 뒤에서 시작한다 — 폭이 **문서 줄 수**(6자리)로 잡혔는지 그 자리로 확인한다.
    const m = chrome_editor.diff_frame.sideMetrics(
        editorBodyRect(fx.session, fx.leaf_rect, fx.term).w -| chrome_editor.frame.content_inset_px * 2,
        editorBodyRect(fx.session, fx.leaf_rect, fx.term).h -| chrome_editor.frame.content_inset_px * 2,
        @intCast(fx.session.cell_width_px),
        @intCast(fx.session.cell_height_px),
    );
    const want = chrome_editor.geometry.compute(m.total_cols, n, .{}).content.width; // 문서 줄 수 기준
    try testing.expectEqual(want, visibleCols(fx.session, editorBodyRect(fx.session, fx.leaf_rect, fx.term), fx.term, false));

    // **렌더가 실제로 받는 값도 봐야 한다.** 위 단언은 제품 쪽 함수만 본다 — 렌더에 보이는 줄 수를
    // 넘기는 뮤턴트가 그것만으로는 **살아남았다**. 본문이 시작하는 열로 화면에서 판정한다.
    const want_left = chrome_editor.geometry.compute(m.total_cols, n, .{}).contentLeft();
    var content_left: u16 = std.math.maxInt(u16);
    for (drawn.dl.cells) |c| {
        if (c.codepoint == 'h' or c.codepoint == ':') content_left = @min(content_left, c.col);
    }
    try testing.expect(content_left != std.math.maxInt(u16)); // 머리 줄이 실제로 그려졌다
    try testing.expectEqual(want_left, content_left);
}

test "접고 튕겨도 first_line은 보이는 배열 안에 있다" {
    // `first_line`은 렌더가 함께 받는 **보이는 배열의 첨자**다. 상한을 문서 줄 수로 잡으면 접혔을 때
    // 배열 밖으로 나간다. 그리기 직전 clamp가 화면은 가려 주므로 **화면으로는 안 드러난다** — 값
    // 자체를 본다. 고치기 전: 40,000줄만 보이는데 `first_line`이 50,000이었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const n = 120_000;
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    for (0..n / 3) |b| {
        lines[b * 3] = "h:";
        lines[b * 3 + 1] = "  a";
        lines[b * 3 + 2] = "  b";
    }
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    try testing.expect(foldAll(fx.session));
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    d0.dl.deinit(allocator);

    // 한 프레임 안에 휠이 여러 번 온다(빠른 튕김) — 렌더는 사이에 안 돈다.
    for (0..50) |_| _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -1000);
    const visible = fx.term.rt.editor_visible_lines.len;
    try testing.expectEqual(@as(usize, n / 3), visible); // 접힘이 실제로 갈렸다 — 아니면 공허하다
    try testing.expect(fx.term.rt.editor_first_line < visible);
}

/// 화면 맨 윗 행의 gutter 번호를 draw list에서 읽는다. **번호는 화면에 보이는 것이 진실이다** —
/// 내부 첨자로 판정하면 접힘이 바뀐 뒤의 뜻 차이를 못 잡는다.
fn topGutterNumber(dl: anytype) u32 {
    var min_row: u16 = std.math.maxInt(u16);
    for (dl.cells) |c| {
        if (c.codepoint >= '0' and c.codepoint <= '9') min_row = @min(min_row, c.row);
    }
    const Digit = struct { col: u16, ch: u8 };
    var digits: [16]Digit = undefined;
    var n: usize = 0;
    for (dl.cells) |c| {
        if (c.row != min_row) continue;
        if (c.codepoint < '0' or c.codepoint > '9') continue;
        if (n < digits.len) {
            digits[n] = .{ .col = c.col, .ch = @intCast(c.codepoint) };
            n += 1;
        }
    }
    std.mem.sort(Digit, digits[0..n], {}, struct {
        fn lt(_: void, a: Digit, b: Digit) bool {
            return a.col < b.col;
        }
    }.lt);
    var v: u32 = 0;
    for (digits[0..n]) |d| v = v * 10 + (d.ch - '0');
    return v;
}

test "접기·펼치기가 보던 자리를 지킨다" {
    // 고치기 전: 3만 줄 문서의 **9,001번 줄**을 보다가 전체 접기를 하니 **1번 줄**로 튀었고, 펼쳐도
    // 1번 그대로였다(실측). 두 조작 다 `first_line = 0`을 박고 있었다. Vim `zM`·VSCode "Fold All"은
    // 보던 자리를 지킨다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const n = 30_000;
    const lines = try allocator.alloc([]const u8, n);
    defer allocator.free(lines);
    for (0..n / 3) |b| {
        lines[b * 3] = "h:";
        lines[b * 3 + 1] = "  a";
        lines[b * 3 + 2] = "  b";
    }
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    d0.dl.deinit(allocator);
    // **몸통 줄에 세운다.** 머리 줄에 세우면 접혀도 그 줄이 그대로 남아 "자리를 지켰다"가 공허하다.
    // 9,001번째 줄(0-based 9001)은 `"  a"` — 접히면 숨는다.
    _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -9001);
    var d1 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const before = topGutterNumber(d1.dl);
    d1.dl.deinit(allocator);
    try testing.expectEqual(@as(u32, 9002), before); // 몸통 줄 위에 섰다 — 아니면 판정이 공허하다

    try testing.expect(foldAll(fx.session));
    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const folded_top = topGutterNumber(d2.dl);
    d2.dl.deinit(allocator);
    // 그 줄은 몸통("  a")이라 숨는다 — 품은 머리("h:", 바로 앞 줄)가 맨 위에 선다.
    try testing.expectEqual(before - 1, folded_top);
    // 접힘이 실제로 갈렸다(머리만 남는다) — 아니면 위 단언이 공허하다.
    try testing.expectEqual(@as(usize, n / 3), fx.term.rt.editor_visible_lines.len);

    try testing.expect(unfoldAll(fx.session));
    var d3 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const back = topGutterNumber(d3.dl);
    d3.dl.deinit(allocator);
    try testing.expectEqual(before - 1, back); // 접었을 때 선 자리를 그대로 들고 나온다

    // **머리 줄 위에서 접는 경우도 봐야 한다.** 그 줄은 안 숨으므로 **그 자리 그대로**여야 하는데,
    // 위 단언들은 몸통에서만 서서 이 구분을 못 잡는다 — 탐색을 "want 미만"으로 바꾸는 뮤턴트가
    // 그것만으로는 **살아남았다**(한 줄 위로 밀린다). 지금 맨 위(9,001)가 바로 머리 줄이다.
    try testing.expect(foldAll(fx.session));
    var d4 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const on_head = topGutterNumber(d4.dl);
    d4.dl.deinit(allocator);
    try testing.expectEqual(back, on_head);
}

test "접힌 채로 다시 접다 실패해도 숨은 줄을 되찾을 수 있다" {
    // 고치기 전: 실패하면 상태만 "안 접힘"이 되고 화면은 접힌 그대로였다 — 문서 4줄인데 화면 2줄,
    // 그리고 `unfoldAll`이 `folded_len == 0`을 보고 거절해 **되돌릴 길이 없었다**(실측).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;
    var stuck_checked: usize = 0;

    var step: usize = 0;
    while (step < 6) : (step += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        const alloc = fa.allocator();
        var fx = try PaneFixture.init(alloc);
        defer fx.deinit(alloc);

        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;
        const lines = try backing.alloc([]const u8, 4);
        defer backing.free(lines);
        lines[0] = "a:";
        lines[1] = "  1";
        lines[2] = "b:";
        lines[3] = "  2";
        fx.term.rt.editor_lines = lines;

        if (!foldAll(fx.session)) continue; // 먼저 성공적으로 접어 둔다
        try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_visible_lines.len);

        fa.fail_index = fa.allocations + step; // 그 뒤의 할당부터 실패한다
        if (foldAll(fx.session)) continue; // 이번 step은 실패를 못 겪었다
        stuck_checked += 1;

        // 화면은 접힌 그대로다. 그렇다면 **되돌릴 수 있어야 한다.**
        try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_visible_lines.len);
        try testing.expect(unfoldAll(fx.session));
        try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_visible_lines.len); // 원본을 그대로 그린다
    }
    try testing.expect(stuck_checked >= 1); // 실패를 한 번도 못 겪었으면 아무것도 지키지 않았다
}

test "탭이 든 긴 줄이 랩에서 끝까지 그려지고 닿는다" {
    // 세는 저장소가 8 KiB였을 때 이 줄은 **103행**으로 세어졌다(실제 250행) — 랩에서 59%가 그려지지도
    // 닿지도 않았다. 상수만 키우고 **제품 두 자리 중 하나라도 안 쓰면** 다시 갈리므로 여기서 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const long = try allocator.alloc(u8, 10_000);
    defer allocator.free(long);
    var i: usize = 0;
    while (i < long.len) : (i += 2) {
        long[i] = 'a';
        long[i + 1] = '\t';
    }
    const lines = try allocator.alloc([]const u8, 1);
    defer allocator.free(lines);
    lines[0] = long;
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    d0.dl.deinit(allocator);

    // 렌더가 실어 둔 시각 행 수 — 넉넉한 저장소로 잰 값과 같아야 한다.
    const body = editorBodyRect(fx.session, fx.leaf_rect, fx.term);
    const cols = visibleCols(fx.session, body, fx.term, false);
    const big = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(big);
    const want = chrome_editor.content.rowCount(long, chrome_editor.frame.default_tab_width, cols, true, big);
    try testing.expect(!want.truncated); // 기준이 절단됐으면 판정이 공허하다
    try testing.expect(want.rows > 100); // 8 KiB 시절 값(103행)보다 확실히 크다
    try testing.expectEqual(@as(usize, want.rows), fx.term.rt.editor_total_visual_rows);

    // 스크롤도 같은 값을 봐야 한다 — 끝 조각까지 닿는다.
    for (0..40) |_| {
        _ = scrollLines(fx.session, fx.term, fx.leaf_rect, -20);
        var dx = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        dx.dl.deinit(allocator);
    }
    try testing.expectEqual(fx.term.rt.editor_max_top_piece, fx.term.rt.editor_first_piece);
    try testing.expect(fx.term.rt.editor_first_piece > 100); // 8 KiB 시절엔 여기까지 못 갔다
}

test "접기 명령이 액션에서 끝까지 이어진다" {
    // 배선이 없으면 기능이 있어도 **사용자가 못 쓴다**(접기는 포인터 경로가 없어 명령이 유일한 길이다).
    // 카탈로그·파싱은 round-trip 테스트가 덮지만 **디스패치 팔은 안 덮는다** — 둘을 뒤바꿔도 컴파일된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 4);
    defer allocator.free(lines);
    lines[0] = "a:";
    lines[1] = "  1";
    lines[2] = "b:";
    lines[3] = "  2";
    fx.term.rt.editor_lines = lines;

    fx.session.dispatchAppAction(.fold_all);
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_visible_lines.len); // 몸통 둘이 숨었다

    fx.session.dispatchAppAction(.unfold_all);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_visible_lines.len); // 원본을 그대로 그린다
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_folded_len);
}

test "레벨 접기는 그 겹의 블록만 접고, 명령이 끝까지 이어진다" {
    // §4.1f가 N1 범위에 넣은 **레벨 접기**. 전체 접기와 달리 "어느 겹을 접는가"를 고르므로,
    // 레벨 1은 최상위만(안쪽은 그 아래 숨는다), 레벨 2는 **함수 본문은 보이고 그 안 블록만** 접힌다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    lines[0] = "class A:";
    lines[1] = "    def m():";
    lines[2] = "        x = 1";
    lines[3] = "        y = 2";
    lines[4] = "    def n():";
    lines[5] = "        z = 3";
    fx.term.rt.editor_lines = lines;

    // 레벨 1 — 맨 바깥(class)만 접는다. 화면에 그 머리 한 줄만 남는다.
    fx.session.dispatchAppAction(.fold_level_1);
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_visible_lines.len);
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_folded_len);

    // 레벨 2 — **갈아 끼운다**(위 doc: 합치지 않는다). class는 펼쳐지고 두 메서드가 접힌다.
    fx.session.dispatchAppAction(.fold_level_2);
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_folded_len);
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_visible_lines.len); // class + def m + def n
    try testing.expectEqualStrings("class A:", fx.term.rt.editor_visible_lines[0]);
    try testing.expectEqualStrings("    def n():", fx.term.rt.editor_visible_lines[2]);

    // 레벨 3 — 그 겹에 블록이 없다. **아무 일도 안 한다**(빈 집합을 넣어 펼쳐지면 안 된다).
    try testing.expect(!foldLevel(fx.session, 3));
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_folded_len); // 레벨 2가 그대로다
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_visible_lines.len);

    try testing.expect(unfoldAll(fx.session));
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_visible_lines.len);
}

test "레벨 접기가 실패해도 옛 집합으로 되돌린다 — 길이만으로는 못 되돌린다" {
    // 전체 접기뿐이던 시절에는 집합이 "전부 아니면 없음"이라 길이가 곧 내용이었다. 레벨 접기가
    // 들어오면 **같은 길이라도 다른 머리들**이라, 되돌리기가 길이만 보면 화면과 상태가 갈린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;
    var restored: usize = 0;

    var step: usize = 0;
    while (step < 12) : (step += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        const alloc = fa.allocator();
        var fx = try PaneFixture.init(alloc);
        defer fx.deinit(alloc);

        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;
        const lines = try backing.alloc([]const u8, 6);
        defer backing.free(lines);
        lines[0] = "a:";
        lines[1] = "  1";
        lines[2] = "  b:";
        lines[3] = "    2";
        lines[4] = "c:";
        lines[5] = "  3";
        fx.term.rt.editor_lines = lines;

        // 레벨 2를 먼저 세운다(머리 하나: `b:`). 여기서 실패하면 이 회차는 볼 것이 없다.
        if (!foldLevel(fx.session, 2)) continue;
        const before = fx.term.rt.editor_folded_buf[0];
        const before_visible = fx.term.rt.editor_visible_lines.len;

        // 그다음 레벨 1(머리 둘)이 할당에 실패하게 민다.
        fa.fail_index = fa.allocations + step;
        if (foldLevel(fx.session, 1)) continue; // 성공했으면 이 회차는 되돌리기를 안 본다

        // **집합이 옛 것 그대로여야 한다** — 길이도, 그 안의 머리도.
        try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_folded_len);
        try testing.expectEqual(before, fx.term.rt.editor_folded_buf[0]);
        try testing.expectEqual(before_visible, fx.term.rt.editor_visible_lines.len);
        // 그리고 **펼치기가 여전히 듣는다**(갇히지 않는다).
        try testing.expect(unfoldAll(fx.session));
        restored += 1;
    }
    // 공허해질 수 없게 센다 — 되돌리기를 한 번도 안 겪으면 아무것도 지키지 않는다.
    try testing.expect(restored >= 1);
}

test "gutter에 접힘 화살표가 선다 — 펼침 ▾, 접힘 ▸" {
    // **hover가 아니라 늘 그린다**(§4.1f) — N1에는 편집기 pane에 포인터 경로가 없어 VSCode식
    // hover 규칙을 흉내 내면 표식이 영영 안 보인다. Vim `foldcolumn` 선례를 따른다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 4);
    defer allocator.free(lines);
    lines[0] = "a:";
    lines[1] = "  1";
    lines[2] = "b:";
    lines[3] = "  2";
    fx.term.rt.editor_lines = lines;
    // 파일을 열면 범위가 서는 자리를 테스트에서는 직접 세운다(픽스처는 줄 배열을 갈아 끼운다).
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);

    // 컴포넌트가 소유한 글자에서 유도한다(위와 같은 이유 — 숫자를 두 곳에 적지 않는다).
    const open_mark: u21 = chrome_editor.gutter.Fold.open.codepoint().?;
    const collapsed_mark: u21 = chrome_editor.gutter.Fold.collapsed.codepoint().?;

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    var opens: usize = 0;
    var collapsed: usize = 0;
    for (d0.dl.cells) |c| {
        if (c.codepoint == open_mark) opens += 1;
        if (c.codepoint == collapsed_mark) collapsed += 1;
    }
    d0.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), opens); // 머리 두 줄에 펼침 화살표
    try testing.expectEqual(@as(usize, 0), collapsed);

    try testing.expect(foldAll(fx.session));
    var d1 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    opens = 0;
    collapsed = 0;
    var mark_col: u16 = std.math.maxInt(u16);
    var number_col: u16 = std.math.maxInt(u16);
    for (d1.dl.cells) |c| {
        if (c.codepoint == open_mark) opens += 1;
        if (c.codepoint == collapsed_mark) {
            collapsed += 1;
            mark_col = @min(mark_col, c.col);
        }
        if (c.codepoint >= '0' and c.codepoint <= '9') number_col = @min(number_col, c.col);
    }
    d1.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), collapsed); // 접힌 머리 두 줄
    try testing.expectEqual(@as(usize, 0), opens);
    // **번호 오른쪽·본문 왼쪽의 접힘 칸에 선다** — 자리가 틀리면 번호나 본문을 덮는다.
    const layout = chrome_editor.geometry.compute(
        chrome_editor.diff_frame.sideMetrics(
            editorBodyRect(fx.session, fx.leaf_rect, fx.term).w -| chrome_editor.frame.content_inset_px * 2,
            editorBodyRect(fx.session, fx.leaf_rect, fx.term).h -| chrome_editor.frame.content_inset_px * 2,
            @intCast(fx.session.cell_width_px),
            @intCast(fx.session.cell_height_px),
        ).total_cols,
        lines.len,
        .{},
    );
    // **span의 시작이 아니라 화살표가 서는 칸이다**(`Layout.foldMarkCol` — 접기 span은 두 셀이고
    // 왼쪽 칸은 줄 번호와의 여백이다). 그리는 쪽과 이 판정이 같은 함수를 읽어야 갈리지 않는다.
    try testing.expectEqual(layout.foldMarkCol(), mark_col);
    try testing.expect(number_col < mark_col);
    // 번호 마지막 자리와 **한 칸 이상** 뜬다 — 맞붙어 있던 것이 사용자 지적의 내용이었다(2026-08-22).
    try testing.expect(mark_col >= layout.line_numbers.end() + 1);
}

/// 접힘 클릭 판정자들이 쓰는 픽스처 — 머리 둘·몸통 둘짜리 문서를 세우고 화살표를 그려 둔다.
///
/// **줄 배열을 갈아 끼우는 방식이라 범위를 여기서 세운다.** 제품 경로(`finishAttach`)는 파일을 열 때
/// 그 둘을 부르고, 픽스처는 파일 대신 배열을 넣으므로 같은 두 걸음을 손으로 밟는다.
fn foldClickFixture(fx: *PaneFixture, lines: [][]const u8) !void {
    lines[0] = "a:";
    lines[1] = "  zzz"; // 접히면 사라질 글자
    lines[2] = "  zzz";
    lines[3] = "b:";
    lines[4] = "  qqq"; // **다른 블록** — 하나만 접히는지 보는 대조군이다
    lines[5] = "tail"; // 화살표가 없는 줄
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);
}

test "gutter 접기 화살표를 누르면 그 블록만 접히고, 다시 누르면 펴진다 (§4.1f 포인터 경로)" {
    // **§4.1f는 이것을 "안 한다"고 적었고 그 근거는 *"N1은 편집기 pane에 포인터 경로가 없다"*였다.**
    // §4.1g(본문 hit-test·선택, 2026-08-19~20)가 그 전제를 없앴고, 결정표가 *"화살표 클릭이 붙으면
    // 그쪽이 먼저 가져간다"*고 예약해 둔 자리를 이 경로가 채운다. 사용자 지적은 더 직접적이었다 —
    // *"닫기 아이콘 실제 동작도 안 된다"*(2026-08-22): 화살표는 보이는데 눌러도 아무 일이 없었다.
    //
    // **판정은 그린 자리에서 누른다.** 화살표가 실제로 그려진 셀의 가운데 픽셀을 쓰므로, 그리는 쪽
    // (`gutter.build` → `foldMarkCol`)과 받는 쪽(`editor_hit_geom.fold_*`)이 갈리면 여기서 죽는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    try foldClickFixture(&fx, lines);

    const open_mark: u21 = chrome_editor.gutter.Fold.open.codepoint().?;
    const collapsed_mark: u21 = chrome_editor.gutter.Fold.collapsed.codepoint().?;
    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    var mark_row: ?u16 = null;
    var mark_col: u16 = 0;
    var z_before: usize = 0;
    for (d0.dl.cells) |c| {
        if (c.codepoint == open_mark) {
            if (mark_row == null or c.row < mark_row.?) {
                mark_row = @intCast(c.row);
                mark_col = @intCast(c.col);
            }
        }
        if (c.codepoint == 'z') z_before += 1;
    }
    d0.dl.deinit(allocator);
    try testing.expect(z_before > 0); // 접기 전에는 보인다 — 아니면 아래 판정이 공허하다
    const row = mark_row orelse return error.NoFoldMarkDrawn;

    // 셀 **가운데**를 누른다. 모서리(+1px)를 쓰면 반올림이 한 칸 옆으로 새도 통과할 수 있다.
    const mark_x = ox + (@as(f64, @floatFromInt(mark_col)) + 0.5) * cw;
    const mark_y = oy + (@as(f64, @floatFromInt(row)) + 0.5) * ch;

    try testing.expect(toggleFoldAtPoint(fx.session, pane, mark_x, mark_y));
    try testing.expectEqual(@as(usize, 1), foldedHeads(fx.term).len); // **그 블록 하나만**

    var d1 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    var z_after: usize = 0;
    var q_after: usize = 0;
    var collapsed_after: usize = 0;
    for (d1.dl.cells) |c| {
        if (c.codepoint == 'z') z_after += 1;
        if (c.codepoint == 'q') q_after += 1;
        if (c.codepoint == collapsed_mark) collapsed_after += 1;
    }
    d1.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), z_after); // 누른 블록이 숨었다
    try testing.expect(q_after > 0); // **다른 블록은 그대로다** — 이것이 전체 접기와 갈리는 자리다
    try testing.expectEqual(@as(usize, 1), collapsed_after); // 방향이 바뀐 화살표도 하나뿐이다

    // 같은 자리를 다시 누르면 펴진다 — 같은 상태를 두 입구가 공유한다(`unfoldAll`도 이것을 편다).
    try testing.expect(toggleFoldAtPoint(fx.session, pane, mark_x, mark_y));
    try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len);

    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer d2.dl.deinit(allocator);
    var z_back: usize = 0;
    for (d2.dl.cells) |c| {
        if (c.codepoint == 'z') z_back += 1;
    }
    try testing.expectEqual(z_before, z_back);
}

test "접기 칸의 왼쪽 여백 칸도 화살표를 누른 것으로 친다 — 누르는 자리가 그리는 자리보다 넓다" {
    // **span은 두 셀이고 글자는 오른쪽 칸 하나다**(`geometry.foldMarkCol`). 왼쪽 칸은 줄 번호와의
    // 여백인데, 포인터에게는 그 칸까지 화살표의 자리다 — 1셀(≈8px)은 맞히기에 좁다. 반대 방향의
    // 규율은 지킨다: **누르는 자리가 넓은 것은 괜찮지만 다른 자리면 안 된다**(§5.4).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    try foldClickFixture(&fx, lines);

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    d0.dl.deinit(allocator);

    const geom = fx.term.rt.editor_hit_geom;
    const fold_left_col: f64 = @floatFromInt(geom.fold_left_px / geom.cell_w_px);
    // 첫 화면 행(문서 1줄 = 머리)의 **왼쪽 칸**을 누른다.
    const x = ox + (fold_left_col + 0.5) * cw;
    const y = oy + 0.5 * ch;

    try testing.expect(toggleFoldAtPoint(fx.session, pane, x, y));
    try testing.expectEqual(@as(usize, 1), foldedHeads(fx.term).len);
}

test "gutter 클릭이 접기를 가져가지 않는 자리들 — 본문·번호 칸·화살표 없는 줄·pane 밖" {
    // **`true`를 남발하면 클릭이 소비되어 pane 포커스 이동이 조용히 죽는다.** 그리고 세로를
    // clamp하면(본문 hit-test는 그렇게 한다) pane 아래 빈 곳을 눌러도 마지막 줄이 접힌다 —
    // 두 좌표계가 갈리는 유일한 축이라 여기서 못 박는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    try foldClickFixture(&fx, lines);

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    d0.dl.deinit(allocator);

    const geom = fx.term.rt.editor_hit_geom;
    const fold_col: f64 = @floatFromInt(geom.fold_left_px / geom.cell_w_px);
    const content_col: f64 = @floatFromInt(geom.content_left_px / geom.cell_w_px);
    const head_y = oy + 0.5 * ch; // 문서 1줄 — 화살표가 서 있는 행

    // 본문 열: 선택이 가져간다.
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (content_col + 0.5) * cw, head_y));
    // 줄 번호 칸: 접기 띠 왼쪽이다.
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (fold_col - 0.5) * cw, head_y));
    // 화살표가 없는 줄(6번째 = "tail")의 접기 칸.
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (fold_col + 0.5) * cw, oy + 5.5 * ch));
    // pane **밖**: 아래로 한참, 그리고 위로.
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (fold_col + 0.5) * cw, oy + 10_000));
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (fold_col + 0.5) * cw, oy - 5));
    // 극단값에서도 죽지 않는다(`@intFromFloat`은 표현 불가능한 값에서 illegal behavior다).
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, std.math.nan(f64), std.math.nan(f64)));
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, std.math.inf(f64), -std.math.inf(f64)));
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, 1e300, 1e300));

    // 그 어느 것도 상태를 건드리지 않았다.
    try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len);
}

/// 지금 화면에 선 접힘 화살표들의 (행, 열)을 위에서부터 모은다. 판정자가 **그린 자리**를 눌러야
/// 하므로(그리기와 클릭이 갈리면 그 순간 죽는 것이 목적이다) 좌표를 지어내지 않고 렌더 산출물에서
/// 읽는다.
const AdvFoldMark = struct { row: u16, col: u16, collapsed: bool };

fn advFoldMarks(dl: renderer.DrawList, out: []AdvFoldMark) usize {
    const open_mark: u21 = chrome_editor.gutter.Fold.open.codepoint().?;
    const collapsed_mark: u21 = chrome_editor.gutter.Fold.collapsed.codepoint().?;
    var n: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint != open_mark and c.codepoint != collapsed_mark) continue;
        if (n >= out.len) break;
        out[n] = .{ .row = @intCast(c.row), .col = @intCast(c.col), .collapsed = c.codepoint == collapsed_mark };
        n += 1;
    }
    // 셀 순서를 계약으로 삼지 않는다 — 행 오름차순으로 세워 판정자가 "n번째 화살표"를 말할 수 있게 한다.
    std.mem.sort(AdvFoldMark, out[0..n], {}, struct {
        fn lt(_: void, a: AdvFoldMark, b: AdvFoldMark) bool {
            return a.row < b.row;
        }
    }.lt);
    return n;
}

test "ADV-F1 화살표를 역순으로 눌러도 접힘 집합이 오름차순이다 — `hiddenSpans` 계약" {
    // **이 축은 개별 접기만 건드린다.** 전체·레벨 접기는 `compute`가 낸 문서 순서를 걸러 담으므로
    // 오름차순을 공짜로 만족하고, 하나씩 넣고 빼는 이 경로만 스스로 지켜야 한다. 그런데 초판
    // 판정자는 **블록을 하나만** 접어서 이 축을 원리상 못 쟀다 — 원소가 하나면 어떤 순서도 정렬이다.
    //
    // 뒤 블록부터 거꾸로 누른다. 삽입 자리가 틀리면 `hiddenSpans`가 계약을 잃고 **숨어야 할 줄이
    // 남거나 엉뚱한 줄이 숨는다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 6);
    defer allocator.free(lines);
    lines[0] = "a:";
    lines[1] = "  xxx";
    lines[2] = "b:";
    lines[3] = "  yyy";
    lines[4] = "c:";
    lines[5] = "  zzz";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);

    var marks: [16]AdvFoldMark = undefined;

    // 화살표 셋이 선다 — 전제가 깨지면 아래 판정이 공허하다.
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    var count = advFoldMarks(d0.dl, &marks);
    d0.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), count);

    // **맨 아래 화살표부터** 누른다. 누를 때마다 행이 줄어드므로 그때그때 다시 그려 찾는다.
    var pressed: usize = 0;
    while (pressed < 3) : (pressed += 1) {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
        count = advFoldMarks(d.dl, &marks);
        d.dl.deinit(allocator);
        try testing.expectEqual(@as(usize, 3), count); // 머리는 접혀도 화면에 남는다(§4.1f)

        // 아직 안 접힌 것 중 가장 아래.
        var target: ?usize = null;
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            if (!marks[i].collapsed) {
                target = i;
                break;
            }
        }
        const t = target orelse return error.NoOpenMarkLeft;
        const x = ox + (@as(f64, @floatFromInt(marks[t].col)) + 0.5) * cw;
        const y = oy + (@as(f64, @floatFromInt(marks[t].row)) + 0.5) * ch;
        try testing.expect(toggleFoldAtPoint(fx.session, pane, x, y));
    }

    // ① 집합이 오름차순이다 — `hiddenSpans`가 계약으로 요구한다.
    const heads = foldedHeads(fx.term);
    try testing.expectEqual(@as(usize, 3), heads.len);
    for (heads[1..], 0..) |h, k| {
        if (h <= heads[k]) {
            std.debug.print("\n[ADV-F1] 접힘 집합이 오름차순이 아니다: {any}\n", .{heads});
            return error.FoldedHeadsNotSorted;
        }
    }
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, heads);

    // ② 그리고 **화면이 실제로 그 상태다** — 순서만 맞고 화면이 틀리면 아무것도 지킨 것이 없다.
    var after = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer after.dl.deinit(allocator);
    var body: usize = 0;
    for (after.dl.cells) |c| {
        if (c.codepoint == 'x' or c.codepoint == 'y' or c.codepoint == 'z') body += 1;
    }
    try testing.expectEqual(@as(usize, 0), body); // 세 블록의 몸통이 전부 숨었다
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_visible_lines.len);
}

test "ADV-F2 중첩: 안쪽을 접고 바깥을 접었다 펴면 안쪽은 접힌 채로 남는다" {
    // **집합은 머리 줄의 모음이지 "마지막 동작"이 아니다.** 바깥을 펴는 것이 안쪽 상태까지 지우면
    // 사용자가 손으로 접어 둔 것이 조용히 사라진다(VSCode·Vim 둘 다 남긴다). `hiddenSpans`가 두
    // 구간을 어떻게 합치는지가 이 판정의 실질이고, 개별 토글 전에는 **만들 수 없던 상태**다 —
    // 전체·레벨 접기는 집합을 갈아 끼우므로 "바깥만 펴기"가 애초에 없다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 5);
    defer allocator.free(lines);
    lines[0] = "outer:"; // 바깥 머리
    lines[1] = "  inner:"; // 안쪽 머리(바깥의 몸통이기도 하다)
    lines[2] = "    zzz"; // 안쪽 몸통
    lines[3] = "    zzz";
    lines[4] = "tail";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    var marks: [16]AdvFoldMark = undefined;

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    var count = advFoldMarks(d0.dl, &marks);
    d0.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), count); // 바깥·안쪽 둘 다 접을 수 있다

    const press = struct {
        fn at(session: *AppSession, p: *Pane, ox_: f64, oy_: f64, cw_: f64, ch_: f64, m: AdvFoldMark) bool {
            return toggleFoldAtPoint(
                session,
                p,
                ox_ + (@as(f64, @floatFromInt(m.col)) + 0.5) * cw_,
                oy_ + (@as(f64, @floatFromInt(m.row)) + 0.5) * ch_,
            );
        }
    };

    // ① 안쪽(둘째 화살표)을 접는다.
    try testing.expect(press.at(fx.session, pane, ox, oy, cw, ch, marks[1]));
    try testing.expectEqualSlices(u32, &.{1}, foldedHeads(fx.term));

    // ② 바깥(첫째 화살표)도 접는다 — 안쪽 머리까지 숨는다.
    var d1 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    count = advFoldMarks(d1.dl, &marks);
    d1.dl.deinit(allocator);
    try testing.expect(count >= 1);
    try testing.expect(press.at(fx.session, pane, ox, oy, cw, ch, marks[0]));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, foldedHeads(fx.term)); // **오름차순 유지**

    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    var visible_z: usize = 0;
    for (d2.dl.cells) |c| {
        if (c.codepoint == 'z') visible_z += 1;
    }
    count = advFoldMarks(d2.dl, &marks);
    d2.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), visible_z);
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_visible_lines.len); // outer: · tail
    try testing.expectEqual(@as(usize, 1), count); // 안쪽 머리가 숨었으므로 화살표도 하나뿐이다

    // ③ 바깥만 다시 편다 — 안쪽은 **접힌 채**여야 한다.
    try testing.expect(press.at(fx.session, pane, ox, oy, cw, ch, marks[0]));
    try testing.expectEqualSlices(u32, &.{1}, foldedHeads(fx.term));

    var d3 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer d3.dl.deinit(allocator);
    visible_z = 0;
    for (d3.dl.cells) |c| {
        if (c.codepoint == 'z') visible_z += 1;
    }
    try testing.expectEqual(@as(usize, 0), visible_z); // 안쪽 몸통은 여전히 숨어 있다
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_visible_lines.len); // outer: · inner: · tail
}

test "ADV-F3 스크롤한 뒤 누른 화살표는 그 화면 줄의 블록이다 — gutter 번호와 대조한다" {
    // **행 → 문서 줄 변환에 스크롤이 섞이는 자리다.** `hitTestBody`가 같은 축에서 실측 36줄 어긋난
    // 적이 있고(`editor_first_line`을 live로 읽었다), 접기 좌표계는 같은 스냅숏을 쓰지만 **그것을
    // 재는 판정자가 없었다** — 초판 판정자는 전부 `first_line = 0`이다.
    //
    // 오라클은 **gutter가 그린 번호**다: 누른 행에 그려진 번호가 `n`이면 접힌 머리는 `n - 1`이어야
    // 한다(번호는 1-based, 머리는 0-based).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const n_blocks = 40;
    const lines = try allocator.alloc([]const u8, n_blocks * 2);
    defer allocator.free(lines);
    for (0..n_blocks) |i| {
        lines[i * 2] = "head:";
        lines[i * 2 + 1] = "  body";
    }
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = false;
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);

    fx.term.rt.editor_first_line = 11; // 문서 중간부터 본다 — 홀수라 머리/몸통 정렬도 어긋난다

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);

    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    var marks: [64]AdvFoldMark = undefined;
    const count = advFoldMarks(d0.dl, &marks);

    // 그 행에 gutter가 그린 번호를 읽는다(같은 프레임에서).
    const rows = fx.term.rt.editor_hit_rows_len;
    var nums_buf: [512]?u32 = undefined;
    advGutterNumbers(d0.dl, advContentLeft(fx.term), nums_buf[0..rows]);
    d0.dl.deinit(allocator);

    try testing.expect(count > 3); // 화면에 화살표가 여럿 서 있다 — 전제

    const target = marks[2]; // 화면 위에서 셋째 화살표
    const want_number = nums_buf[target.row] orelse return error.NoGutterNumberOnMarkRow;

    try testing.expect(toggleFoldAtPoint(
        fx.session,
        pane,
        ox + (@as(f64, @floatFromInt(target.col)) + 0.5) * cw,
        oy + (@as(f64, @floatFromInt(target.row)) + 0.5) * ch,
    ));

    const heads = foldedHeads(fx.term);
    try testing.expectEqual(@as(usize, 1), heads.len);
    if (heads[0] != want_number - 1) {
        std.debug.print(
            "\n[ADV-F3] 스크롤 뒤 어긋남: first_line={d} 누른 행={d} gutter 번호={d} 기대 머리={d} 실제 머리={d}\n",
            .{ fx.term.rt.editor_first_line, target.row, want_number, want_number - 1, heads[0] },
        );
        return error.FoldedWrongLineAfterScroll;
    }
}

test "ADV-F4 화살표 클릭이 실패해도 접힘 집합이 옛 상태로 돌아온다" {
    // `applyFold`가 같은 자리를 지키는 이유와 같다 — 화면은 그대로인데 상태만 달라지면 되돌릴 길이
    // 없어진다. **개별 토글은 백업을 스스로 떠야 한다**(`editor_folded_prev`). 초판 판정자는 성공
    // 경로만 밟아 이 축을 못 쟀다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;
    var checked: usize = 0;

    var step: usize = 0;
    while (step < 8) : (step += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        const alloc = fa.allocator();
        var fx = try PaneFixture.init(alloc);
        defer fx.deinit(alloc);

        const saved = fx.term.rt.editor_lines;
        defer fx.term.rt.editor_lines = saved;
        const lines = try backing.alloc([]const u8, 6);
        defer backing.free(lines);
        try foldClickFixture(&fx, lines);

        const pane = pane_ops.activePane(fx.session);
        const cw: f64 = @floatFromInt(fx.session.cell_width_px);
        const ch: f64 = @floatFromInt(fx.session.cell_height_px);
        var marks: [16]AdvFoldMark = undefined;

        var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse continue;
        const ox: f64 = @floatFromInt(d0.rect.x);
        const oy: f64 = @floatFromInt(d0.rect.y);
        const count = advFoldMarks(d0.dl, &marks);
        d0.dl.deinit(alloc);
        if (count == 0) continue;

        // 먼저 한 블록을 성공적으로 접어 둔다 — 되돌릴 "옛 상태"가 있어야 판정이 성립한다.
        const first_x = ox + (@as(f64, @floatFromInt(marks[0].col)) + 0.5) * cw;
        const first_y = oy + (@as(f64, @floatFromInt(marks[0].row)) + 0.5) * ch;
        if (!toggleFoldAtPoint(fx.session, pane, first_x, first_y)) continue;
        try testing.expectEqual(@as(usize, 1), foldedHeads(fx.term).len);

        var d1 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse continue;
        const count2 = advFoldMarks(d1.dl, &marks);
        d1.dl.deinit(alloc);
        if (count2 < 2) continue;

        fa.fail_index = fa.allocations + step; // 그 뒤의 할당부터 실패한다
        const second_x = ox + (@as(f64, @floatFromInt(marks[1].col)) + 0.5) * cw;
        const second_y = oy + (@as(f64, @floatFromInt(marks[1].row)) + 0.5) * ch;
        if (toggleFoldAtPoint(fx.session, pane, second_x, second_y)) continue; // 실패를 못 겪었다
        checked += 1;

        // **옛 집합 그대로**여야 한다 — 반쪽 상태(둘째가 들어간 채)로 남으면 화면과 갈린다.
        try testing.expectEqual(@as(usize, 1), foldedHeads(fx.term).len);
        // 그리고 되돌릴 수 있다.
        try testing.expect(unfoldAll(fx.session));
        try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len);
    }
    try testing.expect(checked >= 1); // 실패를 한 번도 못 겪었으면 아무것도 지키지 않았다
}

test "랩으로 이어진 조각의 접기 칸은 화살표가 없으므로 눌리지 않는다" {
    // **그린 것과 눌리는 것이 같아야 한다.** gutter는 이어진 조각에 표식을 반복하지 않는데
    // (`rowsForVisual` — 한 줄에 표식이 여러 개면 접힌 줄 수를 오해한다), hit-test가 그 행을 받으면
    // **아무것도 없는 자리를 눌러 접히는** 상태가 된다. 행 → 줄 매핑(`editor_hit_lines`)은 이어진
    // 조각에도 같은 원본 줄을 주므로 그 축만으로는 못 막는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, 3);
    defer allocator.free(lines);
    var long_head: [400]u8 = undefined;
    @memset(&long_head, 'h');
    long_head[long_head.len - 1] = ':';
    lines[0] = &long_head; // 화면 폭보다 길어 여러 조각으로 접힌다
    lines[1] = "  zzz";
    lines[2] = "  zzz";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_wrap = true;
    try ensureFoldRanges(fx.session, fx.term);
    try rebuildVisible(fx.session, fx.term);

    const pane = pane_ops.activePane(fx.session);
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.EditorPaneDidNotDraw;
    const ox: f64 = @floatFromInt(d0.rect.x);
    const oy: f64 = @floatFromInt(d0.rect.y);
    var marks: usize = 0;
    const open_mark: u21 = chrome_editor.gutter.Fold.open.codepoint().?;
    for (d0.dl.cells) |c| {
        if (c.codepoint == open_mark) marks += 1;
    }
    d0.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), marks); // 머리 조각에만 선다 — 전제 확인

    const geom = fx.term.rt.editor_hit_geom;
    const fold_col: f64 = @floatFromInt(geom.fold_left_px / geom.cell_w_px);
    try testing.expect(fx.term.rt.editor_hit_rows_len > 2); // 실제로 여러 조각으로 접혔다

    // **둘째 조각**(화면 행 1)의 접기 칸 — 화살표가 없는 자리다.
    try testing.expect(hitTestFoldMark(fx.term, ox + (fold_col + 0.5) * cw, oy + 1.5 * ch) == null);
    try testing.expect(!toggleFoldAtPoint(fx.session, pane, ox + (fold_col + 0.5) * cw, oy + 1.5 * ch));
    try testing.expectEqual(@as(usize, 0), foldedHeads(fx.term).len);

    // 머리 조각(화면 행 0)은 받는다 — 위 거절이 "랩이면 전부 막는다"가 아님을 보인다.
    try testing.expect(toggleFoldAtPoint(fx.session, pane, ox + (fold_col + 0.5) * cw, oy + 0.5 * ch));
    try testing.expectEqual(@as(usize, 1), foldedHeads(fx.term).len);
}

/// 테스트 전용 libc 바인딩. Zig 0.16 std에는 `setenv`가 없고, 훅 확인은 **환경을 실제로 켜야만**
/// 성립한다(끈 상태로 비교하면 양쪽 다 false라 아무것도 증명하지 못한다 — 비교 훅에서 실제로
/// 그렇게 써서 뮤턴트가 살아남았다). 켠 값은 곧바로 되돌린다.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "텍스트 파일이 편집기 Term으로 열린다 — 되돌리면 지금까지의 CM6다" {
    // **이 분기가 이 슬라이스의 전부다.** 지금까지 네이티브 편집기를 제품에서 보려면 시작할 때
    // `MARU_NATIVE_EDITOR=<경로>`로 한 파일을 열어야 했고, 다른 파일을 보려면 앱을 다시 띄워야 했다.
    // **되돌린 경로도 함께 고정한다** — 기본이 네이티브가 된 지금(2026-08-19) `MARU_NATIVE_TEXT=0`이
    // 편집 수단이므로, 그 경로가 조용히 죽으면 사용자는 파일을 고칠 길을 잃는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "off.txt", .data = "one\ntwo\nthree" });
    try tmp.dir.writeFile(io, .{ .sub_path = "on.txt", .data = "one\ntwo\nthree" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = "\xff\xfe\x00binary" });
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# title" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const off_path = try std.fs.path.join(allocator, &.{ root, "off.txt" });
    defer allocator.free(off_path);
    const on_path = try std.fs.path.join(allocator, &.{ root, "on.txt" });
    defer allocator.free(on_path);
    const bad_path = try std.fs.path.join(allocator, &.{ root, "bad.bin" });
    defer allocator.free(bad_path);
    const md_path = try std.fs.path.join(allocator, &.{ root, "doc.md" });
    defer allocator.free(md_path);

    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 되돌린 상태(`MARU_NATIVE_TEXT=0`) — 지금까지의 웹 Term이다.
    session.native_text = false;
    const off = try pane_ops.openFileTermInActivePane(session, off_path, .text);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.web, off.term.kind);
    try testing.expect(!off.term.file_entry.?.native_editor);

    // 기본 상태 — 편집기 Term이고, **문서가 실려 있다**. Term 종류만 보면 빈 편집기를 열어도 통과한다.
    session.native_text = true;
    const on = try pane_ops.openFileTermInActivePane(session, on_path, .text);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.editor, on.term.kind);
    try testing.expectEqual(@as(usize, 3), on.term.rt.editor_lines.len);
    try testing.expectEqualStrings("two", on.term.rt.editor_lines[1]);
    try testing.expectEqualStrings(on_path, on.term.rt.editor_path.?);
    try testing.expect(on.term.file_entry.?.native_editor);
    try testing.expectEqual(on.term.surfaceId(), on.term.file_entry.?.surface_id);

    // **못 읽는 파일은 CM6로 간다**(§3.5 — UTF-8 아님). 기본이 네이티브인 것이 특정 파일을 아예
    // 못 여는 이유가 되면 안 된다.
    const bad = try pane_ops.openFileTermInActivePane(session, bad_path, .text);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.web, bad.term.kind);
    try testing.expect(!bad.term.file_entry.?.native_editor);

    // 텍스트가 아닌 종류는 이 결정과 무관하다 — 마크다운은 리치 프리뷰가 주 가치라 CM6에 남는다.
    const md = try pane_ops.openFileTermInActivePane(session, md_path, .markdown);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.web, md.term.kind);
}

test "init이 MARU_NATIVE_TEXT를 읽는다 — 안 읽으면 훅이 아무 일도 안 한다" {
    // 비교 훅이 실제로 그 상태로 커밋된 적이 있다(읽기를 `init`이 아니라 `deinit`에 넣어 값이 영영
    // false였다). 테스트가 필드를 직접 세우면 그래도 전부 통과한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    const had = std.c.getenv("MARU_NATIVE_TEXT");
    defer if (had) |old_value| {
        _ = setenv("MARU_NATIVE_TEXT", old_value, 1);
    } else {
        _ = unsetenv("MARU_NATIVE_TEXT");
    };
    _ = setenv("MARU_NATIVE_TEXT", "1", 1);
    try testing.expect(nativeTextFromEnv()); // 전제: 환경이 켜졌다

    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();
    try testing.expect(session.native_text);
}

test "훅 기본은 켬이고 0으로 되돌릴 수 있다 — 되돌릴 길이 곧 편집 수단이다" {
    // **기본이 네이티브다**(2026-08-19 사용자 결정). N1은 읽기 전용이므로 그 기본은 탐색기에서 연
    // 파일을 고칠 수 없게 만들고, `0`이 유일한 편집 수단이다 — 그 값이 안 먹으면 사용자는 되돌릴
    // 길을 잃는다. 그래서 기본값과 되돌림을 **한 테스트에서 함께** 고정한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const had = std.c.getenv("MARU_NATIVE_TEXT");
    defer if (had) |old_value| {
        _ = setenv("MARU_NATIVE_TEXT", old_value, 1);
    } else {
        _ = unsetenv("MARU_NATIVE_TEXT");
    };
    _ = unsetenv("MARU_NATIVE_TEXT");
    try testing.expect(nativeTextFromEnv());
    _ = setenv("MARU_NATIVE_TEXT", "0", 1);
    try testing.expect(!nativeTextFromEnv());
}

test "네이티브로 연 텍스트는 CM6 스냅샷을 기다리지 않는다 — 안 그러면 탭이 안 닫힌다" {
    // **`.text`의 기본 mode가 `.source_edit`이라** `filePanelEntryNeedsDirtyProtection`이 늘 참이었다.
    // 닫기는 그 상태에서 CM6에 dirty 스냅샷을 요청하고 응답을 기다리는데, 네이티브 Term에는 응답할
    // CM6가 없다 — 그대로 두면 **네이티브로 연 탭이 닫히지 않는다**. 브리지 술어를 kind에서 entry로
    // 올린 이유가 이것이다.
    const dock_panel = maru.session.dock_panel;

    var path_buf = "x.txt".*;
    var entry: dock_panel.Entry = .{
        .id = 1,
        .path = &path_buf,
        .kind = .text,
        .mode = dock_panel.Mode.defaultFor(.text),
    };
    // CM6로 열린 텍스트는 지금까지대로 브리지를 쓰고 보호를 요구한다.
    try testing.expect(entry.usesEditorBridge());
    try testing.expect(file_panel_ops.filePanelEntryNeedsDirtyProtection(entry));

    // 네이티브로 열면 둘 다 아니다.
    entry.native_editor = true;
    try testing.expect(!entry.usesEditorBridge());
    try testing.expect(!file_panel_ops.filePanelEntryNeedsDirtyProtection(entry));

    // **dirty 자체가 서면 여전히 보호한다** — 술어를 통째로 꺼 버리면 이 단언이 무너진다.
    entry.dirty = true;
    try testing.expect(file_panel_ops.filePanelEntryNeedsDirtyProtection(entry));
}

/// **측정용 프로토타입** — 목표 열 이하에서 가장 가까운 cluster 경계의 byte.
///
/// **역방향**(`hitTestBody`)이 필요로 하는 걸음이다(포인터 → 열 → byte, `Selection`이 byte offset 기반).
/// `content.stepColumn` 하나를 되짚으므로 규칙이 갈리지 않는다 — 탭스톱·cluster 분절·§3.8 표기가
/// 그 함수에만 있고, 이 방향을 따로 짜면 그 셋이 두 곳으로 갈린다(그렇게 갈려서 강조가 7칸 밀린
/// 전례가 §4.1c에 적혀 있다).
fn byteAtColumnProto(bytes: []const u8, tab_width: u16, target_col: u32) usize {
    var i: usize = 0;
    var col: u32 = 0;
    while (i < bytes.len) {
        const st = chrome_editor.content.stepColumn(bytes, i, col, tab_width);
        if (st.next_col > target_col) break;
        i = st.next_byte;
        col = st.next_col;
    }
    return i;
}

test "[측정] 열→byte 역방향 — 클릭 지점까지 훑는 비용" {
    // **역방향(`hitTestBody`)의 뼈대 비용이다.** 클릭한 픽셀은 열이 되고, 열은 byte가 되어야 selection이
    // 그것을 든다. 이 방향이 거리에 비례하면 §4.1c의 `max_first_col` 상한과 **같은 성질의 상한**이
    // 클릭에도 필요해진다 — 그 판단의 근거를 여기서 만든다.
    //
    // **정방향(`columnOfByte`)과 나란히 잰다.** 둘이 같은 비용이면 "역방향이 특별히 비싸다"는 말은
    // 틀린 것이고, 상한은 방향이 아니라 **거리**의 문제가 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = testing.allocator;
    const cases = [_]struct { name: []const u8, unit: []const u8 }{
        .{ .name = "ASCII", .unit = "abcdefghij" },
        .{ .name = "한글(2칸)", .unit = "가나다라마" },
        .{ .name = "탭+ASCII", .unit = "\tabc\tdef" },
        .{ .name = "BiDi 표기(§3.8)", .unit = "ab\u{202E}cd" },
    };
    const reps = 20_000;
    for (cases) |c| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        for (0..reps) |_| try line.appendSlice(alloc, c.unit);
        const total_cols = chrome_editor.content.lineColumns(line.items, 4);
        const scratch = try alloc.alloc(u8, line.items.len * 8 + 64);
        defer alloc.free(scratch);

        std.debug.print("\n[측정] {s}: {d}B, {d}열\n", .{ c.name, line.items.len, total_cols });
        for ([_]u32{ 100, 1_000, 10_000, 100_000 }) |target| {
            if (target > total_cols) continue;
            // **회귀 감지에 필요한 만큼만 돈다.** 문서에 실은 수치는 이 하니스로 이미 얻었고
            // (§4.1g), 여기 남기는 목적은 그 값이 크게 어긋나는 것을 잡는 것이다 — 200회를
            // 유지하면 이 테스트 하나가 전체 실행에 수십 초를 더한다.
            const rounds: usize = 20;
            var sink: usize = 0;
            const r0 = monotonicMsForTest();
            for (0..rounds) |_| sink +%= byteAtColumnProto(line.items, 4, target);
            const r1 = monotonicMsForTest();

            const off = byteAtColumnProto(line.items, 4, target);
            var sink2: u32 = 0;
            const f0 = monotonicMsForTest();
            for (0..rounds) |_| sink2 +%= chrome_editor.content.columnOfByte(line.items, 4, off, scratch);
            const f1 = monotonicMsForTest();

            std.debug.print("  col={d:>7}  역방향={d:>7.1}µs  정방향={d:>7.1}µs  (byte={d})\n", .{
                target,
                @as(f64, @floatFromInt(r1 - r0)) * 1000.0 / @as(f64, @floatFromInt(rounds)),
                @as(f64, @floatFromInt(f1 - f0)) * 1000.0 / @as(f64, @floatFromInt(rounds)),
                off,
            });
            std.mem.doNotOptimizeAway(sink);
            std.mem.doNotOptimizeAway(sink2);
        }
    }
}

test "[측정] 조각 시작을 함께 내는 비용 — 렌더 루프에 걸음이 하나 더 붙는다 (§4.1g)" {
    // **계약이 "구현 슬라이스에서 잰다"고 미뤄 둔 값이다.** `content.build`가 조각을 순회하며 원본을
    // `stepColumn`으로 **병행해** 걸어 `start_byte`를 낸다 — 전개(`expandTabs`)와 별개 걸음이므로
    // 공짜가 아니다. 그 몫이 프레임 예산에서 얼마인지 재지 않으면 "작다"는 말은 추측이다.
    //
    // 같은 문서를 두 번 그려 비교하지 않는다 — 두 번째는 CPU 캐시가 따뜻해 첫 번째보다 빠르다(여는
    // 경로 측정에서 같은 함정을 만났다). 대신 **랩을 켜고 끈 두 문서**를 각각 여러 프레임 그려,
    // 병행 걸음이 실제로 도는 랩 켠 쪽이 얼마나 더 드는지 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 본문 폭보다 훨씬 긴 줄 — 랩을 켜면 줄마다 여러 조각이 된다.
    const line = "const value = compute(index); // 탭\t한글 가나다 그리고 이모지 😀 를 섞어 조각이 여러 개가 되게 한다\n";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..3_000) |_| try text.appendSlice(allocator, line);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "wrap.zig", .data = text.items });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "wrap.zig" });
    defer allocator.free(path);

    const term = try openPathInActivePane(fx.session, path);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };

    for ([_]bool{ false, true }) |wrap| {
        term.rt.editor_wrap = wrap;
        term.rt.editor_row_cache.filled = false; // 랩이 갈리면 캐시가 무효다
        var slowest: u64 = 0;
        var total: u64 = 0;
        const frames: usize = 30;
        for (0..frames) |_| {
            const t0 = monotonicMsForTest();
            // **draw list를 풀어야 한다.** `appendPaneFrame`은 프레임마다 새 리스트를 만들어 주고
            // 소유를 호출자에게 넘긴다 — `_ =`로 버리면 그 할당이 그대로 샌다. 30프레임 × 2회면
            // 60번 새는 것이고, 러너는 그것을 **error 로그**로 보고해 테스트가 다 통과해도 종료
            // 코드를 1로 만든다(CI가 정확히 그렇게 실패했다).
            if (appendPaneFrame(fx.session, leaf, term)) |drawn| {
                var d = drawn;
                d.dl.deinit(allocator);
            }
            const dt = monotonicMsForTest() - t0;
            total += dt;
            if (dt > slowest) slowest = dt;
        }
        std.debug.print("\n[측정] 랩={s}: 프레임 평균 {d}ms, 최악 {d}ms ({d}줄)\n", .{
            if (wrap) "켬" else "끔",
            total / frames,
            slowest,
            term.rt.editor_lines.len,
        });
    }
}

test "hitTestBody: 렌더가 그린 자리를 기준선으로 삼는다 (§4.1g 다섯 단계)" {
    // **기준선이 구현이면 아무것도 못 잡는다.** 초판은 좌표를 구현과 **같은 식**으로 만들었고
    // (`sideMetrics(body.w, …)`, 원점 `body`), 그래서 렌더 원점의 `content_inset_px`(4px)를 빠뜨린
    // 것과 layout 인자가 렌더와 다른 것을 **둘 다 통과**시켰다 — 적대적 검증이 실측으로 잡았다.
    //
    // 그래서 여기서는 **렌더가 실제로 그린 op의 좌표**를 읽어 그 자리를 클릭한다. 그러면 어느 층이
    // 어긋나도 이 테스트가 먼저 깨진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const io_dir = fx.dir.dir;
    try io_dir.writeFile(io, .{ .sub_path = "hit.txt", .data = "abcdef\nghijkl\nmnopqr\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try io_dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "hit.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **그리기 전에는 받지 않는다** — 행 배열이 비어 있다.
    try testing.expectEqual(@as(?usize, null), hitTestBody(term, 500, 100));

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len > 0);

    // **렌더가 그린 첫 글자 셀을 찾는다.** `PaneDraw.rect`가 op 원점이고(여백 안쪽), 셀은 그 위에
    // `cell_w × cell_h`로 깔린다. 첫 텍스트 셀의 창 좌표가 곧 "화면에서 'a'가 있는 자리"다.
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    var first_cell: ?struct { x: f64, y: f64 } = null;
    for (drawn.dl.cells) |c| {
        if (c.codepoint != 'a') continue;
        first_cell = .{
            .x = @as(f64, @floatFromInt(drawn.rect.x)) + @as(f64, @floatFromInt(c.col)) * cw,
            .y = @as(f64, @floatFromInt(drawn.rect.y)) + @as(f64, @floatFromInt(c.row)) * ch,
        };
        break;
    }
    const a = first_cell orelse return error.NoFirstCell;

    // 'a' 칸의 **왼쪽 절반** → 그 글자 앞(offset 0), **오른쪽 절반** → 뒤(offset 1).
    // caret 모델이라 1칸 안에 두 자리가 있다(§4.1g 9회차).
    try testing.expectEqual(@as(?usize, 0), hitTestBody(term, a.x + 1, a.y + 1));
    try testing.expectEqual(@as(?usize, 1), hitTestBody(term, a.x + cw - 1, a.y + 1));
    // 셋째 칸 왼쪽 → offset 2.
    try testing.expectEqual(@as(?usize, 2), hitTestBody(term, a.x + 2 * cw + 1, a.y + 1));

    // **같은 행의 아래쪽 픽셀도 같은 줄이다** — 세로 원점이 밀리면 여기서 다음 줄이 나온다.
    try testing.expectEqual(@as(?usize, 0), hitTestBody(term, a.x + 1, a.y + ch - 1));

    // 둘째 줄 첫 글자 = 문서 offset 7("abcdef\n" 다음).
    try testing.expectEqual(@as(?usize, 7), hitTestBody(term, a.x + 1, a.y + ch + 1));

    // **행 끝 너머는 그 행의 끝**(6) — 줄 맨 끝이지 문서 끝이 아니다.
    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const right_edge: f64 = @as(f64, @floatFromInt(body.x)) + @as(f64, @floatFromInt(body.w)) - 1;
    try testing.expectEqual(@as(?usize, 6), hitTestBody(term, right_edge, a.y + 1));

    // **gutter는 받지 않는다** — 접힘 화살표가 먼저 가져간다. 본문 왼쪽 1픽셀도 포함이다.
    try testing.expectEqual(@as(?usize, null), hitTestBody(term, a.x - 1, a.y + 1));

    // **세로 밖은 clamp한다** — 드래그가 pane을 벗어나는 것은 정상이다.
    //
    // 아래로 나가면 **마지막 보이는 행**이다. 이 문서는 끝 개행이 만든 **빈 4번째 줄**까지 있어
    // (`"…mnopqr\n"` → 줄 넷) 그 줄의 시작 offset 21이 답이다 — 초판은 3줄이라고 가정해 14를
    // 적었고, 그것은 3번 줄의 *시작*이지 마지막 행이 아니었다(2차 적대적 검증이 잡았다).
    try testing.expectEqual(@as(?usize, 0), hitTestBody(term, a.x + 1, a.y - 500));
    try testing.expectEqual(@as(usize, 4), term.rt.editor_lines.len); // 전제: 빈 4번째 줄이 있다
    try testing.expectEqual(@as(?usize, 21), hitTestBody(term, a.x + 1, a.y + 5000));
}

// ─────────────────── [주 판정] 화면과 클릭이 어긋나지 않는가 (§4.1g) ───────────────────
//
// **오라클은 렌더가 실제로 낸 것뿐이다** — 그린 글자(`DrawList.cells`), gutter가 그린 줄 번호,
// 렌더의 원점(`PaneDraw.rect`). 구현식을 다시 쓰지 않는다.
//
// **초판은 판정력이 0이었다**(3차 적대적 검증). 좌표는 33,048발이나 쐈지만 ⑴ 가장 긴 줄이 70열인데
// 본문이 89열이라 **랩이 한 번도 안 걸렸고**(`piece`·`start_col`·`start_byte`가 네 config 모두 0),
// ⑵ 그래서 행 경계 부등식이 **0회** 실행됐으며, ⑶ 판정에 쓰는 줄을 `editor_hit_lines`에서 읽어
// **자기가 검증한다는 배열로 기대값을 만들었다**. 뮤턴트 8개를 전부 통과시켰고, 그중에는
// `return line.start;`(x를 아예 안 보는 것)도 있었다.

/// 그 **화면 칸을 소유한 cluster**가 화면 글자와 1:1로 대응하지 않는가(탭·§3.8 표기).
///
/// 오라클 테스트가 "그린 글자 == 클릭이 답한 글자"를 비교할 때, 이런 칸은 비교 자체가 성립하지
/// 않으므로 뺀다 — 원본 하나가 화면 여럿이기 때문이다.
///
/// **답을 기준으로 거르면 안 된다**(적대적 검증 6회차가 세 규칙을 계측했다). 표기 여덟 칸 중 중점
/// 오른쪽 칸들은 **다음 cluster**를 답하고 그 cluster에는 hazard가 없어, 답의 cp만 보면 3,003건이
/// 답의 cluster를 훑어도 1,966건이 남았다. **칸을 소유한 cluster로 가르자 0건**이 됐다.
///
/// **그래도 §3.8 판정력은 남는다**: 표기 앞뒤의 정상 글자 칸은 그대로 비교되므로, 표기가 만든 열
/// 어긋남이 이웃에 드러나면 잡힌다(실측으로 뮤턴트 여덟을 잡는다).
fn advCellIsUnmappable(line: []const u8, row: chrome_editor.visual_map.VisualRow, screen_col: u16, content_left: u16) bool {
    const abs_col: u32 = row.start_col + (screen_col - content_left);
    var i: usize = @min(row.start_byte, line.len);
    var col: u32 = row.start_byte_col;
    while (i < line.len) {
        const st = chrome_editor.content.stepColumn(line, i, col, chrome_editor.frame.default_tab_width);
        if (st.next_col > abs_col) {
            if (line[i] == '\t') return true;
            const end = @min(
                maru.chrome.text_layout.clusterEndAfter(line, i, maru.chrome.text_layout.decodeCodepoint(line, i).advance),
                line.len,
            );
            var scan = i;
            while (scan < end) {
                if (maru.hazard.classifyInText(line, scan) != null) return true;
                const seq = std.unicode.utf8ByteSequenceLength(line[scan]) catch 1;
                scan += @max(1, @min(seq, end - scan));
            }
            return false;
        }
        i = st.next_byte;
        col = st.next_col;
    }
    return false;
}

/// 행마다 gutter가 실제로 그린 줄 번호(1-based). 이어진 조각은 `null`.
/// 판정자가 쓰는 **본문 시작 열**. 숫자를 손으로 적으면(`= 8`) `geometry`의 셀 배분이 바뀔 때마다
/// 네 자리가 조용히 낡는다 — 실제로 접기 칸이 1→2셀이 되면서 그 넷이 한꺼번에 어긋났다(2026-08-22).
/// **렌더가 굳힌 값에서 되읽는다**: 그것이 그 프레임이 실제로 그린 자리이므로, 판정자가 다시 계산해
/// 갈릴 여지가 없다(§4.1g "스냅숏의 경계"와 같은 규율).
fn advContentLeft(term: *Term) u16 {
    const g = term.rt.editor_hit_geom;
    if (g.cell_w_px == 0) return 0;
    return @intCast(g.content_left_px / g.cell_w_px);
}

fn advGutterNumbers(dl: renderer.DrawList, content_left: u16, out: []?u32) void {
    for (out) |*o| o.* = null;
    for (dl.cells) |c| {
        if (c.col >= content_left) continue;
        if (c.codepoint < '0' or c.codepoint > '9') continue;
        if (c.row >= out.len) continue;
        const d: u32 = @intCast(c.codepoint - '0');
        out[c.row] = if (out[c.row]) |v| v * 10 + d else d;
    }
}

test "ADV3-A 그려진 글자가 곧 클릭이 답한 글자다 (랩이 실제로 걸린 문서)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **본문 폭(89열)보다 훨씬 긴 줄**을 만들어 랩이 실제로 걸리게 한다.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(0xAD3);
    const rand = prng.random();
    // **§3.8 문자와 cluster 안 hazard를 넣는다**(§4.1g가 *"알파벳은 §3.8 문자 포함"*이라 이름을
    // 대어 요구한 규율). 5차 적대적 검증이 이 누락 때문에 결함 셋이 살아남았다고 짚었다 — 특히
    // `ad<ZWJ>min`처럼 **첫 codepoint가 정상이고 뒤에 hazard가 붙은 cluster**가 없으면, 걸친 것을
    // 자를지 버릴지 가르는 판정이 틀려도 아무도 못 잡는다.
    const units = [_][]const u8{ "a", "b", "Z", "7", "가", "힣", "\u{202E}", "ad\u{200D}min" };
    for (0..30) |_| {
        for (0..120 + rand.uintLessThan(usize, 120)) |_| try text.appendSlice(allocator, units[rand.uintLessThan(usize, units.len)]);
        try text.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "adv3a.txt", .data = text.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "adv3a.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var checked: usize = 0;
    var mismatch: usize = 0;
    var line_mismatch: usize = 0;
    var wrapped_rows: usize = 0;
    var first_bad: ?struct { row: usize, col: u16, want: u21, got: u21 } = null;

    for ([_]struct { wrap: bool, first: usize }{
        .{ .wrap = true, .first = 0 },
        .{ .wrap = true, .first = 3 },
        .{ .wrap = false, .first = 2 },
    }) |cfg| {
        term.rt.editor_wrap = cfg.wrap;
        term.rt.editor_first_line = cfg.first;
        term.rt.editor_first_piece = 0;
        term.rt.editor_row_cache.filled = false;
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse continue;
        defer drawn.dl.deinit(allocator);
        const rows = term.rt.editor_hit_rows_len;
        if (rows == 0) continue;

        const cw: f64 = @floatFromInt(fx.session.cell_width_px);
        const ch: f64 = @floatFromInt(fx.session.cell_height_px);
        const ox: f64 = @floatFromInt(drawn.rect.x);
        const oy: f64 = @floatFromInt(drawn.rect.y);

        // 오라클 ①: gutter가 그린 번호 → 그 행의 원본 줄(이어진 조각은 위에서 물려받는다).
        var nums_buf: [512]?u32 = undefined;
        const content_left: u16 = advContentLeft(term); // gutter 폭 — 렌더가 굳힌 값에서 되읽는다
        advGutterNumbers(drawn.dl, content_left, nums_buf[0..rows]);
        var carry: ?u32 = null;
        var line_of_row: [512]?u32 = undefined;
        for (0..rows) |r| {
            if (nums_buf[r]) |n| carry = n else wrapped_rows += 1;
            line_of_row[r] = carry;
        }

        for (drawn.dl.cells) |c| {
            if (c.col < content_left) continue;
            if (c.row >= rows) continue;
            const x = ox + @as(f64, @floatFromInt(c.col)) * cw + 1;
            const y = oy + @as(f64, @floatFromInt(c.row)) * ch + 1;
            const off = hitTestBody(term, x, y) orelse continue;

            // 오라클 ②: 그 offset이 gutter가 말한 줄 안에 있는가.
            const want_line = line_of_row[c.row] orelse continue;
            const doc = term.rt.editor_doc.?;
            const li = doc.file.lines.line(want_line - 1) orelse continue;
            if (off < li.start or off > li.contentEnd()) {
                line_mismatch += 1;
                continue;
            }

            // 오라클 ③: 그 자리에 **그려진 글자**가 곧 그 offset의 글자인가.
            const lt = term.rt.editor_lines[want_line - 1];
            const rel = off - li.start;
            if (rel >= lt.len) continue; // 줄 끝 — 그릴 글자가 없다
            const seq_len = std.unicode.utf8ByteSequenceLength(lt[rel]) catch continue;
            if (rel + seq_len > lt.len) continue;
            const cp = std.unicode.utf8Decode(lt[rel .. rel + seq_len]) catch continue;
            if (advCellIsUnmappable(lt, term.rt.editor_hit_rows[c.row], c.col, content_left)) continue;
            checked += 1;
            if (cp != c.codepoint) {
                mismatch += 1;
                if (first_bad == null) first_bad = .{ .row = c.row, .col = c.col, .want = c.codepoint, .got = cp };
            }
        }
    }

    std.debug.print("\n[ADV3-A] checked={d} glyph_mismatch={d} line_mismatch={d} wrapped_rows={d}\n", .{ checked, mismatch, line_mismatch, wrapped_rows });
    if (first_bad) |b| std.debug.print("[ADV3-A] 첫 불일치: row={d} col={d} 그린 글자=U+{X} 클릭이 답한 글자=U+{X}\n", .{ b.row, b.col, b.want, b.got });
    try testing.expect(checked > 1000); // 판정이 실제로 돌았는가
    try testing.expect(wrapped_rows > 10); // 랩이 실제로 걸렸는가
    try testing.expectEqual(@as(usize, 0), line_mismatch);
    try testing.expectEqual(@as(usize, 0), mismatch);
}

test "ADV3-B 접힘을 켜도 클릭이 gutter가 그린 줄을 답한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..60) |i| {
        var lb: [64]u8 = undefined;
        try text.appendSlice(allocator, try std.fmt.bufPrint(&lb, "head{d}\n", .{i}));
        for (0..4) |j| try text.appendSlice(allocator, try std.fmt.bufPrint(&lb, "    body{d}_{d}\n", .{ i, j }));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "adv3b.txt", .data = text.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "adv3b.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try testing.expect(foldAll(fx.session));
    try testing.expect(term.rt.editor_visible_numbers.len > 0);
    term.rt.editor_first_line = 11; // 접힌 상태에서 스크롤까지 섞는다

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
    defer drawn.dl.deinit(allocator);
    const rows = term.rt.editor_hit_rows_len;
    try testing.expect(rows > 3);

    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    const ox: f64 = @floatFromInt(drawn.rect.x);
    const oy: f64 = @floatFromInt(drawn.rect.y);
    const content_left: u16 = advContentLeft(term); // gutter 폭 — 렌더가 굳힌 값에서 되읽는다

    var nums_buf: [512]?u32 = undefined;
    advGutterNumbers(drawn.dl, content_left, nums_buf[0..rows]);

    var bad: usize = 0;
    var judged: usize = 0;
    for (0..rows) |r| {
        const want = nums_buf[r] orelse continue;
        const x = ox + @as(f64, @floatFromInt(content_left)) * cw + 1;
        const y = oy + @as(f64, @floatFromInt(r)) * ch + 1;
        const off = hitTestBody(term, x, y) orelse {
            bad += 1;
            continue;
        };
        const doc = term.rt.editor_doc.?;
        const li = doc.file.lines.line(want - 1).?;
        judged += 1;
        if (off != li.start) {
            bad += 1;
            std.debug.print("[ADV3-B] row={d} gutter가 그린 줄={d} 기대 offset={d} 실제={d} (hit_lines={d})\n", .{ r, want, li.start, off, term.rt.editor_hit_lines[r] });
        }
    }
    std.debug.print("\n[ADV3-B] judged={d} bad={d} rows={d} first_line={d} visible={d}\n", .{ judged, bad, rows, term.rt.editor_first_line, term.rt.editor_visible_lines.len });
    try testing.expect(judged > 3);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "ADV3-C 랩된 행의 오른쪽 끝 너머는 그 행의 끝이다 (다음 조각 시작)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(0xC3);
    const rand = prng.random();
    // **§3.8 문자와 cluster 안 hazard를 넣는다**(§4.1g가 *"알파벳은 §3.8 문자 포함"*이라 이름을
    // 대어 요구한 규율). 5차 적대적 검증이 이 누락 때문에 결함 셋이 살아남았다고 짚었다 — 특히
    // `ad<ZWJ>min`처럼 **첫 codepoint가 정상이고 뒤에 hazard가 붙은 cluster**가 없으면, 걸친 것을
    // 자를지 버릴지 가르는 판정이 틀려도 아무도 못 잡는다.
    const units = [_][]const u8{ "a", "b", "Z", "7", "가", "힣", "\u{202E}", "ad\u{200D}min" };
    for (0..20) |_| {
        for (0..150 + rand.uintLessThan(usize, 100)) |_| try text.appendSlice(allocator, units[rand.uintLessThan(usize, units.len)]);
        try text.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "advc.txt", .data = text.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "advc.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    term.rt.editor_wrap = true;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
    defer drawn.dl.deinit(allocator);
    const rows = term.rt.editor_hit_rows_len;

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    const oy: f64 = @floatFromInt(drawn.rect.y);
    // **본문 텍스트의 마지막 픽셀을 쏜다.** 초판은 `body.x + body.w - 1`(사각의 끝 = 막대 띠 위)이라
    // 자기 제목의 자리를 한 번도 안 눌렀고, 다음 판은 `bar.track_x`에서 만들어 **항진 구조**가 됐다
    // (막대 왼쪽이 수락되는지를 막대 좌표로 물으면 띠를 없애는 뮤턴트를 못 잡는다 — 9차 적대적 검증).
    // 여기서는 막대와 무관한 값으로 만든다: 본문 왼쪽 + 본문 폭.
    const right: f64 = blk: {
        const inset = chrome_editor.frame.content_inset_px;
        const cw_i: u32 = @intCast(fx.session.cell_width_px);
        const m = chrome_editor.diff_frame.sideMetrics(
            body.w -| inset * 2,
            body.h -| inset * 2,
            @intCast(fx.session.cell_width_px),
            @intCast(fx.session.cell_height_px),
        );
        const lay = chrome_editor.geometry.compute(m.total_cols, term.rt.editor_lines.len, .{});
        const text_right: u32 = (@as(u32, lay.contentLeft()) + lay.content.width) * cw_i;
        break :blk @as(f64, @floatFromInt(body.x + @as(i32, @intCast(inset)))) + @as(f64, @floatFromInt(text_right)) - 1;
    };

    var judged: usize = 0;
    var bad: usize = 0;
    for (0..rows -| 1) |r| {
        const a = term.rt.editor_hit_rows[r];
        const b = term.rt.editor_hit_rows[r + 1];
        if (b.piece != a.piece + 1) continue; // 같은 줄의 다음 조각만 본다
        if (term.rt.editor_hit_lines[r] != term.rt.editor_hit_lines[r + 1]) continue;
        const src = term.rt.editor_hit_lines[r];
        const li = term.rt.editor_doc.?.file.lines.line(src).?;
        // **오라클이 순환이다** — 기대값을 검증 대상 배열(`editor_hit_rows`)에서 만든다. §4.1g가
        // *"구현과 같은 식으로 좌표를 만들면 어긋남을 못 잡는다"*고 경고한 형태이고, 실제로 `build`와
        // `byteAtPoint`가 **함께 움직이는** 뮤턴트를 통과시킨다.
        //
        // **그래도 남긴다**: 이 판정이 보는 것("행 끝 너머는 다음 조각의 시작")은 독립 오라클인
        // ADV3-A와 [주 판정]이 각각 다른 각도로 함께 잡으므로 여기서 중복으로 걸린다. 지우면 그
        // 각도가 하나 줄고, 남겨도 거짓 통과를 만들지 않는다(7차 적대적 검증이 "이제 중복"이라 확인).
        const want = li.start + b.start_byte;
        const got = hitTestBody(term, right, oy + @as(f64, @floatFromInt(r)) * ch + 1) orelse {
            bad += 1;
            continue;
        };
        judged += 1;
        if (got != want) {
            bad += 1;
            if (bad <= 3) std.debug.print("[ADV3-C] row={d} 기대={d} 실제={d} (차이 {d}바이트)\n", .{ r, want, got, @as(i64, @intCast(got)) - @as(i64, @intCast(want)) });
        }
    }
    std.debug.print("\n[ADV3-C] judged={d} bad={d} rows={d}\n", .{ judged, bad, rows });
    try testing.expect(judged > 10);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "ADV3-D 탭 폭 단일 출처: 렌더와 hit-test가 같은 값을 따른다 (기본값이 아닌 폭으로 잰다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "advd.txt", .data = "\tXabcdef\n\t\tY\nZ\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "advd.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **기본값이 아닌 탭 폭으로 잰다.** 기본값(`4`)으로만 재면 렌더도 hit-test도 같은 comptime 상수를
    // 읽으므로 **하드코딩과 단일 출처 참조를 원리상 구분할 수 없다** — 실측으로 `tab_w`를 `4`로
    // 하드코딩한 뮤턴트를 판정자 열셋가 하나도 못 잡았다(11차 적대적 검증). 4가 아닌 값을 넣을 수
    // 있게 `editor_tab_width` 필드와 `buildPaneOps`의 인자를 그때 뚫었다.
    setEditorTabWidth(fx.session, term, 3); // 필드 직접 대입은 파생 캐시를 낡게 둔다(그 함수 doc)
    const tw: u16 = term.rt.editor_tab_width;
    try testing.expect(tw != chrome_editor.frame.default_tab_width); // 이 테스트의 전제

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
    defer drawn.dl.deinit(allocator);

    const content_left: u16 = advContentLeft(term); // gutter 폭 — 렌더가 굳힌 값에서 되읽는다
    const cw: f64 = @floatFromInt(fx.session.cell_width_px);
    const ch: f64 = @floatFromInt(fx.session.cell_height_px);
    const ox: f64 = @floatFromInt(drawn.rect.x);
    const oy: f64 = @floatFromInt(drawn.rect.y);

    var x_col: ?u16 = null;
    var y_col: ?u16 = null;
    for (drawn.dl.cells) |c| {
        if (c.codepoint == 'X' and c.row == 0) x_col = c.col;
        if (c.codepoint == 'Y' and c.row == 1) y_col = c.col;
    }
    const xc = x_col orelse return error.NoX;
    const yc = y_col orelse return error.NoY;
    std.debug.print("\n[ADV3-D] tab_width={d} 렌더가 그린 X열={d}(본문 {d}) Y열={d}(본문 {d})\n", .{ tw, xc, xc - content_left, yc, yc - content_left });
    // 렌더가 상수를 따르는가.
    try testing.expectEqual(tw, xc - content_left);
    try testing.expectEqual(tw * 2, yc - content_left);
    // hit-test가 **같은** 값을 따르는가: 그 자리를 누르면 탭 다음 byte(=1, =2)다.
    try testing.expectEqual(@as(?usize, 1), hitTestBody(term, ox + @as(f64, @floatFromInt(xc)) * cw + 1, oy + 1));
    try testing.expectEqual(@as(?usize, 11), hitTestBody(term, ox + @as(f64, @floatFromInt(yc)) * cw + 1, oy + ch + 1)); // 둘째 줄 시작(9) + 2

    // **탭에서 떨어진 자리도 누른다 — 안 그러면 위 둘이 폭을 못 가른다.** 실측: 탭 **바로 뒤**
    // 좌표는 폭 3과 4가 **같은 답**을 낸다(탭이 넓어지면 그 자리가 탭 안쪽 마지막 칸이 되는데,
    // 중점을 넘었으므로 역시 탭 다음 byte로 간다). 그래서 `editor_tab_width` 배선을 뚫고 이 테스트를
    // 폭 3으로 돌린 **뒤에도** `tab_w`를 `4`로 하드코딩한 뮤턴트가 통과했다 — 배선만으로는 부족했다.
    // 탭에서 세 칸 떨어지면 갈린다(그 뮤턴트가 여기서 `expected 4, found 3`으로 잡힌다):
    //   tab_w=3 → `\t`(0‥2) `X`=3 `a`=4 `b`=5 **`c`=6** → byte 4
    //   tab_w=4 → `\t`(0‥3) `X`=4 `a`=5 **`b`=6** → byte 3
    // 렌더와 hit-test가 같은 값을 따르면 답은 폭과 **무관하게** 4다(`X`·`a`·`b`를 지난 자리이므로).
    const far_col: f64 = @floatFromInt(content_left + tw + 3);
    try testing.expectEqual(@as(?usize, 4), hitTestBody(term, ox + far_col * cw + 1, oy + 1));
}

test "ADV3-E 가로 스크롤 + 탭: 그려진 글자 = 클릭이 답한 글자" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(0xE3);
    const rand = prng.random();
    // §3.8 문자를 함께 넣는다 — 탭과 같은 "잘라 그리는" 갈래이고, cluster 안 hazard까지 덮는다.
    const units = [_][]const u8{ "a", "b", "\t", "가", "Z", "\t", "\u{202E}", "ad\u{200D}min" };
    for (0..25) |_| {
        for (0..80 + rand.uintLessThan(usize, 60)) |_| try text.appendSlice(allocator, units[rand.uintLessThan(usize, units.len)]);
        try text.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "adve.txt", .data = text.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "adve.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var checked: usize = 0;
    var mismatch: usize = 0;
    var first_bad: ?struct { col: u16, want: u21, got: u21, fc: u16 } = null;

    for ([_]u16{ 0, 7, 33, 60 }) |fc| {
        term.rt.editor_wrap = false;
        term.rt.editor_first_col = fc;
        term.rt.editor_first_line = 0;
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse continue;
        defer drawn.dl.deinit(allocator);
        const rows = term.rt.editor_hit_rows_len;
        if (rows == 0) continue;
        const eff = term.rt.editor_first_col;

        const cw: f64 = @floatFromInt(fx.session.cell_width_px);
        const ch: f64 = @floatFromInt(fx.session.cell_height_px);
        const ox: f64 = @floatFromInt(drawn.rect.x);
        const oy: f64 = @floatFromInt(drawn.rect.y);
        const content_left: u16 = advContentLeft(term); // gutter 폭 — 렌더가 굳힌 값에서 되읽는다

        var nums_buf: [512]?u32 = undefined;
        advGutterNumbers(drawn.dl, content_left, nums_buf[0..rows]);

        for (drawn.dl.cells) |c| {
            if (c.col < content_left or c.row >= rows) continue;
            if (c.codepoint == ' ') continue; // 탭이 편 공백 — 원본 글자와 대조할 수 없다
            const want_line = nums_buf[c.row] orelse continue;
            const off = hitTestBody(term, ox + @as(f64, @floatFromInt(c.col)) * cw + 1, oy + @as(f64, @floatFromInt(c.row)) * ch + 1) orelse continue;
            const li = term.rt.editor_doc.?.file.lines.line(want_line - 1) orelse continue;
            const lt = term.rt.editor_lines[want_line - 1];
            if (off < li.start or off > li.contentEnd()) {
                mismatch += 1;
                continue;
            }
            const rel = off - li.start;
            if (rel >= lt.len) continue;
            const n = std.unicode.utf8ByteSequenceLength(lt[rel]) catch continue;
            if (rel + n > lt.len) continue;
            const cp = std.unicode.utf8Decode(lt[rel .. rel + n]) catch continue;

            if (advCellIsUnmappable(lt, term.rt.editor_hit_rows[c.row], c.col, content_left)) continue;

            checked += 1;
            if (cp != c.codepoint) {
                mismatch += 1;
                if (first_bad == null) first_bad = .{ .col = c.col, .want = c.codepoint, .got = cp, .fc = eff };
            }
        }
        std.debug.print("[ADV3-E] first_col 요청={d} 실제={d} rows={d}\n", .{ fc, eff, rows });
    }
    std.debug.print("[ADV3-E] checked={d} mismatch={d}\n", .{ checked, mismatch });
    try testing.expect(checked > 500);
    if (first_bad) |b| std.debug.print("[ADV3-E] 첫 불일치: first_col={d} col={d} 그린 글자=U+{X} 클릭이 답한 글자=U+{X}\n", .{ b.fc, b.col, b.want, b.got });
    try testing.expectEqual(@as(usize, 0), mismatch);
}

test "[주 판정] cluster 경계 · 단조성 · 행 경계 부등식 (§4.1g)" {
    // **§4.1g가 이름을 대어 요구한 셋이다.** 앞선 판정들(ADV3-*)은 "그린 글자 == 답한 글자"를 보는데,
    // 그것만으로는 **오른쪽 경계 규칙**이 안 보인다 — 7차 적대적 검증이 그 공백에서 뮤턴트 하나(잔여분
    // 중점을 오른쪽에도 적용)가 전 스위트를 통과하는 것을 실측했다. 그 뮤턴트는 답을 뒤로 보냈다가
    // 다시 앞으로 오게 만들어 **단조성**을 깬다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(0x7A11);
    const rand = prng.random();
    const units = [_][]const u8{ "a", "b", "Z", "가", "힣", "\t", "\u{202E}", "ad\u{200D}min", " " };
    for (0..40) |_| {
        for (0..80 + rand.uintLessThan(usize, 120)) |_| try text.appendSlice(allocator, units[rand.uintLessThan(usize, units.len)]);
        try text.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "main.txt", .data = text.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "main.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var judged: usize = 0;
    var rule3: usize = 0;
    for ([_]struct { wrap: bool, first: usize }{
        .{ .wrap = true, .first = 0 },
        .{ .wrap = true, .first = 4 },
        .{ .wrap = false, .first = 0 },
    }) |cfg| {
        term.rt.editor_wrap = cfg.wrap;
        term.rt.editor_first_line = @min(cfg.first, term.rt.editor_lines.len -| 1);
        term.rt.editor_row_cache.filled = false;
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse continue;
        defer drawn.dl.deinit(allocator);
        const rows = term.rt.editor_hit_rows_len;
        if (rows == 0) continue;

        const body_outer = editorBodyRect(fx.session, fx.leaf_rect, term);
        const inset = chrome_editor.frame.content_inset_px;
        const ox: f64 = @floatFromInt(body_outer.x + @as(i32, @intCast(inset)));
        const oy: f64 = @floatFromInt(body_outer.y + @as(i32, @intCast(inset)));
        const bw: f64 = @floatFromInt(body_outer.w -| inset * 2);
        const ch: f64 = @floatFromInt(fx.session.cell_height_px);

        var prev_right: ?usize = null;
        var prev_line: ?u32 = null;
        for (0..rows) |r| {
            const y = oy + @as(f64, @floatFromInt(r)) * ch + 1;
            const src = term.rt.editor_hit_lines[r];
            if (src >= term.rt.editor_lines.len) continue;
            const lt = term.rt.editor_lines[src];
            const li = term.rt.editor_doc.?.file.lines.line(src) orelse continue;

            var last: ?usize = null;
            var first: ?usize = null;
            var x: f64 = ox + 1;
            while (x < ox + bw) : (x += 3) {
                const off = hitTestBody(term, x, y) orelse continue;
                judged += 1;

                // ⑴ **cluster 경계이고 줄 범위 안.**
                //
                // **줄 머리에서 걸어 도달하는 자리인지 본다.** 초판은 답에서 줄 끝까지 걸어
                // `walk == len`을 요구했는데 그것은 **항진명제**였다 — `stepColumn`은 늘 1 이상
                // 전진하고 `next_byte`를 `@min(…, len)`으로 묶으므로 **어떤 시작점에서도** 끝에
                // 닿는다. 실측으로 시작점 20개 중 9개가 진짜 경계가 아닌데 걸러낸 것이 0개였고,
                // "답을 1바이트 민다"(UTF-8 연속 바이트를 답한다)는 뮤턴트가 통과했다(8차 검증).
                try testing.expect(off >= li.start and off <= li.contentEnd());
                const target = off - li.start;
                var reachable = target == 0;
                var walk: usize = 0;
                var wcol: u32 = 0;
                while (walk < lt.len and walk < target) {
                    const st = chrome_editor.content.stepColumn(lt, walk, wcol, chrome_editor.frame.default_tab_width);
                    walk = st.next_byte;
                    wcol = st.next_col;
                    if (walk == target) reachable = true;
                }
                try testing.expect(reachable);

                // ⑵ **한 행 안에서 x가 커지면 offset이 줄지 않는다.**
                if (last) |l| try testing.expect(off >= l);
                if (first == null) first = off;
                last = off;
            }

            // ⑶ **행 경계 부등식** — 같은 논리 줄의 이어진 두 행에서 앞 행의 끝 ≤ 뒤 행의 시작.
            if (prev_right) |pr| {
                if (prev_line != null and prev_line.? == src) {
                    rule3 += 1;
                    try testing.expect(pr <= (first orelse pr));
                }
            }
            prev_right = last;
            prev_line = src;
        }
    }
    std.debug.print("\n[주 판정] judged={d} 행경계판정={d}\n", .{ judged, rule3 });
    try testing.expect(judged > 5_000);
    try testing.expect(rule3 > 0); // 랩이 실제로 걸렸다 — 셋째 규칙이 죽어 있지 않다
}

test "비교 뷰는 hit-test가 받지 않고, 행도 담지 않는다 (§4.1g 결정표)" {
    // **양쪽 다 판정자가 없었다**(8차 적대적 검증): `hitTestBody`의 diff 거절을 지워도, `storeHitRows`의
    // diff 건너뛰기를 지워도 전 스위트가 통과했다. 게다가 전자의 주석이 후자를 정당화하는 근거였다 —
    // 논거도 결론도 아무도 안 지키는 상태였다.
    //
    // 계약 결정표: *"비교(diff) 뷰 → 이 슬라이스는 다루지 않는다"*(좌우가 `split_x`로 갈리고 어느
    // 쪽인지부터 정해야 한다). 그리고 비교 경로의 `visual_rows`는 좌우 열이 섞인 배열이라 담아 두면
    // 뒷날 조용히 틀린 값을 내는 지뢰가 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "alpha\nbeta\ngamma\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "d.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // 먼저 일반 Term으로 그려 행을 담는다 — 그 상태에서 클릭이 된다.
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len > 0);
    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset = chrome_editor.frame.content_inset_px;
    const probe_x: f64 = @as(f64, @floatFromInt(body.x + @as(i32, @intCast(inset)))) + 200;
    const probe_y: f64 = @as(f64, @floatFromInt(body.y + @as(i32, @intCast(inset)))) + 1;
    try testing.expect(hitTestBody(term, probe_x, probe_y) != null);

    // **비교 상태가 되면 받지 않는다.**
    term.rt.editor_diff = .{ .requested_ms = 0 };
    defer term.rt.editor_diff = null;
    try testing.expectEqual(@as(?usize, null), hitTestBody(term, probe_x, probe_y));

    // **그 상태로 그려도 행을 담지 않는다** — 담기면 길이가 갱신된다.
    term.rt.editor_hit_rows_len = 0;
    if (appendPaneFrame(fx.session, fx.leaf_rect, term)) |*d2| {
        var d = d2.*;
        d.dl.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 0), term.rt.editor_hit_rows_len);
}

test "ADV3-F 셀 크기도 스냅숏이다 — 폰트가 바뀌고 아직 안 그린 창에서 답이 안 흔들린다 (§4.1g)" {
    // **원점·폭만 굳히고 셀 크기를 live로 두면 한 표현식 안에서 두 프레임이 섞인다**(11차 적대적
    // 검증). 8×16으로 그린 뒤 폰트가 12×24로 바뀌고 아직 다시 안 그린 창에서 본문 격자 64발 중
    // **60발(93%)**이 정합 상태와 달랐고 **59발(92%)**이 화면에 실제로 보이는 것과도 달랐다 —
    // 어느 쪽 기준으로도 틀린 답이다. 노출 창은 리사이즈와 같은 폭이고, 그 폭이 `editor_hit_geom`을
    // 만든 근거였다.
    //
    // 이 테스트가 지키는 것: `hitTestBody`가 `self.cell_*_px`를 읽지 않는다. 읽으면 아래 두 번째
    // 걸음에서 답이 달라진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **긴 줄이 필요하다** — 짧으면 어느 셀 폭으로 읽어도 답이 줄 끝으로 몰려 차이가 안 난다.
    var doc_buf: std.ArrayList(u8) = .empty;
    defer doc_buf.deinit(allocator);
    for (0..40) |i| {
        for (0..200) |j| try doc_buf.append(allocator, @intCast('a' + (i + j) % 26));
        try doc_buf.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "wide.txt", .data = doc_buf.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "wide.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len > 0);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    try testing.expectEqual(fx.session.cell_width_px, @as(u32, geom.cell_w_px));
    try testing.expectEqual(fx.session.cell_height_px, @as(u32, geom.cell_h_px));

    // 본문 격자 8×8발. 굳은 기하로 자리를 잡는다 — 클릭이 실제로 오는 좌표계다.
    var probes: [64][2]f64 = undefined;
    var before: [64]?usize = undefined;
    var n: usize = 0;
    for (0..8) |gy| {
        for (0..8) |gx| {
            const px: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset +
                @as(i32, @intCast(geom.content_left_px)) + @as(i32, @intCast(gx * 7 * geom.cell_w_px)));
            const py: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset +
                @as(i32, @intCast(gy * 3 * geom.cell_h_px)));
            probes[n] = .{ px, py };
            before[n] = hitTestBody(term, px, py);
            n += 1;
        }
    }
    // 판정할 것이 실제로 있는가 — 답이 전부 같으면 아래 비교가 항진명제가 된다.
    var distinct: usize = 0;
    for (before[0..n]) |b| {
        if (b != null and b != before[0]) distinct += 1;
    }
    try testing.expect(distinct >= 32);

    // **폰트만 바꾸고 다시 안 그린다.** 실제로 이 창이 생기는 것은 폰트 크기 변경·디스플레이 전환이다.
    fx.session.cell_width_px = 12;
    fx.session.cell_height_px = 24;

    var moved: usize = 0;
    for (probes[0..n], before[0..n]) |p, b| {
        const after = hitTestBody(term, p[0], p[1]);
        if (after != b) moved += 1;
    }
    try testing.expectEqual(@as(usize, 0), moved);

    // **역방향도 확인한다 — 안 그러면 위 단언이 항진명제다.** "폰트를 바꿔도 답이 안 변한다"만으로는
    // 답이 셀 크기를 아예 안 본다는 뜻일 수도 있다. 굳은 값을 바꾸면 **반드시** 답이 흔들려야 한다.
    // (이 방향의 뮤턴트는 주입할 수 없다 — `hitTestBody`가 `AppSession`을 안 받으므로 live를 읽는
    //  코드를 쓸 수가 없다. 그 대신 굳은 값 자체를 흔들어 의존을 보인다.)
    // **축을 따로 흔든다.** 둘을 함께 흔들면 한쪽만 굳혀도 문턱을 넘는다 — 실측으로 폭만 ×2가
    // 56/64, 높이만 ×2가 56/64였다(12차 적대적 검증). 그러면 `cell_h_px`를 스냅숏에서 뺀 뮤턴트를
    // 못 잡는다.
    inline for (.{ "cell_w_px", "cell_h_px" }) |axis| {
        @field(term.rt.editor_hit_geom, axis) = @field(geom, axis) * 2;
        var shifted: usize = 0;
        for (probes[0..n], before[0..n]) |p, b| {
            if (hitTestBody(term, p[0], p[1]) != b) shifted += 1;
        }
        @field(term.rt.editor_hit_geom, axis) = @field(geom, axis);
        try testing.expect(shifted >= n / 2);
    }
}

test "ADV3-H 탭 폭도 스냅숏이다 — 프레임 사이에 설정이 바뀌어도 답이 안 흔들린다 (§4.1g)" {
    // **탭 폭 축에 판정자가 하나도 없었다**(12차 적대적 검증: `tab_w`를 `geom.tab_width` 대신
    // live `term.rt.editor_tab_width`로 읽는 뮤턴트가 **컴파일되고 판정자 15개를 전부 통과**했다).
    // `AppSession`을 인자에서 뺀 것은 그 축을 못 막는다 — `term.rt`는 통째로 live다.
    //
    // 탭 폭은 설정이 바뀌면 프레임 사이에 바뀌고, 그때 옛 행 배열 × 새 탭 폭이면 클릭이 화면과
    // 어긋난다(탭 폭이 곧 열 계산이다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 탭이 줄마다 있어야 폭이 답을 가른다.
    try fx.dir.dir.writeFile(io, .{ .sub_path = "tabs.txt", .data = "\tone\ttwo\tthree\n\t\tfour\tfive\n\tsix\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "tabs.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    term.rt.editor_tab_width = 4;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    const geom = term.rt.editor_hit_geom;
    try testing.expectEqual(@as(u8, 4), geom.tab_width);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    var probes: [24][2]f64 = undefined;
    var before: [24]?usize = undefined;
    var n: usize = 0;
    for (0..3) |row| {
        for (0..8) |k| {
            const px: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset +
                @as(i32, @intCast(geom.content_left_px)) + @as(i32, @intCast(k * 2 * geom.cell_w_px)));
            const py: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset +
                @as(i32, @intCast(row * @as(usize, geom.cell_h_px))) + 1);
            probes[n] = .{ px, py };
            before[n] = hitTestBody(term, px, py);
            n += 1;
        }
    }
    var distinct: usize = 0;
    for (before[0..n]) |b| {
        if (b != null and b != before[0]) distinct += 1;
    }
    try testing.expect(distinct >= 8); // 판정할 것이 실제로 있다

    // **설정만 바꾸고 다시 안 그린다.**
    term.rt.editor_tab_width = 8;
    var moved: usize = 0;
    for (probes[0..n], before[0..n]) |p, b| {
        if (hitTestBody(term, p[0], p[1]) != b) moved += 1;
    }
    try testing.expectEqual(@as(usize, 0), moved);

    // 역방향 — 굳은 값을 흔들면 반드시 답이 흔들린다(안 그러면 위가 항진명제다).
    term.rt.editor_hit_geom.tab_width = 8;
    var shifted: usize = 0;
    for (probes[0..n], before[0..n]) |p, b| {
        if (hitTestBody(term, p[0], p[1]) != b) shifted += 1;
    }
    term.rt.editor_hit_geom.tab_width = geom.tab_width;
    try testing.expect(shifted >= n / 3);
}

test "ADV3-G 번호 표가 행보다 짧으면 그 행의 클릭은 답하지 않는다 (§4.1g ③)" {
    // **`source_line >= editor_lines.len` 가드에 판정자가 없었다**(11차 적대적 검증: `>=`를 `>`로
    // 바꾼 뮤턴트를 판정자 열셋가 하나도 못 잡았다). 그 가드는 `storeHitRows`의
    // `else source = doc_lines;`와 짝이다 — 번호 표가 보이는 줄 수보다 짧으면 그 행은 원본 줄을
    // 모르고, 모르는 채로 답하면 **엉뚱한 줄이 선택된다**. 죽은 코드가 아니라 무판정이었다.
    //
    // **그 뮤턴트는 범위 밖 읽기라 판정이 불안정하다.** `>`로 완화하면 `editor_lines[len]`을 읽는다.
    // 12차 실측은 그것이 이 테스트 자리에서 **결정적으로 panic**한다고 보고했지만, 11차 실행에서는
    // **릭·세그폴트가 실행마다 다른 자리에서** 났다(477번 테스트, 다음 실행은 1028번 — 둘 다 편집기와
    // 무관하다). 어느 쪽이든 그 뮤턴트로는 "이 가드가 무엇을 지키는가"를 안정적으로 못 잰다.
    // 그래서 이 테스트가 재는 것은 그쪽이 아니라 `storeHitRows`가 모르는 자리를 **엉뚱한 줄로
    // 답하는** 쪽이다(`else source = 0`) — 범위 안에 머물면서 계약만 어기므로 판정이 성립한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "n.txt", .data = "one\ntwo\nthree\nfour\nfive\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "n.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len >= 3);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    const px: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset +
        @as(i32, @intCast(geom.content_left_px)) + 1);
    const py: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset +
        @as(i32, @intCast(2 * @as(u32, geom.cell_h_px))) + 1);

    // 평상시엔 답한다.
    try testing.expect(hitTestBody(term, px, py) != null);

    // **표가 첫 줄만 덮게 만든다.** 셋째 행은 표 밖이라 `storeHitRows`가 `doc_lines`를 세우고,
    // `hitTestBody`의 가드가 그것을 받아 `null`을 낸다.
    var numbers = try allocator.alloc(?u32, 1);
    numbers[0] = 1;
    const saved = term.rt.editor_visible_numbers;
    term.rt.editor_visible_numbers = numbers;
    defer {
        term.rt.editor_visible_numbers = saved;
        allocator.free(numbers);
    }

    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    d2.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len >= 3);
    try testing.expectEqual(@as(?usize, null), hitTestBody(term, px, py));

    // 표 안에 있는 첫 행은 여전히 답한다 — 가드가 전부를 막는 것이 아니다.
    const py0: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset + 1);
    try testing.expect(hitTestBody(term, px, py0) != null);
}

// TAB1: **config가 실제로 편집기에 닿는가.** ADV3-I는 세터를 **직접** 부르는 경로만 재고, 그
// 세터는 배선 전까지 제품 호출자가 0개였다 — 함수가 옳아도 호출부가 틀리면 아무 일도 안 난다.
//
// **그래서 이 판정자는 세터도 `applyConfigTabWidth`도 직접 부르지 않는다.** 첫 판은 그것을 직접
// 불러서, 배선 두 줄(`applyLoadedConfig`·`reloadConfig`의 호출)을 지워도 전부 초록이었다 — 비판한
// 실수를 한 층 위에서 반복한 것이다(적대적 검증 2026-08-23). 지금은 **제품 진입점만** 탄다.
test "TAB1: config의 탭 폭이 문서를 열 때와 재적용 때 편집기에 닿는다 (§9)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 픽스처는 **탭 두 개짜리 줄**을 든다 — `max_cols`는 모든 줄의 최대라 그 줄이 값을 정한다.
    // 탭 폭 8이면 `\t\tdef` = 16+3 = **19**, 4면 8+3 = **11**. 첫 판은 하한을 11로 잡아
    // **탭 폭 4에서도 통과**했다(첫 줄만 계산한 착오다).
    try fx.dir.dir.writeFile(io, .{ .sub_path = "t.txt", .data = "\tabc\n\t\tdef\n" });
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const root = rb[0..try fx.dir.dir.realPath(io, &rb)];
    const path = try std.fs.path.join(allocator, &.{ root, "t.txt" });
    defer allocator.free(path);

    // ⑴ **여는 시점에 config를 따른다** — 필드와 파생값 둘 다.
    fx.session.loaded_config.config.editor.tab_width = 8;
    const term = try openPathInActivePane(fx.session, path);
    try testing.expectEqual(@as(u8, 8), term.rt.editor_tab_width);
    try testing.expectEqual(@as(u32, 19), term.rt.editor_max_cols); // 정확히 잰다 — 하한이 아니다

    // ⑵ **세팅 GUI 재적용 경로**(`applyLoadedConfig`)가 닿는가. **그 함수를 부른다** —
    //    `applyConfigTabWidth`를 직접 부르면 배선이 지워져도 통과한다.
    fx.session.loaded_config.config.editor.tab_width = 4;
    settings_ops.applyLoadedConfig(fx.session, true);
    try testing.expectEqual(@as(u8, 4), term.rt.editor_tab_width);
    // **파생값이 다시 섰는가.** 세터는 버리기만 하므로 재계산 짝이 없으면 여기가 0이고,
    // 그러면 가로 막대가 사라져 본문 높이가 출렁인다(`ensureMaxCols` doc).
    try testing.expectEqual(@as(u32, 11), term.rt.editor_max_cols);

    // ⑶ **접어 둔 상태를 지킨다** — 값이 같으면 세터를 안 탄다. 첫 판은 접힘 **개수**를 봤는데
    //    세터가 `dropFoldState` 직후 다시 세우므로 개수는 어차피 같다(ADV3-I 주석이 그 사실을
    //    적어 뒀다). 실제로 지켜야 하는 것은 **접힌 상태**다.
    _ = ensureFoldRanges(fx.session, term) catch {};
    if (applyFold(fx.session, 1)) {
        const folded_before = term.rt.editor_folded_len;
        try testing.expect(folded_before > 0); // 전제: 실제로 접혔다
        settings_ops.applyLoadedConfig(fx.session, true); // 값이 같다 → 건너뛰어야 한다
        try testing.expectEqual(folded_before, term.rt.editor_folded_len);
    }

    // ⑷ **파일 재로드 경로**(`reloadConfig`)도 닿는가. 이 경로는 config 파일을 **실제로 읽으므로**
    //    환경을 켜서 탄다 — `MARU_CONFIG`가 기본 경로를 이긴다(`loader.defaultConfigPath`).
    //
    //    **프로브 함수로 흉내 내지 않는다.** 처음에 `applyConfigTabWidth`를 부르는 헬퍼를 만들었다가
    //    지웠다: 그것은 **직접 호출과 같아서** 배선이 지워져도 초록이다. 같은 저장소의
    //    `MARU_NATIVE_DIFF` 판정자가 정확히 그 이유로 환경을 실제로 켠다 — 그 주석이 *"끈 상태로
    //    비교하면 양쪽 다 false라 아무것도 증명하지 못한다"*고 적었다.
    {
        try fx.dir.dir.writeFile(io, .{ .sub_path = "cfg.toml", .data = "editor.tab-width = 8\n" });
        const cfg = try std.fs.path.join(allocator, &.{ root, "cfg.toml" });
        defer allocator.free(cfg);
        const cfg_z = try allocator.dupeZ(u8, cfg);
        defer allocator.free(cfg_z);

        const had = std.c.getenv("MARU_CONFIG");
        defer if (had) |old| {
            _ = setenv("MARU_CONFIG", old, 1);
        } else {
            _ = unsetenv("MARU_CONFIG");
        };
        _ = setenv("MARU_CONFIG", cfg_z.ptr, 1);

        // 지금 값은 4다(⑵에서 그렇게 뒀다) — 8로 바뀌어야 재로드가 닿은 것이다.
        try testing.expectEqual(@as(u8, 4), term.rt.editor_tab_width);
        settings_ops.reloadConfig(fx.session);
        try testing.expectEqual(@as(u8, 8), term.rt.editor_tab_width);
        try testing.expectEqual(@as(u32, 19), term.rt.editor_max_cols); // 파생값도 다시 섰다
    }
}

test "ADV3-I 탭 폭 파생값 셋이 같은 값을 따르고, 바뀌면 낡지 않는다 (§4.1a·§4.1f)" {
    // **12차가 고친 자리 셋에 판정자가 하나도 없었다**(13차 적대적 검증: `ensureMaxCols`·
    // `piecesOfLine`·`ensureFoldRanges`를 상수 읽기로 되돌린 뮤턴트 셋이 editor 테스트 153개를
    // **전부 통과**했다). 그래서 11차가 배선을 뚫고도 세 자리를 놓쳤고, 12차가 고친 뒤에도
    // **무효화 지점이 없어 같은 8열(28.6%) 부족이 낡은 캐시로 재현됐다.**
    //
    // 이 테스트는 둘을 함께 잰다: ⑴ 파생값이 상수가 아니라 필드를 따르는가 ⑵ 필드가 바뀌면 파생값이
    // 다시 서는가(`setEditorTabWidth`).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // **탭과 스페이스를 섞는다.** 순수 탭·순수 스페이스 문서는 겹수가 탭 폭에 대해 **단조 스케일**이라
    // 4↔8에서 접힘 범위가 안 갈린다 — 14차 적대적 검증이 문서 6개를 재어 **갈린 것은 혼합 하나뿐**임을
    // 보였고, 그때 이 테스트가 쓰던 순수 탭 문서도 안 갈렸다(그래서 ⑶이 항진명제였다). 섞으면 탭 하나가
    // 스페이스 넷과 같아지는지 여덟과 같아지는지에 따라 층이 재배열된다.
    const doc =
        "root\n" ++
        "\tlevel_a\n" ++ // 탭 하나 = 4열 또는 8열
        "    spaces4\n" ++ // 스페이스 넷 = 늘 4열
        "\t    mixed\n" ++ // 탭+스페이스 = 8열 또는 12열
        "        spaces8\n" ++ // 스페이스 여덟 = 늘 8열
        "\t\tdeep\n" ++
        "end\n";
    try fx.dir.dir.writeFile(io, .{ .sub_path = "t.txt", .data = doc });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "t.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **탭 폭 4에서의 기준선.**
    setEditorTabWidth(fx.session, term, 4);
    ensureMaxCols(term, false);
    try ensureFoldRanges(fx.session, term);
    const cols4 = term.rt.editor_max_cols;
    const folds4 = term.rt.editor_fold_ranges.len;
    // 범위는 **복사해 둔다** — 세터가 그 배열을 놓으므로 포인터를 들고 있으면 dangling이다.
    const ranges4 = try allocator.dupe(editor_fold.Range, term.rt.editor_fold_ranges);
    defer allocator.free(ranges4);
    var pieces4: u32 = 0;
    for (0..editorLines(term).len) |i| pieces4 += piecesOfLine(term, i, 8); // 좁은 폭 — 랩이 걸린다
    try testing.expect(cols4 > 0);

    // **폭을 바꾼다.** 세터를 거치므로 파생값이 버려진다.
    setEditorTabWidth(fx.session, term, 8);
    try testing.expectEqual(@as(u32, 0), term.rt.editor_max_cols); // 버려졌다 — 아무도 다시 안 센다
    // **접힘 층은 버려지고 곧바로 다시 선다.** 세터가 `ensureFoldRanges`·`rebuildVisible`까지
    // 부르기 때문이다(안 부르면 gutter 화살표가 사라진 채 다음 접기 명령까지 안 돌아온다 —
    // 15차 적대적 검증). 그래서 여기서 재는 것은 "비었다"가 아니라 **새 폭으로 다시 섰다**이고,
    // 그 내용이 옛 폭 것과 다른지는 아래 ⑶이 범위를 통째로 비교해 잰다.
    try testing.expect(term.rt.editor_fold_ranges.len > 0);

    ensureMaxCols(term, false);
    try ensureFoldRanges(fx.session, term); // 세터가 이미 세웠으므로 no-op이다(비었을 때만 센다)
    const cols8 = term.rt.editor_max_cols;
    var pieces8: u32 = 0;
    for (0..editorLines(term).len) |i| pieces8 += piecesOfLine(term, i, 8);

    // ⑴ **가장 긴 줄**: 탭이 넓어지면 반드시 늘어난다(들여쓴 줄이 있으므로).
    std.debug.print("\n[ADV3-I] max_cols 4→{d} 8→{d} / fold_ranges {d}→{d} / pieces {d}→{d}\n", .{ cols4, cols8, folds4, term.rt.editor_fold_ranges.len, pieces4, pieces8 });
    try testing.expect(cols8 > cols4);

    // ⑵ **랩 조각 수**: 같은 폭에서 탭이 넓어지면 줄이 더 많이 접힌다.
    try testing.expect(pieces8 > pieces4);

    // ⑶ **접힘 범위가 실제로 갈린다.** 초판은 `len > 0`만 봐서 **항진명제**였다 — `ensureFoldRanges`는
    //     어떤 탭 폭으로 세든 뭔가를 채우므로, 상수를 읽도록 되돌린 뮤턴트가 그대로 통과했다(14차).
    //     범위를 통째로 비교해야 그 축이 잡힌다.
    const ranges8 = term.rt.editor_fold_ranges;
    var same = ranges8.len == ranges4.len;
    if (same) {
        for (ranges4, ranges8) |a4, a8| {
            if (!std.meta.eql(a4, a8)) {
                same = false;
                break;
            }
        }
    }
    if (same) {
        std.debug.print("[ADV3-I] 접힘 범위가 탭 폭 4와 8에서 같다 — 이 문서로는 그 축을 못 잰다\n", .{});
        return error.FoldRangesDidNotDiffer;
    }

    // ⑷ **낡음 재현 방지**: 세터를 안 거치고 필드만 바꾸면 옛 값이 남는다는 것을 못 박는다 —
    //    그것이 13차가 잡은 결함이고, 그래서 필드 직접 대입을 금지한다.
    term.rt.editor_tab_width = 4; // (일부러 세터를 안 쓴다)
    ensureMaxCols(term, false);
    try testing.expectEqual(cols8, term.rt.editor_max_cols); // 옛 값 그대로 — 세터가 필요한 이유
    setEditorTabWidth(fx.session, term, 4);
    ensureMaxCols(term, false);
    try testing.expectEqual(cols4, term.rt.editor_max_cols); // 세터를 거치면 돌아온다
}

test "ADV3-J 접은 채로 탭 폭을 바꿔도 숨은 줄이 돌아오고 보던 자리를 지킨다 (§4.1f)" {
    // **이 테스트가 재는 것은 세터의 계약이다** — 접은 채로 폭을 바꿔도 ⑴ 숨은 줄이 돌아오고
    // ⑵ 화살표가 다시 서고 ⑶ 보던 자리를 지킨다. 세터가 접힘을 푸는 **세 번째 경로**인데
    // `applyFold`·`unfoldAll`이 지키는 앵커 계약(`topDocLine`/`restoreTop`) 밖에 있어 뷰포트가
    // 300줄 튀었고, 접힘 층을 다시 안 세워 화살표가 사라진 채 다음 접기 명령까지 안 돌아왔다(15차).
    //
    // **`dropFoldState`의 내부 축은 여기서 안 잡힌다.** 세터가 그 뒤에 `ensureFoldRanges`·
    // `rebuildVisible`을 불러 `folded_len`·`fold_marks_len`·`visible_*`를 **덮어쓰기 때문**이다 —
    // 16차 적대적 검증이 그 셋을 되돌린 뮤턴트가 전부 살아남는 것을 실측했고, 초판 주석은 그것들이
    // "여기서 죽는다"고 적어 **소스에 거짓을 박아 두고 있었다**. 그 축은 ADV3-K가 직접 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 블록이 여럿이라야 접힌 좌표계와 문서 좌표계가 크게 갈린다.
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..60) |i| {
        var num: [24]u8 = undefined;
        const head = std.fmt.bufPrint(&num, "block{d}\n", .{i}) catch unreachable;
        try doc.appendSlice(allocator, head);
        try doc.appendSlice(allocator, "\tbody a\n\tbody b\n");
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "f.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "f.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    const doc_lines = editorLines(term).len;

    // **연 직후에 화살표가 보인다**(`finishAttach` 불변식).
    try testing.expect(foldMarks(term) != null);

    // **접는다.**
    try testing.expect(foldAll(fx.session));
    const visible_folded = editorLines(term).len;
    try testing.expect(visible_folded < doc_lines);
    try testing.expect(term.rt.editor_folded_len > 0);

    // 접힌 좌표계에서 한참 아래를 본다.
    term.rt.editor_first_line = visible_folded / 2;
    const want_doc_line = topDocLine(term);
    try testing.expect(want_doc_line > term.rt.editor_first_line); // 접힘이 실제로 좌표계를 벌렸다

    // **접은 채로 탭 폭을 바꾼다.**
    setEditorTabWidth(fx.session, term, 8);

    // ⑴ 숨은 줄이 전부 돌아왔다.
    try testing.expectEqual(doc_lines, editorLines(term).len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_folded_len);
    try testing.expectEqual(@as(usize, 0), foldedHeads(term).len);

    // ⑵ 화살표가 다시 선다 — 사라진 채로 두면 접을 자리를 화면에서 알 수 없다.
    try testing.expect(foldMarks(term) != null);
    try testing.expect(term.rt.editor_fold_ranges.len > 0);

    // ⑶ 보던 자리를 지킨다(앵커 계약). 실측으로 900줄 문서에서 300줄 튀었다.
    testing.expectEqual(want_doc_line, term.rt.editor_first_line) catch |err| {
        std.debug.print("\n[ADV3-J] doc={d} 접힘={d} 앵커={d} 세터뒤 first_line={d}\n", .{ doc_lines, visible_folded, want_doc_line, term.rt.editor_first_line });
        return err;
    };

    // ⑷ 다시 접고 펴는 왕복이 성립한다 — 상태가 일관되지 않으면 여기서 깨진다.
    try testing.expect(foldAll(fx.session));
    try testing.expect(unfoldAll(fx.session));
    try testing.expectEqual(doc_lines, editorLines(term).len);
}

test "ADV3-K dropFoldState는 접힘 층을 통째로 놓는다 — 세터를 거치지 않고 직접 잰다 (§4.1f)" {
    // **세터를 거치면 이 축을 못 잰다.** 세터가 `dropFoldState` 뒤에 `ensureFoldRanges`·
    // `rebuildVisible`을 불러 `folded_len`·`fold_marks_len`·`visible_*`를 **덮어쓰기 때문**이다 —
    // 16차 적대적 검증이 그 셋을 되돌린 뮤턴트가 155개 테스트를 전부 통과하는 것을 실측했고,
    // ADV3-J 주석은 그것들이 "여기서 죽는다"고 **거짓을 적고 있었다**. 그래서 직접 부른다.
    //
    // 이 함수가 지키는 것: ⑴ 여섯 배열을 다 놓는다(하나라도 빠지면 누수) ⑵ 포인터를 비운다(안 비우면
    // 다음 호출자가 **이중 해제**) ⑶ 길이 둘을 0으로 세운다(안 세우면 `foldedHeads`·`foldMarks`가
    // 빈 배열에 옛 길이로 접근해 범위 밖이다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..20) |i| {
        var num: [24]u8 = undefined;
        const head = std.fmt.bufPrint(&num, "b{d}\n", .{i}) catch unreachable;
        try doc.appendSlice(allocator, head);
        try doc.appendSlice(allocator, "\tx\n\ty\n");
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "k.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "k.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try testing.expect(foldAll(fx.session));
    try testing.expect(term.rt.editor_folded_len > 0);
    try testing.expect(term.rt.editor_fold_marks_len > 0);
    try testing.expect(term.rt.editor_visible_lines.len > 0);

    dropFoldState(fx.session, term);

    // ⑵ 포인터가 비었는가 — 안 비면 아래 두 번째 호출이 이중 해제다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_fold_ranges.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_folded_buf.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_folded_prev.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_fold_marks.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_visible_lines.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_visible_numbers.len);

    // ⑶ 길이 둘이 0인가 — `foldedHeads`·`foldMarks`가 빈 배열에 옛 길이로 접근하면 범위 밖이다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_folded_len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_fold_marks_len);
    try testing.expectEqual(@as(usize, 0), foldedHeads(term).len); // G1이 여기서 죽는다
    try testing.expectEqual(@as(?[]const chrome_editor.gutter.Fold, null), foldMarks(term)); // G2

    // 접힘이 풀렸으므로 문서 전체가 보인다.
    try testing.expectEqual(term.rt.editor_lines.len, editorLines(term).len);

    // **두 번 불러도 안전하다** — 포인터를 안 비우는 뮤턴트가 여기서 이중 해제로 죽는다(G4).
    dropFoldState(fx.session, term);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_fold_ranges.len);

    // 다시 세울 수 있다 — 놓기만 하고 못 세우면 그것도 결함이다.
    try ensureFoldRanges(fx.session, term);
    try testing.expect(term.rt.editor_fold_ranges.len > 0);
    try testing.expect(foldAll(fx.session));
    try testing.expect(unfoldAll(fx.session));
}

test "ADV3-L 비교 뷰에서는 탭 폭을 바꿔도 접힘 층을 파괴하지 않는다 (§4.1f 계약 ⓪)" {
    // **`applyFold`·`unfoldAll`이 지키는 계약 셋 중 첫째를 세터가 안 졌다**(16차 적대적 검증).
    // 비교 뷰에서는 `foldSourceLines`가 비어 층을 **다시 셀 수 없으므로**, 지우면 돌아올 길이 없다 —
    // 실측으로 `marks=true ranges=8`이 `marks=false ranges=0`이 되고 **비교를 꺼도 그대로**였다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "a\n\tb\n\tc\nd\n\te\n\tf\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "d.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try ensureFoldRanges(fx.session, term);
    const ranges_before = term.rt.editor_fold_ranges.len;
    try testing.expect(ranges_before > 0);
    try testing.expect(foldMarks(term) != null);

    // **비교 상태로 만든다** — `foldSourceLines`가 비어 접힘을 셀 수 없는 상태다.
    term.rt.editor_diff = .{ .requested_ms = 0 };
    try testing.expect(foldsUnavailable(term));

    setEditorTabWidth(fx.session, term, 8);

    // 층이 그대로다 — 지웠으면 비교를 꺼도 안 돌아온다.
    try testing.expectEqual(ranges_before, term.rt.editor_fold_ranges.len);

    // 파생 캐시는 버려졌다(그것은 다시 셀 수 있다).
    try testing.expectEqual(@as(u32, 0), term.rt.editor_max_cols);

    // **비교를 끄면 화살표가 여전히 있다.**
    term.rt.editor_diff = null;
    try testing.expect(foldMarks(term) != null);
    try testing.expect(foldAll(fx.session));
    try testing.expect(unfoldAll(fx.session));
}

test "SEL1 본문 클릭이 선택을 세우고, 드래그가 범위를 넓히고, 뗌이 소유권을 놓는다 (§4.1g 배선)" {
    // **`hitTestBody`의 첫 제품 호출자를 재는 테스트다.** 그 전까지 좌표계는 판정자만 부르고 있었고
    // (호출 29곳 전부 테스트), §4.1g의 "아직 검증되지 않는 문장" 표가 그 사실 위에 서 있었다 —
    // 적대적 검증 열일곱 회차가 "배선이 없어 못 재는 계약"을 반복해서 지적했다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "s.txt", .data = "alpha beta\ngamma delta\nepsilon\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "s.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    const text_x0: i32 = @as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(geom.content_left_px));
    const y0: i32 = @as(i32, @intCast(body.y)) + inset;

    // 첫 줄 3열을 누른다.
    const down_x: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(3 * @as(u32, geom.cell_w_px))));
    const down_y: f64 = @floatFromInt(y0 + 1);
    const pane = pane_ops.activePane(fx.session);
    try testing.expect(beginBodySelection(fx.session, pane, down_x, down_y, 0));

    const sel0 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(sel0.anchor_start, sel0.focus); // 클릭만으로는 범위가 없다(caret)
    try testing.expectEqual(@as(usize, 3), sel0.focus); // "alpha…"의 3번째 byte

    // **드래그가 focus만 움직인다.** 둘째 줄로 끈다.
    const drag_x: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(2 * @as(u32, geom.cell_w_px))));
    const drag_y: f64 = @floatFromInt(y0 + @as(i32, @intCast(geom.cell_h_px)) + 1);
    try testing.expect(dragBodySelection(fx.session, 2, drag_x, drag_y));
    const sel1 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(sel0.anchor_start, sel1.anchor_start); // anchor는 제자리
    try testing.expectEqual(@as(usize, 13), sel1.focus); // "alpha beta\n"(11) + 2
    try testing.expect(sel1.focus > sel1.anchor_start);

    // **뒤로 끌어도 범위가 뒤집히지 않는다**(`anchorLo`/`anchorHi`가 min/max로 읽는다).
    try testing.expect(dragBodySelection(fx.session, 2, @floatFromInt(text_x0), down_y));
    const sel2 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), sel2.focus);
    try testing.expect(sel2.anchor_start > sel2.focus); // 뒤집힌 상태로 들고 있어도 되는 모델이다

    // **뗌이 소유권을 놓는다** — 안 놓으면 다음 클릭이 옛 제스처에 갇힌다.
    try testing.expect(fx.session.pointerGestureIs(.editor_selection));
    try testing.expect(dragBodySelection(fx.session, 3, drag_x, drag_y));
    try testing.expect(!fx.session.pointerGestureIs(.editor_selection));

    // 제스처가 없으면 드래그를 소비하지 않는다 — 소비하면 터미널 선택이 죽는다.
    try testing.expect(!dragBodySelection(fx.session, 2, drag_x, drag_y));
}

test "SEL2 gutter와 막대 띠는 본문 선택이 가져가지 않는다 (§4.1g 결정표)" {
    // **순서 계약을 재는 첫 판정자다.** 결정표의 *"막대 위 클릭은 상위가 먼저 가져간다"*와
    // *"gutter 클릭은 이 좌표계가 받지 않는다"*는 그동안 **순서를 보장하는 코드가 없어 예고**였고,
    // §4.1g의 "아직 검증되지 않는 문장" 표에 그렇게 적혀 있었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..400) |i| { // 세로 막대가 서려면 넘쳐야 한다
        var num: [24]u8 = undefined;
        const line = std.fmt.bufPrint(&num, "line {d}\n", .{i}) catch unreachable;
        try doc.appendSlice(allocator, line);
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "g.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "g.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const y: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset + 1);
    const pane = pane_ops.activePane(fx.session);

    // **gutter를 눌러도 선택이 안 선다** — 줄 번호·접힘 화살표 자리다.
    const gutter_x: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset + 1);
    try testing.expect(!beginBodySelection(fx.session, pane, gutter_x, y, 0));
    try testing.expectEqual(@as(?maru.session.editor.selection.Selection, null), term.rt.editor_selection);

    // **막대 띠를 눌러도 선택이 안 선다** — 막대가 먼저 가져간다.
    const bar = term.rt.editor_scrollbar orelse return error.NoScrollbar;
    const bar_x: f64 = @as(f64, bar.track_x) + 1;
    try testing.expect(beginScrollbarGesture(fx.session, pane, bar_x, y));
    try testing.expectEqual(@as(?maru.session.editor.selection.Selection, null), term.rt.editor_selection);
    fx.session.cancelPointerGesture();

    // 본문은 가져간다 — 위 둘이 항진명제가 아니라는 대조군이다.
    const geom = term.rt.editor_hit_geom;
    const text_x: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(geom.content_left_px)) + 1);
    try testing.expect(beginBodySelection(fx.session, pane, text_x, y, 0));
    try testing.expect(term.rt.editor_selection != null);
}

test "SEL3 선택이 화면에 띠로 서고, 복사가 문서 원본을 뜬다 (§4.1g)" {
    // **선택은 서는데 안 보이면 없는 것과 같다.** 그리고 복사는 화면에 그린 것이 아니라 **문서
    // 원본**을 떠야 한다 — 둘은 §3.8 표기(`<U+202E>`)와 초장문 줄 축소에서 갈리고, 붙여넣기가
    // 기대되는 것은 원본이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "alpha beta\ngamma delta\nepsilon\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "c.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // 선택이 없으면 띠도 복사도 없다.
    {
        var d0 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d0.dl.deinit(allocator);
        try testing.expect(!copySelection(fx.session));
    }

    // "beta\ngamma"를 고른다(6 .. 16) — **줄을 걸친다**.
    term.rt.editor_selection = .{ .anchor_start = 6, .anchor_end = 6, .focus = 16 };

    // ⑴ 줄별로 잘린다.
    const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;
    try testing.expectEqual(@as(usize, 1), marks[0].len);
    try testing.expectEqual(@as(u32, 6), marks[0][0].start); // "alpha "(6) 뒤
    try testing.expectEqual(@as(u32, 4), marks[0][0].len); // "beta"
    try testing.expectEqual(@as(usize, 1), marks[1].len);
    try testing.expectEqual(@as(u32, 0), marks[1][0].start); // 둘째 줄은 머리부터
    try testing.expectEqual(@as(u32, 5), marks[1][0].len); // "gamma"
    try testing.expectEqual(@as(usize, 0), marks[2].len); // 셋째 줄은 선택 밖

    // ⑵ 그린다 — 여기서는 **죽지 않는 것과 마크가 렌더로 흘러가는 것**만 본다. 띠가 실제로 서는지는
    //     컴포넌트 쪽(`frame.zig`)이 op 수로 잰다: draw list는 셀 크기 quad를 셀 배경으로 접으므로
    //     제품 층에서 세면 그 접힘까지 함께 재게 되고, 그러면 무엇이 깨졌는지 말하지 못한다.
    {
        var d2 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d2.dl.deinit(allocator);
        try testing.expect(d2.dl.cells.len > 0);
    }

    // ⑶ 복사가 문서 원본을 뜬다.
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("beta\ngamma", fx.session.chrome_clipboard_write);

    // **두 번 복사해도 안 샌다.** 앞의 것을 안 놓는 뮤턴트가 살아남았다(적대적 검증) — 누수는
    // 단언이 아니라 exit code로만 드러나므로 여기서 그 경로를 밟아 둔다.
    term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 5 };
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("alpha", fx.session.chrome_clipboard_write);

    // ⑷ **caret뿐이면 그 줄 전체를 담는다**(§3.4 — "선택 없이 복사하면 caret이 있는 줄 전체").
    //
    // **이 판정자는 원래 그 반대를 고정하고 있었다**: `!copySelection` + 빈 클립보드. 그때는
    // 복사만 있고 붙여넣기가 없어 "빈 문자열을 넣으면 사용자가 가진 것을 지운다"가 유일한 걱정
    // 이었는데, §3.4가 요구하는 것은 **빈 문자열이 아니라 줄**이다(적대적 검증 2026-08-26).
    // 줄 단위 표식과 붙여넣기가 함께 서면서 그 계약을 지킬 수 있게 됐다 — `COPY1`이 소유한다.
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(6);
    try testing.expect(copySelection(fx.session));
    try testing.expect(fx.session.chrome_clipboard_write.len > 0); // 빈 문자열은 여전히 아니다
    try testing.expect(fx.session.editor_clipboard_meta.?.from_empty_selection);
}

test "MC1 다음 일치 추가가 커서를 늘리고, 띠가 전부 서고, 복사가 문서 순서로 잇는다 (§9.1·§3.4)" {
    // **커서가 늘어도 화면과 클립보드가 하나만 알면 결함이 조용하다** — 띠가 하나만 서거나 복사가
    // 한 조각만 담아도 아무도 실패하지 않는다. 그래서 셋을 한 자리에서 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "mc.txt", .data = "foo bar\nbaz foo\nfoo end\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "mc.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // 첫 줄의 "foo"(0..3)를 골라 둔다.
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 3, 3, .word);

    // ⑴ 한 번 누르면 둘째 "foo"(12..15)가 primary가 되고 옛 primary가 나머지로 내려간다.
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expectEqual(@as(usize, 12), term.rt.editor_selection.?.start());
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections[0].start());

    // ⑵ 또 누르면 셋째(16..19)까지 — **가장 뒤부터 찾으므로** 아래로 내려간다.
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);
    try testing.expectEqual(@as(usize, 16), term.rt.editor_selection.?.start());

    // ⑶ 띠가 **셋 다** 선다. 줄마다 하나씩이므로 줄별 마크 수가 1·1·1이다.
    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d.dl.deinit(allocator);
    }
    const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;
    try testing.expectEqual(@as(usize, 1), marks[0].len);
    try testing.expectEqual(@as(u32, 0), marks[0][0].start);
    try testing.expectEqual(@as(usize, 1), marks[1].len);
    try testing.expectEqual(@as(u32, 4), marks[1][0].start); // "baz " 뒤
    try testing.expectEqual(@as(usize, 1), marks[2].len);
    try testing.expectEqual(@as(u32, 0), marks[2][0].start);

    // ⑷ 복사는 **문서 순서**로 줄바꿈 연결한다(§3.4). primary가 마지막이지만 순서는 문서를 따른다.
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("foo\nfoo\nfoo", fx.session.chrome_clipboard_write);

    // ⑸ 전부 골랐으면 더 늘지 않는다 — 같은 자리에 커서가 겹쳐 쌓이면 타이핑이 두 번 들어간다.
    try testing.expect(!addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    // ⑹ 클릭 한 번이 정리한다 — 없으면 사용자가 커서를 없앨 방법이 없다.
    clearExtraSelections(fx.session, term);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections.len);
}

test "EDIT1 타이핑이 문서에 들어간다 — 파생 상태까지 따라온다 (§3.3)" {
    // **N2에서 처음으로 글자가 들어가는 자리다.** 그리고 편집은 접힘 토글·스크롤과 달리
    // **줄 배열 자체가 낡는다**(그 배열은 문서 내용을 빌리는 슬라이스다) — 안 다시 세우면 렌더가
    // 옛 경계를 읽는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "type.txt", .data = "alpha\nbeta\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "type.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // caret을 첫 줄 끝에 둔다.
    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));

    // ⑴ 문서가 바뀌었다.
    try testing.expectEqualStrings("alpha!\nbeta\n", term.rt.editor_doc.?.file.content);
    // ⑵ **줄 배열이 따라왔다** — 안 따라오면 렌더가 옛 슬라이스를 그린다.
    try testing.expectEqualStrings("alpha!", term.rt.editor_lines[0]);
    // ⑶ 커서가 삽입 뒤로 밀렸다.
    try testing.expectEqual(@as(usize, 6), term.rt.editor_selection.?.focus);

    // ⑷ 줄이 늘어나는 편집도 배열이 따라온다.
    //
    // **끝 개행 때문에 줄이 하나 더 있다**: `"alpha!\nbeta\n"`은 `"alpha!"`·`"beta"`·`""` 셋이다
    // (§3.5 — 파일 끝 개행은 "빈 마지막 줄"로 보이고 거기 커서를 놓을 수 있어야 한다).
    // 처음에 3을 기대했다가 실측이 4를 냈다 — **판정자가 틀렸고 코드가 맞았다.**
    try testing.expect(insertText(fx.session, term, "\nmid"));
    try testing.expectEqual(@as(usize, 4), term.rt.editor_lines.len);
    try testing.expectEqualStrings("mid", term.rt.editor_lines[1]);

    // ⑸ 프레임이 죽지 않는다 — 파생 상태가 어긋나면 여기서 밟는다.
    var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
    d.dl.deinit(allocator);
}

test "EDIT2 커서가 여럿이면 모든 자리에 들어가고 뒤 커서가 밀린다 (§3.3)" {
    // **한 번의 타이핑 = delta 하나다.** 커서마다 따로 적용하면 첫 삽입이 뒤 커서를 밀어
    // 두 번째가 엉뚱한 자리에 간다 — §3.3이 매핑을 같은 연산에 묶으라고 한 이유다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "multi.txt", .data = "aa bb aa cc aa\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "multi.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // "aa" 셋을 전부 고른다.
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 2, 2, .word);
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    // 셋을 한꺼번에 바꾼다 — **선택이 있으면 타이핑이 그것을 대체한다.**
    try testing.expect(insertText(fx.session, term, "XY"));
    try testing.expectEqualStrings("XY bb XY cc XY\n", term.rt.editor_doc.?.file.content);

    // 커서 셋이 각자 삽입 뒤에 선다.
    var iter = selections(term);
    var focuses: [3]usize = undefined;
    var n: usize = 0;
    while (iter.next()) |sel| {
        if (n < focuses.len) focuses[n] = sel.focus;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    std.mem.sort(usize, &focuses, {}, std.sort.asc(usize));
    try testing.expectEqualSlices(usize, &.{ 2, 8, 14 }, &focuses);
}

test "EDIT4 Backspace·Delete가 글자 단위로 지운다 — 깨진 UTF-8을 만들지 않는다 (§3.2)" {
    // **byte 하나만 지우면 한글·이모지가 깨진다.** 그 상태는 화면에 §3.8 표기로 뜨고 저장하면
    // 파일이 깨진다 — 되돌릴 방법이 undo뿐인 종류다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "del.txt", .data = "a한b\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "del.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // "한"(3 byte) 뒤에 caret을 두고 Backspace — **3 byte가 통째로** 빠져야 한다.
    term.rt.editor_selection = editor_selection.Selection.at(4);
    try testing.expect(deleteText(fx.session, term, true));
    try testing.expectEqualStrings("ab\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(@as(usize, 1), term.rt.editor_selection.?.focus);

    // Delete(앞으로)도 같은 규칙이다.
    try testing.expect(deleteText(fx.session, term, false));
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);

    // **위 Delete는 ASCII라 byte 하나와 결과가 같다.** 앞으로 지우기를 byte 단위로 바꾼 뮤턴트가
    // 그래서 살아남았다(적대적 검증 2026-08-26) — 지워질 글자가 **여러 byte인 경우**를 따로 잰다.
    {
        const wide = try undoFixture(&fx, allocator, "e4b.txt", "a한b\n");
        wide.rt.editor_selection = editor_selection.Selection.at(1); // "한" 바로 앞
        try testing.expect(deleteText(fx.session, wide, false));
        try testing.expectEqualStrings("ab\n", wide.rt.editor_doc.?.file.content);
        try testing.expectEqual(@as(usize, 1), wide.rt.editor_selection.?.focus);
    }

    // **문서 처음에서 Backspace는 아무 일도 안 한다** — 빈 편집이 쌓이면 undo가 헛돈다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!deleteText(fx.session, term, true));
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);

    // 선택이 있으면 **방향과 무관하게** 그 선택을 지운다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 1);
    try testing.expect(deleteText(fx.session, term, false));
    try testing.expectEqualStrings("\n", term.rt.editor_doc.?.file.content);
}

test "EDIT5 Enter가 줄을 나누고 줄 배열이 따라온다 (§3.3)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "enter.txt", .data = "abcdef\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "enter.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    const before_lines = term.rt.editor_lines.len;
    term.rt.editor_selection = editor_selection.Selection.at(3);
    try testing.expect(insertText(fx.session, term, "\n"));

    try testing.expectEqualStrings("abc\ndef\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(before_lines + 1, term.rt.editor_lines.len);
    try testing.expectEqualStrings("abc", term.rt.editor_lines[0]);
    try testing.expectEqualStrings("def", term.rt.editor_lines[1]);
    try testing.expectEqual(@as(usize, 4), term.rt.editor_selection.?.focus);
}

test "EDIT6 파생 상태 갱신이 중간에 실패해도 렌더 스냅숏은 남지 않는다 (§4.1g)" {
    // **적대적 검증(2026-08-25)이 연 자리다.** `refreshAfterEdit`의 ⑵⑶(접힘·보이는 줄)이 할당에
    // 실패하면 `try`가 즉시 반환해 ⑷⑸⑹이 통째로 안 돌았다 — 그러면 렌더 스냅숏이 편집 **전**
    // 행 배열을 든 채 남고, 클릭이 **사라진 글자의 자리를 답한다.** 호출자가 이 실패를 `catch {}`로
    // 삼키므로 편집은 성사되고 파생 상태만 낡는다.
    //
    // 재는 방식은 `EDOC9`와 같다 — 실패 지점을 하나씩 뒤로 밀며 **불변식**을 확인한다:
    // **문서가 바뀌었으면 스냅숏은 비어 있다.** 안 바뀌었으면 옛 스냅숏이 여전히 맞으므로 묻지 않는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;

    var reached: usize = 0; // 실제로 편집이 성사된 지점 수
    var step: usize = 0;
    while (step < 40) : (step += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();

        var fx = try PaneFixture.init(alloc);
        defer fx.deinit(alloc);
        // **접히는 문서를 쓴다.** 평평한 문서는 `editor_visible_lines`가 늘 비어 있어 아래
        // 불변식 ②의 절반이 **공허하게 통과한다** — 접힘 상태를 안 버리는 뮤턴트가 그래서
        // 살아남았다(적대적 검증 2026-08-26).
        const term = undoFixture(&fx, alloc, "e6.txt", "fn a() {\n    x\n    y\n}\nz\n") catch continue;
        // 실제로 하나 접어 둔다 — 접힌 것이 있어야 보이는 줄 배열이 생긴다.
        _ = toggleFoldHead(fx.session, term, 0);

        const before = try backing.dupe(u8, term.rt.editor_doc.?.file.content);
        defer backing.free(before);

        // 렌더가 굳혀 둔 상태를 흉내 낸다 — 지워지는지 보려면 0이 아니어야 한다.
        // **행 수만이 아니라 기하도 함께 본다.** 행 배열만 비우고 기하를 남기면 클릭이 "행은
        // 없는데 셀 크기는 옛 프레임"인 상태로 답한다 — 기하만 안 버리는 뮤턴트가 살아남았다.
        term.rt.editor_hit_rows_len = 1;
        term.rt.editor_hit_geom.cell_w_px = 7;
        term.rt.editor_hit_geom.cell_h_px = 15;
        term.rt.editor_hit_geom.tab_width = 4;

        // **여기서부터** 실패시킨다. 편집 자체가 막히는 지점도, 갱신 중간에 막히는 지점도 지난다.
        failing.fail_index = failing.allocations + step;
        term.rt.editor_selection = editor_selection.Selection.at(0);
        _ = insertText(fx.session, term, "z");

        const content = term.rt.editor_doc.?.file.content;
        const changed = !std.mem.eql(u8, before, content);
        if (changed) {
            reached += 1;
            // **불변식 ①**: 문서가 바뀌었으면 클릭이 읽을 옛 스냅숏이 남아 있으면 안 된다.
            try testing.expectEqual(@as(usize, 0), term.rt.editor_hit_rows_len);
            try testing.expectEqual(@as(u16, 0), term.rt.editor_hit_geom.cell_w_px);
            try testing.expectEqual(@as(u16, 0), term.rt.editor_hit_geom.cell_h_px);
            try testing.expectEqual(@as(u8, 0), term.rt.editor_hit_geom.tab_width);

            // **불변식 ②**: 줄 슬라이스가 **지금** content 안을 가리킨다.
            //
            // 줄 배열은 content 버퍼를 빌리는데 `edit_doc.apply`가 옛 버퍼를 푼다. 갱신이 중간에
            // 실패해 옛 배열이 남으면 그것은 낡은 값이 아니라 **해제된 메모리**이고, 다음 프레임의
            // `editorLines(term)`가 그것을 읽는다. 포인터가 현재 버퍼 안인지 직접 본다 —
            // `testing.allocator`가 use-after-free를 늘 잡아 주지는 않기 때문이다.
            const lo = @intFromPtr(content.ptr);
            const hi = lo + content.len;
            for (term.rt.editor_lines) |ln| {
                const at = @intFromPtr(ln.ptr);
                try testing.expect(at >= lo and at + ln.len <= hi);
            }
            for (term.rt.editor_visible_lines) |ln| {
                const at = @intFromPtr(ln.ptr);
                try testing.expect(at >= lo and at + ln.len <= hi);
            }
        }
    }

    // **"한 번도 안 밟았는데 통과"를 막는다.** 실패 지점이 전부 편집 앞이면 이 판정자는 아무것도
    // 재지 않는다 — `EDOC9`를 고칠 때 실제로 그 착각을 했다(36개 중 34개가 목표 경로 앞이었다).
    try testing.expect(reached > 0);
}

/// UNDO 판정자들이 쓰는 픽스처 — 파일을 열고 caret을 놓는다.
fn undoFixture(fx: *PaneFixture, allocator: std.mem.Allocator, name: []const u8, data: []const u8) !*Term {
    const io = std.testing.io;
    try fx.dir.dir.writeFile(io, .{ .sub_path = name, .data = data });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    return try openPathInActivePane(fx.session, path);
}

test "UNDO8 편집·되돌리기·다시하기를 섞어도 문서가 모델과 같다 (상태 기계 퍼즈)" {
    // **undo 스택은 상태 기계인데 판정자들은 각자 한 갈래씩만 걷는다.** 편집→undo→편집→redo처럼
    // 섞이는 순서는 조합이 폭발해 손으로 못 적고, 거기서 어긋나면 사용자에게는 "되돌렸는데 이상한
    // 글자가 남았다"로 보인다.
    //
    // **기준은 스택 두 개를 든 순진한 모델이다** — 내용 전체를 통째로 쌓는다. 제품은 delta를 쌓아
    // 메모리를 아끼는데, 그 최적화가 답을 바꾸지 않아야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "fuzz_undo.txt", "seed\n");

    var undo_model: std.ArrayList([]u8) = .empty;
    defer {
        for (undo_model.items) |x| allocator.free(x);
        undo_model.deinit(allocator);
    }
    var redo_model: std.ArrayList([]u8) = .empty;
    defer {
        for (redo_model.items) |x| allocator.free(x);
        redo_model.deinit(allocator);
    }

    var prng = std.Random.DefaultPrng.init(0x5A1D);
    const rand = prng.random();

    var step: usize = 0;
    while (step < 300) : (step += 1) {
        const before = try allocator.dupe(u8, term.rt.editor_doc.?.file.content);
        var keep_before = true;
        defer if (keep_before) allocator.free(before);

        switch (rand.uintLessThan(u8, 10)) {
            0...4 => { // 타이핑
                // **묶음을 매번 끊는다** — 안 끊으면 모델이 "편집 하나 = 스택 하나"를 못 맞춘다.
                breakUndoGroup(term);
                const at = rand.uintAtMost(usize, term.rt.editor_doc.?.file.content.len);
                term.rt.editor_selection = editor_selection.Selection.at(at);
                const texts = [_][]const u8{ "a", "bb", "\n", "한" };
                if (insertText(fx.session, term, texts[rand.uintLessThan(usize, texts.len)])) {
                    try undo_model.append(allocator, before);
                    keep_before = false;
                    for (redo_model.items) |x| allocator.free(x);
                    redo_model.clearRetainingCapacity(); // 새 편집은 redo를 버린다
                }
            },
            5, 6 => { // 지우기
                breakUndoGroup(term);
                const len = term.rt.editor_doc.?.file.content.len;
                if (len > 0) {
                    const at = 1 + rand.uintLessThan(usize, len);
                    term.rt.editor_selection = editor_selection.Selection.at(at);
                    if (deleteText(fx.session, term, true)) {
                        try undo_model.append(allocator, before);
                        keep_before = false;
                        for (redo_model.items) |x| allocator.free(x);
                        redo_model.clearRetainingCapacity();
                    }
                }
            },
            7, 8 => { // 되돌리기
                const ok = undoEdit(fx.session, term);
                try testing.expectEqual(undo_model.items.len > 0, ok);
                if (ok) {
                    const want = undo_model.pop().?;
                    defer allocator.free(want);
                    try testing.expectEqualStrings(want, term.rt.editor_doc.?.file.content);
                    try redo_model.append(allocator, before);
                    keep_before = false;
                }
            },
            else => { // 다시 하기
                const ok = redoEdit(fx.session, term);
                try testing.expectEqual(redo_model.items.len > 0, ok);
                if (ok) {
                    const want = redo_model.pop().?;
                    defer allocator.free(want);
                    try testing.expectEqualStrings(want, term.rt.editor_doc.?.file.content);
                    try undo_model.append(allocator, before);
                    keep_before = false;
                }
            },
        }

        // 매 걸음 파생 상태가 성립한다 — 줄 배열이 문서와 같은 줄 수인가.
        const doc = term.rt.editor_doc.?;
        try testing.expectEqual(doc.file.lineCount(), term.rt.editor_lines.len);
    }
}

test "SAVE1 편집한 내용이 디스크에 실제로 남는다 (§3.5)" {
    // **저장은 파일을 실제로 바꾸는 유일한 연산이다.** 다른 판정자는 메모리 상태만 보지만
    // 여기서는 **디스크에서 다시 읽어** 확인한다 — 쓰기 경로가 조용히 실패하면 사용자는
    // "저장했는데 없어졌다"를 겪고, 그것은 되돌릴 방법이 없다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "save1.txt", "alpha\nbeta\n");

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, " EDITED"));
    try testing.expect(saveDocument(fx.session, term));

    const on_disk = try fx.dir.dir.readFileAlloc(io, "save1.txt", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings("alpha EDITED\nbeta\n", on_disk);

    // 저장 뒤에도 문서가 그대로다 — 다시 읽지 않으므로 외부 변경을 조용히 삼키지 않는다.
    try testing.expectEqualStrings("alpha EDITED\nbeta\n", term.rt.editor_doc.?.file.content);
}

test "SAVE2 연 그대로의 파일 속성이 디스크에 되돌아간다 (§3.5)" {
    // **열었다 저장만 해도 내용이 달라지면 diff가 통째로 물든다.** `EDOC11`이 bytes 만드는 규칙을
    // 재고, 여기서는 그 bytes가 **실제로 그렇게 쓰이는지**를 잰다 — 둘은 다른 축이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    // ⑴ BOM + CRLF + 끝 개행 없음.
    {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const term = try undoFixture(&fx, allocator, "save2.txt", "\xEF\xBB\xBFa\r\nb");
        term.rt.editor_selection = editor_selection.Selection.at(0);
        try testing.expect(insertText(fx.session, term, "X"));
        try testing.expect(saveDocument(fx.session, term));

        const on_disk = try fx.dir.dir.readFileAlloc(io, "save2.txt", allocator, .limited(4096));
        defer allocator.free(on_disk);
        // BOM 유지 · 기존 CRLF 유지 · 끝 개행 없음 유지.
        try testing.expectEqualStrings("\xEF\xBB\xBFXa\r\nb", on_disk);
    }

    // ⑵ 끝 개행이 있던 파일은 있는 채로.
    {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        const term = try undoFixture(&fx, allocator, "save3.txt", "keep\n");
        term.rt.editor_selection = editor_selection.Selection.at(4);
        try testing.expect(insertText(fx.session, term, "!"));
        try testing.expect(saveDocument(fx.session, term));

        const on_disk = try fx.dir.dir.readFileAlloc(io, "save3.txt", allocator, .limited(4096));
        defer allocator.free(on_disk);
        try testing.expectEqualStrings("keep!\n", on_disk);
    }
}

test "SAVE3 읽기 전용은 저장을 거절하고 파일을 건드리지 않는다 (§3.5)" {
    // **거절이 조용하면 사용자는 저장된 줄 안다.** 실패를 알리는 것은 상태바 몫이고(§2.2),
    // 여기서는 **파일이 안 바뀌는 것**만 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "save4.txt", "original\n");

    // 편집을 먼저 하고(쓸 내용이 있게) 읽기 전용으로 만든다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "Z"));
    term.rt.editor_doc.?.file.read_only = true;

    try testing.expect(!saveDocument(fx.session, term));
    const on_disk = try fx.dir.dir.readFileAlloc(io, "save4.txt", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings("original\n", on_disk); // 안 바뀌었다
}

test "UNDO1 되돌리면 문서와 커서가 편집 전으로 간다 (§3.3)" {
    // **문서만 돌아오고 커서가 안 돌아오면 다음 타이핑이 엉뚱한 데 간다.** §3.3이 selection 배열
    // 전체와 primary를 함께 되돌리라고 한 이유다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u1.txt", "hello\n");

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, " world"));
    try testing.expectEqualStrings("hello world\n", term.rt.editor_doc.?.file.content);

    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("hello\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(@as(usize, 5), term.rt.editor_selection.?.focus);
    // 줄 배열도 따라왔다 — 안 따라오면 렌더가 없는 글자를 그린다.
    try testing.expectEqualStrings("hello", term.rt.editor_lines[0]);

    // 더 되돌릴 것이 없으면 거절한다(빈 스택에서 죽지 않는다).
    try testing.expect(!undoEdit(fx.session, term));
}

test "UNDO2 연속 타이핑은 한 묶음이라 undo 한 번에 함께 돌아간다 (§3.3)" {
    // **묶음이 없으면 사용자가 글자 수만큼 눌러야 한다.** 반대로 과하게 묶으면 지운 적 없는 것이
    // 사라진다 — 그래서 아래 UNDO3이 끊기는 쪽을 함께 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u2.txt", "x\n");

    term.rt.editor_selection = editor_selection.Selection.at(1);
    try testing.expect(insertText(fx.session, term, "a"));
    try testing.expect(insertText(fx.session, term, "b"));
    try testing.expect(insertText(fx.session, term, "c"));
    try testing.expectEqualStrings("xabc\n", term.rt.editor_doc.?.file.content);

    // **한 번**에 셋 다 돌아간다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("x\n", term.rt.editor_doc.?.file.content);
}

test "UNDO9 타이핑하다 지우면 묶음이 끊긴다 — 연산 종류 변경 (§3.3)" {
    // **뮤턴트가 뚫고 나온 자리다**(적대적 검증 2026-08-25). 타이핑을 `.delete` 종류로 기록하게
    // 바꿔도 `UNDO1~8`이 전부 통과했다 — §3.3이 묶음을 끊는 이유로 셋(**커서 이동**·**시간 경과**·
    // **연산 종류 변경**)을 드는데 판정자는 첫째(UNDO3)만 재고 있었다.
    //
    // 안 끊으면 "치다가 한 글자 지웠다"가 한 묶음이 되어, 지운 것을 되돌리려는 undo 한 번에
    // **친 것까지 사라진다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u9.txt", "AB\n");

    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(insertText(fx.session, term, "12"));
    try testing.expectEqualStrings("AB12\n", term.rt.editor_doc.?.file.content);

    // 종류가 바뀐다 — 여기서 묶음이 끊겨야 한다.
    try testing.expect(deleteText(fx.session, term, true));
    try testing.expectEqualStrings("AB1\n", term.rt.editor_doc.?.file.content);

    // **끊겼으면** undo 한 번이 지우기만 되돌린다. 안 끊겼으면 삽입까지 함께 돌아가 "AB\n"이 된다 —
    // 길이가 셋으로 갈리므로 애매하지 않다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("AB12\n", term.rt.editor_doc.?.file.content);
}

test "UNDO10 손을 뗐다 다시 치면 묶음이 끊긴다 — 시간 경과 (§3.3)" {
    // §3.3의 셋 중 마지막. 시계를 앞으로 돌릴 수 없으므로 **앞 편집의 시각을 과거로 적어** 같은
    // 조건을 만든다 — `sameUndoGroup`이 재는 것이 정확히 그 차이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u10.txt", "AB\n");

    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(insertText(fx.session, term, "1"));

    // 간격을 넘긴다(경계보다 확실히 크게).
    term.rt.editor_last_edit_ms -|= undo_group_gap_ms + 50;
    try testing.expect(insertText(fx.session, term, "2"));
    try testing.expectEqualStrings("AB12\n", term.rt.editor_doc.?.file.content);

    // 끊겼으므로 뒤에 친 것만 돌아간다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("AB1\n", term.rt.editor_doc.?.file.content);
}

test "UNDO3 커서가 움직이면 묶음이 끊긴다 — 클릭 전 타이핑은 남는다 (§3.3)" {
    // **안 끊으면 클릭해서 다른 곳에 친 글자를 되돌릴 때 앞의 타이핑까지 사라진다.**
    // 사용자가 예측할 수 없는 종류다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u3.txt", "AB\n");

    term.rt.editor_selection = editor_selection.Selection.at(1);
    try testing.expect(insertText(fx.session, term, "1"));

    // 커서를 옮긴다 — 클릭이 하는 일과 같다.
    breakUndoGroup(term);
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "2"));
    try testing.expectEqualStrings("2A1B\n", term.rt.editor_doc.?.file.content);

    // 첫 undo는 **뒤엣것만** 되돌린다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("A1B\n", term.rt.editor_doc.?.file.content);
    // 두 번째가 앞엣것을 되돌린다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("AB\n", term.rt.editor_doc.?.file.content);
}

test "UNDO4 되돌린 것을 다시 할 수 있다 (§3.3)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u4.txt", "base\n");

    term.rt.editor_selection = editor_selection.Selection.at(4);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("base\n", term.rt.editor_doc.?.file.content);

    try testing.expect(redoEdit(fx.session, term));
    try testing.expectEqualStrings("base!\n", term.rt.editor_doc.?.file.content);
    // 더 다시 할 것이 없으면 거절한다.
    try testing.expect(!redoEdit(fx.session, term));
}

test "UNDO5 되돌린 뒤 새로 편집하면 redo가 버려진다 (§3.3)" {
    // **안 버리면 존재한 적 없는 상태로 갈 수 있다** — 되돌리고 다른 것을 친 뒤 redo를 누르면
    // 두 편집이 겹친 문서가 나온다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u5.txt", "seed\n");

    term.rt.editor_selection = editor_selection.Selection.at(4);
    try testing.expect(insertText(fx.session, term, "A"));
    try testing.expect(undoEdit(fx.session, term));

    breakUndoGroup(term);
    try testing.expect(insertText(fx.session, term, "B"));
    try testing.expectEqualStrings("seedB\n", term.rt.editor_doc.?.file.content);

    // redo 스택이 비었다.
    try testing.expect(!redoEdit(fx.session, term));
    try testing.expectEqualStrings("seedB\n", term.rt.editor_doc.?.file.content);
}

test "UNDO6 멀티커서 편집은 undo 한 번에 전부 돌아간다 (§3.3)" {
    // **§3.3: "멀티 selection의 동시 편집은 언제나 하나."** 커서마다 항목이 쌓이면 사용자가 커서
    // 수만큼 눌러야 하고, 중간까지만 되돌린 상태는 **문서에 존재한 적 없는 상태**다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u6.txt", "aa bb aa cc aa\n");

    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 2, 2, .word);
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    try testing.expect(insertText(fx.session, term, "ZZ"));
    try testing.expectEqualStrings("ZZ bb ZZ cc ZZ\n", term.rt.editor_doc.?.file.content);

    // **한 번**에 셋 다 돌아간다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("aa bb aa cc aa\n", term.rt.editor_doc.?.file.content);

    // 커서도 셋 그대로 돌아온다 — 편집 전 배열을 통째로 되살리는 것이 §3.3의 계약이다.
    var iter = selections(term);
    try testing.expectEqual(@as(usize, 3), iter.count());

    // redo도 한 번에 간다.
    try testing.expect(redoEdit(fx.session, term));
    try testing.expectEqualStrings("ZZ bb ZZ cc ZZ\n", term.rt.editor_doc.?.file.content);
}

test "UNDO7 스택 상한을 넘겨도 죽지 않고 새지 않는다 (§3.3)" {
    // **누수는 단언이 아니라 검출기가 잡는다** — `Inverse`가 할당을 소유하므로 스택을 자르는
    // 자리에서 한 번만 빠뜨려도 샌다. 상한을 실제로 넘겨 그 경로를 밟는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "u7.txt", "start\n");

    term.rt.editor_selection = editor_selection.Selection.at(5);
    var i: usize = 0;
    while (i < 2600) : (i += 1) { // 상한(2048)을 넘긴다
        breakUndoGroup(term); // 항목마다 따로 쌓이게 한다
        _ = insertText(fx.session, term, "z");
    }
    try testing.expect(term.rt.editor_undo_len <= 2048);
    // 남은 것으로 되돌릴 수 있다(잘린 뒤에도 스택이 성립한다).
    try testing.expect(undoEdit(fx.session, term));
}

test "EDIT3 읽기 전용 문서와 비교 뷰는 타이핑을 거절한다 (§3.5)" {
    // **화면만 바뀌고 저장이 실패하면 사용자가 편집을 잃는다.** L2가 이미 거절하지만(EDOC6),
    // 제품이 그 앞에서 막지 않으면 실패 경로가 사용자에게 "아무 일도 안 일어남"으로 보인다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "ro.txt", .data = "locked\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "ro.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    term.rt.editor_selection = editor_selection.Selection.at(0);

    // 문서를 읽기 전용으로 만든다(권한 대신 상태를 직접 세운다 — 권한은 OS에 달렸다).
    term.rt.editor_doc.?.file.read_only = true;
    try testing.expect(!insertText(fx.session, term, "x"));
    try testing.expectEqualStrings("locked\n", term.rt.editor_doc.?.file.content);

    // **비교 뷰 축은 이름만 있고 재지 않았다**(적대적 검증 2026-08-26 — 이 판정자의 이름이
    // "읽기 전용 문서와 **비교 뷰**는"인데 비교 뷰 분기를 지운 뮤턴트가 살아남았다).
    //
    // 비교 뷰는 좌우 **두 축**이라 커서 offset 하나로는 어디를 가리키는지 정해지지 않는다(§4.1g).
    // 편집을 받으면 왼쪽 문서에 들어가고 화면은 오른쪽을 그리는 식으로 어긋난다.
    term.rt.editor_doc.?.file.read_only = false;
    // **caret을 지울 것이 있는 자리에 둔다.** 문서 처음에 두면 `deleteText`가 비교 뷰 때문이
    // 아니라 "지울 것이 없어서" false를 내고, 그러면 이 판정자가 비교 뷰를 재는 척만 한다
    // (적대적 검증 2026-08-26 — 그 상태로 뮤턴트가 살아남았다).
    term.rt.editor_selection = editor_selection.Selection.at(3);

    // **되돌릴 것을 먼저 쌓는다.** 스택이 비면 `undoEdit`이 비교 뷰 때문이 아니라 "되돌릴 것이
    // 없어서" false를 내고, 그러면 그 축을 재는 척만 한다(적대적 검증 2026-08-26 — 그 상태로
    // 뮤턴트가 두 번 살아남았다).
    try testing.expect(insertText(fx.session, term, "Q"));
    const after_edit = try allocator.dupe(u8, term.rt.editor_doc.?.file.content);
    defer allocator.free(after_edit);

    term.rt.editor_diff = .{}; // 네 상태 중 `loading` — 문서는 그대로 열려 있다
    defer term.rt.editor_diff = null; // 픽스처 해체가 비교 상태를 따로 풀지 않게 되돌린다
    try testing.expect(!insertText(fx.session, term, "x"));
    try testing.expect(!deleteText(fx.session, term, true));
    try testing.expect(!addNextOccurrence(fx.session, term));
    try testing.expect(!saveDocument(fx.session, term));
    // **되돌리기도 같은 축이다.** 비교 뷰에서 undo가 돌면 화면은 오른쪽을 그리는데 왼쪽 문서가
    // 바뀐다 — 다섯 경로 중 이것만 판정자가 없어 뮤턴트가 살아남았다(적대적 검증 2026-08-26).
    try testing.expect(!undoEdit(fx.session, term));
    try testing.expect(!redoEdit(fx.session, term));
    // **이동도 같은 축이다**(적대적 검증 2026-08-26 — 이 목록에 없어서 뮤턴트가 살아남았다).
    // 비교 뷰는 좌우 두 축이라 커서 offset 하나가 어느 쪽을 가리키는지 정해지지 않는다 —
    // 옮기면 화면은 오른쪽을 그리는데 왼쪽 문서 기준으로 움직인다.
    try testing.expect(!moveCarets(fx.session, term, .char_right, false));
    try testing.expect(!moveCarets(fx.session, term, .line_down, false));
    try testing.expectEqualStrings(after_edit, term.rt.editor_doc.?.file.content);
}

test "COL4 시각 좌표를 든 것은 함께 죽는다 — 탭 폭·랩·접힘 (§3.2a)" {
    // **`setEditorTabWidth` 가 이것을 안 하고 있었다**(적대적 검증 2026-09-05). 계약의 무효화 목록에도
    // 탭 폭이 빠져 있었다 — 계약과 코드가 같은 구멍이었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "iv.txt", .data = "\tabc\n\tdef\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "iv.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // 사각형과 목표 열을 **둘 다** 세워 둔다 — 하나만 재면 나머지가 조용히 남는다.
    const seed: editor_selection.ColumnAnchor = .{ .from_row = 0, .from_col = 2, .to_row = 1, .to_col = 4 };
    term.rt.editor_column_anchor = seed;
    term.rt.editor_selection = editor_selection.Selection.at(0);
    term.rt.editor_selection.?.goal = .{ .col = 7 };
    term.rt.editor_selection.?.anchor_goal = .{ .col = 3 };

    // ⑴ **탭 폭이 바뀌면 둘 다 죽는다.** 탭 하나가 4열이냐 8열이냐가 시각 열을 통째로 바꾼다.
    setEditorTabWidth(fx.session, term, 8);
    try testing.expectEqual(@as(?editor_selection.ColumnAnchor, null), term.rt.editor_column_anchor);
    try testing.expectEqual(editor_selection.Goal.none, term.rt.editor_selection.?.goal);
    try testing.expectEqual(editor_selection.Goal.none, term.rt.editor_selection.?.anchor_goal);

    // ⑵ **랩 토글도 같은 사건이다** — 시각 행·열이 통째로 바뀐다.
    term.rt.editor_column_anchor = seed;
    term.rt.editor_selection.?.goal = .{ .col = 7 };
    _ = toggleWrap(fx.session);
    try testing.expectEqual(@as(?editor_selection.ColumnAnchor, null), term.rt.editor_column_anchor);
    try testing.expectEqual(editor_selection.Goal.none, term.rt.editor_selection.?.goal);
}

test "COL7 키보드 확장 — from 은 고정이고 오른쪽 상한은 가장 긴 줄이다 (§3.2a)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "ks.txt", .data = "abcd\nef\nghij\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "ks.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // ⑴ **사각형이 없으면 caret 에서 만든다** — 키만으로 시작할 수 있어야 한다.
    term.rt.editor_selection = editor_selection.Selection.at(1); // 1번 줄 1열
    try testing.expect(columnSelectStep(fx.session, term, .down));
    const a1 = term.rt.editor_column_anchor orelse return error.NoAnchor;
    try testing.expectEqual(@as(u32, 0), a1.from_row);
    try testing.expectEqual(@as(u32, 1), a1.to_row);
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len); // 두 줄

    // ⑵ **`from` 은 고정이다** — 또 내려도 시작 모서리가 안 따라온다(따라오면 「옮기는」 것이다).
    _ = columnSelectStep(fx.session, term, .down);
    try testing.expectEqual(@as(u32, 0), term.rt.editor_column_anchor.?.from_row);
    try testing.expectEqual(@as(u32, 2), term.rt.editor_column_anchor.?.to_row);

    // ⑶ **오른쪽 상한은 걸친 줄 중 가장 긴 줄의 끝**(여기선 'abcd'·'ghij' 의 4열).
    //    없으면 오른쪽 키가 영원히 먹혀 되돌리는 데 그만큼 왼쪽을 눌러야 한다.
    var guard: usize = 0;
    while (guard < 20) : (guard += 1) _ = columnSelectStep(fx.session, term, .right);
    try testing.expectEqual(@as(u32, 4), term.rt.editor_column_anchor.?.to_col);

    // ⑷ **`⇧⌥⌘` 방향키를 실제로 눌러야 그것이 도달한다**(C17·C18). resolver 와 디스패치를 안 재면
    //    chord 를 표에서 빼도, 디스패치가 방향을 바꿔도 위 단언이 전부 초록이다.
    {
        const resolver = fx.session.loaded_config.keyBindingResolver();
        var enc: [32]u8 = undefined;
        const down: maru.terminal.KeyEvent = .{
            .key = .arrow_down,
            .modifiers = .{ .command = true, .option = true, .shift = true },
        };
        switch (try resolver.resolve(down, &enc, .{})) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.column_select_down, a),
            else => return error.ChordNotWired,
        }
        // 키를 눌러 **아래로** 늘어나는지 — 디스패치가 `.up` 을 부르면 줄어든다.
        term.rt.editor_column_anchor = .{ .from_row = 0, .from_col = 0, .to_row = 0, .to_col = 0 };
        term.rt.editor_selection = editor_selection.Selection.at(0);
        _ = try fx.session.handleKeyEvent(down);
        try testing.expectEqual(@as(u32, 1), term.rt.editor_column_anchor.?.to_row);
    }

    // ⑸ **문서 끝에서 멈춘다.** 마지막 개행 뒤 빈 줄도 한 줄이라 `lineCount() - 1` 이 끝이다.
    guard = 0;
    while (guard < 20) : (guard += 1) _ = columnSelectStep(fx.session, term, .down);
    const doc = term.rt.editor_doc orelse return error.NoDoc;
    try testing.expectEqual(@as(u32, @intCast(doc.file.lines.lineCount() - 1)), term.rt.editor_column_anchor.?.to_row);
}

test "COL6 드래그 종단 — ⌥ 와 ⇧⌥ 둘 다 사각형을 세우고 커서가 는다 (§3.2a·§9.1)" {
    // **파생만 재면 배선이 빠져도 초록이다** — `mods` 전달·좌표 변환·드래그 갱신 중 하나만 빠져도
    // `COL1`~`COL5` 는 전부 통과한다. `MC8`·`BR6`·`AC3` 이 선 그 자리다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "cd.txt", .data = "aaaaaaaa\nbbbbbbbb\ncccccccc\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "cd.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **렌더가 스냅숏을 굳혀야 `hitTestBody` 가 답한다**(§4.1g) — `tick` 만으로는 안 선다.
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const g = term.rt.editor_hit_geom;
    const text_x0: i32 = @as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(g.content_left_px));
    const top_y: i32 = @as(i32, @intCast(body.y)) + inset;
    const pane = pane_ops.activePane(fx.session);

    const x0: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(1 * @as(u32, g.cell_w_px))));
    const y0: f64 = @floatFromInt(top_y + 1);
    const x2: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(4 * @as(u32, g.cell_w_px))));
    const y2: f64 = @floatFromInt(top_y + 1 + @as(i32, @intCast(2 * @as(u32, g.cell_h_px))));

    // ⑴ **`⌥`(mods 8) 로 시작하면 사각형이 선다** — 터미널 관례.
    try testing.expect(beginBodySelection(fx.session, pane, x0, y0, 8));
    try testing.expect(term.rt.editor_column_anchor != null);
    _ = dragBodySelection(fx.session, 2, x2, y2);
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len); // 세 줄
    // **열 방향도 늘어난다** — 줄 수만 재면 `to_col` 갱신을 지운 변이가 산다(C13). 세 열을 끌었으므로
    // 각 selection 이 빈 caret 이 아니라 **범위**여야 한다.
    try testing.expect(term.rt.editor_selection.?.anchorLo() != term.rt.editor_selection.?.focus);
    try testing.expect(term.rt.editor_column_anchor.?.to_col > term.rt.editor_column_anchor.?.from_col);

    // ⑵ **`⇧⌥`(4|8) 도 같은 결과** — VSCode 관례. 둘이 갈리면 설정이 필요해진다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_column_anchor = null;
    try testing.expect(beginBodySelection(fx.session, pane, x0, y0, 4 | 8));
    try testing.expect(term.rt.editor_column_anchor != null);
    _ = dragBodySelection(fx.session, 2, x2, y2);
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    // ⑶ **모디파이어가 없으면 사각형이 안 선다** — 일반 선택이다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_column_anchor = null;
    try testing.expect(beginBodySelection(fx.session, pane, x0, y0, 0));
    try testing.expectEqual(@as(?editor_selection.ColumnAnchor, null), term.rt.editor_column_anchor);
}

test "AC1 위/아래로 커서가 늘고 원본이 남는다 — 선택 모양도 유지된다 (§3.2b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 줄 길이를 **일부러 다르게** 둔다 — 같으면 「목표 열을 썼나」와 「그냥 offset 을 더했나」가 겹친다.
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "ac.txt", .data = "aaaaaaaa\nbb\ncccccccc\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "ac.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // ① **caret 하나에서 아래로 — 원본이 남고 하나가 는다.**
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(addCursorVertically(fx.session, term, true));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    // primary 는 **새로 생긴 쪽**이다(§3.2) — 그래야 화면이 따라간다.
    try testing.expect(term.rt.editor_selection.?.focus > 0);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections[0].focus); // 원본은 남는다

    // ①' **위로도 잰다.** 아래로만 재면 방향 인자를 무시하는 변이(A10)와 primary 를 반대쪽에서
    //     고르는 변이(A6)가 그대로 산다 — 커서가 둘뿐이면 「위」와 「아래」가 픽스처에서 겹친다.
    //     셋째 줄에서 **위로** 더하면 사본이 원본보다 **앞**에 서야 하고 primary 가 그 사본이다.
    clearExtraSelections(fx.session, term);
    const third_line = 12; // "aaaaaaaa\nbb\n" 다음이 'cccccccc'
    term.rt.editor_selection = editor_selection.Selection.at(third_line);
    try testing.expect(addCursorVertically(fx.session, term, false));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expect(term.rt.editor_selection.?.focus < third_line); // primary 는 **위**쪽 사본
    try testing.expectEqual(@as(usize, third_line), term.rt.editor_extra_selections[0].focus);

    // ①'' **커서가 둘일 때 primary 방향을 잰다.** 사본이 하나뿐이면 primary 를 고르는 루프가
    //      **0회 돌아** 방향을 뒤집는 변이(A6)가 그대로 산다 — `k = original_len + 1` 부터다.
    //      1·2번 줄에 커서를 두고 **위로** 더하면 primary 는 **가장 위** 사본이어야 한다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.at(9); // 2번 줄
    {
        const extras = try allocator.alloc(editor_selection.Selection, 1);
        extras[0] = editor_selection.Selection.at(12); // 3번 줄
        if (term.rt.editor_extra_selections.len > 0) allocator.free(term.rt.editor_extra_selections);
        term.rt.editor_extra_selections = extras;
    }
    try testing.expect(addCursorVertically(fx.session, term, false));
    // 사본 둘(1번 줄·2번 줄) 중 **위쪽**이 primary 다. 2번 줄 사본을 고르면 9 가 나온다.
    try testing.expect(term.rt.editor_selection.?.focus < 9);

    // ② **범위를 고른 상태면 같은 모양이 생긴다** — anchor 와 focus 를 각자 옮긴다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.fromPoints(1, 4); // 'aaa' 세 글자
    try testing.expect(addCursorVertically(fx.session, term, true));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    const added = term.rt.editor_selection.?;
    try testing.expect(added.anchorLo() != added.focus); // caret 으로 찌그러지지 않았다

    // ②' **겹치면 합친다**(§3.2). 이웃한 두 줄에 커서를 두고 아래로 더하면 위 커서의 사본이
    //     아래 커서와 **같은 자리**에 온다 — 넷이 아니라 셋이 되어야 한다. 병합을 빼도 안 잡히던
    //     구멍이다(변이 A7).
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.at(0); // 1번 줄
    {
        const extras = try allocator.alloc(editor_selection.Selection, 1);
        extras[0] = editor_selection.Selection.at(9); // 2번 줄 'bb'
        if (term.rt.editor_extra_selections.len > 0) allocator.free(term.rt.editor_extra_selections);
        term.rt.editor_extra_selections = extras;
    }
    try testing.expect(addCursorVertically(fx.session, term, true));
    // 원본 둘 + 사본 둘 = 넷인데 하나가 겹쳐 **셋**이다(primary 1 + extras 2).
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    // ②'' **사본이 목표 열을 이어받는다**(§3.2). 안 넘기면 다음 세로 이동이 **현재 열에서** 시작해
    //      짧은 줄을 지나 돌아올 때 열을 잃는다(변이 A11). 1번 줄 8열에서 아래로 더하면 사본은
    //      짧은 2번 줄('bb')에 서는데, 그 사본이 목표 열 8 을 들고 있어야 3번 줄에서 8열로 돌아온다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.at(8); // 1번 줄 끝(8열)
    try testing.expect(addCursorVertically(fx.session, term, true));
    const short_copy = term.rt.editor_selection.?;
    try testing.expect(short_copy.goal != .none); // 목표 열을 들고 있다
    // 그 사본을 한 줄 더 내리면 긴 3번 줄에서 **8열로 돌아온다**.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = short_copy;
    _ = moveCarets(fx.session, term, .line_down, false);
    try testing.expectEqual(@as(usize, 12 + 8), term.rt.editor_selection.?.focus);

    // ③ **문서 끝에서는 안 는다** — clamp 하면 원본과 겹쳐 병합이 지운다(§3.2b).
    clearExtraSelections(fx.session, term);
    const content_len = term.rt.editor_doc.?.file.content.len;
    term.rt.editor_selection = editor_selection.Selection.at(content_len);
    try testing.expect(!addCursorVertically(fx.session, term, true));
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections.len);
}

test "AC4 커서 수 상한을 넘겨 더하지 않는다 (§3.2·§3.2b)" {
    // **상한 분기를 지워도 안 잡혔다**(변이 A4) — 픽스처가 `max_cursors` 근처를 안 갔다.
    // 상한이 없으면 큰 파일에서 키를 누르고 있을 때 커서가 파일 크기만큼 자라 입력이 멈춘다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 줄이 많아야 위로 더할 곳이 있다 — 상한보다 넉넉히.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var n: usize = 0;
    while (n < editor_selection.max_cursors * 3) : (n += 1) try buf.appendSlice(allocator, "x\n");
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "big.txt", .data = buf.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "big.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // 상한 **바로 아래**까지 커서를 채운다 — 마지막 줄들에 하나씩.
    // **한 줄씩 띄운다.** 붙여 두면 각 사본이 다음 커서와 정확히 겹쳐 **전부 병합돼** 상한에
    //     닿지 않는다 — 그러면 상한 분기를 지워도 결과가 같아 변이가 산다(A4 가 그랬다).
    const fill = editor_selection.max_cursors - 1;
    const extras = try allocator.alloc(editor_selection.Selection, fill - 1);
    for (extras, 0..) |*e, i| e.* = editor_selection.Selection.at((i + 1) * 4);
    if (term.rt.editor_extra_selections.len > 0) allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = extras;
    term.rt.editor_selection = editor_selection.Selection.at(0);

    _ = addCursorVertically(fx.session, term, true);
    // **넘지 않는다.** primary 1 + extras 가 상한 이하여야 한다.
    try testing.expect(term.rt.editor_extra_selections.len + 1 <= editor_selection.max_cursors);
}

test "AC2 게이트 넷 — 편집기 아님·비교 뷰·문서 없음·커서 없음 (§3.2b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "g.txt", .data = "aa\nbb\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "g.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();
    term.rt.editor_selection = editor_selection.Selection.at(0);

    // ① 편집기가 아닌 Term
    const saved_kind = term.kind;
    term.kind = .terminal;
    try testing.expect(!addCursorVertically(fx.session, term, true));
    term.kind = saved_kind;

    // ② **비교 뷰** — 축이 둘이라 문서 offset 이 없다(§4.1g)
    term.rt.editor_diff = .{ .requested_ms = 0 };
    try testing.expect(!addCursorVertically(fx.session, term, true));
    term.rt.editor_diff = null;

    // ③ **커서가 없다** — 늘릴 씨앗이 없으므로 짐작하지 않는다
    term.rt.editor_selection = null;
    try testing.expect(!addCursorVertically(fx.session, term, true));

    // ④ **읽기 전용에서는 선다** — 문서를 안 바꾸고 멀티 커서 복사는 뜻이 있다(§3.4)
    term.rt.editor_selection = editor_selection.Selection.at(0);
    term.rt.editor_doc.?.file.read_only = true;
    defer term.rt.editor_doc.?.file.read_only = false;
    try testing.expect(addCursorVertically(fx.session, term, true));
}

test "AC3 ⌥⌘↑↓ 를 실제로 눌렀을 때 커서가 는다 — 배선 종단 (§3.2b)" {
    // 함수만 재면 chord 등록·액션 해석·디스패치 중 하나가 빠져도 AC1·AC2 는 초록이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_ = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io_, .{ .sub_path = "w.txt", .data = "aaaa\nbbbb\ncccc\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io_, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "w.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // ① **전역이 아니라 편집기 컨텍스트가 잡는다.** 전역으로 풀리면 pane 포커스가 옮겨진다.
    {
        const resolver = fx.session.loaded_config.keyBindingResolver();
        const down: maru.terminal.KeyEvent = .{ .key = .arrow_down, .modifiers = .{ .command = true, .option = true } };
        switch (resolver.resolveEditor(down, false)) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.add_cursor_below, a),
            else => return error.ChordNotWired,
        }
        // **비교 뷰에서는 전역으로 돌려준다** — 커서 추가에 뜻이 없으므로 pane 이동이 산다.
        switch (resolver.resolveEditor(down, true)) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.focus_pane_down, a),
            else => return error.ChordNotWired,
        }
    }

    // ② **키를 누르면 커서가 는다.**
    term.rt.editor_selection = editor_selection.Selection.at(0);
    fx.session.metal_dirty = false;
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down, .modifiers = .{ .command = true, .option = true } });
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expect(fx.session.metal_dirty);

    // ③ **팔레트에도 있다.**
    var above = false;
    var below = false;
    for (command_catalog.entries) |e| {
        if (e.action == .add_cursor_above) above = true;
        if (e.action == .add_cursor_below) below = true;
    }
    try testing.expect(above and below);
}

test "BR6 ⇧⌘\\ 를 실제로 눌렀을 때 caret 이 짝으로 간다 — 배선 종단 (§3.9c)" {
    // **`matchingBracket` 만 재면 배선이 빠져도 초록이다** — chord 등록·액션 해석·디스패치·
    // `moveCarets` 갈래 중 하나만 빠져도 기능이 없는 것과 같은데 BR1~BR5 는 전부 통과한다.
    // `MC8` 이 `⌘D` 에 대해 선 것과 같은 이유다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "br.txt", .data = "f((a))\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "br.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    _ = try fx.session.tick();

    // ⑴ **chord 두 벌이 다 그 액션이다** — '\\' 로 올 수도 '|' 로 올 수도 있다(OS/레이아웃 차이).
    {
        const resolver = fx.session.loaded_config.keyBindingResolver();
        var enc: [32]u8 = undefined;
        for ([_]u21{ '\\', '|' }) |ch| {
            const event: maru.terminal.KeyEvent = .{
                .key = .{ .char = ch },
                .modifiers = .{ .command = true, .shift = true },
            };
            switch (try resolver.resolve(event, &enc, .{})) {
                .app_action => |a| try testing.expectEqual(maru.config.action.Action.jump_to_bracket, a),
                else => return error.ChordNotWired,
            }
        }
    }

    // ⑵ **키를 누르면 caret 이 짝 앞으로 간다.** 'f((a))' 에서 offset 1 은 바깥 '(' 앞이다.
    //
    // **목표 열을 미리 세워 둔다.** `Selection.at` 의 goal 이 이미 `.none` 이라 그냥 두면 「버렸나」와
    // 「원래 없었나」가 픽스처에서 겹쳐, goal 을 안 버리는 변이(B9)가 그대로 산다 — 아래 단언이
    // 그것을 재려면 들어갈 때 `.none` 이 아니어야 한다.
    term.rt.editor_selection = editor_selection.Selection.at(1);
    term.rt.editor_selection.?.goal = .{ .col = 7 };
    fx.session.metal_dirty = false;
    _ = try fx.session.handleKeyEvent(.{
        .key = .{ .char = '\\' },
        .modifiers = .{ .command = true, .shift = true },
    });
    try testing.expectEqual(@as(usize, 5), term.rt.editor_selection.?.focus); // 바깥 ')' 앞
    try testing.expect(fx.session.metal_dirty);
    // **가로 이동이므로 목표 열을 버린다**(§3.2). 남기면 다음 위/아래 이동이 사용자가 방금 떠난
    // 열로 튄다 — 그 줄을 지운 변이(B9)가 살아남아 이 단언이 없었음을 보였다.
    try testing.expectEqual(editor_selection.Goal.none, term.rt.editor_selection.?.goal);

    // ⑶ **짝이 없으면 안 움직인다** — 'f' 자리는 괄호가 아니다(감싸는 괄호를 찾지 않는다).
    term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = try fx.session.handleKeyEvent(.{
        .key = .{ .char = '\\' },
        .modifiers = .{ .command = true, .shift = true },
    });
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);

    // ⑷ **팔레트에도 있다** — 키를 뺏긴 사용자가 명령으로 부를 수 있어야 한다.
    var found = false;
    for (command_catalog.entries) |e| {
        if (e.action == .jump_to_bracket) found = true;
    }
    try testing.expect(found);
}

test "MC8 ⌘⌃D를 실제로 눌렀을 때 커서가 는다 — 배선 전체를 통과한다 (§9.1)" {
    // **판정자 여섯이 전부 `addNextOccurrence`를 직접 부른다.** 그래서 그 함수가 아무리 옳아도
    // **키를 눌렀을 때 거기 도달하는지는 아무도 안 본다** — chord 등록, 액션 해석, 디스패치 중
    // 하나만 빠져도 기능이 없는 것과 같은데 판정자는 전부 초록이다. ⌘F 슬라이스가 같은 구조적
    // 구멍을 겪었고(EM* 판정자가 `appendPaneFrame`을 직접 불러 배선을 못 봤다), 그 교훈이 여기다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "wire.txt", .data = "alpha beta\nalpha gamma\nalpha delta\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "wire.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // ⑴ **chord가 액션으로 해석된다** — **편집기 컨텍스트** 표에 실려 있는가(2026-09-04: `⌘⌃D` 임시
    //    chord 를 `⌘D` 로 옮겼다 — §9.1 확정. 전역 표가 아니라 컨텍스트 표라 여기서 묻는 함수가 바뀐다).
    {
        const resolver = fx.session.loaded_config.keyBindingResolver();
        var enc: [maru.terminal.input.encoded_key_buffer_len]u8 = undefined;
        const event = maru.terminal.KeyEvent{
            .key = .{ .char = 'D' },
            .modifiers = .{ .command = true },
        };
        switch (resolver.resolveEditor(event, false)) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.add_next_occurrence, a),
            else => return error.ChordNotWired,
        }
        // **터미널에서는 그대로 좌우 분할이다** — 이 대가가 §9.1 의 결정 조건이고, 여기서 깨지면
        // "편집기를 열었더니 터미널에서 화면이 안 나뉜다" 가 된다.
        switch (try resolver.resolve(event, &enc, .{})) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.split_horizontal, a),
            else => return error.ChordNotWired,
        }
        // **비교 뷰에서도 분할이다** — 「다음 일치 추가」는 거기서 뜻이 없다.
        switch (resolver.resolveEditor(event, true)) {
            .app_action => |a| try testing.expectEqual(maru.config.action.Action.split_horizontal, a),
            else => return error.ChordNotWired,
        }
    }

    // ⑵ **디스패치가 그 액션을 편집기로 보낸다** — 함수를 직접 부르지 않는다.
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 5, 5, .word);
    fx.session.dispatchAppAction(.add_next_occurrence);
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expectEqual(@as(usize, 11), term.rt.editor_selection.?.start());

    fx.session.dispatchAppAction(.add_next_occurrence);
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    // ⑶ **고른 것이 없으면 아무 일도 안 한다** — 씨앗을 문서 머리로 짐작하면 사용자가 있지도 않은
    //    커서 자리를 강요당한다(변이 F2). 앞선 판이 실제로 `Selection.at(0)` 을 씨앗으로 썼다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = null;
    try testing.expect(!addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections.len);

    // ⑷ **편집기가 아닌 Term 은 받지 않는다** — 이 함수는 `editor_doc`·`editor_selection` 을 전제하고,
    //    호출자 게이트가 하나 빠지는 날 그 전제가 깨진다(변이 F3).
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 5, 5, .word);
    const saved_kind = term.kind;
    term.kind = .terminal;
    try testing.expect(!addNextOccurrence(fx.session, term));
    term.kind = saved_kind;

    // ⑸ **컨텍스트 키는 화면을 다시 그리게 한다** — 안 그러면 커서가 늘고도 다음 프레임까지 안 보인다.
    //    다만 디스패치 자리의 `metal_dirty = true` 를 지워도 이 단언은 안 깨진다(변이 F8 이 살아남는
    //    것이 정상이다) — 이 표의 **액션 넷이 전부 스스로 세우기 때문**이다(`toggleWrap`·
    //    `addNextOccurrence` 가 각자 끝에서, 복제·이동은 `applyLineEdit` 에서). 그럼에도 그 줄을 두는
    //    이유는 **다음 액션**이다: 편집기는 PTY 출력이 없어 아무도 프레임을 안 깨우므로, 스스로 안
    //    세우는 액션이 이 표에 하나 붙는 날 그 키는 **눌러도 화면이 그대로**다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 5, 5, .word);
    fx.session.metal_dirty = false;
    _ = try fx.session.handleKeyEvent(.{ .key = .{ .char = 'd' }, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expect(fx.session.metal_dirty);

    // ⑹ **팔레트에도 있다** — 키를 뺏긴 사용자가 명령으로 부를 수 있어야 한다.
    var found = false;
    for (command_catalog.entries) |e| {
        if (e.action == .add_next_occurrence) found = true;
    }
    try testing.expect(found);
}

fn pressKey(fx: *PaneFixture, key: maru.terminal.input.Key, mods: maru.terminal.input.ModifierSet) !void {
    _ = try fx.session.handleKeyEvent(.{ .key = key, .modifiers = mods });
}

test "MOV1 화살표가 커서를 옮긴다 — 키 경로 전체를 통과한다 (§3.2)" {
    // **함수를 직접 부르면 배선이 빠져도 통과한다.** `MC1`이 그렇게 통과하고도 chord가 안 붙어
    // 있었다(2026-08-25). 그래서 여기서는 **키를 눌러** `handleKeyEvent`부터 지난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov1.txt", "ab\ncd\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    // 먼저 **직접 부르는 경로**가 되는지 본다 — 여기가 되는데 키가 안 되면 배선 문제로 좁혀진다.
    try testing.expect(moveCarets(fx.session, term, .char_right, false));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_selection.?.focus);
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(pane_ops.activePane(fx.session).activeTerm() == term); // 활성 Term이 편집기인가
    try pressKey(&fx, .arrow_right, .{});
    try testing.expectEqual(@as(usize, 1), term.rt.editor_selection.?.focus);

    try pressKey(&fx, .arrow_left, .{});
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);

    // 아래로 — 둘째 줄 같은 열(0)이다.
    try pressKey(&fx, .arrow_down, .{});
    try testing.expectEqual(@as(usize, 3), term.rt.editor_selection.?.focus);

    // 문서 처음에서 왼쪽은 **아무 일도 안 한다** — 없으면 매 키가 "옮겼다"고 보고해 화면이 계속 더러워진다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!moveCarets(fx.session, term, .char_left, false));
}

test "MOV2 Shift가 선택을 늘리고, 맨몸 이동은 선택을 접는다 (§3.2)" {
    // **Shift가 anchor를 안 남기면 선택이 안 생긴다.** 반대로 맨몸 이동이 선택을 안 접으면
    // 사용자가 선택을 없앨 방법이 없다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov2.txt", "abcdef\n");

    term.rt.editor_selection = editor_selection.Selection.at(2);
    try pressKey(&fx, .arrow_right, .{ .shift = true });
    try pressKey(&fx, .arrow_right, .{ .shift = true });
    const sel = term.rt.editor_selection.?;
    try testing.expectEqual(@as(usize, 2), sel.start());
    try testing.expectEqual(@as(usize, 4), sel.end());

    // 맨몸 이동은 **접는다**.
    try pressKey(&fx, .arrow_right, .{});
    try testing.expect(term.rt.editor_selection.?.isEmpty());
}

test "MOV3 세로 이동이 목표 열을 지킨다 — 짧은 줄을 지나도 돌아온다 (§3.2)" {
    // `MOT4`가 순수 계산으로 재는 것을 **제품 경로**에서 다시 잰다 — 목표를 selection에 저장하고
    // 다음 이동까지 들고 있는 것은 이쪽 책임이라, L2가 맞아도 여기서 버리면 증상이 그대로 난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov3.txt", "0123456789\nab\n0123456789\n");

    term.rt.editor_selection = editor_selection.Selection.at(7); // 첫 줄 7열
    try pressKey(&fx, .arrow_down, .{}); // 짧은 줄 → 줄 끝(13)
    try testing.expectEqual(@as(usize, 13), term.rt.editor_selection.?.focus);
    try pressKey(&fx, .arrow_down, .{}); // 다시 긴 줄 → **7열로 돌아온다**
    try testing.expectEqual(@as(usize, 21), term.rt.editor_selection.?.focus);

    // **가로 이동은 목표를 버린다** — 안 버리면 다음 세로 이동이 편집 전 열로 튄다.
    try pressKey(&fx, .arrow_left, .{});
    try pressKey(&fx, .arrow_up, .{});
    try pressKey(&fx, .arrow_up, .{});
    try testing.expectEqual(@as(usize, 6), term.rt.editor_selection.?.focus);
}

test "MOV4 커서가 여럿이면 전부 움직이고, 겹치면 그대로 둔다 (§3.2·§9.1)" {
    // **하나만 옮기면 나머지가 제자리에 남아 다음 타이핑이 두 축으로 갈린다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov4.txt", "aa aa aa\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 2);
    extras[0] = editor_selection.Selection.at(3);
    extras[1] = editor_selection.Selection.at(6);
    term.rt.editor_extra_selections = extras;

    try pressKey(&fx, .arrow_right, .{});
    try testing.expectEqual(@as(usize, 1), term.rt.editor_selection.?.focus);
    try testing.expectEqual(@as(usize, 4), term.rt.editor_extra_selections[0].focus);
    try testing.expectEqual(@as(usize, 7), term.rt.editor_extra_selections[1].focus);
}

test "MOV5 이동이 undo 묶음을 끊는다 — 옮겨서 친 글자는 따로 돌아간다 (§3.3)" {
    // §3.3이 묶음을 끊는 이유 셋 중 **커서 이동**이다. `UNDO3`은 클릭으로 재는데, 키 이동은
    // 다른 경로라 따로 잰다 — 안 끊으면 옮겨서 친 글자를 되돌릴 때 앞의 타이핑까지 사라진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov5.txt", "AB\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "1"));
    try pressKey(&fx, .arrow_right, .{}); // 커서를 옮긴다 → 묶음이 끊긴다
    try testing.expect(insertText(fx.session, term, "2"));
    try testing.expectEqualStrings("1A2B\n", term.rt.editor_doc.?.file.content);

    // undo 한 번은 **뒤에 친 것만** 되돌린다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("1AB\n", term.rt.editor_doc.?.file.content);
}

test "MOV7 수정자가 이동 단위를 가른다 — ⌥는 낱말, ⌘는 줄·문서 (§3.2)" {
    // **`MOV1`은 맨몸 화살표만 눌러서 수정자 매핑을 안 쟀다** — `⌥←`·`⌘←`를 문자 이동으로 바꾼
    // 뮤턴트가 살아남았다(적대적 검증 2026-08-26). 매핑이 어긋나면 사용자는 낱말 단위로 가려다
    // 한 글자씩 가고, 그 차이는 조용하다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov7.txt", "    foo bar\nnext\n");

    // ⌥→ 는 **낱말** 단위다(문자면 5에 선다).
    term.rt.editor_selection = editor_selection.Selection.at(4);
    try pressKey(&fx, .arrow_right, .{ .option = true });
    try testing.expectEqual(@as(usize, 8), term.rt.editor_selection.?.focus);

    // ⌥← 는 거울이다.
    try pressKey(&fx, .arrow_left, .{ .option = true });
    try testing.expectEqual(@as(usize, 4), term.rt.editor_selection.?.focus);

    // ⌘← 는 **smart home** — 들여쓰기 뒤 첫 글자(4)로, 이미 거기면 줄 머리(0)로.
    term.rt.editor_selection = editor_selection.Selection.at(7);
    try pressKey(&fx, .arrow_left, .{ .command = true });
    try testing.expectEqual(@as(usize, 4), term.rt.editor_selection.?.focus);
    try pressKey(&fx, .arrow_left, .{ .command = true });
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);

    // ⌘→ 는 줄 끝(개행 **앞**)이다.
    try pressKey(&fx, .arrow_right, .{ .command = true });
    try testing.expectEqual(@as(usize, 11), term.rt.editor_selection.?.focus);

    // ⌘↓ 는 문서 끝, ⌘↑ 는 문서 처음이다 — 한 줄 이동이 아니다.
    try pressKey(&fx, .arrow_down, .{ .command = true });
    try testing.expectEqual(term.rt.editor_doc.?.file.content.len, term.rt.editor_selection.?.focus);
    try pressKey(&fx, .arrow_up, .{ .command = true });
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);

    // Home/End도 같은 단위를 연다(키보드마다 있는 쪽이 다르다).
    term.rt.editor_selection = editor_selection.Selection.at(7);
    try pressKey(&fx, .end, .{});
    try testing.expectEqual(@as(usize, 11), term.rt.editor_selection.?.focus);
    try pressKey(&fx, .home, .{});
    try testing.expectEqual(@as(usize, 4), term.rt.editor_selection.?.focus);
}

test "DIRTY1 저장과 다르면 dirty, undo로 같은 내용에 돌아오면 clean (file-panel.md §1)" {
    // **계약은 개정 번호가 아니라 내용 동등성이다** — `file-panel.md` §1이 소유한다:
    // *"편집 뒤 undo로 snapshot과 같은 내용에 돌아오면 revision이 더 높아도 clean"*.
    //
    // 개정 번호로 재면 열 번 고치고 열 번 되돌린 문서가 dirty로 남아, 사용자가 **바꾼 것이 없는데
    // 저장하라는 표시**를 본다. 그래서 이 판정자의 가운데가 그 왕복이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty1.txt", "hello\n");

    // 여는 순간은 clean이다.
    try testing.expect(!term.rt.editor_doc.?.isDirty());
    const rev0 = term.rt.editor_doc.?.file.revision;

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(term.rt.editor_doc.?.isDirty());

    // **되돌리면 clean이다 — 개정 번호는 더 높다.**
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("hello\n", term.rt.editor_doc.?.file.content);
    try testing.expect(term.rt.editor_doc.?.file.revision > rev0); // 되감지 않는다
    try testing.expect(!term.rt.editor_doc.?.isDirty()); // **그래도 clean**

    // 다시 고치면 dirty, 저장하면 clean.
    try testing.expect(insertText(fx.session, term, "?"));
    try testing.expect(term.rt.editor_doc.?.isDirty());
    try testing.expect(saveDocument(fx.session, term));
    try testing.expect(!term.rt.editor_doc.?.isDirty());

    // **저장 뒤 되돌리면 다시 dirty다** — 이제 디스크와 다르다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expect(term.rt.editor_doc.?.isDirty());
}

test "CUT1 ⌘X가 잘라내고, 선택이 없으면 줄 전체다 (§3.4)" {
    // **복사·붙여넣기만 있고 잘라내기가 없으면 반쪽이다.** 그리고 `⌘C`(`copyText`)·`⌘V`
    // (`pasteText`)와 달리 잘라내기는 Swift 진입점이 없어 **키 분기에서 잡아야** 한다 —
    // 주소창이 `addrEditCut`을 자기 키 처리기에서 부르는 것과 같은 자리다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cut1.txt", "alpha\nbeta\n");

    // ⑴ 선택이 있으면 그것만 잘라낸다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5); // "alpha"
    try pressKey(&fx, .{ .char = 'x' }, .{ .command = true });
    try testing.expectEqualStrings("\nbeta\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqualStrings("alpha", fx.session.chrome_clipboard_write);

    // **한 묶음이라 undo 한 번에 돌아온다.**
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("alpha\nbeta\n", term.rt.editor_doc.?.file.content);

    // ⑵ **선택이 없으면 줄 전체다** — 복사가 줄을 담으므로 지우는 것도 같은 범위여야
    //    "복사한 것이 사라졌다"가 성립한다.
    term.rt.editor_selection = editor_selection.Selection.at(2); // "alpha" 가운데
    try pressKey(&fx, .{ .char = 'x' }, .{ .command = true });
    try testing.expectEqualStrings("beta\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqualStrings("alpha\n", fx.session.chrome_clipboard_write);

    // ⑶ **복사가 실패하면 지우지 않는다.** 지우고 나서 복사가 실패하면 사용자는 **클립보드에도
    //    없고 문서에도 없는** 상태를 겪는다 — undo가 있지만 "잘라냈는데 붙여넣을 것이 없다"는
    //    그 자체로 계약 위반이다(적대적 검증 2026-08-26 — 복사 실패를 무시하는 뮤턴트가 살았다).
    //
    //    **커서를 없애는 방법으로는 갈리지 않는다** — 그 경우 뒤쪽 `orelse return false`가 어차피
    //    막아 두 식이 같은 답을 낸다(뮤턴트가 그 배치에서 살아남았다). 커서가 멀쩡한데 복사만
    //    실패하는 경우는 **할당 실패**뿐이므로, `EDIT6`처럼 실패 지점을 하나씩 밀며 잰다.
    {
        var reached: usize = 0;
        var step: usize = 0;
        while (step < 40) : (step += 1) {
            var failing = std.testing.FailingAllocator.init(allocator, .{});
            const alloc = failing.allocator();
            var fx2 = try PaneFixture.init(alloc);
            defer fx2.deinit(alloc);
            const t2 = undoFixture(&fx2, alloc, "cutfail.txt", "alpha\nbeta\n") catch continue;
            t2.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5);
            const before2 = allocator.dupe(u8, t2.rt.editor_doc.?.file.content) catch continue;
            defer allocator.free(before2);

            failing.fail_index = failing.allocations + step;
            const ok = cutSelection(fx2.session, t2);
            if (!ok) {
                reached += 1;
                // **실패했으면 문서가 그대로다** — 복사가 실패했는데 지우면 클립보드에도 없고
                // 문서에도 없는 상태가 된다.
                try testing.expectEqualStrings(before2, t2.rt.editor_doc.?.file.content);
            }
        }
        try testing.expect(reached > 0); // 한 번도 실패 안 했으면 이 갈래를 안 잰 것이다
    }

    // ⑷ 읽기 전용은 거절한다 — 복사만 하고 지우지 않는 것도 아니다(아예 무동작).
    term.rt.editor_doc.?.file.read_only = true;
    const before = term.rt.editor_doc.?.file.content;
    try testing.expect(!cutSelection(fx.session, term));
    try testing.expectEqualStrings(before, term.rt.editor_doc.?.file.content);
}

test "COPY4 복사 기억은 세션과 함께 사라진다 — 새지 않는다 (§3.4)" {
    // **복사 기억은 세션이 소유한다**(한 편집기에서 복사해 다른 편집기에 붙여넣는 것이 같은 규칙을
    // 타야 하므로 Term이 아니다). 소유가 세션이면 **해체도 세션이 한다** — 안 하면 복사할 때마다
    // 문자열 두 벌(클립보드 사본 + 경계)이 남는다.
    //
    // 편집기 판정자들은 대개 복사를 안 하고 끝나 **그 해제 경로를 안 지났다**(적대적 검증
    // 2026-08-26 — 해체에서 메타를 안 푸는 뮤턴트가 살아남았다). `testing.allocator`가 누수를
    // 잡으므로, 복사한 채로 픽스처를 해체하는 것만으로 판정이 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator); // ← 여기서 메타가 풀려야 한다
    const term = try undoFixture(&fx, allocator, "copy4.txt", "keep me\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 4);
    try testing.expect(copySelection(fx.session));
    try testing.expect(fx.session.editor_clipboard_meta != null);
    // **일부러 정리하지 않고 끝낸다** — 해체가 그것을 하는지가 이 판정자의 전부다.
}

test "COPY3 ⌘C가 편집기 선택을 복사한다 — 배선 전체를 통과한다 (§3.4)" {
    // **한쪽만 배선돼 있었다**(적대적 검증 2026-08-26): 붙여넣기는 `AppSession.pasteText`에 갈래를
    // 넣었는데 복사는 안 넣어, `⌘C`가 편집기에 **안 걸렸다**. `copySelection`은 명령 팔레트로만
    // 닿았다 — 사용자는 "붙여넣기는 되는데 복사가 안 된다"를 겪는다.
    //
    // 그리고 편집기에서 `⌘C`가 터미널 선택으로 흐르면 **화면 뒤 셸 출력**이 복사된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "copy3.txt", "alpha beta\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5); // "alpha"
    const copied = fx.session.copyText(); // ← Swift ⌘C가 부르는 자리
    try testing.expectEqualStrings("alpha", copied);

    // **조각 경계도 함께 선다** — 그 자리에서 `copySelection`을 부르기 때문이다. 두 저장소가
    // 갈리면 붙여넣기가 방금 복사한 것을 **남의 것**으로 본다.
    try testing.expect(maru.session.editor.clipboard.describes(
        fx.session.editor_clipboard_meta,
        fx.session.chrome_clipboard_write,
    ));

    // 선택이 없으면 **줄 전체**다(§3.4) — `⌘C` 경로도 같은 규칙이다.
    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expectEqualStrings("alpha beta\n", fx.session.copyText());
}

test "PASTE6 ⌘V가 편집기 문서에 들어간다 — 배선 전체를 통과한다 (§3.4)" {
    // **함수를 직접 부르면 배선이 빠져도 통과한다.** 이 세션에서 배선이 네 번 끊겨 있었다
    // (⌘⌃D chord · 편집기 키 분기 · dirty 탭 라벨 · dirty DTO 필드). 그래서 여기서는
    // **`AppSession.pasteText`**(Swift가 ⌘V로 부르는 그 자리)부터 지난다.
    //
    // 편집기에는 PTY가 없어, 갈래가 없으면 붙여넣기가 **소멸한다**(터미널 경로로 흘러 사라진다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste6.txt", "ab\n");

    term.rt.editor_selection = editor_selection.Selection.at(1);
    fx.session.pasteText("XY", false); // ← Swift ⌘V가 부르는 자리
    try testing.expectEqualStrings("aXYb\n", term.rt.editor_doc.?.file.content);

    // **한 묶음이라 undo 한 번에 돌아간다**(§3.3).
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("ab\n", term.rt.editor_doc.?.file.content);
}

test "PASTE1 조각 수가 커서 수와 같으면 하나씩 분배한다 (§3.4)" {
    // **§3.4: "개수가 맞을 때만 분배한다."** 커서마다 자기 조각이 들어가야 멀티 커서 복사→
    // 붙여넣기가 왕복한다. 개수가 다른데 억지로 나누면 사용자가 예측할 수 없다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste1.txt", "aa bb cc\n");

    // 셋을 골라 복사한다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2);
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 2);
    extras[0] = editor_selection.Selection.fromPoints(3, 5);
    extras[1] = editor_selection.Selection.fromPoints(6, 8);
    term.rt.editor_extra_selections = extras;
    try testing.expect(copySelection(fx.session));

    // 같은 세 자리에 붙여넣으면 **제자리로 돌아온다**(왕복).
    try testing.expect(pasteText(fx.session, term, fx.session.chrome_clipboard_write));
    try testing.expectEqualStrings("aa bb cc\n", term.rt.editor_doc.?.file.content);

    // **한 번의 붙여넣기는 undo 하나다**(§3.3) — 커서가 셋이어도.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("aa bb cc\n", term.rt.editor_doc.?.file.content);
}

test "PASTE2 개수가 다르면 전부에 통짜로 넣는다 (§3.4)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste2.txt", "xx yy\n");

    // 조각 **둘**을 복사해 두고,
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2);
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.fromPoints(3, 5);
    term.rt.editor_extra_selections = extras;
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("xx\nyy", fx.session.chrome_clipboard_write);

    // 커서 **하나**에 붙여넣는다 — 개수가 다르므로 **통짜**다.
    clearExtraSelections(fx.session, term);
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(pasteText(fx.session, term, fx.session.chrome_clipboard_write));
    try testing.expectEqualStrings("xx\nyyxx yy\n", term.rt.editor_doc.?.file.content);
}

test "PASTE3 외부 클립보드는 항상 통짜다 (§3.4)" {
    // **조각 경계는 이 앱이 만든 복사에만 있다.** 시스템 클립보드가 그 사이 바뀌었으면 기억한
    // 경계로 **남의 문자열**을 자르게 되고, 사용자가 복사한 적 없는 조각이 커서마다 들어간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste3.txt", "aa bb\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2);
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.fromPoints(3, 5);
    term.rt.editor_extra_selections = extras;
    try testing.expect(copySelection(fx.session)); // 조각 둘을 기억한다

    // **다른 앱이 복사한 것**을 붙여넣는다 — 조각 수가 둘로 맞아 보여도 통짜여야 한다.
    try testing.expect(pasteText(fx.session, term, "PP\nQQ"));
    try testing.expectEqualStrings("PP\nQQ PP\nQQ\n", term.rt.editor_doc.?.file.content);
}

test "PASTE4 선택 없이 복사한 것은 줄 단위로 넣는다 (§3.4)" {
    // **§3.4: "그렇게 담긴 것을 붙여넣으면 caret 위치가 아니라 줄 단위로 삽입한다"** —
    // 줄 중간에 끼워 넣으면 줄이 깨진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste4.txt", "alpha\nbeta\n");

    // 첫 줄 가운데에 caret만 두고 복사 → 줄 전체가 담긴다.
    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("alpha\n", fx.session.chrome_clipboard_write);

    // 둘째 줄 **가운데**에 caret을 두고 붙여넣는다 — 줄 중간이 아니라 **그 줄 앞**에 들어간다.
    term.rt.editor_selection = editor_selection.Selection.at(8); // "beta"의 't' 앞
    try testing.expect(pasteText(fx.session, term, fx.session.chrome_clipboard_write));
    try testing.expectEqualStrings("alpha\nalpha\nbeta\n", term.rt.editor_doc.?.file.content);
}

test "PASTE8 붙여넣기는 타이핑과 다른 묶음이고, 문서를 dirty로 만든다 (§3.3·file-panel.md §1)" {
    // **§3.3이 묶음을 끊는 이유 셋 중 "연산 종류 변경"이다.** 안 끊으면 "치다가 붙여넣었다"가
    // 한 묶음이 되어, 붙여넣기를 되돌리려는 undo 한 번에 **친 것까지 사라진다**.
    //
    // 그 축이 판정 밖이었다(적대적 검증 2026-08-26 — 끊기를 지운 뮤턴트가 살아남았다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste8.txt", "AB\n");

    try testing.expect(!isDirty(term));
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "1"));
    try testing.expect(pasteText(fx.session, term, "X"));
    try testing.expectEqualStrings("1XAB\n", term.rt.editor_doc.?.file.content);

    // **붙여넣기도 편집이라 dirty다.**
    try testing.expect(isDirty(term));

    // undo 한 번은 **붙여넣기만** 되돌린다 — 안 끊으면 "AB\n"까지 간다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("1AB\n", term.rt.editor_doc.?.file.content);

    // **붙여넣기 뒤에 친 것도 새 묶음이다** — 끊기는 양쪽이다.
    //
    // **redo를 거치면 안 된다**: `stepHistory`가 이미 묶음을 끊어, 뒤쪽 끊기를 지운 뮤턴트가
    // 그 배치에서 살아남았다(적대적 검증 2026-08-26). 붙여넣기 **바로 뒤에** 쳐야 갈린다.
    try testing.expect(pasteText(fx.session, term, "Y"));
    try testing.expect(insertText(fx.session, term, "2"));
    const after_typing = term.rt.editor_doc.?.file.content;
    try testing.expect(std.mem.indexOf(u8, after_typing, "Y2") != null);
    // undo 한 번은 **친 것만** 되돌린다 — 안 끊으면 붙여넣은 "Y"까지 함께 사라진다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expect(std.mem.indexOf(u8, term.rt.editor_doc.?.file.content, "Y") != null);
}

test "PASTE7 줄 단위 붙여넣기에서 같은 줄 커서 여럿은 한 번만 넣는다 (§3.4)" {
    // **같은 줄에 커서가 둘이면 줄 머리가 같다.** 거르지 않으면 그 줄에 **두 번** 넣게 되고,
    // `delta.apply`가 겹침으로 거절하거나(그러면 붙여넣기가 통째로 실패한다) 중복이 생긴다 —
    // 사용자는 커서를 둘 뒀다는 이유로 **줄이 두 번** 들어간 것을 본다.
    //
    // 이 방어가 판정 밖이었다(적대적 검증 2026-08-26 — 거르기를 지운 뮤턴트가 살아남았다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste7.txt", "alpha\nbeta\n");

    // 선택 없이 복사 → 줄 단위 표식이 선다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("alpha\n", fx.session.chrome_clipboard_write);

    // **둘째 줄 안에 커서 둘**을 둔다 — 줄 머리가 같다.
    term.rt.editor_selection = editor_selection.Selection.at(6); // "beta"의 'b'
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.at(8); // 같은 줄 't' 앞
    term.rt.editor_extra_selections = extras;

    try testing.expect(pasteText(fx.session, term, fx.session.chrome_clipboard_write));
    // **한 번만** 들어간다 — 두 번이면 "alpha\nalpha\nalpha\nbeta\n"이 된다.
    try testing.expectEqualStrings("alpha\nalpha\nbeta\n", term.rt.editor_doc.?.file.content);
}

test "PASTE5 읽기 전용·비교 뷰는 붙여넣기를 거절한다 (§3.5·§4.1g)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "paste5.txt", "locked\n");
    term.rt.editor_selection = editor_selection.Selection.at(0);

    term.rt.editor_doc.?.file.read_only = true;
    try testing.expect(!pasteText(fx.session, term, "x"));
    term.rt.editor_doc.?.file.read_only = false;

    term.rt.editor_diff = .{};
    try testing.expect(!pasteText(fx.session, term, "x"));
    term.rt.editor_diff = null;

    try testing.expectEqualStrings("locked\n", term.rt.editor_doc.?.file.content);
    // 빈 클립보드도 무동작이다 — 빈 편집을 undo 스택에 쌓으면 undo가 헛돈다.
    try testing.expect(!pasteText(fx.session, term, ""));
}

test "COPY1 선택 없이 복사하면 caret 줄 전체를 담는다 (§3.4)" {
    // **§3.4: "선택 없이 복사하면 caret이 있는 줄 전체를 담고, 그 사실을 함께 기억한다."**
    // 그것이 없어서 선택 없이 `⌘C`를 누르면 **아무 일도 안 일어났다**(적대적 검증 2026-08-26) —
    // 기존 판정자는 오히려 "선택이 없으면 복사도 없다"로 그 상태를 고정하고 있었는데, 그쪽은
    // **커서 자체가 없는** 경우라 이 갈래를 안 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "copy1.txt", "alpha\nbeta\ngamma\n");

    // 둘째 줄 가운데에 caret만 둔다(선택 없음).
    term.rt.editor_selection = editor_selection.Selection.at(8);
    try testing.expect(copySelection(fx.session));

    // **줄 끝 문자까지** 담긴다 — 줄 단위 삽입이 그것으로 줄을 만든다.
    try testing.expectEqualStrings("beta\n", fx.session.chrome_clipboard_write);
    const meta = fx.session.editor_clipboard_meta.?;
    try testing.expect(meta.from_empty_selection); // **그 사실을 함께 기억한다**
    try testing.expectEqual(@as(usize, 1), meta.pieceCount());
}

test "COPY2 커서가 여럿이면 조각 경계를 기억한다 (§3.4)" {
    // 시스템 클립보드에는 **통짜**가 들어가므로(다른 앱이 붙여넣을 때 자연스러우라고 §3.4가 정했다)
    // 조각이 몇 개였는지는 앱이 따로 기억해야 한다. 그것이 없으면 붙여넣기가 **분배할 수 없다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "copy2.txt", "aa bb cc\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2); // "aa"
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 2);
    extras[0] = editor_selection.Selection.fromPoints(3, 5); // "bb"
    extras[1] = editor_selection.Selection.fromPoints(6, 8); // "cc"
    term.rt.editor_extra_selections = extras;

    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("aa\nbb\ncc", fx.session.chrome_clipboard_write);

    const meta = fx.session.editor_clipboard_meta.?;
    try testing.expect(!meta.from_empty_selection);
    try testing.expectEqual(@as(usize, 3), meta.pieceCount());
    try testing.expectEqualStrings("aa", meta.piece(0).?);
    try testing.expectEqualStrings("bb", meta.piece(1).?);
    try testing.expectEqualStrings("cc", meta.piece(2).?);

    // **기억이 지금 클립보드를 설명한다** — 이 대조가 외부 클립보드를 걸러 낸다.
    try testing.expect(maru.session.editor.clipboard.describes(meta, fx.session.chrome_clipboard_write));
}

test "DIRTY7 빈 파일과 읽기 전용도 계약을 지킨다 (file-panel.md §1)" {
    // **가장자리 둘.** 빈 파일은 내용이 0 byte라 해시가 상수인데, 그 자체는 문제가 아니고
    // *"열자마자 clean"*·*"한 글자 치면 dirty"*가 성립하면 된다. 읽기 전용은 편집이 거절되므로
    // **영원히 clean**이어야 한다 — dirty가 서면 저장할 수 없는 문서에 저장 표식이 붙고,
    // 닫기 게이트가 **닫을 수 없는 문**을 연다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // ⑴ 빈 파일.
    const empty = try undoFixture(&fx, allocator, "empty.txt", "");
    try testing.expect(!isDirty(empty));
    empty.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, empty, "a"));
    try testing.expect(isDirty(empty));
    // 지워서 **다시 빈 내용**이 되면 clean이다 — 내용 동등성이므로.
    try testing.expect(deleteText(fx.session, empty, true));
    try testing.expectEqualStrings("", empty.rt.editor_doc.?.file.content);
    try testing.expect(!isDirty(empty));

    // ⑵ 읽기 전용.
    const ro = try undoFixture(&fx, allocator, "ro2.txt", "locked\n");
    ro.rt.editor_doc.?.file.read_only = true;
    ro.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!insertText(fx.session, ro, "x")); // 편집이 거절된다
    try testing.expect(!isDirty(ro)); // **그래서 영원히 clean**
    try testing.expect(!fx.session.scopeHasUnsavedEditor(.term));
}

test "DIRTY6 비교 뷰로 전환하면 dirty 표시를 내리지 않는다 — 축이 다르다 (§7)" {
    // **비교 뷰는 읽기 전용 결과**라 저장할 것이 없다(§7). 그런데 같은 Term이 `editor_doc`을 든 채
    // 비교 뷰로 전환될 수 있어, 그 상태에서 dirty를 물으면 **비교 탭에 저장 표식이 뜬다** —
    // 사용자는 "이 비교를 저장해야 하나?"로 읽는다. 닫기 게이트도 그 문을 연다.
    //
    // `editorMeta`는 비교 뷰를 이미 갈라 `dirty = false`를 내는데, `isDirty`에는 그 갈래가 없었다
    // (적대적 검증 2026-08-26).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty6.txt", "hello\n");

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(isDirty(term)); // 편집기로서는 dirty다

    // 비교 뷰로 전환한다.
    term.rt.editor_diff = .{};
    defer term.rt.editor_diff = null;
    try testing.expect(!isDirty(term)); // **비교 뷰에서는 dirty 축이 없다**

    // 라벨에도 표식이 없다.
    const label = try fx.session.diffAwareLabel(allocator, term);
    defer allocator.free(label);
    try testing.expect(!std.mem.startsWith(u8, label, app_session_mod.editor_dirty_marker));
}

/// 파일을 쓰고 그 절대 경로를 준다 — 호출자가 free한다.
fn dirtyFixturePath(fx: *PaneFixture, allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![]const u8 {
    const io = std.testing.io;
    try fx.dir.dir.writeFile(io, .{ .sub_path = name, .data = data });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    return std.fs.path.join(allocator, &.{ root, name });
}

test "DIRTY5 저장 안 한 편집기를 닫으면 확인을 묻는다 (file-panel-dock-ui.md §3.2)" {
    // **§3.2 "파일 탭 닫기와 dirty 보호"** — 닫기 직전에 게이트를 지나야 한다. 안 지나면
    // `⌘W` 한 번에 **저장 안 한 편집이 조용히 사라진다.** 되돌릴 방법이 없는 종류다.
    //
    // 기존 게이트는 **실행 중 셸 명령**만 봤다(`closeTargetHasRunningJob`) — 편집기 dirty는
    // 그 판정에 없었다(적대적 검증 2026-08-26).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty5.txt", "hello\n");

    // **cascade가 아니라 dirty를 잰다.** 마지막 Term을 닫으면 pane·탭·창으로 범위가 번져 다른
    // 이유(창 닫기 확인)로도 모달이 뜬다 — 그러면 이 판정자가 dirty를 재는 척만 한다. 그래서
    // Term을 하나 더 두고 **Term 범위에서** 잰다.
    {
        const other = try dirtyFixturePath(&fx, allocator, "other.txt", "x\n");
        defer allocator.free(other);
        _ = try openPathInActivePane(fx.session, other);
    }
    // **픽스처의 터미널 Term을 프롬프트로 정착시킨다.** 안 그러면 "실행 중 명령" 분기가 **먼저**
    // 걸려 이 판정자가 dirty가 아니라 그것을 잰다(적대적 검증 2026-08-26 — 실제로 그 문구가 떴다).
    for (pane_ops.activePane(fx.session).terms.items) |t| {
        if (t.kind != .editor) t.surface.core.semantic_state = .input;
    }
    // 편집기를 활성으로 되돌린다.
    for (pane_ops.activePane(fx.session).terms.items, 0..) |t, i| {
        if (t == term) fx.session.focusTerm(i);
    }
    try testing.expect(pane_ops.activePane(fx.session).terms.items.len > 1);

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(isDirty(term));

    // **dirty면 묻는다.**
    fx.session.requestClose(.active_term);
    try testing.expect(fx.session.chrome_host.confirm.open); // 모달이 떴다

    // **문구가 dirty를 말한다** — `app_close_running`("명령이 돌고 있다")을 재사용하면 사용자가
    // 무엇을 잃는지 모른다(적대적 검증 2026-08-26 — 처음엔 그 문구를 쓰고 있었다).
    try testing.expectEqualStrings(maru.i18n.t(.app_close_unsaved), fx.session.chrome_host.confirm.message);

    // **탭·창을 닫을 때도 같은 문이 선다.** Term 범위만 재면 `⌘W`는 막히는데 탭 닫기·창 닫기로
    // 같은 편집이 사라진다 — 범위마다 따로 배선돼 있어 하나만 재면 나머지는 판정 밖이다
    // (적대적 검증 2026-08-26 — 탭·창 갈래를 지운 뮤턴트가 둘 다 살아남았다).
    // 은 split 없는 탭에서 **pane**으로 풀린다 —  범위는 사이드바 ✕
    // ()가 연다. 셋을 다 재야 범위별 배선이 전부 판정 아래 든다.
    // `.tab_index`는 **탭이 하나면** `.session`으로 풀린다(마지막 탭 = 창 전체) — 탭을 하나 더
    // 만들어야 `.tab` 갈래에 닿는다. 안 그러면 그 범위가 판정 밖에 남는다(적대적 검증 2026-08-26).
    _ = try tab_ops.newTab(fx.session);
    fx.session.app_window.active_tab = 0; // dirty 편집기가 있는 탭으로 되돌린다
    // 새 탭의 터미널도 프롬프트로 정착시킨다 — 안 그러면 창 범위에서 "실행 중 명령"이 먼저 걸려
    // 이 판정자가 dirty를 재는 척만 한다(같은 함정을 두 번째로 밟았다).
    for (fx.session.tabs.items) |t| {
        for (t.panes.items) |pn| {
            for (pn.terms.items) |tm| if (tm.kind != .editor) {
                tm.surface.core.semantic_state = .input;
            };
        }
    }
    try testing.expect(fx.session.tabs.items.len > 1);
    for ([_]app_session_mod.PendingClose{ .pane_or_tab, .{ .tab_index = 0 }, .window }) |target| {
        fx.session.chrome_host.confirm.open = false;
        fx.session.pending_confirm = .none;
        fx.session.requestClose(target);
        try testing.expect(fx.session.chrome_host.confirm.open);
        try testing.expectEqualStrings(
            if (target == .window) maru.i18n.t(.app_close_window_unsaved) else maru.i18n.t(.app_close_unsaved),
            fx.session.chrome_host.confirm.message,
        );
    }

    // **네 범위 술어를 직접 잰다.** 위 루프는 `target → scope` 해소까지 함께 지나는데, `.pane`은
    // split이 있어야 그 갈래로 풀린다 — 위상을 더 만들면 픽스처의 다른 전제가 깨졌다. 해소 규칙은
    // 이미 기존 판정자들이 재고 있으므로, 여기서는 **술어가 범위마다 dirty를 보는지**만 잰다
    // (그것이 없으면 탭·창 닫기로 같은 편집이 사라진다 — 뮤턴트가 그 갈래마다 따로 살아남았다).
    for ([_]app_session_mod.CloseScope{ .term, .pane, .{ .tab = 0 }, .session }) |scope| {
        try testing.expect(fx.session.scopeHasUnsavedEditor(scope));
    }

    // 저장하면 다시 묻지 않는다 — 닫힌다.
    fx.session.chrome_host.confirm.open = false;
    fx.session.pending_confirm = .none;
    try testing.expect(saveDocument(fx.session, term));
    fx.session.requestClose(.active_term);
    try testing.expect(!fx.session.chrome_host.confirm.open);
    for ([_]app_session_mod.CloseScope{ .term, .pane, .{ .tab = 0 }, .session }) |scope| {
        try testing.expect(!fx.session.scopeHasUnsavedEditor(scope));
    }
}

test "DIRTY4 저장이 실패하면 dirty가 남는다 — 실패를 성공으로 보고하지 않는다 (file-panel.md §1)" {
    // **§1: *"실패·external conflict에서는 buffer와 dirty를 유지한다"***. 이것을 안 지키면
    // 사용자는 **저장됐다고 믿고 창을 닫는다** — 그 순간 편집이 사라진다. 되돌릴 방법이 없는 종류다.
    //
    // 이 축에 판정자가 없어서, 실패 경로에서도 clean으로 만드는 뮤턴트가 살아남았다
    // (적대적 검증 2026-08-26).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty4.txt", "hello\n");

    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(isDirty(term));

    // ⑴ **디렉터리를 쓰기 금지로 만든다** — 원본은 열리고 해시도 나오지만 **temp 만들기가 실패**한다.
    //    쓰기 자리까지 실제로 닿아야 그 경로의 결함이 드러난다: 파일만 지우면 그 앞(열기)에서
    //    끝나 **쓰기 실패 경로가 아예 안 돈다**(적대적 검증 2026-08-26 — 그 상태로 뮤턴트가 살았다).
    {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
        const root_z = try allocator.dupeZ(u8, root);
        defer allocator.free(root_z);
        if (std.c.chmod(root_z, 0o500) != 0) return error.SkipZigTest; // 권한을 못 바꾸면 이 축을 못 잰다
        defer _ = std.c.chmod(root_z, 0o700); // 픽스처 정리가 지울 수 있게 되돌린다

        try testing.expect(!saveDocument(fx.session, term)); // 실패를 실패로 보고한다
        try testing.expect(isDirty(term)); // **dirty가 남는다**
        try testing.expectEqualStrings("hello!\n", term.rt.editor_doc.?.file.content);
    }

    // ⑵ **파일이 사라진 경우**도 같다 — 열기에서 실패하는 다른 갈래다.
    try fx.dir.dir.deleteFile(io, "dirty4.txt");
    try testing.expect(!saveDocument(fx.session, term));
    try testing.expect(isDirty(term));
    try testing.expectEqualStrings("hello!\n", term.rt.editor_doc.?.file.content);
}

test "DIRTY3 dirty면 제목에 점이 붙고, 저장하면 사라진다 (file-panel.md §1)" {
    // **상태만 맞고 화면에 안 나오면 사용자에게는 없는 기능이다.** `isDirty`가 참인 것과 제목에
    // 점이 붙는 것은 다른 자리이고, 그 사이가 끊긴 채로 "dirty 표시를 했다"고 적을 수 있다 —
    // 이 슬라이스에서 배선이 죽어 있던 것을 두 번 겪었다(⌘⌃D chord·편집기 키 분기).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty3.txt", "hello\n");

    try testing.expect(!isDirty(term));
    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(isDirty(term));

    // **스냅숏이 실제로 내는 제목**을 본다 — `isDirty`가 참인 것과 제목에 점이 붙는 것은 다른 자리다.
    const marker = app_session_mod.editor_dirty_marker;
    const snapshotDto = struct {
        fn get(session: *AppSession, alloc: std.mem.Allocator, sid: u64) !struct { title: []const u8, dirty: bool } {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            var surfaces: std.ArrayList(maru.session.control_surface.SurfaceDto) = .empty;
            var windows: std.ArrayList(maru.session.WindowMembershipSnapshot) = .empty;
            try session.collectSessionInto(a, 1, .normal, &surfaces, &windows);
            for (surfaces.items) |dto| {
                if (dto.surface_id != sid) continue;
                return .{
                    .title = try alloc.dupe(u8, dto.title),
                    .dirty = switch (dto.detail) {
                        .editor => |m| m.dirty,
                        else => false,
                    },
                };
            }
            return error.SurfaceNotInSnapshot;
        }
    }.get;

    {
        const dto = try snapshotDto(fx.session, allocator, term.surface.id);
        defer allocator.free(dto.title);
        try testing.expect(std.mem.startsWith(u8, dto.title, marker));
        try testing.expect(std.mem.endsWith(u8, dto.title, "dirty3.txt"));
        // **타입 있는 필드로도 나간다.** 제목 접두사만 두면 소비자가 문자열을 뜯어야 하고,
        // 표식을 바꾸는 순간 조용히 깨진다(적대적 검증 2026-08-26 — 그 상태로 wire에 나가고 있었다).
        try testing.expect(dto.dirty);
    }

    // **사용자가 보는 탭 라벨에도 나온다.** DTO에만 붙였다가 화면에는 안 나오는 상태였다
    // (적대적 검증 2026-08-26 — 탭 바는 `diffAwareLabel` 경로를 탄다).
    {
        const label = try fx.session.diffAwareLabel(allocator, term);
        defer allocator.free(label);
        try testing.expect(std.mem.startsWith(u8, label, marker));
    }
    // **에이전트 running 표식과 다른 글자여야 한다** — 같은 자리에 붙으므로 겹치면 뜻이 겹친다.
    {
        var flag: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(app_session_mod.agent_running_flag, &flag) catch 0;
        try testing.expect(!std.mem.eql(u8, marker, flag[0..n]));
    }

    try testing.expect(saveDocument(fx.session, term));
    try testing.expect(!isDirty(term));
    {
        const label = try fx.session.diffAwareLabel(allocator, term);
        defer allocator.free(label);
        try testing.expect(!std.mem.startsWith(u8, label, marker));
    }
    {
        const dto = try snapshotDto(fx.session, allocator, term.surface.id);
        defer allocator.free(dto.title);
        try testing.expect(!std.mem.startsWith(u8, dto.title, marker));
        try testing.expectEqualStrings("dirty3.txt", dto.title);
        try testing.expect(!dto.dirty);
    }
}

test "DIRTY2 BOM이 있는 파일도 저장 직후 clean이다 (§3.5)" {
    // **저장이 쓰는 bytes에는 BOM이 붙고 편집기가 든 내용에는 없다.** 쓴 bytes로 해시를 재면
    // BOM 있는 파일이 **저장 직후에도 dirty로 남아** 사용자가 저장을 반복한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "dirty2.txt", "\xEF\xBB\xBFhi\n");
    try testing.expect(term.rt.editor_doc.?.file.format.has_bom); // 전제: 실제로 BOM 문서다

    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(insertText(fx.session, term, "!"));
    try testing.expect(term.rt.editor_doc.?.isDirty());
    try testing.expect(saveDocument(fx.session, term));
    try testing.expect(!term.rt.editor_doc.?.isDirty());
}

test "MOV10 제품 열 변환이 L2 대역과 같은 계약을 쓴다 — 탭 안쪽 (§5.4)" {
    // **판정자와 제품이 서로 다른 의미를 재고 있었다**(적대적 검증 2026-08-26). `motion.zig`의
    // 테스트 대역은 **내림**, 제품은 **가장 가까운 경계**였다 — 탭 하나가 열 [0,4)를 먹을 때
    // 목표 열 1에서 대역은 탭 뒤, 제품은 탭 앞을 냈다. L2 판정자 62개가 전부 통과한 채로였다.
    //
    // 계약을 "가장 가까운 경계"로 통일했고(`MOT8`), **여기서 제품이 그 계약을 지키는지** 잰다 —
    // 대역만 고치고 제품을 안 재면 다음에 또 갈린다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov10.txt", "\tx\nyy\n");

    var pcm = productColumnMap(term);
    const map = pcm.map();
    const line = term.rt.editor_doc.?.file.lines.line(0).?;
    const text = term.rt.editor_doc.?.file.content[line.start..line.contentEnd()];

    // `MOT8`과 **같은 표**다 — 둘이 갈리면 여기서 잡힌다.
    try testing.expectEqual(@as(usize, 0), map.offsetOf(map.ctx, text, 0));
    try testing.expectEqual(@as(usize, 0), map.offsetOf(map.ctx, text, 1));
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, text, 2));
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, text, 3));
    try testing.expectEqual(@as(usize, 1), map.offsetOf(map.ctx, text, 4));
    try testing.expectEqual(@as(usize, 2), map.offsetOf(map.ctx, text, 5));

    // 왕복도 같다.
    for ([_]usize{ 0, 1, 2 }) |b| {
        const c = map.columnOf(map.ctx, text, b);
        try testing.expectEqual(b, map.offsetOf(map.ctx, text, c));
    }
}

test "DEL1 ⌥⌫·⌘⌫가 낱말·줄 단위로 지운다 — 이동과 같은 자리다 (§3.2)" {
    // **§3.2가 "문자/단어/줄 단위 삭제"를 요구한다.** 문자만 있으면 낱말을 지우려고 키를 여러 번
    // 눌러야 한다.
    //
    // **경계를 다시 세지 않는다**: `motion.zig`의 `wordLeft`·`lineStartSmart`를 그대로 쓴다.
    // 세면 "⌥←로 간 곳"과 "⌥⌫가 지운 곳"이 갈리고, 사용자는 그 차이를 설명할 수 없다 —
    // 이 판정자가 **둘이 같은 자리인지**까지 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "del1.txt", "    foo bar\nnext\n");

    // ⑴ **⌥⌫ = 낱말 뒤로.** "bar" 끝(11)에서 누르면 "bar"가 사라진다.
    term.rt.editor_selection = editor_selection.Selection.at(11);
    try pressKey(&fx, .backspace, .{ .option = true });
    try testing.expectEqualStrings("    foo \nnext\n", term.rt.editor_doc.?.file.content);

    // **이동과 같은 자리인가** — 같은 시작점에서 `⌥←`가 가는 곳이 지운 범위의 시작이어야 한다.
    {
        const t2 = try undoFixture(&fx, allocator, "del1b.txt", "    foo bar\nnext\n");
        t2.rt.editor_selection = editor_selection.Selection.at(11);
        try testing.expect(moveCarets(fx.session, t2, .word_left, false));
        try testing.expectEqual(@as(usize, 8), t2.rt.editor_selection.?.focus); // "bar" 앞
    }

    // ⑵ **⌘⌫ = 줄 시작까지**(smart home과 같은 자리 — 들여쓰기 앞이 아니라 첫 글자).
    const t3 = try undoFixture(&fx, allocator, "del1c.txt", "    foo bar\nnext\n");
    t3.rt.editor_selection = editor_selection.Selection.at(7); // "foo" 뒤
    try pressKey(&fx, .backspace, .{ .command = true });
    try testing.expectEqualStrings("     bar\nnext\n", t3.rt.editor_doc.?.file.content);

    // ⑵′ **줄 머리에서 ⌘⌫는 앞 줄과 합친다** — 안 그러면 죽은 키다(`⌘⌦`가 줄 끝에서 겪던 것과
    //     같은 함정. 적대적 검증 2026-08-27이 실측으로 잡았다).
    {
        const t = try undoFixture(&fx, allocator, "del1f.txt", "aa\nbb\n");
        t.rt.editor_selection = editor_selection.Selection.at(3); // "bb" 줄 머리
        try pressKey(&fx, .backspace, .{ .command = true });
        try testing.expectEqualStrings("aabb\n", t.rt.editor_doc.?.file.content);
    }

    // ⑶ **⌥⌦ = 낱말 앞으로.**
    const t4 = try undoFixture(&fx, allocator, "del1d.txt", "foo bar\n");
    t4.rt.editor_selection = editor_selection.Selection.at(0);
    try pressKey(&fx, .delete, .{ .option = true });
    try testing.expectEqualStrings("bar\n", t4.rt.editor_doc.?.file.content);

    // ⑷ **⌘⌦ = 줄 끝까지.** 이미 줄 끝이면 개행을 먹는다(안 그러면 죽은 키다).
    const t5 = try undoFixture(&fx, allocator, "del1e.txt", "foo bar\nnext\n");
    t5.rt.editor_selection = editor_selection.Selection.at(4); // "bar" 앞
    try pressKey(&fx, .delete, .{ .command = true });
    try testing.expectEqualStrings("foo \nnext\n", t5.rt.editor_doc.?.file.content);
    try pressKey(&fx, .delete, .{ .command = true }); // 이미 줄 끝 → 개행을 먹는다
    try testing.expectEqualStrings("foo next\n", t5.rt.editor_doc.?.file.content);
}

test "DEL2 선택이 있으면 단위와 무관하게 그 선택을 지운다 (§3.2)" {
    // **사용자가 이미 범위를 골랐는데 단위로 다시 정하면 고른 것이 무시된다.** `⌥⌫`를 눌렀다고
    // 선택 밖 낱말까지 지우면 되돌릴 방법이 undo뿐이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "del2.txt", "alpha beta gamma\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(6, 10); // "beta"
    try pressKey(&fx, .backspace, .{ .option = true });
    try testing.expectEqualStrings("alpha  gamma\n", term.rt.editor_doc.?.file.content);

    // 커서가 여럿이어도 각자 자기 단위로 지운다.
    const t2 = try undoFixture(&fx, allocator, "del2b.txt", "aa bb cc\n");
    t2.rt.editor_selection = editor_selection.Selection.at(5); // "bb" 끝
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.at(8); // "cc" 끝
    t2.rt.editor_extra_selections = extras;
    try testing.expect(deleteBy(fx.session, t2, true, .word));
    // "bb"와 "cc"가 각자 사라지고 **앞 공백은 남는다** — 가 낱말 앞에서 멈추기 때문이다.
    try testing.expectEqualStrings("aa  \n", t2.rt.editor_doc.?.file.content);
}

test "DEL3 문서 밖 커서는 문서 끝으로 접히고, 빈 문서는 무동작이다 (§3.2)" {
    // **커서가 문서 밖을 가리키는 상태가 존재한다** — 편집·재로드가 문서를 줄이면 옛 offset이
    // 남는다(`selections`는 그것을 clamp해서 준다). 그때 `lo`와 `hi`가 **둘 다 문서 끝으로**
    // 접혀 빈 범위가 되고, 거르지 않으면 **빈 편집이 undo 스택에 쌓여** undo가 헛돈다.
    //
    // 그 방어가 판정 밖이었다(적대적 검증 2026-08-27 — 지운 뮤턴트가 살아남았다). 같은 검사를
    // 두 곳에 두었던 것도 그때 확인해 하나로 줄였다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "del3.txt", "ab\n");

    // **문서 밖**을 가리키게 만든다.
    const len = term.rt.editor_doc.?.file.content.len;
    term.rt.editor_selection = editor_selection.Selection.fromPoints(len + 10, len + 20);

    // **문서 끝으로 접힌다.** `@min`이 양끝을 clamp하므로 caret이 문서 끝에 있는 것과 같아진다 —
    // 그래서 뒤로 지우면 마지막 글자가 사라지고, 앞으로 지우면 지울 것이 없다.
    //
    // 처음엔 "아무것도 안 지운다"고 적었는데 **틀렸다**(적대적 검증 2026-08-27이 실측으로 잡았다).
    // 접힌 뒤에는 문서 밖이었다는 사실이 남지 않으므로, 문서 끝 caret과 **구분할 수 없고 구분할
    // 이유도 없다** — 중요한 것은 **죽지 않고 문서를 망가뜨리지 않는 것**이다.
    try testing.expect(!deleteBy(fx.session, term, false, .char)); // 문서 끝: 앞으로 지울 것이 없다
    try testing.expect(deleteBy(fx.session, term, true, .char)); // 뒤로: 마지막 글자
    try testing.expectEqualStrings("ab", term.rt.editor_doc.?.file.content);

    // 낱말·줄 단위도 같은 축이다 — 죽지 않고, 남은 것을 정확히 지운다.
    term.rt.editor_selection = editor_selection.Selection.at(999);
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expectEqualStrings("", term.rt.editor_doc.?.file.content);

    // 빈 문서에서는 어느 단위로도 아무 일이 없다 — 빈 편집이 쌓이면 undo가 헛돈다.
    for ([_]DeleteUnit{ .char, .word, .line_edge }) |unit| {
        try testing.expect(!deleteBy(fx.session, term, true, unit));
        try testing.expect(!deleteBy(fx.session, term, false, unit));
    }
}

test "DEL4 연속 낱말 삭제는 한 묶음이고, 타이핑이 끼면 끊긴다 (§3.3)" {
    // §3.3의 묶음 규칙은 **단위와 무관**하다 — 같은 종류(`.delete`)가 이어지면 한 묶음이고,
    // 종류가 바뀌면 끊긴다. `⌥⌫`를 세 번 눌러 문장을 지웠는데 undo가 세 번 필요하면 사용자는
    // "왜 이건 한 번에 안 돌아오나"를 겪는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "del4.txt", "one two three\n");

    term.rt.editor_selection = editor_selection.Selection.at(13); // "three" 끝
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expectEqualStrings("\n", term.rt.editor_doc.?.file.content);

    // **한 번**에 셋 다 돌아온다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("one two three\n", term.rt.editor_doc.?.file.content);

    // **타이핑이 끼면 끊긴다** — 종류가 바뀌기 때문이다.
    term.rt.editor_selection = editor_selection.Selection.at(13);
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expect(insertText(fx.session, term, "X"));
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expect(undoEdit(fx.session, term)); // 마지막 낱말 삭제만
    try testing.expectEqualStrings("one two X\n", term.rt.editor_doc.?.file.content);
}

test "DEL5 한글·탭이 섞여도 단위 삭제가 깨진 UTF-8을 만들지 않는다 (§3.2·§3.8)" {
    // **byte로 지우면 한글이 반쪽 난다.** 그 상태는 화면에 §3.8 표기로 뜨고 저장하면 파일이
    // 깨진다 — 되돌릴 방법이 undo뿐인 종류다. `EDIT4`가 문자 단위에서 재는 것을 **낱말·줄**
    // 단위에서도 잰다: 경계를 `motion.zig`가 소유하므로 같은 성질이 따라와야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "del5.txt", "\t한글 영어\n다음\n");

    // ⑴ 낱말 뒤로 — "영어"(6 byte)가 통째로 사라진다.
    const content0 = term.rt.editor_doc.?.file.content;
    const nl = std.mem.indexOfScalar(u8, content0, '\n').?;
    term.rt.editor_selection = editor_selection.Selection.at(nl);
    try testing.expect(deleteBy(fx.session, term, true, .word));
    try testing.expectEqualStrings("\t한글 \n다음\n", term.rt.editor_doc.?.file.content);
    try testing.expect(std.unicode.utf8ValidateSlice(term.rt.editor_doc.?.file.content));

    // ⑵ 줄 시작까지 — 탭(들여쓰기) **뒤**가 첫 글자다(smart home과 같은 자리).
    const t2 = try undoFixture(&fx, allocator, "del5b.txt", "\t한글 영어\n");
    const c2 = t2.rt.editor_doc.?.file.content;
    t2.rt.editor_selection = editor_selection.Selection.at(std.mem.indexOfScalar(u8, c2, '\n').?);
    try testing.expect(deleteBy(fx.session, t2, true, .line_edge));
    try testing.expectEqualStrings("\t\n", t2.rt.editor_doc.?.file.content);
    try testing.expect(std.unicode.utf8ValidateSlice(t2.rt.editor_doc.?.file.content));

    // ⑶ 낱말 앞으로 — 한글 낱말 머리에서 눌러도 반쪽이 안 남는다.
    const t3 = try undoFixture(&fx, allocator, "del5c.txt", "한글 영어\n");
    t3.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(deleteBy(fx.session, t3, false, .word));
    try testing.expectEqualStrings("영어\n", t3.rt.editor_doc.?.file.content);
    try testing.expect(std.unicode.utf8ValidateSlice(t3.rt.editor_doc.?.file.content));
}

test "AID1 괄호를 치면 닫히고 caret이 가운데 선다 (§3.7)" {
    // **§1.1의 "VSCode 무회귀"에서 없으면 즉시 체감되는 보조다.** 그리고 caret이 닫는 괄호
    // **뒤**에 서면 자동 닫기가 오히려 방해가 된다 — 사용자는 그 **안에** 이어 친다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid1.txt", "\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "("));
    try testing.expectEqualStrings("()\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(@as(usize, 1), term.rt.editor_selection.?.focus); // **가운데**

    // 이어서 치면 안에 들어간다.
    try testing.expect(insertText(fx.session, term, "x"));
    try testing.expectEqualStrings("(x)\n", term.rt.editor_doc.?.file.content);
}

test "AID2 닫는 괄호를 다시 치면 지나간다 — 겹쳐 쓰지 않는다 (type-over §3.7)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid2.txt", "\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "("));
    // `()`의 가운데에서 `)`를 치면 **하나 더 넣지 않고** caret만 넘어간다.
    const undo_before = term.rt.editor_undo_len;
    try testing.expect(insertText(fx.session, term, ")"));
    // **undo 스택이 안 늘었다.** 문서가 안 바뀐 편집을 쌓으면 되돌리기 한 번이 아무것도 안 하는
    // 것처럼 보인다 — 묶음이 그것을 가리므로(같은 종류·500ms 안이면 앞 편집과 한 묶음이 된다)
    // **문서 상태만으로는 안 드러난다**(적대적 검증 2026-08-27).
    try testing.expectEqual(undo_before, term.rt.editor_undo_len);
    try testing.expectEqualStrings("()\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(@as(usize, 2), term.rt.editor_selection.?.focus);

    // **빈 편집이 쌓이지 않았다** — undo가 헛돌면 사용자가 되돌리기를 믿지 못한다.
    //
    // 전부 건너뛴 경우를 못 알아보면 **길이 0짜리 delta가 undo 스택에 쌓이고**, 되돌리기 한 번이
    // 아무것도 안 바꾸는 것처럼 보인다(적대적 검증 2026-08-27 — 그 갈래를 지운 뮤턴트가 살아남아
    // 여기까지 재게 됐다). 그래서 **문서 상태만이 아니라 되돌리기 횟수**를 잰다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("\n", term.rt.editor_doc.?.file.content); // **한 번**에 원래대로
    try testing.expect(!undoEdit(fx.session, term)); // 더 되돌릴 것이 없다
}

test "AID3 선택이 있으면 감싼다 — 고른 것을 지우지 않는다 (surround §3.7)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid3.txt", "alpha beta\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5); // "alpha"
    try testing.expect(insertText(fx.session, term, "\""));
    try testing.expectEqualStrings("\"alpha\" beta\n", term.rt.editor_doc.?.file.content);

    // **한 번의 감싸기는 undo 하나다** — 앞뒤 두 변경이지만 `delta.apply` 한 번이다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("alpha beta\n", term.rt.editor_doc.?.file.content);
}

test "AID4 붙여넣기·IME 확정은 보조를 타지 않는다 (§3.7)" {
    // **여러 글자가 한 번에 오는 경로에서 괄호를 닫으면 사용자가 넣지 않은 문자가 문서에 들어간다.**
    // 한글 IME 확정(N3)이 같은 경로를 쓰므로 지금 막아 두는 것이 맞다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid4.txt", "\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "((")); // 두 글자 = 보조 없음
    try testing.expectEqualStrings("((\n", term.rt.editor_doc.?.file.content);

    // 붙여넣기도 마찬가지다.
    const t2 = try undoFixture(&fx, allocator, "aid4b.txt", "\n");
    t2.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(pasteText(fx.session, t2, "("));
    try testing.expectEqualStrings("(\n", t2.rt.editor_doc.?.file.content);
}

test "AID6 커서마다 판단이 달라도 각자 제자리에 선다 (§3.7 × §9.1)" {
    // **커서 하나는 지나가고(type-over) 다른 하나는 넣는** 경우가 실재한다. caret 재배치가
    // `inverse.changes`와 **인덱스로** 맞추는데 건너뛴 커서가 delta에 안 실리면 그 뒤 커서들이
    // 밀려 **엉뚱한 자리로 튄다** — 실측으로 잡았다(적대적 검증 2026-08-27: type-over 커서가
    // 다른 커서 자리인 4로 갔다).
    //
    // 고친 방식은 **빈 변경으로 자리를 지키는 것**이다: 길이 0에 빈 텍스트라 버퍼는 안 바뀌고
    // 인덱스만 맞는다. 전부 건너뛴 경우는 delta 없이 끝내 **빈 편집이 undo에 쌓이지 않는다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid6.txt", "a) b\n");

    term.rt.editor_selection = editor_selection.Selection.at(1); // ")" 앞 → 지나간다
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.at(4); // "b" 뒤 → 넣는다
    term.rt.editor_extra_selections = extras;

    try testing.expect(insertText(fx.session, term, ")"));
    try testing.expectEqualStrings("a) b)\n", term.rt.editor_doc.?.file.content);

    // 각자 제자리다 — 지나간 커서는 `)` **뒤**(2), 넣은 커서는 넣은 것 뒤(5).
    const a = term.rt.editor_selection.?.focus;
    const b = term.rt.editor_extra_selections[0].focus;
    try testing.expect((a == 2 and b == 5) or (a == 5 and b == 2));
}

test "AID7 감싸기가 커서 여럿·역방향 선택에서도 맞는다 (§3.7 × §9.1)" {
    // **감싸기는 한 커서당 변경 둘**(여는 것·닫는 것)이라, 커서가 여럿이면 delta에 네 개가 실린다.
    // 정렬·비겹침이 깨지면 `apply`가 통째로 거절하고 **아무 일도 안 일어난다** — 사용자는 `(`가
    // 죽은 키가 된 것으로 겪는다.
    //
    // **역방향 선택**(뒤에서 앞으로 끌어 고른 것)도 같은 자리다. `start()`/`end()`가 정렬해 주므로
    // 맞아야 하지만, 그 전제가 이 경로에서 지켜지는지는 별개다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // ⑴ 커서 둘이 각자 낱말을 감싼다.
    const term = try undoFixture(&fx, allocator, "aid7.txt", "aa bb\n");
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2);
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.fromPoints(3, 5);
    term.rt.editor_extra_selections = extras;
    try testing.expect(insertText(fx.session, term, "("));
    try testing.expectEqualStrings("(aa) (bb)\n", term.rt.editor_doc.?.file.content);

    // **한 번의 감싸기는 undo 하나다** — 커서가 둘이어도(§3.3).
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("aa bb\n", term.rt.editor_doc.?.file.content);

    // ⑵ 역방향 선택도 같다.
    const t2 = try undoFixture(&fx, allocator, "aid7b.txt", "xyz\n");
    t2.rt.editor_selection = editor_selection.Selection.fromPoints(3, 0); // 뒤에서 앞으로
    try testing.expect(insertText(fx.session, t2, "["));
    try testing.expectEqualStrings("[xyz]\n", t2.rt.editor_doc.?.file.content);
}

test "AID8 다른 편집이 끼면 자동 닫기 표식이 낡지 않는다 (§3.7)" {
    // **표식은 offset이라 그 앞이 바뀌면 뜻이 달라진다.** 붙여넣기·다른 커서의 편집이 앞쪽 길이를
    // 바꾸면 같은 숫자가 **다른 글자**를 가리키고, 그때 Backspace를 누르면 사용자가 직접 친 글자가
    // 함께 사라진다.
    //
    // 지금은 `breakUndoGroup`이 표식을 버리므로 안전하다 — 그 함수가 *"커서가 편집 아닌 이유로
    // 움직였다"*의 단일 자리이고 붙여넣기도 그것을 부른다. **그 결합이 이 판정자의 대상**이다:
    // 둘이 갈리면 여기서 잡힌다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid8.txt", "\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "("));
    try testing.expectEqualStrings("()\n", term.rt.editor_doc.?.file.content);
    try testing.expect(term.rt.editor_auto_closed_at != null);

    // **붙여넣기가 사이에 낀다** — 표식이 버려져야 한다.
    try testing.expect(pasteText(fx.session, term, "XY"));
    try testing.expectEqualStrings("(XY)\n", term.rt.editor_doc.?.file.content);
    try testing.expect(term.rt.editor_auto_closed_at == null);

    // Backspace는 **"Y"만** 지운다 — 표식이 남아 있었으면 ")"까지 함께 갔을 것이다.
    try testing.expect(deleteText(fx.session, term, true));
    try testing.expectEqualStrings("(X)\n", term.rt.editor_doc.?.file.content);
}

test "AID9 문맥을 못 물어 생기는 한계를 못 박는다 (§3.7 저하 동작)" {
    // **§3.7이 정한 저하 동작의 경계를 판정자로 고정한다.** 토큰 층(§5.3)이 없으므로 "지금
    // 문자열/주석 안인가"를 못 묻고, 그래서 **문자열 안에서도 괄호가 닫힌다**. 그것이 지금의
    // 계약이고, grammar가 붙으면 달라진다 — 그때 이 판정자가 **바뀌어야 할 자리**를 가리킨다.
    //
    // 판정자를 안 두면 나중에 문맥 판정을 넣었을 때 "원래 이랬나 아닌가"를 아무도 모른다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "aid9.txt", "s = \"\"\n");

    // 문자열 **안**(따옴표 사이)에서 `(`를 친다 — 문맥을 알면 안 닫는 쪽이 낫지만 지금은 닫는다.
    term.rt.editor_selection = editor_selection.Selection.at(5);
    try testing.expect(insertText(fx.session, term, "("));
    try testing.expectEqualStrings("s = \"()\"\n", term.rt.editor_doc.?.file.content);

    // **읽기 전용·비교 뷰에서는 보조 이전에 편집 자체가 막힌다** — 보조가 그 문을 우회하지 않는다.
    term.rt.editor_doc.?.file.read_only = true;
    try testing.expect(!insertText(fx.session, term, "("));
    term.rt.editor_doc.?.file.read_only = false;
    term.rt.editor_diff = .{};
    try testing.expect(!insertText(fx.session, term, "("));
    term.rt.editor_diff = null;
    try testing.expectEqualStrings("s = \"()\"\n", term.rt.editor_doc.?.file.content);
}

test "AID10 한글 주변과 Enter에서도 규칙이 그대로다 (§3.7 × §3.2)" {
    // **낱말 판정이 byte 기준**(`b >= 0x80`)이라 한글도 낱말이다. 그 판정이 어긋나면 한국어
    // 문서에서 괄호가 엉뚱하게 닫히거나 안 닫힌다 — 이 저장소의 주 사용자가 겪는 자리다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // ⑴ 한글 **뒤**에서는 닫는다 — 뒤가 줄 끝이라 막을 이유가 없다.
    const t1 = try undoFixture(&fx, allocator, "aid10.txt", "한글\n");
    t1.rt.editor_selection = editor_selection.Selection.at(6);
    try testing.expect(insertText(fx.session, t1, "("));
    try testing.expectEqualStrings("한글()\n", t1.rt.editor_doc.?.file.content);

    // ⑵ 한글 **앞**에서는 안 닫는다 — `(한글`을 의도한 것이지 `()한글`이 아니다.
    const t2 = try undoFixture(&fx, allocator, "aid10b.txt", "한글\n");
    t2.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, t2, "("));
    try testing.expectEqualStrings("(한글\n", t2.rt.editor_doc.?.file.content);

    // ⑶ `()` 사이 Enter는 **줄만 나눈다** — 자동 들여쓰기는 언어 판정(§5)이 서야 하고
    //    그때까지 계약 밖이다(§3.7이 문맥을 요구하는 자리와 같은 이유).
    const t3 = try undoFixture(&fx, allocator, "aid10c.txt", "\n");
    t3.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, t3, "("));
    try testing.expect(insertText(fx.session, t3, "\n"));
    try testing.expectEqualStrings("(\n)\n", t3.rt.editor_doc.?.file.content);
}

test "AID11 커서가 많아도 재배치가 곱해지지 않는다 (§9.1 — 실측)" {
    // **`MC3`이 "마크 저장소가 커서 수에 곱해지지 않는다"를 실측으로 고정한 것과 같은 축.**
    // caret 재배치가 커서마다 건너뛴 목록을 훑으면 **커서 수에 곱해진다** — 상한이 10,000이라
    // 1억 번이다(적대적 검증 2026-08-27이 그 형태를 잡았다).
    //
    // 목록이 **오름차순**이라는 성질을 쓰면 한 번의 훑기로 된다. 그 성질이 깨지면 답이 틀리므로,
    // 이 판정자는 **큰 입력에서 답이 맞는지**로 그것을 함께 지킨다(시간을 재면 기계마다 갈린다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // ")" 가 많은 문서에서 커서를 잔뜩 세워 **전부 type-over** 시킨다.
    const n = 2000;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..n) |_| try doc.appendSlice(allocator, "x)");
    try doc.append(allocator, '\n');
    const term = try undoFixture(&fx, allocator, "aid11.txt", doc.items);

    term.rt.editor_selection = editor_selection.Selection.at(1); // 첫 ")" 앞
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, n - 1);
    for (extras, 1..) |*e, k| e.* = editor_selection.Selection.at(k * 2 + 1);
    term.rt.editor_extra_selections = extras;

    // **전부 지나간다** — 문서는 안 바뀌고 커서만 한 칸씩 간다.
    const before_len = term.rt.editor_doc.?.file.content.len;
    try testing.expect(insertText(fx.session, term, ")"));
    try testing.expectEqual(before_len, term.rt.editor_doc.?.file.content.len);
    try testing.expectEqual(@as(usize, 2), term.rt.editor_selection.?.focus);
    try testing.expectEqual(@as(usize, n * 2), term.rt.editor_extra_selections[n - 2].focus);

    // **섞인 경우**도 큰 입력에서 맞는다 — 오름차순 전제가 깨지면 여기서 어긋난다.
    const t2 = try undoFixture(&fx, allocator, "aid11b.txt", doc.items);
    t2.rt.editor_selection = editor_selection.Selection.at(1); // 지나간다
    const ex2 = try fx.session.allocator.alloc(editor_selection.Selection, 2);
    ex2[0] = editor_selection.Selection.at(2); // "x" 앞 → 평범한 삽입
    ex2[1] = editor_selection.Selection.at(3); // ")" 앞 → 지나간다
    t2.rt.editor_extra_selections = ex2;
    try testing.expect(insertText(fx.session, t2, ")"));
    // 첫·셋째는 지나가고 둘째만 넣었다 — 길이가 정확히 1 늘었다.
    try testing.expectEqual(before_len + 1, t2.rt.editor_doc.?.file.content.len);
}

test "LN1 줄 삭제 — 마지막 줄은 앞 개행을 먹어 빈 줄을 안 남긴다 (§3.9a)" {
    // **뒤에 개행이 없는데 내용만 지우면 빈 줄이 남는다** — 사용자 눈에는 "지웠는데 자리가 남는다".
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln1.zig", "a\nb\nc");
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(deleteLines(fx.session, term));
    try testing.expectEqualStrings("b\nc", term.rt.editor_doc.?.file.content);

    // **마지막 줄** — 앞 개행까지 먹는다.
    term.rt.editor_selection = editor_selection.Selection.at(term.rt.editor_doc.?.file.content.len);
    try testing.expect(deleteLines(fx.session, term));
    try testing.expectEqualStrings("b", term.rt.editor_doc.?.file.content);
}

test "LN2 줄 조작은 선택이 걸친 줄만 건드린다 — 다음 줄 머리는 뺀다 (§3.9a)" {
    // 줄 전체를 끌어 고르면 끝 offset 이 **다음 줄 0** 이 된다. 그대로 세면 고르지 않은 줄이 지워진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln2.zig", "aa\nbb\ncc\n");
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 3); // "aa\n" — 둘째 줄 머리
    try testing.expect(deleteLines(fx.session, term));
    try testing.expectEqualStrings("bb\ncc\n", term.rt.editor_doc.?.file.content);
}

test "LN3 줄 복제 — 연속한 줄은 한 덩어리다 (§3.9a)" {
    // **줄마다 따로 넣으면 A B 가 A A B B 가 되어 블록이 깨진다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln3.zig", "a\nb\nc\n");
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 3); // a, b
    try testing.expect(duplicateLines(fx.session, term));
    try testing.expectEqualStrings("a\nb\na\nb\nc\n", term.rt.editor_doc.?.file.content);

    // **선택이 복사본으로 옮겨져야 한다.** 원본에 남으면 다시 눌렀을 때 **같은 줄이 또 복제되어**
    // 사용자가 만든 복사본이 아니라 원본만 늘어난다(변이 L16).
    // **자리를 정확히 못박는다.** 「4 이상」 같은 부등식이면 **절반만 민** 구현도 통과한다 —
    // 내용은 우연히 같아지기 때문이다(변이 L19 가 그렇게 살아남았다). 블록이 `"a\nb\n"`(4 byte)이므로
    // 선택 `[0,3)` 은 정확히 `[4,7)` 이 되어야 한다.
    try testing.expectEqual(@as(usize, 4), term.rt.editor_selection.?.start());
    try testing.expectEqual(@as(usize, 7), term.rt.editor_selection.?.end());

    try testing.expect(duplicateLines(fx.session, term));
    try testing.expectEqualStrings("a\nb\na\nb\na\nb\nc\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(@as(usize, 8), term.rt.editor_selection.?.start());
}

test "LN4 줄 이동 — 맞바꾸고, 문서 끝에서는 무동작이다 (§3.9a)" {
    // **clamp 해서 절반만 움직이면 사용자가 무슨 일이 났는지 못 읽는다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln4.zig", "a\nb\nc\n");

    term.rt.editor_selection = editor_selection.Selection.at(0); // 첫 줄
    try testing.expect(!moveLines(fx.session, term, false)); // 위로 — 무동작
    try testing.expectEqualStrings("a\nb\nc\n", term.rt.editor_doc.?.file.content);

    try testing.expect(moveLines(fx.session, term, true)); // 아래로
    try testing.expectEqualStrings("b\na\nc\n", term.rt.editor_doc.?.file.content);

    // **위로도 된다** — 아래만 되는 구현은 위 단언만으로 안 잡힌다(변이 L17).
    const term2 = try undoFixture(&fx, allocator, "ln4b.zig", "a\nb\nc\n");
    term2.rt.editor_selection = editor_selection.Selection.at(2); // 둘째 줄
    try testing.expect(moveLines(fx.session, term2, false));
    try testing.expectEqualStrings("b\na\nc\n", term2.rt.editor_doc.?.file.content);

    // **문서 끝에서 아래로도 무동작이다.**
    term2.rt.editor_selection = editor_selection.Selection.at(4); // 마지막 줄
    try testing.expect(!moveLines(fx.session, term2, true));
    try testing.expectEqualStrings("b\na\nc\n", term2.rt.editor_doc.?.file.content);
}

test "LN5 들여쓰기는 탭 문자 — 빈 줄은 안 건드리고, 내어쓰기는 있는 만큼만 (§3.9a)" {
    // 들여쓰기 문자가 `Tab` 키와 갈리면 **같은 키가 선택 여부에 따라 다른 문자를 넣는다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln5.zig", "a\n\nb\n");
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5); // 세 줄 전부

    try testing.expect(indentLines(fx.session, term, false));
    try testing.expectEqualStrings("\ta\n\n\tb\n", term.rt.editor_doc.?.file.content); // 빈 줄은 그대로

    // **내어쓰기는 있는 만큼만** — 뺄 것 없는 줄이 섞여도 연산이 통째로 실패하지 않는다.
    try testing.expect(indentLines(fx.session, term, true));
    try testing.expectEqualStrings("a\n\nb\n", term.rt.editor_doc.?.file.content);
    try testing.expect(!indentLines(fx.session, term, true)); // 더 뺄 것이 없다

    // **공백 들여쓰기는 `editor.tab-width` 만큼 뺀다** — 한 칸만 빼면 네 번 눌러야 한 단계가 풀려
    // 사용자가 「내어쓰기가 안 먹는다」로 읽는다(변이 L23).
    const term4 = try undoFixture(&fx, allocator, "ln5c.zig", "    a\n");
    term4.rt.editor_tab_width = 4;
    term4.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(indentLines(fx.session, term4, true));
    try testing.expectEqualStrings("a\n", term4.rt.editor_doc.?.file.content);

    // **섞이면 있는 쪽만 뺀다** — 뺄 것 없는 줄 하나 때문에 연산이 통째로 실패하면, 블록을 고를
    // 때마다 내어쓰기가 죽는다(변이 L7).
    const term2 = try undoFixture(&fx, allocator, "ln5b.zig", "\tx\ny\n");
    term2.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5);
    try testing.expect(indentLines(fx.session, term2, true));
    try testing.expectEqualStrings("x\ny\n", term2.rt.editor_doc.?.file.content);
}

test "LN6 Enter 가 이전 줄 들여쓰기를 잇는다 — caret 앞까지만 본다 (§3.9a)" {
    // **줄 가운데서 치면 뒤 절반이 다음 줄로 가는데, 들여쓰기는 원래 줄의 것이다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln6.zig", "\t\tab\n");

    term.rt.editor_selection = editor_selection.Selection.at(3); // "\t\ta" 뒤 (b 앞)
    try testing.expect(insertNewlineKeepingIndent(fx.session, term));
    try testing.expectEqualStrings("\t\ta\n\t\tb\n", term.rt.editor_doc.?.file.content);

    // **선택이 있으면 지운 뒤 그 자리의 줄을 본다**(§3.9a). 안 지우면 Enter 가 고른 글자를 남긴 채
    // 줄만 늘려, 사용자가 「바꿔 쓰려고 골랐는데 그대로 있다」를 본다(변이 L24).
    const term4 = try undoFixture(&fx, allocator, "ln6d.zig", "\tab\n");
    term4.rt.editor_selection = editor_selection.Selection.fromPoints(1, 3); // "ab"
    try testing.expect(insertNewlineKeepingIndent(fx.session, term4));
    try testing.expectEqualStrings("\t\n\t\n", term4.rt.editor_doc.?.file.content);

    // **caret 이 들여쓰기 안에 있으면 그 앞까지만 잇는다** — 줄 전체를 보면 뒤쪽 들여쓰기까지
    // 세어 사용자가 자르지 않은 공백이 새 줄에 들어간다(변이 L9).
    const term3 = try undoFixture(&fx, allocator, "ln6c.zig", "\t\tab\n");
    term3.rt.editor_selection = editor_selection.Selection.at(1); // 탭 하나 뒤
    try testing.expect(insertNewlineKeepingIndent(fx.session, term3));
    try testing.expectEqualStrings("\t\n\t\tab\n", term3.rt.editor_doc.?.file.content);

    // **들여쓰기가 없으면 종전 경로** — 개행만 들어간다.
    const term2 = try undoFixture(&fx, allocator, "ln6b.zig", "x\n");
    term2.rt.editor_selection = editor_selection.Selection.at(1);
    try testing.expect(insertNewlineKeepingIndent(fx.session, term2));
    try testing.expectEqualStrings("x\n\n", term2.rt.editor_doc.?.file.content);
}

test "LN9 줄 조작은 앞뒤 타이핑과 한 undo 로 뭉치지 않는다 (§3.3 연산 종류 변경)" {
    // **꼬리가 `breakUndoGroup` 을 빠뜨리면 타이핑과 한 묶음이 된다** — 되돌리기 한 번에 사용자가
    // 친 글자까지 사라진다(변이 L22). CMT9 가 주석 토글에 대해 세운 것과 같은 판정이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln9.zig", "a\nb\n");

    term.rt.editor_selection = editor_selection.Selection.at(1);
    try testing.expect(insertText(fx.session, term, "X"));
    try testing.expectEqualStrings("aX\nb\n", term.rt.editor_doc.?.file.content);

    try testing.expect(deleteLines(fx.session, term));
    try testing.expectEqualStrings("b\n", term.rt.editor_doc.?.file.content);

    // **되돌리기 한 번은 줄 삭제만 푼다** — 친 글자는 남아 있어야 한다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("aX\nb\n", term.rt.editor_doc.?.file.content);
}

test "CS1 대소문자 변환 — 선택이 있으면 그 범위, 없으면 caret 의 낱말 (§3.9b)" {
    // **낱말 규칙은 `wordRangeAt` 하나가 소유한다** — 더블클릭·`add_next_occurrence` 와 같은 함수다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cs1.zig", "foo bar\n");

    // 선택 없음 — caret 이 `foo` 안이면 `foo` 만 바뀐다.
    term.rt.editor_selection = editor_selection.Selection.at(1);
    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("FOO bar\n", term.rt.editor_doc.?.file.content);

    // 선택 있음 — 그 범위만.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(4, 7); // "bar"
    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("FOO BAR\n", term.rt.editor_doc.?.file.content);

    // 소문자로 되돌린다 — 왕복이 원문이다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 7);
    try testing.expect(transformCase(fx.session, term, false));
    try testing.expectEqualStrings("foo bar\n", term.rt.editor_doc.?.file.content);
}

test "CS2 덮지 않는 글자는 그대로고, 바뀔 것이 없으면 무동작이다 (§3.9b)" {
    // **모르면 안 건드린다.** 그리고 바뀐 것이 없는데 delta 를 만들면 **undo 에 빈 항목**이 쌓여
    // 되돌리기를 눌러도 화면이 안 변한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cs2.zig", "가나다 ABC\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 9); // "가나다"
    try testing.expect(!transformCase(fx.session, term, true)); // 한글 — 바뀔 것이 없다
    try testing.expectEqualStrings("가나다 ABC\n", term.rt.editor_doc.?.file.content);

    // 이미 대문자인 범위도 무동작이다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(10, 13);
    try testing.expect(!transformCase(fx.session, term, true));
    try testing.expectEqualStrings("가나다 ABC\n", term.rt.editor_doc.?.file.content);
}

test "CS3 길이가 안 변해 다른 커서가 안 밀린다 — 키릴·그리스도 (§3.9b)" {
    // **1:N 매핑을 들이는 날 이 성질이 깨진다**(§3.9b 가 그때 보정 규칙을 함께 정하라고 적어 뒀다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cs3.zig", "абв αβγ\n");
    const before_len = term.rt.editor_doc.?.file.content.len;

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 6); // "абв"
    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("АБВ αβγ\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(before_len, term.rt.editor_doc.?.file.content.len);

    term.rt.editor_selection = editor_selection.Selection.fromPoints(7, 13); // "αβγ"
    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("АБВ ΑΒΓ\n", term.rt.editor_doc.?.file.content);
    try testing.expectEqual(before_len, term.rt.editor_doc.?.file.content.len);
}

test "CS7 멀티 커서면 전부 바뀌고 undo 하나다 (§3.9b)" {
    // **커서 하나만 바꾸면 나머지 자리는 그대로 남는다** — 「여기도 같이 고치겠다」로 커서를 늘린
    // 사용자에게 정확히 반대되는 결과다(변이 C13). §3.9a 와 달리 범위를 **합치지 않는다**:
    // 겹치는 것은 줄이 아니라 범위이고 대소문자는 멱등이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cs7.zig", "foo bar foo\n");

    // `⌘⌃D` 와 같은 길로 커서를 둘로 늘린다.
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 3, 3, .word);
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);

    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("FOO bar FOO\n", term.rt.editor_doc.?.file.content);

    // **전체가 undo 하나다**(§3.3) — 한 번에 둘 다 돌아온다.
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("foo bar foo\n", term.rt.editor_doc.?.file.content);
}

test "CS5 깨진 UTF-8 과 낱말 없는 자리는 문서를 안 바꾼다 (§3.8·§3.9b)" {
    // **문서 내용은 신뢰 입력이 아니다**(§3.8). 디코드가 실패하면 원문을 그대로 두어야지, 그 자리에
    // 무엇이든 써 넣으면 **화면과 파일이 갈린다**(변이 C5). 낱말이 없는 자리도 무동작이다(C7).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **깨진 UTF-8 은 여기까지 못 온다** — 문서가 열릴 때 검증되고 아니면 `error.NotUtf8` 이다.
    // 그 사실을 여기서 함께 못박는다: 이 전제가 무너지면 변환의 디코드 가지가 되살아난다.
    try testing.expectError(error.NotUtf8, maru.session.editor.document.open("a\xC3 b", false));

    // **낱말이 없는 자리** — 빈 문서에서 caret 이 어디에 있어도 무동작이다.
    const empty = try undoFixture(&fx, allocator, "cs5b.zig", "");
    empty.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!transformCase(fx.session, empty, true));
    try testing.expectEqualStrings("", empty.rt.editor_doc.?.file.content);

    // 공백만 있는 자리도 같다.
    const ws = try undoFixture(&fx, allocator, "cs5c.zig", "   \n");
    ws.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(!transformCase(fx.session, ws, true));
    try testing.expectEqualStrings("   \n", ws.rt.editor_doc.?.file.content);
}

test "CS4 변환도 비교 뷰·읽기 전용을 거절하고 undo 하나다 (§3.9b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cs4.zig", "ab cd\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    term.rt.editor_diff = .{ .requested_ms = 0 };
    try testing.expect(!transformCase(fx.session, term, true));
    try testing.expectEqualStrings("ab cd\n", term.rt.editor_doc.?.file.content);
    term.rt.editor_diff = null;

    // **타이핑과 한 undo 로 뭉치지 않는다**(§3.3 연산 종류 변경).
    term.rt.editor_selection = editor_selection.Selection.at(2);
    try testing.expect(insertText(fx.session, term, "X"));
    try testing.expectEqualStrings("abX cd\n", term.rt.editor_doc.?.file.content);
    term.rt.editor_selection = editor_selection.Selection.at(5); // "cd" 안
    try testing.expect(transformCase(fx.session, term, true));
    try testing.expectEqualStrings("abX CD\n", term.rt.editor_doc.?.file.content);
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("abX cd\n", term.rt.editor_doc.?.file.content);
}

test "LN8 줄 조작은 비교 뷰와 읽기 전용을 거절한다 (§3.9a)" {
    // **게이트를 재는 판정자가 없으면 지워도 전부 초록이다**(변이 L20·L21 이 그렇게 살아남았다).
    // 비교 뷰는 축이 둘이라(§4.1g) 문서 offset 이 성립하지 않고, 읽기 전용은 고칠 수 없는 파일이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln8.zig", "a\nb\n");
    term.rt.editor_selection = editor_selection.Selection.at(0);

    // **비교 뷰** — 넷 다 거절하고 문서는 그대로다.
    term.rt.editor_diff = .{ .requested_ms = 0 };
    try testing.expect(!deleteLines(fx.session, term));
    try testing.expect(!duplicateLines(fx.session, term));
    try testing.expect(!moveLines(fx.session, term, true));
    try testing.expect(!indentLines(fx.session, term, false));
    try testing.expect(!insertNewlineKeepingIndent(fx.session, term));
    try testing.expectEqualStrings("a\nb\n", term.rt.editor_doc.?.file.content);
    term.rt.editor_diff = null;

    // **읽기 전용** — 같은 자리에서 같은 답이다.
    term.rt.editor_doc.?.file.read_only = true;
    try testing.expect(!deleteLines(fx.session, term));
    try testing.expect(!duplicateLines(fx.session, term));
    try testing.expect(!moveLines(fx.session, term, true));
    try testing.expect(!indentLines(fx.session, term, false));
    try testing.expectEqualStrings("a\nb\n", term.rt.editor_doc.?.file.content);
    term.rt.editor_doc.?.file.read_only = false;

    // **정상 상태에서는 된다** — 위 단언이 「늘 거짓」으로 통과하지 않게 대조를 둔다.
    try testing.expect(deleteLines(fx.session, term));
    try testing.expectEqualStrings("b\n", term.rt.editor_doc.?.file.content);
}

test "LN7 ⇧⌘K 와 Tab/⇧Tab 이 실제로 닿는다 — 키 경로 전체 (§3.9a)" {
    // **함수를 직접 부르는 판정자만 있으면 배선이 빠져도 전부 초록이다**(CMT10 이 같은 이유로 섰다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "ln7.zig", "a\nb\n");

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try pressKey(&fx, .{ .char = 'k' }, .{ .command = true, .shift = true });
    try testing.expectEqualStrings("b\n", term.rt.editor_doc.?.file.content);

    // **선택이 한 줄 안이면 Tab 은 탭 문자다** — 아니면 글자를 못 넣는다.
    // **caret 이 줄 머리가 아니어야 갈린다** — 머리에서 재면 「그 자리에 넣기」와 「줄 들여쓰기」가
    // 같은 답을 내 변이가 살아남는다(L11).
    term.rt.editor_selection = editor_selection.Selection.at(1);
    try pressKey(&fx, .tab, .{});
    try testing.expectEqualStrings("b\t\n", term.rt.editor_doc.?.file.content);

    // **한 줄 안에서 여러 글자를 골라도 Tab 은 글자다** — offset 차이로 재면 긴 한 줄이 여러 줄로
    // 오인되어, 단어를 고르고 Tab 을 치면 **줄이 들여쓰기된다**(변이 L12).
    const term3 = try undoFixture(&fx, allocator, "ln7c.zig", "abcd\n");
    term3.rt.editor_selection = editor_selection.Selection.fromPoints(0, 3);
    try pressKey(&fx, .tab, .{});
    try testing.expectEqualStrings("\td\n", term3.rt.editor_doc.?.file.content);

    // **여러 줄이면 들여쓰기다.**
    const term2 = try undoFixture(&fx, allocator, "ln7b.zig", "a\nb\n");
    term2.rt.editor_selection = editor_selection.Selection.fromPoints(0, 3);
    try pressKey(&fx, .tab, .{});
    try testing.expectEqualStrings("\ta\n\tb\n", term2.rt.editor_doc.?.file.content);
    try pressKey(&fx, .tab, .{ .shift = true });
    try testing.expectEqualStrings("a\nb\n", term2.rt.editor_doc.?.file.content);
}

test "CMT7 한 줄에 커서가 여럿이어도 표식은 하나다 (§3.7)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "tmp.zig", "abcd\nefgh\n");

    // 같은 줄 안 세 자리 + 둘째 줄 한 자리. 줄을 두 번 세면 `//// abcd`가 된다.
    const extras = try allocator.alloc(editor_selection.Selection, 3);
    extras[0] = editor_selection.Selection.at(2);
    extras[1] = editor_selection.Selection.at(3);
    extras[2] = editor_selection.Selection.at(6);
    allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = extras;
    term.rt.editor_selection = editor_selection.Selection.at(1);

    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("// abcd\n// efgh\n", term.rt.editor_doc.?.file.content);
}

test "CMT8 여러 줄 토글이 되돌리기 한 번에 풀린다 (§3.3)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "tmp.zig", "a\nb\nc\n");
    try testing.expect(!isDirty(term));

    // 세 줄을 한 번에 주석 처리 — **한 번의 편집이므로 한 번의 되돌리기**여야 한다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5);
    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("// a\n// b\n// c\n", term.rt.editor_doc.?.file.content);
    try testing.expect(isDirty(term)); // 고쳤으니 표시가 뜬다(§3.5)

    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("a\nb\nc\n", term.rt.editor_doc.?.file.content);
    try testing.expect(!isDirty(term)); // 되돌리면 디스크와 같아진다

    try testing.expect(redoEdit(fx.session, term));
    try testing.expectEqualStrings("// a\n// b\n// c\n", term.rt.editor_doc.?.file.content);
}

test "CMT9 토글은 앞뒤 타이핑과 한 묶음이 되지 않는다 (§3.3 연산 종류 변경)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "tmp.zig", "a\n");

    term.rt.editor_selection = editor_selection.Selection.at(1);
    _ = insertText(fx.session, term, "X"); // 타이핑
    try testing.expectEqualStrings("aX\n", term.rt.editor_doc.?.file.content);
    try testing.expect(toggleLineComment(fx.session, term)); // 토글
    try testing.expectEqualStrings("// aX\n", term.rt.editor_doc.?.file.content);
    _ = insertText(fx.session, term, "Y"); // 다시 타이핑

    // **되돌리기 세 번이 세 단계로 풀려야 한다.** 묶이면 사용자가 토글만 되돌릴 수 없다.
    _ = undoEdit(fx.session, term);
    try testing.expectEqualStrings("// aX\n", term.rt.editor_doc.?.file.content);
    _ = undoEdit(fx.session, term);
    try testing.expectEqualStrings("aX\n", term.rt.editor_doc.?.file.content);
    _ = undoEdit(fx.session, term);
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);
}

test "CMT10 ⌘/ 키가 실제로 토글에 닿는다 — 키 경로 전체 (§3.7)" {
    // **함수를 직접 부르는 판정자만 있으면 배선이 빠져도 전부 초록이다.** 이 세션에서 두 번
    // 그렇게 죽은 키가 있었다(2026-08-25 `MC1`, `⌘⌫`). 그래서 `handleKeyEvent`부터 지난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cmt10.zig", "a\n");
    term.rt.editor_selection = editor_selection.Selection.at(0);

    try pressKey(&fx, .{ .char = '/' }, .{ .command = true });
    try testing.expectEqualStrings("// a\n", term.rt.editor_doc.?.file.content);

    // 다시 누르면 풀린다 — 같은 chord가 양방향이다.
    try pressKey(&fx, .{ .char = '/' }, .{ .command = true });
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);

    // **수식키를 가린다.** 맨 `/`나 `⌥/`·`⌃/`가 토글이면 사용자가 `/`를 칠 때마다 줄이 뒤집힌다.
    // (글자 입력 자체는 이 경로가 아니라 Swift 입력 진입점이 받으므로 여기서는 **토글 여부**만 잰다.)
    try pressKey(&fx, .{ .char = '/' }, .{});
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);
    try pressKey(&fx, .{ .char = '/' }, .{ .option = true });
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);
    try pressKey(&fx, .{ .char = '/' }, .{ .control = true });
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);
}

test "CMT5 선택이 다음 줄 머리에서 끝나면 그 줄은 빼고 센다 (§3.7)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "tmp.zig", "a\nb\nc\n");

    // 첫 줄을 끝까지 끌어 고르면 끝이 **둘째 줄 offset 0**이 된다. 둘째 줄은 고른 게 아니다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 2);
    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("// a\nb\nc\n", term.rt.editor_doc.?.file.content);

    // 반대로 **둘째 줄 안까지** 뻗으면 둘 다 들어간다 (깨끗한 문서로 다시 잰다).
    const t2 = try undoFixture(&fx, allocator, "tmp2.zig", "a\nb\nc\n");
    t2.rt.editor_selection = editor_selection.Selection.fromPoints(0, 3);
    try testing.expect(toggleLineComment(fx.session, t2));
    try testing.expectEqualStrings("// a\n// b\nc\n", t2.rt.editor_doc.?.file.content);
}

test "CMT6 공백 없이 붙은 주석도 푼다 (§3.7)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 사람이 손으로 `//`만 붙인 줄. 뒤 공백을 **있을 때만** 지워야 글자를 먹지 않는다.
    const term = try undoFixture(&fx, allocator, "tmp.zig", "//a\n");
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("a\n", term.rt.editor_doc.?.file.content);
}

test "CMT1 ⌘/가 줄을 주석 처리하고 다시 누르면 푼다 (§3.7)" {
    // **§3.7이 요구하는 셋**: selection이 걸친 줄 전체를 한 번에 · 들여쓰기 **뒤**에 넣기 ·
    // 전체가 undo 하나. 그리고 `⌘C`·`⌘V`처럼 Swift 진입점이 없어 **키 분기**에서 잡는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cmt1.zig", "    const a = 1;\n    const b = 2;\n");

    // 두 줄을 걸쳐 고른다.
    term.rt.editor_selection = editor_selection.Selection.fromPoints(4, 22);
    try pressKey(&fx, .{ .char = '/' }, .{ .command = true });
    // **들여쓰기 뒤**에 들어간다 — 줄 머리에 넣으면 들여쓰기가 무너져 보인다.
    try testing.expectEqualStrings("    // const a = 1;\n    // const b = 2;\n", term.rt.editor_doc.?.file.content);

    // **한 번**에 돌아온다(§3.3).
    try testing.expect(undoEdit(fx.session, term));
    try testing.expectEqualStrings("    const a = 1;\n    const b = 2;\n", term.rt.editor_doc.?.file.content);

    // 다시 주석 처리한 뒤 또 누르면 **푼다** — 표식과 그 뒤 공백 하나까지.
    try pressKey(&fx, .{ .char = '/' }, .{ .command = true });
    try pressKey(&fx, .{ .char = '/' }, .{ .command = true });
    try testing.expectEqualStrings("    const a = 1;\n    const b = 2;\n", term.rt.editor_doc.?.file.content);
}

test "CMT2 하나라도 주석이 아니면 전부 주석이다 (§3.7 — VSCode 관례)" {
    // **섞여 있을 때 "전부 해제"로 가면 주석이던 줄이 코드가 되어** 사용자가 의도하지 않은 실행이
    // 생긴다. 반대 방향은 되돌리기 쉽고 이쪽은 아니다 — 그래서 §3.7이 방향을 못 박았다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cmt2.zig", "// a\nb\n// c\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 11); // 세 줄 전부
    try testing.expect(toggleLineComment(fx.session, term));
    // 가운데만 주석이 아니었으므로 **전부 주석**이 된다(이미 주석인 줄에도 하나 더).
    try testing.expectEqualStrings("// // a\n// b\n// // c\n", term.rt.editor_doc.?.file.content);

    // 이제 전부 주석이므로 다음 토글은 **해제**다.
    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("// a\nb\n// c\n", term.rt.editor_doc.?.file.content);
}

test "CMT3 언어를 모르면 아무 일도 안 한다 (§3.7 no-op)" {
    // **모르는 파일에 아무 문법이나 넣으면 사용자가 그 언어에 없는 문자를 문서에 박는다.**
    // §3.7이 *"없으면 주석 토글이 no-op"*이라고 정한 이유다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const unknown = try undoFixture(&fx, allocator, "data.bin", "x\n");
    unknown.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!toggleLineComment(fx.session, unknown));
    try testing.expectEqualStrings("x\n", unknown.rt.editor_doc.?.file.content);

    // **HTML은 줄 주석이 없다** — 블록만 있으므로 이 슬라이스에서는 no-op이다.
    const html = try undoFixture(&fx, allocator, "a.html", "<p>\n");
    html.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(!toggleLineComment(fx.session, html));

    // 언어별 문법이 실제로 갈린다 — 셸은 `#`이다.
    const sh = try undoFixture(&fx, allocator, "run.sh", "echo hi\n");
    sh.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(toggleLineComment(fx.session, sh));
    try testing.expectEqualStrings("# echo hi\n", sh.rt.editor_doc.?.file.content);
}

test "CMT4 빈 줄은 건드리지 않고, 판단에서도 뺀다 (§3.7)" {
    // **빈 줄에 주석을 넣으면 공백만 남은 줄이 늘어난다.** 그리고 빈 줄 하나 때문에 전체가
    // "주석 아님"으로 뒤집히면 **이미 다 주석인 블록을 해제할 수 없다** — 판단에서도 빼야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "cmt4.zig", "// a\n\n// b\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 10);
    // 빈 줄을 빼면 **둘 다 주석**이므로 해제가 맞다.
    try testing.expect(toggleLineComment(fx.session, term));
    try testing.expectEqualStrings("a\n\nb\n", term.rt.editor_doc.?.file.content);
}

test "AID5 자동으로 넣은 닫는 문자만 backspace로 함께 지운다 (§3.7)" {
    // **§3.7: "자동으로 넣은 닫는 문자만 backspace로 함께 지운다. 사용자가 직접 친 것은 지우지
    // 않는다."** 자동 닫기가 만든 일은 자동 닫기가 되물러야 한다 — 여는 것만 지우고 닫는 것이
    // 남으면 사용자가 그것을 또 지운다.
    //
    // 그리고 **표시는 caret이 떠나면 버린다**: 안 버리면 한참 뒤에 그 자리로 돌아와 Backspace를
    // 눌렀을 때 **옆 글자가 함께 사라진다** — 사용자가 안 만든 규칙에 당한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // ⑴ 자동으로 닫은 직후 Backspace → **둘 다** 사라진다.
    const term = try undoFixture(&fx, allocator, "aid5.txt", "\n");
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, term, "("));
    try testing.expectEqualStrings("()\n", term.rt.editor_doc.?.file.content);
    try testing.expect(deleteText(fx.session, term, true));
    try testing.expectEqualStrings("\n", term.rt.editor_doc.?.file.content);

    // ⑴′ **문자 단위일 때만 함께 지운다.** `⌥⌫`(낱말)·`⌘⌫`(줄)는 사용자가 **범위를 정해** 지우는
    //     것이라, 거기에 자동 닫기 보정을 얹으면 **요청한 것보다 한 글자 더** 사라진다 —
    //     그 축이 판정 밖이었다(적대적 검증 2026-08-27 — 단위 조건을 지운 뮤턴트가 살아남았다).
    {
        const t = try undoFixture(&fx, allocator, "aid5d.txt", "ab\n");
        t.rt.editor_selection = editor_selection.Selection.at(2);
        try testing.expect(insertText(fx.session, t, "(")); // "ab()" — 표식이 선다
        try testing.expectEqualStrings("ab()\n", t.rt.editor_doc.?.file.content);
        // 낱말 삭제는 **자동 닫은 ")"를 안 먹는다** — "ab("까지가 낱말 경계다.
        try testing.expect(deleteBy(fx.session, t, true, .word));
        try testing.expectEqualStrings(")\n", t.rt.editor_doc.?.file.content);
    }

    // ⑵ **사용자가 직접 친 닫는 문자는 안 지운다.**
    const t2 = try undoFixture(&fx, allocator, "aid5b.txt", "x)\n");
    t2.rt.editor_selection = editor_selection.Selection.at(1); // "x" 뒤, ")" 앞
    try testing.expect(deleteText(fx.session, t2, true));
    try testing.expectEqualStrings(")\n", t2.rt.editor_doc.?.file.content); // ")"는 남는다

    // ⑶ **커서가 떠나면 표시를 버린다.** 자동으로 닫고 → 옮기고 → 돌아와서 Backspace.
    const t3 = try undoFixture(&fx, allocator, "aid5c.txt", "\n");
    t3.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, t3, "["));
    try testing.expectEqualStrings("[]\n", t3.rt.editor_doc.?.file.content);
    try testing.expect(moveCarets(fx.session, t3, .char_right, false)); // 떠난다
    try testing.expect(moveCarets(fx.session, t3, .char_left, false)); // 돌아온다
    try testing.expect(deleteText(fx.session, t3, true));
    // **"["만** 사라진다 — 표시를 안 버렸으면 "]"까지 함께 갔을 것이다.
    try testing.expectEqualStrings("]\n", t3.rt.editor_doc.?.file.content);
}

test "EDIT8 편집하면 커서가 보이는 자리로 따라온다 (§5.2 줄 축)" {
    // **`moveCarets`는 노출을 부르는데 편집 경로 셋(타이핑·삭제·붙여넣기)은 안 불렀다**
    // (적대적 검증 2026-08-26). 화면 밖에서 편집하면 — 스크롤해 둔 뒤 `⌘V`를 누르거나,
    // 검색으로 커서를 옮겼다가 치면 — **자기가 어디를 고치는지 못 본다.**
    //
    // 이동은 "커서를 옮기는 것이 목적"이라 노출이 당연해 보이지만, 편집도 **커서가 그 자리에
    // 있다는 전제**로 일어난다. 그래서 같은 규칙이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..200) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    const term = try undoFixture(&fx, allocator, "edit8.txt", doc.items);

    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    // 화면을 아래로 굴려 두고, **위쪽 줄**에 커서를 둔 채 편집한다.
    setEditorTop(fx.session, term, 100);
    term.rt.editor_selection = editor_selection.Selection.at(0);

    try testing.expect(insertText(fx.session, term, "X"));
    try testing.expectEqual(@as(u32, 0), term.rt.editor_first_line); // **따라왔다**

    // 붙여넣기도 같다.
    setEditorTop(fx.session, term, 100);
    try testing.expect(pasteText(fx.session, term, "Y"));
    try testing.expectEqual(@as(u32, 0), term.rt.editor_first_line);

    // 삭제도 같다.
    setEditorTop(fx.session, term, 100);
    try testing.expect(deleteText(fx.session, term, true));
    try testing.expectEqual(@as(u32, 0), term.rt.editor_first_line);

    // **이미 보이는 자리에서 치면 화면이 안 움직인다.**
    //
    // `refreshAfterEdit`가 렌더 스냅숏을 비우므로(§4.1g ⑸) 편집 직후의 노출은 "아직 안 그렸다"
    // 갈래로 떨어지는데, 그 갈래가 커서 줄을 **맨 위에 둔다** — 그대로 두면 **한 글자 칠 때마다
    // 화면이 그 줄을 천장으로 끌어올린다**(적대적 검증 2026-08-26 — 폴백 행 수를 무시하는 뮤턴트가
    // 살아남아 이 축이 판정 밖임을 보였다).
    fx.session.gpu_quads.clearRetainingCapacity();
    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    d2.dl.deinit(allocator);
    setEditorTop(fx.session, term, 50);
    fx.session.gpu_quads.clearRetainingCapacity();
    var d3 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    d3.dl.deinit(allocator);
    const rows = drawnDocLines(term);
    try testing.expect(rows >= 2);

    // 화면 안(맨 위 다음 줄)에 커서를 두고 친다 — **top이 그대로여야 한다**.
    const inside = term.rt.editor_doc.?.file.lines.line(51).?;
    term.rt.editor_selection = editor_selection.Selection.at(inside.start);
    try testing.expect(insertText(fx.session, term, "Z"));
    try testing.expectEqual(@as(u32, 50), term.rt.editor_first_line);
}

test "EDIT7 뷰포트 위에서 줄이 늘어도 화면은 제자리다 — 스크롤 앵커 (§4.1c)" {
    // **문서에 "아는 대가"로 적어 두었던 자리를 닫는다.** 스크롤 앵커가 **줄 번호**라, 뷰포트
    // 위에서 줄이 늘거나 줄면 같은 번호가 다른 내용을 가리켜 **화면이 그만큼 흔들렸다**.
    // 멀티커서 편집·undo가 실제로 그렇게 한다.
    //
    // 고친 방식은 §4.1c가 예고한 승격이다 — 앵커를 **byte offset**으로 떠 두었다가 편집이 민
    // 만큼 옮긴다(`delta.mapOffset`이 그 규칙을 이미 소유한다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    const term = try undoFixture(&fx, allocator, "edit7.txt", doc.items);

    // 아래로 굴려 뷰포트를 문서 중간에 둔다.
    setEditorTop(fx.session, term, 40);
    const lines = term.rt.editor_doc.?.file.lines;
    const top_line = lines.line(40).?;
    const top_text = try allocator.dupe(u8, term.rt.editor_doc.?.file.content[top_line.start .. top_line.start + 7]);
    defer allocator.free(top_text);

    // **앵커 쌍을 직접 잰다.** 편집 함수를 통과시키면 caret 노출이 함께 돌아 화면을 커서 쪽으로
    // 옮기고(그것이 옳다 — `EDIT8`), 그러면 이 판정자가 앵커가 아니라 **노출을 재게 된다**
    // (적대적 검증 2026-08-26에 그 둘이 충돌해 드러났다).
    //
    // 둘은 **다른 것을 지킨다**: 노출은 *"내가 고치는 자리를 보여 준다"*, 앵커는 *"내가 안 건드린
    // 위쪽이 밀려도 화면은 제자리"*. 그래서 여기서는 **문서만 바꾸고** 앵커 쌍을 직접 부른다 —
    // 커서가 개입하지 않는, 앵커가 정확히 필요한 상황이다.
    const anchor = captureScrollAnchor(term).?;
    var sels_dummy = maru.session.editor.selection.Selections.init(
        (try allocator.alloc(editor_selection.Selection, 1))[0..1],
        0,
    );
    sels_dummy.items[0] = editor_selection.Selection.at(0);
    defer allocator.free(sels_dummy.items);
    const changes = [_]maru.session.editor.delta.Change{
        .{ .start = 0, .end = 0, .text = "a\nb\nc\n" },
    };
    var inv = try term.rt.editor_doc.?.file.apply(.{ .changes = &changes }, &sels_dummy);
    inv.deinit();
    refreshAfterEdit(fx.session, term, null) catch {};
    restoreScrollAnchor(fx.session, term, anchor, .{ .changes = &changes });

    // 맨 위 줄이 **같은 내용**을 가리켜야 한다 — 번호는 43으로 밀렸어도 화면은 제자리다.
    const now_top = term.rt.editor_first_line;
    const now_line = term.rt.editor_doc.?.file.lines.line(now_top).?;
    const now_text = term.rt.editor_doc.?.file.content[now_line.start .. now_line.start + 7];
    try testing.expectEqualStrings(top_text, now_text);
    try testing.expectEqual(@as(usize, 43), now_top); // 실제로 밀렸다(보정이 없으면 40에 머문다)

    // **지운 경우도 같다** — 위에서 줄이 줄면 앵커가 그만큼 당겨진다. 여기서도 편집 함수를
    // 통과시키지 않는다: `deleteText`는 caret 노출을 부르고, 커서가 0줄에 있으므로 화면이 거기로
    // 따라간다(그것이 옳다 — `EDIT8`). 이 판정자는 **앵커만** 재므로 델타를 직접 적용한다.
    const anchor2 = captureScrollAnchor(term).?;
    const changes2 = [_]maru.session.editor.delta.Change{
        .{ .start = 0, .end = 6, .text = "" }, // "a\nb\nc\n" 중 앞 셋을 지운다
    };
    sels_dummy.items[0] = editor_selection.Selection.at(0);
    var inv2 = try term.rt.editor_doc.?.file.apply(.{ .changes = &changes2 }, &sels_dummy);
    inv2.deinit();
    refreshAfterEdit(fx.session, term, null) catch {};
    restoreScrollAnchor(fx.session, term, anchor2, .{ .changes = &changes2 });

    const after_line = term.rt.editor_doc.?.file.lines.line(term.rt.editor_first_line).?;
    const after_text = term.rt.editor_doc.?.file.content[after_line.start .. after_line.start + 7];
    try testing.expectEqualStrings(top_text, after_text);
}

test "MOV9 랩이 켜지면 위/아래가 시각 행을 따라간다 — 이음매는 뒤 행 머리다 (§4.1g)" {
    // **문서에 "아는 대가"로 적어 두었던 자리를 닫는다**(§4 `assoc`).
    //
    // 논리 줄로만 움직이면 랩된 줄에서 ↓ 한 번이 화면에서 서너 행을 건너뛴다 — 사용자가 누른 것과
    // 화면이 안 맞는다. 그리고 **이음매 선택이 결정이 아니라 부수효과**였다: `paintCarets`의 열
    // 거르기가 caret을 늘 뒤 행 머리에 세우고 있었는데 우리가 고른 적이 없었다. 여기서 고른다 —
    // 목표 열이 행 경계에 걸리면 **뒤 행의 머리**다(CM6 `assoc = 1`과 같다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 화면 폭보다 훨씬 긴 줄 하나 — 여러 조각으로 접힌다.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    for (0..300) |i| try long.append(allocator, @intCast('a' + (i % 26)));
    try long.append(allocator, '\n');
    try long.appendSlice(allocator, "tail\n");
    const term = try undoFixture(&fx, allocator, "mov9.txt", long.items);

    term.rt.editor_wrap = true;
    term.rt.editor_selection = editor_selection.Selection.at(0);
    fx.session.gpu_quads.clearRetainingCapacity();
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(term.rt.editor_hit_rows_len > 1); // 실제로 접혔다

    // ⑴ **한 번의 ↓가 한 시각 행만큼** 간다 — 논리 줄이면 첫 줄을 통째로 지나 "tail"로 갔을 것이다.
    try testing.expect(moveCarets(fx.session, term, .line_down, false));
    const after_down = term.rt.editor_selection.?.focus;
    try testing.expect(after_down > 0);
    const first_line = term.rt.editor_doc.?.file.lines.line(0).?;
    try testing.expect(after_down < first_line.contentEnd()); // **아직 같은 논리 줄 안**이다

    // ⑵ 그 자리는 **뒤 행의 머리**다(이음매 결정) — 스냅숏의 조각 시작 열과 정확히 같다.
    const rows = term.rt.editor_hit_rows[0..term.rt.editor_hit_rows_len];
    var pcm2 = productColumnMap(term);
    const map2 = pcm2.map();
    const text = term.rt.editor_doc.?.file.content[first_line.start..first_line.contentEnd()];
    const landed_col = map2.columnOf(map2.ctx, text, after_down - first_line.start);
    try testing.expectEqual(rows[1].start_col, landed_col);

    // ⑶ ↑ 로 되돌아오면 제자리다 — 왕복이 성립해야 사용자가 방향키를 믿는다.
    try testing.expect(moveCarets(fx.session, term, .line_up, false));
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);
}

test "MOV8 문서 끝·처음을 넘지 않고, 나머지 커서만 움직여도 보고한다 (§3.2)" {
    // **경계 둘이 판정 밖에 있었다**(적대적 검증 2026-08-26):
    // ⑴ 아래 이동이 줄 수를 안 자르면 없는 줄을 집어 `line()`이 null → 커서가 제자리에 남는데,
    //    화면은 "움직였다"고 다시 그린다. 없는 줄을 집는 것 자체가 §3.2 밖이다.
    // ⑵ 나머지 커서만 움직인 경우를 안 세면 `moveCarets`가 false를 내고 **화면이 안 갱신된다** —
    //    커서는 옮겨졌는데 그대로 그려진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mov8.txt", "aa\nbb\ncc\n");

    // ⑴ 마지막 줄에서 아래로 — **끝에 머문다**(넘으면 없는 줄이다).
    const last = term.rt.editor_doc.?.file.lines;
    const last_line = last.line(last.lineCount() - 1).?;
    term.rt.editor_selection = editor_selection.Selection.at(last_line.start);
    const before = term.rt.editor_selection.?.focus;
    _ = moveCarets(fx.session, term, .line_down, false);
    try testing.expect(term.rt.editor_selection.?.focus >= before);
    try testing.expect(term.rt.editor_selection.?.focus <= term.rt.editor_doc.?.file.content.len);
    // 한 번 더 눌러도 같은 자리다 — 넘어가면 여기서 갈린다.
    const settled = term.rt.editor_selection.?.focus;
    _ = moveCarets(fx.session, term, .line_down, false);
    try testing.expectEqual(settled, term.rt.editor_selection.?.focus);

    // ⑴′ **PageDown이 문서 끝 근처**일 때가 진짜 갈림길이다(적대적 검증 2026-08-26 — 한 줄
    // 이동만 재서 자르기 뮤턴트가 살아남았다). 자르지 않으면 `line()`이 null을 내 **아무 일도
    // 안 하고**, 사용자는 문서 끝으로 못 간다. 자르면 **마지막 줄**에 선다 — 그것이 기대다.
    {
        fx.session.gpu_quads.clearRetainingCapacity();
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        drawn.dl.deinit(allocator);
        try testing.expect(pageRows(term) > 1); // 한 페이지가 여러 줄이어야 이 갈래가 열린다

        const first = term.rt.editor_doc.?.file.lines.line(0).?;
        term.rt.editor_selection = editor_selection.Selection.at(first.start);
        _ = moveCarets(fx.session, term, .page_down, false);
        const lines_now = term.rt.editor_doc.?.file.lines;
        const last_now = lines_now.line(lines_now.lineCount() - 1).?;
        try testing.expectEqual(last_now.start, term.rt.editor_selection.?.focus);
    }

    // ⑵ **primary는 못 움직이고 나머지만 움직이는** 배치를 만든다.
    term.rt.editor_selection = editor_selection.Selection.at(0); // 문서 처음 — 왼쪽으로 못 간다
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, 1);
    extras[0] = editor_selection.Selection.at(4); // 이쪽은 왼쪽으로 갈 수 있다
    term.rt.editor_extra_selections = extras;
    try testing.expect(moveCarets(fx.session, term, .char_left, false)); // **true여야 한다**
    try testing.expectEqual(@as(usize, 0), term.rt.editor_selection.?.focus);
    try testing.expectEqual(@as(usize, 3), term.rt.editor_extra_selections[0].focus);
}

test "MOV6 커서가 화면 밖으로 나가면 스크롤이 따라간다 (§5.2 줄 축)" {
    // **없으면 아래 화살표를 누르는 동안 커서가 화면 밖으로 사라진다** — 사용자는 자기가 어디를
    // 고치는지 못 본다. 반대로 매번 굴리면 화면이 계속 튄다(§5.2가 "이미 보이면 두라"고 요구).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..200) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    const term = try undoFixture(&fx, allocator, "mov6.txt", doc.items);

    // **프레임을 한 번 굳힌다.** 안 그러면 `editor_hit_rows_len == 0`이라 노출이 "아직 안 그렸다"
    // 갈래로만 돌고, **최소 스크롤과 "이미 보이면 두라"가 아예 실행되지 않는다** — 그 상태로
    // 뮤턴트 둘이 살아남았다(적대적 검증 2026-08-26). 재는 상황이 결함이 드러나는 상황과 달랐다.
    const freeze = struct {
        fn once(f: *PaneFixture, t: *Term) !void {
            f.session.gpu_quads.clearRetainingCapacity();
            var drawn = appendPaneFrame(f.session, f.leaf_rect, t) orelse return error.EditorPaneDidNotDraw;
            drawn.dl.deinit(testing.allocator);
        }
    }.once;

    term.rt.editor_selection = editor_selection.Selection.at(0);
    try freeze(&fx, term);
    try testing.expect(term.rt.editor_hit_rows_len > 0); // 스냅숏이 실제로 섰다
    const rows_shown = drawnDocLines(term);
    try testing.expect(rows_shown > 1);

    // ⑴ **이미 보이는 줄로 옮기면 굴리지 않는다** — 굴리면 화살표마다 화면이 튄다.
    const before_top = term.rt.editor_first_line;
    try testing.expect(moveCarets(fx.session, term, .line_down, false));
    try testing.expectEqual(before_top, term.rt.editor_first_line);

    // ⑵ **아래로 나가면 그 줄이 마지막 줄이 되도록만** 민다(가운데로 튕기지 않는다).
    term.rt.editor_selection = editor_selection.Selection.at(0);
    try freeze(&fx, term);
    const target_line: u32 = @intCast(rows_shown); // 화면 바로 아래 첫 줄
    const line = term.rt.editor_doc.?.file.lines.line(target_line).?;
    term.rt.editor_selection = editor_selection.Selection.at(line.start);
    revealPrimaryCaret(fx.session, term);
    // 마지막 줄이 되도록 밀었으면 top은 정확히 한 줄만큼 움직인다.
    try testing.expectEqual(@as(u32, 1), term.rt.editor_first_line);

    // ⑴′ **top이 0이 아닐 때** 보이는 줄 안에서 움직이면 그대로 둔다.
    //
    // 위 ⑴은 top이 0이라 최소 스크롤 공식이 포화 뺄셈으로 0을 내 **"이미 보이면 두라"를 지운
    // 뮤턴트와 같은 답**이 나왔다(적대적 검증 2026-08-26). top이 0에서 떨어져 있어야 갈린다 —
    // 지우면 보이는 줄인데도 그 줄을 **맨 아래로 끌어내리며 위로 굴러간다**.
    try freeze(&fx, term);
    try testing.expectEqual(@as(u32, 1), term.rt.editor_first_line);
    const visible_mid = term.rt.editor_doc.?.file.lines.line(2).?;
    term.rt.editor_selection = editor_selection.Selection.at(visible_mid.start);
    revealPrimaryCaret(fx.session, term);
    try testing.expectEqual(@as(u32, 1), term.rt.editor_first_line);

    // ⑶ 문서 끝까지 가면 따라가고, 처음으로 돌아오면 다시 0이다.
    try freeze(&fx, term);
    try testing.expect(moveCarets(fx.session, term, .doc_end, false));
    try testing.expect(term.rt.editor_first_line > 1);
    try freeze(&fx, term);
    try testing.expect(moveCarets(fx.session, term, .doc_start, false));
    try testing.expectEqual(@as(u32, 0), term.rt.editor_first_line);
}

test "MC9 커서 상한을 넘기면 더 늘지 않는다 (§9.1)" {
    // **상한이 근거 없이 서 있었다**(적대적 검증 2026-08-26 — 그 분기를 없앤 뮤턴트가 아무
    // 판정자도 깨지 않았다). 큰 파일에서 흔한 글자를 잡고 `⌘⌃D`를 누르고 있으면 커서 수가
    // 파일 크기만큼 자라고, 마크 저장소는 커서 수에 비례한다(`MC3`이 실측으로 고정한 성질).
    //
    // 상한까지 실제로 눌러 보는 것은 느리므로 **나머지 배열을 상한 직전으로 채워 두고** 한 번
    // 부른다 — 재는 것은 "상한에서 멈추는가" 하나다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = try undoFixture(&fx, allocator, "mc9.txt", "x x x x\n");

    term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 1);
    // 상한 직전까지 채운다. 세션이 이 배열의 주인이 되므로 세션 할당자로 잡는다.
    const fill = editor_selection.max_cursors - 1;
    const extras = try fx.session.allocator.alloc(editor_selection.Selection, fill);
    for (extras) |*e| e.* = editor_selection.Selection.fromPoints(0, 1);
    clearExtraSelections(fx.session, term);
    term.rt.editor_extra_selections = extras;

    // 한 번 더 부르면 **거절된다** — 배열도 그대로다.
    try testing.expect(!addNextOccurrence(fx.session, term));
    try testing.expectEqual(fill, term.rt.editor_extra_selections.len);
}

test "MC7 편집기 기능을 섞어 돌려도 불변식이 깨지지 않는다 (상호작용 퍼즈)" {
    // **판정자 하나하나는 기능을 하나씩 잰다 — 섞이는 자리는 아무도 안 본다.** 접힘이 켜진 채
    // 커서를 늘리고, 스크롤한 뒤 복사하고, 다시 펴는 식의 순서는 조합이 폭발해 손으로 못 적는다.
    // 그래서 무작위로 섞되 **매 걸음 불변식을 본다**: 죽지 않는가 · 띠가 줄 안에 있는가 ·
    // 띠 수가 커서 수를 넘지 않는가 · 커서가 문서 밖을 가리키지 않는가.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    var l: usize = 0;
    while (l < 120) : (l += 1) {
        // 들여쓰기를 섞어 접힘이 실제로 생기게 한다.
        if (l % 4 == 1 or l % 4 == 2) try doc.appendSlice(allocator, "    ");
        try doc.appendSlice(allocator, "target value here\n");
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "fuzz.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "fuzz.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **씨앗 하나로 통과한 것은 그 씨앗에서만 통과한 것이다.** 퍼즈는 순서를 흔드는 것이 목적인데
    // 고정 씨앗 하나는 순서를 **하나만** 본다 — 여럿을 돌려야 조합이 실제로 흔들린다.
    // (무작위 씨앗은 쓰지 않는다: 실패가 재현되지 않으면 고칠 수 없다.)
    for ([_]u64{ 0xF0221, 0xBEEF, 0x1234, 0xC0DE, 0x5EED }) |seed| {
        try fuzzRound(fx.session, term, fx.leaf_rect, doc.items, seed);
    }
}

fn fuzzRound(
    session: *AppSession,
    term: *Term,
    fx_leaf: maru.session.SplitRect,
    doc_bytes: []const u8,
    seed: u64,
) !void {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var step: usize = 0;
    while (step < 400) : (step += 1) {
        switch (rand.uintLessThan(u8, 7)) {
            0 => { // 커서를 놓는다(클릭과 같은 상태)
                const off = rand.uintLessThan(usize, doc_bytes.len);
                clearExtraSelections(session, term);
                term.rt.editor_selection = editor_selection.Selection.at(off);
            },
            1, 2 => _ = addNextOccurrence(session, term), // 커서를 늘린다
            3 => _ = foldAll(session),
            4 => _ = unfoldAll(session),
            5 => { // 굴린다
                const line = rand.uintLessThan(usize, 100);
                setEditorTop(session, term, line);
            },
            else => _ = copySelection(session), // 복사
        }

        // 프레임을 만든다 — 여기서 죽으면 그 조합이 결함이다.
        var d = appendPaneFrame(session, fx_leaf, term) orelse continue;
        d.dl.deinit(allocator);

        // ── 불변식 ──
        const docf = term.rt.editor_doc orelse continue;
        var iter = selections(term);
        const cursor_count = iter.count();
        while (iter.next()) |sel| {
            try testing.expect(sel.start() <= docf.file.content.len);
            try testing.expect(sel.end() <= docf.file.content.len);
        }
        try testing.expect(cursor_count <= editor_selection.max_cursors);

        if (buildSelectionMarks(session, term)) |marks| {
            const lines = editorLines(term);
            try testing.expectEqual(lines.len, marks.len); // 보이는 줄 축이다
            var drawn: usize = 0;
            for (marks, 0..) |row, i| {
                drawn += row.len;
                var prev: u32 = 0;
                for (row, 0..) |m, k| {
                    // 띠가 그 줄 안에 있다.
                    try testing.expect(m.start + m.len <= lines[i].len);
                    try testing.expect(m.len > 0);
                    // 한 줄 안에서 오름차순이다(렌더가 단언하는 것).
                    if (k > 0) try testing.expect(m.start >= prev);
                    prev = m.start;
                }
            }
            // **띠 수가 커서 수를 넘지 않는다** — 넘으면 같은 커서를 여러 번 그린 것이다.
            // (커서 하나가 여러 줄에 걸치면 띠가 여럿이므로 상한은 커서 수 × 보이는 줄 수지만,
            //  이 문서는 줄을 걸치는 선택을 만들지 않으므로 커서 수가 상한이다.)
            try testing.expect(drawn <= cursor_count);
        }
    }
}

test "MC6 caret에서 누르면 커서가 늘지 않고 낱말이 잡힌다 (§9.1)" {
    // **보이지 않는 커서를 만들지 않는다.** 옛 판은 caret을 나머지로 내려 커서가 둘이 됐고, 그 중
    // 길이 0짜리는 띠가 없어 화면에 안 나타나는데 타이핑은 거기로도 간다 — 사용자가 못 보는 자리에
    // 글자가 들어가는 종류의 결함이다. 클릭 뒤 `⌘⌃D`가 정확히 이 경로다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "caret.txt", .data = "alpha beta\nalpha gamma\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "caret.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // 클릭한 것과 같은 상태 — caret 하나(길이 0).
    term.rt.editor_selection = editor_selection.Selection.at(2); // "alpha" 안
    try testing.expect(addNextOccurrence(fx.session, term));

    // ⑴ 커서가 **늘지 않았다**.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_extra_selections.len);
    // ⑵ 그 자리 낱말이 잡혔다.
    const sel = term.rt.editor_selection.?;
    try testing.expectEqual(@as(usize, 0), sel.start());
    try testing.expectEqual(@as(usize, 5), sel.end());

    // ⑶ 한 번 더 누르면 그때부터 늘어난다.
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 1), term.rt.editor_extra_selections.len);
    try testing.expectEqual(@as(usize, 11), term.rt.editor_selection.?.start()); // 둘째 줄 alpha
}

test "MC5 접힌 문서에서도 커서 띠가 보이는 줄 축으로 선다 (§4.1f × §9.1)" {
    // **멀티커서와 접힘이 만나는 자리는 한 번도 판정된 적이 없다.** 마크는 *보이는 줄* 축인데
    // 커서는 문서 offset이라, 접히는 순간 둘이 어긋나면 화면이 조용히 거짓말한다 — 선택 하나였을
    // 때 실측으로 겪은 그 자리다(보이는 줄의 띠가 사라지고 숨긴 줄이 엉뚱한 행에 섰다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 들여쓰기로 접을 수 있는 문서 — 바깥 줄에 `target`이 둘, 안쪽(접히면 숨는 줄)에 하나.
    const text =
        "target one\n" ++
        "    hidden target\n" ++
        "    hidden two\n" ++
        "target two\n";
    try fx.dir.dir.writeFile(io, .{ .sub_path = "fold.txt", .data = text });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "fold.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // "target" 셋을 전부 고른다(문서 축).
    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 6, 6, .word);
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expect(addNextOccurrence(fx.session, term));
    try testing.expectEqual(@as(usize, 2), term.rt.editor_extra_selections.len);

    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d.dl.deinit(allocator);
    }
    {
        const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;
        var drawn: usize = 0;
        for (marks) |row| drawn += row.len;
        try testing.expectEqual(@as(usize, 3), drawn); // 펼친 상태에선 셋 다 보인다
    }

    // 접는다 — 안쪽 줄이 화면에서 사라진다.
    try testing.expect(foldAll(fx.session));
    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d.dl.deinit(allocator);
    }
    const folded_lines = editorLines(term).len;
    try testing.expect(folded_lines < 4); // 실제로 접혔나 — 안 접혔으면 아래 판정이 공허하다

    const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;
    try testing.expectEqual(folded_lines, marks.len); // 보이는 줄 축이다
    var drawn: usize = 0;
    for (marks, 0..) |row, i| {
        drawn += row.len;
        // 각 띠가 **그 줄 안**에 들어간다 — 축이 어긋나면 여기서 범위를 넘는다.
        const line_text = editorLines(term)[i];
        for (row) |m| try testing.expect(m.start + m.len <= line_text.len);
    }
    // 숨은 줄의 커서는 그려지지 않는다.
    try testing.expectEqual(@as(usize, 2), drawn);
}

test "MC4 병합 훑기가 줄마다 전부 훑던 방식과 같은 답을 낸다 (차분)" {
    // **최적화는 답을 바꾸지 않아야 한다.** `line_index`를 벡터화할 때 옛 구현과 3000건을 대조한
    // 것이 가장 강한 증거였고, 여기서도 같은 방법을 쓴다 — 순진한 `줄 × 커서` 훑기를 이 판정자
    // 안에 그대로 두고 무작위 배치에서 결과를 맞춘다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var l: usize = 0;
    while (l < 60) : (l += 1) {
        const width = 1 + rand.uintLessThan(usize, 30);
        var c: usize = 0;
        while (c < width) : (c += 1) try doc.append(allocator, 'a' + @as(u8, @intCast(rand.uintLessThan(u8, 26))));
        try doc.append(allocator, '\n');
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "diff.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "diff.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        d.dl.deinit(allocator);
    }

    var round: usize = 0;
    while (round < 60) : (round += 1) {
        // 무작위 선택 1~6개를 문서 순서로 만든다(겹치지 않게).
        const want = 1 + rand.uintLessThan(usize, 6);
        var picked: std.ArrayList(editor_selection.Selection) = .empty;
        defer picked.deinit(allocator);
        var cursor: usize = 0;
        var k: usize = 0;
        while (k < want and cursor < doc.items.len) : (k += 1) {
            const gap = rand.uintLessThan(usize, 40);
            const lo = cursor + gap;
            if (lo >= doc.items.len) break;
            const span = 1 + rand.uintLessThan(usize, 50); // 줄을 걸치기도 한다
            const hi = @min(lo + span, doc.items.len);
            if (hi <= lo) break;
            try picked.append(allocator, editor_selection.Selection.fromPoints(lo, hi));
            cursor = hi + 1;
        }
        if (picked.items.len == 0) continue;

        clearExtraSelections(fx.session, term);
        term.rt.editor_selection = picked.items[picked.items.len - 1];
        if (picked.items.len > 1) {
            const extras = try fx.session.allocator.alloc(editor_selection.Selection, picked.items.len - 1);
            @memcpy(extras, picked.items[0 .. picked.items.len - 1]);
            term.rt.editor_extra_selections = extras;
        }

        const marks = buildSelectionMarks(fx.session, term) orelse continue;

        // ── 순진한 기준 구현: 줄마다 커서 전부를 훑는다 ──
        const docf = term.rt.editor_doc.?;
        const lines_len = if (term.rt.editor_visible_lines.len > 0)
            term.rt.editor_visible_lines.len
        else
            term.rt.editor_lines.len;
        for (0..lines_len) |i| {
            const line = docf.file.lines.line(i) orelse continue;
            var expect_count: usize = 0;
            var last_start: u32 = 0;
            for (picked.items) |sel| {
                const lo = sel.start();
                const hi = sel.end();
                const line_end = line.contentEnd();
                if (line_end <= lo or line.start >= hi) continue;
                const from: u32 = @intCast(if (lo > line.start) lo - line.start else 0);
                const to: u32 = @intCast(@min(hi, line_end) - line.start);
                if (to <= from) continue;
                // 순진한 쪽도 문서 순서로 돌므로 start가 단조 증가한다.
                try testing.expect(expect_count == 0 or from >= last_start);
                try testing.expect(expect_count < marks[i].len);
                try testing.expectEqual(from, marks[i][expect_count].start);
                try testing.expectEqual(to - from, marks[i][expect_count].len);
                last_start = from;
                expect_count += 1;
            }
            try testing.expectEqual(expect_count, marks[i].len);
        }
    }
}

test "MC3 마크 저장소가 커서 수에 곱해지지 않는다 (§9.1 — 실측이 만든 판정자)" {
    // **앞선 판은 저장소를 `줄 수 × 커서 수`로 잡았다.** 2만 줄에 커서 1000개면 160 MB이고,
    // 훑는 비용도 같은 곱이라 실측 11ms/프레임이었다(나오는 마크는 1000개인데 2천만 번을 돌았다).
    //
    // 시간으로 게이트를 세우면 기계마다 빨개지므로 **저장소 크기**로 잰다 — 그 값은 결정적이고,
    // 곱셈으로 잡는 구현에서는 반드시 어긋난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    var n: usize = 0;
    while (n < 400) : (n += 1) try doc.appendSlice(allocator, "aa bb cc dd\n");
    try fx.dir.dir.writeFile(io, .{ .sub_path = "many.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "many.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 2, 2, .word);
    var added: usize = 0;
    while (added < 30) : (added += 1) {
        if (!addNextOccurrence(fx.session, term)) break;
    }
    const cursors = term.rt.editor_extra_selections.len + 1;
    try testing.expect(cursors >= 20); // 판정할 만큼 커서가 늘었나

    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d.dl.deinit(allocator);
    }
    const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;

    var drawn: usize = 0;
    for (marks) |row| drawn += row.len;
    try testing.expectEqual(cursors, drawn); // 커서 하나가 띠 하나(전부 한 줄 안이다)

    // **저장소가 실제 마크 수만큼이다.** 곱셈으로 잡으면 401 × 21 = 8421 이상이 된다.
    try testing.expectEqual(drawn, term.rt.editor_selection_mark_buf.len);
    try testing.expect(term.rt.editor_selection_mark_buf.len < doc.items.len);
}

test "MC2 같은 줄에 커서가 여럿이면 그 줄에 띠도 여럿 선다 (§9.1)" {
    // **선택 하나였을 때의 가정("줄마다 최대 하나")이 여기서 깨진다.** 저장소를 줄 수만큼 잡으면
    // 두 번째 띠가 버퍼를 넘거나 첫 번째를 덮어쓴다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "ab cd ab cd ab\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "one.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    term.rt.editor_selection = editor_selection.Selection.fromAnchorRange(0, 2, 2, .word);
    try testing.expect(addNextOccurrence(fx.session, term)); // 6..8
    try testing.expect(addNextOccurrence(fx.session, term)); // 12..14

    {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.NoDraw;
        defer d.dl.deinit(allocator);
    }
    const marks = buildSelectionMarks(fx.session, term) orelse return error.NoMarks;
    // **한 줄에 셋이다.**
    try testing.expectEqual(@as(usize, 3), marks[0].len);
    var starts: [3]u32 = undefined;
    for (marks[0], 0..) |m, i| starts[i] = m.start;
    std.mem.sort(u32, &starts, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 0, 6, 12 }, &starts);

    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("ab\nab\nab", fx.session.chrome_clipboard_write);
}

test "SEL4 더블클릭은 단어를, 트리플클릭은 줄을 잡고, 이어지는 드래그가 그 단위로 는다 (§4.1g)" {
    // **`AnchorKind`가 있는 이유를 재는 테스트다.** anchor가 점이면 단어를 잡고 뒤로 끌 때 그
    // 단어가 잘린다 — `selection.zig` 머리말이 anchor를 **범위**로 둔 근거가 그것이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // "alpha beta gamma\ndelta epsilon\n" — 단어 경계가 뚜렷하다.
    try fx.dir.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "alpha beta gamma\ndelta epsilon\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "w.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    const text_x0: i32 = @as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(geom.content_left_px));
    const y0: i32 = @as(i32, @intCast(body.y)) + inset;
    const pane = pane_ops.activePane(fx.session);
    // 첫 줄 8열("beta"의 b는 6열, 8열은 그 안).
    const on_beta: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(8 * @as(u32, geom.cell_w_px))));
    const row0: f64 = @floatFromInt(y0 + 1);

    // ⑴ **더블클릭 → 단어.** "beta"는 6..10.
    try testing.expect(selectWordOrLineAt(fx.session, pane, false, on_beta, row0));
    const w = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(editor_selection.AnchorKind.word, w.kind);
    try testing.expectEqual(@as(usize, 6), w.start());
    try testing.expectEqual(@as(usize, 10), w.end());

    // ⑵ **드래그가 단어 단위로 는다.** "gamma"(11..16) 안으로 끌면 그 끝까지 삼킨다.
    const on_gamma: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(13 * @as(u32, geom.cell_w_px))));
    try testing.expect(dragBodySelection(fx.session, 2, on_gamma, row0));
    const w2 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 6), w2.start()); // 잡은 단어의 시작이 남는다
    try testing.expectEqual(@as(usize, 16), w2.end()); // "gamma" 끝까지

    // ⑶ **뒤로 끌어도 잡은 단어가 안 잘린다.** "alpha"(0..5) 안으로 끈다.
    const on_alpha: f64 = @floatFromInt(text_x0 + @as(i32, @intCast(2 * @as(u32, geom.cell_w_px))));
    try testing.expect(dragBodySelection(fx.session, 2, on_alpha, row0));
    const w3 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), w3.start()); // "alpha" 시작까지
    try testing.expectEqual(@as(usize, 10), w3.end()); // **"beta" 끝이 남는다** — anchor가 범위다
    try testing.expect(dragBodySelection(fx.session, 3, on_alpha, row0));

    // ⑷ **트리플클릭 → 줄.** 개행은 뺀다.
    try testing.expect(selectWordOrLineAt(fx.session, pane, true, on_beta, row0));
    const l = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(editor_selection.AnchorKind.line, l.kind);
    try testing.expectEqual(@as(usize, 0), l.start());
    try testing.expectEqual(@as(usize, 16), l.end()); // "alpha beta gamma" — 개행 앞

    // ⑸ **줄 단위 드래그.** 둘째 줄로 끌면 그 줄 끝까지.
    const row1: f64 = @floatFromInt(y0 + @as(i32, @intCast(geom.cell_h_px)) + 1);
    try testing.expect(dragBodySelection(fx.session, 2, on_beta, row1));
    const l2 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), l2.start());
    try testing.expectEqual(@as(usize, 30), l2.end()); // "delta epsilon" 끝(17+13)

    // ⑹ 복사가 그 범위를 뜬다.
    try testing.expect(copySelection(fx.session));
    try testing.expectEqualStrings("alpha beta gamma\ndelta epsilon", fx.session.chrome_clipboard_write);

    // ⑺ **줄 단위도 뒤로 끌 수 있다.** 둘째 줄을 잡고 첫 줄로 끌면 첫 줄 **머리**까지 삼키면서
    //    잡은 줄의 끝이 남는다 — 그 갈래를 지운 뮤턴트가 살아남았다(적대적 검증).
    try testing.expect(dragBodySelection(fx.session, 3, on_beta, row1));
    try testing.expect(selectWordOrLineAt(fx.session, pane, true, on_beta, row1)); // 둘째 줄을 잡는다
    const l3 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 17), l3.start());
    try testing.expect(dragBodySelection(fx.session, 2, on_beta, row0)); // 첫 줄로 끈다
    const l4 = term.rt.editor_selection orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), l4.start()); // 첫 줄 머리까지
    try testing.expectEqual(@as(usize, 30), l4.end()); // 잡은 줄의 끝이 남는다
    try testing.expect(dragBodySelection(fx.session, 3, on_beta, row0));
}

test "SEL5 드래그가 pane 밖에 머물면 굴러가고, 손을 떼면 멈춘다 (§4.1g)" {
    // **없으면 보이는 만큼만 고를 수 있다.** 화면보다 긴 범위를 드래그로 고르는 것은 표준 동작이다.
    //
    // 이 테스트가 지키는 것 셋: ⑴ 밖으로 나가면 방향이 서고 ⑵ tick이 굴리며 선택이 늘고
    // ⑶ **손을 떼면 멈춘다** — 방향이 latch되면 tick이 영원히 굴린다(터미널이 그 사고를 겪었고,
    // `app_session.zig`에 그 자리 주석이 남아 있다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..300) |i| { // 화면보다 훨씬 길다
        var num: [24]u8 = undefined;
        const line = std.fmt.bufPrint(&num, "line {d}\n", .{i}) catch unreachable;
        try doc.appendSlice(allocator, line);
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "s.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "s.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    // **랩을 끈다.** 랩이 켜지면 `scrollLines`가 논리 줄 대신 **조각**을 민다(그 함수의 갈래) —
    // 자동 스크롤이 굴러가는지를 재는 데 그 축이 섞이면 무엇이 깨졌는지 말하지 못한다. 랩 상태의
    // 자동 스크롤은 별개 축이고, 조각 단위 스크롤이 붙을 때 함께 잰다.
    term.rt.editor_wrap = false;

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    const text_x: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(geom.content_left_px)) + 1);
    const top_y: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset + 1);
    const pane = pane_ops.activePane(fx.session);

    try testing.expect(beginBodySelection(fx.session, pane, text_x, top_y, 0));
    try testing.expectEqual(@as(i8, 0), fx.session.editor_drag_autoscroll); // 안에서는 안 선다

    // ⑴ **아래로 벗어난다.**
    const below: f64 = @floatFromInt(@as(i32, @intCast(body.y + body.h)) + 200);
    try testing.expect(dragBodySelection(fx.session, 2, text_x, below));
    try testing.expectEqual(@as(i8, -1), fx.session.editor_drag_autoscroll); // 아래로 = 문서 뒤쪽 = 음수

    // ⑵ **tick이 굴린다.** 한 스텝에 못 미치는 누적으로는 안 움직인다(frame rate 무관 속도).
    const first_line0 = term.rt.editor_first_line;
    const sel_end0 = (term.rt.editor_selection orelse return error.NoSelection).end();
    // **렌더를 함께 돌린다.** 스크롤 상한(`editor_max_top_line`)과 행 배열은 렌더가 세우므로,
    // tick만 돌리면 상한이 0에 묶여 아무리 굴려도 안 움직인다 — 제품은 tick마다 그리므로 그
    // 순환을 여기서도 재현해야 한다(§4.1g "렌더가 굳힌 것만 읽는다"의 대가다).
    var ticks: usize = 0;
    while (ticks < 40 and term.rt.editor_first_line == first_line0) : (ticks += 1) {
        applyDragAutoscroll(fx.session, fx.leaf_rect);
        if (appendPaneFrame(fx.session, fx.leaf_rect, term)) |*d| {
            var dd = d.*;
            dd.dl.deinit(allocator);
        }
    }
    try testing.expect(term.rt.editor_first_line > first_line0); // 굴렀다
    // **정확한 tick 수를 못 박는다.** `ticks > 0`은 루프 카운터라 몸통이 한 번만 돌아도 참이라
    // **항진명제였다** — ms 게이트를 통째로 지운 뮤턴트가 그대로 통과했다(적대적 검증). 이 fixture는
    // `msPerTick() == 17`이고 상수가 33이므로 첫 스크롤까지 정확히 **2 tick**이다.
    try testing.expectEqual(@as(u32, 17), fx.session.msPerTick()); // 전제
    try testing.expectEqual(@as(usize, 2), ticks);

    // **선택은 한 프레임 늦게 따라온다.** 굴린 직후 행 배열은 아직 이전 프레임 것이라, 가장자리
    // 행이 가리키는 줄이 그대로다 — 다음 렌더가 배열을 갱신해야 그 자리가 새 줄이 된다. 렌더가
    // 굳힌 것만 읽는다는 §4.1g 계약의 대가이고, live로 다시 구하면 11~16차가 판 결함으로 돌아간다.
    for (0..12) |_| {
        applyDragAutoscroll(fx.session, fx.leaf_rect);
        if (appendPaneFrame(fx.session, fx.leaf_rect, term)) |*d| {
            var dd = d.*;
            dd.dl.deinit(allocator);
        }
    }
    const sel_end1 = (term.rt.editor_selection orelse return error.NoSelection).end();
    try testing.expect(sel_end1 > sel_end0);

    // ⑶ **손을 떼면 멈춘다.**
    try testing.expect(dragBodySelection(fx.session, 3, text_x, below));
    try testing.expectEqual(@as(i8, 0), fx.session.editor_drag_autoscroll);
    const parked = term.rt.editor_first_line;
    for (0..80) |_| applyDragAutoscroll(fx.session, fx.leaf_rect);
    try testing.expectEqual(parked, term.rt.editor_first_line); // 더 안 굴렀다

    // ⑷ **제스처가 딴 데로 넘어가도 latch가 안 남는다.**
    fx.session.editor_drag_autoscroll = -1; // 방향만 남은 상태를 인위로 만든다
    applyDragAutoscroll(fx.session, fx.leaf_rect);
    try testing.expectEqual(@as(i8, 0), fx.session.editor_drag_autoscroll);
    try testing.expectEqual(parked, term.rt.editor_first_line);
}

test "SEL6 막대 띠 위 더블·트리플 클릭은 선택을 열지 않는다 (§4.1g 결정표)" {
    // **kind 4/5는 pane 라우팅 블록을 안 탄다.** 단일 클릭은 그 블록이 `divider → 막대 → 본문`
    // 순서로 걸러 주는데 더블·트리플은 `pxToCell` 앞의 별도 블록에서 처리되므로, 같은 순서를
    // `selectWordOrLineAt` 자신이 져야 한다 — 안 그러면 막대 위 더블클릭이 **진행 중인 막대
    // 드래그를 취소하고** 본문 선택을 연다(적대적 검증 실측).
    //
    // **디스패처(`mouse()`)까지는 이 하니스로 못 잰다** — 실제 창이 없어 `termRect()`가 비고,
    // `paneAtPoint`가 좌표를 못 찾아 배선까지 도달하지 않는다. 그래서 §4.1g "아직 검증되지 않는
    // 문장" 표에 그 세 줄이 남아 있다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..300) |i| {
        var num: [24]u8 = undefined;
        const line = std.fmt.bufPrint(&num, "alpha{d} beta\n", .{i}) catch unreachable;
        try doc.appendSlice(allocator, line);
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "d.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "d.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    const body = editorBodyRect(fx.session, fx.leaf_rect, term);
    const inset: i32 = @intCast(chrome_editor.frame.content_inset_px);
    const geom = term.rt.editor_hit_geom;
    const row0: f64 = @floatFromInt(@as(i32, @intCast(body.y)) + inset + 1);
    const pane = pane_ops.activePane(fx.session);

    const bar = term.rt.editor_scrollbar orelse return error.NoScrollbar;
    const bar_x: f64 = @as(f64, bar.hit_x) + 1;

    // ⑴ **막대를 잡은 채 더블클릭해도 선택이 안 열린다.**
    try testing.expect(beginScrollbarGesture(fx.session, pane, bar_x, row0));
    try testing.expect(!selectWordOrLineAt(fx.session, pane, false, bar_x, row0));
    try testing.expectEqual(@as(?editor_selection.Selection, null), term.rt.editor_selection);
    // 막대 드래그가 살아 있다 — 편집기 막대는 `pointer_gesture_owner`가 아니라 이 필드가 든다.
    try testing.expectEqual(term, fx.session.editor_scrollbar_term);
    fx.session.editor_scrollbar_term = null;
    fx.session.cancelPointerGesture();

    // ⑵ 트리플클릭도 같다.
    try testing.expect(!selectWordOrLineAt(fx.session, pane, true, bar_x, row0));
    try testing.expectEqual(@as(?editor_selection.Selection, null), term.rt.editor_selection);

    // ⑶ **본문은 연다** — 위 둘이 항진명제가 아니라는 대조군.
    const text_x: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + inset + @as(i32, @intCast(geom.content_left_px)) + 1);
    try testing.expect(selectWordOrLineAt(fx.session, pane, false, text_x, row0));
    try testing.expect(term.rt.editor_selection != null);
    fx.session.cancelPointerGesture();
}

test "CUR1 상태바 커서 위치: 그래핌 1-based이고 탭은 한 글자다 (§2.2)" {
    // **화면 위치가 아니라 "몇 번째 글자인가"를 답한다.** 그래서 렌더의 열(`stepColumn` — 탭이
    // 탭스톱까지 먹고 CJK가 두 칸이다)이 아니라 클러스터를 센다. 두 축을 섞으면 탭이 있는 줄에서
    // 상태바가 화면과 다른 수를 낸다 — 화면 위치는 caret이 이미 보여 준다(§2.2).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 1행: 탭 둘 + 글자, 2행: 한글(다중 byte), 3행: 결합 이모지.
    try fx.dir.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "\t\tabc\n안녕하세요\n👨‍👩‍👧x\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "c.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // 선택이 없으면 항목도 없다 — 읽기 전용이라 caret이 늘 있지는 않다.
    try testing.expectEqual(@as(?@TypeOf(cursorPosition(term).?), null), cursorPosition(term));

    // ⑴ **줄도 1-based다.** gutter가 1부터 그리므로 상태바가 0을 말하면 같은 줄을 두 이름으로 부른다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    const p0 = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 1), p0.line);
    try testing.expectEqual(@as(usize, 1), p0.column);

    // ⑵ **탭은 한 글자다.** `"\t\tabc"`에서 byte 2(= 'a' 앞)는 **3열**이지 탭스톱 폭(9)이 아니다.
    term.rt.editor_selection = editor_selection.Selection.at(2);
    const p1 = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 1), p1.line);
    try testing.expectEqual(@as(usize, 3), p1.column);

    // ⑶ **한글은 한 글자다**(두 칸이 아니다). 둘째 줄 "안녕하세요"에서 '하' 앞 = byte 6.
    const line2_start: usize = 6; // "\t\tabc\n"
    term.rt.editor_selection = editor_selection.Selection.at(line2_start + 6);
    const p2 = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 2), p2.line);
    try testing.expectEqual(@as(usize, 3), p2.column); // 안·녕 다음

    // ⑷ **ZWJ 이모지 가족은 한 클러스터다.** 셋째 줄 "👨‍👩‍👧x"에서 'x' 앞은 2열이다.
    const line3_start: usize = line2_start + 16; // "안녕하세요\n" = 15 + 1
    const family_len: usize = 18; // 👨 ZWJ 👩 ZWJ 👧
    term.rt.editor_selection = editor_selection.Selection.at(line3_start + family_len);
    const p3 = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 3), p3.line);
    try testing.expectEqual(@as(usize, 2), p3.column);

    // ⑸ **`focus`를 본다 — `anchor`가 아니다.** caret이 있는 끝이 커서 위치다(§3.2 primary
    //    selection). 앞뒤로 끈 선택 둘이 서로 다른 값을 내야 그 축이 굳는다 — `anchorLo`로 바꾼
    //    뮤턴트가 살아남았다(적대적 검증: 판정자가 전부 collapsed 선택이라 anchor == focus였다).
    term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 2 };
    const fwd = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 3), fwd.column); // focus가 뒤 → 그 자리
    term.rt.editor_selection = .{ .anchor_start = 2, .anchor_end = 2, .focus = 0 };
    const back = cursorPosition(term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 1), back.column); // focus가 앞 → 그 자리

    // ⑹ **CRLF 줄에서 줄 끝을 넘지 않는다.** CR을 한 글자로 세면 글자 수보다 큰 열이 나온다.
    {
        var fx2 = try PaneFixture.init(allocator);
        defer fx2.deinit(allocator);
        try fx2.dir.dir.writeFile(io, .{ .sub_path = "crlf.txt", .data = "ab \r\ncd\r\n" });
        var rb2: [std.fs.max_path_bytes]u8 = undefined;
        const r2 = rb2[0..try fx2.dir.dir.realPath(io, &rb2)];
        const crlf_path = try std.fs.path.join(allocator, &.{ r2, "crlf.txt" });
        defer allocator.free(crlf_path);
        const t2 = try openPathInActivePane(fx2.session, crlf_path);
        // CR(byte 3) 위에 caret을 두어도 줄 끝(글자 3개)을 넘지 않는다.
        t2.rt.editor_selection = editor_selection.Selection.at(4);
        const c = cursorPosition(t2) orelse return error.NoPos;
        try testing.expectEqual(@as(usize, 1), c.line);
        try testing.expectEqual(@as(usize, 4), c.column); // "ab " 뒤 = 4열, 5가 아니다
    }

    // ⑺ **상한을 넘으면 세기를 멈추고 그 사실을 말한다.** 안 묶으면 긴 줄 끝에 caret이 있을 때
    //    매 프레임 줄 전체를 훑는다(실측 1MB 한 줄에서 프레임당 22ms — 60fps 예산의 132%).
    {
        var fx3 = try PaneFixture.init(allocator);
        defer fx3.deinit(allocator);
        var long: std.ArrayList(u8) = .empty;
        defer long.deinit(allocator);
        try long.appendNTimes(allocator, 'x', max_status_column + 500);
        try long.append(allocator, '\n');
        try fx3.dir.dir.writeFile(io, .{ .sub_path = "long.txt", .data = long.items });
        var rb3: [std.fs.max_path_bytes]u8 = undefined;
        const r3 = rb3[0..try fx3.dir.dir.realPath(io, &rb3)];
        const long_path = try std.fs.path.join(allocator, &.{ r3, "long.txt" });
        defer allocator.free(long_path);
        const t3 = try openPathInActivePane(fx3.session, long_path);
        t3.rt.editor_selection = editor_selection.Selection.at(max_status_column + 400);
        const c = cursorPosition(t3) orelse return error.NoPos;
        try testing.expect(c.truncated);
        try testing.expectEqual(max_status_column + 1, c.column); // 상한에서 멈췄다
        // 상한 안이면 정확히 센다 — 위가 항진명제가 아니다.
        t3.rt.editor_selection = editor_selection.Selection.at(10);
        const c2 = cursorPosition(t3) orelse return error.NoPos;
        try testing.expect(!c2.truncated);
        try testing.expectEqual(@as(usize, 11), c2.column);

        // **경계: 딱 상한만큼 센 것은 잘린 게 아니다.** `col > 상한`으로 판정하면 여기서 거짓
        // 양성이 난다(끝까지 세고도 `+`가 붙는다).
        t3.rt.editor_selection = editor_selection.Selection.at(max_status_column);
        const edge = cursorPosition(t3) orelse return error.NoPos;
        try testing.expectEqual(max_status_column + 1, edge.column);
        try testing.expect(!edge.truncated);
    }

    // ⑻ **비교 뷰는 답하지 않는다** — 축이 다르다(행 배열이고 문서가 둘이다).
    term.rt.editor_diff = .{ .requested_ms = 0 };
    defer term.rt.editor_diff = null;
    try testing.expectEqual(@as(?@TypeOf(cursorPosition(term).?), null), cursorPosition(term));
}

test "EM1 한 줄에 매치가 여럿이면 마크도 여럿 선다 (§5.1)" {
    // **이 슬라이스가 존재하는 이유를 재는 판정자다.** 선택 마크 저장소는 줄당 하나이고
    // (`editor_selection_mark_buf`는 줄 수만큼 잡아 `buf[i..i+1]`로 자른다), 그 위에 검색을 얹으면
    // 매치 리스트는 셋인데 화면에는 하나만 선다 — **카운터가 맞으므로 조용하다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "m.txt", .data = "row row row\nnone here\nrow\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "m.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "row", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 4), fx.session.editor_find_matches.items.len);

    const rows = buildFindMarks(fx.session, term, fx.session.editor_find_matches.items) orelse return error.NoMarks;
    try testing.expectEqual(@as(usize, 3), rows[0].len); // 첫 줄에 셋 — 하나면 저장소가 줄당 하나다
    try testing.expectEqual(@as(u32, 0), rows[0][0].start);
    try testing.expectEqual(@as(u32, 4), rows[0][1].start);
    try testing.expectEqual(@as(u32, 8), rows[0][2].start);
    try testing.expectEqual(@as(usize, 0), rows[1].len); // 매치 없는 줄은 빈 슬라이스
    try testing.expectEqual(@as(usize, 1), rows[2].len);
}

test "EM2 접혀 있으면 마크가 보이는 줄 축으로 선다 (§4.1f × §5.1)" {
    // 문서 줄 축으로 만들면 접힘이 켜지는 순간 **화면이 조용히 거짓말한다** — 선택 마크가 겪은
    // 그 자리이고(`buildSelectionMarks` doc의 실측), 축이 둘인 한 같은 함정이 남는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // 들여쓰기로 접을 블록을 만든다. `target`은 **블록 밖 마지막 줄**에 둔다 — 접으면 그 줄이
    // 위로 당겨져 보이는 줄 번호가 문서 줄 번호와 갈린다.
    try fx.dir.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "head\n    a\n    b\n    c\ntarget\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "f.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "target", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 1), fx.session.editor_find_matches.items.len);
    try testing.expectEqual(@as(u32, 4), fx.session.editor_find_matches.items[0].line); // 문서 줄 축

    // 펼친 상태: 보이는 줄도 4다(두 축이 같아 아직 아무것도 판정되지 않는다).
    {
        const rows = buildFindMarks(fx.session, term, fx.session.editor_find_matches.items) orelse return error.NoMarks;
        try testing.expectEqual(@as(usize, 1), rows[4].len);
    }

    // 접는다 — `head` 아래 세 줄이 숨어 `target`이 **보이는 줄 1번**이 된다.
    // (보이는 줄은 셋이다: `head`·`target`·끝 개행이 만든 빈 줄.)
    try testing.expect(foldAll(fx.session));
    try testing.expectEqual(@as(usize, 3), term.rt.editor_visible_lines.len);
    const rows = buildFindMarks(fx.session, term, fx.session.editor_find_matches.items) orelse return error.NoMarks;
    try testing.expectEqual(@as(usize, 0), rows[0].len);
    try testing.expectEqual(@as(usize, 1), rows[1].len); // 문서 줄 축이면 여기가 비고 화면에 띠가 없다
    try testing.expectEqual(@as(u32, 0), rows[1][0].start);
}

test "EM3 접혀 숨은 매치로 가면 펴고 나서 간다 (§5.1 네비게이션)" {
    // 펴지 않으면 "다음 매치"가 **아무 데도 안 가는 것처럼** 보인다 — 카운터만 올라가고 화면은
    // 그대로다. 그 상태가 이 슬라이스가 고치려는 부류(조용히 잘못 동작한다)와 같다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "r.txt", .data = "head\n    a\n    needle\n    c\ntail\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "r.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try testing.expect(foldAll(fx.session));
    try testing.expectEqual(@as(usize, 3), term.rt.editor_visible_lines.len); // head·tail·끝 빈 줄 — needle이 숨었다
    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "needle", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 1), fx.session.editor_find_matches.items.len);
    try testing.expect(buildFindMarks(fx.session, term, fx.session.editor_find_matches.items).?[0].len == 0); // 숨은 동안에는 그릴 것이 없다

    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true; // 출처 검사를 지난다(EM9가 그 검사를 잰다)
    fx.session.editor_find_source = term.surfaceId();
    revealCurrentFindMatch(fx.session, term);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_folded_len); // 폈다
    const vm = currentVisibleMatch(fx.session, term) orelse return error.NotVisible;
    try testing.expectEqual(@as(u32, 2), vm.row);
    try testing.expectEqual(@as(u32, 4), vm.start); // "    needle"의 들여쓰기 뒤
}

test "EM4 이미 보이는 매치로는 화면을 움직이지 않는다" {
    // 증분 검색이라 타이핑마다 이 경로가 돈다 — 매번 굴리면 글자 하나 지울 때마다 본문이 튄다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..200) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    // **매치를 문서 가운데 둔다.** 끝에 두면 아래 "한 칸 옮기기"가 스크롤 상한을 넘어
    // `clampScrollToGeometry`가 되돌려 놓고, 그러면 판정자가 자기 전제를 잃는다.
    try doc.appendSlice(allocator, "needle in the middle\n");
    for (200..400) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "s.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "s.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    const rows_drawn = term.rt.editor_hit_rows_len;
    try testing.expect(rows_drawn > 2); // 판정이 성립할 만큼은 그렸다

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "needle", .{}, &fx.session.editor_find_matches);
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true; // 출처 검사를 지난다
    fx.session.editor_find_source = term.surfaceId();

    // 화면 **밖**이다 — 굴러가고, 매치가 가운데쯤 온다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
    revealCurrentFindMatch(fx.session, term);
    const after = term.rt.editor_first_line;
    try testing.expectEqual(@as(usize, 200 - rows_drawn / 2), after);

    // **여기서 자리를 한 칸 옮긴다.** 이 줄이 없으면 이 판정자가 아무것도 안 잰다 — 중앙 정렬
    // 식(`row - rows/2`)이 **멱등**이라, 조기 반환을 통째로 지워도 두 번째 호출이 같은 값을
    // 다시 계산해 초록이 남는다(뮤턴트 M7이 그렇게 살아남았다. 적대적 검증 2026-08-23).
    // 한 칸 옮긴 자리에서도 매치는 여전히 화면 안이므로, **되돌리면 안 된다**가 판정이 된다.
    const nudged = after + 1;
    term.rt.editor_first_line = nudged;
    var again = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    again.dl.deinit(allocator); // 옮긴 자리로 한 프레임 — `editor_hit_lines`가 그 화면의 것이어야 한다

    // 이제 화면 **안**이다 — 다시 불러도 그 자리를 지켜야 한다.
    revealCurrentFindMatch(fx.session, term);
    try testing.expectEqual(nudged, term.rt.editor_first_line);
}

test "EM7 랩에서도 화면 밖 매치로 굴러간다 — 시각 행과 논리 줄을 안 섞는다" {
    // **초판은 여기서 틀렸다**(적대적 검증 2026-08-23). `row < top + rows`의 `rows`가 시각 행
    // 수인데 `row`/`top`은 논리 줄이라, 랩이 켜지면 **과대 계수**가 나 뷰포트 **아래** 줄을
    // "보인다"고 답했다. Enter를 눌러도 안 굴러가고 카운터만 올라간다 — EM3가 접힘에 대해
    // "이 슬라이스가 고치려던 부류"라 부른 그 실패 모드다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // **한 줄이 여러 행으로 접히게** 길게 쓴다. 그래야 두 축이 갈린다 — 짧은 줄만 있으면
    // 시각 행과 논리 줄이 같아 이 판정자가 옛 구현에서도 통과한다.
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..60) |i| {
        var buf: [400]u8 = undefined;
        const filler = "wrap me " ** 20; // 160자 — 본문 폭보다 훨씬 길다
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {s}\n", .{ i, filler }));
    }
    try doc.appendSlice(allocator, "needle at the end\n");
    try fx.dir.dir.writeFile(io, .{ .sub_path = "w.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "w.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    term.rt.editor_wrap = true;

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    const rows_drawn = term.rt.editor_hit_rows_len;
    const docs_drawn = drawnDocLines(term);
    // **판정이 성립하려면 두 축이 실제로 갈려야 한다.** 안 갈리면 이 테스트는 EM4의 복제일 뿐이다.
    try testing.expect(docs_drawn < rows_drawn);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "needle", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 1), fx.session.editor_find_matches.items.len);
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();

    // 매치는 문서 줄 60이고 화면에는 첫 몇 줄뿐이다 — 굴러가야 한다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
    revealCurrentFindMatch(fx.session, term);
    // 시각 행 수로 나눴으면 훨씬 위(또는 0)에 섰다. 논리 줄 수로 나눠야 이 값이다.
    try testing.expectEqual(@as(usize, 60 - docs_drawn / 2), term.rt.editor_first_line);
    try testing.expect(term.rt.editor_first_line > 0); // 안 굴러간 것이 아니다
}

test "EM8 매치로 점프하면 조각 offset을 지운다 (§4.1d)" {
    // 세로 위치는 `(줄, 조각)` 쌍이다. 초판은 `first_line`만 써서, 랩에서 긴 줄 중간에 있다가
    // 점프하면 **옛 조각 offset이 남아 목적지 줄을 지나쳤다**(적대적 검증 2026-08-23).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..40) |_| try doc.appendSlice(allocator, "long " ** 60 ++ "\n");
    try doc.appendSlice(allocator, "needle\n");
    try fx.dir.dir.writeFile(io, .{ .sub_path = "p.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "p.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    term.rt.editor_wrap = true;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "needle", .{}, &fx.session.editor_find_matches);
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();

    // 긴 줄 **중간**에 서 있다 — 조각이 0이 아니다.
    term.rt.editor_first_piece = 3;
    revealCurrentFindMatch(fx.session, term);
    try testing.expectEqual(@as(u32, 0), term.rt.editor_first_piece); // 남으면 목적지를 지나친다
}

test "EM9 남의 문서 매치로는 이 문서를 굴리지도 펴지도 않는다" {
    // **읽기인 줄 알았던 자리가 남의 상태를 쓴다.** 오버레이를 연 채 다른 편집기로 옮기고
    // Enter를 누르면 `revealCurrentFindMatch`가 그 Term에 대해 불리는데, 매치는 **앞 문서의
    // 것**이다. 초판은 출처를 안 물어 엉뚱한 줄로 굴리고 **이 문서의 접힘을 폈다**
    // (적대적 검증 2026-08-23이 재현). ⌘G 경로에는 그 검사가 있었는데 Enter 경로에만 없었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "head\n    a\n    b\n    c\ntail\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    try testing.expect(foldAll(fx.session));
    const folded_before = term.rt.editor_folded_len;
    try testing.expect(folded_before > 0);

    // 매치는 **다른 Term**의 것이다(출처 id가 다르다).
    try fx.session.editor_find_matches.append(allocator, .{ .line = 2, .start = 0, .len = 1 });
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId() + 1;

    revealCurrentFindMatch(fx.session, term);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line); // 안 굴렀다
    try testing.expectEqual(folded_before, term.rt.editor_folded_len); // 접힘도 그대로다
}

test "EM5 검색 대상이 아닌 편집기에는 강조가 안 선다" {
    // 편집기가 여럿 열려 있을 때 전부에 같은 색이 깔리면 Enter가 어디로 갈지 화면이 말해 주지
    // 못한다. **id로 판정한다** — "활성인가"로 물으면 pane을 옮긴 다음 프레임이 남의 문서 좌표를
    // 이 문서에 칠한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const term = fx.term;

    fx.session.chrome_host.find.open = true;
    try testing.expect(!isFindTarget(fx.session, term)); // 출처가 없다 — 아직 아무것도 안 찾았다

    fx.session.editor_find_source = term.surfaceId();
    try testing.expect(isFindTarget(fx.session, term));

    fx.session.editor_find_source = term.surfaceId() + 1; // 다른 편집기의 매치다
    try testing.expect(!isFindTarget(fx.session, term));

    fx.session.editor_find_source = term.surfaceId();
    fx.session.chrome_host.find.open = false;
    fx.session.find_nav = false;
    try testing.expect(!isFindTarget(fx.session, term)); // 닫혀 있으면 안 그린다
}

test "EM6 닫은 채 ⌘G로 오가면 현재 매치만 그린다" {
    // 스크롤백은 `collectFindViewSpans`에서 `if (find.open)`으로 나머지를 뺀다. 편집기가 그 규칙을
    // 안 따르면 **닫았는데 화면이 그대로**다 — 같은 오버레이가 pane 종류에 따라 다르게 행동한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    try fx.dir.dir.writeFile(io, .{ .sub_path = "g.txt", .data = "row row\nrow\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "g.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "row", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 3), fx.session.editor_find_matches.items.len);
    fx.session.editor_find_source = term.surfaceId();

    // 열려 있으면 셋 다 — 첫 줄에 둘, 둘째 줄에 하나.
    fx.session.chrome_host.find.open = true;
    fx.session.chrome_host.find.current = 2;
    {
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        drawn.dl.deinit(allocator);
        const rows = term.rt.editor_find_marks;
        try testing.expectEqual(@as(usize, 2), rows[0].len);
        try testing.expectEqual(@as(usize, 1), rows[1].len);
    }

    // 닫힌 채 네비 중이면 **현재 하나**만. 현재는 둘째 줄의 것이라 첫 줄이 비어야 한다.
    fx.session.chrome_host.find.open = false;
    fx.session.find_nav = true;
    {
        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        drawn.dl.deinit(allocator);
        const rows = term.rt.editor_find_marks;
        try testing.expectEqual(@as(usize, 0), rows[0].len);
        try testing.expectEqual(@as(usize, 1), rows[1].len);
    }
}

test "EM10 랩에서 가시성 판정도 두 축을 안 섞는다 — EM7이 못 재던 절반" {
    // **EM7은 제목의 절반만 쟀다**(2라운드 적대적 검증 N11). `revealCurrentFindMatch`의 축 섞임은
    // 두 군데였는데(가시성 판정, 가운데 두기 나눗셈) EM7의 매치가 문서 줄 60이라 **옛 근사로도
    // "화면 밖"이 나왔다** — 그래서 나눗셈만 잡고 가시성 판정은 못 잡았다.
    //
    // 과대 계수가 나는 구간은 딱 `[drawnDocLines, editor_hit_rows_len)`다. 매치를 **그 안에** 둬야
    // 옛 근사가 "보인다"(틀림)고 답하고 지금 코드가 "안 보인다"(맞음)고 답한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..80) |i| {
        var buf: [400]u8 = undefined;
        const filler = "wrap me " ** 20;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {s}\n", .{ i, filler }));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "b.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    term.rt.editor_wrap = true;

    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    const rows_drawn = term.rt.editor_hit_rows_len;
    const docs_drawn = drawnDocLines(term);
    // **판정이 성립할 띠가 있어야 한다.** 없으면 이 테스트는 EM7의 복제다.
    try testing.expect(docs_drawn + 1 < rows_drawn);

    // 매치를 그 띠 **안**에 둔다 — 화면에는 없지만 옛 근사는 "보인다"고 답하는 자리다.
    const target_line: u32 = @intCast(docs_drawn + (rows_drawn - docs_drawn) / 2);
    try fx.session.editor_find_matches.append(allocator, .{ .line = target_line, .start = 0, .len = 1 });
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();

    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
    revealCurrentFindMatch(fx.session, term);
    // 옛 근사(`row < top + rows_drawn`)면 여기서 0이 남는다 — 카운터만 오르고 화면은 그대로.
    try testing.expect(term.rt.editor_first_line > 0);
}

test "EM11 한 프레임 안에 두 번 네비게이션해도 두 번째가 굴러간다 (스냅숏 낡음)" {
    // **2라운드 적대적 검증이 회귀로 잡았다.** 가시성 판정을 `editor_hit_lines`로 바꾸면서 세
    // 재료가 전부 지난 프레임의 것이 됐고, 그래서 **방금 자기가 한 스크롤을 못 봤다**. 한 프레임
    // 안에 Enter가 두 번 오면(키 반복 15ms < 프레임 16.7ms) 두 번째가 "보인다"고 답해 안 굴렀다 —
    // 카운터만 오르고 화면은 그대로. **옛 코드는 `top`을 라이브로 읽어 이 경우를 맞히고 있었다.**
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    try doc.appendSlice(allocator, "needle at top\n");
    for (0..400) |i| {
        var buf: [32]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    try doc.appendSlice(allocator, "needle far below\n");
    try fx.dir.dir.writeFile(io, .{ .sub_path = "t.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "t.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "needle", .{}, &fx.session.editor_find_matches);
    try testing.expectEqual(@as(usize, 2), fx.session.editor_find_matches.items.len);
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();

    // 아래쪽 매치로 — 굴러간다.
    // **여는 자리가 0임을 못 박는다.** 형제(EM4·EM7·EM10)는 다 적는데 이것만 빠져 있었다 —
    // 스크롤 복원(§4.1d)이 붙어 여는 자리가 0이 아니게 되면 아래 `> 0`이 공짜로 참이 되고
    // 두 번째 단언도 우연히 통과한다(적대적 검증 2026-08-24).
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
    fx.session.chrome_host.find.current = 1;
    revealCurrentFindMatch(fx.session, term);
    try testing.expect(term.rt.editor_first_line > 0);

    // **프레임을 안 그리고** 위쪽 매치로 되돌아간다. 스냅숏은 아직 첫 화면(줄 0 포함)을 담고
    // 있으므로, 그 목록만 믿으면 "이미 보인다"로 답해 안 굴러간다.
    fx.session.chrome_host.find.current = 0;
    revealCurrentFindMatch(fx.session, term);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
}

test "EM12 조각 축 스냅숏 낡음도 잡는다 — 긴 줄 안을 굴린 뒤 Enter" {
    // **`top_piece` 비교를 지워도 아무도 못 잡았다**(적대적 검증 2026-08-24, 뮤턴트 P4).
    // 제품 경로가 있다: `scrollPieces`는 랩된 긴 줄 **안에서** `first_line`은 그대로 두고
    // `first_piece`만 바꾼다. 휠로 긴 줄 안을 굴린 뒤 같은 프레임에 Enter를 누르면 낡은
    // `editor_hit_lines`를 그대로 믿는다 — EM11이 줄 축에서 막은 회귀의 조각 축 판이다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    // **줄이 넉넉해야 한다** — `clampScrollToGeometry`가 `first_line`을 상한으로 되돌리면
    // 아래 전제(줄 30에서 그렸다)가 성립하지 않는다.
    for (0..200) |i| {
        var buf: [800]u8 = undefined;
        const filler = "long " ** 100; // 500자 — 한 줄이 여러 조각
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {s}\n", .{ i, filler }));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "pc.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "pc.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);
    term.rt.editor_wrap = true;

    // **긴 줄 중간에서 한 프레임 그린다** — 스냅숏이 `(줄 30, 조각 20)`을 굳힌다.
    term.rt.editor_first_line = 30;
    term.rt.editor_first_piece = 20;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expectEqual(@as(usize, 30), term.rt.editor_hit_geom.top_line);
    try testing.expectEqual(@as(u32, 20), term.rt.editor_hit_geom.top_piece);

    // **조각만 되감는다**(휠로 그 줄 위쪽으로 굴린 것) — 프레임은 안 그린다.
    term.rt.editor_first_piece = 0;

    // 그 화면에 없는 매치로 간다. 조각을 안 보면 "줄 30이 그려져 있다"며 안 굴러간다.
    try fx.session.editor_find_matches.append(allocator, .{ .line = 30, .start = 0, .len = 1 });
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();
    revealCurrentFindMatch(fx.session, term);

    // **"매치가 실제로 그려지는가"로 잰다 — 좌표를 다시 계산해 대조하지 않는다.**
    // 초판은 `expectEqual(30 -| drawnDocLines/2, first_line)`을 썼는데 둘이 나빴다:
    // ⑴ `drawnDocLines`가 **낡은 스냅숏**의 값이라 기대값이 제품과 같은 실수를 공유했고,
    // ⑵ 여유가 3줄뿐이라 픽스처가 조금만 달라지면 아무것도 안 재게 된다(적대적 검증 2026-08-24).
    // 바로 앞줄이 스스로 넣은 `first_piece = 0`을 다시 재던 단언도 공허해서 걷어냈다.
    // **먼저 "굴렀는가"를 잰다.** `shown`만 보면 **지난 프레임의 배열이 남아 있어** 아무것도 안
    // 해도 참이 된다 — 실측으로 이 판정자는 프레임을 **0개** 그려도 초록이었다(적대적 검증
    // 2026-08-24, 뮤턴트 R4b). 5라운드가 "자기가 넣은 값을 다시 잰다"며 위치 단언을 걷어내면서
    // **4라운드가 닫은 조각 축 구멍(P4)을 다시 열었다.**
    //
    // 자기참조를 피하려고 **부등식**만 쓴다: 조각 축이 낡았으니 자리는 반드시 30보다 위로 간다.
    try testing.expect(term.rt.editor_first_line < 30);

    // 프레임 둘 — 첫 프레임이 스냅숏을 갱신하고 재조준이 돌며, 둘째가 그 자리를 그린다(EM13 참조).
    for (0..2) |_| {
        var after = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        after.dl.deinit(allocator);
    }
    const shown = for (term.rt.editor_hit_lines[0..term.rt.editor_hit_rows_len]) |dl| {
        if (dl == 30) break true;
    } else false;
    try testing.expect(shown);
}

test "EM13 배치가 바뀌면 스냅숏을 안 믿는다 — 랩을 켜고 프레임 없이 Enter" {
    // **접힘·랩 토글은 `first_line`을 일부러 안 건드린다**(`toggleWrap`의 doc). 그래서 세로 위치만
    // 대조하던 초판은 "신선하다"고 답하며 낡은 목록을 믿었다 — 적대적 검증 2026-08-24가 랩 토글로
    // 실측했다(보이는 줄이 12개인데 줄 32를 "보인다"고 답해 안 굴렀다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    for (0..40) |i| {
        var buf: [400]u8 = undefined;
        const filler = "wrap me " ** 20;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {s}\n", .{ i, filler }));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "wr.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "wr.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    // **랩을 끈 채** 한 프레임 — 짧은 줄이 아니므로 화면에 줄이 많이 들어간다.
    term.rt.editor_wrap = false;
    var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    const wide_docs = drawnDocLines(term);

    // **랩을 켠다 — 프레임은 안 그린다.** 세로 위치는 그대로다(토글이 일부러 안 건드린다).
    term.rt.editor_wrap = true;
    try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);

    // 랩을 켜면 실제로 보이는 줄이 훨씬 적어진다 — 그래야 판정이 성립한다.
    const target: u32 = @intCast(wide_docs - 1);
    try fx.session.editor_find_matches.append(allocator, .{ .line = target, .start = 0, .len = 1 });
    fx.session.chrome_host.find.current = 0;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();
    revealCurrentFindMatch(fx.session, term);
    // 낡은 목록을 믿으면 "보인다"며 0에 남는다.
    try testing.expect(term.rt.editor_first_line > 0);

    // **그리고 실제로 보여야 한다.** `> 0`만 보면 *굴러갔지만 여전히 화면 밖*인 상태를 통과시킨다 —
    // 실제로 그랬다: 낡았다고 옳게 판정해 놓고 **그 낡은 목록에서 나온 줄 수로** 가운데를 잡아
    // 첫 Enter가 매치를 못 올렸고 **두 번 눌러야 보였다**(적대적 검증 2026-08-24 실측).
    //
    // **프레임을 둘 그린다.** 첫 프레임이 스냅숏과 `editor_total_visual_rows`를 이 배치의 값으로
    // 갱신하고 그 끝에서 재조준이 돌며(`editor_find_reveal_pending`), 둘째 프레임이 그 자리를 그린다.
    //
    // **여기는 그 두 프레임이 실제로 온다고 가정한다** — 그 가정(재조준이 다음 프레임을 예약하는가)은
    // 이 판정자가 원리적으로 못 잰다. `PaneFixture`는 경량이라 `tick()`이 렌더 경로를 안 타고,
    // `appendPaneFrame`을 직접 부르는 판정자는 **그 함수 바깥의 배선을 못 본다**. 실제로 그
    // 배선이 끊겨 있었고(같은 tick의 `metal_dirty` 소거가 삼켰다) 이 판정자는 초록이었다
    // (적대적 검증 2026-08-24). **그 축은 `EF8`이 제품 `tick()`으로 잰다** — 단위 판정자를 둘 때는
    // 같은 축을 종단으로 한 번 더 재는 짝을 세운다.
    for (0..2) |i| {
        var after = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        after.dl.deinit(allocator);
        // **첫 프레임 뒤에는 예약이 소진돼 있어야 한다.** 재조준이 `storeHitRows` **앞**에 있으면
        // 그 프레임이 그린 자리와 굳힌 행 배열이 갈리고(픽셀은 7..23인데 장부는 16..32) 예약이
        // 다시 선다 — 그 상태를 아무도 안 재고 있었다(적대적 검증 2026-08-24, 뮤턴트 R3).
        // 이 픽스처에는 접힘이 없으므로 재조준은 한 번이면 끝난다(접히면 최대 두 번 — 그 doc).
        if (i == 0) try testing.expect(!term.rt.editor_find_reveal_pending);
    }
    const shown = for (term.rt.editor_hit_lines[0..term.rt.editor_hit_rows_len]) |dl| {
        if (dl == target) break true;
    } else false;
    try testing.expect(shown);
}

test "EM14 신선도 대조의 **모든 축**이 하중을 진다 — 하나만 바꿔도 낡음이다" {
    // **3라운드가 대조 항목을 다섯 늘리면서 넷을 무판정으로 남겼다**(적대적 검증 2026-08-24가
    // 하나씩 빼서 확인: `visible_len`·`tab_width`·`cell_w_px`·`cell_h_px`를 지워도 33개가 전부
    // 초록이었다). *"판정 안 하던 판정자 셋"*을 닫는다고 적은 커밋이 **같은 자리에 새 무판정
    // 축을 넷 열었다.**
    //
    // `EM12`(조각)·`EM13`(랩)이 축 하나씩을 잡으므로, 여기서는 **나머지 축을 한 표로** 잡는다 —
    // 축마다 판정자를 따로 세우면 다음에 축이 늘 때 또 빠뜨린다.
    //
    // 형태: 매치가 **화면 안**에 있는 상태로 한 프레임 그린다(그래서 "안 굴러간다"가 기준선이다)
    // → 축 하나만 라이브로 바꾼다 → 이제 굴러가야 한다(무엇이 보이는지 모르니까).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    const Axis = enum { none, visible_len, tab_width, cell_w, cell_h };
    for ([_]Axis{ .none, .visible_len, .tab_width, .cell_w, .cell_h }) |axis| {
        var fx = try PaneFixture.init(allocator);
        defer fx.deinit(allocator);
        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(allocator);
        // 접을 블록이 있어야 `visible_len` 축을 움직일 수 있다.
        for (0..120) |i| {
            var buf: [64]u8 = undefined;
            try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "head {d}\n    body\n", .{i}));
        }
        try fx.dir.dir.writeFile(io, .{ .sub_path = "ax.txt", .data = doc.items });
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
        const path = try std.fs.path.join(allocator, &.{ root, "ax.txt" });
        defer allocator.free(path);
        const term = try openPathInActivePane(fx.session, path);

        // **`visible_len` 축만 프레임 *전에* 세운다.** 접었다 펴면 값이 원래대로 돌아와 대조가
        // 안 갈린다 — 검증자의 재현대로 **접은 채 그리고 나서** 펴야 그 축이 움직인다.
        if (axis == .visible_len) try testing.expect(foldAll(fx.session));

        var drawn = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        drawn.dl.deinit(allocator);
        const rows = term.rt.editor_hit_rows_len;
        try testing.expect(rows > 4);

        // 매치를 **화면 맨 아래쯤**에 둔다 — 굴러가면 값이 확실히 바뀌는 자리다.
        const target: u32 = term.rt.editor_hit_lines[rows - 1];
        try fx.session.editor_find_matches.append(allocator, .{ .line = target, .start = 0, .len = 1 });
        fx.session.chrome_host.find.current = 0;
        fx.session.chrome_host.find.open = true;
        fx.session.editor_find_source = term.surfaceId();

        switch (axis) {
            .none => {},
            // **편다** — `first_line`은 안 움직이고(펴기는 앵커를 지킨다) 보이는 줄 수만 바뀐다.
            // 그 필드 doc이 접힘을 **먼저** 이름 대 놓고 랩 절반만 판정자를 세웠던 자리다.
            .visible_len => {
                try testing.expect(unfoldAll(fx.session));
                term.rt.editor_first_line = term.rt.editor_hit_geom.top_line; // 위치 축은 고정
            },
            .tab_width => term.rt.editor_tab_width = term.rt.editor_tab_width + 1, // config reload가 하는 일
            .cell_w => fx.session.cell_width_px += 1, // 폰트 크기 변경
            .cell_h => fx.session.cell_height_px += 1,
        }

        revealCurrentFindMatch(fx.session, term);
        if (axis == .none) {
            // 기준선: 스냅숏이 신선하고 매치가 화면 안이라 **안 움직인다**.
            try testing.expectEqual(@as(usize, 0), term.rt.editor_first_line);
        } else {
            // 축 하나만 달라져도 그 목록은 이 화면 것이 아니다 — 무엇이 보이는지 모르니 굴린다.
            try testing.expect(term.rt.editor_first_line > 0);
        }
    }
}

test "[측정] 검색 강조가 프레임마다 문서 전체를 훑는 비용" {
    // **§5.1이 "아직 측정하지 않았다"고 적어 둔 값이다.** `buildFindMarks`는 dirty 게이트 없이
    // 매 프레임 돌아 **보이는 줄 전체 × 매치 전체**를 쓴다(`buildSelectionMarks`도 같은 모양이라
    // 둘이 함께 돈다). 매치 수에 상한을 안 둔 결정의 대가가 저장소만이 아니라 **프레임 시간**에도
    // 붙는데, 그것을 「한계」가 메모리로만 적고 있었다.
    //
    // **판정은 시간이 아니라 마크 수로 한다**(이 파일의 가로 휠 측정과 같은 규율 — 시간은 러너
    // 부하와 구분이 안 된다). 재는 것: 프레임 하나가 채우는 마크가 **매치 수에 비례**하는지,
    // 그리고 화면에 그릴 수 있는 수와 얼마나 벌어지는지. 시간은 출력만 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = std.testing.io;

    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(allocator);
    // 흔한 글자가 잔뜩인 문서 — 사용자가 `e`를 치는 상황이다.
    for (0..20_000) |i| {
        var buf: [64]u8 = undefined;
        try doc.appendSlice(allocator, try std.fmt.bufPrint(&buf, "    const value{d} = fetch();\n", .{i}));
    }
    try fx.dir.dir.writeFile(io, .{ .sub_path = "big.txt", .data = doc.items });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try fx.dir.dir.realPath(io, &root_buf)];
    const path = try std.fs.path.join(allocator, &.{ root, "big.txt" });
    defer allocator.free(path);
    const term = try openPathInActivePane(fx.session, path);

    try maru.session.editor.find.findMatches(allocator, term.rt.editor_lines, "e", .{}, &fx.session.editor_find_matches);
    const matches = fx.session.editor_find_matches.items.len;
    fx.session.chrome_host.find.open = true;
    fx.session.editor_find_source = term.surfaceId();

    var drawn0 = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
    drawn0.dl.deinit(allocator);
    const rows = term.rt.editor_hit_rows_len;

    // 프레임 다섯 — 정지 상태인데도 매 프레임 다시 훑는다는 사실을 시간으로 보인다.
    const t0 = std.Io.Clock.awake.now(fx.session.io).nanoseconds;
    for (0..5) |_| {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, term) orelse return error.EditorPaneDidNotDraw;
        d.dl.deinit(allocator);
    }
    const t1 = std.Io.Clock.awake.now(fx.session.io).nanoseconds;

    // 화면에 그릴 수 있는 마크 수(행 × 본문 폭 상한)와 실제로 채운 수를 견준다.
    var filled: usize = 0;
    for (term.rt.editor_find_marks) |r| filled += r.len;
    std.debug.print(
        "\n[측정] {d}줄 문서 · 매치 {d}개 · 그린 행 {d}개: 프레임 5개 {d}ms, 채운 마크 {d}개 (버퍼 {d}개)\n",
        .{ term.rt.editor_lines.len, matches, rows, @divFloor(t1 - t0, std.time.ns_per_ms), filled, term.rt.editor_find_mark_buf.len },
    );

    // **판정: 채우는 마크가 매치 수에 비례한다.** 화면에 그릴 수 있는 것은 수십인데 수만을 채운다 —
    // 뷰포트 창으로 좁히면 사라지는 비용이고, 그 개선은 선택 마크와 **함께** 해야 한다(§5.1).
    // 이 선은 **재앙 감지선**이다: 매치의 절반 이상을 채우면 뷰포트 최적화가 안 들어온 것이다.
    try testing.expect(filled > matches / 2);
    // 그리고 버퍼는 문서 전체 매치 수만큼 잡혀 있다(그 필드 doc이 적은 대가).
    try testing.expect(term.rt.editor_find_mark_buf.len >= matches);
}

// ── 구문 강조 배선(§5.3 1층) ────────────────────────────────────────────────────
//
// **아래 넷은 변환 층이 아니라 배선을 잰다.** `editor_syntax.zig`의 `ES1`~`ES12`는 그 모듈을
// 직접 부르므로, 그것이 **제품 프레임 경로에 실제로 연결됐는지**는 하나도 안 본다 — 적대적
// 검증에서 배선을 통째로 들어낸 뮤턴트 넷이 전부 살아남았다(`W03`·`W05`·`W06`·`W07`).

/// 그린 셀 중에 구문 색 역할을 쓴 것이 있는가. **역할별로 센다** — "색이 있다"만 보면 본문색과
/// 구분이 안 된다.
fn drawnSyntaxRoles(self: *AppSession, term: *Term) usize {
    // **셀 전경색을 센다 — draw op의 역할이 아니라.** `PaneDraw`가 주는 것은 이미 lowering된
    // 셀이고, 그것이 **화면에 닿는 마지막 자료**다. 역할만 보면 lowering이 그것을 버려도 못
    // 잡는다(이 파일이 배경 layer 뒤집힘에서 이미 겪은 부류다).
    //
    // **"본문색과 다르다"로 세면 안 된다.** 처음에 그렇게 썼다가 **gutter 줄 번호**를 세고
    // 있었다 — 그것도 흐린 색이라 본문색과 다르다. 그러면 구문 색이 0개여도 34행이 "칠해진"
    // 것으로 나오고, 창 예산·스크롤 뮤턴트가 전부 살아남는다(적대적 검증 3·4회차).
    // 그래서 **구문 색 팔레트와 일치하는 셀만** 센다.
    var d = appendPaneFrame(self, .{ .x = 100, .y = 50, .w = 800, .h = 600 }, term) orelse return 0;
    defer d.dl.deinit(self.allocator);
    var n: usize = 0;
    for (d.dl.cells) |c| {
        if (isSyntaxColored(self, c)) n += 1;
    }
    return n;
}

/// 이 셀이 **구문 색**으로 칠해졌는가. gutter·선택·비교 밴드와 구분한다.
fn isSyntaxColored(self: *AppSession, c: renderer.DrawCell) bool {
    if (c.codepoint == ' ') return false;
    const rgb = switch (c.style.foreground) {
        .rgb => |v| v,
        else => return false,
    };
    const tk = self.buildChromeTokens();
    for ([_]chrome.tokens.ColorRole{
        .syntax_keyword,  .syntax_string,    .syntax_number,   .syntax_comment,
        .syntax_property, .syntax_type_name, .syntax_function, .syntax_punctuation,
    }) |role| {
        if (std.meta.eql(rgb, tk.get(role))) return true;
    }
    return false;
}

test "ES13 파일을 열면 프레임 op 에 구문 색이 실린다 — 배선이 실제로 붙었다" {
    // **`ES1`은 이것을 못 잰다.** 그쪽은 `lineColors`를 직접 부르므로 그 결과가 프레임까지
    // 흐르는지는 안 본다 — 열 때 provider 를 안 세우거나 프레임에 색을 안 넘기는 뮤턴트가
    // 둘 다 살아남았다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    try testing.expect(fx.term.rt.editor_syntax.provider != null); // grammar 가 섰다
    try testing.expect(drawnSyntaxRoles(fx.session, fx.term) > 0); // 화면까지 닿았다
}

/// 그린 셀 중 **구문 색이 붙은 행**의 집합(화면 기준 행 번호). "색이 있다"만 세면 화면 대부분이
/// 무색이어도 한 셀만 칠해지면 통과한다 — 적대적 검증 3회차에서 창 예산·스크롤 뮤턴트 셋이
/// 그렇게 살아남았다(`W06`·`W09`·`W11`).
fn coloredRows(self: *AppSession, term: *Term, out: *std.AutoHashMap(i32, void)) !void {
    var d = appendPaneFrame(self, .{ .x = 100, .y = 50, .w = 800, .h = 600 }, term) orelse return;
    defer d.dl.deinit(self.allocator);
    for (d.dl.cells) |c| {
        if (isSyntaxColored(self, c)) try out.put(@intCast(c.row), {});
    }
}

test "ES18 화면의 여러 행이 칠해진다 — 한 셀만 보고 통과하지 않는다" {
    // **`ES13`·`ES14`는 "색이 하나라도 있으면" 통과한다.** 그래서 창 예산을 1줄로 줄이거나
    // 스크롤 위치를 어긋내도 안 죽었다(3회차). 화면에 색이 **여러 행에 걸쳐** 있어야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 400) : (i += 1) _ = insertText(fx.session, fx.term, "const q = 7;\n");

    var rows = std.AutoHashMap(i32, void).init(allocator);
    defer rows.deinit();

    // 첫 화면.
    try coloredRows(fx.session, fx.term, &rows);
    const at_top = rows.count();
    try testing.expect(at_top >= 5); // 한 셀이 아니라 여러 행이다

    // **끝 가까이로 굴려도** 마찬가지여야 한다 — 0번부터만 묻거나 예산이 작으면 여기가 빈다.
    rows.clearRetainingCapacity();
    setEditorTop(fx.session, fx.term, fx.term.rt.editor_lines.len - 20);
    try coloredRows(fx.session, fx.term, &rows);
    try testing.expect(rows.count() >= 5);

    // **맨 윗행도 칠해져야 한다** — 스크롤이 한 줄 어긋나면 거기가 무색으로 남는다.
    var min_row: i32 = std.math.maxInt(i32);
    var it = rows.keyIterator();
    while (it.next()) |k| min_row = @min(min_row, k.*);
    var all = std.AutoHashMap(i32, void).init(allocator);
    defer all.deinit();
    try coloredRows(fx.session, fx.term, &all);
    try testing.expect(all.contains(min_row));
}

test "ES14 창보다 긴 문서를 굴려도 그 화면에 색이 붙는다 — 늘 0번 줄을 묻지 않는다" {
    // **문서가 짧으면 이 결함이 원리상 안 보인다.** 처음에는 픽스처의 3줄 문서를 그대로 쓰고
    // 두 줄 굴렸는데, 0번부터 물어도 그 세 줄이 전부 범위에 들어와 뮤턴트가 살아남았다
    // (적대적 검증 2회차 `W06`). **질의 창보다 긴 문서**여야 굴린 화면이 범위 밖으로 나간다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 창 예산(256줄)을 넘기는 문서를 만든다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 400) : (i += 1) _ = insertText(fx.session, fx.term, "const q = 7;\n");

    const total = fx.term.rt.editor_lines.len;
    try testing.expect(total > 300);

    // **끝 가까이로 굴린다** — 0번부터 256줄만 물으면 여기는 무색이 된다.
    setEditorTop(fx.session, fx.term, total - 10);
    try testing.expect(drawnSyntaxRoles(fx.session, fx.term) > 0);
}

test "ES17 undo 뒤에도 색이 되돌아온다 — 전체 재파싱 경로가 산다" {
    // undo·redo 는 한 번에 항목 여럿을 되돌려 범위를 못 만들므로 **전체를 다시 판다**. 그 경로를
    // 없애면 트리가 편집된 문서를 가리킨 채 남아 색이 옛 내용에 붙는다 — 적대적 검증에서 그
    // 경로를 지운 뮤턴트 셋이 전부 살아남았다(2회차 `W02`·`E25`·`E27`).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, fx.term, "// c\n"));

    const doc = fx.term.rt.editor_doc.?;
    const st = &fx.term.rt.editor_syntax;
    {
        const colors = syntax_color.lineColors(st, allocator, doc.file.content, doc.file.lines, 0, 2, 4, &.{});
        var is_comment = false;
        for (colors[0]) |cs| if (cs.role == .syntax_comment) {
            is_comment = true;
        };
        try testing.expect(is_comment);
    }

    try testing.expect(undoEdit(fx.session, fx.term));

    // 되돌린 뒤 첫 줄은 다시 `const a = 1;`이다 — **키워드**여야 한다.
    const doc2 = fx.term.rt.editor_doc.?;
    const colors2 = syntax_color.lineColors(st, allocator, doc2.file.content, doc2.file.lines, 0, 2, 4, &.{});
    try testing.expect(colors2.len >= 1);
    var is_keyword = false;
    for (colors2[0]) |cs| if (cs.role == .syntax_keyword and cs.start_col == 0) {
        is_keyword = true;
    };
    try testing.expect(is_keyword);
}

test "ES15 편집하면 색이 새 내용을 따라온다 — 트리가 낡지 않는다" {
    // **이것이 증분 통지를 재는 유일한 자리다.** 통지가 없으면 트리가 편집 전 문서를 가리킨 채
    // 남고, 색은 **옛 offset**에 붙는다 — 화면에서는 색이 글자에서 밀린 것으로 보인다.
    // 적대적 검증에서 통지를 뺀 뮤턴트 셋이 전부 살아남았다(`W02`·`E25`·`E27`).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const before = drawnSyntaxRoles(fx.session, fx.term);
    try testing.expect(before > 0);

    // 문서 **머리에** 주석 줄을 넣는다 — 뒤 내용이 통째로 밀리므로, 트리가 안 따라오면 색이
    // 밀린 자리에 남는다.
    // **커서를 먼저 둔다** — 없으면 `insertText`가 거절한다(`iter.count() == 0`). 처음에 그것을
    // 빠뜨려 판정자가 빨갛게 나왔는데, 구현이 아니라 이 테스트가 틀린 것이었다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, fx.term, "// added comment line\n"));
    const doc = fx.term.rt.editor_doc.?;
    const st = &fx.term.rt.editor_syntax;
    const colors = syntax_color.lineColors(st, allocator, doc.file.content, doc.file.lines, 0, 4, 4, &.{});
    try testing.expect(colors.len >= 2);

    // 첫 줄은 이제 주석이다 — **주석색**이어야 한다. 트리가 낡았으면 여기가 `keyword`로 남는다.
    var first_is_comment = false;
    for (colors[0]) |cs| {
        if (cs.role == .syntax_comment) first_is_comment = true;
    }
    try testing.expect(first_is_comment);

    // 둘째 줄은 원래 첫 줄(`const a = 1;`)이다 — 키워드가 0열에 있어야 한다.
    var second_has_keyword = false;
    for (colors[1]) |cs| {
        if (cs.role == .syntax_keyword and cs.start_col == 0) second_has_keyword = true;
    }
    try testing.expect(second_has_keyword);
}

test "ES16 비교 뷰는 무색이다 — 문서가 둘이라 축이 갈린다" {
    // 비교 뷰는 좌우가 **다른 문서**라 provider 도 둘이어야 한다. 단일 편집기의 색을 그대로
    // 넘기면 **왼쪽 문서의 색이 오른쪽 글자 위에** 선다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    try testing.expect(syntaxColors(fx.session, fx.term).len > 0); // 단일 편집기는 색이 있다
    fx.term.rt.editor_diff = .{}; // 비교 상태로 바꾼다
    defer fx.term.rt.editor_diff = null;
    try testing.expectEqual(@as(usize, 0), syntaxColors(fx.session, fx.term).len);
}

test "ES19 탭 폭을 바꾸면 색 경계가 따라온다 — 제품 경로로 잰다" {
    // **판정자가 전부 탭 폭 4로만 돌면 하드코딩과 단일 출처를 구분할 수 없다.** 이 저장소가
    // `ADV3-D`에서 같은 함정을 적어 두었는데, 색 계산이 그대로 그 안에 있었다.
    //
    // **두 가지를 함께 잡아야 한다.** 처음에는 `syntax_color.lineColors`를 **직접** 부르며 탭 폭을
    // 인자로 넘겼는데, 그러면 제품 헬퍼(`syntaxColors`)에 박힌 4를 **원리상 못 본다** — 그 뮤턴트가
    // 다섯 회차를 살아남았다. 그래서 여기서는 **제품 경로로** 묻는다.
    //
    // 그리고 탭을 **넷** 둔다. 열 계산이 탭 폭을 작게 보면 색 **예산**(`w`)이 줄어 뒤쪽 토큰이
    // 통째로 빠지는데, 탭 하나짜리 줄에서는 그 차이가 예산 안에 묻힌다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    try testing.expect(insertText(fx.session, fx.term, "\t\t\t\t"));
    setEditorTabWidth(fx.session, fx.term, 8);
    try testing.expectEqual(@as(u8, 8), fx.term.rt.editor_tab_width);

    const colors = syntaxColors(fx.session, fx.term); // **제품 경로**
    try testing.expect(colors.len >= 1);

    var kw_start: ?u32 = null;
    for (colors[0]) |cs| {
        if (cs.role == .syntax_keyword) kw_start = cs.start_col;
    }
    // 탭 넷 × 8열 = 32열에서 `const`가 시작한다. 탭 폭이 4로 박히면 16, 1로 세면 4다.
    try testing.expect(kw_start != null);
    try testing.expectEqual(@as(u32, 32), kw_start.?);
}

test "ES23 접힘이 구문 층으로 승격된다 — 들여쓰기가 못 잡는 것이 접힌다 (§4)" {
    // §4: *"grammar 가 있으면 구문 기반 범위가 들여쓰기 추정을 덮는다. 들여쓰기로는 잡히지 않는 것
    // (여러 줄 인자 목록, 배열 리터럴)이 여기서 접힌다"*.
    //
    // **여는 자리에서는 못 한다**(§2.1a — 그때 트리가 아직 없을 수 있다). 프레임이 돌면서 파싱이
    // 끝나야 덮이므로, 이 판정자는 **프레임을 돌린 뒤** 범위를 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 들여쓰기가 **못 잡는** 모양: 배열 리터럴이 같은 들여쓰기 겹에서 시작해 닫힌다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "const items = .{\n1,\n2,\n};\npub fn f() void {}\n");

    var frames: usize = 0;
    while (fx.term.rt.editor_syntax.pending and frames < 200) : (frames += 1) {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.NoFrame;
        d.dl.deinit(allocator);
    }
    var d2 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.NoFrame;
    d2.dl.deinit(allocator);

    try testing.expect(fx.term.rt.editor_syntax_folds_applied);

    // 0행(`const items = .{`)이 3행(`};`)까지 접힌다 — 들여쓰기 층은 이것을 못 만든다.
    var found = false;
    for (fx.term.rt.editor_fold_ranges) |r| {
        if (r.head == 0 and r.last_hidden >= 2) found = true;
    }
    if (!found) {
        std.debug.print("범위 {d}개: ", .{fx.term.rt.editor_fold_ranges.len});
        for (fx.term.rt.editor_fold_ranges) |r| std.debug.print("{d}->{d} ", .{ r.head, r.last_hidden });
        std.debug.print("\n", .{});
    }
    try testing.expect(found);
}

test "ES37 여는 경로가 예산을 건다 — 프레임 하나를 통째로 먹지 않는다 (§2.1a)" {
    // **「§2.1a 가 제품에 닿았는가」를 재는 자리는 여기다.** `ES21`·`ES22` 는 그 문장을 자기 주석에
    // 적어 두었지만 실제로는 **자기가 `syntax_color.open` 을 직접 불러** 상태를 만든다 — 제품
    // 호출처(`finishAttach`)를 예산 0(무제한)으로 바꿔도 그 둘은 그대로 초록이었다(적대적 검증
    // 3회차에서 그 변이가 살아남았다). `PaneFixture` 는 `openPathInActivePane` 을 타므로 여기서
    // 읽는 값이 **제품이 건 예산**이다.
    //
    // **시간으로 재지 않는다.** 「4ms 안에 못 끝냈다」로 물으면 답이 기계 속도에 달려 빠른 기계에서
    // 거짓이 된다 — 그 병이 오늘 CI 를 여러 번 빨갛게 했다. provider 가 마지막 파싱에 쓴 예산을
    // 그대로 들고 있으므로 **구조로** 묻는다. `0` 은 「취소 안 함」이라 상한 없음과 구별된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const prov = fx.term.rt.editor_syntax.provider orelse return error.NoProvider;
    try testing.expectEqual(syntax_color.frame_parse_budget_ns, prov.budget_ns);
}

test "ES24 문서와 줄 배열이 갈리면 승격하지 않는다 — 엉뚱한 줄이 접힌다" {
    // 트리는 문서에서, 범위는 `rt.editor_lines` 에서 나온다. 제품에서는 같은 문서지만 그 둘이 갈린
    // 상태에서 덮으면 **화살표가 엉뚱한 줄에 서고 접으면 다른 줄이 사라진다**.
    //
    // 이 판정자가 없으면 그 방어가 조용히 사라진다 — 실제로 방어를 넣기 전 기존 접힘 판정자 일곱이
    // 깨졌고, 그것이 이 상태가 실재한다는 증거다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "const items = .{\n1,\n2,\n};\n");

    // 문서와 **다른** 줄 배열을 끼운다(줄 수까지 같게 맞춰 "수만 보는" 검사를 통과시킨다).
    const saved = fx.term.rt.editor_lines;
    defer fx.term.rt.editor_lines = saved;
    const lines = try allocator.alloc([]const u8, saved.len);
    defer allocator.free(lines);
    for (lines) |*l| l.* = "zzz";
    fx.term.rt.editor_lines = lines;
    fx.term.rt.editor_syntax_folds_applied = false;

    promoteFoldRangesToSyntax(fx.session, fx.term);
    try testing.expect(!fx.term.rt.editor_syntax_folds_applied); // 덮지 않았다
}

test "ES21 큰 파일은 여는 프레임에 다 안 판다 — 이어 파고 결국 색이 온다 (§2.1a)" {
    // **§2.1a가 제품에 닿았는지 재는 자리다.** 층(`SYN15`~`SYN17`)이 서도 배선이 예산을 안 걸면
    // 여는 프레임이 그대로 멈춘다 — 그 멈춤은 판정자가 아니라 손에만 나타난다.
    //
    // **여기서 "다 안 판다"를 어떻게 아는가**: 여는 직후 `pending`이 참이고 트리가 아직 없다.
    // 그 뒤 프레임을 돌리면(`appendPaneFrame`이 `resumeParse`를 부른다) 결국 색이 온다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 예산(4ms)을 한 번에 못 끝낼 만큼 조밀한 문서를 만든다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    // 6,000 줄을 **한 번에** 넣는다. 한 줄씩 6,000 번 넣던 때는 증분 경로가 매번 돌아 이 test 하나가
    // 45 초(CI)였다 — 「예산을 한 번에 못 끝낼 만큼 조밀하다」는 조건에 몇 번에 넣었는지는 없다.
    const dense_line = "pub fn f() void { const s = \"abc\"; _ = s; }\n";
    _ = insertText(fx.session, fx.term, dense_line ** 6000);

    // 여는 경로를 다시 태운다 — 위 삽입은 증분 경로라 열기와 다르다.
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);

    // ⑴ **한 프레임에 안 끝났다.** 이건 예산(4ms) 대 기계 속도라 **빠른 기계에서는 안 끊긴다** —
    //    그때는 제품이 틀린 게 아니라 이 시나리오가 성립하지 않은 것이므로 건너뛴다. 하드 단언이면
    //    빠른 기계에서 거짓 빨강이 된다. 같은 파일의 `SP` 판정자 둘이 이미 이렇게 처리한다.
    //    **「제품이 예산을 걸었는가」는 시간이 아니라 구조로 `ES37` 이 잰다.**
    if (!fx.term.rt.editor_syntax.pending) return error.SkipZigTest;
    try testing.expect(fx.term.rt.editor_syntax.provider.?.tree == null); // 그동안 무색이다(§5)

    // ⑵ 프레임을 돌리면 이어 판다. 무한이 아니라 **유한 프레임 안에** 끝나야 한다.
    var frames: usize = 0;
    while (fx.term.rt.editor_syntax.pending and frames < 500) : (frames += 1) {
        var d = appendPaneFrame(fx.session, .{ .x = 100, .y = 50, .w = 800, .h = 600 }, fx.term) orelse
            return error.NoFrame;
        d.dl.deinit(allocator);
    }
    try testing.expect(!fx.term.rt.editor_syntax.pending);
    try testing.expect(frames > 0); // 실제로 나뉘었다 — 한 프레임에 끝났으면 ⑴이 이미 실패한다

    // ⑶ 그리고 색이 온다.
    var rows = std.AutoHashMap(i32, void).init(allocator);
    defer rows.deinit();
    try coloredRows(fx.session, fx.term, &rows);
    try testing.expect(rows.count() >= 5);
}

test "ES22 파싱이 남아 있으면 다음 프레임을 부른다 — idle skip 에 멈추지 않는다" {
    // **이 배선이 없으면 색이 영영 안 온다.** 렌더 루프에는 idle skip이 있어(투영 게이트) 아무도
    // 프레임을 요청하지 않으면 다음 프레임이 안 온다. 이어 팔 것이 남았으면 그 자신이 프레임을
    // 불러야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    // 6,000 줄을 **한 번에** 넣는다. 한 줄씩 6,000 번 넣던 때는 증분 경로가 매번 돌아 이 test 하나가
    // 45 초(CI)였다 — 「예산을 한 번에 못 끝낼 만큼 조밀하다」는 조건에 몇 번에 넣었는지는 없다.
    const dense_line = "pub fn f() void { const s = \"abc\"; _ = s; }\n";
    _ = insertText(fx.session, fx.term, dense_line ** 6000);
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    // 남은 파싱이 있어야 「다음 프레임을 부른다」를 잴 수 있다 — 빠른 기계에서는 안 끊기므로
    // 그 시나리오가 성립하지 않는다(`ES21` 과 같은 이유).
    if (!fx.term.rt.editor_syntax.pending) return error.SkipZigTest;

    fx.session.metal_dirty = false;
    var d = appendPaneFrame(fx.session, .{ .x = 100, .y = 50, .w = 800, .h = 600 }, fx.term) orelse
        return error.NoFrame;
    d.dl.deinit(allocator);
    try testing.expect(fx.session.metal_dirty); // 남았으니 다음 프레임을 불렀다
}

test "ES20 화면 맨 윗줄도 칠해진다 — 한 줄 어긋남을 잡는다" {
    // 스크롤 위치가 한 줄만 밀려도 **맨 윗줄이 질의 범위 밖**이 되어 그 줄만 무색이 된다.
    // `ES18`은 "다섯 행 이상 칠해짐"으로 세므로 한 줄 차이를 못 본다 — 적대적 검증에서 그
    // 뮤턴트가 다섯 회차 내내 살아남았다(`W11`).
    //
    // **행 번호로 짚는다**: 본문 첫 행에 구문 색이 있어야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 400) : (i += 1) _ = insertText(fx.session, fx.term, "const q = 7;\n");
    setEditorTop(fx.session, fx.term, 100);

    var rows = std.AutoHashMap(i32, void).init(allocator);
    defer rows.deinit();
    try coloredRows(fx.session, fx.term, &rows);
    try testing.expect(rows.count() >= 5);

    // **본문 첫 행**(칠해진 행 중 가장 작은 값이 아니라, 그린 셀 전체의 첫 본문 행)에 색이 있어야
    // 한다. 한 줄 밀리면 그 행만 빠지므로 `min`으로 재면 못 잡는다 — 밀린 뒤의 첫 행이 최소가
    // 되기 때문이다.
    var d = appendPaneFrame(fx.session, .{ .x = 100, .y = 50, .w = 800, .h = 600 }, fx.term) orelse
        return error.NoFrame;
    defer d.dl.deinit(allocator);
    var body_first: i32 = std.math.maxInt(i32);
    for (d.dl.cells) |c| {
        if (c.codepoint == ' ') continue;
        body_first = @min(body_first, @as(i32, @intCast(c.row)));
    }
    try testing.expect(rows.contains(body_first));
}

// ── NS4: 편집기 본문 우클릭 (docs/send-selection-to-agent.md §6.1) ─────────────────────────────

/// 활성 pane 본문 안의 한 점(창 좌표). **고정 좌표를 찍으면 안 된다** — 사이드바 폭·pane 바 높이가
/// 레이아웃에서 오므로 손으로 적은 값은 chrome 위로 떨어지거나 pane 밖이 된다(실제로 그랬다).
fn bodyPointInActivePane(session: *AppSession) ?struct { x: f64, y: f64 } {
    var rects: std.ArrayList(app_session_mod.PaneTree.LeafRect) = .empty;
    defer rects.deinit(session.allocator);
    tab_ops.activeTabLeafRects(session, session.allocator, session.termRect(), &rects) catch return null;
    const active = pane_ops.activePane(session);
    for (rects.items) |lr| {
        if (lr.leaf != active) continue;
        const bar_h: f64 = if (pane_ops.paneBar(session, lr.rect, lr.leaf)) |pb|
            @floatFromInt(pb.full.h)
        else
            0;
        return .{
            .x = @as(f64, @floatFromInt(lr.rect.x)) + @as(f64, @floatFromInt(lr.rect.w)) / 2,
            .y = @as(f64, @floatFromInt(lr.rect.y)) + bar_h + @as(f64, @floatFromInt(lr.rect.h - @as(u32, @intFromFloat(bar_h)))) / 2,
        };
    }
    return null;
}

test "NS4 편집기 본문 우클릭은 붙여넣기를 요청하지 않고 메뉴를 띄운다" {
    // **이것이 이 조각이 막는 자리다.** 그 전에는 편집기 본문 우클릭이 터미널 본문 분기로 내려가
    // `input.right-click` 기본값 `paste` 에서 클립보드를 요청했고, 그 바이트는 `pasteText` 가
    // 편집기로 라우팅해 **문서에 붙었다**. 그래서 판정자는 둘을 함께 본다 — 메뉴가 떴는가, 그리고
    // 붙여넣기를 **요청하지 않았는가**. 하나만 보면 "메뉴도 뜨고 붙여넣기도 됐다" 를 놓친다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    // **창 크기를 준다** — 픽스처는 렌더 상태만 세우므로 `termRect()` 가 0×0 이고, 그러면 pane 사각이
    // 비어 포인터가 어느 pane 에도 안 맞는다(같은 함정이 스크롤 테스트에도 적혀 있다).
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;
    fx.session.pending_clipboard_action = .none;

    // 먼저 **재료**를 확인한다 — 이것이 틀리면 라우팅을 봐야 할 이유가 없다.
    try testing.expect(pane_ops.activePane(fx.session).activeTerm().kind == .editor);
    try testing.expect(settings_ops.showEditorContextMenu(fx.session, fx.term, 10, 10));
    settings_ops.closeContextMenu(fx.session);

    const pt = bodyPointInActivePane(fx.session) orelse return error.SkipZigTest;
    fx.session.mouse(1, pt.x, pt.y, 2, 0);

    try testing.expect(fx.session.editor_context_menu != null);
    try testing.expect(fx.session.chrome_host.context_menu.open);
    try testing.expectEqual(app_session_mod.ClipboardAction.none, fx.session.pending_clipboard_action);
}

test "NS4 항목은 편집 가능 여부를 따른다 — 읽기 전용이면 잘라내기·붙여넣기가 없다" {
    // 항목 정책은 `session/content_menu.zig` 가 소유한다(파일 패널 웹과 한 벌). 여기서 재구현하면
    // 두 표면이 같은 메뉴를 다른 규칙으로 채운다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    const pt = bodyPointInActivePane(fx.session) orelse return error.SkipZigTest;
    fx.session.mouse(1, pt.x, pt.y, 2, 0);
    const editable = fx.session.editor_context_menu.?;
    try testing.expectEqual(@as(usize, 4), editable.len); // 잘라내기·복사·붙여넣기·전체 선택
    settings_ops.closeContextMenu(fx.session);

    fx.term.rt.editor_doc.?.file.read_only = true;
    fx.session.mouse(1, pt.x, pt.y, 2, 0);
    const read_only = fx.session.editor_context_menu.?;
    try testing.expectEqual(@as(usize, 2), read_only.len); // 복사·전체 선택만
    for (read_only.items[0..read_only.len]) |item| {
        try testing.expect(item != .cut);
        try testing.expect(item != .paste);
    }
}

test "NS4 전체 선택은 편집기 문서를 고른다 — 코어 큐로 새지 않는다" {
    // `select_all` 액션이 주소창·커밋 상자는 분기하는데 **편집기만 빠져** 있었다. 편집기 Term 의
    // 코어는 sentinel 이라 그 명령이 닿을 곳이 없었고, 그래서 ⌘A 가 아무 일도 안 했다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const len = fx.term.rt.editor_doc.?.file.content.len;
    try testing.expect(len > 0);
    fx.term.rt.editor_selection = null;

    try testing.expect(selectAll(fx.session, fx.term));
    const sel = fx.term.rt.editor_selection.?;
    try testing.expectEqual(@as(usize, 0), sel.anchorLo());
    try testing.expectEqual(len, sel.focus);
}

test "NS4 편집기가 아닌 Term 에서는 이 메뉴가 안 뜬다" {
    // 같은 pane 에 터미널 Term 과 편집기 Term 이 함께 있다. 우클릭이 **활성 Term 의 종류**로
    // 갈리지 않으면 터미널 위에서 편집기 메뉴가 뜨거나 그 반대가 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const pane = pane_ops.activePane(fx.session);
    var terminal: ?*Term = null;
    for (pane.terms.items) |t| {
        if (t.kind != .editor) terminal = t;
    }
    const term = terminal orelse return error.SkipZigTest; // 픽스처에 터미널이 없으면 잴 것이 없다

    try testing.expect(!settings_ops.showEditorContextMenu(fx.session, term, 300, 300));
    try testing.expect(fx.session.editor_context_menu == null);
    try testing.expect(!selectAll(fx.session, term)); // 전체 선택도 편집기 것이 아니다
}

// ── NS5: 선택 영역 보내기 ─────────────────────────────────────────────────────────────────────

test "NS5 보낸 페이로드는 개행으로 안 끝난다 — 그 개행이 실행 트리거다" {
    // **이 기능의 유일한 진짜 위험이다**(§4). 터미널에 쓰는 바이트는 셸의 표준 입력이고, 끝에 개행이
    // 있으면 사용자가 프롬프트를 보기 전에 그 자리에서 실행된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 5 };
    var buf: [8192]u8 = undefined;
    const payload = buildSelectionPayload(fx.session, fx.term, true, &buf).?;
    try testing.expect(payload.len > 0);
    try testing.expect(payload[payload.len - 1] != '\n');
    try testing.expect(std.mem.startsWith(u8, payload, "@"));
}

test "NS5 bracketed 가 꺼진 대상에는 인용 없이 참조 한 줄만 간다" {
    // 여러 줄을 보내면 중간 개행이 실행 트리거가 된다(§4). 안전한 축약이 가능한데 위험을 감수할
    // 이유가 없다 — 참조만으로도 에이전트가 그 파일 그 줄을 연다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 30 }; // 여러 줄
    var on_buf: [8192]u8 = undefined;
    var off_buf: [8192]u8 = undefined;
    const on = buildSelectionPayload(fx.session, fx.term, true, &on_buf).?;
    const off = buildSelectionPayload(fx.session, fx.term, false, &off_buf).?;

    try testing.expect(std.mem.indexOf(u8, on, "> ") != null); // 켜져 있으면 인용이 간다
    try testing.expect(std.mem.indexOf(u8, off, "> ") == null); // 꺼져 있으면 안 간다
    try testing.expect(std.mem.indexOf(u8, off, "@") != null); // 참조는 그래도 간다
    try testing.expect(off.len < on.len);
}

test "NS5 줄 범위는 1-based 닫힌 구간이고, 선택이 없으면 caret 줄 하나다" {
    // 0-based 로 보내면 에이전트가 **한 줄 위**를 연다. 그리고 선택이 없을 때 caret 줄을 담는 것은
    // 복사(§3.4)가 정한 규칙과 같아야 한다 — 같은 표면에서 같은 손동작이 두 뜻을 가지면 안 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    var buf: [8192]u8 = undefined;

    // **참조 줄만 본다.** 경로에 `:` 나 `-` 가 들어갈 수 있어(임시 디렉터리) 페이로드 전체에서
    // 부분 문자열을 찾으면 우연히 맞거나 우연히 틀린다.
    const refLine = struct {
        fn of(payload: []const u8) []const u8 {
            const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse payload.len;
            return payload[0..nl];
        }
    }.of;

    // 첫 줄 안에서만 고른다 → 참조가 `:1` 로 끝난다.
    fx.term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 5 };
    try testing.expect(std.mem.endsWith(u8, refLine(buildSelectionPayload(fx.session, fx.term, true, &buf).?), ":1"));

    // 선택 없이 caret 만 둘째 줄에 → 그 줄 하나(`:2`). **범위를 접는다** — `:2-2` 가 아니다.
    fx.term.rt.editor_selection = .{ .anchor_start = 14, .anchor_end = 14, .focus = 14 };
    try testing.expect(std.mem.endsWith(u8, refLine(buildSelectionPayload(fx.session, fx.term, true, &buf).?), ":2"));

    // 두 줄에 걸치면 닫힌 구간이다 → `:1-2`.
    fx.term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 20 };
    try testing.expect(std.mem.endsWith(u8, refLine(buildSelectionPayload(fx.session, fx.term, true, &buf).?), ":1-2"));
}

test "NS5 편집기가 아니거나 대상이 터미널이 아니면 아무것도 안 보낸다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;

    // 대상이 편집기(=터미널 아님) → `bracketedPasteFor` 가 null 이라 접힌다.
    fx.term.rt.editor_selection = .{ .anchor_start = 0, .anchor_end = 0, .focus = 5 };
    try testing.expect(!sendSelectionToAgent(fx.session, fx.term, fx.term.surface.id));
    try testing.expect(fx.session.pending_pastes.getPtr(fx.term.surface.id) == null);
}

test "NS5 대상의 bracketed 를 읽어 그대로 페이로드에 쓴다 — 배선이 끊기면 인용이 새 나간다" {
    // **`buildSelectionPayload` 를 직접 부르는 판정자는 이 배선을 못 잰다** — 그 함수는 bool 을
    // 받기만 하기 때문이다. 끊긴 배선(늘 `true`)은 bracketed 가 꺼진 대상에 여러 줄을 보내고, 그것이
    // §4 가 막으려는 바로 그 상황이다. 그래서 **읽는 쪽**을 따로 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const pane = pane_ops.activePane(fx.session);
    var terminal: ?*Term = null;
    for (pane.terms.items) |t| {
        if (t.kind == .terminal) terminal = t;
    }
    const term = terminal orelse return error.SkipZigTest;

    // 터미널은 bool 을 답하고, 편집기는 **null 이다**(붙일 PTY 가 없다 — 그때는 아무것도 안 보낸다).
    try testing.expect(term_ops.bracketedPasteFor(fx.session, term.surface.id) != null);
    try testing.expect(term_ops.bracketedPasteFor(fx.session, fx.term.surface.id) == null);
}

test "NS5 후보는 그 창의 터미널만이고 편집기는 대상이 아니다" {
    // 편집기가 후보에 들면 "문서를 문서에 보내기" 가 메뉴에 뜬다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    var folders: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const targets = term_ops.collectAgentTargets(fx.session, &buf, &folders).items;
    try testing.expect(targets.len > 0);
    for (targets) |c| try testing.expect(c.surface_id != fx.term.surface.id);
}

// ── NS6: 라벨 표기와 마지막 대상 ──────────────────────────────────────────────────────────────

test "NS9 대상 줄은 그 pane 에서 실제로 도는 것을 말한다 — 전부 «셸» 이 아니다" {
    // 옛 판은 고정 문구 하나를 세워 여덟 줄이 전부 같은 이름이었다. 그러면 라벨의 첫 자리가
    // 대상을 **못 가른다**. 이 값은 이미 관측 캐시에 있다(에이전트 종류 판정이 쓰는 그 목록).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    pane_ops.newTermInActivePane(fx.session) catch {};

    // 관측에 이름을 심는다 — 제품이 읽는 그 자리다.
    const pane = pane_ops.activePane(fx.session);
    var planted: bool = false;
    for (pane.terms.items) |t| {
        if (t.kind != .terminal) continue;
        var name: maru.pty.types.ForegroundProcessName = .{};
        const want = "fish";
        @memcpy(name.bytes[0..want.len], want);
        name.len = want.len;
        // **비우고 심는다.** 픽스처가 실제 자식을 띄우므로 목록에 이미 이름이 있고(관측이 실제로
        // 도는 증거다 — 첫 회차에 `bash` 가 나왔다), 뒤에 붙이면 첫 항목이 안 바뀐다.
        t.rt.observation.foreground_processes.clearRetainingCapacity();
        try t.rt.observation.foreground_processes.append(allocator, name);
        planted = true;
        break;
    }
    // 심을 자리가 없으면 이 판정자는 아무것도 안 잰다.
    try testing.expect(planted);

    var buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    var folders: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const collected = term_ops.collectAgentTargets(fx.session, &buf, &folders);
    var saw = false;
    for (collected.items) |c| {
        if (std.mem.eql(u8, c.shell_name, "fish")) saw = true;
        // 옛 판은 **전부** 고정 문구였다 — 하나라도 그 문구면 그 줄은 대상을 못 가른다.
        try testing.expect(!std.mem.eql(u8, c.shell_name, maru.i18n.t(.ctx_target_shell)));
    }
    try testing.expect(saw);
}

test "NS8 멀티 커서면 주 선택만 간다고 말한다 — 나머지가 갔다고 믿게 두지 않는다" {
    // `buildSelectionPayload` 가 스스로 적어 둔 위험이다 — 「조용히 첫 조각만 보내면 사용자는
    // 나머지가 갔다고 믿는다」. 코드는 그래서 **주 선택만** 보내는데, 정작 그 사실을 말하는 자리가
    // 없었다. 머리글이 그 말을 진다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    pane_ops.newTermInActivePane(fx.session) catch {};

    var buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    var folders: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const collected = term_ops.collectAgentTargets(fx.session, &buf, &folders);

    // 커서 하나면 그 말을 안 한다 — 늘 붙이면 경고가 소음이 된다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    const single = settings_ops.testSendSelectionHeader(fx.session, fx.term, collected);
    try testing.expect(std.mem.indexOf(u8, single, maru.i18n.t(.ctx_send_selection_primary_only)) == null);

    // 커서가 여럿이면 말한다.
    fx.term.rt.editor_extra_selections = try allocator.alloc(editor_selection.Selection, 1);
    defer {
        allocator.free(fx.term.rt.editor_extra_selections);
        fx.term.rt.editor_extra_selections = &.{};
    }
    fx.term.rt.editor_extra_selections[0] = editor_selection.Selection.at(1);
    const multi = settings_ops.testSendSelectionHeader(fx.session, fx.term, collected);
    try testing.expect(std.mem.indexOf(u8, multi, maru.i18n.t(.ctx_send_selection_primary_only)) != null);
}

test "NS7 자리를 넘긴 대상은 조용히 사라지지 않는다 — 머리글이 잘린 수를 말한다" {
    // **옛 판은 그냥 `break` 였다.** 아홉 번째 pane 은 목록에 없고, 없다는 것도 왜 없는지도 알
    // 방법이 없었다. 컴포넌트가 머리글을 앞에서만 세므로 뒤에 줄을 못 달아 **머리글 자체**에 싣는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 자리(8)보다 많은 터미널을 만든다.
    var made: usize = 0;
    while (made < app_session_mod.max_agent_targets + 2) : (made += 1) {
        pane_ops.newTermInActivePane(fx.session) catch break;
    }

    var buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    var folders: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const collected = term_ops.collectAgentTargets(fx.session, &buf, &folders);
    // **자격은 자리와 무관하게 센다** — 이게 0 이면 아래 판정이 아무것도 안 잰다.
    try testing.expect(collected.eligible > collected.items.len);

    const header = settings_ops.testSendSelectionHeader(fx.session, fx.term, collected);
    // 기본 문구로 끝나면 잘린 사실을 안 말한 것이다.
    try testing.expect(!std.mem.eql(u8, header, maru.i18n.t(.ctx_send_selection)));
    try testing.expect(std.mem.startsWith(u8, header, maru.i18n.t(.ctx_send_selection)));
    // 두 수가 **실제로** 들어갔다.
    var want: [32]u8 = undefined;
    const shown = try std.fmt.bufPrint(&want, "{d}", .{collected.items.len});
    try testing.expect(std.mem.indexOf(u8, header, shown) != null);
    const total = try std.fmt.bufPrint(&want, "{d}", .{collected.eligible});
    try testing.expect(std.mem.indexOf(u8, header, total) != null);
}

test "NS6 표시된 줄과 저장된 대상은 1:1 이다 — 라벨이 하나 빠져도 안 어긋난다" {
    // **적대적 검증이 잡은 결함이다.** 라벨을 못 만든 대상을 목록에는 남기고 줄만 건너뛰면, 그 뒤
    // 줄이 전부 한 칸씩 밀려 **고른 것과 다른 터미널**로 보낸다. 여기서는 그 불변식을 직접 잰다 —
    // 대상 수는 **실제로 그려진 줄 수**와 같아야 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;
    fx.session.backing_width_px = 1200;
    fx.session.backing_height_px = 800;

    try testing.expect(settings_ops.showEditorContextMenu(fx.session, fx.term, 10, 10));
    const menu = fx.session.editor_context_menu.?;
    try testing.expect(menu.target_len > 0);
    // 머리글 1 + 대상 줄들 = send_rows.
    try testing.expectEqual(menu.send_rows, 1 + menu.target_len);
    // 전체 줄 수도 맞는다(보내기 구획 + 편집 항목).
    try testing.expectEqual(fx.session.context_menu_items_len, menu.send_rows + menu.len);
    settings_ops.closeContextMenu(fx.session);
}

test "NS6 라벨은 폴더와 브랜치로 가른다 — 사이드바가 쓰는 그 두 축이다" {
    // §5 는 "같은 정보를 두 곳에서 다르게 부르지 않는다" 로 정했다. 사이드바 카드가 쓰는 축을
    // 코드로 확인했더니 **폴더 + 브랜치**였다(워크스페이스 이름이 아니다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    var buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    var folders: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const targets = term_ops.collectAgentTargets(fx.session, &buf, &folders).items;
    try testing.expect(targets.len > 0);

    // `where` 가 비어 있으면 라벨이 이름만 남아 여러 대상을 못 가른다 — 그 자리가 §5 의 핵심이다.
    for (targets) |c| try testing.expect(c.where.len > 0);
}

test "NS6 마지막으로 보낸 대상이 다음 메뉴의 기본 선택이다" {
    // §5: "마지막으로 보낸 대상을 창별로 기억해 다음 호출의 기본값으로 둔다." 표식(`⏎`)이 아니라
    // 기본 선택인 이유는 `last_agent_target` 주석에 적었다(표식 축을 켜면 메뉴 전체가 들여쓰기된다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.surface_initialized = true;

    // **대상이 둘 이상이어야 이 판정자가 무엇이라도 잰다.** 앞 판은 `targets[0]` 을 기억시켰는데,
    // 기본값도 그 줄(머리글 다음)이라 **기억이 죽어도 단언이 통과했다** — 실제로 읽는 쪽을
    // `if (@as(?u64, null))` 로 죽인 뮤턴트가 이 판정자를 지나 main 에 머지됐다(`fbc71126`).
    // 그래서 pane 을 갈라 둘째 대상을 만들고, **기본값과 다른 줄**을 기억시킨다.
    try pane_ops.splitActivePane(fx.session, .horizontal);

    // 기억이 없으면 첫 고를 수 있는 줄(머리글 다음)이 기본이다.
    try testing.expect(settings_ops.showEditorContextMenu(fx.session, fx.term, 10, 10));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.context_menu.selected);
    const menu0 = fx.session.editor_context_menu.?;
    try testing.expect(menu0.target_len >= 2); // 둘이 없으면 아래 단언이 다시 무력해진다
    const second = menu0.targets[1];
    settings_ops.closeContextMenu(fx.session);

    // **없는 id 를 기억해 두면 무시된다** — 닫힌 Term 을 기억한 상태다.
    fx.session.last_agent_target = 0xDEAD_BEEF;
    try testing.expect(settings_ops.showEditorContextMenu(fx.session, fx.term, 10, 10));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.context_menu.selected);
    settings_ops.closeContextMenu(fx.session);

    // 살아 있는 **둘째** 대상을 기억하면 그 줄에서 시작한다 — 기본값(1)과 갈리는 자리다.
    fx.session.last_agent_target = second;
    try testing.expect(settings_ops.showEditorContextMenu(fx.session, fx.term, 10, 10));
    const menu = fx.session.editor_context_menu.?;
    const sel = fx.session.chrome_host.context_menu.selected;
    try testing.expectEqual(@as(usize, 2), sel); // 머리글 1 + 인덱스 1
    try testing.expectEqual(second, menu.targets[sel - 1]);
    settings_ops.closeContextMenu(fx.session);
}

test "ES30 헤더 체인은 primary caret 을 따라간다 — 선택이 있으면 anchor 가 아니라 focus 다 (§7.5)" {
    // **`headerBreadcrumb` 를 재는 자리다.** 위 `ES25`~`ES29` 는 `breadcrumb` 을 직접 부르므로 이 함수의
    // 배선(비교 뷰 건너뛰기·문서 조회·어느 끝을 커서로 보나)이 통째로 안 재졌다 — 뮤테이션에서
    // `focus` 를 `anchor_start` 로 바꿔도 아무 판정자가 안 죽었다.
    //
    // **focus 여야 하는 이유**: 선택을 끌면 anchor 는 시작한 자리에 남고 caret 은 focus 쪽이다. 사용자가
    // 보는 "지금 여기" 는 caret 이므로, anchor 를 보면 **드래그 중에 체인이 출발지에 얼어붙는다**.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const Widget = struct {\n    pub fn draw() void {\n        var x: u8 = 0;\n        x += 1;\n    }\n};\n");

    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }

    const src = doc.file.content;
    const anchor_off = std.mem.indexOf(u8, src, "pub const").?; // 바깥(Widget)만 품는다
    const focus_off = std.mem.indexOf(u8, src, "x += 1").?; // 안쪽(draw)까지 품는다

    // **anchor 는 밖, focus 는 안** — 둘을 보는 차이가 화면에 나타나는 선택이다.
    fx.term.rt.editor_selection = editor_selection.Selection.fromPoints(anchor_off, focus_off);
    const label = headerBreadcrumb(fx.session, fx.term, "a.zig");
    try testing.expectEqualStrings("a.zig \u{203A} Widget \u{203A} draw", label);
}

test "ES31 비교 뷰는 체인을 그리지 않는다 — 문서가 둘이다 (§7.5)" {
    // §7.5 저하 표의 마지막 줄. `syntaxColors` 가 같은 이유로 같은 판정을 하는데(문서가 둘이라
    // provider 도 둘이어야 한다), 그 규율이 이 함수에도 서 있는지 잰다 — 뮤테이션에서 이 분기를
    // 지워도 아무 판정자가 안 죽었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const Widget = struct {\n    pub fn draw() void {\n        var x: u8 = 0;\n    }\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    const inside = std.mem.indexOf(u8, doc.file.content, "var x").?;
    fx.term.rt.editor_selection = editor_selection.Selection.at(inside);

    // 평소에는 체인이 나온다 — 아래 대비의 기준선이다.
    try testing.expect(!std.mem.eql(u8, "a.zig", headerBreadcrumb(fx.session, fx.term, "a.zig")));

    // 비교 뷰로 들어가면 **경로만** 남는다.
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    try testing.expectEqualStrings("a.zig", headerBreadcrumb(fx.session, fx.term, "a.zig"));
}

test "ES32 구문 접힘 승격이 보이는 줄 표를 다시 만든다 — 「접힌 것 없음」과 부분집합이 함께 살 수 없다" {
    // **사용자 제보 결함의 가설을 확정하는 자리**(2026-08-30 — 「커서 위치와 실제 입력 위치가 다르다」).
    //
    // `rebuildVisible` 의 구조가 불변식 하나를 말한다: **접힌 것이 없으면 `editor_visible_lines` 는
    // 비어 있다**(원본을 그대로 그리라는 표시). 그런데 `promoteFoldRangesToSyntax` 는 범위를 갈아
    // 끼우며 `editor_folded_len = 0` 으로 되돌리면서 그 배열을 안 건드린다.
    //
    // 그래서 **파싱이 끝나기 전에 접으면** 「접힌 것 없음 + 보이는 줄은 부분집합」이라는 모순이 남는다.
    // 큰 문서는 예산 파싱이 여러 프레임 걸리므로(§2.1a) 실제로 도달한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 들여쓰기 접힘이 잡히고 구문 접힘도 잡히는 문서.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term,
        \\pub fn outer() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\
        \\pub fn other() void {
        \\    const c = 3;
        \\    _ = c;
        \\}
        \\
    );

    // ⑴ **파싱 전에 접는다** — 그 순간 들여쓰기 층의 범위로 접힌다.
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = .{};
    fx.term.rt.editor_syntax_folds_applied = false;
    try ensureFoldRanges(fx.session, fx.term);
    if (fx.term.rt.editor_fold_ranges.len == 0) return error.SkipZigTest; // 접을 것이 없다 — 잴 것이 없다
    const head = fx.term.rt.editor_fold_ranges[0].head;
    _ = toggleFoldHead(fx.session, fx.term, head);
    try testing.expect(fx.term.rt.editor_folded_len > 0);
    try testing.expect(fx.term.rt.editor_visible_lines.len > 0); // 부분집합이 섰다

    // ⑵ 이제 파싱이 끝나고 승격이 돈다.
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    promoteFoldRangesToSyntax(fx.session, fx.term);
    try testing.expect(fx.term.rt.editor_syntax_folds_applied);

    // ⑶ **불변식**: 접힌 것이 없으면 보이는 줄 배열도 비어 있어야 한다.
    if (fx.term.rt.editor_folded_len == 0) {
        try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_visible_lines.len);
        try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_visible_numbers.len);
    }
}

test "NAV1 이동은 열기→펴기→caret→스크롤 순서로 간다 — 접힌 자리로도 갈 수 있다 (§5.2)" {
    // §5.2 「순서가 계약이다」. 접힘을 안 펴고 caret 만 옮기면 **화면에 없는 곳**으로 가고,
    // 사용자는 아무 일도 안 일어난 것으로 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {\n    const x = 1;\n    _ = x;\n}\n\npub fn b() void {\n    const y = 2;\n    _ = y;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const target = std.mem.indexOf(u8, doc.file.content, "_ = y").?;

    try navigateTo(fx.session, .{ .offset = target });

    const sel = fx.term.rt.editor_selection orelse return error.NoSel;
    try testing.expectEqual(target, sel.focus);
    // **여러 커서를 남기지 않는다** — 이동은 커서를 하나로 놓는다.
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_extra_selections.len);
}

test "NAV2 뒤로 가면 떠난 자리로 돌아오고, 앞으로가 그것을 되짚는다 (§5.2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {\n    const x = 1;\n}\n\npub fn b() void {\n    const y = 2;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const first = std.mem.indexOf(u8, doc.file.content, "const x").?;
    const second = std.mem.indexOf(u8, doc.file.content, "const y").?;

    fx.term.rt.editor_selection = editor_selection.Selection.at(first);
    try navigateTo(fx.session, .{ .offset = second });
    try testing.expectEqual(second, (fx.term.rt.editor_selection orelse return error.NoSel).focus);

    // 뒤로 — 떠난 자리다.
    try testing.expect(navigateBack(fx.session));
    try testing.expectEqual(first, (fx.term.rt.editor_selection orelse return error.NoSel).focus);

    // 앞으로 — 다시 그 자리다.
    try testing.expect(navigateForward(fx.session));
    try testing.expectEqual(second, (fx.term.rt.editor_selection orelse return error.NoSel).focus);

    // 더 갈 곳이 없다.
    try testing.expect(!navigateForward(fx.session));
}

test "NAV3 같은 자리로 가면 스택이 안 쌓인다 — 뒤로가 먹통처럼 보이지 않게 (§5.2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {\n    const x = 1;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const spot = std.mem.indexOf(u8, doc.file.content, "const x").?;

    fx.term.rt.editor_selection = editor_selection.Selection.at(spot);
    try navigateTo(fx.session, .{ .offset = spot }); // 지금 자리 그대로
    try navigateTo(fx.session, .{ .offset = spot });
    try navigateTo(fx.session, .{ .offset = spot });

    try testing.expectEqual(@as(usize, 0), fx.session.editor_nav_back.items.len);
    try testing.expect(!navigateBack(fx.session)); // 갈 곳이 없다
}

test "NAV4 새로 이동하면 앞으로 스택을 버린다 — 가지 않은 미래를 가리키지 않는다 (§5.2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {\n    const x = 1;\n}\n\npub fn b() void {\n    const y = 2;\n}\n\npub fn c() void {\n    const z = 3;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const a = std.mem.indexOf(u8, doc.file.content, "const x").?;
    const b = std.mem.indexOf(u8, doc.file.content, "const y").?;
    const c = std.mem.indexOf(u8, doc.file.content, "const z").?;

    fx.term.rt.editor_selection = editor_selection.Selection.at(a);
    try navigateTo(fx.session, .{ .offset = b });
    try testing.expect(navigateBack(fx.session)); // a 로 돌아왔다 — 앞으로에 b 가 있다
    try testing.expect(fx.session.editor_nav_forward.items.len > 0);

    try navigateTo(fx.session, .{ .offset = c }); // 새 이동
    try testing.expectEqual(@as(usize, 0), fx.session.editor_nav_forward.items.len);
    try testing.expect(!navigateForward(fx.session));
}

test "NAV5 root 밖 경로는 열지 않는다 — 표시와 접근을 가른다 (§5.2)" {
    // §5.2: *"서버가 준 경로라는 것은 열어도 된다는 근거가 아니다"*. 판정의 단일 출처는
    // `repo_path.underRoot` 이고, 그것이 이 경로에 실제로 붙었는지 잰다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **root 를 모르면 안 막는다** — 저장소 밖에서 파일 하나만 열어 쓰는 경우이고, 그때 「밖」이라는
    // 개념 자체가 없다. 픽스처는 그 상태로 시작하므로 여기서 먼저 그 갈래를 못박는다.
    try testing.expect(fx.session.git_repo == null and fx.session.file_tree.rootCount() == 0);
    if (navigateTo(fx.session, .{ .path = "/etc/passwd", .offset = 0 })) |_| {
        // 열렸다 — root 를 모르니 막지 않았다는 뜻이고, 그것이 이 갈래의 계약이다.
    } else |e| {
        try testing.expect(e != error.OutsideRoot); // 못 열 수는 있어도 **막혀서**는 아니다
    }

    // 이제 root 를 세운다 — 세션이 소유하므로 `dupe` 로 넘긴다(`deinit` 이 free 한다).
    fx.session.git_repo = try allocator.dupe(u8, "/private/tmp/maru-nav-root-fixture");

    const before = fx.session.tabs.items[fx.session.app_window.active_tab].panes.items.len;
    try testing.expectError(error.OutsideRoot, navigateTo(fx.session, .{
        .path = "/etc/passwd",
        .offset = 0,
    }));
    // 아무것도 안 열렸다.
    try testing.expectEqual(before, fx.session.tabs.items[fx.session.app_window.active_tab].panes.items.len);
}

test "NAV6 닫힌 Term 을 가리키는 항목은 버리고 다음으로 간다 — 멈추지 않는다 (§5.2)" {
    // §5.2: *"못 찾으면 그 항목을 버리고 다음으로 간다 — 닫힌 파일을 되살리지 않는다"*.
    // **거기서 멈추면 뒤로가 영영 막힌다** — 닫은 파일 하나가 스택 전체를 봉한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {\n    const x = 1;\n}\n\npub fn b() void {\n    const y = 2;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const first = std.mem.indexOf(u8, doc.file.content, "const x").?;
    const second = std.mem.indexOf(u8, doc.file.content, "const y").?;

    fx.term.rt.editor_selection = editor_selection.Selection.at(first);
    try navigateTo(fx.session, .{ .offset = second });
    try testing.expectEqual(@as(usize, 1), fx.session.editor_nav_back.items.len);

    // **닫힌 Term 을 가리키는 항목을 스택 맨 위에 끼운다.** 존재하지 않는 surface id 는 `termBySurfaceId`
    // 가 못 찾는 자리 그대로다 — 실제로 Term 을 닫으면 픽스처의 유일한 편집기가 사라져 갈 곳도 없어진다.
    try fx.session.editor_nav_back.append(allocator, .{ .surface_id = std.math.maxInt(u64), .offset = 0 });
    try testing.expectEqual(@as(usize, 2), fx.session.editor_nav_back.items.len);

    // 죽은 항목을 지나 **살아 있는 자리로** 간다.
    try testing.expect(navigateBack(fx.session));
    try testing.expectEqual(first, (fx.term.rt.editor_selection orelse return error.NoSel).focus);
    try testing.expectEqual(@as(usize, 0), fx.session.editor_nav_back.items.len); // 둘 다 소비됐다
}

test "NAV7 이동은 그 자리를 화면에 드러낸다 — caret 만 옮기지 않는다 (§5.2)" {
    // §5.2: *"화면에 없는 곳으로 caret 만 옮기면 사용자는 아무 일도 안 일어난 것으로 본다"*.
    // 스크롤을 빼도 selection 은 맞으므로 **위 판정자들이 전부 통과한다** — 뮤테이션이 그것을 보였다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 400) : (i += 1) _ = insertText(fx.session, fx.term, "const line = 1;\n");

    // **맨 위로 되돌린다.** 삽입이 커서를 문서 끝으로 끌고 갔고 화면도 따라갔다 — 그대로 재면
    // 「이동이 화면을 옮겼다」와 「이미 거기 있었다」가 구별되지 않는다(첫 판에서 370행이 나왔다).
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    fx.term.rt.editor_first_line = 0;

    // 한 프레임 그려 스냅숏을 만든다 — 스크롤 판정이 그것을 읽는다(§4.1g ②).
    var d0 = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.NoFrame;
    d0.dl.deinit(allocator);
    fx.session.editor_nav_back.clearRetainingCapacity();
    fx.session.editor_nav_forward.clearRetainingCapacity();

    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    const far_line: u32 = 380;
    const far = doc.file.lines.line(far_line) orelse return error.NoLine;

    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line); // 맨 위에서 시작
    try navigateTo(fx.session, .{ .offset = far.start });

    // **화면이 따라갔다.** 첫 줄이 그대로면 그 자리는 화면 밖이다.
    try testing.expect(fx.term.rt.editor_first_line > 0);
    try testing.expect(fx.term.rt.editor_first_line <= far_line);
}

test "NAV8 이동은 커서를 하나로 놓는다 — 멀티커서가 남지 않는다 (§5.2)" {
    // 이동은 「지금 여기」를 하나로 만드는 동작이다. 남은 커서가 있으면 다음 타이핑이 **화면 밖
    // 여러 곳**을 고친다. `NAV1` 이 이것을 보긴 하지만 애초에 커서가 하나여서 뮤턴트를 못 잡았다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "aa\nbb\naa\nbb\naa\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;

    // **커서를 실제로 여럿 만든다** — 그래야 지우는 규율을 잴 수 있다.
    const extras = try allocator.alloc(editor_selection.Selection, 2);
    extras[0] = editor_selection.Selection.at(3);
    extras[1] = editor_selection.Selection.at(6);
    fx.term.rt.editor_extra_selections = extras;
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_extra_selections.len);

    try navigateTo(fx.session, .{ .offset = @min(9, doc.file.content.len) });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_extra_selections.len);
}

test "NAV9 스택은 상한에서 오래된 것부터 버린다 — 오래 켠 창에서 안 자란다 (§5.2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz\n");

    // 상한보다 넉넉히 많이 옮긴다 — 매번 다른 자리라 매번 쌓인다.
    var i: usize = 0;
    while (i < nav_stack_max + 20) : (i += 1) {
        try navigateTo(fx.session, .{ .offset = i + 1 });
    }
    try testing.expectEqual(nav_stack_max, fx.session.editor_nav_back.items.len);

    // **오래된 쪽을 버렸다** — 맨 아래가 0번 자리가 아니다.
    try testing.expect(fx.session.editor_nav_back.items[0].offset > 1);
}

// ── 심볼 피커(§7.5 「피커는 팔레트를 다시 쓴다」) ──────────────────────────────

/// 라벨이 쓸 수 있는 표시 폭. **줄 번호 자리를 먼저 뗀다** — `palette.view` 는 제목과 우측 텍스트의
/// 겹침을 안 보므로, 안 떼면 긴 체인이 줄 번호 위에 겹쳐 그려진다(§7.5).
fn symbolLabelCols(self: *AppSession) usize {
    _ = self;
    // 패널은 최대 60칸이고 프롬프트가 2칸이다. 줄 번호는 최대 7자리(1,000,000줄)로 잡고 여백 2칸을 둔다.
    return 60 - 2 - 7 - 2;
}

/// 지금 활성 편집기의 심볼로 피커 목록을 다시 만든다. **행은 값으로 굳는다**(§7.5 — 공유 버퍼의
/// 인덱스를 들지 않는다).
pub fn recomputeSymbolPicker(self: *AppSession) void {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) {
        self.symbol_picker_rows.clear(self.allocator);
        self.chrome_host.symbol_picker.setResultCount(0);
        return;
    }
    const doc = term.rt.editor_doc orelse {
        self.symbol_picker_rows.clear(self.allocator);
        self.chrome_host.symbol_picker.setResultCount(0);
        return;
    };
    const st = &term.rt.editor_syntax;
    const prov = if (st.provider) |*p| p else {
        self.symbol_picker_rows.clear(self.allocator);
        self.chrome_host.symbol_picker.setResultCount(0);
        return;
    };
    prov.symbols(self.allocator, &st.symbols);
    symbol_picker.filter(
        self.allocator,
        st.symbols.items,
        doc.file.content,
        self.chrome_host.symbol_picker.input.query.items,
        symbolLabelCols(self),
        self.symbol_picker_scope,
        &self.symbol_picker_rows,
    ) catch {
        self.symbol_picker_rows.clear(self.allocator);
    };
    self.chrome_host.symbol_picker.selected = 0; // 쿼리 변경 시 선택 맨 위(팔레트와 같은 규율)
    self.chrome_host.symbol_picker.setResultCount(self.symbol_picker_rows.rows.items.len);
}

/// 「없다」와 「아직 모른다」를 가른다(§7.5 저하 표).
pub const SymbolPickerReadiness = enum {
    /// 편집기가 아니다 — 열지 않는다.
    not_editor,
    /// 파싱이 예산에 걸려 있다 — **연다**(곧 채워진다).
    pending,
    /// grammar 없음·심볼 종류가 빈 언어 — 「이 파일에는 심볼이 없다」.
    none,
    ready,
};

pub fn symbolPickerReadiness(self: *AppSession) SymbolPickerReadiness {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return .not_editor;
    _ = term.rt.editor_doc orelse return .not_editor;
    const st = &term.rt.editor_syntax;
    // **pending 을 먼저 본다.** 그 동안은 트리가 없어 목록이 비는데, 그것을 「없다」로 부르면
    // 읽는 중인 파일에 거짓말한다(§7.5 — 두 상태가 같은 신호다).
    if (st.pending) return .pending;
    if (st.provider == null) return .none;
    if (self.symbol_picker_rows.rows.items.len == 0 and
        self.chrome_host.symbol_picker.input.query.items.len == 0) return .none;
    return .ready;
}

/// 피커를 연다/닫는다. **편집기가 아니거나 심볼이 없으면 열지 않고 알린다**(§7.5).
pub fn toggleSymbolPicker(self: *AppSession) void {
    if (self.chrome_host.symbol_picker.open) {
        self.chrome_host.symbol_picker.hide();
        self.metal_dirty = true;
        return;
    }
    self.dismissMessageOverlays(); // 단일-오버레이 불변식
    self.symbol_picker_scope = null; // 전체 범위
    self.chrome_host.symbol_picker.show();
    self.chrome_host.symbol_picker.prompt = ""; // 기본 프롬프트로 되돌린다
    recomputeSymbolPicker(self);
    switch (symbolPickerReadiness(self)) {
        .not_editor, .none => {
            self.chrome_host.symbol_picker.hide();
            self.showNoticeKey(.symbol_picker_empty);
        },
        .pending, .ready => {},
    }
    self.metal_dirty = true;
}

/// 고른 심볼로 간다. **닫고 나서 간다**(§7.5) — 이동이 포커스·스크롤을 움직이므로 오버레이가 떠
/// 있는 채로 하면 방금 간 자리를 피커가 덮는다. **일치가 없으면 닫기만 한다.**
pub fn acceptSymbolPicker(self: *AppSession) void {
    const rows = self.symbol_picker_rows.rows.items;
    const idx = self.chrome_host.symbol_picker.selected;
    const target: ?u32 = if (idx < rows.len) rows[idx].offset else null;
    self.chrome_host.symbol_picker.hide();
    if (target) |off| navigateTo(self, .{ .offset = off }) catch {};
    self.metal_dirty = true;
}

test "SP7 피커는 편집기에서만 열린다 — 터미널에는 문서가 없다 (§7.5)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 편집기이고 심볼이 있으면 열린다.
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn alpha() void {}\npub fn beta() void {}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    toggleSymbolPicker(fx.session);
    try testing.expect(fx.session.chrome_host.symbol_picker.open);
    try testing.expectEqual(@as(usize, 2), fx.session.symbol_picker_rows.rows.items.len);
    toggleSymbolPicker(fx.session); // 닫는다
    try testing.expect(!fx.session.chrome_host.symbol_picker.open);

    // 편집기가 아니면 안 열린다.
    fx.term.kind = .terminal;
    defer fx.term.kind = .editor;
    toggleSymbolPicker(fx.session);
    try testing.expect(!fx.session.chrome_host.symbol_picker.open);
}

test "SP8 「아직 모른다」와 「없다」를 가른다 — 읽는 중인 파일에 없다고 하지 않는다 (§7.5)" {
    // **문서를 쓰다가 잡은 구멍이다.** `symbols()` 는 트리가 없으면 빈 목록을 내므로 파싱 미완과
    // 심볼 없음이 **같은 신호**다. 그것을 뭉개면 읽는 중인 파일에 「심볼이 없다」고 거짓말한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 500) : (i += 1) _ = insertText(fx.session, fx.term, "pub fn f() void { const s = \"abc\"; _ = s; }\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;

    // ① 예산에 끊긴 상태 — **「아직 모른다」다.**
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    if (!fx.term.rt.editor_syntax.pending) return error.SkipZigTest; // 너무 빨라 못 끊었다
    try testing.expectEqual(SymbolPickerReadiness.pending, symbolPickerReadiness(fx.session));

    // 그리고 **열린다** — 아무 일도 안 일어나는 것이 가장 나쁘다.
    toggleSymbolPicker(fx.session);
    try testing.expect(fx.session.chrome_host.symbol_picker.open);

    // ② 다 파싱하면 목록이 찬다.
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    recomputeSymbolPicker(fx.session);
    try testing.expectEqual(SymbolPickerReadiness.ready, symbolPickerReadiness(fx.session));
    try testing.expect(fx.session.symbol_picker_rows.rows.items.len > 0);

    // ③ grammar 가 없으면 **「없다」다.**
    fx.session.chrome_host.symbol_picker.hide();
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = .{};
    recomputeSymbolPicker(fx.session);
    try testing.expectEqual(SymbolPickerReadiness.none, symbolPickerReadiness(fx.session));
    toggleSymbolPicker(fx.session);
    try testing.expect(!fx.session.chrome_host.symbol_picker.open); // 열지 않는다
}

test "SP9 고르면 닫고 나서 간다 — 오버레이가 방금 간 자리를 덮지 않는다 (§7.5)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn alpha() void {}\n\npub fn beta() void {\n    const x = 1;\n    _ = x;\n}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }

    toggleSymbolPicker(fx.session);
    try testing.expect(fx.session.chrome_host.symbol_picker.open);
    const rows = fx.session.symbol_picker_rows.rows.items;
    try testing.expect(rows.len >= 2);

    // 두 번째(beta)를 고른다.
    fx.session.chrome_host.symbol_picker.selected = 1;
    const want = rows[1].offset;
    acceptSymbolPicker(fx.session);

    // **닫혔다.**
    try testing.expect(!fx.session.chrome_host.symbol_picker.open);
    // **그리고 갔다** — §5.2 경로를 탔으므로 되돌아가기 스택도 쌓였다.
    try testing.expectEqual(@as(usize, want), (fx.term.rt.editor_selection orelse return error.NoSel).focus);
    try testing.expect(fx.session.editor_nav_back.items.len > 0);
}

test "SP10 일치가 없으면 Enter 는 닫기만 한다 — 안 고른 자리로 가지 않는다 (§7.5)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn alpha() void {}\npub fn beta() void {}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    toggleSymbolPicker(fx.session);

    // 아무것도 안 걸리는 쿼리.
    try fx.session.chrome_host.symbol_picker.input.query.appendSlice(allocator, "zzzznope");
    recomputeSymbolPicker(fx.session);
    try testing.expectEqual(@as(usize, 0), fx.session.symbol_picker_rows.rows.items.len);

    const before = (fx.term.rt.editor_selection orelse return error.NoSel).focus;
    acceptSymbolPicker(fx.session);
    try testing.expect(!fx.session.chrome_host.symbol_picker.open); // 닫혔고
    try testing.expectEqual(before, (fx.term.rt.editor_selection orelse return error.NoSel).focus); // 안 움직였다
    try testing.expectEqual(@as(usize, 0), fx.session.editor_nav_back.items.len); // 스택도 안 쌓였다
}

test "SP11 파싱이 끝나면 프레임이 목록을 채운다 — 검색어가 그대로여도 (§7.5)" {
    // **「아직 모른다」의 기제를 재는 자리다.** 파싱이 끝나는 순간 검색어는 그대로라 아무것도
    // 재필터를 촉발하지 않는다 — `resumeParse` 가 도는 자리가 그것을 맡는다. `SP8` 은
    // `recomputeSymbolPicker` 를 **손으로** 부르므로 그 배선을 안 탄다(뮤테이션에서 그 줄을 지워도
    // 안 죽었다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    var i: usize = 0;
    while (i < 500) : (i += 1) _ = insertText(fx.session, fx.term, "pub fn f() void { const s = \"abc\"; _ = s; }\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;

    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    if (!fx.term.rt.editor_syntax.pending) return error.SkipZigTest;

    toggleSymbolPicker(fx.session);
    try testing.expect(fx.session.chrome_host.symbol_picker.open);
    try testing.expectEqual(@as(usize, 0), fx.session.symbol_picker_rows.rows.items.len); // 아직 모른다

    // **프레임만 돌린다** — 재필터를 손으로 부르지 않는다.
    var frames: usize = 0;
    while (fx.term.rt.editor_syntax.pending and frames < 2000) : (frames += 1) {
        var d = appendPaneFrame(fx.session, fx.leaf_rect, fx.term) orelse return error.NoFrame;
        d.dl.deinit(allocator);
    }
    try testing.expect(!fx.term.rt.editor_syntax.pending);
    try testing.expect(frames > 0); // 실제로 나뉘었다

    // 목록이 **저절로** 찼다.
    try testing.expect(fx.session.symbol_picker_rows.rows.items.len > 0);
    try testing.expectEqual(fx.session.symbol_picker_rows.rows.items.len, fx.session.chrome_host.symbol_picker.result_count);
}

/// 체인 마디의 **열 범위**를 담을 버퍼(§7.5). 렌더가 채우고 클릭이 읽는다 — 프레임마다 재사용한다.
///
/// **여기 두는 이유**: 클릭이 읽는 값은 §4.1g 의 규율대로 **렌더가 굳힌 것**이어야 한다. 그리는 자리에서
/// 바로 채우므로 두 값이 갈릴 수 없다.
pub fn crumbSpanBuf(self: *AppSession, term: *Term, n: usize) []maru.cell_text.ColSpan {
    const buf = &term.rt.editor_crumb_spans;
    if (buf.items.len < n) {
        buf.resize(self.allocator, n) catch return &.{};
    }
    return buf.items[0..@min(n, buf.items.len)];
}

/// 창 좌표가 체인의 어느 마디 위인가 — 그 마디가 가리키는 **심볼 인덱스**를 돌려준다.
///
/// **모드 선택기 뒤에 본다**(§7.5). 두 대상이 같은 한 줄에 있고 체인이 왼쪽 전부를 차지하므로,
/// 순서를 뒤집으면 모드 글자 위 클릭이 체인으로 샌다.
///
/// **안 그려진 마디는 안 잡는다** — 빈 열 범위다(「보이는 것 = 클릭되는 것」).
pub fn crumbSegmentAt(self: *AppSession, term: *Term, band: maru.session.SplitRect, x_px: f64, y_px: f64) ?usize {
    if (self.cell_width_px == 0) return null;
    if (y_px < @as(f64, @floatFromInt(band.y)) or y_px >= @as(f64, @floatFromInt(band.y + band.h))) return null;
    const rel = x_px - @as(f64, @floatFromInt(band.x));
    if (rel < 0) return null;
    const col: u16 = @intFromFloat(rel / @as(f64, @floatFromInt(self.cell_width_px)));

    const spans = term.rt.editor_crumb_spans.items;
    const syms = term.rt.editor_syntax.crumb_syms.items;
    for (spans[0..@min(spans.len, syms.len)], 0..) |sp, i| {
        if (sp.start == sp.end) continue; // 안 그려진 마디
        if (col >= sp.start and col < sp.end) return syms[i];
    }
    return null;
}

/// 체인 마디를 눌렀을 때 — **그 심볼의 형제만** 담은 피커를 연다(§7.5).
///
/// **열린 뒤에는 피커와 같은 것이다** — 키·필터·확정(§5.2 이동)·닫는 순서가 전부 그쪽 계약이다.
pub fn openSiblingPicker(self: *AppSession, sym_idx: usize) void {
    self.dismissMessageOverlays();
    self.symbol_picker_scope = .{ .sibling_of = sym_idx };
    self.chrome_host.symbol_picker.show();
    // **범위를 프롬프트가 말한다**(§7.5) — 「형제」 같은 관계 이름이 아니라 **부모 이름**을 쓴다.
    // 사용자가 묻는 것은 「왜 이 목록만 나오나」이고, 그 답은 관계가 아니라 **어느 컨테이너 안인가**다.
    // 체인과 같은 구분자를 써서 breadcrumb 과 이어 읽힌다.
    setSiblingPrompt(self, sym_idx);
    recomputeSymbolPicker(self);
    switch (symbolPickerReadiness(self)) {
        .not_editor, .none => {
            self.chrome_host.symbol_picker.hide();
            self.symbol_picker_scope = null;
            self.showNoticeKey(.symbol_picker_empty);
        },
        .pending, .ready => {},
    }
    self.metal_dirty = true;
}

test "DFF1 비교 뷰 검색은 선택이 있는 열을 본다 — 없으면 왼쪽 (§5.1)" {
    // **열을 베껴 들면 안 된다.** `editor_diff_selection` 은 비교 내용이 다시 계산될 때 버려지는데
    // (옛 행 인덱스로 훑으면 죽는다), 베껴 두면 선택이 사라진 뒤에도 그 열을 계속 검색해
    // **화면은 왼쪽인데 결과는 오른쪽 것**이 된다. 그래서 매번 다시 묻는다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const left_rows = [_][]const u8{ "aa", "aa" };
    const right_rows = [_][]const u8{"aa aa aa"};
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &left_rows;
    fx.term.rt.editor_diff.?.right_texts = &right_rows;

    // **선택이 없으면 왼쪽이다** — 가로 스크롤의 「포인터가 없으면 왼쪽」과 같은 규칙.
    try testing.expectEqual(DiffSide.left, diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 2), findLines(fx.session, fx.term).len);

    // **오른쪽을 고르면 오른쪽을 본다.**
    fx.term.rt.editor_diff_selection = .{
        .side = .right,
        .sel = editor_selection.RowSelection.at(.{ .row = 0, .byte = 0 }),
    };
    try testing.expectEqual(DiffSide.right, diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 1), findLines(fx.session, fx.term).len);

    // **선택이 사라지면 왼쪽으로 돌아온다** — 베껴 들었다면 여기서 오른쪽에 머문다.
    fx.term.rt.editor_diff_selection = null;
    try testing.expectEqual(DiffSide.left, diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 2), findLines(fx.session, fx.term).len);
}

test "DFF8 명시로 고른 열은 셋이 함께 따라온다 — 줄 배열·강조·막대 마커 (§5.1)" {
    // **이 판정자가 겨냥하는 변이는 「호출자에서만 반영」이다.** 명시값을 `find.zig` 쪽에서 갈아
    // 끼우면 검색은 오른쪽을 세는데 강조와 막대 마커는 왼쪽에 그려진다 — 이 절이 「베껴 들기」에서
    // 막아 둔 **화면과 결과가 갈리는** 증상이 다른 원인으로 되돌아온다. 그래서 셋을 **한 자리에서**
    // 함께 묻는다(변이 D7·D8·D9 가 살아남았던 것도 같은 종류였다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const left_rows = [_][]const u8{ "aa", "aa" };
    const right_rows = [_][]const u8{"aa aa aa"};
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &left_rows;
    fx.term.rt.editor_diff.?.right_texts = &right_rows;

    // **폴백은 왼쪽을 가리킨다** — 선택이 없다. 명시값이 그것을 이겨야 한다.
    const marks: ?[]const []const chrome_editor.frame.Mark = &.{};
    const lines = [_]u32{ 1, 2, 3 };
    fx.session.chrome_host.find.diff_side = .right;

    try testing.expectEqual(DiffSide.right, diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 1), findLines(fx.session, fx.term).len); // 오른쪽 행 배열
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .right, marks) != null);
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .left, marks) == null);
    try testing.expectEqual(@as(usize, 3), diffMarkerLinesFor(fx.session, fx.term, .right, &lines).len);
    try testing.expectEqual(@as(usize, 0), diffMarkerLinesFor(fx.session, fx.term, .left, &lines).len);

    // **선택이 반대쪽에 있어도 명시값이 이긴다.** 「선택이 있는 열」이 이기면 사용자가 고른 열이
    // 포인터 한 번에 뒤집혀, 넘긴 것이 없던 일이 된다.
    fx.term.rt.editor_diff_selection = .{
        .side = .left,
        .sel = editor_selection.RowSelection.at(.{ .row = 0, .byte = 0 }),
    };
    try testing.expectEqual(DiffSide.right, diffSearchSide(fx.session, fx.term));
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .right, marks) != null);
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .left, marks) == null);

    // **명시값은 재계산으로 안 죽는다.** 선택은 죽지만(행 인덱스가 낡는다) 열 이름은 안 낡는다 —
    // 그래서 이 값을 드는 것은 이 절이 금지한 「베껴 들기」가 아니다.
    fx.term.rt.editor_diff_selection = null;
    try testing.expectEqual(DiffSide.right, diffSearchSide(fx.session, fx.term));

    // **놓으면 폴백으로 돌아온다** — 명시값이 없어졌는데도 남으면 그것이 곧 베껴 든 것이다.
    fx.session.chrome_host.find.diff_side = null;
    try testing.expectEqual(DiffSide.left, diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 2), findLines(fx.session, fx.term).len);
}

test "DFF7 마커 행은 축을 가려 옮긴다 — 비교면 그대로, 단일이면 보이는 줄로 (§4.1a)" {
    // **이 갈림이 프레임 조립 안에 묻혀 있으면 판정자가 못 지난다**(변이 M5 가 그 자리를
    // 뒤집어도 아무도 안 잡았다). 그래서 `markerRows` 로 떼어내고 여기서 두 축을 다 지난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "a\nb\nc\nd\n");

    var buf: [8]u32 = undefined;
    var cur: ?usize = null;
    const M = maru.session.editor.find.Match;

    // ⑴ **단일 편집기: 보이는 줄로 옮긴다.** 접힘이 없으면 같은 값이지만 그 경로를 지난다.
    const ms = [_]M{ .{ .line = 0, .start = 0, .len = 1 }, .{ .line = 2, .start = 0, .len = 1 } };
    try testing.expectEqual(@as(usize, 2), markerRows(fx.term, &ms, 1, &buf, &cur));
    try testing.expectEqual(@as(?usize, 1), cur);
    try testing.expectEqual(@as(u32, 2), buf[1]);

    // **문서 밖 줄은 빠진다** — 옮길 자리가 없다(목록이 편집보다 낡았다).
    cur = null;
    const oob = [_]M{.{ .line = 999, .start = 0, .len = 1 }};
    try testing.expectEqual(@as(usize, 0), markerRows(fx.term, &oob, 0, &buf, &cur));

    // ⑵ **비교 뷰: 그대로 쓴다.** 문서 축에 없는 행이 와도 마커에 든다 — 그 배열의 행이니까.
    const rows = [_][]const u8{ "x", "y", "z", "w", "v", "u" };
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &rows;
    fx.term.rt.editor_diff.?.right_texts = &rows;

    // **문서 축 밖의 행을 쓴다.** 문서 안에 있는 값이면 두 축이 같은 답을 내 옮겼는지 못 가른다
    // (첫 픽스처가 그랬다 — `line = 5` 는 8줄짜리 문서에도 있었다, 변이 M3 이 그것을 보였다).
    const outside: u32 = @intCast(fx.term.rt.editor_lines.len + 3);
    try testing.expect(visibleRowOfDocLine(fx.term, outside) == null); // 문서 축은 답하지 못한다
    cur = null;
    const dm = [_]M{ .{ .line = outside, .start = 0, .len = 1 }, .{ .line = 0, .start = 0, .len = 1 } };
    try testing.expectEqual(@as(usize, 2), markerRows(fx.term, &dm, 0, &buf, &cur));
    try testing.expectEqual(outside, buf[0]); // 옮기지 않았다 — 그대로 들어왔다
    try testing.expectEqual(@as(?usize, 0), cur);

    // **버퍼가 모자라면 거기서 멈춘다** — 넘겨 쓰면 남의 기억을 밟는다.
    var tiny: [1]u32 = undefined;
    cur = null;
    try testing.expectEqual(@as(usize, 1), markerRows(fx.term, &dm, 1, &tiny, &cur));
}

test "DFF5 막대 마커도 검색 중인 열에만 찍힌다 — 강조와 같은 판정 (§4.1a)" {
    // **양쪽에 찍으면 세지 않은 문서의 자리에 표시가 남는다.** 강조와 같은 거짓이고, 그래서
    // 판정도 같은 함수가 낸다 — 둘이 갈리면 「색은 왼쪽인데 막대 표시는 오른쪽」이 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const rows = [_][]const u8{"aa"};
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &rows;
    fx.term.rt.editor_diff.?.right_texts = &rows;

    const lines = [_]u32{ 0, 3, 7 };

    // 선택이 없으면 왼쪽이 검색 중이다.
    try testing.expectEqual(@as(usize, 3), diffMarkerLinesFor(fx.session, fx.term, .left, &lines).len);
    try testing.expectEqual(@as(usize, 0), diffMarkerLinesFor(fx.session, fx.term, .right, &lines).len);

    // 오른쪽을 고르면 뒤바뀐다.
    fx.term.rt.editor_diff_selection = .{
        .side = .right,
        .sel = editor_selection.RowSelection.at(.{ .row = 0, .byte = 0 }),
    };
    try testing.expectEqual(@as(usize, 0), diffMarkerLinesFor(fx.session, fx.term, .left, &lines).len);
    try testing.expectEqual(@as(usize, 3), diffMarkerLinesFor(fx.session, fx.term, .right, &lines).len);

    // **강조와 같은 열을 고른다** — 두 판정이 갈리면 색과 막대 표시가 다른 문서를 가리킨다.
    const marks: ?[]const []const chrome_editor.frame.Mark = &.{};
    const marked_right = diffSearchMarksFor(fx.session, fx.term, .right, marks) != null;
    const markers_right = diffMarkerLinesFor(fx.session, fx.term, .right, &lines).len > 0;
    try testing.expectEqual(marked_right, markers_right);
}

test "DFF6 비교 뷰 마커는 행을 옮기지 않는다 — 없는 축을 만들지 않는다 (§4.1a)" {
    // 단일 편집기의 매치는 **문서 줄**이라 「보이는 줄」로 옮겨야 하지만(접힘), 비교 뷰의 매치는
    // **이미 그 열의 정렬된 행**이다. `visibleRowOfDocLine` 을 태우면 접힘 목록이 없어 대개
    // `null` 이 되고, 그러면 마커가 통째로 사라진다(또는 엉뚱한 행으로 간다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // **단일 편집기에서는 옮긴다** — 접힘이 없으면 줄 인덱스와 같지만, 그 경로를 지난다는 것이
    // 중요하다(접으면 갈린다).
    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "a\nb\nc\n");
    try testing.expect(visibleRowOfDocLine(fx.term, 2) != null);

    // **비교 뷰에서는 그 함수가 답하지 못한다** — 그래서 태우면 안 된다.
    const rows = [_][]const u8{ "x", "y", "z", "w" };
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &rows;
    fx.term.rt.editor_diff.?.right_texts = &rows;
    try testing.expectEqual(@as(usize, 4), findLines(fx.session, fx.term).len);

    // **두 축이 다르다.** 검색은 4행 배열을 훑는데 문서 축은 그것과 길이가 다르다 —
    // `visibleRowOfDocLine` 은 **문서** 축의 함수라 이 배열의 행을 설명하지 못한다.
    try testing.expect(fx.term.rt.editor_lines.len != findLines(fx.session, fx.term).len);

    // **비교 뷰 마커는 매치의 `line` 을 그대로 쓴다** — 옮기면 없는 축이 하나 더 생긴다.
    // 문서 축에 없는 행(예: 배열 끝)이 와도 마커 목록에 그대로 들어야 한다.
    const lines = [_]u32{3};
    try testing.expectEqual(@as(usize, 1), diffMarkerLinesFor(fx.session, fx.term, .left, &lines).len);
    try testing.expectEqual(@as(u32, 3), diffMarkerLinesFor(fx.session, fx.term, .left, &lines)[0]);
}

test "DFF4 검색 강조는 검색 중인 열에만 간다 — 양쪽도 반대도 아니다 (§5.1)" {
    // **양쪽에 칠하면 카운터가 세지 않은 자리에 색이 남는다** — Enter 가 어디로 갈지 화면이
    // 거짓말한다. 반대 열에 칠하면 더 나쁘다: 세는 열과 보이는 열이 통째로 어긋난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    const rows = [_][]const u8{"aa"};
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = &rows;
    fx.term.rt.editor_diff.?.right_texts = &rows;

    const marks: ?[]const []const chrome_editor.frame.Mark = &.{};

    // 선택이 없으면 왼쪽이 검색 중이다 — 왼쪽만 받는다.
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .left, marks) != null);
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .right, marks) == null);

    // 오른쪽을 고르면 뒤바뀐다.
    fx.term.rt.editor_diff_selection = .{
        .side = .right,
        .sel = editor_selection.RowSelection.at(.{ .row = 0, .byte = 0 }),
    };
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .left, marks) == null);
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .right, marks) != null);

    // **현재 매치 표시도 같은 규칙이다** — 강조만 맞고 현재 표시가 양쪽이면 두 자리가 진해진다.
    const cur: ?chrome_editor.frame.CurrentMatch = .{ .line = 0, .start = 0 };
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .left, cur) == null);
    try testing.expect(diffSearchMarksFor(fx.session, fx.term, .right, cur) != null);
}

test "DFF3 비교 뷰에서는 「선택 영역 내에서만」이 안 켜진다 (§5.1)" {
    // 그 토글은 **문서 offset 축**을 전제하는데(`matchRange`), 비교 뷰의 매치는 정렬된 행 배열
    // 축이라 그 변환이 성립하지 않는다 — 켜 두면 거르기가 **엉뚱한 수**를 낸다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "aa aa aa\n");
    fx.term.rt.editor_selection = editor_selection.Selection.fromPoints(0, 5);

    // 단일 편집기에서는 켜진다.
    fx.session.chrome_host.find.show();
    fx.session.chrome_host.find.target = .editor;
    fx.session.find_selection_at_open = .{ .start = 0, .end = 5 };
    find_ops.toggleFindInSelection(fx.session);
    try testing.expect(fx.session.chrome_host.find.in_selection != null);

    // **비교 뷰가 되면 안 켜진다.**
    find_ops.toggleFindInSelection(fx.session); // 먼저 끈다
    try testing.expect(fx.session.chrome_host.find.in_selection == null);
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    const rows = [_][]const u8{"aa aa aa"};
    fx.term.rt.editor_diff.?.left_texts = &rows;
    fx.term.rt.editor_diff.?.right_texts = &rows;
    fx.session.find_selection_at_open = .{ .start = 0, .end = 5 };
    find_ops.toggleFindInSelection(fx.session);
    try testing.expect(fx.session.chrome_host.find.in_selection == null);
}

test "DFF2 비교가 아닌 문서는 문서 줄을 본다 — 축이 안 섞인다 (§5.1)" {
    // `findLines` 가 두 축을 하나로 답하므로, 비교가 아닐 때 엉뚱한 배열을 주면 검색이 통째로 어긋난다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "one\ntwo\nthree\n");
    try testing.expectEqual(fx.term.rt.editor_lines.len, findLines(fx.session, fx.term).len);
    try testing.expect(fx.term.rt.editor_diff == null);

    // **비교인데 compare 뷰가 아니면 검색할 것이 없다**(읽는 중·거절 등) — 문서 줄로 새면 안 된다.
    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    defer fx.term.rt.editor_diff = null;
    try testing.expectEqual(@as(usize, 0), findLines(fx.session, fx.term).len);

    // **빈 열은 검색 대상이 아니다.** 그대로 두면 `findMatches` 가 빈 배열을 훑어 매치 0 을 내는데,
    // 그것은 「없다」가 아니라 「아직 안 열렸다」다 — 두 상태를 같은 화면으로 답하면 안 된다.
    try testing.expect(!find_ops.activeTermIsEditor(fx.session));
}

test "SP17 체인 마디의 열 범위를 렌더가 굳힌다 — 클릭이 그것을 읽는다 (§7.5)" {
    // §4.1g 의 규율: **클릭 시점에 다시 계산하지 않는다.** 밴드는 폭·생략이 프레임마다 달라질 수
    // 있어 같은 함정이 있다 — 그래서 그리는 자리에서 굳히고 여기서는 읽기만 한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const Widget = struct {\n    pub fn draw() void {\n        var x: u8 = 0;\n        _ = x;\n    }\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    const inside = std.mem.indexOf(u8, doc.file.content, "var x").?;
    fx.term.rt.editor_selection = editor_selection.Selection.at(inside);

    // 체인이 두 마디다 — `Widget › draw`.
    const label = headerBreadcrumb(fx.session, fx.term, "a.zig");
    try testing.expect(std.mem.indexOf(u8, label, "Widget") != null);
    const bounds = fx.term.rt.editor_syntax.crumb_bounds.items;
    try testing.expectEqual(@as(usize, 3), bounds.len); // 마디 둘 → 경계 셋
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_syntax.crumb_syms.items.len);

    // **경계가 실제 이름 자리다** — 그 구간을 잘라 보면 심볼 이름이다.
    try testing.expectEqualStrings("Widget", label[bounds[0]..(bounds[1] - syntax_color.chain_separator.len)]);
    try testing.expectEqualStrings("draw", label[bounds[1]..bounds[2]]);
}

test "SP18 안 그려진 마디는 클릭 대상이 아니다 — 보이는 것 = 클릭되는 것 (§7.5)" {
    // 빈 열 범위는 잡히면 안 된다. 그러지 않으면 **화면에 없는 것을 눌러** 엉뚱한 목록이 뜬다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    // 열 범위를 손으로 심는다 — 하나는 그려졌고(5..10) 하나는 안 그려졌다(0..0).
    try fx.term.rt.editor_crumb_spans.resize(allocator, 2);
    fx.term.rt.editor_crumb_spans.items[0] = .{ .start = 0, .end = 0 };
    fx.term.rt.editor_crumb_spans.items[1] = .{ .start = 5, .end = 10 };
    try fx.term.rt.editor_syntax.crumb_syms.resize(allocator, 2);
    fx.term.rt.editor_syntax.crumb_syms.items[0] = 7;
    fx.term.rt.editor_syntax.crumb_syms.items[1] = 9;

    // **밴드 원점을 0 이 아니게 둔다.** 사이드바가 있으면 밴드는 화면 왼쪽에 안 붙는데, `x = 0` 으로
    // 재면 가로 원점을 빼는지 안 빼는지 **구별되지 않는다**(뮤테이션에서 그 뺄셈을 지웠는데 안 죽었다).
    const band: maru.session.SplitRect = .{ .x = 300, .y = 40, .w = 800, .h = 20 };
    const cw: f64 = @floatFromInt(@max(fx.session.cell_width_px, 1));

    const bx: f64 = @floatFromInt(band.x);
    const by: f64 = @floatFromInt(band.y);

    // 그려진 마디 안 — 그 심볼이 나온다(**밴드 원점을 더한 창 좌표**로 준다).
    try testing.expectEqual(@as(?usize, 9), crumbSegmentAt(fx.session, fx.term, band, bx + 6 * cw + 1, by + 5));
    // 그려진 범위 밖 — 없다.
    try testing.expectEqual(@as(?usize, null), crumbSegmentAt(fx.session, fx.term, band, bx + 12 * cw + 1, by + 5));
    // **빈 범위(0..0)는 어떤 좌표로도 안 잡힌다.**
    try testing.expectEqual(@as(?usize, null), crumbSegmentAt(fx.session, fx.term, band, bx, by + 5));
    // **밴드 왼쪽 바깥** — 원점을 안 빼면 여기가 마디 안으로 잘못 잡힌다.
    try testing.expectEqual(@as(?usize, null), crumbSegmentAt(fx.session, fx.term, band, 6 * cw + 1, by + 5));
    // 밴드 밖 세로.
    try testing.expectEqual(@as(?usize, null), crumbSegmentAt(fx.session, fx.term, band, bx + 6 * cw + 1, by + 50));
}

test "SP19 체인 마디를 누르면 형제 목록이 뜬다 — 전체가 아니다 (§7.5)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const A = struct {\n    pub fn a1() void {}\n    pub fn a2() void {}\n};\npub const B = struct {\n    pub fn b1() void {}\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }

    // 전체 범위로 열면 다섯(A·a1·a2·B·b1).
    toggleSymbolPicker(fx.session);
    const all_n = fx.session.symbol_picker_rows.rows.items.len;
    try testing.expect(all_n >= 5);
    toggleSymbolPicker(fx.session);

    // `a1` 을 가리키는 마디를 누른 셈 치고 연다.
    const st = &fx.term.rt.editor_syntax;
    var a1: ?usize = null;
    for (st.symbols.items, 0..) |s, i| {
        if (std.mem.eql(u8, doc.file.content[s.name_start..s.name_end], "a1")) a1 = i;
    }
    const target = a1 orelse return error.SkipZigTest;
    openSiblingPicker(fx.session, target);

    try testing.expect(fx.session.chrome_host.symbol_picker.open);
    // **A 의 자식 둘만** — 전체보다 적다.
    try testing.expectEqual(@as(usize, 2), fx.session.symbol_picker_rows.rows.items.len);
    try testing.expect(fx.session.symbol_picker_rows.rows.items.len < all_n);

    // 닫고 전체로 열면 범위가 풀린다.
    fx.session.chrome_host.symbol_picker.hide();
    toggleSymbolPicker(fx.session);
    try testing.expectEqual(@as(?symbol_picker.Scope, null), fx.session.symbol_picker_scope);
    try testing.expectEqual(all_n, fx.session.symbol_picker_rows.rows.items.len);
}

test "SP20 프롬프트가 부모 이름을 말한다 — 관계가 아니라 범위다 (§7.5)" {
    // 목록만 보면 「필터로 좁혀진 것」과 「범위가 한정된 것」이 같아 보인다. 사용자가 묻는 것은
    // 「왜 이 목록만 나오나」이고, 그 답은 **어느 컨테이너 안인가**다 — 「형제」 같은 관계 이름은
    // 그 질문에 답하지 않는다(사용자 지적, 2026-08-31).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    // **`Outer` 를 0번이 아닌 자리에 둔다.** 부모가 목록의 첫 심볼이면 「부모를 찾았다」와
    // 「목록의 처음까지 갔다」가 같은 자리라 구별되지 않는다.
    _ = insertText(fx.session, fx.term, "pub fn head() void {}\npub const Outer = struct {\n    pub fn a1() void {}\n    pub fn a2() void {}\n};\npub fn top() void {}\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }

    // 전체 — 기본 프롬프트다.
    toggleSymbolPicker(fx.session);
    try testing.expectEqualStrings("> ", fx.session.chrome_host.symbol_picker.promptText());
    toggleSymbolPicker(fx.session);

    recomputeSymbolPicker(fx.session);
    var a1: ?usize = null;
    var a2: ?usize = null;
    var top_idx: ?usize = null;
    for (fx.term.rt.editor_syntax.symbols.items, 0..) |sy, i| {
        const nm = doc.file.content[sy.name_start..sy.name_end];
        if (std.mem.eql(u8, nm, "a1")) a1 = i;
        if (std.mem.eql(u8, nm, "a2")) a2 = i;
        if (std.mem.eql(u8, nm, "top")) top_idx = i;
    }

    // **부모가 있으면 그 이름이다** — `Outer ›`.
    openSiblingPicker(fx.session, a1 orelse return error.SkipZigTest);
    try testing.expectEqualStrings("Outer \u{203A} ", fx.session.chrome_host.symbol_picker.promptText());
    fx.session.chrome_host.symbol_picker.hide();

    // **앞에 형제가 있어도 부모다.** `a1` 만 보면 「바로 앞 심볼」과 「부모」가 같은 자리라
    // 둘이 구별되지 않는다 — `a2` 의 바로 앞은 형제 `a1` 이고, 그 이름이 뜨면 틀린 것이다.
    openSiblingPicker(fx.session, a2 orelse return error.SkipZigTest);
    try testing.expectEqualStrings("Outer \u{203A} ", fx.session.chrome_host.symbol_picker.promptText());
    fx.session.chrome_host.symbol_picker.hide();

    // **최상위면 부모가 없다** — 그 사실을 말한다(관계 이름이 아니라).
    openSiblingPicker(fx.session, top_idx orelse return error.SkipZigTest);
    const top_prompt = fx.session.chrome_host.symbol_picker.promptText();
    try testing.expect(std.mem.endsWith(u8, top_prompt, syntax_color.chain_separator));
    // **`indexOf` 로는 모자라다** — 앞선 프롬프트가 안 지워지고 남아도 「들어 있기는」 하다.
    // 프롬프트는 **덮어쓰는 것**이지 쌓는 것이 아니므로 첫 글자부터 대조한다.
    try testing.expect(std.mem.startsWith(u8, top_prompt, maru.i18n.t(.symbol_picker_top_level)));

    // **다시 전체로 열면 되돌아온다** — 안 되돌리면 그 뒤로 늘 그 범위라고 거짓말한다.
    fx.session.chrome_host.symbol_picker.hide();
    toggleSymbolPicker(fx.session);
    try testing.expectEqualStrings("> ", fx.session.chrome_host.symbol_picker.promptText());
}

test "SP24 심볼 목록이 문서보다 낡아도 프롬프트가 문서 밖을 안 읽는다 (§7.5)" {
    // 밴드에 굳은 체인을 **누르는 사이** 문서가 바뀔 수 있다(§4.1g — 굳힌 것을 읽는 대가다).
    // 그러면 심볼의 이름 범위가 줄어든 문서 밖을 가리키고, 그 슬라이스를 그대로 뜨면 읽기가
    // 문서를 넘어간다. 「이름을 모른다」로 떨어져야지 넘어가면 안 된다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const Outer = struct {\n    pub fn a1() void {}\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    recomputeSymbolPicker(fx.session);

    var a1: ?usize = null;
    for (fx.term.rt.editor_syntax.symbols.items, 0..) |sy, i| {
        if (std.mem.eql(u8, doc.file.content[sy.name_start..sy.name_end], "a1")) a1 = i;
    }
    const target = a1 orelse return error.SkipZigTest;

    // **목록은 그대로 두고 문서만 줄인다** — 다시 파싱하기 전의 그 한 프레임이다.
    const st = &fx.term.rt.editor_syntax;
    const parent = blk: {
        var j = target;
        while (j > 0) {
            j -= 1;
            if (st.symbols.items[j].depth < st.symbols.items[target].depth) break :blk j;
        }
        return error.SkipZigTest; // 부모가 없으면 이 판정자가 볼 것이 없다
    };
    try testing.expect(st.symbols.items[parent].name_end <= doc.file.content.len); // 지금은 안쪽이다
    const shrunk = st.symbols.items[parent].name_start; // 부모 이름 **직전**까지만 남긴다
    const live = &fx.term.rt.editor_doc.?;
    const whole = live.file.content;
    live.file.content = whole[0..shrunk];

    // 넘어가지 않고 「부모를 모른다」로 떨어진다 — 최상위와 같은 문구다.
    openSiblingPicker(fx.session, target);
    const prompt = fx.session.chrome_host.symbol_picker.promptText();
    live.file.content = whole; // 해제는 원래 길이로 해야 한다 — 줄인 채 두면 teardown 이 거짓말한다
    try testing.expect(std.mem.startsWith(u8, prompt, maru.i18n.t(.symbol_picker_top_level)));
    try testing.expect(std.mem.endsWith(u8, prompt, syntax_color.chain_separator));
}

test "SP21 형제 피커도 단일-오버레이 불변식을 지킨다 — 남의 오버레이를 닫는다 (§7.5)" {
    // 밴드 클릭으로 여는 경로라 **다른 오버레이가 떠 있는 채로** 불릴 수 있다. 안 닫으면 둘이 한
    // 오버레이 그리드에 겹쳐 raster 되어 글자가 포개진다(`dismissMessageOverlays` 머리말이 그
    // 사고를 적어 뒀다). 뮤테이션에서 그 호출을 지웠는데 아무 판정자도 안 죽었다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const A = struct {\n    pub fn a1() void {}\n    pub fn a2() void {}\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }

    // **심볼 목록을 먼저 채운다** — `State.symbols` 는 `recomputeSymbolPicker`·`breadcrumb` 이 채우는
    // 파생값이라, 파싱만 끝냈다고 차 있지 않다(처음에 그것을 빠뜨려 판정자가 SKIP 으로 조용히 넘어갔다).
    recomputeSymbolPicker(fx.session);
    var a1: ?usize = null;
    for (fx.term.rt.editor_syntax.symbols.items, 0..) |s, i| {
        if (std.mem.eql(u8, doc.file.content[s.name_start..s.name_end], "a1")) a1 = i;
    }
    const target = a1 orelse return error.SkipZigTest;

    // **다른 오버레이를 먼저 띄운다.**
    fx.session.chrome_host.palette.show();
    try testing.expect(fx.session.chrome_host.palette.open);

    openSiblingPicker(fx.session, target);

    // 형제 피커가 떴고, **명령 팔레트는 닫혔다**.
    try testing.expect(fx.session.chrome_host.symbol_picker.open);
    try testing.expect(!fx.session.chrome_host.palette.open);
}

test "SP22 누른 마디가 가리키는 심볼이 화면의 그 이름이다 — 하나 밀리면 남의 형제가 뜬다 (§7.5)" {
    // `crumb_syms[i]` 는 **i 번째 마디가 어느 심볼인가**다. 하나만 밀려도 클릭이 **엉뚱한 심볼**의
    // 형제를 열고, 목록이 그럴듯해서 **틀린 줄 모른다**(뮤테이션에서 `si +| 1` 로 담았는데 아무
    // 판정자도 안 죽었다). 그래서 마디 글자와 그 심볼 이름을 **직접 대조**한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub const Widget = struct {\n    pub fn draw() void {\n        var x: u8 = 0;\n        _ = x;\n    }\n};\n");
    const doc = fx.term.rt.editor_doc orelse return error.NoDoc;
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = syntax_color.open(doc.file.content, .zig);
    var rounds: usize = 0;
    while (fx.term.rt.editor_syntax.pending and rounds < 100_000) : (rounds += 1) {
        _ = syntax_color.resumeParse(&fx.term.rt.editor_syntax, doc.file.content);
    }
    const inside = std.mem.indexOf(u8, doc.file.content, "var x").?;
    fx.term.rt.editor_selection = editor_selection.Selection.at(inside);

    const label = headerBreadcrumb(fx.session, fx.term, "a.zig");
    const st = &fx.term.rt.editor_syntax;
    const bounds = st.crumb_bounds.items;
    const syms = st.crumb_syms.items;
    try testing.expectEqual(syms.len + 1, bounds.len);
    try testing.expect(syms.len >= 2);

    // **마디 i 의 글자 == 그 심볼의 이름**이어야 한다.
    for (syms, 0..) |sym_idx, i| {
        try testing.expect(sym_idx < st.symbols.items.len);
        const sym = st.symbols.items[sym_idx];
        const name = doc.file.content[sym.name_start..sym.name_end];
        // 마디 구간에서 뒤따르는 구분자를 뺀다(마지막 마디는 구분자가 없다).
        var seg = label[bounds[i]..bounds[i + 1]];
        if (i + 1 < syms.len) seg = seg[0 .. seg.len - syntax_color.chain_separator.len];
        try testing.expectEqualStrings(name, seg);
    }
}

test "SP23 형제 피커도 「없다」면 열지 않는다 — 빈 목록을 띄우지 않는다 (§7.5)" {
    // 전체 피커와 **같은 판정**을 쓴다는 계약이다. 안 보면 grammar 없는 문서에서 **빈 오버레이**가
    // 뜬다(뮤테이션에서 그 갈래의 `hide()` 를 지웠는데 아무 판정자도 안 죽었다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);

    fx.term.rt.editor_selection = editor_selection.Selection.at(0);
    _ = insertText(fx.session, fx.term, "pub fn a() void {}\n");

    // **provider 를 없앤다** — grammar 없는 문서와 같은 상태다.
    fx.term.rt.editor_syntax.deinit(allocator);
    fx.term.rt.editor_syntax = .{};
    recomputeSymbolPicker(fx.session);
    try testing.expectEqual(SymbolPickerReadiness.none, symbolPickerReadiness(fx.session));

    openSiblingPicker(fx.session, 0);
    try testing.expect(!fx.session.chrome_host.symbol_picker.open); // 안 열린다
    try testing.expectEqual(@as(?symbol_picker.Scope, null), fx.session.symbol_picker_scope); // 범위도 풀린다
}

/// 형제 목록의 프롬프트를 **부모 이름**으로 세운다(§7.5). 부모가 없으면(최상위) 그 사실을 말한다.
///
/// **버퍼를 들고 있는 이유**는 부모 이름이 문서 내용을 빌리는 슬라이스라, 문서가 바뀌면 매달리기
/// 때문이다 — 심볼 피커의 행이 라벨을 사본으로 드는 것과 같은 규율이다.
fn setSiblingPrompt(self: *AppSession, sym_idx: usize) void {
    const term = pane_ops.activePane(self).activeTerm();
    const st = &term.rt.editor_syntax;
    const buf = &self.symbol_picker_prompt;
    buf.clearRetainingCapacity();

    const parent_name: ?[]const u8 = blk: {
        const doc = term.rt.editor_doc orelse break :blk null;
        if (sym_idx >= st.symbols.items.len) break :blk null;
        const d = st.symbols.items[sym_idx].depth;
        // **부모는 「바로 앞의 더 얕은 심볼」이다** — 목록이 문서 순서라 그렇다(§7.5 심볼 목록 층).
        // `<` 이지 `<=` 가 아니다: 같은 깊이의 앞 심볼은 **형제**고, 그것을 이름으로 쓰면
        // 「어느 컨테이너 안인가」에 형제 이름으로 답하는 거짓말이 된다.
        // 최상위(`d == 0`)는 `p.depth < 0` 이 없으므로 이 순회가 그대로 null 을 낸다 —
        // 따로 앞질러 막지 않는다(막아 봐야 뜻이 같아 판정자가 그 줄을 못 지킨다).
        var j = sym_idx;
        while (j > 0) {
            j -= 1;
            const p = st.symbols.items[j];
            if (p.depth < d) {
                // 심볼 목록이 문서보다 **낡았을 수 있다** — 굳힌 체인을 누르는 사이 문서가
                // 바뀌면 이름 범위가 문서 밖을 가리킨다. 그때는 이름이 없는 것으로 친다.
                if (p.name_end > doc.file.content.len or p.name_start >= p.name_end) break :blk null;
                break :blk doc.file.content[p.name_start..p.name_end];
            }
        }
        break :blk null;
    };

    const name = parent_name orelse maru.i18n.t(.symbol_picker_top_level);
    buf.appendSlice(self.allocator, name) catch {
        self.chrome_host.symbol_picker.prompt = "";
        return;
    };
    buf.appendSlice(self.allocator, syntax_color.chain_separator) catch {
        self.chrome_host.symbol_picker.prompt = "";
        return;
    };
    self.chrome_host.symbol_picker.prompt = buf.items;
}
