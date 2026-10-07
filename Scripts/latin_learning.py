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


def mentions(text, language, unit_aliases):
    for raw, start, end, value in literals(text, language):
        before, after = text[max(0, start - 40):start], text[end:].strip()
        prior = re.findall(r'[^\W\d_]+', before.lower())
        following = re.findall(r'[^\W\d_]+', after.lower())
        if prior and prior[-1] in DESIGNATORS.get(language, ()):
            yield value, None, 'designator', '编号' + raw
            continue
        unit = next(((alias, family) for alias, family in UNITS.get(language, ())
                     if after.lower().startswith(alias) and not after[len(alias):len(alias)+1].isalpha()), None)
        if unit is None:
            unit = next(((alias, family) for alias, family in unit_aliases
                         if after.startswith(alias) and not (alias[-1:].isascii() and alias[-1:].isalpha()
                         and after[len(alias):len(alias)+1].isascii() and after[len(alias):len(alias)+1].isalpha())), None)
        attribute = bool(set(prior) & ATTRIBUTES.get(language, set()))
        count = not unit and not attribute and following and following[0] in COUNTS.get(language, ())
        role = 'measurement' if unit or attribute else 'count' if count else 'ambiguous'
        excerpt = raw + after[:len(unit[0])] if unit else before.strip() + raw if attribute else raw
        yield value, unit[1] if unit else None, role, excerpt


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
