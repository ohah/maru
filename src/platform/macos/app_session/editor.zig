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
const term_ops = @import("term.zig");
const editor_diff_ops = @import("editor_diff.zig");
const workspace_ops = @import("workspace.zig");
const chrome = maru.chrome;
const chrome_draw = maru.chrome.draw;
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
    first_line: usize,
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
        .{ .lines = lines },
        .{ .first_line = first_line, .wrap = wrap, .cell_w_px = cell_w_px, .cell_h_px = cell_h_px, .font_px = font_px },
        inner,
        // **배경만 뒤로 물린다.** 내용 op이 (0,0)에서 시작해야 셀 격자 양자화(`buildTextDrawList`가
        // px→셀로 바꾼다)에 여백이 먹히지 않는다 — 여백은 호출자가 **pane 원점**에 걸고, 배경은
        // 그만큼 음수로 밀어 뷰 사각 전체를 덮는다(§4.1b).
        .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        scratch,
    );
    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows };
}

/// **좌우 두 열**을 한 ops 배열에 그린다(N1.5 c). 조합은 컴포넌트가 소유하고(`diff_frame.build`),
/// 여기서는 pane 여백만 반영한다 — Chrome Lab이 같은 함수를 불러 캡처가 제품을 예고한다.
pub fn buildDiffPaneOps(
    left: chrome_editor.diff_frame.Side,
    right: chrome_editor.diff_frame.Side,
    first_line: usize,
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
        .wrap = wrap,
        .rect = inner,
        .background_rect = .{ .x = -inset, .y = -inset, .w = rect.w, .h = rect.h },
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .font_px = font_px,
    }, scratch);
    return .{ .ops = scratch.ops[0..w.ops], .ops_len = w.ops, .visual_rows = w.visual_rows };
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
pub fn appendPaneFrame(self: *AppSession, leaf_rect: maru.session.SplitRect, term: *Term) ?PaneDraw {
    if (term.kind != .editor) return null;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return null;

    // **비교 Term은 문서 대신 판정을 말한다**(N1.5 b·c). 비교가 서면 좌우 두 열이고(c), 아직이거나
    // 보여 줄 수 없으면 그 사실을 한 줄로 말한다 — 조용한 빈 화면을 남기지 않는 것이 §7의 요구다.
    const diff_state_opt: ?*const editor_diff_ops.State = if (term.rt.editor_diff) |*st| st else null;
    var status_line: [1][]const u8 = undefined;
    const lines: []const []const u8 = if (diff_state_opt) |st| blk: {
        if (st.view == .compare) break :blk st.left_texts; // 아래 두 열 경로가 쓴다
        status_line[0] = editor_diff_ops.statusText(st.view);
        break :blk status_line[0..1];
    } else term.rt.editor_lines;
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
    const rect = pane_ops.paneGeometry(self, leaf_rect).body;
    if (rect.w == 0 or rect.h == 0) return null;

    var ops: [1024]chrome_draw.Op = undefined;
    var text: [16384]u8 = undefined;
    var runs: [1024]chrome_draw.Run = undefined;
    var content_rows: [256]chrome_editor.content.Row = undefined;
    var visual_rows: [256]chrome_editor.visual_map.VisualRow = undefined;
    var gutter_rows: [256]chrome_editor.gutter.Row = undefined;
    var counts: [4096]u32 = undefined;
    var count_scratch: [8192]u8 = undefined;

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
        if (st.view != .compare) break :blk buildPaneOps(lines, term.rt.editor_first_line, wrap, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
        // **좌우가 세로를 공유한다**(§3.5) — 행 배열이 이미 같은 길이라 같은 인덱스가 같은 높이다.
        // 가로는 각자다(§3.5의 그 규칙은 CM6가 "양쪽 줄 길이가 달라 한쪽을 따라가면 다른 쪽이
        // 엉뚱한 곳을 본다"고 적어 둔 근거에서 왔다) — 입력이 붙을 때 열별 `first_col`이 여기 온다.
        break :blk buildDiffPaneOps(
            .{ .lines = st.left_texts, .numbers = st.left_numbers, .total_lines = st.left_lines.len, .bands = st.left_bands },
            .{ .lines = st.right_texts, .numbers = st.right_numbers, .total_lines = st.right_lines.len, .bands = st.right_bands },
            term.rt.editor_first_line,
            wrap,
            pane_rect,
            @intCast(self.cell_width_px),
            @intCast(self.cell_height_px),
            @intCast(self.cell_height_px),
            scratch,
        );
    } else buildPaneOps(lines, term.rt.editor_first_line, wrap, pane_rect, @intCast(self.cell_width_px), @intCast(self.cell_height_px), @intCast(self.cell_height_px), scratch);
    if (pf.ops_len == 0) return null;

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

    term.rt.editor_doc = opened;
    term.rt.editor_lines = lines;
    term.rt.editor_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;

    const pane = pane_ops.activePane(self);
    pane.terms.append(self.allocator, term) catch return error.OutOfMemory;
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
pub fn scrollLines(self: *AppSession, term: *Term, body_rect: maru.session.SplitRect, lines: i32) bool {
    if (term.kind != .editor) return false;
    if (lines == 0) return true; // 0줄이어도 **소유는 한다**(잔여 델타는 호출자의 accumulator가 든다)

    // 비교 Term은 좌우 **행** 배열이 문서다(좌우 길이가 같다). 문서 편집기는 줄 배열이다.
    const total: usize = if (term.rt.editor_diff) |st|
        (if (st.view == .compare) st.left_texts.len else 0)
    else
        term.rt.editor_lines.len;
    if (total == 0) return true;

    // **마지막 화면이 비지 않게 멈춘다.** 끝을 넘겨 스크롤하게 두면 배경만 남은 화면이 나오고,
    // 사용자는 문서가 끝났는지 뷰가 깨졌는지 알 수 없다.
    //
    // 호출자가 주는 사각은 **이미 pane 안쪽**이다(`paneTargetAt` → `paneTermRect`). 여기서
    // `paneGeometry`를 다시 태우면 탭 바를 두 번 빼 보이는 행 수가 실제보다 적어진다.
    const inner_h = body_rect.h -| chrome_editor.frame.content_inset_px * 2;
    const visible: usize = @max(inner_h / @max(self.cell_height_px, 1), 1);
    const max_first: usize = total -| visible;

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

/// 활성 Term이 편집기면 그 뷰의 랩을 뒤집는다. 아니면 무동작(true를 안 돌려주므로 호출자가 안다).
///
/// **override를 세우는 방식이다** — 지금 보이는 값의 반대를 뷰에 박는다. config를 바꾸지 않는 이유는
/// 그것이 **기본값**이고(다음에 여는 뷰가 따른다) 토글은 이 뷰의 일이기 때문이다.
pub fn toggleWrap(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return false;
    const now = term.rt.editor_wrap orelse self.loaded_config.config.editor.wrap;
    term.rt.editor_wrap = !now;
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
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;

    // 문서를 화면보다 길게 만든다(픽스처는 3줄이라 스크롤이 성립하지 않는다).
    const long = try allocator.alloc([]const u8, 200);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    try testing.expect(scrollLines(fx.session, fx.term, body, -3)); // 아래로 세 줄
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_first_line);
    try testing.expect(scrollLines(fx.session, fx.term, body, 1)); // 위로 한 줄
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_first_line);
}

test "문서 앞뒤로 넘어가지 않는다 — 마지막 화면이 비지 않게 멈춘다" {
    // 끝을 넘겨 스크롤하게 두면 배경만 남은 화면이 나오고, 사용자는 문서가 끝났는지 뷰가 깨졌는지 모른다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;

    const long = try allocator.alloc([]const u8, 200);
    defer allocator.free(long);
    for (long) |*l| l.* = "line";
    const saved = fx.term.rt.editor_lines;
    fx.term.rt.editor_lines = long;
    defer fx.term.rt.editor_lines = saved;

    _ = scrollLines(fx.session, fx.term, body, 10); // 위로 — 이미 맨 앞
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);

    _ = scrollLines(fx.session, fx.term, body, -10_000); // 아래로 한참
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
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;
    _ = scrollLines(fx.session, fx.term, body, -50); // 픽스처는 3줄
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "편집기가 아니면 휠을 소유하지 않는다 — 터미널 스크롤백으로 흘러야 한다" {
    // 여기서 true를 돌려주면 셸 pane 위 휠이 **아무것도 안 하는** 상태가 된다(호출자가 곧바로 반환한다).
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;
    const term = pane_ops.activePane(fx.session).terms.items[0];
    const saved_kind = term.kind;
    term.kind = .terminal;
    defer term.kind = saved_kind;
    try testing.expect(!scrollLines(fx.session, term, body, -3));
}

test "0줄이어도 편집기가 소유한다 — 잔여 델타가 뒤 터미널을 굴리면 안 된다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;
    try testing.expect(scrollLines(fx.session, fx.term, body, 0));
}

test "스크롤하면 화면이 실제로 바뀐다 — 상태만 움직이고 렌더가 안 따라오면 아무 일도 안 일어난다" {
    // **`editor_first_line`이 바뀌는 것만 보는 테스트는 통과하면서 화면은 멈춰 있을 수 있다**(렌더가
    // 그 값을 안 읽으면). 여기서는 같은 pane을 두 번 그려 **셀 내용이 달라지는지**를 본다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try PaneFixture.init(allocator);
    defer fx.deinit(allocator);
    const body = pane_ops.paneGeometry(fx.session, fx.leaf_rect).body;

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

    _ = scrollLines(fx.session, fx.term, body, -5);
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
