# Dogfooding run results (git-ignored)

This directory holds the output of dogfooding runs. Its contents are
git-ignored on purpose: only this README and the `.gitignore` are tracked, so
the directory stays visible in the source viewer while run artifacts never
land in `git status`.

Each run writes to its own subdirectory:

```
results/<target>/<label>/
  compile_commands.json   the CDB Bear captured this run
  build.log               stdout+stderr of the in-container build
  golden-diff.txt         human-readable golden comparison (on mismatch)
  golden-diff.json        machine-readable golden comparison (on mismatch)
```

`<label>` is supplied with `--label` (default `local`), so reruns under
different labels do not overwrite each other and can be compared after the
fact. The durable, reviewable goldens live separately under
`tests/dogfooding/goldens/` and ARE tracked.
