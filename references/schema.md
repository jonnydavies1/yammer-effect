# Database Schema

The default schema, designed for Notion but adaptable to other targets. Properties grouped by who controls them.

## Auto-derived (overwritten on every scan)

| Property | Type | Notes |
|----------|------|-------|
| Name | Title | Folder name; or README H1 if not on boilerplate deny-list |
| Status | Select | Active, Stalled, Needs review, Non-git, Archived |
| Path | Rich text | Absolute path - upsert key |
| Remote | URL | Origin remote |
| Branch | Rich text | Current branch; short SHA if detached HEAD |
| Sync state | Rich text | "clean" or "ahead N, behind M, dirty K, stash J" |
| Open PRs | Number | Via `gh pr list`, github.com remotes only |
| Last commit | Date | Author date of HEAD |
| Last commit message | Rich text | First line of HEAD message |
| Last activity | Date | Max of last commit date and folder mtime |
| Days since last touch | Number | Computed from Last activity |
| Stack | Multi-select | Manifest-only inference, capped at 25 options |
| Deploy target | Select | First-match from config files |
| Has CLAUDE.md | Checkbox | - |
| TODOs | Number | TODO/FIXME count via ripgrep on tracked files |
| Purpose | Rich text | First README paragraph or H1 fallback, 280 chars max |
| Linked docs | Rich text | Notion/Jira/Linear/Atlassian URLs from README and CLAUDE.md |
| Last synced | Date | Scan timestamp |
| Worktree count | Number | Number of git worktrees for the repo (relevant if you use a tool like Conductor for parallel branch development), else blank |
| Unmerged branches | Number | Local branches not merged into default |

## Manual (preserved on upsert)

| Property | Type | Default | Purpose |
|----------|------|---------|---------|
| Priority | Select | Unset | High, Medium, Low, Unset - what matters now |
| Project type | Select | Unset | Work, Side project, Client, Learning, Archived-but-keep |
| Owner/Context | Select | Unset | Which world this belongs to (Company A, Company B, Personal, Other) |
| Notes | Rich text | empty | One-line "what's stuck" or "blocked on X" |
| Status=Archived | (preserved) | n/a | If user sets Status to Archived, scan won't override |

## Status auto-rules

Computed in this order. First match wins.

1. No `.git` directory → **Non-git**
2. Last activity > 30 days ago → **Stalled**
3. Uncommitted changes OR ahead of origin → **Needs review**
4. Otherwise → **Active**

**Archived** is never auto-set. If the user manually sets Status to Archived, the scanner preserves it.

## Default views

| View | Filter | Sort |
|------|--------|------|
| All projects | none | Last activity desc |
| Stalled | Days since last touch > 30 AND Status != Archived | Days since last touch desc |
| Needs review | Status = Needs review | Last activity desc |
| High priority stalled | Days since last touch > 30 AND Priority = High AND Status != Archived | Days since last touch desc |
| By context | none, group by Owner/Context | Last activity desc |
| Recent activity | none | Last activity desc, limit 10 |

## Why these specific fields

**Last activity, not Last commit**: non-git folders don't have commits but they get touched. Folder mtime catches active editing without commits. Computing days-since from Last activity surfaces stale non-git work that pure git-mtime misses entirely.

**Manual fields preserved on upsert**: the manual triage data (Priority, Notes) is what makes the inventory useful. If a daily scan wiped it, no one would maintain it.

**Stalled view filters by Days, not Status**: because the Status field can only carry one value, "Non-git AND stalled" gets flattened to "Non-git" alone. Filtering by Days side-steps that.

**Worktree count (for parallel-branch tooling like Conductor)**: counts subdirs in the tool's workspace directory for the repo. Blank for everything else. Lets one row represent a repo with many feature branches without flooding the DB with worktree rows.
