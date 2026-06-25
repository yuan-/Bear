// SPDX-License-Identifier: GPL-3.0-or-later

//! Partial matching of a single compilation database entry.
//!
//! [`CompilationEntryMatcher`] checks that an entry (a `serde_json::Value`)
//! satisfies a caller-specified subset of fields. It is the entry-level
//! predicate the integration suite uses to assert a database contains a given
//! compilation; it accepts both the `arguments` array and the `command` string
//! encodings, and canonicalizes `directory` paths so symlinked temp roots
//! (e.g. macOS `/var` -> `/private/var`) still compare equal.

use std::path::PathBuf;

use serde_json::Value;

/// A builder-style predicate over a compilation database entry. Only the fields
/// that are set are checked; unset fields match anything.
#[derive(Debug, Default)]
pub struct CompilationEntryMatcher {
    pub file: Option<String>,
    pub directory: Option<String>,
    pub arguments: Option<Vec<String>>,
    pub output: Option<String>,
}

impl CompilationEntryMatcher {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn file<S: Into<String>>(mut self, file: S) -> Self {
        self.file = Some(file.into());
        self
    }

    pub fn directory<S: Into<String>>(mut self, directory: S) -> Self {
        self.directory = Some(directory.into());
        self
    }

    pub fn arguments(mut self, arguments: Vec<String>) -> Self {
        self.arguments = Some(arguments);
        self
    }

    pub fn output<S: Into<String>>(mut self, output: S) -> Self {
        self.output = Some(output.into());
        self
    }

    /// Return whether `entry` satisfies every field set on this matcher.
    pub fn matches(&self, entry: &Value) -> bool {
        if let Some(ref expected_file) = self.file {
            match entry.get("file").and_then(|v| v.as_str()) {
                Some(actual_file) if actual_file == expected_file => {}
                _ => return false,
            }
        }

        if let Some(ref expected_dir) = self.directory {
            match entry.get("directory").and_then(|v| v.as_str()) {
                Some(actual_dir) => {
                    // Canonicalize both paths so symlinked roots compare equal.
                    let expected_canonical =
                        std::fs::canonicalize(expected_dir).unwrap_or_else(|_| PathBuf::from(expected_dir));
                    let actual_canonical =
                        std::fs::canonicalize(actual_dir).unwrap_or_else(|_| PathBuf::from(actual_dir));
                    if expected_canonical != actual_canonical {
                        return false;
                    }
                }
                None => return false,
            }
        }

        if let Some(ref expected_args) = self.arguments {
            // Accept both the 'arguments' array and the 'command' string forms.
            let actual_args = if let Some(args_array) = entry.get("arguments").and_then(|v| v.as_array()) {
                args_array.iter().filter_map(|v| v.as_str()).map(|s| s.to_string()).collect::<Vec<_>>()
            } else if let Some(command_str) = entry.get("command").and_then(|v| v.as_str()) {
                shell_words::split(command_str).unwrap_or_default()
            } else {
                return false;
            };
            if &actual_args != expected_args {
                return false;
            }
        }

        if let Some(ref expected_output) = self.output {
            match entry.get("output").and_then(|v| v.as_str()) {
                Some(actual_output) if actual_output == expected_output => {}
                _ => return false,
            }
        }

        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entry() -> Value {
        json!({
            "file": "/path/to/test.c",
            "directory": "/path/to",
            "arguments": ["gcc", "-c", "test.c"],
            "output": "test.o"
        })
    }

    #[test]
    fn matches_when_all_set_fields_agree() {
        let sut = CompilationEntryMatcher::new()
            .file("/path/to/test.c")
            .arguments(vec!["gcc".to_string(), "-c".to_string(), "test.c".to_string()])
            .output("test.o");

        assert!(sut.matches(&entry()));
    }

    #[test]
    fn empty_matcher_matches_anything() {
        let sut = CompilationEntryMatcher::new();

        assert!(sut.matches(&entry()));
    }

    #[test]
    fn rejects_on_disagreeing_file() {
        let sut = CompilationEntryMatcher::new().file("/path/to/other.c");

        assert!(!sut.matches(&entry()));
    }

    #[test]
    fn matches_command_string_form() {
        let value = json!({
            "file": "test.c",
            "command": "gcc -c test.c"
        });

        let sut = CompilationEntryMatcher::new().arguments(vec![
            "gcc".to_string(),
            "-c".to_string(),
            "test.c".to_string(),
        ]);

        assert!(sut.matches(&value));
    }
}
