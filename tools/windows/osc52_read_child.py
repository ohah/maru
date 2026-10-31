"""Controlled ConPTY child for check-osc52-read.py.

The parent resizes its owned window independently of child input consumption.
In-band resize reports inserted inside the OSC frame change its observed hash.
Only lengths, hashes and report-shape predicates leave this private process.
"""
import ctypes as c, json, os, time, threading, hashlib, re
from pathlib import Path
k=c.WinDLL('kernel32',use_last_error=True)
k.GetStdHandle.argtypes=[c.c_ulong];k.GetStdHandle.restype=c.c_void_p
k.SetConsoleMode.argtypes=[c.c_void_p,c.c_ulong]
k.ReadFile.argtypes=[c.c_void_p,c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.c_void_p]
root=Path(__file__).resolve().parent
if not __debug__ or os.name != 'nt' or '.zig-cache' not in root.parts:
    raise RuntimeError('This child requires a private Windows cache fixture')
case=json.loads((root/'case.json').read_text());h=k.GetStdHandle(-10 & 0xffffffff)
result={'console_mode':bool(k.SetConsoleMode(h,0x0200))};k.SetConsoleCP(65001)
stream=bytearray();done=threading.Event();resize=rb'(?:\x1b\[48;\d+;\d+;\d+;\d+t)+'
def read():
    while len(stream)<24000000:
        buf=c.create_string_buffer(4096);n=c.c_ulong()
        if not k.ReadFile(h,buf,len(buf),c.byref(n),None):break
        stream.extend(buf.raw[:n.value]);start=stream.find(b'\x1b]52;')
        if start<0:continue
        end=stream.find(b'\x1b\\',start)
        if end<0:continue
        tail=bytes(stream[end+2:])
        if not case['interleave'] or re.fullmatch(resize,tail):break
    done.set()
threading.Thread(target=read,daemon=True).start();time.sleep(1)
if case['interleave']:
    os.write(1,b'\x1b[?2048h');time.sleep(.2)
(root/'query-sent.json').write_text('{}')
os.write(1,b'\x1b]52;'+case['target'].encode()+b';?\x1b\\')
done.wait(case['timeout']);start=stream.find(b'\x1b]52;');end=stream.find(b'\x1b\\',max(0,start))
frame=stream[start:end+2] if start>=0 and end>=0 else stream
tail=bytes(stream[end+2:]) if start>=0 and end>=0 else b''
prefix=bytes(stream[:start]) if start>=0 else b''
result.update(received=bool(stream),frame_received=start>=0 and end>=0,length=len(frame),sha256=hashlib.sha256(frame).hexdigest(),resize_after_frame=bool(re.fullmatch(resize,tail)),prefix_resize_only=not prefix or bool(re.fullmatch(resize,prefix)))
(root/'child-result.json').write_text(json.dumps(result));os._exit(0)
