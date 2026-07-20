import { projectionFallbackReasons } from "../src/live-preview-diagnostics";

export const livePreviewPerfSchemaVersion = 1;

export type LivePreviewPerfCounters = Readonly<{
  visited_code_units: number;
  visited_syntax_nodes: number;
  emitted_decorations: number;
  diffed_decorations: number;
  copied_bytes: number;
  source_transactions: number;
  projection_transactions: number;
  dom_mutations: number;
  iframe_create: number;
  iframe_destroy: number;
  retained_html_bytes: number;
  generated_outside_retention: number;
  projection_fallback_counts: Readonly<Record<string, number>>;
}>;

export type LivePreviewPerfArtifact = Readonly<{
  schema_version: typeof livePreviewPerfSchemaVersion;
  scenario: "fp11a-8mib-1000-input-baseline";
  counters: LivePreviewPerfCounters;
}>;

const counterNames = [
  "visited_code_units",
  "visited_syntax_nodes",
  "emitted_decorations",
  "diffed_decorations",
  "copied_bytes",
  "source_transactions",
  "projection_transactions",
  "dom_mutations",
  "iframe_create",
  "iframe_destroy",
  "retained_html_bytes",
  "generated_outside_retention",
  "projection_fallback_counts",
] as const;

export function validateLivePreviewPerfArtifact(artifact: LivePreviewPerfArtifact): void {
  if (artifact.schema_version !== livePreviewPerfSchemaVersion)
    throw new Error("live preview perf schema mismatch");
  if (artifact.scenario !== "fp11a-8mib-1000-input-baseline")
    throw new Error("live preview perf scenario mismatch");
  const actualNames = Object.keys(artifact.counters).sort();
  const expectedNames = [...counterNames].sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames))
    throw new Error("live preview perf counter set mismatch");
  for (const name of counterNames) {
    if (name === "projection_fallback_counts") continue;
    const value = artifact.counters[name];
    if (!Number.isSafeInteger(value) || value < 0)
      throw new Error(`invalid live preview perf counter: ${name}`);
  }
  const fallbackNames = Object.keys(artifact.counters.projection_fallback_counts).sort();
  if (JSON.stringify(fallbackNames) !== JSON.stringify([...projectionFallbackReasons].sort()))
    throw new Error("live preview fallback counter set mismatch");
  for (const value of Object.values(artifact.counters.projection_fallback_counts)) {
    if (!Number.isSafeInteger(value) || value < 0)
      throw new Error("invalid live preview fallback counter");
  }
  if (artifact.counters.copied_bytes !== 0)
    throw new Error("live preview input copied source bytes");
  if (artifact.counters.source_transactions !== 1_000)
    throw new Error("live preview source transaction fixture incomplete");
  if (
    artifact.counters.visited_code_units !== 0 ||
    artifact.counters.visited_syntax_nodes !== 0 ||
    artifact.counters.emitted_decorations !== 0 ||
    artifact.counters.diffed_decorations !== 0 ||
    artifact.counters.projection_transactions !== 0 ||
    artifact.counters.dom_mutations !== 0 ||
    artifact.counters.iframe_create !== 0 ||
    artifact.counters.iframe_destroy !== 0 ||
    artifact.counters.retained_html_bytes !== 0 ||
    artifact.counters.generated_outside_retention !== 0
  ) {
    throw new Error("FP11a baseline changed product projection behavior");
  }
  for (const count of Object.values(artifact.counters.projection_fallback_counts)) {
    if (count !== 0) throw new Error("FP11a baseline produced a projection fallback");
  }
}
