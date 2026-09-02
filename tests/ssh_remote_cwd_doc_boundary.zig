//! `ssh-integration.md` §9.4 의 「원격 cwd 소비처」 표가 **코드와 같은 상태를 말하는가**.
//!
//! ## 왜 문서를 판정자가 무는가
//!
//! 그 표는 **두 번 낡았다.** 「창 제목이 `currentCwd` 를 쓴다」는 옛 배선이었고, 코드는 2026-08-12 에
//! 그 사실을 주석으로 정정했는데 표는 따라오지 않았다. 그래서 2026-09-01 에 그 행을 읽고 「host 접두를
//! 붙이는 후속이 남았다」고 판단한 사람이 있었다 — **소비자가 0 인 자리의 후속**이었다.
//!
//! 표가 낡으면 **다음 사람에게 없는 일을 시킨다.** 그 낭비는 조용하고, 되풀이된다.
//!
//! ## 무엇을 세는가
//!
//! 표의 각 행이 주장하는 **코드 사실**을 소스에서 되짚는다. 문장을 대조하는 것이 아니라 **그 문장이
//! 참인지**를 본다 — 문구를 다듬어도 안 깨지고, 배선이 바뀌면 깨진다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// 함수 하나의 본문을 자른다. **`max` 를 넘으면 실패한다** — 경계 문자열이 안 맞으면 슬라이스가 파일
/// 끝까지 달아나고, 그러면 아래 needle 들이 **아무 데서나** 걸려 판정자가 통째로 초록이 된다
/// (적대적 검증 1회차: 경계를 지워도 통과했다). 「못 찾았다」와 「달아났다」를 함께 막는다.
fn bodyOf(src: []const u8, head: []const u8, close: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at, close) orelse return error.FunctionUnterminated;
    const body = src[at..end];
    if (body.len > max) return error.FunctionBodyRunaway;
    return body;
}

test "§9.4 표는 원격 cwd 소비처의 지금 배선을 말한다" {
    const allocator = std.testing.allocator;
    const doc = try read(allocator, "docs/ssh-integration.md", 512 * 1024);
    defer allocator.free(doc);
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);
    const workspace = try read(allocator, "src/platform/macos/app_session/workspace.zig", 2 * 1024 * 1024);
    defer allocator.free(workspace);

    // ── 표가 있는가(제목이 바뀌면 이 판정자가 딴 데를 보게 된다) ─────────────────────────────
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 소비처 | 원격 cwd일 때 |") != null);

    // ── ⑴ 창 제목은 **cwd 를 안 쓴다.** `windowTitle()` 이 OSC 0/2 관측에서 만든다 ────────────
    //
    // 표가 「`currentCwd` → Swift」라고 적고 있던 자리다. 코드가 그 사실을 먼저 정정했다.
    const wt_body = try bodyOf(workspace, "pub fn windowTitle", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "observation.window_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "currentCwd") == null); // 다시 엮이면 표도 고쳐야 한다
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 창 제목 | **cwd 를 안 쓴다.**") != null);

    // ── ⑵ `maru_macos_app_session_cwd` 는 **제품 소비자가 0** 이다 ─────────────────────────────
    //
    // 헤더 선언과 Zig export 는 있고 Swift 호출자가 없다. 생기면 표의 그 행부터 고쳐야 한다.
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig", 4 * 1024 * 1024);
    defer allocator.free(abi);
    try std.testing.expect(std.mem.indexOf(u8, abi, "pub export fn maru_macos_app_session_cwd") != null);
    // ⚠️ **Swift 파일은 하나가 아니다**(적대적 검증 2회차 — 16 개다). `MaruAppHost.swift` 만 보고
    //    「소비자 0」이라고 하면, 다른 파일이 부르는 순간 그 주장이 거짓이 되는데 판정자는 초록이다.
    //    디렉터리를 훑어 **전수**로 센다.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src/platform/macos", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var swift_seen: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".swift")) continue;
        const body = try dir.readFileAlloc(std.testing.io, entry.name, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(body);
        swift_seen += 1;
        if (std.mem.indexOf(u8, body, "maru_macos_app_session_cwd(") != null) {
            std.debug.print("소비자가 생겼다: {s} — §9.4 표의 그 행을 고쳐야 한다\n", .{entry.name});
            return error.CwdAbiConsumerAppeared;
        }
    }
    // **훑은 파일이 0 이면 경로가 바뀐 것이다** — 0 을 통과시키면 「아무도 안 부른다」와 「아무것도 안
    // 봤다」가 구분되지 않는다.
    try std.testing.expect(swift_seen >= 10);

    // ── ⑶ 표시 축의 규율: 원격 경로는 `<host>:<path>` ────────────────────────────────────────
    //
    // 폴더줄이 그 규율을 지고, 판정은 `termCwdIsRemote` + `termDisplayHost` **하나**를 공유한다 —
    // 재구현하면 두 뷰가 같은 경로를 다르게 적는다(실제로 종료 안내가 그랬다).
    const sb_body = try bodyOf(app, "pub fn sidebarCwdPath", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termDisplayHost(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "`<host>:<path>` 로 적는다") != null);

    // 그 규율을 지나는 자리는 **둘**이다 — 폴더줄과 종료 안내. 표에 행만 늘리고 여기서 안 세면,
    // 이 판정자가 막으려던 낡음이 **새 행에서 다시 시작**된다.
    const eg_body = try bodyOf(app, "pub fn writeEndedPlaceholderGuidance", "\n    }\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, eg_body, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, eg_body, "termDisplayHost(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 종료 placeholder 안내(`마지막 위치`) |") != null);

    // ── ⑷ 쓰기 축의 규율: 원격 cwd 를 **로컬 spawn 에 안 넘긴다** ─────────────────────────────
    //
    // 표의 두 행(새 탭 상속·종료 Term 되살리기)이 주장하는 사실이다.
    const respawn_body = try bodyOf(app, "fn respawnEndedPlaceholder", "\n    }\n", 8192);
    try std.testing.expect(std.mem.indexOf(u8, respawn_body, "if (!termCwdIsRemote(tomb))") != null);
    const term = try read(allocator, "src/platform/macos/app_session/term.zig", 4 * 1024 * 1024);
    defer allocator.free(term);
    const ft_body = try bodyOf(term, "pub fn focusedTermCwd", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, ft_body, "termCwdIsRemote(term)") != null);

    // ── ⑸ **`cwd` 만이 원격 경로는 아니다**(§9.4.1) ──────────────────────────────────────────
    //
    // 위 넷은 전부 `cwd` 축이다. 그런데 위험은 축이 아니라 **「저쪽 기계의 경로를 로컬 자원으로 쓴다」**
    // 는 사실에 있다. 이미지 갤러리는 `cwd` 가 아니라 훅의 `transcript_path` 를 쓰는 바람에 그 표의
    // 그물에 안 걸렸고, 실제로 **로컬의 다른 대화 이미지를 원격 세션 이름표 밑에 띄웠다**.
    //
    // 판정은 **읽는 쪽 한 곳**(`activeSourcePath`)에 있다 — 채택하는 쪽에도 두면 둘이 갈린다.
    const gallery = try read(allocator, "src/platform/macos/app_session/image_gallery.zig", 4 * 1024 * 1024);
    defer allocator.free(gallery);
    const src_body = try bodyOf(gallery, "fn activeSourcePath", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, src_body, "agent_ops.isRemoteAgentPane(term)") != null);
    // 「없다」와 「못 읽는다」를 가르는 문구가 살아 있는가 — 합치면 사용자가 훅 설치부터 다시 훑는다.
    try std.testing.expect(std.mem.indexOf(u8, gallery, "image_gallery_remote_unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "#### 9.4.1 cwd만이 원격 경로는 아니다") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "agent_ops.isRemoteAgentPane(term)") != null);
}

test "§9.4 컨트롤 플레인 행: wire 는 `cwd_host` 로 따로 알리고 경로엔 접두를 안 섞는다" {
    // **이 행만 판정자가 없었다**(2026-09-02). 표는 「전수」를 약속하는데 위 test 는 GUI 축 일곱 줄만
    // 되짚고 wire 축을 빼먹었다 — 표가 낡는 것을 막으려고 쓴 판정자가 **한 행을 안 보고 있었다.**
    //
    // 이 행이 특별한 이유: 다른 행은 「원격이면 안 쓴다」인데 여기는 **「그대로 싣고 host 를 따로
    // 알린다」**다. 바깥 소비자(`maru sessions list` 를 읽는 자동화)는 앱 안쪽 판정으로 못 막으므로
    // 사실대로 알려 주는 것이 유일한 수단이다. 그래서 **두 방향**이 함께 참이어야 한다:
    // 값이 실린다 ∧ 경로 문자열이 GUI 표기(`<host>:<path>`)로 오염되지 않는다.
    const allocator = std.testing.allocator;
    const doc = try read(allocator, "docs/ssh-integration.md", 512 * 1024);
    defer allocator.free(doc);
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);

    try std.testing.expect(std.mem.indexOf(u8, doc, "| 컨트롤 플레인 DTO의 `cwd` |") != null);

    // ── ⑴ 스키마에 필드가 있다(L2). 없어지면 아래 생산자는 컴파일이 깨지지만, **문서 행이 가리키는
    //     것은 wire 계약**이라 여기서 함께 못 박는다.
    const surface = try read(allocator, "src/session/control_surface.zig", 2 * 1024 * 1024);
    defer allocator.free(surface);
    try std.testing.expect(std.mem.indexOf(u8, surface, "cwd_host: ?[]const u8 = null,") != null);

    // ── ⑵ 생산자가 **원격일 때만** 싣고, host 판정을 `termDisplayHost` 로 **공유**한다 ─────────────
    //
    // 재구현하면 폴더줄·종료 안내와 답이 갈린다(위 test 의 표시 축이 지는 규율과 같은 것이다).
    const wire = try bodyOf(
        app,
        "var cwd_axis_buf: [std.fs.max_path_bytes]u8 = undefined;",
        "const at_prompt = atPromptWire(sem, alt);",
        4096,
    );
    try std.testing.expect(std.mem.indexOf(u8, wire, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "termDisplayHost(term)") != null);
    // 로컬은 **생략**이다 — 빈 문자열을 실으면 「host 가 빈 원격」으로 읽힌다.
    try std.testing.expect(std.mem.indexOf(u8, wire, "if (h.len > 0)") != null);

    // ── ⑶ 경로에 `<host>:` 접두를 **안 섞는다** ──────────────────────────────────────────────────
    //
    // 접두는 GUI 표기 규약(§9.3)이지 wire 값이 아니다. 폴더줄이 쓰는 `"{s}:{s}"` 가 이 구간에
    // 나타나면 wire 가 GUI 문자열을 흉내 내기 시작한 것이고, 바깥 소비자는 그 경로를 못 쓴다.
    try std.testing.expect(std.mem.indexOf(u8, wire, "termCwdForDisplay(self, term") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"{s}:{s}\"") == null);

    // ── ⑷ 두 필드가 **함께** DTO 에 올라간다 ────────────────────────────────────────────────────
    //
    // 「값을 만들었다」와 「실었다」는 다르다 — 만들고 안 싣는 상태가 실제로 이 축에서 한 번 있었다.
    try std.testing.expect(std.mem.indexOf(u8, app, ".cwd = cwd_copy,") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, ".cwd_host = cwd_host_copy,") != null);

    // ── ⑸ host-backed Term 도 나른다 ────────────────────────────────────────────────────────────
    //
    // in-process 만 배선하고 끝난 적이 있어서(§9.6 이 그 정정을 적고 있다) 전달 경로를 함께 센다.
    const codec = try read(allocator, "src/platform/macos/session_host/handoff_codec.zig", 4 * 1024 * 1024);
    defer allocator.free(codec);
    try std.testing.expect(std.mem.indexOf(u8, codec, ".tag = 90, .name = \"cwd_host\", .optional = true") != null);
    const meta_wire = try read(allocator, "src/platform/macos/session_host/runtime_metadata_wire.zig", 4 * 1024 * 1024);
    defer allocator.free(meta_wire);
    // canonical 검사와 해시 **둘 다** — 한쪽만 있으면 위조나 중복 표현이 지난다.
    try std.testing.expect(std.mem.indexOf(u8, meta_wire, "rangeIsCanonical(dto.cwd_host_range") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta_wire, "hashRange(&hasher, dto.cwd_host_range") != null);
}
