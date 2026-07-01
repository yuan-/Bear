# tests/tools specification

The behavioral contract for the shared test tooling. The library exposes the
compilation-database comparison and normalization logic; the binary
`cdb-compare` wraps it. It is the single comparison implementation, used by both
`tests/integration` (which re-exports `CompilationEntryMatcher`) and the
dogfooding harness (`tests/dogfooding/SPEC.md`). Agent-maintenance rules for this
crate live in `CLAUDE.md`.

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

- `invariants [NORM...] [--expected-objects N] [--tolerance PCT]
  [--min-entries N] [--format human|json] CDB`
  asserts structural invariants on one database and exits non-zero iff any
  check fails. The `NORM` flags apply before the checks (no sort), so the
  duplicate key uses normalized arguments. Checks:
  - `non-empty-arguments` (always): fails if any entry has empty `arguments`;
    offenders are those entries' `file`s.
  - `non-empty-directory` (always): fails if any entry has a blank `directory`;
    offenders are those entries' `file`s. A blank `directory` is non-replayable
    (a `cd ""` consumer lands in the wrong tree).
  - `no-true-duplicates` (always): groups entries by the full triple
    `(file, output, arguments)` post-normalization; any group of two or more
    is a true duplicate. The legitimate multi-output case (same `file`,
    different `output`/arguments) forms distinct groups and is not flagged.
  - `entry-count` (opt-in): present iff `--expected-objects` or `--min-entries`
    is given, else `"skipped"`. Passes iff every given constraint holds:
    `--expected-objects N` requires `|entries - N| <= ceil(N * PCT / 100)`
    (`--tolerance PCT`, default 0); `--min-entries M` requires `entries >= M`.
    The tool never walks the filesystem; the harness passes `N`. (Exact
    object-set membership is a deferred refinement.)
  JSON shape: `{"pass": bool, "checks": [{"name", "status":
  "pass"|"fail"|"skipped", "offenders"?, "detail"?}]}`. An offender is
  `{"file", "output"?, "count"?}` (absent fields omitted); `offenders` is
  omitted when empty and `detail` (`{"entries", "expected"?, "tolerance_pct"?,
  "min"?}`) appears only on the entry-count check.

- `sample --count K [--build-dir DIR] CDB`
  selects up to `K` entries deterministically (stable order, no RNG) and prints
  one shell-safe replay line each. With `--build-dir DIR`, entries whose
  `arguments` carry no `-I` include path under `DIR` (attached `-I<path>` or
  split `-I <path>`, matched component-wise so `/buildother` is not under
  `/build`) rank first; the rest fill up to `min(K, total)`. `--count 0` emits
  nothing; `K` larger than the database emits all. Each line is the entry's
  `directory` followed by its `arguments`, every token individually quoted with
  `shell_words::quote` and space-joined, so a jq-less consumer does
  `eval "set -- $line"; dir=$1; shift; ( cd "$dir" && "$@" ... )`. `sample`
  takes no normalization flags and never execs.
