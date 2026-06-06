# Fuzz seed corpora

Each subdirectory holds minimised seed inputs for one libFuzzer target.
These are read by `tools/scripts/preflight.sh`'s fuzz block as the input
basis for the 20-second cold-start gate.

## Workflow

### Refresh after a long fuzz session

After running `tools/scripts/fuzz/run.sh <target> <seconds> both` for an
extended period (e.g., overnight), the hot corpus at
`build/sub/fuzz-corpus-<target>/` may contain new edges. Minimise back
into this directory:

```bash
tools/scripts/fuzz/minimize.sh <target>
```

The script invokes the target binary with `-merge=1 -reduce_inputs=1`
to keep one representative per unique edge. Commit the diff in a PR;
reviewers care about count + coverage gain, not file contents.

### Initial seed sourcing

- `WPMdlParser`, `WPTexImageParser`, `WPPkgFs`: minimal synthetic
  header inputs (the format-tag prefix bytes the parser branches on).
  Refresh from a Steam Workshop install via
  `tools/scripts/fuzz/build-corpus.sh` when available.
- `WPSceneParser`, `WPJsonParse`: seeded from
  `tests/fixtures/smoke_scene/scene.json`.
- `WPShaderParser`, `WPShaderCompile`: seeded from
  `tests/fixtures/smoke_scene/shaders/effects/`.
- `WPParticleParser`, `WPSoundParser`: synthetic JSON exercising the
  initializer/operator and sound-config factories.

### Size budget

Each `seed/` directory is capped at 200 KB / 50 files. Preflight runs
a `du` gate that fails on overflow.
