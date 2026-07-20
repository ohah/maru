import { describe, expect, test } from "bun:test";
import { Text } from "@codemirror/state";
import { projectionFallbackReasons } from "../src/live-preview-diagnostics";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import {
  livePreviewPerfSchemaVersion,
  validateLivePreviewPerfArtifact,
  type LivePreviewPerfArtifact,
} from "../scripts/live-preview-perf-model";
import { startDocumentCopyProbe } from "../scripts/live-preview-perf-scenario";

function artifact(): LivePreviewPerfArtifact {
  return {
    schema_version: livePreviewPerfSchemaVersion,
    scenario: "fp11a-8mib-1000-input-baseline",
    counters: {
      visited_code_units: 0,
      visited_syntax_nodes: 0,
      emitted_decorations: 0,
      diffed_decorations: 0,
      copied_bytes: 0,
      source_transactions: 1_000,
      projection_transactions: 0,
      dom_mutations: 0,
      iframe_create: 0,
      iframe_destroy: 0,
      retained_html_bytes: 0,
      generated_outside_retention: 0,
      projection_fallback_counts: Object.fromEntries(
        projectionFallbackReasons.map((reason) => [reason, 0]),
      ),
    },
  };
}

describe("live preview performance artifact", () => {
  test("document copy probe detects an injected full-source serialization", () => {
    const probe = startDocumentCopyProbe();
    Text.of(["a".repeat(maxLivePreviewProjectionCodeUnits + 1)]).toString();
    expect(probe.stop()).toBeGreaterThan(0);
  });

  test("requires the closed schema and exact baseline thresholds", () => {
    const current = artifact();
    expect(() => validateLivePreviewPerfArtifact(current)).not.toThrow();
    for (const name of [
      "visited_code_units",
      "visited_syntax_nodes",
      "emitted_decorations",
      "diffed_decorations",
      "copied_bytes",
      "projection_transactions",
      "dom_mutations",
      "iframe_create",
      "iframe_destroy",
      "retained_html_bytes",
      "generated_outside_retention",
    ] as const) {
      expect(() =>
        validateLivePreviewPerfArtifact({
          ...current,
          counters: { ...current.counters, [name]: 1 },
        }),
      ).toThrow();
    }
    for (const reason of projectionFallbackReasons) {
      expect(() =>
        validateLivePreviewPerfArtifact({
          ...current,
          counters: {
            ...current.counters,
            projection_fallback_counts: {
              ...current.counters.projection_fallback_counts,
              [reason]: 1,
            },
          },
        }),
      ).toThrow("projection fallback");
    }
    expect(() =>
      validateLivePreviewPerfArtifact({
        ...current,
        counters: { ...current.counters, source_transactions: 999 },
      }),
    ).toThrow("fixture incomplete");
  });
});
