//! Settings — schema-주도 세팅 모달(폼). config 스키마의 각 필드를 한 행(라벨 + 위젯)으로 그린다(CS-4-4).
//! palette/find처럼 ChromeHost가 소유하는 오버레이 모달이지만, 행 목록은 platform이 config 스키마에서 빌드해
//! 주입한다(컴포넌트는 config·스키마를 모름 — palette `Row` 선례, L1/L3 경계). 박스 기하는 modal_box 공유
//! 프리미티브, control 위젯은 toggle 등 leaf 컴포넌트를 재사용한다. State(open·selected) + view(rows→박스+행) +
//! handle(키 네비/토글/닫기) + handlePointer(행/위젯 hit-test). 단일 출처: docs/config-gui.md §2·§4.
//!
//! 위젯은 FieldRow.kind union으로 가른다 — bool(toggle)·number(입력 박스)·enum(dropdown)·text(인라인 편집)·color(스와치+hex)
//! ·palette_grid(ANSI 16색 한 줄 그리드). text/color는 고정 버퍼로 hex/문자열을 편집한다(Enter 커밋, Esc 취소 —
//! State.editing/edit_buf). palette_grid는 16칸이라 control 열을 안 쓰고 폼 우측에 스와치 줄을 펼친다(←→로 셀 선택,
//! Enter/hex 클릭으로 그 칸 편집 — State.grid_cell). 레이아웃은 좌측 Section 네비(섹션 목록, platform이 settings.section
//! 으로 필터해 폼 주입) + 우측 폼(선택 섹션 필드, 길면 스크롤 윈도잉) — config-gui §4·§6.5. 폼 검색은 후속.

const std = @import("std");
const icons = @import("../../icons.zig");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) — 라벨 폭 측정(modal_box와 같은 규약)
const width = @import("../../width.zig"); // UTF-8 경계 절단/백스페이스 단일 출처(truncateToBoundary·dropLastCodepoint)
const toggle = @import("toggle.zig");
const input_box = @import("input_box.zig"); // 숫자 입력 박스(슬라이더 대체 — 프로그레스바 대신 직접 타이핑)
const dropdown = @import("dropdown.zig");
const color_mod = @import("../../color.zig"); // HSV picker — hsvToRgb/rgbToHsv/Hsv
const color = @import("color.zig");

/// 최상위 모달 레이어(palette/notice와 동일).
pub const layer = modal_box.layer;

/// 한 설정 행(platform이 config 스키마에서 빌드해 주입). kind union으로 위젯 종류를 가른다 — bool(toggle, CS-4-1a)·
/// number(입력 박스, CS-4-1b)·enum(dropdown, CS-4-1c)·text(CS-4-1d)·color(CS-4-2)를 모두 지원한다. 값은 config가 소유(주입만).
pub const FieldRow = struct {
    label: []const u8, // 행 라벨(meta.doc 또는 키)
    kind: Kind,
    // platform이 주입하는 비활성 표식 — 회색(muted_fg)으로 그리고 입력은 platform이 차단/전환한다(예: 테마 프리셋이
    // 활성이면 색·팔레트 행을 잠근다). 값은 config 비소유 — 매 프레임 platform이 판정해 주입(palette 선례와 같은 규율).
    disabled: bool = false,
    // 이 행이 기본값과 같은가(§6.11) — platform이 theme.Config{} 대비로 판정해 주입(neutral: 컴포넌트는 config 무지).
    // false(=override됨)면 view가 폼 행 **맨 오른쪽**(값 오른쪽 reset_gutter, resetGlyphX)에 ↺(되돌리기) 어포던스를
    // 그리고, 그 셀 클릭/행 Backspace로 항목 리셋.
    is_default: bool = true,

    pub const Kind = union(enum) {
        toggle: bool, // 현재 on/off
        number: Number, // 현재 값 + 범위(f32/u32; value/min/max는 f64로 통일) — 입력 박스로 렌더(옛 slider 대체)
        dropdown: []const u8, // enum 현재 변형 표시 토큰(클릭/Enter로 열리는 드롭다운 팝업 — platform이 setEnumIndex)
        font: []const u8, // 폰트 패밀리 현재값 — enum이 아니라 번들 폰트 목록 드롭다운 팝업. 목록 끝 "직접 입력…"으로
        // 인라인 편집(목록 밖 시스템/직접입력 폰트 — text와 같은 편집 경로).
        text: []const u8, // 문자열 현재값. 클릭/Enter로 인라인 편집(platform이 schema.setText)
        color: Color, // 색 #RRGGBB — 스와치 + hex. 스와치/Enter로 HSV picker, hex 클릭으로 편집(platform)
        palette_grid: PaletteGrid, // ANSI 16색 그리드(theme.palette.0~15) — 스와치 줄 + 선택 셀 hex 편집(CS-4-5)
        keybind: []const u8, // 현재 단축키 표시(⌘T 또는 빈=미지정). Enter/클릭 → 녹음 모드(platform이 raw 키 캡처→rebind, CS-4-3)
    };
    pub const Number = struct { value: f64, min: f64, max: f64 };
    pub const Color = struct { hex: []const u8, rgb: @import("../../color.zig").Rgb }; // 현재 hex + platform이 파싱한 RGB(스와치)
    /// ANSI 16색 팔레트 그리드. cells[i]=효과색(platform이 config override 또는 xterm256 기본을 resolve), selected=선택 셀
    /// (=State.grid_cell 주입). 색은 ColorRole이 아니라 원색 — 스와치(Op.swatch)로 그린다(color 위젯과 같은 의도적 예외).
    pub const PaletteGrid = struct {
        cells: [16]Cell,
        selected: usize,
        pub const Cell = struct { rgb: @import("../../color.zig").Rgb, hex: []const u8 };
    };
};

/// 순수 상태 — 열림 + 포커스된 행 + color 피커 드래그 상태. 행 데이터(rows)는 State에 두지 않고 매 프레임 platform이
/// 주입한다(config 단일 출처 — palette 선례). 값도 config가 소유하므로 handle은 의도(toggle/dropdown/text_commit 등)만
/// 내고 실제 변경+write-back은 platform이 한다(숫자는 입력 박스 편집→text_commit, enum/폰트는 드롭다운 팝업).
/// 인라인 편집 버퍼 용량(바이트) — 폰트 패밀리·#RRGGBB는 짧아 고정 버퍼면 충분(별도 allocator 불요).
const edit_cap: usize = 128;
/// 검색 쿼리 버퍼 용량(바이트) — 짧은 키워드면 충분(고정 버퍼).
const search_cap: usize = 64;
/// 검색 IME 조합(preedit) 버퍼 용량(바이트) — 조합 중 한글 몇 자면 충분(고정 버퍼).
const search_preedit_cap: usize = 32;
/// 인라인 안내 배너 버퍼 용량(바이트) — keybind 녹음 검증 실패/충돌 메시지(§6.9). notice와 달리 세팅 모달을
/// 닫지 않고 폼 상단에 얹는다(단일-오버레이 불변식과 무관 — 세팅 자체 그리드 안 텍스트).
const message_cap: usize = 256;

// HSV 색 picker 기하 — SV 그리드(채도 col × 명도 row) + hue 스트립. 셀-그리드 tui라 이산 해상도(셀 단위 샘플).
const pick_sv_cols: u32 = 16; // 채도 0~100
const pick_sv_rows: u32 = 8; // 명도 100~0(위→아래)
const pick_swatch_w: u32 = 2; // 셀당 2칸(가시성)
const pick_hue_cols: u32 = 16; // hue 0~360
const pick_help = "←→ 채도  ↑↓ 명도  [ ] 색상  ⇧ 미세  # hex  i 스포이드  Enter 확정  Esc 취소";
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
    /// 좌측 네비 맨 아래 "↺ 모든 설정 초기화" 액션 행의 인덱스(§6.4·§6.11). platform이 매 프레임 주입(=실제 섹션 수;
    /// 없으면 null). 이 행은 섹션이 아니라 액션이라, 네비 포커스 Enter/클릭이 이 인덱스면 handle이 폼 진입 대신 .reset_all을
    /// 낸다. section이 이 값까지 내려갈 수 있게 platform이 clamp 상한을 리셋 행까지 허용한다.
    nav_reset_row: ?usize = null,
    /// color 피커 SV 그리드 드래그 진행 중(down이 그리드에서 시작해 up까지). move를 그 행에 캡처한다(divider 드래그 패턴).
    dragging: bool = false,
    /// text 행 인라인 편집 중. 켜지면 키가 편집 버퍼로 라우팅된다(Enter=커밋, Esc=취소). platform이 enterEdit로 켜고
    /// (현재값 시드) .text_commit에서 editText()를 읽어 config arena에 dupe→setText. 별도 allocator 없이 고정 버퍼.
    editing: bool = false,
    edit_buf: [edit_cap]u8 = undefined,
    edit_len: usize = 0,
    /// palette_grid 행에서 선택된 셀(0~15). ←→가 이 값을 옮기고(platform이 moveGridCell), Enter/hex 클릭이 이 셀을
    /// 편집한다. 행 1개에 16칸이라 폼의 1D selected와 별도로 둔다(color 피커 드래그 상태가 별도인 것과 동형).
    grid_cell: usize = 0,
    /// keybind 행 녹음 중(Enter/클릭으로 켜짐) — 다음 raw 키를 platform이 가로채 chord로 캡처한다(컴포넌트 handle을
    /// 안 거침). 켜지면 그 행이 "키 입력 대기..."로 보인다. platform이 캡처/취소 후 끈다(text editing과 별개 상태).
    recording: bool = false,
    /// 현재 섹션 폼 검색 중(`/`로 시작, Esc로 종료). 켜지면 char가 검색 버퍼로 가고, platform이 searchQuery()로 행을
    /// 필터한다(라벨 부분일치). ↑↓ 나비·Enter 활성은 그대로(필터된 행 위에서). 고정 버퍼라 별도 allocator 불요.
    searching: bool = false,
    search_buf: [search_cap]u8 = undefined,
    search_len: usize = 0,
    /// 검색어의 IME 조합(marked) 텍스트 — macOS는 평범한 글자 입력을 NSTextInputClient(IME)로 처리하므로, 조합 중
    /// 한글이 이 버퍼에 담겨 검색 입력줄에서 query 뒤에 보인다(find/palette의 OverlayInput.preedit와 같은 모델이되
    /// 고정 버퍼). platform이 imeSetPreedit로 채우고 commit/취소 시 비운다. query와 독립(확정 글자는 search_buf).
    search_preedit_buf: [search_preedit_cap]u8 = undefined,
    search_preedit_len: usize = 0,
    /// 폼 상단 인라인 안내 배너(§6.9) — keybind 녹음 검증 실패("등록 불가 키")·충돌 경고를 세팅 모달을 닫지 않고
    /// 보인다(notice 토스트는 dismissMessageOverlays로 세팅을 닫으므로 녹음 중 부적절). platform이 setMessage로 채우고
    /// 녹음 재시작·섹션 전환·닫기에서 비운다. 비면(len 0) 배너 없음(기존 힌트 줄 유지).
    message_buf: [message_cap]u8 = undefined,
    message_len: usize = 0,
    /// HSV 색 picker 모드(color 행 활성 시 platform이 openPicker로 켬). 켜지면 폼 대신 SV 그리드 + hue 스트립을 그리고
    /// ←→(채도)·↑↓(명도)·`[`/`]`(색상)·포인터로 h/s/v를 고른다. Enter 확정(platform이 hex→setText), Esc 취소. h 0~359·s/v 0~100.
    picking: bool = false,
    pick_h: u16 = 0,
    pick_s: u8 = 0,
    pick_v: u8 = 0,
    /// enum/font 행의 열리는 드롭다운 팝업 상태(모달 오버레이). platform이 행 활성 시 변형 목록·현재 인덱스로 열고
    /// (openDropdown), 열려 있으면 handle이 키를 dropdown.handle로 라우팅한다(↑↓ 선택·Enter 확정·Esc 취소). 팝업이
    /// 열린 동안엔 폼 키(행 이동·영역 전환)를 잡지 않는다. 값 적용(변형 set)은 platform이 selected로 한다.
    dropdown: dropdown.State = .{},
    /// 키보드 포커스가 좌측 섹션 네비에 있는가. **방향키 영역 모델**: `←`=네비로 포커스, `→`=폼으로 포커스, 각 영역
    /// 안에서 `↑↓`가 이동한다(네비=섹션, 폼=행). Tab 토글이 아니라 방향으로 이동(직관적 — 왼쪽 열=네비, 오른쪽=폼).
    /// show에서 폼으로 시작(false). 팔레트 그리드 행에서의 `←→` 셀 이동은 platform이 pre-intercept(그 행만 특수).
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
        self.search_preedit_len = 0;
        self.message_len = 0;
        self.picking = false;
        self.dropdown.hide(); // 모달 열 때 드롭다운 팝업 닫힘 상태로 시작
        self.nav_focused = false; // 폼 포커스로 시작(← 눌러 섹션 네비로 이동)
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
        self.editing = false; // picker 내 hex 인라인 편집 중이었으면 같이 닫는다(편집 상태가 폼으로 새지 않게)
    }
    /// 현재 선택 h/s/v의 RGB(미리보기·확정 hex 산출). platform이 확정 시 #rrggbb로 직렬화.
    pub fn pickerRgb(self: *const State) color_mod.Rgb {
        return color_mod.hsvToRgb(.{ .h = self.pick_h, .s = self.pick_s, .v = self.pick_v });
    }
    /// 외부에서 고른 RGB(스포이드 NSColorSampler 결과·hex 등)를 picker 선택값으로 반영한다 — picking 중일 때만. platform이
    /// provide_sampled_color에서 호출. editing(hex 인라인) 중이면 무시(편집 버퍼 우선). RGB→HSV는 양자화 근사.
    pub fn setPickerRgb(self: *State, rgb: color_mod.Rgb) void {
        if (!self.picking or self.editing) return;
        const hsv = color_mod.rgbToHsv(rgb);
        self.pick_h = hsv.h;
        self.pick_s = hsv.s;
        self.pick_v = hsv.v;
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
        self.search_preedit_len = 0;
        self.message_len = 0; // 섹션 전환 = 새 맥락 → 안내 배너 정리
        self.picking = false;
        self.dropdown.hide();
    }
    /// 검색 쿼리(현재 버퍼). platform이 currentSectionFields에서 읽어 행을 필터한다.
    pub fn searchQuery(self: *const State) []const u8 {
        return self.search_buf[0..self.search_len];
    }
    /// 검색 시작(`/`) — 빈 쿼리로 모드 진입. 켜는 동안 selected는 보존(필터 후 platform이 clamp).
    pub fn startSearch(self: *State) void {
        self.searching = true;
        self.search_len = 0;
        self.search_preedit_len = 0;
    }
    /// 검색 종료(Esc) — 쿼리·조합 비우고 모드 해제(필터 풀려 전체 행 복귀).
    pub fn endSearch(self: *State) void {
        self.searching = false;
        self.search_len = 0;
        self.search_preedit_len = 0;
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
        self.search_len = width.dropLastCodepoint(&self.search_buf, self.search_len);
    }
    /// 검색어 IME 조합(marked) 텍스트를 교체한다(빈 bytes = 조합 해제). **검색 중일 때만** 검색 버퍼에 담는다 —
    /// 세팅 모달은 검색 안 할 때도 IME 대상(inputFocus=.settings)이라, 유휴/인라인 편집 중 조합이 그대로 흘러오면
    /// 검색 버퍼를 오염시킨다(안 보이는 검색어로 폼이 필터되거나, 편집 조합이 엉뚱한 버퍼로 확정됨 — code-review high).
    /// 검색이 아니면 무시하고 비운다(편집 조합은 확정 텍스트가 handle(.char)→appendEditCp로 이미 편집 버퍼에 들어간다).
    /// 넘치면 **UTF-8 코드포인트 경계**로 자른다(setMessage와 같은 규율 — raw 바이트 자름은 멀티바이트 조합을 깨 손상 UTF-8을 남긴다).
    pub fn setSearchPreedit(self: *State, bytes: []const u8) void {
        if (!self.searching) {
            self.search_preedit_len = 0;
            return;
        }
        const n = width.truncateToBoundary(bytes, search_preedit_cap);
        @memcpy(self.search_preedit_buf[0..n], bytes[0..n]);
        self.search_preedit_len = n;
    }
    /// 검색어 조합(현재 버퍼). 검색 입력줄이 query 뒤에 보인다(view). platform imeComposingActive가 len으로 조합 판정.
    pub fn searchPreedit(self: *const State) []const u8 {
        return self.search_preedit_buf[0..self.search_preedit_len];
    }
    /// 조합 중 텍스트를 검색어로 확정한다(query 뒤에 코드포인트별로 붙이고 조합 비움) — 포커스 상실 등에서 조합을
    /// 잃지 않게(OverlayInput.commitPreedit의 고정 버퍼판). 확정한 게 있으면 true(platform이 재필터). 빈 조합이면 false.
    pub fn commitSearchPreedit(self: *State) bool {
        if (self.search_preedit_len == 0) return false;
        const utf8 = std.unicode.Utf8View.init(self.search_preedit_buf[0..self.search_preedit_len]) catch {
            self.search_preedit_len = 0; // 손상 UTF-8은 버린다(반쪽 안 남김)
            return false;
        };
        var it = utf8.iterator();
        while (it.nextCodepoint()) |cp| self.appendSearchCp(cp);
        self.search_preedit_len = 0;
        return true;
    }
    /// 폼 상단 안내 배너 메시지를 세운다(§6.9). bytes는 호출자(platform)가 소유 — 고정 버퍼로 복사한다. 넘치면 잘라
    /// 담되 UTF-8 코드포인트 경계로 back-up해 손상 바이트를 안 남긴다(enterEdit와 같은 규율).
    pub fn setMessage(self: *State, bytes: []const u8) void {
        const n = width.truncateToBoundary(bytes, message_cap);
        @memcpy(self.message_buf[0..n], bytes[0..n]);
        self.message_len = n;
    }
    /// 안내 배너 메시지(현재 버퍼). 비면 "" — view가 배너 대신 기존 힌트 줄을 그린다.
    pub fn message(self: *const State) []const u8 {
        return self.message_buf[0..self.message_len];
    }
    /// 안내 배너를 지운다(녹음 재시작·성공 등 새 맥락). platform이 부른다.
    pub fn clearMessage(self: *State) void {
        self.message_len = 0;
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
        const n = width.truncateToBoundary(value, edit_cap); // 버퍼 초과는 UTF-8 경계로 자름(단일 출처 — #823)
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
        self.edit_len = width.dropLastCodepoint(&self.edit_buf, self.edit_len);
    }
    pub fn hide(self: *State) void {
        self.open = false;
        self.dragging = false;
        self.editing = false;
        self.recording = false;
        self.searching = false;
        self.search_len = 0;
        self.search_preedit_len = 0;
        self.message_len = 0;
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
///   toggle=행 활성(bool flip·number 편집 진입·enum/font 드롭다운 팝업 열기·text 편집·color picker·keybind 녹음),
///   dropdown_accept=열린 팝업에서 Enter — platform이 state.dropdown.selected 변형을 set + 팝업 닫기,
///   section_changed=←→ 섹션 전환, selection_changed=재렌더, close=hide, consumed=소비만(모달 뒤로 안 샘).
///   reset_field=선택 폼 행을 기본값으로 되돌림(↺ 클릭·Backspace — §6.11, platform이 rows[selected].kind로 분기),
///   reset_all=네비 "↺ 모든 설정 초기화" 활성(§6.4 — platform이 requestResetAll 확인 모달).
///   값 종류 판정은 platform이 rows[selected].kind로 한다. (slider_set/adjust_left/right는 슬라이더 제거로 더는
///   방출하지 않는 deprecated 잔재 — 슬라이더→입력 박스 전환. 정리 예정, 지금은 dispatch exhaustiveness 유지용.)
pub const Action = enum { close, toggle, dropdown_accept, dropdown_preview, dropdown_cancel, slider_set, adjust_left, adjust_right, selection_changed, section_changed, text_commit, search_changed, delete_row, reset_field, reset_all, color_picked, eyedropper, consumed };

const label_gap_cols: u32 = 2; // 라벨과 우측 위젯 사이 최소 간격(칸)
// 항목별 리셋(↺) 아이콘 렌더 폭(칸) — placeText가 등록 icon_glyph를 2칸(~16px)으로 그려 폰트 글리프(~8px)보다 크고
// 또렷하게(사용자 요청 "너무 작다"). resetGlyphX 배치·hit-test 밴드가 이 폭을 공유한다.
const reset_icon_cols: u32 = 2;
// 항목별 리셋(↺) 어포던스가 차지하는 폼 우측 여백(칸) — 값(control) **오른쪽**에 ↺ 전용 열을 둬, 변경된 행마다
// 항상 같은 자리(폼 행 맨 오른쪽)에 뜨게 한다(사용자 요청 — 예전엔 값 왼쪽 label_gap에 얹혀 작고 눈에 안 띔).
// = 아이콘 2칸 + 값과의 간격 1칸. control/palette 열은 이 폭만큼 좌측으로 물러나 값과 안 겹친다. 박스 폭(form_content)에
// 이 여백을 더해 값·라벨 가용 폭은 그대로 유지한다(모달만 3칸 넓어짐).
const reset_gutter_cols: u32 = reset_icon_cols + 1;

/// control 열 폭(칸) — 모든 행이 같은 우측 열을 공유한다(숫자 입력 박스 폭 기준). 픽셀 폭을 cw로 ceil. view/hitTest
/// 단일 출처. toggle은 이 열 안에서 좌측정렬(입력 박스·dropdown과 같은 시작 x). text/dropdown 값(폰트 패밀리·테마
/// 프리셋명 등)이 입력 박스 폭보다 길 수 있어 settings_value_cols로 하한을 둬 값이 박스 안에서 충분히 보이게 한다
/// (그래도 넘치는 값은 view에서 truncate). 열이 곧 박스 우측 경계라(fieldControlRect 우측정렬) 값이 박스를 안 넘는다.
fn controlCols(ch: u32, cw: u32) u32 {
    return @max((input_box.width(ch) + cw - 1) / @max(cw, 1), settings_value_cols);
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
// 잘리지 않고 담는 하한. 입력 박스 폭이 이보다 넓으면 그쪽을 쓴다(controlCols).
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

const title_rows: u32 = 2; // 제목(0) + 힌트 줄(1 — "⇥ 섹션 ⇄ 설정", 제목 바로 아래 상단)

/// 한 화면에 보일 최대 필드 행 수 — 뷰포트 높이에서 제목·여백·여유를 뺀다. 행이 이보다 많으면 창을 스크롤한다
/// (패널이 화면을 넘치지 않게). palette.max_visible과 같은 윈도잉 취지(여긴 뷰포트 적응형).
fn maxVisible(p: props.ChromeProps) usize {
    const ch = @max(p.metrics.cell_height_px, 1);
    const avail = props.workspaceRect(p.metrics).h / ch; // dock까지 포함한 전체 작업영역에 들어가는 총 행
    return @max(@as(usize, 4), @as(usize, avail) -| 7); // 제목 2 + 위아래 여백 2 + 여유 3
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
        form_label_reserve + label_gap_cols + ctrl_cols + reset_gutter_cols, // 스칼라 행: 라벨 예약 + control 열 + ↺ 여백
        palette_label_reserve + label_gap_cols + paletteGridCols() + reset_gutter_cols, // palette 행: 16 스와치 + hex 블록 + ↺ 여백
    );
    const title_need = overlay_input.displayCols(title_text) + 12; // 제목 + 스크롤 위치 표식 여유
    const content_cols = @max(nav_cols + nav_gap_cols + form_content, title_need);
    const mv = maxVisible(p);
    const win_start = overlay_input.windowStart(rows.len, mv, @min(selected, rows.len -| 1), 0); // 공유 윈도잉(prev=0 재파생)
    const win_len = @min(rows.len, mv);
    // 박스 높이는 **항상 가용 최대(FullHeight)** — win_len(보이는 행 수) 대신 mv(maxVisible)로 고정해, 행이 적은
    // 섹션에서도 모달이 작아졌다 커졌다 하지 않고 화면 높이에 꽉 차게 한다(너비는 content_cols로 별도 고정 — #860).
    // 네비(섹션 수)가 mv보다 많을 일은 거의 없지만 안전하게 큰 쪽을 쓴다. win_len은 폼 스크롤 윈도로 그대로 유지.
    const body_rows = @max(sections.len, mv);
    const content_rows = title_rows + @as(u32, @intCast(body_rows)); // 힌트는 title_rows 영역(제목 아래 줄)에 둬 별도 행 불필요
    const box = modal_box.layout(content_cols, content_rows, p, tk) orelse return null;
    const form_x = box.inner_x + @as(i32, @intCast((nav_cols + nav_gap_cols) * box.cw));
    // 스크롤바 gutter를 폼 폭에서 **한 번** 뗀다(SV5c). 여기가 폼 폭의 단일 출처라, control·↺ 위치를
    // 내는 헬퍼(`fieldControlRect`·`resetIconX`)가 자동으로 따라온다 — 팔레트에서는 요소마다 손으로
    // 빼야 해서 두 번 빠뜨렸는데(단축키·선택 밴드), 세팅은 `reset_gutter_cols`로 같은 패턴을 이미
    // 갖고 있어 그 자리에 하나 더 얹으면 된다.
    const scroll_gutter_cols: u32 = if (cw > 0) (p.metrics.overlay_scroll_gutter_px + cw - 1) / cw else 0;
    const form_cols = box.inner_cols -| (nav_cols + nav_gap_cols) -| scroll_gutter_cols;
    // 창이 너무 좁아 modal_box가 박스를 nav+gap+content보다 좁게 clamp하면 form_cols가 우측 블록보다 작아져
    // fieldControlRect·paletteGridRect의 (form_cols -| 우측블록 -| gutter)가 0으로 saturate → 위젯/그리드가 라벨 위로
    // 겹쳐 그려지거나(리뷰 #823), 라벨 truncate 폭이 0이 돼 라벨이 통째 사라졌다(리뷰). 그 경우 레이아웃 불가로 보고
    // null(view/handlePointer가 그리지 않음 — 창을 넓히면 보임). modal_box가 폭 부족 시 그리는 것과 같은 "안 되면 안 그림".
    // 우측 블록은 **이 섹션의 최대**(palette_grid 행이 있으면 그 그리드, 아니면 control 열) + ↺ 여백 + 라벨 간격을
    // 확보해야 라벨이 최소 1칸이라도 남고 그리드가 라벨을 안 덮는다(ctrl_cols만 보면 palette 섹션에서 그리드가 삐짐).
    var max_right_cols: u32 = ctrl_cols;
    for (rows) |r| {
        if (std.meta.activeTag(r.kind) == .palette_grid) {
            max_right_cols = @max(max_right_cols, paletteGridCols());
            break;
        }
    }
    if (form_cols <= max_right_cols + reset_gutter_cols + label_gap_cols) return null;
    return .{ .box = box, .ctrl_cols = ctrl_cols, .first_field_row = title_rows, .win_start = win_start, .win_len = win_len, .nav_cols = nav_cols, .form_x = form_x, .form_cols = form_cols, .body_rows = @intCast(body_rows) };
}

/// 보이는 폼 행 vi(0..win_len)의 control 열 rect(폼 영역 우측, ctrl_cols 폭, 행 높이). toggle은 좌측정렬, number는
/// 입력 박스(input_box)가 이 열을 채운다.
fn fieldControlRect(l: Layout, vi: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(vi));
    // control 열은 폼 우측에 정렬하되, 맨 오른쪽 reset_gutter_cols칸은 ↺ 어포던스 몫으로 비워 그 왼쪽에 붙인다.
    const ctrl_x = l.form_x + @as(i32, @intCast((l.form_cols -| l.ctrl_cols -| reset_gutter_cols) * box.cw));
    return .{ .x = ctrl_x, .y = modal_box.rowY(box, row), .w = l.ctrl_cols * box.cw, .h = box.ch };
}

/// 항목별 리셋 ↺를 그릴(그리고 hit-test할) 셀의 좌단 x — 폼 영역 **맨 오른쪽 칸**(control/palette 값 오른쪽,
/// reset_gutter 안, reset_icon_cols(2칸) 폭). view의 렌더와 handlePointer의 히트 밴드가 이 단일 출처를 공유해
/// 정렬이 어긋나지 않는다. 2칸 아이콘이라 우단에서 reset_icon_cols만큼 안쪽에 두어 박스 밖으로 안 넘는다.
fn resetGlyphX(l: Layout) i32 {
    return l.form_x + @as(i32, @intCast((l.form_cols -| reset_icon_cols) * l.box.cw));
}

/// 숫자 현재 값을 입력 박스에 표시할 문자열로 포맷한다. 소수 2자리로 굽고 뒤따르는 0(과 점)을 떼
/// 정수·딱떨어지는 소수를 깔끔히 보인다(14.00→"14", 2.28→"2.28", 1.50→"1.5", -8.00→"-8"). u32 필드도 정수로 나온다
/// (값이 whole이라 "200.00"→"200"). 별도 is_int 없이 한 경로로 처리한다. pub — platform이 숫자 입력 박스 편집
/// 진입 시 현재값 시드(enterEdit)에 같은 포맷을 써 표시값=편집시드가 되게 한다(입력 박스와 일관).
pub fn formatNumberValue(arena: std.mem.Allocator, value: f64) ![]const u8 {
    const s = try std.fmt.allocPrint(arena, "{d:.2}", .{value});
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// palette_grid 행의 그리드 블록 rect(폼 우측, paletteGridCols 폭 — control 열과 무관, 우측정렬). 16 스와치 + hex.
fn paletteGridRect(l: Layout, vi: usize) draw.Rect {
    const box = l.box;
    const row = l.first_field_row + @as(u32, @intCast(vi));
    const cols = paletteGridCols();
    // control 열과 마찬가지로 맨 오른쪽 reset_gutter_cols칸은 ↺ 몫으로 비워 그리드를 그 왼쪽에 정렬한다.
    const gx = l.form_x + @as(i32, @intCast((l.form_cols -| cols -| reset_gutter_cols) * box.cw));
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

/// control 열 안의 toggle rect — **좌측정렬**(ctrl 좌단). 입력 박스(전체)·dropdown(좌단 text)과 같은 시작 x라
/// 세 위젯의 control 열 left edge가 일관된다(text 위젯 전환 후 정렬 통일). hit-test/view 공유. 폭은 그려지는 위젯
/// 전체 — tui 트랙 `[  ]`(4*cw)이 pill(width(ch))보다 넓을 수 있어 둘 중 큰 쪽(클릭=보이는 위젯, 리뷰 #823).
fn toggleRectIn(ctrl: draw.Rect, ch: u32, cw: u32) draw.Rect {
    return .{ .x = ctrl.x, .y = ctrl.y, .w = @max(toggle.width(ch), 4 * cw), .h = ch };
}

const title_text = "Settings";
/// 되돌리기(기본값 리셋) 어포던스 글리프(§6.11 폼 행·§6.4 네비 "초기화" 라벨의 단일 출처). **빌드타임 SVG→coverage
/// 합성 아이콘**(`assets/icons/reset.svg`, Plane-15 PUA `0xF000B`) — `renderer.synthesizeGlyph`/`icon_glyph`가 셀을
/// **꽉 채워** 그리므로(chrome ⚙🔔 등과 같은 경로) 폰트 ↺(U+21BA, 번들 폰트 미커버 → 작은 시스템 폴백)보다 크고
/// 또렷하며 테마색이 자동 적용된다(사용자 요청 "너무 작다"). 미등록 PUA면 폰트 폴백이라 tofu는 안 난다. 아이콘 교체는
/// reset.svg를 고치고 `tools/svg_to_coverage.py`를 재실행하면 된다([[icon-svg-coverage-status]]).
/// **codepoint(u21)**: platform `placeText`가 chrome 오버레이 텍스트에서 **이 cp만** width-2(~16px)로 넓힌다 —
/// 등록 아이콘 전체(git_branch 등 Nerd Fonts MDI 겹침 범위)를 넓히면 사용자 config 값에 그런 PUA가 들어올 때
/// displayCols(=1칸)와 어긋나 caret/truncate가 오정렬되므로, 리셋 어포던스 cp 하나로 한정한다(리뷰).
pub const reset_glyph_cp: u21 = icons.codepoint(.reset);
pub const reset_glyph = icons.utf8(.reset); // reset_glyph_cp의 UTF-8(폼 행 ↺·네비 "초기화" 라벨 공용)
comptime {
    // reset_glyph 문자열이 reset_glyph_cp와 같은 코드포인트인지 못박는다(어긋나면 placeText가 안 넓힘).
    std.debug.assert((std.unicode.utf8Decode(reset_glyph) catch 0) == reset_glyph_cp);
}
/// 검색 입력줄 프롬프트 접두 — view의 제목 렌더와 searchCaretRect(IME 후보창 위치)가 같은 폭을 쓰게 하는 단일 출처.
const search_prompt = "검색: ";

/// 인라인 편집 중인 행의 편집 버퍼 텍스트(accent 강조) + 끝 셀 caret을 그린다 — `.font`/`.text` 편집 경로가 공유한다
/// (중복 제거, code-review). control 좌단(ctrl.x) 좌측정렬, caret은 표시폭 끝 셀에 cursor fill 1칸(palette 입력 caret 패턴).
fn drawInlineEdit(box: modal_box.Box, ctrl: draw.Rect, shown: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    if (shown.len > 0) {
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = shown };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = ctrl.x, .y = ctrl.y }, .runs = runs, .role = .accent_bar } });
    }
    const caret_x = ctrl.x + @as(i32, @intCast(overlay_input.displayCols(shown) * box.cw));
    try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = ctrl.y, .w = box.cw, .h = box.ch }, .role = .cursor } });
}

/// 모달 박스 + 제목 + 좌측 Section 네비(선택 강조) + 우측 폼(선택 섹션 필드 행 — 선택 하이라이트 → 라벨 → 위젯)을
/// 그린다(config-gui §4). 빈 rows여도 박스는 띄운다. 순수: state·sections·rows·props·tokens만 읽는다. out/op은 호출자
/// (platform) frame arena 소유. sections=네비 라벨, rows=선택 섹션의 필드(platform이 settings.section으로 필터해 주입).
/// dropdown_items=드롭다운 팝업이 열렸을 때 그 변형 라벨(platform 주입; 닫혔으면 빈 슬라이스 — 폼 위 오버레이로 그림).
pub fn view(
    state: *const State,
    sections: []const []const u8,
    rows: []const FieldRow,
    dropdown_items: []const []const u8,
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
    // 제목 — 검색 중이면 "검색: <쿼리><조합중>▏"(accent + caret), 아니면 "Settings" + 폼이 창보다 많으면 sel/total 위치 표식.
    if (state.searching) {
        // 확정 쿼리("검색: " + query)와 IME 조합(preedit)을 나눠 그린다 — 조합 글자는 query 뒤에 같은 accent로 붙여
        // 입력 가시성을 준다(find의 3-run 모델과 동형). caret은 query 끝(=조합 시작)에 둬 조합 글자 위에 겹친다(preedit는
        // caret 위치에 안 더함 — 단일 줄 append라 뒤 텍스트가 없어 터미널 grid의 삽입/오버레이 구분과 무관, find와 동일).
        // macOS는 평범한 글자 입력을 IME로 처리하므로 이 조합 표시가 필요하다.
        const committed = try std.fmt.allocPrint(arena, "{s}{s}", .{ search_prompt, state.searchQuery() });
        try modal_box.text(box, box.inner_x, 0, committed, .accent_bar, arena, out);
        const committed_cols = overlay_input.displayCols(committed);
        const caret_x = box.inner_x + @as(i32, @intCast(committed_cols * box.cw));
        const preedit = state.searchPreedit();
        // 조합 글자는 남은 칸으로 truncate — 좁은 모달에서 긴 조합이 박스 우단을 넘지 않게(다른 폼 값 truncate와 같은 규율).
        if (preedit.len > 0) {
            const shown_pre = try overlay_input.truncateToCols(arena, preedit, box.inner_cols -| committed_cols);
            if (shown_pre.len > 0) try modal_box.text(box, caret_x, 0, shown_pre, .accent_bar, arena, out);
        }
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = caret_x, .y = modal_box.rowY(box, 0), .w = box.cw, .h = box.ch }, .role = .cursor } });
    } else {
        const title = if (rows.len > l.win_len)
            try std.fmt.allocPrint(arena, "{s}   {d}/{d}", .{ title_text, @min(state.selected + 1, rows.len), rows.len })
        else
            title_text;
        try modal_box.text(box, box.inner_x, 0, title, .surface_fg, arena, out);
        // 검색 진입점 힌트 — 제목 행 우측에 muted로 `/ 검색`을 두어 클릭(또는 `/`)으로 검색됨을 알린다.
        // handlePointer가 제목 행(row 0) 클릭을 startSearch로 받는다(키 `/`와 같은 경로). config-gui §6.8.
        const search_hint = "/ 검색";
        const hint_cols = overlay_input.displayCols(search_hint);
        if (box.inner_cols > hint_cols) { // 좁아 제목과 겹칠 땐 생략(제목 우선)
            const hint_x = box.inner_x + @as(i32, @intCast((box.inner_cols - hint_cols) * box.cw));
            try modal_box.text(box, hint_x, 0, search_hint, .muted_fg, arena, out);
        }
    }

    // 좌측 네비: 섹션 라벨. inner_x 칸은 좌단 여백으로 비우고, 현재 섹션 강조(tab_active_bg)·라벨은 그 우측
    // (inner_x+cw)부터 둔다. 현재 섹션=accent. **네비 포커스면** 나머지 섹션도 surface_fg(선명 — 지금 ↑↓가 여기),
    // **폼 포커스면** 나머지는 muted_fg(흐림 — 지금 키가 폼에)로 어느 영역이 활성인지 보인다(방향키 영역 모델).
    const cw_i: i32 = @intCast(box.cw);
    for (sections, 0..) |label, i| {
        const row = l.first_field_row + @as(u32, @intCast(i));
        // 맨 아래 "↺ 초기화" 액션 행(§6.4)은 섹션이 아니라 액션이라 항상 muted(선택 시만 accent)로 섹션 목록과 구별한다.
        const is_reset = if (state.nav_reset_row) |ri| i == ri else false;
        if (i == state.section) {
            try modal_box.fillCells(box, box.inner_x + cw_i, row, l.nav_cols -| 1, .tab_active_bg, arena, out);
        }
        const role: tokens.ColorRole = if (i == state.section)
            .accent_bar
        else if (is_reset or !state.nav_focused)
            .muted_fg // 리셋 행은 포커스와 무관하게 muted, 섹션은 폼 포커스일 때만 muted
        else
            .surface_fg;
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
        // 선택 행 하이라이트. rich 테마에서 **GPU quad 위젯(입력 박스/toggle)** 만 모달 셀(이 하이라이트가 사는 곳)보다 아래
        // 레이어(layer 3 quad)라, 행 전체를 칠하면 하이라이트 셀이 그 위젯을 덮어 가린다 → 그 행만 **control 칸을 비워**
        // (라벨 영역만 칠해) 위젯이 빈 surface 셀로 비쳐 보이게 한다. color·palette의 swatch는 `Op.swatch`→`paintRectBg`로
        // **셀 bg 레이어**에 이 하이라이트 뒤에 그려져(painter order) 덮이지 않고, dropdown/text/keybind 값도 text 셀이라
        // 안 가려지므로 — 이들은 행 전체를 칠한다(불필요한 하이라이트 손실 방지).
        if (actual == state.selected) {
            const quad_widget = switch (r.kind) {
                .toggle, .number => true,
                else => false,
            };
            // quad 위젯 행은 위젯 좌단(= 폼폭 - control - ↺여백)까지만 칠해 위젯을 덮지 않는다. 비-quad 행은 ↺ 여백
            // 까지 포함해 행 전체(form_cols)를 칠하므로 맨 오른쪽 ↺도 선택 하이라이트 위에 놓인다.
            const hl_cols = if (quad_widget) l.form_cols -| row_right_cols -| reset_gutter_cols else l.form_cols;
            try modal_box.fillCells(box, l.form_x, content_row, hl_cols, .tab_hover_bg, arena, out);
        }
        // 비활성 행(프리셋 잠금)이거나 **네비 포커스**(폼이 비활성 영역)면 라벨을 muted로 — 지금 키가 폼에 없음을 흐림으로 보인다.
        const label_role: tokens.ColorRole = if (r.disabled or state.nav_focused) .muted_fg else .surface_fg;
        // 라벨도 control/palette 열과 ↺ 여백을 침범하지 않게 폼 라벨 영역 폭으로 truncate(고정 폭 안에 가둠 — rich quad 밖 삐짐 방지).
        const label_shown = overlay_input.truncateToCols(arena, r.label, l.form_cols -| row_right_cols -| reset_gutter_cols -| label_gap_cols) catch r.label;
        try modal_box.text(box, l.form_x, content_row, label_shown, label_role, arena, out);
        const ctrl = fieldControlRect(l, vi);
        // 항목별 리셋 어포던스(§6.11): 기본값과 다른(override된) 행은 폼 행 **맨 오른쪽 칸**(값 오른쪽 reset_gutter 안)에
        // ↺를 얹는다 — 변경된 행마다 같은 자리에 뜨게 해 발견성을 높인다(예전엔 값 왼쪽 label_gap이라 작고 눈에 안 띔).
        // 잠금(프리셋) 행은 편집 자체가 막혀 생략. 선택 행은 accent(강조), 그 외도 surface_fg로 또렷하게. handlePointer가 이 셀을 hit-test.
        if (!r.is_default and !r.disabled) {
            const runs = try arena.alloc(draw.Run, 1);
            runs[0] = .{ .text = reset_glyph };
            const rrole: tokens.ColorRole = if (actual == state.selected) .accent_bar else .surface_fg;
            try out.append(arena, .{ .text = .{ .origin = .{ .x = resetGlyphX(l), .y = ctrl.y }, .runs = runs, .role = rrole, .wide_icons = true } });
        }
        switch (r.kind) {
            .toggle => |v| {
                var ts = toggle.State{ .value = v };
                try toggle.view(&ts, toggleRectIn(ctrl, box.ch, box.cw), box.cw, tk, arena, out);
            },
            .number => |s| {
                // 숫자 입력 박스(슬라이더/프로그레스바 대체 — 사용자 요청). 편집 중인 선택 행이면 편집 버퍼 + caret,
                // 아니면 현재 값을 박스 안에 좌측정렬. Enter로 편집 진입, 커밋 시 파싱·범위 clamp는 platform(setNumber).
                const editing_this = state.editing and actual == state.selected;
                const shown: []const u8 = if (editing_this) state.editText() else (formatNumberValue(arena, s.value) catch "");
                try input_box.view(ctrl, shown, editing_this, r.disabled, box.cw, box.ch, p.shape.corner_radius_px, p.shape.border_width_px, arena, out);
            },
            // dropdown.view가 값 뒤에 " ▾"(2칸)를 붙이므로, chevron 자리를 빼고 truncate해 값+chevron이 control 열(=박스
            // 경계)을 넘지 않게 한다(안 그러면 ctrl_cols+2칸이 되어 우측 여백을 침범·rich quad 밖으로 삐진다).
            .dropdown => |cur| try dropdown.view(ctrl, overlay_input.truncateToCols(arena, cur, l.ctrl_cols -| 2) catch cur, tk, arena, out),
            .font => |cur| {
                // dropdown처럼 보이되(번들 폰트 ←→ 순환), Enter 편집 중이면 편집 버퍼 + caret(목록 밖 시스템/직접입력 폰트).
                // 비편집 = 현재값 + " ▾"(dropdown.view — chevron 자리 빼고 truncate). 편집 렌더는 .text와 drawInlineEdit 공유.
                if (state.editing and actual == state.selected) {
                    try drawInlineEdit(box, ctrl, state.editText(), arena, out);
                } else {
                    try dropdown.view(ctrl, overlay_input.truncateToCols(arena, cur, l.ctrl_cols -| 2) catch cur, tk, arena, out);
                }
            },
            .text => |cur| {
                // 편집 중인 선택 행이면 편집 버퍼 + caret(.font와 drawInlineEdit 공유), 아니면 현재값을 control 좌단
                // (ctrl.x) 좌측정렬. 비편집 값은 control 폭으로 truncate해 박스 밖으로 삐지지 않게 한다(긴 값 — rich quad 밖 비침 방지).
                if (state.editing and actual == state.selected) {
                    try drawInlineEdit(box, ctrl, state.editText(), arena, out);
                } else {
                    const shown = overlay_input.truncateToCols(arena, cur, l.ctrl_cols) catch cur;
                    if (shown.len > 0) {
                        const runs = try arena.alloc(draw.Run, 1);
                        runs[0] = .{ .text = shown };
                        try out.append(arena, .{ .text = .{ .origin = .{ .x = ctrl.x, .y = ctrl.y }, .runs = runs, .role = .surface_fg } });
                    }
                }
            },
            .color => |c| {
                // 스와치(literal RGB) + hex. 편집 중인 선택 행이면 hex 대신 편집 버퍼 + caret(hexX 뒤). text 위젯과 동형.
                const editing_this = state.editing and actual == state.selected;
                const shown: []const u8 = if (editing_this) state.editText() else c.hex;
                const text_role: tokens.ColorRole = if (editing_this) .accent_bar else if (r.disabled) .muted_fg else .surface_fg;
                try color.view(ctrl, c.rgb, shown, text_role, box.cw, p.shape.corner_radius_px, arena, out);
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

    const hint_row = l.first_field_row - 1; // 제목(0) 아래 줄 — title_rows 영역 안(본문은 first_field_row부터 시작)

    // 안내 배너(§6.9) — keybind 녹음 검증 실패/충돌 메시지가 있으면 힌트 줄 대신 **폼 상단에 얹어** 보인다(세팅 모달을
    // 닫는 notice 토스트 대신 — 녹음 중 부적절). accent(⚠ 접두)로 도드라지게, 좌우 여백을 truncate로 박스 안에 가둔다.
    // 배너는 한 줄만 차지하므로 레이아웃 불변(힌트 자리를 대체) — 조합/검색 캡션과 겹치지 않는다(배너는 message 있을 때만).
    if (state.message().len > 0) {
        const banner = try std.fmt.allocPrint(arena, "⚠ {s}", .{state.message()});
        const shown = try overlay_input.truncateToCols(arena, banner, box.inner_cols);
        try modal_box.text(box, box.inner_x, hint_row, shown, .accent_bar, arena, out);
        return; // 배너가 힌트 줄을 대체(같은 행)
    }

    // 내비 힌트 — 제목 바로 아래 중앙에 한 줄(muted). 방향키 영역 모델: ← 네비 · → 설정으로 포커스, ↑↓로 그 영역 이동.
    const nav_hint = "← 섹션 · → 설정 · ↑↓ 이동 · ⏎ 선택";
    const hint_w = overlay_input.displayCols(nav_hint);
    const hx = box.inner_x + @as(i32, @intCast((box.inner_cols -| hint_w) / 2 * box.cw)); // 중앙 정렬
    try modal_box.text(box, hx, hint_row, nav_hint, .muted_fg, arena, out);

    // enum/font 드롭다운 팝업(열려 있으면) — 폼 위 최상위 오버레이. 앵커=선택 행의 축소 control rect(그 아래에 목록이
    // 뜬다). 항목 라벨은 platform이 dropdown_items로 주입(빈 슬라이스면 무동작). 선택 행이 보이는 창 안일 때만.
    if (state.dropdown.open and state.selected >= l.win_start and state.selected < l.win_start + l.win_len) {
        const anchor = fieldControlRect(l, state.selected - l.win_start);
        try dropdown.viewPopup(&state.dropdown, anchor, dropdown_items, p, tk, arena, out);
    }
}

/// 검색 입력줄 caret의 셀 rect(backing px) — IME 후보창 위치(platform imeCursorRect)에 쓴다. 검색 중이 아니거나
/// 레이아웃 불가면 null(platform이 터미널 커서로 폴백). 위치 = 제목 행(0)의 "검색: " + query **끝**(= 조합 시작) —
/// view의 caret_x와 같은 폭 규약(search_prompt + queryCols, EAW). preedit는 안 더한다(조합 글자는 query 끝 caret에 겹쳐 그려짐 — 단일 줄 append라 뒤 텍스트 없음).
pub fn searchCaretRect(state: *const State, sections: []const []const u8, rows: []const FieldRow, p: props.ChromeProps, tk: *const tokens.Tokens) ?draw.Rect {
    if (!state.open or state.picking or !state.searching) return null;
    const l = computeLayout(sections, rows, state.selected, p, tk) orelse return null;
    const box = l.box;
    const caret_cols = overlay_input.displayCols(search_prompt) + overlay_input.displayCols(state.searchQuery());
    return .{
        .x = box.inner_x + @as(i32, @intCast(caret_cols * box.cw)),
        .y = modal_box.rowY(box, 0),
        .w = box.cw,
        .h = box.ch,
    };
}

/// 폼 목록의 스크롤 창과 그 뷰포트 rect(SV5c) — host가 스크롤바를 발행하는 데 쓴다.
///
/// **컴포넌트가 막대를 그리지 않는다.** 모양·기하는 공용 경로(`chrome/ui/scroll_area.zig`)가 소유하고,
/// 여기서는 "어디에 얼마만큼"만 알려 준다. `searchCaretRect`가 caret 위치만 알려 주는 것과 같은 형태다.
///
/// `win_start`는 selected에서 매번 재파생된 값이라 **저장되는 상태가 아니다**(팔레트와 같다 — SV5b).
pub const ScrollView = struct { viewport: draw.Rect, total: usize, visible: usize, win_start: usize };

pub fn scrollView(state: *const State, sections: []const []const u8, rows: []const FieldRow, p: props.ChromeProps, tk: *const tokens.Tokens) ?ScrollView {
    if (!state.open) return null;
    const l = computeLayout(sections, rows, state.selected, p, tk) orelse return null;
    if (rows.len <= l.win_len or l.win_len == 0) return null; // 안 넘침 — 막대 없음
    const box = l.box;
    return .{
        .viewport = .{
            .x = l.form_x,
            .y = modal_box.rowY(box, l.first_field_row),
            // 폼 폭은 이미 gutter를 뗀 값이라, 막대가 설 자리는 그 **오른쪽**이다.
            .w = (l.form_cols + ((p.metrics.overlay_scroll_gutter_px + box.cw - 1) / @max(box.cw, 1))) * box.cw,
            .h = @as(u32, @intCast(l.win_len)) * box.ch,
        },
        .total = rows.len,
        .visible = l.win_len,
        .win_start = l.win_start,
    };
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

    // 미리보기 스와치(현재 효과색) + 정보. 평소엔 "#rrggbb  H S V", **hex 인라인 편집 중엔 버퍼**(`#ab▏ 입력` — 무엇을
    // 치는지 보이게, accent 색). 편집 중에도 스와치는 현재 h/s/v 색(커밋 전이라 직전 색) — Enter로 적용.
    const cur = state.pickerRgb();
    const preview = draw.Rect{ .x = box.inner_x, .y = modal_box.rowY(box, pick_preview_row), .w = pick_swatch_w * box.cw, .h = box.ch };
    try out.append(arena, .{ .swatch = .{ .rect = preview, .rgb = cur } });
    const text_x = box.inner_x + sw_px + @as(i32, @intCast(box.cw));
    if (state.editing) {
        const buf = try std.fmt.allocPrint(arena, "{s}▏ hex 입력", .{state.editText()});
        try modal_box.text(box, text_x, pick_preview_row, buf, .accent_bar, arena, out);
    } else {
        const info = try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}  H{d} S{d} V{d}", .{ cur.r, cur.g, cur.b, state.pick_h, state.pick_s, state.pick_v });
        try modal_box.text(box, text_x, pick_preview_row, info, .surface_fg, arena, out);
    }

    try modal_box.text(box, box.inner_x, pick_help_row, pick_help, .surface_fg, arena, out);
}

/// 키 처리(열려 있을 때만 host 호출). 방향키 영역 모델: ←=네비 포커스·→=폼 포커스, ↑↓=포커스 영역 내 이동(네비=섹션·
/// 폼=행), Space/Enter=폼 행 활성(toggle flip·숫자 입력 박스 편집·enum/폰트 드롭다운 팝업 등), Esc=닫기, 그 외=소비.
/// 드롭다운 팝업이 열려 있으면 모든 키를 팝업이 잡는다(↑↓ 프리뷰·Enter 확정·Esc 취소). 값 종류 판정은 platform이 rows[selected]로 한다.
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    // HSV picker 모드 — ←→ 채도, ↑↓ 명도, `[`/`]` 색상, Enter 확정(.color_picked → platform이 hex 커밋), Esc 취소. 그 외 소비.
    if (state.picking) {
        // picker 안 hex 인라인 편집 중(`#`로 진입) — 정확한 hex를 타이핑/붙여넣어 색을 잡는다. Enter=파싱→h/s/v 적용,
        // Esc=취소(picker 유지), 글자(hex/#)·Backspace=버퍼 편집. picker를 안 닫고 그 안에서 색만 바꾼다.
        if (state.editing) {
            switch (k.key) {
                .enter => {
                    if (color_mod.parseHex(state.editText())) |rgb| {
                        const hsv = color_mod.rgbToHsv(rgb);
                        state.pick_h = hsv.h;
                        state.pick_s = hsv.s;
                        state.pick_v = hsv.v;
                    } // 형식 오류면 무시(편집만 닫음 — 직전 색 유지)
                    state.editing = false;
                    return .selection_changed;
                },
                .escape => {
                    state.editing = false; // 편집만 취소(picker 유지)
                    return .selection_changed;
                },
                .backspace => {
                    state.edit_len = width.dropLastCodepoint(&state.edit_buf, state.edit_len);
                    return .selection_changed;
                },
                .char => {
                    const c = k.codepoint;
                    const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '#';
                    if (is_hex) state.appendEditCp(c); // hex 자리·# 만 받는다(잡문자 차단)
                    return .selection_changed;
                },
                else => return .consumed,
            }
        }
        switch (k.key) {
            .escape => {
                state.closePicker();
                return .selection_changed; // picker만 닫고 폼 복귀(모달 유지)
            },
            .enter => return .color_picked,
            // 화살표: 기본은 그리드 **셀** 이동(빠른 coarse), **Shift**면 ±1 미세(연속 해상도 — 0~100/0~359 임의 값 도달).
            // 셀-그리드는 이산 샘플이지만 pick_s/v/h는 full precision으로 저장되므로, Shift 미세 조정이 그 사이 값을 채운다.
            .left => {
                if (k.mods.shift) {
                    state.pick_s -|= 1; // 미세 -채도(saturating)
                } else {
                    const col = svColForSat(state.pick_s);
                    if (col > 0) state.pick_s = svSatForCol(col - 1);
                }
                return .selection_changed;
            },
            .right => {
                if (k.mods.shift) {
                    state.pick_s = @min(100, state.pick_s + 1); // 미세 +채도
                } else {
                    const col = svColForSat(state.pick_s);
                    if (col + 1 < pick_sv_cols) state.pick_s = svSatForCol(col + 1);
                }
                return .selection_changed;
            },
            .up => {
                if (k.mods.shift) {
                    state.pick_v = @min(100, state.pick_v + 1); // 미세 +명도
                } else {
                    const row = svRowForVal(state.pick_v);
                    if (row > 0) state.pick_v = svValForRow(row - 1);
                }
                return .selection_changed;
            },
            .down => {
                if (k.mods.shift) {
                    state.pick_v -|= 1; // 미세 -명도
                } else {
                    const row = svRowForVal(state.pick_v);
                    if (row + 1 < pick_sv_rows) state.pick_v = svValForRow(row + 1);
                }
                return .selection_changed;
            },
            // 색상: `[`/`]` 셀 이동(coarse), `{`/`}`(=Shift+[/]) ±1° 미세(연속 해상도). h는 0~359 wrap. `#`=hex 인라인 편집.
            .char => {
                if (k.codepoint == '#') { // hex 인라인 편집 시작 — `#`로 빈 입력 시작(이어서 6자리 타이핑/붙여넣기).
                    state.enterEdit("#"); // editing=true + 버퍼="#"(위 editing 분기로 라우팅). 현재값 시드 안 함(새 입력이 자연스러움).
                    return .selection_changed;
                }
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
                if (k.codepoint == '{') { // Shift+[ — 미세 -1°
                    state.pick_h = if (state.pick_h == 0) 359 else state.pick_h - 1;
                    return .selection_changed;
                }
                if (k.codepoint == '}') { // Shift+] — 미세 +1°
                    state.pick_h = (state.pick_h + 1) % 360;
                    return .selection_changed;
                }
                if (k.codepoint == 'i') return .eyedropper; // 스포이드 — platform이 OS 화면 색 추출기(NSColorSampler)를 연다
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
    // enum/font 드롭다운 팝업이 열려 있으면 모든 키를 팝업이 잡는다(모달 캡처). **검색보다 먼저** 본다 — 검색 중 열린
    // 드롭다운도 ↑↓가 팝업 선택을 움직여야지 뒤의 필터된 행으로 새면 안 된다. ↑↓ 선택·Enter 확정·Esc 취소(팝업만 닫고
    // 검색 유지)·그 외 소비. accept는 platform이 selected 변형을 set(dropdown_accept)한 뒤 host가 닫는다.
    if (state.dropdown.open) {
        return switch (dropdown.handle(k, &state.dropdown)) {
            .accept => .dropdown_accept, // Enter — 현재 selected 확정(적용 + 팝업 닫기)
            .close => .dropdown_cancel, // Esc — dropdown.handle이 이미 hide, platform이 original로 복원(프리뷰 되돌림)
            .selection_changed => .dropdown_preview, // ↑↓ — platform이 highlighted를 **라이브 적용**(팝업 유지, 바로 반영)
            .consumed => .consumed,
        };
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
    // **방향키 영역 모델**: `←`=섹션 네비로 포커스, `→`=폼으로 포커스, `↑↓`=포커스 영역 안에서 이동(네비=섹션·폼=행),
    // Enter/Space=폼 행 활성(네비에선 Enter=폼 진입), Esc=닫기. Tab 무동작. (팔레트 그리드 행의 ←→ 셀 이동은 platform이
    // pre-intercept — 그 행에선 ←→가 여기 안 온다. ←가 셀 0에서·→가 마지막 셀에서만 여기로 와 영역 이동으로 이어진다.)
    switch (k.key) {
        .escape => {
            state.hide();
            return .close;
        },
        .left => {
            if (state.nav_focused) return .consumed; // 이미 좌측(네비) — 더 왼쪽 없음
            state.nav_focused = true; // 폼 → 네비로 포커스
            return .selection_changed;
        },
        .right => {
            if (state.nav_focused) {
                state.nav_focused = false; // 네비 → 폼으로 포커스
                return .selection_changed;
            }
            return .consumed; // 이미 우측(폼) — 더 오른쪽 없음
        },
        .up => {
            if (state.nav_focused) {
                if (state.section == 0) return .consumed; // 첫 섹션에서 정지
                state.selectSection(state.section - 1); // selectSection은 nav_focused 보존
                return .section_changed;
            }
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            if (state.nav_focused) {
                state.selectSection(state.section + 1); // 상한은 platform이 clamp(섹션 수를 컴포넌트는 모른다)
                return .section_changed;
            }
            state.moveSelection(1);
            return .selection_changed;
        },
        .enter => {
            if (state.nav_focused) {
                // 네비 맨 아래 "↺ 모든 설정 초기화" 액션 행이면 폼 진입 대신 전체 리셋(§6.4). 그 외 섹션 행은 폼으로 진입.
                if (state.nav_reset_row) |ri| if (state.section == ri) return .reset_all;
                state.nav_focused = false; // 네비에서 Enter → 폼으로 진입(그 섹션 확정)
                return .selection_changed;
            }
            return if (state.count == 0) .consumed else .toggle;
        },
        .backspace => return if (state.nav_focused or state.count == 0) .consumed else .delete_row, // 폼 선택 행 삭제(env 행만)
        .char => {
            if (k.codepoint == '/') { // '/'로 검색 시작(현재 섹션 필터)
                state.startSearch();
                return .search_changed;
            }
            return if (!state.nav_focused and k.codepoint == ' ' and state.count > 0) .toggle else .consumed;
        },
        else => return .consumed, // Tab 포함 — 무동작
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
        // sub-cell 연속: 픽셀 위치를 0~100 s/v로 직접 매핑(셀 양자화 안 함 — 클릭/드래그로 셀 사이 임의 색). 좌→우
        // 채도 0~100, 위→아래 명도 100~0. 그리드 폭/높이로 정규화 후 clamp(밖으로 드래그해도 경계값으로 saturate).
        const grid_w: f64 = sw_px * @as(f64, @floatFromInt(pick_sv_cols));
        const grid_h: f64 = ch_px * @as(f64, @floatFromInt(pick_sv_rows));
        const fx = std.math.clamp((ev.x_px - inner_x) / grid_w, 0, 1);
        const fy = std.math.clamp((ev.y_px - sv_y0) / grid_h, 0, 1);
        state.pick_s = @intFromFloat(@round(fx * 100));
        state.pick_v = @intFromFloat(@round((1.0 - fy) * 100));
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

/// 포인터 처리(열려 있을 때만). up=소비. down=박스 밖이면 닫기, 안이면 행 선택 후 위젯별: toggle 위→.toggle, number
/// (control)→.toggle(편집 진입), dropdown/font→.toggle(팝업 열기), text/color/keybind→.toggle/편집, 그 외(라벨)→
/// .selection_changed. 드롭다운 팝업이 열려 있으면 항목 클릭=.dropdown_accept·밖 클릭=닫기. 우클릭=소비.
/// dropdown_items=팝업 변형 라벨(itemAt hit-test용 — view와 같은 platform 주입).
pub fn handlePointer(
    ev: input.PointerEvent,
    sections: []const []const u8,
    rows: []const FieldRow,
    dropdown_items: []const []const u8,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    state: *State,
) Action {
    if (ev.button != .left) return .consumed;
    // HSV picker 모드 — SV 그리드/hue 스트립 클릭·드래그로 s/v·h 선택, 박스 밖 클릭은 picker 취소(폼 복귀). 폼 hit-test 안 함.
    if (state.picking) return pickerPointer(ev, p, tk, state);
    const l = computeLayout(sections, rows, state.selected, p, tk) orelse return .consumed;
    const box = l.box;
    // 드롭다운 팝업이 열려 있으면(모달) 폼 hit-test 대신 팝업만: down이 항목 위면 그 변형 선택+적용, 밖이면 닫기.
    // 앵커=선택 행의 축소 control rect(view와 같은 계산 — "보이는 == 클릭되는").
    if (state.dropdown.open) {
        if (ev.phase != .down) return .consumed;
        if (state.selected >= l.win_start and state.selected < l.win_start + l.win_len) {
            const anchor = fieldControlRect(l, state.selected - l.win_start);
            if (dropdown.itemAt(&state.dropdown, anchor, dropdown_items, p, ev.x_px, ev.y_px)) |idx| {
                state.dropdown.selected = idx;
                return .dropdown_accept; // 항목 클릭 → platform이 그 변형 set + 닫기
            }
        }
        state.dropdown.hide(); // 밖 클릭 → 취소(platform이 original로 복원)
        return .dropdown_cancel;
    }

    if (ev.phase == .up) {
        state.dragging = false;
        return .consumed;
    }
    if (ev.phase == .move) return .consumed; // 슬라이더 드래그 제거 — 숫자는 클릭→입력 박스 편집이라 move는 무동작
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
    // 제목 행(row 0) 클릭 → 검색 시작(클릭 진입점, 키 `/`와 같은 경로). 검색 중이면 그대로(제목=검색창이라 무동작).
    // 필드 행은 first_field_row(=title_rows=2)부터라 이 hit-test는 nav/form과 충돌하지 않는다. config-gui §6.8.
    if (!state.searching) {
        const ty: f64 = @floatFromInt(modal_box.rowY(box, 0));
        if (ev.y_px >= ty and ev.y_px < ty + @as(f64, @floatFromInt(box.ch))) {
            state.startSearch();
            return .search_changed;
        }
    }
    // 좌측 네비 영역(x < form_x) 클릭 → 섹션 행 선택(y로 판정). 비-행이면 소비.
    const form_x_f: f64 = @floatFromInt(l.form_x);
    if (ev.x_px < form_x_f) {
        for (sections, 0..) |_, i| {
            const ny: f64 = @floatFromInt(modal_box.rowY(box, l.first_field_row + @as(u32, @intCast(i))));
            if (ev.y_px >= ny and ev.y_px < ny + @as(f64, @floatFromInt(box.ch))) {
                state.nav_focused = true; // 네비 클릭 → 네비 포커스(↑↓가 섹션 이동)
                // 맨 아래 "↺ 초기화" 액션 행 클릭 → 전체 리셋(§6.4). 섹션 전환이 아니라 액션이라 selectSection을 안 부른다
                // (그 행을 하이라이트만; platform이 requestResetAll로 확인 모달을 연다).
                if (state.nav_reset_row) |ri| if (i == ri) {
                    state.section = i;
                    return .reset_all;
                };
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
            state.nav_focused = false; // 폼 행 클릭 → 폼 포커스(↑↓가 행 이동)
            // ↺ 리셋 어포던스 셀(폼 행 맨 오른쪽 1칸, view의 resetGlyphX와 같은 위치) 클릭 → 그 항목만 기본값 복원(§6.11).
            // 변경된(!is_default)·잠금 아닌(!disabled) 행만. 위젯 hit보다 먼저 검사(↺ 셀은 reset_gutter라 위젯 영역과 안 겹침).
            if (!r.is_default and !r.disabled) {
                const rx: f64 = @floatFromInt(resetGlyphX(l));
                if (ev.x_px >= rx and ev.x_px < rx + @as(f64, @floatFromInt(reset_icon_cols * box.cw))) return .reset_field;
            }
            switch (r.kind) {
                .toggle => return if (toggle.hitTest(toggleRectIn(ctrl, box.ch, box.cw), ev.x_px, ev.y_px)) .toggle else .selection_changed,
                .number => return if (input_box.hitTest(ctrl, ev.x_px, ev.y_px)) .toggle else .selection_changed, // 입력 박스 클릭 → 편집 진입(.toggle=활성, platform이 현재값 시드), 라벨은 선택만
                .dropdown => return if (dropdown.hitTest(ctrl, ev.x_px, ev.y_px)) .toggle else .selection_changed, // 축소 control 클릭 → 팝업 열기(.toggle=활성, platform이 openDropdown)
                .text => return if (ev.x_px >= @as(f64, @floatFromInt(ctrl.x))) .toggle else .selection_changed, // control 영역 클릭 → 인라인 편집(.toggle=활성), 라벨은 선택만
                .font => return if (dropdown.hitTest(ctrl, ev.x_px, ev.y_px)) .toggle else .selection_changed, // 축소 control 클릭 → 팝업 열기(번들 폰트 목록, platform이 openDropdown)
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
const no_items: []const []const u8 = &.{}; // 드롭다운 팝업 닫힘 — view/handlePointer의 dropdown_items 빈 슬라이스
const test_sections = [_][]const u8{ "Font", "Cursor", "Window" };

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
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
    try view(&s, no_sections, &rows, no_items, small, &tk, arena, &out);
    const mv = maxVisible(small);
    try std.testing.expect(mv < rows.len); // 윈도잉 발생(작은 뷰포트)
    // 제목에 "Settings   19/20" 위치 표식(rows.len > win_len).
    try std.testing.expect(std.mem.indexOf(u8, out.items[1].text.runs[0].text, "19/20") != null);
    // 패널 높이가 전체 20행이 아니라 창(mv)만큼이라 뷰포트(200) 안.
    try std.testing.expect(out.items[0].quad.rect.h <= 200);
}

test "settings formatNumberValue: 소수 2자리 + 뒤따르는 0/점 제거(정수·딱떨어지는 소수 깔끔히)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("14", try formatNumberValue(arena, 14.0)); // 정수
    try std.testing.expectEqualStrings("200", try formatNumberValue(arena, 200.0)); // u32 필드(whole)
    try std.testing.expectEqualStrings("2.28", try formatNumberValue(arena, 2.276)); // 소수 2자리 반올림
    try std.testing.expectEqualStrings("1.5", try formatNumberValue(arena, 1.5)); // 뒤 0 하나 제거
    try std.testing.expectEqualStrings("-8", try formatNumberValue(arena, -8.0)); // 음수 정수
    try std.testing.expectEqualStrings("0.1", try formatNumberValue(arena, 0.1)); // 소수 1자리
    try std.testing.expectEqualStrings("16.64", try formatNumberValue(arena, 16.64));
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

test "settings handle: 방향키 영역 모델(←네비·→폼·↑↓ 영역 내 이동)·Enter 활성·Tab 무동작" {
    // ← = 네비 포커스, → = 폼 포커스, ↑↓ = 그 영역 안에서 이동(네비=섹션·폼=행), Enter/Space=폼 행 활성.
    var s = State{};
    s.show(); // 폼 포커스로 시작(nav_focused=false)
    s.setFieldCount(3);
    try std.testing.expect(!s.nav_focused);
    // 폼에서 ↑↓ = 행 이동.
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    // → (이미 폼) = consumed. ← = 네비로 포커스.
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .right }, &s));
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .left }, &s));
    try std.testing.expect(s.nav_focused);
    // 네비에서 ↓ = 섹션 +1(selected 리셋). ← (이미 네비) = consumed.
    try std.testing.expectEqual(Action.section_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.section);
    try std.testing.expect(s.nav_focused); // selectSection이 nav_focused 보존
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .left }, &s));
    // 네비에서 → = 폼으로 복귀. 첫 섹션에서 ↑ = 정지.
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .right }, &s));
    try std.testing.expect(!s.nav_focused);
    // 폼에서 Enter/Space = 행 활성(toggle).
    s.setFieldCount(3);
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .enter }, &s));
    try std.testing.expectEqual(Action.toggle, handle(.{ .key = .char, .codepoint = ' ' }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'a' }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .tab }, &s)); // Tab 무동작
    // Esc → close + hide.
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.open);
}

test "settings handle: 드롭다운 팝업 열림 라우팅(↑↓=preview·Enter=accept·Esc=cancel·←→/글자=consumed)" {
    // 팝업이 열려 있으면 handle이 dropdown.handle로 라우팅해 settings.Action으로 매핑한다 — ↑↓는 라이브 프리뷰
    // (dropdown_preview), Enter는 확정(dropdown_accept), Esc는 취소(dropdown_cancel, 원복). ←→/글자가 섹션·영역으로
    // 새지 않고 consumed되어 팝업이 유지되는 게 회귀 가드(모달 캡처).
    var s = State{};
    s.show();
    s.dropdown.show(3, 0); // 항목 3, 현재 인덱스 0
    try std.testing.expect(s.dropdown.open);
    try std.testing.expectEqual(@as(usize, 0), s.dropdown.original); // show가 original=현재로

    // ↓ → 라이브 프리뷰 + selected 이동.
    try std.testing.expectEqual(Action.dropdown_preview, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.dropdown.selected);
    // ←→/글자 → consumed(팝업 유지 — 섹션/영역으로 안 샘).
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .left }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .right }, &s));
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'x' }, &s));
    try std.testing.expect(s.dropdown.open);
    // Enter → accept(컴포넌트는 안 닫음 — platform이 닫는다).
    try std.testing.expectEqual(Action.dropdown_accept, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.dropdown.open);
    // Esc → cancel + 닫힘(dropdown.handle이 hide).
    try std.testing.expectEqual(Action.dropdown_cancel, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.dropdown.open);
}

test "settings handle: 검색 중 열린 드롭다운이 ↑↓를 먼저 잡는다(필터된 행으로 안 샘 — 회귀 가드)" {
    // 버그: 검색 상태에서 드롭다운을 열면 handle이 searching 분기를 먼저 봐 ↑↓가 뒤의 필터된 행을 이동시켰다.
    // 드롭다운 팝업은 모달이라 **검색보다 먼저** 캡처해야 한다 — ↑↓=팝업 선택, Esc=팝업만 닫고 검색 유지.
    var s = State{};
    s.show();
    s.setFieldCount(3);
    s.startSearch(); // 검색 상태
    try std.testing.expect(s.searching);
    s.dropdown.show(3, 0); // 검색 중 드롭다운 열림
    try std.testing.expect(s.dropdown.open);

    // ↓↑ → 드롭다운 프리뷰(행 이동 아님). selected가 팝업 안에서 움직인다.
    try std.testing.expectEqual(Action.dropdown_preview, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.dropdown.selected);
    try std.testing.expectEqual(Action.dropdown_preview, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.dropdown.selected);
    // Esc → 드롭다운만 취소(dropdown_cancel), 검색은 유지.
    try std.testing.expectEqual(Action.dropdown_cancel, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.dropdown.open);
    try std.testing.expect(s.searching); // 검색 유지(드롭다운만 닫힘)
}

test "settings view: 닫힘=0 ops, 열림=frame+제목+toggle 행(트랙+knob text)+number 행(입력 박스 값 text)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, no_sections, &.{}, no_items, test_props, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show();
    const rows = [_]FieldRow{
        .{ .label = "Cursor blink", .kind = .{ .toggle = true } },
        .{ .label = "Font size", .kind = .{ .number = .{ .value = 512, .min = 1, .max = 512 } } }, // 입력 박스 렌더
    };
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    // tui(border 0): 위젯이 모두 셀 정렬 text(quad 아님). frame(quad)=1, 제목=1, 검색힌트=1.
    // 행0(선택 fill + label + toggle 트랙 text + knob text)=4. 행1(label + 입력 박스 값 text)=2. 마지막=내비 힌트 1줄.
    try std.testing.expect(out.items[0] == .quad); // 박스 bg
    try std.testing.expect(out.items[1] == .text); // 제목
    try std.testing.expectEqualStrings("/ 검색", out.items[2].text.runs[0].text); // 검색 진입점 힌트(제목 우측, muted)
    try std.testing.expect(out.items[3] == .fill); // 행0 선택 하이라이트(셀 bg)
    try std.testing.expectEqualStrings("Cursor blink", out.items[4].text.runs[0].text);
    try std.testing.expect(out.items[5] == .text); // toggle 트랙(muted) — quad 아님
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[5].text.role);
    try std.testing.expectEqual(tokens.ColorRole.accent_bar, out.items[6].text.role); // toggle knob on(앰버)
    // 행1(number 입력 박스, tui=border 0 → 값 text만): 라벨 + 현재 값 "512"(surface_fg). 슬라이더 트랙/채움 없음.
    try std.testing.expectEqualStrings("Font size", out.items[7].text.runs[0].text);
    try std.testing.expectEqualStrings("512", out.items[8].text.runs[0].text); // 입력 박스 안 현재 값
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[8].text.role);
    // 마지막: 화살표 내비 힌트 한 줄(muted) — 옛 "⇥ 섹션 ⇄ 설정" Tab 힌트 대체.
    const hint = out.items[out.items.len - 1];
    try std.testing.expect(hint == .text);
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, hint.text.role);
    try std.testing.expect(std.mem.indexOf(u8, hint.text.runs[0].text, "섹션") != null);
}

test "settings handlePointer: 박스 밖=닫기, toggle 클릭=.toggle, number(입력박스) 클릭=.toggle(편집 진입), 라벨=.selection_changed" {
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{
        .{ .label = "A", .kind = .{ .toggle = false } },
        .{ .label = "Size", .kind = .{ .number = .{ .value = 1, .min = 1, .max = 100 } } }, // 숫자 = 입력 박스 렌더
    };
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;

    // 박스 밖(0,0) 좌클릭 → 닫기.
    try std.testing.expectEqual(Action.close, handlePointer(.{ .phase = .down, .x_px = 0, .y_px = 0 }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expect(!s.open);

    // 행0 toggle 중앙 클릭 → 선택=0 + .toggle.
    s.show();
    const tgl = toggleRectIn(fieldControlRect(l, 0), test_props.metrics.cell_height_px, test_props.metrics.cell_width_px);
    try std.testing.expectEqual(Action.toggle, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(tgl.x + 4), .y_px = @floatFromInt(tgl.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 행1 숫자 입력 박스(control 열) 클릭 → 선택=1 + .toggle(platform이 현재값으로 편집 진입). 슬라이더 드래그 없음.
    const c1 = fieldControlRect(l, 1);
    const mid_y: f64 = @floatFromInt(c1.y + 4);
    try std.testing.expectEqual(Action.toggle, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(c1.x + 4), .y_px = mid_y }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expect(!s.dragging); // 드래그 상태 안 생김(슬라이더 제거)

    // move → 소비(드래그 추적 없음).
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .move, .x_px = @floatFromInt(c1.x + 2), .y_px = mid_y }, no_sections, &rows, no_items, test_props, &tk, &s));
    // up → 소비.
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .up, .x_px = @floatFromInt(c1.x + 2), .y_px = mid_y }, no_sections, &rows, no_items, test_props, &tk, &s));

    // 행0 폼 라벨 영역 클릭(form_x — control 왼쪽, 위젯 밖) → .selection_changed.
    const c0 = fieldControlRect(l, 0);
    try std.testing.expectEqual(Action.selection_changed, handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 2), .y_px = @floatFromInt(c0.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}

test "settings handlePointer: 제목 행 클릭 → 검색 시작(.search_changed), 검색 중엔 무동작" {
    const tk = testTokens();
    var s = State{};
    s.show();
    const rows = [_]FieldRow{.{ .label = "A", .kind = .{ .toggle = false } }};
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;
    const box = l.box;
    const ty: f64 = @floatFromInt(modal_box.rowY(box, 0)); // 제목 행(row 0)
    const tx: f64 = @floatFromInt(box.inner_x + 2);

    // 검색이 아닐 때 제목 행 클릭 → 검색 시작(키 `/`와 같은 경로).
    try std.testing.expect(!s.searching);
    try std.testing.expectEqual(Action.search_changed, handlePointer(.{ .phase = .down, .x_px = tx, .y_px = ty + 2 }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expect(s.searching);

    // 검색 중 제목(검색창) 재클릭 → 검색 재시작 안 함(제목 클릭 게이트가 !searching이라 통과 → nav/form hit-test = .consumed).
    try std.testing.expectEqual(Action.consumed, handlePointer(.{ .phase = .down, .x_px = tx, .y_px = ty + 2 }, no_sections, &rows, no_items, test_props, &tk, &s));
    try std.testing.expect(s.searching);
}

test "settings nav 키보드: 방향키 영역 포커스(←네비·→폼) + 각 영역 ↑↓" {
    // 방향키 영역 모델: ←=네비 포커스, →=폼 포커스. 네비에서 ↑↓=섹션(selected 리셋, nav_focused 보존), 폼에서 ↑↓=행.
    var s = State{};
    s.show();
    s.section = 1;
    s.count = 3;
    s.selected = 2;
    try std.testing.expect(!s.nav_focused); // 폼 시작

    // ← → 네비 포커스(섹션 불변).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .left }, &s));
    try std.testing.expect(s.nav_focused);
    try std.testing.expectEqual(@as(usize, 1), s.section);

    // 네비 ↓ → 섹션 +1 + selected 리셋, nav_focused 유지.
    try std.testing.expectEqual(Action.section_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 2), s.section);
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    try std.testing.expect(s.nav_focused);

    // 네비 ↑ → 섹션 -1. 첫 섹션에서 ↑ = 정지.
    try std.testing.expectEqual(Action.section_changed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.section);
    s.section = 0;
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .up }, &s));
    try std.testing.expectEqual(@as(usize, 0), s.section);

    // 네비 → → 폼 포커스. 폼 ↑↓ = 행 이동(섹션 불변).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .right }, &s));
    try std.testing.expect(!s.nav_focused);
    s.count = 3;
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(@as(usize, 0), s.section);

    // Tab = 무동작.
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .tab }, &s));
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
    try view(&s, &test_sections, &rows, no_items, test_props, &tk, arena, &out);
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
    const act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 4), .y_px = ny + 4 }, &test_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.section_changed, act);
    try std.testing.expectEqual(@as(usize, 1), s.section);
    try std.testing.expectEqual(@as(usize, 0), s.selected);

    // 같은 섹션(1) 재클릭 → selection_changed(부수효과 없음).
    const act2 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 4), .y_px = ny + 4 }, &test_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, act2);
    try std.testing.expectEqual(@as(usize, 1), s.section);
}

test "settings 리셋 UX(§6.4·§6.11): 네비 리셋 행 Enter/클릭 → reset_all·변경 행에만 ↺ 어포던스 렌더" {
    // 전체 리셋 진입점(네비 맨 아래 액션 행)과 항목별 리셋 어포던스(변경 행 ↺)의 컴포넌트 계약:
    // (1) nav_reset_row에서 Enter/클릭이 폼 진입이 아니라 .reset_all을 내고, (2) view가 is_default=false 행에만 ↺를 그린다.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();

    // 네비 라벨 = 실제 섹션 3개 + 맨 아래 "↺ 초기화" 액션 행(platform의 buildSettingsSectionLabels 형태).
    const nav = [_][]const u8{ "Font", "Cursor", "Window", "↺ 초기화" };
    var s = State{};
    s.show();
    s.nav_reset_row = 3; // platform이 refreshSettingsFieldCount에서 주입(=실제 섹션 수)
    s.nav_focused = true;
    s.section = 3; // 리셋 행 선택

    // (1a) 네비 포커스 + 리셋 행에서 Enter → reset_all(섹션 폼 진입 아님).
    try std.testing.expectEqual(Action.reset_all, handle(.{ .key = .enter }, &s));

    // (1b) 리셋 행 클릭 → reset_all.
    const rows = [_]FieldRow{.{ .label = "A", .kind = .{ .toggle = false } }};
    const l = computeLayout(&nav, &rows, s.selected, test_props, &tk).?;
    const ny: f64 = @floatFromInt(modal_box.rowY(l.box, l.first_field_row + 3)); // 리셋 행(nav 인덱스 3)
    const act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.box.inner_x + 2), .y_px = ny + 2 }, &nav, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.reset_all, act);

    // (2) view는 is_default=false 행에만 ↺(reset_glyph)를 그린다 — 기본값 행엔 없음.
    var out: std.ArrayList(draw.Op) = .empty;
    const rows2 = [_]FieldRow{
        .{ .label = "changed", .kind = .{ .toggle = true }, .is_default = false },
        .{ .label = "keeps-default", .kind = .{ .toggle = false }, .is_default = true },
    };
    s.nav_focused = false;
    s.section = 0;
    try view(&s, &nav, &rows2, no_items, test_props, &tk, arena, &out);
    var reset_glyphs: usize = 0;
    for (out.items) |op| if (op == .text) {
        if (std.mem.eql(u8, op.text.runs[0].text, reset_glyph)) reset_glyphs += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), reset_glyphs); // 변경 행 1개만 ↺
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
    try view(&s, &test_sections, &rows, no_items, narrow, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 너무 좁아 안 그림

    // [11] 편집 bleed: text 행 편집 중 다른 행(toggle) 클릭 → 편집 종료(버퍼가 안 샘).
    s.setFieldCount(rows.len);
    s.selected = 0;
    s.enterEdit("editing...");
    try std.testing.expect(s.editing);
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;
    const c1 = fieldControlRect(l, 1); // 행1(toggle)
    _ = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 2), .y_px = @floatFromInt(c1.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
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
    const sw_act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(ctrl.x + 2), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.toggle, sw_act);
    try std.testing.expect(!s.editing); // 스와치 클릭은 편집 아님

    // hex 영역 클릭 → 인라인 편집 시작(현재 hex 시드).
    const hx = color.hexX(ctrl, test_props.metrics.cell_width_px) + 4;
    const hex_act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(hx), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
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
    const a1 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(sw5.x + 2), .y_px = @floatFromInt(sw5.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, a1);
    try std.testing.expectEqual(@as(usize, 5), s.grid_cell);
    try std.testing.expect(!s.editing);

    // hex 영역 클릭 → 선택 셀(5) 인라인 편집 시드(cells[5].hex="#000000").
    const hx = paletteHexX(grid, test_props.metrics.cell_width_px) + 4;
    const a2 = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(hx), .y_px = @floatFromInt(grid.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
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

    // handlePointer: 다시 열고 SV 그리드 **좌상단 모서리**(inner_x, sv_y0) 클릭 → s=0, v=100(연속 매핑이라 정확히 모서리).
    s.openPicker(.{ .r = 255, .g = 0, .b = 0 });
    const box = pickerLayout(test_props, &tk).?;
    const sw_px: i32 = @intCast(pick_swatch_w * box.cw);
    const pa = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(box.inner_x), .y_px = @floatFromInt(modal_box.rowY(box, 1)) }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, pa);
    try std.testing.expectEqual(@as(u8, 0), s.pick_s); // 좌단 = 채도 0
    try std.testing.expectEqual(@as(u8, 100), s.pick_v); // 상단 = 명도 100

    // hue 스트립 col 8 클릭 → h = hueForCol(8).
    const ha = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(box.inner_x + 8 * sw_px + 1), .y_px = @floatFromInt(modal_box.rowY(box, pick_hue_row) + 2) }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, ha);
    try std.testing.expectEqual(hueForCol(8), s.pick_h);

    // 박스 밖 클릭 → picker 취소(폼 복귀).
    const oa = handlePointer(.{ .phase = .down, .x_px = -10, .y_px = -10 }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, oa);
    try std.testing.expect(!s.picking);
}

test "settings HSV picker 미세 조정: Shift+화살표 ±1 채도/명도, {/} ±1° hue (연속 해상도 — 그리드 셀 사이 값)" {
    var s: State = .{};
    s.openPicker(.{ .r = 128, .g = 64, .b = 200 }); // 임의 시드(s,v < 100, h 임의)
    // Shift+→ = 채도 +1(셀 점프 말고 ±1 미세 — 0~100 임의 값 도달).
    const s0 = s.pick_s;
    try std.testing.expect(s0 < 100);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .right, .mods = .{ .shift = true } }, &s));
    try std.testing.expectEqual(@as(u8, s0 + 1), s.pick_s);
    // Shift+← = 채도 -1(복귀).
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .left, .mods = .{ .shift = true } }, &s));
    try std.testing.expectEqual(s0, s.pick_s);
    // Shift+↑ = 명도 +1.
    const v0 = s.pick_v;
    try std.testing.expect(v0 < 100);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .up, .mods = .{ .shift = true } }, &s));
    try std.testing.expectEqual(@as(u8, v0 + 1), s.pick_v);
    // }/{ = hue ±1°(wrap) — Shift+]/[ 의 char.
    const h0 = s.pick_h;
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .char, .codepoint = '}' }, &s));
    try std.testing.expectEqual(@as(u16, (h0 + 1) % 360), s.pick_h);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .char, .codepoint = '{' }, &s));
    try std.testing.expectEqual(h0, s.pick_h);

    // 미세는 그리드 셀 경계와 무관 — 평범한 → 셀 점프와 다른 값에 도달 가능(연속 해상도 입증).
    // s0+1이 svColForSat이 가리키는 셀의 정확한 채도(svSatForCol)와 일반적으로 다름(셀은 0,6,13,...).
    s.pick_s = s0;
    _ = handle(.{ .key = .right, .mods = .{ .shift = true } }, &s); // s0+1
    const fine = s.pick_s;
    s.pick_s = s0;
    _ = handle(.{ .key = .right }, &s); // 셀 점프(다음 셀의 svSatForCol)
    try std.testing.expect(s.pick_s != fine or svSatForCol(svColForSat(s0) + 1) == s0 + 1); // 보통 셀≠미세(셀이 우연히 s0+1이면 예외)
}

test "settings HSV picker 포인터 sub-cell: SV 그리드 중앙 클릭 → s≈50·v≈50 (셀 양자화 아님)" {
    const tk = testTokens();
    const rows = [_]FieldRow{.{ .label = "BG", .kind = .{ .color = .{ .hex = "#ff0000", .rgb = .{ .r = 255, .g = 0, .b = 0 } } } }};
    var s: State = .{};
    s.openPicker(.{ .r = 255, .g = 0, .b = 0 });
    const box = pickerLayout(test_props, &tk).?;
    const sw_px: f64 = @floatFromInt(pick_swatch_w * box.cw);
    const ch_px: f64 = @floatFromInt(box.ch);
    // SV 그리드 **중앙** 클릭 → 좌→우 채도 0~100의 중앙=50, 위→아래 명도 100~0의 중앙=50. 셀 경계와 무관(연속).
    const cx: f64 = @as(f64, @floatFromInt(box.inner_x)) + sw_px * @as(f64, @floatFromInt(pick_sv_cols)) / 2.0;
    const cy: f64 = @as(f64, @floatFromInt(modal_box.rowY(box, 1))) + ch_px * @as(f64, @floatFromInt(pick_sv_rows)) / 2.0;
    const pa = handlePointer(.{ .phase = .down, .x_px = cx, .y_px = cy }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, pa);
    try std.testing.expectEqual(@as(u8, 50), s.pick_s);
    try std.testing.expectEqual(@as(u8, 50), s.pick_v);
    // SV 그리드 우측 끝 안쪽(박스 내) 드래그 → 채도≈100(연속 추적). down이 dragging을 켰으므로 move가 값 추적.
    const right_x: f64 = @as(f64, @floatFromInt(box.inner_x)) + sw_px * @as(f64, @floatFromInt(pick_sv_cols)) - 1.0;
    const pb = handlePointer(.{ .phase = .move, .x_px = right_x, .y_px = cy }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.selection_changed, pb);
    try std.testing.expect(s.pick_s >= 99); // 우측 끝 ≈ 100
}

test "settings HSV picker hex 인라인: # 진입·타이핑·Enter 파싱→h/s/v, Esc 취소, 비-hex 차단 (picker 후속)" {
    var s: State = .{};
    s.openPicker(.{ .r = 0, .g = 0, .b = 0 }); // 검정 시드(h/s/v=0)
    // `#` → hex 편집 시작(버퍼="#").
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .char, .codepoint = '#' }, &s));
    try std.testing.expect(s.editing);
    try std.testing.expectEqualStrings("#", s.editText());
    // 6자리 hex 타이핑(#ff0080 = 순수 빨강-마젠타). 비-hex('z')는 차단.
    for ("ff00z80") |c| _ = handle(.{ .key = .char, .codepoint = c }, &s);
    try std.testing.expectEqualStrings("#ff0080", s.editText()); // z 빠짐
    // Enter → parseHex→rgbToHsv 적용. #ff0080의 hsv ≈ h=330, s=100, v=100.
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .enter }, &s));
    try std.testing.expect(!s.editing); // 편집 종료
    try std.testing.expect(s.picking); // picker는 유지
    const back = s.pickerRgb();
    try std.testing.expectEqual(@as(u8, 0xff), back.r); // 적용된 색이 #ff0080 근사
    try std.testing.expectEqual(@as(u8, 0x80), back.b);

    // Esc는 편집만 취소(picker 유지·색 불변). 새 # 편집 후 Esc.
    const before = s.pickerRgb();
    _ = handle(.{ .key = .char, .codepoint = '#' }, &s);
    _ = handle(.{ .key = .char, .codepoint = '0' }, &s);
    try std.testing.expect(s.editing);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .escape }, &s));
    try std.testing.expect(!s.editing);
    try std.testing.expect(s.picking); // picker 유지(편집만 닫힘)
    try std.testing.expectEqual(before.r, s.pickerRgb().r); // 색 불변(취소)
}

test "settings HSV picker 스포이드: i→.eyedropper, setPickerRgb 반영 + picking·non-editing 가드 (picker 후속)" {
    var s: State = .{};
    s.openPicker(.{ .r = 0, .g = 0, .b = 0 }); // 검정 시드
    // `i` → .eyedropper Action(platform이 NSColorSampler 연다).
    try std.testing.expectEqual(Action.eyedropper, handle(.{ .key = .char, .codepoint = 'i' }, &s));
    // setPickerRgb: picking·non-editing이면 반영(#ff0080 → pickerRgb 근사 r=0xff·b=0x80).
    s.setPickerRgb(.{ .r = 0xff, .g = 0, .b = 0x80 });
    try std.testing.expectEqual(@as(u8, 0xff), s.pickerRgb().r);
    try std.testing.expectEqual(@as(u8, 0x80), s.pickerRgb().b);
    // editing 중이면 무시(hex 편집 버퍼 우선).
    _ = handle(.{ .key = .char, .codepoint = '#' }, &s); // editing=true
    s.setPickerRgb(.{ .r = 0x10, .g = 0x20, .b = 0x30 });
    try std.testing.expectEqual(@as(u8, 0xff), s.pickerRgb().r); // 안 바뀜(editing)
    // picking 아니면 무시.
    s.editing = false;
    s.picking = false;
    s.setPickerRgb(.{ .r = 0x10, .g = 0x20, .b = 0x30 });
    try std.testing.expectEqual(@as(u8, 0xff), s.pickerRgb().r); // 안 바뀜(not picking)
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
    try view(&s, no_sections, &rows2, no_items, test_props, &tk2, arena, &out2);
    var saw_search = false;
    for (out2.items) |op| if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "검색: fo") != null and op.text.role == .accent_bar) {
        saw_search = true;
    };
    try std.testing.expect(saw_search);
}

test "settings 검색 IME 조합(preedit): query 뒤에 조합 글자 표시 + caret은 query 끝(조합 덮음) (§6.8 macOS IME)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var s = State{};
    s.show();
    s.setFieldCount(1);
    s.startSearch();
    s.appendSearchCp('a'); // 확정 "a"
    s.setSearchPreedit("\xea\xb0\x80"); // 조합 중 "가"(3바이트 1코드포인트)
    try std.testing.expectEqualStrings("\xea\xb0\x80", s.searchPreedit());

    const rows = [_]FieldRow{.{ .label = "appearance", .kind = .{ .toggle = true } }};
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    // "검색: a"(확정) + "가"(조합) 두 text op이 accent로 뜬다.
    var saw_committed = false;
    var saw_preedit = false;
    for (out.items) |op| if (op == .text and op.text.role == .accent_bar) {
        if (std.mem.indexOf(u8, op.text.runs[0].text, "검색: a") != null) saw_committed = true;
        if (std.mem.eql(u8, op.text.runs[0].text, "\xea\xb0\x80")) saw_preedit = true;
    };
    try std.testing.expect(saw_committed);
    try std.testing.expect(saw_preedit);

    // caret은 "검색: a" 끝(=조합 시작)에 있어 조합 글자 "가"를 덮는다 — searchCaretRect가 preedit를 안 더한다.
    const cr = searchCaretRect(&s, no_sections, &rows, test_props, &tk).?;
    const l = computeLayout(no_sections, &rows, s.selected, test_props, &tk).?;
    const expect_cols = overlay_input.displayCols("검색: ") + overlay_input.displayCols("a");
    try std.testing.expectEqual(l.box.inner_x + @as(i32, @intCast(expect_cols * l.box.cw)), cr.x);

    // commitSearchPreedit: 조합을 query로 확정(query="a가", 조합 비움).
    try std.testing.expect(s.commitSearchPreedit());
    try std.testing.expectEqualStrings("a\xea\xb0\x80", s.searchQuery());
    try std.testing.expectEqual(@as(usize, 0), s.searchPreedit().len);
    try std.testing.expect(!s.commitSearchPreedit()); // 빈 조합이면 false

    // 검색 종료면 caret 없음(IME 후보창 폴백).
    s.endSearch();
    try std.testing.expect(searchCaretRect(&s, no_sections, &rows, test_props, &tk) == null);

    // 검색 중이 아니면(유휴/편집) 조합은 **검색 버퍼에 안 담긴다** — 안 보이는 검색어로 폼이 오염되던 회귀 가드
    // (code-review high). endSearch로 검색 종료(query·preedit 비움)된 상태에서 setSearchPreedit는 무시하고 비운다.
    try std.testing.expect(!s.searching);
    try std.testing.expectEqualStrings("", s.searchQuery()); // endSearch가 query 비움
    s.setSearchPreedit("\xeb\x82\x98"); // "나" — 검색 아님이라 드롭
    try std.testing.expectEqual(@as(usize, 0), s.searchPreedit().len);
    try std.testing.expect(!s.commitSearchPreedit()); // 확정할 조합 없음 → 검색 버퍼에 안 들어감
    try std.testing.expectEqualStrings("", s.searchQuery()); // 여전히 빔(조합이 query로 안 샘)

    // 조합이 preedit 버퍼(32B)를 넘겨도 UTF-8 코드포인트 경계로 잘라 손상 UTF-8을 안 남긴다(finding 2).
    s.startSearch();
    s.setSearchPreedit("\xea\xb0\x80" ** 20); // "가"×20 = 60B > 32B cap
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.searchPreedit())); // 멀티바이트 중간에서 안 잘림
    try std.testing.expect(s.searchPreedit().len <= 32);
}

test "settings 안내 배너(§6.9): message가 있으면 힌트 줄 대신 폼 상단에 얹힌다·정리로 사라짐" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var s = State{};
    s.show();
    s.setFieldCount(1);
    const rows = [_]FieldRow{.{ .label = "appearance", .kind = .{ .toggle = true } }};

    // 배너 없음: 힌트 "⇥ 섹션 ⇄ 설정"이 보인다.
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    var saw_hint = false;
    for (out.items) |op| if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "섹션") != null) {
        saw_hint = true;
    };
    try std.testing.expect(saw_hint);

    // 배너 설정: ⚠ 접두 + 메시지가 보이고 힌트는 안 보인다(같은 줄 대체).
    s.setMessage("이 키는 전역 단축키로 등록할 수 없습니다");
    try std.testing.expectEqualStrings("이 키는 전역 단축키로 등록할 수 없습니다", s.message());
    out.clearRetainingCapacity();
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    var saw_banner = false;
    var saw_hint2 = false;
    for (out.items) |op| if (op == .text) {
        if (std.mem.indexOf(u8, op.text.runs[0].text, "⚠") != null) saw_banner = true;
        if (std.mem.indexOf(u8, op.text.runs[0].text, "⇄") != null) saw_hint2 = true;
    };
    try std.testing.expect(saw_banner);
    try std.testing.expect(!saw_hint2); // 힌트 줄은 배너로 대체됨

    // 정리: clearMessage/섹션 전환/닫기가 배너를 없앤다.
    s.clearMessage();
    try std.testing.expectEqual(@as(usize, 0), s.message().len);
    s.setMessage("x");
    s.selectSection(1);
    try std.testing.expectEqual(@as(usize, 0), s.message().len);
    s.setMessage("x");
    s.hide();
    try std.testing.expectEqual(@as(usize, 0), s.message().len);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    var has_chord = false;
    for (out.items) |op| if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "⌘T")) {
        has_chord = true;
    };
    try std.testing.expect(has_chord);

    // 녹음 중(선택 행): "키 입력 대기..."를 accent로.
    out.clearRetainingCapacity();
    s.recording = true;
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    var has_prompt = false;
    for (out.items) |op| if (op == .text and std.mem.indexOf(u8, op.text.runs[0].text, "키 입력 대기") != null and op.text.role == .accent_bar) {
        has_prompt = true;
    };
    try std.testing.expect(has_prompt);
    s.recording = false;

    // handlePointer: control 영역 클릭 → .toggle(platform이 recording 켬).
    const l = computeLayout(no_sections, &rows, 0, test_props, &tk).?;
    const ctrl = fieldControlRect(l, 0);
    const act = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(ctrl.x + 2), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
    try std.testing.expectEqual(Action.toggle, act);

    // 녹음 중 다른 곳(라벨) 클릭 → 녹음 취소.
    s.recording = true;
    _ = handlePointer(.{ .phase = .down, .x_px = @floatFromInt(l.form_x + 1), .y_px = @floatFromInt(ctrl.y + 4) }, no_sections, &rows, no_items, test_props, &tk, &s);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
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
    try view(&s, no_sections, &rows, no_items, test_props, &tk, arena, &out);
    var has_buf = false;
    has_caret = false;
    for (out.items) |op| {
        if (op == .text and std.mem.eql(u8, op.text.runs[0].text, "Menlo")) has_buf = true;
        if (op == .fill and op.fill.role == .cursor) has_caret = true;
    }
    try std.testing.expect(has_buf and has_caret);
}

// SV5c — 세팅 폼 목록에 스크롤바가 생겼다. 팔레트와 달리 폼 폭이 nav·control·↺ 여백에 얽혀 있어,
// **뷰포트를 컴포넌트가 준다**(host가 다시 계산하면 두 벌이 갈린다). gutter도 폼 폭 계산 한 곳에서
// 빠지므로 control·↺ 위치가 자동으로 따라온다 — 팔레트에서 두 번 빠뜨렸던 그 흩어짐이 여기엔 없다.
test "settings reserves the scrollbar gutter once and reports a viewport for the host" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const gutter: u32 = 11;
    const base = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 1600,
        .backing_height_px = 600,
    } };
    var with_gutter = base;
    with_gutter.metrics.overlay_scroll_gutter_px = gutter;

    const sections = [_][]const u8{"일반"};
    var rows_buf: [80]FieldRow = undefined;
    for (&rows_buf, 0..) |*r, i| {
        _ = i;
        r.* = .{ .label = "옵션", .kind = .{ .toggle = false } };
    }
    const rows: []const FieldRow = &rows_buf;

    var s: State = .{};
    s.open = true;
    s.selected = 0;

    // ① gutter를 주면 control 열이 그만큼 **왼쪽으로** 물러난다 — 폼 폭 한 곳에서 뺐으니 소비처가 따라온다.
    const l_bare = computeLayout(&sections, rows, s.selected, base, &tk).?;
    const l_gut = computeLayout(&sections, rows, s.selected, with_gutter, &tk).?;
    try std.testing.expect(l_gut.form_cols < l_bare.form_cols);

    // ② 넘치면 host가 쓸 뷰포트를 준다. 창(win_start)은 selected에서 재파생된 값이라 상태가 아니다.
    const sv = scrollView(&s, &sections, rows, with_gutter, &tk) orelse return error.NoScrollView;
    try std.testing.expectEqual(rows.len, sv.total);
    try std.testing.expect(sv.visible > 0 and sv.visible < rows.len);
    try std.testing.expectEqual(@as(usize, 0), sv.win_start);
    try std.testing.expect(sv.viewport.w > 0 and sv.viewport.h > 0);

    // ③ 선택을 끝으로 옮기면 창이 따라간다(파생값의 증거).
    s.selected = rows.len - 1;
    const sv_end = scrollView(&s, &sections, rows, with_gutter, &tk).?;
    try std.testing.expect(sv_end.win_start > 0);

    // ④ 안 넘치면 막대가 없다 — 트랙만 남은 막대를 그리지 않는다.
    const few: []const FieldRow = rows[0..1];
    s.selected = 0;
    try std.testing.expect(scrollView(&s, &sections, few, with_gutter, &tk) == null);

    // ⑤ 닫혀 있으면 없다.
    s.open = false;
    try std.testing.expect(scrollView(&s, &sections, rows, with_gutter, &tk) == null);
}
