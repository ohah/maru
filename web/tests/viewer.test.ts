import { describe, expect, test } from "bun:test";
import { EditorState, Text, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { fragmentChannel } from "../src/renderer-capability";
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
  maxAssetBase64Bytes,
  maxAssetRequests,
  viewerChannel,
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
      { href: "../guide/next.md#usage", forceSystem: false },
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
    expect(requests).toEqual([
      { method: "beginDocument", document_id: 1 },
      { method: "write", editor_epoch: 4, content: "# 저장" },
      { method: "setDirty", dirty: true, editor_epoch: 4, revision: 1, request_id: 0 },
      { method: "openLink", href: "../guide/next.md#usage", forceSystem: false },
      { method: "setDirty", dirty: false, editor_epoch: 4, revision: 7, request_id: 11 },
      { method: "resolveExternalChange", editor_epoch: 4, success: false },
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
      requests.push(JSON.parse(node.textContent ?? "null"));
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { opened: true } });
      node.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });
    bootShell(dom.window.document, dom.window as unknown as Window);
    const frame = dom.window.document.querySelector<HTMLIFrameElement>("#renderer");
    expect(frame?.contentWindow).not.toBeNull();

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
    await Promise.resolve();

    expect(requests).toEqual([
      { method: "beginDocument", document_id: 1 },
      { method: "openLink", href: "../guide/next.md#usage", forceSystem: false },
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
    const initial = "a".repeat(8 * 1024 * 1024);
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
            ? { content: initial }
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
      const editorHost = dom.window.document.querySelector<HTMLElement>("#editor");
      editor = editorHost === null ? null : EditorView.findFromDOM(editorHost);
      expect(editor).not.toBeNull();

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
        revision: 1,
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
  test("accepts fragment HTML only through a load-scoped capability MessagePort", async () => {
    const dom = new JSDOM('<!doctype html><main id="app"></main>', {
      url: "maru-app://render/render.html",
    });
    bootRenderer(dom.window.document, dom.window as unknown as Window);
    const capability = {
      documentRevision: 3,
      projectionGeneration: 4,
      widgetId: 5,
      widgetGeneration: 6,
      rendererInstance: 7,
    };
    const channel = new MessageChannel();
    const rendered = new Promise<unknown>((resolve) => {
      channel.port1.onmessage = (event) => {
        if ((event.data as { type?: string }).type === "fragment-ready") {
          channel.port1.postMessage({
            channel: fragmentChannel,
            type: "fragment-render",
            capability,
            html: '<p>isolated fragment <a href="next.md">next</a></p>',
          });
        } else resolve(event.data);
      };
      channel.port1.start();
    });
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window.parent,
        data: { channel: fragmentChannel, type: "fragment-init", capability },
        ports: [channel.port2] as unknown as readonly MessagePort[],
      }),
    );

    await expect(rendered).resolves.toMatchObject({
      channel: fragmentChannel,
      type: "fragment-rendered",
      capability,
    });
    expect(dom.window.document.querySelector("#app")?.textContent).toBe("isolated fragment next");
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

  test("allows raster data URLs and sanitizes SVG before creating a data URL", () => {
    const dom = new JSDOM("");
    const targetWindow = dom.window as unknown as Window;
    expect(assetDataUrl("image/png", "iVBORw==", targetWindow)).toBe(
      "data:image/png;base64,iVBORw==",
    );
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
