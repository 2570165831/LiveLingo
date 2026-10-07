"""Optional numeric model-call timings, using only the standard library.

The caller exclusively creates an empty, owned regular file, then supplies its
absolute path in LIVELINGO_SCOREBOARD_TIMINGS. This module never creates files.
Wall time includes tensor operations, IO and preprocessing within each measured
call; it is not GPU hardware busy time. CPU time is process-wide. Generation
initialization, cold restoration and individual steps share their fixed purpose's
stage bucket. completed means the measured call returned normally.
text_step is a mixed bucket for text/default/unknown purposes, including current
translation callers. Only explicit purpose="translation" gets translation_step;
neither prompts nor replay context are used to infer a request's purpose.
"""
from contextlib import contextmanager
import json
import os
import stat
from time import monotonic, process_time


TIMINGS_ENV = "LIVELINGO_SCOREBOARD_TIMINGS"
STAGES = frozenset({
    "asr_load", "asr_inference", "language_load", "translation_step",
    "notes_step", "review_step", "text_step",
})
_PURPOSE_STAGES = {
    "translation": "translation_step", "note": "notes_step",
    "review": "review_step", "text": "text_step",
}


def generation_stage(purpose):
    """Never turn an arbitrary purpose, prompt or request ID into a log label."""
    return _PURPOSE_STAGES.get(purpose, "text_step") if type(purpose) is str else "text_step"


def _append(path, sample):
    """Append once, without following a leaf symlink or creating/truncating."""
    if not os.path.isabs(path) or not hasattr(os, "O_NOFOLLOW"):
        return
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
        return
    flags = os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
    flags |= getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
            return
        # One small write keeps records together across the ASR/worker processes.
        payload = (json.dumps(sample, allow_nan=False, separators=(",", ":")) + "\n").encode("ascii")
        os.write(descriptor, payload)
    finally:
        os.close(descriptor)


@contextmanager
def measure(stage):
    """Record success or failure, preserving results and original exceptions.

    No environment setting means no clock reads or file operations. All timer
    and append failures are silent; exception details are never serialized.
    """
    try:
        path = os.environ.get(TIMINGS_ENV)
        enabled = bool(path) and type(stage) is str and stage in STAGES
        if enabled:
            start_mono, start_cpu = monotonic(), process_time()
    except Exception:
        enabled = False
    if not enabled:
        yield
        return
    completed = False
    try:
        yield
        completed = True
    finally:
        try:
            end_mono, end_cpu = monotonic(), process_time()
            _append(path, {
                "stage": stage,
                "wall_seconds": end_mono - start_mono,
                "process_cpu_seconds": end_cpu - start_cpu,
                "start_mono": start_mono,
                "end_mono": end_mono,
                "completed": completed,
            })
        except Exception:
            pass
