const std = @import("std");

// 이 테스트는 **chrome 셀 텍스트의 grapheme cluster 규율**을 강제한다(docs/grapheme-clustering.md §3.1b CG1).
//
// 왜 필요한가: chrome은 터미널과 달리 셀을 매 프레임 문자열에서 새로 만든다. 그 방출 루프가 문자열을
// **codepoint 단위**로 돌면 NFD(macOS 파일시스템 기본)가 자모·결합 문자로 흩어져 그려진다 — 파일 트리
// 한글이 "ㅅㅡㅋㅡ리ㄴㅅㅑㅅ"으로, `café.md`가 `cafe´.md`로 보이던 실제 제보가 그것이다. CG1이 방출을
// cluster 단위(`grapheme.clusterEnd`)로 바꿔 고쳤고, 그 배치 규율은 이제 **chrome `text_layout`(L3, OS-중립)**이
// 소유한다(docs/layering-and-portability.md §7.9 CT-OWN — platform은 계획을 셀로 옮기는 어댑터).
// **그래도 규율은 그 한 경로 안에만 있다.** 셀을 직접 만드는 새 경로를 누가 추가하면 그 경로만 조용히 codepoint 단위로 되돌아간다 —
// 리뷰에서 눈으로 잡는 규칙은 그 순간을 놓친다(NFD 증상은 한글·악센트 이름이 화면에 있어야만 드러난다).
//
// **규칙**: 셀을 만드는 함수는 (a) cluster 경로(`text_layout.plan`/`appendEllipsizedTitle`/`appendCluster`)에 위임하거나,
// (b) 문자열을 직접 디코드하지 않거나, (c) allowlist에 **이유와 함께** 등재돼야 한다. 여기에 더해
// **문자열 → 코드포인트 슬라이스 변환기**(`[]const u8` → `[]u21`)도 같은 규칙을 받는다.
//
// 1차 가드(2026-07-28)의 구멍을 code-review max가 5개 찾아 여기서 메웠다. 무엇을 어떻게 막았는지:
//   - **헬퍼 분리 우회**: 디코드를 다른 함수로 빼면 emit 함수에 디코드 신호가 없어 통과했다 → 우회의 **재료**인
//     `[]const u8` → `[]u21` 변환 헬퍼를 시그니처로 잡는다(방출 쪽에서는 안 보이므로 그쪽에서 막는다).
//   - **한 줄 함수가 스팬을 삼킴**: `fn f() void {}`는 닫는 중괄호가 선언 줄에 있어 스팬이 안 닫혔고, 뒤따르는
//     함수들이 그 이름으로 흡수돼 **엉뚱한 함수명으로 위반이 뜨고 유효한 등재를 지우라고 지시**했다 →
//     중괄호 수지(depth)로 스팬을 닫는다.
//   - **지역변수 철자에 묶인 신호**: `cp[idx] = `는 placeText의 현재 변수명에만 맞아, 이름만 바꿔도 커버리지가
//     사라졌다 → 오버레이 raster는 **시그니처 타입**(`[]u21` 파라미터)으로 잡는다.
//   - **대상 파일 2개 고정**: 새 파일에 만든 방출자는 안 보였다 → `src/` 전체를 재귀 스캔한다.
//   - **pool 배선 누락 미검출**: `&pool`을 넘기고도 `.grapheme_pool`을 리터럴에 안 실으면 셰이퍼가 base만
//     그려(중성·종성 소멸) CG1 이전보다 나빠지는데 통과했다 → 짝을 함수 단위로 검사한다.

/// "이 함수가 셀(또는 셀 그리드)을 만든다"는 신호.
/// - `.codepoint = ` — `renderer.DrawCell`/`NativeMetalCell` 리터럴(대부분의 chrome 방출 경로)
/// - `: []u21` — chrome 오버레이 raster의 codepoint 그리드를 받는 시그니처(metal_lowering.placeText).
///   변수 철자가 아니라 **타입**을 키로 삼아, 지역변수를 rename해도 커버리지가 안 사라지게 한다.
const emit_signals = [_][]const u8{ ".codepoint = ", ": []u21" };

/// UTF-8을 코드포인트로 푸는 신호. 1차 가드는 목록이 좁아 `utf8Decode2/3/4`·`nextCodepointSlice`·손수 만든
/// 이터레이터를 놓쳤다(code-review max) — 여기서 넓혔다.
const decode_signals = [_][]const u8{
    "utf8Decode(",
    "utf8Decode2(",
    "utf8Decode3(",
    "utf8Decode4(",
    "Utf8View",
    "Utf8Iterator",
    "utf8ByteSequenceLength(",
    "nextCodepoint()",
    "nextCodepointSlice()",
    "decodeCodepoint(",
};

/// **디코드를 헬퍼로 빼는 우회**를 그 헬퍼 쪽에서 막는다: `[]const u8`을 받아 코드포인트 슬라이스를 돌려주는
/// 함수(`fn decodeLabel(a, s) ![]u21`)는 "문자열 → 코드포인트" 변환 그 자체이고, 그걸 방출 루프에서 돌면
/// cluster가 깨진다. 방출 함수 쪽에서는 디코드 신호가 안 보이므로 여기서 잡는다.
///
/// 처음엔 방출 함수의 **루프**를 두 번째 트리거로 썼는데 못 쓴다 — 터미널·renderer의 grid producer(문자열이
/// 아니라 스냅샷·배열에서 셀을 만든다)가 전부 걸리고, 텍스트 여부를 문자열 매칭으로 가리려다 `cursor_colors.text`
/// 같은 **색 필드**까지 텍스트로 세는 오탐이 났다(실측). 타입 시그니처는 그런 철자 우연이 없다.
const codepoint_slice_returns = [_][]const u8{ "![]u21", "[]u21 {", "![]u32", "[]u32 {" };

/// cluster 경로 위임 신호 — 이게 있으면 그 함수는 방출을 cluster-aware 헬퍼에 맡긴 것이다.
const delegation_signals = [_][]const u8{ "text_layout.plan(", "appendEllipsizedTitle(", "appendCluster(" };

const Allowed = struct {
    /// `src/` 기준 상대 경로.
    file: []const u8,
    /// 함수 이름.
    function: []const u8,
    /// 왜 cluster 경로를 안 쓰는가 — 사라져도 되는 예외인지, 후속 슬라이스인지.
    reason: []const u8,
};

/// **면제 목록이 아니라 부채 목록**이다. 등재 항목이 더 이상 규칙 대상이 아니면(cluster로 옮겼거나 함수가
/// 사라짐) 아래 stale 검사가 "등재를 지우라"고 실패시킨다 — 목록이 실제와 어긋나 거짓말하지 않게.
const allowlist = [_]Allowed{
    .{
        .file = "platform/macos/coretext_frame_builder.zig",
        .function = "appendCluster",
        .reason = "cluster 방출 어댑터 — text_layout이 잡아 준 바이트 범위에서 base는 셀에, 나머지는 grapheme_pool에(CG1 방출부 그 자체).",
    },
    .{
        .file = "platform/macos/chrome/chrome_draw_lowering.zig",
        .function = "appendCluster",
        .reason = "SessionDock의 단일 DrawList cluster 방출 어댑터 — text_layout.plan이 확정한 범위만 DrawCell/grapheme_pool으로 옮기며, 별도 UTF-8 순회나 폭 계산을 하지 않는다.",
    },
    .{
        .file = "platform/macos/coretext_frame_builder.zig",
        .function = "emitEditBand",
        .reason = "주소창 편집 밴드: caret 열이 text_field.fieldLayout(Σ max(1,cellWidth))과 1:1이라 cluster화하려면 L3 레이아웃까지 같이 바꿔야 한다(후속 슬라이스). IME 조합은 입력 경계 composeHangul이 덮는다.",
    },
    .{
        .file = "platform/macos/chrome/metal_lowering.zig",
        .function = "placeText",
        .reason = "chrome 오버레이(모달·세팅·팔레트·알림) 텍스트: DrawCell이 아니라 오버레이 raster 그리드(cp/fg/width 배열)에 직접 쓰는 별도 경로라 CG1과 표현이 다르다(후속 슬라이스).",
    },
    .{
        .file = "terminal/preedit.zig",
        .function = "drawCells",
        .reason = "IME preedit 오버레이: 확정 전 텍스트를 base snapshot 위 scratch에 codepoint 단위로 임시 렌더한다 — 셀 저장이 아니라 표시 전용이고, 주 타깃 한글 IME가 완성형(NFC) marked text를 보내 실사용 증상이 없다(docs/grapheme-clustering.md §4.7의 '의도된 한계').",
    },
};

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("chrome text scan could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// 주석(`//` 이후)을 잘라 낸 코드 부분. 주석에 적힌 `.codepoint = `·`decodeCodepoint(`를 진짜 신호로 세던
/// 오탐을 없앤다(문자열 리터럴 안의 `//`까지 가리진 않지만, 이 코드베이스에서 그 조합은 나오지 않는다).
fn codePart(line: []const u8) []const u8 {
    const cut = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..cut];
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

/// 함수 선언 줄에서 이름을 뽑는다(`pub fn name(`·`fn name(`).
fn functionNameAt(line: []const u8) ?[]const u8 {
    var rest = line[indentOf(line)..];
    inline for ([_][]const u8{ "pub ", "export ", "inline ", "noinline ", "threadlocal " }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) rest = rest[prefix.len..];
    }
    if (!std.mem.startsWith(u8, rest, "fn ")) return null;
    const after = rest[3..];
    const paren = std.mem.indexOfScalar(u8, after, '(') orelse return null;
    const name = std.mem.trim(u8, after[0..paren], " ");
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

/// 코드 부분의 중괄호 수지. 함수 스팬을 **들여쓰기가 아니라 depth**로 닫아, 한 줄 함수(`fn f() void {}`)가
/// 뒤따르는 선언들을 삼키지 않게 한다(1차 가드의 실제 오작동 — 엉뚱한 이름으로 위반이 뜨고 유효한 등재를
/// 지우라고 지시했다). 문자열/문자 리터럴 안의 중괄호는 세지 않는다.
fn braceDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var in_str = false;
    var in_char = false;
    var i: usize = 0;
    const code = codePart(line);
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (c == '\\') {
            i += 1; // 이스케이프 다음 글자는 건너뛴다
            continue;
        }
        if (in_str) {
            if (c == '"') in_str = false;
            continue;
        }
        if (in_char) {
            if (c == '\'') in_char = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '\'' => in_char = true,
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }
    return delta;
}

const Violation = struct { text: []u8 };

/// 한 파일을 스캔해 위반을 모으고, 등재 항목이 실제로 규칙 대상이었는지 `seen`에 표시한다.
fn scanFile(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    source: []const u8,
    seen: []bool,
    violations: *std.ArrayList(Violation),
) !void {
    var it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var cur_name: ?[]const u8 = null;
    var depth: i32 = 0;
    var saw_emit = false;
    var saw_decode = false;
    var saw_delegate = false;
    var sig_text_in = false; // 시그니처가 []const u8(문자열)을 받는가
    var sig_cp_out = false; // 시그니처가 []u21/[]u32(코드포인트 슬라이스)를 돌려주는가
    var opened = false; // 여는 중괄호를 아직 못 봤으면(여러 줄 시그니처) 함수가 안 열린 것
    var saw_pool_arg = false; // `&pool`을 cluster 헬퍼에 넘겼는가
    var saw_pool_field = false; // 반환 리터럴에 `.grapheme_pool = `을 실었는가
    var start_line: usize = 0;

    while (it.next()) |line| {
        line_no += 1;
        const code = codePart(line);
        var is_decl_line = false;
        if (cur_name == null) {
            if (functionNameAt(line)) |name| {
                cur_name = name;
                start_line = line_no;
                depth = 0;
                saw_emit = false;
                saw_decode = false;
                saw_delegate = false;
                sig_text_in = false;
                sig_cp_out = false;
                opened = false;
                saw_pool_arg = false;
                saw_pool_field = false;
                is_decl_line = true;
            } else continue;
        }
        if (containsAny(code, &emit_signals)) saw_emit = true;
        if (containsAny(code, &decode_signals)) saw_decode = true;
        // 위임 판정에서 **선언 줄은 뺀다** — `fn appendCluster(`가 자기 이름 때문에 위임으로 오인되면
        // cluster 방출 본체가 규칙 대상에서 빠져 allowlist가 stale로 뜬다(1차 가드의 실제 오작동).
        if (!is_decl_line and containsAny(code, &delegation_signals)) saw_delegate = true;
        // 시그니처(본문 시작 전)만 본다 — 본문의 지역 타입은 대상이 아니다.
        if (!opened) {
            if (std.mem.indexOf(u8, code, "[]const u8") != null) sig_text_in = true;
            if (containsAny(code, &codepoint_slice_returns)) sig_cp_out = true;
        }
        if (std.mem.indexOf(u8, code, "&pool") != null) saw_pool_arg = true;
        if (std.mem.indexOf(u8, code, ".grapheme_pool = ") != null) saw_pool_field = true;
        depth += braceDelta(code);
        if (depth > 0) {
            opened = true;
            continue; // 아직 함수 안
        }
        if (!opened and depth == 0 and !is_decl_line) continue; // 여러 줄 시그니처 — 본문 시작 전
        if (!opened and is_decl_line and depth == 0) continue; // 선언 줄에 `{`가 없다(여러 줄 시그니처)
        // depth가 0으로 돌아왔다 = 함수 끝(한 줄 함수는 선언 줄에서 바로 닫힌다).
        const name = cur_name.?;
        var allowed_idx: ?usize = null;
        for (allowlist, 0..) |a, ai| {
            if (std.mem.eql(u8, a.function, name) and std.mem.eql(u8, a.file, rel_path)) allowed_idx = ai;
        }
        // 트리거 둘: (1) 셀을 만들면서 직접 디코드, (2) 문자열 → 코드포인트 슬라이스 변환기(헬퍼 분리 우회의 재료).
        const emits_per_codepoint = saw_emit and saw_decode and !saw_delegate;
        const is_decode_helper = sig_text_in and sig_cp_out;
        if (emits_per_codepoint or is_decode_helper) {
            if (allowed_idx) |ai| {
                seen[ai] = true;
            } else {
                try violations.append(allocator, .{ .text = try std.fmt.allocPrint(
                    allocator,
                    "src/{s}:{d}: `{s}`가 {s}. chrome 텍스트는 cluster 경로(chrome/text_layout.plan → appendEllipsizedTitle)에 위임해야 합니다 — " ++
                        "불가피하면 tests/boundary/chrome_text_clusters.zig의 allowlist에 이유와 함께 등재하세요(docs/grapheme-clustering.md §3.1b).",
                    .{
                        rel_path,
                        start_line,
                        name,
                        if (is_decode_helper)
                            "문자열을 코드포인트 슬라이스로 푸는 헬퍼입니다(그 결과를 셀로 깔면 cluster가 깨집니다)"
                        else
                            "셀을 만들면서 문자열을 직접 디코드합니다",
                    },
                ) });
            }
        }
        // pool 짝 검사: cluster 헬퍼에 풀을 넘겼으면 그 DrawList에 반드시 실어야 한다. 안 실으면 셰이퍼가
        // `offset+count > pool_len` 폴백으로 **base만** 그려 중성·종성이 사라진다(CG1 이전보다 나쁘다).
        if (saw_pool_arg and !saw_pool_field) {
            try violations.append(allocator, .{ .text = try std.fmt.allocPrint(
                allocator,
                "src/{s}:{d}: `{s}`가 cluster 풀(&pool)을 채우고도 반환 DrawList에 `.grapheme_pool`을 싣지 않습니다 — " ++
                    "셰이퍼가 base만 그려 NFD 음절의 중성·종성이 사라집니다.",
                .{ rel_path, start_line, name },
            ) });
        }
        cur_name = null;
    }
}

test "chrome 셀을 만드는 함수는 cluster 경로에 위임하거나 이유와 함께 등재돼야 한다 (CG1)" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList(Violation) = .empty;
    defer {
        for (violations.items) |v| allocator.free(v.text);
        violations.deinit(allocator);
    }
    var seen = [_]bool{false} ** allowlist.len;

    // **`src/` 전체를 재귀 스캔한다** — 대상 파일을 열거하면 새 파일에 만든 방출자가 사각지대가 된다.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const rel = try allocator.dupe(u8, entry.path);
        defer allocator.free(rel);
        const full = try std.fmt.allocPrint(allocator, "src/{s}", .{rel});
        defer allocator.free(full);
        const source = try readSource(allocator, full);
        defer allocator.free(source);
        // 셀 신호도 변환-헬퍼 신호도 없는 파일은 건너뛴다(스캔 비용 절감). **둘 다** 봐야 한다 — 헬퍼는 셀을
        // 만들지 않으므로 emit 신호만으로 거르면 우회의 재료가 통째로 사각지대가 된다(실측으로 잡은 구멍).
        if (!containsAny(source, &emit_signals) and !containsAny(source, &codepoint_slice_returns)) continue;
        try scanFile(allocator, rel, source, &seen, &violations);
    }

    // 등재해 놓고 실제로는 규칙 대상이 아닌 항목(= 이미 cluster로 옮겼거나 함수가 사라짐)은 **지워야 한다**.
    for (allowlist, 0..) |a, ai| {
        if (!seen[ai]) {
            try violations.append(allocator, .{ .text = try std.fmt.allocPrint(
                allocator,
                "src/{s}: allowlist의 `{s}`가 더 이상 규칙 대상이 아닙니다(셀+한글자순회 조합 없음). 등재를 지우세요 — 사유: {s}",
                .{ a.file, a.function, a.reason },
            ) });
        }
    }

    if (violations.items.len > 0) {
        std.debug.print("\nchrome 텍스트 cluster 규율 위반 {d}건:\n", .{violations.items.len});
        for (violations.items) |v| std.debug.print("  - {s}\n", .{v.text});
        return error.ChromeTextClusterBoundaryViolation;
    }
}

test "cluster 경로 자체가 사라지지 않았는가 (CG1 회귀 가드)" {
    // 위 스캔은 "codepoint 단위 방출이 새로 생겼는가"를 본다. 이 테스트는 반대 방향 — **cluster 방출이
    // 통째로 사라지는** 회귀(예: 리팩터로 appendCluster를 되돌림)를 잡는다. 둘이 같이 있어야 규율이 닫힌다.
    // 분절(L3 chrome)과 방출(L4 platform)이 나뉘었으므로(§7.9 CT-OWN) 양쪽을 각각 본다 — 한쪽만 보면
    // "계획은 cluster인데 어댑터가 base만 그린다"(또는 그 반대)를 놓친다.
    const allocator = std.testing.allocator;
    const layout_source = try readSource(allocator, "src/chrome/text_layout.zig");
    defer allocator.free(layout_source);
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "grapheme.clusterEnd(") != null); // 분절이 cluster 경계로

    const source = try readSource(allocator, "src/platform/macos/coretext_frame_builder.zig");
    defer allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "text_layout.plan(") != null); // 방출이 중립 계획에 위임
    try std.testing.expect(std.mem.indexOf(u8, source, ".grapheme_offset = offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".grapheme_pool = owned_pool") != null);
}
