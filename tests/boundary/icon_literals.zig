const std = @import("std");

// 이 테스트는 **아이콘을 codepoint 리터럴로 부르지 않는다**는 디자인 시스템 규율을 강제한다
// (docs/chrome-strategy.md §9.7).
//
// 왜 필요한가: 등록 아이콘의 Plane-15 PUA codepoint를 소비처가 `0xF0023`·`"\u{F0023}"`로 직접 적으면
//   (a) 어느 그림인지 코드에서 안 읽히고,
//   (b) 자산이 재배치되면(변형 흡수·이름 정리) **조용히 다른 아이콘이 되거나 미등록 cp가 돼**
//       폰트 폴백(빈 칸 또는 엉뚱한 Nerd Fonts MDI 글리프)으로 빠진다. 컴파일러는 못 잡는다.
// 그래서 이름 registry(`src/icons.zig` — 생성물)의 `icons.codepoint(.x)`/`icons.utf8(.x)`만 쓴다.
//
// **판정 기준은 "등록된 아이콘 cp인가"다.** 첫 판은 `0xF0000~0xFFFFF` 전 범위를 잡아, 20비트 마스크
// (`0xFFFFF`)나 상위-바이트 태그 상수 같은 무관한 값까지 위반으로 신고했다(적대적 검증 실측). 이제
// 생성물에서 **실제 등록 cp 집합**을 읽어 그 값만 잡는다 — 미등록 sentinel 예외 목록도 자연히 필요 없다.
//
// **스캔은 `std.zig.Tokenizer`로 한다.** 첫 판은 줄에서 `//` 뒤를 잘라내는 근사였는데,
//   - `src/**/*.zig`에는 문자열 안에 `//`가 든 줄이 실재한다(`"rgb://"`, `"https://a/"`, `"]7;file://"` …)
//     → 그 줄 전체가 스캔 사각지대였고,
//   - `0x0F0023`(선행 0)·`0xF_0023`(숫자 구분자)·`983075`(10진)·문자열 안 **원시 UTF-8 PUA 문자**가 전부
//     빠져나갔다(적대적 검증에서 실행 확인).
// 형제 가드 `tests/boundary/imports.zig`가 이미 쓰는 토크나이저 규율로 되돌리고, 정수 리터럴은 **값으로**
// 파싱하며 문자열 리터럴은 escape·원시 바이트 양쪽을 디코드한다.

/// 리터럴을 그대로 둬야 하는 파일. 생성물 자신뿐이다.
const exempt_files = [_][]const u8{
    "icons.zig", // 생성물 — 이름↔codepoint 대응 그 자체다.
    "renderer/icon_coverage_data.zig", // 생성물 — coverage 데이터 + 매니페스트.
};

const registry_path = "src/icons.zig";
const max_registered = 256;

const Violation = struct { text: []u8 };

fn isExempt(rel: []const u8) bool {
    for (exempt_files) |e| if (std.mem.eql(u8, rel, e)) return true;
    return false;
}

/// 생성물에서 등록 codepoint 집합을 읽는다. 이 테스트는 `maru` 모듈을 import하지 않는 순수 소스 스캐너라
/// (형제 boundary 테스트와 같은 형태) `icons.zig`를 텍스트로 파싱한다 — `Icon` 태그 값과 `fromCodepoint`
/// 갈래가 모두 `0x…` 리터럴이므로 **파일 전체의 5자리 PUA hex**를 모으면 그 집합이 곧 등록 집합이다.
fn loadRegistered(allocator: std.mem.Allocator, out: []u32) !usize {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, registry_path, allocator, .limited(512 * 1024));
    defer allocator.free(source);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "0x")) |pos| {
        var end = pos + 2;
        while (end < source.len and std.ascii.isHex(source[end])) : (end += 1) {}
        i = end;
        const digits = source[pos + 2 .. end];
        if (digits.len != 5) continue;
        const value = std.fmt.parseInt(u32, digits, 16) catch continue;
        if (value < 0xF0000 or value > 0xFFFFF) continue;
        var seen = false;
        for (out[0..count]) |v| {
            if (v == value) seen = true;
        }
        if (seen) continue;
        if (count == out.len) return error.TooManyRegisteredIcons;
        out[count] = value;
        count += 1;
    }
    return count;
}

fn isRegistered(registered: []const u32, cp: u32) bool {
    for (registered) |v| {
        if (v == cp) return true;
    }
    return false;
}

/// 정수 리터럴 텍스트를 **값으로** 판독한다. Zig 숫자 구분자(`_`)를 흡수하고 진법을 그대로 따르므로
/// `0x0F0023`·`0xF_0023`·`983075`가 모두 같은 값으로 잡힌다(첫 판이 전부 놓쳤다).
fn integerLiteralValue(text: []const u8) ?u32 {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        if (len == buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    const cleaned = buf[0..len];
    if (cleaned.len == 0) return null;
    return std.fmt.parseInt(u32, cleaned, 0) catch null;
}

/// 문자열/문자 리터럴 안에서 등록 아이콘 codepoint를 찾는다. `\u{F0023}` escape뿐 아니라 **원시 UTF-8**
/// PUA 문자도 디코드한다 — `icons.utf8()`이 만드는 바이트열이 정확히 그것이라, 앱에서 복사해 붙인 글자가
/// 가드를 통과하면 규율이 무의미해진다.
fn scanQuoted(text: []const u8, registered: []const u32) ?u32 {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 2 < text.len and text[i + 1] == 'u' and text[i + 2] == '{') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 3, '}') orelse return null;
            if (std.fmt.parseInt(u32, text[i + 3 .. close], 16)) |cp| {
                if (isRegistered(registered, cp)) return cp;
            } else |_| {}
            i = close + 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) return null;
        if (std.unicode.utf8Decode(text[i .. i + seq_len])) |cp| {
            if (isRegistered(registered, cp)) return cp;
        } else |_| {}
        i += seq_len;
    }
    return null;
}

/// 한 파일에서 첫 위반의 (줄 번호, cp)를 찾는다. 토크나이저가 주석을 아예 토큰으로 내지 않으므로 주석
/// 안의 cp 표기(문서)는 자연히 제외되고, 문자열 안의 `//`도 더 이상 스캔을 끊지 않는다.
fn scanSource(allocator: std.mem.Allocator, source: []const u8, registered: []const u32) !?struct { line: usize, cp: u32 } {
    const sentinel = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel);
    var tokenizer = std.zig.Tokenizer.init(sentinel);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const text = sentinel[token.loc.start..token.loc.end];
        const found: ?u32 = switch (token.tag) {
            .number_literal => blk: {
                const value = integerLiteralValue(text) orelse break :blk null;
                break :blk if (isRegistered(registered, value)) value else null;
            },
            .string_literal, .multiline_string_literal_line, .char_literal => scanQuoted(text, registered),
            else => null,
        };
        if (found) |cp| {
            var line: usize = 1;
            for (sentinel[0..token.loc.start]) |c| {
                if (c == '\n') line += 1;
            }
            return .{ .line = line, .cp = cp };
        }
    }
    return null;
}

test "아이콘은 이름 registry로만 부른다 — codepoint 리터럴 금지 (docs/chrome-strategy.md §9.7)" {
    const allocator = std.testing.allocator;
    var registered_buf: [max_registered]u32 = undefined;
    const registered_len = try loadRegistered(allocator, &registered_buf);
    const registered = registered_buf[0..registered_len];
    try std.testing.expect(registered.len > 0); // 파싱이 실제로 됐다

    var violations: std.ArrayList(Violation) = .empty;
    defer {
        for (violations.items) |v| allocator.free(v.text);
        violations.deinit(allocator);
    }

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (isExempt(entry.path)) continue;
        const full = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(full);
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);

        if (try scanSource(allocator, source, registered)) |hit| {
            try violations.append(allocator, .{ .text = try std.fmt.allocPrint(
                allocator,
                "src/{s}:{d}: 등록 아이콘 codepoint(0x{X}) 리터럴 — `icons.codepoint(.name)`/`icons.utf8(.name)`을 쓰세요",
                .{ entry.path, hit.line, hit.cp },
            ) });
        }
    }

    if (violations.items.len > 0) {
        std.debug.print("\n아이콘 이름 규율 위반 {d}건:\n", .{violations.items.len});
        for (violations.items) |v| std.debug.print("  - {s}\n", .{v.text});
        return error.IconLiteralBoundaryViolation;
    }
}

// 셀 그리드 chrome의 아이콘 배율은 **두 언어에 걸쳐 있다**: Zig가 그 배율로 텍스처를 굽고(`collectShaped`가
// `raster_*_px`를 주입), Objective-C 렌더러가 같은 배율로 quad를 키운다. 둘이 어긋나면 1.7× 텍스처가 1.0× quad에
// 들어가(또는 그 반대) 아이콘이 잘리거나 흐려진다 — 컴파일러도 타입도 못 잡고, 헤드리스 테스트는 quad 크기만
// 보므로 조용히 지나간다.
//
// **"어딘가에 그 숫자가 있는가"로는 부족하다.** 첫 판은 `.m` 전체에서 `1.7f` 부분문자열을 찾았는데,
// 토큰을 흔한 값(1.0/2.0)으로 바꾸면 항상 통과하고, x/y 두 배율 중 **한쪽만** 드리프트해도 통과했으며,
// 코드를 바꾸고 주석에만 옛 값을 남겨도 통과했다(적대적 검증에서 전부 실행 확인). 이제 아이콘 배율을 쓰는
// **그 두 표현식을 직접 짚어** 개수와 값을 함께 단언한다.
const scale_token_file = "src/chrome/ui/icon.zig";
const scale_mirror_file = "src/platform/macos/maru_metal_renderer.m";
/// `.m`에서 아이콘 배율이 실리는 자리. x/y 두 축이 같은 값을 써야 아이콘이 종횡비를 지킨다.
const mirror_prefixes = [_][]const u8{
    "const float glyph_scale_x = is_dock_toggle ? glyph_policy.scale_x : ((is_corner_icon || is_bell_icon) ? ",
    "const float glyph_scale_y = is_dock_toggle ? glyph_policy.scale_y : ((is_corner_icon || is_bell_icon) ? ",
};

test "아이콘 셀 래스터 배율은 Zig 토큰과 Objective-C 미러가 같다" {
    const allocator = std.testing.allocator;
    const token_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, scale_token_file, allocator, .limited(64 * 1024));
    defer allocator.free(token_source);

    // `pub const cell_raster_scale_milli: u32 = 1700;` → 1700 → "1.7f"
    const needle = "cell_raster_scale_milli: u32 = ";
    const start = (std.mem.indexOf(u8, token_source, needle) orelse return error.TestUnexpectedResult) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, token_source, start, ';') orelse return error.TestUnexpectedResult;
    const milli = try std.fmt.parseInt(u32, token_source[start..end], 10);
    var expected_buf: [24]u8 = undefined;
    // 소수 자리는 필요한 만큼만 쓴다(1700 → "1.7f", 1750 → "1.75f", 2000 → "2f"가 아니라 "2.0f").
    const whole = milli / 1000;
    const frac = milli % 1000;
    const expected = if (frac % 100 == 0)
        try std.fmt.bufPrint(&expected_buf, "{d}.{d}f", .{ whole, frac / 100 })
    else if (frac % 10 == 0)
        try std.fmt.bufPrint(&expected_buf, "{d}.{d:0>2}f", .{ whole, frac / 10 })
    else
        try std.fmt.bufPrint(&expected_buf, "{d}.{d:0>3}f", .{ whole, frac });

    const mirror = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, scale_mirror_file, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(mirror);
    for (mirror_prefixes) |prefix| {
        const at = std.mem.indexOf(u8, mirror, prefix) orelse {
            std.debug.print(
                "\n아이콘 배율 미러 지점을 못 찾았습니다: {s}에 `{s}…`가 없습니다.\n" ++
                    "표현식을 바꿨다면 이 가드의 mirror_prefixes도 함께 고쳐야 합니다.\n",
                .{ scale_mirror_file, prefix },
            );
            return error.IconScaleMirrorSiteMissing;
        };
        const value_at = at + prefix.len;
        if (!std.mem.startsWith(u8, mirror[value_at..], expected)) {
            const tail = @min(mirror.len, value_at + 12);
            std.debug.print(
                "\n아이콘 배율 미러 불일치: 토큰 {d} milli → `{s}` 인데 {s}에는 `{s}`가 있습니다.\n",
                .{ milli, expected, scale_mirror_file, mirror[value_at..tail] },
            );
            return error.IconScaleMirrorDrift;
        }
    }
}

test "integerLiteralValue: 진법·숫자 구분자·선행 0을 값으로 흡수한다" {
    try std.testing.expectEqual(@as(?u32, 0xF0023), integerLiteralValue("0xF0023"));
    try std.testing.expectEqual(@as(?u32, 0xF0023), integerLiteralValue("0x0F0023")); // 선행 0
    try std.testing.expectEqual(@as(?u32, 0xF0023), integerLiteralValue("0xF_0023")); // 숫자 구분자
    try std.testing.expectEqual(@as(?u32, 0xF0023), integerLiteralValue("983075")); // 10진
    try std.testing.expectEqual(@as(?u32, 0xF00D), integerLiteralValue("0xF00D")); // 무관한 상수도 값으로
    try std.testing.expectEqual(@as(?u32, null), integerLiteralValue("1.5"));
}

test "scanSource: 주석·문자열 안 //·원시 PUA 문자를 정확히 가른다" {
    const allocator = std.testing.allocator;
    const registered = [_]u32{ 0xF0002, 0xF0023 };

    // 코드의 리터럴은 잡는다(표기 무관).
    try std.testing.expect((try scanSource(allocator, "const a = 0xF0023;", &registered)) != null);
    try std.testing.expect((try scanSource(allocator, "const a = 0x0F0023;", &registered)) != null);
    try std.testing.expect((try scanSource(allocator, "const a = 0xF_0023;", &registered)) != null);
    try std.testing.expect((try scanSource(allocator, "const a = 983075;", &registered)) != null);
    try std.testing.expect((try scanSource(allocator, "const a = \"\\u{F0023}\";", &registered)) != null);
    // 원시 UTF-8 PUA 문자(icons.utf8이 만드는 바로 그 바이트열)도 잡는다.
    try std.testing.expect((try scanSource(allocator, "const a = \"\u{F0023}\";", &registered)) != null);
    // 문자열 안에 `//`가 있어도 그 줄이 사각지대가 되지 않는다(옛 근사가 놓치던 형태).
    try std.testing.expect((try scanSource(allocator, "const u = \"https://x\"; const a = 0xF0023;", &registered)) != null);

    // 주석은 문서다 — 토크나이저가 토큰으로 내지 않으므로 자연히 제외된다.
    try std.testing.expect((try scanSource(allocator, "// 헤더 아이콘(0xF0023)은 1.7×로 그린다", &registered)) == null);
    try std.testing.expect((try scanSource(allocator, "const x = 1; // 0xF0023", &registered)) == null);
    // 등록되지 않은 값은 무관하다 — 20비트 마스크·태그 상수·연결 id가 더 이상 오탐이 아니다.
    try std.testing.expect((try scanSource(allocator, "const mask: u32 = 0xFFFFF;", &registered)) == null);
    try std.testing.expect((try scanSource(allocator, "const tag: u32 = 0xF0000;", &registered)) == null);
    try std.testing.expect((try scanSource(allocator, "var conn = init(alloc, 0xF00D, &reg);", &registered)) == null);
    try std.testing.expect((try scanSource(allocator, "const unreg = 0xF0050;", &registered)) == null);
}

test "loadRegistered: 생성물에서 등록 cp 집합을 읽는다" {
    const allocator = std.testing.allocator;
    var buf: [max_registered]u32 = undefined;
    const len = try loadRegistered(allocator, &buf);
    try std.testing.expect(len >= 30); // 현재 37종 — 파싱이 무너지면 여기서 드러난다
    try std.testing.expect(isRegistered(buf[0..len], 0xF0001)); // git_branch
    try std.testing.expect(isRegistered(buf[0..len], 0xF0023)); // chevron_down/tight
    try std.testing.expect(!isRegistered(buf[0..len], 0xF0050)); // 의도적으로 미등록
}
