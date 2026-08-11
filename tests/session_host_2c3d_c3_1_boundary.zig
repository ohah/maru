const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-1 inline attachment event boundary" {
    const allocator = std.testing.allocator;
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const event_contract = try readSource(allocator, "src/platform/macos/session_host/generation_event_contract.zig");
    defer allocator.free(event_contract);

    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_owner: generation_transport_mod.EventOwner = .{}"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "event_generation_mirror: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn takeEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn viewEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn releaseEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.reserveEventOwnerInPlace("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "generation_transport_mod.takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 3), count(attachment, "generation_transport_mod.eventReadinessOwned("));
    // b4와 b5의 test-only 실제 close fixture가 제품과 같은 take를 각각 한 번 실행한다.
    try std.testing.expectEqual(@as(usize, 4), count(runtime, ".takeEvent("));
    // C3-2 adds the generation product drain while preserving the legacy owner path.
    // b2b3 adds one test-only real-take Busy probe; the three product release callsites remain.
    try std.testing.expectEqual(@as(usize, 4), count(runtime, ".releaseEvent("));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "dropBufferedStream("));

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    // C3-3b3 settlement이 추가한 product owner API 13개를 별도 테스트 facade와 섞지 않고 고정한다.
    try std.testing.expectEqual(@as(usize, 28), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub const ProjectedEventTake = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub const EventReadiness = enum"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn takeEventProjected("));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn eventReadinessOwned("));

    // Token inventories include function-value extraction and whitespace-separated calls while
    // excluding comments and strings. Product and top-level-test counts are separate, so a test
    // reference cannot be exchanged for a new product escape. Whole-src totals reject any other
    // file, including a source symlink, without relying on a direct `name(` spelling.
    try expectSourceIdentifierInventory(allocator, "takeEventForStream", &.{
        .{ .path = "platform/macos/session_host/attach_product_resolver.zig", .product = 0, .top_level_test = 1 },
        .{ .path = "platform/macos/session_host/client.zig", .product = 1, .top_level_test = 10 },
        .{ .path = "platform/macos/session_host/generation_attachment.zig", .product = 0, .top_level_test = 3 },
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 0, .top_level_test = 2 },
        .{ .path = "platform/macos/session_host/remote_runtime.zig", .product = 1, .top_level_test = 0 },
    });
    try expectSourceIdentifierInventory(allocator, "dropBufferedStream", &.{
        .{ .path = "platform/macos/session_host/client.zig", .product = 1, .top_level_test = 3 },
        .{ .path = "platform/macos/session_host/client_slot.zig", .product = 1, .top_level_test = 0 },
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 0, .top_level_test = 2 },
        .{ .path = "platform/macos/session_host/remote_runtime.zig", .product = 2, .top_level_test = 1 },
    });
    try expectSourceIdentifierInventory(allocator, "releaseEvent", &.{
        .{ .path = "platform/macos/session_host/attach_product_resolver.zig", .product = 0, .top_level_test = 1 },
        .{ .path = "platform/macos/session_host/client.zig", .product = 1, .top_level_test = 1 },
        .{ .path = "platform/macos/session_host/generation_attachment.zig", .product = 4, .top_level_test = 14 },
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 6, .top_level_test = 14 },
        .{ .path = "platform/macos/session_host/remote_runtime.zig", .product = 1, .top_level_test = 3 },
    });
    try expectSourceIdentifierInventory(allocator, "EventOwner", &.{
        .{ .path = "platform/macos/session_host/generation_attachment.zig", .product = 1, .top_level_test = 3 },
        // C3-3b3 source tombstone과 phase receipt projection이 canonical EventOwner 참조 3개를 추가한다.
        .{ .path = "platform/macos/session_host/generation_event_contract.zig", .product = 39, .top_level_test = 1 },
        // C3-3b3 tombstone owner API의 mutable owner 인자와 final validation의 const owner 인자가 각각 하나씩 추가된다.
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 27, .top_level_test = 17 },
        .{ .path = "platform/macos/session_host/pending_event_preparation.zig", .product = 2, .top_level_test = 2 },
        // b2b3's dormant RemoteRuntime orchestration names the canonical source owner once.
        .{ .path = "platform/macos/session_host/remote_runtime.zig", .product = 1, .top_level_test = 0 },
    });
    try expectEventOwnerPointerInventory(allocator, &.{
        // 보수적 lexical inventory에는 builtin.is_test facade 2개와 product release consume 1개가 함께 잡힌다.
        .{ .path = "platform/macos/session_host/generation_event_contract.zig", .mutable_product = 23, .mutable_test = 0, .const_product = 14, .const_test = 0 },
        // C3-3b3 tombstone owner API와 final validation이 canonical owner를 변경 가능 pointer로 각각 하나씩 받는다.
        .{ .path = "platform/macos/session_host/generation_transport.zig", .mutable_product = 12, .mutable_test = 1, .const_product = 6, .const_test = 4 },
        .{ .path = "platform/macos/session_host/pending_event_preparation.zig", .mutable_product = 0, .mutable_test = 0, .const_product = 1, .const_test = 1 },
        .{ .path = "platform/macos/session_host/remote_runtime.zig", .mutable_product = 1, .mutable_test = 0, .const_product = 0, .const_test = 0 },
    });
    try expectSourceIdentifierInventory(allocator, "takeEventProjected", &.{
        .{ .path = "platform/macos/session_host/generation_attachment.zig", .product = 1, .top_level_test = 0 },
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 2, .top_level_test = 5 },
    });
    try expectSourceIdentifierInventory(allocator, "eventReadinessOwned", &.{
        .{ .path = "platform/macos/session_host/generation_attachment.zig", .product = 3, .top_level_test = 0 },
        .{ .path = "platform/macos/session_host/generation_transport.zig", .product = 1, .top_level_test = 0 },
    });
    // raw Client event ownership을 실제 함수별로 좁혀 legacy 호출이 generation branch로 되돌아오지 못하게 한다.
    try expectIdentifierCountInFunction(allocator, runtime, "attachmentDropStream", "dropBufferedStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "takeEventForStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "releaseEvent", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "dropBufferedStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "takeEventForStream", 0);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "releaseEvent", 0);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "dropBufferedStream", 0);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "purgeEndedStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "takeEvent", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEventsWithHook", "viewEvent", 0);
    try expectIdentifierCountInFunction(allocator, runtime, "settleAndCommitPreparedEvent", "settlePreparedEvent", 1);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    try expectIdentifierCountInFunction(allocator, client, "dropBufferedStream", "dropBufferedStream", 1);
    try expectIdentifierCountInFunction(allocator, client, "takeEventForStream", "takeEventForStream", 1);
    try expectIdentifierCountInFunction(allocator, client, "releaseEvent", "releaseEvent", 1);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    try expectIdentifierCountInFunction(allocator, slot, "finishActiveAttachmentDrop", "dropBufferedStream", 1);
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn liveGenerationMatches("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn activeGenerationMatches("));
    try std.testing.expectEqual(@as(usize, 1), count(event_contract, "pub fn settledForAttachment("));

    const hostile_inventory: [:0]const u8 =
        \\const raw = Client.takeEventForStream;
        \\fn spaced(client: anytype) void { client.takeEventForStream /* split */ (1); }
        \\const EO = EventOwner;
        \\// takeEventForStream EventOwner
        \\const prose = "takeEventForStream EventOwner";
        \\test "excluded separately" { _ = Client.takeEventForStream; const TestEO = EventOwner; _ = TestEO; }
    ;
    const hostile_take = countIdentifierInventory(hostile_inventory, "takeEventForStream");
    try std.testing.expectEqual(@as(usize, 2), hostile_take.product);
    try std.testing.expectEqual(@as(usize, 1), hostile_take.top_level_test);
    const hostile_owner = countIdentifierInventory(hostile_inventory, "EventOwner");
    try std.testing.expectEqual(@as(usize, 1), hostile_owner.product);
    try std.testing.expectEqual(@as(usize, 1), hostile_owner.top_level_test);
    const hostile_functions: [:0]const u8 =
        \\fn target() void {}
        \\fn sibling() void { Client.takeEventForStream(); }
    ;
    try expectIdentifierCountInFunction(allocator, hostile_functions, "target", "takeEventForStream", 0);
    try expectIdentifierCountInFunction(allocator, hostile_functions, "sibling", "takeEventForStream", 1);
    const hostile_pointers: [:0]const u8 =
        \\const Shapes = struct {
        \\    a: *volatile EventOwner,
        \\    b: *align(8) EventOwner,
        \\    c: *allowzero EventOwner,
        \\    d: [*]EventOwner,
        \\    e: [*c]EventOwner,
        \\    f: []EventOwner,
        \\    g: *const EventOwner,
        \\    h: *generation_event.EventOwner,
        \\    i: *?EventOwner,
        \\    j: *const [1]EventOwner,
        \\};
        \\const EO = generation_event.EventOwner;
        \\const Escaped = *EO;
        \\const EO2 = @TypeOf(@as(EventOwner, undefined));
        \\const Escaped2 = *EO2;
        \\const EO3: type = EventOwner;
        \\const Escaped3 = *EO3;
        \\const EO4 = if (true) EventOwner else EventOwner;
        \\const Escaped4 = *EO4;
        \\const EO5 = @This().EventOwner;
        \\const Escaped5 = *EO5;
        \\const EO6 = @as(type, EventOwner);
        \\const Escaped6 = *EO6;
        \\const size1: usize = @sizeOf(EventOwner);
        \\const size2 = @sizeOf(EventOwner);
        \\const size3 = (@sizeOf(EventOwner));
        \\const size4 = if (true) @sizeOf(EventOwner) else 0;
        \\const size5 = switch (true) { else => @alignOf(EventOwner) };
        \\const size6 = blk: { break :blk @sizeOf(EventOwner); };
    ;
    const hostile_pointer_inventory = try countEventOwnerPointerInventory(allocator, hostile_pointers);
    try std.testing.expectEqual(@as(usize, 8), hostile_pointer_inventory.mutable_product);
    try std.testing.expectEqual(@as(usize, 2), hostile_pointer_inventory.const_product);
    try std.testing.expectEqual(@as(usize, 7), try countUnauthorizedEventOwnerAliases(
        allocator,
        "src/hostile.zig",
        hostile_pointers,
    ));
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

const IdentifierInventory = struct { product: usize = 0, top_level_test: usize = 0 };

fn countIdentifierInventory(source: [:0]const u8, wanted: []const u8) IdentifierInventory {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: IdentifierInventory = .{};
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted)) {
                if (test_body_depth == null)
                    result.product += 1
                else
                    result.top_level_test += 1;
            },
            else => {},
        }
    }
}

fn countSourceIdentifierInventory(
    allocator: std.mem.Allocator,
    identifier: []const u8,
) !IdentifierInventory {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result: IdentifierInventory = .{};
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(
            std.testing.io,
            entry.path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        const actual = countIdentifierInventory(source, identifier);
        result.product = try std.math.add(usize, result.product, actual.product);
        result.top_level_test = try std.math.add(usize, result.top_level_test, actual.top_level_test);
    }
    return result;
}

fn expectIdentifierCountInFunction(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    function_name: []const u8,
    identifier: []const u8,
    expected: usize,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.TestUnexpectedResult;
    var found: ?std.zig.Ast.Node.Index = null;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), function_name)) continue;
        if (found) |prior| {
            if (tree.firstToken(prior) == tree.firstToken(node) and
                tree.lastToken(prior) == tree.lastToken(node)) continue;
            return error.TestUnexpectedResult;
        }
        found = node;
    }
    const function = found orelse return error.TestUnexpectedResult;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var actual: usize = 0;
    var token = first;
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and
            std.mem.eql(u8, tree.tokenSlice(token), identifier)) actual += 1;
    }
    try std.testing.expectEqual(expected, actual);
}

const EventOwnerPointerInventory = struct {
    mutable_product: usize = 0,
    mutable_test: usize = 0,
    const_product: usize = 0,
    const_test: usize = 0,
};

const EventOwnerPointerExpectation = struct {
    path: []const u8,
    mutable_product: usize,
    mutable_test: usize,
    const_product: usize,
    const_test: usize,
};

fn countEventOwnerPointerInventory(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !EventOwnerPointerInventory {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.TestUnexpectedResult;
    const excluded = try topLevelTestTokenMask(allocator, &tree);
    defer allocator.free(excluded);
    var result: EventOwnerPointerInventory = .{};
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const pointer = tree.fullPtrType(node) orelse continue;
        const child = pointer.ast.child_type;
        if (!nodeContainsIdentifier(&tree, child, "EventOwner")) continue;
        const in_test = excluded[tree.firstToken(node)];
        if (pointer.const_token != null) {
            if (in_test) result.const_test += 1 else result.const_product += 1;
        } else {
            if (in_test) result.mutable_test += 1 else result.mutable_product += 1;
        }
    }
    return result;
}

fn expectEventOwnerPointerInventory(
    allocator: std.mem.Allocator,
    expected: []const EventOwnerPointerExpectation,
) !void {
    var total: EventOwnerPointerInventory = .{};
    for (expected) |item| {
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{item.path});
        defer allocator.free(path);
        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            std.testing.io,
            path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        const actual = try countEventOwnerPointerInventory(allocator, source);
        try std.testing.expectEqual(item.mutable_product, actual.mutable_product);
        try std.testing.expectEqual(item.mutable_test, actual.mutable_test);
        try std.testing.expectEqual(item.const_product, actual.const_product);
        try std.testing.expectEqual(item.const_test, actual.const_test);
        total.mutable_product += item.mutable_product;
        total.mutable_test += item.mutable_test;
        total.const_product += item.const_product;
        total.const_test += item.const_test;
    }
    const actual_total = try countSourceEventOwnerPointerInventory(allocator);
    try std.testing.expectEqualDeep(total, actual_total);
    try std.testing.expectEqual(@as(usize, 0), try countSourceUnauthorizedEventOwnerAliases(allocator));
}

fn countSourceEventOwnerPointerInventory(allocator: std.mem.Allocator) !EventOwnerPointerInventory {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result: EventOwnerPointerInventory = .{};
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(std.testing.io, entry.path, allocator, .limited(max_source_bytes), .of(u8), 0);
        defer allocator.free(source);
        const actual = try countEventOwnerPointerInventory(allocator, source);
        result.mutable_product += actual.mutable_product;
        result.mutable_test += actual.mutable_test;
        result.const_product += actual.const_product;
        result.const_test += actual.const_test;
    }
    return result;
}

fn topLevelTestTokenMask(allocator: std.mem.Allocator, tree: *const std.zig.Ast) ![]bool {
    if (tree.errors.len != 0) return error.TestUnexpectedResult;
    const excluded = try allocator.alloc(bool, tree.tokens.len);
    errdefer allocator.free(excluded);
    @memset(excluded, false);
    var lexical_depth: usize = 0;
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) {
        const part = tree.tokenSlice(token);
        if (lexical_depth == 0 and std.mem.eql(u8, part, "test")) {
            var cursor = token;
            var body_depth: usize = 0;
            var body_started = false;
            while (cursor < tree.tokens.len) : (cursor += 1) {
                excluded[cursor] = true;
                const body_part = tree.tokenSlice(cursor);
                if (std.mem.eql(u8, body_part, "{")) {
                    body_started = true;
                    body_depth += 1;
                } else if (std.mem.eql(u8, body_part, "}")) {
                    if (!body_started or body_depth == 0) return error.TestUnexpectedResult;
                    body_depth -= 1;
                    if (body_depth == 0) break;
                }
            }
            if (!body_started or body_depth != 0 or cursor == tree.tokens.len)
                return error.TestUnexpectedResult;
            token = cursor + 1;
            continue;
        }
        if (std.mem.eql(u8, part, "{")) {
            lexical_depth += 1;
        } else if (std.mem.eql(u8, part, "}")) {
            if (lexical_depth == 0) return error.TestUnexpectedResult;
            lexical_depth -= 1;
        }
        token += 1;
    }
    if (lexical_depth != 0) return error.TestUnexpectedResult;
    return excluded;
}

fn nodeContainsIdentifier(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    identifier: []const u8,
) bool {
    var token = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and
            std.mem.eql(u8, tree.tokenSlice(token), identifier)) return true;
    }
    return false;
}

fn countSourceUnauthorizedEventOwnerAliases(allocator: std.mem.Allocator) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(std.testing.io, entry.path, allocator, .limited(max_source_bytes), .of(u8), 0);
        defer allocator.free(source);
        result += try countUnauthorizedEventOwnerAliases(allocator, entry.path, source);
    }
    return result;
}

fn countUnauthorizedEventOwnerAliases(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.TestUnexpectedResult;
    var result: usize = 0;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const variable = tree.fullVarDecl(node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (!nodeContainsIdentifier(&tree, init, "EventOwner")) continue;
        const name = tree.tokenSlice(variable.ast.mut_token + 1);
        const canonical = std.mem.eql(u8, path, "platform/macos/session_host/generation_transport.zig") and
            std.mem.eql(u8, name, "EventOwner") and
            tree.firstToken(init) + 2 == tree.lastToken(init) and
            std.mem.eql(u8, tree.tokenSlice(tree.firstToken(init)), "generation_event") and
            std.mem.eql(u8, tree.tokenSlice(tree.firstToken(init) + 1), ".") and
            std.mem.eql(u8, tree.tokenSlice(tree.lastToken(init)), "EventOwner");
        const init_head = tree.tokenSlice(tree.firstToken(init));
        const reviewed_composite = reviewedEventOwnerComposite(path, name, init_head);
        const reviewed_value = std.mem.eql(u8, init_head, "@ptrFromInt") or
            initializerOnlyUsesEventOwnerInLayoutQueries(&tree, node);
        if (!canonical and !reviewed_composite and !reviewed_value) result += 1;
    }
    return result;
}

fn reviewedEventOwnerComposite(path: []const u8, name: []const u8, init_head: []const u8) bool {
    if (std.mem.eql(u8, path, "platform/macos/session_host/generation_attachment.zig"))
        return std.mem.eql(u8, name, "GenerationAttachment") and std.mem.eql(u8, init_head, "struct");
    if (std.mem.eql(u8, path, "platform/macos/session_host/generation_event_contract.zig"))
        return (std.mem.eql(u8, name, "EventOwner") and std.mem.eql(u8, init_head, "extern")) or
            (std.mem.eql(u8, name, "testing") and std.mem.eql(u8, init_head, "if"));
    if (std.mem.eql(u8, path, "platform/macos/session_host/pending_event_preparation.zig"))
        return std.mem.eql(u8, name, "RuntimePreparationContext") and
            std.mem.eql(u8, init_head, "struct");
    if (std.mem.eql(u8, path, "platform/macos/session_host/remote_runtime.zig"))
        return std.mem.eql(u8, name, "RemoteRuntime") and std.mem.eql(u8, init_head, "struct");
    if (!std.mem.eql(u8, path, "platform/macos/session_host/generation_transport.zig") or
        !std.mem.eql(u8, init_head, "struct")) return false;
    return std.mem.eql(u8, name, "GenerationTransport") or
        std.mem.eql(u8, name, "Owner") or
        std.mem.eql(u8, name, "EventReleaseReentryAllocator") or
        std.mem.eql(u8, name, "EventForeignThreadReleaseProbe") or
        std.mem.eql(u8, name, "Fixture") or
        std.mem.eql(u8, name, "CanonicalHarnessProbe");
}

fn initializerOnlyUsesEventOwnerInLayoutQueries(
    tree: *const std.zig.Ast,
    init: std.zig.Ast.Node.Index,
) bool {
    const first = tree.firstToken(init);
    const last = tree.lastToken(init);
    var saw_owner = false;
    var token = first;
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or
            !std.mem.eql(u8, tree.tokenSlice(token), "EventOwner")) continue;
        saw_owner = true;
        var owner_start = token;
        while (owner_start >= first + 2 and
            std.mem.eql(u8, tree.tokenSlice(owner_start - 1), ".") and
            tree.tokenTag(owner_start - 2) == .identifier)
        {
            owner_start -= 2;
        }
        if (owner_start < first + 2 or tree.tokenTag(owner_start - 1) != .l_paren)
            return false;
        const builtin = tree.tokenSlice(owner_start - 2);
        if (!std.mem.eql(u8, builtin, "@sizeOf") and !std.mem.eql(u8, builtin, "@alignOf"))
            return false;
    }
    return saw_owner;
}

const SourceIdentifierExpectation = struct {
    path: []const u8,
    product: usize,
    top_level_test: usize,
};

fn expectSourceIdentifierInventory(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    expected: []const SourceIdentifierExpectation,
) !void {
    var expected_total: IdentifierInventory = .{};
    for (expected) |item| {
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{item.path});
        defer allocator.free(path);
        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            std.testing.io,
            path,
            allocator,
            .limited(max_source_bytes),
            .of(u8),
            0,
        );
        defer allocator.free(source);
        const actual = countIdentifierInventory(source, identifier);
        try std.testing.expectEqual(item.product, actual.product);
        try std.testing.expectEqual(item.top_level_test, actual.top_level_test);
        expected_total.product = try std.math.add(usize, expected_total.product, item.product);
        expected_total.top_level_test = try std.math.add(usize, expected_total.top_level_test, item.top_level_test);
    }
    const actual_total = try countSourceIdentifierInventory(allocator, identifier);
    try std.testing.expectEqual(expected_total.product, actual_total.product);
    try std.testing.expectEqual(expected_total.top_level_test, actual_total.top_level_test);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
