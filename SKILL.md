---
name: yammer-effect
description: Surface stalled, forgotten, or buried projects across a user's filesystem and (later) chat history, then sync findings to a database for ongoing tracking. Use this skill whenever a user mentions losing track of projects, having too many parallel threads, projects stalling at 80%, forgetting what they started, repos going stale, the "Yammer Effect", inventorying their work, or wanting a tracker for everything they have on the go. Also trigger when a user wants to scan a directory of repos and sync the results to Notion or another tracker, or asks for a scheduled audit of their project folders.
---

# Yammer Effect

Combat the Yammer Effect: heavy LLM and parallel-project users accumulate too many tangents, deep dives, and half-finished work across sessions and folders. Important things get buried, forgotten, or lost. This skill builds a durable inventory that surfaces what's stalling.

## When to use

Trigger this skill when the user describes any of:

- "I have too many projects on the go"
- "I keep losing track of things"
- "Projects stalling at 80%"
- "Inventory my repos / projects / folders"
- "Scan my Mac for repos"
- "Sync my project list to Notion"
- "What have I forgotten about?"
- "Daily / weekly audit of my projects"
- The phrase "Yammer Effect" specifically

Also trigger when the user's context shows many parallel projects (multiple repos, side projects, advisory work) and they're asking about tracking, prioritisation, or focus.

## What this skill does (v1 - filesystem)

v1 ships filesystem inventory only. v2 adds conversation archaeology (see `references/v2-roadmap.md` for the design).

The v1 workflow:

1. Discover project folders across user-defined scan paths
2. Inventory each: git state, last activity, stack, deploy target, TODOs, sync state
3. Sync to a target database (Notion default, configurable)
4. Schedule recurring scans via launchd (macOS) or cron (Linux)
5. Provide a manual on-demand trigger

The output is a database the user can filter by stalled projects, projects needing review, or projects high-priority-but-quiet.

## Workflow

Walk through these phases in order. Stop at every decision point - never assume defaults that affect the user's filesystem or external services.

### Phase 1: Discovery

Scan the user's home directory for project locations. Default candidate paths to check (use only those that exist):

- `~/code`, `~/projects`, `~/dev`, `~/Documents/projects`, `~/Sites`
- `~/Desktop` (top-level only)
- Any directory at `~/` depth 1-2 containing 3+ git repos

Exclude during scan: `node_modules`, `.next`, `dist`, `build`, `out`, `vendor`, `.venv`, `venv`, `__pycache__`, `.Trash`, `Library`, `target`. Max depth 4 from each scan root. Never recurse into nested `.git` directories.

Output to user: which paths exist, what was found in each, total counts. **Stop and confirm scan path list before proceeding.**

### Phase 2: Database setup

Default target: Notion. Other designed targets (not yet implemented): Airtable, local SQLite (see `references/db-targets.md`).

Ask the user which workspace and parent location for the database. Never assume. The most common failure mode is creating the DB in the wrong workspace - confirm explicitly.

Schema: see `references/schema.md` for the full property list with types, defaults, and rationale. Key principles:

- **Manual fields preserved on upsert**: Priority, Project type, Owner/Context, Notes, Status=Archived
- **Auto-derived fields overwritten on every scan**: everything else
- **Upsert key**: absolute path
- **Status precedence**: Non-git overrides Stalled. The Stalled view should filter by `Days since last touch > 30` rather than `Status = Stalled` to surface stale non-git projects too.

Create the database, six default views (All, Stalled, Needs review, High priority stalled, By context, Recent activity), and stop for confirmation before populating.

### Phase 3: Build the scan script

Generate `~/bin/yammer-scan.sh` (or platform equivalent). Required behaviours:

**Per git repo**:
- Folder name (override with README H1 only if not on the boilerplate deny-list)
- Path, remote URL, current branch
- Ahead/behind counts vs origin
- Uncommitted file count, stash count
- Last commit date, author, message first line
- Open PRs via `gh` CLI (github.com remotes only)
- Stack inferred from manifests only (no guessing). Probe one level deep for conventional monorepo subdirs (`apps/*`, `services/*`, `packages/*`, `frontend/`, `backend/`, etc — full list in `heuristics.md`).
- Deploy target from config files
- README first paragraph, max 280 chars (with H1 fallback if no paragraph)
- TODO/FIXME count via ripgrep on tracked files
- CLAUDE.md / SKILL.md presence
- Notion/Jira/Linear/Atlassian URLs from README and CLAUDE.md

**Per non-git project folder** (heuristic must be broad - frontend, Python, Rust, Go, Ruby, .NET, scripts):
- Marker files: any of `package.json`, `index.html`, `.lovable`, `README.md`, `*.fig`, `*.sketch`, `requirements.txt`, `pyproject.toml`, `main.py`, `Cargo.toml`, `go.mod`, `Gemfile`, `*.csproj`, `*.html`, or any `*.py`/`*.sh` at folder root
- Name, path, type, last modified

**Hard guards** (mandatory, not optional):
- Workspace scope check at start of every run (verify DB title and parent page match expected values; abort on mismatch)
- Write-time guard: refuse any non-GET request that would write outside the configured database
- Set `-euo pipefail`; gate array references with `[ ${#arr[@]} -gt 0 ]` to avoid nounset traps

**Flags**:
- `--dry-run`: scan and log payloads, no writes, bypasses debounce
- `--repo <path>`: scan one path only and upsert that single row, bypasses debounce
- (default): full scan with 12h debounce

**Logging**: ISO timestamps, mode prefix, errors duplicated to stderr. Log to `~/Library/Logs/yammer-scan.log` on macOS, `~/.local/state/yammer/scan.log` on Linux.

See `scripts/yammer-scan-template.sh` for the reference implementation.

### Phase 4: Scheduling

Generate the scheduled trigger:

**macOS**: launchd plist with multiple `StartCalendarInterval` entries (06:00, 09:00, 13:00 default) plus 12h debounce. The multi-trigger pattern handles laptop sleep - whichever wake time hits first runs once, the rest skip via debounce.

**Linux**: cron entry with the same debounce logic in the script.

Add a shell alias (`inv` or `yammer`) for manual scans. Append to `~/.zshrc` or `~/.bashrc` with backup.

See `scripts/launchd-plist-template.xml` and `scripts/cron-template.txt`.

### Phase 5: Bootstrap and dry-run

Always run `--dry-run` first. Show the user every classification, every payload, every skipped folder with reason. Common bugs to eyeball:

- Empty Purpose on badge-heavy READMEs (common in polyglot repos where shields.io badges precede the first prose paragraph)
- Boilerplate H1s overriding folder names ("Welcome to your Lovable project")
- Polyglot repos missing stack entries
- Non-git folders being silently skipped (heuristic too narrow)
- TODOs absurdly high (ripgrep including `node_modules`)

Fix any bugs surfaced, re-run dry-run, then real sync.

### Phase 6: Final report

Summary: total projects, status breakdown, top 5 by days since last touch, top 5 by uncommitted/dirty work, follow-ups needing user attention (e.g. project with no .git that should be initialised).

Provide the launchd/cron load command but don't load automatically - the user activates when ready.

## Reference files

| File | When to read |
|------|--------------|
| `references/schema.md` | Building or modifying the database schema |
| `references/db-targets.md` | User wants Airtable, SQLite, or other non-Notion target |
| `references/heuristics.md` | Tuning the project-detection or stack-inference logic |
| `references/v2-roadmap.md` | User asks about conversation archaeology or "what's next" |
| `references/troubleshooting.md` | Things break - keychain, OAuth, scope guard, etc |

## Bundled scripts

| File | Purpose |
|------|---------|
| `scripts/yammer-scan-template.sh` | Reference scan script - copy and customise |
| `scripts/launchd-plist-template.xml` | macOS scheduled trigger |
| `scripts/cron-template.txt` | Linux scheduled trigger |

## Hard rules

1. **Never write to a database that isn't the configured target.** Workspace guard runs before every write.
2. **Never auto-set Priority or Status=Archived.** These are manual fields, preserved across upserts.
3. **Stop at every phase boundary.** Confirm with the user before proceeding. The cost of one wrong assumption (wrong workspace, wrong scan path) is a pile of rework.
4. **Manifest-only stack inference.** Empty Stack is honest; guessed Stack is misinformation.
5. **Confirm scan paths exist on disk** before committing them to config. If `~/code` doesn't exist, don't include it.
6. **Dry-run before any real write.** Always.
