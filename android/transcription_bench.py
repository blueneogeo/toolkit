#!/usr/bin/env python3
"""The transcription quality test's numbers (Turn's spec/recording.md 6.6).

Reads a corpus manifest with human reference transcripts and one or more
results.json files written by the app's benchmark script, and prints per
engine and language: word error rate, the switching clips, caption timing,
words on negative clips, speed, memory and heat, with the pass marks against
a baseline results.json from the leading platform.

Commands:
  files            the clip files the manifest names, one per line (checks they exist)
  device-manifest  the manifest the phone gets: ids and files, no references
  report           the tables (or --json) for result files

The word error rate is jiwer's: (substitutions + deletions + insertions) over
the reference's words, after normalising both sides the same way (lower case,
no accents or punctuation, numbers spelled out in the language spoken there).
It is computed here, with no packages beyond Python's own.

A word in the wrong language is one the engine wrote where a word of another
language was spoken, found in that other language's lexicon and not in the
spoken one's: the corpus's references, plus lexicon/<language>.txt in the
corpus folder (any text; its words count). With a small corpus it undercounts;
the WER of the other language's words shows a translated part regardless.
"""

import argparse
import json
import re
import statistics
import sys
import unicodedata
from pathlib import Path

SPEECH_KINDS = {"speech", "switching", "mixed", "long", "public"}
SWITCH_KINDS = {"switching", "mixed"}
THERMAL_NAMES = ["none", "light", "moderate", "severe", "critical", "emergency", "shutdown"]

# Pass marks (6.6): points over the baseline, milliseconds, real-time factor.
WER_MARGIN = 2.0
SWITCH_MARGIN = 3.0
TIMING_MEDIAN_MS = 400
TIMING_P90_MS = 1000
RTF_LIMIT = 1.5
THERMAL_CLIPS = 10


# ── Corpus ──────────────────────────────────────────────────────────


def load_corpus(folder):
    path = Path(folder) / "manifest.json"
    try:
        clips = json.loads(path.read_text())["clips"]
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"✗ {path}: {error}")
    seen = set()
    for clip in clips:
        for key in ("id", "file", "language"):
            if key not in clip:
                sys.exit(f"✗ {path}: a clip has no {key}: {clip}")
        if clip["id"] in seen:
            sys.exit(f"✗ {path}: clip id {clip['id']} twice")
        seen.add(clip["id"])
        clip.setdefault("kind", "speech")
        clip.setdefault("reference", [])
        if clip["kind"] not in SPEECH_KINDS | {"negative"}:
            sys.exit(f"✗ {path}: {clip['id']} has kind {clip['kind']}")
        for line in clip["reference"]:
            line.setdefault("language", clip["language"])
    return clips


def load_lexicons(folder, clips):
    """Each language's words: the references', and lexicon/<language>.txt in the corpus when there."""
    lexicons = {}
    for clip in clips:
        for line in clip["reference"]:
            lexicons.setdefault(line["language"], set()).update(words(line["text"], line["language"]))
    for path in sorted((Path(folder) / "lexicon").glob("*.txt")):
        lexicons.setdefault(path.stem, set()).update(words(path.read_text(), path.stem))
    return lexicons


def device_file(file):
    return "clips/" + file.replace("/", "_")


def command_files(args):
    corpus = Path(args.corpus)
    missing = []
    for clip in load_corpus(corpus):
        if not (corpus / clip["file"]).is_file():
            missing.append(clip["file"])
        print(clip["file"])
    if missing:
        sys.exit("✗ Missing in the corpus: " + ", ".join(missing))


def command_device_manifest(args):
    clips = [{"id": c["id"], "file": device_file(c["file"])} for c in load_corpus(args.corpus)]
    print(json.dumps({"clips": clips}, indent=2))


# ── Normalising ─────────────────────────────────────────────────────

EN_SMALL = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
EN_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
NL_SMALL = "nul een twee drie vier vijf zes zeven acht negen tien elf twaalf dertien veertien vijftien zestien zeventien achttien negentien".split()
NL_TENS = "_ _ twintig dertig veertig vijftig zestig zeventig tachtig negentig".split()


def english(n):
    if n < 20:
        return EN_SMALL[n]
    if n < 100:
        return EN_TENS[n // 10] + ("" if n % 10 == 0 else " " + EN_SMALL[n % 10])
    if n < 1000:
        rest = n % 100
        return EN_SMALL[n // 100] + " hundred" + ("" if rest == 0 else " " + english(rest))
    for size, name in ((10**9, "billion"), (10**6, "million"), (1000, "thousand")):
        if n >= size:
            rest = n % size
            return english(n // size) + " " + name + ("" if rest == 0 else " " + english(rest))
    return str(n)


def dutch(n):
    if n < 20:
        return NL_SMALL[n]
    if n < 100:
        unit = n % 10
        if unit == 0:
            return NL_TENS[n // 10]
        joiner = "ën" if NL_SMALL[unit].endswith("e") else "en"
        return NL_SMALL[unit] + joiner + NL_TENS[n // 10]
    if n < 1000:
        rest = n % 100
        head = "honderd" if n // 100 == 1 else NL_SMALL[n // 100] + "honderd"
        return head + ("" if rest == 0 else dutch(rest))
    if n < 10**6:
        rest = n % 1000
        head = "duizend" if n // 1000 == 1 else dutch(n // 1000) + "duizend"
        return head + ("" if rest == 0 else " " + dutch(rest))
    for size, name in ((10**9, "miljard"), (10**6, "miljoen")):
        if n >= size:
            rest = n % size
            return dutch(n // size) + " " + name + ("" if rest == 0 else " " + dutch(rest))
    return str(n)


def spell(number, language):
    n = int(number)
    if n >= 10**12:
        return " ".join(spell(d, language) for d in number)
    return dutch(n) if language == "nl" else english(n)


def spelled(number, language, spoken):
    if spoken:
        for candidate in [language] + [other for other in ("en", "nl") if other != language]:
            plain = "".join(c for c in unicodedata.normalize("NFKD", spell(number, candidate)) if not unicodedata.combining(c))
            if set(plain.split()) <= spoken:
                return plain
    return spell(number, language)


GROUPED = re.compile(r"\b\d{1,3}(?:[.,]\d{3})+\b")
DIGITS = re.compile(r"\d+")
NOT_WORD = re.compile(r"[^\w\s]|_")


def words(text, language, spoken=None):
    """
    The normalised words of a text spoken in `language`. With `spoken`, the
    reference's words, a number the engine wrote in digits is spelled in the
    language the reference says it in, when one of them matches.
    """
    text = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    text = text.replace("'", "").replace("-", " ")
    text = GROUPED.sub(lambda m: re.sub(r"[.,]", "", m.group()), text)
    text = DIGITS.sub(lambda m: " " + spelled(m.group(), language, spoken) + " ", text)
    text = NOT_WORD.sub(" ", text)
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return text.split()


# ── Alignment ───────────────────────────────────────────────────────


def align(ref, hyp):
    """Levenshtein over words; the operations as (op, ref index, hyp index), op in = s d i."""
    rows, cols = len(ref) + 1, len(hyp) + 1
    cost = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(cols):
        cost[0][j] = j
    for i in range(1, rows):
        row, above = cost[i], cost[i - 1]
        word = ref[i - 1]
        for j in range(1, cols):
            same = above[j - 1] + (0 if word == hyp[j - 1] else 1)
            row[j] = min(same, above[j] + 1, row[j - 1] + 1)
    ops = []
    i, j = len(ref), len(hyp)
    while i > 0 or j > 0:
        if i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            ops.append(("=" if ref[i - 1] == hyp[j - 1] else "s", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            ops.append(("d", i - 1, None))
            i -= 1
        else:
            ops.append(("i", None, j - 1))
            j -= 1
    ops.reverse()
    return ops


# ── One clip ────────────────────────────────────────────────────────


def reference_words(clip):
    """Each reference word with its language and its line, and whether it starts the line."""
    out = []
    for index, line in enumerate(clip["reference"]):
        for k, word in enumerate(words(line["text"], line["language"])):
            out.append({"word": word, "language": line["language"], "line": index, "first": k == 0})
    return out


def line_language(clip, seconds):
    """The language of the reference line spoken at that moment, for spelling the engine's numbers."""
    for line in clip["reference"]:
        if line.get("start", 0) <= seconds <= line.get("end", line.get("start", 0)):
            return line["language"]
    return clip["language"]


def hypothesis_words(clip, segments, spoken=None):
    out = []
    for index, segment in enumerate(segments):
        language = line_language(clip, segment["startMs"] / 1000)
        for k, word in enumerate(words(segment["text"], language, spoken)):
            out.append({"word": word, "segment": index, "first": k == 0})
    return out


def score_clip(clip, result, lexicons):
    shown = result.get("shown", [])
    if clip["kind"] == "negative":
        filtered = sum(len(words(s["text"], clip["language"])) for s in result.get("segments", []))
        return {"negative": True, "filtered_words": filtered, "shown_words": len(hypothesis_words(clip, shown))}
    ref = reference_words(clip)
    hyp = hypothesis_words(clip, shown, {w["word"] for w in ref})
    ops = align([w["word"] for w in ref], [w["word"] for w in hyp])
    errors = {"s": 0, "d": 0, "i": 0}
    by_language = {}
    wrong_language = 0
    timing = []
    last_language = ref[0]["language"] if ref else clip["language"]
    for op, i, j in ops:
        language = ref[i]["language"] if i is not None else last_language
        last_language = language
        part = by_language.setdefault(language, {"words": 0, "errors": 0})
        if i is not None:
            part["words"] += 1
        if op == "=":
            if hyp[j]["first"] and ref[i]["first"]:
                line = clip["reference"][ref[i]["line"]]
                if "start" in line:
                    timing.append(abs(shown[hyp[j]["segment"]]["startMs"] - line["start"] * 1000))
            continue
        errors[op] += 1
        part["errors"] += 1
        if op in "si":
            word = hyp[j]["word"]
            others = [lang for lang, lex in lexicons.items() if lang != language and word in lex]
            if others and word not in lexicons.get(language, set()):
                wrong_language += 1
    return {
        "negative": False,
        "words": len(ref),
        "errors": errors["s"] + errors["d"] + errors["i"],
        "substitutions": errors["s"],
        "deletions": errors["d"],
        "insertions": errors["i"],
        "by_language": by_language,
        "wrong_language": wrong_language,
        "timing_ms": timing,
    }


# ── A run over the corpus ───────────────────────────────────────────


def percent(errors, total):
    return None if total == 0 else 100.0 * errors / total


def quantile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def score_run(run, clips, lexicons):
    by_id = {c["id"]: c for c in clips}
    results = {r["id"]: r for r in run["clips"]}
    groups = {}
    negative = {"clips": 0, "filtered_words": 0, "shown_words": 0}
    clip_rows = []
    missing = [c["id"] for c in clips if c["id"] not in results]
    failed = [r["id"] for r in run["clips"] if r.get("error")]
    for clip_id, result in results.items():
        clip = by_id.get(clip_id)
        if clip is None or result.get("error"):
            continue
        score = score_clip(clip, result, lexicons)
        if score["negative"]:
            negative["clips"] += 1
            negative["filtered_words"] += score["filtered_words"]
            negative["shown_words"] += score["shown_words"]
            clip_rows.append({"id": clip_id, "kind": "negative", "words_heard": score["shown_words"]})
            continue
        names = [clip["language"]] + (["switching"] if clip["kind"] in SWITCH_KINDS else [])
        for name in names:
            group = groups.setdefault(name, {"clips": 0, "words": 0, "errors": 0, "timing": [], "other_words": 0, "other_errors": 0, "wrong_language": 0})
            group["clips"] += 1
            group["words"] += score["words"]
            group["errors"] += score["errors"]
            group["timing"] += score["timing_ms"]
            group["wrong_language"] += score["wrong_language"]
            for language, part in score["by_language"].items():
                if language != clip["language"]:
                    group["other_words"] += part["words"]
                    group["other_errors"] += part["errors"]
        clip_rows.append({
            "id": clip_id,
            "kind": clip["kind"],
            "language": result.get("language"),
            "wer": percent(score["errors"], score["words"]),
            "wrong_language": score["wrong_language"],
            "rtf": result.get("realTimeFactor"),
        })
    languages = {}
    for name, group in groups.items():
        languages[name] = {
            "clips": group["clips"],
            "words": group["words"],
            "wer": percent(group["errors"], group["words"]),
            "other_language_wer": percent(group["other_errors"], group["other_words"]),
            "wrong_language_words": group["wrong_language"],
            "timing_pairs": len(group["timing"]),
            "timing_median_ms": quantile(group["timing"], 0.5),
            "timing_p90_ms": quantile(group["timing"], 0.9),
        }
    done = [r for r in run["clips"] if not r.get("error")]
    audio = sum(r["audioSeconds"] for r in done)
    decode = sum(r["transcribeMs"] for r in done) / 1000
    thermal = max([r.get("thermalMax", 0) for r in done] + [0])
    return {
        "variant": run["variant"],
        "languages": languages,
        "negative": negative,
        "clips": len(done),
        "missing": missing,
        "failed": failed,
        "audio_seconds": audio,
        "rtf": decode / audio if audio else None,
        "rtf_max": max((r["realTimeFactor"] for r in done), default=None),
        "first_load_ms": run["load"]["ms"],
        "load_memory_mb": [run["load"]["memoryBeforeMB"], run["load"]["memoryAfterMB"], run["load"]["peakMemoryMB"]],
        "peak_memory_mb": max([r.get("peakMemoryMB", 0) for r in done] + [run["load"]["peakMemoryMB"]]),
        "peak_pss_mb": max([r.get("peakPssMB", 0) for r in done] + [run["load"].get("peakPssMB", 0)]),
        "thermal_max": thermal,
        "per_clip": clip_rows,
    }


def load_results(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        sys.exit(f"✗ {path}: {error}")
    return data


def label(results, run):
    device = results.get("device", {})
    name = f"{results.get('platform', '?')} {device.get('model', '?')}"
    return f"{name} {run['variant']}"


# ── Pass marks ──────────────────────────────────────────────────────


def gates(score, base):
    """Each mark as (name, value, limit, passed); passed is None without what it needs."""
    marks = []
    for language in sorted(k for k in score["languages"] if k != "switching"):
        mine = score["languages"][language]["wer"]
        theirs = base["languages"].get(language, {}).get("wer") if base else None
        limit = None if theirs is None else theirs + WER_MARGIN
        marks.append((f"WER {language}", mine, limit, None if limit is None or mine is None else mine <= limit))
    if "switching" in score["languages"]:
        mine = score["languages"]["switching"]["wer"]
        theirs = base["languages"].get("switching", {}).get("wer") if base else None
        limit = None if theirs is None else theirs + SWITCH_MARGIN
        marks.append(("WER switching", mine, limit, None if limit is None or mine is None else mine <= limit))
    timing = [t for k, g in score["languages"].items() if k != "switching" for t in [g]]
    medians = [g["timing_median_ms"] for g in timing if g["timing_median_ms"] is not None]
    p90s = [g["timing_p90_ms"] for g in timing if g["timing_p90_ms"] is not None]
    worst_median = max(medians) if medians else None
    worst_p90 = max(p90s) if p90s else None
    marks.append(("timing median ms", worst_median, TIMING_MEDIAN_MS, None if worst_median is None else worst_median <= TIMING_MEDIAN_MS))
    marks.append(("timing p90 ms", worst_p90, TIMING_P90_MS, None if worst_p90 is None else worst_p90 <= TIMING_P90_MS))
    negative = score["negative"]
    heard = negative["shown_words"] if negative["clips"] else None
    marks.append(("words on negative clips", heard, 0, None if heard is None else heard == 0))
    marks.append(("real-time factor", score["rtf"], RTF_LIMIT, None if score["rtf"] is None else score["rtf"] <= RTF_LIMIT))
    enough = score["clips"] >= THERMAL_CLIPS
    marks.append(("thermal status", score["thermal_max"], 0, (score["thermal_max"] == 0) if enough else None))
    return marks


# ── Printing ────────────────────────────────────────────────────────


def number(value, digits=1):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def table(header, rows):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    line = lambda r: "  ".join(str(c).ljust(w) if i == 0 else str(c).rjust(w) for i, (c, w) in enumerate(zip(r, widths)))
    print(line(header))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(line(r))


def print_report(scored, baseline):
    columns = [name for name, _ in scored] + ([baseline[0]] if baseline else [])
    scores = [s for _, s in scored] + ([baseline[1]] if baseline else [])
    languages = sorted({k for s in scores for k in s["languages"]}, key=lambda k: (k == "switching", k))
    for language in languages:
        print(f"\n{'Switching clips (switching and mixed)' if language == 'switching' else 'Language ' + language}")
        rows = []
        for key, name in (
            ("clips", "clips"),
            ("words", "reference words"),
            ("wer", "WER %"),
            ("other_language_wer", "WER % of the other language's words"),
            ("wrong_language_words", "words in the wrong language"),
            ("timing_pairs", "caption starts compared"),
            ("timing_median_ms", "caption start error median ms"),
            ("timing_p90_ms", "caption start error p90 ms"),
        ):
            rows.append([name] + [number(s["languages"].get(language, {}).get(key)) for s in scores])
        table(["", *columns], rows)
    print("\nSpeed, memory and heat")
    rows = [
        ["clips transcribed"] + [str(s["clips"]) for s in scores],
        ["clips failed or missing"] + [str(len(s["failed"]) + len(s["missing"])) for s in scores],
        ["audio s"] + [number(s["audio_seconds"]) for s in scores],
        ["real-time factor, pooled"] + [number(s["rtf"], 2) for s in scores],
        ["real-time factor, slowest clip"] + [number(s["rtf_max"], 2) for s in scores],
        ["first load s"] + [number(s["first_load_ms"] / 1000) for s in scores],
        ["memory before / after load MB"] + [f"{s['load_memory_mb'][0]} / {s['load_memory_mb'][1]}" for s in scores],
        ["peak memory MB (PSS + native heap)"] + [str(s["peak_memory_mb"]) for s in scores],
        ["peak PSS MB"] + [str(s["peak_pss_mb"] or "-") for s in scores],
        ["highest thermal status"] + [THERMAL_NAMES[s["thermal_max"]] if s["thermal_max"] < len(THERMAL_NAMES) else str(s["thermal_max"]) for s in scores],
        ["negative clips"] + [str(s["negative"]["clips"]) for s in scores],
        ["words on them, filtered"] + [str(s["negative"]["filtered_words"]) for s in scores],
        ["words on them, as shown"] + [str(s["negative"]["shown_words"]) for s in scores],
    ]
    table(["", *columns], rows)
    for name, score in scored:
        base = baseline[1] if baseline else None
        print(f"\nPass marks: {name}" + (f" against {baseline[0]}" if baseline else " (no baseline: the WER marks stay open)"))
        marks = gates(score, base)
        rows = []
        for mark, value, limit, passed in marks:
            verdict = "open" if passed is None else ("pass" if passed else "FAIL")
            rows.append([mark, number(value, 2), "-" if limit is None else number(limit, 2), verdict])
        table(["", "value", "limit", ""], rows)
        verdicts = [p for _, _, _, p in marks]
        if any(p is False for p in verdicts):
            print("Engine version 0: weaker than the baseline on a mark (spec 6.5).")
        elif all(p is True for p in verdicts):
            print("Engine version 1: level with the baseline on every mark (spec 6.5).")
        else:
            print("Engine version open: a mark has no number yet.")


def command_report(args):
    clips = load_corpus(args.corpus)
    lexicons = load_lexicons(args.corpus, clips)
    scored = []
    for path in args.results:
        results = load_results(path)
        for run in results.get("runs", []):
            scored.append((label(results, run), score_run(run, clips, lexicons)))
    if not scored:
        sys.exit("✗ No runs in the result files")
    baseline = None
    if args.baseline:
        results = load_results(args.baseline)
        runs = results.get("runs", [])
        if not runs:
            sys.exit(f"✗ No runs in {args.baseline}")
        # The baseline is the app's run, with its prompt.
        run = next((r for r in runs if r["variant"] == "app"), runs[0])
        baseline = (label(results, run), score_run(run, clips, lexicons))
    if args.json:
        out = {"runs": [{"name": n, **s} for n, s in scored]}
        if baseline:
            out["baseline"] = {"name": baseline[0], **baseline[1]}
        for item in out["runs"]:
            item["marks"] = [dict(zip(("mark", "value", "limit", "passed"), m)) for m in gates(item, baseline[1] if baseline else None)]
        print(json.dumps(out, indent=2))
        return
    print_report(scored, baseline)
    print("\nPer clip")
    rows = []
    for name, score in scored:
        for row in score["per_clip"]:
            if row["kind"] == "negative":
                rows.append([row["id"], name, "negative", "-", f"{row['words_heard']} words", "-", "-"])
            else:
                rows.append([row["id"], name, row["kind"], row["language"] or "-", number(row["wer"]), str(row["wrong_language"]), number(row["rtf"], 2)])
    table(["clip", "run", "kind", "heard", "WER %", "wrong lang", "RTF"], rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("files", "device-manifest"):
        p = sub.add_parser(name)
        p.add_argument("--corpus", required=True)
    p = sub.add_parser("report")
    p.add_argument("--corpus", required=True)
    p.add_argument("--baseline")
    p.add_argument("--json", action="store_true")
    p.add_argument("results", nargs="+")
    args = parser.parse_args()
    {"files": command_files, "device-manifest": command_device_manifest, "report": command_report}[args.command](args)


if __name__ == "__main__":
    main()
