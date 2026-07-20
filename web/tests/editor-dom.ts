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
      return result.finally(cleanup);
    }
    cleanup();
    return result;
  } catch (error) {
    cleanup();
    throw error;
  }
}
