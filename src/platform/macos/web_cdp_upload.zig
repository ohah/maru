//! Chromium 탭의 `browser.upload`(W9c③) — 로케이터가 찾은 `<input type=file>` 에 앱이 만든 사본을 넣는 DevTools 차례. 로케이터 풀기는
//! `web_cdp_ops.Op` 가 click 과 같은 길로 하고(selector·ref·role·text·label), 요소를 찾으면 이 차례로 넘긴다(`located`). 확인 모달은 앱이
//! 띄운다 — 이 차례는 모달 전 확인을 마치면 `Step.confirm` 으로 멈추고, 앱이 승인 뒤 사본을 만들어 `beginPost` 하면 로케이터를 **다시**
//! 풀어 같은 요소인지 본 뒤 넣는다(docs/plans/web-osr-backend.md 「W9c③ 결정」, 실제 CEF 154 실측):
//!
//! - **모달 전**: `Page.getFrameTree`(주 프레임 id·`loaderId`·`securityOrigin` — 모달은 이 출처만 보인다, 페이지가 정한 글은 싣지 않는다)
//!   → 격리 world → `DOM.resolveNode` → 확인 함수(파일 입력칸인가·꺼지지 않았나(`:disabled` — fieldset 도)·폴더 칸이 아닌가·여러 파일이면
//!   `multiple` 인가·문서에 붙어 있나·주 프레임인가). `setFileInputFiles` 는 꺼진 칸에도 넣고 이벤트까지 냈다(실측 d2 — 사람은 못 한다),
//!   폴더 칸에는 조용히 아무것도 안 넣었고(i), 한 파일 칸에 둘을 주면 조용히 첫 것만 넣었다(b2) — 그래서 모달 **전에** 거절한다.
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
//!   `{}` 로 끝났다(처리기는 파일을 받았다). 놓기는 보내지 않는다(그 호출도 붙잡혀 요청 시한을 넘긴다 — 묶음은 문서와 함께 사라진다).
//! - 원격 객체는 요청마다 다른 묶음(`maru-w9b-<id>`)이고 끝나는 모든 길에서 놓는다(위의 읽기 시한만 빼고). 승인 뒤 확인이 단 듣는 이는 읽기가 떼고,
//!   읽기를 못 한 끝(철회·넣기 오류·읽기를 못 보냄·대화상자)은 놓기 앞에서 뗀다(적대 리뷰 2 회차 — 문서가 죽을 때까지 격리 world 에 남았다). 대화상자가
//!   떠 있으면 떼기·놓기는 그것이 사라진 뒤로 미룬다(`after_dialog` — 3 회차). 페이지가 답하지 않는 끝(시한)·탭이 사라진 끝은 떼지 않는다(그 호출도
//!   30 초를 붙잡힌다).
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
pub const directory_reason = "the file input takes a folder (webkitdirectory) — upload passes files, not folders";
pub const single_reason = "the file input takes one file — give one file, or use an input that allows several (multiple)";
pub const frame_reason = "elements inside frames are not supported yet";
pub const detached_reason = "the file input is not in the page";
pub const page_changed_reason = "the page changed while waiting for approval — no file was set; run upload again";
pub const removed_after_reason = "the file input was removed from the page before maru saw the files arrive — the page may not have them; check the page before trying again";
pub const mismatch_reason = "the page did not get the files as approved (the file input held a different list when they were set) — check the page before trying again";
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

/// 확인 함수(격리 world — 프로토타입 getter 로 읽는다: DOM clobbering). 인자 n = 넣을 파일 수. 승인 뒤(arm 참)에는 통과하면 그 칸에 캡처
/// 단계의 `input`·`change` 듣는 이를 달아, 그 칸에 닿은 진짜 이벤트마다(둘까지) 그때의 목록(이름·크기)을 격리 world 의 `globalThis[key]` 에 적는다.
const check_js =
    "function(n,arm,key){var G=function(p,k){return Object.getOwnPropertyDescriptor(p,k).get};var t=this;" ++
    "if(!(t instanceof Element))return 'not file';" ++
    "if(G(Node.prototype,'ownerDocument').call(t)!==document)return 'frame';" ++
    "if(!G(Node.prototype,'isConnected').call(t))return 'detached';" ++
    "if(!(t instanceof HTMLInputElement)||G(HTMLInputElement.prototype,'type').call(t)!=='file')return 'not file';" ++
    "if(G(HTMLInputElement.prototype,'disabled').call(t)||Element.prototype.matches.call(t,':disabled'))return 'disabled';" ++
    "if(G(HTMLInputElement.prototype,'webkitdirectory').call(t))return 'directory';" ++
    "if(n>1&&!G(HTMLInputElement.prototype,'multiple').call(t))return 'single';" ++
    "if(arm){var D=G(HTMLInputElement.prototype,'files'),L=G(FileList.prototype,'length'),I=FileList.prototype.item,N=G(File.prototype,'name'),Z=G(Blob.prototype,'size');" ++
    "var s={seen:[]};s.h=function(e){if(e.isTrusted!==true||e.target!==t||s.seen.length>=2)return;var f=D.call(t),l=[];" ++
    "if(f)for(var i=0,c=L.call(f);i<c;i++){var x=I.call(f,i);l.push([N.call(x),Z.call(x)])}s.seen.push(l)};" ++
    "var A=EventTarget.prototype.addEventListener;A.call(t,'input',s.h,true);A.call(t,'change',s.h,true);globalThis[key]=s}" ++
    "return 'ok'}";

/// 읽기를 못 하고 끝날 때 듣는 이를 뗀다(같은 objectId·같은 key — 없으면 아무것도 안 한다).
const disarm_js =
    "function(key){var s=globalThis[key];if(!s)return;var R=EventTarget.prototype.removeEventListener;" ++
    "R.call(this,'input',s.h,true);R.call(this,'change',s.h,true);delete globalThis[key]}";

/// 넣은 뒤 읽기(같은 objectId) — 듣는 이를 떼고, 넣을 때 적은 목록(받았나)과 지금 칸(그대로 두었나 — 붙어 있고 같은 목록)을 견준다:
/// `ok`(지금 칸이 같다)·`dropped`(넣을 때 같았는데 지금은 아니다 — 페이지가 받은 뒤 비웠다)·`mismatch`(넣을 때 다른 목록)·`removed`(기록 없이
/// 떨어졌다)·`unseen`(기록 없이 다른 목록).
const verify_js =
    "function(names,sizes,key){var G=function(p,k){return Object.getOwnPropertyDescriptor(p,k).get};var t=this;var s=globalThis[key];" ++
    "var D=G(HTMLInputElement.prototype,'files'),L=G(FileList.prototype,'length'),I=FileList.prototype.item,N=G(File.prototype,'name'),Z=G(Blob.prototype,'size');" ++
    "if(s){var R=EventTarget.prototype.removeEventListener;R.call(t,'input',s.h,true);R.call(t,'change',s.h,true);delete globalThis[key]}" ++
    "var same=function(l){if(!l||l.length!==names.length)return false;for(var i=0;i<l.length;i++)if(l[i][0]!==names[i]||l[i][1]!==sizes[i])return false;return true};" ++
    "var now=null;if(G(Node.prototype,'isConnected').call(t)){var f=D.call(t);now=[];if(f)for(var i=0,c=L.call(f);i<c;i++){var x=I.call(f,i);now.push([N.call(x),Z.call(x)])}}" ++
    "if(same(now))return 'ok';" ++
    "if(s&&s.seen.length){for(var j=0;j<s.seen.length;j++)if(same(s.seen[j]))return 'dropped';return 'mismatch'}" ++
    "return now===null?'removed':'unseen'}";

const Stage = enum { tree, world, resolve, check, release_pre, tree_again, set, verify, disarm, release };

pub const Phase = enum { pre, post };

/// 승인 뒤 넣을 사본 하나(앱이 준다).
pub const Staged = struct { path: []const u8, name: []const u8, size: u64 };

const OwnedStaged = struct { path: []u8, name: []u8, size: u64 };

pub const Op = struct {
    id: u64,
    /// 넣을 파일 수(L2 가 1..10 을 봤다).
    count: usize,
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
    /// 놓은 뒤에 낼 답(소유).
    then: ?struct { status: Status, result: []u8 } = null,
    /// `setFileInputFiles` 를 보냈고 그 답이 「안 했다」(오류·못 보냄)가 아니었다 — 사본이 페이지에 갔을 수 있다(앱이 실패여도 사본을 남긴다).
    given: bool = false,
    /// 승인 뒤 확인이 그 칸에 듣는 이를 달았고 아직 떼지 않았다 — 읽기를 못 하고 끝나면 놓기 앞에서 뗀다(`disarm_js`).
    armed: bool = false,

    pub fn init(count: usize, id: u64) Op {
        return .{ .count = count, .id = id };
    }

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.loader) |s| gpa.free(s);
        if (self.origin) |s| gpa.free(s);
        if (self.frame) |s| gpa.free(s);
        if (self.object) |s| gpa.free(s);
        self.freeStaged(gpa);
        self.staged.deinit(gpa);
        if (self.then) |t| gpa.free(t.result);
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
        self.freeStaged(gpa);
        for (staged) |s| {
            const path = try gpa.dupe(u8, s.path);
            errdefer gpa.free(path);
            const name = try gpa.dupe(u8, s.name);
            errdefer gpa.free(name);
            try self.staged.append(gpa, .{ .path = path, .name = name, .size = s.size });
        }
        self.phase = .post;
        self.stage = .tree;
        if (self.object) |o| gpa.free(o);
        self.object = null;
    }

    /// 철회돼도 보낼 호출인가 — `stage` 는 **곧 보낼** 호출이다. 넣기를 보낸 뒤의 확인(`verify`)과 놓기는 끝까지 보낸다. 넣기(`set`) 자체는
    /// 아니다 — 승인 뒤라도 그 사이 철회·탭 닫힘·시한이면 넣지 않는다(`cancel` 이 놓고 끝낸다).
    pub fn committed(self: *const Op) bool {
        return switch (self.stage) {
            .release_pre, .verify, .disarm, .release => true,
            else => false,
        };
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

    /// 철회 — 원격 객체를 쥐었으면 놓은 뒤 끝낸다. 쥔 것이 없으면 null(부른 쪽이 곧 끝낸다).
    pub fn cancel(self: *Op, gpa: std.mem.Allocator) !?Step {
        return switch (self.stage) {
            .check, .tree_again, .set => try self.releaseThen(gpa, .failed, "the request was cancelled"),
            else => null,
        };
    }

    /// 로케이터가 요소를 찾았다(`web_cdp_ops.Op.scrollStep` 자리). 모달 전이면 그 요소를 쥐고, 승인 뒤면 같은 요소인지 본다.
    pub fn located(self: *Op, gpa: std.mem.Allocator, backend: i64) !Step {
        if (self.phase == .pre) {
            self.backend = backend;
        } else if (backend != self.backend) {
            return done(gpa, .failed, page_changed_reason);
        }
        return self.treeStep(gpa, .tree);
    }

    fn treeStep(self: *Op, gpa: std.mem.Allocator, stage: Stage) !Step {
        self.stage = stage;
        return call(gpa, "Page.getFrameTree", "", .{});
    }

    /// 답을 정해 두고 놓는다 — 듣는 이가 달려 있으면 먼저 뗀다(그 답은 무엇이든 놓기로 간다).
    fn releaseThen(self: *Op, gpa: std.mem.Allocator, status: Status, msg: []const u8) !Step {
        if (self.then) |t| gpa.free(t.result);
        self.then = .{ .status = status, .result = try gpa.dupe(u8, msg) };
        if (self.armed) {
            self.armed = false;
            self.stage = .disarm;
            var key_buf: [snapshot_key.len + 20]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, snapshot_key ++ "{d}", .{self.id}) catch unreachable;
            var step = try call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{f}}}]}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(disarm_js, .{}), std.json.fmt(key, .{}) });
            // 대화상자가 떠 있으면 그것이 사라진 뒤 보낸다(놓기와 같은 줄 — 떼기가 먼저 간다). 곧 거절되면 듣는 이가 남았다(3 회차 nit).
            step.call.after_dialog = true;
            return step;
        }
        return self.releaseCall(gpa, .release);
    }

    fn releaseCall(self: *Op, gpa: std.mem.Allocator, stage: Stage) !Step {
        self.stage = stage;
        return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
    }

    /// 확인의 답(`check_js` 의 글) → 실패 이유(null 이면 통과).
    fn checkReason(self: *const Op, verdict: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, verdict, "ok")) return null;
        if (std.mem.eql(u8, verdict, "frame")) return frame_reason;
        if (std.mem.eql(u8, verdict, "disabled")) return disabled_reason;
        if (std.mem.eql(u8, verdict, "directory")) return directory_reason;
        if (std.mem.eql(u8, verdict, "single")) return single_reason;
        if (std.mem.eql(u8, verdict, "detached")) return if (self.phase == .post) page_changed_reason else detached_reason;
        return not_file_input_reason;
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        // 놓기의 답(무엇이든) — 정해 둔 답으로.
        if (self.stage == .release) {
            const t = self.then orelse return done(gpa, .failed, "internal upload state");
            self.then = null;
            return .{ .done = .{ .status = t.status, .result = t.result } };
        }
        if (self.stage == .release_pre) return self.confirmStep(gpa);
        if (self.stage == .disarm) return self.releaseCall(gpa, .release); // 떼기는 best effort — 답이 무엇이든 놓는다
        const holds = switch (self.stage) {
            .check, .tree_again, .set, .verify => true,
            else => false,
        };
        const bytes = switch (reply) {
            .ok => |b| b,
            .cdp_error => |e| return self.cdpError(gpa, e, holds),
            .timed_out => |why| {
                // 넣기가 `{}` 로 끝난 뒤 읽기가 시한 — 받았다(3 회차 T1). 맨 timeout 은 다시 올리게 했다.
                if (self.stage == .verify) return self.verifyLate(gpa);
                if (self.stage == .set) self.given = true; // 갔는지 모른다 — 사본을 남긴다
                self.armed = false; // 페이지가 답하지 않는다 — 떼기도 붙잡힌다(놓기만)
                return if (holds) self.releaseThen(gpa, .timeout, why) else done(gpa, .timeout, why);
            },
            .failed => |why| {
                // 보낸 넣기·읽기가 대화상자로 끝났다 — 넣기는 갔다(붙잡힌 넣기도 대화상자가 답해지면 마저 돈다, 3 회차 D1).
                if ((self.stage == .set or self.stage == .verify) and std.mem.eql(u8, why, ops.dialog_reason)) return self.dialogShown(gpa);
                if (self.stage == .set) self.given = true;
                self.armed = false; // 탭이 닫혔거나 엔진이 멈췄거나 대화상자가 떴다 — 뗄 곳이 없거나 거절된다
                return if (holds) self.releaseThen(gpa, .failed, why) else done(gpa, .failed, why);
            },
            .not_sent => |why| {
                // 넣은 뒤 읽기를 이동 중이라 보내지 않았다 — 넣기가 이동을 걸었다(2 회차: 「then try again」 이 다시 올리게 했다).
                if (self.stage == .verify and std.mem.eql(u8, why, ops.loading_reason)) return self.navigated(gpa);
                // 넣은 뒤 대화상자가 떠 읽기를 못 보냈다 — 넣기는 `{}` 로 끝났다(3 회차 D1). 넣기 자체를 못 보낸 것은 아래의 실패 그대로(갔다가 아니다).
                if (self.stage == .verify and std.mem.eql(u8, why, ops.dialog_reason)) return self.dialogShown(gpa);
                return if (holds) self.releaseThen(gpa, .failed, why) else done(gpa, .failed, why);
            },
        };
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
            return if (holds) self.releaseThen(gpa, .failed, "malformed DevTools result") else done(gpa, .failed, "malformed DevTools result");
        defer parsed.deinit();
        const v = parsed.value;
        switch (self.stage) {
            .tree, .tree_again => {
                const frame = stringAt(v, &.{ "frameTree", "frame", "id" }) orelse return self.failHolding(gpa, "no main frame");
                const loader = stringAt(v, &.{ "frameTree", "frame", "loaderId" }) orelse return self.failHolding(gpa, "no main frame");
                if (self.phase == .pre and self.stage == .tree) {
                    const origin = stringAt(v, &.{ "frameTree", "frame", "securityOrigin" }) orelse "";
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
                self.context = intAt(v, &.{"executionContextId"}) orelse return done(gpa, .failed, "no isolated world");
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.backend, self.context, self.id });
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return done(gpa, .failed, if (self.phase == .post) page_changed_reason else detached_reason);
                try replace(gpa, &self.object, oid);
                self.stage = .check;
                // 승인 뒤에는 듣는 이를 단다(넣을 때 받은 목록을 적는다) — 모달 전에는 페이지에 아무것도 달지 않는다.
                if (self.phase == .post)
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{d}}},{{\"value\":true}},{{\"value\":\"" ++ snapshot_key ++ "{d}\"}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(check_js, .{}), self.count, self.id });
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":{f},\"arguments\":[{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object.?, .{}), std.json.fmt(check_js, .{}), self.count });
            },
            .check => {
                if (at(v, &.{"exceptionDetails"}) != null) return self.releaseThen(gpa, .failed, check_failed_reason);
                const verdict = stringAt(v, &.{ "result", "value" }) orelse return self.releaseThen(gpa, .failed, check_failed_reason);
                if (self.checkReason(verdict)) |why| return self.releaseThen(gpa, .failed, why);
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
                if (at(v, &.{"exceptionDetails"}) != null) return self.releaseThen(gpa, .failed, mismatch_reason);
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                if (std.mem.eql(u8, verdict, "removed")) return self.releaseThen(gpa, .failed, removed_after_reason);
                if (std.mem.eql(u8, verdict, "unseen")) return self.releaseThen(gpa, .failed, unseen_reason);
                // 넣을 때 받은 목록이 맞으면 성공 — 그 뒤 페이지가 비웠으면 kept:false(다시 올리면 두 번 올라간다).
                const kept = std.mem.eql(u8, verdict, "ok");
                if (!kept and !std.mem.eql(u8, verdict, "dropped")) return self.releaseThen(gpa, .failed, mismatch_reason);
                const result = try self.successJson(gpa, kept, false, false);
                defer gpa.free(result);
                return self.releaseThen(gpa, .success, result);
            },
            .release, .release_pre, .disarm => unreachable, // 위에서
        }
    }

    /// 쥔 객체가 있으면 놓고, 없으면 곧 실패.
    fn failHolding(self: *Op, gpa: std.mem.Allocator, why: []const u8) !Step {
        if (self.stage == .tree_again) return self.releaseThen(gpa, .failed, why);
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
        return self.releaseThen(gpa, .success, result);
    }

    /// 넣기가 `{}` 로 끝난 뒤 읽기가 `verify_wait_ms` 안에 답하지 않았다(3 회차 T1 — 실측: change 처리기가 응답이 늦은 주소로 옮겨 읽기가 확정까지
    /// 붙잡혔다). 처리기는 파일을 받았다 — 성공에 `kept:false`·`navigated:true`(작성자 선택: 「넣었지만 확인 못 함」 실패 대신 2 회차와 같은 답 —
    /// 둘 다 「페이지를 보라, 다시 올리지 마라」 다). 이동이 아니라 페이지가 멈춘 것이어도 같은 답이다(문서의 남는 틈). 떼기·놓기는 보내지 않는다 —
    /// 답하지 않는 페이지에 보내면 그것도 붙잡혀 요청 시한을 넘긴다(묶음·듣는 이는 문서와 함께 사라진다).
    fn verifyLate(self: *Op, gpa: std.mem.Allocator) !Step {
        self.armed = false;
        const result = try self.successJson(gpa, false, true, false);
        return .{ .done = .{ .status = .success, .result = result } };
    }

    /// 넣기를 보낸 뒤 페이지(또는 그 팝업 가족)가 대화상자를 띄웠다(3 회차 D1) — 넣기는 갔다(처리기의 alert 면 이미 받았고, 붙잡힌 넣기는 대화상자가
    /// 답해지면 마저 돈다). 읽을 수 없다: 성공에 `kept:false`·`dialog:true`. 실패로 답하면 에이전트가 대화상자에 답한 뒤 다시 올렸다(모달 둘째·두 번
    /// 올라감). 듣는 이는 떼고 묶음은 놓는다 — 둘 다 대화상자가 사라진 뒤로 미뤄진다(`after_dialog`·web_osr 의 미룬 놓기).
    fn dialogShown(self: *Op, gpa: std.mem.Allocator) !Step {
        self.given = true;
        const result = try self.successJson(gpa, false, false, true);
        defer gpa.free(result);
        return self.releaseThen(gpa, .success, result);
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
        const context_gone = std.mem.indexOf(u8, message, "Cannot find context") != null or std.mem.indexOf(u8, message, "Could not find object") != null;
        if (self.stage == .verify and context_gone) return self.navigated(gpa);
        const gone = context_gone or std.mem.indexOf(u8, message, "No node") != null or std.mem.indexOf(u8, message, "No frame") != null;
        if (context_gone) self.armed = false; // 문서가 사라졌다 — 듣는 이도 함께(노드만 떨어졌으면 문서는 살아 있다 — 뗀다)
        const why: []const u8 = switch (self.stage) {
            .set => if (gone) page_changed_reason else if (std.mem.indexOf(u8, message, "not a file input") != null) not_file_input_reason else message,
            .world, .resolve, .check, .tree, .tree_again => if (gone) (if (self.phase == .post) page_changed_reason else detached_reason) else message,
            else => message,
        };
        return if (holds) self.releaseThen(gpa, .failed, why) else done(gpa, .failed, why);
    }
};

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
