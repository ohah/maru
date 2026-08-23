/**
 * wasm 모듈이 노출하는 export의 타입. `src/platform/wasm/wasm_bridge.zig`와 **시그니처를 함께**
 * 바꿔야 한다 — 한쪽만 고치면 링크는 되고 값만 어긋난다.
 *
 * 규약: 큰 값은 반환하지 않고 모듈 스코프 버퍼에 쓴 뒤 길이만 돌려준다. 호출자는 `*_ptr()`로
 * 시작 주소를 받아 `memory.buffer`를 직접 읽는다(복사 0).
 */
export interface WasmExports {
  memory: WebAssembly.Memory;

  /** 입력 바이트를 쓰는 자리. `vt_write`/`vt_paste`/`measure_cells`가 여기서 읽는다. */
  input_ptr(): number;
  /** 입력 버퍼 용량(바이트). 이걸 넘겨 쓰면 인접 정적 버퍼를 덮어쓴다. */
  input_cap(): number;
  /** 셀 스냅샷이 쓰이는 자리. 셀당 20바이트 레코드. */
  cells_ptr(): number;
  /** 스냅샷이 담을 수 있는 최대 셀 수. 격자가 넘으면 아래쪽이 잘린다. */
  cells_cap(): number;
  /** 프로시저럴 글리프 커버리지(RGBA). */
  glyph_ptr(): number;
  /** OSC 8 URI와 창 제목이 공유하는 자리. */
  link_ptr(): number;
  /** 인코딩된 키 바이트. */
  key_ptr(): number;
  /** 선택 span 5워드: [startRow, startCol, endRow, endCol, block]. */
  sel_ptr(): number;
  /** 호스트로 보낼 응답(DA·CPR·OSC 질의). */
  resp_ptr(): number;
  /** bracketed paste로 감싼 결과. */
  paste_ptr(): number;
  /** 현재 선형 메모리 크기(바이트). */
  mem_bytes(): number;

  vt_new(cols: number, rows: number): number;
  vt_free(h: number): void;
  vt_write(h: number, len: number): number;
  vt_resize(h: number, cols: number, rows: number): number;
  /** 셀 수를 반환하고 `cells_ptr()`에 레코드를 채운다. */
  vt_snapshot(h: number): number;
  /** `(row << 16) | col` */
  vt_cursor(h: number): number;
  /** `shape | blink << 8 | visible << 9` (shape: 0=block 1=underline 2=bar) */
  vt_cursor_style(h: number): number;
  /** bracketed=1, appCursor=2, appKeypad=4, ambiguousWide=8, mouseTracking=상위 바이트 */
  vt_modes(h: number): number;

  vt_scroll(h: number, deltaUp: number): void;
  vt_scroll_bottom(h: number): void;
  /** 바닥에서 위로 올라간 행 수. 절단 없음 — `scrollToLine` 이 델타 계산에 쓴다. */
  vt_view_offset(h: number): number;
  /** 스크롤백에 쌓인 행 수 = `vt_view_offset` 의 최대값. */
  vt_scrollback_len(h: number): number;
  /** 화면을 지운다. 반환 1은 셸에 `\x0c`(^L)를 보내야 한다는 뜻. */
  vt_clear(h: number): number;

  /** `input_ptr()` 의 needle 로 검색. **반환은 총 매치 수**, 버퍼엔 `matches_cap()` 건까지. */
  vt_find(h: number, needleLen: number): number;
  /** 매치 버퍼 — 한 건이 `[startRow, startCol, endRow, endCol]` u32 넷. */
  match_ptr(): number;
  matches_cap(): number;

  /** 인코딩 길이를 반환하고 `key_ptr()`에 바이트를 채운다. 0이면 보낼 것이 없다. */
  vt_key(h: number, kind: number, cp: number, mods: number): number;
  vt_paste(h: number, len: number): number;
  vt_report_mouse(
    h: number,
    button: number,
    col: number,
    row: number,
    pressed: number,
    motion: number,
    mods: number,
  ): void;
  vt_report_focus(h: number, gained: number): void;

  vt_response(h: number): number;
  vt_clear_response(h: number): void;
  vt_title(h: number): number;
  vt_take_bell(h: number): number;

  sel_start(h: number, row: number, col: number): void;
  sel_extend(h: number, row: number, col: number): void;
  sel_word(h: number, row: number, col: number): void;
  sel_line(h: number, row: number): void;
  sel_all(h: number): void;
  sel_clear(h: number): void;
  /** `sel_start` **직후에만** 유효하다 — start가 block 플래그를 false로 리셋한다. */
  sel_block(h: number, on: number): void;
  /** 선택이 있으면 1을 반환하고 `sel_ptr()`에 5워드를 채운다. */
  sel_span(h: number): number;
  /** 선택 텍스트를 `paste_ptr()`에 쓰고 길이를 반환한다. 코어가 grapheme·soft-wrap을 풀어준다. */
  sel_text(h: number): number;
  /** OSC 8 링크 id로 URI를 `link_ptr()`에 쓰고 길이를 반환한다. 자동 감지는 지원하지 않는다. */
  link_uri(h: number, id: number): number;

  vt_set_ambiguous_wide(h: number, on: number): void;
  vt_set_max_scrollback(h: number, lines: number): void;
  vt_set_cursor_shape(h: number, shape: number): void;
  vt_set_default_colors(h: number, fg: number, bg: number): void;
  vt_palette_slot(idx: number, rgb: number, present: number): void;
  vt_apply_palette(h: number): void;

  /** 단일 코드포인트의 셀 폭(EAW). grapheme cluster는 `measure_cells`를 쓴다. */
  cell_width(cp: number): number;
  /** `input_ptr()`의 UTF-8을 써서 잰 셀 폭. cluster·EAW가 모두 반영된다. */
  measure_cells(len: number): number;
  /** `measure_cells` 가 폭을 셀 수 없을 때 돌려주는 값. */
  measure_overflow_value(): number;
  /** `(isCluster << 24) | baseCodepoint` */
  measure_first_cell(len: number): number;
  /** 이 코드포인트를 코어가 직접 그리는가(1/0). 폰트보다 먼저 묻는다. */
  glyph_covers(cp: number): number;
  /** 커버리지 픽셀 수를 반환하고 `glyph_ptr()`에 RGBA를 채운다. */
  glyph_box(cp: number, w: number, h: number): number;
}

/** 셀 레코드 한 칸의 바이트 수. `wasm_bridge.zig`의 `vt_snapshot`과 맞물린다. */
export const CELL_STRIDE = 20;

/** 셀 flags 비트. 하위 2비트는 폭이다. */
export const CellFlag = {
  widthMask: 0b11,
  bold: 1 << 4,
  italic: 1 << 5,
  underline: 1 << 6,
  reverse: 1 << 7,
  continuation: 1 << 8,
  link: 1 << 9,
} as const;
