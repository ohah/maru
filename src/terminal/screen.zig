//! 화면 storage + 활성 화면 연산 — 스크롤백 ring(`Scrollback`) + grid/cursor/scroll/print/resize/snapshot.
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면/스크롤백 저장 + host-reply를 한 struct에 섞은 구조 위반
//! (docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸 결과다. 여기는 "활성 화면이 어떻게
//! 바뀌는가"(storage + 연산)를 모은다 — 파서 dispatch는 parser.zig, OSC host-reply는 osc.zig. `Scrollback`
//! 구조체는 self-contained라(architecture.md가 가리킨 seam) types만 의존하지만, 나머지 연산은 `*TerminalCore`
//! 를 받는 free 함수다(필드 직접 접근 — Zig는 필드 privacy가 없다; osc.zig·parser.zig와 동형).
//! facade(terminal.zig)·`TerminalCore` struct는 불변 — core.zig가 이 타입을 import해 필드로 쓴다.
//!
//! 현재 보유(core.zig 분할 8~18/N 완료, docs/terminal-core-decomposition.md): tabstops·dirty 추적·G3 charset·
//! 이모지 폭·스크롤백 저장/재-wrap(Phase B) + cursor 이동·erase/insert/delete·scroll/feed·alt screen·print
//! 핫패스(putCell)·resize/reflow·snapshot/viewport 합성(Phase C). 외부가 점-호출하는 pub API(resize·snapshot·
//! renderSnapshot)는 core.zig에 얇은 facade 메서드로 남고 본문만 여기 있다. 후속: 필드를 `Screen` 하위 struct로
//! 접는 architecture.md §"스크롤백은 화면에 귀속" 2단계, accessor(absRow 등)·selection 분리(11b/N~).
//! core↔screen 순환 import은 osc/parser가 이미 검증한 그래프다.

const std = @import("std");
const types = @import("types.zig");
const core = @import("core.zig"); // 활성 화면 연산이 *TerminalCore를 받는다(Scrollback struct는 여전히 types만 의존)
const width = @import("../width.zig"); // EAW 셀 폭(중립 top-level 유틸) — wide 이모지 판정에 쓴다
const grapheme = @import("../grapheme.zig"); // UAX#29 한글 cluster 분절(writeCodepoint가 호출) — 최상위 중립 유틸

// grapheme.zig의 HG1 단위 테스트를 빌드에 끌어오는 수집 앵커. writeCodepoint가 grapheme
// 함수를 호출해도, Zig는 import한 파일의 함수만 analyze하고 그 파일의 `test` 블록은 끌어오지
// 않는다 — 테스트 수집은 이렇게 `_ = @import`을 test 블록에서 참조해야만 된다(그래서 유지).
test {
    _ = grapheme;
}

const TerminalCore = core.TerminalCore;

/// 한 화면(primary/alt)의 스크롤백 ring buffer. `ring`/`wrapped`/`prompt_marks`는 같은 길이의 병렬 배열로
/// `(head+i)%len`로 인덱싱한다(pushScrollback이 함께 할당). 슬롯 cell 버퍼는 lazy 할당이라 빈 슬롯은 null이다.
/// **핵심 불변식**: alt 화면은 `cap == 0`인 빈 인스턴스를 갖는다 — 그래서 `pushScrollback`이 무동작이고
/// 스크롤백 뷰포트가 잠긴다(분기 없이 모델로 떠받친다). 행 push/get/rewrap 로직은 TerminalCore가 이 필드들을
/// 직접 다루고(cross-file 필드 접근), 이 struct는 메모리 수명(free/cap 재구성)만 소유한다.
/// 페이지 내 한 행 디스크립터: arena `cells`의 offset·len + 행 메타. `len`은 hard 행이면 끝-공백을 자른
/// 가변폭(메모리 절감, §11 A2), soft-wrap 행이면 full 폭(내부 공백 보존 — rewrap 정합).
const RowDesc = struct { off: usize, len: usize, wrapped: bool, prompt: types.RowPrompt = .{} };

/// 스크롤백 행을 담는 페이지(§11 A1→A2). 행마다 개별 heap `dupe`하던 ring을 **연속 arena + per-row 디스크립터**로
/// 묶어 (1) 할당 수를 `rows_per_page`분의 1로 낮추고(A1), (2) 가변폭 행을 촘촘히 팩해 메모리를 줄인다(A2 —
/// 끝-공백 trim). "수백만 줄" 목표의 토대(+ 미래 mmap backing 전제, §11.6). 페이지는 `min(desc cap, arena 용량)`
/// 양쪽으로 bound한다 — arena가 cols-무관 고정 예산이라 trim 행이 빽빽이 들어가 페이지 수가 준다(§11.7).
const ScrollbackPage = struct {
    cells: []types.Cell, // 고정 크기 arena(=arena 용량) — 가변폭 행을 offset 순서로 연속 팩. **binding 제약**
    descs: std.ArrayList(RowDesc) = .empty, // 행 디스크립터(arena가 찰 때까지 grow — 짧은 행이면 많이, 넓으면 적게)
    head: usize = 0, // 첫 live desc 인덱스(eviction이 전진). live = descs.items[head..]
    used: usize = 0, // arena 다음 append 오프셋(append-only — evict해도 안 줄고, 페이지가 비면 통째 회수)
    abs_start: usize = 0, // descs[0]의 절대 행 id(단조). desc d ↔ abs = abs_start + d

    fn rowCells(self: *const ScrollbackPage, d: usize) []types.Cell {
        const desc = self.descs.items[d];
        return self.cells[desc.off .. desc.off + desc.len];
    }
};

/// 한 화면의 스크롤백. per-row ring → **page 리스트 + pool**(§11 A1). 공개 동작은 보존한다 — `count`(live 행
/// 수)·row-count `cap`·eviction(가장 오래된 행부터)·`setCap` 반환(버린 행 수)·rewrap 접근자. 논리 행 i(0=가장
/// 오래된)는 `abs = evicted_abs + i`로 매핑하고 페이지를 abs_start 이진탐색한다. pool이 비워진 페이지를 재사용해
/// steady-state 할당을 0으로 유지한다(옛 ring이 슬롯을 memcpy 재활용하던 것과 동률).
pub const Scrollback = struct {
    /// 페이지 cell arena의 고정 크기(cols-무관, §11.7). **arena가 binding 제약**이다 — descs는 arena가 찰 때까지
    /// 자유롭게 grow하므로(짧은 행이면 많이, 넓으면 적게) arena는 항상 거의 꽉 차 underfill 낭비가 없다(고정 desc
    /// cap이 짧은 행에서 arena를 반만 채우던 문제 해결). 고정 크기라 mmap backing(P4)에도 적합. 단일 행이 이보다
    /// 넓으면(초광폭) acquirePage가 그 행에 맞춰 키운다(`@max(arena_cells, 행폭)`). 작을수록 page 수↑(tail 낭비↓).
    const arena_cells: usize = 8192;

    pages: std.ArrayList(*ScrollbackPage) = .empty, // 오래된→최신 순(abs_start 오름차순)
    pool: std.ArrayList(*ScrollbackPage) = .empty, // 비워진 free 페이지(재사용 — steady-state 0 할당)
    /// cell arena 전용 allocator(§11 P4). 기본은 page_allocator(mmap/VirtualAlloc — demand-commit + 콜드 OS swap +
    /// free 즉시 반납)이나, init이 core 일반 allocator로 덮어써(테스트 leak 추적 유지) production만 app_session이
    /// page_allocator로 override한다(setScrollbackArena). cells alloc/realloc/free에만 쓰고, page struct·descs·
    /// pages/pool 리스트는 일반 allocator(아래 함수들의 `allocator` 인자). std라 platform import 없이 boundary-safe.
    arena_alloc: std.mem.Allocator = std.heap.page_allocator,
    count: usize = 0, // live 행 수(공개 동작 보존)
    cap: usize = 0,
    evicted_abs: usize = 0, // 지금까지 evict된 행 수 = 가장 오래된 live 행의 abs
    pushed_abs: usize = 0, // 지금까지 push된 행 수 = 다음 append의 abs
    // 재-wrap 지연 마크. resize는 비싼 재구성을 즉시 하지 않고 이 플래그만 세우고, 과거를 실제로 보는
    // 순간(scrollViewport/renderSnapshot)에 현재 폭으로 1회 수행한다.
    rewrap_pending: bool = false,

    /// 페이지 해제. cells arena는 arena_alloc(P4: page_allocator), page struct·descs는 일반 allocator로 — 두
    /// allocator가 섞이므로 짝을 맞춘다(cells=arena, 나머지=일반).
    fn freePage(self: *Scrollback, allocator: std.mem.Allocator, page: *ScrollbackPage) void {
        self.arena_alloc.free(page.cells);
        page.descs.deinit(allocator);
        allocator.destroy(page);
    }

    /// 비울 때 페이지를 pool로 회수(재사용). pool도 비울 땐 freePage. arena는 고정 크기라 재사용 시 보통 realloc
    /// 불필요(초광폭 행에 맞춰 키운 페이지만 acquirePage가 조정 — §11.7, A1의 width별 realloc보다 단순).
    fn recyclePage(self: *Scrollback, allocator: std.mem.Allocator, page: *ScrollbackPage) void {
        page.head = 0;
        page.used = 0;
        page.descs.clearRetainingCapacity(); // 백킹은 유지(재사용 — 다음 push가 realloc 없이 채움)
        self.pool.append(allocator, page) catch {
            self.freePage(allocator, page); // pool append OOM이면 그냥 해제(누수 방지)
        };
    }

    /// 새(또는 pool 재사용) 페이지를 끝에 붙인다. cell arena는 arena_alloc(P4)에서, page struct·descs는 일반
    /// allocator에서 잡는다. arena를 `@max(arena_cells, min_cells)`로 잡아 적어도 한 행(min_cells=그 행의 폭)은
    /// 들어가게 한다 — 초광폭 단일 행 안전망. pool 페이지 arena가 모자라면 realloc. OOM이면 null.
    fn acquirePage(self: *Scrollback, allocator: std.mem.Allocator, min_cells: usize) ?*ScrollbackPage {
        const need_cells = @max(arena_cells, min_cells);
        if (self.pool.pop()) |page| {
            if (page.cells.len < need_cells) {
                const new_cells = self.arena_alloc.realloc(page.cells, need_cells) catch {
                    self.freePage(allocator, page);
                    return null;
                };
                page.cells = new_cells;
            }
            page.head = 0;
            page.used = 0;
            page.descs.clearRetainingCapacity();
            page.abs_start = self.pushed_abs;
            return page;
        }
        const page = allocator.create(ScrollbackPage) catch return null;
        page.* = .{ .cells = &.{}, .descs = .empty, .abs_start = self.pushed_abs };
        page.cells = self.arena_alloc.alloc(types.Cell, need_cells) catch {
            allocator.destroy(page);
            return null;
        };
        return page;
    }

    /// live 논리 행 i(0=가장 오래된)의 페이지와 페이지 내 행 인덱스. 범위 밖이면 null.
    fn locate(self: *const Scrollback, i: usize) ?struct { page: *ScrollbackPage, row: usize } {
        if (i >= self.count) return null;
        const abs = self.evicted_abs + i;
        var lo: usize = 0;
        var hi: usize = self.pages.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const p = self.pages.items[mid];
            if (abs < p.abs_start) {
                hi = mid;
            } else if (abs >= p.abs_start + p.descs.items.len) {
                lo = mid + 1;
            } else {
                return .{ .page = p, .row = abs - p.abs_start };
            }
        }
        return null;
    }

    pub fn row(self: *const Scrollback, i: usize) ?[]const types.Cell {
        const loc = self.locate(i) orelse return null;
        return loc.page.rowCells(loc.row);
    }

    pub fn rowWrapped(self: *const Scrollback, i: usize) bool {
        const loc = self.locate(i) orelse return false;
        return loc.page.descs.items[loc.row].wrapped;
    }

    /// i번째 스크롤백 행의 "다음 줄로 이어짐"(soft-wrap) 표시를 바꾼다. 화면을 지울 때 마지막
    /// 행의 이어짐을 끊는 데 쓴다 — 지워진 화면으로 이어지는 줄은 없다.
    pub fn setRowWrapped(self: *Scrollback, i: usize, v: bool) void {
        const loc = self.locate(i) orelse return;
        loc.page.descs.items[loc.row].wrapped = v;
    }

    pub fn rowPrompt(self: *const Scrollback, i: usize) types.RowPrompt {
        const loc = self.locate(i) orelse return .{};
        return loc.page.descs.items[loc.row].prompt;
    }

    /// live 행 i의 OSC 133 종료코드를 갱신한다(거터 색용 — setPromptExitAtAbs). 범위 밖이면 무동작.
    pub fn setRowPromptExit(self: *Scrollback, i: usize, exit: i16) void {
        const loc = self.locate(i) orelse return;
        loc.page.descs.items[loc.row].prompt.exit = exit;
    }

    /// 가장 오래된 한 행을 버린다(eviction). 첫 페이지가 다 소진되면 pool로 회수한다. 좌표 보정은 호출자
    /// (pushScrollback)가 한다 — 데이터/좌표 책임 분리(옛 ring과 동일 규율).
    fn evictOldest(self: *Scrollback, allocator: std.mem.Allocator) void {
        if (self.count == 0) return;
        const first = self.pages.items[0];
        first.head += 1; // 첫 페이지의 가장 오래된 live 행을 죽인다(arena 셀은 페이지가 비면 통째 회수)
        self.evicted_abs += 1;
        self.count -= 1;
        if (first.head >= first.descs.items.len) { // 페이지의 모든 행이 evict됨 → pool로 회수
            _ = self.pages.orderedRemove(0);
            self.recyclePage(allocator, first);
        }
    }

    /// storage-level 행 push(append + cap 초과 시 가장 오래된 1행 evict). 성공 여부 반환. 좌표 보정은
    /// 하지 않는다(pushScrollback 래퍼가 eviction 여부로 처리). cap==0이면 무동작.
    pub fn pushRow(self: *Scrollback, allocator: std.mem.Allocator, cells: []const types.Cell, wrapped_flag: bool, mark: types.RowPrompt) bool {
        if (self.cap == 0) return false;
        // hard 행은 끝-default 셀을 잘라 가변폭 저장(메모리 절감, §11 A2). soft-wrap 행은 **쓴 칸까지**만 —
        // 뒤 trailing space가 내용의 일부라 trim하면 rewrap이 논리 줄을 잘못 잇지만(§11.7, 검증됨), 안 쓴 칸은
        // 애초에 내용이 아니라 그대로 저장하면 재-wrap이 wrap 채움을 진짜 공백으로 구워 버린다.
        const stored: []const types.Cell = if (wrapped_flag) cells[0..paintedLen(cells)] else cells[0..trimmedLen(cells)];
        const w = stored.len;
        const page = blk: {
            const last: ?*ScrollbackPage = if (self.pages.items.len > 0) self.pages.items[self.pages.items.len - 1] else null;
            if (last) |p| {
                // arena 여유 + desc 상한(arena_cells) — 보통 arena가 binding이지만, 0폭(빈 행) 스트림은 arena를
                // 안 채워 한 페이지가 영영 안 닫히므로 desc 상한이 그 경우 페이지를 봉인한다(무한 grow 방지).
                if (p.used + w <= p.cells.len and p.descs.items.len < arena_cells) break :blk p;
            }
            const np = self.acquirePage(allocator, w) orelse return false; // arena ≥ max(arena_cells, w)라 이 행은 들어감
            self.pages.append(allocator, np) catch {
                self.recyclePage(allocator, np);
                return false;
            };
            break :blk np;
        };
        const off = page.used;
        // desc를 먼저 추가한다 — OOM이면 arena/카운터를 안 건드리고 깨끗이 실패(상태 일관).
        page.descs.append(allocator, .{ .off = off, .len = w, .wrapped = wrapped_flag, .prompt = mark }) catch return false;
        @memcpy(page.cells[off .. off + w], stored);
        page.used += w;
        self.pushed_abs += 1;
        self.count += 1;
        if (self.count > self.cap) self.evictOldest(allocator);
        return true;
    }

    /// 모든 페이지를 pool로 회수하고 비운다(재사용 토대 유지). clearScrollback이 쓴다.
    pub fn clear(self: *Scrollback, allocator: std.mem.Allocator) void {
        while (self.pages.items.len > 0) {
            const p = self.pages.pop().?;
            self.recyclePage(allocator, p);
        }
        self.count = 0;
        self.evicted_abs = 0;
        self.pushed_abs = 0;
    }

    pub fn deinit(self: *Scrollback, allocator: std.mem.Allocator) void {
        for (self.pages.items) |p| self.freePage(allocator, p);
        self.pages.deinit(allocator);
        for (self.pool.items) |p| self.freePage(allocator, p);
        self.pool.deinit(allocator);
    }

    /// 용량을 바꾼다. 가장 최근 min(count, new_cap)개 행을 보존하고 넘치는 가장 오래된 행을 버린다.
    /// **버려진 행 수를 반환**한다 — 호출자(setMaxScrollback)가 그만큼 abs 좌표(선택·placement·view_offset)를
    /// 당겨야 한다(eviction과 동일 규율). new_cap==0이면 전부 비운다(cap=0은 alt 불변식).
    pub fn setCap(self: *Scrollback, allocator: std.mem.Allocator, new_cap: usize) usize {
        const keep = @min(self.count, new_cap);
        const drop = self.count - keep;
        var n: usize = 0;
        while (n < drop) : (n += 1) self.evictOldest(allocator); // 가장 오래된 drop개 제거(페이지 회수 포함)
        self.cap = new_cap;
        if (new_cap == 0) self.clear(allocator); // 끄기 — 남은 페이지도 pool로(다음 push가 다시 잡음)
        return drop;
    }
};

/// 활성 화면 storage(grid) — cursor·grid를 `TerminalCore`의 평평한 필드가 아니라 한 구조체로 묶는
/// architecture.md §"스크롤백은 화면에 귀속" **2단계**(B-min: grid+scrollback). `Scrollback`(1단계)과 같은
/// self-contained 패턴 — `TerminalCore`를 참조하지 않고 types만 의존하며, core가 `screen: Screen` 필드로
/// 보유한다. 행 연산은 free 함수가 `self.screen.<field>`를 직접 다룬다(struct는 데이터 그릇).
/// alt-screen 전환은 이 struct 단위 swap(`saved_screen`)으로 "alt엔 스크롤백 없음"을 grid까지 타입으로 보장한다
/// (B3). B2에서 `sb: Scrollback`이 여기로 들어오고, cursor·모드 흡수는 후속(B-full).
pub const Screen = struct {
    /// 활성 화면 셀 그리드(길이=size.rows*size.cols). init/resize가 할당, putCell이 채운다.
    cells: []types.Cell = &.{},
    /// soft-wrap 추적. wrapped[r]==true는 "행 r이 autowrap으로 r+1로 이어진다"는 r↔r+1 경계 속성(내용 아님).
    /// hard 줄끝(LF/CR/CUP로 떠난 줄)은 false. autowrap 넘침에만 true, 그 행에 새로 쓰면 false 리셋(redraw 자가교정).
    /// resize reflow가 이 플래그로 논리 줄을 잇는다. 길이는 항상 size.rows.
    wrapped: []bool = &.{},
    /// 행별 OSC 133 semantic 분류(길이=size.rows). wrapped와 같은 병렬 배열이지만 glyph 쓰기(putCell)로
    /// 리셋하지 않는다 — 셸이 프롬프트를 redraw해도 분류는 유지. 상태머신·scroll·clear·OSC 마커만 건드린다.
    prompt_marks: []types.RowPrompt = &.{},
    /// 이 화면의 스크롤백 ring. primary는 cap>0(init이 default_max_scrollback, config가 setMaxScrollback으로 조정),
    /// alt는 cap=0인 빈 인스턴스라 "alt엔 스크롤백 없음"이 타입으로 보장된다(architecture.md §"스크롤백 귀속" 1단계가
    /// grid와 함께 Screen에 귀속 — B2). 기본 cap=0이라 primary cap은 init의 `.screen = .{ … .sb = .{ .cap = … } }`이 세팅.
    sb: Scrollback = .{},
    /// 이 화면의 커서 위치. per-screen — alt 전환 시 grid·sb와 함께 통째 swap된다(Ghostty Screen.cursor 동형, §10.8).
    /// alt 진입은 home(0,0)에서 시작하고, 이탈은 보관된 primary 커서를 복원한다(saved_screen swap).
    cursor: types.Cursor = .{},
    /// 현재 SGR 스타일(pen). printable cell을 쓸 때마다 stamp한다. CSI ... m 이 갱신한다. per-screen(커서와 함께 swap).
    pen: types.Style = .{},
    /// deferred autowrap(DECAWM). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 이 플래그가 선다. 다음 printable이
    /// 먼저 다음 줄 첫 칸으로 넘어간 뒤 그려진다. 명시적 커서 이동(CR/LF/backspace/위치 지정/resize)이 무효화한다.
    /// per-screen(커서 render 상태라 화면과 함께 swap — alt는 false에서 시작, 이탈은 primary 상태 복원).
    pending_wrap: bool = false,
    /// 가장 최근 printable codepoint를 받은 셀(zero-width combining mark가 커서 추정 대신 실제 base glyph에 붙도록).
    /// 커서는 모호하다: base를 정상 전진하지만 마지막 칸(autowrap 없음)에선 base '위'에 머물고 LF 뒤엔 새 행으로
    /// 간다. grapheme run을 끝내는 무엇이든(CR/LF/backspace/resize) 리셋. per-screen(커서와 함께 swap).
    last_print: ?struct { row: u16, col: u16 } = null,
    /// 직전 printable codepoint(REP·grapheme 연속용). per-screen(커서 render 상태와 함께 swap).
    last_printed_cp: u21 = 0,
    /// DECSC/DECRC(ESC 7/8)·CSI s/u·DECSET 1048이 쓰는 저장 커서 슬롯. per-screen — 커서와 함께 swap을 타므로
    /// primary 슬롯은 alt 왕복에도 생존하고, alt 슬롯은 alt 진입마다 fresh다(Ghostty Screen.saved_cursor 동형,
    /// §10.8). alt가 매 진입 재생성되므로 alt 세션 간 슬롯 persist는 의도적으로 사라진다(§10.8.5 B5).
    saved_cursor: core.SavedCursor = .{},
};

// ── G4 동적 탭스톱 ───────────────────────────────────────────────────────────────────────────────
// col별 탭스톱(기본 8칸마다). HTS(ESC H)가 set, TBC(CSI g)가 clear, CBT(CSI Z)가 역방향 이동, HT(0x09)가
// 다음 탭스톱으로 전진. 길이는 cols와 맞춘다(resize가 재구성). 활성 화면 storage라 screen.zig로 모은다(8/N).
// core가 `self.tabstops`/`self.screen.cursor`/`self.size` 필드를 직접 들고, 여기는 그 위의 연산만 제공한다.

/// col이 탭스톱인가. tabstops 배열 안이면 그 값, 밖(OOM 등 길이 불일치)이면 8칸 기본으로 폴백.
fn isTabstop(self: *const TerminalCore, col: u16) bool {
    if (col < self.tabstops.len) return self.tabstops[col];
    return col % 8 == 0;
}

/// 탭스톱을 8칸 기본으로 되돌린다(RIS·TBC 3). 길이 불일치(OOM)면 가능한 만큼만.
pub fn resetTabstops(self: *TerminalCore) void {
    for (self.tabstops, 0..) |*t, c| t.* = (c % 8 == 0);
}

/// resize 후 탭스톱 배열을 새 cols에 맞춘다. 겹치는 열은 보존(HTS/TBC 유지), 새 열은 8칸 기본. OOM이면
/// 기존 배열 유지(isTabstop이 8칸으로 폴백) — best-effort라 resize를 실패시키지 않는다.
pub fn rebuildTabstops(self: *TerminalCore, old_cols: u16) void {
    const new_cols = self.size.cols;
    if (new_cols == self.tabstops.len) return; // 폭 불변이면 그대로
    const buf = self.allocator.alloc(bool, new_cols) catch return;
    for (buf, 0..) |*t, c| {
        t.* = if (c < old_cols and c < self.tabstops.len) self.tabstops[c] else (c % 8 == 0);
    }
    if (self.tabstops.len > 0) self.allocator.free(self.tabstops);
    self.tabstops = buf;
}

pub fn writeTab(self: *TerminalCore) void {
    // 탭은 수평 이동이다 — 다음 탭스톱으로 커서만 옮기고(끝 칸에 멈춤), 지나는 셀의 내용은 건드리지
    // 않는다. xterm.js(InputHandler.tab)·Ghostty(horizontalTab)도 커서만 이동한다 — putCell(' ')로 공백을
    // 찍으면 CR 후 탭 redraw에서 기존 글자가 지워진다. 탭은 wrap하지 않으므로 pending_wrap도 끈다.
    self.screen.pending_wrap = false;
    // TAB은 grapheme run을 끊는다 — CR/LF/BS와 동일하게 last_print를 비워, 탭 뒤의 combining mark(또는 skin-tone·
    // RI 페어링)가 탭 이전 글자에 잘못 붙지 않게 한다. 이동 여부와 무관하게(이미 마지막 칸이어도) 컨트롤 처리 = run 종료다.
    self.screen.last_print = null;
    if (self.size.cols == 0) return;
    const last = self.size.cols - 1;
    if (self.screen.cursor.col >= last) return; // 이미 마지막 칸 — 이동 없음
    const old_cursor = self.screen.cursor;
    var next = self.screen.cursor.col + 1;
    while (next < last and !isTabstop(self, next)) next += 1; // 다음 탭스톱(없으면 마지막 칸)에 멈춤
    self.screen.cursor.col = next;
    // 커서는 draw-time 오버레이라 이동 시 옛/새 칸을 모두 dirty로 마킹해야 한다 — markCursorMoveDirty 계약(\r·BS·CBT 등
    // 이 함수를 거치는 모든 이동)에 TAB도 포함시켜, 옛 칸의 커서 잔상이 안 남게 한다(cursorBackTab과 동일).
    markCursorMoveDirty(self, old_cursor, self.screen.cursor); // 같은 파일(dirty 추적도 screen.zig)
}

/// CBT(CSI Ps Z): 역방향으로 Ps개 탭스톱 이동. 0번째 칸을 넘지 않는다.
pub fn cursorBackTab(self: *TerminalCore, count: u16) void {
    self.screen.pending_wrap = false;
    self.screen.last_print = null; // CBT도 커서 이동 — grapheme run을 끊는다(HT/CR/LF/BS와 동일).
    const old_cursor = self.screen.cursor;
    var remaining = @max(count, 1);
    while (remaining > 0) : (remaining -= 1) {
        if (self.screen.cursor.col == 0) break;
        var prev = self.screen.cursor.col - 1;
        while (prev > 0 and !isTabstop(self, prev)) prev -= 1; // 이전 탭스톱(없으면 col 0)으로
        self.screen.cursor.col = prev;
    }
    markCursorMoveDirty(self, old_cursor, self.screen.cursor);
}

/// TBC(CSI Ps g): Ps=0(기본) 커서 열 탭스톱 제거, Ps=3 전체 제거. 그 외 Ps는 무시.
pub fn clearTabstop(self: *TerminalCore, mode: u16) void {
    switch (mode) {
        0 => if (self.screen.cursor.col < self.tabstops.len) {
            self.tabstops[self.screen.cursor.col] = false;
        },
        3 => @memset(self.tabstops, false),
        else => {},
    }
}

// ── dirty 영역 추적 ──────────────────────────────────────────────────────────────────────────────
// 렌더러가 다시 그릴 행 범위(DirtyRegion). 셀/커서가 바뀐 행을 마킹하고 렌더가 takeDirty로 소비한다(takeDirty/
// clearDirty 소비 API는 core 잔류). 거의 모든 활성 화면 연산이 부르는 헬퍼라 먼저 옮겨 안정화한다(9/N).

pub fn markDirty(self: *TerminalCore, row: u16) void {
    if (self.dirty) |*dirty| {
        if (row < dirty.start_row) dirty.start_row = row;
        if (row > dirty.end_row) dirty.end_row = row;
        return;
    }

    self.dirty = .{ .start_row = row, .end_row = row };
}

pub fn markCursorMoveDirty(self: *TerminalCore, old_cursor: types.Cursor, new_cursor: types.Cursor) void {
    // 명시적 커서 이동(CR/LF/backspace/CUP/CHA/VPA/CUU..CUB 등 이 함수를 거치는 모든 이동)은
    // deferred autowrap을 무효화한다. putCell의 cursor 전진은 이 함수를 거치지 않으므로
    // pending_wrap을 직접 관리한다. 위치가 안 바뀌는 이동(아래 early-return)도 wrap 의도는
    // 취소되므로 early-return 전에 끈다.
    self.screen.pending_wrap = false;
    // Cursor is drawn as an overlay, not as part of the cell glyph bitmap.
    // Moving it still changes pixels: the old cursor cell must be erased
    // and the new cursor cell must be drawn. Keeping that dirty decision in
    // TerminalCore prevents a future renderer from guessing dirty rows by
    // comparing snapshots on its own.
    if (old_cursor.row == new_cursor.row and
        old_cursor.col == new_cursor.col and
        old_cursor.visible == new_cursor.visible)
    {
        return;
    }

    if (old_cursor.visible) markCursorRowDirty(self, old_cursor.row);
    if (new_cursor.visible) markCursorRowDirty(self, new_cursor.row);
}

fn markCursorRowDirty(self: *TerminalCore, row: u16) void {
    if (self.size.rows == 0) return;
    markDirty(self, @min(row, self.size.rows - 1));
}

// ── G3 charset(G-set 지정·변환) ──────────────────────────────────────────────────────────────────
// ESC ( / ESC ) 로 G0/G1에 charset 지정, SI/SO로 GL 호출, print 시 GL charset으로 codepoint 변환한다.
// DEC special graphics(box drawing)가 유일한 비-ascii charset이다. 베이스: VT100 special graphics·xterm.

/// `ESC <intermediate> <final>`로 G-set을 지정한다. intermediate '('=G0·')'=G1, final '0'=dec_special·
/// 'B'=ascii(그 외 charset은 미지원이라 ascii로). G2/G3('*'/'+')는 maru가 호출(SS2/SS3)을 안 해 무시.
pub fn designateCharset(self: *TerminalCore, intermediate: u8, final: u8) void {
    const set: core.TerminalCore.Charset = switch (final) {
        '0' => .dec_special, // DEC special graphics(box drawing)
        else => .ascii, // 'B'(ASCII)·기타 미지원 → ascii
    };
    switch (intermediate) {
        '(' => self.charset_g0 = set, // ESC ( = G0 지정
        ')' => self.charset_g1 = set, // ESC ) = G1 지정
        else => {}, // G2/G3·기타 intermediate는 소비(미지원)
    }
}

/// GL에 호출된 G-set(charset_gl)의 charset으로 codepoint를 변환한다.
pub fn translateCharset(self: *const TerminalCore, codepoint: u21) u21 {
    const set = if (self.charset_gl == 0) self.charset_g0 else self.charset_g1;
    return switch (set) {
        .ascii => codepoint,
        .dec_special => decSpecial(codepoint),
    };
}

/// DEC special graphics: 0x60..0x7e를 box-drawing/기호 Unicode로. 그 밖은 그대로. 베이스: VT100 special
/// graphics(Ghostty `charsets.zig` dec_special 표와 동작 비교 — 코드 표현 미복사).
fn decSpecial(codepoint: u21) u21 {
    return switch (codepoint) {
        0x60 => 0x25C6, // ◆
        0x61 => 0x2592, // ▒
        0x62 => 0x2409, // ␉ HT
        0x63 => 0x240C, // ␌ FF
        0x64 => 0x240D, // ␍ CR
        0x65 => 0x240A, // ␊ LF
        0x66 => 0x00B0, // °
        0x67 => 0x00B1, // ±
        0x68 => 0x2424, // ␤ NL
        0x69 => 0x240B, // ␋ VT
        0x6a => 0x2518, // ┘
        0x6b => 0x2510, // ┐
        0x6c => 0x250C, // ┌
        0x6d => 0x2514, // └
        0x6e => 0x253C, // ┼
        0x6f => 0x23BA, // ⎺
        0x70 => 0x23BB, // ⎻
        0x71 => 0x2500, // ─
        0x72 => 0x23BC, // ⎼
        0x73 => 0x23BD, // ⎽
        0x74 => 0x251C, // ├
        0x75 => 0x2524, // ┤
        0x76 => 0x2534, // ┴
        0x77 => 0x252C, // ┬
        0x78 => 0x2502, // │
        0x79 => 0x2264, // ≤
        0x7a => 0x2265, // ≥
        0x7b => 0x03C0, // π
        0x7c => 0x2260, // ≠
        0x7d => 0x00A3, // £
        0x7e => 0x00B7, // ·
        else => codepoint,
    };
}

// ── 이모지/RI grapheme 폭 헬퍼 ───────────────────────────────────────────────────────────────────
// 스킨톤 modifier 부착·지역표시자(RI) 페어링·wide 이모지 승격 판정. 같은 파일의 print 경로(writeCodepoint·
// putCell·promoteLastToEmojiWidth, 16/N서 이리로 이동)가 호출한다. last_print·cells·index(grid)에 의존한다.

// 범위 판정은 grapheme.zig가 단일 출처다 — chrome의 바이트 walk(`clusterEnd`)와 터미널의 셀 그리드가
// **같은 문자 집합**을 봐야 국기·스킨톤이 두 경로에서 다르게 묶이지 않는다. 이름은 이 파일의 print 경로
// 서술을 유지하려고 그대로 둔다(Fitzpatrick = Emoji_Modifier).
const isSkinToneModifier = grapheme.isEmojiModifier;
const isRegionalIndicator = grapheme.isRegionalIndicator;

/// mode 2027에서 직전 출력 셀의 emoji cluster가 cp로 이어지는가 — 흡수 판정의 단일 출처.
/// 스킨톤(GB9 modifier)·국기(GB12/13 RI 쌍)·ZWJ 시퀀스(GB11)가 서로 다른 UAX#29 규칙이지만 여기서
/// 함께 판정해 흡수+폭승격 경로를 공유한다. base=cluster 시작 글자(cell.codepoint), 흡수 후 호출자가
/// promoteLastToEmojiWidth로 폭을 맞춘다(RI만 1→2). cellWidth 0인 VS16/Extend는 이 함수 이전의 별도
/// 경로가 처리한다. NFD 한글은 게이팅(무조건)이 달라 여기 들어오지 않는다.
fn emojiClusterExtends(self: *const TerminalCore, cell: types.Cell, cp: u21) bool {
    const base = cell.codepoint;
    // 스킨톤 modifier: 그림문자 cluster에 붙는다(modifier는 GB9 Extend지만 폭 2라 cellWidth-0 경로를 안 탐).
    // 단 (1) 동그란 번호(③ ambiguous-wide)는 그림문자가 아니라 제외, (2) **국기(RI base)는 제외** — 완성된
    // 국기 뒤 스킨톤이 cluster에 잘못 병합돼 국기가 깨지면 안 된다(review #15), (3) **폭 2 base에만** — Fitzpatrick은
    // Emoji_Modifier_Base(전부 폭 2 사람·손 이모지)에만 유효하다. 폭 1 그림문자(❤ U+2764 등)에 스킨톤이 붙어
    // promoteLastToEmojiWidth가 1→2로 늘리던 오동작(malformed 입력)을 막는다. lone이 아니어도(ZWJ 가족 안 사람마다
    // 스킨톤) base가 그림문자면 붙는다 — base는 cluster 시작 글자라 가족 전체가 한 셀로 모인다.
    if (isSkinToneModifier(cp)) return cell.width == 2 and grapheme.isExtendedPictographic(base) and !isRegionalIndicator(base) and !width.isWideRenderSymbol(base);
    // 국기: 짝 없는(extra 없는) RI에 둘째 RI만 묶는다(GB12/13 — 3개 이상은 안 이어 다음 국기가 새 셀로).
    if (isRegionalIndicator(cp)) return isRegionalIndicator(base) and cell.grapheme_id == 0;
    // ZWJ: 그림문자 cluster 뒤에 붙는다(GB11 좌변). base가 그림문자면 OK — 사이에 VS16 등 Extend가 끼어도.
    // 단 **RI base는 제외** — 짝 안 찬 국기(반쪽, 폭 1)에 ZWJ가 잘못 흡수되면 안 된다(유효한 emoji 시퀀스에 flag+ZWJ 없음).
    if (cp == 0x200D) return grapheme.isExtendedPictographic(base) and !isRegionalIndicator(base);
    // ZWJ 뒤 그림문자: 합류한다(GB11 우변 — trailing이 방금 붙은 ZWJ).
    if (grapheme.isExtendedPictographic(cp)) return trailingClusterCp(self, cell) == 0x200D;
    return false;
}

/// wide glyph의 오른쪽 continuation 칸(0폭). base의 style/link를 물려받는다 — putCell과
/// promoteLastToEmojiWidth가 같은 표현을 쓰게 한다.
pub fn wideContinuationCell(style: types.Style, link: u32) types.Cell {
    return .{ .style = style, .width = 0, .continuation = true, .link = link };
}

// ── 스크롤백 행 저장·재-wrap ─────────────────────────────────────────────────────────────────────
// Scrollback ring에 행을 push하고, resize 시 새 폭으로 재-wrap하는 storage 로직(Scrollback struct와 짝).
// accessor(scrollbackRow/scrollbackRowWrapped/scrollbackRowPrompt)와 absRow/absRowWrapped는 core 잔류
// (facade·selection 공유 — 후속 accessor PR). isBlankCell·clearTruncatedWideBase는 17/N서 이리로 이동(같은
// 파일 bare 호출; isBlankCell만 core selection이 cross-file로 써 pub). invalidateSelection·shiftCoordsForEviction은
// core 잔류라 self.(pub)로 호출한다.

/// 스크롤백을 비운다(ED 3). 페이지를 pool로 회수해 다음 push가 재할당 없이 다시 쓴다(§11 A1).
/// 뷰포트는 바닥으로 스냅한다(지워진 과거를 보고 있을 수 없으니).
pub fn clearScrollback(self: *TerminalCore) void {
    self.screen.sb.clear(self.allocator);
    self.screen.sb.rewrap_pending = false; // 비운 스크롤백에 지연 재-wrap이 남을 이유 없다(상태 위생)
    self.view_offset = 0;
    self.invalidateSelection(); // 스크롤백을 지우면 abs 좌표가 무효 — 선택 해제(필드 주석의 약속)
}

/// 지연된 스크롤백 재-wrap을 지금 수행한다(있다면). 과거를 보는 경로(scrollViewport/
/// renderSnapshot)가 진입할 때 불러, 뷰가 항상 현재 폭 기준의 행 수/내용을 보게 한다.
pub fn ensureScrollbackRewrapped(self: *TerminalCore) void {
    if (!self.screen.sb.rewrap_pending) return;
    self.screen.sb.rewrap_pending = false;
    rewrapScrollback(self, self.size.cols);
}

/// 스크롤백 전체를 새 폭으로 재-wrap한다(resize 시). 활성 화면 reflow와 같은 규칙을 ring에
/// 적용한다: sb_wrapped로 논리 줄을 복원해 새 폭에 다시 자르고(hard 행 끝 빈칸은 trim, soft
/// 행은 저장 폭 전체가 내용), wide glyph base가 행 끝에 안 들어가면 먼저 줄을 넘긴다. 재-wrap
/// 행 수가 cap을 넘으면 가장 오래된 것부터 버린다. OOM이면 통째로 포기하고 기존 ring을
/// 유지한다(best-effort — 잘못된 절반 상태보다 옛 폭 표시가 낫다).
pub fn rewrapScrollback(self: *TerminalCore, new_cols: u16) void {
    if (self.screen.sb.count == 0 or new_cols == 0) return;
    self.selectionClear(); // 행 좌표가 재배치된다 — 선택은 해제가 안전(다른 터미널도 동일)
    _ = rewrapScrollbackInner(self, new_cols, null) catch null;
}

/// 보던 위치(옛 스크롤백 행 anchor)를 유지하며 재-wrap한다. 과거를 보는 중 resize가 오면
/// 바닥으로 튕기지 않고, 그 행이 재-wrap 후 어느 행이 됐는지로 view_offset을 재계산한다
/// (Ghostty/iTerm2처럼 보던 내용이 그대로 보이게).
pub fn rewrapScrollbackAnchored(self: *TerminalCore, new_cols: u16, anchor_row: usize) void {
    if (self.screen.sb.count == 0 or new_cols == 0) return;
    self.selectionClear(); // rewrapScrollback과 동일 — 좌표 재배치

    const new_anchor = rewrapScrollbackInner(self, new_cols, anchor_row) catch {
        // 재-wrap 실패(OOM): ring이 그대로이므로 offset도 그대로 유효하다.
        return;
    };
    if (new_anchor) |row_index| {
        // 뷰 최상단이 그 행을 다시 가리키게: viewportRow(0) = sb_count - view_offset.
        self.view_offset = @min(self.screen.sb.count - @min(row_index, self.screen.sb.count), self.screen.sb.count);
    } else {
        // 앵커 행이 cap 드랍으로 사라졌다 — 남은 가장 오래된 행(맨 위)으로.
        self.view_offset = self.screen.sb.count;
    }
}

fn rewrapScrollbackInner(self: *TerminalCore, new_cols: u16, anchor_row: ?usize) !?usize {
    // 1차 패스: 출력 행 수만 센다(할당/복사 없음). cap을 넘는 앞쪽(가장 오래된) 행들은 어차피
    // 버려지므로 2차 패스에서 아예 생성하지 않는다 — 좁힘 재-wrap의 alloc 비용을 절반 가까이
    // 줄인다(perf 게이트 scrollback_rewrap이 1회 비용을 잰다).
    var total_out: usize = 0;
    {
        var i: usize = 0;
        while (i < self.screen.sb.count) {
            var j = i;
            while (j + 1 < self.screen.sb.count and self.scrollbackRowWrapped(j)) j += 1;
            total_out += countRewrapRows(self, i, j, new_cols);
            i = j + 1;
        }
    }
    // cap으로 묶는다 — 산출 행이 cap을 넘으면 가장 오래된 초과분은 어차피 버려지므로 생성하지 않는다.
    // (page 저장은 cap/실제 길이 불일치가 구조적으로 불가 — 페이지는 필요 시 자란다. §11 A1)
    const keep = @min(total_out, self.screen.sb.cap);
    const skip = total_out - keep; // 생성 없이 건너뛸 산출 행 수(가장 오래된 쪽)

    var rows: std.ArrayList([]types.Cell) = .empty;
    var wraps: std.ArrayList(bool) = .empty;
    var pmarks: std.ArrayList(types.RowPrompt) = .empty; // 산출 행별 OSC 133 태그(rows와 병렬)
    var consumed: usize = 0; // commit에서 rebuilt로 복사·해제 완료한 rows 개수(나머지만 defer가 해제)
    // commit이 각 행을 rebuilt로 복사하며 즉시 해제하므로(peak ~2x 유지), 이 defer는 아직 안 옮긴 행만
    // 해제한다 — build 실패 시 전부, commit 중 OOM 시 미복사분.
    defer {
        for (rows.items[consumed..]) |r| self.allocator.free(r);
        rows.deinit(self.allocator);
        wraps.deinit(self.allocator);
        pmarks.deinit(self.allocator);
    }
    try rows.ensureTotalCapacity(self.allocator, keep);
    try wraps.ensureTotalCapacity(self.allocator, keep);
    try pmarks.ensureTotalCapacity(self.allocator, keep);

    var emitted: usize = 0; // 전체 산출 행 인덱스(skip 비교용)
    var anchor_out: ?usize = null; // anchor_row(옛 행)가 떨어진 새 행 인덱스(skip 반영 전)
    var i: usize = 0;
    while (i < self.screen.sb.count) {
        // 논리 줄 [i, j]: 연속된 soft-wrap 행 + 마지막 행.
        var j = i;
        while (j + 1 < self.screen.sb.count and self.scrollbackRowWrapped(j)) j += 1;
        // 줄의 마지막 산출 행이 물려받을 wrap 플래그: 논리 줄이 스크롤백의 끝을 넘어 활성
        // 화면으로 이어지면(마지막 행의 sb_wrapped=true) 그 경계 연속성을 보존한다.
        const tail_wrap = self.scrollbackRowWrapped(j);
        // 논리 줄은 단일 OSC 133 분류다(lineFeed가 같은 영역을 전파). 분류(kind)는 이 줄의 모든
        // 산출 행이 물려받아 재-wrap 후에도 정렬을 유지한다. 단 종료코드(exit)는 leader 한 행에만
        // 스탬프되므로 줄의 '첫' 산출 행에만 둔다 — 안 그러면 거터 바가 여러 개로 보인다(코드리뷰 #1).
        const line_tag = self.scrollbackRowPrompt(i);
        var line_exit: ?i16 = line_tag.exit;

        var cur: ?[]types.Cell = null;
        errdefer if (cur) |c| self.allocator.free(c);
        var oc: u16 = 0;

        var r = i;
        while (r <= j) : (r += 1) {
            // 앵커 옛 행이 시작되는 시점의 산출 행이 "보던 줄"의 새 위치다(셀 단위 정밀도까지는
            // 불필요 — 행 단위면 보던 내용이 화면 안에 유지된다).
            if (anchor_row != null and r == anchor_row.?) anchor_out = emitted;
            const src = self.scrollbackRow(r) orelse continue;
            // soft 행은 쓴 칸까지, hard(마지막) 행은 뒤 빈칸 trim. pushScrollback이 이미 soft 행을 쓴 칸까지
            // 저장하므로 보통 `src.len`과 같지만, 옛 바이너리가 인코딩한 핸드오프 행은 wrap 채움을 달고 올 수
            // 있어(그때는 soft 행을 full 폭으로 저장했다) 여기서도 같은 기준으로 읽는다.
            const contrib: usize = if (r < j) paintedLen(src) else trimmedLen(src);
            var c: usize = 0;
            while (c < contrib) : (c += 1) {
                const cell = src[c];
                const needs: u16 = if (cell.width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    if (cur) |full| {
                        clearTruncatedWideBase(full); // 마지막 칸의 잘린 wide base 정리(new_cols==1 등)
                        rows.appendAssumeCapacity(full);
                        wraps.appendAssumeCapacity(true);
                        pmarks.appendAssumeCapacity(.{ .kind = line_tag.kind, .exit = line_exit });
                        line_exit = null; // exit는 줄의 첫 산출 행에만
                        cur = null;
                    }
                    emitted += 1;
                    oc = 0;
                }
                // skip 범위를 지나서야 행 버퍼를 만든다(버려질 행은 셀 스캔만 하고 할당 생략).
                if (cur == null and emitted >= skip) {
                    cur = try self.allocator.alloc(types.Cell, new_cols);
                    @memset(cur.?, .{});
                }
                if (cur) |dst| dst[oc] = cell;
                oc += 1;
            }
        }
        // 논리 줄의 마지막 행을 닫는다(내용이 전혀 없던 빈 줄도 한 행으로 보존).
        if (cur == null and emitted >= skip) {
            cur = try self.allocator.alloc(types.Cell, new_cols);
            @memset(cur.?, .{});
        }
        if (cur) |last| {
            clearTruncatedWideBase(last);
            rows.appendAssumeCapacity(last);
            wraps.appendAssumeCapacity(tail_wrap);
            pmarks.appendAssumeCapacity(.{ .kind = line_tag.kind, .exit = line_exit });
            line_exit = null;
            cur = null;
        }
        emitted += 1;
        i = j + 1;
    }

    // 옛 storage를 건드리기 전에 새 페이지를 임시 Scrollback에 쌓는다 — commit 중 OOM이면 옛 내용을 그대로
    // 두고 error를 반환해 호출자가 옛 폭 표시를 유지하게 한다(옛 ring의 "OOM이면 통째 포기" 계약 — clear-먼저는
    // commit OOM 시 스크롤백을 조용히 잃었다, A1 리뷰). 한 행을 rebuilt로 복사하면 그 임시 버퍼를 즉시 해제해
    // peak 메모리를 옛 방식과 같은 ~2x로 유지한다(수백만 줄 목표상 3x 금지). keep(≤cap)개라 push 중 eviction 없음.
    var rebuilt: Scrollback = .{ .cap = self.screen.sb.cap, .arena_alloc = self.screen.sb.arena_alloc }; // 같은 arena allocator(§11 P4)
    errdefer rebuilt.deinit(self.allocator); // commit OOM 시 임시만 해제(옛 sb는 그대로)
    for (rows.items, 0..) |row_cells, k| {
        if (!rebuilt.pushRow(self.allocator, row_cells, wraps.items[k], pmarks.items[k])) return error.OutOfMemory;
        self.allocator.free(row_cells);
        consumed = k + 1; // defer가 이 행을 다시 해제하지 않게
    }
    self.screen.sb.deinit(self.allocator); // 전부 성공 — 옛 storage 해제하고 교체
    self.screen.sb = rebuilt;

    if (anchor_out) |a| {
        if (a >= skip) return a - skip; // cap 드랍을 반영한 새 행 인덱스
        return null; // 보던 행이 드랍됨
    }
    return null;
}

/// 논리 줄 [first, last]가 new_cols로 재-wrap될 때의 산출 행 수(할당/복사 없는 시뮬레이션).
fn countRewrapRows(self: *const TerminalCore, first: usize, last: usize, new_cols: u16) usize {
    var count: usize = 0;
    var oc: u16 = 0;
    var r = first;
    while (r <= last) : (r += 1) {
        const src = self.scrollbackRow(r) orelse continue;
        const contrib: usize = if (r < last) paintedLen(src) else trimmedLen(src); // 위 rewrap과 같은 기준
        var c: usize = 0;
        while (c < contrib) : (c += 1) {
            const needs: u16 = if (src[c].width == 2) 2 else 1;
            if (oc + needs > new_cols) {
                count += 1;
                oc = 0;
            }
            oc += 1;
        }
    }
    return count + 1; // 마지막(열린) 행
}

/// 행 슬라이스의 내용 길이(뒤 빈칸 trim). 활성 화면의 trimmedRowLen과 같은 기준을 스크롤백
/// 행(저장 폭이 현재와 다를 수 있음)에 적용한다. selection(core 잔류)도 호출하므로 pub.
pub fn trimmedLen(row: []const types.Cell) usize {
    return types.textTrimmedLen(row);
}

/// soft-wrap 행이 **텍스트**에 기여하는 길이 — 뒤에 붙은 "글자 없는 칸"만 제외한다(쓴 공백은 내용).
/// 논리 줄을 이을 때 이 길이를 넘겨 읽으면 wrap 채움이 없던 공백으로 들어간다.
pub fn textLen(row: []const types.Cell) usize {
    return types.textLen(row);
}

/// soft-wrap 행이 **화면**에 기여하는 길이 — 칠해진(배경 있는) 칸까지 남긴다. 저장·reflow가 쓴다.
pub fn paintedLen(row: []const types.Cell) usize {
    return types.paintedLen(row);
}

/// 행을 스크롤백에 보관한다(§11 A1 page 저장에 위임). OOM 등으로 실제 보관에 실패하면 false — 호출자
/// (scroll-lock)는 보관된 경우에만 view_offset을 보정해야 보던 위치가 어긋나지 않는다. 가득 찬 상태에서
/// push하면 가장 오래된 행이 밀려나(eviction) 절대 행 좌표가 한 칸 당겨지므로, 그때만 선택·placement
/// anchor를 보정한다(밀려난 행에 걸리면 선택 해제·placement 제거). count는 cap로 불변이라 view_offset
/// 클램프는 불필요. 데이터(page 저장)와 좌표 보정의 책임을 분리한다(pushRow는 좌표를 모른다).
pub fn pushScrollback(self: *TerminalCore, row_cells: []const types.Cell, wrapped_flag: bool, mark: types.RowPrompt) bool {
    const was_full = self.screen.sb.cap > 0 and self.screen.sb.count == self.screen.sb.cap;
    if (!self.screen.sb.pushRow(self.allocator, row_cells, wrapped_flag, mark)) return false;
    if (was_full) self.shiftCoordsForEviction(1);
    return true;
}

/// 절대 행 -> 셀(스크롤백 또는 활성 화면). 범위 밖이면 null. abs=[0, sb.count)는 스크롤백,
/// [sb.count, sb.count+rows)는 활성 grid. 선택/검색/URL이 뷰포트 스크롤과 무관한 절대 좌표로
/// 행을 읽을 때 쓴다(selection.zig가 cross-file 호출 — pub). `self.scrollbackRow`(core 잔류 sb accessor)에 위임.
pub fn absRow(self: *const TerminalCore, abs: usize) ?[]const types.Cell {
    if (abs < self.screen.sb.count) return self.scrollbackRow(abs);
    const active = abs - self.screen.sb.count;
    if (active >= self.size.rows) return null;
    const start = @as(usize, @intCast(active)) * self.size.cols;
    return self.screen.cells[start .. start + self.size.cols];
}

/// 절대 행이 soft-wrap continuation인가(다음 행과 논리 줄로 이어지는가). 단어/선택 확장이 행 경계를
/// 넘을지 판단할 때 쓴다. absRow와 같은 좌표계.
pub fn absRowWrapped(self: *const TerminalCore, abs: usize) bool {
    if (abs < self.screen.sb.count) return self.scrollbackRowWrapped(abs);
    const active = abs - self.screen.sb.count;
    if (active >= self.size.rows) return false;
    return self.screen.wrapped[active];
}

/// 뷰포트 행 -> 절대 행. 뷰포트 첫 행은 sb.count - view_offset(과거를 볼수록 view_offset이 큼). absRow와
/// 같은 좌표 family(selection.zig가 cross-file 호출 — pub). 스크롤백/뷰포트 상태만 읽고 선택 상태와 무관.
pub fn absRowFromViewport(self: *const TerminalCore, viewport_row: u16) usize {
    return self.screen.sb.count - @min(self.view_offset, self.screen.sb.count) + viewport_row;
}

// ── 커서 이동/위치 ───────────────────────────────────────────────────────────────────────────────
// CUP/HVP/VPA·CUU..CUB·CHA·DECSCUSR·DECOM 등 커서를 옮기거나 모양을 바꾸는 연산. 명시적 이동은 모두
// markCursorMoveDirty로 옛/새 칸을 dirty 마킹하고 deferred wrap(pending_wrap)·grapheme run(last_print)을 끊는다.
// dispatchCsi(core 잔류, parser 후속)가 CSI 파라미터를 풀어 위임한다.

/// DECSCUSR(CSI Ps SP q): 커서 모양/깜빡임. 0=터미널 기본(config `cursor.shape`)으로 복귀, 1=깜빡 block,
/// 2=고정 block, 3=깜빡 underline, 4=고정 underline, 5=깜빡 bar, 6=고정 bar. 모르는 값은 무시한다.
/// vim이 모드 전환마다 보낸다.
///
/// 0과 1을 **가른다**(옛날엔 둘 다 하드코딩 block). VT520/xterm에서 0은 "terminal default", 1은 "blinking block"로
/// 정의가 다르고, 0은 프로그램이 자기 override를 거둬들이는 유일한 수단이다 — 여기서 갈라야 사용자 config가 다시
/// 보인다(Ghostty `CSI 0 q` → `.default` 동형). 1..6은 override로 표시해 config reload가 화면을 안 덮게 한다.
pub fn setCursorStyle(self: *TerminalCore, param: u16) void {
    switch (param) {
        0 => {
            self.cursor_shape = self.default_cursor_shape; // 터미널 기본 = 사용자 config
            self.cursor_blink = true; // 기본은 깜빡임(config cursor.blink=false는 app 렌더 게이트가 덮는다)
            self.cursor_shape_overridden = false; // override 해제 — 이후 config reload가 라이브로 반영된다
        },
        1 => {
            self.cursor_shape = .block;
            self.cursor_blink = true;
        },
        2 => {
            self.cursor_shape = .block;
            self.cursor_blink = false;
        },
        3 => {
            self.cursor_shape = .underline;
            self.cursor_blink = true;
        },
        4 => {
            self.cursor_shape = .underline;
            self.cursor_blink = false;
        },
        5 => {
            self.cursor_shape = .bar;
            self.cursor_blink = true;
        },
        6 => {
            self.cursor_shape = .bar;
            self.cursor_blink = false;
        },
        else => return,
    }
    if (param != 0) self.cursor_shape_overridden = true; // 앱이 명시 — config reload가 이 커서를 안 덮는다
    markDirty(self, self.screen.cursor.row); // 모양이 바뀐 커서 칸을 다시 그린다
}

/// config `cursor.shape` 기본값을 주입한다(app createTerm chokepoint · config reload · 원격 RuntimeConfig 적용).
/// 앱이 DECSCUSR로 모양을 명시 중이면(`cursor_shape_overridden`) 기본값만 갱신하고 라이브 커서는 안 건드린다 —
/// 설정을 바꿨다고 vim insert-mode의 bar가 block으로 튀지 않게(Ghostty가 `default_cursor`일 때만 재적용하는 것과 동형).
/// 명시가 없으면 즉시 반영해 reload가 화면에서 바로 보인다.
pub fn setDefaultCursorShape(self: *TerminalCore, shape: types.CursorShape) void {
    self.default_cursor_shape = shape;
    if (self.cursor_shape_overridden) return;
    if (self.cursor_shape == shape) return; // 값 불변 — dirty 마킹 없이 idle 유지
    self.cursor_shape = shape;
    markDirty(self, self.screen.cursor.row);
}

pub fn cursorPosition(self: *TerminalCore) void {
    if (self.size.rows == 0 or self.size.cols == 0) return;
    const old = self.screen.cursor;
    const row = self.csiParam(0, 1); // CSI 파라미터 접근(parser helper, core 잔류 — pub)
    const col = self.csiParam(1, 1);
    self.screen.cursor.row = resolveRow(self, row); // DECOM이면 scroll region 상단 기준 + region 안 clamp
    self.screen.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

/// DECOM(DECSET/DECRST ?6) 적용. origin mode를 토글하고 커서를 origin home으로 옮긴다(xterm 동작 —
/// DECOM 변경 시 커서가 home으로). origin이면 scroll region 좌상단, 아니면 화면 좌상단.
pub fn setOriginMode(self: *TerminalCore, on: bool) void {
    self.origin_mode = on;
    const old = self.screen.cursor;
    self.screen.cursor = .{ .row = if (on) self.scroll_top else 0, .col = 0 };
    self.screen.pending_wrap = false;
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

/// CUP/HVP/VPA의 1-based row 파라미터를 0-based 셀 행으로 변환한다. DECOM(origin mode)이면 scroll
/// region 상단 기준(1=region top)으로 옮기고 region 안에 clamp, 아니면 화면 절대로 clamp. 베이스:
/// xterm/Ghostty 공통 — CUP·HVP·VPA가 모두 같은 origin 변환을 거친다(Ghostty는 setCursorPos 단일 경로).
fn resolveRow(self: *const TerminalCore, row_param: u16) u16 {
    if (self.origin_mode) {
        return @intCast(@min(@as(u32, self.scroll_top) + @as(u32, row_param) - 1, @as(u32, self.scroll_bottom)));
    }
    return @intCast(@min(@as(u32, row_param) - 1, @as(u32, self.size.rows) - 1));
}

pub fn cursorVertical(self: *TerminalCore, amount: u16, up: bool) void {
    if (self.size.rows == 0) return;
    const old = self.screen.cursor;
    if (up) {
        self.screen.cursor.row -|= amount;
    } else {
        const max_row = self.size.rows - 1;
        self.screen.cursor.row = @intCast(@min(@as(u32, self.screen.cursor.row) + amount, max_row));
    }
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

pub fn cursorHorizontal(self: *TerminalCore, amount: u16, right: bool) void {
    if (self.size.cols == 0) return;
    const old = self.screen.cursor;
    if (right) {
        const max_col = self.size.cols - 1;
        self.screen.cursor.col = @intCast(@min(@as(u32, self.screen.cursor.col) + amount, max_col));
    } else {
        self.screen.cursor.col -|= amount;
    }
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

pub fn cursorToColumn(self: *TerminalCore, col: u16) void {
    if (self.size.cols == 0) return;
    const old = self.screen.cursor;
    self.screen.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

pub fn cursorToRow(self: *TerminalCore, row: u16) void {
    if (self.size.rows == 0) return;
    const old = self.screen.cursor;
    // VPA(CSI Ps d)도 CUP/HVP처럼 DECOM origin 영향을 받는다(xterm/Ghostty 공통 — setCursorPos 단일 경로).
    self.screen.cursor.row = resolveRow(self, row);
    markCursorMoveDirty(self, old, self.screen.cursor);
    self.screen.last_print = null;
}

/// 저장 커서를 새 grid 안으로 clamp한다. col이 잘려 더는 마지막 칸이 아니면 pending_wrap도 끈다
/// (deferred wrap은 "마지막 칸에 머무는 중"일 때만 유효한 상태다). DECSC/DECRC·1048/1049 저장 슬롯에 쓴다.
/// resize(같은 파일, 17/N)만 호출하므로 private(15/N의 cross-file pub은 resize 이동으로 불필요해짐).
fn clampSavedCursor(slot: *core.SavedCursor, size: types.Size) void {
    const clamped_col = @min(slot.cursor.col, size.cols - 1);
    if (clamped_col != slot.cursor.col) slot.pending_wrap = false;
    slot.cursor.row = @min(slot.cursor.row, size.rows - 1);
    slot.cursor.col = clamped_col;
}

/// 한 화면(Screen)의 커서 상태를 새 크기에 맞춘다 — 활성 커서·DECSC 슬롯을 clamp하고 deferred-wrap·combining
/// 앵커를 무효화한다(resize는 reflow라 모호해진 상태를 버린다). 커서가 화면 귀속(per-screen, §10.8)이라 alt 중
/// resize는 활성 화면과 보관된 primary(saved_screen)에 똑같이 적용해야 swap 복원 시 OOB가 살아나지 않는다 —
/// swap 단위를 한 곳에서 처리해 두 호출이 어긋날 여지를 없앤다.
fn clampScreenCursorForResize(s: *Screen, size: types.Size) void {
    s.cursor.row = @min(s.cursor.row, size.rows - 1);
    s.cursor.col = @min(s.cursor.col, size.cols - 1);
    clampSavedCursor(&s.saved_cursor, size);
    s.pending_wrap = false;
    s.last_print = null;
}

// ── erase / insert / delete (행 내 셀 편집) ─────────────────────────────────────────────────────
// EL(K)·ECH(X)·ICH(@)·DCH(P)·ED(J). 모두 현재 pen 배경(BCE)으로 채우고, 경계에 걸친 wide glyph 반쪽을
// repairWideGlyphEdges로 정리하며, deferred autowrap(pending_wrap)·grapheme run(last_print)을 끊는다.
// dispatchCsi(core 잔류, parser 후속)와 putCell(insert_mode)이 위임한다.

/// erase로 [start, end) 범위를 비울 때, 경계에 걸친 wide glyph(width=2)의 반쪽을 정리한다.
/// clearCellForWrite가 쓰기 시 하던 짝 정리를 erase에도 적용해, 짝 잃은 base나 orphan
/// continuation이 남아 half-glyph로 그려지는 것을 막는다.
fn repairWideGlyphEdges(self: *TerminalCore, row: u16, start: u16, end: u16) void {
    const blank: types.Cell = .{ .style = self.screen.pen };
    // 왼쪽 경계: start-1이 width=2 base면 그 continuation(start)이 지워졌으므로 base도 비운다.
    if (start > 0 and self.screen.cells[self.index(row, start - 1)].width == 2) {
        self.screen.cells[self.index(row, start - 1)] = blank;
    }
    // 오른쪽 경계: end가 continuation이면 그 base(end-1)가 지워졌으므로 continuation도 비운다.
    if (end < self.size.cols and self.screen.cells[self.index(row, end)].continuation) {
        self.screen.cells[self.index(row, end)] = blank;
    }
}

pub fn eraseInLine(self: *TerminalCore, mode: u16) void {
    const row = self.screen.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start: u16 = switch (mode) {
        1, 2 => 0,
        else => self.screen.cursor.col,
    };
    const end: u16 = switch (mode) {
        1 => @min(self.screen.cursor.col + 1, self.size.cols),
        else => self.size.cols,
    };
    var col = start;
    while (col < end) : (col += 1) {
        // erase는 현재 pen의 배경색으로 채워야 하므로 blank cell에 style만 남긴다.
        self.screen.cells[self.index(row, col)] = .{ .style = self.screen.pen };
    }
    repairWideGlyphEdges(self, row, start, end);
    // 행의 오른쪽 끝을 지우면(mode 0=커서~끝, mode 2=전체) soft-wrap 연속성이 끊긴다. mode 1
    // (시작~커서)은 오른쪽 끝이 멀쩡해 줄이 여전히 다음 행으로 이어질 수 있으므로 wrapped를 끄지
    // 않는다 — 안 그러면 reflow가 한 논리 줄을 둘로 쪼갠다.
    if (mode != 1) self.screen.wrapped[row] = false;
    // **0행의 0열이 지워지면 스크롤백에서 이어지던 줄도 끊는다**(ED 와 같은 이유). mode 0 은
    // 커서가 0열일 때만 0열을 지운다.
    if (row == 0 and (mode != 0 or self.screen.cursor.col == 0)) breakScrollbackWrapLink(self);
    markDirty(self, row);
    // 모든 EL 모드는 deferred autowrap을 무효화한다(xterm/Ghostty 동작). 안 끄면 마지막 칸
    // 출력(pending) 후 EL+글자 시퀀스가 한 줄 일찍 wrap돼 상대 커서 이동이 어긋난다.
    self.screen.pending_wrap = false;
    // 다른 cursor/erase op과 같이 grapheme run을 끝낸다. 안 하면 CSI K 뒤 combining mark가
    // 방금 지운 셀에 붙는다.
    self.screen.last_print = null;
}

/// ECH(CSI Ps X): 커서 위치부터 Ps개(기본 1) cell을 현재 pen 배경의 blank로 지운다. EL과 달리 줄 끝까지가
/// 아니라 N개만, DCH(CSI P)와 달리 뒤 cell을 당기지도 않는다(제자리 blank). **커서는 안 움직인다**.
/// 베이스: xterm `ECH`("Erase Ps Character(s)") — nvim이 모드 라벨(`-- INSERT --`)을 이 시퀀스로 지운다(EL 아님).
pub fn eraseCharacters(self: *TerminalCore, count: u16) void {
    const row = self.screen.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.screen.cursor.col;
    const end: u16 = @min(start +| @max(count, 1), self.size.cols);
    var col = start;
    while (col < end) : (col += 1) {
        // erase는 현재 pen의 배경색으로 채운다(blank cell + style만) — eraseInLine과 동일 규칙(bce).
        self.screen.cells[self.index(row, col)] = .{ .style = self.screen.pen };
    }
    repairWideGlyphEdges(self, row, start, end);
    markDirty(self, row);
    // ECH는 부분 erase라 soft-wrap flag를 끄지 않는다(EL mode 1과 같은 결 — 줄 끝이 남아 다음 행으로
    // 이어질 수 있다). deferred autowrap만 무효화(다른 erase op과 동일).
    self.screen.pending_wrap = false;
    self.screen.last_print = null;
}

/// ICH (CSI Ps @): 커서 위치에 Ps개(기본 1) 빈 칸을 삽입한다. 커서부터 줄 끝까지의 셀을 오른쪽으로
/// 밀고, 줄 끝을 넘는 셀은 버린다. 빈 칸은 현재 pen 배경(BCE — eraseCharacters와 동일 규칙). 커서
/// 위치는 불변. 베이스: ECMA-48 ICH / xterm ctlseqs `CSI Ps @`. 좌우 margin(DECSLRM) 미구현이라
/// 줄 전체에서 작동한다.
pub fn insertChars(self: *TerminalCore, count: u16) void {
    const row = self.screen.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.screen.cursor.col;
    if (start >= self.size.cols) return;
    const cols = self.size.cols;
    const n: u16 = @min(@max(count, 1), cols - start);
    const blank: types.Cell = .{ .style = self.screen.pen };
    // 커서부터 오른쪽 셀을 n칸 오른쪽으로(역순 복사라 영역이 겹쳐도 안전). 줄 끝을 넘는 셀은 버린다.
    var col: u16 = cols;
    while (col > start + n) {
        col -= 1;
        self.screen.cells[self.index(row, col)] = self.screen.cells[self.index(row, col - n)];
    }
    // 삽입된 빈 칸.
    col = start;
    while (col < start + n) : (col += 1) self.screen.cells[self.index(row, col)] = blank;
    // 왼쪽 경계에서 쪼개진 wide(start-1 base의 continuation이 밀려남)를 복구하고, 줄 끝으로 밀려
    // continuation이 줄 밖으로 나간 wide base를 비운다.
    repairWideGlyphEdges(self, row, start, cols);
    if (self.screen.cells[self.index(row, cols - 1)].width == 2) self.screen.cells[self.index(row, cols - 1)] = blank;
    markDirty(self, row);
    self.screen.pending_wrap = false;
    self.screen.last_print = null;
}

/// DCH (CSI Ps P): 커서 위치에서 Ps개(기본 1) 문자를 삭제한다. 커서 오른쪽 셀을 왼쪽으로 당기고,
/// 줄 끝의 빈 자리는 현재 pen 배경(BCE). 커서 위치는 불변. 베이스: ECMA-48 DCH / xterm `CSI Ps P`.
pub fn deleteChars(self: *TerminalCore, count: u16) void {
    const row = self.screen.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.screen.cursor.col;
    if (start >= self.size.cols) return;
    const cols = self.size.cols;
    const n: u16 = @min(@max(count, 1), cols - start);
    const blank: types.Cell = .{ .style = self.screen.pen };
    // 커서 오른쪽 셀을 n칸 왼쪽으로 당긴다.
    var col = start;
    while (col + n < cols) : (col += 1) {
        self.screen.cells[self.index(row, col)] = self.screen.cells[self.index(row, col + n)];
    }
    // 줄 끝 n칸은 빈 칸.
    while (col < cols) : (col += 1) self.screen.cells[self.index(row, col)] = blank;
    // 왼쪽 경계에서 쪼개진 wide(start-1 base)를 복구하고, 당겨와서 base를 잃은 continuation을 비운다.
    repairWideGlyphEdges(self, row, start, cols);
    if (self.screen.cells[self.index(row, start)].continuation) self.screen.cells[self.index(row, start)] = blank;
    markDirty(self, row);
    self.screen.pending_wrap = false;
    self.screen.last_print = null;
}

/// **지워진 화면으로 이어지는 줄은 없다.** 활성 화면의 wrap 표시만 지우면 스크롤백 마지막
/// 행이 계속 "다음 줄로 이어짐" 을 주장하고, 지운 뒤 새로 쓴 첫 줄이 그 줄의 연속으로 취급된다
/// — 그 줄에서 단어를 잡으면 **스크롤백의 wrap 뭉치까지 통째로 선택**된다(모바일 복사가 W
/// 수천 자를 담아 오는 것으로 드러났다). 0행이 0열부터 지워지는 모든 ED 에서 끊는다.
fn breakScrollbackWrapLink(self: *TerminalCore) void {
    if (self.screen.sb.count > 0) self.screen.sb.setRowWrapped(self.screen.sb.count - 1, false);
}

pub fn eraseInDisplay(self: *TerminalCore, mode: u16) void {
    if (self.size.rows == 0 or self.size.cols == 0) return;
    // 모든 ED 모드는 deferred autowrap을 무효화한다(EL과 동일한 이유, xterm/Ghostty 동작).
    self.screen.pending_wrap = false;
    const blank: types.Cell = .{ .style = self.screen.pen };
    switch (mode) {
        // 2/3: 화면 전체. 3(xterm E3)은 저장된 줄(스크롤백)까지 지운다 — `clear`가 보내는
        // \e[3J의 핵심 의미로, 비밀 출력 후 history를 비우는 용도다.
        2, 3 => {
            @memset(self.screen.cells, blank);
            @memset(self.screen.wrapped, false);
            breakScrollbackWrapLink(self);
            @memset(self.screen.prompt_marks, .{}); // 전체 clear는 OSC 133 분류도 지운다
            self.semantic_state = .unknown; // 진행 중 영역도 끝낸다(셸이 곧 프롬프트를 재마킹)
            if (mode == 3) clearScrollback(self);
            self.dirty = core.fullDirty(self.size);
        },
        // 1: 화면 시작 ~ 커서까지.
        1 => {
            const cursor_index = self.index(self.screen.cursor.row, self.screen.cursor.col);
            var i: usize = 0;
            while (i <= cursor_index and i < self.screen.cells.len) : (i += 1) self.screen.cells[i] = blank;
            for (0..@min(@as(usize, self.screen.cursor.row) + 1, self.screen.wrapped.len)) |r| self.screen.wrapped[r] = false;
            breakScrollbackWrapLink(self); // 0행을 0열부터 지운다 — 이어지던 줄이 없어진다
            repairWideGlyphEdges(self, self.screen.cursor.row, 0, @min(self.screen.cursor.col + 1, self.size.cols));
            // dirty를 덮어쓰지 않고 markDirty로 병합한다 — 같은 write()에서 앞서 dirty된 행
            // (예: 방금 출력한 아래쪽 행)을 잃어 렌더가 stale glyph를 남기지 않게 한다.
            markDirty(self, 0);
            markDirty(self, self.screen.cursor.row);
        },
        // 0(기본): 커서 ~ 화면 끝까지.
        else => {
            const cursor_index = self.index(self.screen.cursor.row, self.screen.cursor.col);
            var i: usize = cursor_index;
            while (i < self.screen.cells.len) : (i += 1) self.screen.cells[i] = blank;
            for (self.screen.cursor.row..self.size.rows) |r| self.screen.wrapped[r] = false;
            // 커서가 홈이면 0행이 0열부터 지워진다 — `ESC[H ESC[J` 는 가장 흔한 지우기 관용구다.
            if (self.screen.cursor.row == 0 and self.screen.cursor.col == 0) breakScrollbackWrapLink(self);
            repairWideGlyphEdges(self, self.screen.cursor.row, self.screen.cursor.col, self.size.cols);
            markDirty(self, self.screen.cursor.row);
            markDirty(self, self.size.rows - 1);
        },
    }
    self.screen.last_print = null;
}

// ── scroll / line feed (행 스크롤·줄 이동) ──────────────────────────────────────────────────────
// LF/IND·RI·SU/SD(scrollRange)·IL/DL·DECSTBM·DECALN. scroll region 안에서 행을 블록 이동하고, 화면 위로
// 나가는 줄만 스크롤백에 보관(pushScrollback). BCE로 새 빈 줄을 현재 pen 배경으로 채우고, wrap 경계·OSC 133
// 태그를 옮긴 내용과 함께 carry한다. dispatchCsi·write 루프·putCell(autowrap)이 위임한다.

/// DECALN(ESC # 8): 화면 전체를 'E'(기본 attr)로 채우고 커서를 home으로 보낸다. VT 정렬 진단(vttest) 전용.
pub fn decAlign(self: *TerminalCore) void {
    for (self.screen.cells) |*c| c.* = .{ .codepoint = 'E', .width = 1 };
    @memset(self.screen.wrapped, false);
    breakScrollbackWrapLink(self); // 화면을 통째로 덮어쓴다 — 이어지던 줄이 없어진다
    const old_cursor = self.screen.cursor;
    self.screen.cursor = .{};
    self.screen.pending_wrap = false;
    self.screen.last_print = null;
    markCursorMoveDirty(self, old_cursor, self.screen.cursor);
    self.dirty = core.fullDirty(self.size);
}

pub fn lineFeed(self: *TerminalCore) void {
    if (self.size.rows == 0) return;
    // LF(및 IND)는 deferred autowrap을 무효화한다. 비-scroll 분기는 markCursorMoveDirty가
    // 끄지만, scroll 분기(scrollRegionUp)는 그걸 안 거치므로 여기서 한 번에 끈다. 안 그러면
    // 마지막 행이 꽉 찬(pending_wrap) 상태에서 bare LF가 와도 플래그가 남아, 다음 printable
    // 글자가 또 한 줄 내려가(scroll) 직전 줄을 잃는다(이중 스크롤).
    self.screen.pending_wrap = false;
    // 스크롤/이동으로 grapheme run이 끝난다 — 다음 combining mark가 옮겨진 셀에 붙지 않게.
    // (\n 경로는 writeCodepoint가 이미 끊지만 ESC D(IND)는 이 함수로 직행한다.)
    self.screen.last_print = null;
    // 커서가 scroll region 하단 margin이면 region을 위로 스크롤(커서는 그대로). 그 외엔 화면
    // 끝 전까지 한 줄 내려간다(region 위/아래 모두 동일). scrollRegionUp의 fullDirty가 커서
    // 행까지 다시 칠하므로 scroll 분기는 cursor-move diff가 따로 필요 없다.
    if (self.screen.cursor.row == self.scroll_bottom) {
        scrollRegionUp(self);
        return;
    }
    if (self.screen.cursor.row + 1 < self.size.rows) {
        const old_cursor = self.screen.cursor;
        self.screen.cursor.row += 1;
        markCursorMoveDirty(self, old_cursor, self.screen.cursor);
        // OSC 133 영역이 활성이면(프롬프트/입력/출력) 다음 행에 전파한다 — 여러 줄 프롬프트·출력이
        // 전부 같은 분류로 태깅된다. unknown 상태에선 기존 태그를 지우지 않는다(분류 보존).
        if (self.semantic_state != .unknown) self.screen.prompt_marks[self.screen.cursor.row] = .{ .kind = self.semantic_state };
    }
}

/// RI(ESC M): 커서를 한 줄 올리고, scroll region 상단 margin이면 region을 아래로 스크롤한다.
pub fn reverseIndex(self: *TerminalCore) void {
    if (self.size.rows == 0) return;
    self.screen.pending_wrap = false;
    self.screen.last_print = null; // IND와 동일 — 스크롤/이동으로 grapheme run 종료
    if (self.screen.cursor.row == self.scroll_top) {
        scrollRegionDown(self);
        return;
    }
    if (self.screen.cursor.row > 0) {
        const old_cursor = self.screen.cursor;
        self.screen.cursor.row -= 1;
        markCursorMoveDirty(self, old_cursor, self.screen.cursor);
    }
}

/// scroll region [top, bottom]을 위로 한 줄 민다. top==0(화면 최상단)일 때만 밀려나는 줄을
/// 스크롤백에 보관한다 — 화면 위로 나가는 줄만 history다. 부분 region(top>0)의 스크롤아웃은
/// 버린다(xterm 동작). 기본 region [0, rows-1]이면 전체 화면 스크롤과 같다.
fn scrollRegionUp(self: *TerminalCore) void {
    // top==0이면 화면 위로 밀려나는 줄을 스크롤백에 보관한다. alt는 활성 sb.cap==0이라
    // pushScrollback이 by-construction 무동작 — vim 화면이 스크롤백을 오염시키지 않는다
    // (과거의 !alt_active 가드 불필요 — Scrollback 모델).
    const push = self.scroll_top == 0;
    scrollRangeUp(self, self.scroll_top, self.scroll_bottom, 1, push);
}

fn scrollRegionDown(self: *TerminalCore) void {
    scrollRangeDown(self, self.scroll_top, self.scroll_bottom, 1);
}

/// [top, bottom] 범위를 위로 n줄 민다(아래쪽에 빈 줄 n개). push_history면 밀려나는 행들을
/// 스크롤백에 보관한다 — LF 스크롤만 history고, DL(줄 삭제) 같은 편집 연산은 보관하지 않는다
/// (xterm 동작). n줄을 한 번의 블록 이동으로 처리해 IL/DL n이 O(범위)다(줄당 반복 아님).
pub fn scrollRangeUp(self: *TerminalCore, top: u16, bottom: u16, count: u16, push_history: bool) void {
    // **정상 스크롤(push_history)은 건드리지 않는다** — 그쪽이 이어짐을 만드는 경로다. DL 처럼
    // 히스토리로 안 밀고 0행을 다른 내용으로 덮는 경우만 끊는다.
    if (top == 0 and !push_history) breakScrollbackWrapLink(self);
    if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
    // bottom == top(한 줄 범위)도 허용한다 — IL/DL이 region 마지막 행에서 그 행만 비운다.
    if (bottom < top or bottom >= self.size.rows) return;
    const span: u16 = bottom - top + 1;
    const n = @min(count, span);

    // 선택 좌표가 자연히 따라가는 경우는 전체 화면 history 스크롤(아래 push + eviction 보정)뿐.
    // 부분 region 스크롤·DL(push 없음)은 활성 영역 안에서 행만 옮겨 abs 좌표가 어긋나므로 해제.
    if (!(push_history and top == 0 and bottom == self.size.rows - 1)) self.invalidateSelection();

    // 전체 화면 LF 스크롤일 때만 새로 생기는 맨 아래 blank 행이 현재 semantic 영역에 속한다
    // (커서가 거기로 이어져 명령 출력 등이 계속된다). 부분 region 스크롤·IL/DL의 빈 행은 .unknown.
    const lf_scroll = push_history and top == 0 and bottom == self.size.rows - 1;

    if (push_history) {
        var pr: u16 = 0;
        while (pr < n) : (pr += 1) {
            // 밀려나는 행의 OSC 133 태그도 함께 스크롤백으로 보낸다(분류 보존).
            const pushed = pushScrollback(self, self.screen.cells[self.index(top + pr, 0)..][0..self.size.cols], self.screen.wrapped[top + pr], self.screen.prompt_marks[top + pr]);
            // 과거를 보는 중(view_offset>0)이면 같은 내용을 계속 보도록 offset도 올린다
            // (scroll-lock). 보관 실패(OOM) 시엔 보정하지 않는다 — 뷰가 내용과 어긋나지 않게.
            if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.screen.sb.count);
        }
    }

    var row: u16 = top + n;
    while (row <= bottom) : (row += 1) {
        const dst_start = self.index(row - n, 0);
        const src_start = self.index(row, 0);
        @memcpy(
            self.screen.cells[dst_start .. dst_start + self.size.cols],
            self.screen.cells[src_start .. src_start + self.size.cols],
        );
        self.screen.wrapped[row - n] = self.screen.wrapped[row];
        self.screen.prompt_marks[row - n] = self.screen.prompt_marks[row]; // 태그를 옮긴 내용과 함께 끌어온다
    }

    var blank_row: u16 = bottom + 1 - n;
    while (blank_row <= bottom) : (blank_row += 1) {
        const blank_start = self.index(blank_row, 0);
        // BCE(배경색 erase): 스크롤로 새로 들어오는 빈 줄은 현재 pen의 배경으로 채운다(EL/ED와 같은 규칙).
        // 베이스: xterm.js getNullCell이 erase 속성(fg+bg)을 carry — 우리도 full pen을 carry(default pen이면
        // 기존과 동일한 default blank). Ghostty는 bgCell()로 배경만 좁히는데, 우리는 EL/ED와의 내부 일관성을
        // 위해 full pen으로 통일한다(bg-only 정제는 후속). 색 배경 화면이 스크롤될 때 빈 줄이 그 색을 잇는다.
        @memset(self.screen.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.screen.pen });
        self.screen.wrapped[blank_row] = false;
        self.screen.prompt_marks[blank_row] = .{ .kind = if (lf_scroll) self.semantic_state else .unknown };
    }
    // 범위 경계의 wrap 정합: shift가 old wrapped[bottom]("old bottom ↔ bottom+1" — 범위 밖과의
    // 연속)을 bottom-n으로 끌어왔는데, bottom+1은 안 움직였으니 그 연속은 깨졌다. 마찬가지로
    // 범위 위 행(top-1)이 주장하던 "top으로의 연속"도 top 내용이 바뀌어 깨졌다. 안 끊으면
    // 다음 resize reflow가 무관한 줄(상태줄 등)을 한 논리 줄로 합친다.
    if (bottom + 1 >= n and bottom + 1 - n > top) self.screen.wrapped[bottom - n] = false;
    if (top > 0) self.screen.wrapped[top - 1] = false;
    self.dirty = core.fullDirty(self.size);
}

/// [top, bottom] 범위를 아래로 n줄 민다(top쪽에 빈 줄 n개 삽입). 아래로 밀려나는 줄은
/// history가 아니므로 버린다(스크롤백에 안 넣는다).
pub fn scrollRangeDown(self: *TerminalCore, top: u16, bottom: u16, count: u16) void {
    if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
    // bottom == top(한 줄 범위)도 허용한다(scrollRangeUp과 동일한 이유).
    if (bottom < top or bottom >= self.size.rows) return;
    const span: u16 = bottom - top + 1;
    const n = @min(count, span);

    // 아래로 스크롤(IL/RI)은 항상 활성 영역 안에서 행을 옮기므로 선택 좌표가 어긋난다 — 해제.
    self.invalidateSelection();

    var row: u16 = bottom;
    while (row >= top + n) : (row -= 1) {
        const dst_start = self.index(row, 0);
        const src_start = self.index(row - n, 0);
        @memcpy(
            self.screen.cells[dst_start .. dst_start + self.size.cols],
            self.screen.cells[src_start .. src_start + self.size.cols],
        );
        self.screen.wrapped[row] = self.screen.wrapped[row - n];
        self.screen.prompt_marks[row] = self.screen.prompt_marks[row - n]; // OSC 133 태그도 옮긴 내용과 함께(scrollRangeUp 대칭)
    }

    // 0행이 빈 줄로 바뀌면 스크롤백에서 이어지던 줄이 없어진다(ED 와 같은 불변식).
    if (top == 0) breakScrollbackWrapLink(self);

    var blank_row: u16 = top;
    while (blank_row < top + n) : (blank_row += 1) {
        const blank_start = self.index(blank_row, 0);
        // BCE: 아래로 밀며 생기는 빈 줄(RI/IL)도 현재 pen 배경으로 채운다(scrollRangeUp과 같은 규칙).
        @memset(self.screen.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.screen.pen });
        self.screen.wrapped[blank_row] = false;
        self.screen.prompt_marks[blank_row] = .{}; // 삽입된 빈 행은 비분류(잔여 태그 → 헛 거터 방지)
    }
    // 범위 경계의 wrap 정합(scrollRangeUp과 대칭): 새 bottom 행(=old bottom-n 내용)이 범위 밖
    // bottom+1로 이어진다는 플래그는 거짓이고, top-1 행의 "top으로의 연속"도 top이 빈 줄이 돼
    // 깨졌다.
    self.screen.wrapped[bottom] = false;
    if (top > 0) self.screen.wrapped[top - 1] = false;
    self.dirty = core.fullDirty(self.size);
}

/// IL(CSI Ps L): 커서 행에 빈 줄 n개를 삽입한다. 커서 행~region 하단이 아래로 밀리고 넘치는
/// 줄은 버려진다. 커서가 scroll region 밖이면 무시. 후처리로 커서를 행 첫 칸으로 옮긴다(CR —
/// xterm/DEC 동작). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스.
pub fn insertLines(self: *TerminalCore, count: u16) void {
    if (self.screen.cursor.row < self.scroll_top or self.screen.cursor.row > self.scroll_bottom) return;
    scrollRangeDown(self, self.screen.cursor.row, self.scroll_bottom, count);
    self.screen.pending_wrap = false;
    self.screen.cursor.col = 0;
    self.screen.last_print = null;
}

/// DL(CSI Ps M): 커서 행부터 n줄을 삭제한다. 아래 줄들이 올라오고 region 하단에 빈 줄이 생긴다.
/// 삭제된 줄은 history가 아니다(스크롤백에 안 넣음). 커서가 region 밖이면 무시, 후처리 CR.
pub fn deleteLines(self: *TerminalCore, count: u16) void {
    if (self.screen.cursor.row < self.scroll_top or self.screen.cursor.row > self.scroll_bottom) return;
    scrollRangeUp(self, self.screen.cursor.row, self.scroll_bottom, count, false);
    self.screen.pending_wrap = false;
    self.screen.cursor.col = 0;
    self.screen.last_print = null;
}

/// DECSTBM(CSI Pt ; Pb r): scroll region을 설정한다. 1-indexed, 기본 Pt=1·Pb=rows. region 안으로
/// clamp하고 최소 2행이 아니면 무시한다. 설정 후 커서를 home(0,0)으로 옮긴다(DECOM off 기준).
pub fn setScrollRegion(self: *TerminalCore) void {
    const rows = self.size.rows;
    if (rows == 0) return;
    const top: u16 = self.csiParam(0, 1) - 1;
    const bottom: u16 = @min(self.csiParam(1, rows), rows) - 1;
    if (top >= bottom or bottom >= rows) return; // 2행 미만이면 무시
    self.scroll_top = top;
    self.scroll_bottom = bottom;
    const old_cursor = self.screen.cursor;
    // DECSTBM 후 커서를 origin home으로 — DECOM이면 region 상단, 아니면 화면 좌상단(xterm 동작).
    self.screen.cursor = .{ .row = if (self.origin_mode) self.scroll_top else 0, .col = 0 };
    self.screen.pending_wrap = false;
    markCursorMoveDirty(self, old_cursor, self.screen.cursor);
}

// ── alt screen + saved cursor (화면 전환·커서 저장/복원) ─────────────────────────────────────────
// DECSET 1049/47/1047(alt 전환)·1048/DECSC/DECRC·SCOSC/SCORC. alt 진입 시 primary grid·scrollback·커서를
// saved_* 슬롯으로 스왑하고 빈 alt 버퍼를 쓴다(alt는 cap=0 스크롤백 → history 안 쌓임). 복귀 시 되돌린다.
// dispatchCsi·setPrivateModes·handleEscapeByte·fullReset가 위임한다.

/// DECSC(ESC 7)·CSI s·DECSET 1048h가 커서·pen·deferred-wrap을 현재 화면의 슬롯에 저장한다. 슬롯이 Screen에
/// 귀속(per-screen, §10.8 B5)돼 alt 전환 swap을 타므로 늘 활성 화면(self.screen.saved_cursor)을 쓴다 —
/// primary/alt 분리는 swap이 by-construction으로 보장한다(옛 alt_active 슬롯 선택은 불필요해져 제거).
pub fn saveCursorState(self: *TerminalCore) void {
    self.screen.saved_cursor = .{
        .cursor = self.screen.cursor,
        .pen = self.screen.pen,
        .pending_wrap = self.screen.pending_wrap,
    };
}

pub fn restoreCursorState(self: *TerminalCore) void {
    restoreFromSlot(self, self.screen.saved_cursor);
}

fn restoreFromSlot(self: *TerminalCore, slot: core.SavedCursor) void {
    const old_cursor = self.screen.cursor;
    self.screen.cursor = .{
        .row = @min(slot.cursor.row, self.size.rows - 1),
        .col = @min(slot.cursor.col, self.size.cols - 1),
    };
    self.screen.pen = slot.pen;
    markCursorMoveDirty(self, old_cursor, self.screen.cursor);
    // markCursorMoveDirty가 deferred autowrap을 무효화(pending_wrap=false)하므로, 저장된 pending_wrap은
    // 그 '뒤'에 복원한다 — 줄 끝 deferred-wrap 상태에서 저장→복원하면 복원이 즉시 덮어써지던 버그
    // (DECSC/DECRC·CSI s/u가 공유하는 restoreFromSlot, code review).
    self.screen.pending_wrap = slot.pending_wrap;
    self.screen.last_print = null;
}

/// alt screen으로 전환한다. primary 화면(grid+스크롤백+커서 클러스터)을 `saved_screen`으로 통째 옮기고(struct
/// swap) 빈 alt 버퍼를 만든다. 커서가 화면에 귀속되므로(per-screen, §10.8) primary 커서는 swap으로 보관되고
/// alt는 home(0,0)에서 시작한다 — 별도 커서 저장 로직이 필요 없다(47/1047/1049 동일 진입). 할당 실패면 전환하지
/// 않는다(primary 유지가 안전 — grid 세 할당이 성공한 뒤에야 상태를 바꿔 OOM이 부작용 없게).
/// 이미 alt면 no-op이다(§10.8.4 #4 — 옛 1049h "unconditionally saves the cursor"는 단일-커서 모델 유물).
pub fn enterAltScreen(self: *TerminalCore) void {
    if (self.alt_active) return;

    const alt_cells = self.allocator.alloc(types.Cell, core.cellCount(self.size)) catch return;
    @memset(alt_cells, .{});
    const alt_wrapped = self.allocator.alloc(bool, self.size.rows) catch {
        self.allocator.free(alt_cells);
        return;
    };
    @memset(alt_wrapped, false);
    const alt_prompt_marks = self.allocator.alloc(types.RowPrompt, self.size.rows) catch {
        self.allocator.free(alt_cells);
        self.allocator.free(alt_wrapped);
        return;
    };
    @memset(alt_prompt_marks, .{});

    // 세 할당이 성공한 뒤에야 상태를 바꾼다(OOM 경로가 보관 슬롯을 오염시키지 않게).
    // primary 화면(grid+스크롤백+커서 클러스터)을 통째로 보관 슬롯으로 옮기고, alt는 새 빈 grid + cap=0 빈
    // 스크롤백 + home 커서(Screen 기본: cursor=.{}, pen=.{}, pending_wrap=false, last_print=null)를 쓴다.
    // alt 출력은 history에 안 쌓이고(pushScrollback 무동작), sb.count가 0이라 스크롤 뷰·스크롤바·검색이
    // by-construction으로 잠긴다("alt엔 스크롤백 없음"이 타입으로 보장). alt 화면은 셸 프롬프트 의미가 없어
    // prompt_marks는 전부 .unknown이다. 보던 과거를 닫고 선택도 해제한다(활성 cells가 alt로 바뀌어 abs 좌표가
    // 다른 내용을 가리키므로 — xterm.js도 버퍼 전환 시 선택 해제).
    self.saved_screen = self.screen;
    self.screen = .{ .cells = alt_cells, .wrapped = alt_wrapped, .prompt_marks = alt_prompt_marks };
    self.semantic_state = .unknown; // alt 진입 — primary의 진행 중 영역을 이어받지 않는다
    self.alt_active = true;
    self.view_offset = 0;
    self.invalidateSelection();
    self.pen_link = 0; // OSC 8 링크는 화면에 스코프된다 — 전환 시 닫는다(Ghostty endHyperlink)
    self.dirty = core.fullDirty(self.size);
}

/// primary screen으로 복귀한다. alt 버퍼를 버리고 보관해 둔 primary Screen(grid+스크롤백+커서 클러스터)을
/// 통째로 복원한다. 커서가 화면에 귀속되므로(per-screen, §10.8) primary 커서·pen·deferred-wrap 상태가 swap으로
/// 한 번에 돌아온다 — vim 종료 시 프롬프트가 떠났던 자리로 복귀하고, alt 안에서 TUI가 커서를 어떻게 옮겼든 셸
/// 커서는 안전하다(47/1047/1049 동일 — 옛 1047의 "복원 안 함"은 단일-커서 모델 유물, §10.8.4 #2).
/// 이미 primary면 no-op이다(§10.8.4 #4).
pub fn leaveAltScreen(self: *TerminalCore) void {
    if (!self.alt_active) return;
    // alt 화면(grid+빈 스크롤백)을 해제하고 보관해 둔 primary Screen을 통째로 복원한다 — grid·스크롤백
    // (ring·count·cap·rewrap 마크)·커서가 한 번에 돌아온다. alt의 sb는 빈 인스턴스라 deinit은 보통 no-op.
    self.allocator.free(self.screen.cells);
    self.allocator.free(self.screen.wrapped);
    if (self.screen.prompt_marks.len > 0) self.allocator.free(self.screen.prompt_marks);
    self.screen.sb.deinit(self.allocator); // alt의 빈 스크롤백 해제(보통 ring 미할당 — no-op)
    self.screen = self.saved_screen; // primary 화면(grid+스크롤백+커서) 통째 복원
    self.saved_screen = .{};
    self.semantic_state = .unknown; // primary 복귀 — 진행 중 영역을 이어받지 않는다(다음 프롬프트가 재마킹)
    self.alt_active = false;
    self.pen_link = 0; // 화면 전환 — 열린 링크를 닫는다(Ghostty endHyperlink)
    self.invalidateSelection(); // primary 복귀 — 활성 cells가 다시 바뀌므로 선택 해제
    self.dirty = core.fullDirty(self.size);
}

// ── print 핫패스 (codepoint → 셀) ───────────────────────────────────────────────────────────────
// 모든 printable/control codepoint가 거치는 가장 뜨거운 경로. control(CR/LF/BS/HT/SO/SI/BEL)은 즉시 처리,
// printable은 charset 변환 → grapheme/combining/이모지 폭 판정 → putCell(셀 쓰기 + deferred autowrap + BCE).
// write 루프·completePendingUtf8(parser, core 잔류)·repeatLastChar(REP)가 위임한다.

pub fn writeCodepoint(self: *TerminalCore, codepoint: u21) void {
    switch (codepoint) {
        '\r' => {
            const old_cursor = self.screen.cursor;
            self.screen.cursor.col = 0;
            markCursorMoveDirty(self, old_cursor, self.screen.cursor);
            self.screen.last_print = null;
        },
        '\n' => {
            lineFeed(self);
            self.screen.last_print = null;
        },
        '\t' => writeTab(self),
        0x07 => self.bell_pending = true, // BEL: 시스템 벨 요청(platform이 drain — NSSound.beep)
        0x0b, 0x0c => lineFeed(self), // VT(0x0b)/FF(0x0c): LF처럼 한 줄 내림(col 유지) — printf '\f'/'\v'
        0x0e => self.charset_gl = 1, // SO(shift out): G1을 GL로 호출(ESC ) 0 후 box 문자 시작)
        0x0f => self.charset_gl = 0, // SI(shift in): G0을 GL로 호출(box 문자 끝, ASCII 복귀)
        0x08 => {
            // BS는 정확히 1칸 왼쪽이다(ECMA-48; xterm.js InputHandler.backspace와 동일).
            // 예전엔 wide continuation 위에 서면 base로 한 칸 더 당겼는데, 셸은 BS를 항상
            // 1칸으로 계산하고 wide 글자엔 BS를 두 번 보내므로(zsh 캡처: "\b\b  \b\b")
            // 그 친절이 셸 계산과 한 칸 어긋나 지우기 공백이 프롬프트를 침범했다(라이브
            // 한글 삭제에서 실제 발생). continuation 위에 선 커서의 다음 쓰기는
            // clearCellForWrite가 base/continuation을 정리하므로 안전하다.
            const old_cursor = self.screen.cursor;
            if (self.screen.cursor.col > 0) self.screen.cursor.col -= 1;
            markCursorMoveDirty(self, old_cursor, self.screen.cursor);
            self.screen.last_print = null;
        },
        else => {
            if (codepoint < 0x20) return;
            // G3: GL에 호출된 G-set(G0/G1)의 charset으로 변환한다(dec_special이면 0x60..0x7e→box 문자,
            // ascii면 무변환). box 문자는 width 1·non-combining이라 아래 grapheme/combining 로직과 호환.
            const cp = translateCharset(self, codepoint);
            if (width.cellWidth(cp) == 0) {
                // VS16(U+FE0F) 등 변형 선택자/결합 문자는 0폭 combining으로 앞 글자에 붙인다.
                appendClusterCodepoint(self, cp);
                // VS16이 앞 글자를 이모지 표현(width 2)으로 승격해 풀사이즈로 그린다(❤+VS16=❤️, 키캡 2️⃣ 2칸).
                // 승격 조건은 둘 중 하나: (1) mode 2027(grapheme cluster) — 앱이 너비를 합의함, (2) emoji_wide
                // (text.emoji-width=wide, 기본) — Ghostty/iTerm2처럼 이모지를 항상 2칸으로 본다(모던 TUI 정합).
                // narrow(emoji_wide=false)면 EAW 그대로 1칸 — zsh ZLE가 ❤+VS16을 1칸으로 보는 환경의 줄 편집 보호.
                if ((self.grapheme_cluster_mode or self.emoji_wide) and cp == 0xFE0F) promoteLastToEmojiWidth(self);
                return;
            }
            // emoji grapheme(스킨톤·국기 RI 쌍·ZWJ 시퀀스)을 한 셀로 묶는다. 셋은 서로 다른 UAX#29
            // 규칙이지만(GB9 modifier·GB12/13 RI·GB11 ZWJ) emojiClusterExtends 한 판정 + 단일 흡수+폭승격
            // 경로를 공유한다. promoteLastToEmojiWidth는 RI(폭 1→2)만 올리고 이미 폭 2인 스킨톤·ZWJ엔 no-op이다.
            //
            // **게이트는 VS16 승격(위)과 같다**: (1) mode 2027 — 앱이 너비를 합의했다, (2) emoji_wide
            // (`text.emoji-width=wide`, 기본). 옛 코드는 (1)만 열어 두었는데, 그러면 같은 설정에서
            // ❤+VS16은 2칸으로 묶이면서 👨‍👩‍👧‍👦는 구성 이모지마다 셀을 먹어 **10칸**이 됐다 — "이모지를 항상
            // 2칸으로 본다"는 `emoji_wide`의 약속과 정면으로 어긋난다(실측 2026-08-20: `|👍🏽|`=3.8칸,
            // `|👨‍👩‍👧‍👦|`=10.4칸. 같은 줄의 `|❤️|`·`|🇰🇷|`·`|人|`은 정확히 2칸이었다).
            //
            // **베이스/결정(사실상 표준)**: 단일 표준이 없다. Ghostty는 `grapheme-width-method`가
            // **기본 `unicode`**라 mode 2027 없이도 cluster 단위로 센다. maru도 같은 쪽을 택한다 —
            // 모던 TUI(Ink 기반 앱 등)가 cluster 단위로 폭을 계산하므로, 터미널이 구성요소별로 세면
            // 그 앱의 테이블·박스가 어긋난다(사용자 제보: Claude Code 화면의 표 테두리가 밀렸다).
            // `text.emoji-width=narrow`면 옛 동작(mode 2027에서만)이라 wcwidth로 세는 환경도 남는다.
            if (self.grapheme_cluster_mode or self.emoji_wide) {
                if (self.screen.last_print) |last| {
                    const last_cell = self.screen.cells[self.index(last.row, last.col)];
                    if (emojiClusterExtends(self, last_cell, cp)) {
                        appendClusterCodepoint(self, cp);
                        promoteLastToEmojiWidth(self);
                        return;
                    }
                }
            }
            // NFD 한글 conjoining 자모(GB6/7/8): 중성(V)·종성(T)은 단독 폭이 1이라 위 combining
            // (폭 0) 경로에 안 걸리지만, 앞 음절 cluster에 0폭으로 흡수돼야 한다 — 안 그러면 자모가
            // 셀마다 흩어지고 폭이 음절당 2배가 된다(초성만 wide). mode 2027과 무관하게 적용한다:
            // macOS 파일명(NFD)을 내는 `ls`는 grapheme cluster mode를 켜지 않기 때문이다(설계 §4.7).
            // 흡수 대상은 conjoining 자모(U+1100~U+11FF)로 한정한다 — extendsCluster만 쓰면 GB9가
            // ZWJ(폭 1)까지 true라 NFD와 무관한 ZWJ가 0폭으로 새어들어 커서 전진이 달라졌다(리뷰).
            // ZWJ 시퀀스(GB11)·완성형은 각자 제 경로로 가고, 여기선 NFD 자모만 합친다.
            if (grapheme.isConjoiningJamo(cp)) {
                if (self.screen.last_print) |last| {
                    const last_cell = self.screen.cells[self.index(last.row, last.col)];
                    if (grapheme.extendsCluster(trailingClusterCp(self, last_cell), cp)) {
                        appendClusterCodepoint(self, cp);
                        return;
                    }
                }
            }
            putCell(self, cp);
        },
    }
}

pub fn putCell(self: *TerminalCore, codepoint: u21) void {
    if (self.size.cols == 0 or self.size.rows == 0) return;
    // deferred autowrap: 직전 글자가 마지막 칸을 채웠으면(pending_wrap), 이 글자를 그리기
    // 전에 다음 줄 첫 칸으로 넘긴다(바닥이면 scroll). 이렇게 다음 글자 시점에 wrap해야 줄을
    // 정확히 채운 마지막 글자마다 빈 줄이 끼지 않는다(표준 VT 동작, zsh prompt 등이 의존).
    if (self.screen.pending_wrap) {
        // 다음 줄로 넘긴다. lineFeed가 pending_wrap을 끈다. 이 행은 autowrap으로 다음 줄로 이어지는
        // soft-wrap이다(reflow가 이 플래그로 잇는다). soft-wrap 플래그는 lineFeed '후'에 세운다 — 커서가
        // scroll_bottom이라 lineFeed가 scroll이면 scrollRangeUp의 경계 fixup이 lineFeed 전에 세운
        // wrapped를 지우기 때문이다(promoteLastToEmojiWidth와 같은 이유). scroll 여부와 무관하게 "직전
        // 줄(row-1)이 이 줄로 이어진다"를 정확히 남긴다.
        self.screen.cursor.col = 0;
        lineFeed(self);
        if (self.screen.cursor.row > 0) self.screen.wrapped[self.screen.cursor.row - 1] = true;
    }
    if (self.screen.cursor.col >= self.size.cols) self.screen.cursor.col = self.size.cols - 1;
    if (self.screen.cursor.row >= self.size.rows) self.screen.cursor.row = self.size.rows - 1;

    const cell_width: u2 = width.cellWidthAmbiguous(codepoint, self.ambiguous_wide);
    // wide glyph(2칸)가 줄 끝(마지막 칸, 1칸만 남음)에 안 들어가면 통째로 다음 줄로 넘긴다
    // (이전 줄 마지막 칸은 빈칸으로 남는다). grid는 항상 cols>=2라(clampGridSize) 넘긴 뒤엔
    // 반드시 들어가므로, 칸을 줄이는 degrade 없이 그대로 width 2로 쓴다.
    if (cell_width == 2 and self.screen.cursor.col + 1 >= self.size.cols) {
        // wide glyph를 통째로 다음 줄로 넘긴다 — 직전 줄이 이 줄로 이어지는 soft-wrap이다. 플래그는 위
        // pending_wrap과 같은 이유로 lineFeed '후'에 세운다(scroll 시 scrollRangeUp fixup이 지우지 않게).
        self.screen.cursor.col = 0;
        lineFeed(self);
        if (self.screen.cursor.row > 0) self.screen.wrapped[self.screen.cursor.row - 1] = true;
    }

    const row = self.screen.cursor.row;
    const col = self.screen.cursor.col;
    // G6 IRM(insert mode): 켜져 있으면 쓰기 전에 커서 위치에 cell_width칸을 삽입(오른쪽 밀기) — 덮어쓰기 대신
    // 삽입이 된다. insertChars가 커서는 안 옮기고 줄만 민다.
    if (self.insert_mode) insertChars(self, cell_width);
    // 이 행에 새로 쓰므로 wrap 상태를 리셋한다. 다시 채워 마지막 칸을 넘기면 위 autowrap 분기가
    // true로 재설정한다. 덕분에 셸이 한 줄을 다시 그리면(redraw) wrap 플래그가 스스로 교정된다.
    self.screen.wrapped[row] = false;

    clearCellForWrite(self, row, col);
    if (cell_width == 2) clearCellForWrite(self, row, col + 1);

    self.screen.cells[self.index(row, col)] = .{
        .codepoint = codepoint,
        .style = self.screen.pen,
        .width = cell_width,
        .link = self.pen_link,
    };
    if (cell_width == 2) {
        self.screen.cells[self.index(row, col + 1)] = .{
            .style = self.screen.pen,
            .width = 0,
            .continuation = true,
            .link = self.pen_link,
        };
    }
    self.screen.last_print = .{ .row = row, .col = col };
    self.screen.last_printed_cp = codepoint; // G5 REP: 직전 출력 글자 추적
    markDirty(self, self.screen.cursor.row);

    if (self.screen.cursor.col + cell_width < self.size.cols) {
        self.screen.cursor.col += cell_width;
    } else {
        // 마지막 칸을 채웠다. autowrap(DECAWM)이 켜져 있으면 커서를 마지막 칸에 두고 pending_wrap을 세워
        // 다음 printable 글자가 먼저 다음 줄로 넘어가게 한다(deferred autowrap). off(?7l)면 wrap 없이
        // 마지막 칸에 머물러 다음 글자가 그 칸을 덮어쓴다(G8).
        self.screen.cursor.col = self.size.cols - 1;
        if (self.autowrap) self.screen.pending_wrap = true;
    }
}

/// grapheme(VS16/RI 페어 등)이 붙은 직전 base 셀을 width 1 -> 2로 승격한다(이미 2면 무시).
/// mode 2027 또는 emoji_wide(text.emoji-width=wide)에서 호출된다 — 둘 다 이모지를 2칸으로 보는 상태다.
fn promoteLastToEmojiWidth(self: *TerminalCore) void {
    const last = self.screen.last_print orelse return;
    const base_idx = self.index(last.row, last.col);
    if (self.screen.cells[base_idx].width == 2) return; // 이미 wide

    // base가 줄 마지막 칸이면 오른쪽 continuation 칸이 없다. 폭만 키우면 안 되고(다음 칸이
    // 다음 글자라 침범), wide glyph autowrap처럼 base를 통째로 다음 줄로 옮겨 2칸을 차지하게
    // 한다 — 안 그러면 mode 2027에서도 줄 끝 이모지가 width 1로 남아 앱과 너비가 어긋난다.
    if (last.col + 1 >= self.size.cols) {
        const base = self.screen.cells[base_idx];
        self.screen.cells[base_idx] = .{}; // 이전 줄 마지막 칸은 빈칸으로
        markDirty(self, last.row);
        self.screen.cursor.col = 0;
        lineFeed(self);
        const row = self.screen.cursor.row;
        // soft-wrap 플래그는 lineFeed '후'에 세운다. lineFeed가 scroll(커서가 scroll_bottom)일
        // 때 scrollRangeUp의 경계 fixup이 lineFeed 전에 세운 wrapped를 지우기 때문이다 —
        // scroll 여부와 무관하게 "이전 줄(row-1)이 이 이모지 줄로 이어진다"를 정확히 남긴다.
        if (row > 0) self.screen.wrapped[row - 1] = true;
        self.screen.wrapped[row] = false;
        self.screen.cells[self.index(row, 0)] = base;
        self.screen.cells[self.index(row, 0)].width = 2;
        self.screen.cells[self.index(row, 1)] = wideContinuationCell(base.style, base.link);
        self.screen.last_print = .{ .row = row, .col = 0 };
        markDirty(self, row);
        if (2 < self.size.cols) {
            self.screen.cursor.col = 2;
            self.screen.pending_wrap = false;
        } else {
            self.screen.cursor.col = self.size.cols - 1;
            self.screen.pending_wrap = true;
        }
        return;
    }

    self.screen.cells[base_idx].width = 2;
    self.screen.cells[self.index(last.row, last.col + 1)] = wideContinuationCell(self.screen.cells[base_idx].style, self.screen.cells[base_idx].link);
    markDirty(self, last.row);
    // 커서가 base 바로 뒤(width-1 전진 위치)면 2칸짜리로 한 칸 더 민다.
    if (self.screen.cursor.row == last.row and self.screen.cursor.col == last.col + 1) {
        if (last.col + 2 < self.size.cols) {
            self.screen.cursor.col = last.col + 2;
            self.screen.pending_wrap = false;
        } else {
            self.screen.cursor.col = self.size.cols - 1;
            self.screen.pending_wrap = true;
        }
    }
}

/// 셀 cluster의 마지막 코드포인트 — UAX#29 boundary 판정(extendsCluster)의 prev 입력. store에
/// cluster 본체가 있으면 그 끝, 없으면 base다. 이렇게 base가 아니라 '직전 자모'와 비교해야 NFD
/// 음절의 V→T(GB7) 연쇄가 끊기지 않는다(base L과 T는 GB6 밖이라 false).
fn trailingClusterCp(self: *const TerminalCore, cell: types.Cell) u21 {
    if (self.graphemeCluster(cell.grapheme_id)) |cps| {
        if (cps.len > 0) return cps[cps.len - 1];
    }
    return cell.codepoint;
}

/// cp를 직전 base 셀의 grapheme cluster에 0폭 extra로 붙인다(커서·last_print·폭은 그대로). 모든
/// extra(악센트·VS16·NFD 자모·키캡·ZWJ)가 grapheme_store에 누적된다 — pure-B 단일 출처라 잘림·손실이
/// 없다(첫 extra는 internGrapheme, 둘째부터 appendGraphemeCodepoint). base가 없는 run(스트림 시작·
/// CR/LF 직후)이면 붙일 데가 없어 떨구고, OOM이면 그 extra만 떨군다(앞선 cluster·셀은 유지).
/// combining mark(폭 0)·skin-tone·RI·NFD 자모가 모두 이 한 진입점을 공유한다.
fn appendClusterCodepoint(self: *TerminalCore, cp: u21) void {
    const last = self.screen.last_print orelse return;
    const idx = self.index(last.row, last.col);
    var cell = self.screen.cells[idx];
    cell.grapheme_id = if (cell.grapheme_id != 0)
        self.appendGraphemeCodepoint(cell.grapheme_id, cp) catch return
    else
        self.internGrapheme(&.{cp}) catch return;
    self.screen.cells[idx] = cell;
    markDirty(self, last.row);
}

fn clearCellForWrite(self: *TerminalCore, row: u16, col: u16) void {
    const cell_index = self.index(row, col);
    const cell = self.screen.cells[cell_index];
    if (cell.continuation and col > 0) {
        const previous_index = self.index(row, col - 1);
        if (self.screen.cells[previous_index].width == 2) {
            self.screen.cells[previous_index] = .{};
        }
    }
    if (cell.width == 2 and col + 1 < self.size.cols) {
        self.screen.cells[self.index(row, col + 1)] = .{};
    }
    self.screen.cells[cell_index] = .{};
}

// ── resize / reflow (그리드 크기 변경·줄 재배치) ─────────────────────────────────────────────────
// 폭 변경 시 soft-wrap 플래그로 논리 줄을 합쳐 새 폭에 다시 wrap하고 넘치는 위쪽 행을 스크롤백으로 밀어낸다.
// 커서가 있는 논리 줄은 verbatim 보존(셸이 SIGWINCH로 직접 redraw). alt는 reflow 없이 clip/pad. perf 핫
// (core_resize_loop) — reflow 스크래치(reflow_cells)는 grow-only로 재할당 churn을 없앤다. resize는 외부가
// 점-호출하므로 core에 facade 메서드로 남고 본문만 여기 있다(app/runtime·host·live_pty가 core.resize 호출).

fn trimmedRowLen(self: *const TerminalCore, row: u16) u16 {
    var len: u16 = self.size.cols;
    while (len > 0) : (len -= 1) {
        if (!isBlankCell(self.screen.cells[self.index(row, len - 1)])) break;
    }
    return len;
}

/// 활성 행의 "칠해진 칸까지" 길이 — soft-wrap 행이 화면 reflow에 기여하는 길이다(`paintedLen`과 같은 기준).
/// soft 행이 꽉 찼다고 가정하고 `cols`를 쓰면, 넓히는 resize가 남긴 wrap 채움이 내용으로 섞인다.
fn paintedRowLen(self: *const TerminalCore, row: u16) u16 {
    var len: u16 = self.size.cols;
    while (len > 0) : (len -= 1) {
        if (!types.isUnwritten(self.screen.cells[self.index(row, len - 1)])) break;
    }
    return len;
}

/// 기본 배경의 빈 공백 셀인지(reflow trim 기준). continuation/grapheme cluster/배경색이 있으면 내용이다.
/// core의 selection(wordBounds)도 cross-file 호출 — pub.
pub fn isBlankCell(cell: types.Cell) bool {
    return types.isTextTrimBlank(cell);
}

/// reflow가 누적한 출력 행(row-major, cols개)이 통째로 빈 행인지.
fn outputRowBlank(cells: []const types.Cell, row: usize, cols: u16) bool {
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        if (!isBlankCell(cells[row * @as(usize, cols) + c])) return false;
    }
    return true;
}

/// 폭이 줄어 행 마지막 칸에 wide glyph base(width 2)만 남고 continuation이 잘렸으면 그 base를
/// 비운다(한 칸 공간에 2칸 폭 half-glyph가 렌더되는 것 방지). 폭 축소로 내용을 clip하는 모든
/// 경로(resize 커서 줄 verbatim, renderSnapshot 스크롤백 합성)가 공유한다. resize·renderSnapshot·rewrap이
/// 17~18/N서 모두 이리로 이동해 호출처가 전부 같은 파일 — private(11/N의 cross-file pub은 더는 불필요).
fn clearTruncatedWideBase(row: []types.Cell) void {
    if (row.len > 0 and row[row.len - 1].width == 2) row[row.len - 1] = .{};
}

/// reflow 출력 스크래치를 cap_rows×cols 이상으로 키운다(grow-only, 내용 보존 안 함).
fn ensureReflowScratch(self: *TerminalCore, cap_rows: usize, cols: u16) !void {
    const need_cells = cap_rows * @as(usize, cols);
    if (self.reflow_cells.len < need_cells) {
        if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
        self.reflow_cells = try self.allocator.alloc(types.Cell, need_cells);
    }
    if (self.reflow_wrapped.len < cap_rows) {
        if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
        self.reflow_wrapped = try self.allocator.alloc(bool, cap_rows);
    }
    if (self.reflow_prompt_marks.len < cap_rows) {
        if (self.reflow_prompt_marks.len > 0) self.allocator.free(self.reflow_prompt_marks);
        self.reflow_prompt_marks = try self.allocator.alloc(types.RowPrompt, cap_rows);
    }
}

/// 그리드를 reflow 없이 새 크기로 clip/pad해 복사한다(왼쪽 위 기준, 넘치는 내용은 버림).
/// alt screen resize 등 재배치가 의미 없는 경로가 쓴다. 잘린 wide glyph base는 정리한다.
fn copyRegionResize(
    allocator: std.mem.Allocator,
    src: []const types.Cell,
    old_rows: u16,
    old_cols: u16,
    next_size: types.Size,
) ![]types.Cell {
    const dst = try allocator.alloc(types.Cell, core.cellCount(next_size));
    @memset(dst, .{});
    const copy_rows = @min(old_rows, next_size.rows);
    const copy_cols = @min(old_cols, next_size.cols);
    var r: u16 = 0;
    while (r < copy_rows) : (r += 1) {
        const row_dst = dst[@as(usize, r) * next_size.cols ..][0..next_size.cols];
        @memcpy(row_dst[0..copy_cols], src[@as(usize, r) * old_cols ..][0..copy_cols]);
        clearTruncatedWideBase(row_dst);
    }
    return dst;
}

pub fn resize(self: *TerminalCore, cols_in: u16, rows_in: u16) !void {
    // grid를 최소 2칸×1행으로 맞춘다(clampGridSize 참고).
    const next_size = core.clampGridSize(.{ .cols = cols_in, .rows = rows_in });
    const new_cols = next_size.cols;
    const new_rows = next_size.rows;
    const old_rows = self.size.rows;
    const old_cols = self.size.cols;

    // resize는 활성 화면을 reflow하고(폭 변경 시) 행을 스크롤백으로 밀어내 모든 cell이 재배치
    // 된다 — 선택의 절대-행 좌표는 보존할 수 없으니 진입부에서 무조건 해제한다(폭/높이 변경,
    // alt 경로 공통). 스크롤백 재-wrap의 selectionClear와 별개로 여기서도 처리해, 폭 불변 높이
    // 변경이나 빈 스크롤백 같은 경로가 새지 않게 한다.
    self.invalidateSelection();

    // alt screen 중 resize: reflow/스크롤백 없이 두 그리드(활성 alt + 저장된 primary)를 단순
    // clip/pad한다. TUI는 SIGWINCH로 전체를 다시 그리므로 alt 내용 재배치는 의미가 없고, 저장된
    // primary는 복귀 시 크기가 맞아야 한다(복귀 후 첫 resize부터 다시 reflow).
    if (self.alt_active) {
        const new_alt = try copyRegionResize(self.allocator, self.screen.cells, old_rows, old_cols, next_size);
        errdefer self.allocator.free(new_alt);
        const new_saved = try copyRegionResize(self.allocator, self.saved_screen.cells, old_rows, old_cols, next_size);
        errdefer self.allocator.free(new_saved);
        const new_wrapped = try self.allocator.alloc(bool, new_rows);
        errdefer self.allocator.free(new_wrapped);
        @memset(new_wrapped, false);
        const new_saved_wrapped = try self.allocator.alloc(bool, new_rows);
        errdefer self.allocator.free(new_saved_wrapped);
        @memset(new_saved_wrapped, false);
        const new_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
        errdefer self.allocator.free(new_prompt_marks);
        @memset(new_prompt_marks, .{});
        const new_saved_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
        @memset(new_saved_prompt_marks, .{});
        // 살아남는 행의 soft-wrap 플래그는 보존한다. 특히 saved primary의 것을 버리면 복귀 후
        // 리사이즈에서 긴 wrap 줄이 영영 재합쳐지지 않는다(alt 것은 TUI가 다시 그리지만 동일
        // 규칙로 보존). 폭이 줄어 행이 clip돼도 논리 연속성 자체는 유지된다. OSC 133 태그도 같은
        // 규칙으로 보존한다(저장된 primary의 프롬프트 분류가 복귀 후에도 살아 있어야 한다).
        const keep_rows = @min(old_rows, new_rows);
        @memcpy(new_wrapped[0..keep_rows], self.screen.wrapped[0..keep_rows]);
        @memcpy(new_saved_wrapped[0..keep_rows], self.saved_screen.wrapped[0..keep_rows]);
        if (self.screen.prompt_marks.len >= keep_rows) @memcpy(new_prompt_marks[0..keep_rows], self.screen.prompt_marks[0..keep_rows]);
        if (self.saved_screen.prompt_marks.len >= keep_rows) @memcpy(new_saved_prompt_marks[0..keep_rows], self.saved_screen.prompt_marks[0..keep_rows]);

        self.allocator.free(self.screen.cells);
        self.allocator.free(self.saved_screen.cells);
        if (self.screen.wrapped.len > 0) self.allocator.free(self.screen.wrapped);
        if (self.saved_screen.wrapped.len > 0) self.allocator.free(self.saved_screen.wrapped);
        if (self.screen.prompt_marks.len > 0) self.allocator.free(self.screen.prompt_marks);
        if (self.saved_screen.prompt_marks.len > 0) self.allocator.free(self.saved_screen.prompt_marks);
        self.screen.cells = new_alt;
        self.saved_screen.cells = new_saved;
        self.screen.wrapped = new_wrapped;
        self.saved_screen.wrapped = new_saved_wrapped;
        self.screen.prompt_marks = new_prompt_marks;
        self.saved_screen.prompt_marks = new_saved_prompt_marks;
        self.size = next_size;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        // 커서가 화면 귀속(per-screen, §10.8)이라 활성(alt)·보관(primary, saved_screen) 두 화면 모두 새 크기로
        // 맞춘다 — 안 하면 leaveAltScreen이 통째 복원할 때 보관 화면의 OOB 커서가 되살아난다. swap 단위(Screen)를
        // 한 헬퍼로 처리해 두 블록이 어긋나지 않게 한다(리뷰 B6).
        clampScreenCursorForResize(&self.screen, next_size);
        clampScreenCursorForResize(&self.saved_screen, next_size);
        // CSI 파서 상태/UTF-8 꼬리는 유지(아래 일반 경로와 동일한 이유).
        self.dirty = core.fullDirty(next_size);
        rebuildTabstops(self, old_cols); // 탭스톱을 새 cols에 맞춘다(겹침 보존·새 열 8칸 기본).
        // alt 중 폭이 바뀌면 보관된 primary 스크롤백(saved_sb)을 복귀 후 현재 폭으로 재-wrap하도록
        // 마크한다(활성 alt sb는 빈 인스턴스라 무의미 — primary는 saved_sb에 있다). leaveAltScreen이
        // 복원하면 ensureScrollbackRewrapped가 1회 수행한다. 안 그러면 옛 폭 행이 복귀 후 stale로 보인다.
        if (new_cols != old_cols) self.saved_screen.sb.rewrap_pending = true;
        return;
    }

    // 스크롤백 재-wrap은 보통 지연 마크만 한다(폭이 그대로면 불변이라 생략). 즉시 하면 resize
    // 마다 O(스크롤백) 재할당이라 perf 예산(core_resize_loop)을 수십 배 넘는다 — 실제 재-wrap은
    // 사용자가 과거를 보는 순간(scrollViewport/renderSnapshot) 1회만 일어난다. 그 사이에 활성
    // reflow가 밀어내는 새 폭 행이 ring에 섞여도, 재-wrap은 행별 저장 폭 기준이라 혼재가 안전하다.
    // 단 지금 과거를 보는 중(view_offset>0)이면 즉시 재-wrap하면서 보던 행을 앵커로 offset을
    // 재계산한다 — 바닥으로 튕기지 않고 보던 내용이 유지된다(드물어서 1회 비용 수용).
    if (new_cols != old_cols and self.screen.sb.count > 0) {
        if (self.view_offset > 0) {
            const anchor = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count);
            rewrapScrollbackAnchored(self, new_cols, anchor);
            self.screen.sb.rewrap_pending = false;
        } else {
            self.screen.sb.rewrap_pending = true;
        }
    }

    // reflow: soft-wrap 플래그(wrapped)로 연속 줄(논리 줄)을 합쳐 새 폭에 다시 wrap한다. 넘치는
    // 위쪽 행은 스크롤백으로 밀어낸다. 핵심: 커서 위치는 어떤 셀이 나가는지/행이 soft인지를 절대
    // 바꾸지 않는다(hard 줄끝은 항상 hard로 남아 reflow가 프롬프트를 합치지 않는다 — 라이브 garble
    // 회귀의 근본 원인 차단). 커서의 trailing-blank는 내용을 늘리지 않고 좌표로만 환산한다.

    // 출력 행 상한을 계산해 스크래치를 확보한다(ArrayList realloc churn 제거).
    var total_content: usize = 0;
    {
        var r: u16 = 0;
        while (r < old_rows) : (r += 1) {
            total_content += if (self.screen.wrapped[r]) paintedRowLen(self, r) else trimmedRowLen(self, r);
        }
    }
    // 출력 행 상한. soft-flush마다 행에 들어가는 최소 내용은 new_cols-1(줄 끝에서 wide glyph가
    // 한 칸을 못 채우고 넘어가는 경우)이므로 재배치 행 수는 total_content/(new_cols-1)로 막힌다.
    // (이전엔 /new_cols로 나눠 wide glyph의 열 낭비를 과소 계산 → 좁은 폭에서 스크래치 OOB였다.)
    // 2*old_rows는 verbatim 커서 줄(≤old_rows)+hard-flush 빈 행(≤old_rows)을, +4는 ceil/열린 행/
    // 방어 flush 여유다. new_cols>=2(clampGridSize)라 new_cols-1>=1.
    const cap_rows: usize = 2 * @as(usize, old_rows) + total_content / (new_cols - 1) + 4;
    try ensureReflowScratch(self, cap_rows, new_cols);
    const scratch = self.reflow_cells;
    const swrap = self.reflow_wrapped;
    const pmarks = self.reflow_prompt_marks; // 산출 행별 OSC 133 태그(소스 옛 행에서 carry)
    const blank: types.Cell = .{};

    var out_rows: usize = 0;
    var oc: u16 = 0;
    @memset(scratch[0..new_cols], blank); // 열린 출력 행 0
    var cursor_out_row: ?usize = null;
    var cursor_out_col: u16 = 0;

    // 커서가 있는 논리 줄(wrapped run)의 범위. 이 줄은 reflow하지 않고 그대로 둔다 — 셸이
    // SIGWINCH로 직접 다시 그린다(xterm.js의 reflowCursorLine=false 기본 동작). 커서가 있는 줄을
    // 재배치하면 커서가 옮겨져, 옛 폭 기준으로 상대 이동(\e[A)하는 셸 redraw가 어긋나 프롬프트가
    // 중복된다. 그 줄은 셸이 알아서 새 폭으로 다시 그리므로 건드리지 않는 게 안전하다.
    var cur_start: u16 = self.screen.cursor.row;
    while (cur_start > 0 and self.screen.wrapped[cur_start - 1]) cur_start -= 1;
    var cur_end: u16 = self.screen.cursor.row;
    while (cur_end + 1 < old_rows and self.screen.wrapped[cur_end]) cur_end += 1;

    var old_r: u16 = 0;
    // 재-wrap되는 논리 줄의 종료코드(OSC 133 D는 leader 한 행에만 스탬프)를 새 줄의 '첫' 산출
    // 행에만 둔다 — 안 그러면 narrow는 한 명령에 거터 바가 여러 개, widen-merge는 leader exit가
    // 분실된다(코드리뷰 #1). 분류(kind)는 줄 전체가 같으니 그대로 carry한다.
    var rewrap_exit: ?i16 = null;
    while (old_r < old_rows) {
        // 커서 줄: reflow 없이 각 옛 행을 그대로(새 폭으로 clip/pad) 출력한다. cur_start는 논리
        // 줄 시작이라 직전 줄이 닫혀 oc==0이다.
        if (old_r == cur_start) {
            var r: u16 = cur_start;
            while (r <= cur_end) : (r += 1) {
                const dst0 = out_rows * new_cols;
                @memset(scratch[dst0..][0..new_cols], blank);
                const n = @min(old_cols, new_cols);
                @memcpy(scratch[dst0..][0..n], self.screen.cells[self.index(r, 0)..][0..n]);
                clearTruncatedWideBase(scratch[dst0..][0..new_cols]);
                swrap[out_rows] = self.screen.wrapped[r];
                pmarks[out_rows] = self.screen.prompt_marks[r]; // 커서 줄은 verbatim — 태그도 1:1 보존
                if (r == self.screen.cursor.row) {
                    cursor_out_row = out_rows;
                    cursor_out_col = @min(self.screen.cursor.col, new_cols - 1);
                }
                out_rows += 1;
            }
            @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
            oc = 0;
            old_r = cur_end + 1;
            continue;
        }

        // 그 외 논리 줄은 새 폭으로 다시 wrap한다(이 줄엔 커서가 없다).
        // 논리 줄 시작이면 leader의 exit를 잡는다 — 이 줄의 첫 산출 행에만 실린다(아래 finalize).
        if (old_r == 0 or !self.screen.wrapped[old_r - 1]) rewrap_exit = self.screen.prompt_marks[old_r].exit;
        const soft = self.screen.wrapped[old_r];
        // 기여 길이: soft 행은 **쓴 칸까지**(넓히는 resize가 남긴 wrap 채움을 내용으로 삼지 않게),
        // hard 행은 뒤 빈칸을 잘라낸 길이.
        const contrib: u16 = if (soft) paintedRowLen(self, old_r) else trimmedRowLen(self, old_r);

        var c: u16 = 0;
        while (c < contrib) : (c += 1) {
            const cell = self.screen.cells[self.index(old_r, c)];
            // wide glyph base가 출력 행 끝에 안 들어가면(continuation과 분리 방지) 먼저 soft flush.
            const needs: u16 = if (cell.width == 2) 2 else 1;
            if (oc + needs > new_cols) {
                swrap[out_rows] = true;
                // 분류는 줄 전체 동일, exit는 첫 산출 행에만(아래 rewrap_exit 소비).
                pmarks[out_rows] = .{ .kind = self.screen.prompt_marks[old_r].kind, .exit = rewrap_exit };
                rewrap_exit = null;
                out_rows += 1;
                oc = 0;
                @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
            }
            scratch[out_rows * new_cols + oc] = cell;
            oc += 1;
        }
        if (!soft) {
            // 논리 줄 끝: 부분 출력 행을 hard(wrapped=false)로 닫는다.
            swrap[out_rows] = false;
            pmarks[out_rows] = .{ .kind = self.screen.prompt_marks[old_r].kind, .exit = rewrap_exit };
            rewrap_exit = null;
            out_rows += 1;
            oc = 0;
            @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
        }
        old_r += 1;
    }
    if (oc > 0) { // soft로 끝났는데 더 옛 행이 없음(방어)
        swrap[out_rows] = false;
        pmarks[out_rows] = .{ .kind = self.screen.prompt_marks[old_rows - 1].kind, .exit = rewrap_exit };
        out_rows += 1;
    }

    // 콘텐츠 아래 빈 출력 행(빈 옛 행에서 나온 것)을 잘라낸다. 단 커서 행까지는 남긴다.
    var content_len = out_rows;
    while (content_len > 0) {
        const r = content_len - 1;
        if (cursor_out_row) |cr| {
            if (r <= cr) break;
        }
        if (swrap[r]) break;
        if (!outputRowBlank(scratch, r, new_cols)) break;
        content_len -= 1;
    }

    // 그리드보다 높으면 위(오래된)를 스크롤백으로 밀어낸다. 커서가 콘텐츠 아래면 그 행까지 포함.
    const occupied = if (cursor_out_row) |cr| @max(content_len, cr + 1) else content_len;
    const drop: usize = if (occupied > new_rows) occupied - new_rows else 0;
    const push_count = @min(drop, content_len);

    const next_cells = try self.allocator.alloc(types.Cell, core.cellCount(next_size));
    errdefer self.allocator.free(next_cells);
    @memset(next_cells, .{});
    const next_wrapped = try self.allocator.alloc(bool, new_rows);
    errdefer self.allocator.free(next_wrapped); // 아래 next_prompt_marks alloc 실패 시 누수 방지
    @memset(next_wrapped, false);
    // OSC 133 태그를 reflow 산출 행(pmarks)에서 carry한다 — resize 후에도 프롬프트/입력/출력 분류가
    // 보존된다(논리 줄은 단일 분류라 옛 행 태그를 그대로 옮긴다, PR1의 .unknown 한계 제거).
    const next_prompt_marks = try self.allocator.alloc(types.RowPrompt, new_rows);
    @memset(next_prompt_marks, .{});

    // 밀려나는 위쪽 콘텐츠 행을 그 wrap 플래그·OSC 133 태그와 함께 스크롤백으로(가장 오래된 것부터).
    // 빈 행은 스크롤백을 오염시키므로 보관하지 않는다(빈 화면 resize 등).
    var pr: usize = 0;
    while (pr < push_count) : (pr += 1) {
        if (!outputRowBlank(scratch, pr, new_cols)) {
            const pushed = pushScrollback(self, scratch[pr * new_cols ..][0..new_cols], swrap[pr], pmarks[pr]);
            // 과거를 보는 중이면 새로 밀려든 행만큼 offset도 올린다(scroll-lock — 보던 내용 유지).
            if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.screen.sb.count);
        }
    }

    // 남은 콘텐츠 행을 새 그리드 위쪽에 채운다.
    var dst: usize = 0;
    var src: usize = drop;
    while (src < content_len and dst < new_rows) {
        @memcpy(next_cells[dst * new_cols ..][0..new_cols], scratch[src * new_cols ..][0..new_cols]);
        next_wrapped[dst] = swrap[src];
        next_prompt_marks[dst] = pmarks[src]; // 화면에 남는 행의 태그도 carry
        dst += 1;
        src += 1;
    }

    self.allocator.free(self.screen.cells);
    if (self.screen.wrapped.len > 0) self.allocator.free(self.screen.wrapped);
    if (self.screen.prompt_marks.len > 0) self.allocator.free(self.screen.prompt_marks);
    self.size = next_size;
    self.screen.cells = next_cells;
    self.screen.wrapped = next_wrapped;
    self.screen.prompt_marks = next_prompt_marks;
    rebuildTabstops(self, old_cols); // 탭스톱을 새 cols에 맞춘다(겹침 보존·새 열 8칸 기본).
    // semantic_state(진행 중 영역)는 유지한다 — 커서 줄(보통 활성 프롬프트/입력)이 verbatim으로
    // 보존되므로, resize 후 첫 lineFeed가 같은 영역을 이어 전파해야 한다(reset하면 분류가 끊긴다).
    // scroll region margin은 화면 크기에 묶이므로 resize 때 전체로 리셋한다(xterm 동작).
    self.scroll_top = 0;
    self.scroll_bottom = new_rows - 1;

    // 커서 재배치: 기록한 출력 위치에서 스크롤아웃된 행 수를 빼고 grid 안으로 clamp.
    if (cursor_out_row) |cr_raw| {
        const r = cr_raw -| drop;
        self.screen.cursor.row = @intCast(@min(r, @as(usize, new_rows - 1)));
        self.screen.cursor.col = @min(cursor_out_col, new_cols - 1);
    } else {
        self.screen.cursor.row = @min(self.screen.cursor.row, new_rows - 1);
        self.screen.cursor.col = @min(self.screen.cursor.col, new_cols - 1);
    }

    // 스크롤 위치는 유지한다(과거를 보는 중이었으면 위의 anchored 재-wrap이 offset을 새 행
    // 수 기준으로 보정했고, 아래 overflow push의 scroll-lock 보정이 이어진다). 범위만 방어.
    self.view_offset = @min(self.view_offset, self.screen.sb.count);
    self.dirty = core.fullDirty(next_size);
    // 옛 grid 좌표에 묶인 상태(grapheme run, deferred wrap)만 끊는다. CSI 파서 상태와
    // partial UTF-8 꼬리는 grid와 무관한 바이트 스트림 상태라 유지한다 — 리셋하면 PTY read
    // 경계로 쪼개진 시퀀스 한가운데에 resize가 끼었을 때 꼬리 바이트가 글자로 새고 SGR이
    // 유실된다(xterm도 resize에 파서를 리셋하지 않는다).
    self.screen.last_print = null;
    self.screen.pending_wrap = false;
}

// ── snapshot / viewport 합성 (렌더 출력) ────────────────────────────────────────────────────────
// 렌더러가 소비하는 RenderSnapshot을 만든다. 바닥(view_offset==0)이면 활성 grid를 zero-copy로 빌려주고,
// 위로 스크롤 중이면 뷰포트 윈도([스크롤백 ++ 활성])를 viewport_cells에 합성한다. IME preedit은 이 base
// snapshot을 받은 Surface projection이 별도 scratch에 합성한다. snapshot/renderSnapshot은 외부(app/session/renderer)가 점-호출하므로 core에
// facade 메서드로 남고 본문만 여기 있다. kitty placement/image view(buildPlacementViews/buildImageViews)와
// viewport 접근자(viewportRow/viewportRowPrompt)는 core 잔류 — self.X(pub)로 호출한다.

pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
    var cursor = self.screen.cursor;
    cursor.visible = cursor.visible and self.cursor_visible; // DECTCEM(?25l)이면 숨김
    return .{
        .size = self.size,
        .cursor = cursor,
        .ambiguous_wide = self.ambiguous_wide,
        .cursor_shape = self.cursor_shape,
        .cursor_blink = self.cursor_blink,
        .cells = self.screen.cells,
        .graphemes = self.grapheme_store.items, // cluster 본체 store를 zero-copy로 빌려준다(id로 참조)
        .prompt_marks = self.screen.prompt_marks, // 활성 화면 행 태그를 그대로 빌려준다(zero-copy)
        .last_command_exit = self.last_command_exit,
        .scrollback_len = self.screen.sb.count, // 스크롤바 thumb 근거(원격은 host가 wire로 실어 준다)
        .view_offset = self.view_offset,
        .dirty = self.dirty,
    };
}

/// 렌더용 snapshot. 바닥(view_offset==0)이면 snapshot()과 같다(합성 없음 — 일반 경로). 위로
/// 스크롤한 상태면 뷰포트 윈도([스크롤백 ++ 활성])를 viewport_cells에 합성해 돌려준다. 스크롤백
/// 행이 현재 폭과 다르면(resize) 폭에 맞춰 clamp/pad한다. 과거를 보는 중엔 커서를 숨긴다.
/// 합성 버퍼는 스크롤 중에만 lazy 할당하므로 일반(바닥) 렌더 경로는 추가 비용이 없다.
pub fn renderSnapshot(self: *TerminalCore) types.RenderSnapshot {
    if (self.view_offset == 0) {
        // 바닥(스크롤 안 함)에서는 활성 화면이 최상단 — top_abs = sb_count(활성 행의 절대 시작).
        var snap = snapshot(self);
        snap.placements = self.buildPlacementViews(self.screen.sb.count);
        snap.images = self.buildImageViews();
        return snap;
    }
    ensureScrollbackRewrapped(self); // 과거가 보이는 합성 직전, 행들을 현재 폭으로

    const needed = core.cellCount(self.size);
    if (self.viewport_cells.len != needed) {
        if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
        self.viewport_cells = self.allocator.alloc(types.Cell, needed) catch {
            self.viewport_cells = &.{};
            return snapshot(self); // OOM이면 활성 화면으로 폴백(스크롤 뷰 포기)
        };
    }
    // 행별 OSC 133 태그도 보이는 윈도에 맞춰 합성한다(viewport_cells와 병렬, rows 길이).
    if (self.viewport_prompt_marks.len != self.size.rows) {
        if (self.viewport_prompt_marks.len > 0) self.allocator.free(self.viewport_prompt_marks);
        self.viewport_prompt_marks = self.allocator.alloc(types.RowPrompt, self.size.rows) catch {
            self.viewport_prompt_marks = &.{};
            return snapshot(self);
        };
    }

    const cols = self.size.cols;
    var r: u16 = 0;
    while (r < self.size.rows) : (r += 1) {
        const src = self.viewportRow(r);
        const dst = self.viewport_cells[@as(usize, r) * cols ..][0..cols];
        const n = @min(src.len, cols);
        @memcpy(dst[0..n], src[0..n]);
        if (n < cols) @memset(dst[n..cols], .{});
        // 스크롤백 행이 현재 폭보다 넓게 저장돼 clip되면 마지막 칸의 wide glyph base가 잘려
        // half-glyph로 렌더될 수 있다 — resize 경로와 같은 정리를 적용한다.
        clearTruncatedWideBase(dst);
        self.viewport_prompt_marks[r] = self.viewportRowPrompt(r);
    }

    // 위로 스크롤한 뷰포트의 최상단 절대 행 — clipAbsSpanToViewport와 같은 식.
    const top_abs = self.screen.sb.count - @min(self.view_offset, self.screen.sb.count);
    return .{
        .size = self.size,
        // 과거를 보는 중엔 활성 커서를 그리지는 않되 canonical live 위치(row/col)는 보존한다.
        // IME 후보창은 scroll-to-bottom 명령이 적용되기 전에도 이 anchor를 즉시 써야 한다.
        .cursor = .{ .row = self.screen.cursor.row, .col = self.screen.cursor.col, .visible = false },
        .viewport_scrolled = true,
        .ambiguous_wide = self.ambiguous_wide,
        .cells = self.viewport_cells,
        // grapheme store는 코어 전역(활성·스크롤백 셀이 같은 id 공간을 공유)이라 합성 뷰포트도 그대로 빌려준다.
        .graphemes = self.grapheme_store.items,
        .prompt_marks = self.viewport_prompt_marks,
        .last_command_exit = self.last_command_exit,
        .placements = self.buildPlacementViews(top_abs),
        .images = self.buildImageViews(),
        .dirty = self.dirty,
        // **스크롤 중에도 스크롤바 근거를 싣는다.** 이 둘이 빠져 기본값 0으로 나가던 것이
        // 「스크롤하면 스크롤바가 사라진다」의 원인이었다 — 바닥 갈래는 `snapshot()` 을 쓰므로
        // 채워지는데, 위로 올라간 갈래만 이 자리에서 누락돼 `scrollbarThumbGeom` 이
        // `sb_count == 0` 으로 null 을 냈다(2026-08-30 실측: 바닥 sb=235 / 스크롤 중 sb=0).
        .scrollback_len = self.screen.sb.count,
        .view_offset = self.view_offset,
    };
}
