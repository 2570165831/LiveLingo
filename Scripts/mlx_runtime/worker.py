"""App-owned JSONL worker. stdout is protocol-only; no network listener."""
import os
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', PYTHONDONTWRITEBYTECODE='1', TOKENIZERS_PARALLELISM='false')
import argparse
from collections import OrderedDict
import contextlib
import json
from pathlib import Path
import queue
import re
import select
import sys
sys.dont_write_bytecode = True
import threading
import time

from review_diagnostics import (bind_review_prompt, failure_line, generation_detail,
                                parse_review_input, stage_error)

protocol = sys.stdout
sys.stdout = sys.stderr

MEBIBYTE = 1024*1024

# Ceiling for MLX's allocator cache: buffers MLX already freed and keeps for
# reuse. MLX reclaims excess free buffers on subsequent allocations.
# This policy does not impose a limit on live model or task tensors.
# `mx.set_memory_limit` is deliberately never called - that limit applies to
# live graph memory and would turn a valid 9B request into an allocation error.
# 2 GiB is an initial conservative reuse budget, not a measured optimum.
# Validate throughput on a real recording before changing the shipped default.
DEFAULT_CACHE_LIMIT_MB = 2048
DEFAULT_MEMORY_LOG_SECONDS = 15.0
DEFAULT_IDLE_RELEASE_SECONDS = 30.0
DEFAULT_IDLE_MODEL_SECONDS = 120.0
IDLE_TICK_SECONDS = 5.0


def environment_number(name, cast, default):
    raw = os.environ.get(name)
    if raw is None or raw == '': return default
    try: return cast(raw)
    except (TypeError, ValueError):
        print(f'Ignoring invalid {name}={raw!r}', file=sys.stderr)
        return default


def discover_mlx():
    """Import the allocator API only. Loading weights is Engine's job."""
    try: import mlx.core as mx
    except Exception: return None
    return mx


class MlxMemory:
    """Bounded MLX allocator cache with throttled active/cache/peak reporting.

    Only `mx.set_cache_limit` (free-buffer cache) and `mx.clear_cache` (return
    already-freed buffers to the system) are used. An unavailable backend or a
    missing function degrades to one explanatory stderr line, never an error.
    """

    def __init__(self, backend=None, cache_limit_mb=DEFAULT_CACHE_LIMIT_MB,
                 log_seconds=DEFAULT_MEMORY_LOG_SECONDS,
                 idle_seconds=DEFAULT_IDLE_RELEASE_SECONDS,
                 clock=time.monotonic, write=None, report=None):
        self.backend = backend
        self.cache_limit_bytes = None if cache_limit_mb is None else max(0,int(cache_limit_mb))*MEBIBYTE
        self.log_seconds = max(0.0,float(log_seconds))
        self.idle_seconds = max(0.0,float(idle_seconds))
        # Bounded waits let an idle worker reclaim cache without delaying a
        # requested release noticeably.
        self.idle_tick_seconds = IDLE_TICK_SECONDS
        if 0 < self.idle_seconds < IDLE_TICK_SECONDS:
            self.idle_tick_seconds = max(0.05,self.idle_seconds)
        self._clock = clock
        self._write = write or (lambda line: print(line, file=sys.stderr))
        self._report = report
        self._last_log = None
        self._last_activity = self._clock()
        self._released = True

    @staticmethod
    def _mib(value):
        return 'n/a' if value is None else f'{int(value)//MEBIBYTE}MiB'

    def sample(self):
        if self.backend is None: return None
        values = {}
        for key, name in (('active','get_active_memory'),('cache','get_cache_memory'),('peak','get_peak_memory')):
            reader = getattr(self.backend, name, None)
            try: values[key] = None if reader is None else int(reader())
            except Exception: values[key] = None
        return None if all(value is None for value in values.values()) else values

    def log_event(self, reason, force=False, **fields):
        """Report one sample. Steady state is throttled; transitions pass force."""
        now = self._clock()
        self._last_activity = now
        self._released = False
        if not force and self._last_log is not None and now-self._last_log < self.log_seconds:
            return None
        self._last_log = now
        values = self.sample()
        if values is None:
            line = f'[memory] {reason} mlx-memory-unavailable'
        else:
            line = (f'[memory] {reason} active={self._mib(values["active"])}'
                    f' cache={self._mib(values["cache"])} peak={self._mib(values["peak"])}')
        if self.cache_limit_bytes is not None: line += f' limit={self._mib(self.cache_limit_bytes)}'
        for name, value in fields.items(): line += f' {name}={value}'
        self._write(line)
        if self._report is not None and values is not None:
            self._report(values, self.cache_limit_bytes)
        return values

    def apply_limit(self):
        """Bound the allocator cache before the first model load."""
        if self.backend is None:
            self._write('[memory] cache-limit unavailable: mlx is not importable')
            return False
        setter = getattr(self.backend, 'set_cache_limit', None)
        if setter is None or self.cache_limit_bytes is None:
            self._write('[memory] cache-limit unavailable: mx.set_cache_limit is missing')
            return False
        try: previous = int(setter(self.cache_limit_bytes))
        except Exception as error:
            self._write(f'[memory] cache-limit failed error={error}')
            return False
        self.log_event('cache-limit', force=True, previous=self._mib(previous))
        return True

    def release(self, reason):
        """Return already-freed allocator buffers to the system."""
        values = self.sample()
        cache = None if values is None else values.get('cache')
        clear = None if self.backend is None else getattr(self.backend, 'clear_cache', None)
        cleared = False
        if clear is not None and cache != 0:
            try: clear(); cleared = True
            except Exception as error:
                self._write(f'[memory] cache-release failed reason={reason} error={error}')
        self.log_event(reason, force=True, cleared='yes' if cleared else 'no')
        self._released = clear is None or cleared or cache == 0
        return cleared

    def idle(self):
        """Reclaim cache once per quiet period; never on the token path."""
        if self._released or self.idle_seconds <= 0: return False
        if self._clock()-self._last_activity < self.idle_seconds: return False
        return self.release('idle-release')


def send(kind, request_id=None, **fields):
    event = dict(event=kind, **fields)
    if request_id is not None:
        event['id'] = request_id
    protocol.write(json.dumps(event, ensure_ascii=False) + '\n')
    protocol.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--state-directory', required=True)
    parser.add_argument('--cache-limit-mb', type=int,
                        default=environment_number('LIVELINGO_MLX_CACHE_LIMIT_MB', int, DEFAULT_CACHE_LIMIT_MB),
                        help='Ceiling for the MLX free-buffer cache in MiB; 0 disables the cache.')
    parser.add_argument('--memory-log-seconds', type=float,
                        default=environment_number('LIVELINGO_MLX_MEMORY_LOG_SECONDS', float, DEFAULT_MEMORY_LOG_SECONDS),
                        help='Minimum interval between steady-state memory log lines; 0 logs every event.')
    parser.add_argument('--idle-cache-release-seconds', type=float,
                        default=environment_number('LIVELINGO_MLX_IDLE_CACHE_RELEASE_SECONDS', float, DEFAULT_IDLE_RELEASE_SECONDS),
                        help='Quiet period before an idle worker returns unused allocator buffers; 0 disables it.')
    parser.add_argument('--idle-model-seconds', type=float,
                        default=DEFAULT_IDLE_MODEL_SECONDS,
                        help='Quiet period before unloading idle weights; paused progress stays on disk.')
    args = parser.parse_args()
    state_directory = Path(args.state_directory)
    state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    commands = queue.Queue()
    stopping = threading.Event()

    def read():
        try:
            pending = b''
            while not stopping.is_set():
                if not select.select([sys.stdin.fileno()], [], [], 0.2)[0]:
                    continue
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    commands.put({'op':'shutdown'}); return
                pending += chunk
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if len(line) > 2_097_152: raise ValueError('Oversized protocol request')
                    command = json.loads(line)
                    if not isinstance(command, dict): raise ValueError('Expected request object')
                    commands.put(command)
                if len(pending) > 2_097_152:
                    raise ValueError('Oversized protocol request')
        except Exception as error:
            commands.put({'op':'reader_error','message':str(error)})
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    from engine import Engine, Generation
    from schemas import note_schema, review_schema
    # The cache ceiling is in place before Engine() loads the first weight.
    memory = MlxMemory(discover_mlx(), cache_limit_mb=args.cache_limit_mb,
                       log_seconds=args.memory_log_seconds, idle_seconds=args.idle_cache_release_seconds,
                       report=lambda values, limit: send('memory', activeBytes=values['active'],
                           cacheBytes=values['cache'], peakBytes=values['peak'], cacheLimitBytes=limit))
    engine = None
    active = OrderedDict()
    paused = OrderedDict()
    completed = {}
    identities = {}
    purposes = {}
    last_checkpoint = {}
    last_emit = {}
    checkpointed = set()
    last_model_use = time.monotonic()
    send('ready', version=2)
    memory.apply_limit()

    def describe_request_error(request_id, error):
        """Tag a review request failure with stage/code so the app can explain it."""
        message = str(error)
        if purposes.get(request_id) == 'review' and 'review failure ' not in message:
            return failure_line('generation', 'generation_failed', generation_detail(error),
                                request=request_id or 'unknown', error_type=type(error).__name__)
        return message

    def persist(generation):
        generation.save(state_directory/(generation.identity+'.safetensors'))
        # Tensor caches are replaceable accelerators; the app owns the durable
        # text journal. Bound cold caches so paused jobs cannot fill the disk.
        protected={generation.identity, *[g.identity for g in active.values()], *paused.keys()}
        files=[p for p in state_directory.iterdir() if not p.is_symlink() and p.is_file()
               and re.fullmatch(r'[0-9a-f]{64}\.safetensors',p.name)]
        total=sum(p.stat().st_size for p in files)
        for path in sorted(files,key=lambda p:p.stat().st_mtime):
            if total <= 4*1024**3: break
            if path.stem not in protected:
                size=path.stat().st_size
                path.unlink();total-=size

    def checkpoint_path(generation):
        return state_directory/(generation.identity+'.safetensors')

    def handle(command):
        nonlocal engine, last_model_use
        op, request_id = command.get('op'), command.get('id')
        control = {'controlID': command.get('controlID')}
        if op in ('shutdown','reader_error'):
            failures = []
            for identity, generation in active.items():
                if identity not in checkpointed: continue
                try: persist(generation)
                except Exception as error:
                    failures.append(identity)
                    print('Checkpoint failure:', type(error).__name__, file=sys.stderr)
            send('shutdown', request_id, state='checkpoint_failed' if failures else 'ready_to_exit',
                 failedRequests=failures, **control)
            return False
        if op in ('ack','cancel'):
            generation = active.pop(request_id, None)
            identity = identities.pop(request_id, None)
            purposes.pop(request_id, None)
            if identity is not None:
                paused.pop(identity, None)
                completed.pop(request_id, None)
                (state_directory/(identity+'.safetensors')).unlink(missing_ok=True)
            checkpointed.discard(request_id)
            last_checkpoint.pop(request_id,None);last_emit.pop(request_id,None)
            generation = None
            if not active:
                memory.release('cancel' if op=='cancel' else 'ack')
            send(op, request_id, state='released', **control)
            return True
        if op in ('pause','checkpoint'):
            generation = active.get(request_id)
            if generation is not None:
                if op != 'cancel': persist(generation)
                if op != 'checkpoint':
                    active.pop(request_id, None)
                    checkpointed.discard(request_id)
                    last_checkpoint.pop(request_id,None);last_emit.pop(request_id,None)
                    if op == 'pause':
                        paused[generation.identity] = generation
                        # Keep only the most recent paused task hot. Older tasks
                        # remain recoverable from their atomic checkpoint.
                        while len(paused)>1: paused.popitem(last=False)
                        # A paused task keeps its own tensors; only unused
                        # buffers are returned here.
                        memory.log_event('pause')
                send('paused' if op=='pause' else op, request_id, state='saved', **control)
            else:
                # Generation may finish at the token boundary immediately before
                # a pause reaches us. Acknowledge the stopped computation while
                # preserving the completed checkpoint until delivery is acked.
                identity = identities.get(request_id)
                state = ('completed' if request_id in completed else
                         'saved' if identity in paused else 'absent')
                send('paused' if op=='pause' else op, request_id, state=state, **control)
            return True
        if op != 'generate': raise ValueError('Unknown operation')
        if not isinstance(request_id,str) or not request_id or request_id in active:
            raise ValueError('Invalid or duplicate request ID')
        if len(active) >= 4:
            raise ValueError('Local inference queue is full')
        prompt = command['prompt']
        prefix = command.get('prefix','')
        if not isinstance(prompt,str) or not isinstance(prefix,str) or len((prompt+prefix).encode())>1_048_576:
            raise ValueError('Invalid input')
        purpose = command.get('purpose','text')
        schema = None
        # Check the request before any weight is loaded: a legacy or malformed
        # review input must fail with its structured compatibility error
        # instead of costing a model load first.
        if purpose in ('note','review'):
            raw_input = command.get('input')
            if purpose == 'review':
                data = parse_review_input(raw_input)
            else:
                data = json.loads(raw_input)
            try:
                schema=note_schema(data) if purpose=='note' else review_schema(data)
            except Exception as error:
                if purpose == 'review':
                    raise stage_error('schema', 'schema_build_failed', generation_detail(error)) from None
                raise
        if engine is None:
            send('loading',request_id)
            engine = Engine(args.model)
            send('model_state', loaded=True)
            memory.log_event('model-loaded', force=True)
        last_model_use = time.monotonic()
        if purpose == 'review':
            from checks import review_checks
            data['calculationChecks']=review_checks(data)
            prompt = bind_review_prompt(raw_input, prompt, data)
        thinking_budget=int(command.get('thinkingBudget',16384))
        final_budget=int(command.get('finalBudget',4096))
        if not 1<=thinking_budget<=16384 or not 1<=final_budget<=4096:
            raise ValueError('Invalid token budget')
        generation=Generation(engine,prompt,schema,thinking=bool(command.get('thinking',False)),prefix=prefix,
                              thinking_budget=thinking_budget,final_budget=final_budget)
        if any(item.identity == generation.identity for item in active.values()):
            raise ValueError('Identical generation already active')
        for old_id, identity in list(identities.items()):
            if identity == generation.identity and old_id not in active:
                identities.pop(old_id, None)
                completed.pop(old_id, None)
        hot=paused.pop(generation.identity,None)
        recovered=hot if prefix else None
        path=checkpoint_path(generation)
        if prefix and recovered is None and path.exists():
            try: recovered=Generation.restore(engine,path,generation.identity)
            except Exception as error: send('checkpoint_rejected',request_id,message=str(error))
        if recovered is not None:
            # A stale UI journal may lag the token checkpoint, or vice versa.
            # Only reuse a checkpoint belonging to the same unfinished prefix.
            if recovered.wire.startswith(prefix) or prefix.startswith(recovered.wire):
                generation=recovered
        active[request_id]=generation
        identities[request_id]=generation.identity
        purposes[request_id]=purpose
        if purpose in ('note','review'): checkpointed.add(request_id)
        last_checkpoint[request_id]=time.monotonic()
        last_emit[request_id]=0.0
        send('snapshot',request_id,wire=generation.wire,recovered=recovered is generation)
        return True

    try:
        keep_running=True
        while keep_running:
            # Bounded wait: an idle worker still ticks so unused allocator
            # buffers can be returned after the quiet period.
            try: command=commands.get(timeout=memory.idle_tick_seconds) if not active else None
            except queue.Empty: command=None
            while command is not None:
                try: keep_running=handle(command)
                except Exception as error: send('error',command.get('id'),message=str(error),controlID=command.get('controlID'),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
                if not keep_running: break
                try: command=commands.get_nowait()
                except queue.Empty: command=None
            if not keep_running: break
            if not active:
                memory.idle()
                if (engine is not None and args.idle_model_seconds > 0
                        and time.monotonic()-last_model_use >= args.idle_model_seconds):
                    # Every hot paused generation has an atomic checkpoint.
                    # Dropping these tensors releases weights without deleting
                    # any completed batch or resumable progress.
                    paused.clear()
                    engine = None
                    import gc
                    gc.collect()
                    memory.release('model-unloaded')
                    send('model_state', loaded=False)
                continue
            request_id,generation=active.popitem(last=False)
            finished=None
            try:
                state=generation.step()
                now=time.monotonic()
                last_model_use = now
                if state=='done':
                    # Keep a completed checkpoint until the app acknowledges a
                    # committed result; a lost pipe must not discard the batch.
                    if request_id in checkpointed: persist(generation)
                    completed[request_id]=generation.identity
                    send('done',request_id,wire=generation.wire,text=generation.text,
                         thinkingTokens=generation.thinking_count,finalTokens=generation.final_count)
                    finished='done'
                else:
                    if now-last_emit.get(request_id,0)>=0.1:
                        send('snapshot',request_id,wire=generation.wire)
                        last_emit[request_id]=now
                    # Text journals remain frequent; heavy tensor checkpoints
                    # are bounded to avoid continuously writing large caches.
                    if request_id in checkpointed and now-last_checkpoint.get(request_id,now)>=30:
                        persist(generation); last_checkpoint[request_id]=now
                    active[request_id]=generation
                    # Throttled sample: never a cache clear on the token path.
                    memory.log_event('generating')
            except Exception as error:
                finished='error'
                send('error',request_id,message=describe_request_error(request_id,error),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
            finally:
                if request_id not in active:
                    last_checkpoint.pop(request_id,None);last_emit.pop(request_id,None)
                    checkpointed.discard(request_id)
                    purposes.pop(request_id,None)
                # Drop this iteration's reference (and with it the KV cache)
                # before blocking on the command queue; a finished task must not
                # stay live through the loop variable.
                generation=None
            if finished is not None and not active:
                # Nothing references the finished generation any more, so this
                # returns its buffers instead of keeping them for reuse.
                memory.release(finished)
            # Drain commands at every token/prefill boundary. Round-robin steps
            # allow new captions and existing notes to both make progress.
            while True:
                try: command=commands.get_nowait()
                except queue.Empty: break
                try: keep_running=handle(command)
                except Exception as error: send('error',command.get('id'),message=str(error),controlID=command.get('controlID'),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
                if not keep_running: break
    except BrokenPipeError:
        pass
    finally:
        stopping.set()
        reader.join(timeout=1)

if __name__=='__main__': main()
