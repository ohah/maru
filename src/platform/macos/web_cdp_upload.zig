//! Chromium 탭의 `browser.upload`(W9c③) — 로케이터가 찾은 `<input type=file>` 에 앱이 만든 사본을 넣는 DevTools 차례. 로케이터 풀기는
//! `web_cdp_ops.Op` 가 click 과 같은 길로 하고(selector·ref·role·text·label), 요소를 찾으면 이 차례로 넘긴다(`located`). 확인 모달은
//! 없다(사용자 결정 2026-11-16 — 아래의 「모달 전」·「승인 뒤」 는 그 전의 이름이고 지금은 「넣기 전 확인」·「사본 뒤」 다) — 이 차례는 넣기
//! 전 확인을 마치면 `Step.confirm` 으로 멈추고, 앱이 곧 사본을 만들어 `beginPost` 하면 로케이터를 **다시** 풀어 같은 요소인지 본 뒤 넣는다(docs/plans/web-osr-backend.md 「W9c③ 결정」, 실제 CEF 154 실측):
//!
//! - **모달 전**: `Page.getFrameTree`(주 프레임 id·`loaderId`·`securityOrigin` — 모달은 이 출처만 보인다, 페이지가 정한 글은 싣지 않는다)
//!   → 격리 world → `DOM.resolveNode` → 확인 함수(파일 입력칸인가·꺼지지 않았나(`:disabled` — fieldset 도)·칸의 종류가 준 것과 맞나(파일을
//!   준 폴더 칸·폴더를 준 파일 칸은 거절)·여러 파일이면 `multiple` 인가·문서에 붙어 있나·그 frame 의 문서인가). `setFileInputFiles` 는 꺼진 칸에도
//!   넣고 이벤트까지 냈다(실측 d2 — 사람은 못 한다), 폴더 칸에는 폴더 경로도 파일 경로도 조용히 아무것도 안 넣었고(i·`up-folder-path-silent`), 한
//!   파일 칸에 둘을 주면 조용히 첫 것만 넣었다(b2) — 그래서 넣기 **전에** 거절한다. 폴더(`--folder`)는 사본 뒤 확인이 `webkitdirectory` 를 잠깐 떼고
//!   넣은 뒤 첫 진짜 `input` 에서 되돌린다(2026-11-20 — 아래 `check_js`).
//! - **iframe 안의 칸**(`frame`, 2026-11-20): 로케이터 대신 이 차례가 걷는다(`walk_*` — 단계마다 그 frame 의 격리 world 에서 그 iframe 의 selector,
//!   `DOM.describeNode` 로 frame id). 다른 사이트 iframe 이면 그 frame 의 세션(`session` — sidecar 의 자식 세션, wire 30)으로 들어가 그 뒤 호출을 싣는다.
//! - **승인 뒤**: 로케이터를 다시 풀어 같은 `backendNodeId` 인가 → 프레임 트리의 `loaderId` 가 같은가 → **새** 격리 world 에서 objectId 를
//!   잡아 다시 확인(그때 그 칸에 maru 의 듣는 이를 단다 — 아래) → 프레임 트리를 한 번 더(확인과 넣기 사이의 이동) →
//!   `DOM.setFileInputFiles{objectId}` → **같은 objectId** 로 읽어 확인(붙어 있나·수·이름·크기). objectId 는 문서와 함께 죽는다(실측 g4 —
//!   「Cannot find context」) — `backendNodeId` 는 다른 사이트로 옮기면 새 프로세스에서 다시 쓰였고(g2) 같은 문서에서 노드를 바꿔 끼워도
//!   `loaderId` 는 그대로였다(f). `setFileInputFiles` 는 조용히 실패해도 `{}` 라(떨어진 노드·없는 경로 등 여섯 경우 — `files.length`
//!   만으로는 못 잡는다) 넣은 뒤 이름·크기까지 읽는다.
//! - **넣을 때 받은 목록**(적대 리뷰 1 회차): `setFileInputFiles` 는 진짜 `input`·`change` 를 낸다 — 그 처리기에서 칸을 비우거나(`value=''`)
//!   다시 그리는 페이지는 파일을 받고 나서 지운다. 넣은 **뒤** 칸만 읽으면 「다른 목록」 으로 실패해 에이전트가 다시 올리고(모달 둘째·두 번
//!   올라감) 말았다. 그래서 넣기 앞의 확인이 격리 world 에서 그 칸에 캡처 단계의 `input`·`change` 듣는 이를 달아, 진짜(`isTrusted`) 이벤트가 그
//!   칸에 닿을 때의 목록(이름·크기)을 적어 둔다 — 격리 world 의 함수·프로토타입 getter 라 페이지가 그 기록을 고치거나 듣는 이를 흉내 낼 수 없고,
//!   진짜 이벤트는 페이지가 만들 수 없다. 읽기는 그 기록으로 「받았다」 를, 지금 칸으로 「그대로 두었다」(`kept`)를 따로 답한다. 페이지가 더 앞의
//!   캡처 듣는 이(창·조상)에서 이벤트를 멈추거나 먼저 비우면 기록이 없거나 다르다 — 그때는 예전처럼 지금 칸으로 판단한다(성공으로 속이지 않는다).
//! - **넣고 곧 옮겨 간 페이지**(적대 리뷰 2 회차): change 처리기가 `location.href=` 로 옮기면 넣기는 `{}` 로 끝나고(처리기는 파일을 받고 돌았다)
//!   곧 보낸 읽기는 Chromium 이 확정까지 붙잡았다가 「Cannot find context with specified id」 였다(실측 CEF 154 — 같은 출처·다른 사이트 3/3).
//!   앱이 이동을 먼저 보았으면 읽기를 보내지 않고 「…then try again」 이었다. 둘 다 실패로 답하면 에이전트가 다시 불러 모달이 또 뜨고 두 번
//!   올라간다 — 넣기가 끝난 뒤 문서가 사라진 읽기는 성공에 `kept:false`·`navigated:true`(받았는지는 읽을 수 없다 — CLI·MCP 는 「페이지를 보라,
//!   다시 올리지 마라」).
//! - **넣자 뜬 대화상자**(적대 리뷰 3 회차): change 처리기가 alert·confirm·prompt 를 띄우거나 떠나기 확인이 뜨면 넣기의 답은 대화상자가 답해질
//!   때까지 붙잡히고, 앱은 그 순간 호출을 「대화상자」 로 끝낸다 — 처리기는 그 전에 파일을 받았다(실측 CEF 154 3/3: alert 글이 「got 1」).
//!   `setTimeout` 의 대화상자면 넣기는 `{}` 이고 곧 보낸 읽기가 붙잡힌다. 실패로 답하면 에이전트가 대화상자에 답한 뒤 다시 올려 모달이 또 뜨고 두 번
//!   올라갔다 — 넣기를 **보낸 뒤**의 대화상자(넣기·읽기가 대화상자로 끝남, 대화상자 때문에 읽기를 못 보냄)는 성공에 `kept:false`·`dialog:true`
//!   (CLI·MCP 는 「대화상자에 답하고 페이지를 보라, 다시 올리지 마라」). 이미 떠 있어 넣기를 **보내지 못한** 것은 그대로 실패다(아무것도 안 갔다).
//! - **넣은 뒤 답하지 않는 읽기**(적대 리뷰 3 회차): change 처리기가 응답이 아주 늦은 주소로 옮기면 읽기는 확정까지 붙잡힌다(실측 35 초). 읽기는
//!   `verify_wait_ms` 만 기다리고(앱이 그 호출의 시한을 줄이고 요청 시한을 그 뒤로 미룬다), 넘으면 성공에 `kept:false`·`navigated:true` 다 — 넣기는
//!   `{}` 로 끝났다(처리기는 파일을 받았다). 이동이 없어도 페이지가 바쁘면 같다(4 회차 실측: change 처리기의 15 초 바쁜 타이머). 놓기는 보내지 않는다
//!   (그 호출도 붙잡혀 그 탭의 DevTools 자리를 쥔다 — 묶음은 문서와 함께 사라진다).
//! - 원격 객체는 요청마다 다른 묶음(`maru-w9b-<id>`)이고 끝나는 모든 길에서 놓는다(위의 읽기 시한·아래의 넣기 시한만 빼고). 승인 뒤 확인이 단 듣는
//!   이는 읽기가 떼고, 읽기를 못 한 끝(철회·넣기 오류·읽기를 못 보냄·대화상자)은 놓기 앞에서 뗀다(적대 리뷰 2 회차 — 문서가 죽을 때까지 격리 world 에
//!   남았다). 페이지가 답하지 않는 끝(시한)·탭이 사라진 끝은 떼지 않는다(그 호출도 30 초를 붙잡힌다).
//! - **답이 정해지면 곧 답한다**(적대 리뷰 4 회차 L1): 떼기·놓기는 답을 낸 **뒤**의 정리다 — 차례는 곧 `done` 을 내고 정리는 `takeCleanup` 으로
//!   넘겨, 앱이 요청과 묶지 않고 그 탭의 미룬 줄(web_osr `devtoolsCleanup` — 대화상자·확정되지 않은 이동이 없고 자리가 날 때, 탭마다 하나씩)로 보낸다.
//!   놓기도 페이지의 주 스레드에서 돈다 — 읽기가 「ok」 로 답한 뒤 페이지가 바쁘면 놓기가 붙잡혀(실측 CEF 154: 15 초 넘게) 요청 시한이 정해진 성공 대신
//!   맨 `-32004` 를 냈고, 에이전트는 다시 올렸다.
//! - **넣기를 보낸 뒤 답하지 않는 페이지**(적대 리뷰 4 회차 L1): change 처리기가 30 초 넘게 동기로 돌면 넣기 자체가 붙잡힌다(실측 — 처리기는 파일을
//!   받았다). 넣기를 **보낸 뒤**(`set_sent`)의 시한 — 넣기의 DevTools 시한이든 요청 시한(앱이 `lateSuccessJson` 으로 답한다)이든 — 은 읽기 시한과 같은
//!   성공에 `kept:false`·`navigated:true` 다. 보내지 못한 넣기는 그대로 실패다.
//! - 남는 틈(문서로 받아들인 것): 확인과 넣기 사이에 페이지가 같은 문서 안에서 노드를 바꾸면 파일은 떨어진 노드로 간다 — 같은 출처(사용자가
//!   승인한 그 문서)이고, 확인이 「removed」 로 실패를 알린다.

const std = @import("std");
const ops = @import("web_cdp_ops.zig");

const Step = ops.Step;
const Reply = ops.Reply;
const Status = ops.Status;

/// 한 번에 넣는 파일 수 상한 — L2(`control_browser.max_upload_files`)와 같다(앱이 컴파일 때 맞춘다).
pub const max_files = 10;

pub const not_found_reason = "no element matches the locator";
pub const hidden_reason = "no visible element matches the locator (matching elements are hidden) — a hidden file input can be given with --selector or --ref";
pub const not_file_input_reason = "the element is not a file input (<input type=file>)";
pub const disabled_reason = "the file input is disabled — a user could not choose files there";
pub const directory_reason = "the file input takes a folder (webkitdirectory) — give the folder with --folder (MCP: folder) instead of files";
/// 폴더를 주었는데 칸이 폴더 칸이 아니다(사용자 결정 2026-11-20 — 폴더는 `webkitdirectory` 칸에만: 사람의 고르개도 그 칸에서만 폴더를 고른다).
pub const not_directory_reason = "the file input takes files, not a folder — give the files without --folder";
pub const single_reason = "the file input takes one file — give one file, or use an input that allows several (multiple)";
/// 주 문서 길에서 찾은 칸이 다른 frame 의 것이다(role 질의는 같은 프로세스 iframe 안까지 닿는다) — iframe 안의 칸은 `--frame` 으로 준다(사용자 결정 2026-11-20).
pub const frame_reason = "the file input is inside a frame — give the frame with --frame <css selector of the iframe> (MCP: frame), and the input inside it with --selector (or no locator for the frame's only file input)";
/// `--frame` 단계 상한(바깥 → 안 — iframe 안의 iframe 까지). L2(`control_browser.max_upload_frames`)와 같다(앱이 컴파일 때 맞춘다).
pub const max_frames = 4;
/// 걷는 동안(사본 전) frame 이 사라졌다·옮겨 갔다.
pub const frame_gone_reason = "the frame changed while maru was looking into it — run upload again";
pub const detached_reason = "the file input is not in the page";
pub const page_changed_reason = "the page changed while maru was copying the files — no file was set; run upload again";
pub const removed_after_reason = "the file input was removed from the page before maru saw the files arrive — the page may not have them; check the page before trying again";
pub const mismatch_reason = "the page did not get the files maru set (the file input held a different list when they were set) — check the page before trying again";
pub const check_failed_reason = "could not check the file input";
pub const unseen_reason = "maru did not see the page receive the files (no input or change event reached the file input) and the input does not hold them now — check the page before trying again";

/// 넣은 뒤 읽기의 시한(적대 리뷰 3 회차) — 보통은 곧 답한다. 붙잡혔다면 페이지가 옮겨 가는 중이고(실측: 응답이 늦은 주소로의 이동) 더 기다려도
/// 알 것이 없다. 앱(`cdpAdvance`)이 그 호출의 DevTools 시한을 이만큼으로 줄이고 요청 시한을 그 뒤로 둔다 — 요청 시한(승인 뒤 30 초)이 먼저 오면
/// 에이전트는 맨 `-32004` 를 받고 다시 올렸다.
pub const verify_wait_ms: i64 = 10_000;

/// 격리 world 이름 — 확인마다 새로 만든다(옛 문서의 context 를 쓰지 않게).
const world_name = "maru-w9c-upload";
/// 넣을 때의 목록을 적는 자리(격리 world 의 `globalThis` — 페이지는 보지 못한다) — 뒤에 요청 번호.
const snapshot_key = "maru-w9c-upload-";

/// 격리 world 함수들(칸 확인·떼기·읽기) — 판정자가 같은 글을 실제 CEF 에 대도록 따로 둔다(`web_cdp_upload_js.zig`).
const upload_js = @import("web_cdp_upload_js.zig");
const check_js = upload_js.check_js;
const disarm_js = upload_js.disarm_js;
const verify_js = upload_js.verify_js;

/// 넣은 뒤 읽기 인자의 이름·크기 목록 밖 바이트의 위 끝(함수 본문이 JSON 이스케이프로 두 배가 돼도·objectId·key) — 앱이 폴더의 목록이 DevTools 인자
/// 한 번에 드는지 셀 때 쓴다(`app_host_abi.upload_folder_params_overhead`).
pub const verify_params_room: usize = verify_js.len * 2 + 512;

/// `walk_*` — iframe 걷기(사용자 결정 2026-11-20): 주 frame 부터 단계마다 그 frame 의 격리 world 에서 `--frame` selector 로 iframe 요소를 찾고
/// (`DOM.describeNode` 로 그 frame id), 마지막 frame 에서 대상(selector 또는 유일한 파일 칸)을 찾아 `located` 로 넘긴다 — 그 뒤 차례(tree … verify)는
/// 그 frame 에서 돈다.
const Stage = enum { tree, world, resolve, check, release_pre, tree_again, set, verify, walk_tree, walk_world, walk_find, walk_describe };

pub const Phase = enum { pre, post };

/// 승인 뒤 넣을 사본 하나(앱이 준다).
pub const Staged = struct { path: []const u8, name: []const u8, size: u64 };

/// 폴더 올리기의 요약(앱이 펼친 것 — 답의 `folder` 칸): 파일 크기 합과 뺀 수(종류별 — 이름은 싣지 않는다).
pub const FolderSummary = struct { bytes: u64, hidden: u32 = 0, links: u32 = 0, packages: u32 = 0, other: u32 = 0 };

const OwnedStaged = struct { path: []u8, name: []u8, size: u64 };

pub const Op = struct {
    id: u64,
    /// 넣을 파일 수(L2 가 1..10 을 봤다). 폴더면 0 — 펼친 수는 사본 뒤 `beginPost` 가 안다.
    count: usize,
    /// 폴더 올리기(사용자 결정 2026-11-20) — 칸이 `webkitdirectory` 여야 하고, 승인 뒤 확인이 속성을 바꿔 넣는다(`check_js`).
    folder: bool = false,
    /// 폴더의 요약(사본 뒤 `beginPost` — 답의 `folder` 칸).
    folder_summary: ?FolderSummary = null,
    phase: Phase = .pre,
    stage: Stage = .tree,
    /// 모달 전에 찾은 요소 — 승인 뒤 다시 찾은 것과 같아야 한다.
    backend: i64 = 0,
    loader: ?[]u8 = null,
    origin: ?[]u8 = null,
    frame: ?[]u8 = null,
    context: i64 = 0,
    object: ?[]u8 = null,
    staged: std.ArrayList(OwnedStaged) = .empty,
    /// 답을 낸 뒤 보낼 정리(적대 리뷰 4 회차 L1) — 앱이 `takeCleanup` 으로 꺼내 요청과 묶지 않고 보낸다(떼기가 먼저).
    cleanup: struct { disarm: bool = false, release: bool = false } = .{},
    /// 넣기(`setFileInputFiles`)를 실제로 보냈다(앱이 보낸 직후 적는다 — `markSetSent`). 그 뒤의 시한은 「넣었다」 다(4 회차 L1).
    set_sent: bool = false,
    /// `setFileInputFiles` 를 보냈고 그 답이 「안 했다」(오류·못 보냄)가 아니었다 — 사본이 페이지에 갔을 수 있다(앱이 실패여도 사본을 남긴다).
    given: bool = false,
    /// 승인 뒤 확인이 그 칸에 듣는 이를 달았고 아직 떼지 않았다 — 읽기를 못 하고 끝나면 놓기 앞에서 뗀다(`disarm_js`).
    armed: bool = false,
    /// iframe 안의 칸(사용자 결정 2026-11-20 — `--frame`): 바깥 → 안의 iframe selector 들(소유, 1..`max_frames`). 비면 주 문서 길(로케이터는
    /// `web_cdp_ops` 가 푼다).
    frames: std.ArrayList([]u8) = .empty,
    /// 마지막 frame 안의 대상 selector(소유) — null 이면 그 frame 의 유일한 `input[type=file]`(다른 사이트 iframe 안은 에이전트가 볼 길이 없다 —
    /// 공격 A3-7).
    target_sel: ?[]u8 = null,
    /// 걷기의 자리 — 다음에 풀 단계(`frames.len` 이면 대상).
    walk_level: usize = 0,
    /// 걷는 지금 frame 의 id(소유 — 처음은 주 frame, 끝나면 대상의 frame).
    walk_frame: ?[]u8 = null,
    walk_context: i64 = 0,
    walk_object: ?[]u8 = null,
    /// 모달 전 걷기가 단계마다 찾은 frame id(소유) — 사본 뒤 걷기가 같은 frame 들을 지나야 한다(iframe 을 바꿔 끼우면 다른 id).
    pre_frames: std.ArrayList([]u8) = .empty,
    /// wire 30: 지금 호출을 보내는 세션 — 다른 사이트 iframe(OOPIF)에 들어가면 그 frame id(소유, sidecar 가 그 타깃의 자식 세션으로 보낸다), null 이면
    /// 그 탭의 root 연결. 걷기가 같은 프로세스의 하위 frame 으로 가면 그대로다.
    session: ?[]u8 = null,
    /// 원격 객체 묶음을 쥔 세션들(root 밖 — 놓기를 세션마다 보낸다, 공격 A1-6).
    used_sessions: std.ArrayList([]u8) = .empty,
    /// 세션마다의 놓기 자리(0 = root, i = `used_sessions[i-1]`) — 모달 앞 놓기(`release_pre`)·답 뒤 정리가 차례로 보낸다.
    release_i: usize = 0,

    pub fn init(count: usize, id: u64) Op {
        return .{ .count = count, .id = id };
    }

    /// 폴더 올리기의 차례(파일 수는 사본 뒤에 안다).
    pub fn initFolder(id: u64) Op {
        return .{ .count = 0, .id = id, .folder = true };
    }

    /// iframe 안의 칸(`--frame`) — selector 들과 대상(없으면 유일한 파일 칸)을 복사해 쥔다. `start` 가 걷기를 시작한다.
    pub fn initFrames(gpa: std.mem.Allocator, base: Op, frames: []const []const u8, target: ?[]const u8) !Op {
        var op = base;
        errdefer op.deinit(gpa);
        for (frames) |f| {
            const copy = try gpa.dupe(u8, f);
            op.frames.append(gpa, copy) catch |e| {
                gpa.free(copy);
                return e;
            };
        }
        if (target) |t| op.target_sel = try gpa.dupe(u8, t);
        op.stage = .walk_tree;
        return op;
    }

    pub fn framed(self: *const Op) bool {
        return self.frames.items.len > 0;
    }

    /// iframe 걷기를 처음부터(모달 전·사본 뒤 모두 — 로케이터를 다시 푸는 것과 같은 자리).
    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        std.debug.assert(self.framed());
        self.walk_level = 0;
        if (self.walk_object) |o| gpa.free(o);
        self.walk_object = null;
        if (self.session) |f| gpa.free(f);
        self.session = null; // 걷기는 주 frame(root)부터
        self.stage = .walk_tree;
        return call(gpa, "Page.getFrameTree", "", .{});
    }

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.loader) |s| gpa.free(s);
        if (self.origin) |s| gpa.free(s);
        if (self.frame) |s| gpa.free(s);
        if (self.object) |s| gpa.free(s);
        self.freeStaged(gpa);
        self.staged.deinit(gpa);
        for (self.frames.items) |f| gpa.free(f);
        self.frames.deinit(gpa);
        if (self.target_sel) |t| gpa.free(t);
        if (self.walk_frame) |f| gpa.free(f);
        if (self.walk_object) |o| gpa.free(o);
        for (self.pre_frames.items) |f| gpa.free(f);
        self.pre_frames.deinit(gpa);
        if (self.session) |f| gpa.free(f);
        for (self.used_sessions.items) |f| gpa.free(f);
        self.used_sessions.deinit(gpa);
        self.* = undefined;
    }

    fn freeStaged(self: *Op, gpa: std.mem.Allocator) void {
        for (self.staged.items) |s| {
            gpa.free(s.path);
            gpa.free(s.name);
        }
        self.staged.clearRetainingCapacity();
    }

    /// 승인 뒤 — 사본을 받고(복사한다) 차례를 처음부터(로케이터 다시 풀기는 `web_cdp_ops.Op.resumeUpload` 가).
    pub fn beginPost(self: *Op, gpa: std.mem.Allocator, staged: []const Staged) !void {
        return self.beginPostWith(gpa, staged, null);
    }

    /// `beginPost` 와 같되 폴더의 요약을 함께(답의 `folder` 칸). 폴더면 사본 수가 곧 넣을 수다.
    pub fn beginPostWith(self: *Op, gpa: std.mem.Allocator, staged: []const Staged, summary: ?FolderSummary) !void {
        self.freeStaged(gpa);
        if (self.folder) {
            self.count = staged.len;
            self.folder_summary = summary;
        }
        for (staged) |s| {
            const path = try gpa.dupe(u8, s.path);
            errdefer gpa.free(path);
            const name = try gpa.dupe(u8, s.name);
            errdefer gpa.free(name);
            try self.staged.append(gpa, .{ .path = path, .name = name, .size = s.size });
        }
        self.phase = .post;
        self.stage = if (self.framed()) .walk_tree else .tree;
        if (self.object) |o| gpa.free(o);
        self.object = null;
    }

    /// 철회돼도 보낼 호출인가 — `stage` 는 **곧 보낼** 호출이다. 넣기를 보낸 뒤의 확인(`verify`)과 모달 앞의 놓기는 끝까지 보낸다. 넣기(`set`)
    /// 자체는 아니다 — 승인 뒤라도 그 사이 철회·탭 닫힘·시한이면 넣지 않는다(`cancel` 이 놓고 끝낸다). 답을 낸 뒤의 떼기·놓기는 차례 밖이다(`takeCleanup`).
    pub fn committed(self: *const Op) bool {
        return switch (self.stage) {
            .release_pre, .verify => true,
            else => false,
        };
    }

    /// 앱이 넣기를 실제로 보냈다(DevTools 가 받았다 — 자리가 없어 못 보낸 것은 아니다).
    pub fn markSetSent(self: *Op) void {
        if (self.stage == .set) self.set_sent = true;
    }

    /// 보낸 넣기를 sidecar 가 자리 없음(`busy` — 확실히 페이지에 가지 않았다)으로 돌려줬다(적대 리뷰 5 회차 S1). 다시 보낼 때까지(앱이 그때
    /// `markSetSent` 로 다시 적는다) 요청 시한은 「넣었다」 가 아니라 맨 시한이다 — 넣기는 페이지에 간 적이 없다.
    pub fn markSetRefused(self: *Op) void {
        if (self.stage == .set) self.set_sent = false;
    }

    /// 요청 시한이 왔을 때 낼 업로드의 답(적대 리뷰 4 회차 L1) — 넣기를 보냈으면 성공에 `kept:false`·`navigated:true`(소유), 아니면 null(맨 시한).
    /// 넣기를 보낸 뒤 답이 정해지면 차례가 곧 답하므로(위) 이것이 불리는 때는 넣기나 읽기가 아직 답하지 않은 때뿐이다.
    pub fn lateSuccessJson(self: *const Op, gpa: std.mem.Allocator) !?[]u8 {
        if (!self.set_sent) return null;
        return try self.successJson(gpa, false, true, false);
    }

    /// 답을 낸 뒤 보낼 정리 호출을 하나씩 꺼낸다(떼기 → 놓기 — `params` 소유). 없으면 null. 앱이 그 탭의 미룬 줄로 보낸다(답은 버린다).
    pub fn takeCleanup(self: *Op, gpa: std.mem.Allocator) !?Step {
        if (self.cleanup.disarm) {
            self.cleanup.disarm = false;
            var key_buf: [snapshot_key.len + 20]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, snapshot_key ++ "{d}", .{self.id}) catch unreachable;
            // 듣는 이는 대상의 세션(그 frame)에 있다.
            return self.inSession(try call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{f}}}]}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(disarm_js, .{}), std.json.fmt(key, .{}) }));
        }
        if (self.cleanup.release) {
            // 묶음은 세션마다다 — root 와 걷기가 들어간 다른 사이트 iframe 의 세션마다 놓는다.
            const step = try self.releaseAt(gpa, self.release_i);
            self.release_i += 1;
            if (self.release_i > self.used_sessions.items.len) {
                self.cleanup.release = false;
                self.release_i = 0;
            }
            return step;
        }
        return null;
    }

    /// 놓기 하나 — `i` 0 이면 root, 아니면 `used_sessions[i-1]` 의 세션으로.
    fn releaseAt(self: *Op, gpa: std.mem.Allocator, i: usize) !Step {
        var step = try call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
        // root 는 빈 글로 못박는다(`inSession` 이 null 만 지금 세션으로 채운다 — root 의 놓기가 그 세션으로 가지 않게).
        step.call.frame = if (i == 0) "" else self.used_sessions.items[i - 1];
        return step;
    }

    /// 지금 세션의 호출로(다른 사이트 iframe 안이면 그 frame — wire 30).
    fn inSession(self: *const Op, step: Step) Step {
        var out = step;
        switch (out) {
            .call => |*c| if (c.frame == null) {
                c.frame = self.session;
            },
            else => {},
        }
        return out;
    }

    /// `setFileInputFiles` 를 보내기 직전인가 — 앱이 그 호출 앞에서 에이전트 시각을 적는다(페이지의 change 처리기가 띄운 대화상자가 에이전트 것이
    /// 되게 — 모달 전의 호출은 페이지를 움직이지 않는다).
    pub fn setting(self: *const Op) bool {
        return self.stage == .set;
    }

    /// 넣은 뒤 읽기를 보내기 직전인가 — 앱이 그 호출의 시한을 `verify_wait_ms` 로 줄이고 요청 시한을 그 뒤로 둔다(적대 리뷰 3 회차).
    pub fn verifying(self: *const Op) bool {
        return self.stage == .verify;
    }

    /// 철회 — 원격 객체를 쥐었으면 곧 실패로 끝내고 떼기·놓기는 답 뒤의 정리로 넘긴다(`doneThenCleanup` — 4 회차 L1 부터 놓기를 기다리지 않는다).
    /// 쥔 것이 없으면 null(부른 쪽이 곧 끝낸다).
    pub fn cancel(self: *Op, gpa: std.mem.Allocator) !?Step {
        const out = try self.cancelInner(gpa);
        return if (out) |st| self.inSession(st) else null;
    }

    fn cancelInner(self: *Op, gpa: std.mem.Allocator) !?Step {
        return switch (self.stage) {
            .check, .tree_again, .set, .walk_world, .walk_find, .walk_describe => try self.doneThenCleanup(gpa, .failed, "the request was cancelled"),
            // iframe 걷기는 이 단계들에서도 걷기의 묶음을 쥐고 있다(1 회차 MED).
            .tree, .world, .resolve => if (self.framed()) try self.doneThenCleanup(gpa, .failed, "the request was cancelled") else null,
            else => null,
        };
    }

    /// 로케이터가 요소를 찾았다(`web_cdp_ops.Op.scrollStep` 자리). 모달 전이면 그 요소를 쥐고, 승인 뒤면 같은 요소인지 본다.
    pub fn located(self: *Op, gpa: std.mem.Allocator, backend: i64) !Step {
        return self.inSession(try self.locatedInner(gpa, backend));
    }

    fn locatedInner(self: *Op, gpa: std.mem.Allocator, backend: i64) !Step {
        if (self.phase == .pre) {
            self.backend = backend;
        } else if (backend != self.backend) {
            // iframe 걷기는 묶음을 쥐었다 — 놓는다(1 회차 MED).
            return if (self.framed()) self.doneThenCleanup(gpa, .failed, page_changed_reason) else done(gpa, .failed, page_changed_reason);
        }
        return self.treeStep(gpa, .tree);
    }

    fn treeStep(self: *Op, gpa: std.mem.Allocator, stage: Stage) !Step {
        self.stage = stage;
        return call(gpa, "Page.getFrameTree", "", .{});
    }

    /// 답이 정해졌다 — 곧 답하고, 쥔 것(듣는 이가 달려 있으면 떼기, 그리고 묶음 놓기)은 답 **뒤**의 정리로 넘긴다(`takeCleanup` — 적대 리뷰 4 회차
    /// L1: 놓기를 기다리면 바쁜 페이지가 정해진 답을 맨 시한으로 바꿨다). 대화상자가 떠 있으면 web_osr 의 미룬 줄이 그것이 사라진 뒤 보낸다(3 회차 nit).
    fn doneThenCleanup(self: *Op, gpa: std.mem.Allocator, status: Status, msg: []const u8) !Step {
        self.cleanup = .{ .disarm = self.armed, .release = true };
        self.armed = false;
        return done(gpa, status, msg);
    }

    fn releaseCall(self: *Op, gpa: std.mem.Allocator, stage: Stage) !Step {
        self.stage = stage;
        self.release_i = 0;
        return self.releaseAt(gpa, 0); // root 부터(세션마다 — feed 가 잇는다)
    }

    /// 확인의 답(`check_js` 의 글) → 실패 이유(null 이면 통과).
    fn checkReason(self: *const Op, verdict: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, verdict, "ok")) return null;
        if (std.mem.eql(u8, verdict, "frame")) return frame_reason;
        if (std.mem.eql(u8, verdict, "disabled")) return disabled_reason;
        if (std.mem.eql(u8, verdict, "directory")) return directory_reason;
        if (std.mem.eql(u8, verdict, "not directory")) return not_directory_reason;
        if (std.mem.eql(u8, verdict, "single")) return single_reason;
        if (std.mem.eql(u8, verdict, "detached")) return if (self.phase == .post) page_changed_reason else detached_reason;
        return not_file_input_reason;
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        // 모달 앞 놓기는 세션마다(root·다른 사이트 iframe) — 다 놓으면 멈춘다.
        if (self.stage == .release_pre) {
            self.release_i += 1;
            if (self.release_i <= self.used_sessions.items.len) return self.releaseAt(gpa, self.release_i);
            self.release_i = 0;
            return self.confirmStep(gpa);
        }
        return self.inSession(try self.feedInner(gpa, reply));
    }

    fn feedInner(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        const holds = switch (self.stage) {
            // 걷기는 iframe·대상 요소를 묶음에 쥔다(첫 프레임 트리 뒤부터) — 실패해도 놓는다. 그 뒤의 tree·world·resolve 도(1 회차 MED).
            .check, .tree_again, .set, .verify, .walk_world, .walk_find, .walk_describe => true,
            .tree, .world, .resolve => self.framed(),
            else => false,
        };
        const bytes = switch (reply) {
            .ok => |b| b,
            .cdp_error => |e| return self.cdpError(gpa, e, holds),
            .timed_out => |why| {
                // 넣기가 `{}` 로 끝난 뒤 읽기가 시한 — 받았다(3 회차 T1). 보낸 넣기 자체가 시한 — 처리기가 30 초 넘게 돈다(4 회차 L1, 실측: 처리기는
                // 파일을 받았다). 맨 timeout 은 다시 올리게 했다.
                if (self.stage == .verify or self.stage == .set) return self.verifyLate(gpa);
                self.armed = false; // 페이지가 답하지 않는다 — 떼기도 붙잡힌다(놓기만)
                return if (holds) self.doneThenCleanup(gpa, .timeout, why) else done(gpa, .timeout, why);
            },
            .failed => |why| {
                // 보낸 넣기·읽기가 대화상자로 끝났다 — 넣기는 갔다(붙잡힌 넣기도 대화상자가 답해지면 마저 돈다, 3 회차 D1).
                if ((self.stage == .set or self.stage == .verify) and std.mem.eql(u8, why, ops.dialog_reason)) return self.dialogShown(gpa);
                if (self.stage == .set) self.given = true;
                self.armed = false; // 탭이 닫혔거나 엔진이 멈췄거나 대화상자가 떴다 — 뗄 곳이 없거나 거절된다
                return if (holds) self.doneThenCleanup(gpa, .failed, why) else done(gpa, .failed, why);
            },
            .not_sent => |why| {
                // 넣은 뒤 읽기를 이동 중이라 보내지 않았다 — 넣기가 이동을 걸었다(2 회차: 「then try again」 이 다시 올리게 했다).
                if (self.stage == .verify and std.mem.eql(u8, why, ops.loading_reason)) return self.navigated(gpa);
                // 넣은 뒤 대화상자가 떠 읽기를 못 보냈다 — 넣기는 `{}` 로 끝났다(3 회차 D1). 넣기 자체를 못 보낸 것은 아래의 실패 그대로(갔다가 아니다).
                // 다른 사이트 iframe 에서도 먼저 본다(아래 세션 갈래가 앞서면 `dialog:true` 가 빠졌다 — 적대 검증 11 회차).
                if (self.stage == .verify and std.mem.eql(u8, why, ops.dialog_reason)) return self.dialogShown(gpa);
                // 다른 사이트 iframe: 넣기가 `{}` 로 끝난 뒤 읽기를 보내기 전에 그 세션이 사라졌다(위젯이 받자마자 iframe 을 지웠다 — sidecar 는 세션이
                // 없어 읽기를 보내지 않는다, `send_failed`). 처리기는 파일을 받았다 — 실패로 답하면 다시 올려 두 번 올라갔다(적대 검증 1 회차 SEVERE).
                if (self.stage == .verify and self.session != null) return self.navigated(gpa);
                return if (holds) self.doneThenCleanup(gpa, .failed, why) else done(gpa, .failed, why);
            },
        };
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
            return if (holds) self.doneThenCleanup(gpa, .failed, "malformed DevTools result") else done(gpa, .failed, "malformed DevTools result");
        defer parsed.deinit();
        const v = parsed.value;
        switch (self.stage) {
            .walk_tree => {
                const root = stringAt(v, &.{ "frameTree", "frame", "id" }) orelse return done(gpa, .failed, "no main frame");
                try replace(gpa, &self.walk_frame, root);
                return self.walkWorldStep(gpa);
            },
            .walk_world => {
                self.walk_context = intAt(v, &.{"executionContextId"}) orelse return self.doneThenCleanup(gpa, .failed, "no isolated world");
                return self.walkFindStep(gpa);
            },
            .walk_find => return self.walkFound(gpa, v),
            .walk_describe => return self.walkDescribed(gpa, v),
            .tree, .tree_again => {
                // iframe 안의 칸이면 그 frame 을 트리에서 찾는다(같은 프로세스의 하위 frame 은 그 트리에 있다 — 실측 probe-frametree).
                const fr: std.json.Value = if (self.framed())
                    (frameIn(v, self.walk_frame.?, 0) orelse return self.failHolding(gpa, if (self.phase == .post) page_changed_reason else frame_gone_reason))
                else
                    (at(v, &.{ "frameTree", "frame" }) orelse return self.failHolding(gpa, "no main frame"));
                const frame = stringAt(fr, &.{"id"}) orelse return self.failHolding(gpa, "no main frame");
                const loader = stringAt(fr, &.{"loaderId"}) orelse return self.failHolding(gpa, "no main frame");
                if (self.phase == .pre and self.stage == .tree) {
                    const origin = stringAt(fr, &.{"securityOrigin"}) orelse "";
                    try replace(gpa, &self.frame, frame);
                    try replace(gpa, &self.loader, loader);
                    try replace(gpa, &self.origin, origin);
                } else if (!std.mem.eql(u8, loader, self.loader.?) or !std.mem.eql(u8, frame, self.frame.?)) {
                    // 승인한 문서가 아니다 — 아무것도 넣지 않는다. 듣는 이를 단 문서는 사라졌다(떼지 않는다).
                    self.armed = false;
                    return self.failHolding(gpa, page_changed_reason);
                }
                if (self.stage == .tree_again) return self.setStep(gpa);
                self.stage = .world;
                return call(gpa, "Page.createIsolatedWorld", "{{\"frameId\":{f},\"worldName\":\"" ++ world_name ++ "\"}}", .{std.json.fmt(self.frame.?, .{})});
            },
            .world => {
                self.context = intAt(v, &.{"executionContextId"}) orelse return self.failHolding(gpa, "no isolated world");
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.backend, self.context, self.id });
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return self.failHolding(gpa, if (self.phase == .post) page_changed_reason else detached_reason);
                try replace(gpa, &self.object, oid);
                self.stage = .check;
                // 승인 뒤에는 듣는 이를 단다(넣을 때 받은 목록을 적는다) — 모달 전에는 페이지에 아무것도 달지 않는다.
                // 폴더면 넷째 인자(dir)로 — 승인 뒤 확인이 속성을 바꿔 넣는다(`check_js`).
                const dir_arg: []const u8 = if (self.folder) ",{\"value\":true}" else "";
                if (self.phase == .post)
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{d}}},{{\"value\":true}},{{\"value\":\"" ++ snapshot_key ++ "{d}\"}}{s}],\"returnByValue\":true}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(check_js, .{}), self.count, self.id, dir_arg });
                if (self.folder)
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":0}},{{\"value\":false}},{{\"value\":\"\"}},{{\"value\":true}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(check_js, .{}) });
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(check_js, .{}), self.count });
            },
            .check => {
                if (at(v, &.{"exceptionDetails"}) != null) return self.doneThenCleanup(gpa, .failed, check_failed_reason);
                const verdict = stringAt(v, &.{ "result", "value" }) orelse return self.doneThenCleanup(gpa, .failed, check_failed_reason);
                if (self.checkReason(verdict)) |why| return self.doneThenCleanup(gpa, .failed, why);
                if (self.phase == .post) self.armed = true; // 통과한 확인은 듣는 이를 달았다
                // 모달 전: 놓고 멈춘다(모달). 승인 뒤: 확인과 넣기 사이의 이동을 한 번 더 본다.
                if (self.phase == .pre) return self.releaseCall(gpa, .release_pre);
                return self.treeStep(gpa, .tree_again);
            },
            .set => {
                self.given = true;
                return self.verifyStep(gpa);
            },
            .verify => {
                self.armed = false; // 읽기가 돌았다 — 처음에 듣는 이를 뗐다
                if (at(v, &.{"exceptionDetails"}) != null) return self.doneThenCleanup(gpa, .failed, mismatch_reason);
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                if (std.mem.eql(u8, verdict, "removed")) return self.doneThenCleanup(gpa, .failed, removed_after_reason);
                if (std.mem.eql(u8, verdict, "unseen")) return self.doneThenCleanup(gpa, .failed, unseen_reason);
                // 넣을 때 받은 목록이 맞으면 성공 — 그 뒤 페이지가 비웠으면 kept:false(다시 올리면 두 번 올라간다).
                const kept = std.mem.eql(u8, verdict, "ok");
                if (!kept and !std.mem.eql(u8, verdict, "dropped")) return self.doneThenCleanup(gpa, .failed, mismatch_reason);
                const result = try self.successJson(gpa, kept, false, false);
                defer gpa.free(result);
                return self.doneThenCleanup(gpa, .success, result);
            },
            .release_pre => unreachable, // 위에서
        }
    }

    fn walkWorldStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .walk_world;
        return call(gpa, "Page.createIsolatedWorld", "{{\"frameId\":{f},\"worldName\":\"" ++ world_name ++ "\"}}", .{std.json.fmt(self.walk_frame.?, .{})});
    }

    /// 지금 frame 의 격리 world 에서 다음 단계의 iframe(또는 대상)을 찾는다 — 격리 world 의 프로토타입으로(페이지가 바꿔 놓은 함수로 속이지 못하게).
    fn walkFindStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .walk_find;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        (blk: {
            const sel: ?[]const u8 = if (self.walk_level < self.frames.items.len) self.frames.items[self.walk_level] else self.target_sel;
            var expr: std.Io.Writer.Allocating = .init(gpa);
            defer expr.deinit();
            if (sel) |q| {
                expr.writer.writeAll("(function(s){return Document.prototype.querySelector.call(document,s)})(") catch |e| break :blk e;
                std.json.Stringify.value(q, .{}, &expr.writer) catch |e| break :blk e;
                expr.writer.writeAll(")") catch |e| break :blk e;
            } else {
                // 대상이 없다 — 그 frame 의 유일한 파일 칸(0 이나 둘 이상이면 그 수).
                expr.writer.writeAll("(function(){var l=Document.prototype.querySelectorAll.call(document,'input[type=file]'),n=Object.getOwnPropertyDescriptor(NodeList.prototype,'length').get.call(l);return n===1?NodeList.prototype.item.call(l,0):n})()") catch |e| break :blk e;
            }
            w.writeAll("{\"expression\":") catch |e| break :blk e;
            std.json.Stringify.value(expr.written(), .{}, w) catch |e| break :blk e;
            w.print(",\"contextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.walk_context, self.id }) catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Runtime.evaluate", .params = try aw.toOwnedSlice() } };
    }

    /// 찾기의 답 — 요소면 그 노드를 본다(`DOM.describeNode`), 없으면·수면 그 까닭으로 끝.
    fn walkFound(self: *Op, gpa: std.mem.Allocator, v: std.json.Value) !Step {
        const level = self.walk_level + 1;
        const at_frame = self.walk_level < self.frames.items.len;
        if (at(v, &.{"exceptionDetails"}) != null) {
            // selector 문법 오류(SyntaxError) — 주 문서 길의 selector 오류처럼 invalid_params.
            const msg = if (at_frame)
                try std.fmt.allocPrint(gpa, "the --frame selector at level {d} is not a valid CSS selector", .{level})
            else
                try gpa.dupe(u8, "the --selector inside the frame is not a valid CSS selector");
            defer gpa.free(msg);
            return self.doneThenCleanup(gpa, .invalid_params, msg);
        }
        if (stringAt(v, &.{ "result", "objectId" })) |oid| {
            try replace(gpa, &self.walk_object, oid);
            self.stage = .walk_describe;
            return call(gpa, "DOM.describeNode", "{{\"objectId\":{f}}}", .{std.json.fmt(oid, .{})});
        }
        if (at_frame) {
            const msg = try std.fmt.allocPrint(gpa, "no element matches the --frame selector at level {d}", .{level});
            defer gpa.free(msg);
            return self.doneThenCleanup(gpa, .failed, msg);
        }
        if (self.target_sel != null) return self.doneThenCleanup(gpa, .failed, not_found_reason);
        const n = intAt(v, &.{ "result", "value" }) orelse 0;
        const msg = if (n == 0)
            try gpa.dupe(u8, "the frame has no file input (<input type=file>)")
        else
            try std.fmt.allocPrint(gpa, "the frame has {d} file inputs — pick one with --selector", .{n});
        defer gpa.free(msg);
        return self.doneThenCleanup(gpa, .failed, msg);
    }

    /// 찾은 노드 — 단계면 iframe·frame 이고 그 frame 이 같은 프로세스여야(문서가 실려 있다) 그 안으로, 대상이면 그 노드로 `located`.
    fn walkDescribed(self: *Op, gpa: std.mem.Allocator, v: std.json.Value) !Step {
        const node = at(v, &.{"node"}) orelse return self.doneThenCleanup(gpa, .failed, check_failed_reason);
        if (self.walk_level >= self.frames.items.len) {
            const backend = intAt(node, &.{"backendNodeId"}) orelse return self.doneThenCleanup(gpa, .failed, check_failed_reason);
            // 대상은 그 frame 에서 다시 잡는다(`located` → 프레임 트리·격리 world·resolve) — 걷기의 객체는 묶음에 남고 놓기가 함께 놓는다.
            return self.located(gpa, backend);
        }
        const level = self.walk_level + 1;
        const name = stringAt(node, &.{"nodeName"}) orelse "";
        if (!std.ascii.eqlIgnoreCase(name, "IFRAME") and !std.ascii.eqlIgnoreCase(name, "FRAME")) {
            const msg = try std.fmt.allocPrint(gpa, "the --frame selector at level {d} matched an element that is not an iframe", .{level});
            defer gpa.free(msg);
            return self.doneThenCleanup(gpa, .failed, msg);
        }
        const fid = stringAt(node, &.{"frameId"}) orelse {
            const msg = try std.fmt.allocPrint(gpa, "the iframe at level {d} has no document yet — wait for it to load, then try again", .{level});
            defer gpa.free(msg);
            return self.doneThenCleanup(gpa, .failed, msg);
        };
        const cross = at(node, &.{"contentDocument"}) == null;
        if (self.phase == .pre) {
            const copy = try gpa.dupe(u8, fid);
            self.pre_frames.append(gpa, copy) catch |e| {
                gpa.free(copy);
                return e;
            };
        } else if (self.walk_level >= self.pre_frames.items.len or !std.mem.eql(u8, self.pre_frames.items[self.walk_level], fid)) {
            // 사본을 만드는 동안 그 자리의 iframe 이 다른 frame 이 되었다(바꿔 끼움·주 문서 이동) — 아무것도 넣지 않는다.
            return self.doneThenCleanup(gpa, .failed, page_changed_reason);
        }
        try replace(gpa, &self.walk_frame, fid);
        if (cross) {
            // 다른 사이트의 iframe — 다른 렌더러 프로세스(OOPIF)라 이 연결에서 그 문서가 보이지 않는다(실측 probe-dom-pierce·판정 up-frame-describe).
            // 그 frame 의 DevTools 타깃(id = frame id)의 자식 세션으로 들어간다 — sidecar 가 붙인다(wire 30, `devtools_frames.zig`). 그 세션의 처음
            // 호출은 격리 world 만들기다(원격 객체를 싣지 않는 호출만 새로 붙는다 — 공격 A1-3).
            try replace(gpa, &self.session, fid);
            var seen = false;
            for (self.used_sessions.items) |u| if (std.mem.eql(u8, u, fid)) {
                seen = true;
            };
            if (!seen) {
                const copy = try gpa.dupe(u8, fid);
                self.used_sessions.append(gpa, copy) catch |e| {
                    gpa.free(copy);
                    return e;
                };
            }
        }
        self.walk_level += 1;
        return self.walkWorldStep(gpa);
    }

    /// 쥔 객체가 있으면 놓고, 없으면 곧 실패.
    fn failHolding(self: *Op, gpa: std.mem.Allocator, why: []const u8) !Step {
        // iframe 걷기는 tree 앞에서 iframe·대상 요소를 묶음에 쥐었다 — 그 뒤의 tree·world·resolve 끝에서도 놓는다(적대 검증 1·2 회차 MED).
        if (self.stage == .tree_again or self.framed()) return self.doneThenCleanup(gpa, .failed, why);
        return done(gpa, .failed, why);
    }

    fn confirmStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .tree; // 승인 뒤에는 `beginPost` 가 다시 세운다
        return .{ .confirm = .{ .origin = try gpa.dupe(u8, self.origin orelse "") } };
    }

    fn setStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .set;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        (blk: {
            s.beginObject() catch |e| break :blk e;
            s.objectField("files") catch |e| break :blk e;
            s.beginArray() catch |e| break :blk e;
            for (self.staged.items) |f| s.write(f.path) catch |e| break :blk e;
            s.endArray() catch |e| break :blk e;
            s.objectField("objectId") catch |e| break :blk e;
            s.write(self.object.?) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "DOM.setFileInputFiles", .params = try aw.toOwnedSlice() } };
    }

    fn verifyStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .verify;
        var key_buf: [snapshot_key.len + 20]u8 = undefined;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        (blk: {
            s.beginObject() catch |e| break :blk e;
            s.objectField("objectId") catch |e| break :blk e;
            s.write(self.object.?) catch |e| break :blk e;
            s.objectField("functionDeclaration") catch |e| break :blk e;
            s.write(verify_js) catch |e| break :blk e;
            s.objectField("arguments") catch |e| break :blk e;
            s.beginArray() catch |e| break :blk e;
            s.beginObject() catch |e| break :blk e;
            s.objectField("value") catch |e| break :blk e;
            s.beginArray() catch |e| break :blk e;
            for (self.staged.items) |f| s.write(f.name) catch |e| break :blk e;
            s.endArray() catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
            s.beginObject() catch |e| break :blk e;
            s.objectField("value") catch |e| break :blk e;
            s.beginArray() catch |e| break :blk e;
            for (self.staged.items) |f| s.write(f.size) catch |e| break :blk e;
            s.endArray() catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
            s.beginObject() catch |e| break :blk e;
            s.objectField("value") catch |e| break :blk e;
            s.write(std.fmt.bufPrint(&key_buf, snapshot_key ++ "{d}", .{self.id}) catch unreachable) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
            s.endArray() catch |e| break :blk e;
            s.objectField("returnByValue") catch |e| break :blk e;
            s.write(true) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Runtime.callFunctionOn", .params = try aw.toOwnedSlice() } };
    }

    /// 넣기가 `{}` 로 끝난 뒤 읽기 전에 문서가 사라졌다(이동이 시작됐거나 확정됐다) — 처리기는 파일을 받고 돌았다(넣기의 이벤트는 넣기가
    /// 돌아오기 전에 났다 — 1 회차 실측). 받은 목록은 읽을 수 없다: 성공에 `kept:false`·`navigated:true`. 실패로 답하면 에이전트가 다시 올린다.
    /// 듣는 이는 문서와 함께 사라졌다(떼지 않는다).
    fn navigated(self: *Op, gpa: std.mem.Allocator) !Step {
        self.armed = false;
        const result = try self.successJson(gpa, false, true, false);
        defer gpa.free(result);
        return self.doneThenCleanup(gpa, .success, result);
    }

    /// 넣기가 `{}` 로 끝난 뒤 읽기가 `verify_wait_ms` 안에 답하지 않았다(3 회차 T1 — 실측: change 처리기가 응답이 늦은 주소로 옮겨 읽기가 확정까지
    /// 붙잡혔다), 또는 보낸 넣기 자체가 시한이다(4 회차 L1 — 처리기가 30 초 넘게 동기로 돈다). 처리기는 파일을 받았다 — 성공에 `kept:false`·
    /// `navigated:true`(작성자 선택: 「넣었지만 확인 못 함」 실패 대신 2 회차와 같은 답 — 둘 다 「페이지를 보라, 다시 올리지 마라」 다). 이동이 아니라
    /// 페이지가 바쁘거나 멈춘 것이어도 같은 답이다(실측: 바쁜 타이머 — 이동 없이도). 떼기·놓기는 보내지 않는다 — 답하지 않는 페이지에 보내면 그것도
    /// 붙잡혀 그 탭의 DevTools 자리를 쥔다(묶음·듣는 이는 문서와 함께 사라진다).
    fn verifyLate(self: *Op, gpa: std.mem.Allocator) !Step {
        self.given = true;
        self.armed = false;
        const result = try self.successJson(gpa, false, true, false);
        return .{ .done = .{ .status = .success, .result = result } };
    }

    /// 넣기를 보낸 뒤 페이지(또는 그 팝업 가족)가 대화상자를 띄웠다(3 회차 D1) — 넣기는 갔다(처리기의 alert 면 이미 받았고, 붙잡힌 넣기는 대화상자가
    /// 답해지면 마저 돈다). 읽을 수 없다: 성공에 `kept:false`·`dialog:true`. 실패로 답하면 에이전트가 대화상자에 답한 뒤 다시 올렸다(모달 둘째·두 번
    /// 올라감). 듣는 이는 떼고 묶음은 놓는다 — 둘 다 답 뒤의 정리로, 대화상자가 사라진 뒤에 간다(web_osr 의 미룬 줄).
    fn dialogShown(self: *Op, gpa: std.mem.Allocator) !Step {
        self.given = true;
        const result = try self.successJson(gpa, false, false, true);
        defer gpa.free(result);
        return self.doneThenCleanup(gpa, .success, result);
    }

    /// 성공 답 — `{"origin","files":[{"name","size"}],"kept","navigated","dialog"}`(L2 `serializeUploadResult` 가 검사한다). `kept` 거짓 = 넣을 때
    /// 받았지만 그 뒤 페이지가 칸을 비우거나 바꿨다, 곧 옮겨 가 읽을 수 없었다(`navigated` 참 — 2 회차, 읽기가 시한 — 3 회차), 또는 넣자 대화상자가
    /// 떠 읽을 수 없었다(`dialog` 참 — 3 회차).
    fn successJson(self: *const Op, gpa: std.mem.Allocator, kept: bool, moved: bool, dialog: bool) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        (blk: {
            s.beginObject() catch |e| break :blk e;
            s.objectField("origin") catch |e| break :blk e;
            s.write(self.origin orelse "") catch |e| break :blk e;
            s.objectField("files") catch |e| break :blk e;
            s.beginArray() catch |e| break :blk e;
            for (self.staged.items) |f| {
                s.beginObject() catch |e| break :blk e;
                s.objectField("name") catch |e| break :blk e;
                s.write(f.name) catch |e| break :blk e;
                s.objectField("size") catch |e| break :blk e;
                s.write(f.size) catch |e| break :blk e;
                s.endObject() catch |e| break :blk e;
            }
            s.endArray() catch |e| break :blk e;
            s.objectField("kept") catch |e| break :blk e;
            s.write(kept) catch |e| break :blk e;
            s.objectField("navigated") catch |e| break :blk e;
            s.write(moved) catch |e| break :blk e;
            s.objectField("dialog") catch |e| break :blk e;
            s.write(dialog) catch |e| break :blk e;
            // 폴더: 넣은 수·크기 합·뺀 수(종류별) — L2 가 `files` 의 수와 같은지 본다.
            if (self.folder_summary) |f| {
                s.objectField("folder") catch |e| break :blk e;
                s.beginObject() catch |e| break :blk e;
                s.objectField("files") catch |e| break :blk e;
                s.write(self.staged.items.len) catch |e| break :blk e;
                s.objectField("bytes") catch |e| break :blk e;
                s.write(f.bytes) catch |e| break :blk e;
                s.objectField("skipped") catch |e| break :blk e;
                s.beginObject() catch |e| break :blk e;
                // 칸마다 곧게 쓴다(반사 없이 — 경계 판정이 `@field` 를 재고에 센다).
                s.objectField("hidden") catch |e| break :blk e;
                s.write(f.hidden) catch |e| break :blk e;
                s.objectField("links") catch |e| break :blk e;
                s.write(f.links) catch |e| break :blk e;
                s.objectField("packages") catch |e| break :blk e;
                s.write(f.packages) catch |e| break :blk e;
                s.objectField("other") catch |e| break :blk e;
                s.write(f.other) catch |e| break :blk e;
                s.endObject() catch |e| break :blk e;
                s.endObject() catch |e| break :blk e;
            }
            s.endObject() catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// CDP 오류 — 문서가 바뀌어 context·노드가 사라졌으면(승인 뒤) 「페이지가 바뀌었다」, 그 밖은 그 글로. 쥔 객체는 놓는다. 넣은 뒤의 읽기에서
    /// 문서가 사라졌으면 넣기가 이동을 걸었다 — 「넣고 곧 옮겨 갔다」(`navigated`, 2 회차).
    fn cdpError(self: *Op, gpa: std.mem.Allocator, err_json: []const u8, holds: bool) !Step {
        var owned: ?[]u8 = null;
        defer if (owned) |m| gpa.free(m);
        if (std.json.parseFromSlice(std.json.Value, gpa, err_json, .{})) |parsed| {
            defer parsed.deinit();
            if (stringAt(parsed.value, &.{"message"})) |m| owned = try gpa.dupe(u8, m);
        } else |_| {}
        const message: []const u8 = owned orelse "DevTools error";
        // wire 30: 다른 사이트 iframe 의 세션이 사라졌다(위젯이 iframe 을 지웠다·그 frame 이 다른 문서로) — sidecar 는 그 세션으로 **보낸** 호출에만 이 글을
        // 준다(보내지 못한 것은 `send_failed`). 넣기를 보낸 뒤면 처리기가 받았을 수 있다 — 실패로 답하면 다시 올려 두 번 올라간다(공격 A1-3):
        // 읽기처럼 「넣었다 — 읽을 수 없다」(성공에 navigated:true).
        const session_gone = std.mem.indexOf(u8, message, "Session with given id not found") != null;
        if (self.stage == .set and session_gone) {
            self.given = true;
            return self.navigated(gpa);
        }
        const context_gone = std.mem.indexOf(u8, message, "Cannot find context") != null or std.mem.indexOf(u8, message, "Could not find object") != null or session_gone;
        if (self.stage == .verify and context_gone) return self.navigated(gpa);
        const gone = context_gone or std.mem.indexOf(u8, message, "No node") != null or std.mem.indexOf(u8, message, "No frame") != null;
        if (context_gone) self.armed = false; // 문서가 사라졌다 — 듣는 이도 함께(노드만 떨어졌으면 문서는 살아 있다 — 뗀다)
        const why: []const u8 = switch (self.stage) {
            .set => if (gone) page_changed_reason else if (std.mem.indexOf(u8, message, "not a file input") != null) not_file_input_reason else message,
            .world, .resolve, .check, .tree, .tree_again => if (gone) (if (self.phase == .post) page_changed_reason else detached_reason) else message,
            .walk_tree, .walk_world, .walk_find, .walk_describe => if (gone) (if (self.phase == .post) page_changed_reason else frame_gone_reason) else message,
            else => message,
        };
        return if (holds) self.doneThenCleanup(gpa, .failed, why) else done(gpa, .failed, why);
    }
};

/// `Page.getFrameTree` 의 답에서 그 id 의 frame 객체(`frameTree.frame` 꼴 — 자식은 `childFrames`). 깊이는 16 까지(답은 sidecar 가 보낸 것이다).
fn frameIn(v: std.json.Value, id: []const u8, depth: u8) ?std.json.Value {
    const node = if (depth == 0) (at(v, &.{"frameTree"}) orelse return null) else v;
    if (at(node, &.{"frame"})) |f| if (stringAt(f, &.{"id"})) |x| if (std.mem.eql(u8, x, id)) return f;
    if (depth >= 16) return null;
    const kids = at(node, &.{"childFrames"}) orelse return null;
    if (kids != .array) return null;
    for (kids.array.items) |k| if (frameIn(k, id, depth + 1)) |f| return f;
    return null;
}

fn replace(gpa: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    const copy = try gpa.dupe(u8, value);
    if (slot.*) |old| gpa.free(old);
    slot.* = copy;
}

fn call(gpa: std.mem.Allocator, method: []const u8, comptime fmt: []const u8, args: anytype) !Step {
    const params = if (fmt.len == 0) try gpa.alloc(u8, 0) else try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .call = .{ .method = method, .params = params } };
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

fn at(v: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn stringAt(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    const x = at(v, path) orelse return null;
    return if (x == .string) x.string else null;
}

fn intAt(v: std.json.Value, path: []const []const u8) ?i64 {
    const x = at(v, path) orelse return null;
    return if (x == .integer) x.integer else null;
}
