//! 화면 storage — 스크롤백 ring buffer(`Scrollback`).
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면/스크롤백 저장 + host-reply를 한 struct에 섞은 구조 위반
//! (docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어내는 storage 1단계다. OSC(host-reply)는
//! osc.zig로 분리했고, 여기는 "storage" 책임을 모은다. `Scrollback`은 이미 self-contained 서브-struct라
//! (architecture.md가 가리킨 자연스러운 seam) types만 의존하고 `TerminalCore`를 참조하지 않는다.
//! facade(terminal.zig)·`TerminalCore` struct는 불변 — core.zig가 이 타입을 import해 `sb`/`saved_sb` 필드로 쓴다.
//! 점진 분리: 활성 화면 storage/연산 추출이 진행 중이다 — tabstops(G4 동적 탭스톱)부터 이리로 모은다(8/N~,
//! docs/terminal-core-decomposition.md). 각 연산은 `*TerminalCore`를 받는 free 함수다(필드 직접 접근 — Zig는
//! 필드 privacy가 없다; osc.zig·parser.zig와 동형). core↔screen 순환 import은 그 둘이 이미 검증한 그래프다.

const std = @import("std");
const types = @import("types.zig");
const core = @import("core.zig"); // 활성 화면 연산이 *TerminalCore를 받는다(Scrollback struct는 여전히 types만 의존)
const width = @import("../width.zig"); // EAW 셀 폭(중립 top-level 유틸) — wide 이모지 판정에 쓴다

const TerminalCore = core.TerminalCore;

/// 한 화면(primary/alt)의 스크롤백 ring buffer. `ring`/`wrapped`/`prompt_marks`는 같은 길이의 병렬 배열로
/// `(head+i)%len`로 인덱싱한다(pushScrollback이 함께 할당). 슬롯 cell 버퍼는 lazy 할당이라 빈 슬롯은 null이다.
/// **핵심 불변식**: alt 화면은 `cap == 0`인 빈 인스턴스를 갖는다 — 그래서 `pushScrollback`이 무동작이고
/// 스크롤백 뷰포트가 잠긴다(분기 없이 모델로 떠받친다). 행 push/get/rewrap 로직은 TerminalCore가 이 필드들을
/// 직접 다루고(cross-file 필드 접근), 이 struct는 메모리 수명(free/cap 재구성)만 소유한다.
pub const Scrollback = struct {
    ring: []?[]types.Cell = &.{},
    wrapped: []bool = &.{},
    prompt_marks: []types.RowPrompt = &.{},
    head: usize = 0,
    count: usize = 0,
    cap: usize = 0,
    // 재-wrap 지연 마크. resize는 비싼 ring 재구성을 즉시 하지 않고 이 플래그만 세우고, 과거를 실제로
    // 보는 순간(scrollViewport/renderSnapshot)에 현재 폭으로 1회 수행한다.
    rewrap_pending: bool = false,

    /// ring 슬롯의 행 버퍼를 모두 해제하고 null로 비운다(슬롯 배열 자체는 유지 — 재사용 경로용).
    /// deinit·clearScrollback·rewrapScrollbackInner이 공유한다(같은 free 루프 3벌 중복 제거).
    pub fn freeSlots(self: *Scrollback, allocator: std.mem.Allocator) void {
        for (self.ring) |*slot| {
            if (slot.*) |cells_row| {
                allocator.free(cells_row);
                slot.* = null;
            }
        }
    }

    pub fn deinit(self: *Scrollback, allocator: std.mem.Allocator) void {
        self.freeSlots(allocator);
        if (self.ring.len > 0) allocator.free(self.ring);
        if (self.wrapped.len > 0) allocator.free(self.wrapped);
        if (self.prompt_marks.len > 0) allocator.free(self.prompt_marks);
    }

    /// 용량을 바꾼다. cap을 갱신하고, ring이 할당돼 있으면 새 cap 크기로 **재구성**한다 — 가장 최근
    /// min(count, new_cap)개 행을 보존하고, 넘치는 가장 오래된 행은 행 버퍼까지 해제한다. 이로써
    /// ring.len이 항상 cap을 따라가 cap>ring.len(rewrap OOB의 전제)이 생기지 않고, 런타임 config 변경이
    /// 상향(더 보관)·하향(즉시 트림 + 메모리 회수) 양쪽으로 즉시 반영된다.
    ///
    /// **버려진(가장 오래된) 행 수를 반환**한다 — 호출자(setMaxScrollback)가 그만큼 abs 좌표
    /// (선택·kitty placement·view_offset)를 당겨야 한다(eviction과 동일 규율). 행을 안 버리는
    /// 상향/동일은 0을 반환해 좌표 보정이 불필요하다. 미할당이면 cap만 바꾸고 0(다음 lazy push가
    /// new_cap로 잡음). OOM이면 옛 ring을 유지하고 0(best-effort — rewrap의 ring.len clamp가 안전망).
    pub fn setCap(self: *Scrollback, allocator: std.mem.Allocator, new_cap: usize) usize {
        if (self.ring.len == 0 or self.ring.len == new_cap) { // 미할당·동일 크기 — cap만 갱신(드랍 없음)
            self.cap = new_cap;
            return 0;
        }
        const keep = @min(self.count, new_cap);
        const drop = self.count - keep; // 버릴 가장 오래된 행 수(논리 [0, drop))
        if (new_cap == 0) { // 스크롤백 끄기 — 행·배열 전부 해제(cap=0은 Scrollback 기본값)
            self.deinit(allocator);
            self.* = .{};
            return drop;
        }
        // 세 배열을 먼저 확보한다 — 하나라도 OOM이면 옛 ring·cap을 그대로 두고(일관성 유지) 0을 반환한다.
        // cap을 미리 바꾸지 않으므로 OOM이 cap>ring.len 같은 불일치를 남기지 않는다(rewrap의 ring.len
        // clamp는 그래도 OOB 안전망으로 유지).
        const new_ring = allocator.alloc(?[]types.Cell, new_cap) catch return 0;
        const new_wrapped = allocator.alloc(bool, new_cap) catch {
            allocator.free(new_ring);
            return 0;
        };
        const new_pmarks = allocator.alloc(types.RowPrompt, new_cap) catch {
            allocator.free(new_ring);
            allocator.free(new_wrapped);
            return 0;
        };
        @memset(new_ring, null);
        @memset(new_wrapped, false);
        @memset(new_pmarks, .{});
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const src = (self.head + i) % self.ring.len;
            if (i < drop) {
                if (self.ring[src]) |row| allocator.free(row); // 버려지는 가장 오래된 행
            } else {
                new_ring[i - drop] = self.ring[src];
                new_wrapped[i - drop] = self.wrapped[src];
                new_pmarks[i - drop] = self.prompt_marks[src];
            }
        }
        allocator.free(self.ring);
        allocator.free(self.wrapped);
        allocator.free(self.prompt_marks);
        self.ring = new_ring;
        self.wrapped = new_wrapped;
        self.prompt_marks = new_pmarks;
        self.head = 0;
        self.count = keep;
        self.cap = new_cap; // 성공 경로에서만 cap 확정(OOM 시 옛 cap 유지 — 위 catch return 0)
        return drop;
    }
};

// ── G4 동적 탭스톱 ───────────────────────────────────────────────────────────────────────────────
// col별 탭스톱(기본 8칸마다). HTS(ESC H)가 set, TBC(CSI g)가 clear, CBT(CSI Z)가 역방향 이동, HT(0x09)가
// 다음 탭스톱으로 전진. 길이는 cols와 맞춘다(resize가 재구성). 활성 화면 storage라 screen.zig로 모은다(8/N).
// core가 `self.tabstops`/`self.cursor`/`self.size` 필드를 직접 들고, 여기는 그 위의 연산만 제공한다.

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
    self.pending_wrap = false;
    // TAB은 grapheme run을 끊는다 — CR/LF/BS와 동일하게 last_print를 비워, 탭 뒤의 combining mark(또는 skin-tone·
    // RI 페어링)가 탭 이전 글자에 잘못 붙지 않게 한다. 이동 여부와 무관하게(이미 마지막 칸이어도) 컨트롤 처리 = run 종료다.
    self.last_print = null;
    if (self.size.cols == 0) return;
    const last = self.size.cols - 1;
    if (self.cursor.col >= last) return; // 이미 마지막 칸 — 이동 없음
    const old_cursor = self.cursor;
    var next = self.cursor.col + 1;
    while (next < last and !isTabstop(self, next)) next += 1; // 다음 탭스톱(없으면 마지막 칸)에 멈춤
    self.cursor.col = next;
    // 커서는 draw-time 오버레이라 이동 시 옛/새 칸을 모두 dirty로 마킹해야 한다 — markCursorMoveDirty 계약(\r·BS·CBT 등
    // 이 함수를 거치는 모든 이동)에 TAB도 포함시켜, 옛 칸의 커서 잔상이 안 남게 한다(cursorBackTab과 동일).
    markCursorMoveDirty(self, old_cursor, self.cursor); // 같은 파일(dirty 추적도 screen.zig)
}

/// CBT(CSI Ps Z): 역방향으로 Ps개 탭스톱 이동. 0번째 칸을 넘지 않는다.
pub fn cursorBackTab(self: *TerminalCore, count: u16) void {
    self.pending_wrap = false;
    self.last_print = null; // CBT도 커서 이동 — grapheme run을 끊는다(HT/CR/LF/BS와 동일).
    const old_cursor = self.cursor;
    var remaining = @max(count, 1);
    while (remaining > 0) : (remaining -= 1) {
        if (self.cursor.col == 0) break;
        var prev = self.cursor.col - 1;
        while (prev > 0 and !isTabstop(self, prev)) prev -= 1; // 이전 탭스톱(없으면 col 0)으로
        self.cursor.col = prev;
    }
    markCursorMoveDirty(self, old_cursor, self.cursor);
}

/// TBC(CSI Ps g): Ps=0(기본) 커서 열 탭스톱 제거, Ps=3 전체 제거. 그 외 Ps는 무시.
pub fn clearTabstop(self: *TerminalCore, mode: u16) void {
    switch (mode) {
        0 => if (self.cursor.col < self.tabstops.len) {
            self.tabstops[self.cursor.col] = false;
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
    self.pending_wrap = false;
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
// 스킨톤 modifier 부착·지역표시자(RI) 페어링·wide 이모지 승격 판정. putCell·promoteLastToEmojiWidth(print
// 경로, core 잔류)가 cross-file로 호출한다. last_print·cells·index(grid)에 의존한다.

pub fn isSkinToneModifier(codepoint: u21) bool {
    return codepoint >= 0x1F3FB and codepoint <= 0x1F3FF; // Fitzpatrick modifiers
}

pub fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF;
}

/// 직전 출력 셀이 짝 없는(아직 combining 안 붙은) wide 이모지 base인지 — 스킨톤 modifier를
/// 거기 붙이기 위함. combining이 이미 있으면(예: 국기의 2번째 RI) 거기에 스킨톤을 또 붙이면
/// 그 슬롯(하나뿐)을 덮어써 국기가 깨지므로 제외한다.
pub fn lastCellIsWideEmoji(self: *const TerminalCore) bool {
    const last = self.last_print orelse return false;
    const cell = self.cells[self.index(last.row, last.col)];
    // width 2를 wide emoji 대용으로 본다(스킨톤 modifier 부착 대상). 단 ambiguous-width=wide로 2칸이 된
    // 동그란 번호(isWideRenderSymbol)는 이모지가 아니라 스킨톤 부착 대상이 아니므로 제외 — 안 그러면 ③ 뒤
    // 스킨톤이 ③의 combining 슬롯에 잘못 병합된다(mode 2027).
    return cell.width == 2 and cell.combining == null and !width.isWideRenderSymbol(cell.codepoint);
}

/// 직전 출력 셀이 짝 없는(combining 안 붙은) 지역 표시자인지 — 다음 RI와 국기로 묶기 위함.
pub fn lastCellIsLoneRegionalIndicator(self: *const TerminalCore) bool {
    const last = self.last_print orelse return false;
    const cell = self.cells[self.index(last.row, last.col)];
    return isRegionalIndicator(cell.codepoint) and cell.combining == null;
}

/// wide glyph의 오른쪽 continuation 칸(0폭). base의 style/link를 물려받는다 — putCell과
/// promoteLastToEmojiWidth가 같은 표현을 쓰게 한다.
pub fn wideContinuationCell(style: types.Style, link: u32) types.Cell {
    return .{ .style = style, .width = 0, .continuation = true, .link = link };
}

// ── 스크롤백 행 저장·재-wrap ─────────────────────────────────────────────────────────────────────
// Scrollback ring에 행을 push하고, resize 시 새 폭으로 재-wrap하는 storage 로직(Scrollback struct와 짝).
// accessor(scrollbackRow/scrollbackRowWrapped/scrollbackRowPrompt)와 absRow/absRowWrapped는 core 잔류
// (facade·selection 공유 — 후속 accessor PR). 잔류 헬퍼(isBlankCell·clearTruncatedWideBase·invalidateSelection·
// shiftCoordsForEviction)는 core가 pub로 노출, 여기선 self./core.TerminalCore로 호출한다.

/// 스크롤백을 비운다(ED 3). 행 버퍼는 해제하고 ring 슬롯 배열은 유지해 다음 push가 재할당
/// 없이 다시 쓴다. 뷰포트는 바닥으로 스냅한다(지워진 과거를 보고 있을 수 없으니).
pub fn clearScrollback(self: *TerminalCore) void {
    self.sb.freeSlots(self.allocator);
    self.sb.head = 0;
    self.sb.count = 0;
    self.sb.rewrap_pending = false; // 비운 ring에 지연 재-wrap이 남을 이유 없다(상태 위생)
    self.view_offset = 0;
    self.invalidateSelection(); // 스크롤백을 지우면 abs 좌표가 무효 — 선택 해제(필드 주석의 약속)
}

/// 지연된 스크롤백 재-wrap을 지금 수행한다(있다면). 과거를 보는 경로(scrollViewport/
/// renderSnapshot)가 진입할 때 불러, 뷰가 항상 현재 폭 기준의 행 수/내용을 보게 한다.
pub fn ensureScrollbackRewrapped(self: *TerminalCore) void {
    if (!self.sb.rewrap_pending) return;
    self.sb.rewrap_pending = false;
    rewrapScrollback(self, self.size.cols);
}

/// 스크롤백 전체를 새 폭으로 재-wrap한다(resize 시). 활성 화면 reflow와 같은 규칙을 ring에
/// 적용한다: sb_wrapped로 논리 줄을 복원해 새 폭에 다시 자르고(hard 행 끝 빈칸은 trim, soft
/// 행은 저장 폭 전체가 내용), wide glyph base가 행 끝에 안 들어가면 먼저 줄을 넘긴다. 재-wrap
/// 행 수가 cap을 넘으면 가장 오래된 것부터 버린다. OOM이면 통째로 포기하고 기존 ring을
/// 유지한다(best-effort — 잘못된 절반 상태보다 옛 폭 표시가 낫다).
pub fn rewrapScrollback(self: *TerminalCore, new_cols: u16) void {
    if (self.sb.count == 0 or new_cols == 0) return;
    self.selectionClear(); // 행 좌표가 재배치된다 — 선택은 해제가 안전(다른 터미널도 동일)
    _ = rewrapScrollbackInner(self, new_cols, null) catch null;
}

/// 보던 위치(옛 스크롤백 행 anchor)를 유지하며 재-wrap한다. 과거를 보는 중 resize가 오면
/// 바닥으로 튕기지 않고, 그 행이 재-wrap 후 어느 행이 됐는지로 view_offset을 재계산한다
/// (Ghostty/iTerm2처럼 보던 내용이 그대로 보이게).
pub fn rewrapScrollbackAnchored(self: *TerminalCore, new_cols: u16, anchor_row: usize) void {
    if (self.sb.count == 0 or new_cols == 0) return;
    self.selectionClear(); // rewrapScrollback과 동일 — 좌표 재배치

    const new_anchor = rewrapScrollbackInner(self, new_cols, anchor_row) catch {
        // 재-wrap 실패(OOM): ring이 그대로이므로 offset도 그대로 유효하다.
        return;
    };
    if (new_anchor) |row_index| {
        // 뷰 최상단이 그 행을 다시 가리키게: viewportRow(0) = sb_count - view_offset.
        self.view_offset = @min(self.sb.count - @min(row_index, self.sb.count), self.sb.count);
    } else {
        // 앵커 행이 cap 드랍으로 사라졌다 — 남은 가장 오래된 행(맨 위)으로.
        self.view_offset = self.sb.count;
    }
}

fn rewrapScrollbackInner(self: *TerminalCore, new_cols: u16, anchor_row: ?usize) !?usize {
    // 1차 패스: 출력 행 수만 센다(할당/복사 없음). cap을 넘는 앞쪽(가장 오래된) 행들은 어차피
    // 버려지므로 2차 패스에서 아예 생성하지 않는다 — 좁힘 재-wrap의 alloc 비용을 절반 가까이
    // 줄인다(perf 게이트 scrollback_rewrap이 1회 비용을 잰다).
    var total_out: usize = 0;
    {
        var i: usize = 0;
        while (i < self.sb.count) {
            var j = i;
            while (j + 1 < self.sb.count and self.scrollbackRowWrapped(j)) j += 1;
            total_out += countRewrapRows(self, i, j, new_cols);
            i = j + 1;
        }
    }
    // 물리적 ring.len으로 묶는다(cap이 아니라) — setCap이 cap과 ring.len을 항상 같게 유지하지만,
    // 여기서 ring.len을 쓰면 cap이 어떤 경로로 ring보다 커져도 아래 ring[k] 쓰기가 OOB가 될 수 없다.
    // rewrap은 count>0일 때만 오므로 ring은 항상 할당돼 있다.
    const keep = @min(total_out, self.sb.ring.len);
    const skip = total_out - keep; // 생성 없이 건너뛸 산출 행 수(가장 오래된 쪽)

    var rows: std.ArrayList([]types.Cell) = .empty;
    var wraps: std.ArrayList(bool) = .empty;
    var pmarks: std.ArrayList(types.RowPrompt) = .empty; // 산출 행별 OSC 133 태그(rows와 병렬)
    // 성공 경로에선 행 소유권이 ring으로 넘어가므로(items.len = 0으로 비움), 이 defer는
    // 실패 경로에서만 만든 행들을 해제한다.
    defer {
        for (rows.items) |r| self.allocator.free(r);
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
    while (i < self.sb.count) {
        // 논리 줄 [i, j]: 연속된 soft-wrap 행 + 마지막 행.
        var j = i;
        while (j + 1 < self.sb.count and self.scrollbackRowWrapped(j)) j += 1;
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
            // soft 행은 저장 폭 전체가 내용(꽉 찼다는 뜻), hard(마지막) 행은 뒤 빈칸 trim.
            const contrib: usize = if (r < j) src.len else trimmedLen(src);
            var c: usize = 0;
            while (c < contrib) : (c += 1) {
                const cell = src[c];
                const needs: u16 = if (cell.width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    if (cur) |full| {
                        core.TerminalCore.clearTruncatedWideBase(full); // 마지막 칸의 잘린 wide base 정리(new_cols==1 등)
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
            core.TerminalCore.clearTruncatedWideBase(last);
            rows.appendAssumeCapacity(last);
            wraps.appendAssumeCapacity(tail_wrap);
            pmarks.appendAssumeCapacity(.{ .kind = line_tag.kind, .exit = line_exit });
            line_exit = null;
            cur = null;
        }
        emitted += 1;
        i = j + 1;
    }

    // 기존 ring 행을 비우고(슬롯 배열은 재사용) 새 행으로 채운다. ring이 아직 lazy 미할당이면
    // sb.count==0이라 여기 못 온다(가드).
    self.sb.freeSlots(self.allocator);
    for (rows.items, 0..) |row_cells, k| {
        self.sb.ring[k] = row_cells;
        self.sb.wrapped[k] = wraps.items[k];
        self.sb.prompt_marks[k] = pmarks.items[k]; // 재-wrap된 행과 정렬된 OSC 133 태그
    }
    self.sb.head = 0;
    self.sb.count = rows.items.len;
    // 소유권 이전 완료 — defer가 이중 해제하지 않게 목록을 비운다.
    rows.items.len = 0;

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
        const contrib: usize = if (r < last) src.len else trimmedLen(src);
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
    var len: usize = row.len;
    while (len > 0) : (len -= 1) {
        if (!core.TerminalCore.isBlankCell(row[len - 1])) break;
    }
    return len;
}

/// 행을 스크롤백에 보관한다. OOM 등으로 실제 보관에 실패하면 false — 호출자(scroll-lock)는
/// 보관된 경우에만 view_offset을 보정해야 보던 위치가 어긋나지 않는다.
pub fn pushScrollback(self: *TerminalCore, row_cells: []const types.Cell, wrapped_flag: bool, mark: types.RowPrompt) bool {
    if (self.sb.cap == 0) return false;
    if (self.sb.ring.len == 0) {
        const ring = self.allocator.alloc(?[]types.Cell, self.sb.cap) catch return false;
        @memset(ring, null);
        // wrap·semantic 병렬 ring도 함께 할당한다. 하나라도 실패하면 전부 포기해 세 ring 길이를
        // 항상 같게 유지한다((sb_head+i)%len 인덱싱이 어긋나면 안 된다).
        const wring = self.allocator.alloc(bool, self.sb.cap) catch {
            self.allocator.free(ring);
            return false;
        };
        @memset(wring, false);
        const pring = self.allocator.alloc(types.RowPrompt, self.sb.cap) catch {
            self.allocator.free(ring);
            self.allocator.free(wring);
            return false;
        };
        @memset(pring, .{});
        self.sb.ring = ring;
        self.sb.wrapped = wring;
        self.sb.prompt_marks = pring;
    }
    const cap = self.sb.ring.len;
    // 가득 차면 (sb_head+sb_count)%cap == sb_head라, 가장 오래된 슬롯을 재사용해 덮어쓴다.
    const idx = (self.sb.head + self.sb.count) % cap;
    if (self.sb.ring[idx]) |existing| {
        if (existing.len == row_cells.len) {
            @memcpy(existing, row_cells);
        } else {
            const dup = self.allocator.dupe(types.Cell, row_cells) catch return false; // OOM이면 옛 행 유지
            self.allocator.free(existing);
            self.sb.ring[idx] = dup;
        }
    } else {
        self.sb.ring[idx] = self.allocator.dupe(types.Cell, row_cells) catch return false;
    }
    self.sb.wrapped[idx] = wrapped_flag;
    self.sb.prompt_marks[idx] = mark;
    if (self.sb.count == cap) {
        self.sb.head = (self.sb.head + 1) % cap;
        // ring이 가득 차 가장 오래된 행이 밀려나면 절대 행 좌표가 한 칸 당겨진다 — 선택·placement
        // anchor를 같이 보정한다(밀려난 행에 걸리면 선택 해제·placement 제거). count는 불변(ring-full)
        // 이라 view_offset 클램프는 불필요.
        self.shiftCoordsForEviction(1);
    } else {
        self.sb.count += 1;
    }
    return true;
}

// ── 커서 이동/위치 ───────────────────────────────────────────────────────────────────────────────
// CUP/HVP/VPA·CUU..CUB·CHA·DECSCUSR·DECOM 등 커서를 옮기거나 모양을 바꾸는 연산. 명시적 이동은 모두
// markCursorMoveDirty로 옛/새 칸을 dirty 마킹하고 deferred wrap(pending_wrap)·grapheme run(last_print)을 끊는다.
// dispatchCsi(core 잔류, parser 후속)가 CSI 파라미터를 풀어 위임한다.

/// DECSCUSR(CSI Ps SP q): 커서 모양/깜빡임. 0|1=깜빡 block, 2=고정 block, 3=깜빡 underline,
/// 4=고정 underline, 5=깜빡 bar, 6=고정 bar. 모르는 값은 무시한다. vim이 모드 전환마다 보낸다.
pub fn setCursorStyle(self: *TerminalCore, param: u16) void {
    switch (param) {
        0, 1 => {
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
    markDirty(self, self.cursor.row); // 모양이 바뀐 커서 칸을 다시 그린다
}

pub fn cursorPosition(self: *TerminalCore) void {
    if (self.size.rows == 0 or self.size.cols == 0) return;
    const old = self.cursor;
    const row = self.csiParam(0, 1); // CSI 파라미터 접근(parser helper, core 잔류 — pub)
    const col = self.csiParam(1, 1);
    self.cursor.row = resolveRow(self, row); // DECOM이면 scroll region 상단 기준 + region 안 clamp
    self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
}

/// DECOM(DECSET/DECRST ?6) 적용. origin mode를 토글하고 커서를 origin home으로 옮긴다(xterm 동작 —
/// DECOM 변경 시 커서가 home으로). origin이면 scroll region 좌상단, 아니면 화면 좌상단.
pub fn setOriginMode(self: *TerminalCore, on: bool) void {
    self.origin_mode = on;
    const old = self.cursor;
    self.cursor = .{ .row = if (on) self.scroll_top else 0, .col = 0 };
    self.pending_wrap = false;
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
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
    const old = self.cursor;
    if (up) {
        self.cursor.row -|= amount;
    } else {
        const max_row = self.size.rows - 1;
        self.cursor.row = @intCast(@min(@as(u32, self.cursor.row) + amount, max_row));
    }
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
}

pub fn cursorHorizontal(self: *TerminalCore, amount: u16, right: bool) void {
    if (self.size.cols == 0) return;
    const old = self.cursor;
    if (right) {
        const max_col = self.size.cols - 1;
        self.cursor.col = @intCast(@min(@as(u32, self.cursor.col) + amount, max_col));
    } else {
        self.cursor.col -|= amount;
    }
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
}

pub fn cursorToColumn(self: *TerminalCore, col: u16) void {
    if (self.size.cols == 0) return;
    const old = self.cursor;
    self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
}

pub fn cursorToRow(self: *TerminalCore, row: u16) void {
    if (self.size.rows == 0) return;
    const old = self.cursor;
    // VPA(CSI Ps d)도 CUP/HVP처럼 DECOM origin 영향을 받는다(xterm/Ghostty 공통 — setCursorPos 단일 경로).
    self.cursor.row = resolveRow(self, row);
    markCursorMoveDirty(self, old, self.cursor);
    self.last_print = null;
}

/// 저장 커서를 새 grid 안으로 clamp한다. col이 잘려 더는 마지막 칸이 아니면 pending_wrap도 끈다
/// (deferred wrap은 "마지막 칸에 머무는 중"일 때만 유효한 상태다). DECSC/DECRC·1048/1049 저장 슬롯에 쓴다.
pub fn clampSavedCursor(slot: *core.SavedCursor, size: types.Size) void {
    const clamped_col = @min(slot.cursor.col, size.cols - 1);
    if (clamped_col != slot.cursor.col) slot.pending_wrap = false;
    slot.cursor.row = @min(slot.cursor.row, size.rows - 1);
    slot.cursor.col = clamped_col;
}
