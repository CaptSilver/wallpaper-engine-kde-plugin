# Contributing

Thanks for your interest in Wallpaper Engine KDE Plugin. This file is the
human-facing distillation of the project workflow. (`CLAUDE.md` is an
AI-agent memory file — you don't need it as a human contributor.)

## Before you start

```bash
git clone https://github.com/CaptSilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin
git submodule update --init --force --recursive
```

The `backend_scene` submodule is the bulk of the codebase (the custom
Vulkan renderer) — `cmake -B build -S .` will fail at
`add_subdirectory(backend_scene)` without it.

For binary installs (`.rpm` / `.deb`), see [README.md](README.md).

## Local build + test gate

The project uses a single comprehensive local preflight gate
(`tools/scripts/preflight.sh`) — there is no cloud CI. Three commands get you set up:

```bash
git config core.hooksPath tools/scripts/git-hooks   # installs the pre-push hook
cmake -B build -S .
tools/scripts/preflight.sh                          # ~3-5 min: lint + submodule build + tests + fuzz smoke
```

The pre-push hook runs `preflight.sh` on every `git push`. A full run takes
3-5 minutes; a "silent" push is the hook working, not a hang. **Do not pass
`--no-verify`** on non-trivial pushes — the gate catches real regressions.

## Formatting

The project uses `.clang-format` (4-space indent, 100-column lines). The
canonical command to format your changes is:

```bash
tools/scripts/preflight.sh --fix
```

Do not run `clang-format -i` over the whole tree — the formatter version
drifts (Fedora ships `clang-format-21`), and a blanket reformat will trip
the lint leg on unrelated lines.

Format commits should always be **separate** from substantive edits.

## Branch model

Direct commits on `main` are fine; feature branches are fine. PRs target
`main`. Maintainer prefers small, focused PRs over kitchen-sink batches.

## Submodule push order

If your PR touches `src/backend_scene/`, the submodule change needs a
PR to [CaptSilver/wallpaper-scene-renderer](https://github.com/CaptSilver/wallpaper-scene-renderer)
first. Once that lands, bump the parent gitlink (`git add src/backend_scene`)
as a separate commit in this repo's PR.

Push order: **submodule first, parent second.** A parent push that points
at an unpushed submodule SHA will fail clones until the submodule push
catches up.

## Debugging hooks

The plugin honours `WEKDE_*` environment variables (full table in
[README.md](README.md#diagnostics)). If your PR fixes a wallpaper-specific
bug, please include relevant diagnostic output in the PR description — e.g.
before/after screenshots, `WEKDE_TIME_DIAG=1` output, or a `WEKDE_PIPELINE_DIAG=1`
excerpt that shows the render-graph change.

## Tests

Every new function should get a test. The project ships three test surfaces:

| Layer | Location | Runner |
|---|---|---|
| C++ unit | `tests/tst_<unit>.cpp` | qmltestrunner-qt6 / ctest |
| QML unit | `tests/qml/tst_<unit>.qml` | qmltestrunner-qt6 (via ctest) |
| JavaScript unit | `tests/js/<unit>.test.mjs` | `node --test` |
| Renderer unit | `src/backend_scene/src/Test/*.cpp` | doctest binaries |

See the spec's "Tests" section in [CLAUDE.md](CLAUDE.md) for the per-layer
invocations if you need details. The short answer is `tools/scripts/preflight.sh`
exercises all of them.

## CLAUDE.md

If you're using Claude Code or another agentic tool, `CLAUDE.md` is the
project-memory file it reads. You don't need it as a human contributor.

## Security disclosure

See [SECURITY.md](SECURITY.md) for the private vulnerability reporting path.
Do not file security bugs in the public issue tracker.
