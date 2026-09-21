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
//! **이 뷰가 못 하는 것 — 실제로 세어 보니 넷뿐이다.** 빌드 스크립트의 **제어 흐름과 선언**
//! (`if (index % shard.count != shard.index) continue;` · `const x = b.option(` ·
//! `fn isolateMacosProductTest(…) void`), 빌드 소스 안에 박힌 **셸/정규식 조각**
//! (`^final_frame_ended=true$` · `stat -f '%i'`), **파일 이름**(`*.swift`·`*.json`),
//! 그리고 중첩 struct 의 메서드 호출(`B3SettlementTest.add(b, …`)이다.
//! 이건 「빌드 그래프」가 아니라 스크립트 본문이라, 담으려면 AST 전체를 노출해야 한다 —
//! 그럴 거면 판정자가 `std.zig.Ast` 를 직접 쓰는 게 맞다(이 저장소가 이미 9곳에서 그렇게 한다).
//!
//! **「접두 매칭이라 못 옮긴다」는 대개 오해다.** `count(build, "boundary_step.dependOn(&run_")`
//! 같은 자리는 `countDependenciesWithPrefix("boundary_step", "run_")` 로 **더 정확해진다** —
//! 실제로 그 문자열은 여는 괄호 뒤에 줄바꿈이 든 자리 하나를 못 세고 있었다(222 vs 223).
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
///
/// **receiver 로 한 번이라도 등장하면 이 구조가 만들어진다.** 그래야 `varCalls` 의 `null` 이
/// 「그런 변수가 없다」**만** 뜻하고, 「호출이 없다」는 빈 필드로 구분된다.
/// 예전에는 `addArg`·`env`·`dependOn` 셋을 하는 변수만 담아서, `setCwd` 만 하는 run 변수가
/// **존재 자체로 안 보였고** 그래서 「배관이 없다」는 틀린 결론이 나왔다(실측: 142건 중 배관이
/// 있는 것을 45건이라 읽었는데 실제로는 85건이었다).
pub const VarCalls = struct {
    name: []const u8,
    /// `x.addArg("…")` 의 인자.
    args: []const []const u8 = &.{},
    /// `x.step.dependOn(&y.step)`·`x.dependOn(y)` 의 `y`.
    depends_on: []const []const u8 = &.{},
    /// `x.setEnvironmentVariable("K", …)` 의 K.
    envs: []const []const u8 = &.{},
    /// `x.addArtifactArg(y)`·`addPrefixedArtifactArg(…, y)`·`addFileArg(…)` 의 대상 이름/경로.
    artifact_args: []const []const u8 = &.{},
    /// `x.setCwd(…)` 를 불렀는가.
    cwd_set: bool = false,
    /// **뷰가 이름만 알고 내용은 안 담은 호출들.** 이 목록이 비어 있지 않다는 사실 자체가
    /// 「여기에 뷰가 모르는 배선이 있다」는 신호다 — 없는 것을 없다고 읽는 사고를 막는 자리다.
    other: []const []const u8 = &.{},
    file: []const u8 = "",
};

/// 호출 한 건의 **이름과 첫 문자열 인자**. receiver 가 제각각인 질문(`linkFramework("…")`)을 위해
/// 최소한만 담는다 — 인자 전체를 담으면 뷰가 AST 의 두 번째 사본이 된다.
pub const Call = struct {
    method: []const u8,
    receiver: ?[]const u8 = null,
    first_arg: ?[]const u8 = null,
    file: []const u8 = "",
};

pub const Graph = struct {
    arena: *std.heap.ArenaAllocator,
    steps: []const Step,
    registrations: []const Registration,
    vars: []const VarCalls,
    /// 빌드 소스의 **모든 메서드 호출**(이름 + 첫 문자열 인자). `countCall` 이 쓴다.
    calls: []const Call,
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

    /// 그 변수가 매단 대상 **전부**. 판정자가 접두(`run_` 로 시작하는 것)나 개수를 직접 물을 때 쓴다 —
    /// `count(build, "boundary_step.dependOn(&run_") >= 100` 같은 문자열 판정을 이것으로 옮긴다.
    /// 그런 변수가 아예 없으면 빈 슬라이스다(`null` 과 구분하지 않는다 — 호출자가 묻는 것은 「몇을 매달았나」다).
    pub fn dependenciesOf(self: Graph, var_name: []const u8) []const []const u8 {
        const v = self.varCalls(var_name) orelse return &.{};
        return v.depends_on;
    }

    /// **역방향** — 누가 이것을 매달았나. `step.dependOn(&run_x.step)` 는 `step` 쪽에 기록되므로,
    /// 「이 run 이 어느 step 에 붙었나」는 이 함수로만 답할 수 있다.
    ///
    /// **이 API 가 없어서 실제로 틀렸다**: 파일럿 범위를 재면서 38건이 「어느 step 에도 안 매달린다」고
    /// 읽었는데, 실은 `oracle_step.dependOn(&run_oracle_tests.step)` 처럼 **매달려 있었다**.
    /// 방향이 하나뿐인 조회는 빈 값을 「없다」로 읽게 만든다 — 그것이 이 파일이 고치려는 사고다.
    ///
    /// 호출자가 결과를 소유하지 않는다(뷰의 arena 수명을 따른다). 채울 버퍼를 받는다.
    pub fn dependentsOf(
        self: Graph,
        target: []const u8,
        out: *std.ArrayList([]const u8),
        a: std.mem.Allocator,
    ) !void {
        for (self.vars) |v| {
            for (v.depends_on) |d| {
                if (std.mem.eql(u8, d, target)) {
                    try out.append(a, v.name);
                    break;
                }
            }
        }
    }

    /// 누가 이것을 매달았는지의 **수**. 버퍼 없이 묻고 싶을 때.
    pub fn countDependentsOf(self: Graph, target: []const u8) usize {
        var n: usize = 0;
        for (self.vars) |v| {
            for (v.depends_on) |d| {
                if (std.mem.eql(u8, d, target)) {
                    n += 1;
                    break;
                }
            }
        }
        return n;
    }

    /// `dependenciesOf` 중 접두가 맞는 것의 수.
    pub fn countDependenciesWithPrefix(self: Graph, var_name: []const u8, prefix: []const u8) usize {
        var n: usize = 0;
        for (self.dependenciesOf(var_name)) |d| {
            if (std.mem.startsWith(u8, d, prefix)) n += 1;
        }
        return n;
    }

    /// 메서드 이름과 **첫 문자열 인자**로 호출을 센다 — `linkFramework("UserNotifications")` 처럼
    /// receiver 가 제각각이라 변수로 물을 수 없는 자리를 위해서다.
    pub fn countCall(self: Graph, method: []const u8, first_arg: []const u8) usize {
        var n: usize = 0;
        for (self.calls) |c| {
            if (!std.mem.eql(u8, c.method, method)) continue;
            const a = c.first_arg orelse continue;
            if (std.mem.eql(u8, a, first_arg)) n += 1;
        }
        return n;
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
    var calls: std.ArrayList(Call) = .empty;

    const files = try build_source.paths(gpa);
    defer build_source.freePaths(gpa, files);

    for (files) |path| {
        const owned_path = try a.dupe(u8, path);
        const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_bytes));
        const src = try a.dupeZ(u8, raw);
        var tree = try std.zig.Ast.parse(a, src, .zig);
        if (tree.errors.len != 0) return error.BuildSourceParseFailed;

        try scanFile(a, &tree, owned_path, &steps, &regs, &vars, &field_paths, &calls);
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
        .calls = try calls.toOwnedSlice(a),
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
    calls: *std.ArrayList(Call),
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

        // ② 모든 호출을 «이름 + 첫 문자열 인자» 로만 남긴다 — receiver 가 제각각인 질문을 위해서다.
        const recv = receiverName(tree, node);
        var first_arg: ?[]const u8 = null;
        if (call.ast.params.len >= 1)
            first_arg = try stringValue(a, tree, tree.firstToken(call.ast.params[0]));
        try calls.append(a, .{
            .method = callee,
            .receiver = recv,
            .first_arg = first_arg,
            .file = file,
        });

        if (std.mem.eql(u8, callee, "step") and call.ast.params.len >= 1) {
            // b.step("name", "desc")
            const name = (try stringValue(a, tree, tree.firstToken(call.ast.params[0]))) orelse continue;
            var desc: ?[]const u8 = null;
            if (call.ast.params.len >= 2)
                desc = try stringValue(a, tree, tree.firstToken(call.ast.params[1]));
            try steps.append(a, .{ .name = name, .description = desc });
            continue;
        }
        if (std.mem.eql(u8, callee, "addProjectTest")) {
            var r: Registration = .{ .var_name = boundVarName(tree, node), .file = file };
            for (call.ast.params) |p| try readRegistrationFields(a, tree, p, &r, 0);
            try regs.append(a, r);
            continue;
        }

        // ③ **receiver 가 있으면 무조건 VarCalls 를 만든다.** 이것이 이 뷰의 핵심 규율이다 —
        //    그래야 `varCalls` 의 null 이 「그런 변수가 없다」만 뜻한다. 예전에는 아래 세 갈래에
        //    걸리는 호출만 담아서, `setCwd` 만 하는 변수가 존재 자체로 안 보였다.
        const owner = recv orelse continue;
        if (std.mem.eql(u8, owner, callee)) continue; // receiver 없는 평범한 함수 호출
        const v = try upsertVar(a, vars, owner, file);

        if (std.mem.eql(u8, callee, "addArg") and call.ast.params.len == 1) {
            if (first_arg) |s| try appendStr(a, &v.args, s);
        } else if (std.mem.eql(u8, callee, "setEnvironmentVariable") and call.ast.params.len >= 1) {
            if (first_arg) |s| try appendStr(a, &v.envs, s);
        } else if (std.mem.eql(u8, callee, "dependOn") and call.ast.params.len == 1) {
            // `&run_x.step` 의 run_x · `session_host_x_step` 처럼 step 을 바로 주는 형태도 받는다
            if (firstIdentIn(tree, call.ast.params[0])) |name|
                try appendStr(a, &v.depends_on, name);
        } else if (std.mem.eql(u8, callee, "setCwd")) {
            v.cwd_set = true;
        } else if (std.mem.eql(u8, callee, "addArtifactArg") or
            std.mem.eql(u8, callee, "addPrefixedArtifactArg") or
            std.mem.eql(u8, callee, "addFileArg"))
        {
            // 인자가 아티팩트 변수면 그 이름을, 경로 리터럴이면 그 경로를 담는다.
            if (call.ast.params.len >= 1) {
                const p = call.ast.params[call.ast.params.len - 1];
                if (try firstStringIn(a, tree, p)) |s| {
                    try appendStr(a, &v.artifact_args, s);
                } else if (firstIdentIn(tree, p)) |name| {
                    try appendStr(a, &v.artifact_args, name);
                }
            }
        } else {
            // **담지 않은 호출은 이름만 남긴다.** 이 목록이 비어 있지 않다는 사실이
            // 「여기 뷰가 모르는 배선이 있다」는 신호가 된다.
            try appendStr(a, &v.other, callee);
        }
    }
}

/// 노드 안의 첫 identifier — `&run_x.step` 이면 `run_x`.
fn firstIdentIn(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    var tok = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (tok <= last) : (tok += 1) {
        if (tree.tokenTag(tok) == .identifier) return tree.tokenSlice(tok);
    }
    return null;
}

/// 노드 안의 첫 문자열 리터럴 값 — `b.path("tools/x.sh")` 이면 `tools/x.sh`.
fn firstStringIn(a: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) !?[]const u8 {
    var tok = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (tok <= last) : (tok += 1) {
        if (try stringValue(a, tree, tok)) |s| return s;
    }
    return null;
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

test "receiver 가 있으면 VarCalls 가 «무조건» 생긴다 — null 은 「그런 변수가 없다」만 뜻한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    // `setCwd` 만 하는 run 변수도 보여야 한다. 예전 뷰는 이것을 놓쳐
    // 「배관이 없다」는 틀린 결론을 냈다(142건 중 45건이라 읽었는데 실제는 85건).
    const v = g.varCalls("run_macos_window_smoke_tests") orelse return error.TestUnexpectedResult;
    try std.testing.expect(v.cwd_set);

    // 존재하지 않는 이름은 null 이다 — 이 둘이 구분되는 것이 이 확장의 요점이다.
    try std.testing.expect(g.varCalls("run_this_name_does_not_exist_v1") == null);
}

test "dependenciesOf 는 접두·개수 질문을 문자열 없이 답한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // 옛 방식: count(build, "boundary_step.dependOn(&run_") >= 100
    // 새 방식: boundary_step 이 매단 것 중 `run_` 접두인 것
    //
    // **여기서 두 값이 갈리고, 그 갈림이 이 뷰의 존재 이유다.** 문자열은 222, 뷰는 223 이다.
    // 차이 하나는 `build.zig` 의
    //     boundary_step.dependOn(
    //         &run_session_host_upgrade_component_failure_matrix_boundary_tests.step,
    //     );
    // 처럼 **여는 괄호 뒤에 줄바꿈이 든** 자리다 — 문자열 판정은 그 의존을 세지 못했다.
    // 두 값을 모두 고정한다(한쪽만 두면 감시가 줄어든다).
    const old_count = countOccurrences(text, "boundary_step.dependOn(&run_");
    const new_count = g.countDependenciesWithPrefix("boundary_step", "run_");
    try std.testing.expectEqual(@as(usize, 222), old_count);
    try std.testing.expectEqual(@as(usize, 223), new_count);
    try std.testing.expect(new_count > old_count); // 뷰가 더 본다 — 줄바꿈에 안 흔들린다

    // 옛 방식: count(build, "sharded.dependOn(&run_") == 0
    try std.testing.expectEqual(
        countOccurrences(text, "sharded.dependOn(&run_"),
        g.countDependenciesWithPrefix("sharded", "run_"),
    );
}

test "countCall 은 receiver 가 제각각인 호출을 센다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // 옛 방식: count(build, "linkFramework(\"UserNotifications\"") >= 2
    const old_count = countOccurrences(text, "linkFramework(\"UserNotifications\"");
    const new_count = g.countCall("linkFramework", "UserNotifications");
    try std.testing.expectEqual(old_count, new_count);
    try std.testing.expect(new_count >= 2);
}

test "other 는 뷰가 모르는 배선을 신고한다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    // 담지 않은 호출이 실제로 신고되는가 — 하나라도 있어야 이 장치가 살아 있다는 뜻이다.
    var with_other: usize = 0;
    for (g.vars) |v| {
        if (v.other.len > 0) with_other += 1;
    }
    try std.testing.expect(with_other > 0);
}

test "dependentsOf 는 «누가 나를 매달았나» 를 답한다 — 방향이 하나뿐이면 빈 값을 「없다」로 읽는다" {
    const a = std.testing.allocator;
    var g = try parse(a);
    defer g.deinit();

    const text = try build_source.read(a);
    defer a.free(text);

    // `run_oracle_tests` 는 정방향(`depends_on`)으로 보면 비어 있다 — 자기가 매단 것이 없으니까.
    const v = g.varCalls("run_oracle_tests") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), v.depends_on.len);

    // 하지만 «매달려 있다». 역방향으로 물어야 보인다.
    try std.testing.expect(g.countDependentsOf("run_oracle_tests") >= 1);

    var who: std.ArrayList([]const u8) = .empty;
    defer who.deinit(a);
    try g.dependentsOf("run_oracle_tests", &who, a);
    var found_oracle_step = false;
    for (who.items) |w| {
        if (std.mem.eql(u8, w, "oracle_step")) found_oracle_step = true;
    }
    try std.testing.expect(found_oracle_step);

    // 문자열 판정과 대조 — `X.dependOn(&run_cwd_axis_boundary_tests.step)` 의 X 가 몇인가
    const old_count = countOccurrences(text, ".dependOn(&run_cwd_axis_boundary_tests.step)");
    try std.testing.expectEqual(old_count, g.countDependentsOf("run_cwd_axis_boundary_tests"));
}
