import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("tokens.py")

COLORS = """schema = 2

[palette]
feed_paper = { hex = "#E6E2DA", source = "ios/Turn/design/DesignTokens.swift:4" }
feed_ink = { hex = "#36342F", source = "ios/Turn/design/DesignTokens.swift:5" }
feed_secondary_ink = { hex = "#625E57", increased = "#4A4741", source = "ios/Turn/design/DesignTokens.swift:6" }
tab_unselected_ink = { ref = "feed_ink", alpha = 0.55, increased = { ref = "feed_ink", alpha = 0.85 }, source = "ios/Turn/design/DesignTokens.swift:7" }
coral_glow = { hex = "#503C28", source = "ios/Turn/design/DesignTokens.swift:8" }

[glass]
tint = { hex = "#D6D6D6", alpha = 0.08, source = "ios/Turn/design/DesignTokens.swift:14" }
card_tint = { ref = "palette.feed_ink", alpha = 0.42, source = "ios/Turn/design/DesignTokens.swift:15" }
"""

EFFECTS = """schema = 2

[shadow.coral_lift]
source = "ios/Turn/view/Lift.swift:3-4"
layers = [
  { color = "#000000", alpha = 0.18, radius = 4, y = 2 },
  { color = "palette.coral_glow", alpha = 0.08, radius = 18, y = -8 },
]

[shadow.pressed]
inner = [{ color = "palette.feed_ink", alpha = 0.28, radius = 3, y = 2 }]
layers = [{ color = "#FFFFFF", alpha = 0.75, radius = 0, y = 1 }]

[glass]
blur = { value = 0.1388, type = "double", source = "ios/Turn/design/DesignTokens.swift:16" }
play_size = { value = 88, source = "ios/Turn/design/DesignTokens.swift:17" }
"""

SPACE = """schema = 2

[spacing]
xs = { value = 4, source = "ios/Turn/design/Spacing.swift:4" }
md = { value = 12, source = "ios/Turn/design/Spacing.swift:5" }
page_stack = { ref = "md", source = "ios/Turn/design/Spacing.swift:6" }

[floating_card_metrics]
line_gap = { ref = "spacing.xs", source = "ios/Turn/view/Card.swift:2" }

[tab_placement.feed]
drop = 0.37
left = 0.02
source = "ios/Turn/design/DesignTokens.swift:24"

[paper.grain]
seed = { value = 0x7A11, type = "int", source = "ios/Turn/view/Card.swift:3" }
"""

MOTION = """schema = 2

[curve]
ease_in_out = { points = [0.42, 0.0, 0.58, 1.0] }

[motion]
zoom_duration = { value = 0.42, type = "double", source = "ios/Turn/design/Spacing.swift:10" }

[motion.quick_fade]
kind = "curve"
curve = "ease_in_out"
duration = 0.2
source = "ios/Turn/design/Spacing.swift:11"

[motion.press]
kind = "spring"
response = 0.25
damping = 0.7
source = "ios/Turn/design/Spacing.swift:12"

[motion.drawer_snap_back]
kind = "spring"
response = 0.3

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
feed = { dynamic_type_size = "xxxLarge", source = "ios/Turn/view/Card.swift:4" }

[family]
regular = "TurnUIReadable-Regular"
android_files = ["turn_ui_readable_regular.ttf"]
"""

TOML_FILES = {"colors.toml": COLORS, "effects.toml": EFFECTS, "space.toml": SPACE, "motion.toml": MOTION}


class TokensTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.tokens = self.root / "tokens"
        self.tokens.mkdir()
        for name, text in TOML_FILES.items():
            self.write(name, text)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text, folder=None):
        (folder or self.tokens).joinpath(name).write_text(text)

    def edit(self, name, old, new):
        path = self.tokens / name
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def run_tokens(self, *args, seed="0", folders=None):
        env = dict(os.environ, PYTHONHASHSEED=seed)
        command = [sys.executable, "-B", str(SCRIPT)]
        for folder in folders or [self.tokens]:
            command += ["--tokens", str(folder)]
        return subprocess.run(command + list(args), capture_output=True, text=True, env=env)

    def generate(self, name="out", seed="0", folders=None):
        kotlin = self.root / name / "TurnTokens.kt"
        swift = self.root / name / "TurnTokens.swift"
        result = self.run_tokens("--kotlin", str(kotlin), "--swift", str(swift), seed=seed, folders=folders)
        self.assertEqual(0, result.returncode, result.stderr)
        return kotlin.read_text(), swift.read_text()

    def test_same_tokens_give_the_same_bytes(self):
        self.assertEqual(self.generate("first", seed="1"), self.generate("second", seed="4242"))

    def test_springs_convert_response_to_stiffness(self):
        kotlin, swift = self.generate()
        self.assertIn("val pressStiffness: Float = 631.65466f", kotlin)
        self.assertIn("val pressDampingRatio: Float = 0.7f", kotlin)
        self.assertIn("val drawerSnapBackDampingRatio: Float = 0.825f", kotlin)
        self.assertIn("val introDealFanDampingRatio: Float = 0.85f", kotlin)
        self.assertIn("val deckPeekInDelayMillis: Long = 140L", kotlin)
        self.assertIn("static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)", swift)
        self.assertIn("static let drawerSnapBack = Animation.spring(response: 0.3)", swift)
        self.assertIn("static let deckPeekIn = Animation.spring(response: 0.5, dampingFraction: 0.86).delay(0.14)", swift)

    def test_curves_keep_apples_control_points(self):
        kotlin, swift = self.generate()
        self.assertIn("CubicBezierEasing(0.42f, 0f, 0.58f, 1f)", kotlin)
        self.assertIn("tween(durationMillis = quickFadeDurationMillis, easing = TurnTokens.Curve.easeInOut)", kotlin)
        self.assertIn("static let quickFade = Animation.easeInOut(duration: 0.2)", swift)

    def test_colours_carry_alpha_refs_and_increased_contrast(self):
        kotlin, swift = self.generate()
        self.assertIn("val feedSecondaryInk: ComposeColor = ComposeColor(0xFF625E57)", kotlin)
        self.assertIn("val feedSecondaryInkIncreased: ComposeColor = ComposeColor(0xFF4A4741)", kotlin)
        self.assertIn("val tabUnselectedInk: ComposeColor = feedInk.copy(alpha = 0.55f)", kotlin)
        self.assertIn("val tabUnselectedInkIncreased: ComposeColor = feedInk.copy(alpha = 0.85f)", kotlin)
        self.assertIn("val tint: ComposeColor = ComposeColor(0xFFD6D6D6).copy(alpha = 0.08f)", kotlin)
        self.assertIn("val cardTint: ComposeColor = TurnTokens.Palette.feedInk.copy(alpha = 0.42f)", kotlin)
        self.assertIn('static let tint = SwiftUI.Color("#D6D6D6").opacity(0.08)', swift)
        self.assertIn("static let tabUnselectedInkIncreased = feedInk.opacity(0.85)", swift)

    def test_a_table_split_over_files_is_one_object(self):
        kotlin, _ = self.generate()
        self.assertEqual(1, kotlin.count("object Glass {"))
        self.assertIn("val blur: Double = 0.1388", kotlin)
        self.assertIn("val playSize: Float = 88f", kotlin)

    def test_values_keep_their_types(self):
        kotlin, swift = self.generate()
        self.assertIn("val xs: Float = 4f", kotlin)
        self.assertIn("val pageStack: Float = md", kotlin)
        self.assertIn("val lineGap: Float = TurnTokens.Spacing.xs", kotlin)
        self.assertIn("val zoomDuration: Double = 0.42", kotlin)
        self.assertIn("val seed: Int = 31249", kotlin)
        self.assertIn("val feed: Float = 1.3529412f", kotlin)
        self.assertIn('val androidFiles: List<String> = listOf("turn_ui_readable_regular.ttf")', kotlin)
        self.assertIn(
            "ShadowLayer(color = TurnTokens.Palette.coralGlow.copy(alpha = 0.08f), radius = 18.dp, y = (-8).dp)",
            kotlin,
        )
        self.assertIn("val pressedInner: List<ShadowLayer> =", kotlin)
        self.assertIn(
            "ShadowLayer(color: TurnTokens.Palette.coralGlow, opacity: 0.08, radius: 18, x: 0, y: -8),",
            swift,
        )
        self.assertIn("static let zoomDuration: Double = 0.42", swift)
        self.assertIn("static let feed = DynamicTypeSize.xxxLarge", swift)

    def test_a_second_folder_is_laid_over_the_first(self):
        pending = self.root / "pending"
        pending.mkdir()
        self.write("space.toml", "schema = 2\n\n[spacing]\nmd = { value = 14 }\nlg = { value = 16 }\n", pending)
        kotlin, _ = self.generate(folders=[self.root / "missing", self.tokens, pending])
        self.assertIn("val md: Float = 14f", kotlin)
        self.assertIn("val lg: Float = 16f", kotlin)
        self.assertIn("val xs: Float = 4f", kotlin)

    def test_check_fails_when_a_token_changes_without_regenerating(self):
        kotlin = self.root / "TurnTokens.kt"
        self.assertEqual(0, self.run_tokens("--kotlin", str(kotlin)).returncode)
        self.assertEqual(0, self.run_tokens("--kotlin", str(kotlin), "--check").returncode)
        self.edit("colors.toml", "#E6E2DA", "#E6E2DB")
        stale = self.run_tokens("--kotlin", str(kotlin), "--check")
        self.assertEqual(1, stale.returncode)
        self.assertIn("stale", stale.stderr)

    def test_unknown_keys_fail(self):
        self.edit("space.toml", "xs = { value = 4, source", 'xs = { value = 4, setting = "x", source')
        result = self.run_tokens("--kotlin", str(self.root / "TurnTokens.kt"))
        self.assertEqual(2, result.returncode)
        self.assertIn("unknown key", result.stderr)

    def test_schema_one_fails(self):
        self.edit("space.toml", "schema = 2", "schema = 1")
        result = self.run_tokens("--kotlin", str(self.root / "TurnTokens.kt"))
        self.assertEqual(2, result.returncode)
        self.assertIn("schema = 2", result.stderr)

    def test_a_name_in_two_files_fails(self):
        self.write("effects.toml", EFFECTS + '\n[palette]\nfeed_ink = { hex = "#000000" }\n')
        result = self.run_tokens("--kotlin", str(self.root / "TurnTokens.kt"))
        self.assertEqual(2, result.returncode)
        self.assertIn("also in another file", result.stderr)

    def swift_code(self, text):
        folder = self.root / "ios"
        folder.mkdir(exist_ok=True)
        (folder / "View.swift").write_text(text)
        return folder

    def test_ios_usage_lists_every_token_no_swift_code_names(self):
        _, swift = self.generate()
        folder = self.swift_code("let a = TurnTokens.Palette.feedPaper\nlet b = TurnTokens.Palette.feedSecondaryInkIncreased\n")
        (folder / "TurnTokens.swift").write_text(swift)
        result = self.run_tokens("--ios-usage", str(folder))
        self.assertEqual(1, result.returncode)
        self.assertNotIn("uses TurnTokens.Palette.feedPaper\n", result.stderr)
        self.assertNotIn("uses TurnTokens.Palette.feedSecondaryInkIncreased\n", result.stderr)
        self.assertIn("uses TurnTokens.Palette.feedSecondaryInk\n", result.stderr)
        self.assertIn("uses TurnTokens.Shadow.pressedInner\n", result.stderr)
        self.assertIn("uses TurnTokens.Motion.press\n", result.stderr)
        self.assertIn("uses TurnTokens.FloatingCardMetrics.lineGap\n", result.stderr)

    def test_ios_usage_passes_when_every_token_is_named(self):
        _, swift = self.generate()
        unused = self.run_tokens("--ios-usage", str(self.swift_code(""))).stderr.splitlines()
        names = [line.split(" uses ")[1] for line in unused if " uses " in line]
        self.assertIn("TurnTokens.Family.androidFiles", names)
        folder = self.swift_code("\n".join(f"let x{index} = {name}" for index, name in enumerate(names)))
        result = self.run_tokens("--ios-usage", str(folder))
        self.assertEqual(0, result.returncode, result.stderr)

    def test_an_android_list_is_not_in_swift(self):
        android = 'android_files = { value = ["turn_ui_readable_regular.ttf"], platform = "android" }'
        self.edit("motion.toml", 'android_files = ["turn_ui_readable_regular.ttf"]', android)
        kotlin, swift = self.generate()
        self.assertIn('val androidFiles: List<String> = listOf("turn_ui_readable_regular.ttf")', kotlin)
        self.assertNotIn("androidFiles", swift)


if __name__ == "__main__":
    unittest.main()
