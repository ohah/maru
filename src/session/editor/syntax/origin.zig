const std = @import("std");

// native 복사 성공은 호출자가, 번호의 단일 발급은 registry가 보장한다. 여기서는 값의 관계만 검증한다.
const registry = @import("../document_registry.zig");
const Document = registry.DocumentIdentity;
pub const Origin = registry.SyntaxOrigin;
const TestIssuer = struct {
    document: Document,
    last: u64 = 0,

    fn issue(self: *TestIssuer, revision: u64) ?Origin {
        if (self.last == std.math.maxInt(u64)) return null;
        self.last += 1;
        return .{ .document = self.document, .revision = revision, .serial = self.last };
    }
};
pub const Resource = struct {
    document: Document,
    revision: u64,
    parser: usize,
    generation: u64,
    grammar: usize,
    complete: bool = true,
};
pub const Tagged = struct {
    resource: Resource,
    origin: Origin,

    pub fn matches(self: Tagged, live: Resource) bool {
        return live.complete and self.origin.serial != 0 and self.origin.revision == live.revision and
            std.meta.eql(self.resource, live) and std.meta.eql(self.origin.document, live.document);
    }
};

fn updated(before: ?Resource, after: Resource) bool {
    if (!after.complete) return false;
    return if (before) |old| old.parser != after.parser or old.generation != after.generation else true;
}

/// 실제 native 갱신을 완료한 뒤에만 새 발급 번호를 입력·자원 판에 묶는다.
pub fn parsed(before: ?Resource, after: Resource, origin: ?Origin) ?Tagged {
    if (!updated(before, after)) return null;
    const value: Tagged = .{ .resource = after, .origin = origin orelse return null };
    return if (value.matches(after)) value else null;
}

/// 값이 같다는 추정 대신 실제 복사 성공과 제공 자원의 현재 판을 요구한다.
pub fn copied(before: ?Resource, after: Resource, source_live: Resource, source: ?Tagged, succeeded: bool) ?Tagged {
    if (!succeeded or !updated(before, after) or after.parser == source_live.parser or after.grammar != source_live.grammar) return null;
    const ready = source orelse return null;
    if (!ready.matches(source_live)) return null;
    const value: Tagged = .{ .resource = after, .origin = ready.origin };
    return if (value.matches(after)) value else null;
}
pub const Edit = struct { start: u32, old_end: u32, new_end: u32, points: [6]u32 };
pub const Receipt = struct {
    before: Tagged,
    after: Tagged,
    edit: Edit,

    pub fn init(before_live: Resource, before: ?Tagged, after_live: Resource, after: ?Tagged, edit: Edit, ranges_before: u64, ranges_available: bool) ?Receipt {
        const old = before orelse return null;
        const new = after orelse return null;
        if (!old.matches(before_live) or !new.matches(after_live) or !ranges_available) return null;
        if (!std.meta.eql(before_live.document, after_live.document) or
            before_live.parser != after_live.parser or before_live.grammar != after_live.grammar or
            before_live.revision >= after_live.revision or before_live.generation == std.math.maxInt(u64) or
            before_live.generation + 1 != after_live.generation or ranges_before != before_live.generation or
            std.meta.eql(old.origin, new.origin)) return null;
        return .{ .before = old, .after = new, .edit = edit };
    }

    pub fn allows(self: Receipt, receiver_live: Resource, receiver: ?Tagged, source_live: Resource, requested: Edit) bool {
        const target = receiver orelse return false;
        return target.matches(receiver_live) and self.after.matches(source_live) and
            std.meta.eql(target.origin, self.before.origin) and
            receiver_live.revision == self.before.resource.revision and
            receiver_live.grammar == source_live.grammar and
            std.meta.eql(requested, self.edit);
    }
};

const Fixture = struct {
    issuer: TestIssuer,
    old: Tagged,
    new: Tagged,
    peer: Tagged,
    edit: Edit,

    pub fn init() Fixture {
        const document: Document = .{ .owner = 1, .slot = 2, .generation = 3 };
        var issuer: TestIssuer = .{ .document = document };
        const old: Tagged = .{ .resource = .{ .document = document, .revision = 4, .parser = 5, .generation = 6, .grammar = 7 }, .origin = issuer.issue(4).? };
        var new = old;
        new.resource.revision = 5;
        new.resource.generation = 7;
        new.origin = issuer.issue(5).?;
        var peer = old;
        peer.resource.parser = 9;
        peer.resource.generation = 91; // 같은 native 복사 계보도 뷰별 parser와 트리 판은 다를 수 있다.
        return .{ .issuer = issuer, .old = old, .new = new, .peer = peer, .edit = .{ .start = 1, .old_end = 2, .new_end = 3, .points = .{ 0, 1, 0, 2, 0, 3 } } };
    }

    fn receipt(self: Fixture) Receipt {
        return Receipt.init(self.old.resource, self.old, self.new.resource, self.new, self.edit, self.old.resource.generation, true).?;
    }

    fn normal(self: Fixture) !void {
        try std.testing.expect(self.receipt().allows(self.peer.resource, self.peer, self.new.resource, self.edit));
    }
};

test "change origin 복사 계보와 실제 자원의 다른 축을 요구한다" {
    const f = Fixture.init();
    for (0..12) |kind| {
        try f.normal();
        var bad = f.peer;
        switch (kind) {
            0 => bad.origin.serial += 1,
            1 => bad.origin.document.owner += 1,
            2 => bad.resource.document.owner += 1,
            3 => bad.resource.document.slot += 1,
            4 => bad.resource.document.generation += 1,
            5 => bad.resource.revision += 1,
            6 => bad.resource.parser += 1,
            7 => bad.resource.generation += 1,
            8 => bad.resource.grammar += 1,
            9 => bad.resource.complete = false,
            10 => bad.origin.revision += 1,
            else => bad.origin.serial = 0,
        }
        try std.testing.expect(!f.receipt().allows(f.peer.resource, bad, f.new.resource, f.edit));
        try f.normal();
    }
    try std.testing.expect(!f.receipt().allows(f.peer.resource, null, f.new.resource, f.edit));
    var foreign_grammar = f.peer;
    foreign_grammar.resource.grammar += 1;
    try std.testing.expect(!f.receipt().allows(foreign_grammar.resource, foreign_grammar, f.new.resource, f.edit));
}

test "change origin 제공 자원의 후속 변경과 범위 세대 누락을 거절한다" {
    const f = Fixture.init();
    for (0..7) |kind| {
        try f.normal();
        var source = f.new.resource;
        switch (kind) {
            0 => source.document.owner += 1,
            1 => source.document.generation += 1,
            2 => source.revision += 1,
            3 => source.parser += 1,
            4 => source.generation += 1,
            5 => source.grammar += 1,
            else => source.complete = false,
        }
        try std.testing.expect(!f.receipt().allows(f.peer.resource, f.peer, source, f.edit));
        try f.normal();
    }
    try std.testing.expect(Receipt.init(f.old.resource, f.old, f.new.resource, f.new, f.edit, f.old.resource.generation, false) == null);
    try std.testing.expect(Receipt.init(f.old.resource, f.old, f.new.resource, f.new, f.edit, f.old.resource.generation + 1, true) == null);
    try std.testing.expect(Receipt.init(f.old.resource, null, f.new.resource, f.new, f.edit, f.old.resource.generation, true) == null);
    try std.testing.expect(Receipt.init(f.old.resource, f.old, f.new.resource, null, f.edit, f.old.resource.generation, true) == null);
}

test "change origin byte와 모든 행 열 좌표가 같은 편집만 수락한다" {
    const f = Fixture.init();
    for (0..9) |kind| {
        try f.normal();
        var edit = f.edit;
        switch (kind) {
            0 => edit.start += 1,
            1 => edit.old_end += 1,
            2 => edit.new_end += 1,
            else => edit.points[kind - 3] += 1,
        }
        try std.testing.expect(!f.receipt().allows(f.peer.resource, f.peer, f.new.resource, edit));
        try f.normal();
    }
}

test "change origin 다른 이전 문서와 리비전 및 파싱 이력을 거절한다" {
    const f = Fixture.init();
    for (0..5) |kind| {
        try f.normal();
        var old = f.old;
        switch (kind) {
            0 => old.resource.document.generation += 1,
            1 => old.resource.revision = f.new.resource.revision,
            2 => old.resource.parser += 1,
            3 => old.resource.generation -= 1,
            else => old.resource.grammar += 1,
        }
        try std.testing.expect(Receipt.init(old.resource, old, f.new.resource, f.new, f.edit, old.resource.generation, true) == null);
        try f.normal();
    }
}

test "change origin 발급 고갈과 독립 파싱은 입력을 실패시키지 않고 증명만 포기한다" {
    var f = Fixture.init();
    try f.normal();
    var independent = f.peer;
    independent.origin = f.issuer.issue(f.peer.resource.revision).?;
    try std.testing.expect(!f.receipt().allows(independent.resource, independent, f.new.resource, f.edit));
    f.issuer.last = std.math.maxInt(u64);
    try std.testing.expect(f.issuer.issue(f.new.resource.revision) == null);
    try std.testing.expectEqual(std.math.maxInt(u64), f.issuer.last);
    try std.testing.expect(!f.receipt().allows(f.peer.resource, null, f.new.resource, f.edit));
    try f.normal();
}

test "change origin 생성은 실제 native 갱신과 복사 성공을 요구한다" {
    const f = Fixture.init();
    try std.testing.expectEqualDeep(f.new, parsed(f.old.resource, f.new.resource, f.new.origin).?);
    try std.testing.expect(parsed(f.new.resource, f.new.resource, f.new.origin) == null);
    try std.testing.expect(parsed(f.old.resource, f.new.resource, null) == null);
    try std.testing.expect(parsed(f.old.resource, f.new.resource, f.old.origin) == null);
    var after = f.peer.resource;
    after.revision = f.new.resource.revision;
    after.generation += 1;
    const accepted = copied(f.peer.resource, after, f.new.resource, f.new, true).?;
    try std.testing.expectEqualDeep(f.new.origin, accepted.origin);
    try std.testing.expectEqualDeep(after, accepted.resource);
    try std.testing.expect(copied(f.peer.resource, after, f.new.resource, f.new, false) == null);
    try std.testing.expect(copied(after, after, f.new.resource, f.new, true) == null);
    try std.testing.expect(copied(f.peer.resource, after, f.new.resource, null, true) == null);
    after.parser = f.new.resource.parser;
    try std.testing.expect(copied(f.peer.resource, after, f.new.resource, f.new, true) == null);
    after.parser = f.peer.resource.parser;
    after.grammar += 1;
    try std.testing.expect(copied(f.peer.resource, after, f.new.resource, f.new, true) == null);
    after.grammar = f.new.resource.grammar;
    after.complete = false;
    try std.testing.expect(copied(f.peer.resource, after, f.new.resource, f.new, true) == null);
}
