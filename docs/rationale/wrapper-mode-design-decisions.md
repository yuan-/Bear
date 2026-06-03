# Wrapper mode: hard links, deterministic directory, resolve-at-startup

## Context

Wrapper mode intercepts compilers by placing wrapper executables ahead
of the real ones on PATH. Three implementation choices shaped how that
works and each has a non-obvious reason.

## Decision

- Wrappers are **hard links** to `bear-wrapper`, not symlinks.
- The wrapper directory is a **deterministic** `.bear/` in the current
  working directory, not a random temp dir.
- Bare compiler names are **resolved to absolute paths once at startup**,
  not on every wrapper invocation.

## Consequences

- **Hard links, not symlinks.** Tools like ccache detect symlinks to
  themselves and skip them, but do not detect hard links. The hard link
  ensures ccache does not skip Bear's wrapper entirely. The cost is the
  ccache recursion problem handled separately in
  `interception-wrapper-recursion`.
- **Deterministic directory.** Paths recorded during `./configure` stay
  valid during `make`, provided both run under the same Bear invocation.
  Issue #654 showed that temp directories break such multi-step builds.
- **Resolve at startup.** Avoids repeated PATH lookups and keeps the
  wrapper configuration self-contained. The trade-off is that a PATH
  change mid-build is not picked up; the wrapper keeps using the path
  resolved at startup.

## References

- Requirement: `interception-wrapper-mechanism`
- Related requirement: `interception-wrapper-recursion`
- Issue #654 - temp directories break multi-step builds
