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
const Term = app_session_mod.Term;
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");
const term_ops = @import("term.zig");
const scroll_ops = @import("scroll.zig");
const editor_diff_ops = @import("editor_diff.zig");
const workspace_ops = @import("workspace.zig");
const chrome = maru.chrome;
const chrome_draw = maru.chrome.draw;
const editor_fold = maru.session.editor.fold;
const chrome_editor = maru.chrome.components.editor_view;
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
/// **숫자는 잠정이다.** §10이 "선행 측정 게이트는 없다"고 했으므로 여기서도 근거 없는 값을 계약처럼
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

pub const Opened = struct {
    /// 할당한 버퍼 **전체**. 문서는 그 앞부분(실제로 읽은 만큼)을 빌려 쓰므로 문서보다 오래 살아야
    /// 한다. 파일이 `stat`과 read 사이에 줄어들면 뒤에 안 쓰는 꼬리가 남는데, `free`가 원래 크기를
    /// 요구하므로 잘라 들 수 없다 — **파일 내용으로 쓰지 말 것**(문서를 통해 읽어야 한다).
    bytes: []u8,
    file: editor.open.OpenFile,

    pub fn deinit(self: *Opened, allocator: std.mem.Allocator) void {
        self.file.deinit();
        allocator.free(self.bytes);
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
    errdefer allocator.free(buf);
    // **짧게 읽히면 그만큼만 문서가 된다.** `readPositionalAll`은 EOF에서 조용히 멈추므로(`amt == 0`
    // 이면 break) 파일이 `stat`과 여기 사이에 줄어들면 `n < size`가 되고, 우리는 그 시점의 실제
    // 내용을 여는 셈이라 화면은 거짓을 보이지 않는다.
    //
    // **저장이 붙으면 달라진다(N2).** 잘린 버퍼를 원문으로 알고 되쓰면 파일이 그만큼 잘린다 —
    // 그때는 `n != size`를 에러로 올리거나 다시 읽어야 한다. 읽기 전용인 지금은 그 판정을 만들지
    // 않는다(없는 계약을 여기서 지어내지 않는다).
    const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;

    const opened = editor.open.open(allocator, buf[0..n], !isWritable(path)) catch |e| switch (e) {
        error.NotUtf8 => return error.NotUtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .bytes = buf, .file = opened };
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
    /// **문서 전체**의 시각 행 수(랩 포함). 렌더만 접힘을 아므로, 스크롤 입력이 쓰도록 함께 낸다.
    total_visual_rows: u32,
    /// 스크롤 **상한** `(줄, 조각)` — 같은 이유로 함께 낸다(§4.1d).
    max_top_line: usize,
    max_top_piece: u32,
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
    wrap: bool,
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
        .{ .lines = lines, .first_col = first_col, .numbers = numbers, .total_lines = total_lines, .folds = folds, .content_max_cols = content_max_cols },
        .{ .first_line = first_line, .first_piece = first_piece, .wrap = wrap, .cell_w_px = cell_w_px, .cell_h_px = cell_h_px, .font_px = font_px },
        inner,
        // **배경만 뒤로 물린다.** 내용 op이 (0,0)에서 시작해야 셀 격자 양자화(`buildTextDrawList`가
        // px→셀로 바꾼다)에 여백이 먹히지 않는다 — 여백은 호출자가 **pane 원점**에 걸고, 배경은
        // 그만큼 음수로 밀어 뷰 사각 전체를 덮는다(§4.1b).
        .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        scratch,
    );
    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows, .total_visual_rows = w.total_visual_rows, .max_top_line = w.max_top_line, .max_top_piece = w.max_top_piece };
}

/// **좌우 두 열**을 한 ops 배열에 그린다(N1.5 c). 조합은 컴포넌트가 소유하고(`diff_frame.build`),
/// 여기서는 pane 여백만 반영한다 — Chrome Lab이 같은 함수를 불러 캡처가 제품을 예고한다.
pub fn buildDiffPaneOps(
    left: chrome_editor.diff_frame.Side,
    right: chrome_editor.diff_frame.Side,
    first_line: usize,
    first_piece: u32,
    wrap: bool,
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
        .rect = inner,
        .background_rect = .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .font_px = font_px,
    }, scratch);
    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows, .total_visual_rows = w.total_visual_rows, .max_top_line = w.max_top_line, .max_top_piece = w.max_top_piece };
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
    // **hit-test는 아직 이 사각을 소비하지 않는다.** N1은 읽기 전용이라 편집기 pane에 포인터·IME
    // 경로가 없다. 그것이 붙을 때(N2~) 그쪽도 같은 `body`를 읽어야 "보이는 자리"와 "누르는 자리"가
    // 갈리지 않는다 — 터미널이 `grid`를 쓰는 것과 달라지는 지점이므로 그때 함께 정한다.
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
    };

    const pane_rect: chrome_draw.Rect = .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
    const pf = if (diff_state_opt) |st| blk: {
        // **상태 줄은 가로로 안 민다** — 한 줄짜리 문구라 밀면 화면에서 사라진다.
        if (st.view != .compare) break :blk buildPaneOps(lines, null, null, lines.len, term.rt.editor_first_line, 0, 0, null, wrap, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
        // **좌우가 세로를 공유한다**(§3.5) — 행 배열이 이미 같은 길이라 같은 인덱스가 같은 높이다.
        // 가로는 각자다(§3.5의 그 규칙은 CM6가 "양쪽 줄 길이가 달라 한쪽을 따라가면 다른 쪽이
        // 엉뚱한 곳을 본다"고 적어 둔 근거에서 왔다) — 입력이 붙을 때 열별 `first_col`이 여기 온다.
        break :blk buildDiffPaneOps(
            .{ .lines = st.left_texts, .numbers = st.left_numbers, .total_lines = st.left_lines.len, .bands = st.left_bands, .marks = st.left_marks, .first_col = effectiveFirstCol(wrap, term, false) },
            .{ .lines = st.right_texts, .numbers = st.right_numbers, .total_lines = st.right_lines.len, .bands = st.right_bands, .marks = st.right_marks, .first_col = effectiveFirstCol(wrap, term, true) },
            term.rt.editor_first_line,
            effectiveFirstPiece(wrap, term),
            wrap,
            pane_rect,
            @intCast(self.cell_width_px),
            @intCast(self.cell_height_px),
            @intCast(self.cell_height_px),
            scratch,
        );
    } else buildPaneOps(lines, foldNumbers(term), foldMarks(term), term.rt.editor_lines.len, term.rt.editor_first_line, effectiveFirstPiece(wrap, term), effectiveFirstCol(wrap, term, false), maxColsForRender(term), wrap, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
    if (pf.ops_len == 0) return null;
    // 스크롤 입력이 읽을 값을 여기서 싣는다 — 접힘을 아는 것은 렌더뿐이다.
    term.rt.editor_total_visual_rows = pf.total_visual_rows;
    // **스크롤 상한도 렌더만 안다**(§4.1d) — 입력이 이것을 읽어 clamp한다.
    term.rt.editor_max_top_line = pf.max_top_line;
    term.rt.editor_max_top_piece = pf.max_top_piece;

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

/// 경로를 열어 **활성 pane에 편집기 Term으로 붙인다**. N1의 "화면에 파일이 뜬다"가 여기서 닫힌다.
///
/// 실패는 호출자가 사용자에게 알린다 — §3.5가 "여는 것을 막는 이유는 UTF-8 아님 하나"라고 정했으므로
/// 나머지 이유를 같은 메시지로 뭉개면 그 계약을 확인할 수 없다.
pub fn openPathInActivePane(self: *AppSession, path: []const u8) OpenFileError!*Term {
    var opened = try openPath(self.io, self.allocator, path);
    errdefer opened.deinit(self.allocator);

    // **줄 슬라이스를 미리 만든다.** `frame.build`는 문서 전체를 받아야 스크롤바 길이가 맞는데(§4.1a),
    // 매 프레임 다시 만들면 프레임마다 할당이 생긴다. 줄들은 문서 버퍼를 빌리므로 문서보다 오래 살면 안 된다.
    const n = opened.file.lineCount();
    const lines = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
    errdefer self.allocator.free(lines);
    for (0..n) |i| lines[i] = opened.file.lineText(i) orelse "";

    const term = createEditorTerm(self) catch return error.OutOfMemory;
    errdefer term_ops.destroyTerm(self, term);

    // **실패할 수 있는 일을 먼저 끝내고, 넘기는 것은 마지막에 한꺼번에 한다.**
    //
    // 예전에는 `term.rt`에 먼저 넘긴 뒤 경로 복사와 pane 등록을 했다. 그 둘이 실패하면 위
    // `errdefer term_ops.destroyTerm`이 doc·lines를 풀고, 그 아래 `errdefer opened.deinit`과
    // `errdefer free(lines)`가 **같은 것을 또 푼다** — 이중 해제다. 같은 모양을 `materialize`와
    // `computeMarks`에서 이미 두 번 잡았고(할당 실패 주입), 이 자리가 세 번째다.
    //
    // 넘긴 뒤에는 실패 지점이 없으므로 errdefer가 겹칠 여지 자체가 사라진다.
    const path_copy = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
    errdefer self.allocator.free(path_copy);

    const pane = pane_ops.activePane(self);
    pane.terms.append(self.allocator, term) catch return error.OutOfMemory;

    term.rt.editor_doc = opened;
    term.rt.editor_lines = lines;
    term.rt.editor_path = path_copy;

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
        chrome_editor.frame.default_tab_width,
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
fn maxColsForRender(term: *Term) ?u32 {
    const v = term.rt.editor_max_cols;
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
fn ensureMaxCols(term: *Term, right: bool) void {
    const cache = if (right) &term.rt.editor_max_cols_right else &term.rt.editor_max_cols;
    if (cache.* != 0) return;
    const lines = if (right) rightTexts(term) else editorLines(term);
    if (lines.len == 0) return;

    const tab_width = chrome_editor.frame.default_tab_width; // 렌더가 쓰는 그 값(단일 출처)
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

    const tab_width = chrome_editor.frame.default_tab_width;
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

/// 접을 수 있는 것을 **전부 접는다**(§4 — *"큰 파일에서 하나씩 접는 것은 쓸모가 없다"*).
/// 편집기가 아니거나 접을 것이 없으면 `false`.
pub fn foldAll(self: *AppSession) bool {
    return applyFold(self, null);
}

/// **그 중첩 레벨의 블록만 접는다**(VSCode `editor.foldLevelN`). 레벨 1이 문서 맨 바깥이다.
///
/// **집합을 합치지 않고 갈아 끼운다.** VSCode는 기존 접힘 위에 더하지만 Vim `foldlevel`은 그 레벨에
/// 맞춰 열고 닫는다 — 두 선례가 갈리는 자리다. N1에는 **개별 접기가 없어** 접힘 상태가 늘 "전체 ·
/// 어느 레벨 · 없음" 중 하나이므로, 갈아 끼우는 쪽이 (a) 같은 명령을 두 번 눌러도 결과가 같고
/// (b) 레벨 2를 본 뒤 레벨 1을 누르면 더 크게 접히는 예측 가능한 사다리가 된다. 합치기를 택하면
/// 되돌릴 방법이 전체 펼치기뿐이라 사다리를 내려올 수 없다.
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
    self.metal_dirty = true;
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
    if (term.rt.editor_lines.len > 0) self.allocator.free(term.rt.editor_lines);
    term.rt.editor_lines = &.{};
    if (term.rt.editor_path) |p| self.allocator.free(p);
    if (term.rt.editor_fold_ranges.len > 0) self.allocator.free(term.rt.editor_fold_ranges);
    if (term.rt.editor_folded_buf.len > 0) self.allocator.free(term.rt.editor_folded_buf);
    if (term.rt.editor_folded_prev.len > 0) self.allocator.free(term.rt.editor_folded_prev);
    if (term.rt.editor_visible_lines.len > 0) self.allocator.free(term.rt.editor_visible_lines);
    if (term.rt.editor_visible_numbers.len > 0) self.allocator.free(term.rt.editor_visible_numbers);
    if (term.rt.editor_fold_marks.len > 0) self.allocator.free(term.rt.editor_fold_marks);
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
    try testing.expect(opened.file.doc.read_only); // ⑵ 표시된다
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
    try testing.expect(!opened.file.doc.read_only);
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
    try testing.expect(opened.file.doc.format.mixed_endings);
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
    // 아래 상한은 **재앙 감지선**이지 예산이 아니다 — CI 기계 편차로 흔들리지 않게 넉넉히 잡았다.
    // 값이 궁금하면 출력이 그대로 찍힌다.
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

        const t0 = monotonicMsForTest();
        _ = scrollCols(fx.session, fx.term, leaf, -1, null);
        const t1 = monotonicMsForTest();
        std.debug.print("\n[측정] {d}줄 × {d}B: 첫 가로 휠 {d}ms (max_cols={d})\n", .{ n, line.len, t1 - t0, fx.term.rt.editor_max_cols });

        // 두 번째부터는 캐시라 0에 가까워야 한다.
        try testing.expect(t1 - t0 < 1000); // 고치기 전 값(501ms)의 두 배 — 이 아래로 돌아오면 재앙이다

        // 두 번째부터는 캐시라 0에 가까워야 한다.
        const t2 = monotonicMsForTest();
        _ = scrollCols(fx.session, fx.term, leaf, -1, null);
        const t3 = monotonicMsForTest();
        std.debug.print("[측정] {d}줄: 두 번째 휠 {d}ms\n", .{ n, t3 - t2 });
        try testing.expect(t3 - t2 < 50); // 캐시가 안 먹으면 여기서 걸린다
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

    const t0 = monotonicMsForTest();
    _ = scrollCols(fx.session, fx.term, leaf, -1, null);
    const t1 = monotonicMsForTest();
    std.debug.print("\n[측정] 5MB 한 줄: 첫 가로 휠 {d}ms (max_cols={d}, 셈 상한={d})\n", .{ t1 - t0, fx.term.rt.editor_max_cols, chrome_editor.frame.max_cols_count_limit });
    // 고치기 전 149ms. 줄 길이와 무관해야 한다 — 셈이 상한에서 멈추므로.
    try testing.expect(t1 - t0 < 50);
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
    try testing.expect(t1 - t0 < 500); // 재앙 감지선이지 예산이 아니다
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
    try testing.expectEqual(layout.folding.start, mark_col);
    try testing.expect(number_col < mark_col);
}
