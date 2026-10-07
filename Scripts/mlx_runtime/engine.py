"""Isolated candidate: explicit token boundaries, per-request RNG and grammar state."""
import hashlib
import copy
import json
import os
import secrets
from collections import OrderedDict
from importlib.metadata import version
from pathlib import Path
import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache, save_prompt_cache, load_prompt_cache
from mlx_lm.sample_utils import apply_top_k, apply_top_p
from outlines_core import Guide, Index
from safetensors import safe_open
from schemas import build_generation_regex
from grammar_vocabulary import build_vocabulary
from review_diagnostics import grammar_error
from outlines_core.kernels.mlx import allocate_token_bitmask, fill_next_token_bitmask, apply_token_bitmask

PREFILL_STEP = 256


class OutputBudgetExceeded(ValueError):
    code = 'output_budget_exhausted'


class PromptPrefixCache:
    """At most two exact prefill snapshots under one model's total byte limit.

    Recurrent state cannot be trimmed to another prefix. Requests receive deep
    copies of an exact stored boundary; ordinary decoding never mutates a stored
    snapshot. Least recently used entries make room without growing the budget.
    """
    def __init__(self, max_tokens=512, max_bytes=128 * 1024**2, max_entries=2):
        self.max_tokens = max(0, max_tokens // PREFILL_STEP * PREFILL_STEP)
        self.max_bytes = max(0, max_bytes)
        self.max_entries = max(0, max_entries)
        self._entries = OrderedDict()
        self._low_priority = set()
        self.nbytes = 0

    @property
    def tokens(self):
        return next(reversed(self._entries), ())

    def fetch(self, tokens, *, low_priority=False):
        # Prefer the longest exact boundary; leave a token for the first logits.
        for key in sorted(self._entries, key=len, reverse=True):
            count = len(key)
            if len(tokens) > count and tuple(tokens[:count]) == key:
                snapshot = copy.deepcopy(self._entries[key][0])
                if not low_priority:
                    self._low_priority.discard(key)
                    self._entries.move_to_end(key)
                elif key in self._low_priority:
                    self._entries.move_to_end(key)
                return snapshot, count
        return None, 0

    def remember(self, tokens, cache, *, low_priority=False):
        tokens = tuple(tokens)
        if (not tokens or len(tokens) % PREFILL_STEP or len(tokens) > self.max_tokens
                or not self.max_entries):
            return False
        size = sum(item.nbytes for item in cache)
        if size > self.max_bytes:
            return False
        if tokens in self._entries:
            if not low_priority:
                self._low_priority.discard(tokens)
                self._entries.move_to_end(tokens)
            elif tokens in self._low_priority:
                self._entries.move_to_end(tokens)
            return True
        # Notes use spare capacity. They may replace another note snapshot,
        # but cannot evict translation/ordinary-summary state or reorder it.
        if low_priority:
            preferred = [(key, value) for key, value in self._entries.items()
                         if key not in self._low_priority]
            if (len(preferred) >= self.max_entries
                    or sum(value[1] for _, value in preferred) + size > self.max_bytes):
                return False
        # Release old references before allocating a new snapshot. The limit
        # covers retained snapshots, not the active request or model weights.
        while self._entries and (len(self._entries) >= self.max_entries
                                 or self.nbytes + size > self.max_bytes):
            victim = next((key for key in self._entries if key in self._low_priority),
                          next(iter(self._entries)))
            _, removed_bytes = self._entries.pop(victim)
            self._low_priority.discard(victim)
            self.nbytes -= removed_bytes
        self._entries[tokens] = (copy.deepcopy(cache), size)
        if low_priority:
            self._low_priority.add(tokens)
        self.nbytes += size
        return True

def prefix_cache_for_model(model_path):
    """Use the measured longer boundary only for the tested 9B configuration.

    A 768-token translation snapshot and a 256-token low-priority notes
    snapshot need about 130 MiB together. Two 768-token translation variants
    need 146.25 MiB: 148 MiB admits that pair without evicting one on every
    prompt switch. The two-entry bound and note admission priority still apply.
    Other models retain the original 512-token / 128 MiB policy.
    """
    try:
        config = json.loads((Path(model_path) / 'config.json').read_text())
        text = config.get('text_config', {})
        quantization = config.get('quantization', {})
        tested_9b = (
            config.get('model_type') == 'qwen3_5'
            and text.get('hidden_size') == 4096
            and text.get('num_hidden_layers') == 32
            and text.get('head_dim') == 256
            and text.get('num_key_value_heads') == 4
            and text.get('linear_num_value_heads') == 32
            and quantization.get('bits') == 4
            and quantization.get('group_size') == 64
        )
    except (OSError, ValueError, AttributeError):
        tested_9b = False
    return (PromptPrefixCache(max_tokens=768, max_bytes=148 * 1024**2)
            if tested_9b else PromptPrefixCache())


class Engine:
    def __init__(self, model_path):
        self.model_path = str(Path(model_path).resolve())
        self.model, self.tokenizer = load(self.model_path)
        self.prefix_cache = prefix_cache_for_model(self.model_path)
        self.vocabulary = build_vocabulary(self.tokenizer)
        self.indices = OrderedDict()
        self.end_think = self.tokenizer.encode('</think>', add_special_tokens=False)
        if len(self.end_think) != 1:
            raise ValueError('Thinking delimiter must be one token for this adapter')
        identity = [('runtime', [(name, version(name)) for name in
                    ('mlx', 'mlx-lm', 'outlines', 'outlines_core', 'transformers')])]
        for name in ('engine.py', 'schemas.py', 'checks.py', 'worker.py', 'grammar_vocabulary.py', 'review_diagnostics.py', 'latin_numbers.py'):
            source = Path(__file__).with_name(name)
            if source.is_file():
                identity.append((name, hashlib.sha256(source.read_bytes()).hexdigest()))
        for p in sorted(Path(self.model_path).iterdir()):
            if p.suffix in ('.json', '.jinja'):
                identity.append((p.name, hashlib.sha256(p.read_bytes()).hexdigest()))
            elif p.suffix == '.safetensors':
                s = p.stat(); identity.append((p.name, s.st_size, s.st_mtime_ns))
        self.identity = hashlib.sha256(json.dumps(identity).encode()).hexdigest()

    def index(self, schema):
        # Preserve the schema's deliberate field order: establish the topic
        # before asking for the no-new-knowledge decision.
        key = json.dumps(schema, ensure_ascii=False)
        if key not in self.indices:
            try:
                self.indices[key] = Index(build_generation_regex(schema), self.vocabulary)
            except Exception as error:
                raise grammar_error(error) from None
        self.indices.move_to_end(key)
        while len(self.indices) > 8:
            self.indices.popitem(last=False)
        return self.indices[key]

class Generation:
    VERSION = 2
    def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', seed=None,
                 thinking_budget=16384, final_budget=4096, _use_prefix_cache=True):
        self.engine = engine
        self.spec = dict(prompt=prompt, schema=schema, thinking=thinking,
                         thinking_budget=thinking_budget, final_budget=final_budget)
        self.identity = hashlib.sha256(json.dumps([self.VERSION,engine.identity,self.spec],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        seed = secrets.randbits(32) if seed is None else seed
        self.spec['seed'] = seed
        self.initial_prefix = prefix
        self.pending = engine.tokenizer.encode(prompt + prefix, add_special_tokens=False)
        self.input_tokens = len(self.pending)
        self.reused_prefix_tokens = 0
        self.prefill_tokens = 0
        # Reuse only exact input state, never output or a grammar's progress.
        # Schema work stores one smaller chunk with lower admission priority.
        # Restores and output-prefix continuations keep their checkpoint path.
        self._low_priority_prefix = schema is not None
        self._prefix_cache = (getattr(engine, 'prefix_cache', None)
                              if _use_prefix_cache and not thinking and not prefix else None)
        self._cache_tokens = ()
        self.cache = None
        if self._prefix_cache is not None:
            limit = min(PREFILL_STEP, self._prefix_cache.max_tokens) if schema is not None else self._prefix_cache.max_tokens
            count = min((len(self.pending) - 1) // PREFILL_STEP * PREFILL_STEP, limit)
            self._cache_tokens = tuple(self.pending[:max(0, count)])
            self.cache, self.reused_prefix_tokens = self._prefix_cache.fetch(
                self.pending, low_priority=self._low_priority_prefix)
            self.pending = self.pending[self.reused_prefix_tokens:]
        if self.cache is None:
            self.cache = make_prompt_cache(engine.model)
        self.ids = []
        self.final_ids = []
        self.key = mx.random.key(seed)
        self.phase = 'thinking' if thinking and '</think>' not in prefix else 'final'
        self.thinking_count = 0
        self.final_count = 0
        self.done = False
        self.detokenizer = engine.tokenizer.detokenizer
        self.detokenizer.reset()
        self.guide = Guide(engine.index(schema)) if schema else None
        self.mask = None
        if self.guide and self.phase == 'final':
            body = prefix.split('</think>',1)[-1] if thinking else prefix
            self.final_ids = engine.tokenizer.encode(body, add_special_tokens=False)
            for token in self.final_ids:
                self.guide.advance(token, return_tokens=False)

    @property
    def wire(self):
        return self.initial_prefix + self.detokenizer.text

    @property
    def text(self):
        return (self.wire.split('</think>',1)[-1] if self.spec['thinking'] else self.wire).strip()

    def step(self):
        if self.done:
            return 'done'
        if len(self.pending) > PREFILL_STEP:
            chunk, self.pending = self.pending[:PREFILL_STEP], self.pending[PREFILL_STEP:]
            self.engine.model(mx.array([chunk]), cache=self.cache)
            mx.eval([c.state for c in self.cache])
            self.prefill_tokens += len(chunk)
            if (self._cache_tokens and self.prefill_tokens + self.reused_prefix_tokens
                    == len(self._cache_tokens)):
                self._prefix_cache.remember(self._cache_tokens, self.cache,
                                            low_priority=self._low_priority_prefix)
            return 'prefill'
        logits = self.engine.model(mx.array([self.pending]), cache=self.cache)[:, -1, :]
        if self.phase == 'final' and self.guide:
            if self.mask is None:
                self.mask = allocate_token_bitmask(logits.shape[-1])
            fill_next_token_bitmask(self.guide, self.mask)
            logits = apply_token_bitmask(logits, self.mask)
        if self.phase == 'thinking':
            # Same bounded presence penalty as the tested MLX-LM configuration.
            if self.ids:
                positions = mx.array(sorted(set(self.ids[-20:])))
                logits[:, positions] -= 1.5
            keys = mx.random.split(self.key)
            self.key = keys[0]
            logprobs = logits - mx.logsumexp(logits, keepdims=True)
            token_array = mx.random.categorical(apply_top_k(apply_top_p(logprobs,.95),20), key=keys[1])
        else:
            token_array = mx.argmax(logits, axis=-1)
        mx.eval(token_array, self.key, [c.state for c in self.cache])
        token = int(token_array.item())
        self.pending = [token]
        self.ids.append(token)
        if token in self.engine.tokenizer.eos_token_ids:
            if self.phase != 'final' or (self.guide and not self.guide.is_finished()):
                raise ValueError('Generation stopped before a complete final response')
            self.done = True
            self.detokenizer.finalize()
            return 'done'
        self.detokenizer.add_token(token)
        if self.phase == 'thinking':
            self.thinking_count += 1
            if token == self.engine.end_think[0]:
                self.phase = 'final'
            elif self.thinking_count >= self.spec['thinking_budget']:
                closing = '\nI have finished checking. I will now return the final answer.\n</think>\n\n'
                injected = self.engine.tokenizer.encode(closing, add_special_tokens=False)
                self.pending += injected
                for t in injected:
                    self.ids.append(t); self.detokenizer.add_token(t)
                self.phase = 'final'
        else:
            self.final_count += 1
            self.final_ids.append(token)
            if self.guide:
                self.guide.advance(token, return_tokens=False)
            if self.final_count >= self.spec['final_budget']:
                raise OutputBudgetExceeded('Final output budget exhausted; incomplete output is not committable')
        return 'token'

    def save(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        metadata = dict(version=self.VERSION, identity=self.identity, spec=self.spec,
            prefix=self.initial_prefix, pending=self.pending, ids=self.ids, final_ids=self.final_ids,
            key=self.key.tolist(), phase=self.phase, thinking_count=self.thinking_count,
            final_count=self.final_count, done=self.done)
        temporary = path.with_name(path.stem+'.pending.safetensors')
        serialized = json.dumps(metadata, ensure_ascii=False)
        if self.done:
            # A completed request only replays its result while awaiting ACK.
            # Persist its exact tokens/RNG/spec atomically, without writing KV
            # tensors that will never be used for another model step.
            mx.save_safetensors(str(temporary), {}, {'livelingo.completed': serialized})
        else:
            save_prompt_cache(str(temporary), self.cache, {'generation': serialized})
        os.replace(temporary, path)

    @classmethod
    def restore(cls, engine, path, expected_identity):
        # Read only the header to distinguish result-only records from legacy
        # and unfinished tensor checkpoints. Do not load a large cache twice.
        with safe_open(str(path), framework='numpy') as checkpoint:
            completed = (checkpoint.metadata() or {}).get('livelingo.completed')
        if completed is not None:
            state = json.loads(completed)
            if state.get('done') is not True:
                raise ValueError('Result-only checkpoint is not complete')
            cache = []
        else:
            cache, metadata = load_prompt_cache(str(path), return_metadata=True)
            state = json.loads(metadata['generation'])
        if state['version'] != cls.VERSION or state['identity'] != expected_identity:
            raise ValueError('Checkpoint identity mismatch')
        result = cls(engine, **state['spec'], prefix=state['prefix'], _use_prefix_cache=False)
        if result.identity != expected_identity:
            raise ValueError('Model or request changed')
        # A restored cache may already contain an arbitrary part of the input.
        # It must never be recorded under a fresh request's prefix boundary.
        result._prefix_cache = None
        result._cache_tokens = ()
        result.cache = cache
        result.pending = state['pending']
        result.ids = state['ids']
        result.final_ids = state['final_ids']
        result.key = mx.array(state['key'], dtype=mx.uint32)
        result.phase = state['phase']
        result.thinking_count = state['thinking_count']
        result.final_count = state['final_count']
        result.done = state['done']
        if result.guide:
            result.guide.reset()
            for token in result.final_ids:
                result.guide.advance(token, return_tokens=False)
        result.detokenizer.reset()
        for token in result.ids:
            if token not in engine.tokenizer.eos_token_ids:
                result.detokenizer.add_token(token)
        if result.done:
            result.detokenizer.finalize()
        return result
