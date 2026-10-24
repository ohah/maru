//! 파싱 결과의 입력/자원 판을 증명하는 값. 포인터를 역참조하거나 수명을 늘리지 않는다.
const std = @import("std");
const registry = @import("document_registry.zig");

pub const Stamp = struct {
    document: registry.DocumentIdentity,
    revision: u64,
    provider_identity: usize,
    tree_generation: u64,

    /// 텍스트 판만 맞춰서는 슬롯 재사용·다른 parser·미반영 파싱을 가를 수 없다.
    pub fn matches(self: Stamp, document: registry.DocumentIdentity, revision: u64, provider_identity: usize, tree_generation: u64) bool {
        return sameDocument(self.document, document) and self.revision == revision and self.provider_identity == provider_identity and self.tree_generation == tree_generation;
    }
};

pub fn sameDocument(expected: registry.DocumentIdentity, actual: ?registry.DocumentIdentity) bool {
    return if (actual) |value| std.meta.eql(expected, value) else false;
}

pub fn matches(actual: ?Stamp, document: registry.DocumentIdentity, revision: u64, provider_identity: usize, tree_generation: u64) bool {
    return if (actual) |stamp| stamp.matches(document, revision, provider_identity, tree_generation) else false;
}

test "syntax input stamp 문서 신원과 리비전 및 provider 판을 모두 요구한다" {
    const doc: registry.DocumentIdentity = .{ .owner = 1, .slot = 2, .generation = 3 };
    const original: Stamp = .{ .document = doc, .revision = 4, .provider_identity = 5, .tree_generation = 6 };
    try std.testing.expect(matches(original, doc, 4, 5, 6));
    try std.testing.expect(!matches(null, doc, 4, 5, 6));
    for (0..6) |kind| {
        var changed = original;
        switch (kind) {
            0 => changed.document.owner += 1,
            1 => changed.document.slot += 1,
            2 => changed.document.generation += 1,
            3 => changed.revision += 1,
            4 => changed.provider_identity += 1,
            else => changed.tree_generation += 1,
        }
        try std.testing.expect(!matches(changed, doc, 4, 5, 6));
    }
}
