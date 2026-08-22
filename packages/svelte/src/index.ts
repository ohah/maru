import { mountTerminal, type Terminal, type TerminalProps } from "@maru/core";

export type TerminalActionParams = TerminalProps;

/**
 * Svelte **액션**. `.svelte` 컴포넌트가 아닌 이유는 이 저장소의 번들러(zntc)가 그 파일을
 * 컴파일하지 못하기 때문이다. 액션은 Svelte의 1급 패턴이고 마운트·갱신·파괴 훅이 모두 있어
 * 기능은 컴포넌트와 같다.
 *
 * ```svelte
 * <script>
 *   import { terminal } from "@maru/svelte";
 * </script>
 * <div use:terminal={{ options: { cols: 80 }, onData }} style="width:100%;height:400px" />
 * ```
 */
export function terminal(node: HTMLElement, params: TerminalActionParams = {}) {
  const mounted = mountTerminal(node, params);
  return {
    update(next: TerminalActionParams) {
      mounted.update(next);
    },
    destroy() {
      mounted.destroy();
    },
    /** 코어 인스턴스를 직접 만져야 할 때. */
    get terminal(): Terminal {
      return mounted.terminal;
    },
  };
}

export type { Terminal, TerminalProps };
