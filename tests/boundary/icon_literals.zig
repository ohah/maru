const std = @import("std");

// 이 테스트는 **아이콘을 codepoint 리터럴로 부르지 않는다**는 디자인 시스템 규율을 강제한다
// (docs/chrome-strategy.md §9.7).
//
// 왜 필요한가: 등록 아이콘의 Plane-15 PUA codepoint를 소비처가 `0xF0023`·`"\u{F0023}"`로 직접 적으면
//   (a) 어느 그림인지 코드에서 안 읽히고,
//   (b) 자산이 재배치되면(무게 변형 흡수·이름 정리) **조용히 다른 아이콘이 되거나 미등록 cp가 돼**
//       폰트 폴백(빈 칸 또는 엉뚱한 Nerd Fonts MDI 글리프)으로 빠진다. 컴파일러는 못 잡는다.
// 그래서 이름 registry(`src/icons.zig` — 생성물)의 `icons.codepoint(.x)`/`icons.utf8(.x)`만 쓴다.
//
// IC2가 소비처를 전부 이름으로 옮겼고, 이 가드가 그 상태를 고정한다 — 없으면 새 코드가 리터럴로
// 조용히 되돌아간다(리뷰 눈으로 잡는 규칙은 그 순간을 놓친다).
//
// **스캔 범위**: `src/` 전체의 `.zig`. 생성물과 "의도적으로 미등록인 cp"만 예외다(아래).
// 주석은 문서라서 제외한다 — 줄에서 `//` 뒤를 잘라내고 본다(문자열 안의 `//`는 이 코드베이스에 없어
// 근사로 충분하고, 근사가 틀려도 방향은 **덜 잡는 쪽**이라 오탐을 만들지 않는다).

/// 리터럴을 그대로 둬야 하는 파일. 생성물 자신과 이름↔cp 대응을 증명하는 테스트만 해당한다.
const exempt_files = [_][]const u8{
    "icons.zig", // 생성물 — 이름↔codepoint 대응 그 자체다.
    "renderer/icon_coverage_data.zig", // 생성물 — coverage 데이터 + 매니페스트.
};

/// **의도적으로 미등록**인 cp. 등록되지 않은 PUA가 폰트로 폴백하는지 보는 회귀 테스트가 쓰므로 이름이 없다
/// (이름을 주면 그 순간 등록 아이콘이 돼 테스트가 증명하려던 것이 사라진다).
const unregistered_sentinels = [_]u32{ 0xF0050, 0xF00FF };

const Violation = struct { text: []u8 };

fn isExempt(rel: []const u8) bool {
    for (exempt_files) |e| if (std.mem.eql(u8, rel, e)) return true;
    return false;
}

fn isHex(c: u8) bool {
    return std.ascii.isHex(c);
}

/// `start`부터 이어지는 hex 숫자를 값과 개수로 읽는다. 값이 Plane-15 PUA 범위(0xF0000~0xFFFFF)인지는 호출자가 본다.
fn readHex(code: []const u8, start: usize) struct { value: u32, len: usize } {
    var i = start;
    var value: u32 = 0;
    while (i < code.len and isHex(code[i])) : (i += 1) {
        // 자릿수가 5를 넘으면 아이콘 cp가 아니다 — 값 누적을 멈춰 긴 마스크 상수(`0xFFFFFFFFFFFFFFFF`)에서
        // overflow로 죽지 않게 한다. 길이는 계속 세어 호출자가 "정확히 5자리"를 판정한다.
        if (i - start < 5) value = value * 16 + (std.fmt.charToDigit(code[i], 16) catch break);
    }
    return .{ .value = value, .len = i - start };
}

fn isSentinel(cp: u32) bool {
    for (unregistered_sentinels) |s| if (s == cp) return true;
    return false;
}

/// 코드(주석 제외)에 등록 아이콘 codepoint 리터럴이 있는가.
///
/// 두 표기를 본다: 정수 `0xF0023`과 문자열 escape `"\u{F0023}"`. **다섯 자리 hex 전체**를 읽어 값으로 판정하므로
/// `0xF00D`(session_host의 연결 id 같은 무관한 상수)는 자릿수가 달라 걸리지 않는다 — 접두사만 보던 첫 판이
/// 그걸 오탐했다.
fn scanLine(line: []const u8) ?usize {
    const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const digits_at: usize = if (std.mem.startsWith(u8, code[i..], "0x"))
            i + 2
        else if (std.mem.startsWith(u8, code[i..], "\\u{"))
            i + 3
        else
            continue;
        const hex = readHex(code, digits_at);
        if (hex.len != 5) continue; // PUA cp는 다섯 자리다(0xF0001~) — 다른 길이의 상수는 무관.
        if (hex.value < 0xF0000 or hex.value > 0xFFFFF) continue;
        if (isSentinel(hex.value)) continue;
        return i;
    }
    return null;
}

test "아이콘은 이름 registry로만 부른다 — codepoint 리터럴 금지 (docs/chrome-strategy.md §9.7)" {
    const allocator = std.testing.allocator;
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

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| {
            line_no += 1;
            if (scanLine(line) == null) continue;
            try violations.append(allocator, .{ .text = try std.fmt.allocPrint(
                allocator,
                "src/{s}:{d}: 아이콘 codepoint 리터럴 — `icons.codepoint(.name)`/`icons.utf8(.name)`을 쓰세요",
                .{ entry.path, line_no },
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
// 보므로 조용히 지나간다. 그래서 토큰 값이 .m 소스에 그대로 있는지 문자열로 확인한다(C 게이트 헤더를 생성해
// 맞추는 `icon_codepoints.h`와 같은 결의 미러 가드다).
const scale_token_file = "src/chrome/ui/icon.zig";
const scale_mirror_file = "src/platform/macos/maru_metal_renderer.m";

test "아이콘 셀 래스터 배율은 Zig 토큰과 Objective-C 미러가 같다" {
    const allocator = std.testing.allocator;
    const token_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, scale_token_file, allocator, .limited(64 * 1024));
    defer allocator.free(token_source);

    // `pub const cell_raster_scale_milli: u32 = 1700;` → 1700 → "1.7f"
    const needle = "cell_raster_scale_milli: u32 = ";
    const start = (std.mem.indexOf(u8, token_source, needle) orelse return error.TestUnexpectedResult) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, token_source, start, ';') orelse return error.TestUnexpectedResult;
    const milli = try std.fmt.parseInt(u32, token_source[start..end], 10);
    try std.testing.expectEqual(@as(u32, 0), milli % 100); // 아래 소수 표기가 두 자리면 충분하다는 전제
    var expected_buf: [16]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{d}.{d}f", .{ milli / 1000, (milli % 1000) / 100 });

    const mirror = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, scale_mirror_file, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(mirror);
    if (std.mem.indexOf(u8, mirror, expected) == null) {
        std.debug.print(
            "\n아이콘 배율 미러 불일치: {s}의 토큰({d} milli = `{s}`)이 {s}에 없습니다.\n",
            .{ scale_token_file, milli, expected, scale_mirror_file },
        );
        return error.IconScaleMirrorDrift;
    }
}

test "scanLine: 등록 리터럴은 잡고 주석·미등록 sentinel·무관한 hex는 통과시킨다" {
    try std.testing.expect(scanLine("    .codepoint = 0xF0023,") != null);
    try std.testing.expect(scanLine("const a = \"\\u{F000C}\";") != null);
    // 주석은 문서다 — 잡지 않는다.
    try std.testing.expect(scanLine("// 헤더 아이콘(0xF0002)은 1.7×로 그린다") == null);
    try std.testing.expect(scanLine("const x = 1; // 0xF0023") == null);
    // 의도적으로 미등록인 cp(폰트 폴백 회귀 테스트)는 이름이 없으므로 통과 — 두 표기 모두.
    try std.testing.expect(scanLine("    try expect(!isRegisteredIcon(0xF0050));") == null);
    try std.testing.expect(scanLine("    .codepoint = 0xF00FF,") == null);
    try std.testing.expect(scanLine("    displayCols(\"\\u{F0050}\", p);") == null);
    // 아이콘 범위가 아닌 값·자릿수가 다른 상수는 무관(0xF00D = session_host 연결 id).
    try std.testing.expect(scanLine("const mask = 0xFF00;") == null);
    try std.testing.expect(scanLine("const cp = 0x2588;") == null);
    try std.testing.expect(scanLine("    var conn = Connection.init(allocator, 0xF00D, &registry);") == null);
}
