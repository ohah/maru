import {
  applySourceChangesBounded,
  isLivePreviewRequest,
  isProjectionResult,
  type LivePreviewResponse,
  type ProjectionResult,
  utf8Length,
} from "./live-preview-protocol";
import { projectAtomicRequests } from "./project-atomic";

type WorkerScope = Readonly<{
  postMessage: (message: LivePreviewResponse) => void;
}> & {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
};

const workerScope = globalThis as unknown as WorkerScope;
let source = "";
let sourceBytes = 0;
let editorEpoch: number | null = null;
let documentRevision: number | null = null;

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
    editorEpoch = request.editorEpoch;
    documentRevision = request.documentRevision;
    sendResult({
      type: "result",
      editorEpoch,
      documentRevision,
      projectionGeneration: 0,
      results: [],
      rejected: [],
    });
    return;
  }
  if (documentRevision === null || editorEpoch === null) {
    fail("seed-required");
    return;
  }
  if (request.editorEpoch !== editorEpoch) {
    fail("epoch-mismatch");
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
    documentRevision = request.targetRevision;
    const batch = projectAtomicRequests(source, request.requests);
    sendResult({
      type: "result",
      editorEpoch,
      documentRevision,
      projectionGeneration: request.projectionGeneration,
      results: batch.results,
      rejected: batch.rejected,
    });
    return;
  }
  if (request.documentRevision !== documentRevision) {
    fail("revision-gap");
    return;
  }
  const batch = projectAtomicRequests(source, request.requests);
  sendResult({
    type: "result",
    editorEpoch,
    documentRevision,
    projectionGeneration: request.projectionGeneration,
    results: batch.results,
    rejected: batch.rejected,
  });
};
