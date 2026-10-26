"""Check live native font styles in an owned Windows cache fixture.

Launch an isolated app with Consolas 22 and the shipped ConPTY pair. Its shell
must print four identical 12-M rows using SGR 0, 1, 0;3 and 1;3, then reset SGR.
Provide the launcher's PID/HWND/root/work/local JSON and an exe/hash manifest
with conpty_bundle hashes. Only that owned window receives synthetic messages.
The checker changes five settings, compares GPU row pixels, and closes the app.
This is native app E2E, not physical keyboard or independent kernel-size proof.
"""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,time,subprocess,shutil
from ctypes import wintypes as w
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--state',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
if not __debug__:p.error('Run without Python optimization so fixture and clipboard guards remain active')
if os.name!='nt':p.error('Windows is required')
s=json.loads(args.state.read_text(encoding='utf-8-sig'));binary=json.loads(args.binary.read_text());root=Path(s['root']).resolve();assert '.zig-cache' in root.parts
assert Path(s['local']).resolve().is_relative_to(root),'local data must belong to the private fixture'
exe=Path(binary['exe']).resolve();assert hashlib.sha256(exe.read_bytes()).hexdigest()==binary['sha256']
assert '.zig-cache' in exe.parts,'executable must be a private cache copy'
bundle={relative.replace("\\","/"):digest for relative,digest in binary.get('conpty_bundle',{}).items()}
assert set(bundle)=={'conpty.dll','x64/OpenConsole.exe'},'the x64 fixture must include its shipped ConPTY pair'
for relative,digest in bundle.items():
    dependency=(exe.parent/relative).resolve()
    assert dependency.is_relative_to(exe.parent)
    assert hashlib.sha256(dependency.read_bytes()).hexdigest()==digest,'ConPTY bundle changed'

u=c.WinDLL('user32',use_last_error=True);k=c.WinDLL('kernel32',use_last_error=True);g=c.WinDLL('gdi32',use_last_error=True)
u.SetProcessDPIAware();h=s['hwnd']
k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD];k.OpenProcess.restype=w.HANDLE
k.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]
k.CloseHandle.argtypes=[w.HANDLE];k.WaitForSingleObject.argtypes=[w.HANDLE,w.DWORD];k.WaitForSingleObject.restype=w.DWORD
k.GetExitCodeProcess.argtypes=[w.HANDLE,c.POINTER(w.DWORD)];k.GetCurrentThreadId.restype=w.DWORD
u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)];u.GetWindowThreadProcessId.restype=w.DWORD
u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int]
u.SendMessageTimeoutW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t,w.UINT,w.UINT,c.POINTER(c.c_size_t)];u.SendMessageTimeoutW.restype=c.c_ssize_t
u.GetClientRect.argtypes=[w.HWND,c.POINTER(w.RECT)];u.GetWindowRect.argtypes=[w.HWND,c.POINTER(w.RECT)];u.ClientToScreen.argtypes=[w.HWND,c.POINTER(w.POINT)]
u.ShowWindow.argtypes=[w.HWND,c.c_int];u.SetWindowPos.argtypes=[w.HWND,w.HWND,c.c_int,c.c_int,c.c_int,c.c_int,w.UINT]
u.SetForegroundWindow.argtypes=[w.HWND];u.GetForegroundWindow.restype=w.HWND
u.WindowFromPoint.argtypes=[w.POINT];u.WindowFromPoint.restype=w.HWND
u.AttachThreadInput.argtypes=[w.DWORD,w.DWORD,w.BOOL];u.GetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)];u.SetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)]
u.GetDC.argtypes=[w.HWND];u.GetDC.restype=w.HANDLE;u.ReleaseDC.argtypes=[w.HWND,w.HANDLE]
g.CreateCompatibleDC.argtypes=[w.HANDLE];g.CreateCompatibleDC.restype=w.HANDLE
g.CreateCompatibleBitmap.argtypes=[w.HANDLE,c.c_int,c.c_int];g.CreateCompatibleBitmap.restype=w.HANDLE
g.SelectObject.argtypes=[w.HANDLE,w.HANDLE];g.SelectObject.restype=w.HANDLE
g.BitBlt.argtypes=[w.HANDLE,c.c_int,c.c_int,c.c_int,c.c_int,w.HANDLE,c.c_int,c.c_int,w.DWORD]
g.GetDIBits.argtypes=[w.HANDLE,w.HANDLE,w.UINT,w.UINT,c.c_void_p,c.c_void_p,w.UINT]
g.DeleteObject.argtypes=[w.HANDLE];g.DeleteDC.argtypes=[w.HANDLE]
process=k.OpenProcess(0x101000,False,s['pid']);assert process
name=c.create_unicode_buffer(32768);length=w.DWORD(len(name));assert k.QueryFullProcessImageNameW(process,0,name,c.byref(length));assert os.path.normcase(name.value)==os.path.normcase(str(exe))
checks=[];captures=[]

def check_owner():
    pid=w.DWORD();tid=u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==s['pid'],'fixture owner changed'
    cls=c.create_unicode_buffer(128);assert u.GetClassNameW(h,cls,len(cls));assert cls.value=='MaruWindowClass'
    return tid

def send(message,wp=0,lp=0):
    check_owner();result=c.c_size_t();assert u.SendMessageTimeoutW(h,message,wp,lp,2,3000,c.byref(result)),(hex(message),c.get_last_error())
    return result.value

def mouse(message,x,y):return send(message,1 if message==0x201 else 0,((y&65535)<<16)|(x&65535))

@contextlib.contextmanager
def neutral_keyboard():
    tid=check_owner();own=k.GetCurrentThreadId();msg=w.MSG();u.PeekMessageW(c.byref(msg),None,0,0,0)
    assert u.AttachThreadInput(own,tid,True);old=(c.c_ubyte*256)()
    try:
        assert u.GetKeyboardState(old);state=(c.c_ubyte*256)(*old)
        for key in (0x10,0x11,0x12,0x5b,0x5c):state[key]=0
        assert u.SetKeyboardState(state);yield
    finally:u.SetKeyboardState(old);u.AttachThreadInput(own,tid,False)

def key(value):
    with neutral_keyboard():send(0x100,value,1);send(0x101,value,0xc0000001)
    time.sleep(.12)

def probe_caption():
    point=w.POINT(500,16);assert u.ClientToScreen(h,c.byref(point))
    return send(0x84,0,((point.y&65535)<<16)|(point.x&65535))

def wait_caption(expected):
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        if probe_caption()==expected:return
        time.sleep(.03)
    raise AssertionError('popup/native caption state did not settle to '+str(expected))
def opened():wait_caption(1)
def closed():wait_caption(2)
def record(name):checks.append(name);print(name+' passed',flush=True)

def open_menu():
    mouse(0x204,520,220);mouse(0x205,520,220);time.sleep(.3);opened()

def capture(name):
    check_owner();rect=w.RECT();point=w.POINT();assert u.GetClientRect(h,c.byref(rect));assert u.ClientToScreen(h,c.byref(point))
    width,height=rect.right,rect.bottom;assert width==1000 and height==700
    for y in (3,height//2,height-4):
        for x in (3,width//2,width-4):
            under=u.WindowFromPoint(w.POINT(point.x+x,point.y+y));pid=w.DWORD();u.GetWindowThreadProcessId(under,c.byref(pid));assert pid.value==s['pid'],'capture is occluded'
    assert c.WinDLL('dwmapi').DwmFlush()==0
    screen=u.GetDC(None);dc=g.CreateCompatibleDC(screen);bitmap=g.CreateCompatibleBitmap(screen,width,height);assert screen and dc and bitmap
    old=g.SelectObject(dc,bitmap)
    try:
        assert g.BitBlt(dc,0,0,width,height,screen,point.x,point.y,0x40CC0020)
        g.SelectObject(dc,old)
        info=struct.pack('<IiiHHIIiiII',40,width,-height,1,32,0,width*height*4,0,0,0,0);header=c.create_string_buffer(info);data=c.create_string_buffer(width*height*4)
        assert g.GetDIBits(dc,bitmap,0,height,data,header,0)==height
        target=root/(name+'.bmp');target.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data.raw),0,0,54)+info+data.raw);captures.append(str(target));return target
    finally:g.DeleteObject(bitmap);g.DeleteDC(dc);u.ReleaseDC(None,screen)


def ctrl_comma():
    with neutral_keyboard():
        state=(c.c_ubyte*256)();assert u.GetKeyboardState(state);state[0x11]=0x80;assert u.SetKeyboardState(state)
        send(0x100,0xbc,1);send(0x101,0xbc,0xc0000001)
    time.sleep(.3)
def text(value):
    with neutral_keyboard():
        for cp in value:send(0x102,ord(cp),1)
    time.sleep(.2)
def search(value):text('/'+value)
config=Path(s['local'])/'maru'/'config'
def wait_config(token):
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
        value=config.read_text(encoding='utf-8')
        if token in value:return value
        time.sleep(.05)
    raise AssertionError('config did not contain '+token)
def close_overlay():
    for _ in range(4):
        if probe_caption()==2:break
        key(0x1b)
    closed()
def replace_edit(value):
    with neutral_keyboard():
        for _ in range(128):send(0x100,8,1);send(0x101,8,0xc0000001)
    text(value)
def wait_line(name,value):
    deadline=time.monotonic()+5
    while name+' = '+value not in config.read_text(encoding='utf-8'):
        assert time.monotonic()<deadline,'save did not settle'
        time.sleep(.05)
def applied(number):
    deadline=time.monotonic()+8
    pattern=r'font_applied='+str(number)+r' cell=(\d+)x(\d+) terminal_px=(\d+)x(\d+) core=(\d+)x(\d+) core_cell=(\d+)x(\d+)'
    while True:
        data=(root/'app.log').read_text(encoding='utf-8',errors='replace');match=re.search(pattern,data)
        if match:return list(map(int,match.groups()))
        assert time.monotonic()<deadline,'font save did not become a live application'
        time.sleep(.05)
def cursor_rect(path):
    data=path.read_bytes();runs={};rectangles=[]
    # Startup fallback fonts can change the titlebar height. Locate the dark
    # content below the caption instead of cutting a short caret at fixed y=38.
    origin=next((y for y in range(100) if max(data[54+(y*1000+500)*4:54+(y*1000+500)*4+3])<32),38)
    background=data[54+(500*1000+400)*4:54+(500*1000+400)*4+3]
    right=next((x for x in range(400,1000) if data[54+(500*1000+x)*4:54+(500*1000+x)*4+3]!=background),1000)
    for y in range(origin,320):
        line={};x=300
        while x<right:
            rgb=data[54+(y*1000+x)*4:54+(y*1000+x)*4+3]
            if min(rgb)>180 and max(rgb)-min(rgb)<25:
                begin=x;color=rgb;x+=1
                while x<right and data[54+(y*1000+x)*4:54+(y*1000+x)*4+3]==color:x+=1
                if x-begin>=4:line[(begin,x,color)]=runs.get((begin,x,color),y)
            else:x+=1
        for item,top in runs.items():
            if item not in line and y-top>=8:rectangles.append((item[0],top,item[1]-item[0],y-top))
        runs=line
    assert rectangles,'no visible terminal/editor cursor'
    return max(rectangles,key=lambda r:r[2]*r[3])

def style_rows(path,cw,ch):
    data=path.read_bytes();origin=next(y for y in range(100) if max(data[54+(y*1000+500)*4:54+(y*1000+500)*4+3])<32)
    rows=[]
    for row in range(4):
        pixels=b''.join(data[54+((origin+row*ch+y)*1000+300)*4:54+((origin+row*ch+y)*1000+300+10*cw)*4] for y in range(ch))
        assert any(v>80 for v in pixels[0::4]),'missing native SGR row '+str(row)
        rows.append(hashlib.sha256(pixels).hexdigest())
    return rows

failure=None;observations=[]
try:
    check_owner();u.ShowWindow(h,5);assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);time.sleep(1)
    before_path=capture('font-variants-before');cursor=cursor_rect(before_path);cw,ch=cursor[2:]
    before=style_rows(before_path,cw,ch);previous=before
    assert len(set(before))==4,'regular/bold/italic/bold-italic must visibly differ'
    cases=[('font.family-bold','Courier New',{1,3}),('font.family-italic','Times New Roman',{2}),('font.family-bold','Consolas',{1,3}),('font.family-italic','Consolas',{2}),('font.family-bold','Maru missing native font 9273',set())]
    for number,(name,value,changed) in enumerate(cases,1):
        ctrl_comma();opened();search(name);key(0x0d);replace_edit(value);key(0x0d);wait_line(name,value)
        metrics=applied(number);close_overlay();time.sleep(.3)
        assert metrics[0:2]==[cw,ch] and metrics[6:8]==[cw,ch],metrics
        path=capture('font-variants-'+str(number));rows=style_rows(path,cw,ch)
        actual={i for i in range(4) if rows[i]!=previous[i]};assert actual==changed,(name,value,actual,changed)
        assert rows[0]==before[0],'style override changed the regular row'
        if number>=4:assert rows==before,'regular-family restoration or invalid-family fallback changed the glyphs'
        observations.append({'key':name,'value':value,'changed_rows':sorted(actual),'row_hashes':rows,'metrics':metrics})
        previous=rows;record('native variant '+str(number)+' changed only '+str(sorted(actual)))
except Exception as error:failure=repr(error)
finally:
    if k.WaitForSingleObject(process,0)!=0:send(0x10);assert k.WaitForSingleObject(process,12000)==0
    code=w.DWORD();assert k.GetExitCodeProcess(process,c.byref(code));assert code.value==0
    log=(root/'app.log').read_text(encoding='utf-8',errors='replace');counts={}
    for name in ['keys_to_shell','bytes_to_shell','grid_mismatches','dock_rebuild_failures','font_applies','font_apply_errors','font_resize_errors']:
        match=re.search(r'\b'+name+r'=(\d+)',log);counts[name]=int(match[1]) if match else None
    if not re.search(r'^conpty=bundled$',log,re.MULTILINE) and failure is None:failure='fixture did not use the shipped ConPTY provider'
    expected={'keys_to_shell':0,'bytes_to_shell':0,'grid_mismatches':0,'dock_rebuild_failures':0,'font_applies':5,'font_apply_errors':0,'font_resize_errors':0}
    if counts!=expected and failure is None:failure='variant application counters: '+repr(counts)
    args.output.write_text(json.dumps({'valid':failure is None,'failure':failure,'observations':observations,'before_hashes':locals().get('before'),'counts':counts,'binary':binary,'checker_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'captures':captures,'exit':code.value,'scope':'Owned native app, real SGR shell output and GPU screenshot row hashes; synthetic HWND settings input, not physical keyboard'},indent=2))
    k.CloseHandle(process)
if failure:raise AssertionError(failure)
