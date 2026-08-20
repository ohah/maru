//! 외부 소스 원장(`external_source_digests.zig`)의 **판정 규칙 단일 출처**.
//!
//! **왜 별도 파일인가.** 이 규칙은 `tests/boundary/imports.zig`(약 12,000줄) 안에 인라인으로 박혀 있었다.
//! 그래서 "digest 가 무엇을 덮는가"·"count 가 무엇을 세는가" 를 알려면 **게이트 구현을 읽어야** 했고,
//! 원장을 갱신하는 사람(하루에도 여러 번 한다)이 그 답을 찾을 자리가 없었다. 규칙은 계약이고, 계약은
//! 읽을 수 있어야 한다.
//!
//! **규칙이 지키는 것.** 원장의 두 값은 성질이 다르다 — 전수 측정으로 그 차이가 드러났다(원장을 건드린
//! 커밋 236 개 중 `count` 가 바뀐 것은 5 개, digest 만 바뀐 것은 207 개).
//!
//!   · `count` = 그 파일의 **반사 접근(`@field`) 개수**. 늘거나 주는 것은 "이 파일이 이름으로 무언가를
//!     꺼내는 자리가 달라졌다" 는 뜻이고, 그때는 사람이 볼 것이 있다. 실제로 그 다섯 번 다 작성자가
//!     반사를 일부러 늘린 회차였다.
//!   · `digest` = 그 파일의 **test 블록을 뺀 전체 토큰** 해시. 반사 자리의 **내용**이 달라지는 것
//!     (개수는 그대로인데 대상이 바뀌는 것)을 잡으려는 값인데, 지금은 주석 한 줄에도 똑같이 움직인다.
//!     그래서 이 값이 움직였다는 사실은 그 사건에 대해 정보를 거의 주지 않는다 — 사람이 하는 일이
//!     "해시를 다시 재 넣는다" 뿐인 이유다. `docs/project-rules.md` `## 리베이스와 머지` 참조.
//!
//! **그래서 이 파일이 먼저 생겼다.** 감시 범위를 반사 자리로 좁히려면 그 정의가 한 곳에 있어야 한다 —
//! 판정자와 도구에 두 벌로 들어가면 이 저장소가 반복해서 당한 형태(두 벌이 갈린다)가 된다. 지금은
//! **동작을 바꾸지 않는다**: 옛 인라인 구현과 **바이트 단위로 같은 digest** 를 내는 것이 이 추출의
//! 합격 조건이고, 원장이 한 줄도 안 움직이는 것으로 확인한다.
const std = @import("std");

/// 한 소스 파일의 판정 결과.
pub const Result = struct {
    /// test 블록을 뺀 전체 토큰의 SHA-256.
    digest: [32]u8,
    /// 반사 접근(`@field`) 개수. session_host 축은 별도 계약(닫힌 세계)이라 여기서 안 센다.
    reflection_count: usize,

    pub fn digestHex(self: Result) [64]u8 {
        return std.fmt.bytesToHex(self.digest, .lower);
    }
};

/// `tree` 의 토큰 중 **최상위 `test` 블록에 속한 것**을 표시한다.
///
/// 테스트를 빼는 이유는 원장이 지키려는 것이 **제품 코드의 성질**이기 때문이다 — 테스트를 고쳤다고
/// 원장이 움직이면 그 신호는 더 자주 켜지고 더 안 읽힌다. 다만 이 마스킹은 **digest 를 "파일이 바뀌었다"
/// 의 신호로 읽을 수 없게** 만들기도 한다(테스트만 고친 회차에는 안 움직인다). 그 성질을 여기 적어 두는
/// 이유는, 그것이 감시 범위를 좁히는 쪽 논거의 일부이기 때문이다.
pub fn topLevelTestTokenMask(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
) ![]bool {
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
                    if (!body_started or body_depth == 0)
                        return error.TestUnexpectedResult;
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

/// `path` 의 소스에서 digest 와 반사 개수를 낸다. **옛 인라인 구현과 같은 값을 내는 것이 계약이다** —
/// 토큰 순회 순서·구분자(`\0`)·`@field` 판정이 그대로여야 원장이 안 움직인다.
///
/// `@field` 를 **토큰 문자열로** 찾는 이유는 이 판정이 AST 의미가 아니라 표기를 보기 때문이다. 별칭을
/// 거쳐 부르면(`const f = @field;` 같은 것) 안 잡힌다 — 놓치는 방향이라 없는 위반을 만들지는 않는다.
pub fn compute(allocator: std.mem.Allocator, tree: *const std.zig.Ast, path: []const u8) !Result {
    const test_tokens = try topLevelTestTokenMask(allocator, tree);
    defer allocator.free(test_tokens);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var reflection_count: usize = 0;

    // **session_host 축은 세지 않는다.** 그쪽은 "닫힌 세계" 계약이라 반사 자리마다 별도 증명을 요구하고,
    // 그 심사는 게이트가 자기 자리에서 한다. 여기서 함께 세면 두 계약이 한 숫자에 섞인다.
    const session_host = std.mem.startsWith(u8, path, "src/platform/macos/session_host/");

    var token: std.zig.Ast.TokenIndex = 0;
    while (token + 1 < tree.tokens.len) : (token += 1) {
        if (test_tokens[token]) continue;
        hasher.update(tree.tokenSlice(token));
        hasher.update(&.{0});
        if (!std.mem.eql(u8, tree.tokenSlice(token), "@field")) continue;
        if (!session_host) reflection_count += 1;
    }

    var out: Result = .{ .digest = undefined, .reflection_count = reflection_count };
    hasher.final(&out.digest);
    return out;
}

// 규칙이 **정말 무엇을 세고 무엇을 빼는지**를 못 박는다. 이 파일이 생긴 이유가 "규칙을 읽을 수 있게" 인데,
// 읽을 수 있는 것과 참인 것은 다르다.
test "digest 는 test 블록을 빼고, count 는 @field 만 센다" {
    const a = std.testing.allocator;
    const src =
        \\pub fn f() void {
        \\    const x = @field(S, "a");
        \\    _ = x;
        \\}
        \\test "이 안의 @field 는 안 센다" {
        \\    const y = @field(S, "b");
        \\    _ = y;
        \\}
    ;
    var tree = try std.zig.Ast.parse(a, src, .zig);
    defer tree.deinit(a);

    const r = try compute(a, &tree, "src/x.zig");
    try std.testing.expectEqual(@as(usize, 1), r.reflection_count); // 제품 코드의 하나만

    // **테스트만 고치면 digest 가 안 움직인다** — 이것이 digest 를 "파일이 바뀌었다" 로 읽을 수 없는 이유다.
    const src2 =
        \\pub fn f() void {
        \\    const x = @field(S, "a");
        \\    _ = x;
        \\}
        \\test "이 안의 @field 는 안 센다" {
        \\    const y = @field(S, "b");
        \\    _ = y;
        \\    const z = 1; // 테스트만 바꿨다
        \\    _ = z;
        \\}
    ;
    var tree2 = try std.zig.Ast.parse(a, src2, .zig);
    defer tree2.deinit(a);
    const r2 = try compute(a, &tree2, "src/x.zig");
    try std.testing.expectEqual(r.digest, r2.digest);

    // 반면 **제품 코드가 바뀌면** 움직인다(안 움직이면 이 게이트는 아무것도 안 지킨다).
    const src3 =
        \\pub fn f() void {
        \\    const x = @field(S, "a");
        \\    _ = x;
        \\    const w = 2;
        \\    _ = w;
        \\}
    ;
    var tree3 = try std.zig.Ast.parse(a, src3, .zig);
    defer tree3.deinit(a);
    const r3 = try compute(a, &tree3, "src/x.zig");
    try std.testing.expect(!std.mem.eql(u8, &r.digest, &r3.digest));

    // session_host 축은 세지 않는다(그쪽은 별도 계약).
    const r4 = try compute(a, &tree, "src/platform/macos/session_host/x.zig");
    try std.testing.expectEqual(@as(usize, 0), r4.reflection_count);
}
