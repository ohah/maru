"""프레임 비용 기록의 구간 이름과 버전을 생산자·소비자가 함께 사용한다."""

STAGES = ('refreshViewAfterEditImpl', 'advanceSyntax', 'promoteFoldRangesToSyntax',
          'rebuildVisible', 'syntaxColors', 'minimapSide', 'maxColsForRender',
          'ensureLineCols', 'buildPaneOps', 'appendPaneFrame', 'ensureFoldRanges',
          'installFoldRanges', 'foldSpansCached', 'syntaxEdit')
LEGACY_SYNTAX_STAGES = ('bracketShift', 'providerEdit', 'foldCacheEdit', 'bracketRefresh', 'nativeParse')


def syntax_stages(schema):
    if type(schema) is not int or schema not in (1, 2):
        raise ValueError('Unknown frame schema')
    if schema == 1:
        return LEGACY_SYNTAX_STAGES
    return LEGACY_SYNTAX_STAGES[:3] + ('bracketUpdate',) + LEGACY_SYNTAX_STAGES[4:]


def manifest_schema(info):
    # 옛 자료에는 버전 필드가 없었다. 필드와 의미까지 맞을 때만 그 계약으로 읽는다.
    schema = info.get('frame_schema', 1)
    stages = syntax_stages(schema)
    operation = 'copy-or-refresh' if schema == 2 else 'refresh'
    if info.get('frame_stages') != list(STAGES + stages):
        raise ValueError('Frame stage manifest differs from reader')
    if info.get('frame_bracket_operation', 'refresh') != operation:
        raise ValueError('Frame bracket operation differs from schema')
    if info.get('frame_call_stages', []) != (['providerEdit', 'bracketUpdate'] if schema == 2 else []):
        raise ValueError('Frame call coverage differs from schema')
    return schema
