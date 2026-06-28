## tests/tools

Shared test tooling. The library exposes the compilation-database comparison
and normalization logic; the binary `cdb-compare` wraps it.

## Why a separate crate

`tests/integration` depends on this library so there is one comparison
implementation, not two. `CompilationEntryMatcher` lives here and is
re-exported by the integration fixtures. Future test binaries (the dogfooding
harness) layer on the same library.

## Constraints

- ASCII only; SPDX header on every `.rs` file (see `.claude/rules/rust.md`).
- Keep dependencies minimal; prefer crates already in the workspace.
- Tests are host-independent: they operate on in-memory or small fixture CDB
  JSON, never a live build or container.

## cdb-compare

- `compare [NORM...] [--intersection] [--format human|json] A B`
  decides multiset equivalence (order-independent) and exits non-zero on
  non-equivalence.
- `normalize [--sort] [NORM...] IN [-o OUT]`
  emits a canonical database (how a golden manifest is produced).

Normalization operations (`NORM`) are individually toggleable and off by
default. Both subcommands accept:

- `--substitute-compiler V` - replace the first argument (compiler driver) with V.
- `--relativize-paths ROOT` - rebase absolute `directory`/`file`/`output` against ROOT.
- `--output-from-o` - rewrite each entry's `output` to the absolute object path
  derived from its `-o` argument resolved (lexically, no filesystem access)
  against `directory`. Last `-o` wins; no `-o` leaves `output` unchanged. This
  makes the (file, output) match key a true object identity across producers
  that encode `output` against different base directories.
- `--drop-dependency-flags` - strip the dependency-file flags from `arguments`:
  `-MD`/`-MMD`/`-MP` (no argument) and `-MF`/`-MT`/`-MQ`/`-MJ` (drop the flag
  and its following token). They control only the build's `.d` side-file, so
  they are benign for a compilation-database comparison.

`compare` also accepts a gating flag (not a normalization):

- `--intersection` - gate the exit code on the `differing` set only. Entries
  present on just one side (`only_in_a`/`only_in_b`) are reported as advisory
  extras but do not fail the gate; exit 0 iff `differing` is empty AND at least
  one TU matched. The non-vacuity clause is deliberate: a comparison that pairs
  nothing (matched == 0, e.g. `--output-from-o` omitted so the match key never
  lines up) has an empty `differing` set and would otherwise pass green having
  compared nothing; instead it fails with a diagnostic on stderr. The human
  report gains a one-line summary (matched/differing/Bear-only/CMake-only); the
  JSON report is unchanged. Default behavior (flag absent) is unchanged: any
  non-empty set fails.
