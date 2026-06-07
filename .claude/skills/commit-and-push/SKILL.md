---
name: commit-and-push
description: Commit all staged/unstaged changes, update CHANGELOG.md with a versioned entry, and push to remote. Use instead of manual git commit/push workflow.
---

Commit changes, update the changelog, and push to remote.

## Step 1 — Understand the changes

Run these in parallel:
- `git status` to see all modified and untracked files
- `git diff` to see staged and unstaged changes
- `git diff --cached` to see already-staged changes
- `git log --oneline -5` to see recent commit message style

Review all changes and draft a concise commit message summarizing what was done and why.

## Step 2 — Determine version bump

Read `CHANGELOG.md` from the repo root to find the current version.

Decide the version bump:
- **Major** (X.0.0): breaking changes, large new capabilities, architectural rewrites
- **Minor** (x.Y.0): new features, significant enhancements, bug fixes, non-breaking changes

Default to **minor** unless the change is clearly major. If unsure, ask the user.

Increment the appropriate version component. When bumping major, reset minor to 0.

## Step 3 — Update the changelog

Add a new entry at the TOP of the changelog (below the `# Changelog` heading), using this format:

```
## vX.Y.0 — YYYY-MM-DD

- Description of the change(s) made. Be concise but specific — mention what was added/fixed/changed and why.
```

If multiple logical changes are being committed together, use multiple bullet points.

## Step 4 — Commit and push

1. Stage all relevant files INCLUDING the updated `CHANGELOG.md`
2. Create the commit. Use the format: `vX.Y.0: <short description>`
3. End the commit message body with: `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>`
4. Push to remote

## Rules

- NEVER delete or rewrite existing changelog entries — only prepend new ones
- Do not commit files that look like secrets (.env, credentials, tokens)
- If there are no changes to commit, tell the user and stop
- Use today's date (UTC) for the changelog entry
