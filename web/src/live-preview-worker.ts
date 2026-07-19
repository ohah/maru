import {
  applySourceChangesBounded,
  isLivePreviewRequest,
  isProjectionResult,
  type LivePreviewResponse,
  type ProjectionResult,
  utf8Length,
} from "./live-preview-protocol";
import { MarkdownProjectionIndex } from "./project-markdown";

type WorkerScope = Readonly<{
  postMessage: (message: LivePreviewResponse) => void;
}> & {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
};

const workerScope = globalThis as unknown as WorkerScope;
let source = "";
let sourceBytes = 0;
let documentRevision: number | null = null;
let projectionIndex = new MarkdownProjectionIndex("");

function fail(reason: string): void {
  workerScope.postMessage({ type: "failure", reason: reason.slice(0, 128) });
}

function sendResult(result: ProjectionResult): void {
  if (!isProjectionResult(result)) {
    fail("result-cap-exceeded");
    return;
  }
  workerScope.postMessage(result);
}

workerScope.onmessage = (event) => {
  const request = event.data;
  if (!isLivePreviewRequest(request)) {
    fail("invalid-request");
    return;
  }
  if (request.type === "seed") {
    source = request.source;
    sourceBytes = utf8Length(source);
    projectionIndex = new MarkdownProjectionIndex(source);
    documentRevision = request.documentRevision;
    sendResult({
      type: "result",
      documentRevision,
      projectionGeneration: 0,
      fragments: [],
    });
    return;
  }
  if (documentRevision === null) {
    fail("seed-required");
    return;
  }
  if (request.type === "apply") {
    if (request.baseRevision !== documentRevision) {
      fail("revision-gap");
      return;
    }
    const next = applySourceChangesBounded(source, sourceBytes, request.changes);
    if (next === null) {
      fail("invalid-change");
      return;
    }
    source = next.source;
    sourceBytes = next.sourceBytes;
    projectionIndex = new MarkdownProjectionIndex(source);
    documentRevision = request.targetRevision;
    sendResult({
      type: "result",
      documentRevision,
      projectionGeneration: request.projectionGeneration,
      fragments: projectionIndex.project(request.visibleRanges),
    });
    return;
  }
  if (request.documentRevision !== documentRevision) {
    fail("revision-gap");
    return;
  }
  sendResult({
    type: "result",
    documentRevision,
    projectionGeneration: request.projectionGeneration,
    fragments: projectionIndex.project(request.visibleRanges),
  });
};
