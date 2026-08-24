import type { Disposable } from "./types";

/**
 * 버퍼의 한 줄을 가리키는 **안정적인 참조**.
 *
 * 절대 행(0 = 스크롤백 최상단)은 스크롤백이 가득 차 오래된 줄이 버려질 때마다 **앞으로
 * 밀린다** — 같은 줄이 10행이었다가 7행이 된다(실측). 코어는 selection·kitty placement 를
 * 스스로 보정하지만 라이브러리가 들고 있는 좌표는 그럴 수 없으므로, 프레임이 실어 오는
 * `evicted`(버려진 행의 누적 수)로 여기서 보정한다.
 *
 * 가리키던 줄이 버려지면 마커는 **스스로 dispose 된다** — `row` 가 음수가 되는 대신 사라져,
 * 소비자가 "없어진 줄"을 계속 가리키지 않게 한다.
 */
export interface Marker extends Disposable {
  /** 현재 절대 행. 버려졌으면 -1. */
  readonly row: number;
  readonly isDisposed: boolean;
  onDispose(cb: () => void): Disposable;
}

/** 한 마커 줄에 얹는 시각 장식. */
export interface DecorationOptions {
  marker: Marker;
  /** 시작 열(기본 0). */
  x?: number;
  /** 칠할 열 수. 생략하면 줄 끝까지. */
  width?: number;
  /** 배경색 `0xRRGGBB`. */
  backgroundColor?: number;
  /** 전경색 `0xRRGGBB`. 생략하면 글자 색을 바꾸지 않는다. */
  foregroundColor?: number;
  /** 0~1. 기본 0.4 — 글자가 읽히도록 반투명하게 깐다. */
  opacity?: number;
}

export interface Decoration extends Disposable {
  readonly marker: Marker;
  readonly isDisposed: boolean;
}

/** 렌더러가 한 프레임에 그릴 장식(뷰포트 좌표로 접힌 것). */
export interface DecorationSpan {
  row: number;
  x: number;
  width: number;
  backgroundColor?: number;
  foregroundColor?: number;
  opacity: number;
}

/**
 * 마커와 장식의 소유자. `Terminal` 이 하나 들고, 프레임마다 `sync()` 로 보정한 뒤
 * `spansFor()` 로 렌더러에 넘길 목록을 만든다.
 *
 * **DOM element 를 주지 않는다.** xterm.js 는 장식마다 `<div>` 를 얹어 소비자가 스타일링하게
 * 하지만, 여기서는 (1) 렌더가 워커에 있을 수 있어 DOM 을 만질 수 없고, (2) 검색 하이라이트처럼
 * 수천 개가 되는 용도가 주력이라 노드마다 DOM 을 만들면 감당이 안 된다. 대신 색을 받아
 * **렌더러가 칠한다** — 커스텀 UI 가 필요하면 소비자가 `onRender` 로 자기 오버레이를 그리면 된다.
 */
export class DecorationStore {
  #markers = new Set<MarkerImpl>();
  #decorations = new Set<DecorationImpl>();
  #lastEvicted = 0;
  /** 목록이 바뀌면 알린다 — 소유자가 화면을 다시 밀어야 한다(지운 장식이 남으면 안 된다). */
  #onChange: (() => void) | null = null;

  onChange(cb: () => void): void {
    this.#onChange = cb;
  }

  createMarker(row: number): Marker {
    const m = new MarkerImpl(row, (x) => this.#markers.delete(x));
    this.#markers.add(m);
    return m;
  }

  createDecoration(opts: DecorationOptions): Decoration | null {
    if (opts.marker.isDisposed) return null;
    const d = new DecorationImpl(opts, (x) => {
      this.#decorations.delete(x);
      this.#onChange?.();
    });
    this.#decorations.add(d);
    // 마커가 사라지면 장식도 함께 사라진다 — 가리킬 줄이 없으면 그릴 것도 없다.
    opts.marker.onDispose(() => d.dispose());
    return d;
  }

  /** 프레임의 `evicted` 로 마커 좌표를 당긴다. 버려진 줄의 마커는 dispose 된다. */
  sync(evicted: number): void {
    const delta = evicted - this.#lastEvicted;
    this.#lastEvicted = evicted;
    if (delta <= 0) return;
    for (const m of [...this.#markers]) m.shift(delta);
  }

  /** 뷰포트에 걸리는 장식만 뷰포트 좌표로 접어 돌려준다. */
  spansFor(
    scroll: { offset: number; length: number },
    cols: number,
    rows: number,
  ): DecorationSpan[] {
    // 화면 첫 줄의 절대 행 = 스크롤백 길이 - 뷰포트 오프셋.
    const top = scroll.length - scroll.offset;
    const out: DecorationSpan[] = [];
    for (const d of this.#decorations) {
      const abs = d.marker.row;
      if (abs < 0) continue;
      const row = abs - top;
      if (row < 0 || row >= rows) continue; // 화면 밖
      const x = Math.max(0, Math.min(d.opts.x ?? 0, cols - 1));
      const width = Math.max(0, Math.min(d.opts.width ?? cols - x, cols - x));
      if (width === 0) continue;
      out.push({
        row,
        x,
        width,
        backgroundColor: d.opts.backgroundColor,
        foregroundColor: d.opts.foregroundColor,
        opacity: d.opts.opacity ?? 0.4,
      });
    }
    return out;
  }

  get size(): { markers: number; decorations: number } {
    return { markers: this.#markers.size, decorations: this.#decorations.size };
  }

  dispose(): void {
    for (const d of [...this.#decorations]) d.dispose();
    for (const m of [...this.#markers]) m.dispose();
  }
}

class MarkerImpl implements Marker {
  #row: number;
  #disposed = false;
  #cbs: (() => void)[] = [];
  constructor(
    row: number,
    private readonly forget: (m: MarkerImpl) => void,
  ) {
    this.#row = row;
  }
  get row(): number {
    return this.#disposed ? -1 : this.#row;
  }
  get isDisposed(): boolean {
    return this.#disposed;
  }
  shift(n: number): void {
    if (this.#disposed) return;
    this.#row -= n;
    if (this.#row < 0) this.dispose(); // 가리키던 줄이 버려졌다
  }
  onDispose(cb: () => void): Disposable {
    if (this.#disposed) {
      cb();
      return { dispose() {} };
    }
    this.#cbs.push(cb);
    return {
      dispose: () => {
        const i = this.#cbs.indexOf(cb);
        if (i >= 0) this.#cbs.splice(i, 1);
      },
    };
  }
  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.forget(this);
    for (const cb of this.#cbs.splice(0)) cb();
  }
}

class DecorationImpl implements Decoration {
  #disposed = false;
  constructor(
    readonly opts: DecorationOptions,
    private readonly forget: (d: DecorationImpl) => void,
  ) {}
  get marker(): Marker {
    return this.opts.marker;
  }
  get isDisposed(): boolean {
    return this.#disposed;
  }
  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.forget(this);
  }
}
