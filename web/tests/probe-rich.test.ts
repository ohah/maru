import { describe, expect, test } from "bun:test";
import type { ViewerWindow } from "../src/viewer";
import { JSDOM } from "jsdom";
import { bootShell, viewerChannel } from "../src/viewer";

describe("probe", () => {
  test("read -> rich mounts the toolbar", async () => {
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { pretendToBeVisual: true, url: "maru-app://app/index.html?document=1" },
    );
    // 전역은 **반드시 복원한다.** 설치만 하고 두면 이 파일 뒤에 실행되는 모든 테스트가 남의 JSDOM 문서를 보고
    // 돌아, prosemirror가 `getClientRects is not a function`을 던진다 — 단독 실행은 깨끗하고 순서에 따라서만
    // 실패하는 유형이라 CI에서만 터진다. editor-dom.ts·rich-mode-handoff.test.ts가 같은 이유로 이미 복원한다.
    const g = globalThis as Record<string, unknown>;
    const previous = new Map<string, PropertyDescriptor | undefined>();
    for (const k of [
      "window",
      "document",
      "navigator",
      "MutationObserver",
      "DOMRect",
      "requestAnimationFrame",
      "cancelAnimationFrame",
    ]) {
      const source = (dom.window as unknown as Record<string, unknown>)[k];
      const value =
        typeof source === "function" && k.includes("Frame")
          ? (source as (...args: unknown[]) => unknown).bind(dom.window)
          : source;
      previous.set(k, Object.getOwnPropertyDescriptor(globalThis, k));
      Object.defineProperty(g, k, { configurable: true, writable: true, value });
    }
    const restore = async () => {
      // 살아 있는 편집기가 예약해 둔 rAF·지연 콜백을 제품 종료 경로로 먼저 끊는다(rich-mode-handoff.test.ts 참고).
      dom.window.dispatchEvent(new dom.window.Event("pagehide"));
      await new Promise((resolve) => setTimeout(resolve, 0));
      for (const [name, descriptor] of previous) {
        if (descriptor === undefined) delete g[name];
        else Object.defineProperty(globalThis, name, descriptor);
      }
      dom.window.close();
    };
    try {
      dom.window.document.addEventListener("maru:file-request", () => {
        const node = dom.window.document.querySelector<HTMLElement>(
          '[data-maru-file-request="pending"]',
        );
        if (node === null) return;
        const req = JSON.parse(node.textContent ?? "null") as { method?: string };
        const result =
          req.method === "beginDocument"
            ? { editor_epoch: 9 }
            : req.method === "read"
              ? { content: "# 제목\n\n- 하나\n- 둘\n" }
              : { ok: true };
        node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result });
        node.dataset.maruFileRequest = "done";
        dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
      });
      const cw = dom.window.document.querySelector<HTMLIFrameElement>("#renderer")?.contentWindow;
      if (cw) Object.defineProperty(cw, "postMessage", { configurable: true, value: () => {} });
      bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: cw,
          data: {
            channel: viewerChannel,
            type: "renderer-ready",
            bridgeType: "undefined",
            handlerType: "undefined",
            parentAccessible: false,
          },
        }),
      );
      for (let t = 0; t < 20; t += 1) await Promise.resolve();

      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-mode", { detail: { mode: "rich" } }),
      );
      for (let t = 0; t < 40; t += 1) await Promise.resolve();
      await new Promise((r) => setTimeout(r, 0));

      const d = dom.window.document;
      expect(d.body.dataset.fileMode).toBe("rich");
      expect(d.querySelector("#rich-editor")).not.toBeNull();
      expect(d.querySelector("#renderer")?.hasAttribute("hidden")).toBe(true);
      expect(d.querySelectorAll("[data-toolbar-button]").length).toBeGreaterThan(0);
    } finally {
      await restore();
    }
  });
});
