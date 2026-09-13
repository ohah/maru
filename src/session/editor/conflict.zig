//! 병합 충돌 **마커 구간**을 문서에서 찾아낸다(S2 — docs/editor-merge-conflicts.md §5).
//!
//! **순수 계산이라 여기 산다.** 화면도 편집기 상태도 안 본다 — 줄 배열을 받아 구간을 낸다.
//! 그 구간을 무엇으로 그리고 어떤 동작을 붙일지는 위층의 일이다.
//!
//! **git 이 쓰는 모양**(`git-merge(1)` "HOW CONFLICTS ARE PRESENTED"):
//!
//! ```text
//! <<<<<<< HEAD          ← 시작.  그 아래가 «현재 것»(ours)
//! ours
//! ||||||| merged common ancestors   ← diff3·zdiff3 에서만. 그 아래가 «원본»(base)
//! base
//! =======               ← 가름.  그 아래가 «들어온 것»(theirs)
//! theirs
//! >>>>>>> topic         ← 끝
//! ```
//!
//! **diff3 을 빠뜨리지 않는다.** `merge.conflictStyle` 이 `diff3`·`zdiff3` 면 base 구간이 끼는데,
//! 그것을 모르면 base 를 «현재 것»의 일부로 읽어 「현재 것 채택」이 **엉뚱한 것을 남긴다**.

const std = @import("std");

/// 마커 한 종류. 값은 그 줄이 무엇을 **여는가**다.
pub const Marker = enum {
    /// `<<<<<<<` — 구간 시작, 그 아래가 «현재 것».
    ours,
    /// `|||||||` — diff3 의 원본 구간 시작.
    base,
    /// `=======` — 가름, 그 아래가 «들어온 것».
    separator,
    /// `>>>>>>>` — 구간 끝.
    theirs,

    fn glyph(self: Marker) u8 {
        return switch (self) {
            .ours => '<',
            .base => '|',
            .separator => '=',
            .theirs => '>',
        };
    }
};

/// git 이 쓰는 마커 길이. **정확히 일곱이다** — 여섯도 여덟도 git 이 내지 않는다.
pub const marker_len: usize = 7;

/// 이 줄이 마커인가. **줄 머리에서만, 정확히 일곱 자, 그 뒤는 공백이거나 줄 끝**이다.
///
/// 셋 다 필요하다:
///
/// - **줄 머리**: 문자열·주석 안의 같은 글자를 마커로 읽으면 **멀쩡한 파일이 충돌로 보인다**.
///   이 저장소 자신의 `git_backend.zig` 에 `"<<<<<<<"` 를 담은 테스트 단언이 있다.
/// - **정확히 일곱**: 여덟 개짜리 구분선(`========`)은 흔한 주석 장식이다. 그것을 가름으로 읽으면
///   장식이 든 파일이 통째로 충돌 구간이 된다.
/// - **뒤는 공백이나 줄 끝**: `<<<<<<<abc` 같은 것은 git 이 안 낸다. git 은 라벨 앞에 공백을 둔다
///   (`<<<<<<< HEAD`). `=======` 만 라벨이 없어 줄 끝으로 끝난다.
pub fn markerOf(line: []const u8) ?Marker {
    if (line.len < marker_len) return null;
    const kind: Marker = switch (line[0]) {
        '<' => .ours,
        '|' => .base,
        '=' => .separator,
        '>' => .theirs,
        else => return null,
    };
    const g = kind.glyph();
    for (line[0..marker_len]) |c| {
        if (c != g) return null;
    }
    if (line.len == marker_len) return kind; // 줄 끝 — `=======` 가 이 모양이다
    // **여덟 번째가 같은 글자면 마커가 아니다**(장식 줄). 공백이어야 라벨이 붙은 git 의 모양이다.
    return switch (line[marker_len]) {
        ' ', '\t' => kind,
        else => null,
    };
}

/// 찾아낸 충돌 구간 하나. 값은 전부 **줄 인덱스**(0-based, 받은 배열 기준)다.
///
/// **마커 줄 자체도 구간에 든다** — 「고르기」는 그 줄들까지 지우는 일이라, 지울 범위를 그대로
/// 들고 있어야 한다.
pub const Region = struct {
    /// `<<<<<<<` 줄.
    start: u32,
    /// `|||||||` 줄(diff3 이 아니면 `null`).
    base: ?u32 = null,
    /// `=======` 줄.
    separator: u32,
    /// `>>>>>>>` 줄.
    end: u32,

    /// «현재 것» 본문 줄 범위 `[from, to)`. diff3 이면 `|||||||` 앞에서 끝난다.
    pub fn ours(self: Region) struct { from: u32, to: u32 } {
        return .{ .from = self.start + 1, .to = self.base orelse self.separator };
    }

    /// «원본» 본문 줄 범위. diff3 이 아니면 빈 범위다(`from == to`).
    pub fn baseLines(self: Region) struct { from: u32, to: u32 } {
        const b = self.base orelse return .{ .from = self.separator, .to = self.separator };
        return .{ .from = b + 1, .to = self.separator };
    }

    /// «들어온 것» 본문 줄 범위.
    pub fn theirs(self: Region) struct { from: u32, to: u32 } {
        return .{ .from = self.separator + 1, .to = self.end };
    }
};

/// 문서의 충돌 구간을 **앞에서부터** 찾는다. `out` 이 차면 거기서 멈춘다(호출자가 상한을 정한다).
///
/// **닫히지 않은 구간은 안 낸다.** `<<<<<<<` 만 있고 `>>>>>>>` 가 없는 파일은 충돌이 아니라 그냥
/// 그런 글자가 든 파일이다 — 거기에 「고르기」를 붙이면 누르는 순간 문서 끝까지 지운다.
///
/// **`=======` 없이 닫히는 것도 안 낸다.** 가름이 없으면 «현재 것»과 «들어온 것»의 경계를 말할 수
/// 없고, 경계를 모르면 고를 수가 없다.
///
/// **새 `<<<<<<<` 는 진행 중이던 후보를 버리고 다시 시작한다.** git 은 구간을 겹쳐 내지 않으므로
/// 그런 입력은 이미 손으로 망가진 파일이고, 그때는 **뒤엣것**이 더 그럴듯하다(앞엣것은 닫히지
/// 않았다). 둘을 합쳐 하나로 보면 지우는 범위가 실제보다 커진다.
pub fn scan(lines: []const []const u8, out: []Region) []Region {
    var n: usize = 0;
    var start: ?u32 = null;
    var base: ?u32 = null;
    var separator: ?u32 = null;

    for (lines, 0..) |line, i| {
        if (n == out.len) break;
        const kind = markerOf(line) orelse continue;
        const idx: u32 = @intCast(i);
        switch (kind) {
            .ours => {
                // 진행 중이던 후보를 버린다(위 머리말).
                start = idx;
                base = null;
                separator = null;
            },
            .base => {
                // **시작 뒤이고, 가름 앞이고, 처음일 때만.** 순서가 어긋난 `|||||||` 는 본문 글자다.
                if (start != null and base == null and separator == null) base = idx;
            },
            .separator => {
                if (start != null and separator == null) separator = idx;
            },
            .theirs => {
                const s = start orelse continue;
                const sep = separator orelse {
                    // 가름 없이 닫혔다 — 이 후보는 버린다.
                    start = null;
                    base = null;
                    continue;
                };
                out[n] = .{ .start = s, .base = base, .separator = sep, .end = idx };
                n += 1;
                start = null;
                base = null;
                separator = null;
            },
        }
    }
    return out[0..n];
}

/// 문서에 충돌 마커가 **하나라도 남아 있는가**. 저장할 때 알릴지 정하는 자리가 쓴다(§5 S2).
///
/// **`scan` 과 같은 판정을 쓴다** — 여기서 「`<<<<<<<` 가 보이면 남았다」로 따로 재면, 닫히지 않은
/// 구간이 든 멀쩡한 파일마다 경고가 뜬다.
pub fn hasUnresolved(lines: []const []const u8) bool {
    var one: [1]Region = undefined;
    return scan(lines, &one).len > 0;
}

const testing = std.testing;

test "마커는 줄 머리에서만, 정확히 일곱 자, 뒤는 공백이나 줄 끝" {
    try testing.expectEqual(Marker.ours, markerOf("<<<<<<< HEAD").?);
    try testing.expectEqual(Marker.base, markerOf("||||||| merged common ancestors").?);
    try testing.expectEqual(Marker.separator, markerOf("=======").?);
    try testing.expectEqual(Marker.theirs, markerOf(">>>>>>> topic").?);

    // **여덟 개는 마커가 아니다** — `========` 는 흔한 주석 장식이다.
    try testing.expectEqual(@as(?Marker, null), markerOf("========"));
    try testing.expectEqual(@as(?Marker, null), markerOf("<<<<<<<<"));
    // 여섯 개도 아니다.
    try testing.expectEqual(@as(?Marker, null), markerOf("======"));
    // **줄 머리가 아니면 아니다** — 이 저장소 자신의 테스트 단언이 그런 줄을 담고 있다.
    try testing.expectEqual(@as(?Marker, null), markerOf("    <<<<<<< HEAD"));
    try testing.expectEqual(@as(?Marker, null), markerOf("const marker = \"<<<<<<<\";"));
    // 라벨이 공백 없이 붙은 것은 git 이 안 낸다.
    try testing.expectEqual(@as(?Marker, null), markerOf("<<<<<<<HEAD"));
    // 섞인 글자도 아니다.
    try testing.expectEqual(@as(?Marker, null), markerOf("<<<<<<= HEAD"));
    try testing.expectEqual(@as(?Marker, null), markerOf(""));
}

test "평범한 두 쪽 충돌 — 구간 하나와 그 세 범위" {
    const lines = [_][]const u8{
        "fn greet() {",
        "<<<<<<< HEAD",
        "  ours a",
        "  ours b",
        "=======",
        "  theirs",
        ">>>>>>> topic",
        "}",
    };
    var buf: [4]Region = undefined;
    const found = scan(&lines, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    const r = found[0];
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(?u32, null), r.base);
    try testing.expectEqual(@as(u32, 4), r.separator);
    try testing.expectEqual(@as(u32, 6), r.end);
    try testing.expectEqual(@as(u32, 2), r.ours().from);
    try testing.expectEqual(@as(u32, 4), r.ours().to);
    try testing.expectEqual(@as(u32, 5), r.theirs().from);
    try testing.expectEqual(@as(u32, 6), r.theirs().to);
    // diff3 이 아니면 base 는 **빈 범위**다(`null` 과 「비었다」를 호출자가 안 갈라도 되게).
    try testing.expectEqual(r.baseLines().from, r.baseLines().to);
}

test "diff3 — base 구간이 끼면 «현재 것»이 거기서 끝난다" {
    // **이것을 모르면 「현재 것 채택」이 base 까지 남긴다.** 두 쪽 충돌과 같은 코드로 읽으면
    // `ours` 의 끝이 `=======` 가 되어 원본 줄이 결과에 섞인다.
    const lines = [_][]const u8{
        "<<<<<<< HEAD",
        "  ours",
        "||||||| base",
        "  original",
        "=======",
        "  theirs",
        ">>>>>>> topic",
    };
    var buf: [4]Region = undefined;
    const found = scan(&lines, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    const r = found[0];
    try testing.expectEqual(@as(?u32, 2), r.base);
    try testing.expectEqual(@as(u32, 1), r.ours().from);
    try testing.expectEqual(@as(u32, 2), r.ours().to); // **`|||||||` 앞에서 끝난다**
    try testing.expectEqual(@as(u32, 3), r.baseLines().from);
    try testing.expectEqual(@as(u32, 4), r.baseLines().to);
    try testing.expectEqual(@as(u32, 5), r.theirs().from);
    try testing.expectEqual(@as(u32, 6), r.theirs().to);
}

test "닫히지 않은 것과 가름 없는 것은 «구간이 아니다»" {
    // 닫히지 않았다 — 여기에 고르기를 붙이면 누르는 순간 문서 끝까지 지운다.
    const open_only = [_][]const u8{ "<<<<<<< HEAD", "  a", "=======", "  b" };
    var buf: [4]Region = undefined;
    try testing.expectEqual(@as(usize, 0), scan(&open_only, &buf).len);

    // 가름이 없다 — 두 쪽의 경계를 말할 수 없다.
    const no_sep = [_][]const u8{ "<<<<<<< HEAD", "  a", ">>>>>>> topic" };
    try testing.expectEqual(@as(usize, 0), scan(&no_sep, &buf).len);

    // 순서가 뒤집혔다 — 시작 없이 닫힌다.
    const backwards = [_][]const u8{ ">>>>>>> topic", "=======", "<<<<<<< HEAD" };
    try testing.expectEqual(@as(usize, 0), scan(&backwards, &buf).len);

    try testing.expect(!hasUnresolved(&open_only));
    try testing.expect(!hasUnresolved(&no_sep));
}

test "구간이 여럿이고, 상한에 걸리면 거기서 멈춘다" {
    const lines = [_][]const u8{
        "<<<<<<< HEAD", "a",            "=======", "b",       ">>>>>>> t",
        "middle",       "<<<<<<< HEAD", "c",       "=======", "d",
        ">>>>>>> t",    "<<<<<<< HEAD", "e",       "=======", "f",
        ">>>>>>> t",
    };
    var buf: [8]Region = undefined;
    const found = scan(&lines, &buf);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(u32, 0), found[0].start);
    try testing.expectEqual(@as(u32, 6), found[1].start);
    try testing.expectEqual(@as(u32, 11), found[2].start);

    // **상한은 호출자의 것이다** — 자리가 둘뿐이면 둘만 낸다(넘치면 안 된다).
    var small: [2]Region = undefined;
    try testing.expectEqual(@as(usize, 2), scan(&lines, &small).len);
    try testing.expect(hasUnresolved(&lines));
}

test "새 `<<<<<<<` 는 진행 중이던 후보를 버린다 — 지우는 범위가 커지지 않게" {
    // 손으로 망가진 파일: 앞의 시작이 안 닫힌 채 새 시작이 온다. 둘을 합쳐 하나로 보면
    // `start` 가 0 이 되어 「고르기」가 위쪽 멀쩡한 줄까지 지운다.
    const lines = [_][]const u8{
        "<<<<<<< HEAD",
        "  stray",
        "<<<<<<< HEAD",
        "  ours",
        "=======",
        "  theirs",
        ">>>>>>> topic",
    };
    var buf: [4]Region = undefined;
    const found = scan(&lines, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 2), found[0].start); // **뒤엣것**이다
}

test "순서가 어긋난 `|||||||` 는 본문 글자다" {
    // 가름 뒤의 `|||||||` 는 diff3 의 base 가 아니다 — base 로 읽으면 `ours` 의 끝이 앞으로 당겨져
    // 「현재 것 채택」이 자기 줄을 잘라 먹는다.
    const lines = [_][]const u8{
        "<<<<<<< HEAD",
        "  ours",
        "=======",
        "||||||| not base",
        "  theirs",
        ">>>>>>> topic",
    };
    var buf: [4]Region = undefined;
    const found = scan(&lines, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(?u32, null), found[0].base);
    try testing.expectEqual(@as(u32, 1), found[0].ours().from);
    try testing.expectEqual(@as(u32, 2), found[0].ours().to);
}
