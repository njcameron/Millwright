# Millwright

Millwright is an async agent orchestrator that works in the background, using the tools you already have, on infrastructure that you own.

A cron-driven orchestrator that works off a project board (e.g. a GitHub Project board), dispatching [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to implement issues autonomously, create PRs, and respond to comments.

## Contents

- [Principles](#principles)
- [How it works](#how-it-works)
- [PR comment watching](#pr-comment-watching)
- [CI failure auto-fix](#ci-failure-auto-fix)
- [Bot identity](#bot-identity)
- [Planning flow](#planning-flow)
- [File attachments](#file-attachments)
- [Dispatch safety](#dispatch-safety)
- [Routines](#routines)
  - [Weekly product digest](#weekly-product-digest)
  - [Weekly security scan](#weekly-security-scan)
  - [Runtime watchdog ("doctor")](#runtime-watchdog-doctor)
- [Multi-repo support](#multi-repo-support)
- [Project board statuses](#project-board-statuses)
- [Slack notifications](#slack-notifications)
- [Setup](#setup)
- [Configuration reference](#configuration-reference)
- [Pluggable adapters](#pluggable-adapters)
- [Tests](#tests)
- [File structure](#file-structure)
- [Logs](#logs)
- [Professional support](#professional-support)
- [License](#license)

## Principles

1. **Works independently of individual developers.** Millwright is a shared resource for your team or organisation that works autonomously to deliver completed work across multiple projects. Anybody can create a ticket for it to pick up; it delivers the completed work, which any team member can then review and merge.

2. **Uses the tools you already use.** It runs off your existing issue tracker and uses your existing version control and notification channels. It defaults to GitHub, Slack, but is fully extensible to other channels and tools.

3. **Runs on infrastructure you own.** Millwright is intended to run on a VPS: private cloud, public cloud, or a provider like Hetzner — so the work happens on hardware you control.

<img height="450" alt="Millwright principles" src="/docs/Engagement Matrix.png" />

## How it works

1. **Cron** runs `bin/orchestrate` every minute.
2. The **orchestrator** queries the project board (e.g. a GitHub Project board) for issues with status `Ready` or `Planning approved`.
3. It checks two limits before dispatching:
   - **Worker cap**: no more than `max_workers` concurrent Claude processes (tracked via the `In progress` + `cc-planning` statuses).
   - **Review queue cap**: no new issues if `max_in_review` or more PRs are waiting for review.
4. For each available slot, it:
   - Moves the issue to `In progress` status.
   - Resolves which repo the issue belongs to (automatic via GitHub's built-in repository field).
   - Spawns `claude -p` as a detached process with a self-contained prompt.
5. **Claude handles everything from there**: reading the issue, creating a git worktree off `main`, implementing the changes, creating a PR, and cleaning up.
6. After dispatching, the orchestrator checks all `In review` PRs for unaddressed comments and CI failures (these always run, even when the review queue is full).

## PR comment watching

After dispatching new issues, the orchestrator checks all PRs with status `In review` for unaddressed comments. A comment is "unaddressed" if:

- It's not from the bot.
- The bot hasn't replied to it yet.

When unaddressed comments are found, the orchestrator spawns Claude to address them. Each comment author is tagged as **HUMAN** or **BOT** (detected by username patterns like `chatgpt`, `codex`, `claude`, `copilot`, `dependabot`, `bot`).

- **Human comments**: Claude implements the requested change and replies with what it did.
- **Bot comments**: Claude critically assesses whether the suggestion is valid. If it agrees, it implements and replies. If it disagrees, it replies explaining why — no blind obedience to other bots.

Claude replies to each comment it addresses. The reply is the "done" marker — GitHub is the source of truth, no local state needed.

## CI failure auto-fix

After checking PR comments, the orchestrator checks all `In review` PRs for CI failures. For each PR:

1. Fetches the latest GitHub Actions run on the PR branch via `gh run list`.
2. If the run's conclusion is `"failure"`, fetches the failed logs via `gh run view --log-failed`.
3. Truncates logs to the last 20,000 characters (failure output is at the end).
4. Spawns Claude with the logs and instructions to fix the issue, run tests locally, and push.

**Retry limits**: Each PR gets at most `max_ci_fixes` (default: 2) auto-fix attempts, tracked via state files (`state/ci_fix_count_<pr_number>`). After exhausting retries, the orchestrator sends a Slack notification asking for human attention and stops retrying. The count is reset when CI passes.

**Dispatch locks**: `ci-<pr_number>` locks (same 2-hour TTL as other locks) prevent duplicate dispatches while Claude is working on a fix.

## Bot identity

Spawned Claude processes authenticate with a GitHub App installation token, so that comments, commits, and PRs are clearly attributed to the bot rather than the repo owner. Set the bot username in `config.yml` as `factory_username` (e.g. `millwright-bot[bot]`).

The orchestrator itself uses the personal `gh` auth for project board access (GitHub Apps can't access Projects v2). Only the spawned Claude processes get the bot token.

Token generation uses `lib/github_app_token.rb` — creates a JWT from the app's private key and exchanges it for a short-lived installation token via the GitHub API.

## Planning flow

Some issues need a plan before implementation. If the issue description says something like "plan this first", Claude will:

1. Write a detailed implementation plan as a comment on the issue.
2. Add a "needs review" label.
3. Stop — no implementation yet.

The human reviews the plan on GitHub and, if happy, moves the issue to `Planning approved` on the project board. The orchestrator picks it up on the next run and dispatches Claude again, this time with instructions to implement according to the approved plan.

1. `Ready` → `In progress`: the orchestrator picks up the issue.
2. Claude checks whether planning is needed:
   - **Planning needed** → `cc-planning`: Claude writes a plan, adds a "needs review" label, and stops. A human reviews the plan and, if happy, moves the issue to `Planning approved` → `In progress`, where Claude implements according to the plan → `In review` → `Done`.
   - **No planning needed**: Claude implements directly → `In review` → `Done`.

## File attachments

Issues can include attached files (e.g. markdown specs, design docs) by dragging them into the issue body on GitHub. The orchestrator detects `user-attachments/files/` URLs, downloads them with the personal token (GitHub App tokens can't access these), and inlines the content directly into the prompt Claude receives.

## Dispatch safety

The orchestrator uses multiple layers to prevent duplicate dispatches:

1. **WIP replies** — before dispatching a PR review, the orchestrator posts a "Working on this" reply from the bot. Subsequent runs see the reply and skip the comment.
2. **File-based locks** — a lock file in `state/` prevents re-dispatch for 2 hours. Locks are cleared when the orchestrator detects a status transition.
3. **Repo-aware status updates** — `set_status` disambiguates by repo, preventing cross-repo collisions when multiple repos share issue numbers.

## Routines

Beyond the main orchestrator loop, Millwright ships standalone scheduled scripts under `lib/routines/`. Each can be run manually or scheduled via cron (see Setup below).

### Weekly product digest

A script (`lib/routines/weekly_digest.rb`) generates a weekly product update from merged PRs in a configured repository:

1. Fetches all PRs merged in the last 7 days from `routines.weekly_digest.repo`.
2. For each PR, finds the linked issue (by branch name convention) and reads the original brief and plan comments.
3. Feeds everything to Claude, which writes a polished, product-focused summary suitable for LinkedIn or customer emails.
4. Posts the digest to Slack and saves it to `logs/weekly/YYYY-MM-DD.md`.

Run manually: `bundle exec ruby lib/routines/weekly_digest.rb`.

### Weekly security scan

A second routine (`lib/routines/security_scan.rb`) scans one or more configured repositories for high-confidence security issues that existing SAST and dependency-audit tools wouldn't catch (IDOR, broken access control, business-logic flaws, etc.) and posts a report to Slack. Configure target repos under `routines.security_scan.repos` in `config.yml`.

### Runtime watchdog ("doctor")

A health-check routine (`lib/routines/watchdog.rb`, run via `bin/watch`) runs **every minute from its own cron entry, independent of the orchestrator** — so it can also catch the orchestrator itself being down. It works in two stages:

1. **Deterministic scan** of logs, process liveness, dispatch locks, and board state for: stalled/hung workers (a 0-byte worker log whose process is dead or has produced nothing for too long), the orchestrator not ticking, new `ERROR`/stack-trace lines, stale dispatch locks, cards wedged in "In progress" with no live worker, and handlers that detect actionable work every tick but never spawn a worker (detection-without-dispatch — e.g. a lock that outlived its worker).
2. **Escalation** — when something is flagged it posts to Slack (🩺) and, single-flighted and rate-limited, spawns one Claude worker to investigate. By default the worker performs **safe auto-remediation** (reversible actions only — clearing a confirmed-stale lock, killing a dead/hung worker so it respawns, nudging a wedged card) and **diagnoses-and-proposes** for anything touching code or config. Set `routines.watchdog.auto_remediate: false` to make it diagnose-only. Thresholds and attempt limits are configured under `routines.watchdog` in `config.yml`.

This is distinct from `bin/doctor` (`lib/setup/doctor.rb`), which is a one-shot **setup-time** preflight, not a runtime monitor.

## Multi-repo support

A single GitHub Project can manage issues across multiple repositories. The orchestrator determines which repo an issue belongs to from GitHub's built-in repository field on each project item — no manual tagging required.

Clone target repos wherever you like; point `routines.security_scan.repos[*].dir` at their absolute paths in `config.yml`.

## Project board statuses

| Status | Meaning |
|--------|---------|
| Ready | Available for the orchestrator to pick up |
| In progress | Claude is actively working (implementing or addressing PR comments) |
| cc-planning | Claude is writing a plan that needs human review |
| Planning approved | Human has reviewed the plan, ready for implementation |
| In review | PR created, waiting for human review |
| Done | Complete |

Status names are configurable under `statuses:` in `config.yml` — they must match your project board exactly (case-sensitive).

## Slack notifications

Key events are posted to Slack via an incoming webhook:

| Event | Emoji | When |
|-------|-------|------|
| Issue picked up | 🚀 | Orchestrator dispatches a new issue |
| Plan ready for review | 📋 | Claude finishes writing a plan |
| PR ready for review | 🔀 | Claude creates a PR |
| Comments found | 💬 | Orchestrator finds unaddressed PR comments |
| Plan feedback found | 💬 | Orchestrator finds unaddressed comments on a plan in cc-planning, revising it |
| Comments addressed | ✅ | Claude finishes responding to PR comments |
| Worker failed | 🔴 | A spawned Claude process errors out |
| No available slots | ⏸️ | All worker slots are occupied |
| CI fix dispatched | 🔴 | CI failed on a PR, dispatching Claude to fix it |
| CI fix gave up | ⚠️ | CI still failing after max auto-fix attempts |
| Doctor detected / gave up / recovered | 🩺 | Runtime watchdog flags, exhausts fixes for, or clears a problem |
| Weekly digest | 📰 | Weekly product update generated and posted |
| Review queue full | 📥 | Too many PRs waiting for review, pausing new issues |

The orchestrator sends notifications directly for events it controls. Spawned Claude processes send notifications via `curl` for events they control (plan ready, PR created, comments addressed).

## Setup

### Two ways to set up

- **Guided (recommended)** — run the `setup-millwright` skill in Claude Code. It asks you everything, walks you through creating the GitHub App (by hand on GitHub's own form, so you see and approve each permission — with the [App Manifest flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest) available as an opt-in fast path) and the Slack webhook, writes `config.yml`, and verifies the whole thing with `bin/doctor` until it's green.
- **Hands-off on a fresh VPS** — paste the [agent pullout](#agent-pullout-fresh-vps) below into a full-permission Claude Code session on the box. It bootstraps the environment and then runs the same skill.

Both paths converge on the same skill, and the skill converges on `bin/doctor` — so there's one verification path however you start. You can also follow the [manual setup](#manual-setup) steps yourself.

### Prerequisites

- A **host to run on** — Millwright is intended to run on a VPS. A small instance is plenty: roughly 4 GB RAM, 2 vCPU, and 80 GB disk. Since Millwright holds GitHub App credentials and runs agents unattended, harden the box before going live — a non-root user, SSH key-only auth, a firewall, and automatic security updates at minimum. See [VPS hardening and best practices](https://docs.anyone.io/relay/vps-hardening-and-best-practices) for a solid baseline.
- Ruby 3.2+ (see `.ruby-version`).
- `gh` CLI authenticated with `project` scope:
  ```bash
  gh auth refresh -s project
  ```
- The `claude` CLI installed and on the `PATH` that cron sees. Cron runs with a minimal environment, so if your login shell's `PATH` isn't picked up, set `PATH=` explicitly in the crontab or point `coding_agent.bin` at an absolute path. Spawned workers run unattended, so Millwright launches them with permissions bypassed (`--permission-mode bypassPermissions`, equivalent to `--dangerously-skip-permissions`) — they never block on interactive prompts. This is recommended for this use case and is the default; it's safe here because the host is a dedicated VPS you own.
- A **GitHub App** installed on the repos you want Millwright to manage. Required permissions: `contents` (read/write), `issues` (read/write), `pull requests` (read/write), `metadata` (read). See [Creating a GitHub App](https://docs.github.com/en/apps/creating-github-apps).
- A **project board** (e.g. a GitHub Project v2 board) with the status column names listed above.
- A **Slack incoming webhook** for notifications.

### Quick verify: `bin/doctor`

`bin/doctor` is a read-only preflight that tells you whether an install is actually wired up correctly — before anything dispatches. It checks Ruby + bundler, the `claude` CLI, `gh` auth and `project` scope, `config.yml` (presence, valid YAML, all required keys, no leftover placeholders), the private key file, the **GitHub App token exchange** (proving `app_id` + `installation_id` + `.pem` are mutually consistent), that the **board's status columns match `statuses.*`**, and — if configured — posts a **test message to Slack**.

```bash
bin/doctor            # grouped ✓/✗/– report; exits 0 only if everything passes
bin/doctor --json     # machine-readable results (what the setup skill consumes)
bin/doctor --no-slack # skip the one non-read-only action (the Slack test post)
bin/doctor --only gh_auth   # re-run a single check
```

It never writes config, mutates the board, or installs cron, and it redacts secrets from its output. The `setup-millwright` skill loops on it until green.

### Agent pullout (fresh VPS)

> ⚠️ **Before you run this.** This hands a Claude Code agent broad control of the machine. Run it only on a **fresh, dedicated VPS you own** — never a shared host or your laptop. Use a **non-root user** (e.g. `millwright`) for the checkout and cron. Secrets (the App `.pem`, the Slack webhook) must stay in the gitignored `private-key.pem` / `config.yml` (`chmod 600` the key) and must never be committed, logged, or pasted into Slack. Give the GitHub App **least privilege** and install it on **specific repos**, not all. The agent cannot do the browser-only steps (creating/installing the GitHub App, creating the Slack webhook) — it will hand those to you. Nothing goes live until `bin/doctor` is green **and** you confirm.

Paste this into a full-permission Claude Code session on the VPS:

```text
Set up Millwright on this host.
1. Clone https://github.com/njcameron/millwright.git and `cd` into it.
2. Run `bundle install`.
3. Run the `setup-millwright` skill and follow it.
When it reaches a step that needs a browser — creating the GitHub App, installing it,
or creating the Slack webhook — stop and hand it to me with exact instructions, then wait
for what I paste back. Do not install cron until `bin/doctor` is green and I confirm.
```

### Manual setup

Prefer the guided skill above, but if you'd rather do it by hand:

```bash
git clone https://github.com/njcameron/millwright.git
cd millwright
bundle install
cp config.example.yml config.yml
```

Edit `config.yml` and fill in the values described in `config.example.yml`:

- `owner`, `project_number`, `project_id` — your GitHub user/org and the Project board you created.
- `factory_username` — the username of your GitHub App's bot account (looks like `<your-bot>[bot]`).
- `slack_webhook` — your Slack incoming webhook URL. May also be supplied via the `SLACK_WEBHOOK` environment variable, which takes precedence.
- `github_app.app_id` / `installation_id` / `bot_user_id` — the numeric IDs for your GitHub App. Find them on the app's settings page and via `gh api /users/<your-bot>[bot]`.
- `github_app.private_key_path` — path to the `.pem` file you downloaded when you created the App. Keep it outside the repo, or rely on the `.gitignore` entry for `private-key.pem`.
- `routines.weekly_digest.repo` — the `<owner>/<repo>` Millwright should summarise each week.
- `routines.security_scan.repos` — list of `name` + `dir` pairs for repos to scan.

Then verify with `bin/doctor` (see above) until it's green. You can also dry-run the orchestrator — it queries the board and logs what it *would* dispatch, without spawning Claude or changing any statuses:

```bash
bundle exec ruby lib/orchestrator.rb --dry-run
```

Run it for real with:

```bash
bundle exec ruby lib/orchestrator.rb
```

**Schedule via cron.** The `bin/orchestrate`, `bin/watch`, `bin/weekly-digest`, and `bin/security-scan` wrappers `cd` into the repo and stream output to `logs/YYYY-MM-DD/*.log`. Adjust the path to wherever you cloned Millwright:

```cron
* * * * * /path/to/millwright/bin/orchestrate
* * * * * /path/to/millwright/bin/watch
0 12 * * 5 /path/to/millwright/bin/weekly-digest
0 6 * * 1 /path/to/millwright/bin/security-scan
```

`claude` must be on the `PATH` that cron sees. If your shell PATH isn't picked up by cron, set `PATH=` explicitly in the crontab.

## Configuration reference

| Key | Default | Meaning |
|---|---|---|
| `owner` | — | GitHub user/org that owns the project and repos |
| `project_number` | — | GitHub Project v2 number |
| `project_id` | — | GitHub Project v2 node ID (`PVT_...`) |
| `max_workers` | 3 | Max concurrent Claude processes |
| `max_in_review` | 5 | Pause new issues when this many PRs await review |
| `max_ci_fixes` | 2 | Max CI auto-fix attempts per PR |
| `retention_days` | 7 | Days to keep `logs/` and `state/` markers |
| `factory_username` | — | Bot username for comment tracking, e.g. `millwright-bot[bot]` |
| `slack_webhook` | — | Slack incoming webhook URL (env `SLACK_WEBHOOK` overrides) |
| `github_app.app_id` | — | GitHub App numeric ID |
| `github_app.installation_id` | — | Installation ID after installing the App |
| `github_app.bot_user_id` | — | Numeric user ID of the bot account |
| `github_app.private_key_path` | `./private-key.pem` | Path to App private key |
| `adapters.*` | see example | Which adapter to use for each concern |
| `coding_agent.bin` | `claude` | Override the `claude` binary path (Claude Code adapter) |
| `coding_agent.remote_control` | `true` | Spawn workers with `--remote-control`. `true` \| `false` \| `"session-name"` |
| `statuses.*` | see example | Names of project board columns |
| `routines.weekly_digest.repo` | — | Repo to summarise in the weekly digest |
| `routines.security_scan.workspace_dir` | repo parent dir | Default base dir for scanned repo checkouts |
| `routines.security_scan.repos` | `[]` | Repos to scan |

## Pluggable adapters

The orchestrator's four external integrations — issue tracking, version control, update channel, coding agent — sit behind adapter interfaces. See [docs/adapters.md](docs/adapters.md) for the contract, [docs/adapters/](docs/adapters/) for copy-paste skeletons, and `test/adapters/contracts/` for the shape tests every adapter must satisfy.

## Tests

```bash
bundle exec rake
```

Tests use minitest (stdlib only) and stub all external calls via dependency injection — no real GitHub, Slack, or Claude calls in tests. See [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor guide.

## File structure

```
millwright/
  bin/orchestrate            # Bash entry point for cron (every minute)
  bin/watch                  # Bash entry point for the runtime watchdog cron (every minute)
  bin/weekly-digest          # Bash entry point for weekly digest cron
  bin/security-scan          # Bash entry point for weekly security scan cron
  lib/orchestrator.rb        # Polls project board, dispatches Claude, watches PR comments and CI
  lib/routines/              # Scheduled standalone scripts (weekly_digest, security_scan, watchdog)
  lib/adapters/              # Pluggable integrations (issue tracker, VCS, update channel, coding agent)
  lib/github_client.rb       # GraphQL reads + gh CLI writes against GitHub Projects v2
  lib/github_app_token.rb    # JWT + installation token generation for bot identity
  config.example.yml         # Template — copy to config.yml and fill in
  test/                      # Unit tests (minitest)
  state/                     # Dispatch locks and notification cooldown markers (gitignored)
  logs/                      # Daily log directories (gitignored)
```

## Logs

Logs are organised into daily directories:

```
logs/
  2026-03-11/
    orchestrator.log       # orchestrator run output
    issue-193.log          # per-issue Claude session output
    pr-373.log             # per-PR review Claude session output
  2026-03-12/
    ...
```

The orchestrator automatically deletes log directories older than `retention_days` on each run.

## Professional support

If you'd like assistance deploying Millwright in your organisation, or you need custom adapters, feel free to reach out to me at neil[at]neilcameron[dot]me.

## License

MIT — see [LICENSE](LICENSE).
