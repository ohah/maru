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
const index = maru.session.agent_image_index;
const scan_backend = @import("../agent_image_scan_backend.zig");
const image_decode = @import("../image_decode.zig");
const image_scale = maru.session.image_scale;

/// 갤러리가 지금 보여 주는 것. **인덱스는 메모리 전용**이다(계약 §4.5) — 앱을 끄면 사라지고 다음 실행에서
/// 다시 훑는다.
pub const State = struct {
    /// 이 인덱스를 만든(또는 만들고 있는) 파일. 활성 Term 의 것과 다르면 무효다.
    source: index.Source = .{},
    hits: std.ArrayList(index.Hit) = .empty,
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

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.hits.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.hits.clearAndFree(allocator);
        self.source.clear();
        self.partial = false;
        self.scanned_bytes = 0;
        self.scan_ns = 0;
        self.built = false;
        self.awaiting = 0;
        self.resubmit = false;
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

/// 활성 Term 의 트랜스크립트 경로. 없으면 null — 에이전트가 붙지 않은 pane(셸만 띄운 창)이 그렇다.
///
/// **탭이 0 개인 창을 먼저 막는다.** merge/이동으로 비워진 뒤 Swift 가 닫기 전 tick 이 있고, 그때
/// `activePane()` 이 빈 리스트를 인덱싱해 패닉한다(`handleDroppedImage` 가 같은 이유로 같은 가드를 둔다).
fn activeSourcePath(self: *AppSession) ?[]const u8 {
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.agent_image_source.isEmpty()) return null;
    return term.agent_image_source.path();
}

fn backendPtr(self: *AppSession) ?*scan_backend.Backend {
    if (self.image_gallery_backend) |*b| return b;
    return null;
}

/// 갤러리 인덱스를 활성 pane 에 맞춘다. **파일을 여기서 읽지 않는다** — 워커에 요청만 건다.
///
/// 호출자는 둘이다: 뷰에 들어올 때(`setDockView`)와 소스가 바뀐 것을 훅이 알려 줬을 때.
pub fn refresh(self: *AppSession, force: bool) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    const path = activeSourcePath(self) orelse {
        if (self.image_gallery.built or self.image_gallery.scanning() or !self.image_gallery.source.isEmpty()) {
            backend.cancel();
            self.image_gallery.clear(self.allocator);
            self.metal_dirty = true;
        }
        return;
    };
    const same = std.mem.eql(u8, self.image_gallery.source.path(), path);
    if (!force and same and (self.image_gallery.built or self.image_gallery.scanning())) return;

    // 소스가 갈렸다 = 다른 세션이다(`/clear` 는 새 파일을 만든다). 옛 파일의 오프셋은 새 파일에서
    // 아무 뜻이 없으므로 통째로 버리고 다시 건다. 도는 스캔도 취소한다.
    backend.cancel();
    self.image_gallery.clear(self.allocator);
    _ = self.image_gallery.source.set(path);
    self.metal_dirty = true;

    if (backend.submit(path)) |generation| {
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

    if (self.image_gallery.resubmit and !self.image_gallery.source.isEmpty()) {
        if (backend.submit(self.image_gallery.source.path())) |generation| {
            self.image_gallery.awaiting = generation;
            self.image_gallery.resubmit = false;
        }
    }

    var result = backend.take() orelse return;
    // **늦게 온 것은 버린다.** 소스가 그 사이 바뀌었으면 이 결과는 남의 파일 것이다.
    if (result.generation != self.image_gallery.awaiting) {
        result.deinit(self.allocator);
        return;
    }
    self.image_gallery.hits.deinit(self.allocator);
    self.image_gallery.hits = result.hits; // 소유 이동 — 여기서부터 세션이 푼다
    self.image_gallery.partial = result.partial;
    self.image_gallery.scanned_bytes = result.scanned_bytes;
    self.image_gallery.scan_ns = result.scan_ns;
    self.image_gallery.built = true;
    self.image_gallery.awaiting = 0;
    self.image_gallery.resubmit = false;
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
    if (!builtin.target.os.tag.isDarwin()) return;
    const backend = backendPtr(self) orelse return;
    backend.cancel();
    self.image_gallery.awaiting = 0;
    self.image_gallery.resubmit = false;
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
    if (self.image_gallery.source.isEmpty()) return null;
    const hit = self.image_gallery.hits.items[n];

    const io = self.io;
    const file = std.Io.Dir.cwd().openFile(io, self.image_gallery.source.path(), .{
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

/// 도크 본문에 낼 한 줄. 아직 격자가 없으므로 개수와 상태만 말한다.
///
/// **넷을 가른다** — 「에이전트가 없다」·「세는 중」·「훑었는데 없다」·「못 봤다」. 접으면 사용자가
/// «이미지가 없는 것» 과 «아직 세는 중» 과 «갤러리가 고장난 것» 을 구분할 수 없다.
pub fn noticeText(self: *const AppSession, buf: []u8) []const u8 {
    if (self.image_gallery.source.isEmpty()) return maru.i18n.t(.image_gallery_no_agent);
    if (self.image_gallery.scanning()) return maru.i18n.t(.image_gallery_scanning);
    if (self.image_gallery.partial) return maru.i18n.t(.image_gallery_partial);
    const n = self.image_gallery.count();
    if (n == 0) return maru.i18n.t(.image_gallery_empty);
    // 문구가 안 들어가면 개수를 지어내지 않는다 — 빈 문자열이 낫다.
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, maru.i18n.t(.image_gallery_count_suffix) }) catch buf[0..0];
}
