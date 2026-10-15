"""The ledger: one TOML file per unit under sync/, plus sync/_sync.toml for the marker and the shared inputs."""

import os
import tomllib
from dataclasses import dataclass, field

STATUSES = ("ported", "partial", "stub", "todo", "deferred", "ios-only")
MARKER_FILE = "_sync.toml"


@dataclass
class Unit:
    key: str
    status: str = "todo"
    ios_commit: str = ""
    marked_at: str = ""
    note: str = ""
    ios: dict = field(default_factory=dict)       # ios path -> blob
    android: dict = field(default_factory=dict)   # project path -> blob
    scripts: list = field(default_factory=list)
    frames: list = field(default_factory=list)


@dataclass
class Marker:
    ios_commit: str = ""
    synced_at: str = ""
    shared: dict = field(default_factory=dict)     # path -> blob


class Ledger:
    def __init__(self, project_root, ledger_dir="sync"):
        self.root = os.path.join(project_root, ledger_dir)
        self.units = {}
        self.marker = Marker()

    def load(self):
        self.units = {}
        if not os.path.isdir(self.root):
            return self
        for base, _, files in os.walk(self.root):
            for name in files:
                if not name.endswith(".toml"):
                    continue
                path = os.path.join(base, name)
                with open(path, "rb") as handle:
                    data = tomllib.load(handle)
                if name == MARKER_FILE and base == self.root:
                    self.marker = Marker(
                        ios_commit=data.get("ios_commit", ""),
                        synced_at=data.get("synced_at", ""),
                        shared={entry["path"]: entry["blob"] for entry in data.get("shared", [])},
                    )
                    continue
                unit = Unit(
                    key=data["unit"],
                    status=data.get("status", "todo"),
                    ios_commit=data.get("ios_commit", ""),
                    marked_at=data.get("marked_at", ""),
                    note=data.get("note", ""),
                    ios={entry["path"]: entry["blob"] for entry in data.get("ios", [])},
                    android={entry["path"]: entry.get("blob", "") for entry in data.get("android", [])},
                    scripts=data.get("scripts", []),
                    frames=data.get("frames", []),
                )
                self.units[unit.key] = unit
        return self

    def unit_file(self, key):
        return os.path.join(self.root, key + ".toml")

    def write_unit(self, unit):
        lines = [
            "# Written by ./build.sh sync mark. Edit only note.",
            f"unit = {_quote(unit.key)}",
            f"status = {_quote(unit.status)}",
            f"ios_commit = {_quote(unit.ios_commit)}",
            f"marked_at = {_quote(unit.marked_at)}",
            f"note = {_quote(unit.note)}",
            "",
            "ios = [",
            *[f"    {{ path = {_quote(p)}, blob = {_quote(b)} }}," for p, b in sorted(unit.ios.items())],
            "]",
            "android = [",
            *[f"    {{ path = {_quote(p)}, blob = {_quote(b)} }}," for p, b in sorted(unit.android.items())],
            "]",
            f"scripts = [{', '.join(_quote(s) for s in unit.scripts)}]",
            f"frames = [{', '.join(_quote(f) for f in unit.frames)}]",
        ]
        path = self.unit_file(unit.key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write("\n".join(lines) + "\n")
        self.units[unit.key] = unit

    def remove_unit(self, key):
        path = self.unit_file(key)
        if os.path.exists(path):
            os.remove(path)
        self.units.pop(key, None)

    def write_marker(self):
        lines = [
            "# The iOS commit Android is synced to. Written by ./build.sh sync init and sync mark --commit.",
            f"ios_commit = {_quote(self.marker.ios_commit)}",
            f"synced_at = {_quote(self.marker.synced_at)}",
        ]
        for path, blob in sorted(self.marker.shared.items()):
            lines += ["", "[[shared]]", f"path = {_quote(path)}", f"blob = {_quote(blob)}"]
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, MARKER_FILE), "w") as handle:
            handle.write("\n".join(lines) + "\n")

    def unit_for(self, name, config):
        """Finds a unit by key, iOS path or Android path."""
        name = name.rstrip("/")
        if name in self.units:
            return self.units[name]
        for unit in self.units.values():
            if name in unit.ios or name in unit.android:
                return unit
            if any(p.endswith("/" + name) for p in list(unit.ios) + list(unit.android)):
                return unit
        key = config.ios_unit(name)
        if key and key in self.units:
            return self.units[key]
        return None


def _quote(text):
    return '"' + str(text).replace("\\", "\\\\").replace('"', '\\"') + '"'
