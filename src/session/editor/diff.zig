//! diff 본문의 **줄 대응**([diff·떠 있는 UI](../../../docs/native-editor-ui.md) §7).
//!
//! **git은 내용을 주고 대응은 여기서 만든다**(2026-08-14 사용자 결정 — §7이 옛 규칙을 뒤집었다).
//! platform의 bounded `git` 호출이 비교 대상 두 쪽 **전문**을 주고, 이 모듈이 그 둘에서 좌/우로 나란한
//! 행 배열을 만든다. VSCode·Zed·JetBrains가 모두 이 모양이다 — git은 내용 출처이고 diff는 편집기 것이다.
//!
//! **줄을 나누지 않는다.** 입력은 이미 나뉜 줄 배열이다. 분할 규칙(끝 개행이 만드는 빈 줄·CRLF)은
//! `open.zig`가 소유하고, 여기서 또 나누면 같은 규칙이 두 곳에 생겨 갈린다(실제로 그 종류의 갈림이
//! 이 저장소에서 여러 번 났다).
//!
//! **L2 순수**: std만 쓴다. OS·렌더·git을 모른다.

const std = @import("std");

/// 좌/우 한 행의 종류.
pub const RowKind = enum {
    /// 양쪽에 같은 줄이 있다.
    context,
    /// 오른쪽에만 있다(추가).
    added,
    /// 왼쪽에만 있다(삭제).
    removed,
    /// **줄이 없다.** 반대쪽 행과 높이를 맞추려고 비워 두는 자리다 — 나란한 비교에서 같은 줄이 같은
    /// 높이에 있어야 하므로, 한쪽이 짧으면 그만큼 빈 행이 선다.
    filler,
};

/// 화면 한 행.
pub const Row = struct {
    kind: RowKind,
    /// **그 쪽 문서**의 줄 번호(1-based). `filler`면 없다 — 없는 줄에 번호를 붙이면 거짓이다.
    line: ?u32 = null,
    /// 줄 내용. `filler`면 빈 슬라이스다. **입력 줄을 빌린다**(복사하지 않는다) — 호출자가 두 전문을
    /// 이 결과보다 오래 들고 있어야 한다.
    text: []const u8 = "",
};

/// 나란히 놓인 좌/우 행. **`left.len == right.len`이 불변식이다** — 같은 인덱스가 같은 화면 높이다.
pub const Rows = struct {
    left: []Row,
    right: []Row,
    /// context가 아닌 행이 몇 개인가. "변경 없음" 판정과 요약에 쓴다.
    changed: usize,

    pub fn deinit(self: *Rows, allocator: std.mem.Allocator) void {
        allocator.free(self.left);
        allocator.free(self.right);
        self.* = undefined;
    }
};

/// 비교를 보여 줄 수 없는 이유. **내부 값을 그대로 노출하지 않는다**(§7) — 화면은 이 셋만 문장으로 옮긴다.
pub const Unavailable = enum {
    /// 상한을 넘었다(파일이 크거나 차이가 너무 많다).
    too_large,
    /// 텍스트가 아니다.
    binary,
    /// 그 밖(권한·사라진 파일·알 수 없는 거절). 이유를 지어내지 않는다.
    unknown,
};

/// 화면이 그릴 네 상태(§7). **판단은 여기서 끝나고 뷰는 말하기만 한다** — 그래야 도크 목록과 본문이
/// 같은 판정을 쓴다.
pub const View = union(enum) {
    /// 요청이 아직 떠 있다.
    loading,
    unavailable: Unavailable,
    /// 비교했고 다른 곳이 없다. **빈 화면이 아니라 그렇게 말한다.**
    unchanged,
    compare: Rows,
};

/// 계산 상한. 넘으면 `.unavailable = .too_large`다.
///
/// **왜 편집 횟수로 재는가.** 파일 크기가 아니라 **차이의 양**이 비용을 정한다(Myers는 O(N·D)).
/// 큰 파일이라도 몇 줄만 바뀌었으면 싸고, 작은 파일이라도 전면 재작성이면 비싸다. 그래서 줄 수가
/// 아니라 D에 상한을 둔다.
///
/// **숫자는 잠정이다.** §10이 선행 측정 게이트를 두지 않으므로 여기서 근거 없는 값을 계약처럼 굳히지
/// 않는다 — 실측이 붙는 슬라이스에서 정한다. 전면 재작성 diff가 이 값에 걸리면 화면은 "보여 줄 수
/// 없음"이 되는데, 그것이 **틀린 대응을 보여 주는 것보다 낫다**.
pub const default_max_edits: usize = 20_000;

pub const Options = struct {
    max_edits: usize = default_max_edits,
};

/// 두 줄 배열의 대응을 만든다. 호출자가 `Rows`를 해제한다.
///
/// **`unchanged`를 문자열 비교로 판정하지 않는다.** 대응 결과의 변경 행이 0인지로 본다 — 같은 뜻이면서,
/// 줄 분할이 달랐던 경우(끝 개행 유무)를 "변경 있음"으로 정직하게 남긴다.
pub fn compute(
    allocator: std.mem.Allocator,
    left_lines: []const []const u8,
    right_lines: []const []const u8,
    opts: Options,
) error{OutOfMemory}!View {
    const script = myers(allocator, left_lines, right_lines, opts.max_edits) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyEdits => return .{ .unavailable = .too_large },
    };
    defer allocator.free(script);

    var left: std.ArrayList(Row) = .empty;
    errdefer left.deinit(allocator);
    var right: std.ArrayList(Row) = .empty;
    errdefer right.deinit(allocator);

    var li: u32 = 0;
    var ri: u32 = 0;
    var changed: usize = 0;
    var i: usize = 0;
    while (i < script.len) {
        switch (script[i]) {
            .equal => {
                try left.append(allocator, .{ .kind = .context, .line = li + 1, .text = left_lines[li] });
                try right.append(allocator, .{ .kind = .context, .line = ri + 1, .text = right_lines[ri] });
                li += 1;
                ri += 1;
                i += 1;
            },
            .delete, .insert => {
                // **삭제와 추가가 붙어 있으면 한 덩어리로 짝짓는다.** 그래야 "이 줄이 저 줄로 바뀌었다"가
                // 같은 높이에 서고, 문자 단위 강조(§7)가 볼 줄 쌍도 여기서 정해진다. 짝이 남으면 filler다.
                var dels: usize = 0;
                var adds: usize = 0;
                var j = i;
                while (j < script.len and script[j] != .equal) : (j += 1) {
                    switch (script[j]) {
                        .delete => dels += 1,
                        .insert => adds += 1,
                        .equal => unreachable,
                    }
                }
                const pairs = @max(dels, adds);
                var k: usize = 0;
                while (k < pairs) : (k += 1) {
                    if (k < dels) {
                        try left.append(allocator, .{ .kind = .removed, .line = li + 1, .text = left_lines[li] });
                        li += 1;
                    } else {
                        try left.append(allocator, .{ .kind = .filler });
                    }
                    if (k < adds) {
                        try right.append(allocator, .{ .kind = .added, .line = ri + 1, .text = right_lines[ri] });
                        ri += 1;
                    } else {
                        try right.append(allocator, .{ .kind = .filler });
                    }
                }
                changed += pairs;
                i = j;
            },
        }
    }

    if (changed == 0) {
        left.deinit(allocator);
        right.deinit(allocator);
        return .unchanged;
    }
    return .{ .compare = .{
        .left = try left.toOwnedSlice(allocator),
        .right = try right.toOwnedSlice(allocator),
        .changed = changed,
    } };
}

// ── Myers ───────────────────────────────────────────────────────────────────────

const Op = enum { equal, delete, insert };

/// 줄 단위 Myers(O(N·D)). 되짚기용 trace를 D단계마다 저장한다.
///
/// **왜 Myers인가**: git의 xdiff도 Myers 계열이라 **최소 편집 횟수가 같다** — 목록의 `+N -N`(numstat)과
/// 우리 결과의 변경 줄 수가 어긋나지 않는다(§7). 다른 것은 경계 위치뿐이고, 그 차이는 §7이 한계로 적었다.
fn myers(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    max_edits: usize,
) error{ OutOfMemory, TooManyEdits }![]Op {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max_d: isize = @intCast(@min(max_edits, a.len + b.len));

    // v[k]는 대각선 k에서 가장 멀리 간 x. 음수 k를 담으려 offset을 둔다.
    // **여유 둘을 더 잡는다.** `k == -d`일 때 `v[k+1]`을 읽는데 d가 0이면 그 인덱스가 1이라, 딱 맞게
    // 잡으면 빈 문서 둘에서 배열을 넘어선다(실제로 그 테스트가 패닉으로 잡았다).
    const width: usize = @intCast(2 * max_d + 3);
    const offset: isize = max_d;
    const v = try allocator.alloc(isize, width);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit(allocator);
    }

    var d: isize = 0;
    while (d <= max_d) : (d += 1) {
        try trace.append(allocator, try allocator.dupe(isize, v));
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const idx: usize = @intCast(k + offset);
            // d == 0이면 출발점(0,0)이다 — 아래 분기는 이전 단계 값을 읽으므로 그 단계엔 쓸 수 없다.
            var x: isize = if (d == 0) 0 else if (k == -d or (k != d and v[@intCast(k - 1 + offset)] < v[@intCast(k + 1 + offset)]))
                v[@intCast(k + 1 + offset)]
            else
                v[@intCast(k - 1 + offset)] + 1;
            var y: isize = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[idx] = x;
            if (x >= n and y >= m) return backtrack(allocator, trace.items, n, m, offset);
        }
    }
    return error.TooManyEdits;
}

/// trace를 거꾸로 훑어 편집 스크립트를 만든다.
fn backtrack(
    allocator: std.mem.Allocator,
    trace: []const []isize,
    n: isize,
    m: isize,
    offset: isize,
) error{OutOfMemory}![]Op {
    var out: std.ArrayList(Op) = .empty;
    errdefer out.deinit(allocator);

    var x = n;
    var y = m;
    var d: isize = @intCast(trace.len);
    while (d > 0) {
        d -= 1;
        const v = trace[@intCast(d)];
        const k = x - y;
        const prev_k: isize = if (k == -d or (k != d and v[@intCast(k - 1 + offset)] < v[@intCast(k + 1 + offset)]))
            k + 1
        else
            k - 1;
        const prev_x = v[@intCast(prev_k + offset)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            try out.append(allocator, .equal);
            x -= 1;
            y -= 1;
        }
        if (d > 0) {
            if (x > prev_x) {
                try out.append(allocator, .delete);
                x -= 1;
            } else {
                try out.append(allocator, .insert);
                y -= 1;
            }
        }
    }
    // 거꾸로 쌓았으니 뒤집는다.
    const slice = try out.toOwnedSlice(allocator);
    std.mem.reverse(Op, slice);
    return slice;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
//
// 이 테스트들이 증명하는 것: **나란한 비교가 성립하는 조건**이다. 좌/우 길이가 같고, 줄 번호가 그 쪽
// 문서를 가리키고, filler에는 번호가 없어야 한다 — 셋 중 하나만 깨져도 리뷰어가 "몇 번째 줄이 바뀌었나"를
// 잘못 읽는다. 편집기에서 그것은 화면이 거짓을 말하는 것과 같다(§3.8의 규율이 diff에도 적용된다).

const testing = std.testing;

fn expectView(v: View, comptime tag: std.meta.Tag(View)) !void {
    try testing.expectEqual(tag, std.meta.activeTag(v));
}

test "같은 내용이면 변경 없음 — 빈 화면이 아니라 상태로 말한다" {
    const a = [_][]const u8{ "one", "two", "" };
    var v = try compute(testing.allocator, &a, &a, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .unchanged);
}

test "한쪽이 비어 있어도 대응이 선다 — 새 파일" {
    const b = [_][]const u8{ "hello", "world" };
    var v = try compute(testing.allocator, &.{}, &b, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .compare);
    const rows = v.compare;
    try testing.expectEqual(@as(usize, 2), rows.left.len);
    try testing.expectEqual(rows.left.len, rows.right.len); // 불변식
    for (rows.left) |r| try testing.expectEqual(RowKind.filler, r.kind);
    try testing.expectEqual(RowKind.added, rows.right[0].kind);
    try testing.expectEqual(@as(u32, 1), rows.right[0].line.?);
    try testing.expectEqual(@as(u32, 2), rows.right[1].line.?);
}

test "가운데 줄만 바뀌면 그 줄만 짝이 되고 나머지는 context다" {
    const a = [_][]const u8{ "keep", "old", "tail" };
    const b = [_][]const u8{ "keep", "new", "tail" };
    var v = try compute(testing.allocator, &a, &b, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .compare);
    const rows = v.compare;
    try testing.expectEqual(@as(usize, 3), rows.left.len);
    try testing.expectEqual(rows.left.len, rows.right.len);
    try testing.expectEqual(RowKind.context, rows.left[0].kind);
    // **같은 높이에 removed/added가 선다** — 그래야 "이 줄이 저 줄로 바뀌었다"로 읽힌다.
    try testing.expectEqual(RowKind.removed, rows.left[1].kind);
    try testing.expectEqual(RowKind.added, rows.right[1].kind);
    try testing.expectEqual(RowKind.context, rows.left[2].kind);
    try testing.expectEqual(@as(usize, 1), rows.changed);
}

test "줄 번호는 각자 문서를 가리키고 filler에는 없다" {
    // 왼쪽 3줄, 오른쪽 1줄 삭제 → 오른쪽 번호가 왼쪽보다 뒤처진다. 한쪽 번호를 양쪽에 쓰면 여기서 깨진다.
    const a = [_][]const u8{ "a", "gone", "b", "c" };
    const b = [_][]const u8{ "a", "b", "c" };
    var v = try compute(testing.allocator, &a, &b, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    const rows = v.compare;
    try testing.expectEqual(rows.left.len, rows.right.len);

    var saw_removed = false;
    for (rows.left, rows.right) |l, r| {
        if (l.kind == .removed) {
            saw_removed = true;
            try testing.expectEqual(RowKind.filler, r.kind);
            try testing.expect(r.line == null); // 없는 줄에 번호를 붙이지 않는다
        }
        if (l.kind == .context) try testing.expect(l.line.? >= r.line.?); // 왼쪽이 앞서거나 같다
    }
    try testing.expect(saw_removed);
    // 마지막 context의 번호가 각자 문서의 마지막 줄이다.
    try testing.expectEqual(@as(u32, 4), rows.left[rows.left.len - 1].line.?);
    try testing.expectEqual(@as(u32, 3), rows.right[rows.right.len - 1].line.?);
}

test "삭제가 추가보다 많으면 남는 쪽에 filler가 선다" {
    const a = [_][]const u8{ "x1", "x2", "x3" };
    const b = [_][]const u8{"y1"};
    var v = try compute(testing.allocator, &a, &b, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    const rows = v.compare;
    try testing.expectEqual(@as(usize, 3), rows.left.len);
    try testing.expectEqual(rows.left.len, rows.right.len);
    try testing.expectEqual(RowKind.added, rows.right[0].kind);
    try testing.expectEqual(RowKind.filler, rows.right[1].kind);
    try testing.expectEqual(RowKind.filler, rows.right[2].kind);
}

test "편집이 상한을 넘으면 보여 줄 수 없음 — 틀린 대응을 그리지 않는다" {
    var a_buf: [40][]const u8 = undefined;
    var b_buf: [40][]const u8 = undefined;
    for (&a_buf, 0..) |*l, i| l.* = if (i % 2 == 0) "a" else "b";
    for (&b_buf, 0..) |*l, i| l.* = if (i % 2 == 0) "c" else "d";
    var v = try compute(testing.allocator, &a_buf, &b_buf, .{ .max_edits = 4 });
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .unavailable);
    try testing.expectEqual(Unavailable.too_large, v.unavailable);
}

test "총 변경 줄 수가 최소 편집 횟수와 같다 — 목록의 +N -N과 어긋나지 않는다" {
    // §7: 목록은 `git diff --numstat`이 준 최소 편집 횟수를 그린다. 우리도 최소를 내므로 총량이 같아야
    // 한다(경계 위치는 다를 수 있다). 여기서는 **우리 결과 안에서** 그 총량을 센다.
    const a = [_][]const u8{ "1", "2", "3", "4" };
    const b = [_][]const u8{ "1", "9", "3", "4", "5" };
    var v = try compute(testing.allocator, &a, &b, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    const rows = v.compare;
    var removed: usize = 0;
    var added: usize = 0;
    for (rows.left) |r| removed += @intFromBool(r.kind == .removed);
    for (rows.right) |r| added += @intFromBool(r.kind == .added);
    try testing.expectEqual(@as(usize, 1), removed); // "2" 하나
    try testing.expectEqual(@as(usize, 2), added); // "9"와 "5"
}

test "빈 문서 둘은 변경 없음이다" {
    var v = try compute(testing.allocator, &.{}, &.{}, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .unchanged);
}
