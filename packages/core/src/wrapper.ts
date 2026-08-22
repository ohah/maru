import { Terminal } from "./terminal";
import type { Size, TerminalOptions, Theme } from "./types";

/** 프레임워크 래퍼가 공통으로 받는 props. 넷이 같은 표면을 갖게 하는 단일 출처다. */
export interface TerminalProps {
  options?: TerminalOptions;
  theme?: Theme;
  /** 요소 크기에 맞춰 그리드를 자동으로 맞출지. 기본 true. */
  autoFit?: boolean;
  onData?: (bytes: Uint8Array) => void;
  onTitle?: (title: string) => void;
  onBell?: () => void;
  onResize?: (size: Size) => void;
  onReady?: (term: Terminal) => void;
}

/**
 * 요소에 터미널을 붙이고 이벤트를 잇는다. **네 래퍼가 전부 이 함수를 쓴다** — 프레임워크마다
 * 다시 쓰면 생명주기 버그가 네 벌 생긴다.
 *
 * 반환한 정리 함수는 반드시 unmount에서 불러야 한다(워커·wasm·타이머가 남는다).
 */
export function mountTerminal(
  el: HTMLElement,
  props: TerminalProps,
): {
  terminal: Terminal;
  ready: Promise<void>;
  update(next: TerminalProps): void;
  destroy(): void;
} {
  let current = props;
  const term = new Terminal({ ...props.options, theme: props.theme ?? props.options?.theme });
  const subs = [
    term.onData((b) => current.onData?.(b)),
    term.onTitle((t) => current.onTitle?.(t)),
    term.onBell(() => current.onBell?.()),
    term.onResize((s) => current.onResize?.(s)),
  ];

  let observer: ResizeObserver | null = null;
  const ready = term.open(el).then(() => {
    if (current.autoFit !== false) {
      term.fit();
      if (typeof ResizeObserver !== "undefined") {
        observer = new ResizeObserver(() => term.fit());
        observer.observe(el);
      }
    }
    current.onReady?.(term);
  });

  return {
    terminal: term,
    ready,
    update(next) {
      // **부분 병합이어야 한다.** 통째로 덮어쓰면 이번에 안 넘어온 콜백(onData·onReady…)이
      // 사라진다 — 프레임워크의 `updated`/`useEffect` 가 props 일부만 넘기는 게 정상이라
      // 덮어쓰기로 두면 첫 렌더 직후 이벤트가 조용히 끊긴다(Lit 에서 실측).
      const prevTheme = current.theme;
      current = { ...current, ...next };
      if (next.theme && next.theme !== prevTheme) term.setTheme(next.theme);
      if (next.options) term.setOptions(next.options);
    },
    destroy() {
      observer?.disconnect();
      for (const s of subs) s.dispose();
      term.dispose();
    },
  };
}
