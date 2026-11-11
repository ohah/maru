"""xctrace의 행 신원과 명시적 reference만 해석한다. fmt 시각은 계산에 쓰지 않는다."""
import re
import xml.etree.ElementTree as ET
import verify


class Table:
    def __init__(self,path,name):
        self.root=ET.parse(path).getroot();self.ids={}
        for node in self.root.iter():
            if 'id' in node.attrib:
                key=node.attrib['id'];verify.require(key not in self.ids,'duplicate trace XML id');self.ids[key]=node
        schemas=list(self.root.iter('schema'))
        verify.require(len(schemas)==1 and schemas[0].get('name')==name,'trace XML schema mismatch')
        self.columns=[c.findtext('mnemonic') for c in schemas[0].findall('col')]
        verify.require(all(self.columns) and len(set(self.columns))==len(self.columns),'trace XML columns')
        self.rows=[]
        for row in self.root.iter('row'):
            verify.require(len(row)==len(self.columns),'trace XML row width')
            self.rows.append(dict(zip(self.columns,row)))

    def resolve(self,node):
        seen=set()
        while 'ref' in node.attrib:
            ref=node.attrib['ref'];verify.require(ref in self.ids and ref not in seen,'trace XML missing or cyclic ref')
            seen.add(ref);node=self.ids[ref]
        return node

    def integer(self,node):
        node=self.resolve(node);text=node.text or ''
        verify.require(bool(re.fullmatch(r'-?[0-9]+',text)),'trace integer unavailable')
        return int(text)

    def pid(self,node):
        node=self.resolve(node);matches=[self.resolve(n) for n in node if self.resolve(n).tag=='pid']
        verify.require(len(matches)==1,'trace process pid unavailable')
        return self.integer(matches[0])

    def labels(self,node,active=frozenset()):
        node=self.resolve(node);key=id(node)
        verify.require(key not in active,'trace nested reference cycle')
        active=active|{key};result=[]
        if node.tag=='metal-object-label':result.append(node.text or '')
        for child in node:result.extend(self.labels(child,active))
        return result

    def require_columns(self,*names):
        verify.require(all(n in self.columns for n in names),'trace columns unavailable')


def epoch(table):
    table.require_columns('mabs-epoch','timebase-info')
    values=[]
    for row in table.rows:
        clock=table.integer(row['mabs-epoch']);base=table.resolve(row['timebase-info'])
        verify.require(len(base)==2,'trace timebase shape')
        numerator,denominator=[table.integer(n) for n in base]
        verify.require(clock>0 and numerator>0 and denominator>0,'trace timebase values')
        values.append(clock*numerator//denominator)
    verify.require(bool(values) and len(set(values))==1,'trace epoch changed or missing')
    return values[0]


def submissions(table,pid):
    table.require_columns('process','cmdbuffer-id','start','duration','event-label')
    result={}
    for row in table.rows:
        if table.pid(row['process'])!=pid:continue
        labels=table.labels(row['event-label'])
        if 'track-label' in row:labels+=table.labels(row['track-label'])
        own={label for label in labels if re.fullmatch(r'maru-submit:[1-9][0-9]*:[1-9][0-9]*',label)}
        if not own:continue  # 준비 단계의 라벨 없는 buffer는 입력 frame 모집단 밖이다.
        verify.require(len(own)==1,'trace ambiguous frame label')
        label=own.pop();verify.require(label not in result,'trace duplicate frame label')
        identity=table.integer(row['cmdbuffer-id']);start=table.integer(row['start']);duration=table.integer(row['duration'])
        verify.require(identity>0 and start>=0 and duration>=0,'trace submission values')
        result[label]=dict(command_buffer_id=identity,start=start,committed=start+duration)
    verify.require(len({r['command_buffer_id'] for r in result.values()})==len(result),'trace command buffer id reused within labelled population')
    return result
