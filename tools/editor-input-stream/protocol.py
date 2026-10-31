"""입력 ID와 서로 다른 ASCII 접두부를 공유하는 측정 사본 전용 계약이다."""
NAME = 'independent-target-ascii-v1'
TEXT = 'abcdefghijklmnopqrstuvwxyz0123456789'
CODES = (0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6,29,18,19,20,21,23,22,26,28,25)
MAGIC = 0x4D41525500000000
ROW_WIDTH = 12
HEADER_WIDTH = 9


def count(value):
    if type(value) is not int or not 1 <= value <= len(TEXT):
        raise ValueError('unique ASCII count')
    return value


def fixture(size):
    if type(size) is not int or size not in (3000, 50000):
        raise ValueError('fixed fixture size')
    return ('// \n'+''.join('pub fn f%d() void { const value: u64 = %d; _ = value; }\n'%(i,i) for i in range(size))).encode()


def expand(source):
    for marker, value in [('@STREAM_TEXT@', TEXT), ('@STREAM_CODES@', ','.join(map(str, CODES))), ('@STREAM_MAGIC@', hex(MAGIC))]:
        source = source.replace(marker, value)
    return source
