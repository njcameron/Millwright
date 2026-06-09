# Changelog

## v0.2.0 — 2026-06-09

- Surface operational errors (missing repo checkout, failed `gh` API calls) to Slack via a new throttled `Context#error` path, so failures are visible instead of only logged. Throttling reuses the existing `Cooldown` so a recurring error notifies at most once per backoff window.
- Fix silently-swallowed `gh` comment failures: `post_pr_comment`/`post_review_reply` now capture stderr and raise on non-zero exit (previously `capture2` dropped stderr and ignored exit status, so a 403 looked like success and leaked to the log).

## v0.1.0 — 2026-06-07

- Initial commit.
