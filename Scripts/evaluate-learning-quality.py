#!/usr/bin/env python3
"""Validate protocol-2 probe evidence and report conservative body coverage signals.

Exit 0 means complete, internally consistent evidence; 2 means missing/invalid
structure; 1 means an execution failure. No exit code certifies factual quality.
Every report still requires independent semantic readback and baseline comparison.
Old probe files are retained as old evidence and must never be silently upgraded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import uuid

KINDS = {"核心结论", "概念关系", "例子", "易错点", "补充理解", "待确认"}
NUMERIC_CONTEXT = "请核对原文中数值对应的对象、属性、单位和条件；表面数值差异不代表事实错误。"
SOURCE_POLICY = "fixture-uuid-v1/12s-start/10s-duration/revision-0/session-none"
DISPLAY_CONTRACT = "production-point-and-rendered-membership-v1"
PENDING = "pending-independent-readback"
PENDING_EVIDENCE_RULE = ("quoteIDs 和 candidateQuoteIDs 引用 priorEvidence 的旧原文或 evidence 的当前原文。"
                         "h 编号只作历史上下文，不能用于当前正文 sourceIDs；旧引文不作为本批新知识重复整理。")
# Mirror the default CaptionTranslationTarget.simplifiedChinese and SpokenLanguage.all. Source-unit
# labels stay en/zh even when the spoken source uses a different language.
CAPTION_TRANSLATION_TARGET = "zh-Hans"
CAPTION_TRANSLATION_TARGETS = frozenset({"zh-Hans", "en", "es", "fr"})
KIND_DISPLAY_LABELS_EN = {
    "核心结论": "Key finding", "概念关系": "Concept relationship", "例子": "Example",
    "易错点": "Common pitfall", "补充理解": "Background", "待确认": "Needs clarification",
}
FOLLOWUP_DISPLAY_LABELS_EN = {
    "缺信息": "Missing information", "后文补充": "Later clarification",
    "前后冲突": "Conflicting accounts", "关系不明": "Relationship unclear",
}
PENDING_EVIDENCE_RULE_EN = (
    "quoteIDs and candidateQuoteIDs refer to priorEvidence or current evidence. "
    "Historical h IDs are context only: never use them in current point sourceIDs "
    "or repeat old quotations as new knowledge.")
CAPTION_PASS_THROUGH_LANGUAGE_CODES = frozenset({"zh"})
CAPTION_PASS_THROUGH_TRANSFORM = "Traditional-Simplified"
SPOKEN_LANGUAGE_CODES = frozenset({
    "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it",
    "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
    "da", "fi", "pl", "cs", "fil", "fa", "el", "ro", "hu", "mk",
})
# EnglishTranscriptGate deliberately uses these narrower legacy ranges.
LEGACY_HAN_RANGES = ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF))
LEGACY_LATIN_RANGES = ((0x0041, 0x005A), (0x0061, 0x007A), (0x00C0, 0x024F), (0x1E00, 0x1EFF))
LEGACY_MIN_LATIN_COUNT = 6
LEGACY_LATIN_PER_HAN = 3
# These filters only withhold automatic credit. They never declare a claim false.
UNASSERTED = re.compile(r"^(?:[⚠️\s]*)(?:待(?:核实|核查|确认)(?:清单|内容|项)?|本条未提供解释|"
                       r"(?:以下|这些|上述).{0,16}(?:均|都|尚|未).{0,5}确认|"
                       r"(?:请|需要).{0,8}(?:核查|回听|确认以下|核对以下)|"
                       r"(?:无法|尚未|不能)确认|仅(?:列出|提供).{0,8}(?:关键词|标题))")
DENIAL = re.compile(r"(?:不成立|不等于|不要求|并未确认|尚未确认|均未确认|仅供核查)")
FOLLOWUP_STATES = {"缺信息", "后文补充", "前后冲突", "关系不明"}
NUMERIC_ATTRIBUTES = ("温度", "压强", "压力", "流量", "体积", "容量", "速度", "速率", "浓度", "质量", "重量",
                      "长度", "宽度", "高度", "深度", "面积", "密度", "时间", "频率", "功率", "电压", "电流",
                      "电阻", "能量", "热量", "角度", "比例", "百分比", "得分", "分数", "读数", "测量值", "数值")
DESIGNATOR_PREFIXES = ("第", "编号", "序号", "图", "表", "式", "步骤", "阶段", "级别", "等级", "题号", "版本")
DESIGNATOR_SUFFIXES = set("项个份条号组种类名位章节课次步版")
# Keep the order aligned with LearningNumericProvenance.unitAliases. The scorer
# checks provenance metadata; it does not decide whether the claim is true.
UNIT_ALIASES = [
    ("degrees celsius", "C"), ("degree celsius", "C"), ("degrees centigrade", "C"), ("celsius", "C"),
    ("摄氏度", "C"), ("℃", "C"), ("°C", "C"), ("°c", "C"), ("度", "C"),
    ("kilopascals", "kPa"), ("kilopascal", "kPa"), ("千帕", "kPa"), ("kPa", "kPa"),
    ("megapascals", "MPa"), ("megapascal", "MPa"), ("兆帕", "MPa"), ("MPa", "MPa"),
    ("pascals", "Pa"), ("pascal", "Pa"), ("帕斯卡", "Pa"), ("帕", "Pa"), ("Pa", "Pa"),
    ("kiloponds", "kgf"), ("psi", "psi"), ("bar", "bar"), ("atm", "atm"),
    ("kelvins", "K"), ("kelvin", "K"), ("开尔文", "K"), ("K", "K"),
    ("kilograms per cubic metre", "kg/m3"), ("千克每立方米", "kg/m3"), ("kg/m3", "kg/m3"),
    ("grams per cubic centimetre", "g/cm3"), ("克每立方厘米", "g/cm3"), ("g/cm3", "g/cm3"),
    ("millilitres", "mL"), ("milliliters", "mL"), ("millilitre", "mL"), ("milliliter", "mL"), ("毫升", "mL"), ("mL", "mL"),
    ("litres", "L"), ("liters", "L"), ("litre", "L"), ("liter", "L"), ("升", "L"), ("L", "L"),
    ("minutes", "min"), ("minute", "min"), ("分钟", "min"), ("min", "min"),
    ("hours", "h"), ("hour", "h"), ("小时", "h"), ("h", "h"),
    ("milliseconds", "ms"), ("millisecond", "ms"), ("毫秒", "ms"), ("ms", "ms"),
    ("seconds", "s"), ("second", "s"), ("秒", "s"), ("s", "s"),
    ("kilograms", "kg"), ("kilogram", "kg"), ("千克", "kg"), ("公斤", "kg"), ("kg", "kg"),
    ("grams", "g"), ("gram", "g"), ("克", "g"), ("g", "g"),
    ("kilometres", "km"), ("kilometers", "km"), ("kilometre", "km"), ("kilometer", "km"), ("千米", "km"), ("公里", "km"), ("km", "km"),
    ("centimetres", "cm"), ("centimeters", "cm"), ("centimetre", "cm"), ("centimeter", "cm"), ("厘米", "cm"), ("cm", "cm"),
    ("millimetres", "mm"), ("millimeters", "mm"), ("millimetre", "mm"), ("millimeter", "mm"), ("毫米", "mm"), ("mm", "mm"),
    ("metres per second", "m/s"), ("meters per second", "m/s"), ("米每秒", "m/s"), ("m/s", "m/s"),
    ("metres", "m"), ("meters", "m"), ("metre", "m"), ("meter", "m"), ("米", "m"), ("m", "m"),
    ("moles per litre", "mol/L"), ("moles per liter", "mol/L"), ("摩尔每升", "mol/L"), ("mol/L", "mol/L"), ("mol/l", "mol/L"),
    ("moles", "mol"), ("mole", "mol"), ("摩尔", "mol"), ("mol", "mol"),
    ("percent", "%"), ("百分比", "%"), ("%", "%"),
    ("millivolts", "mV"), ("millivolt", "mV"), ("毫伏", "mV"), ("mV", "mV"),
    ("volts", "V"), ("volt", "V"), ("伏特", "V"), ("伏", "V"), ("V", "V"),
    ("milliamperes", "mA"), ("milliamps", "mA"), ("milliampere", "mA"), ("毫安", "mA"), ("mA", "mA"),
    ("amperes", "A"), ("ampere", "A"), ("amps", "A"), ("amp", "A"), ("安培", "A"), ("安", "A"), ("A", "A"),
    ("kilowatt hours", "kWh"), ("kilowatt-hours", "kWh"), ("千瓦时", "kWh"), ("kWh", "kWh"),
    ("kilowatts", "kW"), ("kilowatt", "kW"), ("千瓦", "kW"), ("kW", "kW"),
    ("watts", "W"), ("watt", "W"), ("瓦特", "W"), ("瓦", "W"), ("W", "W"),
    ("kilojoules", "kJ"), ("kilojoule", "kJ"), ("千焦", "kJ"), ("kJ", "kJ"),
    ("joules", "J"), ("joule", "J"), ("焦耳", "J"), ("焦", "J"), ("J", "J"),
    ("newtons", "N"), ("newton", "N"), ("牛顿", "N"), ("牛", "N"), ("N", "N"),
    ("kilohertz", "kHz"), ("kHz", "kHz"), ("hertz", "Hz"), ("赫兹", "Hz"), ("Hz", "Hz"),
]

KIND_DISPLAY_LABELS_LATIN = {
    "en": KIND_DISPLAY_LABELS_EN,
    "es": dict(zip(["核心结论", "概念关系", "例子", "易错点", "补充理解", "待确认"], ["Conclusión clave", "Relación conceptual", "Ejemplo", "Error frecuente", "Contexto", "Por aclarar"])),
    "fr": dict(zip(["核心结论", "概念关系", "例子", "易错点", "补充理解", "待确认"], ["Conclusion clé", "Relation conceptuelle", "Exemple", "Piège courant", "Éclairage complémentaire", "À clarifier"])),
}
FOLLOWUP_DISPLAY_LABELS_LATIN = {
    "en": FOLLOWUP_DISPLAY_LABELS_EN,
    "es": dict(zip(["缺信息", "后文补充", "前后冲突", "关系不明"], ["Falta información", "Aclaración posterior", "Versiones contradictorias", "Relación incierta"])),
    "fr": dict(zip(["缺信息", "后文补充", "前后冲突", "关系不明"], ["Informations manquantes", "Précision ultérieure", "Versions contradictoires", "Relation incertaine"])),
}
PENDING_EVIDENCE_RULE_LATIN = {
    "es": "quoteIDs y candidateQuoteIDs remiten a priorEvidence o evidence actual. Los identificadores h son solo contexto histórico: nunca los uses en sourceIDs de puntos actuales ni repitas citas anteriores como conocimiento nuevo.",
    "fr": "quoteIDs et candidateQuoteIDs renvoient à priorEvidence ou aux evidence actuelles. Les identifiants h servent uniquement de contexte historique : ne les utilise jamais dans les sourceIDs des points actuels et ne répète pas les anciennes citations comme connaissances nouvelles.",
}


COUNT_SUFFIXES = set("个份条项组种类名位次扇件张本枚颗台座间只瓶盒行列人")
NUMBER_WORDS = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety").split()
WORD_VALUES = {word: i if i < 20 else (i - 18) * 10 for i, word in enumerate(NUMBER_WORDS)}
NUMBER_WORD = "(?:" + "|".join(NUMBER_WORDS + ["hundred", "thousand", "million", "billion"]) + ")"
COUNT_NUMBER = re.compile(r"(?<![A-Za-z0-9.,])(?:[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?|[零〇一二两三四五六七八九十百千万]+|" + NUMBER_WORD + "(?:[ -]+(?:and[ -]+)?" + NUMBER_WORD + r")*)(?![A-Za-z0-9.,])", re.I)
# Unsupported spoken decimals must not supply integer fragments as count evidence.
SPOKEN_DECIMAL = re.compile("(?:(?:" + COUNT_NUMBER.pattern + r"[ \t]+)?(?<![A-Za-z0-9])point[ \t]+" + COUNT_NUMBER.pattern
                            + r"|[0-9零〇一二两三四五六七八九十百千万]+点[0-9零〇一二两三四五六七八九]+)", re.I)
COUNT_NOUNS = set("door locker item element object entry record sample student person people child children man men woman women option case group class type row column condition step question point byte bit digit bottle electron atom molecule resistor transistor vertex edge tree node term value channel layer cell measurement mark".split())
COUNT_PLURALS = {{"vertex": "vertices", "entry": "entries", "class": "classes"}.get(noun, noun + "s") for noun in COUNT_NOUNS}
COUNT_QUALIFIERS = set("red blue remaining other different possible available distinct valid invalid additional separate stated checked unchecked open closed total".split())


def count_value(raw):
    if raw[0].isascii() and raw[0].isdigit():
        from decimal import Decimal
        return format(Decimal(raw.replace(",", "")).normalize(), "f")
    digits = {c: n for c, n in zip("零〇一二两三四五六七八九", [0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9])}
    if raw[0] in digits or raw[0] in "十百千万":
        if all(c in digits for c in raw):
            return str(int("".join(str(digits[c]) for c in raw)))
        total = section = digit = 0
        for c in raw:
            if c in digits:
                digit = digits[c]
                continue
            scale = {"十": 10, "百": 100, "千": 1000, "万": 10000}.get(c, 0)
            if not scale:
                return None
            if scale == 10000:
                total += (section + digit) * scale
                section = 0
            else:
                section += max(1, digit) * scale
            digit = 0
            if total + section > 1_000_000_000:
                return None
        return str(total + section + digit)
    words = re.split(r"[ -]+", raw.lower())
    def small(tokens):
        if len(tokens) == 1:
            return WORD_VALUES.get(tokens[0])
        if len(tokens) == 2:
            tens, ones = (WORD_VALUES.get(t, -1) for t in tokens)
            if tens >= 20 and 1 <= ones <= 9:
                return tens + ones
        return None
    def group(tokens):
        if "hundred" not in tokens:
            return small(tokens)
        if tokens.index("hundred") != 1 or not 1 <= WORD_VALUES.get(tokens[0], -1) <= 9:
            return None
        tail = tokens[2:]
        if tail[:1] == ["and"]:
            tail = tail[1:]
        if not tail:
            return WORD_VALUES[tokens[0]] * 100
        rest = small(tail)
        return None if rest is None else WORD_VALUES[tokens[0]] * 100 + rest
    total = start = 0
    previous_scale = 10**15
    for i, word in enumerate(words):
        scale = {"thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000}.get(word)
        if scale is None:
            continue
        n = group(words[start:i])
        if scale >= previous_scale or n is None or n <= 0 or n > (1_000_000_000 - total) // scale:
            return None
        total += n * scale
        start, previous_scale = i + 1, scale
    tail = words[start:]
    if start and tail[:1] == ["and"]:
        tail = tail[1:]
    if not tail:
        return str(total) if start else None
    n = group(tail)
    return str(total + n) if n is not None and total + n <= 1_000_000_000 else None


def has_unit(after):
    return any(after.startswith(alias) and not (
        len(alias) == 1 and alias.isascii() and alias.isalpha()
        and after[len(alias):len(alias)+1].isascii() and after[len(alias):len(alias)+1].isalpha()
    ) for alias, _ in UNIT_ALIASES)


def count_mentions(text):
    found = []
    decimals = [match.span() for match in SPOKEN_DECIMAL.finditer(text)]
    for match in COUNT_NUMBER.finditer(text):
        if any(start < match.end() and end > match.start() for start, end in decimals):
            continue
        raw_before = text[max(0, match.start() - 12):match.start()]
        before, after = raw_before.strip(" \t"), text[match.end():match.end()+80].strip(" \t")
        if before.endswith(DESIGNATOR_PREFIXES) or raw_before[-1:].isupper() or (raw_before.endswith("-") and raw_before[-2:-1].isupper()):
            continue
        if has_unit(after) or has_unit(after.lower()):
            continue
        value = count_value(match.group())
        if value is None:
            continue
        if after[:1] in COUNT_SUFFIXES:
            first, rest = after[0], after[1:].strip(" \t")
            if first == "个" and rest.startswith(("半", "月", "年", "小时", "钟头", "百分点")):
                continue
            if first == "次" and rest.startswith("方"):
                continue
            if first == "位" and rest.startswith("于"):
                continue
            found.append((match.span(), (value, None, "count", match.group()+first)))
            continue
        if raw_before.endswith(NUMERIC_ATTRIBUTES):
            continue
        words = [word for word in after.lower().split(" ") if word][:4]
        while words and words[0] in COUNT_QUALIFIERS:
            words.pop(0)
        token = re.match(r"[A-Za-z]+", words[0]) if words else None
        noun = token.group() if token else ""
        if noun in COUNT_NOUNS or noun in COUNT_PLURALS:
            found.append((match.span(), (value, None, "count", match.group()+" "+noun)))
    return found


def numeric_mentions(text: str, preserving_count_scalars: bool = False) -> list[tuple[str, str | None, str, str]]:
    found = []
    counts = count_mentions(text)
    for match in re.finditer(r"[0-9]+(?:\.[0-9]+)?", text):
        if not preserving_count_scalars and any(start < match.end() and end > match.start() for (start, end), _ in counts):
            continue
        value = match.group()
        before, after = text[max(0, match.start() - 8):match.start()], text[match.end():match.end() + 10]
        if ((before[-1:].isalpha() and before[-1:].isupper())
                or (before.endswith("-") and before[-2:-1].isalpha() and before[-2:-1].isupper())
                or before.rstrip().endswith(DESIGNATOR_PREFIXES) or after.lstrip()[:1] in DESIGNATOR_SUFFIXES):
            found.append((value, None, "designator", f"编号{value}"))
            continue
        unit = next(((alias, family) for alias, family in UNIT_ALIASES
                     if after.lstrip(" ").startswith(alias)
                     and not (len(alias) == 1 and alias.isascii() and alias.isalpha()
                              and after.lstrip(" ")[len(alias):len(alias) + 1].isascii()
                              and after.lstrip(" ")[len(alias):len(alias) + 1].isalpha())), None)
        attribute = any(before.endswith(marker) for marker in NUMERIC_ATTRIBUTES)
        role = "measurement" if unit or attribute else "ambiguous"
        excerpt = value + unit[0] if unit else (before.strip() + value if attribute else value)
        found.append((value, unit[1] if unit else None, role, excerpt))
    return found + [mention for _, mention in counts]


def numeric_report(claim: str, cited: list[str], segment_texts: list[str],
                   batch_texts: list[str], *, target: str = CAPTION_TRANSLATION_TARGET,
                   language_groups: list[tuple[str, str]] = ()) -> tuple[bool, str | None]:
    def parse(text, source=False):
        if target not in ("es", "fr"):
            return numeric_mentions(text, preserving_count_scalars=source)
        from latin_learning import mentions
        languages = {language for language, original in language_groups if text in original} if source else {target}
        if len(languages) > 1:
            return []
        return list(mentions(text, next(iter(languages)) if languages else target, UNIT_ALIASES))
    own = [mention for text in cited + segment_texts for mention in parse(text, source=True)]
    batch = [mention for text in batch_texts for mention in parse(text, source=True)]
    gaps, decidable = [], False
    def push(message):
        if len(gaps) < 3 and message not in gaps:
            gaps.append(message)
    for value, unit, role, excerpt in parse(claim):
        if role == "designator":
            continue
        if role == "count":
            if any(m[0] == value and m[2] == "count" for m in own):
                continue
            location = ("本次原文的其他句子出现过相同数量，请确认是否该把那一句也列为来源。"
                        if any(m[0] == value and m[2] == "count" for m in batch)
                        else "同样的数字不一定表示同样的数量，请核对它是数量、目标值还是编号。")
            push(f"正文里的计数“{excerpt}”未在所引原句及同一字幕中找到计数支持；{location}")
            continue
        in_own = [m for m in own if m[0] == value and m[2] not in ("designator", "count")]
        in_batch = [m for m in batch if m[0] == value and m[2] not in ("designator", "count")]
        def conflict(others):
            families = "、".join(sorted({m[1] for m in others if m[1]})) or "无单位"
            return f"正文里的“{excerpt}”与原文中同一数字的单位不同（原文为 {families}）；请人工确认是换算、推导还是引用错位。"
        if role == "measurement" and unit:
            if any(m[1] == unit for m in in_own):
                continue
            if in_own:
                decidable = True
                push(conflict(in_own))
            elif any(m[1] == unit for m in in_batch):
                push(f"正文里的“{excerpt}”不在所引原句里；本次原文的其他句子出现过同样的数值，请确认是否该把那一句也列为来源。")
            elif in_batch:
                decidable = True
                push(conflict(in_batch))
            else:
                decidable = True
                push(f"正文里的“{excerpt}”在本次原文里找不到；请人工确认它对应的对象、条件和来源。")
        elif role == "measurement":
            if in_own:
                continue
            if in_batch:
                push(f"正文里的“{excerpt}”不在所引原句里；本次原文的其他句子出现过同样的数值，请确认是否该把那一句也列为来源。")
            else:
                decidable = True
                push(f"正文里的“{excerpt}”在本次原文里找不到同值；请人工确认它对应的对象、条件和来源。")
        elif not in_own and not in_batch:
            push(f"正文里的“{excerpt}”没有单位或属性说明，也没有出现在本次原文中；请人工确认它是编号还是测量值，并补上单位或来源。")
    return decidable, " ".join(gaps)[:240] or None


class IntegrityError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise IntegrityError(message)


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate-json-key:{key}")
        result[key] = value
    return result


def decode(data: str | bytes):
    def invalid_constant(value):
        raise IntegrityError(f"nonfinite-json:{value}")
    return json.loads(data, object_pairs_hook=no_duplicate_keys,
                      parse_constant=invalid_constant)


def load(path: Path) -> dict:
    value = decode(path.read_bytes())
    require(isinstance(value, dict), f"object-required:{path.name}")
    return value


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer(value, minimum=0) -> bool:
    return type(value) is int and value >= minimum


def uid(value) -> str:
    require(isinstance(value, str), "uuid-string-required")
    try:
        canonical = str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise IntegrityError("invalid-uuid") from error
    require(value == canonical, "uuid-not-canonical")
    return canonical


def object_list(value, name: str) -> list[dict]:
    require(isinstance(value, list) and all(isinstance(x, dict) for x in value), f"{name}:object-array-required")
    return value


def unique(values: list, name: str) -> None:
    require(len(values) == len(set(values)), f"{name}:duplicate")


def frozen_sources(case: dict, through_stage: int) -> list[dict]:
    require(integer(through_stage, 1) and through_stage <= len(case["stages"]), "stage-out-of-range")
    sources = []
    for stage, rows in enumerate(case["stages"][:through_stage]):
        for index, row in enumerate(rows):
            raw = hashlib.sha256(f"{case['id']}/{stage}/{index}".encode()).hexdigest()[:32]
            start = len(sources) * 12
            sources.append({"id": str(uuid.UUID(raw)).upper(), "english": row["english"], "chinese": row["chinese"],
                            "startTime": start, "endTime": start + 10, "inputRevision": 0})
    return sources


def source_ids(case: dict, through_stage: int) -> set[str]:
    return {x["id"] for x in frozen_sources(case, through_stage)}


def verify_source(actual: dict, expected: dict, representation: str) -> None:
    for key in ("id", "english", "chinese", "startTime", "endTime"):
        require(actual.get(key) == expected[key] and not isinstance(actual.get(key), bool), f"source-mismatch:{key}")
    for key in ("startTime", "endTime"):
        require(isinstance(actual[key], (int, float)) and math.isfinite(actual[key]), f"source-time:{key}")
    require(actual.get("sessionID") is None, "source-session-mismatch")
    if representation == "revisioned":
        require(type(actual.get("inputRevision")) is int and actual["inputRevision"] == 0, "source-revision-mismatch")
        require(actual.get("translationState") == "completed" and actual.get("translationError") is None,
                "source-translation-state-mismatch")
    else:
        require("inputRevision" not in actual and "translationState" not in actual, "legacy-source-fields-mismatch")


def open_question(point: dict) -> bool:
    question = point.get("needsContext")
    require(question is None or isinstance(question, str), "needsContext-type")
    return point.get("kind") == "待确认" or bool(question and question.strip() and question.strip() != NUMERIC_CONTEXT)


def followup_state_label(state: str, *, target: str = CAPTION_TRANSLATION_TARGET) -> str:
    """Display only; wire follow-up states remain their fixed Chinese codes."""
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    return FOLLOWUP_DISPLAY_LABELS_LATIN.get(target, {}).get(state, state)


def point_line(point: dict, *, target: str = CAPTION_TRANSLATION_TARGET) -> str:
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    kind = point["kind"]
    if target != "zh-Hans":
        kind_label = KIND_DISPLAY_LABELS_LATIN[target].get(kind, kind)
        if open_question(point):
            pending = KIND_DISPLAY_LABELS_LATIN[target]["待确认"]
            label = pending if kind in ("", "核心结论", "待确认") else f"{kind_label} ({pending})"
            return f"- **{label}**: {point['text']}"
        return "- " + ("" if kind == "核心结论" else f"**{kind_label}**: ") + point["text"]
    if open_question(point):
        label = "待确认" if kind in ("核心结论", "待确认") else kind + "（待确认）"
        return f"- **{label}**：{point['text']}"
    return "- " + ("" if kind == "核心结论" else f"**{kind}**：") + point["text"]


def validate_note(note: dict) -> None:
    require(isinstance(note, dict), "note-object-required")
    topic = note.get("topic")
    require(isinstance(topic, str) and topic.strip() and len(topic) <= 80
            and "\n" not in topic and "<|" not in topic, "invalid-topic")
    require(type(note.get("sourceVersion")) is int and note["sourceVersion"] == 2, "invalid-source-version")
    points = object_list(note.get("points"), "points")
    require(type(note.get("noNewKnowledge")) is bool, "noNewKnowledge-type")
    require(len(points) <= 24 and (not points if note["noNewKnowledge"] else bool(points)), "empty-or-excess-points")
    for point in points:
        text = point.get("text")
        require(point.get("kind") in KINDS and isinstance(text, str) and text.strip()
                and len(text) <= 2400 and "<|" not in text and "<think>" not in text, "invalid-point")
        open_question(point)


def has_usable_translation(source: dict) -> bool:
    chinese = source.get("chinese", "")
    return (isinstance(chinese, str) and bool(chinese.strip())
            and not chinese.strip().startswith("[翻译失败：")
            and source.get("translationState") in (None, "completed"))


def source_language(source: dict) -> str | None:
    stored = source.get("sourceLanguage")
    if stored is not None:
        # An unknown explicit marker is English, never legacy Chinese inference.
        return stored if isinstance(stored, str) and stored in SPOKEN_LANGUAGE_CODES and stored != "en" else None
    if has_usable_translation(source) and source["english"] == source["chinese"]:
        scalars = [ord(c) for c in source["english"].strip()]
        han = sum(any(start <= c <= end for start, end in LEGACY_HAN_RANGES) for c in scalars)
        latin = sum(any(start <= c <= end for start, end in LEGACY_LATIN_RANGES) for c in scalars)
        if han and latin < max(LEGACY_MIN_LATIN_COUNT, han * LEGACY_LATIN_PER_HAN):
            return "zh"
    return None


def render_pass_through(text: str, *, target: str = CAPTION_TRANSLATION_TARGET) -> str:
    """Use the system transform behind Swift's SimplifiedChineseNormalizer.

    No optional Python package or subprocess receives caption text. If the
    system API is unavailable, withhold integrity credit rather than guess.
    """
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    if target != "zh-Hans":
        return text
    import ctypes
    import ctypes.util

    require(target == "zh-Hans", "unsupported-caption-target")
    library = ctypes.util.find_library("CoreFoundation") if sys.platform == "darwin" else None
    require(bool(library), "pass-through-normalizer-unavailable")

    class CFRange(ctypes.Structure):
        _fields_ = [("location", ctypes.c_long), ("length", ctypes.c_long)]

    pointer, index = ctypes.c_void_p, ctypes.c_long
    characters = ctypes.POINTER(ctypes.c_uint16)
    signatures = {
        "CFStringCreateMutable": (pointer, [pointer, index]),
        "CFStringAppendCharacters": (None, [pointer, characters, index]),
        "CFStringCreateWithCString": (pointer, [pointer, ctypes.c_char_p, ctypes.c_uint32]),
        "CFStringTransform": (ctypes.c_bool, [pointer, pointer, pointer, ctypes.c_bool]),
        "CFStringGetLength": (index, [pointer]),
        "CFStringGetCharacters": (None, [pointer, CFRange, characters]),
        "CFRelease": (None, [pointer]),
    }
    try:
        core = ctypes.CDLL(library)
        for name, (result, arguments) in signatures.items():
            function = getattr(core, name)
            function.restype, function.argtypes = result, arguments
    except (OSError, AttributeError):
        raise IntegrityError("pass-through-normalizer-unavailable") from None

    encoding = "utf-16-le" if sys.byteorder == "little" else "utf-16-be"
    encoded = text.encode(encoding)
    source = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
    mutable = core.CFStringCreateMutable(None, 0)
    transform = core.CFStringCreateWithCString(None, CAPTION_PASS_THROUGH_TRANSFORM.encode("ascii"), 0x08000100)
    try:
        require(bool(mutable and transform), "pass-through-normalization-failed")
        core.CFStringAppendCharacters(mutable, source, len(source))
        # Swift's applyingTransform also returns the original text on failure.
        if not core.CFStringTransform(mutable, None, transform, False):
            return text
        length = core.CFStringGetLength(mutable)
        output = (ctypes.c_uint16 * length)()
        core.CFStringGetCharacters(mutable, CFRange(0, length), output)
        return bytes(output).decode(encoding)
    finally:
        for value in (mutable, transform):
            if value:
                core.CFRelease(value)


def source_text_groups(source: dict, *, target: str = CAPTION_TRANSLATION_TARGET) -> list[tuple[str, str]]:
    """Mirror LearningSourceUnit.textGroups without renaming legacy storage fields."""
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    language_code = source_language(source)
    if target == "en":
        # English pass-through always uses the source, even when a usable old
        # Chinese counterpart remains. Other sources use saved target evidence.
        text = (render_pass_through(source["english"], target=target) if language_code is None
                else source.get("chinese", ""))
        return [("en", text)]
    if target in ("es", "fr"):
        from latin_learning import pass_through_sources
        if language_code in pass_through_sources()[target]:
            return [(target, source["english"])]
        if language_code is None:
            return [("en", source["english"]), (target, source.get("chinese", ""))]
        return [(target, source.get("chinese", ""))]
    groups = (("en", "english"), ("zh", "chinese")) if language_code is None else (("zh", "chinese"),)
    return [(language, (source["chinese"] if has_usable_translation(source)
                       else render_pass_through(source["english"], target=target))
             if language_code in CAPTION_PASS_THROUGH_LANGUAGE_CODES else source[key])
            for language, key in groups]


def verify_units(units: list[dict], evidence: list[dict], *,
                 target: str = CAPTION_TRANSLATION_TARGET) -> dict[str, dict]:
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    units = object_list(units, "sourceUnits")
    unique([x.get("id") for x in units], "sourceUnits")
    require(all(integer(x.get("index")) and x["index"] < len(evidence) and x.get("language") in (("en", "zh", target) if target in ("es", "fr") else ("en", "zh"))
                for x in units), "source-unit-owner")
    expected_order = []
    for index, source in enumerate(evidence):
        for language, original in source_text_groups(source, target=target):
            fragments = [x for x in units if x["index"] == index and x["language"] == language]
            require(bool(fragments), "missing-source-language")
            cursor = 0
            for number, fragment in enumerate(fragments):
                expected_id = f"{language}{index}s{number}"
                require(fragment["id"] == expected_id, "source-unit-sequence")
                expected_order.append(expected_id)
                text = fragment.get("text")
                require(isinstance(text, str) and bool(text.strip()), "empty-source-unit")
                while cursor < len(original) and original[cursor].isspace():
                    cursor += 1
                require(original.startswith(text, cursor), "source-unit-body-or-order")
                cursor += len(text)
            require(not original[cursor:].strip(), "source-units-drop-content")
    require([x["id"] for x in units] == expected_order, "source-unit-order")
    return {x["id"]: x for x in units}


def artifact(directory: Path, name, expected_digest) -> bytes:
    require(isinstance(name, str) and Path(name).name == name and name not in ("", ".", ".."), "artifact-path")
    path = directory / name
    require(path.is_file() and not path.is_symlink() and path.resolve().parent == directory.resolve(), f"artifact-missing:{name}")
    data = path.read_bytes()
    require(isinstance(expected_digest, str) and hashlib.sha256(data).hexdigest() == expected_digest, f"artifact-hash:{name}")
    return data


def rendered_contains(line: str, placement: str, markdown: str, *,
                      target: str = CAPTION_TRANSLATION_TARGET) -> bool:
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    # Kind/state display follows the target; classroom headings/wrappers retain
    # ClassroomFixedText's single switch, whose current default is Chinese.
    current, lines = "body", []
    for part in markdown.split("\n"):
        if part.startswith("## "):
            title = part[3:]
            current = "replay" if title == "需要回听" else "advisory" if title in ("来源检查", "课程安排与待办") else "body"
            lines.append("")
        else:
            lines.append(part.strip() if current == placement else "")
    wanted = [x.strip() for x in line.split("\n")]
    return any(lines[i:i + len(wanted)] == wanted for i in range(len(lines) - len(wanted) + 1))


def retired_questions(batches: list[dict]) -> set[str]:
    retired: set[str] = set()
    for batch in batches:
        points = batch["note"]["points"]
        for record in batch.get("followUps") or []:
            target, state, index = record.get("target"), record.get("state"), record.get("pointIndex")
            if not isinstance(target, str):
                continue
            if state == "后文补充" and integer(index) and index < len(points) and points[index].get("sources"):
                retired.add(target)
            elif state in ("前后冲突", "关系不明"):
                retired.discard(target)
    return retired


def placements(batches: list[dict], latest=False) -> dict[str, str]:
    all_points = {f"{b['id']}:{i}": p for b in batches for i, p in enumerate(b['note']['points'])}
    retired = retired_questions(batches)
    visible = {f"{b['id']}:{i}" for b in (batches[-1:] if latest else batches) for i in range(len(b['note']['points']))}
    children: dict[str, list[str]] = {}
    for reference in visible:
        parent = all_points[reference].get("clarifies")
        if parent:
            children.setdefault(parent, []).append(reference)
    def has_question(reference, seen=frozenset()):
        require(reference not in seen, "clarifies-cycle")
        point = all_points[reference]
        parent = all_points.get(point.get("clarifies"))
        return (False if reference in retired else
                open_question(point) or (parent is not None and point.get("clarifies") not in retired and open_question(parent))
                or any(has_question(x, seen | {reference}) for x in children.get(reference, [])))
    result = {}
    for reference in all_points:
        if reference not in visible:
            result[reference] = "hidden"
            continue
        root, seen = reference, set()
        while all_points[root].get("clarifies") in visible:
            require(root not in seen, "clarifies-cycle")
            seen.add(root)
            root = all_points[root]["clarifies"]
        result[reference] = "replay" if has_question(root) else "body"
    return result


def verify_pending_points(prepared: dict, targets: list[str], references: dict[str, dict],
                          reference_batches: dict[str, dict], units: dict[str, dict], *,
                          target: str = CAPTION_TRANSLATION_TARGET) -> None:
    followups = object_list(prepared.get("pendingPoints"), "pendingPoints")
    require([p.get("id") for p in followups] == [f"q{i}" for i in range(len(targets))], "pending-alias-order")
    indexed = ("priorEvidence" in prepared or "pendingEvidenceRule" in prepared
               or any("quoteIDs" in p or "candidateQuoteIDs" in p for p in followups))
    catalog = None
    if indexed:
        accepted_rules = ((PENDING_EVIDENCE_RULE, PENDING_EVIDENCE_RULE_EN) if target == "en"
                          else (PENDING_EVIDENCE_RULE_LATIN[target],) if target in ("es", "fr")
                          else (PENDING_EVIDENCE_RULE,))
        require(prepared.get("pendingEvidenceRule") in accepted_rules, "pending-evidence-rule")
        prior = object_list(prepared.get("priorEvidence"), "priorEvidence")
        require(all(isinstance(p.get("id"), str) and re.fullmatch(r"h(?:0|[1-9][0-9]*)", p["id"])
                    and p.get("scope") == "prior" and isinstance(p.get("text"), str) and p["text"].strip()
                    for p in prior), "prior-evidence-shape")
        unique([p["id"] for p in prior], "prior-evidence-ID")
        catalog = {key: unit["text"] for key, unit in units.items()}
        catalog.update({p["id"]: p["text"] for p in prior})

    def texts(followup, key, id_key):
        if catalog is None:
            return followup.get(key)
        require(followup.get(key) == [], "indexed-pending-inline-quotes")
        ids = followup.get(id_key)
        require(isinstance(ids, list) and all(isinstance(x, str) and x in catalog for x in ids),
                f"pending-{id_key}-unknown-or-invalid")
        unique(ids, f"pending-{id_key}")
        # One frozen candidate can name several identical current fragments.
        # Bound the number of distinct quoted texts, not the expanded ID list.
        return list(dict.fromkeys(catalog[x] for x in ids))

    for followup, reference in zip(followups, targets):
        old = references[reference]
        eligible = old.get("referenceState") in ("pending", "awaitingContext", "numericDifference") or bool(old.get("needsContext")) or (old.get("sourceHasPronoun") is True and old.get("referenceState") == "linked")
        require(eligible, "pending-target-not-eligible")
        quotes = texts(followup, "quotes", "quoteIDs")
        original_quotes = [s["quote"] for s in old.get("sources", [])]
        if not original_quotes:
            original_quotes = []
            for source in reference_batches[reference]["evidence"]:
                language = source_language(source) if indexed else None
                if target == "en":
                    text = source_text_groups(source, target=target)[0][1]
                elif target in ("es", "fr"):
                    original_quotes.extend(text for _, text in source_text_groups(source, target=target) if text)
                    continue
                elif language in CAPTION_PASS_THROUGH_LANGUAGE_CODES:
                    text = source["chinese"] if has_usable_translation(source) else render_pass_through(source["english"])
                elif language is not None:
                    text = source["chinese"]
                else:
                    text = source["english"] or source["chinese"]
                original_quotes.append(text)
        require(isinstance(quotes, list) and quotes and len(quotes) <= 2
                and all(isinstance(q, str) and q and any(s.startswith(q) for s in original_quotes) for q in quotes),
                "pending-quotes-not-bound-to-target")
        candidates = texts(followup, "candidateQuotes", "candidateQuoteIDs")
        candidate_sources = [s["quote"] for p in references.values() if p.get("clarifies") == reference
                             for s in p.get("sources", [])]
        require(isinstance(candidates, list) and len(candidates) <= 2
                and all(isinstance(q, str) and q and any(s.startswith(q) for s in candidate_sources) for q in candidates),
                "pending-candidate-quotes-not-bound")
        require(type(followup.get("referenceCheck")) is bool, "pending-referenceCheck-type")


def verify_followups(raw: dict, normalized: dict, batch: dict, targets: list[str],
                     units: dict[str, dict], revision: int) -> None:
    aliases = [f"q{i}" for i in range(len(targets))]
    model = raw.get("followUps")
    if model is not None:
        require(isinstance(model, dict) and set(model) == set(aliases), "model-followup-alias-set")
        for record in model.values():
            require(isinstance(record, dict) and record.get("state") in FOLLOWUP_STATES
                    and isinstance(record.get("detail"), str), "model-followup-shape")
            ids = record.get("sourceIDs")
            require(isinstance(ids, list) and len(ids) <= 2
                    and all(isinstance(x, str) and x in units for x in ids), "model-followup-sources")
            require(not (set(record) - {"state", "sourceIDs", "detail", "pointIndex"}),
                    "model-followup-extra-fields")
    resolved = normalized.get("followUps") or []
    committed = batch.get("followUps") or []
    require(not batch["note"].get("followUps"), "followup-must-live-on-batch")
    # Older frozen probes had no follow-up records. They remain historical
    # evidence; a new response cannot silently claim a supplemented target.
    if model is None and not resolved and not committed:
        return
    require(isinstance(resolved, list) and isinstance(committed, list)
            and len(resolved) == len(committed) == len(targets), "followup-record-count")
    for index, (prepared, saved) in enumerate(zip(resolved, committed)):
        for record in (prepared, saved):
            ids = record.get("sourceIDs") if isinstance(record, dict) else None
            require(not (isinstance(ids, list) and any(isinstance(x, str) and x.startswith("h") for x in ids)),
                    "historical-followup-source-ID")
        alias, target = aliases[index], targets[index]
        raw_item = model.get(alias) if model is not None else None
        expected_state = raw_item["state"] if raw_item is not None else "缺信息"
        require(isinstance(prepared, dict) and prepared.get("alias") == alias
                and prepared.get("target") == target and prepared.get("state") == expected_state,
                "resolved-followup-binding")
        if raw_item is not None:
            require(prepared.get("sourceIDs") == (raw_item.get("sourceIDs") or None)
                    and prepared.get("detail") == raw_item["detail"][:240].strip(),
                    "resolved-followup-content")
        require(isinstance(saved, dict) and saved.get("alias") == alias and saved.get("target") == target
                and saved.get("evidenceIDs") == [s["id"] for s in batch["evidence"]]
                and saved.get("notebookRevision") == revision,
                "committed-followup-binding")
        require(saved.get("state") in FOLLOWUP_STATES and isinstance(saved.get("detail"), str)
                and bool(saved["detail"].strip()), "committed-followup-content")
        if expected_state != "后文补充":
            require(saved["state"] == expected_state, "followup-state-changed-without-support")
        else:
            require(saved["state"] in ("后文补充", "关系不明"), "followup-invalid-downgrade")
        if saved["state"] == "后文补充":
            point_index = saved.get("pointIndex")
            require(integer(point_index) and point_index < len(batch["note"]["points"]),
                    "supplement-point-index")
            point = batch["note"]["points"][point_index]
            ids = point.get("sourceIDs")
            require(bool(point.get("sources")) and not open_question(point)
                    and point.get("referenceState") != "unlinked" and saved.get("sourceIDs") == ids,
                    "supplement-without-bound-evidence")


def verify_result(case: dict, result: dict, directory: Path, fixture_sha: str,
                  *, allow_synthetic: bool = False,
                  target: str = CAPTION_TRANSLATION_TARGET) -> list[dict]:
    require(type(result.get("probeVersion")) is int and result["probeVersion"] == 2, "probe-v2-required; old output retained as legacy evidence")
    require(result.get("fixtureID") == case["id"] and result.get("fixtureSHA256") == fixture_sha, "fixture-binding-mismatch")
    require(artifact(directory, "fixture.json", fixture_sha) is not None, "fixture-artifact")
    require(result.get("error") is None, "probe-reported-error")
    require(isinstance(result.get("model"), str) and bool(result["model"]), "model-identity-required")
    producer = result.get("producer")
    require(isinstance(producer, dict), "producer-required")
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    require(producer.get("targetLocale", CAPTION_TRANSLATION_TARGET) == target,
            "producer-target-mismatch")
    for key in ("executableSHA256", "promptSHA256"):
        require(isinstance(producer.get(key), str) and re.fullmatch(r"[a-f0-9]{64}", producer[key]), f"producer:{key}")
    origin = producer.get("generationOrigin")
    require(origin == "production-model" or (allow_synthetic and origin == "synthetic-regression"),
            "synthetic-or-unknown-origin-is-not-model-evidence")
    if origin == "production-model" or producer.get("buildManifestSHA256") is not None:
        build = decode(artifact(directory, "quality-build-manifest.json", producer.get("buildManifestSHA256")))
        require(isinstance(build, dict) and build.get("executableSHA256") == producer["executableSHA256"]
                and build.get("sourcesUnchangedDuringBuild") is True and type(build.get("exitCode")) is int
                and build["exitCode"] == 0, "build-manifest-identity-or-status")
        hashes = build.get("sourceHashes")
        require(isinstance(hashes, dict) and {"Scripts/learning-quality-cli.swift", "LiveLingo/Sources/LearningNotes.swift"}.issubset(hashes)
                and all(isinstance(k, str) and not Path(k).is_absolute() and ".." not in Path(k).parts
                        and isinstance(v, str) and re.fullmatch(r"[a-f0-9]{64}", v) for k, v in hashes.items()),
                "build-source-manifest-required")
        require(build.get("purpose") == ("production-quality-probe" if origin == "production-model" else "synthetic-regression-tests"),
                "build-purpose-origin-mismatch")
    representation = producer.get("sourceRepresentation")
    require(representation in ("legacy", "revisioned") and producer.get("sourcePolicy") == SOURCE_POLICY, "source-policy")
    require(producer.get("displayContract") == DISPLAY_CONTRACT and integer(producer.get("batchCharacters"), 1), "producer-contract")
    stages = object_list(result.get("stages"), "stages")
    numbers = [s.get("number") for s in stages]
    require(all(integer(n, 1) for n in numbers) and numbers == list(range(1, len(case["stages"]) + 1)), "stages-must-be-exactly-1-through-N-in-order")
    requests = object_list(result.get("requests"), "requests")
    require([r.get("number") for r in requests] == list(range(1, len(requests) + 1))
            and all(integer(r.get("number"), 1) for r in requests), "request-number-sequence")
    require(integer(result.get("requestedRequests")) and result["requestedRequests"] == len(requests), "requested-count-mismatch")
    require(integer(result.get("successfulRequests")) and result["successfulRequests"] == len(requests)
            and all(r.get("outcome") == "committed" and r.get("error") is None for r in requests), "successful-count-or-outcome-mismatch")
    previous, references, reference_batches, request_index, output_rows = [], {}, {}, 0, []
    last_elapsed = 0
    for stage in stages:
        number = stage["number"]
        require(stage.get("error") is None, "stage-reported-error")
        elapsed = stage.get("elapsedSeconds")
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= last_elapsed, "stage-elapsed-time")
        last_elapsed = elapsed
        batches = object_list(stage.get("batches"), "batches")
        require(len(batches) > len(previous) and batches[:len(previous)] == previous, "historical-batch-prefix-changed-or-stage-no-progress")
        unique([uid(b.get("id")) for b in batches], "batch-ID")
        expected_rows = frozen_sources(case, number)
        expected = {x["id"]: x for x in expected_rows}
        covered = stage.get("coveredSourceIDs")
        require(isinstance(covered, list), "covered-source-array")
        unique([uid(x) for x in covered], "covered-source-ID")
        require(set(covered) == set(expected), "covered-source-set")
        evidence_ids = []
        for batch in batches:
            for source in object_list(batch.get("evidence"), "evidence"):
                sid = uid(source.get("id"))
                require(sid in expected, "source-ID-not-in-frozen-stage")
                verify_source(source, expected[sid], representation)
                evidence_ids.append(sid)
        require(evidence_ids == [x["id"] for x in expected_rows], "evidence-order-duplicate-or-missing")
        for batch in batches[len(previous):]:
            require(request_index < len(requests), "missing-request-for-batch")
            request = requests[request_index]; request_index += 1
            require(integer(request.get("stage"), 1) and request["stage"] == number, "request-stage-mismatch")
            require(request.get("batchID") == batch["id"] and request.get("evidence") == batch["evidence"], "request-batch-binding")
            units = verify_units(request.get("sourceUnits"), batch["evidence"], target=target)
            require(request.get("inputFile") == f"input-{request_index}.json"
                    and request.get("responseFile") == f"response-{request_index}.txt", "request-artifact-number")
            prepared = decode(artifact(directory, request.get("inputFile"), request.get("inputSHA256")))
            require(isinstance(prepared, dict) and prepared.get("evidence") == request["sourceUnits"], "request-input-source-mismatch")
            targets = request.get("pendingTargets")
            require(isinstance(targets, list) and len(targets) <= 4 and all(isinstance(x, str) and x in references for x in targets), "pending-target-unknown-or-forward")
            unique(targets, "pending-target")
            require(not set(targets) & retired_questions(batches[:batches.index(batch)]),
                    "pending-target-already-retired")
            verify_pending_points(prepared, targets, references, reference_batches, units, target=target)
            raw = decode(artifact(directory, request.get("responseFile"), request.get("responseSHA256")))
            normal = request.get("normalizedNote")
            validate_note(raw); validate_note(normal); validate_note(batch.get("note"))
            verify_followups(raw, normal, batch, targets, units, request_index - 1)
            note = batch["note"]
            require(raw["noNewKnowledge"] == normal["noNewKnowledge"] == note["noNewKnowledge"]
                    and normal["topic"] == note["topic"] and len(raw["points"]) == len(normal["points"]) == len(note["points"]), "normalized-note-shape-mismatch")
            # Default Chinese retains both storage columns. English uses the
            # same selected target evidence as source units, including support
            # from other fragments in the owning segment or the current batch.
            segment_texts = [([source["english"], source["chinese"]] if target == "zh-Hans"
                              else [text for _, text in source_text_groups(source, target=target)])
                             for source in batch["evidence"]]
            all_segments = [text for texts in segment_texts for text in texts]
            for index, (raw_point, normalized, point) in enumerate(zip(raw["points"], normal["points"], note["points"])):
                require(raw_point["kind"] == normalized["kind"] == point["kind"] and normalized["text"] == point["text"], "normalized-point-mismatch")
                ids = point.get("sourceIDs")
                require(isinstance(ids, list) and len(ids) <= 2 and all(isinstance(x, str) and x in units for x in ids), "point-source-ID-invalid")
                unique(ids, "point-source-ID")
                require(raw_point.get("sourceIDs") == normalized.get("sourceIDs") == ids, "raw-point-source-ID-mismatch")
                require(ids or point["kind"] == "补充理解", "point-provenance-missing; factual-correctness-undecided")
                linked = [{"index": units[x]["index"], "quote": units[x]["text"]} for x in ids]
                require(point.get("sources", []) == linked, "point-bound-quote-mismatch")
                require(raw_point.get("needsContext") == normalized.get("needsContext"), "raw-question-changed-before-binding")
                # Production binding trims/caps question text, or supplies its exact
                # numeric advisory. Do not let a forged state hide a real question.
                question = (normalized.get("needsContext") or "")[:240].strip()
                owner_indices = sorted({s["index"] for s in linked})
                own_segments = [text for owner in owner_indices
                                for text in segment_texts[owner]]
                difference, gap = numeric_report(point["text"], [s["quote"] for s in linked],
                                                  own_segments, all_segments, target=target,
                                                  language_groups=[group for source in batch["evidence"]
                                                                   for group in source_text_groups(source, target=target)])
                if not linked and point["kind"] == "补充理解":
                    state = None
                elif question:
                    state = "awaitingContext"
                elif difference:
                    state, question = "numericDifference", NUMERIC_CONTEXT
                else:
                    state = "linked"
                require(point.get("referenceState") == state and (point.get("needsContext") or "") == question,
                        "point-binding-question-or-state-mismatch")
                expected_gap = gap if linked and state in ("linked", "numericDifference") else None
                require(point.get("numericGap") == expected_gap, "point-numeric-gap-mismatch")
                alias = raw_point.get("clarifies")
                expected_target = None
                if alias is not None:
                    require(isinstance(alias, str) and re.fullmatch(r"q(?:0|[1-9][0-9]*)", alias), "raw-followup-alias")
                    n = int(alias[1:]); require(n < len(targets), "raw-followup-target-out-of-range")
                    expected_target = targets[n]
                require(normalized.get("clarifies") == expected_target and point.get("clarifies") == expected_target, "clarifies-target-mismatch")
                require(expected_target is None or (expected_target in references and bool(linked)), "clarifies-unbound-or-forward")
            # Only earlier batches may supply targets, not earlier points in this batch.
            references.update({f"{batch['id']}:{i}": p for i, p in enumerate(note["points"])})
            reference_batches.update({f"{batch['id']}:{i}": batch for i in range(len(note["points"]))})
        require(type(stage.get("requestedRequests")) is int and type(stage.get("successfulRequests")) is int
                and stage["requestedRequests"] == stage["successfulRequests"] == request_index, "stage-request-count")
        full, latest = stage.get("markdown"), stage.get("latestMarkdown")
        require(isinstance(full, str) and isinstance(latest, str), "markdown-fields-required")
        saved = directory / f"notes-stage-{number}.md"
        require(saved.is_file() and not saved.is_symlink() and saved.read_text(encoding="utf-8") == full, "saved-markdown-mismatch")
        displays = object_list(stage.get("displayPoints"), "displayPoints")
        expected_references = [f"{b['id']}:{i}" for b in batches for i in range(len(b['note']['points']))]
        require([p.get("reference") for p in displays] == expected_references, "display-points-order-or-count")
        full_places, latest_places = placements(batches), placements(batches, latest=True)
        rows = []
        for display in displays:
            reference = display["reference"]; point = references[reference]
            require(type(display.get("hasOpenQuestion")) is bool and display["hasOpenQuestion"] == open_question(point), "production-question-mismatch")
            require(display.get("resolvedClarifies") == point.get("clarifies"), "display-followup-mismatch")
            line = point_line(point, target=target)
            require(display.get("renderedLine") == line, "rendered-point-line-mismatch")
            for key, places, markdown in (("fullDisposition", full_places, full), ("latestDisposition", latest_places, latest)):
                placement = places[reference]
                require(display.get(key) == placement, "production-placement-mismatch")
                require(placement == "hidden" or rendered_contains(line, placement, markdown, target=target), "point-missing-from-rendered-section")
            flags = []
            if UNASSERTED.search(point["text"]): flags.append("unasserted-or-warning-preface")
            if DENIAL.search(point["text"]): flags.append("explicit-denial-requires-semantic-readback")
            rows.append({**point, **display, "semanticRiskFlags": flags,
                         "eligibleBodySignal": display["fullDisposition"] == "body" and not flags and bool(point.get("sources"))})
        output_rows.append({"number": number, "points": rows})
        previous = batches
    require(request_index == len(requests), "extra-request-without-batch")
    return output_rows


def evaluate_case(case_gold: dict, case: dict, result: dict, *, directory: Path | None = None,
                  fixture_sha: str | None = None, allow_synthetic: bool = False,
                  target: str = CAPTION_TRANSLATION_TARGET) -> dict:
    facts = [{"id": f["id"], "meaning": f["meaning"], "stage": f["stage"], "coverageSignal": False,
              "lexicalSignal": False, "matchedPointReferences": [], "semanticStatus": PENDING} for f in case_gold["facts"]]
    report = {"id": case["id"], "split": case_gold["split"], "categories": case_gold["categories"],
              "facts": facts, "integrityStatus": "failed", "checks": [], "semanticCorrectness": PENDING,
              "semanticRequirements": [], "pointReadback": {}}
    try:
        require(directory is not None and fixture_sha is not None, "frozen-source-and-artifact-directory-required")
        stages = verify_result(case, result, directory, fixture_sha,
                               allow_synthetic=allow_synthetic, target=target)
        if minimum := case_gold.get("minimumRequests"):
            require(result["successfulRequests"] >= minimum, "overflow-request-minimum")
        report["integrityStatus"] = "pass"
        report["checks"].append({"name": "complete-probe-source-request-and-render-contract", "passed": True})
        by_number = {s["number"]: s["points"] for s in stages}
        report["pointReadback"] = {str(k): v for k, v in by_number.items()}
        for expected, fact in zip(case_gold["facts"], facts):
            rows = by_number[expected["stage"]]
            matches = [p for p in rows if any(re.search(pattern, p["text"], flags=re.I) for pattern in expected["patterns"])]
            fact["lexicalSignal"] = bool(matches)
            eligible = [p for p in matches if p["eligibleBodySignal"]]
            fact["coverageSignal"] = bool(eligible)
            fact["matchedPointReferences"] = [p["reference"] for p in eligible]
        for key in ("requiresQuestionAtStage", "requiresFollowUpAtStage", "requiresEmptyStage"):
            if number := case_gold.get(key):
                rows = by_number[number]
                witness = ([p["reference"] for p in rows if p["hasOpenQuestion"]] if key == "requiresQuestionAtStage"
                           else [p["reference"] for p in rows if p.get("resolvedClarifies")] if key == "requiresFollowUpAtStage"
                           else [])
                report["semanticRequirements"].append({"requirement": key, "stage": number, "status": PENDING,
                    "candidateWitnessReferences": witness,
                    "structuralWitnessPresent": not rows if key == "requiresEmptyStage" else bool(witness),
                    "pointReferences": [p["reference"] for p in rows]})
        report["producer"] = result["producer"]
        report["requestedRequests"] = result["requestedRequests"]
        report["successfulRequests"] = result["successfulRequests"]
    except (IntegrityError, ValueError, TypeError, KeyError, OSError) as error:
        report["integrityStatus"] = "failed"
        report["error"] = str(error)
        report["checks"].append({"name": "complete-probe-source-request-and-render-contract", "passed": False, "reason": str(error)})
        for fact in facts:
            fact["coverageSignal"] = False
    report["coverageStatus"] = "signals-awaiting-semantic-readback" if any(f["coverageSignal"] for f in facts) else "no-valid-body-signals"
    return report


def score(corpus: Path, results: Path, *, allow_synthetic: bool = False,
          target: str = CAPTION_TRANSLATION_TARGET) -> dict:
    require(target in CAPTION_TRANSLATION_TARGETS, "unsupported-caption-target")
    manifest = load(corpus / "manifest.json")
    entries = object_list(manifest.get("files"), "manifest-files")
    names = [entry.get("file") for entry in entries]
    require(all(isinstance(name, str) and Path(name).name == name for name in names), "manifest-filename")
    unique(names, "manifest-file")
    entries = {entry["file"]: entry for entry in entries}
    require("gold.json" in entries, "gold-not-frozen")
    for name, entry in entries.items():
        require(digest(corpus / name) == entry.get("sha256"), f"frozen-corpus-changed:{name}")
    gold = load(corpus / "gold.json")
    require(gold.get("targetLocale", target) == target, "gold-target-mismatch")
    cases = object_list(gold.get("cases"), "gold-cases")
    require(bool(cases), "empty-gold")
    require(all(isinstance(c.get("id"), str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", c["id"])
                and isinstance(c.get("split"), str) and c["split"] for c in cases), "invalid-gold-case-identity")
    unique([c["id"] for c in cases], "gold-case")
    require(set(entries) == {"gold.json", *(c["id"] + ".json" for c in cases)}, "manifest-case-set")
    reports = []
    for expected in cases:
        name = expected["id"] + ".json"
        case = load(corpus / name)
        require(case["id"] == expected["id"], "fixture-id-mismatch")
        require(isinstance(case.get("stages"), list) and case["stages"], "fixture-stages-required")
        for rows in case["stages"]:
            require(object_list(rows, "fixture-stage") and all(isinstance(r.get(k), str) and r[k].strip()
                    for r in rows for k in ("english", "chinese")), "fixture-source-content")
        facts = object_list(expected.get("facts"), "gold-facts")
        unique([f.get("id") for f in facts], "gold-fact-ID")
        for fact in facts:
            require(integer(fact.get("stage"), 1) and fact["stage"] <= len(case["stages"]), "gold-fact-stage")
            require(isinstance(fact.get("patterns"), list) and fact["patterns"]
                    and all(isinstance(p, str) for p in fact["patterns"]), "gold-fact-patterns")
            for pattern in fact["patterns"]: re.compile(pattern)
        directory = results / expected["id"]
        try:
            result = load(directory / "result.json")
            report = evaluate_case(expected, case, result, directory=directory, fixture_sha=entries[name]["sha256"],
                                   allow_synthetic=allow_synthetic, target=target)
        except (IntegrityError, ValueError, TypeError, KeyError, OSError) as error:
            report = evaluate_case(expected, case, {}, target=target)
            report["error"] = "result_missing" if isinstance(error, FileNotFoundError) else str(error)
            report["checks"][0]["reason"] = report["error"]
            if isinstance(error, FileNotFoundError): report["integrityStatus"] = "incomplete"
        reports.append(report)
    identities = {(r["producer"]["executableSHA256"], r["producer"]["promptSHA256"],
                   r["producer"].get("buildManifestSHA256"), r["producer"]["generationOrigin"],
                   r["producer"].get("targetLocale", CAPTION_TRANSLATION_TARGET))
                  for r in reports if r["integrityStatus"] == "pass"}
    identity_consistent = len(identities) <= 1
    if not identity_consistent:
        for report in reports:
            if report["integrityStatus"] == "pass":
                report["integrityStatus"] = "failed"
                report["error"] = "mixed-probe-builds-or-prompts-in-one-result-set"
                report["checks"].append({"name": "single-producer-identity", "passed": False})
                for fact in report["facts"]: fact["coverageSignal"] = False
    def totals(group):
        facts = [f for report in group for f in report["facts"]]
        return {"expectedCases": len(group), "expectedFacts": len(facts),
                "integrityPassedCases": sum(r["integrityStatus"] == "pass" for r in group),
                "missingCases": sum(r["integrityStatus"] == "incomplete" for r in group),
                "bodyCoverageSignals": sum(f["coverageSignal"] for f in facts),
                "lexicalSignals": sum(f["lexicalSignal"] for f in facts),
                "semanticallyAcceptedFacts": 0, "semanticReadbackPendingFacts": len(facts)}
    value = {"version": 2, "goldSHA256": entries["gold.json"]["sha256"], "resultsDirectory": str(results.resolve()),
            "integrityStatus": "pass" if reports and all(r["integrityStatus"] == "pass" for r in reports) else "failed",
            "cases": reports, "totals": totals(reports),
            "bySplit": {split: totals([r for r in reports if r["split"] == split]) for split in sorted({r["split"] for r in reports})},
            "evidenceOrigin": "synthetic-regression-enabled" if allow_synthetic else "production-model-required",
            "producerIdentityConsistent": identity_consistent,
            "splitInterpretation": "declared-labels-only; prior exposure requires an external evaluation log",
            "overallAcceptance": "pending-semantic-readback-and-baseline-comparison",
            "exitCodeMeaning": "0=complete-structural-evidence;2=incomplete-or-invalid-evidence;1=execution-failure;no-code-certifies-semantics"}
    if target != CAPTION_TRANSLATION_TARGET:
        value["targetLocale"] = target
    return value


def delivery_report(value: dict, *, include_content: bool = False) -> dict:
    """Keep point readback and source meanings behind an explicit body switch."""
    if not include_content:
        fields = ("version", "goldSHA256", "integrityStatus", "totals", "bySplit", "evidenceOrigin",
                  "producerIdentityConsistent", "splitInterpretation", "overallAcceptance",
                  "exitCodeMeaning", "targetLocale")
        report = {key: value[key] for key in fields if key in value}
    else:
        report = json.loads(json.dumps(value))
        report.pop("resultsDirectory", None)
        for case in report.get("cases", []):
            if "error" in case:
                case["error"] = "integrity_failed"
            for check in case.get("checks", []):
                if "reason" in check and not check.get("passed"):
                    check["reason"] = "integrity_failed"
    if "error" in value:
        report["error"] = "evaluation_failed"
    report["contentIncluded"] = include_content
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target", choices=sorted(CAPTION_TRANSLATION_TARGETS),
                        default=CAPTION_TRANSLATION_TARGET,
                        help="Target evidence language; default preserves the zh-Hans protocol")
    parser.add_argument("--allow-synthetic-regression", action="store_true",
                        help="Validate explicitly marked injected test results; never count as model evidence")
    parser.add_argument("--include-content", action="store_true",
                        help="Save source meanings and point readback; keep this report private")
    args = parser.parse_args(argv)
    if args.output.exists(): parser.error("Output already exists; retain previous evaluations")
    try:
        value = score(args.corpus, args.results, allow_synthetic=args.allow_synthetic_regression,
                      target=args.target)
    except (IntegrityError, ValueError, TypeError, KeyError, OSError) as error:
        value = {"version": 2, "integrityStatus": "failed", "error": "evaluation_failed",
                 "overallAcceptance": "pending-semantic-readback-and-baseline-comparison"}
    value = delivery_report(value, include_content=args.include_content)
    if args.output.parent.resolve() != args.output.parent.absolute():
        parser.error("output_parent_unsafe")
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"integrityStatus": value["integrityStatus"], "totals": value.get("totals"),
                      "semanticAcceptance": "pending"}, ensure_ascii=False))
    return 0 if value["integrityStatus"] == "pass" else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as error:
        print("Scorer execution failed; raw diagnostics omitted", file=sys.stderr)
        sys.exit(1)
