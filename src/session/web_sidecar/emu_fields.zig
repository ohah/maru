//! 기기 흉내 메시지(W9e① — wire 25: `emulation` 140·`emulation_state` 82)의 닫힌 필드 규칙과 몸통 쓰기·읽기. encode 와 decode 가 **같은 검사
//! 함수**(`checkEmulation`·`checkState`)를 지나야 한쪽만 느슨해지지 않는다(`net_fields.zig` 와 같은 규율). maru 와 sidecar 가 같은 파일을 쓴다.
//!
//! 시험이 증명하는 것(시험은 `codec.zig` 에): 표시와 값의 짝(표시 없는 무리에 값이 있으면·표시만 있고 값이 없으면 거절), 범위(가로·세로
//! 1..4096·배율 0.5..4·width×height×dsf² ≤ 64 Mpx·위도 ±90·경도 ±180·정확도 0..100 000·NaN·무한), 글 모양(UA·플랫폼·client hints 는 인쇄 가능한
//! ASCII, 언어·ICU·시간대는 그 글자만), 모르는 enum, 쓰지 않는 비트, 위치 출처 목록(http(s) 출처·8 개)이 양쪽에서 거절된다는 것. 브라우저
//! 탭에서 중요한 이유 — 이 값은 CDP JSON 에 들어가고(sidecar 가 글로 이어 붙인다) 서버에 머리로 나간다. 받는 쪽이 모양을 믿으면 머리 끼워 넣기·
//! JSON 깨기가 된다.

const std = @import("std");
const wire = @import("wire.zig");
const message = @import("message.zig");
const fields = @import("fields.zig");
const net_fields = @import("net_fields.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;

// ── 글 규칙 ─────────────────────────────────────────────────────────────────────────────────────────────────

/// 인쇄 가능한 ASCII(0x20..0x7e)이고 `max` 안. UA·플랫폼·client hints — 머리 값으로 나가므로 제어 문자·비 ASCII 를 받지 않는다.
pub fn printable(text: []const u8, max: usize) bool {
    if (text.len > max) return false;
    for (text) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

/// `Accept-Language` 목록(`fr-FR,fr`) — 글자·숫자·`-`·`,` 만(q 값은 Chromium 이 붙인다 — 실측 E7).
pub fn acceptLanguageOk(text: []const u8) bool {
    if (text.len == 0 or text.len > message.max_emu_accept_language_bytes) return false;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == ',')) return false;
    return text[0] != ',' and text[text.len - 1] != ',';
}

/// ICU 이름(`fr_FR`·`zh_Hant_TW`) — 글자·숫자·`_` 만.
pub fn icuLocaleOk(text: []const u8) bool {
    if (text.len == 0 or text.len > message.max_emu_icu_locale_bytes) return false;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return std.ascii.isAlphabetic(text[0]);
}

/// IANA 시간대 이름의 모양(`Asia/Kolkata`·`Etc/GMT+5`·`UTC`) — 글자·숫자·`_`·`/`·`+`·`-` 만. 진짜 이름인지는 Chromium 이 본다
/// (모르면 그 무리만 `timezone_unknown`).
pub fn timezoneOk(text: []const u8) bool {
    if (text.len == 0 or text.len > message.max_emu_timezone_bytes) return false;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '/' or c == '+' or c == '-')) return false;
    return std.ascii.isAlphabetic(text[0]) and text[text.len - 1] != '/';
}

fn finite(v: anytype) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

/// 흉내 화면의 모양 — 1..4096 CSS px, 배율 0.5..4(유한), width × height × dsf² ≤ 64 Mpx.
pub fn viewportOk(width: u16, height: u16, dsf: f32) bool {
    if (width == 0 or height == 0 or width > message.max_emu_dimension or height > message.max_emu_dimension) return false;
    if (!finite(dsf) or dsf < message.min_emu_dsf or dsf > message.max_emu_dsf) return false;
    const d: f64 = dsf;
    return @as(f64, @floatFromInt(width)) * @as(f64, @floatFromInt(height)) * d * d <= message.max_emu_pixels;
}

pub fn geoOk(latitude: f64, longitude: f64, accuracy: f64) bool {
    if (!finite(latitude) or !finite(longitude) or !finite(accuracy)) return false;
    return latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180 and accuracy >= 0 and accuracy <= message.max_emu_accuracy;
}

/// 위치를 대신 허용한 출처 — `http(s)://host[:port]`(`fields.checkOrigin` 의 모양, 빈 글 거절).
pub fn geoOriginOk(origin: []const u8) bool {
    if (origin.len == 0) return false;
    if (!(std.mem.startsWith(u8, origin, "https://") or std.mem.startsWith(u8, origin, "http://"))) return false;
    fields.checkOrigin(origin) catch return false;
    return true;
}

fn hintTextOk(text: []const u8) bool {
    return printable(text, message.max_emu_hint_bytes);
}

/// client hints — 브랜드 1..4(브랜드·버전 모두 비지 않음), 전체 목록 0..4, 나머지 글은 64 B 인쇄 가능.
pub fn checkHints(h: message.EmuHints) Error!void {
    if (h.brand_count == 0 or h.brand_count > message.max_emu_brands or h.full_count > message.max_emu_brands) return error.InvalidEmulation;
    for (h.brands[0..h.brand_count]) |b| if (b.brand.len == 0 or b.version.len == 0 or !hintTextOk(b.brand) or !hintTextOk(b.version)) return error.InvalidEmulation;
    for (h.brands[h.brand_count..]) |b| if (b.brand.len != 0 or b.version.len != 0) return error.InvalidEmulation;
    for (h.full_list[0..h.full_count]) |b| if (b.brand.len == 0 or b.version.len == 0 or !hintTextOk(b.brand) or !hintTextOk(b.version)) return error.InvalidEmulation;
    for (h.full_list[h.full_count..]) |b| if (b.brand.len != 0 or b.version.len != 0) return error.InvalidEmulation;
    for ([_][]const u8{ h.platform, h.platform_version, h.architecture, h.model, h.bitness }) |t| if (!hintTextOk(t)) return error.InvalidEmulation;
}

fn hintsEmpty(h: message.EmuHints) bool {
    if (h.brand_count != 0 or h.full_count != 0 or h.mobile) return false;
    for (h.brands) |b| if (b.brand.len != 0 or b.version.len != 0) return false;
    for (h.full_list) |b| if (b.brand.len != 0 or b.version.len != 0) return false;
    return h.platform.len == 0 and h.platform_version.len == 0 and h.architecture.len == 0 and h.model.len == 0 and h.bitness.len == 0;
}

/// 사용자가 보는 줄임(사용자 결정 Q3 — Chromium 의 `scale`): min(1, pane 폭 / 흉내 폭, pane 높이 / 흉내 높이)를 만분의 일로 내린다(작은
/// 흔들림에 다시 보내지 않게, 줄인 화면이 pane 을 넘지 않게). pane 크기를 모르면(0) 1. sidecar 가 `scale` 로 보내고 maru 가 같은 셈으로 미리
/// 보인다(결과의 `fit_scale` — 단일 출처).
pub fn fitScale(pane_w: u32, pane_h: u32, emu_w: u16, emu_h: u16) f32 {
    if (pane_w == 0 or pane_h == 0 or emu_w == 0 or emu_h == 0) return 1;
    const fw = @as(f64, @floatFromInt(pane_w)) / @as(f64, @floatFromInt(emu_w));
    const fh = @as(f64, @floatFromInt(pane_h)) / @as(f64, @floatFromInt(emu_h));
    const f = @min(1.0, @min(fw, fh));
    const q = @floor(f * 10_000) / 10_000;
    return @floatCast(@max(q, 0.0001));
}

// ── emulation ────────────────────────────────────────────────────────────────────────────────────────────────

/// `emulation` — 표시와 값의 짝·범위·글 모양. 표시가 없는 무리의 칸은 기본값이어야 한다(닫힌 칸 — 받는 쪽이 「표시는 없는데 값이
/// 있다」 를 어떻게 읽을지 고르지 않게).
pub fn checkEmulation(v: message.Emulation) Error!void {
    const f = v.flags;
    if (f._reserved != 0) return error.InvalidEmulation;
    if (f.site_bound) try net_fields.checkHost(v.site) else if (v.site.len != 0) return error.InvalidEmulation;
    if (f.viewport) {
        if (!viewportOk(v.width, v.height, v.dsf)) return error.InvalidEmulation;
    } else if (v.width != 0 or v.height != 0 or v.dsf != 0 or f.touch or f.mobile or f.landscape) return error.InvalidEmulation;
    if (f.ua) {
        if (v.ua.len == 0 or !printable(v.ua, message.max_emu_ua_bytes) or !printable(v.platform, message.max_emu_platform_bytes)) return error.InvalidEmulation;
        if (f.hints) try checkHints(v.hints) else if (!hintsEmpty(v.hints)) return error.InvalidEmulation;
    } else if (v.ua.len != 0 or v.platform.len != 0 or f.hints or !hintsEmpty(v.hints)) return error.InvalidEmulation;
    if (f.locale) {
        if (!acceptLanguageOk(v.accept_language) or !icuLocaleOk(v.icu_locale)) return error.InvalidEmulation;
    } else if (v.accept_language.len != 0 or v.icu_locale.len != 0) return error.InvalidEmulation;
    if (f.timezone) {
        if (!timezoneOk(v.timezone)) return error.InvalidEmulation;
    } else if (v.timezone.len != 0) return error.InvalidEmulation;
    if (f.geo and !f.geo_unavailable) {
        if (!geoOk(v.latitude, v.longitude, v.accuracy)) return error.InvalidEmulation;
    } else {
        if (f.geo_unavailable and !f.geo) return error.InvalidEmulation;
        if (v.latitude != 0 or v.longitude != 0 or v.accuracy != 0) return error.InvalidEmulation;
        if (std.math.signbit(v.latitude) or std.math.signbit(v.longitude) or std.math.signbit(v.accuracy)) return error.InvalidEmulation; // -0 도 거절(바이트 하나)
    }
    if (f.media != v.media.any()) return error.InvalidEmulation;
    if (f.vision != (v.vision != .none)) return error.InvalidEmulation;
    if (v.restore_count > message.max_emu_geo_origins) return error.InvalidEmulation;
    for (v.restore[0..v.restore_count]) |o| if (!geoOriginOk(o)) return error.InvalidEmulation;
    for (v.restore[v.restore_count..]) |o| if (o.len != 0) return error.InvalidEmulation;
}

fn writeShort(cursor: *Cursor, text: []const u8) Error!void {
    try cursor.writeByte(@intCast(text.len));
    try cursor.writeBytes(text);
}

fn readShort(cursor: *ReadCursor) Error![]const u8 {
    return cursor.readBytes(try cursor.readByte());
}

fn writeBrands(cursor: *Cursor, count: u8, list: []const message.EmuBrand) Error!void {
    try cursor.writeByte(count);
    for (list[0..count]) |b| {
        try writeShort(cursor, b.brand);
        try writeShort(cursor, b.version);
    }
}

fn readBrands(cursor: *ReadCursor, list: *[message.max_emu_brands]message.EmuBrand) Error!u8 {
    const count = try cursor.readByte();
    if (count > message.max_emu_brands) return error.InvalidEmulation;
    for (list[0..count]) |*b| b.* = .{ .brand = try readShort(cursor), .version = try readShort(cursor) };
    return count;
}

pub fn writeEmulation(cursor: *Cursor, v: message.Emulation) Error!void {
    try checkEmulation(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeU16(@bitCast(v.flags));
    try writeShort(cursor, v.site);
    try cursor.writeU16(v.width);
    try cursor.writeU16(v.height);
    try cursor.writeU32(@bitCast(v.dsf));
    try cursor.writeU16(@intCast(v.ua.len));
    try cursor.writeBytes(v.ua);
    try writeShort(cursor, v.platform);
    try writeBrands(cursor, v.hints.brand_count, &v.hints.brands);
    try writeBrands(cursor, v.hints.full_count, &v.hints.full_list);
    for ([_][]const u8{ v.hints.platform, v.hints.platform_version, v.hints.architecture, v.hints.model, v.hints.bitness }) |t| try writeShort(cursor, t);
    try cursor.writeByte(@intFromBool(v.hints.mobile));
    try writeShort(cursor, v.accept_language);
    try writeShort(cursor, v.icu_locale);
    try writeShort(cursor, v.timezone);
    try fields.writeF64(cursor, v.latitude);
    try fields.writeF64(cursor, v.longitude);
    try fields.writeF64(cursor, v.accuracy);
    try cursor.writeByte(@backingInt(v.media.type));
    try cursor.writeByte(@backingInt(v.media.color_scheme));
    try cursor.writeByte(@backingInt(v.media.reduced_motion));
    try cursor.writeByte(@backingInt(v.media.forced_colors));
    try cursor.writeByte(@backingInt(v.media.contrast));
    try cursor.writeByte(@backingInt(v.vision));
    try cursor.writeByte(v.restore_count);
    for (v.restore[0..v.restore_count]) |o| try writeShort(cursor, o);
}

fn readEnum(comptime E: type, cursor: *ReadCursor) Error!E {
    return std.enums.fromInt(E, try cursor.readByte()) orelse error.InvalidEmulation;
}

pub fn readEmulation(cursor: *ReadCursor) Error!message.Emulation {
    var v: message.Emulation = .{ .browser = try fields.readBrowser(cursor) };
    v.generation = try cursor.readU32();
    v.flags = @bitCast(try cursor.readU16());
    v.site = try readShort(cursor);
    v.width = try cursor.readU16();
    v.height = try cursor.readU16();
    v.dsf = @bitCast(try cursor.readU32());
    const ua_len = try cursor.readU16();
    if (ua_len > message.max_emu_ua_bytes) return error.InvalidEmulation;
    v.ua = try cursor.readBytes(ua_len);
    v.platform = try readShort(cursor);
    v.hints.brand_count = try readBrands(cursor, &v.hints.brands);
    v.hints.full_count = try readBrands(cursor, &v.hints.full_list);
    v.hints.platform = try readShort(cursor);
    v.hints.platform_version = try readShort(cursor);
    v.hints.architecture = try readShort(cursor);
    v.hints.model = try readShort(cursor);
    v.hints.bitness = try readShort(cursor);
    v.hints.mobile = try fields.readBool(cursor);
    v.accept_language = try readShort(cursor);
    v.icu_locale = try readShort(cursor);
    v.timezone = try readShort(cursor);
    v.latitude = try fields.readF64(cursor);
    v.longitude = try fields.readF64(cursor);
    v.accuracy = try fields.readF64(cursor);
    v.media = .{
        .type = try readEnum(message.EmuMediaType, cursor),
        .color_scheme = try readEnum(message.EmuColorScheme, cursor),
        .reduced_motion = try readEnum(message.EmuReducedMotion, cursor),
        .forced_colors = try readEnum(message.EmuForcedColors, cursor),
        .contrast = try readEnum(message.EmuContrast, cursor),
    };
    v.vision = try readEnum(message.EmuVision, cursor);
    v.restore_count = try cursor.readByte();
    if (v.restore_count > message.max_emu_geo_origins) return error.InvalidEmulation;
    for (v.restore[0..v.restore_count]) |*o| o.* = try readShort(cursor);
    try checkEmulation(v);
    return v;
}

// ── emulation_state ──────────────────────────────────────────────────────────────────────────────────────────

/// `emulation_state` — 마스크는 아는 무리만, 실패 무리가 있으면 까닭이 있고 없으면 없다, 걸림과 실패는 겹치지 않는다, 줄임은 (0, 1],
/// 출처 목록은 http(s) 출처 8 개까지.
pub fn checkState(v: message.EmulationState) Error!void {
    if (v.active_mask & ~message.emu_group_mask_valid != 0 or v.failed_mask & ~message.emu_group_mask_valid != 0) return error.InvalidEmulation;
    if (v.active_mask & v.failed_mask != 0) return error.InvalidEmulation;
    if ((v.failed_mask != 0) != (v.reason != .none)) return error.InvalidEmulation;
    if (!finite(v.fit_scale) or !(v.fit_scale > 0) or v.fit_scale > 1) return error.InvalidEmulation;
    if (v.auto_count > message.max_emu_geo_origins) return error.InvalidEmulation;
    for (v.auto_allowed[0..v.auto_count]) |o| if (!geoOriginOk(o)) return error.InvalidEmulation;
    for (v.auto_allowed[v.auto_count..]) |o| if (o.len != 0) return error.InvalidEmulation;
}

pub fn writeState(cursor: *Cursor, v: message.EmulationState) Error!void {
    try checkState(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@intFromBool(v.on_site));
    try cursor.writeByte(@intFromBool(v.alive));
    try cursor.writeByte(@intFromBool(v.pending));
    try cursor.writeU32(@bitCast(v.fit_scale));
    try cursor.writeU16(v.active_mask);
    try cursor.writeU16(v.failed_mask);
    try cursor.writeByte(@backingInt(v.reason));
    try cursor.writeByte(v.auto_count);
    for (v.auto_allowed[0..v.auto_count]) |o| try writeShort(cursor, o);
}

pub fn readState(cursor: *ReadCursor) Error!message.EmulationState {
    var v: message.EmulationState = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .on_site = try fields.readBool(cursor),
        .alive = try fields.readBool(cursor),
        .pending = try fields.readBool(cursor),
        .fit_scale = @bitCast(try cursor.readU32()),
        .active_mask = try cursor.readU16(),
        .failed_mask = try cursor.readU16(),
        .reason = try readEnum(message.EmuFailReason, cursor),
        .auto_count = try cursor.readByte(),
    };
    if (v.auto_count > message.max_emu_geo_origins) return error.InvalidEmulation;
    for (v.auto_allowed[0..v.auto_count]) |*o| o.* = try readShort(cursor);
    try checkState(v);
    return v;
}

/// 가장 큰 `emulation` 몸통의 바이트 수(머리 빼고) — codec 의 comptime 이 frame 상한 안인지 본다.
pub const max_emulation_body_bytes: usize = 8 + 4 + 2 + (1 + message.max_net_host_bytes) + 2 + 2 + 4 + (2 + message.max_emu_ua_bytes) + (1 + message.max_emu_platform_bytes) +
    2 * (1 + message.max_emu_brands * 2 * (1 + message.max_emu_hint_bytes)) + 5 * (1 + message.max_emu_hint_bytes) + 1 +
    (1 + message.max_emu_accept_language_bytes) + (1 + message.max_emu_icu_locale_bytes) + (1 + message.max_emu_timezone_bytes) + 3 * 8 + 6 +
    1 + message.max_emu_geo_origins * (1 + fields.max_origin_bytes);
