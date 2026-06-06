# Contributing

Thanks for wanting to help out. Here's what you need to know to get a change landed.

## Getting set up

```sh
git clone https://github.com/CaptSilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin
git submodule update --init --force --recursive
```

Don't skip the submodule — the `backend_scene` Vulkan renderer is most of the codebase, and the build dies at `add_subdirectory(backend_scene)` without it. For binary installs, see the [README](README.md).

## Build and test

There's no cloud CI; everything runs locally through one script:

```sh
git config core.hooksPath tools/scripts/git-hooks   # install the pre-push hook
cmake -B build -S .
tools/scripts/preflight.sh                          # lint + build + tests + fuzz smoke, ~3–5 min
```

The pre-push hook runs that same gate on every `git push`. It takes a few minutes and runs quietly — that's it working, not hanging — so resist the urge to reach for `--no-verify` on anything non-trivial. It catches real regressions.

One gotcha: the gate runs long enough that GitHub sometimes drops an idle SSH connection mid-push (you'll see exit 141). Set this once and it stops happening:

```sh
git config core.sshCommand 'ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=60'
```

## Formatting

We use `.clang-format` — 4-space indent, 100-column lines. Format your changes with:

```sh
tools/scripts/preflight.sh --fix
```

Don't run `clang-format -i` across the whole tree; the formatter version drifts between machines and a blanket reformat trips the lint check on lines you never touched. Keep formatting in its own commit, separate from real changes.

## Pull requests

Commit straight to `main` or use a branch, whichever suits you — PRs target `main`. Small, focused PRs are far easier to review than one giant one.

If your change touches `src/backend_scene/`, that's a separate repo ([wallpaper-scene-renderer](https://github.com/CaptSilver/wallpaper-scene-renderer)). Land the change there first, then bump the pointer here (`git add src/backend_scene`) in its own commit. Always push the submodule before the parent — a parent commit pointing at an unpushed submodule SHA breaks fresh clones.

## Tests

New code should come with tests. There are four places they live:

| What | Where |
|---|---|
| C++ units | `tests/tst_<unit>.cpp` |
| QML units | `tests/qml/tst_<unit>.qml` |
| JavaScript units | `tests/js/<unit>.test.mjs` |
| Renderer units | `src/backend_scene/src/Test/*.cpp` |

No need to memorize how to run each — `preflight.sh` exercises them all. If you're fixing a wallpaper-specific bug, before/after evidence in the PR helps a lot: a screenshot, or output from one of the `WEKDE_*` diagnostic variables.

## Security

Found a vulnerability? Please don't open a public issue — see [SECURITY.md](SECURITY.md) for the private reporting path.
