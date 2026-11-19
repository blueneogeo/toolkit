"""Runs the Swift and Kotlin extractors, caching each file's result by its git blob id."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT_PACKAGE = os.path.join(HERE, "swift")
KOTLIN_PROJECT = os.path.join(HERE, "kotlin")


class ParityError(Exception):
    pass


def run(args, cwd=None, input_text=None, check=True):
    result = subprocess.run(args, cwd=cwd, input=input_text, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ParityError(f"{' '.join(args[:4])} failed:\n{result.stderr.strip() or result.stdout.strip()}")
    return result


# Git, read-only, at the top level of the repository the project sits in


def repository_root(path):
    """Top level of the git repository a folder sits in."""
    out = run(["git", "-C", path, "rev-parse", "--show-toplevel"], check=False)
    if out.returncode != 0:
        raise ParityError(f"{path} is not inside a git repository.")
    return out.stdout.strip()


class Repo:
    def __init__(self, root):
        self.root = root

    def git(self, *args, check=True):
        return run(["git", "-C", self.root, *args], check=check).stdout

    def resolve(self, commit):
        out = run(["git", "-C", self.root, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}"], check=False)
        if out.returncode != 0:
            raise ParityError(f"Unknown commit '{commit}' in {self.root}")
        return out.stdout.strip()

    def ls_tree(self, commit, paths):
        out = self.git("ls-tree", "-r", "--full-tree", commit, "--", *paths)
        files = {}
        for line in out.splitlines():
            meta, path = line.split("\t", 1)
            _, kind, blob = meta.split()
            if kind == "blob":
                files[path] = blob
        return files

    def cat_blobs(self, blobs):
        """Contents of several blobs, read in one git process."""
        blobs = sorted(set(blobs))
        if not blobs:
            return {}
        proc = subprocess.run(["git", "-C", self.root, "cat-file", "--batch"], input=("\n".join(blobs) + "\n").encode(),
                              capture_output=True)
        if proc.returncode != 0:
            raise ParityError(proc.stderr.decode(errors="replace"))
        data = proc.stdout
        contents = {}
        pos = 0
        for blob in blobs:
            end = data.index(b"\n", pos)
            header = data[pos:end].decode().split()
            pos = end + 1
            if len(header) < 3 or header[1] == "missing":
                raise ParityError(f"Blob {blob} is not in {self.root}")
            size = int(header[2])
            contents[blob] = data[pos:pos + size]
            pos += size + 1
        return contents

    def is_ancestor(self, a, b):
        return run(["git", "-C", self.root, "merge-base", "--is-ancestor", a, b], check=False).returncode == 0

    def merge_base(self, a, b):
        return self.git("merge-base", a, b).strip()

    def touches(self, since, until, paths):
        """Whether a commit in since..until changes one of the paths."""
        if since == until:
            return False
        return bool(self.git("log", "-1", "--format=%H", f"{since}..{until}", "--", *paths).strip())


def hash_files(project_root, paths):
    """Git blob ids of working-tree files, without writing objects."""
    existing = [p for p in paths if os.path.isfile(os.path.join(project_root, p))]
    if not existing:
        return {}
    # Absolute paths: inside a larger repository, --stdin-paths reads them from its top level.
    absolute = [os.path.abspath(os.path.join(project_root, p)) for p in existing]
    out = run(["git", "-C", project_root, "hash-object", "--stdin-paths"], input_text="\n".join(absolute) + "\n").stdout
    return dict(zip(existing, out.split()))


# Tools


def _stamp(root, names):
    digest = hashlib.sha1()
    for base, _, files in sorted(os.walk(root)):
        if any(part in (".build", "build", ".gradle") for part in base.split(os.sep)):
            continue
        for name in sorted(files):
            if names(name):
                path = os.path.join(base, name)
                digest.update(path[len(root):].encode())
                with open(path, "rb") as handle:
                    digest.update(handle.read())
    return digest.hexdigest()[:12]


class Tools:
    def __init__(self, project_root, quiet=False):
        self.project_root = project_root
        self.tools_dir = os.path.join(project_root, "build", "parity-tools")
        self.cache_dir = os.path.join(project_root, "build", "parity", "cache")
        self.quiet = quiet
        self.swift_stamp = _stamp(SWIFT_PACKAGE, lambda n: n.endswith(".swift") or n == "Package.resolved")
        self.kotlin_stamp = _stamp(KOTLIN_PROJECT, lambda n: n.endswith((".java", ".kts")))

    def _say(self, text):
        if not self.quiet:
            print(text, file=sys.stderr)

    def up_to_date(self):
        swift = os.path.join(self.tools_dir, "swift")
        kotlin = os.path.join(self.tools_dir, "kotlin")
        return (os.path.exists(os.path.join(swift, "release", "parity-swift"))
                and _read(os.path.join(swift, "parity.stamp")) == self.swift_stamp
                and os.path.isdir(os.path.join(kotlin, "install", "parity-kotlin", "lib"))
                and _read(os.path.join(kotlin, "parity.stamp")) == self.kotlin_stamp)

    def swift_binary(self):
        scratch = os.path.join(self.tools_dir, "swift")
        binary = os.path.join(scratch, "release", "parity-swift")
        stamp_file = os.path.join(scratch, "parity.stamp")
        if os.path.exists(binary) and _read(stamp_file) == self.swift_stamp:
            return binary
        if not shutil.which("swift"):
            raise ParityError("swift is not installed; the iOS extractor needs it (Xcode or a Swift toolchain).")
        self._say("Building the Swift extractor (swift-syntax, about two minutes the first time).")
        result = run(["swift", "build", "-c", "release", "--package-path", SWIFT_PACKAGE, "--scratch-path", scratch],
                     check=False)
        if result.returncode != 0:
            raise ParityError("swift build of the parity extractor failed:\n" + (result.stderr or result.stdout)[-3000:])
        _write(stamp_file, self.swift_stamp)
        return binary

    def kotlin_command(self):
        build_dir = os.path.join(self.tools_dir, "kotlin")
        lib = os.path.join(build_dir, "install", "parity-kotlin", "lib")
        stamp_file = os.path.join(build_dir, "parity.stamp")
        java_home = os.environ.get("JAVA_HOME", "")
        java = os.path.join(java_home, "bin", "java") if java_home else shutil.which("java")
        if not java or not os.path.exists(java):
            raise ParityError("No JDK found for the Kotlin extractor; set JAVA_HOME or ANDROID_JAVA_HOME.")
        if not (os.path.isdir(lib) and _read(stamp_file) == self.kotlin_stamp):
            gradlew = os.path.join(self.project_root, "gradlew")
            if not os.path.exists(gradlew):
                raise ParityError(f"No Gradle wrapper at {gradlew} to build the Kotlin extractor.")
            self._say("Building the Kotlin extractor.")
            args = [gradlew, "-q", "-p", KOTLIN_PROJECT, "--project-cache-dir", os.path.join(build_dir, ".gradle"),
                    f"-PparityBuildDir={build_dir}", "installDist"]
            result = run(args[:2] + ["--offline"] + args[2:], check=False)
            if result.returncode != 0:
                result = run(args, check=False)
            if result.returncode != 0:
                raise ParityError("Gradle build of the Kotlin extractor failed:\n" + (result.stderr or result.stdout)[-3000:])
            _write(stamp_file, self.kotlin_stamp)
        return [java, "-cp", os.path.join(lib, "*"), "parity.Main"]

    # Extraction

    def extract_ios(self, repo, files):
        """files: {ios path: blob}. Returns {ios path: extracted file}."""
        return self._extract("swift", self.swift_stamp, files, lambda blobs: repo.cat_blobs(blobs),
                             lambda list_file: [self.swift_binary(), list_file])

    def extract_ios_tree(self, root, paths):
        """Extracts working-tree Swift files under root (for the iOS build hook)."""
        result = self._run_tool([self.swift_binary()], [(os.path.join(root, p), p) for p in paths])
        return {f["path"]: f for f in result}

    def extract_android(self, files):
        """files: {project path: blob}. Returns {project path: extracted file}."""
        def contents(blobs):
            by_blob = {blob: path for path, blob in files.items()}
            out = {}
            for blob in blobs:
                with open(os.path.join(self.project_root, by_blob[blob]), "rb") as handle:
                    out[blob] = handle.read()
            return out
        return self._extract("kotlin", self.kotlin_stamp, files, contents, lambda list_file: self.kotlin_command() + [list_file])

    def _extract(self, kind, stamp, files, read_blobs, command):
        cache = os.path.join(self.cache_dir, f"{kind}-{stamp}")
        os.makedirs(cache, exist_ok=True)
        results = {}
        missing = {}
        for path, blob in files.items():
            cached = os.path.join(cache, blob + ".json")
            if os.path.exists(cached):
                with open(cached) as handle:
                    entry = json.load(handle)
                entry["path"] = path
                entry["blob"] = blob
                results[path] = entry
            else:
                missing.setdefault(blob, path)
        if missing:
            contents = read_blobs(list(missing))
            suffix = ".swift" if kind == "swift" else ".kt"
            with tempfile.TemporaryDirectory(prefix="parity-") as tmp:
                pairs = []
                for blob, path in missing.items():
                    disk = os.path.join(tmp, blob + suffix)
                    with open(disk, "wb") as handle:
                        handle.write(contents[blob])
                    pairs.append((disk, blob))
                extracted = self._run_tool(command(None), pairs)
            for entry in extracted:
                blob = entry["path"]
                with open(os.path.join(cache, blob + ".json"), "w") as handle:
                    json.dump(entry, handle)
            for path, blob in files.items():
                if path not in results:
                    with open(os.path.join(cache, blob + ".json")) as handle:
                        entry = json.load(handle)
                    entry["path"] = path
                    entry["blob"] = blob
                    results[path] = entry
        return results

    def _run_tool(self, command, pairs):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            for disk, name in pairs:
                handle.write(f"{disk}\t{name}\n")
            list_file = handle.name
        try:
            args = [arg if arg is not None else list_file for arg in command]
            if list_file not in args:
                args.append(list_file)
            result = run(args, check=False)
        finally:
            os.unlink(list_file)
        if result.returncode != 0:
            raise ParityError(f"Extractor failed:\n{result.stderr[-3000:]}")
        return json.loads(result.stdout)["files"]


def _read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text + "\n")
