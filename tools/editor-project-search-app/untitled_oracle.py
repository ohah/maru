"""첫 저장 실측의 단일 표본과 집계 입력을 검증한다."""
import re


METRICS = ('call_ns', 'next_event_ns', 'serialize_ns', 'io_ns', 'settled_ns')


def validate_metrics(metrics, size, delay):
    if type(metrics.get('bytes')) is not int or type(metrics.get('injected_delay_ms')) is not int or metrics.get('bytes') != size or metrics.get('injected_delay_ms') != delay:
        raise ValueError('Untitled sample does not match the requested size/delay')
    if any(type(metrics.get(key)) is not int or metrics[key] < 0 for key in METRICS):
        raise ValueError('Untitled times must be nonnegative integer nanoseconds')
    if not (metrics['settled_ns'] >= metrics['next_event_ns'] >= metrics['call_ns'] and
            metrics['settled_ns'] >= metrics['serialize_ns'] + metrics['io_ns'] + delay * 1_000_000):
        raise ValueError('Untitled measurement violates phase/delay ordering')
    return metrics


def parse_metrics(transcript, size, delay, require_settled=False):
    def one(prefix, pattern):
        # 모호한 첫 결과를 고르지 않는다. 같은 표본의 중복/손상 로그도 실패다.
        lines = [line for line in transcript.splitlines() if line.startswith(prefix)]
        if len(lines) != 1 or (match := re.fullmatch(pattern, lines[0])) is None:
            raise ValueError('Expected exactly one complete ' + prefix + ' record')
        return tuple(map(int, match.groups()))
    call, event = one('UNTITLED_SAVE_METRIC', r'UNTITLED_SAVE_METRIC call_ns=(\d+) next_event_ns=(\d+) passed=true')
    serialize, = one('UNTITLED_SERIALIZE', r'UNTITLED_SERIALIZE ns=(\d+)')
    io, = one('UNTITLED_IO', r'UNTITLED_IO ns=(\d+)')
    has_settled = require_settled or 'UNTITLED_SETTLED' in transcript
    settled = one('UNTITLED_SETTLED', r'UNTITLED_SETTLED ns=(\d+)')[0] if has_settled else call
    metrics = dict(bytes=size, injected_delay_ms=delay, call_ns=call,
                                 next_event_ns=event, serialize_ns=serialize, io_ns=io, settled_ns=settled)
    if not has_settled:
        # 과거 동기 표본은 호출 반환 시 완료됐다. 원래 하한을 유지한 뒤 관측 시각을 next로 둔다.
        validate_metrics(dict(metrics, next_event_ns=call), size, delay)
        metrics['settled_ns'] = event
    return validate_metrics(metrics, size, delay)


def validate_report(report, size, delay, previous=None):
    if report.get('product_passed') is not True:
        raise ValueError('Product did not pass')
    metrics = validate_metrics(report['untitled_save_benchmark'], size, delay)
    # 서로 다른 앱/주입 소스/실행기로 얻은 표본을 같은 집계에 섞지 않는다.
    keys = ('binary_sha256', 'untitled_prepared_source_sha256', 'harness_sha256', 'runner_sha256', 'untitled_oracle_sha256', 'optimize')
    if any(not report.get(key) for key in keys):
        raise ValueError('Missing untitled sample provenance')
    provenance = {key: report[key] for key in keys}
    if previous is not None and provenance != previous:
        raise ValueError('Untitled sample provenance changed during measurement')
    return metrics, provenance


def parse_build_mode(transcript):
    lines = [line for line in transcript.splitlines() if line.startswith('UNTITLED_BUILD')]
    if len(lines) != 1 or re.fullmatch(r'UNTITLED_BUILD mode=(debug|release_fast)', lines[0]) is None:
        raise ValueError('Missing or ambiguous actual untitled build mode')
    return {'debug': 'Debug', 'release_fast': 'ReleaseFast'}[lines[0].split('=', 1)[1]]
