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

// ── erase / insert / delete (행 내 셀 편집) ─────────────────────────────────────────────────────
// EL(K)·ECH(X)·ICH(@)·DCH(P)·ED(J). 모두 현재 pen 배경(BCE)으로 채우고, 경계에 걸친 wide glyph 반쪽을
// repairWideGlyphEdges로 정리하며, deferred autowrap(pending_wrap)·grapheme run(last_print)을 끊는다.
// dispatchCsi(core 잔류, parser 후속)와 putCell(insert_mode)이 위임한다.

/// erase로 [start, end) 범위를 비울 때, 경계에 걸친 wide glyph(width=2)의 반쪽을 정리한다.
/// clearCellForWrite가 쓰기 시 하던 짝 정리를 erase에도 적용해, 짝 잃은 base나 orphan
/// continuation이 남아 half-glyph로 그려지는 것을 막는다.
fn repairWideGlyphEdges(self: *TerminalCore, row: u16, start: u16, end: u16) void {
    const blank: types.Cell = .{ .style = self.pen };
    // 왼쪽 경계: start-1이 width=2 base면 그 continuation(start)이 지워졌으므로 base도 비운다.
    if (start > 0 and self.cells[self.index(row, start - 1)].width == 2) {
        self.cells[self.index(row, start - 1)] = blank;
    }
    // 오른쪽 경계: end가 continuation이면 그 base(end-1)가 지워졌으므로 continuation도 비운다.
    if (end < self.size.cols and self.cells[self.index(row, end)].continuation) {
        self.cells[self.index(row, end)] = blank;
    }
}

pub fn eraseInLine(self: *TerminalCore, mode: u16) void {
    const row = self.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start: u16 = switch (mode) {
        1, 2 => 0,
        else => self.cursor.col,
    };
    const end: u16 = switch (mode) {
        1 => @min(self.cursor.col + 1, self.size.cols),
        else => self.size.cols,
    };
    var col = start;
    while (col < end) : (col += 1) {
        // erase는 현재 pen의 배경색으로 채워야 하므로 blank cell에 style만 남긴다.
        self.cells[self.index(row, col)] = .{ .style = self.pen };
    }
    repairWideGlyphEdges(self, row, start, end);
    // 행의 오른쪽 끝을 지우면(mode 0=커서~끝, mode 2=전체) soft-wrap 연속성이 끊긴다. mode 1
    // (시작~커서)은 오른쪽 끝이 멀쩡해 줄이 여전히 다음 행으로 이어질 수 있으므로 wrapped를 끄지
    // 않는다 — 안 그러면 reflow가 한 논리 줄을 둘로 쪼갠다.
    if (mode != 1) self.wrapped[row] = false;
    markDirty(self, row);
    // 모든 EL 모드는 deferred autowrap을 무효화한다(xterm/Ghostty 동작). 안 끄면 마지막 칸
    // 출력(pending) 후 EL+글자 시퀀스가 한 줄 일찍 wrap돼 상대 커서 이동이 어긋난다.
    self.pending_wrap = false;
    // 다른 cursor/erase op과 같이 grapheme run을 끝낸다. 안 하면 CSI K 뒤 combining mark가
    // 방금 지운 셀에 붙는다.
    self.last_print = null;
}

/// ECH(CSI Ps X): 커서 위치부터 Ps개(기본 1) cell을 현재 pen 배경의 blank로 지운다. EL과 달리 줄 끝까지가
/// 아니라 N개만, DCH(CSI P)와 달리 뒤 cell을 당기지도 않는다(제자리 blank). **커서는 안 움직인다**.
/// 베이스: xterm `ECH`("Erase Ps Character(s)") — nvim이 모드 라벨(`-- INSERT --`)을 이 시퀀스로 지운다(EL 아님).
pub fn eraseCharacters(self: *TerminalCore, count: u16) void {
    const row = self.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.cursor.col;
    const end: u16 = @min(start +| @max(count, 1), self.size.cols);
    var col = start;
    while (col < end) : (col += 1) {
        // erase는 현재 pen의 배경색으로 채운다(blank cell + style만) — eraseInLine과 동일 규칙(bce).
        self.cells[self.index(row, col)] = .{ .style = self.pen };
    }
    repairWideGlyphEdges(self, row, start, end);
    markDirty(self, row);
    // ECH는 부분 erase라 soft-wrap flag를 끄지 않는다(EL mode 1과 같은 결 — 줄 끝이 남아 다음 행으로
    // 이어질 수 있다). deferred autowrap만 무효화(다른 erase op과 동일).
    self.pending_wrap = false;
    self.last_print = null;
}

/// ICH (CSI Ps @): 커서 위치에 Ps개(기본 1) 빈 칸을 삽입한다. 커서부터 줄 끝까지의 셀을 오른쪽으로
/// 밀고, 줄 끝을 넘는 셀은 버린다. 빈 칸은 현재 pen 배경(BCE — eraseCharacters와 동일 규칙). 커서
/// 위치는 불변. 베이스: ECMA-48 ICH / xterm ctlseqs `CSI Ps @`. 좌우 margin(DECSLRM) 미구현이라
/// 줄 전체에서 작동한다.
pub fn insertChars(self: *TerminalCore, count: u16) void {
    const row = self.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.cursor.col;
    if (start >= self.size.cols) return;
    const cols = self.size.cols;
    const n: u16 = @min(@max(count, 1), cols - start);
    const blank: types.Cell = .{ .style = self.pen };
    // 커서부터 오른쪽 셀을 n칸 오른쪽으로(역순 복사라 영역이 겹쳐도 안전). 줄 끝을 넘는 셀은 버린다.
    var col: u16 = cols;
    while (col > start + n) {
        col -= 1;
        self.cells[self.index(row, col)] = self.cells[self.index(row, col - n)];
    }
    // 삽입된 빈 칸.
    col = start;
    while (col < start + n) : (col += 1) self.cells[self.index(row, col)] = blank;
    // 왼쪽 경계에서 쪼개진 wide(start-1 base의 continuation이 밀려남)를 복구하고, 줄 끝으로 밀려
    // continuation이 줄 밖으로 나간 wide base를 비운다.
    repairWideGlyphEdges(self, row, start, cols);
    if (self.cells[self.index(row, cols - 1)].width == 2) self.cells[self.index(row, cols - 1)] = blank;
    markDirty(self, row);
    self.pending_wrap = false;
    self.last_print = null;
}

/// DCH (CSI Ps P): 커서 위치에서 Ps개(기본 1) 문자를 삭제한다. 커서 오른쪽 셀을 왼쪽으로 당기고,
/// 줄 끝의 빈 자리는 현재 pen 배경(BCE). 커서 위치는 불변. 베이스: ECMA-48 DCH / xterm `CSI Ps P`.
pub fn deleteChars(self: *TerminalCore, count: u16) void {
    const row = self.cursor.row;
    if (self.size.cols == 0 or row >= self.size.rows) return;
    const start = self.cursor.col;
    if (start >= self.size.cols) return;
    const cols = self.size.cols;
    const n: u16 = @min(@max(count, 1), cols - start);
    const blank: types.Cell = .{ .style = self.pen };
    // 커서 오른쪽 셀을 n칸 왼쪽으로 당긴다.
    var col = start;
    while (col + n < cols) : (col += 1) {
        self.cells[self.index(row, col)] = self.cells[self.index(row, col + n)];
    }
    // 줄 끝 n칸은 빈 칸.
    while (col < cols) : (col += 1) self.cells[self.index(row, col)] = blank;
    // 왼쪽 경계에서 쪼개진 wide(start-1 base)를 복구하고, 당겨와서 base를 잃은 continuation을 비운다.
    repairWideGlyphEdges(self, row, start, cols);
    if (self.cells[self.index(row, start)].continuation) self.cells[self.index(row, start)] = blank;
    markDirty(self, row);
    self.pending_wrap = false;
    self.last_print = null;
}

pub fn eraseInDisplay(self: *TerminalCore, mode: u16) void {
    if (self.size.rows == 0 or self.size.cols == 0) return;
    // 모든 ED 모드는 deferred autowrap을 무효화한다(EL과 동일한 이유, xterm/Ghostty 동작).
    self.pending_wrap = false;
    const blank: types.Cell = .{ .style = self.pen };
    switch (mode) {
        // 2/3: 화면 전체. 3(xterm E3)은 저장된 줄(스크롤백)까지 지운다 — `clear`가 보내는
        // \e[3J의 핵심 의미로, 비밀 출력 후 history를 비우는 용도다.
        2, 3 => {
            @memset(self.cells, blank);
            @memset(self.wrapped, false);
            @memset(self.prompt_marks, .{}); // 전체 clear는 OSC 133 분류도 지운다
            self.semantic_state = .unknown; // 진행 중 영역도 끝낸다(셸이 곧 프롬프트를 재마킹)
            if (mode == 3) clearScrollback(self);
            self.dirty = core.fullDirty(self.size);
        },
        // 1: 화면 시작 ~ 커서까지.
        1 => {
            const cursor_index = self.index(self.cursor.row, self.cursor.col);
            var i: usize = 0;
            while (i <= cursor_index and i < self.cells.len) : (i += 1) self.cells[i] = blank;
            for (0..@min(@as(usize, self.cursor.row) + 1, self.wrapped.len)) |r| self.wrapped[r] = false;
            repairWideGlyphEdges(self, self.cursor.row, 0, @min(self.cursor.col + 1, self.size.cols));
            // dirty를 덮어쓰지 않고 markDirty로 병합한다 — 같은 write()에서 앞서 dirty된 행
            // (예: 방금 출력한 아래쪽 행)을 잃어 렌더가 stale glyph를 남기지 않게 한다.
            markDirty(self, 0);
            markDirty(self, self.cursor.row);
        },
        // 0(기본): 커서 ~ 화면 끝까지.
        else => {
            const cursor_index = self.index(self.cursor.row, self.cursor.col);
            var i: usize = cursor_index;
            while (i < self.cells.len) : (i += 1) self.cells[i] = blank;
            for (self.cursor.row..self.size.rows) |r| self.wrapped[r] = false;
            repairWideGlyphEdges(self, self.cursor.row, self.cursor.col, self.size.cols);
            markDirty(self, self.cursor.row);
            markDirty(self, self.size.rows - 1);
        },
    }
    self.last_print = null;
}

// ── scroll / line feed (행 스크롤·줄 이동) ──────────────────────────────────────────────────────
// LF/IND·RI·SU/SD(scrollRange)·IL/DL·DECSTBM·DECALN. scroll region 안에서 행을 블록 이동하고, 화면 위로
// 나가는 줄만 스크롤백에 보관(pushScrollback). BCE로 새 빈 줄을 현재 pen 배경으로 채우고, wrap 경계·OSC 133
// 태그를 옮긴 내용과 함께 carry한다. dispatchCsi·write 루프·putCell(autowrap)이 위임한다.

/// DECALN(ESC # 8): 화면 전체를 'E'(기본 attr)로 채우고 커서를 home으로 보낸다. VT 정렬 진단(vttest) 전용.
pub fn decAlign(self: *TerminalCore) void {
    for (self.cells) |*c| c.* = .{ .codepoint = 'E', .width = 1 };
    @memset(self.wrapped, false);
    const old_cursor = self.cursor;
    self.cursor = .{};
    self.pending_wrap = false;
    self.last_print = null;
    markCursorMoveDirty(self, old_cursor, self.cursor);
    self.dirty = core.fullDirty(self.size);
}

pub fn lineFeed(self: *TerminalCore) void {
    if (self.size.rows == 0) return;
    // LF(및 IND)는 deferred autowrap을 무효화한다. 비-scroll 분기는 markCursorMoveDirty가
    // 끄지만, scroll 분기(scrollRegionUp)는 그걸 안 거치므로 여기서 한 번에 끈다. 안 그러면
    // 마지막 행이 꽉 찬(pending_wrap) 상태에서 bare LF가 와도 플래그가 남아, 다음 printable
    // 글자가 또 한 줄 내려가(scroll) 직전 줄을 잃는다(이중 스크롤).
    self.pending_wrap = false;
    // 스크롤/이동으로 grapheme run이 끝난다 — 다음 combining mark가 옮겨진 셀에 붙지 않게.
    // (\n 경로는 writeCodepoint가 이미 끊지만 ESC D(IND)는 이 함수로 직행한다.)
    self.last_print = null;
    // 커서가 scroll region 하단 margin이면 region을 위로 스크롤(커서는 그대로). 그 외엔 화면
    // 끝 전까지 한 줄 내려간다(region 위/아래 모두 동일). scrollRegionUp의 fullDirty가 커서
    // 행까지 다시 칠하므로 scroll 분기는 cursor-move diff가 따로 필요 없다.
    if (self.cursor.row == self.scroll_bottom) {
        scrollRegionUp(self);
        return;
    }
    if (self.cursor.row + 1 < self.size.rows) {
        const old_cursor = self.cursor;
        self.cursor.row += 1;
        markCursorMoveDirty(self, old_cursor, self.cursor);
        // OSC 133 영역이 활성이면(프롬프트/입력/출력) 다음 행에 전파한다 — 여러 줄 프롬프트·출력이
        // 전부 같은 분류로 태깅된다. unknown 상태에선 기존 태그를 지우지 않는다(분류 보존).
        if (self.semantic_state != .unknown) self.prompt_marks[self.cursor.row] = .{ .kind = self.semantic_state };
    }
}

/// RI(ESC M): 커서를 한 줄 올리고, scroll region 상단 margin이면 region을 아래로 스크롤한다.
pub fn reverseIndex(self: *TerminalCore) void {
    if (self.size.rows == 0) return;
    self.pending_wrap = false;
    self.last_print = null; // IND와 동일 — 스크롤/이동으로 grapheme run 종료
    if (self.cursor.row == self.scroll_top) {
        scrollRegionDown(self);
        return;
    }
    if (self.cursor.row > 0) {
        const old_cursor = self.cursor;
        self.cursor.row -= 1;
        markCursorMoveDirty(self, old_cursor, self.cursor);
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
            const pushed = pushScrollback(self, self.cells[self.index(top + pr, 0)..][0..self.size.cols], self.wrapped[top + pr], self.prompt_marks[top + pr]);
            // 과거를 보는 중(view_offset>0)이면 같은 내용을 계속 보도록 offset도 올린다
            // (scroll-lock). 보관 실패(OOM) 시엔 보정하지 않는다 — 뷰가 내용과 어긋나지 않게.
            if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.sb.count);
        }
    }

    var row: u16 = top + n;
    while (row <= bottom) : (row += 1) {
        const dst_start = self.index(row - n, 0);
        const src_start = self.index(row, 0);
        @memcpy(
            self.cells[dst_start .. dst_start + self.size.cols],
            self.cells[src_start .. src_start + self.size.cols],
        );
        self.wrapped[row - n] = self.wrapped[row];
        self.prompt_marks[row - n] = self.prompt_marks[row]; // 태그를 옮긴 내용과 함께 끌어온다
    }

    var blank_row: u16 = bottom + 1 - n;
    while (blank_row <= bottom) : (blank_row += 1) {
        const blank_start = self.index(blank_row, 0);
        // BCE(배경색 erase): 스크롤로 새로 들어오는 빈 줄은 현재 pen의 배경으로 채운다(EL/ED와 같은 규칙).
        // 베이스: xterm.js getNullCell이 erase 속성(fg+bg)을 carry — 우리도 full pen을 carry(default pen이면
        // 기존과 동일한 default blank). Ghostty는 bgCell()로 배경만 좁히는데, 우리는 EL/ED와의 내부 일관성을
        // 위해 full pen으로 통일한다(bg-only 정제는 후속). 색 배경 화면이 스크롤될 때 빈 줄이 그 색을 잇는다.
        @memset(self.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.pen });
        self.wrapped[blank_row] = false;
        self.prompt_marks[blank_row] = .{ .kind = if (lf_scroll) self.semantic_state else .unknown };
    }
    // 범위 경계의 wrap 정합: shift가 old wrapped[bottom]("old bottom ↔ bottom+1" — 범위 밖과의
    // 연속)을 bottom-n으로 끌어왔는데, bottom+1은 안 움직였으니 그 연속은 깨졌다. 마찬가지로
    // 범위 위 행(top-1)이 주장하던 "top으로의 연속"도 top 내용이 바뀌어 깨졌다. 안 끊으면
    // 다음 resize reflow가 무관한 줄(상태줄 등)을 한 논리 줄로 합친다.
    if (bottom + 1 >= n and bottom + 1 - n > top) self.wrapped[bottom - n] = false;
    if (top > 0) self.wrapped[top - 1] = false;
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
            self.cells[dst_start .. dst_start + self.size.cols],
            self.cells[src_start .. src_start + self.size.cols],
        );
        self.wrapped[row] = self.wrapped[row - n];
        self.prompt_marks[row] = self.prompt_marks[row - n]; // OSC 133 태그도 옮긴 내용과 함께(scrollRangeUp 대칭)
    }

    var blank_row: u16 = top;
    while (blank_row < top + n) : (blank_row += 1) {
        const blank_start = self.index(blank_row, 0);
        // BCE: 아래로 밀며 생기는 빈 줄(RI/IL)도 현재 pen 배경으로 채운다(scrollRangeUp과 같은 규칙).
        @memset(self.cells[blank_start .. blank_start + self.size.cols], .{ .style = self.pen });
        self.wrapped[blank_row] = false;
        self.prompt_marks[blank_row] = .{}; // 삽입된 빈 행은 비분류(잔여 태그 → 헛 거터 방지)
    }
    // 범위 경계의 wrap 정합(scrollRangeUp과 대칭): 새 bottom 행(=old bottom-n 내용)이 범위 밖
    // bottom+1로 이어진다는 플래그는 거짓이고, top-1 행의 "top으로의 연속"도 top이 빈 줄이 돼
    // 깨졌다.
    self.wrapped[bottom] = false;
    if (top > 0) self.wrapped[top - 1] = false;
    self.dirty = core.fullDirty(self.size);
}

/// IL(CSI Ps L): 커서 행에 빈 줄 n개를 삽입한다. 커서 행~region 하단이 아래로 밀리고 넘치는
/// 줄은 버려진다. 커서가 scroll region 밖이면 무시. 후처리로 커서를 행 첫 칸으로 옮긴다(CR —
/// xterm/DEC 동작). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스.
pub fn insertLines(self: *TerminalCore, count: u16) void {
    if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
    scrollRangeDown(self, self.cursor.row, self.scroll_bottom, count);
    self.pending_wrap = false;
    self.cursor.col = 0;
    self.last_print = null;
}

/// DL(CSI Ps M): 커서 행부터 n줄을 삭제한다. 아래 줄들이 올라오고 region 하단에 빈 줄이 생긴다.
/// 삭제된 줄은 history가 아니다(스크롤백에 안 넣음). 커서가 region 밖이면 무시, 후처리 CR.
pub fn deleteLines(self: *TerminalCore, count: u16) void {
    if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
    scrollRangeUp(self, self.cursor.row, self.scroll_bottom, count, false);
    self.pending_wrap = false;
    self.cursor.col = 0;
    self.last_print = null;
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
    const old_cursor = self.cursor;
    // DECSTBM 후 커서를 origin home으로 — DECOM이면 region 상단, 아니면 화면 좌상단(xterm 동작).
    self.cursor = .{ .row = if (self.origin_mode) self.scroll_top else 0, .col = 0 };
    self.pending_wrap = false;
    markCursorMoveDirty(self, old_cursor, self.cursor);
}

// ── alt screen + saved cursor (화면 전환·커서 저장/복원) ─────────────────────────────────────────
// DECSET 1049/47/1047(alt 전환)·1048/DECSC/DECRC·SCOSC/SCORC. alt 진입 시 primary grid·scrollback·커서를
// saved_* 슬롯으로 스왑하고 빈 alt 버퍼를 쓴다(alt는 cap=0 스크롤백 → history 안 쌓임). 복귀 시 되돌린다.
// dispatchCsi·setPrivateModes·handleEscapeByte·fullReset가 위임한다.

/// 현재 활성 화면의 DECSC 저장 슬롯. ESC 7/8과 1048은 항상 "지금 보이는 화면"의 슬롯을 쓴다
/// (xterm 동일). 1049의 enter(저장)/leave(복원)는 primary 슬롯을 쓴다 — 셸 커서를 보관했다가
/// TUI 종료 시 되돌리는 용도라서다.
fn activeSavedCursor(self: *TerminalCore) *core.SavedCursor {
    return if (self.alt_active) &self.saved_cursor_alt else &self.saved_cursor_primary;
}

pub fn saveCursorState(self: *TerminalCore) void {
    activeSavedCursor(self).* = .{
        .cursor = self.cursor,
        .pen = self.pen,
        .pending_wrap = self.pending_wrap,
    };
}

pub fn restoreCursorState(self: *TerminalCore) void {
    restoreFromSlot(self, activeSavedCursor(self).*);
}

fn restoreFromSlot(self: *TerminalCore, slot: core.SavedCursor) void {
    const old_cursor = self.cursor;
    self.cursor = .{
        .row = @min(slot.cursor.row, self.size.rows - 1),
        .col = @min(slot.cursor.col, self.size.cols - 1),
    };
    self.pen = slot.pen;
    markCursorMoveDirty(self, old_cursor, self.cursor);
    // markCursorMoveDirty가 deferred autowrap을 무효화(pending_wrap=false)하므로, 저장된 pending_wrap은
    // 그 '뒤'에 복원한다 — 줄 끝 deferred-wrap 상태에서 저장→복원하면 복원이 즉시 덮어써지던 버그
    // (DECSC/DECRC·CSI s/u가 공유하는 restoreFromSlot, code review).
    self.pending_wrap = slot.pending_wrap;
    self.last_print = null;
}

/// alt screen으로 전환한다. primary 그리드(cells/wrapped)를 saved_*로 옮기고 빈 alt 버퍼를
/// 만든다(1049는 들어가며 clear — TUI가 어차피 전체를 그린다). 할당 실패면 전환하지 않는다
/// (primary 유지가 안전 — 커서 저장도 두 할당이 성공한 뒤에 해 실패가 부작용 없게 한다).
/// 1049의 커서 저장은 이미 alt여도 수행한다(xterm: "unconditionally saves the cursor").
pub fn enterAltScreen(self: *TerminalCore, save_cursor: bool) void {
    if (self.alt_active) {
        // 화면은 이미 alt지만 1049h의 커서 저장 의미는 유지한다(중첩 멀티플렉서/SIGCONT 재초기화).
        if (save_cursor) saveCursorState(self);
        return;
    }

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

    // 세 할당이 성공한 뒤에야 상태를 바꾼다(OOM 경로가 저장 슬롯을 오염시키지 않게).
    if (save_cursor) saveCursorState(self); // primary 슬롯(아직 alt_active=false)
    self.saved_cells = self.cells;
    self.saved_wrapped = self.wrapped;
    self.saved_prompt_marks = self.prompt_marks; // primary의 OSC 133 분류 보관
    self.cells = alt_cells;
    self.wrapped = alt_wrapped;
    self.prompt_marks = alt_prompt_marks; // alt 화면은 셸 프롬프트 의미가 없다(전부 .unknown)
    self.semantic_state = .unknown; // alt 진입 — primary의 진행 중 영역을 이어받지 않는다
    self.alt_active = true;
    // primary 스크롤백을 보관 슬롯으로 옮기고 alt는 cap=0인 빈 스크롤백을 쓴다 — alt 출력은
    // history에 안 쌓이고(pushScrollback 무동작), count가 0이라 스크롤 뷰·스크롤바·검색이
    // by-construction으로 잠긴다(grid의 saved_cells 스왑과 같은 패턴). 보던 과거를 닫고 선택도
    // 해제한다(활성 cells가 alt로 바뀌어 abs 좌표가 다른 내용을 가리키므로 — xterm.js도 버퍼
    // 전환 시 선택 해제).
    self.saved_sb = self.sb;
    self.sb = .{};
    self.view_offset = 0;
    self.invalidateSelection();
    self.pen_link = 0; // OSC 8 링크는 화면에 스코프된다 — 전환 시 닫는다(Ghostty endHyperlink)
    self.pending_wrap = false;
    self.last_print = null;
    self.dirty = core.fullDirty(self.size);
}

/// primary screen으로 복귀한다. alt 버퍼를 버리고 saved 그리드를 복원한다. 1049는 커서도
/// primary 슬롯에서 복원해 vim 종료 시 프롬프트가 원래 자리로 돌아온다 — alt 안에서 TUI가
/// ESC 7/8을 써도(alt 슬롯) 셸 커서는 안전하다. 1049l의 커서 복원은 이미 primary여도
/// 수행한다(xterm 동작 — 방어적 `\e[?1049l` 정리 스크립트 호환).
pub fn leaveAltScreen(self: *TerminalCore, restore_cursor: bool) void {
    if (!self.alt_active) {
        if (restore_cursor) restoreFromSlot(self, self.saved_cursor_primary);
        return;
    }
    self.allocator.free(self.cells);
    self.allocator.free(self.wrapped);
    if (self.prompt_marks.len > 0) self.allocator.free(self.prompt_marks);
    self.cells = self.saved_cells;
    self.wrapped = self.saved_wrapped;
    self.prompt_marks = self.saved_prompt_marks; // primary 분류 복원
    self.saved_cells = &.{};
    self.saved_wrapped = &.{};
    self.saved_prompt_marks = &.{};
    self.sb.deinit(self.allocator); // alt의 빈 스크롤백 해제(보통 ring 미할당 — no-op)
    self.sb = self.saved_sb; // primary 스크롤백 복원(보관해 둔 ring·count·cap·rewrap 마크 그대로)
    self.saved_sb = .{};
    self.semantic_state = .unknown; // primary 복귀 — 진행 중 영역을 이어받지 않는다(다음 프롬프트가 재마킹)
    self.alt_active = false;
    self.pending_wrap = false;
    self.last_print = null;
    self.pen_link = 0; // 화면 전환 — 열린 링크를 닫는다(Ghostty endHyperlink)
    self.invalidateSelection(); // primary 복귀 — 활성 cells가 다시 바뀌므로 선택 해제
    if (restore_cursor) restoreFromSlot(self, self.saved_cursor_primary);
    self.dirty = core.fullDirty(self.size);
}
