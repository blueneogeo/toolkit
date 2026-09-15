import re
import sys


def main():
    prev = None
    stdin = sys.stdin.buffer
    stdout = sys.stdout
    while True:
        line = stdin.readline()
        if line == b"":
            break
        if prev is not None:
            stdout.write(prev.decode("utf-8", errors="replace"))
            stdout.flush()
        prev = line
    if prev is None:
        sys.exit(99)
    text = prev.decode("utf-8", errors="replace")
    stripped = text[:-1] if text.endswith("\n") else text
    m = re.fullmatch(r"__TURN_SRV_EXIT=(-?[0-9]+)", stripped)
    if m:
        code = int(m.group(1))
        sys.exit(code if 0 <= code <= 125 else 1)
    if text.endswith("\n"):
        stdout.write(text)
    else:
        stdout.write(text + "\n")
    stdout.flush()
    sys.exit(1)


if __name__ == "__main__":
    main()
