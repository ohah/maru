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
//! ### 메모리는 문서를 두 벌 든다 — 실측
//!
//! | | 읽기 전용(`open.zig`) | 편집 가능 | 원문 대비 |
//! |---|---|---|---|
//! | 64 KiB 문서 | 38 KiB | 172 KiB | **2.7배** |
//! | 1 MiB 문서 | 614 KiB | 2758 KiB | **2.7배** |
//!
//! 읽기 전용이 원문보다 작은 것은 **bytes를 빌리기 때문**이다(줄 인덱스만 잡는다). 편집 가능은
//! rope 잎 한 벌 + 평탄화 한 벌 + 줄 인덱스라 원문의 약 2.7배가 된다.
//!
//! **이것은 위 평탄화 결정의 대가이고, 파일 상한과 곱해진다** — `read_limit_bytes`가 64 MiB이므로
//! 한 파일이 약 170 MB를 쓸 수 있다. 줄이는 길은 정해져 있다: 소비처를 트리 위로 옮겨 평탄화 벌을
//! 없애면 한 벌 + 인덱스가 된다. **그 슬라이스 전에는 이 수를 알고 있는 것이 최선이고, 몰랐다면
//! 큰 파일에서 이유 없이 메모리가 튀는 것으로 보였을 것이다.**
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
    ///
    /// **문서 밖이거나 형태가 틀린 delta도 거절한다**(`OutOfRange`·`MalformedDelta`) — `delta.apply`가
    /// 그것을 단언이 아니라 오류로 답하므로 여기 오류 집합에도 그대로 실린다. 단언에 맡기면
    /// 출하 빌드(ReleaseFast)에서 사라져 조용히 망가진다.
    pub fn apply(
        self: *EditableFile,
        d: delta.Delta,
        selections: *selection.Selections,
    ) (error{ ReadOnly, OutOfRange, MalformedDelta } || std.mem.Allocator.Error)!delta.Inverse {
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

    /// **디스크에 쓸 bytes를 만든다** — 연 그대로의 파일 속성을 되돌린다(§3.5).
    ///
    /// 편집기가 파일을 열었다 저장하기만 해도 내용이 달라지면 **diff가 통째로 물들고** 사용자는
    /// 자기가 무엇을 바꿨는지 알 수 없다. 그래서 되돌리는 것이 셋이다:
    ///
    /// - **BOM** — 있었으면 다시 붙인다(문서 offset 0은 BOM 뒤였다).
    /// - **끝 개행** — 임의로 더하거나 지우지 않는다. **그 말은 "원래대로 강제한다"가 아니다.**
    ///   초판이 그렇게 읽어 원본 상태로 맞췄는데, 그러면 **사용자 편집이 조용히 되돌아간다**:
    ///   끝 개행이 없던 파일에 Enter를 치면 떼고, 있던 파일에서 지우면 도로 붙였다(적대적 검증
    ///   2026-08-25). §3.5가 막으려는 것은 **편집기가 제멋대로** 더하거나 지우는 것이고,
    ///   편집한 뒤 내용의 진실은 `content`다.
    /// - **줄바꿈** — **건드리지 않는다.** `content`가 이미 원본의 `\r\n`을 그대로 들고 있고,
    ///   편집으로 새로 들어간 줄만 `\n`이다. 섞인 파일을 한 쪽으로 통일하면 **안 건드린 줄까지
    ///   diff에 뜬다**(`mixed_endings`가 그 유혹을 막으려고 사실로 남아 있다).
    ///
    /// **새 줄에 `dominant_ending`을 쓰지 않는다 — 아직.** §3.5는 *"새로 삽입되는 줄에만"* 그것을
    /// 쓰라고 하는데, 그러려면 편집이 "이 줄바꿈은 내가 넣은 것"을 표시해야 한다. 지금 편집 층은
    /// 그 표시를 만들지 않으므로 **CRLF 파일에 새 줄을 넣으면 그 줄만 LF다.** 아는 대가이고,
    /// 그 표시를 만드는 것은 편집 연산 쪽 슬라이스다.
    pub fn saveBytes(self: EditableFile, allocator: std.mem.Allocator) ![]u8 {
        // **내용은 그대로 쓴다.** 끝 개행을 원본 상태로 맞추던 분기를 걷어냈다 — 그것이
        // 사용자 편집을 되돌렸다(위 주석). BOM만 파일 속성이라 되붙인다.
        const bom = if (self.format.has_bom) document.utf8_bom else "";
        const out = try allocator.alloc(u8, bom.len + self.content.len);
        @memcpy(out[0..bom.len], bom);
        @memcpy(out[bom.len..], self.content);
        return out;
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
        // **`\r\n`을 섞는다.** 이것이 없으면 아래 줄별 대조가 CRLF 경로를 아예 안 밟는다 —
        // 실제로 CRLF 판정을 죽인 뮤턴트가 이 판정자를 통과했다(적대적 검증 2026-08-25).
        // 무작위 삽입이 `\r\n` 쌍을 가르기도 하는데, 그것도 정당한 입력이다(홀로 남은 `\r`은
        // 줄바꿈이 아니다).
        const texts = [_][]const u8{ "z", "\n", "abc", "한", "\r\n", "\r" };
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

        // **줄별 텍스트까지 본다.** 내용과 줄 수가 맞아도 경계가 한 칸 밀리면 화면에 그려지는
        // 줄이 통째로 어긋나는데, 위 둘만으로는 그것이 안 잡힌다 — 실제로 `lineText`가 렌더에
        // 넘기는 값이라 여기가 화면과 가장 가깝다. 기준은 순진한 분할이다.
        {
            var line_no: usize = 0;
            var cursor: usize = 0;
            while (line_no < f.lineCount()) : (line_no += 1) {
                const nl = std.mem.indexOfScalarPos(u8, truth, cursor, '\n');
                const raw_end = nl orelse truth.len;
                // 줄바꿈 앞의 `\r`은 줄 내용이 아니다(CRLF 한 덩어리).
                const end = if (nl != null and raw_end > cursor and truth[raw_end - 1] == '\r')
                    raw_end - 1
                else
                    raw_end;
                try testing.expectEqualStrings(truth[cursor..end], f.lineText(line_no).?);
                cursor = raw_end + 1;
            }
        }
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
        const before_sels = items; // 편집 전 값(값 복사)

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
            // ⑶ selection이 **편집 전 그대로**다.
            //
            // 처음엔 "문서 밖을 가리키지 않는다"만 봤는데, 그것은 **0으로 다 뭉개도 통과한다** —
            // 되돌리기가 커서를 전부 0으로 두는 뮤턴트가 살아남았다(적대적 검증 2026-08-25).
            // 사용자에게는 편집이 취소됐는데 커서가 엉뚱한 데 있는 상태이고, 다음 타이핑이 거기로
            // 간다. 이 판정자가 밟는 실패 경로(`rollback`)는 `EDOC10`이 재는 정상 경로와 **다른
            // 코드**라, 그쪽이 초록이어도 이쪽은 열려 있었다.
            //
            // **커서가 편집 전 자리이거나, 접힌 자리다.**
            //
            // 처음엔 "문서 밖을 가리키지 않는다"만 봤는데 그것은 **0으로 다 뭉개도 통과한다** —
            // 되돌리기가 커서를 0으로 두는 뮤턴트가 살아남았다(적대적 검증 2026-08-25).
            //
            // **실패 지점마다 도는 코드가 다르다**(실측 — 36개 중):
            //   · 34개: `delta.apply`가 **selection을 밀기 전에** 실패 → 커서가 그대로(3, 20)
            //   · 2개: 밀린 **뒤** 파생 축 재구축이 실패 → `rollback`의 되짚기가 돈다(0, 20)
            //
            // 되짚기는 편집 구간 **밖**에서만 정확하다. 구간 **안**을 가리키던 커서(3)는 앞서
            // §3.3대로 구간 시작으로 접혔고 그 정보는 어떤 역연산으로도 되살릴 수 없다 — 접기가
            // 여럿을 하나로 보내기 때문이다. **진짜 undo는 이 손실이 없다**(`UNDO1`이 재는 경로는
            // 편집 전 커서를 통째로 들고 있다가 되살린다). 이쪽은 할당 실패 복구라 그럴 여유가
            // 없어 되짚기를 쓴다.
            //
            // 그래서 단언은 **둘 중 하나**를 요구한다: 안 밀렸거나, 접힌 자리에 있거나.
            // "아무 값이나"가 아니다 — 0으로 뭉개는 뮤턴트는 커서[1]에서 죽는다.
            for (sels.items, 0..) |sel, i| {
                const untouched = sel.focus == before_sels[i].focus;
                const collapsed = sel.focus == 0 and i == 0; // 첫 변경이 [0,5)라 그 시작이 0이다
                try testing.expect(untouched or collapsed);
            }
            // ⑷ revision이 오르지 않았다 — 안 일어난 편집이다.
            try testing.expectEqual(@as(u64, 0), f.revision);
        }
    }
    // **실패를 한 번도 못 만들었으면 이 판정자는 아무것도 판정하지 않은 것이다.**
    try testing.expect(failures > 0);
}

test "EDOC10: 되돌리기가 selection을 제자리로 돌린다 (범위 안이 아니라 제자리)" {
    // **EDOC9는 "문서 밖을 가리키지 않는다"만 본다.** 그것은 0으로 뭉개도 통과한다 — 되돌린 뒤
    // 커서가 문서 처음으로 다 모여도 "범위 안"이기 때문이다. 사용자에게는 편집이 취소됐는데
    // 커서가 엉뚱한 데 있는 상태이고, 다음 타이핑이 거기로 간다.
    //
    // 그래서 여기서는 **편집 전 값과 정확히 같은지** 본다. 지워진 구간 안을 가리키던 커서는
    // 접히므로 그것만 예외로 둔다(§3.3 — 접는 것이 계약이다).
    const original = "alpha beta gamma delta\nsecond line here\n";
    var f = try EditableFile.init(testing.allocator, original, false);
    defer f.deinit();

    // 편집 구간 **밖**의 커서들 — 되돌리면 정확히 제자리여야 한다.
    var items = [_]selection.Selection{
        selection.Selection.at(0),
        selection.Selection.fromPoints(23, 29), // "second"
        selection.Selection.at(38),
    };
    var sels = selection.Selections.init(&items, 0);
    const before = items;

    const changes = [_]delta.Change{.{ .start = 6, .end = 10, .text = "BETA!!" }};
    var inv = try f.apply(.{ .changes = &changes }, &sels);
    defer inv.deinit();

    // 편집이 실제로 커서를 밀었다 — 안 밀렸으면 아래 판정이 공허하다.
    try testing.expect(sels.items[1].anchor_start != before[1].anchor_start);

    var back = try f.apply(inv.delta(), &sels);
    defer back.deinit();

    try testing.expectEqualStrings(original, f.content);
    for (sels.items, 0..) |s, i| {
        try testing.expectEqual(before[i].anchor_start, s.anchor_start);
        try testing.expectEqual(before[i].anchor_end, s.anchor_end);
        try testing.expectEqual(before[i].focus, s.focus);
    }
}

test "EDOC11: 저장 bytes가 연 그대로의 파일 속성을 되돌린다 (§3.5)" {
    // **열었다 저장하기만 해도 내용이 달라지면 diff가 통째로 물든다.** 사용자는 자기가 무엇을
    // 바꿨는지 알 수 없게 되고, 그것이 §3.5가 "원문을 바꾸지 않는다"를 첫 문장으로 둔 이유다.
    const a = testing.allocator;

    // ⑴ BOM이 있던 파일은 BOM이 돌아온다.
    {
        var f = try EditableFile.init(a, document.utf8_bom ++ "hello\n", false);
        defer f.deinit();
        try testing.expectEqualStrings("hello\n", f.content); // 문서 offset 0은 BOM 뒤다
        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings(document.utf8_bom ++ "hello\n", out);
    }

    // ⑵ 끝 개행이 없던 파일은 없는 채로 남는다 — 임의로 더하지 않는다.
    //
    // **이 판정자는 끝 개행 결함을 못 잡는다** — 편집하지 않고 저장하므로 "원본대로 강제"와
    // "내용 그대로"가 같은 답을 낸다. 결함은 **사용자가 그것을 건드렸을 때만** 나타나고,
    // 그 축은 `EDOC12`가 잰다(적대적 검증 2026-08-25).
    {
        var f = try EditableFile.init(a, "no trailing", false);
        defer f.deinit();
        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings("no trailing", out);
    }

    // ⑶ CRLF 파일은 기존 줄의 `\r\n`이 그대로다 — 정규화하지 않는다.
    {
        var f = try EditableFile.init(a, "a\r\nb\r\n", false);
        defer f.deinit();
        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings("a\r\nb\r\n", out);
    }

    // ⑷ 편집한 뒤에도 속성이 살아 있다.
    {
        var f = try EditableFile.init(a, document.utf8_bom ++ "x\r\ny", false);
        defer f.deinit();
        var items = [_]selection.Selection{selection.Selection.at(0)};
        var sels = selection.Selections.init(&items, 0);
        const changes = [_]delta.Change{.{ .start = 0, .end = 1, .text = "X" }};
        var inv = try f.apply(.{ .changes = &changes }, &sels);
        defer inv.deinit();

        const out = try f.saveBytes(a);
        defer a.free(out);
        // BOM 유지 · 기존 CRLF 유지 · 끝 개행 없음 유지.
        try testing.expectEqualStrings(document.utf8_bom ++ "X\r\ny", out);
    }
}

test "EDOC12: 저장이 사용자의 끝 개행 편집을 되돌리지 않는다 (§3.5)" {
    // **§3.5의 "임의로 더하거나 지우지 않는다"는 "원래대로 강제한다"가 아니다.**
    // 초판이 그렇게 읽어 원본 상태로 맞췄고, 그래서 사용자가 친 Enter가 저장에서 조용히
    // 사라졌다 — 되돌릴 방법이 undo뿐인 종류이고, 저장했으니 사용자는 눈치채지 못한다.
    const a = testing.allocator;

    // ⑴ 끝 개행이 **없던** 파일에 사용자가 하나 넣는다 → 남아야 한다.
    {
        var f = try EditableFile.init(a, "no newline", false);
        defer f.deinit();
        var items = [_]selection.Selection{selection.Selection.at(10)};
        var sels = selection.Selections.init(&items, 0);
        const changes = [_]delta.Change{.{ .start = 10, .end = 10, .text = "\n" }};
        var inv = try f.apply(.{ .changes = &changes }, &sels);
        defer inv.deinit();

        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings("no newline\n", out);
    }

    // ⑵ 끝 개행이 **있던** 파일에서 사용자가 지운다 → 없어야 한다.
    {
        var f = try EditableFile.init(a, "has newline\n", false);
        defer f.deinit();
        var items = [_]selection.Selection{selection.Selection.at(12)};
        var sels = selection.Selections.init(&items, 0);
        const changes = [_]delta.Change{.{ .start = 11, .end = 12, .text = "" }};
        var inv = try f.apply(.{ .changes = &changes }, &sels);
        defer inv.deinit();

        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings("has newline", out);
    }

    // ⑶ 안 건드리면 그대로다 — 편집기가 **제멋대로** 더하거나 지우지 않는다(§3.5의 본뜻).
    {
        var f = try EditableFile.init(a, "untouched", false);
        defer f.deinit();
        const out = try f.saveBytes(a);
        defer a.free(out);
        try testing.expectEqualStrings("untouched", out);
    }
}
