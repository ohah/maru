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
const ssh_upload = @import("../ssh_upload.zig"); // RAV5b: 원격 펼침이 구간을 당겨온다
const wire = maru.session.remote_activity_wire;
const body_backend = @import("../agent_body_search_backend.zig");
const image_decode = @import("../image_decode.zig");
const decode_backend = @import("../agent_image_decode_backend.zig");
const image_scale = maru.session.image_scale;
const image_grid = maru.session.image_grid;
const image_view = maru.session.image_view;
const context = maru.session.agent_image_context;
const context_mod = context;
const metal_frame = maru.renderer.metal_frame;
const coretext_frame_builder = @import("../coretext_frame_builder.zig");

/// 갤러리를 보고 있는 동안 **파일이 자랐는지** 이따금 본다.
///
/// 훅에 기대지 않는 이유: 훅이 꺼져 있을 수 있고(계약 §4.4), 켜져 있어도 `UserPromptSubmit` 은
/// 이미지가 파일에 적히기 **전에** 올 수 있다. `stat` 은 싸므로 직접 본다.
///
/// **스로틀이 필요하다**: 이 함수는 60 Hz 로 불린다. 그대로 두면 초당 60 번 파일을 연다.
fn pollFreshness(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    if (self.agent_activity.chain.isEmpty() or !self.agent_activity.built) return;
    if (self.agent_activity.scanning()) return;
    // **크게 보기 중에는 미룬다.** 다시 훑으면 새 이미지가 맨 앞에 와 인덱스가 전부 밀리므로
    // (최신 우선, §IG7) 열어 둔 칸이 다른 그림이 된다. 닫으면 다음 tick 이 잡는다 —
    // 에이전트가 줄 하나 적었다고 보던 이미지가 바뀌는 것보다 잠깐 낡은 편이 낫다.
    if (self.agent_activity.open != null) return;

    // **단조 시계다.** 벽시계(`Clock.real`)는 NTP 보정으로 뒤로 갈 수 있고, 그러면 아래 뺄셈이
    // 0 으로 포화해 자동 갱신이 그 시간만큼 **조용히 멈춘다**. 「얼마나 지났나」는 `awake` 가 답한다.
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.awake.now(self.io).nanoseconds, std.time.ns_per_ms));
    // 그래도 뒤로 간 값이 보이면(시계 구현이 보장을 못 지키면) **밀린 것으로 보고 지금을 기준으로
    // 다시 잡는다** — 영원히 이른 상태로 갇히지 않는다.
    if (now_ms < self.agent_activity.last_stat_ms) self.agent_activity.last_stat_ms = now_ms;
    if (now_ms -| self.agent_activity.last_stat_ms < freshnessIntervalMs(self)) return;
    self.agent_activity.last_stat_ms = now_ms;

    const path = activeSourcePath(self) orelse return;
    // **원격은 로컬 `stat` 을 못 쓴다**(§13.2) — 저쪽에 물어야 하고 그것은 왕복이라 tick 을 막으면
    // 안 된다. 워커를 걸고 물러난다(답이 오면 드레인이 `refresh` 를 건다).
    if (self.agent_activity.source_remote) {
        beginRemoteFreshness(self, path);
        return;
    }
    if (!headChanged(self, path)) return;
    refresh(self, true); // 자랐다 — 다시 훑는다(`force` 로 위 게이트를 지나간다)
}

/// 다음 신선도 검사까지 쉬는 시간(ms). **직전 스캔이 비쌌으면 그만큼 더 쉰다.**
///
/// 이것이 없으면 큰 세션에서 워커가 **쉬지 않는다**: 9 초짜리 스캔이 끝나는 순간 그 사이 파일이 또
/// 자라 있어 곧바로 다시 훑는다. 대화가 이어지는 동안 코어 하나를 계속 먹는다 — 계약 §9 의 A2
/// 「활성 세션 재읽기 폭발」이 바로 이것이고, 델타 읽기(IG2-c)를 안 했으므로 여기서 막는다.
///
/// 배수 10 은 **일하는 시간의 10 배는 쉰다** = 워커 점유율 상한 약 9% 라는 뜻이다. 실측 분포에
/// 대면: 중앙 11 ms → 그대로 500 ms · p99 1,175 ms → 11.8 초 · 최대 9,007 ms → 90 초.
/// 흔한 세션은 영향이 없고, 비싼 세션만 느리게 따라온다.
fn freshnessIntervalMs(self: *const AppSession) i64 {
    return restIntervalMs(self.agent_activity.scan_ns / std.time.ns_per_ms);
}

/// 위 규칙의 **순수** 부분 — 화면 없이 짚을 수 있게 갈라 둔다.
pub fn restIntervalMs(last_scan_ms: u64) i64 {
    const last: i64 = @intCast(@min(@as(u64, std.math.maxInt(i32)), last_scan_ms));
    const want = @max(freshness_interval_ms, last *| freshness_rest_multiplier);
    // **상한이 없으면 조용히 죽는다.** `scan_ns` 는 벽시계 경과라 스캔 중에 기계가 잠들면 그 시간이
    // 통째로 들어간다 — 1 시간 자면 쉬는 시간이 10 시간이 되어 그 세션 내내 갱신이 안 온다.
    // 상한에 걸리는 경우 점유율 보장은 깨지지만, 기능이 멈추는 것보다 낫다.
    return @min(want, freshness_max_ms);
}

/// `restIntervalMs` 의 test 창구.
pub fn testFreshnessIntervalMs(last_scan_ms: u64) i64 {
    return restIntervalMs(last_scan_ms);
}

/// 신선도를 보는 **최소** 간격(ms). `stat` 은 싸지만(실측 54,296 배 저렴) 60 Hz 로 열 이유는 없다.
/// 사람이 「방금 붙인 것이 안 보인다」고 느끼기 전에 잡히는 선이다.
const freshness_interval_ms: i64 = 500;
/// 직전 스캔 시간의 몇 배를 쉬는가. 위 doc 참조.
const freshness_rest_multiplier: i64 = 10;
/// 쉬는 시간의 **상한**(ms). 실측 최악(9,007 ms → 90 초)은 이 아래라 점유율 보장이 그대로 산다.
/// 이 값을 넘기는 것은 병리적인 경우(스캔 중 절전)뿐이고, 그때는 「느리게라도 온다」를 택한다.
const freshness_max_ms: i64 = 120_000;

/// 크게 보기의 문맥을 **한 번** 읽는다. 실패는 빈 문맥이다 — 없는 대화를 지어내지 않는다.
///
/// 여기서만 파일을 연다: 격자는 문맥을 안 쓰고(라벨이 답한다), 크게 보기는 한 번에 한 장이라
/// 열 때 한 번 읽으면 끝난다. 라벨처럼 워커가 미리 만들지 않는 이유도 그것이다 — 4,096 장어치
/// 512 B 를 늘 들고 있을 이유가 없다(2 MB).
fn loadOpenContext(self: *AppSession, n: usize) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const op = if (self.agent_activity.open) |*o| o else return;
    op.context_len = 0;
    if (n >= self.agent_activity.hits.items.len) return;
    const hit = self.agent_activity.hits.items[n];
    const path = pathFor(self, hit) orelse return;

    const back: u64 = @min(hit.line_offset, @as(u64, context_mod.max_prev_line_bytes));
    if (back == 0) return;
    const win = self.allocator.alloc(u8, @intCast(back)) catch return;
    defer self.allocator.free(win);

    const file = std.Io.Dir.cwd().openFile(self.io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return;
    defer file.close(self.io);

    var read: usize = 0;
    while (read < win.len) {
        const got = file.readPositional(self.io, &.{win[read..]}, hit.line_offset - back + read) catch break;
        if (got == 0) break;
        read += got;
    }
    if (read == 0) return;

    const text = context_mod.contextText(win[0..read], &op.context);
    op.context_len = text.len;
}

/// 다시 훑은 뒤 타일을 **새 인덱스에 다시 잇는다**. 못 찾은 타일만 버린다.
///
/// 타일 수는 상한이 있고(`max_tiles`) 실측 세션도 수백 장이라 선형 탐색으로 충분하다.
/// **`pub` 인 이유는 판정자다** — 다시 훑는 길(자동 갱신·검색어 변경)의 한가운데에 있어서,
/// 도크를 통째로 세우지 않고 이 함수 하나를 직접 잴 수 있어야 한다(`formatResultSummary` 와 같은 규율).
pub fn remapTiles(self: *AppSession) void {
    const hits = self.agent_activity.hits.items;
    var write: usize = 0;
    for (self.agent_activity.tiles.items) |tile| {
        var found: ?usize = null;
        for (hits, 0..) |hit, i| {
            // ⚠️ **타일이 어디서 왔는지와 같은 함수로 찾는다**(AV5). 접힌 줄의 타일은 픽셀이
            // **그림**의 것인데 그 줄의 `Hit` 은 **호출**이라, `hit.data_offset` 으로 찾으면
            // (그것은 명령문 자리다) 영영 못 찾아 **매번 픽셀을 버리고 다시 디코드**한다 —
            // 격자에서 「매 턴 비었다 다시 찬다」를 막으려고 만든 이 장치가 목록에서 무력해진다.
            const src = thumbSource(hit) orelse continue;
            if (src.file_index == tile.file_index and src.offset == tile.data_offset) {
                found = i;
                break;
            }
        }
        if (found) |n| {
            var kept = tile;
            kept.hit_index = n;
            // **id 는 인덱스로 짓는다**(`appendGpuImages`). 자리가 바뀌었으면 새 id 로 다시 올려야
            // 빈 칸이 안 된다 — 픽셀은 그대로라 다시 디코드하지는 않는다.
            kept.uploaded = false;
            kept.label = labelFor(self, n);
            self.agent_activity.tiles.items[write] = kept;
            write += 1;
        } else {
            self.allocator.free(tile.pixels); // 사라진 이미지 — 픽셀을 여기서 푼다
        }
    }
    self.agent_activity.tiles.shrinkRetainingCapacity(write);
}

/// 지금 그 파일의 자국. 열지 못하면 «모름» 이다.
fn stampOf(self: *AppSession, path: []const u8) Stamp {
    if (!builtin.target.os.tag.isDarwin()) return .{};
    // **열지 않는다.** 이 함수는 main actor 에서 500 ms 마다 돈다 — 스캔을 워커로 옮긴 이유(계약
    // §4.1.1)가 「프레임에서 파일을 만지지 않는다」였고, 여는 것은 그중 가장 비싼 조각이다.
    // `statFile` 은 POSIX 에서 syscall 하나다.
    const st = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return .{};
    return .{
        .inode = @intCast(st.inode),
        .size = st.size,
        .mtime_ns = st.mtime.nanoseconds,
        .known = true,
    };
}

/// 마지막으로 훑은 뒤 현재 세션 파일이 달라졌는가.
///
/// **못 읽는 파일은 「안 달라졌다」로 본다.** 자국이 «모름» 이면 `eql` 이 false 라 「달라졌다」가
/// 되는데, 못 읽는 파일은 다시 훑어도 못 읽는다 — 그대로 두면 지워진 파일을 500 ms 마다 다시 훑는
/// 무한 루프가 된다. 파일이 돌아오면 그때 자국이 서고 달라진 것으로 잡힌다.
fn headChanged(self: *AppSession, path: []const u8) bool {
    const now = stampOf(self, path);
    if (!now.known) return false;
    return !Stamp.eql(self.agent_activity.head_stamp, now);
}

/// 갤러리가 지금 보여 주는 것. **인덱스는 메모리 전용**이다(계약 §4.5) — 앱을 끄면 사라지고 다음 실행에서
/// 다시 훑는다.
pub const State = struct {
    /// 이 인덱스를 만든(또는 만들고 있는) 파일 **묶음**. 첫 파일이 현재 세션이고, 재개면 부모가
    /// 뒤에 붙는다(§3.3). 활성 Term 의 것과 첫 파일이 다르면 무효다.
    chain: index.Chain = .{},
    /// 이 갤러리가 선 pane 이 **원격**인가. `activeSourcePath` 가 매번 다시 정하는 **파생 값**이므로
    /// `clear` 는 건드리지 않는다 — 스캔 결과가 아니라 pane 의 성질이다. 문구가 「없다」와
    /// 「못 읽는다」를 가르는 데 쓴다.
    source_remote: bool = false,
    /// **이번 원격 왕복이 실패했나**(RAV3). 「비었다」와 「못 읽었다」를 가르는 마지막 조각이다 —
    /// 원격 스캔이 실패하면 자리가 0 개로 오는데, 그것을 그냥 그리면 화면이 **「활동이 없습니다」**
    /// 라고 **거짓말**한다(계약 §2.2 가 금하는 그것).
    ///
    /// `source_remote` 와 달리 **스캔 결과의 성질**이라 `clear` 가 지운다.
    remote_failed: bool = false,
    /// **지금 들고 있는 목록이 원격 것인가.** `source_remote` 와 달리 **이미 지은 것**의 성질이다.
    ///
    /// 🔥 둘이 갈리는 순간이 곧 「pane 이 ssh 로 들어갔다(또는 나왔다)」이고, 그때 목록은 **통째로
    /// 다른 기계의 것**이 된다. 이 값이 없으면 `refresh` 가 「같은 경로 · 이미 지었음」으로 보고
    /// 물러나 **로컬 목록이 원격 세션 이름표 밑에 그대로 남는다**(CI 가 잡은 결함).
    built_remote: bool = false,
    /// 펼침 요청의 세대(RAV5b). 다른 것을 열거나 소스가 갈리면 올라가고, **늦게 온 원격 답**은
    /// 여기서 버려진다 — 안 버리면 남의 명령이 뜬다.
    detail_generation: u64 = 0,
    /// **원격 스캔이 읽은 바이트**(RAV7). 원격은 로컬 `stat` 자국을 쓸 수 없으므로(§13.2) 이 값이
    /// 자국이다 — 다음 신선도 확인이 **그 자리에서 1 바이트를 청해** 자랐는지 본다.
    remote_scanned_bytes: u64 = 0,
    /// 이 인덱스가 선 **pane 의 surface id**. 포커스가 옮겨 갔는지는 이 값으로만 안다(계약 §2.1
    /// «범위는 활성 pane»). 경로로는 못 가른다 — 에이전트가 안 붙은 pane 은 경로가 **아예 없어서**
    /// 「같은 것을 보고 있다」와 구별되지 않는다. `0` 은 아직 어떤 pane 도 기록하지 않았다는 뜻이고,
    /// 탭이 0 개인 창도 그 값을 낸다(`activeSourceSurfaceId`).
    ///
    /// **`clear` 가 지우지 않는다.** 소스를 비우는 것은 「그 pane 에 볼 것이 없다」이지 「그 pane 을
    /// 안 보고 있다」가 아니다 — 여기서 함께 지우면 같은 pane 에 머무는 내내 매 tick 다시 훑는다.
    focus_surface_id: u64 = 0,
    /// 스캔이 찾은 **전부**. 필터의 원본이라 여기서는 아무것도 빼지 않는다.
    /// 줄 목록이 **마지막 프레임에 실제로 그린 줄 수**. 진단이자 판정자의 눈이다.
    ///
    /// **없으면 렌더가 통째로 죽어도 CI 가 못 잡는다.** 판정자들은 그림 채널(`appendGpuImages`)만
    /// 보고 있었는데, 목록은 글자가 전부라 안 그려져도 「활동이 없다」로 보인다 — 격자가 빈 것과 달리
    /// 눈에 띄지도 않는다. `overflow` 와 짝이다(그것은 «못 그린 수», 이것은 «그린 수»).
    drawn_rows: usize = 0,
    /// 마지막 프레임에 그린 **글자 조각 수**(접두 · 본문 · 시각을 각각 하나로 센다).
    ///
    /// **`drawn_rows` 만으로는 모자란다.** 줄 수는 접두나 시각이 통째로 사라져도 그대로다 —
    /// 실제로 목록은 격자가 갖던 접두(D3)와 시각(I3)을 두 번 빠뜨렸고, 고친 뒤에도 **그것을 지키는
    /// 판정자가 없었다**(적대적 검증 L2). 조각을 세면 그 손실이 값으로 드러난다.
    drawn_pieces: usize = 0,
    /// 마지막 프레임에 그린 **칩 수**. 판정자가 「필터 UI 가 실제로 나갔나」를 값으로 본다 —
    /// `drawn_rows`·`drawn_pieces` 와 같은 역할이다(렌더가 죽어도 CI 가 모르는 것을 막는다).
    drawn_chips: usize = 0,
    /// 지금 무엇을 보고 있나(활동 뷰 계약 §2.1). **필터가 모양을 정한다** — 이미지는 격자,
    /// 나머지는 줄 목록이다.
    filter: Filter = .images,
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
    /// **아래층 검색**(계약 §2.1.1 — 「라벨은 즉시, 본문은 Enter」). 위층(`search`)은 라벨만 보고
    /// 글자마다 즉시 거르는데 라벨은 세션의 **2.9%** 다(실측) — 나머지를 이것이 맡는다.
    body: BodySearch = .{},
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
    /// 종류별 「다 못 봤다」(스캐너가 나눈 것을 그대로 받는다).
    image_partial: bool = false,
    activity_partial: bool = false,
    /// 마지막 스캔이 읽은 바이트와 걸린 시간. 계약 §4.1.1 의 근거가 이 자리에서 나왔다.
    scanned_bytes: u64 = 0,
    scan_ns: u64 = 0,
    /// 마지막으로 훑은 **현재 세션 파일**의 자국. 이것과 지금 `stat` 이 다르면 다시 훑는다.
    ///
    /// **머리 파일만 든다.** 체인의 뒤쪽은 이미 끝난 세션이라 자라지 않는다(§3.3) — 지금 대화가
    /// 붙는 곳은 언제나 첫 파일이다.
    head_stamp: Stamp = .{},
    /// 마지막으로 `stat` 한 tick. 매 프레임 부르지 않으려는 스로틀이다.
    last_stat_ms: i64 = 0,
    /// 결과를 받아 반영했는가. `hits.len == 0` 과 다르다 — 이미지가 없는 파일도 훑은 것이다.
    built: bool = false,
    /// 기다리는 요청의 generation. 0 이면 기다리는 것이 없다. **늦게 온 결과를 버리는 근거**다 —
    /// 소스가 그 사이 바뀌었으면(`/clear`) 그 결과는 남의 파일 것이다.
    awaiting: u64 = 0,
    /// 워커가 바빠 아직 못 건 요청이 있다. 다음 tick 이 다시 건다.
    resubmit: bool = false,
    /// 마지막 `applyFilter` 가 **어디서 맞았는지** 센 두 수(계약 §2.1.1). 「라벨 3 · 본문 +12」의
    /// 근거이고, **세는 자리와 만드는 자리가 같아야** 그 줄이 거짓말을 안 한다(`Filter.admits` 를 한
    /// 곳에 둔 것과 같은 규율).
    shown_label_matches: usize = 0,
    shown_body_matches: usize = 0,
    /// 격자에 자리를 못 얻은 이미지 수. **계산해 두고 안 쓰면 사용자가 이미지를 놓치고도 모른다** —
    /// 「없다」와 「안 보인다」를 가르는 값이다(계약 §2). 매 frame `appendGpuImages` 가 갱신한다.
    overflow: usize = 0,
    /// 지금 워커에 **걸어 둔 것들**. 예전에는 generation 하나 + 인덱스 하나였다 — 「한 번에 한 장」을
    /// 전제한 짝인데, 그 전제가 처리량을 틱 주기로 묶고 있었다(실측: 12 칸에 200 ms, 그중 148 ms 가
    /// 대기). 여럿이 동시에 돌면 「이 결과가 어느 칸 것인가」를 그 둘로는 못 가르므로 집합으로 든다.
    ///
    /// 상한이 `max_inflight` 라 고정 배열로 충분하다 — 힙을 잡을 이유가 없다.
    pending: [decode_backend.max_inflight]Pending = [_]Pending{.{}} ** decode_backend.max_inflight,
    pending_len: usize = 0,
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
        self.body.deinit(allocator);
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

    /// 크게 보기의 텍스처도 **같은 규율을 받는다.** `markAllNeedUpload` 는 격자 타일만 훑으므로
    /// (`tiles`), 크게 보기 한 장은 그 표시에서 빠져 있었다.
    ///
    /// 실제로 그렇게 났다(사용자 보고): 이미지를 눌러 크게 본 채 **도크를 접으면** 그 프레임에
    /// `activity_open_image_id` 가 `live_ids` 에 안 실려 텍스처가 evict 되는데 `uploaded` 는 참으로
    /// 남는다. 도크를 다시 펴면 크게 보기 화면은 돌아오지만 **그림 자리가 빈다** — 업로드 없이 id 만
    /// 실리기 때문이다. 뷰를 바꿔 나갈 때는 `onLeaveView` 가 아예 닫아서(`dropOpen`) 이 길에 안
    /// 들어오고, **접기만** 그 길로 간다.
    pub fn markOpenNeedUpload(self: *State) void {
        if (self.open) |*op| op.uploaded = false;
    }

    /// 크게 보기의 픽셀도 owned 다 — 소스가 갈리거나 닫을 때 반드시 여기서 푼다.
    pub fn dropOpen(self: *State, allocator: std.mem.Allocator) void {
        if (self.open) |*op| {
            allocator.free(op.pixels);
            op.detail.deinit(allocator); // 펼침 본문도 owned 다(AV3)
        }
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
        self.remote_failed = false;
        // 🔥 **자국도 지운다**(적대적 T1). 소스가 갈리면(pane 이동 · `/clear` 로 새 파일) 이 값은
        // **옛 파일의 크기**다 — 그대로 두면 신선도가 **새 파일**의 그 자리를 묻고, 새 파일이 더
        // 작으면 영영 빈 답이라 **자라도 갱신이 안 된다**.
        self.remote_scanned_bytes = 0;
        // **소스가 갈리면 본문 결과는 남의 파일 것이다.** 오프셋은 파일 절대값이라 그대로 두면
        // 새 세션의 엉뚱한 호출이 「본문에서 맞았다」로 선다.
        self.body.reset(allocator);
        self.chain.clear();
        self.head_stamp = .{};
        // **종류별 플래그도 함께 지운다.** 하나만 지우면 소스가 갈린 뒤에도 옛 세션의 「다 못
        // 읽음」이 따라붙어 새 세션에서 거짓 경고가 뜬다(적대적 검증 O5 — 종류별로 나누면서
        // 리셋 자리를 빠뜨렸다).
        self.partial = false;
        self.image_partial = false;
        self.activity_partial = false;
        self.scanned_bytes = 0;
        self.scan_ns = 0;
        self.built = false;
        self.awaiting = 0;
        self.resubmit = false;
        self.pendingClear();
        self.overflow = 0;
        self.shown_label_matches = 0;
        self.shown_body_matches = 0;
        self.scroll = .{};
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
        // **걸어 둔 디코드를 여기서 버린다.** `pending` 은 `hits` 의 인덱스를 들고 있는데 이 함수가
        // 그 인덱스 체계를 새로 만든다 — 안 버리면 도는 결과가 **엉뚱한 칸**에 붙고, 그 칸의 정체
        // (`file_index`·`data_offset`)까지 그 자리 것으로 적혀 `remapTiles` 가 잘못된 짝을 계속
        // 보존한다. 증상은 「다른 그림이 뜬다」이고 원인은 화면에 안 보인다.
        //
        // 여기가 유일한 길목이다 — 다시 훑은 뒤(자란 파일)와 검색어가 바뀔 때 둘 다 이리로 온다.
        // 버리는 값은 도는 넉 장뿐이고(장당 4.4 ms) 다음 tick 이 다시 건다.
        self.pendingClear();
        self.hits.clearRetainingCapacity();
        self.labels.clearRetainingCapacity();
        const total = self.all_hits.items.len;
        // **자리를 먼저 잡는다.** 루프 안에서 한쪽만 실패하면 그 뒤 전부가 «한 칸 밀린 라벨» 을
        // 갖는다 — 남의 이미지에 남의 설명·시각이 붙고, 그 증상은 「설명이 틀렸다」로 보이지
        // 「인덱스가 어긋났다」로 보이지 않는다. 미리 잡아 두면 append 는 실패할 수 없다.
        self.hits.ensureTotalCapacity(allocator, total) catch return self.showAll(allocator);
        self.labels.ensureTotalCapacity(allocator, total) catch return self.showAll(allocator);

        const q = self.queryText();
        // **본문 결과는 「지금 검색어의 답」일 때만 쓴다.** 워커 왕복이라 그 사이 글자가 바뀔 수
        // 있는데, 옛 검색어의 답을 그대로 두면 사용자가 글자를 지웠는데도 남의 줄이 남는다.
        const use_body = self.body.appliesTo(q);
        self.shown_label_matches = 0;
        self.shown_body_matches = 0;
        const paired = self.all_labels.items.len == total;
        for (self.all_hits.items, 0..) |hit, i| {
            // **종류 필터가 먼저다**(계약 §2.1). 이미지 필터면 그림만 받는다 — 안 거르면 활동
            // `Hit` 의 `data_offset`(사람이 읽는 문자열)이 디코더로 넘어가 빈 칸이 뜬다.
            if (!self.filter.admits(hit)) continue;
            const label: context.Label = if (paired) self.all_labels.items[i] else .{};
            if (q.len > 0) {
                // **라벨이 먼저다**(계약 §2.1.1 — 「라벨은 즉시, 본문은 Enter」). 두 층 다 걸린
                // 줄은 **라벨로 센다**: 사용자가 친 말이 이름에 있었으면 그것이 답이고, 본문에도
                // 있다는 사실은 그 답을 바꾸지 않는다.
                if (context.matches(label.text(), q)) {
                    self.shown_label_matches += 1;
                } else if (use_body and self.body.find(hit) != null) {
                    self.shown_body_matches += 1;
                } else continue;
            }
            self.hits.appendAssumeCapacity(hit);
            self.labels.appendAssumeCapacity(label);
        }
    }

    /// 거를 자리를 못 잡았을 때의 물러날 자리 — **검색을 끄고 그 종류를 전부 보여준다**.
    ///
    /// ⚠️ **끄는 것은 검색이지 종류가 아니다.** 종류 필터(§2.1)는 사용자가 「지금 무엇을 보고
    /// 있는가」로 고른 것이라, 자리를 못 잡았다고 이미지 필터에 활동을 쏟아 놓으면 그것이야말로
    /// 「왜 이게 뜨지」가 된다. 예전 주석은 「필터를 끈다」고 적혀 있었는데 종류 필터가 생긴 뒤로
    /// 거짓이 됐다(적대적 검증 I2).
    ///
    /// 반쯤 걸러 두면 사용자는 왜 어떤 이미지가 사라졌는지 알 수 없다. 여기서도 자리를 못 잡으면
    /// 목록은 비지만, **`hits` 와 `labels` 는 언제나 같은 길이다**(둘 다 비어 있다).
    fn showAll(self: *State, allocator: std.mem.Allocator) void {
        self.search.clear();
        // **센 값도 함께 지운다.** 검색을 껐는데 「라벨 3 · 본문 +12」가 남아 있으면, 목록은 그
        // 종류를 통째로 보여 주면서 안내 줄만 옛 검색을 말한다 — 화면이 자기 자신과 어긋난다
        // (적대적 2회차).
        self.shown_label_matches = 0;
        self.shown_body_matches = 0;
        self.hits.clearRetainingCapacity();
        self.labels.clearRetainingCapacity();
        const total = self.all_hits.items.len;
        self.hits.ensureTotalCapacity(allocator, total) catch return;
        self.labels.ensureTotalCapacity(allocator, total) catch {
            self.hits.clearRetainingCapacity();
            return;
        };
        const paired = self.all_labels.items.len == total;
        for (self.all_hits.items, 0..) |hit, i| {
            // 물러날 자리에서도 종류는 지킨다 — 여기서 새면 「검색을 못 걸었다」가 「엉뚱한 것이
            // 떴다」로 번진다.
            if (!self.filter.admits(hit)) continue;
            self.hits.appendAssumeCapacity(hit);
            self.labels.appendAssumeCapacity(if (paired) self.all_labels.items[i] else .{});
        }
    }

    /// 그 칸을 이미 걸어 뒀나. 안 보면 매 프레임 같은 칸을 다시 건다.
    pub fn pendingContains(self: *const State, hit_index: usize) bool {
        for (self.pending[0..self.pending_len]) |p| {
            if (p.hit_index == hit_index) return true;
        }
        return false;
    }

    pub fn pendingAdd(self: *State, generation: u64, hit_index: usize) void {
        if (self.pending_len >= self.pending.len) return;
        self.pending[self.pending_len] = .{ .generation = generation, .hit_index = hit_index };
        self.pending_len += 1;
    }

    /// 그 generation 을 걷어내고 어느 칸이었는지 돌려준다. 없으면 `null`(늦게 온 것).
    pub fn pendingTake(self: *State, generation: u64) ?usize {
        for (self.pending[0..self.pending_len], 0..) |p, i| {
            if (p.generation != generation) continue;
            const hit_index = p.hit_index;
            self.pending[i] = self.pending[self.pending_len - 1];
            self.pending_len -= 1;
            return hit_index;
        }
        return null;
    }

    pub fn pendingClear(self: *State) void {
        self.pending_len = 0;
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

/// 파일이 그때 그 파일이고 그만큼인가. 계약 §4.2 의 세 갈래를 이 셋으로 가른다.
///
/// **`mtime` 만으로는 모자란다**: 같은 초 안에 두 번 붙으면 못 잡는다. **`size` 만으로도 모자란다**:
/// 파일이 교체되면서 우연히 같은 크기일 수 있다. 셋을 함께 본다.
pub const Stamp = struct {
    inode: u64 = 0,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    /// 한 번도 못 찍었으면 «모름» 이다 — 모르면 다시 훑는다(낡은 채로 두지 않는다).
    known: bool = false,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.known and b.known and a.inode == b.inode and a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

/// 워커에 걸어 둔 한 칸. generation 으로 늦게 온 것을 가르고, 인덱스로 어느 칸인지 안다.
pub const Pending = struct {
    generation: u64 = 0,
    hit_index: usize = 0,
};

/// 화면에 올린 썸네일 하나.
pub const Tile = struct {
    /// 인덱스의 몇 번째 이미지인가. 격자 자리와 `hits` 를 잇는 키다. **다시 훑으면 밀린다** —
    /// 새 이미지가 맨 앞에 오므로(최신 우선). 그때 아래 정체로 다시 잇는다.
    hit_index: usize,
    /// 이 픽셀이 **어느 이미지**의 것인가. 인덱스와 달리 파일 안에서 변하지 않으므로, 다시 훑은 뒤
    /// 타일을 버리지 않고 새 인덱스에 이어 붙일 수 있다(`remapTiles`).
    file_index: u8 = 0,
    data_offset: u64 = 0,
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
/// 펼침이 그리는 본문 두 조각(AV3 — 계약 §2.4). **그때 받은 바이트**이지 지금 파일을 다시 실행한
/// 결과가 아니다.
pub const Detail = struct {
    /// 명령 전문(**owned**). 라벨은 한 줄로 접힌 것이고 이쪽이 원문이다.
    command: []u8 = &.{},
    /// 결과 전문(**owned**). 결과를 못 찾은 호출은 비어 있고 `has_result` 가 그것을 가른다 —
    /// 「결과가 없다」와 「결과가 빈 문자열이다」는 다른 사실이다.
    result: []u8 = &.{},
    command_truncated: bool = false,
    result_truncated: bool = false,
    /// chunk 껍데기에서 읽은 **종료 코드**. 없으면 null — 실측 chunk 의 33.9% 에만 있다.
    ///
    /// ⚠️ **이 값이 없으면 벗기기가 정보를 지운 것이 된다**(§6). `exit_code` 는 chunk JSON
    /// **안**에만 있어서, 껍데기를 벗기면 함께 사라진다.
    result_exit_code: ?i32 = null,
    has_result: bool = false,
    /// **원격에서 이 조각을 못 당겨왔다**(RAV5b). 「명령이 비었다」와 다른 사실이다 — 빈 채로 그리면
    /// 화면이 「에이전트가 빈 명령을 돌렸다」고 거짓말한다(계약 §2.2 의 그 갈림).
    remote_failed: bool = false,

    pub fn deinit(self: *Detail, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.result);
        self.* = .{};
    }
};

/// 펼침이 한 조각에 읽어 들일 상한(계약 §2.4 — 「앞에서부터 상한까지 싣고 이하 생략」).
///
/// 실측이 이 값을 정했다: 결과 바이트는 Claude 중앙 318 · p99 21 KB · 최대 616 KB, Codex 중앙 1,190 ·
/// p99 365 KB · **최대 2.8 MB** 이고, 명령은 최대 23,866 B 다. 8 KiB 는 **화면에 그릴 수 있는 것보다
/// 크다** — 이 판의 패널은 스크롤이 없어 들어가는 줄만 그리고 나머지는 「이하 생략」이 말한다. 더 담아
/// 봐야 못 그리고, 못 그리는 바이트를 위해 2.8 MB 를 읽을 이유가 없다.
pub const max_detail_bytes: usize = 8 * 1024;

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
    /// 지금 들고 있는 픽셀을 원본의 몇 분의 1 로 풀었나. **1 이면 더 선명해질 여지가 없다.**
    decoded_subsample: u8 = 1,
    /// 지금 도는 요청이 «원본으로 다시 풀기» 인가. 수확할 때 보던 자리를 지킬지 가른다.
    upgrading: bool = false,
    /// 펼침(AV3)의 본문 — 명령 전문과 결과 전문. **owned** 이고 `dropOpen` 이 푼다.
    ///
    /// 이미지에는 없다(그림이 본체다). 활동 항목은 반대로 그림이 없고 이 둘이 본체다 — 같은 «크게
    /// 보기» 자리를 쓰되(계약 §2.4) 채우는 것이 다르다.
    detail: Detail = .{},
    /// 원본으로 다시 풀기를 **이미 해 봤나**. 텍스처 상한 때문에 원본을 달라고 해도 `subsample > 1`
    /// 로 돌아올 수 있어(계약 §5.3), `decoded_subsample` 만 보면 매 tick 다시 건다.
    full_tried: bool = false,
    /// 열었을 때의 라벨(출처·순번·설명). **여기 담아 두는 것이 요점이다** — `hit_index` 로 매 프레임
    /// 목록을 다시 뒤지면, 그 사이 검색어가 바뀌어 목록이 재구성됐을 때 **남의 이미지의 출처**가 붙는다.
    /// 문맥(`context`)이 열 때 한 번 읽고 마는 것과 같은 규율이다.
    label: context.Label = .{},
    /// 「그때 무슨 얘기였나」. 열 때 **한 번만** 읽는다 — 매 프레임 파일을 열면 초당 60 번 IO 다.
    /// 빈 값은 「읽어 봤고 없었다」로 확정된 상태다(실측 6% 가 그렇다).
    context: [context_mod.max_context_bytes]u8 = undefined,
    context_len: usize = 0,

    pub fn contextText(self: *const Open) []const u8 {
        return self.context[0..self.context_len];
    }
};

/// 칩 하나의 자리(칸 단위). **그리기와 히트테스트가 같은 함수를 쓴다** — 두 벌이면 「보이는 칩」과
/// 「눌리는 칩」이 갈린다(이 저장소가 반복해서 당한 형태).
pub const ChipSpan = struct { filter: Filter, col: u16, cols: u16 };

/// 칩 넷을 왼쪽부터 놓는다. **폭이 모자라면 고른 것 하나만 남긴다** — 넷을 우겨넣어 글자를 자르면
/// 무엇을 누르는지 알 수 없고, 「지금 무엇을 보고 있나」는 마지막까지 지켜야 할 정보다
/// (계약 §2.2.3 의 「좁아지면 시각부터 버린다」와 같은 규율).
pub fn chipSpans(self: *const AppSession, out: *[4]ChipSpan) []const ChipSpan {
    const order = [_]Filter{ .images, .execs, .reads, .all };
    const rect = chipRowRect(self);
    const cols: u16 = if (self.cell_width_px > 0)
        @intCast(@min(rect.w / self.cell_width_px, @as(u32, std.math.maxInt(u16))))
    else
        0;
    if (cols == 0) return out[0..0];

    var want: u16 = 0;
    for (order, 0..) |f, i| {
        if (i > 0) want +|= chip_gap_cols;
        want +|= displayColsOf(filterText(f));
    }
    if (want <= cols) {
        var col: u16 = 0;
        for (order, 0..) |f, i| {
            const w = displayColsOf(filterText(f));
            out[i] = .{ .filter = f, .col = col, .cols = w };
            col +|= w +| chip_gap_cols;
        }
        return out[0..order.len];
    }

    // 좁다 — 고른 것 하나만. 그것도 안 들어가면 아무것도 안 그린다(잘린 글자를 남기지 않는다).
    const cur = self.agent_activity.filter;
    const w = displayColsOf(filterText(cur));
    if (w > cols) return out[0..0];
    out[0] = .{ .filter = cur, .col = 0, .cols = w };
    return out[0..1];
}

fn filterText(f: Filter) []const u8 {
    return switch (f) {
        .images => maru.i18n.t(.agent_activity_filter_images),
        .execs => maru.i18n.t(.agent_activity_filter_execs),
        .reads => maru.i18n.t(.agent_activity_filter_reads),
        .all => maru.i18n.t(.agent_activity_filter_all),
    };
}

/// 종류 필터(활동 뷰 계약 §2.1). 순서가 곧 순환 순서다.
///
/// **기본이 `images` 인 이유**: 이 뷰는 이미지 갤러리로 살아 있었고, 활동은 얹히는 축이다. 기본을
/// 바꾸면 「내 갤러리가 사라졌다」가 된다.
pub const Filter = enum {
    images,
    reads,
    execs,
    all,

    /// 이 필터가 격자인가. `false` 면 줄 목록이다.
    pub fn isGrid(self: Filter) bool {
        return self == .images;
    }

    /// 이 필터가 보고 있는 것 중 **잘린 것이 있나**(계약 §2 — 「없다」와 「못 봤다」를 가른다).
    ///
    /// ⚠️ **「전체」는 두 종류를 다 담는다.** 예전에는 「격자면 이미지, 아니면 활동」으로 갈랐는데,
    /// 그 규칙에서 「전체」가 **활동 쪽만** 보게 된다 — 이미지가 상한에 잘려도 「전체」는 아무 말을
    /// 안 하고, 사용자는 「이미지」 필터로 가야만 그 사실을 안다. 필터가 **담는 종류**로 정해야
    /// 그 갈래가 안 생긴다.
    /// 이 필터가 **그림을 담나**. 담지 않으면 썸네일도 타일도 그 화면의 것이 아니다.
    ///
    /// 타일을 **버릴지 말지**가 이 값에 걸린다 — 안 담는 필터(「읽기」·「명령」)에 잠깐 들렀다고
    /// 픽셀을 버리면, 돌아올 때 다시 디코드해 화면이 깜빡인다(실측 11 장에 306 ms).
    pub fn holdsImages(self: Filter) bool {
        return self == .images or self == .all;
    }

    pub fn partialOf(self: Filter, image_partial: bool, activity_partial: bool) bool {
        return switch (self) {
            .images => image_partial,
            .reads, .execs => activity_partial,
            .all => image_partial or activity_partial,
        };
    }

    /// 다음 필터. **순서는 실측이 정한다**(적대적 검증 H5).
    ///
    /// 처음에는 표 순서대로 `images → reads → execs → all` 이었는데, 그러면 **첫 Tab 이 거의 항상
    /// 빈 화면**이다 — 「읽기」로 세어지는 것(`Read`·`view_image`)은 실측 39,645 건 중 **634 건**
    /// (1.6%)뿐이다. 사용자가 처음 만나는 화면이 비어 있으면 기능이 고장난 것으로 읽힌다. 그래서
    /// **가장 많은 것부터** 돈다 — `Bash`/`exec` 가 도구의 92% 다.
    ///
    /// ⚠️ **근거 한 줄이 낡아서 지웠다**(2026-09-10 · 적대적 2회차). 여기에는 「Codex 세션에서는
    /// **0 건**」이라고 적혀 있었는데, 갈래표가 Codex 어휘를 알게 되면서(§2.1) `view_image` 226 건이
    /// 「읽기」에 든다 — 실제로 한 세션에서 11 줄이 떴다. **결론은 그대로다**(226 건은 실행
    /// 170,522 건 앞에서 여전히 미미하다). 근거만 갱신했다 — 다음 사람이 「Codex 는 읽기가 없다」를
    /// 믿고 판단하면 틀린다.
    pub fn next(self: Filter) Filter {
        return switch (self) {
            .images => .execs,
            .execs => .reads,
            .reads => .all,
            .all => .images,
        };
    }

    /// 이 `Hit` 이 이 필터에 드는가. **판정을 한 곳에 둔다** — 목록을 만드는 자리와 세는 자리가
    /// 갈리면 「12장 중 8장」이 거짓말을 한다.
    pub fn admits(self: Filter, hit: index.Hit) bool {
        return switch (self) {
            .images => hit.kind.isImage(),
            .reads => hit.activity == .read,
            .execs => hit.activity == .exec,
            // **결과가 이미지인 호출은 한 줄이다**(계약 §2.2.1). 그 이미지는 자기를 부른 호출 줄이
            // 이미 대신하고 있으므로 여기서 뺀다 — 안 빼면 같은 일이 두 줄로 뜬다(실측 542 건).
            //
            // 「이미지」 필터는 그대로 보여 준다: 접는 것은 **남의 줄과 겹칠 때뿐**이고, 격자는
            // 애초에 그림만 세는 자리다.
            .all => hit.fold_owner == index.no_fold,
        };
    }
};

/// 본문 검색의 상태(계약 §2.1.1). **위층과 따로 든다** — 라벨 검색은 글자마다 즉시 다시 거르는데,
/// 본문은 워커 왕복이라 「지금 화면의 검색어」와 「이 결과가 대답한 검색어」가 갈릴 수 있다.
pub const BodySearch = struct {
    /// 이 결과가 **대답한** 검색어. 화면의 검색어와 다르면 결과는 남의 답이라 안 쓴다.
    query: std.ArrayList(u8) = .empty,
    /// 워커가 준 것. `(file, data_offset)` 오름차순이라 이분 탐색으로 되짚는다.
    ///
    /// **자리가 아니라 값을 키로 든다.** 「`all_hits` 의 몇 번째」로 들면 퇴출과 화면의 뒤집기를
    /// 따라 움직여야 하는데, 이 스택은 이미 그런 필드를 셋 만들었고(대기 링 · 접기 · 옛 파일 번호)
    /// 넷째는 안 만들기로 했다(`ResultSummary.image_offset` 의 주석과 같은 결정).
    matches: std.ArrayList(body_backend.Match) = .empty,
    /// 기다리는 요청. 0 이면 기다리는 것이 없다 — 늦게 온 결과를 버리는 근거다.
    awaiting: u64 = 0,
    /// 워커가 바빠 아직 못 건 요청이 있다. 다음 tick 이 다시 건다.
    resubmit: bool = false,
    /// 이 검색어에 **답을 받았다.** `matches` 가 비어 있는 것과 다른 사실이다 — 「걸린 것이
    /// 0 건인 답」과 「아직 안 물어봤다」를 그 길이로는 못 가른다.
    ///
    /// ⚠️ **이 깃발이 없으면 재제출이 자기 게이트에 막힌다**(적대적 1회차). 예전 게이트는
    /// 「`query` 가 같고 `awaiting == 0` 이면 물러난다」였는데, 워커가 바빠 못 걸었을 때가 정확히
    /// 그 모양이라(`query` 는 채웠고 `awaiting` 은 0) `pollBodySearch` 의 재시도가 **한 줄도 못 가고
    /// 되돌아갔다** — 그 요청은 영구히 사라지고, 검색어를 바꾸기 전엔 복구되지 않는다.
    answered: bool = false,
    /// 열지 못한 파일이 있었다.
    partial: bool = false,
    read_bytes: u64 = 0,
    search_ns: u64 = 0,

    pub fn deinit(self: *BodySearch, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.matches.deinit(allocator);
        self.* = .{};
    }

    /// 결과와 기다림을 통째로 놓는다. 검색어가 바뀌었거나 소스가 갈렸을 때다.
    pub fn reset(self: *BodySearch, allocator: std.mem.Allocator) void {
        self.query.clearAndFree(allocator);
        self.matches.clearAndFree(allocator);
        self.awaiting = 0;
        self.resubmit = false;
        self.answered = false;
        self.partial = false;
        self.read_bytes = 0;
        self.search_ns = 0;
    }

    /// 이 결과가 **지금 검색어**에 대한 답인가. 아니면 없는 셈 친다 — 옛 검색어의 결과를 그대로
    /// 두면 사용자가 글자를 지웠는데도 남의 줄이 남는다.
    pub fn appliesTo(self: *const BodySearch, query: []const u8) bool {
        return query.len > 0 and std.mem.eql(u8, self.query.items, query);
    }

    /// 이 검색어에 대해 **이미 답했거나 답하는 중인가.** 셋을 다 봐야 한다 — 받은 답 ·
    /// 도는 요청 · 아직 못 건 요청. 하나라도 빠뜨리면 그 상태가 「안 물어봤다」로 읽혀 같은 일을
    /// 다시 하거나(중복 훑기), 영영 안 하거나(적대적 1회차) 한다.
    pub fn settledFor(self: *const BodySearch, query: []const u8) bool {
        if (!self.appliesTo(query)) return false;
        return self.answered or self.awaiting != 0 or self.resubmit;
    }

    /// 그 호출이 본문에서 맞았나. 못 찾으면 `null`.
    pub fn find(self: *const BodySearch, hit: index.Hit) ?body_backend.Match {
        const key: body_backend.Match = .{ .file = hit.file_index, .data_offset = hit.data_offset };
        var lo: usize = 0;
        var hi: usize = self.matches.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const m = self.matches.items[mid];
            if (body_backend.lessThan({}, m, key)) {
                lo = mid + 1;
            } else if (body_backend.lessThan({}, key, m)) {
                hi = mid;
            } else return m;
        }
        return null;
    }
};

/// 뒤집힌 배열에서 `fold_owner` 를 새 자리로 옮긴다. `i` 였던 것은 `n - 1 - i` 가 된다.
///
/// **`pub` 인 이유는 판정자다** — 뒤집기는 화면 경로 한가운데에 있어서 통째로 세우지 않고 이 한
/// 함수만 직접 잴 수 있어야 한다(`formatResultSummary` 와 같은 규율).
pub fn reverseFoldOwners(hits: []index.Hit) void {
    const n = hits.len;
    if (n == 0) return;
    for (hits) |*h| {
        if (h.fold_owner == index.no_fold) continue;
        // 자리를 벗어난 값은 **접기를 푼다.** 지어낸 주인을 가리키느니 제 줄로 서는 편이 낫다.
        if (h.fold_owner >= n) {
            h.fold_owner = index.no_fold;
            continue;
        }
        h.fold_owner = @intCast(n - 1 - h.fold_owner);
    }
}

/// 갤러리 썸네일용 예약 kitty image id 시작점. 배경(`0xFFFF_FFFF`)과 kitty 프로그램 id(보통 작은 값)
/// 사이에 둔다 — 같은 텍스처 캐시를 쓰므로 id 가 겹치면 남의 그림이 나온다.
pub const activity_image_id_base: u32 = 0xFFF0_0000;

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
pub const activity_open_image_id: u32 = activity_image_id_base +| 0x10000;

/// 활성 Term 의 트랜스크립트 경로. 없으면 null — 에이전트가 붙지 않은 pane(셸만 띄운 창)이 그렇다.
///
/// **탭이 0 개인 창을 먼저 막는다.** merge/이동으로 비워진 뒤 Swift 가 닫기 전 tick 이 있고, 그때
/// `activePane()` 이 빈 리스트를 인덱싱해 패닉한다(`handleDroppedImage` 가 같은 이유로 같은 가드를 둔다).
fn activeSourcePath(self: *AppSession) ?[]const u8 {
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    // **이 pane 이 원격인가**(계약 §4.1.2 · RAV3). 훅이 준 `transcript_path` 는 **저쪽 기계**의
    // 경로다 — 그것을 로컬 `Dir.cwd().openFile` 에 넘기면 같은 모양의 홈 경로가 이쪽에도 있을 때
    // (양쪽 macOS·같은 사용자 이름) **남의 대화가 열린다**. 그래서 예전에는 여기서 통째로 막았다.
    //
    // 이제는 **막는 대신 저쪽에서 훑는다**(RAV3): 경로는 그대로 돌려주되 `source_remote` 가 서면
    // 스캔이 원격 왕복으로 간다(`refresh` → `scan_backend.submit(chain, remote)`). 로컬 syscall 로
    // 새는 자리가 0 인지는 §6.3 의 게이트가 센다.
    //
    // **판정은 여기 한 곳이다.** 채택하는 쪽에도 두면 둘이 갈린다(바로 아래 `refresh` 주석의 그 이유).
    self.agent_activity.source_remote = agent_ops.isRemoteAgentPane(term);
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

        // `openDirAbsolute` 는 상대경로에 **assert 로 죽는다**(`catch` 가 못 막는다). `root_path` 는 HOME 에서
        // 만든 것이라 그 env 가 상대경로면 앱이 abort 한다 — agent.zig 가 같은 이유로 같은 가드를 둔다.
        if (!std.fs.path.isAbsolute(root_path)) break;
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
    if (self.agent_activity_backend) |*b| return b;
    return null;
}

fn decodeBackendPtr(self: *AppSession) ?*decode_backend.Backend {
    if (self.agent_activity_decode_backend) |*b| return b;
    return null;
}

/// 펼쳐 둔 줄의 **정체**(`file_index` · `data_offset`). 타일 재연결과 **같은 키**다 — 배열이
/// 움직여도 변하지 않는 값이라야 다시 이을 수 있다.
const OpenKey = struct { file: u8, data_offset: u64 };

fn openKey(self: *const AppSession) ?OpenKey {
    const op = self.agent_activity.open orelse return null;
    if (op.hit_index >= self.agent_activity.hits.items.len) return null;
    const hit = self.agent_activity.hits.items[op.hit_index];
    return .{ .file = hit.file_index, .data_offset = hit.data_offset };
}

/// 목록이 다시 만들어진 뒤 펼쳐 둔 줄을 **새 자리에 다시 잇는다**. 못 찾으면 닫는다.
///
/// **닫지 않고 잇는 이유**는 이 길이 「검색어는 그대로인데 목록이 **늘어나기만**」 하는 길이기
/// 때문이다(본문 답이 도착). 보던 줄은 여전히 목록에 있고 자리만 밀리는데, 통째로 닫으면 읽던
/// 것을 뺏고, **안 잇고 두면 남의 줄이 펼쳐진 것처럼 보인다** — 후자가 훨씬 나쁘다(「다른 그림이
/// 뜬다」와 같은 결의 조용한 어긋남이다).
fn reattachOpen(self: *AppSession, key: ?OpenKey) void {
    if (self.agent_activity.open == null) return;
    const k = key orelse return self.agent_activity.dropOpen(self.allocator);
    for (self.agent_activity.hits.items, 0..) |hit, i| {
        if (hit.file_index != k.file or hit.data_offset != k.data_offset) continue;
        if (self.agent_activity.open) |*op| op.hit_index = i;
        return;
    }
    self.agent_activity.dropOpen(self.allocator);
}

fn bodyBackendPtr(self: *AppSession) ?*body_backend.Backend {
    if (self.agent_activity_body_backend) |*b| return b;
    return null;
}

/// 본문 검색을 **놓는다** — 검색어가 바뀌었다.
///
/// **취소까지 건다.** 상태만 지우면 워커는 계속 17.7 MB 를 읽고, 그 결과는 generation 이 안 맞아
/// 어차피 버려진다 — 아무도 안 볼 것을 위해 디스크를 도는 셈이다.
pub fn cancelBodySearch(self: *AppSession) void {
    if (bodyBackendPtr(self)) |b| b.cancel();
    self.agent_activity.body.reset(self.allocator);
}

/// 뷰를 떠난다 — **도는 워커만 접고 받은 답은 남긴다**(적대적 3회차).
///
/// 검색어(`search.query`)는 뷰를 떠나도 남으므로 라벨 층 필터는 그대로 걸려 있다. 그런데 본문 답만
/// 버리면, 돌아온 사용자에게는 **아까 있던 줄이 사라진 것**으로 보인다 — 자기가 한 일이 아닌데
/// 목록이 줄었으니 갤러리가 뭔가 잃은 것으로 읽힌다. 두 층은 같이 살고 같이 죽어야 한다.
///
/// 도는 요청은 접는다(`awaiting`·`resubmit`) — 안 보는 뷰를 위해 디스크를 돌 이유가 없고, 늦게 온
/// 결과는 generation 이 안 맞아 어차피 버려진다.
fn suspendBodySearch(self: *AppSession) void {
    if (bodyBackendPtr(self)) |b| b.cancel();
    self.agent_activity.body.awaiting = 0;
    self.agent_activity.body.resubmit = false;
}

/// `Enter` — 본문까지 넓힌다(계약 §2.1.1).
///
/// **파일 전체를 안 훑는다.** 인덱스가 이미 자리를 아니(`cmd_rel` · `result.body.offset`) 그 조각만
/// 넘긴다 — 실측 파일의 12.0% 다. 그림(`kind.isImage()`)은 **안 넘긴다**: 그 `data_offset` 은
/// base64 payload 라 읽어 봐야 뜻이 없고, 64 KiB 씩 헛도는 값만 치른다.
pub fn submitBodySearch(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = bodyBackendPtr(self) orelse return;
    const q = self.agent_activity.queryText();
    if (q.len == 0) return;
    if (self.agent_activity.chain.isEmpty()) return;
    // 같은 검색어에 **이미 답했거나 답하는 중이면** 다시 훑지 않는다 — `Enter` 를 두 번 누르는
    // 것이 17.7 MB 를 두 번 읽을 이유가 되지 않는다. 셋을 다 보는 이유는 `settledFor` 에 있다.
    const body = &self.agent_activity.body;
    if (body.settledFor(q)) return;

    // **인덱스가 아직 없으면 예약해 두고 물러난다.** 스캔이 워커라 큰 세션은 3.6 초인데, 사용자는
    // 도크를 열자마자 검색어를 치고 `Enter` 를 누른다 — 그때 그냥 돌아가면 그 `Enter` 가 **조용히
    // 사라지고**, 창이 이미 닫혀 있어 다시 누를 수도 없다(적대적 3회차).
    if (!self.agent_activity.built) {
        body.reset(self.allocator);
        body.query.appendSlice(self.allocator, q) catch return;
        body.resubmit = true;
        self.metal_dirty = true;
        return;
    }

    var probes: std.ArrayList(body_backend.Probe) = .empty;
    defer probes.deinit(self.allocator);
    probes.ensureTotalCapacity(self.allocator, self.agent_activity.all_hits.items.len) catch return;
    for (self.agent_activity.all_hits.items) |hit| {
        if (hit.kind.isImage()) continue;
        // 펼침(`loadOpenDetail`)과 **같은 자리**를 본다 — 두 벌이 되면 「검색에는 걸리는데 펼치면
        // 없는」 줄이 생긴다.
        const cmd_offset = if (hit.cmd_rel != 0) hit.line_offset +| hit.cmd_rel else hit.data_offset;
        probes.appendAssumeCapacity(.{
            .data_offset = hit.data_offset,
            .cmd_offset = cmd_offset,
            // **입력 전부**(§2.1.1). Claude 만 든다 — Codex 는 `input` 이 문자열이라 대상·명령이
            // 이미 그 안이다.
            .input_offset = if (hit.input_rel != 0) hit.line_offset +| hit.input_rel else 0,
            .body_offset = if (hit.result.found) hit.result.body.offset else 0,
            .body_is_array = hit.result.body.is_array,
            .file = hit.file_index,
        });
    }
    // 새 검색어다 — 옛 답을 먼저 놓는다(안 놓으면 `appliesTo` 가 참인 채로 옛 줄이 남는다).
    body.reset(self.allocator);
    body.query.appendSlice(self.allocator, q) catch return;

    // **훑을 자리가 없다 = 답은 「없다」이고 그것도 답이다.** 안 적어 두면 `Enter` 를 누를 때마다
    // 같은 결론에 다시 도달한다(그림만 있는 세션이 그 모양이다).
    if (probes.items.len == 0) {
        body.answered = true;
        self.metal_dirty = true;
        return;
    }
    if (backend.submit(self.agent_activity.chain, q, probes.items)) |generation| {
        body.awaiting = generation;
    } else {
        // 워커가 바쁘다 — 다음 tick 이 다시 건다. `query` 는 남겨 둔다(그것이 「무엇을 물었나」다).
        body.resubmit = true;
    }
    self.metal_dirty = true;
}

/// 본문 검색의 완료본을 거둔다. `poll` 이 tick 마다 부른다.
fn pollBodySearch(self: *AppSession) void {
    const backend = bodyBackendPtr(self) orelse return;
    const state = &self.agent_activity.body;

    // **못 걸었던 요청(워커가 바빴다)과 예약(스캔이 아직이었다)을 여기서 다시 건다.**
    //
    // ⚠️ `resubmit` 을 **먼저 끄는 것이 계약이다.** `submitBodySearch` 의 게이트(`settledFor`)가
    // 그 깃발도 「진행 중」으로 세므로, 켜 둔 채 부르면 자기 자신에게 막혀 되돌아간다 —
    // 적대적 1회차가 잡은 바로 그 형태다.
    if (state.resubmit and state.query.items.len > 0) {
        state.resubmit = false;
        submitBodySearch(self);
    }

    var result = backend.take() orelse return;
    // **늦게 온 것은 버린다.** 검색어가 그 사이 바뀌었으면 이 결과는 남의 물음에 대한 답이다.
    if (result.generation != state.awaiting or state.awaiting == 0) {
        result.deinit(self.allocator);
        return;
    }
    state.matches.deinit(self.allocator);
    state.matches = result.matches; // 소유 이동 — 여기서부터 세션이 푼다
    state.awaiting = 0;
    state.answered = true;
    state.partial = result.partial;
    state.read_bytes = result.read_bytes;
    state.search_ns = result.search_ns;
    // **목록이 새로 만들어지면 그 위에 얹힌 자리들도 낡는다**(적대적 8회차). 스캔 수확과
    // `rebuildFilter` 는 그것을 이미 다룬다 — 이 길만 빠져 있었고, 그래서 결과가 오는 순간
    // **펼쳐 둔 줄이 남의 자리를 가리켰다**(자리가 밀린 만큼 엉뚱한 줄이 펼쳐진 것처럼 보인다).
    const open_key = openKey(self);
    // 목록을 다시 만든다 — 이제 본문에서 걸린 줄이 더해진다.
    self.agent_activity.applyFilter(self.allocator);
    reattachOpen(self, open_key);
    // 호버도 옛 자리다. 다음 마우스 이동이 다시 잡는다.
    self.agent_activity.hovered = null;
    if (self.agent_activity.filter.holdsImages()) remapTiles(self);
    clampScroll(self);
    self.metal_dirty = true;
}

/// 갤러리 인덱스를 활성 pane 에 맞춘다. **파일을 여기서 읽지 않는다** — 워커에 요청만 건다.
///
/// 호출자는 둘이다: 뷰에 들어올 때(`setDockView`)와 소스가 바뀐 것을 훅이 알려 줬을 때.
pub fn refresh(self: *AppSession, force: bool) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    const path = activeSourcePath(self) orelse {
        if (self.agent_activity.built or self.agent_activity.scanning() or !self.agent_activity.chain.isEmpty()) {
            backend.cancel();
            if (decodeBackendPtr(self)) |d| d.cancel();
            self.agent_activity.clear(self.allocator);
            self.metal_dirty = true;
        }
        return;
    };
    const same = std.mem.eql(u8, self.agent_activity.chain.head(), path);
    // 같은 파일을 이미 훑었거나 훑는 중이면 여기서 물러난다.
    //
    // **신선도는 여기서 안 본다.** 파일이 자랐는지 보는 일은 `pollFreshness` 하나가 맡는다 —
    // 두 곳에서 같은 판정을 하면 갈리고(이 저장소에서 반복해 본 모양), 실제로 뮤테이션이 그것을
    // 짚었다: 이 자리에 신선도 검사를 두어도 `pollFreshness` 가 `force` 로 부르므로 **test 가
    // 지키지 못하는 코드**가 된다. 뷰에 다시 들어오면 다음 tick 의 `pollFreshness` 가 곧바로 잡는다
    // (첫 검사는 스로틀에 안 걸린다).
    // **원격 여부가 갈리면 경로가 같아도 다시 건다.** 같은 문자열이라도 한쪽은 이쪽 파일이고
    // 다른 쪽은 저쪽 파일이다 — 「같은 경로」가 「같은 소스」를 뜻하지 않는 유일한 자리다.
    const remote_changed = self.agent_activity.source_remote != self.agent_activity.built_remote;
    if (!force and same and !remote_changed and (self.agent_activity.built or self.agent_activity.scanning())) return;

    // 소스가 갈렸다 = 다른 세션이다(`/clear` 는 새 파일을 만든다). 옛 파일의 오프셋은 새 파일에서
    // 아무 뜻이 없으므로 통째로 버리고 다시 건다. 도는 스캔도 취소한다.
    backend.cancel();
    if (decodeBackendPtr(self)) |d| d.cancel(); // 옛 파일의 오프셋으로 도는 디코드를 버린다
    // **취소하면 함께 비운다.** 취소된 워커는 결과를 내놓지 않으므로 `pendingTake` 가 영영 안 불리고,
    // 죽은 항목이 자리를 차지한 동안 그 칸들은 다시 걸리지 못해 **비어 보인다**(큰 파일이면 훑는
    // 9 초 내내). 못 박는 불변식 자체는 `applyFilter` 가 지킨다 — 훑기 결과는 반드시 거길 지나므로
    // 여기 것은 그 창을 줄이는 몫이다(뮤테이션으로 확인: 이 줄만 지우면 test 는 통과한다).
    self.agent_activity.pendingClear();
    // **보던 자리도 옛 세션의 것이다.** 오프셋은 픽셀이라 새 목록에서는 아무 뜻이 없고, 남겨 두면
    // 짧은 목록에서 끝을 넘어 화면이 빈다(적대적 검증 H2). 필터 전환이 같은 이유로 같은 일을 한다.
    if (!same or remote_changed) self.agent_activity.scroll.offset_y_px = 0;

    // **같은 파일이면 보이던 것을 그대로 둔다.** `clear` 는 「다른 세션이 됐다」를 뜻하고, 자란 파일을
    // 다시 읽는 것은 그것이 아니다. 여기서 비우면 다시 훑는 내내 갤러리가 **빈 화면**이 된다 —
    // 큰 세션은 9 초다. 자동으로 일어나는 일이라 사용자는 이유를 알 수 없다.
    //
    // 결과가 오면 `poll` 이 목록을 통째로 바꾸고 그 위에 쌓인 것(타일·크게보기·호버)도 그때 버린다.
    // 그때까지는 조금 낡은 목록이 보인다 — 빈 화면보다 정직하다. 검색어도 자연히 남는다.
    // **원격 여부가 갈렸으면 비운다** — 경로가 같아도 **다른 기계의 목록**이다. 안 비우면 로컬에서
    // 본 활동이 원격 세션 이름표 밑에 남는다(그 반대도 마찬가지다).
    if (!same or remote_changed) self.agent_activity.clear(self.allocator);
    self.agent_activity.built_remote = self.agent_activity.source_remote;
    // **원격 체인은 자리 하나다.** `buildChain` 은 `~/.codex/sessions` 를 **로컬** 디렉터리로 훑으므로
    // (부모 rollout 탐색) 원격 경로에 대고 부르면 이쪽 파일을 뒤진다 — §2.1 이 금하는 바로 그것이다.
    // 저쪽에서 체인을 푸는 것은 RAV4 다.
    self.agent_activity.chain = if (self.agent_activity.source_remote)
        remoteHeadChain(path)
    else
        buildChain(self, path);
    self.metal_dirty = true;

    // **훑기 직전의 자국을 찍는다.** 훑은 뒤에 찍으면 그 사이 붙은 줄을 「이미 봤다」로 오해한다.
    //
    // ⚠️ 원격은 자국이 없다 — `stampOf` 는 로컬 `stat` 이다(§2.1). 그래서 원격 세션은 신선도 폴링이
    // 안 걸리고 **뷰에 다시 들어올 때** 다시 훑는다. 저쪽 크기를 묻는 일은 별개 왕복이라 RAV7 이다.
    self.agent_activity.head_stamp = if (self.agent_activity.source_remote) .{} else stampOf(self, path);

    // 원격 목적지는 **활성 Term 의 관측**에서 온다(업로드·SCM 과 같은 출처 — 두 벌을 만들지 않는다).
    const active_term = pane_ops.activePane(self).activeTerm();
    const remote_ctx = if (self.agent_activity.source_remote) self.remoteUploadContextFor(active_term) else null;
    defer if (remote_ctx) |ctx| ctx.deinit(self.allocator);
    const remote: ?scan_backend.RemoteTarget = if (remote_ctx) |ctx|
        .{ .ctl = ctx.ctl, .dest = ctx.dest }
    else
        null;
    // **원격인데 목적지를 못 얻으면 안 건다.** 그 pane 은 곧 「못 읽는다」로 뜬다 — 로컬로 떨어뜨리면
    // 저쪽 경로를 이쪽에서 열게 된다(§2.1).
    if (self.agent_activity.source_remote and remote == null) {
        self.agent_activity.resubmit = false;
        self.agent_activity.remote_failed = true;
        self.metal_dirty = true;
        return;
    }

    if (backend.submit(self.agent_activity.chain, remote)) |generation| {
        self.agent_activity.awaiting = generation;
    } else {
        // 워커가 바쁘다(직전 스캔이 아직 도는 중). 다음 tick 이 다시 건다.
        self.agent_activity.resubmit = true;
    }
}

/// 원격 소스의 체인 — **머리 하나**다(RAV3 · 위 `refresh` 의 그 이유).
fn remoteHeadChain(path: []const u8) index.Chain {
    var chain: index.Chain = .{};
    _ = chain.append(path);
    return chain;
}

/// **포커스가 다른 pane 으로 가면 그 pane 의 세션으로 갈아탄다**(계약 §2.1 — 「포커스가 다른 pane 으로
/// 가면 내용이 따라 바뀐다」).
///
/// 이 훅이 없던 동안 갤러리를 갱신하는 자리는 둘뿐이었고(뷰 진입·`pollFreshness`), 후자는 **같은 파일이
/// 자랐나**를 묻는 자리라 포커스 이동을 세 방향 모두 놓쳤다:
///
///  ⑴ 에이전트가 안 붙은 pane 에서는 `chain` 이 비어 즉시 물러난다 → 에이전트 pane 으로 옮겨도
///     **영영 안 채워진다**(뷰를 껐다 켜야 했다).
///  ⑵ 반대 방향은 `activeSourcePath` 가 null 이라 역시 물러난다 → **옛 pane 의 이미지가 남는다.**
///  ⑶ 양쪽 다 에이전트면 자국이 달라 잡히기는 하나 **휴지기 뒤**다 — 최소 500 ms 이고 직전 스캔이
///     비쌌으면 최대 90 초다(`restIntervalMs`).
///
/// 그래서 **활성 surface id** 하나를 보고 바뀐 순간에 건다. 에이전트 세션 도크가 스코프를 같은 방식으로
/// 따라가고(`refreshAgentSessionArchiveProjectScopeForFocus`), 소스 컨트롤은 `followActiveTerminalRepo`
/// 로 같은 일을 한다 — 도크의 세 뷰가 같은 축을 쓴다.
///
/// **비운다/채운다를 여기서 가르지 않는다.** `refresh` 가 「소스가 없으면 비운다」 갈래를 이미 갖고
/// 있으므로 그 판정을 여기 복사하지 않는다 — 두 자리에 두면 한쪽만 고쳐진다.
pub fn refreshForFocus(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    const surface_id = activeSourceSurfaceId(self);
    if (self.agent_activity.focus_surface_id == surface_id) return;
    self.agent_activity.focus_surface_id = surface_id;
    refresh(self, false);
}

/// 뷰로 들어올 때 한 번 훑는다(계약 §4.1) — **그리고 그 순간의 pane 을 기록한다.** 기록하지 않으면
/// 곧바로 다음 tick 의 `refreshForFocus` 가 같은 소스로 스캔을 한 번 더 건다(1.68 GB 짜리 파일이 있다).
pub fn onEnterView(self: *AppSession) void {
    self.agent_activity.focus_surface_id = activeSourceSurfaceId(self);
    refresh(self, false);
}

/// 지금 갤러리가 보는 pane 의 surface id. `activeSourcePath` 와 **같은 축**(활성 pane 의 활성 Term)을
/// 봐야 「소스를 고른 pane」과 「바뀌었나를 재는 pane」이 갈리지 않는다.
///
/// 탭이 0 개인 창은 `0` 이다 — merge·이동으로 비워진 뒤 Swift 가 닫기 전 tick 이 있고, 그때
/// `activePane()` 이 빈 리스트를 인덱싱해 패닉한다(`activeSourcePath` 가 같은 가드를 두는 그 이유다).
fn activeSourceSurfaceId(self: *AppSession) u64 {
    if (!self.surface_initialized or self.tabs.items.len == 0) return 0;
    return pane_ops.activePane(self).activeTerm().surface.id;
}

/// tick 마다 부른다. 완료본을 가져오고, 못 걸었던 요청을 다시 건다.
///
/// **여기가 유일한 수확 지점이다.** 안 부르면 워커가 다 훑고도 화면이 영영 안 바뀐다.
pub fn poll(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;

    if (self.agent_activity.resubmit and !self.agent_activity.chain.isEmpty()) {
        if (backend.submit(self.agent_activity.chain, null)) |generation| {
            self.agent_activity.awaiting = generation;
            self.agent_activity.resubmit = false;
        }
    }

    harvestDecoded(self);
    ensureOpen(self);
    pollFreshness(self);
    pollBodySearch(self);

    var result = backend.take() orelse return;
    // **늦게 온 것은 버린다.** 소스가 그 사이 바뀌었으면 이 결과는 남의 파일 것이다.
    if (result.generation != self.agent_activity.awaiting) {
        result.deinit(self.allocator);
        return;
    }
    self.agent_activity.all_hits.deinit(self.allocator);
    self.agent_activity.all_hits = result.hits; // 소유 이동 — 여기서부터 세션이 푼다
    self.agent_activity.all_labels.deinit(self.allocator);
    self.agent_activity.all_labels = result.labels;
    // 길이가 어긋나면 라벨을 통째로 버린다 — 남의 이미지에 붙은 설명보다 없는 편이 낫다.
    if (self.agent_activity.all_labels.items.len != self.agent_activity.all_hits.items.len) {
        self.agent_activity.all_labels.clearRetainingCapacity();
    }
    // **순번은 여기서만 채운다**(계약 §2.2). 스캐너는 한 장씩 라벨을 만들어 이웃을 못 보고,
    // 걸러 낸 목록(`hits`)은 묶음이 쪼개져 「1/1」이 된다. 전체가 다 모인 지금이 유일하게 옳은 자리다.
    if (self.agent_activity.all_labels.items.len == self.agent_activity.all_hits.items.len) {
        const scanned = self.agent_activity.all_hits.items;
        for (self.agent_activity.all_labels.items, 0..) |*l, i| {
            const seq = index.sequenceAt(scanned, i);
            l.seq = seq.index;
            l.seq_total = seq.total;
        }
    }
    // **최신이 먼저다.** 스캐너는 파일 순서(= 오래된 것부터)로 담는데, 이 기능의 물음은
    // 「**아까** 그 스크린샷 어디 갔지」다. 실제 세션으로 재 보니 151 장 중 4 장만 보이는데
    // 그 4 장이 세션 맨 처음 것이었다 — 목적과 정확히 반대였다(합성 픽스처는 4 장이 다 보여
    // 이 결함을 원리적으로 못 본다).
    std.mem.reverse(index.Hit, self.agent_activity.all_hits.items);
    // **접기의 주인도 같이 뒤집는다**(§2.2.1). `fold_owner` 는 이 배열의 **자리**이므로, 뒤집고
    // 그대로 두면 엉뚱한 호출을 가리킨다 — 접힌 이미지가 남의 줄에 붙거나, 「전체」에서 사라진다.
    // 퇴출(`remapFoldsAfterEvict`)과 **같은 규율**이고 같은 이유로 판정자가 따로 못박는다.
    reverseFoldOwners(self.agent_activity.all_hits.items);
    // **라벨도 같이 뒤집는다.** 안 뒤집으면 첫 칸에 마지막 이미지의 설명이 붙는다.
    if (self.agent_activity.all_labels.items.len == self.agent_activity.all_hits.items.len) {
        std.mem.reverse(context.Label, self.agent_activity.all_labels.items);
    }
    // **본문 답은 인덱스가 자라면 낡는다**(적대적 3회차). 자동 갱신이 붙어 있어 대화가 이어지는
    // 내내 이 길로 오는데, 새로 들어온 호출은 옛 답에 없으므로 그대로 두면 **라벨 층만 새 줄을
    // 잡고 본문 층은 못 잡는다** — 화면이 반쪽만 갱신되고, 사용자에게는 「어떤 건 걸리고 어떤 건
    // 안 걸린다」로 보인다.
    //
    // 검색어가 걸려 있는 동안에만 다시 묻는다. 대가는 파일의 12% 를 한 번 더 읽는 것이고, 그
    // 길목의 스캔 자체가 이미 파일 전체를 훑은 참이다.
    if (self.agent_activity.body.query.items.len > 0) {
        // ⚠️ **도는 요청도 함께 접는다**(적대적 4회차). `answered` 만 끄면, 그때 요청이 **도는
        // 중**일 때(`awaiting != 0`) `settledFor` 가 여전히 참이라 재질문이 게이트에서 되돌아간다 —
        // 그리고 곧 도착하는 **옛 인덱스의 답**이 `answered` 를 세워 새 호출은 **영영 안 걸린다**.
        // 3회차가 고친 결함이 경합에서 그대로 되살아나는 자리이고, 본문 검색이 수백 ms 라 큰
        // 세션에서는 재스캔과 겹치는 것이 예외가 아니라 보통이다.
        suspendBodySearch(self);
        self.agent_activity.body.answered = false;
        self.agent_activity.body.resubmit = true;
    }
    // 원본이 바뀌었으니 보여줄 목록을 다시 만든다(검색어가 비면 전부).
    self.agent_activity.applyFilter(self.allocator);
    // **타일은 버리지 않고 새 인덱스에 다시 잇는다.** 자동 갱신이 붙은 뒤로 이 길은 「같은 파일이
    // 자랐다」에도 쓰이는데, 통째로 버리면 대화가 이어지는 내내 격자가 매 턴 비었다 다시 찬다
    // (장당 ~20 ms). 인덱스는 밀려도 `(file_index, data_offset)` 은 그대로다.
    //
    // ⚠️ **그림을 안 담는 필터에서는 여기서도 안 잇는다**(`rebuildFilter` 와 같은 규율). 그때
    // `hits` 에는 그림이 없어 `remapTiles` 가 전부 버리는데, 「명령」을 보는 동안 대화가 이어지면
    // 그 사이 픽셀이 통째로 사라져 돌아올 때 다시 디코드한다. 안 그리는 화면이므로 자리가 낡아도
    // 무해하고, 돌아올 때 잇는다.
    if (self.agent_activity.filter.holdsImages()) remapTiles(self);
    // 크게 보기는 그대로 버린다 — 자동 갱신은 애초에 열려 있으면 미루므로(`pollFreshness`) 여기
    // 도달하는 것은 소스가 갈렸을 때뿐이고, 그때는 다른 세션이라 닫는 것이 맞다.
    self.agent_activity.dropOpen(self.allocator);
    // **호버도 옛 인덱스다.** 이미지가 줄면 없는 칸을 가리키고, 안 줄어도 그 자리엔 다른 이미지가
    // 온다(최신 우선이라 순서가 통째로 바뀐다). 다음 마우스 이동이 다시 잡는다.
    self.agent_activity.hovered = null;
    // **스크롤을 새 상한으로 끌어내린다.** 목록이 줄었는데 옛 위치가 남으면, 위로 굴려도 한동안
    // 화면이 안 움직인다 — `scrollByPx` 는 내려갈 때만 상한을 보기 때문이다(올라갈 때는 그냥 뺀다).
    // 리셋이 아니라 clamp 라, 보던 행이 아직 있으면 그 자리에 그대로 있는다.
    clampScroll(self);
    self.agent_activity.partial = result.partial;
    self.agent_activity.image_partial = result.image_partial;
    self.agent_activity.activity_partial = result.activity_partial;
    self.agent_activity.scanned_bytes = result.scanned_bytes;
    self.agent_activity.scan_ns = result.scan_ns;
    // **원격 왕복이 통째로 실패했나**(RAV3). 저쪽에서 아무 바이트도 못 읽고 자리도 0 이면 그것은
    // 「활동이 없다」가 아니라 **「못 읽었다」**다 — 헬퍼가 없거나(exit 127) 채널이 끊긴 것이고,
    // 그 둘을 화면이 가려야 한다(계약 §2.2).
    //
    // ⚠️ **`partial` 만으로는 못 가른다.** 상한에 잘린 정상 스캔도 `partial` 이다. 「한 바이트도
    // 못 봤고 자리도 없다」가 실패의 모양이다.
    self.agent_activity.remote_failed = self.agent_activity.source_remote and
        result.partial and result.scanned_bytes == 0 and result.hits.items.len == 0;
    // **원격 자국을 찍는다**(RAV7). 다음 신선도 확인이 이 자리에서 1 바이트를 청해 자랐는지 본다 —
    // 로컬의 `head_stamp`(stat)에 해당하는 값이다.
    //
    // ⚠️ **체인이 하나일 때만 찍는다**(적대적 S1). `scanned_bytes` 는 **체인 전체의 합**이라 파일이
    // 둘 이상이면 머리 파일의 크기가 아니다 — 그 자리에서 1 바이트를 청하면 **영영 빈 답**이고
    // 신선도가 죽는다(Codex 재개는 실측 58%). 0 이면 신선도가 꺼지고 재진입마다 다시 훑는다 —
    // **덜 아는 쪽**으로 기운다.
    if (self.agent_activity.source_remote) {
        self.agent_activity.remote_scanned_bytes =
            if (result.remote_file_count == 1) result.scanned_bytes else 0;
    }
    self.agent_activity.built = true;
    self.agent_activity.awaiting = 0;
    self.agent_activity.resubmit = false;
    self.metal_dirty = true;
    // 디버그 훅(`MARU_FORCE_IMAGE_GALLERY_OPEN`)이 예약해 둔 크게 보기를 **여기서** 연다 — 인덱스가
    // 방금 생겼기 때문이다. 예약은 한 번만 쓴다.
    if (self.debug_agent_activity_open) |n| {
        self.debug_agent_activity_open = null;
        openAt(self, n);
    }
    // `MARU_FORCE_IMAGE_GALLERY_BODY` — `Enter` 를 누른 것처럼 본문까지 넓힌다. 예약은 한 번만 쓴다.
    if (self.debug_agent_activity_body_search) {
        self.debug_agent_activity_body_search = false;
        self.agent_activity.search_active = false; // `Enter` 는 창을 닫는다 — 안내 줄이 보여야 한다
        submitBodySearch(self);
    }
    // `MARU_FORCE_IMAGE_GALLERY_HOVER=<n>` — 그 칸에 포인터가 얹힌 것처럼 세운다. 실제 호버는 마우스
    // 이동이 필요해 헤드리스로는 만들 수 없다(상태바 호버가 같은 이유로 같은 게이트를 둔다).
    if (self.debug_agent_activity_hover) |n| {
        self.debug_agent_activity_hover = null;
        if (n < self.agent_activity.count()) self.agent_activity.hovered = n;
    }
}

/// 격자에 보이는 칸만큼 타일을 채운다. **tick 당 최대 하나만 푼다.**
///
/// 장당 ~20 ms 라(계약 §5.2) 24칸을 한 프레임에 풀면 480 ms 가 멈춘다. 한 장씩 차오르게 두면 각 프레임은
/// 한 장 몫만 쓰고 격자가 눈앞에서 채워진다. **이것은 워커의 대체가 아니라 그 전 단계다** — 한 장 20 ms 도
/// 프레임 예산(16.7 ms)을 넘으므로, 디코드 워커는 후속에서 붙인다.
/// 「전체」의 줄 왼쪽에 두는 썸네일의 **자리**(AV5, 사용자 결정 2026-09-08).
///
/// **줄 높이에 맞춘다** — 줄마다 높이가 다르면 `listWindow` 의 스크롤·창 계산이 통째로 가변이
/// 되고, 계약 §2.2.3 의 「좁아지면 시각부터 버린다」와도 부딪힌다. 그 대가로 그림은 작아서
/// 「무슨 그림인가」까지는 못 말하지만 **「여기 그림이 있다」는 확실히 말한다** — 실측상 그런
/// 줄이 60 줄에 한 줄이라(중앙 1.7%) 훑을 때의 표지로 값이 있다.
///
/// 세로로는 줄 안에 여백을 남긴다. 줄에 꽉 채우면 위아래 줄과 붙어 목록이 답답해진다.
const thumb_row_padding_px: u32 = 2;

/// 썸네일 칸의 **가로 폭**(px). 격자 타일이 2:1 이므로(`gridMetrics`) 같은 비율로 잡는다 —
/// 실측에서 가로로 긴 그림이 79% 라 세로에 맞추면 대부분 이 폭을 다 쓴다.
fn thumbCellSize(self: *const AppSession) struct { w: u32, h: u32 } {
    const h = listRowHeightPx(self) -| (thumb_row_padding_px *| 2);
    return .{ .w = h *| 2, .h = h };
}

/// 그 줄의 썸네일 사각형. 목록이 아니거나 자리가 없으면 `null`.
pub fn thumbRectAt(self: *const AppSession, row_top_y: u32) ?image_grid.Rect {
    const area = gridArea(self);
    const size = thumbCellSize(self);
    if (size.h == 0 or size.w == 0) return null;
    // **글자가 설 자리가 없으면 그림도 안 그린다.** 그림이 줄을 통째로 먹으면 무엇에 붙은
    // 그림인지 알 수 없다(§2.2.3 과 같은 규율 — 마지막까지 지키는 것은 「무엇인가」다).
    if (area.w <= size.w *| 2) return null;
    return .{ .x = area.x, .y = row_top_y +| thumb_row_padding_px, .w = size.w, .h = size.h };
}

/// 목록에서 썸네일이 **글자를 미는 칸 수**. 0 이면 안 민다.
///
/// 그림이 붙는 줄은 드물지만(실측 60 줄에 한 줄) **자리는 모든 줄이 똑같이 비운다** — 줄마다
/// 들쭉날쭉하면 이름이 세로로 안 맞아 훑기 어렵다.
pub fn thumbCols(self: *const AppSession) u16 {
    if (self.agent_activity.filter != .all) return 0;
    if (self.cell_width_px == 0) return 0;
    const area = gridArea(self);
    if (thumbRectAt(self, area.y) == null) return 0;
    const size = thumbCellSize(self);
    // 그림 폭 + 한 칸 띄우기.
    const want: u16 = @intCast(@min((size.w + self.cell_width_px - 1) / self.cell_width_px + 1, @as(u32, 32)));

    // ⚠️ **대상이 먼저다**(계약 §2.2.3). 그림이 자리를 가져가고 나서 이름이 `min_label_cols` 아래로
    // 떨어지면 「무엇에 붙은 그림인지」를 잃는다 — 좁아지면 **시각부터** 버리는 그 규율에서 썸네일은
    // 시각보다도 나중에 지킬 것이다.
    //
    // 실측(적대적 4 회차)이 이 게이트를 요구했다: 이것이 없으면 `cols=9` 에서 이름이 **3 칸**으로
    // 줄고, 더 좁혀 `cols=8` 이 되면 그림이 꺼지며 이름이 **8 칸으로 되돌아온다** — **좁힐수록
    // 이름이 늘어나는 역전**이라, 사용자가 도크를 줄이다가 글자가 되살아나는 것을 본다.
    const total: u16 = @intCast(@min(area.w / self.cell_width_px, @as(u32, std.math.maxInt(u16))));
    if (total < want +| min_label_cols) return 0;
    return want;
}

/// 그 줄에 그릴 **그림 바이트가 어디 있나**. 없으면 `null` 이다.
///
/// 두 갈래를 여기서 합친다 — 이미지 항목은 **자기 자리**를, 결과가 그림인 호출은 **접힌 그림의
/// 자리**를 준다(AV5 · §2.2.1). 두 벌로 두면 「격자에는 뜨는데 목록에는 안 뜬다」가 생긴다.
pub const ThumbSource = struct { file_index: u8, offset: u64, len: u32 };

pub fn thumbSource(hit: index.Hit) ?ThumbSource {
    if (hit.kind.isImage()) return .{
        .file_index = hit.file_index,
        .offset = hit.data_offset,
        .len = hit.data_len,
    };
    // 접힌 그림 — 그 줄은 호출이고, 그림 자리는 결과가 든다.
    if (hit.result.image and hit.result.image_len > 0) return .{
        .file_index = hit.result.image_file,
        .offset = hit.result.image_offset,
        .len = hit.result.image_len,
    };
    return null;
}

pub fn ensureTiles(self: *AppSession, first: usize, visible: usize) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = decodeBackendPtr(self) orelse return;
    // **크게 보기가 워커를 먼저 쓴다.** 사용자가 방금 누른 것보다 아직 안 보이는 칸이 급할 리 없다.
    if (self.agent_activity.open != null) return;
    if (self.agent_activity.chain.isEmpty()) return;

    // **보이는 칸 중 아직 없는 것**을 채운다. 창을 통째로 버리지 않는 이유는 그렇게 하면 스크롤할
    // 때마다 격자가 ~160 ms(8장 × 20 ms) 비어 깜빡이기 때문이다. 상한(`max_tiles` = 15 MB)은
    // 계약 §5.2 가 허용하는 값이고 실측 세션이 151 장이라 실제로는 거의 안 걸린다.
    // **빈 칸을 상한까지 채워 건다.** 하나만 걸고 물러나면 나머지는 다음 틱을 기다린다 —
    // 그것이 12 칸에 200 ms 를 쓰게 하던 원인이다(실측: 실제 일은 52 ms).
    const last = @min(first +| visible, self.agent_activity.count());
    var next: usize = first;
    while (next < last) : (next += 1) {
        if (self.agent_activity.tileFor(next) != null) continue; // 이미 있다
        if (self.agent_activity.pendingContains(next)) continue; // 이미 걸었다

        const hit = self.agent_activity.hits.items[next];
        // ⚠️ **없으면 건너뛴다(포기하지 않는다).** 격자에서는 모든 항목이 그림이라 차이가 없지만,
        // 「전체」 목록에서는 그림 있는 줄이 **60 줄에 한 줄**이다(실측 중앙 1.7%) — 여기서 물러나면
        // 첫 번째 그림 없는 줄에서 멈춰 뒤쪽 그림을 영영 안 건다.
        const src = thumbSource(hit) orelse continue;
        // **두 문 중 하나를 지난다**(§6.3): 로컬이면 `pathForIndex`, 원격이면 `remotePathForIndex` 다.
        // 여기서 `chain.get` 을 직접 부르면 그 갈림을 우회해 원격 오프셋이 로컬 디코드로 간다.
        const remote = decodeRemoteTarget(self);
        defer if (remote) |r| self.allocator.free(r.owned);
        const path = (if (remote != null)
            remotePathForIndex(self, src.file_index)
        else
            pathForIndex(self, src.file_index)) orelse continue;
        if (backend.submit(
            path,
            src.offset,
            src.len,
            thumbnail_side,
            next,
            if (remote) |r| r.target else null,
        )) |generation| {
            self.agent_activity.pendingAdd(generation, next);
        } else break; // 상한에 닿았다 — 다음 틱이 이어 건다
    }
}

/// 디코드 완료본을 수확한다. `poll` 이 tick 마다 부른다.
///
/// **순서를 지킨다** — 다음에 채울 칸(`tiles.len`)의 것이 아니면 버린다. 순서가 어긋나면 격자의 그림과
/// 인덱스가 갈리는데, 그것은 「엉뚱한 이미지가 뜬다」로 보이지 「비었다」로 보이지 않아 알아채기 어렵다.
/// 준비된 완료본을 **전부** 가져간다.
///
/// 예전에는 틱당 하나였다. 워커를 여럿으로 늘려도 여기가 하나면 처리량은 그대로 틱 주기에 묶인다 —
/// 제출과 수확은 **둘 다** 고쳐야 뜻이 있다(적대적 검증이 짚은 자리).
fn harvestDecoded(self: *AppSession) void {
    while (harvestOne(self)) {}
}

/// 완료본 하나를 반영한다. 가져올 것이 없으면 `false`.
fn harvestOne(self: *AppSession) bool {
    const backend = decodeBackendPtr(self) orelse return false;
    var r = backend.take() orelse return false;
    defer r.deinit(self.allocator); // 아래에서 소유를 옮기면 pixels 를 비워 둔다

    // **크게 보기 것이 먼저다.** 두 요청은 같은 워커를 쓰므로 generation 으로 가른다.
    if (self.agent_activity.open) |*op| {
        if (op.decoding != 0 and r.generation == op.decoding) {
            // **못 풀었으면 가진 것을 지킨다.** 승급은 덤이라, 실패했다고 보고 있던 그림을
            // 버리면 화면이 빈다(원본 디코드는 크기 때문에 실제로 실패할 수 있다).
            if (op.upgrading and r.pixels.len == 0) {
                op.decoding = 0;
                op.upgrading = false;
                return true;
            }
            const was_upgrade = op.upgrading and op.pixels.len > 0 and op.width > 0 and r.width > 0;
            const old_w = op.width;
            op.decoding = 0;
            op.upgrading = false;
            self.allocator.free(op.pixels);
            op.width = r.width;
            op.height = r.height;
            op.pixels = r.pixels;
            r.pixels = &.{}; // 소유가 넘어갔다
            op.decoded_subsample = r.subsample;
            op.uploaded = false;
            if (was_upgrade) {
                // **보던 자리를 지킨다.** 같은 그림을 더 선명하게 다시 푼 것이므로 fit 으로 되돌리면
                // 확대해 보던 사람을 처음으로 끌고 간다. `pan` 은 화면 px 라 그대로 두고, `scale` 은
                // 이미지 px 당 화면 px 라 텍스처가 커진 만큼 나눈다 — 그리는 크기가 그대로다.
                op.view.scale = op.view.scale * @as(f32, @floatFromInt(old_w)) / @as(f32, @floatFromInt(r.width));
                op.view = image_view.clamp(op.view, viewportRect(self), op.width, op.height);
            } else {
                op.view = .{}; // 새 픽셀이면 fit 부터 — 옛 배율은 다른 이미지의 것이다
            }
            self.metal_dirty = true;
            return true;
        }
    }

    // **내가 건 것인가.** 여럿이 도니 generation 으로 집합에서 찾는다.
    const submitted_index = self.agent_activity.pendingTake(r.generation) orelse return true;
    // **내가 건 그 칸의 것인가.** 배열 위치가 아니라 인덱스로 판정한다 — 스크롤이 배열 순서를
    // 바꾸므로 순서로 판정하면 결과가 조용히 버려진다.
    if (r.hit_index != submitted_index) return true;
    if (self.agent_activity.tileFor(r.hit_index) != null) return true; // 이미 있다(중복 제출 방어)

    // 이 픽셀이 **어느 이미지**의 것인지 함께 적어 둔다 — 다시 훑은 뒤 인덱스가 밀려도
    // 그 정체로 타일을 다시 이을 수 있다(`remapTiles`).
    // ⚠️ **정체는 「무엇을 디코드했나」다.** 접힌 줄에서는 그것이 `Hit` 자신이 아니라 **결과가 든
    // 그림의 자리**다(`thumbSource` — `ensureTiles` 가 제출할 때 쓴 바로 그 값). 여기서 `Hit` 의
    // 오프셋(호출이면 명령문 자리)을 적으면 `remapTiles` 가 그 타일을 영영 못 찾아 **다시 훑을
    // 때마다 픽셀을 버리고 새로 디코드**한다 — 격자에서 「매 턴 비었다 다시 찬다」를 막으려고
    // 만든 장치가 목록에서 무력해진다. 제출·정체·재연결이 **같은 함수**를 봐야 한다.
    const hit_src = if (r.hit_index < self.agent_activity.hits.items.len)
        self.agent_activity.hits.items[r.hit_index]
    else
        return true;
    const thumb = thumbSource(hit_src) orelse return true;

    // **못 푼 것도 자리를 차지한다.** 안 그러면 그 칸에서 매 tick 다시 시도해 뒤 칸이 영영 안 찬다.
    self.agent_activity.tiles.append(self.allocator, .{
        .hit_index = r.hit_index,
        .file_index = thumb.file_index,
        .data_offset = thumb.offset,
        .width = r.width,
        .height = r.height,
        .pixels = r.pixels,
        .generation = 1,
        .label = labelFor(self, r.hit_index),
    }) catch return true;
    r.pixels = &.{}; // 소유가 타일로 넘어갔다 — defer 가 두 번 풀지 않게 비운다
    self.agent_activity.evictFarthest(self.allocator, r.hit_index);
    self.metal_dirty = true;
    return true;
}

/// 훅이 소스를 바꿨을 때. **갤러리를 보고 있을 때만 건다** — 안 보는 뷰 때문에 1.68 GB 를 훑지 않는다.
/// 보고 있지 않으면 다음에 들어올 때 `refresh` 가 경로 불일치를 보고 알아서 건다.
pub fn onSourceChanged(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    refresh(self, false);
}

/// 갤러리를 떠날 때. 도는 스캔을 취소한다 — 안 보는 화면 때문에 3.6 초를 끝까지 돌 이유가 없다.
pub fn onLeaveView(self: *AppSession) void {
    self.agent_activity.search_active = false;
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    backend.cancel();
    if (decodeBackendPtr(self)) |d| d.cancel();
    suspendBodySearch(self);
    self.agent_activity.awaiting = 0;
    self.agent_activity.resubmit = false;
    self.agent_activity.pendingClear();
    // 크게 보기도 닫는다 — 원본 픽셀은 수 MB 라, 안 보는 뷰 때문에 들고 있을 이유가 없다.
    self.agent_activity.dropOpen(self.allocator);
    self.agent_activity.key_focus = false;
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
    if (n >= self.agent_activity.hits.items.len) return null;
    if (self.agent_activity.chain.isEmpty()) return null;
    const hit = self.agent_activity.hits.items[n];

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
    // **문맥 줄만큼 아래를 비운다.** 안 비우면 글자가 그림 위에 얹혀 둘 다 못 읽는다.
    // 팬·줌은 이 사각형을 기준으로 계산하므로(`image_view`) 여기만 줄이면 나머지는 따라온다.
    const reserved = contextRows(self) *| labelHeightPx(self);
    return .{
        .x = @floatFromInt(a.x +| pad),
        .y = @floatFromInt(a.y +| pad),
        .w = @floatFromInt(a.w -| (pad *| 2)),
        .h = @floatFromInt(a.h -| (pad *| 2) -| reserved),
    };
}

/// 크게 보기 아래에 내줄 줄 수(출처 한 줄 + 문맥 몇 줄). 없으면 0 — 빈 띠를 남기지 않는다.
///
/// **`viewportRect` 가 이 값으로 그림 자리를 줄인다.** 그래서 여기서 세는 줄과 `collectOpenContext`
/// 가 실제로 그리는 줄이 어긋나면 글자가 그림 위에 얹히거나 아래가 잘린다 — 두 곳이 같은 함수를
/// 부르게 해 그 어긋남을 원리적으로 막는다.
fn contextRows(self: *const AppSession) u32 {
    const op = if (self.agent_activity.open) |*o| o else return 0;
    var rows: u32 = 0;
    var buf: [context_mod.max_label_bytes]u8 = undefined;
    if (openPrefix(self, &buf).len > 0) rows += 1;
    if (op.contextText().len > 0) rows += max_context_rows;
    return rows;
}

/// 크게 보고 있는 한 장의 **출처 + 순번**. 격자 라벨과 같은 조립을 쓴다(계약 §2.2.1).
///
/// **격자에만 붙이면 절반만 답한 것이다.** 눌러서 크게 본 화면에는 격자가 없으므로, 거기서 「이건
/// 내가 올린 것인가」를 물으면 답할 길이 사라진다 — 정작 그 물음이 나오는 자리가 여기다.
fn openPrefix(self: *const AppSession, buf: []u8) []const u8 {
    const op = if (self.agent_activity.open) |*o| o else return buf[0..0];
    return context_mod.originPrefix(buf, originText(op.label.source), op.label.seq, op.label.seq_total);
}

/// 문맥에 내줄 최대 줄 수. 실측 길이 p90 이 311 B 라 도크 폭에서 서너 줄이면 담긴다 —
/// 그보다 키우면 그림 자리를 먹는다(크게 보기의 본체는 그림이다).
pub const max_context_rows: u32 = 3;

/// `n` 번째 이미지를 크게 연다. **픽셀은 여기서 안 푼다** — 워커에 요청만 걸고, 그동안 격자가 계속 보인다.
/// 다 풀리기 전에 격자를 지우면 클릭이 「화면이 비었다」로 보인다.
pub fn openAt(self: *AppSession, n: usize) void {
    if (n >= self.agent_activity.count()) return;
    self.agent_activity.dropOpen(self.allocator);
    self.agent_activity.open = .{ .hit_index = n, .label = labelFor(self, n) };
    loadOpenContext(self, n);
    // **격자를 그 칸으로 맞춰 둔다.** 클릭으로 열 때는 이미 보이므로 아무 일도 없고, ←→ 로 멀리
    // 넘어갔을 때만 움직인다 — 그러지 않으면 닫는 순간 격자가 **옛 자리**를 보여주고 방금 보던
    // 이미지가 화면 밖에 있다. 여는 자리 한 곳에서 하므로 두 입구가 갈리지 않는다.
    self.agent_activity.scroll.offset_y_px = image_grid.scrollToShow(
        gridArea(self),
        gridMetrics(self),
        self.agent_activity.count(),
        self.agent_activity.scroll.offset_y_px,
        n,
    );
    self.metal_dirty = true;
    // **활동 항목에는 그림이 없다.** `ensureOpen` 을 부르면 명령 문자열을 이미지로 디코드하려 들어
    // 「열지 못했습니다」가 뜬다(main 이 목록 클릭을 막아 두었던 그 이유다). 대신 그때 받은 바이트를
    // 읽는다 — 같은 자리를 쓰되 채우는 것이 다르다(계약 §2.4).
    if (n < self.agent_activity.hits.items.len and !self.agent_activity.hits.items[n].kind.isImage()) {
        loadOpenDetail(self, n);
        return;
    }
    ensureOpen(self);
}

/// 펼침의 본문 두 조각을 **그때의 바이트에서** 읽는다(AV3 — 계약 §2.4).
///
/// **파일을 다시 실행하지 않는다.** `grep` 매치 줄이나 파이프 조합은 지금 다시 돌려서 되살릴 수 없고,
/// 파일이 그새 바뀌었을 수도 있다. 트랜스크립트에 그대로 있는 바이트가 「에이전트가 본 것」이다.
///
/// **여기서 한 번만 읽는다** — 크게 보기의 문맥(`loadOpenContext`)과 같은 규율이다. 라벨처럼 워커가
/// 미리 만들지 않는 이유도 같다: 12,200 개어치 8 KiB 를 늘 들고 있을 이유가 없다.
fn loadOpenDetail(self: *AppSession, n: usize) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const op = if (self.agent_activity.open) |*o| o else return;
    if (n >= self.agent_activity.hits.items.len) return;
    const hit = self.agent_activity.hits.items[n];

    // **원격이면 저쪽에서 당겨온다**(RAV5b). `pathFor` 는 원격에서 null 이라(§13.6 N1) 여기서
    // 갈리지 않으면 펼침이 영영 빈다 — 그 가드의 뜻은 「이쪽 파일을 안 연다」이지 「못 보여 준다」가
    // 아니다.
    if (self.agent_activity.source_remote) {
        op.detail.deinit(self.allocator);
        self.agent_activity.detail_generation +%= 1;
        beginRemoteDetail(self, n, hit);
        return;
    }

    const path = pathFor(self, hit) orelse return;
    const file = std.Io.Dir.cwd().openFile(self.io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return;
    defer file.close(self.io);

    // **명령 전문을 보여 준다**(계약 §2.2 ⚠️ — 「description 은 명령과 어긋날 수 있다, 그래서 펼치면
    // 언제나 명령 전문이 먼저 나온다」). 라벨의 대상은 대개 그 요약이므로 **대상 자리를 그대로 읽으면
    // 같은 요약을 두 번 보여 주고 명령은 영영 안 보인다**(적대적 검증에서 잡았다).
    const cmd_offset = if (hit.cmd_rel != 0) hit.line_offset +| hit.cmd_rel else hit.data_offset;
    // 명령은 언제나 **값 하나**다(배열이 아니다) — Codex 는 `input` 이 문자열이고, Claude 는
    // 라벨이 고른 값 하나를 가리킨다.
    op.detail.command = readDetailPart(self, file, cmd_offset, false, &op.detail.command_truncated, null);
    if (hit.result.found) {
        op.detail.has_result = true;
        // **본문이 없는 그림 결과는 「이미지」라고 적는다.** Claude 는 `content` 가 이미지 블록만
        // 들어(실측 542/542) 읽을 자리가 없다 — 그대로 두면 「결과」 칸이 빈 채로 서서 「못 읽었다」
        // 처럼 보인다. AV5 가 여기에 썸네일을 붙일 자리이기도 하다.
        //
        // Codex 는 `output` 첫 원소가 `text` 라 읽을 것이 있다 — 그쪽은 아래 갈래로 간다.
        if (hit.result.image and hit.result.lines == 0) {
            op.detail.result = self.allocator.dupe(u8, maru.i18n.t(.agent_activity_result_image)) catch &.{};
            op.detail.result_truncated = false;
        } else {
            op.detail.result = readDetailPart(
                self,
                file,
                hit.result.body.offset,
                hit.result.body.is_array,
                &op.detail.result_truncated,
                &op.detail.result_exit_code,
            );
        }
    }
    self.metal_dirty = true;
}

/// 한 조각을 읽어 **여러 줄 그대로** 푼다. 못 읽으면 빈 조각이다 — 없는 내용을 지어내지 않는다.
///
/// `is_array` 면 값 하나가 아니라 **배열 안 `text` 들을 순서대로 잇는다**(Codex `output`). 그 규칙은
/// 순수 모듈이 소유하고, 여기서는 어느 쪽인지만 고른다 — 「무엇이 배열인가」의 판정은 스캐너가 이미
/// 했고(`ResultSummary.body_is_array`), 여기서 바이트를 보고 다시 짐작하면 규칙이 두 벌이 된다.
fn readDetailPart(
    self: *AppSession,
    file: std.Io.File,
    offset: u64,
    is_array: bool,
    truncated: *bool,
    /// chunk 껍데기에서 읽은 종료 코드를 여기에 든다(없으면 건드리지 않는다).
    exit_code: ?*?i32,
) []u8 {
    if (offset == 0) return &.{};
    const raw = self.allocator.alloc(u8, max_detail_bytes) catch return &.{};
    defer self.allocator.free(raw);
    var read: usize = 0;
    while (read < raw.len) {
        const got = file.readPositional(self.io, &.{raw[read..]}, offset + read) catch break;
        if (got == 0) break;
        read += got;
    }
    if (read == 0) return &.{};
    return decodeDetailPart(self, raw[0..read], is_array, truncated, exit_code);
}

/// 받은 바이트를 **펼침이 그릴 텍스트**로 푼다 — 이스케이프·배열 잇기·chunk 봉투 벗기기.
///
/// 🔥 **로컬과 원격이 이 함수 하나를 지난다**(RAV5b). 읽는 방법만 다르고(positional read vs 원격
/// 구간 왕복) **푸는 규칙은 같아야 한다** — 두 벌이면 원격 펼침이 로컬과 다른 글자를 보여 주고,
/// 그것이 이 뷰의 최악 실패다(계약 §2.3).
fn decodeDetailPart(
    self: *AppSession,
    raw: []const u8,
    is_array: bool,
    truncated: *bool,
    exit_code: ?*?i32,
) []u8 {
    const read = raw.len;
    if (read == 0) return &.{};
    const out = self.allocator.alloc(u8, read) catch return &.{};
    defer self.allocator.free(out);
    const block = if (is_array)
        context_mod.unescapeTextArray(out, raw[0..read])
    else
        context_mod.unescapeBlock(out, raw[0..read]);
    // **「다 봤나」는 `complete` 가 답한다**(적대적 2회차). `truncated` 만 보면 이 깃발은 영원히
    // 거짓이다 — `out` 을 읽어 온 만큼 잡아 주는데 푸는 일은 바이트를 늘리지 않기 때문이다.
    // 그래서 8 KiB 를 넘는 명령·결과가 **잘렸다는 말 없이** 잘려 있었다(계약 §2.4 위반).
    truncated.* = block.truncated or !block.complete;
    if (exit_code) |slot| slot.* = block.exit_code;
    if (block.len == 0) return &.{};
    // ⚠️ **정확한 길이로 새로 잡아 복사한다.** `realloc` 이 실패했을 때 `out[0..len]` 을 돌려주면
    // **할당 길이와 다른 슬라이스**가 밖으로 나가고, 그것을 `free` 하는 순간 할당자가 죽는다
    // (적대적 검증 1 회차 — 성공 경로만 보면 안 보이는 자리다).
    const exact = self.allocator.alloc(u8, block.len) catch return &.{};
    @memcpy(exact, out[0..block.len]);
    return exact;
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
    if (self.agent_activity.search_active) return false; // 타이핑 중 화살표는 검색창 것이다
    const op = if (self.agent_activity.open) |o| o else return false;
    const count = self.agent_activity.count();
    if (count == 0) return false;

    const cur: i64 = @intCast(op.hit_index);
    const next = cur + delta;
    if (next < 0 or next >= @as(i64, @intCast(count))) return true; // 끝 — 소비는 하되 안 움직인다
    const target: usize = @intCast(next);
    if (target == op.hit_index) return true;
    openAt(self, target);
    return true;
}

/// 종류 필터를 다음으로 넘긴다. 소비했으면 `true`.
///
/// **갤러리가 키를 쥐고 있을 때만** 가져간다(`ownsKeys`). 검색 중에는 물러난다(그때 Tab 은 검색창 것).
///
/// **키 라우팅에서는 빠졌다(AV4).** 이 함수는 이제 칩(`setFilter`)과 판정자만 부른다 — `Tab` 은
/// 도크를 한 번 클릭하면 `key_focus` 가 남아 **터미널 자동완성을 뺏었고**(적대적 검증 D1), 제대로 된
/// 자리(칩)가 생긴 지금은 그 대가를 치를 이유가 없다. 순환 자체는 남겨 둔다 — 나중에 키바인딩을
/// 다시 준다면 그때 쓰는 것이 이 함수이고, 판정자도 「네 자리를 다 돈다」를 여기로 시험한다.
pub fn cycleFilter(self: *AppSession) bool {
    if (!ownsKeys(self)) return false;
    if (self.agent_activity.search_active) return false;
    // 크게 보기는 닫는다 — 그 그림이 다음 필터에는 없을 수 있고, 남겨 두면 「목록을 바꿨는데 남의
    // 그림이 떠 있다」가 된다.
    closeOpen(self);
    self.agent_activity.filter = self.agent_activity.filter.next();
    // 목록이 통째로 바뀌므로 보던 자리도, 얹혀 있던 칸도 뜻을 잃는다.
    self.agent_activity.scroll.offset_y_px = 0;
    self.agent_activity.hovered = null;
    // **넘친 수도 옛 모양의 것이다.** 격자에서 넘쳐 있었다면 그 값이 남아, 목록의 첫 프레임이
    // 그려지기 전에 「도크가 좁아 못 그립니다」가 한 번 스친다. 렌더가 다시 채운다.
    self.agent_activity.overflow = 0;
    rebuildFilter(self);
    self.metal_dirty = true;
    return true;
}

/// 크게 보기를 닫고 격자로 돌아간다. 원본 픽셀(수 MB)을 여기서 푼다.
pub fn closeOpen(self: *AppSession) void {
    if (self.agent_activity.open == null) return;
    self.agent_activity.dropOpen(self.allocator);
    self.metal_dirty = true;
}

/// 크게 보기의 그림을 워커에 건다. 워커가 바쁘면 다음 tick 이 다시 건다(`poll`).
///
/// **먼저 뷰포트에 맞춰 푼다.** 예전에는 `target_side = 0`(원본)이었는데, 실측 최대 이미지
/// (1440×14771 = 21.3 MP)를 열면 **85 MB** 를 상주·업로드해 400 px 도크에 그렸다 — 200 배 낭비다
/// (계약 §5.3 이 「뷰포트 기준 상한이 후속」이라고 적어 둔 그 자리).
///
/// **확대하면 그때 원본으로 다시 푼다.** `scale > 1` 은 「가진 픽셀을 늘려 그리는 중」이라는 뜻이고,
/// 그때부터는 원본이 실제로 더 보여 준다. 한 번 원본으로 올라가면 `decoded_subsample == 1` 이라
/// 다시는 안 건다 — 되풀이가 없다.
pub fn ensureOpen(self: *AppSession) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const op = if (self.agent_activity.open) |*o| o else return;
    if (op.decoding != 0) return;
    if (self.agent_activity.chain.isEmpty()) return;
    if (op.hit_index >= self.agent_activity.count()) return;
    const backend = decodeBackendPtr(self) orelse return;

    const have = op.pixels.len > 0;
    // 이미 원본으로 풀었거나(더 선명해질 여지 없음) 아직 늘려 그리지 않으면 그대로 둔다.
    const want_full = have and !op.full_tried and op.decoded_subsample > 1 and op.view.scale > 1.0;
    if (have and !want_full) return;

    const vp = viewportRect(self);
    const target: u32 = if (want_full) 0 else blk: {
        const side = @max(vp.w, vp.h);
        if (!(side > 0)) break :blk 0; // 아직 자리를 모른다 — 상한만 지켜 푼다
        break :blk @intFromFloat(side);
    };

    const hit = self.agent_activity.hits.items[op.hit_index];
    const remote = decodeRemoteTarget(self);
    defer if (remote) |r| self.allocator.free(r.owned);
    const path = (if (remote != null)
        remotePathForIndex(self, hit.file_index)
    else
        pathFor(self, hit)) orelse return;
    if (backend.submit(
        path,
        hit.data_offset,
        hit.data_len,
        target,
        op.hit_index,
        if (remote) |r| r.target else null,
    )) |generation| {
        op.decoding = generation;
        op.upgrading = want_full;
        if (want_full) op.full_tried = true;
    }
}

/// 휠·트랙패드로 **포인터를 붙잡고** 확대·축소한다. 가운데 기준이면 보려던 곳이 밖으로 밀려나
/// 매번 팬으로 쫓아가야 한다(계산은 `image_view.zoomAt`).
///
/// 트랙패드(`precise`)는 점 단위라 눈금보다 훨씬 촘촘히 온다 — 같은 계수를 쓰면 한 번 쓸어도 최대
/// 배율에 닿는다. 그래서 계수를 나누고, 한 이벤트가 만드는 배율 변화를 e^±1 로 묶는다.
pub fn wheelZoom(self: *AppSession, delta_y: f64, precise: bool, x_px: f64, y_px: f64) void {
    const op = if (self.agent_activity.open) |*o| o else return;
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
    const op = if (self.agent_activity.open) |*o| o else return;
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
    self.agent_activity.applyFilter(self.allocator);
    // **버리지 않고 다시 잇는다.** 예전에는 통째로 버렸는데, 그러면 「전체」↔「이미지」를 오갈 때마다
    // 그림이 **사라졌다가 다시 뜬다** — 실측 11 장에서 **306 ms** 다. 칩으로 종류를 바꾸는 것이
    // AV4 의 요점인데 그때마다 화면이 깜빡이면 그 기능이 값을 잃는다.
    //
    // 다시 잇는 것이 **가능해진 것은 AV5 덕이다**: `remapTiles` 가 `thumbSource` 로 찾으므로
    // 그림 자신(「이미지」)과 접힌 호출(「전체」)이 **같은 키**(`file_index`·`data_offset`)를 갖는다.
    // 그 전에는 두 도메인의 키가 달라 다시 이을 방법이 없었다.
    //
    // ⚠️ **그림을 안 담는 필터에서는 그대로 둔다**(사용자 지적). 「읽기」·「명령」의 `hits` 에는
    // 그림이 없으므로 `remapTiles` 를 부르면 **전부 버려진다** — 잠깐 들렀다 돌아오는 것만으로
    // 화면이 깜빡인다. 그 화면에서는 애초에 안 그리므로(`wants_thumbs`) 타일의 자리(`hit_index`)가
    // 낡아도 무해하고, 돌아올 때 `remapTiles` 가 다시 잇는다.
    //
    // 들고 있는 값은 최대 `max_tiles`(256 장 · 15 MB)로 이미 유계다.
    if (self.agent_activity.filter.holdsImages()) remapTiles(self);
    self.agent_activity.dropOpen(self.allocator);
    self.agent_activity.hovered = null;
    self.agent_activity.scroll = .{};
    self.metal_dirty = true;
}

/// 검색창을 연다(⌘F). 갤러리를 보고 있을 때만 뜻이 있다.
pub fn focusSearch(self: *AppSession) bool {
    // **갤러리가 키를 쥐고 있을 때만**이다. 도크가 보인다는 것만으로 열면, 터미널에 타이핑하던 사용자의
    // ⌘F 가 터미널 찾기 대신 갤러리 검색을 연다.
    if (!ownsKeys(self)) return false;
    self.agent_activity.search_active = true;
    self.metal_dirty = true;
    return true;
}

/// 검색창이 키·IME 를 쥐고 있나. `AppSession.inputFocus` 의 유일한 근거다 — 조합 글자가 뒤 터미널로
/// 새지 않으려면 이 판정이 focus 표에 올라 있어야 한다(설정 검색이 한때 빠져 있어 새던 그 자리다).
pub fn searchOwnsInput(self: *const AppSession) bool {
    return self.agent_activity.search_active and ownsKeys(self);
}

/// 검색창이 키를 받는다. 소비했으면 `true`.
///
/// **검색 중에는 Esc 도 화살표도 검색창 것이다** — 타이핑하다 Esc 로 검색을 접는 것이 자연스럽고,
/// 그 사이 크게 보기 넘기기가 끼어들면 놀랍다. 여기 오는 `.char` 는 ASCII 직접 입력뿐이고, 한글을
/// 비롯한 조합 입력은 `imeSetPreedit`/`commitPreedit` 로 들어온다.
pub fn handleSearchKey(self: *AppSession, event: maru.terminal.KeyEvent) bool {
    if (!searchOwnsInput(self)) {
        self.agent_activity.search_active = false; // 뷰가 바뀌었다 — 창은 닫고 키는 넘긴다
        return false;
    }
    switch (event.key) {
        .escape => {
            // 첫 Esc 는 **검색어만** 지운다(창은 열어 둔다). 다 지운 뒤 Esc 면 창을 닫는다 —
            // 한 번에 닫으면 오타 하나 물리려다 검색을 통째로 잃는다.
            if (self.agent_activity.search.query.items.len > 0 or
                self.agent_activity.search.preedit.items.len > 0)
            {
                self.agent_activity.search.clear();
                cancelBodySearch(self);
                rebuildFilter(self);
            } else {
                self.agent_activity.search_active = false;
                self.metal_dirty = true;
            }
        },
        .enter => {
            // 확정 = 창을 닫고 **검색어는 유지**한다. 걸러진 목록에서 그대로 고르게 된다.
            //
            // **그리고 본문까지 넓힌다**(계약 §2.1.1). 라벨만 보는 검색은 세션의 2.9% 라, 「어떤
            // grep 으로 뭐가 나왔나」를 이 뷰가 답하려면 여기서 한 번 더 가야 한다. 글자마다 하지
            // 않는 이유는 대가다 — 조각을 읽어 푸는 일이라 수백 ms 다.
            self.agent_activity.search_active = false;
            submitBodySearch(self);
            self.metal_dirty = true;
        },
        .backspace => {
            if (self.agent_activity.search.query.items.len == 0) return true;
            self.agent_activity.search.backspace(); // codepoint 단위 — 바이트로 지우면 한글이 깨진다
            // **검색어가 바뀌면 본문 답은 남의 답이다.** `appliesTo` 가 그것을 이미 막지만, 놓지
            // 않으면 워커가 아무도 안 볼 것을 위해 계속 돈다.
            cancelBodySearch(self);
            rebuildFilter(self);
        },
        .char => |codepoint| {
            if (event.modifiers.command or event.modifiers.control or event.modifiers.option) return false;
            if (self.agent_activity.search.query.items.len + 4 > max_query_bytes) return true;
            self.agent_activity.search.appendChar(self.allocator, codepoint) catch return true;
            cancelBodySearch(self);
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
    // **그린 줄에서 곧장 받는다.** 예전에는 같은 공식을 여기 한 번 더 썼는데, 한쪽만 고치면 후보창이
    // 글자와 어긋난 자리에 뜬다 — 화면을 봐야만 보이는 어긋남이라 test 로 잡기도 어렵다.
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = searchLine(self, &buf);
    // 줄 끝을 넘지 않게 — 넘으면 후보창이 도크 밖에 뜬다.
    const max_x = content.x +| content.w -| cw;
    return .{
        .x = @intCast(@min(content.x +| line.caret_cols *| cw, max_x)),
        .y = @intCast(content.y),
        .w = cw,
        .h = ch,
    };
}

/// 검색줄을 **한 번만** 만든다 — 그린 글자와 caret 자리가 같은 계산에서 나온다.
///
/// 도크는 좁다. 길어지면 **뒤쪽**을 보인다(`tailWindow`) — 앞을 보이면 방금 친 글자가 화면 밖이라
/// 자기가 무엇을 치고 있는지 알 수 없다.
pub const SearchLine = struct { text: []const u8, caret_cols: u32 };
fn searchLine(self: *const AppSession, buf: []u8) SearchLine {
    const prompt = maru.i18n.t(.agent_activity_search_prompt);
    const pre = self.agent_activity.search.preedit.items;
    const prompt_cols = chrome.components.overlay_input.displayCols(prompt);
    const pre_cols = chrome.components.overlay_input.displayCols(pre);
    const text_cols = searchLineCols(self) -| prompt_cols;
    const q_tail = chrome.components.overlay_input.tailWindow(
        self.agent_activity.search.query.items,
        text_cols -| pre_cols,
    );

    // **자르되 비우지 않는다.** 예전에는 `bufPrint` 한 방이라, 조합 글자가 길어 자리가 모자라면
    // 빈 문자열이 되어 **검색줄이 통째로 사라졌다** — 한글을 치는 도중에 그러면 무엇을 치는지 못 본다.
    var len: usize = 0;
    var cols: u32 = 0;
    for ([_][]const u8{ prompt, q_tail.text, pre }, [_]u32{ prompt_cols, chrome.components.overlay_input.displayCols(q_tail.text), pre_cols }) |part, part_cols| {
        if (len + part.len > buf.len) break;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
        cols +|= part_cols;
    }
    // **caret 은 여기서 굳는다.** 아래 곁말은 사용자가 친 글자가 아니므로 그것까지 세면 후보창이
    // 글자에서 떨어져 뜬다.
    const caret_cols = cols;

    // **「⏎ 본문」을 자리가 남을 때만 붙인다**(계약 §2.1.1). 이것이 없으면 아래층 검색이 있다는
    // 것을 알 길이 없다 — 라벨은 세션의 2.9% 이므로, 사용자는 「없다」와 「라벨에 없다」를
    // 구분하지 못한 채 검색을 포기한다.
    //
    // **이미 그 답을 받아 뒀으면 안 붙인다.** 누를 이유가 없어진 안내는 잡음이다.
    if (!self.agent_activity.body.appliesTo(self.agent_activity.search.query.items)) {
        const hint = maru.i18n.t(.agent_activity_body_hint);
        const hint_cols = chrome.components.overlay_input.displayCols(hint);
        if (len + hint.len <= buf.len and cols +| hint_cols <= searchLineCols(self)) {
            @memcpy(buf[len..][0..hint.len], hint);
            len += hint.len;
        }
    }
    return .{ .text = buf[0..len], .caret_cols = caret_cols };
}

/// 알림 줄 버퍼 크기. 검색어 상한 + 앞머리 + 조합 글자가 들어갈 만큼이다.
pub const notice_buf_bytes: usize = max_query_bytes + 128;

/// 갤러리가 키보드를 쥐고 있나. 에이전트 도크와 같은 게이트다 — 이것이 없으면 터미널로 돌아간 뒤의
/// Esc 가 셸이 아니라 크게 보기를 닫는다.
pub fn ownsKeys(self: *const AppSession) bool {
    return dock_ops.dockVisible(self) and self.dock.view == .agent_activity and self.agent_activity.key_focus;
}

/// 터미널을 눌렀다 = 키보드를 놓는다. **크게 보기는 그대로 둔다** — 보던 것을 클릭 한 번에 잃지 않는다.
pub fn releaseKeyFocus(self: *AppSession) void {
    if (!self.agent_activity.key_focus) return;
    self.agent_activity.key_focus = false;
    self.metal_dirty = true;
}

/// Esc. 크게 보기를 닫는다. 소비했으면 `true`.
pub fn handleEscape(self: *AppSession) bool {
    if (!ownsKeys(self)) return false;
    if (self.agent_activity.open == null) return false;
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
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return clearHover(self);
    if (self.agent_activity.open != null) return clearHover(self);
    // 줄 목록에는 「얹힌 칸」이 없다 — 격자 좌표로 판정하면 남의 자리를 밝힌다(클릭과 같은 이유).
    if (!self.agent_activity.filter.isGrid()) return clearHover(self);

    const area = gridArea(self);
    if (x_px < @as(f64, @floatFromInt(area.x)) or y_px < @as(f64, @floatFromInt(area.y))) return clearHover(self);
    if (x_px >= @as(f64, @floatFromInt(area.x +| area.w)) or y_px >= @as(f64, @floatFromInt(area.y +| area.h))) {
        return clearHover(self);
    }

    const px: u32 = @intFromFloat(@max(0, x_px));
    const py: u32 = @intFromFloat(@max(0, y_px));
    const hit = image_grid.hitTest(area, gridMetrics(self), gridLayout(self), px, py);
    if (hit != self.agent_activity.hovered) {
        self.agent_activity.hovered = hit;
        self.metal_dirty = true;
    }
    return hit != null;
}

/// 지금 열린 것이 **펼침**(활동)인가 — 그림이 아니라 글이다(AV3). 클릭·렌더가 같은 판정을 쓴다.
pub fn isDetailOpen(self: *const AppSession) bool {
    const op = if (self.agent_activity.open) |o| o else return false;
    if (op.hit_index >= self.agent_activity.hits.items.len) return false;
    return !self.agent_activity.hits.items[op.hit_index].kind.isImage();
}

/// 호버를 놓는다. 얹힌 칸이 없다는 뜻이므로 `false`.
pub fn clearHover(self: *AppSession) bool {
    if (self.agent_activity.hovered != null) {
        self.agent_activity.hovered = null;
        self.metal_dirty = true;
    }
    return false;
}

/// 도크 본문 primary down. 소비했으면 `true`.
///
/// 두 모드가 다르다 — 격자에서는 **칸을 눌러 연다**, 크게 보기에서는 **이미지 밖을 눌러 닫는다**.
/// 이미지 위는 아직 아무 일도 하지 않는다(팬은 IG4-c).
pub fn handleDown(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return false;
    // **칩이 먼저다.** 칩 줄은 격자 영역(`gridArea`) 밖이지만, 순서를 뒤에 두면 나중에 자리가
    // 겹치도록 바뀌었을 때 조용히 격자가 이긴다.
    if (handleChipDown(self, x_px, y_px)) return true;
    const gx = gridArea(self);
    if (x_px < @as(f64, @floatFromInt(gx.x)) or y_px < @as(f64, @floatFromInt(gx.y))) return false;
    if (x_px >= @as(f64, @floatFromInt(gx.x +| gx.w)) or y_px >= @as(f64, @floatFromInt(gx.y +| gx.h))) return false;
    self.agent_activity.key_focus = true;

    if (self.agent_activity.open) |*op| {
        // **펼침에는 그림이 없다**(AV3). 「이미지 밖을 눌러 닫는다」의 «밖» 이 화면 전체이므로 어디를
        // 눌러도 닫는다 — 안 그러면 아래 `pixels.len == 0` 이 클릭을 삼켜 **닫을 길이 없어진다**.
        if (isDetailOpen(self)) {
            closeOpen(self);
            return true;
        }
        if (op.pixels.len == 0) return true; // 아직 못 풀었다 — 격자가 보이지만 클릭은 삼킨다
        const vp = viewportRect(self);
        const r = image_view.destRect(op.view, vp, op.width, op.height);
        const fx: f32 = @floatCast(x_px);
        const fy: f32 = @floatCast(y_px);
        const inside = fx >= r.x and fy >= r.y and fx < r.x + r.w and fy < r.y + r.h;
        // 이미지 위 = 잡고 밀기, 밖 = 닫기. **밖을 닫기로 둔 이유**는 크게 보기가 도크를 통째로
        // 덮어 「어디를 눌러야 돌아가지」의 답이 하나뿐이기 때문이다(Esc 와 짝).
        if (inside) {
            self.beginPointerGesture(.{ .agent_activity_pan = .{ .x = x_px, .y = y_px } });
        } else closeOpen(self);
        return true;
    }

    // **줄 목록에서는 격자 히트테스트를 돌리지 않는다** — 좌표계가 다르다. 대신 줄 높이로 나눠
    // **그 줄을 펼친다**(AV3). 창(`listWindow`)은 그리기와 같은 자리에서 오므로 눌린 줄과 그려진
    // 줄이 갈리지 않는다.
    if (!self.agent_activity.filter.isGrid()) {
        const w = listWindow(self);
        if (w.row_h == 0) return true;
        const py: u32 = @intFromFloat(@max(0, y_px));
        if (py < gx.y) return true;
        const row: usize = @intCast((py - gx.y) / w.row_h);
        const n = w.first +| row;
        // 목록 끝 **아래의 빈 자리**를 누르면 아무 일도 없다 — 없는 항목을 열지 않는다.
        if (n < w.last) openAt(self, n);
        return true;
    }

    const m = gridMetrics(self);
    const l = gridLayout(self);
    const px: u32 = @intFromFloat(@max(0, x_px));
    const py: u32 = @intFromFloat(@max(0, y_px));
    if (image_grid.hitTest(gx, m, l, px, py)) |n| openAt(self, n);
    return true;
}

/// 그 hit 의 오프셋이 가리키는 **로컬 파일**. 체인이 여럿이면 `file_index` 가 유일한 답이다 —
/// 첫 파일로 고정하면 부모 이미지를 현재 파일에서 읽어 엉뚱한 바이트를 디코드한다.
///
/// 🔥 **원격 소스면 null 이다**(계약 §2.1 · 적대적 N1). 이 함수가 주는 경로는 곧바로
/// `Dir.cwd().openFile` 로 간다(디코드 워커 · 본문 검색 워커 · 펼침 · 썸네일 — 계획 §6.3 이 말한
/// 「네 소비자」가 그것이다). 원격 오프셋을 그 자리에 대면 **같은 모양의 이쪽 파일이 실제로 열려**
/// 남의 대화 바이트를 디코드한다 — 갤러리 §4.1.2 가 막으려던 바로 그 사고다.
///
/// **판정을 여기 한 곳에 둔다.** 소비자마다 가드를 두면 넷 중 하나를 잊고, 그 하나가 조용히 남의
/// 파일을 연다(이 저장소가 「여섯 곳이 옛 축에 남아 있었다」로 이미 겪은 모양).
///
/// 저쪽 바이트를 **요청형으로 당겨오는 것**은 RAV5·RAV6 이다. 그때까지 원격 pane 은 목록과 라벨만
/// 보이고 펼침·썸네일은 비어 있다 — 그 사실은 §13.5 가 한계로 적어 둔다.
fn pathFor(self: *const AppSession, hit: index.Hit) ?[]const u8 {
    return pathForIndex(self, hit.file_index);
}

/// `pathFor` 의 알맹이 — 체인 자리 번호로 직접 묻는다(썸네일은 `ResultSummary.image_file` 을 쓴다).
fn pathForIndex(self: *const AppSession, file_index: u8) ?[]const u8 {
    if (self.agent_activity.source_remote) return null;
    return self.agent_activity.chain.get(file_index);
}

/// **저쪽** 경로 — 원격 왕복에 실어 보낼 값이다(RAV5b). 로컬이면 null.
///
/// 🔥 **`pathForIndex` 와 뚜렷이 가른다.** 둘은 같은 문자열을 주지만 **가는 곳이 반대**다: 저쪽 것은
/// ssh argv 로 가고 이쪽 것은 `Dir.cwd().openFile` 로 간다. 한 함수로 합치면 「어디로 가는 값인가」를
/// 호출자가 판단하게 되고, 그 판단이 한 번만 틀려도 **남의 파일이 열린다**(§13.6 N1 이 잡은 그 사고).
///
/// §6.3 게이트가 `chain.get` 호출을 **이 둘로만** 못 박는다 — 실제로 이 함수가 없던 동안 그 게이트가
/// 빨개져서 이 갈림을 만들게 했다.
fn remotePathForIndex(self: *const AppSession, file_index: u8) ?[]const u8 {
    if (!self.agent_activity.source_remote) return null;
    return self.agent_activity.chain.get(file_index);
}

/// 그 칸의 라벨. **스캔 워커가 이미 만들어 뒀다** — 예전에는 타일이 생길 때 파일을 열어 읽었는데,
/// 그러면 보이는 칸만 라벨이 있어 필터가 성립하지 않는다(§2.2).
fn labelFor(self: *const AppSession, hit_index: usize) context.Label {
    const labels = self.agent_activity.labels.items;
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
/// 칩 줄의 높이(px). 글자 한 줄에 위아래 여백을 둔다 — 눌러야 하는 것이라 글자에 딱 붙이면
/// 손가락이 자주 빗나간다.
pub fn chipRowHeightPx(self: *const AppSession) u32 {
    const cell: u32 = if (self.cell_height_px > 0) self.cell_height_px else app_session_mod.placeholder_cell_height_px;
    return cell +| chip_row_padding_px;
}

const chip_row_padding_px: u32 = 6;
/// 칩 사이 간격(칸). 붙여 두면 어디까지가 한 칩인지 안 보인다.
const chip_gap_cols: u16 = 2;

/// 종류 필터 칩이 놓이는 줄 — 안내 줄 **아래**, 목록/격자 **위**다.
///
/// **왜 전용 줄인가.** 안내 줄은 검색 중에는 검색창이 되고(`searchOwnsInput`) 그때 글자가 줄
/// 전체를 쓴다. 같은 줄에 칩을 얹으면 검색을 켜는 순간 필터가 사라지거나 글자를 밀어낸다 —
/// 「지금 무엇을 보고 있나」는 검색 중에도 보여야 하는 정보다(계약 §2.1).
pub fn chipRowRect(self: *const AppSession) image_grid.Rect {
    const g = dock_ops.dockGeometry(self);
    const notice_h: u32 = if (self.cell_height_px > 0) self.cell_height_px else app_session_mod.placeholder_cell_height_px;
    return .{
        .x = g.tree_content.x,
        .y = g.tree_content.y +| notice_h,
        .w = g.tree_content.w,
        .h = @min(chipRowTakenPx(self), g.tree_content.h -| notice_h),
    };
}

/// 칩 줄이 **실제로 먹는** 높이. 크게 보기·펼침이 열려 있으면 0 이다 — 그때는 칩을 그리지 않기
/// 때문이다(`collectFilterChips`).
///
/// **자리와 그리기가 갈리면 두 가지가 한꺼번에 깨진다.** 안 그리는데 자리만 빼면 ① 펼침이 한 줄을
/// 빈 채로 잃어 「이하 생략」이 한 줄 일찍 오고, ② 그 한 줄이 펼침 영역(`gridArea`) **밖**이라
/// 눌러도 안 닫히고 클릭이 뒤 터미널로 샌다 — 계약이 「펼침은 어디를 눌러도 닫는다」라고 못박은
/// 것을 칩 줄만 예외로 만든다. AV3(펼침)와 AV4(칩)를 합치고 나서야 생긴 형태다.
pub fn chipRowTakenPx(self: *const AppSession) u32 {
    if (self.agent_activity.open != null) return 0;
    return chipRowHeightPx(self);
}

pub fn gridArea(self: *const AppSession) image_grid.Rect {
    const g = dock_ops.dockGeometry(self);
    const notice_h: u32 = if (self.cell_height_px > 0) self.cell_height_px else app_session_mod.placeholder_cell_height_px;
    // **칩 줄도 자리를 받는다.** 안 빼면 첫 항목이 칩 위에 겹쳐 그려진다. 반대로 칩을 안 그리는
    // 동안(크게 보기·펼침)에는 빼지 않는다 — `chipRowTakenPx` 가 그 하나를 정한다.
    const taken = notice_h +| chipRowTakenPx(self);
    return .{
        .x = g.tree_content.x,
        .y = g.tree_content.y +| taken,
        .w = g.tree_content.w,
        .h = g.tree_content.h -| taken,
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
    // **안 그리고 나가는 길은 예외 없이 표시한다** — 이 프레임에 id 가 안 실리면 텍스처가 거둬지는데
    // `uploaded` 가 참으로 남으면 다음에 그릴 때 빈 자리가 된다(격자 타일과 같은 규율).
    if (r.w <= 0 or r.h <= 0) {
        op.uploaded = false;
        return;
    }

    // 보이는 부분만 남긴다.
    const x0 = @max(r.x, vp.x);
    const y0 = @max(r.y, vp.y);
    const x1 = @min(r.x + r.w, vp.x + vp.w);
    const y1 = @min(r.y + r.h, vp.y + vp.h);
    if (x1 <= x0 or y1 <= y0) { // 통째로 밖이다 — clamp 가 막지만 한 겹 더 둔다
        op.uploaded = false;
        return;
    }

    const id = activity_open_image_id;
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

    const merged_images = self.allocator.alloc(metal_frame.GpuImage, images.len + 1) catch {
        op.uploaded = false;
        return;
    };
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
/// 크게 보기 아래에 「그때 무슨 얘기였나」를 띄운다. 격자 라벨과 **같은 그리기 경로**다.
///
/// 줄바꿈은 **칸 수로만** 자른다 — 낱말 경계를 찾으려면 폭을 알아야 하는데, 그 폭은 CoreText 가
/// shaping 한 뒤에야 정해진다(비례 폰트·한글 2 칸). 여기서 흉내 내면 그린 자리와 어긋난다.
pub fn collectOpenContext(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    const op = if (self.agent_activity.open) |*o| o else return;
    const text = op.contextText();
    var prefix_buf: [context_mod.max_label_bytes]u8 = undefined;
    const prefix = openPrefix(self, &prefix_buf);
    if (text.len == 0 and prefix.len == 0) return;

    const area = gridArea(self);
    const pad = gridMetrics(self).pad;
    const row_h = labelHeightPx(self);
    const cols: u16 = @intCast(@min(
        @as(u32, std.math.maxInt(u16)),
        (area.w -| (pad *| 2)) / self.cell_width_px,
    ));
    if (cols == 0) return;

    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    // 문맥은 라벨보다 **흐리게**. 그림이 주인공이고 이것은 곁말이다.
    const dim: maru.terminal.Color = .{ .rgb = towardBg(
        self.appearance.theme.sidebar_foreground,
        self.appearance.theme.sidebar_background,
        context_dim_percent,
    ) };

    // 뷰포트가 비워 둔 아래쪽 띠에 그린다 — `viewportRect` 와 **같은 값**(`contextRows`)을 쓴다.
    const rows = contextRows(self);
    var y = area.y +| area.h -| pad -| (rows *| row_h);

    // **출처는 문맥보다 또렷하게, 그리고 위에.** 문맥은 「그때 무슨 얘기였나」라는 곁말이지만 출처는
    // 사용자가 이 화면에 대고 묻는 물음의 답이다. 흐리게 두면 곁말에 묻힌다.
    var context_rows = rows;
    if (prefix.len > 0) {
        const pdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, cols, prefix, fg) catch return;
        self.collectShaped(collected, pdl, builder, .{ .pane = .{
            .origin_x = area.x +| pad,
            .origin_y = y,
            .colors = colors,
        } });
        y +|= row_h;
        context_rows -|= 1;
    }
    if (text.len == 0) return;
    // **결정은 순수 함수가 한다.** 「어느 글자를 어느 줄에」와 「그것을 어떻게 그릴까」를 한 함수에
    // 두었더니, 결정 쪽 결함(줄바꿈에 글자가 사라짐 · 남의 메모리 해제)을 **어떤 test 도 못 봤다** —
    // `collectShaped` 가 CoreText 함수 포인터를 요구해 이 함수를 단위 test 로 부를 수 없기 때문이다.
    const plan = layoutContext(text, cols, context_rows);
    for (plan.lines[0..plan.count], 0..) |span, i| {
        const raw = text[span.start..][0..span.len];
        // «…» 는 **마지막 줄에 남는 것이 있을 때만**이다 — 줄바꿈은 자르기가 아니다.
        const need_ellipsis = plan.ellipsis and i + 1 == plan.count;
        const line = if (need_ellipsis)
            std.fmt.allocPrint(self.allocator, "{s}…", .{raw[0..raw.len -| lastCharBytes(raw)]}) catch break
        else
            raw;
        // **빌린 것을 풀지 않는다.** 예전에는 `truncateToCols` 가 안 넘칠 때 원본 슬라이스를 그대로
        // 돌려주는데도 무조건 `free` 했다 — `op.context` 안을 할당자에 넘긴 것이다.
        defer if (need_ellipsis) self.allocator.free(line);

        const dl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, cols, line, dim) catch break;
        self.collectShaped(collected, dl, builder, .{ .pane = .{
            .origin_x = area.x +| pad,
            .origin_y = y,
            .colors = colors,
        } });
        y +|= row_h;
    }
}

/// 문맥을 몇 줄에 어떻게 나눌까 — **순수 결정**. 화면 없이 시험할 수 있다.
pub const ContextLayout = struct {
    pub const Span = struct { start: usize, len: usize };
    lines: [max_context_rows]Span = [_]Span{.{ .start = 0, .len = 0 }} ** max_context_rows,
    count: u32 = 0,
    /// 자리가 모자라 남는 글자가 있다 — 마지막 줄 끝에 «…» 를 붙일 근거다.
    ellipsis: bool = false,
};

/// 텍스트를 `cols` 칸 · 최대 `rows` 줄로 나눈다.
///
/// **줄을 이어 붙이면 원문의 앞부분이 그대로 나온다** — 한 글자도 빠지거나 겹치지 않는다.
/// 그 불변식이 이 함수의 계약이고, 어긴 것이 방금 고친 결함이었다.
pub fn layoutContext(text: []const u8, cols: u16, rows: u32) ContextLayout {
    var out: ContextLayout = .{};
    if (cols == 0 or rows == 0 or text.len == 0) return out;
    var at: usize = 0;
    while (out.count < rows and out.count < max_context_rows and at < text.len) {
        const take = wrapNextBytes(text[at..], cols);
        if (take == 0) break;
        out.lines[out.count] = .{ .start = at, .len = take };
        out.count += 1;
        at += take;
    }
    out.ellipsis = at < text.len;
    return out;
}

/// `cols` 칸에 들어가는 **원문 바이트 수**. 그리기와 진행이 **같은 값**을 쓰게 하는 단일 출처다.
///
/// 낱말 경계는 안 찾는다 — 그러려면 shaping 뒤에야 정해지는 폭을 알아야 하고, 여기서 흉내 내면
/// 그린 자리와 어긋난다(격자 라벨이 같은 이유로 칸 수로만 자른다).
pub fn wrapNextBytes(text: []const u8, cols: u16) usize {
    if (cols == 0 or text.len == 0) return 0;
    var used: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(text.len, i + len);
        const w = chrome.components.overlay_input.displayCols(text[i..end]);
        if (used + w > cols) break;
        used += w;
        i = end;
    }
    // 한 글자도 못 넣었으면(칸보다 넓은 글자) 한 글자는 넣는다 — 안 그러면 영영 안 나아간다.
    if (i == 0) {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        return @min(text.len, len);
    }
    return i;
}

/// 그 슬라이스의 **마지막 글자** 바이트 수. «…» 자리를 만들려고 한 글자를 물릴 때 쓴다.
fn lastCharBytes(text: []const u8) usize {
    if (text.len == 0) return 0;
    var i = text.len - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) i -= 1;
    return text.len - i;
}

/// 문맥을 배경 쪽으로 얼마나 죽일지(%). 라벨(45)보다 더 물러난다 — 곁말이다.
const context_dim_percent: u8 = 55;

pub fn collectLabels(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    if (!self.agent_activity.filter.isGrid()) return; // 줄 목록은 자기 라벨을 스스로 그린다
    if (self.agent_activity.open != null) return;
    if (self.agent_activity.tiles.items.len == 0) return;

    const area = gridArea(self);
    const m = gridMetrics(self);
    const l = gridLayout(self);
    if (l.visible == 0) return;
    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };

    // 시각은 라벨보다 **흐리게**. 같은 밝기로 두면 눈이 파일명 대신 숫자를 먼저 읽는다.
    const dim: maru.terminal.Color = .{ .rgb = towardBg(
        self.appearance.theme.sidebar_foreground,
        self.appearance.theme.sidebar_background,
        time_dim_percent,
    ) };
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
    const now_off = utcOffsetAt(now_s);

    for (self.agent_activity.tiles.items) |*tile| {
        const text = tile.label.text();
        // **출처와 순번은 라벨보다 앞서 붙는다**(계약 §2.2) — 이 줄에 사용자가 던지는 첫 물음이
        // 「내가 올린 것인가」이기 때문이다.
        var prefix_buf: [context_mod.max_label_bytes]u8 = undefined;
        const prefix = context_mod.originPrefix(
            &prefix_buf,
            originText(tile.label.source),
            tile.label.seq,
            tile.label.seq_total,
        );
        if (text.len == 0 and prefix.len == 0) continue; // 없는 설명을 지어내지 않는다 — 빈 칸이 낫다
        const rect = image_grid.labelRectAt(area, m, l, tile.hit_index) orelse continue;
        const all_cols: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), rect.w / self.cell_width_px));
        if (all_cols == 0) continue;

        var time_buf: [16]u8 = undefined;
        var time_text: []const u8 = &.{};
        if (tile.label.time_s != 0) {
            const off = utcOffsetAt(tile.label.time_s);
            time_text = formatImageTime(&time_buf, tile.label.time_s, off, now_s, now_off);
        }

        // **자리 나누기는 순수 모듈이 정한다** — 좁아지면 시각부터, 그래도 모자라면 접두까지 버린다.
        // 설명이 없는 줄에서는 최소 폭을 요구하지 않는다(지킬 라벨이 애초에 없다).
        const split = context_mod.splitLabelRow(
            all_cols,
            displayColsOf(prefix),
            displayColsOf(time_text),
            time_gap_cols,
            if (text.len == 0) 0 else min_label_cols,
        );

        var at_col: u32 = 0;
        if (split.prefix_cols > 0) {
            // 접두는 라벨보다 **흐리게**. 곁말이 파일명보다 먼저 읽히면 안 된다(시각과 같은 규율).
            const pdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.prefix_cols, prefix, dim) catch continue;
            self.collectShaped(collected, pdl, builder, .{ .pane = .{
                .origin_x = rect.x,
                .origin_y = rect.y,
                .colors = colors,
            } });
            at_col = @as(u32, split.prefix_cols) +| time_gap_cols;
        }

        if (text.len > 0 and split.label_cols > 0) {
            const dl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.label_cols, text, fg) catch continue;
            self.collectShaped(collected, dl, builder, .{ .pane = .{
                .origin_x = rect.x +| at_col *| self.cell_width_px,
                .origin_y = rect.y,
                .colors = colors,
            } });
        }
        if (split.time_cols == 0) continue;
        const time_col = at_col +| @as(u32, split.label_cols) +| time_gap_cols;
        const tdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.time_cols, time_text, dim) catch continue;
        self.collectShaped(collected, tdl, builder, .{ .pane = .{
            .origin_x = rect.x +| time_col *| self.cell_width_px,
            .origin_y = rect.y,
            .colors = colors,
        } });
    }
}

/// 시각과 라벨 사이 최소 간격, 그리고 시각을 넣기 위해 남겨야 할 라벨 최소 폭(칸).
const time_gap_cols: u16 = 1;
/// 대상(이름)에 **반드시 남겨야 할** 최소 폭(칸). 좁아지면 시각·요약을 먼저 버리고 이것을
/// 마지막까지 지킨다(계약 §2.2.3) — 썸네일(AV5)도 이 선 아래로는 자리를 못 가져간다.
pub const min_label_cols: u16 = 6;

/// 이 라벨이 **어떻게 대화에 들어왔는가**를 한 낱말로. 모르면 빈 값이다 — 지어내지 않는다.
///
/// `Source` 는 그동안 진단·테스트 전용이었다. 그래서 사용자는 「내가 올린 것인지 에이전트가 읽은
/// 것인지」를 라벨 **모양**(파일명이냐 문장이냐)으로 짐작해야 했는데, 그것은 규약이 아니라 우연한
/// 상관이라 사용자가 경로를 적어 보낸 순간 틀린다.
fn originText(source: context_mod.Source) []const u8 {
    return switch (source) {
        // codex 래퍼의 경로도 **사용자가 보낸 것**이다 — 래퍼는 provider 가 붙인 껍데기일 뿐이다.
        .message_text, .codex_wrapper_path => maru.i18n.t(.agent_activity_origin_sent),
        .tool_file_path => maru.i18n.t(.agent_activity_origin_read),
        .none => "",
    };
}

/// 이 글자가 차지할 칸 수(u16 로 포화). 폭 계산의 단일 출처는 `displayCols` 다 — 바이트 길이로 세면
/// 한글이 두 칸인 것을 놓쳐 라벨이 밀린다.
fn displayColsOf(text: []const u8) u16 {
    if (text.len == 0) return 0;
    return @intCast(@min(
        @as(usize, std.math.maxInt(u16)),
        chrome.components.overlay_input.displayCols(text),
    ));
}
/// 전경색을 배경 쪽으로 `percent` 만큼 당긴다. 어두운 테마·밝은 테마 어느 쪽에서도 «흐리게» 가 된다 —
/// 고정 회색을 쓰면 한쪽 테마에서 배경과 붙거나 오히려 더 튄다.
fn towardBg(fg: maru.color.Rgb, bg: maru.color.Rgb, percent: u8) maru.color.Rgb {
    const a: u16 = percent;
    const inv: u16 = 100 - a;
    return .{
        .r = @intCast((@as(u16, fg.r) * inv + @as(u16, bg.r) * a) / 100),
        .g = @intCast((@as(u16, fg.g) * inv + @as(u16, bg.g) * a) / 100),
        .b = @intCast((@as(u16, fg.b) * inv + @as(u16, bg.b) * a) / 100),
    };
}

/// 시각을 배경 쪽으로 얼마나 죽일지(%). 라벨보다 뒤로 물러나되 읽히는 선이다.
const time_dim_percent: u8 = 45;

/// 이 이미지가 적힌 **시각**. 오늘이면 `14:32`, 아니면 `08-22 14:32`.
///
/// SCM 도크의 턴 줄과 **같은 표기**다(2026-08-23 사용자 결정: 목록에서 알고 싶은 것은 «얼마나
/// 지났나» 가 아니라 «언제 것인가» 다). 갤러리도 같은 물음이라 같은 답을 쓴다.
///
/// **순수 함수다** — 오프셋은 호출자가 넘긴다. 두 시점의 오프셋을 따로 받는 이유는 서머타임이다:
/// 하나로 합치면 경계를 넘은 이미지에서 「오늘」 판정이 틀린다.
fn formatImageTime(buf: []u8, at_s: i64, at_off: i64, now_s: i64, now_off: i64) []const u8 {
    const local = at_s + at_off;
    if (local < 0) return "";
    const day: i64 = @divFloor(local, std.time.s_per_day);
    const secs_in_day: u17 = @intCast(local - day * std.time.s_per_day);
    const hour = secs_in_day / 3600;
    const minute = (secs_in_day % 3600) / 60;
    const now_day: i64 = @divFloor(now_s + now_off, std.time.s_per_day);
    if (day == now_day) return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    const year_day = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1, // `day_index` 는 0-based 다
        hour,
        minute,
    }) catch "";
}

const CTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timep: *const i64, result: *CTm) ?*CTm;

/// 그 시점의 UTC 오프셋(초). OS 가 서머타임까지 안다 — 우리가 규칙을 흉내 내지 않는다.
fn utcOffsetAt(unix_s: i64) i64 {
    var tm: CTm = undefined;
    if (localtime_r(&unix_s, &tm) == null) return 0;
    return @intCast(tm.gmtoff);
}

/// 스크롤 위치를 지금 목록의 상한 안으로 끌어내린다. 목록이 **줄어든** 뒤에 부른다.
fn clampScroll(self: *AppSession) void {
    const max = gridLayout(self).max_scroll;
    if (self.agent_activity.scroll.offset_y_px > max) {
        self.agent_activity.scroll.offset_y_px = max;
        self.agent_activity.scroll.dropWheelResidue(); // 가는 도중의 잔여는 위치가 확정되면 뜻이 없다
    }
}

/// 지금 프레임의 격자 배치. **그리기·hit-test·스크롤 상한이 모두 이 하나를 쓴다** — 각자 계산하면
/// 스크롤한 뒤 누른 자리와 열리는 것이 어긋난다.
pub fn gridLayout(self: *const AppSession) image_grid.Layout {
    return image_grid.layout(
        gridArea(self),
        gridMetrics(self),
        self.agent_activity.count(),
        self.agent_activity.scroll.offset_y_px,
    );
}

/// 휠로 격자를 굴린다. 크게 보기 중에는 `wheelZoom` 이 가져가므로 여기 오지 않는다.
pub fn wheelScroll(self: *AppSession, delta_y: f64, precise: bool, x_px: f64, y_px: f64) bool {
    // **줄 목록은 자기 자를 쓴다.** 격자의 `max_scroll` 은 타일 크기와 열 수에서 나오므로 줄 목록의
    // 실제 높이(항목 수 × 줄 높이)와 다르다. 그대로 쓰면 **끝까지 내려가지 않는다** — 4,084개짜리
    // 세션에서 앞부분만 닿는다. 눈금도 한 줄이어야 「한 칸씩」이 뜻을 갖는다.
    if (!self.agent_activity.filter.isGrid()) {
        const area = gridArea(self);
        const row_h = listRowHeightPx(self);
        if (row_h == 0) return false;
        const content_h: u32 = @intCast(@min(
            @as(u64, self.agent_activity.count()) * @as(u64, row_h),
            @as(u64, std.math.maxInt(u32)),
        ));
        const max_scroll = content_h -| area.h;
        if (max_scroll == 0) return false; // 다 보인다 — 이벤트를 삼키지 않는다
        const unit: f64 = if (precise)
            @as(f64, @floatFromInt(if (self.scale_milli > 0) self.scale_milli else 1000)) / 1000.0
        else
            @floatFromInt(row_h);
        if (self.agent_activity.scroll.scrollByWheel(delta_y, unit, max_scroll)) {
            self.metal_dirty = true;
        }
        return true; // 경계에서도 소비한다 — 안 그러면 제스처가 뒤 터미널로 샌다
    }

    const l = gridLayout(self);
    if (l.max_scroll == 0) return false; // 굴릴 것이 없다 — 이벤트를 삼키지 않는다
    // 트랙패드(precise)는 논리 픽셀, 눈금은 한 번에 한 행. 도크 목록과 같은 규약이다.
    const unit: f64 = if (precise)
        @as(f64, @floatFromInt(if (self.scale_milli > 0) self.scale_milli else 1000)) / 1000.0
    else
        // **행 높이는 배치가 안다.** 예전엔 `Metrics.tile`(칸 **가로**의 최소치)을 세로로 썼는데,
        // 비율이 2:1 이라 두 배였고 늘리기 뒤에는 더 어긋난다. 눈금은 한 곳에서만 나와야 한다.
        @floatFromInt(l.tile_h +| gridMetrics(self).label +| gridMetrics(self).gap);
    // **부호를 여기서 뒤집지 않는다.** `scrollByWheel` 이 이미 `scrollByPx(-whole)` 로 뒤집으므로
    // 한 번 더 뒤집으면 위아래가 반대가 된다(에이전트 도크도 `delta_y` 를 그대로 넘긴다).
    if (self.agent_activity.scroll.scrollByWheel(delta_y, unit, l.max_scroll)) {
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
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    if (self.agent_activity.open != null) return;
    // **필터가 바뀌어도 `hovered` 는 남는다.** 격자 좌표로 그리면 목록 화면에 뜬금없는 강조가 뜬다.
    if (!self.agent_activity.filter.isGrid()) return;
    const n = self.agent_activity.hovered orelse return;

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
    // **크게 보기 한 장도 같이 표시한다** — 접었다 펴면 격자가 아니라 그 한 장이 돌아오는데, 표시가
    // 빠지면 정확히 그 화면만 빈다(`markOpenNeedUpload`).
    // 격자가 아닌 필터에서는 그림을 하나도 안 싣는다 — 줄 목록이 그 자리를 쓴다(계약 §2.1).
    // **여기도 「안 그리고 나가는 길」이라 표시를 남긴다**: 필터를 되돌렸을 때 텍스처가 거둬진
    // 채 `uploaded` 만 참으로 남으면 격자가 빈다(도크 접기에서 겪은 것과 같은 결함).
    // **「전체」도 그림을 싣는다**(AV5). 접힌 줄에 작은 썸네일이 붙기 때문이다 — 「읽기」·「명령」은
    // 그림이 없는 종류라 그대로 막는다(없는 것을 위해 창을 훑을 이유가 없다).
    const is_grid = self.agent_activity.filter.isGrid();
    const wants_thumbs = is_grid or self.agent_activity.filter == .all;
    // ⚠️ **펼침이 열리면 목록도 썸네일도 없다.** 목록(`collectActivityList`)은 그 게이트를 이미
    // 갖는데 썸네일이 안 가지면 **글자 없이 그림만** 펼침 본문 위에 남는다. 격자의 크게 보기는
    // 아래에서 `appendOpenImage` 로 갈리지만(그쪽은 그림이 본체다), 펼침은 그림이 없어 그 갈래를
    // 안 타고 그대로 내려온다 — AV3 와 AV5 를 합쳐야 생기는 자리다.
    const detail_open = !is_grid and self.agent_activity.open != null;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity or !wants_thumbs or detail_open) {
        self.agent_activity.markAllNeedUpload();
        self.agent_activity.markOpenNeedUpload();
        return;
    }

    const area = gridArea(self);
    const m = gridMetrics(self);
    const l = gridLayout(self);
    // **자리를 못 얻은 수를 남긴다.** 0 칸이어도(좁은 도크) 남겨야 「없다」로 거짓말하지 않는다.
    //
    // ⚠️ 목록에서는 건드리지 않는다 — 그 값은 `listOverflow` 가 `listWindow` 에서 따로 낸다.
    // 격자의 셈을 목록에 흘리면 안내 줄이 「12개 중 8개」를 엉뚱한 수로 말한다(적대적 I1·J1).
    if (is_grid) self.agent_activity.overflow = l.overflow;

    // **크게 보기는 격자를 대체한다.** 겹쳐 그리면 어느 것을 누르는지 알 수 없다. 다만 아직 못 푼
    // 동안에는 격자를 그대로 둔다 — 클릭 직후 화면이 비면 「눌렀더니 사라졌다」로 보인다.
    if (self.agent_activity.open) |*op| {
        if (op.pixels.len > 0) {
            // 크게 보기가 격자를 **대체**하므로 타일이 하나도 안 실린다 — 닫을 때 다시 올려야 한다.
            self.agent_activity.markAllNeedUpload();
            appendOpenImage(self, op, images, uploads, pixels, live_ids);
            return;
        }
    }

    // **창은 모양이 정한다.** 격자는 칸 배치가, 목록은 줄 높이가 「지금 보이는 것」을 안다.
    const w = listWindow(self);
    const first: usize = if (is_grid) l.first else w.first;
    const visible: usize = if (is_grid) l.visible else w.last -| w.first;
    if (visible == 0) {
        self.agent_activity.markAllNeedUpload();
        return;
    }

    // 보이는 창만큼 채운다(tick 당 상한 `max_inflight` 장). 다 차기 전에도 있는 것부터 그린다.
    ensureTiles(self, first, visible);

    var new_images: std.ArrayList(metal_frame.GpuImage) = .empty;
    defer new_images.deinit(self.allocator);
    var new_uploads: std.ArrayList(metal_frame.GpuImageUpload) = .empty;
    defer new_uploads.deinit(self.allocator);
    var new_pixels: std.ArrayList(u8) = .empty;
    defer new_pixels.deinit(self.allocator);

    for (self.agent_activity.tiles.items, 0..) |*tile, i| {
        const n = tile.hit_index; // **자리는 인덱스가 정한다** — 배열 순서가 아니다
        if (tile.pixels.len == 0) continue; // 못 푼 이미지는 자리만 차지하고 안 그린다
        const cell = if (is_grid) image_grid.rectAt(area, m, l, n) orelse {
            // 창 밖이라 안 그린다 = 이 프레임에 evict 된다. 돌아올 때 다시 올려야 한다.
            tile.uploaded = false;
            continue;
        } else blk: {
            // 목록: 그 줄의 왼쪽. 창 밖이면 격자와 **같은 규율**로 내린다.
            if (n < w.first or n >= w.last or w.row_h == 0) {
                tile.uploaded = false;
                continue;
            }
            const row_y = area.y +| (@as(u32, @intCast(n - w.first)) *| w.row_h);
            break :blk thumbRectAt(self, row_y) orelse {
                tile.uploaded = false;
                continue;
            };
        };
        // **비율을 지켜 가운데**. 늘리면 스크린샷 글자가 찌그러지고 자르면 무엇인지 못 알아본다.
        const r = image_grid.fitInside(cell, tile.width, tile.height);
        // id 는 **인덱스**로 짓는다 — 배열 위치는 퇴출·추가로 바뀐다(위 주석).
        const id: u32 = activity_image_id_base +| @as(u32, @intCast(@min(n, 0xFFFF)));

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
            self.agent_activity.markAllNeedUpload();
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
                self.agent_activity.markAllNeedUpload();
                return;
            };
            new_pixels.appendSlice(self.allocator, tile.pixels) catch {
                self.agent_activity.markAllNeedUpload();
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
        self.agent_activity.markAllNeedUpload();
        return;
    };
    @memcpy(merged_images[0..images.len], images.*);
    @memcpy(merged_images[images.len..], new_images.items);
    self.allocator.free(images.*);
    images.* = merged_images;

    if (new_uploads.items.len > 0) {
        // 이미지는 이미 실렸지만 **업로드가 빠지면** 텍스처 없는 id 가 실려 빈 자리가 된다.
        const merged_uploads = self.allocator.alloc(metal_frame.GpuImageUpload, uploads.len + new_uploads.items.len) catch {
            self.agent_activity.markAllNeedUpload();
            return;
        };
        const merged_pixels = std.mem.concat(self.allocator, u8, &.{ pixels.*, new_pixels.items }) catch {
            self.allocator.free(merged_uploads);
            self.agent_activity.markAllNeedUpload();
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

/// 줄 목록 한 줄의 높이(px). 셀 높이의 배수로 두어 글자가 줄 사이에 끼지 않는다.
pub fn listRowHeightPx(self: *const AppSession) u32 {
    return self.cell_height_px + list_row_padding_px;
}

/// 줄 사이 여백(px). 촘촘하면 훑기 어렵고 넓으면 한 화면에 몇 줄 못 담는다.
const list_row_padding_px: u32 = 4;

/// 줄 목록이 이번 프레임에 **자리를 못 얻는** 수. 하나도 못 그리면 `count()` 와 같다.
///
/// **계산은 `listWindow` 가 소유하고 이 함수는 그것을 읽을 뿐이다.** 예전에는 렌더가 `overflow` 에
/// 남긴 값을 안내가 읽었는데, 그리는 순서가 「안내 → 목록」이라 안내는 **한 프레임 늦은 값**을 봤다
/// (적대적 검증 I1). 그때 이 함수가 계산을 따로 갖는 바람에 **렌더와 두 벌**이 됐고, J1 이 그것을
/// 다시 잡았다 — 지금은 둘 다 `listWindow` 하나를 부른다.
pub fn listOverflow(self: *const AppSession) usize {
    const w = listWindow(self);
    return w.total -| (w.last -| w.first);
}

/// 줄 목록이 이번 프레임에 그릴 **창**. 렌더와 안내가 **이 하나만** 부른다.
///
/// **두 벌이면 갈린다.** 처음에는 `listOverflow` 가 계산을 따로 갖고 렌더가 또 계산했는데, 그것은
/// 이 저장소가 반복해서 당한 형태다(적대적 검증 J1 이 내 I1 수정에서 그것을 찾았다 — 계산을 한
/// 곳으로 모은다면서 **절반만** 옮겼다). `cols == 0` 처럼 한 줄도 못 그리는 경우는 `first == last`
/// 로 답한다 — 그러면 overflow 가 저절로 `total` 이 된다.
pub const ListWindow = struct { total: usize, first: usize, last: usize, rows_fit: usize, cols: u16, row_h: u32 };

pub fn listWindow(self: *const AppSession) ListWindow {
    const total = self.agent_activity.count();
    const empty: ListWindow = .{ .total = total, .first = 0, .last = 0, .rows_fit = 0, .cols = 0, .row_h = 0 };
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return empty;
    const area = gridArea(self);
    const row_h = listRowHeightPx(self);
    if (area.w == 0 or area.h == 0 or row_h == 0) return empty;
    const cols: u16 = @intCast(@min(area.w / self.cell_width_px, @as(u32, std.math.maxInt(u16))));
    if (cols == 0) return empty;

    const rows_fit: usize = @intCast(area.h / row_h);
    // **스크롤을 목록 끝 안으로 잡아 둔다**(H2) — 큰 목록에서 굴린 뒤 짧은 pane 으로 옮기면
    // `first` 가 끝을 넘어 화면이 비고, 안내가 틀린 원인을 말한다.
    const max_first = total -| rows_fit;
    const first: usize = @min(@as(usize, @intCast(self.agent_activity.scroll.offset_y_px / row_h)), max_first);
    return .{
        .total = total,
        .first = first,
        .last = @min(first +| rows_fit, total),
        .rows_fit = rows_fit,
        .cols = cols,
        .row_h = row_h,
    };
}

/// 종류 필터 칩을 그린다(계약 §2.1). **격자든 목록이든 늘 보인다** — 「지금 무엇을 보고 있나」는
/// 모양과 무관한 정보이고, 사라지면 사용자가 필터를 바꿀 길도 함께 사라진다.
///
/// 고른 칩은 **또렷하게**, 나머지는 흐리게 그린다. 배경 사각형을 깔지 않는 이유는 도크가 좁을 때
/// 글자 자리를 그만큼 먹기 때문이고, 밝기 차이만으로도 「지금 이것」이 읽힌다(격자 라벨의 접두·시각이
/// 같은 규율을 쓴다).
pub fn collectFilterChips(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    // **안 그리면 0 이라고 말한다.** `drawn_chips` 는 「필터 UI 가 실제로 나갔나」를 값으로 보는
    // 창인데, 안 그리고 나갈 때 지난 프레임의 수를 남겨 두면 그 창이 거짓말을 한다 — 안내 줄이
    // 잔값을 읽던 결함(§2.2)과 같은 형태다.
    self.agent_activity.drawn_chips = 0;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    // 크게 보기·펼침은 도크를 덮는다 — 그 위에 칩을 그리면 내용 위에 글자가 뜬다. 자리도 함께
    // 돌려준다(`chipRowTakenPx`).
    if (self.agent_activity.open != null) return;

    const rect = chipRowRect(self);
    if (rect.h == 0) return;
    var buf: [4]ChipSpan = undefined;
    const spans = chipSpans(self, &buf);
    if (spans.len == 0) return;

    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    const dim: maru.terminal.Color = .{ .rgb = towardBg(
        self.appearance.theme.sidebar_foreground,
        self.appearance.theme.sidebar_background,
        time_dim_percent,
    ) };
    // 칩 글자를 줄 가운데에 둔다 — 위아래 여백을 반씩 나눈다.
    const y = rect.y +| (chip_row_padding_px / 2);

    var drawn: usize = 0;
    for (spans) |span| {
        const text = filterText(span.filter);
        const color = if (span.filter == self.agent_activity.filter) fg else dim;
        const dl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, span.cols, text, color) catch continue;
        self.collectShaped(collected, dl, builder, .{ .pane = .{
            .origin_x = rect.x +| (@as(u32, span.col) *| self.cell_width_px),
            .origin_y = y,
            .colors = colors,
        } });
        drawn += 1;
    }
    self.agent_activity.drawn_chips = drawn;
}

/// 칩 줄을 눌렀나. 눌렀으면 그 필터로 바꾸고 `true`.
///
/// **자리는 `chipSpans` 가 정한다** — 그리기와 같은 함수라 「보이는 칩」과 「눌리는 칩」이 갈리지
/// 않는다. 좁아서 칩이 하나뿐일 때는 그것을 눌러도 아무 일도 안 한다(이미 고른 것이다).
pub fn handleChipDown(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return false;
    if (self.agent_activity.open != null) return false;
    const rect = chipRowRect(self);
    if (rect.h == 0) return false;
    if (y_px < @as(f64, @floatFromInt(rect.y)) or y_px >= @as(f64, @floatFromInt(rect.y +| rect.h))) return false;
    if (x_px < @as(f64, @floatFromInt(rect.x))) return false;

    var buf: [4]ChipSpan = undefined;
    const spans = chipSpans(self, &buf);
    if (spans.len == 0) return false;
    if (self.cell_width_px == 0) return false;

    const rel = @as(u32, @intFromFloat(@max(0, x_px))) -| rect.x;
    const col: u32 = rel / self.cell_width_px;
    for (spans) |span| {
        if (col >= span.col and col < @as(u32, span.col) +| span.cols) {
            setFilter(self, span.filter);
            return true;
        }
    }
    // 칩 줄 안이지만 빈 자리다 — 도크를 눌렀다는 사실만 받고 삼킨다(뒤 터미널로 새지 않게).
    self.agent_activity.key_focus = true;
    return true;
}

/// 종류 필터를 **그것으로** 바꾼다. 같은 것이면 아무 일도 안 한다.
///
/// `cycleFilter` 와 같은 뒷정리를 한다 — 크게 보기를 닫고, 보던 자리·얹힌 칸·넘친 수를 되돌린다.
/// 두 입구가 다른 정리를 하면 「Tab 으로 바꿨을 때와 눌러서 바꿨을 때가 다르다」가 된다.
pub fn setFilter(self: *AppSession, want: Filter) void {
    if (self.agent_activity.filter == want) return;
    closeOpen(self);
    self.agent_activity.filter = want;
    self.agent_activity.scroll.offset_y_px = 0;
    self.agent_activity.hovered = null;
    self.agent_activity.overflow = 0;
    rebuildFilter(self);
    self.agent_activity.key_focus = true; // 도크를 눌렀다 = 키보드도 도크로
    self.metal_dirty = true;
}

/// 활동을 **줄 목록**으로 그린다(활동 뷰 계약 §2.1·§2.2).
///
/// **격자와 같은 자리를 쓴다.** 필터가 모양을 정하므로 둘이 동시에 뜨는 일은 없다. 자리 계산을
/// 여기서 하는 이유는 격자(`image_grid`)의 배치가 정사각 타일 전제라 줄에 맞지 않기 때문이다.
///
/// 지금은 **대상 한 줄**만 그린다. 결과 요약과 시각은 AV2, 펼침은 AV3 다 — 없는 것을 자리만
/// 잡아 두면 빈 띠가 남고, 그것은 「없다」와 「아직 안 붙였다」를 섞는다.
pub fn collectActivityList(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    // **펼치면 목록은 물러난다**(AV3 — 계약 §2.4 「크게 보기와 같은 자리」). 안 비키면 본문 글자가
    // 목록 글자 위에 얹혀 **둘 다 못 읽는다** — 격자가 크게 보기 앞에서 물러나는 것과 같은 규율이다.
    // **안 그리면 0 이라고 말한다.** 칩(`drawn_chips`)·펼침(`drawn_detail_rows`)이 이미 그 규율을
    // 갖는데 목록만 빠져 있었다 — 펼침이 열리면 여기서 그냥 물러나므로 지난 프레임의 줄 수가 남고,
    // 「지금 목록이 그려지고 있나」를 값으로 보는 창이 거짓말을 한다(적대적 1 회차).
    self.agent_activity.drawn_rows = 0;
    self.agent_activity.drawn_pieces = 0;
    if (self.agent_activity.open != null) return;
    if (self.agent_activity.filter.isGrid()) {
        // 격자에는 줄이 없다 — 옛 값이 남으면 판정자가 속는다.
        self.agent_activity.drawn_rows = 0;
        self.agent_activity.drawn_pieces = 0;
        return;
    }

    // **한 줄도 못 그리는 길에서도 그 사실을 남긴다**(계약 §2 — 「없다」와 「안 보인다」는 다르다).
    // 조용히 물러나면 화면은 비었는데 안내는 「4,084개」라고만 말해, 사용자에게는 목록이 **없는 것**과
    // 구분되지 않는다.
    //
    // ⚠️ **어느 길에서 그 안내가 실제로 보이는지 알고 적는다.** `gridArea().w` 는 `tree_content.w` 와
    // 같은 값이므로, `cols == 0` 이면 안내도 같은 폭 게이트(`tree_content_cols > 0`)에 막혀 **갤러리
    // 블록 자체가 안 돈다** — 그 경우 문구는 원리적으로 화면에 못 나온다. 실제로 보이는 길은
    // **세로가 모자랄 때**(`area.h == 0`)다. 그래서 문구가 「좁다」가 아니라 「자리가 없다」이다
    // (적대적 검증 F1 이 「좁아서」라고 적힌 것을 잡았다 — 틀린 원인을 말하고 있었다).
    const win = listWindow(self);
    const area = gridArea(self);
    // **썸네일이 자리를 먼저 받는다**(AV5). 그림이 붙는 줄은 드물지만(실측 60 줄에 한 줄) 자리는
    // 모든 줄이 똑같이 비운다 — 줄마다 들쭉날쭉하면 이름이 세로로 안 맞아 훑기 어렵다.
    const thumb_cols = thumbCols(self);
    const text_x = area.x +| (@as(u32, thumb_cols) *| self.cell_width_px);
    const cols = win.cols -| thumb_cols;
    const row_h = win.row_h;
    if (cols == 0 or row_h == 0) {
        self.agent_activity.overflow = win.total;
        self.agent_activity.drawn_rows = 0;
        self.agent_activity.drawn_pieces = 0;
        return;
    }

    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };

    // 스크롤은 격자와 같은 값을 쓴다 — 필터를 바꿔도 「어디를 보고 있었나」가 이어진다.
    const first = win.first;
    const last = win.last;
    // **자리를 못 얻은 수를 남긴다.** 계약 §2(「없다」와 「안 보인다」를 가른다)를 지키는 것은 이제
    // 안내가 직접 부르는 `listWindow` 이고, **이 필드를 읽는 제품 코드는 없다** — 판정자가 렌더를
    // 들여다보는 창일 뿐이다(`drawn_rows` 와 같은 역할, 적대적 검증 K1 이 전수로 확인했다).
    // 그 사실을 안 적으면 다음 사람이 「안내가 이걸 읽겠지」로 오해해 순서 의존을 되살린다.
    self.agent_activity.overflow = win.total -| (last -| first);

    // 접두·시각은 라벨보다 **흐리게** — 곁말이 본문보다 먼저 읽히면 안 된다(격자 라벨과 같은 규율).
    const dim: maru.terminal.Color = .{ .rgb = towardBg(
        self.appearance.theme.sidebar_foreground,
        self.appearance.theme.sidebar_background,
        time_dim_percent,
    ) };
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
    const now_off = utcOffsetAt(now_s);

    var drawn: usize = 0;
    var pieces: usize = 0;
    var i = first;
    while (i < last) : (i += 1) {
        if (i >= self.agent_activity.labels.items.len) break;
        const label = self.agent_activity.labels.items[i];
        const text = label.text();
        // **「전체」에는 이미지도 섞인다.** 그 줄의 「첨부 / 읽음」은 계약 §2.2.1 이 「이 화면에 사용자가
        // 던지는 첫 물음」이라고 못박은 정보다 — 목록이라고 버리면 격자에서 답하던 것을 못 답한다.
        // 활동 줄에는 접두가 없다(`Source.none`) — 모르면 말하지 않는다.
        var prefix_buf: [context_mod.max_label_bytes]u8 = undefined;
        const prefix = context_mod.originPrefix(
            &prefix_buf,
            originText(label.source),
            label.seq,
            label.seq_total,
        );
        // 없는 설명을 지어내지 않는다. **자리는 지킨다** — `y` 를 `i` 로 계산하므로 못 그린 줄은
        // 빈 자리로 남는다. 그것이 「뭔가 있었는데 못 그렸다」를 정직하게 보이고, 항목 위치가
        // 인덱스와 1:1 이라 스크롤·클릭(AV3) 계산이 갈리지 않는다(적대적 검증 H3 의 결정).
        if (text.len == 0 and prefix.len == 0) continue;
        drawn += 1;

        // **시각도 격자에서 갖던 정보다.** 활동 라벨은 아직 `time_s == 0`(AV2)이라 안 그려지지만,
        // 「전체」에 섞이는 이미지 줄은 격자에서 시각을 보여 주고 있었다 — 목록이라고 버리면
        // 접두를 버렸던 것과 같은 손실이다(적대적 검증 I3, D3 와 짝).
        var time_buf: [16]u8 = undefined;
        var time_text: []const u8 = &.{};
        if (label.time_s != 0) {
            const off = utcOffsetAt(label.time_s);
            time_text = formatImageTime(&time_buf, label.time_s, off, now_s, now_off);
        }

        // **결과 요약**(AV2) — 그 호출이 어떻게 끝났나. 못 찾은 호출은 빈 문자열이라 자리를 안 먹는다.
        var summary_buf: [max_result_summary_bytes]u8 = undefined;
        const summary = if (i < self.agent_activity.hits.items.len)
            formatResultSummary(&summary_buf, self.agent_activity.hits.items[i].result)
        else
            "";

        const y = area.y + @as(u32, @intCast((i - first) * row_h));
        // 자리 나누기는 격자와 **같은 결의 순수 함수**가 정한다 — 좁아지면 시각부터, 그다음 요약을
        // 버리고 대상은 마지막까지 지킨다(활동 뷰 계약 §2.2 · 갤러리 §2.2.3).
        const split = context_mod.splitActivityRow(
            cols,
            displayColsOf(prefix),
            displayColsOf(summary),
            displayColsOf(time_text),
            time_gap_cols,
            if (text.len == 0) 0 else min_label_cols,
        );

        var at_col: u32 = 0;
        if (split.prefix_cols > 0) {
            const pdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.prefix_cols, prefix, dim) catch continue;
            self.collectShaped(collected, pdl, builder, .{ .pane = .{
                .origin_x = text_x,
                .origin_y = y,
                .colors = colors,
            } });
            pieces += 1;
            at_col = @as(u32, split.prefix_cols) +| time_gap_cols;
        }
        if (text.len > 0 and split.label_cols > 0) {
            const dl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.label_cols, text, fg) catch continue;
            self.collectShaped(collected, dl, builder, .{ .pane = .{
                .origin_x = text_x +| (at_col *| self.cell_width_px),
                .origin_y = y,
                .colors = colors,
            } });
            pieces += 1;
        }
        // 요약은 시각 **왼쪽**이다(계약 §2.2 의 줄 모양 그대로). 시각이 버려졌으면 그 자리를 쓴다.
        if (split.summary_cols > 0 and summary.len > 0) {
            const tail: u32 = if (split.time_cols == 0) 0 else @as(u32, split.time_cols) +| time_gap_cols;
            const summary_col: u32 = @as(u32, cols) -| tail -| split.summary_cols;
            const sdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.summary_cols, summary, dim) catch continue;
            self.collectShaped(collected, sdl, builder, .{ .pane = .{
                .origin_x = text_x +| (summary_col *| self.cell_width_px),
                .origin_y = y,
                .colors = colors,
            } });
            pieces += 1;
        }
        if (split.time_cols > 0 and time_text.len > 0) {
            // 시각은 **오른쪽 끝**에 붙인다(격자 라벨과 같은 자리 규약).
            const time_col: u32 = @as(u32, cols) -| split.time_cols;
            const tdl = coretext_frame_builder.buildDockTileLabelDrawList(self.allocator, split.time_cols, time_text, dim) catch continue;
            self.collectShaped(collected, tdl, builder, .{ .pane = .{
                .origin_x = text_x +| (time_col *| self.cell_width_px),
                .origin_y = y,
                .colors = colors,
            } });
            pieces += 1;
        }
    }
    self.agent_activity.drawn_rows = drawn;
    self.agent_activity.drawn_pieces = pieces;
}

/// 요약 문자열의 상한. 「실패 · 4294967295줄」이 가장 긴 모양이고 그 두 배다.
const max_result_summary_bytes: usize = 64;

/// 결말을 **한 조각**으로 적는다(계약 §2.2, 사용자 결정 2026-09-07).
///
/// 크기(줄 수)는 언제나 쓰고, **실패는 provider 가 적었을 때만** 앞에 붙인다. 결과를 못 찾은 호출은
/// **빈 문자열**이다 — 「모른다」를 「0 줄」로 적지 않는다(취소된 호출이 실제로 그렇다).
///
/// 계획 초안은 「결과의 **첫 줄**과 크기」였는데 실측이 그것을 기각했다: Codex 결과 첫 줄의 상위는
/// `Script completed`(133,852) · `Chunk ID`(14,940) · 파일명이라, 그대로 실으면 칸이 잡음으로 찬다.
///
/// **`pub` 인 이유는 판정자다** — 화면에 적히는 문자열이고, 도크 렌더를 통째로 세우지 않고 이 한 줄을
/// 직접 잴 수 있어야 한다(`remoteWatchTargetForTest` 와 같은 규율).
pub fn formatResultSummary(buf: []u8, result: maru.session.agent_image_index.ResultSummary) []const u8 {
    if (!result.found) return "";
    // **본문이 없는 결과가 있다.** Claude 의 이미지 결과는 `content` 가 이미지 블록만 든 배열이라
    // (실측 542/542) 셀 줄이 아예 없다 — 그때 「0줄」은 사실이 아니고 빈 칸은 「모른다」로 읽힌다.
    //
    // ⚠️ **이미지라고 무조건 덮지 않는다.** Codex 의 이미지 결과는 `output` 이 `[{text}, …, {input_image}]`
    // 라 **실제 텍스트가 있다**(실측: 첫 원소가 `text`, 원소 3 개). 그것을 「이미지」로 덮으면
    // provider 가 적어 준 말을 우리가 지운다 — 본문이 있으면 줄 수가 여전히 맞는 답이다.
    if (result.image and result.lines == 0) {
        const text = maru.i18n.t(.agent_activity_result_image);
        // **실패는 삼키지 않는다.** provider 가 적은 유일한 근거이므로(계약 §2.3), 종류를 바꿔
        // 말한다고 그것을 지우면 안 된다. 줄 수 갈래를 그대로 쓰면 「실패 · 0줄」이 되는데 그건
        // 더 나쁜 거짓말이라, 여기서 「실패 · 이미지」로 붙인다. (실측 이미지 결과의 실패는 0 건이지만
        // 근거를 삼키는 코드를 두지 않는다.)
        if (result.failed) {
            return std.fmt.bufPrint(buf, "{s} \u{00b7} {s}", .{
                maru.i18n.t(.agent_activity_result_failed),
                text,
            }) catch text;
        }
        if (text.len > buf.len) return text; // 상수 문자열이라 버퍼 없이도 안전하다
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const suffix = maru.i18n.t(.agent_activity_result_lines_suffix);
    if (result.failed) {
        return std.fmt.bufPrint(buf, "{s} \u{00b7} {d}{s}", .{
            maru.i18n.t(.agent_activity_result_failed),
            result.lines,
            suffix,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}{s}", .{ result.lines, suffix }) catch "";
}

/// 펼친 항목의 **본문**을 그린다(AV3 — 계약 §2.4). 명령 전문 → 빈 줄 → 「결과」 → 결과 전문 순이다.
///
/// **이미지의 크게 보기와 같은 자리를 쓴다**(계약 §2.4) — 둘 다 「한 항목을 크게 본다」이고 동시에
/// 열릴 수 없다. 그래서 여기서 그리는 동안 격자·목록은 이미 물러나 있다.
///
/// **들어가는 줄만 그린다.** 이 판에는 패널 스크롤이 없으므로, 못 그린 뒤는 「이하 생략」이 말한다 —
/// 그 한 줄이 「내용이 여기까지다」와 「자리가 여기까지다」를 가른다.
pub fn collectOpenDetail(
    self: *AppSession,
    collected: *std.ArrayList(AppSession.CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return;
    if (!isDetailOpen(self)) return;
    const op = if (self.agent_activity.open) |*o| o else return;

    const area = gridArea(self);
    const row_h = labelHeightPx(self);
    if (area.w == 0 or area.h == 0 or row_h == 0) return;
    const cols: u16 = @intCast(@min(area.w / self.cell_width_px, @as(u32, std.math.maxInt(u16))));
    if (cols == 0) return;
    const rows_fit: usize = @intCast(area.h / row_h);
    if (rows_fit == 0) return;

    const fg: maru.terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
    const dim: maru.terminal.Color = .{ .rgb = towardBg(
        self.appearance.theme.sidebar_foreground,
        self.appearance.theme.sidebar_background,
        time_dim_percent,
    ) };

    var row: usize = 0;
    const draw = struct {
        fn one(
            s: *AppSession,
            c: *std.ArrayList(AppSession.CollectedPane),
            b: coretext_frame_builder.CoreTextFrameBuilder,
            col: metal_frame.CellColors,
            a: @TypeOf(area),
            h: u32,
            n: usize,
            w: u16,
            text: []const u8,
            fgc: maru.terminal.Color,
        ) void {
            if (text.len == 0) return; // 빈 줄은 자리만 차지한다 — 그리지 않는다
            const dl = coretext_frame_builder.buildDockTileLabelDrawList(s.allocator, w, text, fgc) catch return;
            s.collectShaped(c, dl, b, .{ .pane = .{
                .origin_x = a.x,
                .origin_y = a.y + @as(u32, @intCast(n)) * h,
                .colors = col,
            } });
        }
    }.one;

    // ── 명령 전문
    var it = std.mem.splitScalar(u8, op.detail.command, '\n');
    while (it.next()) |line| {
        if (row >= rows_fit) return;
        draw(self, collected, builder, colors, area, row_h, row, cols, line, fg);
        row += 1;
    }
    if (op.detail.command_truncated) {
        if (row >= rows_fit) return;
        draw(self, collected, builder, colors, area, row_h, row, cols, maru.i18n.t(.agent_activity_detail_truncated), dim);
        row += 1;
    }

    // ── 결과 전문. **없으면 머리도 안 그린다** — 「결과가 없다」를 빈 칸으로 말한다.
    if (!op.detail.has_result) return;
    if (row + 1 >= rows_fit) return;
    row += 1; // 빈 줄 하나로 가른다
    // **종료 코드가 있으면 머리에 붙인다**(§6 — 벗기면서 잃지 않는다). 없으면 그냥 「결과」다:
    // 실측 chunk 의 **66.1%** 에는 코드가 없고, 없는 것을 `0` 으로 지어내면 「실패했나」가 거짓말이
    // 된다.
    var head_buf: [64]u8 = undefined;
    const head = if (op.detail.result_exit_code) |code|
        maru.i18n.format(&head_buf, maru.i18n.t(.agent_activity_detail_exit), &.{.{ .d = code }})
    else
        maru.i18n.t(.agent_activity_detail_result);
    draw(self, collected, builder, colors, area, row_h, row, cols, head, dim);
    row += 1;
    var rit = std.mem.splitScalar(u8, op.detail.result, '\n');
    while (rit.next()) |line| {
        if (row >= rows_fit) return;
        draw(self, collected, builder, colors, area, row_h, row, cols, line, fg);
        row += 1;
    }
    // **원격에서 못 당겨왔으면 그렇게 말한다**(RAV5b). 빈 채로 그리면 화면이 「에이전트가 빈 명령을
    // 돌렸다」고 거짓말한다 — 계약 §2.2 의 그 갈림이 펼침에도 선다.
    if (op.detail.remote_failed and row < rows_fit) {
        draw(self, collected, builder, colors, area, row_h, row, cols, maru.i18n.t(.agent_activity_remote_unsupported), dim);
        return;
    }
    if (op.detail.result_truncated and row < rows_fit) {
        draw(self, collected, builder, colors, area, row_h, row, cols, maru.i18n.t(.agent_activity_detail_truncated), dim);
    }
}

/// 도크 본문에 낼 한 줄. 아직 격자가 없으므로 개수와 상태만 말한다.
///
/// **다섯을 가른다** — 「에이전트가 없다」·「원격이라 못 읽는다」·「세는 중」·「훑었는데 없다」·
/// 「못 봤다」. 접으면 사용자가
/// «이미지가 없는 것» 과 «아직 세는 중» 과 «갤러리가 고장난 것» 을 구분할 수 없다.
pub fn noticeText(self: *const AppSession, buf: []u8) []const u8 {
    // **검색줄이 가장 먼저다.** 타이핑 중인데 「12장 중 8장」이 떠 있으면 자기가 친 글자를 못 본다.
    // 조합 중인 글자(`preedit`)도 붙여 그린다 — 한글은 확정 전에 보이지 않으면 못 친다.
    if (searchOwnsInput(self)) return searchLine(self, buf).text;
    // **크게 보기가 먼저다.** 열려 있으면 격자 개수는 지금 사용자가 보는 것과 무관하다.
    if (self.agent_activity.open) |op| {
        if (op.pixels.len > 0) return "";
        // 도는 것이 없는데 픽셀도 없다 = 못 풀었다. 조용히 닫으면 클릭이 안 먹은 것처럼 보인다.
        if (op.decoding == 0) return maru.i18n.t(.agent_activity_open_failed);
    }
    // **원격에서 못 읽은 것을 「없다」로 말하지 않는다**(계약 §2.2 · RAV3). 왕복이 실패하면 자리가
    // 0 개로 오는데, 그것을 그냥 그리면 화면이 「활동이 없습니다」라고 **거짓말**한다 — 사용자는
    // 에이전트가 아무것도 안 한 줄 안다. 헬퍼가 없거나(exit 127) 채널이 끊긴 것이다.
    if (self.agent_activity.remote_failed) return maru.i18n.t(.agent_activity_remote_unsupported);
    if (self.agent_activity.chain.isEmpty()) {
        // **「없다」와 「못 읽는다」는 다르다.** 원격 pane 에는 에이전트가 **있는데도**(사이드바 배지가
        // 그것을 보여준다) 아직 소스를 못 정했을 수 있다.
        if (self.agent_activity.source_remote) return maru.i18n.t(.agent_activity_remote_unsupported);
        return maru.i18n.t(.agent_activity_no_agent);
    }
    if (self.agent_activity.scanning()) return maru.i18n.t(.agent_activity_scanning);
    // **본문을 훑는 중이면 그렇게 말한다**(계약 §2.1.1). 수백 ms 동안 「걸린 것이 없습니다」라고
    // 하면 사용자는 `Enter` 가 안 먹은 줄 안다 — 스캔에서 「세는 중」을 가른 것과 같은 이유다.
    if (self.agent_activity.body.awaiting != 0 or self.agent_activity.body.resubmit) {
        return maru.i18n.t(.agent_activity_body_searching);
    }
    const n = self.agent_activity.count();
    // **「못 읽었다」는 찾은 것이 있을 때만 말한다**(사용자 보고). 대화 기록이 비어 있으면 스캔이
    // partial 로 끝나기 쉬운데, 그때 「세션을 다 읽지 못했습니다」라고 하면 사용자에게는 갤러리가
    // 고장난 것으로 보인다 — 실제로는 **없는 것**이다.
    //
    // 다만 **한 바이트도 못 읽었으면**(`scanned_bytes == 0`) 그건 진짜로 못 읽은 것이다(파일 없음·
    // 열기 실패). 그때까지 「없다」로 뭉개면 갤러리가 멀쩡한 줄 안다 — IG1-e 가 그 자리를 잡았다.
    // **지금 보는 종류가 잘렸을 때만 말한다.** 활동만 잘렸는데 이미지 필터에서 「다 읽지
    // 못했습니다」가 뜨면 거짓말이다 — 실측 최악 파일에서 활동은 91% 가 잘리지만 이미지 27 장은
    // 종류별 상한 덕에 전부 들어온다(적대적 검증 O1).
    //
    // 종류별 플래그가 아직 없던 스캔 결과(옛 세션)에서는 `partial` 하나로 물러난다.
    const kind_partial = if (self.agent_activity.image_partial or self.agent_activity.activity_partial)
        self.agent_activity.filter.partialOf(
            self.agent_activity.image_partial,
            self.agent_activity.activity_partial,
        )
    else
        self.agent_activity.partial;
    if (kind_partial and (n > 0 or self.agent_activity.scanned_bytes == 0)) {
        return maru.i18n.t(.agent_activity_partial);
    }
    // **「본문을 다 못 봤다」가 「없다」보다 먼저다**(적대적 9회차). 0 건일 때야말로 그 구분이
    // 가장 중요하다 — 뭔가 나왔으면 사용자는 그것을 보지만, 0 건이면 **「없다」를 믿고 검색을
    // 그만둔다**. 못 본 조각에 그 검색어가 있었을 수 있는데도 그렇다.
    //
    // ⚠️ 2 회차가 이 분기를 넣었는데 자리가 `n == 0` **뒤**였다. 주석은 「개수보다 먼저다」라고
    // 적혀 있었으니 **주석이 거짓**이었고, 고치려던 혼동이 0 건일 때 고스란히 남아 있었다.
    const body_partial = self.agent_activity.body.partial and
        self.agent_activity.body.appliesTo(self.agent_activity.queryText());
    if (body_partial) return maru.i18n.t(.agent_activity_body_partial);
    if (n == 0) {
        // 거르고 있는데 0 이면 「세션에 이미지가 없다」가 **아니다**. 그렇게 말하면 사용자는 검색어를
        // 지울 생각을 못 하고 갤러리가 고장났다고 읽는다.
        if (self.agent_activity.queryText().len > 0) return maru.i18n.t(.agent_activity_no_match);
        // **「이미지가 없다」는 이미지 필터에서만 참이다.** 실행 필터에서 그 문구를 내면 거짓말이고,
        // 사용자는 갤러리가 고장난 줄 안다(계약 §2 — 「없다」와 「안 보인다」를 가르는 규율의 연장).
        if (!self.agent_activity.filter.isGrid()) return maru.i18n.t(.agent_activity_none_of_kind);
        return maru.i18n.t(.agent_activity_empty);
    }
    // **어디서 맞았는지 가른다**(계약 §2.1.1). 「라벨 3 · 본문 +12」 — 사용자가 「내가 친 말이
    // 이름에 있었나 본문에 있었나」를 알아야 다음 검색어를 고른다. 본문에서만 걸린 줄은 라벨에
    // 그 글자가 **안 보이므로**, 이 줄이 없으면 「왜 이게 떴지」가 된다.
    //
    // 「12장 중 8장」보다 앞선다: 검색 중에는 **왜 이 목록인가**가 몇 장이 잘렸나보다 급하다.
    if (self.agent_activity.shown_body_matches > 0) {
        return maru.i18n.format(buf, maru.i18n.t(.agent_activity_match_split), &.{
            .{ .d = @intCast(self.agent_activity.shown_label_matches) },
            .{ .d = @intCast(self.agent_activity.shown_body_matches) },
        });
    }
    // 격자가 다 보여 주면 문구를 겹쳐 내지 않는다 — 개수는 격자 자체가 말한다.
    // **다 못 보여 줄 때만 말한다**: 「12장 중 8장」. 이 줄이 없으면 사용자는 4장을 놓치고도 모른다.
    if (self.agent_activity.tiles.items.len > 0) {
        // **렌더가 남긴 값이 아니라 지금 계산을 본다.** 그리는 순서가 「안내 → 격자」라 잔값을 읽으면
        // 한 프레임 늦는다 — 목록에서 고친 것과 **같은 결함**이고, 그때 격자를 빠뜨렸다(적대적 검증 J5).
        const grid_overflow = gridLayout(self).overflow;
        if (grid_overflow == 0) return "";
        return maru.i18n.format(buf, maru.i18n.t(.agent_activity_shown_of), &.{
            .{ .d = @intCast(n -| grid_overflow) },
            .{ .d = @intCast(n) },
        });
    }
    // **하나도 못 그렸으면 그렇게 말한다.** 목록은 자리를 못 얻으면 통째로 비는데(좁은 도크·줄
    // 높이 0), 그때 개수만 적으면 사용자에게는 「목록이 없다」와 구분되지 않는다 — 계약 §2 가
    // 가르라고 한 바로 그 둘이다. 격자는 「12장 중 8장」이 그 몫을 하지만 목록에는 타일이 없어
    // 그 경로를 안 탄다.
    if (!self.agent_activity.filter.isGrid() and listOverflow(self) >= n) {
        return maru.i18n.t(.agent_activity_too_narrow);
    }
    // **단위도 종류를 따른다.** 명령을 「장」으로 세면 안 된다 — 헤드리스 캡처가 실제로 「4084장」을
    // 잡아냈고, 값 판정자로는 안 보이는 종류의 결함이다(계약 §2.2 의 「지어내지 않는다」와 같은 축:
    // 이미지의 단위를 활동에 빌려 쓰면 화면이 거짓을 말한다).
    const suffix = if (self.agent_activity.filter.isGrid())
        maru.i18n.t(.agent_activity_count_suffix)
    else
        maru.i18n.t(.agent_activity_activity_count_suffix);
    // 문구가 안 들어가면 개수를 지어내지 않는다 — 빈 문자열이 낫다.
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, suffix }) catch buf[0..0];
}

/// `formatImageTime` 의 test 창구. 순수 함수라 화면 없이 표기를 짚을 수 있다.
pub fn testFormatImageTime(buf: []u8, at_s: i64, at_off: i64, now_s: i64, now_off: i64) []const u8 {
    return formatImageTime(buf, at_s, at_off, now_s, now_off);
}

// ── 원격 펼침(RAV5b) ────────────────────────────────────────────────────────────────────────────

/// 원격 펼침 워커의 결말. **소유가 통째로 이동한다** — 드레인이 푼다.
pub const RemoteDetailOutcome = struct {
    /// 어느 항목의 것인가. 그 사이 다른 것을 열었으면 드레인이 버린다.
    hit_index: usize,
    /// 이 결말을 만든 요청. 소스가 갈리면(`/clear`·pane 이동) 옛 답을 버린다.
    generation: u64,
    command: []u8 = &.{},
    body: []u8 = &.{},
    /// 못 읽었다 — 「빈 명령」과 다른 사실이다(계약 §2.2).
    failed: bool = false,

    pub fn deinit(self: RemoteDetailOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.body);
    }
};

const RemoteDetailJob = struct {
    session: *AppSession,
    ctl: []u8,
    dest: []u8,
    path: []u8,
    hit_index: usize,
    generation: u64,
    cmd_offset: u64,
    body_offset: u64,
    body_wanted: bool,
};

/// 원격 펼침을 건다. **tick 을 막지 않는다** — ssh 왕복은 수백 ms 이고 그동안 UI 가 멈추면 그것이 곧
/// 「maru 가 원격에 붙을 때 뻗는다」다(RF4 가 같은 자리에서 같은 판단을 했다).
///
/// 이미 도는 것이 있으면 **안 건다**. 다음 tick 이 다시 온다 — 펼침은 사람이 클릭하는 일이라 한
/// 왕복이 도는 동안 또 걸 이유가 없다(계획 §6.2 의 슬롯 규율과 같은 결).
fn beginRemoteDetail(self: *AppSession, n: usize, hit: index.Hit) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.remote_detail_inflight) return;

    const term = pane_ops.activePane(self).activeTerm();
    const ctx = self.remoteUploadContextFor(term) orelse {
        // 목적지를 못 얻었다 — 그 사실이 곧 「못 읽었다」다(계약 §2.2 · §13.3 과 같은 갈림).
        markRemoteDetailFailed(self, n);
        return;
    };
    defer ctx.deinit(self.allocator);

    const path = remotePathForIndex(self, hit.file_index) orelse {
        markRemoteDetailFailed(self, n);
        return;
    };

    const job = self.allocator.create(RemoteDetailJob) catch return;
    job.* = .{
        .session = self,
        .ctl = self.allocator.dupe(u8, ctx.ctl) catch {
            self.allocator.destroy(job);
            return;
        },
        .dest = undefined,
        .path = undefined,
        .hit_index = n,
        .generation = self.agent_activity.detail_generation,
        // **명령 전문이 먼저다**(계약 §2.2) — 라벨의 대상은 대개 모델이 쓴 요약이라 그것을 다시
        // 보여 주면 명령은 영영 안 보인다.
        .cmd_offset = if (hit.cmd_rel != 0) hit.line_offset +| hit.cmd_rel else hit.data_offset,
        .body_offset = hit.result.body.offset,
        .body_wanted = hit.result.found and hit.result.body.offset != 0,
    };
    job.dest = self.allocator.dupe(u8, ctx.dest) catch {
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        return;
    };
    job.path = self.allocator.dupe(u8, path) catch {
        self.allocator.free(job.dest);
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        return;
    };

    self.remote_detail_inflight = true;
    const thread = std.Thread.spawn(.{}, remoteDetailWorker, .{job}) catch {
        self.remote_detail_inflight = false;
        self.allocator.free(job.path);
        self.allocator.free(job.dest);
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        markRemoteDetailFailed(self, n);
        return;
    };
    thread.detach();
}

fn markRemoteDetailFailed(self: *AppSession, n: usize) void {
    const op = if (self.agent_activity.open) |*o| o else return;
    if (op.hit_index != n) return;
    op.detail.remote_failed = true;
    self.metal_dirty = true;
}

/// 백그라운드: 두 구간을 당겨 결과 슬롯에 둔다. **`std.Io` 를 안 만진다**(`ssh_upload` 규율).
///
/// ⚠️ **로컬 파일시스템도 안 만진다** — 저쪽 오프셋이 이쪽 syscall 로 가는 순간 §2.1 위반이고, 그것이
/// 이 축에서 가장 조용한 사고다(§13.6 N1).
fn remoteDetailWorker(job: *RemoteDetailJob) void {
    const self = job.session;
    const allocator = self.allocator;
    defer {
        allocator.free(job.path);
        allocator.free(job.dest);
        allocator.free(job.ctl);
        allocator.destroy(job);
    }

    var outcome: RemoteDetailOutcome = .{ .hit_index = job.hit_index, .generation = job.generation };
    outcome.command = fetchRange(allocator, job, job.cmd_offset) orelse blk: {
        outcome.failed = true;
        break :blk &.{};
    };
    if (job.body_wanted and !outcome.failed) {
        outcome.body = fetchRange(allocator, job, job.body_offset) orelse blk: {
            outcome.failed = true;
            break :blk &.{};
        };
    }

    self.remote_detail_mutex.lockUncancelable(self.io);
    if (self.remote_detail_outcome) |old| old.deinit(allocator); // 늦게 온 것이 있으면 버린다
    self.remote_detail_outcome = outcome;
    self.remote_detail_mutex.unlock(self.io);
}

/// 그 자리의 구간을 당겨온다. 못 읽으면 null — **빈 구간과 다른 사실이다**.
fn fetchRange(allocator: std.mem.Allocator, job: *RemoteDetailJob, offset: u64) ?[]u8 {
    if (offset == 0) return allocator.alloc(u8, 0) catch null;
    var off_buf: [24]u8 = undefined;
    var len_buf: [24]u8 = undefined;
    const off_text = std.fmt.bufPrint(&off_buf, "{d}", .{offset}) catch return null;
    const len_text = std.fmt.bufPrint(&len_buf, "{d}", .{max_detail_bytes}) catch return null;

    var out: []u8 = &.{};
    const code = ssh_upload.runRemoteCapped(
        allocator,
        job.ctl,
        job.dest,
        ssh_upload.activity_read_script,
        &.{ job.path, off_text, len_text },
        wire.max_range_wire_bytes,
        &out,
    ) catch return null;
    defer allocator.free(out);
    if (code != 0) return null;

    var parser = wire.RangeParser.init(out);
    var got: ?[]const u8 = null;
    while (parser.next() catch return null) |ev| switch (ev) {
        .bytes => |b| got = b,
        .remote_error => return null,
    };
    // **꼬리를 못 봤으면 잘린 것이다**(§6.1) — 잘린 바이트를 온전한 척 그리지 않는다.
    if (!parser.complete()) return null;
    const bytes = got orelse return null;
    return allocator.dupe(u8, bytes) catch null;
}

/// tick 이 워커의 결말을 낸다(드레인). **판정자가 직접 부르는 제품 함수**이기도 하다 — 전송 없이
/// 「결말 → 푸는 규칙 → 화면 텍스트」 수직을 실물로 태운다(RF4 의 `finishRemoteFileOpen` 과 같은 결).
pub fn finishRemoteDetail(self: *AppSession, outcome: RemoteDetailOutcome) void {
    defer outcome.deinit(self.allocator);
    self.remote_detail_inflight = false;

    const op = if (self.agent_activity.open) |*o| o else return;
    // **그 사이 다른 것을 열었거나 소스가 갈렸으면 버린다.** 늦게 온 답을 그리면 남의 명령이 뜬다.
    if (op.hit_index != outcome.hit_index) return;
    if (outcome.generation != self.agent_activity.detail_generation) return;

    if (outcome.failed) {
        // **옛 내용을 지운다.** 안 지우면 「못 읽었습니다」라고 말하면서 **직전 항목의 명령**을 같이
        // 그린다 — 판정자가 그것을 잡았다(늦게 온 답 축을 재다가 드러났다).
        op.detail.deinit(self.allocator);
        op.detail.remote_failed = true;
        self.metal_dirty = true;
        return;
    }

    // **로컬과 같은 규칙으로 푼다**(`decodeDetailPart` — 그 함수가 단일 출처다).
    op.detail.deinit(self.allocator);
    op.detail.command = decodeDetailPart(self, outcome.command, false, &op.detail.command_truncated, null);
    if (outcome.body.len > 0) {
        const hit = self.agent_activity.hits.items[outcome.hit_index];
        op.detail.has_result = true;
        op.detail.result = decodeDetailPart(
            self,
            outcome.body,
            hit.result.body.is_array,
            &op.detail.result_truncated,
            &op.detail.result_exit_code,
        );
    }
    op.detail.remote_failed = false;
    self.metal_dirty = true;
}

/// 지금 pane 이 원격이면 디코드 워커에 넘길 목적지(RAV6). 로컬이면 null.
///
/// **문자열 하나를 잡아 둘로 쪼갠다** — `RemoteUpload` 는 조각을 따로 잡으므로 호출자가 둘을 다
/// 해제해야 하는데, 그 규율이 갈리면 한쪽이 샌다(스캔 백엔드가 같은 자리에서 그 결함을 냈다 — N2).
/// 여기서는 **한 덩이**를 잡고 `owned` 하나만 풀면 된다.
fn decodeRemoteTarget(self: *AppSession) ?struct { owned: []u8, target: decode_backend.Backend.RemoteTarget } {
    if (!self.agent_activity.source_remote) return null;
    const term = pane_ops.activePane(self).activeTerm();
    const ctx = self.remoteUploadContextFor(term) orelse return null;
    defer ctx.deinit(self.allocator);

    const owned = self.allocator.alloc(u8, ctx.ctl.len + ctx.dest.len) catch return null;
    @memcpy(owned[0..ctx.ctl.len], ctx.ctl);
    @memcpy(owned[ctx.ctl.len..], ctx.dest);
    return .{
        .owned = owned,
        .target = .{ .ctl = owned[0..ctx.ctl.len], .dest = owned[ctx.ctl.len..] },
    };
}

// ── 원격 신선도(RAV7) ───────────────────────────────────────────────────────────────────────────

/// 원격 신선도 확인의 결말.
pub const RemoteFreshOutcome = struct {
    /// 어느 스캔의 자국에 대한 답인가. 그 사이 다시 훑었으면 드레인이 버린다.
    stamp: u64,
    /// **어느 파일**에 물었나(owned). 자국은 크기라 **다른 세션과 우연히 같을 수 있다** — 그때
    /// 경로를 안 보면 남의 pane 을 재스캔한다(적대적 T3).
    path: []u8 = &.{},
    /// **자랐다.** 자국 자리에서 바이트가 나왔다는 뜻이다.
    grew: bool = false,

    pub fn deinit(self: RemoteFreshOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const RemoteFreshJob = struct {
    session: *AppSession,
    ctl: []u8,
    dest: []u8,
    path: []u8,
    stamp: u64,
};

/// 원격 소스가 **자랐는지** 묻는다 — 왕복 하나로.
///
/// 🔥 **판을 안 올린다.** 「크기를 알려 달라」는 새 서브커맨드를 만들 수도 있지만, 이미 있는 문
/// (`read <path> <off> <len>`)으로 같은 것을 안다: **직전 스캔이 읽은 바이트 수 자리에서 1 바이트를
/// 청한다.** 빈 답이면 그 자리가 아직 파일 끝이고(안 자랐다), 1 바이트가 오면 자랐다.
///
/// 트랜스크립트는 **append-only** 라 이 판정이 성립한다 — `/clear` 는 **새 파일**을 만들고 그때는
/// 경로가 바뀌어 `refresh` 의 「소스가 갈렸나」가 먼저 잡는다.
///
/// **이것이 RAV7 의 값이다**: 그 전에는 뷰에 들어올 때마다 **통째로 다시 훑었다**(원격은 로컬 `stat`
/// 자국을 쓸 수 없어서 — §13.2). 이제는 왕복 하나로 「안 자랐다」를 확인하고 물러난다.
fn beginRemoteFreshness(self: *AppSession, path: []const u8) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    if (self.remote_fresh_inflight) return;
    // 자국이 0 이면 아직 한 번도 안 훑었다 — 물을 것이 없다.
    const stamp = self.agent_activity.remote_scanned_bytes;
    if (stamp == 0) return;

    const term = pane_ops.activePane(self).activeTerm();
    const ctx = self.remoteUploadContextFor(term) orelse return;
    defer ctx.deinit(self.allocator);

    const job = self.allocator.create(RemoteFreshJob) catch return;
    job.* = .{
        .session = self,
        .ctl = self.allocator.dupe(u8, ctx.ctl) catch {
            self.allocator.destroy(job);
            return;
        },
        .dest = undefined,
        .path = undefined,
        .stamp = stamp,
    };
    job.dest = self.allocator.dupe(u8, ctx.dest) catch {
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        return;
    };
    job.path = self.allocator.dupe(u8, path) catch {
        self.allocator.free(job.dest);
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        return;
    };

    self.remote_fresh_inflight = true;
    const thread = std.Thread.spawn(.{}, remoteFreshWorker, .{job}) catch {
        self.remote_fresh_inflight = false;
        self.allocator.free(job.path);
        self.allocator.free(job.dest);
        self.allocator.free(job.ctl);
        self.allocator.destroy(job);
        return;
    };
    thread.detach();
}

/// 백그라운드: 자국 자리에서 1 바이트를 청해 본다. **`std.Io` 도 로컬 파일시스템도 안 만진다.**
fn remoteFreshWorker(job: *RemoteFreshJob) void {
    const self = job.session;
    const allocator = self.allocator;
    defer {
        allocator.free(job.path);
        allocator.free(job.dest);
        allocator.free(job.ctl);
        allocator.destroy(job);
    }

    var outcome: RemoteFreshOutcome = .{
        .stamp = job.stamp,
        // job 이 곧 죽으므로 **사본을 넘긴다**(못 잡으면 경로 없이 가고, 드레인이 그것을 버린다).
        .path = allocator.dupe(u8, job.path) catch &.{},
    };
    var off_buf: [24]u8 = undefined;
    if (std.fmt.bufPrint(&off_buf, "{d}", .{job.stamp})) |off_text| {
        var out: []u8 = &.{};
        const code = ssh_upload.runRemoteCapped(
            allocator,
            job.ctl,
            job.dest,
            ssh_upload.activity_read_script,
            &.{ job.path, off_text, "1" },
            wire.max_range_wire_bytes,
            &out,
        ) catch -1;
        defer allocator.free(out);
        if (code == 0) {
            var parser = wire.RangeParser.init(out);
            var got: ?[]const u8 = null;
            var bad = false;
            while (parser.next() catch blk: {
                bad = true;
                break :blk null;
            }) |ev| switch (ev) {
                .bytes => |b| got = b,
                .remote_error => bad = true,
            };
            // **못 읽었으면 「안 자랐다」로 둔다.** 그 실패를 「자랐다」로 읽으면 매 주기마다 통째로
            // 다시 훑게 되고(RAV7 이 없애려던 그것), 화면에는 아무 근거도 안 뜬다.
            if (!bad and parser.complete()) {
                if (got) |b| outcome.grew = b.len > 0;
            }
        }
    } else |_| {}

    self.remote_fresh_mutex.lockUncancelable(self.io);
    self.remote_fresh_outcome = outcome;
    self.remote_fresh_mutex.unlock(self.io);
}

/// tick 이 신선도 답을 낸다(드레인). **판정자가 직접 부르는 제품 함수**다.
pub fn finishRemoteFreshness(self: *AppSession, outcome: RemoteFreshOutcome) void {
    defer outcome.deinit(self.allocator);
    self.remote_fresh_inflight = false;
    if (!remoteFreshnessWantsRescan(self, outcome)) return;
    refresh(self, true); // 자랐다 — 다시 훑는다(`force` 로 게이트를 지나간다)
}

/// 이 답이 **재스캔을 부르는가** — 순수 판정이다.
///
/// 🔥 **부수효과와 가른 이유**(적대적 T4): 판정자 하네스에는 스캔 백엔드가 없어 `refresh` 가 첫 줄에서
/// 물러난다 — 그래서 가드를 **없애도 아무 자국이 안 남았고**, 뮤테이션 셋이 죽지 않았다. 결정을 값으로
/// 내면 판정자가 그것을 직접 겨눈다(전송과 매핑을 가르는 이 스택의 규율과 같은 결).
pub fn remoteFreshnessWantsRescan(self: *const AppSession, outcome: RemoteFreshOutcome) bool {
    if (!self.agent_activity.source_remote) return false;
    // 🔥 **뷰를 떠났으면 안 훑는다**(적대적 T2 · 계약 §7③ 「볼 때만 훑는다」). 폴링 진입점이 그
    // 가드를 갖지만 **왕복이 도는 사이** 떠날 수 있고, 그때 재스캔을 걸면 아무도 안 보는 목록을
    // 위해 남의 서버가 최악 6.3 초를 태운다.
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_activity) return false;
    // **어느 파일에 물었는지 본다**(적대적 T3). 자국은 크기라 다른 세션과 우연히 같을 수 있다 —
    // 그때 경로를 안 보면 남의 pane 을 재스캔한다(그 자체는 안전하지만 **쓸데없는 왕복**이다).
    if (outcome.path.len == 0) return false;
    if (!std.mem.eql(u8, outcome.path, self.agent_activity.chain.head())) return false;
    // **자국이 0 이면 신선도가 꺼져 있다**(체인이 여럿이라 자국을 못 찍었다 — 적대적 S1). 그때 오는
    // 답은 판정의 근거가 없다.
    if (self.agent_activity.remote_scanned_bytes == 0) return false;
    // 그 사이 다시 훑었으면 이 답은 옛 자국의 것이다 — 버린다.
    if (outcome.stamp != self.agent_activity.remote_scanned_bytes) return false;
    return outcome.grew;
}
