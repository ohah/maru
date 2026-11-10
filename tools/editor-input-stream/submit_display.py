"""같은 command buffer의 GPU 시각과 첫 drawable 표시를 외부 사본에서 연결한다."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIELDS = ('generation','prefix','ready','renderer','commit','returned','kernel_start','kernel_end','gpu_start','gpu_end','scheduled_cb','completed_cb','presented','status','error','main_thread','scheduled_thread','completed_thread','presented_thread','presented_cb','command_buffer','drawable','scheduled_buffer','completed_buffer','presented_drawable')
WIDTH = len(FIELDS)
MODES = ('disabled', 'enabled')


def driver(source, once):
    source = '''@_silgen_name("maru_submit_pending") private func submitPending() -> UInt64
@_silgen_name("maru_submit_copy") private func submitCopy(_ header: UnsafeMutablePointer<UInt64>,_ rows: UnsafeMutablePointer<UInt64>)
''' + source
    source = once(source, '&& postPending()==0 {', '&& postPending()==0 && submitPending()==0 {')
    code = '''        var submitHeader=[UInt64](repeating:0,count:5),submitRows=[UInt64](repeating:0,count:2048*@WIDTH@)
        submitCopy(&submitHeader,&submitRows)
        record["submit_display_mode"]=InputStream.env["MARU_SUBMIT_DISPLAY_TIMED"]=="1" ? "enabled" : "disabled"
        record["submit_fields"]=@FIELDS@
        record["submit_header"]=submitHeader
        record["submit_rows"]=(0..<min(2048,Int(submitHeader[0]))).map { Array(submitRows[$0*@WIDTH@..<($0+1)*@WIDTH@]) }
        record["initial_tail_sha256"]='''
    return once(source, '        record["initial_tail_sha256"]=', code.replace('@WIDTH@', str(WIDTH)).replace('@FIELDS@', json.dumps(FIELDS)))


def present(source):
    enum = 'enum { ' + ', '.join('S_'+name.upper()+'='+str(index) for index, name in enumerate(FIELDS)) + ', S_WIDTH='+str(WIDTH)+' };\n'
    return source + enum + (HERE / 'submit_display.c.inc').read_text()


def renderer(source, once):
    return once(source, '    postCommit();\n    [command_buffer commit];\n    return !overlay_content_dropped;', '    postCommit();\n    const uint64_t submit_index=submitArm(command_buffer,terminal_drawable);\n    [command_buffer commit];\n    submitReturn(submit_index);\n    return !overlay_content_dropped;')
