//! 가짜 언어 서버(docs/editor-surface-tooling.md §8.2a 관측점) — 판정자가 `MARU_LSP_SERVER_OVERRIDE` 로 끼운다.
//!
//! stdin 에서 Content-Length 프레임을 읽고:
//! - `initialize` → 응답(제안된 인코딩에 utf-8 이 있으면 `positionEncoding: "utf-8"`, `MARU_FAKE_LSP_UTF16=1` 이면 utf-16; textDocumentSync Full;
//!   `serverInfo {maru-fake-lsp, 9.8.7}` — `MARU_FAKE_LSP_NOSERVERINFO=1` 이면 null).
//!   `MARU_FAKE_LSP_SERVERINFO_NAME`·`_VERSION` 은 그 이름·버전을 바꾼다(서버가 보낸 문자열을 클라이언트가 거르는지 잰다 — `_VERSION=` 빈 값이면
//!   버전 없이 이름만).
//! - `initialized` → 서버 → 클라이언트 요청 `workspace/configuration` 하나(클라이언트가 **거부**해야 한다). 그 응답(id `srv-1`,
//!   result 든 error 든)이 오면 `answered` — 안 온 채 didChange 를 받으면 WARN 진단의 message 가 `fake: warn noack` 이 된다
//!   (답이 없으면 실서버는 그 요청에 **영원히 매달린다** — 카운터가 아니라 서버 쪽에서 봐야 변이 B7 이 죽는다).
//! - `didOpen`/`didChange` → 그 문서의 `publishDiagnostics` 하나: 첫 줄 0..3 에 error, message `fake: <version>`·code `E1`, `version` 은
//!   문서 version. 본문에 `STALE` 이 있으면 version 을 **하나 낮춰**(클라이언트가 버려야 한다). `BOOM` 이 있으면 즉시 exit 1(재시작).
//!   `WARN` 이 있으면 severity 2 를 하나 더(둘째 줄 0..2). `INFO` 가 있으면 severity 3 을 첫 줄 0..1 에 하나 더(message 두 줄).
//!   `SYNCSUM` 이 있으면 message 가 `fake: <version> sum=<사본의 FNV-1a 32 16진 8자리> rl=<range 없이 온 전문 수> rj=<거부한 변경 수>` 다
//!   (LS3 — didChange 는 받은 range 를 사본에 적용하고, 사본 밖 위치는 거부한다; 판정자가 maru 본문의 해시와 맞대 본다).
//!   `PULLCAP` 이 있으면 message 가 `fake: <version> pull=<true|false>` 다(클라이언트가 `initialize` 에서 `textDocument.diagnostic` 을 알렸나 — pull 칸이
//!   꺼진 주 서버엔 알리지 않는지 서버 쪽에서 잰다, LS2).
//!   `LANGID` 가 있으면 message 가 `fake: <version> <didOpen 의 languageId>` 다(문서마다 그 방언의 값인지 — `.scss`·`.less`, 계획 editor-lsp-servers-expand).
//! - `HANG` 이 있으면 stdout 을 **닫고 살아 있는다**(진단도 exit 도 없다) — 클라이언트는 EOF 를 「끝」으로 보고 죽여 재시작해야 한다.
//! - `textDocument/hover` → contents(markdown): 펜스 `int fake` · `fake hover L<line>:C<char>` · `**bold** here` · 항목 14개(`- item N`,
//!   상자 높이 상한 12행을 넘긴다), range = 그 줄의 `character..character+3`(클라이언트가 앵커로 써야 한다). 본문에 `NOHOVER` 가
//!   있으면 `null` 결과(내용 없음). `MUTEHOVER` 가 있으면 hover 에 **답하지 않는다**(시간 초과 경로).
//! - `textDocument/definition` → `Location[]` 둘(첫 항목 = 줄 1, 글자 = **요청한 character**; 둘째는 버려져야 한다). 본문에 `NODEF` 면 `null`, `XFILE` 이면
//!   같은 디렉터리의 `other.c`, `OUTSIDE` 면 `file:///nonexistent-outside-root/x.c`(root 밖).
//! - `textDocument/signatureHelp` → 요청 줄의 caret 앞에서 마지막 `(` 뒤 `,` 수를 activeParameter 로, 시그니처 둘(`int add(int a, int b)` —
//!   parameters 는 `[8,13]`·`[15,20]`, doc `**adds** two`·첫 파라미터 doc `first`; `int add(double a)`). `(` 가 없거나 닫혔거나 `NOSIG` 면 `null`.
//!   capability 로 triggerCharacters `(`·`,` 와 retriggerCharacters `)` 를 낸다.
//! - `textDocument/formatting` → 각 줄에서 **첫 두 칸 이상 공백 묶음**을 한 칸으로 줄이는 `TextEdit[]`(줄마다 하나, 줄 순서의 **역순**으로 보내
//!   클라이언트가 정렬해야 한다; character = byte — ASCII 본문에서만 맞다). 본문에 `NOFMT` 면 `null`, `BADFMT` 면 겹치는 edit 둘(거부돼야 한다),
//!   `FMTSTALL` 이면 답하지 않는다(저장 시 포맷의 시한).
//!   `options` 가 계약(§8.2e ③)과 다르면 — `insertSpaces` 가 bool 이 아니거나 `tabSize` 가 1 미만 — `null`(제품 경계에서 options 를 잰다).
//!   본문에 `FMTOPTS` 가 있으면 그 표식을 받은 options 로 바꾸는 edit 하나만 낸다(`OPTS spaces=<true|false> size=<n>` — 문서의 들여쓰기 단위를
//!   보냈는지 잰다, 계획 editor-typing-rules TR1).
//!   capability `documentFormattingProvider: true`(`MARU_FAKE_LSP_NOFMTCAP=1` 이면 false — 클라이언트가 요청을 안 보내야 한다).
//! - `textDocument/rename` → 요청 자리의 식별자를 이 문서와 같은 디렉터리 `other.c`(**디스크에서** 읽는다 — 열려 있지 않은 파일의 관측점)에서
//!   낱말 단위로 `newName` 으로 바꾸는 `WorkspaceEdit`(`changes` 맵; `MARU_FAKE_LSP_RENAME_DOCCHANGES=1` 이면 `documentChanges` + version).
//!   `RENAMEFAIL` → 오류 응답 · `RENAMEOUT` → root 밖 파일 edit 추가 · `RENAMECREATE` → `CreateFile` 추가 · `RENAMEBAD` → 겹치는 edit ·
//!   `RENAMESTALEVER` → `documentChanges` 의 version 을 하나 낮춰(낡은 결과).
//!   capability `renameProvider: true`(`MARU_FAKE_LSP_NORENAMECAP=1` 이면 false).
//! - `textDocument/completion` → 문서의 식별자 전부(나온 순서 sortText) + `fake_import`(textEdit 접두사 교체 + additionalTextEdits 로 첫 줄 include,
//!   preselect) + `fake_tail`(additional 이 다음 줄 머리 — 낱말 뒤) + `lazy_import`(data 만 — `completionItem/resolve` 가 include additional 을
//!   채운다; `RESOLVESTALL` 이면 답하지 않는다) + `.` 바로 뒤면 `arrow_fix`(textEdit 이 `x.` 부터 덮어 `x->m`). capability `resolveProvider: true`.
//!   접두사로 거르지 않는다(로컬 필터 관측점), caret 앞 낱말이 2 글자 미만이면 `isIncomplete`. `NOCOMP` → `null`.
//!   capability `completionProvider{triggerCharacters: ["."]}`(`MARU_FAKE_LSP_NOCOMPCAP=1` 이면 없음).
//! - `textDocument/codeAction` → 문맥 진단마다 「fake: fix <code>」(range → `FIXED`, 첫 것 isPreferred) + 「fake: lazy」(data 만 — resolve) +
//!   「fake: command」(command 만) + `Command` 형(둘은 숨겨져야 한다) + `MANYACT` 면 data-only 30 개(상한 관측점). `NOACT` → `[]`.
//!   `context.only` 가 있으면(저장 시 code action — §8.2s) 그 kind 의 source action 만(`handleSourceActions` 의 표식).
//!   `codeAction/resolve` → 첫 줄에 `// lazy` 를 넣는 edit; `RESOLVEFAIL` → 오류; `RESOLVEEMPTY` → edit 없는 응답. capability `codeActionProvider{resolveProvider: true}`(`MARU_FAKE_LSP_NOACTCAP=1` 이면 없음).
//! - `shutdown` → `null` 응답, `exit` → 종료 0.
//! - 시작하자마자 stderr 에 한 줄을 쓴다(실서버 clangd 가 그렇다) — stdout 에 섞이면 프레임이 깨진다(§8.2a 「stderr」).
//! - 수명 판정자(§8.2a 「수명·재시작」)용 환경 스위치:
//!   `MARU_FAKE_LSP_GRANDCHILD=<디렉터리>` — 시작하자마자 `/bin/sleep` 손자를 하나 띄우고(서버의 stdin/stdout 을 물려받아 **파이프를
//!   열어 둔다** — 실서버의 `zig build`·`cargo check` 와 같은 모양) 그 pid 를 `<디렉터리>/gc-<서버 pid>` 에 적는다(서버가 여럿 떠도
//!   섞이지 않게). 서버를 내릴 때 손자가 남는지 본다. stdin 에서 EOF 를 보면 `<디렉터리>/eof-<서버 pid>` 를 남기고 끝난다 — 클라이언트가
//!   죽이기 **전에** stdin 을 닫아 스스로 내려갈 기회를 줬는지 본다.
//!   `MARU_FAKE_LSP_INIT=silent` — `initialize` 에 답하지 않는다 · `=error` — 오류로 답한다.
//!   `MARU_FAKE_LSP_STOPREAD=1` — `initialize` 에 답한 뒤 stdin 을 **더 읽지 않는다**(멈춘 서버 — 클라이언트의 쓰기가 밀린다).
//! - **보조 서버 역할**(tooling §8.2u): 첫 인자가 `server`(보조 서버 표의 `ruff server`)면 보조 서버로 선다 — 진단 message 가 `aux: <version>`·
//!   code `A1`(주 서버와 갈라 보인다). 본문에 `AUXQUIET` 이 있으면 보조 서버는 **빈** 진단을 낸다(한 서버의 publish 가 다른 서버의 칸을 안
//!   지우는지). didChange 본문에 `AUXSPOOF` 가 있으면 **청하지 않은 hover 응답**(id `1e8+1`)을 보낸다(보조 서버의 응답이 주 서버의
//!   대기를 못 채우는지). 보조 역할의 code action: `codeActionKinds` 는 `quickfix`·`source.fixAll.ruff`(ruff 꼴), 진단별 quickfix 만 내고
//!   제목에 문맥 진단의 `data.fix` 를 붙인다(`aux: fix A1 (data aux-1)` — 클라이언트가 data 를 되돌렸는지; ruff 처럼 문맥 진단의
//!   `source` 가 `aux` 일 때만 낸다 — 진단에 `source: "aux"` 를 단다), `source.fixAll(.ruff)` 는
//!   `AUXFIX` → `AUX_FIXED`, 본문에 `AUXSTALL` 이 있으면 메뉴 요청에 답하지 않는다. `AUXSLOW` 면 메뉴 요청에 150ms 늦게 답한다. `AUXLAZY` 면 resolve 가 필요한 「aux: lazy」를 더 내고,
//!   보조 역할의 resolve 는 첫 줄에 `# aux lazy` 를 넣는다(주 역할은 `// lazy`). 주 역할은 `quickfix`·`refactor`·
//!   `source.organizeImports`·`source.fixAll` 을 알린다.
//! - **pull 만 내는 주 서버 역할**(계획 editor-lsp-servers-expand LS2·LS4): 실행 파일 이름이 `tsgo`·`ruby-lsp` 면(판정자가 사본을 그 이름으로 두고
//!   `MARU_LSP_SERVER_OVERRIDE` 를 건다) **주 서버**로 서되 파일 진단을 push 하지 않고, 클라이언트가 `textDocument.diagnostic` 을 알렸을 때만
//!   `diagnosticProvider`(`interFileDependencies` 는 `tsgo` 만 참 — 실서버와 같다)를 알린다. `textDocument/diagnostic` 에는 곧바로 `full` — 첫 줄 0..3 에
//!   error `pull: <version> <languageId>`(code `P1`), 본문에 `PQUIET` 면 빈 목록. **열린 문서 어느 것에든** `XFILE` 이 있으면 모든 문서의 답에
//!   `pull: cross`(code `P2`, 둘째 줄 0..1)를 더한다 — 한 파일이 다른 파일의 오류를 바꾸는 파일 간 의존을 흉내 낸다. 본문에
//!   `PREFRESH` 가 있는 문서의 pull 에 답한 직후 `workspace/diagnostic/refresh` 를 **한 번** 보낸다(LS4). `ruby-lsp` 이름이면 실서버의
//!   작업 스레드 지연을 본뜬다 — pull 은 「pull 이 아닌 마지막 요청을 처리한 때」의 version 으로 답하고 다음 didChange 까지 그 답을 캐시한다
//!   (didChange 바로 뒤의 pull 은 옛 version 이다 — 클라이언트는 장벽 요청의 답을 받고 물어야 한다).
//! - **ESLint 역할**(tooling §8.2u): 실행 파일 이름(argv[0])이 `vscode-eslint-language-server` 면(판정자가 저장소 `node_modules/.bin` 에 사본을
//!   둔다) push 를 안 하고 `diagnosticProvider` 를 알린다(클라이언트가 `textDocument.diagnostic` 을 알렸을 때만, `MARU_FAKE_LSP_NOPULLCAP=1` 이면 안 알린다). 첫 `textDocument/diagnostic` 에서 `workspace/configuration`(`srv-c`)을 묻고 그 pull 은
//!   답을 받은 뒤에 답한다 — 설정 객체(`validate: "on"`·`workingDirectory`·`experimental` 객체)가 아니면 실서버처럼 오류. 진단은 첫 줄 0..3 의 `eslint: <version> <didOpen 의 languageId>`(code `no-var`, source
//!   `eslint`), `ESLQUIET` 면 빈 목록, didChange 본문에 `ESLREFRESH` 면 `workspace/diagnostic/refresh` 를 보낸다. code action 은 보조 역할과
//!   같은 모양(`eslint: fix no-var`·`source.fixAll.eslint` 는 `ESLFIX` → `ESL_FIXED`).
//! - **Biome·oxlint 역할**(tooling §8.2u, 계획 AS4): 실행 파일 이름이 `biome`·`oxlint` 면 보조 역할(push 진단·`initialized` 의 설정 요청)에
//!   이름만 다르다 — 진단 `biome: <version>`(source `biome`)·`oxlint: <version>`(source `oxc` — 실서버의 값), fix kind
//!   `source.fixAll.biome`(`BIOFIX` → `BIO_FIXED`)·`source.fixAll.oxc`(`OXFIX` → `OX_FIXED`). Biome 은 실서버처럼 quickfix 의 kind 가
//!   `quickfix.biome` 이고 항목에 편집 없이 `data` 만 싣는다 — resolve 가 `data.edit` 를 돌려준다(다른 서버가 resolve 하면 `# aux lazy`).
//!   oxlint 는 `source.fixAll` 도 알린다(실서버와 같다).
//! 순수 판정 대상이 아니라(맞으면 되는 도구) 테스트는 없다 — 이 도구의 계약은 `LSPB*` 가 제품 경계에서 든다.

const std = @import("std");

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) std.c._exit(0);
        off += @intCast(n);
    }
}

fn sendJson(allocator: std.mem.Allocator, v: anytype) void {
    const body = std.json.Stringify.valueAlloc(allocator, v, .{}) catch return;
    defer allocator.free(body);
    var hdr: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    writeAll(h);
    writeAll(body);
}

fn nextFrame(buf: []const u8) ?struct { body: []const u8, consumed: usize } {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    var len: ?usize = null;
    var it = std.mem.splitSequence(u8, buf[0..header_end], "\r\n");
    while (it.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10) catch return null;
        }
    }
    const n = len orelse return null;
    if (buf.len < header_end + 4 + n) return null;
    return .{ .body = buf[header_end + 4 .. header_end + 4 + n], .consumed = header_end + 4 + n };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        else => null,
    };
}

extern "c" fn usleep(us: c_uint) c_int;

/// `MARU_FAKE_LSP_GRANDCHILD` — 손자를 띄우고 pid 를 적는다. 손자는 fd 0·1 을 그대로 물려받는다(파이프의 끝을 쥔다).
fn spawnGrandchild(dir: [*:0]const u8) void {
    const pid = std.c.fork();
    if (pid < 0) std.c._exit(3);
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sleep", "300" };
        _ = std.c.execve("/bin/sleep", &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch std.c._exit(3);
    var path_buf: [4096]u8 = undefined;
    const pid_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/gc-{d}", .{ std.mem.span(dir), std.c.getpid() }, 0) catch std.c._exit(3);
    // 임시 이름에 쓰고 옮긴다 — 읽는 쪽이 반쯤 쓴 파일을 보지 않게.
    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.tmp", .{pid_path}, 0) catch std.c._exit(3);
    const fd = std.c.open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) std.c._exit(3);
    _ = std.c.write(fd, text.ptr, text.len);
    _ = std.c.close(fd);
    if (std.c.rename(tmp_path, pid_path) != 0) std.c._exit(3);
}

/// stdin EOF 를 봤다는 표식(`<디렉터리>/eof-<pid>`) — 빈 파일 하나.
fn markEof(dir: [*:0]const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/eof-{d}", .{ std.mem.span(dir), std.c.getpid() }, 0) catch return;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);
}

/// `MARU_FAKE_LSP_STOPREAD` — initialize 에 답한 뒤 서버가 stdin 읽기를 멈춘다.
var stop_reading = false;

pub fn main(init: std.process.Init) void {
    const allocator = std.heap.c_allocator;
    if (init.minimal.args.toSlice(allocator)) |argv| {
        auxiliary = argv.len > 1 and std.mem.eql(u8, argv[1], "server");
        // ESLint 역할(보조 서버 표의 `vscode-eslint-language-server` — 판정자가 저장소 `node_modules/.bin` 에 사본으로 둔다).
        const base = if (argv.len > 0) std.fs.path.basename(argv[0]) else "";
        eslint_mode = std.mem.eql(u8, base, "vscode-eslint-language-server");
        // Biome·oxlint 역할(AS4) — 보조 역할에 이름만 다르다.
        biome_mode = std.mem.eql(u8, base, "biome");
        oxlint_mode = std.mem.eql(u8, base, "oxlint");
        pull_primary_mode = std.mem.eql(u8, base, "tsgo") or std.mem.eql(u8, base, "ruby-lsp");
        inter_file_mode = std.mem.eql(u8, base, "tsgo"); // ruby-lsp 는 파일 간 의존을 알리지 않는다(그 소스 `inter_file_dependencies: false`)
        worker_lag_mode = std.mem.eql(u8, base, "ruby-lsp");
        if (biome_mode or oxlint_mode) auxiliary = true;
    } else |_| {}
    const noise = "fake: stderr noise\n";
    _ = std.c.write(2, noise.ptr, noise.len);
    if (std.c.getenv("MARU_FAKE_LSP_GRANDCHILD")) |pid_path| spawnGrandchild(pid_path);
    var inbuf: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (stop_reading) {
            // 살아는 있되 stdin 을 안 읽는다 — 클라이언트가 그룹째 죽일 때까지. 판정자 프로세스가 죽어 고아가 되면(부모가 launchd)
            // EOF 를 볼 길이 없으니 스스로 끝난다.
            if (std.c.getppid() == 1) std.c._exit(0);
            _ = usleep(100_000);
            continue;
        }
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) {
            if (n == 0) if (std.c.getenv("MARU_FAKE_LSP_GRANDCHILD")) |dir| markEof(dir);
            std.c._exit(0);
        }
        inbuf.appendSlice(allocator, chunk[0..@intCast(n)]) catch std.c._exit(2);
        while (nextFrame(inbuf.items)) |f| {
            handle(allocator, f.body);
            const rest = inbuf.items.len - f.consumed;
            std.mem.copyForwards(u8, inbuf.items[0..rest], inbuf.items[f.consumed..]);
            inbuf.shrinkRetainingCapacity(rest);
            if (stop_reading) break;
        }
    }
}

var answered = false;
/// 보조 서버 역할로 떴다(첫 인자 `server`).
var auxiliary = false;
const primary_action_kinds = [_][]const u8{ "quickfix", "refactor", "source.organizeImports", "source.fixAll" };
const aux_action_kinds = [_][]const u8{ "quickfix", "source.fixAll.ruff" };
const eslint_action_kinds = [_][]const u8{ "quickfix", "source.fixAll.eslint" };
const biome_action_kinds = [_][]const u8{ "quickfix.biome", "source.organizeImports.biome", "source.fixAll.biome" };
const oxlint_action_kinds = [_][]const u8{ "quickfix", "source.fixAll.oxc", "source.fixAll" };
/// Biome·oxlint 역할로 떴다(실행 파일 이름 — AS4).
var biome_mode = false;
var oxlint_mode = false;
/// ESLint 역할로 떴다 — pull 진단만, `workspace/configuration` 에 설정 객체를 받아야 검사한다.
var eslint_mode = false;
/// pull 만 내는 주 서버 역할로 떴다(LS2·LS4 — tsgo·ruby-lsp 꼴).
var pull_primary_mode = false;
/// 그 provider 가 `interFileDependencies: true` 를 알린다(tsgo 꼴).
var inter_file_mode = false;
/// ruby-lsp 꼴(LS4) — 요청은 「읽은 때 적용돼 있던 본문」으로 답하고(`DocText.seen_version`) didChange 는 작업 스레드가 나중에 적용한다: pull 의
/// 답은 그 version 이고 다음 didChange 까지 캐시된다(`cached_pull`). pull 이 아닌 요청을 처리할 때면 앞의 didChange 는 적용됐다(`catchUp`).
var worker_lag_mode = false;
/// `PREFRESH` 의 refresh 를 이미 보냈다(한 번만 — 다시 보내면 묻고 답하고 다시 묻기를 되풀이한다).
var primary_refreshed = false;
/// 클라이언트가 `initialize` 에서 `textDocument.diagnostic` 을 알렸다(`PULLCAP` 이 진단에 싣는다).
var client_announced_pull = false;
/// 우리가 낸 설정 요청(`srv-c`)에 설정 객체(`validate: "on"`)로 답을 받았다 / 답을 기다리는 중이다.
var eslint_config_ok = false;
var eslint_config_asked = false;
/// 설정 답을 기다리는 pull 하나(실서버처럼 설정을 받은 뒤 검사한다) — id 원문과 uri.
var eslint_pending_id: [64]u8 = undefined;
var eslint_pending_id_len: usize = 0;
var eslint_pending_uri: [1024]u8 = undefined;
var eslint_pending_uri_len: usize = 0;

/// 보조 역할들(ruff 꼴·ESLint 꼴)의 이름 — code action 의 모양은 같고 이름만 다르다.
const Persona = struct { prefix: []const u8, source: []const u8, fix_kind: []const u8, marker: []const u8, fixed: []const u8, quickfix_kind: []const u8 = "quickfix", lazy: bool = false };
fn persona() ?Persona {
    if (eslint_mode) return .{ .prefix = "eslint", .source = "eslint", .fix_kind = "source.fixAll.eslint", .marker = "ESLFIX", .fixed = "ESL_FIXED" };
    if (biome_mode) return .{ .prefix = "biome", .source = "biome", .fix_kind = "source.fixAll.biome", .marker = "BIOFIX", .fixed = "BIO_FIXED", .quickfix_kind = "quickfix.biome", .lazy = true };
    if (oxlint_mode) return .{ .prefix = "oxlint", .source = "oxc", .fix_kind = "source.fixAll.oxc", .marker = "OXFIX", .fixed = "OX_FIXED" };
    if (auxiliary) return .{ .prefix = "aux", .source = "aux", .fix_kind = "source.fixAll.ruff", .marker = "AUXFIX", .fixed = "AUX_FIXED" };
    return null;
}
/// `initialize` 에서 협상한 위치 인코딩이 utf-16 인가(기본은 utf-8 — 클라이언트가 먼저 제안한다). documentHighlight 가 자리를 이 단위로 읽고 낸다.
var negotiated_utf16 = false;
/// `initialized` 의 `params` 가 객체가 아니었다 — 그 뒤 전부 `ServerNotInitialized`(tsgo 꼴).
var not_initialized = false;
/// `INLREFRESH` — `srv-2`(`workspace/inlayHint/refresh`) 를 보냈나 · 클라이언트가 **result** 로 답했나.
var refresh_sent = false;
var refresh_answered = false;
/// 마지막 didOpen/didChange 본문에 `NOHOVER` 가 있었다 — hover 가 `null` 을 낸다.
var no_hover = false;
/// 마지막 본문에 `MUTEHOVER` 가 있었다 — hover 요청에 **답하지 않는다**.
var mute_hover = false;
/// definition 의 답 모양 — **문서마다**(uri 별로) 본문 표식으로 고른다: `NODEF` → null · `XFILE` → 같은 디렉터리 `other.c` · `OUTSIDE` →
/// root 밖 경로 · 없으면 같은 파일. 전역 하나로 두면 다른 문서의 didOpen 이 뒤에 와서 되돌린다(GOTO1 실측 — other.c 의 didOpen 이
/// g.c 의 `OUTSIDE` 를 지웠다).
const DefMode = enum { same, none, other, outside };
const DocMode = struct { uri: [1024]u8 = undefined, len: usize = 0, mode: DefMode = .same };
var doc_modes: [8]DocMode = @as([8]DocMode, @splat(.{}));

fn setDocMode(uri: []const u8, mode: DefMode) void {
    if (uri.len > 1024) return;
    for (&doc_modes) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) {
        d.mode = mode;
        return;
    };
    for (&doc_modes) |*d| if (d.len == 0) {
        @memcpy(d.uri[0..uri.len], uri);
        d.len = uri.len;
        d.mode = mode;
        return;
    };
}

/// 문서 본문을 uri 별로 기억한다(signatureHelp 가 caret 앞을 본다). 상한 8 문서·64 KB.
const DocText = struct { uri: [1024]u8 = undefined, len: usize = 0, text: [65536]u8 = undefined, text_len: usize = 0, version: i64 = 0, lang: [32]u8 = undefined, lang_len: usize = 0, rangeless: u32 = 0, rejects: u32 = 0, seen_version: i64 = 0, cached_pull: i64 = -1 };
var doc_texts: [8]DocText = @as([8]DocText, @splat(.{}));

fn setDocText(uri: []const u8, text: []const u8, version: i64) void {
    if (uri.len > 1024 or text.len > 65536) return;
    var slot: ?*DocText = null;
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) {
        slot = d;
    };
    if (slot == null) for (&doc_texts) |*d| if (d.len == 0) {
        @memcpy(d.uri[0..uri.len], uri);
        d.len = uri.len;
        slot = d;
        break;
    };
    const d = slot orelse return;
    @memcpy(d.text[0..text.len], text);
    d.text_len = text.len;
    d.version = version;
}

/// didOpen 이 실어 온 `languageId` 를 기억한다(ESLint 꼴의 진단 메시지가 그것을 보인다 — 문서마다 그 문법의 값인지, tooling §8.2u).
fn setDocLang(uri: []const u8, lang: []const u8) void {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) {
        const n = @min(lang.len, d.lang.len);
        @memcpy(d.lang[0..n], lang[0..n]);
        d.lang_len = n;
        return;
    };
}

fn docLang(uri: []const u8) []const u8 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.lang[0..d.lang_len];
    return "";
}

fn docVersion(uri: []const u8) i64 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.version;
    return 0;
}

/// ruby-lsp 꼴(`worker_lag_mode`) — 작업 스레드가 앞의 didChange 를 다 적용했다(pull 이 아닌 요청을 처리하는 때·pull 에 답한 뒤).
fn catchUp() void {
    for (&doc_texts) |*d| d.seen_version = d.version;
}

fn docSlot(uri: []const u8) ?*DocText {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d;
    return null;
}

/// LS3 — didChange 의 변경들을 **서버 사본에 차례로 적용한다**(실서버처럼 — 전에는 첫 변경의 `text` 를 통째로 썼다). range 가 있으면 그 자리를
/// 갈고, 없으면 전문으로 바꾸며 그 수를 센다(`rangeless`). 위치는 협상한 단위, 줄은 maru 와 같은 모델(`\n` 경계, CRLF 의 `\r` 은 줄 내용 밖).
/// **사본 밖 위치는 거부한다**(줄이 없거나 글자가 줄 길이를 넘는다 — ruby-lsp 가 그렇다) — 그 변경을 버리고 사본은 그대로, `rejects` 를 센다.
/// 판정자는 `SYNCSUM` 표식으로 사본의 해시·두 수를 진단에 받아 maru 본문과 맞대 본다.
var splice_a: [65536]u8 = undefined;
var splice_b: [65536]u8 = undefined;
fn applyChanges(uri: []const u8, cc: []const std.json.Value) []const u8 {
    const d = docSlot(uri) orelse return "";
    var cur: []u8 = splice_a[0..d.text_len];
    @memcpy(cur, d.text[0..d.text_len]);
    for (cc) |item| {
        if (item != .object) continue;
        const t = str(item.object.get("text")) orelse continue;
        const r = item.object.get("range") orelse {
            d.rangeless += 1;
            if (t.len > splice_a.len) continue;
            @memcpy(splice_a[0..t.len], t);
            cur = splice_a[0..t.len];
            continue;
        };
        const lo = rangeOffset(cur, r, "start");
        const hi = rangeOffset(cur, r, "end");
        if (lo == null or hi == null or lo.? > hi.? or lo.? + t.len + (cur.len - hi.?) > splice_b.len) {
            d.rejects += 1;
            continue;
        }
        const n = lo.? + t.len + (cur.len - hi.?);
        @memcpy(splice_b[0..lo.?], cur[0..lo.?]);
        @memcpy(splice_b[lo.? .. lo.? + t.len], t);
        @memcpy(splice_b[lo.? + t.len .. n], cur[hi.?..]);
        @memcpy(splice_a[0..n], splice_b[0..n]);
        cur = splice_a[0..n];
    }
    return cur;
}

/// range 의 한 끝(`which` — `start`·`end`) → 사본의 byte. 사본 밖이면 `null`.
fn rangeOffset(text: []const u8, r: std.json.Value, which: []const u8) ?usize {
    if (r != .object) return null;
    const p = r.object.get(which) orelse return null;
    if (p != .object) return null;
    const line = int(p.object.get("line")) orelse return null;
    const ch = int(p.object.get("character")) orelse return null;
    if (line < 0 or ch < 0) return null;
    var start: usize = 0;
    var l: i64 = 0;
    while (l < line) : (l += 1) start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null) + 1;
    var stop = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    if (stop > start and stop < text.len and text[stop - 1] == '\r') stop -= 1; // CRLF 의 `\r` 은 줄 내용 밖
    const content = text[start..stop];
    var units: i64 = 0;
    var bi: usize = 0;
    while (units < ch) {
        if (bi >= content.len) return null; // 줄 길이를 넘는다
        const n = std.unicode.utf8ByteSequenceLength(content[bi]) catch 1;
        if (negotiated_utf16) {
            const cp = std.unicode.utf8Decode(content[bi..@min(bi + n, content.len)]) catch 0xFFFD;
            units += if (cp > 0xFFFF) 2 else 1;
        } else units += @intCast(n);
        bi += @max(1, n);
    }
    if (units != ch) return null; // 글자 가운데를 가리킨다
    return start + bi;
}

fn docText(uri: []const u8) []const u8 {
    for (&doc_texts) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.text[0..d.text_len];
    return "";
}

/// `line_no` 줄의 `character`(byte 로 친다 — 가짜 서버는 ASCII 픽스처만 받는다) 앞 본문.
/// `textDocument/rename`(§8.2f 관측점) — 요청 자리의 식별자를 문서 전체와 같은 디렉터리의 `other.c`(디스크에서 읽는다 — 열려 있지 않아도)
/// 에서 **낱말 단위**로 찾아 `newName` 으로 바꾸는 `WorkspaceEdit`. 기본은 `changes` 맵, `MARU_FAKE_LSP_RENAME_DOCCHANGES=1` 이면
/// `documentChanges`(마지막으로 본 version 을 싣는다). 본문 표식: `RENAMEFAIL` → 오류 응답(`fake: cannot rename`) · `RENAMEOUT` → root 밖
/// 파일의 edit 을 하나 더 · `RENAMECREATE` → `documentChanges` 에 `CreateFile` 을 하나 더 · `RENAMEBAD` → 겹치는 edit 둘.
fn handleRename(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var character: i64 = 0;
    var new_name: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |pos| if (pos == .object) {
            line_no = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
        new_name = str(p.object.get("newName")) orelse "";
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "RENAMEFAIL") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32602), .message = "fake: cannot rename" } });
        return;
    }
    // 요청 자리의 낱말.
    const before = lineBefore(text, line_no, character);
    const line_start = @intFromPtr(before.ptr) - @intFromPtr(text.ptr);
    const caret = line_start + before.len;
    var ws = caret;
    var we = caret;
    while (ws > 0 and isIdent(text[ws - 1])) ws -= 1;
    while (we < text.len and isIdent(text[we])) we += 1;
    if (ws == we) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    const word = text[ws..we];
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const want_create = std.mem.indexOf(u8, text, "RENAMECREATE") != null;
    const stale_ver = std.mem.indexOf(u8, text, "RENAMESTALEVER") != null; // documentChanges 의 version 을 하나 낮춰 낸다(클라이언트가 버려야 한다)
    const use_doc_changes = want_create or stale_ver or std.c.getenv("MARU_FAKE_LSP_RENAME_DOCCHANGES") != null; // 파일 연산은 documentChanges 에만 실릴 수 있다
    var doc_changes: std.json.Array = .init(arena);
    var changes: std.json.ObjectMap = .empty;
    if (want_create) {
        var op: std.json.ObjectMap = .empty;
        op.put(arena, "kind", .{ .string = "create" }) catch return;
        op.put(arena, "uri", .{ .string = "file:///tmp/fake-new.c" }) catch return;
        doc_changes.append(.{ .object = op }) catch return;
    }
    // 이 문서.
    {
        const edits = renameEdits(arena, text, word, new_name, std.mem.indexOf(u8, text, "RENAMEBAD") != null) catch return;
        addFileEdits(arena, &changes, &doc_changes, use_doc_changes, req_uri, docVersion(req_uri) - @as(i64, if (stale_ver) 1 else 0), edits) catch return;
    }
    // 같은 디렉터리의 other.c — 디스크에서 읽는다(열려 있지 않은 파일의 관측점).
    if (std.mem.lastIndexOfScalar(u8, req_uri, '/')) |slash| {
        var uri_buf: [1200]u8 = undefined;
        const other_uri = std.fmt.bufPrint(&uri_buf, "{s}/other.c", .{req_uri[0..slash]}) catch "";
        if (std.mem.startsWith(u8, other_uri, "file://")) {
            const other_path = other_uri["file://".len..];
            if (readFileC(arena, other_path)) |other_text| {
                const edits = renameEdits(arena, other_text, word, new_name, false) catch return;
                if (edits.items.len > 0) {
                    const other_known = docVersion(other_uri);
                    addFileEdits(arena, &changes, &doc_changes, use_doc_changes, other_uri, other_known, edits) catch return;
                }
            }
        }
    }
    if (std.mem.indexOf(u8, text, "RENAMEOUT") != null) {
        const edits = renameEdits(arena, "int x;\n", "x", new_name, false) catch return;
        addFileEdits(arena, &changes, &doc_changes, use_doc_changes, "file:///nonexistent-outside-root/x.c", 0, edits) catch return;
    }
    if (use_doc_changes) {
        root.put(arena, "documentChanges", .{ .array = doc_changes }) catch return;
    } else {
        root.put(arena, "changes", .{ .object = changes }) catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = root } });
}

/// `textDocument/completion`(§8.2g 관측점) — 문서의 식별자(중복 없이, 나온 순서 = sortText `0000`~)를 항목으로 내고, 마지막에 `fake_import`
/// (`textEdit` 로 `[낱말 시작, caret)` 교체 + `additionalTextEdits` 로 첫 줄에 `#include "fake.h"\n`, `preselect`) 를 더한다. **접두사로 거르지
/// 않는다**(로컬 필터의 관측점). caret 앞 낱말이 2 글자 미만이면 `isIncomplete: true`(재요청의 관측점). 본문에 `NOCOMP` 면 `null`.
/// capability `completionProvider{triggerCharacters: ["."]}`(`MARU_FAKE_LSP_NOCOMPCAP=1` 이면 없음).
fn handleCompletion(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var character: i64 = 0;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |pos| if (pos == .object) {
            line_no = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "NOCOMP") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    const before = lineBefore(text, line_no, character);
    var ws = before.len;
    while (ws > 0 and isIdent(before[ws - 1])) ws -= 1;
    const prefix_len = before.len - ws;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    var seen: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        if (!isIdent(text[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and isIdent(text[j])) j += 1;
        const word = text[i..j];
        i = j;
        if (std.ascii.isDigit(word[0])) continue;
        var dup = false;
        for (seen.items) |w| if (std.mem.eql(u8, w, word)) {
            dup = true;
        };
        if (dup) continue;
        seen.append(arena, word) catch return;
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = word }) catch return;
        it.put(arena, "detail", .{ .string = "fake" }) catch return;
        it.put(arena, "sortText", .{ .string = std.fmt.allocPrint(arena, "{d:0>4}", .{n}) catch return }) catch return;
        items.append(.{ .object = it }) catch return;
        n += 1;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "fake_import" }) catch return;
        it.put(arena, "detail", .{ .string = "adds include" }) catch return;
        // labelDetails(§8.2g-c) — 꼬리 + 설명(설명이 있으면 행의 오른쪽은 detail 이 아니라 이것).
        var ld: std.json.ObjectMap = .empty;
        ld.put(arena, "detail", .{ .string = "(use fake)" }) catch return;
        ld.put(arena, "description", .{ .string = "mod fake" }) catch return;
        it.put(arena, "labelDetails", .{ .object = ld }) catch return;
        it.put(arena, "documentation", .{ .string = "adds an include" }) catch return; // 문자열 꼴(§8.2g-d) — resolve 없이 곧바로
        it.put(arena, "sortText", .{ .string = "zzzz" }) catch return;
        it.put(arena, "preselect", .{ .bool = true }) catch return;
        // textEdit: [낱말 시작, caret) → fake_import
        var te: std.json.ObjectMap = .empty;
        var range: std.json.ObjectMap = .empty;
        var s: std.json.ObjectMap = .empty;
        s.put(arena, "line", .{ .integer = line_no }) catch return;
        s.put(arena, "character", .{ .integer = @intCast(ws) }) catch return;
        var e: std.json.ObjectMap = .empty;
        e.put(arena, "line", .{ .integer = line_no }) catch return;
        e.put(arena, "character", .{ .integer = character }) catch return;
        range.put(arena, "start", .{ .object = s }) catch return;
        range.put(arena, "end", .{ .object = e }) catch return;
        te.put(arena, "range", .{ .object = range }) catch return;
        te.put(arena, "newText", .{ .string = "fake_import" }) catch return;
        it.put(arena, "textEdit", .{ .object = te }) catch return;
        var adds: std.json.Array = .init(arena);
        adds.append(editValue(arena, 0, 0, 0, "#include \"fake.h\"\n") catch return) catch return;
        it.put(arena, "additionalTextEdits", .{ .array = adds }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        // fake_tail — additional 이 **낱말 뒤**(다음 줄 머리)에 있다: 응답 뒤 문서가 바뀌면 버려져야 한다(§8.2g 「적용」).
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "fake_tail" }) catch return;
        it.put(arena, "sortText", .{ .string = "zzzx" }) catch return;
        // labelDetails 에 꼬리만(§8.2g-c) — 설명이 없으니 행의 오른쪽은 detail.
        var ld: std.json.ObjectMap = .empty;
        ld.put(arena, "detail", .{ .string = "(tail)" }) catch return;
        it.put(arena, "labelDetails", .{ .object = ld }) catch return;
        it.put(arena, "detail", .{ .string = "int" }) catch return;
        var adds: std.json.Array = .init(arena);
        adds.append(editValue(arena, line_no + 1, 0, 0, "// tail\n") catch return) catch return;
        it.put(arena, "additionalTextEdits", .{ .array = adds }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    if (ws >= 2 and before[ws - 1] == '.' and isIdent(before[ws - 2])) {
        // arrow_fix — `x.` 뒤에서 `textEdit` 이 낱말 시작 **앞**(`x.` 부터)을 덮는다(clangd 의 `.`→`->` 교정과 같은 모양).
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "arrow_fix" }) catch return;
        it.put(arena, "sortText", .{ .string = "0000" }) catch return;
        it.put(arena, "documentation", .{ .string = "arrow doc" }) catch return; // detail 없는 문서(§8.2g-d 패널의 「빈 줄은 detail 이 있을 때만」 관측점)
        var te: std.json.ObjectMap = .empty;
        var range: std.json.ObjectMap = .empty;
        var s: std.json.ObjectMap = .empty;
        s.put(arena, "line", .{ .integer = line_no }) catch return;
        s.put(arena, "character", .{ .integer = @intCast(ws - 2) }) catch return;
        var e: std.json.ObjectMap = .empty;
        e.put(arena, "line", .{ .integer = line_no }) catch return;
        e.put(arena, "character", .{ .integer = character }) catch return;
        range.put(arena, "start", .{ .object = s }) catch return;
        range.put(arena, "end", .{ .object = e }) catch return;
        te.put(arena, "range", .{ .object = range }) catch return;
        te.put(arena, "newText", .{ .string = "x->m" }) catch return;
        it.put(arena, "textEdit", .{ .object = te }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        // lazy_import — additionalTextEdits 없이 `data` 만: resolve 로 온다(§8.2g-b 관측점).
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "lazy_import" }) catch return;
        it.put(arena, "sortText", .{ .string = "zzzw" }) catch return;
        it.put(arena, "kind", .{ .integer = 3 }) catch return;
        var data: std.json.ObjectMap = .empty;
        data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
        it.put(arena, "data", .{ .object = data }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    var root: std.json.ObjectMap = .empty;
    root.put(arena, "isIncomplete", .{ .bool = prefix_len < 2 }) catch return;
    root.put(arena, "items", .{ .array = items }) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = root } });
}

/// `textDocument/foldingRange`(§8.2j): `{` 로 끝나는 줄마다 짝 `}` 줄을 찾아 `startLine..(닫는 줄 - 1)`(tsgo·clangd 모양 — 접어도 `}` 가
/// 보인다)을 낸다. 문서 첫 줄부터 이어지는 `import ` 줄이 둘 이상이면 `imports` 종류 하나를 더한다. **일부러 더러운 것**도 섞는다 — rust-analyzer
/// 처럼 같은 시작줄의 중복(더 작은 것 하나), 문서 밖(`endLine = 줄 수 + 5`), 한 줄짜리 — 클라이언트의 검증(`fold_range.decode`)이 거른다.
/// 문서에 `FOLDSTALL` 이면 답하지 않고, `FOLDERR` 면 `-32801 content modified` 오류, `FOLDEMPTY` 면 빈 배열.
fn handleFoldingRange(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "FOLDSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "FOLDERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    if (std.mem.indexOf(u8, text, "FOLDEMPTY") == null) {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| lines.append(arena, l) catch return;
        const n = lines.items.len;
        var imports: usize = 0;
        while (imports < n and std.mem.startsWith(u8, lines.items[imports], "import ")) imports += 1;
        if (imports >= 2) appendFold(arena, &out, 0, @intCast(imports - 1), "imports") catch return;
        for (lines.items, 0..) |l, i| {
            const t = std.mem.trimEnd(u8, l, " \t\r");
            if (t.len == 0 or t[t.len - 1] != '{') continue;
            var depth: usize = 0;
            var j = i;
            var close: ?usize = null;
            while (j < n) : (j += 1) {
                for (lines.items[j]) |b| {
                    if (b == '{') depth += 1;
                    if (b == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            close = j;
                            break;
                        }
                    }
                }
                if (close != null) break;
            }
            const c = close orelse continue;
            if (c <= i + 1) continue; // `{ }` 가 바로 다음 줄에 닫히면 한 줄짜리 — 서버도 안 낸다
            appendFold(arena, &out, @intCast(i), @intCast(c - 1), null) catch return;
            if (i == 0 or out.items.len == 1) {
                // 첫 블록에는 rust-analyzer 처럼 같은 시작줄의 더 작은 중복을 하나 더 낸다.
                appendFold(arena, &out, @intCast(i), @intCast(i + 1), null) catch return;
            }
        }
        // 더러운 것 둘 — 문서 밖과 한 줄짜리.
        appendFold(arena, &out, @intCast(n -| 1), @intCast(n + 5), null) catch return;
        appendFold(arena, &out, 0, 0, "region") catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = out } });
}

fn appendFold(arena: std.mem.Allocator, out: *std.json.Array, start: i64, end: i64, kind: ?[]const u8) !void {
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "startLine", .{ .integer = start });
    try o.put(arena, "endLine", .{ .integer = end });
    if (kind) |k| try o.put(arena, "kind", .{ .string = k });
    try out.append(.{ .object = o });
}

/// `textDocument/semanticTokens/range`·`full`(§8.2i): 요청 범위(full 이면 전부) 안의 식별자를 **이름 꼬리로** 분류해 relative 5-tuple 로 낸다 —
/// `*_fn` → function(1) · `*_ty` → type(3) · `*_kw` → keyword(0) · `*_bogus` → bogusKind(4, 클라이언트가 모르는 종류) · 나머지 → variable(2).
/// 문서에 `SEMSTALL` 이면 답하지 않고, `SEMERR` 면 `-32801 content modified` 오류.
fn handleSemanticTokens(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value, full: bool) void {
    var req_uri: []const u8 = "";
    var lo: i64 = 0;
    var hi: i64 = std.math.maxInt(i32);
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (!full) if (p.object.get("range")) |r| if (r == .object) {
            if (r.object.get("start")) |st| if (st == .object) {
                lo = int(st.object.get("line")) orelse 0;
            };
            if (r.object.get("end")) |en| if (en == .object) {
                hi = int(en.object.get("line")) orelse hi;
            };
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "SEMSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "SEMERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var data: std.json.Array = .init(arena);
    var line: i64 = 0;
    var col: i64 = 0; // 줄 안 byte 열(fake 는 utf-8 이 기본)
    var prev_line: i64 = 0;
    var prev_col: i64 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (!isIdent(b)) {
            i += 1;
            col += 1;
            continue;
        }
        var j = i;
        while (j < text.len and isIdent(text[j])) j += 1;
        const word = text[i..j];
        const wlen: i64 = @intCast(j - i);
        if (!std.ascii.isDigit(word[0]) and line >= lo and line < hi) {
            const ty: i64 = if (std.mem.endsWith(u8, word, "_fn")) 1 else if (std.mem.endsWith(u8, word, "_ty")) 3 else if (std.mem.endsWith(u8, word, "_kw")) 0 else if (std.mem.endsWith(u8, word, "_bogus")) 4 else 2;
            const dl = line - prev_line;
            const dc = if (dl == 0) col - prev_col else col;
            data.append(.{ .integer = dl }) catch return;
            data.append(.{ .integer = dc }) catch return;
            data.append(.{ .integer = wlen }) catch return;
            data.append(.{ .integer = ty }) catch return;
            data.append(.{ .integer = 0 }) catch return;
            prev_line = line;
            prev_col = col;
        }
        col += wlen;
        i = j;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .data = std.json.Value{ .array = data }, .resultId = "1" } });
}

/// `textDocument/codeAction`(§8.2h 관측점) — `context.diagnostics` 마다 「fake: fix <code>」(그 range 를 `FIXED` 로 바꾸는 `edit`, 첫 것은
/// `isPreferred`), 늘 「fake: lazy」(`edit` 없이 `data` 만 — resolve 로 온다)와 「fake: command」(`command` 만 — 숨겨져야 한다), `Command` 형
/// 하나. 본문에 `NOACT` 면 `[]`. `RESOLVEFAIL` 이면 resolve 가 오류 응답. 진단 없이 오면 fix 는 없다(문맥 관측점).
fn handleCodeAction(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var ctx_diags: ?std.json.Array = null;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("context")) |c| if (c == .object) if (c.object.get("diagnostics")) |d| if (d == .array) {
            ctx_diags = d.array;
        };
        if (p.object.get("context")) |c| if (c == .object) if (c.object.get("only")) |o| if (o == .array) {
            return handleSourceActions(allocator, o.array.items, req_uri, id);
        };
    };
    const text = docText(req_uri);
    if (auxiliary and std.mem.indexOf(u8, text, "AUXSTALL") != null) return; // 보조 서버가 메뉴 요청에 답하지 않는다(시한 관측점)
    if (auxiliary and std.mem.indexOf(u8, text, "AUXSLOW") != null) _ = usleep(150_000); // 늦지만 시한 안에 답한다
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    if (std.mem.indexOf(u8, text, "NOACT") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
        return;
    }
    if (ctx_diags) |ds| for (ds.items, 0..) |dg, i| {
        if (dg != .object) continue;
        const range = dg.object.get("range") orelse continue;
        const code = str(dg.object.get("code")) orelse "?";
        // 문맥 진단의 `data.fix`(보조 서버가 publish 에 실은 것)를 제목에 — 클라이언트가 되돌렸는지 보인다.
        const data_fix: ?[]const u8 = if (dg.object.get("data")) |dd| (if (dd == .object) str(dd.object.get("fix")) else null) else null;
        // 보조 역할은 ruff 처럼 문맥 진단의 `source` 가 제 것(`aux`)일 때만 quickfix 를 낸다.
        if (persona()) |pp| if (!std.mem.eql(u8, str(dg.object.get("source")) orelse "", pp.source)) continue;
        var it: std.json.ObjectMap = .empty;
        const who = if (persona()) |pp| pp.prefix else "fake";
        const title = if (data_fix) |df| std.fmt.allocPrint(arena, "{s}: fix {s} (data {s})", .{ who, code, df }) catch return else std.fmt.allocPrint(arena, "{s}: fix {s}", .{ who, code }) catch return;
        it.put(arena, "title", .{ .string = title }) catch return;
        it.put(arena, "kind", .{ .string = if (persona()) |pp| pp.quickfix_kind else "quickfix" }) catch return;
        if (i == 0) it.put(arena, "isPreferred", .{ .bool = true }) catch return;
        var te: std.json.ObjectMap = .empty;
        te.put(arena, "range", range) catch return;
        te.put(arena, "newText", .{ .string = "FIXED" }) catch return;
        var arr: std.json.Array = .init(arena);
        arr.append(.{ .object = te }) catch return;
        var changes: std.json.ObjectMap = .empty;
        changes.put(arena, arena.dupe(u8, req_uri) catch return, .{ .array = arr }) catch return;
        var edit: std.json.ObjectMap = .empty;
        edit.put(arena, "changes", .{ .object = changes }) catch return;
        if (persona()) |pp| if (pp.lazy) {
            lazyItem(arena, &it, req_uri, edit) catch return;
            items.append(.{ .object = it }) catch return;
            continue;
        };
        it.put(arena, "edit", .{ .object = edit }) catch return;
        items.append(.{ .object = it }) catch return;
    };
    if (persona() != null) { // 보조 서버(ruff 꼴·ESLint 꼴)는 진단별 quickfix 만 — `AUXLAZY` 면 resolve 가 필요한 「aux: lazy」 하나 더
        if (std.mem.indexOf(u8, text, "AUXLAZY") != null) {
            var it: std.json.ObjectMap = .empty;
            it.put(arena, "title", .{ .string = "aux: lazy" }) catch return;
            it.put(arena, "kind", .{ .string = "quickfix" }) catch return;
            var data: std.json.ObjectMap = .empty;
            data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
            it.put(arena, "data", .{ .object = data }) catch return;
            items.append(.{ .object = it }) catch return;
        }
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
        return;
    }
    if (std.mem.indexOf(u8, text, "MANYACT") != null) {
        // 상한(25 = 메뉴 버퍼) 관측점 — data 만 있는 항목 30 개.
        var n: usize = 0;
        while (n < 30) : (n += 1) {
            var it: std.json.ObjectMap = .empty;
            it.put(arena, "title", .{ .string = std.fmt.allocPrint(arena, "fake: many {d}", .{n}) catch return }) catch return;
            var data: std.json.ObjectMap = .empty;
            data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
            it.put(arena, "data", .{ .object = data }) catch return;
            items.append(.{ .object = it }) catch return;
        }
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: lazy" }) catch return;
        it.put(arena, "kind", .{ .string = "refactor" }) catch return;
        var data: std.json.ObjectMap = .empty;
        data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
        data.put(arena, "id", .{ .integer = 1 }) catch return;
        it.put(arena, "data", .{ .object = data }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: command" }) catch return;
        var cmd: std.json.ObjectMap = .empty;
        cmd.put(arena, "title", .{ .string = "c" }) catch return;
        cmd.put(arena, "command", .{ .string = "fake.run" }) catch return;
        it.put(arena, "command", .{ .object = cmd }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    {
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "title", .{ .string = "fake: Command form" }) catch return;
        it.put(arena, "command", .{ .string = "fake.run" }) catch return;
        items.append(.{ .object = it }) catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
}

/// 저장 시 code action(§8.2s 관측점) — `context.only` 가 있으면 그 kind 의 source action 만 낸다. 본문 표식:
/// `CASTALL` 이면 답하지 않는다(시한) · `UNORGANIZED` → `source.organizeImports`(그 낱말을 `ORGANIZED` 로) · `ORGLAZY` → `edit` 없이 `data` 만
/// (resolve 가 첫 줄에 `// lazy` — 위와 같다) · `ORGOTHER` → 다른 파일도 고치는 edit(건너뛰어져야 한다) · `ORGBAD` → 겹치는 edit 둘(거부) ·
/// `FIXALL` → `source.fixAll.fake`(하위 kind — `FIXED_ALL` 로) · `WRONGKIND` → 요청과 다른 kind(`quickfix`)의 항목도 낸다(클라이언트가 걸러야 한다).
fn handleSourceActions(allocator: std.mem.Allocator, only: []const std.json.Value, req_uri: []const u8, id: std.json.Value) void {
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "CASTALL") != null) return;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    const Mk = struct {
        fn replaceItem(a: std.mem.Allocator, title: []const u8, kind: []const u8, uri: []const u8, body: []const u8, marker: []const u8, new_text: []const u8) ?std.json.Value {
            const at = std.mem.indexOf(u8, body, marker) orelse return null;
            const line_no = std.mem.count(u8, body[0..at], "\n");
            const line_start = if (std.mem.lastIndexOfScalar(u8, body[0..at], '\n')) |nl| nl + 1 else 0;
            const ch = at - line_start;
            var arr: std.json.Array = .init(a);
            arr.append(editValue(a, @intCast(line_no), ch, ch + marker.len, new_text) catch return null) catch return null;
            var changes: std.json.ObjectMap = .empty;
            changes.put(a, a.dupe(u8, uri) catch return null, .{ .array = arr }) catch return null;
            var edit: std.json.ObjectMap = .empty;
            edit.put(a, "changes", .{ .object = changes }) catch return null;
            var it: std.json.ObjectMap = .empty;
            it.put(a, "title", .{ .string = title }) catch return null;
            it.put(a, "kind", .{ .string = kind }) catch return null;
            it.put(a, "edit", .{ .object = edit }) catch return null;
            return .{ .object = it };
        }
    };
    for (only) |k| {
        const kind = if (k == .string) k.string else continue;
        if (persona()) |pp| {
            // 보조 서버: `source.fixAll`·그 도구의 fixAll kind 만 — 표식(`AUXFIX`·`ESLFIX`)을 바꾼다.
            if (std.mem.eql(u8, kind, "source.fixAll") or std.mem.eql(u8, kind, pp.fix_kind)) {
                const t = std.fmt.allocPrint(arena, "{s}: fix all", .{pp.prefix}) catch return;
                if (Mk.replaceItem(arena, t, pp.fix_kind, req_uri, text, pp.marker, pp.fixed)) |item| {
                    var it = item.object;
                    if (pp.lazy) {
                        const edit = it.fetchSwapRemove("edit").?.value.object;
                        lazyItem(arena, &it, req_uri, edit) catch return;
                    }
                    items.append(.{ .object = it }) catch return;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, kind, "source.organizeImports")) {
            if (std.mem.indexOf(u8, text, "ORGLAZY") != null) {
                var it: std.json.ObjectMap = .empty;
                it.put(arena, "title", .{ .string = "fake: organize (lazy)" }) catch return;
                it.put(arena, "kind", .{ .string = "source.organizeImports" }) catch return;
                var data: std.json.ObjectMap = .empty;
                data.put(arena, "uri", .{ .string = arena.dupe(u8, req_uri) catch return }) catch return;
                it.put(arena, "data", .{ .object = data }) catch return;
                items.append(.{ .object = it }) catch return;
            } else if (std.mem.indexOf(u8, text, "ORGOTHER") != null) {
                var item = Mk.replaceItem(arena, "fake: organize (other)", "source.organizeImports", req_uri, text, "ORGOTHER", "X") orelse return;
                const changes = &item.object.getPtr("edit").?.object.getPtr("changes").?.object;
                var arr: std.json.Array = .init(arena);
                arr.append(editValue(arena, 0, 0, 0, "// other\n") catch return) catch return;
                changes.put(arena, "file:///nonexistent-fake-other.c", .{ .array = arr }) catch return;
                items.append(item) catch return;
            } else if (std.mem.indexOf(u8, text, "ORGBAD") != null) {
                var item = Mk.replaceItem(arena, "fake: organize (bad)", "source.organizeImports", req_uri, text, "ORGBAD", "x") orelse return;
                const arr = &item.object.getPtr("edit").?.object.getPtr("changes").?.object.getPtr(req_uri).?.array;
                const first = arr.items[0];
                arr.append(first) catch return; // 같은 범위 둘 — 겹친다
                items.append(item) catch return;
            } else if (Mk.replaceItem(arena, "fake: organize imports", "source.organizeImports", req_uri, text, "UNORGANIZED", "ORGANIZED")) |item| {
                items.append(item) catch return;
            }
        } else if (std.mem.eql(u8, kind, "source.fixAll")) {
            if (Mk.replaceItem(arena, "fake: fix all", "source.fixAll.fake", req_uri, text, "FIXALL", "FIXED_ALL")) |item| items.append(item) catch return;
        }
        if (std.mem.indexOf(u8, text, "WRONGKIND") != null) {
            if (Mk.replaceItem(arena, "fake: wrong kind", "quickfix", req_uri, text, "WRONGKIND", "WRONG_APPLIED")) |item| items.insert(0, item) catch return;
        }
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = items } });
}

/// `codeAction/resolve` — `data.uri` 의 문서 첫 줄 머리에 `// lazy\n` 을 넣는 `edit`. `RESOLVEFAIL` 이면 오류.
/// pull 진단(ESLint 꼴 — §8.2u): 설정 답을 못 받았으면 실서버처럼 오류. 아니면 `full` — 첫 줄 0..3 에 warning `eslint: <version> <languageId>`(code `no-var`,
/// source `eslint`, data 없음 — ESLint 는 data 를 안 싣는다). `ESLQUIET` 면 빈 목록.
fn handlePullDiagnostics(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var uri: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) if (p.object.get("textDocument")) |td| if (td == .object) {
        uri = str(td.object.get("uri")) orelse "";
    };
    if (!eslint_config_asked) {
        // 처음이면 설정을 묻고 이 pull 은 답을 받은 뒤에(실서버는 진단 요청을 처리하며 설정을 묻고 기다린다).
        eslint_config_asked = true;
        const id_json = std.json.Stringify.valueAlloc(allocator, id, .{}) catch return;
        defer allocator.free(id_json);
        if (id_json.len > eslint_pending_id.len or uri.len > eslint_pending_uri.len) return;
        @memcpy(eslint_pending_id[0..id_json.len], id_json);
        eslint_pending_id_len = id_json.len;
        @memcpy(eslint_pending_uri[0..uri.len], uri);
        eslint_pending_uri_len = uri.len;
        // 항목 둘 — 클라이언트가 `items` 수만큼 답하는지(실서버는 하나를 묻는다).
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-c", .method = "workspace/configuration", .params = .{ .items = [_]struct { scopeUri: []const u8, section: []const u8 }{ .{ .scopeUri = uri, .section = "" }, .{ .scopeUri = uri, .section = "" } } } });
        return;
    }
    answerPull(allocator, id, uri);
}

/// pull 만 내는 주 서버의 pull(LS2 — tsgo 꼴) — 설정을 묻지 않고 곧바로 `full`. 파일 간 의존(`XFILE`)은 열린 문서 전부를 본다.
fn answerPrimaryPull(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var uri: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) if (p.object.get("textDocument")) |td| if (td == .object) {
        uri = str(td.object.get("uri")) orelse "";
    };
    var msg_buf: [64]u8 = undefined;
    const seen: i64 = if (worker_lag_mode) blk: {
        const sl = docSlot(uri) orelse break :blk 0;
        if (sl.cached_pull < 0) sl.cached_pull = sl.seen_version;
        break :blk sl.cached_pull;
    } else docVersion(uri);
    defer if (worker_lag_mode) catchUp();
    const msg = std.fmt.bufPrint(&msg_buf, "pull: {d} {s}", .{ seen, docLang(uri) }) catch "pull";
    const Diag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8 };
    var items: [2]Diag = undefined;
    var n: usize = 0;
    if (std.mem.indexOf(u8, docText(uri), "PQUIET") == null) {
        items[n] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .severity = 1, .message = msg, .code = "P1" };
        n += 1;
    }
    const cross = for (&doc_texts) |*d| {
        if (d.len > 0 and std.mem.indexOf(u8, d.text[0..d.text_len], "XFILE") != null) break true;
    } else false;
    if (cross) {
        items[n] = .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 1 } }, .severity = 1, .message = "pull: cross", .code = "P2" };
        n += 1;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .kind = "full", .items = items[0..n] } });
    if (!primary_refreshed and std.mem.indexOf(u8, docText(uri), "PREFRESH") != null) {
        primary_refreshed = true;
        for (&doc_texts) |*d| d.cached_pull = -1; // 실서버는 캐시를 비우고 refresh 를 보낸다
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-r", .method = "workspace/diagnostic/refresh", .params = null });
    }
}

fn answerPull(allocator: std.mem.Allocator, id: std.json.Value, uri: []const u8) void {
    if (!eslint_config_ok) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32603), .message = "Request textDocument/diagnostic failed with message: Cannot read properties of null (reading 'workingDirectory')" } });
        return;
    }
    const text = docText(uri);
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "eslint: {d} {s}", .{ docVersion(uri), docLang(uri) }) catch "eslint";
    const Diag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8, source: []const u8 };
    const one = [_]Diag{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .severity = 2, .message = msg, .code = "no-var", .source = "eslint" }};
    const quiet = std.mem.indexOf(u8, text, "ESLQUIET") != null;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .kind = "full", .items = if (quiet) one[0..0] else one[0..] } });
}

/// Biome 꼴 — 편집을 빼고 `data` 에 싣는다(`uri`·`edit`). resolve 가 그 편집을 돌려준다.
fn lazyItem(arena: std.mem.Allocator, it: *std.json.ObjectMap, uri: []const u8, edit: std.json.ObjectMap) !void {
    var data: std.json.ObjectMap = .empty;
    try data.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
    try data.put(arena, "edit", .{ .object = edit });
    try it.put(arena, "data", .{ .object = data });
}

fn handleCodeActionResolve(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var uri: []const u8 = "";
    var data_edit: ?std.json.Value = null;
    if (obj.get("params")) |p| if (p == .object) if (p.object.get("data")) |d| if (d == .object) {
        uri = str(d.object.get("uri")) orelse "";
        data_edit = d.object.get("edit");
    };
    // Biome 꼴은 항목을 낼 때 미뤄 둔 편집을 돌려준다 — 다른 역할이 받으면 아래 제 글(`# aux lazy`)이라 어느 서버가 resolve 했는지 보인다.
    if (biome_mode) if (data_edit) |e| {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .title = "biome: resolved", .edit = e } });
        return;
    };
    const text = docText(uri);
    if (std.mem.indexOf(u8, text, "RESOLVEFAIL") != null or uri.len == 0) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32603), .message = "fake: cannot resolve" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "RESOLVEEMPTY") != null) {
        // edit 없이 돌려준다 — 클라이언트가 「없음」을 알려야 한다.
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .title = "fake: lazy" } });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var arr: std.json.Array = .init(arena);
    arr.append(editValue(arena, 0, 0, 0, if (auxiliary) "# aux lazy\n" else "// lazy\n") catch return) catch return; // 보조 역할은 다른 글 — 어느 서버가 resolve 했는지 보인다
    var changes: std.json.ObjectMap = .empty;
    changes.put(arena, arena.dupe(u8, uri) catch return, .{ .array = arr }) catch return;
    var edit: std.json.ObjectMap = .empty;
    edit.put(arena, "changes", .{ .object = changes }) catch return;
    var it: std.json.ObjectMap = .empty;
    it.put(arena, "title", .{ .string = "fake: lazy" }) catch return;
    it.put(arena, "edit", .{ .object = edit }) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = it } });
}

/// libc 로 파일을 읽는다(이 도구는 std.Io 를 안 쓴다). 없으면 null. 상한 64 KB.
fn readFileC(arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    var path_z: [1200]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = std.c.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const buf = arena.alloc(u8, 65536) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

/// byte 열의 **utf-16 단위 수**(가짜의 documentHighlight 가 자리를 낼 때 쓴다).
fn utf16Units(bytes: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const cp = std.unicode.utf8Decode(bytes[i..@min(i + n, bytes.len)]) catch 0xFFFD;
        units += if (cp > 0xFFFF) 2 else 1;
        i += @max(1, n);
    }
    return units;
}

fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// `text` 안의 `word` 낱말 전부를 `new_name` 으로 바꾸는 TextEdit 들(character = byte — ASCII 본문). `bad` 면 첫 edit 을 겹치게 하나 더 낸다.
/// `textDocument/references`(§8.2l 관측점): 요청 자리의 식별자를 이 문서 전체에서 **낱말 단위**로 찾아 `Location[]` 로 낸다 — **뒤에서 앞으로**
/// (클라이언트가 정렬하는지 보이게) 그리고 첫 위치를 **두 번**(중복을 하나로 접는지). 같은 디렉터리에 `other.c` 가 있으면 디스크에서 읽어 그
/// 파일의 위치도 섞는다(열려 있지 않은 파일). 본문 표식: `REFOUT` → root 밖 위치 하나 더 · `REFNONE` → 빈 배열 · `REFNULL` → `null` ·
/// `REFSTALL` → 답하지 않는다 · `REFBUSY` → `-32801 content modified` 오류(rust-analyzer 가 로드 중에 내는 것 — 클라이언트가 되묻는다).
fn handleReferences(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var character: i64 = 0;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |pos| if (pos == .object) {
            line_no = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "REFSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "REFBUSY") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "REFNULL") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    if (std.mem.indexOf(u8, text, "REFNONE") == null) {
        const before = lineBefore(text, line_no, character);
        const line_start = @intFromPtr(before.ptr) - @intFromPtr(text.ptr);
        const caret = line_start + before.len;
        var ws = caret;
        var we = caret;
        while (ws > 0 and isIdent(text[ws - 1])) ws -= 1;
        while (we < text.len and isIdent(text[we])) we += 1;
        if (ws < we) {
            const word = text[ws..we];
            // 이 문서 — 뒤에서 앞으로, 첫 것은 두 번.
            const mine = wordLocations(arena, text, word, req_uri) catch return;
            var i: usize = mine.items.len;
            while (i > 0) : (i -= 1) out.append(mine.items[i - 1]) catch return;
            if (mine.items.len > 0) out.append(mine.items[0]) catch return;
            // 같은 디렉터리의 other.c — 디스크에서.
            var uri_buf: [4096]u8 = undefined;
            if (std.mem.lastIndexOfScalar(u8, req_uri, '/')) |slash| {
                const other_uri = std.fmt.bufPrint(&uri_buf, "{s}/other.c", .{req_uri[0..slash]}) catch "";
                if (std.mem.startsWith(u8, other_uri, "file://")) {
                    if (readFileC(arena, other_uri["file://".len..])) |other_text| {
                        const theirs = wordLocations(arena, other_text, word, arena.dupe(u8, other_uri) catch return) catch return;
                        for (theirs.items) |l| out.append(l) catch return;
                    }
                }
            }
            if (std.mem.indexOf(u8, text, "REFOUT") != null) {
                out.append(locationValue(arena, "file:///nonexistent-outside-root/x.c", 3, 0, 4) catch return) catch return;
            }
        }
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = out } });
}

const KindShape = enum { tail_all, first_one };

fn handleLocationKind(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value, shape: KindShape) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var character: i64 = 0;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |pos| if (pos == .object) {
            line_no = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "REFBUSY") != null) { // 참조와 같은 「지금은 못 답한다」(§8.2m — 되묻기는 종류를 든 채)
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    const before = lineBefore(text, line_no, character);
    const line_start = @intFromPtr(before.ptr) - @intFromPtr(text.ptr);
    const caret = line_start + before.len;
    var ws = caret;
    var we = caret;
    while (ws > 0 and isIdent(text[ws - 1])) ws -= 1;
    while (we < text.len and isIdent(text[we])) we += 1;
    if (ws < we) {
        const mine = wordLocations(arena, text, text[ws..we], req_uri) catch return;
        switch (shape) {
            .tail_all => {
                var i: usize = 1;
                while (i < mine.items.len) : (i += 1) out.append(asLink(arena, mine.items[i]) catch return) catch return;
            },
            .first_one => {
                // `REFTD2` 표식이면 둘(피커의 종류별 프롬프트를 재게) — 아니면 첫 것 하나.
                const n: usize = if (std.mem.indexOf(u8, text, "REFTD2") != null) @min(2, mine.items.len) else @min(1, mine.items.len);
                var i: usize = 0;
                while (i < n) : (i += 1) out.append(asLink(arena, mine.items[i]) catch return) catch return;
            },
        }
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = out } });
}

/// `Location` → `LocationLink`(targetUri·targetRange·targetSelectionRange) — tsgo 가 내는 모양.
fn asLink(arena: std.mem.Allocator, loc: std.json.Value) !std.json.Value {
    var link: std.json.ObjectMap = .empty;
    try link.put(arena, "targetUri", loc.object.get("uri").?);
    try link.put(arena, "targetRange", loc.object.get("range").?);
    try link.put(arena, "targetSelectionRange", loc.object.get("range").?);
    return .{ .object = link };
}

/// `textDocument/inlayHint`(§8.2n 관측점): 요청 범위 안 줄마다 — `<name>_hv` 낱말 뒤에 타입 힌트 `: int`(kind 1, 조각 배열, padding 없음),
/// `(` 바로 뒤 첫 인자 앞에 파라미터 힌트 `p:`(kind 2, `paddingRight`), 줄 끝에 `RET` 표식이 있으면 `-> void`(paddingLeft). 일부러 **뒤에서
/// 앞으로** 낸다(클라이언트가 정렬하는지). 문서에 `INLSTALL` 이면 답하지 않고, `INLERR` 면 `-32801`, `INLNULL` 이면 `null`.
/// `textDocument/documentHighlight`(§8.2p) — 요청 자리의 **낱말**과 같은 글자를 문서에서 찾아 낸다(주석·문자열도 가리지 않는다 — 가짜다).
/// `kind` 는 **일부러 섞는다**(없음·2·3) — 클라이언트가 그것을 안 쓰는지 본다. 표식: `DHLNONE` 빈 목록 · `DHLSTALL` 무응답 · `DHLERR` `-32801`.
fn handleDocumentHighlight(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var line_no: i64 = 0;
    var ch: i64 = 0;
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("position")) |ps| if (ps == .object) {
            line_no = int(ps.object.get("line")) orelse 0;
            ch = int(ps.object.get("character")) orelse 0;
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "DHLSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "DHLERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "DHLNONE") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [0]u32{} });
        return;
    }
    // 요청 줄에서 그 자리의 낱말을 끊어 낸다.
    var it0 = std.mem.splitScalar(u8, text, '\n');
    var i: i64 = 0;
    const line = while (it0.next()) |l| : (i += 1) {
        if (i == line_no) break l;
    } else return;
    // **`character` 는 협상한 단위다**(utf-8 이면 byte, utf-16 이면 utf-16 글자). utf-16 이면 byte 로 환산해서 본다 —
    // ASCII 픽스처만 쓰면 이 환산이 보이지 않아 클라이언트의 utf-16 변환 결함이 숨는다(적대적 C4, `MARU_FAKE_LSP_UTF16=1` 로 잰다).
    const at: usize = if (!negotiated_utf16) @intCast(@max(0, @min(ch, @as(i64, @intCast(line.len))))) else blk: {
        var units: i64 = 0;
        var bi: usize = 0;
        while (bi < line.len) {
            if (units >= ch) break :blk bi;
            const n = std.unicode.utf8ByteSequenceLength(line[bi]) catch 1;
            const cp = std.unicode.utf8Decode(line[bi..@min(bi + n, line.len)]) catch 0xFFFD;
            units += if (cp > 0xFFFF) 2 else 1; // surrogate pair 는 둘
            bi += @max(1, n);
        }
        break :blk line.len;
    };
    if (at >= line.len or !isIdent(line[at])) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [0]u32{} });
        return;
    }
    var lo = at;
    while (lo > 0 and isIdent(line[lo - 1])) lo -= 1;
    var hi = at;
    while (hi < line.len and isIdent(line[hi])) hi += 1;
    const word = line[lo..hi];

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    var row: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var kind_turn: i64 = 0;
    while (it.next()) |l| : (row += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, l, from, word)) |found| {
            from = found + word.len;
            const left_ok = found == 0 or !isIdent(l[found - 1]);
            const right_ok = found + word.len >= l.len or !isIdent(l[found + word.len]);
            if (!left_ok or !right_ok) continue; // 낱말 경계 — 부분 일치는 아니다
            var r: std.json.ObjectMap = .empty;
            // **자리도 utf-16 단위로 낸다** — 받는 쪽(`character`)과 내는 쪽이 같은 단위여야 한다(실서버 규약).
            const lo_u = if (negotiated_utf16) utf16Units(l[0..found]) else found;
            const hi_u = if (negotiated_utf16) utf16Units(l[0 .. found + word.len]) else found + word.len;
            r.put(arena, "start", posValue(arena, row, lo_u) catch return) catch return;
            r.put(arena, "end", posValue(arena, row, hi_u) catch return) catch return;
            var h: std.json.ObjectMap = .empty;
            h.put(arena, "range", .{ .object = r }) catch return;
            // 0 → kind 없음, 1 → 2(Read), 2 → 3(Write) 를 돌아가며(실서버 셋의 모양을 섞는다).
            if (@mod(kind_turn, 3) != 0) h.put(arena, "kind", .{ .integer = 1 + @mod(kind_turn, 3) }) catch return;
            kind_turn += 1;
            out.append(.{ .object = h }) catch return;
        }
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = out } });
}

/// `textDocument/selectionRange`(§8.2q) — 위치마다 사슬 하나: **그 자리 낱말 → 낱말부터 그 줄 끝까지 → 문서 전체**. 가운데 단계는
/// tree-sitter 도 낱말 단계도 안 만드는 모양이라 판정자가 「서버 답이 쓰였다」를 가린다. 자리는 **협상한 단위**로 읽고 낸다.
/// 표식: `SSRNONE` 위치마다 빈 범위 하나(부모 없음 — clangd 주석 꼴) · `SSRSTALL` 무응답 · `SSRERR` `-32801` · `SSRSHORT` 위치보다 하나 적게.
fn handleSelectionRange(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var positions: []const std.json.Value = &.{};
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("positions")) |ps| if (ps == .array) {
            positions = ps.array.items;
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "SSRSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "SSRERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    const none = std.mem.indexOf(u8, text, "SSRNONE") != null;
    const short = std.mem.indexOf(u8, text, "SSRSHORT") != null;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 문서 끝 자리(마지막 줄 · 그 줄의 길이).
    var last_row: i64 = 0;
    var last_len: usize = 0;
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        var row: i64 = 0;
        while (it.next()) |l| : (row += 1) {
            last_row = row;
            last_len = if (negotiated_utf16) utf16Units(l) else l.len;
        }
    }
    var out: std.json.Array = .init(arena);
    for (positions, 0..) |pv, pi| {
        if (short and pi + 1 == positions.len) break;
        if (pv != .object) continue;
        const line_no = int(pv.object.get("line")) orelse 0;
        const ch = int(pv.object.get("character")) orelse 0;
        var it0 = std.mem.splitScalar(u8, text, '\n');
        var i: i64 = 0;
        const line = while (it0.next()) |l| : (i += 1) {
            if (i == line_no) break l;
        } else "";
        const at = byteAtUnits(line, ch);
        const at_u = if (negotiated_utf16) utf16Units(line[0..at]) else at;
        if (none) {
            out.append(rangeNode(arena, line_no, at_u, line_no, at_u, null) catch return) catch return;
            continue;
        }
        const doc_node = rangeNode(arena, 0, 0, last_row, last_len, null) catch return;
        var outer = doc_node;
        if (at < line.len and isIdent(line[at])) {
            var lo = at;
            while (lo > 0 and isIdent(line[lo - 1])) lo -= 1;
            var hi = at;
            while (hi < line.len and isIdent(line[hi])) hi += 1;
            const lo_u = if (negotiated_utf16) utf16Units(line[0..lo]) else lo;
            const hi_u = if (negotiated_utf16) utf16Units(line[0..hi]) else hi;
            const end_u = if (negotiated_utf16) utf16Units(line) else line.len;
            if (end_u > hi_u) outer = rangeNode(arena, line_no, lo_u, line_no, end_u, outer) catch return; // 낱말부터 줄 끝까지
            outer = rangeNode(arena, line_no, lo_u, line_no, hi_u, outer) catch return; // 낱말
        }
        out.append(outer) catch return;
    }
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = out } });
}

fn rangeNode(arena: std.mem.Allocator, l0: i64, c0: usize, l1: i64, c1: usize, parent: ?std.json.Value) !std.json.Value {
    var r: std.json.ObjectMap = .empty;
    try r.put(arena, "start", try posValue(arena, l0, c0));
    try r.put(arena, "end", try posValue(arena, l1, c1));
    var n: std.json.ObjectMap = .empty;
    try n.put(arena, "range", .{ .object = r });
    if (parent) |pnode| try n.put(arena, "parent", pnode);
    return .{ .object = n };
}

/// 협상한 단위의 `character` → 그 줄의 byte(utf-8 이면 그대로, utf-16 이면 글자를 세며 환산 — surrogate pair 는 둘).
fn byteAtUnits(line: []const u8, ch: i64) usize {
    if (!negotiated_utf16) return @intCast(@max(0, @min(ch, @as(i64, @intCast(line.len)))));
    var units: i64 = 0;
    var bi: usize = 0;
    while (bi < line.len) {
        if (units >= ch) return bi;
        const n = std.unicode.utf8ByteSequenceLength(line[bi]) catch 1;
        const cp = std.unicode.utf8Decode(line[bi..@min(bi + n, line.len)]) catch 0xFFFD;
        units += if (cp > 0xFFFF) 2 else 1;
        bi += @max(1, n);
    }
    return line.len;
}

/// `textDocument/documentSymbol`(§8.2o) — 문서의 `fn <name>(` 과 `struct <name> {` 을 심볼로 낸다. **계층**으로 내되 tsgo 꼴로 **순서를 섞고**
/// (뒤에서 앞으로) 자식 하나를 형제로 흘린다 — 클라이언트가 정렬·포함 재계산을 하는지 본다. 표식: `DSYNONE` 빈 목록 · `DSYFLAT` 평탄 꼴 ·
/// `DSYSTALL` 무응답 · `DSYERR` `-32801` · `DSYBAD` 이름이 문서와 다른 항목 하나를 섞는다.
fn handleDocumentSymbol(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
    };
    const text = docText(req_uri);
    if (std.mem.indexOf(u8, text, "DSYSTALL") != null) return;
    if (std.mem.indexOf(u8, text, "DSYERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "DSYNONE") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [0]u32{} });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    var line_no: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        const kw: []const u8 = if (std.mem.indexOf(u8, line, "struct ") != null) "struct " else if (std.mem.indexOf(u8, line, "fn ") != null) "fn " else continue;
        const at = std.mem.indexOf(u8, line, kw).? + kw.len;
        var end = at;
        while (end < line.len and isIdent(line[end])) end += 1;
        if (end == at) continue;
        const flat = std.mem.indexOf(u8, text, "DSYFLAT") != null;
        const kind: i64 = if (kw[0] == 's') 23 else 12; // struct · function
        out.append(symbolValue(arena, line, line_no, at, end, kind, flat) catch return) catch return;
    }
    if (std.mem.indexOf(u8, text, "DSYBAD") != null) {
        // 이름 범위가 **다른 글자**를 가리키는 항목(자기 검산이 버려야 한다).
        out.append(symbolValue(arena, "ghost", 0, 0, 5, 12, false) catch return) catch return;
    }
    // **뒤에서 앞으로** — 클라이언트가 정렬하는지.
    var rev: std.json.Array = .init(arena);
    var i: usize = out.items.len;
    while (i > 0) : (i -= 1) rev.append(out.items[i - 1]) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = rev } });
}

fn symbolValue(arena: std.mem.Allocator, line: []const u8, line_no: i64, name_at: usize, name_end: usize, kind: i64, flat: bool) !std.json.Value {
    const name = if (name_end <= line.len) line[name_at..name_end] else "x";
    var sel: std.json.ObjectMap = .empty;
    try sel.put(arena, "start", try posValue(arena, line_no, name_at));
    try sel.put(arena, "end", try posValue(arena, line_no, name_end));
    var full: std.json.ObjectMap = .empty;
    try full.put(arena, "start", try posValue(arena, line_no, 0));
    try full.put(arena, "end", try posValue(arena, line_no, line.len));
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "name", .{ .string = name });
    try o.put(arena, "kind", .{ .integer = kind });
    if (flat) {
        // 평탄 꼴(`SymbolInformation`) — `location` 을 들고 `selectionRange` 가 없다.
        var loc: std.json.ObjectMap = .empty;
        try loc.put(arena, "uri", .{ .string = "file:///x" });
        try loc.put(arena, "range", .{ .object = full });
        try o.put(arena, "location", .{ .object = loc });
    } else {
        try o.put(arena, "range", .{ .object = full });
        try o.put(arena, "selectionRange", .{ .object = sel });
    }
    return .{ .object = o };
}

fn posValue(arena: std.mem.Allocator, line_no: i64, ch: usize) !std.json.Value {
    var p: std.json.ObjectMap = .empty;
    try p.put(arena, "line", .{ .integer = line_no });
    try p.put(arena, "character", .{ .integer = @intCast(ch) });
    return .{ .object = p };
}

fn handleInlayHint(allocator: std.mem.Allocator, obj: std.json.ObjectMap, id: std.json.Value) void {
    var req_uri: []const u8 = "";
    var lo: i64 = 0;
    var hi: i64 = std.math.maxInt(i32);
    if (obj.get("params")) |p| if (p == .object) {
        if (p.object.get("textDocument")) |td| if (td == .object) {
            req_uri = str(td.object.get("uri")) orelse "";
        };
        if (p.object.get("range")) |r| if (r == .object) {
            if (r.object.get("start")) |st| if (st == .object) {
                lo = int(st.object.get("line")) orelse 0;
            };
            if (r.object.get("end")) |en| if (en == .object) {
                hi = int(en.object.get("line")) orelse hi;
            };
        };
    };
    const text = docText(req_uri);
    // rust-analyzer 꼴: 범위 끝 줄이 문서 줄 수를 넘으면 `-32603`(클라이언트가 끝을 마지막 줄로 clamp 해야 한다 — §8.2n).
    const nlines: i64 = @intCast(std.mem.count(u8, text, "\n") + 1);
    if (hi >= nlines) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32603), .message = "range end past document end" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "INLSTALL") != null) return;
    // `INLREFRESH` — rust-analyzer 꼴(§8.2n 실측): 첫 요청엔 `[]` 를 내고 곧 `workspace/inlayHint/refresh`(id `srv-2`) 를 보낸다. 그 뒤의 요청은
    // 클라이언트가 그 요청에 **result 로 답한 뒤에만** 진짜 힌트를 낸다(거부하거나 안 답하면 영영 `[]`).
    if (std.mem.indexOf(u8, text, "INLREFRESH") != null and !refresh_answered) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [0]u32{} });
        if (!refresh_sent) {
            refresh_sent = true;
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-2", .method = "workspace/inlayHint/refresh" });
        }
        return;
    }
    if (std.mem.indexOf(u8, text, "INLERR") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32801), .message = "content modified" } });
        return;
    }
    if (std.mem.indexOf(u8, text, "INLNULL") != null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    // **힌트는 부른 문서에만 낸다** — 표식(`_hv` 또는 줄 끝 `RET`)이 없으면 빈 목록이다. 처음엔 `(` 가 있으면 무조건 `p:` 를 냈는데,
    // 그러면 **다른 판정자**(SMT1 의 `int my_fn(int a_ty)`)의 색 열이 힌트 폭만큼 밀리고 힌트 도착이 비동기라 플레이크가 된다.
    if (std.mem.indexOf(u8, text, "_hv") == null and std.mem.indexOf(u8, text, "RET") == null) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [0]u32{} });
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.json.Array = .init(arena);
    var line_no: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < lo or line_no > hi) continue;
        // 줄 끝 `RET` → `-> void`(paddingLeft).
        if (std.mem.endsWith(u8, line, "RET")) out.append(hintValue(arena, line_no, line.len, "-> void", 1, true, false) catch return) catch return;
        // `(` 뒤 첫 인자 앞 → `p:`(paddingRight).
        if (std.mem.indexOfScalar(u8, line, '(')) |paren| if (paren + 1 < line.len and line[paren + 1] != ')') {
            out.append(hintValue(arena, line_no, paren + 1, "p:", 2, false, true) catch return) catch return;
        };
        // `<name>_hv` 뒤 → `: int`(조각 배열).
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, "_hv")) |at| {
            from = at + 3;
            if (at + 3 < line.len and isIdent(line[at + 3])) continue;
            out.append(hintValue(arena, line_no, at + 3, ": int", 1, false, false) catch return) catch return;
        }
    }
    // 뒤에서 앞으로.
    var rev: std.json.Array = .init(arena);
    var i: usize = out.items.len;
    while (i > 0) : (i -= 1) rev.append(out.items[i - 1]) catch return;
    sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = rev } });
}

fn hintValue(arena: std.mem.Allocator, line_no: i64, character: usize, label: []const u8, kind: i64, pad_l: bool, pad_r: bool) !std.json.Value {
    var pos: std.json.ObjectMap = .empty;
    try pos.put(arena, "line", .{ .integer = line_no });
    try pos.put(arena, "character", .{ .integer = @intCast(character) });
    var h: std.json.ObjectMap = .empty;
    try h.put(arena, "position", .{ .object = pos });
    if (kind == 1) {
        // 타입 힌트는 조각 배열로(rust-analyzer 꼴) — 첫 조각 `: `, 둘째 나머지.
        var parts: std.json.Array = .init(arena);
        var a: std.json.ObjectMap = .empty;
        try a.put(arena, "value", .{ .string = label[0..@min(2, label.len)] });
        try parts.append(.{ .object = a });
        if (label.len > 2) {
            var b: std.json.ObjectMap = .empty;
            try b.put(arena, "value", .{ .string = label[2..] });
            try parts.append(.{ .object = b });
        }
        try h.put(arena, "label", .{ .array = parts });
    } else {
        try h.put(arena, "label", .{ .string = label });
    }
    try h.put(arena, "kind", .{ .integer = kind });
    if (pad_l) try h.put(arena, "paddingLeft", .{ .bool = true });
    if (pad_r) try h.put(arena, "paddingRight", .{ .bool = true });
    return .{ .object = h };
}

fn wordLocations(arena: std.mem.Allocator, text: []const u8, word: []const u8, uri: []const u8) !std.json.Array {
    var locs: std.json.Array = .init(arena);
    var line_no: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, word)) |at| {
            from = at + word.len;
            const left_ok = at == 0 or !isIdent(line[at - 1]);
            const right_ok = at + word.len >= line.len or !isIdent(line[at + word.len]);
            if (!left_ok or !right_ok) continue;
            try locs.append(try locationValue(arena, uri, line_no, at, at + word.len));
        }
    }
    return locs;
}

fn locationValue(arena: std.mem.Allocator, uri: []const u8, line_no: i64, start: usize, end: usize) !std.json.Value {
    var s: std.json.ObjectMap = .empty;
    try s.put(arena, "line", .{ .integer = line_no });
    try s.put(arena, "character", .{ .integer = @intCast(start) });
    var e: std.json.ObjectMap = .empty;
    try e.put(arena, "line", .{ .integer = line_no });
    try e.put(arena, "character", .{ .integer = @intCast(end) });
    var range: std.json.ObjectMap = .empty;
    try range.put(arena, "start", .{ .object = s });
    try range.put(arena, "end", .{ .object = e });
    var loc: std.json.ObjectMap = .empty;
    try loc.put(arena, "uri", .{ .string = uri });
    try loc.put(arena, "range", .{ .object = range });
    return .{ .object = loc };
}

fn renameEdits(arena: std.mem.Allocator, text: []const u8, word: []const u8, new_name: []const u8, bad: bool) !std.json.Array {
    var edits: std.json.Array = .init(arena);
    var line_no: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, word)) |at| {
            from = at + word.len;
            const left_ok = at == 0 or !isIdent(line[at - 1]);
            const right_ok = at + word.len >= line.len or !isIdent(line[at + word.len]);
            if (!left_ok or !right_ok) continue;
            try edits.append(try editValue(arena, line_no, at, at + word.len, new_name));
            if (bad and edits.items.len == 1) try edits.append(try editValue(arena, line_no, at + 1, at + word.len + 1, new_name));
        }
    }
    return edits;
}

fn editValue(arena: std.mem.Allocator, line_no: i64, start: usize, end: usize, new_text: []const u8) !std.json.Value {
    var s: std.json.ObjectMap = .empty;
    try s.put(arena, "line", .{ .integer = line_no });
    try s.put(arena, "character", .{ .integer = @intCast(start) });
    var e: std.json.ObjectMap = .empty;
    try e.put(arena, "line", .{ .integer = line_no });
    try e.put(arena, "character", .{ .integer = @intCast(end) });
    var range: std.json.ObjectMap = .empty;
    try range.put(arena, "start", .{ .object = s });
    try range.put(arena, "end", .{ .object = e });
    var edit: std.json.ObjectMap = .empty;
    try edit.put(arena, "range", .{ .object = range });
    try edit.put(arena, "newText", .{ .string = new_text });
    return .{ .object = edit };
}

fn addFileEdits(arena: std.mem.Allocator, changes: *std.json.ObjectMap, doc_changes: *std.json.Array, use_doc_changes: bool, uri: []const u8, version: i64, edits: std.json.Array) !void {
    const uri_copy = try arena.dupe(u8, uri);
    if (use_doc_changes) {
        var td: std.json.ObjectMap = .empty;
        try td.put(arena, "uri", .{ .string = uri_copy });
        try td.put(arena, "version", if (version == 0) .null else .{ .integer = version });
        var tde: std.json.ObjectMap = .empty;
        try tde.put(arena, "textDocument", .{ .object = td });
        try tde.put(arena, "edits", .{ .array = edits });
        try doc_changes.append(.{ .object = tde });
    } else {
        try changes.put(arena, uri_copy, .{ .array = edits });
    }
}

fn lineBefore(text: []const u8, line_no: i64, character: i64) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: i64 = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == line_no) {
            const c: usize = @intCast(@max(character, 0));
            return line[0..@min(c, line.len)];
        }
    }
    return "";
}

fn docMode(uri: []const u8) DefMode {
    for (&doc_modes) |*d| if (d.len == uri.len and std.mem.eql(u8, d.uri[0..d.len], uri)) return d.mode;
    return .same;
}

fn handle(allocator: std.mem.Allocator, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const id = obj.get("id");
    const method = str(obj.get("method")) orelse {
        // 응답 — 우리가 낸 `srv-1` 에 대한 것이면(거부여도) 「답을 받았다」.
        if (str(id)) |i| {
            if (std.mem.eql(u8, i, "srv-1")) answered = true;
            if (std.mem.eql(u8, i, "srv-c")) {
                // 설정 객체여야 한다 — 배열의 첫 항목에 `validate: "on"`. 그 뒤 기다리던 pull 에 답한다(거부·`null` 이면 실서버처럼 오류).
                if (obj.get("result")) |r| if (r == .array and r.array.items.len == 2 and r.array.items[0] == .object) {
                    const o = r.array.items[0].object;
                    // 실서버는 `workingDirectory`·`experimental` 객체를 읽는다 — 없으면 진단 요청이 실패한다(4.10 실측).
                    const wd_ok = if (o.get("workingDirectory")) |w| w == .object else false;
                    const exp_ok = if (o.get("experimental")) |e| e == .object else false;
                    eslint_config_ok = std.mem.eql(u8, str(o.get("validate")) orelse "", "on") and wd_ok and exp_ok;
                };
                if (eslint_pending_id_len > 0) {
                    var idp = std.json.parseFromSlice(std.json.Value, allocator, eslint_pending_id[0..eslint_pending_id_len], .{}) catch return;
                    defer idp.deinit();
                    eslint_pending_id_len = 0;
                    answerPull(allocator, idp.value, eslint_pending_uri[0..eslint_pending_uri_len]);
                }
            }
            if (std.mem.eql(u8, i, "srv-2") and obj.get("error") == null) refresh_answered = true;
        }
        return;
    };
    // ruby-lsp 꼴(LS4) — 작업 스레드는 받은 순서대로다: pull 이 아닌 요청을 처리하는 때면 그 앞의 didChange 는 적용됐다.
    if (worker_lag_mode and id != null and !std.mem.eql(u8, method, "textDocument/diagnostic")) catchUp();
    if (std.mem.eql(u8, method, "initialize")) {
        if (std.c.getenv("MARU_FAKE_LSP_INIT")) |m| {
            const mode = std.mem.span(m);
            if (std.mem.eql(u8, mode, "silent")) return; // 답하지 않는다 — 클라이언트의 initialize 시한
            if (std.mem.eql(u8, mode, "error")) { // 거절한다 — 클라이언트는 「실패」로 서야 한다
                sendJson(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32603), .message = "fake: refuse initialize" } });
                return;
            }
        }
        defer if (std.c.getenv("MARU_FAKE_LSP_STOPREAD") != null) {
            stop_reading = true;
        };
        var inlay_caps: std.json.ObjectMap = .empty;
        inlay_caps.put(allocator, "resolveProvider", .{ .bool = true }) catch return;
        defer inlay_caps.deinit(allocator);
        var typedef_caps: std.json.ObjectMap = .empty;
        typedef_caps.put(allocator, "workDoneProgress", .{ .bool = false }) catch return;
        defer typedef_caps.deinit(allocator);
        var sync_caps: std.json.ObjectMap = .empty;
        var save_opts: std.json.ObjectMap = .empty;
        save_opts.put(allocator, "includeText", .{ .bool = true }) catch return;
        sync_caps.put(allocator, "openClose", .{ .bool = true }) catch return;
        sync_caps.put(allocator, "change", .{ .integer = 1 }) catch return;
        sync_caps.put(allocator, "save", .{ .object = save_opts }) catch return;
        defer sync_caps.deinit(allocator);
        defer save_opts.deinit(allocator);
        var utf8 = false;
        if (obj.get("params")) |p| if (p == .object) if (p.object.get("capabilities")) |c| if (c == .object) if (c.object.get("general")) |g| if (g == .object) if (g.object.get("positionEncodings")) |pe| if (pe == .array) {
            for (pe.array.items) |e| if (e == .string and std.mem.eql(u8, e.string, "utf-8")) {
                utf8 = true;
            };
        };
        // ESLint 꼴은 클라이언트가 pull 능력(`textDocument.diagnostic`)을 알렸을 때만 `diagnosticProvider` 를 낸다(그렇게 하는 서버가 흔하다 —
        // 클라이언트가 고른 클라이언트에만 능력을 알리는지 잰다). `MARU_FAKE_LSP_NOPULLCAP=1` 이면 알려도 내지 않는다(provider 없는 서버).
        var client_pull = false;
        if (obj.get("params")) |p| if (p == .object) if (p.object.get("capabilities")) |c| if (c == .object) if (c.object.get("textDocument")) |td| if (td == .object) {
            client_pull = td.object.get("diagnostic") != null;
        };
        client_announced_pull = client_pull;
        const offer_pull = (eslint_mode or pull_primary_mode) and client_pull and std.c.getenv("MARU_FAKE_LSP_NOPULLCAP") == null;
        // `MARU_FAKE_LSP_UTF16=1` 이면 제안과 무관하게 utf-16 을 고른다 — 클라이언트의 byte ↔ character 변환을 제품 경계에서 재는 데 쓴다.
        const force_utf16 = std.c.getenv("MARU_FAKE_LSP_UTF16") != null;
        negotiated_utf16 = !(utf8 and !force_utf16); // 협상 결과를 기억한다 — 자리를 읽고 내는 처리기가 같은 단위를 쓴다
        // `serverInfo`(LSP 3.15 선택 필드) — 클라이언트가 이름·버전을 보이는지 잰다(계획 workspace-trust WT5a). `MARU_FAKE_LSP_NOSERVERINFO=1`
        // 이면 싣지 않는다(없는 서버).
        const ServerInfo = struct { name: []const u8, version: ?[]const u8 };
        const server_info: ?ServerInfo = if (std.c.getenv("MARU_FAKE_LSP_NOSERVERINFO") != null) null else .{
            .name = if (std.c.getenv("MARU_FAKE_LSP_SERVERINFO_NAME")) |v| std.mem.span(v) else "maru-fake-lsp",
            .version = if (std.c.getenv("MARU_FAKE_LSP_SERVERINFO_VERSION")) |v| (if (v[0] == 0) null else std.mem.span(v)) else "9.8.7",
        };
        sendJson(allocator, .{
            .jsonrpc = "2.0",
            .id = id.?,
            .result = .{
                .serverInfo = server_info,
                .capabilities = .{
                    .positionEncoding = if (utf8 and !force_utf16) "utf-8" else "utf-16",
                    // 저장 통지(§8.2k) — 객체 꼴로 `save{includeText: true}`(본문을 실어 오게 — 가짜가 didChange 본문과 대조한다).
                    // `MARU_FAKE_LSP_NOSAVECAP=1` 이면 옛 숫자 꼴(Full=1) — save 선언 없음.
                    .textDocumentSync = if (std.c.getenv("MARU_FAKE_LSP_NOSAVECAP") == null) std.json.Value{ .object = sync_caps } else std.json.Value{ .integer = 1 },
                    .signatureHelpProvider = .{ .triggerCharacters = [_][]const u8{ "(", "," }, .retriggerCharacters = [_][]const u8{")"} },
                    .documentFormattingProvider = std.c.getenv("MARU_FAKE_LSP_NOFMTCAP") == null, // `MARU_FAKE_LSP_NOFMTCAP=1` 이면 false
                    .renameProvider = std.c.getenv("MARU_FAKE_LSP_NORENAMECAP") == null, // `MARU_FAKE_LSP_NORENAMECAP=1` 이면 false
                    .completionProvider = if (std.c.getenv("MARU_FAKE_LSP_NOCOMPCAP") == null) .{ .triggerCharacters = [_][]const u8{"."}, .resolveProvider = true } else null,
                    // 내는 kind 를 실서버처럼 알린다 — 클라이언트는 알린 kind 만 저장 시 묻는다(tooling §8.2u). 보조 역할은 ruff 꼴.
                    .codeActionProvider = if (std.c.getenv("MARU_FAKE_LSP_NOACTCAP") == null) .{ .codeActionKinds = if (eslint_mode) eslint_action_kinds[0..] else if (biome_mode) biome_action_kinds[0..] else if (oxlint_mode) oxlint_action_kinds[0..] else if (auxiliary) aux_action_kinds[0..] else primary_action_kinds[0..], .resolveProvider = true } else null,
                    // pull 진단(ESLint 꼴 — §8.2u). 다른 역할은 없다(push).
                    .diagnosticProvider = if (offer_pull) @as(?struct { identifier: []const u8, interFileDependencies: bool, workspaceDiagnostics: bool }, .{ .identifier = if (pull_primary_mode) "primary" else "eslint", .interFileDependencies = inter_file_mode, .workspaceDiagnostics = false }) else null,
                    // semantic tokens(§8.2i) — legend 다섯(하나는 클라이언트가 모르는 이름·`variable` 은 무색). `MARU_FAKE_LSP_SEMFULL=1` 이면 range 없이
                    // full 만(clangd 꼴), `MARU_FAKE_LSP_NOSEMCAP=1` 이면 provider 없음.
                    // 접힘 3층(§8.2j) — `MARU_FAKE_LSP_NOFOLDCAP=1` 이면 provider 없음.
                    .foldingRangeProvider = std.c.getenv("MARU_FAKE_LSP_NOFOLDCAP") == null,
                    .referencesProvider = true, // §8.2l
                    .documentSymbolProvider = std.c.getenv("MARU_FAKE_LSP_NOSYMCAP") == null, // 심볼 2층(§8.2o)
                    .documentHighlightProvider = std.c.getenv("MARU_FAKE_LSP_NOHLCAP") == null, // 같은 낱말 강조(§8.2p)
                    .selectionRangeProvider = std.c.getenv("MARU_FAKE_LSP_NOSRCAP") == null, // 구조 기반 선택 확장(§8.2q)
                    .inlayHintProvider = if (std.c.getenv("MARU_FAKE_LSP_NOINLAYCAP") == null) std.json.Value{ .object = inlay_caps } else std.json.Value{ .bool = false }, // §8.2n — 객체 꼴; `NOINLAYCAP=1` 이면 없음
                    .implementationProvider = true, // §8.2m
                    .typeDefinitionProvider = if (std.c.getenv("MARU_FAKE_LSP_NOTYPEDEFCAP") == null) std.json.Value{ .object = typedef_caps } else std.json.Value{ .bool = false }, // 객체 꼴; `NOTYPEDEFCAP=1` 이면 false
                    .declarationProvider = std.c.getenv("MARU_FAKE_LSP_DECLCAP") != null, // 기본 없음(tsgo 꼴)
                    .semanticTokensProvider = if (std.c.getenv("MARU_FAKE_LSP_NOSEMCAP") == null) .{
                        .legend = .{ .tokenTypes = [_][]const u8{ "keyword", "function", "variable", "type", "bogusKind" }, .tokenModifiers = [_][]const u8{"declaration"} },
                        .range = std.c.getenv("MARU_FAKE_LSP_SEMFULL") == null,
                        .full = true,
                    } else null,
                },
            },
        });
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        // tsgo 꼴(§8.2a 되먹임 ⑦): `params` 가 객체가 아니면(`[]` 로 온 적이 있다) `initialized` 를 **거부**하고 그 뒤 모든 요청에
        // `-32002 ServerNotInitialized`, 통지는 버린다 — 클라이언트가 `{}` 를 안 내면 판정자 전부가 빨개진다.
        const params_ok = if (obj.get("params")) |pv| pv == .object else false;
        if (!params_ok) {
            not_initialized = true;
            return;
        }
        if (eslint_mode) return; // ESLint 꼴은 첫 pull 때 설정을 묻는다(실서버와 같다)
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-1", .method = "workspace/configuration", .params = .{ .items = [_]struct { section: []const u8 }{.{ .section = "fake" }} } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
        if (pull_primary_mode) answerPrimaryPull(allocator, obj, id orelse .null) else handlePullDiagnostics(allocator, obj, id orelse .null);
        return;
    }
    if (not_initialized) {
        if (id) |i| sendJson(allocator, .{ .jsonrpc = "2.0", .id = i, .@"error" = .{ .code = @as(i32, -32002), .message = "ServerNotInitialized" } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
        // 요청 줄의 본문(마지막 didOpen/didChange 에서 기억)에서 caret 앞을 본다: 마지막 `(` 뒤의 `,` 수가 활성 파라미터, 그 `(` 가 없거나
        // 그 뒤에 `)` 가 왔으면 `null`(닫힌다). `NOSIG` 가 있으면 늘 `null`.
        var req_uri: []const u8 = "";
        var line_no: i64 = 0;
        var character: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("position")) |pos| if (pos == .object) {
                line_no = int(pos.object.get("line")) orelse 0;
                character = int(pos.object.get("character")) orelse 0;
            };
        };
        const text = docText(req_uri);
        const before = lineBefore(text, line_no, character);
        const open_at = std.mem.lastIndexOfScalar(u8, before, '(');
        const closed = if (open_at) |o| std.mem.indexOfScalarPos(u8, before, o, ')') != null else true;
        if (open_at == null or closed or std.mem.indexOf(u8, text, "NOSIG") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        const active_param: u32 = @intCast(std.mem.count(u8, before[open_at.?..], ","));
        const Param = struct { label: []const u8, documentation: ?[]const u8 = null };
        const ParamOff = struct { label: [2]u32, documentation: ?[]const u8 = null };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{
            .signatures = .{
                .{ .label = "int add(int a, int b)", .documentation = "**adds** two", .parameters = [_]ParamOff{ .{ .label = .{ 8, 13 }, .documentation = "first" }, .{ .label = .{ 15, 20 } } } },
                .{ .label = "int add(double a)", .parameters = [_]Param{.{ .label = "double a" }} },
            },
            .activeSignature = @as(u32, 0),
            .activeParameter = active_param,
        } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        var req_uri: []const u8 = "";
        var options_ok = false;
        var opt_spaces = false;
        var opt_size: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("options")) |o| if (o == .object) {
                const insert_spaces = o.object.get("insertSpaces");
                opt_size = int(o.object.get("tabSize")) orelse 0;
                options_ok = insert_spaces != null and insert_spaces.? == .bool and opt_size >= 1;
                if (options_ok) opt_spaces = insert_spaces.?.bool;
            };
        };
        const text = docText(req_uri);
        const Pos = struct { line: u32, character: u32 };
        if (!options_ok) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        const Edit = struct { range: struct { start: Pos, end: Pos }, newText: []const u8 };
        // 저장 시 포맷의 시한(§8.2r) — `FMTSTALL` 이면 답하지 않는다(`…HANG` 이라 부르면 didChange 의 `HANG` 표식에 걸려 서버째 멈춘다).
        if (std.mem.indexOf(u8, text, "FMTSTALL") != null) return;
        if (std.mem.indexOf(u8, text, "FMTOPTS")) |at| {
            const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
            const line_no: u32 = @intCast(std.mem.count(u8, text[0..at], "\n"));
            const col: u32 = @intCast(at - line_start);
            var buf: [64]u8 = undefined;
            const opts = std.fmt.bufPrint(&buf, "OPTS spaces={} size={d}", .{ opt_spaces, opt_size }) catch return;
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = [_]Edit{.{ .range = .{ .start = .{ .line = line_no, .character = col }, .end = .{ .line = line_no, .character = col + 7 } }, .newText = opts }} });
            return;
        }
        if (std.mem.indexOf(u8, text, "NOFMT") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        if (std.mem.indexOf(u8, text, "BADFMT") != null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = [_]Edit{
                .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 2 } }, .newText = "x" },
                .{ .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } }, .newText = "y" },
            } });
            return;
        }
        var edits: std.ArrayList(Edit) = .empty;
        defer edits.deinit(allocator);
        var line_no: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (line_no += 1) {
            const at = std.mem.indexOf(u8, line, "  ") orelse continue;
            var end = at;
            while (end < line.len and line[end] == ' ') end += 1;
            edits.append(allocator, .{ .range = .{ .start = .{ .line = line_no, .character = @intCast(at) }, .end = .{ .line = line_no, .character = @intCast(end) } }, .newText = " " }) catch return;
        }
        std.mem.reverse(Edit, edits.items); // 역순 — 정렬은 클라이언트의 몫이다
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = edits.items });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/rename")) {
        handleRename(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        handleCompletion(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "completionItem/resolve")) {
        // `lazy_import`(data 만) → additionalTextEdits(첫 줄 `#include "lazy.h"`) + detail 을 채워 돌려준다. 문서에 `RESOLVESTALL` 이면 답하지 않는다(`…HANG` 이라 부르면 didChange 의 `HANG` 표식에 걸려 서버째 멈춘다).
        var uri: []const u8 = "";
        var label: []const u8 = "";
        if (obj.get("params")) |p| if (p == .object) {
            label = str(p.object.get("label")) orelse "";
            if (p.object.get("data")) |d| if (d == .object) {
                uri = str(d.object.get("uri")) orelse "";
            };
        };
        if (std.mem.indexOf(u8, docText(uri), "RESOLVESTALL") != null) return;
        if (!std.mem.eql(u8, label, "lazy_import")) {
            // 다른 항목은 그대로 돌려준다(풀 것이 없다).
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = obj.get("params").? });
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var it: std.json.ObjectMap = .empty;
        it.put(arena, "label", .{ .string = "lazy_import" }) catch return;
        it.put(arena, "detail", .{ .string = "resolved" }) catch return;
        // documentation(§8.2g-d) — 마크다운: 굵게·펜스·목록(줄이 12 를 넘어 패널이 굴러가는 관측점).
        var doc: std.json.ObjectMap = .empty;
        doc.put(arena, "kind", .{ .string = "markdown" }) catch return;
        doc.put(arena, "value", .{ .string = "Lazy **import**.\n\n```c\n#include \"lazy.h\"\n```\n\n- one\n- two\n- three\n- four\n- five\n- six\n- seven\n- eight\n- nine\n- ten\n- eleven\n- twelve" }) catch return;
        it.put(arena, "documentation", .{ .object = doc }) catch return;
        var adds: std.json.Array = .init(arena);
        adds.append(editValue(arena, 0, 0, 0, "#include \"lazy.h\"\n") catch return) catch return;
        it.put(arena, "additionalTextEdits", .{ .array = adds }) catch return;
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = std.json.Value{ .object = it } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        handleCodeAction(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "codeAction/resolve")) {
        handleCodeActionResolve(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
        handleFoldingRange(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/range") or std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        handleSemanticTokens(allocator, obj, id.?, std.mem.eql(u8, method, "textDocument/semanticTokens/full"));
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        var line: i64 = 0;
        var character: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) if (p.object.get("position")) |pos| if (pos == .object) {
            line = int(pos.object.get("line")) orelse 0;
            character = int(pos.object.get("character")) orelse 0;
        };
        if (mute_hover) return; // 답하지 않는다 — 클라이언트가 시간 초과로 진단만 열어야 한다(§8.2b 「요청」)
        if (no_hover) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(allocator);
        md.print(allocator, "```c\nint fake\n```\nfake hover L{d}:C{d}\n**bold** here\n", .{ line, character }) catch return;
        for (1..15) |n| md.print(allocator, "- item {d}\n", .{n}) catch return;
        const Pos = struct { line: i64, character: i64 };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = .{
            .contents = .{ .kind = "markdown", .value = md.items },
            .range = .{ .start = Pos{ .line = line, .character = character }, .end = Pos{ .line = line, .character = character + 3 } },
        } });
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/references")) {
        handleReferences(allocator, obj, id.?);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
        handleDocumentHighlight(allocator, obj, id orelse .null);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/selectionRange")) {
        handleSelectionRange(allocator, obj, id orelse .null);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        handleDocumentSymbol(allocator, obj, id orelse .null);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        handleInlayHint(allocator, obj, id.?);
        return;
    }
    // 구현·타입 정의(§8.2m): 요청 자리 낱말의 위치를 **뒤에서 둘째까지**(구현 — 선언을 뺀 나머지) / **첫 것 하나**(타입 정의) `LocationLink[]` 로.
    // `declaration` 은 `MARU_FAKE_LSP_DECLCAP=1` 일 때만 provider 를 내고 처리한다(tsgo 꼴 — 없는데 물으면 `-32600`).
    if (std.mem.eql(u8, method, "textDocument/implementation") or std.mem.eql(u8, method, "textDocument/typeDefinition") or std.mem.eql(u8, method, "textDocument/declaration")) {
        if (std.mem.eql(u8, method, "textDocument/declaration") and std.c.getenv("MARU_FAKE_LSP_DECLCAP") == null) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .@"error" = .{ .code = @as(i32, -32600), .message = "InvalidRequest" } });
            return;
        }
        handleLocationKind(allocator, obj, id.?, if (std.mem.eql(u8, method, "textDocument/implementation")) .tail_all else .first_one);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        var req_uri: []const u8 = "";
        var req_char: i64 = 0;
        if (obj.get("params")) |p| if (p == .object) {
            if (p.object.get("textDocument")) |td| if (td == .object) {
                req_uri = str(td.object.get("uri")) orelse "";
            };
            if (p.object.get("position")) |pos| if (pos == .object) {
                req_char = int(pos.object.get("character")) orelse 0;
            };
        };
        const def_mode = docMode(req_uri);
        const Pos = struct { line: i64, character: i64 };
        const Range = struct { start: Pos, end: Pos };
        if (def_mode == .none) {
            sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
            return;
        }
        var uri_buf: [4096]u8 = undefined;
        const uri: []const u8 = switch (def_mode) {
            .same => req_uri,
            .other => blk: {
                // 같은 디렉터리의 `other.c` — 요청 uri 의 마지막 조각을 바꾼다.
                const slash = std.mem.lastIndexOfScalar(u8, req_uri, '/') orelse break :blk req_uri;
                break :blk std.fmt.bufPrint(&uri_buf, "{s}/other.c", .{req_uri[0..slash]}) catch req_uri;
            },
            .outside => "file:///nonexistent-outside-root/x.c",
            .none => unreachable,
        };
        // `Location[]` 로 낸다(가장 흔한 모양) — 둘째 항목은 버려져야 한다.
        const Loc = struct { uri: []const u8, range: Range };
        const locs = [_]Loc{
            // 첫 항목의 character 는 **요청한 자리**를 되돌린다 — 어디서 요청했는지가 답에 남아야 caret 자리로 요청한 변이(B5)가 갈린다.
            .{ .uri = uri, .range = .{ .start = .{ .line = 1, .character = req_char }, .end = .{ .line = 1, .character = req_char + 1 } } },
            .{ .uri = uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } } },
        };
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = locs });
        return;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        sendJson(allocator, .{ .jsonrpc = "2.0", .id = id.?, .result = null });
        return;
    }
    if (std.mem.eql(u8, method, "exit")) std.c._exit(0);
    if (std.mem.eql(u8, method, "textDocument/didOpen") or std.mem.eql(u8, method, "textDocument/didChange")) {
        const params = obj.get("params") orelse return;
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri = str(td.object.get("uri")) orelse return;
        const version = int(td.object.get("version")) orelse 0;
        const text: []const u8 = blk: {
            if (str(td.object.get("text"))) |t| break :blk t;
            if (params.object.get("contentChanges")) |cc| if (cc == .array) break :blk applyChanges(uri, cc.array.items);
            break :blk "";
        };
        no_hover = std.mem.indexOf(u8, text, "NOHOVER") != null;
        mute_hover = std.mem.indexOf(u8, text, "MUTEHOVER") != null;
        setDocText(uri, text, version);
        if (worker_lag_mode) if (docSlot(uri)) |sl| {
            sl.cached_pull = -1; // 편집이 캐시를 비운다(실서버 `push_edits`)
            if (std.mem.eql(u8, method, "textDocument/didOpen")) sl.seen_version = version; // 연 본문은 곧 파싱돼 있다
        };
        if (str(td.object.get("languageId"))) |lang| setDocLang(uri, lang);
        setDocMode(uri, if (std.mem.indexOf(u8, text, "NODEF") != null) .none else if (std.mem.indexOf(u8, text, "XFILE") != null) .other else if (std.mem.indexOf(u8, text, "OUTSIDE") != null) .outside else .same);
        if (std.mem.indexOf(u8, text, "BOOM") != null) std.c._exit(1);
        if (std.mem.indexOf(u8, text, "HANG") != null) {
            _ = std.c.close(1);
            while (true) _ = usleep(100_000);
        }
        const v = if (std.mem.indexOf(u8, text, "STALE") != null) version - 1 else version;
        var msg_buf: [64]u8 = undefined;
        const Diag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8 };
        if (pull_primary_mode) return; // tsgo 꼴도 파일 진단은 push 하지 않는다 — 주 서버의 pull 로만(LS2)
        if (eslint_mode) {
            // ESLint 꼴은 push 하지 않는다 — 클라이언트가 pull 로 물어야 한다. `ESLREFRESH` 면 다시 물어 달라고 한다(`workspace/diagnostic/refresh`).
            if (std.mem.indexOf(u8, text, "ESLREFRESH") != null and std.mem.eql(u8, method, "textDocument/didChange"))
                sendJson(allocator, .{ .jsonrpc = "2.0", .id = "srv-r", .method = "workspace/diagnostic/refresh", .params = null });
            return;
        }
        if (auxiliary) {
            // 보조 서버(tooling §8.2u) — 둘째 줄 0..2 에 warning 하나(주 서버의 첫 줄 error 와 자리가 다르다). `AUXQUIET` 이면 빈 목록.
            if (std.mem.indexOf(u8, text, "AUXSPOOF") != null and std.mem.eql(u8, method, "textDocument/didChange"))
                sendJson(allocator, .{ .jsonrpc = "2.0", .id = @as(i64, 100_000_001), .result = .{ .contents = .{ .kind = "markdown", .value = "aux: spoofed hover" } } });
            const pp = persona().?;
            // Biome 꼴은 didOpen 의 languageId 도 붙인다 — JSON·CSS 에 그 문법의 값이 갔는지(AS5).
            const aux_msg = (if (biome_mode) std.fmt.bufPrint(&msg_buf, "{s}: {d} {s}", .{ pp.prefix, version, docLang(uri) }) else std.fmt.bufPrint(&msg_buf, "{s}: {d}", .{ pp.prefix, version })) catch "aux";
            // `data`(LSP 3.16)를 싣는다 — 클라이언트가 code action 문맥으로 그대로 되돌려야 quickfix 제목에 `(data aux-1)` 이 붙는다.
            const AuxDiag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8, source: []const u8, data: struct { fix: []const u8 } };
            const one = [_]AuxDiag{.{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 2 } }, .severity = 2, .message = aux_msg, .code = "A1", .source = pp.source, .data = .{ .fix = "aux-1" } }};
            const quiet = std.mem.indexOf(u8, text, "AUXQUIET") != null;
            sendJson(allocator, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = v, .diagnostics = if (quiet) one[0..0] else one[0..] } });
            return;
        }
        const sync_slot = docSlot(uri);
        const msg = (if (std.mem.indexOf(u8, text, "SYNCSUM") != null)
            std.fmt.bufPrint(&msg_buf, "fake: {d} sum={x:0>8} rl={d} rj={d}", .{ version, std.hash.Fnv1a_32.hash(text), if (sync_slot) |sl| sl.rangeless else 0, if (sync_slot) |sl| sl.rejects else 0 })
        else if (std.mem.indexOf(u8, text, "PULLCAP") != null)
            std.fmt.bufPrint(&msg_buf, "fake: {d} pull={}", .{ version, client_announced_pull })
        else if (std.mem.indexOf(u8, text, "LANGID") != null) std.fmt.bufPrint(&msg_buf, "fake: {d} {s}", .{ version, docLang(uri) }) else std.fmt.bufPrint(&msg_buf, "fake: {d}", .{version})) catch "fake";
        var diags: [3]Diag = undefined;
        var count: usize = 1;
        diags[0] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .severity = 1, .message = msg, .code = "E1" };
        if (std.mem.indexOf(u8, text, "WARN") != null) {
            diags[count] = .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 2 } }, .severity = 2, .message = if (answered) "fake: warn" else "fake: warn noack", .code = "W1" };
            count += 1;
        }
        // `INFO` — 첫 줄 0..1 에 info 하나 더(error 와 같은 자리에서 시작 — 호버가 severity 순으로 내고 message 첫 줄만 쓰는지, 그리고
        // 반열림 끝(1)이 덮지 않는지 재는 데 쓴다). message 는 두 줄이다.
        if (std.mem.indexOf(u8, text, "INFO") != null) {
            diags[count] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .severity = 3, .message = "fake: info\nnote: more", .code = "I1" };
            count += 1;
        }
        sendJson(allocator, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = v, .diagnostics = diags[0..count] } });
        return;
    }
    // 저장 통지(§8.2k): 실린 `text` 를 마지막 didOpen/didChange 본문과 대조해 진단 하나로 답한다 — 같으면 `fake: saved <bytes>`(info, 줄 0),
    // 다르면 `fake: save desync`(error) — 클라이언트가 밀린 didChange 를 먼저 보냈는지가 여기서 드러난다. `text` 가 없으면 `fake: save notext`.
    if (std.mem.eql(u8, method, "textDocument/didSave")) {
        const params = obj.get("params") orelse return;
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri = str(td.object.get("uri")) orelse return;
        const Diag = struct { range: struct { start: struct { line: u32, character: u32 }, end: struct { line: u32, character: u32 } }, severity: u8, message: []const u8, code: []const u8 };
        var msg_buf: [64]u8 = undefined;
        const text = str(params.object.get("text"));
        const msg: []const u8 = if (text == null) "fake: save notext" else if (!std.mem.eql(u8, text.?, docText(uri))) "fake: save desync" else std.fmt.bufPrint(&msg_buf, "fake: saved {d}", .{text.?.len}) catch "fake: saved";
        const sev: u8 = if (text != null and std.mem.eql(u8, text.?, docText(uri))) 3 else 1;
        const diags = [_]Diag{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .severity = sev, .message = msg, .code = "S1" }};
        sendJson(allocator, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = docVersion(uri), .diagnostics = diags[0..] } });
        return;
    }
    // 모르는 요청은 MethodNotFound 로.
    if (id) |i| sendJson(allocator, .{ .jsonrpc = "2.0", .id = i, .@"error" = .{ .code = @as(i32, -32601), .message = "fake: not supported" } });
}
