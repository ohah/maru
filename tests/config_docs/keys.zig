const std = @import("std");
const maru = @import("maru");

// 이 테스트는 **config 문서 → 실제 스키마** 방향의 드리프트를 막는다.
//
// 반대 방향(스키마 → `configuration.md` 표)은 이미 `src/config/schema.zig`의 doc-drift 가드가 막는다: 스키마에 키를
// 추가하고 표 행을 깜빡하면 컴파일/테스트가 깨진다. 하지만 그 가드는 **문서가 존재하지 않는 키를 광고하는** 경우를
// 잡지 못했다. 실제로 `docs/agent-session.md`가 `notifications.agent-complete` 등 3키를 동작하는 설정처럼 기술했는데
// 로더는 그 키를 모르는 상태였고(구현은 알림 PR 예정), 사용자가 config에 적었다가 조용히 무시되는 일이 있었다
// (앱 로그에만 `config line N: 알 수 없는 key — 무시`). 그 종류의 드리프트를 여기서 막는다.
//
// 두 게이트를 둔다.
//
//   A. `docs/configuration.md` 키 표의 모든 행은 **실제 config 키**여야 한다. 이 문서는 사용자와의 공개 계약이라
//      "적혀 있으면 동작한다"가 성립해야 한다.
//   B. 다른 설계 문서가 config 키를 **선언 형식**으로 소개하면(리스트 항목 + 백틱 키 + 같은 줄에 기본값 표기),
//      그 키는 실재하거나 **미구현임이 같은 줄에 표시**돼야 한다. 설계 문서가 앞으로 만들 키를 적는 것은 doc-first
//      관행상 정당하므로 금지하지 않고, 독자가 현재 키와 구분할 수 있게 표시만 강제한다.
//
// 판정 형식을 좁게 잡은 이유는 오탐 때문이다. 문서에는 config 키와 같은 모양의 토큰이 많다 — 파일명(`theme.zig`),
// control-plane RPC(`session.capture`), JS API(`window.opener`). 실측해 보면 단순 토큰 스캔은 49건 중 46건이 오탐이었다.
// "리스트 항목 + 기본값 표기"로 좁히면 config 키 선언만 남는다(실측 오탐 0).

/// 이 키를 loader가 실제로 받아들이는가 — **loader 자신이 SSOT다**.
///
/// 처음엔 `configKeyValues`(직렬화 dump)를 기준으로 삼았는데, 그건 "파일로 되쓸 때의 canonical 키"라 **입력 전용
/// 키가 빠진다**: `theme.preset`/`chrome.preset`(적용되면 여러 키로 확장)과 `window.padding-x/y`(padding-left/right·
/// top/bottom으로 확장)는 파싱은 되지만 직렬화되지 않는다. 그 기준으로는 정상 문서 4행이 오탐으로 걸렸다.
/// 그래서 판정을 "한 줄을 실제로 파싱시켜 unknown-key 진단이 나오는지"로 바꿨다 — 사용자가 config 파일에 그 줄을
/// 적었을 때 벌어지는 일과 정확히 같은 경로를 태우므로 정의상 어긋날 수 없다.
///
/// 값은 의도적으로 아무거나 준다. 타입이 안 맞으면 "bool 값은 …" 같은 **다른** 진단이 나오는데, 그건 키가
/// 알려졌다는 증거이므로 통과다. 우리가 보는 것은 오직 unknown-key 진단 하나다.
fn keyIsKnown(allocator: std.mem.Allocator, key: []const u8) !bool {
    const line = try std.fmt.allocPrint(allocator, "{s} = 1", .{key});
    defer allocator.free(line);
    var parsed = try maru.config.loader.parse(allocator, line);
    defer parsed.deinit();
    for (parsed.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "알 수 없는 key") != null) return false;
    }
    return true;
}

/// config 네임스페이스(첫 점 앞) 집합. 설계 문서에는 config가 아닌 dotted 토큰이 많아(`session.capture` RPC 등)
/// 게이트 B는 네임스페이스로 1차 필터한다. 네임스페이스 자체는 직렬화 dump에서 뽑아도 충분하다 — 입력 전용
/// 키들도 네임스페이스는 공유한다(theme·chrome·window).
fn configNamespaces(arena: std.mem.Allocator) !std.StringHashMapUnmanaged(void) {
    const cfg: maru.config.theme.Config = .{};
    const kvs = try maru.config.configKeyValues(arena, cfg);
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (kvs) |kv| {
        const dot = std.mem.indexOfScalar(u8, kv.key, '.') orelse continue;
        try set.put(arena, kv.key[0..dot], {});
    }
    return set;
}

/// 문서가 동적 키를 placeholder로 적는 형태 — 실제 키 이름이 런타임에 정해지므로 집합 대조에서 제외한다.
/// `env.<KEY>`는 사용자가 정하는 환경변수 이름, `keybind`는 점이 없어 애초에 dotted 패턴에 안 걸린다.
fn isPlaceholderKey(key: []const u8) bool {
    return std.mem.indexOfScalar(u8, key, '<') != null;
}

/// `| \`key\` |` 형태의 표 행에서 키를 뽑는다(없으면 null). 표 셀 경계로 앵커해 산문 속 백틱 토큰을 잡지 않는다
/// (schema.zig `docHasKeyRow`와 같은 규율 — 그쪽은 존재 확인, 이쪽은 추출).
fn tableRowKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "| `")) return null;
    const rest = trimmed["| `".len..];
    const close = std.mem.indexOfScalar(u8, rest, '`') orelse return null;
    const key = rest[0..close];
    // 닫는 백틱 뒤가 셀 경계여야 키 셀이다(`| \`a\` b |` 같은 산문 셀 제외).
    const after = std.mem.trimStart(u8, rest[close + 1 ..], " ");
    if (!std.mem.startsWith(u8, after, "|")) return null;
    if (std.mem.indexOfScalar(u8, key, '.') == null) return null; // 점 없는 키(keybind)는 특수 — 표 대조 밖
    return key;
}

/// 설계 문서의 **config 키 선언** 형태에서 키를 뽑는다(없으면 null).
/// 형식: 리스트 항목(`- `) + 백틱 dotted 키 + 같은 줄에 기본값 표기(`기본`).
/// 기본값 표기를 요구하는 이유는 오탐 제거다 — control-plane RPC 목록(`- \`session.capture\` chunk 상태머신은 …`)처럼
/// 같은 리스트 형태지만 설정이 아닌 줄을 걸러낸다.
fn declarationKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "- `")) return null;
    const rest = trimmed["- `".len..];
    const close = std.mem.indexOfScalar(u8, rest, '`') orelse return null;
    const key = rest[0..close];
    if (std.mem.indexOfScalar(u8, key, '.') == null) return null;
    if (std.mem.indexOf(u8, rest[close..], "기본") == null) return null; // 기본값 표기가 없으면 설정 선언이 아니다
    return key;
}

/// 미구현임을 독자에게 알리는 표시가 줄에 있는가. 설계 문서가 앞으로 만들 키를 적는 것은 정당하므로,
/// 금지하는 대신 이 표시를 요구한다.
fn marksUnimplemented(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "미구현") != null;
}

/// 키의 네임스페이스가 config 네임스페이스인지(게이트 B의 1차 필터).
fn namespaceIsConfig(namespaces: *const std.StringHashMapUnmanaged(void), key: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, key, '.') orelse return false;
    return namespaces.contains(key[0..dot]);
}

test "config 문서 정합성 A: configuration.md 표의 모든 키가 실재한다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/configuration.md", arena, .limited(4 * 1024 * 1024));

    var missing: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const key = tableRowKey(line) orelse continue;
        if (isPlaceholderKey(key)) continue;
        if (try keyIsKnown(std.testing.allocator, key)) continue;
        std.debug.print(
            "docs/configuration.md:{d}: 표에 있으나 loader가 모르는 config 키 '{s}' — 키를 구현하거나 표 행을 지워라\n",
            .{ line_no, key },
        );
        missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "config 문서 정합성 B: 설계 문서의 config 키 선언은 실재하거나 미구현 표시가 있다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var namespaces = try configNamespaces(arena);

    // docs/*.md를 **전부** 훑는다 — 대상 문서를 명시 목록으로 두면 새 문서를 빠뜨려 게이트가 조용히 통과한다
    // (이번 드리프트가 바로 "게이트가 보지 않는 문서"에서 났다). boundary 테스트가 구현 디렉터리를 재귀적으로
    // 훑는 것과 같은 규율.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "docs", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, arena);
    defer walker.deinit();

    var violations: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        // configuration.md는 게이트 A가 표 전체를 이미 대조한다(같은 파일을 두 규칙으로 이중 판정하지 않는다).
        if (std.mem.eql(u8, entry.path, "configuration.md")) continue;

        const text = try dir.readFileAlloc(std.testing.io, entry.path, arena, .limited(4 * 1024 * 1024));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |line| {
            line_no += 1;
            const key = declarationKey(line) orelse continue;
            if (isPlaceholderKey(key)) continue;
            if (!namespaceIsConfig(&namespaces, key)) continue; // config 네임스페이스가 아니면 설정 선언이 아니다
            if (try keyIsKnown(std.testing.allocator, key)) continue;
            if (marksUnimplemented(line)) continue; // 계획 키는 표시가 있으면 허용
            std.debug.print(
                "docs/{s}:{d}: loader가 모르는 config 키 '{s}'를 설정처럼 소개한다 — 구현하거나 같은 줄에 '미구현' 표시를 달아라\n",
                .{ entry.path, line_no, key },
            );
            violations += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

// 판정 함수 자체의 단위 테스트 — 게이트가 무엇을 잡고 무엇을 통과시키는지 고정한다. 이게 없으면 정규식 성격의
// 형식 판정이 조용히 느슨해져(예: 기본값 표기 요구가 사라져) 게이트가 통과만 하는 껍데기가 될 수 있다.
test "표 행/선언 형식 판정: 실제 문서 문장으로 경계를 고정" {
    // 게이트 A: 키 셀만 뽑는다.
    try std.testing.expectEqualStrings("font.family", tableRowKey("| `font.family` | 문자열 | `JetBrains Mono` | 설명 |").?);
    try std.testing.expect(tableRowKey("| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능 |") == null); // 점 없음
    try std.testing.expect(tableRowKey("일반 산문 `font.size` 언급") == null);
    try std.testing.expect(tableRowKey("| `a.b` 뒤에 산문이 이어짐 |") == null); // 셀 경계 아님

    // 게이트 B: 기본값 표기가 있는 리스트 선언만.
    try std.testing.expectEqualStrings(
        "notifications.agent-complete",
        declarationKey("- `notifications.agent-complete` (`true|false`, 기본 `true`) — 완료 알림 on/off.").?,
    );
    try std.testing.expect(declarationKey("- `session.capture` chunk 상태머신은 L2에 있으나 미배선이다.") == null); // 기본값 표기 없음
    try std.testing.expect(declarationKey("- 일반 항목") == null);

    // 미구현 표시.
    try std.testing.expect(marksUnimplemented("- `x.y` (bool, 기본 `true`) — 설명 **(미구현 — 4단계)**"));
    try std.testing.expect(!marksUnimplemented("- `x.y` (bool, 기본 `true`) — 설명"));

    // placeholder는 대조 밖.
    try std.testing.expect(isPlaceholderKey("env.<KEY>"));
    try std.testing.expect(!isPlaceholderKey("font.size"));
}

// ── 경로 구분자 정규화 (호스트 이식) ─────────────────────────────────────────────────────────────
// `std.Io.Dir.Walker`의 `entry.path`는 **호스트 native 구분자**를 쓴다 — Windows에서는 `platform\macos\x.zig`.
// 이 파일의 스캐너들은 그 경로를 `"platform/macos/x.zig"` 같은 **`/` 리터럴과 비교**하므로, 그대로 두면 제외
// 목록과 매칭이 조용히 전부 빗나간다(실측: 제외됐어야 할 파일이 집계에 섞여 boundary 카운트가 부풀었다 —
// 컴파일도 통과하고 macOS CI도 초록인 채로 Windows에서만 틀렸다). 그래서 walker를 감싸 경로를 `/`로 정규화한다.
// POSIX 호스트에서는 native 구분자가 이미 `/`라 `next`가 std walker를 그대로 통과시킨다(무동작·무비용).
const PosixWalker = struct {
    inner: std.Io.Dir.Walker,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn next(self: *PosixWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
        var entry = (try self.inner.next(io)) orelse return null;
        if (std.fs.path.sep == '/') return entry;
        // 잘라내면 "제외 목록에 없는 경로"로 조용히 바뀌어 게이트가 거짓 초록이 된다 — 시끄럽게 실패시킨다.
        if (entry.path.len >= self.path_buf.len) return error.NameTooLong;
        for (entry.path, 0..) |byte, i|
            self.path_buf[i] = if (byte == std.fs.path.sep) '/' else byte;
        self.path_buf[entry.path.len] = 0;
        entry.path = self.path_buf[0..entry.path.len :0];
        return entry;
    }

    fn deinit(self: *PosixWalker) void {
        self.inner.deinit();
    }
};

fn posixWalk(dir: std.Io.Dir, allocator: std.mem.Allocator) !PosixWalker {
    return .{ .inner = try dir.walk(allocator) };
}
