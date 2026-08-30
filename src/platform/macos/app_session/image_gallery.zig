//! 이미지 갤러리 도크 뷰 — 계약은 [docs/agent-image-gallery.md](../../../../docs/agent-image-gallery.md).
//!
//! 지금 하는 일은 하나다: **활성 pane 의 트랜스크립트를 훑어 이미지가 몇 장인지 안다.** 썸네일도 격자도
//! 아직 없다(IG3·IG4). 이 슬라이스의 값어치는 사슬이 실제로 이어지는지 보는 것이다 —
//! 훅 `transcript_path` → `Term.agent_image_source` → 스캔 → 화면.
//!
//! **스캔은 워커가 한다**(계약 §4.1.1). 처음에는 여기서 동기로 훑었는데, 제품 스캐너로 최악 파일을 재니
//! 1,680 MB / **3,599.9 ms** 였다 — 프레임 예산의 216배다. main actor 는 요청을 걸고 완료본을 가져갈 뿐이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
const agent_ops = @import("agent.zig");
const chrome = maru.chrome;
const index = maru.session.agent_image_index;
const scan_backend = @import("../agent_image_scan_backend.zig");
const image_decode = @import("../image_decode.zig");
const decode_backend = @import("../agent_image_decode_backend.zig");
const image_scale = maru.session.image_scale;
const image_grid = maru.session.image_grid;
const image_view = maru.session.image_view;
const context = maru.session.agent_image_context;
const metal_frame = maru.renderer.metal_frame;
const coretext_frame_builder = @import("../coretext_frame_builder.zig");

/// 갤러리가 지금 보여 주는 것. **인덱스는 메모리 전용**이다(계약 §4.5) — 앱을 끄면 사라지고 다음 실행에서
/// 다시 훑는다.
pub const State = struct {
    /// 이 인덱스를 만든(또는 만들고 있는) 파일 **묶음**. 첫 파일이 현재 세션이고, 재개면 부모가
    /// 뒤에 붙는다(§3.3). 활성 Term 의 것과 첫 파일이 다르면 무효다.
    chain: index.Chain = .{},
    /// 스캔이 찾은 **전부**. 필터의 원본이라 여기서는 아무것도 빼지 않는다.
    all_hits: std.ArrayList(index.Hit) = .empty,
    all_labels: std.ArrayList(context.Label) = .empty,
    /// 검색어(+IME 조합). 비면 필터가 꺼진 것이고 `hits` 는 `all_hits` 와 같다.
    ///
    /// 사이드바·find·아카이브 검색과 **같은 `OverlayInput`** 이다 — 한글은 IME 조합으로 들어오므로
    /// 직접 만든 바이트 버퍼로는 애초에 못 받는다. 거르는 데 쓰는 것은 확정된 `query` 뿐이고
    /// `preedit` 는 그리기 전용이다(아카이브 검색과 같은 규율).
    search: chrome.components.overlay_input.OverlayInput = .{},
    /// 검색창이 키를 받고 있나.
    search_active: bool = false,
    /// **지금 보여줄 것**. 필터를 여기에 적용하므로 인덱스 도메인이 하나다 — 타일·크게보기·호버가
    /// 「전체 인덱스인가 표시 인덱스인가」를 물을 필요가 없다.
    hits: std.ArrayList(index.Hit) = .empty,
    /// `hits` 와 **같은 순서·같은 길이**. 스캔 워커가 함께 만든다(§2.2) — 필터가 전부의 라벨을
    /// 필요로 하는데 main actor 에서 읽으면 실측 40.2 ms 다.
    ///
    /// **`hits` 를 건드리는 자리는 이것도 같이 건든다.** 어긋나면 라벨이 남의 이미지에 붙는데,
    /// 그 증상은 「설명이 틀렸다」로 보이지 「인덱스가 어긋났다」로 보이지 않는다.
    labels: std.ArrayList(context.Label) = .empty,
    /// 상한(줄 길이·이미지 수)에 걸려 못 본 것이 있다. 「비었다」와 「못 봤다」는 다른 사실이라 나눠 든다.
    partial: bool = false,
    /// 마지막 스캔이 읽은 바이트와 걸린 시간. 계약 §4.1.1 의 근거가 이 자리에서 나왔다.
    scanned_bytes: u64 = 0,
    scan_ns: u64 = 0,
    /// 결과를 받아 반영했는가. `hits.len == 0` 과 다르다 — 이미지가 없는 파일도 훑은 것이다.
    built: bool = false,
    /// 기다리는 요청의 generation. 0 이면 기다리는 것이 없다. **늦게 온 결과를 버리는 근거**다 —
    /// 소스가 그 사이 바뀌었으면(`/clear`) 그 결과는 남의 파일 것이다.
    awaiting: u64 = 0,
    /// 워커가 바빠 아직 못 건 요청이 있다. 다음 tick 이 다시 건다.
    resubmit: bool = false,
    /// 격자에 자리를 못 얻은 이미지 수. **계산해 두고 안 쓰면 사용자가 이미지를 놓치고도 모른다** —
    /// 「없다」와 「안 보인다」를 가르는 값이다(계약 §2). 매 frame `appendGpuImages` 가 갱신한다.
    overflow: usize = 0,
    /// 지금 디코드를 걸어 둔 요청의 generation. 0 이면 없다. **한 번에 한 장만 푼다** —
    /// 여러 스레드를 띄우면 빨리 차지만 CPU 를 그만큼 먹고, 뷰를 떠나면 그 일이 전부 버려진다.
    decoding: u64 = 0,
    /// 크게 보고 있는 이미지. `null` 이면 격자다. **격자와 배타적**이다 — 둘을 겹쳐 그리면
    /// 어느 것을 누르는지 알 수 없다.
    open: ?Open = null,
    /// 포인터가 얹힌 칸. **`hitTest` 한 곳에서 온다** — 그리기·클릭·호버가 같은 판정을 쓰지 않으면
    /// 강조된 칸과 열리는 칸이 갈린다.
    hovered: ?usize = null,
    /// 갤러리가 키보드를 쥐고 있나. 도크를 눌렀다는 사실이 소유권이고, 터미널을 누르면 놓는다.
    /// **이 게이트가 없으면 vim 의 Esc 가 셸이 아니라 크게 보기를 닫는다**(에이전트 도크가 같은
    /// 이유로 같은 게이트를 둔다).
    key_focus: bool = false,
    /// 격자 세로 스크롤. 도크의 다른 목록과 **같은 상태 타입**을 쓴다(잔여 축적·방향 전환·clamp).
    scroll: maru.chrome.ui.scroll_area.State = .{},
    /// 지금 디코드를 걸어 둔 칸의 인덱스. `decoding != 0` 일 때만 뜻이 있다.
    decoding_index: usize = 0,
    /// 화면에 올린 썸네일. **인덱스와 다르다** — 인덱스는 파일 전체의 «자리» 이고 이것은 지금 보이는
    /// 칸의 «픽셀» 이다. 장당 0.06 MB 라 상한 안에서 상주해도 가볍다(계약 §5.2).
    tiles: std.ArrayList(Tile) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.dropOpen(allocator);
        self.hits.deinit(allocator);
        self.labels.deinit(allocator);
        self.all_hits.deinit(allocator);
        self.all_labels.deinit(allocator);
        self.search.deinit(allocator);
        self.dropTiles(allocator);
        self.tiles.deinit(allocator);
        self.* = .{};
    }

    /// 타일 픽셀은 힘이다 — 소스가 갈리거나 창이 닫히면 반드시 여기서 푼다.
    pub fn dropTiles(self: *State, allocator: std.mem.Allocator) void {
        for (self.tiles.items) |*t| allocator.free(t.pixels);
        self.tiles.clearRetainingCapacity();
    }

    /// **이 프레임에 안 그린 타일은 다시 올려야 한다.** 렌더러는 `live_ids` 에 없는 텍스처를 evict
    /// 하므로(kitty K4c), 한 프레임이라도 빼먹으면 그 텍스처가 사라진다. 그런데 `uploaded` 가 참으로
    /// 남아 있으면 다음에 그릴 때 **업로드 없이 id 만** 실어 **빈 자리**가 된다.
    ///
    /// 실제로 그렇게 났다: 크게 보기를 열면 격자 타일이 한 프레임도 안 실려 전부 evict 되고, 닫으면
    /// 라벨(글자)만 보이고 그림이 없다. 스크롤로 창 밖에 나갔다 돌아올 때도 같다.
    pub fn markAllNeedUpload(self: *State) void {
        for (self.tiles.items) |*tile| tile.uploaded = false;
    }

    /// 크게 보기의 픽셀도 owned 다 — 소스가 갈리거나 닫을 때 반드시 여기서 푼다.
    pub fn dropOpen(self: *State, allocator: std.mem.Allocator) void {
        if (self.open) |*op| allocator.free(op.pixels);
        self.open = null;
    }

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.dropOpen(allocator);
        self.dropTiles(allocator);
        self.hits.clearAndFree(allocator);
        self.labels.clearAndFree(allocator);
        self.all_hits.clearAndFree(allocator);
        self.all_labels.clearAndFree(allocator);
        self.search.clear();
        self.search_active = false;
        self.chain.clear();
        self.partial = false;
        self.scanned_bytes = 0;
        self.scan_ns = 0;
        self.built = false;
        self.awaiting = 0;
        self.resubmit = false;
        self.decoding = 0;
        self.overflow = 0;
        self.scroll = .{};
        self.decoding_index = 0;
        self.hovered = null;
    }

    /// 그 칸의 타일이 있으면 준다. **`hit_index` 가 유일 키다** — 배열 위치가 아니다.
    pub fn tileFor(self: *State, hit_index: usize) ?*Tile {
        for (self.tiles.items) |*tile| {
            if (tile.hit_index == hit_index) return tile;
        }
        return null;
    }

    /// 상한을 넘으면 **지금 창에서 가장 먼** 타일을 버린다. 스크롤로 멀어진 것부터 나가므로
    /// 되돌아올 때 바로 앞뒤는 남아 있다.
    pub fn evictFarthest(self: *State, allocator: std.mem.Allocator, center: usize) void {
        while (self.tiles.items.len > max_tiles) {
            var worst: usize = 0;
            var worst_d: usize = 0;
            for (self.tiles.items, 0..) |tile, i| {
                const d = if (tile.hit_index > center) tile.hit_index - center else center - tile.hit_index;
                if (d >= worst_d) {
                    worst_d = d;
                    worst = i;
                }
            }
            allocator.free(self.tiles.items[worst].pixels);
            _ = self.tiles.swapRemove(worst);
        }
    }

    /// 지금 **거르는 데 쓰는** 검색어. 조합 중인 글자(`preedit`)는 아직 확정이 아니라 뺀다.
    pub fn queryText(self: *const State) []const u8 {
        return self.search.query.items;
    }

    /// 검색어에 맞는 것만 `hits`/`labels` 에 남긴다. **원본은 안 건드린다.**
    ///
    /// 실패(할당)하면 **필터를 끈 상태**로 되돌린다 — 걸러진 목록을 반쯤 만들어 두면 사용자는 왜 어떤
    /// 이미지가 사라졌는지 알 수 없다. 전부 보여주는 쪽이 정직하다.
    pub fn applyFilter(self: *State, allocator: std.mem.Allocator) void {
        self.hits.clearRetainingCapacity();
        self.labels.clearRetainingCapacity();
        const q = self.queryText();
        const paired = self.all_labels.items.len == self.all_hits.items.len;
        for (self.all_hits.items, 0..) |hit, i| {
            const label: context.Label = if (paired) self.all_labels.items[i] else .{};
            if (q.len > 0 and !context.matches(label.text(), q)) continue;
            self.hits.append(allocator, hit) catch {
                self.search.clear();
                self.hits.clearRetainingCapacity();
                self.labels.clearRetainingCapacity();
                self.hits.appendSlice(allocator, self.all_hits.items) catch {};
                self.labels.appendSlice(allocator, self.all_labels.items) catch {};
                return;
            };
            self.labels.append(allocator, label) catch {};
        }
    }

    pub fn count(self: *const State) usize {
        return self.hits.items.len;
    }

    /// 결과를 기다리는 중인가. 「세는 중」과 「없다」를 가르는 근거다 — 3.6 초 동안
    /// 「이미지가 없습니다」라고 거짓말하지 않기 위해 필요하다.
    pub fn scanning(self: *const State) bool {
        return self.awaiting != 0 or self.resubmit;
    }
};

/// 화면에 올린 썸네일 하나.
pub const Tile = struct {
    /// 인덱스의 몇 번째 이미지인가. 격자 자리와 `hits` 를 잇는 유일한 키다.
    hit_index: usize,
    width: u32,
    height: u32,
    /// RGBA8, **owned**. `State.dropTiles` 가 푼다.
    pixels: []u8,
    /// 이 픽셀의 세대. 렌더러가 `image_id` 로 텍스처를 캐시하므로 **바뀔 때만** 다시 올린다.
    generation: u64,
    /// 이미 GPU 로 보냈는가. 매 프레임 보내면 15 MB 를 초당 60번 복사한다.
    uploaded: bool = false,
    /// 「이게 무엇이었는지」 한 줄(§2.2). **타일마다 한 번만 읽는다** — 매 프레임 파일을 열면
    /// 도크가 초당 60번 IO 를 한다. 빈 라벨도 「읽어 봤고 없었다」로 확정된 값이다.
    label: context.Label = .{},
};

/// 크게 보고 있는 한 장. 썸네일(`Tile`)과 **다른 픽셀**이다 — 이쪽은 텍스처 상한 안에서 원본 배율로
/// 푼 것이라 장당 수 MB 다. 그래서 한 장만 들고, 닫으면 바로 푼다.
pub const Open = struct {
    /// 인덱스의 몇 번째인가. 격자로 돌아가지 않아도 「무엇을 보고 있는지」의 유일한 키다.
    hit_index: usize,
    /// 팬·줌 상태. `scale == 0` 은 「아직 안 정했다」로, `image_view.clamp` 가 fit 으로 채운다.
    view: image_view.View = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// RGBA8, **owned**. 길이 0 은 「아직 못 풀었다」거나 「못 푼다」이며, `decoding` 이 그 둘을 가른다.
    pixels: []u8 = &.{},
    uploaded: bool = false,
    /// 이 요청의 generation. 0 이면 도는 것이 없다 — `pixels` 가 비어 있는데 이 값도 0 이면 **실패**다.
    decoding: u64 = 0,
};

/// 갤러리 썸네일용 예약 kitty image id 시작점. 배경(`0xFFFF_FFFF`)과 kitty 프로그램 id(보통 작은 값)
/// 사이에 둔다 — 같은 텍스처 캐시를 쓰므로 id 가 겹치면 남의 그림이 나온다.
pub const gallery_image_id_base: u32 = 0xFFF0_0000;

/// 검색어 상한(바이트). 아카이브 검색과 같은 값이다.
pub const max_query_bytes: usize = 256;

/// 동시에 픽셀을 들고 있는 타일 수 상한. 장당 0.06 MB 이므로 256장이면 15 MB 다.
pub const max_tiles: usize = 256;

/// 크게 보기 텍스처의 예약 id. 썸네일 구간 **뒤**에 둔다 — 겹치면 크게 보기를 닫았을 때 그 텍스처가
/// 어느 칸의 썸네일로 되살아난다.
///
/// 썸네일 id 는 **`hit_index` 로 짓는다**(배열 위치가 아니라). 배열 위치로 지으면 퇴출·추가로 위치가
/// 바뀔 때 같은 타일의 id 가 달라지고, 두 타일이 id 를 맞바꾸면 한 프레임 동안 엉뚱한 그림이 뜬다.
/// 그래서 구간을 인덱스 상한(`max_hits_per_file`)만큼 잡는다 — 0xFFF0_0000 위로 백만 개가 남아 있어
/// 배경(0xFFFF_FFFF)과 부딪히지 않는다.
pub const gallery_open_image_id: u32 = gallery_image_id_base +| 0x10000;

/// 활성 Term 의 트랜스크립트 경로. 없으면 null — 에이전트가 붙지 않은 pane(셸만 띄운 창)이 그렇다.
///
/// **탭이 0 개인 창을 먼저 막는다.** merge/이동으로 비워진 뒤 Swift 가 닫기 전 tick 이 있고, 그때
/// `activePane()` 이 빈 리스트를 인덱싱해 패닉한다(`handleDroppedImage` 가 같은 이유로 같은 가드를 둔다).
fn activeSourcePath(self: *AppSession) ?[]const u8 {
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    // 훅이 아직 한 번도 안 돌았으면 자식 env 로 확정해 둔 파일로 메운다(추측이 아니다 — 사이드바
    // 대화 라벨이 읽고 있는 그 파일이다). 훅이 나중에 오면 그 값이 이긴다.
    agent_ops.adoptFallbackImageSource(self, term);
    if (term.agent_image_source.isEmpty()) return null;
    return term.agent_image_source.path();
}

/// 이 트랜스크립트가 재개/fork 라면 **부모까지** 잇는다(계약 §3.3).
///
/// **왜 필요한가**: `compacted` 를 건너뛰는 규칙은 「원본이 같은 파일 앞쪽에 있다」를 전제하는데,
/// 재개 세션에서는 그 원본이 **부모 파일**에 있다. 실측 90 파일 중 20개(22%)에서 42 장을 잃고,
/// 최악은 살아 있는 것이 0 장이라 갤러리가 「이미지가 없습니다」라고 말한다.
///
/// **비용은 실측으로 안다**: fork 가 172/296(58%), 체인 깊이 중앙 1·최대 2, 부모 크기 중앙 338 MB·
/// 최대 1.8 GB. 그래서 상한은 `max_chain`(3)이고, 스캔은 **현재 파일부터** 끝낸다(§4.1.1).
///
/// codex 전용이다 — claude 는 `/clear` 가 새 파일을 만들 뿐 이전 대화를 압축해 싣지 않으므로 잃는
/// 것이 없다(그리고 부모를 가리키는 기록도 없다).
fn buildChain(self: *AppSession, head_path: []const u8) index.Chain {
    var chain: index.Chain = .{};
    if (!chain.append(head_path)) return chain;
    if (!builtin.target.os.tag.isDarwin()) return chain;

    const io = self.io;
    const home_z = std.c.getenv("HOME") orelse return chain;
    const home = std.mem.span(home_z);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = std.fmt.bufPrint(&root_buf, "{s}/.codex/sessions", .{home}) catch return chain;
    // head 가 codex rollout 이 아니면 볼 것이 없다(claude 는 부모 개념이 없다).
    if (!std.mem.startsWith(u8, head_path, root_path)) return chain;

    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur: []const u8 = head_path;
    while (chain.len < index.max_chain) {
        var id_buf: [128]u8 = undefined;
        const parent_id = readCodexParentId(self, cur, &id_buf);
        if (parent_id.len == 0) break;

        const root = std.Io.Dir.openDirAbsolute(io, root_path, .{}) catch break;
        defer root.close(io);
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        var suffix_buf: [160]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "{s}.jsonl", .{parent_id}) catch break;
        // **`findCodexByThreadId` 는 단순 `endsWith` 다.** 그대로 믿으면 `…-Xparent-id.jsonl` 이
        // `parent-id` 의 것으로 잡힌다. 찾은 이름을 `isCodexRolloutOf` 로 한 번 더 본다 —
        // id 앞이 구분자여야 그 세션의 파일이다.
        const rel = maru.session.agent_transcript.findCodexByThreadId(io, root, suffix, &rel_buf) orelse break;
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |at| rel[at + 1 ..] else rel;
        if (!maru.session.agent_transcript.isCodexRolloutOf(base, parent_id)) break;
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root_path, rel }) catch break;
        if (!chain.append(abs)) break; // 상한이거나 이미 담긴 경로(자기 자신을 가리키는 기록)

        // 다음 바퀴를 위해 방금 담은 경로를 들고 간다(`abs_buf` 는 이 반복에서 죽는다).
        if (abs.len > cur_buf.len) break;
        @memcpy(cur_buf[0..abs.len], abs);
        cur = cur_buf[0..abs.len];
    }
    return chain;
}

/// 그 rollout 의 첫 줄에서 부모 신원을 읽는다. **첫 줄만** 읽는다 — `session_meta` 가 첫 줄이고,
/// 뒤 레코드의 같은 키를 집으면 남의 부모가 붙는다.
fn readCodexParentId(self: *AppSession, path: []const u8, out: []u8) []const u8 {
    const io = self.io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return "";
    defer file.close(io);
    // **실측이 크기를 정한다**: `session_meta` 첫 줄이 중앙 18,994 B · 최대 22,079 B 이고 296개 중
    // 292개가 8 KiB 를 넘는다. 8 KiB 였을 때 부모 키가 창 안에 든 것은 **운**이었다(초과 0건) —
    // `instructions` 가 조금만 길어지면 조용히 못 읽는다. 최대의 3배로 잡는다.
    var head: [64 * 1024]u8 = undefined;
    const n = file.readPositional(io, &.{&head}, 0) catch return "";
    if (n == 0) return "";
    return maru.session.agent_transcript.parseCodexParentId(head[0..n], out);
}

fn backendPtr(self: *AppSession) ?*scan_backend.Backend {
    if (self.image_gallery_backend) |*b| return b;
    return null;
}

fn decodeBackendPtr(self: *AppSession) ?*decode_backend.Backend {
    if (self.image_gallery_decode_backend) |*b| return b;
    return null;
}

/// 갤러리 인덱스를 활성 pane 에 맞춘다. **파일을 여기서 읽지 않는다** — 워커에 요청만 건다.
///
/// 호출자는 둘이다: 뷰에 들어올 때(`setDockView`)와 소스가 바뀐 것을 훅이 알려 줬을 때.
pub fn refresh(self: *AppSession, force: bool) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    const path = activeSourcePath(self) orelse {
        if (self.image_gallery.built or self.image_gallery.scanning() or !self.image_gallery.chain.isEmpty()) {
            backend.cancel();
            if (decodeBackendPtr(self)) |d| d.cancel();
            self.image_gallery.clear(self.allocator);
            self.metal_dirty = true;
        }
        return;
    };
    const same = std.mem.eql(u8, self.image_gallery.chain.head(), path);
    if (!force and same and (self.image_gallery.built or self.image_gallery.scanning())) return;

    // 소스가 갈렸다 = 다른 세션이다(`/clear` 는 새 파일을 만든다). 옛 파일의 오프셋은 새 파일에서
    // 아무 뜻이 없으므로 통째로 버리고 다시 건다. 도는 스캔도 취소한다.
    backend.cancel();
    if (decodeBackendPtr(self)) |d| d.cancel(); // 옛 파일의 오프셋으로 도는 디코드를 버린다
    self.image_gallery.clear(self.allocator);
    self.image_gallery.chain = buildChain(self, path);
    self.metal_dirty = true;

    if (backend.submit(self.image_gallery.chain)) |generation| {
        self.image_gallery.awaiting = generation;
    } else {
        // 워커가 바쁘다(직전 스캔이 아직 도는 중). 다음 tick 이 다시 건다.
        self.image_gallery.resubmit = true;
    }
}

/// tick 마다 부른다. 완료본을 가져오고, 못 걸었던 요청을 다시 건다.
///
/// **여기가 유일한 수확 지점이다.** 안 부르면 워커가 다 훑고도 화면이 영영 안 바뀐다.
pub fn poll(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;

    if (self.image_gallery.resubmit and !self.image_gallery.chain.isEmpty()) {
        if (backend.submit(self.image_gallery.chain)) |generation| {
            self.image_gallery.awaiting = generation;
            self.image_gallery.resubmit = false;
        }
    }

    harvestDecoded(self);
    ensureOpen(self);

    var result = backend.take() orelse return;
    // **늦게 온 것은 버린다.** 소스가 그 사이 바뀌었으면 이 결과는 남의 파일 것이다.
    if (result.generation != self.image_gallery.awaiting) {
        result.deinit(self.allocator);
        return;
    }
    self.image_gallery.all_hits.deinit(self.allocator);
    self.image_gallery.all_hits = result.hits; // 소유 이동 — 여기서부터 세션이 푼다
    self.image_gallery.all_labels.deinit(self.allocator);
    self.image_gallery.all_labels = result.labels;
    // 길이가 어긋나면 라벨을 통째로 버린다 — 남의 이미지에 붙은 설명보다 없는 편이 낫다.
    if (self.image_gallery.all_labels.items.len != self.image_gallery.all_hits.items.len) {
        self.image_gallery.all_labels.clearRetainingCapacity();
    }
    // **최신이 먼저다.** 스캐너는 파일 순서(= 오래된 것부터)로 담는데, 이 기능의 물음은
    // 「**아까** 그 스크린샷 어디 갔지」다. 실제 세션으로 재 보니 151 장 중 4 장만 보이는데
    // 그 4 장이 세션 맨 처음 것이었다 — 목적과 정확히 반대였다(합성 픽스처는 4 장이 다 보여
    // 이 결함을 원리적으로 못 본다).
    std.mem.reverse(index.Hit, self.image_gallery.all_hits.items);
    // **라벨도 같이 뒤집는다.** 안 뒤집으면 첫 칸에 마지막 이미지의 설명이 붙는다.
    if (self.image_gallery.all_labels.items.len == self.image_gallery.all_hits.items.len) {
        std.mem.reverse(context.Label, self.image_gallery.all_labels.items);
    }
    // 원본이 바뀌었으니 보여줄 목록을 다시 만든다(검색어가 비면 전부).
    self.image_gallery.applyFilter(self.allocator);
    // **인덱스가 갈리면 그 위에 쌓인 것도 버린다.** 지금은 `refresh` 가 `clear` 를 먼저 하므로
    // 여기 도달할 때 둘 다 비어 있지만, 그 순서에 기대면 나중에 점진 publish 를 붙이는 순간
    // 타일과 크게 보기가 **옛 인덱스**를 가리킨 채 남는다 — 「엉뚱한 이미지가 뜬다」로 보이지
    // 「비었다」로 보이지 않아 알아채기 어렵다. 불변식은 가정하지 말고 강제한다.
    self.image_gallery.dropTiles(self.allocator);
    self.image_gallery.dropOpen(self.allocator);
    // **호버도 옛 인덱스다.** 이미지가 줄면 없는 칸을 가리키고, 안 줄어도 그 자리엔 다른 이미지가
    // 온다(최신 우선이라 순서가 통째로 바뀐다). 다음 마우스 이동이 다시 잡는다.
    self.image_gallery.hovered = null;
    self.image_gallery.partial = result.partial;
    self.image_gallery.scanned_bytes = result.scanned_bytes;
    self.image_gallery.scan_ns = result.scan_ns;
    self.image_gallery.built = true;
    self.image_gallery.awaiting = 0;
    self.image_gallery.resubmit = false;
    self.metal_dirty = true;
    // 디버그 훅(`MARU_FORCE_IMAGE_GALLERY_OPEN`)이 예약해 둔 크게 보기를 **여기서** 연다 — 인덱스가
    // 방금 생겼기 때문이다. 예약은 한 번만 쓴다.
    if (self.debug_image_gallery_open) |n| {
        self.debug_image_gallery_open = null;
        openAt(self, n);
    }
    // `MARU_FORCE_IMAGE_GALLERY_HOVER=<n>` — 그 칸에 포인터가 얹힌 것처럼 세운다. 실제 호버는 마우스
    // 이동이 필요해 헤드리스로는 만들 수 없다(상태바 호버가 같은 이유로 같은 게이트를 둔다).
    if (self.debug_image_gallery_hover) |n| {
        self.debug_image_gallery_hover = null;
        if (n < self.image_gallery.count()) self.image_gallery.hovered = n;
    }
}

/// 격자에 보이는 칸만큼 타일을 채운다. **tick 당 최대 하나만 푼다.**
///
/// 장당 ~20 ms 라(계약 §5.2) 24칸을 한 프레임에 풀면 480 ms 가 멈춘다. 한 장씩 차오르게 두면 각 프레임은
/// 한 장 몫만 쓰고 격자가 눈앞에서 채워진다. **이것은 워커의 대체가 아니라 그 전 단계다** — 한 장 20 ms 도
/// 프레임 예산(16.7 ms)을 넘으므로, 디코드 워커는 후속에서 붙인다.
pub fn ensureTiles(self: *AppSession, first: usize, visible: usize) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = decodeBackendPtr(self) orelse return;
    // **크게 보기가 워커를 먼저 쓴다.** 사용자가 방금 누른 것보다 아직 안 보이는 칸이 급할 리 없다.
    if (self.image_gallery.open != null) return;
    if (self.image_gallery.decoding != 0) return; // 이미 한 장 도는 중
    if (self.image_gallery.chain.isEmpty()) return;

    // **보이는 칸 중 아직 없는 것**을 채운다. 창을 통째로 버리지 않는 이유는 그렇게 하면 스크롤할
    // 때마다 격자가 ~160 ms(8장 × 20 ms) 비어 깜빡이기 때문이다. 상한(`max_tiles` = 15 MB)은
    // 계약 §5.2 가 허용하는 값이고 실측 세션이 151 장이라 실제로는 거의 안 걸린다.
    const last = @min(first +| visible, self.image_gallery.count());
    var next: usize = first;
    while (next < last) : (next += 1) {
        if (self.image_gallery.tileFor(next) == null) break;
    }
    if (next >= last) return; // 보이는 칸이 다 찼다

    const hit = self.image_gallery.hits.items[next];
    const path = pathFor(self, hit) orelse return;
    if (backend.submit(
        path,
        hit.data_offset,
        hit.data_len,
        thumbnail_side,
        next,
    )) |generation| {
        self.image_gallery.decoding = generation;
        self.image_gallery.decoding_index = next;
    }
}

/// 디코드 완료본을 수확한다. `poll` 이 tick 마다 부른다.
///
/// **순서를 지킨다** — 다음에 채울 칸(`tiles.len`)의 것이 아니면 버린다. 순서가 어긋나면 격자의 그림과
/// 인덱스가 갈리는데, 그것은 「엉뚱한 이미지가 뜬다」로 보이지 「비었다」로 보이지 않아 알아채기 어렵다.
fn harvestDecoded(self: *AppSession) void {
    const backend = decodeBackendPtr(self) orelse return;
    var r = backend.take() orelse return;
    defer r.deinit(self.allocator); // 아래에서 소유를 옮기면 pixels 를 비워 둔다

    // **크게 보기 것이 먼저다.** 두 요청은 같은 워커를 쓰므로 generation 으로 가른다.
    if (self.image_gallery.open) |*op| {
        if (op.decoding != 0 and r.generation == op.decoding) {
            op.decoding = 0;
            self.allocator.free(op.pixels);
            op.width = r.width;
            op.height = r.height;
            op.pixels = r.pixels;
            r.pixels = &.{}; // 소유가 넘어갔다
            op.uploaded = false;
            op.view = .{}; // 새 픽셀이면 fit 부터 — 옛 배율은 다른 이미지의 것이다
            self.metal_dirty = true;
            return;
        }
    }

    if (r.generation != self.image_gallery.decoding) return; // 늦게 온 것
    self.image_gallery.decoding = 0;
    // **내가 건 그 칸의 것인가.** 배열 위치가 아니라 인덱스로 판정한다 — 스크롤이 배열 순서를
    // 바꾸므로 순서로 판정하면 결과가 조용히 버려진다.
    if (r.hit_index != self.image_gallery.decoding_index) return;
    if (self.image_gallery.tileFor(r.hit_index) != null) return; // 이미 있다(중복 제출 방어)

    // **못 푼 것도 자리를 차지한다.** 안 그러면 그 칸에서 매 tick 다시 시도해 뒤 칸이 영영 안 찬다.
    self.image_gallery.tiles.append(self.allocator, .{
        .hit_index = r.hit_index,
        .width = r.width,
        .height = r.height,
        .pixels = r.pixels,
        .generation = 1,
        .label = labelFor(self, r.hit_index),
    }) catch return;
    r.pixels = &.{}; // 소유가 타일로 넘어갔다 — defer 가 두 번 풀지 않게 비운다
    self.image_gallery.evictFarthest(self.allocator, r.hit_index);
    self.metal_dirty = true;
}

/// 훅이 소스를 바꿨을 때. **갤러리를 보고 있을 때만 건다** — 안 보는 뷰 때문에 1.68 GB 를 훑지 않는다.
/// 보고 있지 않으면 다음에 들어올 때 `refresh` 가 경로 불일치를 보고 알아서 건다.
pub fn onSourceChanged(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return;
    refresh(self, false);
}

/// 갤러리를 떠날 때. 도는 스캔을 취소한다 — 안 보는 화면 때문에 3.6 초를 끝까지 돌 이유가 없다.
pub fn onLeaveView(self: *AppSession) void {
    self.image_gallery.search_active = false;
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    backend.cancel();
    if (decodeBackendPtr(self)) |d| d.cancel();
    self.image_gallery.awaiting = 0;
    self.image_gallery.resubmit = false;
    self.image_gallery.decoding = 0;
    // 크게 보기도 닫는다 — 원본 픽셀은 수 MB 라, 안 보는 뷰 때문에 들고 있을 이유가 없다.
    self.image_gallery.dropOpen(self.allocator);
    self.image_gallery.key_focus = false;
}

/// 격자 썸네일의 한 변(px). 계약 §5.2 — 장당 0.06 MB 라 200장 상주해도 12 MB 다. 원본 해상도로 들면
/// 200장에 3.6 GB 라 불가능하다.
pub const thumbnail_side: u32 = 160;

/// 인덱스의 `n` 번째 이미지를 썸네일로 푼다. 실패는 `null` — 「이미지가 깨졌다」는 그리지 않는 것으로 답한다.
///
/// **바이트를 여기서 처음 읽는다.** 인덱스는 자리만 들고 있으므로(계약 §4) 그 구간을 그때 읽어 base64 를
/// 풀고 ImageIO 에 넘긴다. 이미지 하나가 수 MB 라 인덱스가 픽셀을 들면 목록 하나에 수백 MB 가 앉는다.
///
/// 순서가 계약이다: **크기를 먼저 묻고(probe) → 계수를 고르고(`image_scale`) → 그 계수로 푼다.**
/// 크기를 알자고 원본을 통째로 푸는 것은 앞뒤가 바뀐 일이고, 계수를 안 고르고 올리면 상한 초과에서
/// **프로세스가 abort** 한다(계약 §5.3).
pub fn decodeThumbnail(self: *AppSession, n: usize) ?image_decode.Decoded {
    if (!builtin.target.os.tag.isDarwin()) return null;
    if (n >= self.image_gallery.hits.items.len) return null;
    if (self.image_gallery.chain.isEmpty()) return null;
    const hit = self.image_gallery.hits.items[n];

    const io = self.io;
    const path = pathFor(self, hit) orelse return null;
    const file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return null;
    defer file.close(io);

    const b64 = self.allocator.alloc(u8, hit.data_len) catch return null;
    defer self.allocator.free(b64);
    var got: usize = 0;
    while (got < b64.len) {
        const n_read = file.readPositional(io, &.{b64[got..]}, hit.data_offset + got) catch return null;
        if (n_read == 0) return null; // 파일이 그 사이 잘렸다
        got += n_read;
    }

    // base64 는 표준 알파벳 + 패딩이다(provider 가 그렇게 쓴다). 길이를 먼저 물어 버퍼를 잡는다.
    const dec = std.base64.standard.Decoder;
    const raw_len = dec.calcSizeForSlice(b64) catch return null;
    const raw = self.allocator.alloc(u8, raw_len) catch return null;
    defer self.allocator.free(raw);
    dec.decode(raw, b64) catch return null;

    const size = image_decode.probeSize(raw) catch return null;
    const fit = image_scale.fitToThumbnail(
        size.width,
        size.height,
        thumbnail_side,
        image_scale.default_max_side,
        image_scale.default_max_pixels,
    ) orelse return null; // 상한을 못 맞추면 **안 그린다** — 억지로 올리면 abort 다
    return image_decode.decode(self.allocator, raw, fit.subsample) catch null;
}

/// 크게 보기가 쓸 영역(backing px). 격자와 같은 본문에서 여백만 뺀다 — 두 모드가 같은 자리를 쓰므로
/// 전환할 때 그림이 튀지 않는다.
pub fn viewportRect(self: *const AppSession) image_view.Rect {
    const a = gridArea(self);
    const pad = gridMetrics(self).pad;
    return .{
        .x = @floatFromInt(a.x +| pad),
        .y = @floatFromInt(a.y +| pad),
        .w = @floatFromInt(a.w -| (pad *| 2)),
        .h = @floatFromInt(a.h -| (pad *| 2)),
    };
}

/// `n` 번째 이미지를 크게 연다. **픽셀은 여기서 안 푼다** — 워커에 요청만 걸고, 그동안 격자가 계속 보인다.
/// 다 풀리기 전에 격자를 지우면 클릭이 「화면이 비었다」로 보인다.
pub fn openAt(self: *AppSession, n: usize) void {
    if (n >= self.image_gallery.count()) return;
    self.image_gallery.dropOpen(self.allocator);
    self.image_gallery.open = .{ .hit_index = n };
    // **격자를 그 칸으로 맞춰 둔다.** 클릭으로 열 때는 이미 보이므로 아무 일도 없고, ←→ 로 멀리
    // 넘어갔을 때만 움직인다 — 그러지 않으면 닫는 순간 격자가 **옛 자리**를 보여주고 방금 보던
    // 이미지가 화면 밖에 있다. 여는 자리 한 곳에서 하므로 두 입구가 갈리지 않는다.
    self.image_gallery.scroll.offset_y_px = image_grid.scrollToShow(
        gridArea(self),
        gridMetrics(self),
        self.image_gallery.count(),
        self.image_gallery.scroll.offset_y_px,
        n,
    );
    self.metal_dirty = true;
    ensureOpen(self);
}

/// 크게 보기에서 다음(+1)·이전(-1)으로 넘긴다. 소비했으면 `true`.
///
/// **이 기능의 목적이 「비슷한 것 여럿에서 고르기」다.** 썸네일은 160 px 라 내용을 못 읽으니 결국
/// 하나씩 열어 보게 되는데, 넘기기가 없으면 열고 닫기를 반복해야 한다.
///
/// 끝에서는 **멈춘다**(순환하지 않는다). 순환하면 끝에 닿았다는 것을 알 수 없어 같은 것을 두 번
/// 본다 — 151 장짜리 실제 세션에서는 그 차이가 크다.
pub fn navigateOpen(self: *AppSession, delta: i32) bool {
    if (!ownsKeys(self)) return false;
    if (self.image_gallery.search_active) return false; // 타이핑 중 화살표는 검색창 것이다
    const op = if (self.image_gallery.open) |o| o else return false;
    const count = self.image_gallery.count();
    if (count == 0) return false;

    const cur: i64 = @intCast(op.hit_index);
    const next = cur + delta;
    if (next < 0 or next >= @as(i64, @intCast(count))) return true; // 끝 — 소비는 하되 안 움직인다
    const target: usize = @intCast(next);
    if (target == op.hit_index) return true;
    openAt(self, target);
    return true;
}

/// 크게 보기를 닫고 격자로 돌아간다. 원본 픽셀(수 MB)을 여기서 푼다.
pub fn closeOpen(self: *AppSession) void {
    if (self.image_gallery.open == null) return;
    self.image_gallery.dropOpen(self.allocator);
    self.metal_dirty = true;
}

/// 크게 보기의 원본을 워커에 건다. 워커가 바쁘면 다음 tick 이 다시 건다(`poll`).
///
/// **`target_side = 0` 이 썸네일과 다른 전부다** — 목표 크기를 안 주면 `image_scale` 이 텍스처 상한만
/// 지키고 되도록 원본에 가깝게 푼다(계약 §5.3). 상한을 못 맞추는 이미지는 애초에 안 푼다.
pub fn ensureOpen(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const op = if (self.image_gallery.open) |*o| o else return;
    if (op.pixels.len > 0 or op.decoding != 0) return;
    if (self.image_gallery.chain.isEmpty()) return;
    if (op.hit_index >= self.image_gallery.count()) return;
    const backend = decodeBackendPtr(self) orelse return;

    const hit = self.image_gallery.hits.items[op.hit_index];
    const path = pathFor(self, hit) orelse return;
    if (backend.submit(
        path,
        hit.data_offset,
        hit.data_len,
        0, // 원본 배율(상한 안에서)
        op.hit_index,
    )) |generation| {
        op.decoding = generation;
    }
}

/// 휠·트랙패드로 **포인터를 붙잡고** 확대·축소한다. 가운데 기준이면 보려던 곳이 밖으로 밀려나
/// 매번 팬으로 쫓아가야 한다(계산은 `image_view.zoomAt`).
///
/// 트랙패드(`precise`)는 점 단위라 눈금보다 훨씬 촘촘히 온다 — 같은 계수를 쓰면 한 번 쓸어도 최대
/// 배율에 닿는다. 그래서 계수를 나누고, 한 이벤트가 만드는 배율 변화를 e^±1 로 묶는다.
pub fn wheelZoom(self: *AppSession, delta_y: f64, precise: bool, x_px: f64, y_px: f64) void {
    const op = if (self.image_gallery.open) |*o| o else return;
    if (op.pixels.len == 0) return;
    if (!std.math.isFinite(delta_y) or delta_y == 0) return;
    const per: f64 = if (precise) 0.006 else 0.12;
    // 위로 굴리면 확대다(`lines > 0` = wheel up, 스크롤백과 같은 부호 규약).
    const factor: f32 = @floatCast(@exp(std.math.clamp(delta_y * per, -1.0, 1.0)));
    op.view = image_view.zoomAt(op.view, viewportRect(self), op.width, op.height, factor, @floatCast(x_px), @floatCast(y_px));
    self.metal_dirty = true;
}

/// 드래그로 민다. **화면 이동량 그대로**다 — 잡은 곳이 손끝을 따라와야 한다.
pub fn panDrag(self: *AppSession, dx: f64, dy: f64) void {
    const op = if (self.image_gallery.open) |*o| o else return;
    if (op.pixels.len == 0) return;
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
    op.view = image_view.panBy(op.view, viewportRect(self), op.width, op.height, @floatCast(dx), @floatCast(dy));
    self.metal_dirty = true;
}

/// 검색어가 바뀐 뒤 목록을 다시 만든다.
///
/// **그 위에 쌓인 것을 전부 버린다.** 타일·크게보기·호버는 옛 인덱스를 가리키고 필터는 순서를 통째로
/// 바꾼다 — 안 버리면 「엉뚱한 이미지가 뜬다」가 되는데 그 증상은 원인을 짐작하기 어렵다. 스크롤도
/// 처음으로 돌린다(걸러진 목록의 세 번째 행부터 보여 줄 이유가 없다).
pub fn rebuildFilter(self: *AppSession) void {
    self.image_gallery.applyFilter(self.allocator);
    self.image_gallery.dropTiles(self.allocator);
    self.image_gallery.dropOpen(self.allocator);
    self.image_gallery.hovered = null;
    self.image_gallery.scroll = .{};
    self.metal_dirty = true;
}

/// 검색창을 연다(⌘F). 갤러리를 보고 있을 때만 뜻이 있다.
pub fn focusSearch(self: *AppSession) bool {
    // **갤러리가 키를 쥐고 있을 때만**이다. 도크가 보인다는 것만으로 열면, 터미널에 타이핑하던 사용자의
    // ⌘F 가 터미널 찾기 대신 갤러리 검색을 연다.
    if (!ownsKeys(self)) return false;
    self.image_gallery.search_active = true;
    self.metal_dirty = true;
    return true;
}

/// 검색창이 키·IME 를 쥐고 있나. `AppSession.inputFocus` 의 유일한 근거다 — 조합 글자가 뒤 터미널로
/// 새지 않으려면 이 판정이 focus 표에 올라 있어야 한다(설정 검색이 한때 빠져 있어 새던 그 자리다).
pub fn searchOwnsInput(self: *const AppSession) bool {
    return self.image_gallery.search_active and ownsKeys(self);
}

/// 검색창이 키를 받는다. 소비했으면 `true`.
///
/// **검색 중에는 Esc 도 화살표도 검색창 것이다** — 타이핑하다 Esc 로 검색을 접는 것이 자연스럽고,
/// 그 사이 크게 보기 넘기기가 끼어들면 놀랍다. 여기 오는 `.char` 는 ASCII 직접 입력뿐이고, 한글을
/// 비롯한 조합 입력은 `imeSetPreedit`/`commitPreedit` 로 들어온다.
pub fn handleSearchKey(self: *AppSession, event: maru.terminal.KeyEvent) bool {
    if (!searchOwnsInput(self)) {
        self.image_gallery.search_active = false; // 뷰가 바뀌었다 — 창은 닫고 키는 넘긴다
        return false;
    }
    switch (event.key) {
        .escape => {
            // 첫 Esc 는 **검색어만** 지운다(창은 열어 둔다). 다 지운 뒤 Esc 면 창을 닫는다 —
            // 한 번에 닫으면 오타 하나 물리려다 검색을 통째로 잃는다.
            if (self.image_gallery.search.query.items.len > 0 or
                self.image_gallery.search.preedit.items.len > 0)
            {
                self.image_gallery.search.clear();
                rebuildFilter(self);
            } else {
                self.image_gallery.search_active = false;
                self.metal_dirty = true;
            }
        },
        .enter => {
            // 확정 = 창만 닫고 **검색어는 유지**한다. 걸러진 목록에서 그대로 고르게 된다.
            self.image_gallery.search_active = false;
            self.metal_dirty = true;
        },
        .backspace => {
            if (self.image_gallery.search.query.items.len == 0) return true;
            self.image_gallery.search.backspace(); // codepoint 단위 — 바이트로 지우면 한글이 깨진다
            rebuildFilter(self);
        },
        .char => |codepoint| {
            if (event.modifiers.command or event.modifiers.control or event.modifiers.option) return false;
            if (self.image_gallery.search.query.items.len + 4 > max_query_bytes) return true;
            self.image_gallery.search.appendChar(self.allocator, codepoint) catch return true;
            rebuildFilter(self);
        },
        // **그 밖의 키는 삼키지 않는다.** 검색 중이라는 이유로 전부 먹으면 도크에서 나갈 길이 막힌다.
        else => return false,
    }
    return true;
}

/// IME 후보창을 띄울 자리 — 검색줄 caret 셀. 검색 중이 아니면 `null`(터미널 커서로 폴백).
///
/// **조합 중인 글자 뒤에 둔다**: 후보창이 preedit 앞에 붙으면 한글을 고르는 동안 후보창이 자기가 친
/// 글자를 가린다.
/// 검색줄이 쓸 수 있는 칸 수. 알림 줄과 **같은 폭**이다(같은 자리를 쓰므로).
fn searchLineCols(self: *const AppSession) u32 {
    const cw = self.cell_width_px;
    if (cw == 0) return 0;
    return dock_ops.dockGeometry(self).tree_content.w / cw;
}

pub fn searchCaretRect(self: *const AppSession) ?chrome.draw.Rect {
    if (!searchOwnsInput(self)) return null;
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    // 그려진 줄(`noticeText`)과 **같은 셈법**이어야 한다 — 다르면 후보창이 글자와 어긋난 자리에 뜬다.
    const prompt_cols = chrome.components.overlay_input.displayCols(maru.i18n.t(.image_gallery_search_prompt));
    const pre_cols = chrome.components.overlay_input.displayCols(self.image_gallery.search.preedit.items);
    const text_cols = searchLineCols(self) -| prompt_cols;
    const q_tail = chrome.components.overlay_input.tailWindow(self.image_gallery.search.query.items, text_cols -| pre_cols);
    const cols = prompt_cols +| chrome.components.overlay_input.displayCols(q_tail.text) +| pre_cols;
    // 줄 끝을 넘지 않게 — 넘으면 후보창이 도크 밖에 뜬다.
    const max_x = content.x +| content.w -| cw;
    return .{
        .x = @intCast(@min(content.x +| cols *| cw, max_x)),
        .y = @intCast(content.y),
        .w = cw,
        .h = ch,
    };
}

/// 갤러리가 키보드를 쥐고 있나. 에이전트 도크와 같은 게이트다 — 이것이 없으면 터미널로 돌아간 뒤의
/// Esc 가 셸이 아니라 크게 보기를 닫는다.
pub fn ownsKeys(self: *const AppSession) bool {
    return dock_ops.dockVisible(self) and self.dock.view == .image_gallery and self.image_gallery.key_focus;
}

/// 터미널을 눌렀다 = 키보드를 놓는다. **크게 보기는 그대로 둔다** — 보던 것을 클릭 한 번에 잃지 않는다.
pub fn releaseKeyFocus(self: *AppSession) void {
    if (!self.image_gallery.key_focus) return;
    self.image_gallery.key_focus = false;
    self.metal_dirty = true;
}

/// Esc. 크게 보기를 닫는다. 소비했으면 `true`.
pub fn handleEscape(self: *AppSession) bool {
    if (!ownsKeys(self)) return false;
    if (self.image_gallery.open == null) return false;
    closeOpen(self);
    return true;
}

/// 포인터가 얹힌 칸을 갱신한다. 얹힌 칸이 있으면 `true` — 호출자가 커서를 손가락으로 바꾼다.
///
/// **판정은 `handleDown` 과 같은 `hitTest` 다.** 여기서 따로 재면 강조된 칸과 열리는 칸이 갈리는데,
/// 그 어긋남은 「누른 것과 다른 게 열린다」로 보이지 「호버가 틀렸다」로 보이지 않아 찾기 어렵다.
///
/// 크게 보기 중에는 격자가 없으므로 호버도 없다.
pub fn handleHover(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (!builtin.target.os.tag.isDarwin()) return false;
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return clearHover(self);
    if (self.image_gallery.open != null) return clearHover(self);

    const area = gridArea(self);
    if (x_px < @as(f64, @floatFromInt(area.x)) or y_px < @as(f64, @floatFromInt(area.y))) return clearHover(self);
    if (x_px >= @as(f64, @floatFromInt(area.x +| area.w)) or y_px >= @as(f64, @floatFromInt(area.y +| area.h))) {
        return clearHover(self);
    }

    const px: u32 = @intFromFloat(@max(0, x_px));
    const py: u32 = @intFromFloat(@max(0, y_px));
    const hit = image_grid.hitTest(area, gridMetrics(self), gridLayout(self), px, py);
    if (hit != self.image_gallery.hovered) {
        self.image_gallery.hovered = hit;
        self.metal_dirty = true;
    }
    return hit != null;
}

/// 호버를 놓는다. 얹힌 칸이 없다는 뜻이므로 `false`.
pub fn clearHover(self: *AppSession) bool {
    if (self.image_gallery.hovered != null) {
        self.image_gallery.hovered = null;
        self.metal_dirty = true;
    }
    return false;
}

/// 도크 본문 primary down. 소비했으면 `true`.
///
/// 두 모드가 다르다 — 격자에서는 **칸을 눌러 연다**, 크게 보기에서는 **이미지 밖을 눌러 닫는다**.
/// 이미지 위는 아직 아무 일도 하지 않는다(팬은 IG4-c).
pub fn handleDown(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return false;
    const gx = gridArea(self);
    if (x_px < @as(f64, @floatFromInt(gx.x)) or y_px < @as(f64, @floatFromInt(gx.y))) return false;
    if (x_px >= @as(f64, @floatFromInt(gx.x +| gx.w)) or y_px >= @as(f64, @floatFromInt(gx.y +| gx.h))) return false;
    self.image_gallery.key_focus = true;

    if (self.image_gallery.open) |*op| {
        if (op.pixels.len == 0) return true; // 아직 못 풀었다 — 격자가 보이지만 클릭은 삼킨다
        const vp = viewportRect(self);
        const r = image_view.destRect(op.view, vp, op.width, op.height);
        const fx: f32 = @floatCast(x_px);
        const fy: f32 = @floatCast(y_px);
        const inside = fx >= r.x and fy >= r.y and fx < r.x + r.w and fy < r.y + r.h;
        // 이미지 위 = 잡고 밀기, 밖 = 닫기. **밖을 닫기로 둔 이유**는 크게 보기가 도크를 통째로
        // 덮어 「어디를 눌러야 돌아가지」의 답이 하나뿐이기 때문이다(Esc 와 짝).
        if (inside) {
            self.beginPointerGesture(.{ .image_gallery_pan = .{ .x = x_px, .y = y_px } });
        } else closeOpen(self);
        return true;
    }

    const m = gridMetrics(self);
    const l = gridLayout(self);
    const px: u32 = @intFromFloat(@max(0, x_px));
    const py: u32 = @intFromFloat(@max(0, y_px));
    if (image_grid.hitTest(gx, m, l, px, py)) |n| openAt(self, n);
    return true;
}

/// 그 hit 의 오프셋이 가리키는 **파일**. 체인이 여럿이면 `file_index` 가 유일한 답이다 —
/// 첫 파일로 고정하면 부모 이미지를 현재 파일에서 읽어 엉뚱한 바이트를 디코드한다.
fn pathFor(self: *const AppSession, hit: index.Hit) ?[]const u8 {
    return self.image_gallery.chain.get(hit.file_index);
}

/// 그 칸의 라벨. **스캔 워커가 이미 만들어 뒀다** — 예전에는 타일이 생길 때 파일을 열어 읽었는데,
/// 그러면 보이는 칸만 라벨이 있어 필터가 성립하지 않는다(§2.2).
fn labelFor(self: *const AppSession, hit_index: usize) context.Label {
    const labels = self.image_gallery.labels.items;
    return if (hit_index < labels.len) labels[hit_index] else .{};
}

/// 격자가 쓸 영역(backing px). 도크 본문에서 **문구 한 줄을 늘 뺀다.**
///
/// 문구(`noticeText`)는 `tree_content` 의 첫 행에 그려진다. 격자가 그 자리를 같이 쓰면 「12장 중 8장」이
/// 이미지 위에 겹쳐 찍힌다 — letterbox 여백이 있는 이미지는 우연히 안 겹치고 **정사각 이미지에서만**
/// 드러나, 보고도 재현이 안 되는 종류가 된다.
///
/// **「문구가 보일 때만 비운다」로 하지 않는다.** 그러면 비우는 순간 용량이 줄어 `overflow` 가 커지고,
/// 그 값이 다시 문구를 띄우는 되먹임이 된다 — 한 프레임 안에서 배치의 답이 두 개가 된다.
pub fn gridArea(self: *const AppSession) image_grid.Rect {
    const g = dock_ops.dockGeometry(self);
    const notice_h: u32 = if (self.cell_height_px > 0) self.cell_height_px else app_session_mod.placeholder_cell_height_px;
    return .{
        .x = g.tree_content.x,
        .y = g.tree_content.y +| notice_h,
        .w = g.tree_content.w,
        .h = g.tree_content.h -| notice_h,
    };
}

/// 타일 한 변(backing px). 썸네일 텍스처(160)와 **다를 수 있다** — 화면 크기는 레이아웃이,
/// 텍스처 크기는 디코드가 정한다. 지금은 같은 값을 쓰되 그 둘을 한 상수로 묶지 않는다.
pub fn gridMetrics(self: *const AppSession) image_grid.Metrics {
    // **타일은 정사각이 아니다.** 실측(실제 트랜스크립트 600장)에서 가로/세로 비율 중앙이 2.00 이고
    // 79% 가 가로로 길다 — 정사각으로 두면 타일의 절반 이상이 여백이고, 같은 도크 높이에 들어가는
    // 칸이 절반(4칸 대 8칸)이 된다. 151 장짜리 실제 세션에서는 그 차이가 크게 느껴진다.
    return .{
        .tile = thumbnail_side,
        .tile_h = thumbnail_side / 2,
        .gap = 8,
        .pad = 8,
        .label = labelHeightPx(self),
    };
}

/// 타일 아래 라벨 한 줄의 높이(backing px). 도크 글자 한 줄과 같다 — 다른 값을 쓰면 글자가
/// 자기 자리 밖으로 나가거나 빈 띠가 남는다.
pub fn labelHeightPx(self: *const AppSession) u32 {
    return if (self.cell_height_px > 0) self.cell_height_px else app_session_mod.placeholder_cell_height_px;
}

/// 크게 보기 한 장을 얹는다. **뷰포트 밖은 UV 로 잘라 낸다** — 확대하면 그림이 도크보다 커지는데,
/// 안 자르면 터미널 위로 넘쳐 흐른다(kitty graphics 이미지 quad 에는 scissor 가 없다).
fn appendOpenImage(
    self: *AppSession,
    op: *Open,
    images: *[]metal_frame.GpuImage,
    uploads: *[]metal_frame.GpuImageUpload,
    pixels: *[]u8,
    live_ids: *std.ArrayList(u32),
) void {
    const vp = viewportRect(self);
    const r = image_view.destRect(op.view, vp, op.width, op.height);
    if (r.w <= 0 or r.h <= 0) return;

    // 보이는 부분만 남긴다.
    const x0 = @max(r.x, vp.x);
    const y0 = @max(r.y, vp.y);
    const x1 = @min(r.x + r.w, vp.x + vp.w);
    const y1 = @min(r.y + r.h, vp.y + vp.h);
    if (x1 <= x0 or y1 <= y0) return; // 통째로 밖이다 — clamp 가 막지만 한 겹 더 둔다

    const id = gallery_open_image_id;
    const img: metal_frame.GpuImage = .{
        .image_id = id,
        .dest_x = x0,
        .dest_y = y0,
        .dest_w = x1 - x0,
        .dest_h = y1 - y0,
        .origin_x = 0,
        .origin_y = 0,
        .src_u0 = (x0 - r.x) / r.w,
        .src_v0 = (y0 - r.y) / r.h,
        .src_u1 = (x1 - r.x) / r.w,
        .src_v1 = (y1 - r.y) / r.h,
        .z = 0,
        .pass = 2, // above_text
    };
    live_ids.append(self.allocator, id) catch {};

    const merged_images = self.allocator.alloc(metal_frame.GpuImage, images.len + 1) catch return;
    @memcpy(merged_images[0..images.len], images.*);
    merged_images[images.len] = img;
    self.allocator.free(images.*);
    images.* = merged_images;

    if (op.uploaded) return;
    const merged_uploads = self.allocator.alloc(metal_frame.GpuImageUpload, uploads.len + 1) catch return;
    const merged_pixels = std.mem.concat(self.allocator, u8, &.{ pixels.*, op.pixels }) catch {
        self.allocator.free(merged_uploads);
        return;
    };
    @memcpy(merged_uploads[0..uploads.len], uploads.*);
    merged_uploads[uploads.len] = .{
        .image_id = id,
        .width = op.width,
        .height = op.height,
        .bpp = 4,
        .generation = 1,
        .pixels_offset = pixels.len,
        .pixels_len = op.pixels.len,
    };
    self.allocator.free(uploads.*);
    self.allocator.free(pixels.*);
    uploads.* = merged_uploads;
    pixels.* = merged_pixels;
    op.uploaded = true;
}

/// 썸네일 **아래 라벨**을 프레임에 얹는다(§2.2). 그림만으로는 비슷한 스크린샷 열두 장에서 원하는
/// 것을 못 고른다 — 이 한 줄이 그 문제를 푼다.
///
/// **자리는 `image_grid` 가 준다**(`labelRectAt`). 여기서 좌표를 다시 풀면 글자가 그림에서 밀린다.
/// 크게 보기 중에는 아무것도 그리지 않는다 — 그때 격자는 화면에 없다.
pub fn collectLabels(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return;
    if (self.image_gallery.open != null) return;
    if (self.image_gallery.tiles.items.len == 0) return;

    const area = gridArea(self);
    const m = gridMetrics(self);
    const l = gridLayout(self);
    if (l.visible == 0) return;
    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };

    for (self.image_gallery.tiles.items) |*tile| {
        const text = tile.label.text();
        if (text.len == 0) continue; // 없는 설명을 지어내지 않는다 — 빈 칸이 낫다
        const rect = image_grid.labelRectAt(area, m, l, tile.hit_index) orelse continue;
        const cols: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), rect.w / self.cell_width_px));
        if (cols == 0) continue;
        const dl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, cols, text, fg) catch continue;
        self.collectShaped(collected, dl, builder, .{ .pane = .{
            .origin_x = rect.x,
            .origin_y = rect.y,
            .colors = colors,
        } });
    }
}

/// 지금 프레임의 격자 배치. **그리기·hit-test·스크롤 상한이 모두 이 하나를 쓴다** — 각자 계산하면
/// 스크롤한 뒤 누른 자리와 열리는 것이 어긋난다.
pub fn gridLayout(self: *const AppSession) image_grid.Layout {
    return image_grid.layout(
        gridArea(self),
        gridMetrics(self),
        self.image_gallery.count(),
        self.image_gallery.scroll.offset_y_px,
    );
}

/// 휠로 격자를 굴린다. 크게 보기 중에는 `wheelZoom` 이 가져가므로 여기 오지 않는다.
pub fn wheelScroll(self: *AppSession, delta_y: f64, precise: bool, x_px: f64, y_px: f64) bool {
    const l = gridLayout(self);
    if (l.max_scroll == 0) return false; // 굴릴 것이 없다 — 이벤트를 삼키지 않는다
    // 트랙패드(precise)는 논리 픽셀, 눈금은 한 번에 한 행. 도크 목록과 같은 규약이다.
    const unit: f64 = if (precise)
        @as(f64, @floatFromInt(if (self.scale_milli > 0) self.scale_milli else 1000)) / 1000.0
    else
        @floatFromInt(gridMetrics(self).tile +| gridMetrics(self).label +| gridMetrics(self).gap);
    // **부호를 여기서 뒤집지 않는다.** `scrollByWheel` 이 이미 `scrollByPx(-whole)` 로 뒤집으므로
    // 한 번 더 뒤집으면 위아래가 반대가 된다(에이전트 도크도 `delta_y` 를 그대로 넘긴다).
    if (self.image_gallery.scroll.scrollByWheel(delta_y, unit, l.max_scroll)) {
        // **굴리면 커서 아래 칸이 바뀐다.** 포인터는 그대로인데 격자가 움직였으므로, 옛 칸이 강조된 채
        // 남거나(다른 그림이 그 자리에 온다) 강조가 사라진다. 마우스가 다시 움직일 때까지 그 상태로
        // 있으므로 여기서 같은 좌표로 다시 잡는다.
        _ = handleHover(self, x_px, y_px);
        self.metal_dirty = true;
        return true;
    }
    return true; // 경계에서도 소비한다 — 안 그러면 제스처가 뒤 터미널로 샌다
}

/// 얹힌 칸 **뒤에 판을 깐다.** 그림만 있으면 누를 수 있는 것인지 알 수 없다 — 커서 변화와 짝이다.
///
/// **이미지에 색을 입히지 않는다.** `GpuImage` 에 tint 를 더하려면 extern 구조체 ABI 와 셰이더까지
/// 건드려야 하고, 무엇보다 원본 색이 달라지면 「그 스크린샷 색이 이랬나」가 흔들린다 — 갤러리는 바로
/// 그것을 보는 곳이다. 판은 **칸 전체**를 덮으므로 letterbox 여백까지 밝아져 호버 범위가 그대로 보인다.
///
/// 크게 보기 중에는 격자가 없으니 아무것도 안 그린다.
pub fn appendHoverQuad(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return;
    if (self.image_gallery.open != null) return;
    const n = self.image_gallery.hovered orelse return;

    const area = gridArea(self);
    const l = gridLayout(self);
    const cell = image_grid.rectAt(area, gridMetrics(self), l, n) orelse return;

    // 전경색을 옅게. 배경색을 쓰면 어두운 테마에서 안 보이고, 강조색을 새로 정하면 테마와 논다.
    const color: u32 = app_session_mod.packRgbAlpha(self.appearance.theme.sidebar_foreground, hover_ring_alpha);
    self.gpu_quads.append(self.allocator, .{
        .x = @floatFromInt(cell.x),
        .y = @floatFromInt(cell.y),
        .w = @floatFromInt(cell.w),
        .h = @floatFromInt(cell.h),
        .corner_radii = .{ 4, 4, 4, 4 },
        // **테두리만** 그린다(네 변). 채우면 그림 위에 얹히는 층이라 썸네일이 그 색에 잠긴다 —
        // 셰이더가 fill alpha 0 과 border alpha 를 섞으므로 테두리만 남는다.
        .border_widths = .{ hover_ring_px, hover_ring_px, hover_ring_px, hover_ring_px },
        .fill_color0 = 0,
        .fill_color1 = 0,
        .border_color = color,
        .gradient_kind = 0,
        // **프레임 레이어다.** 예전에는 0 이었는데 그 값은 사이드바가 소유한 «유지» 버킷이라
        // `dropQuadsByLayer` 가 안 건드린다 — 얹은 칸마다 테두리가 영구히 쌓였다(사용자 보고).
        .layer = hover_layer,
    }) catch {};
}

/// 얹힌 칸 테두리의 레이어. **프레임마다 비운다** — `renderFrame` 의 drop 과 짝이다.
///
/// 값이 0·1·2·3·4 가 아니면 렌더러는 «over» 버킷에 넣는다(기본 분기). 0 을 쓰면 안 된다: 그 값은
/// 사이드바 밴드가 소유하는 유지 버킷이라 비워지지 않는다.
pub const hover_layer: u32 = 6;

/// 얹힌 칸 테두리의 두께·불투명도. 보이되 **원본을 가리지 않는** 선이다.
pub const hover_ring_px: f32 = 2;
pub const hover_ring_alpha: u8 = 140;

/// 갤러리 타일을 프레임의 이미지 채널에 얹는다.
///
/// **배경 이미지(`window.background-image`)와 같은 패턴이다** — 예약 id · `live_ids` 등록 ·
/// generation 이 바뀐 것만 업로드. 렌더러를 고치지 않고 kitty graphics 의 텍스처 캐시·image quad
/// 인프라를 그대로 재사용한다(계약 §5.4).
///
/// 실패는 조용히 «안 그림» 이다 — 할당이 모자라는 프레임에 도크를 통째로 멈추지 않는다.
pub fn appendGpuImages(
    self: *AppSession,
    images: *[]metal_frame.GpuImage,
    uploads: *[]metal_frame.GpuImageUpload,
    pixels: *[]u8,
    live_ids: *std.ArrayList(u32),
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    // 도크가 안 보이거나 다른 뷰면 이 프레임에 타일이 하나도 안 실린다 = 전부 evict 된다.
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) {
        self.image_gallery.markAllNeedUpload();
        return;
    }

    const area = gridArea(self);
    const m = gridMetrics(self);
    const l = gridLayout(self);
    // **자리를 못 얻은 수를 남긴다.** 0 칸이어도(좁은 도크) 남겨야 「없다」로 거짓말하지 않는다.
    self.image_gallery.overflow = l.overflow;

    // **크게 보기는 격자를 대체한다.** 겹쳐 그리면 어느 것을 누르는지 알 수 없다. 다만 아직 못 푼
    // 동안에는 격자를 그대로 둔다 — 클릭 직후 화면이 비면 「눌렀더니 사라졌다」로 보인다.
    if (self.image_gallery.open) |*op| {
        if (op.pixels.len > 0) {
            // 크게 보기가 격자를 **대체**하므로 타일이 하나도 안 실린다 — 닫을 때 다시 올려야 한다.
            self.image_gallery.markAllNeedUpload();
            appendOpenImage(self, op, images, uploads, pixels, live_ids);
            return;
        }
    }

    if (l.visible == 0) {
        self.image_gallery.markAllNeedUpload();
        return;
    }

    // 보이는 창만큼 채운다(tick 당 한 장). 다 차기 전에도 있는 것부터 그린다.
    ensureTiles(self, l.first, l.visible);

    var new_images: std.ArrayList(metal_frame.GpuImage) = .empty;
    defer new_images.deinit(self.allocator);
    var new_uploads: std.ArrayList(metal_frame.GpuImageUpload) = .empty;
    defer new_uploads.deinit(self.allocator);
    var new_pixels: std.ArrayList(u8) = .empty;
    defer new_pixels.deinit(self.allocator);

    for (self.image_gallery.tiles.items, 0..) |*tile, i| {
        const n = tile.hit_index; // **자리는 인덱스가 정한다** — 배열 순서가 아니다
        if (tile.pixels.len == 0) continue; // 못 푼 이미지는 자리만 차지하고 안 그린다
        const cell = image_grid.rectAt(area, m, l, n) orelse {
            // 창 밖이라 안 그린다 = 이 프레임에 evict 된다. 돌아올 때 다시 올려야 한다.
            tile.uploaded = false;
            continue;
        };
        // **비율을 지켜 가운데**. 늘리면 스크린샷 글자가 찌그러지고 자르면 무엇인지 못 알아본다.
        const r = image_grid.fitInside(cell, tile.width, tile.height);
        // id 는 **인덱스**로 짓는다 — 배열 위치는 퇴출·추가로 바뀐다(위 주석).
        const id: u32 = gallery_image_id_base +| @as(u32, @intCast(@min(n, 0xFFFF)));

        new_images.append(self.allocator, .{
            .image_id = id,
            .dest_x = @floatFromInt(r.x),
            .dest_y = @floatFromInt(r.y),
            .dest_w = @floatFromInt(r.w),
            .dest_h = @floatFromInt(r.h),
            .origin_x = 0,
            .origin_y = 0,
            .src_u0 = 0,
            .src_v0 = 0,
            .src_u1 = 1,
            .src_v1 = 1,
            .z = @intCast(@min(i, 255)),
            .pass = 2, // above_text — 도크 배경 셀 위에 그린다
        }) catch {
            self.image_gallery.markAllNeedUpload();
            return;
        };
        live_ids.append(self.allocator, id) catch {};

        if (!tile.uploaded) {
            new_uploads.append(self.allocator, .{
                .image_id = id,
                .width = tile.width,
                .height = tile.height,
                .bpp = 4,
                .generation = tile.generation,
                .pixels_offset = pixels.len + new_pixels.items.len,
                .pixels_len = tile.pixels.len,
            }) catch {
                self.image_gallery.markAllNeedUpload();
                return;
            };
            new_pixels.appendSlice(self.allocator, tile.pixels) catch {
                self.image_gallery.markAllNeedUpload();
                return;
            };
            tile.uploaded = true;
        }
    }
    if (new_images.items.len == 0) return;

    // 기존 배열 뒤에 잇는다(배경 이미지가 앞에 prepend 되는 것과 짝 — pass 순서를 지킨다).
    // **여기서 나가면 이 프레임에 아무것도 안 실린다** = 전부 evict 인데 `uploaded` 는 참이다.
    // 방금 고친 것과 같은 결함이라 같은 규율로 막는다 — 안 그리고 나가는 길은 예외 없이 표시한다.
    const merged_images = self.allocator.alloc(metal_frame.GpuImage, images.len + new_images.items.len) catch {
        self.image_gallery.markAllNeedUpload();
        return;
    };
    @memcpy(merged_images[0..images.len], images.*);
    @memcpy(merged_images[images.len..], new_images.items);
    self.allocator.free(images.*);
    images.* = merged_images;

    if (new_uploads.items.len > 0) {
        // 이미지는 이미 실렸지만 **업로드가 빠지면** 텍스처 없는 id 가 실려 빈 자리가 된다.
        const merged_uploads = self.allocator.alloc(metal_frame.GpuImageUpload, uploads.len + new_uploads.items.len) catch {
            self.image_gallery.markAllNeedUpload();
            return;
        };
        const merged_pixels = std.mem.concat(self.allocator, u8, &.{ pixels.*, new_pixels.items }) catch {
            self.allocator.free(merged_uploads);
            self.image_gallery.markAllNeedUpload();
            return;
        };
        @memcpy(merged_uploads[0..uploads.len], uploads.*);
        @memcpy(merged_uploads[uploads.len..], new_uploads.items);
        self.allocator.free(uploads.*);
        self.allocator.free(pixels.*);
        uploads.* = merged_uploads;
        pixels.* = merged_pixels;
    }
}

/// 도크 본문에 낼 한 줄. 아직 격자가 없으므로 개수와 상태만 말한다.
///
/// **넷을 가른다** — 「에이전트가 없다」·「세는 중」·「훑었는데 없다」·「못 봤다」. 접으면 사용자가
/// «이미지가 없는 것» 과 «아직 세는 중» 과 «갤러리가 고장난 것» 을 구분할 수 없다.
pub fn noticeText(self: *const AppSession, buf: []u8) []const u8 {
    // **검색줄이 가장 먼저다.** 타이핑 중인데 「12장 중 8장」이 떠 있으면 자기가 친 글자를 못 본다.
    // 조합 중인 글자(`preedit`)도 붙여 그린다 — 한글은 확정 전에 보이지 않으면 못 친다.
    if (searchOwnsInput(self)) {
        const prompt = maru.i18n.t(.image_gallery_search_prompt);
        const q = self.image_gallery.search.query.items;
        const pre = self.image_gallery.search.preedit.items;
        // 도크는 좁다. 길어지면 **뒤쪽**을 보인다 — 앞을 보이면 방금 친 글자가 화면 밖이라 자기가
        // 무엇을 치고 있는지 알 수 없다(`tailWindow` 가 아카이브 검색에서 하는 것과 같은 일).
        const line_cols = searchLineCols(self);
        const prompt_cols = chrome.components.overlay_input.displayCols(prompt);
        const text_cols = line_cols -| prompt_cols;
        const q_tail = chrome.components.overlay_input.tailWindow(q, text_cols -| chrome.components.overlay_input.displayCols(pre));
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ prompt, q_tail.text, pre }) catch buf[0..0];
    }
    // **크게 보기가 먼저다.** 열려 있으면 격자 개수는 지금 사용자가 보는 것과 무관하다.
    if (self.image_gallery.open) |op| {
        if (op.pixels.len > 0) return "";
        // 도는 것이 없는데 픽셀도 없다 = 못 풀었다. 조용히 닫으면 클릭이 안 먹은 것처럼 보인다.
        if (op.decoding == 0) return maru.i18n.t(.image_gallery_open_failed);
    }
    if (self.image_gallery.chain.isEmpty()) return maru.i18n.t(.image_gallery_no_agent);
    if (self.image_gallery.scanning()) return maru.i18n.t(.image_gallery_scanning);
    const n = self.image_gallery.count();
    // **「못 읽었다」는 찾은 것이 있을 때만 말한다**(사용자 보고). 대화 기록이 비어 있으면 스캔이
    // partial 로 끝나기 쉬운데, 그때 「세션을 다 읽지 못했습니다」라고 하면 사용자에게는 갤러리가
    // 고장난 것으로 보인다 — 실제로는 **없는 것**이다.
    //
    // 다만 **한 바이트도 못 읽었으면**(`scanned_bytes == 0`) 그건 진짜로 못 읽은 것이다(파일 없음·
    // 열기 실패). 그때까지 「없다」로 뭉개면 갤러리가 멀쩡한 줄 안다 — IG1-e 가 그 자리를 잡았다.
    if (self.image_gallery.partial and (n > 0 or self.image_gallery.scanned_bytes == 0)) {
        return maru.i18n.t(.image_gallery_partial);
    }
    if (n == 0) {
        // 거르고 있는데 0 이면 「세션에 이미지가 없다」가 **아니다**. 그렇게 말하면 사용자는 검색어를
        // 지울 생각을 못 하고 갤러리가 고장났다고 읽는다.
        if (self.image_gallery.queryText().len > 0) return maru.i18n.t(.image_gallery_no_match);
        return maru.i18n.t(.image_gallery_empty);
    }
    // 격자가 다 보여 주면 문구를 겹쳐 내지 않는다 — 개수는 격자 자체가 말한다.
    // **다 못 보여 줄 때만 말한다**: 「12장 중 8장」. 이 줄이 없으면 사용자는 4장을 놓치고도 모른다.
    if (self.image_gallery.tiles.items.len > 0) {
        if (self.image_gallery.overflow == 0) return "";
        return maru.i18n.format(buf, maru.i18n.t(.image_gallery_shown_of), &.{
            .{ .d = @intCast(n - self.image_gallery.overflow) },
            .{ .d = @intCast(n) },
        });
    }
    // 문구가 안 들어가면 개수를 지어내지 않는다 — 빈 문자열이 낫다.
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, maru.i18n.t(.image_gallery_count_suffix) }) catch buf[0..0];
}
