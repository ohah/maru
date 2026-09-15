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
const i18n = @import("../../i18n.zig"); // 표시 문자열 단일 출처

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
/// - **뒤는 공백이나 줄 끝**: `<<<<<<<abc` 같은 것은 git 이 안 낸다. git 은 라벨 앞에 **공백**을 둔다
///   (`<<<<<<< HEAD`). `=======` 만 라벨이 없어 줄 끝으로 끝난다.
///
/// **탭은 안 받는다.** 처음에는 공백과 함께 받았는데 **git 이 탭을 내는 경우가 없고**(위 인용),
/// 받아 주면 그만큼 「마커가 아닌 줄을 마커로 읽을」 여지만 넓어진다 — 일곱 자 규칙을 둔 것과 같은
/// 이유다. 적대적 검증 4회차가 그 관용을 **아무 판정자도 안 지킨다**고 드러냈고(지워도 초록이었다),
/// 근거 없는 관용은 지운다.
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
        ' ' => kind,
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

/// 위젯 행에 그릴 세 이름 사이의 **여백**. 번역하지 않는다 — 문장이 아니라 자리다.
pub const action_gap = "   ";

/// 위젯 행의 세 이름을 **계약 순서**로 낸다: 현재 것 → 들어온 것 → 둘 다.
///
/// **순서가 곧 뜻이다.** 호출자는 이 순서로 `Choice` 를 짝지으므로, 여기서 두 이름을 바꾸면
/// **읽은 것과 다른 일이 일어난다**(「들어온 것 채택」이라 적힌 자리를 눌렀는데 현재 것이 남는다).
/// 제품과 Lab 이 **같은 이 함수**를 쓰는 이유이기도 하다 — Lab 이 자기 순서를 들고 있으면 골든이
/// 그 뒤바뀜을 못 본다(적대적 검증 5회차 실측).
pub fn actionNames() [3][]const u8 {
    return .{
        i18n.t(.editor_conflict_accept_current),
        i18n.t(.editor_conflict_accept_incoming),
        i18n.t(.editor_conflict_accept_both),
    };
}

/// **판 위 줄**의 두 이름(S3b-3c — VS Code 의 입력 판 「Accept X」·「Accept Combination (X First)」 상당):
/// 「X 채택」 → 「둘 다 채택 (X 먼저)」. Result 의 세 이름과 마찬가지로 **순서가 곧 뜻**이다.
pub const PaneSide = enum { current, incoming };
pub fn paneActionNames(side: PaneSide) [2][]const u8 {
    return switch (side) {
        .current => .{ i18n.t(.editor_conflict_accept_current), i18n.t(.editor_conflict_accept_both_current_first) },
        .incoming => .{ i18n.t(.editor_conflict_accept_incoming), i18n.t(.editor_conflict_accept_both_incoming_first) },
    };
}

test "판 위 줄의 이름은 «X 채택» → «둘 다 (X 먼저)» 순이다 — 순서가 곧 뜻이라 뒤집히면 읽은 것과 다른 일이 난다" {
    // 적대적 검증(S3b-3c 1회차 A9): 두 이름을 뒤집어도 초록이었다 — 판정자가 「그 글자가 판에 있나」만
    // 봤고 어느 자리인지는 안 봤다. 호출자는 첫째 자리에 `.current`/`.incoming` 을, 둘째에 「둘 다」를 짝짓는다.
    const cur = paneActionNames(.current);
    try std.testing.expectEqualStrings(i18n.t(.editor_conflict_accept_current), cur[0]);
    try std.testing.expectEqualStrings(i18n.t(.editor_conflict_accept_both_current_first), cur[1]);
    const inc = paneActionNames(.incoming);
    try std.testing.expectEqualStrings(i18n.t(.editor_conflict_accept_incoming), inc[0]);
    try std.testing.expectEqualStrings(i18n.t(.editor_conflict_accept_both_incoming_first), inc[1]);
    // 그리고 Current 와 Incoming 의 이름은 서로 다르다 — 같으면 어느 판을 눌러도 같은 글자가 보인다.
    try std.testing.expect(!std.mem.eql(u8, cur[0], inc[0]));
    try std.testing.expect(!std.mem.eql(u8, cur[1], inc[1]));
}

/// 한 이름이 차지하는 열 `[from, to)`.
pub const ActionSpan = struct { from: u32, to: u32 };

/// 세 이름을 이어 `out` 에 쓰고 **각 이름의 열 구간**을 함께 낸다. 자리가 모자라면 `null`.
///
/// **글자와 구간이 한 함수에서 나오는 것이 계약이다** — 그리는 쪽과 누르는 쪽이 각자 재면 폰트·언어가
/// 바뀌는 날 갈리고, 그러면 「현재 것」을 눌렀는데 「둘 다」가 일어난다.
///
/// **열을 세는 함수를 호출자가 준다**(`colsOf`). 이 모듈은 화면을 모르고, 렌더가 쓰는 그 규칙이
/// chrome 에 있기 때문이다 — 여기서 byte 길이로 세면 한글에서 누르는 자리가 글자와 갈린다.
pub fn writeActions(
    names: []const []const u8,
    out: []u8,
    colsOf: *const fn ([]const u8) u32,
    out_spans: []ActionSpan,
) ?[]u8 {
    std.debug.assert(out_spans.len == names.len);
    if (names.len == 0) return null;
    var total: usize = action_gap.len * (names.len - 1);
    for (names) |n| total += n.len;
    if (out.len < total) return null;

    var w: usize = 0;
    var col: u32 = 0;
    for (names, 0..) |name, i| {
        if (i > 0) {
            @memcpy(out[w..][0..action_gap.len], action_gap);
            w += action_gap.len;
            col += colsOf(action_gap);
        }
        const from = col;
        @memcpy(out[w..][0..name.len], name);
        w += name.len;
        col += colsOf(name);
        out_spans[i] = .{ .from = from, .to = col };
    }
    return out[0..w];
}

/// 충돌 중인 파일의 **세 판 중 무엇을 읽었나**(S3a — docs/editor-merge-conflicts.md §5).
///
/// **규칙을 여기 두는 이유**: 「열 수 있나」와 「2-way 로 저하하나」는 git 을 안 돌려도 답할 수 있는
/// 순수 판정이고, 워커 안에 두면 **실제 충돌 저장소 없이는 못 잰다**. 이 저장소에는 충돌 저장소를
/// 만드는 하네스가 없다(쓰기 명령 어휘가 `init`·`merge` 를 일부러 안 갖는다) — 그러면 그 규칙이
/// 영영 무판정으로 남는다.
pub const StageSet = struct {
    /// `:1:` — 공통 조상. **add/add 충돌에는 없다**(양쪽이 같은 경로를 새로 만들었다).
    has_base: bool = false,
    /// `:2:` — 현재 브랜치(ours).
    has_ours: bool = false,
    /// `:3:` — 합쳐 오는 브랜치(theirs).
    has_theirs: bool = false,

    /// 이 충돌을 **열 수 있나**. 한쪽이라도 있으면 보여 줄 것이 있다.
    ///
    /// **조상은 이 판정에 안 든다.** 조상만 있고 두 쪽이 다 없는 것은 「양쪽이 지웠다」인데, 그러면
    /// 고를 내용이 없다 — 3-way 를 열어 봐야 빈 pane 셋이다.
    pub fn openable(self: StageSet) bool {
        return self.has_ours or self.has_theirs;
    }

    /// **조상이 없어 2-way 로 저하하나**(§5 S3a). 「내용이 비었다」가 아니라 「판이 없다」이다 —
    /// 빈 조상 파일은 어엿한 조상이고, 길이로 가르면 그것이 없음으로 읽힌다.
    pub fn degradesToTwoWay(self: StageSet) bool {
        return !self.has_base;
    }
};

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
    // **탭도 안 받는다** — git 은 공백만 쓴다(위 머리말). 받아 주면 마커가 아닌 줄을 읽을 여지가 는다.
    try testing.expectEqual(@as(?Marker, null), markerOf("<<<<<<<\tHEAD"));
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
    // **빈 문서는 «없다»** — 새로 만든 파일마다 경고가 뜨면 그 문구가 무의미해진다.
    try testing.expect(!hasUnresolved(&.{}));
    var none: [2]Region = undefined;
    try testing.expectEqual(@as(usize, 0), scan(&.{}, &none).len);
}

test "stage 셋: 열 수 있나 · 2-way 로 저하하나 (여덟 가지 전부)" {
    // **여덟 가지를 다 적는다** — 「흔한 셋」만 보면 add/add(조상 없음)나 「양쪽이 지웠다」처럼
    // 드문 조합에서 판정이 뒤집혀도 안 보인다. 조합이 여덟뿐이라 전부 적는 것이 가장 싸다.
    const Case = struct { b: bool, o: bool, t: bool, openable: bool, two_way: bool };
    const cases = [_]Case{
        .{ .b = false, .o = false, .t = false, .openable = false, .two_way = true }, // 아무것도 없다
        .{ .b = true, .o = false, .t = false, .openable = false, .two_way = false }, // 양쪽이 지웠다 — 고를 것이 없다
        .{ .b = false, .o = true, .t = false, .openable = true, .two_way = true }, // 들어온 쪽이 지웠다(+add/add 꼴)
        .{ .b = false, .o = false, .t = true, .openable = true, .two_way = true },
        .{ .b = true, .o = true, .t = false, .openable = true, .two_way = false }, // 들어온 쪽이 지웠다
        .{ .b = true, .o = false, .t = true, .openable = true, .two_way = false }, // 내 쪽이 지웠다
        .{ .b = false, .o = true, .t = true, .openable = true, .two_way = true }, // **add/add** — 조상이 없다
        .{ .b = true, .o = true, .t = true, .openable = true, .two_way = false }, // 평범한 3-way
    };
    for (cases) |c| {
        const set: StageSet = .{ .has_base = c.b, .has_ours = c.o, .has_theirs = c.t };
        try testing.expectEqual(c.openable, set.openable());
        try testing.expectEqual(c.two_way, set.degradesToTwoWay());
    }

    // **빈 조상과 «없는 조상»은 다르다.** 길이로 가르면 빈 파일이 조상이던 충돌이 근거 없이
    // 2-way 로 저하한다 — 그래서 판정이 내용이 아니라 **있었나**를 본다.
    const empty_base: StageSet = .{ .has_base = true, .has_ours = true, .has_theirs = true };
    try testing.expect(!empty_base.degradesToTwoWay());
}

test "이름 잇기: 여백이 들어가고, 자리가 모자라면 «안 쓴다»" {
    const names = [3][]const u8{ "aa", "bb", "cc" };
    const cols = struct {
        fn f(t: []const u8) u32 {
            return @intCast(t.len); // 이 판정자는 ASCII 만 쓴다 — 열 규칙은 호출자가 준다
        }
    }.f;
    var spans: [3]ActionSpan = undefined;
    var buf: [32]u8 = undefined;
    const written = writeActions(&names, &buf, cols, &spans).?;
    try testing.expectEqualStrings("aa" ++ action_gap ++ "bb" ++ action_gap ++ "cc", written);
    // 구간은 **닫힌-열린**이고 여백을 어느 쪽도 안 가져간다.
    try testing.expectEqual(@as(u32, 0), spans[0].from);
    try testing.expectEqual(@as(u32, 2), spans[0].to);
    try testing.expectEqual(@as(u32, 2 + action_gap.len), spans[1].from);
    try testing.expectEqual(@as(u32, @intCast(written.len)), spans[2].to);

    // **자리가 모자라면 한 바이트도 안 쓴다.** 호출자 중 하나(Chrome Lab)는 **고정 버퍼**를 주므로,
    // 이름이 길어지는 날 이 검사가 유일한 방어다 — 없으면 그 버퍼를 넘겨 쓴다.
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), writeActions(&names, &tiny, cols, &spans));
}

test "상태 기계: 한 구간을 낸 뒤에는 «처음부터» 다시 센다" {
    // 구간을 낸 뒤 상태를 안 비우면, 뒤따르는 `=======`·`>>>>>>>` 가 **옛 시작**과 짝지어져
    // 두 번째 「구간」이 선다 — 그 범위는 앞 구간의 머리부터라, 고르면 이미 고친 자리까지 지운다.
    const trailing = [_][]const u8{
        "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> t",
        "=======", "c", ">>>>>>> t", // 시작 없이 떠 있는 꼬리
    };
    var buf: [4]Region = undefined;
    const found = scan(&trailing, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 4), found[0].end);
}

test "상태 기계: 가름은 «첫 번째»가 이긴다" {
    // 구간 안에 `=======` 가 둘이면(손으로 고치다 생긴다) 경계는 **앞엣것**이다. 뒤엣것으로 덮으면
    // 「현재 것」이 남의 줄을 데려오고 「들어온 것」이 줄어든다.
    const two_seps = [_][]const u8{ "<<<<<<< HEAD", "a", "=======", "b", "=======", "c", ">>>>>>> t" };
    var buf: [4]Region = undefined;
    const found = scan(&two_seps, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 2), found[0].separator);
    try testing.expectEqual(@as(u32, 2), found[0].ours().to);
}

test "상태 기계: 가름 없이 닫히면 그 후보를 «버린다»" {
    // 버리지 않으면 뒤따르는 `=======`·`>>>>>>>` 가 그 시작과 짝지어져, **닫히지 않은 쓰레기**까지
    // 한 구간으로 묶인다 — 고르면 그 위쪽 멀쩡한 줄이 사라진다.
    const junk = [_][]const u8{ "<<<<<<< HEAD", "a", ">>>>>>> t", "=======", "b", ">>>>>>> t" };
    var buf: [4]Region = undefined;
    try testing.expectEqual(@as(usize, 0), scan(&junk, &buf).len);
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
