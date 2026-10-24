"""Windows app E2E: use only a private fixture launched by the caller.
State JSON must contain root/local/pid/hwnd. Its config must retain the sentinel
comment, shared width=180, Windows width, and future.key=keep used below.
The fixture is deliberately resized; this tool never targets a window by title.
"""
import ctypes,json,time,re,argparse,os
from pathlib import Path
parser=argparse.ArgumentParser(description="Exercise sidebar release routing in an explicitly owned private Maru fixture window")
parser.add_argument('--state',type=Path,required=True)
parser.add_argument('--exe',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
if not __debug__:parser.error('Run without Python optimization so all test checks remain active')
if os.name!='nt':parser.error('Windows is required')
s=json.loads(args.state.read_text(encoding='utf-8-sig'))
fixture=Path(s['root']).resolve();local=Path(s['local']).resolve()
if '.zig-cache' not in fixture.parts or not local.is_relative_to(fixture):parser.error('State must describe a private cache fixture')
u=ctypes.WinDLL('user32');k=ctypes.WinDLL('kernel32');h=ctypes.c_void_p(s['hwnd'])
k.OpenProcess.argtypes=[ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong];k.OpenProcess.restype=ctypes.c_void_p
k.QueryFullProcessImageNameW.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_wchar_p,ctypes.POINTER(ctypes.c_ulong)]
k.CloseHandle.argtypes=[ctypes.c_void_p]
process=k.OpenProcess(0x1000,False,s['pid']);assert process,'Fixture process unavailable'
try:
 name=ctypes.create_unicode_buffer(32768);length=ctypes.c_ulong(len(name))
 assert k.QueryFullProcessImageNameW(process,0,name,ctypes.byref(length))
 assert Path(name.value).resolve()==args.exe.resolve(),'Fixture executable differs'
finally:k.CloseHandle(process)
def check_owner():
 owner=ctypes.c_ulong();u.GetWindowThreadProcessId(h,ctypes.byref(owner));assert owner.value==s['pid'],'Fixture window owner changed'
 cls=ctypes.create_unicode_buffer(128);u.GetClassNameW(h,cls,128);assert cls.value=='MaruWindowClass','Not a Maru render window'
check_owner()
args.output.parent.mkdir(parents=True,exist_ok=True)
config=Path(s['local'])/'maru/config';checks=[]
def width():return int(re.search(r'^sidebar\.width\.windows\s*=\s*(\d+)\s*$',config.read_text(encoding='utf-8'),re.M).group(1))
def send(msg,x,w=0):
 check_owner();u.SendMessageW(h,msg,w,(300<<16)|(x&65535))
def settle(expected):
 time.sleep(.4);actual=width();assert expected(actual) if callable(expected) else actual==expected,(actual,expected)
 text=config.read_text(encoding='utf-8');assert 'sidebar.width = 180' in text and 'future.key = keep' in text and '# resize fixture comment' in text
 return actual
def gesture(name,end,moves=(),grab=0,expected=None,mode=None):
 before=width();send(0x201,before+grab,1);time.sleep(.05)
 for x in moves:send(0x200,x,1)
 if mode=='cancel':send(0x1f,0);time.sleep(.1)
 if mode=='right-up':send(0x205,end)
 send(0x202,end)
 if expected is None:expected=max(120,min(480,end-grab))
 actual=settle(expected)
 if mode=='duplicate':send(0x202,470);assert settle(actual)==actual
 checks.append(dict(name=name,before=before,release=end,grab_offset=grab,actual=actual,passed=True));print(name+' width='+str(actual),flush=True)
 args.output.write_text(json.dumps(dict(pid=s['pid'],checks=checks),indent=2),encoding='utf-8')
gesture('release without move forward',400)
gesture('release without move backward',320)
gesture('release beyond last move',440,[350])
gesture('release before last move',300,[450])
gesture('release reverses direction',420,[280])
gesture('queued moves do not replace release',360,[340,410,390])
gesture('left edge grab offset',396,grab=-4,expected=400)
gesture('right edge grab offset',324,grab=4,expected=320)
gesture('exact maximum',480)
gesture('above maximum',1000,expected=480)
gesture('negative release clamps',-1,expected=lambda x:120<=x<=480)
gesture('zero release clamps',0,expected=lambda x:120<=x<=480)
gesture('just below maximum',479)
before=width();gesture('capture loss cancels persistence',420,expected=before,mode='cancel')
gesture('duplicate release cannot resize again',400,mode='duplicate')
gesture('right release cannot commit left drag',440,mode='right-up')
before=width();gesture('unchanged release preserves config',before)
gesture('rapid direction changes settle final endpoint',430,[160,470,200])
gesture('minimum signed coordinate',-30000,expected=lambda x:120<=x<=480)
gesture('maximum signed coordinate',30000,expected=480)
assert len(checks)==20
