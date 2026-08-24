import type { Disposable } from "./types";

/**
 * 앱이 정의한 링크 한 건. 좌표는 **뷰포트 열**이고 `endCol` 은 포함이다(코어 선택과 같은 규약).
 */
export interface TerminalLink {
  startCol: number;
  endCol: number;
  text: string;
  /** 클릭했을 때. 새 탭을 열든 에디터를 띄우든 소비자 몫이다. */
  activate(ev: MouseEvent): void;
  /** 포인터가 올라왔을 때(툴팁 등). */
  hover?(ev: MouseEvent): void;
  /** 포인터가 떠났을 때. */
  leave?(): void;
}

/**
 * 화면 한 줄에서 링크를 찾아 주는 규칙.
 *
 * **텍스트를 함께 받는다.** xterm.js 는 행 번호만 주고 provider 가 `buffer` API 로 텍스트를
 * 꺼내지만, 여기서는 코어가 워커에 있을 수 있어 그 API 를 동기로 열 수 없다. 대신 라이브러리가
 * 한 번 뽑아 넘긴다 — provider 는 정규식만 돌리면 된다.
 *
 * `row` 는 **뷰포트 행**이다(스크롤하면 같은 줄이 다른 번호가 된다). 절대 행이 필요하면
 * `onRender` 의 `scroll` 로 환산한다.
 */
export interface LinkProvider {
  provideLinks(row: number, text: string): TerminalLink[] | null | Promise<TerminalLink[] | null>;
}

/**
 * provider 목록과 **줄 텍스트 캐시**의 소유자.
 *
 * hover 는 포인터가 움직일 때마다 오므로(초당 수십 번) 매번 화면을 직렬화하면 비싸다. 프레임이
 * 바뀔 때까지 같은 텍스트를 재사용하고, 프레임이 오면 버린다.
 */
export class LinkRegistry {
  #providers = new Set<LinkProvider>();
  #lines: string[] | null = null;
  /** 같은 (row, col) 에 대한 조회를 되풀이하지 않는다 — 포인터가 한 셀 안에서 떨리기도 한다. */
  #last: { row: number; col: number; link: TerminalLink | null } | null = null;

  register(p: LinkProvider): Disposable {
    this.#providers.add(p);
    return {
      dispose: () => {
        this.#providers.delete(p);
        this.invalidate();
      },
    };
  }

  get empty(): boolean {
    return this.#providers.size === 0;
  }

  /** 프레임이 바뀌면 텍스트와 조회 결과를 버린다. */
  invalidate(): void {
    this.#lines = null;
    this.#last = null;
  }

  /**
   * `(row, col)` 에 걸리는 링크. 없으면 `null`.
   *
   * `getText` 는 화면 전체를 평문으로 주는 함수다(`Terminal.serialize`) — 캐시가 살아 있으면
   * 부르지 않는다.
   */
  async linkAt(
    row: number,
    col: number,
    getText: () => Promise<string>,
  ): Promise<TerminalLink | null> {
    if (this.#providers.size === 0) return null;
    if (this.#last && this.#last.row === row && this.#last.col === col) return this.#last.link;

    if (!this.#lines) this.#lines = (await getText()).split("\n");
    const text = this.#lines[row] ?? "";

    let found: TerminalLink | null = null;
    for (const p of this.#providers) {
      const links = await p.provideLinks(row, text);
      if (!links) continue;
      for (const l of links) {
        if (col >= l.startCol && col <= l.endCol) {
          found = l;
          break;
        }
      }
      if (found) break; // 먼저 등록한 provider 가 이긴다
    }
    this.#last = { row, col, link: found };
    return found;
  }
}
