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

test("스크롤 위치는 65535행을 넘어도 정확하다", async () => {
  // 예전 브리지는 `(offset << 16) | len` 하나로 실어 보내며 각 필드를 0xffff 로 잘랐다.
  // 70000 행에서 길이가 4464 로 보고돼 스크롤바가 6% 만 그려졌고, 절대 행 스크롤은 아예
  // 불가능했다(`scrollback: 100000` 은 실제로 쓰는 설정이다).
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.setOptions({ scrollback: 70000 });
  for (let i = 0; i < 70050; i++) term.write("x\r\n");
  await settle();

  const len = term.frame!.scroll.length;
  expect(len).toBe(70000);
  expect(len).toBeGreaterThan(0xffff); // 옛 인코딩이었다면 여기서 4464 였다

  term.scrollToTop();
  await settle();
  expect(term.frame!.scroll.offset).toBe(len); // 맨 위 = 최대 offset
  term.dispose();
});

test("폭을 줄이면 늘어난 스크롤백 행이 즉시 반영된다", async () => {
  // 스크롤백 재-wrap 은 지연된다(`rewrap_pending`). `scrollbackLen()` 은 그걸 강제하지 않아
  // 리사이즈 직후 옛 폭 기준 행 수가 나왔다 — 40→20 열에서 27 행이 57 행이 되는데 30 을
  // 보고했고, `scrollToTop` 이 거기까지만 올라갔다(절반).
  const term = await makeTerminal({ cols: 40, rows: 4 });
  for (let i = 0; i < 30; i++) term.write("y".repeat(38) + "\r\n");
  await settle();
  const wide = term.frame!.scroll.length;

  term.resize(20, 4);
  await settle();
  // 폭이 반이면 38 자 줄이 2 행이 된다 — 행 수는 거의 두 배여야 한다.
  // (`> wide` 로는 부족하다. 재-wrap 전 값 30 도 27 보다 크기 때문이다.)
  expect(term.frame!.scroll.length).toBeGreaterThan(wide * 1.8);

  term.scrollToTop();
  await settle();
  // **같은 프레임 안에서** 비교한다. 앞서 읽어 둔 값과 대조하면 둘 다 틀렸을 때 통과한다.
  const f = term.frame!.scroll;
  expect(f.offset).toBe(f.length);
  term.dispose();
});

test("scrollToLine은 절대 행을 뷰포트 첫 줄에 둔다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  for (let i = 0; i < 120; i++) term.write(`line ${i}\r\n`);
  await settle();
  const len = term.frame!.scroll.length;

  term.scrollToLine(10);
  await settle();
  // offset 은 바닥 기준이라 방향이 반대다 — 절대 행 10 을 보려면 len-10 만큼 올라가야 한다.
  expect(term.frame!.scroll.offset).toBe(len - 10);

  term.scrollToLine(0);
  await settle();
  expect(term.frame!.scroll.offset).toBe(len);
  term.dispose();
});

test("scrollLines/scrollPages는 휠 방향(양수=아래)을 따른다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  for (let i = 0; i < 60; i++) term.write(`line ${i}\r\n`);
  await settle();

  term.scrollToTop();
  await settle();
  const top = term.frame!.scroll.offset;

  term.scrollLines(5); // 아래로 5행 → offset 감소
  await settle();
  expect(term.frame!.scroll.offset).toBe(top - 5);

  term.scrollPages(1); // 아래로 rows(4)행
  await settle();
  expect(term.frame!.scroll.offset).toBe(top - 9);
  term.dispose();
});

test("reset(RIS)은 화면과 스크롤백을 비운다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  for (let i = 0; i < 30; i++) term.write(`line ${i}\r\n`);
  term.write("\x1b[31mred");
  await settle();
  expect(term.frame!.scroll.length).toBeGreaterThan(0);

  term.reset();
  await settle();
  expect(term.frame!.scroll.length).toBe(0);
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trim()).toBe("");
  term.dispose();
});

test("clear는 스크롤백을 비우고, 프롬프트 상태에서만 ^L을 흘린다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const out: number[] = [];
  term.onData((b) => out.push(...b));

  for (let i = 0; i < 30; i++) term.write(`line ${i}\r\n`);
  await settle();
  expect(term.frame!.scroll.length).toBeGreaterThan(0);

  // 셸 통합이 없는 상태 — 커서 모델을 건드리면 안 되므로 ^L 을 보내지 않는다.
  term.clear();
  await settle();
  expect(term.frame!.scroll.length).toBe(0);
  expect(out).toEqual([]);

  // OSC 133 으로 프롬프트를 선언하면 셸이 다시 그려야 하므로 ^L 이 나간다.
  term.write("\x1b]133;A\x07$ ");
  await settle();
  term.clear();
  await settle();
  expect(out).toEqual([0x0c]);
  term.dispose();
});

test("onCursorMove는 위치가 바뀔 때만 온다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write(""); // 기준선 프레임 — 실사용에선 `open()` 의 초기 렌더가 이 역할을 한다
  await settle();
  const seen: { row: number; col: number }[] = [];
  term.onCursorMove((c) => seen.push({ row: c.row, col: c.col }));

  term.write("ab");
  await settle();
  expect(seen.at(-1)).toEqual({ row: 0, col: 2 });

  const n = seen.length;
  term.write("\x1b[?25l"); // 커서 숨김 — 위치는 그대로다
  await settle();
  expect(seen.length).toBe(n); // 모양·가시성 변화는 이동이 아니다

  term.write("\r\n");
  await settle();
  expect(seen.at(-1)).toEqual({ row: 1, col: 0 });
  term.dispose();
});

test("onScroll은 뷰포트나 스크롤백 길이가 바뀔 때 온다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("");
  await settle();
  const seen: { offset: number; length: number }[] = [];
  term.onScroll((s) => seen.push({ ...s }));

  for (let i = 0; i < 10; i++) term.write(`line ${i}\r\n`);
  await settle();
  expect(seen.length).toBeGreaterThan(0);
  expect(seen.at(-1)!.length).toBeGreaterThan(0); // 스크롤백이 자랐다

  const n = seen.length;
  term.scroll(3);
  await settle();
  expect(seen.length).toBeGreaterThan(n);
  expect(seen.at(-1)!.offset).toBe(3);
  term.dispose();
});

test("onSelectionChange는 선택과 해제를 알린다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("hello world");
  await settle();
  const seen: (object | null)[] = [];
  term.onSelectionChange((s) => seen.push(s));

  term.selectWord(0, 1);
  await settle();
  expect(seen.length).toBe(1);
  expect(seen[0]).not.toBeNull();

  term.selectClear();
  await settle();
  expect(seen.at(-1)).toBeNull(); // 해제는 null 로 온다 — 복사 버튼을 끄는 신호
  term.dispose();
});

test("첫 프레임은 상태 이벤트를 내지 않는다", async () => {
  // 초기 상태를 "변화"로 내면 구독자가 마운트 직후 무의미한 알림을 받는다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const seen: string[] = [];
  term.onCursorMove(() => seen.push("cursor"));
  term.onScroll(() => seen.push("scroll"));
  term.onSelectionChange(() => seen.push("sel"));
  term.write(""); // 프레임 하나를 강제한다
  await settle();
  expect(seen).toEqual([]);
  term.dispose();
});

test("findMatches는 스크롤백까지 훑고 절대 행을 준다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("needle here\r\n");
  for (let i = 0; i < 40; i++) term.write(`pad ${i}\r\n`);
  term.write("needle again\r\n");
  await settle();

  const { matches, total } = await term.findMatches("needle");
  expect(total).toBe(2);
  expect(matches).toHaveLength(2);
  expect(matches[0].startRow).toBe(0); // 첫 줄 — 스크롤백 최상단
  expect(matches[0].startCol).toBe(0);
  expect(matches[1].startRow).toBe(41);
  term.dispose();
});

test("findMatches는 없는 것과 빈 문자열에 빈 결과를 준다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("hello");
  await settle();
  expect((await term.findMatches("zzz")).total).toBe(0);
  expect((await term.findMatches("")).total).toBe(0);
  term.dispose();
});

test("매치가 상한을 넘으면 총 개수만 정확히 알린다", async () => {
  // 버퍼는 4096 건까지다. UI 가 "1/5000" 을 보여줄 수 있어야 하므로 총량은 잘리면 안 된다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.setOptions({ scrollback: 6000 });
  for (let i = 0; i < 5000; i++) term.write("hit\r\n");
  await settle();

  const r = await term.findMatches("hit");
  expect(r.total).toBe(5000);
  expect(r.matches).toHaveLength(4096);
  expect(r.matches.at(-1)!.startRow).toBe(4095); // 앞에서부터 채운다
  term.dispose();
});

test("findNext는 매치를 화면에 올리고 정확히 그 글자를 선택한다", async () => {
  // **좌표계가 갈린다.** 매치는 절대 행이고 선택은 뷰포트 행이다 — 변환을 빼먹으면 스크롤백
  // 깊은 매치에서 엉뚱한 줄이 선택된다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("alpha\r\n");
  for (let i = 0; i < 40; i++) term.write(`pad ${i}\r\n`);
  term.write("omega\r\n");
  await settle();

  expect(await term.findNext("alpha")).toBe(true);
  await settle();
  expect(await term.selectionText()).toBe("alpha"); // 선택된 글자가 곧 검증이다

  expect(await term.findNext("omega")).toBe(true);
  await settle();
  expect(await term.selectionText()).toBe("omega");

  expect(await term.findNext("nothing")).toBe(false);
  term.dispose();
});

test("findNext/findPrevious는 순회하고 끝에서 돈다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 6 });
  term.write("x1 hit\r\nx2 hit\r\nx3 hit\r\n");
  await settle();

  const seen: string[] = [];
  for (let i = 0; i < 4; i++) {
    await term.findNext("hit");
    await settle();
    const sel = term.frame!.selection!;
    seen.push(`${sel.startRow}:${sel.startCol}`);
  }
  expect(seen[0]).not.toBe(seen[1]);
  expect(seen[3]).toBe(seen[0]); // 3건이므로 네 번째에 처음으로 돌아온다

  await term.findPrevious("hit");
  await settle();
  const back = term.frame!.selection!;
  expect(`${back.startRow}:${back.startCol}`).toBe(seen[2]);
  term.dispose();
});

test("OSC 52 쓰기는 알리기만 하고 아무것도 하지 않는다", async () => {
  // 임의의 셸 스크립트가 사용자 클립보드를 덮어쓸 수 있으면 안 된다 — 정책은 소비자 몫이다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: string[] = [];
  term.onClipboardWrite((t) => got.push(t));

  // `btoa` 는 Latin-1 만 받는다 — OSC 52 는 UTF-8 바이트의 base64 이므로 먼저 인코딩한다.
  const b64 = (t: string) => btoa(String.fromCharCode(...new TextEncoder().encode(t)));

  term.write(`\x1b]52;c;${b64("복사할 것")}\x07`);
  await settle();
  expect(got).toEqual(["복사할 것"]); // 한글이 깨지지 않는다

  // **drain 했는지가 핵심이다.** 안 비우면 무관한 write 마다 같은 요청이 다시 올라온다
  // (덮어쓰기라 값만 보면 구별되지 않아, 되풀이 여부로 봐야 한다).
  term.write("무관한 출력");
  await settle();
  expect(got).toHaveLength(1);

  term.write(`\x1b]52;c;${b64("second")}\x07`);
  await settle();
  expect(got).toEqual(["복사할 것", "second"]);
  term.dispose();
});

test("OSC 52 읽기 요청은 target과 함께 알린다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: string[] = [];
  term.onClipboardRead((t) => got.push(t));

  term.write("\x1b]52;c;?\x07");
  await settle();
  expect(got).toEqual(["c"]);

  // 알린 뒤 비웠으므로 다음 프레임에 또 오지 않는다.
  term.write("x");
  await settle();
  expect(got).toHaveLength(1);
  term.dispose();
});

test("OSC 9 알림이 title/body로 온다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: { title: string; body: string }[] = [];
  term.onNotification((n) => got.push(n));

  // **알림이 없을 때 아무것도 오면 안 된다.** wasm i32 는 JS 에서 부호 있는 수로 오므로
  // "없음" 표식(0xffff_ffff)이 -1 로 도착한다 — 그냥 비교하면 매 write 마다 빈 알림이 나간다.
  term.write("평범한 출력");
  await settle();
  expect(got).toHaveLength(0);

  term.write("\x1b]9;빌드 끝\x07");
  await settle();
  expect(got).toHaveLength(1);
  expect(got[0].title + got[0].body).toContain("빌드 끝");

  term.write("또 평범한 출력");
  await settle();
  expect(got).toHaveLength(1); // drain 했으므로 되풀이되지 않는다
  term.dispose();
});

test("OSC 7이 cwd 변경을 알린다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: string[] = [];
  term.onCwdChange((c) => got.push(c));

  term.write("\x1b]7;file://host/Users/me/work\x07");
  await settle();
  expect(got.at(-1)).toBe("/Users/me/work");
  term.dispose();
});

test("OSC 133이 셸 진행과 종료 코드를 알린다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: string[] = [];
  let exit: number | null | undefined;
  term.onShellEvent((e) => {
    got.push(e.kind);
    if (e.kind === "command-end") exit = e.exit;
  });

  term.write("\x1b]133;A\x07$ ");
  term.write("\x1b]133;B\x07ls");
  term.write("\x1b]133;C\x07\r\nout\r\n");
  term.write("\x1b]133;D;3\x07");
  await settle();

  expect(got).toEqual(["prompt-start", "input-start", "command-start", "command-end"]);
  expect(exit).toBe(3); // 종료 코드가 실려 온다
  term.dispose();
});

test("음수 종료 코드가 '없음'과 구별된다", async () => {
  // 예전에는 `0xffff_ffff` 를 "없음" 표식으로 썼는데 그건 `@bitCast(@as(i32, -1))` 과 같은
  // 비트다 — 종료 코드 -1 이 null 로 보고됐다. 유무를 별도 칸으로 받는다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const got: (number | null)[] = [];
  term.onShellEvent((e) => {
    if (e.kind === "command-end") got.push(e.exit);
  });

  for (const code of ["0", "1", "255", "-1", "-2"]) {
    term.write(`\x1b]133;D;${code}\x07`);
    await settle();
  }
  term.write("\x1b]133;D\x07"); // 코드 없음
  await settle();

  expect(got).toEqual([0, 1, 255, -1, -2, null]);
  term.dispose();
});

test("cursorAtPrompt는 셸 통합이 없으면 보수적으로 false다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("no integration");
  await settle();
  expect(await term.cursorAtPrompt()).toBe(false); // 확인 없이 닫는 것보다 낫다

  term.write("\x1b]133;A\x07$ ");
  await settle();
  expect(await term.cursorAtPrompt()).toBe(true);
  term.dispose();
});

test("serialize는 화면을 평문으로 뜬다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 3 });
  term.write("\x1b[1;32mhello\x1b[0m\r\nworld");
  await settle();

  const text = await term.serialize();
  const lines = text.split("\n");
  expect(lines[0].trimEnd()).toBe("hello"); // SGR 은 버린다 — 렌더러가 아니다
  expect(lines[1].trimEnd()).toBe("world");
  expect(text).not.toContain("\x1b");
  term.dispose();
});

test("hasSelection/getSelectionPosition은 동기로 답한다", async () => {
  // 복사 버튼의 disabled 를 이벤트 핸들러 안에서 바로 정해야 한다 — Promise 면 못 쓴다.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("hello world");
  await settle();
  expect(term.hasSelection()).toBe(false);
  expect(term.getSelectionPosition()).toBeNull();

  term.selectWord(0, 1);
  await settle();
  expect(term.hasSelection()).toBe(true);
  const pos = term.getSelectionPosition()!;
  expect(pos.startRow).toBe(0);
  expect(pos.startCol).toBe(0);

  term.selectClear();
  await settle();
  expect(term.hasSelection()).toBe(false);
  term.dispose();
});

test("select/selectLines가 프로그래밍 선택을 만든다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("abcdefghij\r\nklmnopqrst\r\n");
  await settle();

  term.select(0, 2, 3); // 0행 2열부터 3칸 = "cde"
  await settle();
  expect(await term.selectionText()).toBe("cde");

  term.selectLines(0, 1);
  await settle();
  expect(await term.selectionText()).toBe("abcdefghij\nklmnopqrst");

  term.select(0, 0, 0); // 길이 0 은 무동작
  await settle();
  expect(await term.selectionText()).toBe("abcdefghij\nklmnopqrst");
  term.dispose();
});

test("범위 밖 선택은 무동작이다", async () => {
  // **음수를 그대로 흘리면 안 된다.** wasm 에서 u32 로 캐스팅돼 거대한 수가 되고, 코어의
  // clamp 를 거쳐 엉뚱한 칸이 잡힌다 — `select(0, -3, 2)` 가 마지막 열을 선택했다.
  const term = await makeTerminal({ cols: 10, rows: 4 });
  term.write("abcdefghij\r\nklmnopqrst\r\n");
  await settle();

  term.select(0, 2, 3);
  await settle();
  expect(await term.selectionText()).toBe("cde");

  term.select(0, -3, 2); // 음수 — 무동작이라 앞 선택이 그대로다
  await settle();
  expect(await term.selectionText()).toBe("cde");

  term.select(99, 0, 2); // 행 초과
  await settle();
  expect(await term.selectionText()).toBe("cde");

  term.selectClear();
  await settle();
  term.selectLines(99, 100); // 격자와 겹치는 구간이 없다
  await settle();
  expect(await term.selectionText()).toBeNull();

  term.selectLines(-5, 1); // 겹치는 구간은 clamp 해서 선택한다
  await settle();
  expect(await term.selectionText()).toBe("abcdefghij\nklmnopqrst");

  // 행 끝을 넘는 길이는 행 안으로 clamp 한다.
  term.select(0, 8, 5);
  await settle();
  expect(await term.selectionText()).toBe("ij");
  term.dispose();
});

test("dispose 후 동기 조회는 살아 있는 척하지 않는다", async () => {
  const term = await makeTerminal({ cols: 10, rows: 4 });
  term.write("text");
  await settle();
  term.selectAll();
  await settle();
  expect(term.hasSelection()).toBe(true);

  term.dispose();
  expect(term.hasSelection()).toBe(false);
  expect(term.getSelectionPosition()).toBeNull();
});

test("writeln은 CRLF를 붙인다", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.writeln("first");
  term.writeln("second");
  await settle();
  const lines = (await term.serialize()).split("\n");
  expect(lines[0].trimEnd()).toBe("first");
  expect(lines[1].trimEnd()).toBe("second"); // \r 이 없으면 이어져 붙는다
  term.dispose();
});

test("alt screen에서 clear는 무동작이다", async () => {
  // 대체 화면은 앱의 것이다 — vim 안에서 ⌘K 가 화면을 지우면 앱의 그리기 모델과 어긋난다.
  // 계약 §7 의 세 번째 조항.
  const term = await makeTerminal({ cols: 20, rows: 4 });
  const out: number[] = [];
  term.onData((b) => out.push(...b));

  term.write("\x1b[?1049h"); // 대체 화면 진입
  term.write("alt content");
  await settle();

  term.clear();
  await settle();
  const snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0)).toBe("alt content");
  expect(out).toEqual([]); // ^L 도 안 나간다
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

test("IME 조합은 화면 버퍼를 건드리지 않는다", async () => {
  // **앱이 화면을 소유한다.** zsh 는 프롬프트와 입력줄을 자기가 관리하므로, 우리가 ICH/DCH 로
  // 끼어들면 그 다음 앱이 그릴 때 엉뚱한 자리를 밟는다 — 실제 PTY 에서 `echo ` 뒤에 조합을
  // 시작하자 "ec" 가 지워졌다. 조합은 렌더러가 커서 자리에 그리고 뒤 셀을 밀어 그린다.
  const term = await makeTerminal();
  term.write("abc\x1b[D"); // 커서를 'c' 앞으로
  await settle();
  const before = rowText((await term.snapshot()).cells, (await term.snapshot()).size.cols, 0);
  term.setPreedit("한");
  await settle();
  expect(rowText((await term.snapshot()).cells, (await term.snapshot()).size.cols, 0)).toBe(before);
  term.setPreedit("");
  await settle();
  expect(rowText((await term.snapshot()).cells, (await term.snapshot()).size.cols, 0)).toBe(before);
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

test("앱이 마우스를 켜면 모드 비트가 올라온다", async () => {
  // DOM 층은 이 비트로 '선택'과 '앱에 리포트'를 가른다. 비트가 안 오면 vim `set mouse=a`
  // 에서 클릭이 커서를 못 옮기고 브라우저 선택만 칠해진다.
  const term = await makeTerminal();
  expect(term.modes >> 8).toBe(0);
  term.write("\x1b[?1000h"); // DECSET 1000 — normal tracking
  await settle();
  expect(term.modes >> 8).toBeGreaterThan(0);
  term.write("\x1b[?1000l");
  await settle();
  expect(term.modes >> 8).toBe(0);
  term.dispose();
});

test("마우스 리포트가 호스트로 나간다", async () => {
  const term = await makeTerminal();
  term.write("\x1b[?1000h\x1b[?1006h"); // tracking + SGR 인코딩
  await settle();
  const out: string[] = [];
  term.onData((b) => out.push(new TextDecoder().decode(b)));
  term.mouse({ button: 0, col: 5, row: 3, pressed: true, motion: false, mods: 0 });
  await settle();
  // SGR: CSI < btn ; col ; row M — 좌표는 1-기반이다.
  expect(out.join("")).toBe("\x1b[<0;6;4M");
  term.dispose();
});

test("포커스 리포트는 그 모드일 때만 나간다", async () => {
  const term = await makeTerminal();
  const out: string[] = [];
  term.onData((b) => out.push(new TextDecoder().decode(b)));
  term.focus(true); // 모드가 꺼져 있으면 아무것도 안 나간다
  await settle();
  expect(out.join("")).toBe("");
  term.write("\x1b[?1004h");
  await settle();
  term.focus(true);
  term.focus(false);
  await settle();
  expect(out.join("")).toBe("\x1b[I\x1b[O");
  term.dispose();
});

test("큰 격자도 스냅샷이 잘리지 않는다", async () => {
  // 셀 버퍼가 작으면 코어는 멀쩡히 그리는데 스냅샷만 잘려 아래쪽 행이 영영 빈다 —
  // 오류도 경고도 없다. 4K 전체 화면(≈457×127)보다 큰 격자로 확인한다.
  const term = await makeTerminal({ cols: 400, rows: 120 });
  const snap = await term.snapshot();
  expect(snap.cells.length).toBe(400 * 120);
  term.dispose();
});

test("코어가 거절한 리사이즈는 격자를 바꾸지 않는다", async () => {
  // 실패했는데 size 를 바꾸면 프레임이 새 크기를 알리면서 셀은 옛 격자 것을 실어,
  // 렌더러가 새 stride 로 인덱싱해 화면이 어긋난다.
  const term = await makeTerminal({ cols: 40, rows: 10 });
  term.resize(100_000, 100_000); // 코어가 거절할 크기
  expect(term.size).toEqual({ cols: 40, rows: 10 });
  term.dispose();
});

test("긴 텍스트도 폭을 정확히 잰다", async () => {
  // 측정 probe 가 좁으면 wrap 이 스크롤로 흡수돼 실제보다 작은 값이 조용히 나온다.
  // 데모의 줄 편집기가 그 값으로 CUB 를 보내므로, 틀리면 커서가 프롬프트 한가운데로 떨어진다.
  const term = await makeTerminal();
  expect(await term.measureCells("a".repeat(250))).toBe(250);
  expect(await term.measureCells("a".repeat(600))).toBe(600);
  expect(await term.measureCells("가".repeat(300))).toBe(600); // 한글은 2셀
  term.dispose();
});

test("기본 팔레트가 src/color.zig 의 ansi16 과 같다", async () => {
  // 같은 코어가 낸 SGR 색이 네이티브와 웹에서 다르면 안 된다. 값은 표준 xterm ansi16 이다.
  const { buildPalette } = await import("../core/src/render/palette");
  const p = buildPalette();
  expect(p[0]).toBe("#000000");
  expect(p[1]).toBe("#800000"); // VS Code 테이블이면 #cd3131 이 된다
  expect(p[7]).toBe("#c0c0c0");
  expect(p[9]).toBe("#ff0000");
  expect(p[15]).toBe("#ffffff");
  // 216 큐브와 그레이 램프는 색 계산식이 코어와 같아야 한다.
  expect(p[16]).toBe("#000000");
  expect(p[231]).toBe("#ffffff");
  expect(p[232]).toBe("#080808");
});

test("setOptions 로 격자를 바꾸면 실제로 리사이즈된다", async () => {
  // 경고만 하고 버리면 안 된다 — 할 수 있는 것은 적용해야 한다.
  const term = await makeTerminal({ cols: 40, rows: 10 });
  term.setOptions({ cols: 60, rows: 20 });
  expect(term.size).toEqual({ cols: 60, rows: 20 });
  term.dispose();
});

/* ── 실제 TUI 가 쓰는 시퀀스 ────────────────────────────────────────────────
   vim·htop·tmux 를 PTY 로 띄워 확인한 것들을 **결정적 재현**으로 옮긴다. 앱 자체를 CI 에서
   돌리면 셸·버전·프로세스 목록에 따라 화면이 달라져 우리 코드 문제와 환경 문제가 구분되지
   않는다. 앱은 "이 시퀀스를 실제로 쓴다"를 확인하는 탐색 도구이고, 회귀는 여기서 지킨다. */

test("대체 화면 — 들어갔다 나오면 원래 화면이 돌아온다 (vim)", async () => {
  const term = await makeTerminal({ cols: 20, rows: 4 });
  term.write("MAIN_SCREEN");
  await settle();
  term.write("\x1b[?1049h"); // 대체 화면 진입
  term.write("\x1b[2J\x1b[HALT_SCREEN");
  await settle();
  let snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("ALT_SCREEN");
  term.write("\x1b[?1049l"); // 복원
  await settle();
  snap = await term.snapshot();
  expect(rowText(snap.cells, snap.size.cols, 0).trimEnd()).toBe("MAIN_SCREEN");
  term.dispose();
});

test("마우스 추적 단계가 모드 비트에 그대로 실린다 (htop·tmux)", async () => {
  const term = await makeTerminal();
  const track = () => term.modes >> 8;
  for (const [seq, expected] of [
    ["\x1b[?1000h", 2], // normal — htop 이 켜는 것
    ["\x1b[?1002h", 3], // button-event — 드래그 중 이동까지
    ["\x1b[?1003h", 4], // any-event — 항상 이동
  ] as const) {
    term.write(seq);
    await settle();
    expect({ seq, track: track() }).toEqual({ seq, track: expected });
  }
  term.write("\x1b[?1003l\x1b[?1002l\x1b[?1000l");
  await settle();
  expect(track()).toBe(0);
  term.dispose();
});

test("스크롤 영역 안에서만 스크롤된다 (tmux·vim 상태줄)", async () => {
  // DECSTBM 으로 하단 한 줄을 고정하면 그 줄은 스크롤에 밀리지 않는다 — 상태줄의 원리다.
  const term = await makeTerminal({ cols: 10, rows: 5 });
  term.write("\x1b[5;5H"); // 마지막 줄로
  term.write("STATUS");
  term.write("\x1b[1;4r"); // 1~4행만 스크롤 영역
  term.write("\x1b[1;1H");
  for (let i = 1; i <= 6; i++) term.write(`L${i}\r\n`);
  await settle();
  const snap = await term.snapshot();
  const row = (r: number) => rowText(snap.cells, snap.size.cols, r).trim();
  // **상태줄은 스크롤에 밀리지 않는다** — 이게 요점이다.
  expect(row(4)).toBe("STATUS");
  // 스크롤 영역(1~4행)에는 최근 줄만 남는다. 마지막 `\r\n` 이 한 번 더 밀어 4행은 비어 있다.
  expect([row(0), row(1), row(2), row(3)]).toEqual(["L4", "L5", "L6", ""]);
  term.dispose();
});

test("DECSCUSR 로 커서 모양이 바뀐다 (vim 삽입 모드)", async () => {
  const term = await makeTerminal();
  const shapeOf = async () => (await term.snapshot()).cursor?.shape;
  term.write("\x1b[5 q"); // 깜빡이는 bar — vim 삽입 모드
  await settle();
  expect(await shapeOf()).toBe("bar");
  term.write("\x1b[1 q"); // 깜빡이는 block — 노멀 모드
  await settle();
  expect(await shapeOf()).toBe("block");
  term.write("\x1b[3 q"); // underline
  await settle();
  expect(await shapeOf()).toBe("underline");
  term.dispose();
});

test("휠은 버튼 64/65 로 나간다 (less·tmux copy-mode)", async () => {
  // less --mouse 와 tmux(mouse on)가 이걸로 스크롤한다. 실제 PTY 로 확인했고, 여기서는
  // 인코딩만 결정적으로 지킨다.
  const term = await makeTerminal();
  term.write("\x1b[?1000h\x1b[?1006h");
  await settle();
  const out: string[] = [];
  term.onData((b) => out.push(new TextDecoder().decode(b)));
  term.mouse({ button: 64, col: 2, row: 1, pressed: true, motion: false, mods: 0 }); // 위로
  term.mouse({ button: 65, col: 2, row: 1, pressed: true, motion: false, mods: 0 }); // 아래로
  await settle();
  expect(out.join("")).toBe("\x1b[<64;3;2M\x1b[<65;3;2M");
  term.dispose();
});
