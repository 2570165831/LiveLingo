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

protocol = sys.stdout
sys.stdout = sys.stderr

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
    engine = None
    active = OrderedDict()
    paused = OrderedDict()
    completed = {}
    identities = {}
    last_checkpoint = {}
    last_emit = {}
    checkpointed = set()
    send('ready', version=1)

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
        nonlocal engine
        op, request_id = command.get('op'), command.get('id')
        if op in ('shutdown','reader_error'):
            for identity, generation in active.items():
                if identity not in checkpointed: continue
                try: persist(generation)
                except Exception as error: print('Checkpoint failure:',error,file=sys.stderr)
            return False
        if op in ('ack','cancel'):
            generation = active.pop(request_id, None)
            identity = identities.pop(request_id, None)
            if identity is not None:
                paused.pop(identity, None)
                completed.pop(request_id, None)
                (state_directory/(identity+'.safetensors')).unlink(missing_ok=True)
            checkpointed.discard(request_id)
            last_checkpoint.pop(request_id,None);last_emit.pop(request_id,None)
            send(op, request_id)
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
                send('paused' if op=='pause' else op, request_id)
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
        if engine is None:
            send('loading',request_id)
            engine = Engine(args.model)
        purpose = command.get('purpose','text')
        schema = None
        if purpose in ('note','review'):
            data=json.loads(command['input'])
            schema=note_schema(data) if purpose=='note' else review_schema(data)
            if purpose=='review':
                from checks import review_checks
                data['calculationChecks']=review_checks(data)
                original=command['input']
                marker='<|im_start|>user\n'+original+'<|im_end|>'
                if marker not in prompt: raise ValueError('Review input does not match prompt')
                prompt=prompt.replace(marker,'<|im_start|>user\n'+json.dumps(data,ensure_ascii=False,sort_keys=True)+'<|im_end|>',1)
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
        if purpose in ('note','review'): checkpointed.add(request_id)
        last_checkpoint[request_id]=time.monotonic()
        last_emit[request_id]=0.0
        send('snapshot',request_id,wire=generation.wire,recovered=recovered is generation)
        return True

    try:
        keep_running=True
        while keep_running:
            command=commands.get() if not active else None
            while command is not None:
                try: keep_running=handle(command)
                except Exception as error: send('error',command.get('id'),message=str(error),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
                if not keep_running: break
                try: command=commands.get_nowait()
                except queue.Empty: command=None
            if not keep_running: break
            if not active: continue
            request_id,generation=active.popitem(last=False)
            try:
                state=generation.step()
                now=time.monotonic()
                if state=='done':
                    # Keep a completed checkpoint until the app acknowledges a
                    # committed result; a lost pipe must not discard the batch.
                    if request_id in checkpointed: persist(generation)
                    completed[request_id]=generation.identity
                    send('done',request_id,wire=generation.wire,text=generation.text,
                         thinkingTokens=generation.thinking_count,finalTokens=generation.final_count)
                else:
                    if now-last_emit.get(request_id,0)>=0.1:
                        send('snapshot',request_id,wire=generation.wire)
                        last_emit[request_id]=now
                    # Text journals remain frequent; heavy tensor checkpoints
                    # are bounded to avoid continuously writing large caches.
                    if request_id in checkpointed and now-last_checkpoint.get(request_id,now)>=30:
                        persist(generation); last_checkpoint[request_id]=now
                    active[request_id]=generation
            except Exception as error:
                send('error',request_id,message=str(error),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
            finally:
                if request_id not in active:
                    last_checkpoint.pop(request_id,None);last_emit.pop(request_id,None)
                    checkpointed.discard(request_id)
            # Drain commands at every token/prefill boundary. Round-robin steps
            # allow new captions and existing notes to both make progress.
            while True:
                try: command=commands.get_nowait()
                except queue.Empty: break
                try: keep_running=handle(command)
                except Exception as error: send('error',command.get('id'),message=str(error),recoverable=not isinstance(error,(ValueError,KeyError,TypeError)))
                if not keep_running: break
    except BrokenPipeError:
        pass
    finally:
        stopping.set()
        reader.join(timeout=1)

if __name__=='__main__': main()
