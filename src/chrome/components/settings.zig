//! Settings — schema-주도 세팅 모달(폼). config 스키마의 각 필드를 한 행(라벨 + 위젯)으로 그린다(CS-4-4).
//! palette/find처럼 ChromeHost가 소유하는 오버레이 모달이지만, 행 목록은 platform이 config 스키마에서 빌드해
//! 주입한다(컴포넌트는 config·스키마를 모름 — palette `Row` 선례, L1/L3 경계). 박스 기하는 modal_box 공유
//! 프리미티브, control 위젯은 toggle 등 leaf 컴포넌트를 재사용한다. State(open·selected) + view(rows→박스+행) +
//! handle(키 네비/토글/닫기) + handlePointer(행/위젯 hit-test). 단일 출처: docs/config-gui.md §2·§4.
//!
//! 위젯은 FieldRow.kind union으로 가른다 — bool(toggle)·number(slider)·enum(dropdown)·text(인라인 편집)·color(스와치+hex)
//! ·palette_grid(ANSI 16색 한 줄 그리드). text/color는 고정 버퍼로 hex/문자열을 편집한다(Enter 커밋, Esc 취소 —
//! State.editing/edit_buf). palette_grid는 16칸이라 control 열을 안 쓰고 폼 우측에 스와치 줄을 펼친다(←→로 셀 선택,
//! Enter/hex 클릭으로 그 칸 편집 — State.grid_cell). 레이아웃은 좌측 Section 네비(섹션 목록, platform이 settings.section
//! 으로 필터해 폼 주입) + 우측 폼(선택 섹션 필드, 길면 스크롤 윈도잉) — config-gui §4·§6.5. 폼 검색은 후속.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 라벨 폭 측정(modal_box와 같은 규약)
const toggle = @import("toggle.zig");
const slider = @import("slider.zig");
const dropdown = @import("dropdown.zig");
const color_mod = @import("../../color.zig"); // HSV picker — hsvToRgb/rgbToHsv/Hsv
const color = @import("color.zig");

/// 최상위 모달 레이어(palette/notice와 동일).
pub const layer = modal_box.layer;

/// 한 설정 행(platform이 config 스키마에서 빌드해 주입). kind union으로 위젯 종류를 가른다 — bool(toggle, CS-4-1a)·
/// number(slider, CS-4-1b)·enum(dropdown, CS-4-1c)·text(CS-4-1d)·color(CS-4-2)를 모두 지원한다. 값은 config가 소유(주입만).
pub const FieldRow = struct {
    label: []const u8, // 행 라벨(meta.doc 또는 키)
    kind: Kind,
    // platform이 주입하는 비활성 표식 — 회색(muted_fg)으로 그리고 입력은 platform이 차단/전환한다(예: 테마 프리셋이
    // 활성이면 색·팔레트 행을 잠근다). 값은 config 비소유 — 매 프레임 platform이 판정해 주입(palette 선례와 같은 규율).
    disabled: bool = false,

    pub const Kind = union(enum) {
        toggle: bool, // 현재 on/off
        slider: Slider, // 현재 값 + 범위(f32/u32; value/min/max는 f64로 통일)
        dropdown: []const u8, // enum 현재 변형 표시 토큰(클릭/←→로 순환 — platform이 schema.cycleEnum)
        text: []const u8, // 문자열 현재값(폰트 패밀리). 클릭/Enter로 인라인 편집(platform이 schema.setText)
        color: Color, // 색 #RRGGBB — 스와치 + hex. 스와치/←→로 프리셋 순환, hex 클릭으로 편집(platform)
        palette_grid: PaletteGrid, // ANSI 16색 그리드(theme.palette.0~15) — 스와치 줄 + 선택 셀 hex 편집(CS-4-5)
        keybind: []const u8, // 현재 단축키 표시(⌘T 또는 빈=미지정). Enter/클릭 → 녹음 모드(platform이 raw 키 캡처→rebind, CS-4-3)
    };
    pub const Slider = struct { value: f64, min: f64, max: f64 };
    pub const Color = struct { hex: []const u8, rgb: @import("../../color.zig").Rgb }; // 현재 hex + platform이 파싱한 RGB(스와치)
    /// ANSI 16색 팔레트 그리드. cells[i]=효과색(platform이 config override 또는 xterm256 기본을 resolve), selected=선택 셀
    /// (=State.grid_cell 주입). 색은 ColorRole이 아니라 원색 — 스와치(Op.swatch)로 그린다(color 위젯과 같은 의도적 예외).
    pub const PaletteGrid = struct {
        cells: [16]Cell,
        selected: usize,
        pub const Cell = struct { rgb: @import("../../color.zig").Rgb, hex: []const u8 };
    };

    /// 슬라이더 값의 정규화 위치(0..1). min==max면 0(0분모 가드).
    fn sliderRatio(s: Slider) f32 {
        if (s.max <= s.min) return 0;
        return @floatCast(std.math.clamp((s.value - s.min) / (s.max - s.min), 0, 1));
    }
};

/// 순수 상태 — 열림 + 포커스된 행 + 슬라이더 드래그 상태. 행 데이터(rows)는 State에 두지 않고 매 프레임 platform이
/// 주입한다(config 단일 출처 — palette 선례). 값도 config가 소유하므로 handle은 의도(toggle/slider_set/adjust)만
/// 내고 실제 변경+write-back은 platform이 한다. slider 드래그 중엔 pending_ratio에 최신 ratio를 담아 platform이 읽는다.
/// 인라인 편집 버퍼 용량(바이트) — 폰트 패밀리·#RRGGBB는 짧아 고정 버퍼면 충분(별도 allocator 불요).
const edit_cap: usize = 128;
/// 검색 쿼리 버퍼 용량(바이트) — 짧은 키워드면 충분(고정 버퍼).
const search_cap: usize = 64;

// HSV 색 picker 기하 — SV 그리드(채도 col × 명도 row) + hue 스트립. 셀-그리드 tui라 이산 해상도(셀 단위 샘플).
const pick_sv_cols: u32 = 16; // 채도 0~100
const pick_sv_rows: u32 = 8; // 명도 100~0(위→아래)
const pick_swatch_w: u32 = 2; // 셀당 2칸(가시성)
const pick_hue_cols: u32 = 16; // hue 0~360
const pick_help = "←→ 채도  ↑↓ 명도  [ ] 색상  Enter 확정  Esc 취소";
// picker 콘텐츠 행: 제목(0) + SV 그리드(1..pick_sv_rows) + hue 스트립 + 미리보기 + 도움말.
const pick_hue_row: u32 = 1 + pick_sv_rows;
const pick_preview_row: u32 = pick_hue_row + 1;
const pick_help_row: u32 = pick_hue_row + 2;
const pick_content_rows: u32 = pick_help_row + 1;

// SV 그리드/hue 스트립의 셀↔값 매핑(이산 샘플). col→채도, row→명도(위가 높음), col→색상. 역함수는 현재 h/s/v를
// 가장 가까운 셀로 스냅(마커 위치·키 스텝). 정수 반올림(+분모/2)으로 양 끝(0/100, 0/360)에 정확히 닿는다.
fn svSatForCol(col: u32) u8 {
    return @intCast(col * 100 / (pick_sv_cols - 1));
}
fn svValForRow(row: u32) u8 {
    return @intCast((pick_sv_rows - 1 - row) * 100 / (pick_sv_rows - 1));
}
fn svColForSat(s: u8) u32 {
    return (@as(u32, s) * (pick_sv_cols - 1) + 50) / 100;
}
fn svRowForVal(v: u8) u32 {
    return (pick_sv_rows - 1) - (@as(u32, v) * (pick_sv_rows - 1) + 50) / 100;
}
fn hueForCol(col: u32) u16 {
    return @intCast(col * 360 / pick_hue_cols);
}
fn hueColForHue(h: u16) u32 {
    // hueForCol(col)=col*360/16은 truncate(360/16=22.5 비정수)다. 역변환을 floor로 하면 odd column이 복원 안 돼
    // hueColForHue(hueForCol(9))=8처럼 어긋나, '['/']' 키가 같은 hue로 되돌아오며 stuck되고 ▾ 마커가 실제 swatch보다
    // 한 칸 왼쪽에 그려진다(code-review #1). +180(=360/2) round로 좌역원을 만든다 — SV 그리드(svColForSat의 +50)와
    // 같은 반올림 규율. %로 끝(h≈360)을 col 0으로 wrap.
    return ((@as(u32, h) * pick_hue_cols + 180) / 360) % pick_hue_cols;
}

/// picker 모달 박스 기하 — renderPicker와 handlePointer가 같은 출처로 공유(hit-test/렌더 일관). SV 그리드 폭과
/// 도움말 폭 중 큰 쪽으로 content_cols. null이면 화면이 너무 좁음.
fn pickerLayout(p: props.ChromeProps, tk: *const tokens.Tokens) ?modal_box.Box {
    const sv_w = pick_sv_cols * pick_swatch_w;
    const help_cols: u32 = @intCast(overlay_input.displayCols(pick_help));
    return modal_box.layout(@max(sv_w, help_cols), pick_content_rows, p, tk);
}

pub const State = struct {
    open: bool = false,
    selected: usize = 0,
    /// 좌측 네비에서 선택된 섹션 인덱스(폼은 이 섹션의 필드만 — config-gui §4). platform이 buildSectionList 순서와
    /// 맞춰 필터/라벨을 주입한다. 섹션 전환 시 selected=0으로(첫 필드).
    section: usize = 0,
    /// 현재 행 수 — platform이 매 프레임 setFieldCount로 주입(palette.setResultCount 선례). host 키 라우팅이 행 목록
    /// 없이 handle(k,&state)를 부를 수 있게(wrap 가드).
    count: usize = 0,
    /// 슬라이더 드래그 진행 중(down이 슬라이더에서 시작해 up까지). move를 그 행에 캡처한다(divider 드래그 패턴).
    dragging: bool = false,
    /// 드래그/클릭이 만든 최신 슬라이더 ratio(0..1). platform이 .slider_set에서 읽어 rows[selected]의 값으로 매핑한다.
    pending_ratio: f32 = 0,
    /// text 행 인라인 편집 중. 켜지면 키가 편집 버퍼로 라우팅된다(Enter=커밋, Esc=취소). platform이 enterEdit로 켜고
    /// (현재값 시드) .text_commit에서 editText()를 읽어 config arena에 dupe→setText. 별도 allocator 없이 고정 버퍼.
    editing: bool = false,
    edit_buf: [edit_cap]u8 = undefined,
    edit_len: usize = 0,
    /// palette_grid 행에서 선택된 셀(0~15). ←→가 이 값을 옮기고(platform이 moveGridCell), Enter/hex 클릭이 이 셀을
    /// 편집한다. 행 1개에 16칸이라 폼의 1D selected와 별도로 둔다(slider 드래그 상태가 별도인 것과 동형).
    grid_cell: usize = 0,
    /// keybind 행 녹음 중(Enter/클릭으로 켜짐) — 다음 raw 키를 platform이 가로채 chord로 캡처한다(컴포넌트 handle을
    /// 안 거침). 켜지면 그 행이 "키 입력 대기..."로 보인다. platform이 캡처/취소 후 끈다(text editing과 별개 상태).
    recording: bool = false,
    /// 현재 섹션 폼 검색 중(`/`로 시작, Esc로 종료). 켜지면 char가 검색 버퍼로 가고, platform이 searchQuery()로 행을
    /// 필터한다(라벨 부분일치). ↑↓ 나비·Enter 활성은 그대로(필터된 행 위에서). 고정 버퍼라 별도 allocator 불요.
    searching: bool = false,
    search_buf: [search_cap]u8 = undefined,
    search_len: usize = 0,
    /// HSV 색 picker 모드(color 행 활성 시 platform이 openPicker로 켬). 켜지면 폼 대신 SV 그리드 + hue 스트립을 그리고
    /// ←→(채도)·↑↓(명도)·`[`/`]`(색상)·포인터로 h/s/v를 고른다. Enter 확정(platform이 hex→setText), Esc 취소. h 0~359·s/v 0~100.
    picking: bool = false,
    pick_h: u16 = 0,
    pick_s: u8 = 0,
    pick_v: u8 = 0,
    /// 좌측 섹션 네비에 키보드 포커스가 있는가(Tab으로 폼↔네비 전환). true면 ↑↓=섹션 이동·Enter/→=폼 복귀, false(기본)면
    /// 폼 모드(↑↓=행·←→=값 — 기존). show에서 false(폼으로 시작), 네비 클릭도 폼 작업이라 false. nav 모드 ↑↓는
    /// selectSection만 호출해 이 플래그를 보존한다(selectSection은 nav_focused를 안 건드린다).
    nav_focused: bool = false,

    pub fn show(self: *State) void {
        self.open = true;
        self.selected = 0;
        self.section = 0;
        self.dragging = false;
        self.editing = false;
        self.grid_cell = 0;
        self.recording = false;
        self.searching = false;
        self.search_len = 0;
        self.picking = false;
        self.nav_focused = false; // 모달 열 때는 폼 모드로 시작
    }
    /// HSV picker 열기(platform이 color 행 활성 시 호출 — 현재 색 rgb로 초기 h/s/v 시드). 폼 키/포인터가 picker로 라우팅된다.
    pub fn openPicker(self: *State, rgb: color_mod.Rgb) void {
        const hsv = color_mod.rgbToHsv(rgb);
        self.pick_h = hsv.h;
        self.pick_s = hsv.s;
        self.pick_v = hsv.v;
        self.picking = true;
    }
    pub fn closePicker(self: *State) void {
        self.picking = false;
        self.dragging = false; // picker 드래그 중 Esc 취소 시 dragging이 폼으로 새지 않게(다른 mode-exit와 동일, code-review)
    }
    /// 현재 선택 h/s/v의 RGB(미리보기·확정 hex 산출). platform이 확정 시 #rrggbb로 직렬화.
    pub fn pickerRgb(self: *const State) color_mod.Rgb {
        return color_mod.hsvToRgb(.{ .h = self.pick_h, .s = self.pick_s, .v = self.pick_v });
    }
    /// 섹션 전환(좌측 네비 클릭) — 선택 섹션과 첫 필드로. platform이 새 섹션 필드 수를 setFieldCount로 다시 준다.
    pub fn selectSection(self: *State, i: usize) void {
        self.section = i;
        self.selected = 0;
        self.dragging = false;
        self.editing = false;
        self.grid_cell = 0;
        self.recording = false;
        self.searching = false; // 섹션 바꾸면 검색 초기화(필터는 섹션 내라)
        self.search_len = 0;
        self.picking = false;
    }
    /// 검색 쿼리(현재 버퍼). platform이 currentSectionFields에서 읽어 행을 필터한다.
    pub fn searchQuery(self: *const State) []const u8 {
        return self.search_buf[0..self.search_len];
    }
    /// 검색 시작(`/`) — 빈 쿼리로 모드 진입. 켜는 동안 selected는 보존(필터 후 platform이 clamp).
    pub fn startSearch(self: *State) void {
        self.searching = true;
        self.search_len = 0;
    }
    /// 검색 종료(Esc) — 쿼리 비우고 모드 해제(필터 풀려 전체 행 복귀).
    pub fn endSearch(self: *State) void {
        self.searching = false;
        self.search_len = 0;
    }
    /// 검색 쿼리에 코드포인트 추가(UTF-8, 넘치면 무시 — 고정 버퍼).
    pub fn appendSearchCp(self: *State, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.search_len + n > search_cap) return;
        @memcpy(self.search_buf[self.search_len..][0..n], tmp[0..n]);
        self.search_len += n;
    }
    /// 검색 쿼리 마지막 코드포인트 제거(UTF-8 경계).
    pub fn backspaceSearch(self: *State) void {
        if (self.search_len == 0) return;
        var i = self.search_len - 1;
        while (i > 0 and (self.search_buf[i] & 0xC0) == 0x80) i -= 1;
        self.search_len = i;
    }
    /// palette_grid 선택 셀을 delta만큼 옮긴다(wrap, 0..15). platform이 ←→(adjust)에서 호출(선택 행이 palette_grid일 때).
    pub fn moveGridCell(self: *State, delta: i32) void {
        const n: i32 = @intCast(palette_count);
        const cur: i32 = @intCast(@min(self.grid_cell, palette_count - 1));
        self.grid_cell = @intCast(@mod(cur + delta, n));
    }
    /// 인라인 편집 시작(platform이 text 행 활성 시 호출 — 현재값으로 시드). 버퍼 초과는 잘라 담되, UTF-8 코드포인트
    /// 중간에서 자르지 않게 경계로 back-up한다(리뷰 #823 — 잘린 멀티바이트는 무효 UTF-8 → view/backspace 오작동).
    pub fn enterEdit(self: *State, value: []const u8) void {
        var n = @min(value.len, edit_cap);
        if (n < value.len) {
            while (n > 0 and (value[n] & 0xC0) == 0x80) n -= 1; // continuation 바이트면 코드포인트 시작까지 back-up
        }
        @memcpy(self.edit_buf[0..n], value[0..n]);
        self.edit_len = n;
        self.editing = true;
    }
    pub fn cancelEdit(self: *State) void {
        self.editing = false;
    }
    pub fn editText(self: *const State) []const u8 {
        return self.edit_buf[0..self.edit_len];
    }
    /// 코드포인트 한 개를 UTF-8로 버퍼에 추가(넘치거나 인코딩 불가면 무시 — 고정 버퍼).
    pub fn appendEditCp(self: *State, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.edit_len + n > edit_cap) return;
        @memcpy(self.edit_buf[self.edit_len..][0..n], tmp[0..n]);
        self.edit_len += n;
    }
    /// 마지막 코드포인트(UTF-8 경계) 제거.
    pub fn backspaceEdit(self: *State) void {
        if (self.edit_len == 0) return;
        var i = self.edit_len - 1;
        while (i > 0 and (self.edit_buf[i] & 0xC0) == 0x80) i -= 1; // continuation 바이트 건너뛰기
        self.edit_len = i;
    }
    pub fn hide(self: *State) void {
        self.open = false;
        self.dragging = false;
        self.editing = false;
        self.recording = false;
        self.searching = false;
        self.search_len = 0;
        self.picking = false;
    }
    pub fn setFieldCount(self: *State, n: usize) void {
        self.count = n;
        if (n > 0 and self.selected >= n) self.selected = n - 1;
    }
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.count == 0) return;
        const c: i32 = @intCast(self.count);
        const cur: i32 = @intCast(@min(self.selected, self.count - 1));
        const next = @mod(cur + delta, c); // @mod(.,c>0) ∈ [0,c) — 음수 보정 불요(리뷰 #823: dead branch 제거)
        self.selected = @intCast(next);
    }
};

/// handle/handlePointer가 돌려주는 intent. platform이 rows[selected] 기준으로 처리:
///   toggle=bool flip, slider_set=pending_ratio→값 매핑, adjust_left/right=slider 한 스텝, selection_changed=재렌더,
///   close=hide, consumed=소비만(모달 뒤로 안 샘). 값 종류 판정(toggle인지 slider인지)은 platform이 rows로 한다.
pub const Action = enum { close, toggle, slider_set, adjust_left, adjust_right, selection_changed, section_changed, text_commit, search_changed, delete_row, color_picked, consumed };

const label_gap_cols: u32 = 2; // 라벨과 우측 위젯 사이 최소 간격(칸)

/// control 열 폭(칸) — 모든 행이 같은 우측 열을 공유한다(가장 넓은 위젯=slider 기준). 픽셀 폭을 cw로 ceil. view/
/// hitTest 단일 출처. toggle은 이 열 안에서 좌측정렬(slider·dropdown과 같은 시작 x). text/dropdown 값(폰트 패밀리·
/// 테마 프리셋명 등)이 slider 폭보다 길 수 있어 settings_value_cols로 하한을 둬 값이 박스 안에서 충분히 보이게 한다
/// (그래도 넘치는 값은 view에서 truncate). 열이 곧 박스 우측 경계라(fieldControlRect 우측정렬) 값이 박스를 안 넘는다.
fn controlCols(ch: u32, cw: u32) u32 {
    return @max((slider.width(ch) + cw - 1) / @max(cw, 1), settings_value_cols);
}

// ── palette_grid 기하(control 열을 공유하지 않는 특수 행 — 16칸은 control 열에 안 들어간다) ───────────────
const palette_count: u32 = 16; // ANSI 0~15
const palette_swatch_w: u32 = 2; // 스와치 1칸당 셀 폭(가시성 — 1칸 8px은 너무 작아 2칸)
const palette_hex_cols: u32 = 12; // 선택 셀 "NN  #rrggbb"(=11) + 좌측 1칸 여백 — 인덱스 표시(셀 색과 무관한 선택 표식)

/// palette_grid 행의 우측 블록 폭(칸) = 16 스와치 + 1 여백 + hex 열. computeLayout이 폼 폭 산정에 쓴다.
fn paletteGridCols() u32 {
    return palette_count * palette_swatch_w + 1 + palette_hex_cols;
}

const nav_gap_cols: u32 = 2; // 좌측 네비와 폼 사이 간격(칸) — 구분 여백
// 폼 라벨 고정 예약 폭(칸) — 모달 너비를 섹션·내용 무관 고정으로 두기 위해 라벨을 실측하지 않고 이 폭으로 예약한다.
// 현재 스키마 최장 라벨 "셸 실행 파일 경로(절대경로, 빈 값=자동)"(≈36칸)을 담는 값. 더 긴 라벨은 view에서 truncate해
// control 열을 침범하지 않게 한다(고정 폭 유지 — 라벨 실측으로 폭을 늘리면 모달이 섹션마다 들썩이던 문제가 재발).
const form_label_reserve: u32 = 38;
const palette_label_reserve: u32 = 14; // palette 행 라벨("ANSI 팔레트") 예약 폭
// control 열 최소 폭(칸) — text 값(폰트 패밀리 "JetBrains Mono"=14)·dropdown 프리셋명("catppuccin-mocha"=16)을
// 잘리지 않고 담는 하한. slider 폭이 이보다 넓으면 그쪽을 쓴다(controlCols).
const settings_value_cols: u32 = 24;

/// 좌측 네비 폭(칸) — 가장 긴 섹션 라벨 + 좌측 1칸 패딩(선택 표식 여유). 빈 목록이면 최소 5.
fn navCols(sections: []const []const u8) u32 {
    var w: u32 = 4;
    for (sections) |s| w = @max(w, overlay_input.displayCols(s));
    return w + 1;
}

const Layout = struct {
    box: modal_box.Box,
    ctrl_cols: u32,
    first_field_row: u32,
    win_start: usize, // 보이는 창의 첫 행(전체 rows 인덱스) — 행이 많으면 selected 주위로 스크롤된다
    win_len: usize, // 보이는 행 수(= min(count, maxVisible))
    nav_cols: u32, // 좌측 네비 폭(칸)
    form_x: i32, // 폼 영역 좌단(px) = inner_x + (nav_cols + nav_gap_cols)*cw
    form_cols: u32, // 폼 영역 폭(칸) = inner_cols - nav_cols - nav_gap_cols
    body_rows: u32, // 네비/폼 본문 행 수(FullHeight = maxVisible) — 활성 영역 세로 강조 바 높이·하단 힌트 행 위치에 쓴다
};

const title_rows: u32 = 2; // 제목(0) + 빈 줄(1)
const hint_rows: u32 = 1; // 하단 힌트 1행("⇥ 섹션 ⇄ 설정" — Tab 영역 전환 안내). content_rows에 더해 박스 하단에 둔다.

/// 한 화면에 보일 최대 필드 행 수 — 뷰포트 높이에서 제목·여백·여유를 뺀다. 행이 이보다 많으면 창을 스크롤한다
/// (패널이 화면을 넘치지 않게). palette.max_visible과 같은 윈도잉 취지(여긴 뷰포트 적응형).
fn maxVisible(p: props.ChromeProps) usize {
    const ch = @max(p.metrics.cell_height_px, 1);
    const avail = p.metrics.backing_height_px / ch; // 화면에 들어가는 총 행
    return @max(@as(usize, 4), @as(usize, avail) -| 7); // 제목 2 + 위아래 여백 2 + 여유 3
}

/// selected가 보이도록 [0,total)에서 길이 mv(≤total)인 창의 시작을 고른다(palette 윈도잉: 끝맞춤 + clamp).
fn windowStart(total: usize, selected: usize, mv: usize) usize {
    if (total <= mv) return 0;
    var s: usize = if (selected >= mv) selected - mv + 1 else 0;
    if (s + mv > total) s = total - mv;
    return s;
}

fn computeLayout(sections: []const []const u8, rows: []const FieldRow, selected: usize, p: props.ChromeProps, tk: *const tokens.Tokens) ?Layout {
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const ctrl_cols = controlCols(ch, cw);
    const nav_cols = navCols(sections);
    // 폼 폭은 **고정**이다(섹션·행 내용·창 크기에 불변) — 예전엔 현재 섹션의 라벨/위젯 최대 폭으로 매 프레임 재서
    // 산정해 섹션을 바꿀 때마다 모달 너비가 들썩였고, 긴 값(폰트 패밀리 등)이 박스를 넘어 rich 테마에서 배경 quad
    // 밖으로 삐져나가 깨졌다. form_label_reserve(가장 긴 라벨 담는 고정 칸) + control/palette 폭으로 못 박는다.
    // 라벨은 reserve로, 값은 view에서 control 폭으로 truncate해 항상 박스 안에 가둔다(palette/find 고정 폭과 같은 취지).
    const form_content: u32 = @max(
        form_label_reserve + label_gap_cols + ctrl_cols, // 스칼라 행: 라벨 예약 + control 열
        palette_label_reserve + label_gap_cols + paletteGridCols(), // palette 행: 16 스와치 + hex 블록
    );
    const title_need = overlay_input.displayCols(title_text) + 12; // 제목 + 스크롤 위치 표식 여유
    const content_cols = @max(nav_cols + nav_gap_cols + form_content, title_need);
    const mv = maxVisible(p);
    const win_start = windowStart(rows.len, @min(selected, rows.len -| 1), mv);
    const win_len = @min(rows.len, mv);
    // 박스 높이는 **항상 가용 최대(FullHeight)** — win_len(보이는 행 수) 대신 mv(maxVisible)로 고정해, 행이 적은
    // 섹션에서도 모달이 작아졌다 커졌다 하지 않고 화면 높이에 꽉 차게 한다(너비는 content_cols로 별도 고정 — #860).
    // 네비(섹션 수)가 mv보다 많을 일은 거의 없지만 안전하게 큰 쪽을 쓴다. win_len은 폼 스크롤 윈도로 그대로 유지.
    const body_rows = @max(sections.len, mv);
    const content_rows = title_rows + @as(u32, @intCast(body_rows)) + hint_rows; // + 하단 힌트 1행
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    const form_x = box.inner_x + @as(i32, @intCast((nav_cols + nav_gap_cols) * box.cw));
    const form_cols = box.inner_cols -| (nav_cols + nav_gap_cols);
    // 창이 너무 좁아 modal_box가 박스를 nav+gap+control보다 좁게 clamp하면 form_cols가 control 열보다 작아져
    // fieldControlRect의 (form_cols -| ctrl_cols)가 0으로 saturate → 위젯이 라벨 위로 겹쳐 그려졌다(리뷰 #823).
    // 그 경우 레이아웃 불가로 보고 null(view/handlePointer가 그리지 않음 — 창을 넓히면 보임). modal_box가 폭 부족 시
    // 그리는 것과 같은 "안 되면 안 그림" 규율.
    if (form_cols <= ctrl_cols) return null;
    return .{ .box = box, .ctrl_cols = ctrl_cols, .first_field_row = title_rows, .win_start = win_start, .win_len = win_len, .nav_cols = nav_cols, .form_x = form_x, .form_cols = form_cols, .body_rows = @intCast(body_rows) };
}

/// 보이는 폼 행 vi(0..win_len)의 control 열 rect(폼 영역 우측, ctrl_cols 폭, 행 높이). slider는 전체, toggle은 좌측정렬.
fn fieldControlRect(l: Layout, vi: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(vi));
    const ctrl_x = l.form_x + @as(i32, @intCast((l.form_cols -| l.ctrl_cols) * box.cw));
    return .{ .x = ctrl_x, .y = modal_box.rowY(box, row), .w = l.ctrl_cols * box.cw, .h = box.ch };
}

/// palette_grid 행의 그리드 블록 rect(폼 우측, paletteGridCols 폭 — control 열과 무관, 우측정렬). 16 스와치 + hex.
fn paletteGridRect(l: Layout, vi: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(vi));
    const cols = paletteGridCols();
    const gx = l.form_x + @as(i32, @intCast((l.form_cols -| cols) * box.cw));
    return .{ .x = gx, .y = modal_box.rowY(box, row), .w = cols * box.cw, .h = box.ch };
}

/// 그리드 블록 안 i번째 스와치 셀 rect(palette_swatch_w칸 폭).
fn paletteSwatchRect(grid: draw.Rect, i: usize, cw: u32, ch: u32) draw.Rect {
    return .{ .x = grid.x + @as(i32, @intCast(@as(u32, @intCast(i)) * palette_swatch_w * cw)), .y = grid.y, .w = palette_swatch_w * cw, .h = ch };
}

/// 그리드 블록 안 hex 텍스트 좌단 x(16 스와치 + 1 여백 뒤).
fn paletteHexX(grid: draw.Rect, cw: u32) i32 {
    return grid.x + @as(i32, @intCast((palette_count * palette_swatch_w + 1) * cw));
}

/// control 열 안의 toggle rect — **좌측정렬**(ctrl 좌단). slider(전체)·dropdown(좌단 text)과 같은 시작 x라
/// 세 위젯의 control 열 left edge가 일관된다(text 위젯 전환 후 정렬 통일). hit-test/view 공유. 폭은 그려지는 위젯
/// 전체 — tui 트랙 `[  ]`(4*cw)이 pill(width(ch))보다 넓을 수 있어 둘 중 큰 쪽(클릭=보이는 위젯, 리뷰 #823).
fn toggleRectIn(ctrl: draw.Rect, ch: u32, cw: u32) draw.Rect {
    return .{ .x = ctrl.x, .y = ctrl.y, .w = @max(toggle.width(ch), 4 * cw), .h = ch };
}

const title_text = "Settings";

/// 모달 박스 + 제목 + 좌측 Section 네비(선택 강조) + 우측 폼(선택 섹션 필드 행 — 선택 하이라이트 → 라벨 → 위젯)을
/// 그린다(config-gui §4). 빈 rows여도 박스는 띄운다. 순수: state·sections·rows·props·tokens만 읽는다. out/op은 호출자
/// (platform) frame arena 소유. sections=네비 라벨, rows=선택 섹션의 필드(platform이 settings.section으로 필터해 주입).
pub fn view(
    state: *const State,
    sections: []const []const u8,
    rows: []const FieldRow,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    if (state.picking) return renderPicker(state, p, tk, arena, out); // HSV picker 모드 — 폼 대신 그리드+스트립
    const l = computeLayout(sections, rows, state.selected, p, tk) orelse return;
    const box = l.box;
    try modal_box.frame(box, p, arena, out);
    // 제목 — 검색 중이면 "검색: <쿼리>▏"(accent + caret), 아니면 "Settings" + 폼이 창보다 많으면 sel/total 위치 표식.
    if (state.searching) {
        const title = try std.fmt.allocPrint(arena, "검색: {s}", .{state.searchQuery()});
        try modal_box.text(box, box.inner_x, 0, title, .accent_bar, arena, out);
        const caret_x = box.inner_x + @as(i32, @intCast(overlay_input.displayCols(title) * box.cw));
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = modal_box.rowY(box, 0), .w = box.cw, .h = box.ch }, .role = .cursor } });
    } else {
        const title = if (rows.len > l.win_len)
            try std.fmt.allocPrint(arena, "{s}   {d}/{d}", .{ title_text, @min(state.selected + 1, rows.len), rows.len })
        else
            title_text;
        try modal_box.text(box, box.inner_x, 0, title, .surface_fg, arena, out);
    }

    // 좌측 네비: 섹션 라벨. inner_x 칸은 활성 영역 세로 바 자리로 비우고, 선택 강조(tab_active_bg)·라벨은 그 우측
    // (inner_x+cw)부터 둔다. Tab 포커스가 폼에 있으면(!nav_focused) 비선택 섹션 라벨을 muted로 흐려, 지금 키 입력이
    // 가는 영역이 폼임을 보인다(선택 섹션은 어느 섹션인지 알게 accent 유지).
    const cw_i: i32 = @intCast(box.cw);
    for (sections, 0..) |label, i| {
        const row = l.first_field_row + @as(u32, @intCast(i));
        if (i == state.section) {
            try modal_box.fillCells(box, box.inner_x + cw_i, row, l.nav_cols -| 1, .tab_active_bg, arena, out);
        }
        const role: tokens.ColorRole = if (i == state.section) .accent_bar else if (!state.nav_focused) .muted_fg else .surface_fg;
        try modal_box.text(box, box.inner_x + cw_i, row, label, role, arena, out);
    }

    // 우측 폼: 보이는 창 [win_start, win_start+win_len)만(스크롤). vi=화면 행, actual=섹션 내 전체 인덱스.
    var vi: usize = 0;
    while (vi < l.win_len) : (vi += 1) {
        const actual = l.win_start + vi;
        const r = rows[actual];
        const content_row = l.first_field_row + @as(u32, @intCast(vi));
        // control/palette 우측 폭 — 라벨 truncate와 선택 하이라이트가 공유한다.
        const row_right_cols: u32 = switch (r.kind) {
            .palette_grid => paletteGridCols(),
            else => l.ctrl_cols,
        };
        // 선택 행 하이라이트. rich 테마에서 **GPU quad 위젯(slider/toggle)** 만 모달 셀(이 하이라이트가 사는 곳)보다 아래
        // 레이어(layer 3 quad)라, 행 전체를 칠하면 하이라이트 셀이 그 위젯을 덮어 가린다 → 그 행만 **control 칸을 비워**
        // (라벨 영역만 칠해) 위젯이 빈 surface 셀로 비쳐 보이게 한다. color·palette의 swatch는 `Op.swatch`→`paintRectBg`로
        // **셀 bg 레이어**에 이 하이라이트 뒤에 그려져(painter order) 덮이지 않고, dropdown/text/keybind 값도 text 셀이라
        // 안 가려지므로 — 이들은 행 전체를 칠한다(불필요한 하이라이트 손실 방지).
        if (actual == state.selected) {
            const quad_widget = switch (r.kind) {
                .toggle, .slider => true,
                else => false,
            };
            const hl_cols = if (quad_widget) l.form_cols -| row_right_cols else l.form_cols;
            try modal_box.fillCells(box, l.form_x, content_row, hl_cols, .tab_hover_bg, arena, out);
        }
        // 비활성 행(프리셋 잠금)이거나 Tab 포커스가 네비에 있을 때(nav_focused)는 라벨을 muted로 — 폼이 비활성 영역임을 흐림으로 보인다.
        const label_role: tokens.ColorRole = if (r.disabled or state.nav_focused) .muted_fg else .surface_fg;
        // 라벨도 control/palette 열을 침범하지 않게 폼 라벨 영역 폭으로 truncate(고정 폭 안에 가둠 — rich quad 밖 삐짐 방지).
        const label_shown = overlay_input.truncateToCols(arena, r.label, l.form_cols -| row_right_cols -| label_gap_cols) catch r.label;
        try modal_box.text(box, l.form_x, content_row, label_shown, label_role, arena, out);
        const ctrl = fieldControlRect(l, vi);
        switch (r.kind) {
            .toggle => |v| {
                var ts = toggle.State{ .value = v };
                try toggle.view(&ts, toggleRectIn(ctrl, box.ch, box.cw), box.cw, tk, arena, out);
            },
            .slider => |s| try slider.view(ctrl, FieldRow.sliderRatio(s), box.cw, tk, arena, out),
            // dropdown.view가 값 뒤에 " ▾"(2칸)를 붙이므로, chevron 자리를 빼고 truncate해 값+chevron이 control 열(=박스
            // 경계)을 넘지 않게 한다(안 그러면 ctrl_cols+2칸이 되어 우측 여백을 침범·rich quad 밖으로 삐진다).
            .dropdown => |cur| try dropdown.view(ctrl, overlay_input.truncateToCols(arena, cur, l.ctrl_cols -| 2) catch cur, tk, arena, out),
            .text => |cur| {
                // 편집 중인 선택 행이면 편집 버퍼 + caret, 아니면 현재값. control 좌단(ctrl.x) 좌측정렬 text.
                // 비편집 값은 control 폭으로 truncate해 박스 밖으로 삐지지 않게 한다(긴 폰트 패밀리 등 — rich quad 밖 비침 방지).
                const editing_this = state.editing and actual == state.selected;
                const shown: []const u8 = if (editing_this) state.editText() else (overlay_input.truncateToCols(arena, cur, l.ctrl_cols) catch cur);
                const text_role: tokens.ColorRole = if (editing_this) .accent_bar else .surface_fg;
                if (shown.len > 0) {
                    const runs = try arena.alloc(draw.Run, 1);
                    runs[0] = .{ .text = shown };
                    try out.append(arena, .{ .text = .{ .origin = .{ .x = ctrl.x, .y = ctrl.y }, .runs = runs, .role = text_role } });
                }
                if (editing_this) {
                    // caret = 편집 텍스트 끝 셀에 cursor fill 1칸(palette 입력 caret 패턴).
                    const caret_x = ctrl.x + @as(i32, @intCast(overlay_input.displayCols(shown) * box.cw));
                    try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = ctrl.y, .w = box.cw, .h = box.ch }, .role = .cursor } });
                }
            },
            .color => |c| {
                // 스와치(literal RGB) + hex. 편집 중인 선택 행이면 hex 대신 편집 버퍼 + caret(hexX 뒤). text 위젯과 동형.
                const editing_this = state.editing and actual == state.selected;
                const shown: []const u8 = if (editing_this) state.editText() else c.hex;
                const text_role: tokens.ColorRole = if (editing_this) .accent_bar else if (r.disabled) .muted_fg else .surface_fg;
                try color.view(ctrl, c.rgb, shown, text_role, box.cw, arena, out);
                if (editing_this) {
                    const caret_x = color.hexX(ctrl, box.cw) + @as(i32, @intCast(overlay_input.displayCols(shown) * box.cw));
                    try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = ctrl.y, .w = box.cw, .h = box.ch }, .role = .cursor } });
                }
            },
            .palette_grid => |g| {
                // 16 스와치(원색 Op.swatch) 한 줄 + 선택 셀 테두리(accent) + 선택 셀 hex(편집 중이면 버퍼 + caret).
                const grid = paletteGridRect(l, vi);
                var ci: usize = 0;
                while (ci < palette_count) : (ci += 1) {
                    const sw = paletteSwatchRect(grid, ci, box.cw, box.ch);
                    try out.append(arena, .{ .swatch = .{ .rect = sw, .rgb = g.cells[ci].rgb } });
                }
                // 선택 표식: 셀 위에 Op.border/fill을 얹으면 tui lowering(paintRectBg)이 1행 높이라 셀 전체를 그 색으로 칠해
                // 스와치 색을 덮는다. 그래서 **마커 글리프 ▾**를 선택 스와치 위에 text 레이어로 얹는다 — 글리프라 셀 bg(스와치
                // 색)는 거의 안 가리고 어느 칸인지 보여준다(우측 "N  #hex" 인덱스 텍스트와 함께). accent_bar 색.
                const sel = @min(g.selected, palette_count - 1);
                const sel_sw = paletteSwatchRect(grid, sel, box.cw, box.ch);
                const marker = try arena.alloc(draw.Run, 1);
                marker[0] = .{ .text = "▾" };
                try out.append(arena, .{ .text = .{ .origin = .{ .x = sel_sw.x, .y = sel_sw.y }, .runs = marker, .role = .accent_bar } });
                const editing_this = state.editing and actual == state.selected;
                // "N  #rrggbb"(선택 ANSI 인덱스 + hex). 셀 색이 accent와 비슷하면 테두리가 묻히므로 인덱스 텍스트로 어느
                // 칸인지 항상 분명히 보여준다(편집 중에도). 편집 중이면 hex 자리는 입력 버퍼, caret이 그 끝에 붙는다.
                const body: []const u8 = if (editing_this) state.editText() else g.cells[sel].hex;
                const shown = try std.fmt.allocPrint(arena, "{d}  {s}", .{ sel, body });
                const text_role: tokens.ColorRole = if (editing_this) .accent_bar else if (r.disabled) .muted_fg else .surface_fg;
                const hex_x = paletteHexX(grid, box.cw);
                const runs = try arena.alloc(draw.Run, 1);
                runs[0] = .{ .text = shown };
                try out.append(arena, .{ .text = .{ .origin = .{ .x = hex_x, .y = grid.y }, .runs = runs, .role = text_role } });
                if (editing_this) {
                    const caret_x = hex_x + @as(i32, @intCast(overlay_input.displayCols(shown) * box.cw));
                    try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = grid.y, .w = box.cw, .h = box.ch }, .role = .cursor } });
                }
            },
            .keybind => |chord| {
                // control 열에 현재 단축키 표시(dropdown과 같은 좌단 정렬 text). 녹음 중인 선택 행이면 "키 입력 대기..."
                // accent로(platform이 raw 키를 가로채 chord 캡처). 빈 chord는 "(미지정)".
                const recording_this = state.recording and actual == state.selected;
                const shown: []const u8 = if (recording_this) "키 입력 대기..." else if (chord.len > 0) chord else "(미지정)";
                const text_role: tokens.ColorRole = if (recording_this) .accent_bar else .surface_fg;
                const runs = try arena.alloc(draw.Run, 1);
                runs[0] = .{ .text = shown };
                try out.append(arena, .{ .text = .{ .origin = .{ .x = ctrl.x, .y = ctrl.y }, .runs = runs, .role = text_role } });
            },
        }
    }

    // 활성 영역(Tab 포커스) 좌단 세로 강조 바 — 섹션 모드는 네비 좌단(inner_x), 폼 모드는 폼 좌단 직전(form_x-cw).
    // 지금 ↑↓·←→가 어느 영역에 작용하는지(섹션 이동 vs 값 조절)를 한눈에 보인다. 폼/네비 op 뒤에 둬 위 레이어로 얹는다.
    const bar_x: i32 = if (state.nav_focused) box.inner_x else l.form_x - cw_i;
    try out.append(arena, .{ .fill = .{ .rect = .{ .x = bar_x, .y = modal_box.rowY(box, l.first_field_row), .w = box.cw, .h = box.ch * l.body_rows }, .role = .accent_bar } });

    // 하단 힌트: Tab으로 섹션(좌측)↔설정 폼(우측) 영역을 오간다는 안내. 본문 아래 한 줄에 muted로 둔다(활성 영역은
    // 위 세로 바 + 비활성 dim으로 강조). 어느 영역이 활성이냐에 따라 ↑↓는 섹션 이동/행 이동으로 갈린다.
    const hint_row = l.first_field_row + l.body_rows;
    try modal_box.text(box, box.inner_x, hint_row, "⇥ 섹션 ⇄ 설정", .muted_fg, arena, out);
}

/// 선택 마커 ▾를 (x, row) 셀 위에 accent text로 얹는다(palette와 같은 이유 — Op.border는 tui lowering이 셀 전체를
/// 칠해 스와치 색을 덮으므로 마커 글리프를 text 레이어로). 스와치 bg는 거의 안 가린다.
fn pickerMarker(box: modal_box.Box, x: i32, row: u32, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const marker = try arena.alloc(draw.Run, 1);
    marker[0] = .{ .text = "▾" };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = modal_box.rowY(box, row) }, .runs = marker, .role = .accent_bar } });
}

/// HSV picker 렌더 — SV 그리드(채도 col × 명도 row 원색 스와치, 현재 hue 고정) + hue 스트립(채도·명도 100) + 미리보기
/// 스와치 + "#rrggbb  H S V" + 도움말. 셀-그리드라 이산 샘플. 선택 셀은 ▾ 마커(스와치를 안 덮음 — pickerMarker 주석).
fn renderPicker(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    const box = pickerLayout(p, tk) orelse return;
    try modal_box.frame(box, p, arena, out);
    try modal_box.text(box, box.inner_x, 0, "HSV 색 선택", .accent_bar, arena, out);

    const sw_px: i32 = @intCast(pick_swatch_w * box.cw);
    // SV 그리드 — 행 1..pick_sv_rows. 각 셀은 (col→채도, row→명도)로 현재 hue의 원색.
    var ry: u32 = 0;
    while (ry < pick_sv_rows) : (ry += 1) {
        var cx: u32 = 0;
        while (cx < pick_sv_cols) : (cx += 1) {
            const rgb = color_mod.hsvToRgb(.{ .h = state.pick_h, .s = svSatForCol(cx), .v = svValForRow(ry) });
            const rect = draw.Rect{ .x = box.inner_x + @as(i32, @intCast(cx)) * sw_px, .y = modal_box.rowY(box, 1 + ry), .w = pick_swatch_w * box.cw, .h = box.ch };
            try out.append(arena, .{ .swatch = .{ .rect = rect, .rgb = rgb } });
        }
    }
    const sel_col = svColForSat(state.pick_s);
    const sel_row = svRowForVal(state.pick_v);
    try pickerMarker(box, box.inner_x + @as(i32, @intCast(sel_col)) * sw_px, 1 + sel_row, arena, out);

    // hue 스트립 — 채도·명도 100 고정, col→색상.
    var hc: u32 = 0;
    while (hc < pick_hue_cols) : (hc += 1) {
        const rgb = color_mod.hsvToRgb(.{ .h = hueForCol(hc), .s = 100, .v = 100 });
        const rect = draw.Rect{ .x = box.inner_x + @as(i32, @intCast(hc)) * sw_px, .y = modal_box.rowY(box, pick_hue_row), .w = pick_swatch_w * box.cw, .h = box.ch };
        try out.append(arena, .{ .swatch = .{ .rect = rect, .rgb = rgb } });
    }
    try pickerMarker(box, box.inner_x + @as(i32, @intCast(hueColForHue(state.pick_h))) * sw_px, pick_hue_row, arena, out);

    // 미리보기 스와치(현재 효과색) + "#rrggbb  H S V".
    const cur = state.pickerRgb();
    const preview = draw.Rect{ .x = box.inner_x, .y = modal_box.rowY(box, pick_preview_row), .w = pick_swatch_w * box.cw, .h = box.ch };
    try out.append(arena, .{ .swatch = .{ .rect = preview, .rgb = cur } });
    const info = try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}  H{d} S{d} V{d}", .{ cur.r, cur.g, cur.b, state.pick_h, state.pick_s, state.pick_v });
    try modal_box.text(box, box.inner_x + sw_px + @as(i32, @intCast(box.cw)), pick_preview_row, info, .surface_fg, arena, out);

    try modal_box.text(box, box.inner_x, pick_help_row, pick_help, .surface_fg, arena, out);
}

/// 키 처리(열려 있을 때만 host 호출). ↑↓=행 이동, ←→=선택 행 조절(slider 스텝; toggle은 platform이 무시), Space/Enter=
/// 선택 행 활성(toggle flip; slider는 무시), Esc=닫기, 그 외=소비. 값 종류 판정은 platform이 rows[selected]로 한다.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    // HSV picker 모드 — ←→ 채도, ↑↓ 명도, `[`/`]` 색상, Enter 확정(.color_picked → platform이 hex 커밋), Esc 취소. 그 외 소비.
    if (state.picking) {
        switch (k.key) {
            .escape => {
                state.closePicker();
                return .selection_changed; // picker만 닫고 폼 복귀(모달 유지)
            },
            .enter => return .color_picked,
            .left => {
                const col = svColForSat(state.pick_s);
                if (col > 0) state.pick_s = svSatForCol(col - 1);
                return .selection_changed;
            },
            .right => {
                const col = svColForSat(state.pick_s);
                if (col + 1 < pick_sv_cols) state.pick_s = svSatForCol(col + 1);
                return .selection_changed;
            },
            .up => {
                const row = svRowForVal(state.pick_v);
                if (row > 0) state.pick_v = svValForRow(row - 1);
                return .selection_changed;
            },
            .down => {
                const row = svRowForVal(state.pick_v);
                if (row + 1 < pick_sv_rows) state.pick_v = svValForRow(row + 1);
                return .selection_changed;
            },
            .char => {
                if (k.codepoint == '[') {
                    const c = hueColForHue(state.pick_h);
                    state.pick_h = hueForCol((c + pick_hue_cols - 1) % pick_hue_cols);
                    return .selection_changed;
                }
                if (k.codepoint == ']') {
                    const c = hueColForHue(state.pick_h);
                    state.pick_h = hueForCol((c + 1) % pick_hue_cols);
                    return .selection_changed;
                }
                return .consumed;
            },
            else => return .consumed,
        }
    }
    // 인라인 편집 중이면 키를 편집 버퍼로 라우팅한다(Enter=커밋, Esc=취소, Backspace/글자=버퍼 편집). 다른 키는 소비.
    if (state.editing) {
        switch (k.key) {
            .enter => return .text_commit, // platform이 editText()→config arena dupe→setText
            .escape => {
                state.cancelEdit();
                return .selection_changed; // 편집 취소(모달은 안 닫음)
            },
            .backspace => {
                state.backspaceEdit();
                return .selection_changed;
            },
            .char => {
                state.appendEditCp(k.codepoint);
                return .selection_changed;
            },
            else => return .consumed,
        }
    }
    // 검색 중이면 char가 쿼리로(필터), ↑↓=필터된 행 나비, Enter=활성, Esc=검색 종료, Backspace=쿼리 편집. 그 외 소비.
    if (state.searching) {
        switch (k.key) {
            .escape => {
                state.endSearch();
                return .search_changed; // 종료 + 필터 해제(전체 행 복귀)
            },
            .backspace => {
                state.backspaceSearch();
                return .search_changed;
            },
            .up => {
                state.moveSelection(-1);
                return .selection_changed;
            },
            .down => {
                state.moveSelection(1);
                return .selection_changed;
            },
            .enter => return if (state.count == 0) .consumed else .toggle, // 필터된 선택 행 활성
            .char => {
                state.appendSearchCp(k.codepoint);
                return .search_changed;
            },
            else => return .consumed,
        }
    }
    // 좌측 섹션 네비에 키보드 포커스(Tab으로 진입/이탈) — ↑↓=섹션 이동, Enter/→=폼 복귀, Esc=닫기. slider/색의 ←→ 값
    // 조절과 충돌하지 않게 진입은 Tab으로만 한다(영역 전환 = Tab/Shift+Tab, 둘 다 토글이라 mods.shift는 안 본다).
    if (state.nav_focused) {
        switch (k.key) {
            .escape => {
                state.hide();
                return .close;
            },
            .tab => {
                state.nav_focused = false; // 폼으로 복귀
                return .selection_changed;
            },
            .up => {
                if (state.section == 0) return .consumed; // 첫 섹션에서 위 = 정지
                state.selectSection(state.section - 1); // selectSection은 nav_focused를 안 건드려 네비 모드 유지
                return .section_changed;
            },
            .down => {
                state.selectSection(state.section + 1); // 상한은 platform이 clamp(섹션 수를 컴포넌트는 모른다)
                return .section_changed;
            },
            .enter, .right => {
                state.nav_focused = false; // 현재 섹션 확정 → 폼으로
                return .selection_changed;
            },
            else => return .consumed,
        }
    }
    switch (k.key) {
        .escape => {
            state.hide();
            return .close;
        },
        .tab => {
            state.nav_focused = true; // 좌측 네비로 포커스 진입(폼↔네비 토글)
            return .selection_changed;
        },
        .up => {
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            state.moveSelection(1);
            return .selection_changed;
        },
        .left => return if (state.count == 0) .consumed else .adjust_left,
        .right => return if (state.count == 0) .consumed else .adjust_right,
        .enter => return if (state.count == 0) .consumed else .toggle,
        .backspace => return if (state.count == 0) .consumed else .delete_row, // 선택 행 삭제(platform이 env 행만 처리)
        .char => {
            if (k.codepoint == '/') { // '/'로 검색 시작(현재 섹션 필터)
                state.startSearch();
                return .search_changed;
            }
            return if (k.codepoint == ' ' and state.count > 0) .toggle else .consumed;
        },
        else => return .consumed,
    }
}

/// HSV picker 포인터 — down/move(드래그)로 SV 그리드 셀→s/v, hue 스트립 셀→h. 박스 밖 down=picker 취소(폼 복귀, 모달
/// 유지). up·비-히트는 소비. 기하는 renderPicker와 같은 pickerLayout 출처.
fn pickerPointer(ev: input.PointerEvent, p: props.ChromeProps, tk: *const tokens.Tokens, state: *State) Action {
    if (ev.phase == .up) {
        state.dragging = false;
        return .consumed;
    }
    const box = pickerLayout(p, tk) orelse return .consumed;
    const bx: f64 = @floatFromInt(box.rect.x);
    const by: f64 = @floatFromInt(box.rect.y);
    const inside = ev.x_px >= bx and ev.x_px < bx + @as(f64, @floatFromInt(box.rect.w)) and
        ev.y_px >= by and ev.y_px < by + @as(f64, @floatFromInt(box.rect.h));
    if (ev.phase == .down and !inside) {
        state.closePicker();
        return .selection_changed; // 밖 클릭 → picker만 취소
    }
    if (ev.phase == .move and !state.dragging) return .consumed; // 버튼 안 누른 hover는 값 안 바꿈(폼 move 가드와 동일)
    if (ev.phase == .down) state.dragging = true; // 박스 안 down → 드래그 시작(이후 move가 그리드 추적)
    if (!inside) return .consumed; // 드래그가 밖으로 나가도 모달은 유지(값만 안 바뀜)
    // 셀 col/row = (px - inner) / (셀폭·행높이). 그리드 좌단은 inner_x, 셀폭은 pick_swatch_w*cw.
    const sw_px: f64 = @floatFromInt(pick_swatch_w * box.cw);
    const ch_px: f64 = @floatFromInt(box.ch);
    const inner_x: f64 = @floatFromInt(box.inner_x);
    const col_f = (ev.x_px - inner_x) / sw_px;
    if (col_f < 0) return .consumed;
    const sv_y0: f64 = @floatFromInt(modal_box.rowY(box, 1));
    const hue_y0: f64 = @floatFromInt(modal_box.rowY(box, pick_hue_row));
    if (ev.y_px >= sv_y0 and ev.y_px < sv_y0 + @as(f64, @floatFromInt(pick_sv_rows)) * ch_px) {
        const col: u32 = @intFromFloat(col_f);
        if (col >= pick_sv_cols) return .consumed;
        const row: u32 = @intFromFloat((ev.y_px - sv_y0) / ch_px);
        state.pick_s = svSatForCol(col);
        state.pick_v = svValForRow(@min(row, pick_sv_rows - 1));
        return .selection_changed;
    }
    if (ev.y_px >= hue_y0 and ev.y_px < hue_y0 + ch_px) {
        const col: u32 = @intFromFloat(col_f);
        if (col >= pick_hue_cols) return .consumed;
        state.pick_h = hueForCol(col);
        return .selection_changed;
    }
    return .consumed;
}

/// 포인터 처리(열려 있을 때만). up=드래그 종료(소비). down=박스 밖이면 닫기, 안이면 행 선택 후 위젯별:
///   slider 위→드래그 시작 + pending_ratio + .slider_set, toggle 위→.toggle, 그 외(라벨)→.selection_changed.
///   move=드래그 중이고 선택 행이 slider면 pending_ratio 갱신 + .slider_set, 아니면 소비. 우클릭=소비.
pub fn handlePointer(
    ev: input.PointerEvent,
    sections: []const []const u8,
    rows: []const FieldRow,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    state: *State,
) Action {
    if (ev.button != .left) return .consumed;
    // HSV picker 모드 — SV 그리드/hue 스트립 클릭·드래그로 s/v·h 선택, 박스 밖 클릭은 picker 취소(폼 복귀). 폼 hit-test 안 함.
    if (state.picking) return pickerPointer(ev, p, tk, state);
    const l = computeLayout(sections, rows, state.selected, p, tk) orelse return .consumed;
    const box = l.box;

    if (ev.phase == .up) {
        state.dragging = false;
        return .consumed;
    }
    if (ev.phase == .move) {
        // 드래그 중이고 선택 행이 slider면 x→ratio로 추적(divider 라이브 드래그 패턴). 아니면 소비. 선택 행의 화면
        // 위치 = selected - win_start(windowStart가 selected를 창 안에 보장).
        if (!state.dragging or state.selected >= rows.len) return .consumed;
        if (rows[state.selected].kind != .slider) return .consumed;
        state.pending_ratio = slider.ratioAt(fieldControlRect(l, state.selected -| l.win_start), ev.x_px);
        return .slider_set;
    }
    // down.
    const bx: f64 = @floatFromInt(box.rect.x);
    const by: f64 = @floatFromInt(box.rect.y);
    const inside = ev.x_px >= bx and ev.x_px < bx + @as(f64, @floatFromInt(box.rect.w)) and
        ev.y_px >= by and ev.y_px < by + @as(f64, @floatFromInt(box.rect.h));
    if (!inside) {
        state.hide();
        return .close;
    }
    // 인라인 편집 중 다른 곳 down → 편집 종료(버퍼가 다른 행으로 새지 않게 — 리뷰 #823). 같은 text control을 다시
    // 누르면 아래에서 .toggle → platform이 현재값으로 재시드한다(커밋은 Enter 전용).
    if (state.editing) state.cancelEdit();
    if (state.recording) state.recording = false; // 녹음 중 다른 곳 클릭 → 녹음 취소(아래에서 같은 keybind 재클릭 시 다시 켜짐)
    // 좌측 네비 영역(x < form_x) 클릭 → 섹션 행 선택(y로 판정). 비-행이면 소비.
    const form_x_f: f64 = @floatFromInt(l.form_x);
    if (ev.x_px < form_x_f) {
        for (sections, 0..) |_, i| {
            const ny: f64 = @floatFromInt(modal_box.rowY(box, l.first_field_row + @as(u32, @intCast(i))));
            if (ev.y_px >= ny and ev.y_px < ny + @as(f64, @floatFromInt(box.ch))) {
                state.nav_focused = false; // 클릭 선택은 폼 작업 — 좌측 네비 키 포커스 해제
                if (i == state.section) return .selection_changed; // 같은 섹션 재클릭 — 부수효과 없음
                state.selectSection(i);
                return .section_changed;
            }
        }
        return .consumed;
    }
    // 우측 폼 영역: 보이는 창만 hit-test. vi=화면 행, actual=섹션 내 전체 인덱스(win_start+vi).
    var vi: usize = 0;
    while (vi < l.win_len) : (vi += 1) {
        const actual = l.win_start + vi;
        const r = rows[actual];
        const ctrl = fieldControlRect(l, vi);
        const ry: f64 = @floatFromInt(ctrl.y);
        if (ev.y_px >= ry and ev.y_px < ry + @as(f64, @floatFromInt(ctrl.h))) {
            state.selected = actual;
            switch (r.kind) {
                .toggle => return if (toggle.hitTest(toggleRectIn(ctrl, box.ch, box.cw), ev.x_px, ev.y_px)) .toggle else .selection_changed,
                .slider => {
                    if (!slider.hitTest(ctrl, ev.x_px, ev.y_px)) return .selection_changed;
                    state.dragging = true;
                    state.pending_ratio = slider.ratioAt(ctrl, ev.x_px);
                    return .slider_set;
                },
                .dropdown => return if (dropdown.hitTest(ctrl, ev.x_px, ev.y_px)) .toggle else .selection_changed, // 클릭 → 변형 순환(.toggle=활성)
                .text => return if (ev.x_px >= @as(f64, @floatFromInt(ctrl.x))) .toggle else .selection_changed, // control 영역 클릭 → 인라인 편집(.toggle=활성), 라벨은 선택만
                .color => |c| {
                    // 비활성(프리셋 잠금)이면 swatch/hex 어디를 눌러도 인라인 편집을 직접 시작하지 않고 .toggle을 올린다 —
                    // platform이 "사용자 지정"으로 전환한 뒤 picker를 연다(클릭 시 자동 전환 후 편집).
                    if (r.disabled) return .toggle;
                    switch (color.zoneAt(ctrl, box.cw, ev.x_px, ev.y_px)) {
                        .swatch => return .toggle, // 스와치 클릭 → 프리셋 순환(.toggle=활성, platform이 cycleColor)
                        .hex => { // hex 클릭 → 인라인 편집(현재 hex 시드 — 컴포넌트가 rows 값을 가짐)
                            state.enterEdit(c.hex);
                            return .selection_changed;
                        },
                        .outside => return .selection_changed,
                    }
                },
                .palette_grid => |g| {
                    // 비활성(프리셋 잠금)이면 클릭을 .toggle로 — platform이 사용자 지정 전환 후 편집(color 잠금과 동형).
                    if (r.disabled) return .toggle;
                    // 스와치 줄: 어느 칸인지 hit-test → grid_cell 선택. hex 영역 클릭 → 선택 셀 인라인 편집(color hex 클릭과 동형).
                    const grid = paletteGridRect(l, vi);
                    const hex_x: f64 = @floatFromInt(paletteHexX(grid, box.cw));
                    if (ev.x_px >= hex_x) {
                        const sel = @min(state.grid_cell, palette_count - 1);
                        state.enterEdit(g.cells[sel].hex);
                        return .selection_changed;
                    }
                    const gx: f64 = @floatFromInt(grid.x);
                    const sw_w: f64 = @floatFromInt(palette_swatch_w * box.cw);
                    const span: f64 = sw_w * @as(f64, @floatFromInt(palette_count));
                    if (ev.x_px >= gx and ev.x_px < gx + span) {
                        const idx: usize = @intFromFloat((ev.x_px - gx) / sw_w);
                        state.grid_cell = @min(idx, palette_count - 1);
                    }
                    return .selection_changed; // 스와치 선택만(편집은 hex 클릭/Enter — color 행의 select-then-act와 동형)
                },
                .keybind => return if (ev.x_px >= @as(f64, @floatFromInt(ctrl.x))) .toggle else .selection_changed, // control 영역 클릭 → 녹음 시작(.toggle=활성, platform이 recording 켬), 라벨은 선택만
            }
        }
    }
    return .consumed; // 박스 안 비-행(제목/여백) — 소비만
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_props = props.ChromeProps{ .metrics = .{
    .cell_width_px = 8,
    .cell_height_px = 16,
    .sidebar_width_px = 40,
    .backing_width_px = 1000,
    .backing_height_px = 600,
} };

// 섹션 없는 폼(네비 ops 0 — 폼 동작만 보는 테스트용). 폼은 빈 네비 폭만큼 우로 밀린다(form_x).
const no_sections: []const []const u8 = &.{};
const test_sections = [_][]const u8{ "Font", "Cursor", "Window" };

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "settings windowStart: 전체≤창=0, 넘치면 selected를 창 안에 끝맞춤·clamp" {
    try std.testing.expectEqual(@as(usize, 0), windowStart(5, 3, 10)); // 전체(5) ≤ 창(10) → 0
    try std.testing.expectEqual(@as(usize, 0), windowStart(20, 2, 10)); // selected 2 < 창 → 0
    try std.testing.expectEqual(@as(usize, 3), windowStart(20, 12, 10)); // selected 12 → start=12-10+1=3
    try std.testing.expectEqual(@as(usize, 10), windowStart(20, 19, 10)); // 끝(19) → start=20-10=10(clamp)
    try std.testing.expectEqual(@as(usize, 10), windowStart(20, 25, 10)); // selected 범위 밖이어도 clamp
}

test "settings view: 행이 창보다 많으면 창만 렌더 + 제목에 위치 표식 + selected가 창 안" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    // 작은 뷰포트(backing_height 작게)로 maxVisible를 줄여 윈도잉을 강제한다.
    const small = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 1000, .backing_height_px = 200 } };
    var rows: [20]FieldRow = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .label = "field", .kind = .{ .toggle = (i % 2 == 0) } };
    var s = State{};
    s.show();
    s.setFieldCount(rows.len);
    s.selected = 18; // 끝 근처 — 창이 끝으로 스크롤되고 selected가 보여야 한다
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, small, &tk, arena, &out);
    const mv = maxVisible(small);
    try std.testing.expect(mv < rows.len); // 윈도잉 발생(작은 뷰포트)
    // 제목에 "Settings   19/20" 위치 표식(rows.len > win_len).
    try std.testing.expect(std.mem.indexOf(u8, out.items[2].text.runs[0].text, "19/20") != null);
    // 패널 높이가 전체 20행이 아니라 창(mv)만큼이라 뷰포트(200) 안.
    try std.testing.expect(out.items[0].quad.rect.h <= 200);
}

test "settings state: show/hide/setFieldCount clamp/moveSelection wrap" {
    var s = State{};
    s.show();
    s.setFieldCount(3);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(-1); // wrap to last
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(1); // wrap to first
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    // setFieldCount이 줄면 selected clamp.
    s.selected = 2;
    s.setFieldCount(2);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.setFieldCount(0); // 0이면 clamp 안 함(0행)
    s.moveSelection(1); // count 0 → no-op
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    s.hide();
    try std.testing.expect(!s.open);
}

test "settings handle: ↑↓ 네비·←→ 조절·Space/Enter 토글·Esc 닫기·그 외 소비" {
    var s = State{};
    s.show();
    s.setFieldCount(3);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(Action.adjust_left, handle(.{ .key = .left }, &s)); // slider 스텝 다운(platform 판정)
    try std.testing.expectEqual(Action.adjust_right, handle(.{ .key = .right }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .char, .codepoint = ' ' }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'a' }, &s));
    // count 0 → enter/space/←→ 대상 없음 → consumed.
    s.setFieldCount(0);
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .left }, &s));
    // Esc → close + hide.
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "settings view: 닫힘=0 ops, 열림=frame+제목+toggle 행(트랙+knob text)+slider 행(트랙+채움 text)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, no_sections, &.{}, test_props, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show();
    const rows = [_]FieldRow{
        .{ .label = "Cursor blink", .kind = .{ .toggle = true } },
        .{ .label = "Font size", .kind = .{ .slider = .{ .value = 512, .min = 1, .max = 512 } } }, // ratio=1 → 채움 op
    };
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    // tui: 위젯이 모두 셀 정렬 text(quad 아님 — paintRectBg 셀 번짐·선택 하이라이트 가림 회피). frame(quad+border)=2,
    // 제목=1. 행0(선택 fill + label + toggle 트랙 text + knob text)=4. 행1(label + slider 트랙 text + 채움 text)=3.
    try std.testing.expect(out.items[0] == .quad and out.items[1] == .border); // 박스 bg+테두리
    try std.testing.expect(out.items[2] == .text); // 제목
    try std.testing.expect(out.items[3] == .fill); // 행0 선택 하이라이트(셀 bg)
    try std.testing.expectEqualStrings("Cursor blink", out.items[4].text.runs[0].text);
    try std.testing.expect(out.items[5] == .text); // toggle 트랙(muted) — quad 아님
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[5].text.role);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[6].text.role); // toggle knob on(앰버)
    // 행1: 라벨 + slider 트랙 text(muted) + 채움 text(accent).
    try std.testing.expectEqualStrings("Font size", out.items[7].text.runs[0].text);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[8].text.role); // slider 트랙
    // slider 채움(accent) 뒤에 활성 영역 세로 바(fill) + 하단 힌트(text)가 본문 op 뒤로 붙는다.
    const hint = out.items[out.items.len - 1];
    try std.testing.expectEqualStrings("⇥ 섹션 ⇄ 설정", hint.text.runs[0].text); // 하단 힌트
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, hint.text.role);
    try std.testing.expect(out.items[out.items.len - 2] == .fill); // 활성 영역 세로 바
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[out.items.len - 3].text.role); // slider 채움 █(앰버)
}

test "settings handlePointer: 박스 밖=닫기, toggle 클릭=.toggle, slider 드래그=.slider_set+pending_ratio, 라벨=.selection_changed" {
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{
        .{ .label = "A", .kind = .{ .toggle = false } },
        .{ .label = "Size", .kind = .{ .slider = .{ .value = 1, .min = 1, .max = 100 } } },
    };
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;

    // 박스 밖(0,0) 좌클릭 → 닫기.
    try std.testing.expectEqual(Action.close, handlePointer(.{ .phase = .down, .x_px = 0, .y_px = 0 }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expect(!s.open);

    // 행0 toggle 중앙 클릭 → 선택=0 + .toggle.
    s.show();
    const tgl = toggleRectIn(fieldControlRect(l, 0), test_props.metrics.cell_height_px, test_props.metrics.cell_width_px);
    try std.testing.expectEqual(Action.toggle, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(tgl.x + 4), .y_px = @floatFromInt(tgl.y + 4) }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 행1 slider 우측 끝 근처 down → 선택=1 + 드래그 시작 + .slider_set + pending_ratio≈1.
    const c1 = fieldControlRect(l, 1);
    const right_x: f64 = @floatFromInt(c1.x + @as(i32, @intCast(c1.w)) - 2);
    const mid_y: f64 = @floatFromInt(c1.y + 4);
    try std.testing.expectEqual(Action.slider_set, handlePointer(.{ .phase = .down, .x_px = right_x, .y_px = mid_y }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expect(s.dragging);
    try std.testing.expect(s.pending_ratio > 0.9);

    // 드래그 move(왼쪽으로) → .slider_set + pending_ratio 작아짐.
    try std.testing.expectEqual(Action.slider_set, handlePointer(.{ .phase = .move, .x_px = @floatFromInt(c1.x + 2), .y_px = mid_y }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expect(s.pending_ratio < 0.1);

    // up → 드래그 종료(소비).
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .up, .x_px = right_x, .y_px = mid_y }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expect(!s.dragging);

    // 행0 폼 라벨 영역 클릭(form_x — control 왼쪽, 위젯 밖) → .selection_changed.
    const c0 = fieldControlRect(l, 0);
    try std.testing.expectEqual(Action.selection_changed, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 2), .y_px = @floatFromInt(c0.y + 4) }, no_sections, &rows, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}

test "settings nav 키보드: Tab 폼↔네비 토글 + ↑↓ 섹션 + Enter 폼 복귀" {
    var s = State{};
    s.show();
    s.section = 1;
    s.count = 3;
    try std.testing.expect(!s.nav_focused); // 폼 모드로 시작

    // 폼 모드 Tab → 좌측 네비 진입
    _ = handle(.{ .key = .tab }, &s);
    try std.testing.expect(s.nav_focused);

    // 네비 ↓ → 섹션 +1, 네비 모드 유지(selectSection이 nav_focused를 안 건드림)
    try std.testing.expectEqual(Action.section_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 2), s.section);
    try std.testing.expect(s.nav_focused);

    // 네비 ↑ → 섹션 -1
    try std.testing.expectEqual(Action.section_changed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.section);

    // 첫 섹션에서 ↑ → 정지(consumed, 섹션 불변)
    s.section = 0;
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.section);

    // Enter → 폼 복귀
    _ = handle(.{ .key = .enter }, &s);
    try std.testing.expect(!s.nav_focused);

    // Tab 토글: 폼 → 네비 → 폼
    _ = handle(.{ .key = .tab }, &s);
    try std.testing.expect(s.nav_focused);
    _ = handle(.{ .key = .tab }, &s);
    try std.testing.expect(!s.nav_focused);
}

test "settings nav: 섹션 라벨 렌더(선택 강조) + 네비 클릭 → section_changed·section 전환·selected 리셋" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{.{ .label = "A", .kind = .{ .toggle = false } }};
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, &test_sections, &rows, test_props, &tk, arena, &out);
    // 좌측 네비 섹션 라벨이 ops에 그려진다(선택 섹션 0은 accent_bar, 나머지 surface_fg).
    var found_font = false;
    var found_cursor = false;
    for (out.items) |op| {
        if (op == .text) {
            if (std.mem.eql(u8, op.text.runs[0].text, "Font")) found_font = true;
            if (std.mem.eql(u8, op.text.runs[0].text, "Cursor")) found_cursor = true;
        }
    }
    try std.testing.expect(found_font and found_cursor);

    // 네비 영역(x < form_x) 섹션 1(Cursor) 행 클릭 → section_changed + section=1 + selected=0.
    const l = computeLayout(&test_sections, &rows, s.selected, test_props, &tk).?;
    const ny: f64 = @floatFromInt(modal_box.rowY(l.box, l.first_field_row + 1));
    s.selected = 0;
    const act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 4), .y_px = ny + 4 }, &test_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.section_changed, act);
    try std.testing.expectEqual(@as(usize, 1), s.section);
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 같은 섹션(1) 재클릭 → selection_changed(부수효과 없음).
    const act2 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 4), .y_px = ny + 4 }, &test_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, act2);
    try std.testing.expectEqual(@as(usize, 1), s.section);
}

test "settings text edit: enterEdit 시드 + char/backspace 편집 + Enter=text_commit + Esc=취소(close 아님)" {
    var s = State{};
    s.show();
    // 편집 시작 — 현재값 시드.
    s.enterEdit("ABC");
    try std.testing.expect(s.editing);
    try std.testing.expectEqualStrings("ABC", s.editText());
    // editing 중 char → 버퍼 추가(handle이 appendEditCp 라우팅).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .char, .codepoint = 'D' }, &s));
    try std.testing.expectEqualStrings("ABCD", s.editText());
    // backspace → 마지막 코드포인트 제거.
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .backspace }, &s));
    try std.testing.expectEqualStrings("ABC", s.editText());
    // Enter → text_commit(platform이 editText 읽어 setText + cancelEdit).
    try std.testing.expectEqual(Action.text_commit, handle(.{ .key = .enter }, &s));
    // Esc(편집 중) → 편집 취소(모달 close 아님).
    s.enterEdit("X");
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.editing);
    try std.testing.expect(s.open); // 모달은 안 닫힘

    // UTF-8 경계: 한글(3바이트) append→backspace.
    s.enterEdit("");
    s.appendEditCp('한');
    try std.testing.expectEqual(@as(usize, 3), s.editText().len);
    s.backspaceEdit();
    try std.testing.expectEqual(@as(usize, 0), s.editText().len);

    // enterEdit가 edit_cap에서 잘릴 때 멀티바이트 코드포인트를 쪼개지 않는다(리뷰 #823): 127*'a' + '한'(3B)=130B>cap(128).
    var long: [130]u8 = undefined;
    for (long[0..127]) |*c| c.* = 'a';
    @memcpy(long[127..130], "한");
    s.enterEdit(&long);
    try std.testing.expectEqual(@as(usize, 127), s.editText().len); // 쪼개진 '한'은 통째로 드롭
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.editText())); // 유효 UTF-8
}

test "settings 좁은 창 → 렌더 안 함(겹침 회피), 편집 중 다른 곳 클릭 → 편집 종료 (리뷰 #823)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    const rows = [_]FieldRow{
        .{ .label = "Family", .kind = .{ .text = "JetBrains Mono" } },
        .{ .label = "Blink", .kind = .{ .toggle = true } },
    };
    var s = State{};
    s.show();

    // [1][3] 좁은 창: form_cols <= ctrl_cols면 computeLayout=null → view 무동작(위젯이 라벨 위로 겹쳐 그려지지 않게).
    const narrow = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 160, .backing_height_px = 600 } };
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, &test_sections, &rows, narrow, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 너무 좁아 안 그림

    // [11] 편집 bleed: text 행 편집 중 다른 행(toggle) 클릭 → 편집 종료(버퍼가 안 샘).
    s.setFieldCount(rows.len);
    s.selected = 0;
    s.enterEdit("editing...");
    try std.testing.expect(s.editing);
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;
    const c1 = fieldControlRect(l, 1); // 행1(toggle)
    _ = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 2), .y_px = @floatFromInt(c1.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expect(!s.editing); // 다른 행 클릭 → 편집 종료
}

test "settings color: 스와치+hex 렌더, 스와치 클릭→toggle(프리셋 순환), hex 클릭→인라인 편집 (CS-4-2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    const rows = [_]FieldRow{.{ .label = "BG", .kind = .{ .color = .{ .hex = "#ff0000", .rgb = .{ .r = 255, .g = 0, .b = 0 } } } }};
    var s = State{};
    s.show();
    s.setFieldCount(rows.len);

    // view: 스와치(literal RGB) + hex 텍스트.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var has_swatch = false;
    var has_hex = false;
    for (out.items) |op| {
        if (op == .swatch and op.swatch.rgb.r == 255) has_swatch = true;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "#ff0000")) has_hex = true;
    }
    try std.testing.expect(has_swatch and has_hex);

    // handlePointer: 스와치 영역 클릭 → .toggle(platform이 cycleColor).
    const l = computeLayout(no_sections, &rows, 0, test_props, &tk).?;
    const ctrl = fieldControlRect(l, 0);
    const sw_act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(ctrl.x + 2), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.toggle, sw_act);
    try std.testing.expect(!s.editing); // 스와치 클릭은 편집 아님

    // hex 영역 클릭 → 인라인 편집 시작(현재 hex 시드).
    const hx = color.hexX(ctrl, test_props.metrics.cell_width_px) + 4;
    const hex_act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(hx), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, hex_act);
    try std.testing.expect(s.editing);
    try std.testing.expectEqualStrings("#ff0000", s.editText());
}

test "settings palette_grid: 16 스와치 + 선택 셀 테두리·hex 렌더, ←→ 셀 이동(wrap), 스와치/hex 클릭 (CS-4-5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var cells: [16]FieldRow.PaletteGrid.Cell = undefined;
    for (&cells, 0..) |*c, i| c.* = .{ .rgb = .{ .r = @intCast(i * 16), .g = 0, .b = 0 }, .hex = "#000000" };
    cells[2].hex = "#abcdef"; // 선택 셀(2) hex 확인용
    const rows = [_]FieldRow{.{ .label = "ANSI", .kind = .{ .palette_grid = .{ .cells = cells, .selected = 2 } } }};
    var s = State{};
    s.show();
    s.setFieldCount(rows.len);

    // view: 16 스와치(색은 안 가림 — 선택 셀 위에 fill/border 안 얹음) + "2  #abcdef"(선택 인덱스 + hex) 텍스트.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var swatch_count: usize = 0;
    var has_sel_label = false;
    for (out.items) |op| {
        if (op == .swatch) swatch_count += 1;
        // 선택 셀(2)의 라벨 "2  #abcdef" — 인덱스 접두 + hex가 한 텍스트에.
        if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "2  #abcdef") != null) has_sel_label = true;
    }
    try std.testing.expectEqual(@as(usize, 16), swatch_count);
    try std.testing.expect(has_sel_label);
    // 스와치를 덮는 선택 accent border/fill이 없어야 한다(색 보존) — 모달 frame border(focus_accent)는 허용.
    for (out.items) |op| {
        if (op == .border) try std.testing.expect(op.border.role != .accent_bar);
    }

    // moveGridCell: ←→ wrap(0..15).
    s.grid_cell = 15;
    s.moveGridCell(1);
    try std.testing.expectEqual(@as(usize, 0), s.grid_cell); // 15→0 wrap
    s.moveGridCell(-1);
    try std.testing.expectEqual(@as(usize, 15), s.grid_cell); // 0→15 wrap

    // handlePointer: 스와치 5번 클릭 → grid_cell=5, .selection_changed(편집 아님 — select-then-act).
    const l = computeLayout(no_sections, &rows, 0, test_props, &tk).?;
    const grid = paletteGridRect(l, 0);
    const sw5 = paletteSwatchRect(grid, 5, test_props.metrics.cell_width_px, test_props.metrics.cell_height_px);
    const a1 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(sw5.x + 2), .y_px = @floatFromInt(sw5.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, a1);
    try std.testing.expectEqual(@as(usize, 5), s.grid_cell);
    try std.testing.expect(!s.editing);

    // hex 영역 클릭 → 선택 셀(5) 인라인 편집 시드(cells[5].hex="#000000").
    const hx = paletteHexX(grid, test_props.metrics.cell_width_px) + 4;
    const a2 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(hx), .y_px = @floatFromInt(grid.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, a2);
    try std.testing.expect(s.editing);
    try std.testing.expectEqualStrings("#000000", s.editText());
}

test "settings HSV picker hue 셀↔값 round-trip: 모든 col 가역(마커·키 stuck 회귀 방지) (code-review max #1)" {
    // hueColForHue는 hueForCol의 좌역원이어야 한다 — 아니면 odd column에서 '['/']' 키가 stuck되고 ▾ 마커가 어긋난다.
    var col: u32 = 0;
    while (col < pick_hue_cols) : (col += 1) {
        try std.testing.expectEqual(col, hueColForHue(hueForCol(col)));
    }
    // 옛 버그 회귀 가드: col 9(h=202)에서 ']'(전진)이 실제로 col 10으로 가야 한다(옛 floor는 9로 되돌아와 stuck).
    const c = hueColForHue(hueForCol(9));
    try std.testing.expectEqual(@as(u32, 9), c);
    try std.testing.expectEqual(@as(u32, 10), hueColForHue(hueForCol((c + 1) % pick_hue_cols)));
}

test "settings HSV picker: openPicker 시드·SV/hue 스와치 렌더·←→↑↓[] 조절·Enter=color_picked·Esc 취소·클릭 hit-test (CS-4-6)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    const rows = [_]FieldRow{.{ .label = "BG", .kind = .{ .color = .{ .hex = "#ff0000", .rgb = .{ .r = 255, .g = 0, .b = 0 } } } }};
    var s = State{};
    s.show();
    s.setFieldCount(rows.len);

    // openPicker: 순수 빨강 → s=100, v=100. pickerRgb 왕복 근사(rgb→hsv→rgb, ±3).
    s.openPicker(.{ .r = 255, .g = 0, .b = 0 });
    try std.testing.expect(s.picking);
    try std.testing.expectEqual(@as(u8, 100), s.pick_s);
    try std.testing.expectEqual(@as(u8, 100), s.pick_v);
    const rt = s.pickerRgb();
    try std.testing.expect(rt.r >= 252 and rt.g <= 3 and rt.b <= 3);

    // view(picking): SV 그리드(16×8) + hue(16) + 미리보기(1) 스와치 + 마커 ▾ 2개 + 도움말 텍스트.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var swatch_count: usize = 0;
    var marker_count: usize = 0;
    var has_help = false;
    for (out.items) |op| {
        if (op == .swatch) swatch_count += 1;
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "▾")) marker_count += 1;
        if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "채도") != null) has_help = true;
    }
    try std.testing.expectEqual(@as(usize, pick_sv_cols * pick_sv_rows + pick_hue_cols + 1), swatch_count);
    try std.testing.expectEqual(@as(usize, 2), marker_count); // SV 선택 + hue 선택
    try std.testing.expect(has_help);
    for (out.items) |op| if (op == .border) try std.testing.expect(op.border.role != .accent_bar); // 스와치 안 덮음(마커는 text)

    // handle: ← 채도 감소, → 복귀, ↓ 명도 감소, [ 색상 한 칸 뒤로(0→마지막 칸 wrap).
    const s_before = s.pick_s;
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .left }, &s));
    try std.testing.expect(s.pick_s < s_before);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .right }, &s));
    try std.testing.expectEqual(s_before, s.pick_s);
    const v_before = s.pick_v;
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expect(s.pick_v < v_before);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .char, .codepoint = '[' }, &s));
    try std.testing.expect(s.pick_h != 0); // 0 → 마지막 hue 칸

    // Enter → .color_picked(platform이 hex 커밋). picker는 platform이 닫는다(컴포넌트는 유지).
    try std.testing.expectEqual(Action.color_picked, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.picking);

    // Esc → picker 취소(closePicker) + selection_changed(모달은 유지).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.picking);

    // handlePointer: 다시 열고 SV 그리드 col 0·row 0 클릭 → s=0, v=100.
    s.openPicker(.{ .r = 255, .g = 0, .b = 0 });
    const box = pickerLayout(test_props, &tk).?;
    const sw_px: i32 = @intCast(pick_swatch_w * box.cw);
    const pa = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(box.inner_x + 1), .y_px = @floatFromInt(modal_box.rowY(box, 1) + 2) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, pa);
    try std.testing.expectEqual(@as(u8, 0), s.pick_s);
    try std.testing.expectEqual(@as(u8, 100), s.pick_v);

    // hue 스트립 col 8 클릭 → h = hueForCol(8).
    const ha = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(box.inner_x + 8 * sw_px + 1), .y_px = @floatFromInt(modal_box.rowY(box, pick_hue_row) + 2) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, ha);
    try std.testing.expectEqual(hueForCol(8), s.pick_h);

    // 박스 밖 클릭 → picker 취소(폼 복귀).
    const oa = handlePointer(.{ .phase = .down, .x_px = -10, .y_px = -10 }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, oa);
    try std.testing.expect(!s.picking);
}

test "settings 검색: '/'로 시작·char 쿼리·Backspace·↑↓ 나비·Enter 활성·Esc 종료 + 제목 렌더 (CS-4-4 검색)" {
    var s = State{};
    s.show();
    s.setFieldCount(5);

    // '/'로 검색 시작.
    try std.testing.expectEqual(Action.search_changed, handle(.{ .key = .char, .codepoint = '/' }, &s));
    try std.testing.expect(s.searching);
    try std.testing.expectEqualStrings("", s.searchQuery());

    // char가 쿼리로(필터 신호).
    try std.testing.expectEqual(Action.search_changed, handle(.{ .key = .char, .codepoint = 's' }, &s));
    try std.testing.expectEqual(Action.search_changed, handle(.{ .key = .char, .codepoint = 'p' }, &s));
    try std.testing.expectEqualStrings("sp", s.searchQuery());
    // Backspace.
    try std.testing.expectEqual(Action.search_changed, handle(.{ .key = .backspace }, &s));
    try std.testing.expectEqualStrings("s", s.searchQuery());
    // ↑↓는 필터된 행 나비(검색 유지).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expect(s.searching);
    // Enter는 선택 행 활성(toggle).
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    // Esc는 검색 종료(모달 close 아님) + 필터 해제.
    try std.testing.expectEqual(Action.search_changed, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.searching);
    try std.testing.expectEqualStrings("", s.searchQuery());
    try std.testing.expect(s.open); // 모달은 안 닫힘

    // view: 검색 중이면 제목이 "검색: <쿼리>"(accent).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk2 = testTokens();
    s.startSearch();
    s.appendSearchCp('f');
    s.appendSearchCp('o');
    const rows2 = [_]FieldRow{.{ .label = "Font size", .kind = .{ .toggle = true } }};
    var out2: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows2, test_props, &tk2, arena, &out2);
    var saw_search = false;
    for (out2.items) |op| if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "검색: fo") != null and op.text.role == .accent_bar) {
        saw_search = true;
    };
    try std.testing.expect(saw_search);
}

test "settings keybind: chord 표시·녹음 시 '키 입력 대기'·control 클릭→toggle(녹음 시작) (CS-4-3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    const rows = [_]FieldRow{.{ .label = "New Terminal", .kind = .{ .keybind = "⌘T" } }};
    var s = State{};
    s.show();
    s.setFieldCount(rows.len);

    // 비녹음: 현재 chord "⌘T" 표시.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var has_chord = false;
    for (out.items) |op| if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "⌘T")) {
        has_chord = true;
    };
    try std.testing.expect(has_chord);

    // 녹음 중(선택 행): "키 입력 대기..."를 accent로.
    out.clearRetainingCapacity();
    s.recording = true;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var has_prompt = false;
    for (out.items) |op| if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "키 입력 대기") != null and op.text.role == .accent_bar) {
        has_prompt = true;
    };
    try std.testing.expect(has_prompt);
    s.recording = false;

    // handlePointer: control 영역 클릭 → .toggle(platform이 recording 켬).
    const l = computeLayout(no_sections, &rows, 0, test_props, &tk).?;
    const ctrl = fieldControlRect(l, 0);
    const act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(ctrl.x + 2), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expectEqual(Action.toggle, act);

    // 녹음 중 다른 곳(라벨) 클릭 → 녹음 취소.
    s.recording = true;
    _ = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 1), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, test_props, &tk, &s);
    try std.testing.expect(!s.recording);
}

test "settings text view: 행 값 렌더, 편집 중이면 버퍼+caret(cursor fill)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{.{ .label = "Family", .kind = .{ .text = "JetBrains Mono" } }};

    // 비편집: 현재값 text op(surface_fg), caret 없음.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var has_value = false;
    var has_caret = false;
    for (out.items) |op| {
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "JetBrains Mono")) has_value = true;
        if (op == .fill and op.fill.role == .cursor) has_caret = true;
    }
    try std.testing.expect(has_value and !has_caret);

    // 편집 중: 버퍼 text(accent_bar) + caret(cursor fill).
    out.clearRetainingCapacity();
    s.enterEdit("Menlo");
    try view(&s, no_sections, &rows, test_props, &tk, arena, &out);
    var has_buf = false;
    has_caret = false;
    for (out.items) |op| {
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "Menlo")) has_buf = true;
        if (op == .fill and op.fill.role == .cursor) has_caret = true;
    }
    try std.testing.expect(has_buf and has_caret);
}
