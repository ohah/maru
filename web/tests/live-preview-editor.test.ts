import { describe, expect, test } from "bun:test";
import { EditorSelection } from "@codemirror/state";
import {
  AtomicProjectionController,
  atomicRecordCanBeReused,
  atomicRangeRetained,
  reconcileAtomicBatch,
} from "../src/live-preview-editor";
import { createMarkdownEditor } from "../src/editor";
import type { LivePreviewRequest, ProjectionResult } from "../src/live-preview-protocol";
import { EditorRevisionClock } from "../src/live-preview-state";
import { atomicRendererChannel } from "../src/renderer-capability";
import { withEditorDom } from "./editor-dom";

class FakeAtomicWorker {
  static latest: FakeAtomicWorker | null = null;
  static instances: FakeAtomicWorker[] = [];
  readonly sent: LivePreviewRequest[] = [];
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;
  constructor(_url: string) {
    FakeAtomicWorker.latest = this;
    FakeAtomicWorker.instances.push(this);
  }
  postMessage(message: LivePreviewRequest): void {
    this.sent.push(message);
  }
  terminate(): void {}
  reply(result: ProjectionResult): void {
    this.onmessage?.({ data: result } as MessageEvent<unknown>);
  }
  fail(): void {
    this.onerror?.(new Event("error"));
  }
}

function imageProjection(
  request: Extract<LivePreviewRequest, { type: "project" | "apply" }>["requests"][number],
  assetNonce: number,
): ProjectionResult["results"][number] {
  return {
    request,
    sourceHash: "0123456789abcdef",
    sanitizedPayload: '<img data-maru-asset-id="1">',
    assetGrants: [
      {
        editorEpoch: request.editorEpoch,
        assetNonce,
        opaqueId: 1,
        normalizedPath: "image.png",
        expectedMimeFamily: "raster-image",
      },
    ],
  };
}

describe("live preview atomic frame budget", () => {
  test("reuses only same-document geometry while rejecting a different document revision", () => {
    const capability = {
      editorEpoch: 1,
      documentRevision: 2,
      projectionGeneration: 3,
      widgetId: 4,
      widgetGeneration: 5,
      rendererInstance: 6,
    };
    const range = { from: 10, to: 20 };
    expect(
      atomicRecordCanBeReused(
        capability,
        {
          editorEpoch: 1,
          documentRevision: 2,
          projectionGeneration: 3,
          requestNonce: 7,
          kind: "image",
          ...range,
        },
        {
          editorEpoch: 1,
          documentRevision: 2,
          projectionGeneration: 3,
          requestNonce: 7,
          kind: "image",
          ...range,
        },
      ),
    ).toBe(true);
    expect(
      atomicRecordCanBeReused(
        capability,
        {
          editorEpoch: 1,
          documentRevision: 2,
          projectionGeneration: 3,
          requestNonce: 7,
          kind: "image",
          ...range,
        },
        {
          editorEpoch: 1,
          documentRevision: 2,
          projectionGeneration: 4,
          requestNonce: 7,
          kind: "image",
          ...range,
        },
      ),
    ).toBe(true);
    expect(
      atomicRecordCanBeReused(
        capability,
        {
          editorEpoch: 1,
          documentRevision: 2,
          projectionGeneration: 3,
          requestNonce: 7,
          kind: "image",
          ...range,
        },
        {
          editorEpoch: 1,
          documentRevision: 3,
          projectionGeneration: 4,
          requestNonce: 8,
          kind: "image",
          ...range,
        },
      ),
    ).toBe(false);
  });

  test("removes before adding and changes at most two iframe memberships per batch", () => {
    let current = [1, 2, 3, 4, 5, 6, 7, 8];
    const desired = [11, 12, 13, 14, 15, 16, 17, 18];
    const changes: Array<{ removed: number; added: number }> = [];
    while (
      current.some((value) => !desired.includes(value)) ||
      desired.some((v) => !current.includes(v))
    ) {
      const batch = reconcileAtomicBatch(current, desired, (left, right) => left === right);
      changes.push({ removed: batch.removed, added: batch.added });
      current = batch.next;
    }

    expect(current).toEqual(desired);
    expect(changes.every(({ removed, added }) => removed <= 2 && added <= 2)).toBe(true);
    expect(changes.slice(0, 4).every(({ removed, added }) => removed === 2 && added === 0)).toBe(
      true,
    );
    expect(changes.slice(4).every(({ removed, added }) => removed === 0 && added === 2)).toBe(true);
  });

  test("retains only discovery-external ranges inside two viewport lengths", () => {
    const viewport = { from: 100, to: 200 };
    const discovery = { from: 0, to: 300 };
    expect(atomicRangeRetained({ from: 300, to: 320 }, discovery, viewport, 1_000)).toBe(true);
    expect(atomicRangeRetained({ from: 250, to: 280 }, discovery, viewport, 1_000)).toBe(false);
    expect(atomicRangeRetained({ from: 400, to: 420 }, discovery, viewport, 1_000)).toBe(false);
  });

  test("mounts only the current epoch request and removes the widget when source is selected", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)\n\nplain";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      const metrics: Array<{ desired: number; mounted: number }> = [];
      const controller = new AtomicProjectionController(
        editor,
        9,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => null,
        () => {},
        (value) => metrics.push(value),
      );
      try {
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
          { type: "atomic", role: "image", from: 0, to: 17 },
        ]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        expect(worker?.sent[0]).toMatchObject({ type: "seed", editorEpoch: 9 });
        worker?.reply({
          type: "result",
          editorEpoch: 9,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const project = worker?.sent[1];
        expect(project).toMatchObject({ type: "project", editorEpoch: 9 });
        if (project?.type !== "project") throw new Error("missing atomic project request");
        const request = project.requests[0];
        if (request === undefined) throw new Error("missing atomic request");
        worker.reply({
          type: "result",
          editorEpoch: 9,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [
            {
              request,
              sourceHash: "0123456789abcdef",
              sanitizedPayload: "<p>image</p>",
              assetGrants: [],
            },
          ],
          rejected: [],
        });
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        const frame = editor.dom.querySelector<HTMLIFrameElement>(".maru-live-atomic-frame");
        expect(frame).not.toBeNull();
        expect(metrics.at(-1)).toEqual(expect.objectContaining({ desired: 1, mounted: 1 }));

        let rendererPort: MessagePort | null = null;
        let rendererCapability: unknown = null;
        if (frame?.contentWindow !== null && frame?.contentWindow !== undefined) {
          frame.contentWindow.postMessage = ((
            message: unknown,
            _target: string,
            ports?: Transferable[],
          ) => {
            rendererCapability = (message as { capability?: unknown }).capability;
            rendererPort = (ports?.[0] as MessagePort | undefined) ?? null;
          }) as typeof frame.contentWindow.postMessage;
        }
        frame?.dispatchEvent(new dom.window.Event("load"));
        expect(rendererPort).not.toBeNull();
        (rendererPort as MessagePort | null)!.onmessage = (event) => {
          if ((event.data as { type?: string }).type !== "atomic-render") return;
          (rendererPort as MessagePort | null)?.postMessage({
            channel: atomicRendererChannel,
            type: "atomic-rendered",
            capability: rendererCapability,
            height: 32,
          });
          (rendererPort as MessagePort | null)?.close();
        };
        (rendererPort as MessagePort | null)!.start();
        (rendererPort as MessagePort | null)!.postMessage({
          channel: atomicRendererChannel,
          type: "atomic-ready",
          capability: rendererCapability,
        });
        for (let turn = 0; turn < 10 && frame?.dataset.atomicRendered !== "true"; turn += 1)
          await new Promise((resolve) => dom.window.setTimeout(resolve, 0));
        expect(frame?.dataset.atomicRendered).toBe("true");

        const sentBeforeSelectionOnlyProjection = worker.sent.length;
        revisions.nextProjection();
        controller.submitEntries(0, 2, [{ type: "atomic", role: "image", from: 0, to: 17 }]);
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(worker.sent).toHaveLength(sentBeforeSelectionOnlyProjection);
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBe(frame);

        revisions.nextProjection();
        controller.submitEntries(0, 3, []);
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("drops an asset grant that completes after its projection is retired", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)\n\nplain";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      let releaseAsset: (value: string | null) => void = () => {};
      const asset = new Promise<string | null>((resolve) => {
        releaseAsset = resolve;
      });
      const controller = new AtomicProjectionController(
        editor,
        11,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () => asset,
      );
      try {
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
          { type: "atomic", role: "image", from: 0, to: 17 },
        ]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 11,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const project = worker?.sent[1];
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing atomic project request");
        worker.reply({
          type: "result",
          editorEpoch: 11,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [
            {
              request: project.requests[0],
              sourceHash: "0123456789abcdef",
              sanitizedPayload: '<img data-maru-asset-id="1">',
              assetGrants: [
                {
                  editorEpoch: 11,
                  assetNonce: 10,
                  opaqueId: 1,
                  normalizedPath: "image.png",
                  expectedMimeFamily: "raster-image",
                },
              ],
            },
          ],
          rejected: [],
        });
        revisions.nextProjection();
        controller.submitEntries(0, 2, []);
        releaseAsset("data:image/png;base64,iVBORw0KGgo=");
        await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("composes multiple document updates into one apply instead of reseeding the full source", async () => {
    await withEditorDom(async (dom) => {
      const revisions = new EditorRevisionClock();
      let controller: AtomicProjectionController | null = null;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "abc",
        (update) => {
          if (!update.docChanged) return;
          const baseRevision = revisions.documentRevision;
          const targetRevision = revisions.documentChanged();
          controller?.handleUpdate(update, baseRevision, targetRevision);
        },
        () => {},
      );
      controller = new AtomicProjectionController(
        editor,
        12,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => null,
      );
      try {
        controller.enable();
        editor.dispatch({ changes: { from: 0, to: 1, insert: "A" } });
        editor.dispatch({ changes: { from: 1, to: 2, insert: "B" } });
        const identity = revisions.nextProjection();
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, []);
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 12,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        expect(worker?.sent.filter(({ type }) => type === "seed")).toHaveLength(1);
        expect(worker?.sent.at(-1)).toMatchObject({
          type: "apply",
          baseRevision: 0,
          targetRevision: 2,
        });
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("keeps replay admission batch-scoped across sixty-five successful image projections", async () => {
    await withEditorDom(async () => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      let assetReads = 0;
      const controller = new AtomicProjectionController(
        editor,
        20,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => {
          assetReads += 1;
          return "data:image/png;base64,iVBORw0KGgo=";
        },
      );
      try {
        let identity = revisions.nextProjection();
        const entry = {
          type: "atomic" as const,
          role: "image" as const,
          from: 0,
          to: source.length,
        };
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [entry]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 20,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        for (let cycle = 1; cycle <= 65; cycle += 1) {
          const project = worker?.sent.at(-1);
          if (project?.type !== "project" || project.requests[0] === undefined)
            throw new Error("missing image projection cycle");
          worker.reply({
            type: "result",
            editorEpoch: 20,
            documentRevision: 0,
            projectionGeneration: identity.projectionGeneration,
            results: [imageProjection(project.requests[0], cycle)],
            rejected: [],
          });
          for (let turn = 0; turn < 3; turn += 1) await Promise.resolve();
          if (cycle < 65) {
            identity = revisions.nextProjection();
            controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
              entry,
            ]);
          }
        }
        expect(assetReads).toBe(65);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("keeps one stalled asset application plus only the latest result", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      let releaseFirst: (value: string | null) => void = () => {};
      const first = new Promise<string | null>((resolve) => {
        releaseFirst = resolve;
      });
      let assetReads = 0;
      const controller = new AtomicProjectionController(
        editor,
        21,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () => {
          assetReads += 1;
          return assetReads === 1 ? first : Promise.resolve("data:image/png;base64,iVBORw0KGgo=");
        },
      );
      const entry = { type: "atomic" as const, role: "image" as const, from: 0, to: source.length };
      try {
        let identity = revisions.nextProjection();
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 21,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        for (let result = 0; result < 100; result += 1) {
          const project = worker?.sent.at(-1);
          if (project?.type !== "project" || project.requests[0] === undefined)
            throw new Error("missing burst projection request");
          worker.reply({
            type: "result",
            editorEpoch: 21,
            documentRevision: 0,
            projectionGeneration: identity.projectionGeneration,
            results: [imageProjection(project.requests[0], 1_000 + result)],
            rejected: [],
          });
          if (result < 99) {
            identity = revisions.nextProjection();
            controller.submitEntries(0, identity.projectionGeneration, [entry]);
          }
        }
        expect(assetReads).toBe(1);
        releaseFirst("data:image/png;base64,iVBORw0KGgo=");
        for (let turn = 0; turn < 5; turn += 1) await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(2);
        expect(editor.dom.querySelectorAll(".maru-live-atomic-frame")).toHaveLength(1);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("turns a rejected asset promise into range-local fallback and drains the next result", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const metrics: Array<{ rendererUnavailable: number }> = [];
      let assetReads = 0;
      const controller = new AtomicProjectionController(
        editor,
        22,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () => {
          assetReads += 1;
          return assetReads === 1
            ? Promise.reject(new Error("bridge timeout"))
            : Promise.resolve("data:image/png;base64,iVBORw0KGgo=");
        },
        () => {},
        (value) => metrics.push(value),
      );
      const entry = { type: "atomic" as const, role: "image" as const, from: 0, to: source.length };
      try {
        let identity = revisions.nextProjection();
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 22,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        let project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing rejected asset request");
        worker.reply({
          type: "result",
          editorEpoch: 22,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(project.requests[0], 2_000)],
          rejected: [],
        });
        for (let turn = 0; turn < 3; turn += 1) await Promise.resolve();
        expect(metrics.at(-1)?.rendererUnavailable).toBe(1);

        identity = revisions.nextProjection();
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing recovery asset request");
        worker.reply({
          type: "result",
          editorEpoch: 22,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(project.requests[0], 2_001)],
          rejected: [],
        });
        for (let turn = 0; turn < 3; turn += 1) await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(2);
        expect(editor.dom.querySelectorAll(".maru-live-atomic-frame")).toHaveLength(1);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("drops an old asset when the exact identity receives a replacement request batch", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      let releaseOld: (value: string | null) => void = () => {};
      const oldAsset = new Promise<string | null>((resolve) => {
        releaseOld = resolve;
      });
      let assetReads = 0;
      const metrics: Array<{
        desired: number;
        staleCapability: number;
        staleCapabilityTotal: number;
      }> = [];
      const controller = new AtomicProjectionController(
        editor,
        25,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () => {
          assetReads += 1;
          return assetReads === 1
            ? oldAsset
            : Promise.resolve("data:image/png;base64,iVBORw0KGgo=");
        },
        () => {},
        (value) => metrics.push(value),
      );
      const entry = {
        type: "atomic" as const,
        role: "image" as const,
        from: 0,
        to: source.length,
      };
      try {
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 25,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const oldProject = worker?.sent.at(-1);
        if (oldProject?.type !== "project" || oldProject.requests[0] === undefined)
          throw new Error("missing old same-identity request");
        worker.reply({
          type: "result",
          editorEpoch: 25,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(oldProject.requests[0], 4_000)],
          rejected: [],
        });
        expect(assetReads).toBe(1);

        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        const newProject = worker?.sent.at(-1);
        if (newProject?.type !== "project" || newProject.requests[0] === undefined)
          throw new Error("missing replacement same-identity request");
        expect(newProject.requests[0].requestNonce).not.toBe(oldProject.requests[0].requestNonce);
        releaseOld("data:image/png;base64,iVBORw0KGgo=");
        await Promise.resolve();
        expect(metrics.at(-1)).toEqual(
          expect.objectContaining({
            desired: 0,
            staleCapability: 0,
            staleCapabilityTotal: 1,
          }),
        );
        worker.reply({
          type: "result",
          editorEpoch: 25,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(newProject.requests[0], 4_001)],
          rejected: [],
        });
        for (let turn = 0; turn < 3; turn += 1) await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(2);
        expect(editor.dom.querySelectorAll(".maru-live-atomic-frame")).toHaveLength(1);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("rejects a duplicate asset nonce batch and consumes a replayed result at most once", async () => {
    await withEditorDom(async (dom) => {
      const source = "![a](a.png)\n\n![b](b.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      let assetReads = 0;
      const metrics: Array<{ staleCapability: number; staleCapabilityTotal: number }> = [];
      const controller = new AtomicProjectionController(
        editor,
        26,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => {
          assetReads += 1;
          return "data:image/png;base64,iVBORw0KGgo=";
        },
        () => {},
        (value) => metrics.push(value),
      );
      const firstTo = source.indexOf("\n");
      const secondFrom = source.lastIndexOf("!");
      const identity = revisions.nextProjection();
      try {
        controller.submitEntries(0, identity.projectionGeneration, [
          { type: "atomic", role: "image", from: 0, to: firstTo },
          { type: "atomic", role: "image", from: secondFrom, to: source.length },
        ]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 26,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests.length !== 2)
          throw new Error("missing duplicate-nonce batch requests");
        const duplicateNonceResult: ProjectionResult = {
          type: "result",
          editorEpoch: 26,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [
            imageProjection(project.requests[0]!, 5_000),
            imageProjection(project.requests[1]!, 5_000),
          ],
          rejected: [],
        };
        worker.reply(duplicateNonceResult);
        await Promise.resolve();
        worker.reply(duplicateNonceResult);
        await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(0);
        expect(metrics.at(-1)).toEqual(
          expect.objectContaining({ staleCapability: 1, staleCapabilityTotal: 1 }),
        );
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("does not admit an old activation asset after disable and re-enable", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)\n\nplain";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      let releaseOld: (value: string | null) => void = () => {};
      const oldAsset = new Promise<string | null>((resolve) => {
        releaseOld = resolve;
      });
      let assetAttempt = 0;
      const controller = new AtomicProjectionController(
        editor,
        13,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () =>
          ++assetAttempt === 1 ? oldAsset : Promise.resolve("data:image/png;base64,iVBORw0KGgo="),
      );
      try {
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
          { type: "atomic", role: "image", from: 0, to: 17 },
        ]);
        controller.enable();
        const oldWorker = FakeAtomicWorker.latest;
        oldWorker?.reply({
          type: "result",
          editorEpoch: 13,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const oldProject = oldWorker?.sent.at(-1);
        if (oldProject?.type !== "project" || oldProject.requests[0] === undefined)
          throw new Error("missing old atomic request");
        oldWorker.reply({
          type: "result",
          editorEpoch: 13,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [
            {
              request: oldProject.requests[0],
              sourceHash: "0123456789abcdef",
              sanitizedPayload: '<img data-maru-asset-id="1">',
              assetGrants: [
                {
                  editorEpoch: 13,
                  assetNonce: 101,
                  opaqueId: 1,
                  normalizedPath: "image.png",
                  expectedMimeFamily: "raster-image",
                },
              ],
            },
          ],
          rejected: [],
        });
        controller.disable();
        controller.enable();
        const newWorker = FakeAtomicWorker.latest;
        newWorker?.reply({
          type: "result",
          editorEpoch: 13,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const newProject = newWorker?.sent.at(-1);
        if (newProject?.type !== "project" || newProject.requests[0] === undefined)
          throw new Error("missing new atomic request");
        expect(newProject.requests[0].requestNonce).not.toBe(oldProject.requests[0].requestNonce);
        releaseOld("data:image/png;base64,iVBORw0KGgo=");
        await Promise.resolve();
        newWorker.reply({
          type: "result",
          editorEpoch: 13,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [
            {
              request: newProject.requests[0],
              sourceHash: "0123456789abcdef",
              sanitizedPayload: '<img data-maru-asset-id="1">',
              assetGrants: [
                {
                  editorEpoch: 13,
                  assetNonce: 202,
                  opaqueId: 1,
                  normalizedPath: "image.png",
                  expectedMimeFamily: "raster-image",
                },
              ],
            },
          ],
          rejected: [],
        });
        await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(editor.dom.querySelectorAll(".maru-live-atomic-frame")).toHaveLength(1);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("regenerates request identity after worker recovery and drops the retired asset", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      let releaseOld: (value: string | null) => void = () => {};
      const oldAsset = new Promise<string | null>((resolve) => {
        releaseOld = resolve;
      });
      let assetReads = 0;
      const controller = new AtomicProjectionController(
        editor,
        23,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        () => {
          assetReads += 1;
          return assetReads === 1
            ? oldAsset
            : Promise.resolve("data:image/png;base64,iVBORw0KGgo=");
        },
      );
      const identity = revisions.nextProjection();
      const entry = { type: "atomic" as const, role: "image" as const, from: 0, to: source.length };
      try {
        const instanceStart = FakeAtomicWorker.instances.length;
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        controller.enable();
        const oldWorker = FakeAtomicWorker.instances[instanceStart];
        oldWorker?.reply({
          type: "result",
          editorEpoch: 23,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const oldProject = oldWorker?.sent.at(-1);
        if (oldProject?.type !== "project" || oldProject.requests[0] === undefined)
          throw new Error("missing pre-recovery request");
        oldWorker.reply({
          type: "result",
          editorEpoch: 23,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(oldProject.requests[0], 3_000)],
          rejected: [],
        });
        expect(assetReads).toBe(1);
        oldWorker.fail();
        await new Promise((resolve) => dom.window.setTimeout(resolve, 300));
        const newWorker = FakeAtomicWorker.instances[instanceStart + 1];
        expect(newWorker).toBeDefined();
        newWorker?.reply({
          type: "result",
          editorEpoch: 23,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const newProject = newWorker?.sent.at(-1);
        if (newProject?.type !== "project" || newProject.requests[0] === undefined)
          throw new Error("missing post-recovery request");
        expect(newProject.requests[0].requestNonce).not.toBe(oldProject.requests[0].requestNonce);
        releaseOld("data:image/png;base64,iVBORw0KGgo=");
        await Promise.resolve();
        newWorker.reply({
          type: "result",
          editorEpoch: 23,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [imageProjection(newProject.requests[0], 3_001)],
          rejected: [],
        });
        for (let turn = 0; turn < 3; turn += 1) await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(2);
        expect(editor.dom.querySelectorAll(".maru-live-atomic-frame")).toHaveLength(1);
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("rejects missing and foreign terminal nonces without loader or DOM effects", async () => {
    await withEditorDom(async () => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      let assetReads = 0;
      const metrics: Array<{
        desired: number;
        staleCapability: number;
        staleCapabilityTotal: number;
      }> = [];
      const controller = new AtomicProjectionController(
        editor,
        24,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => {
          assetReads += 1;
          return "data:image/png;base64,iVBORw0KGgo=";
        },
        () => {},
        (value) => metrics.push(value),
      );
      const entry = { type: "atomic" as const, role: "image" as const, from: 0, to: source.length };
      try {
        let identity = revisions.nextProjection();
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 24,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        worker?.reply({
          type: "result",
          editorEpoch: 24,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [],
          rejected: [],
        });
        await Promise.resolve();
        expect(metrics.at(-1)).toEqual(
          expect.objectContaining({ desired: 0, staleCapability: 1, staleCapabilityTotal: 1 }),
        );

        identity = revisions.nextProjection();
        controller.submitEntries(0, identity.projectionGeneration, [entry]);
        const project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing foreign terminal request");
        worker.reply({
          type: "result",
          editorEpoch: 24,
          documentRevision: 0,
          projectionGeneration: identity.projectionGeneration,
          results: [],
          rejected: [
            { requestNonce: project.requests[0].requestNonce + 1, reason: "invalid-request" },
          ],
        });
        await Promise.resolve();
        expect(metrics.at(-1)).toEqual(
          expect.objectContaining({ desired: 0, staleCapability: 1, staleCapabilityTotal: 2 }),
        );
        expect(assetReads).toBe(0);
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("drops a same-revision result from a different editor epoch before asset or DOM effects", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](image.png)";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      let assetReads = 0;
      const controller = new AtomicProjectionController(
        editor,
        17,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => {
          assetReads += 1;
          return "data:image/png;base64,iVBORw0KGgo=";
        },
      );
      try {
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
          { type: "atomic", role: "image", from: 0, to: source.length },
        ]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 17,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing atomic request");
        const staleRequest = { ...project.requests[0], editorEpoch: 18 };
        worker.reply({
          type: "result",
          editorEpoch: 18,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [
            {
              request: staleRequest,
              sourceHash: "0123456789abcdef",
              sanitizedPayload: '<img data-maru-asset-id="1">',
              assetGrants: [
                {
                  editorEpoch: 18,
                  assetNonce: 303,
                  opaqueId: 1,
                  normalizedPath: "image.png",
                  expectedMimeFamily: "raster-image",
                },
              ],
            },
          ],
          rejected: [],
        });
        await Promise.resolve();
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
        expect(assetReads).toBe(0);
        expect(editor.dom.querySelector(".maru-live-atomic-frame")).toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("derives desired widgets from successful registry records after a range-local rejection", async () => {
    await withEditorDom(async (dom) => {
      const source = "$x$";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      editor.dispatch({ selection: EditorSelection.cursor(source.length) });
      const revisions = new EditorRevisionClock();
      const identity = revisions.nextProjection();
      const metrics: Array<{
        desired: number;
        mounted: number;
        rendererUnavailable: number;
      }> = [];
      const controller = new AtomicProjectionController(
        editor,
        19,
        revisions,
        FakeAtomicWorker as unknown as typeof Worker,
        async () => null,
        () => {},
        (value) => metrics.push(value),
      );
      try {
        controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [
          { type: "atomic", role: "math", from: 0, to: source.length },
        ]);
        controller.enable();
        const worker = FakeAtomicWorker.latest;
        worker?.reply({
          type: "result",
          editorEpoch: 19,
          documentRevision: 0,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        });
        const project = worker?.sent.at(-1);
        if (project?.type !== "project" || project.requests[0] === undefined)
          throw new Error("missing atomic request");
        worker.reply({
          type: "result",
          editorEpoch: 19,
          documentRevision: 0,
          projectionGeneration: 1,
          results: [],
          rejected: [
            { requestNonce: project.requests[0].requestNonce, reason: "renderer-unavailable" },
          ],
        });
        await Promise.resolve();
        expect(metrics.at(-1)).toEqual(
          expect.objectContaining({ desired: 0, mounted: 0, rendererUnavailable: 1 }),
        );
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });
});
