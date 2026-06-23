//! Notifications — 인앱 알림 센터 패널(Zig 오버레이, chrome 컴포넌트 계약: State + view + handle). 사이드바 헤더
//! 종 아이콘 클릭으로 열린다(2단계). **상단 헤더 밴드**("알림" 제목 + 우측 액션 "모두 읽음"/"모두 지우기")와 그 아래
//! 본문(카드 목록 또는 빈 상태 일러스트)으로 구성된다 — 헤더는 viewport 상단 sticky, 카드는 그 아래에서 스크롤한다.
//! 한 항목 = cell 2행(제목+본문)이고 안읽음 점(●)·상대시간·닫힌 surface 회색(role 교체)으로 표현한다. **빈 상태**는
//! 종-슬래시 아이콘 + 굵은 제목 + 부제로 가운데 정렬한다. 패널 폭은 [min,max] cap이라 내용이 길어도 과도하게 넓어지지
//! 않고(적당한 크기), 넘치는 제목/본문은 `truncateToCols`로 …말줄임한다. **항목은 platform이 주입**하고(palette Row
//! 선례) '실행'(클릭→activateSurfaceById)도 platform이 한다 — 컴포넌트는 선택(selected)·anchor만 안다(chrome 중립:
//! surface_id·라이브 포인터 모름). 단일 출처: panelRect를 view·hitTest가 공유(docs/chrome-strategy.md §5.4,
//! docs/notifications.md §3). 디자인은 Maru 독립 설계다.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW)·truncateToCols 단일 출처 — 카드 폭 측정·말줄임에 재사용

/// 최상위 모달 레이어(열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 한 항목 = cell 2행(제목줄 + 본문줄). hitTest·layout이 이 높이로 행을 가른다.
const card_rows: u32 = 2;

/// 상단 헤더 밴드("알림" 제목 + 우측 액션) 높이(cell). viewport 상단 sticky — 카드는 이 아래에서 스크롤한다.
const header_rows: u32 = 1;

/// 제목/본문 좌측 들여쓰기(칸) — 점(●) 자리 1칸 + 공백 1칸. 점은 안읽음일 때만 그 자리에 그린다(읽음이면 공백).
const text_indent_cols: u32 = 2;

/// 패널 **최소** 폭(칸). 헤더의 "알림" + "모두 읽음"·"모두 지우기" 액션이 겹치지 않게, 또 카드가 답답하지 않게 둘
/// 넉넉한 하한(~360px at 12px cell). content가 이보다 작아도 이 폭을 보장한다.
const min_panel_cols: u32 = 30;

/// 패널 **최대** 폭(칸). 내용(긴 본문 등)이 길어도 패널이 화면을 가로지를 만큼 넓어지지 않게 cap한다(사용자 피드백
/// "maxwidth가 있어서 적당한 크기"). 넘치는 제목/본문은 view가 `truncateToCols`로 …말줄임한다. ~520px at 12px cell.
const max_panel_cols: u32 = 44;

/// 빈 상태 일러스트(아이콘+제목+부제) 본문 영역 높이(cell, 헤더 아래). 너무 납작하지 않게 둔다 — 가운데 정렬 여백 포함.
const empty_body_rows: u32 = 6;

/// 항목이 있을 때 팝업 최소 높이(행, 헤더 포함). 알림이 한두 개뿐이어도 팝업이 납작하지 않게 baseline 높이를 보장한다.
/// 헤더+카드는 상단, 사이 여백은 패널 배경(클릭 무시 — Hit.background). 카드가 이보다 많으면 자연 높이로 커지므로 무영향.
const min_panel_rows: u32 = 8;

/// 헤더 제목.
const panel_heading = "알림";

/// 빈 상태 일러스트 — 아이콘(종-슬래시) + 굵은 제목 + 부제. 아이콘은 이모지(🔕, CoreText fallback) — 렌더 안 되면
/// BMP 기호로 교체(docs/notifications.md §5 "종 글리프 실제 렌더 확인" 규율과 동일).
const empty_icon = "\u{1F515}"; // 🔕 U+1F515 BELL WITH CANCELLATION STROKE
const empty_heading = "아직 알림이 없습니다";
const empty_subtext = "데스크톱 알림이 여기에 표시됩니다.";

/// 제목이 빈 문자열(OSC 9는 title 없음)일 때 표시 폴백.
const empty_title = "(제목 없음)";

/// 카드 우측 ✕(개별 삭제) 글리프 — sidebar 닫기와 같은 BMP(이모지 fallback 없음).
const close_glyph = "\u{2715}"; // ✕ U+2715
const mark_all_label = "모두 읽음";
const clear_all_label = "모두 지우기";

/// 헤더 우측 액션 라벨 사이 간격(칸).
const action_gap_cols: u32 = 2;

/// host가 주입하는 알림 한 줄(카드). 중립 바이트/bool — platform이 히스토리에서 만든다(컴포넌트는 surface_id를 안
/// 본다). title/body는 표시 문자열, relative_time="N분 전"(platform 포맷), is_read=안읽음 점 표시, is_alive=false면
/// 닫힌 surface라 회색(muted_fg)으로 dim. selected는 State.selected로 판단(palette.Row와 달리 행에 안 싣는다).
pub const Item = struct {
    title: []const u8,
    body: []const u8,
    relative_time: []const u8,
    is_read: bool,
    is_alive: bool,
};

/// 순수 UI 상태 — open + anchor(종 아이콘 px) + selected(강조 카드) + item_count(키 nav clamp용) + scroll_offset(보이는
/// 첫 카드). 항목 데이터는 platform이 매 프레임 주입(palette 선례)하므로 여기엔 없다. heap 없음(deinit 불필요).
pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    selected: usize = 0,
    item_count: usize = 0,
    /// 보이는 첫 카드 인덱스(0=최신 위). 카드가 화면 높이를 넘으면 이 offset 윈도우만 렌더(카드 단위 스크롤 — draw.Op에
    /// scissor가 없어 부분 카드를 못 자르므로 통째 카드만). 상한 clamp는 layout(items·metrics 의존)이 하고, 여기선
    /// 하한(0)만 보장. show 시 0으로 리셋.
    scroll_offset: usize = 0,

    /// 종 아이콘 위치(x,y px)와 항목 수로 연다 — 선택은 첫(=최신) 항목, 스크롤은 맨 위. platform이 항목을 빌드한 뒤 부른다.
    pub fn show(self: *State, x: i32, y: i32, item_count: usize) void {
        self.anchor_x = x;
        self.anchor_y = y;
        self.selected = 0;
        self.item_count = item_count;
        self.scroll_offset = 0;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 패널이 열린 채 새 알림이 도착하면 item_count가 달라진다 — platform이 collect/pointer 시 동기화(selected clamp).
    pub fn setItemCount(self: *State, n: usize) void {
        self.item_count = n;
        if (self.selected >= n) self.selected = if (n == 0) 0 else n - 1;
    }

    /// 선택을 delta만큼 이동(clamp, wrap 없음 — context_menu/palette와 같은 규율). item_count 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i64) void {
        if (self.item_count == 0) return;
        const last: i64 = @intCast(self.item_count - 1);
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, last));
    }

    /// 마우스 휠용 — delta 카드만큼 스크롤(음수=위/최신, 양수=아래/오래된). count·metrics만 받는다(전체 Item 빌드·폭
    /// 계산 불필요 — scrollWindow는 개수·화면 높이만 본다). 상한은 scrollWindow가 clamp(단일 출처). 스크롤 불필요면 0.
    pub fn scrollBy(self: *State, total: usize, m: props.CellMetrics, delta: i64) void {
        const sw = scrollWindow(total, m);
        if (!sw.scrollable) {
            self.scroll_offset = 0;
            return;
        }
        const max_offset: i64 = @intCast(sw.max_offset);
        const cur: i64 = @intCast(@min(self.scroll_offset, sw.max_offset));
        self.scroll_offset = @intCast(std.math.clamp(cur + delta, 0, max_offset));
    }

    /// 키보드 ↑↓로 selected가 바뀐 뒤 호출 — 선택 카드가 viewport 밖이면 보이게 스크롤한다(prev 위치 유지 + selected
    /// 끝맞춤, overlay_input.windowStart 단일 출처). count·metrics만 받는다(Item 빌드 불필요). 스크롤 불필요면 0.
    pub fn ensureSelectedVisible(self: *State, total: usize, m: props.CellMetrics) void {
        const sw = scrollWindow(total, m);
        if (!sw.scrollable) {
            self.scroll_offset = 0;
            return;
        }
        self.scroll_offset = overlay_input.windowStart(total, sw.visible, self.selected, self.scroll_offset);
    }
};

/// handle이 돌려주는 intent(context_menu와 동일 계약). host가 받아 platform에 디스패치.
pub const Action = enum {
    accept, // Enter/카드 본문 클릭 — selected 항목 실행(platform이 selected→surface_id 해석 후 activateSurfaceById)
    close, // Esc / 그 외 키 — 닫기
    selection_changed, // ↑↓ — selected 이동(렌더 갱신)
    delete_selected, // Backspace — selected 카드 삭제(platform이 히스토리에서 제거)
};

/// 마우스 hit-test 결과(platform이 pointer로 해석). 카드 본문=점프, 우측 ✕=삭제, 상단 헤더 액션=전체 읽음/지우기.
pub const Hit = union(enum) {
    card: usize, // 카드 본문 클릭 → 점프(accept)
    close: usize, // 카드 우측 ✕ → 그 카드 삭제
    mark_all_read, // 헤더 "모두 읽음"
    clear_all, // 헤더 "모두 지우기"
    background, // 카드/액션 아닌 패널 내부(헤더 제목 영역·빈 여백·빈 상태 본문) — 클릭 무시(닫지 않음). 박스 '밖'만 null(=닫기).
};

/// 키 처리(열려 있을 때만 host가 호출). ↑↓=이동, Enter=accept, Backspace=selected 삭제, 그 외(Esc·글자 등)=close.
/// 모달이라 모든 키 소비(context_menu와 같은 규율 — 뒤 터미널로 안 흘린다). 마우스는 platform이 hitTest로 처리한다.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
        .up => {
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            state.moveSelection(1);
            return .selection_changed;
        },
        .enter => return .accept,
        .backspace => return .delete_selected, // selected 카드 삭제(platform이 제거 후 selected clamp)
        else => {
            state.hide();
            return .close;
        },
    }
}

/// 제목 표시 문자열(빈 제목 → 폴백). view·폭 측정 단일 출처.
fn titleText(it: Item) []const u8 {
    return if (it.title.len > 0) it.title else empty_title;
}

/// 한 카드의 **자연**(말줄임 전) 가로 칸 수(EAW). 제목줄 = 들여쓰기 + 제목 + 갭 + 시간, 본문줄 = 들여쓰기 + 본문 중
/// 큰 값. layout이 이 값들의 최대를 [min,max]로 cap하므로, 넘치는 카드는 view에서 truncateToCols로 말줄임된다.
fn cardCols(it: Item) u32 {
    const title_line = text_indent_cols + overlay_input.displayCols(titleText(it)) + 1 + overlay_input.displayCols(it.relative_time);
    const body_line = text_indent_cols + overlay_input.displayCols(it.body);
    return @max(title_line, body_line);
}

/// 헤더 우측 액션 라벨의 panel-local 시작 col(view·hitTest 단일 출처). "모두 지우기"가 우측 끝(1칸 패딩), "모두 읽음"이
/// 그 왼쪽으로 action_gap_cols 띄운 자리. 좁은 폭이면 saturating으로 0까지(제목과 겹칠 수 있으나 min_panel_cols가 방어).
const HeaderActions = struct { mark_x0: u32, mark_cols: u32, clear_x0: u32, clear_cols: u32 };
fn headerActions(panel_cols: u32) HeaderActions {
    const clear_cols = overlay_input.displayCols(clear_all_label);
    const mark_cols = overlay_input.displayCols(mark_all_label);
    const clear_x0 = panel_cols -| clear_cols -| 1; // 우측 1칸 패딩
    const mark_x0 = clear_x0 -| action_gap_cols -| mark_cols;
    return .{ .mark_x0 = mark_x0, .mark_cols = mark_cols, .clear_x0 = clear_x0, .clear_cols = clear_cols };
}

/// 카드 윈도우(보이는 카드 수·스크롤 여부·최대 offset) — **width 없이** 개수와 화면 높이(metrics)만으로 계산한다.
/// layout(렌더용, 폭도 계산)과 scrollBy/ensureSelectedVisible(스크롤만)이 공유 — 후자가 매 휠/키마다 전체 Item을 빌드
/// 하거나 카드 폭을 재지 않게 한다(개수만 필요). 헤더(상단 sticky)는 늘 예약하고, 화면 가용 높이에서 카드 1개는 최소 보장.
const ScrollWindow = struct { visible: usize, scrollable: bool, max_offset: usize };

fn scrollWindow(total: usize, m: props.CellMetrics) ScrollWindow {
    const ch = @max(m.cell_height_px, 1);
    const card_h = ch * card_rows;
    const header_h = ch * header_rows; // 상단 sticky 헤더는 늘 예약
    const avail_h = @max(card_h + header_h, m.backing_height_px -| 2 * ch); // 위아래 1칸 여백
    const max_card_area = avail_h -| header_h;
    const max_visible: usize = @intCast(@max(@as(u32, 1), max_card_area / card_h));
    const visible: usize = if (total == 0) 0 else @min(total, max_visible);
    const scrollable = total > visible;
    return .{ .visible = visible, .scrollable = scrollable, .max_offset = if (scrollable) total - visible else 0 };
}

/// 패널 레이아웃(스크롤 윈도우 포함) — **view·hitTest·panelRect 단일 출처**라 "보이는 카드 == 클릭되는 카드". 상단에
/// 헤더 밴드(제목+액션, sticky)를 두고 그 아래에서 카드가 스크롤한다. 카드가 화면 가용 높이를 넘으면 카드 단위로 스크롤
/// (부분 카드 클리핑 인프라가 없어 — draw.Op에 scissor 없음 — 통째 카드만 보인다). 폭은 [min,max] cap.
const Layout = struct {
    rect: draw.Rect, // 패널 박스(px) — 화면 안으로 clamp됨
    cw: u32,
    ch: u32,
    card_h: u32, // 카드 1개 높이(px) = ch × card_rows
    header_h: u32, // 헤더 밴드 높이(px) = ch × header_rows
    panel_cols: u32, // 박스 폭(칸)
    total: usize, // 전체 카드 수
    first: usize, // 보이는 첫 카드 인덱스(scroll_offset clamp 결과)
    visible: usize, // 보이는 카드 수(≤ total)
    scrollable: bool, // total > visible — 스크롤바·휠 활성
};

/// 패널 레이아웃을 계산한다(폭·높이·스크롤 윈도우·위치 clamp). cell 0이면 null. anchor에서 시작하되 화면(backing)
/// 우/하단을 넘으면 당겨 안에 들게 clamp(context_menu menuRect와 같은 수학). 좌단은 종 드롭다운이라 사이드바로 안 민다.
fn layout(state: *const State, items: []const Item, p: props.ChromeProps) ?Layout {
    const m = p.metrics;
    if (m.cell_width_px == 0 or m.cell_height_px == 0) return null;
    const cw = m.cell_width_px;
    const ch = m.cell_height_px;
    const card_h = ch * card_rows;
    const header_h = ch * header_rows;

    // 폭 — 빈 목록은 일러스트(제목/부제) 폭, 아니면 최대 카드 폭. [min,max] cap + 좌우 1칸 패딩. 헤더 액션은
    // min_panel_cols가 들어가게 보장한다(headerActions 참조). cap을 넘는 카드는 view가 말줄임.
    var content_cols: u32 = if (items.len == 0)
        @max(overlay_input.displayCols(empty_heading), overlay_input.displayCols(empty_subtext))
    else
        0;
    for (items) |it| {
        const c = cardCols(it);
        if (c > content_cols) content_cols = c;
    }
    content_cols = std.math.clamp(content_cols, min_panel_cols, max_panel_cols);
    const box_w = (content_cols + 2) * cw;

    const total = items.len;
    const sw = scrollWindow(total, m); // 보이는 카드 수·스크롤 여부·max_offset(단일 출처)
    const bh = m.backing_height_px;
    const first = @min(state.scroll_offset, sw.max_offset);

    // 높이 — 빈 목록은 헤더 + 일러스트 영역, 아니면 헤더 + 보이는 카드. 스크롤 안 하는(항목 적은) 경우엔 min_panel_rows를
    // baseline으로 보장(헤더+카드 상단, 사이 여백=패널 배경). 스크롤되면 카드가 화면을 채워 baseline 불필요. baseline은
    // 화면(backing)을 넘기지 않게 cap(상하 1칸 여백 — scrollWindow와 동일). content_h는 이미 scrollWindow가 맞췄으므로
    // 그보다 작게 깎지 않는다(`@max`).
    const content_h: u32 = if (total == 0)
        header_h + empty_body_rows * ch
    else
        header_h + @as(u32, @intCast(sw.visible)) * card_h;
    const box_h: u32 = if (total == 0 or sw.scrollable)
        content_h
    else
        @max(content_h, @min(min_panel_rows * ch, bh -| 2 * ch));

    // 위치 clamp.
    var x = state.anchor_x;
    var y = state.anchor_y;
    const bw_px: i32 = @intCast(m.backing_width_px);
    const bh_px: i32 = @intCast(bh);
    if (x + @as(i32, @intCast(box_w)) > bw_px) x = bw_px - @as(i32, @intCast(box_w)); // 우단 넘으면 왼쪽으로
    if (y + @as(i32, @intCast(box_h)) > bh_px) y = bh_px - @as(i32, @intCast(box_h)); // 하단 넘으면 위로
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    return .{
        .rect = .{ .x = x, .y = y, .w = box_w, .h = box_h },
        .cw = cw,
        .ch = ch,
        .card_h = card_h,
        .header_h = header_h,
        .panel_cols = box_w / cw,
        .total = total,
        .first = first,
        .visible = sw.visible,
        .scrollable = sw.scrollable,
    };
}

/// 패널 박스 rect(px). view·hitTest와 같은 layout을 쓴다(단일 출처). cell 0이면 null. platform이 말풍선 caret을
/// 벨↔패널 상단에 맞추려 패널 top/x/w를 읽는다(pub).
pub fn panelRect(state: *const State, items: []const Item, p: props.ChromeProps) ?draw.Rect {
    const l = layout(state, items, p) orelse return null;
    return l.rect;
}

/// 마우스 px를 패널 안의 동작으로 해석한다(박스 밖이면 null → 호출자가 닫기). view와 같은 layout을 써서 "보이는 ==
/// 클릭되는". 세로: 상단 헤더(액션)·그 아래 카드 영역(visible × 2행). 헤더 우측은 모두읽음/지우기, 헤더 좌측(제목)·
/// 카드 영역 아래 빈 여백·빈 상태 본문은 background(닫지 않음). 카드 안에서 본문줄(line 1) 우측 끝 1칸은 ✕(삭제) zone.
pub fn hitTest(state: *const State, items: []const Item, p: props.ChromeProps, x_px: f64, y_px: f64) ?Hit {
    if (!state.open or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const l = layout(state, items, p) orelse return null;
    const rect = l.rect;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    if (x_px < x0 or x_px >= x0 + @as(f64, @floatFromInt(rect.w))) return null;
    if (y_px < y0 or y_px >= y0 + @as(f64, @floatFromInt(rect.h))) return null;
    const cw: f64 = @floatFromInt(l.cw);
    const card_h: f64 = @floatFromInt(l.card_h);
    const rel_y = y_px - y0;
    const col: u32 = @intFromFloat((x_px - x0) / cw);

    // 상단 헤더(sticky): 좌측 제목 = background(닫지 않음), 우측 "모두 읽음"/"모두 지우기" = 액션. view의 headerActions와 단일 출처.
    if (rel_y < @as(f64, @floatFromInt(l.header_h))) {
        const ha = headerActions(l.panel_cols);
        if (col >= ha.clear_x0) return .clear_all;
        if (col >= ha.mark_x0) return .mark_all_read;
        return .background; // 제목 영역
    }

    // 빈 목록: 헤더 아래 본문(일러스트)은 background(닫지 않음 — 박스 밖만 닫기).
    if (items.len == 0) return .background;

    // 카드 영역(헤더 아래): 보이는 vis번째 → 실제 인덱스 first+vis + 본문줄 우측 ✕인지.
    const rel_card_y = rel_y - @as(f64, @floatFromInt(l.header_h));
    const card_area_h = @as(f64, @floatFromInt(l.visible)) * card_h;
    if (rel_card_y >= card_area_h) return .background; // 카드 아래 빈 여백(최소 높이 gap) — 무시

    const vis_idx: usize = @min(@as(usize, @intFromFloat(rel_card_y / card_h)), l.visible - 1);
    const card_idx = l.first + vis_idx;
    const within = rel_card_y - @as(f64, @floatFromInt(vis_idx)) * card_h;
    const line: u32 = @intFromFloat(within / @as(f64, @floatFromInt(l.ch))); // 0=제목줄, 1=본문줄
    if (line >= 1 and col >= l.panel_cols -| 2) return .{ .close = card_idx }; // 본문줄 우측 끝 ✕
    return .{ .card = card_idx };
}

/// 헤더 우측 액션 라벨(모두 읽음/지우기)을 그린다 — view·빈 상태 공유(헤더는 항상 같은 모양). muted_fg(보조 액션).
fn appendHeaderActions(l: Layout, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const cw: i32 = @intCast(l.cw);
    const ha = headerActions(l.panel_cols);
    const mark_runs = try arena.alloc(draw.Run, 1);
    mark_runs[0] = .{ .text = mark_all_label };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = l.rect.x + @as(i32, @intCast(ha.mark_x0)) * cw, .y = l.rect.y }, .runs = mark_runs, .role = .muted_fg } });
    const clear_runs = try arena.alloc(draw.Run, 1);
    clear_runs[0] = .{ .text = clear_all_label };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = l.rect.x + @as(i32, @intCast(ha.clear_x0)) * cw, .y = l.rect.y }, .runs = clear_runs, .role = .muted_fg } });
}

/// 한 줄 텍스트를 패널 폭 안에 가로 가운데 정렬해 그린다(빈 상태 일러스트). EAW 폭 기준.
fn appendCentered(l: Layout, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op), text: []const u8, y: i32, role: tokens.ColorRole) !void {
    const cw: i32 = @intCast(l.cw);
    const w = overlay_input.displayCols(text);
    const x0_cols: u32 = if (w >= l.panel_cols) 0 else (l.panel_cols - w) / 2;
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = text };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = l.rect.x + @as(i32, @intCast(x0_cols)) * cw, .y = y }, .runs = runs, .role = role } });
}

/// 패널(배경 quad + 헤더 밴드 + 보이는 카드 윈도우 또는 빈 상태 일러스트 + 스크롤바)을 `out`에 append한다. 안 열렸으면
/// 무동작. 카드가 화면을 넘으면 items[first..first+visible]만 그린다(카드 단위 스크롤). 순수: state·items·props·tokens만
/// 읽는다. ops·runs는 호출자 frame arena 소유. 색: surface_bg(박스)·surface_fg(제목·살아있는 글자)·muted_fg(닫힌
/// surface·시간·액션·부제·스크롤바)·tab_active_bg(선택행)·focus_accent(테두리·안읽음 점)·divider(구분선).
pub fn view(
    state: *const State,
    items: []const Item,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const l = layout(state, items, p) orelse return;
    const rect = l.rect;
    const cw: i32 = @intCast(l.cw);
    const ch: i32 = @intCast(l.ch);
    const card_h_i: i32 = @intCast(l.card_h);
    const header_h_i: i32 = @intCast(l.header_h);
    const panel_cols: u32 = l.panel_cols;
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // 패널 배경(둥근+테두리) — context_menu/palette와 동일.
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });

    // 헤더 밴드: "알림" 제목(좌, surface_fg) + 우측 액션(muted_fg). 아래 1px 구분선으로 본문과 분리.
    const heading_runs = try arena.alloc(draw.Run, 1);
    heading_runs[0] = .{ .text = panel_heading };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + cw, .y = rect.y }, .runs = heading_runs, .role = .surface_fg } });
    try appendHeaderActions(l, arena, out);
    try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = rect.y + header_h_i - 1, .w = rect.w, .h = 1 }, .role = .divider } });

    if (items.len == 0) {
        // 빈 상태 일러스트: 종-슬래시 아이콘 + 굵은 제목 + 부제(헤더 아래 본문 영역에 세로로 배치, 가로 가운데).
        const body_top = rect.y + header_h_i;
        try appendCentered(l, arena, out, empty_icon, body_top + ch, .muted_fg); // 본문 r1: 아이콘
        try appendCentered(l, arena, out, empty_heading, body_top + 3 * ch, .surface_fg); // 본문 r3: 제목
        try appendCentered(l, arena, out, empty_subtext, body_top + 4 * ch, .muted_fg); // 본문 r4: 부제
        return;
    }

    // 보이는 윈도우: items[first .. first+visible]만 그린다. 화면 vis번째 카드 y = body_top + vis*card_h.
    const body_top = rect.y + header_h_i;
    var vis: usize = 0;
    while (vis < l.visible) : (vis += 1) {
        const i = l.first + vis; // 실제 item 인덱스
        const it = items[i];
        const card_y = body_top + @as(i32, @intCast(vis)) * card_h_i;
        const fg: tokens.ColorRole = if (it.is_alive) .surface_fg else .muted_fg; // 닫힌 surface는 회색 dim
        // 선택 카드 강조(2행 높이) — palette/context_menu 선택행과 같은 tab_active_bg. 텍스트가 그 위에.
        if (i == state.selected) {
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = card_y, .w = rect.w, .h = l.card_h }, .role = .tab_active_bg } });
        }
        // 제목줄: 안읽음 점(●) + 제목(말줄임) + 우측정렬 상대시간.
        if (!it.is_read) {
            const dot = try arena.alloc(draw.Run, 1);
            dot[0] = .{ .text = "\u{25CF}" }; // ● U+25CF — BMP 기호라 폰트 보유(이모지 fallback 위험 없음)
            try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + cw, .y = card_y }, .runs = dot, .role = .focus_accent } });
        }
        // 상대시간: 패널 우측에서 한 칸 안쪽. 제목은 시간/들여쓰기를 뺀 폭으로 말줄임(겹침 방지).
        const time_cols = overlay_input.displayCols(it.relative_time);
        const time_shown = time_cols > 0 and time_cols + 1 < panel_cols;
        const title_budget: u32 = blk: {
            // [들여쓰기 .. (시간 좌단 − 1)] 사이가 제목 자리. 시간 없으면 우측 1칸 패딩까지.
            const right_cols: u32 = if (time_shown) time_cols + 2 else 1; // 시간 + 1칸 간격 + (우측 패딩 1) ≈ time_cols+2
            break :blk panel_cols -| text_indent_cols -| right_cols;
        };
        const title_text = try overlay_input.truncateToCols(arena, titleText(it), title_budget);
        const title_runs = try arena.alloc(draw.Run, 1);
        title_runs[0] = .{ .text = title_text };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(text_indent_cols)) * cw, .y = card_y }, .runs = title_runs, .role = fg } });
        if (time_shown) {
            const time_runs = try arena.alloc(draw.Run, 1);
            time_runs[0] = .{ .text = it.relative_time };
            const tx = rect.x + @as(i32, @intCast((panel_cols - time_cols - 1))) * cw;
            try out.append(arena, .{ .text = .{ .origin = .{ .x = tx, .y = card_y }, .runs = time_runs, .role = .muted_fg } });
        }
        // 본문줄: 제목과 같은 들여쓰기, 우측 ✕(삭제) zone 1칸을 뺀 폭으로 말줄임.
        const body_budget: u32 = panel_cols -| text_indent_cols -| 2; // 우측 ✕ + 1칸 여백
        const body_text = try overlay_input.truncateToCols(arena, it.body, body_budget);
        const body_runs = try arena.alloc(draw.Run, 1);
        body_runs[0] = .{ .text = body_text };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(text_indent_cols)) * cw, .y = card_y + ch }, .runs = body_runs, .role = fg } });
        // 본문줄 우측 끝에 삭제 ✕(개별 삭제) — hitTest의 close zone(본문줄, panel 우측 1칸)과 같은 col.
        const close_runs = try arena.alloc(draw.Run, 1);
        close_runs[0] = .{ .text = close_glyph };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x + @as(i32, @intCast(panel_cols -| 2)) * cw, .y = card_y + ch }, .runs = close_runs, .role = .muted_fg } });
        // 카드 구분선(보이는 마지막 카드 제외). `.rule`은 macOS no-op이라 `.fill` 1px.
        if (vis + 1 < l.visible) {
            try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = card_y + card_h_i - 1, .w = rect.w, .h = 1 }, .role = .divider } });
        }
    }

    // 스크롤바 thumb(스크롤 가능할 때만) — 카드 영역(헤더 아래) 우측 가장자리에 얇은 막대. 위치/크기 = 보이는 비율.
    if (l.scrollable) {
        const visible_i: i32 = @intCast(l.visible);
        const total_i: i32 = @intCast(l.total);
        const first_i: i32 = @intCast(l.first);
        const card_area_h: i32 = card_h_i * visible_i;
        const thumb_h = @max(ch, @divFloor(card_area_h * visible_i, total_i)); // 최소 1줄
        // thumb을 카드 영역 안에 가둔다(헤더 아래) — 최소 높이로 키운 thumb이 max 스크롤에서 카드 영역 밖으로 삐져나가지 않게 clamp.
        const thumb_max_y = body_top + card_area_h - thumb_h;
        const thumb_y = @min(body_top + @divFloor(card_area_h * first_i, total_i), thumb_max_y);
        const thumb_w: i32 = 2; // 얇은 막대
        const sb_x = rect.x + @as(i32, @intCast(rect.w)) - thumb_w;
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = sb_x, .y = thumb_y, .w = @intCast(thumb_w), .h = @intCast(thumb_h) }, .role = .muted_fg } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "notifications state: show/hide/moveSelection clamp + setItemCount" {
    var s: State = .{};
    try std.testing.expect(!s.open);
    s.show(100, 50, 3);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(1);
    s.moveSelection(1);
    s.moveSelection(1); // 2에서 끝(clamp, wrap 없음)
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(-5);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // 새 알림 도착으로 줄면 selected clamp.
    s.moveSelection(2);
    s.setItemCount(1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.hide();
    try std.testing.expect(!s.open);
}

test "notifications handle: ↑↓=이동, Enter=accept, Backspace=delete, Esc·글자=close" {
    var s: State = .{};
    s.show(0, 0, 2);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.accept, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.open); // accept는 닫지 않는다(host가 hide)
    try std.testing.expectEqual(Action.delete_selected, handle(.{ .key = .backspace }, &s)); // 선택 카드 삭제
    try std.testing.expect(s.open); // delete도 닫지 않는다(platform이 삭제 후 유지)
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "notifications hitTest: 헤더 액션(모두읽음/지우기)·제목=background / 카드 본문=card / 본문줄 우측 ✕=close" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    const items = [_]Item{
        .{ .title = "maru", .body = "PR 머지 완료", .relative_time = "2분 전", .is_read = false, .is_alive = true },
        .{ .title = "web", .body = "빌드 실패", .relative_time = "5분 전", .is_read = true, .is_alive = false },
    };
    var s: State = .{};
    s.show(100, 50, items.len);
    // box_w=(max(content,30)+2)*8=256, x=100, panel_cols=32. 헤더 h=16([50,66)). 카드 first 시작=rect.y+16=66.
    // 항목 2 → content_h=16+2*32=80인데 최소 높이 min_panel_rows(8)×16=128이 더 커 box_h=128(=[50,178)).
    // 카드0=[66,98)(제목 66~82·본문 82~98), 카드1=[98,130). 카드영역 아래 gap=[130,178)=background.
    // headerActions(32): clear_x0=32-11-1=20, mark_x0=20-2-9=9.
    try std.testing.expectEqual(Hit.background, hitTest(&s, &items, p, 110, 55).?); // 헤더 좌측 제목 → background(안 닫음)
    try std.testing.expectEqual(Hit.mark_all_read, hitTest(&s, &items, p, 100 + 10 * 8, 55).?); // 헤더 "모두 읽음"(col 10)
    try std.testing.expectEqual(Hit.clear_all, hitTest(&s, &items, p, 100 + 25 * 8, 55).?); // 헤더 "모두 지우기"(col 25)
    try std.testing.expectEqual(Hit{ .card = 0 }, hitTest(&s, &items, p, 110, 70).?); // 카드0 제목 좌측
    try std.testing.expectEqual(Hit{ .close = 0 }, hitTest(&s, &items, p, 345, 85).?); // 카드0 본문줄 우측 ✕
    try std.testing.expectEqual(Hit{ .card = 0 }, hitTest(&s, &items, p, 345, 70).?); // 제목줄 우측은 ✕ 아님(시간 영역)
    try std.testing.expectEqual(Hit{ .card = 1 }, hitTest(&s, &items, p, 110, 110).?); // 카드1
    try std.testing.expectEqual(Hit.background, hitTest(&s, &items, p, 150, 150).?); // 카드 아래 gap → 무시(닫지 않음)
    try std.testing.expectEqual(@as(?Hit, null), hitTest(&s, &items, p, 110, 400)); // 박스 아래 밖 → null(닫기)
    // 빈 목록: 헤더 아래 본문 클릭 = background(닫지 않음), 박스 밖 = null(닫기).
    var e: State = .{};
    e.show(100, 50, 0);
    try std.testing.expectEqual(Hit.background, hitTest(&e, &.{}, p, 130, 120).?); // 빈 상태 본문 → background
    try std.testing.expectEqual(@as(?Hit, null), hitTest(&e, &.{}, p, 110, 590)); // 박스 밖 → null
}

test "notifications view: 빈목록=헤더+일러스트(아이콘·제목·부제), 항목들=헤더+점·제목·시간·본문·구분선" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    // 닫힘 → 0 ops.
    var closed: State = .{};
    try view(&closed, &.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // 빈 목록 → 패널 quad + 헤더(제목+모두읽음+모두지우기=3) + 구분선 + 일러스트(아이콘+제목+부제=3) = 8.
    out.clearRetainingCapacity();
    var empty: State = .{};
    empty.show(100, 50, 0);
    try view(&empty, &.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 8), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    var saw_heading = false;
    var saw_empty_heading = false;
    var saw_empty_subtext = false;
    var saw_mark = false;
    var saw_clear = false;
    for (out.items) |op| {
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, panel_heading)) saw_heading = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, empty_heading)) saw_empty_heading = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, empty_subtext)) saw_empty_subtext = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, mark_all_label)) saw_mark = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, clear_all_label)) saw_clear = true;
    }
    try std.testing.expect(saw_heading and saw_empty_heading and saw_empty_subtext and saw_mark and saw_clear);

    // 2항목(카드0=unread+alive 선택, 카드1=read+closed).
    out.clearRetainingCapacity();
    const items = [_]Item{
        .{ .title = "maru", .body = "PR 머지 완료", .relative_time = "2분 전", .is_read = false, .is_alive = true },
        .{ .title = "web", .body = "빌드 실패", .relative_time = "5분 전", .is_read = true, .is_alive = false },
    };
    var s: State = .{};
    s.show(100, 50, items.len);
    try view(&s, &items, p, &tk, arena, &out);
    // quad + 헤더(제목+모두읽음+모두지우기=3) + 헤더 구분선(1) + 카드0(선택fill+점+제목+시간+본문+✕+구분선=7) +
    // 카드1(제목+시간+본문+✕=4, 점·구분선 없음) = 16.
    try std.testing.expectEqual(@as(usize, 16), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    // 헤더 제목은 surface_fg, 첫 text op.
    try std.testing.expect(out.items[1] == .text and out.items[1].text.role == .surface_fg);
    try std.testing.expectEqualStrings(panel_heading, out.items[1].text.runs[0].text);
    // 구분선(.fill divider) + 안읽음 점(focus_accent) + 닫힌 surface 제목(muted_fg) + 카드 ✕ 존재 확인.
    var divider_count: usize = 0;
    var saw_dot = false;
    var saw_closed_title = false;
    var close_count: usize = 0;
    for (out.items) |op| {
        if (op == .fill and op.fill.role == .divider) divider_count += 1;
        if (op == .text and op.text.role == .focus_accent and std.mem.eql(u8, op.text.runs[0].text, "\u{25CF}")) saw_dot = true;
        if (op == .text and op.text.role == .muted_fg and std.mem.eql(u8, op.text.runs[0].text, "web")) saw_closed_title = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, close_glyph)) close_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), divider_count); // 헤더 구분선 + 카드0↔카드1 구분선
    try std.testing.expect(saw_dot); // 안읽음 점(카드0)
    try std.testing.expect(saw_closed_title); // 닫힌 surface 제목은 muted_fg(dim)
    try std.testing.expectEqual(@as(usize, 2), close_count); // 카드마다 ✕ 1개
}

test "notifications panelRect: 빈 제목 폴백 + [min,max] 폭 cap + 종 밑(사이드바 안 유지) + 화면 우/하단 clamp" {
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 200,
        .backing_width_px = 1600,
        .backing_height_px = 600,
    } };
    const items = [_]Item{
        .{ .title = "", .body = "본문", .relative_time = "방금", .is_read = false, .is_alive = true }, // 빈 제목 → 폴백
    };
    var s: State = .{};
    // 종 드롭다운이라 사이드바 좌단으로 밀지 않는다 — anchor가 사이드바 안(x=20)이어도 그 자리에 뜬다(종 바로 밑).
    s.show(20, 50, items.len);
    const r = panelRect(&s, &items, p).?;
    try std.testing.expectEqual(@as(i32, 20), r.x); // 사이드바(200) 안이어도 종 위치 유지
    try std.testing.expect(r.w >= min_panel_cols * 8); // 최소 폭 보장
    // 아주 긴 본문 → 최대 폭 cap(과도하게 넓어지지 않음).
    const long = [_]Item{
        .{ .title = "t", .body = "아주 긴 본문 텍스트를 반복해서 채워 넣어 패널이 화면을 가로지를 만큼 넓어지는지 검증한다 한참 더 길게", .relative_time = "방금", .is_read = false, .is_alive = true },
    };
    s.show(20, 50, long.len);
    const rl = panelRect(&s, &long, p).?;
    try std.testing.expectEqual(@as(u32, (max_panel_cols + 2) * 8), rl.w); // [min,max] cap → 최대폭
    // 화면 우/하단 밖 anchor → 안으로 clamp.
    s.show(1590, 595, items.len);
    const r2 = panelRect(&s, &items, p).?;
    try std.testing.expect(r2.x + @as(i32, @intCast(r2.w)) <= 1600);
    try std.testing.expect(r2.y + @as(i32, @intCast(r2.h)) <= 600);
}

test "notifications 스크롤: 화면 넘으면 카드 윈도우(헤더 예약) + scrollBy/ensureSelectedVisible clamp + 스크롤바" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 작은 창(backing_height=100) — card_h=32, header=16이라 카드 1개만 보인다(avail=max(48,100-32)=68, area=68-16=52, 52/32=1).
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 100,
    } };
    var items_buf: [5]Item = undefined;
    for (&items_buf) |*it| it.* = .{ .title = "t", .body = "b", .relative_time = "방금", .is_read = false, .is_alive = true };
    const items: []const Item = &items_buf;

    var s: State = .{};
    s.show(0, 0, items.len);
    const l0 = layout(&s, items, p).?;
    try std.testing.expectEqual(@as(usize, 1), l0.visible); // 한 장만 보임
    try std.testing.expect(l0.scrollable);
    try std.testing.expectEqual(@as(usize, 0), l0.first);

    // 휠 아래로 2 → offset 2(max_offset=total-visible=4). count·metrics만 받는다(Item 빌드 불필요).
    s.scrollBy(items.len, p.metrics, 2);
    try std.testing.expectEqual(@as(usize, 2), s.scroll_offset);
    // 보이는 첫 카드 클릭(헤더 아래) → 실제 인덱스 first(2)로 매핑(보이는==클릭되는).
    const rect = panelRect(&s, items, p).?;
    try std.testing.expectEqual(Hit{ .card = 2 }, hitTest(&s, items, p, @floatFromInt(rect.x + 8), @floatFromInt(rect.y + 16 + 4)).?);

    // 상한/하한 clamp — 끝까지 내려도 4, 끝까지 올려도 0.
    s.scrollBy(items.len, p.metrics, 100);
    try std.testing.expectEqual(@as(usize, 4), s.scroll_offset);
    s.scrollBy(items.len, p.metrics, -100);
    try std.testing.expectEqual(@as(usize, 0), s.scroll_offset);

    // 키보드 선택 따라 스크롤 — selected가 viewport 밖이면 보이게 당긴다(visible=1이라 offset=selected).
    s.selected = 4;
    s.ensureSelectedVisible(items.len, p.metrics);
    try std.testing.expectEqual(@as(usize, 4), s.scroll_offset);
    s.selected = 1;
    s.ensureSelectedVisible(items.len, p.metrics);
    try std.testing.expectEqual(@as(usize, 1), s.scroll_offset);

    // view: 헤더 + 보이는 1장 + 스크롤바 thumb(우측 끝 얇은 muted 막대)만 그린다.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, items, p, &tk, arena_state.allocator(), &out);
    var saw_scrollbar = false;
    var card_titles: usize = 0;
    for (out.items) |op| {
        if (op == .fill and op.fill.role == .muted_fg and op.fill.rect.w == 2) saw_scrollbar = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "t")) card_titles += 1;
    }
    try std.testing.expect(saw_scrollbar); // 스크롤 가능 → thumb 표시
    try std.testing.expectEqual(@as(usize, 1), card_titles); // 보이는 카드 1장만(윈도우)

    // 최대 스크롤(offset=4)에서도 thumb이 카드 영역(헤더 아래)을 넘지 않는다.
    s.scroll_offset = 4;
    out.clearRetainingCapacity();
    try view(&s, items, p, &tk, arena_state.allocator(), &out);
    const rect2 = panelRect(&s, items, p).?;
    const card_area_bottom = rect2.y + 16 + 32; // header(16) + visible(1) × card_h(2×16)
    for (out.items) |op| {
        if (op == .fill and op.fill.rect.w == 2) // 스크롤바 thumb
            try std.testing.expect(op.fill.rect.y + @as(i32, @intCast(op.fill.rect.h)) <= card_area_bottom);
    }
}
