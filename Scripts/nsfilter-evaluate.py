#!/opt/homebrew/bin/python3.13
"""Public-only evaluator. Input paths/sources are explicit in an input manifest.

Does not download, run ASR, import candidate packages, sign, or delete anything.
Every block is independently materialized and analyzed; <1.5 seconds pass.
Retains the local PCM clips under the caller's output folder.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import resource
import subprocess
import sys
import time


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1048576), b""):
            h.update(b)
    return h.hexdigest()


def timestamp(s):
    h, m, seconds = s.replace(",", ".").split(":")
    return 3600 * int(h) + 60 * int(m) + float(seconds)


def captions(path, offset, duration):
    rows = []
    for block in re.split(r"\n\s*\n", path.read_text(encoding="utf-8-sig")):
        lines = block.splitlines()
        if len(lines) < 3 or " --> " not in lines[1]:
            continue
        left, right = lines[1].split(" --> ")
        left, right = timestamp(left) - offset, timestamp(right) - offset
        text = re.sub(r"\[[^\]]*\]|<[^>]*>", "", " ".join(lines[2:]))
        words = len(re.findall(r"\w+(?:['’]\w+)*", text))
        if words and left < duration and right > 0:
            rows.append({"start": max(0, left), "end": min(duration, right), "words": words})
    return rows


def aligned_words(path, duration, anchors=None):
    rows=[]
    trusted_times=[v["time_s"] for v in json.loads(anchors.read_text())["anchors"]] if anchors else []
    for line in path.read_text().splitlines():
        for word in json.loads(line)["words"]:
            left,right=word["start_s"],word["end_s"]
            if 0 <= left < right <= duration:
                # Exact official >=5-word match anchors support these timestamps;
                # confidence remains an ASR alignment proxy, not human truth.
                midpoint=(left+right)/2
                matched=any(left <= t <= right or abs(t-midpoint)<0.1 for t in trusted_times)
                rows.append({"start":left,"end":right,"words":1,"official_anchor_matched":int(matched)})
    return rows


def union_length(intervals):
    total, end = 0.0, -math.inf
    for left, right in sorted(intervals):
        total += max(0, right - max(end, left))
        end = max(end, right)
    return total


def summarize(rows, cues, duration):
    scored = [r for r in rows if r["max_speech"] is not None]
    captioned = [r for r in rows if cues is not None and any(c["start"] < r["end"] and c["end"] > r["start"] for c in cues)]
    thresholds = []
    for index, t in enumerate((0.05, 0.1, 0.2, 0.3)):
        blocked = [r for r in rows if r["probe"].get("production_suppressed", [0,0,0,0])[index]]
        bc = [r for r in blocked if r in captioned]
        midpoint_words = lower_words = upper_words = None
        if cues is not None:
            midpoint_words = sum(c["words"] for c in cues if any(r["start"] <= (c["start"] + c["end"]) / 2 < r["end"] for r in blocked))
            lower_words = sum(c["words"] for c in cues if abs(union_length([(max(c["start"],r["start"]),min(c["end"],r["end"])) for r in blocked if r["start"] < c["end"] and r["end"] > c["start"]]) - (c["end"] - c["start"])) < 1e-6)
            upper_words = sum(c["words"] for c in cues if any(r["start"] < c["end"] and r["end"] > c["start"] for r in blocked))
        denom = sum(c["words"] for c in cues) if cues is not None else None
        thresholds.append({"threshold": t, "blocked_blocks": len(blocked),
            "blocked_seconds": sum(r["end"] - r["start"] for r in blocked),
            "blocked_captioned_blocks": len(bc) if cues is not None else None,
            "captioned_fraction_of_blocked": len(bc) / len(blocked) if cues is not None and blocked else None,
            "captioned_block_rejection_rate_proxy": len(bc) / len(captioned) if captioned else None,
            "blocked_uncaptioned_blocks_unknown_truth": len(blocked) - len(bc) if cues is not None else len(blocked),
            "blocked_reference_word_units_midpoint": midpoint_words,
            "blocked_reference_word_units_interval_lower": lower_words,
            "blocked_reference_word_units_interval_upper": upper_words,
            "reference_word_rejection_rate_midpoint_proxy": midpoint_words / denom if denom else None,
            "reference_word_rejection_rate_interval_lower": lower_words / denom if denom else None,
            "reference_word_rejection_rate_interval_upper": upper_words / denom if denom else None,
            "human_verified_true_speech_rejection_rate": None})
    cpu = sum(r["probe"].get("classification_cpu_seconds",0) for r in rows)
    return {"blocks": len(rows), "audio_seconds": duration, "scored_blocks": len(scored),
        "short_failopen_blocks": sum(r["probe"].get("short",0) for r in rows),
        "error_failopen_blocks": sum(bool(r["probe"].get("error") or r["probe"].get("nonfinite")) for r in rows),
        "nil_failopen_blocks_other_than_short_or_thrown_error": sum(r["max_speech"] is None and not r["probe"].get("short") and not r["probe"].get("error") for r in rows),
        "window_covered_audio_seconds": None,
        "window_uncovered_audio_seconds": None,
        "captioned_blocks": len(captioned) if cues is not None else None,
        "reference_word_units": sum(c["words"] for c in cues) if cues is not None else None,
        "caption_covered_seconds": union_length([(c["start"],c["end"]) for c in cues]) if cues is not None else None,
        "caption_cues_straddling_block_edges": sum(any(c["start"] < r["end"] < c["end"] for r in rows[:-1]) for c in cues) if cues is not None else None,
        "process_cpu_seconds_product_call_sum": cpu,
        "process_cpu_seconds_per_audio_hour": cpu * 3600 / duration,
        "process_cpu_seconds_including_clip_preparation":sum(r["probe"]["cpu_seconds"] for r in rows),
        "thresholds": thresholds}


def run(manifest, tool, output):
    output.mkdir(parents=True, exist_ok=True)
    verified = subprocess.run(["/usr/bin/codesign","--verify","--strict",str(tool)],capture_output=True)
    if verified.returncode:
        raise RuntimeError("probe verification failed")
    config = json.loads(manifest.read_text())
    inputs = config["inputs"]
    source_evidence = []
    requests, references = [], []
    for source in inputs:
        p = Path(source["audio"])
        actual = sha(p)
        if actual != source["sha256"]:
            raise RuntimeError("public audio hash mismatch")
        source_evidence.append({**source,"verified_sha256":actual})
        duration = source["duration"]
        cues = captions(Path(source["captions"]),source.get("caption_offset",0),duration) if source.get("captions") else None
        if source.get("aligned_words"):
            cues=aligned_words(Path(source["aligned_words"]),duration,Path(source["anchors"]) if source.get("anchors") else None)
        for chunk in config.get("chunk_seconds",(8,15)):
            position = 0.0
            while position < duration:
                end = min(duration, position+chunk)
                requests.append({"path":str(p),"start":position,"end":end,"scratch":str(output/"public-clips"),"mode":"production"})
                references.append((source["id"],chunk,position,end,cues))
                position=end
    before=resource.getrusage(resource.RUSAGE_CHILDREN)
    wall=time.monotonic()
    process=subprocess.Popen([str(tool)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    stdout,stderr=process.communicate("".join(json.dumps(r)+"\n" for r in requests),timeout=3600)
    wall=time.monotonic()-wall
    after=resource.getrusage(resource.RUSAGE_CHILDREN)
    if process.returncode:
        raise RuntimeError("probe execution failed")
    results=[json.loads(line) for line in stdout.splitlines()]
    if len(results)!=len(requests):
        raise RuntimeError("probe result mismatch")
    groups={}
    for (identity,chunk,start,end,cues),r in zip(references,results):
        windows=r["windows"]
        valid=not r.get("short") and not r.get("error") and not r.get("nonfinite")
        score=r.get("production_maximum") if valid else None
        if score is not None and not math.isfinite(score):score=None
        covered=union_length([(max(0,w["start"]),min(end-start,w["start"]+w["duration"])) for w in windows if w["start"]<end-start and w["start"]+w["duration"]>0])
        row={"start":start,"end":end,"max_speech":score,"covered_seconds":covered,"probe":r}
        groups.setdefault((identity,chunk),[]).append(row)
    summary=[]
    for source in inputs:
        for chunk in config.get("chunk_seconds",(8,15)):
            key=(source["id"],chunk)
            cues=next(r[4] for r in references if r[0]==key[0])
            item={"id":key[0],"chunk_seconds":chunk,**summarize(groups[key],cues,source["duration"])}
            if source.get("aligned_words"):
                item["reference_type"]="previous-ASR-word-timestamps-proxy"
                item["official_anchor_matched_reference_words"]=sum(c["official_anchor_matched"] for c in cues)
                for threshold in item["thresholds"]:
                    blocked=[r for r in groups[key] if r["probe"].get("production_suppressed",[0,0,0,0])[config.get("thresholds",[0.05,0.1,0.2,0.3]).index(threshold["threshold"])]]
                    threshold["blocked_official_anchor_matched_word_proxies"]=sum(c["official_anchor_matched"] for c in cues if any(r["start"] < c["end"] and r["end"] > c["start"] for r in blocked))
            else:item["reference_type"]="official-SRT-cue-timing-proxy" if cues is not None else "unavailable"
            summary.append(item)
    cpu=after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime
    result={"schema":"nsfilter-public-evaluation-v1","method":"fresh-analyzer-per-fixed-block-v1",
        "classifier":"version1","window_seconds":1.5,"overlap_factor":0.5,"decision":"max_speech < threshold; short/error/nonfinite/no-window pass",
        "hardware_selection":"builtin-CoreML-selection-not-verified-no-public-computeUnits-setting",
        "probe_source_mode":"compiles-real-SpeechPresenceGate-source-product-mode-no-second-analysis",
        "total_audio_seconds_analyzed":sum(s["audio_seconds"] for s in summary),
        "probe_process_cpu_seconds_including_startup":cpu,"probe_process_cpu_seconds_per_audio_hour":cpu*3600/sum(s["audio_seconds"] for s in summary),
        "probe_wall_seconds":wall,"probe_stderr_bytes":len(stderr.encode()),
        "energy_joules_per_audio_hour":None,"energy_status":"unverifiable-no-isolated-calibrated-energy-measurement",
        "sources":source_evidence,"summaries":summary,
        "limits":["CPU time is this probe process only; external system services and accelerator energy are not measured.",
            "UN selections and any existing alignment are explicit in sources; floor and interpretation words are different audio and not interchangeable truth.",
            "Official CS50 captions and prior UN ASR-aligned words are proxies, not human audited word timestamps.",
            "Fixed grids differ from the production 2-10-second causal preview/pause policy; no new preview ASR is run.",
            "Product API returns only maximum; per-block window coverage is not measured in product mode. Private diagnostic uses a separate whole-file window mode.",
            "Short, error, missing-label, nonfinite, incomplete and no-window results pass through real product API."]}
    (output/"evaluation.json").write_text(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False)+"\n")
    (output/"block-results.json").write_text(json.dumps({f"{key[0]}-{key[1]}":rows for key,rows in groups.items()},indent=2)+"\n")
    return result


if __name__=="__main__":
    r=run(Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]))
    print(json.dumps({"schema":r["schema"],"audio_seconds":r["total_audio_seconds_analyzed"],"cpu_seconds":r["probe_process_cpu_seconds_including_startup"],"wall_seconds":r["probe_wall_seconds"]}))
