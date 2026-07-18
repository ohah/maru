import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  assetBase64BudgetAllowed,
  assetDataUrl,
  assetRequestCountAllowed,
  bootRenderer,
  bootShell,
  isLinkActivation,
  isAssetRequest,
  isRendererReport,
  requestFileBridge,
  maxAssetBase64Bytes,
  maxAssetRequests,
  viewerChannel,
} from "../src/viewer";

describe("file viewer bridge boundary", () => {
  test("page-world DOM mailbox receives a result and removes transferred bytes", async () => {
    const dom = new JSDOM("<!doctype html><html><body></body></html>");
    const document = dom.window.document;
    document.addEventListener("maru:file-request", () => {
      const node = document.querySelector<HTMLElement>('[data-maru-file-request="pending"]');
      expect(node?.textContent).toBe('{"method":"read"}');
      if (node === null) return;
      node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content: "# FP4" } });
      node.dataset.maruFileRequest = "done";
      document.dispatchEvent(new dom.window.Event("maru:file-response"));
    });

    await expect(requestFileBridge(document, "read", undefined, 100)).resolves.toEqual({
      content: "# FP4",
    });
    expect(document.querySelector("[data-maru-file-request]")).toBeNull();
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

    await requestFileBridge(document, "write", "# 저장", 100);
    await requestFileBridge(document, "setDirty", true, 100);
    await requestFileBridge(
      document,
      "openLink",
      { href: "../guide/next.md#usage", forceSystem: false },
      100,
    );
    await requestFileBridge(document, "resolveExternalChange", false, 100);
    expect(requests).toEqual([
      { method: "write", content: "# 저장" },
      { method: "setDirty", dirty: true },
      { method: "openLink", href: "../guide/next.md#usage", forceSystem: false },
      { method: "resolveExternalChange", success: false },
    ]);
    expect(JSON.stringify(requests)).not.toContain("path");
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
      { url: "maru-app://app/index.html" },
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
      { method: "openLink", href: "../guide/next.md#usage", forceSystem: false },
    ]);
  });
});

describe("bridge-free renderer", () => {
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
