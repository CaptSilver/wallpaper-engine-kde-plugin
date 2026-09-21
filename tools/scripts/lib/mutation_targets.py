#!/usr/bin/env python3
"""Ground truth for tools/scripts/mutation.sh's target and source lists, read
straight out of tests/CMakeLists.txt.

That file is the one place stating which tst_* targets carry -fpass-plugin and
which src/*.cpp each of them compiles.  A copy of it kept in a script diverges
the moment a target is added, and the failure is silent: an unmapped source
makes `mutation.sh --diff-only` skip the work and still report green.  Landing
a new instrumented target only needs its add_executable()/-fpass-plugin block
there; mutation.sh and its self-test both read it through this.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ADD_EXECUTABLE_RE = re.compile(r"add_executable\(\s*(tst_[a-zA-Z_]+)\s*(.*?)\)", re.S)
SOURCE_RE = re.compile(r"\$\{WEKDE_SRC_DIR\}/([a-zA-Z0-9_./]+\.(?:cpp|hpp|h))")
COMPILE_OPTIONS_RE = re.compile(r"target_compile_options\(\s*(tst_[a-zA-Z_]+)")
PASS_PLUGIN = "-fpass-plugin=${MULL_PLUGIN_PATH}"


def instrumented_targets(text: str) -> set[str]:
    """Every tst_* target whose target_compile_options() carries
    -fpass-plugin=${MULL_PLUGIN_PATH} somewhere in tests/CMakeLists.txt.
    Mirrors `grep -B2 -F -- '-fpass-plugin=${MULL_PLUGIN_PATH}'` followed by a
    grep for the owning target_compile_options() call."""
    lines = text.splitlines()
    found: set[str] = set()
    for i, line in enumerate(lines):
        if PASS_PLUGIN not in line:
            continue
        window = [line, lines[i - 1] if i >= 1 else "", lines[i - 2] if i >= 2 else ""]
        for candidate in window:
            m = COMPILE_OPTIONS_RE.search(candidate)
            if m:
                found.add(m.group(1))
                break
    return found


def target_sources(text: str) -> dict[str, set[str]]:
    """target -> WEKDE_SRC_DIR-relative sources (as src/...) compiled into
    it, merged across every add_executable() call for that name --
    tst_filehelper has two, gated on MPV_FOUND/else, with different source
    lists."""
    result: dict[str, set[str]] = {}
    for m in ADD_EXECUTABLE_RE.finditer(text):
        name, body = m.group(1), m.group(2)
        srcs = {f"src/{s}" for s in SOURCE_RE.findall(body)}
        result.setdefault(name, set()).update(srcs)
    return result


def with_sibling_headers(repo_root: pathlib.Path,
                          src_to_targets: dict[str, set[str]]) -> dict[str, set[str]]:
    """A change to FileHelper.hpp should map to the same target(s) as
    FileHelper.cpp.  Headers are almost never listed as add_executable()
    sources themselves (PluginInfo.hpp, captured directly above, is the one
    exception) -- infer the rest from the .cpp/.hpp pairing on disk."""
    out = {src: set(targets) for src, targets in src_to_targets.items()}
    for src, targets in src_to_targets.items():
        if not src.endswith(".cpp"):
            continue
        hpp = src[: -len(".cpp")] + ".hpp"
        if (repo_root / hpp).exists():
            out.setdefault(hpp, set()).update(targets)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmakelists", type=pathlib.Path, help="path to tests/CMakeLists.txt")
    ap.add_argument("--targets", action="store_true",
                     help="print instrumented tst_* target names, one per line")
    ap.add_argument("--sources", action="store_true",
                     help="print 'src/File.ext<TAB>target' lines, one per (source, owning target) pair")
    args = ap.parse_args()
    if not args.targets and not args.sources:
        ap.error("pass --targets and/or --sources")

    text = args.cmakelists.read_text()
    instrumented = instrumented_targets(text)
    if not instrumented:
        print("mutation_targets.py: no -fpass-plugin targets found in "
              f"{args.cmakelists} -- MULL_PLUGIN_PATH marker text may have changed",
              file=sys.stderr)
        return 1

    if args.targets:
        for t in sorted(instrumented):
            print(t)

    if args.sources:
        by_target = target_sources(text)
        rows: dict[str, set[str]] = {}
        for t in sorted(instrumented):
            for src in by_target.get(t, ()):
                rows.setdefault(src, set()).add(t)
        rows = with_sibling_headers(args.cmakelists.resolve().parent.parent, rows)
        for src in sorted(rows):
            for t in sorted(rows[src]):
                print(f"{src}\t{t}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
