//! 편집 가능한 문서 — 버퍼(§3.0)와 **소비처가 요구하는 평탄한 축**을 한 자리에 묶는다
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.1·§3.5).
//!
//! `open.zig`는 읽기 전용이다 — 호출자가 준 bytes를 **빌려** 쓰고 인덱스를 얹는다. 편집이 들어오면
//! 빌린 것을 고칠 수 없으므로 문서가 자기 내용을 **소유**해야 하고, 그 소유자가 `buffer.Buffer`다.
//!
//! ## 평탄화 축을 두는 이유와 그 대가
//!
//! rope는 편집을 `O(log n)`에 하지만, **지금 있는 소비처는 전부 `[]const u8` 하나를 요구한다** —
//! hit-test·검색·§4.2 표시 폭·§3.8 가시화·복사가 모두 그 모양으로 짜여 있다. 그래서 편집한 뒤
//! 트리를 한 번 훑어 평탄한 복사본을 만들고, 줄 인덱스도 다시 세운다.
//!
//! **그 비용은 편집마다 문서 크기에 비례한다.** rope를 고른 이유의 절반이 여기서 상쇄되는 것이
//! 맞고, 숨기지 않는다. 소비처를 트리로 옮기는 것은 별도 슬라이스다 — 41곳이 이 축을 읽고 있고,
//! 한꺼번에 바꾸면 이 슬라이스가 무엇을 깼는지 말할 수 없게 된다. `Snapshot`은 평탄화와 무관하게
//! `O(1)`이므로 §2.1 워커 분리의 전제는 그대로다.
//!
//! ### 실측이 예상을 뒤집었다 (ReleaseFast, 편집 1회 평균)
//!
//! | 문서 | rope 편집 | 평탄화 | 줄 인덱스 |
//! |---|---|---|---|
//! | 256 KiB | 56µs | 18µs | 56µs |
//! | 1 MiB | 58µs | 68µs | **290µs** |
//!
//! **비싼 것은 평탄화가 아니라 줄 인덱스 재구축이다.** 처음에 이 절은 *"memcpy는 싸니 괜찮다"*고
//! 적었는데, 갈라 재 보니 1 MiB에서 줄 인덱스가 **1178µs**로 나머지를 합친 것의 다섯 배였다.
//! 그래서 `line_index.build`를 고쳤다(줄바꿈을 byte 하나씩 세지 않고 `indexOfScalarPos`로 건너뛰며
//! 찾고, 줄 수를 먼저 세어 배열을 한 번에 잡는다) — **1178 → 290µs**.
//!
//! **그래도 문서 크기에 비례한다.** 1 MiB에서 편집 1회가 약 0.4ms(60fps 예산의 2.5%)이고 4 MiB면
//! 1.6ms다. §3.0이 "타이핑이 프레임 예산을 넘는다"를 뒤집을 신호로 들었으므로 **`EDOC7`이 그 수를
//! 계속 낸다** — 볼 수 없으면 신호를 관측할 수 없다. 다음 걸음은 **줄 인덱스 증분 갱신**이다
//! (편집 뒤 줄들은 시작 offset이 같은 양만큼 밀릴 뿐이라 다시 훑을 필요가 없다).
//!
//! **Debug에서는 50배 느리다**(256 KiB에서 8.5ms). 위 수는 전부 ReleaseFast이며, 제품이 도는
//! 모드가 그쪽이다.
//!
//! ## `line_index`가 남는 이유
//!
//! 트리는 줄 **수**와 줄 **시작**을 `O(log n)`에 답하지만 줄별 `LineEnding`(§3.5 원본 보존)은
//! 답하지 않는다 — `\r\n`인지 `\n`인지는 노드 합으로 나오지 않는다. §3.0이 *"부분 잔존은 이미
//! 예상된다"*고 적은 그대로다.

const std = @import("std");
const builtin = @import("builtin");
const buffer = @import("buffer.zig");
const delta = @import("delta.zig");
const document = @import("document.zig");
const line_index = @import("line_index.zig");
const selection = @import("selection.zig");

pub const OpenError = document.OpenError || std.mem.Allocator.Error;

/// 편집 가능한 파일 하나. **내용을 소유한다** — 호출자가 준 bytes는 `init`이 끝나면 놓아도 된다.
///
/// 필드 이름이 `open.OpenFile`과 다른 자리가 셋 있다(`content`·`format`·`read_only`가 `doc.` 없이
/// 바로 있다). 문서 속성과 내용이 **같은 소유자**에게 있기 때문이고, 그 중간 단계를 남겨 두면
/// "어느 것이 진짜 내용인가"가 둘이 된다.
pub const EditableFile = struct {
    allocator: std.mem.Allocator,
    /// 내용의 정본.
    buf: buffer.Buffer,
    /// 저장할 때 되돌려야 하는 파일 속성(§3.5).
    format: document.FileFormat,
    read_only: bool,
    /// **평탄화 축** — 소비처가 읽는 것. `buf`에서 파생되며 편집마다 다시 만든다.
    content: []u8,
    /// 줄 경계 표. 편집마다 다시 세운다.
    lines: line_index.LineIndex,
    /// 편집 횟수. **dirty 판정이 아니다**(그것은 내용 동등성이 정한다 — `file-panel.md` §1).
    /// 파생 캐시가 낡았는지 보는 쪽이 쓴다.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, read_only: bool) OpenError!EditableFile {
        const doc = try document.open(bytes, read_only);

        var buf = try buffer.Buffer.init(allocator, doc.content);
        errdefer buf.deinit();

        const content = try allocator.dupe(u8, doc.content);
        errdefer allocator.free(content);

        const lines = try line_index.build(allocator, content);
        return .{
            .allocator = allocator,
            .buf = buf,
            .format = doc.format,
            .read_only = read_only,
            .content = content,
            .lines = lines,
        };
    }

    pub fn deinit(self: *EditableFile) void {
        self.lines.deinit();
        self.allocator.free(self.content);
        self.buf.deinit();
        self.* = undefined;
    }

    pub fn lineCount(self: EditableFile) usize {
        return self.lines.lineCount();
    }

    /// 화면에 그릴 줄 하나의 **내용**(줄바꿈 제외). 범위를 넘으면 `null`.
    ///
    /// `open.OpenFile.lineText`와 같은 계약이다 — 줄바꿈이 들어가면 §3.8 가시화가 그것을
    /// `<U+000A>`로 그려 화면이 어지러워진다.
    pub fn lineText(self: EditableFile, index: usize) ?[]const u8 {
        const l = self.lines.line(index) orelse return null;
        return self.content[l.start..l.contentEnd()];
    }

    /// 편집을 적용한다 — 버퍼·평탄화 축·줄 인덱스·selection이 **한 연산에서** 함께 움직인다(§3.3).
    ///
    /// **실패하면 문서가 그대로다.** 새 평탄화 축과 새 줄 인덱스를 다 만든 뒤에 갈아 끼운다 —
    /// 중간에 실패해 "버퍼는 바뀌었는데 화면이 읽는 축은 옛것"인 상태를 만들지 않는다. 그 상태는
    /// 조용하다: 렌더가 낡은 offset으로 슬라이스를 떠서 **틀린 글자를 그리거나 범위를 넘는다**.
    ///
    /// **읽기 전용 문서는 거절한다.** 쓸 수 없는 파일도 열지만(§3.5 "보는 것은 되어야 한다") 고칠
    /// 수는 없고, 여기서 막지 않으면 화면만 바뀌고 저장이 실패해 사용자가 편집을 잃는다.
    pub fn apply(
        self: *EditableFile,
        d: delta.Delta,
        selections: *selection.Selections,
    ) (error{ReadOnly} || std.mem.Allocator.Error)!delta.Inverse {
        if (self.read_only) return error.ReadOnly;

        // **편집 전 판을 떠 둔다.** 아래 파생 축 재구축이 실패하면 버퍼만 앞서 나가는데, 그러면
        // 정본과 화면이 읽는 축이 갈린다 — 이 함수의 머리말이 "만들지 않는다"고 적은 그 상태다.
        // 적대적 검증이 `fail_index=12`에서 실제로 그것을 만들어 보였다(2026-08-24).
        const snap = self.buf.snapshot();
        var inverse = delta.apply(self.allocator, &self.buf, d, selections) catch |err| {
            var undone = snap;
            undone.deinit();
            return err;
        };

        // 버퍼는 이미 바뀌었다. 파생 축을 새로 만들되, **둘 다 성공했을 때만** 갈아 끼운다.
        const next_content = self.buf.copyAll(self.allocator) catch |err| {
            self.rollback(snap, &inverse, selections);
            return err;
        };
        const next_lines = line_index.build(self.allocator, next_content) catch |err| {
            self.allocator.free(next_content);
            self.rollback(snap, &inverse, selections);
            return err;
        };
        {
            // 성공 — 옛 판을 놓는다. `deinit`이 `*Snapshot`을 받으므로 지역 복사본을 통해 부른다.
            var done = snap;
            done.deinit();
        }

        self.lines.deinit();
        self.allocator.free(self.content);
        self.content = next_content;
        self.lines = next_lines;
        self.revision += 1;
        return inverse;
    }

    /// 편집을 되돌린다 — **할당하지 않는다.** 여기 오는 이유가 할당 실패라, 되돌리는 길에서 또
    /// 할당하면 되돌리기 자체가 실패한다.
    ///
    /// selection은 `delta.apply`가 이미 편집 **후** 축으로 옮겨 놓았다. 역연산 좌표로 되짚어
    /// 편집 전 축으로 돌리고, 지워졌던 구간 안을 가리키던 것은 접힌 자리에 남으므로 문서 길이로
    /// 한 번 더 조인다(범위를 넘은 offset은 `lineAt`이 Debug에서 밟는다).
    fn rollback(
        self: *EditableFile,
        snap: buffer.Snapshot,
        inverse: *delta.Inverse,
        selections: *selection.Selections,
    ) void {
        self.buf.restore(snap);
        const inv = inverse.delta();
        const limit = self.buf.byteLen();
        for (selections.items) |*s| {
            s.anchor_start = @min(delta.mapOffset(inv, s.anchor_start), limit);
            s.anchor_end = @min(delta.mapOffset(inv, s.anchor_end), limit);
            s.focus = @min(delta.mapOffset(inv, s.focus), limit);
        }
        inverse.deinit();
    }

    /// 지금 내용을 붙든 읽기 전용 판(§2.1 워커로 건너간다). `O(1)`이다.
    pub fn snapshot(self: EditableFile) buffer.Snapshot {
        return self.buf.snapshot();
    }
};

/// 측정 전용 단조 시계(µs). Zig 0.16 `std.time`에 `Timer`가 없어 직접 부른다 —
/// `fold.zig`·`control_bridge.monotonicMs`와 같은 관례이고, **Windows 타깃에서는 0을 낸다**
/// (`check-targets`가 이 L2 모듈을 `x86_64-windows`로도 컴파일하는데 그 타깃에 `std.c.timespec`이
/// 없다). 아래 측정은 단언이 아니라 출력이므로 0이어도 판정이 뒤집히지 않는다.
fn monotonicUs() u64 {
    if (builtin.os.tag == .windows) {
        return 0;
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
    }
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn oneCaret(items: []selection.Selection) selection.Selections {
    return selection.Selections.init(items, 0);
}

test "EDOC1: 연 직후 평탄화 축과 줄 인덱스가 원본과 같다" {
    var f = try EditableFile.init(testing.allocator, "first\nsecond\r\nthird", false);
    defer f.deinit();

    try testing.expectEqualStrings("first\nsecond\r\nthird", f.content);
    try testing.expectEqual(@as(usize, 3), f.lineCount());
    try testing.expectEqualStrings("second", f.lineText(1).?); // CRLF의 \r까지 빠진다
    try testing.expectEqual(@as(u64, 0), f.revision);
}

test "EDOC2: bytes를 빌리지 않는다 — 준 버퍼가 사라져도 문서가 산다" {
    const scratch = try testing.allocator.alloc(u8, 11);
    @memcpy(scratch, "borrowed ok");

    var f = try EditableFile.init(testing.allocator, scratch, false);
    defer f.deinit();

    // **준 버퍼를 놓는다.** `open.OpenFile`이었다면 여기서부터 문서가 해제된 메모리를 가리킨다.
    testing.allocator.free(scratch);

    try testing.expectEqualStrings("borrowed ok", f.content);
}

test "EDOC3: 편집이 버퍼·평탄화 축·줄 인덱스·selection을 함께 움직인다" {
    var f = try EditableFile.init(testing.allocator, "one\ntwo\nthree", false);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(8)}; // "three" 앞
    var sels = oneCaret(&items);

    const changes = [_]delta.Change{.{ .start = 4, .end = 7, .text = "TWO EDIT" }};
    var inv = try f.apply(.{ .changes = &changes }, &sels);
    defer inv.deinit();

    try testing.expectEqualStrings("one\nTWO EDIT\nthree", f.content);
    try testing.expectEqual(@as(usize, 3), f.lineCount());
    try testing.expectEqualStrings("TWO EDIT", f.lineText(1).?);
    try testing.expectEqual(@as(usize, 13), sels.items[0].focus); // 8 + (8-3)
    try testing.expectEqual(@as(u64, 1), f.revision);
    // 버퍼(정본)와 평탄화 축이 갈리지 않았다.
    try testing.expectEqual(f.buf.byteLen(), f.content.len);
}

test "EDOC4: 줄 수가 바뀌는 편집도 인덱스가 따라간다" {
    var f = try EditableFile.init(testing.allocator, "a\nb", false);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = oneCaret(&items);

    const add = [_]delta.Change{.{ .start = 1, .end = 1, .text = "\nmid\n" }};
    var inv = try f.apply(.{ .changes = &add }, &sels);
    defer inv.deinit();
    try testing.expectEqual(@as(usize, 4), f.lineCount());
    try testing.expectEqualStrings("mid", f.lineText(1).?);

    // 줄을 지우는 쪽도 본다 — 늘리는 것만 재면 인덱스를 **한 번만** 세우는 뮤턴트가 살아남는다.
    const del = [_]delta.Change{.{ .start = 1, .end = 6, .text = "" }};
    var inv2 = try f.apply(.{ .changes = &del }, &sels);
    defer inv2.deinit();
    try testing.expectEqual(@as(usize, 2), f.lineCount());
    try testing.expectEqualStrings("a\nb", f.content);
}

test "EDOC5: 역연산을 적용하면 내용·줄 인덱스가 편집 전으로 돌아간다" {
    const original = "alpha\nbeta\ngamma";
    var f = try EditableFile.init(testing.allocator, original, false);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = oneCaret(&items);

    const changes = [_]delta.Change{.{ .start = 6, .end = 10, .text = "B\nB\nB" }};
    var inv = try f.apply(.{ .changes = &changes }, &sels);
    defer inv.deinit();
    try testing.expectEqual(@as(usize, 5), f.lineCount());

    var back = try f.apply(inv.delta(), &sels);
    defer back.deinit();
    try testing.expectEqualStrings(original, f.content);
    try testing.expectEqual(@as(usize, 3), f.lineCount());
    try testing.expectEqual(@as(u64, 2), f.revision); // 되돌린 것도 편집이다
}

test "EDOC6: 읽기 전용 문서는 편집을 거절한다 — 화면만 바뀌고 저장이 실패하지 않게" {
    var f = try EditableFile.init(testing.allocator, "locked", true);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = oneCaret(&items);

    const changes = [_]delta.Change{.{ .start = 0, .end = 0, .text = "x" }};
    try testing.expectError(error.ReadOnly, f.apply(.{ .changes = &changes }, &sels));
    try testing.expectEqualStrings("locked", f.content);
    try testing.expectEqual(@as(u64, 0), f.revision);
}

test "EDOC7: [측정] 편집 1회에 드는 파생 재구축 비용" {
    // §3.0이 "타이핑이 프레임 예산을 넘는다"를 뒤집을 신호로 들었다. **그 수를 볼 수 없으면 신호를
    // 관측할 수 없으므로** 여기서 잰다. 단언이 아니라 측정이다 — 기계마다 다른 수로 게이트를
    // 세우면 CI가 무작위로 빨개진다.
    const size = 256 * 1024;
    const big = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    for (0..size / 64) |i| big[i * 64] = '\n';

    var f = try EditableFile.init(testing.allocator, big, false);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = oneCaret(&items);

    const t0 = monotonicUs();
    const rounds = 50;
    for (0..rounds) |_| {
        const changes = [_]delta.Change{.{ .start = 100, .end = 100, .text = "k" }};
        var inv = try f.apply(.{ .changes = &changes }, &sels);
        inv.deinit();
    }
    const per_edit_us = (monotonicUs() - t0) / rounds;
    std.debug.print("\n[측정] 256 KiB 문서, 편집 1회당 {d}µs (rope 편집 + 평탄화 + 줄 인덱스 재구축)\n", .{per_edit_us});

    try testing.expectEqual(@as(usize, size + rounds), f.content.len);
}

test "EDOC8: 평탄화 축이 버퍼와 갈리지 않는다 — 무작위 편집 200번" {
    var prng = std.Random.DefaultPrng.init(0xED0C);
    const rand = prng.random();

    var f = try EditableFile.init(testing.allocator, "seed\nline\n", false);
    defer f.deinit();

    var items = [_]selection.Selection{selection.Selection.at(0)};
    var sels = oneCaret(&items);

    for (0..200) |_| {
        const at = rand.uintAtMost(usize, f.content.len);
        const texts = [_][]const u8{ "z", "\n", "abc", "한" };
        const changes = [_]delta.Change{.{
            .start = at,
            .end = at,
            .text = texts[rand.uintLessThan(usize, texts.len)],
        }};
        var inv = try f.apply(.{ .changes = &changes }, &sels);
        inv.deinit();

        // 정본(버퍼)을 직접 떠서 평탄화 축과 맞춘다 — 둘이 갈리면 화면이 조용히 거짓말한다.
        const truth = try f.buf.copyAll(testing.allocator);
        defer testing.allocator.free(truth);
        try testing.expectEqualStrings(truth, f.content);
        try testing.expectEqual(std.mem.count(u8, truth, "\n") + 1, f.lineCount());
    }
}

test "EDOC9: 할당이 어디서 실패해도 정본과 평탄화 축이 갈리지 않는다" {
    // **이 판정자는 적대적 검증이 실제로 깬 자리에서 나왔다.** `fail_index=12`에서 `delta.apply`는
    // 성공하고 파생 축 재구축이 실패해, 버퍼는 편집 후·`content`는 편집 전인 상태가 남았다.
    // 그 상태는 조용하다 — 렌더가 낡은 offset으로 슬라이스를 떠서 틀린 글자를 그리거나 범위를 넘는다.
    //
    // 지금은 편집 전 판을 `O(1)` 스냅숏으로 떠 두었다가 되돌린다(할당 없이 — 여기 오는 이유가
    // 할당 실패다). 아래는 그 계약을 실패 지점 전부에서 확인한다.
    const original = "hello world\nsecond line\nthird line\n";
    var idx: usize = 0;
    var failures: usize = 0;
    while (idx < 60) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
        const a = failing.allocator();

        var f = EditableFile.init(a, original, false) catch continue;
        defer f.deinit();

        var items = [_]selection.Selection{ selection.Selection.at(3), selection.Selection.at(20) };
        var sels = selection.Selections.init(&items, 0);

        const changes = [_]delta.Change{
            .{ .start = 0, .end = 5, .text = "GOODBYE" },
            .{ .start = 12, .end = 18, .text = "2ND" },
        };
        if (f.apply(.{ .changes = &changes }, &sels)) |inv| {
            var done = inv;
            done.deinit();
        } else |_| {
            failures += 1;
            // ⑴ 정본이 편집 전이다.
            const truth = f.buf.copyAll(testing.allocator) catch continue;
            defer testing.allocator.free(truth);
            try testing.expectEqualStrings(original, truth);
            // ⑵ 평탄화 축과 줄 인덱스도 같은 판이다.
            try testing.expectEqualStrings(original, f.content);
            try testing.expectEqual(std.mem.count(u8, original, "\n") + 1, f.lineCount());
            // ⑶ selection이 문서 밖을 가리키지 않는다.
            for (sels.items) |sel| {
                try testing.expect(sel.anchor_start <= f.content.len);
                try testing.expect(sel.focus <= f.content.len);
            }
            // ⑷ revision이 오르지 않았다 — 안 일어난 편집이다.
            try testing.expectEqual(@as(u64, 0), f.revision);
        }
    }
    // **실패를 한 번도 못 만들었으면 이 판정자는 아무것도 판정하지 않은 것이다.**
    try testing.expect(failures > 0);
}
