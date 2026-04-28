# Production QML test coverage to 80%+

**Date**: 2026-04-28
**Goal**: Lift production QML test coverage from ~7% to ≥80% literal LOC, measured
by a homegrown coverage tracer.

## Current state

| Metric | Value |
|---|---|
| Production QML files | 23 |
| Production QML LOC | 3,596 |
| Tested files (any coverage) | 1 (Common.qml only) |
| Tested LOC (estimated) | ~250 |
| Current line coverage | ~7% |

Existing test harness:

- `tst_qml` runs `qmltestrunner` over `tests/qml/`
- Tests import `../../plugin/contents/ui` directly via QML relative path
- `tst_js` runs `node --test` over `tests/js/*.test.mjs`
- C++ coverage already wired with `-DCOVERAGE=ON` (Clang source-based, llvm-cov)

## Approach: A + M1 + R2

- **A** — Literal LOC coverage target (≥80%). No exclusions for "presentation
  code"; binding lines that execute on instantiation count too.
- **M1** — Homegrown QML coverage tracer (no off-the-shelf tool exists).
- **R2** — Extract pure logic to `plugin/contents/ui/js/*.mjs` when it makes a
  file dramatically more testable. Otherwise stub Plasma/KCM/pyext/wallpaper
  interfaces and exercise via `qmltestrunner`.

## Architecture

### 1. Coverage tracer (`tools/qmlcov/`)

Three pieces:

**Instrumentation script** — `tools/qmlcov/instrument.py`. Reads each `*.qml`
file under `plugin/contents/ui/` and writes an instrumented copy to a
`build/tests/_instrumented/plugin/contents/ui/` mirror tree. Each executable
construct gets a tracer call inserted at entry:

- `function foo(args) {` → `function foo(args) { __cov.tick("File.qml", 42);`
- `onSomething: {` → `onSomething: { __cov.tick("File.qml", 42);`
- `Component.onCompleted: { ... }` → instrument body
- `if (cond) { ... } else { ... }` → instrument both branches
- Top-level property assignment expressions → instrument once on parse

The script also emits `build/tests/_instrumented/catalog.json` listing every
`(file, line, kind)` registered as an executable statement.

**Runtime tracer** — `tests/qml/_cov/CovTrace.qml` singleton. Accumulates
`(file, line)` keys in a JS `Set`. Exposes a `dump()` method. Hooked from
`qmltestrunner` via a wrapper that registers an `aboutToQuit` slot.

**Report target** — CMake `qmlcov` custom target:

1. Runs `instrument.py` (idempotent, hashes inputs).
2. Sets up an instrumented test root: `build/tests/_qmlcov_root/` with
   `tests/qml/` symlinked from source, `plugin/contents/ui/` symlinked from
   the instrumented mirror. Tests' relative imports continue to work.
3. Runs `qmltestrunner` with `QMLCOV_OUT=$cov_dir/raw.json` env var.
4. Computes `coverage = |hit_lines| / |catalog_lines|`.
5. Prints per-file table.
6. Fails if `coverage < 0.80`.

### 2. Stub layer (`tests/qml/_stubs/`)

Provides QML-importable replacements for runtime-only types so production
files can be instantiated under `qmltestrunner`:

- `_stubs/PlasmaStub/` — `Plasmoid`, `PlasmaCore` types
- `_stubs/KCMStub/` — `SimpleKCM`, `ConfigModule` (plain `Item` aliases)
- `_stubs/PyextStub.qml` — implements the `Pyext` interface with in-memory
  promise resolution and configurable fixtures
- `_stubs/WallpaperContext.qml` — fakes the `wallpaper` C++ context object
  with mutable properties for `displayMode`, `pauseMode`, `userPropsJson`
- `_stubs/SceneViewerStub.qml` — replaces the `com.github.catsout.wallpaperEngineKde.SceneViewer` plugin type
- `_stubs/MpvObjectStub.qml` — replaces `MpvObject`

`QML2_IMPORT_PATH` is configured per-test to point at `_stubs/` first, so
production `import org.kde.kcmutils as KCM` resolves to our stub.

### 3. Tactical extraction

Where a QML file has clearly-pure logic, move it to `plugin/contents/ui/js/`
and `import "./js/foo.mjs" as Foo` from the QML file. Pure modules then get
covered by the existing `tst_js` Node harness (rock-solid, fast, no Qt
overhead).

Confirmed extraction candidates:

- `WallpaperListModel.qml` → `wallpaperList.mjs` (`loadItemFromJson`,
  `genSortCmp`, `filterToList`, sort comparators, JSON parsing)
- `Common.qml` → mostly already pure-functional in QML; leave in place,
  fill remaining function tests in `tst_common.qml`

## Phasing

Each phase ends with a measurable coverage delta. User reviews the diff
between phases (no autocommit).

| # | Phase | Files | Δ Coverage est. |
|--:|---|---|---:|
| 1 | Tracer + stubs scaffolding | new tooling only | 0% (baseline) |
| 2 | Tier-A pure files: Common.qml finish, WallpaperListModel.qml, Theme.qml, PowerSource.qml | 4 | +20% |
| 3 | Backend wrappers: Scene, Mpv, QtMultimedia, InfoShow, Pyext, QtWebView | 6 | +15% |
| 4 | Components: OptionItem, ColorButton, IconSvg, OptionGroup, DoubleSpinBox, Control | 7 | +10% |
| 5 | Window/main: WindowModel, main.qml | 2 | +15% |
| 6 | KCM pages: config.qml, AboutPage, SettingPage, WallpaperPage | 4 | +25% |
| 7 | Coverage gate enforcement at ≥80% | CMake/CI | — |

Cumulative target after Phase 6: ~85%, leaving headroom above the 80% gate.

## Acceptance criteria

- `cmake --build build/tests --target qmlcov` exits 0.
- Per-file coverage table shows ≥80% on all but explicitly excluded files.
- Excluded files (if any) are listed with rationale in `tools/qmlcov/exclusions.txt`.
- Existing `tst_qml`, `tst_js`, `tst_filehelper`, etc. continue to pass.
- No production QML behavior change other than:
  - Pure-logic extraction to `js/*.mjs` (refactor)
  - One-line `import` additions where extraction occurs
  - Tracer instrumentation only present in the instrumented mirror tree —
    production source files are never modified.

## Out of scope

- Visual regression tests (no plasmashell available in CI).
- WebEngineView content-rendering tests (use heavy stub instead).
- Coverage of `qwebchannel.js` (vendored Qt runtime).
- Mutation testing of QML (no Mull equivalent for QML).

## Risks

- **Instrumentation regex fragility** — QML's grammar is JS-based but has
  property-binding constructs. Mitigation: the instrumenter operates on a
  conservative subset; unmatched constructs are skipped (counted against
  coverage as un-instrumentable rather than mis-instrumented).
- **Stub fidelity** — A stubbed `Plasmoid` may diverge from real Plasma
  behavior. Mitigation: stubs expose only the API surface that production
  files call; unused properties stay undefined so use-of-undefined fails fast.
- **Coverage rot** — New production code without tests will drop the number
  silently. Mitigation: Phase 7 gates the build at 80%; CI fails if a PR
  drops below.
