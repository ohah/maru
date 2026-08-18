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
        GetFontCount: *const anyopaque,
        GetFont: *const anyopaque,
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
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
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
const cleartype_bytes_per_pixel: usize = 3;

extern "dwrite" fn DWriteCreateFactory(factory_type: UINT, iid: *const d3d11.GUID, out: *?*anyopaque) callconv(abi.winapi) HRESULT;

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

/// DirectWrite로 글리프를 그리는 래스터라이저. 중립 계약(`renderer/glyph_raster.zig`의 덕 타이핑
/// `rasterize`)에 맞출 수 있도록 **코드포인트 하나 → RGBA8 버퍼 하나**를 하는 함수를 노출한다.
pub const Rasterizer = struct {
    factory: *IDWriteFactory,
    /// 주 폰트가 `faces[0]`, 그 뒤가 폴백 순서다. **글리프가 없으면 다음 face로 내려간다.**
    faces: [max_faces]?*IDWriteFontFace = @splat(null),
    face_count: usize = 0,
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
        defer d3d11.releaseOpt(collection);

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

        var chosen: []const u8 = "";
        for (candidates) |name| {
            if (resolveFace(collection.?, name)) |f| {
                self.faces[0] = f;
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
            if (resolveFace(collection.?, name)) |f| {
                self.faces[self.face_count] = f;
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
        if (bytes_per_row < @as(usize, cell_w) * 4) return error.BufferTooSmall;
        if (pixels.len < bytes_per_row * cell_h) return error.BufferTooSmall;
        if (choice.face_index >= self.face_count) return error.FontFaceFailed;
        const use_face = self.faces[choice.face_index] orelse return error.FontFaceFailed;
        var glyph = [_]u16{choice.glyph_id};

        const run = GlyphRun{
            .font_face = use_face,
            .font_em_size = self.em_size_px,
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
