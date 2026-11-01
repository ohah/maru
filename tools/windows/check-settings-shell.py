"""Verify saved Windows shell commands affect future terminals in a fresh private fixture."""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,time
from ctypes import wintypes as w
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--state',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--old-control',action='store_true');args=p.parse_args()
if not __debug__:p.error('Run without Python optimization so fixture and clipboard guards remain active')
if os.name!='nt':p.error('Windows is required')
s=json.loads(args.state.read_text(encoding='utf-8-sig'));binary=json.loads(args.binary.read_text());root=Path(s['root']).resolve();assert '.zig-cache' in root.parts
assert Path(s['local']).resolve().is_relative_to(root),'local data must belong to the private fixture'
exe=Path(binary['exe']).resolve();assert hashlib.sha256(exe.read_bytes()).hexdigest()==binary['sha256']
assert '.zig-cache' in exe.parts,'executable must be a private cache copy'
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
import subprocess,re
def children():
    script='Get-CimInstance Win32_Process -Filter "ParentProcessId = '+str(s['pid'])+'" | Select-Object ProcessId,Name,ExecutablePath | ConvertTo-Json -Compress'
    output=subprocess.check_output(['powershell','-NoProfile','-Command',script]).decode('utf-8-sig').strip()
    value=json.loads(output) if output else []
    return value if isinstance(value,list) else [value]

def save_command(value):
    closed();ctrl_comma();opened();search('shell.command');key(0x0d)
    with neutral_keyboard():
        for _ in range(256):send(0x100,8,1);send(0x101,8,0xc0000001)
    text(value);key(0x0d)
    token='shell.command = '+value.strip()
    deadline=time.monotonic()+4
    while not any(line.strip()==token.strip() for line in config.read_text(encoding='utf-8').splitlines()):
        assert time.monotonic()<deadline,'saved command did not settle'
        time.sleep(.05)
    # Stop at the first closed overlay; surplus Escape would become shell input.
    for _ in range(3):
        if probe_caption()==2:break
        key(0x1b)
    closed()

failure=None;observations=[]
try:
    check_owner();u.ShowWindow(h,5);assert u.SetWindowPos(h,w.HWND(-1),20,20,1000,700,0x40);time.sleep(.5)
    original=children();shells=[v for v in original if v['Name'].lower() in ('pwsh.exe','powershell.exe')]
    assert len(shells)==1 and shells[0]['ExecutablePath'],'fresh fixture must use default PowerShell'
    cmd=(Path(os.environ['SystemRoot'])/'System32'/'cmd.exe').resolve();assert cmd.is_file()
    cmd_value=cmd.as_posix();powershell=Path(shells[0]['ExecutablePath']).as_posix()
    missing=(root/'not-installed-shell.exe').as_posix();assert not Path(missing).exists()
    cases=[('explicit-command',cmd_value,'cmd.exe'),('explicit-powershell',powershell,shells[0]['Name'].lower()),('missing-shell-fallback',missing,shells[0]['Name'].lower()),('trimmed-command','  '+cmd_value+'  ','cmd.exe'),('switch-back',powershell,shells[0]['Name'].lower())]
    if args.old_control:cases=cases[:1]
    for label,value,expected in cases:
        before=children();save_command(value);capture(label+'-saved')
        mouse(0x201,280,17);mouse(0x202,280,17)
        deadline=time.monotonic()+4
        while True:
            after=children();new=[v for v in after if v['ProcessId'] not in {x['ProcessId'] for x in before} and v['Name'].lower()!='conhost.exe']
            if new or time.monotonic()>deadline:break
            time.sleep(.1)
        assert len(new)==1,(label,new)
        wanted=shells[0]['Name'].lower() if args.old_control else expected
        assert new[0]['Name'].lower()==wanted,(label,wanted,new)
        assert {x['ProcessId'] for x in before}.issubset({x['ProcessId'] for x in after}),'existing child was replaced'
        saved=config.read_text(encoding='utf-8');assert '# resize fixture comment' in saved and 'future.key = keep' in saved and 'sidebar.width.windows = 300' in saved
        observations.append({'case':label,'command':value,'expected':wanted,'new_child':new[0],'existing_children_retained':True})
        capture(label+'-spawned');record(label+(' stale-shell negative control' if args.old_control else ' latest shell launch'))
except Exception as error:failure=repr(error)
finally:
    if k.WaitForSingleObject(process,0)!=0:send(0x10);assert k.WaitForSingleObject(process,12000)==0
    code=w.DWORD();assert k.GetExitCodeProcess(process,c.byref(code));assert code.value==0
    log=(root/'app.log').read_text(encoding='utf-8',errors='replace')
    counts={name:int(re.search(r'\b'+name+r'=(\d+)',log)[1]) for name in ['keys_to_shell','bytes_to_shell']}
    if counts!={'keys_to_shell':0,'bytes_to_shell':0} and failure is None:failure='Unexpected shell input: '+repr(counts)
    args.output.write_text(json.dumps({'valid':failure is None,'old_control':args.old_control,'failure':failure,'observations':observations,'binary':binary,'captures':captures,'counts':counts,'exit':code.value,'input':'Synthetic owned HWND settings/header input; direct owned child process observation, not physical keyboard evidence'},indent=2))
    k.CloseHandle(process)
if failure:raise AssertionError(failure)
