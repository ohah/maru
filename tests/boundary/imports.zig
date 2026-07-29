const std = @import("std");

test "session host neutral cleanup leaf has no owner reverse dependencies" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_owner_cleanup.zig",
    );
    defer allocator.free(source);
    const forbidden = [_][]const u8{
        "client_external_pump",
        "external_rx_intent",
        "external_inbox_ledger",
        "external_event_materialization",
        "client.zig",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(source, needle),
        );
}

test "d2b3b classified intent mechanics stay private and test-only at the pump boundary" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const owner_path = "external_rx_intent.zig";
    const pump_path = "client_external_pump.zig";
    var owner_seen = false;
    var pump_seen = false;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const scratch_refs = countOccurrences(source, "ExternalRxIntentScratch");
        if (std.mem.eql(u8, entry.path, owner_path)) {
            owner_seen = true;
            try std.testing.expect(scratch_refs != 0);
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "client_external_pump.zig"),
            );
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "external_inbox_ledger.zig"),
            );
        } else {
            try std.testing.expectEqual(@as(usize, 0), scratch_refs);
        }
        if (std.mem.eql(u8, entry.path, pump_path)) {
            pump_seen = true;
            try std.testing.expectEqual(
                @as(usize, 1),
                countOccurrences(source, "external_rx_intent.moveFrame("),
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                countOccurrences(source, "external_rx_intent.allocate("),
            );
            try std.testing.expect(
                countOccurrences(
                    source,
                    "fn moveIntentFrameForTest(",
                ) == 1 and
                    countOccurrences(
                        source,
                        "fn createIntentScratchForTest(",
                    ) == 1,
            );
            const move_start = std.mem.indexOf(
                u8,
                source,
                "fn moveIntentFrameForTest(",
            ) orelse return error.TestUnexpectedResult;
            const move_end = std.mem.indexOfPos(
                u8,
                source,
                move_start,
                "fn activateSyntheticLiveOwnersForTest(",
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(
                u8,
                source[move_start..move_end],
                "if (comptime !builtin.is_test) unreachable;",
            ) != null);
            const create_start = std.mem.indexOf(
                u8,
                source,
                "fn createIntentScratchForTest(",
            ) orelse return error.TestUnexpectedResult;
            const create_end = std.mem.indexOfPos(
                u8,
                source,
                create_start,
                "fn liveScreenOrPartialPending(",
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(
                u8,
                source[create_start..create_end],
                "if (comptime !builtin.is_test) unreachable;",
            ) != null);
        }
    }
    try std.testing.expect(owner_seen);
    try std.testing.expect(pump_seen);

    const barrel = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(barrel);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(barrel, "external_rx_intent"),
    );
}

test "session host owner projection capability stays in its reviewed mechanics file" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    const protected = [_][]const u8{
        "BorrowedMetadataView",
        "OwnerEventView",
        "OwnerEventProjector",
        "projectOwnerEventInternal",
    };
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ))
            continue;
        const is_barrel =
            std.mem.eql(u8, entry.path, "platform/macos/session_host.zig");
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        var tokenizer = std.zig.Tokenizer.init(source);
        var protected_counts = [_]usize{0} ** protected.len;
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .identifier and token.tag != .string_literal) continue;
            const spelling = source[token.loc.start..token.loc.end];
            for (protected, 0..) |name, index| {
                if (std.mem.indexOf(u8, spelling, name) != null) {
                    if (!is_barrel) return error.TestUnexpectedResult;
                    protected_counts[index] += 1;
                }
            }
        }
        if (is_barrel)
            for (protected_counts) |count|
                try std.testing.expectEqual(@as(usize, 1), count);
    }
}

// 이 테스트는 docs/implementation-plan.md의 facade import 경계를 강제한다.
// Maru 아키텍처 전체는 TerminalCore가 PTY/platform/renderer를 모른다는 전제 위에
// 서 있다(clean-room VT 코어를 교체 가능하고 headless로 테스트 가능하게 유지하기
// 위해서다). "리뷰에서 조심한다"는 규칙만으로는 이를 보장할 수 없으므로, 한 레이어가
// 금지된 레이어를 import하는 순간 빌드를 실패시킨다.
//
// 금지에는 두 종류가 있다(implementation-plan.md "1단계 boundary checker 최소 요구사항"의 초기 금지 규칙).
//   - 레이어 전체 금지: 공개 barrel("layer.zig")과 구현 디렉터리("layer/...") 모두 금지.
//     예) terminal -> pty/platform/renderer, renderer -> pty, plugin -> pty.
//   - private 구현만 금지: 구현 디렉터리("layer/...")만 금지하고 공개 barrel은 허용.
//     예) pty/plugin -> terminal. pty는 terminal.Size 같은 공개 타입은 써도 되지만
//     terminal/core.zig 같은 내부 구현은 만지면 안 된다.
//
// 새 파일이 추가될 때마다 이 테스트 파일을 고치는 방식은 쉽게 빠뜨린다.
// 그래서 facade barrel 파일은 명시하되, 구현 폴더는 재귀적으로 훑어 새
// `*.zig` 파일도 자동으로 경계 검사를 받게 한다.

const Forbidden = struct {
    layer: []const u8,
    // true이면 구현 디렉터리("layer/...")만 금지하고 공개 barrel("layer.zig")은 허용한다.
    private_only: bool = false,
};

const Rule = struct {
    layer: []const u8,
    barrel: []const u8,
    implementation_dir: []const u8,
    forbidden: []const Forbidden,
};

const rules = [_]Rule{
    .{
        // terminal(L1 VT 코어)의 facade 계약(docs/facade-contracts.md TerminalCore "몰라야 하는 것"): PTY/platform
        // API·renderer/GPU뿐 아니라 **workspace/tab/split·plugin runtime**도 몰라야 한다. workspace/tab/split은 3차
        // 추출로 session(L2)에 있으므로 session을, plugin runtime은 plugin을 각각 금지해 "L1은 위 레이어를 모른다"를
        // 강제한다(과거엔 pty/platform/renderer만 막아 terminal→session/plugin이 뚫려 있었다 — 문서화됐으나 미강제).
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "renderer" },
            .{ .layer = "session" }, // workspace/tab/split 모델이 사는 곳 — L1이 L2를 import하면 위상 역전
            .{ .layer = "plugin" }, // plugin runtime을 몰라야 한다(facade-contracts.md:28)
        },
    },
    .{
        // renderer(L1 중립 frame 계약)는 위상의 바닥이다 — terminal snapshot을 DrawList·Glyph*Frame으로 바꾸는
        // 백엔드-무관 도메인. OS 백엔드(platform·pty)도, 위 레이어(session·chrome)도, 앱 런타임(app)도 import하면
        // 안 된다(아래로만 의존 — terminal·color·std만 허용). WebGPU/다른 OS 백엔드가 같은 frame 계약을 재사용
        // 하려면 L1이 OS·상위에 안 묶여야 한다(docs/layering-and-portability.md §2·§8, renderer-strategy.md).
        .layer = "renderer",
        .barrel = "src/renderer.zig",
        .implementation_dir = "src/renderer",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "session" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // chrome(L3 디자인 시스템)은 플랫폼 중립이어야 한다 — semantic ChromeDraw만 뱉고 session을 **props로만**
        // 읽는다(raw *Pane/*Split·session 모듈을 import하지 않는다). OS/렌더 백엔드(platform·pty), 코어 내부
        // (terminal·renderer), 세션·앱 런타임(session·app)을 import하면 props-only seam과 이식성이 깨지므로 빌드
        // 에서 막는다(docs/layering-and-portability.md §2·§8). 허용: std, color(top-level), 자기 하위 모듈.
        // session 금지는 C1~C3 이주에서 chrome 컴포넌트가 session을 직접 만지지 않고 props만 쓰게 강제한다.
        .layer = "chrome",
        .barrel = "src/chrome.zig",
        .implementation_dir = "src/chrome",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "terminal" },
            .{ .layer = "renderer" },
            .{ .layer = "session" },
            .{ .layer = "app" },
        },
    },
    .{
        // session(L2 세션 코어)은 OS-중립이어야 한다 — 순수 모델·연산·입력 수학만. platform(L4 OS 어댑터)과
        // pty(OS 프로세스)를 직접 import하면 이식성이 깨지므로 막는다(docs/layering-and-portability.md §2·§8).
        // renderer(L1)는 의존 방향이 L2→L1이라 허용한다(금지 안 함). terminal(중립 입력 타입)도 허용. chrome(L3)은
        // 위 레이어라 금지한다(L2가 L3를 import하면 위상 역전).
        //
        // session→app 금지(D3, 3차 추출 완료): 세션 모델이 쓰던 app의 중립 타입(Surface·split_tree·workspace·
        // window·core_command)을 3차(D1·D2)로 session으로 옮겨 session→app 직접 의존이 0이 됐다. 이제 app을
        // 통째 금지해 의존 소거를 가드로 고정한다(과거엔 "app 경유 중립 타입"이 컨벤션이었으나 이제 강제 —
        // docs/app-layer-decomposition.md). app.zig는 pty·platform을 transitive로 끌어오므로, app 금지가 곧 그
        // 차단이기도 하다(직접 @import만 보는 한계는 동일하나, session→app=0이면 transitive 누수 경로가 닫힌다).
        .layer = "session",
        .barrel = "src/session.zig",
        .implementation_dir = "src/session",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // plugin(future Wasm 경계)의 facade 계약(docs/facade-contracts.md:290-291): plugin은 domain event·action
        // facade로만 상호작용하고, TerminalCore private storage·PTY handle·**renderer resource**를 직접 받지 않는다.
        // 그래서 pty(전체)·terminal(private 구현)에 더해 renderer(전체 — 프레임/atlas/GPU resource)를 금지한다
        // (문서화됐으나 pty/terminal만 막혀 plugin→renderer가 뚫려 있었다). plugin은 현재 registry stub이라 위반 0.
        .layer = "plugin",
        .barrel = "src/plugin.zig",
        .implementation_dir = "src/plugin",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "terminal", .private_only = true },
            .{ .layer = "renderer" }, // renderer resource(프레임·atlas·GPU)를 직접 받지 않는다(facade-contracts.md:291)
        },
    },
    .{
        .layer = "pty",
        .barrel = "src/pty.zig",
        .implementation_dir = "src/pty",
        .forbidden = &.{.{ .layer = "terminal", .private_only = true }},
    },
};

test "facade layers do not import forbidden layers" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;

    for (rules) |rule| {
        try checkFile(allocator, rule, rule.barrel, &violations);
        try checkDirectory(allocator, rule, rule.implementation_dir, &violations);
    }

    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "provider cleanup module remains absent" {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, "src/platform/macos/agent_hook_cleanup.zig", .{}),
    );
}

test "session host unchecked adoption leaves stay behind the aggregate permit boundary" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const Leaf = struct {
        prefix: []const u8,
        suffix: []const u8,
        owner_file: []const u8,
        aggregate_calls: usize = 1,
    };
    const leaves = [_]Leaf{
        .{
            .prefix = "commitExternalAdoption",
            .suffix = "TakeUnchecked(",
            .owner_file = "client.zig",
        },
        .{
            .prefix = "commitInto",
            .suffix = "Unchecked(",
            .owner_file = "client_external_adoption.zig",
        },
        .{
            .prefix = "commitOwnerMetadata",
            .suffix = "TakeUnchecked(",
            .owner_file = "external_event_materialization.zig",
        },
        .{
            .prefix = "commitExternalRecoveryDiscard",
            .suffix = "Unchecked(",
            .owner_file = "client.zig",
        },
    };
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    for (leaves) |leaf| {
        const needle = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ leaf.prefix, leaf.suffix },
        );
        defer allocator.free(needle);
        var aggregate_calls: usize = 0;
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            const count = countOccurrences(source, needle);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += count;
            } else if (!std.mem.eql(u8, entry.path, leaf.owner_file) and
                count != 0)
            {
                std.debug.print(
                    "unchecked adoption leaf boundary violation: {s} contains {s}\n",
                    .{ path, needle },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(leaf.aggregate_calls, aggregate_calls);
    }
}

test "session host aggregate screen cleanup has one owner and one caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const seams = [_][]const u8{
        "moveIntoAggregateCleanupSnapshot",
        "abandonAggregateCleanup",
        "prepareAggregateCleanup",
        "finishAggregateCleanup",
    };
    for (seams) |seam| {
        const definition_needle = try std.fmt.allocPrint(
            allocator,
            "pub fn {s}(",
            .{seam},
        );
        defer allocator.free(definition_needle);
        const call_needle = try std.fmt.allocPrint(
            allocator,
            ".{s}(",
            .{seam},
        );
        defer allocator.free(call_needle);
        var owner_definitions: usize = 0;
        var aggregate_calls: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            if (std.mem.eql(u8, entry.path, "client_external_adoption.zig")) {
                owner_definitions += countOccurrences(source, definition_needle);
            } else if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += countOccurrences(source, call_needle);
            } else if (countOccurrences(source, call_needle) != 0 or
                countOccurrences(source, definition_needle) != 0)
            {
                std.debug.print(
                    "aggregate screen cleanup boundary violation: {s}\n",
                    .{path},
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), owner_definitions);
        try std.testing.expectEqual(@as(usize, 1), aggregate_calls);
    }

    const Symbol = struct {
        name: []const u8,
        owner_files: []const []const u8,
        aggregate_references: usize,
    };
    const symbols = [_]Symbol{
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_files = &.{"external_inbox_ledger.zig"},
            .aggregate_references = 1,
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_files = &.{"external_inbox_ledger.zig"},
            .aggregate_references = 1,
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_files = &.{
                "client_external_adoption.zig",
                "external_event_materialization.zig",
            },
            .aggregate_references = 2,
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_files = &.{"client.zig"},
            .aggregate_references = 1,
        },
    };
    for (symbols) |symbol| {
        var aggregate_references: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            var owner_file = false;
            for (symbol.owner_files) |allowed|
                owner_file = owner_file or std.mem.eql(u8, entry.path, allowed);
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            // Count the identifier itself, not only direct `symbol(` calls. This also rejects
            // function-value aliases and facade re-exports of ReleaseFast unchecked authority.
            const references = countOccurrences(source, symbol.name);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_references += references;
            } else if (!owner_file and references != 0) {
                std.debug.print(
                    "frozen teardown symbol escaped owner boundary: {s} contains {s}\n",
                    .{ path, symbol.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(
            symbol.aggregate_references,
            aggregate_references,
        );
    }
}

test "session host aggregate screen cleanup has no public shortcut" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_adoption.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub fn deinitForAggregate("),
    );
}

test "session host screen retirement unchecked commit has one product caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const symbol = "commitScreenRetirementUnchecked";
    var product_references: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const references = countOccurrences(source, symbol);
        if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
            product_references += references;
        } else if (!std.mem.eql(u8, entry.path, "external_inbox_ledger.zig") and
            references != 0)
        {
            std.debug.print(
                "screen retirement unchecked authority escaped owner boundary: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), product_references);
}

test "session host barrel does not re-export unchecked owner modules" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub const external_event_materialization"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub const client = if (builtin.os.tag == .macos)\n    @import"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "pub const Client = client_impl.Client;"),
    );
}

test "session host unchecked teardown authority cannot escape anywhere in src" {
    const allocator = std.testing.allocator;
    const Symbol = struct {
        name: []const u8,
        owner_suffixes: []const []const u8,
        pump_references: usize,
    };
    const symbols = [_]Symbol{
        .{
            .name = "commitExternalAdoptionTakeUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitExternalRecoveryDiscardUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitScreenRetirementUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitIntoUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client_external_adoption.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataTakeUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/client_external_adoption.zig",
                "platform/macos/session_host/external_event_materialization.zig",
            },
            .pump_references = 2,
        },
        .{
            .name = "consumePreparedLiveCommitUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitLiveBatchAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitMovedIntentPayloadTransferUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataCleanupOnlyUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataPublishFirstUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataReplaceNewerUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFrozenCleanupToDescriptorUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitLiveMetadataAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitNeutralRetirementUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitIntentAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "consumePreparedIntentCommitUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveCommittedLiveBatchAbortCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveCommittedIntentAbortCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveFrozenUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_inbox_ledger.zig",
                "platform/macos/session_host/external_rx_intent.zig",
            },
            .pump_references = 4,
        },
        .{
            .name = "freezeOwnedSliceUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_event_materialization.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "freezeOwnedSliceAlignedUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
            },
            .pump_references = 2,
        },
        .{
            .name = "freezeOwnedSliceFromSealUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_event_materialization.zig",
                "platform/macos/session_host/external_rx_intent.zig",
            },
            .pump_references = 0,
        },
    };
    var unchecked_declarations: usize = 0;
    var inventory_dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer inventory_dir.close(std.testing.io);
    var inventory_walker = try inventory_dir.walk(allocator);
    defer inventory_walker.deinit();
    while (try inventory_walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "pub fn ")) continue;
            const rest = trimmed["pub fn ".len..];
            const end = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            const name = rest[0..end];
            if (!std.mem.endsWith(u8, name, "Unchecked")) continue;
            unchecked_declarations += 1;
            var known = false;
            for (symbols) |symbol| known = known or std.mem.eql(u8, name, symbol.name);
            if (!known) {
                std.debug.print("unchecked authority missing from global inventory: {s}\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 27), unchecked_declarations);
    for (symbols) |symbol| {
        var pump_references: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            const references = countOccurrences(source, symbol.name);
            if (std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_pump.zig",
            )) {
                pump_references += references;
                continue;
            }
            var owner = false;
            for (symbol.owner_suffixes) |suffix|
                owner = owner or std.mem.eql(u8, entry.path, suffix);
            if (!owner and references != 0) {
                std.debug.print(
                    "unchecked session-host authority escaped into {s}: {s}\n",
                    .{ path, symbol.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(symbol.pump_references, pump_references);
    }
}

test "session host frozen teardown commits have one aggregate product caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const Seam = struct {
        name: []const u8,
        owner_file: []const u8,
        aggregate_call: []const u8,
    };
    const seams = [_]Seam{
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_file = "external_inbox_ledger.zig",
            .aggregate_call = ".inbox_ledger.commitFreezeAllForOwnerTeardownUnchecked(",
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_file = "external_inbox_ledger.zig",
            .aggregate_call = ".inbox_ledger.restoreFinishedOwnerTeardownUnchecked(",
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_file = "client_external_adoption.zig",
            .aggregate_call = ".committed_screen.commitFrozenCleanupUnchecked(",
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_file = "external_event_materialization.zig",
            .aggregate_call = ".owner_metadata.commitFrozenCleanupUnchecked(",
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_file = "client.zig",
            .aggregate_call = "client_mod.commitExternalAdoptionTakeFrozenCleanupUnchecked(",
        },
    };
    for (seams) |seam| {
        const definition_needle = try std.fmt.allocPrint(
            allocator,
            "pub fn {s}(",
            .{seam.name},
        );
        defer allocator.free(definition_needle);
        var definitions: usize = 0;
        var aggregate_calls: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            if (std.mem.eql(u8, entry.path, seam.owner_file)) {
                definitions += countOccurrences(source, definition_needle);
            }
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += countOccurrences(source, seam.aggregate_call);
            } else if (countOccurrences(source, seam.aggregate_call) != 0) {
                std.debug.print(
                    "frozen teardown boundary violation: {s} exposes {s}\n",
                    .{ path, seam.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), aggregate_calls);
    }
}

test "session host deferred seed retirement has one ledger owner and one adoption caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const definition_needle = "pub fn commitSeedsDeferredRetirement(";
    const call_needle = ".commitSeedsDeferredRetirement(";
    var definitions: usize = 0;
    var ledger_calls: usize = 0;
    var adoption_calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            definitions += countOccurrences(source, definition_needle);
            ledger_calls += countOccurrences(source, call_needle);
        } else if (std.mem.eql(
            u8,
            entry.path,
            "client_external_adoption.zig",
        )) {
            adoption_calls += countOccurrences(source, call_needle);
        } else if (countOccurrences(source, definition_needle) != 0 or
            countOccurrences(source, call_needle) != 0)
        {
            std.debug.print(
                "deferred seed retirement boundary violation: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), ledger_calls);
    try std.testing.expectEqual(@as(usize, 1), adoption_calls);
}

test "session host live batch unchecked mutation stays behind two ledger entrypoints" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const definition_needle = "fn commitPreparedLiveBatchUnchecked(";
    const call_needle = "self.commitPreparedLiveBatchUnchecked(";
    var definitions: usize = 0;
    var calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            definitions += countOccurrences(source, definition_needle);
            calls += countOccurrences(source, call_needle);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "commitPreparedLegacyMergeUnchecked",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "commitPreparedLegacyReleaseUnchecked",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "pub const FrozenPayloadCleanup",
            ) == null);
            const cleanup_start = std.mem.indexOf(
                u8,
                source,
                "const FrozenPayloadCleanup = struct {",
            ) orelse return error.TestUnexpectedResult;
            const cleanup_end = std.mem.indexOfPos(
                u8,
                source,
                cleanup_start,
                "\n};",
            ) orelse return error.TestUnexpectedResult;
            const cleanup_type = source[cleanup_start..cleanup_end];
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                "fn ",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                ".free(",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                ".deinit(",
            ) == null);
        } else if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "ledger.mergeInto(",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "ledger.release(",
            ) == null);
            if (countOccurrences(source, definition_needle) != 0 or
                countOccurrences(source, call_needle) != 0)
                return error.TestUnexpectedResult;
        } else if (countOccurrences(source, definition_needle) != 0 or
            countOccurrences(source, call_needle) != 0)
        {
            std.debug.print(
                "live batch unchecked mutation boundary violation: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), definitions);
    // The legacy checked API and the sealed-permit unchecked consume each converge
    // on the same mutation leaf. No caller outside this owner module may bypass
    // either entrypoint.
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "session host live commit permit keeps checked consume ledger-private" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const checked_needle = "consumePreparedLiveCommitChecked(";
    const unchecked_needle = "consumePreparedLiveCommitUnchecked(";
    var checked_outside_ledger: usize = 0;
    var unchecked_definitions: usize = 0;
    var unchecked_pump_calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            unchecked_definitions += countOccurrences(
                source,
                "pub fn consumePreparedLiveCommitUnchecked(",
            );
        } else {
            checked_outside_ledger += countOccurrences(source, checked_needle);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig"))
                unchecked_pump_calls += countOccurrences(source, unchecked_needle)
            else
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countOccurrences(source, unchecked_needle),
                );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), checked_outside_ledger);
    try std.testing.expectEqual(@as(usize, 1), unchecked_definitions);
    // d2b3c opens exactly one product callsite. Both removing it and bypassing the aggregate with
    // another caller violate the single-writer boundary.
    try std.testing.expectEqual(@as(usize, 1), unchecked_pump_calls);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        count += 1;
        offset = found + needle.len;
    }
    return count;
}

test "session host RX unchecked append has one validating aggregate caller" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_mode.zig",
    );
    defer allocator.free(source);
    // One private definition plus one call from `commitPreparedAdmit`. Tests and future d2 callers
    // must use the validating aggregate entry instead of the unchecked ownership suffix.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, "commitAdmitUnchecked("),
    );
}

test "session host external RX DTO and classifier preserve neutral ownership boundaries" {
    const allocator = std.testing.allocator;
    const types_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_rx_types.zig",
    );
    defer allocator.free(types_source);
    const mode_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_mode.zig",
    );
    defer allocator.free(mode_source);
    const ledger_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_inbox_ledger.zig",
    );
    defer allocator.free(ledger_source);
    const demux_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_rx_demux.zig",
    );
    defer allocator.free(demux_source);
    const barrel_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(barrel_source);

    try std.testing.expect(!std.mem.containsAtLeast(u8, types_source, 1, "client_external_mode.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, types_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mode_source, 1, "external_rx_types.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, mode_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, ledger_source, 1, "client_external_mode.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, ".alloc("));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "std.json"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "client_external_pump.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "external_owner_seal.zig"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(mode_source, "result.pair_seal = externalRxFrameDigest(&result);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(demux_source, "testing.sealExternalRxFrame(&result);"),
    );
    try std.testing.expect(std.mem.containsAtLeast(u8, barrel_source, 1, "external_rx_types.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(
        u8,
        barrel_source,
        1,
        "pub const external_rx_demux",
    ));
}

test "session host client pump policy imports only std" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_pump.zig",
    );
    defer allocator.free(source);

    var imports: usize = 0;
    var import_builtins: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import");
                if (saw_import) import_builtins += 1;
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
            },
            .string_literal => {
                if (saw_import and saw_paren) {
                    imports += 1;
                    const literal = source[token.loc.start..token.loc.end];
                    try std.testing.expect(
                        std.mem.eql(u8, literal, "\"std\"") or
                            std.mem.eql(
                                u8,
                                literal,
                                "\"request_id_state.zig\"",
                            ),
                    );
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                if (saw_import and token.tag != .doc_comment) {
                    saw_import = false;
                    saw_paren = false;
                }
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 2), import_builtins);
    try std.testing.expectEqual(@as(usize, 2), imports);
    try std.testing.expect(!containsForbiddenExternalBuiltin(source));
    try std.testing.expect(!containsForbiddenPumpToken(source));
    try std.testing.expect(!containsForbiddenStdChild(source));

    const forbidden_fixture: [:0]const u8 =
        \\const std = @import("std");
        \\const Leaked = std.mem.Allocator;
    ;
    try std.testing.expect(containsForbiddenPumpToken(forbidden_fixture));
    const forbidden_heap: [:0]const u8 =
        \\const std = @import("std");
        \\const allocator = std.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_heap));
    const forbidden_os: [:0]const u8 =
        \\const std = @import("std");
        \\const os = std.os;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_os));
    const forbidden_fs: [:0]const u8 =
        \\const std = @import("std");
        \\const Handle = std.fs.File.Handle;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fs));
    const forbidden_c_import: [:0]const u8 =
        \\const c = @cImport({ @cInclude("unistd.h"); });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_c_import));
    const forbidden_import_alias: [:0]const u8 =
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_import_alias));
    const forbidden_bare_alias: [:0]const u8 =
        \\const std = @import("std");
        \\const system = std;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_bare_alias));
    const forbidden_std_field: [:0]const u8 =
        \\const std = @import("std");
        \\const heap = @field(std, "heap");
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_std_field));
    const forbidden_extern: [:0]const u8 =
        \\extern fn close(fd: i32) c_int;
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern));
    const forbidden_extern_builtin: [:0]const u8 =
        \\const errno = @extern(*i32, .{ .name = "errno" });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern_builtin));
    const forbidden_fake_std: [:0]const u8 =
        \\const std = 1;
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fake_std));
}

test "session host runtime event wire stays below framing and product ownership" {
    const allocator = std.testing.allocator;
    const event_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_wire.zig",
    );
    defer allocator.free(event_source);
    const event_types_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_types.zig",
    );
    defer allocator.free(event_types_source);
    const event_reducer_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_reducer.zig",
    );
    defer allocator.free(event_reducer_source);
    const metadata_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_metadata_wire.zig",
    );
    defer allocator.free(metadata_source);

    const forbidden = [_][]const u8{
        "framing.zig",
        "client.zig",
        "client_pump.zig",
        "client_external_pump.zig",
        "external_inbox_ledger.zig",
    };
    for (forbidden) |name| {
        try std.testing.expect(!joinedStringLiteralsContain(event_source, name));
        try std.testing.expect(!joinedStringLiteralsContain(event_types_source, name));
        try std.testing.expect(!joinedStringLiteralsContain(event_reducer_source, name));
    }
    // Owning metadata must consume the bounded Scanner preflight. Reintroducing a heap DOM parser
    // here would make malformed/resource precedence depend on allocator state again.
    try std.testing.expect(std.mem.indexOf(
        u8,
        metadata_source,
        "parseFromSlice",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metadata_source,
        "std.json.Value",
    ) == null);

    const client_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client_source);
    const runtime_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime_source);
    const attachment_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_attachment.zig",
    );
    defer allocator.free(attachment_source);
    const external_attach_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_attach.zig",
    );
    defer allocator.free(external_attach_source);

    try std.testing.expect(std.mem.indexOf(u8, client_source, "resize_wire.parseEvent") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "resize_wire.parseEvent") == null);
    try std.testing.expect(std.mem.indexOf(u8, attachment_source, "decodeRevoked") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, runtime_source, "classifyAndMaterializeEvent(") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        runtime_source,
        "extractU64Field(resp, \"\\\"metadata_revision\\\":\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_source, "EnvelopeKind") == null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_source, "decodeSeed") == null);
    try std.testing.expect(std.mem.indexOf(u8, attachment_source, "pub fn decodeAttach(") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, attachment_source, "pub fn decodeAttachForCapabilities(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, attachment_source, "pub fn decodeFrozenV1ControllerAttach(") == null,
    );

    const attach_start = std.mem.indexOf(
        u8,
        external_attach_source,
        "fn attachSnapshot",
    ) orelse return error.TestUnexpectedResult;
    const attach_tail = external_attach_source[attach_start..];
    const attach_end = std.mem.indexOf(u8, attach_tail, "\nfn ") orelse attach_tail.len;
    const attach_body = attach_tail[0..attach_end];
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "decodeAttachResponse(") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "responseErrorExit(") == null);
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "decodeWireError(") == null);

    const gui_attach_start = std.mem.indexOf(
        u8,
        runtime_source,
        "fn attachAndAssemble",
    ) orelse return error.TestUnexpectedResult;
    const gui_attach_tail = runtime_source[gui_attach_start..];
    const gui_attach_end = std.mem.indexOf(u8, gui_attach_tail, "\n    fn ") orelse
        gui_attach_tail.len;
    const gui_attach_body = gui_attach_tail[0..gui_attach_end];
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "decodeAttachResponse(") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "decodeWireError(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "attachFailureCode(") == null,
    );
}

test "session host source transcript encoder imports only std" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_source_transcript.zig",
    );
    defer allocator.free(source);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@import("),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, source, "@import(\"std\")") != null,
    );
    inline for (.{
        "client.zig",
        "protocol.zig",
        "framing.zig",
        "runtime_event_wire.zig",
        "runtime_event_types.zig",
        "runtime_event_reducer.zig",
    }) |forbidden| {
        try std.testing.expect(!joinedStringLiteralsContain(source, forbidden));
    }
}

test "validated metadata token construction and materialization stay in classifier product path" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var classifier_field_count: usize = 0;
    var validated_type_count: usize = 0;
    var private_materializer_count: usize = 0;
    var product_classifier_definition_count: usize = 0;
    var product_classifier_call_count: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);

        const is_types = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/runtime_event_types.zig",
        );
        const is_metadata_wire = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/runtime_metadata_wire.zig",
        );
        const is_remote_runtime = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/remote_runtime.zig",
        );
        const is_client = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const is_external_event_materialization = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_event_materialization.zig",
        );

        const field_refs = std.mem.count(u8, source, "classifier_preflight");
        if (field_refs != 0) {
            try std.testing.expect(is_types);
            classifier_field_count += field_refs;
        }
        const type_refs = std.mem.count(u8, source, "ValidatedMetadataView");
        if (type_refs != 0) {
            try std.testing.expect(is_types or is_metadata_wire);
            validated_type_count += type_refs;
        }
        if (std.mem.indexOf(u8, source, "decodeMetadataEvent") != null)
            try std.testing.expect(is_metadata_wire);

        const exact_event_materializer_refs = std.mem.count(
            u8,
            source,
            "materializeExactEventMetadata",
        );
        if (exact_event_materializer_refs != 0)
            try std.testing.expect(
                is_metadata_wire or is_client or
                    is_external_event_materialization,
            );

        inline for (.{
            "sealOwnedMetadataDto",
            "validateOwnedMetadataDescriptor",
            "validateOwnedMetadataSeal",
        }) |owned_seal_api| {
            if (std.mem.indexOf(u8, source, owned_seal_api) != null)
                try std.testing.expect(
                    is_metadata_wire or is_external_event_materialization,
                );
        }
        if (std.mem.indexOf(
            u8,
            source,
            "ownedMetadataSemanticEqlEvent",
        ) != null)
            try std.testing.expect(is_metadata_wire or is_client);

        const private_materializer_refs = std.mem.count(
            u8,
            source,
            "materializeValidatedEvent",
        );
        if (private_materializer_refs != 0) {
            try std.testing.expect(is_metadata_wire);
            private_materializer_count += private_materializer_refs;
        }
        const product_classifier_refs = std.mem.count(
            u8,
            source,
            "classifyAndMaterializeEvent",
        );
        if (product_classifier_refs != 0) {
            if (is_metadata_wire) {
                product_classifier_definition_count += product_classifier_refs;
            } else if (is_remote_runtime) {
                product_classifier_call_count += product_classifier_refs;
            } else return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), classifier_field_count);
    try std.testing.expectEqual(@as(usize, 5), validated_type_count);
    try std.testing.expectEqual(@as(usize, 2), private_materializer_count);
    try std.testing.expectEqual(@as(usize, 1), product_classifier_definition_count);
    try std.testing.expectEqual(@as(usize, 1), product_classifier_call_count);
}

test "d2b3a live owner substrate stays private and has no product writer" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var owner_module_count: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const mentions_owner =
            std.mem.indexOf(u8, source, "LivePartialBatch") != null or
            std.mem.indexOf(u8, source, "LiveScreenBacklog") != null or
            std.mem.indexOf(u8, source, "PendingResponseOwner") != null;
        if (!mentions_owner) continue;
        try std.testing.expect(std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ));
        owner_module_count += 1;
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const LivePartialBatch") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const LiveScreenBacklog") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const PendingResponseOwner") == null,
        );
        inline for (.{
            "pub fn publishLivePartial",
            "pub fn publishLiveScreen",
            "pub fn publishPendingResponse",
            "pub fn takePendingResponse",
        }) |forbidden_writer|
            try std.testing.expect(
                std.mem.indexOf(u8, source, forbidden_writer) == null,
            );
        const activation_start = std.mem.indexOf(
            u8,
            source,
            "fn activateSyntheticLiveOwnersForTest(",
        ) orelse return error.TestUnexpectedResult;
        const activation_tail = source[activation_start..];
        const activation_end_rel = std.mem.indexOfPos(
            u8,
            activation_tail,
            3,
            "\nfn ",
        ) orelse return error.TestUnexpectedResult;
        const activation_source = activation_tail[0..activation_end_rel];
        const fixture_start = activation_start + activation_end_rel + 1;
        const fixture_tail = source[fixture_start..];
        const fixture_end_rel = std.mem.indexOfPos(
            u8,
            fixture_tail,
            3,
            "\nfn ",
        ) orelse return error.TestUnexpectedResult;
        const fixture_source = fixture_tail[0..fixture_end_rel];
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                activation_source,
                "if (comptime !builtin.is_test) unreachable;",
            ) != null,
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, source, "activateSyntheticLiveOwnersForTest"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                fixture_source,
                "activateSyntheticLiveOwnersForTest(",
            ),
        );
        // A private writer or direct field assignment still has to create these active tags.
        // Keeping each exact activation assignment unique to the guarded synthetic fixture makes
        // product-writer zero a source boundary instead of a public-name convention.
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.live_partial = .{ .assembling"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.live_partial = .{ .assembling",
            ),
        );
        // d2b3c's test-only aggregate writer publishes through the exact presealed destination
        // address instead of naming the persistent field a second time. Keep that fixed writer
        // unique; d2b3d is the gate that may add the product traversal callsite.
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "target.* = .{ .assembling"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "storage.live_screen = .{\n        .saved_self_addr",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.live_screen = .{\n        .saved_self_addr",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.pending_response = .{ .pending"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "target.* = .{ .pending"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.pending_response = .{ .pending",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "fn commitResponseDestinationPlanUnchecked(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "commitResponseDestinationPlanUnchecked(\n            storage,\n            @ptrFromInt(write.prepared_backing_addr),",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "self.live_partial = .{ .assembling"),
        );
        const aggregate_commit_start = std.mem.indexOf(
            u8,
            source,
            "    fn commitRxAggregate(",
        ) orelse return error.TestUnexpectedResult;
        const aggregate_commit_tail = source[aggregate_commit_start..];
        const aggregate_commit_end = std.mem.indexOfPos(
            u8,
            aggregate_commit_tail,
            4,
            "\n    fn ",
        ) orelse return error.TestUnexpectedResult;
        const aggregate_commit_source =
            aggregate_commit_tail[0..aggregate_commit_end];
        const first_test = std.mem.indexOf(u8, source, "\ntest \"") orelse
            return error.TestUnexpectedResult;
        const product_source = source[0..first_test];
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, product_source, "commitRxAggregate("),
        );
        // The declaration is the only pre-test occurrence. Test-only product exercises may grow
        // with the hostile matrix without weakening the no-product-caller boundary.
        try std.testing.expect(
            std.mem.count(u8, source, "commitRxAggregate(") >= 2,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                aggregate_commit_source,
                "commitScreenDestinationPlanUnchecked(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                aggregate_commit_source,
                "commitDestinationWriteUnchecked(self, aggregate, write)",
            ),
        );
        // The suffix consumes the presealed writer kind; it must not reinterpret the ledger
        // disposition after the aggregate has crossed the commit barrier.
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                source,
                "aggregate.dispositions[write.mutation_index]",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                aggregate_commit_source,
                "commitEventScalarDestinationsUnchecked",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                product_source,
                "storage.live_screen.len += 1",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "self.pending_response = .{ .pending"),
        );
        // Count every canonical raw LHS, not only active literals. `zig fmt --check` makes these
        // spellings stable; a helper-return assignment such as `self.live_partial = next` or an
        // extra private writer changes the total even when it avoids the active literal.
        try std.testing.expectEqual(
            @as(usize, 6),
            std.mem.count(u8, source, "self.live_partial ="),
        );
        try std.testing.expectEqual(
            @as(usize, 5),
            std.mem.count(u8, source, "self.live_screen ="),
        );
        try std.testing.expectEqual(
            @as(usize, 6),
            std.mem.count(u8, source, "self.pending_response ="),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_partial == .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.pending_response == .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.live_partial = .{"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.live_screen ="),
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, product_source, "storage.pending_response ="),
        );
        try std.testing.expectEqual(
            @as(usize, 4),
            std.mem.count(u8, source, "self.live_partial = .terminal"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_partial = .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 4),
            std.mem.count(
                u8,
                source,
                "self.live_screen = .{ .lifecycle = .cleaned_tombstone }",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_screen = .{}"),
        );
        try std.testing.expectEqual(
            @as(usize, 4),
            std.mem.count(u8, source, "self.pending_response = .terminal"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.pending_response = .none"),
        );
        // Whole-owner pointer aliases could otherwise hide `owner.* = active`; keep every
        // address-taking spelling bounded as well. Nested payload borrows are not whole owners.
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "&self.live_partial"),
        );
        try std.testing.expectEqual(
            @as(usize, 3),
            std.mem.count(u8, source, "&self.live_screen"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "&self.pending_response"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "&storage.live_partial"),
        );
        try std.testing.expectEqual(
            @as(usize, 8),
            std.mem.count(u8, source, "&storage.live_screen"),
        );
        try std.testing.expectEqual(
            // The product writer is the only pre-test whole-owner address borrow. Hostile
            // fixtures may inspect a local storage owner without opening another product writer.
            @as(usize, 1),
            std.mem.count(u8, product_source, "&storage.pending_response"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"live_partial\")"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"live_screen\")"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"pending_response\")"),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), owner_module_count);
}

fn containsForbiddenExternalBuiltin(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .keyword_extern, .keyword_asm => return true,
            .builtin => {
                const builtin_name = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, builtin_name, "@cImport") or
                    std.mem.eql(u8, builtin_name, "@cInclude") or
                    std.mem.eql(u8, builtin_name, "@embedFile") or
                    std.mem.eql(u8, builtin_name, "@extern"))
                    return true;
            },
            else => {},
        }
    }
}

test "session host external pump facade callsites stay in the final owner boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const allowed = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_attach_evidence.zig",
        );
        if (allowed) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expect(!containsFacadeAccess(source));
    }

    const forbidden_identifier: [:0]const u8 =
        \\const Leak = module.ExternalPumpFacade;
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_identifier));
    const forbidden_field: [:0]const u8 =
        \\const Leak = @field(module, "ExternalPumpFacade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_field));
    const forbidden_import: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/client_external_pump.zig");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_import));
    const forbidden_computed: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/" ++ "client_" ++ "external_" ++ "pump." ++ "zig");
        \\const Leak = @field(pump, "External" ++ "Pump" ++ "Facade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_computed));
}

test "session host stable pump storage and Client transfer stay in mechanics boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const mechanics_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        );
        const framing_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/framing.zig",
        );
        const rx_parser_transaction_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_mode.zig",
        );
        const storage_type_allowed = mechanics_file or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        );
        const transfer_allowed = mechanics_file or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expect(!containsRestrictedName(source, "transferToExternalPump"));
        if (containsRestrictedName(source, "initFromAttachPartsInPlace")) {
            try std.testing.expect(mechanics_file or std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/external_attach_evidence.zig",
            ));
        }
        if (!mechanics_file) {
            try std.testing.expect(!containsRestrictedName(source, "cleanup_seed"));
            try std.testing.expect(!containsRestrictedName(source, "cleanup_seed_seal"));
        }
        if (!framing_file and !rx_parser_transaction_file) {
            try std.testing.expect(!containsRestrictedName(source, "cleanup_replacement"));
            try std.testing.expect(!containsRestrictedName(source, "normalize_cleanup_allocator"));
        }
        if (mechanics_file) continue;
        if (!storage_type_allowed)
            try std.testing.expect(!containsRestrictedName(source, "ExternalPumpStorage"));
        if (!mechanics_file) {
            try std.testing.expect(!containsRestrictedName(source, "owned_client"));
            try std.testing.expect(!containsRestrictedName(source, "inbox_ledger"));
            // The paired suffix's only seed owner until c3c. Raw access outside mechanics could
            // free the seed behind the cleanup mirror's back.
            try std.testing.expect(!containsRestrictedName(source, "owned_evidence"));
        }
        if (!transfer_allowed) {
            try std.testing.expect(!containsRestrictedName(source, "prepareExternalPumpTransfer"));
            try std.testing.expect(!containsRestrictedName(source, "commitExternalPumpTransfer"));
            // All three stages are gated, not just the two that move ownership: calling `finish`
            // out of order panics instead of returning a typed error.
            try std.testing.expect(!containsRestrictedName(source, "finishExternalPumpTransfer"));
            try std.testing.expect(!containsRestrictedName(
                source,
                "PreparedExternalOwnerRangeProof",
            ));
            try std.testing.expect(!containsRestrictedName(
                source,
                "prepareExternalOwnerRangeProof",
            ));
        }
        if (!framing_file and !transfer_allowed and !rx_parser_transaction_file) {
            // The staged parser swap is a mechanics-only leaf for the same reason: its misuse paths
            // are `@panic`, so the compiler cannot keep a new caller honest. `client.zig` owns the
            // three transfer stages that drive it.
            try std.testing.expect(!containsRestrictedName(source, "prepareNormalizeExact"));
            try std.testing.expect(!containsRestrictedName(source, "commitPreparedNormalizeExact"));
            try std.testing.expect(!containsRestrictedName(source, "rebindPreparedNormalizeExact"));
        }
    }

    const forbidden_storage: [:0]const u8 =
        \\const storage: ExternalPumpStorage = .{};
        \\const raw = &storage.inbox_ledger;
    ;
    try std.testing.expect(containsExactIdentifier(forbidden_storage, "ExternalPumpStorage"));
    try std.testing.expect(containsExactIdentifier(forbidden_storage, "inbox_ledger"));
    const forbidden_computed_storage: [:0]const u8 =
        \\const raw = &@field(storage, "inbox_" ++ "ledger");
        \\const copied = @field(module, "External" ++ "PumpStorage");
    ;
    try std.testing.expect(containsRestrictedName(
        forbidden_computed_storage,
        "inbox_ledger",
    ));
    try std.testing.expect(containsRestrictedName(
        forbidden_computed_storage,
        "ExternalPumpStorage",
    ));
    const forbidden_transfer: [:0]const u8 =
        \\try client.transferToExternalPump(&slot, cap);
        \\const transfer = @field(client, "transfer" ++ "ToExternalPump");
    ;
    try std.testing.expect(containsRestrictedName(
        forbidden_transfer,
        "transferToExternalPump",
    ));
}

test "session host external adoption import direction and mechanics stay closed" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const is_client = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const is_adoption = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_adoption.zig",
        );
        const is_pump = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);

        if (!is_pump)
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "client_external_adoption.zig",
            ));
        if (is_client or is_adoption)
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "client_external_pump.zig",
            ));
        if (!is_adoption and !is_pump)
            try std.testing.expect(!containsRestrictedName(source, "PreparedScreenBacklog"));
        if (!is_client and !is_adoption)
            try std.testing.expect(!containsRestrictedName(source, "PreparedClientDisarm"));
    }
}

test "session host external source decision stays outside pump and owning materialization" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_source_decision.zig",
    );
    defer allocator.free(source);

    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "client_external_pump.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "client_external_adoption.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "runtime_metadata_wire.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "external_inbox_ledger.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "std.mem.Allocator",
    ));
}

test "session host prepared metadata mechanics stay inside their final-address owner" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const is_owner = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_event_materialization.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (!is_owner)
            try std.testing.expect(!containsRestrictedName(
                source,
                "PreparedOwnedMetadata",
            ));
    }
}

fn containsExactIdentifier(source: [:0]const u8, expected: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .identifier => if (std.mem.eql(
                u8,
                source[token.loc.start..token.loc.end],
                expected,
            )) return true,
            else => {},
        }
    }
}

fn containsRestrictedName(source: [:0]const u8, expected: []const u8) bool {
    return containsExactIdentifier(source, expected) or
        joinedStringLiteralsEqual(source, expected);
}

fn joinedStringLiteralsEqual(source: [:0]const u8, expected: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var joined: [128]u8 = undefined;
    var joined_len: usize = 0;
    var have_literal = false;
    var expect_literal = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .string_literal => {
                if (!expect_literal) joined_len = 0;
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                if (joined_len + literal.len > joined.len) {
                    joined_len = 0;
                    have_literal = false;
                    expect_literal = false;
                    continue;
                }
                @memcpy(joined[joined_len..][0..literal.len], literal);
                joined_len += literal.len;
                have_literal = true;
                expect_literal = false;
            },
            .plus_plus => {
                if (have_literal and !expect_literal) {
                    expect_literal = true;
                } else {
                    joined_len = 0;
                    have_literal = false;
                    expect_literal = false;
                }
            },
            .eof => return have_literal and !expect_literal and
                std.mem.eql(u8, joined[0..joined_len], expected),
            else => {
                if (have_literal and !expect_literal and
                    std.mem.eql(u8, joined[0..joined_len], expected))
                    return true;
                joined_len = 0;
                have_literal = false;
                expect_literal = false;
            },
        }
    }
}

fn containsForbiddenStdChild(source: [:0]const u8) bool {
    if (!hasExactCanonicalStdImport(source)) return true;
    const allowed = [_][]const u8{ "math", "meta", "testing" };
    var tokenizer = std.zig.Tokenizer.init(source);
    const AfterStd = enum { none, declaration, selector };
    var after_std: AfterStd = .none;
    var expect_child = false;
    var previous_const = false;
    var canonical_bindings: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (after_std != .none) {
            switch (after_std) {
                .declaration => {
                    if (token.tag != .equal) return true;
                    canonical_bindings += 1;
                },
                .selector => {
                    if (token.tag != .period) return true;
                    expect_child = true;
                },
                .none => unreachable,
            }
            after_std = .none;
            previous_const = false;
            continue;
        }
        if (expect_child) {
            if (token.tag != .identifier) return true;
            const child = source[token.loc.start..token.loc.end];
            var accepted = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, child, name)) {
                    accepted = true;
                    break;
                }
            }
            if (!accepted) return true;
            expect_child = false;
            previous_const = false;
            continue;
        }
        switch (token.tag) {
            .eof => return canonical_bindings != 1,
            .keyword_const => {
                previous_const = true;
            },
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, identifier, "std")) {
                    after_std = if (previous_const) .declaration else .selector;
                }
                previous_const = false;
            },
            else => {
                previous_const = false;
            },
        }
    }
}

fn hasExactCanonicalStdImport(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var state: u4 = 0;
    var matches: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return matches == 1 and state == 0;
        const text = source[token.loc.start..token.loc.end];
        const matched = switch (state) {
            0 => token.tag == .keyword_const,
            1 => token.tag == .identifier and std.mem.eql(u8, text, "std"),
            2 => token.tag == .equal,
            3 => token.tag == .builtin and std.mem.eql(u8, text, "@import"),
            4 => token.tag == .l_paren,
            5 => token.tag == .string_literal and std.mem.eql(u8, text, "\"std\""),
            6 => token.tag == .r_paren,
            7 => token.tag == .semicolon,
            else => unreachable,
        };
        if (matched) {
            state += 1;
            if (state == 8) {
                matches += 1;
                state = 0;
            }
        } else {
            state = if (token.tag == .keyword_const) 1 else 0;
        }
    }
}

fn containsForbiddenPumpToken(source: [:0]const u8) bool {
    const forbidden = [_][]const u8{
        "posix",
        "c",
        "json",
        "mem",
        "Allocator",
        "FrameParser",
        "ExternalInboxLedger",
    };
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                for (forbidden) |name| {
                    if (std.mem.eql(u8, identifier, name)) return true;
                }
            },
            else => {},
        }
    }
}

fn containsFacadeAccess(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_client_external = false;
    var saw_pump_file = false;
    var saw_external_pump = false;
    var saw_facade = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return (saw_client_external and saw_pump_file) or
                (saw_external_pump and saw_facade) or
                joinedStringLiteralsContain(source, "client_external_pump.zig") or
                joinedStringLiteralsContain(source, "ExternalPumpFacade"),
            .identifier => {
                if (std.mem.eql(
                    u8,
                    source[token.loc.start..token.loc.end],
                    "ExternalPumpFacade",
                )) return true;
            },
            .string_literal => {
                const literal = source[token.loc.start..token.loc.end];
                saw_client_external = saw_client_external or
                    std.mem.indexOf(u8, literal, "client_external_") != null;
                saw_pump_file = saw_pump_file or
                    std.mem.indexOf(u8, literal, "pump.zig") != null;
                saw_external_pump = saw_external_pump or
                    std.mem.indexOf(u8, literal, "ExternalPump") != null;
                saw_facade = saw_facade or
                    std.mem.indexOf(u8, literal, "Facade") != null;
            },
            else => {},
        }
    }
}

fn joinedStringLiteralsContain(source: [:0]const u8, needle: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var matched: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .string_literal => {
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                for (literal) |byte| {
                    if (byte == needle[matched]) {
                        matched += 1;
                        if (matched == needle.len) return true;
                    } else {
                        matched = if (byte == needle[0]) 1 else 0;
                    }
                }
            },
            else => {},
        }
    }
}

fn checkDirectory(
    allocator: std.mem.Allocator,
    rule: Rule,
    dir_path: []const u8,
    violations: *usize,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        try checkFile(allocator, rule, path, violations);
    }
}

// .zig 소스를 sentinel 종료 버퍼([:0]u8 — std.zig.Tokenizer가 요구)로 읽는다. 호출자가 free한다.
// 읽기 상한 4MB: core.zig가 256KB를 넘어, 이어서 app_session.zig가 1MB→2MB를 넘어 StreamTooLong이 났던 이력이라
// 넉넉히 둔다(정상적 코드 성장 — 한도는 의미 제약이 아니라 읽기 버퍼 크기일 뿐이다).
fn readZigFileZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("boundary scan could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

fn checkFile(
    allocator: std.mem.Allocator,
    rule: Rule,
    path: []const u8,
    violations: *usize,
) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanImports(text_z, rule, path, violations);
}

// @import 경로를 훑어 금지 레이어 import를 센다. 단순 부분문자열 스캔이 아니라
// std.zig.Tokenizer로 토큰화해 실제 `@import` `(` string_literal 시퀀스만 import로 본다.
// 그래야 (1) `@import`와 `(` 사이에 주석·개행·공백이 있어도 잡고(부분문자열 스캐너는
// `@import // 주석\n(...)`을 놓쳤다), (2) 주석이나 문자열 리터럴 안에 적힌
// `@import("../x")`를 오탐하지 않는다. 토크나이저는 일반 주석을 토큰으로 내보내지 않고,
// doc 주석·일반/multiline 문자열은 builtin이 아닌 단일 토큰으로 내보내므로 둘 다 자연히 처리된다.
fn scanImports(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, true);
}

fn scanImportsQuiet(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, false);
}

fn scanImportsWithDiagnostics(
    text: [:0]const u8,
    rule: Rule,
    path: []const u8,
    violations: *usize,
    emit_diagnostics: bool,
) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    // `@import` / `(` / string_literal 가 연속으로 나올 때만 실제 import로 본다.
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import");
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
                saw_import = false;
            },
            .string_literal => {
                if (saw_paren) {
                    // string_literal 토큰은 따옴표를 포함한다("..."). import 경로는
                    // 이스케이프 없는 단순 경로라 양끝 따옴표만 벗긴다.
                    const raw = text[token.loc.start..token.loc.end];
                    const import_path = raw[1 .. raw.len - 1];
                    for (rule.forbidden) |forbidden| {
                        if (importTraversesLayer(import_path, forbidden)) {
                            // 실제 파일을 검사할 때만 진단을 출력한다. 아래 unit test는 일부러
                            // 금지 import fixture를 넣기 때문에, 거기서 같은 메시지를 찍으면
                            // `mise run check`가 성공해도 실패처럼 보여 triage를 방해한다.
                            if (emit_diagnostics) {
                                std.debug.print(
                                    "boundary violation: {s} ({s} layer) imports forbidden layer '{s}' via \"{s}\"\n",
                                    .{ path, rule.layer, forbidden.layer, import_path },
                                );
                            }
                            violations.* += 1;
                        }
                    }
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                saw_import = false;
                saw_paren = false;
            },
        }
    }
}

fn importTraversesLayer(import_path: []const u8, forbidden: Forbidden) bool {
    // import 경로는 "../pty/types.zig"나 "core.zig" 같은 상대 경로다.
    var it = std.mem.splitScalar(u8, import_path, '/');
    while (it.next()) |seg| {
        // 구현 디렉터리로 진입: segment가 정확히 레이어 이름("pty", "terminal" ...).
        if (std.mem.eql(u8, seg, forbidden.layer)) return true;
        // 공개 barrel("layer.zig"): 레이어 전체 금지일 때만 위반으로 본다.
        if (!forbidden.private_only and
            std.mem.endsWith(u8, seg, ".zig") and
            std.mem.eql(u8, seg[0 .. seg.len - 4], forbidden.layer)) return true;
    }
    return false;
}

test "importTraversesLayer distinguishes barrel from private implementation" {
    // 레이어 전체 금지: barrel과 구현 디렉터리 둘 다 잡는다.
    try std.testing.expect(importTraversesLayer("../pty/types.zig", .{ .layer = "pty" }));
    try std.testing.expect(importTraversesLayer("../pty.zig", .{ .layer = "pty" }));
    // private 구현만 금지: 구현 디렉터리는 잡고 공개 barrel은 허용한다.
    try std.testing.expect(importTraversesLayer("../terminal/core.zig", .{ .layer = "terminal", .private_only = true }));
    try std.testing.expect(!importTraversesLayer("../terminal.zig", .{ .layer = "terminal", .private_only = true }));
    // 무관한 import는 잡지 않는다.
    try std.testing.expect(!importTraversesLayer("core.zig", .{ .layer = "pty" }));
    try std.testing.expect(!importTraversesLayer("std", .{ .layer = "renderer" }));
}

test "boundary rules enforce documented facade contracts (terminal↛session/plugin, plugin↛renderer)" {
    // 이 테스트가 증명하는 것: facade-contracts.md의 "몰라야 하는 것" 경계 중 예전엔 미강제였던 항목을 rules가
    // 실제로 잡는다는 것 — 규칙 추가가 no-op(영원히 안 걸림)이 아니라 위반 fixture에서 정확히 발화한다. 실제 소스는
    // 위반이 0이라(top의 "facade layers..." 테스트가 전 파일 스캔) 여기선 fixture 문자열로 규칙 자체의 발화를 고정한다.
    const findRule = struct {
        fn run(layer: []const u8) Rule {
            for (rules) |r| {
                if (std.mem.eql(u8, r.layer, layer)) return r;
            }
            unreachable;
        }
    }.run;

    // terminal → session(workspace/tab/split이 사는 L2): 위상 역전이라 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const w = @import(\"../session/workspace.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // terminal → plugin: plugin runtime을 몰라야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const p = @import(\"../plugin/registry.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // plugin → renderer(전체 — barrel도 금지): renderer resource를 직접 받지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
        var v2: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer/metal_frame.zig\");", findRule("plugin"), "fixture", &v2);
        try std.testing.expectEqual(@as(usize, 1), v2); // 구현부도
    }
    // 반대로 허용된 import는 여전히 통과 — terminal이 중립 top-level(color/width)·자기 모듈을 쓰는 건 정상.
    {
        var v: usize = 0;
        scanImportsQuiet("const c = @import(\"../color.zig\");\nconst w = @import(\"width.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // plugin이 action/config facade로 상호작용하는 건 계약상 허용(pty/terminal-private/renderer만 금지) — config는 안 막힌다.
    {
        var v: usize = 0;
        scanImportsQuiet("const cfg = @import(\"../config.zig\");\nconst t = @import(\"../terminal.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v); // config·terminal 공개 barrel은 허용(terminal은 private_only 금지)
    }
}

test "scanImports catches zig fmt-clean whitespace and multi-line @import forms" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // 단일행: 기존에도 잡혔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // trailing comma 줄바꿈 형태: zig fmt --check를 통과하면서 예전 `@import("` 마커를 빠져나갔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\n    \"../pty/types.zig\",\n);", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // @import 와 `(` 사이 공백.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 허용되는 import(std, 공개 barrel)는 잡지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s = @import(\"std\");\nconst t = @import(\"../terminal.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

test "scanImports tokenizes, so comments and string literals neither evade nor false-positive" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // `@import`와 `(` 사이 줄 주석: zig fmt-clean이고 유효한 Zig지만 부분문자열 스캐너는
    // 놓쳤다. 토크나이저는 주석을 건너뛰므로 실제 import로 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import // sneaky\n    (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 금지 경로 언급: 실제 import가 아니므로 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("// historically used @import(\"../pty/types.zig\")\nconst a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("/// see @import(\"../pty/types.zig\")\npub const a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // multiline 문자열 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s =\n    \\\\@import(\"../pty/types.zig\")\n;", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── 중립성 가드(B): OS-특정 타입명이 중립 레이어(L1~L3) 코드에 식별자로 등장하지 않음을 강제 ──────────────────
// import 금지(위 rules)는 platform을 못 끌어오게 막지만, 어떤 중립 barrel이 OS 타입을 re-export하면 import 없이도
// 이름이 샐 수 있다. 이 가드는 그 누수를 직접 막는다 — renderer-strategy.md의 WebGPU 조건 1("L1~L3가 중립 frame만
// 소비함을 테스트로 증명")의 실제 충족이자 docs/layering-and-portability.md §8의 "Metal-by-name" 규칙이다.
// std.zig.Tokenizer로 **.identifier 토큰만** 검사하므로, 중립 계약을 설명하는 주석·문자열 안의 "Metal"/"CoreText"
// 언급은 오탐하지 않는다(주석은 토큰이 아니고 doc 주석·문자열은 별도 태그).
//
// 비범위: app은 의도적으로 섞인 레이어(pty/runtime + 중립 모델)라 스캔 안 한다 — 그 중립성은 컨벤션으로 다룬다
// (위 session 규칙 주석 참고). transitive·app 규칙 강제는 후속.

const NeutralLayer = struct { layer: []const u8, barrel: []const u8, dir: []const u8 };

const neutral_layers = [_]NeutralLayer{
    .{ .layer = "terminal", .barrel = "src/terminal.zig", .dir = "src/terminal" }, // L1 VT 코어 — 가장 순수한 중립
    .{ .layer = "renderer", .barrel = "src/renderer.zig", .dir = "src/renderer" },
    .{ .layer = "session", .barrel = "src/session.zig", .dir = "src/session" },
    .{ .layer = "chrome", .barrel = "src/chrome.zig", .dir = "src/chrome" },
};

// platform/macos가 정의·노출하는 OS 경계 타입 + 대표 OS(CoreText/CoreGraphics/AppKit/Metal) 타입명. 이 이름이
// 중립 레이어 코드에 식별자로 나타나면 OS 결합이 샌 것이다. 정확 일치라 오탐 0(전부 명백한 OS 타입명 — 부분
// 문자열·소문자 변형은 안 잡는다). 누락이 있어도 import 금지가 1차로 막으므로 이건 2차(re-export) 가드다.
const forbidden_os_type_names = [_][]const u8{
    // GPU 백엔드 런타임 타입(maru_metal_renderer — 실제 Metal API). metal_frame DTO(NativeMetalCell·MetalFrame·
    // MetalFrameBuffer·NativeMetalRasterUpload)는 §8 이주로 renderer(중립 frame 계약)가 소유하므로 더는 OS 타입
    // 가드 대상이 아니다 — 이름만 "Metal"이고 OS 의존 없는 ABI 표현이다. chrome은 import 가드(chrome→renderer 금지)로 여전히 차단.
    "MetalRenderer",
    // CoreText / CoreGraphics(제품 shaper·raster 경계 — C @cImport는 platform 전용이어야 한다).
    "CTFont",
    "CTRun",
    "CTLine",
    "CGGlyph",
    "CGFloat",
    "CGRect",
    "CGSize",
    "CGPoint",
    "CGContext",
    // AppKit / Metal(OS host·GPU 백엔드 전용).
    "NSColor",
    "NSView",
    "NSWindow",
    "NSString",
    "NSEvent",
    "MTLDevice",
    "MTLBuffer",
    "MTLTexture",
};

test "neutral layers (terminal·renderer·session·chrome) do not name OS-specific types" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    for (neutral_layers) |nl| {
        try checkFileForOsTypes(allocator, nl.layer, nl.barrel, &violations); // barrel(re-export 경로)
        try checkDirectoryForOsTypes(allocator, nl, &violations); // 구현부
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

fn checkDirectoryForOsTypes(allocator: std.mem.Allocator, nl: NeutralLayer, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, nl.dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ nl.dir, entry.path });
        defer allocator.free(path);

        try checkFileForOsTypes(allocator, nl.layer, path, violations);
    }
}

fn checkFileForOsTypes(allocator: std.mem.Allocator, layer: []const u8, path: []const u8, violations: *usize) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanForbiddenIdentifiers(text_z, layer, path, violations, true);
}

// .identifier 토큰만 보고 forbidden_os_type_names와 정확 일치하면 위반으로 센다. 주석(토큰 아님)·doc 주석/
// 문자열(별도 태그)은 자연히 건너뛴다 — scanImports와 같은 토크나이저 규율.
fn scanForbiddenIdentifiers(text: [:0]const u8, layer: []const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .identifier) continue;
        const ident = text[token.loc.start..token.loc.end];
        for (forbidden_os_type_names) |name| {
            if (std.mem.eql(u8, ident, name)) {
                if (emit_diagnostics) {
                    std.debug.print(
                        "neutrality violation: {s} ({s} layer) names OS-specific type '{s}' (L1~L3는 중립이어야 한다)\n",
                        .{ path, layer, name },
                    );
                }
                violations.* += 1;
            }
        }
    }
}

test "scanForbiddenIdentifiers flags code identifiers but not comments or strings" {
    // 코드 식별자(qualified access의 끝 식별자 포함)로 등장하면 위반.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const c = shaper.CTFont;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 언급은 오탐 아님(중립 계약 설명).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("// CoreText shaper consumes CTFont\nconst x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 언급도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("/// produces CGFloat-free output\npub const x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 문자열 리터럴 안도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const s = \"NSView is OS-only\";", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 무관한/유사하지만 다른 식별자는 통과(정확 일치라 부분문자열 오탐 없음).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const cell = grid.cell; const myCTFontWrapper = 0;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── core_mutex 직접 lock/unlock 금지 가드 ────────────────────────────────────────────────────────────────
// core_mutex(Surface 소유)는 재진입을 lock 전에 감지하는 owner-추적 래퍼(`Surface.lockCore`/`unlockCore`,
// `CoreOwner.lock`/`unlock`)로만 잡아야 한다. `core_mutex.lockUncancelable`/`.unlock` 직접 호출이 새로 들어오면
// owner 추적이 비어 재진입 안전망(docs/io-render-threading.md §6-5)이 새고, 이번 IME hang 같은 self-deadlock이
// 다시 런타임에서만 드러난다. 식별자 시퀀스 `core_mutex` `.` (`lockUncancelable`|`unlock`)를 토크나이저로 잡아
// 빌드에서 막는다 — 주석·문자열 속 언급은 토큰이 아니라 오탐 0이고, 필드 선언(`core_mutex:` 뒤가 `:`)이나
// 포인터 전달(`&x.core_mutex,` 뒤가 `,`)은 `.lock*`가 아니라 통과한다.

fn scanCoreMutexDirectCalls(text: [:0]const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    var saw_core_mutex = false; // 직전 식별자가 `core_mutex`였나
    var saw_dot = false; // `core_mutex` 직후 `.`를 봤나
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .identifier => {
                const ident = text[token.loc.start..token.loc.end];
                if (saw_dot and (std.mem.eql(u8, ident, "lockUncancelable") or std.mem.eql(u8, ident, "unlock"))) {
                    if (emit_diagnostics) {
                        std.debug.print(
                            "core_mutex direct-call violation: {s} calls core_mutex.{s} directly — use Surface.lockCore/unlockCore (또는 CoreOwner.lock/unlock)\n",
                            .{ path, ident },
                        );
                    }
                    violations.* += 1;
                    saw_core_mutex = false;
                    saw_dot = false;
                } else {
                    saw_core_mutex = std.mem.eql(u8, ident, "core_mutex");
                    saw_dot = false;
                }
            },
            .period => {
                saw_dot = saw_core_mutex;
                saw_core_mutex = false;
            },
            else => {
                saw_core_mutex = false;
                saw_dot = false;
            },
        }
    }
}

fn scanTreeForCoreMutexCalls(allocator: std.mem.Allocator, dir_path: []const u8, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        const text_z = try readZigFileZ(allocator, path);
        defer allocator.free(text_z);
        scanCoreMutexDirectCalls(text_z, path, violations, true);
    }
}

test "core_mutex is acquired only via owner-tracking wrappers (no direct lockUncancelable/unlock)" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    try scanTreeForCoreMutexCalls(allocator, "src", &violations);
    try scanTreeForCoreMutexCalls(allocator, "tests", &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "scanCoreMutexDirectCalls flags direct lock but not wrappers/fields/pointers/comments" {
    // 직접 호출은 잡는다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("s.core_mutex.lockUncancelable(io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("surface.core_mutex.unlock(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 포인터 전달(owner-추적 래퍼로 넘김)은 통과 — 뒤가 `,`라 `.lock*`가 아니다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.core.owner_dbg.lock(&self.core_mutex, io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 필드 선언·optional 언랩은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("core_mutex: std.Io.Mutex = .init,\nconst m = self.core_mutex.?;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 주석 속 언급은 오탐 아님(토큰이 아니다).
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("// 옛 방식: active.core_mutex.lockUncancelable(io)\nconst x = 1;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 다른 변수의 lockUncancelable(예: 큐 mutex)은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.mutex.lockUncancelable(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}
