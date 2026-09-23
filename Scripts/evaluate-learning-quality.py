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
from pathlib import Path
import re
import sys
import uuid

KINDS = {"核心结论", "概念关系", "例子", "易错点", "补充理解", "待确认"}
NUMERIC_CONTEXT = "请核对原文中数值对应的对象、属性、单位和条件；表面数值差异不代表事实错误。"
SOURCE_POLICY = "fixture-uuid-v1/12s-start/10s-duration/revision-0/session-none"
DISPLAY_CONTRACT = "production-point-and-rendered-membership-v1"
PENDING = "pending-independent-readback"
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


def numeric_mentions(text: str) -> list[tuple[str, str | None, str, str]]:
    found = []
    for match in re.finditer(r"[0-9]+(?:\.[0-9]+)?", text):
        value = match.group()
        before, after = text[max(0, match.start() - 8):match.start()], text[match.end():match.end() + 10]
        if ((before[-1:].isalpha() and before[-1:].isupper())
                or (before.endswith("-") and before[-2:-1].isalpha() and before[-2:-1].isupper())
                or before.endswith(DESIGNATOR_PREFIXES) or after[:1] in DESIGNATOR_SUFFIXES):
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
    return found


def numeric_report(claim: str, cited: list[str], segment_texts: list[str],
                   batch_texts: list[str]) -> tuple[bool, str | None]:
    own = numeric_mentions("\n".join(cited + segment_texts))
    batch = numeric_mentions("\n".join(batch_texts))
    gaps, decidable = [], False
    def push(message):
        if len(gaps) < 3 and message not in gaps:
            gaps.append(message)
    for value, unit, role, excerpt in numeric_mentions(claim):
        if role == "designator":
            continue
        in_own = [m for m in own if m[0] == value and m[2] != "designator"]
        in_batch = [m for m in batch if m[0] == value and m[2] != "designator"]
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


def point_line(point: dict) -> str:
    kind = point["kind"]
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


def verify_units(units: list[dict], evidence: list[dict]) -> dict[str, dict]:
    units = object_list(units, "sourceUnits")
    unique([x.get("id") for x in units], "sourceUnits")
    require(all(integer(x.get("index")) and x["index"] < len(evidence) and x.get("language") in ("en", "zh")
                for x in units), "source-unit-owner")
    expected_order = []
    for index, source in enumerate(evidence):
        for language, key in (("en", "english"), ("zh", "chinese")):
            fragments = [x for x in units if x["index"] == index and x["language"] == language]
            require(bool(fragments), "missing-source-language")
            original = source[key]
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


def rendered_contains(line: str, placement: str, markdown: str) -> bool:
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
                  *, allow_synthetic: bool = False) -> list[dict]:
    require(type(result.get("probeVersion")) is int and result["probeVersion"] == 2, "probe-v2-required; old output retained as legacy evidence")
    require(result.get("fixtureID") == case["id"] and result.get("fixtureSHA256") == fixture_sha, "fixture-binding-mismatch")
    require(artifact(directory, "fixture.json", fixture_sha) is not None, "fixture-artifact")
    require(result.get("error") is None, "probe-reported-error")
    require(isinstance(result.get("model"), str) and bool(result["model"]), "model-identity-required")
    producer = result.get("producer")
    require(isinstance(producer, dict), "producer-required")
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
            units = verify_units(request.get("sourceUnits"), batch["evidence"])
            require(request.get("inputFile") == f"input-{request_index}.json"
                    and request.get("responseFile") == f"response-{request_index}.txt", "request-artifact-number")
            prepared = decode(artifact(directory, request.get("inputFile"), request.get("inputSHA256")))
            require(isinstance(prepared, dict) and prepared.get("evidence") == request["sourceUnits"], "request-input-source-mismatch")
            targets = request.get("pendingTargets")
            require(isinstance(targets, list) and len(targets) <= 4 and all(isinstance(x, str) and x in references for x in targets), "pending-target-unknown-or-forward")
            unique(targets, "pending-target")
            require(not set(targets) & retired_questions(batches[:batches.index(batch)]),
                    "pending-target-already-retired")
            followups = object_list(prepared.get("pendingPoints"), "pendingPoints")
            require([p.get("id") for p in followups] == [f"q{i}" for i in range(len(targets))], "pending-alias-order")
            for followup, target in zip(followups, targets):
                old = references[target]
                eligible = old.get("referenceState") in ("pending", "awaitingContext", "numericDifference") or bool(old.get("needsContext")) or (old.get("sourceHasPronoun") is True and old.get("referenceState") == "linked")
                require(eligible, "pending-target-not-eligible")
                quotes = followup.get("quotes")
                original_quotes = [s["quote"] for s in old.get("sources", [])]
                if not original_quotes:
                    original_quotes = [s["english"] or s["chinese"] for s in reference_batches[target]["evidence"]]
                require(isinstance(quotes, list) and quotes and len(quotes) <= 2
                        and all(isinstance(q, str) and q and any(s.startswith(q) for s in original_quotes) for q in quotes),
                        "pending-quotes-not-bound-to-target")
                candidates = followup.get("candidateQuotes")
                candidate_sources = [s["quote"] for p in references.values() if p.get("clarifies") == target
                                     for s in p.get("sources", [])]
                require(isinstance(candidates, list) and len(candidates) <= 2
                        and all(isinstance(q, str) and q and any(s.startswith(q) for s in candidate_sources) for q in candidates),
                        "pending-candidate-quotes-not-bound")
                require(type(followup.get("referenceCheck")) is bool, "pending-referenceCheck-type")
            raw = decode(artifact(directory, request.get("responseFile"), request.get("responseSHA256")))
            normal = request.get("normalizedNote")
            validate_note(raw); validate_note(normal); validate_note(batch.get("note"))
            verify_followups(raw, normal, batch, targets, units, request_index - 1)
            note = batch["note"]
            require(raw["noNewKnowledge"] == normal["noNewKnowledge"] == note["noNewKnowledge"]
                    and normal["topic"] == note["topic"] and len(raw["points"]) == len(normal["points"]) == len(note["points"]), "normalized-note-shape-mismatch")
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
                                for text in (batch["evidence"][owner]["english"], batch["evidence"][owner]["chinese"])]
                all_segments = [text for source in batch["evidence"]
                                for text in (source["english"], source["chinese"])]
                difference, gap = numeric_report(point["text"], [s["quote"] for s in linked],
                                                  own_segments, all_segments)
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
            line = point_line(point)
            require(display.get("renderedLine") == line, "rendered-point-line-mismatch")
            for key, places, markdown in (("fullDisposition", full_places, full), ("latestDisposition", latest_places, latest)):
                placement = places[reference]
                require(display.get(key) == placement, "production-placement-mismatch")
                require(placement == "hidden" or rendered_contains(line, placement, markdown), "point-missing-from-rendered-section")
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
                  fixture_sha: str | None = None, allow_synthetic: bool = False) -> dict:
    facts = [{"id": f["id"], "meaning": f["meaning"], "stage": f["stage"], "coverageSignal": False,
              "lexicalSignal": False, "matchedPointReferences": [], "semanticStatus": PENDING} for f in case_gold["facts"]]
    report = {"id": case["id"], "split": case_gold["split"], "categories": case_gold["categories"],
              "facts": facts, "integrityStatus": "failed", "checks": [], "semanticCorrectness": PENDING,
              "semanticRequirements": [], "pointReadback": {}}
    try:
        require(directory is not None and fixture_sha is not None, "frozen-source-and-artifact-directory-required")
        stages = verify_result(case, result, directory, fixture_sha, allow_synthetic=allow_synthetic)
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


def score(corpus: Path, results: Path, *, allow_synthetic: bool = False) -> dict:
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
                                   allow_synthetic=allow_synthetic)
        except (IntegrityError, ValueError, TypeError, KeyError, OSError) as error:
            report = evaluate_case(expected, case, {})
            report["error"] = "result_missing" if isinstance(error, FileNotFoundError) else str(error)
            report["checks"][0]["reason"] = report["error"]
            if isinstance(error, FileNotFoundError): report["integrityStatus"] = "incomplete"
        reports.append(report)
    identities = {(r["producer"]["executableSHA256"], r["producer"]["promptSHA256"],
                   r["producer"].get("buildManifestSHA256"), r["producer"]["generationOrigin"])
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
    return {"version": 2, "goldSHA256": entries["gold.json"]["sha256"], "resultsDirectory": str(results.resolve()),
            "integrityStatus": "pass" if reports and all(r["integrityStatus"] == "pass" for r in reports) else "failed",
            "cases": reports, "totals": totals(reports),
            "bySplit": {split: totals([r for r in reports if r["split"] == split]) for split in sorted({r["split"] for r in reports})},
            "evidenceOrigin": "synthetic-regression-enabled" if allow_synthetic else "production-model-required",
            "producerIdentityConsistent": identity_consistent,
            "splitInterpretation": "declared-labels-only; prior exposure requires an external evaluation log",
            "overallAcceptance": "pending-semantic-readback-and-baseline-comparison",
            "exitCodeMeaning": "0=complete-structural-evidence;2=incomplete-or-invalid-evidence;1=execution-failure;no-code-certifies-semantics"}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--allow-synthetic-regression", action="store_true",
                        help="Validate explicitly marked injected test results; never count as model evidence")
    args = parser.parse_args(argv)
    if args.output.exists(): parser.error("Output already exists; retain previous evaluations")
    try:
        value = score(args.corpus, args.results, allow_synthetic=args.allow_synthetic_regression)
    except (IntegrityError, ValueError, TypeError, KeyError, OSError) as error:
        value = {"version": 2, "integrityStatus": "failed", "error": str(error),
                 "overallAcceptance": "pending-semantic-readback-and-baseline-comparison"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"integrityStatus": value["integrityStatus"], "totals": value.get("totals"),
                      "semanticAcceptance": "pending"}, ensure_ascii=False))
    return 0 if value["integrityStatus"] == "pass" else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as error:
        print(f"Scorer execution failed: {error}", file=sys.stderr)
        sys.exit(1)
