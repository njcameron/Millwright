# Millwright Project Rules

## Safety Rules

- **NEVER delete GitHub repositories.** Do not run `gh repo delete` or any equivalent command under any circumstances.

## Testing

- Run tests with `bundle exec rake`
- Tests use minitest (stdlib) — no external test framework
- Tests live in `test/` with `_test.rb` suffix
- Stub GitHub API calls via dependency injection (inject items into instance variables or use stub classes), never call real APIs in tests
- When fixing bugs, add a regression test
