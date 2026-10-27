"""Product mutation controls; no UI or pixel claim is made here."""
from pathlib import Path
import subprocess,json,argparse
parser=argparse.ArgumentParser(description='Compile-valid product mutations in an isolated external copy')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[2]
root=args.output.resolve()
if root==repo or root.is_relative_to(repo):parser.error('external output required')
root.mkdir(mode=0o700,parents=True)
snapshot=root/'source'
subprocess.run(['rsync','-a','--exclude=.git','--exclude=.zig-cache','--exclude=zig-out','--exclude=node_modules','--exclude=references','--exclude=.env*',str(repo)+'/',str(snapshot)+'/'],check=True)
for rel in ('node_modules','web/node_modules'):
    if (repo/rel).exists():(snapshot/rel).symlink_to(repo/rel,target_is_directory=True)
host='src/platform/macos/app_session/reference_picker_ime.zig'
rows='src/platform/macos/reference_picker.zig'
mutations=[
 ('range_ignored',host,'bytes, replacement, &self.reference_picker_ime.transaction)','bytes, if (replacement != null) null else replacement, &self.reference_picker_ime.transaction)'),
 ('legacy_clear_before_admission',rows,'        try self.prepareFilter(allocator);','        self.shown.clearRetainingCapacity(); try self.prepareFilter(allocator);'),
 ('filter_not_published',host,'if (result.changed) publishRows(self);','if (result.changed and p.input.query.items.len == 0) publishRows(self);'),
 ('result_owner_ignored',host,'.results = self.reference_picker_rows.result_generation','.results = 0'),
 ('candidate_return_leaks',host,'return result.consumed or s.transaction.rejected;','return if (key == .enter) false else result.consumed or s.transaction.rejected;'),
]
results=[]
def run(name):
    path=root/(name+'.log')
    with path.open('w') as log:
        result=subprocess.run(['mise','exec','--','zig','build','test-reference-picker-ime','-j2'],cwd=snapshot,stdout=log,stderr=subprocess.STDOUT)
    return result.returncode,path.read_text()
rc,log=run('normal-before');assert rc==0
for name,rel,old,new in mutations:
    path=snapshot/rel;original=path.read_text();assert original.count(old)==1,(name,original.count(old))
    try:
        path.write_text(original.replace(old,new))
        rc,log=run(name)
        semantic=rc!=0 and 'FAIL (' in log and 'compilation errors' not in log and 'compilation error' not in log
        results.append(dict(name=name,exit=rc,assertion_failed=semantic))
        (root/'results.json').write_text(json.dumps(results,indent=2))
        assert semantic,(name,log[-2000:])
    finally:path.write_text(original)
rc,log=run('restored-after');assert rc==0
print(json.dumps(results))
