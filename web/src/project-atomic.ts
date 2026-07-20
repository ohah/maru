import {
  atomicProjectionBatchWireBytes,
  atomicProjectionRequestShapeValid,
  atomicSourceFingerprint,
  atomicSourceWithinLimit,
  maxAtomicAssetGrants,
  type AssetGrant,
  type AtomicProjectionRequest,
  type AtomicProjectionResult,
} from "./atomic-projection";
import { renderAtomicMarkdown } from "./markdown";
import { maxLivePreviewResultBytes } from "./live-preview-protocol";
import type {
  AtomicProjectionRejection,
  AtomicProjectionRejectionReason,
} from "./live-preview-protocol";

export type AtomicProjectionBatch = Readonly<{
  results: readonly AtomicProjectionResult[];
  rejected: readonly AtomicProjectionRejection[];
  hashedBytes: number;
}>;

// Prism's token markup can expand punctuation-dense code far beyond its source size. Larger fences keep the
// atomic layout but use escaped plain code, whose worst-case entity expansion stays below the 2 MiB result cap.
export const maxPrismAtomicSourceBytes = 32 * 1024;

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function renderPlainFencedCode(source: string): Readonly<{
  html: string;
  assetPaths: readonly string[];
}> {
  const firstLineEnd = source.indexOf("\n");
  const lastLineStart = source.lastIndexOf("\n");
  const body =
    firstLineEnd >= 0 && lastLineStart > firstLineEnd
      ? source.slice(firstLineEnd + 1, lastLineStart)
      : source;
  return { html: `<pre><code>${escapeHtml(body)}</code></pre>`, assetPaths: [] };
}

function expectedMimeFamily(path: string): AssetGrant["expectedMimeFamily"] {
  return path.toLowerCase().endsWith(".svg") ? "svg-image" : "raster-image";
}

function reject(
  request: AtomicProjectionRequest,
  reason: AtomicProjectionRejectionReason,
): AtomicProjectionRejection {
  return { requestNonce: request.requestNonce, reason };
}

export function projectAtomicRequests(
  source: string,
  requests: readonly AtomicProjectionRequest[],
): AtomicProjectionBatch {
  const results: AtomicProjectionResult[] = [];
  const rejected: AtomicProjectionRejection[] = [];
  let hashedBytes = 0;
  for (const [requestIndex, request] of requests.entries()) {
    if (!atomicProjectionRequestShapeValid(request, source.length)) {
      rejected.push(reject(request, "invalid-request"));
      continue;
    }
    if (request.kind === "mermaid") {
      rejected.push(reject(request, "renderer-unavailable"));
      continue;
    }
    const selected = source.slice(request.from, request.to);
    if (!atomicSourceWithinLimit(request.kind, selected)) {
      rejected.push(reject(request, "rich-source-limit"));
      continue;
    }
    const fingerprint = atomicSourceFingerprint(selected);
    hashedBytes += fingerprint.sourceBytes;
    const rendered =
      request.kind === "fenced-code" && fingerprint.sourceBytes > maxPrismAtomicSourceBytes
        ? renderPlainFencedCode(selected)
        : renderAtomicMarkdown(selected);
    if (rendered.assetPaths.length > maxAtomicAssetGrants) {
      rejected.push(reject(request, "rich-source-limit"));
      continue;
    }
    const assetGrants: AssetGrant[] = rendered.assetPaths.map((path, index) => {
      const opaqueId = index + 1;
      const assetNonce = request.requestNonce * (maxAtomicAssetGrants + 1) + opaqueId;
      if (!Number.isSafeInteger(assetNonce)) throw new RangeError("asset nonce exhausted");
      return {
        editorEpoch: request.editorEpoch,
        assetNonce,
        opaqueId,
        normalizedPath: path,
        expectedMimeFamily: expectedMimeFamily(path),
      };
    });
    const result = {
      request,
      sourceHash: fingerprint.sourceHash,
      sanitizedPayload: rendered.html,
      assetGrants,
    } satisfies AtomicProjectionResult;
    const remainingTerminalCount = requests.length - requestIndex - 1;
    if (
      atomicProjectionBatchWireBytes([...results, result], rejected, remainingTerminalCount) >
      maxLivePreviewResultBytes
    ) {
      rejected.push(reject(request, "rich-source-limit"));
      continue;
    }
    results.push(result);
  }
  return { results, rejected, hashedBytes };
}
