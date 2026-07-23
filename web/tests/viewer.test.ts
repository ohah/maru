import { describe, expect, test } from "bun:test";
import { EditorState, Text, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { atomicRendererChannel } from "../src/renderer-capability";
import {
  assetBase64BudgetAllowed,
  assetDataUrl,
  assetRequestCountAllowed,
  bootRenderer,
  bootShell,
  documentIsDirtyAgainstSnapshot,
  isLinkActivation,
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
  writeLivePreviewIntentQueueMetrics,
} from "../src/viewer";

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

  test("publishes the exact queue SSOT snapshot after every coordinator transition", () => {
    const dom = new JSDOM('<!doctype html><p id="status"></p>');
    const status = dom.window.document.querySelector<HTMLElement>("#status");
    if (status === null) throw new Error("missing status fixture");
    writeLivePreviewIntentQueueMetrics(
      status,
      { retained: 0, maxRetained: 8, dropped: 1, completed: 9 },
      2,
    );
    expect(status.dataset).toEqual(
      expect.objectContaining({
        liveIntentQueueRetained: "0",
        liveIntentQueueMaxRetained: "8",
        liveIntentQueueDropped: "1",
        liveIntentQueueCompleted: "9",
        liveIntentBridgeCalls: "2",
      }),
    );
    dom.window.close();
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
    }) as typeof setTimeout;
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
      expect(status?.dataset.liveMermaidRequest).toBe("pending");
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
      expect(status?.dataset.liveMermaidRequest).toBe("ok");
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
    }) as typeof setTimeout;
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

    bootShell(dom.window.document, dom.window as unknown as Window);
    const page = dom.window as unknown as Window & { __maruSyncDirty?: () => Promise<boolean> };
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

  test("a rejecting livePreviewReady after a successful read keeps the rendered content and shows no read error", async () => {
    // 회귀: 예전엔 read(loadFromDisk) 성공 뒤 livePreviewReady가 StaleDocument 등으로 실패하면 그 rejection이
    // 하나의 catch로 흘러 "파일을 읽을 수 없습니다"를 띄워 이미 렌더된 내용과 겹쳤다. 이제 read 성공과 live-gate
    // 실패를 분리해, gate가 실패해도 read 에러를 표시하지 않는다(내용 유지).
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    const document = dom.window.document;
    let livePreviewReadyRejected = false;
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
      if (request.method === "livePreviewReady") {
        livePreviewReadyRejected = true;
        return settle({ error: "StaleDocument" }); // gate 일시 실패(reject) — read는 이미 성공
      }
      settle({ result: { ok: true } });
    });

    bootShell(document, dom.window as unknown as Window);
    for (let turn = 0; turn < 24; turn += 1) await Promise.resolve();

    const status = document.querySelector<HTMLElement>("#viewer-status");
    expect(livePreviewReadyRejected).toBe(true); // gate가 실제로 호출·실패했다
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
    bootShell(dom.window.document, dom.window as unknown as Window);
    const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
    expect(frame?.contentWindow).not.toBeNull();
    for (let turn = 0; turn < 6; turn += 1) await Promise.resolve();

    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window,
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
      bootShell(dom.window.document, dom.window as unknown as Window);
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
        new dom.window.CustomEvent("maru:file-mode", { detail: { mode: "live-preview" } }),
      );
      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-live-preview-active", {
          detail: { active: false },
        }),
      );
      const editorHost = dom.window.document.querySelector<HTMLElement>("#editor");
      editor = editorHost === null ? null : EditorView.findFromDOM(editorHost);
      expect(editor).not.toBeNull();
      const status = dom.window.document.querySelector<HTMLElement>("#viewer-status");
      expect(status?.dataset.liveProjection).toBe("running");
      expect(status?.dataset.liveProjectionDocumentRevision).toBe("0");
      expect(status?.dataset.liveAtomicAdmitted).toBe("false");
      expect(status?.dataset.liveGeneralFragments).toBe("0");
      expect(workerConstructions).toBe(0);
      expect(dom.window.document.querySelector(".maru-live-atomic-frame")).toBeNull();

      diskContent = "# external\n\n**updated**";
      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-reload", { detail: { conflict: false } }),
      );
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      expect(editor?.state.doc.toString()).toBe(diskContent);
      expect(status?.dataset.liveProjectionDocumentRevision).toBe("1");

      // A duplicate FSEvents notification for the same clean snapshot must not advance document identity.
      dom.window.dispatchEvent(
        new dom.window.CustomEvent("maru:file-reload", { detail: { conflict: false } }),
      );
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      expect(status?.dataset.liveProjectionDocumentRevision).toBe("1");

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
  test("accepts pathless atomic HTML only through a load-scoped capability MessagePort", async () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    let finishDecode: () => void = () => {};
    const decoded = new Promise<void>((resolve) => {
      finishDecode = resolve;
    });
    Object.defineProperty(dom.window.HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: () => decoded,
    });
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    const capability = {
      editorEpoch: 2,
      documentRevision: 3,
      projectionGeneration: 4,
      widgetId: 5,
      widgetGeneration: 6,
      rendererInstance: 7,
    };
    const channel = new MessageChannel();
    let renderedSettled = false;
    let renderedCount = 0;
    const rendered = new Promise<unknown>((resolve) => {
      channel.port1.onmessage = (event) => {
        if ((event.data as { type?: string }).type === "atomic-ready") {
          channel.port1.postMessage({
            channel: atomicRendererChannel,
            type: "atomic-render",
            capability,
            payload:
              '<p>isolated atomic <a href="next.md">next</a><img data-maru-asset-id="1"></p>',
            assets: [{ opaqueId: 1, dataUrl: "data:image/png;base64,iVBORw0KGgo=" }],
          });
          channel.port1.postMessage({
            channel: atomicRendererChannel,
            type: "atomic-render",
            capability,
            payload: "<p>duplicate must not replace the first render</p>",
            assets: [],
          });
        } else {
          renderedCount += 1;
          renderedSettled = true;
          resolve(event.data);
        }
      };
      channel.port1.start();
    });
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: { channel: atomicRendererChannel, type: "atomic-init", capability },
        ports: [channel.port2] as unknown as readonly MessagePort[],
      }),
    );

    for (
      let turn = 0;
      turn < 10 && dom.window.document.querySelector("#app")?.textContent === "";
      turn += 1
    )
      await new Promise((resolve) => dom.window.setTimeout(resolve, 0));
    expect(renderedSettled).toBe(false);
    expect(dom.window.document.querySelector("#app")?.textContent).toBe("isolated atomic next");
    finishDecode();
    await expect(rendered).resolves.toMatchObject({
      channel: atomicRendererChannel,
      type: "atomic-rendered",
      capability,
    });
    expect(dom.window.document.querySelector("#app")?.textContent).toBe("isolated atomic next");
    expect(dom.window.document.querySelector("img")?.src).toStartWith("data:image/png;base64,");
    expect(renderedCount).toBe(1);
    const link = dom.window.document.querySelector("a")!;
    const click = new dom.window.MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      button: 0,
    });
    link.dispatchEvent(click);
    expect(click.defaultPrevented).toBe(true);
    channel.port1.close();
    dom.window.close();
  });

  test("renders sanitized markdown from its parent message without exposing window.maru", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    bootRenderer(dom.window.document, dom.window as unknown as Window);
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
    bootRenderer(dom.window.document, dom.window as unknown as Window);
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

    // image 프리뷰도 panzoom이 크기를 소유 → 페이지 줌 해제(svg와 별도 분기라 따로 검증).
    post({ channel: viewerChannel, type: "setZoom", zoom: 4 });
    post({ channel: viewerChannel, type: "render", markdown: "# Doc" });
    expect(root.style.getPropertyValue("zoom")).toBe("4");
    post({
      channel: viewerChannel,
      type: "renderImage",
      src: "data:image/png;base64,iVBORw0KGgo=",
    });
    expect(root.style.getPropertyValue("zoom")).toBe("");

    dom.window.close();
  });

  test("trusted shell forwards ⌘+/− zoom to the render iframe, clamped, ignoring non-finite", () => {
    const dom = new JSDOM(
      '<!doctype html><p id="viewer-status"></p><iframe id="renderer"></iframe><main id="editor"></main>',
      { url: "maru-app://app/index.html?document=1" },
    );
    // read/write 브리지는 이 테스트와 무관 — 줌 포워딩만 검증하므로 문서 요청은 처리하지 않는다(begin이 pending에 머물러도 무해).
    bootShell(dom.window.document, dom.window as unknown as Window);
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
    const targetWindow = dom.window as unknown as Window;
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

  test("renderImage displays the data URL as a panzoom <img> and reports a broken image on load error", async () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    const src = "data:image/png;base64,iVBORw0KGgo=";
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: { channel: viewerChannel, type: "renderImage", src },
      }),
    );

    const img = dom.window.document.querySelector<HTMLImageElement>("img.maru-image-preview");
    expect(img).not.toBeNull();
    expect(img?.getAttribute("src")).toBe(src); // 신뢰 shell이 만든 raster 데이터 URL을 그대로 표시
    expect(img?.draggable).toBe(false);

    // JSDOM은 이미지를 디코드하지 않으므로 load는 안 뜬다(panzoom은 실브라우저 전용). error 경로만 여기서 검증:
    // 깨진 이미지면 안내 문구로 교체하고 rendered(loadedImageCount:0)를 부모에 보고해 shell이 멈추지 않는다.
    img?.dispatchEvent(new dom.window.Event("error"));
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    expect(dom.window.document.querySelector("img.maru-image-preview")).toBeNull();
    expect(dom.window.document.querySelector(".maru-svg-error")?.textContent).toBe(
      "이 이미지를 표시할 수 없습니다.",
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "rendered",
        text: "image",
        imageCount: 1,
        loadedImageCount: 0,
      }),
    );
    dom.window.close();
  });

  test("read preview requests a mermaid render per fence and replaces the code block with the SVG image", async () => {
    // 읽기 프리뷰가 mermaid 펜스를 native 헬퍼(shell 경유)로 렌더한 SVG `<img>`로 교체하는지 검증(라이브 숨김 동안
    // 읽기에서도 다이어그램). 헬퍼가 요구하는 완전한 ```mermaid 펜스로 재구성해 요청하고, 결과 SVG를 img로 붙인다.
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: Record<string, unknown>[] = [];
    dom.window.postMessage = ((message: Record<string, unknown>) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "render",
          markdown: "```mermaid\nflowchart TD\n  A --> B\n```",
        },
      }),
    );

    // 코드 블록이 먼저 렌더되고, mermaid-request가 완전한 펜스로 나간다.
    const codeEl = dom.window.document.querySelector<HTMLElement>("code.language-mermaid");
    expect(codeEl).not.toBeNull();
    const request = messages.find((m) => m.type === "mermaid-request");
    expect(request).toBeDefined();
    // 완전한 ```mermaid 펜스로 재구성해 보낸다(prism이 코드 블록에 넣는 후행 공백은 mermaidFenceBody가 무시).
    const requestSource = request?.source as string;
    expect(requestSource.startsWith("```mermaid\n")).toBe(true);
    expect(requestSource.trimEnd().endsWith("```")).toBe(true);
    expect(requestSource).toContain("flowchart TD");
    expect(requestSource).toContain("A --> B");
    const requestId = request?.requestId as string;

    // shell이 sanitized SVG를 돌려주면 코드 블록(pre)이 diagram img로 교체된다.
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "mermaid-result",
          requestId,
          svg: '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>',
        },
      }),
    );
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    expect(dom.window.document.querySelector("code.language-mermaid")).toBeNull(); // 코드 블록 사라짐
    const img = dom.window.document.querySelector<HTMLImageElement>("img.maru-mermaid-diagram");
    expect(img).not.toBeNull();
    expect(img?.getAttribute("src")).toStartWith("data:image/svg+xml;base64,");
    dom.window.close();
  });

  test("read preview keeps the mermaid code block when the render fails", async () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: Record<string, unknown>[] = [];
    dom.window.postMessage = ((message: Record<string, unknown>) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: { channel: viewerChannel, type: "render", markdown: "```mermaid\nbad\n```" },
      }),
    );
    const requestId = messages.find((m) => m.type === "mermaid-request")?.requestId as string;
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: {
          channel: viewerChannel,
          type: "mermaid-result",
          requestId,
          error: "mermaid unavailable",
        },
      }),
    );
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    // 실패면 코드 블록을 그대로 남긴다(fallback), img는 안 붙는다.
    expect(dom.window.document.querySelector("code.language-mermaid")).not.toBeNull();
    expect(dom.window.document.querySelector("img.maru-mermaid-diagram")).toBeNull();
    dom.window.close();
  });

  test("renderImage drops a stale overlapping render so its late event never clobbers the current image", async () => {
    // 회귀(generation guard): 정상 open은 renderImage를 2회 보낸다(rendererReady 핸들러 + applyMode "read"). 앞선
    // 렌더의 `<img>`는 다음 렌더의 root.replaceChildren로 detach되는데, 그 detach된 img의 늦은 load/error가 최신
    // 렌더를 건드리면 안 된다(예전엔 detached 노드에 panzoom을 붙여 예외, 또는 error가 현재 이미지를 덮었다).
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    const send = (src: string) =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: dom.window.parent,
          data: { channel: viewerChannel, type: "renderImage", src },
        }),
      );
    send("data:image/png;base64,QQAA"); // 1차 렌더
    const stale = dom.window.document.querySelector<HTMLImageElement>("img.maru-image-preview");
    expect(stale).not.toBeNull();
    send("data:image/png;base64,QkJB"); // 겹친 2차 렌더 — 1차 img를 detach
    expect(stale?.isConnected).toBe(false);

    // stale img의 늦은 error는 최신(2차) img를 error 안내로 덮으면 안 되고, 예외도 없어야 한다.
    expect(() => stale?.dispatchEvent(new dom.window.Event("error"))).not.toThrow();
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    const current = dom.window.document.querySelector<HTMLImageElement>("img.maru-image-preview");
    expect(current?.getAttribute("src")).toBe("data:image/png;base64,QkJB"); // 2차 img 생존
    expect(dom.window.document.querySelector(".maru-svg-error")).toBeNull(); // stale error 안내 없음
    dom.window.close();
  });

  test("routes activated markdown file links to the trusted shell instead of navigating the renderer", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
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
    const navigated = link?.dispatchEvent(
      new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
    );

    expect(navigated).toBe(false);
    expect(messages).toContainEqual({
      channel: viewerChannel,
      type: "link-activate",
      href: "../guide/next.md#usage",
      forceSystem: false,
    });
    expect(dom.window.location.href).toBe("maru-app://render/render.html");
  });

  test("routes http links by click disposition while leaving document fragments in place", () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    const messages: unknown[] = [];
    dom.window.postMessage = ((message: unknown) =>
      messages.push(message)) as typeof dom.window.postMessage;
    bootRenderer(dom.window.document, dom.window as unknown as Window);
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
    expect(
      links[0]?.dispatchEvent(
        new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
      ),
    ).toBe(false);
    expect(
      links[0]?.dispatchEvent(
        new dom.window.MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          button: 0,
          metaKey: true,
          shiftKey: true,
        }),
      ),
    ).toBe(false);
    expect(
      links[1]?.dispatchEvent(
        new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
      ),
    ).toBe(true);

    expect(messages).toContainEqual({
      channel: viewerChannel,
      type: "link-activate",
      href: "https://example.com/guide",
      forceSystem: false,
    });
    expect(messages).toContainEqual({
      channel: viewerChannel,
      type: "link-activate",
      href: "https://example.com/guide",
      forceSystem: true,
    });
  });
});
