const std = @import("std");
const terminal = @import("../terminal.zig");

/// 메인발 비-PTY 코어 mutate를 I/O 스레드(reader)로 위임하는 명령(docs/plans/io-render-threading.md §9 Phase 3,
/// (a) 단일책임). runtime·pty_reader·live_pty가 공유하므로 순환 import를 피해 **중립 위치**에 둔다(terminal만
/// 의존). 큐는 `pty_reader.CoreCommandQueue`, 적용은 `apply`(여기) — reader drain과 non-interactive 직접 폴백이
/// 같은 적용 로직을 공유한다. 명령 집합은 §9.2를 따라 scroll·선택·리포팅·config까지 단계 확장됐다.
/// reportMouse 인자 묶음(P3-3 위임). 코어가 적용 시 mouse_tracking을 다시 가드(.none이면 no-op)하므로,
/// enqueue~apply 사이 트래킹이 꺼져도 안전(메인의 트래킹 읽기는 락 아래 별도).
pub const MouseReport = struct {
    button: u8,
    col: u16,
    row: u16,
    x_px: u16,
    y_px: u16,
    pressed: bool,
    motion: bool,
    mods: u8,
};

pub const CellMetrics = struct { width: u32, height: u32 };
pub const DefaultColors = struct { foreground: terminal.Rgb, background: terminal.Rgb };
pub const RuntimeConfig = struct {
    max_scrollback: usize,
    ambiguous_wide: bool,
    emoji_wide: bool,
    palette: [16]?terminal.Rgb,
    default_colors: DefaultColors,
    cell_metrics: ?CellMetrics,
    /// config `cursor.shape` — 코어의 DECSCUSR 0/RIS 복귀 지점. 원격(host-backed) core는 host가 소유하므로 이 값을
    /// 실어 보내야 로컬과 같은 규칙으로 동작한다(안 보내면 host 기본 block으로 굳어 설정이 원격에서만 무동작).
    default_cursor_shape: terminal.CursorShape = .block,
};

/// 마우스 선택 위치(셀). full (a)(P3-4)에서 선택 코어 mutate는 명령으로 위임하고, read-modify-decide(아래
/// `select_extend_or_collapse`·`scroll_and_extend`)는 reader가 락 아래 **원자 실행**한다 — 메인은 코어를 안 만진다.
pub const SelectAt = struct { row: u16, col: u16 };
pub const SelectStart = struct { row: u16, col: u16, block: bool };
/// 더블클릭 단어 선택 — selectWordAt(row, col, separators). config input.word-separators(F2-8)를 명령에 **복사**해
/// 실어 보낸다(borrowed slice의 reload 수명 문제 회피, set_config_palette처럼 값 복사). buf 초과분은 잘려 무시.
pub const SelectWord = struct {
    row: u16,
    col: u16,
    separators: [64]u8 = undefined,
    sep_len: u8 = 0,
};
/// 드래그 autoscroll: scrollViewport(delta) + selectionExtend(row,col)를 한 명령으로(원래 핸들러의 write 묶음).
pub const ScrollExtend = struct { delta: isize, row: u16, col: u16 };

pub const CoreCommand = union(enum) {
    scroll: isize, // scrollViewport(delta_up)
    scroll_to_bottom,
    // 리포팅(코어 response 생성 — reader가 적용 후 pendingResponse를 PTY로 흘린다):
    report_mouse: MouseReport, // 사이트 배선은 P3-4(측정): 빈번한 PTY-응답이라 §1 결함과 같은 latency 클래스 — §9.4 측정 후 위임
    report_focus: bool, // reportFocus(gained) — P3-3(드묾, latency 무관)
    // P3-3 config(폰트·테마·스크롤백 reload — 값 명령, response 없음):
    set_cell_metrics: CellMetrics,
    set_default_colors: DefaultColors,
    set_config_palette: [16]?terminal.Rgb,
    set_max_scrollback: usize,
    set_ambiguous_wide: bool, // text.ambiguous-width reload — 라이브 코어의 EAW Ambiguous 폭(이후 putCell부터 반영)
    set_emoji_wide: bool, // text.emoji-width reload — 라이브 코어의 이모지(VS16/키캡) 폭 승격(이후 putCell부터 반영)
    set_default_cursor_shape: terminal.CursorShape, // cursor.shape reload — DECSCUSR 0/RIS 복귀 지점(앱 override 중이면 저장만)
    set_runtime_config: RuntimeConfig, // attach/reconnect bootstrap — 한 queue slot에서 host 권위 config를 함께 적용
    // P3-4 scroll·선택 위임(full (a) — read-modify-decide는 reader가 원자 실행, 메인 코어 mutate 0):
    scroll_to_abs: usize, // scrollToAbs(절대 행) — find 점프
    scroll_to_offset: usize, // 절대 view_offset로 — reader가 **fresh offset에서 delta 계산**(스크롤바 드래그: 메인이
    // delta를 미리 빼면 연속 명령이 옛 base로 double-count돼 어긋남 — 절대 목표를 보내 reader가 적용 시점에 빼야 정확)
    scroll_and_extend: ScrollExtend, // 드래그 autoscroll: scrollViewport+selectionExtend 묶음
    select_start: SelectStart, // selectionStart(+block)
    select_extend: SelectAt, // selectionExtend
    select_extend_or_collapse: SelectAt, // extend 후 anchor==head면 clear(이동 없는 클릭=해제 — read-after-write 원자)
    select_word: SelectWord, // selectWordAt(더블클릭) — config word-separators를 복사해 실음(F2-8)
    select_line: u16, // selectLineAt(트리플클릭, row)
    select_all,
    /// 선택 해제(selectionClear). "선택을 만든 주체가 아닌 쪽"이 선택을 무효로 만드는 지점 전용이다 —
    /// 마우스 리포팅 중 클릭·휠(앱이 마우스를 소유하므로 하이라이트만 남으면 유령), 타이핑·Esc
    /// (input.selection-clear-on-typing). 이 명령이 없던 시절엔 ⌘A 선택을 지울 경로가 "이동 없는 클릭"과
    /// 좌표 무효화(resize reflow·alt 전환)뿐이라, 트래킹 TUI pane에선 클릭조차 안 먹혀 선택이 영구히 남았다.
    select_clear,
    jump_to_prompt: i8, // jumpToPrompt(dir) — OSC 133 프롬프트 블록 점프(Cmd+↑/↓), view_offset mutate
    /// 화면 비우기(⌘K). 권위 core가 prompt/alt 여부를 판정해야 하므로 host-backed에서도 reader에 위임한다.
    /// 반환된 `send_form_feed`는 reader가 core lock 밖의 PTY 출력 순서축에 붙인다.
    clear_screen,
    /// 비파괴 입력 모드 리셋(Reset 메뉴 ⌘⇧R) — ssh 비정상 종료 등으로 남은 focus 1004·mouse·kitty keyboard 모드만
    /// 끈다. host-backed면 **실제 모드를 든 host core**에 적용돼야 하므로 명령으로 위임한다(client core는 빈
    /// placeholder라 거기서 리셋해 봐야 원격 앱은 계속 리포트를 보낸다).
    reset_input_modes,
};

/// 명령을 코어에 적용한다. **호출자가 코어 락(core_mutex)을 잡은 상태여야 한다** — reader는 `owner_dbg.lock`,
/// non-interactive 직접 폴백은 `surface.lockCore`. 단일 mutator 계약상 적용은 한 스레드에서만 일어난다(§9.3).
/// 응답을 만드는 명령(리포팅 — P3-3)은 적용 후 호출자가 `core.pendingResponse`를 PTY로 흘린다.
pub const ApplyEffect = struct { send_form_feed: bool = false };

pub fn apply(core: *terminal.TerminalCore, cmd: CoreCommand) ApplyEffect {
    switch (cmd) {
        .scroll => |delta| core.scrollViewport(delta),
        .scroll_to_bottom => core.scrollToBottom(),
        .report_mouse => |m| core.reportMouse(m.button, m.col, m.row, m.x_px, m.y_px, m.pressed, m.motion, m.mods),
        .report_focus => |gained| core.reportFocus(gained),
        .set_cell_metrics => |cm| core.setCellMetrics(cm.width, cm.height),
        .set_default_colors => |colors| core.setDefaultColors(colors.foreground, colors.background),
        .set_config_palette => |palette| core.setConfigPalette(palette),
        .set_max_scrollback => |lines| core.setMaxScrollback(lines),
        .set_ambiguous_wide => |v| core.ambiguous_wide = v,
        .set_emoji_wide => |v| core.emoji_wide = v,
        .set_default_cursor_shape => |shape| core.setDefaultCursorShape(shape),
        .set_runtime_config => |config| {
            core.setMaxScrollback(config.max_scrollback);
            core.ambiguous_wide = config.ambiguous_wide;
            core.emoji_wide = config.emoji_wide;
            core.setConfigPalette(config.palette);
            core.setDefaultColors(config.default_colors.foreground, config.default_colors.background);
            if (config.cell_metrics) |metrics| core.setCellMetrics(metrics.width, metrics.height);
            core.setDefaultCursorShape(config.default_cursor_shape);
        },
        .scroll_to_abs => |abs| core.scrollToAbs(abs),
        .scroll_to_offset => |target| {
            // 적용 시점의 fresh view_offset에서 delta를 구해 절대 위치로 — 연속 스크롤바 드래그가 double-count로 어긋나지 않게.
            const cur: isize = @intCast(core.viewOffset());
            core.scrollViewport(@as(isize, @intCast(target)) - cur);
        },
        .scroll_and_extend => |se| {
            core.scrollViewport(se.delta);
            core.selectionExtend(se.row, se.col);
        },
        .select_start => |s| {
            core.selectionStart(s.row, s.col);
            if (s.block) core.setSelectionBlock(true);
        },
        .select_extend => |s| core.selectionExtend(s.row, s.col),
        .select_extend_or_collapse => |s| {
            // 이동 없는 클릭은 선택이 아니라 해제(다른 터미널과 동일). extend→collapse 판정→clear을 reader가
            // 원자 실행한다 — 메인이 위임 후 옛 상태를 읽어 오판하던 read-after-write 문제 제거(§9.4 full (a)).
            core.selectionExtend(s.row, s.col);
            if (core.selection_anchor) |a| {
                if (core.selection_head) |h| {
                    if (a.row == h.row and a.col == h.col) core.selectionClear();
                }
            }
        },
        .select_word => |s| core.selectWordAt(s.row, s.col, s.separators[0..s.sep_len]),
        .select_line => |row| core.selectLineAt(row),
        .select_all => core.selectAll(),
        .select_clear => core.selectionClear(),
        .clear_screen => return .{ .send_form_feed = core.clearScreen() },
        .reset_input_modes => core.resetInputModes(),
        .jump_to_prompt => |dir| _ = core.jumpToPrompt(dir), // bool 반환(스크롤됨)은 reader 렌더 트리거로 대체
    }
    return .{};
}

test "core_command.apply: 각 명령이 코어를 올바르게 mutate (위임 적용 로직)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    // scroll → 과거로 스크롤(view_offset>0), scroll_to_bottom → 바닥 복귀(view_offset==0)
    var i: usize = 0;
    while (i < 20) : (i += 1) try core.write("line\r\n");
    apply(&core, .{ .scroll = 5 });
    try std.testing.expect(core.viewOffset() > 0);
    apply(&core, .scroll_to_bottom);
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());

    // report_mouse → mouse_tracking 켜면 코어가 SGR/x10 리포트 응답 생성
    core.mouse_tracking = .normal;
    apply(&core, .{ .report_mouse = .{ .button = 0, .col = 1, .row = 1, .x_px = 0, .y_px = 0, .pressed = true, .motion = false, .mods = 0 } });
    try std.testing.expect(core.pendingResponse().len > 0);
    core.clearResponse();
    apply(&core, .{ .report_focus = false }); // 응답 유무는 focus-reporting 모드 의존 — 호출 경로 무크래시만 검증

    // config 값 명령(set_max_scrollback / set_cell_metrics / set_config_palette)
    apply(&core, .{ .set_max_scrollback = 500 });
    try std.testing.expectEqual(@as(usize, 500), core.maxScrollback());
    apply(&core, .{ .set_ambiguous_wide = true }); // text.ambiguous-width reload — 라이브 코어 폭 재적용
    try std.testing.expect(core.ambiguous_wide);
    apply(&core, .{ .set_ambiguous_wide = false });
    try std.testing.expect(!core.ambiguous_wide);
    apply(&core, .{ .set_emoji_wide = false }); // text.emoji-width reload — 라이브 코어 이모지 폭 재적용
    try std.testing.expect(!core.emoji_wide);
    apply(&core, .{ .set_emoji_wide = true });
    try std.testing.expect(core.emoji_wide);
    apply(&core, .{ .set_cell_metrics = .{ .width = 8, .height = 16 } });
    apply(&core, .{ .set_default_colors = .{
        .foreground = .{ .r = 0x11, .g = 0x22, .b = 0x33 },
        .background = .{ .r = 0x44, .g = 0x55, .b = 0x66 },
    } });
    var palette: [16]?terminal.Rgb = .{null} ** 16;
    palette[1] = .{ .r = 10, .g = 20, .b = 30 };
    apply(&core, .{ .set_config_palette = palette });
    try std.testing.expect(core.config_palette[1] != null);

    // P3-4 scroll·선택(full (a)) — 코어 상태 변화 검증
    apply(&core, .scroll_to_bottom); // 바닥에서 선택 좌표 일관
    apply(&core, .select_all);
    try std.testing.expect(core.selection_anchor != null);
    // select_clear가 ⌘A 선택을 실제로 지운다 — 마우스 리포팅 pane/타이핑에서 하이라이트가 영구히 남던
    // 결함의 유일한 해제 경로라 여기서 고정한다(선택 없을 때 재적용해도 no-op이어야 한다).
    apply(&core, .select_clear);
    try std.testing.expect(core.selection_anchor == null);
    apply(&core, .select_clear);
    try std.testing.expect(core.selection_anchor == null);
    apply(&core, .select_all); // 이후 검증이 선택 있는 상태를 전제하므로 되돌린다
    apply(&core, .{ .jump_to_prompt = -1 }); // OSC 133 없으면 no-op — 무크래시 경로
    apply(&core, .{ .select_start = .{ .row = 0, .col = 0, .block = false } }); // 새 선택이 이전을 대체
    apply(&core, .{ .select_extend = .{ .row = 1, .col = 2 } });
    try std.testing.expect(core.selection_anchor != null);
    // 같은 위치로 extend → anchor==head → collapse(clear): read-after-write를 apply가 원자 실행
    apply(&core, .{ .select_extend_or_collapse = .{ .row = 0, .col = 0 } });
    try std.testing.expect(core.selection_anchor == null);
    // scroll_to_abs / scroll_to_offset / scroll_and_extend / select_word / select_line: 무크래시 경로
    apply(&core, .{ .scroll_to_abs = 0 });
    apply(&core, .{ .scroll_to_offset = 0 });
    apply(&core, .{ .select_start = .{ .row = 0, .col = 0, .block = false } });
    apply(&core, .{ .scroll_and_extend = .{ .delta = 0, .row = 1, .col = 1 } });
    // select_word가 separators 페이로드를 selectWordAt(row, col, separators[0..sep_len])로 전달함을 고정(F2-8 — 무크래시
    // + 분할 정확성은 core.zig "double-click with word-separators" 테스트가 별도로 본다). sep_len=0/>0 둘 다 경로 통과.
    apply(&core, .{ .select_word = .{ .row = 0, .col = 0 } }); // sep_len 기본 0 → 공백만 경계
    var sw_cmd: CoreCommand = .{ .select_word = .{ .row = 0, .col = 0, .sep_len = 1 } };
    sw_cmd.select_word.separators[0] = ':';
    apply(&core, sw_cmd); // sep_len=1(":") → 구분자 경로
    apply(&core, .{ .select_line = 0 });
}

test "core_command.apply: clear effect follows authoritative prompt and alt state" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 4 });
    defer core.deinit();

    try core.write("plain");
    try std.testing.expect(!apply(&core, .clear_screen).send_form_feed);

    try core.write("\x1b]133;A\x1b\\prompt");
    try std.testing.expect(apply(&core, .clear_screen).send_form_feed);

    try core.write("\x1b[?1049h");
    try std.testing.expect(!apply(&core, .clear_screen).send_form_feed);
}
