"""Open and cancel the app file picker in an isolated profile (synthetic HWND input)."""
import argparse,contextlib,ctypes as c,hashlib,json,os,re,struct,subprocess,sys,tempfile,time
from ctypes import wintypes as w
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--case',choices=['cancel','open'],default='cancel');p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
if not __debug__:p.error('Run without Python optimization')
if os.name!='nt':p.error('Windows is required')
exe=args.exe.resolve();assert exe.is_file() and '.zig-cache' in exe.parts
assert not args.output.exists()
root=Path(tempfile.mkdtemp(prefix='maru-app-picker-',dir=Path(tempfile.gettempdir())/'.zig-cache'))
profile=root/'profile';local=root/'local';profile.mkdir();local.mkdir()
for folder in ('Desktop','Documents','Downloads','Pictures','Music','Videos'):(profile/folder).mkdir()
selected=root/'picker-selected-한글.txt';selected.write_text('MARU_PICKER_ACCEPTANCE_20261101\n선택한 파일의 실제 편집기 내용입니다.\n',encoding='utf-8')
(root/'picker_child.py').write_text("import time\nfrom pathlib import Path\nwhile not Path('stop-child').exists(): time.sleep(.05)\n",encoding='utf-8')
config=root/'config';config.write_text('ui.language = en\nshell.command = '+Path(sys.executable).as_posix()+'\nshell.args = -u -m picker_child\n',encoding='utf-8')
env=dict(os.environ,HOME=str(profile),USERPROFILE=str(profile),LOCALAPPDATA=str(local),MARU_CONFIG=str(config));env.pop('MARU_TRACE',None);env.pop('MARU_DEBUG',None)
u=c.WinDLL('user32',use_last_error=True);k=c.WinDLL('kernel32',use_last_error=True)
CALLBACK=c.WINFUNCTYPE(w.BOOL,w.HWND,w.LPARAM)
u.EnumChildWindows.argtypes=[w.HWND,CALLBACK,w.LPARAM];u.GetDlgCtrlID.argtypes=[w.HWND];u.GetParent.argtypes=[w.HWND];u.GetParent.restype=w.HWND
u.EnumWindows.argtypes=[CALLBACK,w.LPARAM];u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)];u.GetWindowThreadProcessId.restype=w.DWORD
u.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int];u.IsWindowVisible.argtypes=[w.HWND];u.IsWindowEnabled.argtypes=[w.HWND]
u.GetAncestor.argtypes=[w.HWND,w.UINT];u.GetAncestor.restype=w.HWND
u.SendMessageTimeoutW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t,w.UINT,w.UINT,c.POINTER(c.c_size_t)];u.SendMessageTimeoutW.restype=c.c_ssize_t
u.PostMessageW.argtypes=[w.HWND,w.UINT,c.c_size_t,c.c_ssize_t]
u.AttachThreadInput.argtypes=[w.DWORD,w.DWORD,w.BOOL];u.GetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)];u.SetKeyboardState.argtypes=[c.POINTER(c.c_ubyte)];k.GetCurrentThreadId.restype=w.DWORD

def windows(pid,cls):
 found=[]
 @CALLBACK
 def visit(h,_):
  owner=w.DWORD();u.GetWindowThreadProcessId(h,c.byref(owner));name=c.create_unicode_buffer(128);u.GetClassNameW(h,name,128)
  if owner.value==pid and name.value==cls and u.IsWindowVisible(h):found.append(h)
  return True
 u.EnumWindows(visit,0);return found

def capture_app(h):
 u.SetProcessDPIAware()
 u.SetForegroundWindow.argtypes=[w.HWND];u.SetWindowPos.argtypes=[w.HWND,w.HWND,c.c_int,c.c_int,c.c_int,c.c_int,w.UINT]
 width=min(1000,u.GetSystemMetrics(0)-80);height=min(700,u.GetSystemMetrics(1)-160)
 assert width>=400 and height>=300
 assert u.SetWindowPos(h,w.HWND(-1),40,40,width,height,0x40)
 u.SetForegroundWindow(h);time.sleep(.4)
 u.GetClientRect.argtypes=[w.HWND,c.POINTER(w.RECT)];u.ClientToScreen.argtypes=[w.HWND,c.POINTER(w.POINT)]
 u.WindowFromPoint.argtypes=[w.POINT];u.WindowFromPoint.restype=w.HWND
 u.GetDC.argtypes=[w.HWND];u.GetDC.restype=w.HANDLE;u.ReleaseDC.argtypes=[w.HWND,w.HANDLE]
 rect=w.RECT();origin=w.POINT();assert u.GetClientRect(h,c.byref(rect)) and u.ClientToScreen(h,c.byref(origin))
 width,height=rect.right,rect.bottom;assert 100<=width<=4096 and 100<=height<=4096
 receipt['capture_geometry']={'origin':[origin.x,origin.y],'size':[width,height]}
 for x,y in [(20,20),(width//2,height//2),(width-20,height-20)]:
  pid=w.DWORD();under=u.WindowFromPoint(w.POINT(origin.x+x,origin.y+y));u.GetWindowThreadProcessId(under,c.byref(pid))
  if pid.value!=proc.pid:
   name=c.create_unicode_buffer(128);u.GetClassNameW(under,name,128)
   receipt['occlusion']={'point':[x,y],'pid':pid.value,'class':name.value}
  assert pid.value==proc.pid,'private app capture is occluded'
 g=c.WinDLL('gdi32',use_last_error=True)
 g.CreateCompatibleDC.argtypes=[w.HANDLE];g.CreateCompatibleDC.restype=w.HANDLE
 g.CreateCompatibleBitmap.argtypes=[w.HANDLE,c.c_int,c.c_int];g.CreateCompatibleBitmap.restype=w.HANDLE
 g.SelectObject.argtypes=[w.HANDLE,w.HANDLE];g.SelectObject.restype=w.HANDLE
 g.BitBlt.argtypes=[w.HANDLE,c.c_int,c.c_int,c.c_int,c.c_int,w.HANDLE,c.c_int,c.c_int,w.DWORD]
 g.GetDIBits.argtypes=[w.HANDLE,w.HANDLE,w.UINT,w.UINT,c.c_void_p,c.c_void_p,w.UINT]
 g.DeleteObject.argtypes=[w.HANDLE];g.DeleteDC.argtypes=[w.HANDLE]
 screen=u.GetDC(None);dc=g.CreateCompatibleDC(screen);bitmap=g.CreateCompatibleBitmap(screen,width,height);assert screen and dc and bitmap
 old=g.SelectObject(dc,bitmap)
 try:
  assert c.WinDLL('dwmapi').DwmFlush()==0
  assert g.BitBlt(dc,0,0,width,height,screen,origin.x,origin.y,0x40cc0020)
  g.SelectObject(dc,old);info=struct.pack('<IiiHHIIiiII',40,width,-height,1,32,0,width*height*4,0,0,0,0);header=c.create_string_buffer(info);data=c.create_string_buffer(width*height*4)
  assert g.GetDIBits(dc,bitmap,0,height,data,header,0)==height
  target=root/'accepted-file.bmp';target.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data.raw),0,0,54)+info+data.raw)
  receipt['capture']=str(target);receipt['capture_sha256']=hashlib.sha256(target.read_bytes()).hexdigest()
 finally:g.DeleteObject(bitmap);g.DeleteDC(dc);u.ReleaseDC(None,screen)

def filename_control(dialog):
 found=[];observed=[]
 @CALLBACK
 def visit(h,_):
  pid=w.DWORD();u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==proc.pid
  name=c.create_unicode_buffer(128);u.GetClassNameW(h,name,128);ident=u.GetDlgCtrlID(h);parent=u.GetDlgCtrlID(u.GetParent(h));observed.append({'class':name.value,'id':ident,'parent_id':parent})
  if name.value=='Edit' and (ident==1148 or parent==1148):found.append(h)
  return True
 u.EnumChildWindows(dialog,visit,0);receipt['dialog_controls']=observed
 assert len(found)==1,('filename edit control must be unique',len(found))
 return found[0]

def wait_for(check,seconds=15):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  result=check()
  if result:return result
  assert proc.poll() is None,'owned test app exited early'
  time.sleep(.03)
 raise AssertionError('owned app condition timed out')

def send(h,msg,wp=0,lp=0):
 pid=w.DWORD();u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==proc.pid
 result=c.c_size_t();assert u.SendMessageTimeoutW(h,msg,wp,lp,2,3000,c.byref(result))

@contextlib.contextmanager
def keyboard(h):
 pid=w.DWORD();tid=u.GetWindowThreadProcessId(h,c.byref(pid));assert pid.value==proc.pid
 own=k.GetCurrentThreadId();msg=w.MSG();u.PeekMessageW(c.byref(msg),None,0,0,0)
 assert u.AttachThreadInput(own,tid,True);old=(c.c_ubyte*256)()
 try:
  assert u.GetKeyboardState(old);state=(c.c_ubyte*256)(*old)
  for key in (0x10,0x11,0x12,0x5b,0x5c):state[key]=0
  state[0x10]=state[0x11]=0x80;assert u.SetKeyboardState(state);yield
 finally:u.SetKeyboardState(old);u.AttachThreadInput(own,tid,False)

receipt={'exe':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'root':str(root),'valid':False,'scope':'actual app dialog through synthetic HWND chord; file-open case additionally checks app document registration. No physical input claim','case':args.case}
with (root/'app.log').open('wb') as out,(root/'errors.log').open('wb') as err:
 proc=subprocess.Popen([str(exe),'win32-terminal'],cwd=root,env=env,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
 receipt['pid']=proc.pid
 failure=None;h=None
 try:
  h=wait_for(lambda: next(iter(windows(proc.pid,'MaruWindowClass')),None));time.sleep(1)
  with keyboard(h):send(h,0x100,ord('O'),1);send(h,0x101,ord('O'),0xc0000001)
  dialog=wait_for(lambda: next((x for x in windows(proc.pid,'#32770') if u.GetAncestor(x,3)==h),None))
  assert not u.IsWindowEnabled(h);receipt['modal_seen']=True
  if args.case=='cancel':
   # Native user cancellation of this exact owned dialog.
   send(dialog,0x10)
  else:
   edit=filename_control(dialog);text=c.create_unicode_buffer(str(selected))
   send(edit,0xc,0,c.addressof(text));send(dialog,0x111,1,0)
   receipt['selected_path']=str(selected);receipt['selected_sha256']=hashlib.sha256(selected.read_bytes()).hexdigest()
  wait_for(lambda: not windows(proc.pid,'#32770') and u.IsWindowEnabled(h),10)
  receipt['restored_owner']=True
  if args.case=='open':time.sleep(2);capture_app(h)
 except BaseException as error:
  failure=repr(error);receipt['failure']=failure
 finally:
  if h:
   owner=w.DWORD();u.GetWindowThreadProcessId(h,c.byref(owner))
   if owner.value==proc.pid:u.SetWindowPos(h,w.HWND(-2),0,0,0,0,0x13)
  for dialog in windows(proc.pid,'#32770'):
   try:send(dialog,0x10)
   except Exception:pass
  (root/'stop-child').write_text('stop',encoding='utf-8')
  time.sleep(1)
  for owned in windows(proc.pid,'MaruWindowClass'):u.PostMessageW(owned,0x10,0,0)
  try:receipt['exit']=proc.wait(timeout=12)
  except subprocess.TimeoutExpired:receipt['exit']=None
receipt['valid']=receipt.get('modal_seen',False) and receipt.get('restored_owner',False) and receipt.get('exit')==0 and failure is None
if args.case=='open':
 log=(root/'app.log').read_text(encoding='utf-8',errors='replace')
 receipt['document_registered']=bool(re.search(r'open_files=1 lists_agree=true',log))
 receipt['valid']=receipt['valid'] and receipt['document_registered']
args.output.write_bytes(json.dumps(receipt,indent=2).encode());print(json.dumps(receipt));assert receipt['valid']
