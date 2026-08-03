import { describe, expect, test } from "bun:test";
import type { ViewerWindow } from "../src/viewer";
import { EditorState, Text, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { JSDOM } from "jsdom";
import {
  assetBase64BudgetAllowed,
  assetDataUrl,
  assetRequestCountAllowed,
  bootRenderer,
  bootShell,
  documentIsDirtyAgainstSnapshot,
  isLinkActivation,
  linkActivationFor,
  closeLockCanAcquire,
  closeUnlockOwnsLock,
  isAssetRequest,
  isRendererReport,
  requestFileBridge,
  renderMermaidFromBridge,
  revokeMermaidFromBridge,
  maxAssetBase64Bytes,
  maxAssetRequests,
  viewerChannel,
} from "../src/viewer";

/** renderer가 보내는 여러 메시지 중 링크 열기만 고른다(ready·rendered 보고가 함께 섞인다). */
function linkActivations(messages: unknown[]): unknown[] {
  return messages.filter(
    (message) => (message as { type?: unknown } | null)?.type === "link-activate",
  );
}

describe("file viewer bridge boundary", () => {
  test("save cleanliness follows the CM6 Text snapshot even when revisions advance", () => {
    const saved = EditorState.create({ doc: "saved" }).doc;
    const edited = EditorState.create({ doc: saved }).update({
      changes: { from: saved.length, insert: " edit" },
    }).state.doc;
    const undoneContentAtNewerRevision = EditorState.create({ doc: edited }).update({
      changes: { from: saved.length, to: edited.length, insert: "" },
    }).state.doc;

    expect(documentIsDirtyAgainstSnapshot(edited, saved)).toBe(true);
    expect(documentIsDirtyAgainstSnapshot(undoneContentAtNewerRevision, saved)).toBe(false);
    expect(documentIsDirtyAgainstSnapshot(saved, null)).toBe(true);
  });

  test("close lock acquisition is monotonic and same-request idempotent", () => {
    expect(closeLockCanAcquire(null, 1)).toBe(true);
    expect(closeLockCanAcquire(2, 2)).toBe(true);
    expect(closeLockCanAcquire(2, 3)).toBe(true);
    expect(closeLockCanAcquire(2, 1)).toBe(false);
    expect(closeLockCanAcquire(null, 0)).toBe(false);
    expect(closeLockCanAcquire(null, Number.MAX_SAFE_INTEGER + 1)).toBe(false);
  });

  test("close unlock ignores stale owners and lets a newer cancelled request retire an older lock", () => {
    expect(closeUnlockOwnsLock(2, 1)).toBe(false);
    expect(closeUnlockOwnsLock(2, 2)).toBe(true);
    expect(closeUnlockOwnsLock(2, 3)).toBe(true);
    expect(closeUnlockOwnsLock(null, 3)).toBe(false);
  });

  test("page-world DOM mailbox receives a result and removes transferred bytes", async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>");
    const document = dom.window.document;
    document.addEventListener("maru:file-request", () => {
      const node = document.querySelector<HTMLElement>('[data-maru-file-request="pending"]');
      expect(node?.textContent).toBe('{"method":"read","editor_epoch":1}');
      if (node === null) return;
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content: "# FP4" } });
      node.dataset.maruFileRequest = "done";
      document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });

    await expect(requestFileBridge(document, "read", { editor_epoch: 1 }, 100)).resolves.toEqual({
      content: "# FP4",
    });
    expect(document.querySelector("[data-maru-file-request]")).toBeNull();
  });

  test("product Mermaid adapter waits for the native exact terminal without scheduling a Web timeout", async () => {
    const dom = new JSDOM('<!doctype html><html><body><p id="status"></p></body></html>');
    const document = dom.window.document;
    const status = document.querySelector<HTMLElement>("#status");
    const originalSetTimeout = globalThis.setTimeout;
    let scheduledTimeouts = 0;
    globalThis.setTimeout = ((..._arguments: Parameters<typeof setTimeout>) => {
      scheduledTimeouts += 1;
      throw new Error("product Mermaid adapter scheduled an independent Web timeout");
    }) as unknown as typeof setTimeout;
    let pending: HTMLElement | null = null;
    document.addEventListener("maru:file-request", () => {
      const node = document.querySelector<HTMLElement>('[data-maru-file-request="pending"]');
      if (node === null) return;
      pending = node;
    });

    try {
      const result = renderMermaidFromBridge(
        document,
        status,
        {
          editorEpoch: 1,
          documentRevision: 1,
          projectionGeneration: 1,
          widgetId: 1,
          widgetGeneration: 1,
          rendererInstance: 1,
        },
        1,
        "0".repeat(64),
        "graph TD\nA --> B",
      );
      expect(status?.dataset.mermaidRequest).toBe("pending");
      expect(scheduledTimeouts).toBe(0);
      const node = pending as unknown as HTMLElement;
      node.textContent = JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        result: { job_id: 9, svg: "<svg></svg>" },
      });
      node.dataset.maruFileRequest = "done";
      document.dispatchEvent(new dom.window.Event("maru:file-response"));
      await expect(result).resolves.toBe("<svg></svg>");
      expect(status?.dataset.mermaidRequest).toBe("ok");
    } finally {
      globalThis.setTimeout = originalSetTimeout;
    }
    expect(document.querySelector("[data-maru-file-request]")).toBeNull();
  });

  test("product Mermaid revoke adapter bounds and cleans an unresponsive lifecycle mailbox", async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>");
    const document = dom.window.document;
    const originalSetTimeout = globalThis.setTimeout;
    const originalClearTimeout = globalThis.clearTimeout;
    let scheduledDelay = -1;
    let scheduledCallback: (() => void) | null = null;
    let clearedTimeouts = 0;
    globalThis.setTimeout = ((callback: TimerHandler, delay?: number) => {
      scheduledDelay = delay ?? 0;
      scheduledCallback = callback as () => void;
      return 1 as unknown as ReturnType<typeof setTimeout>;
    }) as unknown as typeof setTimeout;
    globalThis.clearTimeout = ((_handle?: ReturnType<typeof setTimeout>) => {
      clearedTimeouts += 1;
    }) as typeof clearTimeout;

    try {
      const result = revokeMermaidFromBridge(document, {
        editorEpoch: 1,
        documentRevision: 1,
        projectionGeneration: 1,
        widgetId: 1,
        widgetGeneration: 1,
        rendererInstance: 1,
      });
      expect(scheduledDelay).toBe(2_500);
      expect(document.querySelector('[data-maru-file-request="pending"]')).not.toBeNull();
      const callback = scheduledCallback as unknown as () => void;
      callback();
      await expect(result).rejects.toThrow("file bridge timeout");
      expect(document.querySelector("[data-maru-file-request]")).toBeNull();
      expect(clearedTimeouts).toBe(1);
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
    }
  });

  test("dirty snapshot request before editor hydration completes with a clean native ack", async () => {
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    let pendingRead: HTMLElement | null = null;
    const requests: unknown[] = [];
    dom.window.document.addEventListener("maru:file-request", () => {
      const node = dom.window.document.querySelector<HTMLElement>(
        '[data-maru-file-request="pending"]',
      );
      if (node === null) return;
      const request = JSON.parse(node.textContent ?? "null") as { method?: string };
      requests.push(request);
      if (request.method === "beginDocument") {
        node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { editor_epoch: 7 } });
        node.dataset.maruFileRequest = "done";
        dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
        return;
      }
      if (request.method === "read") {
        pendingRead = node;
        return;
      }
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { ok: true } });
      node.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });

    bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
    const page = dom.window as unknown as ViewerWindow & {
      __maruSyncDirty?: () => Promise<boolean>;
    };
    const sync = page.__maruSyncDirty?.();
    const duplicateSync = page.__maruSyncDirty?.();
    expect(duplicateSync).toBe(sync);
    // renderer-ready가 없어도 shell document hydration은 독립적으로 시작돼 dirty-sync가 영구 대기하지 않는다.
    for (let turn = 0; turn < 2; turn += 1) await Promise.resolve();
    expect(pendingRead).not.toBeNull();

    // Complete the deliberately delayed initial read. Initial hydration and dirty snapshot share the same
    // mutation queue, so the snapshot cannot overtake the single DOM mailbox request or be lost.
    const readNode = pendingRead as unknown as HTMLElement;
    readNode.textContent = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      result: { content: "# delayed hydration" },
    });
    readNode.dataset.maruFileRequest = "done";
    dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    await expect(sync).resolves.toBe(true);
    await expect(duplicateSync).resolves.toBe(true);
    expect(requests).toContainEqual({
      method: "setDirty",
      dirty: false,
      editor_epoch: 7,
      revision: 0,
      request_id: 0,
    });
    expect(
      requests.filter((request) => (request as { method?: string }).method === "setDirty"),
    ).toHaveLength(1);

    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    dom.window.close();
  });

  test("a rejecting rendererReady after a successful read keeps the rendered content and shows no read error", async () => {
    // 회귀: 예전엔 read(loadFromDisk) 성공 뒤 rendererReady가 StaleDocument 등으로 실패하면 그 rejection이
    // 하나의 catch로 흘러 "파일을 읽을 수 없습니다"를 띄워 이미 렌더된 내용과 겹쳤다. 이제 read 성공과 live-gate
    // 실패를 분리해, gate가 실패해도 read 에러를 표시하지 않는다(내용 유지).
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    const document = dom.window.document;
    let rendererReadyRejected = false;
    document.addEventListener("maru:file-request", () => {
      const node = document.querySelector<HTMLElement>('[data-maru-file-request="pending"]');
      if (node === null) return;
      const request = JSON.parse(node.textContent ?? "null") as { method?: string };
      const settle = (payload: Record<string, unknown>) => {
        node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, ...payload });
        node.dataset.maruFileRequest = "done";
        document.dispatchEvent(new dom.window.Event("maru:file-response"));
      };
      if (request.method === "beginDocument") return settle({ result: { editor_epoch: 7 } });
      if (request.method === "read") return settle({ result: { content: "# 렌더된 문서" } });
      if (request.method === "rendererReady") {
        rendererReadyRejected = true;
        return settle({ error: "StaleDocument" }); // gate 일시 실패(reject) — read는 이미 성공
      }
      settle({ result: { ok: true } });
    });

    bootShell(document, dom.window as unknown as ViewerWindow);
    for (let turn = 0; turn < 24; turn += 1) await Promise.resolve();

    const status = document.querySelector<HTMLElement>("#viewer-status");
    expect(rendererReadyRejected).toBe(true); // gate가 실제로 호출·실패했다
    expect(status?.dataset.fileRead).toBe("true"); // read는 성공으로 기록
    expect(status?.textContent).toBe(""); // read 에러 텍스트를 렌더 내용 위에 덮지 않는다
    dom.window.close();
  });

  test("write, dirty, link, and external reload ack mailbox requests expose only their exact parameters", async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>");
    const document = dom.window.document;
    const requests: unknown[] = [];
    document.addEventListener("maru:file-request", () => {
      const node = document.querySelector<HTMLElement>('[data-maru-file-request="pending"]');
      if (node === null) return;
      requests.push(JSON.parse(node.textContent ?? "null"));
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { ok: true } });
      node.dataset.maruFileRequest = "done";
      document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });

    await requestFileBridge(document, "beginDocument", { document_id: 1 }, 100);
    await requestFileBridge(document, "write", { editor_epoch: 4, content: "# 저장" }, 100);
    await requestFileBridge(
      document,
      "setDirty",
      { dirty: true, editor_epoch: 4, revision: 1, request_id: 0 },
      100,
    );
    await requestFileBridge(
      document,
      "openLink",
      { editor_epoch: 4, href: "../guide/next.md#usage", forceSystem: false },
      100,
    );
    await requestFileBridge(
      document,
      "setDirty",
      { dirty: false, editor_epoch: 4, revision: 7, request_id: 11 },
      100,
    );
    await requestFileBridge(
      document,
      "resolveExternalChange",
      { editor_epoch: 4, success: false },
      100,
    );
    await requestFileBridge(
      document,
      "renderMermaid",
      {
        editor_epoch: 4,
        document_revision: 7,
        projection_generation: 9,
        widget_id: 10,
        widget_generation: 11,
        renderer_instance: 12,
        fence_id: 13,
        source_hash: "a".repeat(64),
        source: "```mermaid\ngraph TD\n```",
      },
      100,
    );
    expect(requests).toEqual([
      { method: "beginDocument", document_id: 1 },
      { method: "write", editor_epoch: 4, content: "# 저장" },
      { method: "setDirty", dirty: true, editor_epoch: 4, revision: 1, request_id: 0 },
      {
        method: "openLink",
        editor_epoch: 4,
        href: "../guide/next.md#usage",
        forceSystem: false,
      },
      { method: "setDirty", dirty: false, editor_epoch: 4, revision: 7, request_id: 11 },
      { method: "resolveExternalChange", editor_epoch: 4, success: false },
      {
        method: "renderMermaid",
        editor_epoch: 4,
        document_revision: 7,
        projection_generation: 9,
        widget_id: 10,
        widget_generation: 11,
        renderer_instance: 12,
        fence_id: 13,
        source_hash: "a".repeat(64),
        source: "```mermaid\ngraph TD\n```",
      },
    ]);
    expect(JSON.stringify(requests)).not.toContain("path");
  });

  test("mutation requests reject invalid numeric identities before creating a DOM mailbox", async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>");
    const document = dom.window.document;
    let requestEvents = 0;
    document.addEventListener("maru:file-request", () => {
      requestEvents += 1;
    });

    await expect(
      requestFileBridge(document, "write", { editor_epoch: 0, content: "# stale" }, 100),
    ).rejects.toThrow("invalid write payload");
    await expect(
      requestFileBridge(document, "write", { editor_epoch: -1, content: "# stale" }, 100),
    ).rejects.toThrow("invalid write payload");
    await expect(
      requestFileBridge(
        document,
        "setDirty",
        { dirty: true, editor_epoch: 0, revision: 0, request_id: 0 },
        100,
      ),
    ).rejects.toThrow("invalid setDirty payload");
    await expect(
      requestFileBridge(
        document,
        "setDirty",
        { dirty: true, editor_epoch: -1, revision: 0, request_id: 0 },
        100,
      ),
    ).rejects.toThrow("invalid setDirty payload");
    await expect(
      requestFileBridge(
        document,
        "setDirty",
        { dirty: true, editor_epoch: 1, revision: -1, request_id: 0 },
        100,
      ),
    ).rejects.toThrow("invalid setDirty payload");
    await expect(
      requestFileBridge(
        document,
        "setDirty",
        { dirty: true, editor_epoch: 1, revision: 0, request_id: -1 },
        100,
      ),
    ).rejects.toThrow("invalid setDirty payload");
    await expect(
      requestFileBridge(
        document,
        "resolveExternalChange",
        { editor_epoch: 0, success: false },
        100,
      ),
    ).rejects.toThrow("invalid resolveExternalChange payload");
    await expect(
      requestFileBridge(
        document,
        "resolveExternalChange",
        { editor_epoch: -1, success: false },
        100,
      ),
    ).rejects.toThrow("invalid resolveExternalChange payload");
    await expect(
      requestFileBridge(
        document,
        "openLink",
        { editor_epoch: 0, href: "next.md", forceSystem: false },
        100,
      ),
    ).rejects.toThrow("invalid openLink payload");
    await expect(
      requestFileBridge(
        document,
        "renderMermaid",
        {
          editor_epoch: 1,
          document_revision: 0,
          projection_generation: 1,
          widget_id: 1,
          widget_generation: 1,
          renderer_instance: 1,
          fence_id: 1,
          source_hash: "not-a-sha256",
          source: "```mermaid\ngraph TD\n```",
        },
        100,
      ),
    ).rejects.toThrow("invalid renderMermaid payload");
    await expect(
      requestFileBridge(
        document,
        "openLink",
        { editor_epoch: -1, href: "next.md", forceSystem: false },
        100,
      ),
    ).rejects.toThrow("invalid openLink payload");

    expect(requestEvents).toBe(0);
    expect(document.querySelector("[data-maru-file-request]")).toBeNull();
  });

  test("asset request schema accepts only normalized bounded paths and ids", () => {
    expect(
      isAssetRequest({
        channel: viewerChannel,
        type: "asset-request",
        requestId: "1:1",
        path: "images/a.png",
      }),
    ).toBe(true);
    for (const path of ["../secret", "images//a.png", "/tmp/a.png", "https://x/a.png"]) {
      expect(
        isAssetRequest({
          channel: viewerChannel,
          type: "asset-request",
          requestId: "1:1",
          path,
        }),
      ).toBe(false);
    }
  });

  test("renderer report schema is bounded", () => {
    expect(
      isRendererReport({
        channel: viewerChannel,
        type: "rendered",
        text: "FP4 fixture",
        imageCount: 1,
        loadedImageCount: 1,
        bridgeType: "undefined",
        handlerType: "undefined",
        parentAccessible: false,
      }),
    ).toBe(true);
    expect(
      isRendererReport({
        channel: viewerChannel,
        type: "rendered",
        text: "x".repeat(513),
        imageCount: 0,
        loadedImageCount: 0,
        bridgeType: "undefined",
        handlerType: "undefined",
        parentAccessible: false,
      }),
    ).toBe(false);
    expect(
      isRendererReport({
        channel: viewerChannel,
        type: "rendered",
        text: "x",
        imageCount: 1,
        loadedImageCount: 2,
        bridgeType: "undefined",
        handlerType: "undefined",
        parentAccessible: false,
      }),
    ).toBe(false);
  });

  test("asset count and aggregate base64 budgets accept the exact boundary only", () => {
    expect(assetRequestCountAllowed(maxAssetRequests)).toBe(true);
    expect(assetRequestCountAllowed(maxAssetRequests + 1)).toBe(false);
    expect(assetBase64BudgetAllowed(0, maxAssetBase64Bytes)).toBe(true);
    expect(assetBase64BudgetAllowed(1, maxAssetBase64Bytes)).toBe(false);
    expect(assetBase64BudgetAllowed(maxAssetBase64Bytes, 1)).toBe(false);
  });

  test("link activation accepts bounded local documents and explicit http links only", () => {
    expect(
      isLinkActivation({
        channel: viewerChannel,
        type: "link-activate",
        href: "../guide/next.md#usage",
        forceSystem: false,
      }),
    ).toBe(true);
    expect(
      isLinkActivation({
        channel: viewerChannel,
        type: "link-activate",
        href: "HTTPS://example.com/guide?q=1#usage",
        forceSystem: true,
      }),
    ).toBe(true);
    for (const href of [
      "https%3A//example.com/next.md",
      "//example.com/next.md",
      "javascript:alert(1)",
      "data:text/html,unsafe",
      "file:///tmp/next.md",
      "https://example.com/has space",
      "https://example.com:bad/",
      "next.txt",
      "next%2.md",
    ]) {
      expect(
        isLinkActivation({
          channel: viewerChannel,
          type: "link-activate",
          href,
          forceSystem: false,
        }),
      ).toBe(false);
    }
    expect(
      isLinkActivation({
        channel: viewerChannel,
        type: "link-activate",
        href: "https://example.com",
      }),
    ).toBe(false);
  });

  test("trusted shell forwards only its renderer frame link activation to the pinned bridge", async () => {
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    const requests: unknown[] = [];
    dom.window.document.addEventListener("maru:file-request", () => {
      const node = dom.window.document.querySelector<HTMLElement>(
        '[data-maru-file-request="pending"]',
      );
      if (node === null) return;
      const request = JSON.parse(node.textContent ?? "null") as { method?: string };
      requests.push(request);
      const result =
        request.method === "beginDocument"
          ? { editor_epoch: 9 }
          : request.method === "read"
            ? { content: "" }
            : { opened: true };
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result });
      node.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });
    bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
    const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
    expect(frame?.contentWindow).not.toBeNull();
    for (let turn = 0; turn < 6; turn += 1) await Promise.resolve();

    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window as unknown as MessageEventSource,
        data: {
          channel: viewerChannel,
          type: "link-activate",
          href: "wrong-source.md",
          forceSystem: false,
        },
      }),
    );
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: frame?.contentWindow,
        data: {
          channel: viewerChannel,
          type: "link-activate",
          href: "../guide/next.md#usage",
          forceSystem: false,
        },
      }),
    );
    await new Promise((resolve) => dom.window.setTimeout(resolve, 0));

    expect(
      requests.filter((request) => (request as { method?: string }).method === "openLink"),
    ).toEqual([
      {
        method: "openLink",
        editor_epoch: 9,
        href: "../guide/next.md#usage",
        forceSystem: false,
      },
    ]);
  });

  test("trusted shell dirty callback keeps large IME input off full serialization and write paths", async () => {
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

    const requests: unknown[] = [];
    const prefix = "# heading\n\n";
    const initial = `${prefix}${"a".repeat(8 * 1024 * 1024 - prefix.length)}`;
    let diskContent = initial;
    let workerConstructions = 0;
    Object.defineProperty(dom.window, "Worker", {
      configurable: true,
      value: class {
        constructor() {
          workerConstructions += 1;
          throw new Error("general live preview worker must stay retired");
        }
      },
    });
    dom.window.document.addEventListener("maru:file-request", () => {
      const node = dom.window.document.querySelector<HTMLElement>(
        '[data-maru-file-request="pending"]',
      );
      if (node === null) return;
      const request = JSON.parse(node.textContent ?? "null") as { method?: string };
      requests.push(request);
      const result =
        request.method === "beginDocument"
          ? { editor_epoch: 9 }
          : request.method === "read"
            ? { content: diskContent }
            : { ok: true };
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result });
      node.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });

    const textPrototype = Text.prototype as Text & { toString: () => string };
    const originalToString = textPrototype.toString;
    let editor: EditorView | null = null;
    try {
      bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
      const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: frame?.contentWindow,
          data: {
            channel: viewerChannel,
            type: "renderer-ready",
            bridgeType: "undefined",
            handlerType: "undefined",
            parentAccessible: false,
          },
        }),
      );
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      expect(
        dom.window.document.querySelector("#viewer-status")?.getAttribute("data-file-read"),
      ).toBe("true");

      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-mode", { detail: { mode: "source-edit" } }),
      );
      const editorHost = dom.window.document.querySelector<HTMLElement>("#editor");
      editor = editorHost === null ? null : EditorView.findFromDOM(editorHost);
      expect(editor).not.toBeNull();
      // 소스 모드는 순수 CM6다 — worker도, 격리 렌더 위젯도 만들지 않는다.
      expect(workerConstructions).toBe(0);

      diskContent = "# external\n\n**updated**";
      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-reload", { detail: { conflict: false } }),
      );
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      expect(editor?.state.doc.toString()).toBe(diskContent);

      // A duplicate FSEvents notification for the same clean snapshot must not advance document identity.
      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-reload", { detail: { conflict: false } }),
      );
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      let serializations = 0;
      textPrototype.toString = function (this: Text) {
        serializations += 1;
        return originalToString.call(this);
      };
      editor?.dispatch({
        changes: { from: 0, to: 1, insert: "b" },
        annotations: Transaction.userEvent.of("input.type.compose"),
      });
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();

      expect(serializations).toBe(0);
      expect(
        requests.filter((request) => (request as { method?: string }).method === "write"),
      ).toEqual([]);
      expect(requests).toContainEqual({
        method: "setDirty",
        dirty: true,
        editor_epoch: 9,
        revision: 2,
        request_id: 0,
      });
    } finally {
      editor?.destroy();
      textPrototype.toString = originalToString;
      for (const [name, descriptor] of previous) {
        if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
        else Object.defineProperty(globalThis, name, descriptor);
      }
      dom.window.close();
    }
  });
});

describe("bridge-free renderer", () => {
  test("renders sanitized markdown from its parent message without exposing window.maru", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    bootRenderer(dom.window.document, dom.window as unknown as ViewerWindow);
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "render",
          markdown: "# Viewer\n\n<script>alert(1)</script>",
        },
      }),
    );

    expect(dom.window.document.querySelector("#app")?.innerHTML).toContain("Viewer");
    expect(dom.window.document.querySelector("#app")?.innerHTML).not.toContain("script");
    expect((dom.window as unknown as { maru?: unknown }).maru).toBeUndefined();
  });

  test("⌘+/− page zoom applies to markdown reads only, clamps, and clears for svg/1×", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const root = dom.window.document.documentElement;
    bootRenderer(dom.window.document, dom.window as unknown as ViewerWindow);
    const post = (data: unknown) =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", { source: dom.window.parent, data }),
      );

    // 콘텐츠 전이라 값만 저장 — 아직 마크다운이 아니므로 documentElement zoom은 미적용(§2.3 previewIsMarkdown 게이트).
    post({ channel: viewerChannel, type: "setZoom", zoom: 2 });
    expect(root.style.getPropertyValue("zoom")).toBe("");

    // 마크다운 read 프리뷰: 현재 배율을 페이지 줌으로 적용한다.
    post({ channel: viewerChannel, type: "render", markdown: "# Doc" });
    expect(root.style.getPropertyValue("zoom")).toBe("2");

    // 마크다운 상태에서 배율 변경은 즉시 반영. 상한 [0.1,10] 클램프도 확인.
    post({ channel: viewerChannel, type: "setZoom", zoom: 50 });
    expect(root.style.getPropertyValue("zoom")).toBe("10");

    // 1배(⌘0)는 기본 렌더 — zoom 속성을 제거한다.
    post({ channel: viewerChannel, type: "setZoom", zoom: 1 });
    expect(root.style.getPropertyValue("zoom")).toBe("");

    // svg 프리뷰는 자체 fit이 크기를 소유 → 페이지 줌 해제(마크다운에서 배율 3으로 켜둔 뒤 전환해도 비워진다).
    post({ channel: viewerChannel, type: "setZoom", zoom: 3 });
    post({ channel: viewerChannel, type: "render", markdown: "# Doc" });
    expect(root.style.getPropertyValue("zoom")).toBe("3");
    post({
      channel: viewerChannel,
      type: "renderSvg",
      svg: "<svg xmlns='http://www.w3.org/2000/svg'></svg>",
    });
    expect(root.style.getPropertyValue("zoom")).toBe("");

    // 하한 [0.1] 클램프: 마크다운 상태에서 극소 배율이 들어와도 0.1로 흡수한다.
    post({ channel: viewerChannel, type: "render", markdown: "# Doc" });
    post({ channel: viewerChannel, type: "setZoom", zoom: 0.01 });
    expect(root.style.getPropertyValue("zoom")).toBe("0.1");

    dom.window.close();
  });

  test("trusted shell forwards ⌘+/− zoom to the render iframe, clamped, ignoring non-finite", () => {
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    // read/write 브리지는 이 테스트와 무관 — 줌 포워딩만 검증하므로 문서 요청은 처리하지 않는다(begin이 pending에 머물러도 무해).
    bootShell(dom.window.document, dom.window as unknown as ViewerWindow);
    const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
    const target = frame?.contentWindow;
    expect(target).not.toBeNull();
    const posted: unknown[] = [];
    if (target) {
      target.postMessage = ((message: unknown) =>
        posted.push(message)) as typeof target.postMessage;
    }
    const dispatchZoom = (zoom: number) =>
      dom.window.dispatchEvent(new dom.window.CustomEvent("maru:file-zoom", { detail: { zoom } }));

    dispatchZoom(2); // 정상
    dispatchZoom(50); // 상한 → 10
    dispatchZoom(0.01); // 하한 → 0.1
    dispatchZoom(Number.NaN); // 비유한 → 무시(전송 안 함, previewZoom 미변경)
    dispatchZoom(Number.POSITIVE_INFINITY); // 비유한 → 무시

    const zooms = posted
      .filter(
        (m): m is { type?: unknown; zoom?: unknown } =>
          typeof m === "object" && m !== null && (m as { type?: unknown }).type === "setZoom",
      )
      .map((m) => m.zoom);
    // shell-side 클램프 [0.1,10]와 Number.isFinite 가드를 검증한다(비유한은 setZoom을 아예 안 보낸다).
    expect(zooms).toEqual([2, 10, 0.1]);

    dom.window.close();
  });

  test("allows raster data URLs and sanitizes SVG before creating a data URL", () => {
    const dom = new JSDOM("");
    const targetWindow = dom.window as unknown as ViewerWindow;
    expect(assetDataUrl("image/png", "iVBORw0KGgo=", targetWindow)).toBe(
      "data:image/png;base64,iVBORw0KGgo=",
    );
    expect(assetDataUrl("image/jpeg", "iVBORw0KGgo=", targetWindow)).toBeNull();
    const unsafeSvg =
      '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><text>safe</text></svg>';
    const encoded = dom.window.btoa(unsafeSvg);
    const url = assetDataUrl("image/svg+xml", encoded, targetWindow);
    expect(url).toStartWith("data:image/svg+xml;base64,");
    const sanitized = dom.window.atob(url?.split(",", 2)[1] ?? "");
    expect(sanitized).toContain("safe");
    expect(sanitized).not.toContain("onload");
    expect(assetDataUrl("text/html", encoded, targetWindow)).toBeNull();
  });

  test("routes activated markdown file links to the trusted shell instead of navigating the renderer", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as ViewerWindow);
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "render",
          markdown: "[next](../guide/next.md#usage)",
        },
      }),
    );

    const link = dom.window.document.querySelector<HTMLAnchorElement>("a");
    expect(link).not.toBeNull();
    // **합성 클릭은 링크를 열지 않는다**(§13 경화). 스크립트가 만든 이벤트는 `isTrusted`가 거짓이라
    // 여기서 걸린다 — 테스트가 만들 수 있는 이벤트는 전부 합성이므로 이 층에서는 거부만 검증할 수 있고,
    // 정상 경로는 `linkActivationFor` 단위 테스트가 값으로 고정한다.
    link?.dispatchEvent(
      new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
    );
    expect(linkActivations(messages)).toEqual([]);
    // 그렇다고 renderer가 스스로 이동해서도 안 된다.
    expect(dom.window.location.href).toBe("maru-app://render/render.html");
  });

  test("routes http links by click disposition while leaving document fragments in place", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as ViewerWindow);
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "render",
          markdown: "[web](https://example.com/guide) [section](#usage)",
        },
      }),
    );

    const links = dom.window.document.querySelectorAll<HTMLAnchorElement>("a");
    expect(links.length).toBe(2);
    // 합성 클릭은 disposition과 무관하게 아무것도 발급하지 않는다(§13 경화).
    for (const link of links) {
      link.dispatchEvent(
        new dom.window.MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          button: 0,
          metaKey: true,
          shiftKey: true,
        }),
      );
    }
    expect(linkActivations(messages)).toEqual([]);
  });

  test("링크 열기 판정은 사용자가 실제로 누른 클릭만 통과시킨다", () => {
    // 이 판정이 리스너에서 떨어져 나온 이유가 여기 있다 — `isTrusted`는 브라우저만 세울 수 있어 DOM
    // 테스트로는 **정상 경로를 만들 수 없다**(JSDOM에서 own·unconfigurable). 값으로 받으면 둘 다 고정된다.
    const base = {
      isTrusted: true,
      button: 0,
      metaKey: false,
      shiftKey: false,
      href: "https://example.com/guide",
      linkInRoot: true,
    };

    expect(linkActivationFor(base)).toEqual({
      channel: viewerChannel,
      type: "link-activate",
      href: "https://example.com/guide",
      forceSystem: false,
    });
    // ⌘⇧는 시스템 브라우저로 보내라는 뜻이다.
    expect(linkActivationFor({ ...base, metaKey: true, shiftKey: true })?.forceSystem).toBe(true);
    // 로컬 문서도 같은 경로다.
    expect(linkActivationFor({ ...base, href: "../guide/next.md#usage" })?.href).toBe(
      "../guide/next.md#usage",
    );

    // **합성 이벤트는 거부한다** — 이게 이 경화의 전부다.
    expect(linkActivationFor({ ...base, isTrusted: false })).toBeNull();
    // 나머지 기존 게이트도 그대로다.
    expect(linkActivationFor({ ...base, button: 1 })).toBeNull();
    expect(linkActivationFor({ ...base, href: null })).toBeNull();
    expect(linkActivationFor({ ...base, linkInRoot: false })).toBeNull();
    expect(linkActivationFor({ ...base, href: "javascript:alert(1)" })).toBeNull();
    expect(linkActivationFor({ ...base, href: "#usage" })).toBeNull();
  });
});
