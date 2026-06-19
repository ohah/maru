const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");
const png = @import("png.zig"); // kitty graphics f=100 PNG 디코드(K3c)
const width = @import("../width.zig"); // Unicode 셀 폭은 중립 top-level 유틸로 이동(src/width.zig)

/// 단말 자기식별의 단일 신원 출처. XTVERSION(CSI > q) 응답이 지금 이걸 쓰고, 이후 추가할 자체
/// terminfo 생성과 XTGETTCAP(DCS + q) 응답도 같은 값을 재사용한다 — 이름/버전이 채널마다 어긋나지
/// 않도록 한곳에서만 정의한다. 버전의 정식 단일 출처는 build.zig.zon의 `.version`이며, 지금은 둘 다
/// "0.0.0" placeholder다. build_options로 연결하면 drift가 사라지지만, 순수 VT core를 빌드 시스템에
/// 결합하지 않으려고(이식성·단위 테스트 격리) 지금은 상수로 둔다 — 릴리스가 생기면 이 값을 함께 올린다.
pub const terminal_name = "maru";
pub const terminal_version = "0.0.0";

/// mouse tracking 모드(DECSET 9/1000/1002/1003) — 어떤 마우스 이벤트를 앱에 리포트할지(상호 배타). 베이스: xterm
/// mouse tracking. none=꺼짐, x10=press만, normal=press+release, button=+버튼 눌린 채 drag, any=+모든 motion.
pub const MouseTracking = enum { none, x10, normal, button, any };
/// mouse 이벤트 인코딩(DECSET 1006 SGR / 1016 SGR-pixels / 기본 x10). 베이스: xterm. SGR은 좌표 무제한(>223 OK).
pub const MouseFormat = enum { x10, sgr, sgr_pixels, urxvt };

/// kitty keyboard protocol(progressive enhancement) flag(packed u5). disambiguate=모호한 키만 CSI u로 명확히,
/// report_events=key up/repeat, report_alternates=대체 키, report_all=모든 키 escape, report_associated=텍스트.
/// 비트 위치(disambiguate=1·report_events=2·report_alternates=4·report_all=8·report_associated=16)는 kitty
/// keyboard protocol 명세가 정한 progressive-enhancement 플래그 값이다. 기본 disabled(legacy 인코딩).
pub const KittyFlags = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,

    pub const disabled: KittyFlags = .{};
    pub fn int(self: KittyFlags) u5 {
        return @bitCast(self);
    }
};
/// kitty flags의 set 연산 모드(CSI = flags ; mode u). 1=set(치환)·2=or(합집합)·3=not(차집합) — 베이스: kitty spec.
pub const KittySetMode = enum { set, @"or", not };
/// kitty flags 스택(CSI > flags u = push, CSI < n u = pop, CSI = flags;mode u = set). 활성 flags 하나와
/// 복원용 스택을 따로 둔다 — push는 현재 flags를 스택에 저장하고 새 flags로 진입하고, pop n은 n단을
/// 복원한다. kitty keyboard protocol은 스택 깊이/오버플로 동작을 규정하지 않으므로 maru가 한도를 정한다:
/// 한도(16) 초과 push는 가장 오래된 복원 지점을 버리고, 스택 높이를 넘는 pop은 비활성으로 떨군다(빈 스택은
/// disabled). 터미널 모드 스택은 보통 1~2단이라 한도 초과는 비현실적. 베이스: kitty keyboard protocol의
/// flag 스택(push/pop/set 의미만 명세; 자료구조는 maru 설계).
pub const KittyFlagStack = struct {
    const max_depth = 16;
    active: KittyFlags = .{},
    saved: [max_depth]KittyFlags = @splat(.{}),
    depth: usize = 0,

    pub fn current(self: KittyFlagStack) KittyFlags {
        return self.active;
    }
    pub fn set(self: *KittyFlagStack, mode: KittySetMode, v: KittyFlags) void {
        const cur = self.active.int();
        self.active = @bitCast(switch (mode) {
            .set => v.int(),
            .@"or" => cur | v.int(),
            .not => cur & ~v.int(),
        });
    }
    pub fn push(self: *KittyFlagStack, flags: KittyFlags) void {
        if (self.depth == max_depth) {
            // 한도 초과: 가장 오래된 복원 지점을 버리고 한 칸 당긴다.
            std.mem.copyForwards(KittyFlags, self.saved[0 .. max_depth - 1], self.saved[1..]);
            self.depth -= 1;
        }
        self.saved[self.depth] = self.active;
        self.depth += 1;
        self.active = flags;
    }
    pub fn pop(self: *KittyFlagStack, n: usize) void {
        if (n >= self.depth) {
            // 스택 높이 이상으로 pop하면 전부 비우고 비활성(빈 스택 pop은 disabled).
            self.depth = 0;
            self.active = .{};
            return;
        }
        for (0..n) |_| {
            self.depth -= 1;
            self.active = self.saved[self.depth];
        }
    }
};

/// DECSC/DECRC(ESC 7/8)·DECSET 1048/1049가 쓰는 저장 커서 상태. 화면(primary/alt)마다 하나씩 둔다.
pub const SavedCursor = struct {
    cursor: types.Cursor = .{},
    pen: types.Style = .{},
    pending_wrap: bool = false,
};

/// 저장 커서를 새 grid 안으로 clamp한다. col이 잘려 더는 마지막 칸이 아니면 pending_wrap도 끈다
/// (deferred wrap은 "마지막 칸에 머무는 중"일 때만 유효한 상태다).
fn clampSavedCursor(slot: *SavedCursor, size: types.Size) void {
    const clamped_col = @min(slot.cursor.col, size.cols - 1);
    if (clamped_col != slot.cursor.col) slot.pending_wrap = false;
    slot.cursor.row = @min(slot.cursor.row, size.rows - 1);
    slot.cursor.col = clamped_col;
}

pub const TerminalCore = struct {
    allocator: std.mem.Allocator,
    size: types.Size,
    cursor: types.Cursor = .{},
    cells: []types.Cell,
    dirty: ?types.DirtyRegion = null,
    utf8_tail: [4]u8 = undefined,
    utf8_tail_len: usize = 0,
    // The cell that received the most recent printable codepoint, so a
    // following zero-width combining mark attaches to the real base glyph
    // instead of being guessed from the cursor. The cursor is ambiguous: it
    // advances past the base normally, but parks *on* the base at the last
    // column (no autowrap) and moves to a fresh row after a line feed. Reset
    // by anything that ends the current grapheme run (CR/LF/backspace/resize).
    last_print: ?struct { row: u16, col: u16 } = null,
    // 현재 SGR 스타일(pen). printable cell을 쓸 때마다 stamp한다. CSI ... m 이 갱신한다.
    pen: types.Style = .{},
    // VT escape 파서 상태기계. ground 외 상태에서는 byte를 escape sequence로 소비한다.
    parser: ParserState = .ground,
    // CSI 파라미터 누적 버퍼. 대부분의 시퀀스는 파라미터가 적으므로 작은 고정 크기로 충분하고,
    // 넘치면 무시한다(악성/비정상 입력 방어).
    csi_params: [max_csi_params]u16 = [_]u16{0} ** max_csi_params,
    csi_param_count: usize = 0,
    csi_has_digit: bool = false,
    // CSI의 private marker 바이트(0x3c-0x3f: '<','=','>','?'). 0이면 없음. xterm은 marker별로
    // 의미가 다르다 — DECSET/DECRST는 '?' 전용이고 '>'는 DA2/XTVERSION 등 별도 명령이다.
    csi_marker: u8 = 0,
    // CSI intermediate 바이트(0x20-0x2f, 예: DECSCUSR의 ' ', DECCARA의 '$'). 0이면 없음.
    // intermediate가 붙은 시퀀스는 같은 final이라도 다른 명령이므로 (intermediate, final) 튜플로
    // dispatch하고, 모르는 조합은 소비한다(VT500 파서 의미). 여러 개면 마지막 것만 기억한다
    // (실사용 시퀀스는 intermediate 1개).
    csi_intermediate: u8 = 0,
    csi_overflow: bool = false,
    // deferred autowrap(DECAWM, 기본 켜짐). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 이 플래그가
    // 선다. 다음 printable 글자가 먼저 다음 줄 첫 칸으로 넘어간 뒤 그려진다. 마지막 칸이 그 줄의
    // 끝 글자면 wrap하지 않으려고(끝 글자마다 빈 줄이 끼지 않게) 즉시가 아니라 "다음 글자에서"
    // 넘긴다. 명시적 커서 이동(CR/LF/backspace/커서 위치 지정/resize)은 이 상태를 무효화한다.
    pending_wrap: bool = false,
    // DECSTBM scroll region(top/bottom margin, 0-indexed inclusive). LF/IND/RI 스크롤은 이 구간
    // 안에서만 일어난다. 기본은 화면 전체 [0, rows-1]. init/resize에서 전체로 리셋한다. less/vim
    // 등이 상태줄을 고정하고 본문만 스크롤하는 데 쓴다.
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,
    /// DECOM(origin mode, DECSET ?6). 켜지면 CUP/HVP의 row가 scroll region 상단 기준(1=region top)이고
    /// 커서가 region 안에 갇힌다. RIS·기본은 off(화면 절대 좌표). 좌우 margin이 없어 col은 영향 없다.
    origin_mode: bool = false,
    // alternate screen(DECSET 1049/47/1047). vim·less 같은 TUI가 전체 화면을 쓰고 종료 시 원래
    // 셸 화면을 복원하는 보조 버퍼다. 활성이면 saved_*에 primary 그리드가 보관돼 있고, alt 출력은
    // 스크롤백에 쌓이지 않으며 스크롤백 뷰포트도 잠긴다(표준 xterm 동작).
    alt_active: bool = false,
    // DECCKM(CSI ?1 h/l, application cursor keys). vim/less가 켜면 화살표 입력이 SS3(`ESC O A`)로
    // 인코딩돼야 한다. core는 모드만 추적하고, 인코딩은 input.encodeKey가 EncodeOptions로 받는다.
    application_cursor_keys: bool = false,
    // DECKPAM/DECKPNM(ESC =/ESC >, G10): application/numeric keypad 모드. 켜지면 numpad 키가 SS3(`ESC O p`..)로
    // 인코딩돼야 한다(DECCKM 화살표와 같은 결). core는 모드만 추적 — 실제 numpad 인코딩은 input 모델에 keypad 키
    // 변종 + Swift numpad keycode 감지가 전제라 후속(macOS는 numpad 드묾). RIS에서 off(numeric).
    application_keypad: bool = false,
    // alternate scroll(xterm DECSET 1007): alt screen에서 휠/트랙패드 스크롤을 화살표 키로 변환해
    // 프로그램에 보낸다(less/vim이 자체 스크롤). 스크롤백이 잠긴 alt에서 스크롤이 무반응이 되지
    // 않게 하는 표준 장치로, iTerm2/Terminal.app처럼 기본 켠다(프로그램이 ?1007l로 끌 수 있음).
    alternate_scroll: bool = true,
    // bracketed paste(DECSET 2004): 켜져 있으면 붙여넣기를 ESC[200~ ... ESC[201~로 감싸 보낸다.
    // zsh/vim/claude가 켜며, 붙여넣은 텍스트를 타이핑과 구분해(자동 들여쓰기·즉시 실행 방지) 처리한다.
    bracketed_paste: bool = false,
    // focus reporting(DECSET 1004): 켜지면 창 포커스 in/out을 CSI I / CSI O로 PTY에 리포트한다.
    // vim FocusGained/Lost·자동저장 등이 쓴다. 기본 off — 앱이 켠다(progressive; 끄면 무리포트).
    focus_events: bool = false,
    // mouse reporting(DECSET 9/1000/1002/1003): 켜지면 클릭/드래그/휠을 좌표와 함께 PTY로 리포트(셀렉션 대신).
    // 기본 none — 앱이 켠다. nvim/tmux/htop/lazygit 등이 쓴다. shift 누르면 셀렉션 override(8b platform 처리).
    mouse_tracking: MouseTracking = .none,
    mouse_format: MouseFormat = .x10,
    // synchronized output(DECSET 2026): 켜지면 frame 투영을 멈춰(hold) ESU(2026 reset)까지 출력을 한 frame으로
    // 묶는다 — nvim 화면 갱신 tearing/깜빡임 방지. 베이스: Ghostty(synchronized_output이면 render skip)·DEC 2026.
    sync_output: bool = false,
    /// kitty keyboard protocol flag 스택(CSI > flags u=push / < n u=pop / = flags;mode u=set로 앱이 제어).
    /// 기본 비어 있음(current=disabled) → encodeKey가 legacy 인코딩. 베이스: kitty keyboard protocol spec.
    kitty_flags: KittyFlagStack = .{},
    // grapheme cluster mode(DECSET 2027, terminal-unicode-core): 앱이 "나도 grapheme 단위 너비를
    // 쓴다"고 합의하면 켠다. 켜지면 VS16(이모지 표현)·스킨톤·국기 같은 grapheme을 한 셀로 묶고
    // 너비를 EAW 대신 cluster 기준(❤️=2칸 등)으로 잰다 — 앱과 너비가 일치하므로 붙여넣기 redraw가
    // 안 깨지면서 풀사이즈로 그릴 수 있다. 기본 off면 EAW per-codepoint(레거시 앱 호환). 앱은
    // DECRQM(CSI ?2027$p)로 지원 여부를 먼저 묻는다 — Ghostty/xterm.js와 같은 opt-in 모델이다.
    grapheme_cluster_mode: bool = false,
    // DECTCEM(CSI ?25 h/l): 커서 표시. TUI가 화면을 그리는 동안 커서 깜빡임/잔상을 숨기려고 끈다.
    // snapshot/renderSnapshot이 내보내는 cursor.visible에 합성된다(내부 self.cursor.visible은 불변).
    cursor_visible: bool = true,
    // DECSCUSR(CSI Ps SP q): 커서 모양과 깜빡임. vim이 모드별로 bar/block을 전환하는 표준 수단.
    cursor_shape: types.CursorShape = .block,
    cursor_blink: bool = true,
    saved_cells: []types.Cell = &.{},
    saved_wrapped: []bool = &.{},
    // alt screen 전환 때 primary의 OSC 133 행 태그를 보관(saved_wrapped와 같은 슬롯 패턴).
    saved_prompt_marks: []types.RowPrompt = &.{},
    // DECSC/DECRC + 1048/1049가 쓰는 저장 커서. xterm처럼 화면(primary/alt)마다 별도 슬롯을 둔다 —
    // 한 슬롯을 공유하면 TUI가 alt 안에서 ESC 7/8을 쓸 때 1049가 저장한 셸 커서가 덮여, 종료 시
    // 프롬프트가 엉뚱한 위치(예: 화면 맨 위)로 복원된다.
    saved_cursor_primary: SavedCursor = .{},
    saved_cursor_alt: SavedCursor = .{},
    // 각 CSI 파라미터가 ';'(새 파라미터)가 아니라 ':'(sub-parameter)로 들어왔는지 표시한다.
    // ITU colon 형식 38:2:colorspace:r:g:b는 38;2;r;g;b와 달리 colorspace 컴포넌트가 하나 더
    // 있어, 이 구분 없이는 RGB가 한 칸 밀린다.
    csi_subparam: [max_csi_params]bool = [_]bool{false} ** max_csi_params,
    // 활성 화면의 soft-wrap 추적. wrapped[r]==true는 "행 r이 autowrap으로 행 r+1로 이어진다"는
    // r↔r+1 경계의 속성이다(내용이 아니라 경계). hard 줄끝(LF, 또는 셸이 그린 뒤 CR/LF/CUP로 떠난
    // 줄)은 wrapped[r]=false다. autowrap(마지막 칸 넘침)일 때만 true가 되고, 그 행에 새로 쓰면 다시
    // false로 리셋된다(redraw가 스스로 교정됨). resize 시 reflow가 이 플래그로 논리 줄을 잇는다.
    // 길이는 항상 size.rows.
    wrapped: []bool = &.{},
    // 활성 화면의 행별 OSC 133 semantic 분류(길이=size.rows). `wrapped`와 같은 병렬 배열 패턴이지만
    // 결정적 차이: glyph 쓰기(putCell)로 리셋하지 않는다 — 셸이 프롬프트를 redraw해도 그 행의
    // 프롬프트/입력/출력 분류는 유지돼야 한다. 상태 머신(semantic_state)·scroll·clear·OSC 마커만
    // 이 배열을 건드린다. OSC 133 마킹이 없으면 전부 .unknown이다.
    prompt_marks: []types.RowPrompt = &.{},
    // 현재 활성 중인 semantic 영역(OSC 133 A→prompt, B→input, C→command, D→unknown). lineFeed가
    // 다음 행에 이 값을 전파해 여러 줄 프롬프트/출력이 전부 태깅된다.
    semantic_state: types.SemanticPrompt = .unknown,
    // 가장 최근에 끝난 명령의 종료코드(OSC 133 ; D ; <code>, 없으면 null). shell이 음수도 보낼 수
    // 있어 i32. 이후 단계가 프롬프트 거터에 ✓/✗로 투영한다.
    last_command_exit: ?i32 = null,
    // 셸 통합(OSC 133/7) 의미 이벤트 스트림 — 명령 라이프사이클 경계를 시간순으로 기록한다(관측
    // 가능성: 디버그 로그·테스트·후속 trace가 같은 데이터를 공유). OSC 파싱이 append하고 소비자가
    // drain/clear한다. 누구도 drain 안 해도 무한정 자라지 않게 cap(shell_events_cap)에서 멈추고
    // overflow 플래그를 세운다(드롭은 디버그 로그가 보고 — 조용한 손실 방지). 화면 상태가 아니라
    // 전이 스트림이라 RIS는 건드리지 않는다(프레임마다 drain되어 어차피 짧게 유지).
    shell_events: std.ArrayListUnmanaged(types.ShellEvent) = .empty,
    shell_events_overflow: bool = false,
    // 스크롤백: 화면 위로 밀려난(scroll된) 맨 윗줄을 보관한다. ring buffer로, 가장 오래된 행이
    // sb_head, 보관 개수가 sb_count다. 슬롯 버퍼를 재사용해 scroll마다 alloc 없이 memcpy만 하므로
    // 출력 hot path(매 줄 scroll)를 느리게 하지 않는다. 과거를 스크롤해서 보는 뷰포트와 reflow는
    // 이 저장 위에 올린다(다음 단계). 첫 scroll에서 max_scrollback 크기로 lazy 할당한다.
    scrollback: []?[]types.Cell = &.{},
    // 각 스크롤백 행의 soft-wrap 플래그. scrollback과 병렬 ring(같은 max_scrollback 길이, 같은
    // (sb_head+i)%len 인덱싱). 슬롯 cell 버퍼 재사용 경로를 건드리지 않는 평평한 []bool이다.
    sb_wrapped: []bool = &.{},
    // 각 스크롤백 행의 OSC 133 semantic 태그. scrollback/sb_wrapped와 병렬 ring(같은 max_scrollback
    // 길이, 같은 (sb_head+i)%len 인덱싱). 세 ring의 길이는 항상 같아야 한다(pushScrollback이 함께
    // 할당). 스크롤백으로 밀려난 프롬프트/출력 행의 분류를 보존한다.
    sb_prompt_marks: []types.RowPrompt = &.{},
    sb_head: usize = 0,
    sb_count: usize = 0,
    max_scrollback: usize = default_max_scrollback,
    // 뷰포트: 바닥(0=활성 화면)에서 위로 스크롤한 줄 수. [0, sb_count] 범위. >0이면 화면 윗부분에
    // 스크롤백(과거)이 보이고 활성 화면 아랫부분은 가려진다. 과거를 보는 중 새 출력이 scroll되면
    // 같은 내용을 계속 보도록 함께 올린다(scroll-lock).
    view_offset: usize = 0,
    // 스크롤백 재-wrap 지연 마크. resize는 비싼 ring 재구성(행 1000개 재할당)을 즉시 하지 않고
    // 이 플래그만 세우고, 사용자가 실제로 과거를 보는 순간(scrollViewport/renderSnapshot)에 현재
    // 폭으로 1회 수행한다 — 연속 드래그 resize가 와도 마지막 폭으로 한 번만 재-wrap된다.
    sb_rewrap_pending: bool = false,
    // 마우스 드래그 선택(anchor=누른 곳, head=현재 끝). 절대 행 좌표라 스크롤해도 내용을 따라간다.
    // 스크롤백 eviction(가득 찬 ring)·재-wrap·clear 때 보정/해제된다.
    selection_anchor: ?types.SelectionPoint = null,
    selection_head: ?types.SelectionPoint = null,
    // 블록(직사각형) 선택 모드. true면 anchor~head를 행 흐름이 아니라 [min_col,max_col]×[min_row,max_row]
    // 사각형으로 해석한다(Option+드래그 — iTerm2/Terminal.app 관례). selectionStart가 false로 리셋하고
    // setSelectionBlock(start 직후)이 켠다. selectionClear/RIS에서 해제.
    selection_block: bool = false,
    // OSC 8 하이퍼링크. URI는 link_store에 intern(중복 제거)하고 셀에는 id(인덱스+1)만 둔다.
    // pen_link는 현재 열린 링크 id — 링크가 열린 동안 출력되는 셀에 찍힌다. store는 세션 수명
    // 동안 유지된다(셀이 스크롤백에 남아 있는 한 URI도 살아 있어야 하므로 GC하지 않는다).
    link_store: std.ArrayListUnmanaged([]u8) = .empty,
    link_ids: std.StringHashMapUnmanaged(u32) = .empty,
    pen_link: u32 = 0,
    // IME 조합 중(preedit) 텍스트(UTF-8, core 소유). 셀 그리드를 더럽히지 않고 renderSnapshot
    // 합성 단계에서만 커서 위치에 반전 스타일로 표시된다 — 조합이 끝나면(확정/취소) 비워진다.
    preedit: ?[]u8 = null,
    // OSC 내용 축적 버퍼(OSC 8 하이퍼링크 파싱용). 넘치면 그 OSC는 통째로 무시한다(악의적/거대
    // URI가 메모리를 못 잡게). title 등 다른 OSC는 여전히 소비만 한다.
    osc_buffer: [2048]u8 = undefined,
    osc_len: usize = 0,
    osc_overflow: bool = false,
    // G14 DCS(ESC P ... ST) 수집 버퍼. 현재 DECRQSS(`DCS $ q <req> ST`)만 처리하고 요청은 짧아 64B면 충분
    // (넘으면 overflow로 폐기). Sixel/DECDLD 등 큰 DCS는 미지원이라 소비만 한다(이 상태기계가 그 토대).
    dcs_buffer: [64]u8 = undefined,
    dcs_len: usize = 0,
    dcs_overflow: bool = false,
    // APC(ESC _ ... ESC \) 축적 버퍼. kitty graphics(`ESC _ G ...payload... ESC \`)용 — 첫 바이트
    // 'G'면 kitty command로 파싱한다. 단일 APC(한 청크) 한도; 넘치면 그 APC는 통째로 무시한다(chunked면
    // 진행 중 전송도 폐기). 베이스: kitty graphics protocol(APC payload), OSC 버퍼와 동형.
    // kitty graphics APC payload 누적 버퍼(동적). 베이스: Ghostty가 APC를 ArrayList+max_bytes로 받는 것
    // (graphics_command.zig)과 동형 — 단일 APC로 오는 큰 transmit(과거 고정 4096 초과 시 silent drop)을
    // 받기 위해 고정 배열 대신 동적으로. 상한은 chunked와 같은 max_kitty_chunk_bytes(폭주 방어). 초과/OOM이면
    // apc_overflow로 표시해 dispatch에서 폐기한다. RIS/destroy에서 비운다.
    apc_buffer: std.ArrayListUnmanaged(u8) = .empty,
    apc_overflow: bool = false,
    // kitty graphics chunked 전송(m=1) 누적 버퍼 — 여러 APC로 쪼개 온 base64 payload를 모은다. 첫 청크가
    // control(a/f/s/v/i/o)을 갖고(kitty_chunk_cmd), 이후 청크는 payload만 이어 붙인다. m=0에서 누적 base64를
    // 한 번에 디코드한다(각 청크 base64는 4의 배수라 이어 붙여 디코드해도 유효 — kitty 규약). 비어 있으면
    // chunking 비활성. 베이스: kitty graphics protocol(chunked transmission).
    kitty_chunk: std.ArrayListUnmanaged(u8) = .empty,
    kitty_chunk_cmd: ?KittyGraphicsCommand = null,
    // 셀 픽셀 크기(platform이 setCellMetrics로 주입, 폰트·DPI·resize 시 갱신). **kitty 자동 크기 이미지의
    // 커서 advance에만** 쓴다 — 그 외 픽셀↔셀 환산은 여전히 렌더러 책임(K1을 셀 픽셀 1쌍 보관으로만 완화).
    // 0이면 미보유(헤드리스 등) — 자동 크기 advance를 건너뛴다. 마우스 1016이 픽셀을 주입하는 것과 같은 결.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // OSC 10/11 색 질의 응답용 기본 전경/배경 색(theme). platform이 setDefaultColors로 주입(셀 메트릭과 같은
    // 결) — 코어는 Color.default 추상만 알아 실제 RGB를 받는다. 주입 전 기본값은 어두운 테마 근사.
    default_fg_rgb: types.Rgb = .{ .r = 0xcc, .g = 0xcc, .b = 0xcc },
    default_bg_rgb: types.Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 },
    // OSC 10/11 색 설정 override(null = theme 기본 사용). OSC 10이 전경, 11이 배경을 덮고 OSC 110/111이 리셋한다.
    // setDefaultColors(theme를 매 tick 주입)와 별개 필드라 주입이 set 값을 지우지 않는다. 렌더러 default 색은
    // app이 `override orelse theme`로 wiring하고(OSC 4 팔레트와 같은 결 — 코어가 override 보관, app이 소비),
    // OSC 10/11 질의도 override를 우선 회신한다. RIS에서 null.
    default_fg_override: ?types.Rgb = null,
    default_bg_override: ?types.Rgb = null,
    // OSC 4 팔레트 override: 256색 각 인덱스의 앱 재정의(null = 기본 xterm256 팔레트). OSC 4로 설정/질의,
    // OSC 104로 리셋(인덱스 없으면 전부). 렌더러가 `.indexed` 색을 풀 때 이 표를 먼저 본다(app이
    // paletteOverride()를 CellColors.palette로 wiring — 코어는 셀 픽셀/렌더를 모르는 K1 경계 유지). RIS에서 전부 null.
    palette_override: [256]?types.Rgb = .{null} ** 256,
    // K1 경계 보강: 코어는 config palette base를 palette_override 옆 별도 레이어로 보관한다 — 렌더(metal_frame)와
    // OSC 4 query 응답이 같은 우선순위(override > config > xterm256)를 공유해 화면·보고가 일치한다. OSC 4가 없을 때의
    // ANSI 16색 base(theme.palette)를 platform이 setConfigPalette로 주입한다. RIS/OSC104는 override만 리셋(config base 유지).
    config_palette: [16]?types.Rgb = .{null} ** 16,
    // OSC 52 클립보드 쓰기 요청(디코드된 바이트, pending). platform이 정책(allow) 확인 후 drain → system clipboard.
    clipboard_write: std.ArrayListUnmanaged(u8) = .empty,
    // OSC 9(iTerm2)·OSC 777(rxvt) 데스크톱 알림 pending. 코어는 title/body 파싱만 하고, platform이 매 tick drain해
    // 네이티브 알림(UNUserNotificationCenter)으로 띄운다(후속 PR). 한 tick에 여럿 오면 마지막만 남는다(드묾, 허용).
    // 알림은 transient 이벤트라 RIS 대상 아님(pending은 다음 tick에 drain되어 곧 사라진다). osc_overflow가 크기 방어.
    notification_pending: bool = false,
    notification_title: std.ArrayListUnmanaged(u8) = .empty,
    notification_body: std.ArrayListUnmanaged(u8) = .empty,
    // G3 charset: G0/G1 G-set 지정과 GL 호출. `ESC ( <f>`→G0, `ESC ) <f>`→G1(f='0'=dec_special·'B'=ascii).
    // SI(0x0f)→GL=G0, SO(0x0e)→GL=G1. print 시 GL의 charset으로 codepoint를 변환한다. RIS에서 전부 초기화.
    charset_g0: Charset = .ascii,
    charset_g1: Charset = .ascii,
    charset_gl: u1 = 0, // 0=G0(SI), 1=G1(SO)
    // ESC <intermediate>(0x20..0x2f)의 intermediate 바이트. escape_intermediate 상태가 final과 함께 해석한다
    // (예: `ESC ( 0`이면 intermediate='(' final='0'). 0이면 진행 중 아님.
    escape_intermediate_byte: u8 = 0,
    // G4 동적 탭스톱(col별 true=탭스톱). 기본은 8칸마다(col%8==0). HTS(ESC H)가 set, TBC(CSI g)가 clear,
    // CBT(CSI Z)가 역방향 이동. 길이는 cols와 맞춘다(resize가 재구성, OOM이면 isTabstop이 8칸 기본으로 폴백).
    tabstops: []bool = &.{},
    // G12 BEL(0x07) pending. platform이 매 tick takeBell로 drain해 시스템 벨(NSSound.beep)을 울린다.
    // bool로 합쳐 한 tick에 BEL이 쏟아져도 beep는 최대 1회(벨 폭주 방지). transient라 RIS 대상 아님.
    bell_pending: bool = false,
    // G5 REP(CSI Ps b): 직전에 출력한 graphic codepoint. REP가 이걸 N회 반복한다(없으면 0 → 무동작).
    last_printed_cp: u21 = 0,
    // G6 IRM(CSI 4 h/l): insert mode. 켜지면 출력 글자가 커서 위치에 삽입(오른쪽 밀기)된다(덮어쓰기 아님). RIS off.
    insert_mode: bool = false,
    // G8 DECAWM(CSI ?7 h/l): autowrap. 기본 on(마지막 칸 넘침 시 다음 줄로 wrap). off면 마지막 칸에서 덮어쓴다. RIS on.
    autowrap: bool = true,
    // G9 DECSCNM(CSI ?5 h/l): 화면 반전. 켜지면 렌더러가 모든 셀의 전경/배경을 전역 스왑한다(app이 reverseScreen()을
    // CellColors.screen_reverse로 wiring, clear color도 전경색으로). 코어는 셀 색을 안 바꾸고 플래그만 — K1 경계. RIS off.
    reverse_screen: bool = false,
    /// kitty graphics 이미지 저장소(transmit된 이미지, image_id→픽셀 버퍼). 렌더는 후속.
    kitty_images: KittyImageStorage = .{},
    /// kitty graphics placement(표시 중인 이미지 인스턴스) 목록. (image_id, placement_id)로 식별 —
    /// 같은 키 재요청은 교체한다. anchor는 절대 행(스크롤백 0..sb_count-1, 이어서 활성 화면)이라 selection/
    /// find와 같은 좌표계로 스크롤·eviction에 따라 보정된다(shiftPlacementsForEviction). 상한
    /// (max_kitty_placements)으로 악의적 대량 placement를 막는다 — 이미지 320MB 한계·APC 버퍼 한계와 같은
    /// 결의 방어선이다. K1(현재)은 저장/노출/생애주기(코어)까지 — 화면 렌더는 후속 K-단계.
    kitty_placements: std.ArrayListUnmanaged(StoredPlacement) = .empty,
    /// renderSnapshot이 placement를 뷰포트 상대 KittyPlacement로 환산해 담는 재사용 버퍼(placement가
    /// 있을 때만 lazy 할당, viewport_cells와 같은 규율). 없으면 비어 있어 일반(placement 없는) 경로는
    /// 추가 비용이 없다.
    placement_views: []types.KittyPlacement = &.{},
    /// renderSnapshot이 저장된 이미지를 KittyImageView로 빌려 담는 재사용 버퍼(이미지가 있을 때만 lazy
    /// 할당). 픽셀은 복사하지 않고 storage 버퍼를 가리키는 zero-copy다(id/치수/generation/픽셀 포인터만).
    image_views: []types.KittyImageView = &.{},
    // OSC 7: 셸이 보고한 현재 작업 디렉터리(cwd). VTE(GNOME)가 정의한 사실상 표준 — 형식은
    // `OSC 7 ; file://<host>/<percent-encoded path> ST`이고 iTerm2/Terminal.app/kitty/WezTerm이
    // 채택했다(ECMA-48 아님). 디코드한 path를 core가 소유한다(host는 현재 무시 — 로컬 단일 호스트
    // 가정, SSH/원격 구분은 후속). 창 제목 등이 읽는다. 셸 상태라 화면 clear엔 안 지우고 RIS에서만
    // 지운다. 한 번도 안 받았으면 null(빈 cwd).
    cwd: ?[]u8 = null,
    // OSC 0/2: 프로그램이 지정한 창 제목(xterm ctlseqs — OSC 0=아이콘+제목, OSC 2=제목; OSC 1=아이콘만
    // 무시). core가 소유한다. 셸/앱이 지정하면 창 제목에 우선 쓰고, 없으면 cwd basename으로 폴백한다
    // (windowTitle). 빈 제목(OSC 2 ; ST)은 해제(null)로 본다. RIS에서 공장 초기화. 그리드엔 안 보인다.
    title: ?[]u8 = null,
    // 스크롤된(view_offset>0) 상태의 렌더용 합성 버퍼(rows×cols). renderSnapshot이 뷰포트 윈도를
    // 여기에 합성한다. view_offset==0이면 안 쓰므로 lazy 할당한다(스크롤할 때만 메모리 사용).
    viewport_cells: []types.Cell = &.{},
    // 스크롤된 뷰포트의 행별 OSC 133 태그(viewport_cells와 병렬, rows 길이). renderSnapshot이
    // 보이는 행에 맞춰 합성한다. view_offset==0이면 안 쓰므로 lazy 할당한다.
    viewport_prompt_marks: []types.RowPrompt = &.{},
    // resize reflow가 출력 행을 누적하는 재사용 스크래치(grow-only, rows×cols). 매 resize에
    // ArrayList를 새로 키우지 않도록 struct에 들고 다닌다 — core_resize_loop perf 예산을 지키려면
    // alloc churn을 없애야 한다(되돌린 구현이 ArrayList realloc으로 예산을 깼다).
    reflow_cells: []types.Cell = &.{},
    reflow_wrapped: []bool = &.{},
    // reflow가 산출 행별로 OSC 133 태그를 누적하는 스크래치(reflow_wrapped와 병렬, 같은 cap_rows).
    // 논리 줄 하나의 모든 행은 같은 분류라, 출력 행이 어느 옛 행에서 나왔든 그 옛 행의 태그를 그대로
    // 옮긴다 — resize 후에도 프롬프트/입력/출력 분류가 보존된다(PR1의 .unknown 한계 제거).
    reflow_prompt_marks: []types.RowPrompt = &.{},
    // 터미널이 호스트로 돌려보낼 응답(CPR 커서 위치 보고, DSR 상태 등). write() 중 query를 만나면
    // 여기에 쌓이고, app 레이어가 매 write 후 drain해 PTY로 되쓴다(프로그램이 입력처럼 읽는다).
    // zsh 등은 SIGWINCH redraw 때 CSI 6n으로 커서를 묻는데, 응답이 없으면 redraw가 어긋난다.
    response: std.ArrayList(u8) = .empty,

    pub const ParserState = enum { ground, escape, escape_intermediate, csi, osc, osc_escape, apc, apc_escape, dcs, dcs_escape };

    /// G3 charset 지정(94-char G-set). 구형 TUI가 `ESC ( 0`(G0=DEC special graphics)으로 지정하고 SO/SI로
    /// 호출해 box-drawing(┌─┐ 등)을 ASCII 코드포인트(lqk 등)로 보낸다. `.ascii`는 무변환, `.dec_special`은
    /// 0x60..0x7e를 box 문자로 변환. 베이스: VT100 special graphics·xterm ctlseqs(Ghostty `charsets.zig` 동작 비교).
    pub const Charset = enum { ascii, dec_special };

    const max_csi_params = 16;
    const default_max_scrollback = 1000;
    /// 한 세션이 동시에 가질 수 있는 kitty graphics placement 상한 — maru가 정한 실용 값이다(kitty
    /// 명세는 상한을 규정하지 않는다). (image_id, placement_id) 키 교체로 대부분 자연히 묶이지만, 한
    /// 이미지에 placement_id를 무한히 바꿔 보내는 폭주를 막는 방어선이다(이미지 320MB·APC 버퍼 한계와
    /// 같은 결). 보통 화면에 떠 있는 이미지는 한 자릿수~수십이라 1024는 충분히 여유롭다.
    const max_kitty_placements = 1024;
    /// chunked(m=1) 전송에서 누적할 수 있는 base64 payload 상한 — 악의적 m=1 무한 전송의 메모리 폭주를
    /// 막는 방어선(이미지 320MB·APC 4096·placement 1024 한계와 같은 결). 디코드된 이미지는 320MB로 따로
    /// 제한되므로, base64 오버헤드(~4/3)를 감안해 480MB로 둔다. 초과하면 그 chunked 전송을 폐기한다.
    const max_kitty_chunk_bytes: usize = 480 * 1000 * 1000;
    // OSC 52 클립보드 쓰기 상한(디코드 후 바이트). 클립보드는 보통 작아 과대 페이로드는 거부한다(폭주 방어선).
    const max_clipboard_bytes: usize = 16 * 1000 * 1000;

    pub fn init(allocator: std.mem.Allocator, size: types.Size) !TerminalCore {
        const grid = clampGridSize(size);
        const cells = try allocator.alloc(types.Cell, cellCount(grid));
        @memset(cells, .{});
        const wrapped = try allocator.alloc(bool, grid.rows);
        @memset(wrapped, false);
        const prompt_marks = try allocator.alloc(types.RowPrompt, grid.rows);
        @memset(prompt_marks, .{});
        const tabstops = try allocator.alloc(bool, grid.cols);
        for (tabstops, 0..) |*t, c| t.* = (c % 8 == 0); // 기본 탭스톱: 8칸마다(col 0,8,16,…)

        return .{
            .allocator = allocator,
            .size = grid,
            .cells = cells,
            .wrapped = wrapped,
            .prompt_marks = prompt_marks,
            .tabstops = tabstops,
            .dirty = fullDirty(grid),
            .scroll_bottom = grid.rows - 1,
        };
    }

    /// intern된 OSC 8 URI 저장소를 비운다(RIS 등 하드 리셋 — 이후 셀은 어차피 지워져 링크 id가
    /// 가리킬 대상이 없다). pen_link도 0으로.
    fn clearLinkStore(self: *TerminalCore) void {
        for (self.link_store.items) |uri| self.allocator.free(uri);
        self.link_store.clearRetainingCapacity();
        self.link_ids.clearRetainingCapacity();
        self.pen_link = 0;
    }

    /// RIS(ESC c) 하드 리셋: 화면을 비우고 스크롤백·선택·링크 저장소를 지우고 pen·모드를
    /// 공장 초기 상태로 되돌린다(VT100 RIS 의미론 근사). alt 화면이면 primary로 복귀한다.
    fn fullReset(self: *TerminalCore) void {
        if (self.alt_active) self.leaveAltScreen(false);
        @memset(self.cells, .{});
        @memset(self.wrapped, false);
        @memset(self.prompt_marks, .{});
        self.semantic_state = .unknown;
        self.last_command_exit = null;
        self.clearScrollback(); // sb 비우기 + 선택 해제
        self.clearLinkStore();
        if (self.cwd) |c| { // OSC 7 cwd도 공장 초기화(셸이 다음 프롬프트에 다시 보고)
            self.allocator.free(c);
            self.cwd = null;
        }
        if (self.title) |t| { // OSC 0/2 창 제목도 공장 초기화(xterm RIS가 제목을 리셋하는 의미론)
            self.allocator.free(t);
            self.title = null;
        }
        self.cursor = .{};
        self.pen = .{};
        self.pending_wrap = false;
        self.last_print = null;
        self.scroll_top = 0;
        self.scroll_bottom = self.size.rows - 1;
        self.application_cursor_keys = false;
        self.application_keypad = false; // DECKPAM도 numeric(off)으로 공장 초기화(G10).
        self.cursor_visible = true;
        self.bracketed_paste = false;
        self.focus_events = false;
        self.mouse_tracking = .none;
        self.mouse_format = .x10;
        self.sync_output = false;
        self.kitty_flags = .{};
        self.kitty_images.clear(self.allocator); // RIS는 전송된 kitty graphics 이미지를 전부 비운다
        self.kitty_placements.clearRetainingCapacity(); // placement도 함께 비운다
        self.abortKittyChunk(); // 진행 중이던 chunked 전송도 폐기
        self.grapheme_cluster_mode = false;
        self.charset_g0 = .ascii; // G3 charset도 공장 초기화(G0/G1 ascii, GL=G0).
        self.charset_g1 = .ascii;
        self.charset_gl = 0;
        self.resetTabstops(); // G4 탭스톱도 8칸 기본으로 공장 초기화(xterm RIS).
        self.insert_mode = false; // G6 IRM도 off로 복원.
        self.autowrap = true; // G8 DECAWM도 on(기본)으로 복원.
        self.last_printed_cp = 0; // G5 REP 직전 글자도 비운다.
        self.reverse_screen = false; // G9 DECSCNM도 off(정상)로 복원.
        @memset(&self.palette_override, null); // OSC 4 팔레트 재정의도 공장 초기화(xterm RIS가 팔레트를 리셋).
        self.default_fg_override = null; // OSC 10/11 전경/배경 색 설정도 공장 초기화(theme 기본 복귀).
        self.default_bg_override = null;
        self.alternate_scroll = true; // DEC 1007 공장 기본값(켜짐) — 프로그램이 끈 뒤 RIS면 복원.
        self.origin_mode = false; // DECOM도 공장 기본(off — 화면 절대 좌표)으로 복원.
        self.dirty = fullDirty(self.size);
    }

    pub fn deinit(self: *TerminalCore) void {
        if (self.preedit) |p| self.allocator.free(p);
        if (self.cwd) |c| self.allocator.free(c);
        if (self.title) |t| self.allocator.free(t);
        self.shell_events.deinit(self.allocator);
        for (self.link_store.items) |uri| self.allocator.free(uri);
        self.link_store.deinit(self.allocator);
        self.link_ids.deinit(self.allocator);
        self.allocator.free(self.cells);
        if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
        if (self.prompt_marks.len > 0) self.allocator.free(self.prompt_marks);
        if (self.tabstops.len > 0) self.allocator.free(self.tabstops);
        if (self.saved_cells.len > 0) self.allocator.free(self.saved_cells);
        if (self.saved_wrapped.len > 0) self.allocator.free(self.saved_wrapped);
        if (self.saved_prompt_marks.len > 0) self.allocator.free(self.saved_prompt_marks);
        for (self.scrollback) |slot| {
            if (slot) |cells| self.allocator.free(cells);
        }
        if (self.scrollback.len > 0) self.allocator.free(self.scrollback);
        if (self.sb_wrapped.len > 0) self.allocator.free(self.sb_wrapped);
        if (self.sb_prompt_marks.len > 0) self.allocator.free(self.sb_prompt_marks);
        if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
        if (self.viewport_prompt_marks.len > 0) self.allocator.free(self.viewport_prompt_marks);
        if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
        if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
        if (self.reflow_prompt_marks.len > 0) self.allocator.free(self.reflow_prompt_marks);
        self.response.deinit(self.allocator);
        self.kitty_images.deinit(self.allocator);
        self.kitty_placements.deinit(self.allocator);
        self.kitty_chunk.deinit(self.allocator);
        self.apc_buffer.deinit(self.allocator);
        self.clipboard_write.deinit(self.allocator);
        self.notification_title.deinit(self.allocator);
        self.notification_body.deinit(self.allocator);
        if (self.placement_views.len > 0) self.allocator.free(self.placement_views);
        if (self.image_views.len > 0) self.allocator.free(self.image_views);
        self.* = undefined;
    }

    /// 스크롤백에 보관된 행 수.
    pub fn scrollbackLen(self: *const TerminalCore) usize {
        return self.sb_count;
    }

    /// i=0이 가장 오래된 스크롤백 행. 범위 밖이거나 OOM으로 비어 있으면 null.
    pub fn scrollbackRow(self: *const TerminalCore, i: usize) ?[]const types.Cell {
        if (i >= self.sb_count) return null;
        return self.scrollback[(self.sb_head + i) % self.scrollback.len];
    }

    /// 뷰포트를 delta_up줄만큼 위(과거, 양수)/아래(현재, 음수)로 스크롤한다. [0, sb_count]로 clamp.
    /// 뷰가 바뀌면 화면 전체를 dirty로 표시한다(렌더가 새 윈도를 다시 그리도록).
    pub fn scrollViewport(self: *TerminalCore, delta_up: isize) void {
        // alt screen에서는 스크롤백 뷰가 잠긴다(xterm 동작) — TUI 화면 위로 history가 겹치지 않게.
        if (self.alt_active) return;
        // 지연된 재-wrap을 먼저 수행한다 — sb_count(스크롤 범위)가 재-wrap으로 바뀔 수 있다.
        self.ensureScrollbackRewrapped();
        const max_off: isize = @intCast(self.sb_count);
        var off: isize = @as(isize, @intCast(self.view_offset)) + delta_up;
        if (off < 0) off = 0;
        if (off > max_off) off = max_off;
        const new_off: usize = @intCast(off);
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 뷰포트를 바닥(활성 화면)으로 되돌린다.
    pub fn scrollToBottom(self: *TerminalCore) void {
        if (self.view_offset != 0) {
            self.view_offset = 0;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 절대 행 abs가 뷰포트 세로 중앙쯤에 오도록 스크롤한다(스크롤백 Find가 현재 매치를 화면에 보일 때).
    /// 중앙 배치라 상단 Find 오버레이에 매치가 가리지 않는다. alt screen에선 스크롤백이 잠겨 무동작
    /// (jumpToPrompt와 같은 규율). [0, sb_count]로 clamp.
    pub fn scrollToAbs(self: *TerminalCore, abs: usize) void {
        if (self.alt_active) return;
        self.ensureScrollbackRewrapped(); // sb_count(절대 좌표 범위)가 재-wrap으로 바뀔 수 있다
        const total = self.sb_count + self.size.rows;
        if (total == 0) return;
        // 매치를 뷰포트 세로 중앙(target_top = abs - rows/2, saturating)에 둔다.
        const half = self.size.rows / 2;
        const target_top = if (abs > half) abs - half else 0;
        const new_off: usize = if (target_top < self.sb_count) self.sb_count - target_top else 0; // 활성 행이면 바닥
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 절대 행(스크롤백 0..sb_count-1, 이어서 활성 화면)의 OSC 133 정보(분류+종료코드). 범위 밖은 기본값.
    fn promptAtAbs(self: *const TerminalCore, abs: usize) types.RowPrompt {
        if (abs < self.sb_count) return self.scrollbackRowPrompt(abs);
        const active = abs - self.sb_count;
        if (active < self.prompt_marks.len) return self.prompt_marks[active];
        return .{};
    }

    fn isPromptish(t: types.SemanticPrompt) bool {
        return t == .prompt or t == .input;
    }

    /// 절대 행 abs가 "프롬프트 블록의 시작"인지(점프 네비게이션·거터 타깃). 프롬프트/입력 run의 첫
    /// 행 — 직전 행이 프롬프트/입력이 아닌 곳. 명령 출력(.command)·미분류가 블록을 가른다.
    fn isPromptStart(self: *const TerminalCore, abs: usize) bool {
        if (!isPromptish(self.promptAtAbs(abs).kind)) return false;
        if (abs == 0) return true;
        return !isPromptish(self.promptAtAbs(abs - 1).kind);
    }

    /// 절대 행 abs의 종료코드를 설정한다(활성/스크롤백 통일). 거터 색 결정용.
    fn setPromptExitAtAbs(self: *TerminalCore, abs: usize, exit: i16) void {
        if (abs >= self.sb_count) {
            const active = abs - self.sb_count;
            if (active < self.prompt_marks.len) self.prompt_marks[active].exit = exit;
        } else if (self.sb_prompt_marks.len > 0) {
            self.sb_prompt_marks[(self.sb_head + abs) % self.sb_prompt_marks.len].exit = exit;
        }
    }

    /// 방금 끝난 명령(OSC 133 D)의 종료코드를 그 명령의 프롬프트 시작 행에 스탬프한다 — 커서의
    /// 절대 행에서 위로 가장 가까운 isPromptStart를 찾는다. 프롬프트가 이미 스크롤백으로 밀려났어도
    /// 거기까지 스캔해 찾는다. 못 찾으면(분류 없음) 무동작.
    /// 알려진 엣지(실 zsh에선 도달 안 함): C가 B와 같은 행에서(개행 없이) 와 입력 행이 .command로
    /// 재분류되면, 그 명령엔 promptish 시작 행이 없어 스캔이 '이전' 블록을 찍을 수 있다. 실제 zsh는
    /// Enter의 개행이 C를 새 행에 두므로 입력 행이 .input으로 남아 안전하다(합성 스트림 한정 엣지).
    fn stampPromptExit(self: *TerminalCore, exit: i16) void {
        var abs = self.sb_count + self.cursor.row + 1;
        while (abs > 0) {
            abs -= 1;
            if (self.isPromptStart(abs)) {
                self.setPromptExitAtAbs(abs, exit);
                return;
            }
        }
    }

    /// 이전(dir<0, 과거/위)/다음(dir>0, 최근/아래) 프롬프트 블록 시작으로 뷰포트를 스크롤한다.
    /// OSC 133 분류가 있어야 동작(셸 통합 필요). 타깃을 뷰포트 맨 위에 두고, 타깃이 활성 화면이면
    /// 바닥으로 간다. 찾으면 true. alt screen·분류 없음·해당 방향에 프롬프트 없음이면 false.
    pub fn jumpToPrompt(self: *TerminalCore, dir: i8) bool {
        if (self.alt_active) return false;
        self.ensureScrollbackRewrapped(); // sb_count(절대 좌표 범위)가 재-wrap으로 바뀔 수 있다
        const total = self.sb_count + self.size.rows;
        if (total == 0) return false;
        const top = self.sb_count - @min(self.view_offset, self.sb_count); // 현재 뷰포트 맨 위 절대 행(underflow 가드)
        var target: ?usize = null;
        if (dir < 0) {
            var r = top;
            while (r > 0) {
                r -= 1;
                if (self.isPromptStart(r)) {
                    target = r;
                    break;
                }
            }
        } else {
            var r = top + 1;
            while (r < total) : (r += 1) {
                if (self.isPromptStart(r)) {
                    target = r;
                    break;
                }
            }
        }
        const t = target orelse return false;
        const new_off: usize = if (t < self.sb_count) self.sb_count - t else 0; // 활성 행이면 바닥
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
        return true;
    }

    /// 현재 위로 스크롤한 줄 수(0=바닥).
    pub fn viewOffset(self: *const TerminalCore) usize {
        return self.view_offset;
    }

    /// 보이는 행 r(0..rows-1)의 cells. view_offset만큼 [스크롤백 ++ 활성]을 위로 본 윈도다. 윗부분
    /// view_offset줄은 가장 최근 스크롤백, 나머지는 활성 화면 윗부분이다. 스크롤백 행이 비었으면(OOM)
    /// 빈 슬라이스를 준다. resize로 폭이 달라진 스크롤백 행은 저장된 폭 그대로 — 렌더가 clamp/pad한다.
    pub fn viewportRow(self: *const TerminalCore, r: u16) []const types.Cell {
        const ci = self.sb_count - self.view_offset + r; // content index (sb_count>=view_offset 보장)
        if (ci < self.sb_count) {
            return self.scrollbackRow(ci) orelse &.{};
        }
        const active_row = ci - self.sb_count;
        const start = active_row * self.size.cols;
        return self.cells[start .. start + self.size.cols];
    }

    /// 보이는 뷰포트에 blink(SGR 5) 셀이 하나라도 있는가. app이 blink 위상을 진행/재빌드할지 게이트로 쓴다
    /// (blink 글자가 없으면 idle 재투영을 안 한다). view_offset==0(미스크롤)이면 활성 셀만 보는 싸다.
    pub fn viewportHasBlink(self: *const TerminalCore) bool {
        var r: u16 = 0;
        while (r < self.size.rows) : (r += 1) {
            for (self.viewportRow(r)) |cell| {
                if (cell.style.blink) return true;
            }
        }
        return false;
    }

    /// 보이는 행 r의 OSC 133 정보(viewportRow와 같은 [스크롤백 ++ 활성] 윈도 인덱싱).
    pub fn viewportRowPrompt(self: *const TerminalCore, r: u16) types.RowPrompt {
        const ci = self.sb_count - @min(self.view_offset, self.sb_count) + r; // underflow 가드(다른 호출부와 동일)
        if (ci < self.sb_count) return self.scrollbackRowPrompt(ci);
        return self.prompt_marks[ci - self.sb_count];
    }

    /// scroll로 위로 밀려나는 맨 윗줄을 스크롤백 ring에 보관한다. 슬롯 버퍼를 재사용해(같은 길이면
    /// memcpy만) 매 scroll에 alloc하지 않는다. OOM이면 그 행은 보관하지 않고 넘어간다(best-effort).
    /// i=0이 가장 오래된 스크롤백 행의 soft-wrap 플래그.
    pub fn scrollbackRowWrapped(self: *const TerminalCore, i: usize) bool {
        if (i >= self.sb_count or self.sb_wrapped.len == 0) return false;
        return self.sb_wrapped[(self.sb_head + i) % self.sb_wrapped.len];
    }

    /// i번째 스크롤백 행의 OSC 133 정보(i=0이 가장 오래된 행). sb_wrapped와 같은 ring 인덱싱.
    /// 없거나 범위 밖이면 기본값({.unknown, null}).
    pub fn scrollbackRowPrompt(self: *const TerminalCore, i: usize) types.RowPrompt {
        if (i >= self.sb_count or self.sb_prompt_marks.len == 0) return .{};
        return self.sb_prompt_marks[(self.sb_head + i) % self.sb_prompt_marks.len];
    }

    /// 붙여넣기 바이트를 PTY 입력으로 인코딩한다: 개행을 CR로 정규화(\r\n/\n -> \r — 셸 입력의
    /// 줄바꿈 관례)하고, 프로그램이 bracketed paste(DECSET 2004)를 켰으면 ESC[200~ ... ESC[201~로
    /// 감싼다(타이핑과 구분돼 자동 들여쓰기/즉시 실행 방지). 호출자가 free한다.
    pub fn encodePaste(self: *const TerminalCore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[200~");
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b == '\r' or b == '\n') {
                try out.append(allocator, '\r');
                if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1; // CRLF는 한 번만
            } else if (b == 0x1b) {
                // 보안: 붙여넣기 본문의 ESC를 공백으로 치환한다. 안 그러면 악성 클립보드가 ESC[201~
                // 를 심어 bracketed paste 괄호를 일찍 닫고, 뒤따르는 \r-종료 바이트가 "타이핑"으로
                // 실행된다(고전적 paste 인젝션). bracketed paste를 안 쓸 때도 ESC 시퀀스가 그대로
                // 터미널에 주입되는 걸 막는다. ECMA-48의 C1/CSI는 ESC로 시작하므로 ESC만 막으면
                // 시퀀스가 무력화된다. Ghostty(input/paste.zig)도 같은 보호를 한다.
                try out.append(allocator, ' ');
            } else {
                try out.append(allocator, b);
            }
        }
        if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[201~");
        return try out.toOwnedSlice(allocator);
    }

    /// 선택 시작(마우스 다운). 뷰포트 행/열을 받아 절대 행으로 저장한다. 미뤄둔 스크롤백 재-wrap이
    /// 있으면 먼저 끝낸다 — 안 하면 절대 좌표를 옛 ring 기준으로 만들었다가 드래그 도중 첫
    /// scrollViewport(자동 스크롤 포함)가 재-wrap을 수행하며 선택을 지워버린다.
    pub fn selectionStart(self: *TerminalCore, viewport_row: u16, col: u16) void {
        self.ensureScrollbackRewrapped();
        const abs = self.absRowFromViewport(viewport_row);
        self.selection_anchor = .{ .row = abs, .col = @min(col, self.size.cols -| 1) };
        self.selection_head = self.selection_anchor;
        self.selection_block = false; // 기본 선형 — 블록은 setSelectionBlock으로 켠다(start 직후, Option+드래그)
        self.dirty = fullDirty(self.size);
    }

    /// 블록(직사각형) 선택 모드를 켜고 끈다. platform이 selectionStart 직후 Option+드래그면 켠다(시그니처를
    /// 안 바꿔 기존 selectionStart 호출처 보존). 진행 중 anchor가 없으면(선택 없음) 무시.
    pub fn setSelectionBlock(self: *TerminalCore, on: bool) void {
        if (self.selection_anchor == null or self.selection_block == on) return;
        self.selection_block = on;
        self.dirty = fullDirty(self.size);
    }

    /// 선택 확장(드래그). anchor가 없으면 무시.
    pub fn selectionExtend(self: *TerminalCore, viewport_row: u16, col: u16) void {
        if (self.selection_anchor == null) return;
        self.selection_head = .{ .row = self.absRowFromViewport(viewport_row), .col = @min(col, self.size.cols -| 1) };
        self.dirty = fullDirty(self.size);
    }

    /// 더블클릭 단어 선택: 클릭한 셀이 속한 비공백 run을 좌우로 확장한다. soft-wrap 경계는
    /// 논리 줄로 이어지므로 행을 넘어 계속 확장한다(wrap된 긴 URL을 통째로 선택). 공백을
    /// 클릭하면 선택하지 않는다(해제).
    pub fn selectWordAt(self: *TerminalCore, viewport_row: u16, col: u16) void {
        self.ensureScrollbackRewrapped(); // selectionStart와 같은 이유(절대 좌표를 최종 ring 기준으로)
        const bounds = self.wordBoundsAt(viewport_row, col) orelse {
            self.selectionClear();
            return;
        };
        self.selection_anchor = bounds.start;
        self.selection_head = bounds.end;
        self.selection_block = false; // 새 선택은 선형 — 블록은 setSelectionBlock으로만 opt-in(selectionStart와 일관)
        self.dirty = fullDirty(self.size);
    }

    /// 클릭 위치가 속한 비공백 run(단어)의 절대 좌표 경계. soft-wrap을 넘어 확장한다.
    /// 공백 위치면 null.
    fn wordBoundsAt(self: *const TerminalCore, viewport_row: u16, col: u16) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
        const abs = self.absRowFromViewport(viewport_row);
        const row_cells = self.absRow(abs) orelse return null;
        const c = @min(col, @as(u16, @intCast(row_cells.len -| 1)));
        if (isBlankCell(row_cells[c])) return null;

        // 왼쪽 경계: 행 안에서 공백까지, 행 시작에 닿으면 이전 행이 soft-wrap으로 이어질 때 계속.
        var start_row = abs;
        var start_col: u16 = c;
        outer_left: while (true) {
            const cells_row = self.absRow(start_row) orelse break;
            while (start_col > 0) {
                if (isBlankCell(cells_row[start_col - 1])) break :outer_left;
                start_col -= 1;
            }
            if (start_row == 0 or !self.absRowWrapped(start_row - 1)) break;
            const prev = self.absRow(start_row - 1) orelse break;
            if (prev.len == 0 or isBlankCell(prev[prev.len - 1])) break;
            start_row -= 1;
            start_col = @intCast(prev.len - 1);
        }

        // 오른쪽 경계: 대칭 — 행 끝에 닿으면 이 행이 soft-wrap일 때 다음 행으로 계속.
        var end_row = abs;
        var end_col: u16 = c;
        outer_right: while (true) {
            const cells_row = self.absRow(end_row) orelse break;
            while (end_col + 1 < cells_row.len) {
                if (isBlankCell(cells_row[end_col + 1])) break :outer_right;
                end_col += 1;
            }
            if (!self.absRowWrapped(end_row)) break;
            const next = self.absRow(end_row + 1) orelse break;
            if (next.len == 0 or isBlankCell(next[0])) break;
            end_row += 1;
            end_col = 0;
        }

        return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
    }

    /// Cmd+hover 위치의 URL 단어 범위(뷰포트 좌표로 클립). URL이 아니면 null. 밑줄 하이라이트
    /// 렌더용 — 단어 run 전체에 밑줄을 긋는다(http 시작 전 괄호까지 포함될 수 있음, 시각 피드백
    /// 용도라 충분).
    /// 절대-행 [start, end] 선형 범위를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null). 선택
    /// 하이라이트와 URL 밑줄이 같은 규칙을 쓰게 공유한다.
    fn clipAbsSpanToViewport(self: *const TerminalCore, start: types.SelectionPoint, end: types.SelectionPoint, block: bool) ?types.SelectionSpan {
        const top_abs = self.sb_count - @min(self.view_offset, self.sb_count);
        const bottom_abs = top_abs + self.size.rows - 1;
        if (end.row < top_abs or start.row > bottom_abs) return null;
        const start_row: u16 = if (start.row < top_abs) 0 else @intCast(start.row - top_abs);
        // 선형은 첫 행이 위로 잘리면 col 0부터(행 흐름), 블록은 col이 모든 행에서 [start.col,end.col] 고정이라
        // 행이 잘려도 그대로 둔다(잘린 위 부분도 같은 col 사각형).
        const start_col: u16 = if (block) start.col else (if (start.row < top_abs) 0 else start.col);
        const end_row: u16 = if (end.row > bottom_abs) self.size.rows - 1 else @intCast(end.row - top_abs);
        const end_col: u16 = if (block) end.col else (if (end.row > bottom_abs) self.size.cols - 1 else end.col);
        return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col }, .block = block };
    }

    /// 클릭 셀의 OSC 8 링크 id(0=없음).
    fn cellLinkAt(self: *const TerminalCore, abs: usize, col: u16) u32 {
        const row_cells = self.absRow(abs) orelse return 0;
        if (col >= row_cells.len) return 0;
        return row_cells[col].link;
    }

    /// 같은 OSC 8 링크 id가 이어지는 셀 run의 절대 좌표 경계. 링크 텍스트 안의 공백도 포함하고
    /// (보이는 텍스트 전체에 밑줄), soft-wrap 경계 너머로도 이어진다. 행이 바뀌는 hard 줄도 같은
    /// id면 잇는다 — 한 링크가 여러 줄에 걸쳐 출력된 경우(개행 포함 echo) 모두 한 링크다.
    fn linkBoundsAt(self: *const TerminalCore, abs: usize, col: u16, id: u32) struct { start: types.SelectionPoint, end: types.SelectionPoint } {
        var start_row = abs;
        var start_col: u16 = col;
        outer_left: while (true) {
            const cells_row = self.absRow(start_row) orelse break;
            while (start_col > 0) {
                if (cells_row[start_col - 1].link != id) break :outer_left;
                start_col -= 1;
            }
            if (start_row == 0) break;
            const prev = self.absRow(start_row - 1) orelse break;
            if (prev.len == 0 or prev[prev.len - 1].link != id) break;
            start_row -= 1;
            start_col = @intCast(prev.len - 1);
        }
        var end_row = abs;
        var end_col: u16 = col;
        outer_right: while (true) {
            const cells_row = self.absRow(end_row) orelse break;
            while (end_col + 1 < cells_row.len) {
                if (cells_row[end_col + 1].link != id) break :outer_right;
                end_col += 1;
            }
            const next = self.absRow(end_row + 1) orelse break;
            if (next.len == 0 or next[0].link != id) break;
            end_row += 1;
            end_col = 0;
        }
        return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
    }

    /// Cmd+클릭/hover 위치가 URL이면 그 run의 시작 셀 절대 좌표를 돌려준다(밑줄 anchor용,
    /// 할당 없음). OSC 8 명시적 링크가 있으면 그것이 우선이고(보이는 텍스트와 무관), 없으면
    /// 화면 글자의 http(s) 휴리스틱(extractUrlAt과 동일 판정)이다.
    pub fn urlAnchorAt(self: *const TerminalCore, viewport_row: u16, col: u16) ?types.SelectionPoint {
        const abs = self.absRowFromViewport(viewport_row);
        const id = self.cellLinkAt(abs, col);
        if (id != 0) return self.linkBoundsAt(abs, col, id).start;
        if (!self.wordIsUrl(viewport_row, col)) return null;
        const bounds = self.wordBoundsAt(viewport_row, col) orelse return null;
        return bounds.start;
    }

    /// 절대 좌표 anchor에서 시작하는 URL 단어의 현재 뷰포트 밑줄 범위. 매 frame 호출돼 스크롤/
    /// 출력/resize 후에도 현재 폭/위치에 맞게 클립된다(stale span OOB 차단).
    pub fn urlSpanAtAbs(self: *const TerminalCore, anchor: types.SelectionPoint) ?types.SelectionSpan {
        const top_abs = self.sb_count - @min(self.view_offset, self.sb_count);
        const bottom_abs = top_abs + self.size.rows - 1;
        if (anchor.row < top_abs or anchor.row > bottom_abs) return null; // anchor가 화면 밖
        const id = self.cellLinkAt(anchor.row, anchor.col);
        if (id != 0) {
            const bounds = self.linkBoundsAt(anchor.row, anchor.col, id);
            return self.clipAbsSpanToViewport(bounds.start, bounds.end, false);
        }
        const vp_row: u16 = @intCast(anchor.row - top_abs);
        const bounds = self.wordBoundsAt(vp_row, anchor.col) orelse return null;
        return self.clipAbsSpanToViewport(bounds.start, bounds.end, false);
    }

    /// Cmd+클릭 위치의 URL을 추출한다(없으면 null). 클릭 셀이 속한 비공백 run(soft-wrap 포함)
    /// 안에서 http:// 또는 https:// 부터 run 끝까지를 URL로 보고, 끝에 붙은 문장 부호(괄호/마침표
    /// 등)는 다듬는다. 호출자가 free한다.
    pub fn extractUrlAt(self: *const TerminalCore, allocator: std.mem.Allocator, viewport_row: u16, col: u16) !?[]u8 {
        // OSC 8 명시적 링크가 우선 — 프로그램이 지정한 URI를 그대로 연다(보이는 텍스트와 무관,
        // 휴리스틱의 문장부호 다듬기도 적용하지 않는다).
        const link_id = self.cellLinkAt(self.absRowFromViewport(viewport_row), col);
        if (link_id != 0) {
            const uri = self.linkUri(link_id) orelse return null;
            return try allocator.dupe(u8, uri);
        }
        const bounds = self.wordBoundsAt(viewport_row, col) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var abs = bounds.start.row;
        while (abs <= bounds.end.row) : (abs += 1) {
            const row_cells = self.absRow(abs) orelse break;
            const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
            const to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
            try appendRowUtf8(&out, allocator, row_cells, from, to);
        }
        const span = urlSpanInWord(out.items) orelse {
            out.deinit(allocator);
            return null;
        };
        const url = try allocator.dupe(u8, out.items[span.start..span.end]);
        out.deinit(allocator);
        return url;
    }

    /// 셀 [from, to) 구간을 UTF-8로 out에 덧붙인다(continuation 셀 건너뜀, combining mark 포함).
    /// extractSelection과 extractUrlAt이 공유 — URL/선택이 같은 글자열을 만들게 한다.
    fn appendRowUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row_cells: []const types.Cell, from: usize, to: usize) !void {
        var c = from;
        while (c < to) : (c += 1) {
            const cell = row_cells[c];
            if (cell.continuation) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
            try out.appendSlice(allocator, buf[0..n]);
            if (cell.combining) |cp| {
                const m = std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..m]);
            }
        }
    }

    /// 단어 글자열에서 http(s):// URL의 [start, end) 바이트 범위를 찾는다(없으면 null). 끝의
    /// 마무리 문장 부호는 다듬되, 열린 '('가 있으면 그만큼의 닫는 ')'는 URL의 일부로 보존한다
    /// (예: Wikipedia의 ".../Foo_(bar)"). 스킴만 있고 본문이 없으면 null.
    fn urlSpanInWord(word: []const u8) ?struct { start: usize, end: usize } {
        const start = std.mem.indexOf(u8, word, "https://") orelse std.mem.indexOf(u8, word, "http://") orelse return null;
        // URL 안의 열린 괄호 수만큼 끝 ')'를 보존한다(괄호 균형).
        var open_parens: usize = 0;
        for (word[start..]) |ch| {
            if (ch == '(') open_parens += 1;
        }
        var end_idx = word.len;
        while (end_idx > start) : (end_idx -= 1) {
            const ch = word[end_idx - 1];
            if (ch == ')' and open_parens > 0) {
                open_parens -= 1; // 균형 잡힌 닫는 괄호는 URL의 일부 — 다듬지 않는다
                break;
            }
            if (ch == '.' or ch == ',' or ch == ')' or ch == ']' or ch == '>' or ch == ';' or ch == '\'' or ch == '"') continue;
            break;
        }
        const scheme_len: usize = if (std.mem.startsWith(u8, word[start..], "https://")) "https://".len else "http://".len;
        if (end_idx <= start + scheme_len) return null; // 스킴만 있고 본문 없음
        return .{ .start = start, .end = end_idx };
    }

    /// 클릭 셀이 속한 단어가 URL인지(할당 없이) 판정한다. hover의 매-mouseMove 비용을 줄이려
    /// extractUrlAt의 alloc 없이 같은 판정만 한다.
    pub fn wordIsUrl(self: *const TerminalCore, viewport_row: u16, col: u16) bool {
        if (self.cellLinkAt(self.absRowFromViewport(viewport_row), col) != 0) return true;
        const bounds = self.wordBoundsAt(viewport_row, col) orelse return false;
        // URL은 보통 한 단어라 짧은 스택 버퍼로 충분하고, 넘치면 URL일 수 있으니 통과시킨다.
        var buf: [2048]u8 = undefined;
        var len: usize = 0;
        var abs = bounds.start.row;
        outer: while (abs <= bounds.end.row) : (abs += 1) {
            const row_cells = self.absRow(abs) orelse break;
            const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
            const to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
            var c = from;
            while (c < to) : (c += 1) {
                const cell = row_cells[c];
                if (cell.continuation) continue;
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.codepoint, &enc) catch continue;
                if (len + n > buf.len) break :outer; // 너무 긴 단어 — 판정 보류, 통과
                @memcpy(buf[len .. len + n], enc[0..n]);
                len += n;
            }
        }
        return urlSpanInWord(buf[0..len]) != null;
    }

    /// 트리플클릭 줄 선택: 클릭한 행이 속한 논리 줄 전체(soft-wrap된 행들 포함)를 선택한다.
    pub fn selectLineAt(self: *TerminalCore, viewport_row: u16) void {
        self.ensureScrollbackRewrapped(); // selectionStart와 같은 이유
        const abs = self.absRowFromViewport(viewport_row);
        if (self.absRow(abs) == null) return;
        var start_row = abs;
        while (start_row > 0 and self.absRowWrapped(start_row - 1)) start_row -= 1;
        var end_row = abs;
        while (self.absRowWrapped(end_row) and self.absRow(end_row + 1) != null) end_row += 1;
        const end_cells = self.absRow(end_row) orelse return;
        self.selection_anchor = .{ .row = start_row, .col = 0 };
        self.selection_head = .{ .row = end_row, .col = @intCast(end_cells.len -| 1) };
        self.selection_block = false; // 새 선택은 선형(selectionStart와 일관)
        self.dirty = fullDirty(self.size);
    }

    /// 전체 내용(스크롤백 + 화면)을 선택한다 — Select All. 절대 좌표라 현재 스크롤 위치(view_offset)와
    /// 무관하게 첫 스크롤백 행(abs 0)부터 마지막 화면 행까지 잡는다. extractSelection이 행별 trailing 공백을
    /// 다듬으므로 빈 마지막 행까지 잡아도 복사 결과는 깔끔하다. 화면 행이 0이면 무동작.
    pub fn selectAll(self: *TerminalCore) void {
        self.ensureScrollbackRewrapped(); // selectLineAt와 같은 이유 — abs 좌표 쓰기 전 스크롤백 rewrap 확정
        if (self.size.rows == 0) return;
        const last_abs = self.sb_count + self.size.rows - 1;
        const end_cells = self.absRow(last_abs) orelse return;
        self.selection_anchor = .{ .row = 0, .col = 0 };
        self.selection_head = .{ .row = last_abs, .col = @intCast(end_cells.len -| 1) };
        self.selection_block = false; // 새 선택은 선형 — Option+드래그 블록 뒤 ⌘A가 직사각형으로 새던 누수 수정
        self.dirty = fullDirty(self.size);
    }

    /// 화면 + 스크롤백을 비운다(⌘K). 베이스/결정: Ghostty `clear_screen`(키바인딩 수렴의 1차 레퍼런스 —
    /// docs/key-input-and-shortcuts.md). 반환값 = 호출자가 셸에 form-feed(0x0C, ^L)를 보내 프롬프트를 맨 위에
    /// 다시 그리게 할지 여부. 코어는 PTY로 못 쓰므로(L1 경계 — docs/io-render-threading.md) "보낼지"만 알려주고
    /// 실제 쓰기는 app_session이 락 밖에서 한다.
    ///
    /// 세 경로(전부 Ghostty와 동작 일치):
    /// 1. alt 화면(vim/less/htop): 무동작(false). 그 화면은 앱이 소유하고 셀을 에뮬레이터가 지우면 앱의 커서
    ///    모델과 어긋난다. clear는 앱 자신(:clear 등)에 맡긴다.
    /// 2. 셸 프롬프트(OSC 133 prompt/input): 화면 전체 + 스크롤백을 비우고 커서를 홈으로 둔 뒤 true 반환 →
    ///    셸이 ^L(clear-screen 위젯)로 프롬프트를 맨 위에 다시 그린다. 셸이 커서를 다시 잡으므로 readline 모델과
    ///    어긋나지 않는다(프롬프트 분류는 셸 통합이 있을 때만 = 그때 ^L이 정상 동작).
    /// 3. 그 외(셸 통합 없음/명령 실행 중): 스크롤백 + 커서 위 행만 비우고 현재 줄과 그 아래·커서는 보존, false.
    ///    커서를 안 옮겨 비통합 셸·실행 중 프로그램의 커서 모델과 어긋나지 않게 하고 form-feed도 안 보낸다.
    pub fn clearScreen(self: *TerminalCore) bool {
        if (self.alt_active) return false;
        if (self.size.rows == 0 or self.size.cols == 0) return false;
        self.pending_wrap = false;
        self.clearScrollback(); // 스크롤백(history)은 항상 비운다 — 프롬프트 위치와 무관, selection도 무효화
        const blank: types.Cell = .{ .style = self.pen };

        if (isPromptish(self.semantic_state)) {
            @memset(self.cells, blank);
            @memset(self.wrapped, false);
            @memset(self.prompt_marks, .{}); // 전체 clear는 OSC 133 분류도 지운다(셸이 곧 재마킹)
            self.semantic_state = .unknown;
            self.cursor = .{ .row = 0, .col = 0 };
            self.last_print = null;
            self.dirty = fullDirty(self.size);
            return true;
        }

        // 비프롬프트: 커서 행 위쪽만 비운다. index(row,0) = 커서 행 시작 셀 인덱스 = 위쪽 행들의 셀 수.
        if (self.cursor.row > 0) {
            const above = self.index(self.cursor.row, 0);
            @memset(self.cells[0..above], blank);
            for (0..self.cursor.row) |r| {
                self.wrapped[r] = false;
                self.prompt_marks[r] = .{};
            }
            self.last_print = null;
            self.dirty = fullDirty(self.size);
        }
        return false;
    }

    /// 스크롤백 + 활성 화면 전체에서 needle을 찾아 절대-좌표 Match로 out에 채운다(out은 먼저 비운다).
    /// 대소문자 무시 부분일치(Ghostty 스크롤백 검색의 기본 — 같은 1차 레퍼런스). 대소문자 무시는 `foldCase`
    /// (ASCII+Latin-1·Greek·Cyrillic 유니코드) — command_palette 필터(ASCII `toLower`)보다 넓다(거기는 영문
    /// 명령명이라 ASCII로 충분; 통일은 후속).
    /// 논리 줄(soft-wrap 이음) 단위로 스캔해 wrap 경계를 넘는 매치도 잡는다. 같은 줄 안에선 비겹침(매치 뒤로
    /// needle 길이만큼 건너뜀, 관례). needle이 비면 무동작. 대소문자 무시는 `foldCase`(ASCII + Latin-1·Greek·
    /// Cyrillic 깔끔한 오프셋 블록 — Latin Ext-A 등은 후속). 스크롤백 Find의 단일 출처(코어 상태) — UI 상태머신
    /// (find_overlay)은 이 결과를 받기만 한다. regex/fuzzy는 후속.
    pub fn findMatches(self: *TerminalCore, allocator: std.mem.Allocator, needle_utf8: []const u8, out: *std.ArrayList(types.Match)) !void {
        out.clearRetainingCapacity();
        if (needle_utf8.len == 0) return;
        self.ensureScrollbackRewrapped(); // abs 좌표 쓰기 전 스크롤백 rewrap 확정(selectAll과 같은 이유)

        // needle을 코드포인트 배열로 디코드(셀 codepoint와 같은 단위로 비교 — 멀티바이트 오프셋 매핑 회피).
        var needle: std.ArrayList(u21) = .empty;
        defer needle.deinit(allocator);
        var nv = std.unicode.Utf8View.init(needle_utf8) catch return; // 깨진 needle은 매치 없음
        var nit = nv.iterator();
        while (nit.nextCodepoint()) |cp| try needle.append(allocator, cp);
        if (needle.items.len == 0) return;

        const total = self.sb_count + self.size.rows;
        // 논리 줄마다 코드포인트 시퀀스(cps)와 각 코드포인트의 절대 좌표(coords)를 만들어 검색하고, 다음 줄에서
        // 버퍼를 재사용한다(스크롤백 전체를 한 문자열로 들지 않음 — 메모리는 가장 긴 논리 줄 하나).
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(allocator);
        var coords: std.ArrayList(types.SelectionPoint) = .empty;
        defer coords.deinit(allocator);

        var abs: usize = 0;
        while (abs < total) {
            cps.clearRetainingCapacity();
            coords.clearRetainingCapacity();
            // 논리 줄 = 현재 abs부터 wrapped=false인 행까지(soft-wrap 이음).
            var line_abs = abs;
            while (true) {
                const row = self.absRow(line_abs) orelse break;
                const wrapped = self.absRowWrapped(line_abs);
                // wrapped 행은 전폭이 실제 내용(우측 끝에서 wrap), 마지막(hard) 행은 뒤 빈칸을 자른다(extractSelection과 같은 규칙).
                const limit: usize = if (wrapped) row.len else trimmedLen(row);
                var col: usize = 0;
                while (col < limit) : (col += 1) {
                    const cell = row[col];
                    if (cell.continuation) continue; // wide glyph의 둘째 슬롯은 건너뜀(코드포인트 1개)
                    try cps.append(allocator, cell.codepoint);
                    try coords.append(allocator, .{ .row = line_abs, .col = @intCast(col) });
                }
                if (!wrapped) break;
                line_abs += 1;
                if (line_abs >= total) break;
            }
            // 이 논리 줄에서 needle 슬라이딩 매치(비겹침).
            var i: usize = 0;
            while (i + needle.items.len <= cps.items.len) {
                if (matchAtIgnoreCase(cps.items[i..], needle.items)) {
                    try out.append(allocator, .{
                        .start = coords.items[i],
                        .end = coords.items[i + needle.items.len - 1],
                    });
                    i += needle.items.len; // 비겹침: 매치 뒤로 건너뜀
                } else i += 1;
            }
            abs = line_abs + 1;
        }
    }

    /// 검색 매치(절대 좌표)를 현재 뷰포트 좌표로 클립한다(화면 밖이면 null) — 선택 하이라이트와 같은 규칙 공유.
    pub fn matchViewportSpan(self: *const TerminalCore, m: types.Match) ?types.SelectionSpan {
        return self.clipAbsSpanToViewport(m.start, m.end, false);
    }

    /// IME 조합 중 텍스트를 설정한다(빈 입력 = 조합 종료/취소). 렌더 합성 전용 상태라 셀
    /// 그리드·커서는 변하지 않는다. 표시는 renderSnapshot이 한다.
    pub fn setPreedit(self: *TerminalCore, bytes: []const u8) !void {
        if (self.preedit) |old| {
            self.allocator.free(old);
            self.preedit = null;
        }
        if (bytes.len > 0) self.preedit = try self.allocator.dupe(u8, bytes);
        self.dirty = fullDirty(self.size);
    }

    pub fn selectionClear(self: *TerminalCore) void {
        if (self.selection_anchor == null) return;
        self.selection_anchor = null;
        self.selection_head = null;
        self.selection_block = false;
        self.dirty = fullDirty(self.size);
    }

    /// 행을 재배치하는 연산이 선택의 절대-행 좌표 불변식을 깨면 선택을 해제하는 단일 chokepoint.
    /// 절대 좌표가 내용을 자연히 따라가는 경우는 전체 화면 LF 스크롤(밀려난 줄이 스크롤백으로 가고
    /// eviction은 shiftSelectionForEviction가 보정)뿐이고, 그 외 모든 재배치(부분 region 스크롤,
    /// IL/DL/RI, alt 전환, resize reflow, ED3 clear)는 좌표가 어긋나므로 해제한다. selectionClear의
    /// 별칭이지만, 호출부가 "왜 해제하나"(불변식 보호)를 드러내게 별도 이름을 둔다.
    fn invalidateSelection(self: *TerminalCore) void {
        self.selectionClear();
    }

    fn shiftSelectionForEviction(self: *TerminalCore) void {
        if (self.selection_anchor == null) return;
        const a = &self.selection_anchor.?;
        const h = &self.selection_head.?;
        if (a.row == 0 or h.row == 0) {
            self.selectionClear();
            return;
        }
        a.row -= 1;
        h.row -= 1;
    }

    fn absRowFromViewport(self: *const TerminalCore, viewport_row: u16) usize {
        // 절대 행 = 스크롤백 시작 기준. 뷰포트 첫 행은 sb_count - view_offset.
        return self.sb_count - @min(self.view_offset, self.sb_count) + viewport_row;
    }

    /// 정규화된 선택(start <= end). 없으면 null.
    fn normalizedSelection(self: *const TerminalCore) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
        const a = self.selection_anchor orelse return null;
        const h = self.selection_head orelse return null;
        if (a.row < h.row or (a.row == h.row and a.col <= h.col)) return .{ .start = a, .end = h };
        return .{ .start = h, .end = a };
    }

    /// 현재 뷰포트에 보이는 선택 범위(렌더용). 화면 밖이면 null. 블록 모드면 col을 행과 무관하게 min/max로
    /// 정렬해 직사각형 span([lo,hi]×[start.row,end.row])으로 낸다(normalizedSelection은 row만 정규화).
    pub fn selectionViewportSpan(self: *const TerminalCore) ?types.SelectionSpan {
        const sel = self.normalizedSelection() orelse return null;
        if (self.selection_block) {
            const lo = @min(sel.start.col, sel.end.col);
            const hi = @max(sel.start.col, sel.end.col);
            return self.clipAbsSpanToViewport(
                .{ .row = sel.start.row, .col = lo },
                .{ .row = sel.end.row, .col = hi },
                true,
            );
        }
        return self.clipAbsSpanToViewport(sel.start, sel.end, false);
    }

    /// 선택된 텍스트를 추출한다(클립보드 복사용). 행 단위 선형 선택 — soft-wrap으로 이어진 행은
    /// 줄바꿈 없이 잇고, hard 줄끝에서만 \n을 넣는다. 각 행은 뒤 빈칸을 trim한다(soft 행 제외).
    /// 블록 모드면 직사각형 추출로 분기한다(각 행 [lo,hi], 항상 행마다 개행).
    pub fn extractSelection(self: *const TerminalCore, allocator: std.mem.Allocator) !?[]u8 {
        const sel = self.normalizedSelection() orelse return null;
        if (self.selection_block) return self.extractBlockSelection(allocator, sel.start, sel.end);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var abs = sel.start.row;
        while (abs <= sel.end.row) : (abs += 1) {
            const row_cells = self.absRow(abs) orelse continue;
            const wrapped_flag = self.absRowWrapped(abs);
            const from: usize = if (abs == sel.start.row) sel.start.col else 0;
            const full_to: usize = if (abs == sel.end.row) @min(@as(usize, sel.end.col) + 1, row_cells.len) else row_cells.len;
            // hard 줄끝(또는 선택 끝 행)은 뒤 빈칸을 잘라 복사한다 — 패딩이 텍스트로 들어가지 않게.
            const to: usize = if (wrapped_flag and abs != sel.end.row) full_to else @max(from, @min(full_to, trimmedLen(row_cells)));
            try appendRowUtf8(&out, allocator, row_cells, from, to);
            if (abs != sel.end.row and !wrapped_flag) try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    /// 블록(직사각형) 선택 추출 — 각 행에서 [lo,hi] 열만(col은 행과 무관, soft-wrap 무시), 행마다 개행.
    /// hi 칸 뒤 빈칸은 trim해 패딩이 텍스트로 안 들어간다(선형 추출과 같은 trimmedLen 규칙). 행이 hi보다
    /// 짧으면 그 행 몫만(빈 줄도 개행은 유지 — 사각형 모양 보존). start/end는 row만 정규화돼 col은 여기서 min/max.
    fn extractBlockSelection(self: *const TerminalCore, allocator: std.mem.Allocator, start: types.SelectionPoint, end: types.SelectionPoint) !?[]u8 {
        const lo: usize = @min(start.col, end.col);
        const hi: usize = @max(start.col, end.col);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var abs = start.row;
        while (abs <= end.row) : (abs += 1) {
            if (self.absRow(abs)) |row_cells| {
                const from: usize = @min(lo, row_cells.len);
                const full_to: usize = @min(hi + 1, row_cells.len);
                const to: usize = @max(from, @min(full_to, trimmedLen(row_cells)));
                try appendRowUtf8(&out, allocator, row_cells, from, to);
            }
            if (abs != end.row) try out.append(allocator, '\n'); // 블록은 행마다 개행(사각형 — soft-wrap 무관)
        }
        return try out.toOwnedSlice(allocator);
    }

    /// 절대 행 -> 셀(스크롤백 또는 활성 화면). 범위 밖이면 null.
    fn absRow(self: *const TerminalCore, abs: usize) ?[]const types.Cell {
        if (abs < self.sb_count) return self.scrollbackRow(abs);
        const active = abs - self.sb_count;
        if (active >= self.size.rows) return null;
        const start = @as(usize, @intCast(active)) * self.size.cols;
        return self.cells[start .. start + self.size.cols];
    }

    fn absRowWrapped(self: *const TerminalCore, abs: usize) bool {
        if (abs < self.sb_count) return self.scrollbackRowWrapped(abs);
        const active = abs - self.sb_count;
        if (active >= self.size.rows) return false;
        return self.wrapped[active];
    }

    /// 스크롤백을 비운다(ED 3). 행 버퍼는 해제하고 ring 슬롯 배열은 유지해 다음 push가 재할당
    /// 없이 다시 쓴다. 뷰포트는 바닥으로 스냅한다(지워진 과거를 보고 있을 수 없으니).
    fn clearScrollback(self: *TerminalCore) void {
        for (self.scrollback) |*slot| {
            if (slot.*) |cells_row| {
                self.allocator.free(cells_row);
                slot.* = null;
            }
        }
        self.sb_head = 0;
        self.sb_count = 0;
        self.view_offset = 0;
        self.invalidateSelection(); // 스크롤백을 지우면 abs 좌표가 무효 — 선택 해제(필드 주석의 약속)
    }

    /// 스크롤백 전체를 새 폭으로 재-wrap한다(resize 시). 활성 화면 reflow와 같은 규칙을 ring에
    /// 적용한다: sb_wrapped로 논리 줄을 복원해 새 폭에 다시 자르고(hard 행 끝 빈칸은 trim, soft
    /// 행은 저장 폭 전체가 내용), wide glyph base가 행 끝에 안 들어가면 먼저 줄을 넘긴다. 재-wrap
    /// 행 수가 cap을 넘으면 가장 오래된 것부터 버린다. OOM이면 통째로 포기하고 기존 ring을
    /// 유지한다(best-effort — 잘못된 절반 상태보다 옛 폭 표시가 낫다).
    /// 지연된 스크롤백 재-wrap을 지금 수행한다(있다면). 과거를 보는 경로(scrollViewport/
    /// renderSnapshot)가 진입할 때 불러, 뷰가 항상 현재 폭 기준의 행 수/내용을 보게 한다.
    fn ensureScrollbackRewrapped(self: *TerminalCore) void {
        if (!self.sb_rewrap_pending) return;
        self.sb_rewrap_pending = false;
        self.rewrapScrollback(self.size.cols);
    }

    fn rewrapScrollback(self: *TerminalCore, new_cols: u16) void {
        if (self.sb_count == 0 or new_cols == 0) return;
        self.selectionClear(); // 행 좌표가 재배치된다 — 선택은 해제가 안전(다른 터미널도 동일)
        _ = self.rewrapScrollbackInner(new_cols, null) catch null;
    }

    /// 보던 위치(옛 스크롤백 행 anchor)를 유지하며 재-wrap한다. 과거를 보는 중 resize가 오면
    /// 바닥으로 튕기지 않고, 그 행이 재-wrap 후 어느 행이 됐는지로 view_offset을 재계산한다
    /// (Ghostty/iTerm2처럼 보던 내용이 그대로 보이게).
    fn rewrapScrollbackAnchored(self: *TerminalCore, new_cols: u16, anchor_row: usize) void {
        if (self.sb_count == 0 or new_cols == 0) return;
        self.selectionClear(); // rewrapScrollback과 동일 — 좌표 재배치

        const new_anchor = self.rewrapScrollbackInner(new_cols, anchor_row) catch {
            // 재-wrap 실패(OOM): ring이 그대로이므로 offset도 그대로 유효하다.
            return;
        };
        if (new_anchor) |row_index| {
            // 뷰 최상단이 그 행을 다시 가리키게: viewportRow(0) = sb_count - view_offset.
            self.view_offset = @min(self.sb_count - @min(row_index, self.sb_count), self.sb_count);
        } else {
            // 앵커 행이 cap 드랍으로 사라졌다 — 남은 가장 오래된 행(맨 위)으로.
            self.view_offset = self.sb_count;
        }
    }

    fn rewrapScrollbackInner(self: *TerminalCore, new_cols: u16, anchor_row: ?usize) !?usize {
        // 1차 패스: 출력 행 수만 센다(할당/복사 없음). cap을 넘는 앞쪽(가장 오래된) 행들은 어차피
        // 버려지므로 2차 패스에서 아예 생성하지 않는다 — 좁힘 재-wrap의 alloc 비용을 절반 가까이
        // 줄인다(perf 게이트 scrollback_rewrap이 1회 비용을 잰다).
        var total_out: usize = 0;
        {
            var i: usize = 0;
            while (i < self.sb_count) {
                var j = i;
                while (j + 1 < self.sb_count and self.scrollbackRowWrapped(j)) j += 1;
                total_out += self.countRewrapRows(i, j, new_cols);
                i = j + 1;
            }
        }
        const keep = @min(total_out, self.max_scrollback);
        const skip = total_out - keep; // 생성 없이 건너뛸 산출 행 수(가장 오래된 쪽)

        var rows: std.ArrayList([]types.Cell) = .empty;
        var wraps: std.ArrayList(bool) = .empty;
        var pmarks: std.ArrayList(types.RowPrompt) = .empty; // 산출 행별 OSC 133 태그(rows와 병렬)
        // 성공 경로에선 행 소유권이 ring으로 넘어가므로(items.len = 0으로 비움), 이 defer는
        // 실패 경로에서만 만든 행들을 해제한다.
        defer {
            for (rows.items) |r| self.allocator.free(r);
            rows.deinit(self.allocator);
            wraps.deinit(self.allocator);
            pmarks.deinit(self.allocator);
        }
        try rows.ensureTotalCapacity(self.allocator, keep);
        try wraps.ensureTotalCapacity(self.allocator, keep);
        try pmarks.ensureTotalCapacity(self.allocator, keep);

        var emitted: usize = 0; // 전체 산출 행 인덱스(skip 비교용)
        var anchor_out: ?usize = null; // anchor_row(옛 행)가 떨어진 새 행 인덱스(skip 반영 전)
        var i: usize = 0;
        while (i < self.sb_count) {
            // 논리 줄 [i, j]: 연속된 soft-wrap 행 + 마지막 행.
            var j = i;
            while (j + 1 < self.sb_count and self.scrollbackRowWrapped(j)) j += 1;
            // 줄의 마지막 산출 행이 물려받을 wrap 플래그: 논리 줄이 스크롤백의 끝을 넘어 활성
            // 화면으로 이어지면(마지막 행의 sb_wrapped=true) 그 경계 연속성을 보존한다.
            const tail_wrap = self.scrollbackRowWrapped(j);
            // 논리 줄은 단일 OSC 133 분류다(lineFeed가 같은 영역을 전파). 분류(kind)는 이 줄의 모든
            // 산출 행이 물려받아 재-wrap 후에도 정렬을 유지한다. 단 종료코드(exit)는 leader 한 행에만
            // 스탬프되므로 줄의 '첫' 산출 행에만 둔다 — 안 그러면 거터 바가 여러 개로 보인다(코드리뷰 #1).
            const line_tag = self.scrollbackRowPrompt(i);
            var line_exit: ?i16 = line_tag.exit;

            var cur: ?[]types.Cell = null;
            errdefer if (cur) |c| self.allocator.free(c);
            var oc: u16 = 0;

            var r = i;
            while (r <= j) : (r += 1) {
                // 앵커 옛 행이 시작되는 시점의 산출 행이 "보던 줄"의 새 위치다(셀 단위 정밀도까지는
                // 불필요 — 행 단위면 보던 내용이 화면 안에 유지된다).
                if (anchor_row != null and r == anchor_row.?) anchor_out = emitted;
                const src = self.scrollbackRow(r) orelse continue;
                // soft 행은 저장 폭 전체가 내용(꽉 찼다는 뜻), hard(마지막) 행은 뒤 빈칸 trim.
                const contrib: usize = if (r < j) src.len else trimmedLen(src);
                var c: usize = 0;
                while (c < contrib) : (c += 1) {
                    const cell = src[c];
                    const needs: u16 = if (cell.width == 2) 2 else 1;
                    if (oc + needs > new_cols) {
                        if (cur) |full| {
                            clearTruncatedWideBase(full); // 마지막 칸의 잘린 wide base 정리(new_cols==1 등)
                            rows.appendAssumeCapacity(full);
                            wraps.appendAssumeCapacity(true);
                            pmarks.appendAssumeCapacity(.{ .kind = line_tag.kind, .exit = line_exit });
                            line_exit = null; // exit는 줄의 첫 산출 행에만
                            cur = null;
                        }
                        emitted += 1;
                        oc = 0;
                    }
                    // skip 범위를 지나서야 행 버퍼를 만든다(버려질 행은 셀 스캔만 하고 할당 생략).
                    if (cur == null and emitted >= skip) {
                        cur = try self.allocator.alloc(types.Cell, new_cols);
                        @memset(cur.?, .{});
                    }
                    if (cur) |dst| dst[oc] = cell;
                    oc += 1;
                }
            }
            // 논리 줄의 마지막 행을 닫는다(내용이 전혀 없던 빈 줄도 한 행으로 보존).
            if (cur == null and emitted >= skip) {
                cur = try self.allocator.alloc(types.Cell, new_cols);
                @memset(cur.?, .{});
            }
            if (cur) |last| {
                clearTruncatedWideBase(last);
                rows.appendAssumeCapacity(last);
                wraps.appendAssumeCapacity(tail_wrap);
                pmarks.appendAssumeCapacity(.{ .kind = line_tag.kind, .exit = line_exit });
                line_exit = null;
                cur = null;
            }
            emitted += 1;
            i = j + 1;
        }

        // 기존 ring 행을 비우고(슬롯 배열은 재사용) 새 행으로 채운다. ring이 아직 lazy 미할당이면
        // sb_count==0이라 여기 못 온다(가드).
        for (self.scrollback) |*slot| {
            if (slot.*) |old_row| {
                self.allocator.free(old_row);
                slot.* = null;
            }
        }
        for (rows.items, 0..) |row_cells, k| {
            self.scrollback[k] = row_cells;
            self.sb_wrapped[k] = wraps.items[k];
            self.sb_prompt_marks[k] = pmarks.items[k]; // 재-wrap된 행과 정렬된 OSC 133 태그
        }
        self.sb_head = 0;
        self.sb_count = rows.items.len;
        // 소유권 이전 완료 — defer가 이중 해제하지 않게 목록을 비운다.
        rows.items.len = 0;

        if (anchor_out) |a| {
            if (a >= skip) return a - skip; // cap 드랍을 반영한 새 행 인덱스
            return null; // 보던 행이 드랍됨
        }
        return null;
    }

    /// 논리 줄 [first, last]가 new_cols로 재-wrap될 때의 산출 행 수(할당/복사 없는 시뮬레이션).
    fn countRewrapRows(self: *const TerminalCore, first: usize, last: usize, new_cols: u16) usize {
        var count: usize = 0;
        var oc: u16 = 0;
        var r = first;
        while (r <= last) : (r += 1) {
            const src = self.scrollbackRow(r) orelse continue;
            const contrib: usize = if (r < last) src.len else trimmedLen(src);
            var c: usize = 0;
            while (c < contrib) : (c += 1) {
                const needs: u16 = if (src[c].width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    count += 1;
                    oc = 0;
                }
                oc += 1;
            }
        }
        return count + 1; // 마지막(열린) 행
    }

    /// 행 슬라이스의 내용 길이(뒤 빈칸 trim). 활성 화면의 trimmedRowLen과 같은 기준을 스크롤백
    /// 행(저장 폭이 현재와 다를 수 있음)에 적용한다.
    fn trimmedLen(row: []const types.Cell) usize {
        var len: usize = row.len;
        while (len > 0) : (len -= 1) {
            if (!isBlankCell(row[len - 1])) break;
        }
        return len;
    }

    /// 대문자를 소문자로 접는다(findMatches 대소문자 무시 비교용). **베이스 = Unicode simple case folding**,
    /// 단 width.zig와 같은 정책(small first table — 깔끔한 오프셋 블록만, 나머지는 후속)으로 **오프셋이 일정한
    /// 블록만** 알고리즘으로 덮는다:
    ///   - ASCII A-Z(+32)
    ///   - Latin-1 Supplement À-Ö·Ø-Þ(U+00C0–D6·D8–DE, +32; × U+00D7는 글자가 아니라 제외)
    ///   - Greek Α-Ρ·Σ-Ω(U+0391–A1·A3–A9, +32; U+03A2 reserved 제외)
    ///   - Cyrillic А-Я(U+0410–042F, +32) / Ѐ-Џ(U+0400–040F, +80)
    /// **미덮음(후속)**: Latin Extended-A(parity가 U+0139에서 뒤집혀 단일 오프셋 불가 — 표가 필요),
    /// ß→ss·İ 등 1:N·로케일 특수 폴딩. 이들은 표/생성기를 들일 때(docs/font·width 정책과 같은 시점) 확장한다.
    fn foldCase(cp: u21) u21 {
        return switch (cp) {
            'A'...'Z' => cp + 32,
            0x00C0...0x00D6, 0x00D8...0x00DE => cp + 32, // Latin-1 À-Ö, Ø-Þ
            0x0391...0x03A1, 0x03A3...0x03A9 => cp + 32, // Greek Α-Ρ, Σ-Ω
            0x0410...0x042F => cp + 32, // Cyrillic А-Я
            0x0400...0x040F => cp + 80, // Cyrillic Ѐ-Џ
            else => cp,
        };
    }

    /// haystack 앞부분이 needle과 대소문자 무시(foldCase)로 일치하는지(needle.len ≤ haystack.len 가정 — 호출자가 보장).
    fn matchAtIgnoreCase(haystack: []const u21, needle: []const u21) bool {
        for (needle, 0..) |n, k| {
            if (foldCase(haystack[k]) != foldCase(n)) return false;
        }
        return true;
    }

    /// 행을 스크롤백에 보관한다. OOM 등으로 실제 보관에 실패하면 false — 호출자(scroll-lock)는
    /// 보관된 경우에만 view_offset을 보정해야 보던 위치가 어긋나지 않는다.
    fn pushScrollback(self: *TerminalCore, row_cells: []const types.Cell, wrapped_flag: bool, mark: types.RowPrompt) bool {
        if (self.max_scrollback == 0) return false;
        if (self.scrollback.len == 0) {
            const ring = self.allocator.alloc(?[]types.Cell, self.max_scrollback) catch return false;
            @memset(ring, null);
            // wrap·semantic 병렬 ring도 함께 할당한다. 하나라도 실패하면 전부 포기해 세 ring 길이를
            // 항상 같게 유지한다((sb_head+i)%len 인덱싱이 어긋나면 안 된다).
            const wring = self.allocator.alloc(bool, self.max_scrollback) catch {
                self.allocator.free(ring);
                return false;
            };
            @memset(wring, false);
            const pring = self.allocator.alloc(types.RowPrompt, self.max_scrollback) catch {
                self.allocator.free(ring);
                self.allocator.free(wring);
                return false;
            };
            @memset(pring, .{});
            self.scrollback = ring;
            self.sb_wrapped = wring;
            self.sb_prompt_marks = pring;
        }
        const cap = self.scrollback.len;
        // 가득 차면 (sb_head+sb_count)%cap == sb_head라, 가장 오래된 슬롯을 재사용해 덮어쓴다.
        const idx = (self.sb_head + self.sb_count) % cap;
        if (self.scrollback[idx]) |existing| {
            if (existing.len == row_cells.len) {
                @memcpy(existing, row_cells);
            } else {
                const dup = self.allocator.dupe(types.Cell, row_cells) catch return false; // OOM이면 옛 행 유지
                self.allocator.free(existing);
                self.scrollback[idx] = dup;
            }
        } else {
            self.scrollback[idx] = self.allocator.dupe(types.Cell, row_cells) catch return false;
        }
        self.sb_wrapped[idx] = wrapped_flag;
        self.sb_prompt_marks[idx] = mark;
        if (self.sb_count == cap) {
            self.sb_head = (self.sb_head + 1) % cap;
            // ring이 가득 차 가장 오래된 행이 밀려나면 절대 행 좌표가 한 칸 당겨진다 — 선택도
            // 따라 보정하고, 선택이 밀려난 행을 포함했으면 해제한다. placement anchor도 같은 보정.
            self.shiftSelectionForEviction();
            self.shiftPlacementsForEviction();
        } else {
            self.sb_count += 1;
        }
        return true;
    }

    pub fn write(self: *TerminalCore, bytes: []const u8) !void {
        // Process output bytes through a small VT escape-sequence state machine
        // (planned in implementation-plan.md: expand the parser only as the
        // shell path needs). ground state still converts UTF-8 to cells; ESC
        // switches into escape/CSI/OSC handling so shell prompt color/cursor
        // sequences are interpreted instead of printed as literal text. State
        // persists across write() calls, so sequences split across PTY reads
        // are handled.
        var index_: usize = 0;
        while (index_ < bytes.len) {
            switch (self.parser) {
                .ground => {
                    if (self.utf8_tail_len != 0) {
                        index_ = try self.completePendingUtf8(bytes, index_);
                        continue;
                    }
                    const byte = bytes[index_];
                    if (byte == 0x1b) {
                        self.parser = .escape;
                        index_ += 1;
                        continue;
                    }

                    const sequence_len = utf8SequenceLength(byte) catch return error.InvalidUtf8;
                    const end = index_ + sequence_len;
                    if (end > bytes.len) {
                        self.storePendingUtf8(bytes[index_..]);
                        return;
                    }

                    const codepoint = decodeUtf8(bytes[index_..end]) catch return error.InvalidUtf8;
                    self.writeCodepoint(codepoint);
                    index_ = end;
                },
                .escape => {
                    self.handleEscapeByte(bytes[index_]);
                    index_ += 1;
                },
                .escape_intermediate => {
                    // ESC <intermediate> <final>: DECALN(ESC # 8)이면 화면을 'E'로 채우고, 아니면 charset 지정
                    // (intermediate '('=G0·')'=G1, final '0'=dec_special·'B'=ascii). 미지원 조합은 ascii로 소비.
                    const final = bytes[index_];
                    if (self.escape_intermediate_byte == '#' and final == '8') {
                        self.decAlign(); // DECALN(G11)
                    } else {
                        self.designateCharset(self.escape_intermediate_byte, final);
                    }
                    self.parser = .ground;
                    index_ += 1;
                },
                .csi => {
                    self.handleCsiByte(bytes[index_]);
                    index_ += 1;
                },
                .osc => {
                    const byte = bytes[index_];
                    // OSC string은 BEL(0x07) 또는 ST(ESC \)로 끝난다. 내용은 버퍼에 모아 종료
                    // 시점에 해석한다(현재 OSC 8 하이퍼링크만 적용, title 등은 소비).
                    if (byte == 0x07) {
                        self.dispatchOsc();
                        self.parser = .ground;
                    } else if (byte == 0x1b) {
                        self.parser = .osc_escape;
                    } else if (self.osc_len < self.osc_buffer.len) {
                        self.osc_buffer[self.osc_len] = byte;
                        self.osc_len += 1;
                    } else {
                        self.osc_overflow = true; // 너무 긴 OSC — 통째로 무시
                    }
                    index_ += 1;
                },
                .osc_escape => {
                    // OSC 안에서 ESC 다음 바이트. ST(ESC \)면 정상 종료로 해석하고, 그 외도
                    // OSC를 끝낸다(관대 처리 — 내용은 버린다).
                    if (bytes[index_] == '\\') self.dispatchOsc();
                    self.parser = .ground;
                    index_ += 1;
                },
                .apc => {
                    const byte = bytes[index_];
                    // APC는 ST(ESC \)로 끝난다. ESC면 apc_escape로, 아니면 버퍼에 모은다(넘치면 overflow
                    // 표시 후 무시 — 거대/악의적 시퀀스 방어). OSC 수집과 동형.
                    if (byte == 0x1b) {
                        self.parser = .apc_escape;
                    } else if (self.apc_buffer.items.len < max_kitty_chunk_bytes) {
                        self.apc_buffer.append(self.allocator, byte) catch {
                            self.apc_overflow = true; // OOM도 폐기(graceful)
                        };
                    } else {
                        self.apc_overflow = true; // 상한 초과 — 거대/악의적 시퀀스 방어
                    }
                    index_ += 1;
                },
                .apc_escape => {
                    // APC 안에서 ESC 다음 바이트. ST(ESC \)면 dispatch, 그 외도 APC를 끝낸다(관대 처리).
                    if (bytes[index_] == '\\') self.dispatchApc();
                    self.parser = .ground;
                    index_ += 1;
                },
                .dcs => {
                    const byte = bytes[index_];
                    // DCS는 ST(ESC \)로만 끝난다(OSC와 달리 BEL 종료 없음). 내용을 모아 종료 시 dispatch.
                    if (byte == 0x1b) {
                        self.parser = .dcs_escape;
                    } else if (self.dcs_len < self.dcs_buffer.len) {
                        self.dcs_buffer[self.dcs_len] = byte;
                        self.dcs_len += 1;
                    } else {
                        self.dcs_overflow = true; // 너무 긴 DCS(Sixel 등 미지원) — 폐기
                    }
                    index_ += 1;
                },
                .dcs_escape => {
                    // DCS 안에서 ESC 다음 바이트. ST(ESC \)면 dispatch, 그 외도 DCS를 끝낸다(관대 처리).
                    if (bytes[index_] == '\\') self.dispatchDcs();
                    self.parser = .ground;
                    index_ += 1;
                },
            }
        }
    }

    /// 종료된 OSC 내용을 코드별로 분기한다. 현재 OSC 8(하이퍼링크)·OSC 133(semantic prompt)을 적용한다.
    fn dispatchOsc(self: *TerminalCore) void {
        if (self.osc_overflow) return; // 2048 버퍼를 넘긴 OSC는 통째로 무시(거대/악의적 시퀀스 방어)
        const body = self.osc_buffer[0..self.osc_len];
        if (std.mem.startsWith(u8, body, "8;")) {
            self.dispatchOscHyperlink(body[2..]);
        } else if (std.mem.startsWith(u8, body, "133;")) {
            self.dispatchOscSemanticPrompt(body[4..]);
        } else if (std.mem.startsWith(u8, body, "7;")) {
            self.dispatchOscCwd(body[2..]);
        } else if (std.mem.startsWith(u8, body, "0;")) {
            self.setWindowTitle(body[2..]); // OSC 0 = 아이콘 이름 + 창 제목(둘 다) — 창 제목으로 받는다
        } else if (std.mem.startsWith(u8, body, "2;")) {
            self.setWindowTitle(body[2..]); // OSC 2 = 창 제목만
        } else if (std.mem.startsWith(u8, body, "10;")) {
            self.dispatchOscDefaultColor(body[3..], 10); // OSC 10 = 전경색 설정/질의
        } else if (std.mem.startsWith(u8, body, "11;")) {
            self.dispatchOscDefaultColor(body[3..], 11); // OSC 11 = 배경색 설정/질의
        } else if (std.mem.eql(u8, body, "110")) {
            self.default_fg_override = null; // OSC 110 = 전경색 리셋(theme 기본 복귀)
        } else if (std.mem.eql(u8, body, "111")) {
            self.default_bg_override = null; // OSC 111 = 배경색 리셋
        } else if (std.mem.startsWith(u8, body, "52;")) {
            self.dispatchOscClipboard(body[3..]); // OSC 52 = 클립보드(파싱+디코드만; 실제 쓰기·정책은 platform)
        } else if (std.mem.startsWith(u8, body, "4;")) {
            self.dispatchOscPalette(body[2..]); // OSC 4 = 256색 팔레트 설정/질의(`<index>;<spec>` 쌍 반복)
        } else if (std.mem.eql(u8, body, "104") or std.mem.startsWith(u8, body, "104;")) {
            // OSC 104 = 팔레트 리셋. 인덱스 없으면(정확히 "104") 전부, "104;1;2"면 그 인덱스만.
            self.dispatchOscPaletteReset(if (body.len > 4) body[4..] else "");
        } else if (std.mem.startsWith(u8, body, "777;")) {
            self.dispatchOscNotify777(body[4..]); // OSC 777 = rxvt 데스크톱 알림(notify;title;body)
        } else if (std.mem.startsWith(u8, body, "9;")) {
            self.dispatchOscNotify9(body[2..]); // OSC 9 = iTerm2 알림(ConEmu 서브커맨드와 충돌 — 가드)
        }
        // OSC 1(아이콘 이름만)은 창 제목과 무관 — 위 분기에 없으니 소비만 하고 저장 안 한다.
    }

    /// OSC 10/11(전경/배경 색) 설정·질의. spec이 `?`면 현재 색(override 또는 주입된 theme)을 xterm 형식
    /// `OSC <code> ; rgb:rrrr/gggg/bbbb ST`로 회신한다(nvim 등이 배경 밝기로 light/dark 테마를 감지). color
    /// spec이면 그 색을 `default_fg/bg_override`에 둔다 — 렌더러 default 색과 화면 clear color를 app이 그
    /// override로 바꾼다(OSC 4 팔레트와 같은 결: 코어가 override 보관, app이 CellColors/clear로 wiring).
    /// theme 기본 RGB는 platform이 setDefaultColors로 주입(코어는 Color.default 추상만 알아 실제 RGB는 받는다).
    /// OSC 110/111이 리셋. 베이스: xterm ctlseqs OSC 10/11.
    fn dispatchOscDefaultColor(self: *TerminalCore, body: []const u8, code: u16) void {
        // 여러 `;` 필드 중 첫 필드만 본다(xterm 연속 설정 `OSC 10 ; fg ; bg`는 후속).
        var it = std.mem.splitScalar(u8, body, ';');
        const spec = it.next() orelse return;
        if (std.mem.eql(u8, spec, "?")) {
            // 질의: override가 있으면 그 색, 없으면 주입된 theme 색을 회신(설정 직후 질의가 set 값을 본다).
            const base = if (code == 10) self.default_fg_rgb else self.default_bg_rgb;
            const ovr = if (code == 10) self.default_fg_override else self.default_bg_override;
            const rgb = ovr orelse base;
            var buf: [40]u8 = undefined;
            // 8-bit 채널을 16-bit로 복제(0xAB → 0xABAB) — xterm 4-hex-per-channel 표준 형식.
            const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                code, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
            }) catch return;
            self.appendResponse(resp);
        } else if (types.parseSpec(spec)) |rgb| {
            // 설정: default 전경/배경 override를 둔다 — 렌더러 default 색을 app이 override로 바꾼다.
            if (code == 10) {
                self.default_fg_override = rgb;
            } else {
                self.default_bg_override = rgb;
            }
        }
    }

    /// OSC 10/11로 설정된 전경/배경 색 override(없으면 null = theme 기본). app이 렌더러 default 색과 화면
    /// clear color를 `override orelse theme`로 정할 때 쓴다(OSC 4 paletteOverride와 같은 결).
    pub fn defaultFgOverride(self: *const TerminalCore) ?types.Rgb {
        return self.default_fg_override;
    }
    pub fn defaultBgOverride(self: *const TerminalCore) ?types.Rgb {
        return self.default_bg_override;
    }

    /// OSC 4 — 256색 팔레트 설정/질의. `<index>;<spec>` 쌍을 반복 파싱한다. spec이 `?`면 현재 색(우선순위
    /// override > config base(idx<16) > 기본 xterm256)을 `OSC 4 ; <index> ; rgb:rrrr/gggg/bbbb ST`로 회신, color
    /// spec이면 그 인덱스를 덮어쓴다. 인덱스는 0..255(parseInt u8 — 256+ 자동 실패→skip). 짝이 안 맞는 끝 토큰은
    /// 버린다. 베이스: xterm ctlseqs OSC 4(`rgb:`/`#` 색 명세). 색 적용은 렌더러가 palette_override+config_palette를
    /// 소비(코어는 표만 보관 — K1 경계). query 응답은 렌더(metal_frame)와 같은 우선순위라 화면·보고가 일치한다.
    fn dispatchOscPalette(self: *TerminalCore, body: []const u8) void {
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |idx_str| {
            const spec = it.next() orelse break; // 쌍이 안 맞는 마지막 index는 무시
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue; // 0..255 밖 → skip
            if (std.mem.eql(u8, spec, "?")) {
                // 렌더(metal_frame.paletteColor)와 동일 우선순위: OSC4 override → config base(idx<16) → xterm256.
                const rgb = self.palette_override[idx] orelse
                    (if (idx < 16) self.config_palette[idx] else null) orelse
                    types.xterm256(idx);
                var buf: [48]u8 = undefined;
                // 8-bit 채널을 16-bit로 복제(0xAB → 0xABAB) — xterm 4-hex-per-channel 표준 응답 형식.
                const resp = std.fmt.bufPrint(&buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                    idx, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b,
                }) catch continue;
                self.appendResponse(resp);
            } else if (types.parseSpec(spec)) |rgb| {
                self.palette_override[idx] = rgb;
            }
        }
    }

    /// OSC 104 — 팔레트 리셋. body가 비면 전부 기본 xterm256으로(override 제거), 아니면 `;`로 나눈 인덱스만.
    /// 베이스: xterm ctlseqs OSC 104.
    fn dispatchOscPaletteReset(self: *TerminalCore, body: []const u8) void {
        if (body.len == 0) {
            @memset(&self.palette_override, null);
            return;
        }
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |s| {
            const idx = std.fmt.parseInt(u8, s, 10) catch continue;
            self.palette_override[idx] = null;
        }
    }

    /// 렌더러가 `.indexed` 색을 풀 때 참조하는 OSC 4 팔레트 override 표(null = 기본 xterm256). app이
    /// CellColors.palette로 wiring한다 — 코어는 셀 픽셀을 모르고 표만 들고 있다(K1 경계).
    pub fn paletteOverride(self: *const TerminalCore) *const [256]?types.Rgb {
        return &self.palette_override;
    }

    /// config theme.palette(ANSI 16색 base)를 주입한다 — OSC 4가 없을 때의 base 레이어. platform이 createTerm에서
    /// appearance.theme.palette로 주입하며, OSC 4 query 응답이 렌더(metal_frame)와 같은 우선순위(override > config >
    /// xterm256)를 보도록 한다. RIS/OSC104는 override만 리셋하고 이 base는 건드리지 않는다(렌더 동작과 일치).
    pub fn setConfigPalette(self: *TerminalCore, palette: [16]?types.Rgb) void {
        self.config_palette = palette;
    }

    /// DECSCNM(G9) 화면 반전 상태. app이 CellColors.screen_reverse·clear color에 반영한다(코어는 셀 색을 안 바꾼다).
    pub fn reverseScreen(self: *const TerminalCore) bool {
        return self.reverse_screen;
    }

    /// OSC 52(클립보드) — `52;<targets>;<base64>`로 system clipboard 쓰기를 요청한다(tmux/nvim이 SSH 너머
    /// `"+y`로 씀). **코어는 파싱+base64 디코드만** 하고 결과를 clipboard_write pending에 둔다 — 실제 clipboard
    /// 쓰기와 정책(osc52.write ask/allow/deny)은 app/platform 책임이다(클립보드는 OS 리소스라 native 소유 —
    /// terminal-compatibility-policy.md "TerminalCore parses OSC52, app/platform layer만 실제 read/write"). 읽기
    /// (data가 `?`)는 보안 표면이 커 코어가 무시한다(원격 세션의 clipboard 탈취 방지 — platform ask UI는 후속).
    /// 베이스: xterm/iTerm2 OSC 52(사실상 표준), 보안 정책은 호환성/보안 정책 문서.
    fn dispatchOscClipboard(self: *TerminalCore, body: []const u8) void {
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse return; // <targets>;<data>
        const data = body[semi + 1 ..];
        if (data.len == 0 or std.mem.eql(u8, data, "?")) return; // 빈 데이터·읽기(?)는 무시(읽기는 후속·정책)
        const dec = std.base64.standard.Decoder;
        const decoded_len = dec.calcSizeForSlice(data) catch return; // 잘못된 base64
        if (decoded_len == 0 or decoded_len > max_clipboard_bytes) return; // 빈/과대 거부(폭주 방어선)
        self.clipboard_write.resize(self.allocator, decoded_len) catch return;
        dec.decode(self.clipboard_write.items, data) catch {
            self.clipboard_write.clearRetainingCapacity();
            return;
        };
    }

    /// OSC 52로 들어온 clipboard 쓰기 요청(디코드된 바이트). 없으면 빈 슬라이스. platform이 정책(allow)을 확인한
    /// 뒤 system clipboard에 쓰고 clearClipboardWrite한다 — 코어는 OS clipboard를 직접 만지지 않는다(경계).
    pub fn pendingClipboardWrite(self: *const TerminalCore) []const u8 {
        return self.clipboard_write.items;
    }

    pub fn clearClipboardWrite(self: *TerminalCore) void {
        self.clipboard_write.clearRetainingCapacity();
    }

    /// OSC 777(rxvt/urxvt) 데스크톱 알림 — `OSC 777 ; notify ; <title> ; <body>`. `notify;` 접두만 처리하고
    /// 나머지를 첫 `;`로 title/body로 가른다(body는 `;` 포함 가능). body가 없으면 빈 문자열. 다른 777 서브타입
    /// (notify 외)은 무시. 베이스: urxvt OSC 777 notify.
    fn dispatchOscNotify777(self: *TerminalCore, body: []const u8) void {
        if (!std.mem.startsWith(u8, body, "notify;")) return; // notify 외 777 서브타입은 미지원(소비만)
        const rest = body["notify;".len..];
        const sep = std.mem.indexOfScalar(u8, rest, ';');
        if (sep) |i| {
            self.setNotification(rest[0..i], rest[i + 1 ..]);
        } else {
            self.setNotification(rest, ""); // body 없는 형태: title만
        }
    }

    /// OSC 9(iTerm2) 데스크톱 알림 — `OSC 9 ; <message>`(title 없음, body=message). **ConEmu 충돌**: OSC 9는
    /// ConEmu가 `9;1`(sleep)·`9;2`(msgbox)·`9;4`(progress)·`9;9`(cwd) 등으로도 쓴다. 이들을 알림으로 오발사하면
    /// (특히 `9;4` progress가 진행바마다 알림 폭탄) 곤란하므로, `<숫자>;...` 형태는 ConEmu 서브커맨드로 보고
    /// 소비만 한다(알림 안 함). **베이스/결정**: iTerm2 OSC 9(body=전체) 기준. ConEmu 분기는 Ghostty osc9가
    /// 유효 서브커맨드만 소비하고 미완성은 알림으로 폴백하는데(예: `9;4`→알림 "4"), maru는 `<숫자>;` 패턴 전체를
    /// 보수적으로 소비해 progress 등 완성 서브커맨드의 오발사를 확실히 막는다(순수 텍스트·단일 숫자 알림만 발사).
    fn dispatchOscNotify9(self: *TerminalCore, body: []const u8) void {
        if (body.len == 0) return;
        if (looksLikeConemu9(body)) return; // `<숫자>;...` → ConEmu 서브커맨드(소비, 알림 안 함)
        self.setNotification("", body); // iTerm2: title 없음, body=메시지 전체
    }

    /// OSC 9 body가 ConEmu 서브커맨드(`<숫자>;...`)처럼 보이는가. 선두 숫자 뒤에 `;`가 오면 true.
    fn looksLikeConemu9(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        return i > 0 and i < s.len and s[i] == ';';
    }

    /// 알림 title/body를 pending에 둔다(소유 버퍼에 복사). 할당 실패면 조용히 폐기(알림은 best-effort).
    fn setNotification(self: *TerminalCore, title: []const u8, notify_body: []const u8) void {
        self.notification_title.clearRetainingCapacity();
        self.notification_body.clearRetainingCapacity();
        self.notification_title.appendSlice(self.allocator, title) catch return;
        self.notification_body.appendSlice(self.allocator, notify_body) catch {
            self.notification_title.clearRetainingCapacity();
            return;
        };
        self.notification_pending = true;
    }

    /// OSC 9/777로 들어온 데스크톱 알림(title, body). 없으면 null. platform이 매 tick drain해 네이티브 알림으로
    /// 띄우고 clearNotification한다 — 코어는 OS 알림을 직접 만지지 않는다(경계, OSC 52와 같은 결).
    pub fn pendingNotification(self: *const TerminalCore) ?struct { title: []const u8, body: []const u8 } {
        if (!self.notification_pending) return null;
        return .{ .title = self.notification_title.items, .body = self.notification_body.items };
    }

    pub fn clearNotification(self: *TerminalCore) void {
        self.notification_pending = false;
        self.notification_title.clearRetainingCapacity();
        self.notification_body.clearRetainingCapacity();
    }

    /// G12 BEL: pending 벨이 있으면 true를 돌려주고 플래그를 비운다(한 번 울리고 소비). platform이 매 tick
    /// 호출해 시스템 벨(NSSound.beep)을 울린다 — 코어는 OS 소리를 직접 내지 않는다(OSC 52/9·777과 같은 경계).
    pub fn takeBell(self: *TerminalCore) bool {
        const had = self.bell_pending;
        self.bell_pending = false;
        return had;
    }

    /// 종료된 APC(ESC _ ... ESC \) 내용을 처리한다. kitty graphics(`ESC _ G ...`)가 유일한 소비자다.
    /// 토대 단계라 현재는 수집만 — command 파싱·이미지 저장·렌더는 후속(audit 5/5 단계적). APC를 안
    /// 받으면 payload가 화면에 텍스트로 새므로(과거 ESC_ 미처리), 수집해서 무시하는 것만으로도 그 누수를
    /// 막는다. 베이스: kitty graphics protocol(APC payload), OSC dispatch와 동형.
    /// 종료된 DCS(ESC P ... ST) 내용을 처리한다. 현재 DECRQSS(`DCS $ q <req> ST`)만 — 그 외 DCS(Sixel 등)는
    /// 미지원이라 소비만 한다(이 상태기계가 그 토대). overflow면 폐기.
    fn dispatchDcs(self: *TerminalCore) void {
        if (self.dcs_overflow) return;
        const body = self.dcs_buffer[0..self.dcs_len];
        if (std.mem.startsWith(u8, body, "$q")) {
            self.dispatchDecrqss(body[2..]);
        }
    }

    /// DECRQSS(`DCS $ q <req> ST`): 현재 설정을 회신한다. 유효하면 `DCS 1 $ r <설정> ST`, 미지원이면
    /// `DCS 0 $ r ST`. req는 질의 설정의 final(`m`=SGR·`r`=DECSTBM·` q`=DECSCUSR). 베이스: xterm/VT420 DECRQSS.
    fn dispatchDecrqss(self: *TerminalCore, req: []const u8) void {
        if (std.mem.eql(u8, req, "m")) {
            self.appendDecrqssSgr();
        } else if (std.mem.eql(u8, req, "r")) {
            // DECSTBM(scroll region) — top;bottom(1-based).
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{ self.scroll_top + 1, self.scroll_bottom + 1 }) catch return;
            self.appendResponse(s);
        } else if (std.mem.eql(u8, req, " q")) {
            // DECSCUSR(커서 스타일) — shape+blink를 DECSCUSR param 1..6으로 역매핑.
            const param: u8 = switch (self.cursor_shape) {
                .block => if (self.cursor_blink) 1 else 2,
                .underline => if (self.cursor_blink) 3 else 4,
                .bar => if (self.cursor_blink) 5 else 6,
            };
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{param}) catch return;
            self.appendResponse(s);
        } else {
            self.appendResponse("\x1bP0$r\x1b\\"); // 미지원 설정 질의 → invalid
        }
    }

    /// DECRQSS SGR 응답: 현재 pen을 SGR 파라미터로 재구성해 `DCS 1 $ r 0;… m ST`로 회신(default 색은 0 reset에
    /// 포함되므로 생략). appendResponse로 조각조각 누적한다.
    fn appendDecrqssSgr(self: *TerminalCore) void {
        self.appendResponse("\x1bP1$r0");
        const s = self.pen;
        if (s.bold) self.appendResponse(";1");
        if (s.dim) self.appendResponse(";2");
        if (s.italic) self.appendResponse(";3");
        if (s.underline) self.appendResponse(";4");
        if (s.blink) self.appendResponse(";5");
        if (s.reverse) self.appendResponse(";7");
        if (s.conceal) self.appendResponse(";8");
        if (s.strikethrough) self.appendResponse(";9");
        if (s.overline) self.appendResponse(";53");
        self.appendSgrColor(s.foreground, true);
        self.appendSgrColor(s.background, false);
        self.appendSgrUnderlineColor(s.underline_color);
        self.appendResponse("m\x1b\\");
    }

    fn appendSgrColor(self: *TerminalCore, c: types.Color, foreground: bool) void {
        var buf: [24]u8 = undefined;
        switch (c) {
            .default => {}, // default(39/49)는 0 reset에 포함 — 생략
            .indexed => |n| {
                const s = if (n < 8)
                    std.fmt.bufPrint(&buf, ";{d}", .{@as(u16, if (foreground) 30 else 40) + @as(u16, n)})
                else if (n < 16)
                    std.fmt.bufPrint(&buf, ";{d}", .{@as(u16, if (foreground) 90 else 100) + @as(u16, n - 8)})
                else
                    std.fmt.bufPrint(&buf, ";{d};5;{d}", .{ @as(u16, if (foreground) 38 else 48), n });
                self.appendResponse(s catch return);
            },
            .rgb => |v| {
                const s = std.fmt.bufPrint(&buf, ";{d};2;{d};{d};{d}", .{ @as(u16, if (foreground) 38 else 48), v.r, v.g, v.b }) catch return;
                self.appendResponse(s);
            },
        }
    }

    fn appendSgrUnderlineColor(self: *TerminalCore, c: types.Color) void {
        var buf: [24]u8 = undefined;
        switch (c) {
            .default => {},
            .indexed => |n| self.appendResponse(std.fmt.bufPrint(&buf, ";58;5;{d}", .{n}) catch return),
            .rgb => |v| self.appendResponse(std.fmt.bufPrint(&buf, ";58;2;{d};{d};{d}", .{ v.r, v.g, v.b }) catch return),
        }
    }

    fn dispatchApc(self: *TerminalCore) void {
        if (self.apc_overflow or self.apc_buffer.items.len == 0) {
            // 한 청크가 4096을 넘쳤다(overflow) — chunked 진행 중이면 그 전송 전체가 손상이라 폐기한다.
            if (self.apc_overflow) self.abortKittyChunk();
            return;
        }
        // kitty graphics(ESC _ G ...)만 처리한다. control(k=v)을 파싱하고, transmit이면 payload(base64)를
        // 디코드해 이미지를 저장한다. payload는 control 다음(';' 이후)이다.
        if (self.apc_buffer.items[0] != 'G') return;
        const body = self.apc_buffer.items[1..];
        const cmd = parseKittyGraphicsCommand(body);
        const payload = if (std.mem.indexOfScalar(u8, body, ';')) |i| body[i + 1 ..] else body[0..0];

        // chunked(m=1): 첫 청크가 control을 갖고, 이후 청크는 payload만 이어 붙인다. m=0에서 누적분을
        // 한 번에 실행한다. 진행 중이 아니고(첫 등장) m=0이면 단일 전송이라 즉시 실행(기존 경로).
        if (self.kitty_chunk_cmd == null and !cmd.more) {
            self.execKittyGraphics(cmd, payload);
            return;
        }
        // chunked 진행 중 도착한 명령이 transmit continuation(a=t/T)이 아니라 독립 명령(delete 등)이면,
        // kitty 명세상 정의되지 않은 interleave다 — 진행 중 chunk를 버리고 새 명령을 즉시 실행한다(code
        // review #3, 사용자 결정). continuation은 a= 생략(기본 t) 또는 t/T라 누적 경로로 떨어진다.
        if (self.kitty_chunk_cmd != null and cmd.action != 't' and cmd.action != 'T') {
            self.abortKittyChunk();
            self.execKittyGraphics(cmd, payload);
            return;
        }
        if (self.kitty_chunk_cmd == null) self.kitty_chunk_cmd = cmd; // 첫 청크의 control 보존
        if (self.kitty_chunk.items.len + payload.len > max_kitty_chunk_bytes) {
            self.abortKittyChunk(); // 폭주 방어선 초과 — 전송 폐기
            return;
        }
        self.kitty_chunk.appendSlice(self.allocator, payload) catch {
            self.abortKittyChunk(); // OOM도 폐기(graceful)
            return;
        };
        if (!cmd.more) { // 마지막 청크 — 첫 청크 control + 누적 payload로 실행
            const first = self.kitty_chunk_cmd.?;
            self.execKittyGraphics(first, self.kitty_chunk.items);
            self.abortKittyChunk();
        }
    }

    /// 진행 중인 chunked 전송을 폐기한다(누적 버퍼 비우고 control 해제). 완료·overflow·OOM·RIS 공용.
    fn abortKittyChunk(self: *TerminalCore) void {
        self.kitty_chunk.clearRetainingCapacity();
        self.kitty_chunk_cmd = null;
    }

    /// kitty graphics APC control의 파싱 결과(주요 key). transmit(s/v/f/o)와 display(나머지) 양쪽 키를
    /// 한 구조체에 담는다 — a 값(t/T/p/d)이 어느 필드를 쓰는지 정한다. 렌더는 후속이다.
    const KittyGraphicsCommand = struct {
        action: u8 = 't', // a: t=transmit / T=transmit+display / q=query / p=display / d=delete
        format: u16 = 32, // f: 24=RGB / 32=RGBA / 100=PNG
        width: u32 = 0, // s: 이미지 픽셀 폭
        height: u32 = 0, // v: 이미지 픽셀 높이
        image_id: u32 = 0, // i
        more: bool = false, // m: 1이면 chunk가 이어짐
        compression: u8 = 0, // o: 'z'=zlib
        // --- display(placement) 키 — a=p/T에서 쓴다. 베이스: kitty graphics protocol display data. ---
        placement_id: u32 = 0, // p: placement 식별자(0=default)
        src_x: u32 = 0, // x: source 사각형 좌상단 x(이미지 픽셀)
        src_y: u32 = 0, // y: source 사각형 좌상단 y
        src_width: u32 = 0, // w: source 사각형 폭(0=전체)
        src_height: u32 = 0, // h: source 사각형 높이(0=전체)
        cell_x_offset: u32 = 0, // X: 첫 셀 내 픽셀 x 오프셋
        cell_y_offset: u32 = 0, // Y: 첫 셀 내 픽셀 y 오프셋
        columns: u32 = 0, // c: 표시할 열 수(0=auto)
        rows: u32 = 0, // r: 표시할 행 수(0=auto)
        z: i32 = 0, // z: z-index(부호 있음)
        no_cursor_move: bool = false, // C=1이면 표시 후 커서를 옮기지 않음
        delete_what: u8 = 'a', // d: 삭제 타깃(a=d일 때). 기본 'a'(전체). 대문자=이미지 데이터도 free, 소문자=placement만
    };

    /// 저장된 kitty graphics placement(표시 중인 이미지 인스턴스). anchor_row는 절대 행(스크롤백
    /// 0..sb_count-1, 이어서 활성 화면)이라 selection/find와 같은 좌표계로 스크롤·eviction에 따라
    /// 보정돼 내용과 함께 움직인다. 렌더 시 renderSnapshot이 뷰포트 상대 types.KittyPlacement로 환산한다.
    /// 셀 단위 크기는 담지 않는다(코어는 셀 픽셀 크기를 모름 — 렌더러가 환산).
    const StoredPlacement = struct {
        image_id: u32,
        placement_id: u32,
        anchor_row: usize, // 절대 행
        anchor_col: u16,
        cell_x_offset: u32,
        cell_y_offset: u32,
        src_x: u32,
        src_y: u32,
        src_width: u32,
        src_height: u32,
        columns: u32,
        rows: u32,
        z: i32,
    };

    /// kitty graphics APC의 control 섹션(`G` 다음 ~ ';' 전)을 파싱한다. `k=v,k=v` 형식 — 주요 key만
    /// 추출하고 나머지는 후속 확장으로 무시한다. value는 단일 비숫자 문자면 그 문자(a/o), 아니면 정수
    /// (f/s/v/i/m) — 어느 key가 문자/정수인지는 kitty 명세 control data가 정한다. payload(base64)는
    /// 토대에선 보지 않는다(디코드·저장은 후속). 베이스: kitty graphics protocol control data.
    fn parseKittyGraphicsCommand(body: []const u8) KittyGraphicsCommand {
        var cmd: KittyGraphicsCommand = .{};
        const control = if (std.mem.indexOfScalar(u8, body, ';')) |i| body[0..i] else body;
        var it = std.mem.splitScalar(u8, control, ',');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (key.len != 1 or val.len == 0) continue; // kitty control key는 모두 1글자
            switch (key[0]) {
                'a' => if (val.len == 1) {
                    cmd.action = val[0];
                },
                'f' => cmd.format = std.fmt.parseInt(u16, val, 10) catch cmd.format,
                's' => cmd.width = std.fmt.parseInt(u32, val, 10) catch 0,
                'v' => cmd.height = std.fmt.parseInt(u32, val, 10) catch 0,
                'i' => cmd.image_id = std.fmt.parseInt(u32, val, 10) catch 0,
                'm' => cmd.more = (val.len == 1 and val[0] == '1'),
                'o' => if (val.len == 1) {
                    cmd.compression = val[0];
                },
                // display(placement) 키. 대/소문자가 다른 키(x/X, y/Y)는 별개 의미라 그대로 구분한다.
                'p' => cmd.placement_id = std.fmt.parseInt(u32, val, 10) catch 0,
                'x' => cmd.src_x = std.fmt.parseInt(u32, val, 10) catch 0,
                'y' => cmd.src_y = std.fmt.parseInt(u32, val, 10) catch 0,
                'w' => cmd.src_width = std.fmt.parseInt(u32, val, 10) catch 0,
                'h' => cmd.src_height = std.fmt.parseInt(u32, val, 10) catch 0,
                'X' => cmd.cell_x_offset = std.fmt.parseInt(u32, val, 10) catch 0,
                'Y' => cmd.cell_y_offset = std.fmt.parseInt(u32, val, 10) catch 0,
                'c' => cmd.columns = std.fmt.parseInt(u32, val, 10) catch 0,
                'r' => cmd.rows = std.fmt.parseInt(u32, val, 10) catch 0,
                'z' => cmd.z = std.fmt.parseInt(i32, val, 10) catch 0, // 부호 있음(텍스트 앞/뒤)
                'C' => cmd.no_cursor_move = (val.len == 1 and val[0] == '1'),
                'd' => if (val.len == 1) {
                    cmd.delete_what = val[0]; // 삭제 타깃 문자(a/A/i/I/z/Z/…)
                },
                else => {}, // 나머지 control key는 토대에선 무시(후속 확장)
            }
        }
        return cmd;
    }

    /// 디코드된 kitty graphics 이미지(픽셀 버퍼를 소유). bpp=3(RGB)/4(RGBA). generation은 storage가
    /// (재)transmit마다 단조 증가로 찍어 주는 업로드 캐시 무효화 키다(렌더러가 image_id별 텍스처를
    /// 이 값이 바뀔 때만 다시 업로드 — K2d).
    const KittyImage = struct {
        id: u32,
        width: u32,
        height: u32,
        bpp: u8,
        data: []u8,
        generation: u64 = 0, // KittyImageStorage.add가 채운다
    };

    /// kitty graphics 이미지 저장소(image_id → KittyImage). 총량 한계로 악의적/대량 전송을 막는다.
    /// 토대(1단계): 같은 id 교체 + 한계 초과 거부 — LRU evict(transmit_time 기준)는 후속이다.
    /// 베이스: kitty graphics protocol image storage. 자료구조(map + total_bytes)는 placement/LRU/
    /// 애니메이션 프레임 없이 image_id→픽셀만 담는 maru 단순 설계다(그 확장은 후속 단계).
    const KittyImageStorage = struct {
        map: std.AutoHashMapUnmanaged(u32, KittyImage) = .{},
        total_bytes: usize = 0,
        /// 세션 내 단조 증가 카운터 — add마다 다음 generation을 찍는다. clear/RIS에서 **리셋하지
        /// 않는다**(같은 image_id가 비운 뒤 재전송돼도 새 generation을 받아 렌더러 캐시가 stale을
        /// 재사용하지 않게). u64라 현실적으로 wrap 없음.
        gen_counter: u64 = 0,
        /// 한 세션이 kitty graphics 이미지로 잡을 수 있는 메모리 상한 — maru가 정한 실용 값이다(kitty
        /// 명세는 상한을 규정하지 않으므로 과대/악의적 전송 폭주를 막는 방어선으로 둔다). 대형 이미지
        /// 수십~수백 장을 담되 무한 누적을 차단하는 선에서 320MB로 잡았다. 한도 초과 시 evict(K4b)로
        /// 자리를 만든다. 필드라 테스트가 작게 설정할 수 있다(Ghostty total_limit과 동형).
        limit: usize = 320 * 1000 * 1000,

        fn deinit(self: *KittyImageStorage, alloc: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |img| alloc.free(img.data);
            self.map.deinit(alloc);
        }
        fn clear(self: *KittyImageStorage, alloc: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |img| alloc.free(img.data);
            self.map.clearRetainingCapacity();
            self.total_bytes = 0;
        }
        /// 이미지를 저장한다 — img.data의 소유권을 가져간다(성공=map 보관, 거부/실패=즉시 free).
        /// 성공 시 새 generation을 찍어(같은 id 교체도 새 값) 렌더러 업로드 캐시를 무효화한다.
        fn add(self: *KittyImageStorage, alloc: std.mem.Allocator, img: KittyImage) void {
            if (self.map.fetchRemove(img.id)) |old| { // 같은 id는 교체(기존 free)
                self.total_bytes -= old.value.data.len;
                alloc.free(old.value.data);
            }
            if (self.total_bytes + img.data.len > self.limit) { // 한계 초과면 거부
                alloc.free(img.data);
                return;
            }
            var stored = img;
            self.gen_counter += 1;
            stored.generation = self.gen_counter;
            self.map.put(alloc, stored.id, stored) catch {
                alloc.free(stored.data);
                return;
            };
            self.total_bytes += stored.data.len;
        }
        fn remove(self: *KittyImageStorage, alloc: std.mem.Allocator, id: u32) void {
            if (self.map.fetchRemove(id)) |old| {
                self.total_bytes -= old.value.data.len;
                alloc.free(old.value.data);
            }
        }
    };

    /// 파싱된 kitty graphics command를 실행한다. transmit(디코드+저장)·display(placement)·delete까지 —
    /// query 응답·애니메이션은 후속. payload는 control(';' 전) 다음 base64다.
    fn execKittyGraphics(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
        switch (cmd.action) {
            't' => self.kittyTransmit(cmd, payload),
            'T' => { // transmit + display(한 command로 저장 후 placement까지)
                self.kittyTransmit(cmd, payload);
                self.kittyDisplay(cmd);
            },
            'p' => self.kittyDisplay(cmd), // 기존 이미지를 placement로 표시
            'd' => self.kittyDelete(cmd), // delete: d= 타깃에 따라 placement(소문자)/이미지까지(대문자) 제거
            else => {}, // q(query)·f/a/c(애니메이션)는 후속
        }
    }

    /// kitty graphics display(a=p/T): 저장된 이미지를 현재 커서 셀에 placement로 건다. 이미지가 없으면
    /// 무시한다(graceful — transmit 실패/미전송 이미지). (image_id, placement_id) 같은 키는 교체한다.
    /// 커서 이동 정책(C): 기본(C≠1)은 이미지 아래로 커서를 내린다 — 단 행 수(r)가 명시됐을 때만이다.
    /// 자동 크기(r 미지정)는 setCellMetrics로 주입된 셀 메트릭이 있으면 이미지 픽셀 높이를 행 span으로 환산해
    /// 내리고(kittyAdvanceRows — 렌더러 buildGpuImages와 같은 `PlacementGeometry` 공유), 메트릭이 없으면
    /// (헤드리스) 옮기지 않는다(K1 fallback). 화면 끝을 넘기는 이동은 스크롤 없이 마지막 행으로 clamp한다(이미지 표시가
    /// 스크롤을 유발하지 않게). 베이스: kitty graphics protocol display.
    fn kittyDisplay(self: *TerminalCore, cmd: KittyGraphicsCommand) void {
        if (cmd.image_id == 0) return;
        if (!self.kitty_images.map.contains(cmd.image_id)) return; // 없는 이미지는 표시 안 함
        self.addOrReplacePlacement(.{
            .image_id = cmd.image_id,
            .placement_id = cmd.placement_id,
            .anchor_row = self.sb_count + self.cursor.row, // 커서의 절대 행
            .anchor_col = self.cursor.col,
            .cell_x_offset = cmd.cell_x_offset,
            .cell_y_offset = cmd.cell_y_offset,
            .src_x = cmd.src_x,
            .src_y = cmd.src_y,
            .src_width = cmd.src_width,
            .src_height = cmd.src_height,
            .columns = cmd.columns,
            .rows = cmd.rows,
            .z = cmd.z,
        });
        if (!cmd.no_cursor_move) {
            const rows_span = self.kittyAdvanceRows(cmd);
            if (rows_span > 0) {
                const target = @as(usize, self.cursor.row) + rows_span;
                self.cursor.row = @intCast(@min(target, self.size.rows - 1));
            }
        }
    }

    /// 셀 픽셀 크기를 platform이 주입한다(폰트·DPI·resize 시 갱신). kitty 자동 크기 이미지의 커서 advance에
    /// 쓴다(마우스 1016이 픽셀을 주입하는 것과 같은 결). 그 외 픽셀↔셀 환산은 렌더러 책임(K1).
    pub fn setCellMetrics(self: *TerminalCore, cell_width_px: u32, cell_height_px: u32) void {
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
    }

    /// 기본 전경/배경 색(theme RGB)을 platform이 주입한다(셀 메트릭과 같은 결). OSC 10/11 색 질의 응답에
    /// 쓴다 — 코어는 Color.default 추상만 알아 실제 theme RGB를 받아야 질의에 답할 수 있다.
    pub fn setDefaultColors(self: *TerminalCore, fg: types.Rgb, bg: types.Rgb) void {
        self.default_fg_rgb = fg;
        self.default_bg_rgb = bg;
    }

    /// kitty display가 커서를 내릴 행 수. rows(r)가 명시되면 그 값, 자동 크기(r 미지정)면 셀 메트릭이 있을 때
    /// 이미지 dest 픽셀 높이를 셀 높이로 올림해 환산한다 — 렌더러 buildGpuImages와 같은 PlacementGeometry를
    /// 써 화면에 그려진 행 수와 어긋나지 않는다. 셀 메트릭 미보유(cell_height_px==0, 헤드리스)면 자동 크기는
    /// 0(K1대로 미이동). 베이스: kitty graphics protocol display(cursor advance), Ghostty gridSize 동작 비교.
    fn kittyAdvanceRows(self: *const TerminalCore, cmd: KittyGraphicsCommand) u16 {
        if (cmd.rows > 0) return @intCast(@min(cmd.rows, @as(u32, std.math.maxInt(u16))));
        if (self.cell_height_px == 0) return 0; // 셀 메트릭 미보유 — 자동 크기 환산 불가
        const img = self.kitty_images.map.get(cmd.image_id) orelse return 0;
        const geom = types.PlacementGeometry.compute(
            img.width,
            img.height,
            cmd.src_x,
            cmd.src_y,
            cmd.src_width,
            cmd.src_height,
            cmd.columns,
            cmd.rows,
            self.cell_width_px,
            self.cell_height_px,
        ) orelse return 0;
        const span = @ceil(geom.dest_h / @as(f32, @floatFromInt(self.cell_height_px)));
        return @intFromFloat(@min(span, 65535.0));
    }

    /// placement를 추가하거나 같은 (image_id, placement_id)면 교체한다. 상한 초과면 거부(graceful),
    /// OOM이면 표시를 포기한다(절대 panic 없음 — 출력 경로 견고성).
    fn addOrReplacePlacement(self: *TerminalCore, p: StoredPlacement) void {
        for (self.kitty_placements.items) |*existing| {
            if (existing.image_id == p.image_id and existing.placement_id == p.placement_id) {
                existing.* = p;
                return;
            }
        }
        if (self.kitty_placements.items.len >= max_kitty_placements) return; // 폭주 방어선
        self.kitty_placements.append(self.allocator, p) catch {};
    }

    /// 특정 image_id의 placement를 모두 제거한다(delete 시 이미지와 함께). 순서를 보존해(orderedRemove)
    /// 노출 순서를 결정적으로 둔다 — placement 수는 작아 비용이 무시할 만하다.
    fn removePlacementsForImage(self: *TerminalCore, image_id: u32) void {
        var i: usize = 0;
        while (i < self.kitty_placements.items.len) {
            if (self.kitty_placements.items[i].image_id == image_id) {
                _ = self.kitty_placements.orderedRemove(i);
            } else i += 1;
        }
    }

    /// (image_id, placement_id) 한 placement만 제거한다(delete d=i + p 지정).
    fn removeOnePlacement(self: *TerminalCore, image_id: u32, placement_id: u32) void {
        for (self.kitty_placements.items, 0..) |p, i| {
            if (p.image_id == image_id and p.placement_id == placement_id) {
                _ = self.kitty_placements.orderedRemove(i);
                return;
            }
        }
    }

    /// kitty graphics delete(a=d). d= 타깃 문자로 무엇을 지울지 정한다. **소문자=placement만 제거**(이미지
    /// 데이터는 남겨 재표시 가능), **대문자=placement + 이미지 데이터까지 free**. 베이스: kitty graphics
    /// protocol(deletion). 핵심 부분집합만 지원: a/A(전체)·i/I(image_id[+placement_id])·z/Z(z-index).
    /// 나머지(c 커서·n 이미지번호·p/q/x/y/r 위치·f 애니메이션)는 셀 span/이미지번호가 필요해 graceful 무시.
    fn kittyDelete(self: *TerminalCore, cmd: KittyGraphicsCommand) void {
        const c = cmd.delete_what;
        const free_image = (c >= 'A' and c <= 'Z'); // 대문자면 이미지 데이터도 free
        const target = if (free_image) c - 'A' + 'a' else c; // 소문자로 정규화
        switch (target) {
            'a' => { // 전체
                self.kitty_placements.clearRetainingCapacity();
                if (free_image) self.kitty_images.clear(self.allocator);
            },
            'i' => { // image_id로(+ 선택적 placement_id)
                if (cmd.image_id == 0) return;
                if (free_image) { // 이미지 + 그 이미지의 모든 placement 제거
                    self.removePlacementsForImage(cmd.image_id);
                    self.kitty_images.remove(self.allocator, cmd.image_id);
                } else if (cmd.placement_id != 0) {
                    self.removeOnePlacement(cmd.image_id, cmd.placement_id);
                } else {
                    self.removePlacementsForImage(cmd.image_id);
                }
            },
            'z' => self.deleteByZ(cmd.z, free_image), // z-index로
            else => {}, // c/n/p/q/x/y/r/f는 미지원(graceful) — 셀 span·이미지번호 필요
        }
    }

    /// z-index가 target과 같은 placement를 제거한다. free_images면 그 placement가 가리키던 이미지도 free하고
    /// (그 이미지의 다른 placement까지 제거해 orphan을 막는다). placement 수가 작아 재시작 비용은 무시할 만하다.
    fn deleteByZ(self: *TerminalCore, target_z: i32, free_images: bool) void {
        var i: usize = 0;
        while (i < self.kitty_placements.items.len) {
            const p = self.kitty_placements.items[i];
            if (p.z == target_z) {
                if (free_images) {
                    const id = p.image_id;
                    self.kitty_images.remove(self.allocator, id);
                    self.removePlacementsForImage(id); // 그 이미지의 모든 placement 제거(배열 변형)
                    i = 0; // 배열이 바뀌었으니 처음부터 다시 스캔
                } else {
                    _ = self.kitty_placements.orderedRemove(i);
                }
            } else i += 1;
        }
    }

    /// scrollback ring이 가득 차 가장 오래된 행이 밀려나면 절대 행 좌표가 한 칸 당겨진다 — placement
    /// anchor도 따라 보정하고, 0행(밀려난 행)에 앵커된 placement는 화면 밖이라 제거한다. selection의
    /// shiftSelectionForEviction과 같은 규율. 베이스: maru 절대-행 좌표계.
    fn shiftPlacementsForEviction(self: *TerminalCore) void {
        var i: usize = 0;
        while (i < self.kitty_placements.items.len) {
            const p = &self.kitty_placements.items[i];
            if (p.anchor_row == 0) {
                _ = self.kitty_placements.orderedRemove(i);
            } else {
                p.anchor_row -= 1;
                i += 1;
            }
        }
    }

    /// 저장된 placement(절대 행)를 뷰포트 상대 types.KittyPlacement로 환산해 재사용 버퍼에 담아
    /// 돌려준다. placement가 없으면 빈 슬라이스(할당 없음). 화면 위/아래로 완전히 벗어났는지의 판단은
    /// 셀 span을 아는 렌더러 몫이라, 코어는 모든 placement를 그대로 환산해 노출한다(row는 i32 — 음수
    /// 가능). top_abs는 뷰포트 최상단의 절대 행이다.
    fn buildPlacementViews(self: *TerminalCore, top_abs: usize) []const types.KittyPlacement {
        const n = self.kitty_placements.items.len;
        if (n == 0) return &.{};
        if (self.placement_views.len != n) {
            if (self.placement_views.len > 0) self.allocator.free(self.placement_views);
            self.placement_views = self.allocator.alloc(types.KittyPlacement, n) catch {
                self.placement_views = &.{};
                return &.{}; // OOM이면 placement 노출만 포기(렌더는 후속이라 영향 없음)
            };
        }
        for (self.kitty_placements.items, 0..) |p, i| {
            const row_i64 = @as(i64, @intCast(p.anchor_row)) - @as(i64, @intCast(top_abs));
            self.placement_views[i] = .{
                .image_id = p.image_id,
                .placement_id = p.placement_id,
                // 행 오프셋은 작은 값이라 i32에 들지만, 극단값은 포화시켜 안전하게 둔다.
                .row = std.math.cast(i32, row_i64) orelse (if (row_i64 < 0) std.math.minInt(i32) else std.math.maxInt(i32)),
                .col = p.anchor_col,
                .cell_x_offset = p.cell_x_offset,
                .cell_y_offset = p.cell_y_offset,
                .src_x = p.src_x,
                .src_y = p.src_y,
                .src_width = p.src_width,
                .src_height = p.src_height,
                .columns = p.columns,
                .rows = p.rows,
                .z = p.z,
            };
        }
        return self.placement_views;
    }

    /// 저장된 kitty graphics 이미지를 KittyImageView로 빌려 재사용 버퍼에 담아 돌려준다. 이미지가
    /// 없으면 빈 슬라이스(할당 없음). 픽셀은 복사하지 않고 storage 버퍼를 가리킨다(zero-copy). map
    /// 순회 순서는 비결정적이지만 렌더러는 image_id로 찾으므로 무관하다.
    fn buildImageViews(self: *TerminalCore) []const types.KittyImageView {
        const n = self.kitty_images.map.count();
        if (n == 0) return &.{};
        if (self.image_views.len != n) {
            if (self.image_views.len > 0) self.allocator.free(self.image_views);
            self.image_views = self.allocator.alloc(types.KittyImageView, n) catch {
                self.image_views = &.{};
                return &.{}; // OOM이면 이미지 노출만 포기(렌더는 후속이라 영향 없음)
            };
        }
        var i: usize = 0;
        var it = self.kitty_images.map.valueIterator();
        while (it.next()) |img| : (i += 1) {
            self.image_views[i] = .{
                .image_id = img.id,
                .width = img.width,
                .height = img.height,
                .bpp = img.bpp,
                .generation = img.generation,
                .pixels = img.data,
            };
        }
        return self.image_views[0..i];
    }

    /// 이미지를 저장하되, 320MB 한도를 넘기면 먼저 evict해 자리를 만든다(K4b). 한 장이 한도보다 크면 거부.
    /// 같은 id 교체분은 회수되니 계산에서 뺀다. evict 정책은 evictKittyImagesFor — placement 없는 것·오래된
    /// 것 우선(kitty 명세 권장). evict 후에도 못 들어가면 add가 한도 체크로 거부한다(graceful, img.data free).
    fn storeKittyImage(self: *TerminalCore, img: KittyImage) void {
        if (img.data.len > self.kitty_images.limit) { // 한 장이 전체 한도 초과 — 불가
            self.allocator.free(img.data);
            return;
        }
        const existing: usize = if (self.kitty_images.map.get(img.id)) |old| old.data.len else 0;
        const after = self.kitty_images.total_bytes - existing + img.data.len;
        if (after > self.kitty_images.limit) {
            self.evictKittyImagesFor(after - self.kitty_images.limit, img.id); // 부족분만큼 자리 확보
        }
        self.kitty_images.add(self.allocator, img); // 같은-id 교체 + 최종 한도 체크(evict 후 통과)
        // add가 한도로 거부하면 같은 id의 기존 이미지는 이미 제거됐고(같은-id 교체 규칙) 새 것도 안 들어가
        // map에 그 id가 없다 — 그 id를 가리키던 placement가 orphan으로 남지 않게 함께 정리한다(code review #8).
        if (!self.kitty_images.map.contains(img.id)) self.removePlacementsForImage(img.id);
    }

    /// 한도 초과 시 부족분(needed 바이트) 이상을 비우도록 이미지를 evict한다(exclude_id·그 이미지는 제외 —
    /// 지금 넣으려는 새 이미지). 한 번에 한 장씩, **placement 없는(안 쓰이는) 것 중 오래된(generation 작은) 것**
    /// 만 고른다(kitty 명세 "unused first"; Ghostty 동작 비교). 화면 표시 중(used)인 이미지는 보호한다 —
    /// 모두 쓰이면 후보가 없어 멈추고(이후 add가 새 이미지를 거부), 화면 이미지를 조용히 지우지 않는다
    /// (code review #9). placement/이미지 수가 작아 비용은 무시할 만하다.
    fn evictKittyImagesFor(self: *TerminalCore, needed: usize, exclude_id: u32) void {
        var freed: usize = 0;
        while (freed < needed) {
            const victim = self.pickKittyEvictionVictim(exclude_id) orelse break;
            const sz = if (self.kitty_images.map.get(victim)) |im| im.data.len else 0;
            self.removePlacementsForImage(victim); // 안전망(victim은 unused라 보통 placement 없음)
            self.kitty_images.remove(self.allocator, victim);
            freed += sz;
        }
    }

    /// evict 후보를 고른다 — **placement 없는(안 쓰이는) 이미지 중** generation 작은(오래된) 것. exclude_id
    /// 제외. 화면 표시 중(placement 있는)인 이미지는 후보에서 빼 보호한다 — 모두 쓰이면 null을 돌려 새 transmit이
    /// 거부되게 한다(화면 이미지를 조용히 지우지 않음, code review #9). 베이스: kitty 명세 "unused first"
    /// (Ghostty graphics_storage evictImage 동작) — maru는 used를 evict하지 않고 보호를 우선한다.
    fn pickKittyEvictionVictim(self: *TerminalCore, exclude_id: u32) ?u32 {
        var best: ?u32 = null;
        var best_gen: u64 = std.math.maxInt(u64);
        var it = self.kitty_images.map.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            if (id == exclude_id) continue;
            if (self.kittyImageHasPlacement(id)) continue; // 화면 표시 중인 이미지는 보호(evict 안 함)
            const gen = kv.value_ptr.generation;
            if (best == null or gen < best_gen) {
                best = id;
                best_gen = gen;
            }
        }
        return best;
    }

    /// 이미지에 살아있는 placement가 있는지(evict 우선순위 판정용).
    fn kittyImageHasPlacement(self: *const TerminalCore, image_id: u32) bool {
        for (self.kitty_placements.items) |p| {
            if (p.image_id == image_id) return true;
        }
        return false;
    }

    /// kitty graphics transmit: base64 payload를 디코드해 RGBA(f=32)/RGB(f=24) 이미지를 저장한다.
    /// zlib(o=z) 압축이면 base64 디코드 후 inflate한다(K3b). PNG(f=100)는 후속(K3c). 베이스: kitty
    /// graphics protocol transmit — RGBA/RGB 직접 픽셀은 base64만 풀면 되고, zlib은 std.compress로 푼다.
    fn kittyTransmit(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
        if (cmd.image_id == 0) return; // 필수 control 누락(저장 키)
        if (cmd.format == 100) return self.kittyTransmitPng(cmd, payload); // PNG는 별도 경로(s/v는 PNG가 자기기술)
        const bpp: u8 = switch (cmd.format) {
            24 => 3,
            32 => 4,
            else => return, // 알 수 없는 format
        };
        if (cmd.width == 0 or cmd.height == 0) return; // raw 픽셀은 치수가 필수
        // 치수(s/v)는 APC에서 상한 없이 오는 u32라 곱이 usize를 넘을 수 있다(악의적 대형 값) — 오버플로면
        // 거부한다(graceful). 안 그러면 Debug/ReleaseSafe에서 panic, ReleaseFast에선 wrap된다(code review).
        const wh = std.math.mul(usize, cmd.width, cmd.height) catch return;
        const expected = std.math.mul(usize, wh, bpp) catch return;

        // base64 디코드 → raw 바이트(압축이면 압축 데이터, 아니면 곧 픽셀).
        const dec = std.base64.standard.Decoder;
        const decoded_len = dec.calcSizeForSlice(payload) catch return; // 잘못된 base64
        if (decoded_len == 0) return;
        if (cmd.compression == 0 and decoded_len != expected) return; // 비압축은 디코드 크기 = 선언 크기여야(early reject)
        const raw = self.allocator.alloc(u8, decoded_len) catch return;
        dec.decode(raw, payload) catch {
            self.allocator.free(raw);
            return;
        };

        // 압축 해제. o=z(zlib)만 지원, 그 외 압축은 거부. 없으면 raw가 곧 픽셀.
        const data: []u8 = switch (cmd.compression) {
            0 => raw,
            'z' => blk: {
                defer self.allocator.free(raw); // 압축 입력은 inflate 후 불필요
                // PNG IDAT 경로와 같은 exact-inflate 공유(중복 제거) — expected로 바운드하고 over-long 거부.
                break :blk png.inflateExact(self.allocator, raw, expected) catch return;
            },
            else => {
                self.allocator.free(raw); // 알 수 없는 압축
                return;
            },
        };
        if (data.len != expected) { // 선언 크기 ≠ 실제 픽셀(inflate가 보장하지만 비압축 경로 가드)
            self.allocator.free(data);
            return;
        }
        self.storeKittyImage(.{
            .id = cmd.image_id,
            .width = cmd.width,
            .height = cmd.height,
            .bpp = bpp,
            .data = data,
        });
    }

    /// kitty graphics transmit PNG(f=100): base64 디코드 후 PNG 디코더로 RGB/RGBA 픽셀을 푼다. 치수·bpp는
    /// PNG가 자기기술하므로 s/v control은 안 본다. 8-bit truecolor만 지원(미지원 변종·malformed는 graceful
    /// 거부 — png.zig). PNG에 추가 압축(o=z)은 미지원(PNG는 이미 압축됨, 실사용 없음). 베이스: kitty graphics
    /// protocol(f=100) + PNG 명세.
    fn kittyTransmitPng(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
        if (cmd.compression != 0) return; // PNG + 추가 압축은 미지원(rare)
        const dec = std.base64.standard.Decoder;
        const decoded_len = dec.calcSizeForSlice(payload) catch return;
        if (decoded_len == 0) return;
        const png_bytes = self.allocator.alloc(u8, decoded_len) catch return;
        defer self.allocator.free(png_bytes); // PNG 파일 바이트는 디코드 후 불필요
        dec.decode(png_bytes, payload) catch return;
        const img = png.decode(self.allocator, png_bytes) catch return; // 미지원/malformed는 graceful 거부
        self.storeKittyImage(.{
            .id = cmd.image_id,
            .width = img.width,
            .height = img.height,
            .bpp = img.bpp,
            .data = img.data, // storeKittyImage→add가 소유권 가져감
        });
    }

    /// OSC 8: `8 ; params ; URI` — URI가 비면 링크 닫기, 있으면 열기(이후 출력 셀에 id가 찍힌다).
    /// params(`id=...` 등)는 무시한다(xterm ctlseqs의 OSC 8 확장 — 시각 묶음 힌트일 뿐).
    /// URI 안의 ';'는 보존된다(두 번째 구분자 이후 전부 URI).
    fn dispatchOscHyperlink(self: *TerminalCore, after_code: []const u8) void {
        const params_end = std.mem.indexOfScalar(u8, after_code, ';') orelse return;
        const uri = after_code[params_end + 1 ..];
        if (uri.len == 0) {
            self.pen_link = 0;
            return;
        }
        self.pen_link = self.internLink(uri) catch 0; // OOM이면 링크 없이 출력(텍스트는 보존)
    }

    /// OSC 7: `7 ; file://<host>/<percent-encoded path>` — 셸이 cwd를 보고한다. VTE(GNOME)가
    /// 정의한 사실상 표준으로(공개 형식 문서 기반, VTE는 LGPL이라 소스 미열람), iTerm2/Terminal.app/
    /// kitty/WezTerm이 채택했다. `file://` 스킴만 받고, host는 무시한 채(로컬 단일 호스트 가정) 첫
    /// '/'부터의 path를 percent-decode해 저장한다. 형식이 안 맞거나 빈 path, OOM이면 기존 cwd를
    /// 유지한다 — 부분/깨진 갱신으로 이전 값을 잃지 않게 한다.
    fn dispatchOscCwd(self: *TerminalCore, body: []const u8) void {
        const scheme = "file://";
        if (!std.mem.startsWith(u8, body, scheme)) return; // file 스킴만(다른 스킴은 무시)
        const authority_and_path = body[scheme.len..];
        // file://<host>/<path> — host(authority)는 첫 '/'까지, path는 그 '/'부터(절대경로라 '/' 포함).
        const slash = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return;
        const raw_path = authority_and_path[slash..];
        if (raw_path.len == 0) return;
        const decoded = self.percentDecodeAlloc(raw_path) catch return; // OOM/실패면 기존 cwd 유지
        if (self.cwd) |old| self.allocator.free(old);
        self.cwd = decoded;
        self.recordShellEvent(.cwd_changed); // 값은 currentCwd()가 권위 — 이벤트는 경계만 표시
    }

    /// `%XX`를 바이트로 디코드한 새 문자열을 돌려준다(호출자 소유). 잘못된 %escape(두 hex가
    /// 아니거나 끝에서 잘림)는 관대하게 '%'를 리터럴로 두고 계속한다 — path 한 글자가 깨졌다고
    /// 전체를 버리지 않는다. UTF-8 바이트는 그대로 통과(셸이 raw로 보내든 %인코드로 보내든 복원).
    fn percentDecodeAlloc(self: *TerminalCore, s: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                    try out.append(self.allocator, s[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                    try out.append(self.allocator, s[i]);
                    i += 1;
                    continue;
                };
                try out.append(self.allocator, hi * 16 + lo);
                i += 3;
            } else {
                try out.append(self.allocator, s[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// OSC 7로 셸이 보고한 현재 cwd(percent-decode된 경로). 한 번도 안 받았으면 빈 슬라이스.
    /// 창 제목 등 platform layer가 읽는다(facade를 통해 노출).
    pub fn currentCwd(self: *const TerminalCore) []const u8 {
        return self.cwd orelse "";
    }

    /// OSC 0/2 창 제목을 설정한다(xterm ctlseqs). 빈 텍스트는 해제(null)로 본다 — `OSC 2 ; ST`로
    /// 앱이 제목을 지우면 cwd basename 폴백으로 돌아간다. OOM이면 제목 없이 둔다(텍스트는 어차피
    /// 그리드에 안 나오므로 손실 없음).
    fn setWindowTitle(self: *TerminalCore, text: []const u8) void {
        if (self.title) |old| self.allocator.free(old);
        self.title = null;
        if (text.len == 0) return; // 빈 제목 = 해제
        self.title = self.allocator.dupe(u8, text) catch null;
    }

    /// 창 제목으로 보여줄 문자열(native 최소 — 우선순위 로직을 Zig가 소유한다). OSC 0/2로 앱이
    /// 지정한 제목이 있으면 그것을, 없으면 cwd의 basename(마지막 경로 요소)을 쓴다. 둘 다 없으면
    /// 빈 슬라이스(platform이 앱 이름 등으로 폴백). 반환은 core 소유 슬라이스(title 또는 cwd의
    /// 부분슬라이스)로 다음 OSC 0/2/7·RIS·destroy까지 유효하다.
    pub fn windowTitle(self: *const TerminalCore) []const u8 {
        if (self.title) |t| return t;
        const cwd = self.currentCwd();
        if (cwd.len == 0) return "";
        return std.fs.path.basename(cwd); // "/Users/me/proj" -> "proj", "/" -> ""
    }

    /// drain되지 않아도 메모리가 무한정 자라지 않게 하는 상한. 한 프롬프트 사이클은 A/B/C/D(+cwd)
    /// ~5개라 프레임마다 drain되면 닿을 일이 없고, 닿으면 새 이벤트를 버리고 overflow 플래그를 세운다.
    const shell_events_cap = 4096;

    /// 셸 의미 이벤트를 스트림에 기록한다(OSC 133/7 dispatch가 호출). cap을 넘거나 OOM이면 드롭하고
    /// overflow를 표시한다 — 조용히 잃지 않고 소비자(디버그 로그)가 드롭을 보고할 수 있게.
    fn recordShellEvent(self: *TerminalCore, event: types.ShellEvent) void {
        if (self.shell_events.items.len >= shell_events_cap) {
            self.shell_events_overflow = true;
            return;
        }
        self.shell_events.append(self.allocator, event) catch {
            self.shell_events_overflow = true;
        };
    }

    /// 기록된 셸 의미 이벤트 스트림(소비 후 `clearShellEvents`로 비운다). 테스트·디버그 로그·후속
    /// trace 직렬화가 같은 슬라이스를 읽는다 — 반환은 core 소유로 다음 clear/append/deinit까지 유효.
    pub fn shellEvents(self: *const TerminalCore) []const types.ShellEvent {
        return self.shell_events.items;
    }

    /// 이벤트 스트림을 비운다(용량은 유지해 재할당 없이 재사용). overflow 플래그도 내린다.
    pub fn clearShellEvents(self: *TerminalCore) void {
        self.shell_events.clearRetainingCapacity();
        self.shell_events_overflow = false;
    }

    /// 마지막 drain 이후 cap을 넘어 이벤트가 드롭됐는가(소비자가 손실을 보고할 수 있게).
    pub fn shellEventsOverflowed(self: *const TerminalCore) bool {
        return self.shell_events_overflow;
    }

    /// OSC 133(semantic prompt): 셸이 프롬프트/입력/출력 경계를 마킹한다. `133 ; <action> [; opts]`.
    /// 명세: freedesktop semantic-prompts.md(FinalTerm 발) + kitty/Ghostty 확장. 동작 비교만 했고
    /// 레퍼런스 코드 표현은 옮기지 않았다(clean-room). 옵션은 liberal하게 파싱 — 모르는 키는 무시한다.
    ///   A/P = 프롬프트 시작, B = 프롬프트 끝·입력 시작, C = 입력 끝·출력 시작, D[;code] = 명령 끝.
    /// 각 마커는 현재 커서 행을 그 영역으로 태깅하고 semantic_state를 갱신한다(lineFeed가 다음 행에
    /// 전파). D는 행을 태깅하지 않고 종료코드만 기록한 뒤 영역을 닫는다(.unknown).
    fn dispatchOscSemanticPrompt(self: *TerminalCore, rest: []const u8) void {
        if (rest.len == 0) return;
        const action = rest[0];
        // action 뒤에 내용이 더 있으면 반드시 ';'로 시작해야 한다(아니면 `Pextra`류 — invalid).
        if (rest.len > 1 and rest[1] != ';') return;
        const opts: []const u8 = if (rest.len > 2) rest[2..] else "";
        const row: u16 = @intCast(@min(self.cursor.row, std.math.maxInt(u16)));
        switch (action) {
            // A(fresh_line_new_prompt)·P(prompt_start) — PR1은 동일 취급(prompt_kind 옵션은 파싱·무시).
            'A', 'P' => {
                self.semantic_state = .prompt;
                self.prompt_marks[self.cursor.row] = .{ .kind = .prompt }; // 새 프롬프트 — exit 리셋
                self.recordShellEvent(.{ .prompt_start = row });
            },
            'B' => {
                self.semantic_state = .input;
                self.prompt_marks[self.cursor.row].kind = .input; // exit는 보존(D가 채움)
                self.recordShellEvent(.{ .input_start = row });
            },
            'C' => {
                self.semantic_state = .command;
                self.prompt_marks[self.cursor.row].kind = .command;
                self.recordShellEvent(.{ .command_start = row });
            },
            'D' => {
                // 첫 ';' 구분 토큰을 종료코드로(없거나 정수 아니면 이전 값 유지 — 명세상 D는 code 없이도 옴).
                const first = if (std.mem.indexOfScalar(u8, opts, ';')) |s| opts[0..s] else opts;
                var exit_clamped: ?i16 = null;
                if (std.fmt.parseInt(i32, first, 10) catch null) |code| {
                    self.last_command_exit = code;
                    exit_clamped = @intCast(std.math.clamp(code, std.math.minInt(i16), std.math.maxInt(i16)));
                    // 이 명령의 프롬프트 시작 행(커서에서 위로 가장 가까운 isPromptStart)에 종료코드를
                    // 스탬프한다 — 거터가 그 행 옆에 ✓(0)/✗(≠0)를 그린다. exit는 행과 함께 carry된다.
                    self.stampPromptExit(exit_clamped.?);
                }
                self.recordShellEvent(.{ .command_end = .{ .row = row, .exit = exit_clamped } });
                self.semantic_state = .unknown; // 명령 끝 — 영역을 닫는다(커서 행은 태깅하지 않음)
            },
            // L(fresh_line)·I·N 등은 수용하되 무동작(분류 상태 변화 없음).
            else => {},
        }
    }

    /// URI를 link_store에 intern하고 id(인덱스+1)를 돌려준다. 같은 URI는 한 번만 저장된다 —
    /// ls --hyperlink처럼 수백 셀이 같은 파일 URI를 가리켜도 문자열은 하나다.
    fn internLink(self: *TerminalCore, uri: []const u8) !u32 {
        if (self.link_ids.get(uri)) |id| return id;
        const owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned);
        const id: u32 = @intCast(self.link_store.items.len + 1);
        try self.link_store.append(self.allocator, owned);
        errdefer _ = self.link_store.pop();
        try self.link_ids.put(self.allocator, owned, id);
        return id;
    }

    /// 링크 id -> URI(없으면 null).
    fn linkUri(self: *const TerminalCore, id: u32) ?[]const u8 {
        if (id == 0 or id > self.link_store.items.len) return null;
        return self.link_store.items[id - 1];
    }

    fn handleEscapeByte(self: *TerminalCore, byte: u8) void {
        switch (byte) {
            '[' => {
                self.beginCsi();
                self.parser = .csi;
            },
            ']' => {
                self.osc_len = 0;
                self.osc_overflow = false;
                self.parser = .osc;
            },
            // APC(ESC _): application program command. kitty graphics(`ESC _ G ...`)가 쓴다. OSC와
            // 동형으로 버퍼에 모아 ESC \(ST)에서 dispatch한다 — 안 받으면 payload가 화면에 텍스트로 샌다.
            '_' => {
                self.apc_buffer.clearRetainingCapacity();
                self.apc_overflow = false;
                self.parser = .apc;
            },
            // DCS(ESC P ... ST): device control string. 현재 DECRQSS(`DCS $ q`)만 처리하고 ST에서 dispatch한다.
            // 안 받으면 payload(예: tmux의 `$q`)가 화면에 텍스트로 샌다. G14 — Sixel/DECDLD의 토대 상태기계.
            'P' => {
                self.dcs_len = 0;
                self.dcs_overflow = false;
                self.parser = .dcs;
            },
            // IND(ESC D): index. CR 없이 한 줄 내림 + 하단 margin이면 scroll region을 위로 민다(LF와 동일).
            'D' => {
                self.lineFeed();
                self.parser = .ground;
            },
            // RI(ESC M): reverse index. 한 줄 올림 + 상단 margin이면 scroll region을 아래로 민다.
            'M' => {
                self.reverseIndex();
                self.parser = .ground;
            },
            // HTS(ESC H): 현재 커서 열에 탭스톱을 설정한다(G4 동적 탭스톱).
            'H' => {
                if (self.cursor.col < self.tabstops.len) self.tabstops[self.cursor.col] = true;
                self.parser = .ground;
            },
            // NEL(ESC E): next line = CR + LF. 커서를 다음 줄 0열로 옮긴다(하단 margin이면 스크롤). G12.
            'E' => {
                const old_cursor = self.cursor;
                self.cursor.col = 0;
                self.markCursorMoveDirty(old_cursor, self.cursor);
                self.lineFeed();
                self.parser = .ground;
            },
            // DECSC(ESC 7)/DECRC(ESC 8): 커서(위치+pen+pending_wrap) 저장/복원. claude CLI 등이
            // 시작 시 `ESC 7, CSI r, ESC 8`로 scroll region을 리셋하는데, CSI r의 부수효과(커서
            // home)를 ESC 8이 되돌린다 — 복원이 없으면 커서가 (0,0)에 남아 UI가 기존 화면 맨 위를
            // 덮는다. DECSET 1048과 같은 저장 슬롯을 쓴다(xterm 동일).
            '7' => {
                self.saveCursorState();
                self.parser = .ground;
            },
            '8' => {
                self.restoreCursorState();
                self.parser = .ground;
            },
            // RIS(ESC c): 하드 리셋. 화면/스크롤백/선택/링크 저장소를 비우고 pen·pen_link·모드를
            // 초기화한다. 안 하면 열린 OSC 8 링크(pen_link)·intern된 URI가 리셋을 넘어 살아남는다.
            'c' => {
                self.fullReset();
                self.parser = .ground;
            },
            // DECKPAM(ESC =)/DECKPNM(ESC >): application/numeric keypad 모드(G10). 모드만 추적(numpad 인코딩은 후속).
            '=' => {
                self.application_keypad = true;
                self.parser = .ground;
            },
            '>' => {
                self.application_keypad = false;
                self.parser = .ground;
            },
            // ESC <intermediate>(0x20..0x2f) <final>: charset designation 등 2바이트 시퀀스. intermediate를
            // 기억해 escape_intermediate가 final과 함께 해석한다(G0 `(` vs G1 `)` 구분).
            0x20...0x2f => {
                self.escape_intermediate_byte = byte;
                self.parser = .escape_intermediate;
            },
            // 그 밖의 ESC <final>(NEL 등)은 A1에서 소비만 한다.
            else => self.parser = .ground,
        }
    }

    fn beginCsi(self: *TerminalCore) void {
        self.csi_params = [_]u16{0} ** max_csi_params;
        self.csi_subparam = [_]bool{false} ** max_csi_params;
        // 항상 최소 1개의 (비어 있을 수도 있는) 파라미터가 있다고 본다.
        self.csi_param_count = 1;
        self.csi_has_digit = false;
        self.csi_marker = 0;
        self.csi_intermediate = 0;
        self.csi_overflow = false;
    }

    /// ';'(is_sub=false)나 ':'(is_sub=true)로 다음 파라미터 슬롯을 연다. ':'로 연 슬롯은
    /// sub-parameter로 표시해, 38/48 확장 색의 colon 형식을 세미콜론 형식과 구분한다.
    fn csiNextParam(self: *TerminalCore, is_sub: bool) void {
        if (self.csi_param_count >= max_csi_params) {
            self.csi_overflow = true;
        } else {
            self.csi_param_count += 1;
            self.csi_subparam[self.csi_param_count - 1] = is_sub;
        }
        self.csi_has_digit = false;
    }

    fn handleCsiByte(self: *TerminalCore, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                self.csi_has_digit = true;
                // 파라미터가 max(16)를 넘으면(';'가 csi_overflow를 세움) 이후 자릿수는 버린다.
                // 안 그러면 17번째+ 파라미터의 숫자가 params[15]에 누적돼 마지막 파라미터를
                // 오염시킨다.
                if (self.csi_overflow) return;
                const slot = self.csi_param_count - 1;
                const digit: u16 = byte - '0';
                const value = self.csi_params[slot];
                // saturating: 손상/악성 입력이 u16을 넘기지 않게 한다.
                self.csi_params[slot] = if (value > (std.math.maxInt(u16) - digit) / 10)
                    std.math.maxInt(u16)
                else
                    value * 10 + digit;
            },
            // ';'는 파라미터 구분자, ':'는 sub-parameter 구분자다. 둘 다 다음 슬롯을 열되,
            // ':'로 연 슬롯은 sub-parameter로 표시해 colon 확장색 형식을 구분한다.
            ';' => self.csiNextParam(false),
            ':' => self.csiNextParam(true),
            // private/marker bytes: < = > ? (예: CSI ? 25 h). 어떤 marker였는지 기억한다.
            0x3c...0x3f => self.csi_marker = byte,
            // intermediate bytes(공백~/): 같은 final이라도 다른 명령이 된다 — 바이트를 기억해
            // (intermediate, final) 튜플로 dispatch한다(아래 dispatchCsi).
            0x20...0x2f => self.csi_intermediate = byte,
            // final byte: 시퀀스를 dispatch하고 ground로 돌아간다.
            0x40...0x7e => {
                self.dispatchCsi(byte);
                self.parser = .ground;
            },
            // ESC는 진행 중인 CSI를 취소하고 새 escape를 시작한다(VT abort-and-restart). 안 하면
            // ESC[ ESC[31m 같은 입력에서 두 번째 시퀀스가 글자로 샌다.
            0x1b => self.parser = .escape,
            // CSI 안의 C0 control(ESC 제외)은 실행하고 CSI 파싱을 계속한다(VT spec). writeCodepoint가
            // CR/LF/Tab/BS를 처리하고 나머지 C0는 버린다. parser는 .csi로 유지된다.
            0x00...0x1a, 0x1c...0x1f => self.writeCodepoint(byte),
            // 그 밖(DEL/high byte)은 CSI를 중단하고 소비한다(관대 처리).
            else => self.parser = .ground,
        }
    }

    /// i번째 CSI 파라미터를 raw로 돌려준다(없으면 0). erase mode처럼 0이 유효값인 곳에 쓴다.
    fn csiRawParam(self: *const TerminalCore, i: usize) u16 {
        const count = @min(self.csi_param_count, max_csi_params);
        return if (i >= count) 0 else self.csi_params[i];
    }

    /// i번째 CSI 파라미터(없거나 0이면 default). cursor move처럼 0을 1로 보는 곳에 쓴다.
    fn csiParam(self: *const TerminalCore, i: usize, default: u16) u16 {
        const value = self.csiRawParam(i);
        return if (value == 0) default else value;
    }

    fn dispatchCsi(self: *TerminalCore, final: u8) void {
        // intermediate가 붙은 시퀀스는 bare final과 다른 명령이다 — 아는 (intermediate, final)
        // 조합만 dispatch하고 나머지는 소비한다(Williams VT500 파서의 튜플 dispatch 의미).
        if (self.csi_intermediate != 0) {
            switch (self.csi_intermediate) {
                ' ' => switch (final) {
                    'q' => self.setCursorStyle(self.csiRawParam(0)), // DECSCUSR
                    else => {},
                },
                '$' => switch (final) {
                    // DECRQM(CSI ? Ps $ p): private mode 상태 질의. 앱(terminal-unicode-core 등)이
                    // mode 2027 지원 여부를 이걸로 먼저 묻고, "지원함"이면 DECSET 2027로 켠다. 응답이
                    // 없으면 미지원으로 보고 안 켜므로, 우리가 아는 모드는 현재 상태를 보고한다.
                    'p' => if (self.csi_marker == '?') self.reportPrivateMode(self.csiRawParam(0)),
                    else => {},
                },
                else => {}, // `$r`(DECCARA) 등 미지원 조합은 무시
            }
            return;
        }
        // marker별 처리: '?'는 DEC private mode(DECSET/DECRST), '>'는 secondary DA. 그 외 marker
        // 시퀀스(>m modifyOtherKeys, <u kitty 등)는 소비만 한다 — bare final로 흘리면 SGR 등을
        // 오염시킨다.
        if (self.csi_marker != 0) {
            switch (self.csi_marker) {
                '?' => switch (final) {
                    'h' => self.setPrivateModes(true),
                    'l' => self.setPrivateModes(false),
                    // kitty keyboard(CSI ? u): 현재 flag 스택 최상단을 CSI ? flags u로 보고. 앱이 지원
                    // 여부·현재 모드를 감지한다(flags=0이면 비활성). 베이스: kitty keyboard protocol query.
                    'u' => self.reportKittyFlags(),
                    else => {},
                },
                '>' => switch (final) {
                    // DA2(CSI > c): 단말 버전 식별. DA1만 답하고 침묵하면 vim 등이 DA2 응답을
                    // 타임아웃까지 기다린다. VT220급(1), 버전 10, ROM 0으로 답한다.
                    'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[>1;10;0c"),
                    // XTVERSION(CSI > q, Ps=0): xterm ctlseqs "Report xterm name and version".
                    // DA1/DA2가 범용 신원만 주는 것과 달리 "이 단말은 maru다"를 이름으로 알리는
                    // 런타임 자기식별 채널이다. 응답은 DCS `DCS > | <name> <version> ST`
                    // (= ESC P > | ... ESC \). Ps=0만 정의돼 있어 그 외엔 침묵한다. 이름/버전은
                    // terminal_name/terminal_version 단일 출처에서 comptime으로 조립한다.
                    'q' => if (self.csiRawParam(0) == 0)
                        self.appendResponse("\x1bP>|" ++ terminal_name ++ " " ++ terminal_version ++ "\x1b\\"),
                    // kitty keyboard(CSI > flags u): flag 스택에 push(enable). flags는 u5로 truncate.
                    'u' => self.kitty_flags.push(kittyFlagsFromParam(self.csiRawParam(0))),
                    else => {},
                },
                '<' => switch (final) {
                    // kitty keyboard(CSI < n u): 스택에서 n개(기본 1) pop — 이전 모드 복원/비활성.
                    'u' => self.kitty_flags.pop(self.csiParam(0, 1)),
                    else => {},
                },
                '=' => switch (final) {
                    // kitty keyboard(CSI = flags ; mode u): 최상단 flags set — mode 1=치환·2=or·3=not(기본 1).
                    'u' => self.kitty_flags.set(switch (self.csiParam(1, 1)) {
                        2 => .@"or",
                        3 => .not,
                        else => .set,
                    }, kittyFlagsFromParam(self.csiRawParam(0))),
                    else => {},
                },
                else => {},
            }
            return;
        }
        switch (final) {
            'm' => self.applySgr(),
            'H', 'f' => self.cursorPosition(),
            'A' => self.cursorVertical(self.csiParam(0, 1), true),
            'B', 'e' => self.cursorVertical(self.csiParam(0, 1), false),
            'C', 'a' => self.cursorHorizontal(self.csiParam(0, 1), true),
            'D' => self.cursorHorizontal(self.csiParam(0, 1), false),
            'G', '`' => self.cursorToColumn(self.csiParam(0, 1)),
            'd' => self.cursorToRow(self.csiParam(0, 1)),
            'J' => self.eraseInDisplay(self.csiRawParam(0)),
            'K' => self.eraseInLine(self.csiRawParam(0)),
            'X' => self.eraseCharacters(self.csiParam(0, 1)), // ECH: 커서부터 N개(기본 1) cell blank, 커서 유지 — nvim이 모드 라벨(-- INSERT --) clear에 이걸 쓴다
            'n' => self.deviceStatusReport(),
            'r' => self.setScrollRegion(),
            'L' => self.insertLines(self.csiParam(0, 1)),
            'M' => self.deleteLines(self.csiParam(0, 1)),
            '@' => self.insertChars(self.csiParam(0, 1)), // ICH: 커서에 N개(기본 1) blank 삽입, 오른쪽으로 민다
            'P' => self.deleteChars(self.csiParam(0, 1)), // DCH: 커서에서 N개(기본 1) 삭제, 왼쪽으로 당긴다
            'Z' => self.cursorBackTab(self.csiParam(0, 1)), // CBT: 역방향 N개(기본 1) 탭스톱 — Shift+Tab 폼 역이동
            'g' => self.clearTabstop(self.csiRawParam(0)), // TBC: 0(기본)=커서 열 탭스톱 제거, 3=전체 제거
            'b' => self.repeatLastChar(self.csiParam(0, 1)), // REP(G5): 직전 graphic 글자를 N회 반복
            'S' => self.scrollRangeUp(self.scroll_top, self.scroll_bottom, self.csiParam(0, 1), false), // SU(G7): scroll region N줄 위로 팬(history 미보관)
            'T' => self.scrollRangeDown(self.scroll_top, self.scroll_bottom, self.csiParam(0, 1)), // SD(G7): scroll region N줄 아래로 팬
            'h' => self.setAnsiModes(true), // SM(G6): 비-private ANSI 모드 set(IRM=4 등)
            'l' => self.setAnsiModes(false), // RM(G6): 비-private ANSI 모드 reset
            // SCOSC/SCORC(CSI s / CSI u): ANSI(SCO) 커서 저장/복원. DECSC/DECRC(ESC 7/8)와 같은 슬롯을
            // 쓴다(위치+pen+pending_wrap). xterm은 좌우 margin 모드(DECLRMM ?69)일 때만 CSI s를 DECSLRM으로
            // 보지만, maru는 좌우 margin 미구현이라 항상 save로 처리한다. multi-line progress(brew 등)가
            // 커서 저장→여러 줄 그리기→복원으로 제자리 갱신하는 표준 수단이다 — 복원을 무시하면 진행바가
            // 줄줄이 쌓인다. 베이스: xterm ctlseqs SCOSC/SCORC(Ghostty 동등). bare 's'/'u'만 — kitty CSI u
            // (`> < = ?` prefix)는 위 private 분기에서 처리하므로 여기 안 온다.
            's' => self.saveCursorState(),
            'u' => self.restoreCursorState(),

            // DA1(CSI c / CSI 0 c): 터미널 식별 질의. 프로그램(claude CLI 등)이 시작 시 기능 협상
            // 으로 보내며, 응답이 없으면 타임아웃을 기다리거나 기능을 보수적으로 끈다. VT102로
            // 식별한다(CSI ?6c) — 현재 구현 수준(커서/erase/scroll region/IL/DL)과 부합.
            'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[?6c"),
            else => {},
        }
    }

    /// DECSET(h)/DECRST(l)의 alternate-screen 계열 모드를 적용한다. 파라미터가 여러 개면 각각 적용.
    /// 47/1047=alt 전환만(둘의 차이인 "1047은 나갈 때 alt clear"는 alt 버퍼를 해제하는 현 구현에선
    /// 구분이 무의미하다), 1048=커서 저장/복원만, 1049=결합(들어갈 때 커서 저장+빈 alt, 나갈 때
    /// 커서 복원) — vim/less가 쓰는 표준 조합이다.
    fn setPrivateModes(self: *TerminalCore, set: bool) void {
        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            switch (self.csiRawParam(i)) {
                1 => self.application_cursor_keys = set, // DECCKM: 화살표 SS3/CSI 인코딩 전환
                5 => if (self.reverse_screen != set) { // DECSCNM(G9): 화면 전역 반전 — 바뀌면 전체 재칠
                    self.reverse_screen = set;
                    self.dirty = fullDirty(self.size);
                },
                6 => self.setOriginMode(set), // DECOM: CUP/HVP origin을 scroll region 상단으로 + 커서 home
                25 => { // DECTCEM: 커서 표시/숨김. 커서 행만 다시 그리면 된다.
                    self.cursor_visible = set;
                    self.markDirty(self.cursor.row);
                },
                1007 => self.alternate_scroll = set, // alt screen 휠 -> 화살표 변환 on/off
                2004 => self.bracketed_paste = set, // bracketed paste(붙여넣기 감싸기)
                1004 => self.focus_events = set, // focus reporting(창 포커스 in/out → CSI I/O)
                9 => self.mouse_tracking = if (set) .x10 else .none, // X10 mouse(press만)
                1000 => self.mouse_tracking = if (set) .normal else .none, // normal(press+release)
                1002 => self.mouse_tracking = if (set) .button else .none, // button(+버튼 눌린 채 drag)
                1003 => self.mouse_tracking = if (set) .any else .none, // any(+모든 motion)
                1006 => self.mouse_format = if (set) .sgr else .x10, // SGR 인코딩(좌표 무제한)
                1016 => self.mouse_format = if (set) .sgr_pixels else .x10, // SGR-pixels 인코딩
                1015 => self.mouse_format = if (set) .urxvt else .x10, // urxvt 인코딩(G13 — 거의 1006으로 대체)
                7 => self.autowrap = set, // DECAWM(G8): autowrap on/off — off면 마지막 칸에서 덮어쓴다
                2027 => self.grapheme_cluster_mode = set, // grapheme cluster 너비(이모지 풀사이즈 합의)
                2026 => self.sync_output = set, // synchronized output(set=BSU hold 시작, reset=ESU flush)
                47, 1047 => if (set) self.enterAltScreen(false) else self.leaveAltScreen(false),
                1048 => if (set) self.saveCursorState() else self.restoreCursorState(),
                1049 => if (set) self.enterAltScreen(true) else self.leaveAltScreen(true),
                else => {}, // 그 외 private 모드(25 커서 표시 등)는 아직 소비만 한다.
            }
        }
    }

    /// SM/RM(CSI Ps h/l, private marker 없음): 비-private ANSI 모드. 현재 IRM(4)=insert mode만 지원(그 외 소비).
    fn setAnsiModes(self: *TerminalCore, set: bool) void {
        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            switch (self.csiRawParam(i)) {
                4 => self.insert_mode = set, // IRM(G6): insert/replace
                else => {},
            }
        }
    }

    /// REP(CSI Ps b): 직전에 출력한 graphic 글자(last_printed_cp)를 N회(기본 1) 더 반복한다. 아직 출력이
    /// 없으면(0) 무동작. 각 반복은 writeCodepoint 경로(wrap·IRM·DECAWM·charset 적용)를 그대로 탄다.
    fn repeatLastChar(self: *TerminalCore, count: u16) void {
        if (self.last_printed_cp == 0) return;
        const cp = self.last_printed_cp;
        var n = @max(count, 1);
        // putCell을 직접 호출한다(writeCodepoint가 아니라) — last_printed_cp는 이미 charset 변환을 거친 최종
        // 글리프라, writeCodepoint로 다시 보내면 translateCharset이 두 번 적용된다(현 charset이 dec_special이면
        // 오변환). putCell이 wrap·IRM·DECAWM·wide를 그대로 처리하고 charset만 건너뛴다.
        while (n > 0) : (n -= 1) self.putCell(cp);
    }

    /// DECALN(ESC # 8): 화면 전체를 'E'(기본 attr)로 채우고 커서를 home으로 보낸다. VT 정렬 진단(vttest) 전용.
    fn decAlign(self: *TerminalCore) void {
        for (self.cells) |*c| c.* = .{ .codepoint = 'E', .width = 1 };
        @memset(self.wrapped, false);
        const old_cursor = self.cursor;
        self.cursor = .{};
        self.pending_wrap = false;
        self.last_print = null;
        self.markCursorMoveDirty(old_cursor, self.cursor);
        self.dirty = fullDirty(self.size);
    }

    /// focus reporting(DECSET 1004)이 켜져 있으면 창 포커스 변화를 CSI I(gained)/CSI O(lost)로 PTY에 리포트한다.
    /// 베이스: xterm focus event(mode 1004) — 인코딩은 Ghostty `focus.zig`와 동일(`\x1b[I`/`\x1b[O`). off면 무동작.
    pub fn reportFocus(self: *TerminalCore, gained: bool) void {
        if (!self.focus_events) return;
        self.appendResponse(if (gained) "\x1b[I" else "\x1b[O");
    }

    /// mouse 이벤트를 앱에 리포트한다(mouse_tracking이 .none이 아닐 때). col/row는 0-based(인코딩은 1-based로 +1).
    /// button: 0=left,1=middle,2=right, 64=wheel-up,65=wheel-down. mods 비트: 4=shift,8=meta(alt),16=ctrl. motion이면
    /// drag/move(button·any 모드만, Cb에 +32). 베이스: xterm — SGR(1006/1016) `CSI < Cb;Px;Py M`(press)/`m`(release);
    /// x10 `CSI M` + (32+Cb)(32+Px)(32+Py) 바이트(좌표 223 초과는 깨져 SGR 권장, release는 버튼 미상이라 Cb=3).
    /// 마우스 이벤트를 활성 tracking 모드/format으로 PTY에 리포트한다. col/row는 0-based 셀,
    /// x_px/y_px는 0-based 픽셀이며 SGR-Pixels(1016) format에서만 쓴다 — platform이 활성 pane
    /// 영역 좌상단 기준 backing(device) 픽셀로 보정해 전달한다. SGR/x10 format은 픽셀을 무시하고
    /// 셀 좌표를 인코딩한다.
    pub fn reportMouse(self: *TerminalCore, button: u8, col: u16, row: u16, x_px: u16, y_px: u16, pressed: bool, motion: bool, mods: u8) void {
        if (self.mouse_tracking == .none) return;
        // motion(drag/move)은 button·any 모드만 리포트한다(x10/normal은 press·release만).
        if (motion and self.mouse_tracking != .button and self.mouse_tracking != .any) return;
        // x10은 press만 리포트(release를 안 보낸다).
        if (!pressed and self.mouse_tracking == .x10) return;
        const cb: u32 = @as(u32, button) + @as(u32, mods) + (if (motion) @as(u32, 32) else 0);
        var buf: [32]u8 = undefined;
        const out = switch (self.mouse_format) {
            .sgr => std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
                cb, @as(u32, col) + 1, @as(u32, row) + 1, @as(u8, if (pressed) 'M' else 'm'),
            }) catch return,
            // SGR-Pixels(1016): 1006과 같은 형식이되 셀이 아니라 픽셀 좌표를 1-based로 리포트한다.
            // 베이스: xterm ctlseqs "report position in pixels rather than character cells". 단위는
            // maru가 마우스·렌더 전반에 쓰는 backing(device) 픽셀로, xterm X11 device-pixel 관례와 정합한다.
            .sgr_pixels => std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
                cb, @as(u32, x_px) + 1, @as(u32, y_px) + 1, @as(u8, if (pressed) 'M' else 'm'),
            }) catch return,
            // urxvt(1015): x10과 같은 Cb(32 offset)·1-based 셀 좌표를 바이트가 아니라 십진수 `CSI Cb;Px;Py M`로
            // 보낸다(release는 x10처럼 Cb=3). 좌표 무제한이라 x10의 >223 깨짐이 없다. 베이스: urxvt 1015.
            .urxvt => blk: {
                const eb: u32 = if (pressed) cb else 3;
                break :blk std.fmt.bufPrint(&buf, "\x1b[{d};{d};{d}M", .{
                    32 + eb, @as(u32, col) + 1, @as(u32, row) + 1,
                }) catch return;
            },
            .x10 => blk: {
                // x10은 release 시 버튼 미상이라 Cb=3(sentinel). 각 바이트 32 offset, 255 saturate(>223 깨짐).
                const eb: u32 = if (pressed) cb else 3;
                break :blk std.fmt.bufPrint(&buf, "\x1b[M{c}{c}{c}", .{
                    @as(u8, @intCast(@min(32 + eb, 255))),
                    @as(u8, @intCast(@min(32 + @as(u32, col) + 1, 255))),
                    @as(u8, @intCast(@min(32 + @as(u32, row) + 1, 255))),
                }) catch return;
            },
        };
        self.appendResponse(out);
    }

    /// 현재 활성 화면의 DECSC 저장 슬롯. ESC 7/8과 1048은 항상 "지금 보이는 화면"의 슬롯을 쓴다
    /// (xterm 동일). 1049의 enter(저장)/leave(복원)는 primary 슬롯을 쓴다 — 셸 커서를 보관했다가
    /// TUI 종료 시 되돌리는 용도라서다.
    fn activeSavedCursor(self: *TerminalCore) *SavedCursor {
        return if (self.alt_active) &self.saved_cursor_alt else &self.saved_cursor_primary;
    }

    fn saveCursorState(self: *TerminalCore) void {
        self.activeSavedCursor().* = .{
            .cursor = self.cursor,
            .pen = self.pen,
            .pending_wrap = self.pending_wrap,
        };
    }

    fn restoreCursorState(self: *TerminalCore) void {
        self.restoreFromSlot(self.activeSavedCursor().*);
    }

    fn restoreFromSlot(self: *TerminalCore, slot: SavedCursor) void {
        const old_cursor = self.cursor;
        self.cursor = .{
            .row = @min(slot.cursor.row, self.size.rows - 1),
            .col = @min(slot.cursor.col, self.size.cols - 1),
        };
        self.pen = slot.pen;
        self.markCursorMoveDirty(old_cursor, self.cursor);
        // markCursorMoveDirty가 deferred autowrap을 무효화(pending_wrap=false)하므로, 저장된 pending_wrap은
        // 그 '뒤'에 복원한다 — 줄 끝 deferred-wrap 상태에서 저장→복원하면 복원이 즉시 덮어써지던 버그
        // (DECSC/DECRC·CSI s/u가 공유하는 restoreFromSlot, code review).
        self.pending_wrap = slot.pending_wrap;
        self.last_print = null;
    }

    /// alt screen으로 전환한다. primary 그리드(cells/wrapped)를 saved_*로 옮기고 빈 alt 버퍼를
    /// 만든다(1049는 들어가며 clear — TUI가 어차피 전체를 그린다). 할당 실패면 전환하지 않는다
    /// (primary 유지가 안전 — 커서 저장도 두 할당이 성공한 뒤에 해 실패가 부작용 없게 한다).
    /// 1049의 커서 저장은 이미 alt여도 수행한다(xterm: "unconditionally saves the cursor").
    fn enterAltScreen(self: *TerminalCore, save_cursor: bool) void {
        if (self.alt_active) {
            // 화면은 이미 alt지만 1049h의 커서 저장 의미는 유지한다(중첩 멀티플렉서/SIGCONT 재초기화).
            if (save_cursor) self.saveCursorState();
            return;
        }

        const alt_cells = self.allocator.alloc(types.Cell, cellCount(self.size)) catch return;
        @memset(alt_cells, .{});
        const alt_wrapped = self.allocator.alloc(bool, self.size.rows) catch {
            self.allocator.free(alt_cells);
            return;
        };
        @memset(alt_wrapped, false);
        const alt_prompt_marks = self.allocator.alloc(types.RowPrompt, self.size.rows) catch {
            self.allocator.free(alt_cells);
            self.allocator.free(alt_wrapped);
            return;
        };
        @memset(alt_prompt_marks, .{});

        // 세 할당이 성공한 뒤에야 상태를 바꾼다(OOM 경로가 저장 슬롯을 오염시키지 않게).
        if (save_cursor) self.saveCursorState(); // primary 슬롯(아직 alt_active=false)
        self.saved_cells = self.cells;
        self.saved_wrapped = self.wrapped;
        self.saved_prompt_marks = self.prompt_marks; // primary의 OSC 133 분류 보관
        self.cells = alt_cells;
        self.wrapped = alt_wrapped;
        self.prompt_marks = alt_prompt_marks; // alt 화면은 셸 프롬프트 의미가 없다(전부 .unknown)
        self.semantic_state = .unknown; // alt 진입 — primary의 진행 중 영역을 이어받지 않는다
        self.alt_active = true;
        // alt에서 스크롤백 뷰는 잠긴다 — 보고 있던 과거는 닫는다. 선택도 해제(활성 cells가 alt로
        // 바뀌어 abs>=sb_count 좌표가 다른 내용을 가리키므로 — xterm.js도 버퍼 전환 시 선택 해제).
        self.view_offset = 0;
        self.invalidateSelection();
        self.pen_link = 0; // OSC 8 링크는 화면에 스코프된다 — 전환 시 닫는다(Ghostty endHyperlink)
        self.pending_wrap = false;
        self.last_print = null;
        self.dirty = fullDirty(self.size);
    }

    /// primary screen으로 복귀한다. alt 버퍼를 버리고 saved 그리드를 복원한다. 1049는 커서도
    /// primary 슬롯에서 복원해 vim 종료 시 프롬프트가 원래 자리로 돌아온다 — alt 안에서 TUI가
    /// ESC 7/8을 써도(alt 슬롯) 셸 커서는 안전하다. 1049l의 커서 복원은 이미 primary여도
    /// 수행한다(xterm 동작 — 방어적 `\e[?1049l` 정리 스크립트 호환).
    fn leaveAltScreen(self: *TerminalCore, restore_cursor: bool) void {
        if (!self.alt_active) {
            if (restore_cursor) self.restoreFromSlot(self.saved_cursor_primary);
            return;
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        if (self.prompt_marks.len > 0) self.allocator.free(self.prompt_marks);
        self.cells = self.saved_cells;
        self.wrapped = self.saved_wrapped;
        self.prompt_marks = self.saved_prompt_marks; // primary 분류 복원
        self.saved_cells = &.{};
        self.saved_wrapped = &.{};
        self.saved_prompt_marks = &.{};
        self.semantic_state = .unknown; // primary 복귀 — 진행 중 영역을 이어받지 않는다(다음 프롬프트가 재마킹)
        self.alt_active = false;
        self.pending_wrap = false;
        self.last_print = null;
        self.pen_link = 0; // 화면 전환 — 열린 링크를 닫는다(Ghostty endHyperlink)
        self.invalidateSelection(); // primary 복귀 — 활성 cells가 다시 바뀌므로 선택 해제
        if (restore_cursor) self.restoreFromSlot(self.saved_cursor_primary);
        self.dirty = fullDirty(self.size);
    }

    /// DECSCUSR(CSI Ps SP q): 커서 모양/깜빡임. 0|1=깜빡 block, 2=고정 block, 3=깜빡 underline,
    /// 4=고정 underline, 5=깜빡 bar, 6=고정 bar. 모르는 값은 무시한다. vim이 모드 전환마다 보낸다.
    fn setCursorStyle(self: *TerminalCore, param: u16) void {
        switch (param) {
            0, 1 => {
                self.cursor_shape = .block;
                self.cursor_blink = true;
            },
            2 => {
                self.cursor_shape = .block;
                self.cursor_blink = false;
            },
            3 => {
                self.cursor_shape = .underline;
                self.cursor_blink = true;
            },
            4 => {
                self.cursor_shape = .underline;
                self.cursor_blink = false;
            },
            5 => {
                self.cursor_shape = .bar;
                self.cursor_blink = true;
            },
            6 => {
                self.cursor_shape = .bar;
                self.cursor_blink = false;
            },
            else => return,
        }
        self.markDirty(self.cursor.row); // 모양이 바뀐 커서 칸을 다시 그린다
    }

    /// DSR(CSI Ps n): 호스트의 상태 질의에 응답한다. 응답은 response 버퍼에 쌓이고 app이 PTY로 되쓴다.
    /// 5n=터미널 OK(CSI 0n), 6n=커서 위치 보고(CPR, CSI row;col R, 1-indexed). zsh가 SIGWINCH
    /// redraw 때 6n으로 커서를 물으므로 응답이 없으면 redraw가 어긋난다(프롬프트 중복 등).
    fn deviceStatusReport(self: *TerminalCore) void {
        switch (self.csiRawParam(0)) {
            5 => self.appendResponse("\x1b[0n"),
            6 => {
                var buf: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.cursor.row + 1,
                    self.cursor.col + 1,
                }) catch return;
                self.appendResponse(s);
            },
            else => {},
        }
    }

    /// DECRQM(CSI ? Ps $ p) 응답 — DECRPM(CSI ? Ps ; Pm $ y). Pm: 0=미인식, 1=set, 2=reset,
    /// 3=영구 set, 4=영구 reset. 우리가 추적하는 모드는 현재 상태(1/2)를 알려 앱이 지원을 감지하고
    /// 켤 수 있게 한다(특히 mode 2027). 모르는 모드는 0(미인식)으로 답해 앱이 폴백하게 둔다.
    fn reportPrivateMode(self: *TerminalCore, mode: u16) void {
        const state: u8 = switch (mode) {
            2027 => if (self.grapheme_cluster_mode) 1 else 2,
            2026 => if (self.sync_output) 1 else 2,
            2004 => if (self.bracketed_paste) 1 else 2,
            25 => if (self.cursor_visible) 1 else 2,
            1 => if (self.application_cursor_keys) 1 else 2,
            6 => if (self.origin_mode) 1 else 2, // DECOM(origin mode)
            else => 0, // 미인식 — 앱이 보수적으로 폴백
        };
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, state }) catch return;
        self.appendResponse(s);
    }

    /// CSI 파라미터(u16)를 kitty flags로 — Maru가 실제 인코딩하는 disambiguate(bit 0)만 통과시킨다.
    /// report_events/report_alternates/report_all/report_associated는 미구현이므로 스택에 저장하지
    /// 않는다: 저장하면 query(CSI ? u)가 미구현 능력을 활성으로 거짓 보고하고(앱이 켜진 줄 알고 key
    /// release·대체키·연관텍스트를 기대), 인코딩은 disambiguate 수준만 나가 광고와 동작이 어긋난다.
    /// 지원 flag가 늘면 이 마스크를 넓힌다.
    fn kittyFlagsFromParam(v: u16) KittyFlags {
        return .{ .disambiguate = (v & 1) != 0 };
    }

    /// kitty keyboard query(CSI ? u) 응답: 현재 스택 최상단 flags를 CSI ? flags u로 보고한다.
    fn reportKittyFlags(self: *TerminalCore) void {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{self.kitty_flags.current().int()}) catch return;
        self.appendResponse(s);
    }

    fn appendResponse(self: *TerminalCore, bytes: []const u8) void {
        self.response.appendSlice(self.allocator, bytes) catch {}; // best-effort(OOM이면 응답 생략)
    }

    /// 아직 호스트(PTY)로 안 보낸 터미널 응답 바이트. app이 매 write 후 이걸 PTY로 쓰고 clearResponse한다.
    pub fn pendingResponse(self: *const TerminalCore) []const u8 {
        return self.response.items;
    }

    pub fn clearResponse(self: *TerminalCore) void {
        self.response.clearRetainingCapacity();
    }

    fn applySgr(self: *TerminalCore) void {
        const count = @min(self.csi_param_count, max_csi_params);
        var i: usize = 0;
        while (i < count) {
            const p = self.csi_params[i];
            switch (p) {
                0 => self.pen = .{},
                7 => self.pen.reverse = true,
                27 => self.pen.reverse = false,
                1 => self.pen.bold = true,
                2 => self.pen.dim = true, // SGR 2: faint/decreased intensity (ECMA-48)
                3 => self.pen.italic = true,
                4 => {
                    // underline. colon 형식 4:x(ITU T.416 — x는 underline 스타일)는 x=0이면 off, x=2면 double,
                    // 그 외 x>0은 single on(curly/dotted 등 스타일 종류는 single로 근사). 세미콜론 plain 4는 single on.
                    // sub-param은 아래 루프 끝에서 소비한다.
                    const styled = i + 1 < count and self.csi_subparam[i + 1];
                    if (styled) {
                        const sub = self.csi_params[i + 1];
                        self.pen.underline = sub != 0;
                        self.pen.underline_double = sub == 2; // 4:2 = double underline
                    } else {
                        self.pen.underline = true;
                        self.pen.underline_double = false;
                    }
                },
                22 => { // SGR 22: normal intensity — bold·faint 둘 다 off (ECMA-48)
                    self.pen.bold = false;
                    self.pen.dim = false;
                },
                23 => self.pen.italic = false,
                24 => { // SGR 24: underline off — single·double 둘 다 끈다
                    self.pen.underline = false;
                    self.pen.underline_double = false;
                },
                21 => { // SGR 21: doubly underlined — 하단 2중선
                    self.pen.underline = true;
                    self.pen.underline_double = true;
                },
                9 => self.pen.strikethrough = true, // SGR 9: crossed-out (ECMA-48)
                29 => self.pen.strikethrough = false, // SGR 29: not crossed-out
                53 => self.pen.overline = true, // SGR 53: overlined (ECMA-48)
                55 => self.pen.overline = false, // SGR 55: not overlined
                5, 6 => self.pen.blink = true, // SGR 5(slow)/6(rapid) blink — 파싱·저장만(렌더 정적)
                25 => self.pen.blink = false, // SGR 25: blink off
                8 => self.pen.conceal = true, // SGR 8: concealed(invisible)
                28 => self.pen.conceal = false, // SGR 28: reveal
                59 => self.pen.underline_color = .default, // SGR 59: underline color를 default(전경색)로
                30...37 => self.pen.foreground = .{ .indexed = @intCast(p - 30) },
                39 => self.pen.foreground = .default,
                40...47 => self.pen.background = .{ .indexed = @intCast(p - 40) },
                49 => self.pen.background = .default,
                90...97 => self.pen.foreground = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.pen.background = .{ .indexed = @intCast(p - 100 + 8) },
                38 => {
                    i = self.applyExtendedColor(i, &self.pen.foreground);
                    continue;
                },
                48 => {
                    i = self.applyExtendedColor(i, &self.pen.background);
                    continue;
                },
                58 => { // SGR 58: underline color(58;2;r;g;b·58;5;n) — 전경과 별개 밑줄 색(nvim/helix LSP)
                    i = self.applyExtendedColor(i, &self.pen.underline_color);
                    continue;
                },
                else => {},
            }
            i += 1;
            // 직전 주 파라미터에 딸린 colon sub-parameter는 그 파라미터에 종속이라 별도 SGR로 처리하지
            // 않는다(ITU T.416). 4:3은 underline 스타일이지 italic(SGR 3)이 아니고, 4:0은 underline off지
            // SGR 0(전체 리셋)이 아니다 — 4 case에서 이미 소비했으니 여기선 건너뛰기만 한다. 38/48은 위에서
            // continue로 i를 직접 점프하므로 여기 오지 않는다.
            while (i < count and self.csi_subparam[i]) i += 1;
        }
    }

    /// 38/48 (확장 색)을 처리하고 다음으로 읽을 파라미터 인덱스를 돌려준다. 세미콜론
    /// (38;2;r;g;b, 38;5;n)과 colon sub-parameter(38:2:colorspace:r:g:b, 38:5:n)를 모두 지원한다.
    fn applyExtendedColor(self: *TerminalCore, start: usize, target: *types.Color) usize {
        const count = @min(self.csi_param_count, max_csi_params);
        const mode = if (start + 1 < count) self.csi_params[start + 1] else 0;
        // mode가 ':'로 들어왔으면 colon 형식이다. colon mode 2는 r,g,b 앞에 colorspace
        // 컴포넌트가 하나 더 있다(빈 경우 '::'). mode 5는 두 형식 모두 n 위치가 같다.
        const colon_form = start + 1 < count and self.csi_subparam[start + 1];
        if (mode == 5 and start + 2 < count) {
            target.* = .{ .indexed = @intCast(@min(self.csi_params[start + 2], 255)) };
            return start + 3;
        }
        if (mode == 2) {
            if (colon_form) {
                // colon 형식은 mode 뒤의 colon sub-parameter가 [r,g,b](3개) 또는
                // [colorspace,r,g,b](4개, colorspace는 빈 '::'일 수 있음)다. colorspace가
                // 있는지 개수로 정해진 게 아니므로(38:2:r:g:b처럼 생략 가능) mode 뒤 colon
                // 컴포넌트 수를 세어, r,g,b는 항상 마지막 3개로 읽는다. 이전에는 colorspace가
                // 항상 있다고 가정해 38:2:r:g:b(5컴포넌트)를 통째로 버렸다.
                var n: usize = 0;
                while (start + 2 + n < count and self.csi_subparam[start + 2 + n]) : (n += 1) {}
                if (n >= 3) {
                    const rgb_start = start + 2 + (n - 3);
                    target.* = .{ .rgb = .{
                        .r = @intCast(@min(self.csi_params[rgb_start], 255)),
                        .g = @intCast(@min(self.csi_params[rgb_start + 1], 255)),
                        .b = @intCast(@min(self.csi_params[rgb_start + 2], 255)),
                    } };
                    return start + 2 + n;
                }
            } else if (start + 4 < count) {
                // 세미콜론 형식 38;2;r;g;b — r,g,b가 mode 바로 뒤.
                target.* = .{ .rgb = .{
                    .r = @intCast(@min(self.csi_params[start + 2], 255)),
                    .g = @intCast(@min(self.csi_params[start + 3], 255)),
                    .b = @intCast(@min(self.csi_params[start + 4], 255)),
                } };
                return start + 5;
            }
        }
        // 형식이 안 맞으면 나머지 파라미터를 버린다.
        return count;
    }

    fn cursorPosition(self: *TerminalCore) void {
        if (self.size.rows == 0 or self.size.cols == 0) return;
        const old = self.cursor;
        const row = self.csiParam(0, 1);
        const col = self.csiParam(1, 1);
        self.cursor.row = self.resolveRow(row); // DECOM이면 scroll region 상단 기준 + region 안 clamp
        self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    /// DECOM(DECSET/DECRST ?6) 적용. origin mode를 토글하고 커서를 origin home으로 옮긴다(xterm 동작 —
    /// DECOM 변경 시 커서가 home으로). origin이면 scroll region 좌상단, 아니면 화면 좌상단.
    fn setOriginMode(self: *TerminalCore, on: bool) void {
        self.origin_mode = on;
        const old = self.cursor;
        self.cursor = .{ .row = if (on) self.scroll_top else 0, .col = 0 };
        self.pending_wrap = false;
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    /// CUP/HVP/VPA의 1-based row 파라미터를 0-based 셀 행으로 변환한다. DECOM(origin mode)이면 scroll
    /// region 상단 기준(1=region top)으로 옮기고 region 안에 clamp, 아니면 화면 절대로 clamp. 베이스:
    /// xterm/Ghostty 공통 — CUP·HVP·VPA가 모두 같은 origin 변환을 거친다(Ghostty는 setCursorPos 단일 경로).
    fn resolveRow(self: *const TerminalCore, row_param: u16) u16 {
        if (self.origin_mode) {
            return @intCast(@min(@as(u32, self.scroll_top) + @as(u32, row_param) - 1, @as(u32, self.scroll_bottom)));
        }
        return @intCast(@min(@as(u32, row_param) - 1, @as(u32, self.size.rows) - 1));
    }

    fn cursorVertical(self: *TerminalCore, amount: u16, up: bool) void {
        if (self.size.rows == 0) return;
        const old = self.cursor;
        if (up) {
            self.cursor.row -|= amount;
        } else {
            const max_row = self.size.rows - 1;
            self.cursor.row = @intCast(@min(@as(u32, self.cursor.row) + amount, max_row));
        }
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorHorizontal(self: *TerminalCore, amount: u16, right: bool) void {
        if (self.size.cols == 0) return;
        const old = self.cursor;
        if (right) {
            const max_col = self.size.cols - 1;
            self.cursor.col = @intCast(@min(@as(u32, self.cursor.col) + amount, max_col));
        } else {
            self.cursor.col -|= amount;
        }
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorToColumn(self: *TerminalCore, col: u16) void {
        if (self.size.cols == 0) return;
        const old = self.cursor;
        self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorToRow(self: *TerminalCore, row: u16) void {
        if (self.size.rows == 0) return;
        const old = self.cursor;
        // VPA(CSI Ps d)도 CUP/HVP처럼 DECOM origin 영향을 받는다(xterm/Ghostty 공통 — setCursorPos 단일 경로).
        self.cursor.row = self.resolveRow(row);
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    /// erase로 [start, end) 범위를 비울 때, 경계에 걸친 wide glyph(width=2)의 반쪽을 정리한다.
    /// clearCellForWrite가 쓰기 시 하던 짝 정리를 erase에도 적용해, 짝 잃은 base나 orphan
    /// continuation이 남아 half-glyph로 그려지는 것을 막는다.
    fn repairWideGlyphEdges(self: *TerminalCore, row: u16, start: u16, end: u16) void {
        const blank: types.Cell = .{ .style = self.pen };
        // 왼쪽 경계: start-1이 width=2 base면 그 continuation(start)이 지워졌으므로 base도 비운다.
        if (start > 0 and self.cells[self.index(row, start - 1)].width == 2) {
            self.cells[self.index(row, start - 1)] = blank;
        }
        // 오른쪽 경계: end가 continuation이면 그 base(end-1)가 지워졌으므로 continuation도 비운다.
        if (end < self.size.cols and self.cells[self.index(row, end)].continuation) {
            self.cells[self.index(row, end)] = blank;
        }
    }

    fn eraseInLine(self: *TerminalCore, mode: u16) void {
        const row = self.cursor.row;
        if (self.size.cols == 0 or row >= self.size.rows) return;
        const start: u16 = switch (mode) {
            1, 2 => 0,
            else => self.cursor.col,
        };
        const end: u16 = switch (mode) {
            1 => @min(self.cursor.col + 1, self.size.cols),
            else => self.size.cols,
        };
        var col = start;
        while (col < end) : (col += 1) {
            // erase는 현재 pen의 배경색으로 채워야 하므로 blank cell에 style만 남긴다.
            self.cells[self.index(row, col)] = .{ .style = self.pen };
        }
        self.repairWideGlyphEdges(row, start, end);
        // 행의 오른쪽 끝을 지우면(mode 0=커서~끝, mode 2=전체) soft-wrap 연속성이 끊긴다. mode 1
        // (시작~커서)은 오른쪽 끝이 멀쩡해 줄이 여전히 다음 행으로 이어질 수 있으므로 wrapped를 끄지
        // 않는다 — 안 그러면 reflow가 한 논리 줄을 둘로 쪼갠다.
        if (mode != 1) self.wrapped[row] = false;
        self.markDirty(row);
        // 모든 EL 모드는 deferred autowrap을 무효화한다(xterm/Ghostty 동작). 안 끄면 마지막 칸
        // 출력(pending) 후 EL+글자 시퀀스가 한 줄 일찍 wrap돼 상대 커서 이동이 어긋난다.
        self.pending_wrap = false;
        // 다른 cursor/erase op과 같이 grapheme run을 끝낸다. 안 하면 CSI K 뒤 combining mark가
        // 방금 지운 셀에 붙는다.
        self.last_print = null;
    }

    /// ECH(CSI Ps X): 커서 위치부터 Ps개(기본 1) cell을 현재 pen 배경의 blank로 지운다. EL과 달리 줄 끝까지가
    /// 아니라 N개만, DCH(CSI P)와 달리 뒤 cell을 당기지도 않는다(제자리 blank). **커서는 안 움직인다**.
    /// 베이스: xterm `ECH`("Erase Ps Character(s)") — nvim이 모드 라벨(`-- INSERT --`)을 이 시퀀스로 지운다(EL 아님).
    fn eraseCharacters(self: *TerminalCore, count: u16) void {
        const row = self.cursor.row;
        if (self.size.cols == 0 or row >= self.size.rows) return;
        const start = self.cursor.col;
        const end: u16 = @min(start +| @max(count, 1), self.size.cols);
        var col = start;
        while (col < end) : (col += 1) {
            // erase는 현재 pen의 배경색으로 채운다(blank cell + style만) — eraseInLine과 동일 규칙(bce).
            self.cells[self.index(row, col)] = .{ .style = self.pen };
        }
        self.repairWideGlyphEdges(row, start, end);
        self.markDirty(row);
        // ECH는 부분 erase라 soft-wrap flag를 끄지 않는다(EL mode 1과 같은 결 — 줄 끝이 남아 다음 행으로
        // 이어질 수 있다). deferred autowrap만 무효화(다른 erase op과 동일).
        self.pending_wrap = false;
        self.last_print = null;
    }

    /// ICH (CSI Ps @): 커서 위치에 Ps개(기본 1) 빈 칸을 삽입한다. 커서부터 줄 끝까지의 셀을 오른쪽으로
    /// 밀고, 줄 끝을 넘는 셀은 버린다. 빈 칸은 현재 pen 배경(BCE — eraseCharacters와 동일 규칙). 커서
    /// 위치는 불변. 베이스: ECMA-48 ICH / xterm ctlseqs `CSI Ps @`. 좌우 margin(DECSLRM) 미구현이라
    /// 줄 전체에서 작동한다.
    fn insertChars(self: *TerminalCore, count: u16) void {
        const row = self.cursor.row;
        if (self.size.cols == 0 or row >= self.size.rows) return;
        const start = self.cursor.col;
        if (start >= self.size.cols) return;
        const cols = self.size.cols;
        const n: u16 = @min(@max(count, 1), cols - start);
        const blank: types.Cell = .{ .style = self.pen };
        // 커서부터 오른쪽 셀을 n칸 오른쪽으로(역순 복사라 영역이 겹쳐도 안전). 줄 끝을 넘는 셀은 버린다.
        var col: u16 = cols;
        while (col > start + n) {
            col -= 1;
            self.cells[self.index(row, col)] = self.cells[self.index(row, col - n)];
        }
        // 삽입된 빈 칸.
        col = start;
        while (col < start + n) : (col += 1) self.cells[self.index(row, col)] = blank;
        // 왼쪽 경계에서 쪼개진 wide(start-1 base의 continuation이 밀려남)를 복구하고, 줄 끝으로 밀려
        // continuation이 줄 밖으로 나간 wide base를 비운다.
        self.repairWideGlyphEdges(row, start, cols);
        if (self.cells[self.index(row, cols - 1)].width == 2) self.cells[self.index(row, cols - 1)] = blank;
        self.markDirty(row);
        self.pending_wrap = false;
        self.last_print = null;
    }

    /// DCH (CSI Ps P): 커서 위치에서 Ps개(기본 1) 문자를 삭제한다. 커서 오른쪽 셀을 왼쪽으로 당기고,
    /// 줄 끝의 빈 자리는 현재 pen 배경(BCE). 커서 위치는 불변. 베이스: ECMA-48 DCH / xterm `CSI Ps P`.
    fn deleteChars(self: *TerminalCore, count: u16) void {
        const row = self.cursor.row;
        if (self.size.cols == 0 or row >= self.size.rows) return;
        const start = self.cursor.col;
        if (start >= self.size.cols) return;
        const cols = self.size.cols;
        const n: u16 = @min(@max(count, 1), cols - start);
        const blank: types.Cell = .{ .style = self.pen };
        // 커서 오른쪽 셀을 n칸 왼쪽으로 당긴다.
        var col = start;
        while (col + n < cols) : (col += 1) {
            self.cells[self.index(row, col)] = self.cells[self.index(row, col + n)];
        }
        // 줄 끝 n칸은 빈 칸.
        while (col < cols) : (col += 1) self.cells[self.index(row, col)] = blank;
        // 왼쪽 경계에서 쪼개진 wide(start-1 base)를 복구하고, 당겨와서 base를 잃은 continuation을 비운다.
        self.repairWideGlyphEdges(row, start, cols);
        if (self.cells[self.index(row, start)].continuation) self.cells[self.index(row, start)] = blank;
        self.markDirty(row);
        self.pending_wrap = false;
        self.last_print = null;
    }

    fn eraseInDisplay(self: *TerminalCore, mode: u16) void {
        if (self.size.rows == 0 or self.size.cols == 0) return;
        // 모든 ED 모드는 deferred autowrap을 무효화한다(EL과 동일한 이유, xterm/Ghostty 동작).
        self.pending_wrap = false;
        const blank: types.Cell = .{ .style = self.pen };
        switch (mode) {
            // 2/3: 화면 전체. 3(xterm E3)은 저장된 줄(스크롤백)까지 지운다 — `clear`가 보내는
            // \e[3J의 핵심 의미로, 비밀 출력 후 history를 비우는 용도다.
            2, 3 => {
                @memset(self.cells, blank);
                @memset(self.wrapped, false);
                @memset(self.prompt_marks, .{}); // 전체 clear는 OSC 133 분류도 지운다
                self.semantic_state = .unknown; // 진행 중 영역도 끝낸다(셸이 곧 프롬프트를 재마킹)
                if (mode == 3) self.clearScrollback();
                self.dirty = fullDirty(self.size);
            },
            // 1: 화면 시작 ~ 커서까지.
            1 => {
                const cursor_index = self.index(self.cursor.row, self.cursor.col);
                var i: usize = 0;
                while (i <= cursor_index and i < self.cells.len) : (i += 1) self.cells[i] = blank;
                for (0..@min(@as(usize, self.cursor.row) + 1, self.wrapped.len)) |r| self.wrapped[r] = false;
                self.repairWideGlyphEdges(self.cursor.row, 0, @min(self.cursor.col + 1, self.size.cols));
                // dirty를 덮어쓰지 않고 markDirty로 병합한다 — 같은 write()에서 앞서 dirty된 행
                // (예: 방금 출력한 아래쪽 행)을 잃어 렌더가 stale glyph를 남기지 않게 한다.
                self.markDirty(0);
                self.markDirty(self.cursor.row);
            },
            // 0(기본): 커서 ~ 화면 끝까지.
            else => {
                const cursor_index = self.index(self.cursor.row, self.cursor.col);
                var i: usize = cursor_index;
                while (i < self.cells.len) : (i += 1) self.cells[i] = blank;
                for (self.cursor.row..self.size.rows) |r| self.wrapped[r] = false;
                self.repairWideGlyphEdges(self.cursor.row, self.cursor.col, self.size.cols);
                self.markDirty(self.cursor.row);
                self.markDirty(self.size.rows - 1);
            },
        }
        self.last_print = null;
    }

    /// 행 끝의 빈 칸을 잘라낸 내용 길이.
    fn trimmedRowLen(self: *const TerminalCore, row: u16) u16 {
        var len: u16 = self.size.cols;
        while (len > 0) : (len -= 1) {
            if (!isBlankCell(self.cells[self.index(row, len - 1)])) break;
        }
        return len;
    }

    /// 기본 배경의 빈 공백 셀인지(reflow trim 기준). continuation/combining/배경색이 있으면 내용이다.
    fn isBlankCell(cell: types.Cell) bool {
        return cell.codepoint == ' ' and
            !cell.continuation and
            cell.combining == null and
            std.meta.activeTag(cell.style.background) == .default;
    }

    /// reflow가 누적한 출력 행(row-major, cols개)이 통째로 빈 행인지.
    fn outputRowBlank(cells: []const types.Cell, row: usize, cols: u16) bool {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            if (!isBlankCell(cells[row * @as(usize, cols) + c])) return false;
        }
        return true;
    }

    /// 폭이 줄어 행 마지막 칸에 wide glyph base(width 2)만 남고 continuation이 잘렸으면 그 base를
    /// 비운다(한 칸 공간에 2칸 폭 half-glyph가 렌더되는 것 방지). 폭 축소로 내용을 clip하는 모든
    /// 경로(resize 커서 줄 verbatim, renderSnapshot 스크롤백 합성)가 공유한다.
    fn clearTruncatedWideBase(row: []types.Cell) void {
        if (row.len > 0 and row[row.len - 1].width == 2) row[row.len - 1] = .{};
    }

    /// reflow 출력 스크래치를 cap_rows×cols 이상으로 키운다(grow-only, 내용 보존 안 함).
    fn ensureReflowScratch(self: *TerminalCore, cap_rows: usize, cols: u16) !void {
        const need_cells = cap_rows * @as(usize, cols);
        if (self.reflow_cells.len < need_cells) {
            if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
            self.reflow_cells = try self.allocator.alloc(types.Cell, need_cells);
        }
        if (self.reflow_wrapped.len < cap_rows) {
            if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
            self.reflow_wrapped = try self.allocator.alloc(bool, cap_rows);
        }
        if (self.reflow_prompt_marks.len < cap_rows) {
            if (self.reflow_prompt_marks.len > 0) self.allocator.free(self.reflow_prompt_marks);
            self.reflow_prompt_marks = try self.allocator.alloc(types.RowPrompt, cap_rows);
        }
    }

    /// 그리드를 reflow 없이 새 크기로 clip/pad해 복사한다(왼쪽 위 기준, 넘치는 내용은 버림).
    /// alt screen resize 등 재배치가 의미 없는 경로가 쓴다. 잘린 wide glyph base는 정리한다.
    fn copyRegionResize(
        allocator: std.mem.Allocator,
        src: []const types.Cell,
        old_rows: u16,
        old_cols: u16,
        next_size: types.Size,
    ) ![]types.Cell {
        const dst = try allocator.alloc(types.Cell, cellCount(next_size));
        @memset(dst, .{});
        const copy_rows = @min(old_rows, next_size.rows);
        const copy_cols = @min(old_cols, next_size.cols);
        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            const row_dst = dst[@as(usize, r) * next_size.cols ..][0..next_size.cols];
            @memcpy(row_dst[0..copy_cols], src[@as(usize, r) * old_cols ..][0..copy_cols]);
            clearTruncatedWideBase(row_dst);
        }
        return dst;
    }

    pub fn resize(self: *TerminalCore, cols_in: u16, rows_in: u16) !void {
        // grid를 최소 2칸×1행으로 맞춘다(clampGridSize 참고).
        const next_size = clampGridSize(.{ .cols = cols_in, .rows = rows_in });
        const new_cols = next_size.cols;
        const new_rows = next_size.rows;
        const old_rows = self.size.rows;
        const old_cols = self.size.cols;

        // resize는 활성 화면을 reflow하고(폭 변경 시) 행을 스크롤백으로 밀어내 모든 cell이 재배치
        // 된다 — 선택의 절대-행 좌표는 보존할 수 없으니 진입부에서 무조건 해제한다(폭/높이 변경,
        // alt 경로 공통). 스크롤백 재-wrap의 selectionClear와 별개로 여기서도 처리해, 폭 불변 높이
        // 변경이나 빈 스크롤백 같은 경로가 새지 않게 한다.
        self.invalidateSelection();

        // alt screen 중 resize: reflow/스크롤백 없이 두 그리드(활성 alt + 저장된 primary)를 단순
        // clip/pad한다. TUI는 SIGWINCH로 전체를 다시 그리므로 alt 내용 재배치는 의미가 없고, 저장된
        // primary는 복귀 시 크기가 맞아야 한다(복귀 후 첫 resize부터 다시 reflow).
        if (self.alt_active) {
            const new_alt = try copyRegionResize(self.allocator, self.cells, old_rows, old_cols, next_size);
            errdefer self.allocator.free(new_alt);
            const new_saved = try copyRegionResize(self.allocator, self.saved_cells, old_rows, old_cols, next_size);
            errdefer self.allocator.free(new_saved);
            const new_wrapped = try self.allocator.alloc(bool, new_rows);
            errdefer self.allocator.free(new_wrapped);
            @memset(new_wrapped, false);
            const new_saved_wrapped = try self.allocator.alloc(bool, new_rows);
            errdefer self.allocator.free(new_saved_wrapped);
            @memset(new_saved_wrapped, false);
            const new_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
            errdefer self.allocator.free(new_prompt_marks);
            @memset(new_prompt_marks, .{});
            const new_saved_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
            @memset(new_saved_prompt_marks, .{});
            // 살아남는 행의 soft-wrap 플래그는 보존한다. 특히 saved primary의 것을 버리면 복귀 후
            // 리사이즈에서 긴 wrap 줄이 영영 재합쳐지지 않는다(alt 것은 TUI가 다시 그리지만 동일
            // 규칙로 보존). 폭이 줄어 행이 clip돼도 논리 연속성 자체는 유지된다. OSC 133 태그도 같은
            // 규칙으로 보존한다(저장된 primary의 프롬프트 분류가 복귀 후에도 살아 있어야 한다).
            const keep_rows = @min(old_rows, new_rows);
            @memcpy(new_wrapped[0..keep_rows], self.wrapped[0..keep_rows]);
            @memcpy(new_saved_wrapped[0..keep_rows], self.saved_wrapped[0..keep_rows]);
            if (self.prompt_marks.len >= keep_rows) @memcpy(new_prompt_marks[0..keep_rows], self.prompt_marks[0..keep_rows]);
            if (self.saved_prompt_marks.len >= keep_rows) @memcpy(new_saved_prompt_marks[0..keep_rows], self.saved_prompt_marks[0..keep_rows]);

            self.allocator.free(self.cells);
            self.allocator.free(self.saved_cells);
            if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
            if (self.saved_wrapped.len > 0) self.allocator.free(self.saved_wrapped);
            if (self.prompt_marks.len > 0) self.allocator.free(self.prompt_marks);
            if (self.saved_prompt_marks.len > 0) self.allocator.free(self.saved_prompt_marks);
            self.cells = new_alt;
            self.saved_cells = new_saved;
            self.wrapped = new_wrapped;
            self.saved_wrapped = new_saved_wrapped;
            self.prompt_marks = new_prompt_marks;
            self.saved_prompt_marks = new_saved_prompt_marks;
            self.size = next_size;
            self.scroll_top = 0;
            self.scroll_bottom = new_rows - 1;
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
            clampSavedCursor(&self.saved_cursor_primary, next_size);
            clampSavedCursor(&self.saved_cursor_alt, next_size);
            self.pending_wrap = false;
            self.last_print = null;
            // CSI 파서 상태/UTF-8 꼬리는 유지(아래 일반 경로와 동일한 이유).
            self.dirty = fullDirty(next_size);
            self.rebuildTabstops(old_cols); // 탭스톱을 새 cols에 맞춘다(겹침 보존·새 열 8칸 기본).
            return;
        }

        // 스크롤백 재-wrap은 보통 지연 마크만 한다(폭이 그대로면 불변이라 생략). 즉시 하면 resize
        // 마다 O(스크롤백) 재할당이라 perf 예산(core_resize_loop)을 수십 배 넘는다 — 실제 재-wrap은
        // 사용자가 과거를 보는 순간(scrollViewport/renderSnapshot) 1회만 일어난다. 그 사이에 활성
        // reflow가 밀어내는 새 폭 행이 ring에 섞여도, 재-wrap은 행별 저장 폭 기준이라 혼재가 안전하다.
        // 단 지금 과거를 보는 중(view_offset>0)이면 즉시 재-wrap하면서 보던 행을 앵커로 offset을
        // 재계산한다 — 바닥으로 튕기지 않고 보던 내용이 유지된다(드물어서 1회 비용 수용).
        if (new_cols != old_cols and self.sb_count > 0) {
            if (self.view_offset > 0) {
                const anchor = self.sb_count - @min(self.view_offset, self.sb_count);
                self.rewrapScrollbackAnchored(new_cols, anchor);
                self.sb_rewrap_pending = false;
            } else {
                self.sb_rewrap_pending = true;
            }
        }

        // reflow: soft-wrap 플래그(wrapped)로 연속 줄(논리 줄)을 합쳐 새 폭에 다시 wrap한다. 넘치는
        // 위쪽 행은 스크롤백으로 밀어낸다. 핵심: 커서 위치는 어떤 셀이 나가는지/행이 soft인지를 절대
        // 바꾸지 않는다(hard 줄끝은 항상 hard로 남아 reflow가 프롬프트를 합치지 않는다 — 라이브 garble
        // 회귀의 근본 원인 차단). 커서의 trailing-blank는 내용을 늘리지 않고 좌표로만 환산한다.

        // 출력 행 상한을 계산해 스크래치를 확보한다(ArrayList realloc churn 제거).
        var total_content: usize = 0;
        {
            var r: u16 = 0;
            while (r < old_rows) : (r += 1) {
                total_content += if (self.wrapped[r]) old_cols else self.trimmedRowLen(r);
            }
        }
        // 출력 행 상한. soft-flush마다 행에 들어가는 최소 내용은 new_cols-1(줄 끝에서 wide glyph가
        // 한 칸을 못 채우고 넘어가는 경우)이므로 재배치 행 수는 total_content/(new_cols-1)로 막힌다.
        // (이전엔 /new_cols로 나눠 wide glyph의 열 낭비를 과소 계산 → 좁은 폭에서 스크래치 OOB였다.)
        // 2*old_rows는 verbatim 커서 줄(≤old_rows)+hard-flush 빈 행(≤old_rows)을, +4는 ceil/열린 행/
        // 방어 flush 여유다. new_cols>=2(clampGridSize)라 new_cols-1>=1.
        const cap_rows: usize = 2 * @as(usize, old_rows) + total_content / (new_cols - 1) + 4;
        try self.ensureReflowScratch(cap_rows, new_cols);
        const scratch = self.reflow_cells;
        const swrap = self.reflow_wrapped;
        const pmarks = self.reflow_prompt_marks; // 산출 행별 OSC 133 태그(소스 옛 행에서 carry)
        const blank: types.Cell = .{};

        var out_rows: usize = 0;
        var oc: u16 = 0;
        @memset(scratch[0..new_cols], blank); // 열린 출력 행 0
        var cursor_out_row: ?usize = null;
        var cursor_out_col: u16 = 0;

        // 커서가 있는 논리 줄(wrapped run)의 범위. 이 줄은 reflow하지 않고 그대로 둔다 — 셸이
        // SIGWINCH로 직접 다시 그린다(xterm.js의 reflowCursorLine=false 기본 동작). 커서가 있는 줄을
        // 재배치하면 커서가 옮겨져, 옛 폭 기준으로 상대 이동(\e[A)하는 셸 redraw가 어긋나 프롬프트가
        // 중복된다. 그 줄은 셸이 알아서 새 폭으로 다시 그리므로 건드리지 않는 게 안전하다.
        var cur_start: u16 = self.cursor.row;
        while (cur_start > 0 and self.wrapped[cur_start - 1]) cur_start -= 1;
        var cur_end: u16 = self.cursor.row;
        while (cur_end + 1 < old_rows and self.wrapped[cur_end]) cur_end += 1;

        var old_r: u16 = 0;
        // 재-wrap되는 논리 줄의 종료코드(OSC 133 D는 leader 한 행에만 스탬프)를 새 줄의 '첫' 산출
        // 행에만 둔다 — 안 그러면 narrow는 한 명령에 거터 바가 여러 개, widen-merge는 leader exit가
        // 분실된다(코드리뷰 #1). 분류(kind)는 줄 전체가 같으니 그대로 carry한다.
        var rewrap_exit: ?i16 = null;
        while (old_r < old_rows) {
            // 커서 줄: reflow 없이 각 옛 행을 그대로(새 폭으로 clip/pad) 출력한다. cur_start는 논리
            // 줄 시작이라 직전 줄이 닫혀 oc==0이다.
            if (old_r == cur_start) {
                var r: u16 = cur_start;
                while (r <= cur_end) : (r += 1) {
                    const dst0 = out_rows * new_cols;
                    @memset(scratch[dst0..][0..new_cols], blank);
                    const n = @min(old_cols, new_cols);
                    @memcpy(scratch[dst0..][0..n], self.cells[self.index(r, 0)..][0..n]);
                    clearTruncatedWideBase(scratch[dst0..][0..new_cols]);
                    swrap[out_rows] = self.wrapped[r];
                    pmarks[out_rows] = self.prompt_marks[r]; // 커서 줄은 verbatim — 태그도 1:1 보존
                    if (r == self.cursor.row) {
                        cursor_out_row = out_rows;
                        cursor_out_col = @min(self.cursor.col, new_cols - 1);
                    }
                    out_rows += 1;
                }
                @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
                oc = 0;
                old_r = cur_end + 1;
                continue;
            }

            // 그 외 논리 줄은 새 폭으로 다시 wrap한다(이 줄엔 커서가 없다).
            // 논리 줄 시작이면 leader의 exit를 잡는다 — 이 줄의 첫 산출 행에만 실린다(아래 finalize).
            if (old_r == 0 or !self.wrapped[old_r - 1]) rewrap_exit = self.prompt_marks[old_r].exit;
            const soft = self.wrapped[old_r];
            // 기여 길이: soft 행은 꽉 찼으므로 전체, hard 행은 뒤 빈칸을 잘라낸 길이.
            const contrib: u16 = if (soft) old_cols else self.trimmedRowLen(old_r);

            var c: u16 = 0;
            while (c < contrib) : (c += 1) {
                const cell = self.cells[self.index(old_r, c)];
                // wide glyph base가 출력 행 끝에 안 들어가면(continuation과 분리 방지) 먼저 soft flush.
                const needs: u16 = if (cell.width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    swrap[out_rows] = true;
                    // 분류는 줄 전체 동일, exit는 첫 산출 행에만(아래 rewrap_exit 소비).
                    pmarks[out_rows] = .{ .kind = self.prompt_marks[old_r].kind, .exit = rewrap_exit };
                    rewrap_exit = null;
                    out_rows += 1;
                    oc = 0;
                    @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
                }
                scratch[out_rows * new_cols + oc] = cell;
                oc += 1;
            }
            if (!soft) {
                // 논리 줄 끝: 부분 출력 행을 hard(wrapped=false)로 닫는다.
                swrap[out_rows] = false;
                pmarks[out_rows] = .{ .kind = self.prompt_marks[old_r].kind, .exit = rewrap_exit };
                rewrap_exit = null;
                out_rows += 1;
                oc = 0;
                @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
            }
            old_r += 1;
        }
        if (oc > 0) { // soft로 끝났는데 더 옛 행이 없음(방어)
            swrap[out_rows] = false;
            pmarks[out_rows] = .{ .kind = self.prompt_marks[old_rows - 1].kind, .exit = rewrap_exit };
            out_rows += 1;
        }

        // 콘텐츠 아래 빈 출력 행(빈 옛 행에서 나온 것)을 잘라낸다. 단 커서 행까지는 남긴다.
        var content_len = out_rows;
        while (content_len > 0) {
            const r = content_len - 1;
            if (cursor_out_row) |cr| {
                if (r <= cr) break;
            }
            if (swrap[r]) break;
            if (!outputRowBlank(scratch, r, new_cols)) break;
            content_len -= 1;
        }

        // 그리드보다 높으면 위(오래된)를 스크롤백으로 밀어낸다. 커서가 콘텐츠 아래면 그 행까지 포함.
        const occupied = if (cursor_out_row) |cr| @max(content_len, cr + 1) else content_len;
        const drop: usize = if (occupied > new_rows) occupied - new_rows else 0;
        const push_count = @min(drop, content_len);

        const next_cells = try self.allocator.alloc(types.Cell, cellCount(next_size));
        errdefer self.allocator.free(next_cells);
        @memset(next_cells, .{});
        const next_wrapped = try self.allocator.alloc(bool, new_rows);
        errdefer self.allocator.free(next_wrapped); // 아래 next_prompt_marks alloc 실패 시 누수 방지
        @memset(next_wrapped, false);
        // OSC 133 태그를 reflow 산출 행(pmarks)에서 carry한다 — resize 후에도 프롬프트/입력/출력 분류가
        // 보존된다(논리 줄은 단일 분류라 옛 행 태그를 그대로 옮긴다, PR1의 .unknown 한계 제거).
        const next_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
        @memset(next_prompt_marks, .{});

        // 밀려나는 위쪽 콘텐츠 행을 그 wrap 플래그·OSC 133 태그와 함께 스크롤백으로(가장 오래된 것부터).
        // 빈 행은 스크롤백을 오염시키므로 보관하지 않는다(빈 화면 resize 등).
        var pr: usize = 0;
        while (pr < push_count) : (pr += 1) {
            if (!outputRowBlank(scratch, pr, new_cols)) {
                const pushed = self.pushScrollback(scratch[pr * new_cols ..][0..new_cols], swrap[pr], pmarks[pr]);
                // 과거를 보는 중이면 새로 밀려든 행만큼 offset도 올린다(scroll-lock — 보던 내용 유지).
                if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.sb_count);
            }
        }

        // 남은 콘텐츠 행을 새 그리드 위쪽에 채운다.
        var dst: usize = 0;
        var src: usize = drop;
        while (src < content_len and dst < new_rows) {
            @memcpy(next_cells[dst * new_cols ..][0..new_cols], scratch[src * new_cols ..][0..new_cols]);
            next_wrapped[dst] = swrap[src];
            next_prompt_marks[dst] = pmarks[src]; // 화면에 남는 행의 태그도 carry
            dst += 1;
            src += 1;
        }

        self.allocator.free(self.cells);
        if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
        if (self.prompt_marks.len > 0) self.allocator.free(self.prompt_marks);
        self.size = next_size;
        self.cells = next_cells;
        self.wrapped = next_wrapped;
        self.prompt_marks = next_prompt_marks;
        self.rebuildTabstops(old_cols); // 탭스톱을 새 cols에 맞춘다(겹침 보존·새 열 8칸 기본).
        // semantic_state(진행 중 영역)는 유지한다 — 커서 줄(보통 활성 프롬프트/입력)이 verbatim으로
        // 보존되므로, resize 후 첫 lineFeed가 같은 영역을 이어 전파해야 한다(reset하면 분류가 끊긴다).
        // scroll region margin은 화면 크기에 묶이므로 resize 때 전체로 리셋한다(xterm 동작).
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;

        // 커서 재배치: 기록한 출력 위치에서 스크롤아웃된 행 수를 빼고 grid 안으로 clamp.
        if (cursor_out_row) |cr_raw| {
            const r = cr_raw -| drop;
            self.cursor.row = @intCast(@min(r, @as(usize, new_rows - 1)));
            self.cursor.col = @min(cursor_out_col, new_cols - 1);
        } else {
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
        }

        // 스크롤 위치는 유지한다(과거를 보는 중이었으면 위의 anchored 재-wrap이 offset을 새 행
        // 수 기준으로 보정했고, 아래 overflow push의 scroll-lock 보정이 이어진다). 범위만 방어.
        self.view_offset = @min(self.view_offset, self.sb_count);
        self.dirty = fullDirty(next_size);
        // 옛 grid 좌표에 묶인 상태(grapheme run, deferred wrap)만 끊는다. CSI 파서 상태와
        // partial UTF-8 꼬리는 grid와 무관한 바이트 스트림 상태라 유지한다 — 리셋하면 PTY read
        // 경계로 쪼개진 시퀀스 한가운데에 resize가 끼었을 때 꼬리 바이트가 글자로 새고 SGR이
        // 유실된다(xterm도 resize에 파서를 리셋하지 않는다).
        self.last_print = null;
        self.pending_wrap = false;
    }

    pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
        var cursor = self.cursor;
        cursor.visible = cursor.visible and self.cursor_visible; // DECTCEM(?25l)이면 숨김
        return .{
            .size = self.size,
            .cursor = cursor,
            .cursor_shape = self.cursor_shape,
            .cursor_blink = self.cursor_blink,
            .cells = self.cells,
            .prompt_marks = self.prompt_marks, // 활성 화면 행 태그를 그대로 빌려준다(zero-copy)
            .last_command_exit = self.last_command_exit,
            .dirty = self.dirty,
        };
    }

    /// 렌더용 snapshot. 바닥(view_offset==0)이면 snapshot()과 같다(합성 없음 — 일반 경로). 위로
    /// 스크롤한 상태면 뷰포트 윈도([스크롤백 ++ 활성])를 viewport_cells에 합성해 돌려준다. 스크롤백
    /// 행이 현재 폭과 다르면(resize) 폭에 맞춰 clamp/pad한다. 과거를 보는 중엔 커서를 숨긴다.
    /// 합성 버퍼는 스크롤 중에만 lazy 할당하므로 일반(바닥) 렌더 경로는 추가 비용이 없다.
    pub fn renderSnapshot(self: *TerminalCore) types.RenderSnapshot {
        if (self.view_offset == 0) {
            // 바닥(스크롤 안 함)에서는 활성 화면이 최상단 — top_abs = sb_count(활성 행의 절대 시작).
            var snap = if (self.preedit) |preedit_bytes| self.snapshotWithPreedit(preedit_bytes) else self.snapshot();
            snap.placements = self.buildPlacementViews(self.sb_count);
            snap.images = self.buildImageViews();
            return snap;
        }
        self.ensureScrollbackRewrapped(); // 과거가 보이는 합성 직전, 행들을 현재 폭으로

        const needed = cellCount(self.size);
        if (self.viewport_cells.len != needed) {
            if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
            self.viewport_cells = self.allocator.alloc(types.Cell, needed) catch {
                self.viewport_cells = &.{};
                return self.snapshot(); // OOM이면 활성 화면으로 폴백(스크롤 뷰 포기)
            };
        }
        // 행별 OSC 133 태그도 보이는 윈도에 맞춰 합성한다(viewport_cells와 병렬, rows 길이).
        if (self.viewport_prompt_marks.len != self.size.rows) {
            if (self.viewport_prompt_marks.len > 0) self.allocator.free(self.viewport_prompt_marks);
            self.viewport_prompt_marks = self.allocator.alloc(types.RowPrompt, self.size.rows) catch {
                self.viewport_prompt_marks = &.{};
                return self.snapshot();
            };
        }

        const cols = self.size.cols;
        var r: u16 = 0;
        while (r < self.size.rows) : (r += 1) {
            const src = self.viewportRow(r);
            const dst = self.viewport_cells[@as(usize, r) * cols ..][0..cols];
            const n = @min(src.len, cols);
            @memcpy(dst[0..n], src[0..n]);
            if (n < cols) @memset(dst[n..cols], .{});
            // 스크롤백 행이 현재 폭보다 넓게 저장돼 clip되면 마지막 칸의 wide glyph base가 잘려
            // half-glyph로 렌더될 수 있다 — resize 경로와 같은 정리를 적용한다.
            clearTruncatedWideBase(dst);
            self.viewport_prompt_marks[r] = self.viewportRowPrompt(r);
        }

        // 위로 스크롤한 뷰포트의 최상단 절대 행 — clipAbsSpanToViewport와 같은 식.
        const top_abs = self.sb_count - @min(self.view_offset, self.sb_count);
        return .{
            .size = self.size,
            // 과거를 보는 중엔 활성 커서가 화면 밖(아래)에 가려져 있으므로 커서를 숨긴다.
            .cursor = .{ .row = 0, .col = 0, .visible = false },
            .cells = self.viewport_cells,
            .prompt_marks = self.viewport_prompt_marks,
            .last_command_exit = self.last_command_exit,
            .placements = self.buildPlacementViews(top_abs),
            .images = self.buildImageViews(),
            .dirty = self.dirty,
        };
    }

    /// 조합 글자들을 row_cells의 draw_col부터 반전 스타일로 그린다. 행 끝을 넘는 글자는 잘린다
    /// (오버레이 폴백 경로에서만 발생 — 삽입형 경로는 호출 전에 공간을 보장한다). draw_col은
    /// 그린 폭만큼 전진해, 호출자가 조합 끝(=커서 표시 위치)을 알 수 있다.
    fn drawPreeditCells(pen: types.Style, preedit_bytes: []const u8, row_cells: []types.Cell, draw_col: *u16) void {
        const cols: u16 = @intCast(row_cells.len);
        var it = (std.unicode.Utf8View.init(preedit_bytes) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const w = width.cellWidth(cp);
            if (w == 0) continue;
            if (@as(u32, draw_col.*) + @as(u32, w) > @as(u32, cols)) break; // 행 끝 — 잘림
            var style = pen;
            style.reverse = true; // 조합 중임을 반전으로 표시(밑줄 렌더는 후속)
            row_cells[draw_col.*] = .{ .codepoint = cp, .style = style, .width = w };
            if (w == 2) row_cells[draw_col.* + 1] = .{ .style = style, .width = 0, .continuation = true };
            draw_col.* += w;
        }
    }

    /// IME 조합 중 텍스트를 커서 위치에 합성한 snapshot. 셀 그리드는 그대로 두고 합성
    /// 버퍼(viewport_cells 재사용)에만 그린다. 커서는 조합 끝으로 옮겨 보여(다음 글자 위치)
    /// 입력기 사용감을 따른다.
    ///
    /// 동작(삽입형 미리보기): 줄 가운데에서 조합하면 커서 뒤 글자들을 조합 폭만큼 오른쪽으로
    /// 밀고 그 자리에 조합 글자를 넣어, 확정 후 셸이 그릴 모습("가나다"의 '나' 앞에서 조합 →
    /// "가[라]나다")을 조합 중에도 미리 보여준다. 합성 버퍼에서만 미는 것이라 실제 그리드와
    /// 셸 상태는 불변이고, 확정 순간 셸이 동일 배치를 그려 화면이 자연스럽게 이어진다.
    ///
    /// 베이스/결정: 터미널 사실상 표준(Ghostty·iTerm2·Terminal.app)은 조합 글자를 커서 칸에
    /// '오버레이'만 해 뒤 글자를 가린다("가라다"). Maru는 이를 한글 입력 결함으로 보고 의도적으로
    /// 삽입형을 택한다(사용자 요청). preedit은 셸 미전송 텍스트라 GUI 입력창처럼 자체 버퍼
    /// 가운데 삽입이 원칙적으론 불가하지만, '합성 버퍼에만' 미리 그려 시각만 흉내낸다. 단 미는
    /// 게 행 밖으로 콘텐츠를 잘라낼 때(줄 끝 근처)나 조합이 행에 안 들어갈 때는 기존 오버레이로
    /// 폴백한다 — 잘려 사라지는 것보다 가리는 편이 덜 혼란스럽다.
    fn snapshotWithPreedit(self: *TerminalCore, preedit_bytes: []const u8) types.RenderSnapshot {
        const needed = cellCount(self.size);
        if (self.viewport_cells.len != needed) {
            if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
            self.viewport_cells = self.allocator.alloc(types.Cell, needed) catch {
                self.viewport_cells = &.{};
                return self.snapshot(); // OOM이면 preedit 표시만 포기
            };
        }
        @memcpy(self.viewport_cells, self.cells[0..needed]);

        const cols = self.size.cols;
        const row = self.cursor.row;
        const cursor_col = self.cursor.col;

        // 잘못된 UTF-8이면 표시만 포기. 동시에 조합 폭(셀 수)을 미리 합산한다 — 삽입형 시프트가
        // '뒤 글자를 얼마나 밀지' 결정하려면 전체 폭이 먼저 필요하다.
        var iter = std.unicode.Utf8View.init(preedit_bytes) catch {
            return self.snapshot();
        };
        var preedit_width: u16 = 0;
        {
            var it = iter.iterator();
            while (it.nextCodepoint()) |cp| preedit_width += @as(u16, width.cellWidth(cp));
        }
        if (preedit_width == 0) return self.snapshot(); // 그릴 게 없음(조합 폭 0)

        const row_cells = self.viewport_cells[@as(usize, row) * cols ..][0..cols];

        // 커서 뒤(포함)의 마지막 콘텐츠 칸. 빈 칸은 codepoint==' ' & 비-continuation이고, wide의
        // 뒤칸(continuation)도 콘텐츠로 친다(앞 base와 한 쌍이라 같이 밀려야 한다).
        const last_content: ?u16 = blk: {
            var found: ?u16 = null;
            var i: u16 = cursor_col;
            while (i < cols) : (i += 1) {
                if (row_cells[i].codepoint != ' ' or row_cells[i].continuation) found = i;
            }
            break :blk found;
        };
        // 삽입형으로 그릴 수 있는 조건: 조합 글자가 행에 들어가고(커서+폭 ≤ cols), 뒤 콘텐츠를
        // 밀어도 행 밖으로 잘리지 않는다(마지막 콘텐츠+폭 < cols). 아니면 오버레이로 폴백.
        const insert_ok = cursor_col < cols and
            @as(u32, cursor_col) + @as(u32, preedit_width) <= @as(u32, cols) and
            (last_content == null or @as(u32, last_content.?) + @as(u32, preedit_width) < @as(u32, cols));

        if (insert_ok) {
            // 커서 뒤 콘텐츠 [cursor_col, lc]를 preedit_width칸 오른쪽으로 민다. @memmove가 겹침을
            // 안전하게 처리한다(insert_ok가 lc+preedit_width < cols를 보장 — 목적지가 행 안).
            if (last_content) |lc| {
                @memmove(
                    row_cells[cursor_col + preedit_width .. lc + 1 + preedit_width],
                    row_cells[cursor_col .. lc + 1],
                );
            }
        }
        var draw_col = cursor_col;
        drawPreeditCells(self.pen, preedit_bytes, row_cells, &draw_col);
        clearTruncatedWideBase(row_cells); // 시프트/잘림으로 끝칸에 wide base만 남으면 정리

        return .{
            .size = self.size,
            // 조합 중에는 블록 커서를 숨긴다 — 반전 스타일 preedit이 커서 역할을 하므로, 조합
            // 끝에 또 블록 커서를 그리면 커서가 둘로 보인다(라이브 제보). 위치는 조합 끝에 둬
            // 후속(후보창 배치 등)이 참조할 수 있게 하되 그리지는 않는다.
            .cursor = .{ .row = row, .col = @min(draw_col, cols - 1), .visible = false },
            .cells = self.viewport_cells,
            .prompt_marks = self.prompt_marks, // preedit은 행 태그를 바꾸지 않는다(활성 그대로)
            .last_command_exit = self.last_command_exit,
            .dirty = self.dirty,
        };
    }

    pub fn takeDirty(self: *TerminalCore) ?types.DirtyRegion {
        // renderer에는 "이번 변경 범위를 소비했다"는 명시적인 지점이 필요하다.
        // 이 함수가 없으면 모든 snapshot이 영원히 dirty처럼 보여서, dirty redraw
        // 테스트가 한 프레임의 변경 소비 여부를 증명할 수 없다.
        const region = self.dirty;
        self.dirty = null;
        return region;
    }

    pub fn clearDirty(self: *TerminalCore) void {
        // 테스트와 향후 renderer가 "이미 그린 상태"를 만들 때 쓴다.
        // dirty bookkeeping을 TerminalCore 안에 두면 renderer가 내부 상태를
        // 직접 고치는 구조로 새는 것을 막을 수 있다.
        self.dirty = null;
    }

    pub fn encodeKey(self: *const TerminalCore, event: input.KeyEvent, buffer: *[input.encoded_key_buffer_len]u8) ![]const u8 {
        return input.encodeKey(event, buffer, self.encodeOptions());
    }

    /// 이 surface의 현재 입력 인코딩 모드. 키를 인코딩하는 쪽(keybinding resolver 경유 포함)이
    /// 매 키마다 읽어 전달한다 — DECCKM은 프로그램이 수시로 켜고 끈다(vim 진입/이탈).
    pub fn encodeOptions(self: *const TerminalCore) input.EncodeOptions {
        return .{ .application_cursor_keys = self.application_cursor_keys, .kitty_flags = self.kitty_flags.current().int(), .application_keypad = self.application_keypad };
    }

    pub fn dumpUtf8(self: *const TerminalCore, allocator: std.mem.Allocator) ![]u8 {
        // E2E assertions need a beginner-friendly way to inspect the screen.
        // This helper is deliberately not a renderer; it serializes cells into
        // plain text so tests can say "the screen contains hello" without
        // needing Metal, fonts, or screenshots.
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        for (0..self.size.rows) |row| {
            if (row != 0) try output.append(allocator, '\n');
            const row_start = self.index(row, 0);
            var codepoints: types.RowCodepoints = .{ .cells = self.cells[row_start..][0..self.size.cols] };
            while (codepoints.next()) |codepoint| {
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buffer);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }

        return output.toOwnedSlice(allocator);
    }

    fn writeCodepoint(self: *TerminalCore, codepoint: u21) void {
        switch (codepoint) {
            '\r' => {
                const old_cursor = self.cursor;
                self.cursor.col = 0;
                self.markCursorMoveDirty(old_cursor, self.cursor);
                self.last_print = null;
            },
            '\n' => {
                self.lineFeed();
                self.last_print = null;
            },
            '\t' => self.writeTab(),
            0x07 => self.bell_pending = true, // BEL: 시스템 벨 요청(platform이 drain — NSSound.beep)
            0x0b, 0x0c => self.lineFeed(), // VT(0x0b)/FF(0x0c): LF처럼 한 줄 내림(col 유지) — printf '\f'/'\v'
            0x0e => self.charset_gl = 1, // SO(shift out): G1을 GL로 호출(ESC ) 0 후 box 문자 시작)
            0x0f => self.charset_gl = 0, // SI(shift in): G0을 GL로 호출(box 문자 끝, ASCII 복귀)
            0x08 => {
                // BS는 정확히 1칸 왼쪽이다(ECMA-48; xterm.js InputHandler.backspace와 동일).
                // 예전엔 wide continuation 위에 서면 base로 한 칸 더 당겼는데, 셸은 BS를 항상
                // 1칸으로 계산하고 wide 글자엔 BS를 두 번 보내므로(zsh 캡처: "\b\b  \b\b")
                // 그 친절이 셸 계산과 한 칸 어긋나 지우기 공백이 프롬프트를 침범했다(라이브
                // 한글 삭제에서 실제 발생). continuation 위에 선 커서의 다음 쓰기는
                // clearCellForWrite가 base/continuation을 정리하므로 안전하다.
                const old_cursor = self.cursor;
                if (self.cursor.col > 0) self.cursor.col -= 1;
                self.markCursorMoveDirty(old_cursor, self.cursor);
                self.last_print = null;
            },
            else => {
                if (codepoint < 0x20) return;
                // G3: GL에 호출된 G-set(G0/G1)의 charset으로 변환한다(dec_special이면 0x60..0x7e→box 문자,
                // ascii면 무변환). box 문자는 width 1·non-combining이라 아래 grapheme/combining 로직과 호환.
                const cp = self.translateCharset(codepoint);
                if (width.cellWidth(cp) == 0) {
                    // VS16(U+FE0F) 등 변형 선택자/결합 문자는 0폭 combining으로 앞 글자에 붙인다.
                    // 기본(mode 2027 off)은 폭을 EAW 그대로 둔다 — zsh의 ZLE는 ❤+VS16을 EAW 1칸으로
                    // 보므로, 폭을 키우면 zsh의 redraw(CSI <N> D 재출력)가 어긋나 붙여넣기가 깨진다.
                    self.attachCombiningMark(cp);
                    // mode 2027(grapheme cluster)에서는 앱과 너비를 합의한 상태라, VS16이 앞 글자를
                    // 이모지 표현(width 2)으로 승격해 풀사이즈로 그려도 안전하다(❤+VS16 = ❤️ 2칸).
                    if (self.grapheme_cluster_mode and cp == 0xFE0F) self.promoteLastToEmojiWidth();
                    return;
                }
                // mode 2027: grapheme을 한 셀로 묶는다(앱과 너비 합의 상태라 안전).
                if (self.grapheme_cluster_mode) {
                    // 스킨톤 modifier(👍 + 🏽): 앞 이모지에 combining으로 붙여 한 글자. base는 이미
                    // width 2(EAW Wide)라 폭 승격 불필요.
                    if (isSkinToneModifier(cp) and self.lastCellIsWideEmoji()) {
                        self.attachCombiningMark(cp);
                        return;
                    }
                    // 국기: 지역 표시자(RI) 2개를 한 셀(width 2)로. 직전이 짝 없는 RI면 combining + 승격.
                    if (isRegionalIndicator(cp) and self.lastCellIsLoneRegionalIndicator()) {
                        self.attachCombiningMark(cp);
                        self.promoteLastToEmojiWidth();
                        return;
                    }
                }
                self.putCell(cp);
            },
        }
    }

    /// `ESC <intermediate> <final>`로 G-set을 지정한다. intermediate '('=G0·')'=G1, final '0'=dec_special·
    /// 'B'=ascii(그 외 charset은 미지원이라 ascii로). G2/G3('*'/'+')는 maru가 호출(SS2/SS3)을 안 해 무시.
    fn designateCharset(self: *TerminalCore, intermediate: u8, final: u8) void {
        const set: Charset = switch (final) {
            '0' => .dec_special, // DEC special graphics(box drawing)
            else => .ascii, // 'B'(ASCII)·기타 미지원 → ascii
        };
        switch (intermediate) {
            '(' => self.charset_g0 = set, // ESC ( = G0 지정
            ')' => self.charset_g1 = set, // ESC ) = G1 지정
            else => {}, // G2/G3·기타 intermediate는 소비(미지원)
        }
    }

    /// GL에 호출된 G-set(charset_gl)의 charset으로 codepoint를 변환한다.
    fn translateCharset(self: *const TerminalCore, codepoint: u21) u21 {
        const set = if (self.charset_gl == 0) self.charset_g0 else self.charset_g1;
        return switch (set) {
            .ascii => codepoint,
            .dec_special => decSpecial(codepoint),
        };
    }

    /// DEC special graphics: 0x60..0x7e를 box-drawing/기호 Unicode로. 그 밖은 그대로. 베이스: VT100 special
    /// graphics(Ghostty `charsets.zig` dec_special 표와 동작 비교 — 코드 표현 미복사).
    fn decSpecial(codepoint: u21) u21 {
        return switch (codepoint) {
            0x60 => 0x25C6, // ◆
            0x61 => 0x2592, // ▒
            0x62 => 0x2409, // ␉ HT
            0x63 => 0x240C, // ␌ FF
            0x64 => 0x240D, // ␍ CR
            0x65 => 0x240A, // ␊ LF
            0x66 => 0x00B0, // °
            0x67 => 0x00B1, // ±
            0x68 => 0x2424, // ␤ NL
            0x69 => 0x240B, // ␋ VT
            0x6a => 0x2518, // ┘
            0x6b => 0x2510, // ┐
            0x6c => 0x250C, // ┌
            0x6d => 0x2514, // └
            0x6e => 0x253C, // ┼
            0x6f => 0x23BA, // ⎺
            0x70 => 0x23BB, // ⎻
            0x71 => 0x2500, // ─
            0x72 => 0x23BC, // ⎼
            0x73 => 0x23BD, // ⎽
            0x74 => 0x251C, // ├
            0x75 => 0x2524, // ┤
            0x76 => 0x2534, // ┴
            0x77 => 0x252C, // ┬
            0x78 => 0x2502, // │
            0x79 => 0x2264, // ≤
            0x7a => 0x2265, // ≥
            0x7b => 0x03C0, // π
            0x7c => 0x2260, // ≠
            0x7d => 0x00A3, // £
            0x7e => 0x00B7, // ·
            else => codepoint,
        };
    }

    fn completePendingUtf8(self: *TerminalCore, bytes: []const u8, index_: usize) !usize {
        const sequence_len = utf8SequenceLength(self.utf8_tail[0]) catch {
            self.utf8_tail_len = 0;
            return error.InvalidUtf8;
        };
        const needed = sequence_len - self.utf8_tail_len;
        const available = bytes.len - index_;
        const take = @min(needed, available);

        @memcpy(
            self.utf8_tail[self.utf8_tail_len .. self.utf8_tail_len + take],
            bytes[index_ .. index_ + take],
        );
        self.utf8_tail_len += take;

        if (self.utf8_tail_len < sequence_len) return bytes.len;

        const codepoint = decodeUtf8(self.utf8_tail[0..sequence_len]) catch {
            self.utf8_tail_len = 0;
            return error.InvalidUtf8;
        };
        self.utf8_tail_len = 0;
        self.writeCodepoint(codepoint);
        return index_ + take;
    }

    fn storePendingUtf8(self: *TerminalCore, bytes: []const u8) void {
        // PTY reads can stop in the middle of a codepoint. Keeping the partial
        // bytes inside TerminalCore preserves the layer boundary: PTY remains a
        // byte transport and does not need text-decoding logic.
        @memcpy(self.utf8_tail[0..bytes.len], bytes);
        self.utf8_tail_len = bytes.len;
    }

    /// col이 탭스톱인가. tabstops 배열 안이면 그 값, 밖(OOM 등 길이 불일치)이면 8칸 기본으로 폴백.
    fn isTabstop(self: *const TerminalCore, col: u16) bool {
        if (col < self.tabstops.len) return self.tabstops[col];
        return col % 8 == 0;
    }

    /// 탭스톱을 8칸 기본으로 되돌린다(RIS·TBC 3). 길이 불일치(OOM)면 가능한 만큼만.
    fn resetTabstops(self: *TerminalCore) void {
        for (self.tabstops, 0..) |*t, c| t.* = (c % 8 == 0);
    }

    /// resize 후 탭스톱 배열을 새 cols에 맞춘다. 겹치는 열은 보존(HTS/TBC 유지), 새 열은 8칸 기본. OOM이면
    /// 기존 배열 유지(isTabstop이 8칸으로 폴백) — best-effort라 resize를 실패시키지 않는다.
    fn rebuildTabstops(self: *TerminalCore, old_cols: u16) void {
        const new_cols = self.size.cols;
        if (new_cols == self.tabstops.len) return; // 폭 불변이면 그대로
        const buf = self.allocator.alloc(bool, new_cols) catch return;
        for (buf, 0..) |*t, c| {
            t.* = if (c < old_cols and c < self.tabstops.len) self.tabstops[c] else (c % 8 == 0);
        }
        if (self.tabstops.len > 0) self.allocator.free(self.tabstops);
        self.tabstops = buf;
    }

    fn writeTab(self: *TerminalCore) void {
        // 탭은 수평 이동이다 — 다음 탭스톱으로 커서만 옮기고(끝 칸에 멈춤), 지나는 셀의 내용은 건드리지
        // 않는다. xterm.js(InputHandler.tab)·Ghostty(horizontalTab)도 커서만 이동한다 — putCell(' ')로 공백을
        // 찍으면 CR 후 탭 redraw에서 기존 글자가 지워진다. 탭은 wrap하지 않으므로 pending_wrap도 끈다.
        self.pending_wrap = false;
        if (self.size.cols == 0) return;
        const last = self.size.cols - 1;
        if (self.cursor.col >= last) return; // 이미 마지막 칸
        var next = self.cursor.col + 1;
        while (next < last and !self.isTabstop(next)) next += 1; // 다음 탭스톱(없으면 마지막 칸)에 멈춤
        self.cursor.col = next;
    }

    /// CBT(CSI Ps Z): 역방향으로 Ps개 탭스톱 이동. 0번째 칸을 넘지 않는다.
    fn cursorBackTab(self: *TerminalCore, count: u16) void {
        self.pending_wrap = false;
        const old_cursor = self.cursor;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (self.cursor.col == 0) break;
            var prev = self.cursor.col - 1;
            while (prev > 0 and !self.isTabstop(prev)) prev -= 1; // 이전 탭스톱(없으면 col 0)으로
            self.cursor.col = prev;
        }
        self.markCursorMoveDirty(old_cursor, self.cursor);
    }

    /// TBC(CSI Ps g): Ps=0(기본) 커서 열 탭스톱 제거, Ps=3 전체 제거. 그 외 Ps는 무시.
    fn clearTabstop(self: *TerminalCore, mode: u16) void {
        switch (mode) {
            0 => if (self.cursor.col < self.tabstops.len) {
                self.tabstops[self.cursor.col] = false;
            },
            3 => @memset(self.tabstops, false),
            else => {},
        }
    }

    fn putCell(self: *TerminalCore, codepoint: u21) void {
        if (self.size.cols == 0 or self.size.rows == 0) return;
        // deferred autowrap: 직전 글자가 마지막 칸을 채웠으면(pending_wrap), 이 글자를 그리기
        // 전에 다음 줄 첫 칸으로 넘긴다(바닥이면 scroll). 이렇게 다음 글자 시점에 wrap해야 줄을
        // 정확히 채운 마지막 글자마다 빈 줄이 끼지 않는다(표준 VT 동작, zsh prompt 등이 의존).
        if (self.pending_wrap) {
            // 다음 줄로 넘긴다. lineFeed가 pending_wrap을 끈다. 이 행은 autowrap으로 다음 줄로 이어지는
            // soft-wrap이다(reflow가 이 플래그로 잇는다). soft-wrap 플래그는 lineFeed '후'에 세운다 — 커서가
            // scroll_bottom이라 lineFeed가 scroll이면 scrollRangeUp의 경계 fixup이 lineFeed 전에 세운
            // wrapped를 지우기 때문이다(promoteLastToEmojiWidth와 같은 이유). scroll 여부와 무관하게 "직전
            // 줄(row-1)이 이 줄로 이어진다"를 정확히 남긴다.
            self.cursor.col = 0;
            self.lineFeed();
            if (self.cursor.row > 0) self.wrapped[self.cursor.row - 1] = true;
        }
        if (self.cursor.col >= self.size.cols) self.cursor.col = self.size.cols - 1;
        if (self.cursor.row >= self.size.rows) self.cursor.row = self.size.rows - 1;

        const cell_width: u2 = width.cellWidth(codepoint);
        // wide glyph(2칸)가 줄 끝(마지막 칸, 1칸만 남음)에 안 들어가면 통째로 다음 줄로 넘긴다
        // (이전 줄 마지막 칸은 빈칸으로 남는다). grid는 항상 cols>=2라(clampGridSize) 넘긴 뒤엔
        // 반드시 들어가므로, 칸을 줄이는 degrade 없이 그대로 width 2로 쓴다.
        if (cell_width == 2 and self.cursor.col + 1 >= self.size.cols) {
            // wide glyph를 통째로 다음 줄로 넘긴다 — 직전 줄이 이 줄로 이어지는 soft-wrap이다. 플래그는 위
            // pending_wrap과 같은 이유로 lineFeed '후'에 세운다(scroll 시 scrollRangeUp fixup이 지우지 않게).
            self.cursor.col = 0;
            self.lineFeed();
            if (self.cursor.row > 0) self.wrapped[self.cursor.row - 1] = true;
        }

        const row = self.cursor.row;
        const col = self.cursor.col;
        // G6 IRM(insert mode): 켜져 있으면 쓰기 전에 커서 위치에 cell_width칸을 삽입(오른쪽 밀기) — 덮어쓰기 대신
        // 삽입이 된다. insertChars가 커서는 안 옮기고 줄만 민다.
        if (self.insert_mode) self.insertChars(cell_width);
        // 이 행에 새로 쓰므로 wrap 상태를 리셋한다. 다시 채워 마지막 칸을 넘기면 위 autowrap 분기가
        // true로 재설정한다. 덕분에 셸이 한 줄을 다시 그리면(redraw) wrap 플래그가 스스로 교정된다.
        self.wrapped[row] = false;

        self.clearCellForWrite(row, col);
        if (cell_width == 2) self.clearCellForWrite(row, col + 1);

        self.cells[self.index(row, col)] = .{
            .codepoint = codepoint,
            .style = self.pen,
            .width = cell_width,
            .link = self.pen_link,
        };
        if (cell_width == 2) {
            self.cells[self.index(row, col + 1)] = .{
                .style = self.pen,
                .width = 0,
                .continuation = true,
                .link = self.pen_link,
            };
        }
        self.last_print = .{ .row = row, .col = col };
        self.last_printed_cp = codepoint; // G5 REP: 직전 출력 글자 추적
        self.markDirty(self.cursor.row);

        if (self.cursor.col + cell_width < self.size.cols) {
            self.cursor.col += cell_width;
        } else {
            // 마지막 칸을 채웠다. autowrap(DECAWM)이 켜져 있으면 커서를 마지막 칸에 두고 pending_wrap을 세워
            // 다음 printable 글자가 먼저 다음 줄로 넘어가게 한다(deferred autowrap). off(?7l)면 wrap 없이
            // 마지막 칸에 머물러 다음 글자가 그 칸을 덮어쓴다(G8).
            self.cursor.col = self.size.cols - 1;
            if (self.autowrap) self.pending_wrap = true;
        }
    }

    fn isSkinToneModifier(codepoint: u21) bool {
        return codepoint >= 0x1F3FB and codepoint <= 0x1F3FF; // Fitzpatrick modifiers
    }

    fn isRegionalIndicator(codepoint: u21) bool {
        return codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF;
    }

    /// 직전 출력 셀이 짝 없는(아직 combining 안 붙은) wide 이모지 base인지 — 스킨톤 modifier를
    /// 거기 붙이기 위함. combining이 이미 있으면(예: 국기의 2번째 RI) 거기에 스킨톤을 또 붙이면
    /// 그 슬롯(하나뿐)을 덮어써 국기가 깨지므로 제외한다.
    fn lastCellIsWideEmoji(self: *const TerminalCore) bool {
        const last = self.last_print orelse return false;
        const cell = self.cells[self.index(last.row, last.col)];
        return cell.width == 2 and cell.combining == null;
    }

    /// 직전 출력 셀이 짝 없는(combining 안 붙은) 지역 표시자인지 — 다음 RI와 국기로 묶기 위함.
    fn lastCellIsLoneRegionalIndicator(self: *const TerminalCore) bool {
        const last = self.last_print orelse return false;
        const cell = self.cells[self.index(last.row, last.col)];
        return isRegionalIndicator(cell.codepoint) and cell.combining == null;
    }

    /// wide glyph의 오른쪽 continuation 칸(0폭). base의 style/link를 물려받는다 — putCell과
    /// promoteLastToEmojiWidth가 같은 표현을 쓰게 한다.
    fn wideContinuationCell(style: types.Style, link: u32) types.Cell {
        return .{ .style = style, .width = 0, .continuation = true, .link = link };
    }

    /// grapheme(VS16/RI 페어 등)이 붙은 직전 base 셀을 width 1 -> 2로 승격한다(이미 2면 무시).
    /// mode 2027에서만 호출되므로 앱과 너비가 합의된 상태다.
    fn promoteLastToEmojiWidth(self: *TerminalCore) void {
        const last = self.last_print orelse return;
        const base_idx = self.index(last.row, last.col);
        if (self.cells[base_idx].width == 2) return; // 이미 wide

        // base가 줄 마지막 칸이면 오른쪽 continuation 칸이 없다. 폭만 키우면 안 되고(다음 칸이
        // 다음 글자라 침범), wide glyph autowrap처럼 base를 통째로 다음 줄로 옮겨 2칸을 차지하게
        // 한다 — 안 그러면 mode 2027에서도 줄 끝 이모지가 width 1로 남아 앱과 너비가 어긋난다.
        if (last.col + 1 >= self.size.cols) {
            const base = self.cells[base_idx];
            self.cells[base_idx] = .{}; // 이전 줄 마지막 칸은 빈칸으로
            self.markDirty(last.row);
            self.cursor.col = 0;
            self.lineFeed();
            const row = self.cursor.row;
            // soft-wrap 플래그는 lineFeed '후'에 세운다. lineFeed가 scroll(커서가 scroll_bottom)일
            // 때 scrollRangeUp의 경계 fixup이 lineFeed 전에 세운 wrapped를 지우기 때문이다 —
            // scroll 여부와 무관하게 "이전 줄(row-1)이 이 이모지 줄로 이어진다"를 정확히 남긴다.
            if (row > 0) self.wrapped[row - 1] = true;
            self.wrapped[row] = false;
            self.cells[self.index(row, 0)] = base;
            self.cells[self.index(row, 0)].width = 2;
            self.cells[self.index(row, 1)] = wideContinuationCell(base.style, base.link);
            self.last_print = .{ .row = row, .col = 0 };
            self.markDirty(row);
            if (2 < self.size.cols) {
                self.cursor.col = 2;
                self.pending_wrap = false;
            } else {
                self.cursor.col = self.size.cols - 1;
                self.pending_wrap = true;
            }
            return;
        }

        self.cells[base_idx].width = 2;
        self.cells[self.index(last.row, last.col + 1)] = wideContinuationCell(self.cells[base_idx].style, self.cells[base_idx].link);
        self.markDirty(last.row);
        // 커서가 base 바로 뒤(width-1 전진 위치)면 2칸짜리로 한 칸 더 민다.
        if (self.cursor.row == last.row and self.cursor.col == last.col + 1) {
            if (last.col + 2 < self.size.cols) {
                self.cursor.col = last.col + 2;
                self.pending_wrap = false;
            } else {
                self.cursor.col = self.size.cols - 1;
                self.pending_wrap = true;
            }
        }
    }

    fn attachCombiningMark(self: *TerminalCore, codepoint: u21) void {
        // A combining mark is zero-width and belongs to the most recently
        // printed base cell, wherever the cursor ended up. Deriving the base
        // from the cursor was wrong at the last column (cursor parks on the
        // base, so cursor-1 pointed at the previous glyph) and after a line
        // feed (cursor sat over a blank cell on the new row). With no base on
        // the current run (stream start, or right after CR/LF), the mark has
        // nothing to attach to and is dropped.
        const last = self.last_print orelse return;
        self.cells[self.index(last.row, last.col)].combining = codepoint;
        self.markDirty(last.row);
    }

    fn clearCellForWrite(self: *TerminalCore, row: u16, col: u16) void {
        const cell_index = self.index(row, col);
        const cell = self.cells[cell_index];
        if (cell.continuation and col > 0) {
            const previous_index = self.index(row, col - 1);
            if (self.cells[previous_index].width == 2) {
                self.cells[previous_index] = .{};
            }
        }
        if (cell.width == 2 and col + 1 < self.size.cols) {
            self.cells[self.index(row, col + 1)] = .{};
        }
        self.cells[cell_index] = .{};
    }

    fn lineFeed(self: *TerminalCore) void {
        if (self.size.rows == 0) return;
        // LF(및 IND)는 deferred autowrap을 무효화한다. 비-scroll 분기는 markCursorMoveDirty가
        // 끄지만, scroll 분기(scrollRegionUp)는 그걸 안 거치므로 여기서 한 번에 끈다. 안 그러면
        // 마지막 행이 꽉 찬(pending_wrap) 상태에서 bare LF가 와도 플래그가 남아, 다음 printable
        // 글자가 또 한 줄 내려가(scroll) 직전 줄을 잃는다(이중 스크롤).
        self.pending_wrap = false;
        // 스크롤/이동으로 grapheme run이 끝난다 — 다음 combining mark가 옮겨진 셀에 붙지 않게.
        // (\n 경로는 writeCodepoint가 이미 끊지만 ESC D(IND)는 이 함수로 직행한다.)
        self.last_print = null;
        // 커서가 scroll region 하단 margin이면 region을 위로 스크롤(커서는 그대로). 그 외엔 화면
        // 끝 전까지 한 줄 내려간다(region 위/아래 모두 동일). scrollRegionUp의 fullDirty가 커서
        // 행까지 다시 칠하므로 scroll 분기는 cursor-move diff가 따로 필요 없다.
        if (self.cursor.row == self.scroll_bottom) {
            self.scrollRegionUp();
            return;
        }
        if (self.cursor.row + 1 < self.size.rows) {
            const old_cursor = self.cursor;
            self.cursor.row += 1;
            self.markCursorMoveDirty(old_cursor, self.cursor);
            // OSC 133 영역이 활성이면(프롬프트/입력/출력) 다음 행에 전파한다 — 여러 줄 프롬프트·출력이
            // 전부 같은 분류로 태깅된다. unknown 상태에선 기존 태그를 지우지 않는다(분류 보존).
            if (self.semantic_state != .unknown) self.prompt_marks[self.cursor.row] = .{ .kind = self.semantic_state };
        }
    }

    /// RI(ESC M): 커서를 한 줄 올리고, scroll region 상단 margin이면 region을 아래로 스크롤한다.
    fn reverseIndex(self: *TerminalCore) void {
        if (self.size.rows == 0) return;
        self.pending_wrap = false;
        self.last_print = null; // IND와 동일 — 스크롤/이동으로 grapheme run 종료
        if (self.cursor.row == self.scroll_top) {
            self.scrollRegionDown();
            return;
        }
        if (self.cursor.row > 0) {
            const old_cursor = self.cursor;
            self.cursor.row -= 1;
            self.markCursorMoveDirty(old_cursor, self.cursor);
        }
    }

    /// scroll region [top, bottom]을 위로 한 줄 민다. top==0(화면 최상단)일 때만 밀려나는 줄을
    /// 스크롤백에 보관한다 — 화면 위로 나가는 줄만 history다. 부분 region(top>0)의 스크롤아웃은
    /// 버린다(xterm 동작). 기본 region [0, rows-1]이면 전체 화면 스크롤과 같다.
    fn scrollRegionUp(self: *TerminalCore) void {
        // alt screen의 출력은 history가 아니다(vim 화면이 스크롤백을 오염시키지 않게).
        const push = self.scroll_top == 0 and !self.alt_active;
        self.scrollRangeUp(self.scroll_top, self.scroll_bottom, 1, push);
    }

    fn scrollRegionDown(self: *TerminalCore) void {
        self.scrollRangeDown(self.scroll_top, self.scroll_bottom, 1);
    }

    /// [top, bottom] 범위를 위로 n줄 민다(아래쪽에 빈 줄 n개). push_history면 밀려나는 행들을
    /// 스크롤백에 보관한다 — LF 스크롤만 history고, DL(줄 삭제) 같은 편집 연산은 보관하지 않는다
    /// (xterm 동작). n줄을 한 번의 블록 이동으로 처리해 IL/DL n이 O(범위)다(줄당 반복 아님).
    fn scrollRangeUp(self: *TerminalCore, top: u16, bottom: u16, count: u16, push_history: bool) void {
        if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
        // bottom == top(한 줄 범위)도 허용한다 — IL/DL이 region 마지막 행에서 그 행만 비운다.
        if (bottom < top or bottom >= self.size.rows) return;
        const span: u16 = bottom - top + 1;
        const n = @min(count, span);

        // 선택 좌표가 자연히 따라가는 경우는 전체 화면 history 스크롤(아래 push + eviction 보정)뿐.
        // 부분 region 스크롤·DL(push 없음)은 활성 영역 안에서 행만 옮겨 abs 좌표가 어긋나므로 해제.
        if (!(push_history and top == 0 and bottom == self.size.rows - 1)) self.invalidateSelection();

        // 전체 화면 LF 스크롤일 때만 새로 생기는 맨 아래 blank 행이 현재 semantic 영역에 속한다
        // (커서가 거기로 이어져 명령 출력 등이 계속된다). 부분 region 스크롤·IL/DL의 빈 행은 .unknown.
        const lf_scroll = push_history and top == 0 and bottom == self.size.rows - 1;

        if (push_history) {
            var pr: u16 = 0;
            while (pr < n) : (pr += 1) {
                // 밀려나는 행의 OSC 133 태그도 함께 스크롤백으로 보낸다(분류 보존).
                const pushed = self.pushScrollback(self.cells[self.index(top + pr, 0)..][0..self.size.cols], self.wrapped[top + pr], self.prompt_marks[top + pr]);
                // 과거를 보는 중(view_offset>0)이면 같은 내용을 계속 보도록 offset도 올린다
                // (scroll-lock). 보관 실패(OOM) 시엔 보정하지 않는다 — 뷰가 내용과 어긋나지 않게.
                if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.sb_count);
            }
        }

        var row: u16 = top + n;
        while (row <= bottom) : (row += 1) {
            const dst_start = self.index(row - n, 0);
            const src_start = self.index(row, 0);
            @memcpy(
                self.cells[dst_start .. dst_start + self.size.cols],
                self.cells[src_start .. src_start + self.size.cols],
            );
            self.wrapped[row - n] = self.wrapped[row];
            self.prompt_marks[row - n] = self.prompt_marks[row]; // 태그를 옮긴 내용과 함께 끌어온다
        }

        var blank_row: u16 = bottom + 1 - n;
        while (blank_row <= bottom) : (blank_row += 1) {
            const blank_start = self.index(blank_row, 0);
            // BCE(배경색 erase): 스크롤로 새로 들어오는 빈 줄은 현재 pen의 배경으로 채운다(EL/ED와 같은 규칙).
            // 베이스: xterm.js getNullCell이 erase 속성(fg+bg)을 carry — 우리도 full pen을 carry(default pen이면
            // 기존과 동일한 default blank). Ghostty는 bgCell()로 배경만 좁히는데, 우리는 EL/ED와의 내부 일관성을
            // 위해 full pen으로 통일한다(bg-only 정제는 후속). 색 배경 화면이 스크롤될 때 빈 줄이 그 색을 잇는다.
            @memset(self.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.pen });
            self.wrapped[blank_row] = false;
            self.prompt_marks[blank_row] = .{ .kind = if (lf_scroll) self.semantic_state else .unknown };
        }
        // 범위 경계의 wrap 정합: shift가 old wrapped[bottom]("old bottom ↔ bottom+1" — 범위 밖과의
        // 연속)을 bottom-n으로 끌어왔는데, bottom+1은 안 움직였으니 그 연속은 깨졌다. 마찬가지로
        // 범위 위 행(top-1)이 주장하던 "top으로의 연속"도 top 내용이 바뀌어 깨졌다. 안 끊으면
        // 다음 resize reflow가 무관한 줄(상태줄 등)을 한 논리 줄로 합친다.
        if (bottom + 1 >= n and bottom + 1 - n > top) self.wrapped[bottom - n] = false;
        if (top > 0) self.wrapped[top - 1] = false;
        self.dirty = fullDirty(self.size);
    }

    /// [top, bottom] 범위를 아래로 n줄 민다(top쪽에 빈 줄 n개 삽입). 아래로 밀려나는 줄은
    /// history가 아니므로 버린다(스크롤백에 안 넣는다).
    fn scrollRangeDown(self: *TerminalCore, top: u16, bottom: u16, count: u16) void {
        if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
        // bottom == top(한 줄 범위)도 허용한다(scrollRangeUp과 동일한 이유).
        if (bottom < top or bottom >= self.size.rows) return;
        const span: u16 = bottom - top + 1;
        const n = @min(count, span);

        // 아래로 스크롤(IL/RI)은 항상 활성 영역 안에서 행을 옮기므로 선택 좌표가 어긋난다 — 해제.
        self.invalidateSelection();

        var row: u16 = bottom;
        while (row >= top + n) : (row -= 1) {
            const dst_start = self.index(row, 0);
            const src_start = self.index(row - n, 0);
            @memcpy(
                self.cells[dst_start .. dst_start + self.size.cols],
                self.cells[src_start .. src_start + self.size.cols],
            );
            self.wrapped[row] = self.wrapped[row - n];
            self.prompt_marks[row] = self.prompt_marks[row - n]; // OSC 133 태그도 옮긴 내용과 함께(scrollRangeUp 대칭)
        }

        var blank_row: u16 = top;
        while (blank_row < top + n) : (blank_row += 1) {
            const blank_start = self.index(blank_row, 0);
            // BCE: 아래로 밀며 생기는 빈 줄(RI/IL)도 현재 pen 배경으로 채운다(scrollRangeUp과 같은 규칙).
            @memset(self.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.pen });
            self.wrapped[blank_row] = false;
            self.prompt_marks[blank_row] = .{}; // 삽입된 빈 행은 비분류(잔여 태그 → 헛 거터 방지)
        }
        // 범위 경계의 wrap 정합(scrollRangeUp과 대칭): 새 bottom 행(=old bottom-n 내용)이 범위 밖
        // bottom+1로 이어진다는 플래그는 거짓이고, top-1 행의 "top으로의 연속"도 top이 빈 줄이 돼
        // 깨졌다.
        self.wrapped[bottom] = false;
        if (top > 0) self.wrapped[top - 1] = false;
        self.dirty = fullDirty(self.size);
    }

    /// IL(CSI Ps L): 커서 행에 빈 줄 n개를 삽입한다. 커서 행~region 하단이 아래로 밀리고 넘치는
    /// 줄은 버려진다. 커서가 scroll region 밖이면 무시. 후처리로 커서를 행 첫 칸으로 옮긴다(CR —
    /// xterm/DEC 동작). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스.
    fn insertLines(self: *TerminalCore, count: u16) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollRangeDown(self.cursor.row, self.scroll_bottom, count);
        self.pending_wrap = false;
        self.cursor.col = 0;
        self.last_print = null;
    }

    /// DL(CSI Ps M): 커서 행부터 n줄을 삭제한다. 아래 줄들이 올라오고 region 하단에 빈 줄이 생긴다.
    /// 삭제된 줄은 history가 아니다(스크롤백에 안 넣음). 커서가 region 밖이면 무시, 후처리 CR.
    fn deleteLines(self: *TerminalCore, count: u16) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollRangeUp(self.cursor.row, self.scroll_bottom, count, false);
        self.pending_wrap = false;
        self.cursor.col = 0;
        self.last_print = null;
    }

    /// DECSTBM(CSI Pt ; Pb r): scroll region을 설정한다. 1-indexed, 기본 Pt=1·Pb=rows. region 안으로
    /// clamp하고 최소 2행이 아니면 무시한다. 설정 후 커서를 home(0,0)으로 옮긴다(DECOM off 기준).
    fn setScrollRegion(self: *TerminalCore) void {
        const rows = self.size.rows;
        if (rows == 0) return;
        const top: u16 = self.csiParam(0, 1) - 1;
        const bottom: u16 = @min(self.csiParam(1, rows), rows) - 1;
        if (top >= bottom or bottom >= rows) return; // 2행 미만이면 무시
        self.scroll_top = top;
        self.scroll_bottom = bottom;
        const old_cursor = self.cursor;
        // DECSTBM 후 커서를 origin home으로 — DECOM이면 region 상단, 아니면 화면 좌상단(xterm 동작).
        self.cursor = .{ .row = if (self.origin_mode) self.scroll_top else 0, .col = 0 };
        self.pending_wrap = false;
        self.markCursorMoveDirty(old_cursor, self.cursor);
    }

    fn markDirty(self: *TerminalCore, row: u16) void {
        if (self.dirty) |*dirty| {
            if (row < dirty.start_row) dirty.start_row = row;
            if (row > dirty.end_row) dirty.end_row = row;
            return;
        }

        self.dirty = .{ .start_row = row, .end_row = row };
    }

    fn markCursorMoveDirty(self: *TerminalCore, old_cursor: types.Cursor, new_cursor: types.Cursor) void {
        // 명시적 커서 이동(CR/LF/backspace/CUP/CHA/VPA/CUU..CUB 등 이 함수를 거치는 모든 이동)은
        // deferred autowrap을 무효화한다. putCell의 cursor 전진은 이 함수를 거치지 않으므로
        // pending_wrap을 직접 관리한다. 위치가 안 바뀌는 이동(아래 early-return)도 wrap 의도는
        // 취소되므로 early-return 전에 끈다.
        self.pending_wrap = false;
        // Cursor is drawn as an overlay, not as part of the cell glyph bitmap.
        // Moving it still changes pixels: the old cursor cell must be erased
        // and the new cursor cell must be drawn. Keeping that dirty decision in
        // TerminalCore prevents a future renderer from guessing dirty rows by
        // comparing snapshots on its own.
        if (old_cursor.row == new_cursor.row and
            old_cursor.col == new_cursor.col and
            old_cursor.visible == new_cursor.visible)
        {
            return;
        }

        if (old_cursor.visible) self.markCursorRowDirty(old_cursor.row);
        if (new_cursor.visible) self.markCursorRowDirty(new_cursor.row);
    }

    fn markCursorRowDirty(self: *TerminalCore, row: u16) void {
        if (self.size.rows == 0) return;
        self.markDirty(@min(row, self.size.rows - 1));
    }

    fn index(self: *const TerminalCore, row: usize, col: usize) usize {
        return row * self.size.cols + col;
    }
};

fn utf8SequenceLength(first_byte: u8) !usize {
    return std.unicode.utf8ByteSequenceLength(first_byte) catch error.InvalidUtf8;
}

fn decodeUtf8(bytes: []const u8) !u21 {
    return std.unicode.utf8Decode(bytes) catch error.InvalidUtf8;
}

fn cellCount(size: types.Size) usize {
    return @as(usize, size.cols) * @as(usize, size.rows);
}

/// grid를 최소 cols>=2, rows>=1로 맞춘다. 한 cell 글자 모델은 wide glyph(2칸)의 continuation을
/// 옆 칸에 쓰므로 1칸짜리 grid는 마지막 칸에서 col+1 OOB를 부른다. init/resize에서 항상 이 최소
/// 크기를 보장해 그 degenerate 입력을 원천 차단한다(1칸 터미널은 실사용도 없다). 그래서 putCell은
/// cols>=2를 가정하고 wide glyph가 줄 끝에 안 들어가면 단순히 다음 줄로 넘기면 된다. PTY winsize와
/// grid 계산(gridFromBacking)이 같은 최소 크기를 쓰도록 pub으로 노출해 불변식을 한 곳에 둔다.
pub fn clampGridSize(size: types.Size) types.Size {
    return .{ .cols = @max(size.cols, 2), .rows = @max(size.rows, 1) };
}

fn fullDirty(size: types.Size) ?types.DirtyRegion {
    if (size.rows == 0 or size.cols == 0) return null;
    return .{ .start_row = 0, .end_row = size.rows - 1 };
}

test "terminal core stores size and resizes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 100, .rows = 30 });
    defer core.deinit();

    try std.testing.expectEqual(@as(u16, 100), core.snapshot().size.cols);

    try core.resize(120, 40);
    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 120), snapshot.size.cols);
    try std.testing.expectEqual(@as(u16, 40), snapshot.size.rows);
    try std.testing.expectEqual(@as(usize, 120 * 40), snapshot.cells.len);
}

test "terminal core writes process-like text into cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();

    try core.write("hello\nmaru");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "maru") != null);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}

test "findMatches: 대소문자 무시 부분일치 + 비겹침 + 절대 좌표" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    try core.write("alpha\r\nbeta\r\nalpha gamma");

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);

    // "alpha" 2곳: row0 col0, row2 col0. end.col = 4('alpha'=5칸 0..4).
    try core.findMatches(std.testing.allocator, "alpha", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].start.row);
    try std.testing.expectEqual(@as(u16, 0), matches.items[0].start.col);
    try std.testing.expectEqual(@as(u16, 4), matches.items[0].end.col);
    try std.testing.expectEqual(@as(usize, 2), matches.items[1].start.row);

    // 대소문자 무시: 같은 2곳.
    try core.findMatches(std.testing.allocator, "ALPHA", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);

    // 없는 needle / 빈 needle → 0.
    try core.findMatches(std.testing.allocator, "zzz", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
    try core.findMatches(std.testing.allocator, "", &matches);
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "findMatches: 유니코드 대소문자 무시(Latin-1·Greek·Cyrillic foldCase)" {
    // foldCase 직접 — 각 블록 대문자→소문자, 비-글자/미덮음 블록은 그대로.
    try std.testing.expectEqual(@as(u21, 'a'), TerminalCore.foldCase('A'));
    try std.testing.expectEqual(@as(u21, 0x00E9), TerminalCore.foldCase(0x00C9)); // É→é
    try std.testing.expectEqual(@as(u21, 0x00F1), TerminalCore.foldCase(0x00D1)); // Ñ→ñ
    try std.testing.expectEqual(@as(u21, 0x00D7), TerminalCore.foldCase(0x00D7)); // × 그대로(글자 아님)
    try std.testing.expectEqual(@as(u21, 0x03B1), TerminalCore.foldCase(0x0391)); // Α→α
    try std.testing.expectEqual(@as(u21, 0x03C9), TerminalCore.foldCase(0x03A9)); // Ω→ω
    try std.testing.expectEqual(@as(u21, 0x0430), TerminalCore.foldCase(0x0410)); // А→а
    try std.testing.expectEqual(@as(u21, 0x044F), TerminalCore.foldCase(0x042F)); // Я→я
    try std.testing.expectEqual(@as(u21, 0x0450), TerminalCore.foldCase(0x0400)); // Ѐ→ѐ
    try std.testing.expectEqual(@as(u21, 0x0100), TerminalCore.foldCase(0x0100)); // Ā 미덮음(Latin Ext-A — 그대로)

    // findMatches 통합 — 악센트/스크립트 대소문자 무시(코드포인트는 \u{}로 명시해 편집기 정규화 회피).
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    try core.write("CAF\u{00C9}\r\n\u{0391}\u{039B}\u{03A6}\u{0391}\r\n\u{041F}\u{0420}\u{0418}\u{0412}\u{0415}\u{0422}");
    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);

    try core.findMatches(std.testing.allocator, "caf\u{00E9}", &matches); // café ↔ CAFÉ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try core.findMatches(std.testing.allocator, "\u{03B1}\u{03BB}\u{03C6}\u{03B1}", &matches); // αλφα ↔ ΑΛΦΑ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try core.findMatches(std.testing.allocator, "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", &matches); // привет ↔ ПРИВЕТ
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
}

test "findMatches: soft-wrap 경계를 넘는 매치" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("abcdefghij"); // 8칸 auto-wrap → row0 "abcdefgh"(wrapped), row1 "ij"

    var matches: std.ArrayList(types.Match) = .empty;
    defer matches.deinit(std.testing.allocator);
    try core.findMatches(std.testing.allocator, "ghij", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].start.row); // 'g' = row0 col6
    try std.testing.expectEqual(@as(u16, 6), matches.items[0].start.col);
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].end.row); // 'j' = row1 col1
    try std.testing.expectEqual(@as(u16, 1), matches.items[0].end.col);
}

test "scrollToAbs: 스크롤백 매치를 뷰포트로 가져온다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) try core.write("line\r\n"); // 화면(3행)보다 많이 써 스크롤백 생성
    try std.testing.expect(core.sb_count > 0);

    // 맨 위(abs 0)로 → 과거를 본다(view_offset > 0).
    core.scrollToAbs(0);
    try std.testing.expect(core.viewOffset() > 0);
    // 바닥(활성 화면 마지막 행)으로 → view_offset 0.
    core.scrollToAbs(core.sb_count + core.size.rows - 1);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
}

test "terminal core preserves UTF-8 split across process read boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    // PTY reads are byte streams, not UTF-8 string messages. A Korean
    // character can arrive as one byte in one read and the remaining bytes in
    // the next read; TerminalCore owns this tail buffering so PTY code does
    // not need to understand text encoding.
    const korean = "한";
    try core.write(korean[0..1]);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    try core.write(korean[1..]);
    try core.write("글");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "한글") != null);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.snapshot().cursor.col);
}

test "terminal core preserves four-byte UTF-8 split across multiple writes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    const rocket = "🚀";
    try core.write("go ");
    try core.write(rocket[0..1]);
    try core.write(rocket[1..3]);
    try core.write(rocket[3..]);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "go 🚀") != null);
    try std.testing.expectEqual(@as(u16, 5), core.snapshot().cursor.col);
}

test "terminal core stores wide characters with continuation cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // A terminal grid advances by cells, not by UTF-8 byte length or font
    // advance. Korean/CJK characters occupy two cells, and the second cell
    // must be marked as a continuation so cursor movement, snapshots, and the
    // future renderer do not treat it as a separate printable character.
    try core.write("A한B");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 4), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 1), snapshot.cells[0].width);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expectEqual(@as(u21, '한'), snapshot.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), snapshot.cells[1].width);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expect(snapshot.cells[2].continuation);
    try std.testing.expectEqual(@as(u2, 0), snapshot.cells[2].width);
    try std.testing.expectEqual(@as(u21, 'B'), snapshot.cells[3].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "A한B") != null);
}

test "terminal core attaches a combining mark without advancing the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Combining marks are zero-width. They belong to the previous printable
    // cell and must not move the cursor, otherwise prompts and editor grids
    // drift when accents or other marks appear.
    try core.write("e\u{0301}x");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 0x0301), snapshot.cells[0].combining.?);
    try std.testing.expectEqual(@as(u21, 'x'), snapshot.cells[1].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "e\u{0301}x") != null);
}

test "terminal core attaches a combining mark to a base char in the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // Without autowrap the cursor parks *on* the base glyph when it lands in
    // the last column, so deriving the base from cursor-1 attached the accent
    // to the previous cell. The mark must land on the actual last-printed cell.
    try core.write("abe\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'b'), snapshot.cells[1].codepoint);
    try std.testing.expect(snapshot.cells[1].combining == null);
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, 0x0301), snapshot.cells[2].combining.?);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "abe\u{0301}") != null);
}

test "terminal core drops a combining mark with no base on the current row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // A line feed ends the grapheme run and does not reset the column, so the
    // cursor sits over a blank cell on the new row. A combining mark there has
    // no base and must be dropped instead of accenting that blank cell.
    try core.write("A\n\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try std.testing.expect(snapshot.cells[0].combining == null);
    for (snapshot.cells) |cell| try std.testing.expect(cell.combining == null);
}

test "terminal core backspace moves exactly one column even over a wide continuation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // BS는 정확히 1칸이다(ECMA-48, xterm.js 동일). 셸은 wide 글자에 BS를 두 번 보내므로,
    // continuation을 건너뛰는 "친절"은 셸 계산과 한 칸 어긋나 지우기가 프롬프트를 침범한다
    // (라이브 한글 삭제에서 실제 발생). BS 한 번이면 커서는 continuation 칸(col 1)에 서고,
    // 그 자리 쓰기는 clearCellForWrite가 base/continuation을 함께 정리해 글자가 깨지지 않는다.
    try core.write("한\u{08}X");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'X'), snapshot.cells[1].codepoint);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expectEqual(@as(u16, 2), snapshot.cursor.col);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // base 반쪽(한)은 continuation 자리에 X를 쓰며 정리된다 — half-glyph가 남지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, text, "한") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "X") != null);
}

test "terminal core tab expansion stops at the row edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // This test protects the root cause of a common terminal-core failure:
    // cursor movement that cannot advance must not leave a control sequence in
    // an infinite loop. Full wrap behavior will be specified separately.
    try core.write("a\t");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 0), snapshot.cursor.row);
    try std.testing.expectEqual(@as(u16, 7), snapshot.cursor.col);
}

test "terminal core lets renderer consume dirty region once" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    const initial_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), initial_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), initial_dirty.end_row);
    try std.testing.expect(core.takeDirty() == null);

    try core.write("x");

    const next_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), next_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), next_dirty.end_row);
    try std.testing.expect(core.snapshot().dirty == null);
}

test "terminal core leaves frame clean when a cursor-only control does not move" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // At column 0 a carriage return and a backspace change nothing: the cursor
    // is already there. markCursorMoveDirty must early-return so the renderer
    // does not redraw a row whose pixels are unchanged.
    core.clearDirty();
    try core.write("\r");
    try std.testing.expect(core.takeDirty() == null);

    core.clearDirty();
    try core.write("\x08");
    try std.testing.expect(core.takeDirty() == null);
}

test "terminal core marks cursor-only movement dirty for cursor overlay redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // Carriage return changes only the cursor position. It still needs a
    // dirty row because the renderer must erase the old cursor overlay and
    // draw the new one even when no cell text changed.
    try core.write("AB");
    core.clearDirty();
    try core.write("\r");

    const cr_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    // Backspace is the same class of visual change: the glyph grid can stay
    // intact while the cursor overlay moves one cell left.
    try core.write("AB");
    core.clearDirty();
    try core.write("\x08");

    const bs_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.col);
}

test "terminal core marks old and new cursor rows dirty across line feed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();

    // A line feed moves the cursor to a different row without necessarily
    // changing cell text. Both rows are dirty because one loses the cursor
    // overlay and the other gains it.
    try core.write("A");
    core.clearDirty();
    try core.write("\n");

    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}

test "SGR escape sequences are interpreted, not printed as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();

    // The shell prompt problem: color codes must not show as literal "[31m" text.
    try core.write("\x1b[31mhi\x1b[0m");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi        ", dump);
}

test "SGR sets the pen style stamped onto written cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;4;31mA");
    const cell = core.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try std.testing.expect(cell.style.bold);
    try std.testing.expect(cell.style.underline);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "SGR 9/29 toggle strikethrough on the pen stamped onto cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 9(crossed-out) → A는 strikethrough, SGR 29(not crossed-out) → B는 아님.
    // 베이스: ECMA-48 SGR 9/29, xterm ctlseqs 동일. underline(4)과 독립 비트라 같이 켤 수 있다.
    try core.write("\x1b[9mA\x1b[29mB");
    const a = core.cells[core.index(0, 0)];
    const b = core.cells[core.index(0, 1)];
    try std.testing.expect(a.style.strikethrough);
    try std.testing.expect(!b.style.strikethrough);

    // SGR 0(reset)은 strikethrough도 끈다(전체 리셋이 pen을 기본값으로).
    try core.write("\x1b[9mC\x1b[0mD");
    try std.testing.expect(core.cells[core.index(0, 2)].style.strikethrough);
    try std.testing.expect(!core.cells[core.index(0, 3)].style.strikethrough);
}

test "SGR 53/55 toggle overline on the pen stamped onto cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 53(overlined) → A는 overline, SGR 55(not overlined) → B는 아님. 베이스: ECMA-48 SGR 53/55,
    // xterm ctlseqs. strikethrough/underline과 독립 비트라 같이 켤 수 있다.
    try core.write("\x1b[53mA\x1b[55mB");
    try std.testing.expect(core.cells[core.index(0, 0)].style.overline);
    try std.testing.expect(!core.cells[core.index(0, 1)].style.overline);

    // SGR 0(reset)은 overline도 끈다(전체 리셋이 pen을 기본값으로).
    try core.write("\x1b[53mC\x1b[0mD");
    try std.testing.expect(core.cells[core.index(0, 2)].style.overline);
    try std.testing.expect(!core.cells[core.index(0, 3)].style.overline);
}

test "SGR 2/22 toggle dim, and 22 also clears bold (ECMA-48 normal intensity)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // SGR 2(faint) → A는 dim. 같은 셀에 bold(1)도 켜 두고, SGR 22(normal intensity)가 bold와 dim을
    // 둘 다 끄는지(ECMA-48) B에서 확인한다.
    try core.write("\x1b[1;2mA\x1b[22mB");
    const a = core.cells[core.index(0, 0)];
    const b = core.cells[core.index(0, 1)];
    try std.testing.expect(a.style.dim);
    try std.testing.expect(a.style.bold);
    try std.testing.expect(!b.style.dim);
    try std.testing.expect(!b.style.bold);

    // SGR 0(reset)도 dim을 끈다.
    try core.write("\x1b[2mC\x1b[0mD");
    try std.testing.expect(core.cells[core.index(0, 2)].style.dim);
    try std.testing.expect(!core.cells[core.index(0, 3)].style.dim);
}

test "SGR reset returns the pen to default for following cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;31mA\x1b[0mB");
    const a = core.cells[core.index(0, 0)];
    const b = core.cells[core.index(0, 1)];
    try std.testing.expect(a.style.bold);
    try std.testing.expect(!b.style.bold);
    try std.testing.expectEqual(types.Color.default, b.style.foreground);
}

test "SGR 256-color and rgb extended forms set the foreground" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[38;5;200mA");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.cells[core.index(0, 0)].style.foreground);

    try core.write("\x1b[38;2;10;20;30mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 1)].style.foreground,
    );
}

test "CSI cursor position moves the cursor with 1-based params" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);

    // A bare CSI H homes the cursor.
    try core.write("\x1b[H");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
}

test "CSI K erases from the cursor to the end of the line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("abcde");
    // Column 3 (1-based) is index 2, then erase to end of line.
    try core.write("\x1b[3G\x1b[K");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab   ", dump);
}

test "CSI 2J clears the whole screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab\ncd");
    try core.write("\x1b[2J");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("   \n   ", dump);
}

test "clearScreen at the shell prompt wipes screen+scrollback, homes cursor, and requests redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // rows=3보다 많은 줄 → 스크롤백 생성.
    try core.write("l1\nl2\nl3\nl4\n");
    try std.testing.expect(core.scrollbackLen() > 0);
    // 셸 프롬프트 표시(OSC 133 A→B = prompt→input). semantic_state=.input → isPromptish.
    try core.write("\x1b]133;A\x1b\\");
    try core.write("\x1b]133;B\x1b\\");

    const redraw = core.clearScreen();
    try std.testing.expect(redraw); // 프롬프트 → 호출자가 ^L(form-feed)로 프롬프트 재그림
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 스크롤백 비움
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row); // 커서 홈
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    \n    \n    ", dump); // 4×3 전부 공백
}

test "clearScreen on the alternate screen is a no-op and does not request redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?1049h"); // alt 진입(vim/less 류) — 앱이 화면 소유
    try core.write("vi");
    const redraw = core.clearScreen();
    try std.testing.expect(!redraw);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("vi  \n    ", dump); // alt 내용 보존(무동작)
}

test "clearScreen without prompt classification clears above the cursor and keeps the current line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // CUP로 결정적으로 배치한다(\n의 CR 동반 여부에 의존하지 않게). 셸 통합 없음 → semantic_state=.unknown.
    try core.write("\x1b[1;1Haaa"); // row0 = "aaa "
    try core.write("\x1b[2;1Hbbb"); // row1 = "bbb "
    try core.write("\x1b[3;1Hccc"); // row2 = "ccc ", 커서 (2,3)
    const redraw = core.clearScreen();
    try std.testing.expect(!redraw); // 비프롬프트 → form-feed 안 보냄
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    \n    \nccc ", dump); // 커서 행 위만 비우고 현재 줄 보존
}

test "escape sequence split across writes is parsed as one sequence" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // PTY reads can split a sequence; parser state must persist across write().
    try core.write("\x1b[3");
    try core.write("1mX");

    const cell = core.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'X'), cell.codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "OSC sequence is consumed and does not print" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // OSC 0 sets the window title, terminated by BEL; the title text must not show.
    try core.write("\x1b]0;title\x07hi");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump);
    // ...but it IS captured as the window title (consumed != discarded).
    try std.testing.expectEqualStrings("title", core.windowTitle());
}

// 창 제목은 xterm OSC 0/2(아이콘+제목 / 제목)로 앱이 지정하거나, 없으면 OSC 7 cwd의 basename으로
// 폴백한다 — 탭/창 제목줄이 읽는 단일 계약이라 우선순위(제목 > cwd basename > 빈값) 로직이 Zig에
// 있어야 한다(native 최소). OSC 1(아이콘만)은 창 제목과 무관하므로 무시돼야 한다.
test "window title: OSC 2 sets it, OSC 1 ignored, empty clears to cwd basename" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try std.testing.expectEqualStrings("", core.windowTitle()); // 아무것도 없으면 빈값

    // cwd만 있으면 basename으로 폴백.
    try core.write("\x1b]7;file://h/Users/me/proj\x07");
    try std.testing.expectEqualStrings("proj", core.windowTitle());

    // OSC 2 제목이 있으면 그게 우선(cwd basename보다).
    try core.write("\x1b]2;my app\x1b\\");
    try std.testing.expectEqualStrings("my app", core.windowTitle());

    // OSC 1(아이콘만)은 창 제목을 안 바꾼다.
    try core.write("\x1b]1;iconname\x07");
    try std.testing.expectEqualStrings("my app", core.windowTitle());

    // 빈 OSC 2는 제목 해제 → 다시 cwd basename 폴백.
    try core.write("\x1b]2;\x07");
    try std.testing.expectEqualStrings("proj", core.windowTitle());

    // RIS는 제목과 cwd를 모두 공장 초기화 → 빈값.
    try core.write("\x1bc");
    try std.testing.expectEqualStrings("", core.windowTitle());
}

// OSC 7(VTE 사실상 표준)은 셸이 cwd를 보고하는 채널이다 — 터미널은 PTY 너머라 cwd를 모르므로
// 창 제목/새 탭 cwd가 이걸 읽는다. 셸 통합과 platform layer 사이의 단일 계약이라, 형식 파싱과
// percent-decoding이 정확해야 한다. ST(ESC \)·BEL 어느 종결자로 와도 같게 처리돼야 한다.
test "OSC 7 reports cwd: file://host/path is parsed, host ignored, text not printed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]7;file://myhost/Users/me/proj\x1b\\hi");

    try std.testing.expectEqualStrings("/Users/me/proj", core.currentCwd()); // host(myhost) 무시, path만
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump); // OSC 본문은 그리드에 안 보인다
}

test "OSC 7 percent-decodes the path (spaces, UTF-8 bytes round-trip)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // BEL 종결자 + %20(공백) + percent-인코딩된 UTF-8('가'=EA B0 80) + raw로 통과하는 ASCII.
    try core.write("\x1b]7;file://localhost/a%20b/%EA%B0%80\x07");
    try std.testing.expectEqualStrings("/a b/\xea\xb0\x80", core.currentCwd());

    // 잘린 %escape는 관대하게 '%'를 리터럴로 둔다(한 글자 깨졌다고 전체를 버리지 않음).
    try core.write("\x1b]7;file://localhost/x%2\x07");
    try std.testing.expectEqualStrings("/x%2", core.currentCwd());
}

test "OSC 7 keeps prior cwd on malformed input, clears on RIS" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]7;file://h/good\x07");
    try std.testing.expectEqualStrings("/good", core.currentCwd());

    // file 스킴 아님 / path 없음(authority만) → 기존 cwd 유지.
    try core.write("\x1b]7;http://h/other\x07");
    try core.write("\x1b]7;file://hostonly\x07");
    try std.testing.expectEqualStrings("/good", core.currentCwd());

    // RIS(ESC c) 하드 리셋 → cwd도 공장 초기화(빈 값).
    try core.write("\x1bc");
    try std.testing.expectEqualStrings("", core.currentCwd());
}

test "private CSI sequences are consumed without printing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // Cursor visibility toggles (DECTCEM) must not leak as text.
    try core.write("\x1b[?25lhi\x1b[?25h");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi    ", dump);
}

test "resize preserves overlapping content when growing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(8, 1);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hello   ", dump);
}

test "resize leaves the cursor's line verbatim when shrinking (shell redraws it)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(3, 1);

    // "hello"는 커서가 있는 줄이므로 reflow하지 않고 그대로 둔다(xterm.js 방식 — 셸이 SIGWINCH로
    // 다시 그린다). 새 폭(3)으로 clip돼 "hel"이 남고, 커서는 폭 안으로 clamp된다. 스크롤백 push 없음.
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hel", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col); // col 4 -> clamp 2
}

test "resize preserves content across multiple rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab");
    try core.write("\x1b[2;1Hcd");
    try core.resize(4, 3);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab  \ncd  \n    ", dump);
}

test "resize clamps the cursor into the new bounds instead of resetting it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);

    try core.resize(2, 2);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}

test "eraseInDisplay merges dirty instead of dropping earlier-dirtied rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 4 });
    defer core.deinit();
    core.clearDirty();

    // Print on the bottom row, then move the cursor up and erase start-to-cursor (mode 1).
    try core.write("\x1b[4;1HX");
    try core.write("\x1b[2;1H\x1b[1J");

    // The bottom row (3) where X was printed must remain dirty — not be dropped by the erase.
    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expect(dirty.end_row >= 3);
}

test "ESC inside a CSI restarts as a new escape instead of leaking as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // CSI opened by '[', then ESC cancels it and a fresh CSI sets red and prints X.
    try core.write("\x1b[\x1b[31mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X     ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[core.index(0, 0)].style.foreground);
}

test "C0 control inside a CSI is executed and the CSI still completes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Backspace (0x08) embedded mid-CSI must not abort it: the SGR red still applies, X prints red.
    try core.write("\x1b[31\x08mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X   ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[core.index(0, 0)].style.foreground);
}

test "CSI with more than 16 parameters discards the overflow instead of corrupting param 15" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // 16 zero params fill the buffer; the 17th param (1 = bold) is past the cap and must be dropped,
    // not folded into params[15] (which the old guard did, applying spurious bold).
    try core.write("\x1b[0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;1mA");
    try std.testing.expect(!core.cells[core.index(0, 0)].style.bold);
}

test "resize clears a wide glyph whose continuation is clipped at the new right edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A한");
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 1)].width);

    // Shrink so the wide glyph's continuation (col 2) is clipped; the dangling base must be cleared.
    try core.resize(2, 1);
    try std.testing.expect(core.cells[core.index(0, 1)].width != 2);
}

test "erasing the continuation half of a wide glyph clears its dangling base" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("한X");
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 0)].width);

    // Cursor onto the continuation (col 1), erase cursor-to-end: the base at col 0 is now dangling.
    try core.write("\x1b[2G\x1b[K");
    try std.testing.expect(core.cells[core.index(0, 0)].width != 2);
}

test "eraseInLine ends the grapheme run so a later combining mark is dropped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A");
    try core.write("\x1b[1G\x1b[K");
    try core.write("\u{0301}");

    try std.testing.expectEqual(@as(?u21, null), core.cells[core.index(0, 0)].combining);
}

test "SGR colon sub-parameter direct color (38:2:cs:r:g:b) reads RGB past the colorspace slot" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // ITU colon form with an empty colorspace slot: '::' inserts an extra component before r,g,b.
    // The parser must skip the colorspace and read 10/20/30 — not 0/10/20.
    try core.write("\x1b[38:2::10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.foreground,
    );

    // Colon 256-color form: n sits at the same offset as the semicolon form.
    try core.write("\x1b[38:5:200mB");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.cells[core.index(0, 1)].style.foreground);

    // Semicolon form must stay correct (no colorspace component).
    try core.write("\x1b[48;2;1;2;3mC");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        core.cells[core.index(0, 2)].style.background,
    );
}

test "printable characters auto-wrap to the next line at the right edge (DECAWM)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDE"); // ABCD fills row 0; E wraps to row 1
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}

test "a line filled exactly then CR/LF does not insert a blank wrapped line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // ABCD가 row 0을 정확히 채워 pending_wrap이 서지만, \r\n이 그걸 무효화해 X는 row 1에 온다
    // (deferred wrap이 아니면 \n이 한 줄 더 내려가 X가 row 2에 떨어진다).
    try core.write("ABCD\r\nX");
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "overflow fill wraps so a following prompt lands on a new line, not over the content" {
    // 사용자 실제 시나리오: 개행 없이 끝난 출력(파란 배경) 뒤에 zsh PROMPT_SP가 줄 끝을 넘겨
    // 공백을 채워 다음 줄로 wrap시키고 \r + 프롬프트를 그린다. autowrap이 있어야 프롬프트가
    // wrap된 줄(row 1)에 떨어지고 파란 줄(row 0)을 덮지 않는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[44mBLUE\x1b[0m"); // BLUE(파란 배경) at row 0, cursor (0,4)
    try core.write("            "); // 12 spaces: 4 fill row 0, wrap, 8 fill row 1
    try core.write("\rPROMPT"); // \r clears pending_wrap; PROMPT at row 1
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 4 }, core.cells[core.index(0, 0)].style.background);
    try std.testing.expectEqual(@as(u21, 'P'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "cursor positioning cancels a pending wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // fills row 0, pending_wrap set
    try core.write("\x1b[1;1H"); // CUP to (0,0) cancels pending_wrap
    try core.write("X"); // X overwrites (0,0), does NOT wrap to row 1
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}

test "a wide glyph with one column left wraps whole to the next line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABC"); // A,B,C at cols 0,1,2; cursor (0,3) one column left
    try core.write("한"); // wide(2): doesn't fit in 1 col -> wraps to row 1
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(1, 0)].width);
    try std.testing.expect(core.cells[core.index(1, 1)].continuation);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "the grid is clamped to at least 2 columns so wide glyphs never write out of bounds" {
    // 1칸 grid는 wide glyph(2칸) continuation에서 col+1 OOB를 부른다. init/resize가 최소 2칸으로
    // 맞춰 그 degenerate 입력을 원천 차단하므로, wide glyph는 degrade 없이 통째로 들어간다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
    try std.testing.expectEqual(@as(u16, 1), core.size.rows);
    try core.write("한"); // wide(2)가 OOB/degrade 없이 2칸으로 들어간다
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 0)].width);
    try std.testing.expect(core.cells[core.index(0, 1)].continuation);
    // resize도 같은 최소 크기를 보장한다.
    try core.resize(1, 4);
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
}

test "a bottom-row line feed clears pending wrap so the next char does not double-scroll" {
    // 바닥 행이 꽉 차(pending_wrap) bare LF가 오면 scroll이 일어나는데, pending_wrap이 안 지워지면
    // 다음 printable 글자가 또 scroll해 직전 줄을 잃었다(이중 스크롤). lineFeed가 pending_wrap을
    // 끄므로 ABCD가 row 0에 보존되고 X가 row 1에 와야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\r\nABCD"); // row 1을 채움 -> pending_wrap at (1,3)
    try core.write("\n"); // 바닥 bare LF -> scrollRegionUp 한 번(ABCD -> row 0), 컬럼은 보존
    try core.write("X"); // pending_wrap stale면 또 scroll돼 ABCD 유실. 고쳐지면 한 번만 scroll.
    // 핵심: ABCD가 row 0에 보존된다(버그면 두 번 scroll돼 row 0이 빈칸). bare LF는 컬럼을
    // 보존하므로 X는 (1,3)에 온다.
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 3)].codepoint);
}

test "autowrap at the scroll-bottom keeps the soft-wrap flag (reflow가 논리 줄을 안 쪼갠다)" {
    // putCell이 soft-wrap 플래그를 lineFeed '전'에 세우면, 바닥에서 wrap+scroll할 때 scrollRangeUp의
    // 경계 fixup이 그 플래그를 지운다 → resize reflow가 autowrap된 한 논리 줄을 둘로 쪼갠다. 플래그를
    // lineFeed '후'에 세워(promoteLastToEmojiWidth와 같은 패턴) scroll에도 살아남게 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // row0 가득 -> pending_wrap
    try core.write("efgh"); // 'e'가 row1로 wrap, row1 가득 -> pending_wrap at scroll_bottom
    try core.write("i"); // autowrap + scroll: efgh -> row0, i -> row1 col0
    // efgh(row0)는 i 줄(row1)로 이어지는 soft-wrap이다 — 플래그가 scroll fixup에 안 지워져야 한다.
    try std.testing.expect(core.wrapped[0]);
    // i 하나만 있는 마지막 줄은 아직 어디로도 안 이어진다(회귀: 새로 쓴 행은 wrap 리셋).
    try std.testing.expect(!core.wrapped[1]);
}

test "SGR colon direct color without a colorspace component (38:2:r:g:b) sets RGB" {
    // ITU colon form은 colorspace 슬롯이 생략될 수 있다(38:2:r:g:b, 5컴포넌트). 이전엔 colorspace가
    // 항상 있다고 가정해 색을 통째로 버렸다. r,g,b는 colon 컴포넌트의 마지막 3개로 읽어야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[38:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.foreground,
    );
    // 빈 colorspace(38:2::r:g:b)와 colorspace 있는(38:2:1:r:g:b) 6컴포넌트도 여전히 정확.
    try core.write("\x1b[38:2::40:50:60mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 40, .g = 50, .b = 60 } },
        core.cells[core.index(0, 1)].style.foreground,
    );
}

test "a tab near the last column does not overflow the tab-stop arithmetic" {
    // cols가 maxInt(u16)까지 허용되므로(거대 창), 마지막 칸 근처 탭에서 (col/8+1)*8이 u16을 넘길 수
    // 있다. 포화 곱셈으로 패닉/OOB 없이 마지막 칸에 멈춰야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 65535, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[65535G"); // CHA -> 마지막 칸(65534)으로 clamp
    try core.write("\t"); // 패닉하면 안 됨
    try std.testing.expectEqual(@as(u16, 65534), core.cursor.col);
}

test "HT(tab)는 지나는 셀을 덮지 않고 커서만 옮긴다 (xterm/Ghostty)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 1 });
    defer core.deinit();
    try core.write("ABCDEF"); // col0~5
    try core.write("\r\t"); // CR(col0) → HT → 다음 8-탭스톱(col8)
    // ABCDEF가 보존된다 — 예전엔 putCell(' ')로 col0~7을 덮어 글자가 사라졌다.
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.cells[core.index(0, 5)].codepoint);
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col); // 커서만 탭스톱으로 이동
}

test "backspace cancels a pending wrap so the next char does not wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // row 0을 채움 -> pending_wrap at (0,3)
    try core.write("\x08"); // backspace -> (0,2), markCursorMoveDirty가 pending_wrap을 끈다
    try core.write("X"); // (0,2)에 덮어쓰고 wrap하지 않는다
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
}

test "SGR colon background direct color (48:2:r:g:b) sets the cell background" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 전경(38)뿐 아니라 배경(48)도 colon 형식 + colorspace 생략을 처리해야 한다.
    try core.write("\x1b[48:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.background,
    );
}

test "SGR colon sub-parameter는 직전 주 파라미터에 종속 — 별도 SGR로 새지 않는다 (4:3/4:0)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 4:3 (curly underline) — underline만 켜지고 italic(SGR 3)은 안 켜진다(예전엔 :3을 italic으로 오인).
    try core.write("\x1b[4:3m");
    try std.testing.expect(core.pen.underline);
    try std.testing.expect(!core.pen.italic);
    // bold 후 4:0 (underline off) — bold는 유지된다(예전엔 :0을 SGR 0=전체 리셋으로 오인해 bold까지 날렸다).
    try core.write("\x1b[0m\x1b[1m\x1b[4:0m");
    try std.testing.expect(core.pen.bold);
    try std.testing.expect(!core.pen.underline);
    // 회귀: sub-param 스킵이 38/48 확장색을 망가뜨리지 않는다(세미콜론·콜론 형식 모두).
    try core.write("\x1b[0m\x1b[38;2;10;20;30m");
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, core.pen.foreground);
    try core.write("\x1b[38:2:40:50:60m");
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 40, .g = 50, .b = 60 } }, core.pen.foreground);
}

test "printable text wraps across multiple rows filling each line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDEF"); // AB / CD / EF
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(1, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(2, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.cells[core.index(2, 1)].codepoint);
}

test "a wide glyph filling the last two columns sets pending wrap and the next char wraps" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("AB"); // A(0,0) B(0,1), 커서 (0,2)
    try core.write("한"); // 마지막 두 칸(2,3)을 채움 -> 커서 (0,3) pending_wrap
    try core.write("X"); // 다음 줄로 wrap
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expect(core.cells[core.index(0, 3)].continuation);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "clampGridSize enforces a minimum of 2 columns and 1 row" {
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 5 }, clampGridSize(.{ .cols = 1, .rows = 5 }));
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 1 }, clampGridSize(.{ .cols = 0, .rows = 0 }));
    try std.testing.expectEqual(types.Size{ .cols = 80, .rows = 24 }, clampGridSize(.{ .cols = 80, .rows = 24 }));
}

test "tab advances to the next 8-column stop mid-line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 16, .rows = 1 });
    defer core.deinit();
    // 엣지(마지막 칸)가 아니라 일반 전진: 'a'(col 1) 뒤 tab은 다음 8-stop(col 8)으로 간다.
    try core.write("a\t");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);
}

test "scrollback keeps rows that scroll off the top" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // rows=2. 각 줄이 바닥에서 scroll될 때 맨 윗줄이 스크롤백으로 들어간다.
    try core.write("a\r\nb\r\nc\r\nd");
    // 'a' 줄과 'b' 줄이 밀려났다. 화면엔 c/d가 남는다.
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'a'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(1, 0)].codepoint);
}

test "scrollback ring drops the oldest rows past max_scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 2; // 첫 scroll 전에 cap을 작게 둔다(lazy 할당이 이 값을 쓴다).
    // a,b,c가 차례로 밀려난다(d/e는 화면에 남음). cap=2라 가장 최근 2개(b,c)만 남는다.
    try core.write("a\r\nb\r\nc\r\nd\r\ne");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), core.cells[core.index(1, 0)].codepoint);
}

test "scrollback disabled when max_scrollback is zero" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 0;
    try core.write("a\r\nb\r\nc\r\nd");
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "scrollViewport reveals scrollback at the top and scrollToBottom returns to active" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d]
    // 바닥(0): 활성 화면이 보인다.
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.viewportRow(1)[0].codepoint);
    // 1줄 위로: 윗줄에 가장 최근 스크롤백('b'), 아랫줄에 활성 첫 줄('c'). 'd'는 가려진다.
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(1)[0].codepoint);
    // 더 위로: 스크롤백 맨 위(a,b). 범위를 넘겨도 sb_count(2)로 clamp.
    core.scrollViewport(5);
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 바닥으로: 다시 활성.
    core.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
}

test "scroll-lock keeps the viewport on the same content as new output scrolls in" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // 스크롤백=[a], 활성=[b,c]
    core.scrollViewport(1); // 위로 -> 뷰는 'a','b'
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 새 출력이 scroll돼 들어와도(b가 스크롤백으로), 뷰는 같은 'a','b'를 계속 보여준다(scroll-lock).
    try core.write("\r\nd");
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset()); // offset이 함께 올라감
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
}

test "renderSnapshot shows active at bottom and composes the viewport (cursor hidden) when scrolled" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d], 커서 (1,1)

    // 바닥: 활성 화면 그대로 + 실제 커서(보임).
    const at_bottom = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'c'), at_bottom.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), at_bottom.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(at_bottom.cursor.visible);

    // 맨 위로 스크롤: 뷰포트가 스크롤백(a,b)을 합성, 커서 숨김.
    core.scrollViewport(2);
    const scrolled = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'a'), scrolled.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), scrolled.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(!scrolled.cursor.visible);
}

test "wrapped flag: autowrap sets it, rewriting the row clears it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd가 row0를 채우고 'e'가 autowrap으로 row1로 넘어간다
    try std.testing.expect(core.wrapped[0]); // row0는 soft-wrap
    try std.testing.expect(!core.wrapped[1]); // row1은 아직 wrap 아님
    try core.write("\x1b[1;1Hxy"); // CUP (0,0) 후 짧게 다시 그림 -> wrapped[0] 리셋
    try std.testing.expect(!core.wrapped[0]);
}

test "wrapped flag: a wide glyph pushed whole to the next row marks soft-wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abc한"); // abc가 0..2를 채우고 한(width2)이 col3에 안 들어가 통째로 row1로
    try std.testing.expect(core.wrapped[0]);
}

test "wrapped flag: a hard line-end stays false even with the cursor parked past content" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\r"); // 줄을 안 채운 프롬프트 + CR -> 커서 (0,0). row0는 hard 줄끝
    try std.testing.expect(!core.wrapped[0]);
    try core.write("\x1b[1;6H"); // 커서를 내용 너머(col5)로 이동 -> wrap은 안 변함
    try std.testing.expect(!core.wrapped[0]);
}

test "wrapped flag: scrolled-off soft-wrapped row carries its flag into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true (abcd가 'e'로 soft-wrap)
    try std.testing.expect(core.wrapped[0]);
    try core.write("\r\nfg"); // 바닥에서 scroll -> abcd(wrapped=true)가 스크롤백으로
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try std.testing.expect(core.scrollbackRowWrapped(0));
}

test "wrapped flag: erase-in-display mode 2 clears all wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[2J"); // 화면 전체 지움 -> 모든 wrap 플래그 false
    try std.testing.expect(!core.wrapped[0]);
}

test "reflow: the cursor's wrapped line is left unchanged, not re-wrapped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef"); // 4칸에서 abcd|ef로 soft-wrap, 커서 (1,2)
    try std.testing.expect(core.wrapped[0]);
    try core.resize(8, 3); // 넓혀도 커서 줄이라 합치지 않고 그대로 둔다(셸이 다시 그림)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcd    \nef      \n        ", dump);
    try std.testing.expect(core.wrapped[0]); // verbatim이라 wrap 플래그 유지
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "reflow: a non-cursor wrapped line IS reflowed (joined on widen)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\n"); // abcd|ef(행0~1)는 wrap, \r\n으로 커서를 행2로 -> abcdef는 커서 줄 아님
    try std.testing.expect(core.wrapped[0]);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try core.resize(8, 3); // 커서가 다른 줄이라 abcdef는 reflow돼 한 줄로 합쳐진다
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcdef  \n        \n        ", dump);
    try std.testing.expect(!core.wrapped[0]); // 합쳐져 더는 wrap 아님
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row); // 커서(빈 줄)는 한 칸 위로
}

test "reflow: a cursor parked past content on its line clamps (line not reflowed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("abc\x1b[1;7H"); // "abc" 후 커서를 (0,6)로(내용 너머) — 커서 줄
    try std.testing.expectEqual(@as(u16, 6), core.cursor.col);
    try core.resize(4, 3); // 커서 줄이라 reflow 안 함. 커서는 새 폭으로 clamp(6 -> 3).
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
    try std.testing.expect(!core.wrapped[0]);
}

test "reflow: a hard prompt line never merges into the next across repeated resizes (no cascade)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("ok\r\n"); // hard 프롬프트 줄
    try core.write("abcdefghij"); // 다음 줄부터 soft-wrap되는 긴 명령
    // 폭을 왕복해도 프롬프트는 항상 hard 줄로 남고 명령과 합쳐지지 않는다.
    try core.resize(4, 4);
    try core.resize(12, 4);
    try core.resize(6, 4);
    try std.testing.expect(!core.wrapped[0]); // 프롬프트 줄은 hard 유지(cascade 없음)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.startsWith(u8, dump, "ok")); // 첫 줄은 여전히 프롬프트
    try std.testing.expect(std.mem.indexOf(u8, dump, "okabc") == null); // 프롬프트에 명령이 안 붙음
}

test "DSR: CSI 6n replies with the cursor position (CPR, 1-indexed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    try core.write("\x1b[3;5H"); // 커서 (2,4) 0-indexed
    try core.write("\x1b[6n"); // CPR 질의
    try std.testing.expectEqualStrings("\x1b[3;5R", core.pendingResponse());
    core.clearResponse();
    try std.testing.expectEqual(@as(usize, 0), core.pendingResponse().len);
}

test "DSR: CSI 5n replies terminal-OK" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", core.pendingResponse());
}

test "DSR: CPR reports the parked-cursor column at the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸을 채워 parked(pending_wrap), 커서 (0,3)
    try core.write("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", core.pendingResponse()); // row1 col4(1-indexed)
}

test "reflow: many wide glyphs shrunk to a narrow width does not overflow the scratch" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 12 });
    defer core.deinit();
    // 비-커서 줄을 wide glyph로 가득 채운다(soft-wrap). 좁은 폭에서 wide glyph는 줄 끝 한 칸을
    // 낭비하며 wrap돼, 재배치 행 수가 옛 cap_rows(total_content/new_cols) 추정을 초과한다(힙 OOB였음).
    try core.write("한" ** 80); // 160칸 = 8행의 한(rows 0-7, soft-wrap)
    try core.write("\r\nx"); // 커서를 짧은 줄(아래)로 옮겨 한 줄이 비-커서가 되게 함
    try core.resize(3, 12); // 3칸으로 축소: 한 1개/행 -> ~80행 -> 옛 cap 초과(크래시 없어야)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(dump.len > 0); // 크래시 없이 통과 + 내용 보존
    try std.testing.expect(core.scrollbackLen() > 0 or std.mem.indexOf(u8, dump, "한") != null);
}

test "eraseInLine mode 1 (erase to cursor) keeps the row's soft-wrap flag" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd|e: wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[1;2H\x1b[1K"); // CUP (0,1) 후 CSI 1K(시작~커서 지움) — 오른쪽 끝은 멀쩡
    try std.testing.expect(core.wrapped[0]); // mode 1은 wrap 연속성을 안 끊는다
}

test "ECH (CSI Ps X) blanks N cells from the cursor in place, cursor unmoved (nvim mode-label clear)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    try core.write("-- INSERT --"); // 12자(col 0~11), 커서 (0,12)
    try core.write("\x1b[1;1H"); // 커서 home(0,0)
    try core.write("\x1b[12X"); // ECH 12 — nvim이 모드 라벨을 지우는 바로 그 시퀀스
    var c: u16 = 0;
    while (c < 12) : (c += 1) {
        const cp = core.cells[core.index(0, c)].codepoint;
        try std.testing.expect(cp == ' ' or cp == 0); // 12칸 전부 blank
    }
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col); // 커서는 제자리(EL과 달리 이동 없음)
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
}

test "ECH default param is 1 and does not pull following cells (not DCH)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();
    try core.write("ABCDE");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=B
    try core.write("\x1b[X"); // ECH 기본 1 — B만 blank
    const b = core.cells[core.index(0, 1)].codepoint;
    try std.testing.expect(b == ' ' or b == 0);
    try std.testing.expectEqual(@as(u21, 'C'), core.cells[core.index(0, 2)].codepoint); // C는 그대로 — 뒤를 당기지 않는다
}

test "ICH (CSI Ps @) inserts N blanks at the cursor, pushing the rest right and dropping past the edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abcde");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=b
    try core.write("\x1b[2@"); // ICH 2: b 자리에 빈 칸 2개, bc를 오른쪽으로(de는 edge 넘어 버림)
    try std.testing.expectEqual(@as(u21, 'a'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expect(core.cells[core.index(0, 1)].codepoint == ' ' or core.cells[core.index(0, 1)].codepoint == 0);
    try std.testing.expect(core.cells[core.index(0, 2)].codepoint == ' ' or core.cells[core.index(0, 2)].codepoint == 0);
    try std.testing.expectEqual(@as(u21, 'b'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.cells[core.index(0, 4)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col); // 커서는 제자리(ICH는 이동 없음)
}

test "DCH (CSI Ps P) deletes N chars, pulling the rest left with blanks at the end; default 1" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abcde");
    try core.write("\x1b[1;2H"); // 커서 (0,1)=b
    try core.write("\x1b[2P"); // DCH 2: b,c 삭제, de를 왼쪽으로 당김
    try std.testing.expectEqual(@as(u21, 'a'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expect(core.cells[core.index(0, 3)].codepoint == ' ' or core.cells[core.index(0, 3)].codepoint == 0);
    try std.testing.expect(core.cells[core.index(0, 4)].codepoint == ' ' or core.cells[core.index(0, 4)].codepoint == 0);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col); // 커서 불변
    try core.write("\x1b[1;1H\x1b[P"); // 커서 home, DCH 기본 1 — a 삭제, d 당김
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(0, 0)].codepoint);
}

test "DCH pulls a double-width glyph intact when deleting a preceding cell" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();
    try core.write("a한bc"); // a(0) 한(1-2, wide) b(3) c(4)
    try core.write("\x1b[1;1H"); // 커서 home (0,0)=a
    try core.write("\x1b[P"); // DCH 1 — a 삭제, 한이 col0-1로 통째 당겨짐
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expect(core.cells[core.index(0, 1)].continuation); // 한 base+continuation 정합 유지
    try std.testing.expectEqual(@as(u21, 'b'), core.cells[core.index(0, 2)].codepoint);
}

test "ICH clears a wide glyph base pushed half off the line edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();
    try core.write("abc한"); // a(0) b(1) c(2) 한(3-4, wide)
    try core.write("\x1b[1;1H"); // 커서 home
    try core.write("\x1b[@"); // ICH 1 — 한이 줄 끝으로 밀려 continuation이 줄 밖으로
    try std.testing.expectEqual(@as(u21, 'c'), core.cells[core.index(0, 3)].codepoint);
    const last = core.cells[core.index(0, 4)];
    try std.testing.expect(last.codepoint != '한' and last.width != 2); // 고아 base 없이 비워짐
}

test "focus reporting (DECSET 1004): off=무리포트, on=CSI I / CSI O" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 기본 off — 포커스 변화를 리포트하지 않는다.
    core.reportFocus(true);
    try std.testing.expectEqualStrings("", core.pendingResponse());
    // DECSET 1004 on — gained=CSI I, lost=CSI O.
    try core.write("\x1b[?1004h");
    core.clearResponse();
    core.reportFocus(true);
    try std.testing.expectEqualStrings("\x1b[I", core.pendingResponse());
    core.clearResponse();
    core.reportFocus(false);
    try std.testing.expectEqualStrings("\x1b[O", core.pendingResponse());
    // DECSET 1004 off(RST) — 다시 무리포트.
    try core.write("\x1b[?1004l");
    core.clearResponse();
    core.reportFocus(true);
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "mouse reporting (DECSET 1000 + SGR 1006): off=무리포트, press/release/wheel, mode off" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    // off — 무리포트.
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("", core.pendingResponse());
    // 1000(normal) + 1006(SGR). left press col5,row3(0-based) → CSI < 0 ; 6 ; 4 M. SGR은 픽셀 무시(셀).
    try core.write("\x1b[?1000h\x1b[?1006h");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;6;4M", core.pendingResponse());
    // release → 소문자 m.
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, false, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;6;4m", core.pendingResponse());
    // wheel-up(64) → CSI < 64 ; 1 ; 1 M.
    core.clearResponse();
    core.reportMouse(64, 0, 0, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", core.pendingResponse());
    // 1000 off → 무리포트.
    try core.write("\x1b[?1000l");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0);
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "mouse reporting SGR-Pixels format (DECSET 1016): 셀이 아니라 픽셀 좌표 리포트" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    // 1000(normal) + 1016(SGR-Pixels). 셀(5,3)이어도 픽셀(120,72)을 1-based로 리포트한다 —
    // 같은 입력이 1006이면 셀 6;4였을 자리에 픽셀 121;73이 나와야 한다(이게 1016과 1006의 차이).
    try core.write("\x1b[?1000h\x1b[?1016h");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;121;73M", core.pendingResponse());
    // release → 소문자 m, 픽셀 좌표 유지.
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, false, false, 0);
    try std.testing.expectEqualStrings("\x1b[<0;121;73m", core.pendingResponse());
    // 1016 off → format이 x10로 복귀(setPrivateModes 2021: else x10). 픽셀 무시, 셀 32-offset.
    try core.write("\x1b[?1016l");
    core.clearResponse();
    core.reportMouse(0, 5, 3, 120, 72, true, false, 0);
    try std.testing.expectEqualStrings("\x1b[M\x20\x26\x24", core.pendingResponse());
}

test "mouse reporting x10 format (기본): CSI M + 32-offset bytes, press만" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    try core.write("\x1b[?1000h"); // normal tracking, x10 인코딩(기본 format)
    core.clearResponse();
    core.reportMouse(0, 5, 3, 0, 0, true, false, 0); // Cb=0→32(0x20), col6→38(0x26), row4→36(0x24)
    try std.testing.expectEqualStrings("\x1b[M\x20\x26\x24", core.pendingResponse());
}

test "renderSnapshot clears a wide-glyph base truncated by narrowing in a scrollback row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("ab한c\r\nX\r\nY"); // "ab한c"(한 at cols 2-3)이 scroll돼 스크롤백으로
    try std.testing.expect(core.scrollbackLen() >= 1);
    try core.resize(3, 2); // 3칸: 스크롤백 행은 그대로 저장되나, 보일 땐 col 2의 한 base가 잘린다
    core.scrollViewport(@as(isize, @intCast(core.scrollbackLen()))); // 맨 위로
    const snap = core.renderSnapshot();
    // 잘린 한 base(width 2)가 마지막 칸에 남으면 half-glyph가 렌더된다 — 정리됐는지 확인.
    try std.testing.expect(snap.cells[2].width != 2);
}

test "DECSTBM confines scrolling to the region; partial region discards the scrolled-off line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 행0~3 = a,b,c,d
    try core.write("\x1b[2;3r"); // DECSTBM region = 행1~2(1-indexed 2;3), 커서 home으로
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row); // DECSTBM은 커서를 home으로
    try core.write("\x1b[3;1H"); // 커서를 하단 margin(행2)로
    try core.write("\n"); // region [1,2] 위로 스크롤: b 버려지고 c가 행1로, 행2는 빈칸
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump); // 행0(a)·행3(d)는 그대로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // top>0라 스크롤백 보관 안 함
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row); // 커서는 하단 margin 유지
}

test "DECSTBM region at screen top pushes the evicted line to scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region = 행0~2(top==0), 커서 home
    try core.write("\x1b[3;1H"); // 하단 margin(행2)
    try core.write("\n"); // region [0,2] 위로: a는 화면 최상단에서 밀려나므로 스크롤백으로
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("b \nc \n  \nd ", dump);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
}

test "RI scrolls the region down when the cursor is at the top margin" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region 행0~2, 커서 home(행0=상단 margin)
    try core.write("\x1bM"); // RI: 상단 margin이라 region을 아래로 — 행0 빈칸, a->행1, b->행2
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("  \na \nb \nd ", dump); // 행3(d)는 region 밖이라 그대로
}

test "BCE: 스크롤로 들어오는 빈 줄·ED가 현재 pen 배경을 잇는다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    try core.write("\x1b[44m"); // 배경 파랑(SGR 44) → pen에 박힘
    const bg = core.pen.background;
    try std.testing.expect(std.meta.activeTag(bg) != .default); // SGR 44가 non-default bg를 세웠다

    // 화면을 채우고 LF로 한 번 스크롤 → 새로 들어온 맨 아래 빈 줄이 pen 배경을 이어야 한다(BCE).
    try core.write("A\r\nB\r\n");
    const scrolled = core.cells[core.index(1, 0)];
    try std.testing.expectEqual(@as(u21, ' '), scrolled.codepoint);
    try std.testing.expectEqual(bg, scrolled.style.background);

    // ED(\e[2J)도 같은 규칙: 전체를 pen 배경으로 지운다(기존 동작 고정).
    try core.write("\x1b[2J");
    try std.testing.expectEqual(bg, core.cells[core.index(0, 0)].style.background);
    try std.testing.expectEqual(bg, core.cells[core.index(1, 3)].style.background);
}

test "DECSTBM ignores an invalid (top>=bottom) region and keeps the prior one" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2 설정
    try core.write("\x1b[4;2r"); // top(3)>=bottom(1) -> 무시
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "DECOM (DECSET ?6): CUP/HVP/VPA rows are relative to the scroll region and clamped within it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[4;6r"); // DECSTBM: region rows 4~6 (0-based top=3, bottom=5)
    try core.write("\x1b[?6h"); // DECOM on → 커서가 region home(top=3)으로
    try std.testing.expectEqual(@as(u16, 3), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
    try core.write("\x1b[1;3H"); // CUP 1;3 → region top, col 2
    try std.testing.expectEqual(@as(u16, 3), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
    try core.write("\x1b[2;1H"); // CUP 2;1 → region top+1 (row 4)
    try std.testing.expectEqual(@as(u16, 4), core.cursor.row);
    try core.write("\x1b[99;1H"); // CUP 큰 값 → region bottom으로 clamp (row 5)
    try std.testing.expectEqual(@as(u16, 5), core.cursor.row);
    try core.write("\x1b[1d"); // VPA 1 → DECOM origin이라 region top(row 3) — 절대였으면 row 0
    try std.testing.expectEqual(@as(u16, 3), core.cursor.row);
}

test "DECOM off (default): CUP/VPA rows are absolute, ignoring the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[4;6r"); // region 4~6을 설정해도
    try core.write("\x1b[1;1H"); // DECOM off(기본) → CUP 1;1 = 화면 절대 (row 0)
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try core.write("\x1b[8d"); // VPA 8 → row 7 (region 밖이어도 절대)
    try std.testing.expectEqual(@as(u16, 7), core.cursor.row);
}

test "DECOM reset by RIS, reported by DECRQM (?6$p), and DECSTBM homes to region top under DECOM" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
    defer core.deinit();
    try core.write("\x1b[?6h"); // DECOM on
    try std.testing.expect(core.origin_mode);
    core.clearResponse();
    try core.write("\x1b[?6$p"); // DECRQM 질의 → set(1)
    try std.testing.expectEqualStrings("\x1b[?6;1$y", core.pendingResponse());
    try core.write("\x1b[3;7r"); // DECOM on에서 DECSTBM → 커서를 region 상단(top=2)으로 home
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try core.write("\x1bc"); // RIS → DECOM off
    try std.testing.expect(!core.origin_mode);
    core.clearResponse();
    try core.write("\x1b[?6$p"); // DECRQM → reset(2)
    try std.testing.expectEqualStrings("\x1b[?6;2$y", core.pendingResponse());
}

test "resize resets the scroll region to full screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2
    try core.resize(2, 6);
    try std.testing.expectEqual(@as(u16, 0), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 5), core.scroll_bottom); // 새 rows-1
}

test "DECSET 1049 switches to a cleared alt screen and restores primary + cursor on exit" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);

    try core.write("\x1b[?1049h"); // alt 진입: 커서 저장 + 빈 화면
    try std.testing.expect(core.alt_active);
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("        \n        \n        ", dump);
    }
    try core.write("\x1b[1;1HALT"); // alt에 그리기

    try core.write("\x1b[?1049l"); // 복귀: primary 내용 + 커서 복원
    try std.testing.expect(!core.alt_active);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo     \n        ", dump);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
}

test "alt screen output never reaches the scrollback and the viewport is locked" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // primary에서 한 줄 스크롤 -> 스크롤백 1
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());

    try core.write("\x1b[?1049h");
    try core.write("1\r\n2\r\n3\r\n4\r\n5"); // alt에서 여러 줄 스크롤
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen()); // 그대로
    core.scrollViewport(1); // alt에선 잠김
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);

    try core.write("\x1b[?1049l");
    core.scrollViewport(1); // primary 복귀 후엔 다시 동작
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
}

test "DECSET 47 switches screens without saving the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("hi"); // 커서 (0,2)
    try core.write("\x1b[?47h\x1b[2;5H"); // alt에서 커서 (1,4)로 이동
    try core.write("\x1b[?47l"); // 복귀: 1049와 달리 커서 비복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      \n        ", dump); // primary 내용은 복원
}

test "DECSET 1048 saves and restores the cursor without switching screens" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("ab\x1b[?1048h"); // (0,2) 저장
    try core.write("\x1b[2;6H"); // (1,5)로 이동
    try core.write("\x1b[?1048l"); // 복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "resize while in the alt screen clips both grids and restores a matching primary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("hello\r\nworld");
    try core.write("\x1b[?1049h\x1b[1;1HALTALT");
    try core.resize(4, 2); // alt 중 축소: 둘 다 clip/pad, 스크롤백 push 없음
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("ALTA\n    ", dump); // alt 잘림
    }
    try core.write("\x1b[?1049l"); // 복귀: 잘린 primary
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hell\nworl", dump);
}

test "entering the alt screen twice is a no-op (no buffer leak/overwrite)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("ok");
    try core.write("\x1b[?1049h\x1b[?47h"); // 두 번째 enter는 무시
    try std.testing.expect(core.alt_active);
    try core.write("\x1b[?1049l");
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ok  \n    ", dump);
}

test "CSI ?1h/l (DECCKM) flips arrow encoding between SS3 and CSI" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    // 기본(normal): CSI 형식
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1h"); // vim이 켜는 application cursor mode
    try std.testing.expect(core.application_cursor_keys);
    try std.testing.expectEqualStrings("\x1bOA", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1l"); // 끄면 다시 normal
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
}

test "DECCKM combined with alt screen (vim startup sequence) round-trips" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    try core.write("\x1b[?1049h\x1b[?1h"); // vim 진입: alt screen + DECCKM
    try std.testing.expect(core.alt_active);
    try std.testing.expectEqualStrings("\x1bOB", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
    try core.write("\x1b[?1l\x1b[?1049l"); // vim 종료
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqualStrings("\x1b[B", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
}

test "CSI ?1007h/l toggles alternate scroll (default on)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.alternate_scroll); // iTerm2/Terminal.app처럼 기본 on
    try core.write("\x1b[?1007l");
    try std.testing.expect(!core.alternate_scroll);
    try core.write("\x1b[?1007h");
    try std.testing.expect(core.alternate_scroll);
}

test "IL inserts blank lines at the cursor, pushing rows down within the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[L"); // 커서 행1, IL 1: b/c가 내려가고 d는 밀려나감
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \n  \nb \nc ", dump);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col); // IL 후 CR
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 편집 연산은 history 아님
}

test "DL deletes lines at the cursor, pulling rows up; scroll region confines both" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[M"); // DL 1: b 삭제, c/d가 올라오고 바닥 빈 줄
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("a \nc \nd \n  ", dump);
    }
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());

    // scroll region [1,2]에서 DL: region 밖(행0/3)은 불변, region 하단에만 빈 줄.
    try core.write("\x1b[1;1Ha\r\nb\r\nc\r\nd"); // 화면 재구성 a/b/c/d... 행0부터 덮어씀
    try core.write("\x1b[2;3r\x1b[2;1H\x1b[M"); // region 1~2, 커서 행1, DL
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump);
}

test "IL/DL are ignored when the cursor is outside the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;3r"); // region 1~2
    try core.write("\x1b[4;1H\x1b[L\x1b[M"); // 커서 행3(밖): 둘 다 무시
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \nc \nd ", dump);
}

test "DECTCEM (CSI ?25 l/h) hides and shows the cursor in snapshots" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.snapshot().cursor.visible);
    try core.write("\x1b[?25l");
    try std.testing.expect(!core.snapshot().cursor.visible);
    try std.testing.expect(!core.renderSnapshot().cursor.visible);
    try core.write("\x1b[?25h");
    try std.testing.expect(core.snapshot().cursor.visible);
}

test "SGR 7/27 set and clear reverse video on the pen (0 resets it too)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[7mX");
    try std.testing.expect(core.cells[0].style.reverse);
    try core.write("\x1b[27mY");
    try std.testing.expect(!core.cells[1].style.reverse);
    try core.write("\x1b[7m\x1b[0mZ"); // SGR 0이 reverse도 리셋
    try std.testing.expect(!core.cells[2].style.reverse);
}

test "DECSC/DECRC (ESC 7/8) save and restore the cursor around a DECSTBM reset (claude CLI startup)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    // claude CLI 시작 시퀀스: ESC 7(저장), CSI r(region 리셋 — 부수효과로 커서 home), ESC 8(복원).
    try core.write("\x1b7\x1b[r\x1b8!");
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row); // 복원돼 (1,3)에서 이어 그림
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "DECRC restores the pen and clamps a cursor saved on a larger screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[31m\x1b[3;5H\x1b7"); // 빨강 pen + (2,4) 저장
    try core.write("\x1b[0m\x1b[1;1H"); // pen 리셋 + 이동
    try core.write("\x1b8"); // 복원
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.pen.foreground);
    try core.resize(4, 2); // 저장 좌표보다 작은 화면으로
    try core.write("\x1b8"); // clamp돼 grid 안
    try std.testing.expect(core.cursor.row < 2 and core.cursor.col < 4);
}

test "CSI s/u (SCOSC/SCORC) save and restore the cursor like DECSC/DECRC" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    // brew 등 multi-line progress가 쓰는 ANSI 커서 저장/복원. (1,4)로 옮겨 CSI s로 저장하고, 다른
    // 데로 옮긴 뒤 CSI u로 복원하면 (1,4)로 돌아와야 한다 — 안 그러면 진행바가 줄줄이 쌓인다.
    try core.write("\x1b[2;5H"); // CUP (1-indexed 2;5) → row1, col4
    try core.write("\x1b[s"); // SCOSC: 저장
    try core.write("\x1b[3;9H"); // row2, col8로 이동
    try core.write("\x1b[u"); // SCORC: 복원 → row1, col4
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);
}

test "restoreFromSlot (CSI u / DECRC) preserves pending_wrap saved at line end" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("ABCD"); // 마지막 칸을 채워 deferred autowrap(pending_wrap=true), 커서는 col3에 머묾
    try core.write("\x1b[s"); // SCOSC: pending_wrap=true 상태로 저장
    try core.write("\x1b[2;1H"); // 다른 줄로 이동 — pending_wrap 해제
    try core.write("\x1b[u"); // SCORC: 복원 → pending_wrap도 true로 돌아와야 한다
    try core.write("E"); // pending_wrap이면 'E'가 먼저 다음 줄로 넘어가 그려진다
    // 복원이 무효화됐으면(버그) 'E'가 row0 col3(D 자리)를 덮는다. 복원되면 D 유지 + E는 다음 줄.
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(1, 0)].codepoint);
}

test "DA1 (CSI c) answers with a VT102 identification over the response path" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[0c"); // 명시적 0도 동일
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
}

test "OSC 11 (background color) query answers with theme color in xterm rgb format" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xcc, .g = 0xcc, .b = 0xcc }, .{ .r = 0x10, .g = 0x20, .b = 0x30 });
    try core.write("\x1b]11;?\x1b\\"); // OSC 11 ; ? ST — 배경색 질의(nvim 등이 light/dark 테마 감지에 씀)
    // 8-bit 채널을 16-bit로 복제: 0x10→1010, 0x20→2020, 0x30→3030.
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
}

test "OSC 10 (foreground color) query answers; color-set spec is consumed silently (후속)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xab, .g = 0xcd, .b = 0xef }, .{ .r = 0, .g = 0, .b = 0 });
    try core.write("\x1b]10;?\x1b\\"); // 전경색 질의
    try std.testing.expectEqualStrings("\x1b]10;rgb:abab/cdcd/efef\x1b\\", core.pendingResponse());
    // 질의(?)가 아닌 색 설정(spec)은 후속이라 응답 없이 소비만 한다.
    core.clearResponse();
    try core.write("\x1b]10;#ffffff\x1b\\");
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "OSC 52 (clipboard) write decodes base64 into pending; read(?) is ignored (코어는 파싱만)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // "hi" = base64 "aGk=". OSC 52 ; c ; aGk= ST → 디코드된 "hi"가 clipboard_write pending에.
    try core.write("\x1b]52;c;aGk=\x1b\\");
    try std.testing.expectEqualStrings("hi", core.pendingClipboardWrite());
    // 읽기(data가 ?)는 보안상 코어가 무시한다(pending 안 채우고 응답도 안 함 — 원격 clipboard 탈취 방지).
    core.clearClipboardWrite();
    try core.write("\x1b]52;c;?\x1b\\");
    try std.testing.expectEqualStrings("", core.pendingClipboardWrite());
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "OSC 4 (palette) set/query, multi-pair, OSC 104 reset(one/all), RIS clears overrides" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // 설정: OSC 4 ; 1 ; rgb:ff/00/80 ST → 인덱스 1 override.
    try core.write("\x1b]4;1;rgb:ff/00/80\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0xff, .g = 0x00, .b = 0x80 }, core.palette_override[1].?);

    // 질의(override 있음): 8-bit→16-bit 복제(0xff→ffff, 0x80→8080)로 회신.
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:ffff/0000/8080\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 질의(override 없는 인덱스 9 = 기본 xterm256 bright red {255,0,0}).
    try core.write("\x1b]4;9;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;9;rgb:ffff/0000/0000\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 여러 쌍 한 번에(#form·rgb:form 혼용): 인덱스 2·3 동시 설정.
    try core.write("\x1b]4;2;#00ff00;3;rgb:00/00/ff\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0xff, .b = 0x00 }, core.palette_override[2].?);
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0x00, .b = 0xff }, core.palette_override[3].?);

    // OSC 104 ; 1 — 인덱스 1만 리셋(2·3은 유지).
    try core.write("\x1b]104;1\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[1]);
    try std.testing.expect(core.palette_override[2] != null);

    // OSC 104(인덱스 없음) — 전부 리셋.
    try core.write("\x1b]104\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[2]);
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[3]);

    // 잘못된 spec은 무시(인덱스 4 미설정 유지), RIS(ESC c)는 팔레트 override를 공장 초기화.
    try core.write("\x1b]4;4;bogus\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[4]);
    try core.write("\x1b]4;5;rgb:11/22/33\x1b\\");
    try std.testing.expect(core.palette_override[5] != null);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[5]);
}

test "OSC 4 query reflects config_palette base (override > config > xterm256); RIS keeps config" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // platform이 주입하는 config theme.palette base를 흉내(인덱스 1 = {0x12,0x34,0x56}).
    var cfg: [16]?types.Rgb = .{null} ** 16;
    cfg[1] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    core.setConfigPalette(cfg);

    // (a) OSC4 override가 없고 config base가 있으면 config 색을 회신(xterm256이 아니라).
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:1212/3434/5656\x1b\\", core.pendingResponse());
    core.clearResponse();

    // (b) OSC4 override가 있으면 그게 config base보다 우선.
    try core.write("\x1b]4;1;rgb:aa/bb/cc\x1b\\");
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:aaaa/bbbb/cccc\x1b\\", core.pendingResponse());
    core.clearResponse();

    // (c) RIS(ESC c)는 override만 리셋(config base는 유지) — query는 다시 config 색을 회신해야 한다.
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.palette_override[1]); // override는 리셋
    try core.write("\x1b]4;1;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:1212/3434/5656\x1b\\", core.pendingResponse()); // config base 살아남음
    core.clearResponse();

    // (d) idx>=16은 config_palette 대상이 아니므로 xterm256으로 회신(인덱스 16 = xterm256 {0,0,0}).
    const exp16 = types.xterm256(16);
    var buf: [48]u8 = undefined;
    const want16 = try std.fmt.bufPrint(&buf, "\x1b]4;16;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
        exp16.r, exp16.r, exp16.g, exp16.g, exp16.b, exp16.b,
    });
    try core.write("\x1b]4;16;?\x1b\\");
    try std.testing.expectEqualStrings(want16, core.pendingResponse());
    core.clearResponse();
}

test "OSC 10/11 (default fg/bg) set/query/reset; query reflects override; RIS clears" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.setDefaultColors(.{ .r = 0xcc, .g = 0xcc, .b = 0xcc }, .{ .r = 0x10, .g = 0x20, .b = 0x30 }); // theme 주입

    // 설정 전 질의: 주입된 theme 배경색.
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 11 배경 설정 → override.
    try core.write("\x1b]11;rgb:00/80/ff\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0x00, .g = 0x80, .b = 0xff }, core.defaultBgOverride().?);
    // 설정 직후 질의는 set 값을 회신(override 우선).
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:0000/8080/ffff\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 10 전경 설정(#form).
    try core.write("\x1b]10;#ff0000\x1b\\");
    try std.testing.expectEqual(types.Rgb{ .r = 0xff, .g = 0x00, .b = 0x00 }, core.defaultFgOverride().?);

    // OSC 111 = 배경 리셋(전경 override는 유지).
    try core.write("\x1b]111\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultBgOverride());
    try std.testing.expect(core.defaultFgOverride() != null);
    // 리셋 후 질의는 다시 주입 theme 배경.
    try core.write("\x1b]11;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1010/2020/3030\x1b\\", core.pendingResponse());
    core.clearResponse();

    // OSC 110 = 전경 리셋, RIS도 색 설정 공장 초기화.
    try core.write("\x1b]110\x1b\\");
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultFgOverride());
    try core.write("\x1b]10;rgb:11/22/33\x1b\\");
    try std.testing.expect(core.defaultFgOverride() != null);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(?types.Rgb, null), core.defaultFgOverride());
}

test "OSC 9/777 desktop notification: parse iTerm2/rxvt, ConEmu sub-commands ignored" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(core.pendingNotification() == null);

    // OSC 9 ; <message> → iTerm2 알림(title 없음, body=메시지).
    try core.write("\x1b]9;Build finished\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("", n.title);
        try std.testing.expectEqualStrings("Build finished", n.body);
    }
    core.clearNotification();
    try std.testing.expect(core.pendingNotification() == null);

    // OSC 777 ; notify ; <title> ; <body> → rxvt 알림.
    try core.write("\x1b]777;notify;Deploy;done in 3s\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("Deploy", n.title);
        try std.testing.expectEqualStrings("done in 3s", n.body);
    }
    core.clearNotification();

    // body에 ';'가 더 있어도 첫 ';'만 title/body 경계(body는 ';' 포함 가능).
    try core.write("\x1b]777;notify;T;a;b;c\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("T", n.title);
        try std.testing.expectEqualStrings("a;b;c", n.body);
    }
    core.clearNotification();

    // ConEmu 서브커맨드는 알림으로 오발사 안 함: 9;4 progress(진행바 폭탄 방지)·9;1 sleep.
    try core.write("\x1b]9;4;1;50\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);
    try core.write("\x1b]9;1;420\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);

    // 선두 숫자라도 다음이 ';'가 아니면(숫자+공백/글자) iTerm2 알림으로 발사.
    try core.write("\x1b]9;42 builds done\x1b\\");
    {
        const n = core.pendingNotification().?;
        try std.testing.expectEqualStrings("42 builds done", n.body);
    }
    core.clearNotification();

    // OSC 777의 notify 외 서브타입은 무시.
    try core.write("\x1b]777;precmd\x1b\\");
    try std.testing.expect(core.pendingNotification() == null);
}

test "G3 charset: ESC ( 0 dec_special (G0), SO/SI invoke G1/G0, ESC ( B restores, RIS resets" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // ESC ( 0 → G0=dec_special. GL=G0(기본)이라 'q'→─, 'x'→│. 그 뒤 ESC ( B → G0=ascii 복귀, 'q'는 그대로.
    try core.write("\x1b(0qx\x1b(Bq");
    // 둘째 줄: ESC ) 0 → G1=dec_special. SO(0x0e)로 G1 호출 → 'l'→┌, 'q'→─. SI(0x0f)로 G0(ascii) 복귀 → 'l'.
    try core.write("\r\n\x1b)0\x0elq\x0fl");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("─│q     \n┌─l     ", dump);
    }

    // RIS는 charset도 공장 초기화: dec_special 지정 후 RIS → 'q'는 다시 ascii(변환 안 됨).
    try core.write("\x1b(0\x1bcq");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("q       \n        ", dump);
    }
}

test "G4 tabstops: default 8, HTS sets, CBT back, TBC clears, RIS/resize default" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 2 });
    defer core.deinit();

    // 기본 탭스톱 8칸: col 0 → TAB → 8 → TAB → 16.
    try core.write("\t");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);
    try core.write("\t");
    try std.testing.expectEqual(@as(u16, 16), core.cursor.col);

    // CBT(CSI Z): 역방향 한 탭스톱 → 8. CBT 2개: 8 → 0.
    try core.write("\x1b[Z");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);
    try core.write("\x1b[2Z");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);

    // HTS(ESC H): col 3에 탭스톱 설정 → col 0에서 TAB은 3(기본 8보다 먼저).
    try core.write("\x1b[4G\x1bH"); // CHA col 3(1-based 4) + HTS
    try core.write("\r\t");
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);

    // TBC(CSI g 기본 0): col 3 탭스톱 제거 → TAB은 다시 8.
    try core.write("\x1b[4G\x1b[g\r\t");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);

    // TBC 3(전체 제거): TAB은 마지막 칸(cols-1=29)으로.
    try core.write("\x1b[3g\r\t");
    try std.testing.expectEqual(@as(u16, 29), core.cursor.col);

    // RIS는 탭스톱을 8칸 기본으로 복원.
    try core.write("\x1bc\t");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);

    // resize(폭 변경) 후에도 8칸 기본 유지(새 열 포함): 0→8→16→24→32.
    try core.resize(40, 2);
    try core.write("\r\t\t\t\t");
    try std.testing.expectEqual(@as(u16, 32), core.cursor.col);
}

test "G12 BEL/NEL/VT/FF: bell pending(once), NEL=CR+LF, VT/FF=LF(col 유지)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // BEL(0x07): bell_pending set, takeBell이 한 번 true 후 소비(false).
    try std.testing.expect(!core.takeBell());
    try core.write("\x07");
    try std.testing.expect(core.takeBell());
    try std.testing.expect(!core.takeBell());

    // NEL(ESC E): CR+LF — col 5에서 → 다음 줄 0열.
    try core.write("abcde");
    try std.testing.expectEqual(@as(u16, 5), core.cursor.col);
    try core.write("\x1bE");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);

    // VT(0x0b)/FF(0x0c): LF처럼 한 줄 내림(col 유지). col 3에서 VT→row2·col3, FF→row3·col3.
    try core.write("xyz");
    try core.write("\x0b");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
    try core.write("\x0c");
    try std.testing.expectEqual(@as(u16, 3), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
}

test "G5/6/7/8/11/13 small gaps: REP, DECALN, IRM, DECAWM off, SU, urxvt mouse" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 4 });
    defer core.deinit();

    // G5 REP(CSI Ps b): 'a' 출력 후 CSI 3 b → 'a' 3개 더 반복 → "aaaa".
    try core.write("a\x1b[3b");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "aaaa"));
    }

    // 회귀: REP는 '표시된 글리프'를 반복한다 — 출력 후 charset이 바뀌어도 재변환하지 않는다. ASCII에서 'q'
    // 출력 → dec_special(ESC ( 0) 전환 → REP는 'q'를 반복(box `─`로 재변환 아님). putCell 직접 호출로 보장.
    try core.write("\x1bcq\x1b(0\x1b[2b");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "qqq"));
    }

    // G11 DECALN(ESC # 8): 화면 전체 'E', 커서 home.
    try core.write("\x1b#8");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("EEEEEE\nEEEEEE\nEEEEEE\nEEEEEE", dump);
    }

    // G6 IRM(CSI 4h): insert mode. "Xb" 위 home에서 IRM on + "A" → "AXb"(X가 오른쪽으로 밀림).
    try core.write("\x1bcXb\x1b[H\x1b[4hA");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "AXb"));
    }

    // G8 DECAWM off(?7l): 마지막 칸에서 wrap 안 함(덮어쓰기). cols=6: "wxyz12" 채우고 '3'은 마지막 칸 덮어씀.
    try core.write("\x1bc\x1b[?7lwxyz123");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "wxyz13"));
    }

    // G7 SU(CSI S): scroll region 위로 1줄 팬. row0=11/row1=22/row2=33 → SU → row0=22, row1=33.
    try core.write("\x1bc11\r\n22\r\n33\x1b[S");
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expect(std.mem.startsWith(u8, dump, "22"));
        try std.testing.expect(std.mem.indexOf(u8, dump, "33") != null);
    }

    // G13 mouse urxvt(?1015h): mouse_format이 urxvt로 전환(인코딩은 x10 Cb를 십진 CSI Cb;Px;Py M로).
    try core.write("\x1b[?1015h");
    try std.testing.expectEqual(MouseFormat.urxvt, core.mouse_format);
    try core.write("\x1b[?1015l");
    try std.testing.expectEqual(MouseFormat.x10, core.mouse_format);
}

test "G9 DECSCNM: CSI ?5 h/l toggles reverse_screen, RIS resets" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(!core.reverseScreen());
    try core.write("\x1b[?5h");
    try std.testing.expect(core.reverseScreen());
    try core.write("\x1b[?5l");
    try std.testing.expect(!core.reverseScreen());
    try core.write("\x1b[?5h\x1bc"); // set + RIS
    try std.testing.expect(!core.reverseScreen());
}

test "G1 SGR ext: blink(5/25), conceal(8/28), double-underline(21), underline color(58/59)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // SGR 5(blink)·8(conceal)·21(double→underline)·58;2;10;20;30(underline color) → pen에 반영.
    try core.write("\x1b[5;8;21;58;2;10;20;30mA");
    const c0 = core.cells[core.index(0, 0)];
    try std.testing.expect(c0.style.blink);
    try std.testing.expect(c0.style.conceal);
    try std.testing.expect(c0.style.underline);
    try std.testing.expectEqual(types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, c0.style.underline_color);

    // SGR 25(blink off)·28(reveal)·24(underline off)·59(underline color default) → 끄기.
    try core.write("\x1b[25;28;24;59mB");
    const c1 = core.cells[core.index(0, 1)];
    try std.testing.expect(!c1.style.blink);
    try std.testing.expect(!c1.style.conceal);
    try std.testing.expect(!c1.style.underline);
    try std.testing.expectEqual(types.Color.default, c1.style.underline_color);

    // 58;5;n(indexed) underline color.
    try core.write("\x1b[58;5;42mC");
    try std.testing.expectEqual(types.Color{ .indexed = 42 }, core.cells[core.index(0, 2)].style.underline_color);
}

test "G14 DCS/DECRQSS: SGR(m), DECSTBM(r), cursor style( q), invalid → DCS 0 \\$r" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    // 기본 pen에서 SGR 질의: DCS $ q m ST → DCS 1 $ r 0 m ST.
    try core.write("\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // bold+underline+fg red(31) 설정 후 SGR 질의 → 0;1;4;31.
    try core.write("\x1b[1;4;31m\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0;1;4;31m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // fg 256색(38;5;200) + underline color rgb(58;2;1;2;3) → 그대로 재구성.
    try core.write("\x1b[0;38;5;200;58;2;1;2;3m\x1bP$qm\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r0;38;5;200;58;2;1;2;3m\x1b\\", core.pendingResponse());
    core.clearResponse();

    // DECSTBM 질의: scroll region 2..4 설정 후 DCS $ q r → DCS 1 $ r 2;4 r ST.
    try core.write("\x1b[2;4r\x1bP$qr\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r2;4r\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 커서 스타일 질의: DECSCUSR 2(고정 block) → DCS $ q SP q → 1 $ r 2 SP q.
    try core.write("\x1b[2 q\x1bP$q q\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1$r2 q\x1b\\", core.pendingResponse());
    core.clearResponse();

    // 미지원 설정 질의 → DCS 0 $ r ST(invalid).
    try core.write("\x1bP$qZ\x1b\\");
    try std.testing.expectEqualStrings("\x1bP0$r\x1b\\", core.pendingResponse());
}

test "G10 DECKPAM/DECKPNM (ESC =/ESC >): keypad mode toggles, RIS resets, no screen leak" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try std.testing.expect(!core.application_keypad);
    try core.write("\x1b="); // DECKPAM → application
    try std.testing.expect(core.application_keypad);
    try core.write("\x1b>"); // DECKPNM → numeric
    try std.testing.expect(!core.application_keypad);
    try core.write("\x1b=\x1bc"); // set + RIS → numeric 복원
    try std.testing.expect(!core.application_keypad);
    // ESC =/> 는 화면에 텍스트로 새지 않는다(상태만).
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("    ", dump);
}

test "DECSC inside the alt screen does not clobber the cursor saved by 1049 (per-screen slots)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo"); // 셸 커서 (1,3)
    try core.write("\x1b[?1049h"); // 셸 커서를 primary 슬롯에 저장
    try core.write("\x1b[3;5H\x1b7\x1b[1;1H\x1b8"); // alt 안에서 ESC 7/8 사용(claude 패턴)
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row); // alt 슬롯 복원 동작
    try core.write("\x1b[?1049l!"); // 종료: primary 슬롯에서 셸 커서 복원
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "1049l on the primary screen still restores the saved cursor (xterm unconditional restore)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\x1b[?1049h\x1b[?47l"); // 1049 진입 후 47로 이탈(커서 비복원 leave)
    try core.write("\x1b[3;7H"); // 커서를 멀리
    try core.write("\x1b[?1049l"); // 방어적 정리: primary지만 저장 커서 복원해야 한다
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "resize while in the alt screen preserves the saved primary's soft-wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("abcdef"); // abcd|ef soft-wrap: wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[?1049h");
    try core.resize(4, 3); // alt 중 행 수만 축소
    try core.write("\x1b[?1049l");
    try std.testing.expect(core.wrapped[0]); // primary 복원 후에도 wrap 메타데이터 생존
}

test "region scrolls break stale soft-wrap links at the range boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    // 행2-3에 걸친 soft-wrap 줄을 만든다: 행0/1 채우고 "abcdef"(행2 abcd|행3 ef).
    try core.write("x\r\ny\r\nabcdef");
    try std.testing.expect(core.wrapped[2]);
    // 커서 행3에서 IL: 행3이 비고 wrapped[2]의 연속 주장은 깨져야 한다.
    try core.write("\x1b[L");
    try std.testing.expect(!core.wrapped[2]);
    // resize가 빈 행을 이전 줄에 합치지 않는다.
    try core.resize(8, 4);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("x       \ny       \nabcd    \n        ", dump);
}

test "EL and ED clear the deferred-autowrap state (xterm behavior)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸 채움 -> pending_wrap
    try std.testing.expect(core.pending_wrap);
    try core.write("\x1b[K!"); // EL 0 후 글자: wrap 없이 같은 행에 찍혀야 한다
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try core.write("\x1b[2J");
    try std.testing.expect(!core.pending_wrap); // ED도 동일
}

test "a CSI split across writes survives a resize in between (parser state kept)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[31"); // SGR 빨강의 앞부분(쪼개진 read)
    try core.resize(10, 3); // 시퀀스 한가운데 resize
    try core.write("mX"); // 꼬리 도착: 'm'은 글자가 아니라 SGR 완성이어야 한다
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[0].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[0].style.foreground);
}

test "CSI sequences with intermediates are consumed, not dispatched as their bare final" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region [1,2]
    try core.write("\x1b[1;1;2;2$r"); // DECCARA($r) — DECSTBM으로 오발동하면 region이 바뀐다
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "DA2 (CSI > c) is answered and '>'-marked sequences never leak into SGR" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[>4;2m"); // modifyOtherKeys — SGR(4;2=underline)로 새면 안 된다
    try core.write("X");
    try std.testing.expect(!core.cells[0].style.underline);
}

test "ED 3 (CSI 3J) clears the scrollback while ED 2 keeps it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백 2줄 생성
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try core.write("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // ED 2는 화면만
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try core.write("\x1b[3J"); // E3: history까지 비우고 뷰포트도 바닥으로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);
    try core.write("x\r\ny\r\nz"); // 비운 뒤 ring 재사용이 정상인지(커서가 바닥이라 2회 스크롤)
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "IL/DL with count > 1 move the block once (CSI 2L / CSI 2M)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;1H\x1b[2L"); // 행0에 빈 줄 2개 삽입: _,_,a,b
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("  \n  \na \nb ", dump);
    }
    try core.write("\x1b[2M"); // 행0부터 2줄 삭제: a,b,_,_
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \n  \n  ", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "scrollback rows re-wrap to the new width when the user scrolls back after a resize" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // "abcdefgh" 한 줄(8칸 꽉 참 — hard)과 "xy"가 스크롤백으로 밀린다.
    try core.write("abcdefgh\r\nxy\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());

    try core.resize(4, 2); // 좁힘: 스크롤백의 "abcdefgh"는 4칸 두 행이 되어야 한다
    core.scrollViewport(10); // 과거 보기(여기서 지연 재-wrap 수행) — 맨 위로
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen()); // abcd|efgh|xy
    try std.testing.expectEqualSlices(u8, "abcd", &cellsText4(core.scrollbackRow(0).?));
    try std.testing.expectEqualSlices(u8, "efgh", &cellsText4(core.scrollbackRow(1).?));
    try std.testing.expect(core.scrollbackRowWrapped(0)); // abcd -> efgh 연속
    try std.testing.expect(!core.scrollbackRowWrapped(1)); // efgh는 hard 끝

    try core.resize(8, 2); // 다시 넓힘: 쪼개졌던 행이 한 행으로 합쳐져야 한다
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    const joined = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(u21, 'a'), joined[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), joined[7].codepoint);
}

fn cellsText4(row: []const types.Cell) [4]u8 {
    var out: [4]u8 = .{ ' ', ' ', ' ', ' ' };
    for (row[0..@min(row.len, 4)], 0..) |cell, k| out[k] = @intCast(cell.codepoint);
    return out;
}

test "scrollback re-wrap keeps hard line boundaries separate and drops oldest rows past the cap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 4; // 작은 cap으로 드랍 검증
    try core.write("aaaa\r\nbb\r\ncccc\r\ndd\r\n1\r\n2"); // 4줄이 스크롤백(각각 hard)
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());

    try core.resize(2, 2); // 2칸: aaaa->aa|aa, bb->bb, cccc->cc|cc, dd->dd = 6행 > cap 4
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen()); // 오래된 2행 드랍
    // 남은 것은 최신 4행: cc, cc, dd 쪽이 보존되고 hard 경계(bb/cccc 사이 등)는 안 합쳐졌다.
    const last = core.scrollbackRow(3).?;
    try std.testing.expectEqual(@as(u21, 'd'), last[0].codepoint);
    try std.testing.expect(!core.scrollbackRowWrapped(3));
}

test "scrollback re-wrap is deferred until the scrollback is actually viewed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("abcdefgh\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try core.resize(4, 2);
    // 아직 안 봤으니 ring은 옛 폭 그대로(지연) — 행 수 불변.
    try std.testing.expect(core.sb_rewrap_pending);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    core.scrollViewport(1); // 보는 순간 재-wrap
    try std.testing.expect(!core.sb_rewrap_pending);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "resize while scrolled back keeps the viewed scrollback row anchored (Ghostty tracked-pin semantics)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 스크롤백 4행: aaaa / abcdefgh / cccc / dddd (모두 hard).
    try core.write("aaaa\r\nabcdefgh\r\ncccc\r\ndddd\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());
    core.scrollViewport(3); // 뷰 최상단 = 스크롤백 행1("abcdefgh")
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[1].codepoint);

    try core.resize(4, 2); // 좁힘: abcdefgh -> abcd|efgh. 보던 행("abcd...")이 그대로 보여야 한다.
    try std.testing.expect(core.view_offset > 0); // 바닥으로 안 튕김
    const top = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top[1].codepoint);

    try core.resize(8, 2); // 다시 넓힘(행 합쳐져 sb_count 감소): 여전히 같은 내용이 보인다.
    const top2 = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top2[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top2[1].codepoint);
    try std.testing.expect(core.view_offset <= core.scrollbackLen()); // Ghostty 회귀 클래스(범위 초과) 방어
}

test "resize overflow pushed to scrollback keeps the scrolled view in place (scroll-lock)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("aa\r\nbb\r\ncc\r\ndd\r\nee\r\nff"); // 스크롤백 2(aa,bb) + 화면 cc,dd,ee,ff
    core.scrollViewport(2); // 맨 위(aa)를 본다
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try core.resize(4, 2); // 행 수 축소: 화면 위쪽이 스크롤백으로 밀린다(overflow push)
    // 보던 행(aa)이 여전히 뷰 최상단이어야 한다 — push마다 offset이 같이 올라갔어야(scroll-lock).
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
}

test "DECSCUSR (CSI Ps SP q) sets the cursor shape and blink" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape); // 기본 blink block
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[5 q"); // 깜빡 bar(vim 삽입 모드가 흔히 씀)
    try std.testing.expectEqual(types.CursorShape.bar, core.cursor_shape);
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[4 q"); // 고정 underline
    try std.testing.expectEqual(types.CursorShape.underline, core.cursor_shape);
    try std.testing.expect(!core.cursor_blink);
    try core.write("\x1b[0 q"); // 0 -> 기본(깜빡 block)
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
    try std.testing.expect(core.snapshot().cursor_shape == .block);
    try core.write("\x1b[9 q"); // 모르는 값은 무시
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
}

test "selection extracts text across soft-wrapped and hard rows (scrollback + active)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // "abcdef"(abcd|ef soft-wrap) + "hi" — abcd가 스크롤백으로 밀린 상태를 만든다.
    try core.write("abcdef\r\nhi\r\nx");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // abcd, ef

    // 스크롤백 행0(abcd)부터 활성 행0(x 이전의 hi... 레이아웃: sb=[abcd,ef], 화면=[hi, x])
    core.scrollViewport(2); // 맨 위 — 뷰포트 [abcd, ef]
    core.selectionStart(0, 0); // abs 0 (abcd 시작)
    core.selectionExtend(1, 3); // abs 1 (ef 행 끝)
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // soft-wrap 경계는 줄바꿈 없이 이어진다: "abcdef"
    try std.testing.expectEqualStrings("abcdef", text);

    // hard 경계를 포함한 선택: ef(abs1) ~ hi(abs2, 활성 행0)
    core.selectionStart(1, 0);
    core.scrollToBottom(); // 선택은 절대 좌표라 스크롤해도 유지
    core.selectionExtend(0, 3); // 바닥 뷰포트 행0 = abs2(hi)
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("ef\nhi", text2);
}

test "selection span clips to the viewport and follows scrolling" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // sb=[a,b], 화면=[c,d]
    core.selectionStart(0, 0); // abs 2(c)
    core.selectionExtend(1, 1); // abs 3(d)
    const span = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);

    core.scrollViewport(2); // 위로 — 선택(c,d)은 화면 밖
    try std.testing.expect(core.selectionViewportSpan() == null);
    core.scrollViewport(-1); // 한 줄 내림 — 뷰포트 [b, c]: 선택 시작(c)이 행1에 보인다
    const span2 = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 1), span2.start.row);
    try std.testing.expectEqual(@as(u16, 1), span2.end.row); // d는 아래로 클립
    try std.testing.expectEqual(@as(u16, 3), span2.end.col);
}

test "block selection extracts a rectangle column-slice per row (Option+drag)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr"); // 3행, 각 6글자(cols=8라 wrap 없음)

    // 블록 선택 cols 1..3 × rows 0..2 → 각 행의 [1,3] 열만, 행마다 개행(소프트랩 무관).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 3);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("bcd\nhij\nnop", text);

    // anchor col > head col이어도 min/max로 같은 사각형.
    core.selectionStart(0, 3);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 1);
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("bcd\nhij\nnop", text2);

    // hi가 내용보다 넓으면 각 행 뒤 빈칸을 trim(패딩 제외 — 선형 추출과 같은 규칙).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 7);
    const text3 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text3);
    try std.testing.expectEqualStrings("bcdef\nhijkl\nnopqr", text3);
}

test "block selection span carries block flag + lo/hi; selectionStart resets to linear" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr");

    core.selectionStart(0, 3);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 1);
    const span = core.selectionViewportSpan().?;
    try std.testing.expect(span.block);
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 2), span.end.row);
    try std.testing.expectEqual(@as(u16, 1), span.start.col); // lo
    try std.testing.expectEqual(@as(u16, 3), span.end.col); // hi

    // 새 selectionStart는 선형으로 리셋(이전 블록 모드가 새 선택에 안 샌다).
    core.selectionStart(0, 0);
    core.selectionExtend(0, 2);
    const span2 = core.selectionViewportSpan().?;
    try std.testing.expect(!span2.block);

    // setSelectionBlock은 anchor 없으면 무시(선택 없는데 블록 토글은 무효).
    core.selectionClear();
    core.setSelectionBlock(true);
    try std.testing.expect(!core.selection_block);
}

test "selectAll/selectWordAt/selectLineAt이 블록 모드를 리셋한다(Option+드래그 뒤 누수 방지)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nghijkl\r\nmnopqr");

    // selectAll: 블록 켠 뒤 ⌘A는 선형 전체여야 한다(직사각형 truncate 누수 방지 — 리뷰 발견 #1).
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectionExtend(2, 3);
    core.selectAll();
    try std.testing.expect(!core.selection_block);
    const all = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualStrings("abcdef\nghijkl\nmnopqr", all); // 직사각형이 아니라 전체

    // selectWordAt(더블클릭)·selectLineAt(트리플클릭)도 새 선택이라 선형으로 리셋.
    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectWordAt(0, 0); // 'a'..'f' run
    try std.testing.expect(!core.selection_block);

    core.selectionStart(0, 1);
    core.setSelectionBlock(true);
    core.selectLineAt(1);
    try std.testing.expect(!core.selection_block);
}

test "selection survives new output until eviction shifts it off the ring" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 2;
    try core.write("a\r\nb\r\nc"); // sb=[a], 화면=[b,c]
    core.selectionStart(0, 0);
    core.selectionExtend(0, 0); // abs 0 = "a"(스크롤백 첫 행 — 화면 첫 행 b가 아님? 뷰포트 행0=b... )
    // 주: 바닥 뷰포트 행0 = abs sb_count(1)=b. 위 선택은 b를 가리킨다.
    try core.write("\r\nd"); // 스크롤 1회: sb=[a,b] (cap 2, eviction 없음) — 선택 abs는 불변(내용 b 유지)
    const t1 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("b", t1);
    try core.write("\r\ne"); // 또 스크롤: cap 도달, a가 evict — 선택(b)은 -1 보정돼 유지
    const t2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("b", t2);
    try core.write("\r\nf"); // b도 evict — 선택이 ring 밖으로: 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "double-click selects the word run, extending across a soft-wrap boundary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab cdefghij kl"); // 8칸: "ab cdefg"|"hij kl" — 단어 cdefghij가 wrap을 넘는다
    try std.testing.expect(core.wrapped[0]);

    core.selectWordAt(0, 4); // 행0 col4('e') 더블클릭
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("cdefghij", text); // wrap 경계 너머까지 한 단어

    core.selectWordAt(1, 4); // 행1 col4 ('k') — 같은 행 안 단어
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("kl", text2);

    core.selectWordAt(0, 2); // 공백 더블클릭 -> 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "triple-click selects the whole logical line including wrapped rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nxy"); // abcd|ef(논리 한 줄) + xy
    core.selectLineAt(1); // wrap된 두 번째 행을 트리플클릭해도 논리 줄 전체
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abcdef", text);
}

test "encodePaste normalizes newlines and wraps with bracketed paste when DECSET 2004 is on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // 기본(비-bracketed): \r\n/\n -> \r 정규화만.
    const plain = try core.encodePaste(std.testing.allocator, "a\r\nb\nc");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a\rb\rc", plain);

    try core.write("\x1b[?2004h"); // zsh/claude가 켜는 bracketed paste
    const wrapped_paste = try core.encodePaste(std.testing.allocator, "ls\n");
    defer std.testing.allocator.free(wrapped_paste);
    try std.testing.expectEqualStrings("\x1b[200~ls\r\x1b[201~", wrapped_paste);

    try core.write("\x1b[?2004l");
    try std.testing.expect(!core.bracketed_paste);
}

test "encodePaste strips ESC from the body to prevent bracketed-paste injection" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2004h"); // bracketed paste on
    // 악성 클립보드: 본문에 ESC[201~를 심어 괄호를 일찍 닫고 명령을 주입하려 함.
    const malicious = "x\x1b[201~\rrm -rf ~\r";
    const encoded = try core.encodePaste(std.testing.allocator, malicious);
    defer std.testing.allocator.free(encoded);
    // 본문의 ESC가 공백이 돼 인젝션 시퀀스가 무력화되고, 진짜 종료 괄호는 끝에 하나뿐이어야 한다.
    try std.testing.expectEqualStrings("\x1b[200~x [201~\rrm -rf ~\r\x1b[201~", encoded);
    // 본문 안에는 ESC가 없다(시작/끝 괄호의 ESC 2개만).
    var esc_count: usize = 0;
    for (encoded) |b| {
        if (b == 0x1b) esc_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), esc_count);
}

test "extractUrlAt finds an http(s) URL in the clicked word, across soft-wrap, trimming punctuation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("see (https://a.bc/dpath)."); // 12칸 wrap: "see (https:/"|"/a.bc/dpath)"|"."
    try std.testing.expect(core.wrapped[0]);

    // wrap된 URL의 두 번째 행을 Cmd+클릭해도 전체 URL이 나오고, 끝 ")."는 다듬어진다.
    const url = (try core.extractUrlAt(std.testing.allocator, 1, 3)).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://a.bc/dpath", url);

    // URL이 아닌 단어는 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 0)) == null);
    // 공백도 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 3)) == null);
}

test "urlAnchorAt + urlSpanAtAbs project the hovered URL word, following content and rejecting non-URLs" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("go https://a.bc/d now");
    const anchor = core.urlAnchorAt(0, 5).?; // URL 위 → 단어 시작 절대 좌표
    const span = core.urlSpanAtAbs(anchor).?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 3), span.start.col); // "https://..." 단어 시작
    try std.testing.expect(core.urlAnchorAt(0, 0) == null); // "go"
    try std.testing.expect(core.wordIsUrl(0, 5)); // 할당 없는 판정도 같은 결과
    try std.testing.expect(!core.wordIsUrl(0, 0));
}

test "urlSpanInWord keeps balanced trailing parens but trims prose punctuation" {
    // Wikipedia식: 끝 ')'가 열린 '('와 균형이면 URL의 일부.
    const a = TerminalCore.urlSpanInWord("https://en.wikipedia.org/wiki/Foo_(bar)").?;
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", "https://en.wikipedia.org/wiki/Foo_(bar)"[a.start..a.end]);
    // 산문 속: 균형 안 맞는 끝 ')'와 '.'은 다듬는다.
    const b = TerminalCore.urlSpanInWord("(https://a.bc/d).").?;
    try std.testing.expectEqualStrings("https://a.bc/d", "(https://a.bc/d)."[b.start..b.end]);
}

test "selection is invalidated by row-relocating ops that break absolute coords" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();

    // resize(폭 변경): 활성 화면이 reflow돼 선택 해제.
    try core.write("ab\r\ncd");
    core.selectionStart(0, 0);
    core.selectionExtend(1, 1);
    try std.testing.expect(core.selection_anchor != null);
    try core.resize(6, 3);
    try std.testing.expect(core.selection_anchor == null);

    // resize(높이만): 폭 불변이라도 해제(이전엔 안 했음).
    core.selectionStart(0, 0);
    try core.resize(6, 2);
    try std.testing.expect(core.selection_anchor == null);

    // IL/DL(scrollRangeDown/Up, 부분 이동): 해제.
    try core.write("\x1b[1;1Hx\r\ny");
    core.selectionStart(0, 0);
    try core.write("\x1b[L"); // IL
    try std.testing.expect(core.selection_anchor == null);
    core.selectionStart(0, 0);
    try core.write("\x1b[M"); // DL
    try std.testing.expect(core.selection_anchor == null);

    // alt screen 전환: 진입/복귀 모두 해제.
    core.selectionStart(0, 0);
    try core.write("\x1b[?1049h");
    try std.testing.expect(core.selection_anchor == null);
    core.selectionStart(0, 0);
    try core.write("\x1b[?1049l");
    try std.testing.expect(core.selection_anchor == null);

    // ED 3(clearScrollback): 해제.
    try core.write("p\r\nq\r\nr\r\ns"); // 스크롤백 생성
    core.selectionStart(0, 0);
    try core.write("\x1b[3J");
    try std.testing.expect(core.selection_anchor == null);
}

test "selection still follows content through a full-screen scroll (preserved case)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("aa\r\nbb"); // 화면 [aa, bb]
    core.selectionStart(0, 0);
    core.selectionExtend(0, 1); // "aa"(활성 행0)
    try core.write("\r\ncc"); // 전체 화면 스크롤: aa -> 스크롤백, 선택은 따라가 유지
    try std.testing.expect(core.selection_anchor != null);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa", text);
}

test "selectAll selects scrollback + screen regardless of scroll position" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // "a"가 스크롤백으로, "b"/"c"가 화면에 남게(2행 화면). sb_count=1, 화면 [b, c].
    try core.write("a\r\nb\r\nc");
    try std.testing.expect(core.sb_count >= 1);

    core.selectAll();
    // anchor=첫 스크롤백 행(abs 0, col 0), head=마지막 화면 행(abs sb_count+rows-1).
    try std.testing.expectEqual(@as(usize, 0), core.selection_anchor.?.row);
    try std.testing.expectEqual(@as(u16, 0), core.selection_anchor.?.col);
    try std.testing.expectEqual(core.sb_count + core.size.rows - 1, core.selection_head.?.row);

    // 추출하면 전체 내용(스크롤백 a + 화면 b,c)이 줄바꿈으로 잡힌다(빈 칸 trim).
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a\nb\nc", text);

    // 스크롤 위치와 무관: 위로 스크롤한 뒤에도 같은 절대 범위.
    core.selectionClear();
    core.scrollViewport(1); // 위로 1행 스크롤(스크롤백 노출)
    core.selectAll();
    try std.testing.expectEqual(@as(usize, 0), core.selection_anchor.?.row);
    try std.testing.expectEqual(core.sb_count + core.size.rows - 1, core.selection_head.?.row);
}

test "scrollback re-wrap clears a truncated wide-glyph base at narrow widths" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\xed\x95\x9c\xed\x95\x9c\r\n1\r\n2"); // "한한"(wide) 한 줄이 스크롤백으로
    try std.testing.expect(core.scrollbackLen() >= 1);
    try core.resize(2, 2); // 2칸 — 한(width2)이 한 칸씩 차지
    core.scrollViewport(10); // 재-wrap 트리거
    // 재-wrap된 스크롤백 행의 마지막 칸이 잘린 wide base(width 2)로 남지 않아야 한다.
    var r: usize = 0;
    while (r < core.scrollbackLen()) : (r += 1) {
        const row = core.scrollbackRow(r).?;
        if (row.len > 0) try std.testing.expect(row[row.len - 1].width != 2);
    }
}

test "OSC 8 hyperlink: click returns the stored URI regardless of visible text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    // "여기" 두 글자(wide)에 링크. ST(ESC \) 종료.
    try core.write("\x1b]8;;https://maru.dev/docs\x1b\\click here\x1b]8;;\x1b\\ tail");
    // 링크 텍스트 위 클릭 — 보이는 텍스트("click here")가 아니라 지정 URI가 나온다.
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 2)).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://maru.dev/docs", url);
    try std.testing.expect(core.wordIsUrl(0, 2));
    // 링크 안 공백("click here"의 ' ')도 같은 링크다.
    try std.testing.expect(core.wordIsUrl(0, 5));
    // 링크 밖("tail")은 아니다.
    try std.testing.expect(!core.wordIsUrl(0, 12));
    // 닫은 뒤 출력엔 링크가 없다.
    try std.testing.expectEqual(@as(u32, 0), core.cells[12].link);
}

test "OSC 8 hyperlink: BEL terminator, id= params ignored, same URI interned once" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]8;id=x;https://a.bc\x07one\x1b]8;;\x07 \x1b]8;;https://a.bc\x07two\x1b]8;;\x07");
    try std.testing.expectEqual(@as(usize, 1), core.link_store.items.len); // dedup
    try std.testing.expectEqual(core.cells[0].link, core.cells[5].link); // 같은 id 재사용
    const url = (try core.extractUrlAt(std.testing.allocator, 0, 0)).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://a.bc", url);
}

test "OSC 8 hyperlink: span underlines the whole link run and survives soft-wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]8;;https://a.bc/long\x1b\\abcdefgh\x1b]8;;\x1b\\"); // 6칸 wrap: abcdef|gh
    try std.testing.expect(core.wrapped[0]);
    const anchor = core.urlAnchorAt(1, 1).?; // 둘째 줄에서 클릭해도
    try std.testing.expectEqual(@as(usize, 0), anchor.row); // run 시작은 첫 줄
    const span = core.urlSpanAtAbs(anchor).?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 0), span.start.col);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.col); // "gh"까지
    const url = (try core.extractUrlAt(std.testing.allocator, 1, 0)).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://a.bc/long", url);
}

test "OSC 8 oversized URI is ignored and plain heuristic still works" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 30, .rows = 3 });
    defer core.deinit();
    // 버퍼(2048)를 넘는 OSC — 통째로 무시되고 출력은 정상.
    var big: [3000]u8 = undefined;
    @memset(&big, 'u');
    try core.write("\x1b]8;;https://");
    try core.write(&big);
    try core.write("\x07hello");
    try std.testing.expectEqual(@as(usize, 0), core.link_store.items.len);
    try std.testing.expectEqual(@as(u21, 'h'), core.cells[0].codepoint);
    // 휴리스틱은 여전히 동작.
    try core.write("\r\nhttps://x.yz ");
    try std.testing.expect(core.wordIsUrl(1, 3));
}

test "preedit composition shows the in-progress hangul at the cursor without touching the grid" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("$ ");

    try core.setPreedit("안"); // 조합 중(wide)
    const snap = core.renderSnapshot();
    // 커서 위치(0,2)에 '안'이 반전으로 합성되고, 커서는 그 뒤(0,4)로 보인다.
    try std.testing.expectEqual(@as(u21, 0xC548), snap.cells[2].codepoint);
    try std.testing.expect(snap.cells[2].style.reverse);
    try std.testing.expectEqual(@as(u2, 2), snap.cells[2].width);
    try std.testing.expect(snap.cells[3].continuation);
    try std.testing.expect(!snap.cursor.visible); // 조합 중 블록 커서 숨김(반전 preedit이 커서 역할)
    // 실제 그리드는 오염되지 않는다.
    try std.testing.expectEqual(@as(u21, ' '), core.cells[2].codepoint);

    // 조합 갱신('않' 등 다른 글자로 교체)도 같은 자리에.
    try core.setPreedit("않");
    const snap2 = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 0xC54A), snap2.cells[2].codepoint);

    // 조합 종료 — 합성이 사라지고 일반 snapshot으로 돌아간다.
    try core.setPreedit("");
    const snap3 = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, ' '), snap3.cells[2].codepoint);
    try std.testing.expectEqual(@as(u16, 2), snap3.cursor.col);
}

test "preedit clips at the row end instead of wrapping" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abc"); // 커서 (0,3) — 한 칸 남음
    try core.setPreedit("한"); // wide(2칸)는 안 들어간다 — 잘림
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'c'), snap.cells[2].codepoint);
    try std.testing.expect(!snap.cursor.visible);
}

test "preedit inserts mid-line, shifting trailing glyphs (가나다 + 나앞 조합 → 가[라]나다)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4"); // "가나다": 가=0,나=2,다=4 (각 wide)
    try core.write("\x1b[4D"); // 커서를 '나' base(col2)로 — 왼쪽 4칸 이동(글자는 그대로)
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);

    try core.setPreedit("\xeb\x9d\xbc"); // "라"(wide) 조합 중
    const snap = core.renderSnapshot();
    // 삽입형: '나'/'다'가 오른쪽으로 밀리고 그 자리에 '라'가 들어가 "가[라]나다"로 보인다.
    try std.testing.expectEqual(@as(u21, 0xAC00), snap.cells[0].codepoint); // 가(그대로)
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[2].codepoint); // 라(조합, 반전)
    try std.testing.expect(snap.cells[2].style.reverse);
    try std.testing.expectEqual(@as(u2, 2), snap.cells[2].width);
    try std.testing.expect(snap.cells[3].continuation);
    try std.testing.expectEqual(@as(u21, 0xB098), snap.cells[4].codepoint); // 나(2칸 밀림)
    try std.testing.expectEqual(@as(u21, 0xB2E4), snap.cells[6].codepoint); // 다(2칸 밀림)
    try std.testing.expect(!snap.cursor.visible);
    try std.testing.expectEqual(@as(u16, 4), snap.cursor.col); // 커서는 조합 끝
    // 실제 그리드는 불변 — 확정 전까지 셸 상태는 "가나다" 그대로다.
    try std.testing.expectEqual(@as(u21, 0xB098), core.cells[2].codepoint); // grid의 '나'는 col2
    try std.testing.expectEqual(@as(u21, 0xB2E4), core.cells[4].codepoint); // grid의 '다'는 col4
}

test "preedit falls back to overlay when shifting would clip trailing content" {
    // cols=7: "가나다"가 col0~5를 채우고 col6만 빈다. 조합 폭 2칸을 밀 자리가 없어('다'가
    // 행 밖으로 잘림) 삽입형 대신 오버레이로 폴백한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 7, .rows = 2 });
    defer core.deinit();
    try core.write("\xea\xb0\x80\xeb\x82\x98\xeb\x8b\xa4"); // "가나다"
    try core.write("\x1b[4D"); // 커서를 '나' base(col2)로
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);

    try core.setPreedit("\xeb\x9d\xbc"); // "라"(wide) — 밀면 '다'가 행 밖으로 잘린다
    const snap = core.renderSnapshot();
    // 폴백(오버레이): '나' 자리에 '라'가 덮이고 '다'는 제자리(col4)에 남는다("가[라]다").
    try std.testing.expectEqual(@as(u21, 0xB77C), snap.cells[2].codepoint); // 라(덮어씀)
    try std.testing.expect(snap.cells[2].style.reverse);
    try std.testing.expectEqual(@as(u21, 0xB2E4), snap.cells[4].codepoint); // 다(안 밀림)
    try std.testing.expect(!snap.cursor.visible);
}

test "zsh wide-glyph erase sequence (BS BS SP SP BS BS) cleans the hangul cell pair" {
    // 실제 zsh 캡처: "ls 안"에서 Backspace 1회에 zsh가 보내는 시퀀스는 "\x08\x08  \x08\x08".
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("ls \xec\x95\x88"); // "ls 안" — 안은 col3(wide)+col4(continuation)
    try std.testing.expectEqual(@as(u2, 2), core.cells[3].width);
    try core.write("\x08\x08  \x08\x08");
    // 한글이 지워지고 "ls "만 남는다 — continuation 잔재 없이.
    try std.testing.expectEqual(@as(u21, ' '), core.cells[3].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), core.cells[4].codepoint);
    try std.testing.expect(!core.cells[4].continuation);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
}

test "OSC 8 pen_link resets on alt-screen switch and RIS (no stale clickable cells)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    // 링크를 열고 닫지 않은 채(악성/부분 출력) 글자 출력 — 그 글자엔 링크가 찍힌다.
    try core.write("\x1b]8;;https://x.yz\x1b\\ab");
    try std.testing.expect(core.cells[0].link != 0);

    // alt 진입: pen_link이 리셋돼 alt에서 출력한 글자엔 링크가 안 찍힌다.
    try core.write("\x1b[?1049h");
    try core.write("Z");
    try std.testing.expectEqual(@as(u32, 0), core.cells[0].link); // alt 화면 cell
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);

    // primary 복귀도 pen_link 0.
    try core.write("\x1b[?1049l");
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);

    // 다시 링크 열고 RIS(ESC c) — 저장소가 비고 화면/스크롤백/링크가 초기화된다.
    try core.write("\x1b]8;;https://a.bc\x1b\\q\r\nr");
    try std.testing.expect(core.link_store.items.len >= 1);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(usize, 0), core.link_store.items.len);
    try std.testing.expectEqual(@as(u32, 0), core.pen_link);
    try std.testing.expectEqual(@as(u21, ' '), core.cells[0].codepoint); // 화면 비움
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 스크롤백 비움
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
}

test "emoji grapheme: skin tone modifier and flag (RI pair) cluster into one wide cell" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();

    // 스킨톤 modifier(🏽 U+1F3FD)는 EAW Wide(2)라 별도 셀로 둔다 — zsh의 ZLE 너비(👍2+🏽2=4)와
    // 일치시켜 붙여넣기 redraw가 안 깨지게(너비 합의). 👍는 col0-1, 🏽는 col2-3.
    try core.write("\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try std.testing.expectEqual(@as(u21, 0x1F44D), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, null), core.cells[0].combining); // 클러스터 안 함
    try std.testing.expectEqual(@as(u2, 2), core.cells[0].width);
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.cells[2].codepoint); // 스킨톤은 별도 셀
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col); // 4칸(zsh와 일치)

    // 국기 RI(🇰🇷 = U+1F1F0 U+1F1F7)는 zsh와 같이 낱자(각 width 1)로 둔다 — 클러스터하면
    // 우리는 width-2 한 셀, zsh는 width-1 둘이라 구조가 달라 붙여넣기 redraw가 깨졌다.
    try core.write("\r\n\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7");
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.cells[10].codepoint);
    try std.testing.expectEqual(@as(u2, 1), core.cells[10].width); // RI = width 1(EAW Neutral)
    try std.testing.expectEqual(@as(u21, 0x1F1F7), core.cells[11].codepoint); // 둘째 RI 별도 셀
    try std.testing.expectEqual(@as(?u21, null), core.cells[10].combining);
}

test "mode 2027: VS16 promotes to width 2 only when grapheme cluster mode is on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 기본(2027 off): ❤+VS16 = width 1(EAW, zsh 일치).
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤️
    try std.testing.expectEqual(@as(u2, 1), core.cells[0].width);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);

    // 2027 on: 풀사이즈 width 2.
    try core.write("\r\n\x1b[?2027h\xe2\x9d\xa4\xef\xb8\x8f");
    try std.testing.expect(core.grapheme_cluster_mode);
    try std.testing.expectEqual(@as(u21, 0x2764), core.cells[10].codepoint);
    try std.testing.expectEqual(@as(?u21, 0xFE0F), core.cells[10].combining);
    try std.testing.expectEqual(@as(u2, 2), core.cells[10].width);
    try std.testing.expect(core.cells[11].continuation);
}

test "mode 2027: skin tone and flags cluster only when on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 스킨톤: 👍🏽 한 셀 width 2.
    try core.write("\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try std.testing.expectEqual(@as(u21, 0x1F44D), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0x1F3FD), core.cells[0].combining);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
    // 국기: 🇰🇷 한 셀 width 2.
    try core.write("\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7");
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.cells[2].codepoint);
    try std.testing.expectEqual(@as(?u21, 0x1F1F7), core.cells[2].combining);
    try std.testing.expectEqual(@as(u2, 2), core.cells[2].width);

    // 2027 off면 스킨톤은 별도 셀(EAW Wide).
    try core.write("\x1b[?2027l\r\n\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd");
    try std.testing.expectEqual(@as(?u21, null), core.cells[12].combining);
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.cells[14].codepoint); // 별도 셀
}

test "DECRQM reports mode 2027 state so apps can detect support" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 미설정: reset이지만 인식함(2) — 앱이 지원을 감지하고 켤 수 있다.
    try core.write("\x1b[?2027$p");
    try std.testing.expectEqualStrings("\x1b[?2027;2$y", core.pendingResponse());
    core.clearResponse();
    // 켠 뒤: set(1).
    try core.write("\x1b[?2027h\x1b[?2027$p");
    try std.testing.expectEqualStrings("\x1b[?2027;1$y", core.pendingResponse());
    core.clearResponse();
    // 모르는 모드: 미인식(0).
    try core.write("\x1b[?9999$p");
    try std.testing.expectEqualStrings("\x1b[?9999;0$y", core.pendingResponse());
}

test "synchronized output (DECSET 2026): set/reset + DECRQM 지원 감지" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(!core.sync_output); // 기본 off
    try core.write("\x1b[?2026h"); // BSU
    try std.testing.expect(core.sync_output);
    try core.write("\x1b[?2026l"); // ESU
    try std.testing.expect(!core.sync_output);
    // DECRQM: 미설정=reset(2, 인식 — 앱이 지원 감지), 켜면 set(1).
    try core.write("\x1b[?2026$p");
    try std.testing.expectEqualStrings("\x1b[?2026;2$y", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[?2026h\x1b[?2026$p");
    try std.testing.expectEqualStrings("\x1b[?2026;1$y", core.pendingResponse());
}

test "kitty FlagStack: push/pop/set/overflow (audit 4/5)" {
    var stack: KittyFlagStack = .{};
    try std.testing.expectEqual(KittyFlags{}, stack.current()); // 기본 disabled

    stack.push(.{ .disambiguate = true }); // CSI > 1 u
    try std.testing.expectEqual(KittyFlags{ .disambiguate = true }, stack.current());
    stack.push(.{ .report_events = true }); // 새 레벨 push
    try std.testing.expectEqual(KittyFlags{ .report_events = true }, stack.current());
    stack.pop(1); // CSI < 1 u → 이전 레벨 복원
    try std.testing.expectEqual(KittyFlags{ .disambiguate = true }, stack.current());

    stack.set(.@"or", .{ .report_events = true }); // CSI = ; 2 u 합집합
    try std.testing.expect(stack.current().disambiguate and stack.current().report_events);
    stack.set(.not, .{ .report_events = true }); // CSI = ; 3 u 차집합
    try std.testing.expect(stack.current().disambiguate and !stack.current().report_events);
    stack.set(.set, .{ .report_all = true }); // CSI = ; 1 u 치환
    try std.testing.expectEqual(KittyFlags{ .report_all = true }, stack.current());

    stack.pop(100); // 과도한 pop = 전체 리셋(DoS 회피)
    try std.testing.expectEqual(KittyFlags{}, stack.current());
}

test "kitty Flags: packed bit order matches kitty spec (LSB=disambiguate)" {
    try std.testing.expectEqual(@as(u5, 0b00001), (KittyFlags{ .disambiguate = true }).int());
    try std.testing.expectEqual(@as(u5, 0b00010), (KittyFlags{ .report_events = true }).int());
    try std.testing.expectEqual(@as(u5, 0b00100), (KittyFlags{ .report_alternates = true }).int());
    try std.testing.expectEqual(@as(u5, 0b01000), (KittyFlags{ .report_all = true }).int());
    try std.testing.expectEqual(@as(u5, 0b10000), (KittyFlags{ .report_associated = true }).int());
}

test "kitty keyboard CSI u dispatch: push(>)/set(=)/query(?)/pop(<)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current()); // 기본 disabled

    try core.write("\x1b[>1u"); // push disambiguate
    try std.testing.expect(core.kitty_flags.current().disambiguate);
    try core.write("\x1b[?u"); // query → CSI ? 1 u
    try std.testing.expectEqualStrings("\x1b[?1u", core.pendingResponse());
    core.clearResponse();

    // 미구현 flag는 마스킹된다(거짓 광고 방지): =2;2u(or report_events)는 report_events를 안 켜고
    // disambiguate만 유지한다 — Maru는 disambiguate 수준만 인코딩하기 때문.
    try core.write("\x1b[=2;2u");
    try std.testing.expect(core.kitty_flags.current().disambiguate);
    try std.testing.expect(!core.kitty_flags.current().report_events);

    try core.write("\x1b[<1u"); // pop → 이전 레벨(disabled)
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current());
    // RIS는 스택을 비활성으로 리셋한다.
    try core.write("\x1b[>9u\x1bc");
    try std.testing.expectEqual(KittyFlags{}, core.kitty_flags.current());
}

test "kitty keyboard query는 미구현 flag를 활성으로 거짓 보고하지 않는다 (audit HIGH)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    // 앱이 report_events(>2u)만 켜려 하면 — Maru는 미구현이라 스택에 저장하지 않고, query는 0(비활성)을
    // 보고한다. 예전엔 2를 그대로 저장·보고해 "report_events 활성"이라 거짓 광고했다(인코딩은 disambiguate만).
    try core.write("\x1b[>2u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?0u", core.pendingResponse());
    core.clearResponse();
    // disambiguate는 지원하므로 보고된다 — 9(=disambiguate 1 + report_all 8)를 켜도 미구현 비트는 떨구고 1만.
    try core.write("\x1b[>9u\x1b[?u");
    try std.testing.expectEqualStrings("\x1b[?1u", core.pendingResponse());
}

test "APC (ESC _ ... ESC \\): kitty graphics payload가 화면에 텍스트로 새지 않는다 (graphics 토대)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    // kitty graphics APC — control+payload가 셀에 안 찍히고 소비된다(과거 ESC_ 미처리면 누수).
    try core.write("\x1b_Ga=T,f=32;AAAA\x1b\\");
    try std.testing.expectEqual(@as(u21, ' '), core.cells[0].codepoint); // 텍스트 누수 없음
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col); // 커서 안 움직임
    // APC 종료(ESC \) 후 일반 텍스트는 정상 — ground 복귀 확인.
    try core.write("hi");
    try std.testing.expectEqual(@as(u21, 'h'), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), core.cells[1].codepoint);
}

test "kitty graphics command 파싱: control k=v 주요 key (audit 5/5b)" {
    // a=T(transmit+display), f=32(RGBA), s/v 픽셀 크기, i image id, m=1 chunked, o=z compression.
    const cmd = TerminalCore.parseKittyGraphicsCommand("a=T,f=32,s=100,v=50,i=3,m=1,o=z");
    try std.testing.expectEqual(@as(u8, 'T'), cmd.action);
    try std.testing.expectEqual(@as(u16, 32), cmd.format);
    try std.testing.expectEqual(@as(u32, 100), cmd.width);
    try std.testing.expectEqual(@as(u32, 50), cmd.height);
    try std.testing.expectEqual(@as(u32, 3), cmd.image_id);
    try std.testing.expect(cmd.more);
    try std.testing.expectEqual(@as(u8, 'z'), cmd.compression);
}

test "kitty graphics command 파싱: 기본값 + payload(';' 다음)는 control에서 제외" {
    const q = TerminalCore.parseKittyGraphicsCommand("a=q;AAAAdata");
    try std.testing.expectEqual(@as(u8, 'q'), q.action); // query
    try std.testing.expectEqual(@as(u16, 32), q.format); // 기본 RGBA — payload는 파싱 안 함
    const empty = TerminalCore.parseKittyGraphicsCommand("");
    try std.testing.expectEqual(@as(u8, 't'), empty.action); // 기본 transmit(견고성)
}

test "kitty graphics transmit: RGBA 저장 + 같은 id 교체 + delete (audit 5/5-1단계)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // 2x2 RGBA = 16바이트(0xAB)를 base64로 인코딩해 transmit(a=t, f=32, s=2, v=2, i=7).
    const raw = [_]u8{0xAB} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    try std.testing.expect(core.kitty_images.map.contains(7));
    const img = core.kitty_images.map.get(7).?;
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqual(@as(u8, 4), img.bpp);
    try std.testing.expectEqual(@as(usize, 16), img.data.len);
    try std.testing.expectEqual(@as(u8, 0xAB), img.data[0]); // base64 디코드 정확
    try std.testing.expectEqual(@as(usize, 16), core.kitty_images.total_bytes);

    // 같은 id(7)로 다시 transmit → 교체(total_bytes 누적 안 됨).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 16), core.kitty_images.total_bytes);

    // delete(a=d, d=I, i=7) → 이미지 데이터까지 제거(대문자 I). d 기본값은 'a'(전체)라 image_id 지정 삭제는 d=I.
    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

test "kitty graphics transmit: 크기 불일치·PNG·zlib는 저장 안 함, RIS는 비운다" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    var seq: [80]u8 = undefined;

    // 크기 불일치(s=2,v=2,f=32 → 16바이트 기대인데 4바이트만) → 거부.
    const small = [_]u8{1} ** 4;
    var sb: [16]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&sb, &small)}));
    try std.testing.expect(!core.kitty_images.map.contains(1));
    // 과대 치수(s/v=u32max)는 곱이 usize를 넘어 — panic 없이 거부한다(code review 발견).
    try core.write("\x1b_Ga=t,f=32,s=4294967295,v=4294967295,i=8;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(8));
    // PNG(f=100)·zlib(o=z)은 후속이라 저장 안 함.
    try core.write("\x1b_Ga=t,f=100,s=2,v=2,i=2;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(2));
    try core.write("\x1b_Ga=t,f=32,s=2,v=2,i=3,o=z;AAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(3));

    // 정상 저장 후 RIS(ESC c)는 전부 비운다.
    const raw = [_]u8{2} ** 16;
    var b64: [32]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=9;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, &raw)}));
    try std.testing.expect(core.kitty_images.map.contains(9));
    try core.write("\x1bc");
    try std.testing.expect(!core.kitty_images.map.contains(9));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

// --- kitty graphics K1: placement(코어) — 저장/노출/생애주기 ---

test "kitty graphics display(a=p): 커서 셀에 placement 생성 + 모든 display 키 파싱 + 뷰포트 매핑 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // 2x2 RGBA 이미지(i=7) 전송(표시 안 함) — transmit만으론 placement가 안 생긴다.
    const raw = [_]u8{0xCD} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);

    // 커서를 (행1,열2)로 옮기고(CUP 2;3) display(a=p)로 표시 — 모든 display 키를 함께 검증.
    try core.write("\x1b[2;3H");
    try core.write("\x1b_Ga=p,i=7,p=5,c=3,r=2,z=-1,X=4,Y=6,x=1,y=2,w=8,h=9,C=1\x1b\\");

    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    const p = core.kitty_placements.items[0];
    try std.testing.expectEqual(@as(u32, 7), p.image_id);
    try std.testing.expectEqual(@as(u32, 5), p.placement_id);
    try std.testing.expectEqual(@as(usize, 1), p.anchor_row); // sb_count(0)+cursor.row(1)
    try std.testing.expectEqual(@as(u16, 2), p.anchor_col);
    try std.testing.expectEqual(@as(u32, 3), p.columns);
    try std.testing.expectEqual(@as(u32, 2), p.rows);
    try std.testing.expectEqual(@as(i32, -1), p.z);
    try std.testing.expectEqual(@as(u32, 4), p.cell_x_offset);
    try std.testing.expectEqual(@as(u32, 6), p.cell_y_offset);
    try std.testing.expectEqual(@as(u32, 1), p.src_x);
    try std.testing.expectEqual(@as(u32, 2), p.src_y);
    try std.testing.expectEqual(@as(u32, 8), p.src_width);
    try std.testing.expectEqual(@as(u32, 9), p.src_height);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row); // C=1 → 커서 안 움직임

    // renderSnapshot(바닥)은 뷰포트 상대 placement를 노출(top_abs=sb_count=0 → row=anchor=1).
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.placements.len);
    try std.testing.expectEqual(@as(i32, 1), snap.placements[0].row);
    try std.testing.expectEqual(@as(u16, 2), snap.placements[0].col);
    try std.testing.expectEqual(@as(u32, 7), snap.placements[0].image_id);
    try std.testing.expectEqual(@as(i32, -1), snap.placements[0].z);
}

test "kitty graphics display(a=T): transmit+display 한 command로 이미지+placement (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x10} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=4,c=2,r=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_images.map.contains(4)); // 저장
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len); // 표시
    try std.testing.expectEqual(@as(u32, 4), core.kitty_placements.items[0].image_id);
}

test "kitty graphics display: 없는 이미지/ i=0은 placement를 만들지 않는다 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b_Ga=p,i=99\x1b\\"); // 전송된 적 없는 이미지
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try core.write("\x1b_Ga=p\x1b\\"); // i 없음(0)
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: (image_id,placement_id) 같으면 교체, 다르면 별개 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x22} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    try core.write("\x1b_Ga=p,i=7,p=1,z=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=1,z=2\x1b\\"); // 같은 키 → 교체
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(i32, 2), core.kitty_placements.items[0].z); // 갱신

    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\"); // 다른 placement_id → 별개
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);
}

test "kitty graphics display: 커서 이동 정책(C, r) (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 6 });
    defer core.deinit();
    const raw = [_]u8{0x33} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));

    // 기본(C 없음) + r=2 → 커서가 r만큼 아래로(행0 → 행2).
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1,r=2\x1b\\");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    // r 미지정 + 셀 메트릭 미주입(이 테스트는 setCellMetrics를 안 부른다) → 환산 불가로 이동 안 함(K1 fallback).
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1\x1b\\");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    // C=1 → r이 있어도 이동 안 함.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=1,r=3,C=1\x1b\\");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    // 화면 끝을 넘기는 이동은 스크롤 없이 마지막 행(rows-1=5)으로 clamp.
    try core.write("\x1b[5;1H\x1b_Ga=p,i=1,r=10\x1b\\"); // 행4 +10 → clamp 5
    try std.testing.expectEqual(@as(u16, 5), core.cursor.row);
}

test "kitty graphics delete: 이미지와 그 placement를 함께 제거 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x44} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7,p=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);

    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\"); // 대문자 I = 이미지 7 + 그 모든 placement 제거
    try std.testing.expect(!core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: RIS는 placement를 비운다 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x55} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: 스크롤백 eviction에 따라 anchor 보정·제거 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 2; // 작은 스크롤백으로 eviction을 빨리 유발
    const raw = [_]u8{0x66} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    // 활성 행0에 표시 → anchor 절대 행 0.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=7,p=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items[0].anchor_row);

    // 개행 3번 → 스크롤백이 가득(sb_count=2)차지만 eviction 전이라 anchor(절대 0) 유지.
    try core.write("\n\n\n");
    try std.testing.expectEqual(@as(usize, 2), core.sb_count);
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items[0].anchor_row);

    // 한 번 더 → 가장 오래된 행 eviction → 화면 밖이 된 anchor 0 placement 제거.
    try core.write("\n");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
}

test "kitty graphics placement: 위로 스크롤하면 뷰포트 상대 row로 환산 (K1)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    const raw = [_]u8{0x77} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    // 행0에 표시(anchor abs 0). 개행으로 스크롤백 2줄 쌓아 placement가 활성 화면 위로 올라가게.
    try core.write("\x1b[1;1H\x1b_Ga=p,i=7\x1b\\");
    try core.write("\n\n\n"); // sb_count=2, anchor 0 유지(default max_scrollback이라 eviction 없음)
    try std.testing.expectEqual(@as(usize, 2), core.sb_count);

    // 바닥에서는 anchor abs0가 top_abs(=sb_count=2) 위라 row=-2(화면 밖, 렌더러가 클립).
    try std.testing.expectEqual(@as(i32, -2), core.renderSnapshot().placements[0].row);

    // 맨 위까지 스크롤(view_offset=2) → top_abs=0 → row=0(보임).
    core.scrollViewport(2);
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.placements.len);
    try std.testing.expectEqual(@as(i32, 0), snap.placements[0].row);
    try std.testing.expectEqual(@as(u16, 0), snap.placements[0].col);
}

// --- kitty graphics K2a: 이미지 픽셀 노출 + upload generation(코어) ---

test "kitty graphics images: transmit이 RenderSnapshot.images로 픽셀·치수·generation 노출 (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0x9A} ** 16; // 2x2 RGBA
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    const snap = core.renderSnapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.images.len);
    const v = snap.images[0];
    try std.testing.expectEqual(@as(u32, 7), v.image_id);
    try std.testing.expectEqual(@as(u32, 2), v.width);
    try std.testing.expectEqual(@as(u32, 2), v.height);
    try std.testing.expectEqual(@as(u8, 4), v.bpp);
    try std.testing.expectEqual(@as(usize, 16), v.pixels.len);
    try std.testing.expectEqual(@as(u8, 0x9A), v.pixels[0]); // zero-copy로 storage 픽셀
    try std.testing.expect(v.generation > 0);
}

test "kitty graphics images: 같은 id 재transmit은 generation을 올린다(렌더러 재업로드 신호) (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    const gen1 = core.renderSnapshot().images[0].generation;
    // 같은 id로 다시 transmit → generation 증가(같은 id 교체여도 새 값).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    const gen2 = core.renderSnapshot().images[0].generation;
    try std.testing.expect(gen2 > gen1);
}

test "kitty graphics images: 여러 이미지 노출 + delete/RIS 반영, generation은 RIS에도 단조 (K2a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{2} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try std.testing.expectEqual(@as(usize, 2), core.renderSnapshot().images.len);

    // 가장 큰 generation 기록(RIS가 카운터를 리셋하지 않는지 확인용).
    var max_gen: u64 = 0;
    for (core.renderSnapshot().images) |v| max_gen = @max(max_gen, v.generation);

    // delete(d=I, i=1) → 이미지 1만 free, 하나(2) 남는다.
    try core.write("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.renderSnapshot().images.len);
    // RIS → 전부 비운다.
    try core.write("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), core.renderSnapshot().images.len);

    // RIS 후 재transmit은 이전 max보다 큰 generation을 받는다(카운터 비리셋 — stale 재사용 방지).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.renderSnapshot().images[0].generation > max_gen);
}

// --- kitty graphics K3a: chunked 전송(m=1) ---

test "kitty graphics chunked(m=1): 여러 APC로 쪼갠 전송을 누적해 한 이미지로 저장 (K3a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 12바이트 RGB(f=24, 2x2). base64 16자(4의 배수·패딩 없음)를 8+8로 쪼갠다.
    const raw = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var b64: [16]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    try std.testing.expectEqual(@as(usize, 16), b64s.len);
    var seq: [64]u8 = undefined;
    // 첫 청크: control + 앞 8자, m=1 → 아직 미완성이라 저장 안 됨.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=5,m=1;{s}\x1b\\", .{b64s[0..8]}));
    try std.testing.expect(!core.kitty_images.map.contains(5));
    // 마지막 청크: 뒤 8자, m=0 → 누적분을 한 번에 디코드해 저장.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=0;{s}\x1b\\", .{b64s[8..16]}));
    try std.testing.expect(core.kitty_images.map.contains(5));
    const img = core.kitty_images.map.get(5).?;
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u8, 3), img.bpp);
    try std.testing.expectEqual(@as(usize, 12), img.data.len);
    try std.testing.expectEqual(@as(u8, 1), img.data[0]);
    try std.testing.expectEqual(@as(u8, 12), img.data[11]);
    try std.testing.expect(core.kitty_chunk_cmd == null); // 완료 후 chunking 비활성
}

test "kitty graphics chunked: 3청크 완성 + RIS가 진행 중 전송을 폐기 (K3a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{0xAA} ** 12;
    var b64: [16]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [64]u8 = undefined;
    // 3청크(4+4+8, 각 4의 배수): m=1, m=1, m=0.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=9,m=1;{s}\x1b\\", .{b64s[0..4]}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=1;{s}\x1b\\", .{b64s[4..8]}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Gm=0;{s}\x1b\\", .{b64s[8..16]}));
    try std.testing.expect(core.kitty_images.map.contains(9));
    try std.testing.expectEqual(@as(usize, 12), core.kitty_images.map.get(9).?.data.len);

    // 진행 중(m=1) 상태에서 RIS → 폐기되어 저장 안 됨.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=24,s=2,v=2,i=10,m=1;{s}\x1b\\", .{b64s[0..8]}));
    try std.testing.expect(core.kitty_chunk_cmd != null); // chunking 진행 중
    try core.write("\x1bc"); // RIS
    try std.testing.expect(!core.kitty_images.map.contains(10));
    try std.testing.expect(core.kitty_chunk_cmd == null); // 폐기됨
}

// --- kitty graphics K3b: zlib 압축(o=z) ---

test "kitty graphics zlib(o=z): 압축 픽셀 inflate 저장 + 크기 불일치/깨진 zlib 거부 (K3b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 2x2 RGB(12바이트 [1..12])를 zlib 압축한 base64(python zlib.compress).
    try core.write("\x1b_Ga=t,f=24,s=2,v=2,i=5,o=z;eJxjZGJmYWVj5+Dk4uYBAAF4AE8=\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(5));
    const img = core.kitty_images.map.get(5).?;
    try std.testing.expectEqual(@as(usize, 12), img.data.len);
    try std.testing.expectEqual(@as(u8, 3), img.bpp);
    try std.testing.expectEqual(@as(u8, 1), img.data[0]);
    try std.testing.expectEqual(@as(u8, 12), img.data[11]); // inflate 정확

    // 같은 압축인데 선언 치수가 틀리면(s=3,v=3 → expected 36 ≠ inflate 12) 거부.
    try core.write("\x1b_Ga=t,f=24,s=3,v=3,i=6,o=z;eJxjZGJmYWVj5+Dk4uYBAAF4AE8=\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(6));
    // 깨진 zlib(헤더 0x78 아님)도 graceful 거부(panic 없음).
    try core.write("\x1b_Ga=t,f=24,s=2,v=2,i=7,o=z;AAAAAAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
}

test "kitty graphics zlib: 큰 이미지(back-reference 포함) inflate (K3b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // 8x8 RGBA(256바이트) zlib 압축 — LZ77 back-reference가 든 스트림(작은 것만으론 검증 부족).
    try core.write("\x1b_Ga=t,f=32,s=8,v=8,i=8,o=z;eJwBAAH//gAHDhUcIyoxOD9GTVRbYmlwd36FjJOaoaivtr3Ey9LZ4Ofu9fwDChEYHyYtNDtCSVBXXmVsc3qBiI+WnaSrsrnAx87V3OPq8fj/Bg0UGyIpMDc+RUxTWmFob3Z9hIuSmaCnrrW8w8rR2N/m7fT7AgkQFx4lLDM6QUhPVl1ka3J5gIeOlZyjqrG4v8bN1Nvi6fD3/gUMExohKC82PURLUllgZ251fIOKkZifpq20u8LJ0Nfe5ezz+gEIDxYdJCsyOUBHTlVcY2pxeH+GjZSboqmwt77FzNPa4ejv9v0ECxIZICcuNTxDSlFYX2ZtdHuCiZCXnqWss7rByM/W3eTr8vkKE3+B\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(8));
    const img = core.kitty_images.map.get(8).?;
    try std.testing.expectEqual(@as(usize, 256), img.data.len);
    try std.testing.expectEqual(@as(u8, 0), img.data[0]);
    try std.testing.expectEqual(@as(u8, 249), img.data[255]); // 마지막 바이트까지 정확
}

// --- kitty graphics K3c: PNG 디코드(f=100, 8-bit truecolor) ---

test "kitty graphics PNG(f=100): RGBA/RGB 디코드 저장(s/v 없이) (K3c)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 2x2 RGBA PNG(PIL 생성). f=100, s/v 없음 — PNG가 치수를 자기기술.
    try core.write("\x1b_Ga=t,f=100,i=1;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nGP4z8Dwn+E/QwMTI5hmOAAAOrcGP3V8arYAAAAASUVORK5CYII=\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(1));
    const a = core.kitty_images.map.get(1).?;
    try std.testing.expectEqual(@as(u32, 2), a.width);
    try std.testing.expectEqual(@as(u32, 2), a.height);
    try std.testing.expectEqual(@as(u8, 4), a.bpp);
    try std.testing.expectEqual(@as(usize, 16), a.data.len);
    try std.testing.expectEqual(@as(u8, 255), a.data[0]); // 첫 픽셀 R
    try std.testing.expectEqual(@as(u8, 64), a.data[15]); // 마지막 픽셀 A

    // 3x2 RGB PNG(color type 2).
    try core.write("\x1b_Ga=t,f=100,i=2;iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAE0lEQVR4nGPkEpGDAJaoqCgICwAY2AK4OdDUoAAAAABJRU5ErkJggg==\x1b\\");
    const b = core.kitty_images.map.get(2).?;
    try std.testing.expectEqual(@as(u32, 3), b.width);
    try std.testing.expectEqual(@as(u8, 3), b.bpp);
    try std.testing.expectEqual(@as(usize, 18), b.data.len);
    try std.testing.expectEqual(@as(u8, 10), b.data[0]);
    try std.testing.expectEqual(@as(u8, 180), b.data[17]);
}

test "kitty graphics PNG: 필터 다양한 그라데이션 디코드 + 미지원/깨진 PNG graceful 거부 (K3c)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // 16x16 RGBA 그라데이션 — PIL 적응 필터(Sub/Up/Average/Paeth)를 거쳐 unfilter 전 경로를 실증.
    try core.write("\x1b_Ga=t,f=100,i=3;iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAXUlEQVR4nKXMRw6AMBAEwTEMOf7/syD5ALKcdteH6mM7AM8NwIq+cGb8B50Jw0GvxnhAFaYHgxjzg1GE5cFUxfpgLqJssGRRPliTqBtsEeoHe8A4OD4Ng9NrHFx4ARfXB/WGjsh8AAAAAElFTkSuQmCC\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(3));
    const g = core.kitty_images.map.get(3).?;
    try std.testing.expectEqual(@as(u32, 16), g.width);
    try std.testing.expectEqual(@as(u32, 16), g.height);
    try std.testing.expectEqual(@as(usize, 1024), g.data.len);
    try std.testing.expectEqual(@as(u8, 0), g.data[0]);
    try std.testing.expectEqual(@as(u8, 255), g.data[1023]); // 마지막 바이트까지 정확

    // grayscale(color type 0)은 미지원 변종 → graceful 거부(저장 안 됨, panic 없음).
    try core.write("\x1b_Ga=t,f=100,i=4;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGNgcGBo+A8AAwUBwE4zW+kAAAAASUVORK5CYII=\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(4));
    // 깨진 PNG(서명 틀림)도 graceful 거부.
    try core.write("\x1b_Ga=t,f=100,i=5;AAAAAAAAAAAA\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(5));
}

// --- kitty graphics K4a: 세분화된 delete(a=d, d= 타깃) ---

test "kitty graphics delete: d=a(전체 placement만)·d=A(이미지까지) (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), core.kitty_placements.items.len);

    // d 기본값 'a'(소문자) — placement만 전부 제거, 이미지는 남는다.
    try core.write("\x1b_Ga=d\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count()); // 이미지 유지

    // d=A(대문자) — placement + 이미지 데이터까지 전부 free.
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write("\x1b_Ga=d,d=A\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.map.count());
}

test "kitty graphics delete: d=i(placement만)·d=I(이미지까지)·placement_id 지정 (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7,p=1\x1b\\");
    try core.write("\x1b_Ga=p,i=7,p=2\x1b\\");

    // d=i,p=1 — 그 placement만 제거(이미지·다른 placement 유지).
    try core.write("\x1b_Ga=d,d=i,i=7,p=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expect(core.kitty_images.map.contains(7));
    try std.testing.expectEqual(@as(u32, 2), core.kitty_placements.items[0].placement_id);

    // d=i(소문자, p 없음) — image 7의 남은 placement 제거, 이미지는 유지.
    try core.write("\x1b_Ga=d,d=i,i=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expect(core.kitty_images.map.contains(7));

    // d=I(대문자) — 이미지 데이터까지 free.
    try core.write("\x1b_Ga=d,d=I,i=7\x1b\\");
    try std.testing.expect(!core.kitty_images.map.contains(7));
}

test "kitty graphics delete: d=z(z-index)·d=Z(이미지까지) (K4a)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1,p=1,z=5\x1b\\"); // z=5
    try core.write("\x1b_Ga=p,i=2,p=1,z=-1\x1b\\"); // z=-1

    // d=z,z=5(소문자) — z=5 placement만 제거, 이미지 유지.
    try core.write("\x1b_Ga=d,d=z,z=5\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), core.kitty_placements.items.len);
    try std.testing.expectEqual(@as(i32, -1), core.kitty_placements.items[0].z);
    try std.testing.expect(core.kitty_images.map.contains(1)); // 이미지 1 유지

    // d=Z,z=-1(대문자) — z=-1 placement + 그 이미지(2)까지 free.
    try core.write("\x1b_Ga=d,d=Z,z=-1\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), core.kitty_placements.items.len);
    try std.testing.expect(!core.kitty_images.map.contains(2));
}

// --- kitty graphics K4b: 한도 초과 시 LRU evict(placement 없는 것·오래된 것 우선) ---

test "kitty graphics evict: 한도 초과 시 오래된(generation 작은) 이미지부터 밀어낸다 (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32; // 16바이트 이미지 2장까지만
    const raw = [_]u8{1} ** 16; // 2x2 RGBA = 16바이트
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s})); // gen1
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s})); // gen2 (total=32)
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count());
    // 세 번째 → 한도 초과, 안 쓰이는 것 중 오래된 i=1 evict.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s})); // gen3
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 오래된 것 밀려남
    try std.testing.expect(core.kitty_images.map.contains(2));
    try std.testing.expect(core.kitty_images.map.contains(3));
    try std.testing.expectEqual(@as(usize, 32), core.kitty_images.total_bytes);
}

test "kitty graphics evict: placement 있는 이미지는 보호(안 쓰이는 것 먼저) (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32;
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s})); // gen1
    try core.write("\x1b_Ga=p,i=1\x1b\\"); // i=1에 placement(=used, 오래됐지만 보호)
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s})); // gen2 unused
    // 세 번째 → evict 필요. i=1(used·오래됨) 대신 i=2(unused·최신)를 밀어낸다(unused 우선).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s})); // gen3
    try std.testing.expect(core.kitty_images.map.contains(1)); // used라 보호
    try std.testing.expect(!core.kitty_images.map.contains(2)); // unused라 밀려남
    try std.testing.expect(core.kitty_images.map.contains(3));
}

test "kitty graphics evict: 한 장이 한도보다 크면 거부(저장 안 함) (K4b)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 10; // 16바이트 이미지보다 작음
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 한 장이 한도 초과 — 거부
    try std.testing.expectEqual(@as(usize, 0), core.kitty_images.total_bytes);
}

test "kitty graphics evict: 모두 화면 표시 중(used)이면 새 transmit을 거부하고 화면 이미지를 보존 (code review #9)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32; // 16바이트 2장
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1·i=2 둘 다 transmit + display(used) — 한도 꽉.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    // i=3 새 transmit → 한도 초과지만 i=1·i=2 모두 used라 evict 불가 → i=3 거부, 화면 이미지 보존.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s}));
    try std.testing.expect(!core.kitty_images.map.contains(3)); // 새 이미지 거부
    try std.testing.expect(core.kitty_images.map.contains(1)); // 화면 이미지 보존
    try std.testing.expect(core.kitty_images.map.contains(2));
    try std.testing.expect(core.kittyImageHasPlacement(1));
    try std.testing.expect(core.kittyImageHasPlacement(2));
}

test "kitty graphics: 재transmit이 한도로 거부되면 그 image_id placement를 orphan으로 남기지 않는다 (code review #8)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    core.kitty_images.limit = 32;
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1(used)·i=2(used) — 한도 꽉(32).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=1\x1b\\");
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=2\x1b\\");
    try std.testing.expect(core.kittyImageHasPlacement(1));
    // i=1을 더 큰(32B) 이미지로 재transmit: evict 불가(i=2 used 보호) → add가 old i=1 제거 후 거부.
    const raw_big = [_]u8{2} ** 32; // 4x2 RGBA = 32
    var b64b: [44]u8 = undefined;
    const b64bs = std.base64.standard.Encoder.encode(&b64b, &raw_big);
    var seq2: [120]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq2, "\x1b_Ga=t,f=32,s=4,v=2,i=1;{s}\x1b\\", .{b64bs}));
    try std.testing.expect(!core.kitty_images.map.contains(1)); // 재transmit 거부(old i=1 제거됨)
    try std.testing.expect(!core.kittyImageHasPlacement(1)); // placement도 정리 — orphan 없음
    try std.testing.expect(core.kitty_images.map.contains(2)); // i=2 보존
    try std.testing.expect(core.kittyImageHasPlacement(2));
}

test "kitty graphics: chunked 전송 중 독립 명령(delete)이 오면 chunk를 버리고 새 명령을 실행 (code review #3)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    const raw = [_]u8{1} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [80]u8 = undefined;
    // i=1 저장(delete 대상).
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_images.map.contains(1));
    // i=2 chunked transmit 시작(m=1) — 진행 중.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2,m=1;{s}\x1b\\", .{b64s}));
    try std.testing.expect(core.kitty_chunk_cmd != null); // chunk 진행 중
    // 진행 중에 독립 명령 a=d(delete) 도착 → chunk를 버리고 delete를 즉시 실행한다(transmit이 아니라서).
    try core.write("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expect(core.kitty_chunk_cmd == null); // 진행 중 chunk 폐기
    try std.testing.expect(!core.kitty_images.map.contains(1)); // delete가 실제로 실행됨
    try std.testing.expect(!core.kitty_images.map.contains(2)); // 버려진 chunked i=2는 저장 안 됨
}

test "kitty graphics: 단일 APC가 4096B를 넘는 큰 transmit도 받는다 (동적 버퍼, code review #4)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    // 40x40 RGBA = 6400B 픽셀 → base64 ~8534자, APC body가 옛 고정 4096 버퍼를 훌쩍 넘는다.
    const px: usize = 40 * 40 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 7);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=t,f=32,s=40,v=40,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq);
    // 과거엔 4096 초과 → apc_overflow로 silent drop. 이제 동적 버퍼라 정상 저장된다.
    try std.testing.expect(core.kitty_images.map.contains(1));
    try std.testing.expectEqual(@as(u32, 40), core.kitty_images.map.get(1).?.width);
}

test "kitty graphics: 자동 크기 이미지가 셀 메트릭으로 커서를 advance한다 (code review #2)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    core.setCellMetrics(8, 16); // 셀 8×16 px (platform 주입 모사)
    // 16×48 px RGBA 이미지: 높이 48 / 셀 16 = 정확히 3행. c/r 미지정(자동 크기)이라 코어가 메트릭으로 환산.
    const px: usize = 16 * 48 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 9);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=32,s=16,v=48,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq); // a=T: transmit + display(커서 위치에 placement + advance)
    try std.testing.expectEqual(@as(u16, 3), core.cursor.row); // 48px / 16px = 3행 내려감
}

test "kitty graphics: 셀 메트릭이 없으면 자동 크기는 커서를 안 옮긴다 (K1 fallback)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer core.deinit();
    // setCellMetrics 호출 안 함 → cell_height_px==0 (헤드리스). 자동 크기는 환산 불가라 미advance.
    const px: usize = 16 * 48 * 4;
    const raw = try std.testing.allocator.alloc(u8, px);
    defer std.testing.allocator.free(raw);
    @memset(raw, 9);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const seq = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=32,s=16,v=48,i=1;{s}\x1b\\", .{b64});
    defer std.testing.allocator.free(seq);
    try core.write(seq);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row); // 메트릭 없음 → 미이동(K1대로)
}

test "mode 2027: skin tone after a flag does not clobber the flag's combining (review #15)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 국기 🇰🇷 한 셀(combining = 2번째 RI). 이어서 스킨톤 modifier 🏽.
    try core.write("\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7\xf0\x9f\x8f\xbd");
    // 국기의 combining은 2번째 RI 그대로 — 스킨톤이 덮어쓰지 않는다.
    try std.testing.expectEqual(@as(u21, 0x1F1F0), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0x1F1F7), core.cells[0].combining); // 안 깨짐
    // 스킨톤은 국기에 못 붙으니 별도 셀(putCell, EAW Wide).
    try std.testing.expectEqual(@as(u21, 0x1F3FD), core.cells[2].codepoint);
}

test "mode 2027: emoji promotion at the last column wraps to next line as width 2 (review #9)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    try core.write("abcd"); // cols 0-3, 커서 col4(마지막)
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤(col4, width1) + VS16 -> 마지막 칸 승격 불가 -> wrap
    // 이전 줄 마지막 칸은 비워지고, ❤️가 다음 줄에 width 2로.
    try std.testing.expectEqual(@as(u21, ' '), core.cells[4].codepoint); // row0 col4 비움
    try std.testing.expect(core.wrapped[0]); // soft-wrap 표시
    try std.testing.expectEqual(@as(u21, 0x2764), core.cells[5].codepoint); // row1 col0
    try std.testing.expectEqual(@as(?u21, 0xFE0F), core.cells[5].combining);
    try std.testing.expectEqual(@as(u2, 2), core.cells[5].width);
    try std.testing.expect(core.cells[6].continuation);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "RIS restores alternate_scroll to factory default (review #14)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[?1007l"); // 프로그램이 alternate_scroll 끔
    try std.testing.expect(!core.alternate_scroll);
    try core.write("\x1bc"); // RIS
    try std.testing.expect(core.alternate_scroll); // 공장 기본(켜짐) 복원
}

// === 응답 적합성(conformance) — 호스트로 돌려보내는 report를 명세 기대값과 직접 비교한다.
// esctest(GPL)를 안 쓰는 대신 공개 명세에서 자체 도출한다. docs/conformance-testing.md 참조.

test "conformance: DA2 (CSI > c) answers secondary device attributes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // xterm ctlseqs Secondary DA. VT220급(1), 버전 10, ROM 0.
    try core.write("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", core.pendingResponse());
}

// XTVERSION(CSI > q, Ps=0): xterm ctlseqs "Report xterm name and version". 응답은 DCS 시퀀스
// `DCS > | <name version> ST`(= ESC P > | ... ESC \). 이건 런타임 자기식별의 백본이다 — DA1/DA2가
// 범용 VT102/VT220 신원만 주는 것과 달리, XTVERSION은 "이 단말은 maru다"를 이름으로 알린다. terminfo
// 파일이 원격에 없어도 capability를 런타임 질의로 감지하는 도구(tmux/nvim 등)가 maru를 식별할 수 있게
// 하는 가장 미래지향적 채널이며, terminfo·XTGETTCAP 작업이 공유할 단일 신원 출처(terminal_name/version)다.
test "conformance: XTVERSION (CSI > q) reports terminal name and version over DCS, no SGR leak" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[>q");
    // 정확한 wire 바이트를 고정한다("추측 말고 캡처"): ESC P > | maru 0.0.0 ESC \.
    try std.testing.expectEqualStrings("\x1bP>|maru 0.0.0\x1b\\", core.pendingResponse());
    core.clearResponse();
    // '>' 마커 시퀀스가 뒤따르는 SGR로 새지 않는다(DA2 격리 테스트와 같은 불변식).
    try core.write("\x1b[4m"); // underline on
    try core.write("X");
    try std.testing.expect(core.cells[0].style.underline);
}

test "XTVERSION (CSI > q) ignores non-zero Ps (only Ps=0 is defined)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // xterm ctlseqs는 Ps=0만 XTVERSION으로 정의한다. 그 외 Ps는 미정의라 침묵한다(안전 기본값).
    try core.write("\x1b[>1q");
    try std.testing.expectEqualStrings("", core.pendingResponse());
}

test "conformance: DECRQM reports known modes (bracketed paste 2004, DECTCEM 25)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // DEC STD 070 DECRQM/DECRPM: CSI ? Ps $ p -> CSI ? Ps ; Pm $ y. Pm 1=set, 2=reset.
    // bracketed paste(2004) 기본 reset.
    try core.write("\x1b[?2004$p");
    try std.testing.expectEqualStrings("\x1b[?2004;2$y", core.pendingResponse());
    core.clearResponse();
    // 켠 뒤 set.
    try core.write("\x1b[?2004h\x1b[?2004$p");
    try std.testing.expectEqualStrings("\x1b[?2004;1$y", core.pendingResponse());
    core.clearResponse();
    // DECTCEM(25) 기본 set(커서 표시).
    try core.write("\x1b[?25$p");
    try std.testing.expectEqualStrings("\x1b[?25;1$y", core.pendingResponse());
}

test "conformance: CPR reflects cursor position after CUP and reverts after a move" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    // ECMA-48 8.3.20 CUP(CSI row;col H) 1-indexed로 커서 이동, 8.3.14 CPR로 보고.
    try core.write("\x1b[3;7H\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;7R", core.pendingResponse());
    core.clearResponse();
    // CUF(CSI C) 2칸 -> col 9. 응답이 새 위치를 반영.
    try core.write("\x1b[2C\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[3;9R", core.pendingResponse());
}

test "mode 2027: emoji wrap at the last column on the scroll-bottom keeps the soft-wrap flag (re-check)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[?2027h");
    // 커서를 마지막 행(scroll_bottom=2)으로 내리고 그 행 마지막 칸까지 채운다.
    try core.write("\r\n\r\nabcd"); // row2에 abcd, 커서 col4(마지막)
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤+VS16 -> 마지막 칸 승격 불가 -> wrap + scroll
    // scroll로 한 줄 올라가고, '이전 줄'(이제 row1)이 이모지 줄(row2)로 soft-wrap돼야 한다 —
    // scrollRangeUp 경계 fixup이 지우지 않게 lineFeed 후에 세운다.
    try std.testing.expect(core.wrapped[1]); // 이전 줄 soft-wrap 유지(핵심)
    try std.testing.expectEqual(@as(u21, 0x2764), core.cells[core.index(2, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(2, 0)].width);
    try std.testing.expect(core.cells[core.index(2, 1)].continuation);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "backspace + overwrite renders word deletion (zsh meta-DEL response)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    try core.write("foo bar baz");
    // zsh가 meta-DEL(\e\x7f)에 보내는 응답: 왼쪽3 + 공백3 + 왼쪽3 = "baz" 삭제.
    try core.write("\x08\x08\x08   \x08\x08\x08");
    const line = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "foo bar    ")); // baz가 공백으로
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col); // "foo bar " 다음(baz 시작)
}

// ── OSC 133 semantic prompt ────────────────────────────────────────────────────────────────────

test "OSC 133: A/B/C tag the cursor row and update state (ST + BEL terminators)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // ST 종료
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.semantic_state);
    try core.write("\x1b]133;B\x07"); // BEL 종료 — 같은 행을 최신 마커로 덮어쓴다
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.input, core.semantic_state);
    try core.write("\x1b]133;C\x1b\\");
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[0].kind);
}

test "OSC 133: regions tag distinct rows via line-feed propagation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("\r\n"); // row1 ← prompt 전파
    try core.write("\x1b]133;B\x1b\\"); // row1 = input
    try core.write("\r\n"); // row2 ← input 전파
    try core.write("\x1b]133;C\x1b\\"); // row2 = command
    try core.write("\r\nout"); // row3 ← command 전파
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[1].kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[2].kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[3].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[4].kind); // 영역 밖
}

test "OSC 133: a multi-row prompt propagates prompt to every line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("\n\n"); // LF×2 → row1·row2 ← prompt 전파
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[1].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[2].kind);
    try core.write("\x1b]133;B\x1b\\"); // 현재 행(row2)만 input으로
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[2].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[1].kind); // 앞 행은 유지
}

test "OSC 133: autowrap continuation keeps the tag (glyph writes do NOT reset it)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\");
    try core.write("abcdef"); // abcd|ef soft-wrap: row0 채움 → 자동 wrap → row1
    try std.testing.expect(core.wrapped[0]); // soft-wrap 표시
    // 핵심: 글자 쓰기가 태그를 리셋하지 않는다(wrapped와 다른 점). 두 행 모두 prompt.
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[1].kind);
}

test "OSC 133: D decodes the exit code; bare/invalid leaves it unchanged" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(?i32, 0), core.last_command_exit);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state); // 영역 닫힘
    try core.write("\x1b]133;D;12;aid=foo\x07"); // 첫 토큰만 코드, 나머지 옵션 무시
    try std.testing.expectEqual(@as(?i32, 12), core.last_command_exit);
    try core.write("\x1b]133;D;-1\x07"); // 음수 허용
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
    try core.write("\x1b]133;D\x07"); // 코드 없음 → 이전 값 유지
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
    try core.write("\x1b]133;D;abc\x07"); // 정수 아님 → 유지
    try std.testing.expectEqual(@as(?i32, -1), core.last_command_exit);
}

test "OSC 133: D resets state so the next row is not tagged" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // state=command
    try core.write("\x1b]133;D;0\x07"); // state=unknown
    try core.write("\r\nx"); // 다음 행은 전파되지 않아야 한다
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[1].kind);
}

test "OSC 133: a tagged row scrolled off carries its tag into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("X"); // 글자(태그 유지)
    try core.write("\x1b]133;D;0\x07"); // state=unknown (이후 행은 태깅 안 됨)
    try core.write("\r\n\r\n"); // 두 번째 LF가 바닥에서 scroll → row0(prompt)이 스크롤백으로
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.scrollbackRowPrompt(0).kind);
}

test "OSC 133: RIS clears all tags, exit code, and state" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\X\x1b]133;D;5\x07");
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, 5), core.last_command_exit);
    try core.write("\x1bc"); // RIS
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, null), core.last_command_exit);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
}

test "OSC 133: erase-in-display mode 2 clears tags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\");
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try core.write("\x1b[2J");
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
}

test "OSC 133: alt screen is isolated; primary tags survive the round trip" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // primary row0 = prompt
    try core.write("\x1b[?1049h"); // alt 진입
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind); // alt는 비분류
    try core.write("\x1b]133;C\x1b\\"); // alt row0 = command
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[0].kind);
    try core.write("\x1b[?1049l"); // primary 복귀
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind); // primary 분류 복원
}

test "OSC 133: liberal option parsing ignores unknown keys" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A;aid=14;cl=line;k=i\x07"); // 모르는 옵션 무시, 여전히 prompt
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
    try core.write("\x1b]133;B;barekey\x07"); // 정수 아닌 옵션도 무해
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[0].kind);
}

test "OSC 133: malformed or unknown action is ignored" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;Pextra\x07"); // action 뒤 ';' 없는 잉여 내용 → invalid
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind);
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.semantic_state);
    try core.write("\x1b]133;Z\x07"); // 모르는 action → no-op
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind);
}

test "OSC 133: an overflowing sequence is ignored, later OSC still works" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    var big: [2100]u8 = undefined;
    @memset(&big, 'x');
    try core.write("\x1b]133;A;"); // OSC 시작
    try core.write(&big); // 2048 버퍼 초과 → osc_overflow
    try core.write("\x07"); // 종료 — overflow라 dispatch가 무시
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind); // 태깅 안 됨
    try core.write("\x1b]133;A\x07"); // 다음 OSC는 정상 동작(overflow 리셋)
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[0].kind);
}

test "OSC 133: snapshot exposes prompt_marks and last_command_exit (non-scrolled)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\X\x1b]133;D;3\x07");
    const snap = core.snapshot();
    try std.testing.expectEqual(types.SemanticPrompt.prompt, snap.prompt_marks[0].kind);
    try std.testing.expectEqual(@as(?i32, 3), snap.last_command_exit);
}

test "OSC 133: isPromptStart marks the first row of each prompt block" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 5 });
    defer core.deinit();
    // 2 사이클: A 프롬프트 + B 입력 + \r\n + C 출력 + \r\n + D. row0·row2가 프롬프트 블록 시작.
    try core.write("\x1b]133;A\x1b\\P$ \x1b]133;B\x1b\\c1\r\n\x1b]133;C\x1b\\o1\r\n\x1b]133;D;0\x07");
    try core.write("\x1b]133;A\x1b\\P$ \x1b]133;B\x1b\\c2\r\n\x1b]133;C\x1b\\o2\r\n\x1b]133;D;1\x07");
    try std.testing.expect(core.isPromptStart(0)); // 프롬프트+입력 줄(블록 시작)
    try std.testing.expect(!core.isPromptStart(1)); // 출력
    try std.testing.expect(core.isPromptStart(2)); // 다음 블록 시작(직전이 .command)
    try std.testing.expect(!core.isPromptStart(3)); // 출력
}

test "OSC 133: jumpToPrompt scrolls the viewport to a scrollback prompt" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\aaa\r\n"); // row0=.prompt "aaa", \r\n → row1 .prompt
    try core.write("\x1b]133;C\x1b\\bbb\r\n"); // row1=.command, \r\n scroll → row0(.prompt)이 스크롤백으로
    try core.write("\x1b]133;D;0\x07");
    try std.testing.expect(core.scrollbackLen() >= 1);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    try std.testing.expect(core.jumpToPrompt(-1)); // 이전 프롬프트 = 스크롤백의 .prompt
    try std.testing.expect(core.viewOffset() > 0); // 위로 스크롤됨
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.viewportRowPrompt(0).kind); // 그 프롬프트가 뷰 맨 위
}

test "OSC 133: jumpToPrompt returns false with no shell-integration classification" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("plain text\r\nno markers"); // OSC 133 없음 → 점프 타깃 없음
    try std.testing.expect(!core.jumpToPrompt(-1));
    try std.testing.expect(!core.jumpToPrompt(1));
}

test "OSC 133: reflow carries the tag of a re-wrapped (non-cursor) line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // row0 = command(출력 영역)
    try core.write("abcdef"); // abcd|ef soft-wrap: row0(wrapped)·row1 = command
    try std.testing.expect(core.wrapped[0]);
    try core.write("\r\nx"); // row2(.command 전파)로 커서 이동 → 위 wrap 줄은 커서 줄이 아니다
    try core.resize(8, 4); // 넓힘 → "abcdef"가 한 줄로 합쳐진다(재-wrap)
    try std.testing.expectEqual(@as(u21, 'a'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), core.cells[core.index(0, 5)].codepoint);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[0].kind); // 재-wrap 후 태그 보존
}

test "OSC 133: the verbatim cursor line keeps its tag across resize" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\p$ \x1b]133;B\x1b\\ls"); // row0: 프롬프트+입력 → .input(커서 줄)
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[0].kind);
    try core.resize(6, 4); // 좁힘 — 커서 줄은 verbatim(clip), 태그 1:1 보존
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[0].kind);
}

test "OSC 133: rows pushed to scrollback during resize carry their tag" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // command 영역
    try core.write("out1\r\nout2\r\nout3"); // row0·1·2 = command(전파), 커서 row2
    try core.write("\x1b]133;D;0\x07");
    try core.resize(8, 1); // 폭 동일, 행 3→1 → row0·row1이 스크롤백으로(태그 carry)
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(0).kind);
    try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(1).kind);
}

test "OSC 133: scrollback re-wrap keeps tags aligned with re-wrapped rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;C\x1b\\"); // command 영역
    try core.write("abcdefgh"); // row0 꽉 채움(.command, pending wrap)
    try core.write("ij"); // wrap → row1(.command), 커서 row1
    try std.testing.expect(core.wrapped[0]);
    try core.write("\r\n\r\n"); // 두 번 scroll → 논리 줄 abcdefghij가 스크롤백으로(.command)
    try std.testing.expect(core.scrollbackLen() >= 2);
    core.rewrapScrollback(4); // 폭 4로 재-wrap: abcd|efgh|ij — 모두 .command 유지
    var i: usize = 0;
    var saw_command = false;
    while (i < core.scrollbackLen()) : (i += 1) {
        // 재-wrap된 모든 행이 .command여야 한다(stale .unknown이면 PR1 misalignment 회귀).
        try std.testing.expectEqual(types.SemanticPrompt.command, core.scrollbackRowPrompt(i).kind);
        saw_command = true;
    }
    try std.testing.expect(saw_command);
}

test "OSC 133: a realistic zsh prompt+command sequence classifies rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    // 실제 Maru zsh 통합이 emit하는 형태(PTY 캡처로 확인): A·프롬프트·B·입력·CR/LF·C·출력·CR/LF·D;0.
    try core.write("\x1b]133;A\x1b\\"); // 프롬프트 시작 → row0=.prompt
    try core.write("myprompt$ "); // 프롬프트 텍스트(태그 유지)
    try core.write("\x1b]133;B\x1b\\"); // 입력 시작(같은 줄) → row0=.input
    try core.write("echo hi"); // 사용자 입력
    try core.write("\r\n"); // Enter → row1(.input 전파)
    try core.write("\x1b]133;C\x1b\\"); // 출력 시작 → row1=.command
    try core.write("hi\r\n"); // 명령 출력 → row2(.command 전파)
    try core.write("\x1b]133;D;0\x07"); // 명령 끝, exit 0 → state=unknown
    try std.testing.expectEqual(types.SemanticPrompt.input, core.prompt_marks[0].kind); // 프롬프트+입력 줄
    try std.testing.expectEqual(types.SemanticPrompt.command, core.prompt_marks[1].kind); // 출력 줄
    try std.testing.expectEqual(@as(?i32, 0), core.last_command_exit);
}

test "OSC 133: D stamps the exit code on the command's prompt-start row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    // 성공 명령: A $ B ls C out D;0 — exit 0이 프롬프트 시작 행(row0)에 스탬프된다.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\ls\r\n\x1b]133;C\x1b\\out\r\n\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(?i16, 0), core.prompt_marks[0].exit); // 프롬프트 시작 행
    try std.testing.expectEqual(@as(?i16, null), core.prompt_marks[1].exit); // 출력 행엔 없음
    // 실패 명령: 다음 프롬프트(row2 시작)에 exit 1.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\false\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;1\x07");
    try std.testing.expectEqual(@as(?i16, 1), core.prompt_marks[2].exit);
    try std.testing.expectEqual(@as(?i16, 0), core.prompt_marks[0].exit); // 첫 명령 exit는 그대로
}

test "OSC 133: the stamped exit carries with the row into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 실제 흐름: A $ B(입력 줄) \r\n C(출력 시작) \r\n(scroll) D;7. 입력 줄(row0)이 스크롤백으로
    // 밀려난 뒤 D가 그 행에 exit 7을 스탬프 → 스크롤백 행에 exit가 carry된다.
    try core.write("\x1b]133;A\x1b\\$\x1b]133;B\x1b\\\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;7\x07");
    try std.testing.expect(core.scrollbackLen() >= 1);
    try std.testing.expectEqual(@as(?i16, 7), core.scrollbackRowPrompt(0).exit); // exit carry
}

test "OSC 133: re-wrap keeps the exit on exactly one row (no duplicate gutter) [review #1]" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    // 긴 입력으로 프롬프트 줄이 soft-wrap되고 exit가 leader(row0)에 스탬프된다.
    try core.write("\x1b]133;A\x1b\\$ \x1b]133;B\x1b\\");
    try core.write("0123456789012345678901234"); // 25자 → row0(20)+row1(5) .input
    try core.write("\r\n\x1b]133;C\x1b\\\r\n\x1b]133;D;0\x07");
    var before: usize = 0;
    for (0..core.size.rows) |r| {
        if (core.prompt_marks[r].exit != null) before += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), before); // leader 한 행에만
    try core.resize(8, 8); // 좁힘 → 그 줄이 더 쪼개진다. exit는 여전히 한 행에만(중복 거터 방지).
    var after: usize = 0;
    for (0..core.size.rows) |r| {
        if (core.prompt_marks[r].exit != null) after += 1;
    }
    for (0..core.scrollbackLen()) |i| {
        if (core.scrollbackRowPrompt(i).exit != null) after += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), after); // 재-wrap 후에도 거터 바 1개
}

test "OSC 133: scrollRangeDown (RI/IL) carries the tag down and blanks the inserted row [review #2]" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = .prompt, 커서 row0(scroll_top)
    try core.write("\x1bM"); // RI: scroll region을 아래로 → row0 내용·태그가 row1로, row0은 빈 행
    try std.testing.expectEqual(types.SemanticPrompt.unknown, core.prompt_marks[0].kind); // 삽입된 빈 행 비분류
    try std.testing.expectEqual(types.SemanticPrompt.prompt, core.prompt_marks[1].kind); // 태그가 내려감
}

test "OSC 133: renderSnapshot composes prompt_marks for the scrolled viewport" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // row0 = prompt
    try core.write("X\x1b]133;D;0\x07"); // 태그 고정 + state 닫기
    try core.write("\r\n\r\n"); // row0(prompt) → 스크롤백
    core.scrollViewport(1); // 한 줄 위로: 윗줄에 스크롤백(prompt)
    const snap = core.renderSnapshot();
    try std.testing.expectEqual(types.SemanticPrompt.prompt, snap.prompt_marks[0].kind);
}

// 셸 의미 이벤트 스트림은 관측 가능성의 토대다 — 같은 도메인 데이터를 디버그 로그·테스트·후속
// trace가 공유한다. 핵심 검증: OSC 133/7 한 명령 사이클이 정확한 '경계 이벤트 순서'를 낸다
// (E2E가 명령 경계를 상태 스냅샷이 아니라 이벤트로 결정적으로 단언할 수 있어야 한다).
test "shell events: a full command cycle emits prompt/input/command/end + cwd in order" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();

    // 프롬프트 시작(A) → 입력 시작(B) → 출력 시작(C) → cwd 보고(OSC 7) → 명령 끝(D;0).
    try core.write("\x1b]133;A\x1b\\"); // row 0
    try core.write("\x1b]133;B\x07ls\r\n"); // 입력 시작 후 명령 타이핑 + 개행 → row 1
    try core.write("\x1b]133;C\x07out\r\n"); // 출력 시작 → row 2
    try core.write("\x1b]7;file://h/tmp\x07"); // cwd 변경
    try core.write("\x1b]133;D;0\x07"); // 명령 끝, 종료코드 0

    const events = core.shellEvents();
    try std.testing.expect(!core.shellEventsOverflowed());
    try std.testing.expectEqual(@as(usize, 5), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .prompt_start = 0 }, events[0]);
    try std.testing.expectEqual(types.ShellEvent{ .input_start = 0 }, events[1]);
    try std.testing.expectEqual(types.ShellEvent{ .command_start = 1 }, events[2]);
    try std.testing.expectEqual(types.ShellEvent{ .cwd_changed = {} }, events[3]);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 2, .exit = 0 } }, events[4]);
    // cwd 값 자체는 currentCwd()가 권위(이벤트는 경계만 표시).
    try std.testing.expectEqualStrings("/tmp", core.currentCwd());
}

test "shell events: command_end carries the failing exit code; clear empties the stream" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    try core.write("\x1b]133;D;130\x07"); // SIGINT 종료(130) — 음수가 아니어도 실패
    var events = core.shellEvents();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 0, .exit = 130 } }, events[0]);

    // D에 code가 없으면 exit=null(명세상 D는 code 없이도 온다).
    core.clearShellEvents();
    try std.testing.expectEqual(@as(usize, 0), core.shellEvents().len);
    try core.write("\x1b]133;D\x07");
    events = core.shellEvents();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(types.ShellEvent{ .command_end = .{ .row = 0, .exit = null } }, events[0]);
}

test "VS16 attaches to the base as a combining mark (one cell), shaper sees the emoji cluster" {
    // width.zig(중립 Unicode 폭)에서 옮겨온 core 통합 테스트 — base + VS16 결합이 한 글자, 폭은 EAW per-codepoint.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤(U+2764) + VS16(U+FE0F)
    // 폭은 EAW per-codepoint(❤=1, VS16=0) — zsh와 일치시켜 붙여넣기 redraw가 안 깨지게(폭 승격하면 CSI<N>D recolor 어긋남).
    try std.testing.expectEqual(@as(u21, 0x2764), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0xFE0F), core.cells[0].combining);
    try std.testing.expectEqual(@as(u2, 1), core.cells[0].width); // EAW Neutral = 1(zsh 일치)
    try std.testing.expectEqual(@as(u21, ' '), core.cells[1].codepoint); // 다음 칸은 빈칸
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}
