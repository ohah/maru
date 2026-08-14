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

/// 편집 횟수 상한(보조 손잡이). **실질 상한은 이것이 아니라 `max_trace_bytes`에서 역산된 D다** —
/// 둘 중 작은 쪽이 걸린다. 임의의 상수는 메모리를 막지 못하므로(6.4 GB짜리 trace를 허용했다) 상한의
/// 근거를 메모리로 옮겼고, 이 값은 테스트가 작은 상한을 주입할 때만 의미가 있다.
pub const default_max_edits: usize = 20_000; // 실질 상한은 `max_trace_bytes`에서 역산된 D다(아래).

pub const Options = struct {
    max_edits: usize = default_max_edits,
};

/// 두 줄 배열의 대응을 만든다. 호출자가 `Rows`를 해제한다.
///
/// **`unchanged`를 문자열 비교로 판정하지 않는다.** 대응 결과의 변경 행이 0인지로 본다 — 같은 뜻이면서,
/// 줄 분할이 달랐던 경우(끝 개행 유무)를 "변경 있음"으로 정직하게 남긴다.
///
/// **줄을 무엇으로 볼지는 호출자가 정하고, 그 선택이 목록과의 일치를 좌우한다.** 이 함수는 받은 배열만
/// 본다. 개행을 떼고 넘기면 `"a\nb\n"`와 `"a\nb"`가 **같은 배열**이 되어 여기서는 "변경 없음"이 나오는데,
/// 같은 파일에 git은 `+1 -1`을 낸다(끝 개행 제거는 마지막 줄의 변경이다). CRLF도 같다 — `\r`를 떼면
/// 우리는 "변경 없음", git은 `+2 -2`다. **줄 끝 문자를 줄에 포함해 넘기면** 둘 다 git과 맞는다
/// (아래 테스트가 두 경우를 나란히 고정한다). 표시할 때 떼는 것은 뷰의 몫이다.
pub fn compute(
    allocator: std.mem.Allocator,
    left_lines: []const []const u8,
    right_lines: []const []const u8,
    opts: Options,
) error{OutOfMemory}!View {
    // **양 끝의 같은 줄을 먼저 떼어 낸다.** Myers의 비용은 차이의 양(D)에 붙으므로, 큰 파일에서 몇 줄만
    // 바뀐 흔한 경우가 이 한 줄로 거의 공짜가 된다(diff 구현들이 공통으로 쓰는 전처리다). 결과(대응)는 바뀌지 않는다 —
    // 떼어 낸 줄들은 정의상 context다.
    var head: usize = 0;
    while (head < left_lines.len and head < right_lines.len and
        std.mem.eql(u8, left_lines[head], right_lines[head])) : (head += 1)
    {}
    var tail: usize = 0;
    while (tail < left_lines.len - head and tail < right_lines.len - head and
        std.mem.eql(u8, left_lines[left_lines.len - 1 - tail], right_lines[right_lines.len - 1 - tail])) : (tail += 1)
    {}
    const core_left = left_lines[head .. left_lines.len - tail];
    const core_right = right_lines[head .. right_lines.len - tail];

    const script = try scriptFor(allocator, core_left, core_right, opts.max_edits, head, tail);
    defer if (script) |sc| allocator.free(sc);
    if (script == null) return .{ .unavailable = .too_large };
    const ops = script.?;

    var left: std.ArrayList(Row) = .empty;
    errdefer left.deinit(allocator);
    var right: std.ArrayList(Row) = .empty;
    errdefer right.deinit(allocator);

    var li: u32 = 0;
    var ri: u32 = 0;
    var changed: usize = 0;
    var i: usize = 0;
    while (i < ops.len) {
        switch (ops[i]) {
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
                while (j < ops.len and ops[j] != .equal) : (j += 1) {
                    switch (ops[j]) {
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
    // **두 슬라이스를 한 리터럴에서 넘기지 않는다.** `toOwnedSlice`가 성공하는 순간 소유권이 리스트를
    // 떠나므로, 왼쪽이 성공하고 오른쪽이 OOM이면 위의 `errdefer left.deinit`은 이미 빈 리스트를 해제한다 —
    // 넘어간 슬라이스가 샌다. 하나씩 받아서 각자 errdefer를 건다.
    //
    // 지금 allocator에서는 이 경로가 실행되지 않는다(축소 `remap`이 성공해 재할당이 없어, 실패 주입
    // 테스트로 이 형태를 되돌려도 통과한다). 그래도 계약은 실패할 수 있는 함수이므로 방어를 남긴다.
    const left_rows = try left.toOwnedSlice(allocator);
    errdefer allocator.free(left_rows);
    const right_rows = try right.toOwnedSlice(allocator);
    return .{ .compare = .{ .left = left_rows, .right = right_rows, .changed = changed } };
}

// ── Myers ───────────────────────────────────────────────────────────────────────

const Op = enum { equal, delete, insert };

/// 떼어 낸 접두/접미를 다시 붙여 **문서 전체**의 편집 스크립트를 만든다. 상한을 넘으면 `null`.
fn scriptFor(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    max_edits: usize,
    head: usize,
    tail: usize,
) error{OutOfMemory}!?[]Op {
    // **한쪽이 비면 Myers가 필요 없다.** 새 파일·삭제된 파일이 그 경우이고, 에이전트 변경에서 가장 흔하다.
    // 이것을 특수화하지 않으면 3,000줄 새 파일이 D=3,000짜리 탐색을 돌아 메모리를 수백 MB 먹는다(실측).
    if (a.len == 0 or b.len == 0) {
        const total = head + a.len + b.len + tail;
        const out = try allocator.alloc(Op, total);
        var i: usize = 0;
        while (i < head) : (i += 1) out[i] = .equal;
        for (a) |_| {
            out[i] = .delete;
            i += 1;
        }
        for (b) |_| {
            out[i] = .insert;
            i += 1;
        }
        while (i < total) : (i += 1) out[i] = .equal;
        return out;
    }

    const core = myers(allocator, a, b, max_edits) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyEdits => return null,
    };
    defer allocator.free(core);

    const out = try allocator.alloc(Op, head + core.len + tail);
    @memset(out[0..head], .equal);
    @memcpy(out[head .. head + core.len], core);
    @memset(out[head + core.len ..], .equal);
    return out;
}

/// 줄 단위 Myers(O(N·D) 시간). 되짚기용 trace를 D단계마다 저장하므로 **메모리는 O(D²)**다.
///
/// **왜 Myers인가**: git의 xdiff도 Myers 계열이라 **최소 편집 횟수가 같다** — 목록의 `+N -N`(numstat)과
/// 우리 결과의 변경 줄 수가 어긋나지 않는다(§7, 실측 대조 테스트가 그것을 고정한다). 다른 것은 경계
/// 위치뿐이고 그 차이는 §7이 한계로 적었다.
///
/// **상한은 메모리에서 역산한다.** 예전에는 편집 횟수에 임의의 상수(20,000)를 두었는데, 그 값이면
/// trace가 **6.4 GB**(= (D+1)(2D+3)·8B)가 되어 상한이 아무것도 막지 못했다. 실측으로도 확인했다 —
/// 1,500줄 전면 재작성(D=3,000)의 **피크 할당이 128~256 MiB**였다(allocator 한도를 걸어 이분 탐색).
/// 지금은 예산(`max_trace_bytes`)에서 D를 역산하므로 상한이 실제로 메모리를 막는다.
///
/// **남은 한계**: 전면 재작성처럼 D가 큰 경우는 여전히 "보여 줄 수 없음"이다. 선형 공간 Myers
/// (middle snake 분할 정복)를 쓰면 O(N+M) 공간으로 그것까지 그릴 수 있다 — 그 교체는 이 계약을
/// 바꾸지 않으므로(같은 최소 스크립트) 필요해질 때 안에서 갈아 끼운다.
fn myers(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    max_edits: usize,
) error{ OutOfMemory, TooManyEdits }![]Op {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const budget_d = maxDForBudget(max_trace_bytes);
    const max_d: isize = @intCast(@min(@min(max_edits, budget_d), a.len + b.len));

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
        // **자리를 먼저 잡고 복사한다.** `append(dupe(...))`로 쓰면 복사는 성공하고 append가 OOM일 때
        // 그 복사본에 주인이 없다(할당 실패 주입 테스트가 잡았다).
        try trace.ensureUnusedCapacity(allocator, 1);
        trace.appendAssumeCapacity(try allocator.dupe(isize, v));
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

/// trace가 쓸 수 있는 최대 바이트. **이 값이 실질 상한이다** — D는 여기서 역산된다.
///
/// 64 MiB면 D ≈ 2,000(줄 2,000개가 통째로 바뀌는 규모)까지 그린다. 그보다 큰 차이는 "보여 줄 수 없음"이고,
/// 그것이 **수 GB를 잡고 죽는 것보다 낫다**. 숫자는 잠정이며 선형 공간 Myers가 들어오면 사라진다.
pub const max_trace_bytes: usize = 64 << 20;

/// trace 메모리 `(D+1)·(2D+3)·8B`가 예산에 들어가는 최대 D.
fn maxDForBudget(bytes: usize) usize {
    var lo: usize = 0;
    var hi: usize = 100_000;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        const need = (mid + 1) *| (2 * mid + 3) *| @sizeOf(isize);
        if (need <= bytes) lo = mid else hi = mid - 1;
    }
    return lo;
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

/// 좌·우 **양쪽**에 거는 불변식. 한쪽만 보면 반대쪽이 깨져도 통과한다 — 실제로 적대적 검증에서
/// "왼쪽 filler에 번호를 붙이는" 뮤턴트가 오른쪽만 보던 테스트를 그대로 통과했다.
fn expectRowInvariants(rows: Rows) !void {
    try testing.expectEqual(rows.left.len, rows.right.len); // 같은 인덱스 = 같은 화면 높이
    for (rows.left) |r| try expectLineMatchesKind(r);
    for (rows.right) |r| try expectLineMatchesKind(r);
    // 같은 행에서 양쪽이 동시에 filler인 자리는 없다(둘 다 비면 그 행은 존재할 이유가 없다).
    for (rows.left, rows.right) |l, r| try testing.expect(!(l.kind == .filler and r.kind == .filler));
}

fn expectLineMatchesKind(r: Row) !void {
    switch (r.kind) {
        .filler => {
            try testing.expect(r.line == null); // 없는 줄에 번호를 붙이면 거짓이다
            try testing.expectEqual(@as(usize, 0), r.text.len);
        },
        .context, .added, .removed => try testing.expect(r.line != null),
    }
}

test "할당이 어디서 실패해도 새지 않는다 — 실패 지점을 전부 주입한다" {
    // **손으로 고른 실패 지점은 놓친다.** 실제로 이 테스트가 `myers`의 누수를 잡았다 —
    // `trace.append(allocator, try allocator.dupe(...))`는 복사가 성공하고 append가 OOM일 때
    // 그 복사본을 아무도 해제하지 않는다. 눈으로 읽어서는 넘어갔던 줄이다.
    const Case = struct {
        fn run(allocator: std.mem.Allocator, left: []const []const u8, right: []const []const u8) !void {
            var v = try compute(allocator, left, right, .{});
            defer if (v == .compare) v.compare.deinit(allocator);
        }
    };
    const left: []const []const u8 = &.{ "머리", "가운데", "바뀐다", "꼬리" };
    const right: []const []const u8 = &.{ "머리", "가운데", "바뀌었다", "하나 더", "꼬리" };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{ left, right });
}

test "상한이 실제로 메모리를 막는다 — 큰 재작성에서 OOM 대신 '보여 줄 수 없음'이 나온다" {
    // **예전 상한은 아무것도 막지 못했다.** 편집 횟수에 임의의 상수를 두었는데 trace는 O(D²)라,
    // 그 값이면 수 GB가 필요했다(1,500줄 전면 재작성의 피크 할당 128~256 MiB — allocator 한도를 걸어
    // 이분 탐색으로 쟀다). 지금은 예산에서 D를 역산한다.
    //
    // **이 테스트는 "느리지 않다"가 아니라 "죽지 않는다"를 본다** — 예산보다 빠듯한 allocator를 주고,
    // OOM으로 터지지 않고 typed 상태로 빠져나오는지 확인한다.
    var da = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer _ = da.deinit();
    da.requested_memory_limit = max_trace_bytes + (16 << 20); // 예산 + 여유
    const a = da.allocator();

    const n = 4000; // 예산이 감당하는 D(≈2,000)를 훌쩍 넘는 전면 재작성
    const left = try a.alloc([]const u8, n);
    defer a.free(left);
    const right = try a.alloc([]const u8, n);
    defer a.free(right);
    for (left, 0..) |*l, i| l.* = if (i % 2 == 0) "aaaa" else "bbbb";
    for (right, 0..) |*r, i| r.* = if (i % 2 == 0) "cccc" else "dddd";

    var v = try compute(a, left, right, .{});
    defer if (v == .compare) v.compare.deinit(a);
    try expectView(v, .unavailable);
    try testing.expectEqual(Unavailable.too_large, v.unavailable);
}

test "새 파일은 상한과 무관하게 그려진다 — 한쪽이 비면 Myers가 필요 없다" {
    // 에이전트 변경에서 가장 흔한 모양이다. 특수화가 없으면 3,000줄 새 파일이 D=3,000짜리 탐색을 돌아
    // 예산에 걸려 "보여 줄 수 없음"이 된다 — 정상 파일을 못 보여 주는 셈이다.
    var da = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer _ = da.deinit();
    da.requested_memory_limit = 4 << 20; // 아주 빠듯하게
    const a = da.allocator();

    const n = 3000;
    const right = try a.alloc([]const u8, n);
    defer a.free(right);
    for (right, 0..) |*r, i| r.* = if (i % 2 == 0) "line a" else "line b";

    var v = try compute(a, &.{}, right, .{});
    defer if (v == .compare) v.compare.deinit(a);
    try expectView(v, .compare);
    try testing.expectEqual(@as(usize, n), v.compare.right.len);
    for (v.compare.left) |r| try testing.expectEqual(RowKind.filler, r.kind);
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
    try expectRowInvariants(rows);
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
    try expectRowInvariants(rows);
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
    try expectRowInvariants(rows);

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
    try expectRowInvariants(rows);
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

test "git diff --numstat과 총 변경 줄 수가 같다 — §7이 그 근거로 자체 differ를 택했다" {
    // **실측 대조다.** 아래 기대값은 같은 내용을 실제 저장소에 넣고 `git diff --numstat`이 낸 숫자다
    // (2026-08-14, git이 준 `추가 삭제`). §7이 옛 규칙을 뒤집으며 든 근거가 *"둘 다 최소 diff라 총량이
    // 같다"*였으므로, 그 근거가 실제로 성립하는지를 여기서 고정한다. 어긋나면 §7의 판단이 틀린 것이다.
    //
    // 케이스는 **총량이 갈릴 만한 자리**로 골랐다: 이동된 블록·중복 줄·전면 재작성·접두접미 동일.
    const Case = struct {
        name: []const u8,
        a: []const []const u8,
        b: []const []const u8,
        git_added: usize,
        git_removed: usize,
    };
    const cases = [_]Case{
        .{ .name = "가운데 치환", .a = &.{ "keep", "old", "tail", "" }, .b = &.{ "keep", "new", "tail", "" }, .git_added = 1, .git_removed = 1 },
        .{ .name = "블록 이동", .a = &.{ "A", "B", "C", "D", "" }, .b = &.{ "C", "D", "A", "B", "" }, .git_added = 2, .git_removed = 2 },
        .{ .name = "중복 줄", .a = &.{ "x", "x", "x", "y", "" }, .b = &.{ "x", "y", "x", "x", "" }, .git_added = 1, .git_removed = 1 },
        .{ .name = "전면 재작성", .a = &.{ "1", "2", "3", "" }, .b = &.{ "a", "b", "c", "" }, .git_added = 3, .git_removed = 3 },
        .{ .name = "접두접미 동일", .a = &.{ "h", "m1", "m2", "t", "" }, .b = &.{ "h", "m2", "m1", "t", "" }, .git_added = 1, .git_removed = 1 },
    };
    for (cases) |c| {
        var v = try compute(testing.allocator, c.a, c.b, .{});
        defer if (v == .compare) v.compare.deinit(testing.allocator);
        try testing.expect(v == .compare);
        var added: usize = 0;
        var removed: usize = 0;
        for (v.compare.left) |r| removed += @intFromBool(r.kind == .removed);
        for (v.compare.right) |r| added += @intFromBool(r.kind == .added);
        testing.expectEqual(c.git_added, added) catch |e| {
            std.debug.print("[{s}] 추가: git={d} 우리={d}\n", .{ c.name, c.git_added, added });
            return e;
        };
        testing.expectEqual(c.git_removed, removed) catch |e| {
            std.debug.print("[{s}] 삭제: git={d} 우리={d}\n", .{ c.name, c.git_removed, removed });
            return e;
        };
    }
}

test "줄 끝 문자를 줄에 포함해야 git과 맞는다 — 떼고 넘기면 목록과 본문이 정면으로 어긋난다" {
    // **이것이 §7이 막으려던 모순의 마지막 구멍이다.** 목록은 `git diff --numstat`을 그리고 본문은 여기를
    // 그리는데, 줄 분할이 다르면 두 숫자가 갈린다. 아래 기대값은 실제 git이 낸 값이다(2026-08-14).
    //
    // ① 끝 개행 제거: git `+1 -1`.
    {
        // 개행을 떼고 넘긴 경우 — **함정**. 두 배열이 같아져 "변경 없음"이 된다.
        const stripped_a = [_][]const u8{ "a", "b" };
        const stripped_b = [_][]const u8{ "a", "b" };
        var v = try compute(testing.allocator, &stripped_a, &stripped_b, .{});
        defer if (v == .compare) v.compare.deinit(testing.allocator);
        try expectView(v, .unchanged); // git은 +1 -1 — 어긋난다

        // 줄 끝 문자를 포함해 넘긴 경우 — git과 같다.
        const kept_a = [_][]const u8{ "a\n", "b\n" };
        const kept_b = [_][]const u8{ "a\n", "b" };
        var v2 = try compute(testing.allocator, &kept_a, &kept_b, .{});
        defer if (v2 == .compare) v2.compare.deinit(testing.allocator);
        try expectView(v2, .compare);
        var removed: usize = 0;
        var added: usize = 0;
        for (v2.compare.left) |r| removed += @intFromBool(r.kind == .removed);
        for (v2.compare.right) |r| added += @intFromBool(r.kind == .added);
        try testing.expectEqual(@as(usize, 1), removed);
        try testing.expectEqual(@as(usize, 1), added);
    }

    // ② LF → CRLF: git `+2 -2`.
    {
        const kept_a = [_][]const u8{ "a\n", "b\n" };
        const kept_b = [_][]const u8{ "a\r\n", "b\r\n" };
        var v = try compute(testing.allocator, &kept_a, &kept_b, .{});
        defer if (v == .compare) v.compare.deinit(testing.allocator);
        try expectView(v, .compare);
        var removed: usize = 0;
        var added: usize = 0;
        for (v.compare.left) |r| removed += @intFromBool(r.kind == .removed);
        for (v.compare.right) |r| added += @intFromBool(r.kind == .added);
        try testing.expectEqual(@as(usize, 2), removed);
        try testing.expectEqual(@as(usize, 2), added);
    }
}

/// 브루트포스 편집 거리(삽입·삭제만, 교체 없음). **작은 입력에서만** 쓴다 — O(N·M) DP다.
/// Myers가 내는 D와 이 값이 다르면 우리 스크립트가 최소가 아니라는 뜻이고, 그러면 §7의 근거
/// ("git과 총량이 같다")가 무너진다.
fn bruteForceEditDistance(a: []const []const u8, b: []const []const u8, buf: []usize) usize {
    const w = b.len + 1;
    for (0..a.len + 1) |i| {
        for (0..b.len + 1) |j| {
            buf[i * w + j] = if (i == 0) j else if (j == 0) i else if (std.mem.eql(u8, a[i - 1], b[j - 1]))
                buf[(i - 1) * w + (j - 1)]
            else
                1 + @min(buf[(i - 1) * w + j], buf[i * w + (j - 1)]);
        }
    }
    return buf[a.len * w + b.len];
}

test "우리 대응이 정말 최소다 — 브루트포스 편집 거리와 대조(무작위 300쌍)" {
    // **지금까지는 총량을 git과만 맞춰 봤다.** git도 같은 계열이라, 둘이 함께 틀리면 대조가 통과한다.
    // 여기서는 독립적인 판정자(삽입·삭제만 쓰는 DP)를 두고 편집 횟수가 같은지 본다 — 다르면 우리
    // 스크립트가 최소가 아니고, §7이 자체 differ를 택한 근거가 무너진다.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x31D);
    const rnd = prng.random();
    var case_i: usize = 0;
    while (case_i < 300) : (case_i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        // 어휘를 아주 작게 잡는다 — 같은 줄이 자주 겹쳐야 대응이 헷갈리는 모양이 나온다.
        const vocab = [_][]const u8{ "a", "b", "c" };
        const na = rnd.uintLessThan(usize, 9);
        const nb = rnd.uintLessThan(usize, 9);
        const left = try alloc.alloc([]const u8, na);
        const right = try alloc.alloc([]const u8, nb);
        for (left) |*l| l.* = vocab[rnd.uintLessThan(usize, vocab.len)];
        for (right) |*r| r.* = vocab[rnd.uintLessThan(usize, vocab.len)];

        const v = try compute(alloc, left, right, .{});
        var ours: usize = 0;
        switch (v) {
            .compare => |rows| {
                for (rows.left) |r| ours += @intFromBool(r.kind == .removed);
                for (rows.right) |r| ours += @intFromBool(r.kind == .added);
            },
            .unchanged => ours = 0,
            else => continue,
        }
        const buf = try alloc.alloc(usize, (na + 1) * (nb + 1));
        const best = bruteForceEditDistance(left, right, buf);
        try testing.expectEqual(best, ours);
    }
}

test "행을 되돌리면 두 원문이 그대로 나온다 — 무작위 200쌍" {
    // **지금까지의 테스트는 전부 손으로 고른 예제였다.** 고른 사람이 생각하지 못한 모양은 검사되지 않는다.
    // 여기서는 결과가 무엇이든 반드시 참이어야 하는 것만 본다 —
    //   ① 왼쪽 행에서 filler를 빼고 이으면 왼쪽 원문이다(줄 순서·내용 그대로),
    //   ② 오른쪽도 마찬가지,
    //   ③ 두 행 배열의 길이가 같고,
    //   ④ 줄 번호는 각 문서에서 1씩 증가한다,
    //   ⑤ 같은 자리에 removed 없이 filler만 오는 일이 없다(짝이 어긋난 자리).
    // 하나라도 깨지면 화면에 **틀린 대응**이 그려진다 — 빈 화면보다 나쁜 실패다.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(0xD1FF);
    const rnd = prng.random();
    var case_i: usize = 0;
    while (case_i < 200) : (case_i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        // 같은 줄이 자주 겹치도록 어휘를 작게 잡는다 — 대응이 헷갈리는 모양이 여기서 나온다.
        const vocab = [_][]const u8{ "a", "b", "c", "", "  ", "긴 줄 하나" };
        const na = rnd.uintLessThan(usize, 12);
        const nb = rnd.uintLessThan(usize, 12);
        const left = try alloc.alloc([]const u8, na);
        const right = try alloc.alloc([]const u8, nb);
        for (left) |*l| l.* = vocab[rnd.uintLessThan(usize, vocab.len)];
        for (right) |*r| r.* = vocab[rnd.uintLessThan(usize, vocab.len)];

        const v = try compute(alloc, left, right, .{});
        if (v != .compare) continue; // unchanged / too_large는 이 불변식의 대상이 아니다

        const rows = v.compare;
        try testing.expectEqual(rows.left.len, rows.right.len);

        var li: usize = 0;
        var ri: usize = 0;
        for (rows.left, rows.right) |lr, rr| {
            if (lr.kind != .filler) {
                try testing.expect(li < left.len);
                try testing.expectEqualStrings(left[li], lr.text);
                try testing.expectEqual(@as(?u32, @intCast(li + 1)), lr.line);
                li += 1;
            } else {
                try testing.expectEqual(@as(?u32, null), lr.line);
            }
            if (rr.kind != .filler) {
                try testing.expect(ri < right.len);
                try testing.expectEqualStrings(right[ri], rr.text);
                try testing.expectEqual(@as(?u32, @intCast(ri + 1)), rr.line);
                ri += 1;
            } else {
                try testing.expectEqual(@as(?u32, null), rr.line);
            }
            // 양쪽이 동시에 filler인 행은 아무것도 말하지 않는 빈 줄이다 — 서면 안 된다.
            try testing.expect(!(lr.kind == .filler and rr.kind == .filler));
        }
        try testing.expectEqual(left.len, li);
        try testing.expectEqual(right.len, ri);
    }
}

test "2,000줄 규모에서도 git과 같은 수를 낸다 — 작은 예제만으로는 못 믿을 주장이다" {
    // **작은 예제 다섯 개로는 §7의 근거가 서지 않는다.** 위 대조는 한두 줄짜리라 어떤 알고리즘이든
    // 같은 답을 낸다. 여기서는 반복 줄이 많은 2,000줄 파일에 200군데 수정과 60군데 삽입을 섞는다 —
    // 휴리스틱이 갈리기 쉬운 모양이다.
    //
    // 기준선은 실제 git이 같은 내용에 대해 낸 값이다(`git diff --numstat` → `250\t190`, 즉 추가 250 ·
    // 삭제 190). 내용을 여기서 **결정적으로 생성**하므로 픽스처 파일이 필요 없다.
    //
    // **주의**: numstat 열 순서는 `추가<TAB>삭제`다. 반대로 읽으면 대칭 예제에서는 티가 안 나고
    // 이런 비대칭 예제에서만 틀린다.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var a: std.ArrayList([]const u8) = .empty;
    var b: std.ArrayList([]const u8) = .empty;
    var prng = std.Random.DefaultPrng.init(20260814);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "{s}{d}", .{ if (i % 3 == 0) "y" else "x", i % 40 });
        try a.append(alloc, line);
        try b.append(alloc, line);
    }
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        const idx = rnd.uintLessThan(usize, b.items.len);
        b.items[idx] = try std.fmt.allocPrint(alloc, "CHANGED{d}", .{idx});
    }
    n = 0;
    while (n < 60) : (n += 1) {
        const idx = rnd.uintLessThan(usize, b.items.len);
        try b.insert(alloc, idx, try std.fmt.allocPrint(alloc, "INS{d}", .{idx}));
    }

    const v = try compute(alloc, a.items, b.items, .{});
    try expectView(v, .compare);
    var removed: usize = 0;
    var added: usize = 0;
    for (v.compare.left) |r| {
        if (r.kind == .removed) removed += 1;
    }
    for (v.compare.right) |r| {
        if (r.kind == .added) added += 1;
    }
    try testing.expectEqual(@as(usize, 250), added);
    try testing.expectEqual(@as(usize, 190), removed);
}

test "빈 문서 둘은 변경 없음이다" {
    var v = try compute(testing.allocator, &.{}, &.{}, .{});
    defer if (v == .compare) v.compare.deinit(testing.allocator);
    try expectView(v, .unchanged);
}
