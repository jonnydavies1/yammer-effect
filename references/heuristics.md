# Detection Heuristics

The fiddly bits. Get these wrong and the inventory is misleading.

## Project marker files (non-git folders)

A folder counts as a "non-git project" if it contains any of these at root:

- Frontend: `package.json`, `index.html`, `*.html`, `.lovable`
- Python: `requirements.txt`, `pyproject.toml`, `main.py`, any `*.py`
- Rust: `Cargo.toml`
- Go: `go.mod`
- Ruby: `Gemfile`
- .NET: `*.csproj`
- Design: `*.fig`, `*.sketch`
- Docs: `README.md`
- Scripts: any `*.sh`

**Don't be too narrow.** An early version of this skill only checked frontend markers and silently skipped Python and other non-JS projects - exactly the kind of forgotten work the skill is meant to surface.

**Don't be too broad.** A folder with only `.DS_Store` shouldn't count. Empty folders shouldn't count.

## Stack inference (manifest-only)

Inference rules, in priority order:

| Manifest | Stack tags |
|----------|------------|
| `package.json` deps include `typescript` or `*.ts` files exist | typescript |
| `package.json` (no TS) | javascript |
| `package.json` deps include `react` | react |
| `package.json` deps include `next` | nextjs |
| `package.json` deps include `vite` | vite |
| `package.json` deps include `hono` | hono |
| `package.json` deps include `wrangler` or `@cloudflare/workers-types` | wrangler |
| `requirements.txt` or `pyproject.toml` | python |
| `requirements.txt` includes `fastapi` | fastapi |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `Gemfile` | ruby |
| `*.csproj` | dotnet |

**Monorepo subdirs**: probe one level deep for these conventional names: `apps/*`, `services/*`, `packages/*`, `frontend/`, `backend/`, `api/`, `web/`, `client/`, `server/`. Aggregate findings. Users with non-standard top-level dirs (e.g. `dashboard/`, `ingestion/`) should extend this list locally.

**Cap depth at 1.** Deeper scanning starts hitting `node_modules` and dependency manifests, which inflates the stack list with library names.

**Cap total options at 25.** Beyond this, log a warning and skip new option creation rather than failing. Stack list explosion is a smell.

**Manifest-only is non-negotiable.** Empty Stack is honest. Inferring "javascript" from the presence of a `.html` file is misinformation.

## Boilerplate H1 deny-list

When the README H1 differs from the folder name, use H1 as Name - unless H1 matches one of these (case-insensitive):

- "Welcome to your Lovable project"
- "Welcome to your project"
- "My Project"
- "Project"
- "README"
- "Untitled"
- "New Project"
- "Default Project"

These are AI-generator boilerplate and produce useless rows ("Welcome to your Lovable project" times three). Make the deny-list a config constant near the top of the script so users can extend it.

## TODO/FIXME counting

- Use ripgrep (`rg`) on tracked files for git repos: `git ls-files | xargs rg -c 'TODO|FIXME'`
- For non-git projects, ripgrep the full tree minus exclude globs
- Don't include `node_modules`, `.next`, `dist`, etc - even if not gitignored

A repo with 1000 TODOs is almost always counting library code, which is useless. Capping the report at "TODOs > 200" with a warning helps surface the misconfiguration.

## Linked docs regex

Match these URL patterns in README.md and CLAUDE.md:

- `https://www\.notion\.so/[a-z0-9-]+`
- `https://[a-z0-9-]+\.notion\.site/[a-z0-9-]+`
- `https://[a-z0-9-]+\.atlassian\.net/[a-zA-Z0-9/_-]+`
- `https://linear\.app/[a-zA-Z0-9/_-]+`

Empty Linked docs is correct when the README really has no links. Verify with a known-good file before assuming empty results indicate a regex bug.

## Status precedence

```
1. No .git           -> Non-git
2. Last activity > 30d -> Stalled
3. Uncommitted OR ahead -> Needs review
4. Otherwise         -> Active
5. Manual Archived overrides everything (preserved on upsert)
```

**The Status field can only carry one value.** This means stale non-git projects get classified as Non-git and disappear from the Stalled view. Solution: filter the Stalled view by `Days since last touch > 30` rather than `Status = Stalled`. See `schema.md`.

## Last activity calculation

```
last_activity = max(last_commit_date, folder_mtime)
```

For non-git folders, last_commit_date is null, so folder_mtime wins. For git repos, folder_mtime catches recent editing without commits. This is what makes "Days since last touch" honest.

## Worktree count (parallel-branch tooling)

Only populate when the repo lives under a known parallel-branch tool's repo directory — for example, if your tool stores worktrees at `~/conductor/repos/<name>/`, count subdirectories of `~/conductor/workspaces/<name>/`. Blank for any other path.

This avoids creating one row per worktree (which would flood the DB) while keeping the worktree signal visible on the base repo's row.

## Common detection bugs

| Symptom | Cause | Fix |
|---------|-------|-----|
| Purpose duplicated | awk END block prints buf twice | Clear buf before exit, or print only in END |
| Stack empty on monorepo | Only checking root manifests | Probe one level deep |
| Non-git project skipped | Heuristic too narrow | Extend marker file list |
| Boilerplate Name | H1 override fired on AI-generated template | Add to deny-list |
| `out[@]: unbound variable` | `set -u` + empty array | Gate with `[ ${#out[@]} -gt 0 ]` |
| TODOs in the thousands | Not excluding `node_modules` etc | Use `git ls-files` for repos, exclude globs for non-git |
