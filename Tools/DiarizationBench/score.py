"""Scores diarization TSVs (start, end, speaker) against a Zoom transcript.vtt.

Zoom attributes each cue to the participant whose audio channel produced it, so its
speaker labels are a good reference. Its cue boundaries are coarse (a cue can include
short pauses), so DER is reported with a 0.5 s collar and overlap excluded, and the
confusion share is the number that says whether voices are separated well.

Usage: uv run --with pyannote.metrics python score.py <transcript.vtt> <hyp.tsv>...
"""
import re
import sys
from collections import defaultdict

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import (DiarizationCoverage, DiarizationErrorRate,
                                          DiarizationPurity, JaccardErrorRate)


def seconds(stamp):
    h, m, s = stamp.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def reference(vtt_path):
    text = open(vtt_path, encoding="utf-8").read()
    ref = Annotation()
    for start, end, body in re.findall(r"(\d\d:\d\d:\d\d\.\d+) --> (\d\d:\d\d:\d\d\.\d+)\n(.+?)(?:\n\n|\Z)", text, re.S):
        match = re.match(r"([^:]{1,60}): ", body)
        ref[Segment(seconds(start), seconds(end))] = match.group(1) if match else "unknown"
    return ref


def hypothesis(tsv_path):
    hyp = Annotation()
    for line in open(tsv_path).read().splitlines()[1:]:
        start, end, speaker = line.split("\t")
        if float(end) > float(start):
            hyp[Segment(float(start), float(end))] = "h_" + speaker
    return hyp


ref = reference(sys.argv[1])
uem = Timeline([Segment(0, ref.get_timeline().extent().end)])
print(f"reference: {len(ref.labels())} speakers, {ref.get_timeline().support().duration() / 60:.1f} min of speech")
print(f"{'system':<22}{'spk':>4}{'DER':>8}{'miss':>8}{'FA':>8}{'conf':>8}{'JER':>8}{'purity':>8}{'cover':>8}")
for path in sys.argv[2:]:
    hyp = hypothesis(path)
    der = DiarizationErrorRate(collar=0.5, skip_overlap=True)
    d = der(ref, hyp, uem=uem, detailed=True)
    total = d["total"]
    jer = JaccardErrorRate(collar=0.5, skip_overlap=True)(ref, hyp, uem=uem)
    purity = DiarizationPurity(collar=0.5, skip_overlap=True)(ref, hyp, uem=uem)
    coverage = DiarizationCoverage(collar=0.5, skip_overlap=True)(ref, hyp, uem=uem)
    name = path.split("/")[-1].removesuffix(".tsv")
    print(f"{name:<22}{len(hyp.labels()):>4}{d['diarization error rate']:>8.1%}"
          f"{d['missed detection'] / total:>8.1%}{d['false alarm'] / total:>8.1%}{d['confusion'] / total:>8.1%}"
          f"{jer:>8.1%}{purity:>8.1%}{coverage:>8.1%}")

    # Who each hypothesis label mostly is, and how each real person is split.
    mapping = der.optimal_mapping(ref, hyp)
    split = defaultdict(lambda: defaultdict(float))
    for seg, _, r in ref.itertracks(yield_label=True):
        for hseg, _, h in hyp.crop(seg).itertracks(yield_label=True):
            split[r][h] += (hseg & seg).duration
    for person in sorted(split, key=lambda p: -sum(split[p].values())):
        parts = sorted(split[person].items(), key=lambda kv: -kv[1])
        total_p = sum(v for _, v in parts) or 1
        shown = ", ".join(f"{h[2:]}{'*' if mapping.get(h) == person else ''} {v / total_p:.0%}" for h, v in parts[:3])
        print(f"    {person[:30]:<32}{shown}")
