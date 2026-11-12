//! Chromium 탭의 기기 흉내를 maru 가 쥐는 자리(W9e① — docs/plans/web-osr-backend.md 「W9e① 결정·실측」) — L2 순수.
//!
//! 흉내는 **탭에 하나**다(규칙 목록이 아니다 — 계획 §3). 처음 건 pane 이 주인이고 다른 pane 의 `set`·`clear` 는 `emulated_by_other_pane`(그
//! pane 은 `get` 으로 상태만). `set` 은 **덧쓰기**다 — 준 무리만 바꾸고 `null` 은 그 무리를 지운다(Chrome DevTools MCP 의 「매번 전부」 와 다르게 —
//! 에이전트가 시간대만 바꾸다 viewport 를 잃지 않게, 작성자 선택 §17-3). 바뀔 때마다 세대(`gen`)가 오르고 web_osr 가 sidecar 에 **전체 상태**를
//! 보낸다(`emulation` — 다시 보내도 같다, sidecar 가 다시 뜨면 재생 이동 앞에). 사용자 탭은 grant 호스트(사이트)에 묶이고(사용자 결정 Q1 — 그
//! 사이트를 보이는 동안만), 에이전트 탭은 어느 호스트든이다(birth grant — 묻지 않는다). 주인의 emulation grant 가 사라지거나 다른 호스트로 바뀌면
//! 모두 지운다(`sync`).
//!
//! 인자 검사(`parseParams` — control_browser 가 모달 전에, 앱이 op.arg 로 다시)·client hints 추정(`deriveHints` — Chromium 꼴 UA 에서만:
//! 진짜 Safari·Firefox 는 Sec-CH-UA 를 보내지 않는다, 작성자 선택 §17-4)·Accept-Language 목록(`acceptLanguage` — q 값 없이: Chromium 이 붙인다,
//! 실측 E7)·ICU 이름·결과 JSON 도 여기다.
//!
//! 시험이 증명하는 것: 인자 표(범위·NaN·64 Mpx·모르는 키·null 지움·덧쓰기 합치기·까닭 이름), client hints 추정(Chrome/N 있음·없음·Mobile 토큰·
//! viewport.mobile·플랫폼 토큰), Accept-Language 목록(`fr-FR`→`fr-FR,fr`, `en`→`en`), ICU 이름, 주인 pane, 초당 10 번, grant sync, sidecar 상태의
//! 받기, wire 꼴(`emulation` 의 닫힌 칸을 지난다), 결과 JSON(state·active·not_covered·process_shared·warnings), 요약 글.

const std = @import("std");
const ws = @import("web_sidecar/root.zig");
const cpg = @import("control_pane_grant.zig");

const msg = ws.message;
const emu_fields = ws.emu_fields;

/// 탭마다 1 초에 받는 바꾸기 수(계획 §4 — `set`·`clear`).
pub const max_changes_per_s: usize = 10;
/// BCP 47 태그 상한(계획 §4).
pub const max_locale_bytes: usize = 35;

pub const Action = enum { set, clear, get };

pub const Group = enum { viewport, user_agent, locale, timezone, geolocation, media, vision };

/// 바이트 칸(고정 버퍼 — 탭 상태가 할당 없이 쥔다).
pub fn Text(comptime n: usize) type {
    return struct {
        // 0 으로 채운다 — 같은 글이면 바이트까지 같아 `std.meta.eql` 로 상태를 견준다(덧쓰기의 「바뀌었는가」).
        buf: [n]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();

        pub fn init(v: []const u8) Self {
            var t: Self = .{ .len = @min(v.len, n) };
            @memcpy(t.buf[0..t.len], v[0..t.len]);
            return t;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const Hint = Text(msg.max_emu_hint_bytes);

pub const Brand = struct { brand: Hint = .{}, version: Hint = .{} };

/// 준 client hints(`user_agent.client_hints` 객체).
pub const Hints = struct {
    brands: [msg.max_emu_brands]Brand = @splat(.{}),
    brand_count: u8 = 0,
    full: [msg.max_emu_brands]Brand = @splat(.{}),
    full_count: u8 = 0,
    platform: Hint = .{},
    platform_version: Hint = .{},
    architecture: Hint = .{},
    model: Hint = .{},
    bitness: Hint = .{},
    mobile: bool = false,
};

pub const HintsMode = enum { derive, none, given };

pub const Viewport = struct { width: u16, height: u16, dsf: f32 = 1, mobile: bool = false, touch: bool = false, landscape: bool = false };

pub const UserAgent = struct {
    ua: Text(msg.max_emu_ua_bytes) = .{},
    platform: Text(msg.max_emu_platform_bytes) = .{},
    mode: HintsMode = .derive,
    hints: Hints = .{},
};

pub const Geo = struct { unavailable: bool = false, latitude: f64 = 0, longitude: f64 = 0, accuracy: f64 = 50 };

pub const Settings = struct {
    viewport: ?Viewport = null,
    user_agent: ?UserAgent = null,
    locale: ?Text(max_locale_bytes) = null,
    timezone: ?Text(msg.max_emu_timezone_bytes) = null,
    geolocation: ?Geo = null,
    media: ?msg.EmuMedia = null,
    vision: ?msg.EmuVision = null,

    pub fn any(self: *const Settings) bool {
        return self.viewport != null or self.user_agent != null or self.locale != null or self.timezone != null or self.geolocation != null or self.media != null or self.vision != null;
    }
};

pub fn Change(comptime T: type) type {
    return union(enum) { keep, clear, set: T };
}

/// 한 번의 `browser.emulate`(풀린 인자).
pub const Params = struct {
    action: Action,
    reload: bool = false,
    viewport: Change(Viewport) = .keep,
    user_agent: Change(UserAgent) = .keep,
    locale: Change(Text(max_locale_bytes)) = .keep,
    timezone: Change(Text(msg.max_emu_timezone_bytes)) = .keep,
    geolocation: Change(Geo) = .keep,
    media: Change(msg.EmuMedia) = .keep,
    vision: Change(msg.EmuVision) = .keep,
};

/// 인자 거절의 까닭(`-32602` 의 `data.reason` — 계획 §4).
pub const Why = enum { unknown_key, action_invalid, viewport_invalid, viewport_too_large, dsf_invalid, ua_invalid, platform_invalid, client_hints_invalid, locale_invalid, timezone_invalid, geolocation_invalid, media_invalid, vision_invalid, reload_invalid };

pub fn whyMessage(why: Why) []const u8 {
    return switch (why) {
        .unknown_key => "unknown key — browser.emulate takes id, action, reload, viewport, user_agent, locale, timezone, geolocation, media and vision",
        .action_invalid => "action is set, clear or get (clear and get take no settings)",
        .viewport_invalid => "viewport needs whole-number width and height from 1 to 4096 (and optional device_scale_factor, mobile, touch, landscape)",
        .viewport_too_large => "viewport too large — width × height × device_scale_factor² must stay within 64 megapixels (the screenshot limit)",
        .dsf_invalid => "device_scale_factor is a number from 0.5 to 4",
        .ua_invalid => "user_agent.ua is 1–512 bytes of printable ASCII",
        .platform_invalid => "user_agent.platform is up to 64 bytes of printable ASCII",
        .client_hints_invalid => "client_hints is \"derive\", \"none\" or {brands:[{brand,version}] (1–4), platform, full_version_list?, platform_version?, architecture?, model?, mobile?, bitness?} with printable ASCII up to 64 bytes",
        .locale_invalid => "locale is a BCP 47 tag such as fr-FR (letters, digits and '-', up to 35 bytes)",
        .timezone_invalid => "timezone is an IANA name such as Asia/Kolkata",
        .geolocation_invalid => "geolocation is {latitude -90..90, longitude -180..180, accuracy? 0..100000} or \"unavailable\"",
        .media_invalid => "media takes type screen|print, color_scheme light|dark, reduced_motion reduce|no-preference, forced_colors active|none, contrast more|less|no-preference",
        .vision_invalid => "vision is blurredVision, reducedContrast, achromatopsia, deuteranopia, protanopia or tritanopia",
        .reload_invalid => "reload is true or false (with set or clear)",
    };
}

// ── 글 규칙 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// BCP 47 모양 — 첫 조각은 글자 2..8, 다음 조각은 글자·숫자 1..8, `-` 로 잇는다(빈 조각 없음), 35 바이트까지.
pub fn localeOk(tag: []const u8) bool {
    if (tag.len < 2 or tag.len > max_locale_bytes) return false;
    var it = std.mem.splitScalar(u8, tag, '-');
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 8) return false;
        for (part) |ch| if (!(if (first) std.ascii.isAlphabetic(ch) else std.ascii.isAlphanumeric(ch))) return false;
        if (first and part.len < 2) return false;
        first = false;
    }
    return true;
}

/// `Accept-Language` 목록 — 태그와(조각이 있으면) 그 첫 조각(`fr-FR` → `fr-FR,fr`, `en` → `en`). q 값은 붙이지 않는다(Chromium 이 붙인다 — E7).
pub fn acceptLanguage(tag: []const u8, out: []u8) []const u8 {
    const dash = std.mem.indexOfScalar(u8, tag, '-') orelse {
        @memcpy(out[0..tag.len], tag);
        return out[0..tag.len];
    };
    const total = tag.len + 1 + dash;
    @memcpy(out[0..tag.len], tag);
    out[tag.len] = ',';
    @memcpy(out[tag.len + 1 .. total], tag[0..dash]);
    return out[0..total];
}

/// ICU 이름 — `-` 를 `_` 로(`zh-Hant-TW` → `zh_Hant_TW`).
pub fn icuName(tag: []const u8, out: []u8) []const u8 {
    for (tag, 0..) |ch, i| out[i] = if (ch == '-') '_' else ch;
    return out[0..tag.len];
}

/// UA 의 `Chrome/<주 버전>`(없으면 null — 진짜 Safari·Firefox).
pub fn chromeMajor(ua: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, ua, from, "Chrome/")) |at| {
        const start = at + "Chrome/".len;
        var end = start;
        while (end < ua.len and std.ascii.isDigit(ua[end]) and end - start < 8) end += 1;
        if (end > start) return ua[start..end];
        from = start;
    }
    return null;
}

/// client hints 추정(작성자 선택 §17-4 — Playwright 와 같은 줄): Chromium 꼴 UA(`Chrome/N`)에서만 — 브랜드 Chromium N + `Not A(Brand` 99, 플랫폼은
/// UA 토큰(Android·CrOS·Windows·Mac OS X·Linux), 모바일은 `Mobile` 토큰이나 viewport.mobile. 아니면 null(보내지 않는다).
pub fn deriveHints(ua: []const u8, viewport_mobile: bool) ?Hints {
    const major = chromeMajor(ua) orelse return null;
    var h: Hints = .{ .brand_count = 2 };
    h.brands[0] = .{ .brand = .init("Chromium"), .version = .init(major) };
    h.brands[1] = .{ .brand = .init("Not A(Brand"), .version = .init("99") };
    const platform: []const u8 = if (std.mem.indexOf(u8, ua, "Android") != null)
        "Android"
    else if (std.mem.indexOf(u8, ua, "CrOS") != null)
        "Chrome OS"
    else if (std.mem.indexOf(u8, ua, "Windows") != null)
        "Windows"
    else if (std.mem.indexOf(u8, ua, "Mac OS X") != null)
        "macOS"
    else if (std.mem.indexOf(u8, ua, "Linux") != null)
        "Linux"
    else
        "";
    h.platform = .init(platform);
    h.mobile = viewport_mobile or std.mem.indexOf(u8, ua, "Mobile") != null;
    return h;
}

// ── 인자 ────────────────────────────────────────────────────────────────────────────────────────────────

const ParamError = error{InvalidParams};

fn fail(why: *?Why, w: Why) ParamError {
    why.* = w;
    return error.InvalidParams;
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isNan(f) or std.math.isInf(f)) null else f,
        else => null,
    };
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8, why: *?Why, w: Why) ParamError!bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => fail(why, w),
    };
}

fn onlyKeys(obj: std.json.ObjectMap, allowed: []const []const u8) bool {
    var it = obj.iterator();
    outer: while (it.next()) |e| {
        for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        return false;
    }
    return true;
}

fn parseViewport(v: std.json.Value, why: *?Why) ParamError!Viewport {
    const obj = switch (v) {
        .object => |o| o,
        else => return fail(why, .viewport_invalid),
    };
    if (!onlyKeys(obj, &.{ "width", "height", "device_scale_factor", "mobile", "touch", "landscape" })) return fail(why, .viewport_invalid);
    const dim = struct {
        fn get(o: std.json.ObjectMap, key: []const u8, w: *?Why) ParamError!u16 {
            const x = o.get(key) orelse return fail(w, .viewport_invalid);
            const i = switch (x) {
                .integer => |n| n,
                else => return fail(w, .viewport_invalid),
            };
            if (i < 1 or i > msg.max_emu_dimension) return fail(w, .viewport_invalid);
            return @intCast(i);
        }
    };
    var vp: Viewport = .{ .width = try dim.get(obj, "width", why), .height = try dim.get(obj, "height", why) };
    if (obj.get("device_scale_factor")) |d| {
        const f = numberOf(d) orelse return fail(why, .dsf_invalid);
        if (f < msg.min_emu_dsf or f > msg.max_emu_dsf) return fail(why, .dsf_invalid);
        vp.dsf = @floatCast(f);
    }
    vp.mobile = try boolOf(obj, "mobile", why, .viewport_invalid);
    vp.touch = try boolOf(obj, "touch", why, .viewport_invalid);
    vp.landscape = try boolOf(obj, "landscape", why, .viewport_invalid);
    if (!emu_fields.viewportOk(vp.width, vp.height, vp.dsf)) return fail(why, .viewport_too_large);
    return vp;
}

fn hintText(v: ?std.json.Value, required: bool, why: *?Why) ParamError!Hint {
    const x = v orelse return if (required) fail(why, .client_hints_invalid) else .{};
    const t = switch (x) {
        .string => |s| s,
        else => return fail(why, .client_hints_invalid),
    };
    if (!emu_fields.printable(t, msg.max_emu_hint_bytes) or (required and t.len == 0)) return fail(why, .client_hints_invalid);
    return .init(t);
}

fn parseBrands(v: std.json.Value, out: *[msg.max_emu_brands]Brand, why: *?Why) ParamError!u8 {
    const arr = switch (v) {
        .array => |a| a.items,
        else => return fail(why, .client_hints_invalid),
    };
    if (arr.len == 0 or arr.len > msg.max_emu_brands) return fail(why, .client_hints_invalid);
    for (arr, 0..) |item, i| {
        const o = switch (item) {
            .object => |x| x,
            else => return fail(why, .client_hints_invalid),
        };
        if (!onlyKeys(o, &.{ "brand", "version" })) return fail(why, .client_hints_invalid);
        out[i] = .{ .brand = try hintText(o.get("brand"), true, why), .version = try hintText(o.get("version"), true, why) };
    }
    return @intCast(arr.len);
}

fn parseUserAgent(v: std.json.Value, why: *?Why) ParamError!UserAgent {
    const obj = switch (v) {
        .object => |o| o,
        else => return fail(why, .ua_invalid),
    };
    if (!onlyKeys(obj, &.{ "ua", "platform", "client_hints" })) return fail(why, .ua_invalid);
    const ua_text = switch (obj.get("ua") orelse return fail(why, .ua_invalid)) {
        .string => |s| s,
        else => return fail(why, .ua_invalid),
    };
    if (ua_text.len == 0 or !emu_fields.printable(ua_text, msg.max_emu_ua_bytes)) return fail(why, .ua_invalid);
    var ua: UserAgent = .{ .ua = .init(ua_text) };
    if (obj.get("platform")) |p| {
        const t = switch (p) {
            .string => |s| s,
            else => return fail(why, .platform_invalid),
        };
        if (!emu_fields.printable(t, msg.max_emu_platform_bytes)) return fail(why, .platform_invalid);
        ua.platform = .init(t);
    }
    if (obj.get("client_hints")) |h| switch (h) {
        .string => |s| ua.mode = if (std.mem.eql(u8, s, "derive")) .derive else if (std.mem.eql(u8, s, "none")) .none else return fail(why, .client_hints_invalid),
        .object => |o| {
            if (!onlyKeys(o, &.{ "brands", "full_version_list", "platform", "platform_version", "architecture", "model", "mobile", "bitness" })) return fail(why, .client_hints_invalid);
            ua.mode = .given;
            ua.hints.brand_count = try parseBrands(o.get("brands") orelse return fail(why, .client_hints_invalid), &ua.hints.brands, why);
            if (o.get("full_version_list")) |f| ua.hints.full_count = try parseBrands(f, &ua.hints.full, why);
            ua.hints.platform = try hintText(o.get("platform"), false, why);
            if (o.get("platform") == null) return fail(why, .client_hints_invalid);
            ua.hints.platform_version = try hintText(o.get("platform_version"), false, why);
            ua.hints.architecture = try hintText(o.get("architecture"), false, why);
            ua.hints.model = try hintText(o.get("model"), false, why);
            ua.hints.bitness = try hintText(o.get("bitness"), false, why);
            ua.hints.mobile = try boolOf(o, "mobile", why, .client_hints_invalid);
        },
        else => return fail(why, .client_hints_invalid),
    };
    return ua;
}

fn parseGeo(v: std.json.Value, why: *?Why) ParamError!Geo {
    switch (v) {
        .string => |s| return if (std.mem.eql(u8, s, "unavailable")) .{ .unavailable = true, .accuracy = 0 } else fail(why, .geolocation_invalid),
        .object => |o| {
            if (!onlyKeys(o, &.{ "latitude", "longitude", "accuracy" })) return fail(why, .geolocation_invalid);
            const lat = numberOf(o.get("latitude") orelse return fail(why, .geolocation_invalid)) orelse return fail(why, .geolocation_invalid);
            const lon = numberOf(o.get("longitude") orelse return fail(why, .geolocation_invalid)) orelse return fail(why, .geolocation_invalid);
            const acc = if (o.get("accuracy")) |a| numberOf(a) orelse return fail(why, .geolocation_invalid) else 50;
            if (!emu_fields.geoOk(lat, lon, acc)) return fail(why, .geolocation_invalid);
            return .{ .latitude = lat, .longitude = lon, .accuracy = acc };
        },
        else => return fail(why, .geolocation_invalid),
    }
}

fn enumText(comptime E: type, obj: std.json.ObjectMap, key: []const u8, names: []const []const u8, values: []const E, why: *?Why) ParamError!E {
    const v = obj.get(key) orelse return @fromBackingInt(@intCast(0));
    const t = switch (v) {
        .string => |s| s,
        else => return fail(why, .media_invalid),
    };
    for (names, values) |n, e| if (std.mem.eql(u8, n, t)) return e;
    return fail(why, .media_invalid);
}

fn parseMedia(v: std.json.Value, why: *?Why) ParamError!msg.EmuMedia {
    const o = switch (v) {
        .object => |x| x,
        else => return fail(why, .media_invalid),
    };
    if (!onlyKeys(o, &.{ "type", "color_scheme", "reduced_motion", "forced_colors", "contrast" })) return fail(why, .media_invalid);
    return .{
        .type = try enumText(msg.EmuMediaType, o, "type", &.{ "screen", "print" }, &.{ .screen, .print }, why),
        .color_scheme = try enumText(msg.EmuColorScheme, o, "color_scheme", &.{ "light", "dark" }, &.{ .light, .dark }, why),
        .reduced_motion = try enumText(msg.EmuReducedMotion, o, "reduced_motion", &.{ "reduce", "no-preference" }, &.{ .reduce, .no_preference }, why),
        .forced_colors = try enumText(msg.EmuForcedColors, o, "forced_colors", &.{ "active", "none" }, &.{ .active, .off }, why),
        .contrast = try enumText(msg.EmuContrast, o, "contrast", &.{ "more", "less", "no-preference" }, &.{ .more, .less, .no_preference }, why),
    };
}

pub const vision_names = [_][]const u8{ "blurredVision", "reducedContrast", "achromatopsia", "deuteranopia", "protanopia", "tritanopia" };
const vision_values = [_]msg.EmuVision{ .blurred_vision, .reduced_contrast, .achromatopsia, .deuteranopia, .protanopia, .tritanopia };

pub fn visionName(v: msg.EmuVision) []const u8 {
    for (vision_values, vision_names) |e, n| if (e == v) return n;
    return "none";
}

fn change(comptime T: type, v: ?std.json.Value, parseOne: anytype, why: *?Why) ParamError!Change(T) {
    const x = v orelse return .keep;
    if (x == .null) return .clear;
    return .{ .set = try parseOne(x, why) };
}

fn parseLocale(v: std.json.Value, why: *?Why) ParamError!Text(max_locale_bytes) {
    const t = switch (v) {
        .string => |s| s,
        else => return fail(why, .locale_invalid),
    };
    if (!localeOk(t)) return fail(why, .locale_invalid);
    return .init(t);
}

fn parseTimezone(v: std.json.Value, why: *?Why) ParamError!Text(msg.max_emu_timezone_bytes) {
    const t = switch (v) {
        .string => |s| s,
        else => return fail(why, .timezone_invalid),
    };
    if (!emu_fields.timezoneOk(t)) return fail(why, .timezone_invalid);
    return .init(t);
}

fn parseVision(v: std.json.Value, why: *?Why) ParamError!msg.EmuVision {
    const t = switch (v) {
        .string => |s| s,
        else => return fail(why, .vision_invalid),
    };
    for (vision_names, vision_values) |n, e| if (std.mem.eql(u8, n, t)) return e;
    return fail(why, .vision_invalid);
}

const top_keys = [_][]const u8{ "id", "action", "reload", "viewport", "user_agent", "locale", "timezone", "geolocation", "media", "vision" };

/// `browser.emulate` 인자 — 모르는 키는 `unknown_key`, 무리마다 까닭(계획 §4). `clear`·`get` 은 무리를 받지 않는다(`get` 은 reload 도).
pub fn parseParams(params: ?std.json.Value, why: *?Why) ParamError!Params {
    why.* = null;
    const obj = switch (params orelse return fail(why, .action_invalid)) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    if (!onlyKeys(obj, &top_keys)) return fail(why, .unknown_key);
    const action_text = switch (obj.get("action") orelse return fail(why, .action_invalid)) {
        .string => |s| s,
        else => return fail(why, .action_invalid),
    };
    const action = std.meta.stringToEnum(Action, action_text) orelse return fail(why, .action_invalid);
    var p: Params = .{ .action = action };
    if (obj.get("reload")) |r| switch (r) {
        .bool => |b| p.reload = b,
        else => return fail(why, .reload_invalid),
    };
    if (action != .set) {
        for (top_keys[3..]) |k| if (obj.get(k) != null) return fail(why, .action_invalid);
        if (action == .get and p.reload) return fail(why, .reload_invalid);
        return p;
    }
    p.viewport = try change(Viewport, obj.get("viewport"), parseViewport, why);
    p.user_agent = try change(UserAgent, obj.get("user_agent"), parseUserAgent, why);
    p.locale = try change(Text(max_locale_bytes), obj.get("locale"), parseLocale, why);
    p.timezone = try change(Text(msg.max_emu_timezone_bytes), obj.get("timezone"), parseTimezone, why);
    p.geolocation = try change(Geo, obj.get("geolocation"), parseGeo, why);
    p.media = try change(msg.EmuMedia, obj.get("media"), parseMedia, why);
    p.vision = try change(msg.EmuVision, obj.get("vision"), parseVision, why);
    return p;
}

// ── op.arg(앱이 다시 푼다 — 같은 `parseParams`) ─────────────────────────────────────────────────────────

fn writeHintsObj(s: *std.json.Stringify, h: *const Hints) !void {
    try s.beginObject();
    try s.objectField("brands");
    try writeBrandArr(s, h.brands[0..h.brand_count]);
    if (h.full_count > 0) {
        try s.objectField("full_version_list");
        try writeBrandArr(s, h.full[0..h.full_count]);
    }
    try s.objectField("platform");
    try s.write(h.platform.slice());
    const rest = [_]struct { key: []const u8, text: []const u8 }{ .{ .key = "platform_version", .text = h.platform_version.slice() }, .{ .key = "architecture", .text = h.architecture.slice() }, .{ .key = "model", .text = h.model.slice() }, .{ .key = "bitness", .text = h.bitness.slice() } };
    for (rest) |f| if (f.text.len > 0) {
        try s.objectField(f.key);
        try s.write(f.text);
    };
    try s.objectField("mobile");
    try s.write(h.mobile);
    try s.endObject();
}

fn writeBrandArr(s: *std.json.Stringify, list: []const Brand) !void {
    try s.beginArray();
    for (list) |*b| {
        try s.beginObject();
        try s.objectField("brand");
        try s.write(b.brand.slice());
        try s.objectField("version");
        try s.write(b.version.slice());
        try s.endObject();
    }
    try s.endArray();
}

fn writeViewport(s: *std.json.Stringify, v: Viewport) !void {
    try s.beginObject();
    try s.objectField("width");
    try s.write(v.width);
    try s.objectField("height");
    try s.write(v.height);
    try s.objectField("device_scale_factor");
    try s.print("{d}", .{v.dsf});
    try s.objectField("mobile");
    try s.write(v.mobile);
    try s.objectField("touch");
    try s.write(v.touch);
    try s.objectField("landscape");
    try s.write(v.landscape);
    try s.endObject();
}

fn writeGeo(s: *std.json.Stringify, g: Geo) !void {
    if (g.unavailable) return s.write("unavailable");
    try s.beginObject();
    try s.objectField("latitude");
    try s.print("{d}", .{g.latitude});
    try s.objectField("longitude");
    try s.print("{d}", .{g.longitude});
    try s.objectField("accuracy");
    try s.print("{d}", .{g.accuracy});
    try s.endObject();
}

fn writeMedia(s: *std.json.Stringify, m: msg.EmuMedia) !void {
    try s.beginObject();
    if (m.type != .none) {
        try s.objectField("type");
        try s.write(if (m.type == .print) "print" else "screen");
    }
    if (m.color_scheme != .none) {
        try s.objectField("color_scheme");
        try s.write(if (m.color_scheme == .light) "light" else "dark");
    }
    if (m.reduced_motion != .none) {
        try s.objectField("reduced_motion");
        try s.write(if (m.reduced_motion == .reduce) "reduce" else "no-preference");
    }
    if (m.forced_colors != .none) {
        try s.objectField("forced_colors");
        try s.write(if (m.forced_colors == .active) "active" else "none");
    }
    if (m.contrast != .none) {
        try s.objectField("contrast");
        try s.write(switch (m.contrast) {
            .more => "more",
            .less => "less",
            else => "no-preference",
        });
    }
    try s.endObject();
}

fn writeUserAgentArg(s: *std.json.Stringify, ua: *const UserAgent) !void {
    try s.beginObject();
    try s.objectField("ua");
    try s.write(ua.ua.slice());
    if (ua.platform.len > 0) {
        try s.objectField("platform");
        try s.write(ua.platform.slice());
    }
    try s.objectField("client_hints");
    switch (ua.mode) {
        .derive => try s.write("derive"),
        .none => try s.write("none"),
        .given => try writeHintsObj(s, &ua.hints),
    }
    try s.endObject();
}

fn writeChange(s: *std.json.Stringify, comptime key: []const u8, ch: anytype, writer: anytype) !void {
    switch (ch) {
        .keep => {},
        .clear => {
            try s.objectField(key);
            try s.write(null);
        },
        .set => |v| {
            try s.objectField(key);
            try writer(s, v);
        },
    }
}

fn writeTextVal(s: *std.json.Stringify, v: anytype) !void {
    try s.write(v.slice());
}

fn writeVisionVal(s: *std.json.Stringify, v: msg.EmuVision) !void {
    try s.write(visionName(v));
}

fn writeUaVal(s: *std.json.Stringify, v: UserAgent) !void {
    try writeUserAgentArg(s, &v);
}

/// op.arg — 정규형 인자 JSON(앱이 같은 `parseParams` 로 다시 푼다).
pub fn serializeArg(gpa: std.mem.Allocator, p: *const Params) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (blk: {
        s.beginObject() catch |e| break :blk e;
        s.objectField("action") catch |e| break :blk e;
        s.write(@tagName(p.action)) catch |e| break :blk e;
        if (p.reload) {
            s.objectField("reload") catch |e| break :blk e;
            s.write(true) catch |e| break :blk e;
        }
        writeChange(&s, "viewport", p.viewport, writeViewport) catch |e| break :blk e;
        writeChange(&s, "user_agent", p.user_agent, writeUaVal) catch |e| break :blk e;
        writeChange(&s, "locale", p.locale, writeTextVal) catch |e| break :blk e;
        writeChange(&s, "timezone", p.timezone, writeTextVal) catch |e| break :blk e;
        writeChange(&s, "geolocation", p.geolocation, writeGeo) catch |e| break :blk e;
        writeChange(&s, "media", p.media, writeMedia) catch |e| break :blk e;
        writeChange(&s, "vision", p.vision, writeVisionVal) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ── 탭 상태 ─────────────────────────────────────────────────────────────────────────────────────────────

/// 거절의 까닭(`{"reason","message"}` 로 간다 — control_browser 가 코드를 고른다).
pub const Failure = struct { reason: []const u8, message: []const u8 };

/// 그 탭의 emulation grant 하나(`sync` — 주인 pane·어느 호스트든·묶인 호스트).
pub const OwnerGrant = struct { pane: u64, any_host: bool = false, host: []const u8 = "" };

/// sidecar 의 마지막 답(`emulation_state` — 출처 목록은 따로 사본).
pub const Acked = struct {
    generation: u32 = 0,
    on_site: bool = true,
    alive: bool = true,
    pending: bool = false,
    fit_scale: f32 = 1,
    active_mask: u16 = 0,
    failed_mask: u16 = 0,
    reason: msg.EmuFailReason = .none,
};

pub const Origin = Text(emu_fields_origin_bytes);
const emu_fields_origin_bytes = ws.fields.max_origin_bytes;

pub const Call = struct {
    pane: u64,
    params: *const Params,
    /// 그 pane 의 emulation grant(어느 호스트든 = 에이전트 탭, 아니면 grant 호스트 = 사이트).
    any_host: bool,
    grant_host: []const u8 = "",
    /// 그 grant 가 탭과 함께 생겼다(에이전트 탭 — 처음 몰 때 알림).
    birth: bool = false,
    now_ms: i64 = 0,
};

pub const Outcome = struct { changed: bool = false, touch_added: bool = false };

/// 덧쓰기 한 무리 — 그대로·지움·바꿈.
fn merge(comptime T: type, ch: Change(T), slot: *?T) void {
    switch (ch) {
        .keep => {},
        .clear => slot.* = null,
        .set => |v| slot.* = v,
    }
}

pub const Tab = struct {
    settings: Settings = .{},
    owner: u64 = 0,
    agent_tab: bool = false,
    /// 사이트(빈 글 = 어느 호스트든 — 에이전트 탭).
    site: cpg.GrantHost = .{},
    gen: u32 = 0,
    sent_gen: u32 = 0,
    acked: Acked = .{},
    /// sidecar 가 대신 허용한 위치 출처(재시작 때 되돌린다 — 계획 §13 P2-6).
    auto: [msg.max_emu_geo_origins]Origin = @splat(.{}),
    auto_count: usize = 0,
    /// 다음 `emulation` 에 되돌릴 출처를 싣는다(브라우저가 새로 만들어졌다 — 재생).
    restore_next: bool = false,
    changes: [max_changes_per_s]i64 = @splat(std.math.minInt(i64) / 2),
    change_next: usize = 0,
    noticed_gen: u32 = 0,
    /// 추정·준 client hints 의 사본(wire 가 빌린다).
    hints_buf: Hints = .{},
    hints_kind: enum { given, derived, none } = .none,
    accept_buf: [msg.max_emu_accept_language_bytes]u8 = undefined,
    icu_buf: [msg.max_emu_icu_locale_bytes]u8 = undefined,

    /// 흉내가 설정됐다(탭 제목의 ◫ — 사용자 탭이 사이트 밖이라 걸려 있지 않아도: 「이 탭에 흉내가 설정됨」, 계획 §11).
    pub fn active(self: *const Tab) bool {
        return self.settings.any();
    }

    fn bump(self: *Tab) void {
        self.gen +%= 1;
        if (self.gen == 0) self.gen = 1;
    }

    fn rateOk(self: *Tab, now_ms: i64) bool {
        const oldest = self.changes[self.change_next];
        if (now_ms - oldest < 1000) return false;
        self.changes[self.change_next] = now_ms;
        self.change_next = (self.change_next + 1) % max_changes_per_s;
        return true;
    }

    /// 한 번의 `set`·`clear`(get 은 부른 쪽이 결과만). 주인 아닌 pane → `emulated_by_other_pane`, 초당 10 번 → `resource_busy`.
    pub fn apply(self: *Tab, call: Call, why: *Failure) error{Rejected}!Outcome {
        const p = call.params;
        if (p.action == .get) return .{};
        if (self.active() and self.owner != 0 and self.owner != call.pane) {
            why.* = .{ .reason = "emulated_by_other_pane", .message = "another pane is emulating a device on this tab — it can change or clear it; you can read it with action get" };
            return error.Rejected;
        }
        if (!self.rateOk(call.now_ms)) {
            why.* = .{ .reason = "resource_busy", .message = "too many emulation changes on this tab — at most 10 per second" };
            return error.Rejected;
        }
        var out: Outcome = .{};
        const before_touch = if (self.settings.viewport) |v| v.touch else false;
        var next = self.settings;
        if (p.action == .clear) {
            next = .{};
        } else {
            merge(Viewport, p.viewport, &next.viewport);
            merge(UserAgent, p.user_agent, &next.user_agent);
            merge(Text(max_locale_bytes), p.locale, &next.locale);
            merge(Text(msg.max_emu_timezone_bytes), p.timezone, &next.timezone);
            merge(Geo, p.geolocation, &next.geolocation);
            merge(msg.EmuMedia, p.media, &next.media);
            merge(msg.EmuVision, p.vision, &next.vision);
            // `media:{}` 은 흉내 없음 — 지운 것과 같다.
            if (next.media) |m| if (!m.any()) {
                next.media = null;
            };
        }
        out.changed = !std.meta.eql(next, self.settings) or p.reload;
        if (!std.meta.eql(next, self.settings)) {
            self.settings = next;
            self.bump();
        }
        out.touch_added = !before_touch and if (self.settings.viewport) |v| v.touch else false;
        if (self.active()) {
            if (self.owner == 0) {
                self.owner = call.pane;
                self.site = if (call.any_host) .{} else cpg.GrantHost.init(call.grant_host);
                self.agent_tab = call.birth;
            }
        } else {
            self.owner = 0;
            self.site = .{};
            self.agent_tab = false;
        }
        return out;
    }

    /// 주인의 emulation grant 가 사라졌거나 다른 호스트로 바뀌었으면(사이트에 묶인 흉내 — 새 동의) 모두 지운다. 바꿨으면 참.
    pub fn sync(self: *Tab, grants: []const OwnerGrant) bool {
        if (!self.active()) return false;
        for (grants) |g| if (g.pane == self.owner) {
            if (g.any_host and self.site.len == 0) return false;
            if (!g.any_host and self.site.len != 0 and std.mem.eql(u8, g.host, self.site.slice())) return false;
            break;
        };
        self.clearAll();
        return true;
    }

    pub fn clearAll(self: *Tab) void {
        if (!self.active()) return;
        self.settings = .{};
        self.owner = 0;
        self.site = .{};
        self.agent_tab = false;
        self.bump();
    }

    /// sidecar 의 답(그 세대가 아니어도 받는다 — 살아 있음·사이트 안팎·줄임은 지금 값이다). 대신 허용한 출처는 늘 마지막 목록.
    pub fn onState(self: *Tab, st: msg.EmulationState) void {
        self.acked = .{ .generation = st.generation, .on_site = st.on_site, .alive = st.alive, .pending = st.pending, .fit_scale = st.fit_scale, .active_mask = st.active_mask, .failed_mask = st.failed_mask, .reason = st.reason };
        self.auto_count = st.auto_count;
        for (st.auto_allowed[0..st.auto_count], 0..) |o, i| self.auto[i] = .init(o);
    }

    /// 브라우저가 새로 만들어졌다(처음이거나 sidecar 가 다시 떴다) — 다음 `emulation` 은 지금 상태 + 옛 sidecar 가 대신 허용한 출처의 되돌림.
    pub fn browserRecreated(self: *Tab) void {
        self.sent_gen = 0;
        self.restore_next = self.auto_count > 0;
        self.acked = .{};
    }

    /// 보낼 것이 있는가(세대가 바뀌었거나 되돌릴 출처가 있다).
    pub fn needsSend(self: *const Tab) bool {
        return self.sent_gen != self.gen or self.restore_next or (self.sent_gen == 0 and self.active());
    }

    /// wire `emulation`(글은 이 탭의 칸을 빌린다 — 곧 encode 한다). `pane_mobile` 은 쓰지 않는다 — client hints 의 모바일은 viewport.mobile.
    pub fn toWire(self: *Tab, browser: msg.BrowserId) msg.Emulation {
        var v: msg.Emulation = .{ .browser = browser, .generation = self.gen };
        const st = &self.settings;
        if (self.site.len != 0 and self.active()) {
            v.flags.site_bound = true;
            v.site = self.site.slice();
        }
        if (st.viewport) |vp| {
            v.flags.viewport = true;
            v.flags.mobile = vp.mobile;
            v.flags.touch = vp.touch;
            v.flags.landscape = vp.landscape;
            v.width = vp.width;
            v.height = vp.height;
            v.dsf = vp.dsf;
        }
        self.hints_kind = .none;
        if (st.user_agent) |*ua| {
            v.flags.ua = true;
            v.ua = ua.ua.slice();
            v.platform = ua.platform.slice();
            const hints: ?Hints = switch (ua.mode) {
                .given => ua.hints,
                .derive => deriveHints(ua.ua.slice(), if (st.viewport) |vp| vp.mobile else false),
                .none => null,
            };
            if (hints) |h| {
                self.hints_buf = h;
                self.hints_kind = if (ua.mode == .given) .given else .derived;
                v.flags.hints = true;
                const hb = &self.hints_buf;
                v.hints = .{ .brand_count = hb.brand_count, .full_count = hb.full_count, .platform = hb.platform.slice(), .platform_version = hb.platform_version.slice(), .architecture = hb.architecture.slice(), .model = hb.model.slice(), .bitness = hb.bitness.slice(), .mobile = hb.mobile };
                for (0..hb.brand_count) |i| v.hints.brands[i] = .{ .brand = hb.brands[i].brand.slice(), .version = hb.brands[i].version.slice() };
                for (0..hb.full_count) |i| v.hints.full_list[i] = .{ .brand = hb.full[i].brand.slice(), .version = hb.full[i].version.slice() };
            }
        }
        if (st.locale) |*l| {
            v.flags.locale = true;
            v.accept_language = acceptLanguage(l.slice(), &self.accept_buf);
            v.icu_locale = icuName(l.slice(), &self.icu_buf);
        }
        if (st.timezone) |*t| {
            v.flags.timezone = true;
            v.timezone = t.slice();
        }
        if (st.geolocation) |g| {
            v.flags.geo = true;
            if (g.unavailable) v.flags.geo_unavailable = true else {
                v.latitude = g.latitude;
                v.longitude = g.longitude;
                v.accuracy = g.accuracy;
            }
        }
        if (st.media) |m| {
            v.flags.media = true;
            v.media = m;
        }
        if (st.vision) |x| {
            v.flags.vision = true;
            v.vision = x;
        }
        if (self.restore_next) {
            v.restore_count = @intCast(self.auto_count);
            for (self.auto[0..self.auto_count], 0..) |*o, i| v.restore[i] = o.slice();
        }
        return v;
    }

    /// 보냈다(`toWire` 를 encode 했다).
    pub fn sent(self: *Tab) void {
        self.sent_gen = self.gen;
        self.restore_next = false;
    }

    /// 사용자가 보는 줄임 — maru 가 sidecar 와 **같은 셈**(`emu_fields.fitScale`)으로 지금 pane 크기(DIP)에서 구한다. sidecar 의 답을 기다리지
    /// 않는다: 흉내 frame 은 같은 관으로 W9b 의 CDP 보다 먼저 가서 Chromium 은 이미 새 scale 이다(답을 기다리면 바꾼 직후의 누름이 옛 값을 곱해 다른
    /// 요소를 눌렀다 — 적대 리뷰). 흉내 화면이 없거나, 사용자 탭이 사이트 밖이거나, 이 세대의 화면 흉내가 실패했으면 1. W9b 입력 좌표에 곱한다(E3).
    pub fn inputScale(self: *const Tab, pane_w: u32, pane_h: u32) f32 {
        const vp = self.settings.viewport orelse return 1;
        if (!self.onSite()) return 1;
        if (self.acked.generation == self.gen and self.acked.failed_mask & (1 << @backingInt(msg.EmuGroup.viewport)) != 0) return 1;
        return emu_fields.fitScale(pane_w, pane_h, vp.width, vp.height);
    }

    /// 사용자가 보는 흉내 화면의 사각형(DIP, pane 왼쪽 위) — 흉내 화면이 걸려 있을 때만(바깥을 어둡게 테두리 — 계획 §11). 줄임은 `inputScale` 과 같다.
    pub fn shownSize(self: *const Tab, pane_w: u32, pane_h: u32) ?struct { w: f32, h: f32 } {
        const vp = self.settings.viewport orelse return null;
        if (!self.onSite()) return null;
        if (self.acked.generation == self.gen and self.acked.failed_mask & (1 << @backingInt(msg.EmuGroup.viewport)) != 0) return null;
        const f = emu_fields.fitScale(pane_w, pane_h, vp.width, vp.height);
        // 가로(landscape)는 화면 방향만 바꾼다 — 배치 크기는 준 width·height 그대로다(`screenOrientation`).
        return .{ .w = @as(f32, @floatFromInt(vp.width)) * f, .h = @as(f32, @floatFromInt(vp.height)) * f };
    }

    /// 탭·세대마다 한 번 — 사용자가 흉내 중인 에이전트 탭을 몬다(계획 §9).
    pub fn wantsNotice(self: *Tab) bool {
        if (!self.active() or !self.agent_tab or self.noticed_gen == self.gen) return false;
        self.noticed_gen = self.gen;
        return true;
    }

    /// 사이트 안인가(사용자 탭 — 사이트 밖이면 걸려 있지 않다). sidecar 가 알린 값.
    pub fn onSite(self: *const Tab) bool {
        return self.site.len == 0 or self.acked.on_site;
    }

    /// 상태 이름(계획 §4): 아직 그 세대의 답이 없으면 sent, 렌더러가 없으면 waiting_renderer, 실패가 있으면 failed, 답을 기다리면 sent, 아니면 active.
    pub fn stateName(self: *const Tab) []const u8 {
        if (self.acked.generation != self.gen) return if (!self.acked.alive) "waiting_renderer" else "sent";
        if (!self.acked.alive and self.acked.pending) return "waiting_renderer";
        if (self.acked.failed_mask != 0) return "failed";
        if (self.acked.pending) return "sent";
        return "active";
    }

    /// 요약 글 — `browser.list` 의 `emulation.summary`·CLI 줄 끝·Browser Grants 줄(`390×844 mobile, fr-FR, Asia/Kolkata[, off-site]`).
    pub fn summary(self: *const Tab, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        const sep = struct {
            fn put(wr: *std.Io.Writer, f: *bool) void {
                if (!f.*) wr.writeAll(", ") catch {};
                f.* = false;
            }
        };
        const st = &self.settings;
        if (st.viewport) |vp| {
            sep.put(&w, &first);
            w.print("{d}\u{00D7}{d}", .{ vp.width, vp.height }) catch {};
            if (vp.dsf != 1) w.print("@{d}", .{vp.dsf}) catch {};
            if (vp.mobile) w.writeAll(" mobile") catch {};
            if (vp.touch) w.writeAll(" touch") catch {};
            if (vp.landscape) w.writeAll(" landscape") catch {};
        }
        if (st.user_agent != null) {
            sep.put(&w, &first);
            w.writeAll("user agent") catch {};
        }
        if (st.locale) |*l| {
            sep.put(&w, &first);
            w.writeAll(l.slice()) catch {};
        }
        if (st.timezone) |*t| {
            sep.put(&w, &first);
            w.writeAll(t.slice()) catch {};
        }
        if (st.geolocation) |g| {
            sep.put(&w, &first);
            if (g.unavailable) w.writeAll("location unavailable") catch {} else w.writeAll("location (agent)") catch {};
        }
        if (st.media) |m| {
            sep.put(&w, &first);
            w.writeAll("media") catch {};
            if (m.type == .print) w.writeAll(" print") catch {};
            if (m.color_scheme != .none) w.writeAll(if (m.color_scheme == .light) " light" else " dark") catch {};
            if (m.forced_colors == .active) w.writeAll(" forced-colors") catch {};
        }
        if (st.vision) |x| {
            sep.put(&w, &first);
            w.writeAll(visionName(x)) catch {};
        }
        if (!self.onSite()) {
            sep.put(&w, &first);
            w.writeAll("off-site") catch {};
        }
        return w.buffered();
    }

    /// 결과 JSON(계획 §4) — `set`·`clear`·`get` 모두. `pane_w`·`pane_h` 는 사용자가 보는 pane(DIP — 맞춤을 미리 보인다), `reloaded` 는 이번에
    /// 새로고침을 보냈는가.
    pub fn resultJson(self: *const Tab, out: std.mem.Allocator, pane_w: u32, pane_h: u32, reloaded: bool, touch_added: bool) std.mem.Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        self.writeResult(&s, pane_w, pane_h, reloaded, touch_added) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn fit(self: *const Tab, pane_w: u32, pane_h: u32) f32 {
        const vp = self.settings.viewport orelse return 1;
        if (self.acked.generation == self.gen and self.acked.active_mask & 1 != 0) return self.acked.fit_scale;
        return emu_fields.fitScale(pane_w, pane_h, vp.width, vp.height);
    }

    fn writeResult(self: *const Tab, s: *std.json.Stringify, pane_w: u32, pane_h: u32, reloaded: bool, touch_added: bool) !void {
        const st = &self.settings;
        const f = self.fit(pane_w, pane_h);
        try s.beginObject();
        try s.objectField("emulation");
        try s.beginObject();
        if (st.viewport) |vp| {
            try s.objectField("viewport");
            try s.beginObject();
            try s.objectField("width");
            try s.write(vp.width);
            try s.objectField("height");
            try s.write(vp.height);
            try s.objectField("device_scale_factor");
            try s.print("{d}", .{vp.dsf});
            try s.objectField("mobile");
            try s.write(vp.mobile);
            try s.objectField("touch");
            try s.write(vp.touch);
            try s.objectField("landscape");
            try s.write(vp.landscape);
            try s.objectField("fit_scale");
            try s.print("{d}", .{f});
            try s.objectField("shown");
            try s.write(if (f < 1) "fit" else "exact");
            try s.endObject();
        }
        if (st.user_agent) |*ua| {
            try s.objectField("user_agent");
            try s.beginObject();
            try s.objectField("ua");
            try s.write(ua.ua.slice());
            if (ua.platform.len > 0) {
                try s.objectField("platform");
                try s.write(ua.platform.slice());
            }
            try s.objectField("client_hints");
            const kind: []const u8 = switch (ua.mode) {
                .given => "given",
                .none => "none",
                .derive => if (deriveHints(ua.ua.slice(), false) != null) "derived" else "none",
            };
            try s.write(kind);
            try s.endObject();
        }
        if (st.locale) |*l| {
            try s.objectField("locale");
            try s.write(l.slice());
        }
        if (st.timezone) |*t| {
            try s.objectField("timezone");
            try s.write(t.slice());
        }
        if (st.geolocation) |g| {
            try s.objectField("geolocation");
            try writeGeo(s, g);
        }
        if (st.media) |m| {
            try s.objectField("media");
            try writeMedia(s, m);
        }
        if (st.vision) |x| {
            try s.objectField("vision");
            try s.write(visionName(x));
        }
        try s.endObject();
        try s.objectField("site");
        if (self.site.len == 0) try s.write(null) else try s.write(self.site.slice());
        try s.objectField("active");
        try s.write(self.active() and self.onSite());
        try s.objectField("state");
        // 지운 흉내도 같은 이름이다 — 렌더러가 죽어 지움이 쌓여 있으면 `waiting_renderer`(Chromium 은 새 렌더러에 옛 흉내를 다시 건다 — E4,
        // 쌓인 지움은 새 렌더러에서 나간다), 지움을 보내지 못했으면 `failed`(변이 캠페인 WE53 — 전에는 지웠으면 늘 `active` 라 답했다).
        try s.write(self.stateName());
        if (self.acked.generation == self.gen and self.acked.failed_mask != 0) {
            try s.objectField("failed");
            try s.beginArray();
            inline for (@import("type_info_fields").fields(msg.EmuGroup)) |fd| {
                if (self.acked.failed_mask & (1 << fd.value) != 0) {
                    try s.beginObject();
                    try s.objectField("group");
                    try s.write(fd.name);
                    try s.objectField("reason");
                    try s.write(@tagName(self.acked.reason));
                    try s.endObject();
                }
            }
            try s.endArray();
        }
        try s.objectField("applies");
        try s.write("now");
        try s.objectField("headers_from");
        try s.write(if (reloaded) "now" else "next_navigation");
        if (reloaded) {
            try s.objectField("reloaded");
            try s.write(true);
        }
        try s.objectField("not_covered");
        try s.write(&[_][]const u8{ "cross_site_iframes", "service_workers", "workers_started_before", "worker_accept_language" });
        if (st.timezone != null or st.locale != null) {
            try s.objectField("process_shared");
            var shared: [2][]const u8 = undefined;
            var n: usize = 0;
            if (st.timezone != null) {
                shared[n] = "timezone";
                n += 1;
            }
            if (st.locale != null) {
                shared[n] = "locale";
                n += 1;
            }
            try s.write(shared[0..n]);
        }
        var warns: [5][]const u8 = undefined;
        var nw: usize = 0;
        if (touch_added and !reloaded) {
            warns[nw] = "touch_events_after_reload";
            nw += 1;
        }
        if (st.viewport) |vp| if (vp.touch) {
            warns[nw] = "pointer_events_are_mouse";
            nw += 1;
        };
        if (f < 1) {
            warns[nw] = "user_sees_scaled";
            nw += 1;
        }
        if (self.active() and !self.onSite()) {
            warns[nw] = "off_site_inactive";
            nw += 1;
        }
        if (nw > 0) {
            try s.objectField("warnings");
            try s.write(warns[0..nw]);
        }
        try s.endObject();
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(json: []const u8, why: *?Why) !Params {
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer v.deinit();
    return parseParams(v.value, why);
}

fn expectWhy(json: []const u8, want: ?Why) !void {
    var why: ?Why = null;
    try testing.expectError(error.InvalidParams, parse(json, &why));
    try testing.expectEqual(want, why);
}

test "W9e①: 인자 표 — 무리마다 까닭(범위·NaN 꼴·64 Mpx·배율·UA·플랫폼·client hints·언어·시간대·위치·미디어·색각), 모르는 키, action 마다 받는 키" {
    try expectWhy("{\"id\":1,\"action\":\"set\",\"x\":1}", .unknown_key);
    try expectWhy("{\"id\":1,\"action\":\"nope\"}", .action_invalid);
    try expectWhy("{\"id\":1}", .action_invalid);
    try expectWhy("{\"id\":1,\"action\":\"clear\",\"timezone\":\"UTC\"}", .action_invalid);
    try expectWhy("{\"id\":1,\"action\":\"get\",\"reload\":true}", .reload_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"reload\":1}", .reload_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":0,\"height\":800}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":4097,\"height\":800}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390.5,\"height\":800}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":800,\"zoom\":2}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":4096,\"height\":4096,\"device_scale_factor\":3}}", .viewport_too_large);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":800,\"device_scale_factor\":5}}", .dsf_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":800,\"device_scale_factor\":\"2\"}}", .dsf_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":800,\"mobile\":1}}", .viewport_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"\"}}", .ua_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"a\\r\\nX-Evil: 1\"}}", .ua_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"한\"}}", .ua_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"platform\":\"a\\u0001\"}}", .platform_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":\"guess\"}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":{\"brands\":[],\"platform\":\"Android\"}}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":{\"brands\":[{\"brand\":\"A\",\"version\":\"1\"}]}}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"locale\":\"f\"}", .locale_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"locale\":\"fr_FR\"}", .locale_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"locale\":\"fr-FR;q=0.9\"}", .locale_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"timezone\":\"Asia/Kolkata\\\"\"}", .timezone_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"geolocation\":{\"latitude\":91,\"longitude\":0}}", .geolocation_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"geolocation\":{\"latitude\":0}}", .geolocation_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"geolocation\":{\"latitude\":0,\"longitude\":0,\"accuracy\":100001}}", .geolocation_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"geolocation\":\"paris\"}", .geolocation_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"media\":{\"color_scheme\":\"blue\"}}", .media_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"media\":{\"pointer\":\"coarse\"}}", .media_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"vision\":\"colorblind\"}", .vision_invalid);
    var why: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844,\"device_scale_factor\":3,\"mobile\":true},\"timezone\":null,\"geolocation\":\"unavailable\",\"reload\":true}", &why);
    try testing.expect(p.reload and p.viewport == .set and p.timezone == .clear and p.locale == .keep);
    try testing.expectEqual(@as(f32, 3), p.viewport.set.dsf);
    try testing.expect(p.geolocation.set.unavailable);
}

test "W9e①: client hints 추정 — Chrome/N 이 있을 때만(Safari·Firefox 는 없음), 플랫폼 토큰(Android 가 Linux 보다 먼저), Mobile 토큰·viewport.mobile" {
    const android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36";
    const h = deriveHints(android, false).?;
    try testing.expectEqualStrings("Chromium", h.brands[0].brand.slice());
    try testing.expectEqualStrings("154", h.brands[0].version.slice());
    try testing.expectEqualStrings("Not A(Brand", h.brands[1].brand.slice());
    try testing.expectEqualStrings("Android", h.platform.slice());
    try testing.expect(h.mobile);
    const win = deriveHints("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", false).?;
    try testing.expectEqualStrings("Windows", win.platform.slice());
    try testing.expect(!win.mobile);
    try testing.expect(deriveHints("Mozilla/5.0 (Windows NT 10.0) Chrome/120.0.0.0 Safari/537.36", true).?.mobile); // viewport.mobile
    try testing.expectEqualStrings("macOS", deriveHints("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/99.0 Safari", false).?.platform.slice());
    try testing.expectEqualStrings("Chrome OS", deriveHints("Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) Chrome/99.0 Safari", false).?.platform.slice());
    try testing.expect(deriveHints("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", true) == null);
    try testing.expect(deriveHints("Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0", false) == null);
    try testing.expect(deriveHints("Chrome/ x", false) == null);
}

test "W9e①: Accept-Language 목록과 ICU 이름 — fr-FR → fr-FR,fr·fr_FR, en → en, zh-Hant-TW → zh-Hant-TW,zh·zh_Hant_TW, BCP 47 모양" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("fr-FR,fr", acceptLanguage("fr-FR", &buf));
    try testing.expectEqualStrings("en", acceptLanguage("en", &buf));
    try testing.expectEqualStrings("zh-Hant-TW,zh", acceptLanguage("zh-Hant-TW", &buf));
    var ib: [40]u8 = undefined;
    try testing.expectEqualStrings("zh_Hant_TW", icuName("zh-Hant-TW", &ib));
    for ([_][]const u8{ "fr-FR", "en", "zh-Hant-TW", "es-419", "de-CH-1996" }) |t| try testing.expect(localeOk(t));
    for ([_][]const u8{ "", "f", "1a", "fr--FR", "fr-", "fr-toolongsubtag", "fr FR", "fr-FR," }) |t| try testing.expect(!localeOk(t));
    try testing.expect(emu_fields.acceptLanguageOk(acceptLanguage("de-CH-1996", &buf)));
}

fn testCall(params: *const Params, pane: u64, now: i64) Call {
    return .{ .pane = pane, .params = params, .any_host = true, .birth = true, .now_ms = now };
}

test "W9e①: 덧쓰기 — 준 무리만 바꾸고 null 은 그 무리를 지운다, clear 는 모두, 같은 값은 세대를 올리지 않는다, media:{} 는 지움" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    var p = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844},\"timezone\":\"UTC\"}", &w);
    _ = try t.apply(testCall(&p, 5, 0), &why);
    try testing.expectEqual(@as(u32, 1), t.gen);
    p = try parse("{\"id\":1,\"action\":\"set\",\"locale\":\"fr-FR\"}", &w);
    _ = try t.apply(testCall(&p, 5, 100), &why);
    try testing.expect(t.settings.viewport != null and t.settings.timezone != null and t.settings.locale != null); // 시간대·화면은 그대로
    p = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":null}", &w);
    _ = try t.apply(testCall(&p, 5, 200), &why);
    try testing.expect(t.settings.timezone == null and t.settings.viewport != null);
    const g = t.gen;
    p = try parse("{\"id\":1,\"action\":\"set\",\"locale\":\"fr-FR\"}", &w);
    const same = try t.apply(testCall(&p, 5, 300), &why);
    try testing.expect(!same.changed and t.gen == g);
    p = try parse("{\"id\":1,\"action\":\"set\",\"media\":{}}", &w);
    _ = try t.apply(testCall(&p, 5, 400), &why);
    try testing.expect(t.settings.media == null);
    p = try parse("{\"id\":1,\"action\":\"clear\"}", &w);
    _ = try t.apply(testCall(&p, 5, 500), &why);
    try testing.expect(!t.active() and t.owner == 0);
}

test "W9e①: 주인 pane — 다른 pane 의 set·clear 는 emulated_by_other_pane(get 은 된다), 초당 10 번 넘으면 resource_busy, 다 지우면 주인이 풀린다" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const set = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"UTC\"}", &w);
    _ = try t.apply(testCall(&set, 5, 0), &why);
    try testing.expectError(error.Rejected, t.apply(testCall(&set, 6, 1), &why));
    try testing.expectEqualStrings("emulated_by_other_pane", why.reason);
    const get = try parse("{\"id\":1,\"action\":\"get\"}", &w);
    _ = try t.apply(testCall(&get, 6, 2), &why);
    for (1..10) |i| _ = try t.apply(testCall(&set, 5, @intCast(10 + i)), &why);
    try testing.expectError(error.Rejected, t.apply(testCall(&set, 5, 20), &why));
    try testing.expectEqualStrings("resource_busy", why.reason);
    const clear = try parse("{\"id\":1,\"action\":\"clear\"}", &w);
    _ = try t.apply(testCall(&clear, 5, 2000), &why);
    _ = try t.apply(testCall(&set, 6, 2100), &why); // 이제 다른 pane 이 주인이 될 수 있다
    try testing.expectEqual(@as(u64, 6), t.owner);
}

test "W9e①: grant sync — 주인의 grant 가 사라지거나 다른 호스트로 바뀌면 모두 지운다, 같은 호스트면 그대로, 에이전트 탭은 어느 호스트든" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const set = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"UTC\"}", &w);
    _ = try t.apply(.{ .pane = 5, .params = &set, .any_host = false, .grant_host = "a.test" }, &why);
    try testing.expectEqualStrings("a.test", t.site.slice());
    try testing.expect(!t.sync(&.{.{ .pane = 5, .host = "a.test" }}));
    try testing.expect(t.sync(&.{.{ .pane = 5, .host = "bank.test" }})); // 다른 호스트로 다시 허용 — 새 동의
    try testing.expect(!t.active());
    _ = try t.apply(.{ .pane = 5, .params = &set, .any_host = true, .birth = true }, &why);
    try testing.expect(!t.sync(&.{.{ .pane = 5, .any_host = true }}));
    try testing.expect(t.sync(&.{.{ .pane = 6, .any_host = true }})); // 주인의 grant 가 없다
    try testing.expect(!t.sync(&.{})); // 이미 비었다
}

test "W9e①: wire 꼴 — 사용자 탭은 사이트에 묶이고, 언어는 목록·ICU, UA 는 추정 hints, 재생은 대신 허용한 출처를 싣는다 — 닫힌 칸을 지난다" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844,\"device_scale_factor\":3,\"mobile\":true,\"touch\":true},\"user_agent\":{\"ua\":\"Mozilla/5.0 (Linux; Android 14) Chrome/154.0.0.0 Mobile Safari/537.36\"},\"locale\":\"fr-FR\",\"timezone\":\"Asia/Kolkata\",\"geolocation\":{\"latitude\":48.85,\"longitude\":2.35},\"media\":{\"color_scheme\":\"light\"},\"vision\":\"deuteranopia\"}", &w);
    _ = try t.apply(.{ .pane = 5, .params = &p, .any_host = false, .grant_host = "a.test" }, &why);
    var auto: msg.EmulationState = .{ .browser = 9, .generation = t.gen, .auto_count = 1 };
    auto.auto_allowed[0] = "https://a.test";
    t.onState(auto);
    t.browserRecreated();
    try testing.expect(t.needsSend());
    const v = t.toWire(9);
    try emu_fields.checkEmulation(v);
    try testing.expect(v.flags.site_bound and v.flags.hints and v.flags.touch);
    try testing.expectEqualStrings("a.test", v.site);
    try testing.expectEqualStrings("fr-FR,fr", v.accept_language);
    try testing.expectEqualStrings("fr_FR", v.icu_locale);
    try testing.expectEqualStrings("Android", v.hints.platform);
    try testing.expectEqual(@as(f64, 50), v.accuracy);
    try testing.expectEqual(@as(u8, 1), v.restore_count);
    try testing.expectEqualStrings("https://a.test", v.restore[0]);
    t.sent();
    try testing.expect(!t.needsSend());
    try testing.expectEqual(@as(u8, 0), t.toWire(9).restore_count); // 되돌림은 재생 한 번
    t.clearAll();
    try emu_fields.checkEmulation(t.toWire(9)); // 모두 지움 — 사이트도 없다
    try testing.expect(!t.toWire(9).flags.site_bound);
}

test "W9e①: 결과 JSON — viewport 의 fit·shown, client_hints 이름, not_covered·process_shared 는 늘, 경고(터치·줄임·사이트 밖), 상태 이름(sent·active·failed·waiting_renderer)" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844,\"touch\":true},\"user_agent\":{\"ua\":\"Mozilla/5.0 (iPhone) Version/17 Safari/604.1\"},\"timezone\":\"UTC\"}", &w);
    const out = try t.apply(.{ .pane = 5, .params = &p, .any_host = false, .grant_host = "a.test" }, &why);
    const j1 = try t.resultJson(testing.allocator, 640, 400, false, out.touch_added);
    defer testing.allocator.free(j1);
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, j1, .{});
    defer v.deinit();
    const r = v.value.object;
    const vp = r.get("emulation").?.object.get("viewport").?.object;
    try testing.expectEqualStrings("fit", vp.get("shown").?.string);
    try testing.expectEqual(@as(f64, 0.4739), vp.get("fit_scale").?.float);
    try testing.expectEqualStrings("none", r.get("emulation").?.object.get("user_agent").?.object.get("client_hints").?.string); // Safari 꼴 — 추정 없음
    try testing.expectEqualStrings("sent", r.get("state").?.string);
    try testing.expectEqualStrings("a.test", r.get("site").?.string);
    try testing.expectEqual(@as(usize, 4), r.get("not_covered").?.array.items.len);
    try testing.expectEqualStrings("timezone", r.get("process_shared").?.array.items[0].string);
    try testing.expectEqualStrings("next_navigation", r.get("headers_from").?.string);
    const warns = r.get("warnings").?.array.items;
    try testing.expectEqualStrings("touch_events_after_reload", warns[0].string);
    try testing.expectEqualStrings("pointer_events_are_mouse", warns[1].string);
    try testing.expectEqualStrings("user_sees_scaled", warns[2].string);
    // sidecar 답 — 사이트 밖·실패.
    t.onState(.{ .browser = 9, .generation = t.gen, .on_site = false, .fit_scale = 0.4739, .active_mask = 1, .failed_mask = 1 << 3, .reason = .timezone_unknown });
    try testing.expectEqualStrings("failed", t.stateName());
    try testing.expectEqual(@as(f32, 1), t.inputScale(640, 400)); // 사이트 밖 — 걸려 있지 않다
    try testing.expect(t.shownSize(640, 400) == null);
    t.onState(.{ .browser = 9, .generation = t.gen, .fit_scale = 0.4739, .active_mask = 1 });
    try testing.expectEqual(@as(f32, 0.4739), t.inputScale(640, 400));
    try testing.expectEqual(@as(f32, 0.5924), t.inputScale(800, 500)); // pane 이 바뀌면 곧 — 답을 기다리지 않는다
    const shown = t.shownSize(640, 400).?;
    try testing.expectApproxEqAbs(@as(f32, 184.82), shown.w, 0.01);
    t.onState(.{ .browser = 9, .generation = t.gen, .on_site = false, .fit_scale = 0.4739, .active_mask = 1, .failed_mask = 1 << 3, .reason = .timezone_unknown });
    var sb: [128]u8 = undefined;
    try testing.expectEqualStrings("390\u{00D7}844 touch, user agent, UTC, off-site", t.summary(&sb));
    const j2 = try t.resultJson(testing.allocator, 640, 400, true, false);
    defer testing.allocator.free(j2);
    try testing.expect(std.mem.indexOf(u8, j2, "\"active\":false") != null and std.mem.indexOf(u8, j2, "off_site_inactive") != null);
    try testing.expect(std.mem.indexOf(u8, j2, "{\"group\":\"timezone\",\"reason\":\"timezone_unknown\"}") != null);
    try testing.expect(std.mem.indexOf(u8, j2, "\"reloaded\":true") != null and std.mem.indexOf(u8, j2, "\"headers_from\":\"now\"") != null);
    t.onState(.{ .browser = 9, .generation = t.gen, .alive = false, .pending = true, .fit_scale = 1 });
    try testing.expectEqualStrings("waiting_renderer", t.stateName());
    t.onState(.{ .browser = 9, .generation = t.gen, .fit_scale = 1, .active_mask = 0b1001 });
    try testing.expectEqualStrings("active", t.stateName());
}

test "W9e①: 알림은 에이전트 탭·세대마다 한 번, 사용자 탭은 알리지 않는다(모달이 이미 말했다)" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"UTC\"}", &w);
    _ = try t.apply(testCall(&p, 5, 0), &why);
    try testing.expect(t.wantsNotice());
    try testing.expect(!t.wantsNotice());
    const q = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"Asia/Seoul\"}", &w);
    _ = try t.apply(testCall(&q, 5, 100), &why);
    try testing.expect(t.wantsNotice());
    var u: Tab = .{};
    _ = try u.apply(.{ .pane = 5, .params = &p, .any_host = false, .grant_host = "a.test" }, &why);
    try testing.expect(!u.wantsNotice());
}

test "W9e①: op.arg 는 같은 parseParams 로 다시 풀린다 — 정규형 왕복(빈 칸 지움·null 지움·client hints 객체)" {
    var w: ?Why = null;
    const p = try parse("{\"id\":1,\"action\":\"set\",\"reload\":true,\"viewport\":{\"width\":390,\"height\":844,\"device_scale_factor\":2.5,\"landscape\":true},\"user_agent\":{\"ua\":\"UA\",\"platform\":\"P\",\"client_hints\":{\"brands\":[{\"brand\":\"B\",\"version\":\"1\"}],\"platform\":\"Android\",\"model\":\"Pixel\",\"mobile\":true}},\"locale\":null,\"geolocation\":{\"latitude\":-33.5,\"longitude\":151,\"accuracy\":0},\"media\":{\"type\":\"print\",\"contrast\":\"no-preference\"},\"vision\":\"protanopia\"}", &w);
    const arg = try serializeArg(testing.allocator, &p);
    defer testing.allocator.free(arg);
    const q = try parse(arg, &w);
    try testing.expect(std.meta.eql(p, q));
}

// ── W9e① 변이 시험(변이 캠페인이 찾은 빈틈) ──
// 시험이 증명하는 것: 인자 표의 남은 까닭(첫 조각 한 글자 언어·배율 아래 경계·브랜드 다섯·브랜드의 모르는 키·빈 브랜드·clear 의 viewport),
// forced_colors "none" 은 「흉내 없음」 이 아니라 끔(.off), 바꾸기 상한은 1 초 창, 데스크톱 UA 도 viewport.mobile 이면 hints 가 모바일,
// 이 세대의 화면 흉내가 실패하면 입력 줄임 1·테두리 없음, 옛 세대의 죽은 렌더러는 waiting_renderer, 화면이 pane 보다 작으면 exact,
// 화면이 아직 걸리지 않았으면 결과의 줄임은 maru 가 셈한 것, 언어만이면 process_shared 에 locale, 터치 경고는 새로 켤 때·새로고침하지 않을 때만.
test "W9e① 변이: 인자 까닭의 남은 칸·forced none·1 초 창·데스크톱 UA 의 모바일 hints·화면 실패·옛 세대·exact·결과 줄임·locale 공유·터치 경고" {
    try expectWhy("{\"id\":1,\"action\":\"set\",\"locale\":\"f-FR\"}", .locale_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":800,\"device_scale_factor\":0.25}}", .dsf_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":{\"brands\":[{\"brand\":\"A\",\"version\":\"1\"},{\"brand\":\"B\",\"version\":\"1\"},{\"brand\":\"C\",\"version\":\"1\"},{\"brand\":\"D\",\"version\":\"1\"},{\"brand\":\"E\",\"version\":\"1\"}],\"platform\":\"Android\"}}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":{\"brands\":[{\"brand\":\"A\",\"version\":\"1\",\"x\":1}],\"platform\":\"Android\"}}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"set\",\"user_agent\":{\"ua\":\"x\",\"client_hints\":{\"brands\":[{\"brand\":\"\",\"version\":\"1\"}],\"platform\":\"Android\"}}}", .client_hints_invalid);
    try expectWhy("{\"id\":1,\"action\":\"clear\",\"viewport\":null}", .action_invalid);
    var w: ?Why = null;
    const fc = try parse("{\"id\":1,\"action\":\"set\",\"media\":{\"forced_colors\":\"none\"}}", &w);
    try testing.expectEqual(msg.EmuForcedColors.off, fc.media.set.forced_colors);

    // 바꾸기 상한은 1 초 창(500 ms 뒤 열한째는 거절, 1 초 뒤는 된다).
    var r: Tab = .{};
    var why: Failure = undefined;
    const tz = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"UTC\"}", &w);
    for (0..10) |i| _ = try r.apply(testCall(&tz, 5, @intCast(i)), &why);
    try testing.expectError(error.Rejected, r.apply(testCall(&tz, 5, 500), &why));
    _ = try r.apply(testCall(&tz, 5, 1000), &why);

    // 데스크톱 UA 라도 viewport.mobile 이면 추정 hints 가 모바일이다.
    var d: Tab = .{};
    const dp = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844,\"mobile\":true},\"user_agent\":{\"ua\":\"Mozilla/5.0 (Windows NT 10.0) Chrome/120.0.0.0 Safari/537.36\"}}", &w);
    _ = try d.apply(testCall(&dp, 5, 0), &why);
    try testing.expect(d.toWire(1).hints.mobile);

    // 화면 흉내가 이 세대에 실패했다 — 입력 줄임 1, 테두리 없음. 걸리기 전(pending)의 결과 줄임은 maru 가 셈한 것.
    var f: Tab = .{};
    const vp = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844}}", &w);
    const out_vp = try f.apply(testCall(&vp, 5, 0), &why);
    _ = out_vp;
    f.onState(.{ .browser = 1, .generation = f.gen, .pending = true, .fit_scale = 1 });
    const j0 = try f.resultJson(testing.allocator, 640, 400, false, false);
    defer testing.allocator.free(j0);
    try testing.expect(std.mem.indexOf(u8, j0, "\"fit_scale\":0.4739") != null);
    f.onState(.{ .browser = 1, .generation = f.gen, .fit_scale = 0.4739, .failed_mask = 1, .reason = .cdp_error });
    try testing.expectEqual(@as(f32, 1), f.inputScale(640, 400));
    try testing.expect(f.shownSize(640, 400) == null);
    // 옛 세대의 답인데 렌더러가 죽었다 — waiting_renderer.
    f.onState(.{ .browser = 1, .generation = f.gen -% 1, .alive = false, .fit_scale = 1 });
    try testing.expectEqualStrings("waiting_renderer", f.stateName());
    // pane 보다 작은 흉내 화면 — exact.
    const j1 = try f.resultJson(testing.allocator, 1280, 900, false, false);
    defer testing.allocator.free(j1);
    try testing.expect(std.mem.indexOf(u8, j1, "\"shown\":\"exact\"") != null);

    // 언어만 — process_shared 는 locale.
    var l: Tab = .{};
    const lp = try parse("{\"id\":1,\"action\":\"set\",\"locale\":\"fr-FR\"}", &w);
    _ = try l.apply(testCall(&lp, 5, 0), &why);
    const j2 = try l.resultJson(testing.allocator, 640, 400, false, false);
    defer testing.allocator.free(j2);
    try testing.expect(std.mem.indexOf(u8, j2, "\"process_shared\":[\"locale\"]") != null);

    // 터치 경고 — 새로 켤 때만, 새로고침했으면 없음.
    var t: Tab = .{};
    const tp = try parse("{\"id\":1,\"action\":\"set\",\"viewport\":{\"width\":390,\"height\":844,\"touch\":true},\"reload\":true}", &w);
    const o1 = try t.apply(testCall(&tp, 5, 0), &why);
    try testing.expect(o1.touch_added);
    const j3 = try t.resultJson(testing.allocator, 640, 400, true, o1.touch_added);
    defer testing.allocator.free(j3);
    try testing.expect(std.mem.indexOf(u8, j3, "touch_events_after_reload") == null);
    const o2 = try t.apply(testCall(&tz, 5, 100), &why);
    try testing.expect(!o2.touch_added); // 이미 켜져 있었다
}

// 변이 캠페인 WE53: 지운 흉내의 결과 `state` 는 렌더러가 죽어 지움이 쌓여 있으면 `waiting_renderer`(전에는 늘 `active` — 옛 흉내가 새 렌더러에
// 다시 걸리는데 다 지운 것처럼 답했다), 지움을 보내지 못했으면 `failed`, 답이 오기 전이면 `sent`, 지움이 걸렸으면 `active`.
test "W9e①: 지운 흉내의 결과 state — 죽은 렌더러에 쌓인 지움은 waiting_renderer, 보내지 못한 지움은 failed, 걸린 지움은 active" {
    var t: Tab = .{};
    var why: Failure = undefined;
    var w: ?Why = null;
    const set = try parse("{\"id\":1,\"action\":\"set\",\"timezone\":\"UTC\"}", &w);
    _ = try t.apply(testCall(&set, 5, 0), &why);
    t.onState(.{ .browser = 1, .generation = t.gen, .fit_scale = 1, .active_mask = 1 << @backingInt(msg.EmuGroup.timezone) });
    const clear = try parse("{\"id\":1,\"action\":\"clear\"}", &w);
    _ = try t.apply(testCall(&clear, 5, 10), &why);
    try testing.expect(!t.active());
    const expectState = struct {
        fn f(tab: *const Tab, want: []const u8) !void {
            const j = try tab.resultJson(testing.allocator, 640, 400, false, false);
            defer testing.allocator.free(j);
            const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, j, .{});
            defer v.deinit();
            try testing.expectEqual(@as(usize, 0), v.value.object.get("emulation").?.object.count());
            try testing.expectEqualStrings(want, v.value.object.get("state").?.string);
        }
    }.f;
    try expectState(&t, "sent"); // 이 세대의 답 전
    t.onState(.{ .browser = 1, .generation = t.gen, .alive = false, .pending = true, .fit_scale = 1 });
    try expectState(&t, "waiting_renderer");
    t.onState(.{ .browser = 1, .generation = t.gen, .fit_scale = 1, .failed_mask = 1 << @backingInt(msg.EmuGroup.timezone), .reason = .cdp_error });
    try expectState(&t, "failed");
    t.onState(.{ .browser = 1, .generation = t.gen, .fit_scale = 1 });
    try expectState(&t, "active");
}
