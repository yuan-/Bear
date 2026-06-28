# Bear dogfooding harness (Stages 2-3)

A non-automated, release-time harness that runs Bear's *installed release*
binaries against a real project at a pinned revision inside a throwaway
container, then validates the captured `compile_commands.json`. It proves the
end-to-end interception loop and catches behavioral regressions and correctness
divergences in Bear's output on a real build.

Each target picks a validation mode with a `VALIDATION` selector in its
`config.env`:

- **golden** (zlib, Stage 2): gate the capture against a committed golden CDB -
  a change-detector, reblessed deliberately when behavior changes intentionally.
- **oracle** (curl, Stage 3): gate the capture against the database CMake itself
  emits (`CMAKE_EXPORT_COMPILE_COMMANDS=ON`), on the intersection of translation
  units. The oracle is self-renewing: when curl updates, CMake produces a fresh
  reference, so there is no hand-maintained baseline.

This is the host-orchestrated Podman model (feasibility.md Option C): the
orchestrator is POSIX `sh` on the host, each target runs in a per-project
throwaway container, and nothing touches the repo working tree or the
devcontainer image. The only Rust dependency is the Stage 1 `cdb-compare`
binary, built on the host: it does the entire comparison for both modes
(matching, normalization, and the gate), so the harness needs no jq.

The harness contracts are written up in `SPEC.md` (the `dogfood-*` Stage 2 and
Stage 3 specs). They live here, not under `docs/requirements/`, because they
govern the test harness, not Bear itself.

## Prerequisites

- Rootless Podman (developed against podman 5.8.3). The build container runs
  with `--systemd=always` so Bear's cgroup-based process-tree teardown works;
  this mirrors the devcontainer and needs the host's delegated cgroup
  controllers (`/etc/systemd/system/user@.service.d/delegate.conf` with
  `Delegate=cpu cpuset io memory pids`).
- The host `cdb-compare` binary at `target/release/cdb-compare`. Build it with:

  ```sh
  cargo build --release -p bear-test-tools --bin cdb-compare
  ```

  If the host has no C toolchain (cdb-compare's dependencies need a `cc` to
  link their build scripts), build it once in a container and copy it out:

  ```sh
  podman build --build-arg \
    BASE_IMAGE=registry.fedoraproject.org/fedora@sha256:3baf5f0dededfd939eb8f0b271ff8ad17bdb381cdd5768bd7d6f45bba795aa62 \
    -f tests/dogfooding/base/Containerfile -t bear-dogfood-base:tmp .
  cid="$(podman create bear-dogfood-base:tmp)"
  mkdir -p target/release
  podman cp "$cid:/opt/bear/bin/cdb-compare" target/release/cdb-compare
  podman rm "$cid"
  ```

  The base image already builds `cdb-compare`, so this reuses that build.
- Enough free disk on the podman graphroot (zlib needs ~2 GiB, curl ~4 GiB for
  the base + target images plus the CMake build tree). The harness preflight
  checks this against the per-target `MIN_FREE_KIB`.

## How to run

From the repo root:

```sh
# Gate the fresh capture against the committed golden (default target zlib).
tests/dogfooding/run.sh

# Run the curl oracle target (compares against CMake's own database).
tests/dogfooding/run.sh --label rc1 curl

# Name the run (results land under results/zlib/rc1/).
tests/dogfooding/run.sh --label rc1

# Keep the throwaway container for inspection.
tests/dogfooding/run.sh --keep
```

The first invocation builds two cached images (`bear-dogfood-base:<sha>` and
`bear-dogfood-<target>:<sha>`, tagged by the Bear commit under test); subsequent
runs reuse them. The base build compiles Bear from `git archive HEAD`, so it
takes a few minutes the first time. The curl build itself takes a few minutes.

## Outcomes and exit codes

The harness prints one final `OUTCOME:` line and exits with:

| Outcome      | Exit | Meaning |
|--------------|------|---------|
| PASS         | 0    | golden: fresh capture matches the golden. oracle: matched TUs equivalent to the CMake oracle. No regression. |
| FAIL         | 1    | golden: golden mismatch (review the diff, then fix Bear or rebless). oracle: matched TUs diverge from CMake's database (inspect the `matched but differing` section of `oracle-report.txt`). A real behavioral change in Bear's output. |
| INCONCLUSIVE | 2    | The target build failed for its own reasons (source fetch, sha, network, configure/make, OOM). Not a Bear regression. The build log is saved. |
| ERROR        | 3    | Harness or Bear-infra failure: podman missing, disk/digest preflight, base image build, empty capture (libexec/INTERCEPT_LIBDIR mismatch), an oracle that matched 0 TUs (nothing compared), or missing host `cdb-compare`. |

Run artifacts land under `results/<target>/<label>/` (git-ignored). Goldens
live under `goldens/<target>/` and are tracked.

## Reblessing the golden (dogfood-golden-rebless)

The golden is a frozen, full normalized CDB - a change-detector, not a proof of
correctness. When a behavior change is intentional (Bear deliberately changed
the flags it records, or the pinned zlib/base moved), regenerate it
deliberately:

```sh
tests/dogfooding/run.sh --rebless zlib
```

This runs the full pipeline (preflight, base + target build, smoke,
real build) and then, instead of gating, writes
`cdb-compare normalize --sort <fresh>` to
`goldens/zlib/compile_commands.json` and reports "reblessed" (exit 0). The new
golden is left in the working tree for you to:

1. Inspect the diff (`git diff tests/dogfooding/goldens/zlib/`) and confirm the
   change is the one you intended.
2. Commit it with a message explaining *why* the recorded behavior changed.

Reblessing is never automatic: a normal `run.sh` only ever reads the golden and
fails on mismatch, so an unintended change cannot silently overwrite it.

## The curl oracle target (dogfood-oracle-cmake)

curl is CMake-native, so CMake itself can emit the reference compile database.
The harness configures curl out-of-tree (source `/src`, build `/build`) with
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` and all optional dependencies turned off,
then wraps only the *build* with Bear (the configure step is not a compile).
This captures both databases from one run:

- `/out/compile_commands.json` - Bear's capture of the real make-time compiles.
- `/out/oracle.json` - CMake's own database (the independent oracle).

### Extras vs the gate

The comparison is scoped to the *intersection* of translation units, matched by
source file plus the object it produces. The two databases legitimately differ
in coverage, so the result splits in two:

- **Extras** (`only_in_a` Bear-only, `only_in_b` CMake-only): TUs present in
  only one database. CMake lists every configured TU (including ones a given
  build target does not actually compile), while Bear records what the build
  really ran. Extras are *logged for review, never a failure*. On the pinned
  build there are 0 Bear-only and ~156 CMake-only extras.
- **The gate** (`differing`): TUs matched on both sides whose flags differ after
  normalization. The gate passes iff this set is empty.

The comparison is one `cdb-compare` invocation (no jq, no allow-list file):

```sh
cdb-compare compare --intersection --substitute-compiler cc \
    --output-from-o --drop-dependency-flags  <bear.json> <cmake.json>
```

- `--output-from-o` matches TUs by source file plus absolute object path
  (`directory` + the `-o` argument), so the two producers' differently encoded
  `output` fields align and a source compiled into several targets stays
  distinct.
- `--drop-dependency-flags` removes the `-M*` dependency-file group (`-MD`,
  `-MMD`, `-MP`, and the arg-consuming `-MF`/`-MT`/`-MQ`/`-MJ`). On curl this is
  the entire matched-but-differing set: the real compile carries them, CMake's
  configure-time export omits them, and they touch only the `.d` side-file,
  never the object. This is a tested operation of the comparator, not a shell
  heuristic.
- `--intersection` makes the exit code gate on `differing` only; extras are
  advisory. The harness additionally fails the run if 0 TUs matched (a vacuous
  comparison that validated nothing).

The comparator's report (extras lists plus a `summary:` line) is written to
`results/curl/<label>/oracle-report.txt`, with a machine-readable
`oracle-compare.json` alongside. When the gate fails, inspect the
`matched but differing` section. If a future oracle target shows a *different*
benign argument difference, extend `cdb-compare` (a tested normalization rule),
not a shell allow-list - the comparison stays in one place.

## What the harness does NOT do

- It does not modify the repo working tree, the devcontainer image, or any
  cargo cache. Sources and toolchain live only in the throwaway container.
- It does not leave its per-run container behind (unless `--keep`). It does
  leave the two cached images so reruns are fast; remove them with
  `podman rmi bear-dogfood-<target>:<sha> bear-dogfood-base:<sha>` when done.
