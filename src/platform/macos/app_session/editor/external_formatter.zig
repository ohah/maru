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
    /// 띄울 포매터의 이름을 싣는다(시한 알림이 그 이름을 말한다).
    preparing: Name,
    /// 포맷하지 않는다. 말할 이유는 이미 알렸다(실행 파일 없음 등)이거나 말할 것이 없다(`off` 의 `⌘S`·신뢰 전의 `⌘S`).
    skip,
};

pub const Started = struct { id: u64, name: Name };

/// 포매터의 이름 사본(알림 — 시한·실패). 사용자 명령의 이름은 설정 문자열을 빌리는데, 기다리는 사이 설정을 다시 읽으면 그 메모리가
/// 사라진다 — 그래서 기다림 자리에는 사본을 둔다.
pub const Name = external_format.Name;

/// 그 문서를 무엇으로 포맷하나 — 부작용 없는 판단(실행·알림·시트 없음). `prepare`(포맷)와 `showInfo`(정보 명령)가 같은 판단을 쓴다
/// (두 벌이면 한쪽만 낡는다).
const Resolved = union(enum) {
    lsp,
    off,
    /// 포매터를 적어 뒀는데(`auto` 가 아니다) 경로·저장소가 없다 — 원격·이름 없는 문서.
    no_path,
    /// JS 계열 도구의 설정이 둘 이상(사용자 결정 — 고르지 않고 알린다).
    conflict: external_format.JsDetected,
    external: External,

    const External = struct {
        kind: external_format.Kind,
        /// 감지한 설정 파일(루트 기준) — 설정으로 고른 것이면 없을 수 있다.
        detected: ?[]const u8,
        root: []const u8,
        path: []const u8,
        doc_dir: []const u8,
        /// 사용자 명령 줄(`command`).
        command: []const u8 = "",
        /// 설정으로 고르지 않았고(`auto`) 감지한 설정도 없다 — 언어 서버가 포맷할 수 없어 직접 부른다(Rust·Zig). 정보 명령이 그 이유를
        /// 말한다(「설정으로 골랐다」는 거짓이다 — 적대적 검증 EF2 3회차).
        fallback: bool = false,

        /// 알림·정보 명령의 이름 — 사용자 명령이면 그 명령의 이름.
        fn name(self: External) []const u8 {
            return if (self.kind == .command) external_format.commandName(self.command) else self.kind.displayName();
        }
    };
};

/// `cfg_bufs` 는 감지한 설정 파일의 경로가 산다(JS 도구 셋 — Python 은 첫 칸).
fn resolve(self: *AppSession, term: *Term, cfg_bufs: *[3][std.fs.max_path_bytes]u8) Resolved {
    const g = term.rt.editor_grammar;
    const setting = external_format.settingFor(&self.loaded_config.config.editor.formatter, g);
    switch (setting.choice) {
        .lsp => return .lsp,
        .off => return .off,
        else => {},
    }
    const doc_state = term.rt.editorDocument();
    if (doc_state.opened == null) return .lsp;
    // 원격·이름 없는 문서는 저장소도 경로도 없다 — `auto` 는 언어 서버로(지금 동작), 적어 둔 포매터면 그 이유를 말한다.
    const path: []const u8 = if (doc_state.remote == null) (doc_state.path orelse "") else "";
    const root = (if (path.len > 0) editor_lsp.documentRoot(self, term) else null) orelse
        return if (setting.choice == .auto) .lsp else .no_path;
    const doc_dir = std.fs.path.dirname(path) orelse root;
    const fs: RealFs = .{ .io = self.io };
    // 감지는 그 문법에 닿는 것만 — 파일 시스템을 덜 본다.
    const js = external_format.detectJs(self.allocator, fs, g, doc_dir, root, cfg_bufs);
    const py = if (g == .python) external_format.detectPython(fs, doc_dir, root, &cfg_bufs[0]) else null;
    const lsp_can = if (setting.choice == .auto and (g == .rust or g == .zig)) editor_lsp.canFormat(self, term) else true;
    return switch (external_format.plan(setting, g, js, py, lsp_can)) {
        .lsp => .lsp,
        .off => .off,
        .conflict => |c| .{ .conflict = c },
        .external => |e| .{ .external = .{ .kind = e.kind, .detected = e.config, .root = root, .path = path, .doc_dir = doc_dir, .command = setting.command, .fallback = setting.choice == .auto and e.config == null } },
    };
}

/// 실행 파일 — 저장소 폴더(`node_modules/.bin`·`.venv/bin` — 저장소가 고정한 버전), 없으면 그 환경의 PATH. 사용자 명령은 첫 낱말(절대
/// 경로면 그것, 아니면 PATH).
fn findExe(self: *AppSession, e: Resolved.External, view_path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const fs: RealFs = .{ .io = self.io };
    const path = if (builtin.is_test) (test_path orelse view_path) else view_path;
    if (e.kind == .command) {
        var words: [external_format.max_args][]const u8 = undefined;
        const first = (external_format.commandArgs(e.command, &words) orelse return null)[0];
        if (first[0] == '/') {
            if (!isExecutableFile(first) or first.len > buf.len) return null;
            @memcpy(buf[0..first.len], first);
            return buf[0..first.len];
        }
        if (std.mem.indexOfScalar(u8, first, '/') != null) return null; // 상대 경로는 받지 않는다(cwd 가 뜻을 바꾼다)
        return locateInPath(first, path, buf);
    }
    return external_format.findLocalBin(fs, e.kind, e.doc_dir, e.root, buf) orelse locateInPath(e.kind.exeName(), path, buf);
}

/// JS 계열 도구가 둘 이상일 때 알린다(사용자 결정). `⌘S` 는 그 문서에서 한 번만(저장마다 알리면 성가시다 — 구현이 정한 것).
fn noticeConflict(self: *AppSession, term: *Term, js: external_format.JsDetected, purpose: Purpose) void {
    if (purpose == .save) {
        const st = &self.editor_format;
        for (st.conflict_noticed) |id| if (id == term.surface.id) return;
        st.conflict_noticed[st.conflict_next] = term.surface.id;
        st.conflict_next = (st.conflict_next + 1) % @as(u8, st.conflict_noticed.len);
    }
    var names_buf: [64]u8 = undefined;
    self.showResponseNotice(.fmt_external_conflict, &.{ .{ .s = js.names(&names_buf) }, .{ .s = @tagName(term.rt.editor_grammar) } });
}

/// 그 문서를 무엇으로 포맷할지 정하고, 외부 포매터면 띄운다.
pub fn prepare(self: *AppSession, term: *Term, purpose: Purpose) Prepared {
    var cfg_bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    const e = switch (resolve(self, term, &cfg_bufs)) {
        .lsp => return .lsp,
        .off => {
            if (purpose == .command) self.showNoticeKey(.fmt_formatter_off);
            return .skip;
        },
        .no_path => {
            if (purpose == .command) self.showNoticeKey(.fmt_external_no_path);
            return .skip;
        },
        .conflict => |js| {
            noticeConflict(self, term, js, purpose);
            return .skip;
        },
        .external => |e| e,
    };
    const kind = e.kind;
    const name = e.name();
    // 신뢰(§8.1) — 신뢰한 저장소에서만 실행한다.
    switch (editor_lsp.repoTrustState(self, e.root)) {
        .trusted => {},
        .untrusted => {
            if (purpose == .command) switch (editor_lsp.askTrustForRepo(self, e.root, false)) {
                .asked, .busy, .already_trusted => {},
                .refused => self.showResponseNotice(.fmt_external_refused, &.{.{ .s = name }}),
            };
            return .skip;
        },
        .refused => {
            if (purpose == .command) self.showResponseNotice(.fmt_external_refused, &.{.{ .s = name }});
            return .skip;
        },
    }
    // 사용자 명령은 먼저 읽어 본다 — 못 읽으면(닫히지 않은 따옴표) 「실행 파일 없음」이 아니라 그 이유를 말한다.
    if (kind == .command) {
        var words: [external_format.max_args][]const u8 = undefined;
        if (external_format.commandArgs(e.command, &words) == null) {
            self.showResponseNotice(.fmt_external_bad_command, &.{.{ .s = @tagName(term.rt.editor_grammar) }});
            return .skip;
        }
    }
    const view = editor_lsp.toolEnvironment(self, e.root) orelse return .{ .preparing = Name.of(name) };
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = findExe(self, e, view.path, &exe_buf) orelse {
        self.showResponseNotice(.fmt_external_missing, &.{.{ .s = name }});
        return .skip;
    };
    // rustfmt 는 Cargo 의 edition 을 받는다(기본 2015 는 `async fn` 등을 깨뜨린다).
    var edition_text: ?[]u8 = null;
    defer if (edition_text) |t| std.heap.smp_allocator.free(t);
    const edition: ?[]const u8 = if (kind == .rustfmt) blk: {
        var cargo_buf: [std.fs.max_path_bytes]u8 = undefined;
        const fs: RealFs = .{ .io = self.io };
        const cargo = external_format.findNearest(fs, e.doc_dir, e.root, "Cargo.toml", &cargo_buf) orelse break :blk null;
        const text = fs.read(cargo, external_format.max_config_read_bytes) orelse break :blk null;
        edition_text = @constCast(text);
        break :blk external_format.cargoEdition(text);
    } else null;
    var argv: external_format.Argv = undefined;
    if (!external_format.argv(&argv, kind, exe, e.path, edition, e.command)) {
        self.showResponseNotice(.fmt_external_bad_command, &.{.{ .s = @tagName(term.rt.editor_grammar) }});
        return .skip;
    }
    const doc = term.rt.editorDocument().opened.?;
    const id = format_process.start(.{ .argv = argv.slice(), .cwd = e.root, .envp = view.envp, .stdin = doc.file.content, .timeout_ms = timeout_ms }) orelse {
        self.showResponseNotice(.fmt_external_failed, &.{ .{ .s = name }, .{ .s = "spawn" } });
        return .skip;
    };
    log.info("{s}: {s} for {s} (config {s})", .{ name, exe, e.path, e.detected orelse "-" });
    return .{ .started = .{ .id = id, .name = Name.of(name) } };
}

/// 팔레트 「Editor: Show Formatter Info」(§8.1 「해결된 executable·config discovery 를 사용자에게」) — 지금 문서를 무엇으로 포맷하나,
/// 감지한 설정 파일, 실행 파일(찾았으면 경로와 저장소 안인지), 저장소와 신뢰 결정. 실행하지 않는다(찾기만).
pub fn showInfo(self: *AppSession) void {
    if (self.tabs.items.len == 0) return self.showNoticeKey(.fmt_info_unavailable);
    const term = @import("../pane.zig").activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) return self.showNoticeKey(.fmt_info_unavailable);
    var cfg_bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    const e = switch (resolve(self, term, &cfg_bufs)) {
        .lsp => return self.showNoticeKey(.fmt_info_lsp),
        .off => return self.showNoticeKey(.fmt_formatter_off),
        .no_path => return self.showNoticeKey(.fmt_external_no_path),
        .conflict => |js| return noticeConflict(self, term, js, .command),
        .external => |e| e,
    };
    var out: [3 * std.fs.max_path_bytes + 512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var line: [2 * std.fs.max_path_bytes + 128]u8 = undefined;
    const head = if (e.detected) |d|
        maru.i18n.format(&line, maru.i18n.t(.fmt_info_detected), &.{ .{ .s = e.name() }, .{ .s = d } })
    else
        maru.i18n.format(&line, maru.i18n.t(if (e.fallback) .fmt_info_fallback else .fmt_info_configured), &.{.{ .s = e.name() }});
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
        } else w.writeAll(maru.i18n.format(&line, maru.i18n.t(.fmt_external_missing), &.{.{ .s = e.name() }})) catch {};
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

pub fn isExecutableFile(p: []const u8) bool {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{p}) catch return false;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, pz.ptr, &st, 0) != 0) return false;
    if ((st.mode & std.c.S.IFMT) != std.c.S.IFREG) return false;
    return std.c.access(pz.ptr, std.c.X_OK) == 0;
}

/// 감지가 보는 파일 시스템(실제) — `external_format` 의 `fs` 모양. 보조 언어 서버의 감지(`lsp.zig` — tooling §8.2u)도 이것을 쓴다.
pub const RealFs = struct {
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
/// 저장 완료 뒤 게시할 안내를 반환한다. 사용자 명령 이름도 보존하며 결과는 호출자가 푼다.
/// `asked_revision` 은 띄운 순간의 본문 revision(`opened.file.revision`).
pub fn apply(self: *AppSession, term: *Term, name: []const u8, result: *const format_process.Result, asked_revision: u64, then_save: bool) ?maru.editor_save_notice.Success {
    switch (result.outcome) {
        .timeout => {
            counters.timeouts += 1;
            if (then_save) return .external(.fmt_external_timeout_saved, name, null);
            self.showResponseNotice(.fmt_external_timeout, &.{.{ .s = name }});
        },
        .too_large, .spawn_failed => {
            counters.failed += 1;
            if (then_save) return .external(.fmt_external_failed_saved, name, @tagName(result.outcome));
            self.showResponseNotice(.fmt_external_failed, &.{ .{ .s = name }, .{ .s = @tagName(result.outcome) } });
        },
        .exited => |e| {
            log.info("{s}: exit {?d} in {d} ms ({d} bytes)", .{ name, e.code, result.elapsed_ms, e.stdout.len });
            if (e.code != 0) {
                counters.failed += 1;
                var line_buf: [160]u8 = undefined;
                const why = firstLine(e.stderr, e.code, term.rt.editorDocument().path orelse "", &line_buf);
                if (then_save) return .external(.fmt_external_failed_saved, name, why);
                self.showResponseNotice(.fmt_external_failed, &.{ .{ .s = name }, .{ .s = why } });
                return null;
            }
            const doc = term.rt.editorDocument().opened orelse return null;
            // §3.6 revision 검증 — 띄운 뒤 문서가 바뀌었으면 결과가 그 문서의 것이 아니다.
            if (doc.file.revision != asked_revision) {
                counters.stale += 1;
                if (then_save) return .{ .key = .fmt_stale_saved };
                self.showResponseNotice(.fmt_stale, &.{});
                return null;
            }
            // 빈 결과는 문서를 통째로 지운다 — 성공 코드여도 받지 않는다(포매터가 stdin 을 못 읽고 끝났을 수 있다).
            if (e.stdout.len == 0 and doc.file.content.len > 0) {
                counters.failed += 1;
                if (then_save) return .external(.fmt_external_failed_saved, name, "empty output");
                self.showResponseNotice(.fmt_external_failed, &.{ .{ .s = name }, .{ .s = "empty output" } });
                return null;
            }
            const changes = external_format.changesFor(self.allocator, doc.file.content, e.stdout) catch return null;
            defer self.allocator.free(changes);
            if (changes.len == 0) {
                counters.noop += 1;
                return null;
            }
            if (editor_ops.applyEditAsOneWithUndo(self, term, changes)) counters.applied += 1;
        },
    }
    return null;
}

/// 실패 알림의 이유 한 줄 — stderr 에서 오류 문장을 고른다(제어 문자는 공백, 상한은 글자 경계). 없으면 종료 코드.
/// - Biome 처럼 진단 문장이 `×` 로 시작하는 줄이 있으면 그 줄(첫 줄은 `‹경로›:1:7 parse ━━━` 같은 머리다).
/// - 아니면 첫 비지 않은 줄(Prettier 의 머리 표식 `[error]` 를 뗀다).
/// - 그 줄 안의 **문서 경로**(`‹경로›:` — Prettier 는 앞에, black 은 `error: cannot format ‹경로›: …` 로 가운데)를 뗀다 — 긴 경로가 상한을
///   먹어 정작 오류가 잘렸다(진짜 Prettier·Biome·black 으로 잰 적대적 검증 EF1 3회차·EF2 2회차).
pub fn firstLine(stderr: []const u8, code: ?u8, doc_path: []const u8, buf: []u8) []const u8 {
    const line: []const u8 = blk: {
        var it = std.mem.splitScalar(u8, stderr, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, l, "×")) break :blk std.mem.trimStart(u8, l["×".len..], " ");
        }
        it = std.mem.splitScalar(u8, stderr, '\n');
        while (it.next()) |raw| {
            var l = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, l, "[error]")) l = std.mem.trimStart(u8, l["[error]".len..], " ");
            if (l.len > 0) break :blk l;
        }
        return std.fmt.bufPrint(buf, "exit {?d}", .{code}) catch "exit";
    };
    var n: usize = 0;
    var i: usize = 0;
    var truncated = false;
    while (i < line.len) {
        if (doc_path.len > 0 and std.mem.startsWith(u8, line[i..], doc_path) and line.len > i + doc_path.len and line[i + doc_path.len] == ':') {
            i += doc_path.len + 1;
            if (i < line.len and line[i] == ' ') i += 1;
            continue;
        }
        if (n == buf.len) {
            truncated = true;
            break;
        }
        const c = line[i];
        buf[n] = if (c < 0x20 or c == 0x7f) ' ' else c;
        n += 1;
        i += 1;
    }
    // 상한에서 글자 가운데를 자르지 않는다 — 다음 바이트가 이어지는 바이트면 그 글자의 머리까지 물린다.
    if (truncated) while (n > 0 and (line[i] & 0xC0) == 0x80) {
        n -= 1;
        i -= 1;
    };
    const out = std.mem.trim(u8, buf[0..n], " ");
    return if (out.len == 0) (std.fmt.bufPrint(buf, "exit {?d}", .{code}) catch "exit") else out;
}

test "EXFL1 실패 알림의 첫 줄 — Prettier 의 머리 표식과 문서 경로를 떼고, 빈 줄은 건너뛰며, 제어 문자는 공백, 상한은 글자 경계; stderr 가 없으면 종료 코드 (적대적 검증 EF1 3회차)" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("SyntaxError: Variable declaration expect", firstLine("[error] /very/long/repo/path/b.ts: SyntaxError: Variable declaration expected. (1:7)\n[error] > 1 | const = ;\n", 2, "/very/long/repo/path/b.ts", &buf));
    try std.testing.expectEqualStrings("boom", firstLine("\n  \nboom\nmore", 1, "/x", &buf));
    try std.testing.expectEqualStrings("a b", firstLine("a\x1bb", 1, "", &buf));
    try std.testing.expectEqualStrings("exit 3", firstLine("", 3, "", &buf));
    try std.testing.expectEqualStrings("/other.ts: x", firstLine("[error] /other.ts: x", 2, "/a.ts", &buf)); // 다른 파일의 경로는 그대로
    // 진짜 도구의 stderr 모양(EF2 실측) — Biome 은 `×` 줄, black 은 경로가 가운데.
    var wide: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Expected an identifier, an array pattern, or an object pattern but instead found '='.", firstLine("/r/a.ts:1:7 parse ━━━━━━━━━━\n\n  × Expected an identifier, an array pattern, or an object pattern but instead found '='.\n  \n  > 1 │ const = ;\n", 1, "/r/a.ts", &wide));
    try std.testing.expectEqualStrings("error: cannot format Cannot parse: 1:5: Unexpected EOF in multi-line statement", firstLine("error: cannot format /r/a.py: Cannot parse: 1:5: Unexpected EOF in multi-line statement\n", 123, "/r/a.py", &wide));
    try std.testing.expectEqualStrings("exit 1", firstLine("/r/a.ts:\n", 1, "/r/a.ts", &wide)); // 경로만 남는 줄은 이유가 없다
    var small: [5]u8 = undefined;
    try std.testing.expectEqualStrings("가", firstLine("가나다", 1, "", &small)); // 6 바이트를 5 에서 — 글자 가운데에서 자르지 않는다
}
