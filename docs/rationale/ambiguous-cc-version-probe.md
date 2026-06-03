# Disambiguating cc/c++: a cached version probe as sole classifier

## Context

`cc` and `c++` name different toolchains per OS - GCC on most Linux,
Clang on the BSDs and macOS. Misclassifying them corrupts the database
silently, because GCC and Clang have different flag-arity tables (e.g.
Clang's `-Xclang <arg>` consumes the next argv slot and GCC's does not),
so source/output detection mis-parses. Several designs were weighed:

- **Per-OS defaults** - hard-code "cc means Clang on BSD/macOS, GCC
  elsewhere". Wrong whenever a host installs the other toolchain under
  `cc`, which is exactly the case users hit.
- **Regex with a probe fallback (probe-then-regex)** - the original
  implementation. On probe failure it fell back to the recognition regex,
  which defaulted `cc` to GCC.
- **Per-invocation probe** (PR #695) - run `--version` on every
  invocation.
- **Cached version probe as the sole classifier** - run the executable
  once with `--version`, cache the result per canonical path, and do not
  fall back to the regex for ambiguous names.

## Decision

Use the cached version probe as the sole classifier for ambiguous names.
The recognition regex deliberately does not list `cc`/`c++`, so when the
probe declines (timeout, unrecognizable output, failed spawn, non-zero
exit) recognition returns `NotRecognized` rather than guessing.

## Consequences

- The failure mode is **loud, not wrong**: a missing entry is visible and
  debuggable; a mis-classified entry corrupts the database silently. The
  probe-then-regex fallback re-introduced the very bug on the platforms
  the probe was meant to fix, which is why there is no regex fallback for
  ambiguous names. `gcc.yaml` carries a comment recording why `cc`/`c++`
  are absent from its recognize list.
- The user override is per-path and explicit: declaring a path under
  `compilers:` takes priority over the probe and is the only way to
  recover recognition for a quirky `cc` whose `--version` output the
  probe cannot read. There is no process-wide off switch, by request.
- Caching per canonical path keeps the cost at one or two `fork+exec`
  pairs per clean build rather than per invocation - the reason the
  per-invocation probe (PR #695) was not taken.
- The ambiguous-names list is intentionally minimal (`cc`, `c++`).
  Cross-prefixed variants like `aarch64-linux-gnu-cc` are left to the
  regex because cross-toolchains are overwhelmingly GCC; the list can
  grow if a real BSD cross-toolchain case appears.

## References

- Requirement: `recognition-ambiguous-name-probe`
- PR #695 - the per-invocation probe variant, not taken
