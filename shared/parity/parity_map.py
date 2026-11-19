"""Compares iOS and Android symbols unit by unit and decides which rows fail the gate."""

import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field

from parity_symbols import android_symbols, ios_symbols

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
MEMBER_KINDS = ("property", "function")
STRICT_KINDS = ("type", "property", "function", "case")
GATED = ("stub", "partial", "ported")


@dataclass
class Row:
    unit: str
    tier: str
    status: str             # matching, missing_on_android, misnamed, moved, signature_drift, ios_only, deferred, android_only
    ios: object = None      # Symbol
    android: object = None  # Symbol
    detail: str = ""
    failing: bool = False


@dataclass
class UnitResult:
    key: str
    tier: str
    ledger_status: str
    rows: list = field(default_factory=list)
    android_files: list = field(default_factory=list)
    missing_files: list = field(default_factory=list)


def edit_distance(a, b, limit=2):
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        if min(current) > limit:
            return limit + 1
        previous = current
    return previous[-1]


class Index:
    def __init__(self, symbols):
        self.symbols = symbols
        self.by_name = defaultdict(list)
        for symbol in symbols:
            self.by_name[(group(symbol.kind), symbol.owner, symbol.name)].append(symbol)
        self.names_only = defaultdict(list)
        for symbol in symbols:
            self.names_only[(group(symbol.kind), symbol.name)].append(symbol)

    def find(self, kind_group, owner, name):
        return self.by_name.get((kind_group, owner, name), [])

    def anywhere(self, kind_group, name):
        return self.names_only.get((kind_group, name), [])


def group(kind):
    return "member" if kind in MEMBER_KINDS else kind


def capitalize(name):
    return name[:1].upper() + name[1:]


def lower_first(name):
    return name[:1].lower() + name[1:]


class Comparer:
    def __init__(self, config, ios_sources=None):
        self.config = config
        self.identifier_counts = {path: Counter(IDENTIFIER.findall(text)) for path, text in (ios_sources or {}).items()}
        self.ios_only_paths = set()
        self.renames = self._parse_renames(config.renames)

    @staticmethod
    def _parse_renames(raw):
        renames = {}
        for ios_name, android_name in raw.items():
            target = android_name.split("(", 1)[0].split(" ", 1)[0]
            owner, _, name = target.rpartition(".")
            renames[ios_name.split("(", 1)[0]] = (owner.rsplit(".", 1)[-1] if owner else "", name)
        return renames

    def compare(self, units, ios_files, android_files):
        """units: list of (key, ledger status, ios paths, android paths). Files map path -> extracted entry."""
        android_by_path = {path: android_symbols(entry) for path, entry in android_files.items()}
        global_index = Index([s for symbols in android_by_path.values() for s in symbols])
        self.ios_only_paths = {path for key, status, ios_paths, _ in units if status == "ios-only" for path in ios_paths}
        results = []
        matched_android = set()
        for key, status, ios_paths, android_paths in units:
            tier = self._unit_tier(ios_paths)
            result = UnitResult(key, tier, status)
            present = [p for p in android_paths if p in android_by_path]
            result.android_files = present
            result.missing_files = [p for p in android_paths if p not in android_by_path]
            unit_symbols = [s for p in present for s in android_by_path[p]]
            unit_index = Index(unit_symbols)
            ios_list = [s for p in ios_paths if p in ios_files for s in ios_symbols(ios_files[p])]
            for symbol in ios_list:
                row = self._match(key, tier, status, symbol, unit_index, global_index, present)
                if row is None:
                    continue
                if row.android is not None and row.status in ("matching", "signature_drift"):
                    matched_android.add(id(row.android))
                result.rows.append(row)
            self._find_misnamed(result, unit_symbols, matched_android)
            results.append(result)
        extras = self._android_extras(results, android_by_path, matched_android)
        return results, extras

    def _unit_tier(self, ios_paths):
        tiers = {self.config.tier(p) for p in ios_paths}
        for tier in ("strict", "component", "other"):
            if tier in tiers:
                return tier
        return "other"

    def _checked(self, tier, symbol):
        if symbol.kind in ("script", "test"):
            return True
        if not symbol.path.startswith(self.config.ios_root + "/"):
            return False
        if tier == "strict":
            return symbol.kind in STRICT_KINDS
        if tier == "component":
            return symbol.kind == "view"
        return symbol.kind in STRICT_KINDS or symbol.kind == "view"

    def _match(self, key, tier, status, symbol, unit_index, global_index, present):
        if symbol.kind == "view" and tier == "strict":
            tier = "component"
        if not self._checked(tier, symbol):
            return None
        row = Row(key, tier, "matching", ios=symbol)
        if status == "ios-only":
            row.status = "ios_only"
            return row
        if status == "deferred":
            row.status = "deferred"
            return row
        reason = self._ios_only(symbol)
        if reason:
            row.status, row.detail = "ios_only", reason
            return row

        if symbol.kind == "function" and symbol.name == "init":
            candidates = self._constructor(symbol, unit_index, global_index)
        else:
            candidates = self._lookup(symbol, unit_index)
        if candidates:
            row.android = candidates[0]
            if symbol.kind == "function":
                self._check_signature(row, candidates)
            return self._finish(row, status)

        elsewhere = self._lookup(symbol, global_index, strict_owner=True)
        elsewhere = [c for c in elsewhere if c.path not in present]
        if elsewhere:
            row.status = "moved"
            row.android = elsewhere[0]
            row.detail = f"found in {elsewhere[0].path}:{elsewhere[0].line}"
            return self._finish(row, status)

        reason = self._only_called_from_ios_only(symbol)
        if reason:
            row.status, row.detail = "ios_only", reason
            return row
        row.status = "missing_on_android"
        return self._finish(row, status)

    def _constructor(self, symbol, unit_index, global_index):
        """Kotlin constructors live with their class, or are factory functions named after the type."""
        renamed = self.renames.get(f"{symbol.owner}.init")
        if renamed:
            owner, name = renamed
            return unit_index.find("member", owner, name) + global_index.find("member", owner, name)
        owners = self._owners(symbol.owner)
        found = []
        for owner in owners:
            found += unit_index.find("member", "", owner) + global_index.find("member", owner, "init")
        if found:
            return found
        if not symbol.params:
            for owner in owners:
                classes = [t for t in global_index.anywhere("type", owner) if t.detail in ("class", "object")]
                if classes:
                    return classes
        return []

    def _owners(self, owner):
        """The owner, its framework stand-in, and the Kotlin name of a renamed type."""
        owners = [owner]
        mapped = self.config.type_map.get(owner)
        if mapped:
            owners.append(mapped)
        renamed = self.renames.get(owner)
        if renamed and not renamed[0] and renamed[1][:1].isupper() and renamed[1] not in owners:
            owners.append(renamed[1])
        return owners

    def _finish(self, row, status):
        hard = row.status in ("misnamed", "moved")
        missing = row.status == "missing_on_android"
        if status not in GATED:
            row.failing = False
        elif hard:
            row.failing = True
        elif missing:
            if row.ios.kind in ("script", "test"):
                row.failing = status == "ported"
            elif row.tier == "strict":
                row.failing = True
            else:
                row.failing = status == "ported"
        return row

    def _names_for(self, symbol):
        """Kotlin (owner, name) pairs that count as the twin of an iOS symbol."""
        renamed = None
        for name in (f"{symbol.owner}.{symbol.name}" if symbol.owner else symbol.name, symbol.name):
            if name in self.renames:
                renamed = self.renames[name]
                break
        if renamed:
            owner, name = renamed
            return [(owner, name), ("", name)]
        if symbol.kind == "case":
            names = [capitalize(symbol.name)] if self.config.enum_case == "capitalize_first" else []
            return [(symbol.owner, n) for n in names + [symbol.name]]
        if symbol.kind == "view":
            if symbol.detail == "ViewExtension":
                return [("", symbol.name), ("", capitalize(symbol.name))]
            if symbol.detail == "ViewModifier":
                base = symbol.name[: -len("Modifier")] if symbol.name.endswith("Modifier") else symbol.name
                return [("", symbol.name), ("", lower_first(symbol.name)), ("", base), ("", lower_first(base))]
            if symbol.detail == "ButtonStyle":
                return [("", symbol.name), ("", lower_first(symbol.name))]
            return [("", symbol.name)]
        if symbol.kind == "function" and symbol.name == "init":
            return [(owner, "init") for owner in self._owners(symbol.owner)]
        if symbol.kind in ("script", "test"):
            return [(symbol.owner, symbol.name)]
        if not symbol.owner:
            return [("", symbol.name)]
        return [(owner, symbol.name) for owner in self._owners(symbol.owner)] + [("", symbol.name)]

    def _lookup(self, symbol, index, strict_owner=False):
        kind_group = group(symbol.kind)
        pairs = self._names_for(symbol)
        if strict_owner and symbol.kind != "view":
            pairs = pairs[:1] if symbol.owner else pairs
        found = []
        for owner, name in pairs:
            if symbol.kind == "view":
                found += [s for s in index.anywhere("view", name)]
                found += [s for s in index.anywhere("type", name) if s.detail != "companion"]
                continue
            if symbol.kind == "type":
                found += [s for s in index.anywhere("type", name) if s.detail != "companion"]
                continue
            found += index.find(kind_group, owner, name)
            if symbol.kind == "case":
                found += index.find("type", owner, name)
        unique = []
        for s in found:
            if s not in unique:
                unique.append(s)
        unique.sort(key=lambda s: s.owner != symbol.owner)
        return unique

    def _check_signature(self, row, candidates):
        symbol = row.ios
        functions = [c for c in candidates if c.kind == "function"]
        if not functions:
            return
        expected = self.expected_params(symbol)
        if symbol.name == "init":
            for candidate in functions:
                if self._params_fit(expected, candidate.params, allow_defaults=True):
                    row.android = candidate
                    return
            row.status = "missing_on_android"
            row.android = None
            row.detail = f"no Kotlin constructor or factory takes ({', '.join(expected)})"
            return
        same_arity = [c for c in functions if len(c.params) == len(symbol.params)]
        if not same_arity:
            row.status = "signature_drift"
            row.android = functions[0]
            row.detail = f"{len(symbol.params)} parameters on iOS, {len(functions[0].params)} on Android"
            return
        for candidate in same_arity:
            if self._params_fit(expected, candidate.params):
                row.android = candidate
                return
        row.android = same_arity[0]
        if f"{symbol.owner}.{symbol.name}" in self.renames or symbol.name in self.renames:
            return
        row.status = "signature_drift"
        row.detail = f"parameters ({', '.join(expected)}) on iOS, ({', '.join(same_arity[0].params)}) on Android"

    @staticmethod
    def _params_fit(expected, actual, allow_defaults=False):
        if len(actual) < len(expected) or (len(actual) > len(expected) and not allow_defaults):
            return False
        if len(actual) == len(expected):
            return all(e == "_" or e == a for e, a in zip(expected, actual))
        return all(e == "_" or e in actual for e in expected)

    def expected_params(self, symbol):
        names = []
        for label, name in zip(symbol.labels, symbol.params):
            if label == "_" or label in self.config.kotlin_keywords:
                names.append(name)
            else:
                names.append(label)
        return names

    def _find_misnamed(self, result, unit_symbols, matched_android):
        taken = set(matched_android)
        for row in result.rows:
            if row.status != "missing_on_android":
                continue
            symbol = row.ios
            best = None
            for candidate in unit_symbols:
                if id(candidate) in taken or group(candidate.kind) != group(symbol.kind):
                    continue
                if symbol.kind != "type" and candidate.owner != symbol.owner:
                    continue
                if candidate.name == symbol.name:
                    continue
                if candidate.name.lower() == symbol.name.lower() or edit_distance(candidate.name, symbol.name) <= 2:
                    if self._has_ios_twin(candidate, result):
                        continue
                    best = candidate
                    break
            if best:
                taken.add(id(best))
                row.status = "misnamed"
                row.android = best
                row.detail = f"Android has {best.name} at {best.path}:{best.line}"
                row.failing = result.ledger_status in GATED

    @staticmethod
    def _has_ios_twin(candidate, result):
        return any(r.ios.name == candidate.name and r.ios.owner == candidate.owner for r in result.rows)

    def _ios_only(self, symbol):
        if symbol.kind == "type":
            reason = self.config.ios_only_conformance(symbol.conformances)
            if reason:
                return reason
        return self.config.ios_only_symbol(symbol.names())

    def _only_called_from_ios_only(self, symbol):
        if not self.identifier_counts or not self.ios_only_paths or symbol.kind in ("script", "test", "view"):
            return None
        callers = set()
        for path, counts in self.identifier_counts.items():
            count = counts.get(symbol.name, 0)
            if path == symbol.path:
                count -= 1
            if count > 0:
                callers.add(path)
        if callers and callers <= self.ios_only_paths:
            return "called only from iOS-only files"
        return None

    def _android_extras(self, results, android_by_path, matched_android):
        """Android symbols with no iOS twin in strict-tier units, and Android files that belong to no unit."""
        extras = []
        unit_files = {}
        for result in results:
            for path in result.android_files:
                unit_files.setdefault(path, result)
        matched_names = set()
        case_types = set()
        for result in results:
            for row in result.rows:
                if row.android is not None:
                    matched_names.add((row.android.path, row.android.owner, row.android.name))
                    if row.ios.kind == "case":
                        case_types.add(row.android.name)
        for path, symbols in sorted(android_by_path.items()):
            result = unit_files.get(path)
            if result is None:
                reason = self.config.android_only_file(path)
                extras.append(Row(path, "other", "android_only", failing=reason is None,
                                  detail=reason or "Android file with no iOS twin and no reason in parity.toml"))
                continue
            if self.config.android_only_file(path):
                continue
            if result.tier != "strict" or result.ledger_status not in GATED:
                continue
            for symbol in symbols:
                if symbol.kind not in ("function", "property", "type"):
                    continue
                if (symbol.path, symbol.owner, symbol.name) in matched_names:
                    continue
                if symbol.kind == "property" and symbol.owner in case_types:
                    continue
                if self._kotlin_plumbing(symbol):
                    continue
                reason = self.config.android_only_symbol(symbol.names() + ([symbol.owner] if symbol.owner else []))
                is_handler = symbol.kind == "function" and re.match(r"on[A-Z]", symbol.name) and symbol.owner == "AppState"
                extras.append(Row(result.key, result.tier, "android_only", android=symbol,
                                  detail=reason or ("handler with no iOS twin" if is_handler else "no iOS twin"),
                                  failing=reason is None))
        return extras

    @staticmethod
    def _kotlin_plumbing(symbol):
        if symbol.kind == "function" and symbol.name in ("init", "equals", "hashCode", "toString", "invoke", "serialize",
                                                         "deserialize", "copy", "component1"):
            return True
        if symbol.kind == "property" and symbol.name in ("descriptor", "rawValue", "allCases", "entries"):
            return True
        if symbol.kind == "type" and symbol.detail == "companion":
            return True
        return False
