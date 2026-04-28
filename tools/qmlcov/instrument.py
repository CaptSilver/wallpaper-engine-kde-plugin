#!/usr/bin/env python3
"""
QML coverage instrumenter.

Rewrites every `function`/signal-handler/lifecycle-handler entry to record a
tick into a runtime singleton (`Cov`), and emits a catalog of all
instrumented units with their LOC weight.

Usage:
    instrument.py --src plugin/contents/ui --out build/_qmlcov/instrumented \
        --catalog build/_qmlcov/catalog.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

# A "unit" is an executable scope we track:
#   function foo(...) { ... }
#   onSomething: { ... }
#   onSomething: function(...) { ... }
#   Component.onCompleted: { ... }
#   Component.onDestruction: { ... }
#
# We also count any *anonymous-function expression* that has its body at top
# level inside a property assignment like `property var f: function() { ... }`
# because those are common in this codebase (e.g. lock primitives in Common.qml).

_FUNC = re.compile(
    r"""
    \b function \s+
    (?P<name> [A-Za-z_$][A-Za-z0-9_$]* )
    \s* \( [^)]* \) \s* \{
    """,
    re.VERBOSE,
)

_HANDLER_BLOCK = re.compile(
    r"""
    (?P<indent> ^ [ \t]* )
    (?P<name> on[A-Z][A-Za-z0-9_]* | Component\.onCompleted | Component\.onDestruction )
    \s* : \s* \{
    """,
    re.VERBOSE | re.MULTILINE,
)

_HANDLER_FUNC = re.compile(
    r"""
    (?P<indent> ^ [ \t]* )
    (?P<name> on[A-Z][A-Za-z0-9_]* | Component\.onCompleted | Component\.onDestruction )
    \s* : \s* function \s* \( [^)]* \) \s* \{
    """,
    re.VERBOSE | re.MULTILINE,
)

_PROP_ANON_FUNC = re.compile(
    r"""
    (?P<indent> ^ [ \t]* )
    property \s+ var \s+
    (?P<name> [A-Za-z_$][A-Za-z0-9_$]* )
    \s* : \s* function \s* \( [^)]* \) \s* \{
    """,
    re.VERBOSE | re.MULTILINE,
)


@dataclass
class Unit:
    file: str       # path relative to --src root
    name: str       # function or handler name
    start_line: int # 1-based line of opening `{`
    end_line: int   # 1-based line of matching `}`
    loc: int        # end_line - start_line + 1
    key: str        # "file::name@start_line" — unique


def _matching_brace(text: str, open_pos: int) -> int:
    """Return index of the `}` matching the `{` at `open_pos`, ignoring
    braces inside string literals and // line comments / /* block comments */.
    Returns -1 if no match."""
    assert text[open_pos] == "{"
    depth = 0
    i = open_pos
    n = len(text)
    in_string: str | None = None
    in_line_comment = False
    in_block_comment = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_string is not None:
            if ch == "\\":
                i += 1  # skip escaped next char
            elif ch == in_string:
                in_string = None
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                in_block_comment = True
                i += 1
            elif ch in ("'", '"', "`"):
                in_string = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def _line_at(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def instrument(text: str, file_rel: str) -> tuple[str, list[Unit]]:
    """Return (instrumented_text, units_added).

    Insertions happen right after the opening `{` of each unit. We do them
    back-to-front so earlier positions don't shift later positions."""

    units: list[Unit] = []
    insertions: list[tuple[int, str]] = []  # (pos_after_open_brace, snippet)

    # Collect matches from all three patterns.
    matches = []
    for pat in (_FUNC, _HANDLER_BLOCK, _HANDLER_FUNC, _PROP_ANON_FUNC):
        for m in pat.finditer(text):
            open_brace_pos = m.end() - 1
            assert text[open_brace_pos] == "{", (
                f"expected `{{` at end of match for {m.group(0)!r}"
            )
            matches.append((open_brace_pos, m.group("name")))

    # Dedup (same open_brace_pos can match multiple patterns; keep first name).
    seen: dict[int, str] = {}
    for pos, name in matches:
        seen.setdefault(pos, name)

    for open_brace_pos in sorted(seen):
        name = seen[open_brace_pos]
        end_pos = _matching_brace(text, open_brace_pos)
        if end_pos < 0:
            print(
                f"warning: unmatched `{{` for {name} in {file_rel}, skipping",
                file=sys.stderr,
            )
            continue
        start_line = _line_at(text, open_brace_pos)
        end_line = _line_at(text, end_pos)
        loc = end_line - start_line + 1
        # Skip 1-line empty blocks like `function() { }` — nothing to cover.
        if loc <= 1 and text[open_brace_pos + 1 : end_pos].strip() == "":
            continue
        key = f"{file_rel}::{name}@{start_line}"
        units.append(
            Unit(
                file=file_rel,
                name=name,
                start_line=start_line,
                end_line=end_line,
                loc=loc,
                key=key,
            )
        )
        snippet = f' Cov.tick("{key}");'
        insertions.append((open_brace_pos + 1, snippet))

    # Apply insertions back-to-front.
    insertions.sort(key=lambda x: x[0], reverse=True)
    out = text
    for pos, snippet in insertions:
        out = out[:pos] + snippet + out[pos:]

    # Inject `import Cov 1.0` after the last *file-level* import.
    # QML's top-level imports start at column 0; imports inside JS template
    # literals (e.g. `Qt.createQmlObject('import QtQuick 2.0; ...')`) are
    # always indented and must NOT be treated as injection points.
    if units:
        m = list(re.finditer(r"^import[ \t][^\n]*\n", out, re.MULTILINE))
        if m:
            last = m[-1]
            insert_at = last.end()
            out = out[:insert_at] + "import Cov 1.0\n" + out[insert_at:]
        else:
            # No imports? Prepend.
            out = "import Cov 1.0\n" + out

    return out, units


def walk_qml(src_root: Path) -> Iterable[Path]:
    for p in sorted(src_root.rglob("*.qml")):
        yield p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="Source QML root")
    ap.add_argument("--out", required=True, help="Output instrumented root")
    ap.add_argument("--catalog", required=True, help="Output catalog JSON")
    args = ap.parse_args()

    src_root = Path(args.src).resolve()
    out_root = Path(args.out).resolve()
    catalog_path = Path(args.catalog).resolve()

    if not src_root.is_dir():
        print(f"error: --src not a directory: {src_root}", file=sys.stderr)
        return 2

    out_root.mkdir(parents=True, exist_ok=True)

    all_units: list[Unit] = []
    file_count = 0

    for src_file in walk_qml(src_root):
        rel = src_file.relative_to(src_root).as_posix()
        out_file = out_root / rel
        out_file.parent.mkdir(parents=True, exist_ok=True)
        text = src_file.read_text(encoding="utf-8")
        instrumented, units = instrument(text, rel)
        out_file.write_text(instrumented, encoding="utf-8")
        all_units.extend(units)
        file_count += 1

    # Also copy non-.qml files (qmldir, .js) verbatim so imports continue to work.
    for src_aux in src_root.rglob("*"):
        if src_aux.is_file() and src_aux.suffix not in (".qml",):
            rel = src_aux.relative_to(src_root).as_posix()
            out_aux = out_root / rel
            out_aux.parent.mkdir(parents=True, exist_ok=True)
            out_aux.write_bytes(src_aux.read_bytes())

    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(
        json.dumps(
            {
                "src_root": str(src_root),
                "files": file_count,
                "units": [asdict(u) for u in all_units],
                "total_loc": sum(u.loc for u in all_units),
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print(
        f"instrumented {file_count} files, "
        f"{len(all_units)} units, "
        f"{sum(u.loc for u in all_units)} LOC tracked"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
