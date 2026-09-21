//! 빌드 그래프를 **문자열이 아니라 구조로** 보는 뷰.
//!
//! **왜 있나.** 판정자 178자리가 빌드 소스를 문자열로 세고 있다 —
//! `count(build, "run_b3_0_4_tests.addArg(\"--maru-expect-tests=8\")")` 같은 형태다.
//! 그 방식은 세 가지로 약하다:
//!   ① 공백·줄바꿈·주석이 한 글자만 달라져도 죽는다,
//!   ② 등록을 다른 파일로 옮기면 「찾던 것이 사라져」 죽는다(2026-09-21 에 52개가 그렇게 죽었다),
//!   ③ 같은 이름의 다른 자리를 구분하지 못한다.
//! [필수 프로젝트 규칙](../../docs/project-rules.md)이 적어 둔 **"문자열로 구조를 찾지 말고
//! 구조로 찾아라"** 가 가리키는 자리다.
//!
//! **무엇을 읽나.** 「빌드 소스」의 정의는 [build_source.zig](build_source.zig) 하나가 소유하고,
//! 여기서는 그 `paths()` 를 받아 **파일별로** 파싱한다 — `build_source.read()` 가 돌려주는
//! 이어 붙인 텍스트는 유효한 Zig 파일이 아니라 `std.zig.Ast` 가 받지 못한다.
//!
//! **이 뷰가 못 하는 것.** 일부러 잘라 쓴 접두 매칭(`"pub fn scrollTextViewport("` 처럼)은
//! 옮기면 뜻이 바뀐다. 그런 자리는 문자열 판정으로 남기고 이유를 그 자리에 적는다.
//!
//! 이 저장소는 이미 `std.zig.Ast` 판정자를 여럿 갖고 있지만(`cli_purity`·`imports`·
//! `i18n_literals` 등) 공유 헬퍼가 없어 각자 파서를 세운다. 빌드 그래프만큼은 여기로 모은다.

const std = @import("std");
/// **모듈 이름으로 받는다.** 상대 경로(`@import("build_source.zig")`)로 끌어오면 같은 컴파일에서
/// 그 파일이 `build_source` 모듈의 루트이기도 해서 Zig 가 거절한다
/// (`file exists in modules 'build_source' and 'build_graph'`). 모듈은 하나만 만들고 둘이 나눠 쓴다.
const build_source = @import("build_source");

const max_bytes = 8 * 1024 * 1024;

/// `b.step("name", "description")` 한 건.
pub const Step = struct {
    name: []const u8,
    description: ?[]const u8,
};

/// `addProjectTest(b, .{ .root_module = b.createModule(.{...}), .filters = &.{...} })` 한 건.
pub const Registration = struct {
    /// `const b3_0_4_tests = addProjectTest(...)` 의 왼쪽 이름. 이름 없이 바로 넘기면 null.
    var_name: ?[]const u8 = null,
    /// `.root_source_file = b.path("…")` 의 경로.
    root: ?[]const u8 = null,
    /// `.filters = &.{ "A", "B" }` 의 원소.
    filters: []const []const u8 = &.{},
    /// `.optimize = …` 의 **표현식 텍스트**(`optimize`·`.ReleaseFast`·`b3_optimize` 등).
    /// 값으로 접지 않는 이유는 빌드 스크립트가 변수를 거쳐 넘기기 때문이다.
    optimize: ?[]const u8 = null,
    /// `.imports = &.{ .{ .name = "maru", … } }` 의 이름들.
    imports: []const []const u8 = &.{},
    link_libc: bool = false,
    /// 어느 파일에서 왔나 — 실패를 쫓을 때 필요하다.
    file: []const u8 = "",
};

/// 한 **변수 이름**에 대해 일어난 배선. 판정자가 `run_x.addArg("…")` 를 세던 것을 그대로 받는다.
pub const VarCalls = struct {
    name: []const u8,
    /// `x.addArg("…")` 의 인자.
    args: []const []const u8 = &.{},
    /// `x.step.dependOn(&y.step)` 의 `y`.
    depends_on: []const []const u8 = &.{},
    /// `x.setEnvironmentVariable("K", …)` 의 K.
    envs: []const []const u8 = &.{},
    file: []const u8 = "",
};

pub const Graph = struct {
    arena: *std.heap.ArenaAllocator,
    steps: []const Step,
    registrations: []const Registration,
    vars: []const VarCalls,
    /// `std.builtin.OptimizeMode.Debug` 처럼 **점으로 이어진 이름 경로**의 등장. 판정자가
    /// 그 문자열을 세던 자리를 받는다.
    field_paths: []const []const u8,

    pub fn deinit(self: *Graph) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn step(self: Graph, name: []const u8) ?Step {
        for (self.steps) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub fn varCalls(self: Graph, name: []const u8) ?VarCalls {
        for (self.vars) |v| if (std.mem.eql(u8, v.name, name)) return v;
        return null;
    }

    pub fn countRegistrationsWithFilter(self: Graph, filter: []const u8) usize {
        var n: usize = 0;
        for (self.registrations) |r| {
            for (r.filters) |f| if (std.mem.eql(u8, f, filter)) {
                n += 1;
                break;
            };
        }
        return n;
    }

    pub fn countRegistrationsWithRoot(self: Graph, root: []const u8) usize {
        var n: usize = 0;
        for (self.registrations) |r| {
            if (r.root) |x| if (std.mem.eql(u8, x, root)) {
                n += 1;
            };
        }
        return n;
    }

    pub fn countFieldPath(self: Graph, path: []const u8) usize {
        var n: usize = 0;
        for (self.field_paths) |p| if (std.mem.eql(u8, p, path)) {
            n += 1;
        };
        return n;
    }

    pub fn hasArg(self: Graph, var_name: []const u8, arg: []const u8) bool {
        const v = self.varCalls(var_name) orelse return false;
        for (v.args) |a| if (std.mem.eql(u8, a, arg)) return true;
        return false;
    }

    pub fn dependsOn(self: Graph, var_name: []const u8, target: []const u8) bool {
        const v = self.varCalls(var_name) orelse return false;
        for (v.depends_on) |d| if (std.mem.eql(u8, d, target)) return true;
        return false;
    }
};

/// 빌드 소스 전체를 파싱해 뷰를 만든다. 호출자는 `deinit` 한다.
pub fn parse(gpa: std.mem.Allocator) !Graph {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    }
    const a = arena_ptr.allocator();

    var steps: std.ArrayList(Step) = .empty;
    var regs: std.ArrayList(Registration) = .empty;
    var vars: std.StringHashMap(VarCalls) = .init(a);
    var field_paths: std.ArrayList([]const u8) = .empty;

    const files = try build_source.paths(gpa);
    defer build_source.freePaths(gpa, files);

    for (files) |path| {
        const owned_path = try a.dupe(u8, path);
        const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_bytes));
        const src = try a.dupeZ(u8, raw);
        var tree = try std.zig.Ast.parse(a, src, .zig);
        if (tree.errors.len != 0) return error.BuildSourceParseFailed;

        try scanFile(a, &tree, owned_path, &steps, &regs, &vars, &field_paths);
    }

    return .{
        .arena = arena_ptr,
        .steps = try steps.toOwnedSlice(a),
        .registrations = try regs.toOwnedSlice(a),
        .vars = blk: {
            var list = try std.ArrayList(VarCalls).initCapacity(a, vars.count());
            var it = vars.valueIterator();
            while (it.next()) |v| try list.append(a, v.*);
            break :blk try list.toOwnedSlice(a);
        },
        .field_paths = try field_paths.toOwnedSlice(a),
    };
}

// ── 파싱 내부 ────────────────────────────────────────────────────────────────

/// 문자열 리터럴 토큰의 «값». `"a\"b"` 같은 이스케이프를 푼다.
fn stringValue(a: std.mem.Allocator, tree: *const std.zig.Ast, tok: std.zig.Ast.TokenIndex) !?[]const u8 {
    if (tree.tokenTag(tok) != .string_literal) return null;
    const raw = tree.tokenSlice(tok);
    return try std.zig.string_literal.parseAlloc(a, raw);
}

/// 호출 노드에서 «여는 괄호 직전의 마지막 identifier» — 호출된 이름.
fn calleeName(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    var tok = tree.firstToken(node);
    const last = tree.lastToken(node);
    var found: ?[]const u8 = null;
    while (tok <= last) : (tok += 1) {
        const tag = tree.tokenTag(tok);
        if (tag == .l_paren) break;
        if (tag == .identifier) found = tree.tokenSlice(tok);
    }
    return found;
}

/// 호출 노드에서 receiver 의 **첫** identifier — `run_x.step.dependOn(...)` 이면 `run_x`.
fn receiverName(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    var tok = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (tok <= last) : (tok += 1) {
        const tag = tree.tokenTag(tok);
        if (tag == .l_paren) break;
        if (tag == .identifier) return tree.tokenSlice(tok);
    }
    return null;
}

/// `const NAME = <이 노드>` 의 NAME.
fn boundVarName(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    const first = tree.firstToken(node);
    if (first < 2) return null;
    if (tree.tokenTag(first - 1) != .equal) return null;
    if (tree.tokenTag(first - 2) != .identifier) return null;
    if (first >= 3 and tree.tokenTag(first - 3) != .keyword_const and
        tree.tokenTag(first - 3) != .keyword_var) return null;
    return tree.tokenSlice(first - 2);
}

fn upsertVar(
    a: std.mem.Allocator,
    vars: *std.StringHashMap(VarCalls),
    name: []const u8,
    file: []const u8,
) !*VarCalls {
    const gop = try vars.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = .{ .name = try a.dupe(u8, name), .file = file };
    return gop.value_ptr;
}

fn appendStr(a: std.mem.Allocator, slice: *[]const []const u8, item: []const u8) !void {
    const grown = try a.alloc([]const u8, slice.len + 1);
    @memcpy(grown[0..slice.len], slice.*);
    grown[slice.len] = item;
    slice.* = grown;
}

fn scanFile(
    a: std.mem.Allocator,
    tree: *std.zig.Ast,
    file: []const u8,
    steps: *std.ArrayList(Step),
    regs: *std.ArrayList(Registration),
    vars: *std.StringHashMap(VarCalls),
    field_paths: *std.ArrayList([]const u8),
) !void {
    // ① 점으로 이어진 이름 경로 — `std.builtin.OptimizeMode.Debug`
    //    토큰열로 모은다(AST 노드로는 조각이 흩어져 오히려 복잡하다).
    var i: std.zig.Ast.TokenIndex = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokenTag(i) != .identifier) continue;
        if (i > 0 and tree.tokenTag(i - 1) == .period) continue; // 경로 중간이면 시작이 아니다
        var end = i;
        while (end + 2 < tree.tokens.len and
            tree.tokenTag(end + 1) == .period and
            tree.tokenTag(end + 2) == .identifier) end += 2;
        if (end == i) continue; // 점이 없으면 경로가 아니다
        var buf: std.ArrayList(u8) = .empty;
        var t = i;
        while (t <= end) : (t += 2) {
            if (t != i) try buf.append(a, '.');
            try buf.appendSlice(a, tree.tokenSlice(t));
        }
        try field_paths.append(a, try buf.toOwnedSlice(a));
        i = end;
    }

    // ② 호출 노드
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_i);
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buf, node) orelse continue;
        const callee = calleeName(tree, node) orelse continue;

        if (std.mem.eql(u8, callee, "step") and call.ast.params.len >= 1) {
            // b.step("name", "desc")
            const name = (try stringValue(a, tree, tree.firstToken(call.ast.params[0]))) orelse continue;
            var desc: ?[]const u8 = null;
            if (call.ast.params.len >= 2)
                desc = try stringValue(a, tree, tree.firstToken(call.ast.params[1]));
            try steps.append(a, .{ .name = name, .description = desc });
        } else if (std.mem.eql(u8, callee, "addProjectTest")) {
            var r: Registration = .{ .var_name = boundVarName(tree, node), .file = file };
            for (call.ast.params) |p| try readRegistrationFields(a, tree, p, &r, 0);
            try regs.append(a, r);
        } else if (std.mem.eql(u8, callee, "addArg") and call.ast.params.len == 1) {
            const owner = receiverName(tree, node) orelse continue;
            const v = try upsertVar(a, vars, owner, file);
            if (try stringValue(a, tree, tree.firstToken(call.ast.params[0]))) |s|
                try appendStr(a, &v.args, s);
        } else if (std.mem.eql(u8, callee, "setEnvironmentVariable") and call.ast.params.len >= 1) {
            const owner = receiverName(tree, node) orelse continue;
            const v = try upsertVar(a, vars, owner, file);
            if (try stringValue(a, tree, tree.firstToken(call.ast.params[0]))) |s|
                try appendStr(a, &v.envs, s);
        } else if (std.mem.eql(u8, callee, "dependOn") and call.ast.params.len == 1) {
            const owner = receiverName(tree, node) orelse continue;
            const v = try upsertVar(a, vars, owner, file);
            // `&run_x.step` 의 run_x
            const p = call.ast.params[0];
            var tok = tree.firstToken(p);
            const last = tree.lastToken(p);
            while (tok <= last) : (tok += 1) {
                if (tree.tokenTag(tok) == .identifier) {
                    try appendStr(a, &v.depends_on, tree.tokenSlice(tok));
                    break;
                }
            }
        }
    }
}

/// `addProjectTest` 인자의 struct 리터럴을 재귀로 훑어 필드를 채운다.
fn readRegistrationFields(
    a: std.mem.Allocator,
    tree: *std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    out: *Registration,
    depth: usize,
) !void {
    if (depth > 5) return;
    var sbuf: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&sbuf, node)) |si| {
        for (si.ast.fields) |f| {
            const ft = tree.firstToken(f);
            var fname: ?[]const u8 = null;
            if (ft >= 2 and tree.tokenTag(ft - 1) == .equal and tree.tokenTag(ft - 2) == .identifier)
                fname = tree.tokenSlice(ft - 2);

            if (fname) |n| {
                if (std.mem.eql(u8, n, "root_source_file")) {
                    // b.path("…") 안의 문자열
                    var tok = tree.firstToken(f);
                    const last = tree.lastToken(f);
                    while (tok <= last) : (tok += 1) {
                        if (try stringValue(a, tree, tok)) |s| {
                            out.root = s;
                            break;
                        }
                    }
                } else if (std.mem.eql(u8, n, "filters")) {
                    var tok = tree.firstToken(f);
                    const last = tree.lastToken(f);
                    while (tok <= last) : (tok += 1) {
                        if (try stringValue(a, tree, tok)) |s| try appendStr(a, &out.filters, s);
                    }
                } else if (std.mem.eql(u8, n, "optimize")) {
                    const first = tree.firstToken(f);
                    const last = tree.lastToken(f);
                    const start = tree.tokenStart(first);
                    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
                    out.optimize = try a.dupe(u8, std.mem.trim(u8, tree.source[start..end], " \t\n"));
                } else if (std.mem.eql(u8, n, "link_libc")) {
                    var tok = tree.firstToken(f);
                    const last = tree.lastToken(f);
                    while (tok <= last) : (tok += 1) {
                        if (tree.tokenTag(tok) == .identifier and
                            std.mem.eql(u8, tree.tokenSlice(tok), "true")) out.link_libc = true;
                    }
                } else if (std.mem.eql(u8, n, "name")) {
                    if (try stringValue(a, tree, tree.firstToken(f))) |s|
                        try appendStr(a, &out.imports, s);
                }
            }
            try readRegistrationFields(a, tree, f, out, depth + 1);
        }
        return;
    }
    var cbuf: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullCall(&cbuf, node)) |call| {
        for (call.ast.params) |p| try readRegistrationFields(a, tree, p, out, depth + 1);
    }
}

// ── 자체 검증 ────────────────────────────────────────────────────────────────
//
// **옛 방식과 새 방식이 같은 값을 내는지 대조한다.** 이 뷰의 목적은 문자열 판정을 대체하는
// 것이고, 대체가 성립하려면 «같은 것을 세야» 한다. 문자열 판정을 지우기 전에 이 대조를 통과시킨다.

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        n += 1;
        rest = rest[at + needle.len ..];
    }
    return n;
}

test "빌드 그래프 뷰는 문자열 판정과 같은 값을 낸다 (B3-0.4 게이트)" {
    const a = std.testing.allocator;

    // 옛 방식 — 이어 붙인 소스를 문자열로 센다
    const text = try build_source.read(a);
    defer a.free(text);

    // 새 방식 — 파일별 AST 뷰
    var g = try parse(a);
    defer g.deinit();

    // ① 스텝 이름
    try std.testing.expectEqual(
        countOccurrences(text, "\"test-session-host-b3-0-4\""),
        @as(usize, if (g.step("test-session-host-b3-0-4") != null) 1 else 0),
    );
    // ② filters 원소
    try std.testing.expectEqual(
        countOccurrences(text, ".filters = &.{\"B3-0.4\"}"),
        g.countRegistrationsWithFilter("B3-0.4"),
    );
    try std.testing.expectEqual(
        countOccurrences(text, ".filters = &.{\"B3-0.1 pre-wire issuer exhaustion\"}"),
        g.countRegistrationsWithFilter("B3-0.1 pre-wire issuer exhaustion"),
    );
    // ③ 이름 경로
    try std.testing.expectEqual(
        countOccurrences(text, "std.builtin.OptimizeMode.Debug"),
        g.countFieldPath("std.builtin.OptimizeMode.Debug"),
    );
    try std.testing.expectEqual(
        countOccurrences(text, "std.builtin.OptimizeMode.ReleaseFast"),
        g.countFieldPath("std.builtin.OptimizeMode.ReleaseFast"),
    );
    // ④ 특정 변수의 인자·의존
    try std.testing.expect(g.hasArg("run_b3_0_4_tests", "--maru-expect-tests=8"));
    try std.testing.expect(g.dependsOn("run_b3_0_4_tests", "run_b3_strict_cleanup_tests"));
    try std.testing.expect(g.dependsOn("run_b3_0_4_tests", "run_b3_issuer_cleanup_tests"));
    // ⑤ 같은 root 를 쓰는 «등록» 수 — **여기서 두 값이 갈리고, 그 갈림이 이 뷰의 존재 이유다.**
    //
    // 문자열 판정(`imports.zig` 의 "B3-0.4 focused product gate…")은 이 경로가 **15번** 나온다고
    // 세고 그 숫자를 등록 수로 읽는다. 실제로 세어 보면 그중 **셋은 등록이 아니다** —
    // 별도 `b.createModule` 하나(`event_2c3e_c1_transport_module`)와 `inline for` 표의 행 둘이다.
    // 뷰는 `addProjectTest` 만 세므로 **12**다.
    //
    // 어느 쪽이 맞느냐는 그 판정자의 의도에 달렸다. 옮길 때 작성자 의도를 확인해야 하므로
    // 여기서는 **두 값을 모두 고정**해 둔다 — 한쪽만 적으면 다음 사람이 차이를 모르고 지나간다.
    const root_path = "src/platform/macos/session_host/generation_transport.zig";
    try std.testing.expectEqual(@as(usize, 15), countOccurrences(text, root_path));
    try std.testing.expectEqual(@as(usize, 12), g.countRegistrationsWithRoot(root_path));
}
