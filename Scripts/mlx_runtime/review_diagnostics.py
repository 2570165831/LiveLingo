"""Metadata-only review failure records for the owned MLX worker.

These strings travel from the worker protocol into the app's queue failure text
and local log, so they carry identifiers and bounded metadata only: never note
text, prompts, evidence quotes or model output. The app parses the
``review failure stage=... code=...`` prefix and maps it to a user-facing
Chinese explanation.

Review input is validated against the app's review protocol v2: the app's
fragmenter splits each frozen evidence item into fragments of at most 2400
Swift ``Character`` values and emits a short quote ID per fragment
(``e0.en.0``). Only those IDs reach the response grammar; the frozen catalog
maps an ID back to its text on the app side.
"""

import json
import re

MAX_DETAIL = 200
MAX_FIELD = 80
_STAGES = frozenset({'input', 'schema', 'prompt_binding', 'generation', 'decode'})
_CODES = frozenset({'invalid_input', 'invalid_json', 'invalid_item', 'missing_field',
                    'legacy_input', 'unsupported_review_version', 'input_not_in_prompt',
                    'schema_build_failed', 'generation_failed', 'vocabulary_encoding',
                    'grammar_complexity', 'grammar_compile_failed', 'output_budget_exhausted'})
_STRUCTURAL_FIELD = re.compile(
    r'(?:input|reviewVersion|note(?:\.points(?:\[\d+\](?:\.(?:text|index))?)?)?'
    r'|evidence(?:\[\d+\](?:\.(?:index|chineseWarning|quotes(?:\[\d+\]'
    r'(?:\.(?:id|language|text))?)?))?)?)')
_DETAIL_MESSAGES = frozenset({
    'point text must be a string', 'point must be an object',
    'point index must be an integer', 'review input must be a JSON object',
    'review input must be a JSON string', 'review input has no note object',
    'note.points must be an array', 'evidence must be an array',
    'evidence item must be an object', 'evidence index must be an integer',
    'evidence index must not be negative', 'evidence index must be unique',
    'evidence quotes must be an array', 'chineseWarning must be a string',
    'quote must be an object', 'unexpected field in a v2 quote',
    'unexpected field in a v2 evidence item', 'quote id must be a non-empty string',
    'quote id must be a short ASCII identifier', 'quote id must be unique across the review input',
    'quote language must be en or zh', 'quote language must be en, zh, es or fr',
    'quote id language does not match its language field',
    'quote id does not belong to this evidence item', 'quote text must be a string',
    'empty fragments are not allowed', 'quote id is required',
    'quote language is required', 'quote text is required',
    'evidence must use reviewVersion 2 quotes; legacy english/chinese fields are not accepted',
    'evidence mixes reviewVersion 2 quotes with legacy quote fields',
    'review input has no reviewVersion; only reviewVersion 2 is accepted',
    'reviewVersion must be the integer 2', 'only reviewVersion 2 is accepted',
    'review input not found in rendered prompt', 'review input not found',
    'token_bytes_unmatched', 'grammar_state_limit', 'cache limit exceeded',
    'invalid_request', 'invalid_json', 'io_error', 'resource_exhausted',
    'timeout', 'runtime_error', 'output_budget_exhausted', 'internal_error',
})

REVIEW_VERSION = 2
QUOTE_LANGUAGES = ('en', 'zh', 'es', 'fr')
# Short-ID bound: quote IDs are literals inside the response grammar (DFA), so
# they must stay short, ASCII and free of payload text. Fragment text itself is
# never copied into the grammar.
MAX_QUOTE_ID = 64
_QUOTE_ID = re.compile(r'[A-Za-z0-9_.:-]{1,%d}' % MAX_QUOTE_ID)
_QUOTE_ID_PARTS = re.compile(r'e(\d+)\.(en|zh|es|fr)\.\d+')
QUOTE_FIELDS = ('id', 'language', 'text')
EVIDENCE_FIELDS = ('index', 'quotes', 'chineseWarning')
# Fields that only existed before review v2; never mix them with v2 quotes.
LEGACY_EVIDENCE_FIELDS = ('english', 'chinese', 'quote')


def clean_detail(value, limit=MAX_DETAIL):
    """Only fixed application explanations or numeric JSON positions survive."""
    raw = str(value)
    text = ' '.join(raw.split())
    if not text:
        return ''
    if text in _DETAIL_MESSAGES or re.fullmatch(
            r'JSON syntax error at line \d+ column \d+ \(offset \d+\)', text):
        return text[:limit]
    return f'<redacted {len(raw.encode("utf-8", "replace"))} bytes>'


def field_value(value):
    """Accept only known structural paths, never attacker-chosen key names."""
    return value if (isinstance(value, str) and len(value) <= MAX_FIELD
                     and _STRUCTURAL_FIELD.fullmatch(value)) else 'unknown'


def failure_line(stage, code, detail='', **fields):
    """One structured, content-free failure record."""
    stage = stage if isinstance(stage, str) and stage in _STAGES else 'unknown'
    code = code if isinstance(code, str) and code in _CODES else 'generation_failed'
    parts = [f'review failure stage={stage} code={code}']
    for name in sorted(fields):
        value = fields[name]
        if value is None:
            continue
        if name == 'field':
            parts.append(f'field={field_value(value)}')
        elif name in ('input_bytes', 'prompt_bytes') and type(value) is int and value >= 0:
            parts.append(f'{name}={value}')
    cleaned = clean_detail(detail)
    if cleaned:
        parts.append(f'detail={cleaned}')
    return ' '.join(parts)


class ReviewFailure(ValueError):
    """Application-authored structured record; arbitrary exception text is not one."""
    def __init__(self, stage, code='generation_failed', detail='', **fields):
        self.record = failure_line(stage, code, detail, **fields)
        super().__init__(self.record)


def stage_error(stage, code, detail='', **fields):
    """ValueError carrying a structured record (message reaches the app)."""
    return ReviewFailure(stage, code, detail, **fields)


def describe_json_error(error):
    if isinstance(error, json.JSONDecodeError):
        return f'JSON syntax error at line {error.lineno} column {error.colno} (offset {error.pos})'
    return 'invalid_json'


def _quote_problem(evidence_position, unit_index, quote_index, quote, seen_ids):
    """First problem in one v2 quote, or None. Never echoes fragment text.

    Fragment length is intentionally not re-checked here: the app's fragmenter
    limits fragments to 2400 Swift ``Character`` values, and one ``Character``
    can be several Unicode scalars, so a Python ``len`` limit would reject
    valid fragments. Structural checks only; nothing is dropped for length.
    """
    field = f'evidence[{evidence_position}].quotes[{quote_index}]'
    if not isinstance(quote, dict):
        return ('invalid_item', field, 'quote must be an object')
    for name in quote:
        if name not in QUOTE_FIELDS:
            return ('invalid_item', f'{field}.{name}', 'unexpected field in a v2 quote')
    for name in QUOTE_FIELDS:
        if name not in quote:
            return ('missing_field', f'{field}.{name}', f'quote {name} is required')
    identifier = quote['id']
    if not isinstance(identifier, str) or not identifier:
        return ('missing_field', f'{field}.id', 'quote id must be a non-empty string')
    if _QUOTE_ID.fullmatch(identifier) is None:
        return ('invalid_item', f'{field}.id', 'quote id must be a short ASCII identifier')
    if identifier in seen_ids:
        return ('invalid_item', f'{field}.id', 'quote id must be unique across the review input')
    language = quote['language']
    if not isinstance(language, str) or language not in QUOTE_LANGUAGES:
        return ('invalid_item', f'{field}.language', 'quote language must be en, zh, es or fr')
    parts = _QUOTE_ID_PARTS.fullmatch(identifier)
    if parts is not None and parts.group(2) != language:
        return ('invalid_item', f'{field}.id', 'quote id language does not match its language field')
    # The documented ID is rooted in its own evidence entry (``e<index>``); the
    # array position is accepted too so a filtered batch may keep either.
    if parts is not None and int(parts.group(1)) not in (evidence_position, unit_index):
        return ('invalid_item', f'{field}.id', 'quote id does not belong to this evidence item')
    text = quote['text']
    if not isinstance(text, str):
        return ('missing_field', f'{field}.text', 'quote text must be a string')
    if not text:
        return ('invalid_item', f'{field}.text', 'empty fragments are not allowed')
    seen_ids.add(identifier)
    return None


def _evidence_problem(position, unit, seen_ids):
    """First problem in one v2 evidence item, or None."""
    field = f'evidence[{position}]'
    if not isinstance(unit, dict):
        return ('invalid_item', field, 'evidence item must be an object')
    legacy = [name for name in LEGACY_EVIDENCE_FIELDS if name in unit]
    if 'quotes' not in unit:
        if legacy:
            return ('legacy_input', field,
                    'evidence must use reviewVersion 2 quotes; legacy english/chinese fields are not accepted')
        return ('missing_field', f'{field}.quotes', 'evidence quotes must be an array')
    if legacy:
        return ('legacy_input', field, 'evidence mixes reviewVersion 2 quotes with legacy quote fields')
    for name in unit:
        if name not in EVIDENCE_FIELDS:
            return ('invalid_item', f'{field}.{name}', 'unexpected field in a v2 evidence item')
    unit_index = unit.get('index', position)
    if not isinstance(unit_index, int) or isinstance(unit_index, bool):
        return ('invalid_item', f'{field}.index', 'evidence index must be an integer')
    if unit_index < 0:
        return ('invalid_item', f'{field}.index', 'evidence index must not be negative')
    quotes = unit['quotes']
    if not isinstance(quotes, list):
        return ('missing_field', f'{field}.quotes', 'evidence quotes must be an array')
    warning = unit.get('chineseWarning')
    if warning is not None and not isinstance(warning, str):
        return ('invalid_item', f'{field}.chineseWarning', 'chineseWarning must be a string')
    for quote_index, quote in enumerate(quotes):
        problem = _quote_problem(position, unit_index, quote_index, quote, seen_ids)
        if problem is not None:
            return problem
    return None


def review_input_problem(data):
    """First structural problem in a review request, or None.

    Returns ``(code, field, detail)`` so the caller can raise a structured
    error instead of surfacing a bare KeyError such as ``'note'``. Only review
    protocol v2 is accepted: a missing ``reviewVersion`` is an older app build,
    and mixing legacy ``english``/``chinese`` evidence with v2 quotes is
    refused rather than guessed at.
    """
    if not isinstance(data, dict):
        return ('invalid_input', 'input', 'review input must be a JSON object')
    version = data.get('reviewVersion')
    if version is None:
        return ('legacy_input', 'reviewVersion',
                'review input has no reviewVersion; only reviewVersion 2 is accepted')
    if not isinstance(version, int) or isinstance(version, bool):
        return ('unsupported_review_version', 'reviewVersion', 'reviewVersion must be the integer 2')
    if version != REVIEW_VERSION:
        return ('unsupported_review_version', 'reviewVersion',
                'only reviewVersion 2 is accepted')
    note = data.get('note')
    if not isinstance(note, dict):
        return ('missing_field', 'note', 'review input has no note object')
    points = note.get('points')
    if not isinstance(points, list):
        return ('missing_field', 'note.points', 'note.points must be an array')
    for index, point in enumerate(points):
        if not isinstance(point, dict):
            return ('invalid_item', f'note.points[{index}]', 'point must be an object')
        if not isinstance(point.get('text'), str):
            return ('missing_field', f'note.points[{index}].text', 'point text must be a string')
        if not isinstance(point.get('index', index), int):
            return ('invalid_item', f'note.points[{index}].index', 'point index must be an integer')
    evidence = data.get('evidence')
    if not isinstance(evidence, list):
        return ('missing_field', 'evidence', 'evidence must be an array')
    seen_ids = set()
    seen_indexes = set()
    for position, unit in enumerate(evidence):
        problem = _evidence_problem(position, unit, seen_ids)
        if problem is not None:
            return problem
        unit_index = unit.get('index', position)
        if unit_index in seen_indexes:
            return ('invalid_item', f'evidence[{position}].index', 'evidence index must be unique')
        seen_indexes.add(unit_index)
    return None


def generation_detail(error):
    """Classify by exception type without ever reading its free-text message."""
    if getattr(error, 'code', None) == 'output_budget_exhausted':
        return 'output_budget_exhausted'
    if isinstance(error, json.JSONDecodeError): return 'invalid_json'
    if isinstance(error, MemoryError): return 'resource_exhausted'
    if isinstance(error, TimeoutError): return 'timeout'
    if isinstance(error, OSError): return 'io_error'
    if isinstance(error, (ValueError, KeyError, TypeError)): return 'invalid_request'
    if isinstance(error, RuntimeError): return 'runtime_error'
    return 'internal_error'


def safe_error_message(error, review=False):
    if isinstance(error, ReviewFailure):
        return error.record
    code = generation_detail(error)
    if review:
        return failure_line('generation', 'generation_failed', code)
    return 'runtime failure code=' + code


def parse_review_input(raw_input):
    """Decode and structurally check review input, or raise a structured error."""
    if not isinstance(raw_input, str):
        raise stage_error('input', 'invalid_json', 'review input must be a JSON string')
    try:
        data = json.loads(raw_input)
    except Exception as error:
        raise stage_error('input', 'invalid_json', describe_json_error(error),
                          input_bytes=len(raw_input.encode())) from None
    problem = review_input_problem(data)
    if problem is not None:
        raise stage_error('schema', problem[0], problem[2], field=problem[1])
    return data


def bind_review_prompt(raw_input, prompt, data):
    """Replace the user turn with the checked input, or raise a structured error.

    The schema is built from this exact JSON, so a prompt that does not contain
    the original input would silently constrain a different payload.
    """
    marker = '<|im_start|>user\n' + raw_input + '<|im_end|>'
    if marker not in prompt:
        raise stage_error('prompt_binding', 'input_not_in_prompt',
                          'review input not found in rendered prompt',
                          input_bytes=len(raw_input.encode()), prompt_bytes=len(prompt.encode()))
    bound = '<|im_start|>user\n' + json.dumps(data, ensure_ascii=False, sort_keys=True) + '<|im_end|>'
    return prompt.replace(marker, bound, 1)



def grammar_error(error):
    """Keep actionable compiler metadata, never the regex or classroom text."""
    message = str(error)
    if 'Found no transitions' in message or 'encoding issue in your vocabulary' in message:
        return stage_error('schema', 'vocabulary_encoding', 'token_bytes_unmatched')
    if 'DFA states' in message or 'Failed to build DFA' in message:
        return stage_error('schema', 'grammar_complexity', 'grammar_state_limit')
    return stage_error('schema', 'grammar_compile_failed', generation_detail(error))
