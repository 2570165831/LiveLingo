"""Offline es/fr numeric provenance, mirroring LatinLearningText."""
import re
from mlx_runtime.latin_numbers import literals

ATTRIBUTES = {
    'es': set('temperatura presión presion volumen masa velocidad densidad tiempo frecuencia energía longitud ángulo concentración potencia corriente voltaje puntuación'.split()),
    'fr': set('température pression volume masse vitesse densité temps fréquence énergie longueur angle concentration puissance courant tension score'.split()),
    'en': set('temperature pressure volume mass speed velocity density time frequency energy length angle concentration power current voltage score'.split()),
}
DESIGNATORS = {'es': set('capítulo sección figura tabla ecuación paso número versión'.split()),
               'fr': set('chapitre section figure tableau équation étape numéro version'.split()),
               'en': set('chapter section figure table equation step number version'.split())}
COUNTS = {'es': set('ejemplo ejemplos caso casos elemento elementos punto puntos pregunta preguntas'.split()),
          'fr': set('exemple exemples cas élément éléments point points question questions'.split()),
          'en': set('example examples case cases element elements point points question questions'.split())}
UNITS = {
    'es': [('grados celsius', 'C'), ('grado celsius', 'C'), ('kilopascales', 'kPa'), ('kilopascal', 'kPa'),
           ('mililitros', 'mL'), ('mililitro', 'mL'), ('litros', 'L'), ('litro', 'L'),
           ('minutos', 'min'), ('minuto', 'min'), ('segundos', 's'), ('segundo', 's'),
           ('kilogramos', 'kg'), ('kilogramo', 'kg'), ('gramos', 'g'), ('gramo', 'g')],
    'fr': [('degrés celsius', 'C'), ('degré celsius', 'C'), ('kilopascals', 'kPa'), ('kilopascal', 'kPa'),
           ('millilitres', 'mL'), ('millilitre', 'mL'), ('litres', 'L'), ('litre', 'L'),
           ('minutes', 'min'), ('minute', 'min'), ('secondes', 's'), ('seconde', 's'),
           ('kilogrammes', 'kg'), ('kilogramme', 'kg'), ('grammes', 'g'), ('gramme', 'g')],
}


UNIT_WORDS = {language: dict(entries) for language, entries in UNITS.items()}
for language, entries in {
    'es': [('metro', 'm'), ('metros', 'm'), ('centímetro', 'cm'), ('centímetros', 'cm'),
           ('milímetro', 'mm'), ('milímetros', 'mm'), ('kilómetro', 'km'), ('kilómetros', 'km'),
           ('hora', 'h'), ('horas', 'h'), ('milisegundo', 'ms'), ('milisegundos', 'ms'),
           ('pascal', 'Pa'), ('pascales', 'Pa'), ('megapascal', 'MPa'), ('megapascales', 'MPa'),
           ('mol', 'mol'), ('moles', 'mol'), ('voltio', 'V'), ('voltios', 'V'),
           ('amperio', 'A'), ('amperios', 'A'), ('vatio', 'W'), ('vatios', 'W'),
           ('julio', 'J'), ('julios', 'J'), ('newton', 'N'), ('newtons', 'N'),
           ('por', 'per'), ('al cuadrado', 'squared'), ('cuadrado', 'squared'), ('cuadrados', 'squared'),
           ('cuadrada', 'squared'), ('cuadradas', 'squared'), ('al cubo', 'cubed'),
           ('cúbico', 'cubed'), ('cúbicos', 'cubed'), ('cúbica', 'cubed'), ('cúbicas', 'cubed')],
    'fr': [('mètre', 'm'), ('mètres', 'm'), ('centimètre', 'cm'), ('centimètres', 'cm'),
           ('millimètre', 'mm'), ('millimètres', 'mm'), ('kilomètre', 'km'), ('kilomètres', 'km'),
           ('heure', 'h'), ('heures', 'h'), ('milliseconde', 'ms'), ('millisecondes', 'ms'),
           ('pascal', 'Pa'), ('pascals', 'Pa'), ('mégapascal', 'MPa'), ('mégapascals', 'MPa'),
           ('mole', 'mol'), ('moles', 'mol'), ('ampère', 'A'), ('ampères', 'A'),
           ('volt', 'V'), ('volts', 'V'), ('watt', 'W'), ('watts', 'W'),
           ('joule', 'J'), ('joules', 'J'), ('newton', 'N'), ('newtons', 'N'),
           ('par', 'per'), ('carré', 'squared'), ('carrés', 'squared'), ('carrée', 'squared'),
           ('carrées', 'squared'), ('cube', 'cubed'), ('cubes', 'cubed'), ('cubique', 'cubed'), ('cubiques', 'cubed')],
}.items():
    UNIT_WORDS[language].update(entries)
    for alias, family in UNITS[language]:
        if family == 'C':
            UNIT_WORDS[language][alias] = '°C'
UNIT_PATTERNS = {language: re.compile(
    r'(?<![^\W\d_])(?:' + '|'.join(re.escape(word).replace(r'\ ', r'[\t \u00a0\u202f]+')
                                   for word in sorted(words, key=len, reverse=True))
    + r')(?![^\W\d_])|\s*[/·⋅]\s*', re.I) for language, words in UNIT_WORDS.items()}
SUPERSCRIPTS = dict(zip('⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺', '0123456789-+'))


def superscript(power):
    return ('⁻' if power < 0 else '') + ''.join('⁰¹²³⁴⁵⁶⁷⁸⁹'[int(d)] for d in str(abs(power)))


def unit_term(text, unit_aliases, leading=True):
    prefix_length, power = 0, 1
    for word, exponent in [('square ', 2), ('cubic ', 3)]:
        if text.lower().startswith(word):
            prefix_length, power = len(word), exponent
            break
    body = text[prefix_length:]
    unit = next(((alias, family) for alias, family in unit_aliases if body.startswith(alias)
                 and not (alias[-1:].isascii() and alias[-1:].isalpha()
                          and body[len(alias):len(alias)+1].isascii()
                          and body[len(alias):len(alias)+1].isalnum())), None)
    if unit is None:
        for alias, family in unit_aliases:
            if family in ('m', 'cm', 'mm', 'km', 's') and alias.isascii() and alias.isalpha():
                match = re.match(re.escape(alias) + r'([23])(?![A-Za-z0-9])', body)
                if match and power == 1:
                    return len(match.group()), family + superscript(int(match[1]))
        return None
    alias, family = unit
    if '/' in family and (not leading or power != 1):
        return None
    family = {'kg/m3': 'kg/m³', 'g/cm3': 'g/cm³'}.get(family, family)
    length = len(alias)
    rest = body[length:]
    run = re.match(r'[⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺]+', rest)
    caret = re.match(r'\^([+\-−]?[0-9]{1,2})(?![0-9])', rest)
    word = re.match(r' (squared|cubed)(?![A-Za-z])', rest, re.I)
    if run or caret:
        raw = ''.join(SUPERSCRIPTS.get(c, c) for c in run.group()) if run else caret[1].replace('−', '-')
        try:
            exponent = int(raw)
        except ValueError:
            exponent = 0
        if not exponent:
            return prefix_length + length + len((run or caret).group()), family + '…'
        power *= exponent
        length += len((run or caret).group())
    elif rest.startswith('^'):
        return prefix_length + length + 1, family + '…'
    elif word:
        power *= 2 if word[1].lower() == 'squared' else 3
        length += len(word.group())
    return prefix_length + length, family if power == 1 else family + superscript(power)


def append_denominator(family, term):
    def split(unit):
        match = re.search(r'[⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺]+$', unit)
        return (unit[:match.start()], int(''.join(SUPERSCRIPTS[c] for c in match.group()))) if match else (unit, 1)
    if '/' in family:
        head, last = family.rsplit('/', 1)
        if '·' not in last and not last.endswith('…') and not term.endswith('…'):
            previous, p = split(last)
            following, q = split(term)
            if previous == following and p > 0 and q > 0:
                return head + '/' + previous + superscript(p + q)
    return family + '/' + term


def provenance_unit(after, language, unit_aliases):
    # Bind canonical parsing back to the exact source spelling, as Swift does.
    canonical, ends, cursor = '', [], 0
    pattern = UNIT_PATTERNS.get(language)
    for match in pattern.finditer(after) if pattern else ():
        canonical += ''.join(' ' if c.isspace() else c for c in after[cursor:match.start()])
        ends += list(range(cursor + 1, match.start() + 1))
        raw = ' '.join(match.group().lower().split())
        replacement = UNIT_WORDS[language].get(raw, ''.join(raw.split()))
        canonical += replacement
        ends += [match.end()] * len(replacement)
        cursor = match.end()
    canonical += ''.join(' ' if c.isspace() else c for c in after[cursor:])
    ends += list(range(cursor + 1, len(after) + 1))
    leading = unit_term(canonical, unit_aliases)
    if leading is None:
        return None
    length, family = leading
    for _ in range(3):
        if family.endswith('…'):
            break
        rest = canonical[length:]
        if rest[:1] in ('/', '·', '⋅'):
            separator, operator, explicit = '/' if rest[0] == '/' else '·', 1, True
        elif rest.lower().startswith(' per '):
            separator, operator, explicit = '/', 5, False
        else:
            break
        operand = rest[operator:]
        term = unit_term(operand, unit_aliases, leading=False)
        if term:
            size, unit = term
            family = append_denominator(family, unit) if separator == '/' else family + separator + unit
            length += operator + size
        elif explicit and operand[:1].isalpha():
            unknown = re.match(r'[^\s.,;:!?\)\]\"\']+', operand)
            family += separator + '…'
            length += operator + len(unknown.group())
        else:
            break
    return after[:ends[length - 1]], family


def negative_sign(before, language, unit_aliases):
    if before[-1:] in ('-', '−', '－', '﹣'):
        prior = before[-2:-1]
        return before[-1] if not prior or prior.isspace() or prior in '([{=：:,;~≈<>≤≥\"\'“‘' else ''
    words = {'es': 'menos|negativo|negativa', 'fr': 'moins|négatif|négative', 'en': 'minus|negative'}
    match = re.search(r'(?<![\w])(?:' + words.get(language, words['en']) + r')[ \t]+$', before, re.I)
    if not match:
        return ''
    head = before[:match.start()]
    if re.search(r'(?:más\s+o|plus\s+ou|plus\s+or)\s+$', head, re.I):
        return ''
    token = head.split()[-1] if head.split() else ''
    unit = provenance_unit(token, language, unit_aliases)
    return '' if any(c.isnumeric() for c in token) or unit and unit[0] == token else match.group()


SCIENTIFIC_TAIL = re.compile(r'^(?:[ \t]*[×xX*·⋅][ \t]*10[ \t]*(?:\^[ \t]*([+\-−]?[0-9]+)|([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+))'
                             r'|[ \t]*\^[ \t]*([+\-−]?[0-9]+)|([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+))(?![0-9A-Za-z_])')


def signed_mentions(text, language, unit_aliases):
    covered_end = 0
    for raw, start, end, value in literals(text, language):
        if start < covered_end:
            continue
        before = text[max(0, start - 40):start]
        value = value.lstrip('-')
        tail = SCIENTIFIC_TAIL.match(text[end:])
        if tail:
            group = next(i for i in range(1, 5) if tail[i] is not None)
            power_text = ''.join(SUPERSCRIPTS.get(c, '-' if c == '−' else c) for c in tail[group])
            exponent = int(power_text) if len(power_text) <= 20 else None
            bounded = exponent is not None and -30 <= exponent <= 30
            if bounded and group <= 2:
                coefficient, power = value.split('e')
                scale = int(power) + exponent
                if not -(2**63) <= scale < 2**63:
                    value = ''.join((raw.lstrip('+-−') + tail.group()).split())
                else:
                    value = '0e0' if coefficient == '0' else coefficient + 'e' + str(scale)
            elif bounded and value == '1e1':
                value = '1e' + str(exponent)
            else:
                value = ''.join((raw.lstrip('+-−') + tail.group()).split())
            end += len(tail.group())
            raw = text[start:end]
        unit_start = end
        while unit_start < len(text) and text[unit_start].isspace():
            unit_start += 1
        after = text[unit_start:]
        prior = re.findall(r'[^\W\d_]+', before.lower())
        following = re.findall(r'[^\W\d_]+', after.lower())
        if before[-1:].isupper() or before.endswith('-') and before[-2:-1].isupper() or prior and prior[-1] in DESIGNATORS.get(language, ()):
            yield value, None, 'designator', '编号' + raw, ''
            continue
        unit = provenance_unit(after, language, unit_aliases)
        covered_end = unit_start + len(unit[0]) if unit else end
        attribute = bool(set(prior) & ATTRIBUTES.get(language, set()))
        count = not unit and not attribute and following and following[0] in COUNTS.get(language, ())
        role = 'measurement' if unit or attribute else 'count' if count else 'ambiguous'
        written_sign = raw[:1] in ('+', '-', '−')
        sign = negative_sign(before + (raw[0] if written_sign else ''), language, unit_aliases)
        if unit and unit[1] == 'C':
            below = r'^\s+bajo\s+cero\b' if language == 'es' else r'^\s+(?:au-dessous\s+de|en\s+dessous\s+de|sous)\s+zéro\b'
            if re.search(below, after[len(unit[0]):], re.I):
                sign = '-'
        signed = ('' if written_sign else sign) + raw
        excerpt = signed + unit[0] if unit else before.strip() + raw if attribute else signed
        yield value, unit[1] if unit else None, role, excerpt, '-' if sign and value != '0e0' else ''


def mentions(text, language, unit_aliases):
    """Preserve the existing public four-field mention interface."""
    for mention in signed_mentions(text, language, unit_aliases):
        yield mention[:4]


def numeric_report(claim, cited, segment_texts, batch_texts, target, language_groups, unit_aliases):
    def parse(text, source=False):
        languages = {language for language, original in language_groups if text in original} if source else {target}
        return [] if len(languages) > 1 else list(signed_mentions(text, next(iter(languages)) if languages else target, unit_aliases))
    own = [m for text in cited + segment_texts for m in parse(text, source=True)]
    batch = [m for text in batch_texts for m in parse(text, source=True)]
    gaps, decidable = [], False
    def push(message):
        if len(gaps) < 3 and message not in gaps:
            gaps.append(message)
    for value, unit, role, excerpt, sign in parse(claim):
        if role == 'designator':
            continue
        if role == 'count':
            if any(m[0] == value and m[2] == 'count' for m in own):
                continue
            location = ('本次原文的其他句子出现过相同数量，请确认是否该把那一句也列为来源。'
                        if any(m[0] == value and m[2] == 'count' for m in batch)
                        else '同样的数字不一定表示同样的数量，请核对它是数量、目标值还是编号。')
            push(f'正文里的计数“{excerpt}”未在所引原句及同一字幕中找到计数支持；{location}')
            continue
        in_own = [m for m in own if m[0] == value and m[2] not in ('designator', 'count')]
        in_batch = [m for m in batch if m[0] == value and m[2] not in ('designator', 'count')]
        if role == 'measurement' and unit:
            def matching(others):
                return any(m[1] == unit and m[4] == sign for m in others)
            def conflict(others):
                signed = [m for m in others if m[1] == unit]
                if signed:
                    forms = '、'.join(sorted({m[3] for m in signed}))
                    return f'正文里的“{excerpt}”与原文中对应数值的正负号不同（原文为 {forms}）；请人工确认。'
                families = '、'.join(sorted({m[1] for m in others if m[1]})) or '无单位'
                return f'正文里的“{excerpt}”与原文中同一数字的单位不同（原文为 {families}）；请人工确认是换算、推导还是引用错位。'
            if matching(in_own):
                continue
            if in_own:
                decidable = True
                push(conflict(in_own))
            elif matching(in_batch):
                push(f'正文里的“{excerpt}”不在所引原句里；本次原文的其他句子出现过同样的数值，请确认是否该把那一句也列为来源。')
            elif in_batch:
                decidable = True
                push(conflict(in_batch))
            else:
                decidable = True
                push(f'正文里的“{excerpt}”在本次原文里找不到；请人工确认它对应的对象、条件和来源。')
        elif role == 'measurement':
            if in_own:
                continue
            if in_batch:
                push(f'正文里的“{excerpt}”不在所引原句里；本次原文的其他句子出现过同样的数值，请确认是否该把那一句也列为来源。')
            else:
                decidable = True
                push(f'正文里的“{excerpt}”在本次原文里找不到同值；请人工确认它对应的对象、条件和来源。')
        elif not in_own and not in_batch:
            push(f'正文里的“{excerpt}”没有单位或属性说明，也没有出现在本次原文中；请人工确认它是编号还是测量值，并补上单位或来源。')
    return decidable, ' '.join(gaps)[:240] or None


def pass_through_sources():
    from pathlib import Path
    source = (Path(__file__).resolve().parents[1] / "LiveLingo/Sources/OutputLanguage.swift").read_text()
    result = {}
    for locale, name in (("es", "spanish"), ("fr", "french")):
        match = re.search(r"static let " + name + r"PassThroughSources: Set<String> = \[(.*?)\]", source)
        if match is None:
            raise ValueError("Missing pass-through defaults: " + locale)
        result[locale] = frozenset(re.findall(r'"([^"\n]+)"', match.group(1)))
    return result
