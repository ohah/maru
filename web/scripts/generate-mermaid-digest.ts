import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const [, , inputPath, outputPath] = process.argv;
if (!inputPath || !outputPath) {
  throw new Error("usage: generate-mermaid-digest.ts <input> <output>");
}

const digest = createHash("sha256")
  .update(await readFile(inputPath))
  .digest();
const bytes = [...digest].map((byte) => `0x${byte.toString(16).padStart(2, "0")}`).join(", ");
await writeFile(
  outputPath,
  `// Generated from web/dist/mermaid-helper.js. Do not edit.\n` +
    `enum MermaidHelperDigest {\n` +
    `    static let sha256: [UInt8] = [${bytes}]\n` +
    `}\n`,
);
