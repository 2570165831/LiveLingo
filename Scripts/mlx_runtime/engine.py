"""Isolated candidate: explicit token boundaries, per-request RNG and grammar state."""
import hashlib
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
from outlines_core.json_schema import build_regex_from_schema
from grammar_vocabulary import build_vocabulary
from review_diagnostics import grammar_error
from outlines_core.kernels.mlx import allocate_token_bitmask, fill_next_token_bitmask, apply_token_bitmask

class Engine:
    def __init__(self, model_path):
        self.model_path = str(Path(model_path).resolve())
        self.model, self.tokenizer = load(self.model_path)
        self.vocabulary = build_vocabulary(self.tokenizer)
        self.indices = OrderedDict()
        self.end_think = self.tokenizer.encode('</think>', add_special_tokens=False)
        if len(self.end_think) != 1:
            raise ValueError('Thinking delimiter must be one token for this adapter')
        identity = [('runtime', [(name, version(name)) for name in
                    ('mlx', 'mlx-lm', 'outlines', 'outlines_core', 'transformers')])]
        for name in ('engine.py', 'schemas.py', 'checks.py', 'worker.py', 'grammar_vocabulary.py', 'review_diagnostics.py'):
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
                self.indices[key] = Index(build_regex_from_schema(key), self.vocabulary)
            except Exception as error:
                raise grammar_error(error) from None
        self.indices.move_to_end(key)
        while len(self.indices) > 8:
            self.indices.popitem(last=False)
        return self.indices[key]

class Generation:
    VERSION = 2
    def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', seed=None,
                 thinking_budget=16384, final_budget=4096):
        self.engine = engine
        self.spec = dict(prompt=prompt, schema=schema, thinking=thinking,
                         thinking_budget=thinking_budget, final_budget=final_budget)
        self.identity = hashlib.sha256(json.dumps([self.VERSION,engine.identity,self.spec],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        seed = secrets.randbits(32) if seed is None else seed
        self.spec['seed'] = seed
        self.initial_prefix = prefix
        self.pending = engine.tokenizer.encode(prompt + prefix, add_special_tokens=False)
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
        if len(self.pending) > 256:
            chunk, self.pending = self.pending[:256], self.pending[256:]
            self.engine.model(mx.array([chunk]), cache=self.cache)
            mx.eval([c.state for c in self.cache])
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
                raise ValueError('Final output budget exhausted; incomplete output is not committable')
        return 'token'

    def save(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        metadata = dict(version=self.VERSION, identity=self.identity, spec=self.spec,
            prefix=self.initial_prefix, pending=self.pending, ids=self.ids, final_ids=self.final_ids,
            key=self.key.tolist(), phase=self.phase, thinking_count=self.thinking_count,
            final_count=self.final_count, done=self.done)
        temporary = path.with_name(path.stem+'.pending.safetensors')
        save_prompt_cache(str(temporary), self.cache, {'generation':json.dumps(metadata, ensure_ascii=False)})
        os.replace(temporary, path)

    @classmethod
    def restore(cls, engine, path, expected_identity):
        cache, metadata = load_prompt_cache(str(path), return_metadata=True)
        state = json.loads(metadata['generation'])
        if state['version'] != cls.VERSION or state['identity'] != expected_identity:
            raise ValueError('Checkpoint identity mismatch')
        result = cls(engine, **state['spec'], prefix=state['prefix'])
        if result.identity != expected_identity:
            raise ValueError('Model or request changed')
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
