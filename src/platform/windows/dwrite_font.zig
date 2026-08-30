//! DirectWrite 글리프 래스터라이저 — W7.3.
//!
//! **이 파일은 "코드포인트 하나를 픽셀로 만드는 것"만 안다.** 아틀라스 슬롯 배치·캐시·eviction은
//! `renderer/glyph_atlas.zig`가, 그 픽셀을 GPU에 올리는 것은 `d3d11_cells.zig`가 한다. 여기가 채우는 것은
//! 중립 계약이 요구하는 **RGBA8 버퍼 하나**다 — RGB는 흰색, 커버리지는 알파(`renderer/glyph_pixels.zig`와
//! 같은 규약).
//!
//! ## 합성 글리프는 여기까지 오지 않는다
//!
//! box-drawing·block·braille·powerline은 `renderer.synthesizeGlyph`가 코드포인트에서 직접 만든다(중립·
//! 모든 타깃). 폰트로 그리면 셀에 안 맞아 이음매가 생기기 때문이다. 그래서 이 파일은 **그 집합에 없는
//! 글자만** 받는다 — 호출자가 `synthesizeGlyph(...) orelse <이 경로>` 순서를 지킨다(그것이 중립 계약이
//! 정한 dispatch 순서다).
//!
//! ## 회색 안티앨리어싱은 ClearType 텍스처를 평균해서 얻는다
//!
//! DirectWrite의 `IDWriteGlyphRunAnalysis`가 주는 알파 텍스처는 두 종류다 — `ALIASED_1x1`(1바이트/픽셀,
//! **안티앨리어싱 없음**)과 `CLEARTYPE_3x1`(3바이트/픽셀, RGB 서브픽셀). 터미널에 계단은 쓸 수 없고, 서브픽셀
//! 렌더링은 우리 아틀라스가 채널 하나(알파)만 쓰므로 그대로 못 쓴다. 그래서 **3바이트를 평균해 회색
//! 커버리지로 만든다** — 널리 쓰이는 방법이고, 우리 셰이더가 원하는 값과 정확히 같은 의미다.
//!
//! 대가: ClearType 분석은 RGB 스트라이프를 가정해 튜닝돼 있어 평균값이 "진짜 회색 AA"와 완전히 같지는
//! 않다. 실측으로 화면을 보고 판정한다(추측하지 않는다).

const std = @import("std");
const abi = @import("abi.zig"); // Win32 호출 규약 단일 출처(다른 타깃에서는 `.c`로 접는다)
const builtin = @import("builtin");
const d3d11 = @import("d3d11.zig");
// **배럴로 가져온다.** `maru.zig` 는 이 파일을 내보내지 않으므로 순환이 아니고(형제 `win32_keys.zig`·
// `win32_terminal.zig` 도 같다), 상대 경로로 `../../` 를 타면 이 파일이 모듈 루트가 되는 순간 깨진다
// (`win32_process.zig` 가 실제로 그렇게 깨져 있었다 — docs/windows-platform.md §2m.8).
// **상대 경로다.** 이 파일은 배럴(`maru.zig`)이 내보내므로 `@import("maru")` 로는 자기 모듈을
// 못 부른다("no module named 'maru' within module 'maru'"). 같은 모듈의 루트 파일이라 안전하다.
const maru = @import("../../maru.zig");

pub const Error = error{
    UnsupportedPlatform,
    FactoryMissing,
    CreateFactoryFailed,
    NoFontFound,
    FontFaceFailed,
    MetricsFailed,
    AnalysisFailed,
    TextureFailed,
    BufferTooSmall,
    OutOfMemory,
};

pub var last_hresult: i32 = 0;

fn check(hr: d3d11.HRESULT, err: Error) Error!void {
    if (d3d11.failed(hr)) {
        last_hresult = hr;
        return err;
    }
}

// ── COM 표면 (필요한 슬롯만, 규약은 계약 §2c) ────────────────────────────────────────────────

const HRESULT = d3d11.HRESULT;
const UINT = d3d11.UINT;
const BOOL = d3d11.BOOL;

/// `IID_IDWriteFactory` — `{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}`. 틀리면 `DWriteCreateFactory`가
/// `E_NOINTERFACE`를 돌려주므로 런타임에 즉시 드러난다.
const IID_IDWriteFactory = d3d11.GUID{
    .data1 = 0xb859ee5a,
    .data2 = 0xd838,
    .data3 = 0x4b5b,
    .data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

const IDWriteFontCollection = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetFontFamilyCount: *const anyopaque,
        GetFontFamily: *const fn (*IDWriteFontCollection, UINT, *?*IDWriteFontFamily) callconv(abi.winapi) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const u16, *UINT, *BOOL) callconv(abi.winapi) HRESULT,
    };
};

const IDWriteFontFamily = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // IDWriteFontList
        GetFontCollection: *const anyopaque,
        GetFontCount: *const fn (*IDWriteFontFamily) callconv(abi.winapi) UINT,
        GetFont: *const fn (*IDWriteFontFamily, UINT, *?*IDWriteFont) callconv(abi.winapi) HRESULT,
        // IDWriteFontFamily
        GetFamilyNames: *const anyopaque,
        GetFirstMatchingFont: *const fn (*IDWriteFontFamily, UINT, UINT, UINT, *?*IDWriteFont) callconv(abi.winapi) HRESULT,
    };
};

const IDWriteFont = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetFontFamily: *const anyopaque,
        GetWeight: *const anyopaque,
        GetStretch: *const anyopaque,
        GetStyle: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetFaceNames: *const anyopaque,
        GetInformationalStrings: *const anyopaque,
        GetSimulations: *const anyopaque,
        GetMetrics: *const anyopaque,
        HasCharacter: *const anyopaque,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(abi.winapi) HRESULT,
    };
};

const IDWriteFontFace = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetType: *const anyopaque,
        GetFiles: *const anyopaque,
        GetIndex: *const anyopaque,
        GetSimulations: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetMetrics: *const fn (*IDWriteFontFace, *FontMetrics) callconv(abi.winapi) void,
        GetGlyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const fn (*IDWriteFontFace, [*]const u16, UINT, [*]GlyphMetrics, BOOL) callconv(abi.winapi) HRESULT,
        GetGlyphIndices: *const fn (*IDWriteFontFace, [*]const u32, UINT, [*]u16) callconv(abi.winapi) HRESULT,
        /// 슬롯 12. OpenType 테이블 하나를 **빌려 온다**. 성공하면 `ctx` 를 `ReleaseFontTable` 로
        /// 돌려줘야 한다 — 안 그러면 face 가 그 메모리를 붙들고 있는다.
        TryGetFontTable: *const fn (*IDWriteFontFace, UINT, *?*const anyopaque, *UINT, *?*anyopaque, *BOOL) callconv(abi.winapi) HRESULT,
        ReleaseFontTable: *const fn (*IDWriteFontFace, *anyopaque) callconv(abi.winapi) void,
    };
};

const IDWriteGlyphRunAnalysis = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetAlphaTextureBounds: *const fn (*IDWriteGlyphRunAnalysis, UINT, *Rect) callconv(abi.winapi) HRESULT,
        CreateAlphaTexture: *const fn (*IDWriteGlyphRunAnalysis, UINT, *const Rect, [*]u8, UINT) callconv(abi.winapi) HRESULT,
    };
};

const IDWriteFactory = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(abi.winapi) HRESULT,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        /// 슬롯 7. **파일 경로 하나를 폰트 파일 참조로** 만든다 — 컬렉션도 로더 COM 객체도 필요 없다.
        /// 번들 폰트를 여는 길이 이것이다(§2e).
        CreateFontFileReference: *const fn (*IDWriteFactory, [*:0]const u16, ?*const anyopaque, *?*anyopaque) callconv(abi.winapi) HRESULT,
        CreateCustomFontFileReference: *const anyopaque,
        /// 슬롯 9. 파일 참조 배열에서 face 를 만든다.
        CreateFontFace: *const fn (*IDWriteFactory, UINT, UINT, [*]const ?*anyopaque, UINT, UINT, *?*IDWriteFontFace) callconv(abi.winapi) HRESULT,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const anyopaque,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const fn (
            *IDWriteFactory,
            *const GlyphRun,
            f32, // pixelsPerDip
            ?*const anyopaque, // DWRITE_MATRIX
            UINT, // rendering mode
            UINT, // measuring mode
            f32, // baselineOriginX
            f32, // baselineOriginY
            *?*IDWriteGlyphRunAnalysis,
        ) callconv(abi.winapi) HRESULT,
    };
};

comptime {
    if (@sizeOf(usize) == 8) {
        const slot = struct {
            fn at(comptime T: type, comptime name: []const u8) usize {
                return @offsetOf(T, name) / 8;
            }
        };
        std.debug.assert(slot.at(IDWriteFactory.VTable, "GetSystemFontCollection") == 3);
        std.debug.assert(slot.at(IDWriteFactory3.VTable, "CreateFontSetBuilder") == 36);
        std.debug.assert(slot.at(IDWriteFactory3.VTable, "CreateFontCollectionFromFontSet") == 37);
        std.debug.assert(slot.at(IDWriteFontSetBuilder.VTable, "CreateFontSet") == 6);
        std.debug.assert(slot.at(IDWriteFontSetBuilder.VTable, "AddFontFile") == 7);
        std.debug.assert(slot.at(IDWriteFactory.VTable, "CreateFontFileReference") == 7);
        std.debug.assert(slot.at(IDWriteFactory.VTable, "CreateFontFace") == 9);
        std.debug.assert(slot.at(IDWriteFactory.VTable, "CreateGlyphRunAnalysis") == 23);
        std.debug.assert(slot.at(IDWriteFontCollection.VTable, "GetFontFamily") == 4);
        std.debug.assert(slot.at(IDWriteFontCollection.VTable, "FindFamilyName") == 5);
        std.debug.assert(slot.at(IDWriteFontFamily.VTable, "GetFirstMatchingFont") == 7);
        std.debug.assert(slot.at(IDWriteFont.VTable, "CreateFontFace") == 13);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "GetMetrics") == 8);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "GetDesignGlyphMetrics") == 10);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "GetGlyphIndices") == 11);
        std.debug.assert(slot.at(IDWriteGlyphRunAnalysis.VTable, "GetAlphaTextureBounds") == 3);
        std.debug.assert(slot.at(IDWriteGlyphRunAnalysis.VTable, "CreateAlphaTexture") == 4);
    }
}

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// `DWRITE_FONT_METRICS`. **디자인 단위**다 — 픽셀로 바꾸려면 `em_size / design_units_per_em`을 곱한다.
const FontMetrics = extern struct {
    design_units_per_em: u16,
    ascent: u16,
    descent: u16,
    line_gap: i16,
    cap_height: u16,
    x_height: u16,
    underline_position: i16,
    underline_thickness: u16,
    strikethrough_position: i16,
    strikethrough_thickness: u16,
};

/// `DWRITE_GLYPH_METRICS`. 역시 디자인 단위다.
const GlyphMetrics = extern struct {
    left_side_bearing: i32,
    advance_width: u32,
    right_side_bearing: i32,
    top_side_bearing: i32,
    advance_height: u32,
    bottom_side_bearing: i32,
    vertical_origin_y: i32,
};

const GlyphRun = extern struct {
    font_face: *IDWriteFontFace,
    font_em_size: f32,
    glyph_count: UINT,
    glyph_indices: [*]const u16,
    glyph_advances: ?[*]const f32,
    glyph_offsets: ?*const anyopaque,
    is_sideways: BOOL,
    bidi_level: UINT,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(FontMetrics) == 20);
        std.debug.assert(@sizeOf(GlyphMetrics) == 28);
        std.debug.assert(@sizeOf(Rect) == 16);
        // 포인터 정렬 때문에 `font_em_size`·`glyph_count`가 8바이트 칸을 나눠 쓴다 — 크기만 재면
        // 그 배치가 어긋나도 통과하므로 오프셋을 못 박는다(§2c 규약).
        std.debug.assert(@sizeOf(GlyphRun) == 48);
        std.debug.assert(@offsetOf(GlyphRun, "font_em_size") == 8);
        std.debug.assert(@offsetOf(GlyphRun, "glyph_count") == 12);
        std.debug.assert(@offsetOf(GlyphRun, "glyph_indices") == 16);
        std.debug.assert(@offsetOf(GlyphRun, "is_sideways") == 40);
        std.debug.assert(@offsetOf(GlyphRun, "bidi_level") == 44);
    }
}

const factory_type_shared: UINT = 0;
const font_weight_normal: UINT = 400;
const font_stretch_normal: UINT = 5;
const font_style_normal: UINT = 0;
/// `DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC` — 작은 크기에서 좌우 대칭을 지켜 터미널 격자에 어울린다.
const rendering_mode_natural_symmetric: UINT = 5;
const measuring_mode_natural: UINT = 0;
/// `DWRITE_TEXTURE_CLEARTYPE_3x1` — 픽셀당 3바이트(RGB 서브픽셀). 우리는 평균해 회색으로 쓴다.
const texture_cleartype_3x1: UINT = 1;
/// `DWRITE_FONT_FACE_TYPE_TRUETYPE` = **1**(0 은 CFF 다). 번들 폰트는 전부 `.ttf` 다(assets/fonts/).
/// 값을 틀리면 `CreateFontFace` 가 실패하고 번들 폰트가 **조용히 안 열린다** — 아래 테스트가 못 박는다.
const font_face_type_truetype: UINT = 1;
/// `DWRITE_FONT_SIMULATIONS_NONE`. 굵게/기울임을 **합성하지 않는다** — 번들에 진짜 face 가 따로 있다.
const font_simulations_none: UINT = 0;
const cleartype_bytes_per_pixel: usize = 3;

/// `IDWriteFactory3`. **번들 폰트를 컬렉션에 담는 유일한 이유**로 쓴다 — `IDWriteTextLayout` 은 폰트를
/// **이름으로 컬렉션에서** 찾으므로, 파일에서 연 face 만으로는 다리(§2m.13)가 못 쓴다.
///
/// 슬롯은 `IDWriteFactory` 24(0..23, 이 파일의 assert 가 소유) + Factory1 2(24,25) + Factory2 5(26..30 —
/// `GetSystemFontFallback`=26 은 §2m.12 가 실측) 뒤에 온다. 아래 assert 가 그 유도를 못 박고, 값이
/// 틀리면 **크래시거나 조용한 오답**이라 실기 실행으로도 확인했다(§2m.15).
const IDWriteFactory3 = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [36]*const anyopaque,
        CreateFontSetBuilder: *const fn (*IDWriteFactory3, *?*IDWriteFontSetBuilder) callconv(abi.winapi) HRESULT,
        CreateFontCollectionFromFontSet: *const fn (*IDWriteFactory3, *anyopaque, *?*IDWriteFontCollection) callconv(abi.winapi) HRESULT,
    };
};

/// `IDWriteFontSetBuilder` + `IDWriteFontSetBuilder1` 의 `AddFontFile`.
///
/// **`AddFontFile` 은 `IDWriteFontSetBuilder1`(Win10 1703+) 것이다** — `QueryInterface` 로 올린
/// 포인터에서만 부른다. 안 올리고 부르면 `CreateFontSet` 자리를 부르게 된다.
const IDWriteFontSetBuilder = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFontSetBuilder, *const d3d11.GUID, *?*anyopaque) callconv(abi.winapi) HRESULT,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        AddFontFaceReferenceWithProps: *const anyopaque,
        AddFontFaceReference: *const anyopaque,
        AddFontSet: *const anyopaque,
        CreateFontSet: *const fn (*IDWriteFontSetBuilder, *?*anyopaque) callconv(abi.winapi) HRESULT,
        /// `IDWriteFontSetBuilder1` 의 첫 추가 메서드.
        AddFontFile: *const fn (*IDWriteFontSetBuilder, *anyopaque) callconv(abi.winapi) HRESULT,
    };
};

const IID_IDWriteFactory3 = d3d11.GUID{
    .data1 = 0x9a1b41c3,
    .data2 = 0xd3bb,
    .data3 = 0x466a,
    .data4 = .{ 0x87, 0xfc, 0xfe, 0x67, 0x55, 0x6a, 0x3b, 0x65 },
};
const IID_IDWriteFontSetBuilder1 = d3d11.GUID{
    .data1 = 0x3ff7715f,
    .data2 = 0x3cdc,
    .data3 = 0x4dc6,
    .data4 = .{ 0x9b, 0x72, 0xec, 0x56, 0x21, 0xdc, 0xca, 0xfd },
};

extern "dwrite" fn DWriteCreateFactory(factory_type: UINT, iid: *const d3d11.GUID, out: *?*anyopaque) callconv(abi.winapi) HRESULT;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, filename: [*]u16, size: u32) callconv(abi.winapi) u32;

// ── 폰트 티어 ────────────────────────────────────────────────────────────────────────────────

/// 설정이 비어 있거나 그 폰트가 없을 때 Windows에서 시도할 순서. **§3.1a의 셸 티어와 같은 모양**이다 —
/// 사용자가 정한 것이 최우선이고, 없으면 이 순서로 내려간다.
///
/// ⑴ `Cascadia Mono` — Windows Terminal의 기본이고 터미널용으로 설계됐다(리가처 없는 변종을 고른다).
/// ⑵ `Consolas` — Vista부터 모든 Windows에 있다. Cascadia가 없는 구형 설치의 안전망.
/// ⑶ `Courier New` — 최후. 예쁘지 않지만 **없을 수가 없다**.
///
/// 이 목록은 **OS를 인자로 받는 순수 함수**를 통해서만 쓰이므로 macOS·Linux CI에서도 테스트가 돈다.
pub const windows_font_tier = [_][]const u8{ "Cascadia Mono", "Consolas", "Courier New" };

/// 주 폰트에 없는 글자를 그릴 때 시도할 순서. config `font.fallback`이 비어 있어도 **이만큼은 시도한다** —
/// 한글이 안 나오는 터미널은 쓸 수 없고, 고정폭 라틴 폰트에는 한글·CJK·이모지가 없는 게 정상이다
/// (실측: Cascadia Mono에서 한글 10자가 전부 `.notdef`였다).
///
/// macOS는 `kCTFontCascadeListAttribute`로 CoreText에 맡기지만 DirectWrite에는 그 자동 cascade가
/// `IDWriteFactory2` 이후에만 있어, **목록을 우리가 갖는다.** 없는 폰트는 조용히 건너뛴다(config 문서가
/// 정한 best-effort와 같은 규칙).
pub const windows_fallback_tier = [_][]const u8{
    "Malgun Gothic", // 한글 — Windows 한국어 기본 UI 폰트
    "Noto Sans KR", // 한글 — Malgun이 없는 설치의 안전망(개발기 실측: Malgun 없고 이것이 있었다)
    "Microsoft YaHei", // 간체
    "Microsoft JhengHei", // 번체
    "Yu Gothic", // 일본어
    "Segoe UI Emoji", // 이모지
    "Segoe UI Symbol", // 기타 기호
};

/// 열어 둘 폰트 face 최대 개수(주 1 + 폴백). 넘치면 뒤를 버린다 — 무한히 열지 않는다.
pub const max_faces = windows_fallback_tier.len + 5;

/// `font.fallback`(쉼표 구분)을 풀어 폴백 순서를 만든다. 사용자 항목이 **앞**, 내장 티어가 뒤다.
///
/// 각 항목은 앞뒤 공백을 다듬고 내부 공백은 보존한다(config 계약이 그렇다). 빈 항목은 버리고, 이미 나온
/// 이름은 건너뛴다(대소문자 무시). `primary`와 같은 이름도 건너뛴다 — 주 폰트를 두 번 물어볼 이유가 없다.
///
/// 순수 함수라 **모든 타깃에서** 테스트가 돈다.
pub fn fallbackCandidates(csv: []const u8, primary: []const u8, out: *[max_faces][]const u8) []const []const u8 {
    var n: usize = 0;
    const seen = struct {
        fn has(list: []const []const u8, primary_name: []const u8, name: []const u8) bool {
            if (std.ascii.eqlIgnoreCase(primary_name, name)) return true;
            for (list) |x| if (std.ascii.eqlIgnoreCase(x, name)) return true;
            return false;
        }
    };

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        if (n == out.len) break;
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (seen.has(out[0..n], primary, name)) continue;
        out[n] = name;
        n += 1;
    }
    for (windows_fallback_tier) |name| {
        if (n == out.len) break;
        if (seen.has(out[0..n], primary, name)) continue;
        out[n] = name;
        n += 1;
    }
    return out[0..n];
}

/// 시도할 폰트 이름 순서를 만든다. `configured`가 비어 있지 않으면 **맨 앞**에 온다.
///
/// 순수 함수다 — 실제로 폰트가 있는지는 여기서 모른다(그것은 DirectWrite가 답한다). 이 함수가 정하는 것은
/// **순서**뿐이라 모든 타깃에서 테스트할 수 있다.
pub fn fontCandidates(configured: []const u8, out: *[windows_font_tier.len + 1][]const u8) []const []const u8 {
    var n: usize = 0;
    const trimmed = std.mem.trim(u8, configured, " \t");
    if (trimmed.len > 0) {
        out[n] = trimmed;
        n += 1;
    }
    for (windows_font_tier) |name| {
        // 설정값과 같은 이름을 두 번 시도하지 않는다(대소문자 무시 — Windows 폰트 이름이 그렇다).
        if (n > 0 and std.ascii.eqlIgnoreCase(out[0], name)) continue;
        out[n] = name;
        n += 1;
    }
    return out[0..n];
}

// ── 래스터라이저 ─────────────────────────────────────────────────────────────────────────────

/// 셀 하나의 픽셀 크기와 베이스라인. 폰트 메트릭에서 유도한다 — **셀 격자는 폰트가 정한다**(터미널이
/// 임의로 정하면 글자가 셀을 넘거나 남는다).
/// 번들 폰트 컬렉션을 **불투명 포인터로** 만든다 — 셰이핑 다리(`dwrite_shape`)가 쓴다.
///
/// 그쪽은 자기 `IDWriteFactory2` 를 들고 있는데 이 파일의 `IDWriteFactory` 는 비공개 타입이라 그대로는
/// 못 넘긴다. **`shared` 팩토리는 같은 객체**이므로(§2m.15 실측) 불투명 포인터로 받아 캐스팅하면 된다.
pub fn createBundledCollectionRaw(factory_raw: *anyopaque) ?*anyopaque {
    if (builtin.os.tag != .windows) return null;
    const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_raw));
    const coll = Rasterizer.createBundledCollection(factory) orelse return null;
    return @ptrCast(coll);
}

pub const CellMetrics = struct {
    width_px: u32,
    height_px: u32,
    /// 셀 위쪽에서 베이스라인까지의 픽셀. 글리프를 여기에 앉힌다.
    baseline_px: u32,
};

/// 디자인 단위 폰트 메트릭에서 셀 격자를 유도하는 **순수** 변환.
///
/// **올림한다.** 내림하면 글리프가 셀 밖으로 반 픽셀 새어 옆 칸을 침범한다 — 격자 렌더에서 가장 눈에
/// 띄는 결함이다. 그리고 **최소 1을 보장한다**: 아주 작은 `em_size_px`나 이상한 폰트에서 0이 나오면
/// 아틀라스 슬롯이 0바이트가 되고 그 뒤 인덱싱이 전부 어긋난다.
///
/// `upem`이 0이면 `null`이다(0으로 나누지 않는다) — 폰트가 망가진 경우다.
///
/// DirectWrite 없이 돌므로 **모든 타깃에서** 이 규칙이 테스트된다.
pub fn cellMetricsFrom(
    upem: u16,
    ascent: u16,
    descent: u16,
    line_gap: i16,
    advance_width: u32,
    em_size_px: f32,
) ?CellMetrics {
    if (upem == 0) return null;
    const scale = em_size_px / @as(f32, @floatFromInt(upem));
    const advance_px = @as(f32, @floatFromInt(advance_width)) * scale;
    const ascent_px = @as(f32, @floatFromInt(ascent)) * scale;
    const descent_px = @as(f32, @floatFromInt(descent)) * scale;
    const gap_px = @as(f32, @floatFromInt(line_gap)) * scale;
    return .{
        .width_px = ceilAtLeastOne(advance_px),
        .height_px = ceilAtLeastOne(ascent_px + descent_px + gap_px),
        .baseline_px = ceilAtLeastOne(ascent_px),
    };
}

fn ceilAtLeastOne(v: f32) u32 {
    if (!(v > 0)) return 1; // NaN·0·음수를 한 번에 접는다 — `line_gap`이 음수인 폰트가 실제로 있다.
    return @max(1, @as(u32, @intFromFloat(@ceil(v))));
}

/// ClearType 서브픽셀 3바이트를 회색 커버리지 하나로 접는 **순수** 변환.
///
/// DirectWrite가 회색 알파 텍스처를 주지 않아(`ALIASED_1x1`은 안티앨리어싱이 없고 `CLEARTYPE_3x1`은 RGB
/// 서브픽셀뿐) 평균을 쓴다. 우리 아틀라스는 채널 하나(알파)만 쓰므로 셋을 합쳐야 하고, 평균이 곧 그
/// 픽셀이 덮인 정도다.
pub fn grayFromClearType(r: u8, g: u8, b: u8) u8 {
    // u8 셋의 합은 최대 765이라 u32에서 더한 뒤 나눈다 — u8로 더하면 넘친다.
    return @intCast((@as(u32, r) + @as(u32, g) + @as(u32, b)) / 3);
}

/// OpenType `name` 테이블 태그. `DWRITE_MAKE_OPENTYPE_TAG` 와 같은 바이트 순서다(첫 글자가 최하위).
const tag_name: UINT = @as(UINT, 'n') | (@as(UINT, 'a') << 8) | (@as(UINT, 'm') << 16) | (@as(UINT, 'e') << 24);

fn readBe16(bytes: []const u8, at: usize) ?u16 {
    if (at + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}

/// OpenType `name` 테이블에서 **PostScript 이름**(name ID 6)을 꺼낸다. 없으면 `null`.
///
/// **이름 하나가 face 를 하나로 정해야 한다.** measured 크롬 텍스트는 폰트를
/// `FontIdentity.postscript_name` 으로 가리키고, 래스터라이저는 그 이름으로 face 를 되찾아 셰이퍼가
/// 정한 **글리프 번호**를 굽는다. 글리프 번호는 face 마다 다르므로, 이름이 face 를 못 정하면 다른
/// face 의 번호를 굽는다. **family 이름은 그 일을 못 한다** — 같은 family 의 Regular 와 Bold 는 다른
/// face 다. 실측(§2m.90): 굵은 도크 제목이 Regular 로 구워져 글자가 **한 칸씩 밀려** 나왔다.
/// PostScript 이름은 face 마다 다르므로 그 일을 한다.
///
/// 표는 OpenType `name` 명세 그대로다 — 헤더 6 바이트(version·count·storageOffset) 뒤에 12 바이트
/// NameRecord 가 count 개, 문자열은 `storageOffset + stringOffset` 에 있고 전부 big-endian 이다.
/// **Windows 판(platform 3)을 먼저** 본다(UTF-16BE, 거의 모든 폰트에 있다). 없으면 Macintosh 판
/// (platform 1, 1 바이트). PostScript 이름은 명세가 ASCII 로 제한하므로 그 밖의 바이트가 나오면 그
/// 레코드를 버린다 — **깨진 이름을 쓰면 엉뚱한 face 에 붙는다**.
pub fn postScriptNameFromNameTable(bytes: []const u8, out: []u8) ?[]const u8 {
    if (postScriptNameForPlatform(bytes, 3, out)) |s| return s;
    return postScriptNameForPlatform(bytes, 1, out);
}

fn postScriptNameForPlatform(bytes: []const u8, want_platform: u16, out: []u8) ?[]const u8 {
    const count = readBe16(bytes, 2) orelse return null;
    const storage = readBe16(bytes, 4) orelse return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = 6 + @as(usize, i) * 12;
        if (rec + 12 > bytes.len) return null;
        if ((readBe16(bytes, rec) orelse return null) != want_platform) continue;
        if ((readBe16(bytes, rec + 6) orelse return null) != 6) continue; // nameID 6 = PostScript 이름
        const len: usize = readBe16(bytes, rec + 8) orelse return null;
        const off: usize = @as(usize, storage) + (readBe16(bytes, rec + 10) orelse return null);
        const step: usize = if (want_platform == 3) 2 else 1;
        if (len == 0 or len % step != 0 or off + len > bytes.len) continue;
        const raw = bytes[off..][0..len];
        var n: usize = 0;
        var k: usize = 0;
        const ok = while (k < raw.len) : (k += step) {
            const c = raw[k + step - 1];
            if (step == 2 and raw[k] != 0) break false;
            if (c < 0x20 or c > 0x7e or n == out.len) break false;
            out[n] = c;
            n += 1;
        } else true;
        if (ok and n > 0) return out[0..n];
    }
    return null;
}

/// face 하나의 PostScript 이름. **컬렉션이 필요 없다** — 파일에서 바로 연 번들 face 와 시스템 face 가
/// 같은 길을 쓴다(`IDWriteFont` 를 거치면 파일 face 는 답을 못 얻는다).
fn facePostScriptName(face: *IDWriteFontFace, out: []u8) ?[]const u8 {
    var data: ?*const anyopaque = null;
    var size: UINT = 0;
    var ctx: ?*anyopaque = null;
    var exists: BOOL = 0;
    if (d3d11.failed(face.vtable.TryGetFontTable(face, tag_name, &data, &size, &ctx, &exists))) return null;
    // **빌린 것은 성공/실패와 무관하게 돌려준다.** `exists = 0` 이어도 `ctx` 가 올 수 있다.
    defer if (ctx) |cx| face.vtable.ReleaseFontTable(face, cx);
    if (exists == 0 or size == 0) return null;
    const raw = data orelse return null;
    return postScriptNameFromNameTable(@as([*]const u8, @ptrCast(raw))[0..size], out);
}

test "postScriptNameFromNameTable: Windows 판을 먼저 읽는다" {
    // 레코드 둘 — Macintosh(platform 1) 가 앞, Windows(platform 3) 가 뒤. 뒤엣것이 이겨야 한다.
    const mac = "MacName";
    const win = "WinName";
    var t: [6 + 12 * 2 + 7 + 14]u8 = undefined;
    const storage: u16 = 6 + 12 * 2;
    std.mem.writeInt(u16, t[0..2], 0, .big);
    std.mem.writeInt(u16, t[2..4], 2, .big);
    std.mem.writeInt(u16, t[4..6], storage, .big);
    inline for (.{ .{ 6, 1, 0, mac.len, 0 }, .{ 18, 3, 1, win.len * 2, mac.len } }) |r| {
        std.mem.writeInt(u16, t[r[0]..][0..2], r[1], .big); // platform
        std.mem.writeInt(u16, t[r[0] + 2 ..][0..2], r[2], .big); // encoding
        std.mem.writeInt(u16, t[r[0] + 4 ..][0..2], 0, .big); // language
        std.mem.writeInt(u16, t[r[0] + 6 ..][0..2], 6, .big); // nameID
        std.mem.writeInt(u16, t[r[0] + 8 ..][0..2], @intCast(r[3]), .big); // length
        std.mem.writeInt(u16, t[r[0] + 10 ..][0..2], @intCast(r[4]), .big); // offset
    }
    @memcpy(t[storage..][0..mac.len], mac);
    for (win, 0..) |c, i| {
        t[storage + mac.len + i * 2] = 0;
        t[storage + mac.len + i * 2 + 1] = c;
    }
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("WinName", postScriptNameFromNameTable(&t, &out).?);
    // Windows 판을 지우면(count 를 1 로) Macintosh 판으로 내려간다 — 차선이 살아 있다는 뜻.
    std.mem.writeInt(u16, t[2..4], 1, .big);
    try std.testing.expectEqualStrings("MacName", postScriptNameFromNameTable(&t, &out).?);
}

test "postScriptNameFromNameTable: 못 믿을 표는 null 이다" {
    var out: [64]u8 = undefined;
    try std.testing.expect(postScriptNameFromNameTable("", &out) == null);
    try std.testing.expect(postScriptNameFromNameTable(&[_]u8{ 0, 0, 0, 9, 0, 6 }, &out) == null); // 레코드가 없다
    // nameID 가 6 이 아니면(= family 이름 자리) 안 준다 — 그 혼동이 이 결함의 뿌리였다.
    var t: [6 + 12 + 4]u8 = @splat(0);
    std.mem.writeInt(u16, t[2..4], 1, .big);
    std.mem.writeInt(u16, t[4..6], 18, .big);
    std.mem.writeInt(u16, t[6..8], 1, .big); // platform 1
    std.mem.writeInt(u16, t[12..14], 1, .big); // nameID 1 = family
    std.mem.writeInt(u16, t[14..16], 4, .big);
    @memcpy(t[18..], "Abcd");
    try std.testing.expect(postScriptNameFromNameTable(&t, &out) == null);
    std.mem.writeInt(u16, t[12..14], 6, .big);
    try std.testing.expectEqualStrings("Abcd", postScriptNameFromNameTable(&t, &out).?);
}

/// DirectWrite로 글리프를 그리는 래스터라이저. 중립 계약(`renderer/glyph_raster.zig`의 덕 타이핑
/// `rasterize`)에 맞출 수 있도록 **코드포인트 하나 → RGBA8 버퍼 하나**를 하는 함수를 노출한다.
pub const Rasterizer = struct {
    factory: *IDWriteFactory,
    /// 주 폰트가 `faces[0]`, 그 뒤가 폴백 순서다. **글리프가 없으면 다음 face로 내려간다.**
    faces: [max_faces]?*IDWriteFontFace = @splat(null),
    /// 번들 폰트만 담은 컬렉션. 없으면 `null`(시스템 폰트로만 간다).
    /// **셰이핑 다리(§2m.13)가 이것을 layout 에 넘긴다** — 그쪽은 이름으로만 폰트를 찾는다.
    bundled: ?*IDWriteFontCollection = null,
    face_count: usize = 0,
    /// 열린 face 마다의 **이름**. measured 텍스트가 폰트를 `FontIdentityRegistry` 의 이름으로
    /// 가리키므로(`resolveArtifact` 가 `intern(postscript_name)` 한다), 그 이름을 face 로 되돌리려면
    /// 여기 있어야 한다. 이름이 없으면 `faceIndexForName` 이 늘 실패하고, 그 실패가 조용한 zero-ink 로
    /// 접혀 **화면에 글자가 하나도 안 나온다**(실측으로 그렇게 됐다).
    face_names: [max_faces][64]u8 = @splat(@splat(0)),
    face_name_len: [max_faces]usize = @splat(0),
    /// 열린 face 마다의 **PostScript 이름**. `face_names` 는 우리가 **찾을 때 쓴 family 이름**이라
    /// face 를 하나로 못 정한다(같은 family 의 Regular·Bold). 셰이퍼가 싣는 신원은 이쪽이다
    /// (`postScriptNameFromNameTable` 의 doc, §2m.90).
    face_ps_names: [max_faces][64]u8 = @splat(@splat(0)),
    face_ps_name_len: [max_faces]usize = @splat(0),
    /// 시스템 폰트 컬렉션. **`create` 가 끝난 뒤에도 들고 있다** — 셰이퍼가 우리가 안 연 face
    /// (같은 family 의 다른 굵기)로 셰이핑하면 그때 그 face 를 열어야 한다.
    system: ?*IDWriteFontCollection = null,
    /// 실제로 고른 주 폰트 이름(진단·보고용). `family_name_buf`를 가리킨다.
    family: []const u8,
    family_name_buf: [128]u8 = undefined,
    /// 실제로 열린 폴백 face 개수(= `face_count - 1`). 보고용 — 티어에 이름을 넣어도 그 폰트가 없으면
    /// 열리지 않으므로, "몇 개 시도했나"와 "몇 개 열렸나"는 다르다.
    fallback_opened: usize = 0,
    em_size_px: f32,
    metrics: CellMetrics,
    /// 셀 격자를 유도한 **원본 디자인 단위**. 진단용이다 — 셀이 왜 그 크기인지 설명하는 유일한 근거이고,
    /// 이 값 없이는 `cellMetricsFrom` 테스트가 무엇을 흉내 내는지 확인할 수 없다.
    design: DesignMetrics = .{},
    allocator: std.mem.Allocator,

    fn rememberFaceName(self: *Rasterizer, index: usize, name: []const u8, face: *IDWriteFontFace) void {
        const n = @min(name.len, self.face_names[index].len);
        @memcpy(self.face_names[index][0..n], name[0..n]);
        self.face_name_len[index] = n;
        // PostScript 이름은 **없을 수 있다**(테이블이 없거나 ASCII 밖) — 그러면 0 이고,
        // `faceIndexForName` 이 family 이름으로 내려간다(예전 동작).
        self.face_ps_name_len[index] = 0;
        var buf: [64]u8 = undefined;
        if (facePostScriptName(face, &buf)) |ps| {
            const m = @min(ps.len, self.face_ps_names[index].len);
            @memcpy(self.face_ps_names[index][0..m], ps[0..m]);
            self.face_ps_name_len[index] = m;
        }
    }

    /// 이름으로 열린 face 를 찾는다. **measured 텍스트가 쓰는 길이다** — 그쪽은 폰트를
    /// `FontIdentityRegistry` 의 이름으로 가리키지 `fontIdForFace` 인코딩으로 가리키지 않는다.
    ///
    /// 대소문자를 무시한다 — DirectWrite 가 돌려주는 가족 이름과 config·티어에 적힌 이름이 늘 같은
    /// 표기는 아니다(`fallbackCandidates` 도 같은 이유로 그렇게 비교한다).
    pub fn faceIndexForName(self: *Rasterizer, name: []const u8) ?usize {
        if (name.len == 0) return null;
        // **PostScript 이름이 먼저다.** 그것이 face 를 하나로 정하는 유일한 이름이다.
        for (0..self.face_count) |i| {
            const have = self.face_ps_names[i][0..self.face_ps_name_len[i]];
            if (std.ascii.eqlIgnoreCase(have, name)) return i;
        }
        // family 이름으로도 받는다 — PostScript 이름을 못 읽은 face(테이블이 없는 것)가 그리로 온다.
        for (0..self.face_count) |i| {
            const have = self.face_names[i][0..self.face_name_len[i]];
            if (std.ascii.eqlIgnoreCase(have, name)) return i;
        }
        return self.openFaceForPostScriptName(name);
    }

    /// 아직 안 연 face 를 **그 이름으로** 연다. 못 열면 `null` — 호출부가 `RasterizerFailed` 로
    /// 접어 `error_skip` 으로 센다(조용히 다른 face 로 굽지 않는다).
    ///
    /// **이미 연 face 들의 family 안만 뒤진다.** 이 결함의 모양이 늘 "같은 family, 다른 굵기" 이고
    /// (셰이퍼도 우리가 준 목록으로 셰이핑한다), 컬렉션 전체를 훑으면 폰트 수백 개의 `name` 테이블을
    /// 읽어야 한다. 목록 밖의 face 로 셰이핑된 글자는 **못 찾은 채로 보고된다** — 그 편이 엉뚱한
    /// face 로 굽는 것보다 낫다.
    fn openFaceForPostScriptName(self: *Rasterizer, name: []const u8) ?usize {
        if (self.face_count >= max_faces) return null;
        const known = self.face_count;
        for (0..known) |i| {
            const family = self.face_names[i][0..self.face_name_len[i]];
            if (family.len == 0) continue;
            for ([_]?*IDWriteFontCollection{ self.bundled, self.system }) |maybe| {
                const coll = maybe orelse continue;
                const f = faceInFamilyByPostScriptName(coll, family, name) orelse continue;
                if (!faceIsUsable(f, false)) {
                    d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
                    continue;
                }
                self.faces[self.face_count] = f;
                self.rememberFaceName(self.face_count, family, f);
                self.face_count += 1;
                return self.face_count - 1;
            }
        }
        return null;
    }

    /// family 하나 안의 face 들을 훑어 **PostScript 이름이 같은 것**을 연다. 없으면 `null`.
    fn faceInFamilyByPostScriptName(collection: *IDWriteFontCollection, family: []const u8, want: []const u8) ?*IDWriteFontFace {
        var wide: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], family) catch return null;
        wide[wlen] = 0;
        var index: UINT = 0;
        var exists: BOOL = 0;
        if (d3d11.failed(collection.vtable.FindFamilyName(collection, @ptrCast(&wide), &index, &exists))) return null;
        if (exists == 0) return null;
        var fam: ?*IDWriteFontFamily = null;
        if (d3d11.failed(collection.vtable.GetFontFamily(collection, index, &fam))) return null;
        const family_obj = fam orelse return null;
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(family_obj)));

        const n = family_obj.vtable.GetFontCount(family_obj);
        var i: UINT = 0;
        while (i < n) : (i += 1) {
            var font: ?*IDWriteFont = null;
            if (d3d11.failed(family_obj.vtable.GetFont(family_obj, i, &font))) continue;
            const fo = font orelse continue;
            defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(fo)));
            var f: ?*IDWriteFontFace = null;
            if (d3d11.failed(fo.vtable.CreateFontFace(fo, &f))) continue;
            const face = f orelse continue;
            var buf: [64]u8 = undefined;
            const ps = facePostScriptName(face, &buf) orelse {
                d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(face)));
                continue;
            };
            if (std.ascii.eqlIgnoreCase(ps, want)) return face;
            d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(face)));
        }
        return null;
    }

    pub const DesignMetrics = struct {
        upem: u16 = 0,
        ascent: u16 = 0,
        descent: u16 = 0,
        line_gap: i16 = 0,
        advance_width: u32 = 0,
    };

    /// 이름 하나를 face로 바꾼다. 없으면 `null` — **오류가 아니다**(폴백 목록에는 없는 폰트가 흔하다).
    fn resolveFace(collection: *IDWriteFontCollection, name: []const u8) ?*IDWriteFontFace {
        // 이름을 UTF-16으로. 너무 길면 그 후보만 건너뛴다(전체 실패로 만들지 않는다).
        var wide: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], name) catch return null;
        wide[wlen] = 0;

        var index: UINT = 0;
        var exists: BOOL = 0;
        if (d3d11.failed(collection.vtable.FindFamilyName(collection, @ptrCast(&wide), &index, &exists))) return null;
        if (exists == 0) return null;

        var family: ?*IDWriteFontFamily = null;
        if (d3d11.failed(collection.vtable.GetFontFamily(collection, index, &family))) return null;
        defer d3d11.releaseOpt(family);

        var font: ?*IDWriteFont = null;
        if (d3d11.failed(family.?.vtable.GetFirstMatchingFont(family.?, font_weight_normal, font_stretch_normal, font_style_normal, &font))) return null;
        defer d3d11.releaseOpt(font);

        var f: ?*IDWriteFontFace = null;
        if (d3d11.failed(font.?.vtable.CreateFontFace(font.?, &f))) return null;
        return f;
    }

    /// exe 가 있는 디렉터리를 **중립 경로**(`/`)로 준다. 못 얻으면 `null`.
    ///
    /// **잘린 경로는 안 쓴다.** `GetModuleFileNameW` 는 버퍼가 모자라면 잘라 넣고 크기를 그대로 돌려준다
    /// (에러가 아니다). 그 값으로 파일을 열면 **다른 파일을 열거나 조용히 못 연다** — 그래서 가득 찬
    /// 경우를 실패로 접는다.
    fn exeDirNeutral(out: []u8) ?[]const u8 {
        if (builtin.os.tag != .windows) return null;
        var wide: [1024]u16 = undefined;
        const n = GetModuleFileNameW(null, &wide, wide.len);
        if (n == 0 or n >= wide.len) return null;
        const written = std.unicode.utf16LeToUtf8(out, wide[0..n]) catch return null;
        for (out[0..written]) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return maru.path_shape.parentOf(out[0..written]);
    }

    /// 파일 하나를 face 로 연다. 컬렉션도, 로더 COM 객체도 필요 없다.
    ///
    /// **없는 파일은 `CreateFontFace` 에서 걸린다.** `CreateFontFileReference` 는 경로를 받아 두기만 하고
    /// 실제로 열지 않아 `hr=0` 을 준다 — 여기서 성공을 판정하면 안 된다(아래 테스트가 그 자리를 지킨다).
    ///
    /// **`CreateFontFace` 의 `hr=0` 도 증거가 못 된다.** face 종류를 틀리면(`TRUETYPE` 대신 `CFF`)
    /// 실패하지 않고 **반쪽짜리 face** 를 준다 — 적대적 검증의 변이가 실증했다. 글리프 **인덱스는
    /// 나오는데 디자인 메트릭이 안 나온다**. 그런 face 가 `faces[0]` 이 되면 셀 격자를 못 뽑아
    /// 래스터라이저 전체가 `MetricsFailed` 로 죽는다. 그래서 여기서 **쓸 수 있는지 확인하고** 아니면
    /// `null` 로 접어 다음 후보로 넘어간다(`resolveFace` 의 "없으면 null" 규약과 같다).
    fn openFaceFromFile(factory: *IDWriteFactory, path: []const u8) ?*IDWriteFontFace {
        var wide: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
        wide[wlen] = 0;

        var file_ref: ?*anyopaque = null;
        if (d3d11.failed(factory.vtable.CreateFontFileReference(factory, @ptrCast(&wide), null, &file_ref))) return null;
        defer d3d11.releaseOpt(file_ref);
        var files = [_]?*anyopaque{file_ref};

        var face: ?*IDWriteFontFace = null;
        if (d3d11.failed(factory.vtable.CreateFontFace(factory, font_face_type_truetype, 1, &files, 0, font_simulations_none, &face))) return null;
        const f = face orelse return null;
        if (!faceIsUsable(f, true)) {
            d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
            return null;
        }
        return f;
    }

    /// face 가 실제로 쓸 수 있는지 본다 — **`hr=0` 은 답이 아니다**(위 doc).
    ///
    /// **`strict` 는 주 폰트냐 폴백이냐를 가른다.** 확인 항목이 소비자와 같아야 하기 때문이다:
    ///
    /// - **주 폰트**(`strict = true`): `create` 가 여기서 **셀 격자를 뽑는다** — `upem` 과 `'M'` 의
    ///   디자인 advance 가 필요하다. 셋 다 본다. 앞의 둘만 보면 부족하다는 것이 변이 실험에서 드러났다
    ///   (잘못 만든 face 가 **인덱스는 돌려주고 디자인 메트릭에서만** 실패했다).
    /// - **폴백**(`strict = false`): 격자를 안 만든다. 필요한 것은 글리프 조회가 도는 것뿐이라
    ///   `upem` 만 본다.
    ///
    /// **폴백에 `'M'` 을 요구하면 안 된다.** 라틴 글리프가 없는 폰트가 정당한 폴백일 수 있다 — 이모지·
    /// 기호 전용 폰트가 그렇다. `windows_fallback_tier` 는 오늘 전부 `'M'` 을 갖고 있지만(실측),
    /// 그것에 기대면 목록에 그런 폰트를 넣는 순간 **조용히 버려진다**.
    fn faceIsUsable(face: *IDWriteFontFace, strict: bool) bool {
        var fm: FontMetrics = undefined;
        face.vtable.GetMetrics(face, &fm);
        if (fm.design_units_per_em == 0) return false;
        if (!strict) return true;
        const probe = [_]u32{'M'};
        var gid: [1]u16 = undefined;
        if (d3d11.failed(face.vtable.GetGlyphIndices(face, &probe, 1, &gid))) return false;
        if (gid[0] == 0) return false;
        var gm: [1]GlyphMetrics = undefined;
        if (d3d11.failed(face.vtable.GetDesignGlyphMetrics(face, &gid, 1, &gm, 0))) return false;
        return gm[0].advance_width > 0;
    }

    /// 번들 폰트를 **파일에서 직접** 연다. 시스템에 설치돼 있지 않아도 된다.
    ///
    /// macOS 는 앱 번들이 `ATSApplicationFontsPath` 로 폰트를 프로세스에 등록해 줘서 이름만으로 열린다.
    /// Windows 에는 그 장치가 없어 **경로로 연다**. 두 OS 가 같은 폰트를 쓰게 하려면 이 자리가 필요하다 —
    /// config 기본값(`font.family = JetBrains Mono`, `font.fallback = Jetendard`)이 둘 다 번들이라,
    /// 이것이 없으면 Windows 만 시스템 폰트로 내려간다(§2e).
    ///
    /// **한글 자간이 실제 이유다.** 시스템 폴백(Malgun Gothic)의 한글 advance 는 셀 격자의 배수가 아니라
    /// 칸마다 여백이 남는다. Jetendard 는 한글을 자기 라틴의 **정확히 2 배**로 그리고(upem 1000 에서
    /// `M`=600, `한`=1200), 기본 주 폰트 `JetBrains Mono` 가 마침 같은 0.6 em 이라 둘이 맞아떨어진다.
    /// **주 폰트를 다른 번들로 바꾸면 그 정확함은 안 따라온다** — 범위와 실측은
    /// docs/windows-platform.md §2m.14 의 표가 소유한다.
    fn resolveBundledPath(factory: *IDWriteFactory, family: []const u8, out: []u8) ?[]const u8 {
        const rel = maru.config.theme.bundledRegularRelPath(family) orelse return null;
        var exe_buf: [1024]u8 = undefined;
        const exe_dir = exeDirNeutral(&exe_buf) orelse "";
        var roots: [4][]const u8 = undefined;
        // **정책은 여기 한 곳에 있다**(`assetSearchRoots` doc). 폰트는 DirectWrite 가 **프로세스
        // 안에서** 파싱하므로 출처를 좁힌다. 손잡이가 **둘이고 서로 다르게** 걸린다:
        //
        // **작업 디렉터리는 테스트에서만 본다.** 이것이 가장 나쁜 자리다 — 아무 저장소나
        // `assets/fonts/<Family>/<Family>-Regular.ttf` 를 담아 둘 수 있고, 터미널 사용자는 낯선
        // 저장소로 `cd` 하는 일이 잦다. 테스트 바이너리는 `.zig-cache` 안에 있어 여기로만 닿는다.
        // **`Debug` 로는 안 켠다** — 오늘 만드는 Windows 바이너리는 전부 `Debug` 라
        // (`standardOptimizeOption` 기본값이고 `.mise.toml` 의 Release 레시피는 macOS 뿐이다)
        // 최적화 모드로 가르면 그 방어가 **하나도 안 걸린다**(적대적 검증 3 라운드).
        //
        // **위로 오르는 것은 개발 빌드에서 켠다.** `zig-out/bin/maru.exe` 는 위로 두 단계가 저장소
        // 루트다. 이 자리가 공격자 것이 되려면 **maru 를 적대적 트리 안에서 빌드**해야 하는데,
        // 그 지경이면 폰트가 문제가 아니다.
        const cwd: []const u8 = if (builtin.is_test) "." else "";
        const up_levels: usize = if (builtin.mode == .Debug or builtin.is_test) 2 else 0;
        for (maru.path_shape.assetSearchRoots(exe_dir, cwd, up_levels, &roots)) |root| {
            const joined = std.fmt.bufPrint(out, "{s}/{s}", .{ root, rel }) catch continue;
            // **열어 봐야 안다.** `CreateFontFileReference` 는 없는 경로에도 `hr=0` 이라 존재 확인이
            // 안 되고, 종류가 틀리면 반쪽짜리 face 가 나온다(`openFaceFromFile` doc).
            const face = openFaceFromFile(factory, joined) orelse continue;
            d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(face)));
            return joined;
        }
        return null;
    }

    /// 번들 폰트만 담은 **폰트 컬렉션**을 만든다. 하나도 못 찾으면 `null`.
    ///
    /// **왜 컬렉션이 필요한가.** 래스터라이저는 face 만 있으면 되지만 `IDWriteTextLayout`(셰이핑 다리,
    /// §2m.13)은 폰트를 **이름으로 컬렉션에서** 찾는다. 번들 폰트가 시스템 컬렉션 밖이라, 컬렉션이
    /// 없으면 다리가 번들 폰트를 아예 못 쓴다.
    ///
    /// **구현할 COM 객체가 없다.** 커스텀 컬렉션의 고전적인 길은 `IDWriteFontCollectionLoader` +
    /// `IDWriteFontFileEnumerator` 를 우리가 구현하는 것인데, `IDWriteFontSetBuilder`(Factory3) 로 가면
    /// 파일을 넣고 세트를 컬렉션으로 바꾸기만 하면 된다 — 실기에서 확인했다(§2m.15).
    ///
    /// **없는 폰트는 조용히 건너뛴다.** 배포 형태에 따라 `assets/` 가 없을 수 있고, 그때는 시스템 폰트로
    /// 내려가는 것이 맞다(`resolveFace` 의 규약과 같다).
    pub fn createBundledCollection(factory: *IDWriteFactory) ?*IDWriteFontCollection {
        var raw3: ?*anyopaque = null;
        if (d3d11.failed(DWriteCreateFactory(factory_type_shared, &IID_IDWriteFactory3, &raw3))) return null;
        const f3: *IDWriteFactory3 = @ptrCast(@alignCast(raw3 orelse return null));
        defer d3d11.releaseOpt(raw3);

        var builder_raw: ?*IDWriteFontSetBuilder = null;
        if (d3d11.failed(f3.vtable.CreateFontSetBuilder(f3, &builder_raw))) return null;
        const builder = builder_raw orelse return null;
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(builder)));

        // `AddFontFile` 은 `IDWriteFontSetBuilder1` 것이다.
        var b1_raw: ?*anyopaque = null;
        if (d3d11.failed(builder.vtable.QueryInterface(builder, &IID_IDWriteFontSetBuilder1, &b1_raw))) return null;
        const b1: *IDWriteFontSetBuilder = @ptrCast(@alignCast(b1_raw orelse return null));
        defer d3d11.releaseOpt(b1_raw);

        var added: usize = 0;
        for (maru.config.theme.bundled_fonts) |bf| {
            var path_buf: [1400]u8 = undefined;
            const path = resolveBundledPath(factory, bf.family, &path_buf) orelse continue;
            var wide: [1024]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch continue;
            wide[wlen] = 0;
            var file_ref: ?*anyopaque = null;
            if (d3d11.failed(factory.vtable.CreateFontFileReference(factory, @ptrCast(&wide), null, &file_ref))) continue;
            defer d3d11.releaseOpt(file_ref);
            if (d3d11.failed(b1.vtable.AddFontFile(b1, file_ref.?))) continue;
            added += 1;
        }
        if (added == 0) return null;

        var set: ?*anyopaque = null;
        if (d3d11.failed(builder.vtable.CreateFontSet(builder, &set))) return null;
        defer d3d11.releaseOpt(set);

        var coll: ?*IDWriteFontCollection = null;
        if (d3d11.failed(f3.vtable.CreateFontCollectionFromFontSet(f3, set orelse return null, &coll))) return null;
        return coll;
    }

    /// 이름 하나를 face 로 바꾼다 — **시스템 먼저, 없으면 번들.**
    ///
    /// 순서가 이 방향인 이유: 사용자가 직접 설치한 폰트가 이긴다. 같은 이름의 번들본으로 조용히
    /// 바꿔치기하면 "내가 깐 폰트가 안 먹는다" 가 된다. 번들은 **없을 때의 바닥**이다.
    fn resolveFaceAnywhere(system: *IDWriteFontCollection, bundled: ?*IDWriteFontCollection, name: []const u8, strict: bool) ?*IDWriteFontFace {
        if (usableFaceFrom(system, name, strict)) |f| return f;
        const bc = bundled orelse return null;
        return usableFaceFrom(bc, name, strict);
    }

    /// 컬렉션 하나에서 이름을 찾고 **쓸 수 있는지까지** 본다.
    ///
    /// **시스템도 검증한다.** 예전에는 번들만 봤는데, 그러면 망가진 **시스템** 폰트가 `faces[0]` 이 되어
    /// `create` 가 `MetricsFailed` 로 죽는다 — 티어의 다음 후보로 안 내려간다. 두 갈래가 같은 규약을
    /// 쓰는 것이 맞다(`resolveFace` 의 "없으면 null, 오류가 아니다").
    fn usableFaceFrom(collection: *IDWriteFontCollection, name: []const u8, strict: bool) ?*IDWriteFontFace {
        const f = resolveFace(collection, name) orelse return null;
        if (faceIsUsable(f, strict)) return f;
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
        return null;
    }

    /// `configured`가 비어 있으면 티어의 첫 항목부터 시도한다. `fallback_csv`는 config `font.fallback`
    /// 그대로(쉼표 구분)이고, 비어 있어도 내장 폴백 티어는 시도한다. `em_size_px`는 config `font.size`를
    /// 픽셀로 환산한 값이다(DPI 적용은 호출자 몫 — 이 파일은 픽셀만 안다).
    pub fn create(allocator: std.mem.Allocator, configured: []const u8, fallback_csv: []const u8, em_size_px: f32) Error!*Rasterizer {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

        var factory_raw: ?*anyopaque = null;
        try check(DWriteCreateFactory(factory_type_shared, &IID_IDWriteFactory, &factory_raw), error.CreateFactoryFailed);
        const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));
        errdefer d3d11.releaseOpt(factory_raw);

        var collection: ?*IDWriteFontCollection = null;
        // `false` = 시스템에 새로 설치된 폰트를 다시 훑지 않는다(시작이 빨라진다).
        try check(factory.vtable.GetSystemFontCollection(factory, &collection, 0), error.NoFontFound);
        // `self` 로 넘기기 전까지만 우리가 책임진다(넘긴 뒤에는 `releaseFaces` 가 놓는다).
        errdefer d3d11.releaseOpt(collection);

        var buf: [windows_font_tier.len + 1][]const u8 = undefined;
        const candidates = fontCandidates(configured, &buf);

        const self = allocator.create(Rasterizer) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .factory = factory,
            .family = "",
            .em_size_px = em_size_px,
            .metrics = .{ .width_px = 1, .height_px = 1, .baseline_px = 1 },
            .allocator = allocator,
        };
        // 여기서부터 face를 열기 시작하므로, 이후 실패는 열린 것을 전부 놓아야 한다.
        errdefer self.releaseFaces();
        // **소유권만 넘긴다** — 아래 두 루프는 여전히 이 컬렉션을 쓴다(`coll`).
        const coll = collection.?;
        self.system = collection;
        collection = null; // 위 errdefer 가 두 번 놓지 않게 한다.

        // **번들 컬렉션은 한 번만 만든다.** 이름마다 파일을 뒤지면 후보 수만큼 디스크를 친다.
        // 못 만들면 `null` 이고 시스템 폰트로만 간다 — 오류가 아니다.
        self.bundled = createBundledCollection(factory);

        var chosen: []const u8 = "";
        for (candidates) |name| {
            if (resolveFaceAnywhere(coll, self.bundled, name, true)) |f| {
                self.faces[0] = f;
                self.rememberFaceName(0, name, f);
                self.face_count = 1;
                chosen = name;
                break;
            }
        }
        const chosen_face = self.faces[0] orelse return error.NoFontFound;

        // ── 폴백 face들을 연다 ─────────────────────────────────────────────────────────────
        var fb_buf: [max_faces][]const u8 = undefined;
        for (fallbackCandidates(fallback_csv, chosen, &fb_buf)) |name| {
            if (self.face_count == max_faces) break;
            if (resolveFaceAnywhere(coll, self.bundled, name, false)) |f| {
                self.faces[self.face_count] = f;
                self.rememberFaceName(self.face_count, name, f);
                self.face_count += 1;
            }
        }
        self.fallback_opened = self.face_count - 1;

        // ── 셀 격자를 폰트에서 유도한다 ────────────────────────────────────────────────────
        var fm: FontMetrics = undefined;
        chosen_face.vtable.GetMetrics(chosen_face, &fm);

        // 셀 폭은 **'M'의 advance**로 잡는다. 고정폭 폰트라 어느 글자든 같지만, 'M'은 어느 폰트에나 있다.
        const m_cp = [_]u32{'M'};
        var m_glyph: [1]u16 = undefined;
        try check(chosen_face.vtable.GetGlyphIndices(chosen_face, &m_cp, 1, &m_glyph), error.MetricsFailed);
        var gm: [1]GlyphMetrics = undefined;
        try check(chosen_face.vtable.GetDesignGlyphMetrics(chosen_face, &m_glyph, 1, &gm, 0), error.MetricsFailed);

        self.design = .{
            .upem = fm.design_units_per_em,
            .ascent = fm.ascent,
            .descent = fm.descent,
            .line_gap = fm.line_gap,
            .advance_width = gm[0].advance_width,
        };
        // 유도 규칙은 순수 함수가 소유한다 — 그래야 올림·최소값 규칙이 모든 타깃에서 테스트된다.
        self.metrics = cellMetricsFrom(
            fm.design_units_per_em,
            fm.ascent,
            fm.descent,
            fm.line_gap,
            gm[0].advance_width,
            em_size_px,
        ) orelse return error.MetricsFailed;
        const n = @min(chosen.len, self.family_name_buf.len);
        @memcpy(self.family_name_buf[0..n], chosen[0..n]);
        self.family = self.family_name_buf[0..n];
        return self;
    }

    fn releaseFaces(self: *Rasterizer) void {
        for (self.faces[0..self.face_count]) |f| d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
        self.face_count = 0;
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.bundled)));
        self.bundled = null;
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.system)));
        self.system = null;
    }

    pub fn destroy(self: *Rasterizer) void {
        self.releaseFaces();
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.factory)));
        self.allocator.destroy(self);
    }

    /// 코드포인트를 그릴 face와 글리프 번호. `face_index`는 `faces`의 인덱스(0이 주 폰트)다.
    pub const GlyphChoice = struct { face_index: usize, glyph_id: u16 };

    /// 어느 face의 어느 글리프로 그릴지 **고른다**(그리지는 않는다). 전부 없으면 `null`.
    ///
    /// **고르기와 그리기를 갈라 둔 이유**는 셰이퍼와 래스터라이저가 같은 답을 써야 하기 때문이다. 중립
    /// 계약에서 셰이퍼가 `font_id`·`glyph_id`를 정하고 래스터라이저가 그 값을 받는데, 래스터라이저가
    /// 코드포인트로 다시 풀면 두 결정이 갈릴 수 있다(폴백 목록이 같아도 순서 판정이 어긋나면 다른 글리프를
    /// 그린다). 그래서 결정은 이 함수 하나가 소유한다.
    pub fn glyphFor(self: *Rasterizer, cp: u32) ?GlyphChoice {
        const cps = [_]u32{cp};
        var glyph: [1]u16 = undefined;
        for (self.faces[0..self.face_count], 0..) |candidate, i| {
            const f = candidate orelse continue;
            if (d3d11.failed(f.vtable.GetGlyphIndices(f, &cps, 1, &glyph))) continue;
            // 글리프 0은 `.notdef`다 — 이 폰트에 없는 글자이므로 다음 폴백에 묻는다.
            if (glyph[0] != 0) return .{ .face_index = i, .glyph_id = glyph[0] };
        }
        return null;
    }

    /// **face 하나가 말하는** 글리프 번호. 없으면 `null`.
    ///
    /// `glyphFor` 는 face 를 스스로 고르므로 *"셰이퍼가 고른 face 와 우리가 되찾은 face 가 같은 답을
    /// 내는가"* 에 답하지 못한다 — §2m.90 의 결함이 정확히 그 둘이 갈린 것이었다. 그것을 재려면
    /// **face 를 지정해서** 물어야 한다.
    pub fn glyphIdIn(self: *const Rasterizer, face_index: usize, cp: u32) ?u16 {
        if (face_index >= self.face_count) return null;
        const f = self.faces[face_index] orelse return null;
        const cps = [_]u32{cp};
        var glyph: [1]u16 = undefined;
        if (d3d11.failed(f.vtable.GetGlyphIndices(f, &cps, 1, &glyph))) return null;
        return glyph[0];
    }

    /// 코드포인트를 `pixels`(RGBA8, `bytes_per_row` 간격)에 그린다. **중립 규약을 그대로 지킨다** —
    /// RGB는 흰색, 커버리지는 알파. 덮인 픽셀 수를 돌려준다(0이면 잉크 없음 — 공백 등).
    ///
    /// 버퍼는 호출자가 **0으로 지워 넘긴다**(중립 계약이 그렇다 — `buildGlyphRasterFrame`이 그렇게 한다).
    /// 셀 밖으로 나가는 부분은 잘라 버린다: 글리프가 셀보다 크면(악센트·CJK) 넘치는 쪽을 포기하는 것이
    /// 옆 칸을 덮는 것보다 낫다.
    pub fn rasterize(
        self: *Rasterizer,
        cp: u32,
        cell_w: u32,
        cell_h: u32,
        bytes_per_row: usize,
        pixels: []u8,
        scratch: []u8,
    ) Error!u32 {
        // 고르는 것은 `glyphFor`가 소유한다 — 없으면 0(빈 칸)이 정직한 답이다.
        const choice = self.glyphFor(cp) orelse return 0;
        return self.rasterizeGlyph(choice, cell_w, cell_h, bytes_per_row, pixels, scratch);
    }

    /// 이미 고른 face·글리프로 그린다. 셰이퍼가 정한 결정을 **그대로** 받는 자리다(위 `glyphFor` 참조).
    pub fn rasterizeGlyph(
        self: *Rasterizer,
        choice: GlyphChoice,
        cell_w: u32,
        cell_h: u32,
        bytes_per_row: usize,
        pixels: []u8,
        scratch: []u8,
    ) Error!u32 {
        return self.rasterizeGlyphAtSize(choice, self.em_size_px, cell_w, cell_h, bytes_per_row, pixels, scratch);
    }

    /// **em 크기를 호출자가 정한다.** measured 크롬 텍스트는 role 마다 크기가 다르고
    /// (`GlyphCacheKey.raster_font_size_milli` — 그 필드 doc: *"플랫폼 래스터라이저만 소비한다"*),
    /// 터미널 하나의 크기로 구우면 도크 글자가 전부 터미널 크기로 나온다. macOS 는 이미 그 값을
    /// 읽는다(`coretext_raster.zig`) — 이 갈래가 그것의 Windows 짝이다.
    pub fn rasterizeGlyphAtSize(
        self: *Rasterizer,
        choice: GlyphChoice,
        em_size_px: f32,
        cell_w: u32,
        cell_h: u32,
        bytes_per_row: usize,
        pixels: []u8,
        scratch: []u8,
    ) Error!u32 {
        if (bytes_per_row < @as(usize, cell_w) * 4) return error.BufferTooSmall;
        if (pixels.len < bytes_per_row * cell_h) return error.BufferTooSmall;
        if (choice.face_index >= self.face_count) return error.FontFaceFailed;
        const use_face = self.faces[choice.face_index] orelse return error.FontFaceFailed;
        var glyph = [_]u16{choice.glyph_id};

        const run = GlyphRun{
            .font_face = use_face,
            .font_em_size = em_size_px,
            .glyph_count = 1,
            .glyph_indices = &glyph,
            .glyph_advances = null,
            .glyph_offsets = null,
            .is_sideways = 0,
            .bidi_level = 0,
        };

        var analysis: ?*IDWriteGlyphRunAnalysis = null;
        try check(self.factory.vtable.CreateGlyphRunAnalysis(
            self.factory,
            &run,
            1.0,
            null,
            rendering_mode_natural_symmetric,
            measuring_mode_natural,
            0,
            @floatFromInt(self.metrics.baseline_px),
            &analysis,
        ), error.AnalysisFailed);
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(analysis)));

        var bounds: Rect = undefined;
        try check(analysis.?.vtable.GetAlphaTextureBounds(analysis.?, texture_cleartype_3x1, &bounds), error.TextureFailed);
        const bw = bounds.right - bounds.left;
        const bh = bounds.bottom - bounds.top;
        // 잉크가 없으면 빈 사각형이 온다(공백·제어문자). 오류가 아니다.
        if (bw <= 0 or bh <= 0) return 0;

        const need = @as(usize, @intCast(bw)) * @as(usize, @intCast(bh)) * cleartype_bytes_per_pixel;
        if (scratch.len < need) return error.BufferTooSmall;
        @memset(scratch[0..need], 0);
        try check(analysis.?.vtable.CreateAlphaTexture(analysis.?, texture_cleartype_3x1, &bounds, scratch.ptr, @intCast(need)), error.TextureFailed);

        // ── ClearType 3바이트를 평균해 회색 커버리지로 ──────────────────────────────────────
        var covered: u32 = 0;
        const src_pitch = @as(usize, @intCast(bw)) * cleartype_bytes_per_pixel;
        var y: i32 = 0;
        while (y < bh) : (y += 1) {
            const dst_y = bounds.top + y;
            if (dst_y < 0 or dst_y >= @as(i32, @intCast(cell_h))) continue;
            var x: i32 = 0;
            while (x < bw) : (x += 1) {
                const dst_x = bounds.left + x;
                if (dst_x < 0 or dst_x >= @as(i32, @intCast(cell_w))) continue;

                const s = @as(usize, @intCast(y)) * src_pitch + @as(usize, @intCast(x)) * cleartype_bytes_per_pixel;
                const alpha = grayFromClearType(scratch[s], scratch[s + 1], scratch[s + 2]);
                if (alpha == 0) continue;

                const d = @as(usize, @intCast(dst_y)) * bytes_per_row + @as(usize, @intCast(dst_x)) * 4;
                // RGB는 흰색, 커버리지는 알파 — `renderer/glyph_pixels.zig`와 같은 규약이다.
                pixels[d + 0] = 0xFF;
                pixels[d + 1] = 0xFF;
                pixels[d + 2] = 0xFF;
                pixels[d + 3] = alpha;
                covered += 1;
            }
        }
        return covered;
    }

    /// ClearType 텍스처를 담을 스크래치의 최대 크기. 글리프가 셀보다 클 수 있어 넉넉히 잡는다
    /// (악센트·CJK가 셀 밖으로 나가면 `GetAlphaTextureBounds`가 그만큼 큰 사각형을 준다).
    pub fn scratchSize(cell_w: u32, cell_h: u32) usize {
        return @as(usize, cell_w) * 3 * @as(usize, cell_h) * 3 * cleartype_bytes_per_pixel;
    }
};

const testing = std.testing;

test "fontCandidates: 설정값이 맨 앞에 오고 티어가 뒤를 잇는다" {
    var buf: [windows_font_tier.len + 1][]const u8 = undefined;

    // 설정이 있으면 그것이 최우선이고, 티어 전부가 뒤에 온다.
    const with = fontCandidates("JetBrains Mono", &buf);
    try testing.expectEqual(@as(usize, windows_font_tier.len + 1), with.len);
    try testing.expectEqualStrings("JetBrains Mono", with[0]);
    try testing.expectEqualStrings("Cascadia Mono", with[1]);
    try testing.expectEqualStrings("Courier New", with[with.len - 1]);

    // 비어 있으면 티어만.
    const without = fontCandidates("", &buf);
    try testing.expectEqual(@as(usize, windows_font_tier.len), without.len);
    try testing.expectEqualStrings("Cascadia Mono", without[0]);

    // 공백만 있는 값은 비어 있는 것으로 본다 — config가 `font.family =` 로 비워 둘 수 있다.
    try testing.expectEqual(@as(usize, windows_font_tier.len), fontCandidates("   ", &buf).len);

    // 내부 공백은 보존한다(config 계약이 그렇다) — 앞뒤만 다듬는다.
    try testing.expectEqualStrings("Cascadia Code", fontCandidates("  Cascadia Code  ", &buf)[0]);
}

test "fontCandidates: 설정값이 티어와 같으면 두 번 시도하지 않는다" {
    var buf: [windows_font_tier.len + 1][]const u8 = undefined;

    // 같은 이름을 두 번 물어보는 것은 낭비이고, 실패 진단을 헷갈리게 한다.
    const same = fontCandidates("Consolas", &buf);
    try testing.expectEqual(@as(usize, windows_font_tier.len), same.len);
    try testing.expectEqualStrings("Consolas", same[0]);
    var consolas_count: usize = 0;
    for (same) |n| if (std.ascii.eqlIgnoreCase(n, "Consolas")) {
        consolas_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), consolas_count);

    // 대소문자가 달라도 같은 폰트다 — Windows 폰트 이름은 대소문자를 구분하지 않는다.
    const lower = fontCandidates("consolas", &buf);
    try testing.expectEqual(@as(usize, windows_font_tier.len), lower.len);
}

test "fallbackCandidates: 사용자 항목이 앞, 내장 티어가 뒤" {
    var buf: [max_faces][]const u8 = undefined;

    // 비어 있어도 내장 티어는 시도한다 — 한글이 안 나오는 터미널은 쓸 수 없다.
    const none = fallbackCandidates("", "Cascadia Mono", &buf);
    try testing.expectEqual(@as(usize, windows_fallback_tier.len), none.len);
    try testing.expectEqualStrings("Malgun Gothic", none[0]);

    // 사용자 항목이 앞에 온다. 쉼표로 갈리고 앞뒤 공백은 다듬되 내부 공백은 보존한다(config 계약).
    const some = fallbackCandidates("D2Coding ,  Segoe UI Emoji ", "Cascadia Mono", &buf);
    try testing.expectEqualStrings("D2Coding", some[0]);
    try testing.expectEqualStrings("Segoe UI Emoji", some[1]);
    // 사용자가 먼저 적은 것을 티어가 다시 넣지 않는다 — 같은 폰트를 두 번 열 이유가 없다.
    var emoji_count: usize = 0;
    for (some) |n| if (std.ascii.eqlIgnoreCase(n, "Segoe UI Emoji")) {
        emoji_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), emoji_count);
}

test "fallbackCandidates: 주 폰트와 빈 항목은 폴백에 안 들어간다" {
    var buf: [max_faces][]const u8 = undefined;

    // 주 폰트를 폴백으로 다시 물어보면 낭비이고 진단이 헷갈린다(대소문자 무시).
    const dup = fallbackCandidates("malgun gothic", "Malgun Gothic", &buf);
    for (dup) |n| try testing.expect(!std.ascii.eqlIgnoreCase(n, "Malgun Gothic"));
    try testing.expectEqual(@as(usize, windows_fallback_tier.len - 1), dup.len);

    // 빈 항목·공백 항목은 버린다 — `font.fallback = A, , B` 같은 값이 실제로 온다.
    const holes = fallbackCandidates(" , ,  ", "Cascadia Mono", &buf);
    try testing.expectEqual(@as(usize, windows_fallback_tier.len), holes.len);
    for (holes) |n| try testing.expect(n.len > 0);

    // 항목이 넘쳐도 버퍼를 넘지 않는다 — 무한히 face를 열지 않는다는 규칙이다.
    const many = fallbackCandidates("a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p", "X", &buf);
    try testing.expect(many.len <= max_faces);
}

test "cellMetricsFrom: 올림하고 최소 1을 지킨다" {
    // **Cascadia Mono의 실측 디자인 단위다** — 스모크가 `design_units`로 보고한 값을 그대로 박았다
    // (upem 2048, ascent 1900, descent 480, line_gap 0, 'M' advance 1200). 18px에서 셀 11×21·베이스라인
    // 17이 나오고, 그것이 실기 캡처의 `cell_px`와 일치한다. 값을 추측해 넣으면 결과가 우연히 맞아도
    // 테스트가 무엇을 고정하는지 알 수 없다.
    const m = cellMetricsFrom(2048, 1900, 480, 0, 1200, 18.0).?;
    try testing.expectEqual(@as(u32, 11), m.width_px);
    try testing.expectEqual(@as(u32, 21), m.height_px);
    try testing.expectEqual(@as(u32, 17), m.baseline_px);

    // **올림이 규칙이다.** 딱 맞는 값보다 조금 큰 폭은 한 픽셀 올라가야 한다 — 내림하면 글리프가 옆 칸을
    // 침범한다. upem 1000·advance 501·em 10 → 5.01px → 6.
    const up = cellMetricsFrom(1000, 800, 200, 0, 501, 10.0).?;
    try testing.expectEqual(@as(u32, 6), up.width_px);

    // 아주 작은 크기에서도 0이 나오지 않는다 — 0이면 아틀라스 슬롯이 0바이트가 된다.
    const tiny = cellMetricsFrom(2048, 1900, 483, 0, 1233, 0.01).?;
    try testing.expectEqual(@as(u32, 1), tiny.width_px);
    try testing.expectEqual(@as(u32, 1), tiny.height_px);
    try testing.expectEqual(@as(u32, 1), tiny.baseline_px);

    // 음수 `line_gap`인 폰트가 실제로 있다 — 높이가 0이나 음수로 접히면 안 된다.
    const neg = cellMetricsFrom(1000, 800, 200, -2000, 1000, 10.0).?;
    try testing.expectEqual(@as(u32, 1), neg.height_px);

    // upem 0은 망가진 폰트다 — 0으로 나누지 않고 null을 준다.
    try testing.expect(cellMetricsFrom(0, 1900, 483, 0, 1233, 18.0) == null);
}

test "grayFromClearType: 서브픽셀 셋을 커버리지 하나로 접는다" {
    try testing.expectEqual(@as(u8, 0), grayFromClearType(0, 0, 0));
    try testing.expectEqual(@as(u8, 255), grayFromClearType(255, 255, 255));
    // 한 채널만 켜져 있으면 3분의 1 — 서브픽셀 경계가 회색으로 남는다(계단이 아니라).
    try testing.expectEqual(@as(u8, 85), grayFromClearType(255, 0, 0));
    try testing.expectEqual(@as(u8, 85), grayFromClearType(0, 0, 255));
    // **u8로 더하면 넘친다.** 255×3 = 765이라 u32에서 더해야 한다 — 이 단언이 그 회귀를 잡는다.
    try testing.expectEqual(@as(u8, 170), grayFromClearType(255, 255, 0));
}

test "scratchSize: 셀보다 큰 글리프도 담을 만큼 잡는다" {
    // 셀 크기 그대로 잡으면 악센트·CJK가 넘칠 때 `CreateAlphaTexture`가 실패한다.
    try testing.expect(Rasterizer.scratchSize(8, 16) > @as(usize, 8) * 16 * 3);
    // 셀이 0이어도 0을 돌려주고 터지지 않는다(호출자가 0으로 부를 수 있다).
    try testing.expectEqual(@as(usize, 0), Rasterizer.scratchSize(0, 16));
}

test "번들 폰트: 시스템에 없어도 컬렉션에서 이름으로 찾힌다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var factory_raw: ?*anyopaque = null;
    try check(DWriteCreateFactory(factory_type_shared, &IID_IDWriteFactory, &factory_raw), error.CreateFactoryFailed);
    defer d3d11.releaseOpt(factory_raw);
    const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));

    const coll = Rasterizer.createBundledCollection(factory) orelse {
        std.debug.print("\n  번들 컬렉션을 못 만들었다 — assets/fonts 를 못 찾은 것이다\n", .{});
        return error.TestUnexpectedResult;
    };
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(coll)));

    // `Jetendard` 는 배포판이 없어 시스템에 설치될 일이 없는 **번들 전용** 폰트다. 그래서 이 하나로
    // "번들 경로가 실제로 도는가" 를 판정할 수 있다.
    const jet = Rasterizer.resolveFace(coll, "Jetendard") orelse return error.TestUnexpectedResult;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(jet)));

    // **null 이 아닌 것만으로는 부족하다.** face 종류를 틀리면 `CreateFontFace` 가 실패하지 않고
    // 반쪽짜리 face 를 준다 — 적대적 검증의 변이(`TRUETYPE`→`CFF`)가 이 테스트를 그냥 통과했다.
    // 그래서 `Rasterizer.create` 가 실제로 쓰는 값까지 본다.
    try std.testing.expect(Rasterizer.faceIsUsable(jet, true));
    var fm: FontMetrics = undefined;
    jet.vtable.GetMetrics(jet, &fm);
    try std.testing.expect(fm.design_units_per_em > 0);

    // **대조군 ⑴**: 이 컬렉션에는 **번들만** 있다. 시스템 폰트가 여기서 나오면 컬렉션이 아니라 시스템을
    // 보고 있는 것이다 — 그러면 위 성공이 아무것도 증명하지 못한다.
    try std.testing.expect(Rasterizer.resolveFace(coll, "Malgun Gothic") == null);
    try std.testing.expect(Rasterizer.resolveFace(coll, "") == null);

    // **대조군 ⑵**: 번들 다섯이 전부 들어 있어야 한다. 하나라도 빠지면 그 폰트를 고른 사용자가
    // 조용히 시스템 폰트로 내려간다.
    for (maru.config.theme.bundled_fonts) |bf| {
        const f = Rasterizer.resolveFace(coll, bf.family) orelse {
            std.debug.print("\n  번들 컬렉션에 \"{s}\" 가 없다\n", .{bf.family});
            return error.TestUnexpectedResult;
        };
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
        try std.testing.expect(Rasterizer.faceIsUsable(f, true));
    }

    // **대조군 ⑶**: 없는 파일은 실패해야 한다. `CreateFontFileReference` 는 경로를 받아 두기만 하고
    // `hr=0` 을 주므로, 거기서 성공을 판정하면 **없는 폰트가 열린 것처럼 보인다**.
    try std.testing.expect(Rasterizer.openFaceFromFile(factory, "assets/fonts/NoSuchFont/NoSuchFont-Regular.ttf") == null);
}

test "번들 Jetendard: 한글 advance 가 라틴의 정확히 2배다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var factory_raw: ?*anyopaque = null;
    try check(DWriteCreateFactory(factory_type_shared, &IID_IDWriteFactory, &factory_raw), error.CreateFactoryFailed);
    defer d3d11.releaseOpt(factory_raw);
    const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));

    const coll = Rasterizer.createBundledCollection(factory) orelse return error.TestUnexpectedResult;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(coll)));
    const face = Rasterizer.resolveFace(coll, "Jetendard") orelse return error.TestUnexpectedResult;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(face)));

    // **이 성질이 이 슬라이스의 존재 이유다.** 한글이 라틴 2 칸에 맞으려면 advance 가 정확히 2 배여야
    // 한다. 폰트를 바꾸면(또는 번들을 갱신하면) 여기서 걸린다 — 화면에서만 드러나는 부류를 막는다.
    const cps = [_]u32{ 'M', 0xd55c };
    var gids: [2]u16 = undefined;
    try check(face.vtable.GetGlyphIndices(face, &cps, 2, &gids), error.MetricsFailed);
    try std.testing.expect(gids[0] != 0);
    try std.testing.expect(gids[1] != 0); // 한글 글리프가 있어야 폴백으로 의미가 있다
    var gm: [2]GlyphMetrics = undefined;
    try check(face.vtable.GetDesignGlyphMetrics(face, &gids, 2, &gm, 0), error.MetricsFailed);
    try std.testing.expectEqual(gm[0].advance_width * 2, gm[1].advance_width);
}

test "Rasterizer: config 기본값이 번들 폰트로 해석된다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const theme = maru.config.theme;
    const defaults = theme.FontConfig{};

    var r = try Rasterizer.create(std.testing.allocator, defaults.family, defaults.fallback, 14.0);
    defer r.destroy();

    // 주 폰트가 기본값 그대로여야 한다. 예전에는 번들을 못 열어 티어의 `Cascadia Mono` 로 내려갔다.
    try std.testing.expectEqualStrings(defaults.family, r.family);
    // 폴백도 열렸어야 한다 — 주 face + 최소 1 개.
    try std.testing.expect(r.face_count >= 2);

    // 한글이 **주 폰트에는 없고** 폴백 어딘가에는 있어야 한다. 그래야 폴백이 실제로 쓰인다.
    const han = [_]u32{0xd55c};
    var gid: [1]u16 = undefined;
    const primary = r.faces[0].?;
    try check(primary.vtable.GetGlyphIndices(primary, &han, 1, &gid), error.MetricsFailed);
    try std.testing.expectEqual(@as(u16, 0), gid[0]); // JetBrains Mono 에는 한글이 없다

    var found = false;
    for (r.faces[1..r.face_count]) |maybe| {
        const f = maybe orelse continue;
        var g: [1]u16 = undefined;
        if (d3d11.failed(f.vtable.GetGlyphIndices(f, &han, 1, &g))) continue;
        if (g[0] != 0) found = true;
    }
    try std.testing.expect(found);
}

test "폴백 티어: 설치된 폰트가 느슨한 검사를 통과한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var factory_raw: ?*anyopaque = null;
    try check(DWriteCreateFactory(factory_type_shared, &IID_IDWriteFactory, &factory_raw), error.CreateFactoryFailed);
    defer d3d11.releaseOpt(factory_raw);
    const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_raw.?));
    var coll: ?*IDWriteFontCollection = null;
    try check(factory.vtable.GetSystemFontCollection(factory, &coll, 0), error.NoFontFound);
    const c = coll orelse return error.SkipZigTest;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(c)));

    // **폴백은 느슨하게 본다**(`faceIsUsable` doc). 이 루프가 그 규약을 지킨다 — 티어에 라틴 없는
    // 폰트(이모지·기호 전용)를 넣어도 조용히 버려지지 않아야 한다.
    var checked: usize = 0;
    for (windows_fallback_tier) |name| {
        const f = Rasterizer.resolveFace(c, name) orelse continue; // 이 기계에 없으면 건너뛴다
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
        checked += 1;
        try std.testing.expect(Rasterizer.faceIsUsable(f, false));
    }
    // 하나도 못 봤으면 이 테스트가 아무것도 안 지킨 것이다.
    try std.testing.expect(checked > 0);
}
