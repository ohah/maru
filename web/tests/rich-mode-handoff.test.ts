/**
 * 리치 모드를 벗어날 때 편집 내용이 다음 화면으로 인계되는지 검증한다(docs/file-panel.md §2.5).
 *
 * 왜 중요한가: 리치는 문서모델이고 읽기 프리뷰·저장은 CM6/savedContent를 본다. 전환 시점에 마크다운 한 벌을
 * 넘겨주지 않으면 **리치에서 편집한 내용이 읽기로 돌아가는 순간 사라진 것처럼 보인다** — 실제로 그 결함이
 * 있었고(리치→소스만 인계하고 리치→읽기는 빠뜨림), 사용자가 "저장해도 반영이 안 된다"로 관측했다.
 * 저장 기준점(savedDocument)도 함께 옮기지 않으면 저장 직후에도 dirty가 남아 탭 ●와 닫기 확인이 계속 뜬다.
 */

import { describe, expect, test } from "bun:test";
import type { ViewerWindow } from "../src/viewer";
import { JSDOM } from "jsdom";
import { bootShell, viewerChannel } from "../src/viewer";

type Harness = {
  dom: JSDOM;
  writes: string[];
  renders: string[];
  /** 브리지 read가 돌려줄 내용. 외부 디스크 변경을 흉내 낼 때 바꾼다. */
  diskContent: string;
  cleanup: () => Promise<void>;
};

async function bootMarkdownShell(initial: string): Promise<Harness> {
  const state = { diskContent: initial };
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
          ? { content: state.diskContent }
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

  bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
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
    get diskContent() {
      return state.diskContent;
    },
    set diskContent(next: string) {
      state.diskContent = next;
    },
    cleanup: async () => {
      // **편집기를 실제로 파괴한다.** 매크로태스크 한 턴을 흘리는 것만으로는 부족하다 — CodeMirror의 measure
      // 루프는 rAF로 자기를 다시 예약하고, ProseMirror는 트랜잭션 뒤 scrollToSelection을 지연 실행한다. 살아 있는
      // 편집기를 두고 globals를 걷으면 그 콜백이 `window is not defined`·`getClientRects is not a function`으로
      // 터지면서 **다음 테스트 파일 헤딩 아래에** uncaught 오류로 붙는다(실제로 그렇게 나왔다).
      // 제품이 쓰는 종료 경로(`pagehide` → editor.destroy())를 그대로 태워 예약된 작업을 먼저 끊는다.
      dom.window.dispatchEvent(new dom.window.Event("pagehide"));
      await new Promise((resolve) => setTimeout(resolve, 0));
      for (const [name, descriptor] of previous) {
        if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
        else Object.defineProperty(globalThis, name, descriptor);
      }
      dom.window.close();
    },
  };
}

/**
 * 툴바 버튼을 title로 찾아 누른다 — 실제 편집 명령 경로를 그대로 탄다.
 *
 * 마운트를 기다리지 않는다. 툴바 첫 렌더는 동기이므로(toolbar-mount.tsx), 폴링을 넣으면 그 계약이 깨져도
 * 테스트가 통과해 버린다.
 */
function clickToolbar(dom: JSDOM, title: string): void {
  const button = [
    ...dom.window.document.querySelectorAll<HTMLButtonElement>("[data-toolbar-button]"),
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
      await harness.cleanup();
    }
  });

  test("잠긴 문서는 리치에서 저장되지 않는다", async () => {
    // 잠금이 타이핑만 막고 저장 경로가 열려 있으면 ⌘S 한 번에 frontmatter가 `## title: 문서`로 덮인다.
    const harness = await bootMarkdownShell("---\ntitle: 문서\n---\n\n본문");
    try {
      setMode(harness.dom, "rich");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      expect(harness.dom.window.document.querySelector(".maru-rich-notice")).not.toBeNull();

      harness.writes.length = 0;
      harness.dom.window.document.querySelector("#rich-editor .maru-rich-content")?.dispatchEvent(
        new harness.dom.window.KeyboardEvent("keydown", {
          key: "s",
          metaKey: true,
          bubbles: true,
        }),
      );
      for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();
      expect(harness.writes).toEqual([]); // 디스크로 나간 바이트가 없어야 한다
    } finally {
      await harness.cleanup();
    }
  });

  test("외부 디스크 변경이 리치 편집기에도 반영된다", async () => {
    // 반영하지 않으면 리치는 옛 문서를 들고 있다가 다음 저장에 외부 편집을 되돌려 쓴다.
    const harness = await bootMarkdownShell("# 처음\n");
    try {
      setMode(harness.dom, "rich");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      harness.diskContent = "# 외부에서 바뀐 문서\n\n새 문단\n";
      harness.dom.window.dispatchEvent(
        new harness.dom.window.CustomEvent("maru:file-reload", { detail: { conflict: true } }),
      );
      for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();

      harness.renders.length = 0;
      setMode(harness.dom, "read");
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      const rendered = harness.renders.at(-1) ?? "";
      expect(rendered).toContain("외부에서 바뀐 문서");
      expect(rendered).not.toContain("# 처음");
    } finally {
      await harness.cleanup();
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
      await harness.cleanup();
    }
  });
});
