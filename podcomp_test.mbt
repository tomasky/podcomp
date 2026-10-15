// Blackbox tests run against the package's public API. Use `@podcomp` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "the version is a semantic version" {
  let v = @podcomp.version
  let parts = v.split(".")
  assert_eq(parts.length(), 3)
  for part in parts {
    assert_true(part.length() > 0)
  }
}
