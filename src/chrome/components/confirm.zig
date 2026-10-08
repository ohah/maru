//! Confirm — 예/아니오 확인 다이얼로그(키보드 Enter/Esc·Y/N + 마우스 클릭 hit-test `buttonAtPoint`). **재사용 가능한 디자인 시스템 컴포넌트**:
//! 메시지 + 두 버튼 라벨을 host가 주입하면(`show(message, .{ .confirm = "닫기", .cancel = "취소" })`) 경계선 패널 +
//! 가운데 버튼 두 개(라벨에 TUI식 [Y]/[N] 단축키)를 그리고, ←/→로 포커스를 옮기면 accent 강조가 따라간다(Enter는
//! 포커스된 버튼 실행). 닫기 확인뿐 아니라 삭제·저장 등 어떤 확인에도 쓴다 —
//! 컴포넌트는 "무엇을 확인하는지"를 모르고(중립), handle은 의도(confirmed/cancelled)만 돌려준다. host가 confirmed면
//! 보류한 동작을 실행, cancelled면 버린다. chrome 계약: State(순수 데이터+전이) + view(순수) + handle(intent 반환).
//! 박스 기하·중앙배치·폭 clamp는 modal_box 프리미티브(단일 출처)에 위임한다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 중앙 정렬·박스 폭 계산
const text_layout = @import("../text_layout.zig"); // elidePathMiddle — 경로 안내 줄을 뿌리·잎을 남기고 가운데에서 줄인다

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유 — notice와 동일). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

/// 버튼에 표시하는 단축키 마커 — TUI 관례의 Y/N(Enter/Esc도 handle이 받지만, 표시는 짧은 Y/N로 통일해 영어
/// 단어를 안 섞는다). 버튼 라벨 앞에 "[Y] "/"[N] "로 붙여 어느 키가 어느 버튼인지 보인다(키는 handle이 고정).
const key_confirm = "Y";
const key_alternate = "D";
/// 네 번째 자리(`extra`)의 마커. **이 글자들은 뜻이 아니라 «자리»다** — `D` 도 「종료 및 세션
/// 끝내기」에서 그랬다. 새 글자는 기존 셋(`Y`·`D`·`N`)과 겹치지 않는 것이면 된다.
const key_extra = "R";
const key_cancel = "N";

/// show가 받는 버튼 라벨. 호출자가 **둘 다 준다** — 컴포넌트가 닫기 전용이 아니라 범용이게 하는
/// 재사용 seam이다.
///
/// **기본값을 두지 않는다.** `"확인"`/`"취소"` 를 기본값으로 두었더니 그 문자열이 struct 필드 기본값이라
/// **comptime 에 얼어붙었다** — `.{}` 로 부르면 `ui.language` 와 무관하게 한국어가 나오고, 필드 기본값에는
/// 런타임 조회(`i18n.t`)를 넣을 수 없다(컨테이너 수준 `const` 와 같은 제약이다). 제품 호출부는 전부
/// 라벨을 명시하고 있었으므로 기본값은 **쓰이지 않는 함정**이었다. 없애면 빠뜨린 자리가 컴파일 에러가
/// 된다 — 계약 §7.2 의 1차 방어(타입으로 막는다)와 같은 방식이다.
pub const Buttons = struct {
    confirm: []const u8,
    cancel: []const u8,
};

/// 세 갈래 확인 descriptor. `primary`/`alternate`/`cancel`은 표시 순서와 무관한 안정적인 choice id이며,
/// 기존 두 버튼 호출자는 `Buttons`/`show`를 그대로 쓴다.
pub const Choices = struct {
    primary: []const u8,
    alternate: []const u8,
    cancel: []const u8,
    /// **네 번째 자리**(선택) — 행동이 셋인 대화상자만 쓴다(저장 충돌: 비교·덮어쓰기·다시 읽기).
    ///
    /// **왜 `cancel` 에 세 번째 행동을 놓을 수 없나**: `cancel` 은 버튼이면서 **Esc·바깥 클릭의
    /// 갈래**다(`handle` 의 `.escape`·`buttonAtPoint` 의 패널 밖). 거기에 행동을 놓으면 Esc 가 그
    /// 행동을 실행한다 — 「닫으면 아무 일도 일어나지 않는다」가 깨진다.
    ///
    /// 기본값이 `null` 이라 **기존 세 갈래 호출부는 그대로**다(라벨 기본값을 두지 않는 규율은 위 주석
    /// 그대로 — 이것은 라벨이 아니라 「그 자리가 있나」다).
    extra: ?[]const u8 = null,
};

/// 메시지와 버튼 사이에 그리는 **안내 줄** — 신뢰 시트처럼 확인의 대가를 밝히는 문장(tooling §8.1 「sandbox 하지 못하는
/// 한계를 확인 UX 에 명시」). 경고 문장은 잘리면 뜻이 사라지므로 안쪽 폭으로 **줄바꿈**하고(`wrap`), 경로처럼 한 줄로
/// 둘 값은 **가운데를 줄인다**(`path` — 뿌리와 잎을 남긴다). 붙여넣기 미리보기(`body` — 코드처럼 배경을 깔고 끝을 자른다)와
/// 달리 배경 없이 본문 글자색으로 그린다.
pub const Note = struct {
    text: []const u8,
    fit: Fit = .wrap,

    pub const Fit = enum { wrap, path };
};

/// 안내 줄이 줄바꿈 뒤 차지할 수 있는 행 수 상한 — 넘으면 마지막 줄이 「…」로 끝난다(상자가 창을 덮지 않게).
pub const max_note_rows: u32 = 24;

/// 그릴 안내 한 행 — 원문을 빌린다. `path` 면 그릴 때 가운데를 줄이고, `cut` 이면 끝에 「…」를 붙인다.
const NoteLine = struct { text: []const u8, path: bool = false, cut: bool = false };

/// 어느 버튼에 포커스가 있나(←/→로 이동). Enter가 포커스된 버튼을 실행한다. 열 때마다 기본 = confirm(Enter=확정 유지).
pub const Focus = enum { confirm, alternate, extra, cancel };

/// 순수 상태 — message + (선택) 본문 미리보기 + 버튼 라벨 + 포커스 + open 플래그. host가 보류(pending)하며 show를
/// 부른다. 라벨은 show가 채우고, body는 show 뒤 host가 따로 주입한다(대부분의 확인엔 없음 — 붙여넣기 미리보기 전용).
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",
    // 기본값은 빈 문자열 — 실제 라벨은 show(message, Buttons)가 채운다(호출자가 둘 다 준다).
    // view는 open일 때만 그리고 show 없이는 열리지 않으므로 빈 기본값이 렌더되는 일은 없다.
    confirm_label: []const u8 = "",
    alternate_label: []const u8 = "",
    extra_label: []const u8 = "",
    cancel_label: []const u8 = "",
    has_alternate: bool = false,
    has_extra: bool = false,
    focused: Focus = .confirm,
    // 메시지와 버튼 사이에 그릴 **본문 미리보기 줄들**(비면 없음 — 기존 동작). Ghostty의 붙여넣기 확인창이 내용을
    // 스크롤 뷰로 보여주는 것의 셀-그리드 근사(앞 몇 줄 + 요약). 슬라이스는 host가 세션 소유 버퍼로 준다(message와 동형).
    body: []const []const u8 = &.{},
    // 메시지 아래에 그릴 **안내 줄들**(비면 없음 — 기존 동작). 슬라이스는 host 가 세션 소유 버퍼로 준다(body 와 같다).
    notes: []const Note = &.{},

    pub fn show(self: *State, message: []const u8, buttons: Buttons) void {
        self.message = message;
        self.confirm_label = buttons.confirm;
        self.alternate_label = "";
        self.extra_label = "";
        self.cancel_label = buttons.cancel;
        self.has_alternate = false;
        self.has_extra = false;
        self.focused = .confirm; // 열 때마다 기본 포커스 = 확정 버튼(Enter=확정, ←/→로 이동). 동작이 전부 파괴적인 상자는 호출자가 show 뒤 .cancel 로 둔다
        self.body = &.{}; // 이전 확인이 남긴 미리보기가 새 모달에 새지 않게 리셋(붙여넣기 경로가 show 뒤 다시 주입)
        self.notes = &.{}; // 안내 줄도 같다(신뢰 시트가 show 뒤 다시 주입)
        self.open = true;
    }

    pub fn showChoices(self: *State, message: []const u8, choices: Choices) void {
        self.message = message;
        self.confirm_label = choices.primary;
        self.alternate_label = choices.alternate;
        self.extra_label = choices.extra orelse "";
        self.cancel_label = choices.cancel;
        self.has_alternate = true;
        self.has_extra = choices.extra != null;
        self.focused = .confirm;
        self.body = &.{};
        self.notes = &.{};
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리한다 — confirmed면 보류한 동작을 실행, cancelled면 버린다.
/// (notice는 dismissed 하나뿐이지만 confirm은 파괴적 동작 분기라 둘로 나뉜다.)
pub const Action = enum { confirmed, alternate, extra, cancelled };

/// 키 이벤트 처리. 열려 있을 때만 동작:
///   ←/→ : 두 버튼 사이 포커스 이동(소비, intent 없음 → host가 재렌더). Enter : **포커스된** 버튼 실행
///   (confirm/cancelled). Esc : 항상 cancelled(취소 관례). Y/N : 포커스와 무관하게 직접 실행(대소문자 무시 단축키).
/// 그 외 키는 소비하되 Action 없음(모달이라 뒤(터미널)로 안 흘린다). 닫혀 있으면 null(라우팅 안 가로챔).
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (k.key) {
        // **순회는 그려진 순서**(confirm → alternate → extra → cancel)를 따른다. 없는 자리는 건너뛴다 —
        // 안 건너뛰면 포커스가 보이지 않는 버튼에 얹혀 Enter 가 아무 일도 안 한다.
        .left => {
            state.focused = switch (state.focused) {
                .confirm => .cancel,
                .alternate => .confirm,
                .extra => .alternate,
                .cancel => if (state.has_extra) .extra else if (state.has_alternate) .alternate else .confirm,
            };
            return null;
        },
        .right => {
            state.focused = switch (state.focused) {
                .confirm => if (state.has_alternate) .alternate else .cancel,
                .alternate => if (state.has_extra) .extra else .cancel,
                .extra => .cancel,
                .cancel => .confirm,
            };
            return null;
        },
        .enter => {
            state.dismiss();
            return switch (state.focused) {
                .confirm => .confirmed,
                .alternate => .alternate,
                .extra => .extra,
                .cancel => .cancelled,
            };
        },
        .escape => {
            state.dismiss();
            return .cancelled;
        },
        .char => switch (k.codepoint) {
            'y', 'Y' => {
                state.dismiss();
                return .confirmed;
            },
            'n', 'N' => {
                state.dismiss();
                return .cancelled;
            },
            'd', 'D' => if (state.has_alternate) {
                state.dismiss();
                return .alternate;
            } else return null,
            'r', 'R' => if (state.has_extra) {
                state.dismiss();
                return .extra;
            } else return null,
            else => return null, // 다른 글자는 소비만(모달 — 뒤로 안 샘)
        },
        else => return null,
    }
}

/// 확인 다이얼로그를 그린다 — 경계선 패널(modal_box.frame) 안에 (1) 메시지(중앙), (2) 가운데 버튼 행: **포커스된**
/// 버튼이 accent 배경(focus_accent) + 대비색 라벨로 강조되고 나머지는 은은한 배경(tab_hover_bg)이다(←/→로 강조가
/// 옮겨감). 두 버튼 다 라벨에 TUI식 단축키 마커([Y]/[N])를 단다(별도 영어 키 줄 없음). 안 열렸으면 무동작. 박스
/// 기하/중앙배치/폭 clamp/soft-lock은 modal_box 단일 출처. 순수: state·props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    const g = buttonGeom(state, p, tk) orelse return;
    const box = g.box;
    try modal_box.frame(box, p, arena, out);

    // (1) 메시지 — 줄마다 중앙, row 0부터 g.msg_rows 줄. 상자 안쪽 폭에 맞춰 나눈다(`modal_box.wrapLine`) — 한 줄로만 그리면
    //     넘치는 글자가 상자 밖으로 나가 창 가장자리에서 잘렸다(기본 960pt 창에서 영어 붙여넣기·원격 삭제·LSP 신뢰 확인,
    //     2026-10-05 실측). 상한을 넘으면 마지막 줄이 「…」로 끝난다.
    for (g.msg_lines[0..g.msg_rows], 0..) |line, i| {
        const last_cut = g.msg_truncated and i + 1 == g.msg_rows;
        // 줄 수를 줄여 자른 마지막 줄은 폭이 꽉 찼을 수 있다 — 「…」를 붙인 뒤 안쪽 폭으로 다시 맞춘다.
        const shown = if (last_cut) try overlay_input.truncateToCols(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ line, modal_box.ellipsis }), box.inner_cols) else line;
        try modal_box.text(box, modal_box.centerX(box, overlay_input.displayCols(shown)), @intCast(i), shown, .surface_fg, arena, out);
    }

    // (1.25) 안내 줄(있으면) — 메시지 아래 빈 줄 다음부터 좌측 정렬, 본문 글자색. 줄바꿈은 buttonGeom 이 이미 했다 — 여기서는
    //      경로 줄의 가운데를 줄이고, 높이가 모자라 잘린 마지막 줄에 「…」를 붙인 뒤 안쪽 폭으로 다시 맞춘다.
    for (g.note_lines[0..g.note_rows], 0..) |nl, i| {
        const row = g.note_row + @as(u32, @intCast(i));
        var shown: []const u8 = nl.text;
        if (nl.path) {
            const buf = try arena.alloc(u8, nl.text.len + 8);
            shown = text_layout.elidePathMiddle(nl.text, box.inner_cols, null, buf);
        }
        if (nl.cut) shown = try std.fmt.allocPrint(arena, "{s}{s}", .{ shown, modal_box.ellipsis });
        try modal_box.text(box, box.inner_x, row, try overlay_input.truncateToCols(arena, shown, box.inner_cols), .surface_fg, arena, out);
    }

    // (1.5) 본문 미리보기(있으면) — 메시지 아래 빈 줄 다음부터 좌측 정렬. 각 줄에 은은한 배경 fill(tab_hover_bg)을
    //       inner 폭만큼 깔아 인셋 패널처럼 보이게 하고, 그 위에 muted 텍스트를 놓는다(painter order: fill→text).
    //       Ghostty의 스크롤 텍스트 뷰를 셀-그리드로 근사한 것 — 붙여넣을 내용을 눈으로 확인하고 결정하게 한다.
    // 미리보기 줄도 안쪽 폭에서 끝을 줄인다 — 예전에는 그대로 그려 좁은 상자에서 글자가 패널 밖으로 나갔다(적대적 검증).
    for (state.body[0..g.body_rows], 0..) |line, i| {
        const row = g.body_row + @as(u32, @intCast(i));
        try modal_box.fillCells(box, box.inner_x, row, box.inner_cols, .tab_hover_bg, arena, out);
        try modal_box.text(box, box.inner_x, row, try overlay_input.truncateToCols(arena, line, box.inner_cols), .muted_fg, arena, out);
    }

    // (2) 버튼 행(g.btn_row — 미리보기 줄 수만큼 아래로 내려감) — **포커스된 버튼이 accent**(focus_accent + 대비색 surface_bg 라벨)로 강조되고, 나머지는 은은한 배경
    //     (tab_hover_bg + surface_fg 라벨)이다. ←/→로 포커스가 옮겨가면 강조도 따라 이동한다(어느 버튼이 Enter 대상인지
    //     보임). 둘 다 배경 fill로 버튼처럼(painter order: bg→glyph). 위치/폭은 buttonGeom 단일 출처(클릭 hit-test와 공유).
    //     라벨은 버튼 패딩만큼 우측에서 시작. arena에 만든 라벨 슬라이스는 view 동안(=lower까지) 유효.
    const confirm_focused = state.focused == .confirm;
    if (g.confirm_fit > 0) {
        try modal_box.fillCells(box, g.confirm_x, g.confirm_row, g.confirm_fit, if (confirm_focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try buttonLabel(arena, key_confirm, state.confirm_label, g.confirm_fit);
        try modal_box.text(box, g.confirm_x + @as(i32, @intCast(btn_pad * box.cw)), g.confirm_row, t, if (confirm_focused) .surface_bg else .surface_fg, arena, out);
    }
    if (state.has_alternate and g.alternate_fit > 0) {
        const focused = state.focused == .alternate;
        try modal_box.fillCells(box, g.alternate_x, g.alternate_row, g.alternate_fit, if (focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try buttonLabel(arena, key_alternate, state.alternate_label, g.alternate_fit);
        try modal_box.text(box, g.alternate_x + @as(i32, @intCast(btn_pad * box.cw)), g.alternate_row, t, if (focused) .surface_bg else .surface_fg, arena, out);
    }
    if (state.has_extra and g.extra_fit > 0) {
        const focused = state.focused == .extra;
        try modal_box.fillCells(box, g.extra_x, g.extra_row, g.extra_fit, if (focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try buttonLabel(arena, key_extra, state.extra_label, g.extra_fit);
        try modal_box.text(box, g.extra_x + @as(i32, @intCast(btn_pad * box.cw)), g.extra_row, t, if (focused) .surface_bg else .surface_fg, arena, out);
    }
    if (g.cancel_fit > 0) {
        const focused = state.focused == .cancel;
        try modal_box.fillCells(box, g.cancel_x, g.cancel_row, g.cancel_fit, if (focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try buttonLabel(arena, key_cancel, state.cancel_label, g.cancel_fit);
        try modal_box.text(box, g.cancel_x + @as(i32, @intCast(btn_pad * box.cw)), g.cancel_row, t, if (focused) .surface_bg else .surface_fg, arena, out);
    }
}

const btn_pad: u32 = 1; // 버튼 라벨 좌우 패딩(배경이 라벨을 감싸 버튼처럼)

/// 버튼 라벨 `[키] 라벨` — 배경이 잘린 폭(`fit` 칸)에서 좌우 패딩을 뺀 자리에 맞춰 끝을 「…」로 줄인다. 예전에는 배경만
/// 상자 안으로 잘리고(`fitButtonCols`) 라벨은 그대로 그려 **글자가 패널 밖으로** 나갔다(적대적 검증 퍼징 5,000 회 중
/// 1,293 건 — 좁은 창·큰 글꼴의 「[Y] 덮어쓰기」 등). 들어가면 그대로다.
fn buttonLabel(arena: std.mem.Allocator, key: []const u8, label: []const u8, fit: u32) ![]const u8 {
    const t = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key, label });
    return overlay_input.truncateToCols(arena, t, fit -| 2 * btn_pad);
}
const btn_gap: u32 = 2; // 두 버튼 사이 간격(칸)

/// 버튼 행 기하 — view(그리기)와 buttonAtPoint(클릭 hit-test)가 공유하는 **단일 레이아웃**(chrome 계약 §5.4의
/// view↔hitTest 단일 모델). 박스·각 버튼 x·fit-clamp된 폭(칸; 0이면 너무 좁아 생략)을 돌려준다. null=안 열림/생략 박스.
const ButtonGeom = struct {
    box: modal_box.Box,
    btn_row: u32, // 버튼 **첫** 행 — 메시지 줄 수와 미리보기(body) 줄 수만큼 아래로 내려간다(view↔hitTest 공유)
    btn_rows: u32, // 버튼이 차지하는 행 수 — 한 줄에 안 들어가면 순서대로 다음 줄로 넘긴다
    // 버튼마다 자기 행(btn_row 부터). 없는 버튼(has_alternate/has_extra=false)은 무시된다.
    confirm_row: u32,
    alternate_row: u32,
    extra_row: u32,
    cancel_row: u32,
    note_row: u32, // 안내 첫 행 — 메시지 줄 다음 빈 줄 뒤
    note_rows: u32, // 그릴 안내 행 수 — 상자가 작업영역보다 높으면 줄바꿈된 행보다 적다(마지막 행이 「…」)
    note_lines: [max_note_rows]NoteLine,
    body_row: u32, // 미리보기 첫 행 — 메시지(와 안내) 다음 빈 줄 뒤
    body_rows: u32, // 그릴 미리보기 줄 수 — 상자가 작업영역보다 높으면 state.body 보다 적다(버튼 행이 화면 안에 남게)
    // 메시지를 상자 안쪽 폭으로 나눈 줄들(state.message 를 빌린다). msg_truncated 면 마지막 줄 끝에 「…」.
    msg_lines: [modal_box.max_wrap_rows][]const u8,
    msg_rows: u32,
    msg_truncated: bool,
    confirm_x: i32,
    confirm_fit: u32,
    alternate_x: i32,
    alternate_fit: u32,
    extra_x: i32,
    extra_fit: u32,
    cancel_x: i32,
    cancel_fit: u32,
};

/// 마커 "[" + key + "] "의 표시 폭(칸). key는 "Y"/"N"(1칸)이라 보통 4.
fn markerCols(key: []const u8) u32 {
    return 3 + overlay_input.displayCols(key); // "[" + key + "] "
}

fn buttonGeom(state: *const State, p: props.ChromeProps, tk: *const tokens.Tokens) ?ButtonGeom {
    const confirm_cols = markerCols(key_confirm) + overlay_input.displayCols(state.confirm_label);
    const alternate_cols = if (state.has_alternate) markerCols(key_alternate) + overlay_input.displayCols(state.alternate_label) else 0;
    const extra_cols = if (state.has_extra) markerCols(key_extra) + overlay_input.displayCols(state.extra_label) else 0;
    const cancel_cols = markerCols(key_cancel) + overlay_input.displayCols(state.cancel_label);
    const default_btn_cols = confirm_cols + 2 * btn_pad;
    const alternate_btn_cols = if (state.has_alternate) alternate_cols + 2 * btn_pad else 0;
    const extra_btn_cols = if (state.has_extra) extra_cols + 2 * btn_pad else 0;
    const cancel_btn_cols = cancel_cols + 2 * btn_pad;
    const btn_row_cols = default_btn_cols + btn_gap + alternate_btn_cols +
        (if (state.has_alternate) btn_gap else 0) + extra_btn_cols +
        (if (state.has_extra) btn_gap else 0) + cancel_btn_cols;
    var content_cols = @max(modal_box.widestLineCols(state.message), btn_row_cols);
    for (state.body) |line| content_cols = @max(content_cols, overlay_input.displayCols(line)); // 미리보기 줄도 폭에 반영
    // 안내 줄도 폭에 반영 — 넓은 창에서는 한 줄씩 그대로 서게(좁으면 아래에서 줄바꿈한다).
    for (state.notes) |note| content_cols = @max(content_cols, switch (note.fit) {
        .wrap => modal_box.widestLineCols(note.text),
        .path => overlay_input.displayCols(note.text),
    });
    // 폭은 행 수와 무관하다 — 먼저 한 행으로 재서 상자 안쪽 폭을 얻고, 그 폭으로 메시지를 나눈 뒤 실제 행 수로 다시 잰다.
    // 메시지가 안쪽 폭에 들어가면 한 줄 그대로다(짧은 확인은 예전 모양 그대로).
    const width_probe = modal_box.layout(content_cols, 1, p, tk) orelse return null;
    var msg_lines: [modal_box.max_wrap_rows][]const u8 = undefined;
    const wrapped = modal_box.wrapLine(state.message, width_probe.inner_cols, &msg_lines);
    var m: u32 = wrapped.rows;
    var msg_truncated = wrapped.truncated;
    // 안내 줄을 같은 안쪽 폭으로 나눈다 — 경로 줄은 한 행(그릴 때 가운데를 줄인다), 문장은 `wrapLine`(메시지와 같은 규칙).
    var note_lines: [max_note_rows]NoteLine = undefined;
    var notes_all: u32 = 0;
    var notes_overflow = false;
    note_loop: for (state.notes) |note| switch (note.fit) {
        .path => {
            if (notes_all == max_note_rows) {
                notes_overflow = true;
                break :note_loop;
            }
            note_lines[notes_all] = .{ .text = note.text, .path = true };
            notes_all += 1;
        },
        .wrap => {
            var parts: [modal_box.max_wrap_rows][]const u8 = undefined;
            const w = modal_box.wrapLine(note.text, width_probe.inner_cols, &parts);
            for (parts[0..w.rows], 0..) |line, i| {
                if (notes_all == max_note_rows) {
                    notes_overflow = true;
                    break :note_loop;
                }
                note_lines[notes_all] = .{ .text = line, .cut = w.truncated and i + 1 == w.rows };
                notes_all += 1;
            }
        },
    };
    if (notes_overflow and notes_all > 0) note_lines[notes_all - 1].cut = true;
    var k: u32 = notes_all;
    // 콘텐츠 행: 미리보기 없으면 m+2행([0..m)=메시지·m=빈줄·m+1=버튼); 있으면 [0..m)=메시지·m=빈줄·[m+1..m+1+n)=본문·
    // m+1+n=빈줄·m+2+n=버튼. m=1 이면 예전 배치(3행·4+n행) 그대로다.
    // 버튼도 안쪽 폭에 나눈다 — 순서대로(확인·대안·추가·취소) 채우고, 다음 버튼이 안 들어가면 다음 줄로 넘긴다. 예전에는
    // 한 줄로만 놓고 넘친 버튼을 잘라 생략했다 — 좁은 창의 종료 확인에서 「종료 및 세션 끝내기」가 잘리고 「취소」가
    // 사라졌다(실제 앱 캡처, 2026-10-05). 한 줄에 다 들어가면 예전 배치 그대로다.
    const btn_cols = [4]u32{ default_btn_cols, alternate_btn_cols, extra_btn_cols, cancel_btn_cols };
    const present = [4]bool{ true, state.has_alternate, state.has_extra, true };
    var row_of: [4]u32 = .{ 0, 0, 0, 0 };
    var row_cols: [4]u32 = .{ 0, 0, 0, 0 };
    var last_row: u32 = 0;
    for (btn_cols, present, 0..) |cols, here, i| {
        if (!here) continue;
        const cur = row_cols[last_row];
        if (cur > 0 and cur + btn_gap + cols > width_probe.inner_cols) last_row += 1;
        row_cols[last_row] = if (row_cols[last_row] == 0) cols else row_cols[last_row] + btn_gap + cols;
        row_of[i] = last_row;
    }
    const btn_rows: u32 = last_row + 1;
    var n: u32 = @intCast(state.body.len);
    // **버튼 행은 화면 안에 있어야 한다**(적대적 검증 2026-10-06). 상자는 작업영역보다 높으면 위를 지키고 아래가 잘린다
    // (`modal_box.layout` 의 y clamp) — 잘리는 것이 버튼 행이다. 메시지를 줄바꿈하게 된 뒤로 상자가 높아져, 420×240 창의
    // 붙여넣기 경고(메시지 5줄 + 미리보기 7줄)에서 취소 버튼이 y=240 으로 화면 밖이었다. 들어가는 행 수를 넘으면 미리보기
    // 줄부터, 그다음 메시지 줄을 줄인다(메시지는 한 줄은 남기고 마지막 줄을 「…」로 — view). 그래도 안 되면(한두 줄짜리
    // 창) 예전처럼 둔다.
    const fit_rows: u32 = blk: {
        const ws = props.workspaceRect(p.metrics);
        const ch = @max(p.metrics.cell_height_px, 1);
        break :blk ((ws.h -| 2 * @as(u32, p.shape.modal_padding_px)) / ch) -| 2; // 위아래 여백 한 줄씩
    };
    const rowsFor = struct {
        fn f(msg: u32, notes: u32, body: u32, btns: u32) u32 {
            return msg + (if (notes == 0) 0 else notes + 1) + (if (body == 0) 0 else body + 1) + 1 + btns;
        }
    }.f;
    // 줄이는 순서: 미리보기(내용을 다 안 봐도 결정할 수 있다) → 안내(끝부터, 한 행은 남긴다) → 메시지(한 행은 남긴다).
    // 안내는 확인의 대가를 밝히는 문장이라 미리보기보다 늦게 줄인다.
    while (rowsFor(m, k, n, btn_rows) > fit_rows and n > 0) n -= 1;
    while (rowsFor(m, k, n, btn_rows) > fit_rows and k > 1) k -= 1;
    while (rowsFor(m, k, n, btn_rows) > fit_rows and m > 1) {
        m -= 1;
        msg_truncated = true;
    }
    if (k > 0 and k < notes_all) note_lines[k - 1].cut = true;
    const note_row: u32 = m + 1;
    const body_row: u32 = if (k == 0) m + 1 else m + 1 + k + 1;
    // 콘텐츠 행: [0..m)=메시지·m=빈줄·(안내 k줄·빈줄)·(미리보기 n줄·빈줄)·버튼 btn_rows줄. 안내·미리보기가 없으면 예전 배치 그대로다.
    const content_rows: u32 = rowsFor(m, k, n, btn_rows);
    const btn_row: u32 = if (n == 0) body_row else body_row + n + 1; // 본문 뒤 빈 줄 다음
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    // 줄마다 가운데. 버튼 하나가 안쪽 폭보다 넓으면(아주 좁은 창/긴 라벨) fill이 rasterize bbox를 패널 밖으로 키운다 →
    // 폭을 clamp하고 0이면(완전히 밖) 호출자가 그 버튼을 생략(그땐 키보드 Esc/Y/N). inner=[inner_x, inner_x+inner_cols×cw).
    const inner_right = box.inner_x + @as(i32, @intCast(box.inner_cols * box.cw));
    var cursor: [4]i32 = undefined;
    for (&cursor, row_cols) |*c, cols| c.* = modal_box.centerX(box, cols);
    var xs: [4]i32 = .{ 0, 0, 0, 0 };
    for (btn_cols, present, 0..) |cols, here, i| {
        if (!here) continue;
        xs[i] = cursor[row_of[i]];
        cursor[row_of[i]] += @intCast((cols + btn_gap) * box.cw);
    }
    const group_x = xs[0];
    const alternate_x = xs[1];
    const extra_x = xs[2];
    const cancel_x = xs[3];
    return .{
        .box = box,
        .btn_row = btn_row,
        .btn_rows = btn_rows,
        .confirm_row = btn_row + row_of[0],
        .alternate_row = btn_row + row_of[1],
        .extra_row = btn_row + row_of[2],
        .cancel_row = btn_row + row_of[3],
        .note_row = note_row,
        .note_rows = k,
        .note_lines = note_lines,
        .body_row = body_row,
        .body_rows = n,
        .msg_lines = msg_lines,
        .msg_rows = m,
        .msg_truncated = msg_truncated,
        .confirm_x = group_x,
        .confirm_fit = fitButtonCols(group_x, default_btn_cols, box.cw, inner_right),
        .alternate_x = alternate_x,
        .alternate_fit = if (state.has_alternate) fitButtonCols(alternate_x, alternate_btn_cols, box.cw, inner_right) else 0,
        .extra_x = extra_x,
        .extra_fit = if (state.has_extra) fitButtonCols(extra_x, extra_btn_cols, box.cw, inner_right) else 0,
        .cancel_x = cancel_x,
        .cancel_fit = fitButtonCols(cancel_x, cancel_btn_cols, box.cw, inner_right),
    };
}

/// 마우스 클릭(backing px) hit-test — 확인 버튼 위면 confirmed, 취소 버튼 위면 cancelled, **패널 밖이면 cancelled**
/// (바깥 클릭 dismiss 관례), 패널 안 비-버튼이면 null(소비, 무동작). 닫혀 있거나 좌표 비유한이면 null. view와 같은
/// buttonGeom을 써 그려진 버튼과 클릭 영역이 항상 일치한다(view↔hitTest 단일 레이아웃). host가 반환 intent를
/// confirm_accept/confirm_cancel로 디스패치한다(키보드 경로와 동일 후처리).
pub fn buttonAtPoint(state: *const State, p: props.ChromeProps, tk: *const tokens.Tokens, x_px: f64, y_px: f64) ?Action {
    if (!state.open) return null;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const g = buttonGeom(state, p, tk) orelse return null;
    const b = g.box.rect;
    // 비교는 **f64 도메인**으로 한다 — x_px/y_px를 @intFromFloat(i32)로 바꾸면 isFinite여도 i32 범위를 넘는 값(거대
    // backing/스케일·합성 좌표)에서 안전 빌드 패닉(illegal behavior)이다. 형제 hit-test(app_session.collapsedToggleRect)도
    // 같은 이유로 f64로 비교한다(@floatFromInt(rect)). 폭도 f64로 곱해 u32 overflow까지 회피.
    const fx = @as(f64, @floatFromInt(b.x));
    const fy = @as(f64, @floatFromInt(b.y));
    // 패널 밖 → 취소(바깥 클릭 dismiss).
    if (x_px < fx or x_px >= fx + @as(f64, @floatFromInt(b.w)) or y_px < fy or y_px >= fy + @as(f64, @floatFromInt(b.h))) return .cancelled;
    // 버튼마다 **자기 행**의 y 범위 안에서 x 범위(fit 폭)를 본다 — 버튼이 여러 줄로 나뉠 수 있다(view 와 같은 배치).
    const cw_f = @as(f64, @floatFromInt(g.box.cw));
    const ch_f = @as(f64, @floatFromInt(g.box.ch));
    const Hit = struct {
        fn at(box: modal_box.Box, row: u32, x: i32, fit: u32, cw: f64, ch: f64, px: f64, py: f64) bool {
            if (fit == 0) return false;
            const ry = @as(f64, @floatFromInt(modal_box.rowY(box, row)));
            const bx = @as(f64, @floatFromInt(x));
            return py >= ry and py < ry + ch and px >= bx and px < bx + @as(f64, @floatFromInt(fit)) * cw;
        }
    };
    if (Hit.at(g.box, g.confirm_row, g.confirm_x, g.confirm_fit, cw_f, ch_f, x_px, y_px)) return .confirmed;
    if (state.has_alternate and Hit.at(g.box, g.alternate_row, g.alternate_x, g.alternate_fit, cw_f, ch_f, x_px, y_px)) return .alternate;
    if (state.has_extra and Hit.at(g.box, g.extra_row, g.extra_x, g.extra_fit, cw_f, ch_f, x_px, y_px)) return .extra;
    if (Hit.at(g.box, g.cancel_row, g.cancel_x, g.cancel_fit, cw_f, ch_f, x_px, y_px)) return .cancelled;
    return null; // 패널 안, 버튼 아님 → 소비(무동작)
}

/// 버튼 배경 fill 폭(칸)을 박스 안쪽 우측 끝(right_px)까지로 줄인다 — x 위치에서 cols칸이 안쪽을 넘으면 안 넘게.
/// x가 이미 끝을 넘었으면 0(호출자가 그 버튼을 생략). 폭이 충분하면 cols 그대로(정상 창 무변화).
fn fitButtonCols(x: i32, cols: u32, cw: u32, right_px: i32) u32 {
    if (x >= right_px or cw == 0) return 0;
    const avail: u32 = @intCast(@divFloor(right_px - x, @as(i32, @intCast(cw))));
    return @min(cols, avail);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 헤드리스로 (1) 상태 전이+라벨 주입 (2) 입력→intent 2-갈래 (3) view가 버튼 다이얼로그 구조를 내는지 증명한다.

test "confirm state: show가 메시지+버튼 라벨을 주입, dismiss로 닫힘(재사용 — 라벨 가변)" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("정말 삭제할까요?", .{ .confirm = "삭제", .cancel = "취소" });
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("정말 삭제할까요?", s.message);
    try std.testing.expectEqualStrings("삭제", s.confirm_label); // 닫기 전용이 아니라 라벨 주입(재사용)
    try std.testing.expectEqualStrings("취소", s.cancel_label);
    s.dismiss();
    try std.testing.expect(!s.open);
    // 다시 열면 **새 라벨로 갈린다** — 앞 확인의 라벨이 남지 않는다.
    // (예전에는 여기서 `.{}` 로 부르고 기본값 `"확인"` 을 단정했는데, 그 기본값은 comptime 에
    //  얼어붙는 함정이라 없앴다. 검증할 것은 "기본값이 무엇인가" 가 아니라 "주입이 갈아끼우는가" 다.)
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqualStrings("ok", s.confirm_label);
    try std.testing.expectEqualStrings("no", s.cancel_label);
}

test "confirm handle: Enter/Y=confirmed · Esc/N=cancelled · 닫힘이면 null · 다른 키는 소비" {
    var s = State{};
    // 닫혀 있으면 무동작(라우팅 안 가로챔).
    try std.testing.expect(handle(.{ .key = .enter }, &s) == null);

    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .enter }, &s).?);
    try std.testing.expect(!s.open); // confirmed면 닫힘

    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .escape }, &s).?);
    try std.testing.expect(!s.open); // cancelled면 닫힘

    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .char, .codepoint = 'y' }, &s).?);
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .char, .codepoint = 'Y' }, &s).?);
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .char, .codepoint = 'n' }, &s).?);
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .char, .codepoint = 'N' }, &s).?);

    // 다른 글자는 소비만(intent 없음, 모달이라 뒤로 안 샘) — 여전히 열려 있음.
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expect(handle(.{ .key = .char, .codepoint = 'a' }, &s) == null);
    try std.testing.expect(s.open);
}

test "confirm handle: ←/→로 포커스 이동, Enter는 포커스된 버튼 실행 (Esc는 항상 취소)" {
    var s = State{};
    s.show("x", .{ .confirm = "ok", .cancel = "no" }); // 기본 포커스 = confirm
    try std.testing.expectEqual(Focus.confirm, s.focused);

    // → 이동 → cancel 포커스(소비, intent 없음 — 재렌더는 host).
    try std.testing.expect(handle(.{ .key = .right }, &s) == null);
    try std.testing.expectEqual(Focus.cancel, s.focused);
    try std.testing.expect(s.open); // 포커스 이동은 안 닫음

    // 이 상태에서 Enter → 포커스된 cancel 실행(닫기 아님!).
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .enter }, &s).?);
    try std.testing.expect(!s.open);

    // ← 도 토글(버튼 둘뿐) — confirm→cancel.
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    try std.testing.expect(handle(.{ .key = .left }, &s) == null);
    try std.testing.expectEqual(Focus.cancel, s.focused);
    // 다시 ← → confirm으로.
    try std.testing.expect(handle(.{ .key = .left }, &s) == null);
    try std.testing.expectEqual(Focus.confirm, s.focused);
    // confirm 포커스에서 Enter → confirmed.
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .enter }, &s).?);

    // Esc는 포커스와 무관하게 항상 취소.
    s.show("x", .{ .confirm = "ok", .cancel = "no" });
    _ = handle(.{ .key = .right }, &s); // cancel 포커스로 옮겨도
    s.focused = .confirm; // 다시 confirm 포커스라도
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .escape }, &s).?);
}

test "confirm three choices expose stable primary alternate cancel actions" {
    var s = State{};
    s.showChoices("dirty", .{ .primary = "저장", .alternate = "버리기", .cancel = "취소" });
    try std.testing.expect(s.has_alternate);
    try std.testing.expectEqual(Action.confirmed, handle(.{ .key = .enter }, &s).?);

    s.showChoices("dirty", .{ .primary = "저장", .alternate = "버리기", .cancel = "취소" });
    try std.testing.expect(handle(.{ .key = .right }, &s) == null);
    try std.testing.expectEqual(Focus.alternate, s.focused);
    try std.testing.expectEqual(Action.alternate, handle(.{ .key = .enter }, &s).?);

    s.showChoices("dirty", .{ .primary = "저장", .alternate = "버리기", .cancel = "취소" });
    try std.testing.expectEqual(Action.alternate, handle(.{ .key = .char, .codepoint = 'd' }, &s).?);
    s.showChoices("dirty", .{ .primary = "저장", .alternate = "버리기", .cancel = "취소" });
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .escape }, &s).?);
}

test "confirm four choices: extra 자리가 키·순회·클릭에 다 서고, 없으면 그 자리가 아예 없다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 1200, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const four = Choices{ .primary = "비교", .alternate = "덮어쓰기", .cancel = "계속 편집", .extra = "다시 읽기" };

    // ⑴ **글자 키**가 그 자리를 실행한다. `Y`·`D`·`N` 과 겹치지 않는 `R` 이다.
    var s = State{};
    s.showChoices("충돌", four);
    try std.testing.expect(s.has_extra);
    try std.testing.expectEqualStrings("다시 읽기", s.extra_label);
    try std.testing.expectEqual(Action.extra, handle(.{ .key = .char, .codepoint = 'r' }, &s).?);

    // ⑵ **순회가 네 자리를 돈다**(그려진 순서) — 건너뛰면 포커스가 보이지 않는 버튼에 얹힌다.
    s.showChoices("충돌", four);
    try std.testing.expect(handle(.{ .key = .right }, &s) == null);
    try std.testing.expectEqual(Focus.alternate, s.focused);
    try std.testing.expect(handle(.{ .key = .right }, &s) == null);
    try std.testing.expectEqual(Focus.extra, s.focused);
    try std.testing.expect(handle(.{ .key = .right }, &s) == null);
    try std.testing.expectEqual(Focus.cancel, s.focused);
    try std.testing.expect(handle(.{ .key = .left }, &s) == null);
    try std.testing.expectEqual(Focus.extra, s.focused); // 왼쪽도 같은 순서를 되돌아온다
    try std.testing.expectEqual(Action.extra, handle(.{ .key = .enter }, &s).?);

    // ⑶ **Esc 는 여전히 취소다** — 네 번째 자리를 만든 이유가 그것이다(`cancel` 에 행동을 못 놓는다).
    s.showChoices("충돌", four);
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .escape }, &s).?);

    // ⑷ **그려지고, 그 자리를 클릭하면 같은 Action 이다**(view↔hitTest 단일 레이아웃).
    s.showChoices("충돌", four);
    _ = handle(.{ .key = .right }, &s); // alternate
    _ = handle(.{ .key = .right }, &s); // extra ← 포커스를 옮겨 accent 로 찾는다
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, p, &tk, arena, &out);
    var extra_rect: ?draw.Rect = null;
    var fills: usize = 0;
    for (out.items) |op| switch (op) {
        .fill => |f| {
            fills += 1;
            if (f.role == .focus_accent) extra_rect = f.rect;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), fills); // 버튼 넷이 다 배경을 깐다
    const er = extra_rect.?;
    const cx = @as(f64, @floatFromInt(er.x)) + @as(f64, @floatFromInt(er.w)) / 2.0;
    const cy = @as(f64, @floatFromInt(er.y)) + @as(f64, @floatFromInt(er.h)) / 2.0;
    try std.testing.expectEqual(@as(?Action, .extra), buttonAtPoint(&s, p, &tk, cx, cy));

    // ⑸ **세 갈래에는 그 자리가 아예 없다** — 라벨도 비고, `R` 도 안 먹고, 배경도 셋만 깔린다.
    var three = State{};
    three.showChoices("종료", .{ .primary = "종료", .alternate = "종료 및 세션 끝내기", .cancel = "취소" });
    try std.testing.expect(!three.has_extra);
    try std.testing.expectEqualStrings("", three.extra_label);
    try std.testing.expectEqual(@as(?Action, null), handle(.{ .key = .char, .codepoint = 'r' }, &three));
    var out3: std.ArrayList(draw.Op) = .empty;
    try view(&three, p, &tk, arena, &out3);
    var fills3: usize = 0;
    for (out3.items) |op| switch (op) {
        .fill => fills3 += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), fills3);
}

test "confirm view: 닫힘이면 ops 0, 열림이면 패널(quad)+accent 기본 버튼+메시지·버튼·키 텍스트" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show("실행 중인 명령이 있습니다.", .{ .confirm = "닫기", .cancel = "취소" });
    try view(&s, p, &tk, arena, &out);
    // 프레임이 먼저(quad 배경 — 외곽선 별도 op 없음).
    try std.testing.expect(out.items[0] == .quad);
    // 구조: 두 버튼 배경 fill(기본=accent, 보조=tab_hover_bg) + 메시지 + 단축키 통합 버튼 라벨("[Y] 닫기"/"[N] 취소").
    // 영어 단어(Enter/Esc) 줄은 없다 — 단축키는 [Y]/[N]로 라벨에 통합. 순서에 무관하게 존재 확인.
    var saw_accent_fill = false;
    var saw_cancel_fill = false;
    var saw_msg = false;
    var saw_confirm = false;
    var saw_cancel = false;
    for (out.items) |op| switch (op) {
        .fill => |f| {
            if (f.role == .focus_accent) saw_accent_fill = true;
            if (f.role == .tab_hover_bg) saw_cancel_fill = true;
        },
        .text => |t| {
            const txt = t.runs[0].text;
            if (std.mem.eql(u8, txt, "실행 중인 명령이 있습니다.")) saw_msg = true;
            if (std.mem.eql(u8, txt, "[Y] 닫기")) saw_confirm = true; // 단축키 통합 라벨
            if (std.mem.eql(u8, txt, "[N] 취소")) saw_cancel = true;
        },
        else => {},
    };
    try std.testing.expect(saw_accent_fill); // 기본 버튼이 accent 배경으로 강조됨
    try std.testing.expect(saw_cancel_fill); // 보조 버튼(취소)도 배경 fill로 버튼 느낌
    try std.testing.expect(saw_msg and saw_confirm and saw_cancel); // 메시지 + [Y]/[N] 버튼 라벨
    // 박스는 터미널 영역(사이드바 오른쪽) 안. 기하 엣지케이스는 modal_box.zig 테스트가 단일 출처로 커버.
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
}

test "confirm view: body(미리보기)가 있으면 메시지·본문·버튼 순으로 그리고 버튼이 본문 아래로 내려간다" {
    // 이 테스트가 증명하는 것: 붙여넣기 미리보기(body 줄들)가 메시지와 버튼 사이에 그려지고(각 줄 배경 fill +
    // muted 텍스트), 버튼 행이 본문 줄 수만큼 아래로 내려가며(btn_row 동적), 클릭 hit-test도 같은 위치를 따라간다
    // (view↔hitTest 단일 레이아웃). body가 없으면 기존 3행 레이아웃 그대로.
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = State{};
    // 미리보기 없음(기준) — 박스 높이.
    var out0: std.ArrayList(draw.Op) = .empty;
    s.show("붙여넣을까요?", .{ .confirm = "붙여넣기", .cancel = "취소" });
    try view(&s, p, &tk, arena, &out0);
    const h0 = out0.items[0].quad.rect.h;

    // 미리보기 2줄 주입 후.
    var out1: std.ArrayList(draw.Op) = .empty;
    const body = [_][]const u8{ "echo hi", "rm -rf ~/important" };
    s.body = &body;
    try view(&s, p, &tk, arena, &out1);

    // 박스가 미리보기(2줄) + 빈 줄 1개 만큼 더 커진다(정확히 3행 × ch).
    try std.testing.expectEqual(h0 + 3 * @as(u32, 16), out1.items[0].quad.rect.h);

    // 본문 텍스트 두 줄이 muted로 그려지고, 각 줄에 배경 fill이 깔린다.
    var saw_line0 = false;
    var saw_line1 = false;
    var body_fills: usize = 0;
    var confirm_label_y: i32 = -1;
    var line0_y: i32 = -1;
    for (out1.items) |op| switch (op) {
        .text => |t| {
            const txt = t.runs[0].text;
            if (std.mem.eql(u8, txt, "echo hi")) {
                saw_line0 = true;
                line0_y = t.origin.y;
            }
            if (std.mem.eql(u8, txt, "rm -rf ~/important")) saw_line1 = true;
            if (std.mem.eql(u8, txt, "[Y] 붙여넣기")) confirm_label_y = t.origin.y;
        },
        .fill => |f| if (f.role == .tab_hover_bg) {
            body_fills += 1;
        },
        else => {},
    };
    try std.testing.expect(saw_line0 and saw_line1); // 미리보기 두 줄
    try std.testing.expect(body_fills >= 2); // 본문 줄 배경 fill(버튼 fill과 별개로 최소 2)
    try std.testing.expect(confirm_label_y > line0_y); // 버튼이 미리보기 아래

    // 클릭 hit-test도 내려간 버튼 위치를 따라간다 — 확인 버튼 fill 중심 클릭이 confirmed.
    var confirm_rect: ?draw.Rect = null;
    for (out1.items) |op| if (op == .fill and op.fill.role == .focus_accent) {
        confirm_rect = op.fill.rect;
    };
    const cr = confirm_rect.?;
    const cx = @as(f64, @floatFromInt(cr.x)) + @as(f64, @floatFromInt(cr.w)) / 2.0;
    const cy = @as(f64, @floatFromInt(cr.y)) + @as(f64, @floatFromInt(cr.h)) / 2.0;
    try std.testing.expectEqual(@as(?Action, .confirmed), buttonAtPoint(&s, p, &tk, cx, cy));
}

test "confirm view: 포커스가 accent 강조를 이동시킨다(←/→ 선택 가시화)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // accent(focus_accent) fill의 x를 찾는 헬퍼 — 포커스된 버튼 위치.
    const findAccentX = struct {
        fn run(ops: []const draw.Op) i32 {
            for (ops) |op| switch (op) {
                .fill => |f| if (f.role == .focus_accent) return f.rect.x,
                else => {},
            };
            return -1;
        }
    }.run;

    var s = State{};
    var out_confirm: std.ArrayList(draw.Op) = .empty;
    s.show("실행 중인 명령이 있습니다.", .{ .confirm = "닫기", .cancel = "취소" }); // 기본 포커스 = confirm(왼쪽 버튼)
    try view(&s, p, &tk, arena, &out_confirm);
    const accent_x_confirm = findAccentX(out_confirm.items);

    var out_cancel: std.ArrayList(draw.Op) = .empty;
    s.focused = .cancel; // 포커스를 취소(오른쪽 버튼)로
    try view(&s, p, &tk, arena, &out_cancel);
    const accent_x_cancel = findAccentX(out_cancel.items);

    try std.testing.expect(accent_x_confirm >= 0 and accent_x_cancel >= 0);
    // 포커스가 오른쪽(취소) 버튼으로 가면 accent 강조도 오른쪽으로 이동한다.
    try std.testing.expect(accent_x_cancel > accent_x_confirm);
}

test "confirm view: 좁은 창에서 버튼 배경이 패널(quad) 밖으로 안 넘친다 — fill clamp 회귀" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // term 영역 = 140 − 40 = 100px, cw=8 → term_cols=12, avail=12. 버튼 행(≈22칸)이 inner_cols(8)보다 넓어
    // clamp 없으면 fill이 패널 밖으로 넘쳐 rasterize 격자를 키운다(사이드바/터미널 침범).
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 140, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    s.show("닫을까요?", .{ .confirm = "닫기", .cancel = "취소" });
    try view(&s, p, &tk, arena, &out);

    // 패널(quad) 우측 끝.
    var panel_right: i32 = 0;
    for (out.items) |op| if (op == .quad) {
        panel_right = op.quad.rect.x + @as(i32, @intCast(op.quad.rect.w));
    };
    try std.testing.expect(panel_right > 0);
    // 모든 배경 fill(버튼)이 패널 우측 끝을 넘지 않아야 한다(넘으면 격자 확장 → 패널 밖 그림).
    for (out.items) |op| switch (op) {
        .fill => |f| try std.testing.expect(f.rect.x + @as(i32, @intCast(f.rect.w)) <= panel_right),
        else => {},
    };
}

test "confirm view: 네 버튼은 좁은 창에서 줄을 나눠 다 그려지고, 패널 밖으로 안 넘치며 서로 안 겹친다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 저장 충돌 상자의 실제 문구·라벨(한국어) — CJK 는 두 칸이라 폭이 가장 불리한 판이다.
    const msg = "파일이 외부에서 바뀌었습니다. 덮어쓰면 그 변경이, 다시 읽으면 방금 친 것이 사라집니다(되돌리기로 돌아옵니다)";
    const four = Choices{ .primary = "비교", .alternate = "덮어쓰기", .cancel = "계속 편집", .extra = "다시 읽기" };

    // ⑴ **어느 폭에서도 넷이 다 그려진다** — 한 줄에 안 들어가면 순서대로 다음 줄로 넘긴다. 예전에는 500px 아래에서
    //    뒤 버튼이 생략됐다(키만 살아 있었다). 그리고 **어느 폭에서도 패널 밖으로 넘치지 않고** 버튼끼리 겹치지 않는다 —
    //    넘치면 rasterize 격자가 커져 사이드바·터미널을 침범한다(두 버튼 판의 그 회귀와 같은 부류).
    for ([_]u32{ 2560, 1600, 1200, 900, 700, 500, 360, 200 }) |w| {
        const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = w, .backing_height_px = 600 } };
        var s = State{};
        s.showChoices(msg, four);
        var out: std.ArrayList(draw.Op) = .empty;
        try view(&s, p, &tk, arena, &out);
        var panel_right: i32 = 0;
        var buttons: usize = 0;
        for (out.items) |op| {
            switch (op) {
                .quad => |q| panel_right = q.rect.x + @as(i32, @intCast(q.rect.w)),
                .fill => buttons += 1,
                else => {},
            }
        }
        try std.testing.expect(panel_right > 0);
        var rects: [4]draw.Rect = undefined;
        var k: usize = 0;
        for (out.items) |op| {
            if (op == .fill) {
                try std.testing.expect(op.fill.rect.x + @as(i32, @intCast(op.fill.rect.w)) <= panel_right);
                if (k < rects.len) rects[k] = op.fill.rect;
                k += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 4), buttons);
        // 서로 안 겹친다 — 같은 행이면 x 구간이 떨어져 있고, 다른 행이면 y 가 다르다.
        for (rects[0..4], 0..) |a, i| for (rects[i + 1 .. 4]) |b| {
            const same_row = a.y == b.y;
            const apart = a.x + @as(i32, @intCast(a.w)) <= b.x or b.x + @as(i32, @intCast(b.w)) <= a.x;
            try std.testing.expect(!same_row or apart);
        };
    }

    // ⑵ **줄어들어도 키는 그대로다.** 버튼이 생략된 폭에서도 `R`·Esc 가 그 갈래를 실행한다 —
    //    그리기와 판정이 갈린 자리가 없어야 한다(생략은 그리기의 사정이다).
    var narrow = State{};
    narrow.showChoices(msg, four);
    try std.testing.expectEqual(Action.extra, handle(.{ .key = .char, .codepoint = 'r' }, &narrow).?);
    narrow.showChoices(msg, four);
    try std.testing.expectEqual(Action.cancelled, handle(.{ .key = .escape }, &narrow).?);
}

test "confirm buttonAtPoint: 그려진 버튼 중심 클릭이 같은 Action — view↔hitTest 단일 레이아웃 일치" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 800, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = State{};
    // 닫힌 모달은 어디를 클릭해도 null(라우팅 안 가로챔).
    try std.testing.expectEqual(@as(?Action, null), buttonAtPoint(&s, p, &tk, 400, 300));

    s.show("실행 중인 명령이 있습니다.", .{ .confirm = "닫기", .cancel = "취소" }); // 기본 포커스=confirm
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, p, &tk, arena, &out);

    // view가 그린 버튼 fill rect를 ground truth로 — 포커스=confirm이라 focus_accent=확인, tab_hover_bg=취소.
    var confirm_rect: ?draw.Rect = null;
    var cancel_rect: ?draw.Rect = null;
    var panel_rect: ?draw.Rect = null;
    for (out.items) |op| switch (op) {
        .quad => |q| panel_rect = q.rect,
        .fill => |f| {
            if (f.role == .focus_accent) confirm_rect = f.rect;
            if (f.role == .tab_hover_bg) cancel_rect = f.rect;
        },
        else => {},
    };
    const cr = confirm_rect.?;
    const xr = cancel_rect.?;
    const pr = panel_rect.?;

    const centerX = struct {
        fn run(r: draw.Rect) f64 {
            return @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) / 2.0;
        }
    }.run;
    const centerY = struct {
        fn run(r: draw.Rect) f64 {
            return @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2.0;
        }
    }.run;

    // 확인 버튼 중심 클릭 → confirmed, 취소 버튼 중심 클릭 → cancelled.
    try std.testing.expectEqual(@as(?Action, .confirmed), buttonAtPoint(&s, p, &tk, centerX(cr), centerY(cr)));
    try std.testing.expectEqual(@as(?Action, .cancelled), buttonAtPoint(&s, p, &tk, centerX(xr), centerY(xr)));
    // 패널 밖(좌상단 원점) → cancelled(바깥 클릭 dismiss 관례).
    try std.testing.expectEqual(@as(?Action, .cancelled), buttonAtPoint(&s, p, &tk, 0, 0));
    // 패널 안이지만 버튼 행이 아닌 메시지 행(패널 top+2px) → null(소비, 무동작).
    try std.testing.expectEqual(@as(?Action, null), buttonAtPoint(&s, p, &tk, centerX(pr), @floatFromInt(pr.y + 2)));
    // 비유한 좌표 방어.
    try std.testing.expectEqual(@as(?Action, null), buttonAtPoint(&s, p, &tk, std.math.nan(f64), 300));
}

// 좁은 창의 종료 확인(버튼 셋)에서 「종료 및 세션 끝내기」가 잘리고 「취소」가 사라졌다(실제 앱 캡처 420px, 2026-10-05).
test "confirm view: 버튼이 한 줄에 안 들어가면 다음 줄로 넘기고, 넘긴 버튼도 그 자리에서 눌린다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 420, .backing_height_px = 360 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = State{};
    s.showChoices("maru를 종료할까요? 열린 터미널은 백그라운드에서 유지됩니다.", .{ .primary = "종료", .alternate = "종료 및 세션 끝내기", .cancel = "취소" });
    const g = buttonGeom(&s, p, &tk).?;
    try std.testing.expect(g.btn_rows > 1);
    try std.testing.expect(g.confirm_fit > 0 and g.alternate_fit > 0 and g.cancel_fit > 0); // 셋 다 그려진다
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, p, &tk, arena, &out);
    var panel: ?draw.Rect = null;
    for (out.items) |op| if (op == .quad) {
        panel = op.quad.rect;
    };
    const pr = panel.?;
    // 버튼마다 자기 가운데를 누르면 그 동작이다 — 넘긴 줄의 버튼도 그려진 자리에서 눌린다.
    const Probe = struct { row: u32, x: i32, fit: u32, want: Action };
    for ([_]Probe{
        .{ .row = g.confirm_row, .x = g.confirm_x, .fit = g.confirm_fit, .want = .confirmed },
        .{ .row = g.alternate_row, .x = g.alternate_x, .fit = g.alternate_fit, .want = .alternate },
        .{ .row = g.cancel_row, .x = g.cancel_x, .fit = g.cancel_fit, .want = .cancelled },
    }) |b| {
        const cx = @as(f64, @floatFromInt(b.x)) + @as(f64, @floatFromInt(b.fit * g.box.cw)) / 2.0;
        const cy = @as(f64, @floatFromInt(modal_box.rowY(g.box, b.row))) + @as(f64, @floatFromInt(g.box.ch)) / 2.0;
        try std.testing.expectEqual(@as(?Action, b.want), buttonAtPoint(&s, p, &tk, cx, cy));
        // 그 버튼은 패널 안이다.
        try std.testing.expect(b.x >= pr.x and b.x + @as(i32, @intCast(b.fit * g.box.cw)) <= pr.x + @as(i32, @intCast(pr.w)));
        try std.testing.expect(cy < @as(f64, @floatFromInt(pr.y + @as(i32, @intCast(pr.h)))));
    }
    // 한 줄에 다 들어가는 넓은 창에서는 예전 배치 그대로다(한 줄).
    const wide = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 1200, .backing_height_px = 600 } };
    const gw = buttonGeom(&s, wide, &tk).?;
    try std.testing.expectEqual(@as(u32, 1), gw.btn_rows);
    try std.testing.expect(gw.confirm_row == gw.cancel_row and gw.alternate_row == gw.cancel_row);
}

// 메시지가 상자보다 길면 한 줄로 그려 상자 밖으로 넘쳤다 — 기본 960pt 창(셀 8px·사이드바 180px, 안쪽 약 90칸)에서
// 영어 붙여넣기 경고(104칸)·원격 삭제 경고(96칸)·LSP 신뢰 확인(약 105칸+서버 이름)이 창 가장자리에서 잘렸다
// (2026-10-05 실측). 상자 안쪽 폭으로 나누고, 버튼과 클릭 영역이 그 줄 수만큼 따라 내려간다.
test "confirm view: 상자보다 긴 메시지는 안쪽 폭으로 나뉘어 패널 안에 다 들고, 버튼과 클릭이 따라 내려간다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 960, .backing_height_px = 600 } };
    const messages = [_][]const u8{
        "The pasted content has newlines or control characters, so a command could run immediately. Paste anyway?",
        "이 저장소에서 /opt/homebrew/bin/rust-analyzer-nightly-aarch64-apple-darwin 를 실행할까요? 언어 서버는 저장소의 설정을 읽고 빌드를 실행할 수 있습니다.",
    };
    for (messages) |message| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var s = State{};
        s.show(message, .{ .confirm = "ok", .cancel = "no" });
        try std.testing.expect(overlay_input.displayCols(message) > 90); // 한 줄이면 넘치는 길이다

        const g = buttonGeom(&s, p, &tk).?;
        try std.testing.expect(g.msg_rows > 1);
        try std.testing.expect(!g.msg_truncated);
        try std.testing.expectEqual(g.msg_rows + 1, g.btn_row); // 버튼은 마지막 줄 다음 빈 줄 뒤
        // 줄마다 안쪽 폭 안이고, 다시 이으면 원문이다(공백에서 끊었으므로 공백 하나로 잇는다).
        var joined: std.ArrayList(u8) = .empty;
        for (g.msg_lines[0..g.msg_rows], 0..) |line, i| {
            try std.testing.expect(overlay_input.displayCols(line) <= g.box.inner_cols);
            if (i > 0) try joined.append(arena, ' ');
            try joined.appendSlice(arena, line);
        }
        try std.testing.expectEqualStrings(message, joined.items);

        var out: std.ArrayList(draw.Op) = .empty;
        try view(&s, p, &tk, arena, &out);
        var panel: ?draw.Rect = null;
        var confirm_rect: ?draw.Rect = null;
        for (out.items) |op| switch (op) {
            .quad => |q| panel = q.rect,
            .fill => |f| if (f.role == .focus_accent) {
                confirm_rect = f.rect;
            },
            else => {},
        };
        const pr = panel.?;
        // 모든 글자가 패널 안이다 — 예전에는 메시지가 패널 오른쪽 밖으로 나갔다.
        var text_ops: usize = 0;
        for (out.items) |op| if (op == .text) {
            const t = op.text;
            const cols = overlay_input.displayCols(t.runs[0].text);
            try std.testing.expect(t.origin.x >= pr.x);
            try std.testing.expect(t.origin.x + @as(i32, @intCast(cols * 8)) <= pr.x + @as(i32, @intCast(pr.w)));
            text_ops += 1;
        };
        try std.testing.expectEqual(@as(usize, g.msg_rows) + 2, text_ops); // 메시지 줄들 + 버튼 라벨 둘
        // 내려간 확인 버튼의 가운데를 누르면 확인이다 — 그리기와 클릭이 같은 배치를 본다.
        const cr = confirm_rect.?;
        const cx = @as(f64, @floatFromInt(cr.x)) + @as(f64, @floatFromInt(cr.w)) / 2.0;
        const cy = @as(f64, @floatFromInt(cr.y)) + @as(f64, @floatFromInt(cr.h)) / 2.0;
        try std.testing.expectEqual(@as(?Action, .confirmed), buttonAtPoint(&s, p, &tk, cx, cy));
    }
}

// 브라우저 권한 확인은 페이지 URL 을 그대로 싣는다 — 공백 없는 토큰이 상자보다 길 수 있고 길이에 끝이 없다.
test "confirm wrap: 공백 없는 긴 토큰은 글자 경계에서 자르고, 줄 상한을 넘으면 마지막 줄이 「…」로 끝난다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 960, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (1) 한글만 이어진 긴 토큰 — 2칸 글자 경계에서 자른다(코드포인트를 쪼개지 않는다).
    const hangul = "가" ** 100; // 200칸
    var s = State{};
    s.show(hangul, .{ .confirm = "ok", .cancel = "no" });
    var g = buttonGeom(&s, p, &tk).?;
    try std.testing.expect(g.msg_rows >= 3);
    var total: usize = 0;
    for (g.msg_lines[0..g.msg_rows]) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(overlay_input.displayCols(line) <= g.box.inner_cols);
        total += line.len;
    }
    try std.testing.expectEqual(hangul.len, total); // 잃은 글자가 없다

    // (2) 끝없이 긴 URL — 상한 줄 수에서 멈추고 마지막 줄이 「…」로 끝나며, 그 줄도 안쪽 폭 안이다.
    const url = "Allow access to https://example.com/" ++ "a" ** 2000 ++ " ?";
    s.show(url, .{ .confirm = "ok", .cancel = "no" });
    g = buttonGeom(&s, p, &tk).?;
    try std.testing.expectEqual(modal_box.max_wrap_rows, g.msg_rows);
    try std.testing.expect(g.msg_truncated);
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, p, &tk, arena, &out);
    var last_line: ?[]const u8 = null;
    var last_y: i32 = std.math.minInt(i32);
    const btn_y = modal_box.rowY(g.box, g.btn_row);
    for (out.items) |op| if (op == .text) {
        const t = op.text;
        if (t.origin.y < btn_y and t.origin.y > last_y) {
            last_y = t.origin.y;
            last_line = t.runs[0].text;
        }
    };
    const shown = last_line.?;
    try std.testing.expect(std.mem.endsWith(u8, shown, modal_box.ellipsis));
    try std.testing.expect(overlay_input.displayCols(shown) <= g.box.inner_cols);
}

test "confirm wrap: 짧은 메시지는 예전 배치 그대로고, 미리보기가 있으면 메시지 줄 수만큼 함께 내려간다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 960, .backing_height_px = 600 } };
    var s = State{};
    s.show("닫을까요?", .{ .confirm = "닫기", .cancel = "취소" });
    var g = buttonGeom(&s, p, &tk).?;
    try std.testing.expectEqual(@as(u32, 1), g.msg_rows);
    try std.testing.expectEqual(@as(u32, 2), g.btn_row); // 0=메시지·1=빈줄·2=버튼 — 예전 그대로
    try std.testing.expectEqual(@as(u32, 2), g.body_row);

    // 두 줄로 나뉘는 메시지 + 미리보기 세 줄: [0,1]=메시지·2=빈줄·[3..6)=본문·6=빈줄·7=버튼.
    const body = [_][]const u8{ "echo one", "echo two", "echo three" };
    s.show("The pasted content has newlines or control characters, so a command could run immediately. Paste anyway?", .{ .confirm = "ok", .cancel = "no" });
    s.body = &body;
    g = buttonGeom(&s, p, &tk).?;
    try std.testing.expectEqual(@as(u32, 2), g.msg_rows);
    try std.testing.expectEqual(@as(u32, 3), g.body_row);
    try std.testing.expectEqual(@as(u32, 7), g.btn_row);
}

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "낮은 창에서도 버튼 행은 화면 안이다 — 미리보기부터, 그다음 메시지 줄을 줄이고 마지막 줄은 「…」로 끝난다" {
    // 실측(적대적 검증 2026-10-06): 420×240 창의 영어 붙여넣기 경고 + 미리보기 7줄이 상자 272px 이 되어, 취소 버튼이
    // y=240(화면 밖)이었다. 메시지를 줄바꿈하게 된 뒤(#4163) 상자가 높아져 생긴 자리다.
    const tk = testTokens();
    const msg = "This paste contains multiple lines and may run commands as soon as it is pasted into the terminal. Paste anyway?";
    const body = [_][]const u8{ "line1", "line2", "line3", "line4", "line5", "line6", "line7" };
    // 공백 없는 긴 토큰은 줄을 안쪽 폭까지 **꽉** 채운다 — 줄인 마지막 줄에 「…」를 그냥 붙이면 한 칸 넘친다.
    const full_lines = "x" ** 500;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{ msg, full_lines }) |message| for ([_]u32{ 120, 160, 200, 240, 272, 360 }) |h| {
        const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 180, .backing_width_px = 420, .backing_height_px = h } };
        var st: State = .{};
        st.show(message, .{ .confirm = "Paste", .cancel = "Cancel" });
        st.body = &body;
        const g = buttonGeom(&st, p, &tk) orelse return error.TestUnexpectedResult;
        const ws = props.workspaceRect(p.metrics);
        const cancel_y = modal_box.rowY(g.box, g.cancel_row);
        try std.testing.expect(cancel_y + 16 <= @as(i32, @intCast(ws.y + ws.h)));
        // 그 자리를 실제로 누르면 취소다(그림과 클릭이 같은 배치).
        const cx: f64 = @as(f64, @floatFromInt(g.cancel_x)) + 8;
        try std.testing.expectEqual(@as(?Action, .cancelled), buttonAtPoint(&st, p, &tk, cx, @as(f64, @floatFromInt(cancel_y)) + 8));
        if (h >= 360 and message.ptr == msg.ptr) try std.testing.expectEqual(@as(u32, 7), g.body_rows); // 들어가면 예전 그대로다
        if (g.msg_truncated) {
            // 메시지를 줄였으면 마지막 줄은 「…」로 끝나고 안쪽 폭 안이다.
            _ = arena_state.reset(.retain_capacity);
            var ops: std.ArrayList(draw.Op) = .empty;
            try view(&st, p, &tk, arena_state.allocator(), &ops);
            var last: []const u8 = "";
            for (ops.items) |op| switch (op) {
                .text => |t| if (t.origin.y == modal_box.rowY(g.box, g.msg_rows - 1)) {
                    last = t.runs[0].text;
                },
                else => {},
            };
            try std.testing.expect(std.mem.endsWith(u8, last, modal_box.ellipsis));
            try std.testing.expect(overlay_input.displayCols(last) <= g.box.inner_cols);
        }
    };
}

test "상자보다 넓은 버튼의 라벨은 그 버튼 칸에서 「…」로 줄어 패널 안에 든다" {
    // 예전에는 배경만 상자 안으로 잘리고 라벨은 그대로 그려 글자가 패널 밖으로 나갔다(퍼징 5,000 회 중 1,293 건).
    const tk = testTokens();
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 15, .cell_height_px = 30, .sidebar_width_px = 102, .backing_width_px = 287, .backing_height_px = 900 } };
    var st: State = .{};
    st.showChoices("파일이 외부에서 바뀌었습니다.", .{ .primary = "덮어쓰기", .alternate = "다시 읽기", .cancel = "계속 편집" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ops: std.ArrayList(draw.Op) = .empty;
    try view(&st, p, &tk, arena_state.allocator(), &ops);
    const g = buttonGeom(&st, p, &tk).?;
    const right = g.box.rect.x + @as(i32, @intCast(g.box.rect.w));
    var cut: usize = 0;
    for (ops.items) |op| switch (op) {
        .text => |t| {
            var cols: u32 = 0;
            for (t.runs) |r| cols += overlay_input.displayCols(r.text);
            try std.testing.expect(t.origin.x + @as(i32, @intCast(cols * 15)) <= right);
            if (std.mem.startsWith(u8, t.runs[0].text, "[") and std.mem.endsWith(u8, t.runs[0].text, "…")) cut += 1;
        },
        else => {},
    };
    try std.testing.expect(cut >= 1); // 실제로 줄인 라벨이 있었다 — 이 판정자가 그 길을 탔다
}

test "확인 모달 성질: 어떤 창·글꼴·메시지·버튼·미리보기에서도 글자는 패널 안, 자리가 있으면 버튼 행은 화면 안, 클릭은 그 버튼" {
    const tk = testTokens();
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "abc ", "한", "글자 ", "🙂", " ", "\n", "e\u{301}", "\xff", "\xe2", "…", "ｗ", "/opt/x/y" };
    const labels = [_][]const u8{ "OK", "실행", "덮어쓰기", "다시 읽기", "계속 편집", "Overwrite anyway", "x" ** 30, "한" ** 12 };
    const preview = [_][]const u8{ "echo hi", "rm -rf ./build && make " ++ "y" ** 60, "한글 줄", "" };
    const note_pool = [_]Note{ .{ .text = "• 서버는 사용자 권한으로 격리 없이 실행되며, 저장소 밖 파일에 닿을 수 있습니다." }, .{ .text = "~/a/b/c/" ++ "d" ** 40 ++ "/leaf", .fit = .path }, .{ .text = "x" ** 90 }, .{ .text = "" }, .{ .text = "한 🙂 \xff" } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var short_windows: usize = 0;
    for (0..3000) |_| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var b: std.ArrayList(u8) = .empty;
        for (0..r.intRangeAtMost(usize, 0, 60)) |_| try b.appendSlice(arena, pieces[r.intRangeLessThan(usize, 0, pieces.len)]);
        const cw = r.intRangeAtMost(u32, 4, 20);
        const ch = r.intRangeAtMost(u32, 8, 40);
        const bw = r.intRangeAtMost(u32, 100, 2400);
        const bh = r.intRangeAtMost(u32, 60, 1600);
        const p = props.ChromeProps{ .metrics = .{ .cell_width_px = cw, .cell_height_px = ch, .sidebar_width_px = r.intRangeAtMost(u32, 0, bw / 2), .backing_width_px = bw, .backing_height_px = bh } };
        var st: State = .{};
        const pick = struct {
            fn f(rr: std.Random) []const u8 {
                return labels[rr.intRangeLessThan(usize, 0, labels.len)];
            }
        }.f;
        if (r.boolean()) {
            st.show(b.items, .{ .confirm = pick(r), .cancel = pick(r) });
        } else {
            st.showChoices(b.items, .{ .primary = pick(r), .alternate = pick(r), .extra = if (r.boolean()) pick(r) else null, .cancel = pick(r) });
        }
        st.body = preview[0..r.intRangeAtMost(usize, 0, preview.len)];
        st.notes = note_pool[0..r.intRangeAtMost(usize, 0, note_pool.len)];
        const g = buttonGeom(&st, p, &tk) orelse continue;
        if (g.box.inner_cols == 0) continue; // 한 칸도 없는 상자 — 키보드만(예전과 같다)
        const rect = g.box.rect;
        var ops: std.ArrayList(draw.Op) = .empty;
        try view(&st, p, &tk, arena, &ops);
        for (ops.items) |op| switch (op) {
            .text => |t| {
                var cols: u32 = 0;
                for (t.runs) |run| cols += overlay_input.displayCols(run.text);
                // 1칸 상자에 2칸 글자 하나는 어쩔 수 없다(wrapLine 이 그 글자를 한 줄로 낸다) — 그 밖에는 패널 안이다.
                if (cols > 2 or g.box.inner_cols >= 2)
                    try std.testing.expect(t.origin.x >= rect.x and t.origin.x + @as(i32, @intCast(cols * cw)) <= rect.x + @as(i32, @intCast(rect.w)));
            },
            else => {},
        };
        const ws = props.workspaceRect(p.metrics);
        const ws_bottom: i32 = @intCast(ws.y + ws.h);
        // 메시지 한 줄 + 빈 줄 + (안내 한 줄 + 빈 줄) + 버튼 행이 들어갈 창 — 안내는 한 행까지만 줄인다.
        const fits = (ws.h / ch) -| 2 >= g.btn_rows + 2 + @as(u32, if (st.notes.len > 0) 2 else 0);
        if (!fits) short_windows += 1;
        const Btn = struct { a: Action, row: u32, x: i32, fit: u32 };
        var btns: [4]Btn = undefined;
        var nb: usize = 0;
        btns[nb] = .{ .a = .confirmed, .row = g.confirm_row, .x = g.confirm_x, .fit = g.confirm_fit };
        nb += 1;
        if (st.has_alternate) {
            btns[nb] = .{ .a = .alternate, .row = g.alternate_row, .x = g.alternate_x, .fit = g.alternate_fit };
            nb += 1;
        }
        if (st.has_extra) {
            btns[nb] = .{ .a = .extra, .row = g.extra_row, .x = g.extra_x, .fit = g.extra_fit };
            nb += 1;
        }
        btns[nb] = .{ .a = .cancelled, .row = g.cancel_row, .x = g.cancel_x, .fit = g.cancel_fit };
        nb += 1;
        for (btns[0..nb], 0..) |bt, i| {
            try std.testing.expect(bt.fit > 0); // 버튼은 생략되지 않는다(#4169)
            const y = modal_box.rowY(g.box, bt.row);
            if (fits) try std.testing.expect(y + @as(i32, @intCast(ch)) <= ws_bottom);
            const cx: f64 = @as(f64, @floatFromInt(bt.x)) + @as(f64, @floatFromInt(bt.fit * cw)) / 2;
            const cy: f64 = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(ch)) / 2;
            try std.testing.expectEqual(@as(?Action, bt.a), buttonAtPoint(&st, p, &tk, cx, cy));
            for (btns[0..i]) |o| {
                if (o.row != bt.row) continue;
                const a1 = bt.x + @as(i32, @intCast(bt.fit * cw));
                const b1 = o.x + @as(i32, @intCast(o.fit * cw));
                try std.testing.expect(!(bt.x < b1 and o.x < a1));
            }
        }
    }
    try std.testing.expect(short_windows < 3000); // 낮은 창만 나온 퍼징이 아니다
}

/// 안내 줄 판정자 공용 — 그 상태를 그린 op 들에서 텍스트만 행(y) 순서대로 모은다.
fn testTexts(arena: std.mem.Allocator, ops: []const draw.Op) ![]const draw.Op.Text {
    var list: std.ArrayList(draw.Op.Text) = .empty;
    for (ops) |op| if (op == .text) try list.append(arena, op.text);
    return list.items;
}

fn testProps(w: u32, h: u32) props.ChromeProps {
    return .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = w, .backing_height_px = h } };
}

test "confirm 안내 줄: 메시지 아래·버튼 위에 본문 글자색으로 서고, 좁은 창에서는 줄바꿈해 낱말을 하나도 잃지 않는다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const notes = [_]Note{
        .{ .text = "• runs with your user privileges and no sandbox" },
        .{ .text = "• may reach files outside the workspace, the network, and ssh-agent" },
    };
    for ([_]u32{ 800, 260 }) |width| {
        var s = State{};
        s.show("Run language servers?", .{ .confirm = "Run", .cancel = "Don't run" });
        s.notes = &notes;
        var out: std.ArrayList(draw.Op) = .empty;
        try view(&s, testProps(width, 600), &tk, arena, &out);
        const texts = try testTexts(arena, out.items);
        var msg_y: i32 = -1;
        var btn_y: i32 = -1;
        var joined: std.ArrayList(u8) = .empty;
        for (texts) |t| {
            const txt = t.runs[0].text;
            if (std.mem.eql(u8, txt, "Run language servers?")) msg_y = t.origin.y;
            if (std.mem.startsWith(u8, txt, "[Y]")) btn_y = t.origin.y;
            if (t.role == .surface_fg and !std.mem.startsWith(u8, txt, "[") and !std.mem.eql(u8, txt, "Run language servers?")) {
                try std.testing.expect(t.origin.y > msg_y); // 메시지 아래
                try joined.appendSlice(arena, txt);
                try joined.append(arena, ' ');
            }
        }
        try std.testing.expect(btn_y > msg_y);
        for (texts) |t| if (t.role == .surface_fg and !std.mem.startsWith(u8, t.runs[0].text, "[") and t.origin.y > msg_y) try std.testing.expect(t.origin.y < btn_y); // 버튼 위
        // 낱말을 하나도 잃지 않는다 — 줄바꿈만 했다(「…」 없음).
        for (notes) |note| {
            var it = std.mem.tokenizeScalar(u8, note.text, ' ');
            while (it.next()) |word| try std.testing.expect(std.mem.indexOf(u8, joined.items, word) != null);
        }
        try std.testing.expect(std.mem.indexOf(u8, joined.items, modal_box.ellipsis) == null);
    }
}

test "confirm 안내 줄: 높이가 모자라면 미리보기를 먼저 줄이고, 그래도 모자라면 안내를 끝부터 줄여 마지막 줄을 「…」로 끝낸다 — 버튼은 화면 안" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const notes = [_]Note{ .{ .text = "• one" }, .{ .text = "• two" }, .{ .text = "• three" }, .{ .text = "• four" }, .{ .text = "• five" } };
    const body = [_][]const u8{ "a", "b", "c" };
    var s = State{};
    s.show("Q?", .{ .confirm = "Y", .cancel = "N" });
    s.notes = &notes;
    s.body = &body;
    // 넉넉하면 다 선다.
    const roomy = buttonGeom(&s, testProps(400, 600), &tk).?;
    try std.testing.expectEqual(@as(u32, 5), roomy.note_rows);
    try std.testing.expectEqual(@as(u32, 3), roomy.body_rows);
    // 미리보기가 먼저 준다 — 안내는 그대로.
    var h: u32 = 600;
    var saw_body_cut_with_notes_whole = false;
    while (h > 64) : (h -= 16) {
        const g = buttonGeom(&s, testProps(400, h), &tk) orelse break;
        if (g.body_rows < 3 and g.note_rows == 5) saw_body_cut_with_notes_whole = true;
        if (g.note_rows < 5) try std.testing.expectEqual(@as(u32, 0), g.body_rows); // 안내가 줄면 미리보기는 이미 0
        if (g.note_rows < 5 and g.note_rows > 0) try std.testing.expect(g.note_lines[g.note_rows - 1].cut);
        // 버튼 행은 화면 안 — 상자 아래 끝이 작업영역 안이다(줄일 것이 더 없는 극단 — 안내·메시지 한 행씩 — 은 빼고).
        const ws = props.workspaceRect(testProps(400, h).metrics);
        if (g.note_rows > 1 or g.msg_rows > 1 or g.body_rows > 0) try std.testing.expect(g.box.rect.y + @as(i32, @intCast(g.box.rect.h)) <= @as(i32, @intCast(ws.y + ws.h)));
    }
    try std.testing.expect(saw_body_cut_with_notes_whole);
}

test "confirm 안내 줄: 경로 줄은 줄바꿈하지 않고 가운데를 줄여 뿌리와 잎을 남긴다; show 는 이전 안내를 비운다" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "~/workspace/very/deeply/nested/directory/structure/maru";
    const notes = [_]Note{.{ .text = path, .fit = .path }};
    var s = State{};
    s.show("Q?", .{ .confirm = "Y", .cancel = "N" });
    s.notes = &notes;
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, testProps(260, 600), &tk, arena, &out);
    const g = buttonGeom(&s, testProps(260, 600), &tk).?;
    try std.testing.expectEqual(@as(u32, 1), g.note_rows); // 한 행
    var found = false;
    for (try testTexts(arena, out.items)) |t| {
        const txt = t.runs[0].text;
        if (std.mem.startsWith(u8, txt, "~/") and std.mem.endsWith(u8, txt, "/maru")) {
            found = true;
            try std.testing.expect(std.mem.indexOf(u8, txt, "…") != null);
            try std.testing.expect(overlay_input.displayCols(txt) <= g.box.inner_cols);
        }
    }
    try std.testing.expect(found);
    s.show("Again?", .{ .confirm = "Y", .cancel = "N" });
    try std.testing.expectEqual(@as(usize, 0), s.notes.len);
}
