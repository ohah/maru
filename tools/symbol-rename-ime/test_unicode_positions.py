"""Different byte/scalar/UTF-16 positions must never rename a neighboring token or comment."""
import json
from pathlib import Path
import re
import tempfile
import unittest
from test_real_server import real_fixture
from test_verify import publish
from verify import PREFIX,MAIN,OTHER,LOCAL,h,validate_diagnostic


def unicode_fixture(root,scene='hanja',encoding='utf-16',documents=False):
    r,m,w=real_fixture(root,scene,documents)
    original=PREFIX+MAIN;other=PREFIX+'int base(void);\n'+PREFIX+OTHER
    case=json.loads((root/'case.json').read_text());case.update(unicode_prefix=True,main=original,other=other)
    (root/'case.json').write_text(json.dumps(case));(root/'project/main.c').write_text(original);(root/'project/other.c').write_text(other)
    name='base한' if scene=='korean' else 'base韓'
    applied=scene in ('hanja','korean')
    for row in r['observations']:
        body=original.replace(' base(',' '+name+'(') if row['name']=='applied' else LOCAL+original if row['name']=='invalidated' else original
        row['body_hash']=h(body)
    m.update(body=LOCAL+original if scene=='stale' else original,main_disk=original,other_disk=other)
    w[1]['message']['result']['capabilities']['positionEncoding']=encoding
    w[2]['message']['params']['textDocument']['text']=original
    codec,width=('utf-8',1) if encoding=='utf-8' else ('utf-16-le',2)
    if applied:
        w[3]['message']['params']['position']['character']=len((PREFIX+'int ').encode(codec))//width
        changes={}
        for path,text in ((root/'project/main.c',original),(root/'project/other.c',other)):
            edits=[]
            for line,body in enumerate(text.splitlines()):
                for match in re.finditer(r'\bbase\b',body):
                    start=len(body[:match.start()].encode(codec))//width
                    edits.append(dict(range=dict(start=dict(line=line,character=start),end=dict(line=line,character=start+4)),newText=name))
            changes[path.resolve().as_uri()]=edits
        w[4]['message']['result']=dict(documentChanges=[dict(textDocument=dict(uri=u,version=1 if u.endswith('/main.c') else None),edits=e) for u,e in changes.items()]) if documents else dict(changes=changes)
        first=json.loads((root/'applied.json').read_text());first.update(body=original.replace(' base(',' '+name+'('),main_disk=original.replace(' base(',' '+name+'('),other_disk=other.replace('base(',name+'('))
        (root/'applied.json').write_text(json.dumps(first))
    publish(root,m,w)
    return r,m,w


class UnicodePositionControls(unittest.TestCase):
    def test_distinct_units_and_forms(self):
        self.assertEqual(len((PREFIX+'int ').encode('utf-8')),18)
        self.assertEqual(len((PREFIX+'int ').encode('utf-16-le'))//2,14)
        self.assertEqual(len(PREFIX+'int '),13)
        for scene in ('hanja','korean','cancel','stale'):
            for encoding in ('utf-8','utf-16'):
                for documents in (False,True):
                    with self.subTest(scene=scene,encoding=encoding,documents=documents),tempfile.TemporaryDirectory() as directory:
                        root=Path(directory);r,*_=unicode_fixture(root,scene,encoding,documents)
                        result=validate_diagnostic(r);self.assertTrue(result['unicode_prefix']);self.assertEqual(result['position_encoding'],encoding)

    def test_twenty_unicode_corruptions(self):
        labels=('mode_off','mode_type','controlled','fixture_main','fixture_other','initial_body','opened_text',
                'request_scalars','request_bytes','request_line','edit_scalars','edit_bytes','split_surrogate',
                'comment_edit','response_text','applied_prefix','undo_prefix','disk_prefix','encoding','wrong_encoding')
        for label in labels:
            with self.subTest(label=label),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);r,m,w=unicode_fixture(root)
                case=json.loads((root/'case.json').read_text());position=w[3]['message']['params']['position']
                edit=next(iter(w[4]['message']['result']['changes'].values()))[0]
                if label=='mode_off':case['unicode_prefix']=False
                elif label=='mode_type':case['unicode_prefix']='true'
                elif label=='controlled':case['server']['kind']='controlled'
                elif label=='fixture_main':case['main']=MAIN
                elif label=='fixture_other':case['other']=OTHER
                elif label=='initial_body':r['observations'][0]['body_hash']=h(MAIN)
                elif label=='opened_text':w[2]['message']['params']['textDocument']['text']=MAIN
                elif label=='request_scalars':position['character']=13
                elif label=='request_bytes':position['character']=18
                elif label=='request_line':position['line']=1
                elif label in ('edit_scalars','edit_bytes'):
                    start=13 if label=='edit_scalars' else 18;edit['range']=dict(start=dict(line=0,character=start),end=dict(line=0,character=start+4))
                elif label=='split_surrogate':edit['range']['start']['character']=5
                elif label=='comment_edit':edit['range']=dict(start=dict(line=0,character=3),end=dict(line=0,character=4))
                elif label=='response_text':edit['newText']='base'
                elif label=='applied_prefix':
                    p=root/'applied.json';v=json.loads(p.read_text());v['body']=v['body'].removeprefix(PREFIX);p.write_text(json.dumps(v))
                elif label=='undo_prefix':m['body']=MAIN
                elif label=='disk_prefix':(root/'project/main.c').write_text(MAIN)
                elif label=='encoding':w[1]['message']['result']['capabilities']['positionEncoding']='utf-32'
                elif label=='wrong_encoding':w[1]['message']['result']['capabilities']['positionEncoding']='utf-8'
                (root/'case.json').write_text(json.dumps(case));publish(root,m,w)
                with self.assertRaises(ValueError):validate_diagnostic(r)


if __name__=='__main__':unittest.main()
