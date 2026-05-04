# Yammer Effect

> **Status: v0.1 experimental.** v1 (filesystem inventory → Notion) is implemented and dogfooded by the author. Other database targets, the v2 conversation-archaeology design, and Linux scheduling are designed but not yet exercised in the wild. Treat heuristics as starting points; expect rough edges; PRs welcome.

A Claude Code skill that surfaces stalled, forgotten, or buried projects across your filesystem (and, in v2, your chat history).

## The Yammer Effect

Heavy LLM users and parallel-project operators accumulate too many tangents, deep dives, and half-finished ideas. Every conversation forks. Every spike spawns a folder. Important work gets buried under newer work, then forgotten.

Symptoms:

- Repos go quiet for weeks; you can't remember which were on purpose
- Projects stall at 80% and never quite ship
- "Wait, didn't I start that?" while reading your own filesystem
- A vague feeling that you're losing more than you're shipping

This skill builds a durable inventory of everything you have on the go and syncs it to a database you can actually filter.

## What it does (v1)

- Scans your filesystem for git repos and project folders
- Inventories each: git state, last activity, stack, deploy target, TODOs, sync state
- Syncs to a Notion database (Airtable and SQLite are designed but not yet implemented — see [`references/db-targets.md`](references/db-targets.md))
- Generates a launchd plist (macOS) for recurring scans — macOS only in v1; Linux support is template-level (cron entry provided) but the script's Keychain/`stat`/`date` calls are BSD-shaped and need porting before it'll run
- Provides an on-demand manual trigger
- Preserves your manual fields (Priority, Notes, Owner) across upserts

The output is a database you can filter by stalled, needs-review, or high-priority-but-quiet projects.

## What it doesn't do yet (v2)

**Conversation archaeology** — scraping past Claude chats for unfulfilled commitments, dropped threads, and decisions made but not recorded. The design is in [`references/v2-roadmap.md`](references/v2-roadmap.md). v2 is intentionally not built yet: the heuristics are harder than v1's, and they should be tuned against a month of real v1 data first.

## Install

1. Download the latest `.skill` bundle from [Releases](../../releases), or build it from source:
   ```bash
   git clone https://github.com/jonnydavies1/yammer-effect.git
   cd yammer-effect
   tar -czf yammer-effect.skill --exclude='.git' --exclude='.DS_Store' --exclude='.claude' .
   ```
2. Drop the `.skill` file into your Claude Code skills folder:
   - macOS/Linux: `~/.claude/skills/`
3. Restart Claude Code (or run `/skills` to refresh).
4. The skill auto-triggers when you mention "Yammer Effect", "inventory my projects", "scan my repos", or similar phrases — see `SKILL.md` for the full trigger list.

## Dependencies

The scan script is bash and shells out to standard tools. Required on the host:

- `bash` 4+ (for `mapfile`, associative arrays, process substitution)
- `jq` — JSON parsing and payload construction
- `curl` — Notion API calls
- `rg` (ripgrep) — TODO/FIXME counting and linked-doc URL extraction
- `gh` (GitHub CLI) — open-PR counts; needs `gh auth login` once
- `git` — repo state, history, working-tree status
- POSIX userland: `awk`, `sed`, `find`, `xargs`, `stat`, `date`, `tr`, `grep`

macOS-specific (v1):

- `security` (macOS Keychain) — built-in; the script reads the Notion integration token from a keychain entry named `yammer-scan`
- BSD `stat -f` and `date -r` — the script's invocations don't match GNU coreutils flags

Notion side: an internal integration with the database shared via Notion's Connections UI. The skill workflow walks you through this setup.

## Quick start

A typical first run, in five steps:

1. **Trigger the skill** — tell Claude something like "I need to inventory my projects" or "run the Yammer Effect skill on my Mac".
2. **Confirm scan paths** — Claude proposes candidate folders (`~/code`, `~/projects`, `~/Desktop`, etc.) and stops to confirm before scanning.
3. **Confirm Notion as your target** — confirm the workspace and parent page explicitly. Wrong workspace = rework.
4. **Dry run first** — always. The skill scans, classifies every folder, and shows you the payloads before writing anything.
5. **Real sync, then schedule** — once the dry run looks right, do the real sync and load the launchd plist (macOS only in v1). A cron template is provided for Linux but the script itself uses macOS Keychain, BSD `stat -f`, and BSD `date -r` and won't run on Linux without porting. The 12h debounce means multiple triggers a day are safe.

After that, the inventory updates itself. Open it on your phone, filter for "stalled and high priority", and triage.

## Roadmap

See [`references/v2-roadmap.md`](references/v2-roadmap.md) for the conversation-archaeology design. Highlights:

- Surface unfulfilled commitments from chat history ("I'll do X" with no follow-through)
- Detect decisions made but not recorded
- Cross-reference filesystem state with chat-stated intent
- Auto-archive commitments older than 90 days unless they reappear

v2 is design-only for now. v1 ships first; v2 builds on observed v1 gaps, not optimism.

## Honest scope

- **v1 is filesystem-only.** That's the half that's already validated.
- **v2 is design-only.** The conversation-archaeology heuristics will earn trust before they earn a build.
- **Manifest-only stack inference.** Empty Stack is honest; guessed Stack is misinformation.
- **Manual fields are sacred.** The scanner will never touch your Priority, Notes, or manual Status=Archived.
- **Scope guards are hard stops.** The script refuses to write to any database that isn't the one configured.

## Repository layout

```
.
├── SKILL.md                              Orchestration and workflow
├── README.md                             This file
├── LICENCE                               MIT
├── references/
│   ├── architecture.md                   Why bash, why Notion, why these tradeoffs
│   ├── schema.md                         Database property definitions
│   ├── db-targets.md                     Notion (built), Airtable / SQLite (designed)
│   ├── heuristics.md                     Detection logic for projects and stacks
│   ├── troubleshooting.md                Common failure modes
│   └── v2-roadmap.md                     Conversation archaeology design
└── scripts/
    ├── yammer-scan-template.sh           Working scan script (with placeholders)
    ├── launchd-plist-template.xml        macOS scheduling template
    └── cron-template.txt                 Linux scheduling template
```

## Contributing

Issues and PRs welcome. Particularly useful contributions:

- **New database targets** — Linear, Obsidian, Logseq, Things, etc. The scan layer is target-agnostic; adding a target is mostly a thin write-adapter.
- **Heuristic tuning** — false-positive or false-negative reports on project detection, stack inference, or boilerplate H1s. Real-world examples beat synthetic ones.
- **v2 design feedback** — if you've thought about conversation archaeology heuristics and have opinions, the v2 roadmap is the place to argue them.

Open an issue before a large PR so we can sanity-check scope.

## Licence

MIT — see [`LICENCE`](LICENCE).
