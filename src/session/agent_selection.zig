//! 파일 패널에서 고른 선택을 터미널 CLI에 붙여넣을 페이로드로 조립한다(docs/send-selection-to-agent.md).
//!
//! **이 모듈이 안전 계약을 소유한다.** 터미널에 쓰는 바이트는 셸의 표준 입력이라 개행이 섞이면 그 자리에서
//! 실행된다. 문서 인용에는 임의 텍스트가 들어올 수 있으므로 ⑴ 페이로드 끝에 개행을 붙이지 않고, ⑵ bracketed
//! paste가 꺼진 대상에는 여러 줄을 보내지 않으며, ⑶ 인용을 상한으로 자른다.
//!
//! DOM·AppKit 비의존 순수 로직이라 헤드리스로 전수 검증한다(L2 중립).

const std = @import("std");

/// 인용 상한. 넘으면 자르고 생략 표시를 붙인다. 상한이 없으면 큰 문서를 통째로 붙여넣어 대상 프롬프트가 마비된다.
pub const max_quote_lines: usize = 64;
pub const max_quote_bytes: usize = 8 * 1024;

pub const Selection = struct {
    /// 트리 루트 기준 상대 경로(루트 밖이면 절대 경로). native가 핀 경로에서 파생한다 — web은 지정할 수 없다.
    path: []const u8,
    /// 1-based 닫힌 구간.
    start_line: u32,
    end_line: u32,
    /// 사용자가 고른 원문. 이스케이프하지 않는다 — 셸이 해석할 자리가 아니라 에이전트 프롬프트에 놓기 때문이다.
    text: []const u8,
};

pub const Options = struct {
    /// 대상이 bracketed paste를 켜 두었는가. 꺼져 있으면 여러 줄을 보내지 않는다(중간 개행이 실행 트리거가 된다).
    bracketed_paste: bool,
};

/// `@경로:시작-끝` 한 줄을 쓴다. 한 줄 선택이면 범위를 접는다.
fn writeReference(writer: *std.Io.Writer, sel: Selection) !void {
    if (sel.start_line == sel.end_line) {
        try writer.print("@{s}:{d}", .{ sel.path, sel.start_line });
    } else {
        try writer.print("@{s}:{d}-{d}", .{ sel.path, sel.start_line, sel.end_line });
    }
}

/// 선택 텍스트를 `> ` 인용으로 감싸 쓴다. 상한을 넘으면 자르고 생략 줄을 붙인다.
/// 반환값은 생략된 줄 수(0이면 전량 포함).
fn writeQuote(writer: *std.Io.Writer, text: []const u8) !usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| total += 1;

    var written_lines: usize = 0;
    var written_bytes: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // 바이트 상한은 줄 단위로 끊는다 — UTF-8 중간에서 자르면 깨진 글자가 나간다.
        if (written_lines >= max_quote_lines or written_bytes + line.len > max_quote_bytes) break;
        try writer.writeAll("\n> ");
        try writer.writeAll(line);
        written_lines += 1;
        written_bytes += line.len;
    }
    return total - written_lines;
}

/// 페이로드를 조립해 `out`에 쓴다. 반환은 쓴 바이트 수(버퍼 부족이면 null — fail-closed).
///
/// **끝에 개행을 붙이지 않는다.** 사용자가 프롬프트를 보고 직접 Enter를 눌러야 전송된다.
pub fn build(sel: Selection, options: Options, out: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    writeReference(&writer, sel) catch return null;
    // bracketed paste가 꺼진 대상에는 인용을 붙이지 않는다. 안전한 축약(경로 참조 한 줄)이 가능한데 여러 줄
    // 개행을 흘려보낼 이유가 없다. 참조만으로도 에이전트가 그 파일 그 줄을 열 수 있다.
    if (options.bracketed_paste and sel.text.len > 0) {
        const omitted = writeQuote(&writer, sel.text) catch return null;
        if (omitted > 0) writer.print("\n> …({d}줄 생략)", .{omitted}) catch return null;
    }
    return writer.buffered();
}

// ── NS3: 후보와 경로 (docs/send-selection-to-agent.md §5) ──────────────────────────────────────

/// 트리 루트 기준으로 경로를 접는다. **루트 밖이면 절대 경로 그대로**다.
///
/// **에이전트가 그 자리에서 열 수 있어야 한다**(§2). 에이전트 CLI 의 cwd 는 보통 저장소 루트라
/// 상대 경로가 짧고 바로 열린다. 루트 밖 파일을 상대로 접으면 `../../..` 가 되어 오히려 못 연다 —
/// 그때는 절대 경로가 맞다.
///
/// **접두 문자열 비교만으로 접으면 안 된다.** `/a/bc` 는 `/a/b` 로 시작하지만 그 안이 아니다.
/// 경계에 `/` 가 오는지까지 봐야 한다(실제로 그 실수가 흔하다).
pub fn relativePath(root: []const u8, path: []const u8) []const u8 {
    if (root.len == 0 or path.len == 0) return path;
    const trimmed = if (root.len > 1 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (path.len <= trimmed.len) return path;
    if (!std.mem.startsWith(u8, path, trimmed)) return path;
    if (path[trimmed.len] != '/') return path; // `/a/bc` 는 `/a/b` 안이 아니다
    const rest = path[trimmed.len + 1 ..];
    return if (rest.len == 0) path else rest;
}

/// 후보 종류. **정렬 순서를 이 enum 이 든다** — 값이 작을수록 위다.
///
/// 에이전트를 먼저 올리는 이유는 §5 가 적었다. 일반 셸도 후보로 두는 이유도 거기 있다 —
/// `tail -f` 를 보는 창에 보내고 싶을 수 있다.
pub const CandidateKind = enum(u8) {
    claude = 0,
    codex = 1,
    shell = 2,

    /// 라벨 앞머리. 에이전트는 이름, 셸은 그 셸 이름을 호출자가 준다.
    pub fn agentName(self: CandidateKind) ?[]const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
            .shell => null,
        };
    }

    /// 줄 맨 앞 **종류 기호**(사용자 요청 2026-08-31 — "클로드인지 코덱스인지 아이콘이나 색으로").
    ///
    /// **왜 기호인가**: 컨텍스트 메뉴는 문자열 배열만 받고 행마다 색이 하나다(`context_menu.view`).
    /// 색으로 가르려면 그 컴포넌트에 항목별 role 을 들이는 확장이 필요한데, 그것은 모든 소비처에
    /// 영향이 간다. 기호는 **켜짐 표시(`check_glyph`)가 이미 쓰는 자리**라 컴포넌트가 그대로다.
    ///
    /// **번역하지 않는다** — 기호는 번역 단위가 아니다(같은 규율이 `context_menu` 주석에 있다).
    /// **셸에도 기호를 준다**: 빈 칸을 두면 에이전트 줄과 셸 줄의 글자가 좌우로 어긋나 목록이
    /// 들쭉날쭉해진다(켜짐 표시가 꺼진 줄에 같은 폭의 공백을 넣는 것과 같은 이유다).
    pub fn glyph(self: CandidateKind) []const u8 {
        return switch (self) {
            .claude => "◆",
            .codex => "◇",
            .shell => "○",
        };
    }
};

pub const Candidate = struct {
    /// 앱 전역 surface id. 주입 대상은 **이 값으로만** 지정된다.
    surface_id: u64,
    kind: CandidateKind,
    /// 화면 순서(0부터). **호출자가 준다** — 여기서 알 방법이 없다(pane 배치는 위층 것이다).
    ///
    /// **이것이 없으면 순서 계약을 잴 수 없다.** 처음에는 이 필드 없이 "안정 정렬이니 원래 순서가
    /// 유지된다" 로 두었는데, 그 성질은 **판정자가 원리적으로 못 잰다** — `sortUnstable` 로 바꾼
    /// 변이가 다섯·스물넷·512 개 입력에서 **전부 살아남았다**(pdqsort 가 이미 정렬된 입력을
    /// 알아채 순서를 지켰다). 잴 수 없는 것에 기대는 계약은 계약이 아니라 우연이다.
    order: u32 = 0,
    /// 셸 이름(`zsh` 등). 에이전트면 안 쓴다 — 이름은 `kind` 가 든다.
    shell_name: []const u8 = "",
    /// 워크스페이스 이름(에이전트) 또는 폴더(셸).
    where: []const u8 = "",
    /// 저장소 브랜치. 없으면 라벨에서 괄호를 뺀다.
    branch: ?[]const u8 = null,
    /// 그 Term 의 **화면 이름**(탭에 뜨는 그것). 같은 워크스페이스에 에이전트가 둘 이상 떠 있으면
    /// 폴더·브랜치가 같아 **줄이 구분되지 않는다** — 그때 이 값만이 둘을 가른다(사용자 요청
    /// 2026-08-31). 비어 있으면 라벨에서 화살표째 뺀다.
    pane: []const u8 = "",
};

/// 후보를 §5 순서로 **제자리 정렬**한다 — 에이전트 먼저, 그 안에서는 **화면 순서**(`order`).
///
/// **키가 둘이라 정렬의 안정성에 안 기댄다.** 그것이 이 설계의 요점이다 — 안정성은 판정자가
/// 원리적으로 못 재는 성질이라(위 `order` 주석의 실측), 못 재는 것에 기대는 대신 **순서를 값으로**
/// 받는다. 그러면 같은 입력이 언제나 같은 출력을 내고, 그 사실을 테스트가 잰다.
pub fn orderCandidates(items: []Candidate) void {
    std.mem.sort(Candidate, items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
            return a.order < b.order;
        }
    }.lessThan);
}

/// 한 행의 라벨을 쓴다 — `Claude — maru (feat/rich)` · `zsh — ~/work/maru`.
///
/// **표기를 여기서 새로 정하지 않는다**(§5) — 폴더·브랜치 표기는 사이드바 에이전트 목록이 이미
/// 쓰는 것과 같아야 한다. 같은 정보를 두 곳에서 다르게 부르면 사용자가 다른 것으로 읽는다.
pub fn writeLabel(out: []u8, c: Candidate) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    // **종류 기호가 맨 앞이다.** 눈이 줄을 훑을 때 먼저 닿는 자리이고, 폭이 고정이라 아래 글자들이
    // 같은 열에서 시작한다.
    writer.writeAll(c.kind.glyph()) catch return null;
    writer.writeAll(" ") catch return null;
    const head = c.kind.agentName() orelse c.shell_name;
    writer.writeAll(head) catch return null;
    if (c.where.len > 0) writer.print(" — {s}", .{c.where}) catch return null;
    if (c.branch) |b| if (b.len > 0) writer.print(" ({s})", .{b}) catch return null;
    // **pane 이름은 맨 뒤다.** 앞의 것들이 "어느 저장소인가" 를 답하고, 이것이 "그 안 어느 줄인가"
    // 를 답한다 — 좁은 것에서 넓은 것으로 읽히면 눈이 되돌아가야 한다.
    if (c.pane.len > 0) writer.print(" → {s}", .{c.pane}) catch return null;
    return writer.buffered();
}

/// 후보들을 **메뉴 줄로 편다** — 라벨과 id 를 **같은 걸음으로** 채운다.
///
/// **이 함수가 존재하는 이유는 그 1:1 을 잴 수 있게 하려는 것이다.** 처음에는 호출부에서 두 배열을
/// 각자 채웠고, 라벨이 자리에 안 들어가면 줄만 건너뛰고 목록에는 남겼다 — 그러면 그 뒤 줄이 전부
/// 한 칸씩 밀려 **고른 것과 다른 대상**으로 간다. 적대적 검증이 그것을 잡았는데, **판정자는 못
/// 잡았다**: 실제 픽스처에서는 라벨이 절대 안 넘쳐 두 수가 우연히 같았다. 잴 수 없는 계약은
/// 계약이 아니라 우연이라, 버퍼 크기를 **인자로** 받는 자리로 옮겨 작은 버퍼로 강제할 수 있게 했다.
///
/// `label_bufs[i]` 에 i 번째 **실린** 줄의 라벨을 쓴다(후보 인덱스가 아니다). 반환은 실린 줄 수.
pub fn writeRows(
    cands: []const Candidate,
    label_bufs: [][]u8,
    out_ids: []u64,
    out_labels: [][]const u8,
) usize {
    var n: usize = 0;
    for (cands) |c| {
        if (n >= label_bufs.len or n >= out_ids.len or n >= out_labels.len) break;
        // **자리에 안 들어가면 자르지 않고 뺀다** — 잘린 라벨은 다른 대상으로 읽힌다.
        const label = writeLabel(label_bufs[n], c) orelse continue;
        out_labels[n] = label;
        out_ids[n] = c.surface_id;
        n += 1;
    }
    return n;
}

const testing = std.testing;

test "reference collapses a single-line range and keeps the closed interval otherwise" {
    var buf: [256]u8 = undefined;
    const one = build(
        .{ .path = "docs/a.md", .start_line = 12, .end_line = 12, .text = "" },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expectEqualStrings("@docs/a.md:12", one);

    var buf2: [256]u8 = undefined;
    const many = build(
        .{ .path = "docs/a.md", .start_line = 12, .end_line = 20, .text = "" },
        .{ .bracketed_paste = true },
        &buf2,
    ).?;
    try testing.expectEqualStrings("@docs/a.md:12-20", many);
}

test "payload never ends with a newline" {
    // 안전 계약의 핵심이다 — 끝의 개행 하나가 곧 실행 트리거다. 인용 유무·절단 여부와 무관하게 성립해야 한다.
    var buf: [8192]u8 = undefined;
    const cases = [_]Selection{
        .{ .path = "a.md", .start_line = 1, .end_line = 1, .text = "" },
        .{ .path = "a.md", .start_line = 1, .end_line = 2, .text = "첫 줄\n둘째 줄" },
        .{ .path = "a.md", .start_line = 1, .end_line = 2, .text = "끝에 개행이 있는 선택\n" },
    };
    for (cases) |sel| {
        inline for (.{ true, false }) |bracketed| {
            const payload = build(sel, .{ .bracketed_paste = bracketed }, &buf).?;
            try testing.expect(payload.len > 0);
            try testing.expect(payload[payload.len - 1] != '\n');
        }
    }
}

test "quote is included only when the target keeps bracketed paste on" {
    var buf: [1024]u8 = undefined;
    const sel: Selection = .{ .path = "a.md", .start_line = 3, .end_line = 4, .text = "하나\n둘" };

    const with_quote = build(sel, .{ .bracketed_paste = true }, &buf).?;
    try testing.expectEqualStrings("@a.md:3-4\n> 하나\n> 둘", with_quote);

    // 꺼진 대상: 여러 줄을 흘리지 않고 참조 한 줄로 축약한다.
    var buf2: [1024]u8 = undefined;
    const reference_only = build(sel, .{ .bracketed_paste = false }, &buf2).?;
    try testing.expectEqualStrings("@a.md:3-4", reference_only);
    try testing.expect(std.mem.indexOfScalar(u8, reference_only, '\n') == null);
}

test "quote truncates at the line cap and says how much was dropped" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..max_quote_lines + 10) |i| {
        if (i > 0) try text.append(testing.allocator, '\n');
        var line_buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "line{d}", .{i});
        try text.appendSlice(testing.allocator, line);
    }
    var buf: [16 * 1024]u8 = undefined;
    const payload = build(
        .{ .path = "a.md", .start_line = 1, .end_line = @intCast(max_quote_lines + 10), .text = text.items },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expect(std.mem.indexOf(u8, payload, "…(10줄 생략)") != null);
    // 마지막 포함 줄은 상한 직전이고, 그 다음 줄은 들어가지 않았다.
    try testing.expect(std.mem.indexOf(u8, payload, "> line63") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "> line64") == null);
    try testing.expect(payload[payload.len - 1] != '\n');
}

test "quote truncates on the byte cap without splitting a line" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 한 줄이 1 KiB인 줄을 여러 개 — 줄 수 상한보다 바이트 상한이 먼저 걸린다.
    for (0..12) |i| {
        if (i > 0) try text.append(testing.allocator, '\n');
        try text.appendNTimes(testing.allocator, 'x', 1024);
    }
    var buf: [32 * 1024]u8 = undefined;
    const payload = build(
        .{ .path = "a.md", .start_line = 1, .end_line = 12, .text = text.items },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expect(std.mem.indexOf(u8, payload, "줄 생략)") != null);
    // 잘린 자리는 항상 줄 경계다 — 인용 줄은 전부 온전한 1 KiB다(UTF-8 중간 절단이 없다).
    var lines = std.mem.splitSequence(u8, payload, "\n> ");
    _ = lines.next(); // 참조 줄
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "…")) break;
        try testing.expectEqual(@as(usize, 1024), line.len);
    }
}

test "build fails closed when the buffer cannot hold the reference" {
    var tiny: [4]u8 = undefined;
    try testing.expect(build(
        .{ .path = "very/long/path.md", .start_line = 1, .end_line = 2, .text = "x" },
        .{ .bracketed_paste = true },
        &tiny,
    ) == null);
}

// ── NS3 테스트 ────────────────────────────────────────────────────────────────────────────────

test "경로는 루트 안일 때만 접힌다 — 이름이 겹치는 형제는 안 접힌다" {
    // 접두 비교만 하면 `/a/bc` 가 `/a/b` 안으로 보인다. 경계의 `/` 까지 봐야 한다.
    try testing.expectEqualStrings("src/main.zig", relativePath("/repo", "/repo/src/main.zig"));
    try testing.expectEqualStrings("src/main.zig", relativePath("/repo/", "/repo/src/main.zig")); // 끝 슬래시 허용
    try testing.expectEqualStrings("/repo-old/x.zig", relativePath("/repo", "/repo-old/x.zig")); // 형제
    try testing.expectEqualStrings("/other/x.zig", relativePath("/repo", "/other/x.zig"));
    // 루트 **자기 자신**은 접으면 빈 문자열이 되어 `@:12` 가 된다 — 그대로 둔다.
    try testing.expectEqualStrings("/repo", relativePath("/repo", "/repo"));
    // 루트를 모르면 손대지 않는다.
    try testing.expectEqualStrings("/repo/x.zig", relativePath("", "/repo/x.zig"));
}

test "후보는 에이전트가 먼저이고, 같은 종류끼리는 화면 순서를 지킨다" {
    // **입력을 일부러 흐트러 둔다.** 화면 순서대로 넣어 두면 아무것도 안 하는 구현도 통과한다 —
    // 실제로 그렇게 썼다가 `sortUnstable` 변이가 다섯·스물넷·512 개에서 전부 살아남았다.
    // 여기서는 `order` 가 입력 순서와 **반대**라, 종류별 tiebreak 을 빼면 곧바로 어긋난다.
    var items = [_]Candidate{
        .{ .surface_id = 10, .kind = .shell, .order = 5 },
        .{ .surface_id = 11, .kind = .codex, .order = 4 },
        .{ .surface_id = 12, .kind = .shell, .order = 3 },
        .{ .surface_id = 13, .kind = .claude, .order = 2 },
        .{ .surface_id = 14, .kind = .codex, .order = 1 },
        .{ .surface_id = 15, .kind = .claude, .order = 0 },
    };
    orderCandidates(&items);

    // claude(order 0,2) → codex(1,4) → shell(3,5).
    const got = [_]u64{
        items[0].surface_id, items[1].surface_id, items[2].surface_id,
        items[3].surface_id, items[4].surface_id, items[5].surface_id,
    };
    try testing.expectEqualSlices(u64, &.{ 15, 13, 14, 11, 12, 10 }, &got);
}

test "같은 입력은 언제나 같은 순서를 낸다 — 정렬의 안정성에 안 기댄다" {
    // 키가 (종류, 화면 순서) 둘이라 **전순서**다. 원소가 많고 같은 종류가 잔뜩이어도 답이 하나다.
    const n = 512;
    var a: [n]Candidate = undefined;
    var b: [n]Candidate = undefined;
    for (0..n) |i| {
        const c: Candidate = .{
            .surface_id = @intCast(1000 + i),
            .kind = switch (i % 3) {
                0 => .shell,
                1 => .codex,
                else => .claude,
            },
            .order = @intCast(n - i), // 입력 순서와 반대
        };
        a[i] = c;
        b[n - 1 - i] = c; // 같은 집합, 뒤집어 넣는다
    }
    orderCandidates(&a);
    orderCandidates(&b);
    for (a, b) |x, y| try testing.expectEqual(x.surface_id, y.surface_id);

    // 그리고 그 답이 §5 다 — 에이전트가 먼저, 그 안에서 화면 순서.
    var prev_kind: ?CandidateKind = null;
    var prev_order: u32 = 0;
    for (a) |c| {
        if (prev_kind) |pk| {
            try testing.expect(@intFromEnum(pk) <= @intFromEnum(c.kind));
            if (pk == c.kind) try testing.expect(c.order > prev_order);
        }
        prev_kind = c.kind;
        prev_order = c.order;
    }
}

test "라벨은 §5 모양이고, 없는 축은 자리도 안 만든다" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "◆ Claude — maru (feat/rich)",
        writeLabel(&buf, .{ .surface_id = 1, .kind = .claude, .where = "maru", .branch = "feat/rich" }).?,
    );
    // 브랜치가 없으면 **빈 괄호를 남기지 않는다** — `maru ()` 는 저장소가 아닌 것처럼 읽힌다.
    try testing.expectEqualStrings(
        "◇ Codex — maru",
        writeLabel(&buf, .{ .surface_id = 2, .kind = .codex, .where = "maru", .branch = null }).?,
    );
    try testing.expectEqualStrings(
        "◇ Codex — maru",
        writeLabel(&buf, .{ .surface_id = 2, .kind = .codex, .where = "maru", .branch = "" }).?,
    );
    // 셸은 이름을 호출자가 준다.
    try testing.expectEqualStrings(
        "○ zsh — ~/work/maru",
        writeLabel(&buf, .{ .surface_id = 3, .kind = .shell, .shell_name = "zsh", .where = "~/work/maru" }).?,
    );
}

test "종류 기호가 맨 앞에 서고 셋이 서로 다르다 — 셸도 자리를 차지한다" {
    // 사용자 요청(2026-08-31): 클로드인지 코덱스인지 한눈에 갈리게. 컨텍스트 메뉴가 문자열만
    // 받으므로 기호로 가른다(§5.1).
    //
    // **셸에도 기호를 주는 것이 계약이다.** 빈 칸을 두면 에이전트 줄과 셸 줄의 글자가 좌우로
    // 어긋나 목록이 들쭉날쭉해진다 — 켜짐 표시가 꺼진 줄에 같은 폭의 공백을 넣는 것과 같은 이유다.
    try testing.expect(!std.mem.eql(u8, CandidateKind.claude.glyph(), CandidateKind.codex.glyph()));
    try testing.expect(!std.mem.eql(u8, CandidateKind.codex.glyph(), CandidateKind.shell.glyph()));
    try testing.expect(CandidateKind.shell.glyph().len > 0);

    var buf: [128]u8 = undefined;
    const label = writeLabel(&buf, .{ .surface_id = 1, .kind = .claude, .where = "maru" }).?;
    try testing.expect(std.mem.startsWith(u8, label, CandidateKind.claude.glyph()));
}

test "pane 이름이 맨 뒤에 붙는다 — 같은 저장소의 두 에이전트를 가르는 유일한 값이다" {
    // 사용자 요청(2026-08-31): 워크스페이스와 pane 이름이 보이게. 폴더·브랜치가 같으면 그 두 줄은
    // 이것으로만 구분된다.
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "◆ Claude — maru5 (main) → 편집기 2",
        writeLabel(&buf, .{
            .surface_id = 1,
            .kind = .claude,
            .where = "maru5",
            .branch = "main",
            .pane = "편집기 2",
        }).?,
    );

    // **같은 저장소의 둘이 실제로 갈린다** — 이 판정이 없으면 pane 을 빼도 앞 판정자들이 통과한다.
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    const a = writeLabel(&buf_a, .{ .surface_id = 1, .kind = .claude, .where = "maru5", .branch = "main", .pane = "터미널 1" }).?;
    const b = writeLabel(&buf_b, .{ .surface_id = 2, .kind = .claude, .where = "maru5", .branch = "main", .pane = "터미널 2" }).?;
    try testing.expect(!std.mem.eql(u8, a, b));

    // 비어 있으면 **화살표째 뺀다** — `maru5 → ` 로 끝나는 줄은 잘린 것처럼 읽힌다.
    try testing.expectEqualStrings(
        "◆ Claude — maru5",
        writeLabel(&buf, .{ .surface_id = 1, .kind = .claude, .where = "maru5", .pane = "" }).?,
    );
}

test "라벨은 자리가 모자라면 잘라 내지 않고 접는다" {
    // 잘린 라벨은 **다른 대상**으로 읽힌다 — `Claude — maru-a` 와 `Claude — maru-b` 가 같아진다.
    var tiny: [8]u8 = undefined;
    try testing.expect(writeLabel(&tiny, .{ .surface_id = 1, .kind = .claude, .where = "maru", .branch = "main" }) == null);
}

test "줄과 id 는 같은 걸음으로 늘어난다 — 라벨이 빠져도 안 어긋난다" {
    // **작은 버퍼로 실패를 강제한다.** 실제 메뉴 버퍼(128B)로는 이 경로가 안 돌아 판정이 성립하지
    // 않는다 — 그것이 이 함수를 뺀 이유다.
    const cands = [_]Candidate{
        .{ .surface_id = 11, .kind = .claude, .where = "a", .order = 0 },
        .{ .surface_id = 22, .kind = .codex, .where = "이 라벨은 아주 길어서 작은 버퍼에 절대 안 들어간다", .order = 1 },
        .{ .surface_id = 33, .kind = .shell, .shell_name = "z", .where = "b", .order = 2 },
    };
    var storage: [3][24]u8 = undefined;
    var bufs: [3][]u8 = .{ &storage[0], &storage[1], &storage[2] };
    var ids: [3]u64 = undefined;
    var labels: [3][]const u8 = undefined;

    const n = writeRows(&cands, &bufs, &ids, &labels);
    try testing.expectEqual(@as(usize, 2), n); // 가운데는 자리에 안 들어가 빠졌다
    // **남은 둘의 라벨과 id 가 짝이다** — 빠진 것이 뒤 줄을 밀지 않았다.
    try testing.expectEqual(@as(u64, 11), ids[0]);
    try testing.expectEqual(@as(u64, 33), ids[1]);
    // 기호가 맨 앞이므로 이름은 그 뒤다(§5.1) — 상수로 조립해 기호가 바뀌어도 이 판정이 안 깨진다.
    try testing.expect(std.mem.startsWith(u8, labels[0], CandidateKind.claude.glyph()));
    try testing.expect(std.mem.indexOf(u8, labels[0], "Claude") != null);
    try testing.expect(std.mem.startsWith(u8, labels[1], CandidateKind.shell.glyph()));
    try testing.expect(std.mem.indexOf(u8, labels[1], "z") != null); // 이 픽스처의 셸 이름
}

test "출력 배열이 짧으면 거기서 멈춘다 — 넘겨 쓰지 않는다" {
    const cands = [_]Candidate{
        .{ .surface_id = 1, .kind = .claude, .where = "a", .order = 0 },
        .{ .surface_id = 2, .kind = .claude, .where = "b", .order = 1 },
    };
    var storage: [1][64]u8 = undefined;
    var bufs: [1][]u8 = .{&storage[0]};
    var ids: [1]u64 = undefined;
    var labels: [1][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), writeRows(&cands, &bufs, &ids, &labels));
    try testing.expectEqual(@as(u64, 1), ids[0]);
}
