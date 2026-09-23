"""Byte-faithful Outlines vocabulary for the bundled byte-level BPE models.

Decoding one token at a time is lossy: a token may contain only part of a
UTF-8 character. Outlines accepts bytes directly, so preserve those fragments.
This adapter deliberately rejects other tokenizer encodings instead of guessing.
"""
import json

from outlines_core import Vocabulary


def _byte_decoder():
    # The reversible GPT-2 / Hugging Face ByteLevel alphabet. Bytes without a
    # printable Latin-1 representation are assigned characters starting at 256.
    values = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
    characters = list(values)
    next_character = 256
    for value in range(256):
        if value not in values:
            values.append(value)
            characters.append(next_character)
            next_character += 1
    return {chr(character): value for value, character in zip(values, characters)}


def build_vocabulary(tokenizer):
    """Build an offline ``Vocabulary`` from an HF tokenizer or MLX wrapper.

    The backend JSON identifies both the encoding and added tokens; ordinary
    added tokens are literal UTF-8, whereas BPE tokens use the ByteLevel alphabet.
    Special tokens are excluded from JSON generation (EOS is handled by Guide).
    """
    backend = getattr(tokenizer, 'backend_tokenizer', None)
    if backend is None:
        backend = getattr(tokenizer, '_tokenizer', None)
        backend = getattr(backend, 'backend_tokenizer', backend)
    if backend is None or not callable(getattr(backend, 'to_str', None)):
        raise ValueError('Grammar vocabulary requires a Hugging Face tokenizer backend')
    definition = json.loads(backend.to_str())
    if (definition.get('model', {}).get('type') != 'BPE'
            or definition.get('decoder', {}).get('type') != 'ByteLevel'):
        raise ValueError('Grammar vocabulary requires BPE with a ByteLevel decoder')

    eos = getattr(tokenizer, 'eos_token_id', None)
    if not isinstance(eos, int):
        raise ValueError('Grammar vocabulary requires one integer EOS token ID')
    special = set(getattr(tokenizer, 'all_special_ids', []))
    special.add(eos)
    added = {}
    for token in definition.get('added_tokens', []):
        if token.get('special'):
            special.add(token['id'])
        else:
            added[token['id']] = token['content']

    decoder = _byte_decoder()
    formatted = {}
    for token, token_id in tokenizer.get_vocab().items():
        if token_id in special:
            continue
        if token_id in added:
            raw = added[token_id].encode('utf-8')
        else:
            try:
                raw = bytes(decoder[character] for character in token)
            except KeyError:
                raise ValueError('Grammar vocabulary contains a non-ByteLevel BPE token') from None
        if raw:
            formatted.setdefault(raw, []).append(token_id)
    return Vocabulary(eos, formatted)
