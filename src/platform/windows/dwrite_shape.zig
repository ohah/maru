//! 크롬 텍스트 **셰이핑 다리** — Windows. macOS 의 `maru_macos_coretext_shape_chrome_text` 짝이다.
//!
//! 사이드바·pane·소스 컨트롤·에이전트 도크가 이 함수 하나에 막혀 있었다(§2m.13). 그쪽은 CoreText 의
//! `CTLine` 한 줄이 셰이핑·폰트 폴백·말줄임을 다 하는데, DirectWrite 는 그 층이 고수준
//! (`IDWriteTextLayout`)과 저수준(`IDWriteTextAnalyzer`)으로 갈라져 있다. **고수준을 고른 이유와 실측은
//! docs/windows-platform.md §2m.13 이 소유한다.**
//!
//! ## 이 파일이 지키는 세 가지
//!
//! **⑴ 폴백 목록은 우리가 준다.** `dwrite_font.fallbackCandidates` 가 Windows 폴백 순서의 단일 출처이고
//! (사용자 CSV 앞, `windows_fallback_tier` 뒤), 그것을 `IDWriteFontFallbackBuilder` 로 layout 에 박는다.
//! 안 박으면 DirectWrite 가 시스템에서 제멋대로 골라 **터미널과 크롬이 다른 폰트를 쓴다**(§2m.13).
//!
//! **⑵ 번들 폰트는 컬렉션으로 준다.** layout 은 폰트를 **이름으로 컬렉션에서** 찾으므로 파일에서 연
//! face 만으로는 못 쓴다(§2m.15). `Rasterizer.createBundledCollection` 이 만든 것을 그대로 쓴다.
//!
//! **⑶ 슬롯은 comptime 에 못 박는다.** 이 파일이 부르는 vtable 슬롯을 다섯 번 틀렸고(§2m.12·§2m.13),
//! 그중 하나는 **엉뚱한 함수가 `hr=0` 을 돌려줘 성공처럼 보였다**(`SetFontFallback` 을 부른 줄 알았는데
//! `SetCharacterSpacing` 이었다 — 자간만 바뀌고 폴백은 안 걸렸다). assert 가 없으면 런타임 신호가
//! 나쁘다: 크래시거나 조용한 오답이다.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const d3d11 = @import("d3d11.zig");
const dwrite_font = @import("dwrite_font.zig");
const maru = @import("../../maru.zig");
/// **타입은 이음매가 소유한다**(`text_shaper.zig`). 두 곳에 적으면 필드가 갈린다.
const seam = @import("../../text_shaper.zig");

const HRESULT = i32;
const UINT = u32;
const BOOL = i32;

pub const Error = error{
    UnsupportedPlatform,
    CreateFactoryFailed,
    FallbackFailed,
    FormatFailed,
    LayoutFailed,
    DrawFailed,
    /// `anchor = .tail`(앞을 잘라 `…` 를 앞에 둔다)은 DirectWrite 에 없다 — 손으로 잘라야 한다.
    /// **조용히 뒤를 자르지 않는다**: 입력 줄은 caret 이 끝에 있어 앞을 잘라야 방금 친 글자가 보인다
    /// (docs/file-explorer.md §3.5). 뒤를 자르면 사용자가 자기 입력을 못 본다.
    UnsupportedHeadTrim,
    OutOfMemory,
};

/// 마지막 COM 실패의 `HRESULT`. 오류만으로는 어디서 틀렸는지 모른다(다른 Windows 모듈과 같은 규약).
var last_hresult_value: HRESULT = 0;
pub fn lastHresult() HRESULT {
    return last_hresult_value;
}

fn check(hr: HRESULT, e: Error) Error!void {
    if (hr < 0) {
        last_hresult_value = hr;
        return e;
    }
}

// ── 중립 출력 ────────────────────────────────────────────────────────────────────────────────

pub const GlyphRecord = seam.GlyphRecord;
pub const Request = seam.Request;

pub const ShapeResult = struct { count: usize = 0, overflow: bool = false, primary_found: bool = false };

// ── COM 선언 ─────────────────────────────────────────────────────────────────────────────────

const IID_IDWriteFactory2 = d3d11.GUID{
    .data1 = 0x0439fc60,
    .data2 = 0xca44,
    .data3 = 0x4994,
    .data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec },
};
const IID_IDWriteTextFormat1 = d3d11.GUID{
    .data1 = 0x5f174b49,
    .data2 = 0x0d8b,
    .data3 = 0x4cfb,
    .data4 = .{ 0x8b, 0xca, 0xf1, 0xcc, 0xe9, 0xd0, 0x6c, 0x67 },
};
const IID_IUnknown = d3d11.GUID{
    .data1 = 0,
    .data2 = 0,
    .data3 = 0,
    .data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 },
};
const IID_IDWritePixelSnapping = d3d11.GUID{
    .data1 = 0xeaf3a2da,
    .data2 = 0xecf4,
    .data3 = 0x4d24,
    .data4 = .{ 0xb6, 0x44, 0xb3, 0x4f, 0x68, 0x42, 0x02, 0x4b },
};
const IID_IDWriteTextRenderer = d3d11.GUID{
    .data1 = 0xef8a8135,
    .data2 = 0x5cc6,
    .data3 = 0x45fe,
    .data4 = .{ 0x88, 0x25, 0xc5, 0xa0, 0x72, 0x4e, 0xb8, 0x19 },
};

fn guidEql(a: *const d3d11.GUID, b: *const d3d11.GUID) bool {
    return a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and std.mem.eql(u8, &a.data4, &b.data4);
}

const UnicodeRange = extern struct { first: u32, last: u32 };

const GlyphRun = extern struct {
    font_face: ?*anyopaque,
    font_em_size: f32,
    glyph_count: u32,
    glyph_indices: ?[*]const u16,
    glyph_advances: ?[*]const f32,
    /// `DWRITE_GLYPH_OFFSET*` — 배열이지만 opaque 라 **한 겹 포인터**로 받는다(indexable opaque 금지).
    glyph_offsets: ?*const anyopaque,
    is_sideways: BOOL,
    bidi_level: UINT,
};

const GlyphRunDescription = extern struct {
    locale_name: ?[*:0]const u16,
    string: ?[*]const u16,
    string_length: UINT,
    cluster_map: ?[*]const u16,
    text_position: UINT,
};

const Trimming = extern struct { granularity: UINT, delimiter: UINT, delimiter_count: UINT };
const GlyphMetrics = extern struct {
    left_side_bearing: i32,
    advance_width: u32,
    right_side_bearing: i32,
    top_side_bearing: i32,
    advance_height: u32,
    bottom_side_bearing: i32,
    vertical_origin_y: i32,
};
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

/// `IDWriteFactory2`. 이 파일이 부르는 것은 **폴백 빌더 하나**다(슬롯 27).
/// 유도: `IDWriteFactory` 24(0..23 — `dwrite_font` 의 assert 가 소유) + Factory1 2(24,25) +
/// Factory2 의 `GetSystemFontFallback`(26) → `CreateFontFallbackBuilder`(27). §2m.12 가 26 을 실측했다.
const IDWriteFactory2 = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [26]*const anyopaque,
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*anyopaque) callconv(abi.winapi) HRESULT,
        CreateFontFallbackBuilder: *const fn (*IDWriteFactory2, *?*IDWriteFontFallbackBuilder) callconv(abi.winapi) HRESULT,
    };
};

const IDWriteFontFallbackBuilder = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [3]*const anyopaque,
        AddMapping: *const fn (
            *IDWriteFontFallbackBuilder,
            [*]const UnicodeRange,
            UINT,
            [*]const [*:0]const u16,
            UINT,
            ?*anyopaque, // IDWriteFontCollection — null 이면 시스템
            ?[*:0]const u16, // localeName
            ?[*:0]const u16, // baseFamilyName
            f32, // scale
        ) callconv(abi.winapi) HRESULT,
        /// 시스템 폴백을 **뒤에** 잇는다 — 우리 목록에 없는 글자가 여기로 간다.
        AddMappings: *const fn (*IDWriteFontFallbackBuilder, *anyopaque) callconv(abi.winapi) HRESULT,
        CreateFontFallback: *const fn (*IDWriteFontFallbackBuilder, *?*anyopaque) callconv(abi.winapi) HRESULT,
    };
};

/// `IDWriteTextFormat`(0..27) 뒤 Format1: SetVerticalGlyphOrientation(28) Get(29)
/// SetLastLineWrapping(30) Get(31) SetOpticalAlignment(32) Get(33) **SetFontFallback(34)**.
const IDWriteTextFormat1 = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [34]*const anyopaque,
        SetFontFallback: *const fn (*IDWriteTextFormat1, *anyopaque) callconv(abi.winapi) HRESULT,
    };
};

/// 이 파일이 쓰는 `IDWriteTextFormat` 슬롯 둘.
const IDWriteTextFormat = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [5]*const anyopaque,
        SetWordWrapping: *const fn (*IDWriteTextFormat, UINT) callconv(abi.winapi) HRESULT,
        mid: [3]*const anyopaque,
        SetTrimming: *const fn (*IDWriteTextFormat, *const Trimming, ?*anyopaque) callconv(abi.winapi) HRESULT,
        rest: [18]*const anyopaque,
    };
};

/// `Draw` 는 58. **그 뒤에도 여덟이 더 있어 이 인터페이스는 67 슬롯(0..66)** 이다 — 58 로 끝난다고
/// 세었다가 `IDWriteTextLayout2.SetFontFallback` 을 9 칸 앞에서 불러 `SetCharacterSpacing` 을 실행했다.
const IDWriteTextLayout = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [58]*const anyopaque,
        Draw: *const fn (*IDWriteTextLayout, ?*anyopaque, *TextRenderer, f32, f32) callconv(abi.winapi) HRESULT,
        tail: [8]*const anyopaque,
    };
};

const IDWriteFontFace = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [8]*const anyopaque,
        GetMetrics: *const fn (*IDWriteFontFace, *FontMetrics) callconv(abi.winapi) void,
        GetGlyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const fn (*IDWriteFontFace, [*]const u16, UINT, [*]GlyphMetrics, BOOL) callconv(abi.winapi) HRESULT,
        GetGlyphIndices: *const anyopaque,
        TryGetFontTable: *const fn (*IDWriteFontFace, UINT, *?*const anyopaque, *UINT, *?*anyopaque, *BOOL) callconv(abi.winapi) HRESULT,
        ReleaseFontTable: *const fn (*IDWriteFontFace, *anyopaque) callconv(abi.winapi) void,
    };
};

const IDWriteFontCollection = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [6]*const anyopaque,
        GetFontFromFontFace: *const fn (*IDWriteFontCollection, *anyopaque, *?*IDWriteFont) callconv(abi.winapi) HRESULT,
    };
};
const IDWriteFont = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [3]*const anyopaque,
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(abi.winapi) HRESULT,
    };
};
const IDWriteFontFamily = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [6]*const anyopaque,
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(abi.winapi) HRESULT,
    };
};
const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [7]*const anyopaque,
        GetStringLength: *const fn (*IDWriteLocalizedStrings, UINT, *UINT) callconv(abi.winapi) HRESULT,
        GetString: *const fn (*IDWriteLocalizedStrings, UINT, [*]u16, UINT) callconv(abi.winapi) HRESULT,
    };
};

comptime {
    if (@sizeOf(usize) == 8) {
        const slot = struct {
            fn at(comptime T: type, comptime name: []const u8) usize {
                return @offsetOf(T, name) / 8;
            }
        };
        // **다섯 번 틀린 자리다.** 하나는 엉뚱한 함수가 `hr=0` 을 돌려줘 성공처럼 보였다(§2m.13).
        std.debug.assert(slot.at(IDWriteFactory2.VTable, "GetSystemFontFallback") == 26);
        std.debug.assert(slot.at(IDWriteFactory2.VTable, "CreateFontFallbackBuilder") == 27);
        std.debug.assert(slot.at(IDWriteFontFallbackBuilder.VTable, "AddMapping") == 3);
        std.debug.assert(slot.at(IDWriteFontFallbackBuilder.VTable, "CreateFontFallback") == 5);
        std.debug.assert(slot.at(IDWriteTextFormat1.VTable, "SetFontFallback") == 34);
        std.debug.assert(slot.at(IDWriteTextFormat.VTable, "SetWordWrapping") == 5);
        std.debug.assert(slot.at(IDWriteTextFormat.VTable, "SetTrimming") == 9);
        std.debug.assert(slot.at(IDWriteTextLayout.VTable, "Draw") == 58);
        // `IDWriteTextLayout` 은 67 슬롯이다 — 이 크기가 곧 Layout1/2 슬롯 계산의 바닥이다.
        std.debug.assert(@sizeOf(IDWriteTextLayout.VTable) / 8 == 67);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "GetMetrics") == 8);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "GetDesignGlyphMetrics") == 10);
        std.debug.assert(slot.at(IDWriteFontFace.VTable, "TryGetFontTable") == 12);
        std.debug.assert(slot.at(IDWriteFontCollection.VTable, "GetFontFromFontFace") == 6);
        std.debug.assert(slot.at(IDWriteFont.VTable, "GetFontFamily") == 3);
        std.debug.assert(slot.at(IDWriteFontFamily.VTable, "GetFamilyNames") == 6);
        std.debug.assert(slot.at(IDWriteLocalizedStrings.VTable, "GetString") == 8);
    }
}

const word_wrapping_no_wrap: UINT = 1;
const trimming_granularity_character: UINT = 1;

extern "dwrite" fn DWriteCreateFactory(kind: UINT, iid: *const d3d11.GUID, out: *?*anyopaque) callconv(abi.winapi) HRESULT;

// ── 우리가 구현하는 COM: IDWriteTextRenderer ─────────────────────────────────────────────────

/// 한 번의 `Draw` 가 모으는 것. 런은 최대 `max_runs` 개까지만 본다 — 크롬 한 줄이 그보다 잘게 쪼개지면
/// 폰트 폴백이 이상한 것이라 잘라도 화면이 크게 안 다르다.
const max_runs = 32;

const RunInfo = struct {
    face: ?*IDWriteFontFace = null,
    baseline_x: f32 = 0,
    glyph_start: usize = 0,
    glyph_count: usize = 0,
    text_position: u32 = 0,
    string_length: u32 = 0,
};

const Collector = struct {
    runs: [max_runs]RunInfo = @splat(.{}),
    run_count: usize = 0,
    /// 글리프 평면 배열 — 런들이 이 안의 구간을 가리킨다.
    glyph_ids: [512]u16 = @splat(0),
    advances: [512]f32 = @splat(0),
    /// 글리프마다의 코드포인트(런 서술자의 `clusterMap` 에서 역산).
    codepoints: [512]u32 = @splat(0),
    glyph_total: usize = 0,
    overflow: bool = false,
};

const TextRenderer = extern struct {
    vtable: *const VTable,
    collector: *Collector,

    const VTable = extern struct {
        QueryInterface: *const fn (*TextRenderer, *const d3d11.GUID, *?*anyopaque) callconv(abi.winapi) HRESULT,
        AddRef: *const fn (*TextRenderer) callconv(abi.winapi) UINT,
        Release: *const fn (*TextRenderer) callconv(abi.winapi) UINT,
        IsPixelSnappingDisabled: *const fn (*TextRenderer, ?*anyopaque, *BOOL) callconv(abi.winapi) HRESULT,
        GetCurrentTransform: *const fn (*TextRenderer, ?*anyopaque, *[6]f32) callconv(abi.winapi) HRESULT,
        GetPixelsPerDip: *const fn (*TextRenderer, ?*anyopaque, *f32) callconv(abi.winapi) HRESULT,
        DrawGlyphRun: *const fn (*TextRenderer, ?*anyopaque, f32, f32, UINT, *const GlyphRun, ?*const GlyphRunDescription, ?*anyopaque) callconv(abi.winapi) HRESULT,
        DrawUnderline: *const fn (*TextRenderer, ?*anyopaque, f32, f32, *const anyopaque, ?*anyopaque) callconv(abi.winapi) HRESULT,
        DrawStrikethrough: *const fn (*TextRenderer, ?*anyopaque, f32, f32, *const anyopaque, ?*anyopaque) callconv(abi.winapi) HRESULT,
        DrawInlineObject: *const fn (*TextRenderer, ?*anyopaque, f32, f32, ?*InlineObject, BOOL, BOOL, ?*anyopaque) callconv(abi.winapi) HRESULT,
    };

    /// **아무 IID 에나 자기를 주면 안 된다.** DirectWrite 가 다른 인터페이스를 묻고 우리가 준 포인터를
    /// 그 인터페이스로 알아 **엉뚱한 vtable 슬롯**으로 뛴다 — `Draw` 가 크래시한다(§2m.13 실측).
    /// 증상이 슬롯 실수와 구분되지 않아 한참 그쪽을 뒤졌다.
    fn queryInterface(self: *TextRenderer, iid: *const d3d11.GUID, out: *?*anyopaque) callconv(abi.winapi) HRESULT {
        if (guidEql(iid, &IID_IUnknown) or guidEql(iid, &IID_IDWritePixelSnapping) or guidEql(iid, &IID_IDWriteTextRenderer)) {
            out.* = self;
            return 0;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }
    /// **참조 계수를 안 센다.** 이 객체는 스택에 있고 `Draw` 호출 동안만 산다 — DirectWrite 가 렌더러를
    /// 그 밖으로 들고 가지 않는다는 규약에 기댄다(§2m.12 가 남긴 미정 항목을 여기서 그렇게 정한다).
    fn addRef(_: *TextRenderer) callconv(abi.winapi) UINT {
        return 1;
    }
    fn release(_: *TextRenderer) callconv(abi.winapi) UINT {
        return 1;
    }
    fn snappingDisabled(_: *TextRenderer, _: ?*anyopaque, out: *BOOL) callconv(abi.winapi) HRESULT {
        out.* = 0;
        return 0;
    }
    fn currentTransform(_: *TextRenderer, _: ?*anyopaque, out: *[6]f32) callconv(abi.winapi) HRESULT {
        out.* = .{ 1, 0, 0, 1, 0, 0 };
        return 0;
    }
    fn pixelsPerDip(_: *TextRenderer, _: ?*anyopaque, out: *f32) callconv(abi.winapi) HRESULT {
        out.* = 1;
        return 0;
    }

    fn drawGlyphRun(
        self: *TextRenderer,
        _: ?*anyopaque,
        baseline_x: f32,
        _: f32,
        _: UINT,
        run: *const GlyphRun,
        desc: ?*const GlyphRunDescription,
        _: ?*anyopaque,
    ) callconv(abi.winapi) HRESULT {
        const c = self.collector;
        if (c.run_count >= max_runs) {
            c.overflow = true;
            return 0;
        }
        const n = run.glyph_count;
        if (c.glyph_total + n > c.glyph_ids.len) {
            c.overflow = true;
            return 0;
        }
        const start = c.glyph_total;
        const ids = run.glyph_indices orelse return 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            c.glyph_ids[start + i] = ids[i];
            c.advances[start + i] = if (run.glyph_advances) |a| a[i] else 0;
            c.codepoints[start + i] = 0;
        }
        // **글리프 → 코드포인트**는 `clusterMap` 을 뒤집어 얻는다. 그 배열은 **문자 기준**이라
        // (`clusterMap[문자] = 글리프`) 같은 글리프를 가리키는 첫 문자를 그 글리프의 대표로 삼는다 —
        // 합자(`->` 가 두 글리프)와 서러게이트 쌍(이모지가 두 칸 한 글리프)이 그렇게 접힌다.
        if (desc) |d| {
            if (d.cluster_map) |cm| {
                if (d.string) |str| {
                    var t: usize = 0;
                    while (t < d.string_length) : (t += 1) {
                        const g = cm[t];
                        if (g >= n) continue;
                        if (c.codepoints[start + g] != 0) continue; // 첫 문자만
                        c.codepoints[start + g] = decodeUtf16At(str, d.string_length, t);
                    }
                }
            }
        }
        c.runs[c.run_count] = .{
            .face = if (run.font_face) |f| @ptrCast(@alignCast(f)) else null,
            .baseline_x = baseline_x,
            .glyph_start = start,
            .glyph_count = n,
            .text_position = if (desc) |d| d.text_position else 0,
            .string_length = if (desc) |d| d.string_length else 0,
        };
        c.run_count += 1;
        c.glyph_total += n;
        return 0;
    }

    fn drawUnderline(_: *TextRenderer, _: ?*anyopaque, _: f32, _: f32, _: *const anyopaque, _: ?*anyopaque) callconv(abi.winapi) HRESULT {
        return 0;
    }
    fn drawStrikethrough(_: *TextRenderer, _: ?*anyopaque, _: f32, _: f32, _: *const anyopaque, _: ?*anyopaque) callconv(abi.winapi) HRESULT {
        return 0;
    }
    /// **말줄임 기호가 여기로 온다.** 되돌려 그 객체의 `Draw` 를 부르지 않으면 글리프가 안 나온다 —
    /// 콜백은 객체만 주고 글리프는 안 준다. 그러면 **말줄임 기호만 안 그려지는** 조용한 결함이 된다.
    fn drawInlineObject(self: *TextRenderer, ctx: ?*anyopaque, x: f32, y: f32, obj: ?*InlineObject, sideways: BOOL, rtl: BOOL, effect: ?*anyopaque) callconv(abi.winapi) HRESULT {
        const o = obj orelse return 0;
        _ = o.vtable.Draw(o, ctx, self, x, y, sideways, rtl, effect);
        return 0;
    }

    const instance = VTable{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .IsPixelSnappingDisabled = snappingDisabled,
        .GetCurrentTransform = currentTransform,
        .GetPixelsPerDip = pixelsPerDip,
        .DrawGlyphRun = drawGlyphRun,
        .DrawUnderline = drawUnderline,
        .DrawStrikethrough = drawStrikethrough,
        .DrawInlineObject = drawInlineObject,
    };
};

/// 말줄임 기호가 이것으로 온다. `Draw` 는 슬롯 3.
const InlineObject = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [3]*const anyopaque,
        Draw: *const fn (*InlineObject, ?*anyopaque, *TextRenderer, f32, f32, BOOL, BOOL, ?*anyopaque) callconv(abi.winapi) HRESULT,
    };
};

/// UTF-16 한 자리에서 코드포인트를 읽는다(서러게이트 쌍은 합친다). 짝 없는 서러게이트는 그대로 준다 —
/// 버리면 그 글리프의 코드포인트가 0 이 되어 호출자가 "빈 글리프" 로 오해한다.
fn decodeUtf16At(s: [*]const u16, len: u32, i: usize) u32 {
    const hi = s[i];
    if (hi >= 0xD800 and hi <= 0xDBFF and i + 1 < len) {
        const lo = s[i + 1];
        if (lo >= 0xDC00 and lo <= 0xDFFF) {
            return 0x10000 + ((@as(u32, hi - 0xD800) << 10) | @as(u32, lo - 0xDC00));
        }
    }
    return hi;
}

// ── 셰이퍼 ───────────────────────────────────────────────────────────────────────────────────

/// 팩토리와 컬렉션을 들고 있는 셰이퍼. **한 번 만들어 재사용한다** — 팩토리·컬렉션 생성은 프레임마다
/// 할 일이 아니다(§2m.15 가 컬렉션을 2ms 로 쟀다).
pub const Shaper = struct {
    allocator: std.mem.Allocator,
    factory: *IDWriteFactory2,
    /// 시스템 폰트 컬렉션(face → 이름 되찾기에 쓴다).
    system: *IDWriteFontCollection,
    /// 번들 폰트만 담은 컬렉션(§2m.15). 없으면 `null` — 시스템 폰트로만 간다.
    bundled: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator) Error!*Shaper {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var raw: ?*anyopaque = null;
        try check(DWriteCreateFactory(0, &IID_IDWriteFactory2, &raw), error.CreateFactoryFailed);
        errdefer d3d11.releaseOpt(raw);
        const factory: *IDWriteFactory2 = @ptrCast(@alignCast(raw orelse return error.CreateFactoryFailed));

        // 시스템 컬렉션은 이 파일의 vtable 로 직접 얻는다(슬롯 3).
        const get_system: *const fn (*IDWriteFactory2, *?*IDWriteFontCollection, BOOL) callconv(abi.winapi) HRESULT =
            @ptrCast(@alignCast(factory.vtable.head[3]));
        var sys_raw: ?*IDWriteFontCollection = null;
        try check(get_system(factory, &sys_raw, 0), error.CreateFactoryFailed);
        errdefer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(sys_raw)));
        const system: *IDWriteFontCollection = sys_raw orelse return error.CreateFactoryFailed;

        const self = allocator.create(Shaper) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .factory = factory,
            .system = system,
            // 번들 컬렉션이 없어도 선다 — 시스템 폰트로만 간다(§2m.15 의 규약).
            .bundled = dwrite_font.createBundledCollectionRaw(raw.?),
        };
        return self;
    }

    pub fn destroy(self: *Shaper) void {
        d3d11.releaseOpt(self.bundled);
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.system)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.factory)));
        self.allocator.destroy(self);
    }

    /// 한 줄을 셰이핑해 `out` 에 채운다.
    pub fn shape(self: *Shaper, req: Request, out: []GlyphRecord) Error!ShapeResult {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (req.text.len == 0) return .{ .primary_found = true };
        // **앞을 자르는 말줄임은 아직 없다.** 조용히 뒤를 자르면 입력 줄에서 사용자가 자기 입력을 못 본다.
        if (req.anchor_tail and req.max_width_px > 0) return error.UnsupportedHeadTrim;

        // **목적지 경계는 우리가 본다.** `std.unicode.utf8ToUtf16Le` 는 dest 를 **검사하지 않는다** —
        // `utf16le[dest_index] = ..` 를 그대로 쓴다. 넘치면 safe 모드에서 패닉이고 ReleaseFast 에서는
        // 스택 밖 쓰기다(적대적 검증에서 std 구현을 읽고 찾았다). 크롬 본문은 에디터 한 줄일 수
        // 있어 1024 는 언제든 넘는다 — **자르지 않고 힙으로 넘어간다.**
        //
        // 바이트 수로 재면 충분하다: UTF-8 1~3 바이트는 UTF-16 1 유닛, 4 바이트는 2 유닛이라
        // 유닛 수가 바이트 수를 넘지 않는다.
        var wide_stack: [1024]u16 = undefined;
        const heap_wide: ?[]u16 = if (req.text.len > wide_stack.len)
            (self.allocator.alloc(u16, req.text.len) catch return error.OutOfMemory)
        else
            null;
        defer if (heap_wide) |h| self.allocator.free(h);
        const wide = heap_wide orelse wide_stack[0..];
        const wlen = std.unicode.utf8ToUtf16Le(wide, req.text) catch return error.OutOfMemory;

        // ── 주 폰트 이름과 컬렉션 ────────────────────────────────────────────────────────────
        var fam_buf: [dwrite_font.max_faces][]const u8 = undefined;
        const primary = blk: {
            // **여기는 크롬 텍스트다 — 빈 family 를 터미널 티어로 떨어뜨리지 않는다.**
            //
            // 계약은 이미 정해져 있다: docs/font-strategy.md "Chrome 텍스트 face" 가 measured 경로도
            // `font.family`(+`font.fallback` cascade)를 쓴다고 못 박았다(사용자 결정 2026-08-08) —
            // 도크와 사이드바가 한 화면에 같이 보이는데 face 가 갈리면 사용자가 고른 폰트를 앱이
            // 절반만 따르는 셈이 되기 때문이다. 그러니 제품 경로에서는 이 값이 비지 않는다.
            //
            // 비는 것은 Chrome Lab·단위 테스트처럼 **resolved appearance 가 없는 호출자**뿐이다.
            // macOS 는 그때 시스템 UI face 로 가고, Windows 는 **번들 기본**으로 간다
            // (사용자 결정 2026-08-22). 시스템 폰트로 가면 설치 환경마다 캡처가 흔들린다.
            const trimmed = std.mem.trim(u8, req.family, " \t");
            if (trimmed.len == 0) break :blk maru.config.theme.bundled_fonts[0].family;
            const cands = dwrite_font.fontCandidates(trimmed, fam_buf[0 .. dwrite_font.windows_font_tier.len + 1]);
            break :blk if (cands.len > 0) cands[0] else "Consolas";
        };
        var primary_w: [128]u16 = undefined;
        // 같은 이유의 경계. **조용히 자르지 않는다** — 자른 이름은 다른 폰트를 찾거나 못 찾는다.
        if (primary.len >= primary_w.len) return error.FormatFailed;
        const pw = std.unicode.utf8ToUtf16Le(primary_w[0 .. primary_w.len - 1], primary) catch return error.FormatFailed;
        primary_w[pw] = 0;
        // 번들 폰트면 그 컬렉션을 준다 — 시스템 컬렉션에는 없어서 layout 이 못 찾는다(§2m.15).
        const primary_bundled = maru.config.theme.bundledRegularRelPath(primary) != null;
        const format_collection: ?*anyopaque = if (primary_bundled) self.bundled else null;

        // ── 포맷 ─────────────────────────────────────────────────────────────────────────────
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        var fmt_raw: ?*IDWriteTextFormat = null;
        const create_format: *const fn (*IDWriteFactory2, [*:0]const u16, ?*anyopaque, UINT, UINT, UINT, f32, [*:0]const u16, *?*IDWriteTextFormat) callconv(abi.winapi) HRESULT =
            @ptrCast(@alignCast(self.factory.vtable.head[15]));
        try check(create_format(self.factory, @ptrCast(&primary_w), format_collection, req.weight, 0, 5, req.size_px, locale, &fmt_raw), error.FormatFailed);
        const fmt = fmt_raw orelse return error.FormatFailed;
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(fmt)));

        // **줄바꿈을 끈다.** 크롬 텍스트는 한 줄이고, 말줄임은 `NO_WRAP` 일 때만 일어난다(§2m.13).
        _ = fmt.vtable.SetWordWrapping(fmt, word_wrapping_no_wrap);

        // ── 폴백 목록을 박는다 ───────────────────────────────────────────────────────────────
        try self.attachFallback(fmt, primary, req.fallback_csv);

        // ── 말줄임 ───────────────────────────────────────────────────────────────────────────
        var sign: ?*anyopaque = null;
        defer d3d11.releaseOpt(sign);
        if (req.max_width_px > 0) {
            const create_sign: *const fn (*IDWriteFactory2, *IDWriteTextFormat, *?*anyopaque) callconv(abi.winapi) HRESULT =
                @ptrCast(@alignCast(self.factory.vtable.head[20]));
            _ = create_sign(self.factory, fmt, &sign);
            const trim = Trimming{ .granularity = trimming_granularity_character, .delimiter = 0, .delimiter_count = 0 };
            _ = fmt.vtable.SetTrimming(fmt, &trim, sign);
        }

        // ── 레이아웃 → Draw ──────────────────────────────────────────────────────────────────
        const create_layout: *const fn (*IDWriteFactory2, [*]const u16, UINT, *IDWriteTextFormat, f32, f32, *?*IDWriteTextLayout) callconv(abi.winapi) HRESULT =
            @ptrCast(@alignCast(self.factory.vtable.head[18]));
        var layout_raw: ?*IDWriteTextLayout = null;
        const width = if (req.max_width_px > 0) req.max_width_px else 1_000_000;
        try check(create_layout(self.factory, wide.ptr, @intCast(wlen), fmt, width, req.size_px * 4, &layout_raw), error.LayoutFailed);
        const layout = layout_raw orelse return error.LayoutFailed;
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(layout)));

        var collector = Collector{};
        var renderer = TextRenderer{ .vtable = &TextRenderer.instance, .collector = &collector };
        try check(layout.vtable.Draw(layout, null, &renderer, 0, 0), error.DrawFailed);

        return self.fill(&collector, req, out, primary_bundled);
    }

    /// `fallbackCandidates` 의 답을 layout 이 볼 수 있게 박는다.
    ///
    /// **format 에 박는다**(`IDWriteTextFormat1`, 슬롯 34). layout 에 박아도(슬롯 78) 되지만, format 은
    /// 한 번 만들어 재사용하므로 런마다 QI 를 안 해도 된다. 둘 다 실측으로 확인했다.
    fn attachFallback(self: *Shaper, fmt: *IDWriteTextFormat, primary: []const u8, fallback_csv: []const u8) Error!void {
        var builder_raw: ?*IDWriteFontFallbackBuilder = null;
        if (d3d11.failed(self.factory.vtable.CreateFontFallbackBuilder(self.factory, &builder_raw))) return;
        const builder = builder_raw orelse return;
        defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(builder)));

        // 전 범위를 후보 순서대로 건다 — CoreText 의 `kCTFontCascadeListAttribute` 와 같은 모양이다.
        const all = [_]UnicodeRange{.{ .first = 0, .last = 0x10FFFF }};
        var fb_buf: [dwrite_font.max_faces][]const u8 = undefined;
        for (dwrite_font.fallbackCandidates(fallback_csv, primary, &fb_buf)) |name| {
            var w: [128]u16 = undefined;
            // 같은 이유의 경계. 폴백 하나가 길다고 나머지까지 버리지는 않는다.
            if (name.len >= w.len) continue;
            const n = std.unicode.utf8ToUtf16Le(w[0 .. w.len - 1], name) catch continue;
            w[n] = 0;
            var names = [_][*:0]const u16{@ptrCast(&w)};
            const coll: ?*anyopaque = if (maru.config.theme.bundledRegularRelPath(name) != null) self.bundled else null;
            _ = builder.vtable.AddMapping(builder, &all, 1, &names, 1, coll, null, null, 1.0);
        }

        // **시스템 폴백을 뒤에 잇는다.** 우리 목록에 없는 글자(아랍어·한자 일부 등)가 여기로 간다.
        // 안 이으면 그 글자들이 전부 `.notdef` 가 된다.
        var sys_fb: ?*anyopaque = null;
        if (!d3d11.failed(self.factory.vtable.GetSystemFontFallback(self.factory, &sys_fb))) {
            if (sys_fb != null) {
                _ = builder.vtable.AddMappings(builder, sys_fb.?);
                d3d11.releaseOpt(sys_fb);
            }
        }

        var fallback: ?*anyopaque = null;
        if (d3d11.failed(builder.vtable.CreateFontFallback(builder, &fallback))) return;
        defer d3d11.releaseOpt(fallback);
        const fb = fallback orelse return;

        const unk: *const *const IUnknownVTable = @ptrCast(@alignCast(fmt));
        var f1_raw: ?*anyopaque = null;
        if (d3d11.failed(unk.*.QueryInterface(@ptrCast(fmt), &IID_IDWriteTextFormat1, &f1_raw))) return;
        const f1: *IDWriteTextFormat1 = @ptrCast(@alignCast(f1_raw orelse return));
        defer d3d11.releaseOpt(f1_raw);
        _ = f1.vtable.SetFontFallback(f1, fb);
    }

    /// 모은 런을 중립 레코드로 옮긴다.
    fn fill(self: *Shaper, c: *const Collector, req: Request, out: []GlyphRecord, primary_bundled: bool) Error!ShapeResult {
        _ = primary_bundled;
        var result = ShapeResult{ .overflow = c.overflow, .primary_found = true };
        if (c.run_count == 0) return result;
        const primary_face = c.runs[0].face;

        var n: usize = 0;
        for (c.runs[0..c.run_count]) |run| {
            const face = run.face orelse continue;
            var name_buf: [128]u8 = @splat(0);
            self.familyName(face, &name_buf);
            const is_color = faceHasColor(face);

            var fm: FontMetrics = undefined;
            face.vtable.GetMetrics(face, &fm);
            const upem: f32 = @floatFromInt(if (fm.design_units_per_em == 0) 1000 else fm.design_units_per_em);

            var metrics: [512]GlyphMetrics = undefined;
            const has_metrics = run.glyph_count <= metrics.len and
                !d3d11.failed(face.vtable.GetDesignGlyphMetrics(face, c.glyph_ids[run.glyph_start..].ptr, @intCast(run.glyph_count), &metrics, 0));

            var x = run.baseline_x;
            var i: usize = 0;
            while (i < run.glyph_count) : (i += 1) {
                if (n >= out.len) {
                    result.overflow = true;
                    result.count = n;
                    return result;
                }
                const adv = c.advances[run.glyph_start + i];
                // ink 가 자기 자리 **왼쪽으로** 넘치는 만큼(합자만 양수).
                const overhang: f32 = if (has_metrics and metrics[i].left_side_bearing < 0)
                    @as(f32, @floatFromInt(-metrics[i].left_side_bearing)) * req.size_px / upem
                else
                    0;
                out[n] = .{
                    .glyph_id = c.glyph_ids[run.glyph_start + i],
                    .codepoint = c.codepoints[run.glyph_start + i],
                    .fallback = run.face != primary_face,
                    .color = is_color,
                    .x_px = x,
                    .advance_px = adv,
                    .left_overhang_px = overhang,
                    .font_name = name_buf,
                };
                x += adv;
                n += 1;
            }
        }
        result.count = n;
        return result;
    }

    /// face 의 가족 이름을 UTF-8 로. **번들 컬렉션을 먼저 본다** — 번들 face 는 시스템 컬렉션에 없어서
    /// `GetFontFromFontFace` 가 `DWRITE_E_NOFONT` 를 낸다(§2m.14 실측).
    fn familyName(self: *Shaper, face: *IDWriteFontFace, out: *[128]u8) void {
        if (self.bundled) |b| {
            const coll: *IDWriteFontCollection = @ptrCast(@alignCast(b));
            if (familyNameFrom(coll, face, out)) return;
        }
        _ = familyNameFrom(self.system, face, out);
    }
};

const IUnknownVTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(abi.winapi) HRESULT,
};

fn familyNameFrom(coll: *IDWriteFontCollection, face: *IDWriteFontFace, out: *[128]u8) bool {
    var font: ?*IDWriteFont = null;
    if (d3d11.failed(coll.vtable.GetFontFromFontFace(coll, @ptrCast(face), &font))) return false;
    const f = font orelse return false;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(f)));
    var family: ?*IDWriteFontFamily = null;
    if (d3d11.failed(f.vtable.GetFontFamily(f, &family))) return false;
    const fam = family orelse return false;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(fam)));
    var names: ?*IDWriteLocalizedStrings = null;
    if (d3d11.failed(fam.vtable.GetFamilyNames(fam, &names))) return false;
    const nm = names orelse return false;
    defer d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(nm)));
    var len: UINT = 0;
    if (d3d11.failed(nm.vtable.GetStringLength(nm, 0, &len))) return false;
    var w: [128]u16 = undefined;
    if (d3d11.failed(nm.vtable.GetString(nm, 0, &w, @min(len + 1, w.len)))) return false;
    const used = std.unicode.utf16LeToUtf8(out, w[0..@min(len, w.len - 1)]) catch return false;
    if (used < out.len) out[used] = 0;
    return true;
}

/// `COLR`/`sbix` 테이블이 있으면 컬러 폰트다 — macOS `maru_font_is_color` 와 **같은 판정**(런 폰트 단위).
/// DirectWrite 태그는 **리틀엔디언 4CC** 라 CoreText 와 바이트 순서가 반대다.
fn faceHasColor(face: *IDWriteFontFace) bool {
    return faceHasTable(face, "COLR") or faceHasTable(face, "sbix");
}

fn faceHasTable(face: *IDWriteFontFace, tag: *const [4]u8) bool {
    const t: UINT = @as(UINT, tag[0]) | (@as(UINT, tag[1]) << 8) | (@as(UINT, tag[2]) << 16) | (@as(UINT, tag[3]) << 24);
    var data: ?*const anyopaque = null;
    var size: UINT = 0;
    var ctx: ?*anyopaque = null;
    var exists: BOOL = 0;
    if (d3d11.failed(face.vtable.TryGetFontTable(face, t, &data, &size, &ctx, &exists))) return false;
    if (ctx) |p| face.vtable.ReleaseFontTable(face, p);
    return exists != 0;
}

test "셰이퍼: 빈 family 는 터미널 티어가 아니라 번들 기본으로 간다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 크롬 텍스트는 계약상 `font.family` 를 쓴다(docs/font-strategy.md "Chrome 텍스트 face").
    // 빈 값은 Lab·테스트 호출자뿐이고, 그때 **터미널 티어(Cascadia Mono)로 떨어지면 안 된다** —
    // 그것은 터미널 폰트지 크롬 폰트가 아니다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    var out: [32]GlyphRecord = undefined;
    const res = try sh.shape(.{ .text = "Agent", .family = "", .fallback_csv = "", .size_px = 16 }, &out);
    try std.testing.expect(res.count > 0);
    const got = std.mem.sliceTo(&out[0].font_name, 0);
    std.debug.print("  [실측] 빈 family -> \"{s}\"", .{got});
    // 값을 손으로 안 적는다 — config 기본값이 바뀌면 함께 움직여야 한다.
    try std.testing.expectEqualStrings(maru.config.theme.bundled_fonts[0].family, got);
}

test "셰이퍼: 1024 유닛을 넘는 줄이 스택을 넘어 쓰지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // **메모리 안전이 판정 대상이다.** 예전엔 고정 `[1024]u16` 에 바로 변환했는데
    // `utf8ToUtf16Le` 는 dest 를 **검사하지 않는다**(실증: 8칸 버퍼에 16자를 주면
    // `index out of bounds: index 16, len 8` 로 패닉한다 — ReleaseFast 였다면 스택 밖 쓰기다).
    // 에디터 한 줄이면 언제든 닿는 길이라 힙으로 넘어가게 고쳤다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    const n = 1600;
    const text = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    const out = try std.testing.allocator.alloc(GlyphRecord, n + 16);
    defer std.testing.allocator.free(out);

    // 여기까지 오는 것 자체가 판정이다 — 고치기 전이면 이 줄에서 패닉했다.
    const res = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, out);
    std.debug.print("  [실측] 긴 줄: 입력 {d}자 -> 글리프 {d} overflow={s}", .{ n, res.count, if (res.overflow) "true" else "false" });

    // **수집기 상한(512 글리프)에서 시끄럽게 선다.** 절단된 개수를 정상처럼 주지 않는다 —
    // 상한을 늘리는 것은 이 슬라이스가 아니라 에디터 표면(W8.3)의 일이다(§2m.18).
    try std.testing.expect(res.overflow);
    try std.testing.expectError(error.ShapeFailed, shapeInto(
        std.testing.allocator,
        .{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 },
        @as([]seam.GlyphRecord, @ptrCast(out)),
    ));
}

test "셰이퍼: 수집기 상한 바로 아래는 한 글자도 안 잃는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 위 테스트의 대조군. 상한 아래에서는 절단이 없다는 것을 함께 못 박아야 "512 에서 선다" 가
    // 성질이 된다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    const n = 500;
    const text = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    const out = try std.testing.allocator.alloc(GlyphRecord, n + 16);
    defer std.testing.allocator.free(out);

    const res = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, out);
    std.debug.print("  [실측] 상한 아래: 입력 {d}자 -> 글리프 {d} overflow={s}", .{ n, res.count, if (res.overflow) "true" else "false" });
    try std.testing.expect(!res.overflow);
    try std.testing.expectEqual(@as(usize, n), res.count);
}

test "셰이퍼: 버퍼보다 긴 폰트 이름을 조용히 자르지 않는다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();
    var long_name: [200]u8 = @splat('A');
    var out: [16]GlyphRecord = undefined;
    // 잘린 이름으로 엉뚱한 폰트를 찾느니 시끄럽게 실패한다.
    try std.testing.expectError(error.FormatFailed, sh.shape(.{
        .text = "x",
        .family = &long_name,
        .fallback_csv = "",
        .size_px = 16,
    }, &out));
}

test "셰이퍼: 버퍼가 모자라면 조용히 자르지 않고 실패한다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // **여기가 글자가 사라지는 자리다.** 넘친 것을 `count` 로만 알리면 호출자는 잘린 줄을 정상으로
    // 받아 그린다. `shapeInto` 는 이음매 앞에서 그것을 오류로 접어야 한다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    const text = "abcdefghijklmnopqrstuvwxyz";
    var big: [64]GlyphRecord = undefined;
    const full = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, &big);
    try std.testing.expect(!full.overflow);
    try std.testing.expect(full.count > 2);

    // 한 칸 모자라게 준다 — 경계 바로 아래.
    var tight: [64]GlyphRecord = undefined;
    const short = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, tight[0 .. full.count - 1]);
    std.debug.print(
        "\n  [실측] 넘침: 넉넉 {d} 글리프 / 한 칸 모자람 → count={d} overflow={s}\n",
        .{ full.count, short.count, if (short.overflow) "true" else "false" },
    );
    try std.testing.expect(short.overflow);

    // 이음매를 거치면 **오류**여야 한다. 절단된 개수가 아니다.
    try std.testing.expectError(
        seam.Error.ShapeFailed,
        shapeInto(std.testing.allocator, .{
            .text = text,
            .family = "Consolas",
            .fallback_csv = "",
            .size_px = 16,
        }, @as([]seam.GlyphRecord, @ptrCast(tight[0 .. full.count - 1]))),
    );
}

test "셰이퍼: 한 줄이 여섯 출력을 채운다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    var out: [64]GlyphRecord = undefined;
    const res = try sh.shape(.{
        .text = "Wi->l \u{d55c}\u{ae00} \u{1f600} tail",
        .family = "JetBrains Mono",
        .fallback_csv = "",
        .size_px = 16,
    }, &out);

    std.debug.print("\n  SHAPE count={d} overflow={s}\n", .{ res.count, if (res.overflow) "true" else "false" });
    try std.testing.expect(!res.overflow);
    try std.testing.expect(res.count > 0);

    var fallback_n: usize = 0;
    var color_n: usize = 0;
    var names_seen: usize = 0;
    var last_name: [128]u8 = @splat(0);
    for (out[0..res.count]) |g| {
        if (g.fallback) fallback_n += 1;
        if (g.color) color_n += 1;
        if (!std.mem.eql(u8, &last_name, &g.font_name)) {
            names_seen += 1;
            last_name = g.font_name;
            const z = std.mem.indexOfScalar(u8, &g.font_name, 0) orelse g.font_name.len;
            std.debug.print("    폰트 바뀜 → \"{s}\"\n", .{g.font_name[0..z]});
        }
    }
    std.debug.print("  SHAPE fallback={d} color={d} 폰트종류={d}\n", .{ fallback_n, color_n, names_seen });
    for (out[0..@min(res.count, 8)]) |g| {
        std.debug.print("    gid={d:<5} cp=U+{X:0>4} x={d:<6.1} adv={d:<5.1} over={d:.1}\n", .{ g.glyph_id, g.codepoint, g.x_px, g.advance_px, g.left_overhang_px });
    }

    // **판정 여섯.** 하나라도 비면 그 출력이 안 채워진 것이다.
    try std.testing.expect(out[0].glyph_id != 0); // ① glyph_id
    try std.testing.expectEqual(@as(u32, 'W'), out[0].codepoint); // ② codepoint
    try std.testing.expect(out[0].advance_px > 0); // ③ advance
    try std.testing.expect(names_seen >= 2); // ④ font_name — 한글/이모지가 다른 폰트로 갔다
    try std.testing.expect(fallback_n > 0); // ⑤ fallback 표시
    try std.testing.expect(color_n > 0); // ⑥ 이모지가 컬러 폰트로
}

test "셰이퍼: 말줄임이 글리프를 줄인다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();
    var out: [64]GlyphRecord = undefined;

    const full = try sh.shape(.{ .text = "Wi->l 100% tail.zig", .family = "JetBrains Mono", .fallback_csv = "", .size_px = 16 }, &out);
    const cut = try sh.shape(.{ .text = "Wi->l 100% tail.zig", .family = "JetBrains Mono", .fallback_csv = "", .size_px = 16, .max_width_px = 60 }, &out);
    std.debug.print("\n  SHAPE 안 자름={d} 자름={d}\n", .{ full.count, cut.count });
    try std.testing.expect(cut.count < full.count);

    // **앞을 자르는 것은 아직 없다 — 조용히 뒤를 자르지 않는다.**
    try std.testing.expectError(error.UnsupportedHeadTrim, sh.shape(.{
        .text = "Wi->l 100% tail.zig",
        .family = "JetBrains Mono",
        .fallback_csv = "",
        .size_px = 16,
        .max_width_px = 60,
        .anchor_tail = true,
    }, &out));
}

test "셰이퍼: 폴백 목록이 번들 폰트를 고른다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();
    var out: [64]GlyphRecord = undefined;

    // **이 슬라이스의 존재 이유.** 폴백 목록을 안 박으면 DirectWrite 가 시스템에서 고르고(§2m.13 실측:
    // Malgun Gothic) 터미널과 크롬이 갈린다. `fallbackCandidates` 의 첫 항목이 번들 `Jetendard` 다.
    const res = try sh.shape(.{ .text = "\u{d55c}\u{ae00}", .family = "JetBrains Mono", .fallback_csv = "Jetendard", .size_px = 16 }, &out);
    try std.testing.expect(res.count >= 2);
    const z = std.mem.indexOfScalar(u8, &out[0].font_name, 0) orelse out[0].font_name.len;
    std.debug.print("\n  SHAPE 한글 폰트 = \"{s}\"\n", .{out[0].font_name[0..z]});
    try std.testing.expectEqualStrings("Jetendard", out[0].font_name[0..z]);
}

// ── 프로세스 하나짜리 셰이퍼 ─────────────────────────────────────────────────────────────────

var shared_shaper: ?*Shaper = null;

/// 프로세스에 하나뿐인 셰이퍼. **프레임마다 만들면 안 된다** — 팩토리·컬렉션 생성이 매번 든다
/// (§2m.15 가 컬렉션을 2ms 로 쟀다).
///
/// **잠금이 없다.** 크롬 셰이핑은 메인 스레드에서만 돈다(macOS 의 CoreText 경로도 같다 —
/// `shapeUnresolvedRun` 은 프레임 조립 중에 불린다). 다른 스레드에서 부르면 그 규약이 깨진 것이다.
///
/// **한 번 실패하면 다시 시도한다** — 폰트가 나중에 설치될 수 있고, 실패를 캐시하면 그 세션 내내
/// 크롬 텍스트가 안 나온다.
///
/// **호출자의 allocator 를 안 쓴다.** 이것은 프로세스 끝까지 사는 물건인데 첫 호출자가 프레임
/// 아레나나 테스트 allocator 면 그 allocator 가 죽은 뒤에도 캐시된 포인터가 남아 매달린다 —
/// 처음엔 caller allocator 를 받게 짜 뒀다가 Windows 종단 실측에서 `testing.allocator` 가 누수로
/// 잡아냈다. 수명이 프로세스면 allocator 도 프로세스여야 한다.
pub fn sharedShaper() Error!*Shaper {
    if (shared_shaper) |s| return s;
    const s = try Shaper.create(std.heap.page_allocator);
    shared_shaper = s;
    return s;
}

/// 테스트가 프로세스 상태를 안 남기게 하는 자리. 제품은 프로세스 끝까지 들고 간다.
pub fn destroySharedShaper() void {
    if (shared_shaper) |s| {
        s.destroy();
        shared_shaper = null;
    }
}

// ── 이음매가 부르는 자리 ─────────────────────────────────────────────────────────────────────

/// `text_shaper.shape` 가 가리키는 함수. **오류를 이음매 타입으로 접는다** — 중립 층이
/// DirectWrite 오류 이름을 알 필요가 없다.
pub fn shapeInto(allocator: std.mem.Allocator, req: seam.Request, out: []seam.GlyphRecord) seam.Error!usize {
    // `allocator` 는 이 백엔드가 안 쓴다 — 셰이퍼는 프로세스 소유이고 글리프는 호출자 버퍼에
    // 바로 쓴다. 이음매 서명에 남겨 두는 것은 다른 백엔드(중간 버퍼가 필요한 종류)를 위해서다.
    _ = allocator;
    const shaper = sharedShaper() catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        else => error.ShapeFailed,
    };
    const res = shaper.shape(req, out) catch |e| return switch (e) {
        error.UnsupportedHeadTrim => error.UnsupportedHeadTrim,
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        else => error.ShapeFailed,
    };
    // **넘치면 실패다.** 잘린 줄을 그대로 주면 글자가 조용히 사라진다.
    if (res.overflow) return error.ShapeFailed;
    return res.count;
}
