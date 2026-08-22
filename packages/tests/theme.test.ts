import { expect, test } from "bun:test";
import { parseGhosttyTheme } from "../core/src/theme/parse";
import { themes } from "../core/src/theme/presets";
import { makeTerminal } from "./support";

const DRACULA = `
palette = 0=#21222c
palette = 1=#ff5555
palette = 15=#f8f8f2
background = #282a36
foreground = #f8f8f2
cursor-color = #ff79c6
cursor-text = #282a36
selection-background = #44475a
selection-foreground = #f8f8f2
`;

test("Ghostty 테마 파일을 읽는다", () => {
  const t = parseGhosttyTheme(DRACULA)!;
  expect(t.background).toBe(0x282a36);
  expect(t.foreground).toBe(0xf8f8f2);
  expect(t.cursor).toBe(0xff79c6);
  expect(t.selectionBackground).toBe(0x44475a);
  expect(t.palette![0]).toBe(0x21222c);
  expect(t.palette![15]).toBe(0xf8f8f2);
  expect(t.palette![7]).toBeUndefined(); // 파일에 없는 자리는 비운다
});

test("전경·배경이 없으면 테마가 아니다", () => {
  expect(parseGhosttyTheme("palette = 0=#000000")).toBeNull();
});

test("인식 못 하는 키는 건너뛴다", () => {
  const t = parseGhosttyTheme(
    "background = #000000\nforeground = #ffffff\nbold-is-bright = true\n",
  )!;
  expect(t.background).toBe(0);
  expect(t.foreground).toBe(0xffffff);
});

test("테마가 코어에 반영된다 — OSC 4 질의가 그 값을 회신한다", async () => {
  const term = await makeTerminal();
  const seen: string[] = [];
  term.onData((b) => seen.push(new TextDecoder().decode(b)));
  term.setTheme(themes.dracula);
  term.write("\x1b]4;1;?\x07"); // 팔레트 1번을 물어본다
  // 코어는 16비트 채널로 회신한다: #ff5555 → rgb:ffff/5555/5555
  const reply = seen.find((s) => s.includes("]4;1;"));
  expect(reply).toBeDefined();
  expect(reply).toContain("rgb:ffff/5555/5555");
  term.dispose();
});
