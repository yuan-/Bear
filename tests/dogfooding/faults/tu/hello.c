/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A trivial, self-contained translation unit used by the dogfooding
 * self-test (selftest.sh). The bad-directory fault fixture records a
 * compile of this file but with a wrong `directory`, so replaying the
 * recorded command fails - demonstrating that the replay check catches a
 * corrupted `directory` field. */
int dogfood_selftest_hello(void) { return 0; }
