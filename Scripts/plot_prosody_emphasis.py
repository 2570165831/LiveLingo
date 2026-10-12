#!/usr/bin/env python3
"""Plot existing numeric prosody CSVs; matplotlib is an offline lab dependency."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vectors", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new PNG path")
    parser.add_argument("--title", default="Acoustic emphasis / speaking rate")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    with args.vectors.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        parser.error("empty vectors")
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), constrained_layout=True)
    for column, label, color, hist, timeline in [
        ("emphasis_score", "Acoustic emphasis score", "#236a8a", axes[0, 0], axes[1, 0]),
        ("pace_deviation_score", "Rate deviation (robust z)", "#a65d24", axes[0, 1], axes[1, 1]),
    ]:
        selected = [(float(r["start_s"]) / 60, float(r[column])) for r in rows if r[column]]
        if selected:
            x, y = zip(*selected)
            hist.hist(y, bins=40, color=color, edgecolor="white", linewidth=0.4)
            timeline.scatter(x, y, s=5, color=color, alpha=0.6)
        hist.set(xlabel=label, ylabel="Segments")
        timeline.set(xlabel="Audio time (minutes)", ylabel=label,
                     xlim=(0, max(float(r["end_s"]) for r in rows) / 60))
        timeline.axhline(0, color="#555555", linewidth=0.7)
        for ax in (hist, timeline):
            ax.spines[["top", "right"]].set_visible(False)
    fig.suptitle(args.title + "\nWhole-input baseline; gaps are excluded / unavailable segments", fontsize=13)
    # Open exclusively to refuse races/symlinks. No transcript or local paths
    # in the figure or PNG metadata; no optional plotting dependencies in ASR.
    with args.output.open("xb") as handle:
        fig.savefig(handle, format="png", dpi=150, metadata={"Software": ""})
    plt.close(fig)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
