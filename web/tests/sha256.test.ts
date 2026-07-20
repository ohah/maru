import { expect, test } from "bun:test";
import { sha256Hex } from "../src/sha256";

test("worker SHA-256 matches standard UTF-8 vectors", () => {
  expect(sha256Hex("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  expect(sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  expect(sha256Hex("```mermaid\ngraph TD\n```")).toBe(
    "2151a7a6ec2eaff56c93602c3b07382d7bd484e8e572852da1ffe6b874656bd8",
  );
});
