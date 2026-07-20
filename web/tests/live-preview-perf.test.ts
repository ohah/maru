import { describe, expect, test } from "bun:test";
import { Text } from "@codemirror/state";
import { projectionFallbackReasons } from "../src/live-preview-diagnostics";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { atomicSourceHash, startAtomicSourceHashProbe } from "../src/atomic-projection";
import {
  livePreviewPerfSchemaVersion,
  validateLivePreviewPerfArtifact,
  type LivePreviewPerfArtifact,
} from "../scripts/live-preview-perf-model";
import { startDocumentCopyProbe } from "../scripts/live-preview-perf-scenario";

function artifact(): LivePreviewPerfArtifact {
  return {
    schema_version: livePreviewPerfSchemaVersion,
    scenario: "fp11f-8mib-1000-editable-projection-mermaid",
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
      atomic_requests: 4,
      atomic_results: 4,
      atomic_asset_grants: 1,
      atomic_worker_hashed_bytes_max: 256 * 1024,
      atomic_worker_hashed_bytes_batch_max: 8 * 256 * 1024,
      atomic_result_payload_bytes: 1_024,
      atomic_cap_plus_one_hashed_bytes: 0,
      atomic_main_hashed_bytes: 0,
      atomic_main_copied_bytes: 0,
      atomic_mounted_max: 8,
      atomic_iframe_create_max_per_frame: 2,
      atomic_iframe_destroy_max_per_frame: 2,
      atomic_generated_outside_retention: 0,
      mermaid_requests: 1,
      mermaid_worker_hashed_bytes: 38,
      mermaid_cap_plus_one_hashed_bytes: 0,
      mermaid_main_hashed_bytes: 0,
      mermaid_main_received_source_bytes: 38,
      mermaid_native_requests: 1,
      mermaid_native_requests_after_unrelated_edit: 1,
      mermaid_cache_entries_max: 1,
      mermaid_cache_source_bytes_max: 38,
      mermaid_cache_svg_code_units_max: 64,
      mermaid_cache_entries_after_disable: 0,
      mermaid_cache_svg_code_units_after_disable: 0,
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
      table_intent_events: 10,
      table_cm6_transactions: 8,
      table_source_transactions: 2,
      table_appended_rows: 2,
      table_zero_effect_rejections: 2,
      table_cell_cap: 256,
      table_cap_plus_one_transactions: 0,
      table_multirange_transactions: 0,
      table_context_record_checks: 200,
      table_context_cells_retained_max: 256,
      table_queue_max_retained: 1,
      table_external_actions: 0,
      table_bridge_calls: 0,
      table_iframe_create: 0,
      table_iframe_destroy: 0,
      table_copied_bytes: 0,
      table_event_record_checks_max: 18,
      table_projection_record_count: 4_096,
      table_non_table_record_count: 3_840,
      table_projection_record_checks_max: 4_096,
      table_group_build_record_checks_max: 16,
      table_group_cell_arrays_created_max: 1,
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

  test("atomic hash probe detects fingerprint work in the observed execution segment", () => {
    const probe = startAtomicSourceHashProbe();
    atomicSourceHash("measured");
    expect(probe.stop()).toBe(8);
  });

  test("requires the closed FP11f schema and exact Mermaid/atomic/interaction counters", () => {
    const current = artifact();
    expect(() => validateLivePreviewPerfArtifact(current)).not.toThrow();
    for (const name of [
      "copied_bytes",
      "iframe_create",
      "iframe_destroy",
      "retained_html_bytes",
      "generated_outside_retention",
      "atomic_cap_plus_one_hashed_bytes",
      "atomic_main_hashed_bytes",
      "atomic_main_copied_bytes",
      "atomic_generated_outside_retention",
      "mermaid_cap_plus_one_hashed_bytes",
      "mermaid_main_hashed_bytes",
      "mermaid_cache_entries_after_disable",
      "mermaid_cache_svg_code_units_after_disable",
      "intent_dual_effects",
      "table_cap_plus_one_transactions",
      "table_multirange_transactions",
      "table_external_actions",
      "table_bridge_calls",
      "table_iframe_create",
      "table_iframe_destroy",
      "table_copied_bytes",
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
      ).toThrow("projection fallback mismatch");
    }
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
      ["atomic_requests", 3],
      ["atomic_results", 3],
      ["atomic_asset_grants", 2],
      ["atomic_worker_hashed_bytes_max", 262_143],
      ["atomic_result_payload_bytes", 0],
      ["atomic_mounted_max", 9],
      ["atomic_iframe_create_max_per_frame", 3],
      ["atomic_iframe_destroy_max_per_frame", 3],
      ["mermaid_requests", 0],
      ["mermaid_worker_hashed_bytes", 0],
      ["mermaid_worker_hashed_bytes", 32_769],
      ["intent_events", 7],
      ["intent_cm6_transactions", 2],
      ["intent_external_actions", 2],
      ["intent_zero_effect_rejections", 3],
      ["intent_range_checks", 0],
      ["intent_queue_capacity", 9],
      ["intent_queue_max_retained", 9],
      ["intent_queue_dropped", 0],
      ["intent_bridge_calls", 3],
      ["table_intent_events", 7],
      ["table_cm6_transactions", 5],
      ["table_source_transactions", 1],
      ["table_appended_rows", 1],
      ["table_zero_effect_rejections", 1],
      ["table_cell_cap", 255],
      ["table_context_record_checks", 0],
      ["table_context_cells_retained_max", 255],
      ["table_queue_max_retained", 2],
      ["table_event_record_checks_max", 33],
      ["table_projection_record_count", 4_095],
      ["table_non_table_record_count", 3_839],
      ["table_projection_record_checks_max", 4_095],
      ["table_group_build_record_checks_max", 4_097],
      ["table_group_cell_arrays_created_max", 2],
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
