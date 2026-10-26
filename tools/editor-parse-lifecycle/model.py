"""설계 반례를 실행하는 단일 문서 모델. 제품 큐·스레드·allocator 구현이 아니다."""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Key:
    owner: int
    slot: int
    generation: int
    revision: int
    grammar: int
    serial: int


@dataclass
class Job:
    key: Key
    phase: str = 'queued'
    cancelled: bool = False
    has_tree: bool = False
    views: set = field(default_factory=set)
    snapshot_returns: int = 0
    tree_returns: int = 0


class Model:
    def __init__(self, fault=None):
        self.desired = None
        self.queued = None
        self.running = None
        self.installed = None
        self.jobs = {}
        self.fault = fault

    def _return_snapshot(self, job):
        assert job.snapshot_returns == 0
        job.snapshot_returns = 1

    def _retire_installed(self):
        if self.installed is not None:
            self.jobs[self.installed].phase = 'retiring'
            self.installed = None

    def input(self, key, prepared=True):
        # 본문 판은 작업 할당 성공 여부와 별개다.
        if prepared or self.fault != 'failed_prepare_keeps_old':
            self.desired = key
            self._retire_installed()
        if self.queued is not None:
            old = self.jobs[self.queued]
            self._return_snapshot(old)
            old.phase = 'reclaimed'
            self.queued = None
        if self.running is not None:
            self.jobs[self.running].cancelled = True
        if not prepared:
            return None
        assert key.serial not in self.jobs, '이 모델은 요청 번호 재사용을 허용하지 않는다'
        self.jobs[key.serial] = Job(key)
        self.queued = key.serial
        return key.serial

    def start(self):
        assert self.running is None and self.queued is not None
        self.running, self.queued = self.queued, None
        self.jobs[self.running].phase = 'running'
        return self.running

    def finish(self, success=True):
        assert self.running is not None
        job = self.jobs[self.running]
        assert job.phase == 'running'
        job.has_tree = success
        job.phase = 'completed'
        self.running = None

    def _matches(self, key):
        if self.desired is None:
            return False
        ignored = self.fault if self.fault in Key.__dataclass_fields__ else None
        return all(name == ignored or getattr(key, name) == getattr(self.desired, name)
                   for name in Key.__dataclass_fields__)

    def deliver(self, serial, views=()):
        job = self.jobs[serial]
        assert job.phase == 'completed'
        self._return_snapshot(job)
        if job.has_tree and not job.cancelled and self._matches(job.key):
            self._retire_installed()
            job.phase = 'installed'
            job.views = set(views)
            self.installed = serial
            return True
        job.phase = 'retiring' if job.has_tree else 'reclaimed'
        return False

    def return_view(self, serial, view):
        job = self.jobs[serial]
        assert view in job.views
        job.views.remove(view)

    def retire(self, serial):
        job = self.jobs[serial]
        assert job.phase == 'retiring'
        if job.views and self.fault != 'free_with_reader':
            return False
        assert job.tree_returns == 0
        job.tree_returns = 1
        job.phase = 'reclaimed'
        return True

    def close(self):
        self.desired = None
        self._retire_installed()
        # 전체 문서 닫기를 모델링한다. 단일 뷰 닫기는 return_view다.
        for job in self.jobs.values():
            job.views.clear()
        if self.queued is not None:
            job = self.jobs[self.queued]
            self._return_snapshot(job)
            job.phase = 'reclaimed'
            self.queued = None
        if self.running is not None:
            job = self.jobs[self.running]
            job.cancelled = True
            if self.fault == 'free_running':
                self._return_snapshot(job)

    def check(self):
        for job in self.jobs.values():
            assert job.snapshot_returns in (0, 1)
            assert job.tree_returns in (0, 1)
            if job.phase in ('running', 'completed', 'queued'):
                assert job.snapshot_returns == 0
            if job.phase in ('installed', 'retiring', 'reclaimed'):
                assert job.snapshot_returns == 1
            if job.tree_returns:
                assert job.has_tree and not job.views and job.phase == 'reclaimed'
        if self.installed is not None:
            job = self.jobs[self.installed]
            assert job.phase == 'installed' and job.key == self.desired

    def drain(self):
        self.close()
        if self.running is not None:
            self.finish()
        for serial, job in self.jobs.items():
            if job.phase == 'completed':
                self.deliver(serial)
            if job.phase == 'retiring':
                assert self.retire(serial)
        self.check()
        assert all(j.phase == 'reclaimed' and j.snapshot_returns == 1 and
                   j.tree_returns == int(j.has_tree) for j in self.jobs.values())
