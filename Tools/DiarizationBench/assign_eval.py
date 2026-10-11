"""Measures how well speakers end up on the transcript words.

Ports SpeakerAssignment.assign (word-level split, 2-word smoothing, segment fallback)
and scores every word against the Zoom reference: a word counts when its midpoint
falls inside a single reference cue; the hypothesis speaker labels are mapped to
reference names by the overlap-optimal one-to-one mapping.

Usage:
  python3 assign_eval.py <transcript.vtt> <whisper.json> <whisper.stderr|-> <turns.tsv> [whisper.stderr]
whisper.stderr supplies the VAD map (vad_segment_info lines); "-" assigns with the raw
token times (what the app did before the fix); the trailing whisper.stderr is then
still needed to know the true time of each word for scoring.
"""
import bisect
import json
import re
import sys
from collections import defaultdict
from itertools import permutations

MIN_RUN = 2


def seconds(stamp):
    h, m, s = stamp.replace(",", ".").split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def reference(path):
    text = open(path, encoding="utf-8").read()
    cues = []
    for a, b, body in re.findall(r"(\d\d:\d\d:\d\d\.\d+) --> (\d\d:\d\d:\d\d\.\d+)\n(.+?)(?:\n\n|\Z)", text, re.S):
        m = re.match(r"([^:]{1,60}): ", body)
        cues.append((seconds(a), seconds(b), m.group(1) if m else "?"))
    return sorted(cues)


def vad_map(stderr_path):
    if stderr_path == "-":
        return None
    pts = []
    pat = re.compile(r"vad_segment_info: orig_start: ([\d.]+), orig_end: ([\d.]+), vad_start: ([\d.]+), vad_end: ([\d.]+)")
    for line in open(stderr_path, errors="ignore"):
        m = pat.search(line)
        if m:
            os_, oe, vs, ve = map(float, m.groups())
            pts += [(vs, os_), (ve, oe)]
    pts.sort()
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]

    def f(t):
        if t <= xs[0]:
            return ys[0] + (t - xs[0])
        if t >= xs[-1]:
            return ys[-1] + (t - xs[-1])
        i = bisect.bisect_right(xs, t)
        x0, x1, y0, y1 = xs[i - 1], xs[i], ys[i - 1], ys[i]
        return y0 if x1 == x0 else y0 + (t - x0) * (y1 - y0) / (x1 - x0)
    return f


def words_from_tokens(tokens, mapping):
    out, cur, start, end = [], "", 0, 0
    for t in tokens:
        if "offsets" not in t or (t["text"].startswith("[") and t["text"].endswith("]")):
            continue
        begins = t["text"].startswith(" ") or (not out and not cur)
        if begins and cur:
            out.append([start, end, cur])
            cur = ""
        if not cur:
            start = t["offsets"]["from"] / 1000
        cur += t["text"]
        end = t["offsets"]["to"] / 1000
    if cur:
        out.append([start, end, cur])
    if mapping:
        out = [[mapping(a), mapping(b), w] for a, b, w in out]
    return out


def label_for(start, end, turns):
    totals = defaultdict(float)
    for ts, te, lab in turns:
        if te > start and ts < end:
            totals[lab] += min(end, te) - max(start, ts)
    if totals:
        return sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    mid = (start + end) / 2
    best, dist = None, 1e9
    for ts, te, lab in turns:
        d = ts - mid if mid < ts else (mid - te if mid > te else 0)
        if d < dist:
            best, dist = lab, d
    return best if dist <= 1.0 else None


def smoothed_runs(labels):
    runs = []
    for i, lab in enumerate(labels):
        if runs and runs[-1][0] == lab:
            runs[-1][2] = i + 1
        else:
            runs.append([lab, i, i + 1])
    while len(runs) > 1:
        short = next((k for k, r in enumerate(runs) if r[2] - r[1] < MIN_RUN), None)
        if short is None:
            break
        prev = short - 1 if short > 0 else None
        nxt = short + 1 if short < len(runs) - 1 else None
        if prev is not None and nxt is not None:
            target = prev if runs[prev][2] - runs[prev][1] >= runs[nxt][2] - runs[nxt][1] else nxt
        else:
            target = prev if prev is not None else nxt
        runs[target][1] = min(runs[target][1], runs[short][1])
        runs[target][2] = max(runs[target][2], runs[short][2])
        del runs[short]
        merged = []
        for r in runs:
            if merged and merged[-1][0] == r[0]:
                merged[-1][2] = r[2]
            else:
                merged.append(r)
        runs = merged
    return runs


def assign(segments, turns):
    """Returns (word_start, word_end, label) for every word, as the app would label it."""
    labelled = []
    for seg in segments:
        words = seg["words"]
        if not words:
            continue
        labels = [label_for(a, b, turns) for a, b, _ in words]
        prev = None
        for i, lab in enumerate(labels):
            if lab is not None:
                prev = lab
            else:
                labels[i] = prev
        first = next((x for x in labels if x is not None), None)
        labels = [x if x is not None else first for x in labels]
        for lab, lo, hi in smoothed_runs(labels):
            for a, b, _ in words[lo:hi]:
                labelled.append((a, b, lab))
    return labelled


def ref_at(t, cues, starts):
    i = bisect.bisect_right(starts, t) - 1
    hits = [c for c in cues[max(0, i - 3): i + 1] if c[0] <= t < c[1]]
    names = {c[2] for c in hits}
    return names.pop() if len(names) == 1 else None


vtt, wjson, stderr, tsv = sys.argv[1:5]
cues = reference(vtt)
starts = [c[0] for c in cues]
# The map is always needed to know when a word was really said; `use_map` says
# whether the assignment sees mapped (fixed) or raw (current app) times.
use_map = stderr != "-"
true_map = vad_map(sys.argv[5] if len(sys.argv) > 5 else stderr)
mapping = true_map if use_map else None
turns = []
for line in open(tsv).read().splitlines()[1:]:
    a, b, lab = line.split("\t")
    turns.append((float(a), float(b), lab))
segments = []
truth = []
for s in json.load(open(wjson))["transcription"]:
    segments.append({"start": s["offsets"]["from"] / 1000, "end": s["offsets"]["to"] / 1000,
                     "words": words_from_tokens(s.get("tokens", []), mapping)})
    truth += words_from_tokens(s.get("tokens", []), true_map)

words = assign(segments, turns)
pairs = []
outside = 0
for (a, b, lab), (ta, tb, _) in zip(words, truth):
    r = ref_at((ta + tb) / 2, cues, starts)
    if r is None:
        outside += 1
        continue
    pairs.append((lab, r))

# Overlap-optimal one-to-one mapping between hypothesis labels and people.
count = defaultdict(lambda: defaultdict(int))
for h, r in pairs:
    count[h][r] += 1
hyps = sorted({h for h, _ in pairs if h is not None})
refs = sorted({r for _, r in pairs})
best = {}
remaining = set(refs)
for h, r, n in sorted(((h, r, count[h][r]) for h in hyps for r in refs), key=lambda x: -x[2]):
    if h not in best and r in remaining:
        best[h] = r
        remaining.discard(r)
correct = sum(1 for h, r in pairs if best.get(h) == r)
print(f"{'mapped' if use_map else 'raw   '} words={len(words)} scored={len(pairs)} outside_ref={outside} "
      f"accuracy={correct / len(pairs):.1%}")
