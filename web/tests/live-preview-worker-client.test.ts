import { describe, expect, test } from "bun:test";
import { ChangeSet } from "@codemirror/state";
import type { LivePreviewRequest, ProjectionResult } from "../src/live-preview-protocol";
import {
  LivePreviewWorkerClient,
  type LivePreviewWorkerState,
  type WorkerPort,
} from "../src/live-preview-worker-client";

const viewport = { from: 0, to: 0, active: false } as const;

class FakeWorker implements WorkerPort {
  readonly sent: LivePreviewRequest[] = [];
  terminated = false;
  throwOnPost = false;
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;

  postMessage(message: LivePreviewRequest): void {
    if (this.throwOnPost) throw new Error("post failed");
    this.sent.push(message);
  }

  terminate(): void {
    this.terminated = true;
  }

  reply(result: ProjectionResult): void {
    this.onmessage?.({ data: result } as MessageEvent<unknown>);
  }
}

function result(documentRevision: number, projectionGeneration: number): ProjectionResult {
  return { type: "result", documentRevision, projectionGeneration, fragments: [] };
}

describe("live preview worker latest-only client", () => {
  test("keeps one in flight, composes one contiguous latest apply, and drops stale results", () => {
    const workers: FakeWorker[] = [];
    const projections: ProjectionResult[] = [];
    let source = "abc";
    let revision = 0;
    let generation = 1;
    const client = new LivePreviewWorkerClient(
      () => {
        const worker = new FakeWorker();
        workers.push(worker);
        return worker;
      },
      () => ({
        documentRevision: revision,
        projectionGeneration: generation,
        source,
        visibleRanges: [{ from: 0, to: source.length, active: false }],
      }),
      (value) => projections.push(value),
    );
    client.start();
    const worker = workers[0]!;
    expect(worker.sent.map(({ type }) => type)).toEqual(["seed"]);

    source = "aBc";
    revision = 1;
    generation = 2;
    client.submitChanges(0, 1, ChangeSet.of({ from: 1, to: 2, insert: "B" }, 3), 2, [
      { from: 0, to: 3, active: false },
    ]);
    expect(worker.sent).toHaveLength(1);
    worker.reply(result(0, 0));
    expect(worker.sent.map(({ type }) => type)).toEqual(["seed", "apply"]);

    source = "aBC";
    revision = 2;
    generation = 3;
    client.submitChanges(1, 2, ChangeSet.of({ from: 2, to: 3, insert: "C" }, 3), 3, [
      { from: 0, to: 3, active: false },
    ]);
    source = "ABC";
    revision = 3;
    generation = 4;
    client.submitChanges(2, 3, ChangeSet.of({ from: 0, to: 1, insert: "A" }, 3), 4, [
      { from: 0, to: 3, active: false },
      { from: 0, to: 3, active: true },
    ]);
    worker.reply(result(1, 1));
    expect(worker.sent).toHaveLength(2);
    expect(projections).toEqual([]);
    worker.reply(result(1, 2));
    expect(worker.sent).toHaveLength(3);
    expect(worker.sent[2]).toMatchObject({
      type: "apply",
      baseRevision: 1,
      targetRevision: 3,
      projectionGeneration: 4,
    });
    worker.reply(result(3, 4));
    expect(projections).toEqual([result(3, 4)]);
  });

  test("turns a revision gap into one latest seed after the current request completes", () => {
    const worker = new FakeWorker();
    let snapshotCalls = 0;
    const client = new LivePreviewWorkerClient(
      () => worker,
      () => {
        snapshotCalls += 1;
        return {
          documentRevision: snapshotCalls === 1 ? 0 : 7,
          projectionGeneration: snapshotCalls === 1 ? 1 : 8,
          source: snapshotCalls === 1 ? "old" : "latest",
          visibleRanges: [{ from: 0, to: 6, active: false }],
        };
      },
      () => {},
    );
    client.start();
    client.submitChanges(6, 7, ChangeSet.of({ from: 0, insert: "x" }, 6), 8, [viewport]);
    worker.reply(result(0, 0));
    expect(worker.sent).toHaveLength(2);
    expect(worker.sent[1]).toEqual({ type: "seed", documentRevision: 7, source: "latest" });
    expect(worker.terminated).toBe(false);
    worker.reply(result(7, 0));
    expect(worker.sent[2]).toMatchObject({ type: "project", documentRevision: 7 });
  });

  test("sends an immediately following edit without forcing a full seed", () => {
    const worker = new FakeWorker();
    const client = new LivePreviewWorkerClient(
      () => worker,
      () => ({
        documentRevision: 0,
        projectionGeneration: 1,
        source: "abc",
        visibleRanges: [viewport],
      }),
      () => {},
    );
    client.start();
    worker.reply(result(0, 0));
    worker.reply(result(0, 1));
    client.submitChanges(0, 1, ChangeSet.of({ from: 1, to: 2, insert: "B" }, 3), 2, [viewport]);
    expect(worker.sent.at(-1)).toMatchObject({
      type: "apply",
      baseRevision: 0,
      targetRevision: 1,
    });
  });

  test("restarts after timeout and disables projection after three failures in sixty seconds", () => {
    const workers: FakeWorker[] = [];
    const states: LivePreviewWorkerState[] = [];
    let now = 0;
    let nextId = 0;
    const callbacks = new Map<number, () => void>();
    const client = new LivePreviewWorkerClient(
      () => {
        const worker = new FakeWorker();
        workers.push(worker);
        return worker;
      },
      () => ({
        documentRevision: 0,
        projectionGeneration: 1,
        source: "seed",
        visibleRanges: [viewport],
      }),
      () => {},
      (state) => states.push(state),
      {
        now: () => now,
        schedule: (callback) => {
          nextId += 1;
          callbacks.set(nextId, callback);
          return nextId as unknown as ReturnType<typeof setTimeout>;
        },
        cancel: (handle) => callbacks.delete(handle as unknown as number),
      },
    );
    client.start();
    for (let failure = 0; failure < 3; failure += 1) {
      const timeout = [...callbacks.entries()][0];
      expect(timeout).toBeDefined();
      callbacks.delete(timeout![0]);
      timeout![1]();
      now += 10;
      if (failure < 2) {
        const restart = [...callbacks.entries()][0];
        expect(restart).toBeDefined();
        callbacks.delete(restart![0]);
        restart![1]();
      }
    }
    expect(workers).toHaveLength(3);
    expect(workers.every(({ terminated }) => terminated)).toBe(true);
    expect(states.at(-1)).toBe("disabled");
  });

  test("routes synchronous create and post failures through bounded recovery", () => {
    const states: LivePreviewWorkerState[] = [];
    let attempts = 0;
    const callbacks: Array<() => void> = [];
    const client = new LivePreviewWorkerClient(
      () => {
        attempts += 1;
        if (attempts === 1) throw new Error("create failed");
        const worker = new FakeWorker();
        worker.throwOnPost = true;
        return worker;
      },
      () => ({
        documentRevision: 0,
        projectionGeneration: 1,
        source: "x",
        visibleRanges: [viewport],
      }),
      () => {},
      (state) => states.push(state),
      {
        now: () => attempts,
        schedule: (callback) => {
          callbacks.push(callback);
          return callbacks.length as unknown as ReturnType<typeof setTimeout>;
        },
        cancel: () => {},
      },
    );
    client.start();
    expect(states.at(-1)).toBe("recovering");
    callbacks.shift()?.();
    expect(states.at(-1)).toBe("recovering");
  });

  test("ignores queued callbacks from a retired worker epoch", () => {
    const workers: FakeWorker[] = [];
    const callbacks: Array<() => void> = [];
    const projections: ProjectionResult[] = [];
    const client = new LivePreviewWorkerClient(
      () => {
        const worker = new FakeWorker();
        workers.push(worker);
        return worker;
      },
      () => ({
        documentRevision: 0,
        projectionGeneration: 1,
        source: "x",
        visibleRanges: [viewport],
      }),
      (projection) => projections.push(projection),
      () => {},
      {
        now: () => 0,
        schedule: (callback) => {
          callbacks.push(callback);
          return callbacks.length as unknown as ReturnType<typeof setTimeout>;
        },
        cancel: () => {},
      },
    );
    client.start();
    const staleMessage = workers[0]!.onmessage!;
    callbacks.shift()?.();
    callbacks.shift()?.();
    expect(workers).toHaveLength(2);
    staleMessage({ data: result(0, 0) } as MessageEvent<unknown>);
    expect(projections).toEqual([]);
    expect(workers[1]!.terminated).toBe(false);
  });

  test("resyncs before serializing more than 64 KiB of change metadata", () => {
    const worker = new FakeWorker();
    let revision = 0;
    let source = "x".repeat(2_048);
    const client = new LivePreviewWorkerClient(
      () => worker,
      () => ({
        documentRevision: revision,
        projectionGeneration: 1,
        source,
        visibleRanges: [viewport],
      }),
      () => {},
    );
    client.start();
    const changes = ChangeSet.of(
      Array.from({ length: 1_025 }, (_, from) => ({ from, to: from, insert: "y" })),
      source.length,
    );
    revision = 1;
    source = "latest";
    client.submitChanges(0, 1, changes, 2, [viewport]);
    worker.reply(result(0, 0));
    expect(worker.sent.some(({ type }) => type === "apply")).toBe(false);
    expect(worker.sent.at(-1)?.type).toBe("seed");
  });

  test("does not create or post a worker for a source snapshot above 8 MiB", () => {
    let creates = 0;
    const states: LivePreviewWorkerState[] = [];
    const client = new LivePreviewWorkerClient(
      () => {
        creates += 1;
        return new FakeWorker();
      },
      () => ({
        documentRevision: 0,
        projectionGeneration: 1,
        source: "x".repeat(8 * 1024 * 1024 + 1),
        visibleRanges: [viewport],
      }),
      () => {},
      (state) => states.push(state),
    );
    client.start();
    expect(creates).toBe(0);
    expect(states.at(-1)).toBe("disabled");
  });

  test("checks the source cap again before a resync seed", () => {
    const worker = new FakeWorker();
    let source = "x";
    let revision = 0;
    const states: Array<{ state: LivePreviewWorkerState; reason?: string }> = [];
    const client = new LivePreviewWorkerClient(
      () => worker,
      () => ({
        documentRevision: revision,
        projectionGeneration: 1,
        source,
        visibleRanges: [viewport],
      }),
      () => {},
      (state, reason) => states.push({ state, reason }),
    );
    client.start();
    source = "x".repeat(8 * 1024 * 1024 + 1);
    revision = 7;
    client.submitChanges(6, 7, ChangeSet.of({ from: 0, insert: "y" }, 1), 2, [viewport]);
    worker.reply(result(0, 0));
    expect(worker.sent).toHaveLength(1);
    expect(worker.terminated).toBe(true);
    expect(states.at(-1)).toEqual({ state: "disabled", reason: "source-cap-exceeded" });

    const exactWorker = new FakeWorker();
    source = "x";
    revision = 0;
    const exact = new LivePreviewWorkerClient(
      () => exactWorker,
      () => ({
        documentRevision: revision,
        projectionGeneration: 1,
        source,
        visibleRanges: [viewport],
      }),
      () => {},
    );
    exact.start();
    source = "x".repeat(8 * 1024 * 1024);
    revision = 7;
    exact.submitChanges(6, 7, ChangeSet.of({ from: 0, insert: "y" }, 1), 2, [viewport]);
    exactWorker.reply(result(0, 0));
    expect(exactWorker.sent.at(-1)).toMatchObject({ type: "seed", documentRevision: 7 });
  });
});
