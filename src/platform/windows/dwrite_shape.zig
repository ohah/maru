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

/// 스택에 미리 두는 런 수. **이것은 상한이 아니라 흔한 경우의 크기다** — 넘으면 힙으로 옮긴다.
///
/// 런은 폰트가 바뀔 때마다 하나다. 처음엔 32 로 두고 "그보다 잘게 쪼개지면 폴백이 이상한 것" 이라고
/// 적어 뒀는데, **재 보니 틀렸다**: 라틴/한글이 교대하는 800 자 줄이 256 런에서도 넘쳤다(아래 테스트).
/// 임의의 숫자에서 줄이 통째로 사라지게 두지 않는다.
const stack_runs = 64;

/// `GetDesignGlyphMetrics` 를 한 번에 부르는 글리프 수. 런 길이와 무관하게 같은 결과가 나오도록
/// **조각으로 나눠** 부르기 위한 스크래치 크기다(스택 `[128]u16` + `[128]GlyphMetrics`).
const metrics_chunk = 128;

const RunInfo = struct {
    face: ?*IDWriteFontFace = null,
    baseline_x: f32 = 0,
    glyph_start: usize = 0,
    glyph_count: usize = 0,
    text_position: u32 = 0,
    string_length: u32 = 0,
};

/// **글리프를 호출자 버퍼에 바로 무대를 편다.** 예전에는 `[512]` 고정 배열 셋을 들고 있었는데,
/// 그 숫자가 어디서도 안 나온 값이라 **에디터 한 줄이 512 글리프를 넘으면 그 줄이 통째로 사라졌다**
/// (실측: 1600 자 → `count=0 overflow=true`). 상한은 이제 **호출자가 준 버퍼 크기**다 — 그것이
/// 정직한 계약이고, 호출자는 이미 자기가 몇 개를 받을 수 있는지 알고 있다.
///
/// `GlyphRecord` 의 `glyph_id`·`advance_px`·`codepoint` 가 예전 평면 배열 셋과 정확히 같은 것을
/// 담으므로 별도 저장이 필요 없다. 나머지 필드(폰트 이름·x·폴백 여부 등)는 `fill` 이 런 단위로
/// 채운다.
const Collector = struct {
    /// 흔한 경우의 자리. 넘으면 `heap` 으로 옮긴다.
    inline_runs: [stack_runs]RunInfo = @splat(.{}),
    /// 스택을 넘었을 때만 산다. `Draw` 가 끝나면 `deinit` 이 돌려준다.
    heap: ?[]RunInfo = null,
    allocator: std.mem.Allocator,
    run_count: usize = 0,
    /// 무대. `Draw` 동안 `glyph_id`·`advance_px`·`codepoint` 만 쓰이고, 나머지는 `fill` 이 채운다.
    stage: []GlyphRecord,
    glyph_total: usize = 0,
    overflow: bool = false,

    fn deinit(self: *Collector) void {
        if (self.heap) |h| self.allocator.free(h);
        self.heap = null;
    }

    fn runs(self: *const Collector) []const RunInfo {
        const all = if (self.heap) |h| h else &self.inline_runs;
        return all[0..self.run_count];
    }

    /// 런 하나를 더 담는다. **자리가 없으면 두 배로 늘린다.** 실패하면 `overflow` 로 남긴다 —
    /// 여기는 COM 콜백이라 오류를 위로 못 던지고, 조용히 자르는 것보다 시끄러운 편이 낫다.
    fn push(self: *Collector, info: RunInfo) void {
        const cap = if (self.heap) |h| h.len else self.inline_runs.len;
        if (self.run_count == cap) {
            const bigger = self.allocator.alloc(RunInfo, cap * 2) catch {
                self.overflow = true;
                return;
            };
            const old = if (self.heap) |h| h else self.inline_runs[0..];
            @memcpy(bigger[0..self.run_count], old[0..self.run_count]);
            if (self.heap) |h| self.allocator.free(h);
            self.heap = bigger;
        }
        const dst = if (self.heap) |h| h else self.inline_runs[0..];
        dst[self.run_count] = info;
        self.run_count += 1;
    }
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
        const n = run.glyph_count;
        if (c.glyph_total + n > c.stage.len) {
            c.overflow = true;
            return 0;
        }
        const start = c.glyph_total;
        const ids = run.glyph_indices orelse return 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            c.stage[start + i].glyph_id = ids[i];
            c.stage[start + i].advance_px = if (run.glyph_advances) |a| a[i] else 0;
            c.stage[start + i].codepoint = 0;
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
                        if (c.stage[start + g].codepoint != 0) continue; // 첫 문자만
                        c.stage[start + g].codepoint = decodeUtf16At(str, d.string_length, t);
                    }
                }
            }
        }
        c.push(.{
            .face = if (run.font_face) |f| @ptrCast(@alignCast(f)) else null,
            .baseline_x = baseline_x,
            .glyph_start = start,
            .glyph_count = n,
            .text_position = if (desc) |d| d.text_position else 0,
            .string_length = if (desc) |d| d.string_length else 0,
        });
        if (c.overflow) return 0; // 자리를 못 늘렸다 — 이 런은 안 실렸다
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
        try check(create_format(self.factory, @ptrCast(&primary_w), format_collection, @intFromEnum(req.weight), 0, 5, req.size_px, locale, &fmt_raw), error.FormatFailed);
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

        var collector = Collector{ .stage = out, .allocator = self.allocator };
        defer collector.deinit();
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
        const all_runs = c.runs();
        const primary_face = all_runs[0].face;

        var n: usize = 0;
        for (all_runs) |run| {
            const face = run.face orelse continue;
            var name_buf: [128]u8 = @splat(0);
            self.identityName(face, &name_buf);
            const is_color = faceHasColor(face);

            var fm: FontMetrics = undefined;
            face.vtable.GetMetrics(face, &fm);
            const upem: f32 = @floatFromInt(if (fm.design_units_per_em == 0) 1000 else fm.design_units_per_em);

            // **디자인 메트릭은 조각으로 가져온다.** 예전에는 `[512]` 스크래치를 잡고 런이 그보다
            // 길면 통째로 포기해(`has_metrics = false`) 합자 overhang 이 조용히 0 이 됐다. 길이와
            // 무관하게 같은 결과가 나오도록 조각마다 부른다.
            var chunk_ids: [metrics_chunk]u16 = undefined;
            var metrics: [metrics_chunk]GlyphMetrics = undefined;
            var chunk_base: usize = 0; // 이번 조각이 덮는 런 내 시작 인덱스
            var chunk_len: usize = 0;
            var has_metrics = false;

            var x = run.baseline_x;
            var i: usize = 0;
            while (i < run.glyph_count) : (i += 1) {
                if (n >= out.len) {
                    result.overflow = true;
                    result.count = n;
                    return result;
                }
                if (i >= chunk_base + chunk_len) {
                    chunk_base = i;
                    chunk_len = @min(metrics_chunk, run.glyph_count - i);
                    // 무대에는 `u32` 로 실려 있지만 값은 DirectWrite 가 준 `u16` 글리프 인덱스 그대로다.
                    for (0..chunk_len) |k| chunk_ids[k] = @intCast(c.stage[run.glyph_start + i + k].glyph_id);
                    has_metrics = !d3d11.failed(face.vtable.GetDesignGlyphMetrics(face, &chunk_ids, @intCast(chunk_len), &metrics, 0));
                }
                // **무대와 결과가 같은 버퍼다.** `n <= run.glyph_start + i` 가 늘 성립하므로(런을
                // 건너뛰면 n 만 뒤처진다) 앞으로 접는 in-place 압축이고, 덮어쓰기 전에 읽어 둔다.
                const staged = c.stage[run.glyph_start + i];
                const m = metrics[i - chunk_base];
                // ink 가 자기 자리 **왼쪽으로** 넘치는 만큼(합자만 양수).
                const overhang: f32 = if (has_metrics and m.left_side_bearing < 0)
                    @as(f32, @floatFromInt(-m.left_side_bearing)) * req.size_px / upem
                else
                    0;
                out[n] = .{
                    .glyph_id = staged.glyph_id,
                    .codepoint = staged.codepoint,
                    .fallback = run.face != primary_face,
                    .color = is_color,
                    .x_px = x,
                    .advance_px = staged.advance_px,
                    .left_overhang_px = overhang,
                    .font_name = name_buf,
                };
                x += staged.advance_px;
                n += 1;
            }
        }
        result.count = n;
        return result;
    }

    /// 이 런을 셰이핑한 face 의 **신원**을 싣는다. 이 값이 `ShapedGlyph.font_name` 이 되고, 측정 결과를
    /// 읽는 쪽(`system_text.resolveArtifact`)이 그것을 `FontIdentity.postscript_name` 으로 intern 해,
    /// 래스터라이저가 **그 이름으로 face 를 되찾아** 여기서 정한 글리프 번호를 굽는다.
    ///
    /// **그래서 이름이 face 를 하나로 정해야 한다.** 예전에는 family 이름을 실었는데, family 는 굵기·
    /// 스타일마다 다른 face 를 묶은 이름이라 그 일을 못 한다 — 굵은 크롬 제목이 Regular face 로 구워져
    /// 글자가 **한 칸씩 밀렸다**(§2m.90 의 실측). PostScript 이름은 face 마다 다르므로 그것을 싣는다.
    ///
    /// 못 읽으면(`name` 테이블이 없거나 ASCII 밖) **family 로 내려간다** — 예전 동작이고, 래스터라이저는
    /// 두 이름을 다 받는다.
    fn identityName(self: *Shaper, face: *IDWriteFontFace, out: *[128]u8) void {
        if (postScriptName(face, out)) return;
        self.familyName(face, out);
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

/// face 의 PostScript 이름을 `out` 에 채운다. 채웠으면 `true`.
///
/// **표 읽기는 순수 함수가 한다**(`dwrite_font.postScriptNameFromNameTable`) — 여기서는 OS 에서
/// 테이블 바이트를 빌려 오고 **반드시 돌려주는** 일만 한다(`faceHasTable` 과 같은 규약).
fn postScriptName(face: *IDWriteFontFace, out: *[128]u8) bool {
    const t: UINT = @as(UINT, 'n') | (@as(UINT, 'a') << 8) | (@as(UINT, 'm') << 16) | (@as(UINT, 'e') << 24);
    var data: ?*const anyopaque = null;
    var size: UINT = 0;
    var ctx: ?*anyopaque = null;
    var exists: BOOL = 0;
    if (d3d11.failed(face.vtable.TryGetFontTable(face, t, &data, &size, &ctx, &exists))) return false;
    defer if (ctx) |q| face.vtable.ReleaseFontTable(face, q);
    if (exists == 0 or size == 0) return false;
    const raw = data orelse return false;
    var buf: [128]u8 = undefined;
    const ps = dwrite_font.postScriptNameFromNameTable(@as([*]const u8, @ptrCast(raw))[0..size], &buf) orelse return false;
    const n = @min(ps.len, out.len - 1);
    @memcpy(out[0..n], ps[0..n]);
    out[n] = 0;
    return true;
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
    //
    // **이제 싣는 것은 face 신원(PostScript 이름)이라 family 와 글자가 같지 않다** — PostScript
    // 이름은 공백을 빼고 스타일 꼬리를 붙인다(`JetBrains Mono` → `JetBrainsMono-Regular`, §2m.90).
    // 그래도 **어느 family 로 갔는지**는 그 이름이 말한다: 공백을 뺀 family 로 시작해야 한다
    // (터미널 티어로 떨어졌다면 `CascadiaMono…` 라 안 맞는다 — 이 테스트가 지키던 그 사실이다).
    const family = maru.config.theme.bundled_fonts[0].family;
    var want: [64]u8 = undefined;
    var wn: usize = 0;
    for (family) |c| {
        if (c == ' ') continue;
        want[wn] = c;
        wn += 1;
    }
    try std.testing.expect(std.ascii.startsWithIgnoreCase(got, want[0..wn]));
    // **family 이름 그대로면 안 된다.** 그것이 §2m.90 의 결함이었다 — family 는 같은 가족의 다른
    // 굵기를 못 가르고, 래스터라이저가 그 이름으로 되찾은 face 는 셰이핑한 face 가 아닐 수 있다.
    try std.testing.expect(!std.mem.eql(u8, got, family));
}

test "셰이퍼: 1024 유닛을 넘는 긴 줄이 한 글자도 안 잘린다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 두 가지를 한 번에 본다.
    // ⒜ **메모리 안전** — 예전엔 고정 `[1024]u16` 에 바로 변환했는데 `utf8ToUtf16Le` 는 dest 를
    //    **검사하지 않는다**(실증: 8칸 버퍼에 16자 → `index out of bounds: index 16, len 8`).
    //    ReleaseFast 였다면 스택 밖 쓰기다.
    // ⒝ **수집기 상한** — 예전엔 `[512]` 고정 배열이라 이 줄이 통째로 사라졌다(`count=0`).
    //    이제 상한은 호출자 버퍼 크기다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    const n = 1600;
    const text = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    const out = try std.testing.allocator.alloc(GlyphRecord, n + 16);
    defer std.testing.allocator.free(out);

    const res = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, out);
    std.debug.print("  [실측] 긴 줄: 입력 {d}자 -> 글리프 {d} overflow={s}", .{ n, res.count, if (res.overflow) "true" else "false" });
    try std.testing.expect(!res.overflow);
    try std.testing.expectEqual(@as(usize, n), res.count);
    // x 가 끝까지 오른쪽으로 간다 — 뒤쪽 절반이 0 에 몰려 있으면 무대 인덱스가 어긋난 것이다.
    try std.testing.expect(out[n - 1].x_px > out[n / 2].x_px);
    try std.testing.expect(out[n / 2].x_px > out[0].x_px);
}

test "[실측] 셰이퍼: 런 상한이 실제로 닿는가 — 폰트가 계속 바뀌는 줄" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 런은 폰트가 바뀔 때마다 하나다. 라틴/한글을 번갈아 두면 글자마다 런이 생긴다 —
    // 스택 자리(`stack_runs`)를 넘겨 **힙으로 옮겨 가는지** 본다. 예전에는 여기가 고정 상한이라
    // 이 줄이 통째로 사라졌다(실측: 800자 교대 -> 글리프 256 overflow=true, max_runs=256).
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..400) |_| try buf.appendSlice(std.testing.allocator, "a\u{d55c}");

    const out = try std.testing.allocator.alloc(GlyphRecord, 4096);
    defer std.testing.allocator.free(out);
    const res = try sh.shape(.{
        .text = buf.items,
        .family = "Consolas",
        .fallback_csv = "Malgun Gothic",
        .size_px = 16,
    }, out);
    std.debug.print(
        "  [실측] 런 spill: 800자(라틴/한글 교대) -> 글리프 {d} overflow={s} (stack_runs={d})",
        .{ res.count, if (res.overflow) "true" else "false", stack_runs },
    );
    // 이제는 **넘치지 않는다** — 자리가 모자라면 늘린다.
    try std.testing.expect(!res.overflow);
    try std.testing.expectEqual(@as(usize, 800), res.count);
    // 폰트가 실제로 교대했는지 — 안 그러면 런이 하나뿐이라 이 테스트가 아무것도 안 잰다.
    try std.testing.expect(out[0].fallback != out[1].fallback);

    // **내용까지 본다.** 무대와 결과가 같은 버퍼라(in-place 앞 접기) 인덱스가 하나만 어긋나도
    // 개수는 맞는데 글자가 뒤섞인다 — 개수만 세면 안 잡힌다.
    for (out[0..res.count], 0..) |g, i| {
        const want: u32 = if (i % 2 == 0) 'a' else 0xD55C;
        try std.testing.expectEqual(want, g.codepoint);
        // 짝수 자리는 주 폰트, 홀수 자리는 폴백이어야 한다.
        try std.testing.expectEqual(i % 2 == 1, g.fallback);
        // x 는 단조 증가한다.
        if (i > 0) try std.testing.expect(g.x_px > out[i - 1].x_px);
    }
}

test "셰이퍼: 옛 512 상한 자리에서 더 이상 안 선다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // 대조군. 정확히 예전 상한 바로 위·아래를 재서 "512 라는 숫자가 사라졌다" 를 성질로 만든다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();
    for ([_]usize{ 511, 512, 513 }) |n| {
        const text = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(text);
        @memset(text, 'x');
        const out = try std.testing.allocator.alloc(GlyphRecord, n);
        defer std.testing.allocator.free(out);
        const res = try sh.shape(.{ .text = text, .family = "Consolas", .fallback_csv = "", .size_px = 16 }, out);
        try std.testing.expect(!res.overflow);
        try std.testing.expectEqual(n, res.count);
    }
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

    // **자른 런의 글리프가 서로 겹치면 안 된다.** 개수만 보면 속 빈다 — 자리가 뒤로 안 가고 앞으로
    // 되감기면 글자가 포개져 읽을 수 없다(제품 캡처 2026-08-25: 브랜치 이름이 그렇게 뭉갰다).
    // 말줄임 부호가 별도 런으로 오므로 **런이 여럿일 때 x 가 되감기는지**가 진짜 위험이다.
    var prev_end: f32 = -1e9;
    for (out[0..cut.count]) |g| {
        try std.testing.expect(g.x_px + 0.5 >= prev_end);
        prev_end = g.x_px + g.advance_px;
    }

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

test "셰이퍼가 실은 이름으로 래스터라이저가 같은 face 를 되찾는다 — 굵은 런도" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // **§2m.90 의 결함을 그대로 재현하는 배치다.** 굵은 크롬 제목은 같은 family 의 **다른 face** 로
    // 셰이핑되는데, 신원이 family 이름이면 래스터라이저는 Regular 를 되찾아 **다른 번호 체계**로
    // 굽는다 — 실측으로 `Agent session history` 가 `@f dms rdrrhmr ghrsnqx` 로 그려졌다(글자마다
    // 하나씩 앞). 그래서 재는 것은 *"이름이 돌아오나"* 가 아니라 **"셰이퍼와 래스터라이저가 같은
    // 번호를 말하나"** 다.
    var sh = try Shaper.create(std.testing.allocator);
    defer sh.destroy();
    var out: [16]GlyphRecord = undefined;
    const res = try sh.shape(.{
        .text = "A",
        .family = "Malgun Gothic",
        .fallback_csv = "",
        .size_px = 16,
        .weight = .semibold,
    }, &out);
    if (res.count == 0) return error.SkipZigTest;
    const name = std.mem.sliceTo(&out[0].font_name, 0);
    // 그 폰트가 없는 기계에서는 DirectWrite 가 딴 것을 고른다 — 그러면 이 판정의 전제가 없다.
    if (!std.ascii.startsWithIgnoreCase(name, "Malgun")) return error.SkipZigTest;

    const ras = try dwrite_font.Rasterizer.create(std.testing.allocator, "Malgun Gothic", "", 16);
    defer ras.destroy();
    const idx = ras.faceIndexForName(name) orelse return error.NoFaceForShapedName;
    const says = ras.glyphIdIn(idx, 'A') orelse return error.NoGlyphIndex;
    std.debug.print("\n  [실측] 굵은 런 신원 = \"{s}\" 셰이퍼={d} 그 face={d}\n", .{ name, out[0].glyph_id, says });
    try std.testing.expectEqual(out[0].glyph_id, @as(u32, says));
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
    // 싣는 값은 **face 신원**이다(§2m.90) — family `Jetendard` 의 face 하나를 가리키는 PostScript
    // 이름이라 `Jetendard-…` 로 시작하고, family 이름 그대로는 아니다.
    try std.testing.expect(std.ascii.startsWithIgnoreCase(out[0].font_name[0..z], "Jetendard"));
    try std.testing.expect(!std.mem.eql(u8, out[0].font_name[0..z], "Jetendard"));
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
