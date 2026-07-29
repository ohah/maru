/**
 * 리치 모드를 벗어날 때 편집 내용이 다음 화면으로 인계되는지 검증한다(docs/file-panel.md §2.5).
 *
 * 왜 중요한가: 리치는 문서모델이고 읽기 프리뷰·저장은 CM6/savedContent를 본다. 전환 시점에 마크다운 한 벌을
 * 넘겨주지 않으면 **리치에서 편집한 내용이 읽기로 돌아가는 순간 사라진 것처럼 보인다** — 실제로 그 결함이
 * 있었고(리치→소스만 인계하고 리치→읽기는 빠뜨림), 사용자가 "저장해도 반영이 안 된다"로 관측했다.
 * 저장 기준점(savedDocument)도 함께 옮기지 않으면 저장 직후에도 dirty가 남아 탭 ●와 닫기 확인이 계속 뜬다.
 */

import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { bootShell, viewerChannel } from "../src/viewer";

type Harness = {
  dom: JSDOM;
  writes: string[];
  renders: string[];
  cleanup: () => void;
};

async function bootMarkdownShell(initial: string): Promise<Harness> {
  const dom = new JSDOM(
    '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
    { pretendToBeVisual: true, url: "maru-app://app/index.html?document=1" },
  );
  const previous = new Map<string, PropertyDescriptor | undefined>();
  const installGlobal = (name: string, value: unknown) => {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  };
  installGlobal("window", dom.window);
  installGlobal("document", dom.window.document);
  installGlobal("navigator", dom.window.navigator);
  installGlobal("MutationObserver", dom.window.MutationObserver);
  installGlobal("DOMRect", dom.window.DOMRect);
  installGlobal("requestAnimationFrame", dom.window.requestAnimationFrame.bind(dom.window));
  installGlobal("cancelAnimationFrame", dom.window.cancelAnimationFrame.bind(dom.window));

  const writes: string[] = [];
  const renders: string[] = [];
  dom.window.document.addEventListener("maru:file-request", () => {
    const node = dom.window.document.querySelector<HTMLElement>(
      '[data-maru-file-request="pending"]',
    );
    if (node === null) return;
    const request = JSON.parse(node.textContent ?? "null") as {
      method?: string;
      content?: string;
    };
    if (request.method === "write" && typeof request.content === "string") {
      writes.push(request.content);
    }
    const result =
      request.method === "beginDocument"
        ? { editor_epoch: 9 }
        : request.method === "read"
          ? { content: initial }
          : { ok: true };
    node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result });
    node.dataset.maruFileRequest = "done";
    dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
  });

  const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
  // 읽기 프리뷰로 나가는 내용을 가로챈다 — 리치 편집 결과가 프리뷰에 실제로 도달하는지가 이 테스트의 핵심이다.
  const contentWindow = frame?.contentWindow;
  if (contentWindow !== null && contentWindow !== undefined) {
    Object.defineProperty(contentWindow, "postMessage", {
      configurable: true,
      value: (message: unknown) => {
        if (
          typeof message === "object" &&
          message !== null &&
          (message as { type?: string }).type === "render"
        ) {
          renders.push((message as { markdown: string }).markdown);
        }
      },
    });
  }

  bootShell(dom.window.document, dom.window as unknown as Window);
  dom.window.dispatchEvent(
    new dom.window.MessageEvent("message", {
      source: contentWindow,
      data: {
        channel: viewerChannel,
        type: "renderer-ready",
        bridgeType: "undefined",
        handlerType: "undefined",
        parentAccessible: false,
      },
    }),
  );
  for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();

  return {
    dom,
    writes,
    renders,
    cleanup: () => {
      for (const [name, descriptor] of previous) {
        if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
        else Object.defineProperty(globalThis, name, descriptor);
      }
      dom.window.close();
    },
  };
}

/** 툴바 버튼을 title로 찾아 누른다 — 실제 편집 명령 경로를 그대로 탄다. */
function clickToolbar(dom: JSDOM, title: string): void {
  const button = [
    ...dom.window.document.querySelectorAll<HTMLButtonElement>(".maru-rich-toolbar-button"),
  ].find((el) => el.title === title);
  if (button === undefined) throw new Error(`toolbar button not found: ${title}`);
  button.dispatchEvent(new dom.window.Event("click", { bubbles: true }));
}

const setMode = (dom: JSDOM, mode: string) =>
  dom.window.dispatchEvent(new dom.window.CustomEvent("maru:file-mode", { detail: { mode } }));

describe("rich mode hand-off", () => {
  test("edits made in rich mode reach the read preview", async () => {
    const harness = await bootMarkdownShell("# 처음\n");
    try {
      setMode(harness.dom, "rich");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      // 실제 편집 경로(툴바 명령)로 문서를 바꾼다. DOM에 노드를 직접 넣으면 ProseMirror가 무시하므로
      // 인계를 검증하지 못한다. 여기서는 제목을 본문으로 낮춰 마크다운의 `#`가 사라지는 것을 신호로 쓴다.
      expect(harness.dom.window.document.querySelector("#rich-editor .ProseMirror")).not.toBeNull();
      clickToolbar(harness.dom, "본문 텍스트");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      harness.renders.length = 0;
      setMode(harness.dom, "read");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      // 읽기로 돌아갈 때 프리뷰가 받는 마크다운에 리치 편집 결과가 들어 있어야 한다.
      expect(harness.renders.length).toBeGreaterThan(0);
      const rendered = harness.renders.at(-1) ?? "";
      expect(rendered).toContain("처음");
      expect(rendered).not.toContain("# 처음"); // 제목이 본문으로 낮아진 편집이 반영됐다
    } finally {
      harness.cleanup();
    }
  });

  test("rich edits carry into the source editor document", async () => {
    const harness = await bootMarkdownShell("# 처음\n");
    try {
      setMode(harness.dom, "rich");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      clickToolbar(harness.dom, "인용");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      setMode(harness.dom, "source-edit");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      const cmText = harness.dom.window.document.querySelector("#editor .cm-content")?.textContent;
      expect(cmText ?? "").toContain(">"); // 리치에서 건 인용이 소스 문서에 확정됐다
      expect(cmText ?? "").toContain("처음");
    } finally {
      harness.cleanup();
    }
  });
});
