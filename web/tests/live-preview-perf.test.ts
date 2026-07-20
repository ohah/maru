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
    scenario: "fp11b-8mib-1000-editable-projection",
    counters: {
      visited_code_units: 64_000,
      visited_syntax_nodes: 8_000,
      selection_range_checks: 1_000,
      math_scanned_code_units: 1_000,
      dense_math_scanned_code_units: 32_768,
      emitted_decorations: 4,
      diffed_decorations: 5_000,
      copied_bytes: 0,
      source_transactions: 1_000,
      projection_transactions: 1,
      dom_mutations: 0,
      iframe_create: 0,
      iframe_destroy: 0,
      retained_html_bytes: 0,
      generated_outside_retention: 0,
      projection_fallback_counts: Object.fromEntries(
        projectionFallbackReasons.map((reason) => [
          reason,
          reason === "atomic-not-enabled" ? 1 : 0,
        ]),
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

  test("requires the closed FP11b schema and bounded nonzero projection counters", () => {
    const current = artifact();
    expect(() => validateLivePreviewPerfArtifact(current)).not.toThrow();
    for (const name of [
      "copied_bytes",
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
    for (const reason of projectionFallbackReasons.filter(
      (candidate) => candidate !== "atomic-not-enabled",
    )) {
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
      ).toThrow("projection fallback mismatch");
    }
    expect(() =>
      validateLivePreviewPerfArtifact({
        ...current,
        counters: {
          ...current.counters,
          projection_fallback_counts: {
            ...current.counters.projection_fallback_counts,
            "atomic-not-enabled": 0,
          },
        },
      }),
    ).toThrow("projection fallback mismatch");
    expect(() =>
      validateLivePreviewPerfArtifact({
        ...current,
        counters: { ...current.counters, source_transactions: 999 },
      }),
    ).toThrow("fixture incomplete");
    for (const [name, value] of [
      ["projection_transactions", 2],
      ["dom_mutations", 1],
      ["dense_math_scanned_code_units", 32_769],
      ["dense_math_scanned_code_units", 1_000_000],
    ] as const) {
      expect(() =>
        validateLivePreviewPerfArtifact({
          ...current,
          counters: { ...current.counters, [name]: value },
        }),
      ).toThrow("budget exceeded");
    }
  });
});
