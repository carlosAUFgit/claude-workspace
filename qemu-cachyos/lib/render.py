#!/usr/bin/env python3
"""Substitute @TOKEN@ placeholders in a domain template.

Used by 04-create-windows-vm.sh and exercised directly by
tests/test-render.sh, so both go through identical code.

Usage:
    render.py TEMPLATE OUTPUT KEY=VALUE... [--file KEY=PATH]...

Values given with --file are read from a file, which is how the multi-line
<vcpupin>/<hostdev> blocks get in without any shell quoting hazard.
"""
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2

    template, output = argv[1], argv[2]
    subs = {}
    args = argv[3:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--file":
            i += 1
            key, _, path = args[i].partition("=")
            with open(path) as fh:
                subs[key] = fh.read().rstrip("\n")
        else:
            key, _, value = arg.partition("=")
            subs[key] = value
        i += 1

    with open(template) as fh:
        text = fh.read()

    for key, value in subs.items():
        text = text.replace("@%s@" % key, value)

    # Refuse to emit a domain with unresolved placeholders: libvirt would
    # either reject it with an opaque parse error or, worse, accept a literal
    # "@MEM_KIB@" somewhere it is treated as a string.
    leftover = sorted(set(
        tok for tok in __import__("re").findall(r"@[A-Z_][A-Z0-9_]*@", text)
    ))
    if leftover:
        sys.stderr.write("unsubstituted tokens: %s\n" % " ".join(leftover))
        return 1

    with open(output, "w") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
