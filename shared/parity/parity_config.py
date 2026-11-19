"""Project rules from parity.toml: source roots, unit keys, mirrored paths, iOS-only and Android-only lists."""

import fnmatch
import os
import re
import tomllib
from dataclasses import dataclass, field

KOTLIN_KEYWORDS_DEFAULT = [
    "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is",
    "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof",
    "val", "var", "when", "while",
]


_GLOBS = {}


def glob_match(path, pattern):
    """Glob where * stays inside one folder and ** crosses folders."""
    regex = _GLOBS.get(pattern)
    if regex is None:
        parts = re.split(r"(\*\*/?|\*|\?)", pattern)
        out = []
        for part in parts:
            if part in ("**", "**/"):
                out.append(".*")
            elif part == "*":
                out.append("[^/]*")
            elif part == "?":
                out.append("[^/]")
            else:
                out.append(re.escape(part))
        regex = _GLOBS[pattern] = re.compile("".join(out) + r"\Z")
    return regex.match(path) is not None


@dataclass
class Exemption:
    patterns: list
    reason: str


@dataclass
class Config:
    project_root: str
    turn_root: str
    ios_root: str = "ios/Turn"
    ios_debug: str = "ios/debug"
    ios_tests: str = "ios/TurnTests"
    android_root: str = ""
    android_debug_tools: str = ""
    android_debug: str = "debug"
    android_tests: str = ""
    android_instrumented_tests: str = ""
    shared: list = field(default_factory=list)
    strict: list = field(default_factory=list)
    component: list = field(default_factory=list)
    drop_in_file_names: list = field(default_factory=lambda: ["+"])
    enum_case: str = "capitalize_first"
    kotlin_keywords: set = field(default_factory=lambda: set(KOTLIN_KEYWORDS_DEFAULT))
    splits: dict = field(default_factory=dict)
    moved_files: dict = field(default_factory=dict)
    renames: dict = field(default_factory=dict)
    type_map: dict = field(default_factory=dict)
    ios_only_files: list = field(default_factory=list)
    ios_only_symbols: list = field(default_factory=list)
    ios_only_conformances: list = field(default_factory=list)
    android_only_files: list = field(default_factory=list)
    android_only_symbols: list = field(default_factory=list)
    deferred: list = field(default_factory=list)
    ledger_dir: str = "sync"
    guide: str = "doc/platform-mapping.md"

    @property
    def ios_roots(self):
        return [self.ios_root, self.ios_debug, self.ios_tests]

    # Units

    def ios_unit(self, path):
        """Unit key of an iOS path relative to Turn's root, or None when the path is outside the iOS roots."""
        for prefix, root in (("", self.ios_root), ("debug/", self.ios_debug), ("tests/", self.ios_tests)):
            if path.startswith(root + "/"):
                rel = path[len(root) + 1:]
                if rel.endswith(".swift"):
                    rel = rel[: -len(".swift")]
                    for token in self.drop_in_file_names:
                        rel = rel.replace(token, "")
                return prefix + rel
        return None

    def tier(self, ios_path):
        if not ios_path.endswith(".swift") or not ios_path.startswith(self.ios_root + "/"):
            return "other"
        rel = ios_path[len(self.ios_root) + 1:]
        if any(glob_match(rel, pattern) for pattern in self.strict):
            return "strict"
        if any(glob_match(rel, pattern) for pattern in self.component):
            return "component"
        return "other"

    def android_paths(self, ios_path):
        """Android files (relative to the project root) that mirror an iOS file."""
        if not ios_path.endswith(".swift"):
            return []
        if ios_path.startswith(self.ios_root + "/"):
            rel = ios_path[len(self.ios_root) + 1:]
            if rel in self.splits:
                return [self._android_path(name) for name in self.splits[rel]]
            if rel in self.moved_files:
                return [self._android_path(self.moved_files[rel])]
            stem = rel[: -len(".swift")]
            for token in self.drop_in_file_names:
                stem = stem.replace(token, "")
            return [self._android_path(stem + ".kt")]
        if ios_path.startswith(self.ios_debug + "/"):
            rel = ios_path[len(self.ios_debug) + 1:]
            return [os.path.join(self.android_debug, rel[: -len(".swift")] + ".kt")]
        if ios_path.startswith(self.ios_tests + "/") and self.android_tests:
            rel = ios_path[len(self.ios_tests) + 1:]
            # A test file whose classes Android keeps in several files: [[split]] with the iOS path in full.
            if ios_path in self.splits:
                names = self.splits[ios_path]
            else:
                folder, name = os.path.split(rel)
                names = [os.path.join(folder.lower(), name[: -len(".swift")] + ".kt")]
            return [self._android_test_path(name) for name in names]
        return []

    def _android_test_path(self, name):
        """A test runs on the JVM or on a phone: the instrumented tests' file when only it exists, else the JVM one."""
        unit = os.path.join(self.android_tests, name)
        if self.android_instrumented_tests and not os.path.exists(os.path.join(self.project_root, unit)):
            instrumented = os.path.join(self.android_instrumented_tests, name)
            if os.path.exists(os.path.join(self.project_root, instrumented)):
                return instrumented
        return unit

    def _android_path(self, name):
        if name.startswith("debugTools:"):
            return os.path.join(self.android_debug_tools, name[len("debugTools:"):])
        return os.path.join(self.android_root, name)

    def android_rel(self, android_path):
        """Path under the Android source root, as parity.toml writes it."""
        for root in (self.android_root, self.android_debug_tools):
            if root and android_path.startswith(root + "/"):
                return android_path[len(root) + 1:]
        return android_path

    # Exemptions

    def ios_only_file(self, ios_path):
        for exemption in self.ios_only_files:
            for pattern in exemption.patterns:
                candidates = [ios_path]
                if ios_path.startswith(self.ios_root + "/"):
                    candidates.append(ios_path[len(self.ios_root) + 1:])
                if any(glob_match(candidate, pattern) for candidate in candidates):
                    return exemption.reason
        return None

    def deferred_file(self, ios_path):
        for exemption in self.deferred:
            rel = ios_path[len(self.ios_root) + 1:] if ios_path.startswith(self.ios_root + "/") else ios_path
            if any(glob_match(ios_path, p) or glob_match(rel, p) for p in exemption.patterns):
                return exemption.reason
        return None

    def ios_only_symbol(self, names):
        for exemption in self.ios_only_symbols:
            for pattern in exemption.patterns:
                if any(fnmatch.fnmatchcase(name, pattern) for name in names):
                    return exemption.reason
        return None

    def ios_only_conformance(self, conformances):
        for exemption in self.ios_only_conformances:
            if any(c in exemption.patterns for c in conformances):
                return exemption.reason
        return None

    def android_only_file(self, android_path):
        rel = self.android_rel(android_path)
        for exemption in self.android_only_files:
            for pattern in exemption.patterns:
                if glob_match(rel, pattern) or glob_match(android_path, pattern):
                    return exemption.reason
        return None

    def android_only_symbol(self, names):
        for exemption in self.android_only_symbols:
            for pattern in exemption.patterns:
                if any(fnmatch.fnmatchcase(name, pattern) for name in names):
                    return exemption.reason
        return None


def _patterns(value):
    if isinstance(value, str):
        return [value]
    return list(value)


def load(project_root, turn_root, path=None):
    path = path or os.path.join(project_root, "parity.toml")
    with open(path, "rb") as handle:
        data = tomllib.load(handle)
    source = data.get("source", {})
    naming = data.get("naming", {})
    tiers = data.get("tiers", {})
    config = Config(project_root=project_root, turn_root=turn_root)
    config.ios_root = source.get("ios_root", config.ios_root)
    config.ios_debug = source.get("ios_debug", config.ios_debug)
    config.ios_tests = source.get("ios_tests", config.ios_tests)
    config.android_root = source.get("android_root", "")
    config.android_debug_tools = source.get("android_debug_tools", "")
    config.android_debug = source.get("android_debug", config.android_debug)
    config.android_tests = source.get("android_tests", "")
    config.android_instrumented_tests = source.get("android_instrumented_tests", "")
    config.shared = source.get("shared", [])
    config.ledger_dir = source.get("ledger", config.ledger_dir)
    config.guide = source.get("guide", config.guide)
    config.strict = tiers.get("strict", ["model/**", "service/**"])
    config.component = tiers.get("component", ["view/**"])
    config.drop_in_file_names = naming.get("drop_in_file_names", config.drop_in_file_names)
    config.enum_case = naming.get("enum_case", config.enum_case)
    config.kotlin_keywords = set(naming.get("kotlin_keywords", KOTLIN_KEYWORDS_DEFAULT))
    config.splits = {entry["ios"]: entry["android"] for entry in data.get("split", [])}
    config.moved_files = {entry["ios"]: entry["android"] for entry in data.get("moved_file", [])}
    config.renames = data.get("renames", {})
    config.type_map = data.get("type_map", {})
    config.ios_only_files = [Exemption(_patterns(k), v) for k, v in data.get("ios_only", {}).items()]
    config.ios_only_symbols = [Exemption(_patterns(e["symbols"]), e["reason"]) for e in data.get("ios_only_symbol", [])]
    config.ios_only_conformances = [Exemption(_patterns(e["conformances"]), e["reason"]) for e in data.get("ios_only_conformance", [])]
    config.android_only_files = [Exemption(_patterns(e["path"]), e["reason"]) for e in data.get("android_only", [])]
    config.android_only_symbols = [Exemption(_patterns(e["symbols"]), e["reason"]) for e in data.get("android_only_symbol", [])]
    config.deferred = [Exemption(_patterns(e["path"]), e["reason"]) for e in data.get("deferred", [])]
    return config
