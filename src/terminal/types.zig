const std = @import("std");
const color = @import("../color.zig");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub const default: Size = .{ .cols = 80, .rows = 24 };
};

// Rgb는 terminal 전용 타입이 아니라 config/renderer도 쓰는 공용 색 primitive다.
// 단일 출처를 src/color.zig에 두고 여기서는 재노출만 한다. `terminal.Rgb`와 아래
// `Color` union은 그대로 동작한다.
pub const Rgb = color.Rgb;
// 같은 결로 색 해석 유틸도 재노출한다 — 코어가 OSC 4 팔레트 질의에서 기본 xterm256 색을 회신하고
// (xterm256), OSC 4/10/11 색 명세를 파싱한다(parseSpec). core.zig는 이미 `color`를 지역 변수명으로
// 써서 파일 레벨 import가 충돌하므로, `types.` 게이트웨이로 노출한다(Rgb와 동일).
pub const xterm256 = color.xterm256;
pub const parseSpec = color.parseSpec;

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    // SGR 2/22(faint/normal-intensity): 전경 intensity를 낮춘다. 베이스 ECMA-48 SGR 2(faint).
    // 렌더는 packForeground가 전경을 배경 쪽으로 0.5 보간한다(Ghostty faint-opacity 0.5 동작 비교 —
    // maru 전경색엔 alpha가 없어 alpha 0.5 over bg와 같은 효과를 RGB 보간으로 낸다). SGR 22가 함께 끈다.
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    // SGR 21(또는 4:2)=double underline. underline=true와 함께 켜지며, 렌더가 하단에 2중선(reserved=7)을 긋는다.
    // SGR 4(plain)·24가 false로 끈다. 베이스 ECMA-48 SGR 21(doubly underlined)·ITU T.416 4:2.
    underline_double: bool = false,
    // SGR 9/29(crossed-out/strikethrough): 셀 중앙을 가로지르는 선. 베이스 ECMA-48 SGR 9(crossed-out
    // characters)·xterm ctlseqs 동일. 렌더는 underline과 같은 부분-사각형(중앙 띠)을 재사용한다.
    strikethrough: bool = false,
    // SGR 53/55(overline): 셀 상단을 가로지르는 선. 베이스 ECMA-48 SGR 53(overlined)·xterm ctlseqs.
    // 렌더는 셀 상단의 가는 텍스트 장식선(reserved=10)을 사용한다(hollow cursor 상단 reserved=4와 분리).
    overline: bool = false,
    // SGR 7/27(reverse video): 렌더 시 전경/배경을 맞바꾼다(default 색은 theme 값으로 풀어 스왑).
    reverse: bool = false,
    // SGR 5/6/25(blink): 점멸 속성. 파싱·저장만 하고 렌더는 정적(애니메이션 미구현 — 프레임 루프 연동 후속).
    // DECRQSS 등 상태 round-trip·미래 애니메이션을 위해 비트는 보존한다. 베이스 ECMA-48 SGR 5(slow blink).
    blink: bool = false,
    // SGR 8/28(conceal/reveal): 숨김. 렌더 시 전경을 그 셀 배경색으로 풀어 글자를 안 보이게 한다(invisible).
    // 베이스 ECMA-48 SGR 8(concealed characters)·xterm ctlseqs. 비밀번호 프롬프트 등이 쓴다.
    conceal: bool = false,
    // SGR 58/59(underline color): 밑줄 색을 전경과 별개로 정한다(58;2;r;g;b·58;5;n, 59=default). nvim/helix가
    // LSP 진단을 색 밑줄로 표시. default면 전경색을 쓴다. 렌더는 underline overlay의 색으로 이 값을 푼다.
    underline_color: Color = .default,
};

pub const Cell = struct {
    // 0 = **아직 아무도 안 쓴 칸**(터미널이 만든 빈 칸 — init·erase·scroll·resize 패딩). 프로그램이
    // 실제로 쓴 공백(' ')과 구분해야 soft-wrap 이음에서 "없던 공백"이 안 생긴다: wrap 채움은 버리고
    // 쓴 공백은 지켜야 하는데, 둘을 같은 값으로 두면 어떤 읽는 쪽도 구분할 수 없다(§안 쓴 칸).
    // 화면·텍스트로 나갈 때는 공백으로 보인다(RowCodepoints·appendRowUtf8이 ' '로 푼다).
    codepoint: u21 = 0,
    style: Style = .{},
    width: u2 = 1,
    continuation: bool = false,
    // base(codepoint) 뒤에 붙는 grapheme cluster 본체(악센트·VS16·NFD 한글 V/T·키캡·ZWJ 시퀀스).
    // grapheme_id(0=없음)가 TerminalCore.grapheme_store의 코드포인트 배열을 가리킨다 — link/link_store와
    // 동형(셀엔 id만, 본체는 store에). extra가 1개든 N개든 전부 여기로(pure-B, 단일 출처) — 긴 cluster도
    // 무손실. (단일 extra가 반복돼 누적되면 회수/dedup은 측정 후 후속, 설계 §5 HG3b.)
    grapheme_id: u32 = 0,
    // OSC 8 하이퍼링크 id(0=없음). URI 자체는 TerminalCore.link_store에 한 번만 저장하고
    // 셀은 id만 든다 — 링크가 걸린 긴 출력에서도 셀 메모리가 URI 길이에 비례하지 않는다.
    link: u32 = 0,
};

/// **글자가 없는 칸인가** — 터미널이 만든 빈 칸(codepoint 0)이다. 프로그램이 쓴 공백(' ')은 여기 안 든다.
/// 배경색은 보지 않는다: 텍스트를 뽑는 자리에서 배경은 글자가 아니다. BCE로 배경을 칠해 둔 화면에서도
/// wrap 채움은 채움이라, 배경을 보면 유령 공백이 되살아난다(적대적 검증 2라운드에서 재서 찾았다).
pub fn hasNoText(cell: Cell) bool {
    return cell.codepoint == 0 and !cell.continuation and cell.grapheme_id == 0;
}

/// **아무도 안 쓰지도, 칠하지도 않은 칸인가** — `hasNoText`에 "배경도 default"를 더한 것.
/// 화면 저장·reflow처럼 **눈에 보이는 것을 잃으면 안 되는** 자리가 쓴다(칠해진 칸은 버리면 색이 사라진다).
pub fn isUnwritten(cell: Cell) bool {
    return hasNoText(cell) and std.meta.activeTag(cell.style.background) == .default;
}

/// 텍스트 추출/reflow가 뒤 padding을 자를 때 쓰는 blank-cell 단일 출처. 배경색·continuation·grapheme가 있으면
/// 화면상 의미가 있으므로 단순 U+0020이어도 보존한다.
/// **hard 줄끝**에서는 쓴 공백도 잘라낸다(복사에 줄끝 공백이 안 딸려가게) — 그래서 안 쓴 칸(0)과 쓴 공백을
/// 여기서는 함께 본다. 둘을 갈라야 하는 자리는 위 `isUnwritten`을 쓴다.
pub fn isTextTrimBlank(cell: Cell) bool {
    return (cell.codepoint == ' ' or cell.codepoint == 0) and
        !cell.continuation and
        cell.grapheme_id == 0 and
        std.meta.activeTag(cell.style.background) == .default;
}

/// 행의 텍스트 의미를 보존하면서 뒤 기본 blank padding만 제외한 길이.
pub fn textTrimmedLen(cells: []const Cell) usize {
    var len = cells.len;
    while (len > 0) : (len -= 1) {
        if (!isTextTrimBlank(cells[len - 1])) break;
    }
    return len;
}

/// **글자가 있는 마지막 칸까지**의 길이 — 뒤에 붙은 "글자 없는 칸"만 제외한다. 쓴 공백은 남는다.
/// soft-wrap 행이 **텍스트**(복사·검색)에 기여하는 길이다: wrap 이음은 논리 줄 가운데라 쓴 공백을
/// 지워선 안 되고, 반대로 wrap 채움은 글자가 아니므로 이어 붙이면 없던 공백이 된다.
/// hard 줄끝은 `textTrimmedLen`(쓴 공백도 자름)을 쓴다 — 거기선 뒤 공백이 진짜 뒤 공백이다.
pub fn textLen(cells: []const Cell) usize {
    var len = cells.len;
    while (len > 0) : (len -= 1) {
        if (!hasNoText(cells[len - 1])) break;
    }
    return len;
}

/// **글자든 배경이든 있는 마지막 칸까지**의 길이. 화면 저장·reflow가 쓴다 — 텍스트만 보고 자르면
/// BCE로 칠해 둔 칸의 색이 사라진다. 텍스트 경로는 위 `textLen`을 쓴다(둘의 차이가 곧 "칠했지만
/// 글자는 없는 칸"이고, 그 칸은 눈엔 보이되 복사엔 안 들어가야 한다).
pub fn paintedLen(cells: []const Cell) usize {
    var len = cells.len;
    while (len > 0) : (len -= 1) {
        if (!isUnwritten(cells[len - 1])) break;
    }
    return len;
}

/// OSC 133 semantic prompt — 셸이 알려주는 한 행의 의미 분류. 터미널은 raw 바이트만 봐선
/// 프롬프트/입력/출력을 구분 못 하므로, 셸 통합이 `OSC 133 ; A|B|C|D`로 경계를 마킹한다.
/// 행 단위로 보관(`wrapped`와 같은 병렬 배열 패턴)해, 이후 단계가 거터 마크(✓/✗)·프롬프트
/// 점프·출력 선택·reflow 정확화에 쓴다. 명세: freedesktop semantic-prompts.md(FinalTerm 발).
/// 주의: `wrapped`와 달리 glyph 쓰기(putCell)로 리셋되지 않는다 — 셸이 프롬프트를 다시 그려도
/// 그 행의 분류는 유지돼야 하기 때문이다.
pub const SemanticPrompt = enum(u8) {
    unknown, // OSC 133 분류 없음(모든 행 기본값)
    prompt, // A(또는 P)~B 사이 — 프롬프트 텍스트 자체
    input, // B~C 사이 — 사용자가 친 명령줄
    command, // C~D 사이 — 실행 중인 명령의 출력
};

/// 한 행의 OSC 133 정보(분류 + 그 프롬프트에서 실행된 명령의 종료코드). 종료코드는 프롬프트
/// 시작 행에만 `D;<code>`로 기록되고 나머지 행은 null이다. 분류와 한 묶음이라, 스크롤/reflow
/// carry가 둘을 함께 옮긴다(별도 배열을 안 들어도 됨). 거터 ✓/✗ 색(성공=초록/실패=빨강)에 쓴다.
pub const RowPrompt = struct {
    kind: SemanticPrompt = .unknown,
    exit: ?i16 = null, // 그 프롬프트의 명령 종료코드(프롬프트 시작 행에만; shell은 음수도 보냄)
};

/// 셸 통합(OSC 133/7)이 알린 의미 이벤트 — 명령 라이프사이클의 경계를 시간순으로 표시한다.
/// 같은 도메인 데이터를 디버그 로그·테스트·(후속) trace 직렬화/replay가 공유한다(관측 가능성
/// 원칙: 임시 포맷을 따로 두지 않는다). core가 OSC를 파싱하며 순서대로 기록하고 소비자가 drain한다.
///
/// 설계: POD다(소유 문자열 없음) — 행 인덱스는 이벤트 발생 시점의 활성 화면 커서 행이고, 종료코드는
/// OSC 133 D의 값이다. `cwd_changed`는 '경계만' 표시하고 cwd 값 자체는 `TerminalCore.currentCwd()`가
/// 권위다(trace는 순서가 정답이라 절대 좌표/문자열을 이벤트가 들 필요가 없고, 소유권도 단순해진다).
pub const ShellEvent = union(enum) {
    prompt_start: u16, // OSC 133 A — 프롬프트 시작(행)
    input_start: u16, // OSC 133 B — 입력 시작(행)
    command_start: u16, // OSC 133 C — 출력 시작(행)
    command_end: CommandEnd, // OSC 133 D — 명령 끝(행 + 종료코드, code 없으면 null)
    cwd_changed: void, // OSC 7 — cwd 변경(값은 currentCwd()가 권위)

    pub const CommandEnd = struct {
        row: u16,
        exit: ?i16,
    };
};

/// Iterates the visible codepoints of a single row: each non-continuation
/// cell yields its base codepoint, immediately followed by the rest of its
/// grapheme cluster (the extra codepoints — NFD jamo, combining marks, ZWJ
/// sequences). Both the plain-text dump (`TerminalCore.dumpUtf8`) and the
/// snapshot row rendering consume this, so the rule for which cells actually
/// show on screen (skip continuations, append the cluster body) lives in
/// exactly one place instead of being re-derived per consumer — and stays
/// lossless (clipboard/re-output get every codepoint, not just the first).
///
/// `graphemes` is `TerminalCore.grapheme_store.items` (id-1 indexed) — the
/// single source for every cell's extra codepoints. A cell with `grapheme_id`
/// 0 has no extras (just its base). Callers that consume row text MUST pass
/// `graphemes`, else cluster bodies are dropped.
pub const RowCodepoints = struct {
    cells: []const Cell,
    graphemes: []const []const u21 = &.{},
    col: usize = 0,
    pending: []const u21 = &.{}, // grapheme_id store 슬라이스의 아직 안 내보낸 꼬리

    pub fn next(self: *RowCodepoints) ?u21 {
        if (self.pending.len > 0) {
            const cp = self.pending[0];
            self.pending = self.pending[1..];
            return cp;
        }
        while (self.col < self.cells.len) {
            const cell = self.cells[self.col];
            self.col += 1;
            if (cell.continuation) continue;
            // store가 cluster 본체의 단일 출처 — id가 있으면 base 뒤에 그 전체를 내보낸다.
            if (cell.grapheme_id != 0 and cell.grapheme_id <= self.graphemes.len) {
                self.pending = self.graphemes[cell.grapheme_id - 1];
            }
            // 안 쓴 칸은 화면·텍스트에서 공백으로 보인다(값 0은 내부 표현일 뿐).
            return if (cell.codepoint == 0) ' ' else cell.codepoint;
        }
        return null;
    }
};

/// 선택의 한 끝점. row는 "절대 행"(스크롤백 0..sb_count-1, 이어서 활성 화면 행) — 스크롤해도
/// 선택이 내용을 따라가게 하는 좌표계다.
pub const SelectionPoint = struct {
    row: usize,
    col: u16,
};

/// 뷰포트 좌표로 클립된 선택 범위(렌더용). [start, end]는 포함 범위다. block=false면 선형(행 단위
/// 이어짐 — 첫/끝 행만 col 제한, 중간 행은 전폭), block=true면 직사각형([start.col,end.col]을 모든 행에
/// 적용 — Option+드래그). search_match·hover_link 등은 항상 선형(block=false 기본).
pub const SelectionSpan = struct {
    start: struct { row: u16, col: u16 },
    end: struct { row: u16, col: u16 },
    block: bool = false,
};

/// 스크롤백 Find 매치 한 건의 절대-행 [start, end] 포함 범위. SelectionPoint와 같은 절대 좌표계라
/// 스크롤·eviction과 무관하게 내용을 가리키고, 렌더 시 clipAbsSpanToViewport로 뷰포트 span으로 클립한다.
/// 한 매치는 soft-wrap 경계를 넘어 여러 행에 걸칠 수 있다(논리 줄 단위 검색).
pub const Match = struct {
    start: SelectionPoint,
    end: SelectionPoint,
};

/// DECSCUSR(CSI Ps SP q)의 커서 모양. blink 여부는 별도 플래그로 추적한다.
pub const CursorShape = enum { block, underline, bar };

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16,
    end_row: u16,
};

/// kitty graphics 이미지 한 장의 렌더용 뷰(픽셀 버퍼를 빌려 노출 — zero-copy). 렌더러(K2d)가
/// image_id로 GPU 텍스처를 캐시하고 `generation`이 바뀔 때만 업로드한다(매 frame 픽셀 전송 X).
/// `bpp`=3(RGB)/4(RGBA). 베이스: kitty graphics protocol image storage.
pub const KittyImageView = struct {
    image_id: u32,
    width: u32,
    height: u32,
    bpp: u8,
    generation: u64, // (재)transmit마다 단조 증가 — 렌더러 업로드 캐시 무효화 키(세션 내 단조)
    pixels: []const u8,
};

/// kitty graphics placement — 화면에 표시 중인 이미지 인스턴스 하나(렌더용 뷰). 한 이미지(image_id)에
/// placement_id로 구분되는 여러 placement가 있을 수 있다. 좌표는 뷰포트 상대 — row는 placement가 앵커된
/// 셀의 뷰포트 행(top 기준 오프셋, i32라 위로 스크롤돼 화면 위로 벗어난 앵커는 음수). 셀 단위 크기(span)는
/// 코어가 셀 픽셀 크기를 모르므로 계산하지 않는다: source rect(픽셀)와 명시 columns/rows만 담고, 픽셀→셀
/// 환산·클립은 셀 메트릭을 가진 렌더러가 한다. 키 의미의 단일 출처는 kitty.zig의 KittyGraphicsCommand
/// 주석이다. 베이스: kitty graphics protocol(placement/display).
pub const KittyPlacement = struct {
    image_id: u32,
    placement_id: u32, // p: 0이면 default placement
    row: i32, // 앵커 셀의 뷰포트 행(top 기준 오프셋). 음수면 앵커가 화면 위로 벗어남.
    col: u16, // 앵커 셀의 열.
    cell_x_offset: u32 = 0, // X: 첫 셀 안에서 이미지를 그리기 시작할 픽셀 오프셋.
    cell_y_offset: u32 = 0, // Y
    src_x: u32 = 0, // x: 표시할 source 사각형의 좌상단(이미지 픽셀 좌표).
    src_y: u32 = 0, // y
    src_width: u32 = 0, // w: source 사각형 폭(픽셀, 0=전체).
    src_height: u32 = 0, // h: source 사각형 높이(픽셀, 0=전체).
    columns: u32 = 0, // c: 표시할 열 수(0=렌더러가 환산).
    rows: u32 = 0, // r: 표시할 행 수(0=렌더러가 환산).
    z: i32 = 0, // z-index(<0 텍스트 뒤, >=0 텍스트 앞).
};

/// kitty 이미지 placement의 source crop(UV용)과 목적지 픽셀 크기(quad/커서 advance용). buildGpuImages
/// (렌더러)와 kittyDisplay의 자동 크기 커서 advance(코어)가 **같은 환산식**을 쓰도록 단일 출처로 둔다 —
/// 어긋나면 화면에 그려진 이미지 행 수와 커서가 내려간 행 수가 달라진다.
pub const PlacementGeometry = struct {
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    dest_w: f32,
    dest_h: f32,

    /// 이미지 픽셀 크기·placement의 src crop/columns/rows·셀 메트릭으로 source 사각형과 목적지 픽셀 크기를
    /// 정한다. columns/rows가 둘 다면 셀수×셀크기, 한쪽만이면 종횡비 유지, 둘 다 0이면 source 픽셀(자동 크기).
    /// crop이 비거나(잘린 영역 0) src 원점이 이미지 밖이면 null(그릴 게 없음). 베이스: kitty graphics protocol
    /// display data(c/r/x/y/w/h). 단일 출처: 코어 커서 advance와 렌더러 dest가 이 함수를 공유한다.
    pub fn compute(
        img_width: u32,
        img_height: u32,
        src_x: u32,
        src_y: u32,
        src_width: u32,
        src_height: u32,
        columns: u32,
        rows: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    ) ?PlacementGeometry {
        if (src_x >= img_width or src_y >= img_height) return null;
        const max_sw = img_width - src_x;
        const max_sh = img_height - src_y;
        const sw = if (src_width == 0) max_sw else @min(src_width, max_sw);
        const sh = if (src_height == 0) max_sh else @min(src_height, max_sh);
        if (sw == 0 or sh == 0) return null;

        const cw: f32 = @floatFromInt(cell_width_px);
        const ch: f32 = @floatFromInt(cell_height_px);
        const sw_f: f32 = @floatFromInt(sw);
        const sh_f: f32 = @floatFromInt(sh);
        var dest_w = sw_f;
        var dest_h = sh_f;
        if (columns > 0 and rows > 0) {
            dest_w = @as(f32, @floatFromInt(columns)) * cw;
            dest_h = @as(f32, @floatFromInt(rows)) * ch;
        } else if (columns > 0) {
            dest_w = @as(f32, @floatFromInt(columns)) * cw;
            dest_h = if (sw_f > 0) sh_f * (dest_w / sw_f) else sh_f;
        } else if (rows > 0) {
            dest_h = @as(f32, @floatFromInt(rows)) * ch;
            dest_w = if (sh_f > 0) sw_f * (dest_h / sh_f) else sw_f;
        }
        return .{ .src_x = src_x, .src_y = src_y, .src_w = sw, .src_h = sh, .dest_w = dest_w, .dest_h = dest_h };
    }
};

/// 링크 종류 — platform(Swift)이 여는 방식을 가른다: url=URL(string:), file_path=URL(fileURLWithPath:).
pub const LinkKind = enum { url, file_path };

/// 어떤 종류를 자동 감지할지(각 비트 독립). app_session이 config `input.link-detection`에서 채워 매 호출
/// 넘긴다 — 코어는 토글 상태를 안 든다(word_separators 주입과 동형, reload-safe). OSC 8 명시 링크는 이 토글과
/// 무관하게 항상 우선이다(호출자가 cellLinkAt로 먼저 처리).
pub const LinkScopes = struct {
    web: bool = false, // http:// https://
    extra_schemes: bool = false, // file:// mailto: ssh:// ftp:// git:// tel: news: magnet:
    absolute_path: bool = false, // /Users/x/a.zig
    home_path: bool = false, // ~/.config
    dot_relative: bool = false, // ./src ../lib
    bare_relative: bool = false, // src/foo.zig (슬래시+점)
};

/// config 프리셋(osc8-only / web / full)과 1:1. osc8-only는 자동 감지를 끈다(OSC 8만).
pub const link_scopes_none: LinkScopes = .{};
pub const link_scopes_web: LinkScopes = .{ .web = true };
pub const link_scopes_full: LinkScopes = .{ .web = true, .extra_schemes = true, .absolute_path = true, .home_path = true, .dot_relative = true, .bare_relative = true };

/// 링크를 만들어낸 감지 종류. `LinkScopes`의 각 비트와 1:1이고 `osc8`(명시 하이퍼링크)만 추가다 — OSC 8은 scope
/// 토글과 무관하게 항상 링크이므로 별도 값을 둔다. 원격(host-backed) 경로에서 host가 **client config를 모른 채
/// 최대 집합으로 계산**하고 span마다 이 값을 실어 보내면, client가 자기 `input.link-detection`으로 거를 수 있다
/// (docs/link-detection.md §원격(host-backed) 세션 — "host 해석 / client 정책" 분리). 로컬 경로는 이 값을 쓰지 않는다.
/// wire 인코딩은 이 enum의 `@intFromEnum`을 **비트 위치**로 쓴다(docs/persistent-session-host.md §12 `link_spans`).
pub const LinkScope = enum(u8) {
    web = 0,
    extra_schemes = 1,
    absolute_path = 2,
    home_path = 3,
    dot_relative = 4,
    bare_relative = 5,
    osc8 = 6,

    /// 이 종류가 주어진 scope 토글로 켜져 있는가. `osc8`은 토글과 무관하게 항상 참이다(OSC 8 우선 규칙).
    pub fn enabledIn(self: LinkScope, scopes: LinkScopes) bool {
        return switch (self) {
            .web => scopes.web,
            .extra_schemes => scopes.extra_schemes,
            .absolute_path => scopes.absolute_path,
            .home_path => scopes.home_path,
            .dot_relative => scopes.dot_relative,
            .bare_relative => scopes.bare_relative,
            .osc8 => true,
        };
    }
};

/// 뷰포트에서 보이는 링크 하나 — 밑줄 범위(뷰포트 상대) + 종류 + 그 매치를 만든 감지 종류.
/// `collectViewportLinks`가 채우고, 원격 경로에서 host가 wire로 실어 client의 hover 판정 입력이 된다.
pub const ViewportLink = struct { span: SelectionSpan, kind: LinkKind, scope: LinkScope };

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    // true면 현재 cells는 live bottom이 아니라 스크롤백 뷰포트다. IME preedit처럼 live cursor에
    // 앵커되는 client-local projection은 이 상태에서 합성하지 않고 먼저 scroll-to-bottom을 요청한다.
    viewport_scrolled: bool = false,
    // false면 연결된 구 host가 viewport_scrolled 의미론을 협상하지 않은 상태다. 이때 false 값을
    // "live bottom"으로 해석하면 구 host의 hidden (0,0) cursor에 client-local overlay를 잘못 그릴 수
    // 있으므로, cursor에 앵커되는 projection은 fail-closed해야 한다.
    viewport_scrolled_known: bool = true,
    // base grid가 사용한 EAW ambiguous-width 정책. client-local projection도 이 값을 소비해
    // host/local canonical grid와 조합문자의 셀 폭이 갈리지 않게 한다.
    ambiguous_wide: bool = false,
    // DECSCUSR가 정한 커서 모양/깜빡임. 렌더러가 block(반전)/underline(하단 바)/bar(좌측 바)로
    // 투영한다. blink는 추적만 하고 깜빡임 타이머는 아직 렌더하지 않는다.
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    cells: []const Cell = &.{},
    // grapheme cluster 본체 store(TerminalCore.grapheme_store.items, id-1 인덱싱) — cells의
    // grapheme_id가 가리킨다. zero-copy(코어 store 슬라이스를 빌려줌). 비어 있으면 cluster 셀이
    // 없다(일반 경로). 직렬화(dumpUtf8·snapshot.zig)·후속 렌더(HG3)가 RowCodepoints로 이걸 풀어
    // 다중 코드포인트를 무손실로 본다. (첫 extra 1개만 담던 옛 `combining` 필드는 이 store로 대체·제거됐다.)
    graphemes: []const []const u21 = &.{},
    // 행별 OSC 133 정보(분류 + 종료코드, 길이=size.rows, cells와 같은 행 인덱싱). 스크롤된
    // 뷰포트에서도 보이는 행에 맞춰 합성된다. 마킹이 없으면 전부 {.unknown, null}이라 렌더러는
    // 무시해도 된다. 거터(✓/✗)는 prompt 시작 행의 exit로 색을 정한다.
    prompt_marks: []const RowPrompt = &.{},
    // 뷰포트에서 보이는 링크(자동 감지 + OSC 8) — **원격(host-backed) 화면 소스에서만 채워진다**. 로컬 in-process
    // 화면은 client가 자기 core를 직접 분류하므로(hover 시점 계산) 항상 빈 슬라이스이고, 이 필드를 읽지 않는다.
    // 원격은 client core가 빈 placeholder라 스스로 감지할 수 없어, host가 해석한 결과를 이 중립 DTO에 실어 보낸다
    // (docs/link-detection.md §원격(host-backed) 세션). 소스 메모리를 alias하므로 lock 안에서 읽고 복사해야 한다.
    links: []const ViewportLink = &.{},
    // 스크롤바가 thumb 크기·위치를 계산하는 데 쓰는 스크롤 상태. 로컬/원격 **양쪽이 채워** 소비자가 화면
    // 소유자를 몰라도 되게 한다(host-backed면 client core가 빈 placeholder라 거기서 읽으면 항상 0이고,
    // 그래서 원격 세션에 스크롤바가 안 뜬다). `scrollback_len`=스크롤백 행 수, `view_offset`=바닥에서 위로
    // 올라간 행 수(0=바닥).
    scrollback_len: usize = 0,
    view_offset: usize = 0,
    // 가장 최근에 끝난 명령의 종료코드(OSC 133 ; D ; <code>). 없으면 null. shell이 음수(-1 등)를
    // 보낼 수 있어 i32. **주의: 거터는 이 값이 아니라 `prompt_marks[행].exit`(행별)로 그린다** —
    // 이건 MARU_DEBUG 덤프 헤더용 편의 값이라 거터/UI를 여기에 연결하지 말 것.
    last_command_exit: ?i32 = null,
    // kitty graphics placement(표시 중인 이미지 인스턴스)의 뷰포트 뷰. 비어 있으면 표시할 이미지가
    // 없다(일반 경로 — 할당 없음). 렌더러가 image_id로 픽셀을 찾아 source rect/오프셋/span으로 그린다 —
    // 픽셀→셀 환산·클립은 렌더러 책임(코어는 셀 픽셀 크기를 모름). 좌표는 뷰포트 상대(row는 i32라 화면
    // 위로 벗어난 앵커도 노출 — 셀 span을 아는 렌더러가 가시성/클립을 정한다). 렌더는 후속 K-단계.
    placements: []const KittyPlacement = &.{},
    // kitty graphics 이미지(transmit된 픽셀)의 렌더용 뷰. 비어 있으면 이미지 없음(일반 경로 — 할당
    // 없음). 렌더러가 `placements`의 image_id로 여기서 픽셀을 찾아 GPU 텍스처를 캐시하고, `generation`이
    // 바뀔 때만 업로드한다(이미지당 개별 텍스처·upload-once). 매 frame 픽셀 복사 없이 storage 버퍼를
    // zero-copy로 빌려준다.
    images: []const KittyImageView = &.{},
    dirty: ?DirtyRegion = null,
};
