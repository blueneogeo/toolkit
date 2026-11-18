"""Turns extractor output into comparable symbols: one per type, property, function, enum case, view, script and test."""

from dataclasses import dataclass, field


@dataclass
class Symbol:
    kind: str           # type, property, function, case, view, script, test
    owner: str          # simple name of the owning type, "" at top level
    name: str
    path: str
    line: int = 0
    key: str = ""       # functions: name/arity
    labels: list = field(default_factory=list)
    params: list = field(default_factory=list)
    access: str = "internal"
    debug: bool = False
    static: bool = False
    hash: str = ""
    conformances: list = field(default_factory=list)
    detail: str = ""    # view kind, type kind

    @property
    def ident(self):
        base = f"{self.owner}.{self.name}" if self.owner else self.name
        if self.kind == "function":
            return f"{self.owner}.{self.key}" if self.owner else self.key
        if self.kind in ("view", "script", "test"):
            return f"{self.kind}:{base}"
        return base

    @property
    def display(self):
        if self.kind == "function":
            labels = "".join(f"{label}:" for label in self.labels)
            base = f"{self.name}({labels})"
        else:
            base = self.name
        return f"{self.owner}.{base}" if self.owner else base

    def names(self):
        """Names an exemption pattern can match."""
        out = [self.name, self.display, self.ident]
        if self.owner:
            out.append(f"{self.owner}.{self.name}")
        return out


def simple(name):
    name = name.split("<", 1)[0]
    return name.rsplit(".", 1)[-1] if name else ""


def owner_of(name):
    name = name.split("<", 1)[0].replace(".Companion", "")
    if name.endswith("Companion"):
        name = name[: -len("Companion")].rstrip(".")
    return simple(name)


def ios_symbols(entry):
    """Symbols of one extracted Swift file."""
    path = entry["path"]
    symbols = []

    def add_type(info, owner):
        symbols.append(Symbol("type", owner, info["name"], path, info.get("line", 0), access=info.get("access", "internal"),
                              debug=info.get("debug", False), hash=info.get("hash", ""),
                              conformances=info.get("conformances", []), detail=info.get("kind", "")))
        add_members(info, info["name"], info.get("debug", False))

    def add_members(info, owner, debug):
        for prop in info.get("properties", []):
            symbols.append(Symbol("property", owner, prop["name"], path, prop.get("line", 0), access=prop.get("access", "internal"),
                                  debug=debug or prop.get("debug", False), static=prop.get("static", False), hash=prop.get("hash", "")))
        for fn in info.get("functions", []):
            symbols.append(function_symbol(fn, owner, path, debug))
        for case in info.get("cases", []):
            symbols.append(Symbol("case", owner, case["name"], path, case.get("line", 0), debug=debug or case.get("debug", False),
                                  hash=case.get("hash", "")))
        for nested in info.get("types", []):
            add_type(nested, owner)

    for info in entry.get("types", []):
        add_type(info, owner_of(info["parent"]) if info.get("parent") else "")
    for ext in entry.get("extensions", []):
        owner = owner_of(ext["of"])
        if owner == "View":
            continue
        for prop in ext.get("properties", []):
            symbols.append(Symbol("property", owner, prop["name"], path, prop.get("line", 0), access=prop.get("access", "internal"),
                                  debug=ext.get("debug", False) or prop.get("debug", False), static=prop.get("static", False),
                                  hash=prop.get("hash", "")))
        for fn in ext.get("functions", []):
            symbols.append(function_symbol(fn, owner, path, ext.get("debug", False)))
    for fn in entry.get("functions", []):
        symbols.append(function_symbol(fn, "", path, False))
    for prop in entry.get("properties", []):
        symbols.append(Symbol("property", "", prop["name"], path, prop.get("line", 0), access=prop.get("access", "internal"),
                              debug=prop.get("debug", False), hash=prop.get("hash", "")))
    for view in entry.get("views", []):
        symbols.append(Symbol("view", "", view["name"], path, view.get("line", 0), access=view.get("access", "internal"),
                              detail=view.get("kind", ""), key=view.get("key", "")))
    for script in entry.get("debug_scripts", []):
        symbols.append(Symbol("script", "", script["name"], path, script.get("line", 0), detail=script.get("type", "")))
    for test in entry.get("tests", []):
        symbols.append(Symbol("test", "", test["class"], path))
        for method in test.get("methods", []):
            symbols.append(Symbol("test", test["class"], method, path))
    return symbols


def function_symbol(fn, owner, path, debug):
    name = fn["name"]
    return Symbol("function", owner, name, path, fn.get("line", 0), key=fn.get("key", name), labels=fn.get("labels", []),
                  params=fn.get("params", []), access=fn.get("access", "internal"), debug=debug or fn.get("debug", False),
                  static=fn.get("static", False), hash=fn.get("hash", ""))


def android_symbols(entry):
    """Symbols of one extracted Kotlin file. Extension members are owned by their receiver."""
    path = entry["path"]
    symbols = []

    def add_type(info, owner):
        symbols.append(Symbol("type", owner, info["name"], path, info.get("line", 0), access=info.get("access", "public"),
                              conformances=info.get("conformances", []), detail=info.get("kind", "")))
        own = info["name"]
        if info.get("kind") == "companion":
            own = owner
        for prop in info.get("properties", []):
            symbols.append(Symbol("property", own, prop["name"], path, prop.get("line", 0), access=prop.get("access", "public"),
                                  static=prop.get("static", False), detail="stub" if prop.get("stub") else ""))
        for fn in info.get("functions", []):
            symbols.append(kotlin_function(fn, own, path))
        for case in info.get("cases", []):
            symbols.append(Symbol("case", own, case["name"], path, case.get("line", 0)))
        for nested in info.get("types", []):
            if nested.get("kind") in ("class", "object") and nested.get("name"):
                symbols.append(Symbol("case", own, nested["name"], path, nested.get("line", 0)))
            add_type(nested, own)
        if owner == "" and info.get("conformances"):
            for parent in info["conformances"]:
                symbols.append(Symbol("case", parent, info["name"], path, info.get("line", 0)))

    for info in entry.get("types", []):
        add_type(info, "")
    for fn in entry.get("functions", []):
        symbols.append(kotlin_function(fn, owner_of(fn.get("receiver", "")), path))
    for prop in entry.get("properties", []):
        symbols.append(Symbol("property", owner_of(prop.get("receiver", "")), prop["name"], path, prop.get("line", 0),
                              access=prop.get("access", "public"), detail="stub" if prop.get("stub") else ""))
    for view in entry.get("views", []):
        symbols.append(Symbol("view", "", view["name"], path, view.get("line", 0), access=view.get("access", "public"),
                              detail=view.get("kind", ""), key=view.get("key", "")))
    for script in entry.get("debug_scripts", []):
        symbols.append(Symbol("script", "", script["name"], path, script.get("line", 0), detail=script.get("type", "")))
    tests = list(entry.get("tests", []))
    if is_test_source(path):
        # An abstract base, iOS's XCTestCase subclass that the tests inherit from, counts as a test class without @Test methods.
        named = {test["class"] for test in tests}
        tests += [{"class": info["name"], "methods": []} for info in entry.get("types", [])
                  if "abstract" in info.get("modifiers", []) and info.get("name") and info["name"] not in named]
    for test in tests:
        symbols.append(Symbol("test", "", test["class"], path))
        for method in test.get("methods", []):
            symbols.append(Symbol("test", test["class"], method, path))
    return symbols


def is_test_source(path):
    """A file of the JVM tests or the instrumented ones (Gradle's src/test and src/androidTest)."""
    return "/src/test/" in f"/{path}" or "/src/androidTest/" in f"/{path}"


def kotlin_function(fn, owner, path):
    name = fn["name"]
    if name == "invoke" and fn.get("receiver", "").endswith("Companion"):
        name = "init"
    return Symbol("function", owner, name, path, fn.get("line", 0), key=fn.get("key", fn["name"]),
                  params=fn.get("params", []), access=fn.get("access", "public"), static=fn.get("static", False),
                  detail="stub" if fn.get("stub") else "")
