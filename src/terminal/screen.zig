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
