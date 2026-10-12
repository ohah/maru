//! 외부 포매터의 제품 경로(docs/editor-surface-tooling.md §8.2t, 계획 docs/plans/editor-external-formatter.md) — 그 문서를 무엇으로
//! 포맷할지 정하고(설정 `editor.formatter.<언어>`·저장소 설정 감지·신뢰), 외부 포매터를 띄우며(`format_process`), 결과를 문서에
//! 적용한다(덩어리마다 편집·되돌리기 하나·revision 검증). 기다림 자리와 저장 순서는 `format.zig` 가 갖는다 — 이 파일은 그 자리에서
//! 「언어 서버로 갈지·외부 포매터를 띄울지·포맷하지 않을지」만 답한다.
//!
//! **신뢰한 저장소에서만 돈다**(§8.1): 실행 파일이 PATH 의 것이어도 Prettier 는 저장소의 `prettier.config.js`·플러그인을 실행한다.
//! 신뢰 전이면 `⌘S` 는 포맷 없이 저장하고(저장이 시트에 막히지 않는다), `⇧⌥F` 는 저장소 신뢰 시트를 띄운다(사용자가 포맷을 불렀다).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const editor_lsp = @import("lsp.zig");
const format_process = @import("../../format_process.zig");
const external_format = maru.session.editor.external_format;

const log = std.log.scoped(.format);

/// 왜 포맷하나 — 저장 시 포맷(`⌘S`)은 시트·알림으로 저장을 막지 않는다. 명령(`⇧⌥F`)은 사용자가 포맷을 불렀으니 이유를 말한다.
pub const Purpose = enum { save, command };

pub const Prepared = union(enum) {
    /// 언어 서버 포맷으로(지금 동작 — §8.2e·§8.2r).
    lsp,
    /// 외부 포매터를 띄웠다 — 결과를 `format_process.take(id)` 로 기다린다.
    started: Started,
    /// 사용자 셸 환경을 담는 중이다 — tick 에서 다시 준비한다(처음 연 문서의 첫 `⌘S` — Prettier 는 PATH 의 `node` 가 필요하다).
    /// 띄울 포매터의 종류를 싣는다(시한 알림이 그 이름을 말한다).
    preparing: external_format.Kind,
    /// 포맷하지 않는다. 말할 이유는 이미 알렸다(실행 파일 없음 등)이거나 말할 것이 없다(`off` 의 `⌘S`·신뢰 전의 `⌘S`).
    skip,
};

pub const Started = struct { id: u64, kind: external_format.Kind };

/// 그 문서를 무엇으로 포맷하나 — 부작용 없는 판단(실행·알림·시트 없음). `prepare`(포맷)와 `showInfo`(정보 명령)가 같은 판단을 쓴다
/// (두 벌이면 한쪽만 낡는다).
const Resolved = union(enum) {
    lsp,
    off,
    /// 포매터를 적어 뒀는데(`auto` 가 아니다) 경로·저장소가 없다 — 원격·이름 없는 문서.
    no_path: external_format.Kind,
    external: External,

    const External = struct { kind: external_format.Kind, detected: ?[]const u8, root: []const u8, path: []const u8, doc_dir: []const u8 };
};

fn resolve(self: *AppSession, term: *Term, cfg_buf: *[std.fs.max_path_bytes]u8) Resolved {
    const g = term.rt.editor_grammar;
    const choice = external_format.choiceFor(&self.loaded_config.config.editor.formatter, g);
    switch (choice) {
        .lsp => return .lsp,
        .off => return .off,
        .auto, .prettier => {},
    }
    const doc_state = term.rt.editorDocument();
    if (doc_state.opened == null) return .lsp;
    // 원격·이름 없는 문서는 저장소도 경로도 없다 — `auto` 는 언어 서버로(지금 동작), 적어 둔 포매터면 그 이유를 말한다.
    const path: []const u8 = if (doc_state.remote == null) (doc_state.path orelse "") else "";
    const root = (if (path.len > 0) editor_lsp.documentRoot(self, term) else null) orelse
        return if (choice == .auto) .lsp else .{ .no_path = .prettier };
    const doc_dir = std.fs.path.dirname(path) orelse root;
    const fs: RealFs = .{ .io = self.io };
    const detected = if (choice == .auto and !external_format.prettierHandles(g)) null else external_format.findPrettierConfig(self.allocator, fs, doc_dir, root, cfg_buf);
    return switch (external_format.plan(choice, g, detected)) {
        .lsp => .lsp,
        .off => .off,
        .external => |e| .{ .external = .{ .kind = e.kind, .detected = detected, .root = root, .path = path, .doc_dir = doc_dir } },
    };
}

/// 실행 파일 — 가장 가까운 `node_modules/.bin`(저장소가 고정한 버전), 없으면 그 환경의 PATH.
fn findExe(self: *AppSession, e: Resolved.External, view_path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const fs: RealFs = .{ .io = self.io };
    return external_format.findLocalBin(fs, e.doc_dir, e.root, e.kind.exeName(), buf) orelse
        locateInPath(e.kind.exeName(), if (builtin.is_test) (test_path orelse view_path) else view_path, buf);
}

/// 그 문서를 무엇으로 포맷할지 정하고, 외부 포매터면 띄운다.
pub fn prepare(self: *AppSession, term: *Term, purpose: Purpose) Prepared {
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const e = switch (resolve(self, term, &cfg_buf)) {
        .lsp => return .lsp,
        .off => {
            if (purpose == .command) self.showNoticeKey(.fmt_formatter_off);
            return .skip;
        },
        .no_path => {
            if (purpose == .command) self.showNoticeKey(.fmt_external_no_path);
            return .skip;
        },
        .external => |e| e,
    };
    const kind = e.kind;
    // 신뢰(§8.1) — 신뢰한 저장소에서만 실행한다.
    switch (editor_lsp.repoTrustState(self, e.root)) {
        .trusted => {},
        .untrusted => {
            if (purpose == .command) switch (editor_lsp.askTrustForRepo(self, e.root, false)) {
                .asked, .busy, .already_trusted => {},
                .refused => self.showResponseNotice(.fmt_external_refused, &.{.{ .s = kind.displayName() }}),
            };
            return .skip;
        },
        .refused => {
            if (purpose == .command) self.showResponseNotice(.fmt_external_refused, &.{.{ .s = kind.displayName() }});
            return .skip;
        },
    }
    const view = editor_lsp.toolEnvironment(self, e.root) orelse return .{ .preparing = kind };
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = findExe(self, e, view.path, &exe_buf) orelse {
        self.showResponseNotice(.fmt_external_missing, &.{.{ .s = kind.displayName() }});
        return .skip;
    };
    const doc = term.rt.editorDocument().opened.?;
    const argv = external_format.argv(kind, exe, e.path);
    const id = format_process.start(.{ .argv = &argv, .cwd = e.root, .envp = view.envp, .stdin = doc.file.content, .timeout_ms = timeout_ms }) orelse {
        self.showResponseNotice(.fmt_external_failed, &.{ .{ .s = kind.displayName() }, .{ .s = "spawn" } });
        return .skip;
    };
    log.info("{s}: {s} --stdin-filepath {s} (config {s})", .{ kind.displayName(), exe, e.path, e.detected orelse "-" });
    return .{ .started = .{ .id = id, .kind = kind } };
}

/// 팔레트 「Editor: Show Formatter Info」(§8.1 「해결된 executable·config discovery 를 사용자에게」) — 지금 문서를 무엇으로 포맷하나,
/// 감지한 설정 파일, 실행 파일(찾았으면 경로와 저장소 안인지), 저장소와 신뢰 결정. 실행하지 않는다(찾기만).
pub fn showInfo(self: *AppSession) void {
    if (self.tabs.items.len == 0) return self.showNoticeKey(.fmt_info_unavailable);
    const term = @import("../pane.zig").activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) return self.showNoticeKey(.fmt_info_unavailable);
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const e = switch (resolve(self, term, &cfg_buf)) {
        .lsp => return self.showNoticeKey(.fmt_info_lsp),
        .off => return self.showNoticeKey(.fmt_formatter_off),
        .no_path => return self.showNoticeKey(.fmt_external_no_path),
        .external => |e| e,
    };
    var out: [3 * std.fs.max_path_bytes + 512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var line: [2 * std.fs.max_path_bytes + 128]u8 = undefined;
    const head = if (e.detected) |d|
        maru.i18n.format(&line, maru.i18n.t(.fmt_info_detected), &.{ .{ .s = e.kind.displayName() }, .{ .s = d } })
    else
        maru.i18n.format(&line, maru.i18n.t(.fmt_info_configured), &.{.{ .s = e.kind.displayName() }});
    w.writeAll(head) catch {};
    // 저장소와 신뢰 결정 — 신뢰한 저장소에서만 실행한다.
    var shown_buf: [std.fs.max_path_bytes]u8 = undefined;
    const word = switch (editor_lsp.repoTrustState(self, e.root)) {
        .trusted => maru.i18n.t(.lsp_trust_list_allowed),
        .untrusted => maru.i18n.t(.fmt_info_untrusted),
        .refused => maru.i18n.t(.fmt_info_refused),
    };
    w.writeAll("\n") catch {};
    w.writeAll(maru.i18n.format(&line, maru.i18n.t(.lsp_info_repo), &.{ .{ .s = app_session_mod.homeTildeInto(e.root, &shown_buf) }, .{ .s = word } })) catch {};
    // 실행 파일 — 셸 환경을 담기 전에는 찾지 않는다(PATH 가 아직 없다).
    w.writeAll("\n") catch {};
    if (editor_lsp.toolEnvironment(self, e.root)) |view| {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (findExe(self, e, view.path, &exe_buf)) |exe| {
            const in_repo = std.mem.startsWith(u8, exe, e.root) and exe.len > e.root.len and exe[e.root.len] == '/';
            w.writeAll(maru.i18n.format(&line, maru.i18n.t(if (in_repo) .fmt_info_exe_repo else .fmt_info_exe), &.{.{ .s = app_session_mod.homeTildeInto(exe, &shown_buf) }})) catch {};
        } else w.writeAll(maru.i18n.format(&line, maru.i18n.t(.fmt_external_missing), &.{.{ .s = e.kind.displayName() }})) catch {};
    } else w.writeAll(maru.i18n.t(.fmt_info_exe_pending)) catch {};
    self.showNotice(w.buffered());
}

/// 외부 포매터의 시한(판정자가 당긴다 — 구조 필드).
pub var timeout_ms: u32 = format_process.default_timeout_ms;

/// 판정자 주입 — PATH 찾기에 쓸 PATH(기계마다 PATH 의 `prettier` 가 달라 「실행 파일 없음」을 결정적으로 재려고). 테스트 빌드에서만 읽는다.
pub var test_path: ?[]const u8 = null;

fn locateInPath(name: []const u8, path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue; // §8.1 — 절대 경로 항목만
        const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name }) catch continue;
        if (isExecutableFile(p)) return p;
    }
    return null;
}

fn isExecutableFile(p: []const u8) bool {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{p}) catch return false;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, pz.ptr, &st, 0) != 0) return false;
    if ((st.mode & std.c.S.IFMT) != std.c.S.IFREG) return false;
    return std.c.access(pz.ptr, std.c.X_OK) == 0;
}

/// 감지가 보는 파일 시스템(실제) — `external_format` 의 `fs` 모양.
const RealFs = struct {
    io: std.Io,

    pub fn exists(_: RealFs, p: []const u8) bool {
        var z: [std.fs.max_path_bytes + 1]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{p}) catch return false;
        return std.c.access(pz.ptr, std.c.F_OK) == 0;
    }
    pub fn isExecutable(_: RealFs, p: []const u8) bool {
        return isExecutableFile(p);
    }
    pub fn read(self: RealFs, p: []const u8, limit: usize) ?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, p, std.heap.smp_allocator, .limited(limit)) catch null;
    }
    pub fn freeRead(_: RealFs, text: []const u8) void {
        std.heap.smp_allocator.free(text);
    }
};

/// 판정자 관측.
pub const Counters = struct { applied: u64 = 0, noop: u64 = 0, stale: u64 = 0, failed: u64 = 0, timeouts: u64 = 0 };
pub var counters: Counters = .{};

/// 외부 포매터의 결과를 그 문서에 적용한다(`format.zig` 가 결과를 가져와 부른다). `asked_version` 은 띄울 때의 revision, `then_save` 면
/// 알림은 「저장했다」를 말한다(저장은 호출자가 이 뒤에 한다). 결과는 호출자가 푼다.
/// `asked_revision` 은 띄운 순간의 본문 revision(`opened.file.revision`).
pub fn apply(self: *AppSession, term: *Term, kind: external_format.Kind, result: *const format_process.Result, asked_revision: u64, then_save: bool) void {
    const name = kind.displayName();
    switch (result.outcome) {
        .timeout => {
            counters.timeouts += 1;
            self.showResponseNotice(if (then_save) .fmt_external_timeout_saved else .fmt_external_timeout, &.{.{ .s = name }});
        },
        .too_large, .spawn_failed => {
            counters.failed += 1;
            self.showResponseNotice(if (then_save) .fmt_external_failed_saved else .fmt_external_failed, &.{ .{ .s = name }, .{ .s = @tagName(result.outcome) } });
        },
        .exited => |e| {
            log.info("{s}: exit {?d} in {d} ms ({d} bytes)", .{ name, e.code, result.elapsed_ms, e.stdout.len });
            if (e.code != 0) {
                counters.failed += 1;
                var line_buf: [160]u8 = undefined;
                const why = firstLine(e.stderr, e.code, term.rt.editorDocument().path orelse "", &line_buf);
                return self.showResponseNotice(if (then_save) .fmt_external_failed_saved else .fmt_external_failed, &.{ .{ .s = name }, .{ .s = why } });
            }
            const doc = term.rt.editorDocument().opened orelse return;
            // §3.6 revision 검증 — 띄운 뒤 문서가 바뀌었으면 결과가 그 문서의 것이 아니다.
            if (doc.file.revision != asked_revision) {
                counters.stale += 1;
                return self.showResponseNotice(if (then_save) .fmt_stale_saved else .fmt_stale, &.{});
            }
            // 빈 결과는 문서를 통째로 지운다 — 성공 코드여도 받지 않는다(포매터가 stdin 을 못 읽고 끝났을 수 있다).
            if (e.stdout.len == 0 and doc.file.content.len > 0) {
                counters.failed += 1;
                return self.showResponseNotice(if (then_save) .fmt_external_failed_saved else .fmt_external_failed, &.{ .{ .s = name }, .{ .s = "empty output" } });
            }
            const changes = external_format.changesFor(self.allocator, doc.file.content, e.stdout) catch return;
            defer self.allocator.free(changes);
            if (changes.len == 0) {
                counters.noop += 1;
                return;
            }
            if (editor_ops.applyEditAsOneWithUndo(self, term, changes)) counters.applied += 1;
        },
    }
}

/// stderr 의 첫 비지 않은 줄(제어 문자는 공백, 상한) — 없으면 종료 코드. Prettier 의 `[error] ‹문서 전체 경로›: SyntaxError: …` 에서 머리
/// 표식과 그 문서의 경로를 뗀다 — 긴 경로가 상한을 먹어 정작 오류가 잘렸다(실제 Prettier 3 로 잰 적대적 검증 EF1 3회차).
pub fn firstLine(stderr: []const u8, code: ?u8, doc_path: []const u8, buf: []u8) []const u8 {
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        var l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "[error]")) l = std.mem.trimStart(u8, l["[error]".len..], " ");
        if (doc_path.len > 0 and std.mem.startsWith(u8, l, doc_path) and std.mem.startsWith(u8, l[doc_path.len..], ": ")) l = l[doc_path.len + 2 ..];
        if (l.len == 0) continue;
        const n = @min(l.len, buf.len);
        var cut = n;
        if (n < l.len) while (cut > 0 and (l[cut] & 0xC0) == 0x80) {
            cut -= 1;
        };
        for (l[0..cut], 0..) |c, i| buf[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
        return buf[0..cut];
    }
    return std.fmt.bufPrint(buf, "exit {?d}", .{code}) catch "exit";
}

test "EXFL1 실패 알림의 첫 줄 — Prettier 의 머리 표식과 문서 경로를 떼고, 빈 줄은 건너뛰며, 제어 문자는 공백, 상한은 글자 경계; stderr 가 없으면 종료 코드 (적대적 검증 EF1 3회차)" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("SyntaxError: Variable declaration expect", firstLine("[error] /very/long/repo/path/b.ts: SyntaxError: Variable declaration expected. (1:7)\n[error] > 1 | const = ;\n", 2, "/very/long/repo/path/b.ts", &buf));
    try std.testing.expectEqualStrings("boom", firstLine("\n  \nboom\nmore", 1, "/x", &buf));
    try std.testing.expectEqualStrings("a b", firstLine("a\x1bb", 1, "", &buf));
    try std.testing.expectEqualStrings("exit 3", firstLine("", 3, "", &buf));
    try std.testing.expectEqualStrings("/other.ts: x", firstLine("[error] /other.ts: x", 2, "/a.ts", &buf)); // 다른 파일의 경로는 그대로
    var small: [5]u8 = undefined;
    try std.testing.expectEqualStrings("가", firstLine("가나다", 1, "", &small)); // 6 바이트를 5 에서 — 글자 가운데에서 자르지 않는다
}
