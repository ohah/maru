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
model='src/chrome/components/activity_search_ime.zig'
host='src/platform/macos/app_session/activity_search_ime.zig'
mutations=[
 ('range_ignored',model,'bytes, replacement, &self.transaction)','bytes, if (replacement != null) null else replacement, &self.transaction)'),
 ('rollback_disabled',model,'return self.projection.finishKey(a, field, &self.transaction, key, deleted);','self.transaction.rejected = false; return self.projection.finishKey(a, field, &self.transaction, key, deleted);'),
 ('filter_preflight_bypassed',host,'const s = &self.agent_activity;\n    // applyFilter','const s = &self.agent_activity;\n    if (s.all_hits.items.len > 0) return true;\n    // applyFilter'),
 ('body_invalidation_disabled',host,'    ops.cancelBodySearch(self);','    if (self.agent_activity.search.query.items.len == 0) ops.cancelBodySearch(self);'),
 ('candidate_return_leaks',model,'return self.projection.finishKey(a, field, &self.transaction, key, deleted);','var result = self.projection.finishKey(a, field, &self.transaction, key, deleted); if (key == .enter) result.consumed = false; return result;'),
]
results=[]
def run(name):
    path=root/(name+'.log')
    with path.open('w') as log:
        result=subprocess.run(['mise','exec','--','zig','build','test-activity-search-ime','-j2'],cwd=snapshot,stdout=log,stderr=subprocess.STDOUT)
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
