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
    scenario: "fp11c-8mib-1000-editable-projection-interactions",
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
      intent_events: 6,
      intent_cm6_transactions: 1,
      intent_external_actions: 1,
      intent_dual_effects: 0,
      intent_zero_effect_rejections: 4,
      intent_range_checks: 4,
      intent_queue_capacity: 8,
      intent_queue_max_retained: 8,
      intent_queue_dropped: 1,
      intent_bridge_calls: 2,
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

  test("requires the closed FP11c schema and exact interaction effect counters", () => {
    const current = artifact();
    expect(() => validateLivePreviewPerfArtifact(current)).not.toThrow();
    for (const name of [
      "copied_bytes",
      "iframe_create",
      "iframe_destroy",
      "retained_html_bytes",
      "generated_outside_retention",
      "intent_dual_effects",
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
      ["intent_events", 7],
      ["intent_cm6_transactions", 2],
      ["intent_external_actions", 2],
      ["intent_zero_effect_rejections", 3],
      ["intent_range_checks", 0],
      ["intent_queue_capacity", 9],
      ["intent_queue_max_retained", 9],
      ["intent_queue_dropped", 0],
      ["intent_bridge_calls", 3],
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
