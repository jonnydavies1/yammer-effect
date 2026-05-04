#!/usr/bin/env bash
# yammer-scan.sh — inventory project folders, sync to a Notion database.
#
# This is the working v1 implementation shipped with the yammer-effect skill.
# It is a TEMPLATE: the CONFIG section below contains REPLACE_WITH_YOUR_*
# placeholders that must be filled in before the script will run.
#
# RECOMMENDED PATH: run the yammer-effect skill in Claude Code. The SKILL.md
# workflow walks Claude through filling in these placeholders for you (Notion
# OAuth, parent page selection, scan path discovery, schema creation) and
# writes the customised script to ~/bin/yammer-scan.sh.
#
# MANUAL PATH: copy this file, replace every REPLACE_WITH_YOUR_* below, and
# add at least one entry to SCAN_ROOTS or SINGLE_PROJECTS.
#
# Modes:
#   yammer-scan.sh                  full scan, write to Notion (12h debounce)
#   yammer-scan.sh --dry-run        full scan, log payloads, no writes
#   yammer-scan.sh --repo <path>    scan one path only, write that single row
#
# One-time setup (normally handled by the skill):
#   1. Create a Notion internal integration: notion.so/profile/integrations
#   2. Store the integration token in the macOS keychain:
#        security add-generic-password -s yammer-scan -a "$USER" -w '<token>'
#      (Linux: adapt to your secret store, e.g. pass, libsecret.)
#   3. In Notion, share your inventory database with that integration
#      (database page → ⋯ → Connections → add the integration).
#   4. Fill in the CONFIG values below.

set -euo pipefail
shopt -s nullglob

# --- Configuration ---------------------------------------------------------

NOTION_DB_ID="REPLACE_WITH_YOUR_DB_ID"
NOTION_VERSION="2022-06-28"
LOG_FILE="$HOME/Library/Logs/yammer-scan.log"

# Hard scope guard. The script refuses to run if these don't match the
# database it is pointed at, and notion_curl refuses any modifying request
# outside this database (or its rows). A wrong DB ID is the failure mode this
# guard exists to catch — if your Notion workspace contains other people's
# pages, this is what stops the scanner from touching anything else.
NOTION_EXPECTED_DB_TITLE="REPLACE_WITH_YOUR_DB_TITLE"
NOTION_EXPECTED_PARENT_PAGE_ID="REPLACE_WITH_YOUR_PARENT_PAGE_ID"

# Debounce: skip a scheduled full sync if the last successful scan was fewer
# than DEBOUNCE_SECONDS ago. Keeps a multi-trigger launchd plist (e.g. 06/09/13)
# from double-running on a given day.
DEBOUNCE_FILE="$HOME/Library/Caches/yammer-scan.last"
DEBOUNCE_SECONDS=$(( 12 * 3600 ))

# Roots whose immediate subdirectories are project folders.
# Add any directory whose direct children are repos/projects.
SCAN_ROOTS=(
  # "$HOME/code"
  # "$HOME/projects"
  # "$HOME/CLAUDE-PROJECTS"
)

# Paths that are themselves a single project root (not a parent of repos).
SINGLE_PROJECTS=(
  # "$HOME/some-specific-repo"
)

# Optional: if you use a parallel-branch tool that stores worktrees alongside
# the base repo (e.g. Conductor's "$HOME/conductor/repos/<name>" pattern),
# point this at the workspaces directory so the Worktree count field can be
# populated. Leave blank if you don't use such a tool.
WORKTREE_BASE=""  # e.g. "$HOME/conductor/workspaces"
WORKTREE_REPO_PARENT=""  # e.g. "$HOME/conductor/repos" — only repos under this path get a worktree count

# Hard cap on Stack multi-select option count (Notion).
STACK_OPTION_CAP=25

# README H1 deny-list: H1s that match (case-insensitive, exact) are treated as
# boilerplate and the folder name is used instead. Extend as new generators
# show up.
README_TITLE_DENYLIST=(
  "welcome to your lovable project"
  "welcome to your project"
  "my project"
  "project"
  "readme"
  "untitled"
  "new project"
  "default project"
)

# --- Placeholder guard -----------------------------------------------------
# Refuse to run if the user hasn't replaced the placeholder values. This
# fails fast with a clear message instead of producing a confusing 404 from
# the Notion API.

_check_placeholders() {
  local bad=0
  case "$NOTION_DB_ID" in REPLACE_WITH_YOUR_*|"") bad=1 ;; esac
  case "$NOTION_EXPECTED_DB_TITLE" in REPLACE_WITH_YOUR_*|"") bad=1 ;; esac
  case "$NOTION_EXPECTED_PARENT_PAGE_ID" in REPLACE_WITH_YOUR_*|"") bad=1 ;; esac
  if [ "$bad" = "1" ]; then
    printf 'yammer-scan: configuration incomplete — replace REPLACE_WITH_YOUR_* values in the CONFIG section.\n' >&2
    printf 'See the script header for setup instructions, or run the yammer-effect skill in Claude Code.\n' >&2
    exit 2
  fi
  if [ ${#SCAN_ROOTS[@]} -eq 0 ] && [ ${#SINGLE_PROJECTS[@]} -eq 0 ]; then
    printf 'yammer-scan: no scan paths configured — add at least one entry to SCAN_ROOTS or SINGLE_PROJECTS.\n' >&2
    exit 2
  fi
}

# --- Logging ---------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${MODE:-init}" "$*" | tee -a "$LOG_FILE"
}

err() {
  printf '%s [%s] ERROR %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${MODE:-init}" "$*" | tee -a "$LOG_FILE" >&2
}

# --- Argument parsing ------------------------------------------------------

MODE="scan"
TARGET_REPO=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ -n "${2:-}" ] || { err "--repo requires a path argument"; exit 2; }
      [ -d "$2" ] || { err "--repo path does not exist or is not a directory: $2"; exit 2; }
      TARGET_REPO="$2"
      MODE="single"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      err "unknown arg: $1"
      exit 2
      ;;
  esac
done

if [ "$MODE" = "single" ] && [ "$DRY_RUN" -eq 1 ]; then
  err "--dry-run not compatible with --repo"
  exit 2
fi

_check_placeholders

# --- Notion token ----------------------------------------------------------

NOTION_TOKEN="$(security find-generic-password -s yammer-scan -a "$USER" -w 2>/dev/null || true)"
if [ -z "$NOTION_TOKEN" ]; then
  err "notion token not found in keychain. See setup instructions in the script header."
  exit 1
fi

# --- Notion API helpers ----------------------------------------------------

NOTION_API="https://api.notion.com/v1"

# Strip dashes for UUID compares.
_uuid_norm() { printf '%s' "$1" | tr -d '-' | tr '[:upper:]' '[:lower:]'; }

notion_curl() {
  # $1 method, $2 path, $3 optional JSON body.
  # Modifying operations are scope-checked against NOTION_DB_ID. GETs pass through.
  local method="$1" path="$2" body="${3:-}"

  if [ "$method" != "GET" ]; then
    local our_db
    our_db="$(_uuid_norm "$NOTION_DB_ID")"
    case "$method $path" in
      "POST /databases/$NOTION_DB_ID/query")
        : # read by query, allowed
        ;;
      "PATCH /databases/$NOTION_DB_ID")
        : # schema mutate on our DB only (e.g. Stack option append)
        ;;
      "POST /pages")
        local parent_db
        parent_db="$(_uuid_norm "$(printf '%s' "$body" | jq -r '.parent.database_id // empty' 2>/dev/null)")"
        if [ "$parent_db" != "$our_db" ]; then
          err "GUARD: refused POST /pages with parent.database_id=$parent_db (expected $our_db)"
          return 99
        fi
        ;;
      "PATCH /pages/"*)
        # Page updates are scoped because page_ids only come from
        # find_page_by_path which queries our DB. Defence-in-depth: refuse any
        # PATCH body that tries to move the page (changes parent).
        if printf '%s' "$body" | jq -e '.parent' >/dev/null 2>&1; then
          err "GUARD: refused PATCH /pages/* that attempts to change parent"
          return 99
        fi
        ;;
      *)
        err "GUARD: refused $method $path - not on the write allowlist"
        return 99
        ;;
    esac
  fi

  if [ -n "$body" ]; then
    curl -sS -X "$method" "$NOTION_API$path" \
      -H "Authorization: Bearer $NOTION_TOKEN" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sS -X "$method" "$NOTION_API$path" \
      -H "Authorization: Bearer $NOTION_TOKEN" \
      -H "Notion-Version: $NOTION_VERSION"
  fi
}

# One-time startup check: the configured DB really is the expected inventory,
# and it sits under the expected parent page. Aborts the run on mismatch.
verify_workspace_scope() {
  local resp db_title parent_page_id expected_parent
  resp="$(notion_curl GET "/databases/$NOTION_DB_ID")"
  if ! printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
    err "scope guard: failed to fetch database $NOTION_DB_ID - $resp"
    exit 1
  fi
  db_title="$(printf '%s' "$resp" | jq -r '.title[0].plain_text // ""')"
  parent_page_id="$(_uuid_norm "$(printf '%s' "$resp" | jq -r '.parent.page_id // ""')")"
  expected_parent="$(_uuid_norm "$NOTION_EXPECTED_PARENT_PAGE_ID")"

  if [ "$db_title" != "$NOTION_EXPECTED_DB_TITLE" ]; then
    err "scope guard: DB title mismatch (got '$db_title', expected '$NOTION_EXPECTED_DB_TITLE')"
    exit 1
  fi
  if [ "$parent_page_id" != "$expected_parent" ]; then
    err "scope guard: parent page mismatch (got '$parent_page_id', expected '$expected_parent')"
    exit 1
  fi
  log "scope guard OK: '$db_title' under parent page $parent_page_id"
}

# Cache the database schema once per run for Stack option enforcement.
DB_SCHEMA_JSON=""
get_db_schema() {
  if [ -z "$DB_SCHEMA_JSON" ]; then
    DB_SCHEMA_JSON="$(notion_curl GET "/databases/$NOTION_DB_ID")"
    if ! printf '%s' "$DB_SCHEMA_JSON" | jq -e '.id' >/dev/null 2>&1; then
      err "failed to fetch database schema: $DB_SCHEMA_JSON"
      exit 1
    fi
  fi
  printf '%s' "$DB_SCHEMA_JSON"
}

# Get the current set of Stack options (multi-select) by name.
current_stack_options() {
  get_db_schema | jq -r '.properties.Stack.multi_select.options[].name'
}

# Append new Stack options up to the cap. $@ is the proposed names.
ensure_stack_options() {
  local proposed=("$@")
  [ ${#proposed[@]} -gt 0 ] || return 0

  local existing
  existing="$(current_stack_options)"
  local existing_count
  existing_count="$(printf '%s\n' "$existing" | grep -c . || true)"

  local to_add=()
  local opt
  for opt in "${proposed[@]}"; do
    if ! printf '%s\n' "$existing" | grep -qx "$opt"; then
      to_add+=("$opt")
    fi
  done

  [ ${#to_add[@]} -gt 0 ] || return 0

  if (( existing_count + ${#to_add[@]} > STACK_OPTION_CAP )); then
    log "stack option cap ($STACK_OPTION_CAP) would be exceeded - skipping append of: ${to_add[*]}"
    USE_STACK=()
    for opt in "${proposed[@]}"; do
      if printf '%s\n' "$existing" | grep -qx "$opt"; then
        USE_STACK+=("$opt")
      fi
    done
    return 0
  fi

  # Dry-run: surface what the schema mutation would be, but never PATCH.
  # The DB write here is the same kind of mutation /pages writes are, so it
  # must respect DRY_RUN to keep the safety promise in README and SKILL.md.
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would add stack options: ${to_add[*]}"
    USE_STACK=("${proposed[@]}")
    return 0
  fi

  local merged_json
  merged_json="$(get_db_schema | jq --argjson new "$(printf '%s\n' "${to_add[@]}" | jq -R . | jq -s .)" \
    '[.properties.Stack.multi_select.options[].name] + $new | unique | map({name: .})')"

  local patch_body
  patch_body="$(jq -n --argjson opts "$merged_json" \
    '{properties: {Stack: {multi_select: {options: $opts}}}}')"

  local resp
  resp="$(notion_curl PATCH "/databases/$NOTION_DB_ID" "$patch_body")"
  if ! printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
    err "failed to add stack options ${to_add[*]}: $resp"
    USE_STACK=()
    for opt in "${proposed[@]}"; do
      if printf '%s\n' "$existing" | grep -qx "$opt"; then
        USE_STACK+=("$opt")
      fi
    done
    return 0
  fi

  log "added stack options: ${to_add[*]}"
  DB_SCHEMA_JSON=""  # invalidate cache
  USE_STACK=("${proposed[@]}")
}

# Find existing page by Path. Echoes page_id or empty.
find_page_by_path() {
  local path="$1"
  local body
  body="$(jq -n --arg p "$path" \
    '{filter: {property: "Path", rich_text: {equals: $p}}, page_size: 1}')"
  notion_curl POST "/databases/$NOTION_DB_ID/query" "$body" \
    | jq -r '.results[0].id // empty'
}

# Pull manual-field values to preserve. Echoes JSON object.
fetch_manual_fields() {
  local page_id="$1"
  local resp
  resp="$(notion_curl GET "/pages/$page_id")"
  printf '%s' "$resp" | jq '{
    priority: (.properties.Priority.select.name // null),
    project_type: (.properties."Project type".select.name // null),
    owner_context: (.properties."Owner/Context".select.name // null),
    notes_rt: (.properties.Notes.rich_text // []),
    is_archived: (.properties.Status.select.name == "Archived")
  }'
}

# --- Project field collection ---------------------------------------------

resolve_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
  else
    printf '%s' "$p"
  fi
}

# Echo "git" if path has a working .git, "nongit" if it looks like a project, else "skip".
classify_path() {
  local p="$1"
  if [ -e "$p/.git" ]; then
    printf 'git'
    return
  fi
  if [ -f "$p/package.json" ]      || [ -f "$p/index.html" ] \
     || [ -f "$p/.lovable" ]       || [ -f "$p/README.md" ] \
     || [ -f "$p/requirements.txt" ] || [ -f "$p/pyproject.toml" ] \
     || [ -f "$p/main.py" ]        || [ -f "$p/Cargo.toml" ] \
     || [ -f "$p/go.mod" ]         || [ -f "$p/Gemfile" ] \
     || compgen -G "$p/*.fig" >/dev/null \
     || compgen -G "$p/*.sketch" >/dev/null \
     || compgen -G "$p/*.csproj" >/dev/null \
     || compgen -G "$p/*.html" >/dev/null \
     || compgen -G "$p/*.py" >/dev/null \
     || compgen -G "$p/*.sh" >/dev/null; then
    printf 'nongit'
    return
  fi
  printf 'skip'
}

# Folder mtime as unix epoch (macOS).
folder_mtime() {
  stat -f %m "$1" 2>/dev/null || echo 0
}

# Manifest-only stack detection at a single directory. Echoes one stack name
# per line, no dedup. Caller aggregates.
_detect_stack_at() {
  local p="$1"
  [ -d "$p" ] || return 0

  if [ -f "$p/package.json" ]; then
    local deps
    deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys | .[]' "$p/package.json" 2>/dev/null | tr '\n' ' ' || echo "")"
    if printf '%s' "$deps" | grep -qw 'typescript'; then
      echo typescript
    else
      echo javascript
    fi
    printf '%s' "$deps" | grep -qw 'react'    && echo react
    printf '%s' "$deps" | grep -qw 'next'     && echo nextjs
    printf '%s' "$deps" | grep -qw 'vite'     && echo vite
    printf '%s' "$deps" | grep -qw 'hono'     && echo hono
    if printf '%s' "$deps" | grep -qE '(^| )wrangler( |$)|@cloudflare/workers-types'; then
      echo wrangler
    fi
  fi

  if [ -f "$p/requirements.txt" ] || [ -f "$p/pyproject.toml" ]; then
    echo python
    if [ -f "$p/requirements.txt" ] && grep -qiE '^(fastapi)([=<>~ ]|$)' "$p/requirements.txt" 2>/dev/null; then
      echo fastapi
    elif [ -f "$p/pyproject.toml" ] && grep -qiE '"?fastapi"?' "$p/pyproject.toml" 2>/dev/null; then
      echo fastapi
    fi
  fi

  [ -f "$p/Cargo.toml" ] && echo rust
  [ -f "$p/go.mod" ]     && echo go
  [ -f "$p/Gemfile" ]    && echo ruby
  if compgen -G "$p/*.csproj" >/dev/null; then
    echo dotnet
  fi
  return 0
}

# Stack inference: root + conventional monorepo subdirs (depth 1) and known
# workspace patterns (depth 2: apps/*, packages/*, services/*).
detect_stack() {
  local p="$1"
  local out=()
  local line sd ws_root child

  while IFS= read -r line; do
    [ -n "$line" ] && out+=("$line")
  done < <(_detect_stack_at "$p")

  for sd in frontend backend api web client server; do
    [ -d "$p/$sd" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && out+=("$line")
    done < <(_detect_stack_at "$p/$sd")
  done

  for ws_root in apps packages services; do
    [ -d "$p/$ws_root" ] || continue
    for child in "$p/$ws_root"/*/; do
      [ -d "$child" ] || continue
      while IFS= read -r line; do
        [ -n "$line" ] && out+=("$line")
      done < <(_detect_stack_at "${child%/}")
    done
  done

  [ ${#out[@]} -gt 0 ] || return 0
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

detect_deploy() {
  local p="$1"
  [ -f "$p/vercel.json" ]      && { echo vercel; return; }
  [ -f "$p/netlify.toml" ]     && { echo netlify; return; }
  [ -f "$p/fly.toml" ]         && { echo fly; return; }
  [ -f "$p/.lovable" ]         && { echo lovable; return; }
  [ -f "$p/amplify.yml" ]      && { echo amplify; return; }
  [ -f "$p/serverless.yml" ]   && { echo serverless; return; }
  [ -f "$p/railway.json" ]     && { echo railway; return; }
  if [ -f "$p/wrangler.toml" ] || [ -f "$p/wrangler.jsonc" ] || [ -f "$p/wrangler.json" ]; then
    echo cloudflare; return
  fi
  [ -f "$p/Dockerfile" ]       && { echo docker; return; }
  echo none
}

extract_linked_docs() {
  local p="$1"
  local files=()
  [ -f "$p/README.md" ]   && files+=("$p/README.md")
  [ -f "$p/CLAUDE.md" ]   && files+=("$p/CLAUDE.md")
  [ ${#files[@]} -eq 0 ] && return 0
  # NB: rg's short flag `-h` is `--help`, not `--no-filename`. Using the long
  # form is the only way to suppress filenames; a previous `-oh` invocation
  # silently dumped rg's help text instead of searching.
  rg --only-matching --no-filename -e 'https?://[^ )"<>]+' "${files[@]}" 2>/dev/null \
    | grep -E '(notion\.so|notion\.site|atlassian\.net|linear\.app)' \
    | sort -u | head -10 | tr '\n' ' '
}

extract_readme_title() {
  local p="$1"
  [ -f "$p/README.md" ] || return 0
  local title lower deny
  title="$(awk '/^# / {sub(/^# +/, ""); print; exit}' "$p/README.md")"
  [ -z "$title" ] && return 0
  lower="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  if [ ${#README_TITLE_DENYLIST[@]} -gt 0 ]; then
    for deny in "${README_TITLE_DENYLIST[@]}"; do
      [ "$lower" = "$deny" ] && return 0
    done
  fi
  printf '%s' "$title"
}

# First non-heading, non-image-only paragraph of the README, capped at 280 chars.
# Falls back to the H1 text if no paragraph survives stripping.
extract_purpose() {
  local p="$1"
  [ -f "$p/README.md" ] || return 0

  # Note on awk control flow: `exit` from a main rule still runs END, so
  # `print buf; exit` would emit twice. Print only in END and use exit to
  # stop scanning once a complete paragraph has been collected.
  local para
  para="$(awk '
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^[[:space:]]*#/ { next }
    {
      stripped = $0
      gsub(/\[!\[[^]]*\]\([^)]*\)\]\([^)]*\)/, "", stripped)
      gsub(/!\[[^]]*\]\([^)]*\)/, "", stripped)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", stripped)
      if (stripped == "") {
        if (buf != "") exit
        next
      }
      buf = (buf ? buf " " : "") stripped
    }
    END { if (buf != "") print buf }
  ' "$p/README.md" | tr -s ' ' | head -c 280)"

  if [ -n "$para" ]; then
    printf '%s' "$para"
    return
  fi

  awk '/^# / { sub(/^# +/, ""); print; exit }' "$p/README.md" | head -c 280
}

count_todos() {
  local p="$1" is_git="$2"
  if [ "$is_git" = "git" ]; then
    (cd "$p" && git ls-files -z 2>/dev/null | xargs -0 rg -c -e 'TODO|FIXME' 2>/dev/null) \
      | awk -F: '{ s += $NF } END { print s + 0 }'
  else
    rg --hidden --no-messages \
       --glob '!node_modules' --glob '!.next' --glob '!dist' --glob '!build' --glob '!out' \
       --glob '!vendor' --glob '!.venv' --glob '!venv' --glob '!__pycache__' --glob '!target' \
       -c -e 'TODO|FIXME' "$p" 2>/dev/null \
      | awk -F: '{ s += $NF } END { print s + 0 }'
  fi
}

count_open_prs() {
  local remote="$1"
  case "$remote" in
    *github.com*) ;;
    *) echo 0; return ;;
  esac
  local owner_repo
  owner_repo="$(printf '%s' "$remote" \
    | sed -E 's#^https?://github\.com/##; s#^git@github\.com:##; s#\.git$##')"
  [ -n "$owner_repo" ] || { echo 0; return; }
  gh pr list --repo "$owner_repo" --state open --json number 2>/dev/null \
    | jq 'length' 2>/dev/null || echo 0
}

scan_git_project() {
  local p="$1"
  local name remote branch ahead behind dirty stash
  local last_ts last_msg
  local default_branch unmerged
  local todos prs
  local has_claude purpose linked_docs deploy stack_csv readme_title display_name
  local mtime last_activity_ts days
  local worktree_count=""

  name="$(basename "$p")"
  readme_title="$(extract_readme_title "$p")"
  if [ -n "$readme_title" ] && [ "$readme_title" != "$name" ]; then
    display_name="$readme_title"
  else
    display_name="$name"
  fi

  remote="$(git -C "$p" remote get-url origin 2>/dev/null || echo '')"
  branch="$(git -C "$p" branch --show-current 2>/dev/null || echo '')"
  [ -z "$branch" ] && branch="$(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo 'detached')"

  ahead=0; behind=0
  if [ -n "$remote" ] && git -C "$p" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    read -r ahead behind < <(git -C "$p" rev-list --left-right --count "$branch...origin/$branch" 2>/dev/null || echo "0 0")
  fi
  dirty="$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  stash="$(git -C "$p" stash list 2>/dev/null | wc -l | tr -d ' ')"

  local sync_parts=()
  [ "$ahead"  != "0" ] && sync_parts+=("ahead $ahead")
  [ "$behind" != "0" ] && sync_parts+=("behind $behind")
  [ "$dirty"  != "0" ] && sync_parts+=("dirty $dirty")
  [ "$stash"  != "0" ] && sync_parts+=("stash $stash")
  local sync_state
  if [ ${#sync_parts[@]} -eq 0 ]; then
    sync_state="clean"
  else
    sync_state="$(IFS=', '; echo "${sync_parts[*]}")"
  fi

  last_ts="$(git -C "$p" log -1 --format=%at 2>/dev/null || echo 0)"
  last_msg="$(git -C "$p" log -1 --format=%s 2>/dev/null || echo '')"

  default_branch="$(git -C "$p" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo '')"
  if [ -z "$default_branch" ]; then
    default_branch="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi
  unmerged="$(git -C "$p" for-each-ref --no-merged "$default_branch" --format='%(refname:short)' refs/heads/ 2>/dev/null | wc -l | tr -d ' ')"

  todos="$(count_todos "$p" git)"
  prs="$(count_open_prs "$remote")"

  has_claude="false"
  [ -f "$p/CLAUDE.md" ] && has_claude="true"

  purpose="$(extract_purpose "$p")"
  linked_docs="$(extract_linked_docs "$p")"
  deploy="$(detect_deploy "$p")"

  local stack_arr=()
  while IFS= read -r line; do [ -n "$line" ] && stack_arr+=("$line"); done < <(detect_stack "$p")
  stack_csv="$(IFS=','; echo "${stack_arr[*]:-}")"

  mtime="$(folder_mtime "$p")"
  if [ "$last_ts" -gt "$mtime" ]; then
    last_activity_ts="$last_ts"
  else
    last_activity_ts="$mtime"
  fi
  days=$(( ( $(date +%s) - last_activity_ts ) / 86400 ))

  # Worktree count: only populated for repos under WORKTREE_REPO_PARENT,
  # counting subdirs under WORKTREE_BASE/<name>.
  if [ -n "$WORKTREE_REPO_PARENT" ] && [ -n "$WORKTREE_BASE" ] \
     && [[ "$p" == "$WORKTREE_REPO_PARENT/"* ]]; then
    if [ -d "$WORKTREE_BASE/$name" ]; then
      worktree_count="$(find "$WORKTREE_BASE/$name" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    else
      worktree_count="0"
    fi
  fi

  local status="Active"
  if [ "$days" -gt 30 ]; then
    status="Stalled"
  elif [ "$dirty" != "0" ] || [ "$ahead" != "0" ]; then
    status="Needs review"
  fi

  jq -n \
    --arg name           "$display_name" \
    --arg path           "$p" \
    --arg status         "$status" \
    --arg remote         "$remote" \
    --arg branch         "$branch" \
    --arg sync_state     "$sync_state" \
    --argjson open_prs   "${prs:-0}" \
    --arg last_commit    "$(date -u -r "$last_ts" +'%Y-%m-%d' 2>/dev/null || echo '')" \
    --arg last_msg       "$last_msg" \
    --arg last_activity  "$(date -u -r "$last_activity_ts" +'%Y-%m-%d' 2>/dev/null || echo '')" \
    --argjson days       "$days" \
    --arg stack          "$stack_csv" \
    --arg deploy         "$deploy" \
    --argjson has_claude "$has_claude" \
    --argjson todos      "${todos:-0}" \
    --arg purpose        "$purpose" \
    --arg linked_docs    "$linked_docs" \
    --argjson worktree   "$( [ -n "$worktree_count" ] && echo "$worktree_count" || echo 'null' )" \
    --argjson unmerged   "${unmerged:-0}" \
    '{
       name: $name, path: $path, status: $status, remote: $remote, branch: $branch,
       sync_state: $sync_state, open_prs: $open_prs,
       last_commit: $last_commit, last_msg: $last_msg, last_activity: $last_activity,
       days: $days, stack: ($stack | split(",") | map(select(length > 0))),
       deploy: $deploy, has_claude: $has_claude, todos: $todos,
       purpose: $purpose, linked_docs: $linked_docs,
       worktree_count: $worktree, unmerged: $unmerged,
       is_git: true
     }'
}

scan_nongit_project() {
  local p="$1"
  local name display_name readme_title mtime days
  local todos has_claude purpose linked_docs deploy stack_csv

  name="$(basename "$p")"
  readme_title="$(extract_readme_title "$p")"
  if [ -n "$readme_title" ] && [ "$readme_title" != "$name" ]; then
    display_name="$readme_title"
  else
    display_name="$name"
  fi

  mtime="$(folder_mtime "$p")"
  days=$(( ( $(date +%s) - mtime ) / 86400 ))

  todos="$(count_todos "$p" nongit)"
  has_claude="false"
  [ -f "$p/CLAUDE.md" ] && has_claude="true"
  purpose="$(extract_purpose "$p")"
  linked_docs="$(extract_linked_docs "$p")"
  deploy="$(detect_deploy "$p")"

  local stack_arr=()
  while IFS= read -r line; do [ -n "$line" ] && stack_arr+=("$line"); done < <(detect_stack "$p")
  stack_csv="$(IFS=','; echo "${stack_arr[*]:-}")"

  jq -n \
    --arg name           "$display_name" \
    --arg path           "$p" \
    --arg last_activity  "$(date -u -r "$mtime" +'%Y-%m-%d' 2>/dev/null || echo '')" \
    --argjson days       "$days" \
    --arg stack          "$stack_csv" \
    --arg deploy         "$deploy" \
    --argjson has_claude "$has_claude" \
    --argjson todos      "${todos:-0}" \
    --arg purpose        "$purpose" \
    --arg linked_docs    "$linked_docs" \
    '{
       name: $name, path: $path, status: "Non-git",
       remote: "", branch: "", sync_state: "", open_prs: 0,
       last_commit: "", last_msg: "", last_activity: $last_activity,
       days: $days, stack: ($stack | split(",") | map(select(length > 0))),
       deploy: $deploy, has_claude: $has_claude, todos: $todos,
       purpose: $purpose, linked_docs: $linked_docs,
       worktree_count: null, unmerged: 0,
       is_git: false
     }'
}

# --- Notion payload + upsert ----------------------------------------------

build_properties() {
  local rec="$1" preserve_status="$2"
  local now_iso
  now_iso="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  local name path status remote branch sync_state purpose linked_docs deploy last_msg last_commit last_activity
  local open_prs days todos worktree unmerged has_claude

  name="$(jq -r '.name'           <<<"$rec")"
  path="$(jq -r '.path'           <<<"$rec")"
  status="$(jq -r '.status'       <<<"$rec")"
  remote="$(jq -r '.remote'       <<<"$rec")"
  branch="$(jq -r '.branch'       <<<"$rec")"
  sync_state="$(jq -r '.sync_state' <<<"$rec")"
  purpose="$(jq -r '.purpose'     <<<"$rec")"
  linked_docs="$(jq -r '.linked_docs' <<<"$rec")"
  deploy="$(jq -r '.deploy'       <<<"$rec")"
  last_msg="$(jq -r '.last_msg'   <<<"$rec")"
  last_commit="$(jq -r '.last_commit' <<<"$rec")"
  last_activity="$(jq -r '.last_activity' <<<"$rec")"
  open_prs="$(jq -r '.open_prs'   <<<"$rec")"
  days="$(jq -r '.days'           <<<"$rec")"
  todos="$(jq -r '.todos'         <<<"$rec")"
  worktree="$(jq -r '.worktree_count' <<<"$rec")"
  unmerged="$(jq -r '.unmerged'   <<<"$rec")"
  has_claude="$(jq -r '.has_claude' <<<"$rec")"

  if [ "$preserve_status" = "1" ]; then
    status="Archived"
  fi

  jq -n \
    --arg name           "$name" \
    --arg path           "$path" \
    --arg status         "$status" \
    --arg remote         "$remote" \
    --arg branch         "$branch" \
    --arg sync_state     "$sync_state" \
    --arg purpose        "$purpose" \
    --arg linked_docs    "$linked_docs" \
    --arg deploy         "$deploy" \
    --arg last_msg       "$last_msg" \
    --arg last_commit    "$last_commit" \
    --arg last_activity  "$last_activity" \
    --argjson open_prs   "${open_prs:-0}" \
    --argjson days       "${days:-0}" \
    --argjson todos      "${todos:-0}" \
    --argjson worktree   "$worktree" \
    --argjson unmerged   "${unmerged:-0}" \
    --argjson has_claude "$has_claude" \
    --argjson stack      "$(jq -c '.stack' <<<"$rec")" \
    --arg now_iso        "$now_iso" \
    '
      def rt(s): if (s // "") == "" then [] else [{type:"text", text:{content: s}}] end;

      ({
        Name:                 { title: rt($name) },
        Status:               { select: { name: $status } },
        Path:                 { rich_text: rt($path) },
        Remote:               (if $remote == "" then { url: null } else { url: $remote } end),
        Branch:               { rich_text: rt($branch) },
        "Sync state":         { rich_text: rt($sync_state) },
        "Open PRs":           { number: $open_prs },
        "Last commit message":{ rich_text: rt($last_msg) },
        "Days since last touch": { number: $days },
        Stack:                { multi_select: ($stack | map({name: .})) },
        "Deploy target":      { select: { name: $deploy } },
        "Has CLAUDE.md":      { checkbox: $has_claude },
        TODOs:                { number: $todos },
        Purpose:              { rich_text: rt($purpose) },
        "Linked docs":        { rich_text: rt($linked_docs) },
        "Last synced":        { date: { start: $now_iso } },
        "Unmerged branches":  { number: $unmerged }
      })
      + (if $last_commit   == "" then {} else { "Last commit":  { date: { start: $last_commit } } } end)
      + (if $last_activity == "" then {} else { "Last activity":{ date: { start: $last_activity } } } end)
      + (if $worktree     == null then {} else { "Worktree count":{ number: $worktree } } end)
    '
}

upsert_record() {
  local rec="$1"
  local path display_name preserve_status=0
  path="$(jq -r '.path' <<<"$rec")"
  display_name="$(jq -r '.name' <<<"$rec")"

  local stack_list=()
  while IFS= read -r s; do [ -n "$s" ] && stack_list+=("$s"); done < <(jq -r '.stack[]?' <<<"$rec")
  if [ ${#stack_list[@]} -gt 0 ]; then
    USE_STACK=("${stack_list[@]}")
    ensure_stack_options "${stack_list[@]}"
    local use_json
    use_json="$(printf '%s\n' "${USE_STACK[@]:-}" | jq -R . | jq -s .)"
    rec="$(jq --argjson s "$use_json" '.stack = $s' <<<"$rec")"
  fi

  local existing_id=""
  existing_id="$(find_page_by_path "$path" || echo "")"

  if [ -n "$existing_id" ]; then
    local manual
    manual="$(fetch_manual_fields "$existing_id")"
    if [ "$(jq -r '.is_archived' <<<"$manual")" = "true" ]; then
      preserve_status=1
    fi
  fi

  local props
  props="$(build_properties "$rec" "$preserve_status")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $( [ -n "$existing_id" ] && echo update || echo create ) $display_name ($path)"
    jq -n --argjson p "$props" '{properties: $p}' >> "$LOG_FILE"
    return 0
  fi

  if [ -n "$existing_id" ]; then
    local body resp
    body="$(jq -n --argjson p "$props" '{properties: $p}')"
    resp="$(notion_curl PATCH "/pages/$existing_id" "$body")"
    if printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
      log "updated $display_name ($path)"
    else
      err "update failed for $display_name: $resp"
      return 1
    fi
  else
    local body resp
    body="$(jq -n --arg db "$NOTION_DB_ID" --argjson p "$props" \
      '{parent: {database_id: $db}, properties: $p}')"
    resp="$(notion_curl POST "/pages" "$body")"
    if printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
      log "created $display_name ($path)"
    else
      err "create failed for $display_name: $resp"
      return 1
    fi
  fi
}

# --- Discovery + main ------------------------------------------------------

discover_paths() {
  local root p
  if [ ${#SCAN_ROOTS[@]} -gt 0 ]; then
    for root in "${SCAN_ROOTS[@]}"; do
      [ -d "$root" ] || continue
      for p in "$root"/*/; do
        [ -d "$p" ] || continue
        printf '%s\n' "${p%/}"
      done
    done
  fi
  if [ ${#SINGLE_PROJECTS[@]} -gt 0 ]; then
    for p in "${SINGLE_PROJECTS[@]}"; do
      [ -d "$p" ] || continue
      printf '%s\n' "$p"
    done
  fi
}

scan_one() {
  local p="$1"
  p="$(resolve_path "$p")"
  local kind
  kind="$(classify_path "$p")"

  case "$kind" in
    git)    scan_git_project "$p" ;;
    nongit) scan_nongit_project "$p" ;;
    skip)
      log "skipped $p (no git, no project markers)"
      return 1
      ;;
  esac
}

main_full_scan() {
  verify_workspace_scope

  if [ "$DRY_RUN" -eq 0 ] && [ -f "$DEBOUNCE_FILE" ]; then
    local last_ts now_ts age
    last_ts="$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    age=$(( now_ts - last_ts ))
    if [ "$age" -lt "$DEBOUNCE_SECONDS" ]; then
      log "debounced (last scan ${age}s ago, threshold ${DEBOUNCE_SECONDS}s) - skipping"
      return 0
    fi
  fi

  log "starting full scan (dry_run=$DRY_RUN)"
  local count=0 errors=0
  # TODO: add 350ms sleep between rows when project count exceeds 30 (Notion rate limit ~3 req/sec).
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local rec
    if rec="$(scan_one "$p")"; then
      if upsert_record "$rec"; then
        count=$(( count + 1 ))
      else
        errors=$(( errors + 1 ))
      fi
    fi
  done < <(discover_paths)

  if [ "$DRY_RUN" -eq 0 ] && [ "$errors" -eq 0 ]; then
    mkdir -p "$(dirname "$DEBOUNCE_FILE")"
    date +%s > "$DEBOUNCE_FILE"
  fi

  log "scan complete: $count processed, $errors errors"
}

main_single() {
  verify_workspace_scope

  local p="$TARGET_REPO"
  log "single-repo scan: $p"
  local rec
  if rec="$(scan_one "$p")"; then
    upsert_record "$rec"
  else
    err "skipped $p"
    exit 1
  fi
}

case "$MODE" in
  scan)   main_full_scan ;;
  single) main_single ;;
esac
