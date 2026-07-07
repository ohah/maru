//! 에이전트(claude/codex) 세션 resume용 순수 argv 로직 — workspace restore가 종료 시점에 캡처한 argv를 저장
//! 가능하게 redact하고(redactArgv), 복원 시점에 정확한 session id로 resume 명령을 재구성한다(rebuildAgentArgv).
//! macOS 무관 순수 함수(Linux CI에서도 테스트). 정책 단일 출처: docs/workspace-restore.md "에이전트 세션 자동
//! resume", redaction 토큰은 docs/project-rules.md "민감정보 redaction 기준".

const std = @import("std");
const redact = @import("../redact.zig"); // 민감정보 redaction 단일 출처(중립 leaf) — 토큰 목록·key 판정을 공유

pub const Kind = enum {
    claude,
    codex,

    /// agent_kind 문자열("claude"/"codex"/그 외)을 Kind로. 인식 못 하면 null(일반 셸 복원).
    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        return null;
    }

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
        };
    }
};

// ── redaction (저장 전) ──────────────────────────────────────────────────────────────

/// redaction 대상 key 토큰 — 단일 출처는 중립 leaf `src/redact.zig`(docs/project-rules.md 미러). 여기선 재노출만 해
/// 기존 소비처(app_session 등)의 `agent_resume.sensitive_tokens` 경로를 유지한다(목록은 한 곳에만 존재).
pub const sensitive_tokens = redact.sensitive_tokens;

/// key 이름에 민감 토큰이 있으면 true(redact.keyIsSensitive 위임 — 단일 출처).
fn isSensitiveKey(key: []const u8) bool {
    return redact.keyIsSensitive(key);
}

/// 선두 '-'/'--'를 제거한 key를 돌려준다(0.16엔 mem.trimLeft 없음).
fn stripDashes(s: []const u8) []const u8 {
    var key = s;
    while (key.len > 0 and key[0] == '-') key = key[1..];
    return key;
}

/// `--key=value`/`-key=value` 형태에서 key에 민감 토큰이 있으면 true(인라인 비밀 — 토큰 드롭).
fn isInlineSecret(tok: []const u8) bool {
    if (!std.mem.startsWith(u8, tok, "-")) return false;
    const eq_pos = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    return isSensitiveKey(stripDashes(tok[0..eq_pos]));
}

/// `--key`(값 없는 플래그 형태)에서 key가 민감 토큰이면 true — 다음 토큰이 공백분리 값일 수 있어 함께 드롭한다.
fn isSecretFlag(tok: []const u8) bool {
    if (!std.mem.startsWith(u8, tok, "-")) return false;
    if (std.mem.indexOfScalar(u8, tok, '=') != null) return false; // 인라인 형태는 isInlineSecret이 처리
    return isSensitiveKey(stripDashes(tok));
}

/// 캡처한 argv에서 **민감 토큰을 드롭**해 저장 가능한 argv를 만든다. `--key=value`(인라인)와 `--key value`(공백
/// 분리) 둘 다 key가 민감하면 버린다(공백분리는 플래그+값 토큰을 함께). out에 보존 토큰을 채우고 그 슬라이스를
/// 돌려준다(입력 슬라이스 참조). 단일 출처: docs/workspace-restore.md "redaction 경계", project-rules.md "민감정보 redaction 기준".
pub fn redactArgv(argv: []const []const u8, out: [][]const u8) []const []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (isInlineSecret(tok)) continue;
        if (isSecretFlag(tok)) {
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) i += 1; // 공백분리 값도 스킵
            continue;
        }
        if (n >= out.len) break;
        out[n] = tok;
        n += 1;
    }
    return out[0..n];
}

// ── resume 재구성 (복원 시) ──────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// node 등 스크립트 인터프리터 basename — 에이전트가 `#!/usr/bin/env node` 래퍼로 돌면 exec_path가 인터프리터고
/// argv[1]이 실제 에이전트 스크립트다(codex가 그렇다). pty/macos.zig `isInterpreterName`과 같은 목록을 단일 규칙으로
/// 둔다(그쪽은 감지, 여기는 resume 재구성 — 둘이 어긋나면 감지된 에이전트의 복원이 깨진다).
const interpreters = [_][]const u8{ "node", "deno", "bun", "python", "python3", "ruby" };

pub fn isInterpreterPath(p: []const u8) bool {
    const base = std.fs.path.basename(p);
    for (interpreters) |it| if (eql(base, it)) return true;
    return false;
}

/// 복원 시점에 저장된 argv를 정확한 session id로 resume하도록 재구성한다. argv[0]은 호출자가 exec_path(=command)로
/// 따로 쓴다. **node 래퍼**(argv[0]=node, argv[1]=스크립트)면 그 스크립트를 args 맨 앞에 보존하고 실인자는 argv[2]
/// 부터다(`node /codex resume <id>`); native면 실인자는 argv[1]부터다. session_id가 비면 폴백 resume(claude
/// `--continue` / codex `resume --last`). out에 토큰을 채워 그 슬라이스를 돌려준다(입력/session_id 참조 — 호출자 수명).
pub fn rebuildAgentArgv(kind: Kind, argv: []const []const u8, session_id: []const u8, out: [][]const u8) []const []const u8 {
    if (argv.len == 0) return out[0..0];
    // node 래퍼면 argv[1]=스크립트도 "프로그램"이라 보존하고, 에이전트 실인자는 argv[2]부터.
    const wrapped = argv.len >= 2 and isInterpreterPath(argv[0]);
    var n: usize = 0;
    if (wrapped and n < out.len) {
        out[n] = argv[1];
        n += 1;
    }
    const real_start: usize = if (wrapped) 2 else 1;
    const real = argv[@min(real_start, argv.len)..];
    return switch (kind) {
        .claude => rebuildClaude(real, session_id, out, n),
        .codex => rebuildCodex(real, session_id, out, n),
    };
}

/// claude: 실인자(`real`)에서 `--resume`/`-r`(+값)·`--continue`/`-c`를 제거하고 정확한 id로 `--resume <id>`(없으면
/// `--continue`)를 끝에 더한다. 나머지 플래그(`--dangerously-skip-permissions` 등)는 보존. `start_n`은 호출자가 이미
/// out에 채운 래퍼 스크립트 prefix 다음 인덱스.
fn rebuildClaude(real: []const []const u8, session_id: []const u8, out: [][]const u8, start_n: usize) []const []const u8 {
    var n = start_n;
    var i: usize = 0;
    while (i < real.len) : (i += 1) {
        const tok = real[i];
        if (eql(tok, "--resume") or eql(tok, "-r")) {
            // --resume [value] — 다음 토큰이 값(플래그가 아니면)이면 같이 건너뛴다.
            if (i + 1 < real.len and !std.mem.startsWith(u8, real[i + 1], "-")) i += 1;
            continue;
        }
        if (eql(tok, "--continue") or eql(tok, "-c")) continue;
        if (n >= out.len) break;
        out[n] = tok;
        n += 1;
    }
    if (session_id.len > 0) {
        if (n + 2 <= out.len) {
            out[n] = "--resume";
            out[n + 1] = session_id;
            n += 2;
        }
    } else if (n < out.len) {
        out[n] = "--continue";
        n += 1;
    }
    return out[0..n];
}

/// codex: 서브커맨드 구조라 `resume <id>`(없으면 `resume --last`)를 더하고, 실인자(`real`)에서 resume 서브커맨드·
/// 세션 토큰(uuid/`--last`)을 빼고 나머지 글로벌 플래그를 보존한다. `start_n`은 래퍼 스크립트 prefix 다음 인덱스.
fn rebuildCodex(real: []const []const u8, session_id: []const u8, out: [][]const u8, start_n: usize) []const []const u8 {
    var n = start_n;
    if (n >= out.len) return out[0..n];
    out[n] = "resume";
    n += 1;
    if (session_id.len > 0) {
        if (n < out.len) {
            out[n] = session_id;
            n += 1;
        }
    } else if (n < out.len) {
        out[n] = "--last";
        n += 1;
    }
    var i: usize = 0;
    if (i < real.len and eql(real[i], "resume")) {
        i += 1;
        if (i < real.len and (eql(real[i], "--last") or !std.mem.startsWith(u8, real[i], "-"))) i += 1;
    }
    while (i < real.len) : (i += 1) {
        if (n >= out.len) break;
        out[n] = real[i];
        n += 1;
    }
    return out[0..n];
}

// ── 테스트(헤드리스, Linux CI 포함) ─────────────────────────────────────────────────

test "redactArgv: 인라인 민감 토큰 드롭, 무해 플래그 보존" {
    const argv = [_][]const u8{ "claude", "--api-key=sk-secret", "--dangerously-skip-permissions", "--model=opus", "--auth-token=zzz" };
    var out: [8][]const u8 = undefined;
    const r = redactArgv(&argv, &out);
    // --api-key(KEY)·--auth-token(AUTH/TOKEN) 드롭, 나머지 보존.
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("claude", r[0]);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", r[1]);
    try std.testing.expectEqualStrings("--model=opus", r[2]);
}

test "redactArgv: 공백분리 비밀(--api-key <v>)도 플래그+값 함께 드롭, 무해 값은 보존" {
    const argv = [_][]const u8{ "claude", "--api-key", "sk-secret", "--dangerously-skip-permissions", "--model", "opus" };
    var out: [8][]const u8 = undefined;
    const r = redactArgv(&argv, &out);
    // --api-key(KEY) + 다음 값 sk-secret 드롭. --model opus(민감 아님)는 둘 다 보존.
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("claude", r[0]);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", r[1]);
    try std.testing.expectEqualStrings("--model", r[2]);
    try std.testing.expectEqualStrings("opus", r[3]);
}

test "rebuildAgentArgv claude: 기존 resume 제거 + 정확한 id 주입, 위험모드 보존" {
    const argv = [_][]const u8{ "claude", "--dangerously-skip-permissions", "--resume", "old-id" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.claude, &argv, "new-id", &out);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", r[0]);
    try std.testing.expectEqualStrings("--resume", r[1]);
    try std.testing.expectEqualStrings("new-id", r[2]);
}

test "rebuildAgentArgv claude: session_id 없으면 --continue 폴백" {
    const argv = [_][]const u8{ "claude", "--dangerously-skip-permissions" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.claude, &argv, "", &out);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", r[0]);
    try std.testing.expectEqualStrings("--continue", r[1]);
}

test "rebuildAgentArgv codex: resume <id> 서브커맨드 + 기존 세션 토큰 제거" {
    const argv = [_][]const u8{ "codex", "resume", "old-id" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.codex, &argv, "new-id", &out);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("resume", r[0]);
    try std.testing.expectEqualStrings("new-id", r[1]);
}

test "rebuildAgentArgv codex: 새 세션(서브커맨드 없음)이면 resume <id> 앞에 붙이고 플래그 보존" {
    const argv = [_][]const u8{ "codex", "--model", "gpt-5" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.codex, &argv, "new-id", &out);
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("resume", r[0]);
    try std.testing.expectEqualStrings("new-id", r[1]);
    try std.testing.expectEqualStrings("--model", r[2]);
    try std.testing.expectEqualStrings("gpt-5", r[3]);
}

test "rebuildAgentArgv codex: session_id 없으면 resume --last 폴백" {
    const argv = [_][]const u8{"codex"};
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.codex, &argv, "", &out);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("resume", r[0]);
    try std.testing.expectEqualStrings("--last", r[1]);
}

test "rebuildAgentArgv codex: node 래퍼(exec_path=node, argv[1]=script)는 스크립트를 보존" {
    // codex는 #!/usr/bin/env node 래퍼라 캡처 argv=[node, /codex, resume, old]. command=argv[0]=node이고 args는
    // 스크립트(/codex)를 맨 앞에 보존해 `node /codex resume <id>`가 돼야 한다(스크립트 앞에 resume이 끼면 깨진다).
    const argv = [_][]const u8{ "/Users/me/.local/bin/node", "/Users/me/.local/bin/codex", "resume", "old-id" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.codex, &argv, "new-id", &out);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("/Users/me/.local/bin/codex", r[0]); // 스크립트 prefix 보존
    try std.testing.expectEqualStrings("resume", r[1]);
    try std.testing.expectEqualStrings("new-id", r[2]);
}

test "rebuildAgentArgv claude: node 래퍼는 스크립트 보존하고 위험모드 + --resume 재구성" {
    const argv = [_][]const u8{ "/usr/bin/node", "/opt/claude/cli.js", "--dangerously-skip-permissions", "--resume", "old" };
    var out: [8][]const u8 = undefined;
    const r = rebuildAgentArgv(.claude, &argv, "new", &out);
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("/opt/claude/cli.js", r[0]);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", r[1]);
    try std.testing.expectEqualStrings("--resume", r[2]);
    try std.testing.expectEqualStrings("new", r[3]);
}

test "Kind.fromString: claude/codex 인식, 그 외 null" {
    try std.testing.expectEqual(Kind.claude, Kind.fromString("claude").?);
    try std.testing.expectEqual(Kind.codex, Kind.fromString("codex").?);
    try std.testing.expectEqual(@as(?Kind, null), Kind.fromString(""));
    try std.testing.expectEqual(@as(?Kind, null), Kind.fromString("vim"));
}
