//! Owned DirectWrite typography for the three optional ligature features.
//! A layout keeps its own reference; this owner releases only the caller's one.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const d3d11 = @import("d3d11.zig");

pub const Error = error{ UnsupportedPlatform, CreateFailed, FeatureFailed, ApplyFailed, QueryFailed };
pub const Feature = extern struct { tag: u32, parameter: u32 };
const TextRange = extern struct { start: u32, length: u32 };
pub const AppliedRange = struct {
    queried: bool = false,
    has_typography: bool = false,
    start: u32 = 0,
    length: u32 = 0,
};
var last_hresult: i32 = 0;

pub fn lastHresult() i32 {
    return last_hresult;
}

// Tags are OpenType byte tags in DWRITE_MAKE_OPENTYPE_TAG order. Required
// ligatures and kerning remain untouched; FontConfig only controls these three.
const disabled_features = [_]Feature{
    .{ .tag = 0x6167696c, .parameter = 0 }, // liga
    .{ .tag = 0x67696c63, .parameter = 0 }, // clig
    .{ .tag = 0x746c6163, .parameter = 0 }, // calt
};

const Instance = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [3]*const anyopaque,
        AddFontFeature: *const fn (*Instance, Feature) callconv(abi.winapi) i32,
        GetFontFeatureCount: *const fn (*Instance) callconv(abi.winapi) u32,
        GetFontFeature: *const fn (*Instance, u32, *Feature) callconv(abi.winapi) i32,
    };
};
const Factory = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [16]*const anyopaque,
        CreateTypography: *const fn (*Factory, *?*Instance) callconv(abi.winapi) i32,
    };
};
const Layout = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        head: [40]*const anyopaque,
        SetTypography: *const fn (*Layout, *Instance, TextRange) callconv(abi.winapi) i32,
        mid: [14]*const anyopaque,
        GetTypography: *const fn (*Layout, u32, *?*Instance, *TextRange) callconv(abi.winapi) i32,
    };
};

comptime {
    const pointer = @sizeOf(usize);
    std.debug.assert(@offsetOf(Factory.VTable, "CreateTypography") / pointer == 16);
    std.debug.assert(@offsetOf(Instance.VTable, "AddFontFeature") / pointer == 3);
    std.debug.assert(@offsetOf(Layout.VTable, "SetTypography") / pointer == 40);
    std.debug.assert(@offsetOf(Layout.VTable, "GetTypography") / pointer == 55);
    std.debug.assert(@sizeOf(Feature) == 8 and @sizeOf(TextRange) == 8);
}

fn check(hr: i32, failure: Error) Error!void {
    if (hr < 0) {
        last_hresult = hr;
        return failure;
    }
}

pub const Typography = struct {
    raw: *Instance,

    pub fn createDisabled(factory_raw: *anyopaque) Error!Typography {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const factory: *Factory = @ptrCast(@alignCast(factory_raw));
        var raw: ?*Instance = null;
        // Also retire a partial COM out pointer on failure. No failed prefix may
        // leave a native object alive on each dirty terminal frame.
        errdefer d3d11.releaseOpt(raw);
        try check(factory.vtable.CreateTypography(factory, &raw), error.CreateFailed);
        const instance = raw orelse return error.CreateFailed;
        for (disabled_features) |descriptor| try check(instance.vtable.AddFontFeature(instance, descriptor), error.FeatureFailed);
        return .{ .raw = instance };
    }

    pub fn apply(self: Typography, layout_raw: *anyopaque, utf16_length: u32) Error!void {
        const layout: *Layout = @ptrCast(@alignCast(layout_raw));
        // DirectWrite ranges count UTF-16 code units, not bytes or Unicode
        // scalars. Otherwise an operator after Hangul/emoji keeps its ligature.
        try check(layout.vtable.SetTypography(layout, self.raw, .{ .start = 0, .length = utf16_length }), error.ApplyFailed);
    }

    pub fn featureCount(self: Typography) u32 {
        return self.raw.vtable.GetFontFeatureCount(self.raw);
    }

    /// Optional native readback distinguishes a complete range from glyph output
    /// that happens to look unligated because of script/itemization boundaries.
    pub fn rangeAt(layout_raw: *anyopaque, utf16_position: u32) Error!AppliedRange {
        const layout: *Layout = @ptrCast(@alignCast(layout_raw));
        var raw: ?*Instance = null;
        var range: TextRange = undefined;
        defer d3d11.releaseOpt(raw);
        try check(layout.vtable.GetTypography(layout, utf16_position, &raw, &range), error.QueryFailed);
        return .{ .queried = true, .has_typography = raw != null, .start = range.start, .length = range.length };
    }

    pub fn feature(self: Typography, index: u32) Error!Feature {
        var value: Feature = undefined;
        try check(self.raw.vtable.GetFontFeature(self.raw, index, &value), error.QueryFailed);
        return value;
    }

    pub fn deinit(self: *Typography) void {
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.raw)));
        self.* = undefined;
    }
};
