const std = @import("std");

// 이 테스트는 **chrome 셀 텍스트의 grapheme cluster 규율**을 강제한다(docs/grapheme-clustering.md §3.1a CG1).
//
// 왜 필요한가: chrome은 터미널과 달리 셀을 매 프레임 문자열에서 새로 만든다. 그 방출 루프가 문자열을
// **codepoint 단위**로 돌면 NFD(macOS 파일시스템 기본)가 자모·결합 문자로 흩어져 그려진다 — 파일 트리
// 한글이 "ㅅㅡㅋㅡ리ㄴㅅㅑㅅ"으로, `café.md`가 `cafe´.md`로 보이던 실제 제보가 그것이다. CG1이 방출을
// cluster 단위(`grapheme.clusterEnd`)로 바꿔 고쳤지만, **그 규율은 `appendEllipsizedTitle` 한 함수 안에만
// 있다.** 셀을 직접 만드는 새 경로를 누가 추가하면 그 경로만 조용히 codepoint 단위로 되돌아간다 —
// 리뷰에서 눈으로 잡는 규칙은 그 순간을 놓친다. 그래서 새 디코드 지점이 생기면 **빌드를 실패시킨다.**
//
// 규칙: **셀을 만드는 함수**(아래 emit 신호를 가진 함수) 안에서 UTF-8을 코드포인트로 디코드하려면
// 이 파일의 allowlist에 **이유와 함께** 등재돼야 한다. 셀을 안 만드는 디코더(파싱·transcript·config 등)는
// 애초에 대상이 아니다 — 규칙이 스스로 범위를 좁혀 무관한 편집에 깨지지 않는다.
//
// 등재는 "면제"가 아니라 **부채 목록**이다. 지금 등재된 셋(주소창 편집 밴드·사이드바 검색 밴드·chrome
// 오버레이 텍스트)은 caret 열 모델이나 오버레이 raster에 묶여 CG1과 같은 방식으로 못 바꾼 것들이고,
// 각 항목의 `reason`이 왜 후속 슬라이스인지 적는다.

/// 함수가 "셀을 만든다"고 보는 신호. 하나라도 있으면 그 함수는 이 규칙의 대상이다.
/// - `.codepoint = ` — `renderer.DrawCell`/`NativeMetalCell` 리터럴(대부분의 chrome 방출 경로)
/// - `cp[idx] = ` — chrome 오버레이 raster의 codepoint 그리드 쓰기(app_session.placeText)
const emit_signals = [_][]const u8{ ".codepoint = ", "cp[idx] = " };

/// UTF-8 → codepoint 디코드 신호. 이게 emit 함수 안에 있으면 cluster 규율 대상이다.
const decode_signals = [_][]const u8{
    "utf8Decode(",
    "Utf8View.init",
    "utf8ByteSequenceLength(",
    "nextCodepoint()",
    "decodeTitleCp(",
};

const Allowed = struct {
    /// 함수 이름(파일 안에서 유일해야 한다).
    function: []const u8,
    /// 왜 codepoint 단위가 허용되는가 — 사라져도 되는 예외인지, 후속 슬라이스인지.
    reason: []const u8,
};

const Target = struct {
    path: []const u8,
    allowed: []const Allowed,
};

const targets = [_]Target{
    .{
        .path = "src/platform/macos/coretext_frame_builder.zig",
        .allowed = &.{
            .{
                .function = "appendCluster",
                .reason = "cluster 방출 본체 — base는 셀에, 나머지는 grapheme_pool에(CG1의 구현 그 자체).",
            },
            .{
                .function = "appendEllipsizedTitle",
                .reason = "cluster 경로의 진입점 — 말줄임 '…' 셀만 직접 만들고 본문은 appendCluster에 위임한다.",
            },
            .{
                .function = "emitEditBand",
                .reason = "주소창 편집 밴드: caret 열이 text_field.fieldLayout(Σ max(1,cellWidth))과 1:1이라 cluster화하려면 L3 레이아웃까지 같이 바꿔야 한다(후속 슬라이스). IME 조합은 입력 경계 composeHangul이 덮는다.",
            },
            .{
                .function = "buildSidebarDrawList",
                .reason = "활동 시각(now·5m·3h·2d)만 직접 방출한다 — producer(sidebar.formatRelativeAge)가 ASCII만 내므로 cluster가 생길 수 없다. 카드 본문 줄은 appendEllipsizedTitle 경유.",
            },
        },
    },
    .{
        .path = "src/platform/macos/app_session.zig",
        .allowed = &.{
            .{
                .function = "placeText",
                .reason = "chrome 오버레이(모달·세팅·팔레트·알림) 텍스트: DrawCell이 아니라 오버레이 raster 그리드(cp/fg/width 배열)에 직접 쓰는 별도 경로라 CG1과 표현이 다르다(후속 슬라이스).",
            },
            .{
                .function = "buildSidebarHeaderDrawList",
                .reason = "사이드바 검색 밴드(query+preedit): 주소창 편집 밴드와 같은 caret 열 모델이라 함께 옮겨야 한다(후속 슬라이스).",
            },
        },
    },
};

/// 최상위·struct 멤버 함수 선언 줄에서 이름을 뽑는다(`pub fn name(`·`fn name(`). zig fmt가 들여쓰기를 고정하므로
/// 같은 들여쓰기의 닫는 중괄호를 함수 끝으로 본다.
fn functionNameAt(line: []const u8) ?[]const u8 {
    const trimmed = line[indentOf(line)..];
    var rest = trimmed;
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

/// 소스 파일을 통째로 읽는다(imports.zig의 readZigFileZ와 같은 IO 규약 — cwd는 build가 리포지토리 루트로 고정).
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

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

fn isAllowed(target: Target, function: []const u8) bool {
    for (target.allowed) |a| if (std.mem.eql(u8, a.function, function)) return true;
    return false;
}

test "chrome 셀을 만드는 함수는 cluster 경로를 쓰거나 이유와 함께 등재돼야 한다 (CG1)" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| allocator.free(v);
        violations.deinit(allocator);
    }
    // 등재 항목이 **실제로** 규칙 대상인지도 함께 본다(stale 등재 검출) — targets가 comptime이라 대상마다
    // 고정 크기 bool로 표시한다. covered를 슬라이스로 모으면 source가 해제된 뒤를 가리키게 된다(UAF).
    inline for (targets) |target| {
        const source = try readSource(allocator, target.path);
        defer allocator.free(source);
        var seen = [_]bool{false} ** target.allowed.len;

        var it = std.mem.splitScalar(u8, source, '\n');
        // 현재 함수 상태(이름·시작 들여쓰기)와 그 함수에서 관측한 신호.
        var cur_name: ?[]const u8 = null;
        var cur_indent: usize = 0;
        var saw_emit = false;
        var saw_decode = false;
        var line_no: usize = 0;
        var decode_line: usize = 0;

        while (it.next()) |line| {
            line_no += 1;
            if (cur_name) |name| {
                // 같은 들여쓰기의 닫는 중괄호 = 함수 끝. 판정 후 상태를 비운다.
                const trimmed = line[indentOf(line)..];
                if (indentOf(line) == cur_indent and (std.mem.startsWith(u8, trimmed, "}") and trimmed.len <= 2)) {
                    if (saw_emit and saw_decode) {
                        var allowed_idx: ?usize = null;
                        inline for (target.allowed, 0..) |a, ai| {
                            if (std.mem.eql(u8, a.function, name)) allowed_idx = ai;
                        }
                        if (allowed_idx) |ai| {
                            seen[ai] = true;
                        } else {
                            try violations.append(allocator, try std.fmt.allocPrint(
                                allocator,
                                "{s}:{d}: `{s}`가 셀을 만들면서 문자열을 codepoint 단위로 디코드합니다. " ++
                                    "chrome 텍스트는 appendEllipsizedTitle(cluster 경로)을 거쳐야 합니다 — " ++
                                    "불가피하면 tests/boundary/chrome_text_clusters.zig의 allowlist에 이유와 함께 등재하세요(docs/grapheme-clustering.md §3.1a).",
                                .{ target.path, decode_line, name },
                            ));
                        }
                    }
                    cur_name = null;
                    saw_emit = false;
                    saw_decode = false;
                    continue;
                }
                if (containsAny(line, &emit_signals)) saw_emit = true;
                if (containsAny(line, &decode_signals)) {
                    if (!saw_decode) decode_line = line_no;
                    saw_decode = true;
                }
                continue;
            }
            if (functionNameAt(line)) |name| {
                cur_name = name;
                cur_indent = indentOf(line);
                saw_emit = containsAny(line, &emit_signals);
                saw_decode = containsAny(line, &decode_signals);
                if (saw_decode) decode_line = line_no;
            }
        }

        // 등재해 놓고 실제로는 규칙 대상이 아닌 항목(= 이미 cluster로 옮겼거나 함수가 사라짐)은 **지워야 한다**.
        // 부채 목록이 실제 부채와 어긋나면 목록이 거짓말을 하게 되고, 다음 사람이 "이건 원래 예외"라고 믿는다.
        inline for (target.allowed, 0..) |a, ai| {
            if (!seen[ai]) {
                try violations.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "{s}: allowlist의 `{s}`가 더 이상 규칙 대상이 아닙니다(셀+디코드 조합 없음). 등재를 지우세요 — 사유: {s}",
                    .{ target.path, a.function, a.reason },
                ));
            }
        }
    }

    if (violations.items.len > 0) {
        std.debug.print("\nchrome 텍스트 cluster 규율 위반 {d}건:\n", .{violations.items.len});
        for (violations.items) |v| std.debug.print("  - {s}\n", .{v});
        return error.ChromeTextClusterBoundaryViolation;
    }
}

test "cluster 경로 자체가 사라지지 않았는가 (CG1 회귀 가드)" {
    // 위 스캔은 "codepoint 단위 방출이 새로 생겼는가"를 본다. 이 테스트는 반대 방향 — **cluster 방출이
    // 통째로 사라지는** 회귀(예: 리팩터로 appendCluster를 되돌림)를 잡는다. 둘이 같이 있어야 규율이 닫힌다.
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/platform/macos/coretext_frame_builder.zig");
    defer allocator.free(source);
    // cluster 경계를 실제로 쓰고(grapheme.clusterEnd) 본체를 풀에 싣는(grapheme_offset) 코드가 남아 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, source, "grapheme.clusterEnd(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".grapheme_offset = offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".grapheme_pool = try pool.toOwnedSlice(allocator)") != null);
}
