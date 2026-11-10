"""현재 제품 예약을 유지하는 첫 표시·drawable·관측자 계측. 외부 사본만 변환한다."""
from pathlib import Path

HERE = Path(__file__).resolve().parent


def driver(source, once):
    source = (HERE / 'input_display.swift.inc').read_text() + source
    source = once(source, '        let now=ProcessInfo.processInfo.systemUptime\n        if InputStream.phase<2', '        let inputDisplayObserver=InputDisplay.begin(0)\n        defer { InputDisplay.end(inputDisplayObserver) }\n        let now=ProcessInfo.processInfo.systemUptime\n        if InputStream.phase<2')
    return once(source, '        record["initial_tail_sha256"]=', '''        var inputDrawHeader=[UInt64](repeating:0,count:4),inputDrawRows=[UInt64](repeating:0,count:2048*9)
        inputDisplayDraws(&inputDrawHeader,&inputDrawRows)
        record["input_display_mode"]=InputDisplay.timed ? "timed" : "untimed"
        record["input_interval_started"]=InputDisplay.started
        record["input_interval_completed"]=InputDisplay.completed
        record["input_interval_errors"]=InputDisplay.errors
        record["input_intervals"]=InputDisplay.events
        record["input_finish_handler_begin"]=InputDisplay.finishBegin
        record["input_draw_header"]=inputDrawHeader
        record["input_drawables"]=(0..<min(2048,Int(inputDrawHeader[0]))).map { Array(inputDrawRows[$0*9..<($0+1)*9]) }
        record["initial_tail_sha256"]=''')


def swift(source, once):
    return once(source, '        streamKeydown(event)', '''        streamKeydown(event)
        let inputDisplayKey=InputDisplay.begin(1,UInt64(bitPattern:event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0))
        defer { InputDisplay.end(inputDisplayKey) }''')


def present(source, once):
    source = once(source, 'static void postRendererEntry(void) { post_renderer_ns=stream_now();post_active_draw=0; }', 'static void postRendererEntry(void) { post_renderer_ns=stream_now();post_active_draw=0;inputDrawableReset(); }')
    source = once(source, '    const uint64_t index=post_draw_count++;', '    inputDrawableRecord(gen,prefix,ready);\n    const uint64_t index=post_draw_count++;')
    return 'static void inputDrawableReset(void);\nstatic void inputDrawableRecord(uint64_t,uint64_t,uint64_t);\n' + source + (HERE / 'input_display.c.inc').read_text()


def renderer(source, once):
    source = once(source, '    id<CAMetalDrawable> terminal_drawable = [terminal_layer nextDrawable];', '    inputDrawableBegin(0);\n    id<CAMetalDrawable> terminal_drawable = [terminal_layer nextDrawable];\n    inputDrawableEnd(0,terminal_drawable!=nil);')
    return once(source, '        overlay_drawable = [overlay_layer nextDrawable];', '        inputDrawableBegin(1);\n        overlay_drawable = [overlay_layer nextDrawable];\n        inputDrawableEnd(1,overlay_drawable!=nil);')
