"""외부 진단 앱에만 화면 timing 관측기를 붙인다."""
from pathlib import Path
HERE=Path(__file__).resolve().parent
FIELDS=('begin','timestamp','target','duration','end')
CONTEXT=('display_id','maximum_frames_per_second','layer','display_sync','transaction','maximum_drawables','frame_loop_hz')


def driver(source,once):
    source=(HERE/'display_timing.swift.inc').read_text()+source
    source=once(source,'        let now=ProcessInfo.processInfo.systemUptime\n        if InputStream.phase<2','        if #available(macOS 14.0, *) { DisplayTiming.shared.observe(view,w,currentFrameLoopRateHz()) }\n        let now=ProcessInfo.processInfo.systemUptime\n        if InputStream.phase<2')
    return once(source,'        record["initial_tail_sha256"]=','        if #available(macOS 14.0, *) { record["display_timing"]=DisplayTiming.shared.finish() } else { record["display_timing"]=["unsupported":true] }\n        record["initial_tail_sha256"]=')
