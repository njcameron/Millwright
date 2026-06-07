---
name: setup-millwright
description: Interactively configure a fresh Millwright install — gather config, guide GitHub App + Slack webhook creation, write config.yml, and verify everything with bin/doctor until green. Use when setting up Millwright on a new host.
---

Set up a fresh Millwright install end-to-end. You are the brain: you elicit values, guide
the human through the unavoidable browser steps, write `config.yml`, and loop `bin/doctor`
until everything is green. **`bin/doctor` is the source of truth** — never declare setup
done on your own judgement; declare it done when doctor exits 0.

Work from the repo root (where `config.example.yml` lives). Run all shell commands there.

## What only the human can do (browser-gated)

Three steps require a browser you may not have. Treat each as a STOP-and-hand-to-human
gate: prepare everything, tell the human exactly what to click, wait for them to paste the
result back, then verify before continuing.

1. Creating the GitHub App and downloading its private key.
2. Installing the GitHub App on the target repo(s).
3. Creating the Slack incoming webhook.

Everything else (cloning, `bundle install`, deriving IDs via `gh api`, writing config,
running doctor) you do yourself.

## Step 1 — Detect state

- Check Ruby (`ruby -v`, need 3.2+), `bundle`, and `claude` on PATH.
- Does `config.yml` already exist at the repo root?
  - **Yes** → ask the user: "verify only" (skip to Step 7) or "reconfigure" (continue).
  - **No** → continue.
- Detect whether you have a browser available. If you're a headless agent on a VPS, you
  will hand the browser steps to the human on *their* machine and wait for paste-backs.

## Step 2 — Prerequisites

- Run `bundle install` if deps aren't satisfied.
- Ensure `gh` is authenticated **with project scope**: `gh auth status`. If not, instruct
  `gh auth login` then `gh auth refresh -s project`. (Project scope is required — Projects
  v2 can't be read without it.)
- Confirm `claude` is on PATH. Warn that cron uses a minimal PATH (see README) — they may
  need an explicit `PATH=` in the crontab or an absolute `coding_agent.bin`.

## Step 3 — Project board config

- Ask for the GitHub `owner` (user or org). Detect which: `gh api users/<owner> --jq .type`.
- Help them create or identify the GitHub Project (v2) board.
- Derive `project_number` and `project_id` via `gh api graphql` (query the owner's
  `projectsV2`). Confirm with the user which board is the right one.
- Confirm the board has six status columns matching `statuses.*`. Defaults:
  `Ready`, `cc-planning`, `Planning approved`, `In progress`, `In review`, `Done`. Either
  the columns must match these names, or adjust `statuses.*` to match the columns. They
  must match **exactly** (case-insensitive) or dispatch fails at runtime — doctor's board
  check (Step 7) catches mismatches.

## Step 4 — GitHub App (manual creation — default)

Create the App by hand. It's a few clicks more than the manifest flow, but every permission
is visible on GitHub's own form and the human approves each one — nothing is hidden in an
opaque blob and there's no copy-the-code-back handshake. **Do not** generate an HTML form or
a `?manifest=` URL for this path; just walk the human through GitHub's normal UI. Guide them:

1. Open the **New GitHub App** page:
   - personal account: `https://github.com/settings/apps`
   - org: `https://github.com/organizations/<owner>/settings/apps`

   then click **New GitHub App**.
2. **Name** it (e.g. `millwright-bot`). **Homepage URL**: anything (the repo URL is fine).
3. **Webhook**: uncheck **Active** (Millwright polls; it needs no webhook).
4. **Repository permissions** — set exactly these four, leave everything else "No access":
   - Contents → **Read and write**
   - Issues → **Read and write**
   - Pull requests → **Read and write**
   - Metadata → **Read-only** (auto-selected)
5. **Where can this app be installed?** → **Only on this account**. Click **Create GitHub App**.
6. On the App's settings page, record the **App ID** shown at the top.
7. Under **Private keys**, click **Generate a private key** — it downloads a `.pem`. Have the
   human give you the file (or its contents); write it to `private-key.pem` at the repo root
   and `chmod 600` it. **Never echo the pem into the chat.**
8. Left sidebar → **Install App** → install on the target repo(s).
9. Derive the rest yourself:
   - `installation_id`: `gh api /users/<owner>/installation --jq .id` (or
     `/orgs/<owner>/installation` for an org).
   - `bot_user_id`: `gh api /users/<slug>[bot] --jq .id`, where `<slug>` is the App name
     GitHub assigned (lowercased, shown in the App's URL).
   - `factory_username`: `<slug>[bot]`.

**Fast path (App Manifest flow — opt-in):** if the human prefers fewer clicks and trusts it,
the manifest flow collapses the manual fields into one approval. Offer it only if they ask,
and explain it plainly first so it doesn't look suspicious:
- Tell them it's GitHub's official mechanism
  (https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest),
  that it requests the **same four permissions** listed above and nothing else, and that the
  `code` GitHub hands back is just part of GitHub's normal redirect — pasting it back is
  expected, not a credential leak.
- Generate a manifest with those least-privilege permissions only: `contents: write`,
  `issues: write`, `pull_requests: write`, `metadata: read`; `default_events: []`; webhook
  **off**; `public: false`. Name it (e.g. `millwright-bot`).
- Have them open the manifest create page, click **Create GitHub App**, approve the redirect,
  and paste back the `code`. Exchange it: `gh api -X POST /app-manifests/<code>/conversions`
  → the response contains `id` (the `app_id`), `pem` (the private key), and `slug`. Write the
  `pem` to `private-key.pem` (`chmod 600`), record `app_id`, then continue from step 8 above
  (install, then derive `installation_id` / `bot_user_id` / `factory_username`).

Either path lands the same values, and doctor validates the result identically.

## Step 5 — Slack webhook (optional)

- Ask whether they want Slack notifications. If yes, guide creating an **incoming webhook**
  in Slack (browser) and have them paste the URL.
- Store it as `slack_webhook` in config, or tell them to export `SLACK_WEBHOOK` (the env var
  takes precedence). Allow skipping entirely — Slack is optional.

## Step 6 — Write config.yml

- Copy `config.example.yml` to `config.yml` and fill in everything gathered: `owner`,
  `project_number`, `project_id`, `factory_username`, the `github_app.*` block, `statuses.*`,
  and optional `slack_webhook` / `routines.*`.
- Show the user a **redacted** diff/summary for confirmation (never echo the webhook URL,
  the pem, or any token).

## Step 7 — Verify (loop until green)

- Run `bin/doctor --json` and parse the results.
- For every `fail`/`warn`, explain it plainly and remediate: re-ask the relevant value, or
  re-run the relevant browser step, then **re-run doctor**. Repeat until doctor exits 0.
- This is where the GitHub App token exchange and the Slack test post are actually proven.
  After the Slack check passes, confirm with the human: "I posted a test message to your
  Slack channel — did you see it?"
- Use `bin/doctor --only <check>` to re-check a single thing after a targeted fix.

## Step 8 — Go live (cron) — gated

Only after doctor is green **and** the human explicitly confirms they want to go live:

- Detect the absolute repo path (`pwd`).
- Show the exact crontab lines with the path substituted:
  ```
  * * * * * /abs/path/to/millwright/bin/orchestrate
  0 12 * * 5 /abs/path/to/millwright/bin/weekly-digest
  0 6 * * 1 /abs/path/to/millwright/bin/security-scan
  ```
- Warn about the cron PATH caveat (suggest an explicit `PATH=` line or absolute
  `coding_agent.bin`).
- Install only after confirmation, e.g. `(crontab -l 2>/dev/null; echo "<lines>") | crontab -`,
  or print the lines for the human to paste. Never install cron silently.

## Rules

- **Never commit secrets.** `config.yml` and `private-key.pem` are gitignored — verify those
  entries exist before writing secrets. Do not `git add` them.
- **Never echo** the pem, the Slack webhook URL, or any token into the chat, logs, or Slack.
- **Confirm before installing cron** — going live dispatches real workers.
- **Hand the three browser steps to the human** — don't try to automate around them.
- **Doctor is the source of truth** — setup is done when `bin/doctor` exits 0, not before.
