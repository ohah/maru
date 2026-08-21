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

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유 — notice와 동일). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

/// 버튼에 표시하는 단축키 마커 — TUI 관례의 Y/N(Enter/Esc도 handle이 받지만, 표시는 짧은 Y/N로 통일해 영어
/// 단어를 안 섞는다). 버튼 라벨 앞에 "[Y] "/"[N] "로 붙여 어느 키가 어느 버튼인지 보인다(키는 handle이 고정).
const key_confirm = "Y";
const key_alternate = "D";
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
};

/// 어느 버튼에 포커스가 있나(←/→로 이동). Enter가 포커스된 버튼을 실행한다. 열 때마다 기본 = confirm(Enter=확정 유지).
pub const Focus = enum { confirm, alternate, cancel };

/// 순수 상태 — message + (선택) 본문 미리보기 + 버튼 라벨 + 포커스 + open 플래그. host가 보류(pending)하며 show를
/// 부른다. 라벨은 show가 채우고, body는 show 뒤 host가 따로 주입한다(대부분의 확인엔 없음 — 붙여넣기 미리보기 전용).
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",
    // 기본값은 빈 문자열 — 실제 라벨은 show(message, Buttons)가 채운다(호출자가 둘 다 준다).
    // view는 open일 때만 그리고 show 없이는 열리지 않으므로 빈 기본값이 렌더되는 일은 없다.
    confirm_label: []const u8 = "",
    alternate_label: []const u8 = "",
    cancel_label: []const u8 = "",
    has_alternate: bool = false,
    focused: Focus = .confirm,
    // 메시지와 버튼 사이에 그릴 **본문 미리보기 줄들**(비면 없음 — 기존 동작). Ghostty의 붙여넣기 확인창이 내용을
    // 스크롤 뷰로 보여주는 것의 셀-그리드 근사(앞 몇 줄 + 요약). 슬라이스는 host가 세션 소유 버퍼로 준다(message와 동형).
    body: []const []const u8 = &.{},

    pub fn show(self: *State, message: []const u8, buttons: Buttons) void {
        self.message = message;
        self.confirm_label = buttons.confirm;
        self.alternate_label = "";
        self.cancel_label = buttons.cancel;
        self.has_alternate = false;
        self.focused = .confirm; // 열 때마다 기본 포커스 = 확정 버튼(Enter=확정, ←/→로 이동)
        self.body = &.{}; // 이전 확인이 남긴 미리보기가 새 모달에 새지 않게 리셋(붙여넣기 경로가 show 뒤 다시 주입)
        self.open = true;
    }

    pub fn showChoices(self: *State, message: []const u8, choices: Choices) void {
        self.message = message;
        self.confirm_label = choices.primary;
        self.alternate_label = choices.alternate;
        self.cancel_label = choices.cancel;
        self.has_alternate = true;
        self.focused = .confirm;
        self.body = &.{};
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리한다 — confirmed면 보류한 동작을 실행, cancelled면 버린다.
/// (notice는 dismissed 하나뿐이지만 confirm은 파괴적 동작 분기라 둘로 나뉜다.)
pub const Action = enum { confirmed, alternate, cancelled };

/// 키 이벤트 처리. 열려 있을 때만 동작:
///   ←/→ : 두 버튼 사이 포커스 이동(소비, intent 없음 → host가 재렌더). Enter : **포커스된** 버튼 실행
///   (confirm/cancelled). Esc : 항상 cancelled(취소 관례). Y/N : 포커스와 무관하게 직접 실행(대소문자 무시 단축키).
/// 그 외 키는 소비하되 Action 없음(모달이라 뒤(터미널)로 안 흘린다). 닫혀 있으면 null(라우팅 안 가로챔).
/// host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 host.handlePointer.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    if (!state.open) return null;
    switch (k.key) {
        .left => {
            state.focused = switch (state.focused) {
                .confirm => .cancel,
                .alternate => .confirm,
                .cancel => if (state.has_alternate) .alternate else .confirm,
            };
            return null;
        },
        .right => {
            state.focused = switch (state.focused) {
                .confirm => if (state.has_alternate) .alternate else .cancel,
                .alternate => .cancel,
                .cancel => .confirm,
            };
            return null;
        },
        .enter => {
            state.dismiss();
            return switch (state.focused) {
                .confirm => .confirmed,
                .alternate => .alternate,
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

    // (1) 메시지 — 중앙, row 0.
    try modal_box.text(box, modal_box.centerX(box, overlay_input.displayCols(state.message)), 0, state.message, .surface_fg, arena, out);

    // (1.5) 본문 미리보기(있으면) — 메시지 아래 빈 줄 다음부터 좌측 정렬. 각 줄에 은은한 배경 fill(tab_hover_bg)을
    //       inner 폭만큼 깔아 인셋 패널처럼 보이게 하고, 그 위에 muted 텍스트를 놓는다(painter order: fill→text).
    //       Ghostty의 스크롤 텍스트 뷰를 셀-그리드로 근사한 것 — 붙여넣을 내용을 눈으로 확인하고 결정하게 한다.
    for (state.body, 0..) |line, i| {
        const row = body_start_row + @as(u32, @intCast(i));
        try modal_box.fillCells(box, box.inner_x, row, box.inner_cols, .tab_hover_bg, arena, out);
        try modal_box.text(box, box.inner_x, row, line, .muted_fg, arena, out);
    }

    // (2) 버튼 행(g.btn_row — 미리보기 줄 수만큼 아래로 내려감) — **포커스된 버튼이 accent**(focus_accent + 대비색 surface_bg 라벨)로 강조되고, 나머지는 은은한 배경
    //     (tab_hover_bg + surface_fg 라벨)이다. ←/→로 포커스가 옮겨가면 강조도 따라 이동한다(어느 버튼이 Enter 대상인지
    //     보임). 둘 다 배경 fill로 버튼처럼(painter order: bg→glyph). 위치/폭은 buttonGeom 단일 출처(클릭 hit-test와 공유).
    //     라벨은 버튼 패딩만큼 우측에서 시작. arena에 만든 라벨 슬라이스는 view 동안(=lower까지) 유효.
    const confirm_focused = state.focused == .confirm;
    if (g.confirm_fit > 0) {
        try modal_box.fillCells(box, g.confirm_x, g.btn_row, g.confirm_fit, if (confirm_focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key_confirm, state.confirm_label });
        try modal_box.text(box, g.confirm_x + @as(i32, @intCast(btn_pad * box.cw)), g.btn_row, t, if (confirm_focused) .surface_bg else .surface_fg, arena, out);
    }
    if (state.has_alternate and g.alternate_fit > 0) {
        const focused = state.focused == .alternate;
        try modal_box.fillCells(box, g.alternate_x, g.btn_row, g.alternate_fit, if (focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key_alternate, state.alternate_label });
        try modal_box.text(box, g.alternate_x + @as(i32, @intCast(btn_pad * box.cw)), g.btn_row, t, if (focused) .surface_bg else .surface_fg, arena, out);
    }
    if (g.cancel_fit > 0) {
        const focused = state.focused == .cancel;
        try modal_box.fillCells(box, g.cancel_x, g.btn_row, g.cancel_fit, if (focused) .focus_accent else .tab_hover_bg, arena, out);
        const t = try std.fmt.allocPrint(arena, "[{s}] {s}", .{ key_cancel, state.cancel_label });
        try modal_box.text(box, g.cancel_x + @as(i32, @intCast(btn_pad * box.cw)), g.btn_row, t, if (focused) .surface_bg else .surface_fg, arena, out);
    }
}

const btn_pad: u32 = 1; // 버튼 라벨 좌우 패딩(배경이 라벨을 감싸 버튼처럼)
const btn_gap: u32 = 2; // 두 버튼 사이 간격(칸)
const body_start_row: u32 = 2; // 본문 미리보기 시작 행: 0=메시지, 1=빈줄, 2~=본문

/// 버튼 행 기하 — view(그리기)와 buttonAtPoint(클릭 hit-test)가 공유하는 **단일 레이아웃**(chrome 계약 §5.4의
/// view↔hitTest 단일 모델). 박스·각 버튼 x·fit-clamp된 폭(칸; 0이면 너무 좁아 생략)을 돌려준다. null=안 열림/생략 박스.
const ButtonGeom = struct {
    box: modal_box.Box,
    btn_row: u32, // 버튼 콘텐츠 행 — 미리보기(body) 줄 수만큼 아래로 내려간다(view↔hitTest 공유)
    confirm_x: i32,
    confirm_fit: u32,
    alternate_x: i32,
    alternate_fit: u32,
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
    const cancel_cols = markerCols(key_cancel) + overlay_input.displayCols(state.cancel_label);
    const default_btn_cols = confirm_cols + 2 * btn_pad;
    const alternate_btn_cols = if (state.has_alternate) alternate_cols + 2 * btn_pad else 0;
    const cancel_btn_cols = cancel_cols + 2 * btn_pad;
    const btn_row_cols = default_btn_cols + btn_gap + alternate_btn_cols + (if (state.has_alternate) btn_gap else 0) + cancel_btn_cols;
    var content_cols = @max(overlay_input.displayCols(state.message), btn_row_cols);
    for (state.body) |line| content_cols = @max(content_cols, overlay_input.displayCols(line)); // 미리보기 줄도 폭에 반영
    // 콘텐츠 행: 미리보기 없으면 3행(0=메시지·1=빈줄·2=버튼); 있으면 0=메시지·1=빈줄·[2..2+n)=본문·2+n=빈줄·3+n=버튼.
    const n: u32 = @intCast(state.body.len);
    const content_rows: u32 = if (n == 0) 3 else 4 + n;
    const btn_row: u32 = if (n == 0) body_start_row else body_start_row + n + 1; // 본문 뒤 빈 줄 다음
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    const group_x = modal_box.centerX(box, btn_row_cols);
    // 버튼이 박스 안쪽 우측 끝을 넘으면(좁은 창/긴 라벨) fill이 rasterize bbox를 패널 밖으로 키운다 → 폭을 clamp하고
    // 0이면(완전히 밖) 호출자가 버튼을 생략(그땐 키보드 Esc/Y/N). 정상 창은 무변화. inner=[inner_x, inner_x+inner_cols×cw).
    const inner_right = box.inner_x + @as(i32, @intCast(box.inner_cols * box.cw));
    const alternate_x = group_x + @as(i32, @intCast((default_btn_cols + btn_gap) * box.cw));
    const cancel_x = alternate_x + @as(i32, @intCast((alternate_btn_cols + (if (state.has_alternate) btn_gap else 0)) * box.cw));
    return .{
        .box = box,
        .btn_row = btn_row,
        .confirm_x = group_x,
        .confirm_fit = fitButtonCols(group_x, default_btn_cols, box.cw, inner_right),
        .alternate_x = alternate_x,
        .alternate_fit = if (state.has_alternate) fitButtonCols(alternate_x, alternate_btn_cols, box.cw, inner_right) else 0,
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
    // 버튼 행 y 범위 안에서 각 버튼 x 범위(fit 폭) 검사.
    const ry = @as(f64, @floatFromInt(modal_box.rowY(g.box, g.btn_row)));
    const cw_f = @as(f64, @floatFromInt(g.box.cw));
    if (y_px >= ry and y_px < ry + @as(f64, @floatFromInt(g.box.ch))) {
        const cfx = @as(f64, @floatFromInt(g.confirm_x));
        if (g.confirm_fit > 0 and x_px >= cfx and x_px < cfx + @as(f64, @floatFromInt(g.confirm_fit)) * cw_f) return .confirmed;
        const afx = @as(f64, @floatFromInt(g.alternate_x));
        if (g.alternate_fit > 0 and x_px >= afx and x_px < afx + @as(f64, @floatFromInt(g.alternate_fit)) * cw_f) return .alternate;
        const xcx = @as(f64, @floatFromInt(g.cancel_x));
        if (g.cancel_fit > 0 and x_px >= xcx and x_px < xcx + @as(f64, @floatFromInt(g.cancel_fit)) * cw_f) return .cancelled;
    }
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
