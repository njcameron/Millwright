# Contributing to Millwright

Thanks for your interest in contributing.

## Development setup

```bash
git clone https://github.com/<your-fork>/millwright.git
cd millwright
bundle install
cp config.example.yml config.yml   # fill in real values to run end-to-end
```

Ruby 3.2+ is required (see `.ruby-version`).

## Running tests

```bash
bundle exec rake
```

Tests use minitest from the standard library — no external test framework, no
real external services. Two ground rules:

- **Never call real APIs in tests.** GitHub, Slack, and `claude` invocations
  are stubbed via dependency injection — inject items into instance variables
  or use the stub classes in `test/`. CI and contributor laptops should be
  able to run the full suite offline.
- **When fixing a bug, add a regression test** that fails on the broken code
  and passes on the fix.

## Filing issues

Open an issue describing:
- What you expected to happen.
- What actually happened (full error message + stack trace if applicable).
- Steps to reproduce, or a minimal `config.yml` snippet (with secrets
  redacted) that triggers the problem.

## Pull requests

- Branch from `main`.
- Keep PRs focused — one logical change per PR.
- Include a regression test for any bug fix.
- Update `README.md` or `docs/` if you change user-visible behaviour.
- Run `bundle exec rake` before pushing.

## Architecture

See `docs/adapters.md` for the pluggable-adapter design. New external
integrations (issue tracker, version control, update channel, coding agent)
should follow that pattern.
