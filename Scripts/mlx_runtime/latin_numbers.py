"""Locale-aware Arabic literals for offline es/fr checks; no inferred magnitudes."""
import re


def literals(text, language):
    code = language.lower().split('-')[0]
    group = '. \u00a0\u202f' if code == 'es' else ' \u00a0\u202f' if code in ('fr', 'ru') else ', \u00a0\u202f'
    decimal = ',.' if code in ('es', 'fr', 'ru') else '.'
    body = rf'(?:[0-9]{{1,3}}(?:[{group}][0-9]{{3}})+|[0-9]+)(?:[{decimal}][0-9]+)?|[{decimal}][0-9]+'
    pattern = re.compile(rf'(?<![0-9.,])[-+−]?(?:{body})(?:[eE][-+−]?[0-9]+)?(?![0-9]|[.,][0-9]|[eE](?:$|[-+−]|[0-9]))')
    for match in pattern.finditer(text):
        token = match.group().replace('−', '-').replace(' ', '').replace('\u00a0', '').replace('\u202f', '').lower()
        if code == 'es':
            mantissa = token.split('e')[0]
            if re.fullmatch(r'[+-]?[1-9][0-9]{0,2}(?:\.[0-9]{3})+(?:,[0-9]+)?', mantissa):
                token = token.replace('.', '')
            token = token.replace(',', '.')
        elif code in ('fr', 'ru'):
            token = token.replace(',', '.')
        else:
            token = token.replace(',', '')
        parts = token.split('e')
        exponent = int(parts[1]) if len(parts) == 2 else 0
        if not -(2**63) <= exponent < 2**63:
            continue
        sign = '-' if parts[0].startswith('-') else ''
        mantissa = parts[0].lstrip('+-')
        digits = mantissa.replace('.', '').lstrip('0')
        if not digits:
            value = '0e0'
        else:
            zeros = len(digits) - len(digits.rstrip('0'))
            scale = exponent - (len(mantissa.split('.')[1]) if '.' in mantissa else 0)
            power = scale + zeros
            if not -(2**63) <= scale < 2**63 or not -(2**63) <= power < 2**63:
                continue
            value = sign + digits.rstrip('0') + 'e' + str(power)
        yield match.group(), match.start(), match.end(), value


def normalize_expression(text, language):
    """Normalize whole locale literals only; AST/Pint still decide supported syntax."""
    for raw, start, end, value in reversed(list(literals(text, language))):
        coefficient, exponent = value.split('e')
        text = text[:start] + coefficient + 'e' + exponent + text[end:]
    return text
