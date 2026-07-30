import { JSDOM } from "jsdom";

export function withEditorDom<T>(run: (dom: JSDOM) => Promise<T>): Promise<T>;
export function withEditorDom<T>(run: (dom: JSDOM) => T): T;
export function withEditorDom<T>(run: (dom: JSDOM) => T | Promise<T>): T | Promise<T> {
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", {
    pretendToBeVisual: true,
  });
  const previous = new Map<string, PropertyDescriptor | undefined>();
  const globals: Array<[string, unknown]> = [
    ["window", dom.window],
    ["Window", dom.window.Window],
    ["document", dom.window.document],
    ["navigator", dom.window.navigator],
    ["MutationObserver", dom.window.MutationObserver],
    ["DOMRect", dom.window.DOMRect],
    ["requestAnimationFrame", dom.window.requestAnimationFrame.bind(dom.window)],
    ["cancelAnimationFrame", dom.window.cancelAnimationFrame.bind(dom.window)],
  ];
  const cleanup = () => {
    for (const [name, descriptor] of previous) {
      if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
      else Object.defineProperty(globalThis, name, descriptor);
    }
    dom.window.close();
  };
  try {
    for (const [name, value] of globals) {
      previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
      Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
    }
    const result = run(dom);
    if (result instanceof Promise) {
      // React는 unmount 뒤에도 스케줄러 작업을 한 번 더 돌린다. 그때 jsdom globals가 이미 걷혔으면
      // `window is not defined`가 터지고 **그 뒤에 실행되는 다른 테스트 파일까지 오염된다**(실제로 겪었다).
      // 그래서 async 경로에서는 정리 전에 매크로태스크 한 턴을 흘려 그 작업을 흡수한다.
      return result.finally(async () => {
        await new Promise((resolve) => setTimeout(resolve, 0));
        cleanup();
      });
    }
    cleanup();
    return result;
  } catch (error) {
    cleanup();
    throw error;
  }
}
