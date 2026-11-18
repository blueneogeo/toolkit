#!/usr/bin/env python3
"""The transcription bench's normalising, alignment and scoring, without a phone.

  python3 -B toolkit/android/tests/transcription_bench_test.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import transcription_bench as bench  # noqa: E402


class NormalisingTests(unittest.TestCase):
    def test_numbers_are_spelled_in_the_language_spoken(self):
        self.assertEqual(bench.words("Om 10 uur, 21 mensen", "nl"), ["om", "tien", "uur", "eenentwintig", "mensen"])
        self.assertEqual(bench.words("At 10, 21 people", "en"), ["at", "ten", "twenty", "one", "people"])
        self.assertEqual(bench.words("22", "nl"), ["tweeentwintig"])
        self.assertEqual(bench.words("1.250 euro", "nl"), ["duizend", "tweehonderdvijftig", "euro"])
        self.assertEqual(bench.words("2024", "en"), ["two", "thousand", "twenty", "four"])

    def test_case_accents_and_punctuation_go(self):
        self.assertEqual(bench.words("Één café, don't!", "nl"), ["een", "cafe", "dont"])
        self.assertEqual(bench.words("twenty-four", "en"), ["twenty", "four"])


class ScoringTests(unittest.TestCase):
    clip = {
        "id": "c",
        "language": "nl",
        "kind": "switching",
        "reference": [
            {"start": 0.0, "end": 2.0, "language": "nl", "text": "ik zat te denken"},
            {"start": 2.5, "end": 4.0, "language": "en", "text": "maybe around ten"},
        ],
    }
    lexicons = {"nl": {"ik", "zat", "te", "denken", "misschien", "rond", "tien"}, "en": {"maybe", "around", "ten"}}

    def test_alignment_counts_each_kind_of_error(self):
        ops = bench.align("a b c d".split(), "a x c d e".split())
        self.assertEqual([op for op, _, _ in ops], ["=", "s", "=", "=", "i"])

    def test_a_translated_part_shows_as_the_other_languages_errors_and_wrong_words(self):
        result = {"shown": [{"startMs": 0, "text": "Ik zat te denken"}, {"startMs": 2600, "text": "misschien rond tien"}]}
        score = bench.score_clip(self.clip, result, self.lexicons)
        self.assertEqual(score["words"], 7)
        self.assertEqual(score["errors"], 3)
        self.assertEqual(score["by_language"]["en"], {"words": 3, "errors": 3})
        self.assertEqual(score["wrong_language"], 3)
        self.assertEqual(score["timing_ms"], [0])

    def test_the_words_as_spoken_score_nothing(self):
        result = {"shown": [{"startMs": 100, "text": "Ik zat te denken, maybe around 10?"}]}
        score = bench.score_clip(self.clip, result, self.lexicons)
        self.assertEqual(score["errors"], 0)
        self.assertEqual(score["timing_ms"], [100])

    def test_a_negative_clip_counts_the_words_heard(self):
        clip = {"id": "n", "language": "nl", "kind": "negative", "reference": []}
        result = {"segments": [], "shown": [{"startMs": 0, "text": "Ondertiteld door"}]}
        score = bench.score_clip(clip, result, self.lexicons)
        self.assertEqual((score["filtered_words"], score["shown_words"]), (0, 2))


if __name__ == "__main__":
    unittest.main()
