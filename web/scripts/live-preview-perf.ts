import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  livePreviewPerfSchemaVersion,
  validateLivePreviewPerfArtifact,
  type LivePreviewPerfArtifact,
} from "./live-preview-perf-model";
import { runLivePreviewBaselineScenario } from "./live-preview-perf-scenario";

async function runProjectionScenario(): Promise<LivePreviewPerfArtifact> {
  return {
    schema_version: livePreviewPerfSchemaVersion,
    scenario: "fp11e-8mib-1000-editable-projection-atomic-widgets",
    counters: await runLivePreviewBaselineScenario(),
  };
}

const first = await runProjectionScenario();
const second = await runProjectionScenario();
validateLivePreviewPerfArtifact(first);
validateLivePreviewPerfArtifact(second);
if (JSON.stringify(first) !== JSON.stringify(second))
  throw new Error("live preview perf fixture is not deterministic");

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const artifactPath = join(webRoot, "..", "tests", "artifacts", "perf", "live-preview.json");
await mkdir(dirname(artifactPath), { recursive: true });
await writeFile(artifactPath, `${JSON.stringify(first, null, 2)}\n`);
console.log(JSON.stringify({ artifact: artifactPath, ...first }));
