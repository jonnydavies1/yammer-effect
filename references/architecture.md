# Architecture decisions

Short notes on the load-bearing choices in v1, and the tradeoffs that shaped them. If you're considering a fork or a contribution, this is the file that says "here's why it isn't already that way."

## Why bash (not Python)

The script is one file, ~750 lines, with three external dependencies: `jq`, `curl`, `gh`. All three are present on most developer Macs already; on Linux they're a one-line install. There is no virtual environment to activate, no `pip install` to drift, no Python version mismatch to debug at 9am on a Monday.

The cost: bash is unforgiving on edge cases (`set -euo pipefail` is mandatory; empty array refs trap; subshells lose state). The script earns its complexity by avoiding install friction — the moment a contributor needs to "set up the project" before running it once, adoption drops.

If v2's conversation-archaeology layer needs heavier lifting (parsing JSONL chat logs, NLP on commitments), that's the moment to reach for Python. v1 doesn't.

## Why Notion as the default target

Most users with the Yammer Effect symptom — too many parallel projects, things stalling at 80% — already have Notion. Rich filtering, multiple views, mobile access, no separate viewer to install. The skill's value is "see your stale work on your phone over coffee," and Notion delivers that without extra tooling.

The cost: Notion's API is rate-limited (~3 req/sec), workspaces can be misconfigured (the wrong-workspace failure mode is real and expensive), and the OAuth/integration model is fiddly. The scope guard exists specifically to make wrong-workspace damage impossible.

Airtable and SQLite are documented in `db-targets.md` as designed-but-not-built. The data model is target-agnostic; adding them is a write-adapter, not a redesign.

## Why launchd with multiple triggers + debounce

The naive scheduler is "run once a day at 09:00." The naive scheduler fails the moment a laptop is closed at 09:00. Cron and launchd both fire only when the machine is awake, so a closed-lid scheduled run is silently skipped.

The pattern that survives lid-closing:

- **Multiple `StartCalendarInterval` triggers** at 06:00, 09:00, 13:00 (or whatever fits the user's day)
- **A 12h debounce** in the script itself — first trigger of the day runs the scan, subsequent triggers see the cache file and skip

Whichever wake time the laptop is open at runs the scan; the rest exit fast. The user gets at most one scan per day without coordinating with the OS sleep/wake cycle.

The cost: a debounce file at `~/Library/Caches/yammer-scan.last` that needs to be deleted to force a re-run. `--dry-run` and `--repo` both bypass debounce explicitly, so this isn't a footgun in practice.

## Why manifest-only stack inference

The skill's job is to surface forgotten work. False data — "this is a JavaScript project" when it's actually a Python project with a stale `package.json` — erodes trust and makes the inventory useless.

Stack tags only appear when a manifest unambiguously declares them: `package.json` for JavaScript/TypeScript, `Cargo.toml` for Rust, `go.mod` for Go, etc. The script never infers from file extensions alone (a single `.py` doesn't make a project Python; a single `.html` doesn't make it a frontend project — those are folder-classification signals, not stack signals).

The cost: empty Stack on a folder that "obviously" uses a particular language. That's the right tradeoff. Empty Stack is honest; guessed Stack is misinformation, and an inventory you can't trust is one you stop opening.

## Why upsert-by-path, not by repo URL

Repos move. Forks happen. A folder's path on disk is the most stable identifier the inventory has. Two folders with the same git remote (a fork and the original) are two distinct rows because they're two distinct working copies on the user's filesystem.

The cost: renaming a folder creates a new row and orphans the old one. The user's manual fields (Priority, Notes) on the old row are lost unless they re-enter them. This is rare enough in practice not to justify a rename-detection layer; if it becomes a problem, content-hash matching on README+remote could be added.

## Why the workspace scope guard is non-negotiable

The single highest-cost failure mode of this script is "wrote to the wrong Notion database." Reasons it could happen: copy-pasted DB ID from another project, stale config after a workspace migration, integration shared with multiple databases.

The mitigation runs before every write:

1. `verify_workspace_scope` fetches the target DB and confirms title + parent page match the configured expectations. Mismatch → exit before any write.
2. `notion_curl` rejects any non-GET request whose path or body falls outside the allowlist (the configured DB's query/update endpoints, or POST /pages with the right `parent.database_id`).

Both layers exist because the user has been burned by single-layer guards before. The cost — a few dozen lines of bash and one extra API call per run — is trivial against the cost of corrupting a real database.
