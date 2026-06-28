// SPDX-License-Identifier: GPL-3.0-or-later

//! Deterministic selection of replayable compilation-database entries.
//!
//! Stage 4 replay needs to pick up to `K` entries and emit a shell-safe record
//! a jq-less POSIX `sh` loop can `eval set --` and exec. Selection is
//! deterministic (no RNG): the same database always yields the same sample, in a
//! stable order, so a replay step is reproducible.

use std::path::Path;

use crate::cdb::{CompilationDatabase, Entry};

/// Select up to `count` entries for replay, in a deterministic stable order.
///
/// With `build_dir`, entries are partitioned into "clean" ones (no `-I` include
/// path under `build_dir`, since a build-dir include may reference a generated
/// header that makes replay less reliable) and the rest; each group keeps its
/// original database order, clean entries come first, and the first
/// `min(count, total)` are taken. Without `build_dir`, the first
/// `min(count, total)` entries are taken in original order.
pub fn select<'a>(
    database: &'a CompilationDatabase,
    count: usize,
    build_dir: Option<&Path>,
) -> Vec<&'a Entry> {
    let ordered: Vec<&Entry> = match build_dir {
        None => database.entries.iter().collect(),
        Some(dir) => {
            let (clean, rest): (Vec<&Entry>, Vec<&Entry>) =
                database.entries.iter().partition(|entry| !has_include_under(&entry.arguments, dir));
            clean.into_iter().chain(rest).collect()
        }
    };
    ordered.into_iter().take(count).collect()
}

/// Render one selected entry as a single shell-safe line: the entry's
/// `directory` followed by each argument token, every token individually quoted
/// with `shell_words::quote` and space-joined. A consumer recovers the exact
/// argv with `eval "set -- $line"`.
pub fn to_line(entry: &Entry) -> String {
    let mut tokens: Vec<&str> = Vec::with_capacity(entry.arguments.len() + 1);
    tokens.push(entry.directory.as_str());
    tokens.extend(entry.arguments.iter().map(String::as_str));
    shell_words::join(tokens)
}

/// Whether any `-I` include path in `arguments` points under `dir`. Recognizes
/// both the attached `-I<path>` form and the separate `-I <path>` form.
fn has_include_under(arguments: &[String], dir: &Path) -> bool {
    let mut iter = arguments.iter();
    while let Some(arg) = iter.next() {
        let include = if arg == "-I" {
            iter.next().map(String::as_str)
        } else {
            arg.strip_prefix("-I").filter(|rest| !rest.is_empty())
        };
        if let Some(path) = include
            && is_under(Path::new(path), dir)
        {
            return true;
        }
    }
    false
}

/// Whether `path` equals `dir` or is a descendant. Component-wise `starts_with`
/// (std `Path`) so `/buildother` does not count as under `/build`.
fn is_under(path: &Path, dir: &Path) -> bool {
    path.starts_with(dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// An entry with the given directory and arguments. `file`/`output` are not
    /// exercised by selection, so they carry placeholder values.
    fn entry(directory: &str, arguments: &[&str]) -> Entry {
        Entry {
            directory: directory.to_string(),
            file: "/src/a.c".to_string(),
            arguments: arguments.iter().map(|s| s.to_string()).collect(),
            output: None,
        }
    }

    fn database(entries: Vec<Entry>) -> CompilationDatabase {
        CompilationDatabase { entries }
    }

    #[test]
    fn line_round_trips_tricky_tokens_through_shell_words() {
        // An argument with a space and one with a quote must come back intact when
        // a consumer parses the emitted line, which is what `eval set --` relies on.
        let sut = entry("/build dir", &["cc", "-DMSG=a b", "-DQ=\"x\"", "-c", "/src/a.c"]);

        let line = to_line(&sut);
        let parsed = shell_words::split(&line).unwrap();

        let mut expected = vec![sut.directory.clone()];
        expected.extend(sut.arguments.clone());
        assert_eq!(parsed, expected);
    }

    #[test]
    fn count_larger_than_database_returns_all() {
        let db = database(vec![entry("/b", &["cc"]), entry("/b", &["cc"])]);

        let sut = select(&db, 10, None);

        assert_eq!(sut.len(), 2);
    }

    #[test]
    fn count_zero_returns_nothing() {
        let db = database(vec![entry("/b", &["cc"]), entry("/b", &["cc"])]);

        let sut = select(&db, 0, None);

        assert!(sut.is_empty());
    }

    #[test]
    fn build_dir_ranks_build_includes_after_clean_entries() {
        // A clean entry (only /src and system includes) must rank before entries
        // carrying a build-dir include in either the attached or the split form.
        let clean = entry("/b", &["cc", "-I/src/include", "-I", "/usr/include", "-c", "/src/a.c"]);
        let attached = entry("/b", &["cc", "-I/build/x", "-c", "/src/b.c"]);
        let split = entry("/b", &["cc", "-I", "/build/x", "-c", "/src/c.c"]);
        let db = database(vec![attached.clone(), clean.clone(), split.clone()]);

        let sut = select(&db, 3, Some(&PathBuf::from("/build")));

        // Clean entry first; the two build-dir entries keep their original order.
        assert_eq!(sut[0].file, clean.file);
        assert_eq!(sut[0].arguments, clean.arguments);
        assert_eq!(sut[1].arguments, attached.arguments);
        assert_eq!(sut[2].arguments, split.arguments);
    }

    #[test]
    fn build_dir_does_not_match_sibling_prefix() {
        // `/buildother` must not count as an include under `/build`.
        let sut = entry("/b", &["cc", "-I/buildother/x", "-c", "/src/a.c"]);

        assert!(!has_include_under(&sut.arguments, Path::new("/build")));
    }

    #[test]
    fn build_dir_fills_with_unclean_entries_to_reach_count() {
        // Fewer clean entries than K: build-dir entries still appear so the sample
        // reaches min(K, total).
        let clean = entry("/b", &["cc", "-I/src", "-c", "/src/a.c"]);
        let dirty1 = entry("/b", &["cc", "-I/build/g", "-c", "/src/b.c"]);
        let dirty2 = entry("/b", &["cc", "-I/build/h", "-c", "/src/c.c"]);
        let db = database(vec![dirty1, clean, dirty2]);

        let sut = select(&db, 3, Some(&PathBuf::from("/build")));

        assert_eq!(sut.len(), 3);
    }

    #[test]
    fn selection_is_deterministic_across_runs() {
        let db = database(vec![
            entry("/b", &["cc", "-I/build/x", "-c", "/src/a.c"]),
            entry("/b", &["cc", "-I/src", "-c", "/src/b.c"]),
            entry("/b", &["cc", "-c", "/src/c.c"]),
        ]);
        let build_dir = PathBuf::from("/build");

        let first: Vec<String> = select(&db, 2, Some(&build_dir)).iter().map(|e| to_line(e)).collect();
        let second: Vec<String> = select(&db, 2, Some(&build_dir)).iter().map(|e| to_line(e)).collect();

        assert_eq!(first, second);
    }
}
