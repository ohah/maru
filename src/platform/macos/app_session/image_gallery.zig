//! 이미지 갤러리 도크 뷰(IG1-d) — 계약은 [docs/agent-image-gallery.md](../../../../docs/agent-image-gallery.md).
//!
//! 지금 하는 일은 하나다: **활성 pane 의 트랜스크립트를 훑어 이미지가 몇 장인지 안다.** 썸네일도 격자도
//! 아직 없다(IG3·IG4). 이 슬라이스의 값어치는 사슬이 실제로 이어지는지 보는 것이다 —
//! 훅 `transcript_path` → `Term.agent_image_source` → 스캔 → 화면.
//!
//! **렌더 tick 에서 파일을 읽지 않는다.** 스캔은 뷰에 들어올 때와 소스가 바뀔 때만 돈다. 프레임 경로는
//! 이미 만들어 둔 결과만 읽는다 — 매 프레임 읽으면 실측 최대 1,626 MB 파일을 초당 60번 훑는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
const index = maru.session.agent_image_index;

/// 한 번에 읽는 크기. 아카이브 스캐너(64 KiB)와 같은 값이다 — 같은 성격의 순차 읽기라 다르게 둘 이유가 없다.
const read_chunk_bytes: usize = 64 * 1024;

/// 갤러리가 지금 보여 주는 것. **인덱스는 메모리 전용**이다(계약 §4.5) — 앱을 끄면 사라지고 다음 실행에서
/// 다시 훑는다.
pub const State = struct {
    /// 이 인덱스를 만든 파일. 활성 Term 의 것과 다르면 인덱스가 무효다.
    source: index.Source = .{},
    hits: std.ArrayList(index.Hit) = .empty,
    /// 상한(줄 길이·이미지 수)에 걸려 못 본 것이 있다. 「비었다」와 「못 봤다」는 다른 사실이라 나눠 든다.
    partial: bool = false,
    /// 마지막 스캔이 읽은 바이트와 걸린 시간. **동기 스캔이 얼마나 무거운지 답하기 위한 실측 자리다** —
    /// 계약 §4.1 이 전형 3 ms·최악 0.7 초라고 적었는데, 그것은 Python 으로 잰 값이라 제품에서 다시 재야 한다.
    scanned_bytes: u64 = 0,
    scan_ns: u64 = 0,
    /// 한 번이라도 훑었는가. `hits.len == 0` 과 다르다 — 이미지가 없는 파일도 훑은 것이다.
    built: bool = false,

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
    }

    pub fn count(self: *const State) usize {
        return self.hits.items.len;
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

/// 갤러리 인덱스를 활성 pane 에 맞춘다. 이미 그 파일로 만들어 뒀으면 아무것도 하지 않는다.
///
/// **여기 말고는 파일을 읽는 자리가 없다.** 호출자는 둘뿐이다 — 뷰에 들어올 때(`setDockView`)와
/// 소스가 바뀐 것을 훅이 알려 줬을 때. 그 둘 다 프레임 밖이다.
pub fn refresh(self: *AppSession, force: bool) void {
    if (!builtin.target.os.tag.isDarwin()) return;
    const path = activeSourcePath(self) orelse {
        if (self.image_gallery.built or !self.image_gallery.source.isEmpty()) {
            self.image_gallery.clear(self.allocator);
            self.metal_dirty = true;
        }
        return;
    };
    if (!force and self.image_gallery.built and std.mem.eql(u8, self.image_gallery.source.path(), path)) return;

    // 경로가 갈렸다 = 다른 세션이다(`/clear` 는 새 파일을 만든다). 옛 파일의 오프셋은 새 파일에서
    // 아무 뜻이 없으므로 통째로 버리고 다시 훑는다.
    self.image_gallery.clear(self.allocator);
    _ = self.image_gallery.source.set(path);
    self.image_gallery.built = true;
    self.metal_dirty = true;

    const io = self.io;
    // `follow_symlinks = false` 는 아카이브 스캐너와 같은 규율이다 — 심링크를 갈아끼워 다른 파일을
    // 읽히는 것을 막는다. 열지 못하면 「이미지 0장」이 아니라 **못 읽은 것**이므로 partial 로 밝힌다.
    const file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch {
        self.image_gallery.partial = true;
        return;
    };
    defer file.close(io);

    const started_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    var scanner: index.StreamScanner = .{};
    defer scanner.deinit(self.allocator);
    var buf: [read_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositional(io, &.{&buf}, offset) catch {
            // 스캔 도중 파일이 지워지거나 잘리는 것은 정상이다(세션이 끝났다). 여기까지 본 것은 살린다.
            self.image_gallery.partial = true;
            break;
        };
        if (n == 0) break;
        offset += n;
        scanner.feed(self.allocator, buf[0..n], &self.image_gallery.hits) catch {
            self.image_gallery.partial = true;
            break;
        };
    }
    const ended_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    self.image_gallery.scanned_bytes = offset;
    self.image_gallery.scan_ns = @intCast(@max(0, ended_ns - started_ns));
    if (scanner.partial) self.image_gallery.partial = true;
}

/// 훅이 소스를 바꿨을 때. **갤러리를 보고 있을 때만 훑는다** — 안 보는 뷰 때문에 1.6 GB 를 읽지 않는다.
/// 보고 있지 않으면 다음에 들어올 때 `refresh` 가 경로 불일치를 보고 알아서 다시 훑는다.
pub fn onSourceChanged(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .image_gallery) return;
    refresh(self, false);
}

/// 도크 본문에 낼 한 줄. 아직 격자가 없으므로 개수와 상태만 말한다.
///
/// **「비었다」와 「못 봤다」와 「에이전트가 없다」를 가른다.** 셋을 한 문구로 접으면 사용자가
/// «이미지가 없는 것» 과 «갤러리가 고장난 것» 을 구분할 수 없다 — SCM 도크의 3-상태 안내와 같은 규율.
pub fn noticeText(self: *const AppSession, buf: []u8) []const u8 {
    if (self.image_gallery.source.isEmpty()) return maru.i18n.t(.image_gallery_no_agent);
    if (self.image_gallery.partial) return maru.i18n.t(.image_gallery_partial);
    const n = self.image_gallery.count();
    if (n == 0) return maru.i18n.t(.image_gallery_empty);
    // 문구가 안 들어가면 개수를 지어내지 않고 「없다」로 물러나지 않는다 — 숫자만이라도 낸다.
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, maru.i18n.t(.image_gallery_count_suffix) }) catch buf[0..0];
}
