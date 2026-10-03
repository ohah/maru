import os, tempfile, subprocess, sys, json, time
from pathlib import Path
child = '''import os,sys
p,kind=sys.argv[1:]
sys.stdin.buffer.read(1)
try:
 if kind=='claim':
  fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd)
 else: os.mkdir(p,0o700)
 print('won',flush=True)
except FileExistsError: print('lost',flush=True)
'''
results=[]
with tempfile.TemporaryDirectory(prefix='maru-recovery-reservation-') as tmp:
 for kind in ('claim','directory'):
  base=Path(tmp)/kind;base.mkdir()
  start=time.perf_counter_ns()
  for i in range(20):
   target=base/str(i)
   peers=[subprocess.Popen([sys.executable,'-c',child,str(target),kind],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
   for p in peers:p.stdin.write(b'x');p.stdin.flush()
   outputs=[]
   try:
    for p in peers:
     out,err=p.communicate(timeout=10)
     assert p.returncode==0,(p.returncode,err)
     outputs.append(out.decode().strip())
   finally:
    for p in peers:
     if p.poll() is None:p.kill();p.wait()
   assert sorted(outputs)==['lost','won'],outputs
   record=(target/'record') if kind=='directory' else base/(str(i)+'.record')
   record.write_bytes(b'old-complete')
   staged=record.with_name(record.name+'.tmp')
   staged.write_bytes(b'new-complete')
   # Before replacement, aborting the prepared write leaves the old record intact.
   staged.unlink();assert record.read_bytes()==b'old-complete'
   staged.write_bytes(b'new-complete');os.replace(staged,record)
   assert record.read_bytes()==b'new-complete'
   assert target.exists()  # reservation survives record replacement
  elapsed=time.perf_counter_ns()-start
  results.append(dict(candidate=kind,races=20,exclusive_winners=20,abort_preserves_old=20,replace_complete=20,reservation_survives=True,elapsed_ns_including_process_startup=elapsed))
print(json.dumps({'scope':'isolated Python filesystem primitives, not Maru product writer or performance comparison','results':results},indent=2))
