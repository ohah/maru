// Alacritty 외부 오라클용 dumper.
//
// stdin으로 raw 터미널 바이트를 받아 alacritty_terminal로 렌더한 뒤, cols×rows
// 그리드를 평문으로 stdout에 출력한다(행은 '\n'으로 연결, 빈 셀은 space).
// 이는 maru.terminal의 dumpUtf8 및 다른 오라클(libvterm/Ghostty)과 같은 규약이라
// 동일 golden으로 비교할 수 있다.
//
// 사용: alacritty-dumper <cols> <rows> <input_file>
//
// alacritty_terminal은 Rust 크레이트라 in-process로 링크하기 어렵다. 그래서 작은
// 독립 바이너리로 만들고 Maru의 Zig 테스트가 subprocess로 호출한다. 입력은 stdin이
// 아니라 파일 경로로 받는다 — 그래야 Zig 쪽에서 std.process.Child.run으로 stdout만
// 캡처하면 되고, 0.16의 stdin 파이프 I/O를 다룰 필요가 없다.

use std::io::{self, Write};

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::Config;
use alacritty_terminal::vte::ansi::Processor;
use alacritty_terminal::Term;

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let cols: usize = args
        .next()
        .expect("usage: alacritty-dumper <cols> <rows>")
        .parse()
        .expect("cols must be an integer");
    let rows: usize = args
        .next()
        .expect("usage: alacritty-dumper <cols> <rows> <input_file>")
        .parse()
        .expect("rows must be an integer");
    let input_path = args
        .next()
        .expect("usage: alacritty-dumper <cols> <rows> <input_file>");

    let input = std::fs::read(&input_path).expect("read input file");

    let size = Size { cols, rows };
    let mut term = Term::new(Config::default(), &size, VoidListener);
    let mut parser: Processor = Processor::new();
    parser.advance(&mut term, &input);

    let grid = term.grid();
    let mut out = String::new();
    for line in 0..rows {
        if line != 0 {
            out.push('\n');
        }
        for col in 0..cols {
            let cell = &grid[Line(line as i32)][Column(col)];
            out.push(cell.c);
        }
    }

    io::stdout()
        .write_all(out.as_bytes())
        .expect("write stdout");
}
