import { expect, test } from "bun:test";
import { loadWasm, makeTerminal, rowText, settle } from "./support";

test("VT 출력이 셀 격자에 들어간다", async () => {
  const term = await makeTerminal();
  term.write("\x1b[1;32mhello\x1b[0m");
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0)).toBe("hello");
  term.dispose();
});

test("동아시아 문자는 2셀을 먹는다", async () => {
  const term = await makeTerminal();
  expect(await term.measureCells("가")).toBe(2);
  expect(await term.measureCells("漢")).toBe(2);
  expect(await term.measureCells("a")).toBe(1);
  expect(await term.measureCells("가나다")).toBe(6);
  term.dispose();
});

test("grapheme cluster는 한 칸으로 묶인다", async () => {
  const term = await makeTerminal();
  expect(await term.measureCells("é")).toBe(1); // e + combining acute
  expect(await term.measureCells("a̐")).toBe(1);
  term.dispose();
});

test("키 입력이 호스트 바이트로 인코딩돼 onData로 나간다", async () => {
  const term = await makeTerminal();
  const seen: number[][] = [];
  term.onData((b) => seen.push([...b]));

  term.key({ key: "char", codepoint: 99, ctrl: true }); // Ctrl+C
  term.key({ key: "enter" });
  term.key({ key: "up" });

  expect(seen[0]).toEqual([0x03]);
  expect(seen[1]).toEqual([0x0d]);
  expect(seen[2]).toEqual([0x1b, 0x5b, 0x41]); // CSI A
  term.dispose();
});

test("DECCKM을 켜면 같은 화살표가 SS3로 바뀐다", async () => {
  const term = await makeTerminal();
  const seen: number[][] = [];
  term.onData((b) => seen.push([...b]));

  term.write("\x1b[?1h"); // application cursor keys
  term.key({ key: "up" });

  const last = seen.at(-1);
  expect(last).toEqual([0x1b, 0x4f, 0x41]); // SS3 A
  term.dispose();
});

test("수식자 붙은 화살표는 xterm legacy 형식이다", async () => {
  const term = await makeTerminal();
  const seen: number[][] = [];
  term.onData((b) => seen.push([...b]));
  term.key({ key: "left", alt: true });
  expect(seen.at(-1)).toEqual([...new TextEncoder().encode("\x1b[1;3D")]);
  term.dispose();
});

test("질의 응답이 onData로 흘러나온다 — 안 나가면 TUI가 멈춘다", async () => {
  const term = await makeTerminal();
  const seen: string[] = [];
  term.onData((b) => seen.push(new TextDecoder().decode(b)));

  term.write("\x1b[c"); // Primary DA
  term.write("\x1b[6n"); // CPR

  expect(seen).toContain("\x1b[?6c");
  // CPR 응답: ESC [ row ; col R. 정규식에 제어문자를 넣지 않으려 문자열로 판정한다.
  expect(seen.some((s) => s.startsWith("\x1b[") && s.endsWith("R"))).toBe(true);
  term.dispose();
});

test("창 제목과 벨이 이벤트로 나온다", async () => {
  const term = await makeTerminal();
  const titles: string[] = [];
  const bells: number[] = [];
  term.onTitle((t) => titles.push(t));
  term.onBell(() => bells.push(1));

  term.write("\x1b]0;My Terminal\x07");
  term.write("\x07");

  expect(titles.at(-1)).toBe("My Terminal");
  expect(bells.length).toBeGreaterThan(0);
  term.dispose();
});

test("선택 span과 텍스트 추출", async () => {
  const term = await makeTerminal();
  term.write("hello world\r\nsecond line\r\n");
  // span 의 끝은 **inclusive**다 — extend(0,4)가 "hello"(0~4)를 잡는다.
  term.selectStart(0, 0);
  term.selectExtend(0, 4);
  expect(await term.selectionText()).toBe("hello");

  term.selectWord(0, 7); // "world"
  expect(await term.selectionText()).toBe("world");

  term.selectClear();
  expect(await term.selectionText()).toBeNull();
  term.dispose();
});

test("블록 선택은 start 직후에 켜야 유효하다", async () => {
  const term = await makeTerminal();
  term.write("abcdef\r\nghijkl\r\nmnopqr\r\n");
  term.selectStart(0, 1, true);
  term.selectExtend(2, 3); // inclusive → 열 1~3
  const text = await term.selectionText();
  expect(text).toBe("bcd\nhij\nnop");
  term.dispose();
});

test("스크롤백을 넘기면 뷰포트가 과거를 가리킨다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  for (let i = 0; i < 12; i++) term.write(`line ${i}\r\n`);
  await settle();
  const before = term.frame?.scroll.offset ?? -1;
  term.scroll(3);
  await settle();
  expect(term.frame!.scroll.offset).toBeGreaterThan(before);
  term.scrollToBottom();
  await settle();
  expect(term.frame!.scroll.offset).toBe(0);
  term.dispose();
});

test("bracketed paste 모드가 붙으면 감싼다", async () => {
  const term = await makeTerminal();
  const seen: string[] = [];
  term.onData((b) => seen.push(new TextDecoder().decode(b)));
  term.write("\x1b[?2004h");
  term.paste("hi");
  expect(seen.at(-1)).toBe("\x1b[200~hi\x1b[201~");
  term.dispose();
});

test("OSC 8 하이퍼링크를 좌표로 조회한다", async () => {
  const term = await makeTerminal();
  term.write("\x1b]8;;https://ziglang.org\x1b\\Zig\x1b]8;;\x1b\\ ok");
  expect(await term.linkAt(0, 0)).toBe("https://ziglang.org");
  expect(await term.linkAt(0, 5)).toBeNull(); // 링크 밖
  term.dispose();
});

test("ambiguous wide를 켜면 레이아웃이 갈린다", async () => {
  const term = await makeTerminal();
  expect(await term.measureCells("①②③")).toBe(3);
  term.setOptions({ ambiguousWide: true });
  expect(await term.measureCells("①②③")).toBe(6);
  term.dispose();
});

test("resize가 그리드와 이벤트에 반영된다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const seen: { cols: number; rows: number }[] = [];
  term.onResize((s) => seen.push(s));
  term.resize(60, 10);
  expect(seen.at(-1)).toEqual({ cols: 60, rows: 10 });
  const snap = await term.snapshot();
  expect(snap.cells.length).toBe(600);
  term.dispose();
});

/* ── 회귀: 브라우저에서 드러난 결함들 ───────────────────────────────────── */

test("타이핑하면 선택이 풀린다", async () => {
  const term = await makeTerminal();
  term.write("hello world");
  await settle();
  term.selectStart(0, 0, false);
  term.selectExtend(0, 4);
  expect(await term.selectionText()).not.toBeNull();
  term.key({ key: "char", codepoint: 120 }); // 'x'
  expect(await term.selectionText()).toBeNull();
  term.dispose();
});

test("합성 글리프는 박스만이 아니라 전 계열을 덮는다", async () => {
  // 렌더러가 이 판정을 JS 로 복제하지 않고 코어에 위임하는 것이 계약이다. wasm 브리지가
  // `box_glyph` 만 부르던 시절엔 블록·파워라인·브라유가 통째로 폰트로 흘렀다.
  const w = await loadWasm();
  for (const cp of [0x2500 /* ─ */, 0x2588 /* █ */, 0xe0b0 /* 파워라인 */, 0x2801 /* ⠁ */, 0x1fb3c])
    expect({ cp, covers: w.glyph_covers(cp) !== 0 }).toEqual({ cp, covers: true });
  for (const cp of [0x41 /* A */, 0xac00 /* 가 */])
    expect({ cp, covers: w.glyph_covers(cp) !== 0 }).toEqual({ cp, covers: false });
  // 실제로 픽셀도 나와야 한다 — covers 만 참이고 빈 커버리지면 화면이 빈다.
  expect(w.glyph_box(0xe0b0, 9, 22)).toBeGreaterThan(0);
});

test("IME 조합 텍스트는 화면에 실제로 들어가고 뒤 텍스트를 민다", async () => {
  // 오버레이로 덮어 그리기만 하면 커서 뒤 글자가 가려질 뿐 밀리지 않는다 — 조합 중에 뒤
  // 텍스트가 사라진 것처럼 보인다. 코어에 넣어야 밀린다.
  const term = await makeTerminal();
  term.write("abc\x1b[D"); // 커서를 'c' 앞으로
  await settle();
  term.setPreedit("한");
  await settle();
  let snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("ab한c");

  // 조합을 물리면 원래 줄이 그대로 돌아온다 — 삽입한 만큼만 지운다.
  term.setPreedit("");
  await settle();
  snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("abc");
  term.dispose();
});

test("조합을 물리면 화면이 원래대로 — 라이브러리 삽입 경로", async () => {
  // `onPreedit` 를 구독하지 않으면 라이브러리가 ICH/DCH 로 직접 넣는다. 되돌리기가 정확하지
  // 않으면 조합을 지워도 마지막 글자가 화면에 남는다.
  const term = await makeTerminal();
  term.write("ab");
  await settle();
  for (const step of ["ㅎ", "하", "한", "하", "ㅎ", ""]) {
    term.setPreedit(step);
    await settle();
  }
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("ab");
  term.dispose();
});

test("조합 폭이 바뀌어도 되돌리기가 정확하다", async () => {
  // 한글(2셀) ↔ 라틴(1셀) 처럼 폭이 달라지는 전환에서 지우는 칸 수가 어긋나기 쉽다.
  const term = await makeTerminal();
  term.write("xy");
  await settle();
  for (const step of ["a", "가", "ab", "가나", ""]) {
    term.setPreedit(step);
    await settle();
  }
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("xy");
  term.dispose();
});

test("거대한 붙여넣기가 인접 버퍼를 밟지 않는다", async () => {
  // `Uint8Array(memory, ptr, len).set()` 은 선형 메모리가 넉넉하면 예외 없이 옆 버퍼를
  // 덮어쓴다(wasm 은 ReleaseSmall 이라 트랩도 없다). 입력 버퍼보다 큰 붙여넣기를 넣고,
  // 화면이 멀쩡한지 — 즉 스냅샷 버퍼가 밟히지 않았는지 본다.
  const term = await makeTerminal();
  term.write("sentinel");
  await settle();
  const before = rowText((await term.snapshot()).cells, (await term.snapshot()).size.cols, 0);
  term.paste("x".repeat(3_000_000)); // 3 MB — 어떤 입력 버퍼보다 크다
  await settle();
  const snap = await term.snapshot();
  // 붙여넣기는 호스트로 나갈 뿐 화면을 건드리지 않는다. 첫 줄이 그대로여야 한다.
  expect(rowText(snap.cells, snap.size.cols, 0)).toBe(before);
  expect(snap.size.cols).toBeGreaterThan(0); // 스냅샷 자체가 성립한다
  term.dispose();
});

test("입력 버퍼보다 큰 write 도 온전히 들어간다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  // write 는 순수 바이트 스트림이라 나눠 넣어도 결과가 같아야 한다.
  term.write("A".repeat(2_000_000) + "\r\nEND");
  await settle();
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, snap.size.rows - 1).trimEnd()).toBe("END");
  term.dispose();
});
