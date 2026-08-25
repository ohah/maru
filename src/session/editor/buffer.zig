//! 편집 가능한 텍스트 버퍼 — **persistent rope**
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.0).
//!
//! N1까지 편집기는 읽기 전용이라 문서가 슬라이스 하나였다. 편집이 들어오면 그것으로는 안 된다 —
//! 가운데 삽입이 뒤 전체를 밀고, 그 비용이 문서 크기에 비례한다.
//!
//! **표현은 rope다. 확정이 아니라 1순위 후보이고, 뒤집을 조건을 §3.0이 표로 든다.** 여기서
//! 고른 이유는 그 절이 적은 둘 그대로다:
//!
//! - **persistent(copy-on-write)가 요구다.** §2.1이 파싱·랩·검색을 렌더 루프 밖으로 빼려면
//!   스냅숏을 워커에 넘기고 메인이 옛 것으로 계속 그려야 한다. 이 성질이 없으면 그 분리가
//!   성립하지 않는다 — `Snapshot`이 그것이고, 노드 참조 수가 원자적인 이유도 그것이다.
//! - **줄 수가 같은 트리에서 나온다.** 노드마다 부분 트리의 `\n` 수를 들고 있어 byte↔줄 왕복이
//!   `O(log n)`이다. piece table을 골랐다면 별도 인덱스의 갱신·무효화가 새 계약이 됐을 것이다.
//!
//! **`line_index.zig`를 아직 지우지 않는다.** §3.0이 *"흡수되는지는 표현을 정한 뒤에 안다"*고 적었고,
//! 실제로 이 트리는 줄 **수**는 답하지만 줄별 `LineEnding`(§3.5 원본 보존)은 답하지 않는다 —
//! `\r\n`인지 `\n`인지는 노드 합으로 나오지 않는다. 그 절이 *"부분 잔존은 이미 예상된다"*고 적은
//! 그대로이며, 뒤집을 신호는 *"전혀 못 지운다"*일 때다. 지금 판단은 **부분 잔존**이다.
//!
//! **undo는 여기 없다.** §3.3이 delta(역연산)로 두기로 했고, rope가 스냅숏을 `O(1)`로 준다는 것이
//! 스냅숏을 undo에 쓸 이유는 되지 않는다 — 스택에 N개를 쥐면 그동안 바뀐 노드가 전부 살아 있다.
//! 이 모듈은 **한 번의 편집이 무엇이었는지**(`Edit`)를 답하고, 그것을 쌓는 일은 그 슬라이스가 한다.
//!
//! **L2다 — filesystem도 뷰도 모른다.** 열기·저장은 `document.zig`와 저장 경로가, 화면 행은 L3가 맡는다.

const std = @import("std");

/// 잎 하나가 담는 최대 byte. 이 값이 하는 일 둘:
///
/// - **작은 편집이 큰 복사를 일으키지 않게 한다.** 삽입은 잎 하나만 다시 만든다.
/// - **잎이 잘게 부서지지 않게 한다.** `concat`이 이 상한 안에서 이웃 잎을 합쳐, 한 글자씩 치는
///   동안 트리가 깊어지지 않는다(그 경로가 타이핑이라 가장 흔하다).
///
/// **1 KiB는 재서 정한 값이 아니라 출발점이다.** §10의 임계값 규율대로 소비처가 생긴 뒤 조정한다.
const leaf_max: usize = 1024;

/// 이 깊이를 넘으면 부분 트리를 다시 세운다.
///
/// **깊이로 재는 이유**: 무게로 재면 문서 끝에 이어 붙이는 편집(= 타이핑)이 매번 불균형으로 판정돼
/// 키 하나마다 `O(n)` 재구축이 된다. 깊이 기준은 그 경로를 건드리지 않고, 재구축은 잎 수에
/// 비례하므로 임계마다 한 번이면 분할 상환된다.
const rebalance_depth: u8 = 32;

/// 한 번의 편집이 문서에 한 일. **selection 매핑이 얹히는 자리다**(§3.3).
///
/// 편집은 그 뒤의 byte offset을 전부 민다. 그래서 §3.3은 매핑을 *"delta 적용과 한 연산으로 묶어"*
/// 중간 상태가 새어 나가지 않게 하라고 요구한다 — 버퍼가 편집 결과와 함께 이 값을 돌려주는 것이
/// 그 요구를 인터페이스로 만든 것이다. 나중에 끼우려 했다면 `insert`/`delete`의 서명이 바뀐다.
///
/// **여러 range를 담지 않는다.** 멀티 커서 한 번이 delta 하나라는 §3.3의 요구는 그 delta가 이것을
/// 여럿 담는 형태로 만족된다 — 버퍼 연산 자체는 한 자리를 고치는 것이 맞다.
pub const Edit = struct {
    /// 바뀐 구간의 시작 offset(편집 **전** 축).
    start: usize,
    /// 지워진 byte 수.
    removed: usize,
    /// 삽입된 byte 수.
    inserted: usize,

    /// 편집 전 offset을 편집 후 축으로 옮긴다(§3.3).
    ///
    /// 규칙 둘 그대로다 — 앞선 변경의 길이 차만큼 밀고, **삭제된 구간 안을 가리키고 있었으면
    /// 구간 시작으로 접는다.** 접지 않으면 그 offset이 지워진 자리를 가리켜 다음 입력이 엉뚱한
    /// 곳에 간다.
    ///
    /// 경계는 **삭제 구간 끝을 안쪽으로 친다**: `start + removed`에 있던 커서는 지워진 텍스트
    /// 바로 뒤이므로 밀어서 살린다.
    pub fn mapOffset(self: Edit, offset: usize) usize {
        if (offset <= self.start) return offset;
        if (offset >= self.start + self.removed) {
            return offset - self.removed + self.inserted;
        }
        return self.start;
    }
};

/// 트리 노드 — **만들어진 뒤 내용이 바뀌지 않는다**(참조 수만 움직인다).
///
/// 불변이라 부분 트리를 여러 판이 동시에 가리킬 수 있고, 그것이 곧 copy-on-write다.
const Node = struct {
    /// 이 노드를 가리키는 수. **원자적이다** — 스냅숏이 워커 스레드로 건너가므로 메인과 워커가
    /// 같은 노드를 동시에 놓을 수 있다.
    refs: std.atomic.Value(u32),
    /// 부분 트리의 총 byte 수.
    bytes: usize,
    /// 부분 트리 안 `\n`의 수. **줄 수 = 이 값 + 1**이다.
    ///
    /// `\r\n`도 `\n`을 하나 들고 있어 같은 수를 낸다. `\r` 단독은 줄바꿈이 아니다 —
    /// `line_index.build`가 같은 판단을 하며, 두 곳이 갈리면 줄 수가 어긋난다.
    newlines: usize,
    /// 트리 깊이(잎이 1). 재구축 판단에만 쓴다.
    depth: u8,
    kind: union(enum) {
        /// 이 노드가 소유하는 bytes. `release`가 푼다.
        leaf: []u8,
        branch: struct { left: *Node, right: *Node },
    },

    fn isLeaf(self: *const Node) bool {
        return self.kind == .leaf;
    }
};

fn countNewlines(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n");
}

fn retain(node: *Node) *Node {
    _ = node.refs.fetchAdd(1, .monotonic);
    return node;
}

/// 참조 하나를 놓는다. 마지막이면 자식까지 내려가며 푼다.
///
/// **재귀가 아니라 명시 스택이다.** 깊이는 `rebalance_depth`로 묶여 있지만 재구축 직전 순간에는
/// 그 값을 넘을 수 있고, 무엇보다 이 함수는 실패할 수 없어야 한다 — 스택을 쌓다 넘치면 해제
/// 경로에서 죽는다.
fn release(allocator: std.mem.Allocator, node: *Node) void {
    var stack: [rebalance_depth * 2 + 8]*Node = undefined;
    var len: usize = 0;
    stack[len] = node;
    len += 1;

    while (len > 0) {
        len -= 1;
        const n = stack[len];
        if (n.refs.fetchSub(1, .release) != 1) continue;
        // 마지막 참조였다. 다른 스레드의 놓기가 보이도록 획득 담을 친다.
        _ = n.refs.load(.acquire);

        switch (n.kind) {
            .leaf => |bytes| allocator.free(bytes),
            .branch => |b| {
                if (len + 2 > stack.len) {
                    // 스택이 모자라면 그 가지만 재귀로 푼다. 깊이 상한 덕에 실제로는 닿지 않는
                    // 자리이고, 닿더라도 조용히 새는 것보다 낫다.
                    release(allocator, b.left);
                    release(allocator, b.right);
                } else {
                    stack[len] = b.left;
                    len += 1;
                    stack[len] = b.right;
                    len += 1;
                }
            },
        }
        allocator.destroy(n);
    }
}

fn newLeaf(allocator: std.mem.Allocator, bytes: []const u8) !*Node {
    const copy = try allocator.dupe(u8, bytes);
    errdefer allocator.free(copy);
    const node = try allocator.create(Node);
    node.* = .{
        .refs = std.atomic.Value(u32).init(1),
        .bytes = copy.len,
        .newlines = countNewlines(copy),
        .depth = 1,
        .kind = .{ .leaf = copy },
    };
    return node;
}

/// 잎 둘을 **이어 붙인 하나**로 만든다. `concat`의 합치기 규칙이 쓴다.
fn newLeafJoined(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !*Node {
    const copy = try allocator.alloc(u8, a.len + b.len);
    errdefer allocator.free(copy);
    @memcpy(copy[0..a.len], a);
    @memcpy(copy[a.len..], b);
    const node = try allocator.create(Node);
    node.* = .{
        .refs = std.atomic.Value(u32).init(1),
        .bytes = copy.len,
        .newlines = countNewlines(copy),
        .depth = 1,
        .kind = .{ .leaf = copy },
    };
    return node;
}

/// 가지를 만든다. **자식 참조를 가져간다**(호출자가 쥐고 있던 것을 넘긴다).
fn newBranch(allocator: std.mem.Allocator, left: *Node, right: *Node) !*Node {
    const node = allocator.create(Node) catch |err| {
        release(allocator, left);
        release(allocator, right);
        return err;
    };
    node.* = .{
        .refs = std.atomic.Value(u32).init(1),
        .bytes = left.bytes + right.bytes,
        .newlines = left.newlines + right.newlines,
        .depth = @max(left.depth, right.depth) +| 1,
        .kind = .{ .branch = .{ .left = left, .right = right } },
    };
    return node;
}

/// 잎들을 모아 균형 트리를 다시 세운다.
///
/// 기존 잎을 **공유한다** — 내용이 불변이라 복사할 이유가 없고, 재구축 비용이 잎 수에만
/// 비례하게 만드는 것도 이것이다.
fn rebuildBalanced(allocator: std.mem.Allocator, node: *Node) !*Node {
    var leaves: std.ArrayList(*Node) = .empty;
    defer {
        for (leaves.items) |leaf| release(allocator, leaf);
        leaves.deinit(allocator);
    }

    var stack: std.ArrayList(*Node) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, node);
    while (stack.pop()) |n| {
        switch (n.kind) {
            .leaf => {
                // **`append(retain(n))`으로 적으면 안 된다** — append가 실패하면 그 참조가 샌다.
                const held = retain(n);
                leaves.append(allocator, held) catch |err| {
                    release(allocator, held);
                    return err;
                };
            },
            .branch => |b| {
                try stack.append(allocator, b.right);
                try stack.append(allocator, b.left);
            },
        }
    }

    // **가지에는 잎이 반드시 있다** — 잎이 아닌 노드는 자식 둘을 갖고 모든 경로가 잎에서 끝난다.
    // 오류로 두면 도달할 수 없는 값이 `insert`·`delete`를 거쳐 **모든 호출자의 오류 집합**에
    // 얹히고, 그것을 받는 쪽이 있을 수 없는 분기를 짓게 된다.
    std.debug.assert(leaves.items.len > 0);
    return foldBalanced(allocator, &leaves);
}

/// 잎 배열을 **제자리에서** 아래에서 위로 접어 균형 트리를 만든다.
///
/// **소유를 인덱스로 가른다.** 앞선 판은 층마다 새 배열을 만들고 `defer`로 통째로 놓았는데, 그
/// `defer`가 **이미 `newBranch`가 가져간 노드까지 다시 놓아** 이중 해제였다(적대적 검증 2026-08-24).
/// 제자리로 접으면 소비한 구간과 안 만진 구간이 인덱스로 나뉘어 그 혼동이 생기지 않고, 층마다
/// 배열을 새로 잡지 않으므로 **실패할 수 있는 자리도 `newBranch` 하나로 줄어든다.**
///
/// 성공하면 `level`은 비고(소유가 결과로 넘어간다), 실패해도 비운다(안에서 전부 놓는다) — 어느
/// 쪽이든 호출자의 `defer`가 두 번 놓지 않는다.
fn foldBalanced(allocator: std.mem.Allocator, level: *std.ArrayList(*Node)) !*Node {
    std.debug.assert(level.items.len > 0);

    while (level.items.len > 1) {
        var write: usize = 0;
        var read: usize = 0;
        while (read + 1 < level.items.len) : (read += 2) {
            const branch = newBranch(allocator, level.items[read], level.items[read + 1]) catch |err| {
                // `newBranch`가 자기 인자 둘은 놓았다. 앞서 접어 둔 것과 아직 안 만진 것을 놓는다.
                for (level.items[0..write]) |n| release(allocator, n);
                for (level.items[read + 2 ..]) |n| release(allocator, n);
                level.clearRetainingCapacity();
                return err;
            };
            level.items[write] = branch;
            write += 1;
        }
        if (read < level.items.len) {
            level.items[write] = level.items[read];
            write += 1;
        }
        level.shrinkRetainingCapacity(write);
    }

    const root = level.items[0];
    level.clearRetainingCapacity();
    return root;
}

/// 둘을 잇는다. **양쪽 참조를 가져간다.**
///
/// 합치기 규칙 셋이 잎이 부서지는 것을 막는다. 특히 두 번째 규칙(왼쪽 가지의 오른쪽 잎에 붙이기)이
/// **문서 끝에 이어 붙이는 타이핑**을 잎 하나 교체로 만든다.
fn concat(allocator: std.mem.Allocator, left: *Node, right: *Node) !*Node {
    if (left.bytes == 0) {
        release(allocator, left);
        return right;
    }
    if (right.bytes == 0) {
        release(allocator, right);
        return left;
    }

    // **이 아래로는 실패해도 입력 둘을 놓는다**(위 규약). `errdefer`로 적어 두면 새 분기를 더할 때
    // 놓기를 잊을 수 없다 — 잊은 판이 실제로 이중 해제와 세그폴트를 냈다(적대적 검증 2026-08-24).
    var owned = true;
    errdefer if (owned) {
        release(allocator, left);
        release(allocator, right);
    };

    if (left.isLeaf() and right.isLeaf() and left.bytes + right.bytes <= leaf_max) {
        const joined = try newLeafJoined(allocator, left.kind.leaf, right.kind.leaf);
        release(allocator, left);
        release(allocator, right);
        return joined;
    }

    if (right.isLeaf() and left.kind == .branch) {
        const lb = left.kind.branch;
        if (lb.right.isLeaf() and lb.right.bytes + right.bytes <= leaf_max) {
            const joined = try newLeafJoined(allocator, lb.right.kind.leaf, right.kind.leaf);
            // `newBranch`는 실패하면 **자기 인자 둘**을 놓는다. `left`·`right`는 아직 우리 것이므로
            // 위 `errdefer`가 그쪽을 맡는다 — 둘을 섞으면 이중 해제다.
            const merged = try newBranch(allocator, retain(lb.left), joined);
            release(allocator, left);
            release(allocator, right);
            return merged;
        }
    }

    if (left.isLeaf() and right.kind == .branch) {
        const rb = right.kind.branch;
        if (rb.left.isLeaf() and left.bytes + rb.left.bytes <= leaf_max) {
            const joined = try newLeafJoined(allocator, left.kind.leaf, rb.left.kind.leaf);
            const merged = try newBranch(allocator, joined, retain(rb.right));
            release(allocator, left);
            release(allocator, right);
            return merged;
        }
    }

    // `newBranch`가 실패하면 그 안에서 `left`·`right`를 놓으므로 위 `errdefer`를 끈다.
    owned = false;

    const branch = try newBranch(allocator, left, right);
    if (branch.depth <= rebalance_depth) return branch;

    // 다시 세우지 못하면 **깊은 채로 둔다** — 깊이는 성능 문제이지 정확성 문제가 아니고, 여기서
    // 실패를 올리면 할당 실패 하나가 편집 자체를 거절하게 된다.
    const balanced = rebuildBalanced(allocator, branch) catch return branch;
    release(allocator, branch);
    return balanced;
}

/// `offset`에서 둘로 가른다. **입력 참조를 가져가고**, 나온 둘 각각에 참조 하나씩을 준다.
const Split = struct { left: *Node, right: *Node };

fn splitNode(allocator: std.mem.Allocator, node: *Node, offset: usize) !Split {
    std.debug.assert(offset <= node.bytes);

    // **실패해도 `node`를 놓는다**(위 규약). 성공 경로는 아래에서 명시로 놓거나 결과에 실어 보내므로
    // 이 `errdefer`가 걸리지 않는다.
    var owned = true;
    errdefer if (owned) release(allocator, node);

    if (offset == 0) {
        const empty = try newLeaf(allocator, "");
        owned = false; // 결과에 실어 보낸다
        return .{ .left = empty, .right = node };
    }
    if (offset == node.bytes) {
        const empty = try newLeaf(allocator, "");
        owned = false; // 결과에 실어 보낸다
        return .{ .left = node, .right = empty };
    }

    switch (node.kind) {
        .leaf => |bytes| {
            const l = try newLeaf(allocator, bytes[0..offset]);
            errdefer release(allocator, l);
            const r = try newLeaf(allocator, bytes[offset..]);
            release(allocator, node);
            owned = false;
            return .{ .left = l, .right = r };
        },
        .branch => |b| {
            if (offset < b.left.bytes) {
                const sub = try splitNode(allocator, retain(b.left), offset);
                // `concat`이 `sub.right`를 가져간다(실패해도). 남는 것은 `sub.left`뿐이다.
                errdefer release(allocator, sub.left);
                const right = try concat(allocator, sub.right, retain(b.right));
                release(allocator, node);
                owned = false;
                return .{ .left = sub.left, .right = right };
            }
            const sub = try splitNode(allocator, retain(b.right), offset - b.left.bytes);
            errdefer release(allocator, sub.right);
            const left = try concat(allocator, retain(b.left), sub.left);
            release(allocator, node);
            owned = false;
            return .{ .left = left, .right = sub.right };
        },
    }
}

/// 읽기 전용 판 하나. **워커 스레드로 넘어가는 것이 이것이다**(§2.1).
///
/// 스냅숏을 든 동안 그 판의 내용은 절대 바뀌지 않는다 — 편집은 새 루트를 만들 뿐 옛 노드를
/// 건드리지 않기 때문이다. 다 쓴 뒤 `deinit`으로 놓지 않으면 그 판이 붙들고 있던 노드가 남는다.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    pub fn deinit(self: *Snapshot) void {
        release(self.allocator, self.root);
        self.* = undefined;
    }

    pub fn byteLen(self: Snapshot) usize {
        return self.root.bytes;
    }

    /// 논리 줄 수. **항상 1 이상이다** — `line_index.lineCount`와 같은 규칙이다(빈 문서도 한 줄).
    pub fn lineCount(self: Snapshot) usize {
        return self.root.newlines + 1;
    }

    pub fn copyRange(self: Snapshot, allocator: std.mem.Allocator, start: usize, end: usize) ![]u8 {
        return copyRangeOf(self.root, allocator, start, end);
    }
};

/// 편집 가능한 문서 내용.
///
/// **`Document`(§3.5)와 다른 것이다** — 그쪽은 BOM·줄바꿈 같은 *파일 속성*을 들고, 이쪽은 *내용*을
/// 든다. 저장 경로가 둘을 합쳐 쓴다.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Buffer {
        const root = try buildFrom(allocator, initial);
        return .{ .allocator = allocator, .root = root };
    }

    pub fn deinit(self: *Buffer) void {
        release(self.allocator, self.root);
        self.* = undefined;
    }

    pub fn byteLen(self: Buffer) usize {
        return self.root.bytes;
    }

    /// 논리 줄 수. **항상 1 이상이다**(`line_index.lineCount`와 같은 규칙).
    pub fn lineCount(self: Buffer) usize {
        return self.root.newlines + 1;
    }

    /// 지금 내용을 붙든 읽기 전용 판을 뜬다. `O(1)`이다 — 참조 하나만 는다.
    pub fn snapshot(self: Buffer) Snapshot {
        return .{ .allocator = self.allocator, .root = retain(self.root) };
    }

    /// 스냅숏이 붙든 판으로 되돌린다.
    ///
    /// **할당하지 않는다** — 참조를 맞바꿀 뿐이다. 이 성질이 이 함수의 존재 이유다: 되돌리기가
    /// 필요한 자리는 대개 **할당이 실패한 직후**이고, 거기서 또 할당하면 되돌리기 자체가 실패한다.
    /// rope가 persistent라서 공짜로 얻는 것이고(옛 노드가 그대로 살아 있다), 슬라이스 하나였다면
    /// 편집 전 내용을 통째로 복사해 두어야 했다.
    ///
    /// **스냅숏을 가져간다** — 되돌린 뒤 `deinit`을 부르면 이중 해제다.
    pub fn restore(self: *Buffer, snap: Snapshot) void {
        release(self.allocator, self.root);
        self.root = snap.root;
    }

    /// `offset`에 `text`를 넣는다.
    ///
    /// **실패하면 문서가 그대로다.** 새 루트를 다 만든 뒤에 갈아 끼우므로 중간에 실패해도 옛 판이
    /// 온전하다 — 편집이 반쯤 적용된 상태는 만들지 않는다.
    pub fn insert(self: *Buffer, offset: usize, text: []const u8) !Edit {
        // **단언이 아니라 오류다.** `std.debug.assert`는 ReleaseFast에서 사라지므로, 그것에만
        // 기대면 **Debug에서는 패닉하고 출하 빌드에서는 조용히 망가진다.** 낡은 offset은 실제로
        // 생긴다 — §3.3의 undo 스택은 delta를 오래 들고 있고, 그 사이 외부 재로드로 문서가 짧아질
        // 수 있다. 적대적 검증(2026-08-25)이 ReleaseFast에서 범위 밖 delta가 `OutOfMemory`라는
        // 엉뚱한 이유로 막히는 것을 보였다.
        if (offset > self.root.bytes) return error.OutOfRange;
        if (text.len == 0) return .{ .start = offset, .removed = 0, .inserted = 0 };

        const parts = try splitNode(self.allocator, retain(self.root), offset);
        const left0 = parts.left;
        const right = parts.right;

        // **`x = undefined` + 살아 있는 `errdefer`를 쓰지 않는다.** 그 조합이 세그폴트를 냈다 —
        // 소유가 넘어간 뒤에도 `errdefer`가 그 변수를 읽어 쓰레기 포인터를 놓는다(적대적 검증).
        // 대신 넘긴 것과 아직 든 것을 이름으로 가른다.
        const mid = buildFrom(self.allocator, text) catch |err| {
            release(self.allocator, left0);
            release(self.allocator, right);
            return err;
        };
        // `concat`은 실패해도 `left0`·`mid`를 가져간다. 남은 것은 `right`뿐이다.
        const left = concat(self.allocator, left0, mid) catch |err| {
            release(self.allocator, right);
            return err;
        };
        // 이 `concat`이 실패하면 둘 다 그쪽이 놓는다 — 여기서 더 놓을 것이 없다.
        const root = try concat(self.allocator, left, right);

        release(self.allocator, self.root);
        self.root = root;
        return .{ .start = offset, .removed = 0, .inserted = text.len };
    }

    /// `[start, end)`를 지운다. 빈 범위는 아무것도 하지 않는다.
    pub fn delete(self: *Buffer, start: usize, end: usize) !Edit {
        if (start > end or end > self.root.bytes) return error.OutOfRange; // 위 `insert`와 같은 이유
        if (start == end) return .{ .start = start, .removed = 0, .inserted = 0 };

        const first = try splitNode(self.allocator, retain(self.root), start);
        const left = first.left;

        // `splitNode`는 실패해도 `first.right`를 가져간다 — 남은 것은 `left`뿐이다.
        const second = splitNode(self.allocator, first.right, end - start) catch |err| {
            release(self.allocator, left);
            return err;
        };
        release(self.allocator, second.left); // 지워지는 구간
        // 이 `concat`이 실패하면 `left`·`second.right` 둘 다 그쪽이 놓는다.
        const root = try concat(self.allocator, left, second.right);

        release(self.allocator, self.root);
        self.root = root;
        return .{ .start = start, .removed = end - start, .inserted = 0 };
    }

    /// `[start, end)`를 새 버퍼에 복사해 돌려준다. 호출자가 푼다.
    pub fn copyRange(self: Buffer, allocator: std.mem.Allocator, start: usize, end: usize) ![]u8 {
        return copyRangeOf(self.root, allocator, start, end);
    }

    /// 문서 전체를 이어 붙여 돌려준다. 호출자가 푼다.
    pub fn copyAll(self: Buffer, allocator: std.mem.Allocator) ![]u8 {
        return copyRangeOf(self.root, allocator, 0, self.root.bytes);
    }

    /// offset이 속한 **0-based 논리 줄 번호**.
    ///
    /// 경계 규칙을 `line_index.lineAt`과 맞춘다 — **줄바꿈 byte 자체는 그 줄에 속한다.** 두 곳이
    /// 갈리면 같은 offset이 모듈에 따라 다른 줄을 답한다.
    pub fn lineAt(self: Buffer, offset: usize) usize {
        std.debug.assert(offset <= self.root.bytes);
        if (offset == 0) return 0;
        return newlinesBefore(self.root, offset);
    }

    /// 0-based 줄 번호의 시작 offset. 범위 밖이면 null.
    pub fn lineStart(self: Buffer, line: usize) ?usize {
        if (line >= self.lineCount()) return null;
        if (line == 0) return 0;
        return offsetAfterNewline(self.root, line);
    }

    /// 지금 트리 깊이. **재구축이 실제로 도는지 보는 창이다** — §3.0이 "편집을 누적하니 나빠진다"를
    /// 뒤집을 신호로 들었으므로, 그것을 재는 수단이 제품 코드에 있어야 한다.
    pub fn depth(self: Buffer) u8 {
        return self.root.depth;
    }
};

fn buildFrom(allocator: std.mem.Allocator, bytes: []const u8) !*Node {
    if (bytes.len <= leaf_max) return newLeaf(allocator, bytes);

    var leaves: std.ArrayList(*Node) = .empty;
    defer {
        for (leaves.items) |n| release(allocator, n);
        leaves.deinit(allocator);
    }

    var i: usize = 0;
    while (i < bytes.len) : (i += leaf_max) {
        const end = @min(i + leaf_max, bytes.len);
        // `append(try newLeaf(...))`로 적으면 append 실패 시 그 잎이 샌다 — 실측으로 확인했다.
        const leaf = try newLeaf(allocator, bytes[i..end]);
        leaves.append(allocator, leaf) catch |err| {
            release(allocator, leaf);
            return err;
        };
    }

    return foldBalanced(allocator, &leaves);
}

fn copyRangeOf(root: *Node, allocator: std.mem.Allocator, start: usize, end: usize) ![]u8 {
    std.debug.assert(start <= end);
    std.debug.assert(end <= root.bytes);

    const out = try allocator.alloc(u8, end - start);
    errdefer allocator.free(out);
    if (out.len == 0) return out;

    var written: usize = 0;
    collectInto(root, start, end, 0, out, &written);
    std.debug.assert(written == out.len);
    return out;
}

/// `node`가 문서 안 `base`에서 시작한다고 보고 `[start, end)`와 겹치는 부분을 `out`에 잇는다.
fn collectInto(node: *Node, start: usize, end: usize, base: usize, out: []u8, written: *usize) void {
    const node_end = base + node.bytes;
    if (node_end <= start or base >= end) return;

    switch (node.kind) {
        .leaf => |bytes| {
            const from = if (start > base) start - base else 0;
            const to = if (end < node_end) end - base else bytes.len;
            @memcpy(out[written.* .. written.* + (to - from)], bytes[from..to]);
            written.* += to - from;
        },
        .branch => |b| {
            collectInto(b.left, start, end, base, out, written);
            collectInto(b.right, start, end, base + b.left.bytes, out, written);
        },
    }
}

/// `offset` **앞**에 있는 `\n`의 수. 그것이 곧 0-based 줄 번호다.
///
/// 줄바꿈 byte 자체는 그 줄에 속하므로(§`Buffer.lineAt`) `\n`이 있는 자리 `p`에 대해 `offset == p`는
/// 아직 그 줄이고 `offset == p + 1`부터 다음 줄이다 — 그래서 세는 범위가 `[0, offset)`이다.
fn newlinesBefore(node: *Node, offset: usize) usize {
    var n = node;
    var remaining = offset;
    var count: usize = 0;

    while (true) {
        switch (n.kind) {
            .leaf => |bytes| return count + countNewlines(bytes[0..remaining]),
            .branch => |b| {
                if (remaining <= b.left.bytes) {
                    n = b.left;
                } else {
                    count += b.left.newlines;
                    remaining -= b.left.bytes;
                    n = b.right;
                }
            },
        }
    }
}

/// `line`번째 줄이 시작하는 offset — 즉 `line`번째 `\n` **바로 뒤**.
fn offsetAfterNewline(node: *Node, line: usize) usize {
    std.debug.assert(line >= 1);
    var n = node;
    var wanted = line; // 몇 번째 개행 뒤인가(1-based)
    var base: usize = 0;

    while (true) {
        switch (n.kind) {
            .leaf => |bytes| {
                var seen: usize = 0;
                for (bytes, 0..) |c, i| {
                    if (c != '\n') continue;
                    seen += 1;
                    if (seen == wanted) return base + i + 1;
                }
                unreachable; // 호출자가 줄 수를 확인하고 부른다
            },
            .branch => |b| {
                if (wanted <= b.left.newlines) {
                    n = b.left;
                } else {
                    wanted -= b.left.newlines;
                    base += b.left.bytes;
                    n = b.right;
                }
            },
        }
    }
}

// ── 판정자 ────────────────────────────────────────────────────────────────────
//
// **모델 대조가 중심이다.** rope의 결함은 "특정 연산이 틀린다"보다 "여러 번 하면 어긋난다"로
// 나타나므로, 단순 배열 모델과 같은 편집을 시켜 매번 내용·줄 수를 맞춘다(BUF7).

const testing = std.testing;

test "BUF1: 빈 버퍼도 한 줄이다 — line_index와 같은 규칙" {
    var buf = try Buffer.init(testing.allocator, "");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.byteLen());
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
    try testing.expectEqual(@as(usize, 0), buf.lineAt(0));
    try testing.expectEqual(@as(?usize, 0), buf.lineStart(0));
    try testing.expectEqual(@as(?usize, null), buf.lineStart(1));
}

test "BUF2: 가운데 삽입이 내용을 밀어 넣는다" {
    var buf = try Buffer.init(testing.allocator, "hello world");
    defer buf.deinit();

    const edit = try buf.insert(5, ",");
    try testing.expectEqual(@as(usize, 5), edit.start);
    try testing.expectEqual(@as(usize, 0), edit.removed);
    try testing.expectEqual(@as(usize, 1), edit.inserted);

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("hello, world", all);
}

test "BUF3: 삭제가 구간만 지운다" {
    var buf = try Buffer.init(testing.allocator, "abcdef");
    defer buf.deinit();

    const edit = try buf.delete(2, 4);
    try testing.expectEqual(@as(usize, 2), edit.removed);

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("abef", all);
}

test "BUF4: 줄 수와 줄 시작이 노드 합에서 나온다" {
    var buf = try Buffer.init(testing.allocator, "one\ntwo\nthree");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 3), buf.lineCount());
    try testing.expectEqual(@as(?usize, 0), buf.lineStart(0));
    try testing.expectEqual(@as(?usize, 4), buf.lineStart(1));
    try testing.expectEqual(@as(?usize, 8), buf.lineStart(2));
    try testing.expectEqual(@as(?usize, null), buf.lineStart(3));
}

test "BUF5: 줄바꿈 byte는 그 줄에 속한다 — line_index.lineAt과 같은 경계" {
    var buf = try Buffer.init(testing.allocator, "ab\ncd");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.lineAt(0));
    try testing.expectEqual(@as(usize, 0), buf.lineAt(2)); // '\n' 자리
    try testing.expectEqual(@as(usize, 1), buf.lineAt(3)); // 'c'
    try testing.expectEqual(@as(usize, 1), buf.lineAt(5)); // 문서 끝
}

test "BUF6: CRLF도 한 줄바꿈이고 홀로 온 CR은 줄바꿈이 아니다" {
    var crlf = try Buffer.init(testing.allocator, "a\r\nb");
    defer crlf.deinit();
    try testing.expectEqual(@as(usize, 2), crlf.lineCount());
    try testing.expectEqual(@as(?usize, 3), crlf.lineStart(1));

    var cr = try Buffer.init(testing.allocator, "a\rb");
    defer cr.deinit();
    try testing.expectEqual(@as(usize, 1), cr.lineCount());
}

test "BUF7: 무작위 편집 2천 번을 배열 모델과 대조한다" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();

    var buf = try Buffer.init(testing.allocator, "");
    defer buf.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(testing.allocator);

    // 잎 상한(1 KiB)을 넘겨 **가지를 건너는 분할·이음**을 실제로 만들려면 긴 것도 섞어야 한다.
    // 짧은 것만 넣고 지우면 문서가 잎 하나 안에 머물러 트리가 서지 않는다(실측: 369 byte, 깊이 1).
    const long_line = "L" ** 200 ++ "\n";
    const words = [_][]const u8{ "a", "bc", "def\n", "\n", "ghij", "한글", "x\ny\nz", long_line };

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (model.items.len > 0 and rand.uintLessThan(u8, 10) < 3) {
            const start = rand.uintLessThan(usize, model.items.len);
            const room = @min(model.items.len - start, 16);
            const end = start + rand.uintLessThan(usize, room + 1);
            _ = try buf.delete(start, end);
            model.replaceRange(testing.allocator, start, end - start, &.{}) catch unreachable;
        } else {
            const at = if (model.items.len == 0) 0 else rand.uintAtMost(usize, model.items.len);
            const w = words[rand.uintLessThan(usize, words.len)];
            _ = try buf.insert(at, w);
            try model.insertSlice(testing.allocator, at, w);
        }

        try testing.expectEqual(model.items.len, buf.byteLen());
    }

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings(model.items, all);

    const expected_lines = std.mem.count(u8, model.items, "\n") + 1;
    try testing.expectEqual(expected_lines, buf.lineCount());

    // 모든 줄 시작이 모델과 맞는가 — 줄 축이 내용과 따로 어긋나는 결함을 잡는다.
    var line: usize = 0;
    var scan: usize = 0;
    while (line < expected_lines) : (line += 1) {
        try testing.expectEqual(@as(?usize, scan), buf.lineStart(line));
        if (std.mem.indexOfScalarPos(u8, model.items, scan, '\n')) |p| scan = p + 1;
    }
}

test "BUF8: 편집을 누적해도 깊이가 상한 아래 머문다 — 재구축이 실제로 돈다 (§3.0 뒤집을 신호)" {
    var buf = try Buffer.init(testing.allocator, "");
    defer buf.deinit();

    // 문서 끝에 이어 붙이는 타이핑 — 가장 흔하고, 무게 기준 재구축이면 여기서 O(n)이 된다.
    var i: usize = 0;
    while (i < 80000) : (i += 1) {
        _ = try buf.insert(buf.byteLen(), "x");
    }

    try testing.expectEqual(@as(usize, 80000), buf.byteLen());

    // **이 단언이 재구축을 판정한다.** 잎 하나가 1 KiB이므로 80 KB는 잎 약 78개이고, 끝에 이어
    // 붙이는 경로는 잎이 찰 때마다 깊이를 1씩 올린다 — 재구축이 없으면 깊이가 78 언저리가 된다.
    // 32 이하라는 것은 재구축이 돌았다는 뜻이다(실측: 깊이 28, 재구축 2회).
    //
    // **깊이가 "잎 수의 로그"는 아니다.** 재구축 직후엔 로그(≈7)이지만 다음 임계까지 선형으로
    // 자란다. 보장되는 것은 **상한**이지 매 순간의 로그가 아니다 — 재기 전에는 로그라고 적었다.
    try testing.expect(buf.depth() <= 32);
}

test "BUF14: 합치기 규칙이 한 글자 타이핑을 잎 하나로 뭉친다" {
    var buf = try Buffer.init(testing.allocator, "");
    defer buf.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = try buf.insert(buf.byteLen(), "y");
    }

    try testing.expectEqual(@as(usize, 2000), buf.byteLen());
    // 잎 상한이 1 KiB이므로 합쳐지면 잎 둘, 깊이 둘이다. 합치기가 없으면 잎이 2000개가 되고
    // 재구축을 거쳐도 깊이가 로그(≈11)로 남는다 — 그래서 이 상한이 그 규칙을 판정한다.
    //
    // **BUF8은 이것을 판정하지 못한다.** 합치기를 뺀 뮤턴트에서 BUF8은 단언으로 죽는 대신
    // 10분을 넘겨도 안 끝났다(재구축이 매 32글자마다 도는 2차식). 시간으로 죽는 것은 판정이 아니다.
    try testing.expect(buf.depth() <= 4);
}

test "BUF9: 스냅숏은 뜬 시점을 붙들고 이후 편집에 흔들리지 않는다" {
    var buf = try Buffer.init(testing.allocator, "before");
    defer buf.deinit();

    var snap = buf.snapshot();
    defer snap.deinit();

    _ = try buf.insert(6, " and after");
    _ = try buf.delete(0, 6);

    const snap_bytes = try snap.copyRange(testing.allocator, 0, snap.byteLen());
    defer testing.allocator.free(snap_bytes);
    try testing.expectEqualStrings("before", snap_bytes);

    const live = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(live);
    try testing.expectEqualStrings(" and after", live);
}

test "BUF10: 스냅숏은 O(1)이다 — 내용 크기와 무관하게 노드를 복사하지 않는다" {
    const big = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'q');

    var buf = try Buffer.init(testing.allocator, big);
    defer buf.deinit();

    var snap = buf.snapshot();
    defer snap.deinit();

    // 같은 루트를 가리킨다 — 이것이 "복사하지 않는다"의 관측 가능한 형태다.
    try testing.expectEqual(buf.root, snap.root);
    try testing.expectEqual(buf.byteLen(), snap.byteLen());
}

test "BUF11: 편집은 selection offset을 §3.3 규칙대로 옮긴다" {
    const insert_edit = Edit{ .start = 5, .removed = 0, .inserted = 3 };
    try testing.expectEqual(@as(usize, 2), insert_edit.mapOffset(2)); // 앞은 그대로
    try testing.expectEqual(@as(usize, 5), insert_edit.mapOffset(5)); // 경계는 밀지 않는다
    try testing.expectEqual(@as(usize, 13), insert_edit.mapOffset(10)); // 뒤는 밀린다

    const delete_edit = Edit{ .start = 4, .removed = 6, .inserted = 0 };
    try testing.expectEqual(@as(usize, 4), delete_edit.mapOffset(4));
    try testing.expectEqual(@as(usize, 4), delete_edit.mapOffset(7)); // 지워진 구간 안 → 시작으로 접는다
    try testing.expectEqual(@as(usize, 4), delete_edit.mapOffset(10)); // 구간 끝
    try testing.expectEqual(@as(usize, 6), delete_edit.mapOffset(12));

    // **구간 끝 경계는 대체(removed·inserted 둘 다 0이 아님)에서만 관측된다.** 순수 삭제에서는
    // `offset - removed + inserted`와 `start`가 같은 값이라 접든 밀든 구분이 안 된다 — 위 두 줄만
    // 두었을 때 경계를 `>`로 바꾼 뮤턴트가 살아남았다. 버퍼 연산은 아직 대체를 내지 않지만
    // §3.3의 delta range가 그 모양이고, 그때 이 경계가 조용히 틀리지 않게 여기서 못박는다.
    const replace_edit = Edit{ .start = 4, .removed = 6, .inserted = 2 };
    try testing.expectEqual(@as(usize, 4), replace_edit.mapOffset(7)); // 안쪽 → 접는다
    try testing.expectEqual(@as(usize, 6), replace_edit.mapOffset(10)); // 끝 → 살려서 민다
}

test "BUF12: 잎 상한을 넘는 삽입도 한 덩어리로 남지 않는다" {
    var buf = try Buffer.init(testing.allocator, "");
    defer buf.deinit();

    const chunk = try testing.allocator.alloc(u8, leaf_max * 5);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'z');

    _ = try buf.insert(0, chunk);
    try testing.expectEqual(leaf_max * 5, buf.byteLen());
    try testing.expect(buf.depth() > 1); // 잎 하나로 뭉쳐 있지 않다

    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(u8, chunk, all);
}

fn refChurn(node: *Node, allocator: std.mem.Allocator, rounds: usize) void {
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const held = retain(node);
        release(allocator, held);
    }
}

test "BUF18: 참조 수가 스레드 경합에서 어긋나지 않는다 (§2.1 워커 분리의 전제)" {
    // **처음 쓴 스레드 판정자는 판정하지 못했다.** 워커가 스냅숏을 하나씩 들고 읽기만 하는 모양은
    // retain/release가 겹치는 창이 너무 좁아, 참조 수를 **비원자로 바꾼 뮤턴트가 3회 모두
    // 통과**했다(적대적 검증 2026-08-25). "찢어짐 0건"은 안전하다는 증거가 아니라 그 워크로드에서
    // 경합이 안 드러났다는 뜻이었다.
    //
    // 그래서 여기서는 **같은 노드**에 대고 여러 스레드가 retain/release를 고빈도로 친다. 원자적이지
    // 않으면 증감이 유실돼 마지막 참조 수가 1이 아니고, 그것은 조기 해제(세그폴트)나 누수가 된다.
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator, "shared node under contention");
    defer buf.deinit();

    const node = buf.root;
    const before = node.refs.load(.acquire);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, refChurn, .{ node, allocator, 50_000 });
    refChurn(node, allocator, 50_000);
    for (&threads) |*t| t.join();

    // 20만 번 오갔지만 순증감이 0이므로 참조 수는 그대로여야 한다.
    try testing.expectEqual(before, node.refs.load(.acquire));

    // 그리고 문서가 멀쩡하다 — 조기 해제됐다면 여기서 죽거나 쓰레기가 나온다.
    const all = try buf.copyAll(allocator);
    defer allocator.free(all);
    try testing.expectEqualStrings("shared node under contention", all);
}

test "BUF19: 문서 밖을 가리키는 편집은 오류로 거절한다 (단언이 아니라)" {
    // **단언은 출하 빌드에서 사라진다.** 그것에만 기대면 Debug는 패닉하고 ReleaseFast는 조용히
    // 망가지는데, 둘 다 "거절"이 아니다. 이 판정자는 **두 모드에서 같은 답**을 요구한다.
    var buf = try Buffer.init(testing.allocator, "12345");
    defer buf.deinit();

    try testing.expectError(error.OutOfRange, buf.insert(6, "x"));
    try testing.expectError(error.OutOfRange, buf.delete(0, 6));
    try testing.expectError(error.OutOfRange, buf.delete(4, 2)); // 뒤집힌 범위

    // 문서는 그대로다.
    const all = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("12345", all);

    // 경계는 유효하다 — 문서 끝에 붙이는 것은 정상이다.
    _ = try buf.insert(5, "6");
    try testing.expectEqual(@as(usize, 6), buf.byteLen());
}

test "BUF17: 스냅숏으로 되돌리면 편집 전 판이 그대로 온다 — 할당 없이" {
    var buf = try Buffer.init(testing.allocator, "original content here");
    defer buf.deinit();

    const snap = buf.snapshot();
    _ = try buf.insert(8, " MORE");
    _ = try buf.delete(0, 8);

    const edited = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings(" MORE content here", edited);

    // **되돌리기는 실패할 수 없다** — 오류 집합이 없다는 것이 곧 그 계약이다.
    buf.restore(snap);

    const back = try buf.copyAll(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("original content here", back);
}

test "BUF15: 할당이 어디서 실패해도 죽지 않고 문서가 그대로다" {
    // **BUF1~14가 이 축을 하나도 안 봤다.** 적대적 검증이 여기서 세그폴트를 찾았다 —
    // `concat`이 어떤 실패 경로에서는 입력을 놓고 어떤 경로에서는 안 놓는데 호출자가 `errdefer`로
    // 또 놓았고, `x = undefined` 뒤에도 그 `errdefer`가 살아 있어 쓰레기 포인터를 놓았다.
    //
    // 이 판정자는 **실패 지점을 하나씩 밀며** ⑴ 죽지 않는가 ⑵ 실패했으면 내용이 편집 전 그대로인가
    // ⑶ 새지 않는가(`FailingAllocator`가 뒤에서 검사한다)를 본다.
    const original = "aaaa bbbb cccc dddd eeee";
    var idx: usize = 0;
    while (idx < 80) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
        const a = failing.allocator();

        var buf = Buffer.init(a, original) catch continue;
        defer buf.deinit();

        if (buf.insert(10, "INSERTED TEXT HERE")) |_| {} else |_| {
            const after = buf.copyAll(testing.allocator) catch continue;
            defer testing.allocator.free(after);
            try testing.expectEqualStrings(original, after);
        }
        if (buf.delete(2, 9)) |_| {} else |_| {}
    }
}

test "BUF16: 잎을 여럿 거치는 편집도 실패 지점 전부에서 안전하다" {
    // 잎 하나에 들어가는 문서는 `concat`의 합치기 규칙만 타고 **가지 분할·재구축 경로를 안 밟는다**.
    // 실패 주입이 그 경로를 덮으려면 문서가 잎 상한을 넘어야 한다.
    const big = try testing.allocator.alloc(u8, leaf_max * 6);
    defer testing.allocator.free(big);
    @memset(big, 'q');

    var idx: usize = 0;
    while (idx < 120) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
        const a = failing.allocator();

        var buf = Buffer.init(a, big) catch continue;
        defer buf.deinit();

        const before = buf.byteLen();
        if (buf.insert(leaf_max * 3, "MIDDLE")) |_| {} else |_| {
            try testing.expectEqual(before, buf.byteLen());
        }
        if (buf.delete(leaf_max, leaf_max * 2)) |_| {} else |_| {}
    }
}

test "BUF13: 부분 복사가 경계를 정확히 집는다" {
    var buf = try Buffer.init(testing.allocator, "0123456789");
    defer buf.deinit();
    // 잎을 여러 개로 쪼개 가지를 건너는 복사를 만든다.
    _ = try buf.insert(5, "abcde");

    const mid = try buf.copyRange(testing.allocator, 3, 9);
    defer testing.allocator.free(mid);
    try testing.expectEqualStrings("34abcd", mid);

    const empty = try buf.copyRange(testing.allocator, 4, 4);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
