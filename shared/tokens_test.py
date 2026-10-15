import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("tokens.py")

COLORS = """schema = 1

[color.feed_paper]
hex = "#E6E2DA"
setting = "feed_paper_hex"
source = "ios/Turn/model/AppState+SettingsDefaults.swift:179"

[color.standard_button]
hex = "#D6D6D6"
setting_channels = ["standard_button_color_red", "standard_button_color_green", "standard_button_color_blue"]

[shadow.photo]
source = "ios/Turn/view/component/PhotoEdge.swift:51"
layers = [
  { color = "#000000", alpha = 0.28, radius = 1.5, y = 1.2 },
  { color = "feed_paper", alpha = 0.14, radius = 8, y = -4 },
]
"""

SPACE = """schema = 1

[space]
md = { value = 12, source = "ios/Turn/view/Spacing.swift:9" }
page_stack = { ref = "md" }
two_xs = 2

[layout.card_look]
shuffle_edge_width = { value = 1.2, setting = "shuffle_edge_width" }
"""

MOTION = """schema = 1

[curve]
ease_in_out = { points = [0.42, 0.0, 0.58, 1.0] }

[motion.deck_spring]
kind = "spring"
response = 0.46
damping = 0.8

[motion.drawer_snap_back]
kind = "spring"
response = 0.3

[motion.lens_fade]
kind = "curve"
curve = "ease_in_out"
duration = 0.28

[motion.deck_peek_in]
kind = "spring"
response = 0.5
damping = 0.86
delay = 0.14

[motion.intro_deal_fan]
kind = "keyframe_spring"
preset = "snappy"
duration = 0.42

[cap]
feed = { dynamic_type_size = "xxxLarge" }
"""


class TokensTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.tokens = self.root / "tokens"
        self.tokens.mkdir()
        (self.tokens / "colors.toml").write_text(COLORS)
        (self.tokens / "space.toml").write_text(SPACE)
        (self.tokens / "motion.toml").write_text(MOTION)

    def tearDown(self):
        self.temp.cleanup()

    def run_tokens(self, *args, seed="0"):
        env = dict(os.environ, PYTHONHASHSEED=seed)
        command = [sys.executable, "-B", str(SCRIPT), "--tokens", str(self.tokens), *args]
        return subprocess.run(command, capture_output=True, text=True, env=env)

    def generate(self, name, seed):
        kotlin = self.root / name / "TurnTokens.kt"
        swift = self.root / name / "TurnTokens.swift"
        result = self.run_tokens("--kotlin", str(kotlin), "--swift", str(swift), seed=seed)
        self.assertEqual(0, result.returncode, result.stderr)
        return kotlin.read_bytes(), swift.read_bytes()

    def test_same_tokens_give_the_same_bytes(self):
        first = self.generate("first", seed="1")
        second = self.generate("second", seed="4242")
        self.assertEqual(first, second)

    def test_springs_convert_response_to_stiffness(self):
        kotlin, swift = (text.decode() for text in self.generate("out", seed="0"))
        self.assertIn("val deckSpringStiffness: Float = 186.57097f", kotlin)
        self.assertIn("val deckSpringDampingRatio: Float = 0.8f", kotlin)
        self.assertIn("val drawerSnapBackDampingRatio: Float = 0.825f", kotlin)
        self.assertIn("val introDealFanDampingRatio: Float = 0.85f", kotlin)
        self.assertIn("static let deckSpring = Animation.spring(response: 0.46, dampingFraction: 0.8)", swift)
        self.assertIn("static let drawerSnapBack = Animation.spring(response: 0.3)", swift)
        self.assertIn("static let deckPeekIn = Animation.spring(response: 0.5, dampingFraction: 0.86).delay(0.14)", swift)

    def test_curves_keep_apples_control_points(self):
        kotlin, swift = (text.decode() for text in self.generate("out", seed="0"))
        self.assertIn("CubicBezierEasing(0.42f, 0f, 0.58f, 1f)", kotlin)
        self.assertIn("tween(durationMillis = lensFadeDurationMillis, easing = Curve.easeInOut)", kotlin)
        self.assertIn("static let lensFade = Animation.easeInOut(duration: 0.28)", swift)

    def test_values_keep_their_types(self):
        kotlin, swift = (text.decode() for text in self.generate("out", seed="0"))
        self.assertIn("val twoXS: Float = 2f", kotlin)
        self.assertIn("val pageStack: Float = md", kotlin)
        self.assertIn("val shuffleEdgeWidth: Double = 1.2", kotlin)
        self.assertIn("val standardButtonRed: Double = 0.8392156862745098", kotlin)
        self.assertIn("val feed: Float = 1.3529412f", kotlin)
        self.assertIn("ShadowLayer(color = Color.feedPaper.copy(alpha = 0.14f), radius = 8.dp, y = (-4).dp)", kotlin)
        self.assertIn("static let shuffleEdgeWidth: Double = 1.2", swift)
        self.assertIn("static let feed = DynamicTypeSize.xxxLarge", swift)

    def test_check_fails_when_a_token_changes_without_regenerating(self):
        kotlin = self.root / "TurnTokens.kt"
        self.assertEqual(0, self.run_tokens("--kotlin", str(kotlin)).returncode)
        self.assertEqual(0, self.run_tokens("--kotlin", str(kotlin), "--check").returncode)
        (self.tokens / "colors.toml").write_text(COLORS.replace("#E6E2DA", "#E6E2DB"))
        stale = self.run_tokens("--kotlin", str(kotlin), "--check")
        self.assertEqual(1, stale.returncode)
        self.assertIn("stale", stale.stderr)

    def test_unknown_keys_fail(self):
        (self.tokens / "space.toml").write_text(SPACE.replace("source =", "sauce ="))
        result = self.run_tokens("--kotlin", str(self.root / "TurnTokens.kt"))
        self.assertEqual(2, result.returncode)
        self.assertIn("unknown key", result.stderr)

    def test_settings_must_exist_in_swift(self):
        swift = self.root / "swift"
        swift.mkdir()
        (swift / "Settings.swift").write_text('let a = "feed_paper_hex"\nlet b = "standard_button_color_red"\n')
        result = self.run_tokens("--kotlin", str(self.root / "TurnTokens.kt"), "--settings-root", str(swift))
        self.assertEqual(2, result.returncode)
        self.assertIn("shuffle_edge_width", result.stderr)


if __name__ == "__main__":
    unittest.main()
